// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show SemanticsProperties, SemanticsRole;
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../icons/zanshin_icon.dart';
import '../materials/zs_glass.dart';
import '../zs_strings.dart';
import 'zs_control_core.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';
import 'zs_tooltip.dart';

/// A toast's tone (DS components/overlays/Toast.jsx:5; overlays.css:7-11).
enum ZsToastTone {
  /// What happened, with Undo: no glyph.
  success,

  /// Refused, nothing changed: the `conflict` glyph in `--warn`.
  warn,

  /// Failed, with an action such as Retry: the `alert` glyph in `--rem`, role alert.
  error,
}

/// One of a toast's quiet pill buttons (Undo, Redo, Retry).
@immutable
class ZsToastAction {
  /// A button labelled [label] whose tooltip is [tooltip], the jj command it runs.
  const ZsToastAction({required this.label, required this.tooltip, required this.onPressed, this.identifier});

  /// The verb.
  final String label;

  /// The jj command it runs.
  final String tooltip;

  /// Runs on activation.
  final VoidCallback onPressed;

  /// The button's `Semantics(identifier:)`.
  final String? identifier;
}

/// The operation toast's look (DS components/overlays/Toast.{jsx,prompt.md}; overlays.css:4-22): a 36 px
/// (`--control-lg`) glass pill — `ZsGlass(fill: strong, blur: regular, radius: radiusPill)` — padding 0 5 0 15, gap 8;
/// the warn or error glyph (md, margin-left −3), [message] in `--type-control` `--text` on one line, ellipsized; the
/// [actions] as 26 px (`--control-sm`) quiet pills, padding 0 13, margin-left 4, 500 `--text` on `--fl-hover` → hover
/// `--fl-on` → pressed `--fl-press`, each with its command as tooltip; × a 26 px circle, `ZI.close` xs in `--text-dim`,
/// hover `--fl-hover` / `--text`, pressed `--fl-on`, labelled "Dismiss". Focus rings are `--focus-ring`.
///
/// Look only: the host places, times and animates it. [tooltip] shows over the text (a report with several lines).
/// [actionFocusSkip] keeps the buttons out of Tab (the toast is not in the Tab order while you work; DS
/// Toast.prompt.md:15) — they still take focus when it is moved to them. VoiceOver: success and warn are a polite live
/// region, error a `SemanticsRole.alert`; the label is the plain text.
class ZsToast extends StatefulWidget {
  /// A toast saying [message].
  const ZsToast({
    required this.message,
    this.tone = ZsToastTone.success,
    this.actions = const <ZsToastAction>[],
    this.onDismiss,
    this.tooltip,
    this.actionFocusSkip = false,
    this.identifier,
    super.key,
  });

  /// This toast with [actionFocusSkip] set to [skip] (the host decides it).
  ZsToast withActionFocusSkip(bool skip) => ZsToast(
    message: message,
    tone: tone,
    actions: actions,
    onDismiss: onDismiss,
    tooltip: tooltip,
    actionFocusSkip: skip,
    identifier: identifier,
    key: key,
  );

  /// The text, its ids in mono.
  final InlineSpan message;

  /// The tone.
  final ZsToastTone tone;

  /// Undo, Redo, Retry.
  final List<ZsToastAction> actions;

  /// The ×; none without it.
  final VoidCallback? onDismiss;

  /// A tooltip over the text.
  final String? tooltip;

  /// Whether Tab skips the buttons.
  final bool actionFocusSkip;

  /// The toast's `Semantics(identifier:)`.
  final String? identifier;

  @override
  State<ZsToast> createState() => _ZsToastState();
}

class _ZsToastState extends State<ZsToast> {
  // One per action, then the ×'s. A node of its own, not an `ExcludeFocusTraversal` above: a `Focus` rebuilt under one
  // writes its node's ancestor-derived `skipTraversal` back as its own, and the button would stay skipped.
  final _nodes = <FocusNode>[];

