// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_edges.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/layout_invariants.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';
import 'package:zanshin_core/zanshin_core.dart' show RouteClasses, RouteGeometry;

import '../../../widgetbook/graph/graph_recordings.g.dart';
import '../../../widgetbook/graph/synthetic_layout.dart';
import 'graph_harness.dart';

Set<LayoutInvariant> violated(GraphLayout layout, {VerticalLayout? vertical}) =>
    checkLayoutInvariants(layout, vertical: vertical).map((v) => v.invariant).toSet();

void main() {
  group('(p) every fixture passes the hard invariants', () {
    for (final String name in graphRecordingNames) {
      test(name, () => expect(checkLayoutInvariants(recording(name)), isEmpty));
    }
    for (final int size in syntheticSizes) {
      for (final free in <bool>[false, true]) {
        test('synthetic $size ${free ? 'free' : 'compact'}', () {
          final RecordedGraphLayout layout = syntheticLayout(size, free: free);
          expect(layout.nodeCount, size);
          expect(layout.unit, free ? 16 : 1);
          expect(layout.colCount, greaterThanOrEqualTo(100));
          expect(checkLayoutInvariants(layout), isEmpty);
          final ({bool merge, bool indirect, bool stub}) has = (
            merge: List<int>.generate(layout.edgeCount, (e) => e).any((e) => layout.shapeOf(e) == GraphEdgeShape.merge),
            indirect: List<int>.generate(
              layout.edgeCount,
              (e) => e,
            ).any((e) => layout.kindOf(e) == GraphEdgeKind.indirect),
            stub: List<int>.generate(layout.nodeCount, (i) => i).any(layout.elidedOf),
          );
          expect(has, (merge: true, indirect: true, stub: true));
        });
      }
    }
    test("the catalogue's long history: shortened like the worker's, with a break per quiet stretch", () {
      final RecordedGraphLayout layout = syntheticLayout(1500, free: true, lanes: 6, longGapEvery: 75);
      expect(checkLayoutInvariants(layout), isEmpty);
      expect(layout.breaks, isNotEmpty);
      for (final GraphBreak cut in layout.breaks) {
        expect(cut.upperRow - cut.lowerRow, 24, reason: '$cut: 1½ pitches card to card');
        expect(cut.t1! - cut.t0!, greaterThan(400 * 86400000), reason: '$cut: spans the 400 quiet days');
      }
      // Without the gaps nothing is cut; the generator's rows and its other output stay as they were.
      expect(syntheticLayout(10000, free: true).breaks, isEmpty);
    });

    test('the synthetic generator is deterministic', () {
      final RecordedGraphLayout a = syntheticLayout(10000);
      final RecordedGraphLayout b = syntheticLayout(10000);
      for (var i = 0; i < a.nodeCount; i += 97) {
        expect((b.keyOf(i), b.rowOf(i), b.colOf(i)), (a.keyOf(i), a.rowOf(i), a.colOf(i)));
      }
      expect(b.edgeCount, a.edgeCount);
    });
  });

  group('(p) the checker rejects hand-built violations', () {
    test("two nodes in one (row, col) cell: the prototype's r at 13:59 and k←r at 13:55", () {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('k', 1, 0), ('r', 1, 0), ('base', 0, 0)],
        edges: const <(int, int)>[(0, 1), (1, 2)],
      );
      expect(violated(layout), contains(LayoutInvariant.noOverlappingCards));
    });

    test('a child placed below its parent', () {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('child', 0, 0), ('parent', 1, 1)],
        edges: const <(int, int)>[(0, 1)],
      );
      expect(violated(layout), <LayoutInvariant>{LayoutInvariant.childAboveParent});
    });

    test('a duplicate (child, parent) edge', () {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('child', 1, 0), ('parent', 0, 0)],
        edges: const <(int, int)>[(0, 1), (0, 1)],
      );
      expect(violated(layout), <LayoutInvariant>{LayoutInvariant.noDuplicateEdge});
    });

    test('a dangling edge', () {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('child', 1, 0), ('parent', 0, 0)],
        edges: const <(int, int)>[(0, 1), (1, 7)],
      );
      expect(violated(layout), <LayoutInvariant>{LayoutInvariant.noDanglingEdge});
    });

    test('a repeated key', () {
      final RecordedGraphLayout layout = handLayout(const <(String, int, int)>[('same', 1, 0), ('same', 0, 0)]);
      expect(violated(layout), <LayoutInvariant>{LayoutInvariant.uniqueKeys});
    });

    test('free cards closer than one pitch in a column', () {
      final RecordedGraphLayout layout = handLayout(const <(String, int, int)>[('a', 20, 0), ('b', 5, 0)], unit: 16);
      expect(violated(layout), <LayoutInvariant>{LayoutInvariant.noOverlappingCards});
      expect(violated(handLayout(const <(String, int, int)>[('a', 21, 0), ('b', 5, 0)], unit: 16)), isEmpty);
    });

    test("free: day buckets that meet, 23:50 and 00:10 in two columns (Story 4.16's day band)", () {
      const day = 86400000;
      // Root 0, A (day 1) and B (day 2) both its children, in two columns.
      RecordedGraphLayout layout(int rowB) => handLayout(
        <(String, int, int)>[('b', rowB, 1), ('a', 16, 0), ('root', 0, 0)],
        edges: const <(int, int)>[(0, 2), (1, 2)],
        unit: 16,
        root: 2,
        buckets: <(int, int, int)>[(day, 16, 16), (2 * day, rowB, rowB)],
      );
      expect(violated(layout(24)), <LayoutInvariant>{LayoutInvariant.dayBandClear});
      expect(violated(layout(32)), isEmpty);
    });

    test('PerNodeTops: overlapping tops in a column, and a child less than a pitch above its parent', () {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('child', 1, 0), ('parent', 0, 0), ('other', 0, 1)],
        edges: const <(int, int)>[(0, 1)],
      );
      final metrics = GraphMetrics();
      expect(
        violated(layout, vertical: PerNodeTops(layout, metrics, Float64List.fromList(<double>[56, 166, 56]))),
        isEmpty,
      );
      expect(
        violated(layout, vertical: PerNodeTops(layout, metrics, Float64List.fromList(<double>[56, 100, 56]))),
        <LayoutInvariant>{LayoutInvariant.childAboveParent, LayoutInvariant.noOverlappingCards},
      );
    });
  });

  group('route report (Story 10.4)', () {
    RouteGeometry routed(GraphLayout layout) => routeGraph(layout, GraphMetrics()) as RouteGeometry;

    for (final String name in graphRecordingNames) {
      final compact = name.split(' ')[1] == 'compact';
      test('$name ${compact ? 'passes the Compact gate' : 'reports without failing'}', () {
        final RouteGeometry g = routed(recording(name));
        final RouteReport report = checkRoutes(g, gate: compact);
        expect(report.passes, isTrue, reason: '$report');
        expect(report.collinear, 0);
        if (compact) {
          expect(report.behindCard + report.behindCardExplained, 0);
        }
      });
    }

    test('a synthetic free layout reports its router fallbacks without failing', () {
      final RouteGeometry g = routed(syntheticLayout(10000, free: true));
      final RouteReport report = checkRoutes(g, gate: false);
      expect(report.passes, isTrue, reason: '$report');
      expect(report.directFallbacks, g.classes.directFallbacks);
      expect(report.overfullGutters, g.classes.overfullGutters);
      expect(report.overfullClusters, g.overfullClusters);
      expect(report.directFallbacks + report.overfullGutters + report.overfullClusters, greaterThan(0));
    });

    test('a gutter with more than 9 lines in Compact fails, its hits explained', () {
      // c (row 11) has 11 parents in its own column: the first enters straight, the other 10 share gutter 1, whose
      // outermost line (step +5, +30 px) runs 2 px inside column 1, behind y. At W 400 the 10 entries fit their side.
      final RecordedGraphLayout layout = handLayout(
        <(String, int, int)>[for (var i = 0; i < 11; i++) ('p$i', i, 0), ('y', 10, 1), ('c', 11, 0)],
        edges: <(int, int)>[(12, 10), for (var i = 0; i < 10; i++) (12, i)],
        parentCounts: <int>[for (var i = 0; i < 12; i++) 0, 11],
      );
      final g = routeGraph(layout, GraphMetrics(cardWidth: 400)) as RouteGeometry;
      expect(g.classes.overfullGutters, 1);
      final RouteReport report = checkRoutes(g, gate: true);
      expect(report.passes, isFalse);
      expect(report.behindCard, 0, reason: '$report');
      expect(report.behindCardExplained, greaterThan(0));
      expect(report.collinear, 0);
    });

    test('a collinear overlap of unshared lines fails; shared lines may overlap', () {
      RouteReport check(Int32List slots, Int32List froms) => checkRouteLines(
        pointStarts: Int32List.fromList(<int>[0, 4, 8]),
        points: Float64List.fromList(<double>[0, 0, 0, -50, 100, -50, 100, -100, 50, 0, 50, -50, 150, -50, 150, -100]),
        edgeFroms: froms,
        edgeTos: Int32List.fromList(<int>[2, 3]),
        slots: slots,
        cardLefts: Float64List(4)..fillRange(0, 4, double.nan),
        cardTops: Float64List(4)..fillRange(0, 4, double.nan),
        cardWidth: 240,
        cardHeight: 62,
        explained: Uint8List(2),
        gate: true,
      );
      final RouteReport unshared = check(Int32List.fromList(<int>[0, 1]), Int32List.fromList(<int>[0, 1]));
      expect((unshared.collinear, unshared.passes), (1, false));
      final RouteReport sameSlot = check(Int32List.fromList(<int>[0, 0]), Int32List.fromList(<int>[0, 1]));
      expect((sameSlot.collinear, sameSlot.passes), (0, true));
    });

    test('two lines of one parent leaving one exit point may overlap on the exit stub', () {
      // Both leave (0, 0) and climb to (0, −50) together, then part.
      final RouteReport report = checkRouteLines(
        pointStarts: Int32List.fromList(<int>[0, 4, 8]),
        points: Float64List.fromList(<double>[0, 0, 0, -50, -100, -50, -100, -100, 0, 0, 0, -50, 100, -50, 100, -100]),
        edgeFroms: Int32List.fromList(<int>[0, 0]),
        edgeTos: Int32List.fromList(<int>[1, 2]),
        slots: Int32List.fromList(<int>[0, 1]),
        cardLefts: Float64List(3)..fillRange(0, 3, double.nan),
        cardTops: Float64List(3)..fillRange(0, 3, double.nan),
        cardWidth: 240,
        cardHeight: 62,
        explained: Uint8List(2),
        gate: true,
      );
      expect((report.collinear, report.passes), (0, true));
    });

    test('D11 (I2): a fork over a lower card in the child column climbs a gutter, no behind-card hit', () {
      // p ← x in column 1 at row 1 sits between p (row 0) and its child c (row 2, column 1).
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('p', 0, 0), ('x', 1, 1), ('c', 2, 1)],
        edges: const <(int, int)>[(1, 0), (2, 0)],
        parentCounts: const <int>[0, 1, 1],
      );
      final RouteGeometry g = routed(layout);
      expect(g.classes.kinds[1], RouteClasses.kindGutter);
      final RouteReport report = checkRoutes(g, gate: true);
      expect(report.behindCard + report.behindCardExplained, 0);
      expect(report.passes, isTrue);
    });

    test('an empty layout passes', () {
      expect(checkRoutes(routed(handLayout(const <(String, int, int)>[])), gate: true).passes, isTrue);
    });
  });
}
