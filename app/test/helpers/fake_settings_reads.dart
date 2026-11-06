// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:zanshin/src/features/settings/immutable_heads.dart';
import 'package:zanshin/src/features/settings/settings_view_model.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// The Settings window's repository reads for tests: two remotes, `origin` the default fetch remote, `main` and `dev`
/// on it; [count], [errors] and [members] scripted. The remote verbs log their call in [verbs] and change [remoteList]
/// unless [verbError] fails them; an add answers [addWarnings].
class FakeSettingsReads implements SettingsRepoReads {
  var count = const RevsetCount(n: 14, capped: false, error: null);

  /// Expressions whose count is an error.
  final errors = <String, ZanshinFfiException>{};

  /// Each revset's members; an unscripted revset fails like an unread repository.
  final members = <String, List<RevsetMember>>{};

  /// The remotes.
  var remoteList = <Remote>[
    const Remote(name: 'origin', url: 'git@github.com:ralph/myapp.git', pushUrl: null),
    const Remote(name: 'upstream', url: 'https://github.com/acme/myapp.git', pushUrl: null),
  ];

  /// The default fetch remotes.
  var fetchDefault = const <String>['origin'];

  /// Every remote verb, as `add <name> <url> <push>`, `rename <old> <new>`, `set-url <name> <url> <push>`,
  /// `remove <name>`.
  final verbs = <String>[];

  /// While set, a remote verb waits for it.
  Completer<void>? verbGate;

  /// While set, a remote verb fails with it.
  ZanshinFfiException? verbError;

  /// What an add warns.
  var addWarnings = const <ZanshinWarning>[];

  @override
  Future<List<Remote>> remotes() async => List<Remote>.of(remoteList);

  Future<List<ZanshinWarning>> _verb(String call, void Function() apply, [List<ZanshinWarning>? warnings]) async {
    verbs.add(call);
    await verbGate?.future;
    final ZanshinFfiException? error = verbError;
    if (error != null) {
      throw error;
    }
    apply();
    return warnings ?? const <ZanshinWarning>[];
  }

  @override
  Future<List<ZanshinWarning>> remoteAdd({required String name, required String url, String? pushUrl}) => _verb(
    'add $name $url $pushUrl',
    () => remoteList = <Remote>[...remoteList, Remote(name: name, url: url, pushUrl: pushUrl)],
    addWarnings,
  );

  @override
  Future<List<ZanshinWarning>> remoteRename(String oldName, String newName) => _verb(
    'rename $oldName $newName',
    () => remoteList = <Remote>[
      for (final Remote r in remoteList)
        if (r.name == oldName) Remote(name: newName, url: r.url, pushUrl: r.pushUrl) else r,
    ],
  );

  @override
  Future<List<ZanshinWarning>> remoteSetUrl({required String name, String? url, String? pushUrl}) => _verb(
    'set-url $name $url $pushUrl',
    () => remoteList = <Remote>[
      for (final Remote r in remoteList)
        if (r.name == name) Remote(name: name, url: url ?? r.url, pushUrl: pushUrl ?? r.pushUrl) else r,
    ],
  );

  @override
  Future<List<ZanshinWarning>> remoteRemove(String name) => _verb(
    'remove $name',
    () => remoteList = <Remote>[
      for (final Remote r in remoteList)
        if (r.name != name) r,
    ],
  );

  @override
  Future<List<String>> defaultFetchRemotes() async => fetchDefault;

  @override
  Future<List<String>> defaultPushRemotes() async => const <String>['upstream'];

  @override
  Future<List<String>> remoteBookmarks(String remote) async => const <String>['main', 'dev'];

  @override
  Future<List<String>> localBookmarks() async => const <String>['develop', 'main'];

  @override
  Future<RevsetCounts> revsetCounts(List<String> expressions, {required int cap}) async => RevsetCounts(
    <RevsetCount>[
      for (final String expression in expressions)
        if (errors[expression] case final ZanshinFfiException error)
          RevsetCount(n: 0, capped: false, error: error)
        else
          count,
    ],
    const <ZanshinWarning>[],
  );

  @override
  Future<List<RevsetMember>> revsetMembers(String revset) async =>
      members[revset] ?? (throw const ZanshinFfiException('jj.revset_resolution_error', 'unscripted'));
}
