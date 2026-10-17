// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/widgets.dart';

import '../design/zs_appearance.dart';
import '../design/zs_colors.dart';
import '../design/zs_elevation.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../icons/zanshin_icon.dart';
import '../materials/zs_surface.dart';
import 'zs_badge.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';
import 'zs_spinner.dart';
import 'zs_tooltip.dart';

/// A text button's look (DS components/actions/Button.d.ts; actions.css:4-32).
enum ZsButtonVariant {
  /// The quiet default: `--fl-hover` → `--fl-on` → `--fl-press`, `--text-muted` turning `--text` (the DS's
  /// "default").
  quiet,

  /// Transparent, `--text-dim`: hover `--fl-hover`, pressed `--fl-on`.
  ghost,

  /// Quiet until hover, then a red tint with red text, never a solid red fill: `--danger-hover` → `--danger-press`.
  danger,

  /// The confirmation's filled red button, the primary's build in red (`--destructive-*`); its icon in `--rem`.
  destructive,

  /// The gold primary, the one main action of a view (`--primary-*`; DS readme.md:143).
  primary,
}

/// A text button's size (DS components/actions/Button.d.ts).
enum ZsButtonSize {
  /// 30 (`--control-md`): inspector, dialogs, settings.
  sm,

  /// The same 30; kept for the DS's existing calls.
  md,

  /// 44 (`--control-xl`): the top bar's one primary action, radius `--radius-island`, `--fs-base`.
  lg,
}

/// The fills, ring and colours a button paints in one state.
typedef _Look = ({Color fillA, Color fillB, Color ring, Color edge, Color text, Color icon});

_Look _lerpLook(_Look a, _Look b, double t) => (
  fillA: Color.lerp(a.fillA, b.fillA, t)!,
  fillB: Color.lerp(a.fillB, b.fillB, t)!,
  ring: Color.lerp(a.ring, b.ring, t)!,
  edge: Color.lerp(a.edge, b.edge, t)!,
  text: Color.lerp(a.text, b.text, t)!,
  icon: Color.lerp(a.icon, b.icon, t)!,
);

const _clear = Color(0x00000000);

/// A flat look: one fill, the [text] colour for the icon too.
_Look _flat(Color fill, Color text, {Color edge = _clear}) =>
    (fillA: fill, fillB: fill, ring: _clear, edge: edge, text: text, icon: text);

/// Paints a control's fill — a solid colour, or the 180° two-stop gradient of the gold and red builds — and its inset
/// 1 px ring and edge (`box-shadow: inset 0 0 0 1px`).
class _LookPainter extends CustomPainter {
  _LookPainter(this.look, this.radius);

  final _Look look;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect box = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(box, Radius.circular(radius.clamp(0, size.shortestSide / 2)));
    final fill = Paint();
    if (look.fillA == look.fillB) {
      fill.color = look.fillA;
    } else {
      fill.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[look.fillA, look.fillB],
      ).createShader(box);
    }
    canvas.drawRRect(rrect, fill);
    for (final line in <Color>[look.ring, look.edge]) {
      if (line.a > 0) {
        canvas.drawDRRect(rrect, rrect.deflate(1), Paint()..color = line);
      }
    }
  }

  @override
  bool shouldRepaint(_LookPainter oldDelegate) => oldDelegate.look != look || oldDelegate.radius != radius;
}

