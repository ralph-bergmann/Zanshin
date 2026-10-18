// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_values.dart';
import 'zs_fade.dart';

/// The one paint path every material shares: the CSS box of `.zs-glass` and its siblings (DS components/base.css:2,
/// :7), painted in one render box from 11.1's tokens. `ZsGlass`, `ZsMenuMaterial`, `ZsSheet` and `ZsWindowFill`
/// pick the values; the other glass builds (the @ pill with its own `--at-chrome-edge` border, the large primary's
/// gold layer over the glass) compose or extend `ZsSurface` in their own stories. The folder `materials/` is
/// Claude's proposal (Story 11.2).
///
/// **Geometry** (CSS Backgrounds 3, border-box sizing): the outer shape is the box at [radius], each corner clamped
/// to half the shorter side (a 36 px pill is radius 18); the padding box lies [borderWidth] inside it (none without
/// a [border]) at the radius minus that width. The child is laid out inside the padding box less [padding].
///
/// **Paint order:** [fill] over the outer shape; [sheen] from the padding box's top down, over the outer shape but
/// nothing above the padding box (the DS's 46 px band keeps its scale in a shorter box); each inset part of
/// [shadow] (`--fl-shadow`'s `inset 0 1px 0` becomes a 1 px line along the top that thins along the corner arcs —
/// Claude's proposal for "painted as a line"); the [border]; the callout [arrow]; the child, clipped to the padding
/// box when [clip]. The outer parts of [shadow] (11.1's `boxShadows`, σ = blur / 2) paint after the surface, clipped
/// to outside its shape — CSS never paints an outer shadow under the box, and so a glass surface never blurs its
/// own shadow (Claude's proposal).
///
/// **Glass:** with a [filter], a `ClipRRect` of the outer shape and a grouped `BackdropFilter` sit between the
/// shadows and the box; it joins the nearest `BackdropGroup` (11.3 mounts one per window) and blurs ungrouped
/// without one. A null filter (reduce transparency, increased contrast) leaves no filter and no clip in the tree,
/// and the content keeps its state across the switch.
///
/// **Fading** (Story 11.3): a surface fades only through an enclosing [ZsFade], never through an `Opacity` or a
/// `FadeTransition` above it — the engine then paints the filter into an empty layer and the blur is gone for the
/// whole fade. At the fade a = [ZsFade.of] < 1 the box sits under an `Opacity` of a inside the filter, the filter's
/// colour matrix takes the alpha a·(1 − Lα) / (1 − a·Lα) (Lα the [fill]'s alpha), so the blurred backdrop and the
/// faded box add up to CSS `opacity` a over the whole surface (the scrim's formula, `ZsSheet`), and the drop shadows
/// paint at a times their alpha. At a = 0 the filter and its clip leave the tree and the content keeps its state.
/// Without a filter (reduce transparency, increased contrast) the box fades through the same `Opacity`.
///
/// Every surface shows the arrow cursor (`SystemMouseCursors.basic`), takes the pointer inside its shape (the
/// rounded corners let it through) and is a semantics container. Its content's text and icons default to `--text`,
/// as every DS surface sets `color:var(--text)`, so content shown through an overlay never takes its anchor's colour.
class ZsSurface extends StatefulWidget {
  /// Paints [child] on the surface the values describe.
  const ZsSurface({
    required this.fill,
    required this.shadow,
    required this.radius,
    required this.child,
    this.sheen,
    this.border,
    this.filter,
    this.clip = false,
    this.padding = EdgeInsets.zero,
    this.arrow = false,
    super.key,
  });

  /// The width of every material's border, `border:1px solid` (DS components/base.css:7).
  static const double borderWidth = 1;

  /// The fill colour, painted under everything else; also the arrow's colour.
  final Color fill;

  /// The sheen over the fill (`--fl-sheen`), or null for none.
  final ZsLinearGradient? sheen;

  /// The border colour, or null for a surface without a border (the window fill).
  final Color? border;

  /// The CSS shadow list: its inset parts paint inside the box, its outer parts around it.
  final ZsShadowStack shadow;

  /// The corner radius before clamping.
  final double radius;

  /// The backdrop filter of glass, or null for an opaque surface.
  final ZsGlassFilter? filter;

