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
 bool get hideControls;/// The inspector's diff layout (Story 10.24); [DiffLayoutSetting.unified] by default.
@JsonKey(unknownEnumValue: DiffLayoutSetting.unified) DiffLayoutSetting get diffLayout;/// Settings › General › Diffs › "Changed words" (Story 5.14): whether the diff marks the words that changed
/// inside a line. It changes only how a loaded diff is drawn; on by default.
 bool get diffWordMarks;/// The diff's whitespace mode (Story 10.33); [DiffWhitespaceSetting.showAll] by default.
@JsonKey(unknownEnumValue: DiffWhitespaceSetting.showAll) DiffWhitespaceSetting get diffWhitespace;/// The inspector's file list (Story 10.39); [DiffFileListSetting.flat] by default.
@JsonKey(unknownEnumValue: DiffFileListSetting.flat) DiffFileListSetting get diffFileList;/// Settings › General › Editor (Story 10.39): what Open in Editor starts — null for none, `idea`, `code` or
/// `zed` for that launcher, any other value a command line that holds `{file}` (and maybe `{line}`).
 String? get editor;/// The file masks of the inspector and the operation view (Story 10.49), newest first; one list for the app. A file without the key gets
/// [defaultFileMasks]; an empty saved list stays empty.
 List<FileMask> get fileMasks;/// Settings › General › Diffs › "Code font" (Story 10.50): the font family of the code in diffs and the config
/// file editor; null for the built-in JetBrains Mono. A family that is not installed stays saved.
 String? get codeFont;/// Settings › General › Diffs › "Code size" (Story 10.50): the code's size in points, before the app zoom; 11 by
/// default.
 int get codeSize;
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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GeneralSettings&&(identical(other.hideControls, _this.hideControls) || other.hideControls == _this.hideControls)&&(identical(other.diffLayout, _this.diffLayout) || other.diffLayout == _this.diffLayout)&&(identical(other.diffWordMarks, _this.diffWordMarks) || other.diffWordMarks == _this.diffWordMarks)&&(identical(other.diffWhitespace, _this.diffWhitespace) || other.diffWhitespace == _this.diffWhitespace)&&(identical(other.diffFileList, _this.diffFileList) || other.diffFileList == _this.diffFileList)&&(identical(other.editor, _this.editor) || other.editor == _this.editor)&&const DeepCollectionEquality().equals(other.fileMasks, _this.fileMasks)&&(identical(other.codeFont, _this.codeFont) || other.codeFont == _this.codeFont)&&(identical(other.codeSize, _this.codeSize) || other.codeSize == _this.codeSize));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as GeneralSettings;
  return Object.hash(runtimeType,_this.hideControls,_this.diffLayout,_this.diffWordMarks,_this.diffWhitespace,_this.diffFileList,_this.editor,const DeepCollectionEquality().hash(_this.fileMasks),_this.codeFont,_this.codeSize);
}

@override
String toString() {
  final _this = this as GeneralSettings;
  return 'GeneralSettings(hideControls: ${_this.hideControls}, diffLayout: ${_this.diffLayout}, diffWordMarks: ${_this.diffWordMarks}, diffWhitespace: ${_this.diffWhitespace}, diffFileList: ${_this.diffFileList}, editor: ${_this.editor}, fileMasks: ${_this.fileMasks}, codeFont: ${_this.codeFont}, codeSize: ${_this.codeSize})';
}


}

