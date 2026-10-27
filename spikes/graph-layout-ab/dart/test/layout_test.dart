// Unit tests for the spike's Dart layout. Run: `dart run test/layout_test.dart`.
//
// The hand-traced graphs below list nodes children-first (jj log order); every expectation was
// derived by hand from docs/graph-layout.md §4 before the code ran.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:graph_layout/graph_layout.dart';

import 'harness.dart';

/// An `indirect` parent in [graph]'s parent lists (a plain int is `direct`, null is `missing`).
final class Ind {
  const Ind(this.idx);

  final int idx;
}

LayoutInput graph(
  List<List<Object?>> parents, {
  List<int>? priority,
  List<int?>? ts,
  Set<int> roots = const {},
  int now = 0,
  int offset = 0,
}) {
  final nodes = [
    for (var i = 0; i < parents.length; i++)
      {
        'id': 'n$i',
        'ts_ms': ts?[i],
        'is_root': roots.contains(i),
        'priority': priority?[i] ?? 0,
        'parents': [
          for (final p in parents[i])
            switch (p) {
              null => {'idx': null, 'kind': 'missing'},
              Ind(:final idx) => {'idx': idx, 'kind': 'indirect'},
              final int idx => {'idx': idx, 'kind': 'direct'},
              _ => throw ArgumentError(p),
            },
        ],
      },
  ];
  return parseInput(utf8.encode(jsonEncode({'now_ms': now, 'utc_offset_min': offset, 'nodes': nodes})));
}

LayoutResult run(LayoutInput g, Mode mode, [LaneOrder order = LaneOrder.greedy]) => computeLayout(g, mode, order);

/// Edges as (from, to, route, blocked) tuples for compact comparison.
List<List<Object>> edges(LayoutResult r) => [
  for (var e = 0; e < r.edgeFrom.length; e++)
    [r.edgeFrom[e], r.edgeTo[e], routeNames[r.edgeRoute[e]], r.edgeBlocked[e] != 0],
];

const int now = 1000000000000; // 2001-09-09T01:46:40Z
const int minute = 60000;
const int hour = 3600000;
const int day = 86400000;

void main() {
  arithmetic();
  layering();
  lanePacking();
  laneOrder();
  compactOrder();
  outputAndValidation();
  randomized();
  stacks();
  jointColumns();
  finish();
}

// ---- Story 4.14: joint columns (docs/graph-layout.md §4.3 / §4.7, amended 2026-10-27) -----------

/// The joint packing read literally: both models' §4.3 intervals, a node fits a lane iff no
/// interval there except the excluded owner's overlaps it in either model; packed once in each
/// model's visit order, the fewer lanes kept, `compact`'s on a tie. Also returns both counts.
(List<int>, int, int) naiveJointLanes(LayoutInput g) {
  final ls = [GraphLayout(g, Mode.compact)..layering(), GraphLayout(g, Mode.free)..layering()];
  final n = g.n, fp = ls[0].fp, prio = g.priority;
  final cont = List.filled(n, -1);
  for (var i = 0; i < n; i++) {
    final f = fp[i];
    if (f >= 0 && (cont[f] < 0 || prio[i] < prio[cont[f]])) cont[f] = i;
  }
  List<int> iv(int k, int i) {
    final l = ls[k], y = l.y, u = l.unit;
    final ey = [
      if (cont[i] >= 0) y[cont[i]],
      for (var s = l.chStart[i]; s < l.chStart[i + 1]; s++)
        if (l.chPos[s] >= 1) y[l.chIdx[s]],
    ];
    final end = ey.isEmpty ? y[i] : max(y[i], ey.reduce(max) - u);
    return [fp[i] >= 0 ? y[fp[i]] + u : y[i], end + 2 * u];
  }

  final ivs = [for (var k = 0; k < 2; k++) List.generate(n, (i) => iv(k, i))];
  (List<int>, int) pack(int v) {
    final y = ls[v].y;
    final order = List.generate(n, (i) => i)
      ..sort((a, b) => y[a] != y[b] ? y[a].compareTo(y[b]) : (prio[a] != prio[b] ? prio[a] - prio[b] : a - b));
    final lanes = <List<int>>[]; // owners per lane
    bool overlap(int k, int x, int i) => ivs[k][x][0] < ivs[k][i][1] && ivs[k][i][0] < ivs[k][x][1];
    bool fits(int lane, int i, int except) =>
        lane >= lanes.length || !lanes[lane].any((x) => x != except && (overlap(0, x, i) || overlap(1, x, i)));
    final lane = List.filled(n, -1);
    for (final i in order) {
      var chosen = -1;
      if (fp[i] >= 0 && cont[fp[i]] == i && fits(lane[fp[i]], i, fp[i])) chosen = lane[fp[i]];
      if (chosen < 0) {
        chosen = 0;
        while (!fits(chosen, i, -1)) {
          chosen++;
        }
      }
      while (lanes.length <= chosen) {
        lanes.add([]);
      }
      lanes[chosen].add(i);
      lane[i] = chosen;
    }
    return (lane, lanes.length);
  }

  final (lc, cc) = pack(0);
  final (lf, cf) = pack(1);
  return (cc <= cf ? lc : lf, cc, cf);
}

/// A joint layout through routing: the state the `compact` order starts from.
GraphLayout jointGreedy(LayoutInput g, Mode mode) => GraphLayout(g, mode, joint: true)
  ..layering()
  ..packLanes()
  ..markBlocked()
  ..route();

/// The joint model cost (SPEC §4.7, amended): 16·cost_compact + cost_free, each from scratch.
int naiveJointCost(LayoutInput g, List<int> lanes) =>
    16 * naiveCompactCost(jointGreedy(g, Mode.compact), lanes) + naiveCompactCost(jointGreedy(g, Mode.free), lanes);

