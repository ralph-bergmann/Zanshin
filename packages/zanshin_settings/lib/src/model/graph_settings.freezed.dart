// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'graph_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$GraphSettings {

/// The layout mode; [GraphLayoutSetting.free] by default.
 GraphLayoutSetting get layout;/// Detailed (62 px) or compact (40 px) cards; detailed by default.
 bool get detailedCards;/// Whether linear runs of changes collapse into stack cards; on by default.
 bool get groupStacks;/// The card width, 240 by default (160–400; the app clamps it where it uses it).
 double get cardWidth;
/// Create a copy of GraphSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GraphSettingsCopyWith<GraphSettings> get copyWith => _$GraphSettingsCopyWithImpl<GraphSettings>(this as GraphSettings, _$identity);

  /// Serializes this GraphSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as GraphSettings;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GraphSettings&&(identical(other.layout, _this.layout) || other.layout == _this.layout)&&(identical(other.detailedCards, _this.detailedCards) || other.detailedCards == _this.detailedCards)&&(identical(other.groupStacks, _this.groupStacks) || other.groupStacks == _this.groupStacks)&&(identical(other.cardWidth, _this.cardWidth) || other.cardWidth == _this.cardWidth));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as GraphSettings;
  return Object.hash(runtimeType,_this.layout,_this.detailedCards,_this.groupStacks,_this.cardWidth);
}

@override
String toString() {
  final _this = this as GraphSettings;
  return 'GraphSettings(layout: ${_this.layout}, detailedCards: ${_this.detailedCards}, groupStacks: ${_this.groupStacks}, cardWidth: ${_this.cardWidth})';
}


}

/// @nodoc
abstract mixin class $GraphSettingsCopyWith<$Res>  {
  factory $GraphSettingsCopyWith(GraphSettings value, $Res Function(GraphSettings) _then) = _$GraphSettingsCopyWithImpl;
@useResult
$Res call({
 GraphLayoutSetting layout, bool detailedCards, bool groupStacks, double cardWidth
});




}
/// @nodoc
class _$GraphSettingsCopyWithImpl<$Res>
    implements $GraphSettingsCopyWith<$Res> {
  _$GraphSettingsCopyWithImpl(this._self, this._then);

  final GraphSettings _self;
  final $Res Function(GraphSettings) _then;

/// Create a copy of GraphSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? layout = null,Object? detailedCards = null,Object? groupStacks = null,Object? cardWidth = null,}) {
  return _then(GraphSettings(
layout: null == layout ? _self.layout : layout // ignore: cast_nullable_to_non_nullable
as GraphLayoutSetting,detailedCards: null == detailedCards ? _self.detailedCards : detailedCards // ignore: cast_nullable_to_non_nullable
as bool,groupStacks: null == groupStacks ? _self.groupStacks : groupStacks // ignore: cast_nullable_to_non_nullable
as bool,cardWidth: null == cardWidth ? _self.cardWidth : cardWidth // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [GraphSettings].
extension GraphSettingsPatterns on GraphSettings {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _GraphSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _GraphSettings() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _GraphSettings value)  $default,){
final _that = this;
switch (_that) {
case _GraphSettings():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _GraphSettings value)?  $default,){
final _that = this;
switch (_that) {
case _GraphSettings() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( GraphLayoutSetting layout,  bool detailedCards,  bool groupStacks,  double cardWidth)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _GraphSettings() when $default != null:
return $default(_that.layout,_that.detailedCards,_that.groupStacks,_that.cardWidth);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( GraphLayoutSetting layout,  bool detailedCards,  bool groupStacks,  double cardWidth)  $default,) {final _that = this;
switch (_that) {
case _GraphSettings():
return $default(_that.layout,_that.detailedCards,_that.groupStacks,_that.cardWidth);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( GraphLayoutSetting layout,  bool detailedCards,  bool groupStacks,  double cardWidth)?  $default,) {final _that = this;
switch (_that) {
case _GraphSettings() when $default != null:
return $default(_that.layout,_that.detailedCards,_that.groupStacks,_that.cardWidth);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _GraphSettings implements GraphSettings {
  const _GraphSettings({this.layout = GraphLayoutSetting.free, this.detailedCards = true, this.groupStacks = true, this.cardWidth = 240});
  factory _GraphSettings.fromJson(Map<String, dynamic> json) => _$GraphSettingsFromJson(json);

/// The layout mode; [GraphLayoutSetting.free] by default.
@override@JsonKey() final  GraphLayoutSetting layout;
/// Detailed (62 px) or compact (40 px) cards; detailed by default.
@override@JsonKey() final  bool detailedCards;
/// Whether linear runs of changes collapse into stack cards; on by default.
@override@JsonKey() final  bool groupStacks;
/// The card width, 240 by default (160–400; the app clamps it where it uses it).
@override@JsonKey() final  double cardWidth;

/// Create a copy of GraphSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$GraphSettingsCopyWith<_GraphSettings> get copyWith => __$GraphSettingsCopyWithImpl<_GraphSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$GraphSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _GraphSettings&&(identical(other.layout, layout) || other.layout == layout)&&(identical(other.detailedCards, detailedCards) || other.detailedCards == detailedCards)&&(identical(other.groupStacks, groupStacks) || other.groupStacks == groupStacks)&&(identical(other.cardWidth, cardWidth) || other.cardWidth == cardWidth));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,layout,detailedCards,groupStacks,cardWidth);
}

@override
String toString() {
    return 'GraphSettings(layout: $layout, detailedCards: $detailedCards, groupStacks: $groupStacks, cardWidth: $cardWidth)';
}


}

/// @nodoc
abstract mixin class _$GraphSettingsCopyWith<$Res> implements $GraphSettingsCopyWith<$Res> {
  factory _$GraphSettingsCopyWith(_GraphSettings value, $Res Function(_GraphSettings) _then) = __$GraphSettingsCopyWithImpl;
@override @useResult
$Res call({
 GraphLayoutSetting layout, bool detailedCards, bool groupStacks, double cardWidth
});




}
/// @nodoc
class __$GraphSettingsCopyWithImpl<$Res>
    implements _$GraphSettingsCopyWith<$Res> {
  __$GraphSettingsCopyWithImpl(this._self, this._then);

  final _GraphSettings _self;
  final $Res Function(_GraphSettings) _then;

/// Create a copy of GraphSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? layout = null,Object? detailedCards = null,Object? groupStacks = null,Object? cardWidth = null,}) {
  return _then(_GraphSettings(
layout: null == layout ? _self.layout : layout // ignore: cast_nullable_to_non_nullable
as GraphLayoutSetting,detailedCards: null == detailedCards ? _self.detailedCards : detailedCards // ignore: cast_nullable_to_non_nullable
as bool,groupStacks: null == groupStacks ? _self.groupStacks : groupStacks // ignore: cast_nullable_to_non_nullable
as bool,cardWidth: null == cardWidth ? _self.cardWidth : cardWidth // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

// dart format on
