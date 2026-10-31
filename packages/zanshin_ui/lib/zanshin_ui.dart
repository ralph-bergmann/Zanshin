// SPDX-License-Identifier: MIT

/// Public API of Zanshin's design system. The package holds the tokens, the glass materials, the DS icons and fonts
/// and the Zs controls (Story 11.11); this library exports only the names the app consumes — the catalogue shows the
/// materials and every control, so those are exported too.
///
/// The app imports `package:zanshin_ui/zanshin_ui.dart` rather than reaching into `src/` directly. The export list
/// grows with what the app consumes.
library;

export 'l10n/zs_localizations.dart' show ZsLocalizations;
export 'src/controls/zs_badge.dart' show ZsBadge, ZsBadgeTone;
export 'src/controls/zs_button.dart' show ZsButton, ZsButtonSize, ZsButtonVariant, ZsIconButton, ZsIconButtonSize;
export 'src/controls/zs_checkbox.dart' show ZsCheckbox, ZsCheckboxSize, ZsCheckboxTone;
export 'src/controls/zs_chip.dart' show ZsChip, ZsChipKind, ZsChipSize;
export 'src/controls/zs_confirm_dialog.dart' show ZsConfirmDialog, ZsConfirmTone;
export 'src/controls/zs_control.dart' show ZsControl;
export 'src/controls/zs_control_core.dart' show ZsControlCore, ZsControlStatus;
export 'src/controls/zs_disclosure.dart' show ZsDisclosure;
export 'src/controls/zs_drag_ghost.dart' show ZsDragGhost, ZsDragGhostKind;
export 'src/controls/zs_field_list.dart' show ZsFieldListController, ZsFieldListRow;
export 'src/controls/zs_focus_ring.dart' show ZsFocusRing, ZsRingPlacement, zsRingFollowsInput;
export 'src/controls/zs_kbd.dart' show ZsKbd;
export 'src/controls/zs_link.dart' show ZsLink;
export 'src/controls/zs_menu.dart'
    show ZsMenuAnchor, ZsMenuController, ZsMenuEntry, ZsMenuHeader, ZsMenuItem, ZsMenuSeparator;
export 'src/controls/zs_popover.dart' show ZsOptionLink, ZsOptionRow, ZsPopover, ZsPopoverHeader, ZsPopoverSeparator;
export 'src/controls/zs_presence.dart' show ZsPresence;
export 'src/controls/zs_progress_bar.dart' show ZsProgressBar;
export 'src/controls/zs_radio.dart' show ZsRadio, ZsRadioGroup, ZsRadioOption;
export 'src/controls/zs_resize_edge.dart' show ZsResizeEdge, ZsResizeSide;
export 'src/controls/zs_scroll_area.dart' show ZsScrollArea;
export 'src/controls/zs_segmented.dart' show ZsSegment, ZsSegmented, ZsSegmentedSize, ZsSegmentedVariant;
export 'src/controls/zs_select.dart'
    show ZsSelect, ZsSelectCustom, ZsSelectEntry, ZsSelectHeader, ZsSelectOption, ZsSelectPlacement, ZsSelectSeparator;
export 'src/controls/zs_skeleton.dart' show ZsSkeleton, ZsSkeletonKind, paintZsSkeletonBar;
export 'src/controls/zs_slider.dart' show ZsSlider;
export 'src/controls/zs_spinner.dart' show ZsSpinner;
export 'src/controls/zs_switch.dart' show ZsSwitch;
export 'src/controls/zs_text_field.dart' show ZsSearchField, ZsTextEditingController, ZsTextField, ZsTextFieldSize;
export 'src/controls/zs_text_rung.dart' show ZsTextRung;
export 'src/controls/zs_tooltip.dart' show ZsTooltip, ZsTooltipBubble, ZsTooltipPlacement;
export 'src/design/graph_theme.dart' show GraphTheme;
export 'src/design/zs_app_theme.dart' show ZsAppTheme;
export 'src/design/zs_appearance.dart' show ZsAccentFamily, ZsAppearance, ZsAppearanceOverride, ZsTheme;
export 'src/design/zs_colors.dart' show ZsColors;
export 'src/design/zs_elevation.dart' show ZsElevation;
export 'src/design/zs_metrics.dart' show ZsIconSize, ZsMetrics;
export 'src/design/zs_motion.dart' show ZsMotion;
export 'src/design/zs_root.dart' show ZsRoot, ZsShellScope;
export 'src/design/zs_type.dart' show ZsType;
export 'src/design/zs_values.dart' show ZsGradientStop, ZsLinearGradient, ZsShadowStack;
export 'src/icons/icon_registry.dart' show IconRegistry, IconRegistryScope;
export 'src/icons/zanshin_icon.dart' show ZI, ZanshinIcon;
export 'src/icons/zs_nami_mark.dart' show ZsNamiMark;
export 'src/materials/zs_canvas.dart' show ZsCanvas;
export 'src/materials/zs_fade.dart' show ZsFade;
export 'src/materials/zs_glass.dart' show ZsGlass, ZsGlassBlur, ZsGlassFill, ZsIsland, ZsIslandSeparator, ZsIslandShape;
export 'src/materials/zs_menu_material.dart' show ZsMenuMaterial;
export 'src/materials/zs_sheet.dart' show ZsSheet;
export 'src/materials/zs_surface.dart' show ZsSurface;
export 'src/materials/zs_surface_transition.dart' show ZsSurfaceMotion, ZsSurfaceTransition;
export 'src/materials/zs_window_fill.dart' show ZsWindowFill;
export 'src/materials/zs_window_scaffold.dart' show ZsWindowHeaderAlign, ZsWindowScaffold;
