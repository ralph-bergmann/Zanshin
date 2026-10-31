// SPDX-License-Identifier: MIT

// Commit stacks in the layout engine (Story 4.13, docs/graph-layout.md §4.8), on hand-built inputs:
// the run rule at gaps and breaks, the state rules, the fixed columns of a split run, the rows in
// `compact` and `free`, `free`'s buckets, the output's shape, V5, and `stacks` off as 4.11's grid.
// The graphs list nodes children-first (jj log order), the last node is the root; every
// expectation was derived by hand from §4.8.

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import 'support/spec_json.dart';

const _day = 86400000;
const _minute = 60000;

typedef Graph = ({LayoutInput input, SpecStackFacts facts});

/// [g] laid out with [stacks] (default: the empty request).
GraphGridView grouped(
  Graph g, {
  StackInput? stacks,
  LayoutMode mode = LayoutMode.compact,
  LaneOrder order = LaneOrder.greedy,
}) => GraphGridView.fromBytes(
  computeGraphGrid(
    g.input,
    mode: mode,
    order: order,
    budget: defaultLayoutBudget,
    stacks: stacks ?? specStackRequest(g.facts),
  ),
);

/// [g] laid out without stacks.
GraphGridView ungrouped(Graph g, {LayoutMode mode = LayoutMode.compact, LaneOrder order = LaneOrder.greedy}) =>
    GraphGridView.fromBytes(computeGraphGrid(g.input, mode: mode, order: order, budget: defaultLayoutBudget));

/// The runs of [r]: per run `[members (oldest first), collapsed]`.
List<List<Object>> runs(GraphGridView r) => [
  for (var k = 0; k < r.runCount; k++)
    [
      r.runMembers!.sublist(r.runStarts![k], r.runStarts![k + 1]).toList(),
      r.runStates![k] == GraphGridView.runCollapsed,
    ],
];

/// The grouped edges as (from, to, kind) with kind 0 direct, 1 indirect.
List<(int, int, int)> edgeKinds(GraphGridView r) => [
  for (var e = 0; e < r.edgeCount; e++) (r.edgeFroms[e], r.edgeTos[e], r.edgeKinds[e]),
];

/// A chain of [length] nodes above the root: node i's parent is i + 1, the root last.
List<List<Object?>> chain(int length) => [
  for (var i = 0; i < length; i++) [i + 1],
  <Object?>[],
];

Matcher violates(String rule) => throwsA(isA<LayoutContractException>().having((e) => e.rule, 'rule', rule));

