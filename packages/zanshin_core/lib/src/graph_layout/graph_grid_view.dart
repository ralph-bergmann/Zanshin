// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'layout_request.dart';

/// The grid header: 35 little-endian int32 slots at byte 0.
const _headerSlots = 35;

/// The header's byte length; the first array starts at the next multiple of 8 (144).
const int _headerBytes = 4 * _headerSlots;

const _slotVersion = 0;
const _slotMode = 1;
const _slotOrder = 2;
const _slotUnit = 3;
const _slotRows = 4;
const _slotLanes = 5;
const _slotNodes = 6;
const _slotEdges = 7;
const _slotBuckets = 8;

/// Slot 9 + 2k is array k's byte offset, slot 10 + 2k its element count.
const _slotArrays = 9;

const _nodeRow = 0;
const _nodeLane = 1;
const _nodeCol = 2;
const _edgeFrom = 3;
const _edgeTo = 4;
const _edgeKind = 5;
const _edgeRoute = 6;
const _edgeBlocked = 7;
const _bucketKind = 8;
const _bucketValue = 9;
const _bucketStart = 10;
const _bucketEnd = 11;
const _nodeDay = 12;
const _arrayCount = 13;

/// The element size in bytes of each array, in array order.
const _elementSizes = <int>[4, 4, 4, 4, 4, 1, 1, 1, 1, 8, 4, 4, 8];

/// The array names, in array order (for the decode errors).
const _arrayNames = <String>[
  'node row',
  'node lane',
  'node col',
  'edge from',
  'edge to',
  'edge kind',
  'edge route',
  'edge blocked',
  'bucket kind',
  'bucket value',
  'bucket start',
  'bucket end',
  'node day',
];

/// The version-4 header (Stories 4.13 / 4.14, a layout with stacks): 48 int32 slots, version 3's
/// 35 first.
const _stackHeaderSlots = 48;

/// The version-4 header's byte length; its first array starts right after it (192 is 8-aligned).
const int _stackHeaderBytes = 4 * _stackHeaderSlots;

const _slotStacks = 35;
const _slotRuns = 36;
const _slotMembers = 37;

/// Slot 38 + 2k is stack array k's byte offset, slot 39 + 2k its element count.
const _slotStackArrays = 38;

const _nodeRun = 0;
const _runState = 1;
const _runNode = 2;
const _runStart = 3;
const _runMember = 4;
const _stackArrayCount = 5;

/// The element size in bytes of each stack array, in array order.
const _stackElementSizes = <int>[4, 1, 4, 4, 4];

/// The stack array names, in array order (for the decode errors).
const _stackArrayNames = <String>['node run', 'run state', 'run node', 'run start', 'run members'];

