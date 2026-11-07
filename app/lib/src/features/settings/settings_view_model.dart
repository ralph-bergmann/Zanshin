// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import '../graph/graph_layout.dart' show jjRefSymbol;
import '../graph/graph_ports.dart' show jjCommand;
import '../projects/project_repos.dart';
import '../projects/project_session.dart';
import '../projects/projects_environment.dart';
import '../shell/app_menu.dart' show GraphMenuBinding;
import 'immutable_heads.dart';

final _log = Logger('zanshin.settings');

/// The config keys of Settings' jj rows.
abstract final class SettingsKeys {
  /// Identity › Name.
  static const userName = 'user.name'; // l10n-ignore: jj's config key

  /// Identity › Email.
  static const userEmail = 'user.email'; // l10n-ignore: jj's config key

  /// Remotes › Fetch from.
  static const gitFetch = 'git.fetch'; // l10n-ignore: jj's config key

  /// Remotes › Push to.
  static const gitPush = 'git.push'; // l10n-ignore: jj's config key

  /// `jj log`'s default revset; a write re-requests the graph too.
  static const revsetsLog = 'revsets.log'; // l10n-ignore: jj's config key

  /// The keys whose write re-requests the graph's layout once.
  static const graphKeys = <String>{trunkKey, immutableHeadsKey, revsetsLog};

  /// The keys the Project tab reads.
  static const project = <String>[gitFetch, gitPush, trunkKey, immutableHeadsKey, userEmail];

  /// The keys the General tab reads.
  static const general = <String>[userName, userEmail];
}

/// What Settings reads of the open repository besides the config, and its remote verbs (a port, so tests pass a fake).
abstract interface class SettingsRepoReads {
  /// The remotes (`jj git remote list`), URLs unredacted.
  Future<List<Remote>> remotes();

  /// `jj git remote add`; the call's warnings.
  Future<List<ZanshinWarning>> remoteAdd({required String name, required String url, String? pushUrl});

  /// `jj git remote rename`; the call's warnings.
  Future<List<ZanshinWarning>> remoteRename(String oldName, String newName);

  /// `jj git remote set-url`, a null side left as it is; the call's warnings.
  Future<List<ZanshinWarning>> remoteSetUrl({required String name, String? url, String? pushUrl});

  /// `jj git remote remove`; the call's warnings.
  Future<List<ZanshinWarning>> remoteRemove(String name);

  /// The remotes `jj git fetch` without `--remote` fetches from.
  Future<List<String>> defaultFetchRemotes();

  /// The remotes `jj git push` without `--remote` pushes to.
  Future<List<String>> defaultPushRemotes();

  /// The names of [remote]'s bookmarks.
  Future<List<String>> remoteBookmarks(String remote);

  /// The local bookmarks' names.
  Future<List<String>> localBookmarks();

  /// How many commits each of [expressions] denotes at the head operation, at most [cap] each.
  Future<RevsetCounts> revsetCounts(List<String> expressions, {required int cap});

  /// The commits [revset] denotes, each with its refs, shortest change id prefix and root flag.
  Future<List<RevsetMember>> revsetMembers(String revset);
}

/// [SettingsRepoReads] over an open repository's handle.
class RepoSettingsReads implements SettingsRepoReads {
  /// The reads of [_repo].
  RepoSettingsReads(this._repo);

  final ProjectRepo _repo;

  @override
  Future<List<Remote>> remotes() => _repo.handle.remotes();

  @override
  Future<List<ZanshinWarning>> remoteAdd({required String name, required String url, String? pushUrl}) async =>
      (await _repo.handle.gitRemoteAdd(name: name, url: url, pushUrl: pushUrl)).warnings;

  @override
  Future<List<ZanshinWarning>> remoteRename(String oldName, String newName) async =>
      (await _repo.handle.gitRemoteRename(oldName, newName)).warnings;

  @override
  Future<List<ZanshinWarning>> remoteSetUrl({required String name, String? url, String? pushUrl}) async =>
      (await _repo.handle.gitRemoteSetUrl(name: name, url: url, pushUrl: pushUrl)).warnings;

  @override
  Future<List<ZanshinWarning>> remoteRemove(String name) async => (await _repo.handle.gitRemoteRemove(name)).warnings;

  @override
  Future<List<String>> defaultFetchRemotes() => _repo.handle.gitFetchRemotes();

