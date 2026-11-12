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
        diffLayout: $checkedConvert(
          'diffLayout',
          (v) =>
              $enumDecodeNullable(
                _$DiffLayoutSettingEnumMap,
                v,
                unknownValue: DiffLayoutSetting.unified,
              ) ??
              DiffLayoutSetting.unified,
        ),
        diffMarks: $checkedConvert(
          'diffMarks',
          (v) =>
              $enumDecodeNullable(
                _$DiffMarksSettingEnumMap,
                v,
                unknownValue: DiffMarksSetting.words,
              ) ??
              DiffMarksSetting.words,
        ),
      );
      return val;
    });

Map<String, dynamic> _$GeneralSettingsToJson(_GeneralSettings instance) =>
    <String, dynamic>{
      'hideControls': instance.hideControls,
      'diffLayout': _$DiffLayoutSettingEnumMap[instance.diffLayout]!,
      'diffMarks': _$DiffMarksSettingEnumMap[instance.diffMarks]!,
    };

const _$DiffLayoutSettingEnumMap = {
  DiffLayoutSetting.unified: 'unified',
  DiffLayoutSetting.sideBySide: 'sideBySide',
};

const _$DiffMarksSettingEnumMap = {
  DiffMarksSetting.words: 'words',
  DiffMarksSetting.jj: 'jj',
};
