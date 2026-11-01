// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_edges.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_viewport_render.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';
import 'package:zanshin_core/zanshin_core.dart' show RouteBridges, RouteClasses, RouteGeometry, routeSyncNodeLimit;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../../widgetbook/graph/graph_recordings.g.dart';
import '../../../widgetbook/graph/synthetic_layout.dart';
import 'graph_harness.dart';

/// [layout]'s geometry, synchronously (≤ the sync limit).
RouteGeometry routed(GraphLayout layout, GraphMetrics metrics, {RouteClasses? classes}) =>
    routeGraph(layout, metrics, classes: classes) as RouteGeometry;

GraphEdgePainter painterOf(GraphLayout layout, {GraphMetrics? metrics}) =>
    GraphEdgePainter(layout: layout, geometry: routed(layout, metrics ?? GraphMetrics()), theme: GraphTheme.night);

/// Edge [k]'s polyline points.
List<Offset> polyline(RouteGeometry g, int k) => <Offset>[
  for (int q = g.pointStarts[k]; q < g.pointStarts[k + 1]; q++) Offset(g.points[2 * q], g.points[2 * q + 1]),
];

/// The start and end of every contour of [path].
List<(Offset, Offset, double)> contours(Path path) => <(Offset, Offset, double)>[
  for (final PathMetric m in path.computeMetrics())
    (m.getTangentForOffset(0)!.position, m.getTangentForOffset(m.length)!.position, m.length),
];

Matcher near(Offset at, [double tolerance = .05]) =>
    predicate<Offset>((o) => (o - at).distance <= tolerance, 'within $tolerance of $at');

/// A test-only oracle (docs/graph-layout.md §14.4, all pairs): every crossing of a horizontal and a vertical run of
/// [edges] inside both runs by 1 px, in [x0, x1) × [y0, y1), of two edges that share no node, with the edge that breaks.
Set<(int, double, double, bool)> oracleCuts(RouteGeometry g, List<int> edges, Rect window) {
  final h = <(int, double, double, double)>[];
  final v = <(int, double, double, double)>[];
  for (final k in edges) {
    final List<Offset> p = polyline(g, k);
    for (var i = 1; i < p.length; i++) {
      if (p[i] == p[i - 1]) {
        continue;
      }
      if (p[i].dy == p[i - 1].dy) {
        h.add((k, p[i].dy, math.min(p[i].dx, p[i - 1].dx), math.max(p[i].dx, p[i - 1].dx)));
      } else {
        v.add((k, p[i].dx, math.min(p[i].dy, p[i - 1].dy), math.max(p[i].dy, p[i - 1].dy)));
      }
    }
  }
  final out = <(int, double, double, bool)>{};
  final Int32List froms = g.classes.edgeFroms;
  final Int32List tos = g.classes.edgeTos;
  for (final (int he, double hy, double ha, double hb) in h) {
    for (final (int ve, double vx, double va, double vb) in v) {
      if (!(vx > ha + 1 && vx < hb - 1 && hy > va + 1 && hy < vb - 1)) {
        continue;
      }
      if (vx < window.left || vx >= window.right || hy < window.top || hy >= window.bottom) {
        continue;
      }
      if (froms[he] == froms[ve] || tos[he] == tos[ve] || froms[he] == tos[ve] || tos[he] == froms[ve]) {
        continue;
      }
      final double hRoom = math.min(vx - 6 - ha, hb - vx - 6);
      final double vRoom = math.min(hy - 6 - va, vb - hy - 6);
      final bool vertical = hRoom < 12 && vRoom > hRoom;
      out.add((vertical ? ve : he, vx, hy, vertical));
    }
  }
  return out;
}

Set<(int, double, double, bool)> cutSet(Map<int, List<GraphEdgeCut>> cuts) => <(int, double, double, bool)>{
  for (final MapEntry(key: int k, value: List<GraphEdgeCut> list) in cuts.entries)
    for (final c in list) (k, c.x, c.y, c.vertical),
};