  @override
  Future<List<String>> defaultPushRemotes() => _repo.handle.gitPushRemotes();

  @override
  Future<List<String>> remoteBookmarks(String remote) async => <String>{
    for (final Bookmark bookmark in await _repo.handle.bookmarks(remotes: <String>['exact:$remote']))
      if (bookmark.kind case RemoteBookmark(:final remoteName) when remoteName == remote) bookmark.name,
  }.toList();

  @override
  Future<List<String>> localBookmarks() async => <String>{
    for (final Bookmark bookmark in await _repo.handle.bookmarks())
      if (bookmark.kind is LocalBookmark) bookmark.name,
  }.toList();

  @override
  Future<RevsetCounts> revsetCounts(List<String> expressions, {required int cap}) async {
    final String operation = (await _repo.handle.opLog(limit: 1)).first.id;
    return _repo.handle.revsetCounts(operation, expressions, cap: cap);
  }

  @override
  Future<List<RevsetMember>> revsetMembers(String revset) async {
    final GraphTopologyView view = await _repo.handle.graphTopology(
      revset: revset,
      anchors: const <String>[],
      withTimestamps: false,
    );
    return <RevsetMember>[
      for (var i = 0; i < view.nodeCount; i++)
        RevsetMember(
          refs: view.refsOf(i),
          changeIdPrefix: view.changeId(i).substring(0, view.changeIdPrefixLength(i)),
          isRoot: view.isRoot(i),
        ),
    ];
  }
}

/// The text of an [error] for a row.
String settingsErrorText(ZanshinFfiException error) => error.context ?? error.code;

// DS RemotesGroup.jsx `zsRemScrub`, but up to the LAST `@` before the path: a password may hold an unencoded `@`.
final _remoteCredential = RegExp(r'^([a-z][a-z0-9+.-]*://)[^/]*@', caseSensitive: false);

/// [url] with a credential hidden as `•••` (`https://•••@host/…`); every remote URL Settings shows goes through it.
String scrubRemoteUrl(String url) => url.replaceFirstMapped(_remoteCredential, (match) => '${match[1]}•••@');

/// Whether [url] holds a credential [scrubRemoteUrl] hides.
bool remoteUrlHasCredential(String? url) => url != null && scrubRemoteUrl(url) != url;

/// A remote verb (Story 11.18), as a Remotes form or the Remove sheet issues it.
sealed class RemoteOp {
  const RemoteOp(this.name);

  /// The remote the verb is about; for an add, the new remote's name.
  final String name;

  /// The name the user typed, which jj validates (the new name for a rename).
  String get typedName => name;

  List<String> get _args;

  /// `jj git remote …` as the CLI takes it, each word shell-quoted, credentials hidden, missing values as
  /// placeholders.
  String get command => jjCommand(<String>['git', 'remote', ..._args]); // l10n-ignore: jj command
}

/// `jj git remote add <name> <url> [--push-url <push>]`.
final class RemoteAdd extends RemoteOp {
  /// Adds [name] at [url], pushing to [pushUrl] when given.
  const RemoteAdd(super.name, {required this.url, this.pushUrl});

  /// The fetch URL.
  final String url;

  /// The push URL, or null to push to [url].
  final String? pushUrl;

  @override
  List<String> get _args => <String>[
    'add', // l10n-ignore: jj command
    if (name.isEmpty) '<name>' else name, // l10n-ignore: jj command placeholder
    if (url.isEmpty) '<url>' else scrubRemoteUrl(url), // l10n-ignore: jj command placeholder
    if (pushUrl case final String push) ...<String>['--push-url', scrubRemoteUrl(push)],
  ];
}

/// `jj git remote rename <old> <new>`.
final class RemoteRename extends RemoteOp {
  /// Renames [name] to [newName].
  const RemoteRename(super.name, this.newName);

  /// The new name.
  final String newName;

  @override
  String get typedName => newName;

  @override
  List<String> get _args => <String>[
    'rename', // l10n-ignore: jj command
    name,
    if (newName.isEmpty) '<new name>' else newName, // l10n-ignore: jj command placeholder
  ];
}

/// `jj git remote set-url <name> [<url>] [--push <push>]`; a null side stays as it is.
final class RemoteSetUrl extends RemoteOp {
  /// Re-points [name]'s [url] and/or [pushUrl].
  const RemoteSetUrl(super.name, {this.url, this.pushUrl});