/// A layout's result (Story 4.11): the abstract grid of docs/graph-layout.md §3 — per node its
/// row, lane and column, per layout edge its route and `blocked` flag, per time bucket its row
/// range — read through typed-data views over ONE buffer, without a per-node object.
///
/// **Format** (format version [formatVersion]; little-endian; the contract of docs/graph-layout.md
/// §13):
/// - **Header:** 35 int32 slots at byte 0 — [0] the format version, [1] the mode
///   ([LayoutMode.index]: 0 compact, 1 free), [2] the lane order ([LaneOrder.index]: 0 greedy,
///   1 compact), [3] U (1 in `compact`, 16 in `free`), [4] rows, [5] lanes, [6] n, [7] E (the
///   layout edges), [8] B (the buckets), then for each of the thirteen arrays below its byte offset
///   and its element count (slots 9 + 2k and 10 + 2k).
/// - **Arrays,** in this order, each starting at the next multiple of 8 after the previous one (the
///   first at byte 144): node row, node lane, node col (int32 × n); edge from, edge to
///   (int32 × E); edge kind, edge route, edge blocked (uint8 × E); bucket kind (uint8 × B); bucket
///   value (int64 × B); bucket start, bucket end (int32 × B); node day (int64 × n).
/// - **Values:** a node's row is y (§4.2; in `free` in 1/U pitch units, y ≤ 48·(n − 1), so it
///   fits an int32). Lanes and columns are joint (§4.3 / §4.7, amended 2026-10-27): the same in a
///   `compact` and a `free` grid of one input. Edges are in §3's order — by child ascending, then
///   by the parent's position among the child's layout parents; `from` is the parent, `to` the
///   child, and Missing parents are no layout edges. Edge kinds are [edgeKindDirect] /
///   [edgeKindIndirect], routes [routeStraight] / [routeMerge] / [routeBranchOff] (§8.4's r),
///   `blocked` 0 or 1. Buckets are `free`'s day buckets ([bucketKindDay]), ascending; their value
///   is the local-midnight instant in epoch ms, their start and end the least and the largest y of
///   their members. A node's day (Story 4.14, §4.2 free step 4's dk in both modes) is the
///   local-midnight instant of its clamped T, [noDay] for a root.
///
/// **Format version [stackFormatVersion]** (Stories 4.13 / 4.14, docs/graph-layout.md §4.8 and
/// §13 — a layout with a stack request): version 3's header slots and thirteen arrays, with header
/// slot 0 = 4, then
/// - **more header slots,** 48 in all (192 bytes): [35] S (the stack nodes), [36] R (the runs),
///   [37] M (the run members), then for each of five more arrays its byte offset and element count
///   (slots 38 + 2k and 39 + 2k);
/// - **the node arrays** hold n + S entries: the n topology nodes, then the stack nodes in run
///   order; a hidden node (a member of a collapsed run) has row, lane and col −1 but keeps its own
///   day; a stack node has its newest member's day. [nodeCount] stays n. The edges and buckets are
///   the grouped layout's, and an edge's `from` / `to` may be a stack node. Index order is then no
///   topological order: an edge into a stack node has a parent index below its child's
///   (p < n ≤ s);
/// - **five more arrays** after the thirteen, each 8-aligned after the previous one: node run
///   (int32 × n: the run index of each topology node, or −1), run state (uint8 × R:
///   [runExpanded] / [runCollapsed]), run node (int32 × R: the run's stack node, or −1 when
///   expanded), run start (int32 × R + 1) and run members (int32 × M) — the runs' members as a CSR
///   over topology node indices, oldest first. Runs are ordered by their newest member.
///
/// [GraphGridView.fromBytes] validates the header and every array's offset, count and bounds,
/// never the values.
final class GraphGridView {
  GraphGridView._({
    required this.bytes,
    required this.copied,
    required this.mode,
    required this.order,
    required this.unit,
    required this.rows,
    required this.lanes,
    required this.nodeCount,
    required this.edgeCount,
    required this.bucketCount,
    required this.nodeRows,
    required this.nodeLanes,
    required this.nodeCols,
    required this.edgeFroms,
    required this.edgeTos,
    required this.edgeKinds,
    required this.edgeRoutes,
    required this.edgeBlocked,
    required this.bucketKinds,
    required this.bucketValues,
    required this.bucketStarts,
    required this.bucketEnds,
    required this.nodeDays,
    required this.stackCount,
    required this.runCount,
    required this.nodeRuns,
    required this.runStates,
    required this.runNodes,
    required this.runStarts,
    required this.runMembers,
  });

