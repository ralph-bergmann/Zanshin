// SPDX-License-Identifier: MIT

// The product engine's invariant checks (Story 4.11): docs/graph-layout.md §7.3 I1–I6 with the
// amended `free` I5, the `compact` order against greedy, literal model-cost references, and the
// seeded random DAGs they run on. Ported from the spike's Dart tests
// (spikes/graph-layout-ab/dart/test/layout_test.dart), minus `time` and `optimized`. Story 4.14:
// joint columns — I8 across modes, the joint model cost, every node's day key.

import 'dart:math';
import 'dart:typed_data';

import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/graph_layout/compact_order.dart';
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import 'support/spec_json.dart';
import 'support/topology_envelope.dart';

/// 2001-09-09T01:46:40Z.
const now = 1000000000000;

/// One minute in ms.
const minute = 60000;

/// One hour in ms.
const hour = 3600000;

/// One day in ms.
const day = 86400000;

/// A random children-first DAG: mostly chains, some merges, indirect and missing parents, priority
/// ties, ~10 % non-monotonic timestamps, some null timestamps on non-root nodes, a null-ts root at
/// the end and now and then a second root, and a UTC offset anywhere in ±1440.
LayoutInput randomGraph(Random rnd, int n, {bool branchy = false}) {
  final parents = <List<Object?>>[];
  final ts = <int?>[];
  final roots = <int>{if (n > 0) n - 1};
  int t = now + 5 * minute;
  for (var i = 0; i < n; i++) {
    t -= i < n ~/ 3 ? rnd.nextInt(30 * minute) : rnd.nextInt(2 * day);
    ts.add(rnd.nextInt(25) == 0 ? null : (rnd.nextInt(10) == 0 ? t + rnd.nextInt(4 * day) - 2 * day : t));
    final ps = <Object?>[];
    final used = <int>{};
    final int count = i == n - 1 ? 0 : const [0, 1, 1, 1, 1, 1, 2, 2, 3][rnd.nextInt(9)];
    for (var k = 0; k < count; k++) {
      final span = branchy ? 40 : (rnd.nextInt(8) == 0 ? n : 6);
      final int idx = i + 1 + rnd.nextInt(min(span, n - i - 1));
      if (!used.add(idx)) {
        continue;
      }
      ps.add(rnd.nextInt(10) == 0 ? Ind(idx) : idx);
    }
    if (rnd.nextInt(15) == 0) {
      ps.insert(rnd.nextInt(ps.length + 1), null);
    }
    if (ps.isEmpty && rnd.nextInt(20) == 0) {
      roots.add(i);
    }
    parents.add(ps);
  }
  if (n > 0) {
    ts[n - 1] = null;
  }
  return specGraph(
    parents,
    priority: [for (var i = 0; i < n; i++) rnd.nextInt(3)],
    ts: ts,
    roots: roots,
    offset: rnd.nextInt(2881) - 1440,
  );
}