  /// Whether the child is clipped to the padding box (`overflow:hidden`).
  final bool clip;

  /// The space between the border and the child (CSS `padding`).
  final EdgeInsetsGeometry padding;

  /// Whether to paint the callout's arrow on the left edge (DS components/surfaces/surfaces.css:17); see
  /// `ZsMenuMaterial.arrow`.
  final bool arrow;

  /// The surface's content.
  final Widget child;

  @override
  State<ZsSurface> createState() => _ZsSurfaceState();
}

class _ZsSurfaceState extends State<ZsSurface> {
  /// Moves the box, and the content's state with it, when the filter comes or goes (Claude's proposal).
  final GlobalKey _box = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final Color text = ZsColors.of(context).text;
    final double fade = ZsFade.of(context);
    Widget surface = _SurfaceBox(
      key: _box,
      fill: widget.fill,
      sheen: widget.sheen,
      border: widget.border,
      shadow: widget.shadow,
      radius: widget.radius,
      clip: widget.clip,
      padding: widget.padding,
      arrow: widget.arrow,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: text),
        child: IconTheme.merge(
          data: IconThemeData(color: text),
          child: widget.child,
        ),
      ),
    );
    if (fade < 1) {
      surface = Opacity(opacity: fade, child: surface);
    }
    final ZsGlassFilter? filter = widget.filter;
    if (filter != null && fade > 0) {
      // CSS opacity a over the whole surface: the backdrop's share of what the faded box lets through.
      final double fill = widget.fill.a;
      final double alpha = fade >= 1 ? 1 : fade * (1 - fill) / (1 - fade * fill);
      surface = ClipRRect(
        clipper: _SurfaceClip(widget.radius),
        child: BackdropFilter.grouped(
          filter: filter.toImageFilter(alpha: alpha),
          child: surface,
        ),
      );
    }
    return Semantics(
      container: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        hitTestBehavior: HitTestBehavior.deferToChild,
        child: _SurfaceShadow(
          shadow: widget.shadow,
          radius: widget.radius,
          arrow: widget.arrow,
          fade: fade,
          child: surface,
        ),
      ),
    );
  }
}

/// The outer shape of a [size] box at [radius], each corner clamped to half the shorter side.
RRect _outer(Size size, double radius) =>
    RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(math.min(radius, size.shortestSide / 2)));

/// Half the side of the callout arrow's 10 × 10 square (DS components/surfaces/surfaces.css:17).
const double _arrowHalf = 5;

/// The callout arrow (DS components/surfaces/surfaces.css:17; base.css:2): a 10 × 10 square at `left:-6px;
/// top:16px` of the padding box — x −5…5, y 17…27 of the border box — turned 45° clockwise about its centre (0, 22),
/// so its tip points left at (−7.07, 22).
final Path _arrowSquare = _turnedArrow(const <Offset>[
  Offset(-_arrowHalf, -_arrowHalf),
  Offset(_arrowHalf, -_arrowHalf),
  Offset(_arrowHalf, _arrowHalf),
  Offset(-_arrowHalf, _arrowHalf),
]);

/// The arrow's 1 px left and bottom borders, inside its square (border-box sizing): after the turn, the two edges
/// that meet at the tip. One path, so the corner they share is painted once.
final Path _arrowEdges = _turnedArrow(const <Offset>[
  Offset(-_arrowHalf, -_arrowHalf),
  Offset(-_arrowHalf + ZsSurface.borderWidth, -_arrowHalf),
  Offset(-_arrowHalf + ZsSurface.borderWidth, _arrowHalf - ZsSurface.borderWidth),
  Offset(_arrowHalf, _arrowHalf - ZsSurface.borderWidth),
  Offset(_arrowHalf, _arrowHalf),
  Offset(-_arrowHalf, _arrowHalf),
]);

/// [points], given about the square's centre, turned 45° clockwise and moved to the centre (0, 22).
Path _turnedArrow(List<Offset> points) {
  const centre = Offset(0, 22);
  final double c = math.cos(math.pi / 4);
  final double s = math.sin(math.pi / 4);
  return Path()..addPolygon(<Offset>[
    for (final Offset p in points) centre + Offset(p.dx * c - p.dy * s, p.dx * s + p.dy * c),
  ], true);
}

