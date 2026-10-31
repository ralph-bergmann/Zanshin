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
        layout: $checkedConvert(
          'layout',
          (v) => v == null
              ? const LayoutSettings()
              : LayoutSettings.fromJson(v as Map<String, dynamic>),
        ),
        general: $checkedConvert(
          'general',
          (v) => v == null
              ? const GeneralSettings()
              : GeneralSettings.fromJson(v as Map<String, dynamic>),
        ),
        projects: $checkedConvert(
          'projects',
          (v) => v == null
              ? const ProjectsSettings()
              : ProjectsSettings.fromJson(v as Map<String, dynamic>),
        ),
        graph: $checkedConvert(
          'graph',
          (v) => v == null
              ? const GraphSettings()
              : GraphSettings.fromJson(v as Map<String, dynamic>),
        ),
      );
      return val;
    });

Map<String, dynamic> _$AppSettingsToJson(_AppSettings instance) =>
    <String, dynamic>{
      'appearance': instance.appearance.toJson(),
      'layout': instance.layout.toJson(),
      'general': instance.general.toJson(),
      'projects': instance.projects.toJson(),
      'graph': instance.graph.toJson(),
    };