  /// Reads a grid buffer of format version [formatVersion] or [stackFormatVersion]. A [bytes]
  /// view whose start is not 8-aligned in its buffer is copied once (see [copied]); otherwise
  /// every view reads [bytes] in place. Throws [FormatException] for a buffer shorter than its
  /// header, another format version, an unknown mode or order code, a unit that is not the
  /// mode's, a negative count, an array count that differs from its header count, or an array
  /// offset that is not 8-aligned, lies inside the header or runs past the buffer. Little-endian
  /// host assumed (macOS).
  factory GraphGridView.fromBytes(Uint8List bytes) {
    final copy = bytes.offsetInBytes % 8 != 0;
    final data = copy ? Uint8List.fromList(bytes) : bytes;
    if (data.length < _headerBytes) {
      throw FormatException('a grid buffer needs its $_headerBytes-byte header, got ${data.length} bytes');
    }
    final header = ByteData.sublistView(data);
    int slot(int k) => header.getInt32(4 * k, Endian.little);

    final int version = slot(_slotVersion);
    if (version != formatVersion && version != stackFormatVersion) {
      throw FormatException('grid format version $version, expected $formatVersion or $stackFormatVersion');
    }
    final stacked = version == stackFormatVersion;
    final int headerBytes = stacked ? _stackHeaderBytes : _headerBytes;
    if (data.length < headerBytes) {
      throw FormatException(
        'a version-$version grid buffer needs its $headerBytes-byte header, got ${data.length} bytes',
      );
    }
    final int modeCode = slot(_slotMode);
    if (modeCode < 0 || modeCode >= LayoutMode.values.length) {
      throw FormatException('unknown grid mode code $modeCode');
    }
    final LayoutMode mode = LayoutMode.values[modeCode];
    final int orderCode = slot(_slotOrder);
    if (orderCode < 0 || orderCode >= LaneOrder.values.length) {
      throw FormatException('unknown grid lane order code $orderCode');
    }
    final int unit = slot(_slotUnit);
    if (unit != (mode == LayoutMode.free ? 16 : 1)) {
      throw FormatException('grid unit $unit does not belong to mode ${mode.name}');
    }
    final int n = slot(_slotNodes);
    final int e = slot(_slotEdges);
    final int b = slot(_slotBuckets);
    final int rows = slot(_slotRows);
    final int lanes = slot(_slotLanes);
    if (n < 0 || e < 0 || b < 0 || rows < 0 || lanes < 0) {
      throw FormatException('negative grid count: n $n, E $e, B $b, rows $rows, lanes $lanes');
    }
    final int s = stacked ? slot(_slotStacks) : 0;
    final int r = stacked ? slot(_slotRuns) : 0;
    final int m = stacked ? slot(_slotMembers) : 0;
    if (s < 0 || r < 0 || m < 0) {
      throw FormatException('negative grid stack count: S $s, R $r, M $m');
    }
    final ByteBuffer buffer = data.buffer;
    final int base = data.offsetInBytes;
    int locate(String name, int offsetSlot, int count, int expected, int elementSize) {
      final int offset = slot(offsetSlot);
      if (count != expected) {
        throw FormatException('grid $name array has $count entries, expected $expected');
      }
      if (offset % 8 != 0) {
        throw FormatException('grid $name array starts at byte $offset, which is not 8-aligned');
      }
      if (offset < headerBytes || offset + count * elementSize > data.length) {
        throw FormatException('grid $name array at byte $offset runs outside the ${data.length}-byte buffer');
      }
      return base + offset;
    }

    final offsets = Int32List(_arrayCount);
    for (var k = 0; k < _arrayCount; k++) {
      final int expected = k <= _nodeCol || k == _nodeDay ? n + s : (k <= _edgeBlocked ? e : b);
      offsets[k] = locate(
        _arrayNames[k],
        _slotArrays + 2 * k,
        slot(_slotArrays + 2 * k + 1),
        expected,
        _elementSizes[k],
      );
    }
    final stackOffsets = Int32List(_stackArrayCount);
    if (stacked) {
      final expected = <int>[n, r, r, r + 1, m];
      for (var k = 0; k < _stackArrayCount; k++) {
        stackOffsets[k] = locate(
          _stackArrayNames[k],
          _slotStackArrays + 2 * k,
          slot(_slotStackArrays + 2 * k + 1),
          expected[k],
          _stackElementSizes[k],
        );
      }
    }
    final int nodes = n + s;
    return GraphGridView._(
      bytes: data.asUnmodifiableView(),
      copied: copy,
      mode: mode,
      order: LaneOrder.values[orderCode],
      unit: unit,
      rows: rows,
      lanes: lanes,
      nodeCount: n,
      edgeCount: e,
      bucketCount: b,
      nodeRows: buffer.asInt32List(offsets[_nodeRow], nodes).asUnmodifiableView(),
      nodeLanes: buffer.asInt32List(offsets[_nodeLane], nodes).asUnmodifiableView(),
      nodeCols: buffer.asInt32List(offsets[_nodeCol], nodes).asUnmodifiableView(),
      edgeFroms: buffer.asInt32List(offsets[_edgeFrom], e).asUnmodifiableView(),
      edgeTos: buffer.asInt32List(offsets[_edgeTo], e).asUnmodifiableView(),
      edgeKinds: buffer.asUint8List(offsets[_edgeKind], e).asUnmodifiableView(),
      edgeRoutes: buffer.asUint8List(offsets[_edgeRoute], e).asUnmodifiableView(),
      edgeBlocked: buffer.asUint8List(offsets[_edgeBlocked], e).asUnmodifiableView(),
      bucketKinds: buffer.asUint8List(offsets[_bucketKind], b).asUnmodifiableView(),
      bucketValues: buffer.asInt64List(offsets[_bucketValue], b).asUnmodifiableView(),
      bucketStarts: buffer.asInt32List(offsets[_bucketStart], b).asUnmodifiableView(),
      bucketEnds: buffer.asInt32List(offsets[_bucketEnd], b).asUnmodifiableView(),
      nodeDays: buffer.asInt64List(offsets[_nodeDay], nodes).asUnmodifiableView(),
      stackCount: s,
      runCount: r,
      nodeRuns: stacked ? buffer.asInt32List(stackOffsets[_nodeRun], n).asUnmodifiableView() : null,
      runStates: stacked ? buffer.asUint8List(stackOffsets[_runState], r).asUnmodifiableView() : null,
      runNodes: stacked ? buffer.asInt32List(stackOffsets[_runNode], r).asUnmodifiableView() : null,
      runStarts: stacked ? buffer.asInt32List(stackOffsets[_runStart], r + 1).asUnmodifiableView() : null,
      runMembers: stacked ? buffer.asInt32List(stackOffsets[_runMember], m).asUnmodifiableView() : null,
    );
  }

