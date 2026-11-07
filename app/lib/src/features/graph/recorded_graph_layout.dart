// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'graph_layout.dart';

/// An array-backed [GraphLayout]: the recorded layouts (Story 10.1 item 13) and the synthetic scale fixtures.
///
/// It stores what a source computed and never lays anything out itself; the CSR child ranges are an index over the
/// given edges.
class RecordedGraphLayout extends GraphLayout {
  /// A layout from typed arrays, one entry per node or edge. Edges must be ordered by child ascending.
  RecordedGraphLayout({
    required this.mode,
    required this.unit,
    required this.rows,
    required this.colCount,
    required List<String> keys,
    required Int32List cols,
    required Int32List nodeRows,
    required Int32List parentCounts,
    required Uint8List elided,
    required Int32List edgeChildren,
    required Int32List edgeParents,
    required List<GraphEdgeKind> edgeKinds,
    required List<GraphEdgeShape> edgeShapes,
    List<int?>? timestamps,
    List<int>? bucketValues,
    Int32List? bucketFirstRows,
    Int32List? bucketLastRows,
    this.utcOffsetMinutes = 0,
    this.rootIndex,
    this.workingCopyIndex,
    this.totalCount,
    this.operationId,
    List<String>? changeIds,
    List<String>? commitIds,
    Int32List? changeIdPrefixLengths,
    List<int?>? changeOffsets,
    Uint8List? flags,
    List<List<GraphRef>>? refs,
    List<List<String>>? workingCopies,
    List<GraphCommitContent?>? contents,
    this.workspaceName,
    List<List<int>> runMembers = const <List<int>>[],
    List<int?>? runStackNodes,
    this.breaks = const <GraphBreak>[],
  }) : _runMembers = runMembers,
       _runStackNodes = runStackNodes ?? List<int?>.filled(runMembers.length, null),
       _keys = keys,
       _changeIds = changeIds,
       _commitIds = commitIds,
       _givenPrefixLengths = changeIdPrefixLengths,
       _changeOffsets = changeOffsets,
       _flags = flags,
       _refs = refs,
       _workingCopies = workingCopies,
       _contents = contents,
       _cols = cols,
       _rows = nodeRows,
       _parentCounts = parentCounts,
       _elided = elided,
       _timestamps = timestamps,
       _edgeChildren = edgeChildren,
       _edgeParents = edgeParents,
       _edgeKinds = edgeKinds,
       _edgeShapes = edgeShapes,
       _bucketValues = bucketValues ?? const <int>[],
       _bucketFirstRows = bucketFirstRows ?? Int32List(0),
       _bucketLastRows = bucketLastRows ?? Int32List(0),
       version = nextGraphLayoutVersion() {
    final int n = keys.length;
    final int e = edgeChildren.length;
    assert(cols.length == n && nodeRows.length == n && parentCounts.length == n && elided.length == n);
    assert(timestamps == null || timestamps.length == n);
    assert(changeIds == null || changeIds.length == n);
    assert(commitIds == null || commitIds.length == n);
    assert(changeIdPrefixLengths == null || changeIdPrefixLengths.length == n);
    assert(changeOffsets == null || changeOffsets.length == n);
    assert(flags == null || flags.length == n);
    assert(refs == null || refs.length == n);
    assert(workingCopies == null || workingCopies.length == n);
    assert(contents == null || contents.length == n);
    assert(edgeParents.length == e && edgeKinds.length == e && edgeShapes.length == e);
    assert(_bucketFirstRows.length == _bucketValues.length && _bucketLastRows.length == _bucketValues.length);
    for (var i = 0; i < n; i++) {
      _indexOfKey[keys[i]] = i;
    }
    assert(_runStackNodes.length == runMembers.length);
    _runOf = Int32List(n)..fillRange(0, n, -1);
    for (var r = 0; r < runMembers.length; r++) {
      for (final int member in runMembers[r]) {
        _runOf[member] = r;
      }
      final int? stack = _runStackNodes[r];
      if (stack != null) {
        _runOf[stack] = r;
        _stackCount++;
      }
    }
    _edges = GraphEdgeIndex.build(edgeChildren, edgeParents, n);
  }

