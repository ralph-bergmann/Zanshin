// SPDX-License-Identifier: MIT

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'splash_card.dart';

// ---------------------------------------------------------------- colours

const _indigoTop = Color(0xFF1D2540);
const _indigoMid = Color(0xFF131831);
const _indigoBottom = Color(0xFF10142A);
const _lift = Color(0xFF6078B2);
const _warm = Color(0xFFDCA85B);
const _shade = Color(0xFF090B16);
const _goldLight = Color(0xFFFFF6E4);
const _gold = Color(0xFFF4CF80);
const _goldMid = Color(0xFFDCA85B);
const _goldDeep = Color(0xFFB58346);
const _goldDark = Color(0xFFD9A755);

/// `#FFFFFF` @ 10 % — the light edge along the card's top.
const _edgeWhite = Color(0x1AFFFFFF);

/// `#FFFFFF` @ 8 % — the footer's divider.
const _dividerWhite = Color(0x14FFFFFF);

/// `#FFFFFF` @ 7 % — the progress rail.
const _railWhite = Color(0x12FFFFFF);

// ------------------------------------------------------------------ text

/// The version part of the footer's version line.
const splashVersionStyle = TextStyle(
  fontFamily: ZsType.monoFamily,
  fontSize: 13,
  color: Color(0xFFE7DCC4),
);

/// The `· Build <n>` part of the footer's version line.
const splashBuildStyle = TextStyle(
  fontFamily: ZsType.monoFamily,
  fontSize: 13,
  color: Color(0xFF8792B4),
);

/// The boot status line, bottom right.
const splashStatusStyle = TextStyle(
  fontFamily: ZsType.sansFamily,
  fontSize: 13,
  color: Color(0xFF98A3C2),
);

const _kanjiStyle = TextStyle(
  fontFamily: ZsType.kanjiFamily,
  fontSize: 44,
  fontWeight: FontWeight.w500,
  letterSpacing: 1.8,
  color: _gold,
);

const _watermarkStyle = TextStyle(
  fontFamily: ZsType.kanjiFamily,
  fontSize: 144,
  fontWeight: FontWeight.w600,
  height: 1,
  color: Color(0x0AF4CF80), // gold @ 4 %
);

const _taglineStyle = TextStyle(
  fontFamily: ZsType.sansFamily,
  fontSize: 13,
  fontWeight: FontWeight.w500,
  fontVariations: <FontVariation>[FontVariation.weight(500)],
  letterSpacing: 1.96,
  color: Color(0xFFA9B3D0),
);

// -------------------------------------------------------------- geometry

/// Side padding; also the left edge of the version line and the divider.
const double _padX = 36;

/// Shared alphabetic baseline of the version and status lines.
const double _footerBaseline = 370;

/// Right edge of the status line and of the divider.
const double _statusRight = 584;

const double _dividerY = 337;

/// Centre of the status dot, `_dotGap` left of the status box: the HTML's
/// `gap: 8` plus the dot's 3 px radius.
const double _dotGap = 11;
const double _dotY = 366;
const double _dotRadius = 3;
const double _dotRingRadius = 6;
const _dotRingAlpha = 0.16;

const double _kanjiBaseline = 181;
const double _lockupGap = 20;
const double _taglineBaseline = 217;
const _taglineText = 'JUJUTSU CLIENT';
const _kanjiText = '残心';

const _wordmarkScale = 0.38;
const double _wordmarkWidth = 562 * _wordmarkScale;
const double _wordmarkHeight = 100 * _wordmarkScale;
const double _wordmarkStroke = 7.37 * _wordmarkScale;
const double _wordmarkTop = _kanjiBaseline - _wordmarkHeight;

const double _watermarkCentre = 517;
const _watermarkBaselines = <double>[148, 296];

/// The ornament reuses the app icon's wave paths at 124 % card width.
const _ornamentScale = 3.045;
const _ornamentOpacity = 0.05;
const _waveOpacities = <double>[0.95, 0.77, 0.59];
const _waveStrokes = <double>[5.58, 6.82, 8.06];

