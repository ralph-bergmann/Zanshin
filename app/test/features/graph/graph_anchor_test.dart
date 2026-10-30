// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';

import 'graph_harness.dart';

/// The cards fully on screen, with where they are.
Map<String, Offset> onScreen(WidgetTester tester, GraphHarness g) => <String, Offset>{
  for (final String key in g.expectedMounted(cache: 0))
    if (g.viewport.intersect(g.cardRect(g.layout.indexOfKey(key)!)) == g.cardRect(g.layout.indexOfKey(key)!))
      key: g.screenOf(tester, key),
};

/// The key the default anchor rule picks: the node whose card centre is nearest the viewport's centre.
String nearestCentre(GraphHarness g) {
  final Offset centre = g.viewport.center;
  String? best;
  double distance = double.infinity;
  for (final String key in g.expectedMounted()) {
    final double d = (g.cardRect(g.layout.indexOfKey(key)!).center - centre).distanceSquared;
    if (d < distance) {
      distance = d;
      best = key;
    }
  }
  return best!;
}

Future<GraphHarness> pumpChain(WidgetTester tester, {Offset scroll = const Offset(100, 8000)}) async {
  final g = GraphHarness(chainLayout(200));
  await pumpGraph(tester, g);
  g.h.jumpTo(scroll.dx);
  g.v.jumpTo(scroll.dy);
  await tester.pump();
  return g;
}

