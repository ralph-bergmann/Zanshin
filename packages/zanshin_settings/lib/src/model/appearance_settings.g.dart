// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'appearance_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AppearanceSettings _$AppearanceSettingsFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_AppearanceSettings', json, ($checkedConvert) {
      final val = _AppearanceSettings(
        themeMode: $checkedConvert(
          'themeMode',
          (v) => $enumDecodeNullable(_$ThemeModeEnumMap, v) ?? ThemeMode.system,
        ),
      );
      return val;
    });

Map<String, dynamic> _$AppearanceSettingsToJson(_AppearanceSettings instance) =>
    <String, dynamic>{'themeMode': _$ThemeModeEnumMap[instance.themeMode]!};

const _$ThemeModeEnumMap = {
  ThemeMode.system: 'system',
  ThemeMode.light: 'light',
  ThemeMode.dark: 'dark',
};