  /// The grid format version of a layout without stacks (header slot 0). Versions 1 and 2 (before
  /// Story 4.14's node day) are retired: no grid is ever persisted.
  static const formatVersion = 3;

  /// The grid format version of a layout with a stack request (Stories 4.13 / 4.14).
  static const stackFormatVersion = 4;

  /// [nodeDays]' value for a node in no day: the root (−2^63).
  static const int noDay = -0x7FFFFFFFFFFFFFFF - 1;

  /// A run state ([runStates]): the run's members are visible.
  static const runExpanded = 0;

  /// A run state ([runStates]): the run's members are hidden behind its stack node.
  static const runCollapsed = 1;

  /// An edge kind: the parent is in the revset.
  static const edgeKindDirect = 0;

  /// An edge kind: the edge skips hidden commits (drawn dashed).
  static const edgeKindIndirect = 1;

  /// A route: the parent's lane continues into the child (same lane).
  static const routeStraight = 0;

  /// A route: a non-first parent in another lane, not blocked.
  static const routeMerge = 1;

  /// A route: a first parent in another lane, or a blocked merge (D9).
  static const routeBranchOff = 2;

  /// A bucket kind: a calendar day at the fixed UTC offset. (0 and 1 are §3's `root` and `age`,
  /// which only the unported `time` mode emits.)
  static const bucketKindDay = 2;

  /// The buffer every view reads, unmodifiable.
  final Uint8List bytes;

  /// Whether [GraphGridView.fromBytes] had to copy its buffer because it did not start 8-aligned.
  @visibleForTesting
  final bool copied;

  /// The vertical model the grid was laid out in.
  final LayoutMode mode;

  /// The lane order the grid was laid out with.
  final LaneOrder order;

  /// U, the y units per row pitch: 1 in `compact`, 16 in `free`.
  final int unit;

  /// The largest row plus U; 0 for an empty grid.
  final int rows;

  /// The largest lane plus 1; 0 for an empty grid.
  final int lanes;

  /// n, the topology nodes; the node arrays are index-aligned with the topology and, with stacks,
  /// hold [stackCount] stack nodes after them.
  final int nodeCount;

  /// E, the layout edges.
  final int edgeCount;

  /// B, the buckets.
  final int bucketCount;

  /// Each node's row (y), unmodifiable; −1 for a hidden node.
  final Int32List nodeRows;

  /// Each node's lane, unmodifiable; −1 for a hidden node.
  final Int32List nodeLanes;

  /// Each node's column, unmodifiable; −1 for a hidden node.
  final Int32List nodeCols;

  /// Each layout edge's parent node, unmodifiable.
  final Int32List edgeFroms;

  /// Each layout edge's child node, unmodifiable.
  final Int32List edgeTos;

  /// Each layout edge's kind ([edgeKindDirect] or [edgeKindIndirect]), unmodifiable.
  final Uint8List edgeKinds;