  /// The new fetch URL, or null to keep it.
  final String? url;

  /// The new push URL, or null to keep it.
  final String? pushUrl;

  @override
  List<String> get _args => <String>[
    'set-url', // l10n-ignore: jj command
    name,
    if (url case final String url) scrubRemoteUrl(url),
    if (pushUrl case final String push) ...<String>['--push', scrubRemoteUrl(push)],
  ];
}

/// `jj git remote remove <name>`.
final class RemoteRemove extends RemoteOp {
  /// Removes [name].
  const RemoteRemove(super.name);

  @override
  List<String> get _args => <String>['remove', name]; // l10n-ignore: jj command
}

/// What a remote verb left to show: a [RemoteRefusal] or a [RemoteWarning].
sealed class RemoteOutcome {
  const RemoteOutcome(this.message);

  /// jj's text, verbatim.
  final String message;
}

/// The plain sentence after a refusal, where the DS defines one.
enum RemoteHelp {
  /// The reserved name `git`.
  reservedName,

  /// A remote with git keys jj doesn't manage.
  nonstandardConfig,
}

/// jj refused the verb: its [message], and the [help] sentence about [name] where one is defined.
final class RemoteRefusal extends RemoteOutcome {
  /// The refusal [message].
  const RemoteRefusal(super.message, {this.help, this.name});

  /// The sentence after it, or null.
  final RemoteHelp? help;

  /// The remote the help names.
  final String? name;
}

/// jj warned after the verb landed: its [message] and its [hint].
final class RemoteWarning extends RemoteOutcome {
  /// The warning [message] with jj's [hint].
  const RemoteWarning(super.message, {required this.hint});

  /// jj's hint.
  final String hint;
}

/// jj's text for [error], a remote verb's failure, as the bridge sends it (the parity oracle proves it is the CLI's);
/// [typedName] is the name the user typed. The three remote codes carry `"<name>\n<jj's message>"`, the help keyed by
/// the code (never parsed from text).
RemoteRefusal remoteRefusal(ZanshinFfiException error, String typedName) =>
    switch ((error.code, error.context?.split('\n'))) {
      ('jj.remote_exists' || 'jj.remote_not_found', [_, final String message]) => RemoteRefusal(message),
      ('jj.remote_nonstandard_config', [final String name, final String message]) => RemoteRefusal(
        message,
        help: RemoteHelp.nonstandardConfig,
        name: name,
      ),
      ('jj.invalid_input', _) => RemoteRefusal(
        settingsErrorText(error),
        help: typedName == 'git' ? RemoteHelp.reservedName : null, // l10n-ignore: jj's reserved remote name
      ),
      _ => RemoteRefusal(settingsErrorText(error)),
    };

/// The Settings window's state and writes (Story 11.7): the app preferences in [store], the jj config through
/// [environment]'s config verbs at the tab's scope, the open project's reads through a [SettingsRepoReads].
///
/// - Every jj row reads the effective value (`configList`, the last entry no layer overrides).
/// - A write of a [SettingsKeys.graphKeys] key re-requests the bound graph's layout once ([graph]).
/// - An identity write keeps `@`'s author fact ([workingCopyAuthor]) when jj reports one.
/// - Text rows register their pending write ([registerFlush]); the window's close awaits [flushPending].
class SettingsViewModel extends ChangeNotifier {
  /// The view model over its ports.
  SettingsViewModel({
    required this.store,
    required this.environment,
    required this.session,
    required this.graph,
    required this.setThemeMode,
    SettingsRepoReads Function(ProjectRepo repo)? readsOf,
  }) : _readsOf = readsOf ?? RepoSettingsReads.new;

  /// The app preferences.
  final SettingsStore store;

  /// The jj config.
  final ProjectsEnvironment environment;

  /// The open project.
  final ProjectSession session;

  /// The project window's graph, which a trunk or immutable write re-requests.
  final ValueListenable<GraphMenuBinding?> graph;

  /// Sets the theme (and mirrors it onto the native window chrome).
  final Future<void> Function(ThemeMode mode) setThemeMode;

  final SettingsRepoReads Function(ProjectRepo repo) _readsOf;

