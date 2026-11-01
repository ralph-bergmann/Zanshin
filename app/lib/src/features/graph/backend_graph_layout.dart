// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:zanshin_core/zanshin_core.dart';

import 'graph_layout.dart';

/// The worker's layout (Story 10.12): a lazy [GraphLayout] over one `RepoHandle.graphLayout` reply — the ids, flags,
/// refs, working copies, counts and operation of the [topology] (Story 4.12) and the rows, columns, edges, buckets and
/// runs of its [grid] (Stories 4.11, 4.13).
///
/// It lays nothing out and allocates no per-node object up front: ids are formatted on access, and only the key
/// lookup, the edge index and the root/@ scan are built, each on first use. Node `i < n` is topology node `i`; the
/// grid's stack nodes follow (`n ≤ i < n + S`), each keyed [graphStackKey] of its run's oldest member, with its newest
/// member's timestamp, one parent and the immutable flag when every member has it.
class BackendGraphLayout extends GraphLayout {
  /// The layout of [topology] laid out as [grid], its day buckets cut at [utcOffsetMinutes] (the request's).
  BackendGraphLayout(this.topology, this.grid, {required this.utcOffsetMinutes})
    : assert(grid.nodeCount == topology.nodeCount, 'the grid lays out the topology it came with'),
      version = nextGraphLayoutVersion();

  /// The topology the layout came with.
  final GraphTopologyView topology;

  /// The grid the engine laid out.
  final GraphGridView grid;

  @override
  final int utcOffsetMinutes;

  @override
  final int version;

  int get _n => topology.nodeCount;

  @override
  GraphMode get mode => grid.mode == LayoutMode.free ? GraphMode.free : GraphMode.compact;

  @override
  int get unit => grid.unit;

  @override
  int get rows => grid.rows;

  @override
  int get colCount => grid.lanes;

  @override
  int get nodeCount => _n + grid.stackCount;

  @override
  int get shownCount => _n;

  @override
  int? get totalCount => topology.allCount;

  @override
  String? get operationId => topology.operationId;

  bool _isStack(int node) => node >= _n;

  // The run of each stack node (stack nodes are in run order, but only the collapsed runs have one).
  late final Int32List _stackRuns = () {
    final runs = Int32List(grid.stackCount);
    final Int32List? runNodes = grid.runNodes;
    for (var r = 0; r < grid.runCount; r++) {
      final int stack = runNodes![r];
      if (stack >= 0) {
        runs[stack - _n] = r;
      }
    }
    return runs;
  }();

  @override
  String keyOf(int node) {
    if (_isStack(node)) {
      return graphStackKey(keyOf(runMembersOf(_stackRuns[node - _n]).first));
    }
    return topology.isHidden(node) || topology.isDivergent(node) ? topology.commitId(node) : topology.changeId(node);
  }

  late final _keys = <String, int>{for (var i = 0; i < nodeCount; i++) keyOf(i): i};

  @override
  int? indexOfKey(String key) => _keys[key];

  @override
  int colOf(int node) => grid.nodeCols[node];

  @override
  int rowOf(int node) => grid.nodeRows[node];

  @override
  int? timestampOf(int node) =>
      _isStack(node) ? topology.timestamp(runMembersOf(_stackRuns[node - _n]).last) : topology.timestamp(node);

  @override
  int parentCountOf(int node) => _isStack(node) ? 1 : topology.parentCount(node);

  @override
  bool elidedOf(int node) {
    if (_isStack(node)) {
      return false;
    }
    for (int e = topology.edgeStart(node); e < topology.edgeEnd(node); e++) {
      if (topology.edgeTarget(e) == null) {
        return true;
      }
    }
    return false;
  }

  @override
  int get edgeCount => grid.edgeCount;

  @override
  int childOf(int edge) => grid.edgeTos[edge];

  @override
  int parentOf(int edge) => grid.edgeFroms[edge];

  @override
  GraphEdgeKind kindOf(int edge) =>
      grid.edgeKinds[edge] == GraphGridView.edgeKindIndirect ? GraphEdgeKind.indirect : GraphEdgeKind.direct;

