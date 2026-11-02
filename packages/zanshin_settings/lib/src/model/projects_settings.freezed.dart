// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'projects_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ProjectsSettings {

/// The registered projects, keyed by [ProjectEntry.path].
 List<ProjectEntry> get projects;/// The groups, keyed by [ProjectGroup.id].
 List<ProjectGroup> get groups;/// The path of the project the project window shows, or null when none is open; launch reopens it. A launch
/// whose open failed keeps it, so the next launch tries again; one that finds no jj workspace there clears it.
 String? get openProject;
/// Create a copy of ProjectsSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProjectsSettingsCopyWith<ProjectsSettings> get copyWith => _$ProjectsSettingsCopyWithImpl<ProjectsSettings>(this as ProjectsSettings, _$identity);

  /// Serializes this ProjectsSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as ProjectsSettings;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProjectsSettings&&const DeepCollectionEquality().equals(other.projects, _this.projects)&&const DeepCollectionEquality().equals(other.groups, _this.groups)&&(identical(other.openProject, _this.openProject) || other.openProject == _this.openProject));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as ProjectsSettings;
  return Object.hash(runtimeType,const DeepCollectionEquality().hash(_this.projects),const DeepCollectionEquality().hash(_this.groups),_this.openProject);
}

@override
String toString() {
  final _this = this as ProjectsSettings;
  return 'ProjectsSettings(projects: ${_this.projects}, groups: ${_this.groups}, openProject: ${_this.openProject})';
}


}

/// @nodoc
abstract mixin class $ProjectsSettingsCopyWith<$Res>  {
  factory $ProjectsSettingsCopyWith(ProjectsSettings value, $Res Function(ProjectsSettings) _then) = _$ProjectsSettingsCopyWithImpl;
@useResult
$Res call({
 List<ProjectEntry> projects, List<ProjectGroup> groups, String? openProject
});




}
/// @nodoc
class _$ProjectsSettingsCopyWithImpl<$Res>
    implements $ProjectsSettingsCopyWith<$Res> {
  _$ProjectsSettingsCopyWithImpl(this._self, this._then);

  final ProjectsSettings _self;
  final $Res Function(ProjectsSettings) _then;

/// Create a copy of ProjectsSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? projects = null,Object? groups = null,Object? openProject = freezed,}) {
  return _then(ProjectsSettings(
projects: null == projects ? _self.projects : projects // ignore: cast_nullable_to_non_nullable
as List<ProjectEntry>,groups: null == groups ? _self.groups : groups // ignore: cast_nullable_to_non_nullable
as List<ProjectGroup>,openProject: freezed == openProject ? _self.openProject : openProject // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ProjectsSettings].
extension ProjectsSettingsPatterns on ProjectsSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ProjectsSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ProjectsSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ProjectsSettings value)  $default,){
final _that = this;
switch (_that) {
case _ProjectsSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ProjectsSettings value)?  $default,){
final _that = this;
switch (_that) {
case _ProjectsSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<ProjectEntry> projects,  List<ProjectGroup> groups,  String? openProject)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ProjectsSettings() when $default != null:
return $default(_that.projects,_that.groups,_that.openProject);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<ProjectEntry> projects,  List<ProjectGroup> groups,  String? openProject)  $default,) {final _that = this;
switch (_that) {
case _ProjectsSettings():
return $default(_that.projects,_that.groups,_that.openProject);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<ProjectEntry> projects,  List<ProjectGroup> groups,  String? openProject)?  $default,) {final _that = this;
switch (_that) {
case _ProjectsSettings() when $default != null:
return $default(_that.projects,_that.groups,_that.openProject);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ProjectsSettings implements ProjectsSettings {
  const _ProjectsSettings({ List<ProjectEntry> projects = const <ProjectEntry>[],  List<ProjectGroup> groups = const <ProjectGroup>[], this.openProject}): _projects = projects,_groups = groups;
  factory _ProjectsSettings.fromJson(Map<String, dynamic> json) => _$ProjectsSettingsFromJson(json);

/// The registered projects, keyed by [ProjectEntry.path].
 final  List<ProjectEntry> _projects;
/// The registered projects, keyed by [ProjectEntry.path].
@override@JsonKey() List<ProjectEntry> get projects {
  if (_projects is EqualUnmodifiableListView) return _projects;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_projects);
}

/// The groups, keyed by [ProjectGroup.id].
 final  List<ProjectGroup> _groups;
/// The groups, keyed by [ProjectGroup.id].
@override@JsonKey() List<ProjectGroup> get groups {
  if (_groups is EqualUnmodifiableListView) return _groups;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_groups);
}

/// The path of the project the project window shows, or null when none is open; launch reopens it. A launch
/// whose open failed keeps it, so the next launch tries again; one that finds no jj workspace there clears it.
@override final  String? openProject;

/// Create a copy of ProjectsSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProjectsSettingsCopyWith<_ProjectsSettings> get copyWith => __$ProjectsSettingsCopyWithImpl<_ProjectsSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ProjectsSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ProjectsSettings&&const DeepCollectionEquality().equals(other.projects, _projects)&&const DeepCollectionEquality().equals(other.groups, _groups)&&(identical(other.openProject, openProject) || other.openProject == openProject));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(_projects),const DeepCollectionEquality().hash(_groups),openProject);
}

