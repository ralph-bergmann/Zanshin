// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:zanshin/src/features/bookmarks/bookmark_list_model.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_search_controller.dart';
import 'package:zanshin/src/features/graph/graph_search_store.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../features/graph/graph_harness.dart';
import 'fake_graph_search_source.dart';
import 'scripted_graph_source.dart';

/// A [BookmarkListSource] a test scripts: [list] answers `bookmarks()` (or [error] is thrown), finds resolve
/// `change_id(x)` through [commits], and every call is recorded.
class FakeBookmarkListSource implements BookmarkListSource {
  FakeBookmarkListSource(this.list);

  /// The rows `bookmarks()` answers.
  List<Bookmark> list;

  /// Thrown by the next `bookmarks()` calls while set.
  ZanshinFfiException? error;

  /// While set, `bookmarks()` waits on it.
  Completer<void>? gate;

  /// The commits of each change id at any operation; a change id not listed has `c<id>`.
  var commits = <String, List<String>>{};

  /// How many times `bookmarks()` was read.
  var reads = 0;

  /// Every find: its operation and expression.
  final finds = <({String operationId, String expression})>[];

  /// Every content call's operation and commit ids.
  final contents = <({String operationId, List<String> commitIds})>[];

  @override
  Future<List<Bookmark>> bookmarks() async {
    reads++;
    await gate?.future;
    if (error case final ZanshinFfiException error) {
      throw error;
    }
    return list;
  }

  @override
  Future<FoundChanges> findChanges(
    String operationId,
    String expression, {
    required int limit,
    required String shortPrefixes,
  }) async {
    finds.add((operationId: operationId, expression: expression));
    return FoundChanges(
      entries: <FoundChange>[
        for (final Match m in RegExp(r'change_id\(([^)]*)\)').allMatches(expression))
          for (final String commit in commits[m[1]!] ?? <String>['c${m[1]}'])
            FoundChange(commitId: commit, changeId: m[1]!, commitPrefixLen: 4, changePrefixLen: 3),
      ],
      truncated: false,
      warnings: const <ZanshinWarning>[],
    );
  }

  @override
  Future<Map<String, GraphCommitContent>> content(String operationId, List<String> commitIds) async {
    contents.add((operationId: operationId, commitIds: commitIds));
    return <String, GraphCommitContent>{
      for (final String id in commitIds) id: GraphCommitContent(subject: id == 'cempty' ? '' : 'about $id'),
    };
  }
}

/// A local row [name] on [target].
Bookmark localRow(String name, String? target, {bool synced = true, bool conflicted = false}) =>
    Bookmark(name: name, target: target, kind: const LocalBookmark(), conflicted: conflicted, synced: synced);

/// A remote row [name]@[remote] on [target].
Bookmark remoteRow(
  String name,
  String remote,
  String? target, {
  bool tracked = true,
  bool synced = true,
  RefDistance? ahead,
  RefDistance? behind,
}) => Bookmark(
  name: name,
  target: target,
  kind: RemoteBookmark(remote, tracked: tracked, ahead: ahead, behind: behind),
  conflicted: false,
  synced: synced,
);

/// The default view: `k0` (@) … `k2`, newest first, at `op1`; `all()` adds `hid` (and whatever [extra] names) at
/// `op1`. Commit ids are `c<key>`, prefixes 2.
GraphLayout bookmarkLayout(GraphRequest request, {List<String> extra = const <String>[], String op = 'op1'}) {
  final keys = <String>[
    'k0',
    'k1',
    'k2',
    if (request.revset == 'all()') ...<String>['hid', ...extra],
  ];
  return handLayout(
    <(String, int, int)>[for (var i = 0; i < keys.length; i++) (keys[i], keys.length - 1 - i, 0)],
    edges: <(int, int)>[for (var i = 0; i + 1 < keys.length; i++) (i, i + 1)],
    workingCopy: 0,
    commitIds: <String>[for (final String k in keys) 'c$k'],
    prefixLengths: <int>[for (final _ in keys) 2],
    operationId: op,
    contents: <GraphCommitContent?>[for (final String k in keys) GraphCommitContent(subject: 'card $k')],
  );
}

/// The graph, its search and the list over [source], wired as the project window wires them.
class BookmarkRig {
  BookmarkRig(this.source, {GraphLayout Function(GraphRequest request)? respond}) {
    graphSource.respond = respond ?? bookmarkLayout;
    search = GraphSearchController(model: graph, source: FakeGraphSearchSource(), store: store);
    graph.init(graphSource, actions: actions, clock: () => DateTime.utc(2026, 11), revset: search.revset);
    model = BookmarkListModel(source, search: search);
  }

  final FakeBookmarkListSource source;
  final graphSource = ScriptedGraphSource();
  final graph = GraphViewModel();
  final store = MemoryGraphSearchStore();
  final actions = RecordingGraphActions();
  late final GraphSearchController search;
  late final BookmarkListModel model;

  void dispose() {
    model.dispose();
    search.dispose();
    graph.dispose();
  }
}

/// [GraphActions] recording every action; each runs and writes `op2`.
class RecordingGraphActions implements GraphActions {
  final ran = <GraphAction>[];

  @override
  Future<String> headOpId() async => 'op1';

  @override
  Future<MutationResult> run(GraphAction action) async {
    ran.add(action);
    return const MutationResult(
      newOpId: 'op2',
      newChangeIds: <String>[],
      abandonedChangeIds: <String>[],
      workingCopyChangeId: null,
      finish: null,
    );
  }
}
