// SPDX-License-Identifier: MIT

import 'dart:convert';
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
    this.workingCopyIndex,
    this.totalCount,
    this.operationId,
  }) : _keys = keys,
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
       version = _nextVersion++ {
    final int n = keys.length;
    final int e = edgeChildren.length;
    assert(cols.length == n && nodeRows.length == n && parentCounts.length == n && elided.length == n);
    assert(timestamps == null || timestamps.length == n);
    assert(edgeParents.length == e && edgeKinds.length == e && edgeShapes.length == e);
    assert(_bucketFirstRows.length == _bucketValues.length && _bucketLastRows.length == _bucketValues.length);
    for (var i = 0; i < n; i++) {
      _indexOfKey[keys[i]] = i;
    }
    // CSR over the given order: parent ranges by counting the children, child ranges by a counting sort on parents.
    // A dangling end is left out of the index, so the invariant checker can report it instead of a RangeError.
    bool valid(int node) => node >= 0 && node < n;
    _parentStart = Int32List(n + 1);
    _childStart = Int32List(n + 1);
    for (var k = 0; k < e; k++) {
      assert(k == 0 || edgeChildren[k - 1] <= edgeChildren[k], 'edges must be ordered by child');
      if (valid(edgeChildren[k])) {
        _parentStart[edgeChildren[k] + 1]++;
      }
      if (valid(edgeParents[k])) {
        _childStart[edgeParents[k] + 1]++;
      }
    }
    for (var i = 0; i < n; i++) {
      _parentStart[i + 1] += _parentStart[i];
      _childStart[i + 1] += _childStart[i];
    }
    _childEdges = Int32List(_childStart[n]);
    final fill = Int32List.fromList(_childStart.sublist(0, n));
    for (var k = 0; k < e; k++) {
      if (valid(edgeParents[k])) {
        _childEdges[fill[edgeParents[k]]++] = k;
      }
    }
  }

  /// Joins a docs/graph-layout.md §2 input (the view facts: `key` ?? `id`, `parent_count` ?? the parent entries,
  /// `working_copy == "this"`, a Missing parent, `ts_ms`) with the engine's §3 output for it (rows, unit, lanes,
  /// columns, edges with their routes, buckets).
  factory RecordedGraphLayout.fromSpec(String inputJson, String outputJson) {
    final input = jsonDecode(inputJson) as Map<String, Object?>;
    final output = jsonDecode(outputJson) as Map<String, Object?>;
    final inNodes = input['nodes']! as List<Object?>;
    final outNodes = output['nodes']! as List<Object?>;
    if (inNodes.length != outNodes.length) {
      throw FormatException('input has ${inNodes.length} nodes, output ${outNodes.length}');
    }
    final int n = inNodes.length;
    final keys = <String>[];
    final cols = Int32List(n);
    final nodeRows = Int32List(n);
    final parentCounts = Int32List(n);
    final elided = Uint8List(n);
    final timestamps = <int?>[];
    int? workingCopy;
    for (var i = 0; i < n; i++) {
      final node = inNodes[i]! as Map<String, Object?>;
      final parents = node['parents']! as List<Object?>;
      keys.add((node['key'] ?? node['id'])! as String);
      parentCounts[i] = (node['parent_count'] as int?) ?? parents.length;
      elided[i] = parents.any((p) => (p! as Map<String, Object?>)['kind'] == 'missing') ? 1 : 0;
      timestamps.add(node['ts_ms'] as int?);
      if (node['working_copy'] == 'this') {
        workingCopy = i;
      }
      final cell = outNodes[i]! as Map<String, Object?>;
      cols[i] = cell['col']! as int;
      nodeRows[i] = cell['row']! as int;
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
      workingCopyIndex: workingCopy,
    );
  }

  static var _nextVersion = 0;

  @override
  final GraphMode mode;

  @override
  final int unit;

  @override
  final int rows;

  @override
  final int colCount;

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
  late final Int32List _parentStart;
  late final Int32List _childStart;
  late final Int32List _childEdges;

  @override
  int get nodeCount => _keys.length;

  @override
  int get shownCount => _keys.length;

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
  bool elidedOf(int node) => _elided[node] != 0;

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
  ({int start, int end}) parentEdges(int node) => (start: _parentStart[node], end: _parentStart[node + 1]);

  @override
  ({int start, int end}) childEdges(int node) => (start: _childStart[node], end: _childStart[node + 1]);

  @override
  int childEdgeAt(int slot) => _childEdges[slot];

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
