// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'layout_request.dart';

/// The grid header: 33 little-endian int32 slots at byte 0.
const _headerSlots = 33;

/// The header's byte length; the first array starts at the next multiple of 8 (136).
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
const _arrayCount = 12;

/// The element size in bytes of each array, in array order.
const _elementSizes = <int>[4, 4, 4, 4, 4, 1, 1, 1, 1, 8, 4, 4];

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
];

/// A layout's result (Story 4.11): the abstract grid of docs/graph-layout.md §3 — per node its
/// row, lane and column, per layout edge its route and `blocked` flag, per time bucket its row
/// range — read through typed-data views over ONE buffer, without a per-node object.
///
/// **Format** (format version [formatVersion]; little-endian; the contract of docs/graph-layout.md
/// §13):
/// - **Header:** 33 int32 slots at byte 0 — [0] the format version, [1] the mode
///   ([LayoutMode.index]: 0 compact, 1 free), [2] the lane order ([LaneOrder.index]: 0 greedy,
///   1 compact), [3] U (1 in `compact`, 16 in `free`), [4] rows, [5] lanes, [6] n, [7] E (the
///   layout edges), [8] B (the buckets), then for each of the twelve arrays below its byte offset
///   and its element count (slots 9 + 2k and 10 + 2k).
/// - **Arrays,** in this order, each starting at the next multiple of 8 after the previous one (the
///   first at byte 136): node row, node lane, node col (int32 × n); edge from, edge to
///   (int32 × E); edge kind, edge route, edge blocked (uint8 × E); bucket kind (uint8 × B); bucket
///   value (int64 × B); bucket start, bucket end (int32 × B).
/// - **Values:** a node's row is y (§4.2; in `free` in 1/U pitch units, y ≤ 48·(n − 1), so it
///   fits an int32). Edges are in §3's order — by child ascending, then by the parent's position
///   among the child's layout parents; `from` is the parent, `to` the child, and Missing parents
///   are no layout edges. Edge kinds are [edgeKindDirect] / [edgeKindIndirect], routes
///   [routeStraight] / [routeMerge] / [routeBranchOff] (§8.4's r), `blocked` 0 or 1. Buckets are
///   `free`'s day buckets ([bucketKindDay]), ascending; their value is the local-midnight instant
///   in epoch ms, their start and end the least and the largest y of their members.
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
  });

  /// Reads a grid buffer. A [bytes] view whose start is not 8-aligned in its buffer is copied
  /// once (see [copied]); otherwise every view reads [bytes] in place. Throws [FormatException]
  /// for a buffer shorter than the header, a format version other than [formatVersion], an
  /// unknown mode or order code, a unit that is not the mode's, a negative count, an array count
  /// that differs from its header count, or an array offset that is not 8-aligned or runs past
  /// the buffer. Little-endian host assumed (macOS).
  factory GraphGridView.fromBytes(Uint8List bytes) {
    final copy = bytes.offsetInBytes % 8 != 0;
    final data = copy ? Uint8List.fromList(bytes) : bytes;
    if (data.length < _headerBytes) {
      throw FormatException('a grid buffer needs its $_headerBytes-byte header, got ${data.length} bytes');
    }
    final header = ByteData.sublistView(data, 0, _headerBytes);
    int slot(int k) => header.getInt32(4 * k, Endian.little);

    final int version = slot(_slotVersion);
    if (version != formatVersion) {
      throw FormatException('grid format version $version, expected $formatVersion');
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
    final ByteBuffer buffer = data.buffer;
    final int base = data.offsetInBytes;
    final offsets = Int32List(_arrayCount);
    for (var k = 0; k < _arrayCount; k++) {
      final int offset = slot(_slotArrays + 2 * k);
      final int count = slot(_slotArrays + 2 * k + 1);
      final expected = k <= _nodeCol ? n : (k <= _edgeBlocked ? e : b);
      if (count != expected) {
        throw FormatException('grid ${_arrayNames[k]} array has $count entries, expected $expected');
      }
      if (offset % 8 != 0) {
        throw FormatException('grid ${_arrayNames[k]} array starts at byte $offset, which is not 8-aligned');
      }
      if (offset < _headerBytes || offset + count * _elementSizes[k] > data.length) {
        throw FormatException(
          'grid ${_arrayNames[k]} array at byte $offset runs outside the ${data.length}-byte buffer',
        );
      }
      offsets[k] = base + offset;
    }
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
      nodeRows: buffer.asInt32List(offsets[_nodeRow], n).asUnmodifiableView(),
      nodeLanes: buffer.asInt32List(offsets[_nodeLane], n).asUnmodifiableView(),
      nodeCols: buffer.asInt32List(offsets[_nodeCol], n).asUnmodifiableView(),
      edgeFroms: buffer.asInt32List(offsets[_edgeFrom], e).asUnmodifiableView(),
      edgeTos: buffer.asInt32List(offsets[_edgeTo], e).asUnmodifiableView(),
      edgeKinds: buffer.asUint8List(offsets[_edgeKind], e).asUnmodifiableView(),
      edgeRoutes: buffer.asUint8List(offsets[_edgeRoute], e).asUnmodifiableView(),
      edgeBlocked: buffer.asUint8List(offsets[_edgeBlocked], e).asUnmodifiableView(),
      bucketKinds: buffer.asUint8List(offsets[_bucketKind], b).asUnmodifiableView(),
      bucketValues: buffer.asInt64List(offsets[_bucketValue], b).asUnmodifiableView(),
      bucketStarts: buffer.asInt32List(offsets[_bucketStart], b).asUnmodifiableView(),
      bucketEnds: buffer.asInt32List(offsets[_bucketEnd], b).asUnmodifiableView(),
    );
  }

  /// The grid format version this view reads (header slot 0).
  static const formatVersion = 1;

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

  /// n, the nodes, index-aligned with the topology.
  final int nodeCount;

  /// E, the layout edges.
  final int edgeCount;

  /// B, the buckets.
  final int bucketCount;

  /// Each node's row (y), unmodifiable.
  final Int32List nodeRows;

  /// Each node's lane, unmodifiable.
  final Int32List nodeLanes;

  /// Each node's column, unmodifiable.
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
}

/// Writes a grid buffer in [GraphGridView]'s format: the header, then the twelve arrays. Every
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
    final count = k <= _nodeCol ? n : (k <= _edgeBlocked ? e : b);
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
      ..setInt32(4 * (_slotArrays + 2 * k + 1), k <= _nodeCol ? n : (k <= _edgeBlocked ? e : b), Endian.little);
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
  return bytes;
}
