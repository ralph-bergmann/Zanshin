// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import 'zs_control.dart';

/// A skeleton's shape (DS components/controls/Skeleton.d.ts).
enum ZsSkeletonKind {
  /// A bar.
  bar,

  /// A 240 × 62 change card on the real card's material.
  card,

  /// A 30 px file or project row.
  row,
}

/// A pending placeholder whose shape is known while jj answers (DS components/controls/Skeleton.{d.ts,jsx,prompt.md};
/// controls.css:61-67): `--skeleton` bars with a `--skeleton-hi` sweep every `--dur-shimmer`, linear; the card on
/// `--card-solid` with a 1 px `--border-strong`, radius `--radius-card`.
///
/// It paints nothing until `--delay-skeleton` has passed, so a load that ends sooner never flashes it. Under reduce
/// motion the highlight stays off the bars and they pulse instead (opacity 1 → .55 → 1; DS
/// components/controls/controls.css:66-67). Hidden from VoiceOver; the region it stands in is the busy one.
class ZsSkeleton extends StatefulWidget implements ZsControl {
  /// A placeholder of [kind].
  const ZsSkeleton({
    this.kind = ZsSkeletonKind.bar,
    this.width,
    this.height = 10,
    this.radius,
    this.identifier,
    super.key,
  });

  /// Bar, card or row.
  final ZsSkeletonKind kind;

  /// A bar's width (null: as wide as it may be); a row's longest middle bar.
  final double? width;

  /// A bar's height.
  final double height;

  /// A bar's radius; `--radius-xs` when null.
  final double? radius;

  @override
  final String? identifier;

  /// The card's geometry (DS components/controls/controls.css:63; Skeleton.jsx:5-10).
  static const _card = Size(240, 62);

  /// The lowest opacity of the reduce-motion pulse (DS components/controls/controls.css:67).
  static const _pulse = .55;

  @override
  State<ZsSkeleton> createState() => _ZsSkeletonState();
}

class _ZsSkeletonState extends State<ZsSkeleton> with SingleTickerProviderStateMixin {
  late final _sweep = AnimationController(vsync: this);
  Timer? _wait;
  var _shown = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ZsMotion motion = ZsMotion.of(context);
    _sweep.duration = motion.durShimmer;
    if (!_shown && _wait == null) {
      _wait = Timer(motion.delaySkeleton, () {
        if (mounted) {
          setState(() => _shown = true);
          _sweep.repeat();
        }
      });
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _sweep.dispose();
    super.dispose();
  }

  Widget _bar({required double height, double? width, double? radius}) => CustomPaint(
    size: Size(width ?? 0, height),
    painter: _SkeletonPainter(
      sweep: _sweep,
      base: ZsColors.of(context).skeleton,
      high: ZsColors.of(context).skeletonHi,
      radius: radius ?? ZsMetrics.of(context).radiusXs,
      motion: ZsMotion.of(context).motion,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_shown) {
      return const SizedBox.shrink();
    }
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final Widget shape = switch (widget.kind) {
      ZsSkeletonKind.bar => SizedBox(
        width: widget.width ?? double.infinity,
        height: widget.height,
        child: _bar(width: widget.width, height: widget.height, radius: widget.radius),
      ),
      ZsSkeletonKind.card => DecoratedBox(
        decoration: BoxDecoration(
          color: colors.cardSolid,
          border: Border.all(color: colors.borderStrong),
          borderRadius: BorderRadius.circular(metrics.radiusCard),
        ),
        child: SizedBox.fromSize(
          size: ZsSkeleton._card,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: LayoutBuilder(
              builder: (context, box) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 9,
                children: <Widget>[
                  Row(
                    spacing: 8,
                    children: <Widget>[
                      _bar(width: 38, height: 9),
                      _bar(width: box.maxWidth * .58, height: 9),
                    ],
                  ),
                  _bar(width: box.maxWidth * .36, height: 7),
                ],
              ),
            ),
          ),
        ),
      ),
      ZsSkeletonKind.row => SizedBox(
        height: 30,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            spacing: 8,
            children: <Widget>[
              _bar(width: 14, height: 14, radius: 3),
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: widget.width ?? double.infinity),
                  child: SizedBox(width: double.infinity, height: 8, child: _bar(height: 8)),
                ),
              ),
              _bar(width: 34, height: 8),
            ],
          ),
        ),
      ),
    };
    return ExcludeSemantics(
      child: widget.identifier == null ? shape : Semantics(identifier: widget.identifier, child: shape),
    );
  }
}

/// The sweep's band at [t] of one sweep over a bar of [size]: twice the bar's width (`background-size:200%`), its
/// centre running from one bar width left of the bar to one bar width right of it, so the band enters and leaves
/// the bar whole; under reduce motion ([motion] 0) it stays off the bar.
///
/// The DS's `background-position:150%` → `-50%` (components/controls/controls.css:62, :67) runs the centre only from
/// −50 % to 150 % of the bar, so half the band still lies on the bar at both ends and every loop jumps from the right
/// edge to the left one (Ralph, 2026-10-18, in the catalogue).
@visibleForTesting
Rect zsSkeletonBand(Size size, double t, double motion) {
  final double band = size.width * 2;
  final double centre = size.width * (-1 + 3 * t * motion);
  return Rect.fromLTWH(centre - band / 2, 0, band, size.height);
}

/// Paints one skeleton bar into [rect] at [t] of a sweep: `--skeleton` ([base]) with radius [radius] and the
/// [high] (`--skeleton-hi`) band of [zsSkeletonBand]; under reduce motion ([motion] 0) no band, the bar pulses. The
/// one skeleton look, shared by [ZsSkeleton] and painters that draw a bar in a text slot (the graph card, Story 10.11).
void paintZsSkeletonBar(
  Canvas canvas,
  Rect rect, {
  required double t,
  required Color base,
  required Color high,
  required double radius,
  required double motion,
}) {
  // The pulse: opacity `1 − .45 × (1 − --motion)` halfway (DS components/controls/controls.css:67).
  final double opacity = 1 - (1 - ZsSkeleton._pulse) * (1 - motion) * (1 - (2 * t - 1).abs());
  final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
  canvas
    ..save()
    ..clipRRect(rrect)
    ..drawRRect(rrect, Paint()..color = base.withValues(alpha: base.a * opacity));
  if (motion > 0) {
    final Shader shader = LinearGradient(
      colors: <Color>[high.withValues(alpha: 0), high, high.withValues(alpha: 0)],
    ).createShader(zsSkeletonBand(rect.size, t, motion).shift(rect.topLeft));
    canvas.drawRect(rect, Paint()..shader = shader);
  }
  canvas.restore();
}

class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter({
    required this.sweep,
    required this.base,
    required this.high,
    required this.radius,
    required this.motion,
  }) : super(repaint: sweep);

  final Animation<double> sweep;
  final Color base;
  final Color high;
  final double radius;
  final double motion;

  @override
  void paint(Canvas canvas, Size size) => paintZsSkeletonBar(
    canvas,
    Offset.zero & size,
    t: sweep.value,
    base: base,
    high: high,
    radius: radius,
    motion: motion,
  );

  @override
  bool shouldRepaint(_SkeletonPainter oldDelegate) =>
      oldDelegate.sweep != sweep ||
      oldDelegate.base != base ||
      oldDelegate.high != high ||
      oldDelegate.radius != radius ||
      oldDelegate.motion != motion;
}
