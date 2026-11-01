// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';

part 'general_settings.freezed.dart';
part 'general_settings.g.dart';

/// How the inspector draws a file's diff (Story 10.24; Settings › Diffs binds it, 11.7).
enum DiffLayoutSetting {
  /// One column, removed above added (the default).
  unified,

  /// Two columns, the left side beside the right.
  sideBySide,
}

/// Settings › General (Story 11.7 builds the tab). The key `general` is Claude's proposal (Story 11.3).
@freezed
abstract class GeneralSettings with _$GeneralSettings {
  /// Creates general settings; an omitted [hideControls] is on, an omitted [diffLayout] unified.
  const factory GeneralSettings({
    /// "While you scroll: Hide controls" — the floating controls step aside while the graph scrolls (epics.md Story
    /// 11.3 item 8); on by default.
    @Default(true) bool hideControls,

    /// The inspector's diff layout (Story 10.24); [DiffLayoutSetting.unified] by default.
    @JsonKey(unknownEnumValue: DiffLayoutSetting.unified)
    @Default(DiffLayoutSetting.unified)
    DiffLayoutSetting diffLayout,
  }) = _GeneralSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory GeneralSettings.fromJson(Map<String, Object?> json) => _$GeneralSettingsFromJson(json);
}
