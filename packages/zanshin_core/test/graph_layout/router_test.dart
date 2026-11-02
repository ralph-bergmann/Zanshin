// SPDX-License-Identifier: MIT

// Story 4.15: line router B (docs/graph-layout.md §14) — the class stage's kinds, gutters, the
// unit rule, shared entries and reports; the geometry stage's exits, entries, tracks and bridges;
// stability across card sizes; and the route gate over the recording inputs (no line behind a card
// in Compact; in Free only reported cases).

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';
import 'package:zanshin_core/src/graph_layout/router.dart';
import 'package:zanshin_core/zanshin_core.dart' as barrel;

import 'invariants.dart';
import 'support/router_scan.dart';
import 'support/spec_json.dart';

const _goldens = 'test/graph_layout/goldens';

/// A hand-built grid: per node its row and column, the edges as (parent, child) in §3's order.
RouteClasses _grid(
  List<int> rows,
  List<int> cols,
  List<(int, int)> edges, {
  bool free = false,
  Set<int> indirect = const {},
  List<int>? parentCounts,
}) => RouteClasses.compute(
  nodeRows: Int32List.fromList(rows),
  nodeCols: Int32List.fromList(cols),
  unit: free ? 16 : 1,
  free: free,
  edgeFroms: Int32List.fromList([for (final (int p, _) in edges) p]),
  edgeTos: Int32List.fromList([for (final (_, int c) in edges) c]),
  edgeKinds: Uint8List.fromList([
    for (var k = 0; k < edges.length; k++)
      if (indirect.contains(k)) GraphGridView.edgeKindIndirect else GraphGridView.edgeKindDirect,
  ]),
  parentCounts: Int32List.fromList(parentCounts ?? [for (var i = 0; i < rows.length; i++) 1]),
);

RouteGeometry _geometry(RouteClasses c, {double width = 240, double height = 62}) =>
    RouteGeometry.compute(c, RouteMetrics(width: width, height: height));

/// Column [col]'s card centre x at [width].
double _cx(int col, {double width = 240}) => 56 + col * (width + 56) + width / 2;

/// Edge [k]'s points as (x, y) records.
List<(double, double)> _points(RouteGeometry g, int k) => [
  for (int q = g.pointStarts[k]; q < g.pointStarts[k + 1]; q++) (g.points[2 * q], g.points[2 * q + 1]),
];

/// The run y of a 4- or 6-point polyline: its second point's y (the track above the parent, or below
/// the child for `merge-up`).
double _trackY(RouteGeometry g, int k) => g.points[2 * (g.pointStarts[k] + 1) + 1];

/// One bridge as a comparable tuple.
typedef _Bridge = (double, double, int, int, int);

List<_Bridge> _bridgeList(RouteBridges b) => [
  for (var q = 0; q < b.length; q++) (b.xs[q], b.ys[q], b.horizontalEdges[q], b.verticalEdges[q], b.verticalBreaks[q]),
];

int _compareBridges(_Bridge a, _Bridge b) {
  for (final (num x, num y) in [(a.$1, b.$1), (a.$2, b.$2), (a.$3, b.$3), (a.$4, b.$4), (a.$5, b.$5)]) {
    final int c = x.compareTo(y);
    if (c != 0) {
      return c;
    }
  }
  return 0;
}

/// GL's `analyzeEdges` + `placeCuts` (graph-layout.jsx:47-82), all pairs, as the oracle of the
/// per-window query: every crossing of two edges that share no node, with its orientation.
List<_Bridge> _allPairs(RouteGeometry g) {
  final RouteClasses c = g.classes;
  final segs = <List<(bool, double, double, double)>>[];
  for (var k = 0; k < c.edgeCount; k++) {
    final s = <(bool, double, double, double)>[];
    final List<(double, double)> pts = _points(g, k);
    for (var q = 1; q < pts.length; q++) {
      final (double x1, double y1) = pts[q - 1];
      final (double x2, double y2) = pts[q];
      if (x1 == x2 && y1 == y2) {
        continue;
      }
      s.add(y1 == y2 ? (true, y1, min(x1, x2), max(x1, x2)) : (false, x1, min(y1, y2), max(y1, y2)));
    }
    segs.add(s);
  }
  final out = <_Bridge>[];
  for (var i = 0; i < c.edgeCount; i++) {
    for (int j = i + 1; j < c.edgeCount; j++) {
      final int fi = c.edgeFroms[i];
      final int ti = c.edgeTos[i];
      final int fj = c.edgeFroms[j];
      final int tj = c.edgeTos[j];
      if (fi == fj || ti == tj || fi == tj || ti == fj) {
        continue;
      }
      for (final (bool, double, double, double) s in segs[i]) {
        for (final (bool, double, double, double) t in segs[j]) {
          if (s.$1 == t.$1) {
            continue;
          }
          final (h, v, he, ve) = s.$1 ? (s, t, i, j) : (t, s, j, i);
          if (v.$2 > h.$3 + 1 && v.$2 < h.$4 - 1 && h.$2 > v.$3 + 1 && h.$2 < v.$4 - 1) {
            final double hRoom = min(v.$2 - 6 - h.$3, h.$4 - v.$2 - 6);
            final double vRoom = min(h.$2 - 6 - v.$3, v.$4 - h.$2 - 6);
            out.add((v.$2, h.$2, he, ve, hRoom < 12 && vRoom > hRoom ? 1 : 0));
          }
        }
      }
    }
  }
  return out;
}

