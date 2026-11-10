// SPDX-License-Identifier: MIT

// The product engine's invariant checks: docs/graph-layout.md §7.3 I1–I6 with the amended `free` I5
// and I2–I4 as restated on 2026-11-10, the branch columns read literally, every node's day key, and
// the seeded random DAGs they run on.

import 'dart:math';
import 'dart:typed_data';

import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
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

/// The failures of docs/graph-layout.md §7.3 I1–I6 — I5 as amended on 2026-10-01, I2 and I3 as
/// restated on 2026-11-10 — plus the header fields, the edge order and kinds of §3, col = lane (I4), no
/// empty column and every node's day key (dk of its clamped T, [GraphGridView.noDay] for a root, in
/// both modes), for the grid [r] laid out from [g]; empty when every check holds.
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
      check(route != routeMerge || (pos >= 1 && !blocked), 'I3 merge, $p→$i');
      check(!blocked || !same, 'I3 blocked ⇒ lanes differ, $p→$i');
      pos++;
      e++;
    }
  }
  check(e == r.edgeCount, 'edge count');
  // I2: in one column, consecutive cards by y keep at least U.
  final byLane = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    (byLane[r.nodeLanes[i]] ??= []).add(i);
  }
  for (final List<int> nodes in byLane.values) {
    nodes.sort((a, b) => y[a].compareTo(y[b]));
    for (var k = 1; k < nodes.length; k++) {
      final int lo = nodes[k - 1];
      final int hi = nodes[k];
      check(y[hi] - y[lo] >= u, 'I2 column ${r.nodeLanes[lo]}: nodes $lo, $hi');
    }
  }
  // I4: col = lane.
  for (var i = 0; i < n; i++) {
    check(r.nodeCols[i] == r.nodeLanes[i], 'I4 col = lane, node $i');
  }
  check(r.rows == (n == 0 ? 0 : y.reduce(max) + u), 'rows');
  check(r.lanes == (n == 0 ? 0 : r.nodeLanes.reduce(max) + 1), 'lanes');
  check(byLane.length == r.lanes, 'no column is empty');
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

/// cont(j) of §4.3, read literally over the layout parents [lp]: the child with fp = j and the least
/// (priority, index), or −1.
List<int> naiveContinuations(LayoutInput g, List<List<int>> lp) {
  final List<int> cont = List.filled(g.n, -1);
  for (var i = 0; i < g.n; i++) {
    if (lp[i].isNotEmpty) {
      final int f = lp[i].first;
      if (cont[f] < 0 || g.priority[i] < g.priority[cont[f]]) {
        cont[f] = i;
      }
    }
  }
  return cont;
}

/// The branches of §4.3 (Branch columns, amended 2026-11-10), read literally on the rows [y] in units
/// of [u]: per node its branch, and per branch its bottom card and reserved rows [lo, hi]; the main
/// branch is `main`, −1 without a node.
({List<int> branchOf, List<int> bottom, List<int> lo, List<int> hi, int main}) naiveBranches(
  LayoutInput g,
  List<int> y,
  int u,
  List<int> cont,
) {
  final int n = g.n;
  final List<List<int>> lp = layoutParents(g);
  final List<int> branchOf = List.filled(n, -1);
  final bottom = <int>[];
  for (int i = n - 1; i >= 0; i--) {
    final int? f = lp[i].firstOrNull;
    if (f != null && cont[f] == i) {
      branchOf[i] = branchOf[f];
    } else {
      branchOf[i] = bottom.length;
      bottom.add(i);
    }
  }
  final List<int> lo = [
    for (final int b in bottom)
      if (lp[b].isNotEmpty) y[lp[b].first] + u else y[b],
  ];
  final List<int> hi = [for (final int b in bottom) y[b]];
  for (var i = 0; i < n; i++) {
    hi[branchOf[i]] = max(hi[branchOf[i]], y[i]);
    for (final int p in lp[i].skip(1)) {
      hi[branchOf[p]] = max(hi[branchOf[p]], y[i] - u);
    }
  }
  var best = -1;
  for (var i = 0; i < n; i++) {
    final bool better =
        best < 0 || g.priority[i] < g.priority[best] || (g.priority[i] == g.priority[best] && y[i] <= y[best]);
    if (better) {
      best = i;
    }
  }
  return (branchOf: branchOf, bottom: bottom, lo: lo, hi: hi, main: best < 0 ? -1 : branchOf[best]);
}