/// A text button for commands (DS components/actions/Button.{d.ts,jsx,prompt.md}; actions.css:1-32): 30 high
/// (`--control-md`; lg 44), padding 0 12 (lg 0 16 0 13), gap 7 (lg 8), radius `--radius-btn` (lg `--radius-island`),
/// `--type-control` (lg at `--fs-base`); the icon sits before the label at md (lg at lg).
///
/// Rest → hover → pressed is one fill step each, the press instant, no shrink; every colour fades on `--dur-hover`
/// and the press appears at once (DS readme.md:102). The gold [ZsButtonVariant.primary] and the red
/// [ZsButtonVariant.destructive] step fill and inset 1 px ring together; the large primary lays the gold over the
/// island glass (`--fl-bg` with `--glass-blur`) and `--fl-shadow` (DS components/actions/actions.css:16-18). Under
/// increased contrast every other variant adds a 1 px `--border-strong` edge (DS tokens/contrast.css:23); the gold
/// stays in an inactive window.
///
/// [iconOnly] makes it square with [label] as its name and tooltip. [busy] puts a spinner in the icon slot while the
/// label and width hold, ignores presses and shows the `progress` cursor. A Tab stop; Space / ↩ press it, the press
/// showing while held. VoiceOver: a button with [label]; busy reads "busy"; disabled with a reason reads the reason.
class ZsButton extends StatelessWidget implements ZsControl {
  /// A button labelled [label].
  const ZsButton({
    required this.label,
    this.onPressed,
    this.variant = ZsButtonVariant.quiet,
    this.size = ZsButtonSize.sm,
    this.icon,
    this.iconOnly = false,
    this.busy = false,
    this.disabledReason,
    this.focusNode,
    this.statesController,
    this.identifier,
    super.key,
  }) : assert(!iconOnly || icon != null, 'An icon-only button needs an icon.');

  /// The verb, in sentence case; the name and tooltip of an icon-only button.
  final String label;

  /// Runs on activation; null disables the button.
  final VoidCallback? onPressed;

  /// The look.
  final ZsButtonVariant variant;

  /// The size.
  final ZsButtonSize size;

  /// A `ZI` glyph before the label.
  final String? icon;

  /// Whether the button shows only its [icon], square.
  final bool iconOnly;

  /// Whether the action runs.
  final bool busy;

  /// Why the button is disabled.
  final String? disabledReason;

  /// The button's focus node.
  final FocusNode? focusNode;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  bool get _large => size == ZsButtonSize.lg;

