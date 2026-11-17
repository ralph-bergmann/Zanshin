// SPDX-License-Identifier: MIT

part of 'zs_button.dart';

/// A split button's size (DS components/actions/SplitButton.d.ts).
enum ZsSplitButtonSize {
  /// 30 (`--control-md`): padding 0 12, the chevron 0 7, radius `--radius-btn`, `--type-control`.
  md,

  /// 26 (`--control-sm`): padding 0 10, the chevron 0 6, radius 8, 12 px.
  sm,
}

/// A button whose label runs a command and whose divided chevron opens the alternatives (DS
/// components/actions/SplitButton.{d.ts,jsx,prompt.md}; actions.css `.zs-splitbtn`). Buttons that look the same work
/// the same: a split button runs its label, a [ZsMenuButton] only opens a menu.
///
/// One shape in the [variant]'s rest fill and ring ([ZsButtonVariant.quiet] or [ZsButtonVariant.primary]); a 1 px
/// divider inset 7 top and bottom (`--fl-border`; the primary's gold at 45 %). Each part is its own control — Tab stop,
/// hover, pressed, focus ring inside, disabled — and paints its half's step: quiet `--fl-on` / `--fl-press`, primary
/// gold at 16 % / 28 %. The chevron (`chevron-down` 12; gold on the primary) opens a [ZsMenuAnchor] of [entries] on a
/// click, Space or ↩, placed by the anchor's rules.
///
/// [onPressed] null or a [disabledReason] disables the label; a [menuDisabledReason] disables the chevron. [tooltip]
/// (with the jj [cmd]) is the label's tooltip. VoiceOver: the label is a button named [label], the chevron a button
/// named "More [label] actions"; [identifier] marks the label, `<identifier>-more` the chevron.
class ZsSplitButton extends StatelessWidget implements ZsControl {
  /// A split button labelled [label] whose chevron opens [entries].
  const ZsSplitButton({
    required this.label,
    required this.entries,
    this.onPressed,
    this.variant = ZsButtonVariant.quiet,
    this.size = ZsSplitButtonSize.md,
    this.disabledReason,
    this.menuDisabledReason,
    this.tooltip,
    this.cmd,
    this.maxWidth = 360,
    this.statesController,
    this.menuStatesController,
    this.identifier,
    super.key,
  }) : assert(
         variant == ZsButtonVariant.quiet || variant == ZsButtonVariant.primary,
         'A split button is quiet or primary.',
       );

  /// The command the label runs, in sentence case.
  final String label;

  /// The alternatives the chevron opens.
  final List<ZsMenuEntry> entries;

  /// Runs on the label's activation; null disables the label.
  final VoidCallback? onPressed;

  /// The look: quiet or primary.
  final ZsButtonVariant variant;

  /// The size.
  final ZsSplitButtonSize size;

  /// Why the label is disabled.
  final String? disabledReason;

  /// Why the chevron is disabled.
  final String? menuDisabledReason;

  /// The label's tooltip.
  final String? tooltip;

  /// The jj command under the [tooltip].
  final String? cmd;

  /// The widest the menu grows by its content ([ZsMenuAnchor.maxWidth]).
  final double maxWidth;

  /// The label's states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  /// The chevron's states controller.
  final WidgetStatesController? menuStatesController;

  @override
  final String? identifier;

  @override
  Widget build(BuildContext context) => ZsMenuAnchor(
    entries: entries,
    maxWidth: maxWidth,
    builder: _shape,
  );

