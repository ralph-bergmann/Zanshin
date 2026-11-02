// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

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

/// What Settings reads of the open repository besides the config (a port, so tests pass a fake).
abstract interface class SettingsRepoReads {
  /// The remotes' names (`jj git remote list`).
  Future<List<String>> remoteNames();

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
}

/// [SettingsRepoReads] over an open repository's handle.
class RepoSettingsReads implements SettingsRepoReads {
  /// The reads of [_repo].
  RepoSettingsReads(this._repo);

  final ProjectRepo _repo;

  @override
  Future<List<String>> remoteNames() async => <String>[
    for (final Remote remote in await _repo.handle.remotes()) remote.name,
  ];

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
}

/// The text of an [error] for a row.
String settingsErrorText(ZanshinFfiException error) => error.context ?? error.code;

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

  /// The remotes' names.
  var remotes = const <String>[];

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
    remotes = const <String>[];
    fetchDefault = const <String>[];
    pushDefault = const <String>[];
    trunkChoices = const <String>[];
    bookmarks = const <String>[];
    immutableCount = null;
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
      recountImmutable(),
    ]);
  }

  Future<void> _readRemotes(SettingsRepoReads reads, int generation) async {
    try {
      final List<String> names = await reads.remoteNames();
      final List<String> fetch = await reads.defaultFetchRemotes();
      final List<String> push = await reads.defaultPushRemotes();
      final String? remote = fetch.firstOrNull;
      final trunk = remote == null
          ? const <String>[]
          : <String>[for (final String name in await reads.remoteBookmarks(remote)) '$name@$remote'];
      if (generation != _generation) {
        return;
      }
      remotes = names;
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
