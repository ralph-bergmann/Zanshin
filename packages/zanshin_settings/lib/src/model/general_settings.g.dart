// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'general_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_GeneralSettings _$GeneralSettingsFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_GeneralSettings', json, ($checkedConvert) {
      final val = _GeneralSettings(
        hideControls: $checkedConvert(
          'hideControls',
          (v) => v as bool? ?? true,
        ),
      );
      return val;
    });

Map<String, dynamic> _$GeneralSettingsToJson(_GeneralSettings instance) =>
    <String, dynamic>{'hideControls': instance.hideControls};