void jointColumns() {
  LayoutResult joint(LayoutInput g, Mode mode, [LaneOrder order = LaneOrder.greedy, StackInput? stacks]) =>
      computeLayout(g, mode, order, joint: true, stacks: stacks);

  // Trunk R-T1-T2-T3-T4 (lane 0); X branches off T1, Y off T3. In compact rows X [2, 4) and
  // Y [4, 6) are disjoint, so per-mode compact stacks them in lane 1. X is committed six days
  // after Y: in free units X [36, 154) and Y [76, 108) overlap, so joint columns split them.
  //   0:X→T1 1:T4→T3 2:Y→T3 3:T3→T2 4:T2→T1 5:T1→R 6:R
  const t0 = now - 30 * day;
  final xy = graph(
    [
      [5],
      [3],
      [3],
      [4],
      [5],
      [6],
      [],
    ],
    priority: [2, 0, 2, 0, 0, 0, 0],
    ts: [t0 + 10 * day, t0 + 4 * day, t0 + 3 * day + hour, t0 + 3 * day, t0 + 2 * day, t0 + day, t0],
  );

  test('joint: two chains disjoint in compact but overlapping in free get different lanes in both modes', () {
    expectEq(run(xy, Mode.compact).lane, [1, 0, 1, 0, 0, 0, 0], 'per-mode compact');
    expectEq(run(xy, Mode.free).lane, [2, 0, 1, 0, 0, 0, 0], 'per-mode free');
    // Both visit orders need 3 lanes; the tie keeps compact's order, which places X first.
    final (lanes, compactCount, freeCount) = naiveJointLanes(xy);
    expectEq([compactCount, freeCount], [3, 3]);
    expectEq(lanes, [1, 0, 2, 0, 0, 0, 0]);
    for (final mode in [Mode.compact, Mode.free]) {
      final r = joint(xy, mode);
      expectEq(r.lane, [1, 0, 2, 0, 0, 0, 0], '$mode lanes');
      expectEq(
        [r.lanes, r.col],
        [
          3,
          [1, 0, 2, 0, 0, 0, 0],
        ],
        '$mode',
      );
    }
    expectEq(joint(xy, Mode.compact).row, run(xy, Mode.compact).row, 'compact rows');
    expectEq(joint(xy, Mode.free).row, run(xy, Mode.free).row, 'free rows');
  });

  test('joint: the free visit order needs fewer lanes here, so the joint packing is its', () {
    // Found by a random search; the expected values are the literal two-model scan's.
    final g = graph(
      [
        [1],
        [6],
        [5],
        [8],
        [5, 6],
        [8, 6],
        [8],
        [8],
        [],
      ],
      priority: [0, 0, 1, 1, 0, 0, 0, 0, 1],
      ts: [
        1000000000000,
        1000342000000,
        1000082800000,
        999910000000,
        999902800000,
        999816400000,
        999816400000,
        999730000000,
        999730000000,
      ],
    );
    final (lanes, compactCount, freeCount) = naiveJointLanes(g);
    expectEq([compactCount, freeCount], [5, 4]);
    expectEq(lanes, [3, 2, 1, 3, 0, 0, 2, 1, 0]);
    for (final mode in [Mode.compact, Mode.free]) {
      expectEq(joint(g, mode).lane, lanes, '$mode');
    }
  });

  test('joint: one chain packs as per-mode greedy (single-model reduction)', () {
    final chain = graph(
      [
        [1],
        [2],
        [3],
        [],
      ],
      ts: [now, now - day, now - 2 * day, null],
      roots: {3},
    );
    for (final mode in [Mode.compact, Mode.free]) {
      expectEq(encodeOutput(joint(chain, mode)), encodeOutput(run(chain, mode)), '$mode');
    }
  });

  test('joint: the packing equals the literal two-model scan; the visit-order choice takes the fewer lanes', () {
    final rnd = Random(41);
    var freeFewer = 0, compactFewer = 0, tie = 0;
    for (var t = 0; t < 300; t++) {
      final g = randomGraph(rnd, 1 + rnd.nextInt(70), branchy: t.isOdd);
      final (want, cc, cf) = naiveJointLanes(g);
      if (cf < cc) {
        freeFewer++;
      } else if (cc < cf) {
        compactFewer++;
      } else {
        tie++;
      }
      for (final mode in [Mode.compact, Mode.free]) {
        final l = GraphLayout(g, mode, joint: true)
          ..layering()
          ..packLanes()
          ..markBlocked();
        expectEq(l.lane, want, 'lanes, case $t $mode');
        expectEq(l.blocked, naiveBlocked(l), 'blocked, case $t $mode');
      }
    }
    check(freeFewer > 0 && compactFewer > 0 && tie > 0, 'visit-order cases: $freeFewer / $compactFewer / $tie');
  });

  test('joint: I8 and I1–I6 on random graphs in both modes and orders, with and without stacks', () {
    final rnd = Random(43);
    for (var t = 0; t < 150; t++) {
      final g = randomGraph(rnd, rnd.nextInt(110), branchy: t.isOdd);
      for (final order in [LaneOrder.greedy, LaneOrder.compact]) {
        final c = joint(g, Mode.compact, order), f = joint(g, Mode.free, order);
        final what = 'case $t $order';
        checkInvariants(g, c, '$what compact');
        checkInvariants(g, f, '$what free');
        expectEq([c.lanes, c.lane, c.col], [f.lanes, f.lane, f.col], '$what: I8');
        expectEq(encodeOutput(joint(g, Mode.free, order)), encodeOutput(f), '$what: deterministic');
      }
    }
  });

  test('joint: compact order cost exact, never above joint greedy; the search is mode-independent', () {
    final rnd = Random(47);
    var swapped = 0;
    for (var t = 0; t < 150; t++) {
      final g = randomGraph(rnd, 1 + rnd.nextInt(90), branchy: t.isOdd);
      final what = 'case $t';
      final lc = jointGreedy(g, Mode.compact), lf = jointGreedy(g, Mode.free);
      final start = naiveJointCost(g, lc.lane);
      final co = JointCompactOrder(lc);
      expectEq(co.totalCost(), start, '$what: start cost');
      expectEq(JointCompactOrder(lc, rounds: 0).run(), lc.lane, '$what: no rounds = greedy');
      final lanes = co.run();
      final beforeDrop = Int32List.fromList([for (var i = 0; i < g.n; i++) co.colOf[co.seg[i]]]);
      final searched = naiveJointCost(g, beforeDrop);
      expectEq(co.totalCost(), searched, '$what: searched cost');
      check(searched <= start, '$what: cost $searched > greedy $start');
      check(naiveJointCost(g, lanes) <= searched, '$what: dropping empty columns raised the cost');
      if (searched < start) swapped++;
      checkDisjointReservations(lc, lanes, '$what compact');
      checkDisjointReservations(lf, lanes, '$what free');
      expectEq(JointCompactOrder(lf).run(), lanes, '$what: same search from the free layout');
      final c = joint(g, Mode.compact, LaneOrder.compact), greedy = joint(g, Mode.compact);
      expectEq(c.lane, lanes, '$what: computeLayout lanes');
      expectEq(c.edgeRoute, greedy.edgeRoute, '$what: routes');
      for (var i = 0; i < g.n; i++) {
        check((c.lane[i] == 0) == (greedy.lane[i] == 0), '$what: lane 0 node $i');
      }
      check(c.lanes <= greedy.lanes, '$what: more lanes than greedy');
      expectEq(c.lane.toSet().length, c.lanes, '$what: an empty column');
    }
    check(swapped > 40, 'too few improving searches: $swapped');
  });

  test('joint: with one model the joint search is the per-mode search, work units included', () {
    final rnd = Random(53);
    for (var t = 0; t < 120; t++) {
      final g = randomGraph(rnd, 1 + rnd.nextInt(120), branchy: t.isOdd);
      for (final mode in [Mode.compact, Mode.free]) {
        final l = GraphLayout(g, mode)
          ..layering()
          ..packLanes()
          ..markBlocked()
          ..route();
        for (final budget in [0, 40, 300, 3000, compactBudget]) {
          expectEq(
            JointCompactOrder(l, single: true, budget: budget).run(),
            CompactOrder(l, budget: budget).run(),
            'case $t $mode budget $budget',
          );
        }
      }
    }
  });

  test('joint: skipping unchanged windows ends where the unskipped search ends', () {
    final rnd = Random(59);
    for (var t = 0; t < 150; t++) {
      final g = randomGraph(rnd, 1 + rnd.nextInt(130), branchy: t.isOdd);
      List<int> search({required bool skip}) =>
          JointCompactOrder(jointGreedy(g, Mode.compact), rounds: 1 << 20, budget: 1 << 60, skip: skip).run();
      expectEq(search(skip: true), search(skip: false), 'case $t');
    }
  });

  test('joint: stacks keep the joint columns in both modes (I7 + I8)', () {
    final rnd = Random(61);
    for (var t = 0; t < 60; t++) {
      final base = randomGraph(rnd, rnd.nextInt(70), branchy: t % 3 == 0);
      final n = base.n;
      final g = stackGraph(
        [
          for (var i = 0; i < n; i++)
            [
              for (var k = base.parStart[i]; k < base.parStart[i + 1]; k++)
                switch (base.parKind[k]) {
                  kindMissing => null,
                  kindIndirect => Ind(base.parIdx[k]),
                  _ => base.parIdx[k],
                },
            ],
        ],
        ts: [for (var i = 0; i < n; i++) base.hasTs[i] != 0 ? base.ts[i] : null],
        priority: base.priority.toList(),
      );
      final all = List.generate(n, (i) => i);
      final some = [
        for (var i = 0; i < n; i++)
          if (rnd.nextBool()) i,
      ];
      for (final order in [LaneOrder.greedy, LaneOrder.compact]) {
        final off = joint(g, Mode.compact, order);
        for (final req in [
          stackRequest(g, collapsed: all),
          stackRequest(g, keepOpen: all),
          stackRequest(g, collapsed: some),
        ]) {
          final c = joint(g, Mode.compact, order, req), f = joint(g, Mode.free, order, req);
          expectEq([c.lanes, c.lane, c.col], [f.lanes, f.lane, f.col], 'case $t $order: I8');
          check(c.lanes == off.lanes, 'case $t $order: lanes');
          for (var i = 0; i < n; i++) {
            if (c.lane[i] >= 0) check(c.lane[i] == off.lane[i], 'case $t $order: I7 node $i');
          }
        }
      }
    }
  });
}

void arithmetic() {
  test('floorDiv rounds toward −∞', () {
    expectEq([floorDiv(7, 5), floorDiv(-1, 5), floorDiv(-5, 5), floorDiv(-6, 5), floorDiv(0, 5)], [1, -1, -1, -2, 0]);
  });

  test('free gap curve matches the SPEC §4.2 table', () {
    final gaps = [0, 59999, minute, hour, day, 7 * day, 365 * day, 100 * 365 * day].map(freeGap).toList();
    expectEq(gaps, [0, 0, 2, 11, 20, 26, 38, 48]);
  });

  test('time bucket key: ladder boundaries, future, 12h cut-off', () {
    expectEq(timeBucketKey(now - 10 * minute, now, 0), now - 10 * minute, 'exactly 10m');
    expectEq(timeBucketKey(now - 10 * minute - 1, now, 0), now - 20 * minute, '10m + 1ms');
    expectEq(timeBucketKey(now + 5000, now, 0), now - 10 * minute, 'future');
    expectEq(timeBucketKey(now - 50 * minute, now, 0), now - 60 * minute, '50m');
    expectEq(timeBucketKey(now - 720 * minute, now, 0), now - 720 * minute, 'exactly 12h');
    final ts = now - 720 * minute - 1;
    expectEq(timeBucketKey(ts, now, 0), floorDiv(ts, day) * day, '12h + 1ms is a day');
  });

  test('time bucket key: calendar day with offsets and negative timestamps', () {
    expectEq(timeBucketKey(-1, now, 0), -day);
    expectEq(timeBucketKey(0, now, -300), -day + 5 * hour, 'UTC−5: 1970-01-01T00:00Z is Dec 31 local');
    expectEq(timeBucketKey(0, now, 120), -2 * hour, 'UTC+2');
    expectEq(timeBucketKey(day - 2 * hour, now, 120), day - 2 * hour, 'UTC+2 local midnight itself');
  });
}