  /// Joins a docs/graph-layout.md §2 input (the view facts: `key` ?? `id`, `parent_count` ?? the parent entries,
  /// `working_copy == "this"`, a Missing parent, `ts_ms`) with the engine's §3 output for it (rows, unit, lanes,
  /// columns, edges with their routes, buckets). `immutable` goes into the flags (the root is immutable); the
  /// recordings carry no content and no refs, so [content] and [refs] may supply them per node. A grouped output
  /// (format 4, `--stacks`, Story 10.17) carries n + S nodes and `runs`: a folded member gets row and column −1, and
  /// each stack node the key [graphStackKey] of its oldest member, its newest member's timestamp, one parent, and the
  /// immutable flag when every member has it. [operationId] pins the layout to an operation, as a worker layout is
  /// (the search's counts and lookups need one); [totalCount] is `|all()|` as a worker layout carries it.
  factory RecordedGraphLayout.fromSpec(
    String inputJson,
    String outputJson, {
    GraphCommitContent? Function(int node, String key)? content,
    List<GraphRef> Function(int node, String key)? refs,
    String? operationId,
    int? totalCount,
  }) {
    final input = jsonDecode(inputJson) as Map<String, Object?>;
    final output = jsonDecode(outputJson) as Map<String, Object?>;
    final inNodes = input['nodes']! as List<Object?>;
    final outNodes = output['nodes']! as List<Object?>;
    // Format 4 (§3 amended, Story 4.13): n + S nodes, a folded member null, then the stack nodes in run order.
    final runMembers = <List<int>>[];
    final runStackNodes = <int?>[];
    for (final Object? entry in (output['runs'] as List<Object?>?) ?? const <Object?>[]) {
      final run = entry! as Map<String, Object?>;
      runMembers.add(<int>[for (final Object? m in run['members']! as List<Object?>) m! as int]);
      runStackNodes.add(run['node'] as int?);
      if ((run['node'] == null) != (run['state'] == 'expanded')) {
        throw FormatException('run ${runMembers.length - 1} is ${run['state']} with node ${run['node']}');
      }
    }
    final int n = inNodes.length;
    final int total = n + runStackNodes.nonNulls.length;
    if (outNodes.length != total) {
      throw FormatException('input has $n nodes and ${total - n} stacks, output ${outNodes.length} nodes');
    }
    final keys = <String>[];
    final cols = Int32List(total);
    final nodeRows = Int32List(total);
    final parentCounts = Int32List(total);
    final elided = Uint8List(total);
    final timestamps = <int?>[];
    final flags = Uint8List(total);
    int? workingCopy;
    int? root;
    for (var i = 0; i < n; i++) {
      final node = inNodes[i]! as Map<String, Object?>;
      final parents = node['parents']! as List<Object?>;
      keys.add((node['key'] ?? node['id'])! as String);
      if (node['immutable'] == true || node['is_root'] == true) {
        flags[i] = flagImmutable;
      }
      parentCounts[i] = (node['parent_count'] as int?) ?? parents.length;
      elided[i] = parents.where((p) => (p! as Map<String, Object?>)['kind'] == 'missing').length;
      timestamps.add(node['ts_ms'] as int?);
      if (node['working_copy'] == 'this') {
        workingCopy = i;
      }
      if (node['is_root'] == true) {
        root = i;
      }
      final cell = outNodes[i] as Map<String, Object?>?;
      cols[i] = (cell?['col'] as int?) ?? -1;
      nodeRows[i] = (cell?['row'] as int?) ?? -1;
    }
    // A stack node: its oldest member's stack key, its newest member's timestamp, immutable when every member is.
    for (var r = 0; r < runMembers.length; r++) {
      final int? s = runStackNodes[r];
      if (s == null) {
        continue;
      }
      if (s != keys.length) {
        throw FormatException('run $r has stack node $s, expected ${keys.length}');
      }
      final List<int> members = runMembers[r];
      keys.add(graphStackKey(keys[members.first]));
      timestamps.add(timestamps[members.last]);
      parentCounts[s] = 1;
      if (members.every((m) => flags[m] & flagImmutable != 0)) {
        flags[s] = flagImmutable;
      }
      final cell = outNodes[s]! as Map<String, Object?>;
      cols[s] = cell['col']! as int;
      nodeRows[s] = cell['row']! as int;
    }
    final outEdges = output['edges']! as List<Object?>;
    final int e = outEdges.length;
    final edgeChildren = Int32List(e);
    final edgeParents = Int32List(e);
    final edgeKinds = <GraphEdgeKind>[];
    final edgeShapes = <GraphEdgeShape>[];
    for (var k = 0; k < e; k++) {
      final edge = outEdges[k]! as Map<String, Object?>;
      edgeChildren[k] = edge['to']! as int;
      edgeParents[k] = edge['from']! as int;
      edgeKinds.add(GraphEdgeKind.values.byName(edge['kind']! as String));
      edgeShapes.add(switch (edge['route']) {
        'straight' => GraphEdgeShape.straight,
        'merge' => GraphEdgeShape.merge,
        'branch_off' => GraphEdgeShape.branchOff,
        final Object? route => throw FormatException('unknown route $route'),
      });
    }
    final outBuckets = output['buckets']! as List<Object?>;
    final bucketValues = <int>[];
    final bucketFirstRows = Int32List(outBuckets.length);
    final bucketLastRows = Int32List(outBuckets.length);
    for (var b = 0; b < outBuckets.length; b++) {
      final bucket = outBuckets[b]! as Map<String, Object?>;
      if (bucket['kind'] != 'day') {
        throw FormatException('unknown bucket kind ${bucket['kind']}');
      }
      bucketValues.add(bucket['value']! as int);
      bucketFirstRows[b] = bucket['start']! as int;
      bucketLastRows[b] = bucket['end']! as int;
    }
    return RecordedGraphLayout(
      mode: GraphMode.values.byName(output['mode']! as String),
      unit: output['unit']! as int,
      rows: output['rows']! as int,
      colCount: output['lanes']! as int,
      keys: keys,
      cols: cols,
      nodeRows: nodeRows,
      parentCounts: parentCounts,
      elided: elided,
      timestamps: timestamps,
      edgeChildren: edgeChildren,
      edgeParents: edgeParents,
      edgeKinds: edgeKinds,
      edgeShapes: edgeShapes,
      bucketValues: bucketValues,
      bucketFirstRows: bucketFirstRows,
      bucketLastRows: bucketLastRows,
      utcOffsetMinutes: (input['utc_offset_min'] as int?) ?? 0,
      rootIndex: root,
      workingCopyIndex: workingCopy,
      operationId: operationId,
      totalCount: totalCount,
      flags: flags,
      // A stack node has no content and no refs of its own: the card reads its members'.
      contents: content == null
          ? null
          : <GraphCommitContent?>[
              for (var i = 0; i < n; i++) content(i, keys[i]),
              for (var i = n; i < total; i++) null,
            ],
      refs: refs == null
          ? null
          : <List<GraphRef>>[
              for (var i = 0; i < n; i++) refs(i, keys[i]),
              for (var i = n; i < total; i++) const <GraphRef>[],
            ],
      runMembers: runMembers,
      runStackNodes: runStackNodes,
    );
  }

