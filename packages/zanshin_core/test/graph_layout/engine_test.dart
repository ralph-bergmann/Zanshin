// SPDX-License-Identifier: MIT

// Unit tests of the product layout engine (Story 4.11): the spike's hand-traced tests
// (spikes/graph-layout-ab/dart/test/layout_test.dart) for the shipped scope — modes compact and
// free, orders greedy and compact — ported to package:test, plus `free`'s day buckets. The graphs
// list nodes children-first (jj log order); every expectation was derived by hand from
// docs/graph-layout.md §4.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/graph_layout/compact_order.dart';
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import 'invariants.dart';
import 'support/spec_json.dart';

/// Lays [g] out and reads the grid.
GraphGridView run(LayoutInput g, LayoutMode mode, [LaneOrder order = LaneOrder.greedy]) =>
    GraphGridView.fromBytes(computeGraphGrid(g, mode: mode, order: order, budget: defaultLayoutBudget));

const _routeNames = <String>['straight', 'merge', 'branch_off'];

/// Edges as (from, to, route, blocked) tuples for compact comparison.
List<List<Object>> edges(GraphGridView r) => [
  for (var e = 0; e < r.edgeCount; e++)
    [r.edgeFroms[e], r.edgeTos[e], _routeNames[r.edgeRoutes[e]], r.edgeBlocked[e] != 0],
];

