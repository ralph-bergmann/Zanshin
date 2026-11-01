// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_edges.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_peek.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../../widgetbook/graph/synthetic_layout.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

/// Story 10.20's witnesses: the viewport's FLIP (glide, birth, arrival, vanish, glide-out, reduce motion, hit testing,
/// no card builds) and the canvas's edge layer, born edges, flash and after-glide reveal.
void main() {
  // A column step: the card width plus the column gap.
  const double step = 296;
  const ZsMotion full = ZsMotion.full;

  group('the viewport', () {
    /// Lands [to] on [h] with a transition from the shown layout, at elapsed 0.
    Future<void> land(WidgetTester tester, GraphHarness h, GraphLayout to, {String? anchor, String? born}) async {
      h
        ..transition = GraphTransition(from: h.layout, to: to, anchor: anchor, born: born)
        ..layout = to
        ..transitionElapsed = Duration.zero;
      await tester.pumpWidget(h.build());
    }

    Future<void> at(WidgetTester tester, GraphHarness h, int ms) async {
      h.transitionElapsed = Duration(milliseconds: ms);
      await tester.pumpWidget(h.build());
    }

    Finder card(String key) => find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == key, skipOffstage: false);

    testWidgets('a moved card glides 460 ms on --ease-glide from its old screen rect; the anchor never moves', (
      tester,
    ) async {
      // r13 is the anchor; the new layout moves the anchor too, so the scroll follows it and r12 moves on screen.
      final h = GraphHarness(chainLayout(20))..anchorKey = 'r13';
      await pumpGraph(tester, h);
      h.v.jumpTo(600);
      await tester.pump();
      final Offset r12 = h.screenOf(tester, 'r12');
      final Offset r13 = h.screenOf(tester, 'r13');
      await land(tester, h, chainLayout(20, colOf: const <String, int>{'r12': 2, 'r13': 2}));
      expect(h.screenOf(tester, 'r12'), r12, reason: 'the first frame paints the old rect');
      expect(h.screenOf(tester, 'r13'), r13);
      expect(h.render(tester).transitionEffectOf('r13'), isNull, reason: 'the anchor does not move');
      await at(tester, h, 230);
      expect(h.screenOf(tester, 'r12').dx, moreOrLessEquals(r12.dx + step * full.easeGlide.transform(.5)));
      expect(h.screenOf(tester, 'r13'), r13);
      await at(tester, h, 460);
      expect(h.screenOf(tester, 'r12'), r12 + const Offset(step, 0));
      expect(h.render(tester).transitionEffectOf('r12'), isNull);
      expect(h.screenOf(tester, 'r13'), r13);
    });

    testWidgets('hit testing follows the glide: a tap on the old rect hits the gliding card', (tester) async {
      final h = GraphHarness(chainLayout(20))..anchorKey = 'r14';
      await pumpGraph(tester, h);
      h.v.jumpTo(600);
      await tester.pump();
      final Offset r12 = h.screenOf(tester, 'r12');
      await land(tester, h, chainLayout(20, colOf: const <String, int>{'r12': 2}));
      await tester.tapAt(r12 + const Offset(graphCardOverhang + 20, graphCardOverhang + 20));
      expect(h.log.taps, <String>['r12']);
    });

    testWidgets('the born card grows out of the anchor\'s old rect: scale .94, opaque at 162 ms, at rest at 540 ms', (
      tester,
    ) async {
      final h = GraphHarness(chainLayout(6, cols: 3))..anchorKey = 'r5';
      await pumpGraph(tester, h);
      final Offset anchor = tester.getCenter(card('r5'));
      await land(
        tester,
        h,
        chainLayout(6, cols: 3, head: 'n'),
        anchor: 'r5',
        born: 'n',
      );
      final RenderGraphViewport render = h.render(tester);
      expect(render.transitionEffectOf('n')?.scale, moreOrLessEquals(graphBirthScale));
      expect(render.transitionEffectOf('n')?.alpha, 0);
      expect(tester.getCenter(card('n')), offsetMoreOrLessEquals(anchor));
      expect(tester.getRect(card('n')).width, moreOrLessEquals((240 + 2 * graphCardOverhang) * graphBirthScale));
      expect(tester.getCenter(card('r5')), anchor, reason: 'the anchor stays');
      await at(tester, h, 162);
      expect(render.transitionEffectOf('n')?.alpha, moreOrLessEquals(1));
      await at(tester, h, 540);
      expect(render.transitionEffectOf('n'), isNull);
      expect(tester.getRect(card('n')).width, 240 + 2 * graphCardOverhang);
    });

    testWidgets('another new card waits 220 ms, then fades in over 240 ms; a born card without an old anchor too', (
      tester,
    ) async {
      for (final born in <String?>[null, 'n']) {
        final h = GraphHarness(chainLayout(6, cols: 3))..anchorKey = 'r5';
        await pumpGraph(tester, h);
        await land(
          tester,
          h,
          chainLayout(6, cols: 3, head: 'n'),
          anchor: 'gone',
          born: born,
        );
        final RenderGraphViewport render = h.render(tester);
        await at(tester, h, 219);
        expect(render.transitionEffectOf('n')?.alpha, 0);
        await at(tester, h, 340);
        expect(render.transitionEffectOf('n')?.alpha, allOf(greaterThan(0), lessThan(1)));
        expect(render.transitionEffectOf('n')?.shift, Offset.zero);
        await at(tester, h, 460);
        expect(render.transitionEffectOf('n'), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a removed card vanishes at once', (tester) async {
      final h = GraphHarness(chainLayout(6, cols: 3));
      await pumpGraph(tester, h);
      expect(h.mounted(tester), contains('r5'));
      await land(tester, h, chainLayout(5, cols: 3));
      expect(h.mounted(tester), isNot(contains('r5')));
    });

    testWidgets('a card gliding out of the window stays laid out until it lands', (tester) async {
      final h = GraphHarness(chainLayout(12, cols: 3))..anchorKey = 'r11';
      await pumpGraph(tester, h);
      final Offset r10 = h.screenOf(tester, 'r10');
      await land(tester, h, chainLayout(12, cols: 3, colOf: const <String, int>{'r10': 40}));
      expect(h.mounted(tester), contains('r10'));
      expect(h.screenOf(tester, 'r10'), r10);
      // Painted and hit at its old rect, though laid out off screen.
      await tester.tapAt(r10 + const Offset(graphCardOverhang + 20, graphCardOverhang + 20));
      expect(h.log.taps, <String>['r10']);
      await at(tester, h, 459);
      expect(h.mounted(tester), contains('r10'));
      await at(tester, h, 460);
      expect(h.mounted(tester), isNot(contains('r10')));
    });

    testWidgets('a card gliding out of the window stays laid out through a continuation until it lands', (
      tester,
    ) async {
      final h = GraphHarness(chainLayout(12, cols: 3))..anchorKey = 'r11';
      await pumpGraph(tester, h);
      final Offset r10 = h.screenOf(tester, 'r10');
      await land(tester, h, chainLayout(12, cols: 3, colOf: const <String, int>{'r10': 40}));
      // Mid-glide the card is already beyond the window, so the hit is checked on the continuation's first frame.
      final GraphLayout again = chainLayout(12, cols: 3, colOf: const <String, int>{'r10': 40});
      h
        ..transition = GraphTransition.continued(h.transition!, again)
        ..layout = again;
      await tester.pumpWidget(h.build());
      expect(h.mounted(tester), contains('r10'));
      expect(h.screenOf(tester, 'r10'), r10);
      await tester.tapAt(r10 + const Offset(graphCardOverhang + 20, graphCardOverhang + 20));
      expect(h.log.taps, <String>['r10']);
      await at(tester, h, 200);
      expect(h.mounted(tester), contains('r10'));
      await at(tester, h, 459);
      expect(h.mounted(tester), contains('r10'));
      await at(tester, h, 460);
      expect(h.mounted(tester), isNot(contains('r10')));
    });

    testWidgets('a describe (same keys, same rects) moves nothing', (tester) async {
      final h = GraphHarness(chainLayout(6, cols: 3));
      await pumpGraph(tester, h);
      final before = <String, Offset>{
        for (final key in h.mounted(tester)) key: h.screenOf(tester, key),
      };
      await land(tester, h, chainLayout(6, cols: 3));
      for (final MapEntry<String, Offset>(:key, :value) in before.entries) {
        expect(h.render(tester).transitionEffectOf(key), isNull, reason: key);
        expect(h.screenOf(tester, key), value, reason: key);
      }
    });

    testWidgets('a second transition finishes the first: it starts from the landed rects', (tester) async {
      final h = GraphHarness(chainLayout(20))..anchorKey = 'r14';
      await pumpGraph(tester, h);
      h.v.jumpTo(600);
      await tester.pump();
      final Offset r12 = h.screenOf(tester, 'r12');
      final Offset r13 = h.screenOf(tester, 'r13');
      await land(tester, h, chainLayout(20, colOf: const <String, int>{'r12': 2}));
      await at(tester, h, 200);
      expect(h.screenOf(tester, 'r12'), isNot(r12 + const Offset(2 * step, 0)), reason: 'mid-glide');
      await land(tester, h, chainLayout(20, colOf: const <String, int>{'r12': 2, 'r13': 3}));
      expect(h.screenOf(tester, 'r12'), r12 + const Offset(2 * step, 0), reason: 'landed');
      expect(h.render(tester).transitionEffectOf('r12'), isNull);
      expect(h.screenOf(tester, 'r13'), r13);
      expect(h.render(tester).transitionEffectOf('r13'), isNotNull);
    });

    testWidgets('a continuation onto an equal layout mid-glide keeps the painted rects; the glide ends at 460 ms', (
      tester,
    ) async {
      final h = GraphHarness(chainLayout(20))..anchorKey = 'r14';
      await pumpGraph(tester, h);
      h.v.jumpTo(600);
      await tester.pump();
      final Offset r12 = h.screenOf(tester, 'r12');
      await land(tester, h, chainLayout(20, colOf: const <String, int>{'r12': 2}));
      await at(tester, h, 200);
      final Offset mid = h.screenOf(tester, 'r12');
      expect(mid, isNot(r12 + const Offset(2 * step, 0)), reason: 'mid-glide');
      final GraphLayout again = chainLayout(20, colOf: const <String, int>{'r12': 2});
      h
        ..transition = GraphTransition.continued(h.transition!, again)
        ..layout = again;
      await tester.pumpWidget(h.build());
      expect(h.screenOf(tester, 'r12'), mid, reason: 'no snap');
      await at(tester, h, 300);
      expect(h.screenOf(tester, 'r12').dx, moreOrLessEquals(r12.dx + 2 * step * full.easeGlide.transform(300 / 460)));
      await at(tester, h, 460);
      expect(h.screenOf(tester, 'r12'), r12 + const Offset(2 * step, 0));
      expect(h.render(tester).transitionEffectOf('r12'), isNull);
    });

    testWidgets('reduce motion: moved cards jump, the born card fades over 540 ms in place without growth', (
      tester,
    ) async {
      final h = GraphHarness(chainLayout(20))
        ..anchorKey = 'r14'
        ..disableAnimations = true;
      await pumpGraph(tester, h);
      h.v.jumpTo(600);
      await tester.pump();
      final Offset r12 = h.screenOf(tester, 'r12');
      await land(tester, h, chainLayout(20, colOf: const <String, int>{'r12': 2}));
      expect(h.screenOf(tester, 'r12'), r12 + const Offset(2 * step, 0));

      final b = GraphHarness(chainLayout(6, cols: 3))
        ..anchorKey = 'r5'
        ..disableAnimations = true;
      await pumpGraph(tester, b);
      await land(
        tester,
        b,
        chainLayout(6, cols: 3, head: 'n'),
        anchor: 'r5',
        born: 'n',
      );
      final RenderGraphViewport render = b.render(tester);
      expect(render.transitionEffectOf('n'), (shift: Offset.zero, scale: 1.0, alpha: 0.0));
      await at(tester, b, 270);
      expect(render.transitionEffectOf('n')?.alpha, moreOrLessEquals(.5));
      expect(render.transitionEffectOf('n')?.scale, 1);
      await at(tester, b, 540);
      expect(render.transitionEffectOf('n'), isNull);
    });

    testWidgets("the transition's ticks build no card", (tester) async {
      final h = GraphHarness(chainLayout(20))..anchorKey = 'r14';
      await pumpGraph(tester, h);
      h.v.jumpTo(600);
      await tester.pump();
      await land(tester, h, chainLayout(20, colOf: const <String, int>{'r12': 2}));
      h.log.clear();
      for (var ms = 20; ms <= 720; ms += 20) {
        await at(tester, h, ms);
      }
      expect(h.log.buildCount, 0);
    });

    testWidgets('10k → 10k + 1: only window cards build, and every effect rests within the fixed duration', (
      tester,
    ) async {
      final GraphLayout from = syntheticLayout(10000);
      final GraphLayout to = syntheticLayout(10001);
      final String born = <String>[
        for (var i = 0; i < to.nodeCount; i++)
          if (from.indexOfKey(to.keyOf(i)) == null) to.keyOf(i),
      ].single;
      final int bornNode = to.indexOfKey(born)!;
      final ({int start, int end}) parents = to.parentEdges(bornNode);
      final String? anchor = parents.start < parents.end ? to.keyOf(to.parentOf(parents.start)) : null;
      final h = GraphHarness(from)..anchorKey = anchor;
      await pumpGraph(tester, h);
      h.log.clear();
      await land(tester, h, to, anchor: anchor, born: born);
      final Set<String> mounted = h.mounted(tester);
      expect(mounted.length, lessThan(200));
      expect(h.log.buildCount, lessThanOrEqualTo(mounted.length));
      await at(tester, h, graphTransitionDuration(full).inMilliseconds);
      for (final String key in h.mounted(tester)) {
        expect(h.render(tester).transitionEffectOf(key), isNull, reason: key);
      }
    });
  });

  group('the canvas', () {
    setUpIconRegistry();

    late GraphCardController cards;

    Widget canvasOf(GraphLayout layout, {GraphTransition? transition, GraphReveal? reveal, bool reduce = false}) =>
        shellHost(
          GraphCanvas(layout: layout, cards: cards, transition: transition, reveal: reveal),
          appearance: ZsAppearance(reduceMotion: reduce),
        );

    /// The born case: n over r5 … r0 (three columns), anchored on r5, [born] n.
    Future<GraphTransition> bornOperation(
      WidgetTester tester, {
      bool reduce = false,
      Set<String> flash = const {},
      String? born = 'n',
    }) async {
      useShellWindow(tester, const Size(800, 600));
      cards = GraphCardController(now: 0);
      addTearDown(cards.dispose);
      final GraphLayout from = chainLayout(6, cols: 3);
      final GraphLayout to = chainLayout(6, cols: 3, head: 'n');
      await tester.pumpWidget(canvasOf(from, reduce: reduce));
      await tester.pump();
      final transition = GraphTransition(from: from, to: to, anchor: 'r5', born: born, flash: flash);
      await tester.pumpWidget(canvasOf(to, transition: transition, reduce: reduce));
      return transition;
    }

    RenderGraphViewport viewport(WidgetTester tester) =>
        tester.allRenderObjects.whereType<RenderGraphViewport>().single;

    /// The edge strokes the viewport paints, in order.
    List<double> edgeStrokes(WidgetTester tester) {
      final lengths = <double>[];
      expect(
        viewport(tester),
        paints..everything((method, args) {
          if (method == #drawPath && (args[1] as Paint).strokeWidth == GraphEdgePainter.lineWidth) {
            lengths.add((args[0] as Path).computeMetrics().fold<double>(0, (sum, m) => sum + m.length));
          }
          return true;
        }),
      );
      return lengths;
    }

    Iterable<int> opacities(WidgetTester tester) => tester.layers.whereType<OpacityLayer>().map((l) => l.alpha!);

    testWidgets('the edge layer is hidden for 460 ms and fades back by 720 ms; the born edges draw in from 140 ms', (
      tester,
    ) async {
      await bornOperation(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(edgeStrokes(tester), isEmpty, reason: 'the layer hidden, the born edges not started');
      await tester.pump(const Duration(milliseconds: 200));
      final List<double> partial = edgeStrokes(tester);
      expect(partial, hasLength(1), reason: 'only the born edge');
      await tester.pump(const Duration(milliseconds: 290));
      expect(
        opacities(tester),
        contains(Color.getAlphaFromOpacity(full.easeState.transform(130 / 260))),
        reason: 'the layer half way back at 590 ms',
      );
      await tester.pump(const Duration(milliseconds: 70));
      final List<double> drawn = edgeStrokes(tester);
      expect(drawn.last, greaterThan(partial.single), reason: 'the born edge fully drawn at 660 ms');
      expect(partial.single, moreOrLessEquals(drawn.last * full.easeState.transform(160 / 520), epsilon: 1));
      await tester.pump(const Duration(milliseconds: 100));
      expect(edgeStrokes(tester), hasLength(1), reason: 'at rest: one stroke for every edge');
      expect(edgeStrokes(tester).single, greaterThan(drawn.last));
    });

    testWidgets('reduce motion: the edge layer fades in over 260 ms with the born edges in it', (tester) async {
      await bornOperation(tester, reduce: true);
      await tester.pump(const Duration(milliseconds: 130));
      expect(opacities(tester), contains(Color.getAlphaFromOpacity(full.easeState.transform(.5))));
      expect(edgeStrokes(tester), hasLength(1), reason: 'no separate born stroke');
      await tester.pumpAndSettle();
    });

    testWidgets("an outcome's flash keys ring for 2.4 s", (tester) async {
      await bornOperation(tester, flash: const <String>{'r2'});
      await tester.pump(const Duration(milliseconds: 500));
      int rings() {
        var count = 0;
        expect(
          viewport(tester),
          paints..everything((method, args) {
            if (method == #drawDRRect) {
              count++;
            }
            return true;
          }),
        );
        return count;
      }

      expect(rings(), 2);
      await tester.pump(const Duration(milliseconds: 1950));
      expect(rings(), 0);
    });

    testWidgets('the peek waits for the transition to end', (tester) async {
      // No born card: its reveal would scroll another card under the pointer.
      await bornOperation(tester, born: null);
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(
          find.byWidgetPredicate((w) => w is GraphCard && w.layout.keyOf(w.node) == 'r4', skipOffstage: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(GraphPeek), findsNothing, reason: 'past --delay-peek, inside the transition');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.byType(GraphPeek), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
    });

    testWidgets('a continuation mid-run keeps it going: edges still hidden, the born card revealed after the glide', (
      tester,
    ) async {
      final GraphTransition t = await bornOperation(tester);
      await tester.pump();
      final double landed = viewport(tester).verticalOffset.pixels;
      await tester.pump(const Duration(milliseconds: 300));
      final GraphLayout again = chainLayout(6, cols: 3, head: 'n');
      await tester.pumpWidget(canvasOf(again, transition: GraphTransition.continued(t, again)));
      expect(viewport(tester).transition?.to, same(again), reason: 'still running');
      expect(edgeStrokes(tester), hasLength(1), reason: 'the layer hidden, only the born edge');
      expect(viewport(tester).verticalOffset.pixels, landed);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(viewport(tester).verticalOffset.pixels, 0, reason: 'revealed once the glide landed');
    });

    testWidgets('a continuation that brings a reveal of another key ends at that key, not the born card', (
      tester,
    ) async {
      final GraphTransition t = await bornOperation(tester);
      await tester.pump(const Duration(milliseconds: 300));
      final GraphLayout again = chainLayout(6, cols: 3, head: 'n');
      await tester.pumpWidget(
        canvasOf(again, transition: GraphTransition.continued(t, again), reveal: GraphReveal('r0')),
      );
      expect(viewport(tester).transition?.to, same(again), reason: 'still running');
      await tester.pumpAndSettle();
      expect(viewport(tester).verticalOffset.pixels, greaterThan(0), reason: 'at r0, not scrolled up to n');
    });

    testWidgets('a continuation after the end animates nothing', (tester) async {
      final GraphTransition t = await bornOperation(tester);
      await tester.pumpAndSettle();
      expect(viewport(tester).transition, isNull);
      final GraphLayout again = chainLayout(6, cols: 3, head: 'n');
      await tester.pumpWidget(canvasOf(again, transition: GraphTransition.continued(t, again)));
      expect(viewport(tester).transition, isNull);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a fresh canvas given a continuation of a landing it never ran animates nothing', (tester) async {
      final GraphTransition t = await bornOperation(tester, flash: const <String>{'r2'});
      await tester.pumpAndSettle();
      // A remount: a new State that never started t.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(canvasOf(chainLayout(6, cols: 3, head: 'n')));
      await tester.pump();
      final GraphLayout again = chainLayout(6, cols: 3, head: 'n');
      await tester.pumpWidget(canvasOf(again, transition: GraphTransition.continued(t, again)));
      expect(viewport(tester).transition, isNull);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('an early end whose layout brings a reveal of another key ends at that key, not the born card', (
      tester,
    ) async {
      await bornOperation(tester);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(canvasOf(chainLayout(6, cols: 3, head: 'n'), reveal: GraphReveal('r0')));
      await tester.pumpAndSettle();
      expect(viewport(tester).verticalOffset.pixels, greaterThan(0), reason: 'at r0, not scrolled up to n');
    });

    testWidgets('an early end whose reveal goes back to null still reveals the born card', (tester) async {
      final GraphTransition t = await bornOperation(tester);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(canvasOf(t.to, transition: t, reveal: GraphReveal('r0')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(canvasOf(chainLayout(6, cols: 3, head: 'n')));
      await tester.pumpAndSettle();
      expect(viewport(tester).verticalOffset.pixels, 0, reason: 'the born card, not r0');
    });

    testWidgets(
      'a layout without a transition mid-run ends it: full edges at once, the waiting peek opens, the born card revealed',
      (
        tester,
      ) async {
        await bornOperation(tester);
        final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(
          tester.getCenter(
            find.byWidgetPredicate((w) => w is GraphCard && w.layout.keyOf(w.node) == 'r4', skipOffstage: false),
          ),
        );
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump(const Duration(milliseconds: 5));
        expect(find.byType(GraphPeek), findsNothing, reason: 'waiting');
        final double landed = viewport(tester).verticalOffset.pixels;
        await tester.pumpWidget(canvasOf(chainLayout(6, cols: 3, head: 'n')));
        expect(viewport(tester).transition, isNull);
        final List<double> strokes = edgeStrokes(tester);
        expect(find.byType(GraphPeek), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(landed, greaterThan(0));
        expect(viewport(tester).verticalOffset.pixels, 0, reason: 'the covered born card is still revealed');
        // Back to the scroll the strokes were taken at.
        viewport(tester).verticalOffset.jumpTo(landed);
        await tester.pump();
        expect(strokes, hasLength(1));
        expect(strokes.single, moreOrLessEquals(edgeStrokes(tester).single), reason: 'every edge, at once');
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets('a covered born card is revealed after the glide, not with the layout', (tester) async {
      await bornOperation(tester);
      await tester.pump();
      final double landed = viewport(tester).verticalOffset.pixels;
      expect(landed, greaterThan(0), reason: 'the anchor kept r5 still, n sits above the window');
      await tester.pump(const Duration(milliseconds: 400));
      expect(viewport(tester).verticalOffset.pixels, landed);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(viewport(tester).verticalOffset.pixels, 0);
    });

    testWidgets('reduce motion: a covered born card is revealed after its landing frame', (tester) async {
      await bornOperation(tester, reduce: true);
      await tester.pumpAndSettle();
      expect(viewport(tester).verticalOffset.pixels, 0);
    });
  });
}
