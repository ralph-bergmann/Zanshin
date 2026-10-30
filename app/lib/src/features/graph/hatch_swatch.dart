// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// Paints the immutable hatch (DS components/graph/graph.css:109-110) into [rrect], clipped to it: 135° lines 1 px
/// wide, one every [period] px, as CSS's `repeating-linear-gradient(135deg, transparent 0 p−1, color p−1 p)` does —
/// the line centres lie on `x + y = √2·(period − .5 + period·k)` from the rect's top-left.
void paintGraphHatch(Canvas canvas, RRect rrect, {required double period, required Color color}) {
  final Rect rect = rrect.outerRect;
  final double reach = rect.width + rect.height;
  final paint = Paint()
    ..color = color
    ..strokeWidth = 1;
  canvas
    ..save()
    ..clipRRect(rrect);
  for (var k = 0; ; k++) {
    final double c = math.sqrt2 * (period - .5 + period * k);
    if (c > reach + 1) {
      break;
    }
    canvas.drawLine(Offset(rect.left + c, rect.top), Offset(rect.left + c - reach, rect.top + reach), paint);
  }
  canvas.restore();
}

/// The swatch that names "immutable" (DS components/graph/HatchSwatch.prompt.md; Story 10.3): the card's hatch in
/// miniature, 12 × 12, radius `--radius-kbd`, 1 px `--border-strong` on `--card-solid`, a 135° hatch every 3 px in
/// `--hatch-mark`. Decoration beside its word (excluded from semantics); alone, give it a [label] and it is an image
/// with that label.
class HatchSwatch extends StatelessWidget {
  /// A swatch; [label] makes it an image with that label.
  const HatchSwatch({this.label, super.key});

  /// The label when the swatch stands alone, else null.
  final String? label;

  /// The side, `--icon-sm`.
  static const double side = 12;

  /// The swatch's hatch period.
  static const double period = 3;

  @override
  Widget build(BuildContext context) {
    final paint = CustomPaint(
      size: const Size.square(side),
      painter: _HatchSwatchPainter(theme: GraphTheme.of(context), radius: ZsMetrics.of(context).radiusKbd),
    );
    final String? label = this.label;
    return label == null ? ExcludeSemantics(child: paint) : Semantics(image: true, label: label, child: paint);
  }
}

class _HatchSwatchPainter extends CustomPainter {
  const _HatchSwatchPainter({required this.theme, required this.radius});

  final GraphTheme theme;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    canvas.drawRRect(rrect, Paint()..color = theme.cardFill);
    paintGraphHatch(canvas, rrect, period: HatchSwatch.period, color: theme.hatchMark);
    canvas.drawRRect(
      rrect.deflate(.5),
      Paint()
        ..color = theme.cardBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_HatchSwatchPainter oldDelegate) => oldDelegate.theme != theme || oldDelegate.radius != radius;
}