@override
String toString() {
    return 'ProjectsSettings(projects: $projects, groups: $groups, openProject: $openProject)';
}


}

/// @nodoc
abstract mixin class _$ProjectsSettingsCopyWith<$Res> implements $ProjectsSettingsCopyWith<$Res> {
  factory _$ProjectsSettingsCopyWith(_ProjectsSettings value, $Res Function(_ProjectsSettings) _then) = __$ProjectsSettingsCopyWithImpl;
@override @useResult
$Res call({
 List<ProjectEntry> projects, List<ProjectGroup> groups, String? openProject
});




}
/// @nodoc
class __$ProjectsSettingsCopyWithImpl<$Res>
    implements _$ProjectsSettingsCopyWith<$Res> {
  __$ProjectsSettingsCopyWithImpl(this._self, this._then);

  final _ProjectsSettings _self;
  final $Res Function(_ProjectsSettings) _then;

/// Create a copy of ProjectsSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? projects = null,Object? groups = null,Object? openProject = freezed,}) {
  return _then(_ProjectsSettings(
projects: null == projects ? _self._projects : projects // ignore: cast_nullable_to_non_nullable
as List<ProjectEntry>,groups: null == groups ? _self._groups : groups // ignore: cast_nullable_to_non_nullable
as List<ProjectGroup>,openProject: freezed == openProject ? _self.openProject : openProject // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$ProjectEntry {

/// The workspace's root directory, absolute; the registry's key.
 String get path;/// The name the capsule, the Project menu and the Projects window show.
 String get name;/// The [ProjectGroup.id] of its group, or null at the top level.
 String? get group;/// Its position among its siblings (the groups and projects of the same parent), from 0.
 int get order;/// When it was last opened (UTC), or null when it never was; the Project menu's Recent sorts by it.
 DateTime? get lastOpened;/// Its last known state, written after every reading of the open project and when a switch or a close leaves
/// it (item 7), or null before the first. A value this version does not know reads as null (Story 11.5: a newer
/// file never breaks an older app's settings).
@JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue) ProjectStatus? get status;/// Its last known bookmark label — the first by name of the local bookmarks on @'s closest bookmarked ancestor
/// (design question (b)) — or null when there was none ("—").
 String? get bookmark;/// The graph's stacks the user expanded, by their run's oldest member key (Story 10.17).
 List<String> get expandedStacks;/// The graph's stacks the user collapsed, by their run's oldest member key (Story 10.17).
 List<String> get collapsedStacks;/// What the graph shows, as the search's JSON text (Story 10.21), or null for the default search.
 String? get graphView;/// The graph search's recent go-tos and filters, newest first, each as its JSON text (Story 10.21).
 List<String> get recentSearches;/// The inspector's Viewed marks, each `<change id>:<fingerprint>:<path>`, oldest first (Story 10.24).
 List<String> get viewedFiles;/// Settings › Project's "Check for remote changes" (Story 11.7; 11.8's poll reads it); every 15 minutes by
/// default, and for a value this version does not know.
@JsonKey(unknownEnumValue: RemotePollSetting.fifteenMinutes) RemotePollSetting get remotePoll;
/// Create a copy of ProjectEntry
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProjectEntryCopyWith<ProjectEntry> get copyWith => _$ProjectEntryCopyWithImpl<ProjectEntry>(this as ProjectEntry, _$identity);

  /// Serializes this ProjectEntry to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as ProjectEntry;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProjectEntry&&(identical(other.path, _this.path) || other.path == _this.path)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.group, _this.group) || other.group == _this.group)&&(identical(other.order, _this.order) || other.order == _this.order)&&(identical(other.lastOpened, _this.lastOpened) || other.lastOpened == _this.lastOpened)&&(identical(other.status, _this.status) || other.status == _this.status)&&(identical(other.bookmark, _this.bookmark) || other.bookmark == _this.bookmark)&&const DeepCollectionEquality().equals(other.expandedStacks, _this.expandedStacks)&&const DeepCollectionEquality().equals(other.collapsedStacks, _this.collapsedStacks)&&(identical(other.graphView, _this.graphView) || other.graphView == _this.graphView)&&const DeepCollectionEquality().equals(other.recentSearches, _this.recentSearches)&&const DeepCollectionEquality().equals(other.viewedFiles, _this.viewedFiles)&&(identical(other.remotePoll, _this.remotePoll) || other.remotePoll == _this.remotePoll));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as ProjectEntry;
  return Object.hash(runtimeType,_this.path,_this.name,_this.group,_this.order,_this.lastOpened,_this.status,_this.bookmark,const DeepCollectionEquality().hash(_this.expandedStacks),const DeepCollectionEquality().hash(_this.collapsedStacks),_this.graphView,const DeepCollectionEquality().hash(_this.recentSearches),const DeepCollectionEquality().hash(_this.viewedFiles),_this.remotePoll);
}

@override
String toString() {
  final _this = this as ProjectEntry;
  return 'ProjectEntry(path: ${_this.path}, name: ${_this.name}, group: ${_this.group}, order: ${_this.order}, lastOpened: ${_this.lastOpened}, status: ${_this.status}, bookmark: ${_this.bookmark}, expandedStacks: ${_this.expandedStacks}, collapsedStacks: ${_this.collapsedStacks}, graphView: ${_this.graphView}, recentSearches: ${_this.recentSearches}, viewedFiles: ${_this.viewedFiles}, remotePoll: ${_this.remotePoll})';
}


}

