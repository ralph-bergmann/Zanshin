// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../materials/zs_menu_material.dart';
import '../materials/zs_surface_transition.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_control_text.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';
import 'zs_text_rung.dart';

/// A popover's content (DS components/surfaces/Popover.{d.ts,jsx,prompt.md}; surfaces.css:8-12, :49-54, :57): the
/// settings sheet dropped from an island button — the menu material (11.2), padding 6 8 10, its children 2 apart,
/// [width] wide, entering and leaving as the popover (`ZsSurfaceTransition`, `--dur-pop` in, `--dur-exit` out).
///
/// Content only: its placement against the island, and closing it on Esc, Tab past the end or a click outside, are
/// 11.3's overlay host. VoiceOver: a non-modal dialog named [label] (its header).
class ZsPopover extends StatelessWidget implements ZsControl {
  /// A popover showing [child].
  const ZsPopover({
    required this.child,
    this.width = 340,
    this.label,
    this.closing = false,
    this.onClosed,
    this.identifier,
    super.key,
  });

  /// The rows: headers, option rows, separators, an option link.
  final Widget child;

  /// The popover's width (DS components/surfaces/Popover.jsx:4).
  final double width;

  /// The accessible name.
  final String? label;

  /// Whether the popover leaves.
  final bool closing;

  /// Runs once the exit completes.
  final VoidCallback? onClosed;

  @override
  final String? identifier;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    identifier: identifier,
    label: label,
    child: ZsSurfaceTransition(
      motion: ZsSurfaceMotion.popover,
      closing: closing,
      onClosed: onClosed,
      child: SizedBox(
        width: width,
        child: ZsMenuMaterial(
          // `padding:6px 8px 10px` (DS components/surfaces/surfaces.css:9).
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
          child: child,
        ),
      ),
    ),
  );
}

/// A popover's caps heading (DS components/surfaces/surfaces.css:10): `--type-caps` in `--text-dim`, padding 10 8 4.
class ZsPopoverHeader extends StatelessWidget implements ZsControl {
  /// A heading reading [label].
  const ZsPopoverHeader(this.label, {this.identifier, super.key});

  /// The heading.
  final String label;

  @override
  final String? identifier;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    identifier: identifier,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
      child: Text(ZsType.caps(label), style: ZsType.capsLabel.copyWith(color: ZsColors.of(context).textDim)),
    ),
  );
}

/// A popover's hairline (DS components/surfaces/surfaces.css:11): 1 px `--fl-border`, margin 6 4 2.
class ZsPopoverSeparator extends StatelessWidget implements ZsControl {
  /// A separator.
  const ZsPopoverSeparator({this.identifier, super.key});

  @override
  final String? identifier;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Semantics(
      identifier: identifier,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
        child: SizedBox(height: 1, child: ColoredBox(color: ZsColors.of(context).flBorder)),
      ),
    ),
  );
}

/// A 36 px option row (DS components/surfaces/surfaces.css:12): the label left, its control right, gap 12, padding
/// 0 8, radius `--radius-md`, `--fs-control` in `--text-muted`.
class ZsOptionRow extends StatelessWidget implements ZsControl {
  /// A row labelled [label] holding [child].
  const ZsOptionRow({required this.label, required this.child, this.identifier, super.key});

  /// The setting's name.
  final String label;

  /// The control (a switch, a segmented control, a slider).
  final Widget child;

  @override
  final String? identifier;

  /// `min-height:36px` (DS components/surfaces/surfaces.css:12).
  static const double _minHeight = 36;

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: identifier,
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: _minHeight + ZsMetrics.of(context).rowStep),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          spacing: 12,
          children: <Widget>[
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  label,
                  style: zsSans(
                    ZsType.fsControl,
                    height: ZsType.lhSnug,
                  ).copyWith(color: ZsColors.of(context).textMuted),
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    ),
  );
}

/// The popover's way out (DS components/surfaces/Popover.jsx:30-39; surfaces.css:49-54): a 36 px row, the label
/// left in `--text-muted`, the [action] (`--fs-md`, `--text-dim`) and a [shortcut] (`--text-faint`) right — a
/// shortcut only when the row does exactly what it does. Hover `--fl-hover` with `--text`, pressed `--fl-on`; the
/// right side's text steps up a rung on the fill; the focus ring sits inside the row.
class ZsOptionLink extends StatelessWidget implements ZsControl {
  /// A row labelled [label].
  const ZsOptionLink({
    required this.label,
    this.action,
    this.shortcut,
    this.onPressed,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// Where it leads.
  final String label;

  /// The right side ("Settings…").
  final String? action;

  /// A plain-text shortcut ("⌘,").
  final String? shortcut;

  /// Runs on activation.
  final VoidCallback? onPressed;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// `min-height:36px` (DS components/surfaces/surfaces.css:50).
  static const double _minHeight = 36;

  @override
  Widget build(BuildContext context) {
    final double radius = ZsMetrics.of(context).radiusMd;
    return ZsControlCore(
      identifier: identifier,
      statesController: statesController,
      onActivate: onPressed,
      enabled: onPressed != null,
      semantics: SemanticsProperties(button: true, label: label),
      ring: ZsRingPlacement.inside,
      ringRadius: radius,
      builder: (context, status) {
        final ZsColors colors = ZsColors.of(context);
        final ZsMotion motion = ZsMotion.of(context);
        final rung = ZsTextRung.of(colors, hovered: status.hovered, raised: status.pressed);
        final bool lit = status.hovered || status.pressed;
        const clear = Color(0x00000000);
        final String? action = this.action;
        final String? shortcut = this.shortcut;
        return ZsLerpBuilder<(Color, Color)>(
          value: (
            status.pressed ? colors.flOn : (status.hovered ? colors.flHover : clear),
            lit ? colors.text : colors.textMuted,
          ),
          lerp: (a, b, t) => (Color.lerp(a.$1, b.$1, t)!, Color.lerp(a.$2, b.$2, t)!),
          duration: status.pressed ? motion.durInstant : motion.durHover,
          curve: motion.easeState,
          builder: (context, look, _) => DecoratedBox(
            decoration: BoxDecoration(color: look.$1, borderRadius: BorderRadius.circular(radius)),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: _minHeight + ZsMetrics.of(context).rowStep),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  spacing: 12,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        label,
                        style: zsSans(ZsType.fsControl, height: ZsType.lhSnug).copyWith(color: look.$2),
                      ),
                    ),
                    if (action != null || shortcut != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 6,
                        children: <Widget>[
                          if (action != null) Text(action, style: zsSans(ZsType.fsMd).copyWith(color: rung.dim)),
                          if (shortcut != null) Text(shortcut, style: zsSans(ZsType.fsMd).copyWith(color: rung.faint)),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
