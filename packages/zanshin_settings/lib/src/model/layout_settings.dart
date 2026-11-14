// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';

part 'layout_settings.freezed.dart';
part 'layout_settings.g.dart';

/// The project window's remembered island widths (decisions 16.22, 16.42 (l); Story 11.3): the widths the user
/// dragged at the inspector's and the pinned panels' resize edges, one for the inspector and one shared by every
/// left panel, app-wide. They are written when a drag ends (and after key steps), never for the narrower width a
/// small window allows, so a temporarily narrow window leaves them as they are.
///
/// It also remembers the inspector's split between its file list and its diff (Story 10.38): the files' share of the
/// split, one per layout, written when a divider drag ends or on reset, never per move.
@freezed
abstract class LayoutSettings with _$LayoutSettings {
  /// Creates layout settings; omitted widths take the DS defaults (DS tokens/spacing.css:42).
  const factory LayoutSettings({
    /// The inspector's remembered width, `--inspector-w` 460 by default (at least 380, no maximum).
    @Default(460) double inspectorWidth,

    /// The left panels' remembered width, `--panel-w` 300 by default (at least 240, no maximum).
    @Default(300) double panelWidth,

    /// The files' share of the inspector's split while the files sit above the diff, 0.38 by default.
    @Default(0.38) double inspectorFilesNarrow,

    /// The files' share of the inspector's split while the files sit beside the diff, 0.34 by default.
    @Default(0.34) double inspectorFilesWide,
  }) = _LayoutSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory LayoutSettings.fromJson(Map<String, Object?> json) => _$LayoutSettingsFromJson(json);
}
