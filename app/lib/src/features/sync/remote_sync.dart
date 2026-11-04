// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../graph/graph_ports.dart' show exactNamePattern, jjCommand;
import '../settings/immutable_heads.dart' show tomlStringValue;

/// How the sync slice reaches a repository's remotes (Story 11.8): the CLI's default fetch and push remotes, every
/// remote's name, `jj git fetch` with the default remotes, the read-only remote-change poll and `jj git push`. The app's
/// adapter is [RepoRemoteSync] over the open handle; the tests pass a fake.
abstract interface class RemoteSync {
  /// The remotes `jj git fetch` without `--remote` fetches from (`RepoHandle.gitFetchRemotes`).
  Future<List<String>> fetchRemotes();

  /// The remotes `jj git push` without `--remote` pushes to (`RepoHandle.gitPushRemotes`).
  Future<List<String>> pushRemotes();

  /// Every configured remote's name (`RepoHandle.remotes`).
  Future<List<String>> remoteNames();

  /// `jj git fetch` with the CLI's default remotes: no remote is passed (decision 16.44).
  NetworkOperation<GitFetchResult> fetch();

  /// What [remote] has now against the view, without fetching (`RepoHandle.remoteChanges`).
  NetworkOperation<WarnedList<RemoteRefChange>> remoteChanges(String remote);

  /// `jj git push` as [request] says (a dry run while [PushRequest.dryRun]).
  NetworkOperation<GitPushResult> push(PushRequest request);

  /// What the Push sheet says about the config: `git.sign-on-push` and the effective `revsets.git-push`.
  Future<PushConfig> pushConfig();

  /// `jj bookmark track` of the `NAME@REMOTE` [symbols] (`RepoHandle.bookmarkTrack`; the Push sheet's Track fix-it,
  /// Story 11.22).
  Future<void> track(List<String> symbols);
}

/// The config the Push sheet names (Story 11.8 item 7).
@immutable
class PushConfig {
  /// [signOnPush] and the [gitPushRevset].
  const PushConfig({this.signOnPush = false, this.gitPushRevset});

  /// `git.sign-on-push`: the push signs commits and rebases their descendants.
  final bool signOnPush;

  /// `revsets.git-push`, the bare push's revset; null when unread.
  final String? gitPushRevset;
}

/// Which refs a push sends: the bare `jj git push`, a bulk flag, or refs named one by one.
enum PushMode {
  /// `jj git push` alone: `revsets.git-push` per remote and the tracked tags in it.
  bare,

  /// `--tracked`.
  tracked,

  /// `--all`.
  all,

  /// `--deleted`.
  deleted,

  /// `--bookmark` / `--tag` / `--change` / `--named` by hand.
  custom,
}

/// One `jj git push` with the parameters the Push sheet passes through (no `-r`, no `-o`; Story 11.8): the request the
/// port runs and the [command] the footer shows, which are the same.
@immutable
class PushRequest {
  /// A push to [remotes] (null: the default remotes, no flag) in [mode].
  const PushRequest({
    this.remotes,
    this.mode = PushMode.bare,
    this.bookmarks = const <String>[],
    this.tags = const <String>[],
    this.changes = const <String>[],
    this.named = const <String>[],
    this.allowEmptyDescription = false,
    this.allowPrivate = false,
    this.allowConflicts = false,
    this.dryRun = false,
  });

  /// `--remote` each; null for the default remotes.
  final List<String>? remotes;

  /// The mode; [bookmarks], [tags], [changes] and [named] belong to [PushMode.custom].
  final PushMode mode;

  /// `--bookmark` names, each sent as an exact pattern.
  final List<String> bookmarks;

  /// `--tag` names, each sent as an exact pattern.
  final List<String> tags;

  /// `--change` revisions.
  final List<String> changes;

  /// `--named NAME=REVISION` values.
  final List<String> named;

  /// `--allow-empty-description`.
  final bool allowEmptyDescription;

  /// `--allow-private`.
  final bool allowPrivate;

  /// `--allow-conflicts`.
  final bool allowConflicts;

  /// `--dry-run`: the plan only. The footer never shows it.
  final bool dryRun;

  /// The patterns `--bookmark` passes.
  List<String> get bookmarkPatterns => bookmarks.map(exactNamePattern).toList();

  /// The patterns `--tag` passes.
  List<String> get tagPatterns => tags.map(exactNamePattern).toList();

