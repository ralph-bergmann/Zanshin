// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'general_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_GeneralSettings _$GeneralSettingsFromJson(
  Map<String, dynamic> json,
) => $checkedCreate('_GeneralSettings', json, ($checkedConvert) {
  final val = _GeneralSettings(
    hideControls: $checkedConvert('hideControls', (v) => v as bool? ?? true),
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
    diffWordMarks: $checkedConvert('diffWordMarks', (v) => v as bool? ?? true),
    diffWhitespace: $checkedConvert(
      'diffWhitespace',
      (v) =>
          $enumDecodeNullable(
            _$DiffWhitespaceSettingEnumMap,
            v,
            unknownValue: DiffWhitespaceSetting.showAll,
          ) ??
          DiffWhitespaceSetting.showAll,
    ),
    diffFileList: $checkedConvert(
      'diffFileList',
      (v) =>
          $enumDecodeNullable(
            _$DiffFileListSettingEnumMap,
            v,
            unknownValue: DiffFileListSetting.flat,
          ) ??
          DiffFileListSetting.flat,
    ),
    editor: $checkedConvert('editor', (v) => v as String?),
    fileMasks: $checkedConvert(
      'fileMasks',
      (v) =>
          (v as List<dynamic>?)
              ?.map((e) => FileMask.fromJson(e as Map<String, dynamic>))
              .toList() ??
          defaultFileMasks,
    ),
  );
  return val;
});

Map<String, dynamic> _$GeneralSettingsToJson(
  _GeneralSettings instance,
) => <String, dynamic>{
  'hideControls': instance.hideControls,
  'diffLayout': _$DiffLayoutSettingEnumMap[instance.diffLayout]!,
  'diffWordMarks': instance.diffWordMarks,
  'diffWhitespace': _$DiffWhitespaceSettingEnumMap[instance.diffWhitespace]!,
  'diffFileList': _$DiffFileListSettingEnumMap[instance.diffFileList]!,
  'editor': instance.editor,
  'fileMasks': instance.fileMasks.map((e) => e.toJson()).toList(),
};

const _$DiffLayoutSettingEnumMap = {
  DiffLayoutSetting.unified: 'unified',
  DiffLayoutSetting.sideBySide: 'sideBySide',
};

const _$DiffWhitespaceSettingEnumMap = {
  DiffWhitespaceSetting.showAll: 'showAll',
  DiffWhitespaceSetting.ignoreChangesInAmount: 'ignoreChangesInAmount',
  DiffWhitespaceSetting.ignoreAll: 'ignoreAll',
};

const _$DiffFileListSettingEnumMap = {
  DiffFileListSetting.flat: 'flat',
  DiffFileListSetting.tree: 'tree',
};

_FileMask _$FileMaskFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_FileMask', json, ($checkedConvert) {
      final val = _FileMask(
        mask: $checkedConvert('mask', (v) => v as String),
        active: $checkedConvert('active', (v) => v as bool? ?? false),
      );
      return val;
    });

Map<String, dynamic> _$FileMaskToJson(_FileMask instance) => <String, dynamic>{
  'mask': instance.mask,
  'active': instance.active,
};
