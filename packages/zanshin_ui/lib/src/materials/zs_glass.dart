// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_elevation.dart';
import '../design/zs_metrics.dart';
import 'zs_surface.dart';

/// The glass fills (DS tokens/colors.css:36; paper :88).
enum ZsGlassFill {
  /// `--fl-bg`: the islands (DS components/base.css:7).
  regular,

  /// `--fl-bg-strong`: the panel island, the minimap and the toast (DS components/surfaces/surfaces.css:4;
  /// ui_kits/desktop/kit.css:147; components/overlays/overlays.css:4).
  strong,
}

/// The glass blurs (DS tokens/effects.css:36-37).
enum ZsGlassBlur {
  /// `--glass-blur`, σ 18 with saturate 1.4: the islands and the toast (DS components/overlays/overlays.css:4).
  regular,

  /// `--glass-blur-strong`, σ 22 with saturate 1.4: the panel island and the minimap (DS
  /// components/surfaces/surfaces.css:4; ui_kits/desktop/kit.css:147).
  strong,
}

/// Floating glass: `--fl-sheen` over the [fill], a 1 px `--fl-border` and `--fl-shadow` (its inset top highlight
/// and two drops) over a grouped backdrop blur (DS components/base.css:7), painted by [ZsSurface].
///
/// Reduce transparency and increased contrast reach it only through the tokens: `--fl-bg` and `--fl-bg-strong`
/// resolve to `--fl-bg-solid`'s value and the blurs to none, so it paints solid without a `BackdropFilter` (DS
/// tokens/transparency.css:9-10; tokens/contrast.css:21-22). Its backdrop joins the nearest [BackdropGroup].
///
/// Glass never nests (DS components/surfaces/Island.prompt.md:13); a `ZsGlass` below another fails an assertion in
/// debug builds, as nested grouped backdrops would overlap. The check walks the element tree, where an
/// `OverlayPortal`'s overlay child counts as a child of the portal: glass must therefore never mount through an
/// `OverlayPortal` placed inside other glass. Story 11.3 settles it that way — none of the overlay host's surfaces
/// does (its preview is the menu material, its flyout a sibling of the rail). Never fade glass through an `Opacity`
/// or a `FadeTransition` above it: the engine then drops the blur for the whole fade; fade it through `ZsFade`.
///
/// Besides the islands ([ZsIsland]), two surfaces are plain glass (Claude's proposal for their build):
/// - the toast (10.23): `ZsGlass(fill: ZsGlassFill.strong, blur: ZsGlassBlur.regular, radius: radiusPill)` (DS
///   components/overlays/overlays.css:4);
/// - the minimap (10.16): `ZsGlass(fill: ZsGlassFill.strong, blur: ZsGlassBlur.strong, radius: radiusIsland)` (DS
///   ui_kits/desktop/kit.css:147).
class ZsGlass extends StatelessWidget {
  /// Paints [child] on glass at [radius].
  const ZsGlass({
    required this.radius,
    required this.child,
    this.fill = ZsGlassFill.regular,
    this.blur = ZsGlassBlur.regular,
    this.clip = false,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  /// The corner radius, a `ZsMetrics` radius token.
  final double radius;

  /// The fill.
  final ZsGlassFill fill;

  /// The backdrop blur.
  final ZsGlassBlur blur;

  /// Whether the child is clipped to the inside of the border (`overflow:hidden`).
  final bool clip;

  /// The space between the border and the child.
  final EdgeInsetsGeometry padding;

  /// The glass's content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    assert(
      context.findAncestorWidgetOfExactType<ZsGlass>() == null,
      'Glass never nests (DS components/surfaces/Island.prompt.md:13): nested grouped backdrops would overlap.',
    );
    final ZsColors colors = ZsColors.of(context);
    final ZsElevation elevation = ZsElevation.of(context);
    return ZsSurface(
      fill: switch (fill) {
        ZsGlassFill.regular => colors.flBg,
        ZsGlassFill.strong => colors.flBgStrong,
      },
      sheen: colors.flSheen,
      border: colors.flBorder,
      shadow: elevation.flShadow,
      radius: radius,
      filter: switch (blur) {
        ZsGlassBlur.regular => elevation.glassBlur,
        ZsGlassBlur.strong => elevation.glassBlurStrong,
      },
      clip: clip,
      padding: padding,
      child: child,
    );
  }
}