void layering() {
  test('compact: longest path (chain + merge)', () {
    // 0: merge of 1 and 3; 1 → 2 → 3.
    final r = run(
      graph([
        [1, 3],
        [2],
        [3],
        [],
      ]),
      Mode.compact,
    );
    expectEq(r.row, [3, 2, 1, 0]);
    expectEq([r.rows, r.unit], [4, 1]);
  });

  test('compact: missing parents are ignored, indirect ones count', () {
    final r = run(
      graph([
        [null, const Ind(1)],
        [null],
        [],
      ]),
      Mode.compact,
    );
    expectEq(r.row, [1, 0, 0]);
    expectEq(edges(r).length, 1);
    expectEq(kindNames[r.edgeKind[0]], 'indirect');
  });

  test('time: topological clamp puts an older child into its parent\'s bucket (D1)', () {
    // 0 (2 days old) is a child of 1 (5 min old), whose parent is the root 2.
    final r = run(
      graph(
        [
          [1],
          [2],
          [],
        ],
        ts: [now - 2 * day, now - 5 * minute, null],
        roots: {2},
        now: now,
      ),
      Mode.time,
    );
    expectEq(r.row, [2, 1, 0]);
    expectEq(r.rows, 3);
    expectEq(
      [r.bucketKind.toList(), r.bucketValue.toList(), r.bucketStart.toList(), r.bucketEnd.toList()],
      [
        [bucketRoot, bucketAge],
        [0, 10],
        [0, 1],
        [0, 2],
      ],
    );
  });

  test('time: day and age buckets in key order, with a UTC offset', () {
    // Chain 0 → 1 → 2 → 3: 1 min, 50 min, 13 h and 3 days old.
    final ts = [now - minute, now - 50 * minute, now - 13 * hour, now - 3 * day];
    final utc = run(
      graph(
        [
          [1],
          [2],
          [3],
          [],
        ],
        ts: ts,
        now: now,
      ),
      Mode.time,
    );
    expectEq(utc.row, [3, 2, 1, 0]);
    expectEq(utc.bucketKind, [bucketDay, bucketDay, bucketAge, bucketAge]);
    expectEq(utc.bucketValue, [999734400000, 999907200000, 60, 10]);
    expectEq(utc.bucketStart, [0, 1, 2, 3]);
    final plus2 = run(
      graph(
        [
          [1],
          [2],
          [3],
          [],
        ],
        ts: ts,
        now: now,
        offset: 120,
      ),
      Mode.time,
    );
    expectEq(plus2.bucketValue, [999727200000, 999900000000, 60, 10]);
  });

  test('time: rows inside a bucket are longest paths from the bucket start', () {
    // 3 is a day old (its own bucket); 0, 1, 2 share the 10m bucket, which starts at row 1.
    final ts = [now - minute, now - minute, now - 2 * minute, now - day];
    final r = run(
      graph(
        [
          [2],
          [2, 3],
          [3],
          [],
        ],
        ts: ts,
        now: now,
      ),
      Mode.time,
    );
    expectEq(r.row, [2, 2, 1, 0]);
    expectEq(r.bucketStart, [0, 1]);
    expectEq(r.bucketEnd, [0, 2]);
  });

  test('free: gap vs one pitch per commit', () {
    const t0 = 1700000000000;
    expectEq(
      run(
        graph(
          [
            [1],
            [],
          ],
          ts: [t0 + hour, t0],
        ),
        Mode.free,
      ).row,
      [16, 0],
      '1 h: the pitch wins',
    );
    expectEq(
      run(
        graph(
          [
            [1],
            [],
          ],
          ts: [t0 + day, t0],
        ),
        Mode.free,
      ).row,
      [20, 0],
      '1 day: the gap wins',
    );
    final r = run(graph([[], []], ts: [t0 + minute, t0]), Mode.free);
    expectEq(r.row, [2, 0], 'unrelated nodes: time axis only');
    expectEq([r.rows, r.unit], [18, 16]);
  });

  test('free: clamp for a child older than its parent; the root takes tmin', () {
    const t0 = 1700000000000;
    // Visit order: 2 (T = t0), then 1 and 0 (both T = t0 + 1 day, index descending).
    final r = run(
      graph(
        [
          [1],
          [2],
          [],
        ],
        ts: [t0, t0 + day, null],
        roots: {2},
      ),
      Mode.free,
    );
    expectEq(r.row, [36, 20, 0]);
    expectEq(r.rows, 52);
    // Day buckets (amended 2026-10-01): 0 counts by its clamped T (1's day), the root by none.
    expectEq(r.bucketValue, [floorDiv(t0 + day, day) * day]);
    expectEq(
      [r.bucketStart, r.bucketEnd],
      [
        [20],
        [36],
      ],
    );
  });

  test('free: day buckets across a local midnight share one row; roots are in none', () {
    const midnight = 1000072800000; // 2001-09-10T00:00 at UTC+2
    final r = run(
      graph([[], [], []], ts: [midnight + 10000, midnight - 20000, null], roots: {2}, offset: 120),
      Mode.free,
    );
    expectEq(r.row, [0, 0, 0]);
    expectEq(r.bucketKind, [bucketDay, bucketDay]);
    expectEq(r.bucketValue, [midnight - day, midnight]);
    expectEq(
      [r.bucketStart, r.bucketEnd],
      [
        [0, 0],
        [0, 0],
      ],
    );
    final rootOnly = run(graph([[]], ts: [null], roots: {0}), Mode.free);
    expectEq(rootOnly.bucketKind.length, 0, 'no non-root node, no bucket');
    expectEq(run(graph([[], []], ts: [midnight, midnight - day]), Mode.compact).bucketKind.length, 0, 'compact');
  });

  test('free: a non-root node with a null ts counts by its clamped T', () {
    const t1 = 1700000000000;
    final r = run(
      graph(
        [
          [1],
          [2],
          [],
        ],
        ts: [null, t1, null],
        roots: {2},
      ),
      Mode.free,
    );
    expectEq(r.row, [32, 16, 0]);
    expectEq(r.bucketValue, [floorDiv(t1, day) * day]);
    expectEq(
      [r.bucketStart, r.bucketEnd],
      [
        [16],
        [32],
      ],
    );
  });

  test('free: day key at UTC offsets −300, 0, 330 and ±1440', () {
    for (final (offset, want) in [(-300, -day + 5 * hour), (0, 0), (330, -330 * minute), (1440, 0), (-1440, 0)]) {
      final r = run(
        graph(
          [
            [1],
            [],
          ],
          ts: [0, null],
          roots: {1},
          offset: offset,
        ),
        Mode.free,
      );
      expectEq(r.bucketValue, [want], 'offset $offset');
      expectEq(dayKey(0, offset), want, 'dayKey offset $offset');
    }
  });

  test('free: tmin is the least non-null ts, including a root\'s (literal reading)', () {
    const t0 = 1700000000000;
    final r = run(
      graph(
        [
          [1],
          [],
        ],
        ts: [t0, t0 - 365 * day],
        roots: {1},
      ),
      Mode.free,
    );
    expectEq(r.row, [38, 0]);
  });
}

void lanePacking() {
  test('chain: one lane, all straight', () {
    final r = run(
      graph([
        [1],
        [2],
        [],
      ]),
      Mode.compact,
    );
    expectEq(r.lane, [0, 0, 0]);
    expectEq(edges(r), [
      [1, 0, 'straight', false],
      [2, 1, 'straight', false],
    ]);
  });

  test('branch: the continuation child is the least (priority, index); the other branches off, blocked', () {
    final r = run(
      graph(
        [
          [2],
          [2],
          [],
        ],
        priority: [1, 0, 0],
      ),
      Mode.compact,
    );
    expectEq(r.lane, [1, 0, 0]);
    expectEq(edges(r), [
      [2, 0, 'branch_off', true],
      [2, 1, 'straight', false],
    ]);
  });

  test('merge: merge child extends the parent reservation; unblocked merge; blocked branch-off', () {
    final r = run(
      graph([
        [1, 2],
        [3],
        [3],
        [],
      ]),
      Mode.compact,
    );
    expectEq(r.row, [2, 1, 1, 0]);
    expectEq(r.lane, [0, 0, 1, 0]);
    expectEq(edges(r), [
      [1, 0, 'straight', false],
      [2, 0, 'merge', false],
      [3, 1, 'straight', false],
      [3, 2, 'branch_off', true],
    ]);
  });

  test('one-row buffer: an adjacent interval does not fit, a buffered one does', () {
    // 0:C→3:B, 1:F→3:B, 2:E→5:A, 3:B→5:A, 4:D→6:R, 5:A→6:R, 6:R.
    // D takes lane 1 as [1,3); E would start at row 2 → lane 2; F starts at row 3 → lane 1.
    final r = run(
      graph(
        [
          [3],
          [3],
          [5],
          [5],
          [6],
          [6],
          [],
        ],
        priority: [0, 1, 1, 0, 1, 0, 0],
      ),
      Mode.compact,
    );
    expectEq(r.row, [3, 3, 2, 2, 1, 1, 0]);
    expectEq(r.lane, [0, 1, 2, 0, 1, 0, 0]);
    expectEq(r.lanes, 3);
    expectEq(edges(r), [
      [3, 0, 'straight', false],
      [3, 1, 'branch_off', true],
      [5, 2, 'branch_off', true],
      [5, 3, 'straight', false],
      [6, 4, 'branch_off', true],
      [6, 5, 'straight', false],
    ]);
  });

  test('continuation refused: the grandparent\'s merge reservation (tie in the top-2 b′)', () {
    // 0:I→2:F, 1:M→[3:X, 4:G], 2:F→4:G, 3:X→4:G, 4:G. G reserves lane 0 up to M's row;
    // F continues G (G's own interval excepted), I cannot continue F (G's interval is not F's).
    final r = run(
      graph(
        [
          [2],
          [3, 4],
          [4],
          [4],
          [],
        ],
        priority: [0, 1, 0, 1, 0],
      ),
      Mode.compact,
    );
    expectEq(r.row, [2, 2, 1, 1, 0]);
    expectEq(r.lane, [2, 1, 0, 1, 0]);
    expectEq(edges(r), [
      [2, 0, 'branch_off', false],
      [3, 1, 'straight', false],
      [4, 1, 'branch_off', true], // blocked merge → branch_off (D9)
      [4, 2, 'straight', false],
      [4, 3, 'branch_off', true],
    ]);
  });

  test('lane packing equals the design-literal interval scan (random graphs, all modes)', () {
    final rnd = Random(7);
    for (var t = 0; t < 150; t++) {
      final g = randomGraph(rnd, 1 + rnd.nextInt(60));
      for (final mode in Mode.values) {
        final l = GraphLayout(g, mode)
          ..layering()
          ..packLanes()
          ..markBlocked();
        expectEq(l.lane, naiveLanes(l), 'lanes, case $t $mode');
        expectEq(l.blocked, naiveBlocked(l), 'blocked, case $t $mode');
      }
    }
  });
}

