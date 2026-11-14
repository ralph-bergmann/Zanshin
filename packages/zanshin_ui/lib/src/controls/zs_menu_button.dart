// SPDX-License-Identifier: MIT

part of 'zs_button.dart';

/// A button that opens a menu (DS components/actions/MenuButton.{d.ts,jsx,prompt.md}; actions.css): [ZsButton]'s look —
/// [variant], [size], [icon], [disabledReason] — with a trailing `chevron-down` at 12, opacity .75, 5 after the label
/// and 8 before the right edge. Click, Space and ↩ open a [ZsMenuAnchor] of [entries] 4 below the button's left edge;
/// the menu's keys, activation and focus return are the anchor's.
///
/// [iconOnly] (Story 10.33, a diff header's options) shows the [icon] at 14 and the chevron 2 apart, no text, 26 high
/// with padding 0 5 0 6; [label] is its name and tooltip; [active] puts the glyph in `--accent` (a value off its
/// default).
///
/// A [disabledReason] disables it and is its tooltip. VoiceOver: a button with [label].
class ZsMenuButton extends StatelessWidget implements ZsControl {
  /// A button labelled [label] that opens [entries].
  const ZsMenuButton({
    required this.label,
    required this.entries,
    this.variant = ZsButtonVariant.quiet,
    this.size = ZsButtonSize.sm,
    this.icon,
    this.iconOnly = false,
    this.active = false,
    this.disabledReason,
    this.maxWidth = 360,
    this.focusNode,
    this.statesController,
    this.identifier,
    super.key,
  }) : assert(!iconOnly || icon != null, 'An icon-only menu button needs an icon.');

  /// Whether the button shows only its [icon] and the chevron.
  final bool iconOnly;

  /// Whether the icon-only glyph is `--accent`.
  final bool active;

  /// The button's label, in sentence case.
  final String label;

  /// The menu's rows.
  final List<ZsMenuEntry> entries;

  /// The look.
  final ZsButtonVariant variant;

  /// The size.
  final ZsButtonSize size;

  /// A `ZI` glyph before the label.
  final String? icon;

  /// Why the button is disabled; null enables it.
  final String? disabledReason;

  /// The widest the menu grows by its content ([ZsMenuAnchor.maxWidth]); 360 by default, as the DS `menuMaxWidth`:
  /// rows whose commands carry a change id need more than a menu's usual 320.
  final double maxWidth;

  /// The button's focus node.
  final FocusNode? focusNode;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  @override
  Widget build(BuildContext context) => ZsMenuAnchor(
    entries: entries,
    maxWidth: maxWidth,
    builder: (context, controller) => ZsButton._withChevron(
      label: label,
      onPressed: disabledReason == null ? controller.open : null,
      variant: variant,
      size: size,
      icon: icon,
      iconOnly: iconOnly,
      active: active,
      disabledReason: disabledReason,
      focusNode: focusNode,
      statesController: statesController,
      identifier: identifier,
    ),
  );
}
