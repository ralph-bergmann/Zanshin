// SPDX-License-Identifier: MIT

// Story 4.13's invariant checks (docs/graph-layout.md §4.8, §7.3 as amended): a naive, literal
// reading of the run rule and the state, every grouped edge, I1–I7, y′ ≤ y, and the rows as the
// least solution of the constraints — rebuilt from scratch with library sorts and a plain
// fixed-point iteration, independent of the engine's level sweep — plus the seeded stack-shaped
// DAGs they run on.

import 'dart:math';
import 'dart:typed_data';

import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import 'invariants.dart' show clampedT, layoutParents;
import 'support/spec_json.dart';

/// A run of §4.8 read literally: its members, oldest first, and whether it is collapsed.
typedef NaiveRun = ({List<int> members, bool collapsed});

/// §4.8 steps 1–3, literally: the candidates, the maximal link chains of at least two members
/// (ordered by newest member), and each run's state under [s]'s request.
List<NaiveRun> naiveRuns(LayoutInput g, StackInput s) {
  final int n = g.n;
  final List<List<int>> lp = layoutParents(g);
  final List<List<int>> children = List.generate(n, (_) => <int>[]);
  for (var i = 0; i < n; i++) {
    for (final int p in lp[i]) {
      children[p].add(i);
    }
  }
  bool cand(int i) =>
      g.isRoot[i] == 0 &&
      s.workingCopy[i] == workingCopyNone &&
      s.hasRef[i] == 0 &&
      s.parentCount[i] == 1 &&
      g.parStart[i + 1] - g.parStart[i] == 1 &&
      g.parKind[g.parStart[i]] == parentDirect &&
      children[i].length == 1;
  int? link(int i) {
    if (!cand(i)) {
      return null;
    }
    final int c = children[i].single;
    return cand(c) && (s.immutable[c] != 0) == (s.immutable[i] != 0) ? c : null;
  }

  final Set<int> linkedTo = {
    for (var i = 0; i < n; i++)
      if (link(i) != null) link(i)!,
  };
  final chains = <List<int>>[];
  for (var i = 0; i < n; i++) {
    if (link(i) == null || linkedTo.contains(i)) {
      continue;
    }
    final members = [i];
    for (int? next = link(i); next != null; next = link(next)) {
      members.add(next);
    }
    chains.add(members);
  }
  chains.sort((a, b) => a.last - b.last);

  // A: this workspace's @ and what it reaches through mutable layout parents.
  final inA = <int>{};
  final List<int> work = [
    for (var i = 0; i < n; i++)
      if (s.workingCopy[i] == workingCopyThis) i,
  ];
  inA.addAll(work);
  while (work.isNotEmpty) {
    for (final int p in lp[work.removeLast()]) {
      if (s.immutable[p] == 0 && inA.add(p)) {
        work.add(p);
      }
    }
  }
  final Set<int> ex = s.expandedNodes.toSet();
  final Set<int> co = s.collapsedNodes.toSet();
  final Set<int> ko = s.keepOpenNodes.toSet();
  return [
    for (final List<int> m in chains)
      (
        members: m,
        collapsed: !(m.any(ko.contains) || ex.contains(m.first) || (!co.contains(m.first) && inA.contains(m.last))),
      ),
  ];
}

