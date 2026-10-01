// SPDX-License-Identifier: MIT

// The product engine against the committed goldens (Story 4.11), which tools/goldens.mjs writes
// from the spike's two references (greedy: Rust; the `compact` order: the spike's Dart) and from
// the design's own computeLayout: every output byte for byte in docs/graph-layout.md §3's
// canonical form, the fuzz cases by FNV-1a 64 hash and byte length. Story 4.13 adds the stacks
// (§4.8): the spike Dart's outputs, the design's own groupStacks runs, the hand-derived compaction.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import 'support/spec_json.dart';

const _goldens = 'test/graph_layout/goldens';

/// The golden file at [path] (relative to the goldens directory), as bytes.
Uint8List golden(String path) => File('$_goldens/$path').readAsBytesSync();

/// The engine's §3 canonical output for the §2 input [bytes], with [budget] as the `compact` order's
/// search budget.
String layOut(Uint8List bytes, LayoutMode mode, LaneOrder order, {int budget = defaultLayoutBudget}) {
  final LayoutInput input = parseSpecInput(bytes).input;
  return canonicalOutput(GraphGridView.fromBytes(computeGraphGrid(input, mode: mode, order: order, budget: budget)));
}

/// The grouped grid (Story 4.13) of [input] with the stack request [stacks].
GraphGridView stackGrid(LayoutInput input, StackInput stacks, LayoutMode mode, LaneOrder order) =>
    GraphGridView.fromBytes(
      computeGraphGrid(input, mode: mode, order: order, budget: defaultLayoutBudget, stacks: stacks),
    );

/// The engine's §3 canonical output with stacks for the §2 input [bytes] (with stack facts) and the
/// stack request file [request].
String layOutStacks(Uint8List bytes, Uint8List request, LayoutMode mode, LaneOrder order) {
  final ({LayoutInput input, int nowMs, SpecStackFacts? facts}) parsed = parseSpecInput(bytes, stacks: true);
  return canonicalOutput(stackGrid(parsed.input, parseSpecStackRequest(request, parsed.facts!), mode, order));
}

