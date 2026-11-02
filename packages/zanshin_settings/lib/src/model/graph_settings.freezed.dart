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
 double get cardWidth;/// Whether the minimap shows beside the graph (Story 10.16); on by default.
 bool get showMinimap;/// The jj log configurations (Story 10.22), in search-menu order (the default search leads the menu, the rest keep this order); global, not per repository.
 List<RevsetConfiguration> get revsetConfigs;/// The default search: `log` (the built-in `jj log`), `all` (`all()`) or a [RevsetConfiguration.id]. An id no
/// configuration has reads as `log` ([effectiveRevsetDefault]).
 String get revsetDefault;
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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GraphSettings&&(identical(other.layout, _this.layout) || other.layout == _this.layout)&&(identical(other.detailedCards, _this.detailedCards) || other.detailedCards == _this.detailedCards)&&(identical(other.groupStacks, _this.groupStacks) || other.groupStacks == _this.groupStacks)&&(identical(other.cardWidth, _this.cardWidth) || other.cardWidth == _this.cardWidth)&&(identical(other.showMinimap, _this.showMinimap) || other.showMinimap == _this.showMinimap)&&const DeepCollectionEquality().equals(other.revsetConfigs, _this.revsetConfigs)&&(identical(other.revsetDefault, _this.revsetDefault) || other.revsetDefault == _this.revsetDefault));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as GraphSettings;
  return Object.hash(runtimeType,_this.layout,_this.detailedCards,_this.groupStacks,_this.cardWidth,_this.showMinimap,const DeepCollectionEquality().hash(_this.revsetConfigs),_this.revsetDefault);
}

@override
String toString() {
  final _this = this as GraphSettings;
  return 'GraphSettings(layout: ${_this.layout}, detailedCards: ${_this.detailedCards}, groupStacks: ${_this.groupStacks}, cardWidth: ${_this.cardWidth}, showMinimap: ${_this.showMinimap}, revsetConfigs: ${_this.revsetConfigs}, revsetDefault: ${_this.revsetDefault})';
}


}

