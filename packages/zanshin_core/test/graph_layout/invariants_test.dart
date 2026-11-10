// SPDX-License-Identifier: MIT

// docs/graph-layout.md §7.3's invariants I1–I6 (I5 as amended on 2026-10-01, I2–I4 restated on
// 2026-11-10) and the branch columns read literally (§4.3), over seeded random DAGs and over every
// committed golden input, in both modes.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/input_builder.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import 'invariants.dart';
import 'support/spec_json.dart';
import 'support/topology_envelope.dart';

/// Lays [g] out in [mode].
GraphGridView run(LayoutInput g, LayoutMode mode) => GraphGridView.fromBytes(computeGraphGrid(g, mode: mode));

/// Every invariant of [g] and the literal branch columns, in both modes.
void checkAll(LayoutInput g, String what) {
  final List<int> cont = naiveContinuations(g, layoutParents(g));
  for (final LayoutMode mode in LayoutMode.values) {
    final GraphGridView r = run(g, mode);
    expect(invariantFailures(g, r), isEmpty, reason: '$what ${mode.name}');
    expect(branchFailures(g, r), isEmpty, reason: '$what ${mode.name}: branches');
    expect(r.nodeCols, naiveBranchColumns(g, r.nodeRows, r.unit, cont), reason: '$what ${mode.name}: columns');
  }
}

void main() {
  test('invariants_and_branch_columns_hold_on_1000_seeded_random_dags_in_both_modes', () {
    final rnd = Random(4011);
    for (var t = 0; t < 1000; t++) {
      // Every third graph is branchy (more branches, so the column choice has work); a few are larger.
      final int n = t % 50 == 0 ? 200 + rnd.nextInt(200) : rnd.nextInt(120);
      checkAll(randomGraph(rnd, n, branchy: t % 3 == 0), 'case $t');
    }
  });

  test('repeated_targets_through_the_input_builder_follow_the_rule_and_keep_the_invariants', () {
    // Engine inputs cannot carry repeated targets (V3), so these 250 seeded topologies go through
    // the input builder, as jj-lib's edges do.
    final rnd = Random(4111);
    var repeated = 0;
    for (var t = 0; t < 250; t++) {
      final (:Uint8List envelope, :List<List<(int, fbs.GraphEdgeKind)>> edges) = randomTopology(
        rnd,
        1 + rnd.nextInt(80),
      );
      final LayoutInput input = buildLayoutInput(
        GraphTopologyView.fromEnvelope(envelope),
        utcOffsetMin: rnd.nextInt(2881) - 1440,
      );
      for (var i = 0; i < edges.length; i++) {
        expect(parentsOf(input, i), naiveRepeatedTargets(edges[i]), reason: 'case $t node $i');
        final Iterable<int> targets = edges[i].where((e) => e.$2 != fbs.GraphEdgeKind.Missing).map((e) => e.$1);
        if (targets.toSet().length < targets.length) {
          repeated++;
        }
      }
      checkAll(input, 'case $t');
    }
    expect(repeated, greaterThan(200), reason: 'too few nodes with repeated targets');
  });

  test('invariants_and_branch_columns_hold_on_every_golden_input', () {
    const goldens = 'test/graph_layout/goldens';
    for (final path in [
      'design/design-default.json',
      'design/design-all.json',
      'fixtures/tiny-all.input.json',
      'fixtures/medium-narrow.input.json',
      'stacks/design-default.json',
      'stacks/design-all.json',
    ]) {
      checkAll(parseSpecInput(File('$goldens/$path').readAsBytesSync()).input, path);
    }
    final List<String> cases = File('$goldens/fuzz/cases.jsonl').readAsLinesSync();
    for (var c = 0; c < cases.length; c++) {
      checkAll(parseSpecInput(utf8.encode(cases[c])).input, 'fuzz case $c');
    }
    final List<String> stackCases = File('$goldens/stacks/fuzz/cases.jsonl').readAsLinesSync();
    for (var c = 0; c < stackCases.length; c++) {
      final Object? input = (jsonDecode(stackCases[c]) as Map<String, Object?>)['input'];
      checkAll(parseSpecInput(utf8.encode(jsonEncode(input))).input, 'stack fuzz case $c');
    }
  });
}