  var _disposed = false;
  ProjectRepo? _repo;
  SettingsRepoReads? _reads;

  /// The General tab's config (the user-level stack), by key.
  var userConfig = <String, List<ConfigEntry>>{};

  /// The Project tab's config (the workspace's stack), by key.
  var projectConfig = <String, List<ConfigEntry>>{};

  /// `jj config path --user`, or null until read.
  String? userPath;

  /// `jj config path --repo`, or null until read.
  String? repoPath;

  /// The remotes, URLs unredacted (show them through [scrubRemoteUrl]).
  var remoteList = const <Remote>[];

  /// The remotes' names.
  List<String> get remotes => <String>[for (final Remote remote in remoteList) remote.name];

  /// What the last remote verb left under a row, by remote name; cleared by the next verb.
  final remoteNotes = <String, RemoteOutcome>{};

  /// The remote the Remove sheet asks about, or null.
  String? removing;

  /// Whether the Remove sheet leaves.
  var removeClosing = false;

  /// The remotes a fetch without `--remote` uses.
  var fetchDefault = const <String>[];

  /// The remotes a push without `--remote` uses.
  var pushDefault = const <String>[];

  /// The trunk choices: the default fetch remote's bookmarks as `<name>@<remote>`.
  var trunkChoices = const <String>[];

  /// The local bookmarks (the Immutable commits page's chips).
  var bookmarks = const <String>[];

  /// `::immutable_heads() ~ root()` counted, or null before or without an answer.
  RevsetCount? immutableCount;

  /// The names each built-in after `trunk()` matches here ([matchNames]), by term; an absent term is unread.
  var builtinMatches = <String, List<String>>{};

  /// `immutable_heads()` as [headLabels], or null before or without an answer; re-read with every recount.
  List<String>? immutableHeadLabels;

  /// `@`'s author after the last identity write that differs from it, else null.
  WorkingCopyAuthor? workingCopyAuthor;

  /// The last failed write per key.
  final errors = <String, String>{};

  final _flushes = <Object, Future<void> Function()>{};

  /// The open project's root, or null.
  String? get root => session.current?.path;

  /// The open project's name, or null.
  String? get projectName => session.current?.name;

  /// Starts reading and follows the open project.
  void init() {
    session.addListener(_sessionChanged);
    store.addListener(_notify);
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_sessionChanged);
    store.removeListener(_notify);
    super.dispose();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _sessionChanged() {
    if (!identical(session.repo, _repo)) {
      unawaited(_load());
    } else {
      _notify();
    }
  }

  // ---- reads ----

  /// The effective entry of [name] in the General ([project] false) or the Project tab's stack.
  ConfigEntry? effective(String name, {required bool project}) =>
      effectiveConfigEntry((project ? projectConfig : userConfig)[name] ?? const <ConfigEntry>[]);

  /// The effective string value of [name], or null when it is unset or no string.
  String? stringValue(String name, {required bool project}) =>
      tomlStringValue(effective(name, project: project)?.value);

  /// Whether [name] has a value in the repo config file.
  bool hasRepoValue(String name) =>
      (projectConfig[name] ?? const <ConfigEntry>[]).any((entry) => entry.source == ConfigValueSource.repo);

  /// The Immutable commits page's controls, from the effective alias.
  ImmutableHeads get immutableHeads =>
      ImmutableHeads.parse(stringValue(immutableHeadsKey, project: true), bookmarks: bookmarks);

  /// The current load; a superseded load's results are dropped.
  var _generation = 0;

  Future<void> _load() async {
    final int generation = ++_generation;
    _repo = session.repo;
    final ProjectRepo? repo = _repo;
    _reads = repo == null ? null : _readsOf(repo);
    // Nothing of the project before survives the switch.
    projectConfig = <String, List<ConfigEntry>>{};
    repoPath = null;
    remoteList = const <Remote>[];
    remoteNotes.clear();
    removing = null;
    removeClosing = false;
    fetchDefault = const <String>[];
    pushDefault = const <String>[];
    trunkChoices = const <String>[];
    bookmarks = const <String>[];
    immutableCount = null;
    builtinMatches = <String, List<String>>{};
    immutableHeadLabels = null;
    errors.clear();
    workingCopyAuthor = null;
    _notify();
    await Future.wait(<Future<void>>[_readGeneral(generation), if (repo != null) _readProject(generation)]);
  }