/// @nodoc
abstract mixin class $GraphSettingsCopyWith<$Res>  {
  factory $GraphSettingsCopyWith(GraphSettings value, $Res Function(GraphSettings) _then) = _$GraphSettingsCopyWithImpl;
@useResult
$Res call({
 GraphLayoutSetting layout, bool detailedCards, bool groupStacks, double cardWidth, bool showMinimap, List<RevsetConfiguration> revsetConfigs, String revsetDefault
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
@pragma('vm:prefer-inline') @override $Res call({Object? layout = null,Object? detailedCards = null,Object? groupStacks = null,Object? cardWidth = null,Object? showMinimap = null,Object? revsetConfigs = null,Object? revsetDefault = null,}) {
  return _then(GraphSettings(
layout: null == layout ? _self.layout : layout // ignore: cast_nullable_to_non_nullable
as GraphLayoutSetting,detailedCards: null == detailedCards ? _self.detailedCards : detailedCards // ignore: cast_nullable_to_non_nullable
as bool,groupStacks: null == groupStacks ? _self.groupStacks : groupStacks // ignore: cast_nullable_to_non_nullable
as bool,cardWidth: null == cardWidth ? _self.cardWidth : cardWidth // ignore: cast_nullable_to_non_nullable
as double,showMinimap: null == showMinimap ? _self.showMinimap : showMinimap // ignore: cast_nullable_to_non_nullable
as bool,revsetConfigs: null == revsetConfigs ? _self.revsetConfigs : revsetConfigs // ignore: cast_nullable_to_non_nullable
as List<RevsetConfiguration>,revsetDefault: null == revsetDefault ? _self.revsetDefault : revsetDefault // ignore: cast_nullable_to_non_nullable
as String,
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( GraphLayoutSetting layout,  bool detailedCards,  bool groupStacks,  double cardWidth,  bool showMinimap,  List<RevsetConfiguration> revsetConfigs,  String revsetDefault)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _GraphSettings() when $default != null:
return $default(_that.layout,_that.detailedCards,_that.groupStacks,_that.cardWidth,_that.showMinimap,_that.revsetConfigs,_that.revsetDefault);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( GraphLayoutSetting layout,  bool detailedCards,  bool groupStacks,  double cardWidth,  bool showMinimap,  List<RevsetConfiguration> revsetConfigs,  String revsetDefault)  $default,) {final _that = this;
switch (_that) {
case _GraphSettings():
return $default(_that.layout,_that.detailedCards,_that.groupStacks,_that.cardWidth,_that.showMinimap,_that.revsetConfigs,_that.revsetDefault);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( GraphLayoutSetting layout,  bool detailedCards,  bool groupStacks,  double cardWidth,  bool showMinimap,  List<RevsetConfiguration> revsetConfigs,  String revsetDefault)?  $default,) {final _that = this;
switch (_that) {
case _GraphSettings() when $default != null:
return $default(_that.layout,_that.detailedCards,_that.groupStacks,_that.cardWidth,_that.showMinimap,_that.revsetConfigs,_that.revsetDefault);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _GraphSettings extends GraphSettings {
  const _GraphSettings({this.layout = GraphLayoutSetting.free, this.detailedCards = true, this.groupStacks = true, this.cardWidth = 240, this.showMinimap = true,  List<RevsetConfiguration> revsetConfigs = const <RevsetConfiguration>[], this.revsetDefault = revsetDefaultLog}): _revsetConfigs = revsetConfigs,super._();
  factory _GraphSettings.fromJson(Map<String, dynamic> json) => _$GraphSettingsFromJson(json);

/// The layout mode; [GraphLayoutSetting.free] by default.
@override@JsonKey() final  GraphLayoutSetting layout;
/// Detailed (62 px) or compact (40 px) cards; detailed by default.
@override@JsonKey() final  bool detailedCards;
/// Whether linear runs of changes collapse into stack cards; on by default.
@override@JsonKey() final  bool groupStacks;
/// The card width, 240 by default (160–400; the app clamps it where it uses it).
@override@JsonKey() final  double cardWidth;
/// Whether the minimap shows beside the graph (Story 10.16); on by default.
@override@JsonKey() final  bool showMinimap;
/// The jj log configurations (Story 10.22), in search-menu order (the default search leads the menu, the rest keep this order); global, not per repository.
 final  List<RevsetConfiguration> _revsetConfigs;
/// The jj log configurations (Story 10.22), in search-menu order (the default search leads the menu, the rest keep this order); global, not per repository.
@override@JsonKey() List<RevsetConfiguration> get revsetConfigs {
  if (_revsetConfigs is EqualUnmodifiableListView) return _revsetConfigs;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_revsetConfigs);
}

/// The default search: `log` (the built-in `jj log`), `all` (`all()`) or a [RevsetConfiguration.id]. An id no
/// configuration has reads as `log` ([effectiveRevsetDefault]).
@override@JsonKey() final  String revsetDefault;

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
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _GraphSettings&&(identical(other.layout, layout) || other.layout == layout)&&(identical(other.detailedCards, detailedCards) || other.detailedCards == detailedCards)&&(identical(other.groupStacks, groupStacks) || other.groupStacks == groupStacks)&&(identical(other.cardWidth, cardWidth) || other.cardWidth == cardWidth)&&(identical(other.showMinimap, showMinimap) || other.showMinimap == showMinimap)&&const DeepCollectionEquality().equals(other.revsetConfigs, _revsetConfigs)&&(identical(other.revsetDefault, revsetDefault) || other.revsetDefault == revsetDefault));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,layout,detailedCards,groupStacks,cardWidth,showMinimap,const DeepCollectionEquality().hash(_revsetConfigs),revsetDefault);
}

@override
String toString() {
    return 'GraphSettings(layout: $layout, detailedCards: $detailedCards, groupStacks: $groupStacks, cardWidth: $cardWidth, showMinimap: $showMinimap, revsetConfigs: $revsetConfigs, revsetDefault: $revsetDefault)';
}


}

/// @nodoc
abstract mixin class _$GraphSettingsCopyWith<$Res> implements $GraphSettingsCopyWith<$Res> {
  factory _$GraphSettingsCopyWith(_GraphSettings value, $Res Function(_GraphSettings) _then) = __$GraphSettingsCopyWithImpl;
@override @useResult
$Res call({
 GraphLayoutSetting layout, bool detailedCards, bool groupStacks, double cardWidth, bool showMinimap, List<RevsetConfiguration> revsetConfigs, String revsetDefault
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
@override @pragma('vm:prefer-inline') $Res call({Object? layout = null,Object? detailedCards = null,Object? groupStacks = null,Object? cardWidth = null,Object? showMinimap = null,Object? revsetConfigs = null,Object? revsetDefault = null,}) {
  return _then(_GraphSettings(
layout: null == layout ? _self.layout : layout // ignore: cast_nullable_to_non_nullable
as GraphLayoutSetting,detailedCards: null == detailedCards ? _self.detailedCards : detailedCards // ignore: cast_nullable_to_non_nullable
as bool,groupStacks: null == groupStacks ? _self.groupStacks : groupStacks // ignore: cast_nullable_to_non_nullable
as bool,cardWidth: null == cardWidth ? _self.cardWidth : cardWidth // ignore: cast_nullable_to_non_nullable
as double,showMinimap: null == showMinimap ? _self.showMinimap : showMinimap // ignore: cast_nullable_to_non_nullable
as bool,revsetConfigs: null == revsetConfigs ? _self._revsetConfigs : revsetConfigs // ignore: cast_nullable_to_non_nullable
as List<RevsetConfiguration>,revsetDefault: null == revsetDefault ? _self.revsetDefault : revsetDefault // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$RevsetConfiguration {

/// Its key, stable across renames.
 String get id;/// The name the search menu and the window show; may be empty ("Unnamed").
 String get name;/// How [rules] combine; `&` by default.
 RevsetCombine get op;/// The rules, in order.
 List<RevsetRule> get rules;
/// Create a copy of RevsetConfiguration
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RevsetConfigurationCopyWith<RevsetConfiguration> get copyWith => _$RevsetConfigurationCopyWithImpl<RevsetConfiguration>(this as RevsetConfiguration, _$identity);

  /// Serializes this RevsetConfiguration to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as RevsetConfiguration;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RevsetConfiguration&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.op, _this.op) || other.op == _this.op)&&const DeepCollectionEquality().equals(other.rules, _this.rules));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as RevsetConfiguration;
  return Object.hash(runtimeType,_this.id,_this.name,_this.op,const DeepCollectionEquality().hash(_this.rules));
}

@override
String toString() {
  final _this = this as RevsetConfiguration;
  return 'RevsetConfiguration(id: ${_this.id}, name: ${_this.name}, op: ${_this.op}, rules: ${_this.rules})';
}


}

/// @nodoc
abstract mixin class $RevsetConfigurationCopyWith<$Res>  {
  factory $RevsetConfigurationCopyWith(RevsetConfiguration value, $Res Function(RevsetConfiguration) _then) = _$RevsetConfigurationCopyWithImpl;
@useResult
$Res call({
 String id, String name, RevsetCombine op, List<RevsetRule> rules
});




}
/// @nodoc
class _$RevsetConfigurationCopyWithImpl<$Res>
    implements $RevsetConfigurationCopyWith<$Res> {
  _$RevsetConfigurationCopyWithImpl(this._self, this._then);

  final RevsetConfiguration _self;
  final $Res Function(RevsetConfiguration) _then;

/// Create a copy of RevsetConfiguration
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? op = null,Object? rules = null,}) {
  return _then(RevsetConfiguration(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,op: null == op ? _self.op : op // ignore: cast_nullable_to_non_nullable
as RevsetCombine,rules: null == rules ? _self.rules : rules // ignore: cast_nullable_to_non_nullable
as List<RevsetRule>,
  ));
}

}


/// Adds pattern-matching-related methods to [RevsetConfiguration].
extension RevsetConfigurationPatterns on RevsetConfiguration {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RevsetConfiguration value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RevsetConfiguration() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RevsetConfiguration value)  $default,){
final _that = this;
switch (_that) {
case _RevsetConfiguration():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RevsetConfiguration value)?  $default,){
final _that = this;
switch (_that) {
case _RevsetConfiguration() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  RevsetCombine op,  List<RevsetRule> rules)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RevsetConfiguration() when $default != null:
return $default(_that.id,_that.name,_that.op,_that.rules);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  RevsetCombine op,  List<RevsetRule> rules)  $default,) {final _that = this;
switch (_that) {
case _RevsetConfiguration():
return $default(_that.id,_that.name,_that.op,_that.rules);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  RevsetCombine op,  List<RevsetRule> rules)?  $default,) {final _that = this;
switch (_that) {
case _RevsetConfiguration() when $default != null:
return $default(_that.id,_that.name,_that.op,_that.rules);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _RevsetConfiguration implements RevsetConfiguration {
  const _RevsetConfiguration({required this.id, this.name = '', this.op = RevsetCombine.and,  List<RevsetRule> rules = const <RevsetRule>[]}): _rules = rules;
  factory _RevsetConfiguration.fromJson(Map<String, dynamic> json) => _$RevsetConfigurationFromJson(json);

/// Its key, stable across renames.
@override final  String id;
/// The name the search menu and the window show; may be empty ("Unnamed").
@override@JsonKey() final  String name;
/// How [rules] combine; `&` by default.
@override@JsonKey() final  RevsetCombine op;
/// The rules, in order.
 final  List<RevsetRule> _rules;
/// The rules, in order.
@override@JsonKey() List<RevsetRule> get rules {
  if (_rules is EqualUnmodifiableListView) return _rules;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_rules);
}


/// Create a copy of RevsetConfiguration
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RevsetConfigurationCopyWith<_RevsetConfiguration> get copyWith => __$RevsetConfigurationCopyWithImpl<_RevsetConfiguration>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RevsetConfigurationToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _RevsetConfiguration&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.op, op) || other.op == op)&&const DeepCollectionEquality().equals(other.rules, _rules));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,id,name,op,const DeepCollectionEquality().hash(_rules));
}

@override
String toString() {
    return 'RevsetConfiguration(id: $id, name: $name, op: $op, rules: $rules)';
}


}

