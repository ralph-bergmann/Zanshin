// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'graph_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_GraphSettings _$GraphSettingsFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_GraphSettings', json, ($checkedConvert) {
      final val = _GraphSettings(
        layout: $checkedConvert(
          'layout',
          (v) =>
              $enumDecodeNullable(_$GraphLayoutSettingEnumMap, v) ??
              GraphLayoutSetting.free,
        ),
        detailedCards: $checkedConvert(
          'detailedCards',
          (v) => v as bool? ?? true,
        ),
        groupStacks: $checkedConvert('groupStacks', (v) => v as bool? ?? true),
        cardWidth: $checkedConvert(
          'cardWidth',
          (v) => (v as num?)?.toDouble() ?? 240,
        ),
      );
      return val;
    });

Map<String, dynamic> _$GraphSettingsToJson(_GraphSettings instance) =>
    <String, dynamic>{
      'layout': _$GraphLayoutSettingEnumMap[instance.layout]!,
      'detailedCards': instance.detailedCards,
      'groupStacks': instance.groupStacks,
      'cardWidth': instance.cardWidth,
    };

const _$GraphLayoutSettingEnumMap = {
  GraphLayoutSetting.free: 'free',
  GraphLayoutSetting.compact: 'compact',
};