  Widget _shape(BuildContext context, ZsMenuController controller) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final small = size == ZsSplitButtonSize.sm;
    final primary = variant == ZsButtonVariant.primary;
    final bool contrast = ZsAppearance.of(context).increasedContrast;
    final double radius = small ? 8 : metrics.radiusBtn;
    final _Look rest = primary
        ? (
            fillA: colors.primaryFillA,
            fillB: colors.primaryFillB,
            ring: colors.primaryRing,
            edge: _clear,
            text: colors.text,
            icon: colors.primaryIcon,
          )
        : _flat(colors.flHover, colors.textMuted, edge: contrast ? colors.borderStrong : _clear);
    final String more = zsStrings(context).splitButtonMore(label);
    Widget labelPart = _part(
      context,
      leading: true,
      radius: radius,
      onActivate: disabledReason == null ? onPressed : null,
      disabledReason: disabledReason,
      semanticLabel: label,
      identifier: identifier,
      states: statesController,
      content: (color) => Padding(
        padding: EdgeInsets.symmetric(horizontal: small ? 10 : 12),
        child: Center(
          widthFactor: 1,
          child: Text(
            label,
            style: ZsType.control.copyWith(color: color, fontSize: small ? ZsType.fsMd : null),
            softWrap: false,
          ),
        ),
      ),
    );
    final String? tip = tooltip;
    if (tip != null) {
      labelPart = ZsTooltip(message: tip, cmd: cmd, child: labelPart);
    }
    Widget chevron = _part(
      context,
      leading: false,
      radius: radius,
      onActivate: menuDisabledReason == null ? controller.open : null,
      disabledReason: menuDisabledReason,
      semanticLabel: more,
      identifier: identifier == null ? null : '$identifier-more',
      states: menuStatesController,
      content: (color) => Padding(
        padding: EdgeInsets.symmetric(horizontal: small ? 6 : 7),
        child: Center(
          widthFactor: 1,
          child: ZanshinIcon(
            ZI.chevronDown,
            size: ZsIconSize.sm,
            color: primary ? colors.gold : color.withValues(alpha: color.a * .8),
          ),
        ),
      ),
    );
    if (menuDisabledReason == null) {
      chevron = ZsTooltip(message: more, child: chevron);
    }
    return CustomPaint(
      painter: _LookPainter(rest, radius),
      child: SizedBox(
        height: small ? metrics.controlSm : metrics.controlMd,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            labelPart,
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: SizedBox(
                width: 1,
                child: ColoredBox(
                  color: primary ? colors.gold.withValues(alpha: colors.gold.a * .45) : colors.flBorder,
                ),
              ),
            ),
            chevron,
          ],
        ),
      ),
    );
  }

  /// One part: its own control, painting its half's hover and press step over the shape.
  Widget _part(
    BuildContext context, {
    required bool leading,
    required double radius,
    required VoidCallback? onActivate,
    required String? disabledReason,
    required String semanticLabel,
    required String? identifier,
    required WidgetStatesController? states,
    required Widget Function(Color color) content,
  }) => ZsControlCore(
    identifier: identifier,
    statesController: states,
    onActivate: onActivate,
    enabled: onActivate != null,
    disabledReason: disabledReason,
    semantics: SemanticsProperties(button: true, label: semanticLabel),
    // shortcut: the ring takes the shape's radius on all four corners, where the CSS outline squares the divider
    // side; give ZsFocusRing per-corner radii if that shows.
    ring: ZsRingPlacement.inside,
    ringRadius: radius,
    builder: (context, status) {
      final ZsColors colors = ZsColors.of(context);
      final ZsMotion motion = ZsMotion.of(context);
      final primary = variant == ZsButtonVariant.primary;
      final bool lit = status.hovered || status.pressed;
      final Color fill = primary
          ? (status.pressed
                ? colors.gold.withValues(alpha: colors.gold.a * .28)
                : (status.hovered ? colors.gold.withValues(alpha: colors.gold.a * .16) : _clear))
          : (status.pressed ? colors.flPress : (status.hovered ? colors.flOn : _clear));
      return ZsLerpBuilder<_Look>(
        value: _flat(fill, primary || lit ? colors.text : colors.textMuted),
        lerp: _lerpLook,
        duration: status.pressed ? motion.durInstant : motion.durHover,
        curve: motion.easeState,
        builder: (context, look, _) => CustomPaint(
          painter: _HalfPainter(look.fillA, radius, leading: leading),
          child: content(look.text),
        ),
      );
    },
  );
}

/// Fills a split button's part, rounded on its outer side only.
class _HalfPainter extends CustomPainter {
  _HalfPainter(this.color, this.radius, {required this.leading});

  final Color color;
  final double radius;
  final bool leading;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) {
      return;
    }
    final corner = Radius.circular(radius.clamp(0, size.shortestSide / 2));
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Offset.zero & size,
        topLeft: leading ? corner : Radius.zero,
        bottomLeft: leading ? corner : Radius.zero,
        topRight: leading ? Radius.zero : corner,
        bottomRight: leading ? Radius.zero : corner,
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_HalfPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius || oldDelegate.leading != leading;
}
