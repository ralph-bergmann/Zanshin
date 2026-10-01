// SPDX-License-Identifier: MIT

// The stack invariants (Story 4.13, docs/graph-layout.md §4.8 and §7.3 as amended) over at least
// 1,000 seeded stack-shaped DAGs × both modes × both orders × the stack states all collapsed, all
// expanded, the default and random subsets — and over every stack golden input with its requests.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import 'stack_invariants.dart';
import 'support/spec_json.dart';

const _goldens = 'test/graph_layout/goldens/stacks';

GraphGridView _grid(LayoutInput g, LayoutMode mode, LaneOrder order, [StackInput? stacks]) => GraphGridView.fromBytes(
  computeGraphGrid(g, mode: mode, order: order, budget: defaultLayoutBudget, stacks: stacks),
);

/// Checks [g] with every request of [requests] in every mode and order; returns the failures.
List<String> _checkAll(LayoutInput g, Map<String, StackInput> requests, String what) {
  final fails = <String>[];
  for (final LayoutMode mode in LayoutMode.values) {
    for (final LaneOrder order in LaneOrder.values) {
      final GraphGridView off = _grid(g, mode, order);
      for (final MapEntry(key: String state, value: StackInput s) in requests.entries) {
        for (final String f in stackInvariantFailures(g, s, off, _grid(g, mode, order, s))) {
          fails.add('$what ${mode.name} ${order.name} $state: $f');
        }
      }
    }
  }
  return fails;
}

void main() {
  test('stack_invariants_hold_on_1000_seeded_dags_in_every_state_mode_and_order', () {
    final rnd = Random(413);
    final fails = <String>[];
    var splits = 0;
    var runs = 0;
    for (var t = 0; t < 1000; t++) {
      final ({LayoutInput input, SpecStackFacts facts}) g = randomStackGraph(
        rnd,
        rnd.nextInt(56),
        split: rnd.nextInt(3) == 0,
      );
      final int n = g.input.n;
      final List<int> all = List.generate(n, (i) => i);
      List<int> some(int oneIn) => [
        for (var i = 0; i < n; i++)
          if (rnd.nextInt(oneIn) == 0) i,
      ];
      final requests = <String, StackInput>{
        'collapsed': specStackRequest(g.facts, collapsed: all),
        'expanded': specStackRequest(g.facts, keepOpen: all),
        'default': specStackRequest(g.facts),
        'random': specStackRequest(g.facts, expanded: some(4), collapsed: some(3), keepOpen: some(8)),
      };
      fails.addAll(_checkAll(g.input, requests, 'case $t'));
      final StackInput s = requests['default']!;
      runs += naiveRuns(g.input, s).length;
      splits += splitRuns(g.input, s, _grid(g.input, LayoutMode.compact, LaneOrder.greedy));
      if (fails.length >= 10) {
        break;
      }
    }
    expect(fails, isEmpty);
    expect(runs, greaterThan(1000), reason: 'the generator makes runs');
    expect(splits, greaterThanOrEqualTo(20), reason: 'the split-run shape occurs (compact, greedy)');
  });

  test('every_stack_golden_input_keeps_the_stack_invariants_under_its_requests', () {
    final fails = <String>[];
    for (final rev in ['default', 'all']) {
      final ({LayoutInput input, int nowMs, SpecStackFacts? facts}) parsed = parseSpecInput(
        File('$_goldens/design-$rev.json').readAsBytesSync(),
        stacks: true,
      );
      final requests = <String, StackInput>{
        for (final state in ['default', 'expanded', 'mixed'])
          state: parseSpecStackRequest(File('$_goldens/request-$state.json').readAsBytesSync(), parsed.facts!),
      };
      fails.addAll(_checkAll(parsed.input, requests, 'design-$rev'));
    }
    final List<String> cases = const LineSplitter().convert(File('$_goldens/fuzz/cases.jsonl').readAsStringSync());
    for (var c = 0; c < cases.length; c++) {
      final line = jsonDecode(cases[c]) as Map<String, Object?>;
      final ({LayoutInput input, int nowMs, SpecStackFacts? facts}) parsed = parseSpecInput(
        utf8.encode(jsonEncode(line['input'])),
        stacks: true,
      );
      final Uint8List request = utf8.encode(jsonEncode(line['request']));
      fails.addAll(
        _checkAll(parsed.input, {'request': parseSpecStackRequest(request, parsed.facts!)}, 'stack case $c'),
      );
    }
    expect(fails, isEmpty);
  });
}