void laneOrder() {
  // 0:N→2:X, 1:M→[3:Y, 4:A], 2:X→5:R, 3:Y→5:R, 4:A→5:R, 5:R. The merge A→M (lane 0 → 2) crosses
  // X→N's vertical in lane 1; putting lane 2 in column 1 removes the crossing (cost 420 → 18).
  final crossing = graph(
    [
      [2],
      [3, 4],
      [5],
      [5],
      [5],
      [],
    ],
    priority: [1, 2, 1, 2, 0, 0],
  );

  test('optimized: sifting removes the hand-traced crossing', () {
    final greedy = run(crossing, Mode.compact);
    expectEq(greedy.lane, [1, 2, 1, 2, 0, 0]);
    expectEq(greedy.col, greedy.lane);
    expectEq(edges(greedy), [
      [2, 0, 'straight', false],
      [3, 1, 'straight', false],
      [4, 1, 'merge', false],
      [5, 2, 'branch_off', true],
      [5, 3, 'branch_off', true],
      [5, 4, 'straight', false],
    ]);
    final optimized = run(crossing, Mode.compact, LaneOrder.optimized);
    expectEq(optimized.lane, greedy.lane);
    expectEq(optimized.col, [2, 1, 2, 1, 0, 0]);
  });

  test('optimized: swap deltas of the hand trace', () {
    final l = GraphLayout(crossing, Mode.compact)
      ..layering()
      ..packLanes()
      ..markBlocked()
      ..route();
    final s = l.buildSifter();
    expectEq([s.h(0), s.h(1), s.h(2)], [3, 1, 2]);
    expectEq(s.m(1, 18), 1, 'X→N passes dn(M)');
    expectEq(s.swapDelta(1), -402);
    expectEq(naiveCost(l, s), 420);
    s.swapColumns(1);
    expectEq(naiveCost(l, s), 18);
    expectEq(s.swapDelta(1), 402);
  });

  test('optimized: two lanes or fewer stay the identity', () {
    final r = run(
      graph(
        [
          [2],
          [2],
          [],
        ],
        priority: [1, 0, 0],
      ),
      Mode.compact,
      LaneOrder.optimized,
    );
    expectEq(r.col, r.lane);
  });

  test('optimized: incremental deltas equal full cost differences (random graphs and permutations)', () {
    final rnd = Random(11);
    var checked = 0;
    for (var t = 0; t < 120; t++) {
      final g = randomGraph(rnd, 5 + rnd.nextInt(50));
      final mode = Mode.values[t % 3];
      final l = GraphLayout(g, mode)
        ..layering()
        ..packLanes()
        ..markBlocked()
        ..route();
      final s = l.buildSifter();
      final lanes = s.laneCount;
      if (lanes < 3) continue;
      for (var k = 0; k < 3 * lanes; k++) {
        final a = 1 + rnd.nextInt(lanes - 1), b = 1 + rnd.nextInt(lanes - 1);
        s.moveColumn(s.pos[a], s.pos[b]); // a random permutation with π(0) = 0
      }
      for (var a = 1; a < lanes; a++) {
        final c = s.pos[a];
        final to = 1 + rnd.nextInt(lanes - 1);
        final before = naiveCost(l, s);
        var d = 0;
        if (to > c) {
          for (var k = c; k < to; k++) {
            d += s.swapDelta(k);
            s.swapColumns(k);
          }
        } else {
          for (var k = c - 1; k >= to; k--) {
            d += s.swapDelta(k);
            s.swapColumns(k);
          }
        }
        expectEq(d, naiveCost(l, s) - before, 'case $t lane $a: $c → $to');
        checked++;
      }
    }
    check(checked > 500, 'too few delta checks: $checked');
  });

  test('optimized: deterministic, a permutation fixing lane 0, never worse than greedy', () {
    final rnd = Random(13);
    for (var t = 0; t < 60; t++) {
      final g = randomGraph(rnd, 20 + rnd.nextInt(150), branchy: true);
      final mode = Mode.values[t % 3];
      final a = run(g, mode, LaneOrder.optimized), b = run(g, mode, LaneOrder.optimized);
      expectEq(encodeOutput(a), encodeOutput(b), 'case $t');
      final l = GraphLayout(g, mode)
        ..layering()
        ..packLanes()
        ..markBlocked()
        ..route();
      final s = l.buildSifter();
      final greedyCost = naiveCost(l, s);
      final pi = List.filled(a.lanes, -1);
      for (var i = 0; i < g.n; i++) {
        pi[a.lane[i]] = a.col[i];
      }
      for (var lane = 0; lane < a.lanes; lane++) {
        s.pos[lane] = pi[lane];
        s.inv[pi[lane]] = lane;
      }
      expectEq(pi.toSet().length, a.lanes, 'π is a permutation');
      if (a.lanes > 0) expectEq(pi[0], 0, 'π(0) = 0');
      check(naiveCost(l, s) <= greedyCost, 'case $t: optimized cost ${naiveCost(l, s)} > greedy $greedyCost');
    }
  });
}

void compactOrder() {
  // Trunk R-A1-…-A8 (lane 0). L = L1…L4 branches off A1 and merges into A5; S = S1 branches off
  // A2 and merges into A4, nested inside L; X = X1 branches off A6 and merges into A8, after L.
  // Greedy: L and X share lane 1, S takes lane 2, and S's two horizontals cross L (X = 2).
  //   0:A8→[A7, X1] 1:X1→A6 2:A7→A6 3:A6→A5 4:A5→[A4, L4] 5:L4→L3 6:A4→[A3, S1] 7:L3→L2
  //   8:S1→A2 9:A3→A2 10:L2→L1 11:A2→A1 12:L1→A1 13:A1→R 14:R
  final nested = graph(
    [
      [2, 1],
      [3],
      [3],
      [4],
      [6, 5],
      [7],
      [9, 8],
      [10],
      [11],
      [11],
      [12],
      [13],
      [13],
      [14],
      [],
    ],
    priority: [0, 2, 0, 0, 0, 2, 0, 2, 2, 0, 2, 0, 2, 0, 0],
  );

  test('compact: a window swap puts S inside L; optimized swaps whole lanes and leaves a hole at X', () {
    final greedy = run(nested, Mode.compact);
    expectEq(greedy.row, [9, 8, 8, 7, 6, 5, 4, 4, 3, 3, 3, 2, 2, 1, 0]);
    expectEq(greedy.lane, [0, 1, 0, 0, 0, 1, 0, 1, 2, 0, 1, 0, 1, 0, 0]);
    expectEq(tickCrossings(greedy), 2);
    // optimized: π = [0, 2, 1] moves X too, although column 1 is empty beside it (rows 8–9).
    final optimized = run(nested, Mode.compact, LaneOrder.optimized);
    expectEq(optimized.col, [0, 2, 0, 0, 0, 2, 0, 2, 1, 0, 2, 0, 2, 0, 0]);
    expectEq(tickCrossings(optimized), 0);
    // compact: only the window of L and S is swapped; X stays in column 1.
    final compact = run(nested, Mode.compact, LaneOrder.compact);
    expectEq(compact.lane, [0, 1, 0, 0, 0, 2, 0, 2, 1, 0, 2, 0, 2, 0, 0]);
    expectEq(compact.col, compact.lane);
    expectEq(tickCrossings(compact), 0);
    expectEq(edges(compact), edges(greedy));
  });

  test('compact: the model cost of the hand trace (1096 → 368)', () {
    final l = GraphLayout(nested, Mode.compact)
      ..layering()
      ..packLanes()
      ..markBlocked()
      ..route();
    final co = CompactOrder(l);
    // Segments: trunk (col 0), L [2, 7) col 1, S [3, 5) col 2, X [8, 10) col 1. X = 2, Len = 8,
    // gravity 24·(1·5 + 2·2 + 1·2) = 264: 400·2 + 4·8 + 264 = 1096.
    expectEq(co.totalCost(), 1096);
    co.run();
    // L col 2, S col 1: X = 0, Len = 8, gravity 24·(2·5 + 1·2 + 1·2) = 336.
    expectEq(co.totalCost(), 368);
  });

  test('compact: exact model cost, never above greedy\'s; chains, routes and lane 0 kept (random graphs)', () {
    final rnd = Random(17);
    var swapped = 0;
    for (var t = 0; t < 150; t++) {
      final g = randomGraph(rnd, 1 + rnd.nextInt(90), branchy: t.isOdd);
      for (final mode in Mode.values) {
        final what = 'case $t $mode';
        final l = GraphLayout(g, mode)
          ..layering()
          ..packLanes()
          ..markBlocked()
          ..route();
        final start = naiveCompactCost(l, l.lane);
        final co = CompactOrder(l);
        expectEq(co.totalCost(), start, '$what: start cost');
        expectEq(CompactOrder(l, rounds: 0).run(), l.lane, '$what: no rounds = greedy');
        final lanes = co.run();
        final beforeDrop = Int32List.fromList([for (var i = 0; i < g.n; i++) co.colOf[co.seg[i]]]);
        final searched = naiveCompactCost(l, beforeDrop);
        expectEq(co.totalCost(), searched, '$what: searched cost');
        check(searched <= start, '$what: cost $searched > greedy $start');
        check(naiveCompactCost(l, lanes) <= searched, '$what: dropping empty columns raised the cost');
        if (searched < start) swapped++;
        checkDisjointReservations(l, lanes, what);

        final greedy = run(g, mode), compact = run(g, mode, LaneOrder.compact);
        expectEq(compact.lane, lanes, '$what: computeLayout lanes');
        expectEq(compact.col, compact.lane, '$what: col = lane');
        expectEq(compact.edgeRoute, greedy.edgeRoute, '$what: routes');
        for (var e = 0; e < compact.edgeFrom.length; e++) {
          if (e - l.lpStart[compact.edgeTo[e]] >= 1) {
            expectEq(compact.edgeBlocked[e], greedy.edgeBlocked[e], '$what: blocked merge $e');
          }
        }
        for (var i = 0; i < g.n; i++) {
          check((compact.lane[i] == 0) == (greedy.lane[i] == 0), '$what: lane 0 node $i');
        }
        check(compact.lanes <= greedy.lanes, '$what: more lanes than greedy');
        expectEq(compact.lane.toSet().length, compact.lanes, '$what: an empty column');
        expectEq(encodeOutput(run(g, mode, LaneOrder.compact)), encodeOutput(compact), '$what: deterministic');
      }
    }
    check(swapped > 50, 'too few improving searches: $swapped');
  });

  test('compact: skipping unchanged windows ends where the unskipped search ends (random graphs)', () {
    // Cases 188, 197 and 200 of this sequence failed while a window's span started at
    // 10·min a − 3U: a blocked merge's horizontal lies below its child segment's span.
    final rnd = Random(1);
    for (var t = 0; t < 201; t++) {
      final g = randomGraph(rnd, 1 + rnd.nextInt(150), branchy: t.isOdd);
      for (final mode in Mode.values) {
        List<int> search({required bool skip}) {
          final l = GraphLayout(g, mode)
            ..layering()
            ..packLanes()
            ..markBlocked()
            ..route();
          return CompactOrder(l, rounds: 1 << 20, budget: 1 << 60, skip: skip).run();
        }

        expectEq(search(skip: true), search(skip: false), 'case $t $mode');
      }
    }
  });
}

