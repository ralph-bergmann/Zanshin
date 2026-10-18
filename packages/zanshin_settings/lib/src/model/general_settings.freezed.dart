// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'general_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$GeneralSettings {

/// "While you scroll: Hide controls" — the floating controls step aside while the graph scrolls (epics.md Story
/// 11.3 item 8); on by default.
 bool get hideControls;
/// Create a copy of GeneralSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GeneralSettingsCopyWith<GeneralSettings> get copyWith => _$GeneralSettingsCopyWithImpl<GeneralSettings>(this as GeneralSettings, _$identity);

  /// Serializes this GeneralSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as GeneralSettings;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GeneralSettings&&(identical(other.hideControls, _this.hideControls) || other.hideControls == _this.hideControls));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as GeneralSettings;
  return Object.hash(runtimeType,_this.hideControls);
}

@override
String toString() {
  final _this = this as GeneralSettings;
  return 'GeneralSettings(hideControls: ${_this.hideControls})';
}


}

/// @nodoc
abstract mixin class $GeneralSettingsCopyWith<$Res>  {
  factory $GeneralSettingsCopyWith(GeneralSettings value, $Res Function(GeneralSettings) _then) = _$GeneralSettingsCopyWithImpl;
@useResult
$Res call({
 bool hideControls
});




}
/// @nodoc
class _$GeneralSettingsCopyWithImpl<$Res>
    implements $GeneralSettingsCopyWith<$Res> {
  _$GeneralSettingsCopyWithImpl(this._self, this._then);

  final GeneralSettings _self;
  final $Res Function(GeneralSettings) _then;

/// Create a copy of GeneralSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? hideControls = null,}) {
  return _then(GeneralSettings(
hideControls: null == hideControls ? _self.hideControls : hideControls // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [GeneralSettings].
extension GeneralSettingsPatterns on GeneralSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _GeneralSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _GeneralSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _GeneralSettings value)  $default,){
final _that = this;
switch (_that) {
case _GeneralSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _GeneralSettings value)?  $default,){
final _that = this;
switch (_that) {
case _GeneralSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool hideControls)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _GeneralSettings() when $default != null:
return $default(_that.hideControls);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool hideControls)  $default,) {final _that = this;
switch (_that) {
case _GeneralSettings():
return $default(_that.hideControls);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool hideControls)?  $default,) {final _that = this;
switch (_that) {
case _GeneralSettings() when $default != null:
return $default(_that.hideControls);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _GeneralSettings implements GeneralSettings {
  const _GeneralSettings({this.hideControls = true});
  factory _GeneralSettings.fromJson(Map<String, dynamic> json) => _$GeneralSettingsFromJson(json);

/// "While you scroll: Hide controls" — the floating controls step aside while the graph scrolls (epics.md Story
/// 11.3 item 8); on by default.
@override@JsonKey() final  bool hideControls;

/// Create a copy of GeneralSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$GeneralSettingsCopyWith<_GeneralSettings> get copyWith => __$GeneralSettingsCopyWithImpl<_GeneralSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$GeneralSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _GeneralSettings&&(identical(other.hideControls, hideControls) || other.hideControls == hideControls));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,hideControls);
}

@override
String toString() {
    return 'GeneralSettings(hideControls: $hideControls)';
}


}

/// @nodoc
abstract mixin class _$GeneralSettingsCopyWith<$Res> implements $GeneralSettingsCopyWith<$Res> {
  factory _$GeneralSettingsCopyWith(_GeneralSettings value, $Res Function(_GeneralSettings) _then) = __$GeneralSettingsCopyWithImpl;
@override @useResult
$Res call({
 bool hideControls
});




}
/// @nodoc
class __$GeneralSettingsCopyWithImpl<$Res>
    implements _$GeneralSettingsCopyWith<$Res> {
  __$GeneralSettingsCopyWithImpl(this._self, this._then);

  final _GeneralSettings _self;
  final $Res Function(_GeneralSettings) _then;

/// Create a copy of GeneralSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? hideControls = null,}) {
  return _then(_GeneralSettings(
hideControls: null == hideControls ? _self.hideControls : hideControls // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
