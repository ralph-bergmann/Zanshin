// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';

part 'graph_settings.freezed.dart';
part 'graph_settings.g.dart';

/// The graph's layout mode (Story 10.7): Free (rows follow commit time) or Compact (rows = dependency depth).
enum GraphLayoutSetting {
  /// Rows follow commit time (the default).
  free,

  /// Rows = dependency depth.
  compact,
}

/// The graph's View options (Story 10.7 item 7), app-global: the layout, the card detail, stack grouping and the card
/// width.
@freezed
abstract class GraphSettings with _$GraphSettings {
  /// Creates graph settings; omitted fields take the design's defaults.
  const factory GraphSettings({
    /// The layout mode; [GraphLayoutSetting.free] by default.
    @Default(GraphLayoutSetting.free) GraphLayoutSetting layout,

    /// Detailed (62 px) or compact (40 px) cards; detailed by default.
    @Default(true) bool detailedCards,

    /// Whether linear runs of changes collapse into stack cards; on by default.
    @Default(true) bool groupStacks,

    /// The card width, 240 by default (160–400; the app clamps it where it uses it).
    @Default(240) double cardWidth,
  }) = _GraphSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory GraphSettings.fromJson(Map<String, Object?> json) => _$GraphSettingsFromJson(json);
}