/// A random topology envelope (support/topology_envelope.dart) of [n] nodes, children-first, the
/// last one the root: every non-root node gets 0–4 Direct / Indirect edges to later nodes, now and
/// then REPEATED targets (a second edge to a target it already has, of either kind) and Missing
/// edges (target −1) anywhere among them; timestamps half of the time (non-monotonic now and then,
/// the root's slot 0); 0–3 anchors of up to 3 nodes each. Returns the envelope and every node's
/// edges as the envelope lists them.
({Uint8List envelope, List<List<(int, fbs.GraphEdgeKind)>> edges}) randomTopology(Random rnd, int n) {
  const List<fbs.GraphEdgeKind> kinds = [
    fbs.GraphEdgeKind.Direct,
    fbs.GraphEdgeKind.Direct,
    fbs.GraphEdgeKind.Indirect,
  ];
  final edges = <List<(int, fbs.GraphEdgeKind)>>[];
  for (var i = 0; i < n; i++) {
    final e = <(int, fbs.GraphEdgeKind)>[];
    final int count = i == n - 1 ? 0 : const [0, 1, 1, 1, 2, 2, 3, 4][rnd.nextInt(8)];
    for (var k = 0; k < count; k++) {
      final span = rnd.nextInt(6) == 0 ? n : 6;
      e.add((i + 1 + rnd.nextInt(min(span, n - i - 1)), kinds[rnd.nextInt(kinds.length)]));
      if (rnd.nextInt(3) == 0) {
        // A repeated target, as jj-lib yields for a merge whose hidden parent reaches a visible one.
        e.insert(rnd.nextInt(e.length + 1), (e[rnd.nextInt(e.length)].$1, kinds[rnd.nextInt(kinds.length)]));
      }
    }
    while (rnd.nextInt(8) == 0) {
      e.insert(rnd.nextInt(e.length + 1), (-1, fbs.GraphEdgeKind.Missing));
    }
    edges.add(e);
  }
  int t = now;
  final List<int>? timestamps = rnd.nextBool()
      ? [
          for (var i = 0; i < n; i++)
            if (i == n - 1) 0 else (t -= rnd.nextInt(2 * day)) + (rnd.nextInt(10) == 0 ? day : 0),
        ]
      : null;
  final List<List<int>> anchors = [
    for (var a = rnd.nextInt(4); a > 0; a--)
      ({for (var k = rnd.nextInt(4); k > 0 && n > 0; k--) rnd.nextInt(n)}.toList()..sort()),
  ];
  return (
    envelope: topologyEnvelope(edges, roots: {if (n > 0) n - 1}, timestamps: timestamps, anchors: anchors),
    edges: edges,
  );
}

/// docs/graph-layout.md §2's repeated-target rule, read literally for one node's [edges]: every
/// Missing edge stays where it is; a Direct / Indirect edge is kept only if no EARLIER edge has its
/// target, and then it is `direct` iff ANY edge to that target is Direct.
List<(int, int)> naiveRepeatedTargets(List<(int, fbs.GraphEdgeKind)> edges) => [
  for (var p = 0; p < edges.length; p++)
    if (edges[p].$2 == fbs.GraphEdgeKind.Missing)
      (edges[p].$1, parentMissing)
    else if (!edges.take(p).any((e) => e.$2 != fbs.GraphEdgeKind.Missing && e.$1 == edges[p].$1))
      (
        edges[p].$1,
        edges.any((e) => e.$1 == edges[p].$1 && e.$2 == fbs.GraphEdgeKind.Direct) ? parentDirect : parentIndirect,
      ),
];

/// The layout parents LP(i) of every node: the non-missing parents in input order.
List<List<int>> layoutParents(LayoutInput g) => [
  for (var i = 0; i < g.n; i++)
    [
      for (int k = g.parStart[i]; k < g.parStart[i + 1]; k++)
        if (g.parIdx[k] >= 0) g.parIdx[k],
    ],
];

/// The clamped T(i) of §4.2 free, steps 1–2, from scratch.
List<int> clampedT(LayoutInput g, List<List<int>> lp) {
  var tmin = 0;
  var found = false;
  for (var i = 0; i < g.n; i++) {
    if (g.hasTs[i] != 0 && (!found || g.ts[i] < tmin)) {
      tmin = g.ts[i];
      found = true;
    }
  }
  final List<int> tt = List.filled(g.n, 0);
  for (int i = g.n - 1; i >= 0; i--) {
    tt[i] = [if (g.isRoot[i] != 0 || g.hasTs[i] == 0) tmin else g.ts[i], for (final p in lp[i]) tt[p]].reduce(max);
  }
  return tt;
}