void main() {
  group('the run rule at gaps', () {
    test('a_an_indirect_parent_edge_keeps_b_single_and_c_d_stack_with_a_direct_parent_edge', () {
      // E ← D ← C ← B ⇠ A.
      final Graph g = specStackGraph([
        [1],
        [2],
        [3],
        [const Ind(4)],
        [],
      ]);
      final GraphGridView r = grouped(g);
      expect(runs(r), [
        [
          [2, 1],
          true,
        ],
      ]);
      expect(edgeKinds(r), [(5, 0, 0), (4, 3, 1), (3, 5, 0)], reason: "the stack's parent edge to B is direct");
      expect([r.isHidden(3), r.isHidden(2), r.isHidden(1)], [false, true, true]);
    });

    test('b_two_indirect_edges_of_one_real_parent_and_c_a_missing_edge_make_no_member', () {
      for (final gap in <List<Object?>>[
        [const Ind(4), const Ind(5)],
        [null],
      ]) {
        final Graph g = specStackGraph(
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
        expect(runs(grouped(g)), [
          [
            [2, 1],
            true,
          ],
        ], reason: 'the stack starts one node above the gap: $gap');
      }
    });

    test('d_two_runs_meeting_at_a_gap_are_two_stacks_with_a_single_card_between', () {
      // G ← F ← E ← D ⇠ C ← B ← A: C's one child edge is indirect.
      final Graph g = specStackGraph([
        [1],
        [2],
        [3],
        [const Ind(4)],
        [5],
        [6],
        [],
      ]);
      final GraphGridView r = grouped(g);
      expect(runs(r), [
        [
          [2, 1],
          true,
        ],
        [
          [5, 4],
          true,
        ],
      ]);
      expect(r.isHidden(3), isFalse, reason: 'D, above the gap, is no member');
      // A 0, the lower stack (node 8) 1, D 2, the upper stack (node 7) 3, G 4.
      expect(r.nodeRows, [4, -1, -1, 2, -1, -1, 0, 3, 1]);
    });

    test('e_a_direct_and_an_indirect_child_edge_make_a_fork_and_no_member', () {
      // H ← Y2 ← Y ← X ← W ← R, and Z ⇠ X.
      final Graph g = specStackGraph([
        [2],
        [const Ind(4)],
        [3],
        [4],
        [5],
        [6],
        [],
      ]);
      expect(runs(grouped(g)), [
        [
          [3, 2],
          true,
        ],
      ]);
    });

    test('f_a_collapsed_stack_keeps_the_indirect_kind_of_its_newest_members_child_edge', () {
      final Graph g = specStackGraph([
        [const Ind(1)],
        [2],
        [3],
        [],
      ]);
      expect(edgeKinds(grouped(g)), [(4, 0, 1), (3, 4, 0)]);
    });
  });

  group('run breaks', () {
    test('a_plain_chain_is_one_run_up_to_but_excluding_the_head_and_the_root', () {
      expect(runs(grouped(specStackGraph(chain(8)))), [
        [
          [7, 6, 5, 4, 3, 2, 1],
          true,
        ],
      ]);
    });

    test('a_ref_this_or_another_working_copy_and_a_merge_parent_count_break_a_run_at_the_node', () {
      for (final (String what, Graph g) in [
        ('a bookmark or tag', specStackGraph(chain(8), refs: {4})),
        ("this workspace's @", specStackGraph(chain(8), self: 4)),
        ("another workspace's @", specStackGraph(chain(8), others: {4})),
        ('a merge with one layout parent', specStackGraph(chain(8), counts: {4: 2})),
      ]) {
        expect(
          runs(grouped(g, stacks: specStackRequest(g.facts, collapsed: [3, 7]))),
          [
            [
              [3, 2, 1],
              true,
            ],
            [
              [7, 6, 5],
              true,
            ],
          ],
          reason: what,
        );
      }
    });

    test('a_fork_breaks_a_run_and_the_immutable_boundary_splits_it_in_two', () {
      final Graph forked = specStackGraph([
        [1],
        [2],
        [3],
        [4],
        [6],
        [6],
        [7],
        [8],
        [],
      ]);
      // Node 6 has two children (4 and 5): no member, and 7 links on to nothing; 5 is a head.
      expect(runs(grouped(forked)), [
        [
          [4, 3, 2, 1],
          true,
        ],
      ]);
      final Graph split = specStackGraph(chain(8), immutable: {5, 6, 7, 8});
      expect(runs(grouped(split)), [
        [
          [4, 3, 2, 1],
          true,
        ],
        [
          [7, 6, 5],
          true,
        ],
      ]);
    });
  });

  group('state', () {
    // 0 (@) ← 1 ← 2 ← 3 ← 4 ← 5 (the root, immutable): the run [4, 3, 2, 1].
    final Graph g = specStackGraph(chain(5), self: 0, immutable: {5});
    bool collapsed(StackInput s) => runs(grouped(g, stacks: s)).single[1] as bool;

    test('a_run_of_mutable_ancestors_of_this_workspaces_at_starts_expanded', () {
      expect(collapsed(specStackRequest(g.facts)), isFalse);
      final Graph away = specStackGraph(chain(5), immutable: {5});
      expect(runs(grouped(away)).single[1], isTrue, reason: 'without @ every run starts collapsed');
      final Graph immutableAt = specStackGraph(chain(5), self: 0, immutable: {1, 2, 3, 4, 5});
      expect(runs(grouped(immutableAt)).single[1], isTrue, reason: 'the walk enters mutable parents only');
    });

    test('collapsed_names_the_oldest_member_and_expanded_wins_over_it', () {
      expect(collapsed(specStackRequest(g.facts, collapsed: [4])), isTrue);
      expect(collapsed(specStackRequest(g.facts, expanded: [4], collapsed: [4])), isFalse);
    });

    test('keep_open_on_any_member_wins_over_all', () {
      expect(collapsed(specStackRequest(g.facts, collapsed: [4], keepOpen: [2])), isFalse);
      expect(
        collapsed(specStackRequest(g.facts, collapsed: [4], keepOpen: [0])),
        isTrue,
        reason: '@ is no member',
      );
    });

    test('a_non_oldest_member_or_an_unknown_key_changes_nothing', () {
      final Graph away = specStackGraph(chain(5), immutable: {5});
      bool awayCollapsed(StackInput s) => runs(grouped(away, stacks: s)).single[1] as bool;
      expect(awayCollapsed(specStackRequest(away.facts, expanded: [3])), isTrue, reason: 'EX on a non-oldest member');
      expect(collapsed(specStackRequest(g.facts, collapsed: [3])), isFalse, reason: 'CO on a non-oldest member');
      expect(collapsed(specStackRequest(g.facts, unknown: ['no-such-key'])), isFalse);
      expect(awayCollapsed(specStackRequest(away.facts, unknown: ['no-such-key'])), isTrue);
    });
  });

  group('columns', () {
    // p = 5 with the children m1 = 4 (its continuation: priority 0) and x = 2 (priority 2); the run
    // m1 ← m2 = 3 with one child c0 = 0; c = 1 merges x and p, so p's reservation outlives m1 and
    // m2 cannot continue m1's lane (§4.8 step 4).
    final Graph g = specStackGraph(
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

    test('a_split_run_stacks_in_its_newest_members_column_and_every_other_node_keeps_its_own', () {
      for (final LaneOrder order in LaneOrder.values) {
        final GraphGridView off = ungrouped(g, order: order);
        expect(off.nodeCols[4], isNot(off.nodeCols[3]), reason: 'the run is split (${order.name})');
        final GraphGridView r = grouped(g, order: order);
        expect(runs(r), [
          [
            [4, 3],
            true,
          ],
        ]);
        expect([r.nodeLanes[6], r.nodeCols[6]], [off.nodeLanes[3], off.nodeCols[3]], reason: "m_k's column");
        for (final i in [0, 1, 2, 5]) {
          expect([r.nodeLanes[i], r.nodeCols[i]], [off.nodeLanes[i], off.nodeCols[i]], reason: 'node $i');
        }
        expect(r.lanes, off.lanes, reason: 'lanes is the ungrouped value');
        // The stack sits one row above p, where m1 was; c0 one above it.
        expect([r.nodeRows[6], r.nodeRows[0], r.rows], [1, 2, 3]);
      }
    });

    test('an_expanded_run_keeps_every_column_and_row', () {
      final GraphGridView off = ungrouped(g);
      final GraphGridView r = grouped(g, stacks: specStackRequest(g.facts, expanded: [4]));
      expect([r.nodeRows, r.nodeLanes, r.nodeCols], [off.nodeRows, off.nodeLanes, off.nodeCols]);
      expect(
        [r.edgeFroms, r.edgeTos, r.edgeRoutes, r.edgeBlocked],
        [
          off.edgeFroms,
          off.edgeTos,
          off.edgeRoutes,
          off.edgeBlocked,
        ],
      );
    });
  });

  group('rows', () {
    test('compact_a_stack_sits_one_row_above_its_parent_unless_a_column_constraint_pushes_it', () {
      // Column 0: R ← m1 ← m2 ← m3 ← t ← h0; column 1: R ← u1 ← u2 (a ref) ← u3, and h, t's second
      // child (priority 1), first-fit above u3. Collapsing the run would put t at 2, but h's
      // reservation must start above u3's end: y′(t) ≥ y′(u3) + 1 = 4.
      final Graph g = specStackGraph(
        [
          [2],
          [2],
          [3],
          [4],
          [5],
          [9],
          [7],
          [8],
          [9],
          [],
        ],
        refs: {7},
        priority: [0, 1, 0, 0, 0, 0, 0, 0, 0, 0],
      );
      final GraphGridView off = ungrouped(g);
      expect([off.nodeCols[1], off.nodeCols[6], off.nodeCols[2]], [1, 1, 0], reason: 'h above u3, t in column 0');
      final GraphGridView r = grouped(g);
      expect(runs(r), [
        [
          [5, 4, 3],
          true,
        ],
      ]);
      expect([r.nodeRows[10], r.nodeRows[2], r.nodeRows[0], r.nodeRows[1], r.rows], [1, 4, 5, 5, 6]);

      // Without the u-chain nothing holds t: it drops to 2.
      final Graph free = specStackGraph(
        [
          [2],
          [2],
          [3],
          [4],
          [5],
          [6],
          [],
        ],
        priority: [0, 1, 0, 0, 0, 0, 0],
      );
      final GraphGridView loose = grouped(free);
      expect([loose.nodeRows[7], loose.nodeRows[2], loose.rows], [1, 2, 4]);
    });

    test('free_a_stretched_run_compacts_and_an_unstretched_one_keeps_every_other_y', () {
      // H ← m3 ← m2 ← m1 ← B (a ref) ← R, B a day before m1, the members [delta] apart.
      Graph run(int delta) => specStackGraph(
        chain(5),
        refs: {4},
        ts: [10 * _day + 3 * delta, 10 * _day + 2 * delta, 10 * _day + delta, 10 * _day, 9 * _day, null],
      );
      // A day apart: gap 20 > U = 16, so the walk never stretched the run.
      final GraphGridView dayOff = ungrouped(run(_day), mode: LayoutMode.free);
      final GraphGridView dayOn = grouped(run(_day), mode: LayoutMode.free);
      expect(dayOff.nodeRows, [96, 76, 56, 36, 16, 0]);
      expect(dayOn.nodeRows, [96, -1, -1, -1, 16, 0, 76], reason: 'the stack at y(m_k), H unchanged');
      // A minute apart: gap 2 < 16, one pitch per commit; collapsing pulls H down.
      final GraphGridView minuteOff = ungrouped(run(_minute), mode: LayoutMode.free);
      final GraphGridView minuteOn = grouped(run(_minute), mode: LayoutMode.free);
      // The stack: max(B + 16, B + X(m3) − X(B)) = max(32, 16 + 20 + 2 + 2) = 40; H: 40 + 16 = 56.
      expect(minuteOff.nodeRows, [84, 68, 52, 36, 16, 0]);
      expect(minuteOn.nodeRows, [56, -1, -1, -1, 16, 0, 40]);
      expect([minuteOn.rows, minuteOff.rows], [72, 100]);
    });

    test('free_buckets_hold_the_visible_non_root_nodes_and_the_stack_in_its_newest_members_day', () {
      final Graph g = specStackGraph(
        chain(5),
        refs: {4},
        ts: [14 * _day, 13 * _day, 12 * _day, 11 * _day, 10 * _day, null],
      );
      final GraphGridView r = grouped(g, mode: LayoutMode.free);
      expect(r.bucketValues, [10 * _day, 13 * _day, 14 * _day], reason: "B's, the stack's (m3's), H's");
      expect(
        [r.bucketStarts, r.bucketEnds],
        [
          [16, 76, 96],
          [16, 76, 96],
        ],
      );
      expect(r.nodeRows[6], 76);
    });

    test('free_a_run_across_midnight_keeps_the_day_band_collapsed_expanded_or_by_default', () {
      // Story 4.16: X 00:10 → R in its own column; m3 00:20 ← m2 23:50 ← m1 23:40 ← B (a ref) 20:00 ← R.
      const int midnight = 10 * _day;
      final Graph g = specStackGraph(
        [
          [5],
          [2],
          [3],
          [4],
          [5],
          [],
        ],
        refs: {4},
        ts: [
          midnight + 10 * _minute,
          midnight + 20 * _minute,
          midnight - 10 * _minute,
          midnight - 20 * _minute,
          midnight - 4 * 60 * _minute,
          null,
        ],
      );
      final GraphGridView off = ungrouped(g, mode: LayoutMode.free);
      final GraphGridView collapsed = grouped(
        g,
        stacks: specStackRequest(g.facts, collapsed: [1, 2, 3]),
        mode: LayoutMode.free,
      );
      final GraphGridView expanded = grouped(
        g,
        stacks: specStackRequest(g.facts, expanded: [1, 2, 3]),
        mode: LayoutMode.free,
      );
      expect(runs(collapsed), isNotEmpty);
      for (final (String name, GraphGridView r) in [
        ('none', off),
        ('default', grouped(g, mode: LayoutMode.free)),
        ('collapsed', collapsed),
        ('expanded', expanded),
      ]) {
        expect(r.bucketCount, 2, reason: name);
        expect(r.bucketEnds[0] + 16, lessThanOrEqualTo(r.bucketStarts[1]), reason: '$name: a pitch apart');
      }
      expect(expanded.nodeRows.sublist(0, 6), off.nodeRows, reason: 'all expanded = ungrouped');
    });
  });

  group('a stack as an edge endpoint', () {
    /// The grouped edges as (from, to, kind, route, blocked); kind 0 direct, route 0 straight,
    /// 1 merge, 2 branch_off.
    List<(int, int, int, int, bool)> routed(GraphGridView r) => [
      for (var e = 0; e < r.edgeCount; e++)
        (r.edgeFroms[e], r.edgeTos[e], r.edgeKinds[e], r.edgeRoutes[e], r.edgeBlocked[e] != 0),
    ];

    test('a_collapsed_run_under_another_gives_a_stack_to_stack_edge', () {
      // 0 ← 1 ← … ← 7 ← 8 (root), 5–8 immutable: the runs [4, 3, 2, 1] (stack 9) and [7, 6, 5]
      // (stack 10). Stack 9's parent is fp(4) = 5, hidden behind stack 10: the edge 10 → 9. One
      // lane, one segment: R 0, stack 10 at 1, stack 9 at 2, node 0 at 3.
      final Graph g = specStackGraph(chain(8), immutable: {5, 6, 7, 8});
      final GraphGridView r = grouped(g);
      expect(runs(r), [
        [
          [4, 3, 2, 1],
          true,
        ],
        [
          [7, 6, 5],
          true,
        ],
      ]);
      expect(routed(r), [(9, 0, 0, 0, false), (10, 9, 0, 0, false), (8, 10, 0, 0, false)]);
      expect(r.nodeRows, [3, -1, -1, -1, -1, -1, -1, -1, 0, 2, 1]);
      expect(r.rows, 4);
    });

    test('a_run_whose_newest_member_is_its_childs_second_parent_reserves_the_merge_column', () {
      // Lane 0: R ← q1 ← q2 (a ref) ← q3 ← c ← d, c = merge(q3, m2); lane 1: R ← m1 ← m2 (the run,
      // stack 16), then h, t's second child, first-fit above m2 (a = y(t) + 1 = 6 ≥ m2's end 5);
      // lane 2: R ← u1 ← … ← u4 (the run, stack 15) ← t ← h0.
      // Grouped: in lane 1 the stack (1) and h are two segments, h's first parent is t, so (C)
      // gives y′(t) ≥ y′(16) + 1 = 2 and, for the merge 16 → c (pos 1), y′(t) ≥ y′(c) = 4. So t
      // stays at 4 (the stack below would put it at 2) and h, h0 at 5: the merge's vertical up
      // lane 1 to c keeps clear of h.
      final Graph g = specStackGraph(
        [
          [2],
          [2],
          [3],
          [4],
          [5],
          [6],
          [14],
          [8],
          [9, 12],
          [10],
          [11],
          [14],
          [13],
          [14],
          [],
        ],
        refs: {10},
        priority: [2, 0, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 1, 1, 0],
      );
      final GraphGridView off = ungrouped(g);
      expect([off.nodeCols[0], off.nodeCols[12], off.nodeCols[2], off.nodeCols[8]], [1, 1, 2, 0]);
      final GraphGridView r = grouped(g);
      expect(runs(r), [
        [
          [6, 5, 4, 3],
          true,
        ],
        [
          [13, 12],
          true,
        ],
      ]);
      expect(r.nodeRows, [5, 5, 4, -1, -1, -1, -1, 5, 4, 3, 2, 1, -1, -1, 0, 1, 1]);
      expect(routed(r), [
        (2, 0, 0, 2, true),
        (2, 1, 0, 0, false),
        (15, 2, 0, 0, false),
        (8, 7, 0, 0, false),
        (9, 8, 0, 0, false),
        (16, 8, 0, 1, false),
        (10, 9, 0, 0, false),
        (11, 10, 0, 0, false),
        (14, 11, 0, 0, false),
        (14, 15, 0, 2, true),
        (14, 16, 0, 2, true),
      ]);
      expect([r.rows, off.rows], [6, 7]);
    });
  });

  group('output', () {
    test('stack_nodes_follow_the_n_nodes_in_run_order_and_runs_are_ordered_by_newest_member', () {
      // Two chains on one root: 0 ← 1 ← 2 ← 3 ← 8 and 4 ← 5 ← 6 ← 7 ← 8.
      final Graph g = specStackGraph([
        [1],
        [2],
        [3],
        [8],
        [5],
        [6],
        [7],
        [8],
        [],
      ]);
      final GraphGridView r = grouped(g);
      expect([r.nodeCount, r.stackCount, r.runCount, r.nodeRows.length], [9, 2, 2, 11]);
      expect(runs(r), [
        [
          [3, 2, 1],
          true,
        ],
        [
          [7, 6, 5],
          true,
        ],
      ]);
      expect(r.runNodes, [9, 10]);
      expect(r.nodeRuns, [-1, 0, 0, 0, -1, 1, 1, 1, -1]);
      expect(
        [for (var i = 0; i < 9; i++) r.nodeRows[i] < 0],
        [false, true, true, true, false, true, true, true, false],
      );
      expect(edgeKinds(r), [(9, 0, 0), (10, 4, 0), (8, 9, 0), (8, 10, 0)], reason: 'edges reference the stack nodes');
      expect(
        canonicalOutput(r),
        endsWith(
          '"runs":[{"members":[3,2,1],"state":"collapsed","node":9},{"members":[7,6,5],"state":"collapsed","node":10}]}\n',
        ),
      );
    });

    test('the_spec_3_example_is_the_engines_output', () {
      // docs/graph-layout.md §3 (amended 2026-10-01).
      final Graph g = specStackGraph(chain(3));
      expect(
        canonicalOutput(grouped(g)),
        '{"mode":"compact","order":"greedy","unit":1,"rows":3,"lanes":1,"nodes":[{"row":2,"lane":0,"col":0},null,null,'
        '{"row":0,"lane":0,"col":0},{"row":1,"lane":0,"col":0}],"edges":[{"from":4,"to":0,"kind":"direct",'
        '"route":"straight","blocked":false},{"from":3,"to":4,"kind":"direct","route":"straight","blocked":false}],'
        '"buckets":[],"runs":[{"members":[2,1],"state":"collapsed","node":4}]}\n',
      );
    });

    test('an_empty_graph_with_stacks_has_no_runs', () {
      final GraphGridView r = grouped(specStackGraph(const []));
      expect([r.hasStacks, r.nodeCount, r.runCount, r.rows, r.lanes, r.edgeCount], [true, 0, 0, 0, 0, 0]);
    });
  });

  group('stacks off', () {
    test('without_a_stack_request_the_grid_is_4_11s_version_1_buffer_byte_for_byte', () {
      final Graph g = specStackGraph(chain(6), self: 0);
      final LayoutInput plain = specGraph(chain(6), roots: {6});
      for (final LayoutMode mode in LayoutMode.values) {
        for (final LaneOrder order in LaneOrder.values) {
          final Uint8List off = computeGraphGrid(g.input, mode: mode, order: order, budget: defaultLayoutBudget);
          expect(ByteData.sublistView(off).getInt32(0, Endian.little), GraphGridView.formatVersion);
          expect(off, computeGraphGrid(plain, mode: mode, order: order, budget: defaultLayoutBudget));
          expect(GraphGridView.fromBytes(off).hasStacks, isFalse);
        }
      }
    });
  });

  group('V5', () {
    final Graph g = specStackGraph(chain(3));
    final StackInput ok = specStackRequest(g.facts);
    StackInput altered({
      Uint8List? immutable,
      Int32List? parentCount,
      Uint8List? hasRef,
      Uint8List? workingCopy,
      Int32List? expanded,
    }) => StackInput(
      immutable: immutable ?? ok.immutable,
      parentCount: parentCount ?? ok.parentCount,
      hasRef: hasRef ?? ok.hasRef,
      workingCopy: workingCopy ?? ok.workingCopy,
      expandedNodes: expanded ?? ok.expandedNodes,
      collapsedNodes: ok.collapsedNodes,
      keepOpenNodes: ok.keepOpenNodes,
    );
    Uint8List layOut(StackInput s) =>
        computeGraphGrid(g.input, mode: LayoutMode.compact, order: LaneOrder.greedy, budget: 0, stacks: s);

    test('fact_arrays_of_the_wrong_length_violate_v5', () {
      expect(() => layOut(altered(immutable: Uint8List(3))), violates('V5'));
      expect(() => layOut(altered(parentCount: Int32List(5))), violates('V5'));
      expect(() => layOut(altered(hasRef: Uint8List(0))), violates('V5'));
      expect(() => layOut(altered(workingCopy: Uint8List(2))), violates('V5'));
    });

    test('a_bad_working_copy_code_two_this_and_a_negative_parent_count_violate_v5', () {
      expect(() => layOut(altered(workingCopy: Uint8List.fromList([3, 0, 0, 0]))), violates('V5'));
      expect(
        () => layOut(altered(workingCopy: Uint8List.fromList([workingCopyThis, 0, workingCopyThis, 0]))),
        violates('V5'),
      );
      expect(() => layOut(altered(parentCount: Int32List.fromList([1, -1, 1, 0]))), violates('V5'));
    });

    test('a_request_index_outside_the_nodes_violates_v5', () {
      expect(() => layOut(altered(expanded: Int32List.fromList([4]))), violates('V5'));
      expect(() => layOut(altered(expanded: Int32List.fromList([-1]))), violates('V5'));
      expect(layOut(altered(expanded: Int32List.fromList([3]))), isNotEmpty, reason: 'n − 1 is in range');
    });

    test('v1_to_v4_come_before_v5', () {
      final bad = LayoutInput(
        utcOffsetMin: 2000,
        ts: Int64List(4),
        hasTs: Uint8List(4),
        isRoot: Uint8List(4),
        priority: Int32List(4),
        parStart: Int32List(5),
        parIdx: Int32List(0),
        parKind: Uint8List(0),
      );
      expect(
        () => computeGraphGrid(
          bad,
          mode: LayoutMode.compact,
          order: LaneOrder.greedy,
          budget: 0,
          stacks: altered(immutable: Uint8List(1)),
        ),
        violates('V4'),
      );
    });
  });

  group('JSON layer', () {
    Map<String, Object?> node(int i, {Map<String, Object?> extra = const {}}) => {
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
    Uint8List doc(List<Map<String, Object?>> nodes) =>
        utf8.encode(jsonEncode({'now_ms': 0, 'utc_offset_min': 0, 'nodes': nodes}));
    final Matcher refused = throwsA(isA<SpecInputError>());

    test('with_stacks_every_fact_is_required_typed_and_keys_are_distinct', () {
      expect(parseSpecInput(doc([node(0), node(1)]), stacks: true).facts, isNotNull);
      for (final field in ['key', 'immutable', 'parent_count', 'has_ref', 'working_copy']) {
        final Map<String, Object?> lacking = node(0)..remove(field);
        expect(() => parseSpecInput(doc([lacking, node(1)]), stacks: true), refused, reason: 'no $field');
      }
      expect(
        () => parseSpecInput(
          doc([
            node(0, extra: {'key': 'n1'}),
            node(1),
          ]),
          stacks: true,
        ),
        refused,
      );
      expect(
        () => parseSpecInput(
          doc([
            node(0, extra: {'immutable': 1}),
            node(1),
          ]),
          stacks: true,
        ),
        refused,
      );
      expect(
        () => parseSpecInput(
          doc([
            node(0, extra: {'parent_count': -1}),
            node(1),
          ]),
          stacks: true,
        ),
        refused,
      );
      expect(
        () => parseSpecInput(
          doc([
            node(0, extra: {'working_copy': 'both'}),
            node(1),
          ]),
          stacks: true,
        ),
        refused,
      );
      expect(
        () => parseSpecInput(
          doc([
            node(0, extra: {'working_copy': 'this'}),
            node(1, extra: {'working_copy': 'this'}),
          ]),
          stacks: true,
        ),
        refused,
        reason: 'two "this"',
      );
      expect(parseSpecInput(doc([node(0)..remove('key'), node(1)])).facts, isNull, reason: 'ignored without stacks');
    });

    test('a_malformed_request_file_is_refused_and_unknown_keys_are_dropped', () {
      final SpecStackFacts facts = parseSpecInput(doc([node(0), node(1)]), stacks: true).facts!;
      Uint8List request(Object body) => utf8.encode(jsonEncode(body));
      expect(() => parseSpecStackRequest(utf8.encode('{'), facts), refused);
      expect(() => parseSpecStackRequest(request([]), facts), refused);
      expect(() => parseSpecStackRequest(request({'expanded': [], 'collapsed': []}), facts), refused);
      expect(
        () => parseSpecStackRequest(
          request({
            'expanded': [1],
            'collapsed': [],
            'keep_open': [],
          }),
          facts,
        ),
        refused,
      );
      final StackInput s = parseSpecStackRequest(
        request({
          'expanded': ['n1', 'zz'],
          'collapsed': ['n0'],
          'keep_open': [],
        }),
        facts,
      );
      expect(
        [s.expandedNodes, s.collapsedNodes, s.keepOpenNodes],
        [
          [1],
          [0],
          isEmpty,
        ],
      );
    });
  });
}