  @override
  GraphEdgeShape shapeOf(int edge) => switch (grid.edgeRoutes[edge]) {
    GraphGridView.routeMerge => GraphEdgeShape.merge,
    GraphGridView.routeBranchOff => GraphEdgeShape.branchOff,
    _ => GraphEdgeShape.straight,
  };

  late final _edges = GraphEdgeIndex.build(grid.edgeTos, grid.edgeFroms, nodeCount);

  @override
  ({int start, int end}) parentEdges(int node) => _edges.parentEdges(node);

  @override
  ({int start, int end}) childEdges(int node) => _edges.childEdgeRange(node);

  @override
  int childEdgeAt(int slot) => _edges.childEdges[slot];

  @override
  int get bucketCount => grid.bucketCount;

  @override
  GraphBucketKind bucketKindOf(int bucket) => GraphBucketKind.day;

  @override
  int bucketValueOf(int bucket) => grid.bucketValues[bucket];

  @override
  int bucketFirstRowOf(int bucket) => grid.bucketStarts[bucket];

  @override
  int bucketLastRowOf(int bucket) => grid.bucketEnds[bucket];

  // One flags scan finds both.
  late final ({int? root, int? at}) _special = () {
    int? root;
    int? at;
    final Uint8List flags = topology.flags;
    for (var i = 0; i < _n && (root == null || at == null); i++) {
      if (flags[i] & GraphTopologyView.flagRoot != 0) {
        root = i;
      }
      if (flags[i] & GraphTopologyView.flagWorkingCopy != 0) {
        at = i;
      }
    }
    return (root: root, at: at);
  }();

  @override
  int? get rootIndex => _special.root;

  @override
  int? get workingCopyIndex => _special.at;

  @override
  String changeIdOf(int node) => _isStack(node) ? keyOf(node) : topology.changeId(node);

  @override
  String commitIdOf(int node) => _isStack(node) ? keyOf(node) : topology.commitId(node);

  @override
  int changeIdPrefixLengthOf(int node) => _isStack(node) ? 0 : topology.changeIdPrefixLength(node);

  @override
  int commitIdPrefixLengthOf(int node) => _isStack(node) ? 0 : topology.commitIdPrefixLength(node);

  @override
  int? changeOffsetOf(int node) =>
      _isStack(node) || !(topology.isHidden(node) || topology.isDivergent(node)) ? null : topology.changeOffset(node);

  @override
  bool isImmutable(int node) =>
      _isStack(node) ? runMembersOf(_stackRuns[node - _n]).every(topology.isImmutable) : topology.isImmutable(node);

  @override
  bool isHidden(int node) => !_isStack(node) && topology.isHidden(node);

  @override
  bool isDivergent(int node) => !_isStack(node) && topology.isDivergent(node);

  @override
  List<GraphRef> refsOf(int node) => _isStack(node)
      ? const <GraphRef>[]
      : <GraphRef>[
          for (final TopologyRef ref in topology.refsOf(node))
            if (ref.kind == TopologyRefKind.bookmark)
              GraphRef(ref.name, remote: ref.remote, synced: ref.synced, conflicted: ref.conflicted),
        ];

  @override
  List<String> workingCopiesOf(int node) =>
      _isStack(node) ? const <String>[] : <String>[for (final w in topology.workingCopiesOf(node)) w.workspace];

  // shortcut: with several workspaces on @'s commit the topology cannot say which is ours, so none is named and the
  // card shows every name (as jj does); a Rust-side workspace name would settle it.
  @override
  String? get workspaceName {
    final int? at = workingCopyIndex;
    final List<String> names = at == null ? const <String>[] : workingCopiesOf(at);
    return names.length == 1 ? names.single : null;
  }

  @override
  GraphCommitContent? contentOf(int node) => null;

  @override
  int get runCount => grid.runCount;

  @override
  List<int> runMembersOf(int run) =>
      Int32List.sublistView(grid.runMembers!, grid.runStarts![run], grid.runStarts![run + 1]);

  @override
  int? stackNodeOf(int run) {
    final int stack = grid.runNodes![run];
    return stack < 0 ? null : stack;
  }

  @override
  int? runOf(int node) {
    final Int32List? runs = grid.nodeRuns;
    if (runs == null) {
      return null;
    }
    if (_isStack(node)) {
      return _stackRuns[node - _n];
    }
    final int run = runs[node];
    return run < 0 ? null : run;
  }
}
