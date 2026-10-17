// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_elevation.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../materials/zs_surface.dart';
import 'zs_control.dart';
import 'zs_control_text.dart';

/// The side a [ZsTooltip] prefers (DS components/controls/Tooltip.d.ts).
enum ZsTooltipPlacement {
  /// Below the control: the top bar's controls.
  below,

  /// Above the control: near the window's bottom edge.
  above,

  /// Right of the control: the rail.
  right,

  /// Left of the control.
  left,
}

/// The Zs tooltip, "verbs first, jj underneath": [message] (with [shortcut] beside it) over the exact jj [cmd]
/// (DS components/controls/Tooltip.{d.ts,jsx,prompt.md}; controls.css:36-50), on `RawTooltip`.
///
/// **Timing.** It shows after `--delay-tooltip` of rest over [child], and at once within `--dur-tooltip-warm` of any
/// Zs tooltip closing (one shared warm window) or while another is still open. Keyboard focus inside [child] shows it
/// after the same delay and leaving it hides it; pressing the control hides it; Esc hides it. It fades in with a 2 px
/// drift × `--motion` on `--dur-hover` / `--ease-glide` and fades out on `--dur-exit` / `--ease-exit`.
///
/// **Placement.** 8 px from the control on the [placement] side; if that side would leave the window it flips to
/// the opposite side, then it shifts along its axis to stay 8 px inside the window; it never covers its control.
/// Claude's proposal (Story 11.11): when neither side has room it keeps the preferred side, and the drift follows
/// the preferred side.
///
/// **Bubble.** `--tooltip-bg`, a 1 px `--tooltip-border`, `--shadow-tooltip`, radius `--radius-chip`, padding 5 8 6,
/// at most 300 wide; the label 500 `--fs-id` in `--text`, the shortcut in `--text-faint`, which reads as dim on the
/// tooltip (DS components/base.css:50), the command `--fs-sm` mono in `--text-dim`. It takes no pointer.
///
/// **Semantics.** The bubble is not in the semantics tree; the text joins the control's own node: a Zs control below
/// reads it through [semanticsOf] (the description VoiceOver gets, DS Tooltip.prompt.md:14; r4out a11y KVS-9).
class ZsTooltip extends StatefulWidget implements ZsControl {
  /// Shows [message] for [child].
  const ZsTooltip({
    required this.message,
    required this.child,
    this.cmd,
    this.shortcut,
    this.placement = ZsTooltipPlacement.below,
    this.identifier,
    super.key,
  });

  /// The label: the action's name or a disabled control's reason.
  final String message;

  /// The exact jj command, shown in mono on the second line.
  final String? cmd;

  /// A plain-text shortcut right of the label ("⌘N").
  final String? shortcut;

  /// The preferred side.
  final ZsTooltipPlacement placement;

  /// The control.
  final Widget child;

  /// The bubble's identifier, while it shows (it is hidden from VoiceOver; the message is the control's tooltip).
  @override
  final String? identifier;

  /// The gap between the control and the bubble, and the bubble's margin to the window edge (DS
  /// components/controls/controls.css:36; Tooltip.jsx:35).
  static const double _gap = 8;

  /// `max-width:300px` (DS components/controls/controls.css:38).
  static const double _maxWidth = 300;

  /// The drift of the entrance (DS components/controls/controls.css:47-50).
  static const double _drift = 2;

  /// Whether a Zs tooltip closed within `--dur-tooltip-warm`.
  static final _warm = ValueNotifier<bool>(false);
  static Timer? _cool;

  /// The text of the nearest enclosing tooltip — what a Zs control puts in its own semantics node; null outside one.
  static String? semanticsOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ZsTooltipScope>()?.description;

  /// Starts the warm window: the next tooltip within [warmFor] shows at once.
  static void _markClosed(Duration warmFor) {
    _warm.value = true;
    _cool?.cancel();
    _cool = Timer(warmFor, () => _warm.value = false);
  }

  /// Ends the warm window at once, so one test does not warm the next.
  @visibleForTesting
  static void resetWarmWindow() {
    _cool?.cancel();
    _cool = null;
    _warm.value = false;
  }

  @override
  State<ZsTooltip> createState() => _ZsTooltipState();
}

class _ZsTooltipState extends State<ZsTooltip> {
  final _tooltip = GlobalKey<RawTooltipState>();
  Timer? _focusTimer;
  var _shownByFocus = false;

  void _handleFocusChange(bool focused) {
    _focusTimer?.cancel();
    _focusTimer = null;
    if (focused) {
      final Duration delay = ZsTooltip._warm.value ? Duration.zero : ZsMotion.of(context).delayTooltip;
      _focusTimer = Timer(delay, () {
        _focusTimer = null;
        _shownByFocus = _tooltip.currentState?.ensureTooltipVisible() ?? false;
      });
    } else if (_shownByFocus) {
      _shownByFocus = false;
      RawTooltip.dismissAllToolTips();
    }
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    super.dispose();
  }

