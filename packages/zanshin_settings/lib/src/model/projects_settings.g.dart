// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'projects_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ProjectsSettings _$ProjectsSettingsFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_ProjectsSettings', json, ($checkedConvert) {
      final val = _ProjectsSettings(
        projects: $checkedConvert(
          'projects',
          (v) =>
              (v as List<dynamic>?)
                  ?.map((e) => ProjectEntry.fromJson(e as Map<String, dynamic>))
                  .toList() ??
              const <ProjectEntry>[],
        ),
        groups: $checkedConvert(
          'groups',
          (v) =>
              (v as List<dynamic>?)
                  ?.map((e) => ProjectGroup.fromJson(e as Map<String, dynamic>))
                  .toList() ??
              const <ProjectGroup>[],
        ),
        openProject: $checkedConvert('openProject', (v) => v as String?),
      );
      return val;
    });

Map<String, dynamic> _$ProjectsSettingsToJson(_ProjectsSettings instance) =>
    <String, dynamic>{
      'projects': instance.projects.map((e) => e.toJson()).toList(),
      'groups': instance.groups.map((e) => e.toJson()).toList(),
      'openProject': instance.openProject,
    };

_ProjectEntry _$ProjectEntryFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_ProjectEntry', json, ($checkedConvert) {
      final val = _ProjectEntry(
        path: $checkedConvert('path', (v) => v as String),
        name: $checkedConvert('name', (v) => v as String),
        group: $checkedConvert('group', (v) => v as String?),
        order: $checkedConvert('order', (v) => (v as num?)?.toInt() ?? 0),
        lastOpened: $checkedConvert(
          'lastOpened',
          (v) => v == null ? null : DateTime.parse(v as String),
        ),
        status: $checkedConvert(
          'status',
          (v) => $enumDecodeNullable(
            _$ProjectStatusEnumMap,
            v,
            unknownValue: JsonKey.nullForUndefinedEnumValue,
          ),
        ),
        bookmark: $checkedConvert('bookmark', (v) => v as String?),
      );
      return val;
    });

Map<String, dynamic> _$ProjectEntryToJson(_ProjectEntry instance) =>
    <String, dynamic>{
      'path': instance.path,
      'name': instance.name,
      'group': instance.group,
      'order': instance.order,
      'lastOpened': instance.lastOpened?.toIso8601String(),
      'status': _$ProjectStatusEnumMap[instance.status],
      'bookmark': instance.bookmark,
    };

const _$ProjectStatusEnumMap = {
  ProjectStatus.clean: 'clean',
  ProjectStatus.dirty: 'dirty',
  ProjectStatus.conflict: 'conflict',
  ProjectStatus.missing: 'missing',
  ProjectStatus.stale: 'stale',
  ProjectStatus.ahead: 'ahead',
  ProjectStatus.behind: 'behind',
  ProjectStatus.diverged: 'diverged',
};

_ProjectGroup _$ProjectGroupFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_ProjectGroup', json, ($checkedConvert) {
      final val = _ProjectGroup(
        id: $checkedConvert('id', (v) => v as String),
        name: $checkedConvert('name', (v) => v as String),
        parent: $checkedConvert('parent', (v) => v as String?),
        order: $checkedConvert('order', (v) => (v as num?)?.toInt() ?? 0),
      );
      return val;
    });

Map<String, dynamic> _$ProjectGroupToJson(_ProjectGroup instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'parent': instance.parent,
      'order': instance.order,
    };
