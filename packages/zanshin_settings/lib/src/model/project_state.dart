// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';

part 'project_state.freezed.dart';
part 'project_state.g.dart';

/// One project's view state (Story 10.37): the content of its `projects/<stateId>.json`. Each list is oldest first.
@freezed
abstract class ProjectState with _$ProjectState {
  /// Creates a state; an omitted list is empty.
  const factory ProjectState({
    /// The inspector's Viewed marks, each `<change id>:<fingerprint>:<path>` (Story 10.24).
    @Default(<String>[]) List<String> viewedFiles,

    /// The graph's stacks the user expanded, by their run's oldest member key (Story 10.17).
    @Default(<String>[]) List<String> expandedStacks,

    /// The graph's stacks the user collapsed, by their run's oldest member key (Story 10.17).
    @Default(<String>[]) List<String> collapsedStacks,
  }) = _ProjectState;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory ProjectState.fromJson(Map<String, Object?> json) => _$ProjectStateFromJson(json);
}
