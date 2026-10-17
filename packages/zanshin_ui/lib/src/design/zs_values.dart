// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:ui' as ui show Gradient;
import 'dart:ui' show Color, ColorFilter, ImageFilter, Offset, Rect, Shader, lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show BoxShadow;

/// One part of a CSS `box-shadow`, as the design system writes it: offsets, blur and spread in logical pixels.
///
/// Inset parts (such as `--fl-shadow`'s 1 px highlight, DS tokens/effects.css:25) have no [BoxShadow]; `ZsSurface`
/// paints them, see [ZsShadowStack.inset].
@immutable
class ZsShadow {
  /// Creates a shadow part.
  const ZsShadow({
    required this.dx,
    required this.dy,
    required this.blur,
    required this.spread,
    required this.color,
    this.inset = false,
  });

  /// Interpolates every value; parts of different kinds switch at the midpoint.
  factory ZsShadow.lerp(ZsShadow a, ZsShadow b, double t) {
    if (a.inset != b.inset) {
      return t < .5 ? a : b;
    }
    return ZsShadow(
      dx: lerpDouble(a.dx, b.dx, t)!,
      dy: lerpDouble(a.dy, b.dy, t)!,
      blur: lerpDouble(a.blur, b.blur, t)!,
      spread: lerpDouble(a.spread, b.spread, t)!,
      color: Color.lerp(a.color, b.color, t)!,
      inset: a.inset,
    );
  }

  /// Horizontal offset.
  final double dx;

  /// Vertical offset.
  final double dy;

  /// The CSS blur length; CSS blurs with σ = blur / 2.
  final double blur;

  /// The spread; negative values shrink the shadow.
  final double spread;

  /// The shadow's colour.
  final Color color;

  /// Whether this part is drawn inside the box (`inset`).
  final bool inset;

  /// The [BoxShadow.blurRadius] that blurs like CSS's [cssBlur]: CSS uses σ = blur / 2 while [BoxShadow] maps a
  /// radius r to σ = 0.57735·r + 0.5, so r = (σ − 0.5) / 0.57735, never below 0 (`0 14px 36px` → σ 18 → ≈ 30.31).
  static double blurRadiusFor(double cssBlur) => math.max(0, (cssBlur / 2 - 0.5) / 0.57735);

  /// This outer part as a [BoxShadow]; an inset part has none.
  BoxShadow toBoxShadow() {
    assert(!inset, 'An inset shadow has no BoxShadow; paint it from ZsShadowStack.inset.');
    return BoxShadow(color: color, offset: Offset(dx, dy), blurRadius: blurRadiusFor(blur), spreadRadius: spread);
  }

  /// This part with a fully transparent colour; what a part fades from or to.
  ZsShadow get _clear => ZsShadow(
    dx: dx,
    dy: dy,
    blur: blur,
    spread: spread,
    color: color.withValues(alpha: 0),
    inset: inset,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZsShadow &&
          other.dx == dx &&
          other.dy == dy &&
          other.blur == blur &&
          other.spread == spread &&
          other.color == color &&
          other.inset == inset;

  @override
  int get hashCode => Object.hash(dx, dy, blur, spread, color, inset);

  @override
  String toString() => 'ZsShadow(${inset ? 'inset ' : ''}$dx $dy $blur $spread $color)';
}

/// A CSS shadow list: every part in the DS's order, inset parts kept.
@immutable
class ZsShadowStack {
  /// Creates a shadow list.
  const ZsShadowStack(this.parts);

  /// Interpolates part by part; a part only one side has fades in or out.
  factory ZsShadowStack.lerp(ZsShadowStack a, ZsShadowStack b, double t) {
    final int count = math.max(a.parts.length, b.parts.length);
    return ZsShadowStack(<ZsShadow>[
      for (var i = 0; i < count; i++)
        ZsShadow.lerp(
          i < a.parts.length ? a.parts[i] : b.parts[i]._clear,
          i < b.parts.length ? b.parts[i] : a.parts[i]._clear,
          t,
        ),
    ]);
  }

  /// The parts, front first, as in CSS.
  final List<ZsShadow> parts;

  /// The outer parts converted to [BoxShadow]s (see [ZsShadow.blurRadiusFor]); the inset parts are dropped.
  List<BoxShadow> get boxShadows => <BoxShadow>[
    for (final ZsShadow part in parts)
      if (!part.inset) part.toBoxShadow(),
  ];

  /// The inset parts, which no [BoxShadow] can draw; `ZsSurface` paints them.
  List<ZsShadow> get inset => <ZsShadow>[
    for (final ZsShadow part in parts)
      if (part.inset) part,
  ];

  @override
  bool operator ==(Object other) => identical(this, other) || other is ZsShadowStack && listEquals(other.parts, parts);

  @override
  int get hashCode => Object.hashAll(parts);

  @override
  String toString() => 'ZsShadowStack($parts)';
}

/// One colour stop of a CSS gradient, with its position as written: in percent ([percent]), in pixels ([px]), or
/// none (CSS spreads unpositioned stops evenly).
@immutable
class ZsGradientStop {
  /// Creates a stop.
  const ZsGradientStop(this.color, {this.percent, this.px});

