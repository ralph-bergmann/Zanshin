// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_values.dart';

/// The window canvas `--canvas` (DS tokens/colors.css:25, paper :82; readme.md:76, :88): the two static shaders under
/// the graph — the linear base over the whole box, then the flat radial lift — painted opaque edge to edge.
///
/// No dot grid, no blur, no noise (DS readme.md:88). It fills the box its parent gives it (a bounded side; an
/// unbounded one takes its minimum — Claude's proposal), is a hit-test target of its own, so a press on empty canvas
/// reaches it, and follows a theme switch: the token theme lerps `--canvas`, and every new gradient repaints it.
class ZsCanvas extends LeafRenderObjectWidget {
  /// Paints the canvas of the nearest theme.
  const ZsCanvas({super.key});

  @override
  RenderZsCanvas createRenderObject(BuildContext context) => RenderZsCanvas(ZsColors.of(context).canvas);

  @override
  void updateRenderObject(BuildContext context, RenderZsCanvas renderObject) =>
      renderObject.gradient = ZsColors.of(context).canvas;
}

/// The render object of [ZsCanvas].
class RenderZsCanvas extends RenderBox {
  /// Paints [gradient].
  RenderZsCanvas(this._gradient);

  /// The canvas painted; a new value repaints.
  ZsCanvasGradient get gradient => _gradient;
  ZsCanvasGradient _gradient;
  set gradient(ZsCanvasGradient value) {
    if (value == _gradient) {
      return;
    }
    _gradient = value;
    markNeedsPaint();
  }

  // WHY: the canvas lies under the graph and every island, which repaint far more often than the theme changes; a
  // layer of its own keeps their repaints from re-running its two shaders.
  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => Size(
    constraints.hasBoundedWidth ? constraints.maxWidth : constraints.minWidth,
    constraints.hasBoundedHeight ? constraints.maxHeight : constraints.minHeight,
  );

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      return;
    }
    final Rect box = offset & size;
    context.canvas
      ..drawRect(box, Paint()..shader = _gradient.linear.createShader(box))
      ..drawRect(box, Paint()..shader = _gradient.radial.createShader(box));
  }
}