/// @nodoc
abstract mixin class _$RevsetConfigurationCopyWith<$Res> implements $RevsetConfigurationCopyWith<$Res> {
  factory _$RevsetConfigurationCopyWith(_RevsetConfiguration value, $Res Function(_RevsetConfiguration) _then) = __$RevsetConfigurationCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, RevsetCombine op, List<RevsetRule> rules
});




}
/// @nodoc
class __$RevsetConfigurationCopyWithImpl<$Res>
    implements _$RevsetConfigurationCopyWith<$Res> {
  __$RevsetConfigurationCopyWithImpl(this._self, this._then);

  final _RevsetConfiguration _self;
  final $Res Function(_RevsetConfiguration) _then;

/// Create a copy of RevsetConfiguration
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? op = null,Object? rules = null,}) {
  return _then(_RevsetConfiguration(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,op: null == op ? _self.op : op // ignore: cast_nullable_to_non_nullable
as RevsetCombine,rules: null == rules ? _self._rules : rules // ignore: cast_nullable_to_non_nullable
as List<RevsetRule>,
  ));
}


}


/// @nodoc
mixin _$RevsetRule {

/// The revset function.
 RevsetRuleFunction get fn;/// The match mode; ignored for `mine`.
 RevsetRuleMode get mode;/// The value; ignored for `mine`. A blank value drops the rule from the expression.
 String get value;/// Case-insensitive (`-i`); ignored for `mine` and `files`.
 bool get ci;/// Negated (`~`).
 bool get not;
/// Create a copy of RevsetRule
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RevsetRuleCopyWith<RevsetRule> get copyWith => _$RevsetRuleCopyWithImpl<RevsetRule>(this as RevsetRule, _$identity);

  /// Serializes this RevsetRule to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as RevsetRule;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RevsetRule&&(identical(other.fn, _this.fn) || other.fn == _this.fn)&&(identical(other.mode, _this.mode) || other.mode == _this.mode)&&(identical(other.value, _this.value) || other.value == _this.value)&&(identical(other.ci, _this.ci) || other.ci == _this.ci)&&(identical(other.not, _this.not) || other.not == _this.not));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as RevsetRule;
  return Object.hash(runtimeType,_this.fn,_this.mode,_this.value,_this.ci,_this.not);
}