/// The failures of §4.8 and the amended §7.3 for the grouped grid [r] laid out from [g] with [s],
/// against the ungrouped grid [off] of the same mode and order; empty when every check holds.
List<String> stackInvariantFailures(LayoutInput g, StackInput s, GraphGridView off, GraphGridView r) {
  final fails = <String>[];
  void check(bool ok, String message) {
    if (!ok && fails.length < 8) {
      fails.add(message);
    }
  }

  final int n = g.n;
  final int u = r.unit;
  final List<NaiveRun> runs = naiveRuns(g, s);
  final List<NaiveRun> stacks = [
    for (final NaiveRun run in runs)
      if (run.collapsed) run,
  ];
  final int total = n + stacks.length;
  check(r.hasStacks, 'no stack arrays');
  check(r.mode == off.mode && r.order == off.order && r.unit == off.unit, 'header echo');
  check(
    r.nodeCount == n && r.stackCount == stacks.length && r.runCount == runs.length && r.nodeRows.length == total,
    'counts: n ${r.nodeCount}/$n, S ${r.stackCount}/${stacks.length}, R ${r.runCount}/${runs.length}',
  );
  if (fails.isNotEmpty) {
    return fails;
  }
  check(r.lanes == off.lanes, 'I7 lanes ${r.lanes} ≠ ${off.lanes}');

  // The runs, their state and stack nodes, and img.
  final List<int> image = List.generate(n, (i) => i);
  final List<int> runOf = List.filled(n, -1);
  final stackOf = <int, NaiveRun>{};
  for (var k = 0; k < runs.length; k++) {
    final NaiveRun run = runs[k];
    final List<int> got = r.runMembers!.sublist(r.runStarts![k], r.runStarts![k + 1]);
    check(_same(got, run.members), 'run $k members $got ≠ ${run.members}');
    check(
      r.runStates![k] == (run.collapsed ? GraphGridView.runCollapsed : GraphGridView.runExpanded),
      'run $k state',
    );
    final int node = run.collapsed ? n + stacks.indexOf(run) : -1;
    check(r.runNodes![k] == node, 'run $k node ${r.runNodes![k]} ≠ $node');
    for (final int m in run.members) {
      runOf[m] = k;
      if (run.collapsed) {
        image[m] = node;
      }
    }
    if (run.collapsed) {
      stackOf[node] = run;
    }
  }
  for (var i = 0; i < n; i++) {
    check(r.nodeRuns![i] == runOf[i], 'node run $i');
  }
  if (fails.isNotEmpty) {
    return fails;
  }

  // Y, hidden members, I7, y′ ≤ Y.
  final Int32List y = r.nodeRows;
  final List<int> big = List.filled(total, 0);
  final List<bool> visible = List.filled(total, true);
  for (var i = 0; i < n; i++) {
    final hidden = image[i] != i;
    check(r.isHidden(i) == hidden, 'isHidden($i)');
    if (hidden) {
      visible[i] = false;
      check(y[i] == -1 && r.nodeLanes[i] == -1 && r.nodeCols[i] == -1, 'hidden $i has a position');
      continue;
    }
    big[i] = off.nodeRows[i];
    check(r.nodeLanes[i] == off.nodeLanes[i] && r.nodeCols[i] == off.nodeCols[i], 'I7 node $i');
    check(y[i] <= off.nodeRows[i], 'y′ ≤ y at $i: ${y[i]} > ${off.nodeRows[i]}');
  }
  final splitStack = <int>{};
  for (final MapEntry(key: int sNode, value: NaiveRun run) in stackOf.entries) {
    final int mk = run.members.last;
    big[sNode] = off.nodeRows[mk];
    check(r.nodeLanes[sNode] == off.nodeLanes[mk] && r.nodeCols[sNode] == off.nodeCols[mk], 'I7 stack $sNode');
    check(y[sNode] <= off.nodeRows[mk], 'y′ ≤ y(m_k) at stack $sNode');
    if (off.nodeCols[run.members.first] != off.nodeCols[mk]) {
      splitStack.add(sNode);
    }
  }
  check(r.rows <= off.rows, 'rows ${r.rows} > ${off.rows}');
  final Iterable<int> live = Iterable<int>.generate(total).where((v) => visible[v]);
  check(r.rows == (n == 0 ? 0 : live.map((v) => y[v]).reduce(max) + u), 'rows = max y′ + U');

  // G′'s edges in §3's order, with their pos.
  final List<List<int>> lp = layoutParents(g);
  final edges = <(int, int, int, int)>[]; // (parent, child, kind, pos)
  for (var v = 0; v < n; v++) {
    if (!visible[v]) {
      continue;
    }
    var pos = 0;
    for (int k = g.parStart[v]; k < g.parStart[v + 1]; k++) {
      if (g.parIdx[k] >= 0) {
        edges.add((image[g.parIdx[k]], v, g.parKind[k], pos++));
      }
    }
  }
  for (var k = 0; k < stacks.length; k++) {
    edges.add((image[lp[stacks[k].members.first].single], n + k, parentDirect, 0));
  }
  check(r.edgeCount == edges.length, 'edge count ${r.edgeCount} ≠ ${edges.length}');
  if (fails.isNotEmpty) {
    return fails;
  }
  final List<int> fp = List.filled(total, -1);
  for (var e = 0; e < edges.length; e++) {
    final (int p, int c, int kind, int pos) = edges[e];
    check(r.edgeFroms[e] == p && r.edgeTos[e] == c && r.edgeKinds[e] == kind, 'edge $e is not $p→$c ($kind)');
    if (pos == 0) {
      fp[c] = p;
    }
  }

  // The rows: the least solution of (E), (F) and (C), by a plain fixed-point iteration.
  final constraints = <(int, int, int)>[]; // (source, target, delta)
  for (final (int p, int c, _, _) in edges) {
    constraints.add((p, c, u));
  }
  final List<int>? walk = r.mode == LayoutMode.free ? _freeWalk(g, image, stackOf, n, total) : null;
  if (walk != null) {
    final List<int> x = _walkX(g);
    int xOf(int v) => v < n ? x[v] : x[stackOf[v]!.members.last];
    for (var k = 1; k < walk.length; k++) {
      constraints.add((walk[k - 1], walk[k], xOf(walk[k]) - xOf(walk[k - 1])));
    }
  }
  final byCol = <int, List<int>>{};
  for (final v in live) {
    (byCol[r.nodeCols[v]] ??= []).add(v);
  }
  for (final List<int> col in byCol.values) {
    col.sort((a, b) => big[a].compareTo(big[b]));
    var segment = 0;
    for (var j = 1; j < col.length; j++) {
      final int h = col[j];
      if (fp[h] == col[j - 1]) {
        continue;
      }
      final bool fromCard = fp[h] < 0 || splitStack.contains(h);
      final int t = fromCard ? h : fp[h];
      constraints.add((col[j - 1], t, fromCard ? 2 * u : u));
      for (var k = segment; k < j; k++) {
        for (final (int p, int c, _, int pos) in edges) {
          if (p == col[k] && pos >= 1) {
            constraints.add((c, t, fromCard ? u : 0));
          }
        }
      }
      segment = j;
    }
  }
  for (final (int src, int dst, int delta) in constraints) {
    check(big[dst] >= big[src] + delta, 'Y violates $src→$dst +$delta');
  }
  constraints.sort((a, b) => big[a.$1].compareTo(big[b.$1]));
  final List<int> least = List.filled(total, 0);
  var rounds = 0;
  for (var changed = true; changed && rounds <= total + 1; rounds++) {
    changed = false;
    for (final (int src, int dst, int delta) in constraints) {
      if (least[dst] < least[src] + delta) {
        least[dst] = least[src] + delta;
        changed = true;
      }
    }
  }
  check(rounds <= total + 1, 'the constraints have no least solution');
  for (final v in live) {
    check(y[v] == least[v], "y′($v) ${y[v]} is not the least solution's ${least[v]}");
  }

  // I1–I4 on G′, `blocked` literally.
  final byLane = <int, List<int>>{};
  for (final v in live) {
    (byLane[r.nodeLanes[v]] ??= []).add(v);
  }
  final straight = <(int, int)>{};
  for (var e = 0; e < edges.length; e++) {
    final (int p, int c, _, int pos) = edges[e];
    check(y[c] >= y[p] + u, 'I1 $p→$c');
    final same = r.nodeLanes[p] == r.nodeLanes[c];
    final int route = r.edgeRoutes[e];
    final blocked = r.edgeBlocked[e] != 0;
    final bool naiveBlocked = !same && byLane[r.nodeLanes[p]]!.any((o) => y[p] < y[o] && y[o] <= y[c]);
    check(blocked == naiveBlocked, 'blocked $p→$c');
    check((route == routeStraight) == same, 'I3 straight ⇔ same lane $p→$c');
    check(!same || pos == 0, 'I3 straight ⇒ first parent $p→$c');
    check(route != routeMerge || (pos >= 1 && !blocked), 'I3 merge $p→$c');
    check(route != routeBranchOff || !same, 'I3 branch-off $p→$c');
    if (same) {
      straight.add((p, c));
    }
  }
  for (final List<int> lane in byLane.values) {
    lane.sort((a, b) => y[a].compareTo(y[b]));
    for (var k = 1; k < lane.length; k++) {
      final int need = straight.contains((lane[k - 1], lane[k])) ? u : 2 * u;
      check(y[lane[k]] - y[lane[k - 1]] >= need, 'I2 ${lane[k - 1]}, ${lane[k]}');
    }
  }
  for (final v in live) {
    check(r.nodeCols[v] == r.nodeLanes[v], 'I4 col = lane at $v');
  }

  // I5 / I6 over W′.
  if (walk == null) {
    check(r.bucketCount == 0, 'I5 compact: no buckets');
  } else {
    final List<int> tt = clampedT(g, lp);
    int tOf(int v) => v < n ? tt[v] : tt[stackOf[v]!.members.last];
    final days = <int>[];
    final lo = <int>[];
    final hi = <int>[];
    for (final int v in walk) {
      if (v < n && g.isRoot[v] != 0) {
        continue;
      }
      final int key = dayKey(tOf(v), g.utcOffsetMin);
      if (days.isEmpty || days.last != key) {
        days.add(key);
        lo.add(y[v]);
        hi.add(y[v]);
      }
      lo.last = min(lo.last, y[v]);
      hi.last = max(hi.last, y[v]);
    }
    check(_same(r.bucketValues, days), 'I5 bucket days');
    check(_same(r.bucketStarts, lo) && _same(r.bucketEnds, hi), 'I5 bucket ranges');
    for (var k = 1; k < walk.length; k++) {
      check(y[walk[k]] >= y[walk[k - 1]], 'I6 at ${walk[k]}');
    }
  }

  // With nothing collapsed the grouped layout is the ungrouped one.
  if (stacks.isEmpty) {
    check(
      _same(r.nodeRows, off.nodeRows) &&
          _same(r.edgeRoutes, off.edgeRoutes) &&
          _same(r.edgeBlocked, off.edgeBlocked) &&
          _same(r.bucketStarts, off.bucketStarts) &&
          _same(r.bucketEnds, off.bucketEnds) &&
          r.rows == off.rows,
      'all expanded ≠ ungrouped',
    );
  }
  return fails;
}