/// The failures of docs/graph-layout.md §7.3 I1–I6 — I5 as amended on 2026-10-01 — plus the
/// header fields, the edge order and kinds of §3, col = lane (both shipped orders keep π the
/// identity) and every node's day key (Story 4.14: dk of its clamped T, [GraphGridView.noDay] for a
/// root, in both modes), for the grid [r] laid out from [g]; empty when every check holds.
List<String> invariantFailures(LayoutInput g, GraphGridView r) {
  final fails = <String>[];
  void check(bool ok, String message) {
    if (!ok && fails.length < 8) {
      fails.add(message);
    }
  }

  final int n = g.n;
  final int u = r.unit;
  final Int32List y = r.nodeRows;
  check(n == r.nodeCount, 'node count');
  if (n != r.nodeCount) {
    return fails;
  }
  check(u == unitOf(r.mode), 'unit');
  final List<List<int>> lp = layoutParents(g);
  var e = 0;
  final straight = <int>{};
  for (var i = 0; i < n; i++) {
    var pos = 0;
    for (int k = g.parStart[i]; k < g.parStart[i + 1]; k++) {
      final int p = g.parIdx[k];
      if (p < 0) {
        continue;
      }
      if (e >= r.edgeCount) {
        check(false, 'too few edges');
        return fails;
      }
      check(r.edgeFroms[e] == p && r.edgeTos[e] == i, 'edge $e is not $p→$i');
      check(r.edgeKinds[e] == g.parKind[k], 'edge $e kind');
      check(y[i] >= y[p] + u, 'I1 edge $p→$i');
      final int route = r.edgeRoutes[e];
      final blocked = r.edgeBlocked[e] != 0;
      final same = r.nodeLanes[p] == r.nodeLanes[i];
      check((route == routeStraight) == same, 'I3 straight ⇔ same lane, $p→$i');
      check(!same || pos == 0, 'I3 straight ⇒ first parent, $p→$i');
      check(route != routeMerge || (pos >= 1 && !blocked), 'I3 merge, $p→$i');
      check(!blocked || !same, 'I3 blocked ⇒ lanes differ, $p→$i');
      if (route == routeStraight) {
        straight.add(p * n + i);
      }
      pos++;
      e++;
    }
  }
  check(e == r.edgeCount, 'edge count');
  // I2: per lane, consecutive cards by y keep 2U, or U along a straight edge.
  final byLane = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    (byLane[r.nodeLanes[i]] ??= []).add(i);
  }
  for (final List<int> nodes in byLane.values) {
    nodes.sort((a, b) => y[a].compareTo(y[b]));
    for (var k = 1; k < nodes.length; k++) {
      final int lo = nodes[k - 1];
      final int hi = nodes[k];
      final int need = straight.contains(lo * n + hi) ? u : 2 * u;
      check(y[hi] - y[lo] >= need, 'I2 lane ${r.nodeLanes[lo]}: nodes $lo, $hi');
    }
  }
  // I4: both shipped orders keep π the identity.
  for (var i = 0; i < n; i++) {
    check(r.nodeCols[i] == r.nodeLanes[i], 'I4 col = lane, node $i');
  }
  check(r.rows == (n == 0 ? 0 : y.reduce(max) + u), 'rows');
  check(r.lanes == (n == 0 ? 0 : r.nodeLanes.reduce(max) + 1), 'lanes');
  final List<int> days = clampedT(g, lp);
  for (var i = 0; i < n; i++) {
    final int want = g.isRoot[i] != 0 ? GraphGridView.noDay : dayKey(days[i], g.utcOffsetMin);
    check(r.nodeDays[i] == want, 'day key of node $i');
  }
  switch (r.mode) {
    case LayoutMode.compact:
      check(r.bucketCount == 0, 'I5 compact: no buckets');
    case LayoutMode.free:
      final List<int> tt = clampedT(g, lp);
      _freeDayBuckets(g, r, tt, check);
      // I6: y never decreases in (T asc, i desc) order.
      final List<int> order = List.generate(n, (i) => i)
        ..sort((a, b) => tt[a] != tt[b] ? tt[a].compareTo(tt[b]) : b - a);
      for (var k = 1; k < n; k++) {
        check(y[order[k]] >= y[order[k - 1]], 'I6 at node ${order[k]}');
      }
  }
  return fails;
}