  /// Interpolates the colour, and a position both sides have; otherwise the position switches at the midpoint.
  factory ZsGradientStop.lerp(ZsGradientStop a, ZsGradientStop b, double t) => ZsGradientStop(
    Color.lerp(a.color, b.color, t)!,
    percent: _lerpNullable(a.percent, b.percent, t),
    px: _lerpNullable(a.px, b.px, t),
  );

  /// The stop's colour.
  final Color color;

  /// The position in percent of the gradient line, if the DS gives one.
  final double? percent;

  /// The position in logical pixels, if the DS gives one (the sheen's 46 px band).
  final double? px;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZsGradientStop && other.color == color && other.percent == percent && other.px == px;

  @override
  int get hashCode => Object.hash(color, percent, px);

  @override
  String toString() => 'ZsGradientStop($color, percent: $percent, px: $px)';
}

/// A CSS `linear-gradient`: its angle in degrees and its stops.
@immutable
class ZsLinearGradient {
  /// Creates a linear gradient.
  const ZsLinearGradient({required this.angle, required this.stops});

  /// Interpolates the angle and, for equally long stop lists, every stop.
  factory ZsLinearGradient.lerp(ZsLinearGradient a, ZsLinearGradient b, double t) =>
      ZsLinearGradient(angle: lerpDouble(a.angle, b.angle, t)!, stops: _lerpStops(a.stops, b.stops, t));

  /// The CSS angle in degrees (180 runs top to bottom).
  final double angle;

  /// The stops, in order.
  final List<ZsGradientStop> stops;

  /// The paint inputs of this gradient over [rect], the box it fills (CSS Images 3 §3.1).
  ///
  /// The gradient line runs through the box's centre at [angle] (0 points up, 90 right) and is |w·sin θ| + |h·cos θ|
  /// long. A stop in percent sits at that share of the line, one in px that far along it; the first stop without a
  /// position sits at 0 %, the last at 100 %, a position behind an earlier one moves up to it, and every other run
  /// of unpositioned stops is spread evenly between its neighbours. The result runs from the first stop (`from`) to
  /// the last (`to`), with the stops normalised to that span — what `ui.Gradient.linear` takes.
  ({Offset from, Offset to, List<Color> colors, List<double> stops}) resolve(Rect rect) {
    final double radians = angle * math.pi / 180;
    final direction = Offset(math.sin(radians), -math.cos(radians));
    final double length = (rect.width * math.sin(radians)).abs() + (rect.height * math.cos(radians)).abs();
    final Offset start = rect.center - direction * (length / 2);
    final positions =
        <double?>[
            for (final ZsGradientStop stop in stops)
              stop.px ?? (stop.percent == null ? null : stop.percent! / 100 * length),
          ]
          ..first ??= 0
          ..last ??= length;
    double floor = double.negativeInfinity;
    for (var i = 0; i < positions.length; i++) {
      final double? at = positions[i];
      if (at != null) {
        floor = math.max(floor, at);
        positions[i] = floor;
      }
    }
    for (var i = 1; i < positions.length - 1; i++) {
      if (positions[i] != null) {
        continue;
      }
      var next = i;
      while (positions[next] == null) {
        next++;
      }
      final double before = positions[i - 1]!;
      final double after = positions[next]!;
      for (var k = i; k < next; k++) {
        positions[k] = before + (after - before) * (k - i + 1) / (next - i + 1);
      }
      i = next;
    }
    final double first = positions.first!;
    final double span = positions.last! - first;
    return (
      from: start + direction * first,
      to: start + direction * positions.last!,
      colors: <Color>[for (final ZsGradientStop stop in stops) stop.color],
      stops: <double>[
        for (final double? at in positions)
          if (span == 0) 0 else (at! - first) / span,
      ],
    );
  }

  /// A shader that paints this gradient over [rect] (see [resolve]); past the first and the last stop it keeps their
  /// colours, as CSS does.
  Shader createShader(Rect rect) {
    final ({Offset from, Offset to, List<Color> colors, List<double> stops}) line = resolve(rect);
    return ui.Gradient.linear(line.from, line.to, line.colors, line.stops);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ZsLinearGradient && other.angle == angle && listEquals(other.stops, stops);

  @override
  int get hashCode => Object.hash(angle, Object.hashAll(stops));

  @override
  String toString() => 'ZsLinearGradient($angle, $stops)';
}

/// A CSS `radial-gradient(<width>% <height>% at <x>% <y>%, …)`: the ellipse and its centre in percent of the box,
/// and its stops.
@immutable
class ZsRadialGradient {
  /// Creates a radial gradient.
  const ZsRadialGradient({
    required this.width,
    required this.height,
    required this.centerX,
    required this.centerY,
    required this.stops,
  });

