// SPDX-License-Identifier: MIT

// The line router (docs/graph-layout.md §14): the per-layout stage, the shapes, levels, ports and
// bridges of the geometry stage on hand-built grids (W 240, H 62, gapX 56, gapY 48, pad 56 unless a
// test says otherwise; column centre 176 + 296·c, the gutter right of column c at 324 + 296·c), and
// the line gate over the recording inputs and the fuzz cases.

import 'dart:convert';
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
  int unit = 1,
  Set<int> indirect = const {},
  List<int>? parentCounts,
}) => RouteClasses.compute(
  nodeRows: Int32List.fromList(rows),
  nodeCols: Int32List.fromList(cols),
  unit: unit,
  edgeFroms: Int32List.fromList([for (final (int p, _) in edges) p]),
  edgeTos: Int32List.fromList([for (final (_, int c) in edges) c]),
  edgeKinds: Uint8List.fromList([
    for (var k = 0; k < edges.length; k++)
      if (indirect.contains(k)) GraphGridView.edgeKindIndirect else GraphGridView.edgeKindDirect,
  ]),
  parentCounts: Int32List.fromList(parentCounts ?? [for (var i = 0; i < rows.length; i++) 1]),
);

RouteGeometry _geometry(RouteClasses c, {double width = 240, double height = 62, double gapX = 56, double gapY = 48}) =>
    RouteGeometry.compute(c, RouteMetrics(width: width, height: height, gapX: gapX, gapY: gapY));

/// Column [col]'s card centre x at [width].
double _cx(int col, {double width = 240}) => 56 + col * (width + 56) + width / 2;

/// Edge [k]'s points as (x, y) records.
List<(double, double)> _points(RouteGeometry g, int k) => [
  for (int q = g.pointStarts[k]; q < g.pointStarts[k + 1]; q++) (g.points[2 * q], g.points[2 * q + 1]),
];

/// Expects edge [k]'s polyline to be [expected], within rounding.
void _expectLine(RouteGeometry g, int k, List<(double, double)> expected) {
  final List<(double, double)> actual = _points(g, k);
  expect(actual, hasLength(expected.length), reason: 'edge $k: $actual');
  for (var q = 0; q < expected.length; q++) {
    expect(actual[q].$1, closeTo(expected[q].$1, 1e-6), reason: 'edge $k point $q x: $actual');
    expect(actual[q].$2, closeTo(expected[q].$2, 1e-6), reason: 'edge $k point $q y: $actual');
  }
}