  _Look _look(ZsColors c, ZsControlStatus s, {required bool contrast}) {
    final bool hover = s.hovered;
    final bool press = s.pressed;
    final Color edge = contrast ? c.borderStrong : _clear;
    switch (variant) {
      case ZsButtonVariant.quiet:
        return _flat(
          press ? c.flPress : (hover ? c.flOn : c.flHover),
          hover || press ? c.text : c.textMuted,
          edge: edge,
        );
      case ZsButtonVariant.ghost:
        return _flat(press ? c.flOn : (hover ? c.flHover : _clear), hover || press ? c.text : c.textDim, edge: edge);
      case ZsButtonVariant.danger:
        return _flat(
          press ? c.dangerPress : (hover ? c.dangerHover : _clear),
          hover || press ? c.rem : c.textDim,
          edge: edge,
        );
      case ZsButtonVariant.primary:
        return (
          fillA: press ? c.primaryFillAPress : (hover ? c.primaryFillAHover : c.primaryFillA),
          fillB: press ? c.primaryFillBPress : (hover ? c.primaryFillBHover : c.primaryFillB),
          ring: hover || press ? c.primaryRingHover : c.primaryRing,
          edge: _clear,
          text: c.text,
          icon: c.primaryIcon,
        );
      case ZsButtonVariant.destructive:
        return (
          fillA: press ? c.destructiveFillAPress : (hover ? c.destructiveFillAHover : c.destructiveFillA),
          fillB: press ? c.destructiveFillBPress : (hover ? c.destructiveFillBHover : c.destructiveFillB),
          ring: hover || press ? c.destructiveRingHover : c.destructiveRing,
          edge: _clear,
          text: c.text,
          icon: c.rem,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    final double radius = _large ? metrics.radiusIsland : metrics.radiusBtn;
    final Widget button = ZsControlCore(
      identifier: identifier,
      focusNode: focusNode,
      statesController: statesController,
      onActivate: onPressed,
      enabled: onPressed != null,
      disabledReason: disabledReason,
      busy: busy,
      semantics: SemanticsProperties(button: true, label: label),
      ring: ZsRingPlacement.outside,
      ringRadius: radius,
      builder: (context, status) => _paint(context, status, metrics, radius),
    );
    return iconOnly ? ZsTooltip(message: label, child: button) : button;
  }

  Widget _paint(BuildContext context, ZsControlStatus status, ZsMetrics metrics, double radius) {
    final ZsColors colors = ZsColors.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final bool contrast = ZsAppearance.of(context).increasedContrast;
    final double height = _large ? metrics.controlXl : metrics.controlMd;
    final ZsIconSize iconSize = _large ? ZsIconSize.lg : ZsIconSize.md;
    return ZsLerpBuilder<_Look>(
      value: _look(colors, status, contrast: contrast),
      lerp: _lerpLook,
      duration: status.pressed ? motion.durInstant : motion.durHover,
      curve: motion.easeState,
      builder: (context, look, _) {
        final String? glyph = icon;
        final Widget? mark = busy
            ? ZsSpinner(size: iconSize, color: look.icon)
            : (glyph == null ? null : ZanshinIcon(glyph, size: iconSize, color: look.icon));
        final Widget content = iconOnly
            ? SizedBox.square(
                dimension: height,
                child: Center(child: mark),
              )
            : SizedBox(
                height: height,
                child: Padding(
                  // `padding:0 12px` (lg `0 16px 0 13px`; DS components/actions/actions.css:4, :8).
                  padding: _large
                      ? const EdgeInsets.fromLTRB(13, 0, 16, 0)
                      : const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: _large ? 8 : 7,
                    children: <Widget>[
                      ?mark,
                      Text(
                        label,
                        style: ZsType.control.copyWith(
                          color: look.text,
                          fontSize: _large ? ZsType.fsBase : null,
                        ),
                        softWrap: false,
                      ),
                    ],
                  ),
                ),
              );
        final Widget painted = CustomPaint(painter: _LookPainter(look, radius), child: content);
        if (!(_large && variant == ZsButtonVariant.primary)) {
          return painted;
        }
        final ZsElevation elevation = ZsElevation.of(context);
        return ZsSurface(
          fill: colors.flBg,
          shadow: elevation.flShadow,
          radius: radius,
          filter: elevation.glassBlur,
          // The surface shows the arrow; the button's own cursor (progress while busy) must win inside it.
          child: MouseRegion(cursor: busy ? SystemMouseCursors.progress : SystemMouseCursors.basic, child: painted),
        );
      },
    );
  }
}

/// An icon button's size (DS components/actions/IconButton.d.ts).
enum ZsIconButtonSize {
  /// 30 (`--control-md`): a panel's close button; radius `--radius-md`, `--text-dim`, the icon at sm.
  sm,

  /// 36 (`--control-lg`): inside islands; radius `--radius-card`, `--text-muted`, the icon at bar.
  md,

