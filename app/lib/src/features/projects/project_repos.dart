// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// How the project session reaches repositories (Story 11.5; Claude's proposal): detect a path, open a jj workspace.
/// The app's adapter is `WorkerProjectRepos` over the worker; the tests pass a fake.
abstract interface class ProjectRepos {
  /// Classifies [path] (`ZanshinWorker.detect`, FR-JJ-17); a folder without a repository is a result, not an error.
  Future<RepoDetectResult> detect(String path);

  /// Opens the jj workspace at [path] (`ZanshinWorker.openRepo`).
  Future<ProjectRepo> open(String path);
}

/// One open repository as the project session sees it.
abstract interface class ProjectRepo {
  /// The open handle, the one 10.5's graph reads through.
  OpenedRepoHandle get handle;

  /// Fires when a jj operation lands in this repository (its op heads changed), by anyone.
  Stream<void> get changes;

  /// Reads what the status dot and the bookmark label show; a stale working copy reads as [ProjectStatus.stale].
  /// Throws [ZanshinFfiException] when the reads fail otherwise.
  Future<ProjectReading> read();

  /// Closes the handle.
  Future<void> close();
}

/// What one reading of the open project found (design questions (a) and (b)).
@immutable
class ProjectReading {
  /// A reading of [status] with the bookmark label [bookmark].
  const ProjectReading({required this.status, this.bookmark});

  /// The status dot's state.
  final ProjectStatus status;

  /// The first by name of the local bookmarks on @'s closest bookmarked ancestor, or null when there is none. A
  /// [ProjectStatus.stale] reading carries none: jj refuses the read, so the label keeps its last value.
  final String? bookmark;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ProjectReading && other.status == status && other.bookmark == bookmark;

  @override
  int get hashCode => Object.hash(status, bookmark);

  @override
  String toString() => 'ProjectReading($status, $bookmark)';
}

/// The open project's dot from @ (design question (a), decision 16.28): conflict when @'s change is conflicted, else
/// dirty when @ changes files against its merged parents, else clean.
ProjectStatus statusOf({required ConflictState conflict, required bool hasFileChanges}) {
  if (conflict == ConflictState.conflicted) {
    return ProjectStatus.conflict;
  }
  return hasFileChanges ? ProjectStatus.dirty : ProjectStatus.clean;
}

/// The bookmark label from the refs of `heads(::@ & bookmarks())` (design question (b)): the first by name of the
/// local bookmarks, or null when there is none. Remote bookmarks and tags never count.
String? bookmarkLabel(Iterable<TopologyRef> refs) => (<String>[
  for (final ref in refs)
    if (ref.kind == TopologyRefKind.bookmark && ref.remote == null) ref.name,
]..sort()).firstOrNull;

/// Whether [error] is jj's refusal to read a stale working copy (docs/rust-error-codes.md, `jj.stale_working_copy`).
bool isStale(ZanshinFfiException error) => error.code == 'jj.stale_working_copy';
