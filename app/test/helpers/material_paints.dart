// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/shared/design/zs_values.dart';

/// Whether [actual], read back from a `Paint` (its channels are stored as 32-bit floats), is [expected].
bool sameColor(Color actual, Color expected) =>
    (actual.a - expected.a).abs() < 1e-6 &&
    (actual.r - expected.r).abs() < 1e-6 &&
    (actual.g - expected.g).abs() < 1e-6 &&
    (actual.b - expected.b).abs() < 1e-6;

/// The outer shape of a [size] box at [radius] (already clamped).
RRect outerShape(Size size, double radius) => RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));

/// Matches the sheen: the outer shape drawn with a shader.
PaintPatternPredicate isSheen(RRect outer) =>
    (method, arguments) => method == #drawRRect && arguments[0] == outer && (arguments[1] as Paint).shader != null;

/// Matches one outer shadow part painted as 11.1's [BoxShadow]: the shape moved by its offset and grown by its
/// spread, in its colour, blurred at σ = blur / 2.
PaintPatternPredicate isDrop(RRect outer, ZsShadow part) {
  final BoxShadow shadow = part.toBoxShadow();
  final RRect bounds = outer.shift(shadow.offset).inflate(shadow.spreadRadius);
  // A paint keeps σ as a 32-bit float, so σ is compared as MaskFilter prints it.
  final blur = MaskFilter.blur(BlurStyle.normal, part.blur / 2).toString();
  return (method, arguments) {
    if (method != #drawRRect || arguments[0] != bounds) {
      return false;
    }
    final paint = arguments[1] as Paint;
    return sameColor(paint.color, part.color) && paint.maskFilter.toString() == blur;
  };
}

/// The paint of a bordered surface: [fill] over [outer], the sheen, the [inset] highlight when given (a line along
/// the top inside the border), the 1 px [border] ring, then the [drops] outside the shape.
PaintPattern surfacePaints({
  required RRect outer,
  required Color fill,
  required Color border,
  required List<ZsShadow> drops,
  ZsShadow? inset,
}) {
  final RRect inner = outer.deflate(1);
  final double mid = outer.width / 2;
  final PaintPattern pattern = paints
    ..rrect(rrect: outer, color: fill)
    // The sheen stops at the top of the padding box.
    ..clipRect(rect: Rect.fromLTRB(outer.left, outer.top + 1, outer.right, outer.bottom))
    ..something(isSheen(outer));
  if (inset != null) {
    pattern
      ..clipRRect(rrect: inner)
      ..path(color: inset.color, includes: <Offset>[Offset(mid, 1.5)], excludes: <Offset>[Offset(mid, 2.5)]);
  }
  pattern
    ..drrect(outer: outer, inner: inner, color: border)
    // The drops paint only outside the shape.
    ..clipPath(
      pathMatcher: isPathThat(
        includes: <Offset>[Offset(mid, outer.bottom + 1)],
        excludes: <Offset>[outer.center],
      ),
    );
  for (final drop in drops) {
    pattern.something(isDrop(outer, drop));
  }
  return pattern;
}

/// [expect], with the shadows' blur painted: `flutter_test` turns [debugDisableShadows] on, and a `paints` matcher
/// paints while it matches.
void expectWithShadows(Object? actual, Object matcher) {
  debugDisableShadows = false;
  try {
    expect(actual, matcher);
  } finally {
    debugDisableShadows = true;
  }
}
