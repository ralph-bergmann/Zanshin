// SPDX-License-Identifier: MIT

/// Public API of Zanshin's design system. The package holds the tokens, the glass materials and the DS icons and
/// fonts; this library exports only the names the app consumes, so the materials join it with their first user.
///
/// The app imports `package:zanshin_ui/zanshin_ui.dart` rather than reaching into `src/` directly. The export list
/// grows with what the app consumes.
library;

export 'src/design/zs_app_theme.dart' show ZsAppTheme;
export 'src/design/zs_appearance.dart' show ZsAccentFamily, ZsAppearance, ZsTheme;
export 'src/design/zs_colors.dart' show ZsColors;
export 'src/design/zs_elevation.dart' show ZsElevation;
export 'src/design/zs_metrics.dart' show ZsIconSize;
export 'src/design/zs_motion.dart' show ZsMotion;
export 'src/design/zs_root.dart' show ZsRoot;
export 'src/design/zs_type.dart' show ZsType;
export 'src/icons/icon_registry.dart' show IconRegistry, IconRegistryScope;
export 'src/icons/zanshin_icon.dart' show ZI, ZanshinIcon;
