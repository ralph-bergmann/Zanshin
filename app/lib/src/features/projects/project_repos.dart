// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// How the project session reaches repositories (Stories 11.5 and 11.6; Claude's proposal): detect a path, open a jj
/// workspace, and create one — convert a Git repository, initialise a folder, clone a remote. The app's adapter is
/// `WorkerProjectRepos` over the worker; the tests pass a fake.
abstract interface class ProjectRepos {
  /// Classifies [path] (`ZanshinWorker.detect`, FR-JJ-17); a folder without a repository is a result, not an error.
  Future<RepoDetectResult> detect(String path);

  /// Opens the jj workspace at [path] (`ZanshinWorker.openRepo`).
  Future<ProjectRepo> open(String path);

  /// Converts the Git repository at [path] to a colocated jj workspace (`ZanshinWorker.convert`, the CLI's
  /// `jj git init --colocate <path>`). Throws [ZanshinFfiException], carrying the conversion's warnings, when it fails.
  Future<ProjectCreation> convert(String path);

  /// Creates a Git-backed jj repository in the existing folder [path] (`ZanshinWorker.initRepo` with the Git backend,
  /// the CLI's `jj git init --no-colocate <path>`). Throws [ZanshinFfiException] when it fails.
  Future<ProjectCreation> init(String path);

  /// Clones [url] into the existing folder [destination] (`ZanshinWorker.cloneRepo`, the CLI's
  /// `jj git clone --no-colocate <url> <destination>` with the remote `origin`). Throws [ZanshinFfiException],
  /// carrying the clone's warnings, when it fails.
  Future<ProjectCreation> clone({required String url, required String destination});
}

/// A repository a creation made, open, with what the creating call warned about (9.33).
@immutable
class ProjectCreation {
  /// The created and open [repo] with the creation's [warnings].
  const ProjectCreation({required this.repo, this.warnings = const <ZanshinWarning>[]});

  /// The new repository, open.
  final ProjectRepo repo;

  /// The creation's warnings in the CLI's print order, their messages verbatim; empty when there were none.
  final List<ZanshinWarning> warnings;
}

/// One open repository as the project session sees it.
abstract interface class ProjectRepo {
  /// The open handle, the one 10.5's graph reads through: opened, or fresh from a creation.
  RepoHandle get handle;

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
/// dirty when @ changes files against its merged parents, else the [tracking] state ([trackingStatusOf]: diverged,
/// ahead or behind), else clean.
ProjectStatus statusOf({required ConflictState conflict, required bool hasFileChanges, ProjectStatus? tracking}) {
  if (conflict == ConflictState.conflicted) {
    return ProjectStatus.conflict;
  }
  if (hasFileChanges) {
    return ProjectStatus.dirty;
  }
  return tracking ?? ProjectStatus.clean;
}

/// The open project's dot as `ProjectRepo.read` composes it: [statusOf] over @'s conflict state and file changes
/// and, only when neither decides the dot, [trackingStatusOf] over [headRefs] and the list [bookmarks] reads — so a
/// conflicted or dirty @ never pays for the bookmark distances, and a failed bookmark read cannot discard its state.
Future<ProjectStatus> statusFrom({
  required ConflictState conflict,
  required bool hasFileChanges,
  required Iterable<TopologyRef> headRefs,
  required Future<Iterable<Bookmark>> Function() bookmarks,
}) async {
  final ProjectStatus local = statusOf(conflict: conflict, hasFileChanges: hasFileChanges);
  if (local != ProjectStatus.clean) {
    return local;
  }
  return statusOf(
    conflict: conflict,
    hasFileChanges: hasFileChanges,
    tracking: trackingStatusOf(headRefs, await bookmarks()),
  );
}

/// The remote the CLI leaves out of its tracked-bookmark default (`--tracked` implies `--remote=~git`,
/// `default_ignored_remote_name`): the colocated Git repository's own refs.
const _ignoredRemote = 'git';

/// The dot's sync state (Story 9.29) from the refs of `heads(::@ & bookmarks())` and the bookmark list: over the
/// tracked remote rows of those local bookmarks (remote `git` excluded), [ProjectStatus.ahead] when the local side has
/// commits a remote lacks (a remote row's `behind`), [ProjectStatus.behind] when a remote has commits the local side
/// lacks (its `ahead`), [ProjectStatus.diverged] when both hold, null when neither does.
ProjectStatus? trackingStatusOf(Iterable<TopologyRef> headRefs, Iterable<Bookmark> bookmarks) {
  final names = <String>{
    for (final ref in headRefs)
      if (ref.kind == TopologyRefKind.bookmark && ref.remote == null) ref.name,
  };
  var localAhead = false;
  var localBehind = false;
  for (final bookmark in bookmarks) {
    if (bookmark.kind case RemoteBookmark(tracked: true, :final remoteName, :final ahead, :final behind)
        when remoteName != _ignoredRemote && names.contains(bookmark.name)) {
      localAhead |= (behind?.lower ?? 0) > 0;
      localBehind |= (ahead?.lower ?? 0) > 0;
    }
  }
  return switch ((localAhead, localBehind)) {
    (true, true) => ProjectStatus.diverged,
    (true, false) => ProjectStatus.ahead,
    (false, true) => ProjectStatus.behind,
    (false, false) => null,
  };
}

/// The bookmark label from the refs of `heads(::@ & bookmarks())` (design question (b)): the first by name of the
/// local bookmarks, or null when there is none. Remote bookmarks and tags never count.
String? bookmarkLabel(Iterable<TopologyRef> refs) => (<String>[
  for (final ref in refs)
    if (ref.kind == TopologyRefKind.bookmark && ref.remote == null) ref.name,
]..sort()).firstOrNull;

/// Whether [error] is jj's refusal to read a stale working copy (docs/rust-error-codes.md, `jj.stale_working_copy`).
bool isStale(ZanshinFfiException error) => error.code == 'jj.stale_working_copy';
