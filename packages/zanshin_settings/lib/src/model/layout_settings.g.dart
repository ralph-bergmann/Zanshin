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
      );
      return val;
    });

Map<String, dynamic> _$LayoutSettingsToJson(_LayoutSettings instance) =>
    <String, dynamic>{
      'inspectorWidth': instance.inspectorWidth,
      'panelWidth': instance.panelWidth,
    };