/// §7.3 I5 for `free` (amended 2026-10-01 and 2026-10-31, Story 4.16): `day` buckets only, values
/// strictly ascending, start ≤ end, end_k + U ≤ start_{k+1} (the band around a divider is
/// card-free), every non-root node inside the bucket of its clamped T's day, start / end its
/// members' min / max y, and no bucket iff no non-root node.
void _freeDayBuckets(LayoutInput g, GraphGridView r, List<int> tt, void Function(bool, String) check) {
  final int count = r.bucketCount;
  for (var b = 0; b < count; b++) {
    check(r.bucketKinds[b] == GraphGridView.bucketKindDay, 'I5 free: bucket $b kind');
    check(r.bucketStarts[b] <= r.bucketEnds[b], 'I5 free: bucket $b start ≤ end');
    if (b > 0) {
      check(r.bucketValues[b - 1] < r.bucketValues[b], 'I5 free: bucket $b ascending');
      check(r.bucketEnds[b - 1] + modelUnits[1] <= r.bucketStarts[b], 'I5 free: bucket $b a pitch above ${b - 1}');
    }
  }
  final List<int> lo = List.filled(count, 1 << 62);
  final List<int> hi = List.filled(count, -(1 << 62));
  var nonRoot = 0;
  for (var i = 0; i < g.n; i++) {
    if (g.isRoot[i] != 0) {
      continue;
    }
    nonRoot++;
    final int b = r.bucketValues.indexOf(dayKey(tt[i], g.utcOffsetMin));
    check(b >= 0, 'I5 free: node $i has no bucket of its day');
    if (b < 0) {
      continue;
    }
    lo[b] = min(lo[b], r.nodeRows[i]);
    hi[b] = max(hi[b], r.nodeRows[i]);
  }
  check((count == 0) == (nonRoot == 0), 'I5 free: a bucket iff a non-root node');
  for (var b = 0; b < count; b++) {
    check(r.bucketStarts[b] == lo[b] && r.bucketEnds[b] == hi[b], 'I5 free: bucket $b start / end');
  }
}

/// A greedy layout of [g] in [mode], through routing (the state the `compact` order starts from).
LayoutEngine greedyEngine(LayoutInput g, LayoutMode mode) => LayoutEngine(g, mode)
  ..layering()
  ..packLanes()
  ..markBlocked()
  ..route();

/// The failures of §4.7's claims for the `compact` order's grid [compact] against greedy's
/// [greedy], both laid out from [g] in one mode: the same rows, buckets, edge order and routes,
/// `blocked` unchanged on every merge (pos ≥ 1), col = lane, the trunk's lane-0 nodes fixed, no
/// empty column, no more lanes than greedy, and a model cost (§4.7) no higher than greedy's.
List<String> compactAgainstGreedy(LayoutInput g, GraphGridView greedy, GraphGridView compact) {
  final fails = <String>[];
  void check(bool ok, String message) {
    if (!ok && fails.length < 8) {
      fails.add(message);
    }
  }

  bool same(List<int> a, List<int> b) =>
      a.length == b.length && Iterable<int>.generate(a.length).every((k) => a[k] == b[k]);
  check(same(compact.nodeRows, greedy.nodeRows), 'rows differ');
  check(
    same(compact.bucketValues, greedy.bucketValues) &&
        same(compact.bucketStarts, greedy.bucketStarts) &&
        same(compact.bucketEnds, greedy.bucketEnds),
    'buckets differ',
  );
  check(same(compact.edgeFroms, greedy.edgeFroms) && same(compact.edgeTos, greedy.edgeTos), 'edge order differs');
  check(same(compact.edgeRoutes, greedy.edgeRoutes), 'routes differ');
  check(compact.rows == greedy.rows, 'header rows differ');
  final LayoutEngine l = greedyEngine(g, compact.mode);
  for (var e = 0; e < compact.edgeCount; e++) {
    if (e - l.lpStart[compact.edgeTos[e]] >= 1) {
      check(compact.edgeBlocked[e] == greedy.edgeBlocked[e], 'blocked differs on merge $e');
    }
  }
  for (var i = 0; i < g.n; i++) {
    check(compact.nodeCols[i] == compact.nodeLanes[i], 'col ≠ lane at node $i');
    check((compact.nodeLanes[i] == 0) == (greedy.nodeLanes[i] == 0), 'lane 0 changed at node $i');
  }
  check(compact.lanes <= greedy.lanes, 'more lanes than greedy');
  check(compact.nodeLanes.toSet().length == compact.lanes, 'an empty column');
  final int greedyCost = naiveCompactCost(g, l.lane);
  final int compactCost = naiveCompactCost(g, compact.nodeLanes);
  check(compactCost <= greedyCost, 'joint model cost $compactCost > greedy $greedyCost');
  return fails;
}