  Future<void> _readGeneral(int generation) async {
    try {
      final String path = await environment.configPath(ConfigScope.user);
      final config = <String, List<ConfigEntry>>{
        for (final String key in SettingsKeys.general) key: await environment.configList(name: key),
      };
      if (generation != _generation) {
        return;
      }
      userPath = path;
      userConfig = config;
    } on ZanshinFfiException catch (error, stack) {
      _log
        ..warning('reading the user config failed: ${error.code}')
        ..fine('user config failure', error, stack);
    }
    _notify();
  }

  Future<void> _readProject(int generation) async {
    final String? workspace = root;
    final SettingsRepoReads? reads = _reads;
    if (workspace == null || reads == null) {
      return;
    }
    try {
      final String path = await environment.configPath(ConfigScope.repo, workspaceRoot: workspace);
      final config = <String, List<ConfigEntry>>{
        for (final String key in SettingsKeys.project)
          key: await environment.configList(name: key, workspaceRoot: workspace),
      };
      if (generation != _generation) {
        return;
      }
      repoPath = path;
      projectConfig = config;
    } on ZanshinFfiException catch (error, stack) {
      _log
        ..warning('reading the repo config failed: ${error.code}')
        ..fine('repo config failure', error, stack);
    }
    _notify();
    await Future.wait(<Future<void>>[
      _readRemotes(reads, generation),
      _readBookmarks(reads, generation),
      for (final String term in immutableBuiltins.skip(1)) _readBuiltinMatches(reads, generation, term),
      recountImmutable(),
    ]);
  }

  Future<void> _readBuiltinMatches(SettingsRepoReads reads, int generation, String term) async {
    try {
      final List<String> names = matchNames(await reads.revsetMembers(term), term);
      if (generation != _generation) {
        return;
      }
      builtinMatches = <String, List<String>>{...builtinMatches, term: names};
    } on ZanshinFfiException catch (error) {
      _log.fine('reading $term failed: ${error.code}');
    }
    _notify();
  }

  Future<void> _readRemotes(SettingsRepoReads reads, int generation) async {
    try {
      final List<Remote> list = await reads.remotes();
      final List<String> fetch = await reads.defaultFetchRemotes();
      final List<String> push = await reads.defaultPushRemotes();
      final String? remote = fetch.firstOrNull;
      final trunk = remote == null
          ? const <String>[]
          : <String>[for (final String name in await reads.remoteBookmarks(remote)) '$name@$remote'];
      if (generation != _generation) {
        return;
      }
      remoteList = list;
      fetchDefault = fetch;
      pushDefault = push;
      trunkChoices = trunk;
    } on ZanshinFfiException catch (error) {
      // A native repository has no remotes; the rows show what they have.
      _log.fine('reading the remotes failed: ${error.code}');
    }
    _notify();
  }

  Future<void> _readBookmarks(SettingsRepoReads reads, int generation) async {
    try {
      final List<String> names = await reads.localBookmarks();
      if (generation != _generation) {
        return;
      }
      bookmarks = names;
    } on ZanshinFfiException catch (error) {
      _log.fine('reading the bookmarks failed: ${error.code}');
    }
    _notify();
  }

  /// Counts the immutable changes again (`::immutable_heads() ~ root()`, cap 10,000); a failure shows no count.
  Future<void> recountImmutable() async {
    final SettingsRepoReads? reads = _reads;
    if (reads == null) {
      return;
    }
    try {
      final RevsetCounts counts = await reads.revsetCounts(const <String>[
        '::immutable_heads() ~ root()', // l10n-ignore: jj's revset
      ], cap: 10000);
      final RevsetCount? count = counts.firstOrNull;
      if (!identical(reads, _reads)) {
        return;
      }
      immutableCount = count?.error == null ? count : null;
    } on ZanshinFfiException catch (error) {
      _log.fine('counting the immutable changes failed: ${error.code}');
      if (identical(reads, _reads)) {
        immutableCount = null;
      }
    }
    // The count shows without waiting for the heads.
    _notify();
    try {
      const heads = 'immutable_heads()'; // l10n-ignore: jj's revset
      final List<String> labels = headLabels(await reads.revsetMembers(heads));
      if (!identical(reads, _reads)) {
        return;
      }
      immutableHeadLabels = labels;
    } on ZanshinFfiException catch (error) {
      _log.fine('reading the immutable heads failed: ${error.code}');
      if (identical(reads, _reads)) {
        immutableHeadLabels = null;
      }
    }
    _notify();
  }

