// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'app_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AppSettings _$AppSettingsFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_AppSettings', json, ($checkedConvert) {
      final val = _AppSettings(
        appearance: $checkedConvert(
          'appearance',
          (v) => v == null
              ? const AppearanceSettings()
              : AppearanceSettings.fromJson(v as Map<String, dynamic>),
        ),
      );
      return val;
    });

Map<String, dynamic> _$AppSettingsToJson(_AppSettings instance) =>
    <String, dynamic>{'appearance': instance.appearance.toJson()};
