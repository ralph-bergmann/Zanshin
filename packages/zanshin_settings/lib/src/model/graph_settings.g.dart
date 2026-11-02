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
        revsetConfigs: $checkedConvert(
          'revsetConfigs',
          (v) =>
              (v as List<dynamic>?)
                  ?.map(
                    (e) =>
                        RevsetConfiguration.fromJson(e as Map<String, dynamic>),
                  )
                  .toList() ??
              const <RevsetConfiguration>[],
        ),
        revsetDefault: $checkedConvert(
          'revsetDefault',
          (v) => v as String? ?? revsetDefaultLog,
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
      'revsetConfigs': instance.revsetConfigs.map((e) => e.toJson()).toList(),
      'revsetDefault': instance.revsetDefault,
    };

const _$GraphLayoutSettingEnumMap = {
  GraphLayoutSetting.free: 'free',
  GraphLayoutSetting.compact: 'compact',
};

_RevsetConfiguration _$RevsetConfigurationFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_RevsetConfiguration', json, ($checkedConvert) {
      final val = _RevsetConfiguration(
        id: $checkedConvert('id', (v) => v as String),
        name: $checkedConvert('name', (v) => v as String? ?? ''),
        op: $checkedConvert(
          'op',
          (v) =>
              $enumDecodeNullable(_$RevsetCombineEnumMap, v) ??
              RevsetCombine.and,
        ),
        rules: $checkedConvert(
          'rules',
          (v) =>
              (v as List<dynamic>?)
                  ?.map((e) => RevsetRule.fromJson(e as Map<String, dynamic>))
                  .toList() ??
              const <RevsetRule>[],
        ),
      );
      return val;
    });

Map<String, dynamic> _$RevsetConfigurationToJson(
  _RevsetConfiguration instance,
) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'op': _$RevsetCombineEnumMap[instance.op]!,
  'rules': instance.rules.map((e) => e.toJson()).toList(),
};

const _$RevsetCombineEnumMap = {
  RevsetCombine.and: 'and',
  RevsetCombine.or: 'or',
};

_RevsetRule _$RevsetRuleFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_RevsetRule', json, ($checkedConvert) {
      final val = _RevsetRule(
        fn: $checkedConvert(
          'fn',
          (v) => $enumDecode(_$RevsetRuleFunctionEnumMap, v),
        ),
        mode: $checkedConvert(
          'mode',
          (v) =>
              $enumDecodeNullable(_$RevsetRuleModeEnumMap, v) ??
              RevsetRuleMode.substring,
        ),
        value: $checkedConvert('value', (v) => v as String? ?? ''),
        ci: $checkedConvert('ci', (v) => v as bool? ?? false),
        not: $checkedConvert('not', (v) => v as bool? ?? false),
      );
      return val;
    });

Map<String, dynamic> _$RevsetRuleToJson(_RevsetRule instance) =>
    <String, dynamic>{
      'fn': _$RevsetRuleFunctionEnumMap[instance.fn]!,
      'mode': _$RevsetRuleModeEnumMap[instance.mode]!,
      'value': instance.value,
      'ci': instance.ci,
      'not': instance.not,
    };

const _$RevsetRuleFunctionEnumMap = {
  RevsetRuleFunction.author: 'author',
  RevsetRuleFunction.committer: 'committer',
  RevsetRuleFunction.mine: 'mine',
  RevsetRuleFunction.subject: 'subject',
  RevsetRuleFunction.description: 'description',
  RevsetRuleFunction.files: 'files',
  RevsetRuleFunction.revset: 'revset',
};

const _$RevsetRuleModeEnumMap = {
  RevsetRuleMode.substring: 'substring',
  RevsetRuleMode.exact: 'exact',
  RevsetRuleMode.glob: 'glob',
  RevsetRuleMode.regex: 'regex',
  RevsetRuleMode.prefix: 'prefix',
  RevsetRuleMode.file: 'file',
};