/// @nodoc
abstract mixin class $ProjectEntryCopyWith<$Res>  {
  factory $ProjectEntryCopyWith(ProjectEntry value, $Res Function(ProjectEntry) _then) = _$ProjectEntryCopyWithImpl;
@useResult
$Res call({
 String path, String name, String? group, int order, DateTime? lastOpened,@JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue) ProjectStatus? status, String? bookmark, List<String> expandedStacks, List<String> collapsedStacks, String? graphView, List<String> recentSearches, List<String> viewedFiles,@JsonKey(unknownEnumValue: RemotePollSetting.fifteenMinutes) RemotePollSetting remotePoll
});




}
/// @nodoc
class _$ProjectEntryCopyWithImpl<$Res>
    implements $ProjectEntryCopyWith<$Res> {
  _$ProjectEntryCopyWithImpl(this._self, this._then);

  final ProjectEntry _self;
  final $Res Function(ProjectEntry) _then;

/// Create a copy of ProjectEntry
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? path = null,Object? name = null,Object? group = freezed,Object? order = null,Object? lastOpened = freezed,Object? status = freezed,Object? bookmark = freezed,Object? expandedStacks = null,Object? collapsedStacks = null,Object? graphView = freezed,Object? recentSearches = null,Object? viewedFiles = null,Object? remotePoll = null,}) {
  return _then(ProjectEntry(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,group: freezed == group ? _self.group : group // ignore: cast_nullable_to_non_nullable
as String?,order: null == order ? _self.order : order // ignore: cast_nullable_to_non_nullable
as int,lastOpened: freezed == lastOpened ? _self.lastOpened : lastOpened // ignore: cast_nullable_to_non_nullable
as DateTime?,status: freezed == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ProjectStatus?,bookmark: freezed == bookmark ? _self.bookmark : bookmark // ignore: cast_nullable_to_non_nullable
as String?,expandedStacks: null == expandedStacks ? _self.expandedStacks : expandedStacks // ignore: cast_nullable_to_non_nullable
as List<String>,collapsedStacks: null == collapsedStacks ? _self.collapsedStacks : collapsedStacks // ignore: cast_nullable_to_non_nullable
as List<String>,graphView: freezed == graphView ? _self.graphView : graphView // ignore: cast_nullable_to_non_nullable
as String?,recentSearches: null == recentSearches ? _self.recentSearches : recentSearches // ignore: cast_nullable_to_non_nullable
as List<String>,viewedFiles: null == viewedFiles ? _self.viewedFiles : viewedFiles // ignore: cast_nullable_to_non_nullable
as List<String>,remotePoll: null == remotePoll ? _self.remotePoll : remotePoll // ignore: cast_nullable_to_non_nullable
as RemotePollSetting,
  ));
}

}


