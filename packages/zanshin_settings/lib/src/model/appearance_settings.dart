// SPDX-License-Identifier: MIT

import 'package:flutter/material.dart' show ThemeMode;
import 'package:freezed_annotation/freezed_annotation.dart';

part 'appearance_settings.freezed.dart';
part 'appearance_settings.g.dart';

/// Look-and-feel settings.
@freezed
abstract class AppearanceSettings with _$AppearanceSettings {
  /// Creates appearance settings; an omitted [themeMode] follows the OS.
  const factory AppearanceSettings({
    /// The user's day/night choice; `system` follows the OS.
    @Default(ThemeMode.system) ThemeMode themeMode,
  }) = _AppearanceSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory AppearanceSettings.fromJson(Map<String, Object?> json) => _$AppearanceSettingsFromJson(json);
}