/// The failures of §7.3 I8 (Story 4.14) for a `compact` grid [c] and a `free` grid [f] of one
/// input, order and stack request: the same `lanes`, and every node — stack nodes included — the
/// same lane and col, hidden ones −1 in both; the same day keys too. Empty when it holds.
List<String> i8Failures(GraphGridView c, GraphGridView f) {
  final fails = <String>[];
  if (c.mode != LayoutMode.compact || f.mode != LayoutMode.free) {
    fails.add('I8 needs a compact and a free grid');
  }
  if (c.lanes != f.lanes) {
    fails.add('I8 lanes ${c.lanes} ≠ ${f.lanes}');
  }
  if (c.nodeLanes.length != f.nodeLanes.length) {
    fails.add('I8 node count ${c.nodeLanes.length} ≠ ${f.nodeLanes.length}');
    return fails;
  }
  for (var i = 0; i < c.nodeLanes.length && fails.length < 8; i++) {
    if (c.nodeLanes[i] != f.nodeLanes[i] || c.nodeCols[i] != f.nodeCols[i]) {
      fails.add('I8 node $i: lane/col ${c.nodeLanes[i]}/${c.nodeCols[i]} ≠ ${f.nodeLanes[i]}/${f.nodeCols[i]}');
    }
    if (c.nodeDays[i] != f.nodeDays[i]) {
      fails.add('node $i: day key differs between the modes');
    }
  }
  return fails;
}

/// Naive segments of a greedy layout: chains of straight edges, with their §4.3 reservations
/// [a, b) re-derived literally. Returns (segment per node, a per segment, b per segment).
(List<int>, List<int>, List<int>) naiveSegments(LayoutEngine l) {
  final int n = l.n;
  final int u = l.unit;
  final Int64List y = l.y;
  final Int32List fp = l.fp;
  final Int32List prio = l.input.priority;
  final List<int> cont = List.filled(n, -1);
  for (var i = 0; i < n; i++) {
    final int f = fp[i];
    if (f >= 0 && (cont[f] < 0 || prio[i] < prio[cont[f]])) {
      cont[f] = i;
    }
  }
  final List<int> seg = List.filled(n, -1);
  final a = <int>[];
  final b = <int>[];
  for (int i = n - 1; i >= 0; i--) {
    final int f = fp[i];
    if (f >= 0 && l.routes[l.lpStart[i]] == routeStraight) {
      seg[i] = seg[f];
    } else {
      seg[i] = a.length;
      a.add(1 << 60);
      b.add(-(1 << 60));
    }
  }
  for (var i = 0; i < n; i++) {
    final List<int> ends = [
      y[i],
      if (cont[i] >= 0) y[cont[i]] - u,
      for (int s = l.chStart[i]; s < l.chStart[i + 1]; s++)
        if (l.chPos[s] >= 1) y[l.chIdx[s]] - u,
    ];
    final int ai = fp[i] >= 0 ? y[fp[i]] + u : y[i];
    final int bi = ends.reduce(max) + 2 * u;
    a[seg[i]] = min(a[seg[i]], ai);
    b[seg[i]] = max(b[seg[i]], bi);
  }
  return (seg, a, b);
}

/// §4.7's joint model cost (amended 2026-10-27) of [lanes] (per node) over [g]'s joint greedy
/// layout, from scratch: 16·cost_compact + cost_free, each [naiveModelCost] in its model's greedy
/// engine (the lanes are joint, so both engines share them; y, U and routes are the model's).
int naiveCompactCost(LayoutInput g, List<int> lanes) =>
    16 * naiveModelCost(greedyEngine(g, LayoutMode.compact), lanes) +
    naiveModelCost(greedyEngine(g, LayoutMode.free), lanes);

