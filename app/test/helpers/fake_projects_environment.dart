// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zanshin/src/features/projects/projects_environment.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// [ProjectsEnvironment] for the Projects window tests: scripted versions and identity (or an identity read that
/// throws), the folder picker's answers in order, and logs of every picker call and every Reveal in Finder.
class FakeProjectsEnvironment implements ProjectsEnvironment {
  /// What [appVersion] answers.
  String? version = '2026.9.1 · Build 1';

  /// What [jjLibVersion] answers.
  String? jjLib = '0.46.0';

  /// What [identity] answers.
  var identityAnswer = JjIdentity(name: 'Ralph Stein', email: 'ralph@example.com');

  /// When set, [identity] throws it.
  ZanshinFfiException? identityFailure;

  /// The folder picker's answers, first first; an empty list answers null (cancelled).
  final pickerAnswers = <String?>[];

  /// Every picker call as `<viewId> <initialDirectory> <prompt>`.
  final pickerCalls = <String>[];

  /// Every revealed path.
  final revealed = <String>[];

  /// Every identity read's workspace root.
  final identityReads = <String?>[];

  @override
  var home = '/Users/me';

  @override
  Future<String?> appVersion() async => version;

  @override
  Future<String?> jjLibVersion() async => jjLib;

  @override
  Future<JjIdentity> identity({String? workspaceRoot}) async {
    identityReads.add(workspaceRoot);
    final ZanshinFfiException? failure = identityFailure;
    if (failure != null) {
      throw failure;
    }
    return identityAnswer;
  }

  @override
  Future<String?> chooseDirectory({required int viewId, String? initialDirectory, String? prompt}) async {
    pickerCalls.add('$viewId $initialDirectory $prompt');
    return pickerAnswers.isEmpty ? null : pickerAnswers.removeAt(0);
  }

  @override
  Future<void> revealInFinder(String path) async => revealed.add(path);

  // ---- config (Settings, Story 11.7) ----

  /// What [configList] answers, by name; a missing name answers no entry.
  final configEntries = <String, List<ConfigEntry>>{};

  /// What [configPath] answers, by scope.
  final configPaths = <ConfigScope, String>{
    ConfigScope.user: '/Users/me/.config/jj/config.toml',
    ConfigScope.repo: '/Users/me/.config/jj/repos/abc/config.toml',
  };

  /// What [configSet] answers as `@`'s author.
  WorkingCopyAuthor? workingCopyAuthor;

  /// When set, [configSet] and [configUnset] throw it.
  ZanshinFfiException? configFailure;

  /// Every write as `set <scope> <name> <value>` or `unset <scope> <name>`.
  final configCalls = <String>[];

  final _writes = ConfigWrites();

  @override
  Listenable get configWrites => _writes;

  @override
  Future<List<ConfigEntry>> configList({required String name, String? workspaceRoot}) async => <ConfigEntry>[
    for (final ConfigEntry entry in configEntries[name] ?? const <ConfigEntry>[])
      if (workspaceRoot != null ||
          (entry.source != ConfigValueSource.repo && entry.source != ConfigValueSource.workspace))
        entry,
  ];

  @override
  Future<ConfigSetResult> configSet(ConfigScope scope, String name, String value, {String? workspaceRoot}) async {
    configCalls.add('set ${scope.name} $name $value');
    if (configFailure case final ZanshinFfiException failure) {
      throw failure;
    }
    final ConfigValueSource source = _source(scope);
    configEntries[name] = <ConfigEntry>[
      ...?configEntries[name]?.where((entry) => entry.source != source),
      ConfigEntry(
        name: name,
        // The fake stores strings quoted, as `jj config list` reads them back.
        value: value.startsWith('[') ? value : '"${value.replaceAll('"', r'\"')}"',
        source: source,
        path: configPaths[scope],
        overridden: false,
      ),
    ]..sort((a, b) => a.source.index.compareTo(b.source.index));
    _writes.fire();
    return ConfigSetResult(path: configPaths[scope] ?? '', workingCopyAuthor: workingCopyAuthor, precondition: null);
  }

  @override
  Future<void> configUnset(ConfigScope scope, String name, {String? workspaceRoot}) async {
    configCalls.add('unset ${scope.name} $name');
    if (configFailure case final ZanshinFfiException failure) {
      throw failure;
    }
    final ConfigValueSource source = _source(scope);
    configEntries[name] = <ConfigEntry>[...?configEntries[name]?.where((entry) => entry.source != source)];
    _writes.fire();
  }

  static ConfigValueSource _source(ConfigScope scope) => switch (scope) {
    ConfigScope.user => ConfigValueSource.user,
    ConfigScope.repo => ConfigValueSource.repo,
    ConfigScope.workspace => ConfigValueSource.workspace,
  };

  @override
  Future<String> configPath(ConfigScope scope, {String? workspaceRoot}) async => configPaths[scope] ?? '';

  // ---- config file (Story 11.19) ----

  /// What [configFileRead] answers as the text, by scope; a missing scope is an empty file.
  final configFileTexts = <ConfigScope, String>{};

  /// When set, [configFileRead] throws it.
  ZanshinFfiException? configFileReadFailure;

  /// When set, [configFileWrite] throws it (nothing is written).
  ZanshinFfiException? configFileWriteFailure;

  /// Every landed write as `<path> <text>`.
  final configFileWrites = <String>[];

  /// Runs on every landed write with its path and text (before [configWrites] fires).
  void Function(String path, String text)? onConfigFileWrite;

  /// The [fileChanges] streams, by path; a test adds to one to report a change on disk.
  final fileChangeControllers = <String, StreamController<void>>{};

  @override
  Future<ConfigFileText> configFileRead(ConfigScope scope, {String? workspaceRoot}) async {
    if (configFileReadFailure case final ZanshinFfiException failure) {
      throw failure;
    }
    return ConfigFileText(path: configPaths[scope] ?? '', text: configFileTexts[scope] ?? '');
  }

  @override
  Future<void> configFileWrite(String path, String text, {String? workspaceRoot}) async {
    if (configFileWriteFailure case final ZanshinFfiException failure) {
      throw failure;
    }
    configFileWrites.add('$path $text');
    for (final MapEntry<ConfigScope, String> entry in configPaths.entries) {
      if (entry.value == path) {
        configFileTexts[entry.key] = text;
      }
    }
    onConfigFileWrite?.call(path, text);
    _writes.fire();
  }

  @override
  Stream<void> fileChanges(String path) => (fileChangeControllers[path] ??= StreamController<void>.broadcast()).stream;
}