/// Adds pattern-matching-related methods to [ProjectEntry].
extension ProjectEntryPatterns on ProjectEntry {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ProjectEntry value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ProjectEntry() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ProjectEntry value)  $default,){
final _that = this;
switch (_that) {
case _ProjectEntry():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ProjectEntry value)?  $default,){
final _that = this;
switch (_that) {
case _ProjectEntry() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String path,  String name,  String? group,  int order,  DateTime? lastOpened, @JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue)  ProjectStatus? status,  String? bookmark,  List<String> expandedStacks,  List<String> collapsedStacks,  String? graphView,  List<String> recentSearches,  List<String> viewedFiles, @JsonKey(unknownEnumValue: RemotePollSetting.fifteenMinutes)  RemotePollSetting remotePoll)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ProjectEntry() when $default != null:
return $default(_that.path,_that.name,_that.group,_that.order,_that.lastOpened,_that.status,_that.bookmark,_that.expandedStacks,_that.collapsedStacks,_that.graphView,_that.recentSearches,_that.viewedFiles,_that.remotePoll);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String path,  String name,  String? group,  int order,  DateTime? lastOpened, @JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue)  ProjectStatus? status,  String? bookmark,  List<String> expandedStacks,  List<String> collapsedStacks,  String? graphView,  List<String> recentSearches,  List<String> viewedFiles, @JsonKey(unknownEnumValue: RemotePollSetting.fifteenMinutes)  RemotePollSetting remotePoll)  $default,) {final _that = this;
switch (_that) {
case _ProjectEntry():
return $default(_that.path,_that.name,_that.group,_that.order,_that.lastOpened,_that.status,_that.bookmark,_that.expandedStacks,_that.collapsedStacks,_that.graphView,_that.recentSearches,_that.viewedFiles,_that.remotePoll);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String path,  String name,  String? group,  int order,  DateTime? lastOpened, @JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue)  ProjectStatus? status,  String? bookmark,  List<String> expandedStacks,  List<String> collapsedStacks,  String? graphView,  List<String> recentSearches,  List<String> viewedFiles, @JsonKey(unknownEnumValue: RemotePollSetting.fifteenMinutes)  RemotePollSetting remotePoll)?  $default,) {final _that = this;
switch (_that) {
case _ProjectEntry() when $default != null:
return $default(_that.path,_that.name,_that.group,_that.order,_that.lastOpened,_that.status,_that.bookmark,_that.expandedStacks,_that.collapsedStacks,_that.graphView,_that.recentSearches,_that.viewedFiles,_that.remotePoll);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ProjectEntry implements ProjectEntry {
  const _ProjectEntry({required this.path, required this.name, this.group, this.order = 0, this.lastOpened, @JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue) this.status, this.bookmark,  List<String> expandedStacks = const <String>[],  List<String> collapsedStacks = const <String>[], this.graphView,  List<String> recentSearches = const <String>[],  List<String> viewedFiles = const <String>[], @JsonKey(unknownEnumValue: RemotePollSetting.fifteenMinutes) this.remotePoll = RemotePollSetting.fifteenMinutes}): _expandedStacks = expandedStacks,_collapsedStacks = collapsedStacks,_recentSearches = recentSearches,_viewedFiles = viewedFiles;
  factory _ProjectEntry.fromJson(Map<String, dynamic> json) => _$ProjectEntryFromJson(json);

/// The workspace's root directory, absolute; the registry's key.
@override final  String path;
/// The name the capsule, the Project menu and the Projects window show.
@override final  String name;
/// The [ProjectGroup.id] of its group, or null at the top level.
@override final  String? group;
/// Its position among its siblings (the groups and projects of the same parent), from 0.
@override@JsonKey() final  int order;
/// When it was last opened (UTC), or null when it never was; the Project menu's Recent sorts by it.
@override final  DateTime? lastOpened;
/// Its last known state, written after every reading of the open project and when a switch or a close leaves
/// it (item 7), or null before the first. A value this version does not know reads as null (Story 11.5: a newer
/// file never breaks an older app's settings).
@override@JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue) final  ProjectStatus? status;
/// Its last known bookmark label — the first by name of the local bookmarks on @'s closest bookmarked ancestor
/// (design question (b)) — or null when there was none ("—").
@override final  String? bookmark;
/// The graph's stacks the user expanded, by their run's oldest member key (Story 10.17).
 final  List<String> _expandedStacks;
/// The graph's stacks the user expanded, by their run's oldest member key (Story 10.17).
@override@JsonKey() List<String> get expandedStacks {
  if (_expandedStacks is EqualUnmodifiableListView) return _expandedStacks;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_expandedStacks);
}