/// The joint packing (docs/graph-layout.md §4.3, amended 2026-10-27) read literally: both models'
/// intervals (half-open [a, b)), a node fits a lane iff no interval there except the excluded
/// owner's overlaps it in either model; packed once in each model's visit order, the fewer lanes
/// kept, `compact`'s on a tie. Returns the lanes and both visit orders' lane counts.
(List<int>, int, int) naiveJointLanes(LayoutInput g) {
  final ls = [LayoutEngine(g, LayoutMode.compact)..layering(), LayoutEngine(g, LayoutMode.free)..layering()];
  final int n = g.n;
  final Int32List fp = ls[0].fp;
  final Int32List prio = g.priority;
  final List<int> cont = List.filled(n, -1);
  for (var i = 0; i < n; i++) {
    final int f = fp[i];
    if (f >= 0 && (cont[f] < 0 || prio[i] < prio[cont[f]])) {
      cont[f] = i;
    }
  }
  List<int> interval(int k, int i) {
    final LayoutEngine l = ls[k];
    final Int64List y = l.y;
    final int u = l.unit;
    final ey = <int>[
      if (cont[i] >= 0) y[cont[i]],
      for (int s = l.chStart[i]; s < l.chStart[i + 1]; s++)
        if (l.chPos[s] >= 1) y[l.chIdx[s]],
    ];
    final int end = ey.isEmpty ? y[i] : max(y[i], ey.reduce(max) - u);
    return [if (fp[i] >= 0) y[fp[i]] + u else y[i], end + 2 * u];
  }

  final List<List<List<int>>> ivs = [for (var k = 0; k < 2; k++) List.generate(n, (i) => interval(k, i))];
  (List<int>, int) pack(int v) {
    final Int64List y = ls[v].y;
    final List<int> order = List.generate(n, (i) => i)
      ..sort((a, b) => y[a] != y[b] ? y[a].compareTo(y[b]) : (prio[a] != prio[b] ? prio[a] - prio[b] : a - b));
    final lanes = <List<int>>[]; // the owners per lane
    bool overlap(int k, int x, int i) => ivs[k][x][0] < ivs[k][i][1] && ivs[k][i][0] < ivs[k][x][1];
    bool fits(int lane, int i, int except) =>
        lane >= lanes.length || !lanes[lane].any((x) => x != except && (overlap(0, x, i) || overlap(1, x, i)));
    final List<int> lane = List.filled(n, -1);
    for (final i in order) {
      var chosen = -1;
      if (fp[i] >= 0 && cont[fp[i]] == i && fits(lane[fp[i]], i, fp[i])) {
        chosen = lane[fp[i]];
      }
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

  final (List<int> compactLanes, int compactCount) = pack(0);
  final (List<int> freeLanes, int freeCount) = pack(1);
  return (compactCount <= freeCount ? compactLanes : freeLanes, compactCount, freeCount);
}

/// The design's blocked formula, O(E·n), with D4.
List<int> naiveBlocked(LayoutEngine l) => [
  for (var e = 0; e < l.edgeCount; e++)
    () {
      final int p = l.edgeParent[e];
      final int i = l.edgeChild[e];
      if (l.lane[p] == l.lane[i]) {
        return 0;
      }
      for (var o = 0; o < l.n; o++) {
        if (l.lane[o] == l.lane[p] && l.y[o] > l.y[p] && l.y[o] <= l.y[i]) {
          return 1;
        }
      }
      return 0;
    }(),
];

void main() {
  group('arithmetic', () {
    test('floor_division_rounds_toward_minus_infinity', () {
      expect([floorDiv(7, 5), floorDiv(-1, 5), floorDiv(-5, 5), floorDiv(-6, 5), floorDiv(0, 5)], [1, -1, -1, -2, 0]);
    });

    test('free_gap_curve_matches_the_spec_table', () {
      final List<int> gaps = [0, 59999, minute, hour, day, 7 * day, 365 * day, 100 * 365 * day].map(freeGap).toList();
      expect(gaps, [0, 0, 2, 11, 20, 26, 38, 48]);
    });

    test('day_key_with_utc_offsets_and_negative_timestamps', () {
      expect(dayKey(-1, 0), -day);
      expect(dayKey(0, -300), -day + 5 * hour, reason: 'UTC−5: 1970-01-01T00:00Z is Dec 31 local');
      expect(dayKey(0, 120), -2 * hour, reason: 'UTC+2');
      expect(dayKey(day - 2 * hour, 120), day - 2 * hour, reason: 'UTC+2 local midnight itself');
      expect(dayKey(0, 330), -330 * minute, reason: 'UTC+5:30');
      expect([dayKey(0, 1440), dayKey(0, -1440)], [0, 0], reason: '±1 day: midnight UTC is local midnight');
    });
  });

  group('layering', () {
    test('compact_rows_are_the_longest_path_over_chains_and_merges', () {
      // 0: merge of 1 and 3; 1 → 2 → 3.
      final GraphGridView r = run(
        specGraph([
          [1, 3],
          [2],
          [3],
          [],
        ]),
        LayoutMode.compact,
      );
      expect(r.nodeRows, [3, 2, 1, 0]);
      expect([r.rows, r.unit], [4, 1]);
    });

    test('compact_ignores_missing_parents_and_counts_indirect_ones', () {
      final GraphGridView r = run(
        specGraph([
          [null, const Ind(1)],
          [null],
          [],
        ]),
        LayoutMode.compact,
      );
      expect(r.nodeRows, [1, 0, 0]);
      expect(edges(r), hasLength(1));
      expect(r.edgeKinds[0], GraphGridView.edgeKindIndirect);
      expect(r.bucketCount, 0, reason: 'compact emits no bucket');
    });

    test('free_takes_the_gap_or_one_pitch_per_commit', () {
      const t0 = 1700000000000;
      expect(
        run(
          specGraph(
            [
              [1],
              [],
            ],
            ts: [t0 + hour, t0],
          ),
          LayoutMode.free,
        ).nodeRows,
        [16, 0],
        reason: '1 h: the pitch wins',
      );
      expect(
        run(
          specGraph(
            [
              [1],
              [],
            ],
            ts: [t0 + day, t0],
          ),
          LayoutMode.free,
        ).nodeRows,
        [20, 0],
        reason: '1 day: the gap wins',
      );
      final GraphGridView r = run(specGraph([[], []], ts: [t0 + minute, t0]), LayoutMode.free);
      expect(r.nodeRows, [2, 0], reason: 'unrelated nodes: time axis only');
      expect([r.rows, r.unit], [18, 16]);
    });

    test('free_clamps_a_child_older_than_its_parent_and_the_root_takes_tmin', () {
      const t0 = 1700000000000;
      // Visit order: 2 (T = t0), then 1 and 0 (both T = t0 + 1 day, index descending).
      final GraphGridView r = run(
        specGraph(
          [
            [1],
            [2],
            [],
          ],
          ts: [t0, t0 + day, null],
          roots: {2},
        ),
        LayoutMode.free,
      );
      expect(r.nodeRows, [36, 20, 0]);
      expect(r.rows, 52);
      // Day buckets: 0 counts by its clamped T (1's day), the root by none.
      expect(r.bucketValues, [floorDiv(t0 + day, day) * day]);
      expect(
        [r.bucketStarts, r.bucketEnds],
        [
          [20],
          [36],
        ],
      );
    });

    test('free_tmin_is_the_least_non_null_ts_including_a_roots', () {
      const t0 = 1700000000000;
      final GraphGridView r = run(
        specGraph(
          [
            [1],
            [],
          ],
          ts: [t0, t0 - 365 * day],
          roots: {1},
        ),
        LayoutMode.free,
      );
      expect(r.nodeRows, [38, 0]);
    });
  });

  group('free day buckets', () {
    test('two_days_less_than_a_minute_apart_across_local_midnight_end_a_pitch_apart', () {
      // Story 4.16: the walk step across a day change is max(gap, U) = 16, not gap(30 s) = 0.
      const midnight = 1000072800000; // 2001-09-10T00:00 at UTC+2
      final GraphGridView r = run(
        specGraph([[], [], []], ts: [midnight + 10000, midnight - 20000, null], roots: {2}, offset: 120),
        LayoutMode.free,
      );
      expect(r.nodeRows, [16, 0, 0]);
      expect(r.bucketKinds, [GraphGridView.bucketKindDay, GraphGridView.bucketKindDay]);
      expect(r.bucketValues, [midnight - day, midnight]);
      expect(
        [r.bucketStarts, r.bucketEnds],
        [
          [0, 16],
          [0, 16],
        ],
      );
    });

    // Story 4.16 (docs/graph-layout.md §4.2 free.3, amended 2026-10-31): the day band.
    const int midnight = 1000080000000 - 1000080000000 % day; // a UTC midnight
    test('day_band_the_demo_hand_case_2350_and_0010_in_two_columns_end_a_pitch_apart', () {
      // 0:B 00:10 → R, 1:A 23:50 → R, 2:R. Walk R 0, A 16, B 16 + max(gap(20 min) = 8, 16).
      final LayoutInput g = specGraph(
        [
          [2],
          [2],
          [],
        ],
        ts: [midnight + 10 * minute, midnight - 10 * minute, null],
        roots: {2},
      );
      final GraphGridView r = run(g, LayoutMode.free, LaneOrder.compact);
      expect(r.nodeRows, [32, 16, 0]);
      expect(r.rows, 48);
      expect(
        [r.bucketValues, r.bucketStarts, r.bucketEnds],
        [
          [midnight - day, midnight],
          [16, 32],
          [16, 32],
        ],
      );
      expect(r.nodeCols[0], isNot(r.nodeCols[1]));
      expect(invariantFailures(g, r), isEmpty);
      final GraphGridView c = run(g, LayoutMode.compact, LaneOrder.compact);
      expect([c.nodeLanes, c.nodeCols], [r.nodeLanes, r.nodeCols], reason: 'I8');

      // The pre-4.16 walk (B at A's 16, the buckets meet) fails the strengthened I5.
      final meet = GraphGridView.fromBytes(
        writeGraphGrid(
          mode: r.mode,
          order: r.order,
          unit: r.unit,
          rows: 32,
          lanes: r.lanes,
          nodeRows: Int64List.fromList([16, 16, 0]),
          nodeLanes: Int32List.fromList(r.nodeLanes),
          nodeCols: Int32List.fromList(r.nodeCols),
          nodeDays: Int64List.fromList(r.nodeDays),
          edgeFroms: Int32List.fromList(r.edgeFroms),
          edgeTos: Int32List.fromList(r.edgeTos),
          edgeKinds: Uint8List.fromList(r.edgeKinds),
          edgeRoutes: Uint8List.fromList(r.edgeRoutes),
          edgeBlocked: Uint8List.fromList(r.edgeBlocked),
          bucketValues: Int64List.fromList(r.bucketValues),
          bucketStarts: Int64List.fromList([16, 16]),
          bucketEnds: Int64List.fromList([16, 16]),
        ),
      );
      expect(invariantFailures(g, meet), contains('I5 free: bucket 1 a pitch above 0'));
    });

    test('day_band_steps_already_a_pitch_apart_or_on_one_day_are_unchanged', () {
      // 0:B → 1:A → 2:R across midnight: the parent edge already spaces B 16 above A.
      final GraphGridView chain = run(
        specGraph(
          [
            [1],
            [2],
            [],
          ],
          ts: [midnight + 10 * minute, midnight - 10 * minute, null],
          roots: {2},
        ),
        LayoutMode.free,
      );
      expect(chain.nodeRows, [32, 16, 0]);
      // Two columns: 21:00 / 02:00 across midnight, gap(5 h) = 16; 23:30 / 23:50 on one day, gap = 8.
      for (final (int a, int b, int want) in [
        (midnight - 3 * hour, midnight + 2 * hour, 32),
        (midnight - 30 * minute, midnight - 10 * minute, 24),
      ]) {
        final GraphGridView r = run(
          specGraph(
            [
              [2],
              [2],
              [],
            ],
            ts: [b, a, null],
            roots: {2},
          ),
          LayoutMode.free,
        );
        expect(r.nodeRows, [want, 16, 0], reason: 'A $a B $b');
      }
    });

    test('the_root_is_in_no_bucket_and_a_root_only_graph_has_none', () {
      expect(run(specGraph([[]], ts: [null], roots: {0}), LayoutMode.free).bucketCount, 0);
      final GraphGridView r = run(specGraph([[], []], ts: [now, null], roots: {1}), LayoutMode.free);
      expect(r.bucketCount, 1);
      expect([r.bucketStarts[0], r.bucketEnds[0]], [r.nodeRows[0], r.nodeRows[0]]);
    });

    test('a_non_root_node_with_a_null_ts_counts_by_its_clamped_t', () {
      const t1 = 1700000000000;
      final GraphGridView r = run(
        specGraph(
          [
            [1],
            [2],
            [],
          ],
          ts: [null, t1, null],
          roots: {2},
        ),
        LayoutMode.free,
      );
      expect(r.nodeRows, [32, 16, 0]);
      expect(r.bucketValues, [floorDiv(t1, day) * day]);
      expect(
        [r.bucketStarts, r.bucketEnds],
        [
          [16],
          [32],
        ],
      );
    });

    test('the_day_key_follows_the_utc_offset_minus_300_0_330_and_plus_minus_1440', () {
      for (final (int offset, int want) in [
        (-300, -day + 5 * hour),
        (0, 0),
        (330, -330 * minute),
        (1440, 0),
        (-1440, 0),
      ]) {
        final GraphGridView r = run(
          specGraph(
            [
              [1],
              [],
            ],
            ts: [0, null],
            roots: {1},
            offset: offset,
          ),
          LayoutMode.free,
        );
        expect(r.bucketValues, [want], reason: 'offset $offset');
      }
    });

    test('compact_emits_no_bucket_whatever_the_timestamps', () {
      final GraphGridView r = run(specGraph([[], []], ts: [now, now - day]), LayoutMode.compact);
      expect(r.bucketCount, 0);
    });
  });

  group('lane packing', () {
    test('a_chain_keeps_one_lane_all_straight', () {
      final GraphGridView r = run(
        specGraph([
          [1],
          [2],
          [],
        ]),
        LayoutMode.compact,
      );
      expect(r.nodeLanes, [0, 0, 0]);
      expect(edges(r), [
        [1, 0, 'straight', false],
        [2, 1, 'straight', false],
      ]);
    });

    test('the_continuation_child_is_the_least_priority_and_index_the_other_branches_off_blocked', () {
      final GraphGridView r = run(
        specGraph(
          [
            [2],
            [2],
            [],
          ],
          priority: [1, 0, 0],
        ),
        LayoutMode.compact,
      );
      expect(r.nodeLanes, [1, 0, 0]);
      expect(edges(r), [
        [2, 0, 'branch_off', true],
        [2, 1, 'straight', false],
      ]);
    });

    test('a_merge_child_extends_the_parent_reservation_unblocked_merge_blocked_branch_off', () {
      final GraphGridView r = run(
        specGraph([
          [1, 2],
          [3],
          [3],
          [],
        ]),
        LayoutMode.compact,
      );
      expect(r.nodeRows, [2, 1, 1, 0]);
      expect(r.nodeLanes, [0, 0, 1, 0]);
      expect(edges(r), [
        [1, 0, 'straight', false],
        [2, 0, 'merge', false],
        [3, 1, 'straight', false],
        [3, 2, 'branch_off', true],
      ]);
    });

    test('one_row_buffer_an_adjacent_interval_does_not_fit_a_buffered_one_does', () {
      // 0:C→3:B, 1:F→3:B, 2:E→5:A, 3:B→5:A, 4:D→6:R, 5:A→6:R, 6:R.
      // D takes lane 1 as [1,3); E would start at row 2 → lane 2; F starts at row 3 → lane 1.
      final GraphGridView r = run(
        specGraph(
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
        LayoutMode.compact,
      );
      expect(r.nodeRows, [3, 3, 2, 2, 1, 1, 0]);
      expect(r.nodeLanes, [0, 1, 2, 0, 1, 0, 0]);
      expect(r.lanes, 3);
      expect(edges(r), [
        [3, 0, 'straight', false],
        [3, 1, 'branch_off', true],
        [5, 2, 'branch_off', true],
        [5, 3, 'straight', false],
        [6, 4, 'branch_off', true],
        [6, 5, 'straight', false],
      ]);
    });

    test('continuation_is_refused_by_the_grandparents_merge_reservation', () {
      // 0:I→2:F, 1:M→[3:X, 4:G], 2:F→4:G, 3:X→4:G, 4:G. G reserves lane 0 up to M's row;
      // F continues G (G's own interval excepted), I cannot continue F (G's interval is not F's).
      final GraphGridView r = run(
        specGraph(
          [
            [2],
            [3, 4],
            [4],
            [4],
            [],
          ],
          priority: [0, 1, 0, 1, 0],
        ),
        LayoutMode.compact,
      );
      expect(r.nodeRows, [2, 2, 1, 1, 0]);
      expect(r.nodeLanes, [2, 1, 0, 1, 0]);
      expect(edges(r), [
        [2, 0, 'branch_off', false],
        [3, 1, 'straight', false],
        [4, 1, 'branch_off', true], // blocked merge → branch_off (D9)
        [4, 2, 'straight', false],
        [4, 3, 'branch_off', true],
      ]);
    });

    test('lane_packing_equals_the_literal_two_model_interval_scan_on_random_graphs', () {
      final rnd = Random(7);
      var freeFewer = 0;
      var compactFewer = 0;
      var tie = 0;
      for (var t = 0; t < 300; t++) {
        final LayoutInput g = randomGraph(rnd, 1 + rnd.nextInt(70), branchy: t.isOdd);
        final (List<int> want, int compactCount, int freeCount) = naiveJointLanes(g);
        if (freeCount < compactCount) {
          freeFewer++;
        } else if (compactCount < freeCount) {
          compactFewer++;
        } else {
          tie++;
        }
        for (final LayoutMode mode in LayoutMode.values) {
          final l = LayoutEngine(g, mode)
            ..layering()
            ..packLanes()
            ..markBlocked();
          expect(l.lane, want, reason: 'lanes, case $t $mode');
          expect(l.blocked, naiveBlocked(l), reason: 'blocked, case $t $mode');
        }
      }
      expect([freeFewer, compactFewer, tie], everyElement(greaterThan(0)), reason: 'each visit-order outcome');
    });
  });

  group('compact lane order', () {
    // Trunk R-A1-…-A8 (lane 0). L = L1…L4 branches off A1 and merges into A5; S = S1 branches off
    // A2 and merges into A4, nested inside L; X = X1 branches off A6 and merges into A8, after L.
    // Greedy: L and X share lane 1, S takes lane 2, and S's two horizontals cross L (X = 2).
    //   0:A8→[A7, X1] 1:X1→A6 2:A7→A6 3:A6→A5 4:A5→[A4, L4] 5:L4→L3 6:A4→[A3, S1] 7:L3→L2
    //   8:S1→A2 9:A3→A2 10:L2→L1 11:A2→A1 12:L1→A1 13:A1→R 14:R
    final LayoutInput nested = specGraph(
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

    test('a_window_swap_puts_s_inside_l_and_leaves_x_in_column_1', () {
      final GraphGridView greedy = run(nested, LayoutMode.compact);
      expect(greedy.nodeRows, [9, 8, 8, 7, 6, 5, 4, 4, 3, 3, 3, 2, 2, 1, 0]);
      expect(greedy.nodeLanes, [0, 1, 0, 0, 0, 1, 0, 1, 2, 0, 1, 0, 1, 0, 0]);
      expect(tickCrossings(greedy), 2);
      // compact: only the window of L and S is swapped; X stays in column 1.
      final GraphGridView compact = run(nested, LayoutMode.compact, LaneOrder.compact);
      expect(compact.nodeLanes, [0, 1, 0, 0, 0, 2, 0, 2, 1, 0, 2, 0, 2, 0, 0]);
      expect(compact.nodeCols, compact.nodeLanes);
      expect(tickCrossings(compact), 0);
      expect(edges(compact), edges(greedy));
    });

    test('the_joint_model_cost_of_the_hand_trace_falls_from_35072_to_11776', () {
      // No timestamps: every T is tmin, so free's walk (index descending) gives each node one pitch
      // above its parents and nothing more — free y = 16·compact y here, every free interval is 16×
      // its compact one, and the joint packing is compact's.
      expect(greedyEngine(nested, LayoutMode.free).y, [
        for (final y in greedyEngine(nested, LayoutMode.compact).y) 16 * y,
      ]);
      final LayoutEngine l = greedyEngine(nested, LayoutMode.compact);
      final co = CompactOrder(l, budget: defaultLayoutBudget);
      // Compact: segments trunk (col 0), L [2, 7) col 1, S [3, 5) col 2, X [8, 10) col 1. X = 2,
      // Len = 8, gravity 24·(1·5 + 2·2 + 1·2) = 264: 400·2 + 4·8 + 264 = 1096. Free: the same X and
      // Len times U = 16, every reservation 16× as long: 16·1096. Joint: 16·1096 + 16·1096 = 35072.
      expect(co.totalCost(), 35072);
      co.run();
      // L col 2, S col 1: X = 0, Len = 8, gravity 24·(2·5 + 1·2 + 1·2) = 336, so 368 per model:
      // 32·368 = 11776.
      expect(co.totalCost(), 11776);
    });

    test('the_joint_search_cost_is_exact_never_above_greedy_mode_independent_and_keeps_chains_routes_and_lane_0', () {
      final rnd = Random(17);
      var swapped = 0;
      for (var t = 0; t < 150; t++) {
        final LayoutInput g = randomGraph(rnd, 1 + rnd.nextInt(90), branchy: t.isOdd);
        final Int32List fromFree = CompactOrder(greedyEngine(g, LayoutMode.free), budget: defaultLayoutBudget).run();
        for (final LayoutMode mode in LayoutMode.values) {
          final what = 'case $t $mode';
          final LayoutEngine l = greedyEngine(g, mode);
          final int start = naiveCompactCost(g, l.lane);
          final co = CompactOrder(l, budget: defaultLayoutBudget);
          expect(co.totalCost(), start, reason: '$what: start cost');
          expect(
            CompactOrder(l, budget: defaultLayoutBudget, rounds: 0).run(),
            l.lane,
            reason: '$what: no rounds = greedy',
          );
          final Int32List lanes = co.run();
          expect(lanes, fromFree, reason: '$what: the search does not depend on the mode');
          final beforeDrop = Int32List.fromList([for (var i = 0; i < g.n; i++) co.colOf[co.seg[i]]]);
          final int searched = naiveCompactCost(g, beforeDrop);
          expect(co.totalCost(), searched, reason: '$what: searched cost');
          expect(searched, lessThanOrEqualTo(start), reason: '$what: above greedy');
          expect(naiveCompactCost(g, lanes), lessThanOrEqualTo(searched), reason: '$what: dropping columns raised it');
          if (searched < start) {
            swapped++;
          }
          expect(reservationFailures(greedyEngine(g, LayoutMode.compact), lanes), isEmpty, reason: '$what compact');
          expect(reservationFailures(greedyEngine(g, LayoutMode.free), lanes), isEmpty, reason: '$what free');

          final GraphGridView greedy = run(g, mode);
          final GraphGridView compact = run(g, mode, LaneOrder.compact);
          expect(compact.nodeLanes, lanes, reason: '$what: computeGraphGrid lanes');
          expect(compactAgainstGreedy(g, greedy, compact), isEmpty, reason: what);
          expect(
            canonicalOutput(run(g, mode, LaneOrder.compact)),
            canonicalOutput(compact),
            reason: '$what: deterministic',
          );
        }
      }
      expect(swapped, greaterThan(50), reason: 'too few improving searches');
    });

    test('a_budget_cut_joint_search_gives_the_same_lanes_and_cols_in_both_modes', () {
      final rnd = Random(31);
      for (var t = 0; t < 40; t++) {
        final LayoutInput g = randomGraph(rnd, 1 + rnd.nextInt(90), branchy: t.isOdd);
        for (final budget in [0, 10, 40, 200, 1000]) {
          GraphGridView lay(LayoutMode mode) =>
              GraphGridView.fromBytes(computeGraphGrid(g, mode: mode, order: LaneOrder.compact, budget: budget));
          final GraphGridView c = lay(LayoutMode.compact);
          final GraphGridView f = lay(LayoutMode.free);
          expect(
            [c.lanes, c.nodeLanes, c.nodeCols],
            [f.lanes, f.nodeLanes, f.nodeCols],
            reason: 'case $t budget $budget',
          );
        }
      }
    });

    test('skipping_unchanged_windows_ends_where_the_unskipped_search_ends', () {
      // The spike found the blocked-merge case of the skip rule this way (docs/graph-layout.md
      // §4.7, "Corrected in review"): a window's span must reach down to its horizontals.
      final rnd = Random(1);
      for (var t = 0; t < 201; t++) {
        final LayoutInput g = randomGraph(rnd, 1 + rnd.nextInt(150), branchy: t.isOdd);
        for (final LayoutMode mode in LayoutMode.values) {
          Int32List search({required bool skip}) =>
              CompactOrder(greedyEngine(g, mode), budget: 1 << 60, rounds: 1 << 20, skip: skip).run();

          expect(search(skip: true), search(skip: false), reason: 'case $t $mode');
        }
      }
    });
  });

  group('joint columns', () {
    // Trunk R-T1-T2-T3-T4 (lane 0); X branches off T1, Y off T3. In compact rows X's interval is
    // [2, 4) and Y's [4, 6): disjoint, one lane would hold both. X is committed six days after Y,
    // so in free units X [36, 154) and Y [76, 108) overlap: the joint packing splits them.
    //   0:X→T1 1:T4→T3 2:Y→T3 3:T3→T2 4:T2→T1 5:T1→R 6:R
    const int t0 = now - 30 * day;
    final LayoutInput xy = specGraph(
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

    test('two_chains_disjoint_in_compact_but_overlapping_in_free_get_different_lanes_in_both_modes', () {
      final LayoutEngine l = greedyEngine(xy, LayoutMode.compact);
      expect(l.modelY[0], [2, 4, 4, 3, 2, 1, 0], reason: 'compact rows');
      // Free walk: R 0; T1, T2, T3 a day apart (gap 20 each); Y one hour after T3 (gap 11, but one
      // pitch above T3: 76); T4 23 h later (gap 20: 96); X six days later (gap 26: 122).
      expect(l.modelY[1], [122, 96, 76, 60, 40, 20, 0], reason: 'free y');
      // Compact order: R, T1, T2 continue lane 0; X (row 2) finds lane 0 reserved to 4 and takes
      // lane 1; T3, T4 continue; Y [4, 6) fits lane 1 in compact (X ends at 4) but overlaps X in
      // free, so it takes lane 2. Free order: Y (76) takes lane 1, X (122) lane 2. Both need 3
      // lanes; the tie keeps compact's order.
      final (List<int> lanes, int compactCount, int freeCount) = naiveJointLanes(xy);
      expect(
        [compactCount, freeCount, lanes],
        [
          3,
          3,
          [1, 0, 2, 0, 0, 0, 0],
        ],
      );
      for (final LayoutMode mode in LayoutMode.values) {
        final GraphGridView r = run(xy, mode);
        expect(
          [r.lanes, r.nodeLanes, r.nodeCols],
          [
            3,
            [1, 0, 2, 0, 0, 0, 0],
            [1, 0, 2, 0, 0, 0, 0],
          ],
          reason: mode.name,
        );
      }
    });

    test('the_free_visit_order_needs_fewer_lanes_here_so_the_joint_packing_is_its', () {
      // Found by a random search (spike); the expected values are the literal two-model scan's.
      final LayoutInput g = specGraph(
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
      final (List<int> lanes, int compactCount, int freeCount) = naiveJointLanes(g);
      expect([compactCount, freeCount], [5, 4]);
      expect(lanes, [3, 2, 1, 3, 0, 0, 2, 1, 0]);
      for (final LayoutMode mode in LayoutMode.values) {
        expect(run(g, mode).nodeLanes, lanes, reason: mode.name);
      }
    });

    test('one_chain_reduces_to_the_single_model_packing_one_lane', () {
      final LayoutInput chain = specGraph(
        [
          [1],
          [2],
          [3],
          [],
        ],
        ts: [now, now - day, now - 2 * day, null],
        roots: {3},
      );
      for (final LayoutMode mode in LayoutMode.values) {
        final GraphGridView r = run(chain, mode, LaneOrder.compact);
        expect(
          [r.lanes, r.nodeLanes],
          [
            1,
            [0, 0, 0, 0],
          ],
          reason: mode.name,
        );
      }
    });

    test('without_timestamps_the_free_model_is_the_tmin_clamp_and_i8_still_holds', () {
      final rnd = Random(29);
      for (var t = 0; t < 60; t++) {
        final LayoutInput base = randomGraph(rnd, rnd.nextInt(80), branchy: t.isOdd);
        final noTs = LayoutInput(
          utcOffsetMin: base.utcOffsetMin,
          ts: Int64List(base.n),
          hasTs: Uint8List(base.n),
          isRoot: base.isRoot,
          priority: base.priority,
          parStart: base.parStart,
          parIdx: base.parIdx,
          parKind: base.parKind,
        );
        for (final LaneOrder order in LaneOrder.values) {
          final GraphGridView c = run(noTs, LayoutMode.compact, order);
          final GraphGridView f = run(noTs, LayoutMode.free, order);
          expect(invariantFailures(noTs, c), isEmpty, reason: 'case $t $order compact');
          expect(invariantFailures(noTs, f), isEmpty, reason: 'case $t $order free');
          expect(i8Failures(c, f), isEmpty, reason: 'case $t $order');
          // tmin = 0: every non-root node is in the epoch's day, the root in none.
          for (var i = 0; i < noTs.n; i++) {
            expect(c.nodeDays[i], noTs.isRoot[i] != 0 ? GraphGridView.noDay : dayKey(0, noTs.utcOffsetMin));
          }
        }
      }
    });

    test('every_node_has_its_clamped_ts_day_in_both_modes_and_the_root_none', () {
      const t1 = 1700000000000;
      // 0 has no ts and counts by its clamped T (1's); 1 a day key of its own; 2 is the root.
      final LayoutInput g = specGraph(
        [
          [1],
          [2],
          [],
        ],
        ts: [null, t1, null],
        roots: {2},
        offset: 120,
      );
      for (final LayoutMode mode in LayoutMode.values) {
        final GraphGridView r = run(g, mode);
        expect(r.nodeDays, [dayKey(t1, 120), dayKey(t1, 120), GraphGridView.noDay], reason: mode.name);
      }
      expect(dayKey(t1, 120), floorDiv(t1 + 120 * minute, day) * day - 120 * minute);
    });
  });

  group('output and validation', () {
    test('canonical_output_and_digest_of_a_free_layout_with_a_day_bucket', () {
      final GraphGridView r = run(
        specGraph(
          [
            [1, null],
            [],
          ],
          ts: [now - minute, null],
          roots: {1},
        ),
        LayoutMode.free,
      );
      // The amended spike Dart reference's output for this input (free, greedy).
      expect(
        canonicalOutput(r),
        '{"mode":"free","order":"greedy","unit":16,"rows":32,"lanes":1,'
        '"nodes":[{"row":16,"lane":0,"col":0},{"row":0,"lane":0,"col":0}],'
        '"edges":[{"from":1,"to":0,"kind":"direct","route":"straight","blocked":false}],'
        '"buckets":[{"kind":"day","value":999993600000,"start":16,"end":16}]}\n',
      );
      // nodes: 7·16 = 112, then 31·112 = 3472; edge: 31·3472 = 107632; bucket:
      // 31·107632 + 16 + 3·16 = 3336656.
      expect(specDigest(r), 3336656);
    });

    test('an_empty_graph_has_zero_rows_and_lanes_in_every_mode_and_order', () {
      for (final LayoutMode mode in LayoutMode.values) {
        for (final LaneOrder order in LaneOrder.values) {
          expect(
            canonicalOutput(run(specGraph([]), mode, order)),
            '{"mode":"${mode.name}","order":"${order.name}","unit":${mode == LayoutMode.free ? 16 : 1},'
            '"rows":0,"lanes":0,"nodes":[],"edges":[],"buckets":[]}\n',
          );
        }
      }
    });

    test('value_range_violations_throw_the_named_contract_rule', () {
      // Built by hand: the support parser would reject the JSON-level cases itself.
      LayoutInput input({
        int ts = 1,
        int priority = 0,
        int offset = 0,
        List<int> idx = const [1],
        List<int> kind = const [parentDirect],
      }) => LayoutInput(
        utcOffsetMin: offset,
        ts: Int64List.fromList([ts, 0]),
        hasTs: Uint8List.fromList([1, 0]),
        isRoot: Uint8List.fromList([0, 1]),
        priority: Int32List.fromList([priority, 0]),
        parStart: Int32List.fromList([0, idx.length, idx.length]),
        parIdx: Int32List.fromList(idx),
        parKind: Uint8List.fromList(kind),
      );
      Matcher violates(String rule) => throwsA(isA<LayoutContractException>().having((e) => e.rule, 'rule', rule));
      Uint8List lay(LayoutInput g) =>
          computeGraphGrid(g, mode: LayoutMode.free, order: LaneOrder.compact, budget: defaultLayoutBudget);

      lay(input());
      expect(() => lay(input(idx: [-1])), violates('V1'), reason: 'a direct parent without a target');
      expect(() => lay(input(kind: [parentMissing])), violates('V1'), reason: 'a missing parent with a target');
      expect(() => lay(input(kind: [parentMissing + 1])), violates('V1'), reason: 'a parent kind that is no kind');
      expect(() => lay(input(idx: [0])), violates('V2'), reason: 'the node itself');
      expect(() => lay(input(idx: [2])), violates('V2'), reason: 'beyond n');
      expect(() => lay(input(idx: [1, 1], kind: [parentDirect, parentIndirect])), violates('V3'));
      expect(() => lay(input(priority: 0x80000000)), violates('V4'), reason: 'priority 2^31');
      expect(() => lay(input(priority: -1)), violates('V4'), reason: 'negative priority');
      expect(() => lay(input(ts: maxSafeInt + 1)), violates('V4'), reason: 'ts beyond 2^53');
      expect(() => lay(input(ts: -maxSafeInt - 1)), violates('V4'), reason: 'ts below −2^53');
      lay(input(ts: maxSafeInt));
      lay(input(ts: -maxSafeInt));
    });

    test('utc_offset_min_lies_within_plus_minus_1440', () {
      for (final offset in [1440, -1440, 0]) {
        final LayoutInput g = specGraph([[]], ts: [now], offset: offset);
        expect(run(g, LayoutMode.free).bucketCount, 1, reason: 'offset $offset');
      }
      for (final offset in [1441, -1441]) {
        final g = LayoutInput(
          utcOffsetMin: offset,
          ts: Int64List(0),
          hasTs: Uint8List(0),
          isRoot: Uint8List(0),
          priority: Int32List(0),
          parStart: Int32List(1),
          parIdx: Int32List(0),
          parKind: Uint8List(0),
        );
        expect(
          () => computeGraphGrid(g, mode: LayoutMode.free, order: LaneOrder.greedy, budget: 0),
          throwsA(isA<LayoutContractException>().having((e) => e.rule, 'rule', 'V4')),
          reason: 'offset $offset',
        );
      }
    });

    test('the_support_parser_rejects_malformed_json_and_names_contract_rules', () {
      String doc(String node0) =>
          '{"now_ms":0,"utc_offset_min":0,"nodes":[$node0,{"id":"b","ts_ms":null,"is_root":true,"priority":0,"parents":[]}]}';
      const ok = '{"id":"a","ts_ms":1,"is_root":false,"priority":0,"parents":[{"idx":1,"kind":"direct"}]}';
      parseSpecInput(utf8.encode(doc(ok)));
      expect(
        () => parseSpecInput(utf8.encode(doc(ok.replaceFirst('"ts_ms":1', '"ts_ms":1.5')))),
        throwsA(isA<SpecInputError>()),
      );
      expect(() => parseSpecInput(utf8.encode(doc(ok.replaceFirst('"ts_ms":1,', '')))), throwsA(isA<SpecInputError>()));
      expect(() => parseSpecInput(utf8.encode('\u{FEFF}${doc(ok)}')), throwsA(isA<SpecInputError>()));
      expect(
        () => parseSpecInput(utf8.encode(doc(ok.replaceFirst('"idx":1', '"idx":null')))),
        throwsA(isA<LayoutContractException>().having((e) => e.rule, 'rule', 'V1')),
      );
    });
  });

  group('invariants', () {
    test('i1_to_i6_hold_on_random_graphs_in_every_mode_and_order', () {
      final rnd = Random(3);
      for (var t = 0; t < 120; t++) {
        final LayoutInput g = randomGraph(rnd, rnd.nextInt(120), branchy: t.isOdd);
        for (final LayoutMode mode in LayoutMode.values) {
          for (final LaneOrder order in LaneOrder.values) {
            expect(invariantFailures(g, run(g, mode, order)), isEmpty, reason: 'case $t $mode $order');
          }
        }
      }
    });
  });
}