  /// 40 (`--chrome-rail-btn`): the rail; radius `--radius-rail`, `--text-dim`, the icon at rail, the ring inside.
  lg,
}

/// A square icon button for island toolbars, the rail and panel close buttons (DS
/// components/actions/IconButton.{d.ts,jsx,prompt.md}; actions.css:34-45): transparent at rest, hover `--fl-hover`,
/// pressed `--fl-on`; [active] (toggled, or its panel open) `--fl-on` → hover `--fl-on-hover` → pressed
/// `--fl-press`, the icon in `--text` from hover on. Under increased contrast an active button adds a 1 px
/// `--border-strong` edge (DS tokens/contrast.css:25).
///
/// [label] is its name and its tooltip (right of the rail button, below otherwise); a [badge] sits on the top-right
/// corner and joins the name ("Fetch, 3"). A Tab stop (the rail's ring inside); Space / ↩.
class ZsIconButton extends StatelessWidget implements ZsControl {
  /// An icon button showing [icon], named [label].
  const ZsIconButton({
    required this.icon,
    required this.label,
    this.onPressed,
    this.size = ZsIconButtonSize.md,
    this.active = false,
    this.badge,
    this.disabledReason,
    this.focusNode,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// A `ZI` glyph.
  final String icon;

  /// The name, also the tooltip.
  final String label;

  /// Runs on activation; null disables the button.
  final VoidCallback? onPressed;

  /// The size.
  final ZsIconButtonSize size;

  /// Whether it is toggled on or its panel is open (`aria-pressed`).
  final bool active;

  /// A count on the corner (see [ZsBadge.count]); null, 0 and false hide it with its exit.
  final Object? badge;

  /// Why the button is disabled.
  final String? disabledReason;

  /// The button's focus node.
  final FocusNode? focusNode;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  bool get _hasBadge => badge != null && badge != false && badge != 0;

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    final (double side, double radius, ZsIconSize glyph, EdgeInsets badgeAt) = switch (size) {
      // The badge's corner offsets: `top:1px;right:0` · `top:4px;right:3px` · `top:4px;right:4px` (DS
      // components/actions/actions.css:43-45).
      ZsIconButtonSize.sm => (metrics.controlMd, metrics.radiusMd, ZsIconSize.sm, const EdgeInsets.only(top: 1)),
      ZsIconButtonSize.md => (
        metrics.controlLg,
        metrics.radiusCard,
        ZsIconSize.bar,
        const EdgeInsets.only(top: 4, right: 3),
      ),
      ZsIconButtonSize.lg => (
        metrics.chromeRailBtn,
        metrics.radiusRail,
        ZsIconSize.rail,
        const EdgeInsets.only(top: 4, right: 4),
      ),
    };
    final Widget button = ZsControlCore(
      identifier: identifier,
      focusNode: focusNode,
      statesController: statesController,
      onActivate: onPressed,
      enabled: onPressed != null,
      disabledReason: disabledReason,
      selected: active,
      semantics: SemanticsProperties(
        button: true,
        // A dot (`true`) has no count to read.
        label: _hasBadge && badge is! bool ? '$label, $badge' : label,
        toggled: active ? true : null,
      ),
      ring: size == ZsIconButtonSize.lg ? ZsRingPlacement.inside : ZsRingPlacement.outside,
      ringRadius: radius,
      builder: (context, status) {
        final ZsColors colors = ZsColors.of(context);
        final ZsMotion motion = ZsMotion.of(context);
        final bool contrast = ZsAppearance.of(context).increasedContrast;
        final Color rest = size == ZsIconButtonSize.md ? colors.textMuted : colors.textDim;
        final bool on = status.selected;
        final Color fill = on
            ? (status.pressed ? colors.flPress : (status.hovered ? colors.flOnHover : colors.flOn))
            : (status.pressed ? colors.flOn : (status.hovered ? colors.flHover : _clear));
        final bool lit = on || status.hovered || status.pressed;
        return ZsLerpBuilder<_Look>(
          value: _flat(fill, lit ? colors.text : rest, edge: on && contrast ? colors.borderStrong : _clear),
          lerp: _lerpLook,
          duration: status.pressed ? motion.durInstant : motion.durHover,
          curve: motion.easeState,
          builder: (context, look, _) => CustomPaint(
            painter: _LookPainter(look, radius),
            child: SizedBox.square(
              dimension: side,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Center(
                    child: ZanshinIcon(icon, size: glyph, color: look.icon),
                  ),
                  Positioned(
                    top: badgeAt.top,
                    right: badgeAt.right,
                    child: ZsBadge(count: badge),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    return ZsTooltip(
      message: label,
      placement: size == ZsIconButtonSize.lg ? ZsTooltipPlacement.right : ZsTooltipPlacement.below,
      child: button,
    );
  }
}