  /// Interpolates the geometry and, for equally long stop lists, every stop.
  factory ZsRadialGradient.lerp(ZsRadialGradient a, ZsRadialGradient b, double t) => ZsRadialGradient(
    width: lerpDouble(a.width, b.width, t)!,
    height: lerpDouble(a.height, b.height, t)!,
    centerX: lerpDouble(a.centerX, b.centerX, t)!,
    centerY: lerpDouble(a.centerY, b.centerY, t)!,
    stops: _lerpStops(a.stops, b.stops, t),
  );

  /// The ellipse's horizontal radius in percent of the box width.
  final double width;

  /// The ellipse's vertical radius in percent of the box height.
  final double height;

  /// The centre's x in percent of the box width.
  final double centerX;

  /// The centre's y in percent of the box height (negative: above the box).
  final double centerY;

  /// The stops, in order.
  final List<ZsGradientStop> stops;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZsRadialGradient &&
          other.width == width &&
          other.height == height &&
          other.centerX == centerX &&
          other.centerY == centerY &&
          listEquals(other.stops, stops);

  @override
  int get hashCode => Object.hash(width, height, centerX, centerY, Object.hashAll(stops));

  @override
  String toString() => 'ZsRadialGradient($width% $height% at $centerX% $centerY%, $stops)';
}

/// The window canvas `--canvas` (DS tokens/colors.css:25): a flat radial lift painted over a linear base.
@immutable
class ZsCanvasGradient {
  /// Creates the canvas.
  const ZsCanvasGradient({required this.radial, required this.linear});

  /// Interpolates both layers.
  factory ZsCanvasGradient.lerp(ZsCanvasGradient a, ZsCanvasGradient b, double t) => ZsCanvasGradient(
    radial: ZsRadialGradient.lerp(a.radial, b.radial, t),
    linear: ZsLinearGradient.lerp(a.linear, b.linear, t),
  );

  /// The radial lift, the upper layer.
  final ZsRadialGradient radial;

  /// The linear base, the lower layer.
  final ZsLinearGradient linear;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ZsCanvasGradient && other.radial == radial && other.linear == linear;

  @override
  int get hashCode => Object.hash(radial, linear);

  @override
  String toString() => 'ZsCanvasGradient($radial, $linear)';
}

/// The glass filter `blur(<n>px) saturate(<x>)` (DS tokens/effects.css:36-38); a token that is `none` is null.
@immutable
class ZsGlassFilter {
  /// Creates a glass filter.
  const ZsGlassFilter({required this.blur, required this.saturate});

  /// The CSS blur length in logical pixels.
  final double blur;

  /// The saturation factor (1 leaves colours as they are).
  final double saturate;

  /// The CSS `saturate(s)` colour matrix (Filter Effects 1 §"saturate"), row-major as [ColorFilter.matrix] takes it,
  /// with [alpha] in the alpha row: below 1 it fades the filtered result into what lies beneath, as CSS opacity does
  /// (`ZsSheet`'s scrim fades its blur this way).
  static List<double> saturateMatrix(double s, {double alpha = 1}) => <double>[
    ...<double>[.213 + .787 * s, .715 - .715 * s, .072 - .072 * s, 0, 0],
    ...<double>[.213 - .213 * s, .715 + .285 * s, .072 - .072 * s, 0, 0],
    ...<double>[.213 - .213 * s, .715 - .715 * s, .072 + .928 * s, 0, 0],
    ...<double>[0, 0, 0, alpha, 0],
  ];

  /// This filter as one [ImageFilter], for a `BackdropFilter`: the blur first (CSS `blur(N)` takes σ = N), then the
  /// saturation ([saturateMatrix], with [alpha]), in the order CSS applies a filter list.
  ImageFilter toImageFilter({double alpha = 1}) => ImageFilter.compose(
    outer: ColorFilter.matrix(saturateMatrix(saturate, alpha: alpha)),
    inner: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
  );

  /// Interpolates two filters; with `none` on one side the filter switches at the midpoint.
  static ZsGlassFilter? lerp(ZsGlassFilter? a, ZsGlassFilter? b, double t) {
    if (a == null || b == null) {
      return t < .5 ? a : b;
    }
    return ZsGlassFilter(blur: lerpDouble(a.blur, b.blur, t)!, saturate: lerpDouble(a.saturate, b.saturate, t)!);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ZsGlassFilter && other.blur == blur && other.saturate == saturate;

  @override
  int get hashCode => Object.hash(blur, saturate);

  @override
  String toString() => 'ZsGlassFilter(blur: $blur, saturate: $saturate)';
}

double? _lerpNullable(double? a, double? b, double t) {
  if (a == null || b == null) {
    return t < .5 ? a : b;
  }
  return lerpDouble(a, b, t);
}

List<ZsGradientStop> _lerpStops(List<ZsGradientStop> a, List<ZsGradientStop> b, double t) {
  if (a.length != b.length) {
    return t < .5 ? a : b;
  }
  return <ZsGradientStop>[for (var i = 0; i < a.length; i++) ZsGradientStop.lerp(a[i], b[i], t)];
}