  /// Free's shortened stretches, already applied to the given rows (the catalogue's long history); none by default.
  @override
  final List<GraphBreak> breaks;

  /// The `flags` bit of an immutable node.
  static const flagImmutable = 1;

  /// The `flags` bit of a hidden node.
  static const flagHidden = 2;

  /// The `flags` bit of a divergent node.
  static const flagDivergent = 4;

  @override
  final String? workspaceName;

  final List<String>? _changeIds;
  final List<String>? _commitIds;
  final Int32List? _givenPrefixLengths;
  final List<int?>? _changeOffsets;
  final Uint8List? _flags;
  final List<List<GraphRef>>? _refs;
  final List<List<String>>? _workingCopies;
  final List<GraphCommitContent?>? _contents;

  // A fixture stand-in for jj's `changeIdPrefixLen`: the shortest prefix unique among this layout's change ids (the
  // stack nodes' synthetic keys left out), from its sorted neighbours, computed once on first use.
  late final Int32List _prefixLengths = _givenPrefixLengths ?? _shortestPrefixes();

  Int32List _shortestPrefixes() {
    final order = <int>[
      for (var i = 0; i < _keys.length; i++)
        if (!isStackNode(i)) i,
    ]..sort((a, b) => changeIdOf(a).compareTo(changeIdOf(b)));
    final int n = order.length;
    int common(String a, String b) {
      var k = 0;
      while (k < a.length && k < b.length && a.codeUnitAt(k) == b.codeUnitAt(k)) {
        k++;
      }
      return k;
    }

    final lengths = Int32List(_keys.length);
    for (var r = 0; r < n; r++) {
      final String id = changeIdOf(order[r]);
      final int before = r > 0 ? common(id, changeIdOf(order[r - 1])) : 0;
      final int after = r + 1 < n ? common(id, changeIdOf(order[r + 1])) : 0;
      lengths[order[r]] = math.min(id.length, math.max(before, after) + 1);
    }
    return lengths;
  }

