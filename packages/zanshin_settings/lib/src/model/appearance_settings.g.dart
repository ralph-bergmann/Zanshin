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
        accentSource: $checkedConvert(
          'accentSource',
          (v) =>
              $enumDecodeNullable(_$AccentSourceEnumMap, v) ??
              AccentSource.followMacOS,
        ),
      );
      return val;
    });

Map<String, dynamic> _$AppearanceSettingsToJson(_AppearanceSettings instance) =>
    <String, dynamic>{
      'themeMode': _$ThemeModeEnumMap[instance.themeMode]!,
      'accentSource': _$AccentSourceEnumMap[instance.accentSource]!,
    };

const _$ThemeModeEnumMap = {
  ThemeMode.system: 'system',
  ThemeMode.light: 'light',
  ThemeMode.dark: 'dark',
};

const _$AccentSourceEnumMap = {
  AccentSource.followMacOS: 'followMacOS',
  AccentSource.zanshin: 'zanshin',
};