@override
String toString() {
  final _this = this as RevsetRule;
  return 'RevsetRule(fn: ${_this.fn}, mode: ${_this.mode}, value: ${_this.value}, ci: ${_this.ci}, not: ${_this.not})';
}


}

/// @nodoc
abstract mixin class $RevsetRuleCopyWith<$Res>  {
  factory $RevsetRuleCopyWith(RevsetRule value, $Res Function(RevsetRule) _then) = _$RevsetRuleCopyWithImpl;
@useResult
$Res call({
 RevsetRuleFunction fn, RevsetRuleMode mode, String value, bool ci, bool not
});




}
/// @nodoc
class _$RevsetRuleCopyWithImpl<$Res>
    implements $RevsetRuleCopyWith<$Res> {
  _$RevsetRuleCopyWithImpl(this._self, this._then);

  final RevsetRule _self;
  final $Res Function(RevsetRule) _then;

/// Create a copy of RevsetRule
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? fn = null,Object? mode = null,Object? value = null,Object? ci = null,Object? not = null,}) {
  return _then(RevsetRule(
fn: null == fn ? _self.fn : fn // ignore: cast_nullable_to_non_nullable
as RevsetRuleFunction,mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as RevsetRuleMode,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String,ci: null == ci ? _self.ci : ci // ignore: cast_nullable_to_non_nullable
as bool,not: null == not ? _self.not : not // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [RevsetRule].
extension RevsetRulePatterns on RevsetRule {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _RevsetRule value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _RevsetRule() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _RevsetRule value)  $default,){
final _that = this;
switch (_that) {
case _RevsetRule():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _RevsetRule value)?  $default,){
final _that = this;
switch (_that) {
case _RevsetRule() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( RevsetRuleFunction fn,  RevsetRuleMode mode,  String value,  bool ci,  bool not)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _RevsetRule() when $default != null:
return $default(_that.fn,_that.mode,_that.value,_that.ci,_that.not);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( RevsetRuleFunction fn,  RevsetRuleMode mode,  String value,  bool ci,  bool not)  $default,) {final _that = this;
switch (_that) {
case _RevsetRule():
return $default(_that.fn,_that.mode,_that.value,_that.ci,_that.not);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( RevsetRuleFunction fn,  RevsetRuleMode mode,  String value,  bool ci,  bool not)?  $default,) {final _that = this;
switch (_that) {
case _RevsetRule() when $default != null:
return $default(_that.fn,_that.mode,_that.value,_that.ci,_that.not);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _RevsetRule implements RevsetRule {
  const _RevsetRule({required this.fn, this.mode = RevsetRuleMode.substring, this.value = '', this.ci = false, this.not = false});
  factory _RevsetRule.fromJson(Map<String, dynamic> json) => _$RevsetRuleFromJson(json);

/// The revset function.
@override final  RevsetRuleFunction fn;
/// The match mode; ignored for `mine`.
@override@JsonKey() final  RevsetRuleMode mode;
/// The value; ignored for `mine`. A blank value drops the rule from the expression.
@override@JsonKey() final  String value;
/// Case-insensitive (`-i`); ignored for `mine` and `files`.
@override@JsonKey() final  bool ci;
/// Negated (`~`).
@override@JsonKey() final  bool not;

/// Create a copy of RevsetRule
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RevsetRuleCopyWith<_RevsetRule> get copyWith => __$RevsetRuleCopyWithImpl<_RevsetRule>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RevsetRuleToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _RevsetRule&&(identical(other.fn, fn) || other.fn == fn)&&(identical(other.mode, mode) || other.mode == mode)&&(identical(other.value, value) || other.value == value)&&(identical(other.ci, ci) || other.ci == ci)&&(identical(other.not, not) || other.not == not));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,fn,mode,value,ci,not);
}

@override
String toString() {
    return 'RevsetRule(fn: $fn, mode: $mode, value: $value, ci: $ci, not: $not)';
}


}

/// @nodoc
abstract mixin class _$RevsetRuleCopyWith<$Res> implements $RevsetRuleCopyWith<$Res> {
  factory _$RevsetRuleCopyWith(_RevsetRule value, $Res Function(_RevsetRule) _then) = __$RevsetRuleCopyWithImpl;
@override @useResult
$Res call({
 RevsetRuleFunction fn, RevsetRuleMode mode, String value, bool ci, bool not
});




}
/// @nodoc
class __$RevsetRuleCopyWithImpl<$Res>
    implements _$RevsetRuleCopyWith<$Res> {
  __$RevsetRuleCopyWithImpl(this._self, this._then);

  final _RevsetRule _self;
  final $Res Function(_RevsetRule) _then;

/// Create a copy of RevsetRule
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? fn = null,Object? mode = null,Object? value = null,Object? ci = null,Object? not = null,}) {
  return _then(_RevsetRule(
fn: null == fn ? _self.fn : fn // ignore: cast_nullable_to_non_nullable
as RevsetRuleFunction,mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as RevsetRuleMode,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String,ci: null == ci ? _self.ci : ci // ignore: cast_nullable_to_non_nullable
as bool,not: null == not ? _self.not : not // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
