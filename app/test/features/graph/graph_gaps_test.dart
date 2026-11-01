// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:ui' show PictureRecorder;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_edges.dart';
import 'package:zanshin/src/features/graph/graph_gap_callout.dart';
import 'package:zanshin/src/features/graph/graph_gaps.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart' show GraphFlash, GraphGapTarget;
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';
import 'package:zanshin_core/zanshin_core.dart' show RouteGeometry;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../../widgetbook/graph/graph_recordings.g.dart';
import '../../../widgetbook/graph/synthetic_layout.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart' show showEntryOf;
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

typedef _Placed = ({GraphLayout layout, RouteGeometry geometry, VerticalLayout rows, GraphGaps gaps});

_Placed _place(GraphLayout layout, {GraphMetrics? metrics, double clearance = 12}) {
  final GraphMetrics m = metrics ?? GraphMetrics();
  final rows = UniformRows(layout, m, bottomExtra: graphGapsBottomExtraOf(layout));
  final geometry = routeGraph(layout, m) as RouteGeometry;
  return (
    layout: layout,
    geometry: geometry,
    rows: rows,
    gaps: GraphGaps.compute(layout: layout, geometry: geometry, rows: rows, clearance: clearance),
  );
}

/// [edge]'s polyline points without repeats.
List<Offset> _polyline(RouteGeometry g, int edge) {
  final out = <Offset>[];
  for (int q = g.pointStarts[edge]; q < g.pointStarts[edge + 1]; q++) {
    final p = Offset(g.points[2 * q], g.points[2 * q + 1]);
    if (out.isEmpty || out.last != p) {
      out.add(p);
    }
  }
  return out;
}

/// Checks every scanned marker's clearance by brute force (independent of the placement's indexes): its centre keeps
/// clearance + 4 (the cut's half length) of line to every card on its run, every bend, every crossing or junction of
/// another edge, and every earlier mark within the clearance across; and no other edge shares its run there.
List<String> _violations(_Placed p) {
  final double c = p.gaps.clearance;
  final GraphLayout layout = p.layout;
  final RouteGeometry g = p.geometry;
  final out = <String>[];
  final List<GraphGap> gaps = p.gaps.gaps;
  final lines = <List<Offset>>[for (var k = 0; k < layout.edgeCount; k++) _polyline(g, k)];
  for (var i = 0; i < gaps.length; i++) {
    final GraphGap gap = gaps[i];
    if (gap.isStub || gap.kind == GraphGapKind.hiddenMerge || gap.fallback) {
      continue;
    }
    final int edge = gap.edges.single;
    final List<Offset> line = lines[edge];
    final Offset at = gap.point;
    var seg = -1;
    for (var s = 0; s + 1 < line.length; s++) {
      final Rect r = Rect.fromPoints(line[s], line[s + 1]).inflate(.01);
      if (r.contains(at)) {
        seg = s;
      }
    }
    if (seg < 0) {
      out.add('gap $i is off its edge');
      continue;
    }
    final Offset a = line[seg];
    final Offset b = line[seg + 1];
    final horizontal = a.dy == b.dy;
    double along(Offset q) => horizontal ? (q.dx - at.dx).abs() : (q.dy - at.dy).abs();
    double across(Offset q) => horizontal ? (q.dy - at.dy).abs() : (q.dx - at.dx).abs();
    if (along(a) < c + 4 || along(b) < c + 4) {
      out.add('gap $i sits ${math.min(along(a), along(b))} from its segment end');
    }
    for (var n = 0; n < layout.nodeCount; n++) {
      if (layout.rowOf(n) < 0) {
        continue;
      }
      final card = Rect.fromLTWH(
        p.rows.metrics.x(layout.colOf(n)),
        p.rows.top(n),
        p.rows.metrics.cardWidth,
        p.rows.metrics.cardHeight,
      );
      final lane = horizontal
          ? Rect.fromLTRB(card.left, at.dy - 6, card.right, at.dy + 6)
          : Rect.fromLTRB(at.dx - 6, card.top, at.dx + 6, card.bottom);
      if (!card.overlaps(lane)) {
        continue;
      }
      final double gapToCard = horizontal
          ? math.max(card.left - at.dx, at.dx - card.right)
          : math.max(card.top - at.dy, at.dy - card.bottom);
      if (gapToCard < c + 4) {
        out.add('gap $i sits $gapToCard from card $n');
      }
    }
    for (var k = 0; k < layout.edgeCount; k++) {
      if (k == edge) {
        continue;
      }
      final List<Offset> other = lines[k];
      for (var s = 0; s + 1 < other.length; s++) {
        final Offset u = other[s];
        final Offset v = other[s + 1];
        final oh = u.dy == v.dy;
        if (oh != horizontal) {
          // A crossing or a T junction on the marker's run.
          final x = horizontal ? Offset(u.dx, at.dy) : Offset(at.dx, u.dy);
          final Rect run = Rect.fromPoints(u, v).inflate(1);
          final Rect mine = Rect.fromPoints(a, b).inflate(1);
          if (run.contains(x) && mine.contains(x) && along(x) < c + 4) {
            out.add('gap $i sits ${along(x)} from a crossing with edge $k');
          }
        } else if (across(u) <= 3) {
          final double lo = horizontal ? math.min(u.dx, v.dx) : math.min(u.dy, v.dy);
          final double hi = horizontal ? math.max(u.dx, v.dx) : math.max(u.dy, v.dy);
          final double pos = horizontal ? at.dx : at.dy;
          if (pos >= lo - 5 && pos <= hi + 5) {
            out.add('gap $i sits on a run shared with edge $k');
          }
        }
      }
    }
    for (var j = 0; j < i; j++) {
      final Offset q = gaps[j].point;
      if (across(q) <= c && along(q) < 3) {
        out.add('gap $i sits ${along(q)} from mark $j');
      }
    }
  }
  return out;
}

