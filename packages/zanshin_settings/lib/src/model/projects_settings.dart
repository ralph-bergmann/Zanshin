// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';

part 'projects_settings.freezed.dart';
part 'projects_settings.g.dart';

/// The project registry (epics.md Story 11.5 item 1, Claude's proposal): the projects and groups the user keeps, and
/// the project the project window shows. jj knows nothing about it; the Projects window (11.6) edits it.
///
/// The tree is stored flat (Claude's proposal): a project names its group, a group its parent, and every member of a
/// parent — groups and projects alike — carries one [ProjectEntry.order] / [ProjectGroup.order] among its siblings,
/// so mixed, nested siblings keep their order (the floating export's `HOME_TREE`, design/data.js:305-338).
@freezed
abstract class ProjectsSettings with _$ProjectsSettings {
  /// Creates a registry; an omitted list is empty and no project is open.
  const factory ProjectsSettings({
    /// The registered projects, keyed by [ProjectEntry.path].
    @Default(<ProjectEntry>[]) List<ProjectEntry> projects,

    /// The groups, keyed by [ProjectGroup.id].
    @Default(<ProjectGroup>[]) List<ProjectGroup> groups,

    /// The path of the project the project window shows, or null when none is open; launch reopens it. A launch
    /// whose open failed keeps it, so the next launch tries again; one that finds no jj workspace there clears it.
    String? openProject,
  }) = _ProjectsSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory ProjectsSettings.fromJson(Map<String, Object?> json) => _$ProjectsSettingsFromJson(json);
}

/// One registered project (epics.md Story 11.5 item 1).
@freezed
abstract class ProjectEntry with _$ProjectEntry {
  /// Creates a project at [path] named [name].
  const factory ProjectEntry({
    /// The workspace's root directory, absolute; the registry's key.
    required String path,

    /// The name the capsule, the Project menu and the Projects window show.
    required String name,

    /// The [ProjectGroup.id] of its group, or null at the top level.
    String? group,

    /// Its position among its siblings (the groups and projects of the same parent), from 0.
    @Default(0) int order,

    /// When it was last opened (UTC), or null when it never was; the Project menu's Recent sorts by it.
    DateTime? lastOpened,

    /// Its last known state, written after every reading of the open project and when a switch or a close leaves
    /// it (item 7), or null before the first. A value this version does not know reads as null (Story 11.5: a newer
    /// file never breaks an older app's settings).
    @JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue) ProjectStatus? status,

    /// Its last known bookmark label — the first by name of the local bookmarks on @'s closest bookmarked ancestor
    /// (design question (b)) — or null when there was none ("—").
    String? bookmark,

    /// The graph's stacks the user expanded, by their run's oldest member key (Story 10.17).
    @Default(<String>[]) List<String> expandedStacks,

    /// The graph's stacks the user collapsed, by their run's oldest member key (Story 10.17).
    @Default(<String>[]) List<String> collapsedStacks,

    /// What the graph shows, as the search's JSON text (Story 10.21), or null for the default search.
    String? graphView,

    /// The graph search's recent go-tos and filters, newest first, each as its JSON text (Story 10.21).
    @Default(<String>[]) List<String> recentSearches,

    /// The inspector's Viewed marks, each `<change id>:<fingerprint>:<path>`, oldest first (Story 10.24).
    @Default(<String>[]) List<String> viewedFiles,
  }) = _ProjectEntry;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory ProjectEntry.fromJson(Map<String, Object?> json) => _$ProjectEntryFromJson(json);
}

/// One group of the registry: a user-defined virtual folder, not a directory (design/data.js:302-303).
@freezed
abstract class ProjectGroup with _$ProjectGroup {
  /// Creates a group [id] named [name].
  const factory ProjectGroup({
    /// The group's key, `g<n>` (Claude's proposal).
    required String id,

    /// The name the Projects window shows.
    required String name,

    /// The [ProjectGroup.id] of its parent group, or null at the top level.
    String? parent,

    /// Its position among its siblings (the groups and projects of the same parent), from 0.
    @Default(0) int order,
  }) = _ProjectGroup;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory ProjectGroup.fromJson(Map<String, Object?> json) => _$ProjectGroupFromJson(json);
}

/// A project's state as its status dot shows it (DS components/content/ProjectRow.jsx:5-15; decision 16.28).
///
/// Ahead, behind and diverged come from the bookmark tracking state (Story 9.29); syncing is 11.8's.
enum ProjectStatus {
  /// Nothing to report.
  clean,

  /// @ has file changes.
  dirty,

  /// @'s change is conflicted.
  conflict,

  /// The path is gone.
  missing,

  /// The working copy is stale (`jj.stale_working_copy`).
  stale,

  /// The bookmark @ sits on has commits its tracked remote lacks ("ahead of remote").
  ahead,

  /// The tracked remote has commits the bookmark @ sits on lacks ("behind remote").
  behind,

  /// Both at once: the bookmark and its tracked remote each have commits the other lacks.
  diverged,
}
