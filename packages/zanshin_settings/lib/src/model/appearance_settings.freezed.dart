// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'appearance_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$AppearanceSettings {

/// The user's day/night choice; `system` follows the OS.
 ThemeMode get themeMode;/// Where the accent colour comes from; [AccentSource.followMacOS] by default.
 AccentSource get accentSource;/// The density; [DensitySetting.compact] by default, and for a value this version does not know.
@JsonKey(unknownEnumValue: DensitySetting.compact) DensitySetting get density;/// The app-wide zoom in percent (90 · 100 · 110 · 125 · 150); 100 by default. The app snaps a value off
/// those steps to the nearest one where it uses it.
 int get zoom;
/// Create a copy of AppearanceSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppearanceSettingsCopyWith<AppearanceSettings> get copyWith => _$AppearanceSettingsCopyWithImpl<AppearanceSettings>(this as AppearanceSettings, _$identity);

  /// Serializes this AppearanceSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as AppearanceSettings;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppearanceSettings&&(identical(other.themeMode, _this.themeMode) || other.themeMode == _this.themeMode)&&(identical(other.accentSource, _this.accentSource) || other.accentSource == _this.accentSource)&&(identical(other.density, _this.density) || other.density == _this.density)&&(identical(other.zoom, _this.zoom) || other.zoom == _this.zoom));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as AppearanceSettings;
  return Object.hash(runtimeType,_this.themeMode,_this.accentSource,_this.density,_this.zoom);
}

@override
String toString() {
  final _this = this as AppearanceSettings;
  return 'AppearanceSettings(themeMode: ${_this.themeMode}, accentSource: ${_this.accentSource}, density: ${_this.density}, zoom: ${_this.zoom})';
}


}

/// @nodoc
abstract mixin class $AppearanceSettingsCopyWith<$Res>  {
  factory $AppearanceSettingsCopyWith(AppearanceSettings value, $Res Function(AppearanceSettings) _then) = _$AppearanceSettingsCopyWithImpl;
@useResult
$Res call({
 ThemeMode themeMode, AccentSource accentSource,@JsonKey(unknownEnumValue: DensitySetting.compact) DensitySetting density, int zoom
});




}
/// @nodoc
class _$AppearanceSettingsCopyWithImpl<$Res>
    implements $AppearanceSettingsCopyWith<$Res> {
  _$AppearanceSettingsCopyWithImpl(this._self, this._then);

  final AppearanceSettings _self;
  final $Res Function(AppearanceSettings) _then;

/// Create a copy of AppearanceSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? themeMode = null,Object? accentSource = null,Object? density = null,Object? zoom = null,}) {
  return _then(AppearanceSettings(
themeMode: null == themeMode ? _self.themeMode : themeMode // ignore: cast_nullable_to_non_nullable
as ThemeMode,accentSource: null == accentSource ? _self.accentSource : accentSource // ignore: cast_nullable_to_non_nullable
as AccentSource,density: null == density ? _self.density : density // ignore: cast_nullable_to_non_nullable
as DensitySetting,zoom: null == zoom ? _self.zoom : zoom // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [AppearanceSettings].
extension AppearanceSettingsPatterns on AppearanceSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AppearanceSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AppearanceSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AppearanceSettings value)  $default,){
final _that = this;
switch (_that) {
case _AppearanceSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AppearanceSettings value)?  $default,){
final _that = this;
switch (_that) {
case _AppearanceSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( ThemeMode themeMode,  AccentSource accentSource, @JsonKey(unknownEnumValue: DensitySetting.compact)  DensitySetting density,  int zoom)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AppearanceSettings() when $default != null:
return $default(_that.themeMode,_that.accentSource,_that.density,_that.zoom);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( ThemeMode themeMode,  AccentSource accentSource, @JsonKey(unknownEnumValue: DensitySetting.compact)  DensitySetting density,  int zoom)  $default,) {final _that = this;
switch (_that) {
case _AppearanceSettings():
return $default(_that.themeMode,_that.accentSource,_that.density,_that.zoom);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( ThemeMode themeMode,  AccentSource accentSource, @JsonKey(unknownEnumValue: DensitySetting.compact)  DensitySetting density,  int zoom)?  $default,) {final _that = this;
switch (_that) {
case _AppearanceSettings() when $default != null:
return $default(_that.themeMode,_that.accentSource,_that.density,_that.zoom);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AppearanceSettings implements AppearanceSettings {
  const _AppearanceSettings({this.themeMode = ThemeMode.system, this.accentSource = AccentSource.followMacOS, @JsonKey(unknownEnumValue: DensitySetting.compact) this.density = DensitySetting.compact, this.zoom = 100});
  factory _AppearanceSettings.fromJson(Map<String, dynamic> json) => _$AppearanceSettingsFromJson(json);

/// The user's day/night choice; `system` follows the OS.
@override@JsonKey() final  ThemeMode themeMode;
/// Where the accent colour comes from; [AccentSource.followMacOS] by default.
@override@JsonKey() final  AccentSource accentSource;
/// The density; [DensitySetting.compact] by default, and for a value this version does not know.
@override@JsonKey(unknownEnumValue: DensitySetting.compact) final  DensitySetting density;
/// The app-wide zoom in percent (90 · 100 · 110 · 125 · 150); 100 by default. The app snaps a value off
/// those steps to the nearest one where it uses it.
@override@JsonKey() final  int zoom;

/// Create a copy of AppearanceSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppearanceSettingsCopyWith<_AppearanceSettings> get copyWith => __$AppearanceSettingsCopyWithImpl<_AppearanceSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AppearanceSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppearanceSettings&&(identical(other.themeMode, themeMode) || other.themeMode == themeMode)&&(identical(other.accentSource, accentSource) || other.accentSource == accentSource)&&(identical(other.density, density) || other.density == density)&&(identical(other.zoom, zoom) || other.zoom == zoom));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,themeMode,accentSource,density,zoom);
}

@override
String toString() {
    return 'AppearanceSettings(themeMode: $themeMode, accentSource: $accentSource, density: $density, zoom: $zoom)';
}


}

/// @nodoc
abstract mixin class _$AppearanceSettingsCopyWith<$Res> implements $AppearanceSettingsCopyWith<$Res> {
  factory _$AppearanceSettingsCopyWith(_AppearanceSettings value, $Res Function(_AppearanceSettings) _then) = __$AppearanceSettingsCopyWithImpl;
@override @useResult
$Res call({
 ThemeMode themeMode, AccentSource accentSource,@JsonKey(unknownEnumValue: DensitySetting.compact) DensitySetting density, int zoom
});




}
/// @nodoc
class __$AppearanceSettingsCopyWithImpl<$Res>
    implements _$AppearanceSettingsCopyWith<$Res> {
  __$AppearanceSettingsCopyWithImpl(this._self, this._then);

  final _AppearanceSettings _self;
  final $Res Function(_AppearanceSettings) _then;

/// Create a copy of AppearanceSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? themeMode = null,Object? accentSource = null,Object? density = null,Object? zoom = null,}) {
  return _then(_AppearanceSettings(
themeMode: null == themeMode ? _self.themeMode : themeMode // ignore: cast_nullable_to_non_nullable
as ThemeMode,accentSource: null == accentSource ? _self.accentSource : accentSource // ignore: cast_nullable_to_non_nullable
as AccentSource,density: null == density ? _self.density : density // ignore: cast_nullable_to_non_nullable
as DensitySetting,zoom: null == zoom ? _self.zoom : zoom // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
