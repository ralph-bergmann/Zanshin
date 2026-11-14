// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'project_state.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ProjectState _$ProjectStateFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_ProjectState', json, ($checkedConvert) {
      final val = _ProjectState(
        viewedFiles: $checkedConvert(
          'viewedFiles',
          (v) =>
              (v as List<dynamic>?)?.map((e) => e as String).toList() ??
              const <String>[],
        ),
        expandedStacks: $checkedConvert(
          'expandedStacks',
          (v) =>
              (v as List<dynamic>?)?.map((e) => e as String).toList() ??
              const <String>[],
        ),
        collapsedStacks: $checkedConvert(
          'collapsedStacks',
          (v) =>
              (v as List<dynamic>?)?.map((e) => e as String).toList() ??
              const <String>[],
        ),
      );
      return val;
    });

Map<String, dynamic> _$ProjectStateToJson(_ProjectState instance) =>
    <String, dynamic>{
      'viewedFiles': instance.viewedFiles,
      'expandedStacks': instance.expandedStacks,
      'collapsedStacks': instance.collapsedStacks,
    };
