// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'layout_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$LayoutSettings {

/// The inspector's remembered width, `--inspector-w` 460 by default (380–720).
 double get inspectorWidth;/// The left panels' remembered width, `--panel-w` 300 by default (240–440).
 double get panelWidth;
/// Create a copy of LayoutSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$LayoutSettingsCopyWith<LayoutSettings> get copyWith => _$LayoutSettingsCopyWithImpl<LayoutSettings>(this as LayoutSettings, _$identity);

  /// Serializes this LayoutSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as LayoutSettings;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is LayoutSettings&&(identical(other.inspectorWidth, _this.inspectorWidth) || other.inspectorWidth == _this.inspectorWidth)&&(identical(other.panelWidth, _this.panelWidth) || other.panelWidth == _this.panelWidth));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as LayoutSettings;
  return Object.hash(runtimeType,_this.inspectorWidth,_this.panelWidth);
}

@override
String toString() {
  final _this = this as LayoutSettings;
  return 'LayoutSettings(inspectorWidth: ${_this.inspectorWidth}, panelWidth: ${_this.panelWidth})';
}


}

/// @nodoc
abstract mixin class $LayoutSettingsCopyWith<$Res>  {
  factory $LayoutSettingsCopyWith(LayoutSettings value, $Res Function(LayoutSettings) _then) = _$LayoutSettingsCopyWithImpl;
@useResult
$Res call({
 double inspectorWidth, double panelWidth
});




}
/// @nodoc
class _$LayoutSettingsCopyWithImpl<$Res>
    implements $LayoutSettingsCopyWith<$Res> {
  _$LayoutSettingsCopyWithImpl(this._self, this._then);

  final LayoutSettings _self;
  final $Res Function(LayoutSettings) _then;

/// Create a copy of LayoutSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? inspectorWidth = null,Object? panelWidth = null,}) {
  return _then(LayoutSettings(
inspectorWidth: null == inspectorWidth ? _self.inspectorWidth : inspectorWidth // ignore: cast_nullable_to_non_nullable
as double,panelWidth: null == panelWidth ? _self.panelWidth : panelWidth // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [LayoutSettings].
extension LayoutSettingsPatterns on LayoutSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _LayoutSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _LayoutSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _LayoutSettings value)  $default,){
final _that = this;
switch (_that) {
case _LayoutSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _LayoutSettings value)?  $default,){
final _that = this;
switch (_that) {
case _LayoutSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double inspectorWidth,  double panelWidth)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _LayoutSettings() when $default != null:
return $default(_that.inspectorWidth,_that.panelWidth);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double inspectorWidth,  double panelWidth)  $default,) {final _that = this;
switch (_that) {
case _LayoutSettings():
return $default(_that.inspectorWidth,_that.panelWidth);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double inspectorWidth,  double panelWidth)?  $default,) {final _that = this;
switch (_that) {
case _LayoutSettings() when $default != null:
return $default(_that.inspectorWidth,_that.panelWidth);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _LayoutSettings implements LayoutSettings {
  const _LayoutSettings({this.inspectorWidth = 460, this.panelWidth = 300});
  factory _LayoutSettings.fromJson(Map<String, dynamic> json) => _$LayoutSettingsFromJson(json);

/// The inspector's remembered width, `--inspector-w` 460 by default (380–720).
@override@JsonKey() final  double inspectorWidth;
/// The left panels' remembered width, `--panel-w` 300 by default (240–440).
@override@JsonKey() final  double panelWidth;

/// Create a copy of LayoutSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$LayoutSettingsCopyWith<_LayoutSettings> get copyWith => __$LayoutSettingsCopyWithImpl<_LayoutSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$LayoutSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _LayoutSettings&&(identical(other.inspectorWidth, inspectorWidth) || other.inspectorWidth == inspectorWidth)&&(identical(other.panelWidth, panelWidth) || other.panelWidth == panelWidth));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,inspectorWidth,panelWidth);
}

@override
String toString() {
    return 'LayoutSettings(inspectorWidth: $inspectorWidth, panelWidth: $panelWidth)';
}


}

/// @nodoc
abstract mixin class _$LayoutSettingsCopyWith<$Res> implements $LayoutSettingsCopyWith<$Res> {
  factory _$LayoutSettingsCopyWith(_LayoutSettings value, $Res Function(_LayoutSettings) _then) = __$LayoutSettingsCopyWithImpl;
@override @useResult
$Res call({
 double inspectorWidth, double panelWidth
});




}
/// @nodoc
class __$LayoutSettingsCopyWithImpl<$Res>
    implements _$LayoutSettingsCopyWith<$Res> {
  __$LayoutSettingsCopyWithImpl(this._self, this._then);

  final _LayoutSettings _self;
  final $Res Function(_LayoutSettings) _then;

/// Create a copy of LayoutSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? inspectorWidth = null,Object? panelWidth = null,}) {
  return _then(_LayoutSettings(
inspectorWidth: null == inspectorWidth ? _self.inspectorWidth : inspectorWidth // ignore: cast_nullable_to_non_nullable
as double,panelWidth: null == panelWidth ? _self.panelWidth : panelWidth // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

// dart format on