/// The graph's stacks the user collapsed, by their run's oldest member key (Story 10.17).
 final  List<String> _collapsedStacks;
/// The graph's stacks the user collapsed, by their run's oldest member key (Story 10.17).
@override@JsonKey() List<String> get collapsedStacks {
  if (_collapsedStacks is EqualUnmodifiableListView) return _collapsedStacks;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_collapsedStacks);
}

/// What the graph shows, as the search's JSON text (Story 10.21), or null for the default search.
@override final  String? graphView;
/// The graph search's recent go-tos and filters, newest first, each as its JSON text (Story 10.21).
 final  List<String> _recentSearches;
/// The graph search's recent go-tos and filters, newest first, each as its JSON text (Story 10.21).
@override@JsonKey() List<String> get recentSearches {
  if (_recentSearches is EqualUnmodifiableListView) return _recentSearches;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_recentSearches);
}

/// The inspector's Viewed marks, each `<change id>:<fingerprint>:<path>`, oldest first (Story 10.24).
 final  List<String> _viewedFiles;
/// The inspector's Viewed marks, each `<change id>:<fingerprint>:<path>`, oldest first (Story 10.24).
@override@JsonKey() List<String> get viewedFiles {
  if (_viewedFiles is EqualUnmodifiableListView) return _viewedFiles;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_viewedFiles);
}

/// Settings › Project's "Check for remote changes" (Story 11.7; 11.8's poll reads it); every 15 minutes by
/// default, and for a value this version does not know.
@override@JsonKey(unknownEnumValue: RemotePollSetting.fifteenMinutes) final  RemotePollSetting remotePoll;

/// Create a copy of ProjectEntry
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProjectEntryCopyWith<_ProjectEntry> get copyWith => __$ProjectEntryCopyWithImpl<_ProjectEntry>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ProjectEntryToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ProjectEntry&&(identical(other.path, path) || other.path == path)&&(identical(other.name, name) || other.name == name)&&(identical(other.group, group) || other.group == group)&&(identical(other.order, order) || other.order == order)&&(identical(other.lastOpened, lastOpened) || other.lastOpened == lastOpened)&&(identical(other.status, status) || other.status == status)&&(identical(other.bookmark, bookmark) || other.bookmark == bookmark)&&const DeepCollectionEquality().equals(other.expandedStacks, _expandedStacks)&&const DeepCollectionEquality().equals(other.collapsedStacks, _collapsedStacks)&&(identical(other.graphView, graphView) || other.graphView == graphView)&&const DeepCollectionEquality().equals(other.recentSearches, _recentSearches)&&const DeepCollectionEquality().equals(other.viewedFiles, _viewedFiles)&&(identical(other.remotePoll, remotePoll) || other.remotePoll == remotePoll));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,path,name,group,order,lastOpened,status,bookmark,const DeepCollectionEquality().hash(_expandedStacks),const DeepCollectionEquality().hash(_collapsedStacks),graphView,const DeepCollectionEquality().hash(_recentSearches),const DeepCollectionEquality().hash(_viewedFiles),remotePoll);
}

