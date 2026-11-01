// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/bookmarks/bookmark_list_model.dart';
import 'package:zanshin/src/features/bookmarks/bookmark_list_view.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_search_controller.dart';
import 'package:zanshin/src/features/graph/graph_search_store.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/rail_preview.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../graph/fake_graph_search_source.dart';
import '../graph/fake_graph_source.dart';

/// The "Bookmarks" folder (Story 10.14): the rail item's hover preview and pinned panel over a fake bookmark list and
/// a five-change graph — every state of the state column, a row beyond the view (dimmed), a deleted one.
final bookmarksFolder = WidgetbookFolder(
  name: 'Bookmarks',
  children: <WidgetbookNode>[
    WidgetbookComponent(
      name: 'Bookmarks',
      useCases: <WidgetbookUseCase>[
        for (final _Demo demo in _Demo.values)
          WidgetbookUseCase(
            name: demo.label,
            builder: (context) => _DemoHost(key: ValueKey<_Demo>(demo), demo: demo),
          ),
      ],
    ),
  ],
);

enum _Demo {
  preview('Preview'),
  panel('Panel'),
  empty('Empty'),
  stale('Stale');

  const _Demo(this.label);

  final String label;
}

const _changes = <String>['wkmxrlpq', 'ovknlmro', 'vruxwmqvz', 'kxqpsytn', 'qzpwolnt'];
const _subjects = <String>['Graph lanes', 'Fix cache eviction', '', 'Onboarding copy', 'Release 1.5'];

/// Four of the changes, newest first, at [op] (@ the newest); [all] adds `tlxsuorz` (the release branch).
GraphLayout _layout({required bool all, String op = 'op1'}) {
  final keys = <String>[..._changes.take(4), if (all) 'tlxsuorz'];
  final int n = keys.length;
  return RecordedGraphLayout(
    mode: GraphMode.compact,
    unit: 1,
    rows: n,
    colCount: 1,
    keys: keys,
    cols: Int32List(n),
    nodeRows: Int32List.fromList(<int>[for (var i = 0; i < n; i++) n - 1 - i]),
    // One parent each, none for the oldest.
    parentCounts: Int32List(n)..fillRange(0, n - 1, 1),
    elided: Uint8List(n),
    edgeChildren: Int32List.fromList(<int>[for (var i = 0; i + 1 < n; i++) i]),
    edgeParents: Int32List.fromList(<int>[for (var i = 0; i + 1 < n; i++) i + 1]),
    edgeKinds: <GraphEdgeKind>[for (var i = 0; i + 1 < n; i++) GraphEdgeKind.direct],
    edgeShapes: <GraphEdgeShape>[for (var i = 0; i + 1 < n; i++) GraphEdgeShape.straight],
    workingCopyIndex: 0,
    operationId: op,
    commitIds: <String>[for (final String k in keys) 'c$k'],
    changeIdPrefixLengths: Int32List.fromList(<int>[for (final _ in keys) 2]),
  );
}

List<Bookmark> _bookmarks() {
  Bookmark local(String name, String? target, {bool synced = true, bool conflicted = false}) =>
      Bookmark(name: name, target: target, kind: const LocalBookmark(), conflicted: conflicted, synced: synced);
  Bookmark remote(String name, String? target, {bool tracked = true, bool synced = true, int? ahead, int? behind}) =>
      Bookmark(
        name: name,
        target: target,
        kind: RemoteBookmark(
          'origin',
          tracked: tracked,
          ahead: ahead == null ? null : RefDistance(lower: ahead, upper: ahead),
          behind: behind == null ? null : RefDistance(lower: behind, upper: behind),
        ),
        conflicted: false,
        synced: synced,
      );
  return <Bookmark>[
    local('feat/graph-lanes', 'wkmxrlpq', synced: false),
    remote('feat/graph-lanes', 'ovknlmro', synced: false, ahead: 0, behind: 2),
    local('fix/cache', 'ovknlmro', synced: false),
    remote('fix/cache', 'vruxwmqvz', synced: false, ahead: 1, behind: 0),
    local('main', 'kxqpsytn'),
    remote('main', 'kxqpsytn'),
    local('old-spike', null, synced: false),
    remote('old-spike', 'vruxwmqvz', synced: false),
    remote('release/1.5.x', 'tlxsuorz', tracked: false, synced: false),
    local('wip', 'vruxwmqvz'),
  ];
}

