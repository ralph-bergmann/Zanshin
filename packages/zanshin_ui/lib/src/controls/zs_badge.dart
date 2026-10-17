// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import 'zs_control.dart';
import 'zs_control_text.dart';

/// A badge's tone (DS components/controls/Badge.d.ts).
enum ZsBadgeTone {
  /// Something to act on (incoming changes): `--accent` with `--accent-ink`.
  accent,

  /// A plain count: `--fl-on` with `--text-muted`.
  neutral,
}

/// A count badge on an icon button or at the end of a navigation row (DS components/controls/Badge.{d.ts,jsx,
/// prompt.md}; controls.css:9-17): a 15 px pill (`min-width` 15, padding 0 4), `--fs-2xs` 700 mono with tabular
/// figures. Accent: `--accent` with `--accent-ink`, an inset 1 px `--accent-line` edge that carries the 3:1 where the
/// fill is light (DS readme.md:269), cut out of its island by a 2 px `--fl-bg-solid` ring; neutral: `--fl-on` with
/// `--text-muted`, no ring. In an inactive window the accent tokens are neutral already, so the badge goes neutral
/// with the role (DS tokens/inactive.css:11).
///
/// [count] is a number, a text, or `true` for an 8 px dot; null, 0 and false hide it. Above [max] it shows "max+".
/// It scales in from .6 with a fade (`--dur-pop`, glide); a changed number rises 5 px into place (`--dur-pop`,
/// glide); hiding shrinks it out (`--dur-exit`, exit). Every scale and rise is × `--motion`, so under reduce motion
/// it only fades. It takes no pointer and is not focusable; its count belongs in its button's label, so it is
/// hidden from VoiceOver.
class ZsBadge extends StatefulWidget implements ZsControl {
  /// A badge showing [count].
  const ZsBadge({this.count, this.max = 99, this.tone = ZsBadgeTone.accent, this.identifier, super.key});

  /// A number, a text, or `true` for a dot; null, 0 and false hide the badge.
  final Object? count;

  /// Above this a number shows as "max+".
  final int max;

  /// Accent or neutral.
  final ZsBadgeTone tone;

  @override
  final String? identifier;

  /// The pill's height and smallest width (DS components/controls/controls.css:10).
  static const double _side = 15;

  /// The dot's side (DS components/controls/controls.css:12).
  static const double _dot = 8;

  /// The horizontal padding (DS components/controls/controls.css:10).
  static const double _padX = 4;

  /// The cut-out ring around an accent badge (DS components/controls/controls.css:10).
  static const double _cutOut = 2;

  /// How far a new number rises into place (DS components/controls/controls.css:16).
  static const double _roll = 5;

  /// The scale a badge enters from and leaves to: 1 − .4 (DS components/controls/controls.css:15, :17).
  static const _shrink = .4;

  @override
  State<ZsBadge> createState() => _ZsBadgeState();
}

class _ZsBadgeState extends State<ZsBadge> with TickerProviderStateMixin {
  late final _presence = AnimationController(vsync: this);
  late final _roll = AnimationController(vsync: this, value: 1);
  late final _in = CurvedAnimation(parent: _presence, curve: ZsMotion.full.easeGlide);
  late final _out = CurvedAnimation(parent: _presence, curve: ZsMotion.full.easeExit.flipped);
  late final _rollIn = CurvedAnimation(parent: _roll, curve: ZsMotion.full.easeGlide);

  /// The value shown, kept while the badge leaves.
  Object? _shown;
  var _leaving = false;
  var _started = false;