void outputAndValidation() {
  test('canonical output and digest', () {
    final r = run(
      graph(
        [
          [1, null],
          [],
        ],
        ts: [now - minute, null],
        roots: {1},
        now: now,
      ),
      Mode.time,
    );
    expectEq(
      encodeOutput(r),
      '{"mode":"time","order":"greedy","unit":1,"rows":2,"lanes":1,'
      '"nodes":[{"row":1,"lane":0,"col":0},{"row":0,"lane":0,"col":0}],'
      '"edges":[{"from":1,"to":0,"kind":"direct","route":"straight","blocked":false}],'
      '"buckets":[{"kind":"root","value":0,"start":0,"end":0},{"kind":"age","value":10,"start":1,"end":1}]}\n',
    );
    // nodes: 7·1 = 7, then 31·7 = 217; edge: 31·217 = 6727; buckets: 31·6727 + 0 = 208537,
    // then 31·208537 + 1 + 3 = 6464651.
    expectEq(digest(r), 6464651);
  });

  test('empty graph: rows = lanes = 0', () {
    for (final mode in Mode.values) {
      final r = run(graph([]), mode, LaneOrder.optimized);
      expectEq(
        encodeOutput(r),
        '{"mode":"${mode.name}","order":"optimized","unit":${mode == Mode.free ? 16 : 1},"rows":0,"lanes":0,'
        '"nodes":[],"edges":[],"buckets":[]}\n',
      );
    }
  });

  test('parser accepts any whitespace and key order', () {
    final g = parseInput(
      utf8.encode(
        ' { "nodes" : [ {"parents":[{"kind":"direct","idx":1}],"priority":2,"is_root":false,"ts_ms":5,"id":"a"},'
        '{"is_root":true,"ts_ms":null,"parents":[],"priority":0} ] ,"utc_offset_min":-60, "now_ms":9 }\n',
      ),
    );
    expectEq(
      [g.n, g.nowMs, g.utcOffsetMin, g.priority[0], g.parIdx[0], g.isRoot[1], g.hasTs[1]],
      [2, 9, -60, 2, 1, 1, 0],
    );
  });

  test('validation: V1–V4 and malformed input throw InputError', () {
    String doc(String node0, [String extra = '']) =>
        '{"now_ms":0,"utc_offset_min":0,"nodes":[$node0,{"id":"b","ts_ms":null,"is_root":true,"priority":0,"parents":[]}$extra]}';
    const ok = '{"id":"a","ts_ms":1,"is_root":false,"priority":0,"parents":[{"idx":1,"kind":"direct"}]}';
    parseInput(utf8.encode(doc(ok)));
    final bad = {
      'V1 null idx, direct': doc(ok.replaceFirst('"idx":1', '"idx":null')),
      'V1 idx on missing': doc(ok.replaceFirst('"direct"', '"missing"')),
      'V2 self': doc(ok.replaceFirst('"idx":1', '"idx":0')),
      'V2 out of range': doc(ok.replaceFirst('"idx":1', '"idx":2')),
      'V3 duplicate': doc(ok.replaceFirst('"kind":"direct"}', '"kind":"direct"},{"idx":1,"kind":"indirect"}')),
      'V4 priority 2^31': doc(ok.replaceFirst('"priority":0', '"priority":2147483648')),
      'V4 ts beyond 2^53': doc(ok.replaceFirst('"ts_ms":1', '"ts_ms":9007199254740993')),
      'negative priority': doc(ok.replaceFirst('"priority":0', '"priority":-1')),
      'float': doc(ok.replaceFirst('"ts_ms":1', '"ts_ms":1.5')),
      'unknown kind': doc(ok.replaceFirst('"direct"', '"weird"')),
      'missing ts_ms': doc(ok.replaceFirst('"ts_ms":1,', '')),
      'missing idx': doc(ok.replaceFirst('"idx":1,"kind":"direct"', '"kind":"missing"')),
      'not JSON': '{"now_ms":',
    };
    for (final MapEntry(:key, :value) in bad.entries) {
      expectThrows<InputError>(() => parseInput(utf8.encode(value)), key);
    }
    // 2^53 itself is allowed.
    parseInput(utf8.encode(doc(ok.replaceFirst('"ts_ms":1', '"ts_ms":9007199254740992'))));
  });

  // Stage-3 diff: `utc_offset_min · 60000` overflowed int64 (silent wrap) for offsets V4
  // allowed; SPEC §2 V4 now bounds it to ±1440.
  test('validation: utc_offset_min lies within ±1440', () {
    String doc(String off) => '{"now_ms":0,"utc_offset_min":$off,"nodes":[]}';
    for (final off in ['1440', '-1440', '0']) {
      parseInput(utf8.encode(doc(off)));
    }
    for (final off in ['1441', '-1441', '9007199254740992']) {
      expectThrows<InputError>(() => parseInput(utf8.encode(doc(off))), off);
    }
  });

  // Stage-3 diff: the fused UTF-8/JSON decoder skipped a leading BOM that serde_json rejects;
  // SPEC §2 now rejects it. `-0` is the integer 0 on both sides, `-0.0` a float.
  test('validation: a byte order mark is rejected; -0 is the integer 0, -0.0 is not', () {
    const json = '{"now_ms":-0,"utc_offset_min":0,"nodes":[{"ts_ms":-0,"is_root":false,"priority":-0,"parents":[]}]}';
    final g = parseInput(utf8.encode(json));
    expectEq([g.nowMs, g.ts[0], g.priority[0]], [0, 0, 0]);
    expectThrows<InputError>(() => parseInput(utf8.encode('﻿$json')), 'BOM');
    expectThrows<InputError>(() => parseInput(utf8.encode(json.replaceFirst('"ts_ms":-0', '"ts_ms":-0.0'))), '-0.0');
  });
}

void randomized() {
  test('invariants I1–I6 hold on random graphs (all modes and orders)', () {
    final rnd = Random(3);
    for (var t = 0; t < 120; t++) {
      final g = randomGraph(rnd, rnd.nextInt(120), branchy: t.isOdd);
      for (final mode in Mode.values) {
        for (final order in LaneOrder.values) {
          checkInvariants(g, run(g, mode, order), 'case $t $mode $order');
        }
      }
    }
  });
}

// ---- Story 4.13: commit stacks (docs/graph-layout.md §4.8) -------------------------------------

/// A hand-built input with stack facts (keys `n<i>`): [parents] as in [graph]; [counts] overrides a
/// node's `parent_count` (default: its parent entries), [refs] carry `has_ref`, [self] is `"this"`
/// working copy, [others] `"other"`, [immutable] the immutable nodes.
LayoutInput stackGraph(
  List<List<Object?>> parents, {
  Map<int, int> counts = const {},
  Set<int> refs = const {},
  int? self,
  Set<int> others = const {},
  Set<int> immutable = const {},
  List<int?>? ts,
  List<int>? priority,
}) {
  final n = parents.length;
  final nodes = [
    for (var i = 0; i < n; i++)
      {
        'id': 'n$i',
        'ts_ms': ts?[i],
        'is_root': i == n - 1,
        'priority': priority?[i] ?? 0,
        'parents': [
          for (final p in parents[i])
            switch (p) {
              null => {'idx': null, 'kind': 'missing'},
              Ind(:final idx) => {'idx': idx, 'kind': 'indirect'},
              final int idx => {'idx': idx, 'kind': 'direct'},
              _ => throw ArgumentError(p),
            },
        ],
        'key': 'n$i',
        'immutable': immutable.contains(i),
        'parent_count': counts[i] ?? parents[i].length,
        'has_ref': refs.contains(i),
        'working_copy': i == self ? 'this' : (others.contains(i) ? 'other' : null),
      },
  ];
  return parseInput(utf8.encode(jsonEncode({'now_ms': 0, 'utc_offset_min': 0, 'nodes': nodes})), stacks: true);
}

/// The stack request for [g] naming the node keys `n<i>` of each list.
StackInput stackRequest(
  LayoutInput g, {
  List<int> expanded = const [],
  List<int> collapsed = const [],
  List<int> keepOpen = const [],
  List<String> unknown = const [],
}) => parseStackRequest(
  utf8.encode(
    jsonEncode({
      'expanded': [for (final i in expanded) 'n$i', ...unknown],
      'collapsed': [for (final i in collapsed) 'n$i', ...unknown],
      'keep_open': [for (final i in keepOpen) 'n$i', ...unknown],
    }),
  ),
  g,
);

/// The runs of [r] as member lists, oldest first, with their state.
List<Object> runsOf(LayoutResult r) => [
  for (var k = 0; k + 1 < r.runStart!.length; k++)
    [
      [for (var j = r.runStart![k]; j < r.runStart![k + 1]; j++) r.runMembers![j]],
      runStateNames[r.runState![k]],
    ],
];

/// Edges as (from, to, kind) tuples.
List<List<Object>> kinds(LayoutResult r) => [
  for (var e = 0; e < r.edgeFrom.length; e++) [r.edgeFrom[e], r.edgeTo[e], kindNames[r.edgeKind[e]]],
];

