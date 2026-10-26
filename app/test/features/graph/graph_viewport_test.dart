// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';

import '../../../widgetbook/graph/synthetic_layout.dart';
import 'graph_harness.dart';

final RecordedGraphLayout big = syntheticLayout(100000);
final RecordedGraphLayout branchy = syntheticLayout(10000);
final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

Finder cardOf(String key) => find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == key, skipOffstage: false);

/// A row near [around] whose cards (at least two) all sit in two neighbouring columns. A row's nodes are consecutive,
/// so only the scan's first and last rows can be partial; they are skipped.
List<int> multiCardRow(GraphLayout layout, int around) {
  final byRow = <int, List<int>>{};
  for (var i = around; i < around + 4000; i++) {
    (byRow[layout.rowOf(i)] ??= <int>[]).add(i);
  }
  byRow
    ..remove(layout.rowOf(around))
    ..remove(layout.rowOf(around + 3999));
  return byRow.values.firstWhere((nodes) {
    if (nodes.length < 2) {
      return false;
    }
    final List<int> cols = nodes.map(layout.colOf).toList()..sort();
    return cols.last - cols.first <= 1;
  });
}

/// A key whose card is fully inside the viewport.
String fullyVisible(GraphHarness g) => g.expectedMounted(cache: 0).firstWhere((k) {
  final Rect rect = g.cardRect(g.layout.indexOfKey(k)!);
  return g.viewport.intersect(rect) == rect;
});

