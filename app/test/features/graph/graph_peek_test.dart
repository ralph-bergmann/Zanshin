// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_peek.dart';

void main() {
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
