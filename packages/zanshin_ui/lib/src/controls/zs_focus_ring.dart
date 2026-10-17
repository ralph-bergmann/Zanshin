// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';

/// Where a control draws the one focus ring (DS components/base.css:24-28).
enum ZsRingPlacement {
  /// `--focus-offset` outside the control: buttons, switches, checkboxes, chips, links, the select trigger.
  outside,

  /// `--focus-offset-inset` inside the control: rows in lists and menus, flush segments, the rail icon button, scroll
  /// viewports and anything in a clipping well (DS components/base.css:26).
  inside,

  /// `--focus-offset-card` outside, clear of a graph card's selection halo (DS components/base.css:28).
  card,
}

/// The one focus ring (DS components/base.css:19-31; readme.md:135): a `--focus-w` stroke in `--focus-ring` at the
/// [placement]'s offset around the control's rounded rect, its radius grown or shrunk by the offset (never below 0).
///
/// It fades in on `--dur-focus` / `--ease-state` from transparent while it settles from the offset +
/// `--focus-settle` × `--motion` to rest (the DS keyframes `zs-focus-in*`), and leaves at once, as a CSS outline does.
/// Under increased contrast the stroke is 3 px; an inside ring then lies at inset −3, so the whole stroke stays
/// within the control's bounds and no clipping container cuts it (Claude's proposal, Story 11.11). In an inactive
/// window `--focus-ring` is transparent and nothing is painted.
///
/// The control decides [visible] — keyboard focus only (`ZsControlCore` reports it).
class ZsFocusRing extends StatefulWidget {
  /// Rings [child] while [visible].
  const ZsFocusRing({
    required this.visible,
    required this.child,
    this.placement = ZsRingPlacement.outside,
    this.radius = 0,
    super.key,
  });

  /// Whether the control has keyboard focus.
  final bool visible;

  /// Outside, inside or card.
  final ZsRingPlacement placement;

  /// The control's own corner radius, before the ring's offset is added; clamped to half the shorter side.
  final double radius;

  /// The control.
  final Widget child;

  /// The stroke's offset from the control's edge for [placement] and the stroke width [width]: the inside offset
  /// moves inward to −[width] when the stroke is wider than `--focus-offset-inset` is deep.
  static double offsetFor(ZsRingPlacement placement, ZsMetrics metrics, double width) => switch (placement) {
    ZsRingPlacement.outside => metrics.focusOffset,
    ZsRingPlacement.inside => -math.max(-metrics.focusOffsetInset, width),
    ZsRingPlacement.card => metrics.focusOffsetCard,
  };

  @override
  State<ZsFocusRing> createState() => _ZsFocusRingState();
}

class _ZsFocusRingState extends State<ZsFocusRing> with SingleTickerProviderStateMixin {
  late final _entrance = AnimationController(vsync: this, value: widget.visible ? 1 : 0);

  /// `--ease-state` is the same curve with and without reduce motion.
  late final _progress = CurvedAnimation(parent: _entrance, curve: ZsMotion.full.easeState);

  @override
  void didUpdateWidget(ZsFocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) {
      return;
    }
    if (widget.visible) {
      _entrance
        ..duration = ZsMotion.of(context).durFocus
        ..forward(from: 0);
    } else {
      _entrance.value = 0;
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final double width = metrics.focusW;
    return CustomPaint(
      foregroundPainter: _FocusRingPainter(
        progress: _progress,
        visible: widget.visible,
        color: ZsColors.of(context).focusRing,
        width: width,
        offset: ZsFocusRing.offsetFor(widget.placement, metrics, width),
        settle: metrics.focusSettle * motion.motion,
        radius: widget.radius,
      ),
      child: widget.child,
    );
  }
}

class _FocusRingPainter extends CustomPainter {
  _FocusRingPainter({
    required this.progress,
    required this.visible,
    required this.color,
    required this.width,
    required this.offset,
    required this.settle,
    required this.radius,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final bool visible;
  final Color color;
  final double width;
  final double offset;
  final double settle;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = progress.value;
    if (!visible || t == 0 || color.a == 0) {
      return;
    }
    final box = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(math.min(radius, size.shortestSide / 2)),
    );
    final double at = offset + settle * (1 - t);
    canvas.drawDRRect(
      box.inflate(at + width),
      box.inflate(at),
      Paint()..color = color.withValues(alpha: color.a * t),
    );
  }

  @override
  bool shouldRepaint(_FocusRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.visible != visible ||
      oldDelegate.color != color ||
      oldDelegate.width != width ||
      oldDelegate.offset != offset ||
      oldDelegate.settle != settle ||
      oldDelegate.radius != radius;
}