void main() {
  group('(j) anchoring', () {
    testWidgets('a reload that adds a head keeps every card in place, and only entering nodes init a State', (
      tester,
    ) async {
      final GraphHarness g = await pumpChain(tester);
      final Map<String, Offset> before = onScreen(tester, g);
      final Set<String> mountedBefore = g.mounted(tester);
      final inits = Map<String, int>.of(g.log.inits);
      g.layout = chainLayout(200, head: 'new');
      await tester.pumpWidget(g.build());
      expect(g.v.offset, 8000 + 110, reason: 'every card moved down one pitch');
      for (final MapEntry<String, Offset>(:key, :value) in before.entries) {
        expect(g.screenOf(tester, key), value, reason: key);
      }
      final Set<String> mountedAfter = g.mounted(tester);
      for (final key in mountedAfter) {
        expect(g.log.inits[key], mountedBefore.contains(key) ? inits[key] : 1, reason: key);
      }
    });

    testWidgets('a reload that moves the anchor to another column keeps it in place horizontally too', (tester) async {
      final GraphHarness g = await pumpChain(tester);
      final String anchor = nearestCentre(g);
      final Offset at = g.screenOf(tester, anchor);
      final int col = g.layout.colOf(g.layout.indexOfKey(anchor)!);
      g.layout = chainLayout(200, colOf: <String, int>{anchor: col + 2});
      await tester.pumpWidget(g.build());
      expect(g.screenOf(tester, anchor), at);
      expect(g.h.offset, 100 + 2 * 296);
    });

    testWidgets('a reveal key centres its node once; the next relayout keeps the anchor and does not re-centre', (
      tester,
    ) async {
      final GraphHarness g = await pumpChain(tester);
      g
        ..layout = chainLayout(200, head: 'new')
        ..reveal = GraphReveal('r50');
      await tester.pumpWidget(g.build());
      expect(
        tester.getCenter(find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == 'r50')),
        const Offset(400, 300),
      );

      final Offset revealed = g.screenOf(tester, 'r50');
      g.metrics = GraphMetrics(cardWidth: 300);
      await tester.pumpWidget(g.build());
      expect(g.screenOf(tester, 'r50'), revealed, reason: 'the anchor holds');
      expect(tester.getCenter(find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == 'r50')).dx, isNot(400));
    });

    testWidgets('an absent reveal key falls back to the anchor', (tester) async {
      final GraphHarness g = await pumpChain(tester);
      final Map<String, Offset> before = onScreen(tester, g);
      g
        ..layout = chainLayout(200, head: 'new')
        ..reveal = GraphReveal('absent');
      await tester.pumpWidget(g.build());
      for (final MapEntry<String, Offset>(:key, :value) in before.entries) {
        expect(g.screenOf(tester, key), value, reason: key);
      }
    });

    testWidgets('an anchor key on screen keeps its place even when the centre node changes column (Story 10.5)', (
      tester,
    ) async {
      final GraphHarness g = await pumpChain(tester);
      final String centre = nearestCentre(g);
      final String key = onScreen(tester, g).keys.firstWhere((k) => k != centre);
      g.anchorKey = key;
      await tester.pumpWidget(g.build());
      final Offset at = g.screenOf(tester, key);
      final int col = g.layout.colOf(g.layout.indexOfKey(centre)!);
      g.layout = chainLayout(200, head: 'new', colOf: <String, int>{centre: col + 2});
      await tester.pumpWidget(g.build());
      expect(g.screenOf(tester, key), at);
    });

    testWidgets('an anchor key whose card is off screen gives way to the node nearest the centre (Story 10.5)', (
      tester,
    ) async {
      final GraphHarness g = await pumpChain(tester);
      g.anchorKey = 'r10';
      await tester.pumpWidget(g.build());
      expect(g.viewport.overlaps(g.cardRect(g.layout.indexOfKey('r10')!)), isFalse);
      final Map<String, Offset> before = onScreen(tester, g);
      // Were r10 the anchor, its new column would shift every card sideways.
      g.layout = chainLayout(200, head: 'new', colOf: const <String, int>{'r10': 5});
      await tester.pumpWidget(g.build());
      for (final MapEntry<String, Offset>(:key, :value) in before.entries) {
        expect(g.screenOf(tester, key), value, reason: key);
      }
    });

    testWidgets('an anchor key whose card lies under an inset gives way to the node nearest the centre (Story 10.5)', (
      tester,
    ) async {
      final GraphHarness g = await pumpChain(tester);
      // r122 (column 2) sits at screen x 548–788, on screen but wholly under a 300 px right inset (the inspector).
      g
        ..insets = const EdgeInsets.only(right: 300)
        ..anchorKey = 'r122';
      await tester.pumpWidget(g.build());
      final Rect card = g.cardRect(g.layout.indexOfKey('r122')!).shift(-g.scroll);
      expect(card.left, greaterThanOrEqualTo(500));
      expect((Offset.zero & surface).overlaps(card), isTrue);
      final before = <String, Offset>{
        for (final String key in g.expectedMounted(cache: 0))
          if (key != 'r122') key: g.screenOf(tester, key),
      };
      expect(before, isNotEmpty);
      // Were r122 the anchor, its move to column 0 would shift every card sideways.
      g.layout = chainLayout(200, colOf: const <String, int>{'r122': 0});
      await tester.pumpWidget(g.build());
      for (final MapEntry<String, Offset>(:key, :value) in before.entries) {
        expect(g.screenOf(tester, key), value, reason: key);
      }
    });

    testWidgets('an absent anchor key leaves the offsets as they are', (tester) async {
      final GraphHarness g = await pumpChain(tester);
      g.layout = handLayout(<(String, int, int)>[for (int row = 199; row >= 0; row--) ('other$row', row, row % 6)]);
      await tester.pumpWidget(g.build());
      expect(g.scroll, const Offset(100, 8000));
    });

    testWidgets('an absent anchor key arriving with a left or top inset change still shifts the offset by it', (
      tester,
    ) async {
      final GraphHarness g = await pumpChain(tester);
      g
        ..layout = handLayout(<(String, int, int)>[for (int row = 199; row >= 0; row--) ('other$row', row, row % 6)])
        ..insets = const EdgeInsets.only(left: 50, top: 30);
      await tester.pumpWidget(g.build());
      expect(g.scroll, const Offset(150, 8030));
    });
  });

  testWidgets('(l) a W or H change remaps without a layout request: exact extents, the anchor holds', (tester) async {
    final GraphHarness g = await pumpChain(tester);
    // An anchor key holds only while its card meets the viewport (Story 10.5): such a card other than the centre one,
    // in column 0 or 1, so no card width clamps the offset at 0.
    final String centre = nearestCentre(g);
    final String key = g
        .expectedMounted(cache: 0)
        .firstWhere(
          (k) =>
              k != centre &&
              g.layout.colOf(g.layout.indexOfKey(k)!) <= 1 &&
              g.viewport.overlaps(g.cardRect(g.layout.indexOfKey(k)!)),
        );
    g.anchorKey = key;
    await tester.pumpWidget(g.build());
    final Offset at = g.screenOf(tester, key);
    final RenderGraphViewport render = g.render(tester);
    for (final metrics in <GraphMetrics>[
      GraphMetrics(cardWidth: 320),
      GraphMetrics(cardWidth: 320, detailedCards: false),
      GraphMetrics(cardWidth: 160, detailedCards: false),
    ]) {
      g.metrics = metrics;
      await tester.pumpWidget(g.build());
      expect(identical(render.graphLayout, g.layout), isTrue);
      expect(Offset(g.h.position.maxScrollExtent, g.v.position.maxScrollExtent), g.expectedMax);
      expect(g.screenOf(tester, key), at, reason: '$key ${metrics.cardWidth} ${metrics.cardHeight}');
      expect(g.mounted(tester), g.expectedMounted());
    }
  });

  group('(o) pinning', () {
    testWidgets('a pinned key keeps its State when pinned, scrolled out and moved by a reload', (tester) async {
      final GraphHarness g = await pumpChain(tester);
      final String key = nearestCentre(g);
      g.pinned = <String>{key};
      await tester.pumpWidget(g.build());
      expect(g.log.inits[key], 1);

      g.v.jumpTo(100);
      await tester.pump();
      expect(g.mounted(tester), contains(key));
      expect(g.log.inits[key], 1);

      final int col = g.layout.colOf(g.layout.indexOfKey(key)!);
      g.layout = chainLayout(200, head: 'new', colOf: <String, int>{key: (col + 1) % 6});
      await tester.pumpWidget(g.build());
      expect(g.mounted(tester), contains(key));
      expect(g.log.inits[key], 1);
      expect(g.mounted(tester), g.expectedMounted());

      g.pinned = const <String>{};
      await tester.pumpWidget(g.build());
      expect(g.mounted(tester), isNot(contains(key)));
    });
  });

  group('live insets (2026-10-16)', () {
    Future<void> drive(WidgetTester tester, GraphHarness g, EdgeInsets Function(double t) insets) async {
      final Map<String, Offset> before = onScreen(tester, g);
      expect(before, isNotEmpty);
      for (var step = 1; step <= 20; step++) {
        g.insets = insets(step / 20);
        await tester.pumpWidget(g.build());
        for (final MapEntry<String, Offset>(:key, :value) in before.entries) {
          expect(g.screenOf(tester, key), value, reason: '$key at ${g.insets}');
        }
        expect(g.h.offset, inInclusiveRange(0, g.h.position.maxScrollExtent));
      }
    }

    testWidgets('a left inset growing and shrinking mid-range moves no card: the offset shifts by it', (tester) async {
      final GraphHarness g = await pumpChain(tester, scroll: const Offset(400, 8000));
      await drive(tester, g, (t) => EdgeInsets.only(left: 200 * t));
      expect(g.h.offset, 600);
      await drive(tester, g, (t) => EdgeInsets.only(left: 200 * (1 - t)));
      expect(g.h.offset, 400);
    });

    testWidgets('a right inset growing and shrinking mid-range moves no card and no offset', (tester) async {
      final GraphHarness g = await pumpChain(tester, scroll: const Offset(400, 8000));
      await drive(tester, g, (t) => EdgeInsets.only(right: 200 * t));
      await drive(tester, g, (t) => EdgeInsets.only(right: 200 * (1 - t)));
      expect(g.h.offset, 400);
    });

    testWidgets('growing at both ends moves no card', (tester) async {
      final GraphHarness g = await pumpChain(tester, scroll: const Offset(0, 8000));
      await drive(tester, g, (t) => EdgeInsets.only(left: 240 * t));
      expect(g.h.offset, 240);
      g.h.jumpTo(g.h.position.maxScrollExtent);
      await tester.pump();
      await drive(tester, g, (t) => EdgeInsets.only(left: 240, right: 300 * t));
      expect(g.h.offset, g.h.position.maxScrollExtent - 300);
    });

    testWidgets('a flyout over the viewport changes no extent and no offset', (tester) async {
      final GraphHarness g = await pumpChain(tester);
      Widget host({required bool flyout}) => Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: g.build()),
            if (flyout)
              const Positioned(left: 60, top: 60, bottom: 60, width: 300, child: ColoredBox(color: Color(0xFF808080))),
          ],
        ),
      );
      await tester.pumpWidget(host(flyout: false));
      final Offset scroll = g.scroll;
      final max = Offset(g.h.position.maxScrollExtent, g.v.position.maxScrollExtent);
      await tester.pumpWidget(host(flyout: true));
      expect(g.scroll, scroll);
      expect(Offset(g.h.position.maxScrollExtent, g.v.position.maxScrollExtent), max);
    });
  });

  group('reveal', () {
    testWidgets('under disableAnimations an animated reveal lands in one frame', (tester) async {
      final GraphHarness g = await pumpChain(tester);
      g.disableAnimations = true;
      await tester.pumpWidget(g.build());
      g.controller.reveal('r50', animate: true);
      await tester.pump();
      expect(
        tester.getCenter(find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == 'r50')),
        const Offset(400, 300),
      );

      g.reveal = GraphReveal('r152', animate: true);
      await tester.pumpWidget(g.build());
      expect(
        tester.getCenter(find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == 'r152')),
        const Offset(400, 300),
      );
    });

    testWidgets('with motion an animated reveal glides there', (tester) async {
      final GraphHarness g = await pumpChain(tester);
      g.controller.reveal('r50', animate: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(g.v.offset, isNot(closeTo(g.cardRect(g.layout.indexOfKey('r50')!).center.dy - 300, 1)));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == 'r50')),
        const Offset(400, 300),
      );

      g.reveal = GraphReveal('r152', animate: true);
      await tester.pumpWidget(g.build());
      await tester.pump(const Duration(milliseconds: 16));
      final double target = g.cardRect(g.layout.indexOfKey('r152')!).center.dy - 300;
      expect(g.v.offset, isNot(closeTo(target, 1)), reason: 'still gliding');
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == 'r152')),
        const Offset(400, 300),
      );
    });

    testWidgets('a minimal reveal scrolls just enough to show the whole card', (tester) async {
      final GraphHarness g = await pumpChain(tester, scroll: Offset.zero);
      final Rect card = g.cardRect(g.layout.indexOfKey('r180')!);
      g.controller.reveal('r180', alignment: GraphRevealAlignment.minimal);
      await tester.pump();
      expect(g.viewport.intersect(card), card);
      expect(g.v.offset, card.bottom - 600);
      g.controller.jumpTo(const Offset(10, 20));
      await tester.pump();
      expect(g.scroll, const Offset(10, 20));
    });

    testWidgets('two equal reveal requests for one key both centre it', (tester) async {
      final GraphHarness g = await pumpChain(tester);
      Offset centreOf(String key) => tester.getCenter(find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == key));
      g.reveal = GraphReveal('r152');
      await tester.pumpWidget(g.build());
      expect(centreOf('r152'), const Offset(400, 300));
      g.v.jumpTo(9000);
      await tester.pump();
      g.reveal = GraphReveal('r152');
      await tester.pumpWidget(g.build());
      expect(centreOf('r152'), const Offset(400, 300));
    });

    group('with insets, in the unobscured area', () {
      const insets = EdgeInsets.only(left: 200, top: 50, right: 100);
      final Rect area = insets.deflateRect(Offset.zero & surface);

      testWidgets('a centre reveal puts the card at its centre', (tester) async {
        final GraphHarness g = await pumpChain(tester);
        g.insets = insets;
        await tester.pumpWidget(g.build());
        g.controller.reveal('r152');
        await tester.pump();
        expect(tester.getCenter(find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == 'r152')), area.center);
      });

      testWidgets('a minimal reveal shows the whole card inside it', (tester) async {
        final GraphHarness g = await pumpChain(tester, scroll: Offset.zero);
        g.insets = insets;
        await tester.pumpWidget(g.build());
        g.controller.reveal('r180', alignment: GraphRevealAlignment.minimal);
        await tester.pump();
        final Rect card = g.cardRect(g.layout.indexOfKey('r180')!).shift(-g.scroll);
        expect(area.intersect(card), card);
        expect(card.bottom, area.bottom);
      });
    });

    testWidgets('animateTo glides both axes to an in-range offset', (tester) async {
      final GraphHarness g = await pumpChain(tester);
      final Future<void> done = g.controller.animateTo(
        const Offset(300, 900),
        duration: const Duration(milliseconds: 200),
        curve: Curves.linear,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(g.scroll, isNot(const Offset(300, 900)));
      await tester.pumpAndSettle();
      await done;
      expect(g.scroll, const Offset(300, 900));
    });
  });

  group('an explicit vertical layout', () {
    testWidgets('PerNodeTops: the mounted cards are the oracle, the extents its height; swapped tops apply', (
      tester,
    ) async {
      final RecordedGraphLayout layout = chainLayout(200);
      final g = GraphHarness(layout)
        ..verticalLayout = PerNodeTops(
          layout,
          GraphMetrics(),
          Float64List.fromList(<double>[for (var i = 0; i < 200; i++) 56 + i * 137.0]),
        );
      await pumpGraph(tester, g);
      g.v.jumpTo(3000);
      await tester.pump();
      expect(g.mounted(tester), g.expectedMounted());
      expect(Offset(g.h.position.maxScrollExtent, g.v.position.maxScrollExtent), g.expectedMax);

      final double before = g.v.position.maxScrollExtent;
      g.verticalLayout = PerNodeTops(
        layout,
        GraphMetrics(),
        Float64List.fromList(<double>[for (var i = 0; i < 200; i++) 56 + i * 80.0]),
      );
      await tester.pumpWidget(g.build());
      expect(g.v.position.maxScrollExtent, isNot(before));
      expect(Offset(g.h.position.maxScrollExtent, g.v.position.maxScrollExtent), g.expectedMax);
      expect(g.mounted(tester), g.expectedMounted());
    });
  });

  testWidgets('with no card laid out, a left or top inset change still shifts the offset', (tester) async {
    final g = GraphHarness(handLayout(const <(String, int, int)>[]))
      ..insets = const EdgeInsets.only(left: 1000, top: 700);
    await pumpGraph(tester, g);
    g
      ..h.jumpTo(100)
      ..v.jumpTo(100);
    await tester.pump();
    g.insets = const EdgeInsets.only(left: 1100, top: 750);
    await tester.pumpWidget(g.build());
    expect(g.scroll, const Offset(200, 150));
  });
}
