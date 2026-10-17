// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The appearance a use case shows: the theme, the accent family and the system flags, plus the inactive window
/// (Claude's proposal, Story 11.11: the inactive look is a witness state of the controls).
typedef CatalogueAppearance = ({
  ZsTheme theme,
  ZsAccentFamily accent,
  bool contrast,
  bool reduceMotion,
  bool reduceTransparency,
  bool inactive,
});

/// The catalogue's "Appearance" addon (query group `appearance`): every use case is shown under a window root with
/// these values over the DS canvas (`--canvas-base`).
///
/// Addons run inside the app builder, so the use case gets its own [ZsRoot] under a [ZsAppearanceOverride]; the
/// override wins over what the shell reports to the app builder.
class AppearanceAddon extends WidgetbookAddon<CatalogueAppearance> {
  /// The addon, starting in night with Zanshin's own accent and no system flag.
  AppearanceAddon() : super(name: 'Appearance');

  @override
  List<Field> get fields => <Field>[
    ObjectDropdownField<ZsTheme>(
      name: 'theme',
      values: ZsTheme.values,
      initialValue: ZsTheme.night,
      labelBuilder: (theme) => theme.name,
    ),
    ObjectDropdownField<ZsAccentFamily>(
      name: 'accent',
      values: ZsAccentFamily.values,
      initialValue: ZsAccentFamily.multicolor,
      labelBuilder: (family) => family.name,
    ),
    BooleanField(name: 'contrast', initialValue: false),
    BooleanField(name: 'reduceMotion', initialValue: false),
    BooleanField(name: 'reduceTransparency', initialValue: false),
    BooleanField(name: 'inactive', initialValue: false),
  ];

  @override
  CatalogueAppearance valueFromQueryGroup(Map<String, String> group) => (
    theme: valueOf<ZsTheme>('theme', group) ?? ZsTheme.night,
    accent: valueOf<ZsAccentFamily>('accent', group) ?? ZsAccentFamily.multicolor,
    contrast: valueOf<bool>('contrast', group) ?? false,
    reduceMotion: valueOf<bool>('reduceMotion', group) ?? false,
    reduceTransparency: valueOf<bool>('reduceTransparency', group) ?? false,
    inactive: valueOf<bool>('inactive', group) ?? false,
  );

  @override
  Widget buildUseCase(BuildContext context, Widget child, CatalogueAppearance setting) => ZsAppearanceOverride(
    theme: setting.theme,
    family: setting.accent,
    increasedContrast: setting.contrast,
    reduceMotion: setting.reduceMotion,
    reduceTransparency: setting.reduceTransparency,
    inactive: setting.inactive,
    child: Builder(
      builder: (context) => ZsRoot(
        appearance: ZsAppearance.of(context),
        child: Builder(
          builder: (context) => ColoredBox(color: ZsColors.of(context).canvasBase, child: child),
        ),
      ),
    ),
  );
}