  /// [revset]'s own error, or null when jj resolves it (`revsetCounts`, cap 0); a failed call is its error.
  Future<String?> revsetError(String revset) async {
    final SettingsRepoReads? reads = _reads;
    if (reads == null) {
      return null;
    }
    try {
      final RevsetCount? count = (await reads.revsetCounts(<String>[revset], cap: 0)).firstOrNull;
      final ZanshinFfiException? error = count?.error;
      return error == null ? null : settingsErrorText(error);
    } on ZanshinFfiException catch (error) {
      return settingsErrorText(error);
    }
  }

  // ---- jj writes ----

  /// `jj config set --<scope> NAME VALUE`; true when it landed. A failure is the key's [errors] entry.
  Future<bool> setConfig(ConfigScope scope, String name, String value) async {
    final String? workspace = root;
    try {
      final ConfigSetResult result = await environment.configSet(scope, name, value, workspaceRoot: workspace);
      if (name == SettingsKeys.userName || name == SettingsKeys.userEmail) {
        workingCopyAuthor = result.workingCopyAuthor;
      }
    } on ZanshinFfiException catch (error) {
      errors[name] = settingsErrorText(error);
      _notify();
      return false;
    }
    await _written(scope, name);
    return true;
  }

  /// `jj config unset --<scope> NAME`; true when it landed. A failure is the key's [errors] entry.
  Future<bool> unsetConfig(ConfigScope scope, String name) async {
    try {
      await environment.configUnset(scope, name, workspaceRoot: root);
    } on ZanshinFfiException catch (error) {
      errors[name] = settingsErrorText(error);
      _notify();
      return false;
    }
    await _written(scope, name);
    return true;
  }

  Future<void> _written(ConfigScope scope, String name) async {
    errors.remove(name);
    if (SettingsKeys.graphKeys.contains(name)) {
      graph.value?.model.configChanged();
    }
    await _reread(name);
    if (name == immutableHeadsKey || name == trunkKey) {
      await recountImmutable();
    }
  }

  Future<void> _reread(String name) async {
    try {
      if (SettingsKeys.general.contains(name)) {
        userConfig = <String, List<ConfigEntry>>{...userConfig, name: await environment.configList(name: name)};
      }
      if (root case final String workspace when SettingsKeys.project.contains(name)) {
        projectConfig = <String, List<ConfigEntry>>{
          ...projectConfig,
          name: await environment.configList(name: name, workspaceRoot: workspace),
        };
      }
    } on ZanshinFfiException catch (error) {
      _log.fine('reading $name again failed: ${error.code}');
    }
    _notify();
  }

  /// The config page saved a file (Story 11.19): both tabs read everything again — the Project tab's remotes, trunk
  /// and Immutable commits page included — and the graph re-requests its layout once.
  Future<void> configFileSaved() async {
    graph.value?.model.configChanged();
    final int generation = _generation;
    await Future.wait(<Future<void>>[_readGeneral(generation), _readProject(generation)]);
  }

  /// Writes the Immutable commits page's [heads] at repo scope, unless the alias already reads so.
  Future<bool> writeImmutable(ImmutableHeads heads) {
    final String alias = heads.compose();
    if (alias == stringValue(immutableHeadsKey, project: true) ||
        (alias == builtinImmutableHeads && effective(immutableHeadsKey, project: true) == null)) {
      return Future<bool>.value(true);
    }
    return setConfig(ConfigScope.repo, immutableHeadsKey, alias);
  }

  /// Reset to jj's default: unsets the alias at repo scope.
  Future<bool> resetImmutable() => unsetConfig(ConfigScope.repo, immutableHeadsKey);

  // ---- remote verbs ----

  /// Clears the notes under the rows (a form opens).
  void clearRemoteNotes() {
    if (remoteNotes.isNotEmpty) {
      remoteNotes.clear();
      _notify();
    }
  }

