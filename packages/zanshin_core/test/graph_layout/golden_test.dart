// SPDX-License-Identifier: MIT

// The product engine against the committed goldens (Story 4.11), which tools/goldens.mjs writes
// from the spike's two references (greedy: Rust; the `compact` order: the spike's Dart) and from
// the design's own computeLayout: every output byte for byte in docs/graph-layout.md §3's
// canonical form, the fuzz cases by FNV-1a 64 hash and byte length.

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

  test('the_goldens_hash_is_fnv_1a_64', () {
    // Reference values of FNV-1a 64 (offset basis and the hash of "a").
    expect(fnv1a64Hex(const []), 'cbf29ce484222325');
    expect(fnv1a64Hex(utf8.encode('a')), 'af63dc4c8601ec8c');
  });
}