void stacks() {
  LayoutResult grouped(LayoutInput g, [StackInput? s, Mode mode = Mode.compact, LaneOrder order = LaneOrder.greedy]) =>
      computeLayout(g, mode, order, stacks: s ?? stackRequest(g));

  test('stacks: (a) an Indirect parent edge — B a single card, C–D a stack whose parent edge is Direct', () {
    // E ← D ← C ← B ⇠ A: B's one edge is Indirect.
    final g = stackGraph([
      [1],
      [2],
      [3],
      [Ind(4)],
      [],
    ]);
    final r = grouped(g);
    expectEq(runsOf(r), [
      [
        [2, 1],
        'collapsed',
      ],
    ]);
    expectEq(kinds(r), [
      [5, 0, 'direct'],
      [4, 3, 'indirect'],
      [3, 5, 'direct'],
    ]);
    check(r.lane[3] >= 0 && r.lane[1] < 0 && r.lane[2] < 0, 'B visible, C and D hidden');
  });

  test('stacks: (b) one real parent, two Indirect edges; (c) one Missing edge — no member', () {
    for (final gap in [
      [Ind(4), Ind(5)],
      [null],
    ]) {
      final g = stackGraph(
        [
          [1],
          [2],
          [3],
          gap,
          [6],
          [6],
          [],
        ],
        counts: {3: 1},
      );
      expectEq(runsOf(grouped(g)), [
        [
          [2, 1],
          'collapsed',
        ],
      ], '$gap');
    }
  });

  test('stacks: (d) two runs meet at a gap — two stacks, the node above the gap a single card', () {
    // G ← F ← E ← D ⇠ C ← B ← A: C's one child edge is Indirect.
    final g = stackGraph([
      [1],
      [2],
      [3],
      [Ind(4)],
      [5],
      [6],
      [],
    ]);
    final r = grouped(g);
    expectEq(runsOf(r), [
      [
        [2, 1],
        'collapsed',
      ],
      [
        [5, 4],
        'collapsed',
      ],
    ]);
    check(r.lane[3] >= 0, 'D visible');
    // A 0, the lower stack 1, D 2, the upper stack 3, G 4.
    expectEq(r.row.toList(), [4, -1, -1, 2, -1, -1, 0, 3, 1], 'rows');
  });

  test('stacks: (e) a node with one Direct and one Indirect child edge is a fork, no member', () {
    // H ← Y2 ← Y ← X ← W ← R, and Z ⇠ X.
    final g = stackGraph([
      [2],
      [Ind(4)],
      [3],
      [4],
      [5],
      [6],
      [],
    ]);
    expectEq(runsOf(grouped(g)), [
      [
        [3, 2],
        'collapsed',
      ],
    ]);
  });

  test('stacks: (f) a collapsed stack keeps the Indirect kind of its newest member\'s child edge', () {
    final g = stackGraph([
      [Ind(1)],
      [2],
      [3],
      [],
    ]);
    expectEq(kinds(grouped(g)), [
      [4, 0, 'indirect'],
      [3, 4, 'direct'],
    ]);
  });

  test('stacks: a ref, another working copy, a merge and the immutable boundary break a run', () {
    // A chain of 8 above the root: 0 ← 1 ← … ← 7 ← 8 (root).
    final chain = [
      for (var i = 0; i < 8; i++) [i + 1],
      <Object?>[],
    ];
    expectEq(runsOf(grouped(stackGraph(chain))), [
      [
        [7, 6, 5, 4, 3, 2, 1],
        'collapsed',
      ],
    ], 'plain chain');
    expectEq(runsOf(grouped(stackGraph(chain, refs: {4}))), [
      [
        [3, 2, 1],
        'collapsed',
      ],
      [
        [7, 6, 5],
        'collapsed',
      ],
    ], 'a ref');
    expectEq(runsOf(grouped(stackGraph(chain, others: {4}))).length, 2, 'another workspace\'s working copy');
    expectEq(runsOf(grouped(stackGraph(chain, counts: {4: 2}))).length, 2, 'a merge with one layout parent');
    expectEq(runsOf(grouped(stackGraph(chain, immutable: {5, 6, 7, 8}))), [
      [
        [4, 3, 2, 1],
        'collapsed',
      ],
      [
        [7, 6, 5],
        'collapsed',
      ],
    ], 'the immutable boundary');
  });

  test(
    'stacks: state — @\'s mutable ancestors start expanded; CO, EX wins over CO, KO wins over all, unknown keys',
    () {
      // 0 (@) ← 1 ← 2 ← 3 ← 4 ← 5 (root, immutable).
      final chain = [
        for (var i = 0; i < 5; i++) [i + 1],
        <Object?>[],
      ];
      final g = stackGraph(chain, self: 0, immutable: {5});
      String state(StackInput s) => runsOf(grouped(g, s)).map((x) => (x as List)[1]).join(',');
      expectEq(state(stackRequest(g)), 'expanded', 'default');
      expectEq(state(stackRequest(g, collapsed: [4])), 'collapsed', 'CO on m_1');
      expectEq(state(stackRequest(g, expanded: [4], collapsed: [4])), 'expanded', 'EX wins');
      expectEq(state(stackRequest(g, collapsed: [4], keepOpen: [2])), 'expanded', 'KO on a middle member');
      expectEq(state(stackRequest(g, collapsed: [3])), 'expanded', 'CO on a non-oldest member: ignored');
      expectEq(state(stackRequest(g, collapsed: [4], unknown: ['zz'])), 'collapsed', 'an unknown key');
      final away = stackGraph(chain, immutable: {5});
      expectEq(state(stackRequest(away)), 'collapsed', 'without @ the default is collapsed');
    },
  );

  test('stacks: a split run — the stack takes m_k\'s column, every visible node keeps its own', () {
    // p = 5: children m1 = 4 (continuation, priority 0) and x = 2 (priority 2); the run m1 ← m2 = 3
    // with one child c0 = 0; c = 1 merges x and p, so p's reservation outlives m1.
    final g = stackGraph(
      [
        [3],
        [2, 5],
        [5],
        [4],
        [5],
        [],
      ],
      priority: [0, 0, 2, 0, 0, 0],
    );
    final off = run(g, Mode.compact);
    check(off.col[4] != off.col[3], 'the run is split');
    final r = grouped(g);
    expectEq(runsOf(r), [
      [
        [4, 3],
        'collapsed',
      ],
    ]);
    expectEq([r.lane[6], r.col[6]], [off.lane[3], off.col[3]], 'the stack sits in m_k\'s column');
    for (final i in [0, 1, 2, 5]) {
      expectEq([r.lane[i], r.col[i]], [off.lane[i], off.col[i]], 'node $i keeps its column');
    }
    check(r.rows <= off.rows, 'rows never grow');
  });

  test('stacks: a missing or mistyped fact, a repeated key, two "this" and a bad request are InputErrors', () {
    Map<String, Object?> node(int i, [Map<String, Object?> extra = const {}]) => {
      'id': 'n$i',
      'ts_ms': null,
      'is_root': i == 1,
      'priority': 0,
      'parents': i == 0
          ? [
              {'idx': 1, 'kind': 'direct'},
            ]
          : <Object?>[],
      'key': 'n$i',
      'immutable': false,
      'parent_count': i == 0 ? 1 : 0,
      'has_ref': false,
      'working_copy': null,
      ...extra,
    };
    LayoutInput parse(List<Map<String, Object?>> nodes) =>
        parseInput(utf8.encode(jsonEncode({'now_ms': 0, 'utc_offset_min': 0, 'nodes': nodes})), stacks: true);
    final ok = parse([node(0), node(1)]);
    for (final field in ['key', 'immutable', 'parent_count', 'has_ref', 'working_copy']) {
      expectThrows<InputError>(() => parse([node(0)..remove(field), node(1)]), 'no $field');
    }
    expectThrows<InputError>(
      () => parse([
        node(0, {'key': 'n1'}),
        node(1),
      ]),
      'a repeated key',
    );
    expectThrows<InputError>(
      () => parse([
        node(0, {'has_ref': 'no'}),
        node(1),
      ]),
      'a mistyped fact',
    );
    expectThrows<InputError>(
      () => parse([
        node(0, {'parent_count': -1}),
        node(1),
      ]),
      'a negative parent count',
    );
    expectThrows<InputError>(
      () => parse([
        node(0, {'working_copy': 'this'}),
        node(1, {'working_copy': 'this'}),
      ]),
      'two "this"',
    );
    expectThrows<InputError>(() => parseStackRequest(utf8.encode('{"expanded":[]}'), ok), 'lists missing');
    expectThrows<InputError>(
      () => parseStackRequest(utf8.encode('{"expanded":[1],"collapsed":[],"keep_open":[]}'), ok),
      'a non-string key',
    );
    final s = parseStackRequest(utf8.encode('{"expanded":["n1","zz"],"collapsed":[],"keep_open":[]}'), ok);
    expectEq(s.expandedNodes.toList(), [1], 'an unknown key is dropped');
  });

  test('stacks: random graphs — all expanded equals off, all collapsed only compacts (I7, y′ ≤ y)', () {
    final rnd = Random(413);
    for (var t = 0; t < 150; t++) {
      final base = randomGraph(rnd, rnd.nextInt(80), branchy: t % 3 == 0);
      final n = base.n;
      final parents = [
        for (var i = 0; i < n; i++)
          [
            for (var k = base.parStart[i]; k < base.parStart[i + 1]; k++)
              switch (base.parKind[k]) {
                kindMissing => null,
                kindIndirect => Ind(base.parIdx[k]),
                _ => base.parIdx[k],
              },
          ],
      ];
      final g = stackGraph(
        parents,
        refs: {
          for (var i = 0; i < n; i++)
            if (rnd.nextInt(12) == 0) i,
        },
        self: n > 1 && rnd.nextBool() ? rnd.nextInt(n - 1) : null,
        immutable: {for (var i = rnd.nextInt(n + 1); i < n; i++) i},
        ts: [for (var i = 0; i < n; i++) base.hasTs[i] != 0 ? base.ts[i] : null],
        priority: base.priority.toList(),
      );
      final all = List.generate(n, (i) => i);
      for (final mode in [Mode.compact, Mode.free]) {
        for (final order in [LaneOrder.greedy, LaneOrder.compact]) {
          final what = 'case $t $mode $order';
          final off = computeLayout(g, mode, order);
          final open = computeLayout(g, mode, order, stacks: stackRequest(g, keepOpen: all));
          check(encodeOutput(open).startsWith(encodeOutput(off).replaceFirst(RegExp(r'\]\}\n$'), ']')), '$what: open');
          final shut = computeLayout(g, mode, order, stacks: stackRequest(g, collapsed: all));
          check(shut.rows <= off.rows && shut.lanes == off.lanes, '$what: rows / lanes');
          for (var i = 0; i < n; i++) {
            if (shut.lane[i] < 0) continue;
            check(shut.lane[i] == off.lane[i] && shut.col[i] == off.col[i], '$what: I7 node $i');
            check(shut.row[i] <= off.row[i], '$what: y′ ≤ y at $i');
          }
          for (var k = 0; k < shut.stackCount; k++) {
            final run = shut.runNode!.indexOf(n + k);
            final newest = shut.runMembers![shut.runStart![run + 1] - 1];
            check(shut.col[n + k] == off.col[newest] && shut.row[n + k] <= off.row[newest], '$what: stack $k');
          }
          for (var e = 0; e < shut.edgeFrom.length; e++) {
            final p = shut.edgeFrom[e], c = shut.edgeTo[e];
            check(shut.row[c] >= shut.row[p] + shut.unit, '$what: I1 $p→$c');
          }
        }
      }
    }
  });
}

