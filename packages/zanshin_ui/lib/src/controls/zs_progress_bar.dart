// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import '../design/zs_appearance.dart';
import '../design/zs_colors.dart';
import '../design/zs_motion.dart';
import '../zs_strings.dart';
import 'zs_control.dart';
import 'zs_lerp_builder.dart';

/// A 4 px progress bar for operations that measure themselves (DS components/controls/ProgressBar.{d.ts,jsx,
/// prompt.md}; controls.css:52-59). Where the DS disagrees with itself the CSS wins (story 11.11; V2 §4): the fill is
/// `--accent-live-line` — the live copy, so it keeps its colour in an inactive window — on `--progress-track`, and a
/// new value moves on `--dur-expand` / `--ease-glide` (it jumps under reduce motion).
///
/// Without a [value] it is indeterminate: a 32 % segment sweeps from −100 % to 320 % of its width every
/// `--dur-shimmer`, linear; under reduce motion the fill spans the groove and pulses (opacity 1 → .45 → 1). Under
/// increased contrast the groove has a 1 px `--border-strong` edge (DS tokens/contrast.css:23). Not focusable.
/// VoiceOver: a progress indicator named [label] with the value in percent, or "in progress".
class ZsProgressBar extends StatefulWidget implements ZsControl {
  /// A bar at [value] of [max], or indeterminate without a value.
  const ZsProgressBar({this.value, this.max = 1, this.label, this.width = 200, this.identifier, super.key})
    : assert(max > 0, 'The maximum must be positive.');

  /// The progress, between 0 and [max]; null is indeterminate.
  final double? value;

  /// The value of a full bar.
  final double max;

  /// The accessible name ("Fetching").
  final String? label;

  /// The bar's width.
  final double width;

  @override
  final String? identifier;

  /// The groove's height (DS components/controls/controls.css:56).
  static const double _height = 4;

  /// The sweep's share of the groove, and its travel in fill widths (DS components/controls/controls.css:58-59).
  static const _sweep = .32;
  static const double _from = -1;
  static const _to = 3.2;

  /// The lowest opacity of the reduce-motion pulse (DS components/controls/controls.css:59).
  static const _pulse = .45;

  @override
  State<ZsProgressBar> createState() => _ZsProgressBarState();
}

class _ZsProgressBarState extends State<ZsProgressBar> with SingleTickerProviderStateMixin {
  late final _sweep = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _run();
  }

  @override
  void didUpdateWidget(ZsProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _run();
  }

  void _run() {
    if (widget.value == null) {
      final Duration period = ZsMotion.of(context).durShimmer;
      if (!_sweep.isAnimating || _sweep.duration != period) {
        _sweep
          ..duration = period
          ..repeat();
      }
    } else if (_sweep.isAnimating) {
      _sweep.stop();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final Color? edge = ZsAppearance.of(context).increasedContrast ? colors.borderStrong : null;
    final double? value = widget.value;
    final Widget bar;
    final String semanticsValue;
    if (value == null) {
      semanticsValue = zsStrings(context).progressIndeterminate;
      bar = CustomPaint(
        size: Size(widget.width, ZsProgressBar._height),
        painter: _ProgressPainter(
          track: colors.progressTrack,
          fill: colors.accentLiveLine,
          edge: edge,
          sweep: _sweep,
          motion: motion.motion,
        ),
      );
    } else {
      final double fraction = (value / widget.max).clamp(0, 1);
      semanticsValue = '${(fraction * 100).round()}%';
      bar = ZsLerpBuilder<double>(
        value: fraction,
        lerp: (a, b, t) => a + (b - a) * t,
        duration: motion.durExpand,
        curve: motion.easeGlide,
        builder: (context, shown, _) => CustomPaint(
          size: Size(widget.width, ZsProgressBar._height),
          painter: _ProgressPainter(
            track: colors.progressTrack,
            fill: colors.accentLiveLine,
            edge: edge,
            fraction: shown,
          ),
        ),
      );
    }
    return Semantics(
      container: true,
      identifier: widget.identifier,
      label: widget.label,
      value: semanticsValue,
      child: bar,
    );
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter({
    required this.track,
    required this.fill,
    required this.edge,
    this.fraction = 0,
    this.sweep,
    this.motion = 1,
  }) : super(repaint: sweep);

  final Color track;
  final Color fill;
  final Color? edge;
  final double fraction;
  final Animation<double>? sweep;
  final double motion;

  @override
  void paint(Canvas canvas, Size size) {
    final groove = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.height / 2));
    canvas
      ..save()
      ..clipRRect(groove)
      ..drawRRect(groove, Paint()..color = track);
    final Animation<double>? running = sweep;
    if (running == null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width * fraction, size.height),
          Radius.circular(size.height / 2),
        ),
        Paint()..color = fill,
      );
    } else {
      final double t = running.value;
      // `width:calc(100% - 68% * var(--motion))`, moved `translateX(-100% … 320% × --motion)`, its opacity dipping to
      // `1 − .55 × (1 − --motion)` halfway (DS components/controls/controls.css:58-59).
      final double width = size.width * (1 - (1 - ZsProgressBar._sweep) * motion);
      final double shift = width * (ZsProgressBar._from + (ZsProgressBar._to - ZsProgressBar._from) * t) * motion;
      final double dip = (1 - ZsProgressBar._pulse) * (1 - motion);
      final double opacity = 1 - dip * (1 - (2 * t - 1).abs());
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(shift, 0, width, size.height), Radius.circular(size.height / 2)),
        Paint()..color = fill.withValues(alpha: fill.a * opacity),
      );
    }
    final Color? line = edge;
    if (line != null) {
      canvas.drawDRRect(groove, groove.deflate(1), Paint()..color = line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ProgressPainter oldDelegate) =>
      oldDelegate.track != track ||
      oldDelegate.fill != fill ||
      oldDelegate.edge != edge ||
      oldDelegate.fraction != fraction ||
      oldDelegate.sweep != sweep ||
      oldDelegate.motion != motion;
}