void main() {
  group('design sample', () {
    for (final rev in ['default', 'all']) {
      test('design_${rev}_compact_greedy_equals_the_designs_own_compute_layout', () {
        expect(
          layOut(golden('design/design-$rev.json'), LayoutMode.compact, LaneOrder.greedy),
          utf8.decode(golden('design/oracle/design-$rev.compact.greedy.json')),
        );
      });

      for (final LayoutMode mode in LayoutMode.values) {
        for (final LaneOrder order in LaneOrder.values) {
          test('design_${rev}_${mode.name}_${order.name}_equals_the_reference', () {
            expect(
              layOut(golden('design/design-$rev.json'), mode, order),
              utf8.decode(golden('design/design-$rev.${mode.name}.${order.name}.json')),
            );
          });
        }
      }
    }

    test('design_free_greedy_has_spec_7_2s_rows_and_4_lanes', () {
      for (final (String rev, int rows) in const [('default', 209), ('all', 377)]) {
        final LayoutInput input = parseSpecInput(golden('design/design-$rev.json')).input;
        final grid = GraphGridView.fromBytes(
          computeGraphGrid(input, mode: LayoutMode.free, order: LaneOrder.greedy, budget: defaultLayoutBudget),
        );
        expect([grid.rows, grid.lanes], [rows, 4], reason: rev);
      }
    });

    // The `compact` order at a budget that stops its search mid-way (goldens README): the cut
    // output is the reference's at the same budget, and differs from the default budget's.
    for (final (String name, LayoutMode mode, int budget) in const [
      ('design-all', LayoutMode.compact, 20),
      ('design-all', LayoutMode.free, 90),
      ('design-default', LayoutMode.free, 40),
    ]) {
      test('${name}_${mode.name}_compact_at_budget_${budget}_equals_the_cut_reference', () {
        final String cut = layOut(golden('design/$name.json'), mode, LaneOrder.compact, budget: budget);
        expect(cut, utf8.decode(golden('design/$name.${mode.name}.compact.budget-$budget.json')));
        expect(cut, isNot(utf8.decode(golden('design/$name.${mode.name}.compact.json'))), reason: 'the budget cut');
      });
    }
  });

  group('fixture dumps', () {
    for (final name in ['tiny-all', 'medium-narrow']) {
      for (final LayoutMode mode in LayoutMode.values) {
        for (final LaneOrder order in LaneOrder.values) {
          test('${name}_${mode.name}_${order.name}_equals_the_reference', () {
            expect(
              layOut(golden('fixtures/$name.input.json'), mode, order),
              utf8.decode(golden('fixtures/$name.${mode.name}.${order.name}.json')),
            );
          });
        }
      }
    }
  });

  test('every_seeded_fuzz_case_hashes_to_its_golden_in_every_mode_and_order', () {
    final List<String> cases = const LineSplitter().convert(utf8.decode(golden('fuzz/cases.jsonl')));
    final expected =
        (jsonDecode(utf8.decode(golden('fuzz/expected.json'))) as Map<String, Object?>)['cases']! as List<Object?>;
    expect(cases, hasLength(expected.length));
    expect(cases.length, greaterThanOrEqualTo(100));
    for (var c = 0; c < cases.length; c++) {
      final Uint8List input = utf8.encode('${cases[c]}\n');
      final want = expected[c]! as Map<String, Object?>;
      for (final LayoutMode mode in LayoutMode.values) {
        for (final LaneOrder order in LaneOrder.values) {
          final Uint8List out = utf8.encode(layOut(input, mode, order));
          final digest = want['${mode.name}.${order.name}']! as Map<String, Object?>;
          expect(
            [fnv1a64Hex(out), out.length],
            [digest['fnv1a64'], digest['bytes']],
            reason: 'case $c ${mode.name} ${order.name}',
          );
        }
      }
    }
  });

  // Story 4.13, docs/graph-layout.md §4.8: every stack golden comes from the spike's Dart binary.
  group('stacks', () {
    for (final rev in ['default', 'all']) {
      for (final state in ['default', 'expanded', 'mixed']) {
        for (final LayoutMode mode in LayoutMode.values) {
          for (final LaneOrder order in LaneOrder.values) {
            test('stacks_design_${rev}_${state}_${mode.name}_${order.name}_equals_the_spike_reference', () {
              expect(
                layOutStacks(golden('stacks/design-$rev.json'), golden('stacks/request-$state.json'), mode, order),
                utf8.decode(golden('stacks/design-$rev.$state.${mode.name}.${order.name}.json')),
              );
            });
          }
        }
      }

      test('stacks_design_${rev}_runs_equal_the_designs_group_stacks', () {
        final oracle = jsonDecode(utf8.decode(golden('stacks/oracle/design-$rev.runs.json'))) as Map<String, Object?>;
        final ({LayoutInput input, int nowMs, SpecStackFacts? facts}) parsed = parseSpecInput(
          golden('stacks/design-$rev.json'),
          stacks: true,
        );
        final GraphGridView grid = stackGrid(
          parsed.input,
          parseSpecStackRequest(golden('stacks/request-default.json'), parsed.facts!),
          LayoutMode.compact,
          LaneOrder.greedy,
        );
        final List<Map<String, Object>> runs = [
          for (var k = 0; k < grid.runCount; k++)
            {
              'key': parsed.facts!.keys[grid.runMembers![grid.runStarts![k]]],
              'members': grid.runMembers!.sublist(grid.runStarts![k], grid.runStarts![k + 1]),
            },
        ];
        expect(runs, oracle['runs']);
        expect(runs, hasLength(rev == 'default' ? 6 : 7));
      });
    }

    // docs/graph-layout.md §4.8 "The design sample, by hand": compact, greedy, every run collapsed.
    test('stacks_design_compact_greedy_rows_shrink_by_the_hand_derived_counts', () {
      for (final (String rev, int before, int after) in const [('all', 19, 15), ('default', 9, 8)]) {
        final ({LayoutInput input, int nowMs, SpecStackFacts? facts}) parsed = parseSpecInput(
          golden('stacks/design-$rev.json'),
          stacks: true,
        );
        final off = GraphGridView.fromBytes(
          computeGraphGrid(
            parsed.input,
            mode: LayoutMode.compact,
            order: LaneOrder.greedy,
            budget: defaultLayoutBudget,
          ),
        );
        final GraphGridView grouped = stackGrid(
          parsed.input,
          parseSpecStackRequest(golden('stacks/request-default.json'), parsed.facts!),
          LayoutMode.compact,
          LaneOrder.greedy,
        );
        expect([off.rows, grouped.rows], [before, after], reason: rev);
        expect(grouped.stackCount, grouped.runCount, reason: '$rev: every run collapsed');
      }
    });

    test('every_seeded_stack_fuzz_case_hashes_to_its_golden_in_every_mode_and_order', () {
      final List<String> cases = const LineSplitter().convert(utf8.decode(golden('stacks/fuzz/cases.jsonl')));
      final expected =
          (jsonDecode(utf8.decode(golden('stacks/fuzz/expected.json'))) as Map<String, Object?>)['cases']!
              as List<Object?>;
      expect(cases, hasLength(expected.length));
      expect(cases.length, greaterThanOrEqualTo(60));
      for (var c = 0; c < cases.length; c++) {
        final line = jsonDecode(cases[c]) as Map<String, Object?>;
        final Uint8List input = utf8.encode('${jsonEncode(line['input'])}\n');
        final Uint8List request = utf8.encode('${jsonEncode(line['request'])}\n');
        final want = expected[c]! as Map<String, Object?>;
        for (final LayoutMode mode in LayoutMode.values) {
          for (final LaneOrder order in LaneOrder.values) {
            final Uint8List out = utf8.encode(layOutStacks(input, request, mode, order));
            final digest = want['${mode.name}.${order.name}']! as Map<String, Object?>;
            expect(
              [fnv1a64Hex(out), out.length],
              [digest['fnv1a64'], digest['bytes']],
              reason: 'stack case $c ${mode.name} ${order.name}',
            );
          }
        }
      }
    });
  });

  test('the_goldens_hash_is_fnv_1a_64', () {
    // Reference values of FNV-1a 64 (offset basis and the hash of "a").
    expect(fnv1a64Hex(const []), 'cbf29ce484222325');
    expect(fnv1a64Hex(utf8.encode('a')), 'af63dc4c8601ec8c');
  });
}