  /// Each layout edge's route ([routeStraight], [routeMerge] or [routeBranchOff]), unmodifiable.
  final Uint8List edgeRoutes;

  /// Each layout edge's `blocked` flag (0 or 1), unmodifiable.
  final Uint8List edgeBlocked;

  /// Each bucket's kind ([bucketKindDay]), unmodifiable.
  final Uint8List bucketKinds;

  /// Each bucket's value: the local-midnight instant in epoch ms, unmodifiable.
  final Int64List bucketValues;

  /// Each bucket's least member y, unmodifiable.
  final Int32List bucketStarts;

  /// Each bucket's largest member y, unmodifiable.
  final Int32List bucketEnds;

  /// Each node's local day (Story 4.14): the local-midnight instant in epoch ms of the calendar day
  /// of its clamped T at the request's UTC offset (§4.2 free, step 4's dk), in both modes; [noDay]
  /// for the root. With stacks n + S entries: a hidden node keeps its own day, a stack node has its
  /// newest member's. Unmodifiable.
  final Int64List nodeDays;

  /// S, the stack nodes (the collapsed runs); 0 without stacks.
  final int stackCount;

  /// R, the runs, collapsed or expanded; 0 without stacks.
  final int runCount;

  /// Each topology node's run index, or −1 for a node in no run; `null` without stacks.
  /// Unmodifiable.
  final Int32List? nodeRuns;

  /// Each run's state ([runExpanded] or [runCollapsed]); `null` without stacks. Unmodifiable.
  final Uint8List? runStates;

  /// Each run's stack node (≥ [nodeCount]), or −1 for an expanded run; `null` without stacks.
  /// Unmodifiable.
  final Int32List? runNodes;

  /// The runs' member CSR offsets (R + 1): run k's members are `runMembers[runStarts[k] ..<
  /// runStarts[k + 1]]`; `null` without stacks. Unmodifiable.
  final Int32List? runStarts;

  /// Every run's members as topology node indices, oldest first; `null` without stacks.
  /// Unmodifiable.
  ///
  /// Run k's key — what `RepoHandle.graphLayout`'s `expandedKeys` / `collapsedKeys` take — is the
  /// Story 10.1 key of its first (oldest) member `runMembers[runStarts[k]]`, bare: no design-style
  /// `grp:` prefix.
  final Int32List? runMembers;

  /// Whether the layout had a stack request (format version [stackFormatVersion]).
  bool get hasStacks => nodeRuns != null;

  /// Whether node [i] is hidden: a member of a collapsed run, with no position. Stack nodes and
  /// every node of a layout without stacks are visible.
  bool isHidden(int i) {
    RangeError.checkValidIndex(i, nodeRows, 'i');
    final Int32List? runs = nodeRuns;
    final Uint8List? states = runStates;
    if (runs == null || states == null || i >= nodeCount) {
      return false;
    }
    final int run = runs[i];
    return run >= 0 && states[run] == runCollapsed;
  }
}

