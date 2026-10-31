// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'app_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$AppSettings {

/// Look-and-feel settings.
 AppearanceSettings get appearance;/// The project window's remembered island widths.
 LayoutSettings get layout;/// Settings › General.
 GeneralSettings get general;/// The project registry (Story 11.5).
 ProjectsSettings get projects;/// The graph's View options (Story 10.7).
 GraphSettings get graph;
/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppSettingsCopyWith<AppSettings> get copyWith => _$AppSettingsCopyWithImpl<AppSettings>(this as AppSettings, _$identity);

  /// Serializes this AppSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as AppSettings;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppSettings&&(identical(other.appearance, _this.appearance) || other.appearance == _this.appearance)&&(identical(other.layout, _this.layout) || other.layout == _this.layout)&&(identical(other.general, _this.general) || other.general == _this.general)&&(identical(other.projects, _this.projects) || other.projects == _this.projects)&&(identical(other.graph, _this.graph) || other.graph == _this.graph));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as AppSettings;
  return Object.hash(runtimeType,_this.appearance,_this.layout,_this.general,_this.projects,_this.graph);
}

@override
String toString() {
  final _this = this as AppSettings;
  return 'AppSettings(appearance: ${_this.appearance}, layout: ${_this.layout}, general: ${_this.general}, projects: ${_this.projects}, graph: ${_this.graph})';
}


}

/// @nodoc
abstract mixin class $AppSettingsCopyWith<$Res>  {
  factory $AppSettingsCopyWith(AppSettings value, $Res Function(AppSettings) _then) = _$AppSettingsCopyWithImpl;
@useResult
$Res call({
 AppearanceSettings appearance, LayoutSettings layout, GeneralSettings general, ProjectsSettings projects, GraphSettings graph
});


$AppearanceSettingsCopyWith<$Res> get appearance;$LayoutSettingsCopyWith<$Res> get layout;$GeneralSettingsCopyWith<$Res> get general;$ProjectsSettingsCopyWith<$Res> get projects;$GraphSettingsCopyWith<$Res> get graph;

}
/// @nodoc
class _$AppSettingsCopyWithImpl<$Res>
    implements $AppSettingsCopyWith<$Res> {
  _$AppSettingsCopyWithImpl(this._self, this._then);

  final AppSettings _self;
  final $Res Function(AppSettings) _then;

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? appearance = null,Object? layout = null,Object? general = null,Object? projects = null,Object? graph = null,}) {
  return _then(AppSettings(
appearance: null == appearance ? _self.appearance : appearance // ignore: cast_nullable_to_non_nullable
as AppearanceSettings,layout: null == layout ? _self.layout : layout // ignore: cast_nullable_to_non_nullable
as LayoutSettings,general: null == general ? _self.general : general // ignore: cast_nullable_to_non_nullable
as GeneralSettings,projects: null == projects ? _self.projects : projects // ignore: cast_nullable_to_non_nullable
as ProjectsSettings,graph: null == graph ? _self.graph : graph // ignore: cast_nullable_to_non_nullable
as GraphSettings,
  ));
}
/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AppearanceSettingsCopyWith<$Res> get appearance {
  
  return $AppearanceSettingsCopyWith<$Res>(_self.appearance, (value) {
    return _then(_self.copyWith(appearance: value));
  });
}/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$LayoutSettingsCopyWith<$Res> get layout {
  
  return $LayoutSettingsCopyWith<$Res>(_self.layout, (value) {
    return _then(_self.copyWith(layout: value));
  });
}/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$GeneralSettingsCopyWith<$Res> get general {
  
  return $GeneralSettingsCopyWith<$Res>(_self.general, (value) {
    return _then(_self.copyWith(general: value));
  });
}/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ProjectsSettingsCopyWith<$Res> get projects {
  
  return $ProjectsSettingsCopyWith<$Res>(_self.projects, (value) {
    return _then(_self.copyWith(projects: value));
  });
}/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$GraphSettingsCopyWith<$Res> get graph {
  
  return $GraphSettingsCopyWith<$Res>(_self.graph, (value) {
    return _then(_self.copyWith(graph: value));
  });
}
}


