// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_peek.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

void main() {
  setUpIconRegistry();

  group('GraphPeek (Story 10.12)', () {
    const content = GraphCommitContent(
      subject: 'Fix the cache',
      description: 'Fix the cache\n\nIt evicted too early.\nNow it does not.\n',
      authorName: 'Lena König',
    );
    GraphCardData data({GraphCommitContent? content, bool root = false}) => GraphCardData(
      key: 'kmnvxoqprstu',
      changeId: 'kmnvxoqprstu',
      prefixLength: 2,
      commitId: '0123456789abcdef0123',
      commitPrefixLength: 3,
      isRoot: root,
      content: content,
    );

    Future<void> pumpPeek(WidgetTester tester, GraphCardData d) =>
        tester.pumpWidget(shellHost(Center(child: GraphPeek(data: d, nowMs: 0))));

    testWidgets('the description body below the subject, the commit id in the meta row after the change id', (
      tester,
    ) async {
      await pumpPeek(tester, data(content: content));
      expect(find.text('Fix the cache'), findsOneWidget);
      final Text body = tester.widget<Text>(find.byKey(const ValueKey<String>('peek-description')));
      expect(body.data, 'It evicted too early.\nNow it does not.');
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<String>('peek-description'))).dy,
        greaterThan(tester.getTopLeft(find.text('Fix the cache')).dy),
      );
      final Text commit = tester.widget<Text>(find.byKey(const ValueKey<String>('peek-commit')));
      expect(commit.data, '01234567', reason: 'max(prefix, 8) hex');
      expect(find.byKey(const ValueKey<String>('peek-skeleton')), findsNothing);
    });

    testWidgets('a one-line description shows no body', (tester) async {
      await pumpPeek(
        tester,
        data(
          content: const GraphCommitContent(subject: 'One', description: 'One\n'),
        ),
      );
      expect(find.byKey(const ValueKey<String>('peek-description')), findsNothing);
    });

    testWidgets('while the content loads: a skeleton bar in the subject place', (tester) async {
      await pumpPeek(tester, data());
      expect(find.byKey(const ValueKey<String>('peek-skeleton')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('peek-description')), findsNothing);
    });

    testWidgets('the root keeps root() and never shows the loading look or a commit id', (tester) async {
      await pumpPeek(tester, data(root: true));
      expect(find.text('root()'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('peek-skeleton')), findsNothing);
      expect(find.byKey(const ValueKey<String>('peek-commit')), findsNothing);
    });
  });

  const area = Rect.fromLTRB(76, 60, 800, 600);
  const peek = Size(340, 160);

  group('graphPeekPosition', () {
    test('8 px right of the card, its top at the card top', () {
      const card = Rect.fromLTWH(100, 100, 240, 62);
      final ({Offset topLeft, bool flipped}) p = graphPeekPosition(card, peek, area);
      expect(p.flipped, isFalse);
      expect(p.topLeft, const Offset(348, 100));
    });

    test('flipped to the left when it would cross the right edge', () {
      const card = Rect.fromLTWH(500, 100, 240, 62);
      final ({Offset topLeft, bool flipped}) p = graphPeekPosition(card, peek, area);
      expect(p.flipped, isTrue);
      expect(p.topLeft.dx, card.left - 8 - peek.width);
    });

    test('shifted up to stay above the bottom edge', () {
      const card = Rect.fromLTWH(100, 520, 240, 62);
      expect(graphPeekPosition(card, peek, area).topLeft.dy, area.bottom - peek.height);
    });

    test('clamped inside the area on both axes', () {
      // Flipped left past the area's left edge, and above its top.
      const card = Rect.fromLTWH(200, 20, 500, 62);
      final ({Offset topLeft, bool flipped}) p = graphPeekPosition(card, peek, area);
      expect(p.topLeft, Offset(area.left, area.top));
    });
  });

  group('graphTooltipPosition', () {
    const tip = Size(120, 24);

    test('centred 8 px above the affordance', () {
      const target = Rect.fromLTWH(300, 200, 20, 20);
      final ({Offset topLeft, bool below}) p = graphTooltipPosition(target, tip, area);
      expect(p.below, isFalse);
      expect(p.topLeft, const Offset(250, 200 - 8 - 24));
    });

    test('below when above would leave the area at its top', () {
      const target = Rect.fromLTWH(300, 70, 20, 20);
      final ({Offset topLeft, bool below}) p = graphTooltipPosition(target, tip, area);
      expect(p.below, isTrue);
      expect(p.topLeft.dy, target.bottom + 8);
    });

    test('clamped horizontally inside the area', () {
      expect(graphTooltipPosition(const Rect.fromLTWH(80, 200, 20, 20), tip, area).topLeft.dx, area.left);
      expect(
        graphTooltipPosition(const Rect.fromLTWH(790, 200, 20, 20), tip, area).topLeft.dx,
        area.right - tip.width,
      );
    });
  });
}
