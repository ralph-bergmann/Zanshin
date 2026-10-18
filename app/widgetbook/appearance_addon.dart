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
    _NamedDropdown<ZsTheme>(name: 'theme', label: 'Theme', values: ZsTheme.values, initialValue: ZsTheme.night),
    _NamedDropdown<ZsAccentFamily>(
      name: 'accent',
      label: 'Accent',
      values: ZsAccentFamily.values,
      initialValue: ZsAccentFamily.multicolor,
    ),
    _NamedSwitch(name: 'contrast', label: 'Increase contrast'),
    _NamedSwitch(name: 'reduceMotion', label: 'Reduce motion'),
    _NamedSwitch(name: 'reduceTransparency', label: 'Reduce transparency'),
    _NamedSwitch(name: 'inactive', label: 'Inactive window'),
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

/// A switch field with its name beside it. Widgetbook titles an addon, never its fields, so the addon's bare switches
/// did not say what they change (Ralph, 2026-10-18).
class _NamedSwitch extends BooleanField {
  _NamedSwitch({required super.name, required this.label}) : super(initialValue: false);

  /// The name shown beside the switch.
  final String label;

  @override
  Widget toWidget(BuildContext context, String group, bool? value) => Row(
    spacing: 12,
    children: <Widget>[
      super.toWidget(context, group, value),
      Flexible(child: Text(label)),
    ],
  );
}

/// A dropdown field of enum values, labelled by their names, with its name above it (see [_NamedSwitch]).
class _NamedDropdown<T extends Enum> extends ObjectDropdownField<T> {
  _NamedDropdown({required super.name, required this.label, required super.values, required super.initialValue})
    : super(labelBuilder: (value) => value.name);

  /// The name shown above the dropdown.
  final String label;

  @override
  Widget toWidget(BuildContext context, String group, T? value) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 6,
    children: <Widget>[Text(label), super.toWidget(context, group, value)],
  );
}
