// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/bookmarks/bookmark_list_model.dart';
import 'package:zanshin/src/features/bookmarks/bookmark_list_view.dart';
import 'package:zanshin/src/features/bookmarks/ref_delete.dart';
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
import 'package:zanshin_ui/zanshin_ui.dart';

import '../graph/fake_graph_search_source.dart';
import '../graph/fake_graph_source.dart';

/// The "Bookmarks" folder (Story 10.14): the rail item's hover preview and pinned panel over a fake bookmark list and
/// a five-change graph — every state of the state column, a row beyond the view (dimmed), a deleted one. Story 10.44:
/// the panel's tree with a filter, rows with their hover-only buttons shown, the Tags preview and panel, and the delete
/// sheet for a bookmark and for a tag on two remotes.
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
  filtered('Panel, filtered'),
  rowButtons('Row buttons'),
  empty('Empty'),
  stale('Stale'),
  tagsPreview('Tags preview'),
  tagsPanel('Tags panel'),
  deleteBookmark('Delete sheet, bookmark'),
  deleteTag('Delete sheet, tag on two remotes');

  const _Demo(this.label);

  final String label;

  bool get tags => this == tagsPreview || this == tagsPanel;
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

/// The tags, as `RepoTagListSource` maps them: no distances.
List<Bookmark> _tags() {
  Bookmark tag(String name, String target, {String? remote, bool tracked = true, bool synced = true}) => tagRow(
    Tag(
      name: name,
      target: target,
      kind: remote == null ? const LocalTag() : RemoteTag(remote, tracked: tracked),
      conflicted: false,
      synced: synced,
    ),
  );
  return <Bookmark>[
    tag('v1.4.2', 'kxqpsytn'),
    tag('v1.5.0', 'ovknlmro'),
    tag('v1.5.0', 'ovknlmro', remote: 'origin'),
    tag('v1.5.0-rc1', 'vruxwmqvz'),
    tag('v1.5.0-rc1', 'vruxwmqvz', remote: 'origin'),
    tag('v1.5.0-rc1', 'vruxwmqvz', remote: 'upstream'),
    tag('nightly/2026-11-15', 'wkmxrlpq', remote: 'origin', tracked: false, synced: false),
    tag('nightly/2026-11-16', 'wkmxrlpq'),
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
    _deletes = RefDeleteFlow(graph: _graph);
    final source = _DemoSource(
      switch (widget.demo) {
        _Demo.empty => const <Bookmark>[],
        _ when widget.demo.tags => _tags(),
        _ => _bookmarks(),
      },
      stale: widget.demo == _Demo.stale,
    );
    _model = widget.demo.tags
        ? TagListModel(source, search: _search, deletes: _deletes)
        : BookmarkListModel(source, search: _search, deletes: _deletes);
    if (widget.demo == _Demo.filtered) {
      _model.filter = 'fe';
    }
    if (widget.demo == _Demo.stale) {
      _model.addListener(_goStale);
    }
  }

  late final RefDeleteFlow _deletes;

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
    _deletes.dispose();
    _search.dispose();
    _graph.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.demo == _Demo.deleteBookmark) {
      return _sheet(
        const RefDeleteRequest(kind: RefKind.bookmark, name: 'feature/auth-flow', remotes: <String>['origin']),
      );
    }
    if (widget.demo == _Demo.deleteTag) {
      return _sheet(
        const RefDeleteRequest(kind: RefKind.tag, name: 'v1.5.0-rc1', remotes: <String>['origin', 'upstream']),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[_model, _graph]),
      builder: (context, _) {
        final ShellRailItem item = _model is TagListModel
            ? tagsRailItem(context.l10n, _model)
            : bookmarksRailItem(context.l10n, _model);
        return Center(
          child: switch (widget.demo) {
            _Demo.preview || _Demo.tagsPreview => SizedBox(width: 290, child: RailPreview(item: item, closing: false)),
            _Demo.rowButtons => SizedBox(width: 300, child: _rowButtons()),
            _ => SizedBox(
              width: 300,
              height: 640,
              child: RefDeleteHost(
                flow: _deletes,
                child: PinnedPanel(item: item, onClose: () {}),
              ),
            ),
          },
        );
      },
    );
  }

  /// A local, a tracked and an untracked remote row with their hover-only buttons shown.
  Widget _rowButtons() {
    final List<BookmarkRow> rows = _model.rows;
    return ZsIsland(
      shape: ZsIslandShape.panel,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final String display in <String>['main', 'main@origin', 'release/1.5.x@origin'])
              if (rows.indexWhere((r) => r.display == display) case final int i when i >= 0)
                BookmarkRowTile(row: rows[i], index: i, model: _model, label: display, showActions: true),
          ],
        ),
      ),
    );
  }

  Widget _sheet(RefDeleteRequest request) => RefDeleteSheet(request: request, onConfirm: (_) {}, onCancel: () {});
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

  @override
  Future<AbsorbResult> absorb(String from) async => throw const ZanshinFfiException('jj.demo', 'a demo');
}