/// Writes a grid buffer in [GraphGridView]'s format: the header, then the thirteen arrays. Every
/// bucket is a `day` bucket. For the layout engine only — not part of the public API that
/// [GraphGridView] is.
@internal
Uint8List writeGraphGrid({
  required LayoutMode mode,
  required LaneOrder order,
  required int unit,
  required int rows,
  required int lanes,
  required Int64List nodeRows,
  required Int32List nodeLanes,
  required Int32List nodeCols,
  required Int64List nodeDays,
  required Int32List edgeFroms,
  required Int32List edgeTos,
  required Uint8List edgeKinds,
  required Uint8List edgeRoutes,
  required Uint8List edgeBlocked,
  required Int64List bucketValues,
  required Int64List bucketStarts,
  required Int64List bucketEnds,
}) {
  final int n = nodeLanes.length;
  final int e = edgeFroms.length;
  final int b = bucketValues.length;
  final offsets = Int32List(_arrayCount);
  int end = _headerBytes;
  for (var k = 0; k < _arrayCount; k++) {
    final count = k <= _nodeCol || k == _nodeDay ? n : (k <= _edgeBlocked ? e : b);
    final int start = (end + 7) & ~7;
    offsets[k] = start;
    end = start + count * _elementSizes[k];
  }
  final bytes = Uint8List(end);
  final ByteBuffer buffer = bytes.buffer;
  final header = ByteData.sublistView(bytes, 0, _headerBytes)
    ..setInt32(4 * _slotVersion, GraphGridView.formatVersion, Endian.little)
    ..setInt32(4 * _slotMode, mode.index, Endian.little)
    ..setInt32(4 * _slotOrder, order.index, Endian.little)
    ..setInt32(4 * _slotUnit, unit, Endian.little)
    ..setInt32(4 * _slotRows, rows, Endian.little)
    ..setInt32(4 * _slotLanes, lanes, Endian.little)
    ..setInt32(4 * _slotNodes, n, Endian.little)
    ..setInt32(4 * _slotEdges, e, Endian.little)
    ..setInt32(4 * _slotBuckets, b, Endian.little);
  for (var k = 0; k < _arrayCount; k++) {
    header
      ..setInt32(4 * (_slotArrays + 2 * k), offsets[k], Endian.little)
      ..setInt32(
        4 * (_slotArrays + 2 * k + 1),
        k <= _nodeCol || k == _nodeDay ? n : (k <= _edgeBlocked ? e : b),
        Endian.little,
      );
  }
  final Int32List row = buffer.asInt32List(offsets[_nodeRow], n);
  for (var i = 0; i < n; i++) {
    row[i] = nodeRows[i];
  }
  buffer.asInt32List(offsets[_nodeLane], n).setAll(0, nodeLanes);
  buffer.asInt32List(offsets[_nodeCol], n).setAll(0, nodeCols);
  buffer.asInt32List(offsets[_edgeFrom], e).setAll(0, edgeFroms);
  buffer.asInt32List(offsets[_edgeTo], e).setAll(0, edgeTos);
  buffer.asUint8List(offsets[_edgeKind], e).setAll(0, edgeKinds);
  buffer.asUint8List(offsets[_edgeRoute], e).setAll(0, edgeRoutes);
  buffer.asUint8List(offsets[_edgeBlocked], e).setAll(0, edgeBlocked);
  buffer.asUint8List(offsets[_bucketKind], b).fillRange(0, b, GraphGridView.bucketKindDay);
  buffer.asInt64List(offsets[_bucketValue], b).setAll(0, bucketValues);
  final Int32List start = buffer.asInt32List(offsets[_bucketStart], b);
  final Int32List bucketEnd = buffer.asInt32List(offsets[_bucketEnd], b);
  for (var k = 0; k < b; k++) {
    start[k] = bucketStarts[k];
    bucketEnd[k] = bucketEnds[k];
  }
  buffer.asInt64List(offsets[_nodeDay], n).setAll(0, nodeDays);
  return bytes;
}

