// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';

part 'layout_settings.freezed.dart';
part 'layout_settings.g.dart';

/// The project window's remembered island widths (decisions 16.22, 16.42 (l); Story 11.3): the widths the user
/// dragged at the inspector's and the pinned panels' resize edges, one for the inspector and one shared by every
/// left panel, app-wide. They are written when a drag ends (and after key steps), never for the narrower width a
/// small window allows, so a temporarily narrow window leaves them as they are.
@freezed
abstract class LayoutSettings with _$LayoutSettings {
  /// Creates layout settings; omitted widths take the DS defaults (DS tokens/spacing.css:42).
  const factory LayoutSettings({
    /// The inspector's remembered width, `--inspector-w` 460 by default (380–720).
    @Default(460) double inspectorWidth,

    /// The left panels' remembered width, `--panel-w` 300 by default (240–440).
    @Default(300) double panelWidth,
  }) = _LayoutSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory LayoutSettings.fromJson(Map<String, Object?> json) => _$LayoutSettingsFromJson(json);
}