// ---------------------------------------------------------------------------------------------
// Reference implementations and generators (tests only).

/// A random children-first DAG: mostly chains, some merges, indirect and missing parents,
/// ~10 % non-monotonic timestamps, a null-ts root at the end.
LayoutInput randomGraph(Random rnd, int n, {bool branchy = false}) {
  final parents = <List<Object?>>[];
  final ts = <int?>[];
  var t = now + 5 * minute;
  for (var i = 0; i < n; i++) {
    t -= i < n ~/ 3 ? rnd.nextInt(30 * minute) : rnd.nextInt(2 * day);
    ts.add(rnd.nextInt(10) == 0 ? t + rnd.nextInt(4 * day) - 2 * day : t);
    final ps = <Object?>[];
    final used = <int>{};
    final count = i == n - 1 ? 0 : [0, 1, 1, 1, 1, 1, 2, 2, 3][rnd.nextInt(9)];
    for (var k = 0; k < count; k++) {
      final span = branchy ? 40 : (rnd.nextInt(8) == 0 ? n : 6);
      final idx = i + 1 + rnd.nextInt(min(span, n - i - 1));
      if (!used.add(idx)) continue;
      ps.add(rnd.nextInt(10) == 0 ? Ind(idx) : idx);
    }
    if (rnd.nextInt(15) == 0) ps.insert(rnd.nextInt(ps.length + 1), null);
    parents.add(ps);
  }
  if (n > 0) ts[n - 1] = null;
  return graph(
    parents,
    priority: [for (var i = 0; i < n; i++) rnd.nextInt(3)],
    ts: ts,
    roots: {if (n > 0) n - 1},
    now: now,
    offset: rnd.nextInt(1201) - 600,
  );
}

/// The design's interval test, literally: scan every interval of the lane (half-open [a, b)).
List<int> naiveLanes(GraphLayout l) {
  final n = l.n, u = l.unit, y = l.y, fp = l.fp, prio = l.input.priority;
  final cont = List.filled(n, -1);
  for (var i = 0; i < n; i++) {
    final f = fp[i];
    if (f >= 0 && (cont[f] < 0 || prio[i] < prio[cont[f]])) cont[f] = i;
  }
  final order = List.generate(n, (i) => i)
    ..sort((a, b) => y[a] != y[b] ? y[a].compareTo(y[b]) : (prio[a] != prio[b] ? prio[a] - prio[b] : a - b));
  final lanes = <List<List<int>>>[]; // [a, b, owner]
  bool fits(int lane, int a, int b, int except) =>
      lane >= lanes.length || !lanes[lane].any((iv) => iv[0] < b && a < iv[1] && iv[2] != except);
  final lane = List.filled(n, -1);
  for (final i in order) {
    final ey = <int>[
      if (cont[i] >= 0) y[cont[i]],
      for (var s = l.chStart[i]; s < l.chStart[i + 1]; s++)
        if (l.chPos[s] >= 1) y[l.chIdx[s]],
    ];
    final end = ey.isEmpty ? y[i] : max(y[i], ey.reduce(max) - u);
    final a = fp[i] >= 0 ? y[fp[i]] + u : y[i];
    final b = end + 2 * u;
    var chosen = -1;
    if (fp[i] >= 0 && cont[fp[i]] == i && fits(lane[fp[i]], a, b, fp[i])) chosen = lane[fp[i]];
    if (chosen < 0) {
      chosen = 0;
      while (!fits(chosen, a, b, -1)) {
        chosen++;
      }
    }
    while (lanes.length <= chosen) {
      lanes.add([]);
    }
    lanes[chosen].add([a, b, i]);
    lane[i] = chosen;
  }
  return lane;
}

/// The design's blocked formula, O(E·n), with D4.
List<int> naiveBlocked(GraphLayout l) => [
  for (var e = 0; e < l.edgeCount; e++)
    () {
      final p = l.edgeParent[e], i = l.edgeChild[e];
      if (l.lane[p] == l.lane[i]) return 0;
      for (var o = 0; o < l.n; o++) {
        if (l.lane[o] == l.lane[p] && l.y[o] > l.y[p] && l.y[o] <= l.y[i]) return 1;
      }
      return 0;
    }(),
];

/// cost(π) = 400·X + 4·Len + Disp from scratch, with the geometry re-derived from SPEC §4.6's table.
int naiveCost(GraphLayout l, LaneSifter s) {
  final u = l.unit;
  final verticals = <List<int>>[]; // [lane, lo, hi]
  final horizontals = <List<int>>[]; // [laneA, laneB, level]
  for (var e = 0; e < l.edgeCount; e++) {
    final p = l.edgeParent[e], i = l.edgeChild[e];
    final lp = l.lane[p], li = l.lane[i];
    final botP = 10 * l.y[p], botI = 10 * l.y[i];
    final top = botP + 5 * u, up = botP + 7 * u, dn = botI - 2 * u;
    switch (l.routes[e]) {
      case routeStraight:
        verticals.add([lp, top, botI]);
      case routeMerge:
        verticals
          ..add([lp, top, dn])
          ..add([li, dn, botI]);
        horizontals.add([lp, li, dn]);
      default:
        verticals.add([li, up, botI]);
        horizontals.add([lp, li, up]);
    }
  }
  var x = 0, len = 0, disp = 0;
  for (final [a, b, level] in horizontals) {
    final lo = min(s.pos[a], s.pos[b]), hi = max(s.pos[a], s.pos[b]);
    len += hi - lo;
    for (final [lane, vlo, vhi] in verticals) {
      if (lo < s.pos[lane] && s.pos[lane] < hi && vlo < level && level < vhi) x++;
    }
  }
  for (var lane = 0; lane < s.laneCount; lane++) {
    disp += (s.pos[lane] - lane).abs();
  }
  return 400 * x + 4 * len + disp;
}

/// §4.6 tick-model crossings of a result by column, every horizontal × vertical pair.
int tickCrossings(LayoutResult r) {
  final u = r.unit;
  final verticals = <List<int>>[]; // [col, lo, hi]
  final horizontals = <List<int>>[]; // [colA, colB, level]
  for (var e = 0; e < r.edgeFrom.length; e++) {
    final p = r.edgeFrom[e], i = r.edgeTo[e];
    final botP = 10 * r.row[p], botI = 10 * r.row[i];
    final top = botP + 5 * u, up = botP + 7 * u, dn = botI - 2 * u;
    switch (r.edgeRoute[e]) {
      case routeStraight:
        verticals.add([r.col[p], top, botI]);
      case routeMerge:
        verticals
          ..add([r.col[p], top, dn])
          ..add([r.col[i], dn, botI]);
        horizontals.add([r.col[p], r.col[i], dn]);
      default:
        verticals.add([r.col[i], up, botI]);
        horizontals.add([r.col[p], r.col[i], up]);
    }
  }
  var x = 0;
  for (final [a, b, level] in horizontals) {
    for (final [c, lo, hi] in verticals) {
      if (min(a, b) < c && c < max(a, b) && lo < level && level < hi) x++;
    }
  }
  return x;
}

/// Naive segments of a greedy layout: chains of straight edges, with their §4.3 reservations
/// [a, b) re-derived literally. Returns (segment per node, a per segment, b per segment).
(List<int>, List<int>, List<int>) naiveSegments(GraphLayout l) {
  final n = l.n, u = l.unit, y = l.y, fp = l.fp, prio = l.input.priority;
  final cont = List.filled(n, -1);
  for (var i = 0; i < n; i++) {
    final f = fp[i];
    if (f >= 0 && (cont[f] < 0 || prio[i] < prio[cont[f]])) cont[f] = i;
  }
  final seg = List.filled(n, -1);
  final a = <int>[], b = <int>[];
  for (var i = n - 1; i >= 0; i--) {
    final f = fp[i];
    if (f >= 0 && l.routes[l.lpStart[i]] == routeStraight) {
      seg[i] = seg[f];
    } else {
      seg[i] = a.length;
      a.add(1 << 60);
      b.add(-(1 << 60));
    }
  }
  for (var i = 0; i < n; i++) {
    final ends = [
      y[i],
      if (cont[i] >= 0) y[cont[i]] - u,
      for (var s = l.chStart[i]; s < l.chStart[i + 1]; s++)
        if (l.chPos[s] >= 1) y[l.chIdx[s]] - u,
    ];
    final ai = fp[i] >= 0 ? y[fp[i]] + u : y[i];
    final bi = ends.reduce(max) + 2 * u;
    a[seg[i]] = min(a[seg[i]], ai);
    b[seg[i]] = max(b[seg[i]], bi);
  }
  return (seg, a, b);
}