/// Writes a grid buffer of format version [GraphGridView.stackFormatVersion] (Stories 4.13 /
/// 4.14): the 48-slot header, the thirteen arrays of [writeGraphGrid] — the node arrays with n + S
/// entries, −1 for a hidden node's row, lane and col — then the five run arrays. n is
/// `nodeRuns.length`, S the node arrays' surplus over it. Every bucket is a `day` bucket. For the
/// layout engine only, like [writeGraphGrid].
@internal
Uint8List writeStackGrid({
  required LayoutMode mode,
  required LaneOrder order,
  required int unit,
  required int rows,
  required int lanes,
  required Int64List nodeRows,
  required Int32List nodeLanes,
  required Int32List nodeCols,
  required Int64List nodeDays,
  required Int32List edgeFroms,
  required Int32List edgeTos,
  required Uint8List edgeKinds,
  required Uint8List edgeRoutes,
  required Uint8List edgeBlocked,
  required Int64List bucketValues,
  required Int64List bucketStarts,
  required Int64List bucketEnds,
  required Int32List nodeRuns,
  required Uint8List runStates,
  required Int32List runNodes,
  required Int32List runStarts,
  required Int32List runMembers,
}) {
  final int nodes = nodeLanes.length;
  final int n = nodeRuns.length;
  final int e = edgeFroms.length;
  final int b = bucketValues.length;
  final int r = runStates.length;
  final int m = runMembers.length;
  final counts = <int>[nodes, nodes, nodes, e, e, e, e, e, b, b, b, b, nodes];
  final stackCounts = <int>[n, r, r, r + 1, m];
  final offsets = Int32List(_arrayCount);
  final stackOffsets = Int32List(_stackArrayCount);
  int end = _stackHeaderBytes;
  for (var k = 0; k < _arrayCount; k++) {
    final int start = (end + 7) & ~7;
    offsets[k] = start;
    end = start + counts[k] * _elementSizes[k];
  }
  for (var k = 0; k < _stackArrayCount; k++) {
    final int start = (end + 7) & ~7;
    stackOffsets[k] = start;
    end = start + stackCounts[k] * _stackElementSizes[k];
  }
  final bytes = Uint8List(end);
  final ByteBuffer buffer = bytes.buffer;
  final header = ByteData.sublistView(bytes, 0, _stackHeaderBytes)
    ..setInt32(4 * _slotVersion, GraphGridView.stackFormatVersion, Endian.little)
    ..setInt32(4 * _slotMode, mode.index, Endian.little)
    ..setInt32(4 * _slotOrder, order.index, Endian.little)
    ..setInt32(4 * _slotUnit, unit, Endian.little)
    ..setInt32(4 * _slotRows, rows, Endian.little)
    ..setInt32(4 * _slotLanes, lanes, Endian.little)
    ..setInt32(4 * _slotNodes, n, Endian.little)
    ..setInt32(4 * _slotEdges, e, Endian.little)
    ..setInt32(4 * _slotBuckets, b, Endian.little)
    ..setInt32(4 * _slotStacks, nodes - n, Endian.little)
    ..setInt32(4 * _slotRuns, r, Endian.little)
    ..setInt32(4 * _slotMembers, m, Endian.little);
  for (var k = 0; k < _arrayCount; k++) {
    header
      ..setInt32(4 * (_slotArrays + 2 * k), offsets[k], Endian.little)
      ..setInt32(4 * (_slotArrays + 2 * k + 1), counts[k], Endian.little);
  }
  for (var k = 0; k < _stackArrayCount; k++) {
    header
      ..setInt32(4 * (_slotStackArrays + 2 * k), stackOffsets[k], Endian.little)
      ..setInt32(4 * (_slotStackArrays + 2 * k + 1), stackCounts[k], Endian.little);
  }
  final Int32List row = buffer.asInt32List(offsets[_nodeRow], nodes);
  for (var i = 0; i < nodes; i++) {
    row[i] = nodeRows[i];
  }
  buffer.asInt32List(offsets[_nodeLane], nodes).setAll(0, nodeLanes);
  buffer.asInt32List(offsets[_nodeCol], nodes).setAll(0, nodeCols);
  buffer.asInt32List(offsets[_edgeFrom], e).setAll(0, edgeFroms);
  buffer.asInt32List(offsets[_edgeTo], e).setAll(0, edgeTos);
  buffer.asUint8List(offsets[_edgeKind], e).setAll(0, edgeKinds);
  buffer.asUint8List(offsets[_edgeRoute], e).setAll(0, edgeRoutes);
  buffer.asUint8List(offsets[_edgeBlocked], e).setAll(0, edgeBlocked);
  buffer.asUint8List(offsets[_bucketKind], b).fillRange(0, b, GraphGridView.bucketKindDay);
  buffer.asInt64List(offsets[_bucketValue], b).setAll(0, bucketValues);
  final Int32List start = buffer.asInt32List(offsets[_bucketStart], b);
  final Int32List bucketEnd = buffer.asInt32List(offsets[_bucketEnd], b);
  for (var k = 0; k < b; k++) {
    start[k] = bucketStarts[k];
    bucketEnd[k] = bucketEnds[k];
  }
  buffer.asInt64List(offsets[_nodeDay], nodes).setAll(0, nodeDays);
  buffer.asInt32List(stackOffsets[_nodeRun], n).setAll(0, nodeRuns);
  buffer.asUint8List(stackOffsets[_runState], r).setAll(0, runStates);
  buffer.asInt32List(stackOffsets[_runNode], r).setAll(0, runNodes);
  buffer.asInt32List(stackOffsets[_runStart], r + 1).setAll(0, runStarts);
  buffer.asInt32List(stackOffsets[_runMember], m).setAll(0, runMembers);
  return bytes;
}
