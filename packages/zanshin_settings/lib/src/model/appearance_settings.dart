// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

part 'appearance_settings.freezed.dart';
part 'appearance_settings.g.dart';

/// Where the accent role (selection, focus, controls) takes its colour from: Settings › General's
/// "Accent colour: Follow macOS · Zanshin" (decision 16.2; Story 11.7 builds the row).
///
/// Claude's proposal for the names (Story 11.1).
enum AccentSource {
  /// The macOS accent picks the accent family; Multicolor shows Zanshin's own moon.
  followMacOS,

  /// Always Zanshin's own moon, whatever macOS reports.
  zanshin,
}

/// Look-and-feel settings.
@freezed
abstract class AppearanceSettings with _$AppearanceSettings {
  /// Creates appearance settings; an omitted [themeMode] follows the OS, an omitted [accentSource] the macOS accent.
  const factory AppearanceSettings({
    /// The user's day/night choice; `system` follows the OS.
    @Default(ThemeMode.system) ThemeMode themeMode,

    /// Where the accent colour comes from; [AccentSource.followMacOS] by default.
    @Default(AccentSource.followMacOS) AccentSource accentSource,
  }) = _AppearanceSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory AppearanceSettings.fromJson(Map<String, Object?> json) => _$AppearanceSettingsFromJson(json);
}