/// The bridges of a window in the documented order — every horizontal run by index, then every
/// vertical run by index — straight from the run arrays, without the query's candidate filter.
List<_Bridge> _byRunOrder(RouteGeometry g, double x0, double y0, double x1, double y1) {
  final RouteClasses c = g.classes;
  final out = <_Bridge>[];
  for (var h = 0; h < g.horizontalYs.length; h++) {
    final double hy = g.horizontalYs[h];
    if (hy < y0 || hy >= y1) {
      continue;
    }
    for (var v = 0; v < g.verticalXs.length; v++) {
      final double vx = g.verticalXs[v];
      if (vx < x0 || vx >= x1) {
        continue;
      }
      final int he = g.horizontalEdges[h];
      final int ve = g.verticalEdges[v];
      if (c.edgeFroms[he] == c.edgeFroms[ve] ||
          c.edgeTos[he] == c.edgeTos[ve] ||
          c.edgeFroms[he] == c.edgeTos[ve] ||
          c.edgeTos[he] == c.edgeFroms[ve]) {
        continue;
      }
      final double ha = g.horizontalLefts[h];
      final double hb = g.horizontalRights[h];
      final double va = g.verticalTops[v];
      final double vb = g.verticalBottoms[v];
      if (vx > ha + 1 && vx < hb - 1 && hy > va + 1 && hy < vb - 1) {
        final double hRoom = min(vx - 6 - ha, hb - vx - 6);
        final double vRoom = min(hy - 6 - va, vb - hy - 6);
        out.add((vx, hy, he, ve, hRoom < 12 && vRoom > hRoom ? 1 : 0));
      }
    }
  }
  return out;
}

/// Whether two orthogonal segments of different edges cross strictly inside both (1 px margin).
int _strictCrossings(RouteGeometry g, List<int> edges) {
  var count = 0;
  for (final a in edges) {
    for (final b in edges) {
      if (a == b) {
        continue;
      }
      final List<(double, double)> pa = _points(g, a);
      final List<(double, double)> pb = _points(g, b);
      for (var i = 1; i < pa.length; i++) {
        if (pa[i - 1].$2 != pa[i].$2) {
          continue; // a's horizontals against b's verticals
        }
        final double hy = pa[i].$2;
        final double h0 = min(pa[i - 1].$1, pa[i].$1);
        final double h1 = max(pa[i - 1].$1, pa[i].$1);
        for (var j = 1; j < pb.length; j++) {
          if (pb[j - 1].$1 != pb[j].$1 || pb[j - 1].$2 == pb[j].$2) {
            continue;
          }
          final double vx = pb[j].$1;
          final double v0 = min(pb[j - 1].$2, pb[j].$2);
          final double v1 = max(pb[j - 1].$2, pb[j].$2);
          if (vx > h0 + 1 && vx < h1 - 1 && hy > v0 + 1 && hy < v1 - 1) {
            count++;
          }
        }
      }
    }
  }
  return count;
}

/// The recording inputs, laid out by the product engine, ready to route.
typedef _Recording = ({String name, GraphGridView grid, Int32List parentCounts});

List<_Recording> _recordings(LayoutMode mode) {
  final out = <_Recording>[];
  for (final LaneOrder order in LaneOrder.values) {
    for (final name in ['stacks/design-default.json', 'stacks/design-all.json']) {
      final ({LayoutInput input, int nowMs, SpecStackFacts? facts}) parsed = parseSpecInput(
        File('$_goldens/$name').readAsBytesSync(),
        stacks: true,
      );
      final Int32List counts = parsed.facts!.parentCount;
      out
        ..add((
          name: '$name ${order.name}',
          grid: GraphGridView.fromBytes(
            computeGraphGrid(parsed.input, mode: mode, order: order, budget: defaultLayoutBudget),
          ),
          parentCounts: counts,
        ))
        ..add((
          name: '$name ${order.name} stacks-mixed',
          grid: GraphGridView.fromBytes(
            computeGraphGrid(
              parsed.input,
              mode: mode,
              order: order,
              budget: defaultLayoutBudget,
              stacks: parseSpecStackRequest(
                File('$_goldens/stacks/request-mixed.json').readAsBytesSync(),
                parsed.facts!,
              ),
            ),
          ),
          parentCounts: counts,
        ));
    }
    for (final name in ['design/design-default.json', 'fixtures/medium-narrow.input.json']) {
      final LayoutInput input = parseSpecInput(File('$_goldens/$name').readAsBytesSync()).input;
      final counts = Int32List(input.n);
      for (var i = 0; i < input.n; i++) {
        counts[i] = input.parStart[i + 1] - input.parStart[i];
      }
      out.add((
        name: '$name ${order.name}',
        grid: GraphGridView.fromBytes(computeGraphGrid(input, mode: mode, order: order, budget: defaultLayoutBudget)),
        parentCounts: counts,
      ));
    }
  }
  return out;
}