/// The island shapes (DS components/surfaces/Island.jsx:4; surfaces.css:2-5).
///
/// Each carries the DS's [gap] between an island's controls; an island takes one child and its consumer lays the
/// controls out with that gap (Claude's proposal).
enum ZsIslandShape {
  /// A top-bar island: 44 px high (`--chrome-h`), padding 0 4, radius `--radius-island` (DS
  /// components/surfaces/surfaces.css:2-3).
  bar(gap: 2),

  /// The rail: padding 5, radius `--radius-panel` (DS components/surfaces/surfaces.css:5).
  rail(gap: 4),

  /// The inspector and the pinned panels: strong glass, radius `--radius-panel`, clipped (DS
  /// components/surfaces/surfaces.css:4).
  panel(gap: 0),

  /// No preset geometry: radius `--radius-island` (DS components/surfaces/Island.jsx:4; surfaces.css:2).
  free(gap: 2);

  const ZsIslandShape({required this.gap});

  /// The gap between the island's controls (DS components/surfaces/surfaces.css:2, :4, :5).
  final double gap;
}

/// The floating glass container: everything over the graph sits on one (DS components/surfaces/Island.jsx:3).
///
/// Islands sit 12 px from the window edge and from each other and never nest (DS
/// components/surfaces/Island.prompt.md:13); 11.3 places them.
class ZsIsland extends StatelessWidget {
  /// An island of [shape] around [child].
  const ZsIsland({required this.child, this.shape = ZsIslandShape.bar, super.key});

  /// The island's shape.
  final ZsIslandShape shape;

  /// The island's content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    return switch (shape) {
      ZsIslandShape.bar => SizedBox(
        height: metrics.chromeH,
        child: ZsGlass(
          radius: metrics.radiusIsland,
          // `padding:0 4px` (DS components/surfaces/surfaces.css:3).
          padding: const EdgeInsets.symmetric(horizontal: 4),
          // `align-items:center` (DS components/surfaces/surfaces.css:2).
          child: Align(alignment: AlignmentDirectional.centerStart, widthFactor: 1, child: child),
        ),
      ),
      // `padding:5px` (DS components/surfaces/surfaces.css:5).
      ZsIslandShape.rail => ZsGlass(radius: metrics.radiusPanel, padding: const EdgeInsets.all(5), child: child),
      ZsIslandShape.panel => ZsGlass(
        fill: ZsGlassFill.strong,
        blur: ZsGlassBlur.strong,
        radius: metrics.radiusPanel,
        clip: true,
        child: child,
      ),
      ZsIslandShape.free => ZsGlass(radius: metrics.radiusIsland, child: child),
    };
  }
}

/// The separator between groups of an island's controls: a 1 × 20 line in `--fl-border` with 4 px margins on
/// either side, 9 × 20 in all (DS components/surfaces/surfaces.css:6). It has no semantics (`aria-hidden`, DS
/// components/surfaces/Island.jsx:15).
class ZsIslandSeparator extends StatelessWidget {
  /// Creates a separator.
  const ZsIslandSeparator({super.key});

  @override
  Widget build(BuildContext context) => _Separator(color: ZsColors.of(context).flBorder);
}

class _Separator extends LeafRenderObjectWidget {
  const _Separator({required this.color});

  final Color color;

  @override
  _RenderSeparator createRenderObject(BuildContext context) => _RenderSeparator(color: color);

  @override
  void updateRenderObject(BuildContext context, _RenderSeparator renderObject) {
    renderObject.color = color;
  }
}

class _RenderSeparator extends RenderBox {
  _RenderSeparator({required this._color});

  /// `width:1px;height:20px` (DS components/surfaces/surfaces.css:6).
  static const _line = Size(1, 20);

  /// `margin:0 4px` (DS components/surfaces/surfaces.css:6).
  static const double _margin = 4;

  Color get color => _color;
  Color _color;
  set color(Color value) {
    if (value != _color) {
      _color = value;
      markNeedsPaint();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(_line.width + 2 * _margin, _line.height));

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _line.width + 2 * _margin;

  @override
  double computeMaxIntrinsicWidth(double height) => _line.width + 2 * _margin;

  @override
  double computeMinIntrinsicHeight(double width) => _line.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _line.height;

  @override
  void paint(PaintingContext context, Offset offset) {
    final Offset centre = offset + size.center(Offset.zero);
    context.canvas.drawRect(
      Rect.fromCenter(center: centre, width: _line.width, height: _line.height),
      Paint()..color = _color,
    );
  }
}