/// The run y of a polyline with bends: its second point's y (the first level from the parent).
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
/// per-window query: every crossing of two edges, with its orientation (GL skips edges that share a
/// node; the router bridges them too since 2026-11-07).
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
      for (final (bool, double, double, double) s in segs[i]) {
        for (final (bool, double, double, double) t in segs[j]) {
          if (s.$1 == t.$1) {
            continue;
          }
          final ((bool, double, double, double) h, (bool, double, double, double) v, int he, int ve) = s.$1
              ? (s, t, i, j)
              : (t, s, j, i);
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
      if (he == ve) {
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
  for (final name in ['stacks/design-default.json', 'stacks/design-all.json']) {
    final ({LayoutInput input, int nowMs, SpecStackFacts? facts}) parsed = parseSpecInput(
      File('$_goldens/$name').readAsBytesSync(),
      stacks: true,
    );
    final Int32List counts = parsed.facts!.parentCount;
    out
      ..add((
        name: name,
        grid: GraphGridView.fromBytes(computeGraphGrid(parsed.input, mode: mode)),
        parentCounts: counts,
      ))
      ..add((
        name: '$name stacks-mixed',
        grid: GraphGridView.fromBytes(
          computeGraphGrid(
            parsed.input,
            mode: mode,
            stacks: parseSpecStackRequest(File('$_goldens/stacks/request-mixed.json').readAsBytesSync(), parsed.facts!),
          ),
        ),
        parentCounts: counts,
      ));
  }
  for (final name in ['design/design-default.json', 'fixtures/medium-narrow.input.json']) {
    final LayoutInput input = parseSpecInput(File('$_goldens/$name').readAsBytesSync()).input;
    out.add((
      name: name,
      grid: GraphGridView.fromBytes(computeGraphGrid(input, mode: mode)),
      parentCounts: _parentCounts(input),
    ));
  }
  return out;
}

Int32List _parentCounts(LayoutInput input) {
  final counts = Int32List(input.n);
  for (var i = 0; i < input.n; i++) {
    counts[i] = input.parStart[i + 1] - input.parStart[i];
  }
  return counts;
}

RouteClasses _route(GraphGridView grid, Int32List parentCounts) => RouteClasses.compute(
  nodeRows: grid.nodeRows,
  nodeCols: grid.nodeCols,
  unit: grid.unit,
  edgeFroms: grid.edgeFroms,
  edgeTos: grid.edgeTos,
  edgeKinds: grid.edgeKinds,
  parentCounts: parentCounts,
);

void main() {
  group('per-layout stage', () {
    test('goes_on_marks_a_parent_with_a_first_parent_child_in_its_column', () {
      // Parent 2 (col 0): a first-parent child 0 in its column. Parent 3 (col 1): its child 1 is a first-parent child
      // in column 2, and child 0 is its second-parent child in column 0, so its branch does not go on.
      final RouteClasses c = _grid([1, 1, 0, 0], [0, 2, 0, 1], [(2, 0), (3, 0), (3, 1)]);
      expect(c.goesOn, [0, 0, 1, 0]);
      expect(c.firstParents, [1, 0, 1]);
    });

    test('column_pos_is_each_visible_nodes_place_in_the_column_list', () {
      final RouteClasses c = _grid([2, -1, 0, 1], [0, -1, 0, 1], []);
      expect(c.columnNodes, [2, 0, 3]);
      expect([c.columnPos[2], c.columnPos[0], c.columnPos[3]], [0, 1, 2]);
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
      final RouteClasses own = _grid([2, 0, 1], [0, 1, 2], [(1, 0), (2, 0)], indirect: {0, 1}, parentCounts: [2, 0, 0]);
      expect(own.slots, [0, 1]);
      expect(own.deep, [0, 0]);
    });

    test('rejects_bad_input', () {
      expect(() => _grid([0, 1], [0], []), throwsArgumentError);
      expect(
        () => RouteClasses.compute(
          nodeRows: Int32List(1),
          nodeCols: Int32List(1),
          unit: 0,
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
          edgeFroms: Int32List(1),
          edgeTos: Int32List(2),
          edgeKinds: Uint8List(1),
          parentCounts: Int32List(0),
        ),
        throwsArgumentError,
      );
    });
  });

  group('geometry stage: the rules', () {
    test('a_line_in_a_free_column_is_straight_also_for_a_non_first_parent_one_row_below_its_child', () {
      final RouteGeometry g = _geometry(_grid([1, 0, 0], [0, 1, 0], [(1, 0), (2, 0)]));
      _expectLine(g, 1, [(176, 166), (176, 118)]);
      _expectLine(g, 0, [(472, 166), (472, 146.8), (200, 146.8), (200, 118)]);
    });

    test('a_card_in_the_way_turns_the_line_into_the_gutter_at_the_lifted_level', () {
      final RouteGeometry g = _geometry(_grid([2, 0, 1], [0, 0, 0], [(1, 0)]));
      _expectLine(g, 0, [(176, 276), (176, 247.2), (324, 247.2), (324, 137.2), (176, 137.2), (176, 118)]);
    });

    test('a_level_on_a_card_moves_off_it_as_little_as_it_can_at_unit_16', () {
      final RouteGeometry g = _geometry(_grid([32, 0, 3], [2, 0, 1], [(1, 0)], unit: 16));
      _expectLine(g, 0, [(176, 276), (176, 236.175), (768, 236.175), (768, 118)]);
    });

    test('three_runs_of_one_parent_nest_6_px_apart_without_crossing', () {
      final RouteClasses c = _grid([1, 1, 1, 0], [1, 2, 3, 0], [(3, 0), (3, 1), (3, 2)]);
      final RouteGeometry g = _geometry(c);
      expect([for (var k = 0; k < 3; k++) _points(g, k).first.$1], [200, 216, 232]);
      for (final (int k, double level) in [(0, 146.8), (1, 152.8), (2, 158.8)]) {
        expect(_trackY(g, k), closeTo(level, 1e-6));
      }
      expect([for (var k = 0; k < 3; k++) _points(g, k).last.$1], [472, 768, 1064]);
      expect(_strictCrossings(g, [0, 1, 2]), 0);
      expect(g.unavoidableCrossings, 0);
    });

    test('a_merge_line_bends_at_its_parent_where_its_branch_goes_on_and_the_childs_column_is_free', () {
      final RouteGeometry g = _geometry(_grid([3, 2, 1, 0], [0, 1, 2, 0], [(3, 0), (2, 1), (3, 1)]));
      _expectLine(g, 2, [(200, 386), (200, 366.8), (472, 366.8), (472, 228)]);
      _expectLine(g, 1, [(768, 276), (768, 256.8), (496, 256.8), (496, 228)]);
      _expectLine(g, 0, [(176, 386), (176, 118)]);
    });

    test('an_x_between_two_neighbouring_rows_crosses_once_and_moves_a_lone_line_off_the_centre', () {
      final RouteGeometry g = _geometry(_grid([1, 1, 0, 0], [0, 1, 1, 0], [(2, 0), (3, 1)]));
      _expectLine(g, 0, [(448, 166), (448, 146.8), (176, 146.8), (176, 118)]);
      _expectLine(g, 1, [(176, 166), (176, 152.8), (472, 152.8), (472, 118)]);
      expect(_strictCrossings(g, [0, 1]), 1);
      expect(g.sharedStretches, 0);
      expect(g.unavoidableCrossings, 1);
      expect(g.unsettledPorts, 0);
    });

    test('a_detour_is_taken_where_it_saves_a_crossing', () {
      final RouteGeometry g = _geometry(
        _grid([5, 4, 2, 0, 2, 3], [1, 3, 3, 1, 2, 0], [(3, 0), (2, 1), (3, 1), (4, 5)]),
      );
      _expectLine(g, 2, [(496, 606), (496, 586.8), (916, 586.8), (916, 247.2), (1040, 247.2), (1040, 228)]);
    });

    test('a_detour_that_saves_nothing_is_left_alone', () {
      final RouteGeometry g = _geometry(_grid([5, 4, 2, 0], [1, 3, 3, 1], [(3, 0), (2, 1), (3, 1)]));
      _expectLine(g, 2, [(496, 606), (496, 247.2), (1040, 247.2), (1040, 228)]);
    });

    test('a_detour_is_taken_for_the_column_order_whatever_it_crosses', () {
      final RouteGeometry g = _geometry(_grid([5, 4, 2, 0, 1], [1, 3, 3, 1, 2], [(3, 0), (2, 1), (3, 1), (3, 4)]));
      _expectLine(g, 2, [(512, 606), (512, 592.8), (916, 592.8), (916, 247.2), (1040, 247.2), (1040, 228)]);
      _expectLine(g, 3, [(496, 606), (496, 586.8), (768, 586.8), (768, 558)]);
    });

    test('a_fan_of_ten_lines_shares_one_row_gap_without_getting_too_tight', () {
      final RouteGeometry g = _geometry(
        _grid(
          [for (var k = 0; k < 10; k++) 1, 0],
          [for (var k = 0; k < 10; k++) k + 1, 0],
          [for (var k = 0; k < 10; k++) (10, k)],
        ),
      );
      for (var k = 0; k < 10; k++) {
        expect(_trackY(g, k), closeTo(120 + 4.6 * k, 1e-6), reason: 'level $k');
        expect(_points(g, k).first.$1, closeTo(200 + 26 / 3 * k, 1e-6), reason: 'exit $k');
      }
      expect(g.tightFans, 0);
    });

    test('a_fan_too_tight_for_2_px_is_reported_and_its_exits_overflow', () {
      final RouteGeometry g = _geometry(
        _grid(
          [for (var k = 0; k < 24; k++) 1, 0],
          [for (var k = 0; k < 24; k++) k + 1, 0],
          [for (var k = 0; k < 24; k++) (24, k)],
        ),
      );
      expect(g.tightFans, 1);
      // A run never comes nearer than 2 px to its band's edges, so the outermost run gives up its share of 46 / 24.
      expect(_trackY(g, 0), closeTo(120, 1e-6));
      expect(_trackY(g, 23), closeTo(164, 1e-6));
      for (var k = 2; k < 24; k++) {
        expect(_trackY(g, k) - _trackY(g, k - 1), closeTo(46 / 24, 1e-6));
      }
      final List<double> exits = [for (var k = 0; k < 24; k++) _points(g, k).first.$1]..sort();
      expect(exits.last, 272);
      expect(exits.first, 200);
    });

    test('a_hidden_merges_lines_share_one_entry_and_the_deep_run_keeps_a_long_stem', () {
      final RouteClasses c = _grid([2, 0, 1], [0, 1, 2], [(1, 0), (2, 0)], indirect: {0, 1}, parentCounts: [1, 0, 0]);
      final RouteGeometry g = _geometry(c);
      expect(c.slots, [0, 0]);
      expect(c.deep, [1, 1]);
      expect(g.portStarts[1] - g.portStarts[0], 1);
      expect(g.portXs[g.portStarts[0]], 176);
      _expectLine(g, 1, [(768, 166), (768, 154), (176, 154), (176, 118)]);
      _expectLine(g, 0, [(472, 276), (472, 256.8), (176, 256.8), (176, 118)]);
    });

    test('the_same_lines_without_sharing_take_two_entries_and_keep_their_usual_levels', () {
      final RouteClasses c = _grid([2, 0, 1], [0, 1, 2], [(1, 0), (2, 0)], indirect: {0, 1}, parentCounts: [2, 0, 0]);
      final RouteGeometry g = _geometry(c);
      expect(c.slots, [0, 1]);
      expect(c.deep, [0, 0]);
      expect(g.portStarts[1] - g.portStarts[0], 2);
      _expectLine(g, 1, [(768, 166), (768, 137.2), (200, 137.2), (200, 118)]);
    });

    test('a_loser_of_the_tie_break_at_a_fan_slot_moves_one_slot_further_out', () {
      final RouteGeometry g = _geometry(_grid([5, 5, 4, 2], [0, 1, 1, 0], [(3, 0), (2, 0), (2, 1), (3, 1)]));
      _expectLine(g, 1, [(448, 166), (448, 146.8), (216, 146.8), (216, 118)]);
      _expectLine(g, 3, [(200, 386), (200, 137.2), (448, 137.2), (448, 118)]);
      expect(g.unsettledPorts, 0);
    });

    test('a_fork_dodges_a_card_inside_its_childs_column_through_the_gutter_with_8_points', () {
      final RouteGeometry g = _geometry(_grid([3, 0, 1], [1, 0, 1], [(1, 0)]));
      _expectLine(g, 0, [
        (176, 386),
        (176, 366.8),
        (472, 366.8),
        (472, 357.2),
        (324, 357.2),
        (324, 137.2),
        (472, 137.2),
        (472, 118),
      ]);
    });

    test('a_fork_that_cannot_enter_its_childs_column_goes_through_the_gutter_with_6_points', () {
      // Card 2 (col 1, row 14) reaches down to the run above the parent, so the line cannot enter column 1 at all.
      final RouteGeometry g = _geometry(_grid([32, 0, 14], [1, 0, 1], [(1, 0)], unit: 16));
      _expectLine(g, 0, [(176, 276), (176, 258.875), (324, 258.875), (324, 137.2), (472, 137.2), (472, 118)]);
    });

    test('a_merge_lines_run_at_its_parent_moves_off_a_card_at_unit_16', () {
      // Parent 2 (col 0, row 0) goes on in node 3 and merges into 0 (col 2, row 48), whose first parent is 1 (col 3,
      // row 16). Card 4 (col 1, row 3) stands on the usual level 696.8, so the run moves above that card.
      final RouteGeometry g = _geometry(
        _grid([48, 16, 0, 96, 3], [2, 3, 0, 0, 1], [(1, 0), (2, 0), (2, 3)], unit: 16),
      );
      _expectLine(g, 1, [(200, 716), (200, 676.175), (768, 676.175), (768, 448)]);
    });

    test('a_detour_between_neighbouring_rows_is_not_taken_even_for_the_column_order', () {
      // Parent 4 (col 0, row 0) goes on in node 2 and forks to 1 (col 1, row 1). The fork to the nearer column turns nearer
      // to the card than the merge line to 0 (col 2, row 1), which asks for a detour; one row apart it would be a zigzag.
      final RouteGeometry g = _geometry(_grid([1, 1, 2, 0, 0], [2, 1, 0, 2, 0], [(3, 0), (4, 0), (4, 1), (4, 2)]));
      _expectLine(g, 1, [(216, 276), (216, 262.8), (744, 262.8), (744, 228)]);
    });

    test('a_detours_run_moves_off_a_card_at_unit_16', () {
      // The detour that saves a crossing, at unit 16, with card 6 (col 2, row 3) on its usual level 586.8.
      final RouteGeometry g = _geometry(
        _grid([80, 64, 32, 0, 32, 48, 3], [1, 3, 3, 1, 2, 0, 2], [(3, 0), (2, 1), (3, 1), (4, 5)], unit: 16),
      );
      _expectLine(g, 2, [(496, 606), (496, 566.175), (916, 566.175), (916, 247.2), (1040, 247.2), (1040, 228)]);
    });

    test('a_detour_counts_the_crossings_of_an_8_point_line', () {
      // Line 4 → 5 dodges card 6 in its child's column with 8 points, and its first run crosses the merge line's usual
      // climb in column 1: the detour saves that crossing.
      final RouteGeometry g = _geometry(
        _grid([5, 4, 2, 0, 1, 3, 2], [1, 3, 3, 1, 2, 0, 0], [(3, 0), (2, 1), (3, 1), (4, 5)]),
      );
      expect(_points(g, 3), hasLength(8));
      _expectLine(g, 2, [(496, 606), (496, 586.8), (916, 586.8), (916, 247.2), (1040, 247.2), (1040, 228)]);
    });

    test('a_line_reuses_a_gutter_slot_once_the_earlier_line_has_ended', () {
      // Column 0, rows 6 … 12: A 9 → 12, B 6 → 11, C 7 → 9. B overlaps A (slot 1, +6 px); C starts where A has ended and
      // overlaps B, so it takes A's slot 0 again.
      final RouteGeometry g = _geometry(_grid([12, 11, 10, 9, 8, 7, 6], List.filled(7, 0), [(3, 0), (6, 1), (5, 3)]));
      _expectLine(g, 0, [(176, 386), (176, 357.2), (324, 357.2), (324, 137.2), (176, 137.2), (176, 118)]);
      _expectLine(g, 1, [(176, 716), (176, 687.2), (330, 687.2), (330, 247.2), (176, 247.2), (176, 228)]);
      _expectLine(g, 2, [(176, 606), (176, 577.2), (324, 577.2), (324, 467.2), (176, 467.2), (176, 448)]);
    });

    test('a_line_the_tracks_leave_out_of_order_still_climbs', () {
      // A seeded graph, reduced: the tracks leave line 3's two levels out of order; monotone levels repair them.
      final RouteGeometry g = _geometry(
        _grid(
          [2, 1, 9, 7, 1, 2, 6, 1, 2, 7, 6, 1, 0, 5, 5, 6, 3, 4, 3],
          [9, 7, 10, 13, 11, 3, 8, 3, 1, 6, 0, 13, 4, 12, 8, 6, 2, 0, 5],
          [(1, 0), (4, 2), (10, 3), (7, 3), (7, 5), (12, 6), (11, 8), (16, 9), (12, 11), (17, 13), (18, 15)],
        ),
      );
      expect(polylineFailures(g), isEmpty);
    });

    test('a_hidden_merge_with_a_straight_line_keeps_one_port_on_that_lines_x', () {
      // Child 0 (col 1, row 1) has Indirect parents 1 (col 0, row 0) and 2 (col 1, row 0). The owner of the shared slot must
      // not leave the centre to the straight line, or the two would enter at two x's.
      final RouteClasses c = _grid([1, 0, 0], [1, 0, 1], [(1, 0), (2, 0)], indirect: {0, 1}, parentCounts: [1, 0, 0]);
      final RouteGeometry g = _geometry(c);
      expect(c.slots, [0, 0]);
      expect(g.portStarts[1] - g.portStarts[0], 1);
      expect(g.portXs[g.portStarts[0]], 472);
      _expectLine(g, 0, [(176, 166), (176, 146.8), (472, 146.8), (472, 118)]);
      _expectLine(g, 1, [(472, 166), (472, 118)]);
    });

    test('every_line_of_a_shared_slot_takes_part_in_the_tie_break', () {
      // Child 0 (col 1, row 5) has Indirect parents 1 (col 2, row 4) and 2 (col 3, row 1); line 2 → 0 is the slot's longest
      // and climbs column 1 from row 1. Line 4 → 5 climbs column 1 past that stretch. Both stay straight 358.8 px, so the
      // edge with the higher index gives up its port.
      final RouteClasses c = _grid(
        [5, 4, 1, 3, 0, 4, 3],
        [1, 2, 3, 3, 1, 0, 0],
        [(1, 0), (2, 0), (2, 3), (6, 5), (4, 5)],
        indirect: {0, 1},
      );
      final RouteGeometry g = _geometry(c);
      expect(c.slots[1], 0);
      _expectLine(g, 4, [(448, 606), (448, 247.2), (200, 247.2), (200, 228)]);
      expect(g.sharedStretches, 0);
      expect(g.unsettledPorts, 0);
    });

    test('a_stretch_the_rules_cannot_avoid_is_reported_for_both_lines', () {
      final RouteGeometry g = _geometry(_grid([3, 0, 1, 0], [1, 0, 1, 1], [(1, 0), (3, 2)]));
      _expectLine(g, 0, [
        (176, 386),
        (176, 366.8),
        (472, 366.8),
        (472, 357.2),
        (324, 357.2),
        (324, 137.2),
        (472, 137.2),
        (472, 118),
      ]);
      expect(g.sharedStretches, 1);
      expect(g.sharedEdges, [1, 1]);
      expect(sharedStretchOracle(g), 1);
    });

    test('a_line_behind_a_card_is_reported_at_unit_16', () {
      final RouteClasses c = _grid([16, 0, 9], [2, 0, 1], [(1, 0)], unit: 16);
      final RouteGeometry g = _geometry(c);
      _expectLine(g, 0, [(176, 166), (176, 146.8), (768, 146.8), (768, 118)]);
      expect(g.behindCards, 1);
      expect(g.behindEdges, [1]);
      expect(cardHits(g).every((h) => g.behindEdges[h.edge] == 1), isTrue);
    });

    test('an_empty_layout_has_empty_arrays_and_zero_reports', () {
      final RouteGeometry g = _geometry(_grid([], [], []));
      expect(g.points, isEmpty);
      expect(g.pointStarts, [0]);
      expect(g.portXs, isEmpty);
      expect(g.verticalXs, isEmpty);
      expect(g.horizontalYs, isEmpty);
      expect(
        [g.behindCards, g.sharedStretches, g.tightFans, g.unavoidableCrossings, g.unsettledPorts],
        [0, 0, 0, 0, 0],
      );
    });

    test('a_card_size_change_recomputes_only_the_geometry_deterministically', () {
      final _Recording rec = _recordings(LayoutMode.free).first;
      final RouteClasses c = _route(rec.grid, rec.parentCounts);
      final List<Object> snapshot = [
        Int32List.fromList(c.columnNodes),
        Int32List.fromList(c.slots),
        Uint8List.fromList(c.deep),
        Uint8List.fromList(c.firstParents),
        Uint8List.fromList(c.goesOn),
      ];
      final RouteGeometry narrow = _geometry(c, width: 160);
      final RouteGeometry wide = _geometry(c, width: 400);
      expect(identical(narrow.classes, c) && identical(wide.classes, c), isTrue);
      expect([c.columnNodes, c.slots, c.deep, c.firstParents, c.goesOn], snapshot);
      expect(narrow.points, isNot(wide.points));
      final RouteGeometry again = _geometry(c, width: 400);
      expect(again.pointStarts, wide.pointStarts);
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

  group('geometry stage: ports', () {
    test('nine_exits_on_one_side_fan_as_the_entries_16_9_75_and_8_px_apart_at_w_400_240_160', () {
      // Parent 9 (col 0, row 0) forks to children 0 … 8 (cols 1 … 9, row 1). The entry fan: 24 out, 16 apart, squeezed
      // to 8, the overflow on the outermost; at most W/2 − 18.
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

    test('a_lone_line_sits_at_the_centre_a_straight_one_at_the_centre_else_the_centre_stays_free', () {
      double exit(RouteGeometry g, int k, int col) => _points(g, k).first.$1 - _cx(col);
      double entry(RouteGeometry g, int k, int col) => _points(g, k).last.$1 - _cx(col);

      // A lone bending exit: fork 1 (col 0, row 0) → 0 (col 1, row 1).
      final RouteGeometry lone = _geometry(_grid([1, 0], [1, 0], [(1, 0)]));
      expect((exit(lone, 0, 0), entry(lone, 0, 1)), (0, 0));

      // A lone merge to a child up-right leaves at the centre (Ralph's nuwmzrpz card, 2026-11-02; it was at +28):
      // parent 2 (col 0, row 0) is child 0's (col 1, row 2) second parent; 1 (col 1, row 1) is the first.
      final RouteGeometry up = _geometry(_grid([2, 1, 0], [1, 1, 0], [(1, 0), (2, 0)]));
      expect(exit(up, 1, 0), 0);

      // Straight + bending: parent 2 (col 0, row 0) → 0 (col 0, row 1) and → 1 (col 1, row 1).
      final RouteGeometry g = _geometry(_grid([1, 1, 0], [0, 1, 0], [(2, 0), (2, 1)]));
      expect((exit(g, 0, 0), exit(g, 1, 0)), (0, 24));

      // Left + right, none straight: parent 2 (col 1, row 0) → 0 (col 0, row 1) and → 1 (col 2, row 1).
      final RouteGeometry sides = _geometry(_grid([1, 1, 0], [0, 2, 1], [(2, 0), (2, 1)]));
      expect((exit(sides, 0, 1), exit(sides, 1, 1)), (-24, 24), reason: 'the centre stays free');

      // Entries alike: child 0 (col 1, row 1) with parents 1 (col 0, row 0) and 2 (col 2, row 0), none straight.
      final RouteGeometry merge = _geometry(_grid([1, 0, 0], [1, 0, 2], [(1, 0), (2, 0)]));
      expect((entry(merge, 0, 1), entry(merge, 1, 1)), (-24, 24), reason: 'top and bottom alike');
    });

    test('a_line_that_is_vertical_at_the_entry_takes_the_centre_whatever_its_shape', () {
      // Child 0 (col 1, row 2): first parent 1 (col 0, row 0), climbing child 0's column from the band above row 0;
      // second parent 2 (col 2, row 1), a merge line that turns right below the child. The fork is vertical at the
      // child's bottom, so it takes the centre; the merge line fans to its side, right.
      final RouteGeometry g = _geometry(_grid([2, 0, 1], [1, 0, 2], [(1, 0), (2, 0)]));
      expect([_points(g, 0).last.$1 - _cx(1), _points(g, 1).last.$1 - _cx(1)], [0, 24]);

      // A same-column second parent right below its child is straight and keeps the centre; the first parent's fork
      // meets that card in the child's column and goes through the gutter next to it, so it fans right.
      final RouteGeometry same = _geometry(_grid([2, 0, 1], [0, 1, 0], [(1, 0), (2, 0)]));
      expect(_points(same, 1), hasLength(2));
      expect(_points(same, 0), hasLength(8));
      expect([_points(same, 1).last.$1 - _cx(0), _points(same, 0).last.$1 - _cx(0)], [0, 24]);

      // A single fork entering a child's bottom: at the centre. Fork 1 (col 0, row 0) → 0 (col 1, row 2).
      final RouteGeometry lone = _geometry(_grid([2, 0], [1, 0], [(1, 0)]));
      expect(_points(lone, 0).last.$1, _cx(1));

      // An adjacent fork turns right below its child too, so with a merge line beside it the centre stays free:
      // child 0 (col 1, row 1), parents 1 (col 0, row 0) and 2 (col 2, row 0).
      final RouteGeometry adjacent = _geometry(_grid([1, 0, 0], [1, 0, 2], [(1, 0), (2, 0)]));
      expect([_points(adjacent, 0).last.$1 - _cx(1), _points(adjacent, 1).last.$1 - _cx(1)], [-24, 24]);
    });

    test('a_straight_line_and_a_merge_line_both_vertical_never_share_an_x', () {
      // Parent 3 (col 0, row 0): straight into 0 (col 0, row 3) and a merge line into 1 (col 1, row 2), whose first
      // parent is 2 (col 1, row 1). The straight line stays vertical longest and takes the centre; the merge line fans
      // to the side it later turns to.
      final RouteGeometry g = _geometry(_grid([3, 2, 1, 0], [0, 1, 1, 0], [(3, 0), (2, 1), (3, 1)]));
      expect(_points(g, 0), hasLength(2));
      expect([_points(g, 0).first.$1 - _cx(0), _points(g, 2).first.$1 - _cx(0)], [0, 24]);
    });

    test('merge_lines_leave_on_the_side_they_turn_to', () {
      // Ralph's rtvlvrzr card (2026-11-02: two merge lines left of centre that then ran right). Parent 5 (col 1,
      // row 0): merge lines into 0 (col 2, row 2) and 1 (col 3, row 3), a fork left into 2 (col 0, row 1); 3 and 4 are
      // the merge children's first parents. The longer merge line takes the centre, the other fans right, the fork
      // left.
      final RouteGeometry g = _geometry(
        _grid([2, 3, 1, 1, 2, 0], [2, 3, 0, 2, 3, 1], [(3, 0), (5, 0), (4, 1), (5, 1), (5, 2)]),
      );
      double exit(int k) => _points(g, k)[0].$1 - _cx(1);
      expect([exit(3), exit(1), exit(4)], [0, 24, -24]);
    });

    test('a_line_climbing_past_a_port_on_its_x_keeps_it_only_if_longer', () {
      // Column 0: parent 4 (row 0) merges into 1 (col 1, row 3; first parent 2, col 1, row 2) and climbs to row 3; above
      // it child 0 (row 4) takes its lone fork from 3 (col 2, row 2), which climbs column 0 down to row 2. Both are
      // vertical on column 0's centre over rows 2 … 3: the merge line stays straight longer, keeps the centre, and the
      // fork enters toward its parent.
      final RouteGeometry g = _geometry(_grid([4, 3, 2, 2, 0], [0, 1, 1, 2, 0], [(2, 1), (4, 1), (3, 0)]));
      expect([_points(g, 1).first.$1 - _cx(0), _points(g, 2).last.$1 - _cx(0)], [0, 24]);
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

    test('a_mixed_side_exits_the_longest_merge_line_at_the_centre_the_other_innermost_then_the_fork', () {
      // Parent 5 (col 0, row 0): merge lines into 0 (col 1, row 2) and 1 (col 2, row 3), a fork into 2 (col 3, row 1);
      // 3 and 4 are the merge children's first parents. Both merge lines are vertical at the parent's top: the one into
      // row 3 stays straight longest and takes the centre, the other is the fan's innermost (24), the fork turning at
      // the top the next (40).
      final RouteGeometry g = _geometry(
        _grid([2, 3, 1, 1, 2, 0], [1, 2, 3, 1, 2, 0], [(3, 0), (5, 0), (4, 1), (5, 1), (5, 2)]),
      );
      double exit(int k) => _points(g, k)[0].$1 - _cx(0);
      expect(exit(3), 0);
      expect(exit(1), 24);
      expect(exit(4), 40);
    });

    test('a_cyclic_run_pair_counts_one_unavoidable_crossing_and_still_gets_two_tracks', () {
      // Forks 2 (col 0) → 0 (col 2) and 3 (col 3) → 1 (col 1) in one band: each spans the other's entry.
      final RouteGeometry g = _geometry(_grid([1, 1, 0, 0], [2, 1, 0, 3], [(2, 0), (3, 1)]));
      expect(g.unavoidableCrossings, 1);
      expect((_trackY(g, 0) - _trackY(g, 1)).abs(), closeTo(6, 1e-9));
    });
  });

  group('geometry stage: bridges', () {
    test('a_crossing_breaks_the_horizontal_12_by_10', () {
      // B: straight 1 → 0 in col 1 (rows 0 … 3); A: fork 3 (col 2, row 1) → 2 (col 0, row 2) crosses it.
      final RouteGeometry g = _geometry(_grid([3, 0, 2, 1], [1, 1, 0, 2], [(1, 0), (3, 2)]));
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
      // Two merge lines with cards in their parents' column, on gutter 1: B (6 → 0, rows 0 … 6) has the first slot, A
      // (5 → 2, rows 1 … 3) the second, 6 px to its right; A's run into the gutter ends 6 px past B's vertical.
      final RouteGeometry g = _geometry(
        _grid([6, 5, 3, 2, 2, 1, 0], [1, 1, 1, 1, 0, 0, 0], [(1, 0), (6, 0), (3, 2), (5, 2)]),
      );
      expect(_points(g, 1), hasLength(6));
      expect(_points(g, 3), hasLength(6));
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
        final grid = GraphGridView.fromBytes(computeGraphGrid(input, mode: mode));
        final RouteGeometry g = _geometry(
          _route(grid, _parentCounts(input)),
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
  });

  group('line gate', () {
    test('every_recording_passes_the_line_gate_at_every_card_size_in_both_modes', () {
      for (final LayoutMode mode in LayoutMode.values) {
        for (final _Recording rec in _recordings(mode)) {
          final RouteClasses c = _route(rec.grid, rec.parentCounts);
          for (final double width in [160, 240, 400]) {
            // Every card height and gap the densities give: compact (the default), balanced, comfy.
            for (final (double height, double gapX, double gapY) in const [
              (40.0, 56.0, 48.0),
              (62.0, 56.0, 48.0),
              (44.0, 62.0, 54.0),
              (68.0, 62.0, 54.0),
              (48.0, 68.0, 60.0),
              (74.0, 68.0, 60.0),
            ]) {
              final RouteGeometry g = _geometry(c, width: width, height: height, gapX: gapX, gapY: gapY);
              final what = '${rec.name} ${mode.name} W $width H $height gapY $gapY';
              expect(lineFailures(g), isEmpty, reason: what);
              expect(g.behindCards, 0, reason: '$what: no line behind a card');
              expect(g.sharedStretches, 0, reason: '$what: no shared stretch');
              expect(g.unsettledPorts, 0, reason: '$what: the port passes settle');
            }
          }
        }
      }
    });

    test('every_fuzz_case_has_right_angles_ends_on_their_card_edges_and_lines_that_climb', () {
      final List<String> cases = File('$_goldens/fuzz/cases.jsonl').readAsLinesSync();
      expect(cases, hasLength(100));
      var adjacentMerges = 0;
      var shared = 0;
      var behind = 0;
      final failures = <String>[];
      for (var i = 0; i < cases.length; i++) {
        final LayoutInput input = parseSpecInput(utf8.encode(cases[i])).input;
        for (final LayoutMode mode in LayoutMode.values) {
          final grid = GraphGridView.fromBytes(computeGraphGrid(input, mode: mode));
          final RouteClasses c = _route(grid, _parentCounts(input));
          final RouteGeometry g = _geometry(c);
          expect(polylineFailures(g), isEmpty, reason: 'case $i ${mode.name}');
          for (var k = 0; k < c.edgeCount; k++) {
            if (c.firstParents[k] == 0 &&
                c.nodeCols[c.edgeFroms[k]] == c.nodeCols[c.edgeTos[k]] &&
                c.nodeRows[c.edgeTos[k]] == c.nodeRows[c.edgeFroms[k]] + grid.unit) {
              adjacentMerges++;
            }
          }
          shared += g.sharedStretches;
          behind += g.behindCards;
          failures.addAll(lineFailures(g));
        }
      }
      // These inputs hold the shapes real histories rarely show: gutter lines, detours and a non-first parent one row
      // below its child in its own column.
      expect(adjacentMerges, greaterThan(0), reason: 'a merge between adjacent rows of one column');
      // Dense random merges break the rules more often than real histories, and the rules have known limits
      // (spikes/graph-layout-lab/README.md, step 12): the counts may fall, never rise.
      expect(shared, lessThanOrEqualTo(134));
      expect(behind, lessThanOrEqualTo(30));
      expect(failures.where((f) => f.contains('column order')).length, lessThanOrEqualTo(152));
      expect(failures.where((f) => f.contains(' cross')).length, lessThanOrEqualTo(403));
      expect(failures.where((f) => !f.contains('column order') && !f.contains(' cross')), isEmpty);
    });

    test('the_barrel_exports_the_router', () {
      expect(barrel.routeSyncNodeLimit, routeSyncNodeLimit);
      expect(const barrel.RouteMetrics(width: 240, height: 62).gapX, 56);
    });
  });
}