/// How many runs of [g] (any state) are split in [off]: col(m_1) ≠ col(m_k).
int splitRuns(LayoutInput g, StackInput s, GraphGridView off) => naiveRuns(
  g,
  s,
).where((run) => off.nodeCols[run.members.first] != off.nodeCols[run.members.last]).length;

/// W′ (§4.8 step 6): §4.2's walk by (T ascending, i descending), hidden nodes dropped and each
/// newest member replaced by its stack node.
List<int> _freeWalk(LayoutInput g, List<int> image, Map<int, NaiveRun> stackOf, int n, int total) {
  final List<int> tt = clampedT(g, layoutParents(g));
  final List<int> order = List.generate(n, (i) => i)..sort((a, b) => tt[a] != tt[b] ? tt[a].compareTo(tt[b]) : b - a);
  return [
    for (final int w in order)
      if (image[w] == w) w else if (stackOf[image[w]]!.members.last == w) image[w],
  ];
}

/// X along the ungrouped walk: the gaps summed (§4.8 step 6, (F)).
List<int> _walkX(LayoutInput g) {
  final int n = g.n;
  final List<int> tt = clampedT(g, layoutParents(g));
  final List<int> order = List.generate(n, (i) => i)..sort((a, b) => tt[a] != tt[b] ? tt[a].compareTo(tt[b]) : b - a);
  final List<int> x = List.filled(n, 0);
  for (var k = 1; k < n; k++) {
    x[order[k]] = x[order[k - 1]] + freeGap(tt[order[k]] - tt[order[k - 1]]);
  }
  return x;
}