void main() {
  testWidgets('(a) on 100k nodes, the mounted cards are exactly the oracle and the extents precede every card', (
    tester,
  ) async {
    final g = GraphHarness(big);
    Offset? maxAtFirstCard;
    g.onCardBuild = () => maxAtFirstCard ??= Offset(g.h.position.maxScrollExtent, g.v.position.maxScrollExtent);
    await pumpGraph(tester, g);
    expect(big.unit, 1);
    expect(maxAtFirstCard, g.expectedMax);
    expect(g.expectedMax.dy, 2 * 56 + big.rows * (62 + 48) - 48 - 600, reason: "the design's formula at U = 1");
    expect(g.expectedMax.dx, 2 * 56 + big.colCount * (240 + 56) - 56 - 800);
    expect(g.mounted(tester), g.expectedMounted());
    expect(g.mounted(tester).length, inInclusiveRange(10, 40));
  });

  testWidgets('(b, c) a jump to the middle mounts only nearby nodes, every card of a multi-card row, and taps hit', (
    tester,
  ) async {
    final g = GraphHarness(big);
    await pumpGraph(tester, g);
    final String before = fullyVisible(g);
    await tester.tap(cardOf(before));
    final List<int> row = multiCardRow(big, big.nodeCount ~/ 2);
    final double left = row.map((n) => g.cardRect(n).left).reduce((a, b) => a < b ? a : b);
    g.h.jumpTo(left - 100);
    g.v.jumpTo(g.cardRect(row.first).top - 250);
    await tester.pump();
    expect(g.mounted(tester), g.expectedMounted());
    expect(g.mounted(tester), containsAll(row.map(big.keyOf)));
    for (final String key in g.mounted(tester)) {
      expect((big.rowOf(big.indexOfKey(key)!) - big.rowOf(row.first)).abs(), lessThan(12));
    }
    for (final node in row) {
      await tester.tap(cardOf(big.keyOf(node)));
    }
    expect(g.log.taps, <String>[before, ...row.map(big.keyOf)]);
  });

  group('(d) input', () {
    late GraphHarness g;
    Future<void> pumpMid(WidgetTester tester) async {
      g = GraphHarness(branchy);
      await pumpGraph(tester, g);
      g.h.jumpTo(600);
      g.v.jumpTo(5000);
      await tester.pump();
    }

    testWidgets('a mostly-vertical trackpad pan does not move horizontally', (tester) async {
      await pumpMid(tester);
      final TestGesture pan = await tester.startGesture(const Offset(400, 300), kind: PointerDeviceKind.trackpad);
      for (var step = 1; step <= 20; step++) {
        await pan.panZoomUpdate(const Offset(400, 300), pan: Offset(-0.6 * step, -12.0 * step));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pan.panZoomEnd();
      await tester.pumpAndSettle();
      expect(g.h.offset, 600);
      expect(g.v.offset, greaterThan(5200));
    }, variant: macOS);

    testWidgets('a diagonal drag moves both axes', (tester) async {
      await pumpMid(tester);
      final TestGesture drag = await tester.startGesture(const Offset(400, 300));
      for (var step = 0; step < 20; step++) {
        await drag.moveBy(const Offset(-10, -10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await tester.pumpAndSettle();
      expect(g.h.offset, greaterThan(700));
      expect(g.v.offset, greaterThan(5100));
    }, variant: macOS);

    testWidgets('a wheel event with dx and dy scrolls both axes', (tester) async {
      await pumpMid(tester);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(400, 300)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(30, 40)));
      await tester.pump();
      expect(g.scroll, const Offset(630, 5040));
    }, variant: macOS);

    testWidgets('Shift+wheel on a mouse scrolls horizontally, and so does the dx macOS sends for it', (tester) async {
      await pumpMid(tester);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(400, 300)));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 50)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(g.scroll, const Offset(650, 5000));
      await tester.sendEventToBinding(pointer.scroll(const Offset(50, 0)));
      await tester.pump();
      expect(g.scroll, const Offset(700, 5000));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 50)));
      await tester.pump();
      expect(g.scroll, const Offset(700, 5050), reason: 'a plain wheel stays vertical');
    }, variant: macOS);
  });

  group('(e) pan by drag', () {
    testWidgets('a primary mouse drag on empty canvas moves both offsets by the delta and selects nothing', (
      tester,
    ) async {
      final g = GraphHarness(branchy);
      await pumpGraph(tester, g);
      // Between columns 0 and 1: empty canvas in every row.
      const start = Offset(56 + 240 + 28, 300);
      final RenderGraphViewport render = g.render(tester);
      expect(render.isOnCard(start), isFalse);
      final TestGesture drag = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
      await drag.moveBy(const Offset(-60, -50));
      await tester.pump();
      expect(render.isPanning, isTrue);
      expect(render.cursor, SystemMouseCursors.grabbing);
      await drag.moveBy(const Offset(-40, -30));
      await drag.up();
      await tester.pump();
      expect(g.scroll, const Offset(100, 80));
      expect(render.isPanning, isFalse);
      expect(render.cursor, SystemMouseCursors.basic);
      expect(g.log.taps, isEmpty);
    }, variant: macOS);

    testWidgets('a mouse drag that starts on a card does not pan', (tester) async {
      final g = GraphHarness(branchy);
      await pumpGraph(tester, g);
      final String key = g.expectedMounted(cache: 0).first;
      final Offset centre = tester.getCenter(cardOf(key));
      expect(g.render(tester).isOnCard(centre), isTrue);
      await tester.dragFrom(centre, const Offset(-100, -80), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(g.scroll, Offset.zero);
    }, variant: macOS);

    testWidgets('a secondary-button drag does not pan', (tester) async {
      final g = GraphHarness(branchy);
      await pumpGraph(tester, g);
      await tester.dragFrom(
        const Offset(56 + 240 + 28, 300),
        const Offset(-100, -80),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      expect(g.scroll, Offset.zero);
    }, variant: macOS);

    Future<void> panBy(WidgetTester tester, Offset start) async {
      final TestGesture drag = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
      await drag.moveBy(const Offset(-60, -50));
      await tester.pump();
      await drag.moveBy(const Offset(-40, -30));
      await drag.up();
      await tester.pump();
    }

    testWidgets('with left and top insets, a drag on empty canvas pans and one on a card does not', (tester) async {
      final g = GraphHarness(branchy)..insets = const EdgeInsets.only(left: 200, top: 100);
      await pumpGraph(tester, g);
      final Offset card = tester.getCenter(cardOf(fullyVisible(g)));
      expect(g.render(tester).isOnCard(card), isTrue);
      await panBy(tester, card);
      expect(g.scroll, Offset.zero);
      // Between columns 0 and 1, past the left inset.
      const empty = Offset(200 + 56 + 240 + 28, 300);
      expect(g.render(tester).isOnCard(empty), isFalse);
      await panBy(tester, empty);
      expect(g.scroll, const Offset(100, 80));
    }, variant: macOS);

    testWidgets('a drag that starts on a card dimmed to 0 pans: it is empty canvas', (tester) async {
      final g = GraphHarness(branchy);
      await pumpGraph(tester, g);
      final int node = branchy.indexOfKey(fullyVisible(g))!;
      g.opacityOf = (n) => n == node ? 0 : 1;
      await tester.pumpWidget(g.build());
      final Offset start = g.cardRect(node).center;
      expect(g.render(tester).isOnCard(start), isFalse);
      await panBy(tester, start);
      expect(g.scroll, const Offset(100, 80));
    }, variant: macOS);

    testWidgets('a pan stops at both ends of both axes', (tester) async {
      final g = GraphHarness(branchy);
      await pumpGraph(tester, g);
      final RenderGraphViewport render = g.render(tester);
      Future<void> pan(Offset by) async {
        final Offset start = <Offset>[
          for (double x = 0; x < surface.width; x += 4) Offset(x, 300),
        ].firstWhere((p) => !render.isOnCard(p));
        final TestGesture drag = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
        await drag.moveBy(by / 2);
        await tester.pump();
        await drag.moveBy(by / 2);
        await drag.up();
        await tester.pump();
      }

      await pan(const Offset(100, 80));
      expect(g.scroll, Offset.zero);
      g
        ..h.jumpTo(g.expectedMax.dx)
        ..v.jumpTo(g.expectedMax.dy);
      await tester.pump();
      await pan(const Offset(-100, -80));
      expect(g.scroll, g.expectedMax);
    }, variant: macOS);
  });

  testWidgets('no scrollbar is shown', (tester) async {
    await pumpGraph(tester, GraphHarness(branchy));
    expect(find.byWidgetPredicate((w) => w is RawScrollbar, skipOffstage: false), findsNothing);
  }, variant: macOS);

  testWidgets('(f) on a ≥ 100-lane fixture, far-right columns are not built at h = 0, nor column 0 at the maximum', (
    tester,
  ) async {
    final g = GraphHarness(branchy);
    await pumpGraph(tester, g);
    expect(branchy.colCount, greaterThanOrEqualTo(100));
    int colOf(String key) => branchy.colOf(branchy.indexOfKey(key)!);
    // A height where the last column has a card.
    final int far = List<int>.generate(branchy.nodeCount, (i) => i).firstWhere(
      (i) => branchy.colOf(i) == branchy.colCount - 1,
    );
    g.v.jumpTo(g.cardRect(far).top - 200);
    await tester.pump();
    expect(g.mounted(tester), isNotEmpty);
    expect(g.mounted(tester).map(colOf).every((col) => col < 4), isTrue);
    g.h.jumpTo(g.h.position.maxScrollExtent);
    await tester.pump();
    expect(g.mounted(tester), contains(branchy.keyOf(far)));
    expect(g.mounted(tester).map(colOf).every((col) => col > branchy.colCount - 6), isTrue);
    expect(g.mounted(tester), g.expectedMounted());
  });

  testWidgets('(g) paint order: clip, background, edges, cards (base, @, selected, hovered), overlay', (tester) async {
    // Natural order hovered, selected, @, base: the paint order reverses it.
    final RecordedGraphLayout layout = handLayout(
      const <(String, int, int)>[('hov', 1, 0), ('sel', 1, 1), ('wc', 0, 0), ('base', 0, 1), ('dim', 0, 2)],
      workingCopy: 2,
    );
    final g = GraphHarness(layout)
      ..selected = 'sel'
      ..hovered = 'hov'
      ..opacityOf = ((node) => node == 4 ? 0 : 1)
      ..background = ((context, origin, visible) => context.canvas.drawRRect(RRect.zero, Paint()))
      ..edges = ((context, origin, visible) => context.canvas.drawPath(Path(), Paint()))
      ..overlay = ((context, origin, visible) => context.canvas.drawOval(Rect.zero, Paint()));
    await pumpGraph(tester, g);
    final calls = <Symbol>[];
    final cardNodes = <int>[];
    expect(
      g.render(tester),
      paints..everything((method, arguments) {
        calls.add(method);
        if (method == #drawRect) {
          cardNodes.add(nodeOfColor((arguments[1] as Paint).color));
        }
        return true;
      }),
    );
    expect(calls.indexOf(#clipRect), isNonNegative);
    expect(calls.indexOf(#clipRect), lessThan(calls.indexOf(#drawRRect)));
    expect(calls.indexOf(#drawRRect), lessThan(calls.indexOf(#drawPath)));
    expect(calls.indexOf(#drawPath), lessThan(calls.indexOf(#drawParagraph)));
    expect(calls.lastIndexOf(#drawParagraph), lessThan(calls.indexOf(#drawOval)));
    expect(cardNodes, <int>[3, 2, 1, 0], reason: 'base, @, selected, hovered; the dimmed-out card is not painted');
  });

  testWidgets('(g) a rebuild after the first frame updates the z-order and swaps the paint hooks', (tester) async {
    final g = GraphHarness(handLayout(const <(String, int, int)>[('a', 0, 0), ('b', 0, 1), ('c', 0, 2)]));
    await pumpGraph(tester, g);
    (List<Symbol>, List<int>) painted() {
      final calls = <Symbol>[];
      final cardNodes = <int>[];
      expect(
        g.render(tester),
        paints..everything((method, arguments) {
          calls.add(method);
          if (method == #drawRect) {
            cardNodes.add(nodeOfColor((arguments[1] as Paint).color));
          }
          return true;
        }),
      );
      return (calls, cardNodes);
    }

    final (List<Symbol> callsBefore, List<int> before) = painted();
    expect(callsBefore, isNot(contains(#drawPath)));
    expect(before, isNot(<int>[2, 1, 0]));
    g
      ..selected = 'b'
      ..hovered = 'a'
      ..edges = ((context, origin, visible) => context.canvas.drawPath(Path(), Paint()));
    await tester.pumpWidget(g.build());
    final (List<Symbol> callsAfter, List<int> after) = painted();
    expect(after, <int>[2, 1, 0], reason: 'base, selected, hovered');
    expect(callsAfter.indexOf(#drawPath), lessThan(callsAfter.indexOf(#drawParagraph)));
  });

  testWidgets('(g) a dimmed card paints at its opacity', (tester) async {
    final g = GraphHarness(handLayout(const <(String, int, int)>[('a', 0, 0), ('b', 0, 1)]))
      ..opacityOf = ((node) => node == 1 ? .5 : 1);
    await pumpGraph(tester, g);
    final calls = <Symbol>[];
    expect(
      g.render(tester),
      paints..everything((method, arguments) {
        calls.add(method);
        return true;
      }),
    );
    expect(calls.where((m) => m == #saveLayer), hasLength(1));
    expect(calls.where((m) => m == #drawRect), hasLength(2));
  });

  testWidgets('(i) a parent rebuild builds no card; a scroll builds only entering nodes', (tester) async {
    final g = GraphHarness(chainLayout(200));
    await pumpGraph(tester, g);
    g.log.clear();
    await tester.pumpWidget(g.build());
    expect(g.log.buildCount, 0);

    Set<String> at(double dy) => g.expectedMounted(at: Offset(0, dy));

    final Set<String> mounted = g.mounted(tester);
    final double none = <double>[
      for (double d = 1; d < 300; d++) d,
    ].firstWhere((d) => at(d).difference(mounted).isEmpty);
    g.v.jumpTo(none);
    await tester.pump();
    expect(g.log.buildCount, 0);

    final Set<String> now = g.mounted(tester);
    final double one = <double>[
      for (double d = none + 1; d < none + 700; d++) d,
    ].firstWhere((d) => at(d).difference(now).length == 1);
    final Set<String> entering = at(one).difference(now);
    g.v.jumpTo(one);
    await tester.pump();
    expect(g.log.buildCount, 1);
    expect(g.log.builds.keys, entering);
  });

  testWidgets('(m) a cache-extent card is hidden to VoiceOver, a visible one is not', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final g = GraphHarness(recording('design-all compact compact'));
    await pumpGraph(tester, g);
    final Set<String> visible = g.expectedMounted(cache: 0);
    final String cached = g.mounted(tester).firstWhere((k) => !visible.contains(k));
    expect(tester.getSemantics(cardOf(cached)).flagsCollection.isHidden, isTrue);
    expect(tester.getSemantics(cardOf(fullyVisible(g))).flagsCollection.isHidden, isFalse);
    semantics.dispose();
  });

  group('(n) robustness', () {
    testWidgets('an empty layout: a 2·pad plane, no card, the paint hooks still run over the whole viewport', (
      tester,
    ) async {
      var hooks = 0;
      final visibleRects = <Rect>[];
      final g = GraphHarness(handLayout(const <(String, int, int)>[]))
        ..background = ((context, origin, visible) {
          hooks++;
          visibleRects.add(visible);
        })
        ..overlay = ((context, origin, visible) => hooks++);
      await pumpGraph(tester, g);
      expect(tester.takeException(), isNull);
      expect(g.mounted(tester), isEmpty);
      expect(g.h.position.maxScrollExtent, 0);
      expect(g.v.position.maxScrollExtent, 0);
      expect(hooks, 2);
      expect(visibleRects, <Rect>[Offset.zero & surface], reason: 'the painted plane covers max(content, viewport)');
    });

    testWidgets('a shrink while scrolled deep clamps the offsets and builds only valid nodes', (tester) async {
      final g = GraphHarness(big);
      await pumpGraph(tester, g);
      g.v.jumpTo(g.v.position.maxScrollExtent);
      g.h.jumpTo(g.h.position.maxScrollExtent);
      await tester.pump();
      g.layout = recording('design-default compact compact');
      await tester.pumpWidget(g.build());
      expect(tester.takeException(), isNull);
      expect(g.v.offset, inInclusiveRange(0, g.v.position.maxScrollExtent));
      expect(g.h.offset, inInclusiveRange(0, g.h.position.maxScrollExtent));
      expect(g.scroll, g.expectedMax);
      expect(g.mounted(tester), g.expectedMounted());
    });

    testWidgets('macOS overscroll past both ends on both axes keeps the children consistent', (tester) async {
      final g = GraphHarness(recording('design-all compact compact'));
      await pumpGraph(tester, g);
      Future<void> overscroll(Offset by) async {
        final TestGesture drag = await tester.startGesture(const Offset(400, 300));
        for (var step = 0; step < 10; step++) {
          await drag.moveBy(by / 10);
          await tester.pump(const Duration(milliseconds: 16));
          expect(g.mounted(tester), g.expectedMounted());
        }
        await drag.up();
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(g.mounted(tester), g.expectedMounted());
        }
        await tester.pumpAndSettle();
      }

      await overscroll(const Offset(300, 300));
      expect(g.scroll, Offset.zero);
      g
        ..h.jumpTo(g.h.position.maxScrollExtent)
        ..v.jumpTo(g.v.position.maxScrollExtent);
      await tester.pump();
      await overscroll(const Offset(-300, -300));
      expect(g.scroll, g.expectedMax);
      expect(tester.takeException(), isNull);
    }, variant: macOS);
  });
}
