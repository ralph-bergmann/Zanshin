// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_elevation.dart';
import '../design/zs_values.dart';

/// Nami, the Zanshin mark: three gold waves on an indigo tile (DS components/brand/NamiMark.jsx; app icon #04).
///
/// A leaf render box painting the DS's 256-unit SVG at [size]: the tile (radius [size] × .2266, `rx="58"`) in a
/// vertical gradient from `--night-icon` to `--night-2` under the radial `--gold-400` glow at .1 opacity (centre .5 / .6,
/// radius .7 of the box), then the three waves in `--gold-200`, `--gold-400` and `--gold-600` with round caps and
/// joins. Optical sizing: at chrome sizes (≤ 48 px) the waves are drawn heavier, 13 / 15 / 17 units, so they hold at
/// 28 px; larger sizes use the icon's 9 / 11 / 13. [chip] adds `--shadow-mark` (its hairline and small drop; DS
/// components/brand/brand.css:3, tokens/effects.css:29, :55).
///
/// VoiceOver reads it as the image "Zanshin" (the DS's `title`).
class ZsNamiMark extends LeafRenderObjectWidget {
  /// The mark at [size], as a [chip] with its shadow or bare.
  const ZsNamiMark({this.size = 28, this.chip = false, super.key});

  /// The side in logical pixels.
  final double size;

  /// Whether the tile carries `--shadow-mark` (the project capsule's chip).
  final bool chip;

  @override
  RenderZsNamiMark createRenderObject(BuildContext context) => RenderZsNamiMark(
    side: size,
    colors: ZsColors.of(context),
    shadow: chip ? ZsElevation.of(context).shadowMark : null,
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
  );

  @override
  void updateRenderObject(BuildContext context, RenderZsNamiMark renderObject) {
    renderObject
      ..side = size
      ..colors = ZsColors.of(context)
      ..shadow = chip ? ZsElevation.of(context).shadowMark : null
      ..textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr;
  }
}

/// One wave of the mark: its path in the 256-unit view box and its two stroke widths (DS NamiMark.jsx:5-9).
typedef _Wave = ({Path path, Color Function(ZsColors colors) colour, double thin, double heavy});

/// The render box of a [ZsNamiMark].
class RenderZsNamiMark extends RenderBox {
  /// Creates the render box.
  RenderZsNamiMark({
    required this._side,
    required this._colors,
    required this._shadow,
    required this._textDirection,
  });

  /// The SVG's view box (`viewBox="0 0 256 256"`).
  static const double _box = 256;

  /// The tile's corner radius in the view box (`rx="58"`; × size / 256 = size × .2266).
  static const double _tileRadius = 58;

  /// Up to this side the waves take their heavy strokes (`const heavy = size <= 48`).
  static const double _heavyUpTo = 48;

  /// The radial glow's opacity at its centre (`stopOpacity="0.1"`).
  static const _glow = .1;

  /// The waves (DS NamiMark.jsx:5-9). The SVG's `T` repeats the previous `Q`'s control point mirrored through the
  /// current point.
  static final _waves = <_Wave>[
    // M 28 92 Q 72 60, 116 92 T 196 92 Q 218 84, 228 90
    (
      path: Path()
        ..moveTo(28, 92)
        ..quadraticBezierTo(72, 60, 116, 92)
        ..quadraticBezierTo(160, 124, 196, 92)
        ..quadraticBezierTo(218, 84, 228, 90),
      colour: (colors) => colors.gold200,
      thin: 9,
      heavy: 13,
    ),
    // M 24 134 Q 76 100, 132 134 T 212 134 Q 226 130, 234 134
    (
      path: Path()
        ..moveTo(24, 134)
        ..quadraticBezierTo(76, 100, 132, 134)
        ..quadraticBezierTo(188, 168, 212, 134)
        ..quadraticBezierTo(226, 130, 234, 134),
      colour: (colors) => colors.gold400,
      thin: 11,
      heavy: 15,
    ),
    // M 22 178 Q 88 138, 154 178 T 234 178
    (
      path: Path()
        ..moveTo(22, 178)
        ..quadraticBezierTo(88, 138, 154, 178)
        ..quadraticBezierTo(220, 218, 234, 178),
      colour: (colors) => colors.gold600,
      thin: 13,
      heavy: 17,
    ),
  ];

  /// The side in logical pixels.
  double get side => _side;
  double _side;
  set side(double value) {
    if (value != _side) {
      _side = value;
      markNeedsLayout();
    }
  }

  /// The colours the tile and the waves take.
  ZsColors get colors => _colors;
  ZsColors _colors;
  set colors(ZsColors value) {
    if (value != _colors) {
      _colors = value;
      markNeedsPaint();
    }
  }

  /// The chip's shadow, or null for a bare mark.
  ZsShadowStack? get shadow => _shadow;
  ZsShadowStack? _shadow;
  set shadow(ZsShadowStack? value) {
    if (value != _shadow) {
      _shadow = value;
      markNeedsPaint();
    }
  }

  /// The direction VoiceOver reads the label in.
  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value != _textDirection) {
      _textDirection = value;
      markNeedsSemanticsUpdate();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(Size.square(_side));

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _side;

  @override
  double computeMaxIntrinsicWidth(double height) => _side;

  @override
  double computeMinIntrinsicHeight(double width) => _side;

  @override
  double computeMaxIntrinsicHeight(double width) => _side;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..isImage = true
      ..label = 'Zanshin'
      ..textDirection = _textDirection;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final double side = math.min(size.width, size.height);
    if (side <= 0) {
      return;
    }
    final Canvas canvas = context.canvas;
    // A box forced to another shape keeps the square tile, centred.
    final Rect tile = Alignment.center.inscribe(Size.square(side), offset & size);
    final shape = RRect.fromRectAndRadius(tile, Radius.circular(side * _tileRadius / _box));
    // CSS paints the list front first; the back part goes down first.
    final ZsShadowStack? shadow = _shadow;
    if (shadow != null) {
      for (final BoxShadow part in shadow.boxShadows.reversed) {
        canvas.drawRRect(shape.shift(part.offset).inflate(part.spreadRadius), part.toPaint());
      }
    }
    final ZsColors colors = _colors;
    canvas
      ..drawRRect(
        shape,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[colors.nightIcon, colors.night2],
          ).createShader(tile),
      )
      ..drawRRect(
        shape,
        Paint()
          ..shader = RadialGradient(
            // `cx="0.5" cy="0.6" r="0.7"` of the bounding box.
            center: const Alignment(0, .2),
            radius: .7,
            colors: <Color>[
              colors.gold400.withValues(alpha: _glow),
              colors.gold400.withValues(alpha: 0),
            ],
          ).createShader(tile),
      );
    final double scale = side / _box;
    final bool heavy = side <= _heavyUpTo;
    canvas
      ..save()
      ..translate(tile.left, tile.top)
      ..scale(scale);
    for (final _Wave wave in _waves) {
      canvas.drawPath(
        wave.path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = heavy ? wave.heavy : wave.thin
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = wave.colour(colors),
      );
    }
    canvas.restore();
  }
}
