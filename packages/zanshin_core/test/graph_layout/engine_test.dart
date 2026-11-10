// SPDX-License-Identifier: MIT

// Unit tests of the product layout engine: hand-traced cases for the modes compact and
// free, `free`'s day buckets, and the branch columns of docs/graph-layout.md §4.3 (amended
// 2026-11-10). The graphs list nodes children-first (jj log order); every expectation was derived
// by hand from §4.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';
import 'package:zanshin_core/src/graph_layout/router.dart';

import 'invariants.dart';
import 'support/spec_json.dart';

/// Lays [g] out and reads the grid.
GraphGridView run(LayoutInput g, LayoutMode mode) => GraphGridView.fromBytes(computeGraphGrid(g, mode: mode));

const _routeNames = <String>['straight', 'merge', 'branch_off'];

/// Edges as (from, to, route, blocked) tuples for compact comparison.
List<List<Object>> edges(GraphGridView r) => [
  for (var e = 0; e < r.edgeCount; e++)
    [r.edgeFroms[e], r.edgeTos[e], _routeNames[r.edgeRoutes[e]], r.edgeBlocked[e] != 0],
];

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
      final GraphGridView r = run(g, LayoutMode.free);
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

      // The pre-4.16 walk (B at A's 16, the buckets meet) fails the strengthened I5.
      final meet = GraphGridView.fromBytes(
        writeGraphGrid(
          mode: r.mode,
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

    test('without_timestamps_every_non_root_node_has_the_epochs_day_in_both_modes', () {
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
        for (final LayoutMode mode in LayoutMode.values) {
          final GraphGridView r = run(noTs, mode);
          expect(invariantFailures(noTs, r), isEmpty, reason: 'case $t $mode');
          // tmin = 0: every non-root node is in the epoch's day, the root in none.
          for (var i = 0; i < noTs.n; i++) {
            expect(r.nodeDays[i], noTs.isRoot[i] != 0 ? GraphGridView.noDay : dayKey(0, noTs.utcOffsetMin));
          }
        }
      }
    });
  });

  group('lanes and routes', () {
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

    test('one_pitch_between_two_branches_is_enough_to_share_a_column', () {
      // 0:C→3:B, 1:F→3:B, 2:E→5:A, 3:B→5:A, 4:D→6:R, 5:A→6:R, 6:R.
      // D reserves [1, 1], E [2, 2] and F [3, 3]: each starts one pitch above the last, so all three
      // share column 1.
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
      expect(r.nodeLanes, [0, 1, 1, 0, 1, 0, 0]);
      expect(r.lanes, 2);
      expect(edges(r), [
        [3, 0, 'straight', false],
        [3, 1, 'branch_off', true],
        [5, 2, 'branch_off', true],
        [5, 3, 'straight', false],
        [6, 4, 'branch_off', true],
        [6, 5, 'straight', false],
      ]);
    });

    test('blocked_equals_the_designs_formula_on_random_graphs_in_both_modes', () {
      final rnd = Random(7);
      for (var t = 0; t < 300; t++) {
        final LayoutInput g = randomGraph(rnd, 1 + rnd.nextInt(70), branchy: t.isOdd);
        for (final LayoutMode mode in LayoutMode.values) {
          final l = LayoutEngine(g, mode)
            ..layering()
            ..chooseColumns()
            ..markBlocked();
          expect(l.blocked, naiveBlocked(l), reason: 'blocked, case $t $mode');
        }
      }
    });
  });

  group('branch columns', () {
    // Trunk R-A1-…-A8. L = L1…L4 forks from A1 and merges into A5; S = S1 forks from A2 and merges
    // into A4, nested inside L; X = X1 forks from A6 and merges into A8, after L.
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

    // Trunk R-T1-T2-T3-T4; X forks from T1 and Y from T3. In compact rows X reserves [2, 2] and Y
    // [4, 4]: one pitch apart, so they share a column. X is committed six days after Y, so in free
    // units X reserves [36, 122] and Y [76, 76]: Y lies inside X and takes the nearer column.
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

    /// The columns of [g] in `compact` (without timestamps also `free`'s).
    List<int> columns(LayoutInput g) {
      final GraphGridView r = run(g, LayoutMode.compact);
      expect(run(g, LayoutMode.free).nodeCols, r.nodeCols, reason: 'free has the same columns here');
      expect(invariantFailures(g, r), isEmpty);
      expect(branchFailures(g, r), isEmpty);
      return r.nodeCols;
    }

    test('a_nested_branch_sits_nearer_and_a_later_one_reuses_its_column', () {
      expect(columns(nested), [0, 1, 0, 0, 0, 2, 0, 2, 1, 0, 2, 0, 2, 0, 0]);
    });

    test('of_two_branches_that_overlap_in_part_the_one_that_ends_first_sits_nearer', () {
      // A = 3 forks from R and merges into T4; B = 1 forks from T2 and merges into T5. A is longer
      // but ends first.
      final LayoutInput g = specGraph(
        [
          [2, 1],
          [5],
          [4, 3],
          [7],
          [5],
          [6],
          [7],
          [],
        ],
        priority: [0, 2, 0, 2, 0, 0, 0, 0],
      );
      expect(columns(g), [0, 2, 0, 1, 0, 0, 0, 0]);
    });

    test('a_side_branch_that_merges_back_into_its_branch_docks_to_that_branch_and_is_placed_after_it', () {
      final LayoutInput g = specGraph(
        [
          [1, 2],
          [3],
          [4, 5],
          [6],
          [7],
          [7],
          [8],
          [8],
          [9],
          [],
        ],
        priority: [0, 0, 2, 0, 2, 2, 0, 2, 0, 0],
      );
      expect(columns(g), [0, 0, 1, 0, 1, 2, 0, 1, 0, 0]);
    });

    test('a_side_branch_that_merges_into_the_main_branch_docks_to_it_and_ends_first', () {
      final LayoutInput g = specGraph(
        [
          [1, 2],
          [3, 5],
          [4],
          [6],
          [7],
          [7],
          [8],
          [8],
          [9],
          [],
        ],
        priority: [0, 0, 2, 0, 2, 2, 0, 2, 0, 0],
      );
      expect(columns(g), [0, 0, 2, 0, 2, 1, 0, 2, 0, 0]);
    });

    test('a_column_is_used_again_one_pitch_after_a_merge', () {
      List<List<Object?>> parents(int t1Parent) => [
        [2, 1],
        [t1Parent],
        [3],
        [4, 5],
        [6],
        [7],
        [7],
        [],
      ];
      const priority = [0, 2, 0, 0, 0, 2, 0, 0];
      expect(columns(specGraph(parents(4), priority: priority)), [0, 1, 0, 0, 0, 1, 0, 0]);
      expect(columns(specGraph(parents(6), priority: priority)), [0, 2, 0, 0, 0, 1, 0, 0]);
    });

    test('each_mode_chooses_its_own_columns_on_its_own_rows', () {
      final l = LayoutEngine(xy, LayoutMode.compact)..layering();
      expect(l.modelY[0], [2, 4, 4, 3, 2, 1, 0], reason: 'compact rows');
      // Free walk: R 0; T1, T2, T3 a day apart (gap 20 each); Y one hour after T3 (gap 11, but one
      // pitch above T3: 76); T4 23 h later (gap 20: 96); X six days later (gap 26: 122).
      expect(l.modelY[1], [122, 96, 76, 60, 40, 20, 0], reason: 'free y');
      final GraphGridView c = run(xy, LayoutMode.compact);
      final GraphGridView f = run(xy, LayoutMode.free);
      expect(
        [c.lanes, c.nodeCols, c.nodeLanes],
        [
          2,
          [1, 0, 1, 0, 0, 0, 0],
          [1, 0, 1, 0, 0, 0, 0],
        ],
      );
      expect(
        [f.lanes, f.nodeCols, f.nodeLanes],
        [
          3,
          [2, 0, 1, 0, 0, 0, 0],
          [2, 0, 1, 0, 0, 0, 0],
        ],
      );
      expect(c.nodeDays, f.nodeDays, reason: 'the day keys do not depend on the mode');
    });

    test('a_merge_child_can_sit_in_its_merge_parents_column_and_the_edge_is_straight', () {
      // 0:M2→M1 1:i→[M1, F1] 2:M1→R 3:F1→R 4:R: F1's reservation ends one pitch below i, so i's
      // branch may take F1's column.
      final LayoutInput g = specGraph(
        [
          [2],
          [2, 3],
          [4],
          [4],
          [],
        ],
        priority: [0, 2, 0, 2, 0],
      );
      expect(columns(g), [0, 1, 0, 1, 0]);
      for (final LayoutMode mode in LayoutMode.values) {
        final GraphGridView r = run(g, mode);
        const e = 2; // the edges by child: M1→M2, M1→i, F1→i, R→M1, R→F1
        expect([r.edgeFroms[e], r.edgeTos[e]], [3, 1], reason: mode.name);
        expect([_routeNames[r.edgeRoutes[e]], r.edgeBlocked[e] != 0], ['straight', false], reason: mode.name);
        // Position 1: the second parent of i, so router B has no straight column line for it.
        final classes = RouteClasses.compute(
          nodeRows: r.nodeRows,
          nodeCols: r.nodeCols,
          unit: r.unit,
          free: mode == LayoutMode.free,
          edgeFroms: r.edgeFroms,
          edgeTos: r.edgeTos,
          edgeKinds: r.edgeKinds,
          parentCounts: Int32List.fromList([1, 2, 1, 1, 0]),
        );
        expect(classes.kinds[e], RouteClasses.kindGutter, reason: mode.name);
      }
    });

    test('of_two_parentless_nodes_of_equal_priority_and_row_the_higher_index_is_the_main_branch', () {
      expect(columns(specGraph([[], []])), [1, 0]);
    });

    test('an_empty_input_has_no_rows_and_no_lanes_in_both_modes', () {
      for (final LayoutMode mode in LayoutMode.values) {
        final GraphGridView r = run(specGraph([]), mode);
        expect([r.rows, r.lanes, r.nodeCount], [0, 0, 0], reason: mode.name);
      }
    });

    test('the_same_input_twice_gives_identical_bytes_in_both_modes', () {
      final rnd = Random(17);
      for (var t = 0; t < 150; t++) {
        final LayoutInput g = randomGraph(rnd, 1 + rnd.nextInt(90), branchy: t.isOdd);
        for (final LayoutMode mode in LayoutMode.values) {
          expect(
            computeGraphGrid(g, mode: mode),
            computeGraphGrid(g, mode: mode),
            reason: 'case $t $mode',
          );
        }
      }
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
      expect(
        canonicalOutput(r),
        '{"mode":"free","unit":16,"rows":32,"lanes":1,'
        '"nodes":[{"row":16,"lane":0,"col":0},{"row":0,"lane":0,"col":0}],'
        '"edges":[{"from":1,"to":0,"kind":"direct","route":"straight","blocked":false}],'
        '"buckets":[{"kind":"day","value":999993600000,"start":16,"end":16}]}\n',
      );
      // nodes: 7·16 = 112, then 31·112 = 3472; edge: 31·3472 = 107632; bucket:
      // 31·107632 + 16 + 3·16 = 3336656.
      expect(specDigest(r), 3336656);
    });

    test('an_empty_graph_has_zero_rows_and_lanes_in_every_mode', () {
      for (final LayoutMode mode in LayoutMode.values) {
        expect(
          canonicalOutput(run(specGraph([]), mode)),
          '{"mode":"${mode.name}","unit":${mode == LayoutMode.free ? 16 : 1},'
          '"rows":0,"lanes":0,"nodes":[],"edges":[],"buckets":[]}\n',
        );
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
      Uint8List lay(LayoutInput g) => computeGraphGrid(g, mode: LayoutMode.free);

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
          () => computeGraphGrid(g, mode: LayoutMode.free),
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
    test('i1_to_i6_hold_on_random_graphs_in_every_mode', () {
      final rnd = Random(3);
      for (var t = 0; t < 120; t++) {
        final LayoutInput g = randomGraph(rnd, rnd.nextInt(120), branchy: t.isOdd);
        for (final LayoutMode mode in LayoutMode.values) {
          expect(invariantFailures(g, run(g, mode)), isEmpty, reason: 'case $t $mode');
        }
      }
    });
  });
}