void main() {
  group('graphRoundedPath', () {
    test('a bend between segments of 8 and 30 px gets radius 4', () {
      final Path path = graphRoundedPath(Float64List.fromList(<double>[0, 0, 0, -8, 30, -8]), 0, 3);
      final PathMetric m = path.computeMetrics().single;
      expect(m.getTangentForOffset(0)!.position, near(Offset.zero));
      expect(m.getTangentForOffset(4)!.position, near(const Offset(0, -4)));
      expect(m.getTangentForOffset(m.length - 26)!.position, near(const Offset(4, -8)));
      expect(m.getTangentForOffset(m.length)!.position, near(const Offset(30, -8)));
    });

    test('a 2-point polyline is one line, consecutive equal points are dropped', () {
      final Path straight = graphRoundedPath(Float64List.fromList(<double>[5, 100, 5, 100, 5, 20]), 0, 3);
      expect(contours(straight), hasLength(1));
      final (Offset from, Offset to, double length) = contours(straight).single;
      expect((from, to, length), (const Offset(5, 100), const Offset(5, 20), 80.0));
    });
  });

  group('geometry', () {
    for (final String name in graphRecordingNames) {
      test('$name: every edge is its rounded polyline in UniformRows coordinates; a W change reuses the classes', () {
        final RecordedGraphLayout layout = recording(name);
        final int version = layout.version;
        RouteClasses? classes;
        for (final detailed in <bool>[true, false]) {
          for (final width in <double>[160, 240, 400]) {
            final metrics = GraphMetrics(cardWidth: width, detailedCards: detailed);
            final RouteGeometry g = routed(layout, metrics, classes: classes);
            if (classes != null) {
              expect(identical(g.classes, classes), isTrue);
            }
            classes = g.classes;
            final rows = UniformRows(layout, metrics);
            final painter = GraphEdgePainter(layout: layout, geometry: g, theme: GraphTheme.night);
            for (var k = 0; k < layout.edgeCount; k++) {
              final List<Offset> p = polyline(g, k);
              final int parent = layout.parentOf(k);
              final int child = layout.childOf(k);
              // From the parent's top edge to the child's bottom edge, inside both cards.
              expect(p.first.dy, closeTo(rows.top(parent), 1e-6));
              expect(p.last.dy, closeTo(rows.top(child) + metrics.cardHeight, 1e-6));
              expect(
                p.first.dx,
                inInclusiveRange(metrics.x(layout.colOf(parent)), metrics.x(layout.colOf(parent)) + width),
              );
              expect(
                p.last.dx,
                inInclusiveRange(metrics.x(layout.colOf(child)), metrics.x(layout.colOf(child)) + width),
              );
              final Path path = painter.edgePath(k);
              final (Offset from, Offset to, _) = contours(path).single;
              expect(from, near(p.first));
              expect(to, near(p.last));
              final Path expected = graphRoundedPath(g.points, g.pointStarts[k], g.pointStarts[k + 1]);
              expect(path.computeMetrics().single.length, expected.computeMetrics().single.length);
              // A solid edge without cuts strokes its path as is.
              if (layout.kindOf(k) == GraphEdgeKind.direct) {
                expect(
                  contours(painter.strokePath(k, painter.edgePath(k).getBounds())).single.$3,
                  closeTo(expected.computeMetrics().single.length, 1e-6),
                );
              }
            }
          }
        }
        expect(layout.version, version);
      });
    }
  });

  test('an Indirect edge is dashed 3 on, 5 off from its parent end', () {
    final RecordedGraphLayout layout = handLayout(
      <(String, int, int)>[('p', 0, 0), ('c', 4, 1)],
      edges: <(int, int)>[(1, 0)],
      indirect: <int>{0},
      parentCounts: <int>[0, 1],
    );
    final GraphEdgePainter painter = painterOf(layout);
    final List<Offset> p = polyline(painter.geometry, 0);
    final List<(Offset, Offset, double)> dashes = contours(
      painter.strokePath(0, const Rect.fromLTWH(-10000, -10000, 20000, 20000)),
    );
    expect(dashes.length, greaterThan(10));
    expect(dashes.first.$1, near(p.first));
    for (var i = 0; i < dashes.length; i++) {
      // Skia re-measures a dash that bends round a corner: within .15 px there.
      expect(dashes[i].$3, i == dashes.length - 1 ? lessThanOrEqualTo(3.15) : closeTo(3, .15));
    }
    final double total = painter.edgePath(0).computeMetrics().single.length;
    expect(dashes.length, (total / 8).ceil());
  });

  group('a long straight Indirect edge', () {
    // p (row 0) ← c (row 20), one column: a 2-point vertical line from p's top up to c's bottom.
    late GraphEdgePainter painter;
    late Offset start;
    // Arc length from the parent end of a point on the line.
    double arcOf(Offset o) => start.dy - o.dy;

    setUp(() {
      painter = painterOf(
        handLayout(
          <(String, int, int)>[('p', 0, 0), ('c', 20, 0)],
          edges: <(int, int)>[(1, 0)],
          indirect: <int>{0},
          parentCounts: <int>[0, 1],
        ),
      );
      start = polyline(painter.geometry, 0).first;
    });

    test('a window over its middle gets every dash of the 8 px grid it shows, from the parent end', () {
      final window = Rect.fromLTWH(start.dx - 100, start.dy - 1200, 200, 300);
      final List<(Offset, Offset, double)> dashes = contours(painter.strokePath(0, window));
      expect(dashes, isNotEmpty);
      // The visible arc range: the window + 8 px.
      final double lo = arcOf(Offset(start.dx, window.bottom + 8));
      final double hi = arcOf(Offset(start.dx, window.top - 8));
      final starts = <double>[for (final (Offset a, _, _) in dashes) arcOf(a)];
      for (var i = 0; i < dashes.length; i++) {
        expect(starts[i] / 8, closeTo((starts[i] / 8).roundToDouble(), 1e-3), reason: 'on the 8 px grid');
        expect(dashes[i].$3, closeTo(3, 1e-3));
        if (i > 0) {
          expect(starts[i] - starts[i - 1], closeTo(8, 1e-3), reason: 'none missing');
        }
      }
      expect(starts.first, inInclusiveRange(lo - 8, lo + 1e-3));
      expect(starts.last + 8, greaterThanOrEqualTo(hi - 1e-3));
      expect(starts.last, lessThan(hi));
    });

    test('a cut keeps the 8 px grid on both sides of its 12 px gap and draws nothing inside it', () {
      // The crossing at arc length 100: the gap is 94–106; dash 96–99 goes, dash 104–107 keeps 106–107.
      final GraphEdgeCut cut = (x: start.dx, y: start.dy - 100, vertical: true);
      final List<(Offset, Offset, double)> dashes = contours(
        painter.strokePath(0, const Rect.fromLTWH(-10000, -10000, 20000, 20000), cuts: <GraphEdgeCut>[cut]),
      );
      final arcs = <(double, double)>[
        for (final (Offset a, Offset b, _) in dashes) (arcOf(a), arcOf(b)),
      ];
      for (final (double from, double to) in arcs) {
        expect(to <= 94 + 1e-3 || from >= 106 - 1e-3, isTrue, reason: 'nothing in the gap: $from–$to');
        final bool gapEdge = (from - 106).abs() < 1e-3;
        expect(gapEdge || (from / 8 - (from / 8).roundToDouble()).abs() < 1e-3, isTrue, reason: 'grid: $from');
      }
      expect(arcs, contains(predicate<(double, double)>((a) => (a.$1 - 88).abs() < 1e-3 && (a.$2 - 91).abs() < 1e-3)));
      expect(
        arcs,
        contains(predicate<(double, double)>((a) => (a.$1 - 106).abs() < 1e-3 && (a.$2 - 107).abs() < 1e-3)),
      );
      expect(
        arcs,
        contains(predicate<(double, double)>((a) => (a.$1 - 112).abs() < 1e-3 && (a.$2 - 115).abs() < 1e-3)),
      );
      expect(arcs.where((a) => (a.$1 - 96).abs() < 1e-3), isEmpty);
    });
  });

  group('bridges', () {
    // Finds, in the recordings and the synthetic 10k, a bridge of each kind whose cut lies on a straight part.
    ({GraphEdgePainter painter, GraphEdgeCut cut, int broken, int other})? find(bool vertical) {
      final layouts = <GraphLayout>[for (final name in graphRecordingNames) recording(name), syntheticLayout(10000)];
      for (final layout in layouts) {
        final GraphEdgePainter painter = painterOf(layout);
        final RouteGeometry g = painter.geometry;
        final RouteBridges b = g.bridges(-1000000000, -1000000000, 1000000000, 1000000000);
        for (var i = 0; i < b.length; i++) {
          if ((b.verticalBreaks[i] != 0) != vertical) {
            continue;
          }
          final int broken = vertical ? b.verticalEdges[i] : b.horizontalEdges[i];
          final int other = vertical ? b.horizontalEdges[i] : b.verticalEdges[i];
          final List<Offset> p = polyline(g, broken);
          // The run carrying the cut, at least 16 px of straight line either side of the crossing.
          final bool straight = List<int>.generate(p.length - 1, (s) => s + 1).any((s) {
            final Offset a = p[s - 1];
            final Offset c = p[s];
            return vertical
                ? a.dx == b.xs[i] &&
                      c.dx == b.xs[i] &&
                      (b.ys[i] - math.min(a.dy, c.dy)) >= 16 &&
                      (math.max(a.dy, c.dy) - b.ys[i]) >= 16
                : a.dy == b.ys[i] &&
                      c.dy == b.ys[i] &&
                      (b.xs[i] - math.min(a.dx, c.dx)) >= 16 &&
                      (math.max(a.dx, c.dx) - b.xs[i]) >= 16;
          });
          if (straight) {
            return (painter: painter, cut: (x: b.xs[i], y: b.ys[i], vertical: vertical), broken: broken, other: other);
          }
        }
      }
      return null;
    }

    for (final vertical in <bool>[false, true]) {
      test('a ${vertical ? 'vertical' : 'horizontal'} break leaves a 12 px gap centred on the crossing', () {
        final ({GraphEdgePainter painter, GraphEdgeCut cut, int broken, int other})? found = find(vertical);
        expect(found, isNotNull);
        final (
          :GraphEdgePainter painter,
          :GraphEdgeCut cut,
          :int broken,
          :int other,
        ) = found!;
        final window = Rect.fromCenter(center: Offset(cut.x, cut.y), width: 400, height: 300);
        final Map<int, List<GraphEdgeCut>> cuts = painter.cutsIn(window);
        expect(cuts[broken], contains(cut));
        expect(cuts[other] ?? const <GraphEdgeCut>[], isNot(contains(cut)));
        final along = vertical ? const Offset(0, 6) : const Offset(6, 0);
        final at = Offset(cut.x, cut.y);
        final ends = <Offset>[
          for (final (Offset a, Offset b, _) in contours(
            painter.strokePath(broken, window, cuts: cuts[broken]),
          )) ...<Offset>[a, b],
        ];
        expect(ends, contains(near(at - along)));
        expect(ends, contains(near(at + along)));
        // The other edge is whole there: no contour ends within 6 px of the crossing.
        final otherEnds = <Offset>[
          for (final (Offset a, Offset b, _) in contours(
            painter.strokePath(other, window, cuts: cuts[other]),
          )) ...<Offset>[a, b],
        ];
        expect(otherEnds.where((o) => (o - at).distance < 5.9), isEmpty);
      });
    }

    testWidgets('a scrolled viewport paints the edges at the plane origin, cut at a horizontal break', (tester) async {
      final (
        :GraphEdgePainter painter,
        :GraphEdgeCut cut,
        :int broken,
        :int other,
      ) = find(
        false,
      )!;
      final harness = GraphHarness(painter.layout)
        ..edges = (context, origin, visible) =>
            painter.paint(context, origin, visible, highlight: const GraphEdgeHighlight(lineage: false));
      await pumpGraph(tester, harness);
      // Scroll so the crossing shows near (150, 150) on screen.
      final at = Offset(cut.x, cut.y);
      harness.h.jumpTo((at.dx - 150).clamp(0, harness.h.position.maxScrollExtent));
      harness.v.jumpTo((at.dy - 150).clamp(0, harness.v.position.maxScrollExtent));
      await tester.pump();
      expect(harness.scroll, isNot(Offset.zero));
      // The viewport sits at the surface's origin with no insets, so a plane point paints at point − scroll.
      final Offset screen = at - harness.scroll;
      Iterable<PathMetric> drawn = const <PathMetric>[];
      expect(
        harness.render(tester),
        paints..something((method, arguments) {
          if (method != #drawPath) {
            return false;
          }
          drawn = (arguments[0] as Path).computeMetrics().toList();
          return true;
        }),
      );
      final ends = <Offset>[
        for (final m in drawn) ...<Offset>[
          m.getTangentForOffset(0)!.position,
          m.getTangentForOffset(m.length)!.position,
        ],
      ];
      // The broken (horizontal) edge stops 6 px either side of the crossing; its polyline points there are drawn.
      expect(ends, contains(near(screen - const Offset(6, 0))));
      expect(ends, contains(near(screen + const Offset(6, 0))));
      // Nothing horizontal is drawn at the crossing: whatever passes it runs vertically (the whole edge $other).
      for (final m in drawn) {
        for (double d = 0; d <= m.length; d += .5) {
          final Tangent t = m.getTangentForOffset(d)!;
          if ((t.position - screen).distance < .3) {
            expect(t.vector.dx.abs(), lessThan(1e-3), reason: 'edge $broken is drawn at the crossing');
          }
        }
      }
    });

    test('random windows of the synthetic 10k: cutsIn equals an all-pairs oracle; lines sharing a node never cut', () {
      final GraphEdgePainter painter = painterOf(syntheticLayout(10000));
      final RouteGeometry g = painter.geometry;
      final rng = math.Random(7);
      // The plane's width; the points' maximum is at least the lowest y.
      final plane = Rect.fromLTWH(0, 0, GraphMetrics().planeWidth(painter.layout.colCount), g.points.reduce(math.max));
      var offScreenVertical = false;
      var total = 0;
      for (var w = 0; w < 40; w++) {
        final window = Rect.fromLTWH(
          rng.nextDouble() * math.max(0, plane.width - 800),
          rng.nextDouble() * math.max(0, plane.height - 600),
          800,
          600,
        );
        final Set<(int, double, double, bool)> expected = oracleCuts(g, painter.edgesIn(window), window.inflate(6));
        total += expected.length;
        expect(cutSet(painter.cutsIn(window)), expected);
        // A crossing whose vertical starts above the window.
        for (var q = 0; q < g.verticalXs.length && !offScreenVertical; q++) {
          if (g.verticalTops[q] < window.top - 6 &&
              expected.any((c) => c.$2 == g.verticalXs[q] && c.$3 > g.verticalTops[q] && c.$3 < g.verticalBottoms[q])) {
            offScreenVertical = true;
          }
        }
      }
      expect(total, greaterThan(0));
      expect(offScreenVertical, isTrue);
    });

    test('two lines sharing a node that cross are not cut', () {
      var found = 0;
      for (final layout in <GraphLayout>[
        for (final name in graphRecordingNames) recording(name),
        syntheticLayout(10000),
      ]) {
        final GraphEdgePainter painter = painterOf(layout);
        final RouteGeometry g = painter.geometry;
        final Int32List froms = g.classes.edgeFroms;
        final Int32List tos = g.classes.edgeTos;
        // Every horizontal run against the verticals in its x-range (sorted by x), inside both runs by 1 px.
        for (var h = 0; h < g.horizontalYs.length; h++) {
          final double hy = g.horizontalYs[h];
          final int he = g.horizontalEdges[h];
          for (var v = 0; v < g.verticalXs.length; v++) {
            final double vx = g.verticalXs[v];
            if (vx <= g.horizontalLefts[h] + 1) {
              continue;
            }
            if (vx >= g.horizontalRights[h] - 1) {
              break;
            }
            final int ve = g.verticalEdges[v];
            final bool shares =
                froms[he] == froms[ve] || tos[he] == tos[ve] || froms[he] == tos[ve] || tos[he] == froms[ve];
            if (!shares || hy <= g.verticalTops[v] + 1 || hy >= g.verticalBottoms[v] - 1) {
              continue;
            }
            found++;
            final Set<(int, double, double, bool)> cuts = cutSet(
              painter.cutsIn(Rect.fromCenter(center: Offset(vx, hy), width: 100, height: 100)),
            );
            expect(cuts.where((c) => c.$2 == vx && c.$3 == hy && (c.$1 == he || c.$1 == ve)), isEmpty);
          }
        }
      }
      expect(found, greaterThan(0));
    });
  });

  group('classification', () {
    // r ← a, r ← b, m ← (a, b), @ w ← m; x ← b is a side branch off @'s lineage.
    RecordedGraphLayout merge() => handLayout(
      <(String, int, int)>[('r', 0, 0), ('a', 1, 0), ('b', 1, 1), ('m', 2, 0), ('w', 3, 0), ('x', 2, 2)],
      edges: <(int, int)>[(1, 0), (2, 0), (3, 1), (3, 2), (4, 3), (5, 2)],
      workingCopy: 4,
      parentCounts: <int>[0, 1, 1, 2, 1, 1],
    );

    test('every ancestor edge of @, the merged side branch included, is lineage', () {
      final RecordedGraphLayout layout = merge();
      final GraphEdgePainter painter = painterOf(layout);
      for (var k = 0; k < layout.edgeCount; k++) {
        final side = layout.keyOf(layout.childOf(k)) == 'x';
        expect(
          painter.classify(k, const GraphEdgeHighlight()).tone,
          side ? GraphEdgeTone.normal : GraphEdgeTone.lineage,
        );
        expect(painter.classify(k, const GraphEdgeHighlight(lineage: false)).tone, GraphEdgeTone.normal);
      }
    });

    test('no @ in the layout: no lineage edges', () {
      final RecordedGraphLayout layout = chainLayout(5);
      final GraphEdgePainter painter = painterOf(layout);
      expect(
        List<int>.generate(
          layout.edgeCount,
          (k) => k,
        ).where((k) => painter.classify(k, const GraphEdgeHighlight()).tone == GraphEdgeTone.lineage),
        isEmpty,
      );
    });

    test('focus on: exactly the edges inside the focus set are hovered, every other dimmed', () {
      final RecordedGraphLayout layout = merge();
      final GraphEdgePainter painter = painterOf(layout);
      // {a, m}: only the edge m ← a lies inside.
      final focus = Uint8List(layout.nodeCount)
        ..[1] = 1
        ..[3] = 1;
      final highlight = GraphEdgeHighlight(focus: focus, dim: 1, lineage: false);
      for (var k = 0; k < layout.edgeCount; k++) {
        final bool inside = layout.childOf(k) == 3 && layout.parentOf(k) == 1;
        expect(painter.classify(k, highlight), (
          tone: inside ? GraphEdgeTone.hovered : GraphEdgeTone.normal,
          dimmed: !inside,
        ));
      }
    });

    test('focus off, hovered c: the edges touching c are hovered, none dimmed', () {
      final RecordedGraphLayout layout = merge();
      final GraphEdgePainter painter = painterOf(layout);
      const highlight = GraphEdgeHighlight(hoveredNode: 2, lineage: false);
      for (var k = 0; k < layout.edgeCount; k++) {
        final bool touches = layout.childOf(k) == 2 || layout.parentOf(k) == 2;
        expect(painter.classify(k, highlight), (
          tone: touches ? GraphEdgeTone.hovered : GraphEdgeTone.normal,
          dimmed: false,
        ));
      }
    });

    testWidgets('a viewport paint draws normal, then hovered, then the lineage (glow, 2.25 px stroke) last', (
      tester,
    ) async {
      final RecordedGraphLayout layout = merge();
      final GraphEdgePainter painter = painterOf(layout);
      final harness = GraphHarness(layout)
        ..edges = (context, origin, visible) =>
            painter.paint(context, origin, visible, highlight: const GraphEdgeHighlight(hoveredNode: 5));
      await pumpGraph(tester, harness);
      final RenderGraphViewport render = harness.render(tester);
      expect(
        render,
        paints
          ..path(color: GraphTheme.night.edgeHover, strokeWidth: 1.5)
          ..path(color: GraphTheme.night.lineageGlow, strokeWidth: 2.25)
          ..path(color: GraphTheme.night.lineage, strokeWidth: 2.25),
      );
      // One drawPath per non-empty group: hovered (x ← b) and the lineage's two; no normal edge here.
      expect(render, paintsExactlyCountTimes(#drawPath, 3));
    });

    testWidgets(
      'with a focus set half faded: normal dimmed, then the lineage, then the lineage dimmed, one path each',
      (
        tester,
      ) async {
        final RecordedGraphLayout layout = merge();
        final GraphEdgePainter painter = painterOf(layout);
        // {b, m}: m ← b is inside (lineage beats hovered); x ← b is dimmed normal; the other lineage edges are dimmed.
        final focus = Uint8List(layout.nodeCount)
          ..[2] = 1
          ..[3] = 1;
        final harness = GraphHarness(layout)
          ..edges = (context, origin, visible) =>
              painter.paint(context, origin, visible, highlight: GraphEdgeHighlight(focus: focus, dim: .5));
        await pumpGraph(tester, harness);
        // Halfway through the fade: alpha × (1 − .72 · .5) = × .64.
        const double fade = 1 - .72 * .5;
        Color dim(Color color) => color.withValues(alpha: color.a * fade);
        final GraphTheme theme = GraphTheme.night;
        expect(
          harness.render(tester),
          paints
            ..path(color: dim(theme.edge), strokeWidth: 1.5)
            ..path(color: theme.lineageGlow, strokeWidth: 2.25)
            ..path(color: theme.lineage, strokeWidth: 2.25)
            ..path(color: dim(theme.lineageGlow), strokeWidth: 2.25)
            ..path(color: dim(theme.lineage), strokeWidth: 2.25),
        );
        expect(harness.render(tester), paintsExactlyCountTimes(#drawPath, 5));
      },
    );
  });

  group('virtualization and hit lookup', () {
    late RecordedGraphLayout big;
    late RouteGeometry geometry;

    setUpAll(() async {
      big = syntheticLayout(100000);
      final FutureOr<RouteGeometry> result = routeGraph(big, GraphMetrics());
      // Above the sync limit the geometry is routed on another isolate.
      expect(big.nodeCount, greaterThan(routeSyncNodeLimit));
      expect(result, isA<Future<RouteGeometry>>());
      geometry = await result;
    });

    test('100k: edgesIn is exactly the edges whose bounds meet the window + 8 px; a long straight edge is in', () {
      final painter = GraphEdgePainter(layout: big, geometry: geometry, theme: GraphTheme.night);
      final bounds = <Rect>[
        for (var k = 0; k < big.edgeCount; k++)
          polyline(geometry, k).fold<Rect?>(
            null,
            (r, o) => r?.expandToInclude(Rect.fromLTWH(o.dx, o.dy, 0, 0)) ?? Rect.fromLTWH(o.dx, o.dy, 0, 0),
          )!,
      ];
      bool meets(Rect b, Rect w) => b.left <= w.right && b.right >= w.left && b.top <= w.bottom && b.bottom >= w.top;
      // The longest straight (2-point) edge, and a window in its middle.
      var longest = 0;
      for (var k = 0; k < big.edgeCount; k++) {
        if (geometry.pointStarts[k + 1] - geometry.pointStarts[k] == 2 && bounds[k].height > bounds[longest].height) {
          longest = k;
        }
      }
      expect(bounds[longest].height, greaterThan(1200));
      final rng = math.Random(3);
      final windows = <Rect>[
        Rect.fromCenter(center: bounds[longest].center, width: 800, height: 600),
        for (var i = 0; i < 5; i++)
          Rect.fromLTWH(rng.nextDouble() * 4000, rng.nextDouble() * geometry.points.reduce(math.max), 800, 600),
      ];
      for (final window in windows) {
        final Rect grown = window.inflate(8);
        expect(painter.edgesIn(window), <int>[
          for (var k = 0; k < big.edgeCount; k++)
            if (meets(bounds[k], grown)) k,
        ]);
      }
      expect(painter.edgesIn(windows.first), contains(longest));
    });

    test('a shared entry slot: edgesAt on its stem returns both edges; a single line one; away from lines none', () {
      // c (one real parent) reaches p1 and p2 through hidden commits: two Indirect edges, one slot.
      final RecordedGraphLayout layout = handLayout(
        <(String, int, int)>[('p1', 0, 0), ('p2', 0, 2), ('c', 2, 1)],
        edges: <(int, int)>[(2, 0), (2, 1)],
        indirect: <int>{0, 1},
        parentCounts: <int>[0, 0, 1],
      );
      final GraphEdgePainter painter = painterOf(layout);
      final RouteGeometry g = painter.geometry;
      expect(g.classes.slots[1], g.classes.slots[0]);
      final Offset stem = polyline(g, 0).last + const Offset(0, 3);
      expect(painter.edgesAt(stem), <int>[0, 1]);
      final List<Offset> first = polyline(g, 0);
      expect(painter.edgesAt(Offset.lerp(first[0], first[1], .5)!), <int>[0]);
      expect(painter.edgesAt(const Offset(-500, -500)), isEmpty);
    });
  });

  test(
    '> 20k nodes: GraphRouteCache routes on another isolate and drops a result superseded by a metrics change',
    () async {
      final RecordedGraphLayout layout = syntheticLayout(30000);
      var routed = 0;
      final cache = GraphRouteCache(onRouted: () => routed++);
      final first = GraphMetrics();
      final latest = GraphMetrics(cardWidth: 300);
      expect(cache.geometryFor(layout, first), isNull);
      expect(cache.geometryFor(layout, first), isNull, reason: 'still in flight');
      expect(cache.geometryFor(layout, latest), isNull, reason: 'supersedes the first request');
      await cache.settled();
      expect(routed, 1);
      final RouteGeometry? geometry = cache.geometryFor(layout, latest);
      expect(geometry?.metrics.width, 300);
      // After dispose a result is dropped.
      expect(cache.geometryFor(layout, first), isNull);
      cache.dispose();
      await cache.settled();
      expect(routed, 1);
    },
  );

  test('≤ 20k nodes: GraphRouteCache answers at once and a W change reuses the classes', () {
    final RecordedGraphLayout layout = recording('design-all compact compact');
    var routed = 0;
    final cache = GraphRouteCache(onRouted: () => routed++);
    final RouteGeometry? a = cache.geometryFor(layout, GraphMetrics());
    final RouteGeometry? b = cache.geometryFor(layout, GraphMetrics(cardWidth: 400));
    expect(a, isNotNull);
    expect(identical(b?.classes, a?.classes), isTrue);
    expect(identical(cache.geometryFor(layout, GraphMetrics(cardWidth: 400)), b), isTrue);
    expect(routed, 0);
  });

  test('GraphRouteCache keeps the classes per layout: another layout at the same metrics gets its own', () {
    final cache = GraphRouteCache(onRouted: () {});
    final metrics = GraphMetrics();
    final RecordedGraphLayout a = recording('design-all compact compact');
    final RecordedGraphLayout b = recording('medium-narrow compact compact');
    final RouteGeometry ga = cache.geometryFor(a, metrics)!;
    final RouteGeometry gb = cache.geometryFor(b, metrics)!;
    expect(identical(gb.classes, ga.classes), isFalse);
    expect(gb.classes.edgeCount, b.edgeCount);
    expect(gb.classes.nodeRows.length, b.nodeCount);
  });

  test('an overflowing shared exit: edgesAt on its stub returns the lines leaving there together', () {
    // p has 8 children to its right at W 160: exits 18–60 px from its centre, 7 px apart, the outer ones share one.
    final RecordedGraphLayout layout = handLayout(
      <(String, int, int)>[('p', 0, 0), for (var c = 1; c <= 8; c++) ('c$c', 1, c)],
      edges: <(int, int)>[for (var c = 1; c <= 8; c++) (c, 0)],
      parentCounts: <int>[0, for (var c = 1; c <= 8; c++) 1],
    );
    final GraphEdgePainter painter = painterOf(layout, metrics: GraphMetrics(cardWidth: 160));
    final RouteGeometry g = painter.geometry;
    final byExit = <Offset, List<int>>{};
    for (var k = 0; k < layout.edgeCount; k++) {
      (byExit[polyline(g, k).first] ??= <int>[]).add(k);
    }
    final List<int> shared = byExit.values.singleWhere((edges) => edges.length > 1);
    final Offset stub = polyline(g, shared.first).first - const Offset(0, 2);
    expect(painter.edgesAt(stub), shared);
  });

  testWidgets('an empty layout paints nothing', (tester) async {
    final RecordedGraphLayout layout = handLayout(const <(String, int, int)>[]);
    final GraphEdgePainter painter = painterOf(layout);
    expect(painter.edgesIn(const Rect.fromLTWH(0, 0, 800, 600)), isEmpty);
    final harness = GraphHarness(layout)..edges = painter.paint;
    await pumpGraph(tester, harness);
    expect(harness.render(tester), paintsExactlyCountTimes(#drawPath, 0));
  });

  testWidgets('Story 10.20: only and except pick the edges; drawn strokes that part of each, from its parent end', (
    tester,
  ) async {
    final RecordedGraphLayout layout = chainLayout(4, cols: 2);
    final GraphEdgePainter painter = painterOf(layout);
    const window = Rect.fromLTWH(0, 0, 800, 600);
    double length(int k) => painter.strokePath(k, window).computeMetrics().fold<double>(0, (sum, m) => sum + m.length);
    final harness = GraphHarness(layout);
    await pumpGraph(tester, harness);
    Future<List<PathMetric>> painted({Set<int>? only, Set<int>? except, double drawn = 1}) async {
      harness.edges = (context, origin, visible) =>
          painter.paint(context, origin, visible, only: only, except: except, drawn: drawn);
      await tester.pumpWidget(harness.build());
      final metrics = <PathMetric>[];
      expect(
        harness.render(tester),
        paints..everything((method, args) {
          if (method == #drawPath) {
            metrics.addAll((args[0] as Path).computeMetrics());
          }
          return true;
        }),
      );
      return metrics;
    }

    double total(List<PathMetric> metrics) => metrics.fold<double>(0, (sum, m) => sum + m.length);
    expect(layout.edgeCount, 3);
    expect(total(await painted(only: <int>{1})), moreOrLessEquals(length(1)));
    expect(total(await painted(except: <int>{1})), moreOrLessEquals(length(0) + length(2)));
    final List<PathMetric> half = await painted(only: <int>{1}, drawn: .5);
    expect(total(half), moreOrLessEquals(length(1) / 2));
    expect(half.first.getTangentForOffset(0)!.position, near(polyline(painter.geometry, 1).first));
    expect(await painted(only: <int>{1}, drawn: 0), isEmpty);
  });
}