class _DemoHost extends StatefulWidget {
  const _DemoHost({required this.demo, super.key});

  final _Demo demo;

  @override
  State<_DemoHost> createState() => _DemoHostState();
}

class _DemoHostState extends State<_DemoHost> {
  final _graph = GraphViewModel();
  late final FakeGraphSource _source;
  late final GraphSearchController _search;
  late final BookmarkListModel _model;
  var _op = 'op1';

  @override
  void initState() {
    super.initState();
    _source = FakeGraphSource((request) => _layout(all: request.revset == 'all()', op: _op));
    _search = GraphSearchController(
      model: _graph,
      source: FakeGraphSearchSource(() => _layout(all: true)),
      store: MemoryGraphSearchStore(),
    );
    _graph.init(_source, actions: _DemoActions(), revset: _search.revset);
    _model = BookmarkListModel(
      _DemoSource(widget.demo == _Demo.empty ? const <Bookmark>[] : _bookmarks(), stale: widget.demo == _Demo.stale),
      search: _search,
    );
    if (widget.demo == _Demo.stale) {
      _model.addListener(_goStale);
    }
  }

  /// The stale demo: after the first read, an operation the list's read is refused at, then the graph's refusal too.
  void _goStale() {
    if (_model.loaded && _op == 'op1') {
      _op = 'op2';
      _graph.reload();
    } else if (_model.stale && _source.staleCause == null) {
      _model.removeListener(_goStale);
      _source.staleCause = 'stale';
      _graph.reload();
    }
  }

  @override
  void dispose() {
    _model
      ..removeListener(_goStale)
      ..dispose();
    _search.dispose();
    _graph.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _model,
    builder: (context, _) {
      final ShellRailItem item = bookmarksRailItem(context.l10n, _model);
      return Center(
        child: widget.demo == _Demo.preview
            ? SizedBox(width: 290, child: RailPreview(item: item, closing: false))
            : SizedBox(
                width: 300,
                height: 640,
                child: PinnedPanel(item: item, onClose: () {}),
              ),
      );
    },
  );
}

/// The demo list: [list], or jj's stale refusal after one good read.
class _DemoSource implements BookmarkListSource {
  _DemoSource(this.list, {required this.stale});

  final List<Bookmark> list;
  final bool stale;
  var _reads = 0;

  @override
  Future<List<Bookmark>> bookmarks() async {
    if (stale && _reads++ > 0) {
      throw const ZanshinFfiException('jj.stale_working_copy');
    }
    return list;
  }

  @override
  Future<FoundChanges> findChanges(
    String operationId,
    String expression, {
    required int limit,
    required String shortPrefixes,
  }) async => FoundChanges(
    entries: <FoundChange>[
      for (final Match m in RegExp(r'change_id\(([^)]*)\)').allMatches(expression))
        FoundChange(commitId: 'c${m[1]}', changeId: m[1]!, commitPrefixLen: 4, changePrefixLen: 2),
    ],
    truncated: false,
    warnings: const <ZanshinWarning>[],
  );

  @override
  Future<Map<String, GraphCommitContent>> content(String operationId, List<String> commitIds) async =>
      <String, GraphCommitContent>{
        for (final String id in commitIds)
          id: GraphCommitContent(
            subject: switch (_changes.indexOf(id.substring(1))) {
              -1 => 'Release 1.5', // l10n-ignore: demo data
              final int i => _subjects[i],
            },
          ),
      };
}

/// A runner that runs nothing.
class _DemoActions implements GraphActions {
  @override
  Future<String> headOpId() async => 'op1';

  @override
  Future<MutationResult> run(GraphAction action) async => throw const ZanshinFfiException('jj.demo', 'a demo');
}
