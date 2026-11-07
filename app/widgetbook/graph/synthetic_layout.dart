// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:zanshin/src/features/graph/graph_breaks.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';

import 'fake_content.dart';

/// The scale sizes of the catalogue and the tests (Story 10.1 item 13(b)).
const syntheticSizes = <int>[10000, 50000, 100000];

/// A deterministic synthetic layout of [nodeCount] nodes over [lanes] columns (≥ 100 by default), seeded by [seed]:
/// several cards per row, branches, merges, indirect edges and Missing stubs. With [free] the rows are spread in
/// 1/16 pitch units (U = 16) by seeded gaps of one to two and a half pitches, and every 25 rows above the root make one
/// day bucket; the topology and columns stay the same. Every node carries [fakeContent] and [fakeRefs].
///
/// This is test and demo data written directly as a layout (the spike's 10k–100k outputs are not committed), not a
/// layout of a topology; the invariant checker gates it like every fixture.
///
/// With [longGapEvery] > 0 (Free only, Story 10.31's long history) every [longGapEvery]-th row starts after a quiet
/// stretch of 40 pitches and 400 days, and the rows come back shortened as the worker's layout shortens them
/// ([GraphBreaks]), with their [GraphLayout.breaks]. Keep it a multiple of 25 so the gaps fall between day buckets.
RecordedGraphLayout syntheticLayout(
  int nodeCount, {
  bool free = false,
  int seed = 101,
  int lanes = 120,
  int longGapEvery = 0,
}) {
  assert(longGapEvery % 25 == 0, 'a long gap starts a day bucket');
  final rng = math.Random(seed);
  // Generated bottom-up: id 0 is the root (the oldest); the layout's node index is nodeCount − 1 − id.
  final rowOf = Int32List(nodeCount);
  final laneOf = Int32List(nodeCount);
  final parents = List<List<int>>.generate(nodeCount, (_) => const <int>[]);
  final head = Int32List(lanes)..fillRange(0, lanes, -1);
  final active = <int>[];
  var made = 0;
  void place(int row, int lane, List<int> of) {
    rowOf[made] = row;
    laneOf[made] = lane;
    parents[made] = of;
    made++;
  }

  if (nodeCount > 0) {
    place(0, 0, const <int>[]);
    head[0] = 0;
    active.add(0);
  }
  var row = 1;
  while (made < nodeCount) {
    final used = <int>{};
    final ended = <int>{};
    final int k = const <int>[1, 1, 1, 2, 2, 2, 3, 3, 4, 4][rng.nextInt(10)];
    for (var slot = 0; slot < k && made < nodeCount; slot++) {
      final double p = rng.nextDouble();
      final freeLanes = <int>[
        for (var lane = 1; lane < lanes; lane++)
          if (head[lane] < 0 && !used.contains(lane)) lane,
      ];
      if (p < .12 && freeLanes.isNotEmpty) {
        final int from = active[rng.nextInt(active.length)];
        final int lane = rng.nextDouble() < .7 ? freeLanes.first : freeLanes[rng.nextInt(freeLanes.length)];
        used.add(lane);
        place(row, lane, <int>[head[from]]);
      } else if (p < .22 && active.length >= 2) {
        final int into = active[rng.nextInt(active.length)];
        final int other = active[rng.nextInt(active.length)];
        if (other == into || used.contains(into)) {
          continue;
        }
        used.add(into);
        place(row, into, <int>[head[into], head[other]]);
        if (other != 0 && rng.nextBool()) {
          ended.add(other);
        }
      } else {
        // Most commits land on the trunk and the lanes next to it, so every row of the left columns is busy.
        final near = <int>[
          for (final lane in active)
            if (lane < 3) lane,
        ];
        final int lane = rng.nextDouble() < .8 && near.isNotEmpty
            ? near[rng.nextInt(near.length)]
            : active[rng.nextInt(active.length)];
        if (used.contains(lane)) {
          continue;
        }
        used.add(lane);
        place(row, lane, <int>[head[lane]]);
        if (lane != 0 && rng.nextDouble() < .04) {
          ended.add(lane);
        }
      }
    }
    if (used.isEmpty) {
      continue;
    }
    // The row's new heads, then the lanes that end; a lane taken over in this row keeps its new head.
    for (int id = made - used.length; id < made; id++) {
      if (head[laneOf[id]] < 0) {
        active.add(laneOf[id]);
      }
      head[laneOf[id]] = id;
    }
    for (final int lane in ended.difference(used)) {
      head[lane] = -1;
      active.remove(lane);
    }
    row++;
  }

  final unit = free ? 16 : 1;
  // Free: strictly increasing y with gaps of 16–40 (one to two and a half pitches), so every invariant still holds.
  final gaps = math.Random(seed + 1);
  final y = Int32List(row);
  // The days skipped by the long gaps up to and including row r.
  final skippedDays = Int32List(row);
  for (var r = 1; r < row; r++) {
    final bool longGap = free && longGapEvery > 0 && r > 1 && (r - 1) % longGapEvery == 0;
    skippedDays[r] = skippedDays[r - 1] + (longGap ? 400 : 0);
    y[r] = free ? y[r - 1] + 16 + gaps.nextInt(25) + (longGap ? 40 * 16 : 0) : r;
  }
  final missing = math.Random(seed + 2);
  final keys = <String>[];
  final cols = Int32List(nodeCount);
  final nodeRows = Int32List(nodeCount);
  final parentCounts = Int32List(nodeCount);
  final elided = Uint8List(nodeCount);
  final timestamps = <int?>[];
  final edgeChildren = <int>[];
  final edgeParents = <int>[];
  final edgeKinds = <GraphEdgeKind>[];
  final edgeShapes = <GraphEdgeShape>[];
  var colCount = 0;
  for (var i = 0; i < nodeCount; i++) {
    final int id = nodeCount - 1 - i;
    keys.add('n$id');
    cols[i] = laneOf[id];
    colCount = math.max(colCount, laneOf[id] + 1);
    nodeRows[i] = y[rowOf[id]];
    final bool stub = id > 0 && missing.nextDouble() < .01;
    elided[i] = stub ? 1 : 0;
    parentCounts[i] = parents[id].length + (stub ? 1 : 0);
    // Half an hour per row inside its day bucket (25 rows per day, below), so a card's time falls in its day.
    timestamps.add(
      id == 0
          ? null
          : _baseMidnight +
                ((rowOf[id] - 1) ~/ 25 + skippedDays[rowOf[id]]) * 86400000 +
                (rowOf[id] - 1) % 25 * 1800000,
    );
    for (var position = 0; position < parents[id].length; position++) {
      final int parent = parents[id][position];
      edgeChildren.add(i);
      edgeParents.add(nodeCount - 1 - parent);
      edgeKinds.add(missing.nextDouble() < .05 ? GraphEdgeKind.indirect : GraphEdgeKind.direct);
      edgeShapes.add(switch (position) {
        0 when laneOf[parent] == laneOf[id] => GraphEdgeShape.straight,
        0 => GraphEdgeShape.branchOff,
        _ => GraphEdgeShape.merge,
      });
    }
  }
  // Free: one day per 25 row indices above the root (which is in no day), oldest first.
  final bucketValues = <int>[];
  final bucketFirstRows = <int>[];
  final bucketLastRows = <int>[];
  if (free) {
    for (var first = 1; first < row; first += 25) {
      bucketValues.add(_baseMidnight + (bucketValues.length + skippedDays[first]) * 86400000);
      bucketFirstRows.add(y[first]);
      bucketLastRows.add(y[math.min(first + 24, row - 1)]);
    }
  }
  // The long history comes back shortened, as BackendGraphLayout shortens a worker layout.
  final GraphBreaks cuts = longGapEvery > 0 && free
      ? GraphBreaks.compute(nodeRows, unit, (node) => timestamps[node])
      : GraphBreaks.none;
  for (var i = 0; i < nodeCount; i++) {
    nodeRows[i] = cuts.map(nodeRows[i]);
  }
  for (var b = 0; b < bucketValues.length; b++) {
    bucketFirstRows[b] = cuts.map(bucketFirstRows[b]);
    bucketLastRows[b] = cuts.map(bucketLastRows[b]);
  }
  return RecordedGraphLayout(
    mode: free ? GraphMode.free : GraphMode.compact,
    unit: unit,
    rows: nodeCount == 0 ? 0 : cuts.map(y[row - 1]) + unit,
    breaks: cuts.breaks,
    colCount: colCount,
    keys: keys,
    cols: cols,
    nodeRows: nodeRows,
    parentCounts: parentCounts,
    elided: elided,
    timestamps: timestamps,
    edgeChildren: Int32List.fromList(edgeChildren),
    edgeParents: Int32List.fromList(edgeParents),
    edgeKinds: edgeKinds,
    edgeShapes: edgeShapes,
    bucketValues: bucketValues,
    bucketFirstRows: Int32List.fromList(bucketFirstRows),
    bucketLastRows: Int32List.fromList(bucketLastRows),
    rootIndex: nodeCount == 0 ? null : nodeCount - 1,
    workingCopyIndex: nodeCount == 0 ? null : nodeCount - 1 - head[0],
    // The root is in immutable() (GraphLayout.isImmutable).
    flags: nodeCount == 0 ? null : (Uint8List(nodeCount)..[nodeCount - 1] = RecordedGraphLayout.flagImmutable),
    contents: <GraphCommitContent?>[for (var i = 0; i < nodeCount; i++) fakeContent(i, keys[i])],
    refs: <List<GraphRef>>[for (var i = 0; i < nodeCount; i++) fakeRefs(i, keys[i])],
  );
}

/// A UTC midnight, the synthetic layouts' oldest day.
const _baseMidnight = 1789948800000;