const double _railHeight = 2;
const _runnerFraction = 0.38;
const _runnerStart = -0.4;
const _runnerPeriod = Duration(milliseconds: 2100);
const _runnerCurve = Cubic(0.65, 0.05, 0.35, 0.95);
const _dotPeriod = Duration(milliseconds: 1850);
const _dotMinAlpha = 0.35;

/// Where the runner stands when "reduce motion" froze it.
const _frozenRunnerPhase = 0.5;

/// The two widget-backed pieces of the splash card. Everything else is painted.
enum SplashSlot {
  /// The footer's version line, bottom left.
  version,

  /// The boot status line, bottom right.
  status,
}

/// The splash card's design, painted in one render pass.
///
/// Only the two footer texts are widgets, so they can follow their listenables
/// while the card is on screen; the rest is a single [Canvas] pass.
class SplashCardBody extends SlottedMultiChildRenderObjectWidget<SplashSlot, RenderBox> {
  const SplashCardBody({
    required this.vsync,
    required this.animate,
    required this.version,
    required this.status,
    super.key,
  });

  /// Drives the runner and the status dot.
  final TickerProvider vsync;

  /// False under "reduce motion": no ticker runs and nothing repaints.
  final bool animate;

  /// Occupies [SplashSlot.version].
  final Widget version;

  /// Occupies [SplashSlot.status].
  final Widget status;

  @override
  Iterable<SplashSlot> get slots => SplashSlot.values;

  @override
  Widget? childForSlot(SplashSlot slot) => switch (slot) {
    SplashSlot.version => version,
    SplashSlot.status => status,
  };

  @override
  SplashCardRenderBox createRenderObject(BuildContext context) => SplashCardRenderBox(vsync: vsync, animate: animate);

  @override
  void updateRenderObject(BuildContext context, SplashCardRenderBox renderObject) {
    renderObject.animate = animate;
  }
}

