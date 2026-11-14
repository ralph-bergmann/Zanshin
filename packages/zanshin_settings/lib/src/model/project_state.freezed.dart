// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'project_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ProjectState {

/// The inspector's Viewed marks, each `<change id>:<fingerprint>:<path>` (Story 10.24).
 List<String> get viewedFiles;/// The graph's stacks the user expanded, by their run's oldest member key (Story 10.17).
 List<String> get expandedStacks;/// The graph's stacks the user collapsed, by their run's oldest member key (Story 10.17).
 List<String> get collapsedStacks;
/// Create a copy of ProjectState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProjectStateCopyWith<ProjectState> get copyWith => _$ProjectStateCopyWithImpl<ProjectState>(this as ProjectState, _$identity);

  /// Serializes this ProjectState to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as ProjectState;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProjectState&&const DeepCollectionEquality().equals(other.viewedFiles, _this.viewedFiles)&&const DeepCollectionEquality().equals(other.expandedStacks, _this.expandedStacks)&&const DeepCollectionEquality().equals(other.collapsedStacks, _this.collapsedStacks));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as ProjectState;
  return Object.hash(runtimeType,const DeepCollectionEquality().hash(_this.viewedFiles),const DeepCollectionEquality().hash(_this.expandedStacks),const DeepCollectionEquality().hash(_this.collapsedStacks));
}

@override
String toString() {
  final _this = this as ProjectState;
  return 'ProjectState(viewedFiles: ${_this.viewedFiles}, expandedStacks: ${_this.expandedStacks}, collapsedStacks: ${_this.collapsedStacks})';
}


}

/// @nodoc
abstract mixin class $ProjectStateCopyWith<$Res>  {
  factory $ProjectStateCopyWith(ProjectState value, $Res Function(ProjectState) _then) = _$ProjectStateCopyWithImpl;
@useResult
$Res call({
 List<String> viewedFiles, List<String> expandedStacks, List<String> collapsedStacks
});




}
/// @nodoc
class _$ProjectStateCopyWithImpl<$Res>
    implements $ProjectStateCopyWith<$Res> {
  _$ProjectStateCopyWithImpl(this._self, this._then);

  final ProjectState _self;
  final $Res Function(ProjectState) _then;

/// Create a copy of ProjectState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? viewedFiles = null,Object? expandedStacks = null,Object? collapsedStacks = null,}) {
  return _then(ProjectState(
viewedFiles: null == viewedFiles ? _self.viewedFiles : viewedFiles // ignore: cast_nullable_to_non_nullable
as List<String>,expandedStacks: null == expandedStacks ? _self.expandedStacks : expandedStacks // ignore: cast_nullable_to_non_nullable
as List<String>,collapsedStacks: null == collapsedStacks ? _self.collapsedStacks : collapsedStacks // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}

}


/// Adds pattern-matching-related methods to [ProjectState].
extension ProjectStatePatterns on ProjectState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ProjectState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ProjectState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ProjectState value)  $default,){
final _that = this;
switch (_that) {
case _ProjectState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ProjectState value)?  $default,){
final _that = this;
switch (_that) {
case _ProjectState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<String> viewedFiles,  List<String> expandedStacks,  List<String> collapsedStacks)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ProjectState() when $default != null:
return $default(_that.viewedFiles,_that.expandedStacks,_that.collapsedStacks);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<String> viewedFiles,  List<String> expandedStacks,  List<String> collapsedStacks)  $default,) {final _that = this;
switch (_that) {
case _ProjectState():
return $default(_that.viewedFiles,_that.expandedStacks,_that.collapsedStacks);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<String> viewedFiles,  List<String> expandedStacks,  List<String> collapsedStacks)?  $default,) {final _that = this;
switch (_that) {
case _ProjectState() when $default != null:
return $default(_that.viewedFiles,_that.expandedStacks,_that.collapsedStacks);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ProjectState implements ProjectState {
  const _ProjectState({ List<String> viewedFiles = const <String>[],  List<String> expandedStacks = const <String>[],  List<String> collapsedStacks = const <String>[]}): _viewedFiles = viewedFiles,_expandedStacks = expandedStacks,_collapsedStacks = collapsedStacks;
  factory _ProjectState.fromJson(Map<String, dynamic> json) => _$ProjectStateFromJson(json);

/// The inspector's Viewed marks, each `<change id>:<fingerprint>:<path>` (Story 10.24).
 final  List<String> _viewedFiles;
/// The inspector's Viewed marks, each `<change id>:<fingerprint>:<path>` (Story 10.24).
@override@JsonKey() List<String> get viewedFiles {
  if (_viewedFiles is EqualUnmodifiableListView) return _viewedFiles;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_viewedFiles);
}

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


/// Create a copy of ProjectState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProjectStateCopyWith<_ProjectState> get copyWith => __$ProjectStateCopyWithImpl<_ProjectState>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ProjectStateToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ProjectState&&const DeepCollectionEquality().equals(other.viewedFiles, _viewedFiles)&&const DeepCollectionEquality().equals(other.expandedStacks, _expandedStacks)&&const DeepCollectionEquality().equals(other.collapsedStacks, _collapsedStacks));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(_viewedFiles),const DeepCollectionEquality().hash(_expandedStacks),const DeepCollectionEquality().hash(_collapsedStacks));
}

@override
String toString() {
    return 'ProjectState(viewedFiles: $viewedFiles, expandedStacks: $expandedStacks, collapsedStacks: $collapsedStacks)';
}


}

/// @nodoc
abstract mixin class _$ProjectStateCopyWith<$Res> implements $ProjectStateCopyWith<$Res> {
  factory _$ProjectStateCopyWith(_ProjectState value, $Res Function(_ProjectState) _then) = __$ProjectStateCopyWithImpl;
@override @useResult
$Res call({
 List<String> viewedFiles, List<String> expandedStacks, List<String> collapsedStacks
});




}
/// @nodoc
class __$ProjectStateCopyWithImpl<$Res>
    implements _$ProjectStateCopyWith<$Res> {
  __$ProjectStateCopyWithImpl(this._self, this._then);

  final _ProjectState _self;
  final $Res Function(_ProjectState) _then;

/// Create a copy of ProjectState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? viewedFiles = null,Object? expandedStacks = null,Object? collapsedStacks = null,}) {
  return _then(_ProjectState(
viewedFiles: null == viewedFiles ? _self._viewedFiles : viewedFiles // ignore: cast_nullable_to_non_nullable
as List<String>,expandedStacks: null == expandedStacks ? _self._expandedStacks : expandedStacks // ignore: cast_nullable_to_non_nullable
as List<String>,collapsedStacks: null == collapsedStacks ? _self._collapsedStacks : collapsedStacks // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}

// dart format on