  @override
  void dispose() {
    for (final FocusNode node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _node(int i) {
    while (_nodes.length <= i) {
      _nodes.add(FocusNode(debugLabel: 'ZsToast button'));
    }
    return _nodes[i]..skipTraversal = widget.actionFocusSkip;
  }

  @override
  Widget build(BuildContext context) {
    final ZsToastTone tone = widget.tone;
    final InlineSpan message = widget.message;
    final List<ZsToastAction> actions = widget.actions;
    final metrics = ZsMetrics.of(context);
    final ZsColors colors = ZsColors.of(context);
    final String? glyph = switch (tone) {
      ZsToastTone.success => null,
      ZsToastTone.warn => ZI.conflict,
      ZsToastTone.error => ZI.alert,
    };
    final String? hover = widget.tooltip;
    Widget text = Text.rich(
      message,
      style: ZsType.control.copyWith(color: colors.text),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );
    if (hover != null) {
      text = ZsTooltip(message: hover, placement: ZsTooltipPlacement.above, child: text);
    }
    final Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: <Widget>[
        if (glyph != null)
          ZanshinIcon(glyph, size: ZsIconSize.md, color: tone == ZsToastTone.warn ? colors.warn : colors.rem),
        Flexible(child: ExcludeSemantics(child: text)),
        for (final (int i, ZsToastAction action) in actions.indexed)
          Padding(
            // `margin-left:4px` (DS components/overlays/overlays.css:17).
            padding: EdgeInsets.only(left: i == 0 ? 4 : 0),
            child: _ActionButton(action: action, focusNode: _node(i)),
          ),
        if (widget.onDismiss case final VoidCallback dismiss)
          _DismissButton(onPressed: dismiss, focusNode: _node(actions.length)),
      ],
    );
    return Semantics(
      container: true,
      identifier: widget.identifier,
      liveRegion: tone != ZsToastTone.error,
      role: tone == ZsToastTone.error ? SemanticsRole.alert : null,
      label: message.toPlainText(),
      child: SizedBox(
        height: metrics.controlLg,
        child: ZsGlass(
          fill: ZsGlassFill.strong,
          radius: metrics.radiusPill,
          // `padding:0 5px 0 15px`; the glyph's `margin-left:-3px` (DS components/overlays/overlays.css:4, :9).
          padding: EdgeInsets.only(left: glyph == null ? 15 : 12, right: 5),
          child: row,
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, required this.focusNode});

  final ZsToastAction action;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    return ZsTooltip(
      message: action.tooltip,
      placement: ZsTooltipPlacement.above,
      child: ZsControlCore(
        identifier: action.identifier,
        focusNode: focusNode,
        onActivate: action.onPressed,
        semantics: SemanticsProperties(button: true, label: action.label),
        ring: ZsRingPlacement.outside,
        ringRadius: metrics.controlSm / 2,
        builder: (context, status) {
          final ZsColors colors = ZsColors.of(context);
          final Color fill = status.pressed ? colors.flPress : (status.hovered ? colors.flOn : colors.flHover);
          return _Pill(
            fill: fill,
            pressed: status.pressed,
            child: SizedBox(
              height: metrics.controlSm,
              child: Padding(
                // `padding:0 13px` (DS components/overlays/overlays.css:17).
                padding: const EdgeInsets.symmetric(horizontal: 13),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    action.label,
                    // `font-weight:500` (DS components/overlays/overlays.css:17).
                    style: ZsType.control.copyWith(color: colors.text, fontWeight: ZsType.fwMedium),
                    softWrap: false,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DismissButton extends StatelessWidget {
  const _DismissButton({required this.onPressed, required this.focusNode});

  final VoidCallback onPressed;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    return ZsControlCore(
      identifier: 'toast-dismiss',
      focusNode: focusNode,
      onActivate: onPressed,
      semantics: SemanticsProperties(button: true, label: zsStrings(context).toastDismiss),
      ring: ZsRingPlacement.outside,
      ringRadius: metrics.controlSm / 2,
      builder: (context, status) {
        final ZsColors colors = ZsColors.of(context);
        final bool lit = status.hovered || status.pressed;
        final Color fill = status.pressed ? colors.flOn : (status.hovered ? colors.flHover : const Color(0x00000000));
        return _Pill(
          fill: fill,
          pressed: status.pressed,
          child: SizedBox.square(
            dimension: metrics.controlSm,
            child: Center(
              child: ZanshinIcon(ZI.close, size: ZsIconSize.xs, color: lit ? colors.text : colors.textDim),
            ),
          ),
        );
      },
    );
  }
}

/// A pill whose fill fades on `--dur-hover` / `--ease-state`, the press at once.
class _Pill extends StatelessWidget {
  const _Pill({required this.fill, required this.pressed, required this.child});

  final Color fill;
  final bool pressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZsMotion motion = ZsMotion.of(context);
    return ZsLerpBuilder<Color>(
      value: fill,
      lerp: (a, b, t) => Color.lerp(a, b, t)!,
      duration: pressed ? motion.durInstant : motion.durHover,
      curve: motion.easeState,
      child: child,
      builder: (context, color, child) => DecoratedBox(
        decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
        child: child,
      ),
    );
  }
}