  /// Runs [op]: a refusal is returned (and, for a remove, noted under its row); a landed verb re-reads the remotes
  /// here and in the project window's sync, and returns Add's duplicate-URL warning (noted under the new row).
  Future<RemoteOutcome?> runRemote(RemoteOp op) async {
    final SettingsRepoReads? reads = _reads;
    if (reads == null) {
      return null;
    }
    final int generation = _generation;
    remoteNotes.clear();
    _notify();
    final List<ZanshinWarning> warnings;
    try {
      warnings = await switch (op) {
        RemoteAdd(:final name, :final url, :final pushUrl) => reads.remoteAdd(name: name, url: url, pushUrl: pushUrl),
        RemoteRename(:final name, :final newName) => reads.remoteRename(name, newName),
        RemoteSetUrl(:final name, :final url, :final pushUrl) => reads.remoteSetUrl(
          name: name,
          url: url,
          pushUrl: pushUrl,
        ),
        RemoteRemove(:final name) => reads.remoteRemove(name),
      };
    } on ZanshinFfiException catch (error) {
      _log.fine('the remote verb failed: ${error.code}');
      if (generation != _generation) {
        return null;
      }
      final RemoteRefusal refusal = remoteRefusal(error, op.typedName);
      if (op is RemoteRemove) {
        remoteNotes[op.name] = refusal;
      }
      _notify();
      return refusal;
    }
    // The project switched while the verb ran: its results belong to the old project.
    if (generation != _generation) {
      return null;
    }
    final messages = <String>[
      for (final ZanshinWarning warning in warnings)
        if (warning.code == ZanshinWarningCode.remoteUrlDuplicate) warning.message,
    ];
    // CLI add.rs:111-115 @ v0.47.0 prints the hint once after the warnings.
    final RemoteWarning? warning = op is RemoteAdd && messages.isNotEmpty
        ? RemoteWarning(
            messages.join('\n'),
            hint:
                'If this was a mistake, run `jj git remote remove ${jjRefSymbol(op.name)}`.', // l10n-ignore: jj's text
          )
        : null;
    if (warning != null) {
      remoteNotes[op.name] = warning;
    }
    unawaited(graph.value?.sync?.reloadRemotes());
    await _readRemotes(reads, generation);
    // jj rewrites a `trunk()` naming the remote in the repo config on rename and remove.
    if (op is RemoteRename || op is RemoteRemove) {
      await _reread(trunkKey);
      await recountImmutable();
    }
    return warning;
  }

  /// Remove…: the sheet asks about [name].
  void askRemove(String name) {
    remoteNotes.clear();
    removing = name;
    removeClosing = false;
    _notify();
  }

  /// The sheet's answer: it leaves, and [confirm] removes the remote.
  void answerRemove({required bool confirm}) {
    final String? name = removing;
    if (name == null || removeClosing) {
      return;
    }
    removeClosing = true;
    _notify();
    if (confirm) {
      unawaited(runRemote(RemoteRemove(name)));
    }
  }

  /// The sheet's exit ended.
  void removeClosed() {
    removing = null;
    removeClosing = false;
    _notify();
  }

  // ---- pending text writes ----

  /// Registers [flush], [owner]'s pending write, for the window's close.
  void registerFlush(Object owner, Future<void> Function() flush) => _flushes[owner] = flush;

  /// Removes [owner]'s pending write.
  void unregisterFlush(Object owner) => _flushes.remove(owner);

  /// Runs every pending write (a valid one writes, an invalid one is dropped).
  Future<void> flushPending() async {
    for (final flush in List<Future<void> Function()>.of(_flushes.values)) {
      try {
        await flush();
        // One failing write must not keep the window from closing; it is logged and the others still run.
      } on Object catch (error, stack) {
        _log.severe('a pending Settings write failed', error, stack);
      }
    }
  }

  // ---- app preferences ----

  /// Settings › General's preferences.
  AppSettings get preferences => store.value;

  /// Writes [change] to the store; a failed write keeps the value for the session (the store logs it).
  void updatePreferences(AppSettings Function(AppSettings settings) change) =>
      unawaited(store.update(change).onError<Object>((_, _) {}));

  /// The open project's "Check for remote changes".
  RemotePollSetting get remotePoll => session.current?.remotePoll ?? RemotePollSetting.fifteenMinutes;

  /// Sets the open project's "Check for remote changes".
  void setRemotePoll(RemotePollSetting poll) {
    if (root case final String path) {
      unawaited(session.registry.setRemotePoll(path, poll));
    }
  }
}
