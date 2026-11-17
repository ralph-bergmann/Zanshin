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

/// How the diff treats whitespace (Story 10.33; the diff options menu and Settings › Diffs bind it).
enum DiffWhitespaceSetting {
  /// Every whitespace change shows (`jj diff`, the default).
  showAll,

  /// Changes in the amount of whitespace read as unchanged (`jj diff -b`).
  ignoreChangesInAmount,

  /// All whitespace is ignored (`jj diff -w`).
  ignoreAll,
}

/// How the inspector lists a change's files (Story 10.39; the Changes header and Settings › Diffs bind it).
enum DiffFileListSetting {
  /// One row per file in jj's order, the name first (the default).
  flat,

  /// Folders with their files, sorted by name.
  tree,
}

/// Settings › General (Story 11.7 builds the tab). The key `general` is Claude's proposal (Story 11.3).
@freezed
abstract class GeneralSettings with _$GeneralSettings {
  /// Creates general settings; an omitted [hideControls] is on, an omitted [diffLayout] unified, an omitted
  /// [diffWordMarks] on, an omitted [diffWhitespace] show all, an omitted [diffFileList] flat, an omitted [editor]
  /// none.
  const factory GeneralSettings({
    /// "While you scroll: Hide controls" — the floating controls step aside while the graph scrolls (epics.md Story
    /// 11.3 item 8); on by default.
    @Default(true) bool hideControls,

    /// The inspector's diff layout (Story 10.24); [DiffLayoutSetting.unified] by default.
    @JsonKey(unknownEnumValue: DiffLayoutSetting.unified)
    @Default(DiffLayoutSetting.unified)
    DiffLayoutSetting diffLayout,

    /// Settings › General › Diffs › "Changed words" (Story 5.14): whether the diff marks the words that changed
    /// inside a line. It changes only how a loaded diff is drawn; on by default.
    @Default(true) bool diffWordMarks,

    /// The diff's whitespace mode (Story 10.33); [DiffWhitespaceSetting.showAll] by default.
    @JsonKey(unknownEnumValue: DiffWhitespaceSetting.showAll)
    @Default(DiffWhitespaceSetting.showAll)
    DiffWhitespaceSetting diffWhitespace,

    /// The inspector's file list (Story 10.39); [DiffFileListSetting.flat] by default.
    @JsonKey(unknownEnumValue: DiffFileListSetting.flat)
    @Default(DiffFileListSetting.flat)
    DiffFileListSetting diffFileList,

    /// Settings › General › Editor (Story 10.39): what Open in Editor starts — null for none, `idea`, `code` or
    /// `zed` for that launcher, any other value a command line that holds `{file}` (and maybe `{line}`).
    String? editor,

    /// The inspector's file masks (Story 10.49), newest first; one list for the app. A file without the key gets
    /// [defaultFileMasks]; an empty saved list stays empty.
    @Default(defaultFileMasks) List<FileMask> fileMasks,
  }) = _GeneralSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory GeneralSettings.fromJson(Map<String, Object?> json) => _$GeneralSettingsFromJson(json);
}

/// The masks a fresh install starts with (Story 10.49): both unticked, so nothing is hidden until a tick.
const defaultFileMasks = <FileMask>[FileMask(mask: '*.g.dart, *.freezed.dart'), FileMask(mask: '*.lock')];

/// One entry of the file-mask list (Story 10.49): IntelliJ-style masks, comma-separated, and whether it hides files.
@freezed
abstract class FileMask with _$FileMask {
  /// Creates entry [mask]; inactive unless [active].
  const factory FileMask({
    /// The masks as typed, e.g. `*.g.dart, *.freezed.dart`.
    required String mask,

    /// Whether the entry hides the files it matches; off by default.
    @Default(false) bool active,
  }) = _FileMask;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory FileMask.fromJson(Map<String, Object?> json) => _$FileMaskFromJson(json);
}