/// @nodoc
abstract mixin class $GeneralSettingsCopyWith<$Res>  {
  factory $GeneralSettingsCopyWith(GeneralSettings value, $Res Function(GeneralSettings) _then) = _$GeneralSettingsCopyWithImpl;
@useResult
$Res call({
 bool hideControls,@JsonKey(unknownEnumValue: DiffLayoutSetting.unified) DiffLayoutSetting diffLayout, bool diffWordMarks,@JsonKey(unknownEnumValue: DiffWhitespaceSetting.showAll) DiffWhitespaceSetting diffWhitespace,@JsonKey(unknownEnumValue: DiffFileListSetting.flat) DiffFileListSetting diffFileList, String? editor, List<FileMask> fileMasks, String? codeFont, int codeSize
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
@pragma('vm:prefer-inline') @override $Res call({Object? hideControls = null,Object? diffLayout = null,Object? diffWordMarks = null,Object? diffWhitespace = null,Object? diffFileList = null,Object? editor = freezed,Object? fileMasks = null,Object? codeFont = freezed,Object? codeSize = null,}) {
  return _then(GeneralSettings(
hideControls: null == hideControls ? _self.hideControls : hideControls // ignore: cast_nullable_to_non_nullable
as bool,diffLayout: null == diffLayout ? _self.diffLayout : diffLayout // ignore: cast_nullable_to_non_nullable
as DiffLayoutSetting,diffWordMarks: null == diffWordMarks ? _self.diffWordMarks : diffWordMarks // ignore: cast_nullable_to_non_nullable
as bool,diffWhitespace: null == diffWhitespace ? _self.diffWhitespace : diffWhitespace // ignore: cast_nullable_to_non_nullable
as DiffWhitespaceSetting,diffFileList: null == diffFileList ? _self.diffFileList : diffFileList // ignore: cast_nullable_to_non_nullable
as DiffFileListSetting,editor: freezed == editor ? _self.editor : editor // ignore: cast_nullable_to_non_nullable
as String?,fileMasks: null == fileMasks ? _self.fileMasks : fileMasks // ignore: cast_nullable_to_non_nullable
as List<FileMask>,codeFont: freezed == codeFont ? _self.codeFont : codeFont // ignore: cast_nullable_to_non_nullable
as String?,codeSize: null == codeSize ? _self.codeSize : codeSize // ignore: cast_nullable_to_non_nullable
as int,
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool hideControls, @JsonKey(unknownEnumValue: DiffLayoutSetting.unified)  DiffLayoutSetting diffLayout,  bool diffWordMarks, @JsonKey(unknownEnumValue: DiffWhitespaceSetting.showAll)  DiffWhitespaceSetting diffWhitespace, @JsonKey(unknownEnumValue: DiffFileListSetting.flat)  DiffFileListSetting diffFileList,  String? editor,  List<FileMask> fileMasks,  String? codeFont,  int codeSize)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _GeneralSettings() when $default != null:
return $default(_that.hideControls,_that.diffLayout,_that.diffWordMarks,_that.diffWhitespace,_that.diffFileList,_that.editor,_that.fileMasks,_that.codeFont,_that.codeSize);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool hideControls, @JsonKey(unknownEnumValue: DiffLayoutSetting.unified)  DiffLayoutSetting diffLayout,  bool diffWordMarks, @JsonKey(unknownEnumValue: DiffWhitespaceSetting.showAll)  DiffWhitespaceSetting diffWhitespace, @JsonKey(unknownEnumValue: DiffFileListSetting.flat)  DiffFileListSetting diffFileList,  String? editor,  List<FileMask> fileMasks,  String? codeFont,  int codeSize)  $default,) {final _that = this;
switch (_that) {
case _GeneralSettings():
return $default(_that.hideControls,_that.diffLayout,_that.diffWordMarks,_that.diffWhitespace,_that.diffFileList,_that.editor,_that.fileMasks,_that.codeFont,_that.codeSize);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool hideControls, @JsonKey(unknownEnumValue: DiffLayoutSetting.unified)  DiffLayoutSetting diffLayout,  bool diffWordMarks, @JsonKey(unknownEnumValue: DiffWhitespaceSetting.showAll)  DiffWhitespaceSetting diffWhitespace, @JsonKey(unknownEnumValue: DiffFileListSetting.flat)  DiffFileListSetting diffFileList,  String? editor,  List<FileMask> fileMasks,  String? codeFont,  int codeSize)?  $default,) {final _that = this;
switch (_that) {
case _GeneralSettings() when $default != null:
return $default(_that.hideControls,_that.diffLayout,_that.diffWordMarks,_that.diffWhitespace,_that.diffFileList,_that.editor,_that.fileMasks,_that.codeFont,_that.codeSize);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _GeneralSettings implements GeneralSettings {
  const _GeneralSettings({this.hideControls = true, @JsonKey(unknownEnumValue: DiffLayoutSetting.unified) this.diffLayout = DiffLayoutSetting.unified, this.diffWordMarks = true, @JsonKey(unknownEnumValue: DiffWhitespaceSetting.showAll) this.diffWhitespace = DiffWhitespaceSetting.showAll, @JsonKey(unknownEnumValue: DiffFileListSetting.flat) this.diffFileList = DiffFileListSetting.flat, this.editor,  List<FileMask> fileMasks = defaultFileMasks, this.codeFont, this.codeSize = 11}): _fileMasks = fileMasks;
  factory _GeneralSettings.fromJson(Map<String, dynamic> json) => _$GeneralSettingsFromJson(json);

/// "While you scroll: Hide controls" — the floating controls step aside while the graph scrolls (epics.md Story
/// 11.3 item 8); on by default.
@override@JsonKey() final  bool hideControls;
/// The inspector's diff layout (Story 10.24); [DiffLayoutSetting.unified] by default.
@override@JsonKey(unknownEnumValue: DiffLayoutSetting.unified) final  DiffLayoutSetting diffLayout;
/// Settings › General › Diffs › "Changed words" (Story 5.14): whether the diff marks the words that changed
/// inside a line. It changes only how a loaded diff is drawn; on by default.
@override@JsonKey() final  bool diffWordMarks;
/// The diff's whitespace mode (Story 10.33); [DiffWhitespaceSetting.showAll] by default.
@override@JsonKey(unknownEnumValue: DiffWhitespaceSetting.showAll) final  DiffWhitespaceSetting diffWhitespace;
/// The inspector's file list (Story 10.39); [DiffFileListSetting.flat] by default.
@override@JsonKey(unknownEnumValue: DiffFileListSetting.flat) final  DiffFileListSetting diffFileList;
/// Settings › General › Editor (Story 10.39): what Open in Editor starts — null for none, `idea`, `code` or
/// `zed` for that launcher, any other value a command line that holds `{file}` (and maybe `{line}`).
@override final  String? editor;
/// The file masks of the inspector and the operation view (Story 10.49), newest first; one list for the app. A file without the key gets
/// [defaultFileMasks]; an empty saved list stays empty.
 final  List<FileMask> _fileMasks;
/// The file masks of the inspector and the operation view (Story 10.49), newest first; one list for the app. A file without the key gets
/// [defaultFileMasks]; an empty saved list stays empty.
@override@JsonKey() List<FileMask> get fileMasks {
  if (_fileMasks is EqualUnmodifiableListView) return _fileMasks;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_fileMasks);
}

/// Settings › General › Diffs › "Code font" (Story 10.50): the font family of the code in diffs and the config
/// file editor; null for the built-in JetBrains Mono. A family that is not installed stays saved.
@override final  String? codeFont;
/// Settings › General › Diffs › "Code size" (Story 10.50): the code's size in points, before the app zoom; 11 by
/// default.
@override@JsonKey() final  int codeSize;

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
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _GeneralSettings&&(identical(other.hideControls, hideControls) || other.hideControls == hideControls)&&(identical(other.diffLayout, diffLayout) || other.diffLayout == diffLayout)&&(identical(other.diffWordMarks, diffWordMarks) || other.diffWordMarks == diffWordMarks)&&(identical(other.diffWhitespace, diffWhitespace) || other.diffWhitespace == diffWhitespace)&&(identical(other.diffFileList, diffFileList) || other.diffFileList == diffFileList)&&(identical(other.editor, editor) || other.editor == editor)&&const DeepCollectionEquality().equals(other.fileMasks, _fileMasks)&&(identical(other.codeFont, codeFont) || other.codeFont == codeFont)&&(identical(other.codeSize, codeSize) || other.codeSize == codeSize));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,hideControls,diffLayout,diffWordMarks,diffWhitespace,diffFileList,editor,const DeepCollectionEquality().hash(_fileMasks),codeFont,codeSize);
}

@override
String toString() {
    return 'GeneralSettings(hideControls: $hideControls, diffLayout: $diffLayout, diffWordMarks: $diffWordMarks, diffWhitespace: $diffWhitespace, diffFileList: $diffFileList, editor: $editor, fileMasks: $fileMasks, codeFont: $codeFont, codeSize: $codeSize)';
}


}

/// @nodoc
abstract mixin class _$GeneralSettingsCopyWith<$Res> implements $GeneralSettingsCopyWith<$Res> {
  factory _$GeneralSettingsCopyWith(_GeneralSettings value, $Res Function(_GeneralSettings) _then) = __$GeneralSettingsCopyWithImpl;
@override @useResult
$Res call({
 bool hideControls,@JsonKey(unknownEnumValue: DiffLayoutSetting.unified) DiffLayoutSetting diffLayout, bool diffWordMarks,@JsonKey(unknownEnumValue: DiffWhitespaceSetting.showAll) DiffWhitespaceSetting diffWhitespace,@JsonKey(unknownEnumValue: DiffFileListSetting.flat) DiffFileListSetting diffFileList, String? editor, List<FileMask> fileMasks, String? codeFont, int codeSize
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
@override @pragma('vm:prefer-inline') $Res call({Object? hideControls = null,Object? diffLayout = null,Object? diffWordMarks = null,Object? diffWhitespace = null,Object? diffFileList = null,Object? editor = freezed,Object? fileMasks = null,Object? codeFont = freezed,Object? codeSize = null,}) {
  return _then(_GeneralSettings(
hideControls: null == hideControls ? _self.hideControls : hideControls // ignore: cast_nullable_to_non_nullable
as bool,diffLayout: null == diffLayout ? _self.diffLayout : diffLayout // ignore: cast_nullable_to_non_nullable
as DiffLayoutSetting,diffWordMarks: null == diffWordMarks ? _self.diffWordMarks : diffWordMarks // ignore: cast_nullable_to_non_nullable
as bool,diffWhitespace: null == diffWhitespace ? _self.diffWhitespace : diffWhitespace // ignore: cast_nullable_to_non_nullable
as DiffWhitespaceSetting,diffFileList: null == diffFileList ? _self.diffFileList : diffFileList // ignore: cast_nullable_to_non_nullable
as DiffFileListSetting,editor: freezed == editor ? _self.editor : editor // ignore: cast_nullable_to_non_nullable
as String?,fileMasks: null == fileMasks ? _self._fileMasks : fileMasks // ignore: cast_nullable_to_non_nullable
as List<FileMask>,codeFont: freezed == codeFont ? _self.codeFont : codeFont // ignore: cast_nullable_to_non_nullable
as String?,codeSize: null == codeSize ? _self.codeSize : codeSize // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$FileMask {

/// The masks as typed, e.g. `*.g.dart, *.freezed.dart`.
 String get mask;/// Whether the entry hides the files it matches; off by default.
 bool get active;
/// Create a copy of FileMask
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FileMaskCopyWith<FileMask> get copyWith => _$FileMaskCopyWithImpl<FileMask>(this as FileMask, _$identity);

  /// Serializes this FileMask to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as FileMask;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FileMask&&(identical(other.mask, _this.mask) || other.mask == _this.mask)&&(identical(other.active, _this.active) || other.active == _this.active));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as FileMask;
  return Object.hash(runtimeType,_this.mask,_this.active);
}

@override
String toString() {
  final _this = this as FileMask;
  return 'FileMask(mask: ${_this.mask}, active: ${_this.active})';
}


}

/// @nodoc
abstract mixin class $FileMaskCopyWith<$Res>  {
  factory $FileMaskCopyWith(FileMask value, $Res Function(FileMask) _then) = _$FileMaskCopyWithImpl;
@useResult
$Res call({
 String mask, bool active
});




}
/// @nodoc
class _$FileMaskCopyWithImpl<$Res>
    implements $FileMaskCopyWith<$Res> {
  _$FileMaskCopyWithImpl(this._self, this._then);

  final FileMask _self;
  final $Res Function(FileMask) _then;

/// Create a copy of FileMask
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? mask = null,Object? active = null,}) {
  return _then(FileMask(
mask: null == mask ? _self.mask : mask // ignore: cast_nullable_to_non_nullable
as String,active: null == active ? _self.active : active // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [FileMask].
extension FileMaskPatterns on FileMask {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _FileMask value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _FileMask() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _FileMask value)  $default,){
final _that = this;
switch (_that) {
case _FileMask():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _FileMask value)?  $default,){
final _that = this;
switch (_that) {
case _FileMask() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String mask,  bool active)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _FileMask() when $default != null:
return $default(_that.mask,_that.active);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String mask,  bool active)  $default,) {final _that = this;
switch (_that) {
case _FileMask():
return $default(_that.mask,_that.active);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String mask,  bool active)?  $default,) {final _that = this;
switch (_that) {
case _FileMask() when $default != null:
return $default(_that.mask,_that.active);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _FileMask implements FileMask {
  const _FileMask({required this.mask, this.active = false});
  factory _FileMask.fromJson(Map<String, dynamic> json) => _$FileMaskFromJson(json);

/// The masks as typed, e.g. `*.g.dart, *.freezed.dart`.
@override final  String mask;
/// Whether the entry hides the files it matches; off by default.
@override@JsonKey() final  bool active;

/// Create a copy of FileMask
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FileMaskCopyWith<_FileMask> get copyWith => __$FileMaskCopyWithImpl<_FileMask>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FileMaskToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _FileMask&&(identical(other.mask, mask) || other.mask == mask)&&(identical(other.active, active) || other.active == active));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,mask,active);
}

@override
String toString() {
    return 'FileMask(mask: $mask, active: $active)';
}


}

/// @nodoc
abstract mixin class _$FileMaskCopyWith<$Res> implements $FileMaskCopyWith<$Res> {
  factory _$FileMaskCopyWith(_FileMask value, $Res Function(_FileMask) _then) = __$FileMaskCopyWithImpl;
@override @useResult
$Res call({
 String mask, bool active
});




}
/// @nodoc
class __$FileMaskCopyWithImpl<$Res>
    implements _$FileMaskCopyWith<$Res> {
  __$FileMaskCopyWithImpl(this._self, this._then);

  final _FileMask _self;
  final $Res Function(_FileMask) _then;

/// Create a copy of FileMask
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? mask = null,Object? active = null,}) {
  return _then(_FileMask(
mask: null == mask ? _self.mask : mask // ignore: cast_nullable_to_non_nullable
as String,active: null == active ? _self.active : active // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