@override
String toString() {
    return 'ProjectEntry(path: $path, name: $name, group: $group, order: $order, lastOpened: $lastOpened, status: $status, bookmark: $bookmark, expandedStacks: $expandedStacks, collapsedStacks: $collapsedStacks, graphView: $graphView, recentSearches: $recentSearches, viewedFiles: $viewedFiles, remotePoll: $remotePoll)';
}


}

/// @nodoc
abstract mixin class _$ProjectEntryCopyWith<$Res> implements $ProjectEntryCopyWith<$Res> {
  factory _$ProjectEntryCopyWith(_ProjectEntry value, $Res Function(_ProjectEntry) _then) = __$ProjectEntryCopyWithImpl;
@override @useResult
$Res call({
 String path, String name, String? group, int order, DateTime? lastOpened,@JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue) ProjectStatus? status, String? bookmark, List<String> expandedStacks, List<String> collapsedStacks, String? graphView, List<String> recentSearches, List<String> viewedFiles,@JsonKey(unknownEnumValue: RemotePollSetting.fifteenMinutes) RemotePollSetting remotePoll
});




}
/// @nodoc
class __$ProjectEntryCopyWithImpl<$Res>
    implements _$ProjectEntryCopyWith<$Res> {
  __$ProjectEntryCopyWithImpl(this._self, this._then);

  final _ProjectEntry _self;
  final $Res Function(_ProjectEntry) _then;

/// Create a copy of ProjectEntry
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? path = null,Object? name = null,Object? group = freezed,Object? order = null,Object? lastOpened = freezed,Object? status = freezed,Object? bookmark = freezed,Object? expandedStacks = null,Object? collapsedStacks = null,Object? graphView = freezed,Object? recentSearches = null,Object? viewedFiles = null,Object? remotePoll = null,}) {
  return _then(_ProjectEntry(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,group: freezed == group ? _self.group : group // ignore: cast_nullable_to_non_nullable
as String?,order: null == order ? _self.order : order // ignore: cast_nullable_to_non_nullable
as int,lastOpened: freezed == lastOpened ? _self.lastOpened : lastOpened // ignore: cast_nullable_to_non_nullable
as DateTime?,status: freezed == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ProjectStatus?,bookmark: freezed == bookmark ? _self.bookmark : bookmark // ignore: cast_nullable_to_non_nullable
as String?,expandedStacks: null == expandedStacks ? _self._expandedStacks : expandedStacks // ignore: cast_nullable_to_non_nullable
as List<String>,collapsedStacks: null == collapsedStacks ? _self._collapsedStacks : collapsedStacks // ignore: cast_nullable_to_non_nullable
as List<String>,graphView: freezed == graphView ? _self.graphView : graphView // ignore: cast_nullable_to_non_nullable
as String?,recentSearches: null == recentSearches ? _self._recentSearches : recentSearches // ignore: cast_nullable_to_non_nullable
as List<String>,viewedFiles: null == viewedFiles ? _self._viewedFiles : viewedFiles // ignore: cast_nullable_to_non_nullable
as List<String>,remotePoll: null == remotePoll ? _self.remotePoll : remotePoll // ignore: cast_nullable_to_non_nullable
as RemotePollSetting,
  ));
}


}


/// @nodoc
mixin _$ProjectGroup {

/// The group's key, `g<n>` (Claude's proposal).
 String get id;/// The name the Projects window shows.
 String get name;/// The [ProjectGroup.id] of its parent group, or null at the top level.
 String? get parent;/// Its position among its siblings (the groups and projects of the same parent), from 0.
 int get order;
/// Create a copy of ProjectGroup
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProjectGroupCopyWith<ProjectGroup> get copyWith => _$ProjectGroupCopyWithImpl<ProjectGroup>(this as ProjectGroup, _$identity);

  /// Serializes this ProjectGroup to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as ProjectGroup;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProjectGroup&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.parent, _this.parent) || other.parent == _this.parent)&&(identical(other.order, _this.order) || other.order == _this.order));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as ProjectGroup;
  return Object.hash(runtimeType,_this.id,_this.name,_this.parent,_this.order);
}