class _SurfaceClip extends CustomClipper<RRect> {
  const _SurfaceClip(this.radius);

  final double radius;

  @override
  RRect getClip(Size size) => _outer(size, radius);

  @override
  bool shouldReclip(_SurfaceClip oldClipper) => oldClipper.radius != radius;
}

/// Paints its child, then the outer shadow parts clipped to outside the surface's shape, at [fade] times their alpha.
class _SurfaceShadow extends SingleChildRenderObjectWidget {
  const _SurfaceShadow({
    required this.shadow,
    required this.radius,
    required this.arrow,
    required this.fade,
    required super.child,
  });

  final ZsShadowStack shadow;
  final double radius;
  final bool arrow;
  final double fade;

  @override
  _RenderSurfaceShadow createRenderObject(BuildContext context) =>
      _RenderSurfaceShadow(shadow: shadow, radius: radius, arrow: arrow, fade: fade);

  @override
  void updateRenderObject(BuildContext context, _RenderSurfaceShadow renderObject) {
    renderObject
      ..shadow = shadow
      ..radius = radius
      ..arrow = arrow
      ..fade = fade;
  }
}

class _RenderSurfaceShadow extends RenderProxyBox {
  _RenderSurfaceShadow({required this._shadow, required this._radius, required this._arrow, required this._fade});

  ZsShadowStack get shadow => _shadow;
  ZsShadowStack _shadow;
  set shadow(ZsShadowStack value) {
    if (value != _shadow) {
      _shadow = value;
      markNeedsPaint();
    }
  }

  double get radius => _radius;
  double _radius;
  set radius(double value) {
    if (value != _radius) {
      _radius = value;
      markNeedsPaint();
    }
  }

  bool get arrow => _arrow;
  bool _arrow;
  set arrow(bool value) {
    if (value != _arrow) {
      _arrow = value;
      markNeedsPaint();
    }
  }

  double get fade => _fade;
  double _fade;
  set fade(double value) {
    if (value != _fade) {
      _fade = value;
      markNeedsPaint();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final List<BoxShadow> drops = _shadow.boxShadows;
    if (drops.isEmpty || _fade <= 0) {
      return;
    }
    final RRect outer = _outer(size, _radius);
    var reach = 0.0;
    for (final ZsShadow part in _shadow.parts) {
      if (!part.inset) {
        // A blur reaches 3σ = 1.5 · blur past its shape.
        reach = math.max(reach, part.dx.abs() + part.dy.abs() + part.spread.abs() + part.blur * 1.5);
      }
    }
    final Rect around = outer.outerRect.inflate(reach + 1);
    // The arrow overlaps the box, so only its outline needs path operations.
    final Path outside = _arrow
        ? Path.combine(
            PathOperation.difference,
            Path()..addRect(around),
            Path.combine(PathOperation.union, Path()..addRRect(outer), _arrowSquare),
          )
        : (Path()
            ..fillType = PathFillType.evenOdd
            ..addRect(around)
            ..addRRect(outer));
    final Canvas canvas = context.canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..clipPath(outside);
    for (final drop in drops) {
      final Paint paint = drop.toPaint();
      if (_fade < 1) {
        paint.color = paint.color.withValues(alpha: paint.color.a * _fade);
      }
      canvas.drawRRect(outer.shift(drop.offset).inflate(drop.spreadRadius), paint);
    }
    canvas.restore();
  }
}

/// The surface's box: fill, sheen, inset parts, border, arrow and the padded child.
class _SurfaceBox extends SingleChildRenderObjectWidget {
  const _SurfaceBox({
    required this.fill,
    required this.sheen,
    required this.border,
    required this.shadow,
    required this.radius,
    required this.clip,
    required this.padding,
    required this.arrow,
    required super.child,
    super.key,
  });

  final Color fill;
  final ZsLinearGradient? sheen;
  final Color? border;
  final ZsShadowStack shadow;
  final double radius;
  final bool clip;
  final EdgeInsetsGeometry padding;
  final bool arrow;

  EdgeInsetsGeometry get _inset => EdgeInsets.all(border == null ? 0 : ZsSurface.borderWidth).add(padding);