  @override
  String changeIdOf(int node) => _changeIds?[node] ?? _keys[node];

  // shortcut: recordings carry no commit ids, so the key stands in; the worker's BackendGraphLayout has real ones.
  @override
  String commitIdOf(int node) => _commitIds?[node] ?? _keys[node];

  @override
  int changeIdPrefixLengthOf(int node) => _prefixLengths[node];

  @override
  int? changeOffsetOf(int node) => _changeOffsets?[node];

  bool _flag(int node, int bit) => (_flags?[node] ?? 0) & bit != 0;

  @override
  bool isImmutable(int node) => _flag(node, flagImmutable);

  @override
  bool isHidden(int node) => _flag(node, flagHidden);

  @override
  bool isDivergent(int node) => _flag(node, flagDivergent);

  @override
  List<GraphRef> refsOf(int node) => _refs?[node] ?? const <GraphRef>[];

  @override
  List<String> workingCopiesOf(int node) => _workingCopies?[node] ?? const <String>[];

  @override
  GraphCommitContent? contentOf(int node) => _contents?[node];

  @override
  final GraphMode mode;

  @override
  final int unit;

  @override
  final int rows;

  @override
  final int colCount;

  @override
  final int utcOffsetMinutes;

  @override
  final int? rootIndex;

  @override
  final int? workingCopyIndex;

  @override
  final int? totalCount;

  @override
  final String? operationId;

  @override
  final int version;

  final List<String> _keys;
  final Int32List _cols;
  final Int32List _rows;
  final Int32List _parentCounts;
  final Uint8List _elided;
  final List<int?>? _timestamps;
  final Int32List _edgeChildren;
  final Int32List _edgeParents;
  final List<GraphEdgeKind> _edgeKinds;
  final List<GraphEdgeShape> _edgeShapes;
  final List<int> _bucketValues;
  final Int32List _bucketFirstRows;
  final Int32List _bucketLastRows;
  final _indexOfKey = <String, int>{};
  late final GraphEdgeIndex _edges;

  final List<List<int>> _runMembers;
  final List<int?> _runStackNodes;
  late final Int32List _runOf;
  var _stackCount = 0;

  @override
  int get runCount => _runMembers.length;

  @override
  List<int> runMembersOf(int run) => _runMembers[run];

  @override
  int? stackNodeOf(int run) => _runStackNodes[run];

  @override
  int? runOf(int node) => _runOf[node] < 0 ? null : _runOf[node];

  @override
  int get nodeCount => _keys.length;

  @override
  int get shownCount => _keys.length - _stackCount;

  @override
  String keyOf(int node) => _keys[node];

  @override
  int? indexOfKey(String key) => _indexOfKey[key];

  @override
  int colOf(int node) => _cols[node];

  @override
  int rowOf(int node) => _rows[node];

  @override
  int? timestampOf(int node) => _timestamps?[node];

  @override
  int parentCountOf(int node) => _parentCounts[node];

  @override
  bool elidedOf(int node) => missingCountOf(node) > 0;

  @override
  int missingCountOf(int node) =>
      // A stack's edges leave from its oldest member.
      isStackNode(node) ? _elided[runMembersOf(runOf(node)!).first] : _elided[node];

  @override
  int get edgeCount => _edgeChildren.length;

  @override
  int childOf(int edge) => _edgeChildren[edge];

  @override
  int parentOf(int edge) => _edgeParents[edge];

  @override
  GraphEdgeKind kindOf(int edge) => _edgeKinds[edge];

  @override
  GraphEdgeShape shapeOf(int edge) => _edgeShapes[edge];

  @override
  ({int start, int end}) parentEdges(int node) => _edges.parentEdges(node);

  @override
  ({int start, int end}) childEdges(int node) => _edges.childEdgeRange(node);

  @override
  int childEdgeAt(int slot) => _edges.childEdges[slot];

  @override
  int get bucketCount => _bucketValues.length;

  @override
  GraphBucketKind bucketKindOf(int bucket) => GraphBucketKind.day;

  @override
  int bucketValueOf(int bucket) => _bucketValues[bucket];

  @override
  int bucketFirstRowOf(int bucket) => _bucketFirstRows[bucket];

  @override
  int bucketLastRowOf(int bucket) => _bucketLastRows[bucket];
}