/// SPEC §4.7's model cost of [lanes] (per node) over greedy layout [l], from scratch:
/// U·(400·X + 4·Len) + κ·Σ column·(b − a), with blocked-merge verticals clipped to 10·a − 3U.
int naiveCompactCost(GraphLayout l, List<int> lanes) {
  final u = l.unit, y = l.y;
  final (seg, a, b) = naiveSegments(l);
  final verticals = <List<int>>[]; // [col, lo, hi]
  final horizontals = <List<int>>[]; // [colA, colB, level]
  for (var e = 0; e < l.edgeCount; e++) {
    final p = l.edgeParent[e], i = l.edgeChild[e];
    final botP = 10 * y[p], botI = 10 * y[i];
    final top = botP + 5 * u, up = botP + 7 * u, dn = botI - 2 * u;
    switch (l.routes[e]) {
      case routeStraight:
        verticals.add([lanes[p], top, botI]);
      case routeMerge:
        verticals
          ..add([lanes[p], top, dn])
          ..add([lanes[i], dn, botI]);
        horizontals.add([lanes[p], lanes[i], dn]);
      default:
        verticals.add([lanes[i], max(up, 10 * a[seg[i]] - 3 * u), botI]);
        horizontals.add([lanes[p], lanes[i], up]);
    }
  }
  var x = 0, len = 0, grav = 0;
  for (final [ca, cb, level] in horizontals) {
    len += (ca - cb).abs();
    for (final [c, lo, hi] in verticals) {
      if (min(ca, cb) < c && c < max(ca, cb) && lo < level && level < hi) x++;
    }
  }
  final col = List.filled(a.length, -1);
  for (var i = 0; i < l.n; i++) {
    check(col[seg[i]] < 0 || col[seg[i]] == lanes[i], 'segment ${seg[i]} split over columns');
    col[seg[i]] = lanes[i];
  }
  for (var s = 0; s < a.length; s++) {
    grav += compactGravity * col[s] * (b[s] - a[s]);
  }
  return u * (400 * x + 4 * len) + grav;
}

/// Reservations of the segments in one column never overlap.
void checkDisjointReservations(GraphLayout l, List<int> lanes, String what) {
  final (seg, a, b) = naiveSegments(l);
  final byCol = <int, List<int>>{};
  final seen = <int>{};
  for (var i = 0; i < l.n; i++) {
    if (seen.add(seg[i])) (byCol[lanes[i]] ??= []).add(seg[i]);
  }
  for (final MapEntry(key: c, value: segs) in byCol.entries) {
    segs.sort((s, t) => a[s] - a[t]);
    for (var k = 1; k < segs.length; k++) {
      check(b[segs[k - 1]] <= a[segs[k]], '$what: reservations overlap in column $c');
    }
  }
}

/// The clamped T(i) of SPEC §4.2 free, steps 1–2, from scratch.
List<int> clampedT(LayoutInput g, List<List<int>> lp) {
  final n = g.n;
  var tmin = 0;
  var found = false;
  for (var i = 0; i < n; i++) {
    if (g.hasTs[i] != 0 && (!found || g.ts[i] < tmin)) {
      tmin = g.ts[i];
      found = true;
    }
  }
  final tt = List.filled(n, 0);
  for (var i = n - 1; i >= 0; i--) {
    tt[i] = [g.isRoot[i] != 0 || g.hasTs[i] == 0 ? tmin : g.ts[i], for (final p in lp[i]) tt[p]].reduce(max);
  }
  return tt;
}

/// SPEC §7.3 I5 for `free` (amended 2026-10-01): `day` buckets only, values strictly ascending,
/// start ≤ end, end_k ≤ start_{k+1}, every non-root node inside the bucket of its clamped T's day,
/// start / end its members' min / max y, and no bucket iff no non-root node.
void checkFreeDayBuckets(LayoutInput g, LayoutResult r, List<List<int>> lp, String what) {
  final tt = clampedT(g, lp);
  final count = r.bucketKind.length;
  for (var b = 0; b < count; b++) {
    check(r.bucketKind[b] == bucketDay, '$what: I5 free kind');
    check(r.bucketStart[b] <= r.bucketEnd[b], '$what: I5 free start ≤ end');
    if (b > 0) {
      check(r.bucketValue[b - 1] < r.bucketValue[b], '$what: I5 free ascending');
      check(r.bucketEnd[b - 1] <= r.bucketStart[b], '$what: I5 free ranges in order');
    }
  }
  final lo = List.filled(count, 1 << 62), hi = List.filled(count, -(1 << 62));
  var nonRoot = 0;
  for (var i = 0; i < g.n; i++) {
    if (g.isRoot[i] != 0) continue;
    nonRoot++;
    final b = r.bucketValue.indexOf(dayKey(tt[i], g.utcOffsetMin));
    check(b >= 0, '$what: I5 free node $i has its day bucket');
    if (b < 0) continue;
    lo[b] = min(lo[b], r.row[i]);
    hi[b] = max(hi[b], r.row[i]);
  }
  check((count == 0) == (nonRoot == 0), '$what: I5 free no bucket iff no non-root node');
  for (var b = 0; b < count; b++) {
    check(r.bucketStart[b] == lo[b] && r.bucketEnd[b] == hi[b], '$what: I5 free start / end = members\' min / max y');
  }
}

/// SPEC §7.3 I1–I6.
void checkInvariants(LayoutInput g, LayoutResult r, String what) {
  final n = g.n, u = r.unit, y = r.row;
  // Layout parents, fp, pos.
  final lp = [
    for (var i = 0; i < n; i++)
      [
        for (var k = g.parStart[i]; k < g.parStart[i + 1]; k++)
          if (g.parIdx[k] >= 0) g.parIdx[k],
      ],
  ];
  var e = 0;
  final straight = <int>{};
  for (var i = 0; i < n; i++) {
    for (var pos = 0; pos < lp[i].length; pos++, e++) {
      final p = lp[i][pos];
      check(r.edgeFrom[e] == p && r.edgeTo[e] == i, '$what: edge order');
      // I1
      check(y[i] >= y[p] + u, '$what: I1 edge $p→$i');
      // I3
      final route = r.edgeRoute[e], blocked = r.edgeBlocked[e] != 0, same = r.lane[p] == r.lane[i];
      check((route == routeStraight) == same, '$what: I3 straight ⇔ same lane');
      if (same) check(pos == 0, '$what: I3 straight ⇒ first parent');
      if (route == routeMerge) check(pos >= 1 && !blocked, '$what: I3 merge');
      if (blocked) check(!same, '$what: I3 blocked ⇒ lanes differ');
      if (route == routeStraight) straight.add(p * n + i);
    }
  }
  check(e == r.edgeFrom.length, '$what: edge count');
  // I2
  final byLane = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    (byLane[r.lane[i]] ??= []).add(i);
  }
  for (final nodes in byLane.values) {
    nodes.sort((a, b) => y[a].compareTo(y[b]));
    for (var k = 1; k < nodes.length; k++) {
      final lo = nodes[k - 1], hi = nodes[k];
      final need = straight.contains(lo * n + hi) ? u : 2 * u;
      check(y[hi] - y[lo] >= need, '$what: I2 lane ${r.lane[lo]} nodes $lo, $hi');
    }
  }
  // I4
  final pi = <int, int>{};
  for (var i = 0; i < n; i++) {
    check((pi[r.lane[i]] ??= r.col[i]) == r.col[i], '$what: I4 col = π(lane)');
    if (r.order == LaneOrder.greedy) check(r.col[i] == r.lane[i], '$what: I4 greedy');
  }
  check(pi.values.toSet().length == pi.length, '$what: I4 permutation');
  if (n > 0) check(pi[0] == 0, '$what: I4 π(0) = 0');
  // Rows / lanes.
  check(r.rows == (n == 0 ? 0 : y.reduce(max) + u), '$what: rows');
  check(r.lanes == (n == 0 ? 0 : r.lane.reduce(max) + 1), '$what: lanes');
  // I5
  if (r.mode == Mode.compact) {
    check(r.bucketKind.isEmpty, '$what: I5 no buckets');
  } else if (r.mode == Mode.free) {
    checkFreeDayBuckets(g, r, lp, what);
  } else {
    int keyOf(int b) => switch (r.bucketKind[b]) {
      bucketRoot => rootKey,
      bucketAge => g.nowMs - r.bucketValue[b] * minute,
      _ => r.bucketValue[b],
    };
    final eb = List.filled(n, 0);
    for (var i = n - 1; i >= 0; i--) {
      eb[i] = [
        g.isRoot[i] != 0 || g.hasTs[i] == 0 ? rootKey : timeBucketKey(g.ts[i], g.nowMs, g.utcOffsetMin),
        for (final p in lp[i]) eb[p],
      ].reduce(max);
    }
    var next = 0;
    for (var b = 0; b < r.bucketKind.length; b++) {
      if (b > 0) check(keyOf(b) > keyOf(b - 1), '$what: I5 ascending');
      check(r.bucketStart[b] == next && r.bucketEnd[b] >= r.bucketStart[b], '$what: I5 contiguous');
      next = r.bucketEnd[b] + 1;
    }
    check(next == r.rows, '$what: I5 covers 0..rows−1');
    for (var i = 0; i < n; i++) {
      final b = [for (var b = 0; b < r.bucketKind.length; b++) keyOf(b)].indexOf(eb[i]);
      check(b >= 0 && r.bucketStart[b] <= y[i] && y[i] <= r.bucketEnd[b], '$what: I5 node $i in its bucket');
    }
  }
  // I6
  if (r.mode == Mode.free && n > 0) {
    var tmin = 0;
    var found = false;
    for (var i = 0; i < n; i++) {
      if (g.hasTs[i] != 0 && (!found || g.ts[i] < tmin)) {
        tmin = g.ts[i];
        found = true;
      }
    }
    final tt = List.filled(n, 0);
    for (var i = n - 1; i >= 0; i--) {
      tt[i] = [g.isRoot[i] != 0 || g.hasTs[i] == 0 ? tmin : g.ts[i], for (final p in lp[i]) tt[p]].reduce(max);
    }
    final order = List.generate(n, (i) => i)..sort((a, b) => tt[a] != tt[b] ? tt[a].compareTo(tt[b]) : b - a);
    for (var k = 1; k < n; k++) {
      check(y[order[k]] >= y[order[k - 1]], '$what: I6');
    }
  }
}