  @override
  _RenderSurfaceBox createRenderObject(BuildContext context) => _RenderSurfaceBox(
    padding: _inset,
    textDirection: Directionality.maybeOf(context),
    fill: fill,
    sheen: sheen,
    border: border,
    shadow: shadow,
    radius: radius,
    clip: clip,
    arrow: arrow,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderSurfaceBox renderObject) {
    renderObject
      ..padding = _inset
      ..textDirection = Directionality.maybeOf(context)
      ..fill = fill
      ..sheen = sheen
      ..border = border
      ..shadow = shadow
      ..radius = radius
      ..clip = clip
      ..arrow = arrow;
  }
}

class _RenderSurfaceBox extends RenderPadding {
  _RenderSurfaceBox({
    required super.padding,
    required super.textDirection,
    required this._fill,
    required this._sheen,
    required this._border,
    required this._shadow,
    required this._radius,
    required this._clip,
    required this._arrow,
  });

  final _clipLayer = LayerHandle<ClipRRectLayer>();

  Color get fill => _fill;
  Color _fill;
  set fill(Color value) {
    if (value != _fill) {
      _fill = value;
      markNeedsPaint();
    }
  }

  ZsLinearGradient? get sheen => _sheen;
  ZsLinearGradient? _sheen;
  set sheen(ZsLinearGradient? value) {
    if (value != _sheen) {
      _sheen = value;
      markNeedsPaint();
    }
  }

  Color? get border => _border;
  Color? _border;
  set border(Color? value) {
    if (value != _border) {
      _border = value;
      markNeedsPaint();
    }
  }

  ZsShadowStack get shadow => _shadow;
  ZsShadowStack _shadow;
  set shadow(ZsShadowStack value) {
    if (value != _shadow) {
      _shadow = value;
      markNeedsPaint();
    }
  }

  double get radius => _radius;
  double _radius;
  set radius(double value) {
    if (value != _radius) {
      _radius = value;
      markNeedsPaint();
    }
  }

  bool get clip => _clip;
  bool _clip;
  set clip(bool value) {
    if (value != _clip) {
      _clip = value;
      markNeedsPaint();
    }
  }

  bool get arrow => _arrow;
  bool _arrow;
  set arrow(bool value) {
    if (value != _arrow) {
      _arrow = value;
      markNeedsPaint();
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!_outer(size, _radius).contains(position)) {
      return false;
    }
    hitTestChildren(result, position: position);
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RRect outer = _outer(size, _radius);
    final Color? border = _border;
    final RRect inner = outer.deflate(border == null ? 0 : ZsSurface.borderWidth);
    final Canvas canvas = context.canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..drawRRect(outer, Paint()..color = _fill);
    final ZsLinearGradient? sheen = _sheen;
    if (sheen != null) {
      canvas
        ..save()
        ..clipRect(Rect.fromLTRB(outer.left, inner.top, outer.right, outer.bottom))
        ..drawRRect(outer, Paint()..shader = sheen.createShader(inner.outerRect))
        ..restore();
    }
    for (final ZsShadow part in _shadow.inset) {
      final RRect hole = inner.shift(Offset(part.dx, part.dy)).deflate(part.spread);
      final double reach = part.dx.abs() + part.dy.abs() + part.spread.abs() + part.blur * 1.5 + 1;
      final paint = Paint()..color = part.color;
      if (part.blur > 0) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, part.blur / 2);
      }
      canvas
        ..save()
        ..clipRRect(inner)
        ..drawPath(
          Path()
            ..fillType = PathFillType.evenOdd
            ..addRect(inner.outerRect.inflate(reach))
            ..addRRect(hole),
          paint,
        )
        ..restore();
    }
    if (border != null) {
      canvas.drawDRRect(outer, inner, Paint()..color = border);
    }
    if (_arrow) {
      canvas.drawPath(_arrowSquare, Paint()..color = _fill);
      if (border != null) {
        canvas.drawPath(_arrowEdges, Paint()..color = border);
      }
    }
    canvas.restore();
    if (_clip) {
      _clipLayer.layer = context.pushClipRRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        inner,
        super.paint,
        oldLayer: _clipLayer.layer,
      );
    } else {
      _clipLayer.layer = null;
      super.paint(context, offset);
    }
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    super.dispose();
  }
}