/// Paints the splash card and places the two footer texts on its baseline.
class SplashCardRenderBox extends RenderBox with SlottedContainerRenderObjectMixin<SplashSlot, RenderBox> {
  SplashCardRenderBox({required TickerProvider vsync, required bool animate}) {
    _animate = animate;
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;

  /// Time the ticker has run; the only input to runner and dot.
  Duration _elapsed = Duration.zero;

  /// Left edge of the status box, remembered during layout: the dot hangs off
  /// it, so an empty status still puts the dot in a sane place.
  double _statusLeft = _statusRight;

  List<ui.Gradient>? _background;
  Size? _backgroundSize;
  List<Path>? _ornament;
  ui.Shader? _runnerShader;
  double? _runnerShaderWidth;
  late Path _wordmark;
  ui.Shader? _wordmarkShader;
  double? _wordmarkLeft;
  TextPainter? _lockupKanji;
  TextPainter? _tagline;
  List<TextPainter>? _watermark;

  /// False under "reduce motion".
  bool get animate => _animate;
  late bool _animate;

  set animate(bool value) {
    if (_animate == value) {
      return;
    }
    _animate = value;
    _syncTicker();
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _syncTicker();
  }

  @override
  void detach() {
    _ticker.stop();
    super.detach();
  }

  @override
  void dispose() {
    // The render object's element unmounts before `State.dispose`, so stopping
    // here keeps `SingleTickerProviderStateMixin`'s assert happy.
    _ticker
      ..stop()
      ..dispose();
    _lockupKanji?.dispose();
    _tagline?.dispose();
    for (final TextPainter painter in _watermark ?? const <TextPainter>[]) {
      painter.dispose();
    }
    _disposeBackground();
    _runnerShader?.dispose();
    _runnerShader = null;
    _wordmarkShader?.dispose();
    _wordmarkShader = null;
    super.dispose();
  }

  void _disposeBackground() {
    for (final ui.Gradient gradient in _background ?? const <ui.Gradient>[]) {
      gradient.dispose();
    }
    _background = null;
  }

  void _syncTicker() {
    if (_animate && attached) {
      if (!_ticker.isActive) {
        _ticker.start();
      }
    } else {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    markNeedsPaint();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(splashWindowSize);

  @override
  void performLayout() {
    size = constraints.constrain(splashWindowSize);
    final slotConstraints = BoxConstraints.loose(Size(size.width - 2 * _padX, size.height));

    final RenderBox? version = childForSlot(SplashSlot.version);
    if (version != null) {
      version.layout(slotConstraints, parentUsesSize: true);
      _parentDataOf(version).offset = Offset(_padX, _footerBaseline - _baselineOf(version));
    }

    final RenderBox? status = childForSlot(SplashSlot.status);
    if (status == null) {
      _statusLeft = _statusRight;
      return;
    }
    status.layout(slotConstraints, parentUsesSize: true);
    _statusLeft = _statusRight - status.size.width;
    _parentDataOf(status).offset = Offset(_statusLeft, _footerBaseline - _baselineOf(status));
  }

  static BoxParentData _parentDataOf(RenderBox child) => child.parentData! as BoxParentData;

  static double _baselineOf(RenderBox child) =>
      child.getDistanceToBaseline(TextBaseline.alphabetic) ?? child.size.height;

  @override
  void paint(PaintingContext context, Offset offset) {
    final Canvas canvas = context.canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    _paintCard(canvas);
    canvas.restore();
    // Outside the manual transform: a child that is its own repaint boundary
    // gets a layer, and layers do not inherit canvas transforms.
    _paintSlot(context, offset, SplashSlot.version);
    _paintSlot(context, offset, SplashSlot.status);
  }

  void _paintSlot(PaintingContext context, Offset offset, SplashSlot slot) {
    final RenderBox? child = childForSlot(slot);
    if (child != null) {
      context.paintChild(child, offset + _parentDataOf(child).offset);
    }
  }

  void _paintCard(Canvas canvas) {
    final Rect rect = Offset.zero & size;
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(splashCardRadius)));
    _paintBackground(canvas, rect);
    _paintTopEdge(canvas, rect);
    _paintOrnament(canvas);
    _paintWatermark(canvas);
    _paintLockup(canvas);
    _paintFooter(canvas);
    _paintProgress(canvas, rect);
    canvas.restore();
    _paintBorder(canvas, rect);
  }

  // ------------------------------------------------------------ background

  void _paintBackground(Canvas canvas, Rect rect) {
    final paint = Paint();
    for (final ui.Gradient gradient in _backgroundGradients(rect)) {
      canvas.drawRect(rect, paint..shader = gradient);
    }
  }

  /// The four stacked gradients, back to front. The three radials are ellipses
  /// with independent radii, so they are built from a scale matrix rather than
  /// approximated with a circle.
  List<ui.Gradient> _backgroundGradients(Rect rect) {
    final List<ui.Gradient>? cached = _background;
    if (cached != null && _backgroundSize == rect.size) {
      return cached;
    }
    _disposeBackground();
    final double w = rect.width;
    final double h = rect.height;
    _backgroundSize = rect.size;
    return _background = <ui.Gradient>[
      ui.Gradient.linear(
        Offset.zero,
        Offset(0.42 * w, h),
        const <Color>[_indigoTop, _indigoMid, _indigoBottom],
        const <double>[0, 0.72, 1],
      ),
      _radial(Offset(0.08 * w, 0), 0.9 * w, 1.2 * h, _lift, 0.34, 0.58),
      _radial(Offset(w, h), 0.7 * w, 0.9 * h, _warm, 0.2, 0.6),
      _radial(Offset(0.5 * w, 1.18 * h), 1.2 * w, 0.8 * h, _shade, 0.85, 0.65),
    ];
  }

  static ui.Gradient _radial(Offset centre, double rx, double ry, Color colour, double alpha, double edge) =>
      ui.Gradient.radial(
        Offset.zero,
        1,
        <Color>[colour.withValues(alpha: alpha), colour.withValues(alpha: 0)],
        <double>[0, edge],
        TileMode.clamp,
        _affine(rx, ry, centre.dx, centre.dy).storage,
      );

  /// A scale-then-translate matrix, spelled out column by column: the
  /// `Matrix4` mutators that would build it are deprecated.
  static Matrix4 _affine(double sx, double sy, double tx, double ty) =>
      Matrix4(sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1);

  void _paintTopEdge(Canvas canvas, Rect rect) {
    final edge = Rect.fromLTWH(0, 0, rect.width, 2);
    canvas.drawRect(
      edge,
      Paint()
        ..shader = ui.Gradient.linear(edge.topLeft, edge.bottomLeft, const <Color>[
          _edgeWhite,
          Color(0x00FFFFFF),
        ]),
    );
  }

  // -------------------------------------------------------------- ornament

  void _paintOrnament(Canvas canvas) {
    final List<Path> paths = _ornament ??= _ornamentPaths();
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (var i = 0; i < paths.length; i++) {
      // The three waves never overlap at this scale, so folding the group's
      // 5 % into each line's own opacity matches the SVG exactly.
      canvas.drawPath(
        paths[i],
        paint
          ..color = _gold.withValues(alpha: _ornamentOpacity * _waveOpacities[i])
          ..strokeWidth = _waveStrokes[i] * _ornamentScale,
      );
    }
  }

  /// The app icon's three waves, moved into card coordinates:
  /// `translate(-56 18) scale(3.045) translate(-14 -76)`.
  static List<Path> _ornamentPaths() {
    final Matrix4 transform = _affine(
      _ornamentScale,
      _ornamentScale,
      -56 - _ornamentScale * 14,
      18 - _ornamentScale * 76,
    );
    return <Path>[
      Path()
        ..moveTo(28, 92)
        ..quadraticBezierTo(72, 60, 116, 92)
        ..quadraticBezierTo(160, 124, 196, 92)
        ..quadraticBezierTo(218, 84, 228, 90),
      Path()
        ..moveTo(24, 134)
        ..quadraticBezierTo(76, 100, 132, 134)
        ..quadraticBezierTo(188, 168, 212, 134)
        ..quadraticBezierTo(226, 130, 234, 134),
      Path()
        ..moveTo(22, 178)
        ..quadraticBezierTo(88, 138, 154, 178)
        ..quadraticBezierTo(220, 218, 234, 178),
    ].map((path) => path.transform(transform.storage)).toList();
  }

  // -------------------------------------------------------------- lettering

  void _paintWatermark(Canvas canvas) {
    final List<TextPainter> painters = _watermark ??= <TextPainter>[
      _painter('残', _watermarkStyle),
      _painter('心', _watermarkStyle),
    ];
    for (var i = 0; i < painters.length; i++) {
      final TextPainter painter = painters[i];
      canvas.save();
      painter.paint(
        canvas,
        Offset(
          _watermarkCentre - painter.width / 2,
          _watermarkBaselines[i] - painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
        ),
      );
      canvas.restore();
    }
  }

  void _paintLockup(Canvas canvas) {
    final TextPainter kanji = _lockupKanji ??= _painter(_kanjiText, _kanjiStyle);
    // Centre the whole group rather than trusting the SVG's x = 117: a
    // font-metric difference would otherwise push the lock-up off-centre.
    final double left = (size.width - (kanji.width + _lockupGap + _wordmarkWidth)) / 2;
    kanji.paint(
      canvas,
      Offset(left, _kanjiBaseline - kanji.computeDistanceToActualBaseline(TextBaseline.alphabetic)),
    );

    _buildWordmark(left + kanji.width + _lockupGap);
    canvas.drawPath(
      _wordmark,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _wordmarkStroke
        ..shader = _wordmarkShader,
    );

    final TextPainter tagline = _tagline ??= _painter(_taglineText, _taglineStyle);
    tagline.paint(
      canvas,
      Offset(
        (size.width - tagline.width) / 2,
        _taglineBaseline - tagline.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      ),
    );
  }

  /// The wordmark is drawn, not set: a monolinear geometric sans with a
  /// crossbar-less A, at a 100-unit cap height and 32 units of tracking.
  void _buildWordmark(double left) {
    if (_wordmarkLeft == left) {
      return;
    }
    _wordmarkLeft = left;
    _wordmark = _wordmarkUnitPath().transform(_affine(_wordmarkScale, _wordmarkScale, left, _wordmarkTop).storage);
    _wordmarkShader?.dispose();
    _wordmarkShader = ui.Gradient.linear(
      Offset(left, _wordmarkTop),
      Offset(left + 0.4 * _wordmarkWidth, _wordmarkTop + _wordmarkHeight),
      const <Color>[_goldLight, _gold, _goldDark],
      const <double>[0, 0.5, 1],
    );
  }

  static Path _wordmarkUnitPath() => Path()
    ..moveTo(0, 0) // Z
    ..lineTo(62, 0)
    ..lineTo(0, 100)
    ..lineTo(62, 100)
    ..moveTo(94, 100) // A, no crossbar
    ..lineTo(126, 0)
    ..lineTo(158, 100)
    ..moveTo(190, 100) // N
    ..lineTo(190, 0)
    ..lineTo(252, 100)
    ..lineTo(252, 0)
    ..moveTo(339, 19) // S, two half ellipses
    ..arcToPoint(
      const Offset(313, 50),
      radius: const Radius.elliptical(27, 22),
      largeArc: true,
      clockwise: false,
    )
    ..arcToPoint(const Offset(287, 81), radius: const Radius.elliptical(27, 22), largeArc: true)
    ..moveTo(374, 0) // H
    ..lineTo(374, 100)
    ..moveTo(436, 0)
    ..lineTo(436, 100)
    ..moveTo(374, 50)
    ..lineTo(436, 50)
    ..moveTo(468, 0) // I
    ..lineTo(468, 100)
    ..moveTo(500, 100) // N
    ..lineTo(500, 0)
    ..lineTo(562, 100)
    ..lineTo(562, 0);

  static TextPainter _painter(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();

  // ----------------------------------------------------------------- footer

  void _paintFooter(Canvas canvas) {
    canvas.drawLine(
      const Offset(_padX, _dividerY),
      Offset(size.width - _padX, _dividerY),
      Paint()
        ..color = _dividerWhite
        ..strokeWidth = 1,
    );

    final double alpha = _dotAlpha();
    final centre = Offset(_statusLeft - _dotGap, _dotY);
    canvas
      ..drawCircle(centre, _dotRingRadius, Paint()..color = _gold.withValues(alpha: alpha * _dotRingAlpha))
      ..drawCircle(centre, _dotRadius, Paint()..color = _gold.withValues(alpha: alpha));
  }

  /// The dot breathes 0.35 → 1 → 0.35 over [_dotPeriod]; frozen it stays lit.
  double _dotAlpha() {
    if (!_animate) {
      return 1;
    }
    final double phase = _phase(_dotPeriod);
    final double ramp = phase <= 0.5 ? phase * 2 : 2 - phase * 2;
    return _dotMinAlpha + (1 - _dotMinAlpha) * Curves.easeInOut.transform(ramp);
  }

  // --------------------------------------------------------------- progress

  void _paintProgress(Canvas canvas, Rect rect) {
    final double top = rect.height - _railHeight;
    canvas.drawRect(Rect.fromLTWH(0, top, rect.width, _railHeight), Paint()..color = _railWhite);

    final double width = rect.width * _runnerFraction;
    final double travel = rect.width * (1 - _runnerStart);
    final double left = _runnerStart * rect.width + _runnerPhase() * travel;
    canvas
      ..save()
      ..translate(left, top)
      ..drawRect(Rect.fromLTWH(0, 0, width, _railHeight), Paint()..shader = _runner(width))
      ..restore();
  }

  double _runnerPhase() => _animate ? _runnerCurve.transform(_phase(_runnerPeriod)) : _frozenRunnerPhase;

  ui.Shader _runner(double width) {
    final ui.Shader? cached = _runnerShader;
    if (cached != null && _runnerShaderWidth == width) {
      return cached;
    }
    cached?.dispose();
    _runnerShaderWidth = width;
    return _runnerShader = ui.Gradient.linear(
      Offset.zero,
      Offset(width, 0),
      <Color>[_gold.withValues(alpha: 0), _gold, _goldMid, _goldDeep.withValues(alpha: 0)],
      const <double>[0, 0.35, 0.7, 1],
    );
  }

  /// Where in a [period]-long loop the ticker stands, in `0…1`.
  double _phase(Duration period) => (_elapsed.inMicroseconds % period.inMicroseconds) / period.inMicroseconds;

  // ----------------------------------------------------------------- border

  /// The inner gold hairline. The outer drop shadow is the native window's —
  /// see `WindowingBootstrap.swift`.
  void _paintBorder(Canvas canvas, Rect rect) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), const Radius.circular(splashCardRadius - 0.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _gold.withValues(alpha: 0.1),
    );
  }
}