/// §4.3's branch columns of [g], read literally on the rows [y] in units of [u] with cont [cont]: plain
/// lists, a library sort, every candidate column scanned. Returns every node's column.
List<int> naiveBranchColumns(LayoutInput g, List<int> y, int u, List<int> cont) {
  final List<List<int>> lp = layoutParents(g);
  final (:List<int> branchOf, :List<int> bottom, :List<int> lo, :List<int> hi, :int main) = naiveBranches(
    g,
    y,
    u,
    cont,
  );
  final int count = bottom.length;
  final List<int> from = [
    for (final int b in bottom)
      if (lp[b].isNotEmpty) branchOf[lp[b].first] else main,
  ];
  // A branch merges elsewhere if a card of it is a non-first parent of a card outside the branch it
  // forks from (the lab's `elsewhere`).
  final List<bool> elsewhere = List.filled(count, false);
  for (var i = 0; i < g.n; i++) {
    for (final int p in lp[i].skip(1)) {
      if (branchOf[i] != from[branchOf[p]]) {
        elsewhere[branchOf[p]] = true;
      }
    }
  }
  int depth(int b) => b == main ? 0 : (from[b] == main || elsewhere[b] ? 1 : depth(from[b]) + 1);
  final List<int> order = List.generate(count, (b) => b)
    ..sort((a, b) {
      for (final (int x, int z) in [
        (depth(a), depth(b)),
        (hi[a], hi[b]),
        (hi[a] - lo[a], hi[b] - lo[b]),
        (y[bottom[a]], y[bottom[b]]),
        (g.priority[bottom[a]], g.priority[bottom[b]]),
        (bottom[a], bottom[b]),
      ]) {
        if (x != z) {
          return x.compareTo(z);
        }
      }
      return 0;
    });
  final List<int> columnOf = List.filled(count, -1);
  final columns = <int, List<int>>{};
  bool free(int column, int b) =>
      (columns[column] ?? const <int>[]).every((o) => lo[o] >= hi[b] + u || lo[b] >= hi[o] + u);
  for (final b in order) {
    var column = 0;
    if (b != main) {
      final int dock = from[b] == main || elsewhere[b] ? 0 : columnOf[from[b]];
      column = -1;
      for (var d = 0; column < 0; d++) {
        if (dock - d >= 1 && free(dock - d, b)) {
          column = dock - d;
        } else if (d > 0 && free(dock + d, b)) {
          column = dock + d;
        }
      }
    }
    columnOf[b] = column;
    (columns[column] ??= []).add(b);
  }
  return [for (var i = 0; i < g.n; i++) columnOf[branchOf[i]]];
}

/// The failures of §7.3's branch invariants (I2's second half and I4, restated 2026-11-10) for the
/// ungrouped grid [r] of [g]: the main branch alone in column 0, one column per branch, and two
/// branches of one column keeping one pitch between their reserved rows; empty when they hold.
List<String> branchFailures(LayoutInput g, GraphGridView r) {
  final int u = r.unit;
  final List<int> cont = naiveContinuations(g, layoutParents(g));
  final (:List<int> branchOf, :List<int> bottom, :List<int> lo, :List<int> hi, :int main) = naiveBranches(
    g,
    r.nodeRows,
    u,
    cont,
  );
  final fails = <String>[];
  final List<int> columnOf = List.filled(bottom.length, -1);
  for (var i = 0; i < g.n; i++) {
    final int b = branchOf[i];
    if (columnOf[b] >= 0 && columnOf[b] != r.nodeCols[i] && fails.length < 8) {
      fails.add('branch $b has columns ${columnOf[b]} and ${r.nodeCols[i]}');
    }
    columnOf[b] = r.nodeCols[i];
  }
  for (var b = 0; b < bottom.length && fails.length < 8; b++) {
    if ((columnOf[b] == 0) != (b == main)) {
      fails.add('branch $b ${b == main ? 'is the main branch but not in' : 'shares'} column 0');
    }
    for (var o = 0; o < b; o++) {
      if (columnOf[o] == columnOf[b] && !(lo[o] >= hi[b] + u || lo[b] >= hi[o] + u)) {
        fails.add('branches $o and $b of column ${columnOf[b]} keep no pitch');
      }
    }
  }
  return fails;
}