  Offset _position(TooltipPositionContext layout) {
    const double gap = ZsTooltip._gap;
    const double margin = ZsTooltip._gap;
    final Size tip = layout.tooltipSize;
    final Size window = layout.overlaySize;
    final Size target = layout.targetSize;
    final Offset centre = layout.target;
    double clampX(double x) => math.max(margin, math.min(x, window.width - margin - tip.width));
    double clampY(double y) => math.max(margin, math.min(y, window.height - margin - tip.height));
    final double below = centre.dy + target.height / 2 + gap;
    final double above = centre.dy - target.height / 2 - gap - tip.height;
    final double right = centre.dx + target.width / 2 + gap;
    final double left = centre.dx - target.width / 2 - gap - tip.width;
    final bool fitsBelow = below + tip.height <= window.height - margin;
    final bool fitsAbove = above >= margin;
    final bool fitsRight = right + tip.width <= window.width - margin;
    final bool fitsLeft = left >= margin;
    return switch (widget.placement) {
      ZsTooltipPlacement.below => Offset(clampX(centre.dx - tip.width / 2), !fitsBelow && fitsAbove ? above : below),
      ZsTooltipPlacement.above => Offset(clampX(centre.dx - tip.width / 2), !fitsAbove && fitsBelow ? below : above),
      ZsTooltipPlacement.right => Offset(!fitsRight && fitsLeft ? left : right, clampY(centre.dy - tip.height / 2)),
      ZsTooltipPlacement.left => Offset(!fitsLeft && fitsRight ? right : left, clampY(centre.dy - tip.height / 2)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final ZsMotion motion = ZsMotion.of(context);
    final String description = <String>[widget.message, ?widget.cmd].join('\n');
    return ValueListenableBuilder<bool>(
      valueListenable: ZsTooltip._warm,
      builder: (context, warm, child) => RawTooltip(
        key: _tooltip,
        semanticsTooltip: null,
        hoverDelay: warm ? Duration.zero : motion.delayTooltip,
        dismissDelay: Duration.zero,
        triggerMode: TooltipTriggerMode.manual,
        enableFeedback: false,
        ignorePointer: true,
        animationStyle: AnimationStyle(
          duration: motion.durHover,
          reverseDuration: motion.durExit,
          curve: motion.easeGlide,
          reverseCurve: motion.easeExit.flipped,
        ),
        positionDelegate: _position,
        tooltipBuilder: (context, animation) => _Bubble(
          animation: animation,
          message: widget.message,
          cmd: widget.cmd,
          shortcut: widget.shortcut,
          placement: widget.placement,
          identifier: widget.identifier,
        ),
        child: child!,
      ),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onFocusChange: _handleFocusChange,
        child: _ZsTooltipScope(description: description, child: widget.child),
      ),
    );
  }
}

class _ZsTooltipScope extends InheritedWidget {
  const _ZsTooltipScope({required this.description, required super.child});

  final String description;

  @override
  bool updateShouldNotify(_ZsTooltipScope oldWidget) => description != oldWidget.description;
}

/// The bubble; it reports its own closing to the shared warm window.
class _Bubble extends StatefulWidget {
  const _Bubble({
    required this.animation,
    required this.message,
    required this.cmd,
    required this.shortcut,
    required this.placement,
    required this.identifier,
  });

  final Animation<double> animation;
  final String message;
  final String? cmd;
  final String? shortcut;
  final ZsTooltipPlacement placement;
  final String? identifier;

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> {
  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(_Bubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onStatus);
      widget.animation.addStatusListener(_onStatus);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse && mounted) {
      ZsTooltip._markClosed(ZsMotion.of(context).durTooltipWarm);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final double drift = ZsTooltip._drift * ZsMotion.of(context).motion;
    final Offset from = switch (widget.placement) {
      ZsTooltipPlacement.below => Offset(0, -drift),
      ZsTooltipPlacement.above => Offset(0, drift),
      ZsTooltipPlacement.right => Offset(-drift, 0),
      ZsTooltipPlacement.left => Offset(drift, 0),
    };
    final TextStyle label = zsSans(ZsType.fsId, weight: FontWeight.w500, height: 1.35).copyWith(color: colors.text);
    final String? shortcut = widget.shortcut;
    final String? cmd = widget.cmd;
    return ExcludeSemantics(
      child: Semantics(
        identifier: widget.identifier,
        child: FadeTransition(
          opacity: widget.animation,
          child: AnimatedBuilder(
            animation: widget.animation,
            builder: (context, child) => Transform.translate(offset: from * (1 - widget.animation.value), child: child),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: ZsTooltip._maxWidth),
              child: ZsSurface(
                fill: colors.tooltipBg,
                border: colors.tooltipBorder,
                shadow: ZsElevation.of(context).shadowTooltip,
                radius: ZsMetrics.of(context).radiusChip,
                padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: <Widget>[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      spacing: 14,
                      children: <Widget>[
                        Flexible(child: Text(widget.message, style: label)),
                        if (shortcut != null)
                          Text(
                            shortcut,
                            style: zsWeighted(label, FontWeight.w400).copyWith(color: colors.textDim),
                            softWrap: false,
                          ),
                      ],
                    ),
                    if (cmd != null)
                      Text(
                        cmd,
                        style: zsMono(ZsType.fsSm, height: 1.35).copyWith(color: colors.textDim),
                        softWrap: false,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