RouteClasses _route(GraphGridView grid, Int32List parentCounts) => RouteClasses.compute(
  nodeRows: grid.nodeRows,
  nodeCols: grid.nodeCols,
  unit: grid.unit,
  free: grid.mode == LayoutMode.free,
  edgeFroms: grid.edgeFroms,
  edgeTos: grid.edgeTos,
  edgeKinds: grid.edgeKinds,
  parentCounts: parentCounts,
);

void main() {
  group('class stage', () {
    test('each_kind_routes_with_its_number_of_points', () {
      // Each grid's last edge is the one under test.
      final cases = <(String, RouteClasses, int, int)>[
        ('straight', _grid([1, 0], [0, 0], [(1, 0)]), RouteClasses.kindStraight, 2),
        ('fork', _grid([1, 0], [1, 0], [(1, 0)]), RouteClasses.kindFork, 4),
        ('merge-adjacent', _grid([1, 0, 0], [0, 0, 1], [(1, 0), (2, 0)]), RouteClasses.kindMergeAdjacent, 4),
        ('merge-up', _grid([2, 1, 0], [0, 0, 1], [(1, 0), (2, 0)]), RouteClasses.kindMergeUp, 4),
      ];
      for (final (String name, RouteClasses c, int kind, int points) in cases) {
        final int k = c.edgeCount - 1;
        expect(c.kinds[k], kind, reason: name);
        final RouteGeometry g = _geometry(c);
        expect(g.pointStarts[k + 1] - g.pointStarts[k], points, reason: name);
      }
    });

    test('a_lane_blocked_merge_climbs_the_gutter_nearest_the_child_behind_no_card', () {
      // Child 0 (col 0, row 2), first parent 1 (col 0, row 1), second parent 2 (col 1, row 0), and node 3
      // in col 1 at row 1 between them: defect 2's case.
      final RouteClasses c = _grid([2, 1, 0, 1], [0, 0, 1, 1], [(1, 0), (2, 0)]);
      expect(c.kinds[1], RouteClasses.kindGutter);
      expect(c.gutters[1], 1); // between col 0 and col 1
      final RouteGeometry g = _geometry(c);
      final List<(double, double)> pts = _points(g, 1);
      expect(pts, hasLength(6));
      expect(pts[2].$1, _cx(0) + 296 / 2);
      expect(cardHits(g), isEmpty);
    });

    test('a_same_column_line_with_a_node_between_takes_the_gutter_on_its_right', () {
      final RouteClasses c = _grid([2, 0, 1], [0, 0, 0], [(1, 0)]);
      expect(c.kinds[0], RouteClasses.kindGutter);
      expect(c.sides[0], 1);
      expect(c.gutters[0], 1);
      expect(_points(_geometry(c), 0)[2].$1, _cx(0) + 296 / 2);
    });

    test('free_unit_rule_detours_for_a_card_12_units_above_the_parent_not_13_or_0', () {
      // Parent 1 (col 0, row 0) forks to child 0 (col 2, row 32); card 2 sits in col 1, d units above.
      for (final (int d, int kind, int gutter) in [
        (12, RouteClasses.kindGutter, 1),
        (13, RouteClasses.kindFork, 0),
        (0, RouteClasses.kindFork, 0),
      ]) {
        final RouteClasses c = _grid([32, 0, d], [2, 0, 1], [(1, 0)], free: true);
        expect(c.kinds[0], kind, reason: 'd = $d');
        expect(c.gutters[0], gutter, reason: 'd = $d');
        expect(c.directFallbacks, 0);
      }
      // Compact has no detours: the same grid one pitch apart stays a fork.
      expect(_grid([2, 0, 1], [2, 0, 1], [(1, 0)]).kinds[0], RouteClasses.kindFork);
    });

    test('a_blocked_direct_run_with_every_gutter_blocked_stays_direct_and_is_reported', () {
      // Card 2 (col 1, row 5) is 5 units above the parent and 11 below the child: both gutters blocked.
      final RouteClasses c = _grid([16, 0, 5], [2, 0, 1], [(1, 0)], free: true);
      expect(c.kinds[0], RouteClasses.kindFork);
      expect(c.directFallbacks, 1);
      expect(c.fallbackEdges, [1]);
      final RouteGeometry g = _geometry(c);
      expect(cardHits(g).every((h) => h.edge == 0), isTrue);
    });

    test('a_free_gutter_line_with_every_gutter_blocked_takes_the_nearest_and_is_flagged', () {
      // Child 0 (col 0, row 32), first parent 1 (col 0, row 16), second parent 2 (col 2, row 0) with node
      // 3 (col 2, row 8) between: a gutter line. Cards 4 (col 1, row 5: 5 units above the parent) and 5
      // (col 1, row 27: 5 units below the child) block both gutters.
      final RouteClasses c = _grid([32, 16, 0, 8, 5, 27], [0, 0, 2, 2, 1, 1], [(1, 0), (2, 0)], free: true);
      expect(c.kinds[1], RouteClasses.kindGutter);
      expect(c.gutters[1], 1);
      expect(c.fallbackEdges, [0, 1]);
      expect(c.directFallbacks, 0);
    });

    test('free_merge_up_detours_for_a_card_12_units_below_the_child_not_13_or_0', () {
      // Child 0 (col 0, row 32), first parent 1 (col 0, row 16), second parent 2 (col 2, row 0): a
      // merge-up; card 3 sits in col 1, d units below the child.
      for (final (int d, int kind, int gutter) in [
        (12, RouteClasses.kindGutter, 1),
        (13, RouteClasses.kindMergeUp, 0),
        (0, RouteClasses.kindMergeUp, 0),
      ]) {
        final RouteClasses c = _grid([32, 16, 0, 32 - d], [0, 0, 2, 1], [(1, 0), (2, 0)], free: true);
        expect(c.kinds[1], kind, reason: 'd = $d');
        expect(c.gutters[1], gutter, reason: 'd = $d');
        expect(c.fallbackEdges[1], 0, reason: 'd = $d');
      }
    });

    test('nine_lines_on_one_gutter_are_not_overfull', () {
      final RouteClasses c = _grid(
        [20, for (var r = 9; r >= 0; r--) r],
        List.filled(11, 0),
        [for (var p = 1; p <= 10; p++) (p, 0)],
      );
      expect([for (var k = 1; k <= 9; k++) c.kinds[k]], everyElement(RouteClasses.kindGutter));
      expect(c.overfullGutters, 0);
    });

    test('ten_lines_on_one_gutter_step_by_six_px_and_report_the_overflow', () {
      // Child 0 (col 0, row 20), parents 1 … 11 (col 0, rows 10 … 0): the first is straight, the other
      // ten are same-column non-first lines on gutter 1.
      final RouteClasses c = _grid(
        [20, for (var r = 10; r >= 0; r--) r],
        List.filled(12, 0),
        [for (var p = 1; p <= 11; p++) (p, 0)],
      );
      expect(c.kinds[0], RouteClasses.kindStraight);
      expect([for (var k = 1; k <= 10; k++) c.gutterSteps[k]], [0, 1, -1, 2, -2, 3, -3, 4, -4, 5]);
      expect(c.overfullGutters, 1);
      final RouteGeometry g = _geometry(c);
      final double base = _cx(0) + 296 / 2;
      expect([for (var k = 1; k <= 10; k++) _points(g, k)[2].$1 - base], [0, 6, -6, 12, -12, 18, -18, 24, -24, 30]);
    });

    test('two_indirect_edges_into_a_single_parent_node_share_one_deep_entry', () {
      // Child 0 (col 0, row 2) with Indirect edges from 1 (col 1, row 0) and 2 (col 2, row 1).
      final RouteClasses shared = _grid(
        [2, 0, 1],
        [0, 1, 2],
        [(1, 0), (2, 0)],
        indirect: {0, 1},
        parentCounts: [1, 0, 0],
      );
      expect(shared.slots, [0, 0]);
      expect(shared.deep, [1, 1]);
      final RouteGeometry g = _geometry(shared);
      expect(g.portStarts[1] - g.portStarts[0], 1);
      final RouteClasses own = _grid([2, 0, 1], [0, 1, 2], [(1, 0), (2, 0)], indirect: {0, 1}, parentCounts: [2, 0, 0]);
      expect(own.slots, [0, 1]);
      expect(own.deep, [0, 0]);
      final RouteGeometry h = _geometry(own);
      expect(h.portStarts[1] - h.portStarts[0], 2);
    });

    test('rejects_bad_input', () {
      expect(() => _grid([0, 1], [0], []), throwsArgumentError);
      expect(
        () => RouteClasses.compute(
          nodeRows: Int32List(1),
          nodeCols: Int32List(1),
          unit: 0,
          free: false,
          edgeFroms: Int32List(0),
          edgeTos: Int32List(0),
          edgeKinds: Uint8List(0),
          parentCounts: Int32List(0),
        ),
        throwsArgumentError,
      );
      expect(() => _grid([1, 0], [0, 0], [(1, 2)]), throwsArgumentError);
      expect(() => _grid([1, -1], [0, -1], [(1, 0)]), throwsArgumentError);
      expect(() => _grid([1, 0], [0, -1], []), throwsArgumentError);
      expect(
        () => RouteClasses.compute(
          nodeRows: Int32List(2),
          nodeCols: Int32List(2),
          unit: 1,
          free: false,
          edgeFroms: Int32List(1),
          edgeTos: Int32List(2),
          edgeKinds: Uint8List(1),
          parentCounts: Int32List(0),
        ),
        throwsArgumentError,
      );
    });
  });

  group('geometry stage', () {
    test('nine_exits_on_one_side_fan_as_the_entries_16_9_75_and_8_px_apart_at_w_400_240_160', () {
      // Parent 9 (col 0, row 0) forks to children 0 … 8 (cols 1 … 9, row 1). Story 10.30: the entry fan
      // (24 out, 16 apart, squeezed to 8, the overflow on the outermost; at most W/2 − 18).
      final RouteClasses c = _grid(
        [for (var k = 0; k < 9; k++) 1, 0],
        [for (var k = 0; k < 9; k++) k + 1, 0],
        [for (var k = 0; k < 9; k++) (9, k)],
      );
      for (final (double width, List<double> steps) in [
        (400.0, List.filled(8, 16)),
        (240.0, List.filled(8, 9.75)),
        (160.0, <double>[8, 8, 8, 8, 0, 0, 0, 0]),
      ]) {
        final RouteGeometry g = _geometry(c, width: width);
        final List<double> exits = [for (var k = 0; k < 9; k++) _points(g, k)[0].$1 - _cx(0, width: width)]..sort();
        expect([for (var k = 1; k < 9; k++) exits[k] - exits[k - 1]], steps, reason: 'W $width');
        expect(exits.first, 24, reason: 'W $width');
      }
    });

    test('story_10_30_ports_a_lone_line_at_the_centre_a_straight_one_at_the_centre_else_the_centre_free', () {
      double exit(RouteGeometry g, int k, int col) => _points(g, k).first.$1 - _cx(col);
      double entry(RouteGeometry g, int k, int col) => _points(g, k).last.$1 - _cx(col);

      // A lone bending exit: fork 1 (col 0, row 0) → 0 (col 1, row 1).
      final RouteGeometry lone = _geometry(_grid([1, 0], [1, 0], [(1, 0)]));
      expect((exit(lone, 0, 0), entry(lone, 0, 1)), (0, 0));

      // A lone merge-up never takes its parent's centre, which the entries of the cards above it use: parent 2
      // (col 1, row 0) is child 0's (col 0, row 2) second parent; 1 (col 0, row 1) is the first.
      final RouteClasses up = _grid([2, 1, 0], [0, 0, 1], [(1, 0), (2, 0)]);
      expect(up.kinds[1], RouteClasses.kindMergeUp);
      expect(exit(_geometry(up), 1, 1), -28);

      // Straight + bending: parent 2 (col 0, row 0) → 0 (col 0, row 1) and → 1 (col 1, row 1).
      final RouteClasses both = _grid([1, 1, 0], [0, 1, 0], [(2, 0), (2, 1)]);
      expect(both.kinds[0], RouteClasses.kindStraight);
      final RouteGeometry g = _geometry(both);
      expect((exit(g, 0, 0), exit(g, 1, 0)), (0, 24));

      // Left + right, none straight: parent 2 (col 1, row 0) → 0 (col 0, row 1) and → 1 (col 2, row 1).
      final RouteGeometry sides = _geometry(_grid([1, 1, 0], [0, 2, 1], [(2, 0), (2, 1)]));
      expect((exit(sides, 0, 1), exit(sides, 1, 1)), (-24, 24), reason: 'the centre stays free');

      // Entries alike: child 0 (col 1, row 1) with parents 1 (col 0, row 0) and 2 (col 2, row 0), none straight.
      final RouteGeometry merge = _geometry(_grid([1, 0, 0], [1, 0, 2], [(1, 0), (2, 0)]));
      expect((entry(merge, 0, 1), entry(merge, 1, 1)), (-24, 24), reason: 'top and bottom alike');
    });

    test('story_10_30_a_merge_whose_first_parent_bends_leaves_the_entry_centre_free', () {
      // Child 0 (col 0, row 2): first parent 1 (col 1, row 0), second parent 2 (col 0, row 1). Only a
      // first parent is ever straight, so the same-column second one is a gutter line: no line is straight.
      final RouteClasses c = _grid([2, 0, 1], [0, 1, 0], [(1, 0), (2, 0)]);
      expect([c.kinds[0], c.kinds[1]], everyElement(isNot(RouteClasses.kindStraight)));
      final RouteGeometry g = _geometry(c);
      expect([_points(g, 0).last.$1, _points(g, 1).last.$1], everyElement(isNot(_cx(0))));
    });

    test('entries_sit_24_plus_16_k_px_out_and_squeeze_to_8', () {
      // Child 0 (col 0, row 1), first parent 1 (col 0, row 0), m more parents in cols 1 … m, row 0.
      for (final (int m, List<double> expected) in [
        (3, <double>[24, 40, 56]),
        (12, <double>[24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 96, 96]),
      ]) {
        final RouteClasses c = _grid(
          [1, 0, for (var k = 0; k < m; k++) 0],
          [0, 0, for (var k = 0; k < m; k++) k + 1],
          [(1, 0), for (var k = 0; k < m; k++) (k + 2, 0)],
        );
        final RouteGeometry g = _geometry(c);
        final List<double> entries = [for (var k = 1; k <= m; k++) _points(g, k).last.$1 - _cx(0)]..sort();
        expect(entries, expected, reason: 'm = $m');
        expect(_points(g, 0).last.$1, _cx(0));
      }
    });

    test('a_mixed_side_exits_merge_ups_innermost_by_child_row_then_the_fork', () {
      // Parent 5 (col 0, row 0): merge-ups into 0 (col 1, row 2) and 1 (col 2, row 3), a fork into 2
      // (col 3, row 1); 3 and 4 are the merge children's first parents.
      final RouteClasses c = _grid(
        [2, 3, 1, 1, 2, 0],
        [1, 2, 3, 1, 2, 0],
        [(3, 0), (5, 0), (4, 1), (5, 1), (5, 2)],
      );
      expect(
        [c.kinds[1], c.kinds[3], c.kinds[4]],
        [
          RouteClasses.kindMergeUp,
          RouteClasses.kindMergeUp,
          RouteClasses.kindFork,
        ],
      );
      final RouteGeometry g = _geometry(c);
      double exit(int k) => _points(g, k)[0].$1 - _cx(0);
      // The entry fan (Story 10.30): 24, 40, 56 inner → outer; a merge-up 4 px outside its slot.
      expect(exit(3), 28); // merge-up into row 3
      expect(exit(1), 44); // merge-up into row 2
      expect(exit(4), 56); // the fork
    });

    test('a_shared_entrys_deep_run_sits_at_its_free_parts_far_end', () {
      // As the shared-entry case: the second Indirect edge (2 → 0) is a merge-adjacent line whose run
      // lies alone in the band above node 2 (row 1, card top at 56 + 110).
      const double top = 56 + 110;
      final RouteClasses shared = _grid(
        [2, 0, 1],
        [0, 1, 2],
        [(1, 0), (2, 0)],
        indirect: {0, 1},
        parentCounts: [1, 0, 0],
      );
      expect(shared.kinds[1], RouteClasses.kindMergeAdjacent);
      expect(_trackY(_geometry(shared), 1), top - 12); // far from the child: the free part's lower end
      final RouteClasses own = _grid([2, 0, 1], [0, 1, 2], [(1, 0), (2, 0)], indirect: {0, 1}, parentCounts: [2, 0, 0]);
      expect(_trackY(_geometry(own), 1), top - 24); // the band's middle
    });

    test('a_free_run_takes_the_room_interval_nearest_the_band_middle', () {
      // Fork 1 (col 0, row 0) → 0 (col 1, row 32); card 2 in the parent's own column, 6 units up (the
      // unit rule ignores end columns), splits the band. H 2, gapY 80: band [140, 220], inner
      // [152, 208], card [179.25, 201.25] → intervals [152, 179.25] (0.75 from the middle 180) and
      // [201.25, 208] (21.25).
      final RouteClasses c = _grid([32, 0, 6], [1, 0, 0], [(1, 0)], free: true);
      expect(c.kinds[0], RouteClasses.kindFork);
      final g = RouteGeometry.compute(c, const RouteMetrics(width: 240, height: 2, gapY: 80));
      expect(_trackY(g, 0), 152 + 0.5 * (179.25 - 152));
    });

    test('a_cyclic_run_pair_counts_one_unavoidable_crossing_and_still_gets_two_tracks', () {
      // Forks 2 (col 0) → 0 (col 2) and 3 (col 3) → 1 (col 1) in one band: each spans the other's entry.
      final RouteClasses c = _grid([1, 1, 0, 0], [2, 1, 0, 3], [(2, 0), (3, 1)]);
      final RouteGeometry g = _geometry(c);
      expect(g.unavoidableCrossings, 1);
      expect((_trackY(g, 0) - _trackY(g, 1)).abs(), 6);
    });

    test('nested_runs_share_a_band_6_px_apart_without_crossing', () {
      final RouteClasses c = _grid([1, 1, 1, 0], [1, 2, 3, 0], [(3, 0), (3, 1), (3, 2)]);
      final RouteGeometry g = _geometry(c);
      expect(g.overfullClusters, 0);
      expect(g.unavoidableCrossings, 0);
      final List<double> ys = [for (var k = 0; k < 3; k++) _trackY(g, k)]..sort();
      expect([ys[1] - ys[0], ys[2] - ys[1]], [6, 6]);
      // The band above the parent (row 0's card top at pad + pitch): its inner part.
      const double parentTop = 56 + 110;
      expect(ys.first, greaterThanOrEqualTo(parentTop - 48 + 12));
      expect(ys.last, lessThanOrEqualTo(parentTop - 12));
      expect(_strictCrossings(g, [0, 1, 2]), 0);
    });

    test('an_overfull_band_keeps_3_5_px_spacing_centred_and_is_reported', () {
      final RouteClasses c = _grid(
        [for (var k = 0; k < 10; k++) 1, 0],
        [for (var k = 0; k < 10; k++) k + 1, 0],
        [for (var k = 0; k < 10; k++) (10, k)],
      );
      final RouteGeometry g = _geometry(c);
      expect(g.overfullClusters, 1);
      expect(g.overfullEdges, everyElement(1));
      final List<double> ys = [for (var k = 0; k < 10; k++) _trackY(g, k)]..sort();
      for (var k = 1; k < 10; k++) {
        expect(ys[k] - ys[k - 1], closeTo(3.5, 1e-9));
      }
      const double parentTop = 56 + 110;
      expect((ys.first + ys.last) / 2, closeTo(parentTop - 24, 1e-9));
    });

    test('a_crossing_breaks_the_horizontal_12_by_10', () {
      // B: straight 1 → 0 in col 1 (rows 0 … 3); A: fork 3 (col 2, row 1) → 2 (col 0, row 2) crosses it.
      final RouteClasses c = _grid([3, 0, 2, 1], [1, 1, 0, 2], [(1, 0), (3, 2)]);
      final RouteGeometry g = _geometry(c);
      final RouteBridges all = g.bridges(
        double.negativeInfinity,
        double.negativeInfinity,
        double.infinity,
        double.infinity,
      );
      expect(_bridgeList(all), [(_cx(1), _trackY(g, 1), 1, 0, 0)]);
      final double x = all.xs[0];
      final double y = all.ys[0];
      expect(g.bridges(x, y, x + 1, y + 1).length, 1);
      expect(g.bridges(x + 1, y, x + 2, y + 1).length, 0); // half-open: x0 is in, x1 is out
      expect(g.bridges(x - 1, y - 1, x, y).length, 0);
    });

    test('a_crossing_near_the_horizontals_end_breaks_the_longer_vertical_10_by_12', () {
      // Two lane-blocked merges on gutter 1: B (6 → 0, rows 0 … 6) first at the gutter's x, A (5 → 2,
      // rows 1 … 3) second, 6 px to its right; A's run into the gutter ends 6 px past B's vertical.
      final RouteClasses c = _grid(
        [6, 5, 3, 2, 2, 1, 0],
        [1, 1, 1, 1, 0, 0, 0],
        [(1, 0), (6, 0), (3, 2), (5, 2)],
      );
      expect(c.kinds[1], RouteClasses.kindGutter);
      expect(c.kinds[3], RouteClasses.kindGutter);
      expect([c.gutterSteps[1], c.gutterSteps[3]], [0, 1]);
      final RouteGeometry g = _geometry(c);
      final List<_Bridge> all = _bridgeList(
        g.bridges(double.negativeInfinity, double.negativeInfinity, double.infinity, double.infinity),
      );
      final double gutter = _cx(0) + 296 / 2;
      expect(all, contains((gutter, _trackY(g, 3), 3, 1, 1)));
      expect(all, unorderedEquals(_allPairs(g)));
    });

    test('per_window_bridges_equal_the_all_pairs_oracle_on_random_grids_and_windows', () {
      final rnd = Random(4150);
      var compared = 0;
      for (var round = 0; round < 40; round++) {
        final LayoutInput input = randomGraph(rnd, 40 + rnd.nextInt(60), branchy: round.isOdd);
        final LayoutMode mode = round % 4 < 2 ? LayoutMode.compact : LayoutMode.free;
        final grid = GraphGridView.fromBytes(
          computeGraphGrid(input, mode: mode, order: LaneOrder.greedy, budget: defaultLayoutBudget),
        );
        final counts = Int32List(input.n);
        for (var i = 0; i < input.n; i++) {
          counts[i] = input.parStart[i + 1] - input.parStart[i];
        }
        final RouteGeometry g = _geometry(
          _route(grid, counts),
          width: const [160.0, 240.0, 400.0][rnd.nextInt(3)],
          height: rnd.nextBool() ? 40 : 62,
        );
        final List<_Bridge> oracle = _allPairs(g)..sort(_compareBridges);
        final List<_Bridge> whole = _bridgeList(
          g.bridges(double.negativeInfinity, double.negativeInfinity, double.infinity, double.infinity),
        )..sort(_compareBridges);
        expect(whole, oracle, reason: 'round $round');
        for (var w = 0; w < 20; w++) {
          final double x0 = rnd.nextDouble() * 3000 - 200;
          final double y0 = rnd.nextDouble() * 20000 - 200;
          final double x1 = x0 + rnd.nextDouble() * 1500;
          final double y1 = y0 + rnd.nextDouble() * 1500;
          final List<_Bridge> unsorted = _bridgeList(g.bridges(x0, y0, x1, y1));
          expect(unsorted, _byRunOrder(g, x0, y0, x1, y1), reason: 'round $round window $w: the documented order');
          final window = <_Bridge>[...unsorted]..sort(_compareBridges);
          expect(
            window,
            oracle.where((b) => b.$1 >= x0 && b.$1 < x1 && b.$2 >= y0 && b.$2 < y1).toList(),
            reason: 'round $round window $w',
          );
          compared += window.length;
        }
      }
      expect(compared, greaterThan(0));
    });

    test('a_card_size_change_recomputes_only_the_geometry_deterministically', () {
      final ({String name, GraphGridView grid, Int32List parentCounts}) rec = _recordings(LayoutMode.free).first;
      final RouteClasses c = _route(rec.grid, rec.parentCounts);
      final List<Object> snapshot = [
        Uint8List.fromList(c.kinds),
        Int8List.fromList(c.sides),
        Int32List.fromList(c.gutters),
        Int32List.fromList(c.gutterSteps),
        Int32List.fromList(c.slots),
        Uint8List.fromList(c.deep),
      ];
      final RouteGeometry narrow = _geometry(c, width: 160);
      final RouteGeometry wide = _geometry(c, width: 400);
      expect([c.kinds, c.sides, c.gutters, c.gutterSteps, c.slots, c.deep], snapshot);
      expect(narrow.points, isNot(wide.points));
      final RouteGeometry again = _geometry(c, width: 400);
      expect(again.points, wide.points);
      expect(again.portXs, wide.portXs);
      expect(again.horizontalYs, wide.horizontalYs);
      expect(again.verticalXs, wide.verticalXs);
    });

    test('hidden_members_are_skipped_and_stack_nodes_never_share_an_entry', () {
      for (final LayoutMode mode in LayoutMode.values) {
        for (final _Recording rec in _recordings(mode).where((r) => r.name.endsWith('stacks-mixed'))) {
          final GraphGridView grid = rec.grid;
          expect(grid.stackCount, greaterThan(0), reason: rec.name);
          final RouteClasses c = _route(grid, rec.parentCounts);
          final RouteGeometry g = _geometry(c);
          for (var i = 0; i < grid.nodeRows.length; i++) {
            if (grid.isHidden(i)) {
              expect(g.portStarts[i + 1] - g.portStarts[i], 0, reason: '${rec.name} node $i');
            }
          }
          for (var k = 0; k < c.edgeCount; k++) {
            if (c.edgeTos[k] >= grid.nodeCount) {
              expect((c.slots[k], c.deep[k]), (k, 0), reason: '${rec.name} edge $k');
            }
          }
        }
      }
    });
  });

  group('route gate', () {
    test('compact_lines_pass_behind_no_card_except_on_an_overfull_gutter', () {
      for (final _Recording rec in _recordings(LayoutMode.compact)) {
        final RouteClasses c = _route(rec.grid, rec.parentCounts);
        final Uint8List overfull = overfullGutterEdges(c);
        for (final (double width, double height) in [
          for (final double w in [160, 240, 400])
            for (final double h in [40, 62]) (w, h),
        ]) {
          final RouteGeometry g = _geometry(c, width: width, height: height);
          final List<CardHit> hits = [
            for (final CardHit hit in cardHits(g))
              if (overfull[hit.edge] == 0) hit,
          ];
          expect(hits, isEmpty, reason: '${rec.name} W $width H $height');
        }
      }
    });

    test('free_lines_pass_behind_a_card_only_where_it_is_reported', () {
      for (final _Recording rec in _recordings(LayoutMode.free)) {
        final RouteClasses c = _route(rec.grid, rec.parentCounts);
        final Uint8List overfull = overfullGutterEdges(c);
        for (final (double width, double height) in [
          for (final double w in [160, 240, 400])
            for (final double h in [40, 62]) (w, h),
        ]) {
          final RouteGeometry g = _geometry(c, width: width, height: height);
          final List<CardHit> hits = [
            for (final CardHit hit in cardHits(g))
              if (c.fallbackEdges[hit.edge] == 0 && g.overfullEdges[hit.edge] == 0 && overfull[hit.edge] == 0) hit,
          ];
          expect(hits, isEmpty, reason: '${rec.name} W $width H $height');
        }
      }
    });

    test('the_barrel_exports_the_router', () {
      expect(barrel.routeSyncNodeLimit, routeSyncNodeLimit);
      expect(const barrel.RouteMetrics(width: 240, height: 62).gapX, 56);
    });
  });
}
