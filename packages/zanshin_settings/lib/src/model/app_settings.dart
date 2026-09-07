// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';

import 'appearance_settings.dart';

part 'app_settings.freezed.dart';
part 'app_settings.g.dart';

/// Root of all persisted app settings.
///
/// Every sub-model is a field with a `@Default`, so a file written by an older
/// app version (missing keys or whole sub-objects) still loads — the missing
/// parts take their defaults. Unknown keys are ignored. Adding a setting means
/// adding a defaulted field here or on a sub-model and re-running
/// `dart run build_runner build`; no version field, no migration.
@freezed
abstract class AppSettings with _$AppSettings {
  /// Creates settings; omitted sub-models take their defaults.
  const factory AppSettings({
    /// Look-and-feel settings.
    @Default(AppearanceSettings()) AppearanceSettings appearance,
  }) = _AppSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory AppSettings.fromJson(Map<String, Object?> json) => _$AppSettingsFromJson(json);
}
