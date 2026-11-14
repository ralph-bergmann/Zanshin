// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'layout_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_LayoutSettings _$LayoutSettingsFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_LayoutSettings', json, ($checkedConvert) {
      final val = _LayoutSettings(
        inspectorWidth: $checkedConvert(
          'inspectorWidth',
          (v) => (v as num?)?.toDouble() ?? 460,
        ),
        panelWidth: $checkedConvert(
          'panelWidth',
          (v) => (v as num?)?.toDouble() ?? 300,
        ),
        inspectorFilesNarrow: $checkedConvert(
          'inspectorFilesNarrow',
          (v) => (v as num?)?.toDouble() ?? 0.38,
        ),
        inspectorFilesWide: $checkedConvert(
          'inspectorFilesWide',
          (v) => (v as num?)?.toDouble() ?? 0.34,
        ),
      );
      return val;
    });

Map<String, dynamic> _$LayoutSettingsToJson(_LayoutSettings instance) =>
    <String, dynamic>{
      'inspectorWidth': instance.inspectorWidth,
      'panelWidth': instance.panelWidth,
      'inspectorFilesNarrow': instance.inspectorFilesNarrow,
      'inspectorFilesWide': instance.inspectorFilesWide,
    };