bool _same(List<int> a, List<int> b) =>
    a.length == b.length && Iterable<int>.generate(a.length).every((k) => a[k] == b[k]);

/// A random stack-shaped graph (the last node the root): mostly chains, broken by refs, working
/// copies, the immutable boundary, merges, forks and Indirect child edges, with Indirect,
/// multi-Indirect and Missing parent gaps, non-monotonic timestamps now and then, and, with
/// [split] true, §4.8 step 4's split-run shape rewired in (m_1 continues its parent beside the
/// parent's merge reservation).
({LayoutInput input, SpecStackFacts facts}) randomStackGraph(Random rnd, int n, {bool split = false}) {
  final double pFork = [0.0, 0.08, 0.2][rnd.nextInt(3)];
  final double pMerge = [0.0, 0.06, 0.15][rnd.nextInt(3)];
  final double pGap = [0.0, 0.08, 0.2][rnd.nextInt(3)];
  final double pRef = [0.0, 0.06, 0.15][rnd.nextInt(3)];
  final int cut = n == 0 ? 0 : n ~/ 3 + rnd.nextInt(n - n ~/ 3 + 1);
  final parents = <List<Object?>>[for (var i = 0; i < n; i++) <Object?>[]];
  final counts = <int, int>{};
  for (int i = n - 2; i >= 0; i--) {
    final int fp = rnd.nextDouble() < pFork ? i + 1 + rnd.nextInt(min(6, n - 1 - i)) : i + 1;
    final ps = <Object?>[];
    final double gap = rnd.nextDouble();
    if (gap < pGap / 3) {
      ps.add(null);
    } else if (gap < 2 * pGap / 3 && fp + 1 < n) {
      ps.addAll([Ind(fp), Ind(fp + 1 + rnd.nextInt(n - 1 - fp))]);
    } else if (gap < pGap) {
      ps.add(Ind(fp));
    } else {
      ps.add(fp);
    }
    counts[i] = 1;
    if (rnd.nextDouble() < pMerge) {
      final int q = i + 1 + rnd.nextInt(n - 1 - i);
      if (!ps.any((p) => p == q || (p is Ind && p.idx == q))) {
        ps.add(rnd.nextInt(5) == 0 ? null : (rnd.nextInt(5) == 0 ? Ind(q) : q));
        counts[i] = 2;
      }
    }
    parents[i] = ps;
  }
  final List<int> priority = [for (var i = 0; i < n; i++) rnd.nextInt(3)];
  // The split shape's m2 and m1 (j + 3, j + 4), which must stay plain candidates.
  final members = <int>{};
  if (split && n >= 6) {
    // c0 = j ← m2 = j + 3 ← m1 = j + 4 ← p = j + 5; x = j + 2 ← p; c = j + 1 merges x and p.
    final int j = rnd.nextInt(n - 5);
    members.addAll([j + 3, j + 4]);
    parents[j] = [j + 3];
    parents[j + 1] = [j + 2, j + 5];
    parents[j + 2] = [j + 5];
    parents[j + 3] = [j + 4];
    parents[j + 4] = [j + 5];
    counts.addAll({j: 1, j + 1: 2, j + 2: 1, j + 3: 1, j + 4: 1});
    priority[j + 4] = 0;
    priority[j + 2] = 2;
    // Nothing else may hang off m1 or m2: such edges move to c0, without repeating a target.
    for (var i = 0; i < j; i++) {
      final seen = <int>{};
      final rewired = <Object?>[];
      for (final Object? p in parents[i]) {
        if (p == null) {
          rewired.add(null);
          continue;
        }
        final int target = _idx(p) == j + 3 || _idx(p) == j + 4 ? j : _idx(p);
        if (seen.add(target)) {
          rewired.add(p is Ind ? Ind(target) : target);
        }
      }
      parents[i] = rewired;
    }
  }
  final Set<int> refs = {
    for (var i = 0; i < n - 1; i++)
      if (rnd.nextDouble() < pRef && !members.contains(i)) i,
  };
  final Set<int> others = {
    for (var i = 0; i < n - 1; i++)
      if (rnd.nextInt(40) == 0 && !members.contains(i)) i,
  };
  final int? at = n > 1 && rnd.nextInt(3) > 0 ? rnd.nextInt(min(n - 1, 6)) : null;
  final int? self = members.contains(at) ? null : at;
  var t = 1790000000000;
  final List<int?> ts = List.filled(n, null);
  for (int i = n - 2; i >= 0; i--) {
    t += const [0, 1000, 60000, 420000, 3600000, 72000000, 86400000][rnd.nextInt(7)];
    ts[i] = rnd.nextInt(12) == 0 ? t - 2 * 86400000 : t;
  }
  return specStackGraph(
    parents,
    counts: counts,
    refs: refs,
    self: self,
    others: others,
    immutable: {for (var i = cut; i < n; i++) i},
    priority: priority,
    ts: ts,
    offset: const [0, 120, -300, 330, 1440][rnd.nextInt(5)],
  );
}

int _idx(Object p) => p is Ind ? p.idx : p as int;