/// §4.7's model cost of [lanes] (per node) in the vertical model of the greedy layout [l], from
/// scratch: U·(400·X + 4·Len) + κ·Σ column·(b − a), with blocked-merge verticals clipped to
/// 10·a − 3U.
int naiveModelCost(LayoutEngine l, List<int> lanes) {
  final int u = l.unit;
  final Int64List y = l.y;
  final (List<int> seg, List<int> a, List<int> b) = naiveSegments(l);
  final verticals = <List<int>>[]; // [col, lo, hi]
  final horizontals = <List<int>>[]; // [colA, colB, level]
  for (var e = 0; e < l.edgeCount; e++) {
    final int p = l.edgeParent[e];
    final int i = l.edgeChild[e];
    final int botP = 10 * y[p];
    final int botI = 10 * y[i];
    final int top = botP + 5 * u;
    final int up = botP + 7 * u;
    final int dn = botI - 2 * u;
    switch (l.routes[e]) {
      case routeStraight:
        verticals.add([lanes[p], top, botI]);
      case routeMerge:
        verticals
          ..add([lanes[p], top, dn])
          ..add([lanes[i], dn, botI]);
        horizontals.add([lanes[p], lanes[i], dn]);
      case _:
        verticals.add([lanes[i], max(up, 10 * a[seg[i]] - 3 * u), botI]);
        horizontals.add([lanes[p], lanes[i], up]);
    }
  }
  var x = 0;
  var len = 0;
  var grav = 0;
  for (final [int ca, int cb, int level] in horizontals) {
    len += (ca - cb).abs();
    for (final [int c, int lo, int hi] in verticals) {
      if (min(ca, cb) < c && c < max(ca, cb) && lo < level && level < hi) {
        x++;
      }
    }
  }
  final List<int> col = List.filled(a.length, -1);
  for (var i = 0; i < l.n; i++) {
    col[seg[i]] = lanes[i];
  }
  for (var s = 0; s < a.length; s++) {
    grav += compactGravity * col[s] * (b[s] - a[s]);
  }
  return u * (400 * x + 4 * len) + grav;
}

/// The segments [lanes] puts into one column overlap nowhere, and no segment is split over
/// columns; the failures, empty when both hold.
List<String> reservationFailures(LayoutEngine l, List<int> lanes) {
  final (List<int> seg, List<int> a, List<int> b) = naiveSegments(l);
  final fails = <String>[];
  final List<int> colOf = List.filled(a.length, -1);
  for (var i = 0; i < l.n; i++) {
    if (colOf[seg[i]] >= 0 && colOf[seg[i]] != lanes[i]) {
      fails.add('segment ${seg[i]} split over columns');
    }
    colOf[seg[i]] = lanes[i];
  }
  final byCol = <int, List<int>>{};
  for (var s = 0; s < a.length; s++) {
    (byCol[colOf[s]] ??= []).add(s);
  }
  for (final MapEntry(key: int c, value: List<int> segs) in byCol.entries) {
    segs.sort((s, t) => a[s] - a[t]);
    for (var k = 1; k < segs.length; k++) {
      if (b[segs[k - 1]] > a[segs[k]]) {
        fails.add('reservations overlap in column $c');
      }
    }
  }
  return fails;
}

/// §4.6 tick-model crossings of a grid by column, every horizontal × vertical pair.
int tickCrossings(GraphGridView r) {
  final int u = r.unit;
  final verticals = <List<int>>[]; // [col, lo, hi]
  final horizontals = <List<int>>[]; // [colA, colB, level]
  for (var e = 0; e < r.edgeCount; e++) {
    final int p = r.edgeFroms[e];
    final int i = r.edgeTos[e];
    final int botP = 10 * r.nodeRows[p];
    final int botI = 10 * r.nodeRows[i];
    final int top = botP + 5 * u;
    final int up = botP + 7 * u;
    final int dn = botI - 2 * u;
    switch (r.edgeRoutes[e]) {
      case routeStraight:
        verticals.add([r.nodeCols[p], top, botI]);
      case routeMerge:
        verticals
          ..add([r.nodeCols[p], top, dn])
          ..add([r.nodeCols[i], dn, botI]);
        horizontals.add([r.nodeCols[p], r.nodeCols[i], dn]);
      case _:
        verticals.add([r.nodeCols[i], up, botI]);
        horizontals.add([r.nodeCols[p], r.nodeCols[i], up]);
    }
  }
  var x = 0;
  for (final [int a, int b, int level] in horizontals) {
    for (final [int c, int lo, int hi] in verticals) {
      if (min(a, b) < c && c < max(a, b) && lo < level && level < hi) {
        x++;
      }
    }
  }
  return x;
}
