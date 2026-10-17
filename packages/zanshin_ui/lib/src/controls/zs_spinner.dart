// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import 'zs_control.dart';

/// The inline busy mark (DS components/controls/Spinner.{d.ts,jsx,prompt.md}; controls.css:6-7): a quarter arc on a
/// faint ring, drawn on the icon grid of 16 — the ring r 6 with a 2 px stroke at .22, the arc from 12 to 3 o'clock
/// with round caps — in the current colour ([color], else the nearest `IconTheme`'s, else `--text`).
///
/// One turn per `--dur-spin`, linear, forever; it keeps turning under reduce motion — it is information, not
/// motion between states (DS components/base.css:64; decision 16.4). It is not focusable; with a [label] it is a
/// progress indicator reading "busy", without one it is hidden (a busy button carries the state itself).
class ZsSpinner extends StatefulWidget implements ZsControl {
  /// A spinner [size] wide.
  const ZsSpinner({this.size = ZsIconSize.md, this.label, this.color, this.identifier, super.key});

  /// sm 12, md 14 (the default), lg 16 — the icon sizes (DS Spinner.d.ts).
  final ZsIconSize size;

  /// The name VoiceOver reads when the spinner stands alone ("Fetching").
  final String? label;

  /// The colour; null takes the nearest `IconTheme`'s, else `--text`.
  final Color? color;

  @override
  final String? identifier;

  @override
  State<ZsSpinner> createState() => _ZsSpinnerState();
}

class _ZsSpinnerState extends State<ZsSpinner> with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Duration period = ZsMotion.of(context).durSpin;
    if (_turn.duration != period) {
      _turn
        ..duration = period
        ..repeat();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color =
        widget.color ??
        context.dependOnInheritedWidgetOfExactType<IconTheme>()?.data.color ??
        ZsColors.of(context).text;
    final Widget mark = CustomPaint(
      size: Size.square(widget.size.size),
      painter: _SpinnerPainter(turn: _turn, color: color),
    );
    final String? label = widget.label;
    if (label == null) {
      return ExcludeSemantics(
        child: widget.identifier == null ? mark : Semantics(identifier: widget.identifier, child: mark),
      );
    }
    return Semantics(container: true, identifier: widget.identifier, label: label, value: 'busy', child: mark);
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({required this.turn, required this.color}) : super(repaint: turn);

  final Animation<double> turn;
  final Color color;

  /// The DS draws the spinner on a 16-unit grid: ring r 6, stroke 2, ring opacity .22 (DS Spinner.jsx:9-10).
  static const double _grid = 16;
  static const double _r = 6;
  static const double _stroke = 2;
  static const _ringAlpha = .22;

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.shortestSide / _grid;
    canvas
      ..save()
      ..scale(scale)
      ..translate(_grid / 2, _grid / 2)
      ..rotate(turn.value * 2 * math.pi);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..color = color.withValues(alpha: color.a * _ringAlpha);
    canvas.drawCircle(Offset.zero, _r, ring);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas
      ..drawArc(Rect.fromCircle(center: Offset.zero, radius: _r), -math.pi / 2, math.pi / 2, false, arc)
      ..restore();
  }

  @override
  bool shouldRepaint(_SpinnerPainter oldDelegate) => oldDelegate.turn != turn || oldDelegate.color != color;
}