  static bool _visible(Object? count) => count != null && count != false && count != 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      if (_visible(widget.count)) {
        _shown = widget.count;
        _enter();
      }
    }
  }

  @override
  void didUpdateWidget(ZsBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool show = _visible(widget.count);
    final ZsMotion motion = ZsMotion.of(context);
    if (show) {
      final bool wasGone = _shown == null || _leaving;
      if (!wasGone && _text(widget.count) != _text(_shown)) {
        _roll
          ..duration = motion.durPop
          ..forward(from: 0);
      }
      _shown = widget.count;
      if (wasGone) {
        _enter();
      }
    } else if (_shown != null && !_leaving) {
      _leaving = true;
      _presence
        ..reverseDuration = motion.durExit
        ..reverse(from: 1).whenCompleteOrCancel(_gone);
    }
  }

  void _enter() {
    _leaving = false;
    _presence
      ..duration = ZsMotion.of(context).durPop
      ..forward(from: 0);
  }

  void _gone() {
    if (mounted && _leaving) {
      setState(() {
        _shown = null;
        _leaving = false;
      });
    }
  }

  String _text(Object? count) {
    if (count == true) {
      return '';
    }
    if (count is int && count > widget.max) {
      return '${widget.max}+';
    }
    return '$count';
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    _rollIn.dispose();
    _presence.dispose();
    _roll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Object? shown = _shown;
    if (shown == null) {
      return const SizedBox.shrink();
    }
    final ZsColors colors = ZsColors.of(context);
    final double m = ZsMotion.of(context).motion;
    final accent = widget.tone == ZsBadgeTone.accent;
    final dot = shown == true;
    final Color ink = accent ? colors.accentInk : colors.textMuted;
    final Animation<double> presence = _leaving ? _out : _in;
    Widget pill = CustomPaint(
      painter: _BadgePainter(
        fill: accent ? colors.accent : colors.flOn,
        edge: accent ? colors.accentLine : null,
        cutOut: accent ? colors.flBgSolid : null,
      ),
      child: dot
          ? const SizedBox.square(dimension: ZsBadge._dot)
          : ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: ZsBadge._side,
                minHeight: ZsBadge._side,
                maxHeight: ZsBadge._side,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: ZsBadge._padX),
                child: ClipRect(
                  child: Center(
                    widthFactor: 1,
                    child: AnimatedBuilder(
                      animation: _rollIn,
                      builder: (context, child) => Opacity(
                        opacity: _rollIn.value,
                        child: Transform.translate(
                          offset: Offset(0, ZsBadge._roll * m * (1 - _rollIn.value)),
                          child: child,
                        ),
                      ),
                      child: Text(
                        _text(shown),
                        style: zsMono(ZsType.fs2xs, weight: FontWeight.w700).copyWith(color: ink),
                        softWrap: false,
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
    pill = AnimatedBuilder(
      animation: presence,
      builder: (context, child) => Opacity(
        opacity: presence.value,
        child: Transform.scale(scale: 1 - ZsBadge._shrink * m * (1 - presence.value), child: child),
      ),
      child: pill,
    );
    // The identifier sits inside the exclusion: the count is read by the control the badge sits on.
    return IgnorePointer(
      child: ExcludeSemantics(
        child: widget.identifier == null ? pill : Semantics(identifier: widget.identifier, child: pill),
      ),
    );
  }
}

class _BadgePainter extends CustomPainter {
  _BadgePainter({required this.fill, required this.edge, required this.cutOut});

  final Color fill;
  final Color? edge;
  final Color? cutOut;

  @override
  void paint(Canvas canvas, Size size) {
    final pill = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.height / 2));
    final Color? cut = cutOut;
    if (cut != null) {
      // `0 0 0 2px var(--fl-bg-solid)`: a ring outside the pill.
      canvas.drawDRRect(pill.inflate(ZsBadge._cutOut), pill, Paint()..color = cut);
    }
    canvas.drawRRect(pill, Paint()..color = fill);
    final Color? line = edge;
    if (line != null) {
      // `inset 0 0 0 1px var(--accent-line)`.
      canvas.drawDRRect(pill, pill.deflate(1), Paint()..color = line);
    }
  }

  @override
  bool shouldRepaint(_BadgePainter oldDelegate) =>
      oldDelegate.fill != fill || oldDelegate.edge != edge || oldDelegate.cutOut != cutOut;
}