  /// This request as a dry run.
  PushRequest get asDryRun => _copy(dryRun: true);

  /// This request run for real.
  PushRequest get asPush => _copy(dryRun: false);

  /// This request in [mode] with nothing named (a mode's plan).
  PushRequest inMode(PushMode mode) => PushRequest(remotes: remotes, mode: mode, dryRun: true);

  PushRequest _copy({required bool dryRun}) => PushRequest(
    remotes: remotes,
    mode: mode,
    bookmarks: bookmarks,
    tags: tags,
    changes: changes,
    named: named,
    allowEmptyDescription: allowEmptyDescription,
    allowPrivate: allowPrivate,
    allowConflicts: allowConflicts,
    dryRun: dryRun,
  );

  /// The command, shell-quoted, without `--dry-run`.
  String get command => jjCommand(<String>[
    'git', 'push', // l10n-ignore: jj command
    for (final String remote in remotes ?? const <String>[]) ...<String>['--remote', remote], // l10n-ignore: jj flag
    ?switch (mode) {
      PushMode.tracked => '--tracked', // l10n-ignore: jj flag
      PushMode.all => '--all', // l10n-ignore: jj flag
      PushMode.deleted => '--deleted', // l10n-ignore: jj flag
      PushMode.bare || PushMode.custom => null,
    },
    for (final String pattern in bookmarkPatterns) ...<String>['--bookmark', pattern], // l10n-ignore: jj flag
    for (final String pattern in tagPatterns) ...<String>['--tag', pattern], // l10n-ignore: jj flag
    for (final String change in changes) ...<String>['--change', change], // l10n-ignore: jj flag
    for (final String value in named) ...<String>['--named', value], // l10n-ignore: jj flag
    if (allowEmptyDescription) '--allow-empty-description', // l10n-ignore: jj flag
    if (allowPrivate) '--allow-private', // l10n-ignore: jj flag
    if (allowConflicts) '--allow-conflicts', // l10n-ignore: jj flag
  ]);

  @override
  bool operator ==(Object other) => other is PushRequest && other.dryRun == dryRun && other.command == command;

  @override
  int get hashCode => Object.hash(command, dryRun);

  @override
  String toString() => dryRun ? '$command --dry-run' : command; // l10n-ignore: jj flag
}

/// [RemoteSync] over the open repository's handle; `config` reads one config name's effective value as TOML (the
/// environment's `configList`).
class RepoRemoteSync implements RemoteSync {
  /// The remotes of the repository [_open] returns the handle of (read at each call, as the project's handle is).
  RepoRemoteSync(this._open, {required this._config});

  final RepoHandle Function() _open;
  final Future<String?> Function(String name) _config;

  RepoHandle get _handle => _open();

  @override
  Future<List<String>> fetchRemotes() async => await _handle.gitFetchRemotes();

  @override
  Future<List<String>> pushRemotes() async => await _handle.gitPushRemotes();

  @override
  Future<List<String>> remoteNames() async => <String>[
    for (final Remote remote in await _handle.remotes()) remote.name,
  ];

  @override
  NetworkOperation<GitFetchResult> fetch() => _handle.gitFetch();

  @override
  NetworkOperation<WarnedList<RemoteRefChange>> remoteChanges(String remote) => _handle.remoteChanges(remote);

  @override
  NetworkOperation<GitPushResult> push(PushRequest request) => _handle.gitPush(
    remotes: request.remotes,
    bookmarks: request.bookmarkPatterns,
    tags: request.tagPatterns,
    all: request.mode == PushMode.all,
    tracked: request.mode == PushMode.tracked,
    deleted: request.mode == PushMode.deleted,
    allowEmptyDescription: request.allowEmptyDescription,
    allowPrivate: request.allowPrivate,
    allowConflicts: request.allowConflicts,
    changes: request.changes,
    named: request.named,
    dryRun: request.dryRun,
  );

  @override
  Future<void> track(List<String> symbols) async => await _handle.bookmarkTrack(symbols);

  @override
  Future<PushConfig> pushConfig() async {
    final String? sign = await _config('git.sign-on-push'); // l10n-ignore: jj config name
    return PushConfig(
      signOnPush: sign == 'true',
      gitPushRevset: tomlStringValue(await _config('revsets.git-push')), // l10n-ignore: jj config name
    );
  }
}