@override
String toString() {
  final _this = this as ProjectGroup;
  return 'ProjectGroup(id: ${_this.id}, name: ${_this.name}, parent: ${_this.parent}, order: ${_this.order})';
}


}

/// @nodoc
abstract mixin class $ProjectGroupCopyWith<$Res>  {
  factory $ProjectGroupCopyWith(ProjectGroup value, $Res Function(ProjectGroup) _then) = _$ProjectGroupCopyWithImpl;
@useResult
$Res call({
 String id, String name, String? parent, int order
});




}
/// @nodoc
class _$ProjectGroupCopyWithImpl<$Res>
    implements $ProjectGroupCopyWith<$Res> {
  _$ProjectGroupCopyWithImpl(this._self, this._then);

  final ProjectGroup _self;
  final $Res Function(ProjectGroup) _then;

/// Create a copy of ProjectGroup
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? parent = freezed,Object? order = null,}) {
  return _then(ProjectGroup(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,parent: freezed == parent ? _self.parent : parent // ignore: cast_nullable_to_non_nullable
as String?,order: null == order ? _self.order : order // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [ProjectGroup].
extension ProjectGroupPatterns on ProjectGroup {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ProjectGroup value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ProjectGroup() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ProjectGroup value)  $default,){
final _that = this;
switch (_that) {
case _ProjectGroup():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ProjectGroup value)?  $default,){
final _that = this;
switch (_that) {
case _ProjectGroup() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String? parent,  int order)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ProjectGroup() when $default != null:
return $default(_that.id,_that.name,_that.parent,_that.order);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String? parent,  int order)  $default,) {final _that = this;
switch (_that) {
case _ProjectGroup():
return $default(_that.id,_that.name,_that.parent,_that.order);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String? parent,  int order)?  $default,) {final _that = this;
switch (_that) {
case _ProjectGroup() when $default != null:
return $default(_that.id,_that.name,_that.parent,_that.order);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ProjectGroup implements ProjectGroup {
  const _ProjectGroup({required this.id, required this.name, this.parent, this.order = 0});
  factory _ProjectGroup.fromJson(Map<String, dynamic> json) => _$ProjectGroupFromJson(json);

/// The group's key, `g<n>` (Claude's proposal).
@override final  String id;
/// The name the Projects window shows.
@override final  String name;
/// The [ProjectGroup.id] of its parent group, or null at the top level.
@override final  String? parent;
/// Its position among its siblings (the groups and projects of the same parent), from 0.
@override@JsonKey() final  int order;

/// Create a copy of ProjectGroup
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProjectGroupCopyWith<_ProjectGroup> get copyWith => __$ProjectGroupCopyWithImpl<_ProjectGroup>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ProjectGroupToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ProjectGroup&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.parent, parent) || other.parent == parent)&&(identical(other.order, order) || other.order == order));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,id,name,parent,order);
}

@override
String toString() {
    return 'ProjectGroup(id: $id, name: $name, parent: $parent, order: $order)';
}


}

/// @nodoc
abstract mixin class _$ProjectGroupCopyWith<$Res> implements $ProjectGroupCopyWith<$Res> {
  factory _$ProjectGroupCopyWith(_ProjectGroup value, $Res Function(_ProjectGroup) _then) = __$ProjectGroupCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String? parent, int order
});




}
/// @nodoc
class __$ProjectGroupCopyWithImpl<$Res>
    implements _$ProjectGroupCopyWith<$Res> {
  __$ProjectGroupCopyWithImpl(this._self, this._then);

  final _ProjectGroup _self;
  final $Res Function(_ProjectGroup) _then;

/// Create a copy of ProjectGroup
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? parent = freezed,Object? order = null,}) {
  return _then(_ProjectGroup(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,parent: freezed == parent ? _self.parent : parent // ignore: cast_nullable_to_non_nullable
as String?,order: null == order ? _self.order : order // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