void main() {
  group('placement', () {
    for (final String name in graphRecordings.keys) {
      test('$name: every marker keeps the clearance or is the fallback', () {
        final RecordedGraphLayout layout = recording(name);
        final _Placed p = _place(layout);
        expect(_violations(p), isEmpty);
        final ({int dashed, int ends}) counts = graphGapCounts(layout);
        expect(p.gaps.gaps.where((g) => !g.isStub), hasLength(counts.dashed));
        expect(p.gaps.gaps.where((g) => g.isStub), hasLength(counts.ends));
      });
    }

    test('the design-default recording: one marker per Indirect edge, one shared marker per hidden merge', () {
      final RecordedGraphLayout layout = recording('design-default free compact');
      final _Placed p = _place(layout);
      for (var k = 0; k < layout.edgeCount; k++) {
        if (layout.kindOf(k) == GraphEdgeKind.indirect) {
          final int g = p.gaps.gapOfEdge(k)!;
          expect(p.gaps.gaps[g].edges, contains(k));
          expect(p.gaps.cuts[k], hasLength(1));
        } else {
          expect(p.gaps.gapOfEdge(k), isNull);
        }
      }
      expect(p.gaps.gaps.where((g) => g.kind == GraphGapKind.hiddenMerge), isNotEmpty);
      // The clearance witness is not vacuous: most markers come from the scan.
      final List<GraphGap> indirect = p.gaps.gaps.where((g) => g.kind == GraphGapKind.indirect).toList();
      expect(indirect.where((g) => !g.fallback).length, greaterThan(indirect.length ~/ 2));
      expect(p.gaps.gaps.where((g) => g.isStub), isNotEmpty);
    });

    test('a scale layout: 1 000 random windows return exactly the placed gaps they meet', () {
      final RecordedGraphLayout layout = syntheticLayout(10000);
      final _Placed p = _place(layout);
      expect(p.gaps.gaps, isNotEmpty);
      expect(_place(layout).gaps.gaps.map((g) => (g.x, g.y)), p.gaps.gaps.map((g) => (g.x, g.y)));
      final random = math.Random(7);
      final double width = p.rows.metrics.planeWidth(layout.colCount);
      final double height = p.rows.contentHeight;
      for (var i = 0; i < 1000; i++) {
        final window = Rect.fromLTWH(random.nextDouble() * width, random.nextDouble() * height, 800, 600);
        expect(p.gaps.gapsIn(window), <int>[
          for (var g = 0; g < p.gaps.gaps.length; g++)
            if (p.gaps.gaps[g].box.overlaps(window)) g,
        ]);
      }
    });

    test('a straight dashed edge between adjacent rows gets its marker in the middle of the row gap', () {
      final RecordedGraphLayout layout = handLayout(
        <(String, int, int)>[('a', 1, 0), ('b', 0, 0)],
        edges: <(int, int)>[(0, 1)],
        indirect: <int>{0},
        parentCounts: <int>[1, 0],
      );
      final _Placed p = _place(layout);
      final GraphGap gap = p.gaps.gaps.single;
      final double bottom = p.rows.top(0) + p.rows.metrics.cardHeight;
      expect(gap.fallback, isFalse);
      expect(gap.vertical, isTrue);
      expect(gap.y, bottom + p.rows.metrics.gapY / 2);
    });

    test('a hidden merge gets one shared marker 16–22 px under the card; several real parents never group', () {
      // a has one real parent and two Indirect edges (to b and c); d has two real parents and two Indirect edges.
      final RecordedGraphLayout layout = handLayout(
        <(String, int, int)>[('a', 3, 0), ('d', 3, 2), ('b', 0, 0), ('c', 0, 1)],
        edges: <(int, int)>[(0, 2), (0, 3), (1, 2), (1, 3)],
        indirect: <int>{0, 1, 2, 3},
        parentCounts: <int>[1, 2, 0, 0],
      );
      final _Placed p = _place(layout);
      final List<GraphGap> merges = p.gaps.gaps.where((g) => g.kind == GraphGapKind.hiddenMerge).toList();
      expect(merges, hasLength(1));
      expect(merges.single.node, 0);
      expect(merges.single.edges, hasLength(2));
      final double under = merges.single.y - (p.rows.top(0) + p.rows.metrics.cardHeight);
      expect(under, inInclusiveRange(16, 22));
      expect(p.gaps.gaps.where((g) => g.node == 1), hasLength(2));
      expect(graphGapCounts(layout).dashed, 3);
    });

    test('with no room anywhere the marker is the middle of the longest free run', () {
      final RecordedGraphLayout layout = handLayout(
        <(String, int, int)>[('a', 1, 0), ('b', 0, 0)],
        edges: <(int, int)>[(0, 1)],
        indirect: <int>{0},
        parentCounts: <int>[1, 0],
      );
      // A clearance of 22 needs more than the 48 px row gap holds; 12 px stay free between the cards' margins.
      final _Placed p = _place(layout, clearance: 22);
      final GraphGap gap = p.gaps.gaps.single;
      expect(gap.fallback, isTrue);
      final double bottom = p.rows.top(0) + p.rows.metrics.cardHeight;
      expect(gap.y, closeTo(bottom + p.rows.metrics.gapY / 2, .001));
    });
  });

  group('stubs', () {
    RecordedGraphLayout stubbed({required bool parentEdge}) {
      final RecordedGraphLayout base = handLayout(
        <(String, int, int)>[('a', 1, 0), ('b', 0, 0)],
        edges: parentEdge ? <(int, int)>[(0, 1)] : const <(int, int)>[],
        parentCounts: <int>[if (parentEdge) 2 else 1, 0],
      );
      return _withMissing(base, <int>[1, 0]);
    }

    test('a node without a parent edge gets its stub centred, the glyph 16 px under the card, the label right', () {
      final _Placed p = _place(stubbed(parentEdge: false));
      final GraphGap stub = p.gaps.gaps.single;
      final double left = p.rows.metrics.x(0);
      expect(stub.x, left + p.rows.metrics.cardWidth / 2);
      expect(stub.top, p.rows.top(0) + p.rows.metrics.cardHeight);
      expect(stub.y - stub.top, 16);
      expect(stub.label, GraphGapLabel.right);
    });

    test('a stub label goes right where free, else left, else it is left out', () {
      // Three Missing edges, no parent edge: centre, +0.28·W, −0.28·W. The centre's both label boxes meet a
      // neighbour stub, the −0.28 one's right box meets the centre.
      final RecordedGraphLayout base = handLayout(<(String, int, int)>[('a', 1, 0), ('b', 0, 0)]);
      final _Placed p = _place(_withMissing(base, <int>[3, 0]));
      final double cx = p.rows.metrics.x(0) + p.rows.metrics.cardWidth / 2;
      final labels = <int, GraphGapLabel?>{
        for (final GraphGap g in p.gaps.gaps) ((g.x - cx) / p.rows.metrics.cardWidth * 100).round(): g.label,
      };
      expect(labels, <int, GraphGapLabel?>{0: null, 28: GraphGapLabel.right, -28: GraphGapLabel.left});
    });

    test('beside a parent edge the stub takes the first slot 14 px from every entry port', () {
      final _Placed p = _place(stubbed(parentEdge: true));
      final GraphGap stub = p.gaps.gaps.single;
      final ports = <double>[
        for (int q = p.geometry.portStarts[0]; q < p.geometry.portStarts[1]; q++) p.geometry.portXs[q],
      ];
      expect(ports, isNotEmpty);
      for (final port in ports) {
        expect((stub.x - port).abs(), greaterThanOrEqualTo(14));
      }
      final double cx = p.rows.metrics.x(0) + p.rows.metrics.cardWidth / 2;
      expect(stub.x, cx + .28 * p.rows.metrics.cardWidth);
    });

    test('a layout whose lowest row holds a stubbed node gets bottomExtra 44', () {
      expect(graphGapsBottomExtraOf(stubbed(parentEdge: false)), 0);
      final RecordedGraphLayout low = _withMissing(
        handLayout(<(String, int, int)>[('a', 1, 0), ('b', 0, 0)], edges: <(int, int)>[(0, 1)]),
        <int>[0, 1],
      );
      expect(graphGapsBottomExtraOf(low), graphGapsBottomExtra);
    });
  });

  group('painting', () {
    test('every Indirect edge carries its `//` and cut, every Missing edge a stub with "~ elided"', () {
      final RecordedGraphLayout layout = recording('design-default free compact');
      final _Placed p = _place(layout);
      final edges = GraphEdgePainter(
        layout: layout,
        geometry: p.geometry,
        theme: GraphTheme.night,
        gapCuts: p.gaps.cuts,
      );
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      const all = Rect.fromLTWH(0, 0, 100000, 100000);
      final log = <String>[];
      p.gaps.paint(_LoggingCanvas(canvas, log), Offset.zero, all, edges: edges, label: '~ elided');
      recorder.endRecording().dispose();
      final int markers = p.gaps.gaps.length;
      expect(log.where((l) => l == 'line'), hasLength(2 * markers));
      // The cut: each marked edge's stroke breaks around the marker.
      for (final MapEntry<int, List<GraphEdgeCut>> cut in p.gaps.cuts.entries) {
        final Path with_ = edges.strokePath(cut.key, all);
        final Path without = GraphEdgePainter(
          layout: layout,
          geometry: p.geometry,
          theme: GraphTheme.night,
        ).strokePath(cut.key, all);
        final double length = with_.computeMetrics().fold(0, (s, m) => s + m.length);
        final double full = without.computeMetrics().fold(0, (s, m) => s + m.length);
        expect(length, lessThan(full));
      }
    });

    test('states: hover paints --text, @\'s lineage --co, the focus path dims to .28', () {
      // c (@) --dashed--> a.
      final RecordedGraphLayout layout = handLayout(
        <(String, int, int)>[('c', 1, 0), ('a', 0, 0), ('o', 1, 1)],
        edges: <(int, int)>[(0, 1)],
        indirect: <int>{0},
        parentCounts: <int>[1, 0, 0],
        workingCopy: 0,
      );
      final _Placed p = _place(layout);
      final GraphTheme theme = GraphTheme.night;
      final edges = GraphEdgePainter(layout: layout, geometry: p.geometry, theme: theme, gapCuts: p.gaps.cuts);
      Color cutColor({GraphEdgeHighlight highlight = const GraphEdgeHighlight(lineage: false), int? hovered}) {
        final log = <String>[];
        final colors = <Color>[];
        final recorder = PictureRecorder();
        p.gaps.paint(
          _LoggingCanvas(Canvas(recorder), log, colors),
          Offset.zero,
          const Rect.fromLTWH(0, 0, 4000, 4000),
          edges: edges,
          label: '~ elided',
          highlight: highlight,
          hovered: hovered,
        );
        recorder.endRecording().dispose();
        return colors.first;
      }

      expect(cutColor(), isSameColorAs(theme.gapCut));
      expect(cutColor(hovered: 0), isSameColorAs(theme.gapCutHover));
      expect(cutColor(highlight: const GraphEdgeHighlight()), isSameColorAs(theme.lineage));
      final Color dimmed = cutColor(
        highlight: GraphEdgeHighlight(lineage: false, focus: Uint8List.fromList(<int>[0, 0, 1]), dim: 1),
      );
      expect(dimmed.a, closeTo(theme.gapCut.a * .28, 1e-6));
    });
  });

  group('graphGapCalloutPosition', () {
    const area = Rect.fromLTWH(100, 50, 800, 600);
    const size = Size(320, 200);
    test('18 px right of the point and 22 px above it', () {
      expect(graphGapCalloutPosition(const Offset(300, 300), size, area), const Offset(318, 278));
    });
    test('flipped left of the point near the right edge', () {
      expect(graphGapCalloutPosition(const Offset(700, 300), size, area), const Offset(700 - 18 - 320, 278));
    });
    test('shifted inside the area at the left, top and bottom edges', () {
      // Flipped near the right edge of a narrow area, it would leave on the left: clamped to the left edge.
      expect(
        graphGapCalloutPosition(const Offset(300, 300), size, const Rect.fromLTWH(100, 50, 400, 600)).dx,
        100,
      );
      expect(graphGapCalloutPosition(const Offset(300, 60), size, area).dy, 50, reason: 'top');
      expect(graphGapCalloutPosition(const Offset(300, 640), size, area).dy, 650 - 200, reason: 'bottom');
    });
  });

  group('the canvas (callout, pans, flash)', () {
    setUpIconRegistry();

    // c (row 31) --dashed over the empty row 30--> a (row 29) → r28 … r0, all in column 0; s (row 31, column 2) has
    // a Missing parent and no parent edge.
    RecordedGraphLayout tall() => _withMissing(
      handLayout(
        <(String, int, int)>[
          ('c', 31, 0),
          ('s', 31, 2),
          ('a', 29, 0),
          for (var row = 28; row >= 0; row--) ('r$row', row, 0),
        ],
        edges: <(int, int)>[(0, 2), for (var i = 2; i < 31; i++) (i, i + 1)],
        indirect: <int>{0},
        parentCounts: <int>[1, 1, for (var i = 2; i < 32; i++) 1],
        commitIds: <String>['c', 's', 'a', for (var row = 28; row >= 0; row--) 'r$row'],
      ),
      <int>[0, 1, for (var i = 2; i < 32; i++) 0],
    );

    late GraphCardController cards;
    late List<GraphGapTarget> shown;

    Widget canvasOf(
      GraphLayout layout, {
      ValueListenable<GraphFlash?>? flash,
      ZsAppearance appearance = const ZsAppearance(),
    }) => shellHost(
      GraphCanvas(
        layout: layout,
        cards: cards,
        flash: flash,
        onShowGap: shown.add,
        showChange: (commitId) async => showEntryOf(commitId, <String>['hidden0123456789']),
      ),
      appearance: appearance,
    );

    Future<_Placed> pump(
      WidgetTester tester, {
      GraphLayout? layout,
      ValueListenable<GraphFlash?>? flash,
      ZsAppearance appearance = const ZsAppearance(),
    }) async {
      useShellWindow(tester, const Size(800, 600));
      final GraphLayout shownLayout = layout ?? tall();
      cards = GraphCardController(now: 0);
      addTearDown(cards.dispose);
      shown = <GraphGapTarget>[];
      await tester.pumpWidget(canvasOf(shownLayout, flash: flash, appearance: appearance));
      await tester.pump();
      return _place(shownLayout);
    }

    /// Rests the mouse on [at] until the callout opens.
    Future<void> openAt(WidgetTester tester, TestGesture mouse, Offset at) async {
      await mouse.moveTo(at);
      await tester.pump(const Duration(milliseconds: 390));
      await tester.pump();
      expect(find.byType(GraphGapCallout), findsOneWidget);
    }

    const away = Offset(790, 590);

    Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: at);
      addTearDown(mouse.removePointer);
      await tester.pump();
      return mouse;
    }

    testWidgets('a band, a marker and a stub open their callout after 380 ms of rest; a quick crossing opens none', (
      tester,
    ) async {
      final _Placed p = await pump(tester);
      final GraphGap marker = p.gaps.gaps.firstWhere((g) => !g.isStub);
      final GraphGap stub = p.gaps.gaps.firstWhere((g) => g.isStub);
      final double cardBottom = p.rows.top(0) + p.rows.metrics.cardHeight;
      // The band: the dashed run far below the marker.
      final band = Offset(marker.x + 3, cardBottom + 100);
      final TestGesture mouse = await mouseAt(tester, const Offset(790, 590));
      var builds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is GraphCard) {
          builds++;
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      for (final at in <Offset>[band, marker.point]) {
        await mouse.moveTo(at);
        await tester.pump(const Duration(milliseconds: 370));
        expect(find.byType(GraphGapCallout), findsNothing, reason: 'not yet');
        await tester.pump(const Duration(milliseconds: 20));
        expect(find.text('Commits hidden between these changes'), findsOneWidget);
        expect(tester.widget<ZsMenuMaterial>(find.byType(ZsMenuMaterial)).arrow, isFalse);
        // Onto the callout: it stays open.
        await mouse.moveTo(tester.getCenter(find.byType(GraphGapCallout)));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(GraphGapCallout), findsOneWidget, reason: 'held while hovered');
        await mouse.moveTo(const Offset(790, 590));
        await tester.pump(const Duration(milliseconds: 170));
        expect(find.byType(GraphGapCallout), findsOneWidget, reason: 'closes 180 ms after leaving');
        await tester.pump(const Duration(milliseconds: 20));
        expect(find.byType(GraphGapCallout), findsNothing);
      }
      expect(builds, 0, reason: 'a hover builds no card');

      // A quick crossing.
      await mouse.moveTo(band);
      await tester.pump(const Duration(milliseconds: 100));
      await mouse.moveTo(const Offset(790, 590));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(GraphGapCallout), findsNothing);

      // The stub, near the right edge: flipped left of it, its hidden parent read by one show.
      await mouse.moveTo(stub.point);
      await tester.pump(const Duration(milliseconds: 390));
      await tester.pump();
      expect(find.text('History continues outside this revset'), findsOneWidget);
      expect(find.text('parent, not in revset'), findsOneWidget);
      expect(find.text('hidden01'), findsOneWidget, reason: 'max(8) characters, no bold prefix');
      expect(tester.getRect(find.byType(GraphGapCallout)).right, lessThanOrEqualTo(stub.x - 18 + 1e-6));
      await tester.tap(find.text('Show in all()'));
      expect(shown.single.child, 's');
      expect(shown.single.commitId, 's');
      expect(shown.single.missing, isTrue);
      await mouse.moveTo(const Offset(790, 590));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a press on a band still pans', (tester) async {
      final _Placed p = await pump(tester);
      final GraphGap marker = p.gaps.gaps.firstWhere((g) => !g.isStub);
      final double cardBottom = p.rows.top(0) + p.rows.metrics.cardHeight;
      final band = Offset(marker.x + 3, cardBottom + 100);
      final RenderGraphViewport render = tester.allRenderObjects.whereType<RenderGraphViewport>().single;
      expect(render.verticalOffset.pixels, 0);
      await tester.dragFrom(band, const Offset(0, -120), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(render.verticalOffset.pixels, greaterThan(50));
    });

    testWidgets("a marker's Show in all() names the dashed edge's parent as its target", (tester) async {
      final _Placed p = await pump(tester);
      final TestGesture mouse = await mouseAt(tester, away);
      await openAt(tester, mouse, p.gaps.gaps.firstWhere((g) => !g.isStub).point);
      await tester.tap(find.text('Show in all()'));
      expect(shown.single.child, 'c');
      expect(shown.single.commitId, 'c');
      expect(shown.single.targets, <String>['a']);
      expect(shown.single.missing, isFalse);
      await mouse.moveTo(away);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets("a gap under a collapsed stack shows in all() by its oldest member's commit", (tester) async {
      // The stack of m0 (oldest) and m1 at row 2 --dashed--> a (row 0).
      final layout = RecordedGraphLayout(
        mode: GraphMode.compact,
        unit: 1,
        rows: 3,
        colCount: 1,
        keys: <String>['m1', 'm0', 'a', graphStackKey('m0')],
        cols: Int32List.fromList(<int>[-1, -1, 0, 0]),
        nodeRows: Int32List.fromList(<int>[-1, -1, 0, 2]),
        parentCounts: Int32List.fromList(<int>[1, 1, 0, 1]),
        elided: Uint8List(4),
        commitIds: const <String>['cm1', 'cm0', 'ca', 'cs'],
        edgeChildren: Int32List.fromList(<int>[3]),
        edgeParents: Int32List.fromList(<int>[2]),
        edgeKinds: const <GraphEdgeKind>[GraphEdgeKind.indirect],
        edgeShapes: const <GraphEdgeShape>[GraphEdgeShape.straight],
        runMembers: <List<int>>[
          <int>[1, 0],
        ],
        runStackNodes: <int?>[3],
      );
      final _Placed p = await pump(tester, layout: layout);
      final TestGesture mouse = await mouseAt(tester, away);
      await openAt(tester, mouse, p.gaps.gaps.single.point);
      await tester.tap(find.text('Show in all()'));
      expect(shown.single.commitId, 'cm0');
      expect(shown.single.targets, <String>['a']);
      await mouse.moveTo(away);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('an open callout closes on a pan, a new layout and a card menu', (tester) async {
      final _Placed p = await pump(tester);
      final Offset marker = p.gaps.gaps.firstWhere((g) => !g.isStub).point;
      final TestGesture mouse = await mouseAt(tester, away);

      await openAt(tester, mouse, marker);
      // On the empty canvas, clear of the callout.
      expect(tester.getRect(find.byType(GraphGapCallout)).contains(const Offset(700, 560)), isFalse);
      await tester.dragFrom(const Offset(700, 560), const Offset(0, -120), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(find.byType(GraphGapCallout), findsNothing, reason: 'a pan');
      await tester.pumpAndSettle();

      await mouse.moveTo(away);
      await tester.pumpWidget(canvasOf(tall()));
      await tester.pump(const Duration(seconds: 1));
      final RenderGraphViewport render = tester.allRenderObjects.whereType<RenderGraphViewport>().single;
      final Offset scrolled = marker - Offset(render.horizontalOffset.pixels, render.verticalOffset.pixels);
      await openAt(tester, mouse, scrolled);
      await tester.pumpWidget(canvasOf(tall()));
      expect(find.byType(GraphGapCallout), findsNothing, reason: 'a new layout');

      await mouse.moveTo(away);
      await tester.pump(const Duration(seconds: 1));
      final RenderGraphViewport now = tester.allRenderObjects.whereType<RenderGraphViewport>().single;
      await openAt(tester, mouse, marker - Offset(now.horizontalOffset.pixels, now.verticalOffset.pixels));
      cards.menuOpen.value = 'r0';
      await tester.pump();
      expect(find.byType(GraphGapCallout), findsNothing, reason: 'a card menu');
      cards.menuOpen.value = null;
      await mouse.moveTo(away);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('while a new layout is still being routed, a hover finds no gap of the old one', (tester) async {
      final _Placed p = await pump(tester);
      final Offset marker = p.gaps.gaps.firstWhere((g) => !g.isStub).point;
      final TestGesture mouse = await mouseAt(tester, away);
      // Above routeSyncNodeLimit: the route runs on another isolate and has not completed in fake time.
      await tester.pumpWidget(canvasOf(syntheticLayout(25000)));
      await mouse.moveTo(marker);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(GraphGapCallout), findsNothing);
      expect(tester.takeException(), isNull);
      await mouse.moveTo(away);
      await tester.pump(const Duration(seconds: 1));
    });

    for (final reduce in <bool>[false, true]) {
      testWidgets('the flash: 2 px + 6 px rings, held for 35 % of 2.4 s, then fading (reduce motion $reduce)', (
        tester,
      ) async {
        final flash = ValueNotifier<GraphFlash?>(null);
        addTearDown(flash.dispose);
        await pump(
          tester,
          flash: flash,
          appearance: ZsAppearance(reduceMotion: reduce),
        );
        flash.value = const GraphFlash(<String>{'c', 'a'}, 1);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        List<RRect> rings() {
          final found = <RRect>[];
          expect(
            tester.allRenderObjects.whereType<RenderGraphViewport>().single,
            paints..everything((method, args) {
              if (method == #drawDRRect) {
                found.add(args[0] as RRect);
              }
              return true;
            }),
          );
          return found;
        }

        expect(rings().map((r) => (r.width - 240) / 2), <double>[6, 2, 6, 2], reason: 'held: two cards, two rings');
        await tester.pump(const Duration(milliseconds: 1400));
        final spreads = <double>[for (final RRect r in rings()) (r.width - 240) / 2];
        expect(spreads, hasLength(4));
        if (reduce) {
          expect(spreads, <double>[6, 2, 6, 2], reason: 'a fixed size under reduce motion');
        } else {
          expect(spreads.first, lessThan(6));
        }
        await tester.pumpAndSettle();
        expect(rings(), isEmpty);
      });
    }
  });
}

/// [base] with [missing] Missing parents per node.
RecordedGraphLayout _withMissing(RecordedGraphLayout base, List<int> missing) => RecordedGraphLayout(
  mode: base.mode,
  unit: base.unit,
  rows: base.rows,
  colCount: base.colCount,
  keys: <String>[for (var i = 0; i < base.nodeCount; i++) base.keyOf(i)],
  cols: Int32List.fromList(<int>[for (var i = 0; i < base.nodeCount; i++) base.colOf(i)]),
  nodeRows: Int32List.fromList(<int>[for (var i = 0; i < base.nodeCount; i++) base.rowOf(i)]),
  parentCounts: Int32List.fromList(<int>[for (var i = 0; i < base.nodeCount; i++) base.parentCountOf(i)]),
  elided: Uint8List.fromList(missing),
  edgeChildren: Int32List.fromList(<int>[for (var k = 0; k < base.edgeCount; k++) base.childOf(k)]),
  edgeParents: Int32List.fromList(<int>[for (var k = 0; k < base.edgeCount; k++) base.parentOf(k)]),
  edgeKinds: <GraphEdgeKind>[for (var k = 0; k < base.edgeCount; k++) base.kindOf(k)],
  edgeShapes: <GraphEdgeShape>[for (var k = 0; k < base.edgeCount; k++) base.shapeOf(k)],
);

/// A canvas that logs the drawLine calls the marks make.
class _LoggingCanvas implements Canvas {
  _LoggingCanvas(this._inner, this._log, [this._colors]);

  final Canvas _inner;
  final List<String> _log;
  final List<Color>? _colors;

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    _log.add('line');
    _colors?.add(paint.color);
    _inner.drawLine(p1, p2, paint);
  }

  @override
  void drawPath(Path path, Paint paint) => _inner.drawPath(path, paint);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
