// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';

import 'appearance_settings.dart';
import 'general_settings.dart';
import 'layout_settings.dart';
import 'projects_settings.dart';

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

    /// The project window's remembered island widths.
    @Default(LayoutSettings()) LayoutSettings layout,

    /// Settings › General.
    @Default(GeneralSettings()) GeneralSettings general,

    /// The project registry (Story 11.5).
    @Default(ProjectsSettings()) ProjectsSettings projects,
  }) = _AppSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory AppSettings.fromJson(Map<String, Object?> json) => _$AppSettingsFromJson(json);
}