/// Adds pattern-matching-related methods to [AppSettings].
extension AppSettingsPatterns on AppSettings {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AppSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AppSettings value)  $default,){
final _that = this;
switch (_that) {
case _AppSettings():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AppSettings value)?  $default,){
final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( AppearanceSettings appearance,  LayoutSettings layout,  GeneralSettings general,  ProjectsSettings projects,  GraphSettings graph)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that.appearance,_that.layout,_that.general,_that.projects,_that.graph);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( AppearanceSettings appearance,  LayoutSettings layout,  GeneralSettings general,  ProjectsSettings projects,  GraphSettings graph)  $default,) {final _that = this;
switch (_that) {
case _AppSettings():
return $default(_that.appearance,_that.layout,_that.general,_that.projects,_that.graph);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( AppearanceSettings appearance,  LayoutSettings layout,  GeneralSettings general,  ProjectsSettings projects,  GraphSettings graph)?  $default,) {final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that.appearance,_that.layout,_that.general,_that.projects,_that.graph);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AppSettings implements AppSettings {
  const _AppSettings({this.appearance = const AppearanceSettings(), this.layout = const LayoutSettings(), this.general = const GeneralSettings(), this.projects = const ProjectsSettings(), this.graph = const GraphSettings()});
  factory _AppSettings.fromJson(Map<String, dynamic> json) => _$AppSettingsFromJson(json);

/// Look-and-feel settings.
@override@JsonKey() final  AppearanceSettings appearance;
/// The project window's remembered island widths.
@override@JsonKey() final  LayoutSettings layout;
/// Settings › General.
@override@JsonKey() final  GeneralSettings general;
/// The project registry (Story 11.5).
@override@JsonKey() final  ProjectsSettings projects;
/// The graph's View options (Story 10.7).
@override@JsonKey() final  GraphSettings graph;

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppSettingsCopyWith<_AppSettings> get copyWith => __$AppSettingsCopyWithImpl<_AppSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AppSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppSettings&&(identical(other.appearance, appearance) || other.appearance == appearance)&&(identical(other.layout, layout) || other.layout == layout)&&(identical(other.general, general) || other.general == general)&&(identical(other.projects, projects) || other.projects == projects)&&(identical(other.graph, graph) || other.graph == graph));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,appearance,layout,general,projects,graph);
}

@override
String toString() {
    return 'AppSettings(appearance: $appearance, layout: $layout, general: $general, projects: $projects, graph: $graph)';
}


}

/// @nodoc
abstract mixin class _$AppSettingsCopyWith<$Res> implements $AppSettingsCopyWith<$Res> {
  factory _$AppSettingsCopyWith(_AppSettings value, $Res Function(_AppSettings) _then) = __$AppSettingsCopyWithImpl;
@override @useResult
$Res call({
 AppearanceSettings appearance, LayoutSettings layout, GeneralSettings general, ProjectsSettings projects, GraphSettings graph
});


@override $AppearanceSettingsCopyWith<$Res> get appearance;@override $LayoutSettingsCopyWith<$Res> get layout;@override $GeneralSettingsCopyWith<$Res> get general;@override $ProjectsSettingsCopyWith<$Res> get projects;@override $GraphSettingsCopyWith<$Res> get graph;

}
/// @nodoc
class __$AppSettingsCopyWithImpl<$Res>
    implements _$AppSettingsCopyWith<$Res> {
  __$AppSettingsCopyWithImpl(this._self, this._then);

  final _AppSettings _self;
  final $Res Function(_AppSettings) _then;

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? appearance = null,Object? layout = null,Object? general = null,Object? projects = null,Object? graph = null,}) {
  return _then(_AppSettings(
appearance: null == appearance ? _self.appearance : appearance // ignore: cast_nullable_to_non_nullable
as AppearanceSettings,layout: null == layout ? _self.layout : layout // ignore: cast_nullable_to_non_nullable
as LayoutSettings,general: null == general ? _self.general : general // ignore: cast_nullable_to_non_nullable
as GeneralSettings,projects: null == projects ? _self.projects : projects // ignore: cast_nullable_to_non_nullable
as ProjectsSettings,graph: null == graph ? _self.graph : graph // ignore: cast_nullable_to_non_nullable
as GraphSettings,
  ));
}

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AppearanceSettingsCopyWith<$Res> get appearance {
  
  return $AppearanceSettingsCopyWith<$Res>(_self.appearance, (value) {
    return _then(_self.copyWith(appearance: value));
  });
}/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$LayoutSettingsCopyWith<$Res> get layout {
  
  return $LayoutSettingsCopyWith<$Res>(_self.layout, (value) {
    return _then(_self.copyWith(layout: value));
  });
}/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$GeneralSettingsCopyWith<$Res> get general {
  
  return $GeneralSettingsCopyWith<$Res>(_self.general, (value) {
    return _then(_self.copyWith(general: value));
  });
}/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ProjectsSettingsCopyWith<$Res> get projects {
  
  return $ProjectsSettingsCopyWith<$Res>(_self.projects, (value) {
    return _then(_self.copyWith(projects: value));
  });
}/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$GraphSettingsCopyWith<$Res> get graph {
  
  return $GraphSettingsCopyWith<$Res>(_self.graph, (value) {
    return _then(_self.copyWith(graph: value));
  });
}
}

// dart format on
