// SPDX-License-Identifier: MIT

import '../ffi/bookmarks.dart' show Bookmark;
import '../ffi/change.dart' show Change;
import '../ffi/commit_views.dart' show ChangeIdRef, CommitIdRef, EvologEntry, InterdiffView, RevisionRef, ShowEntry;
import '../ffi/file.dart' show AnnotationLine, FileContents, FileEntry, FileSearch;
import '../ffi/git.dart' show GitExportResult, GitImportResult;
import '../ffi/graph.dart'
    show GraphSlice, defaultGraphPrioritize, defaultLogRevset, defaultShortPrefixes, defaultSyntheticElided;
import '../ffi/log_defaults.dart' show LogDefaults;
import '../ffi/mutate.dart' show AbsorbResult, MutationResult;
import '../ffi/op_log.dart' show Operation;
import '../ffi/remotes.dart' show Remote;
import '../ffi/status.dart' show WorkingCopyStatus;
import '../ffi/workspace.dart' show WorkspaceEntry;
import 'isolate.dart';
import 'responses.dart';

/// Main-isolate wrapper around an open jj repository (Model A, Story 3.9).
///
/// Holds an opaque [handleId] that the worker resolves to its internal
/// `*mut Repo` pointer. Raw handles never leave the worker — this class
/// contains only integers.
///
/// Lifecycle:
/// - Created by [ZanshinWorker.openRepo] / [ZanshinWorker.initRepo] /
///   [ZanshinWorker.cloneRepo].
/// - Closed explicitly via [close], or implicitly when GC runs the
///   Dart [Finalizer] (belt-and-suspenders).
///
/// The `NativeFinalizer` rule in project-context applies to wrappers whose
/// callback is a C function pointer. This class frees a resource across the
/// isolate boundary via a Dart call — a Dart [Finalizer] is correct (R4).
final class RepoHandle {
  /// Wrap `handleId` returned by the worker for the given `worker`.
  RepoHandle(this._worker, this._handleId) {
    _finalizer.attach(this, (_worker, _handleId), detach: this);
  }

  final ZanshinWorker _worker;
  final int _handleId;
  var _closed = false;

  /// The opaque dense id in the worker's handle table.
  ///
  /// 3.4b read commands pass this to [ZanshinWorker.send] as the handle
  /// discriminant, e.g. `StatusCommand(commandId: id, handleId: handleId)`.
  int get handleId => _handleId;

  /// Close the repository on the worker and release the handle table entry.
  ///
  /// Idempotent: subsequent calls are silently no-ops.
  ///
  /// Swallows `StateError('Worker is closed')` — a closed worker has already
  /// released all handles with the process. A genuine `ffi.invalid_handle`
  /// surfaces as [ZanshinFfiException] (it would signal a bug in the table).
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _finalizer.detach(this);
    try {
      await _worker.closeRepo(_handleId);
    } catch (e) {
      // WHY: During closeRepo, if the worker shuts down concurrently,
      // correlator.failAll propagates StateError('Worker is closed') through
      // the awaited future. Swallowing it is correct — the OS reclaims FFI
      // handles at process exit. All other exceptions are re-thrown.
      if (e is! StateError) {
        rethrow;
      }
    }
  }

  /// Read the working-copy status for this repository.
  ///
  /// Throws [StateError] if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.no_working_copy`, `jj.jj_lib_error`).
  Future<WorkingCopyStatus> status() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.status(_handleId);
  }

  /// Read full change metadata for the change identified by [changeId].
  ///
  /// Throws [StateError] if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.change_not_found`, `jj.jj_lib_error`).
  Future<Change> getChange(String changeId) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.getChange(_handleId, changeId);
  }

  /// Read the lane-assigned commit graph for [revset], metadata included
  /// (Story 4.6, enriched in Story 4.8).
  ///
  /// Every parameter is a CLI pass-through with the CLI's own default
  /// pre-filled and editable by the caller (FR-JJ-17):
  ///
  /// - [prioritize] — branch-prioritisation revset, default
  ///   [defaultGraphPrioritize] (`present(@)`); `'none()'` means none.
  /// - [syntheticElided] — render elided ancestry as synthetic rows, default
  ///   [defaultSyntheticElided] (`true`, the CLI's `ui.log-synthetic-elided-nodes`).
  /// - [shortPrefixes] — disambiguation revset for the shortest-prefix lengths,
  ///   default [defaultShortPrefixes]; `''` DISABLES disambiguation.
  ///
  /// [defaultLogRevset] is the CLI's default for [revset], exported for the UI
  /// to pre-fill; it is never applied silently.
  ///
  /// The graph is re-derived from head on every call (ADR-0002) — re-request on
  /// an `OpHeadsChangedEvent` to pick up external operations.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.jj_lib_error`;
  /// full list: `docs/ffi-abi.md` § `zanshin_graph_slice`).
  Future<GraphSlice> graphSlice({
    required String revset,
    String prioritize = defaultGraphPrioritize,
    bool syntheticElided = defaultSyntheticElided,
    String shortPrefixes = defaultShortPrefixes,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.graphSlice(
      _handleId,
      revset: revset,
      prioritize: prioritize,
      syntheticElided: syntheticElided,
      shortPrefixes: shortPrefixes,
    );
  }

  /// Read the operation log for this repository.
  ///
  /// `limit < 0` (default `-1`) returns all operations; `limit >= 0` returns
  /// at most [limit] most-recent operations.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.jj_lib_error`).
  Future<List<Operation>> opLog({int limit = -1}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.opLog(_handleId, limit);
  }

  /// Read local + tracked-remote bookmarks for this repository.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.jj_lib_error`).
  Future<List<Bookmark>> bookmarks() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.bookmarks(_handleId);
  }

  /// Read the configured git remotes for this repository.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.jj_lib_error`).
  Future<List<Remote>> remotes() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.remotes(_handleId);
  }

  /// Read the effective `jj log` defaults for this repository (Story 4.9) —
  /// what the user's own `jj` CLI would apply after their config overrides.
  ///
  /// Use these to pre-fill [graphSlice]'s parameters instead of the builtin
  /// constants [defaultLogRevset] / [defaultGraphPrioritize] /
  /// [defaultShortPrefixes] / [defaultSyntheticElided]; they are offers, still
  /// editable by the user (FR-JJ-17). The config is re-read Rust-side on every
  /// call and never cached, so an externally edited config file shows up on the
  /// next call without reopening the handle.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.config_error`).
  Future<LogDefaults> logDefaults() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.logDefaults(_handleId);
  }

  /// Rewrite the description of [changeId] to [description] (Story 6.5).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.change_not_found`, `jj.invalid_input`, `jj.immutable`,
  /// `jj.config_error`).
  Future<MutationResult> describe({required String changeId, required String description}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.describe(_handleId, changeId: changeId, description: description);
  }

  /// Create a new, empty change on top of [parents], and switch the working
  /// copy to it — a merge commit when [parents] has more than one entry
  /// (Story 6.5).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`).
  Future<MutationResult> newChange(List<String> parents) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.newChange(_handleId, parents);
  }

  /// Switch the working copy to [changeId] without creating a new commit
  /// (Story 6.5).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.change_not_found`, `jj.immutable`, `jj.config_error`). Unlike [describe]
  /// and [abandon] this has no separate root-commit guard, so editing the root
  /// commit reports `jj.immutable` (which is what the jj CLI reports for it).
  Future<MutationResult> edit(String changeId) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.edit(_handleId, changeId);
  }

  /// Abandon [changeIds], rebasing descendants onto their parents and deleting
  /// any bookmarks that pointed only at the abandoned commits (Story 6.5).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`).
  Future<MutationResult> abandon(List<String> changeIds) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.abandon(_handleId, changeIds);
  }

  /// Revert the last operation, one step back from the current head
  /// (Story 6.5). Calling this twice in a row redoes the first `undo`.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.nothing_to_undo`).
  Future<MutationResult> undo() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.undo(_handleId);
  }

  /// Fetch all branches and tags from [remoteName] and import them
  /// (Story 6.5). Never moves `@` — fetch only updates remote-tracking refs.
  ///
  /// Progress rides `ZanshinWorker.events` as a `ProgressEvent` carrying this
  /// handle's [handleId].
  ///
  /// `git.abandon-unreachable-commits` and `git.record-synthetic-predecessors` are
  /// read from the repo's effective config per call, never hardcoded.
  ///
  /// The result's `abandonedChangeIds` carries the commits the import abandoned
  /// because they became unreachable in git — jj-lib's OWN abandonments, not a
  /// caller echo, and empty when `git.abandon-unreachable-commits` is off.
  /// `newChangeIds` is always empty: a fetch mints nothing.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.remote_not_found`, `jj.not_a_git_repo`, `jj.config_error`,
  /// `jj.network_error`, `jj.jj_lib_error`). A workspace with no git backend is
  /// `jj.not_a_git_repo` — not `jj.remote_not_found`, which now means only
  /// "no remote of that name".
  Future<MutationResult> gitFetch(String remoteName) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitFetch(_handleId, remoteName);
  }

  /// Give the paths in [paths] the content they have in another commit
  /// (Story 9.3) — the CLI's `jj restore`, whole-file only.
  ///
  /// A `null` [from]/[into]/[changesIn] applies the CLI's own defaults: if
  /// exactly one of [from]/[into] is given the other is `@`; if neither is, the
  /// destination ([changesIn], else `@`) is restored from its PARENT tree, which
  /// undoes its own diff while keeping its description. [changesIn] cannot be
  /// combined with [from]/[into].
  ///
  /// [paths] entries are repo-relative paths interpreted as PREFIXES (an empty
  /// list means all paths); an empty-STRING entry is the repository root, which
  /// prefixes everything, so `paths: ['']` matches all paths just as `paths: []`
  /// does. [restoreDescendants] reparents children (preserving their content)
  /// instead of rebasing them.
  ///
  /// A path that matches nothing is silently a no-op, where the CLI would warn —
  /// `MutationResult` has no warning channel.
  ///
  /// If the resulting tree already equals the destination's, NO operation is
  /// written and `newOpId` is the pre-call op-log head. The working copy is not
  /// snapshotted first — `@` is the last-snapshotted working-copy commit.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`).
  Future<MutationResult> restore({
    String? from,
    String? into,
    String? changesIn,
    List<String> paths = const <String>[],
    bool restoreDescendants = false,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.restore(
      _handleId,
      from: from,
      into: into,
      changesIn: changesIn,
      paths: paths,
      restoreDescendants: restoreDescendants,
    );
  }

  /// Move each hunk of [from] into the closest commit in [into] where the
  /// corresponding lines were last modified (Story 9.3) — the CLI's
  /// `jj absorb`, non-interactive only.
  ///
  /// A `null` [from] means `@`. A `null` [into] applies the CLI's own default,
  /// the `mutable()` ALIAS resolved through the repo's effective config — and
  /// unlike every other mutation argument [into] is a revset EXPRESSION, not a
  /// change id. [paths] behaves as in [restore].
  ///
  /// Paths jj-lib refuses to split are reported in `AbsorbResult.skippedPaths`
  /// rather than failing the call. If nothing was absorbable, no operation is
  /// written and `rewrittenChangeIds` is empty. On an ERROR the skipped-path list
  /// is lost (an exception carries no payload), where a CLI user would still have
  /// seen the per-path warnings.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`,
  /// `jj.change_not_found`, `jj.immutable`, `jj.config_error`).
  Future<AbsorbResult> absorb({String? from, String? into, List<String> paths = const <String>[]}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.absorb(_handleId, from: from, into: into, paths: paths);
  }

  /// List the entries of a revision's tree (Story 9.4) — the CLI's
  /// `jj file list`.
  ///
  /// A `null` [revision] applies the CLI's own `-r` default `@` — here the
  /// LAST-SNAPSHOTTED working-copy commit, because Zanshin never snapshots. It is
  /// a jj reverse-hex CHANGE ID, not a revset; a divergent id is refused rather
  /// than guessed, exactly as the CLI's `-r` refuses an ambiguous revision.
  ///
  /// [paths] entries are repo-relative paths interpreted as PREFIXES (an empty
  /// list means all paths); an empty-STRING entry is the repository root, which
  /// prefixes everything, so `paths: ['']` matches all paths just as `paths: []`
  /// does. The fileset DSL is not parsed.
  ///
  /// Entries come in jj's own tree order. A path matching nothing simply
  /// contributes no entry, where the CLI prints a warning. Subtrees are visited
  /// recursively and never listed — except a subtree that CONFLICTS with a
  /// non-tree, which arrives as one `FileType.conflict` entry.
  ///
  /// This read writes no operation. Throws [StateError] synchronously if the
  /// handle is already [_closed]; throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.change_not_found`, `jj.invalid_input`,
  /// `jj.jj_lib_error`).
  Future<List<FileEntry>> fileList({String? revision, List<String> paths = const <String>[]}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.fileList(_handleId, revision: revision, paths: paths);
  }

  /// Read the contents of the files selected by [paths] (Story 9.4) — the CLI's
  /// `jj file show`.
  ///
  /// [revision] and [paths] behave as in [fileList], with one difference the CLI
  /// also makes: [paths] may NOT be empty (its FILESETS argument is `required`).
  /// A directory is read recursively.
  ///
  /// With exactly ONE path an absent path is refused (`jj.path_not_found`); with
  /// several, an absent path simply contributes nothing — that asymmetry is the
  /// CLI's, reproduced deliberately. A conflicted file's content is the
  /// MATERIALIZED merge, with markers in the style the repo's effective
  /// `ui.conflict-marker-style` selects. Paths that exist but are not renderable
  /// as file content (a symlink, a submodule, a blob whose access is denied) land
  /// in `FileContents.skipped` instead of failing the call.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.path_not_found`, `jj.change_not_found`,
  /// `jj.config_error` — this is the only file read that consults the repo's
  /// effective jj config — `jj.jj_lib_error`).
  Future<FileContents> fileShow({required List<String> paths, String? revision}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.fileShow(_handleId, revision: revision, paths: paths);
  }

  /// Annotate [path] line by line (Story 9.4) — the CLI's `jj file annotate`.
  ///
  /// [path] is a single PLAIN repo-relative path, not a prefix and not a fileset.
  /// The search domain is `all()`, hardcoded exactly as the CLI hardcodes it.
  ///
  /// One entry per line of the file, in file order, so a line's own 1-based
  /// number is its index in the returned list + 1 — which is why
  /// `AnnotationLine` carries only `originalLineNumber`, the line's number in the
  /// ORIGINATING commit. Where the CLI collapses "the search stopped outside the
  /// domain" to the root commit, `AnnotationLine.originFound` keeps it.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.path_not_found`, `jj.not_a_file`,
  /// `jj.change_not_found`, `jj.jj_lib_error`).
  Future<List<AnnotationLine>> fileAnnotate({required String path, String? revision}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.fileAnnotate(_handleId, path: path, revision: revision);
  }

  /// Search the files of a revision for [pattern] (Story 9.4) — the CLI's
  /// `jj file search`.
  ///
  /// [pattern] is jj's own `kind:pattern` string-pattern syntax passed through
  /// verbatim; a bare pattern defaults to kind `regex`, and the FIRST `:`
  /// separates. [revision] and [paths] behave as in [fileList].
  ///
  /// [nameOnly] stops a file's scan at its first match — it changes the WORK done,
  /// not the result shape, so each matching file still contributes its first
  /// matching line (a superset of what the CLI prints). The CLI's `--line-number`
  /// has no counterpart: `SearchMatch.lineNumber` is always carried.
  ///
  /// A conflicted path is searched side by side, with `conflictSide` set and line
  /// numbers restarting at each side. Symlinks, submodules and non-file conflicts
  /// are SILENTLY not searched, as the CLI skips them; a path whose blob could not
  /// be READ lands in `FileSearch.skipped` — the only case `jj file search` warns
  /// about — and does not fail the call.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.jj_lib_error`).
  Future<FileSearch> fileSearch({
    required String pattern,
    String? revision,
    List<String> paths = const <String>[],
    bool nameOnly = false,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.fileSearch(_handleId, pattern: pattern, revision: revision, paths: paths, nameOnly: nameOnly);
  }

  /// Import the backing git repo's refs into jj's view (Story 9.5) — the CLI's
  /// `jj git import`.
  ///
  /// Takes no arguments; the CLI's own `jj git import` has none either. Unlike the
  /// CLI this is NOT skipped in a colocated workspace: that skip exists because the
  /// CLI imports refs during its implicit per-command snapshot, which Zanshin never
  /// performs, so the skip's premise is false here.
  ///
  /// `git.abandon-unreachable-commits` and `git.record-synthetic-predecessors` are
  /// read from the repo's effective jj config per call. Per-remote
  /// `auto-track-bookmarks` is not honoured — [gitFetch] and clone leave it empty
  /// too, and changing that is a separate, three-call-site change.
  ///
  /// If nothing needed importing, no operation is written and `mutation.newOpId` is
  /// the pre-call op-log head. A ref that could not be imported lands in
  /// `failedRefNames` and does NOT fail the call — the CLI warns and exits 0.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.not_a_git_repo`, `jj.config_error`, `jj.jj_lib_error`).
  Future<GitImportResult> gitImport() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitImport(_handleId);
  }

  /// Write jj's bookmarks and tags back to the backing git repo (Story 9.5) — the
  /// CLI's `jj git export`.
  ///
  /// Not skipped in a colocated workspace either — see [gitImport]. Export never
  /// moves `@` and rewrites no commit.
  ///
  /// If git already matched, no operation is written and `mutation.newOpId` is the
  /// pre-call op-log head. Refs that could not be written land in `failedBookmarks`
  /// / `failedTags` and do NOT fail the call; the classic case is two bookmarks
  /// named `foo` and `foo/bar`, which git cannot both hold.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.not_a_git_repo`, `jj.jj_lib_error`).
  Future<GitExportResult> gitExport() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitExport(_handleId);
  }

  /// Register a new git remote (Story 9.5) — the CLI's `jj git remote add`.
  ///
  /// [url] and [pushUrl] are passed through verbatim; unlike the CLI, a relative
  /// local path is not resolved against a process CWD. A `null` [pushUrl] means the
  /// remote pushes to [url], which is git's own behaviour.
  ///
  /// [remotes] on this SAME handle reflects the new remote immediately.
  ///
  /// One caveat worth surfacing in a UI: a remote added WITH a push URL cannot
  /// later be removed — jj writes a `pushurl` key, which its own remove refuses as
  /// `jj.remote_nonstandard_config`.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.remote_exists`, `jj.invalid_input`, `jj.not_a_git_repo`,
  /// `jj.jj_lib_error`).
  Future<MutationResult> gitRemoteAdd({required String name, required String url, String? pushUrl}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitRemoteAdd(_handleId, name: name, url: url, pushUrl: pushUrl);
  }

  /// Remove a git remote and forget its bookmarks (Story 9.5) — the CLI's
  /// `jj git remote remove`.
  ///
  /// [remotes] on this SAME handle reflects the removal immediately. Removing the
  /// reserved remote `git` SUCCEEDS but writes no operation — it changes the git
  /// config and refs, not jj's view.
  ///
  /// Unlike the CLI, `.jj/repo/config.toml` is not edited: a `[remotes.<name>]`
  /// section survives, and a `revset-aliases.'trunk()'` pinned to this remote keeps
  /// naming it.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.remote_not_found`, `jj.remote_nonstandard_config`, `jj.not_a_git_repo`,
  /// `jj.jj_lib_error`).
  Future<MutationResult> gitRemoteRemove(String name) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitRemoteRemove(_handleId, name);
  }

  /// Rename a git remote (Story 9.5) — the CLI's `jj git remote rename`.
  ///
  /// [remotes] on this SAME handle reflects the rename immediately. Renaming FROM
  /// the reserved remote `git` writes no operation, for the same reason removing it
  /// does not, and `.jj/repo/config.toml` is not edited — see [gitRemoteRemove].
  ///
  /// jj validates [newName] BEFORE it reports that [oldName] is missing, so
  /// renaming a nonexistent remote to `git` reports the reserved-name refusal. That
  /// ordering is jj's own and is reproduced, not corrected.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.remote_not_found`, `jj.remote_exists`,
  /// `jj.remote_nonstandard_config`, `jj.not_a_git_repo`, `jj.jj_lib_error`).
  Future<MutationResult> gitRemoteRename(String oldName, String newName) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitRemoteRename(_handleId, oldName, newName);
  }

  /// Re-point a git remote's fetch and/or push URL (Story 9.5) — the CLI's
  /// `jj git remote set-url`.
  ///
  /// NEVER writes an operation: jj takes no transaction for this verb, and neither
  /// does the CLI — so the returned `newOpId` is always the pre-call op-log head.
  /// [remotes] on this SAME handle still reports the new URL.
  ///
  /// A `null` [url]/[pushUrl] leaves that side unchanged (a URL cannot be REMOVED
  /// from a remote). With BOTH null the call succeeds and does nothing, even for a
  /// remote that does not exist — jj returns early before its own existence check,
  /// and inventing a refusal there would be a divergence.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.remote_not_found`, `jj.invalid_input`, `jj.not_a_git_repo`,
  /// `jj.jj_lib_error`).
  Future<MutationResult> gitRemoteSetUrl({required String name, String? url, String? pushUrl}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitRemoteSetUrl(_handleId, name: name, url: url, pushUrl: pushUrl);
  }

  /// Show each revision [revset] denotes with what it changed (Story 9.6) — the
  /// CLI's `jj show`.
  ///
  /// A `null` [revset] applies the CLI's own default `@` — here the
  /// LAST-SNAPSHOTTED working-copy commit, because Zanshin never snapshots. Unlike
  /// [interdiff]'s two single revisions, [revset] is a pass-through EXPRESSION:
  /// the CLI unions its revsets, so entries are per COMMIT — a revset naming
  /// two commits of ONE divergent change yields two entries with the same
  /// `Change.id`, both flagged `divergent`. A BARE divergent change-id symbol does
  /// NOT get that far: jj-lib's own `SymbolResolver` refuses it
  /// (`RevsetResolutionError::DivergentChangeId`), exactly as
  /// `jj show <divergent-id>` fails in the CLI, so it throws
  /// `jj.revset_resolution_error` — a DIFFERENT refusal from [interdiff]'s
  /// `jj.change_not_found`. Address both commits by unioning their COMMIT hexes,
  /// which are ordinary revset symbols. Aliases come from the repo's effective jj
  /// config, re-read per call.
  ///
  /// Entries come in raw revset order (topological, children before parents). Each
  /// entry's `fileChanges` is the diff against the commit's MERGED parent tree —
  /// for a merge, only what the merge itself changed; for the root commit, empty.
  /// There is no path filter and no textual patch: the CLI has no path argument
  /// here, and line/word-level diffing is Epic 5's.
  ///
  /// [limit] is a ZANSHIN-SIDE cap the CLI has no counterpart for — `jj show` has
  /// no `-n/--limit`, because it streams to a pager where this materialises one
  /// list whose every entry pays a merged-parent tree diff. It is applied in RAW
  /// REVSET order, the same order the unbounded call returns; `limit: 0` is an
  /// empty list, not an error, and `null` is the CLI-parity default (unbounded).
  /// A [limit] above the wire field's `uint` ceiling (4294967295) SATURATES
  /// there, so an over-large limit means "everything" rather than wrapping to an
  /// empty list; a NEGATIVE [limit] throws [ArgumentError].
  ///
  /// This read writes no operation. Throws [StateError] synchronously if the
  /// handle is already [_closed]; throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.revset_parse_error`, `jj.revset_resolution_error`,
  /// `jj.config_error`, `jj.jj_lib_error`).
  Future<List<ShowEntry>> show({String? revset, int? limit}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.show(_handleId, revset: revset, limit: limit);
  }

  /// Walk the evolution of the changes [revset] denotes (Story 9.6) — the CLI's
  /// `jj evolog`.
  ///
  /// [revset] behaves as in [show]. [limit] is the CLI's `-n/--limit`, applied in
  /// WALK order (the CLI limits before reversing); `limit: 0` is an empty list,
  /// not an error. A [limit] above the wire field's `uint` ceiling (4294967295)
  /// SATURATES there, so an over-large limit means "everything" rather than
  /// wrapping to an empty list; a NEGATIVE [limit] throws [ArgumentError]. The
  /// CLI's `--reversed` and its graph mode's re-ordering are rendering the UI does
  /// itself and are not applied.
  ///
  /// Rows carry COMMIT ids, not change ids: every predecessor shares the change's
  /// id, and predecessors are hidden by construction. A `null`
  /// `EvologEntry.operationId` marks an entry the walk emitted from its flush tail
  /// — the only signal that an evolution may be TRUNCATED, which the CLI leaves
  /// silent.
  ///
  /// The CLI's `-p/--patch` has no counterpart: it *is* an interdiff of each
  /// entry's predecessors — so a caller composes the two verbs, feeding an
  /// `EvologEntry.predecessorCommitIds` entry to [interdiff] as a [CommitIdRef],
  /// the arm that reaches hidden commits.
  ///
  /// `EvologEntry.change` carries two fields derived against the CURRENT view
  /// rather than this version's moment: `divergent` (whether the change has
  /// several visible commits right now — the same answer on every row) and
  /// `isAnonymous` (today's local bookmarks).
  ///
  /// This read writes no operation. Throws [StateError] synchronously if the
  /// handle is already [_closed]; throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.revset_parse_error`, `jj.revset_resolution_error`,
  /// `jj.config_error`, `jj.jj_lib_error`).
  Future<List<EvologEntry>> evolog({String? revset, int? limit}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.evolog(_handleId, revset: revset, limit: limit);
  }

  /// Compare what two revisions each CHANGE, with the parent difference factored
  /// out (Story 9.6) — the CLI's `jj interdiff`.
  ///
  /// Unlike [show], each side is a SINGLE revision, written as a [ChangeIdRef]
  /// (the house reverse-hex change-id prefix) or a [CommitIdRef] (a commit-id hex
  /// prefix). Each inherits the CLI `resolve_single_rev`'s REFUSAL — an ambiguous
  /// revision is rejected rather than guessed. A [ChangeIdRef] resolves only to the
  /// currently VISIBLE commit carrying it; a [CommitIdRef] resolves through jj's
  /// index, which ignores visibility, so the
  /// `EvologEntry.predecessorCommitIds` [evolog] reports — hidden by construction
  /// — ARE addressable and the two verbs compose into a version-to-version diff.
  /// A revset expression (`main`, `@-`) is still unaddressable on either arm,
  /// where the CLI accepts one. An absent side is `@` —
  /// but omitting BOTH is refused with `jj.invalid_input`, mirroring the CLI's
  /// required argument group: interdiffing `@` against itself is trivially empty
  /// and never what a caller meant.
  ///
  /// [paths] entries are repo-relative paths interpreted as PREFIXES (an empty
  /// list means all paths); an empty-STRING entry is the repository root, which
  /// prefixes everything. A filter matching nothing yields an empty list, where
  /// the CLI prints a warning.
  ///
  /// No `renamed`/`copied` entry is ever produced: `interdiff` passes no copy
  /// records, and that asymmetry with [show] is the CLI's own, reproduced
  /// deliberately.
  ///
  /// `InterdiffView.baseHasConflicts` reports whether the REBASED `from` tree —
  /// the LEFT side of the diff, which exists only in memory — is conflicted. That
  /// is a ZANSHIN-SIDE addition: the CLI signals it by rendering conflict markers
  /// in the patch TEXT, which is Epic 5's surface here. It never turns the call
  /// into a refusal, and it describes the TREE, not the filtered result.
  ///
  /// This read writes no operation — the rebase behind it is in-memory only.
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.revset_resolution_error` —
  /// an ambiguous [CommitIdRef] prefix — `jj.jj_lib_error`).
  Future<InterdiffView> interdiff({RevisionRef? from, RevisionRef? to, List<String> paths = const <String>[]}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.interdiff(_handleId, from: from, to: to, paths: paths);
  }

  /// List every workspace with its working-copy commit and root directory
  /// (Story 9.7) — the CLI's `jj workspace list`.
  ///
  /// Takes no argument: the CLI verb takes none either (its `-T/--template` flag
  /// is rendering). Rows come in jj-lib's own lexicographic-by-name order, which
  /// is preserved rather than re-sorted, and each carries the same
  /// name/working-copy-commit pair the repo's `View` holds plus an ABSOLUTE root
  /// path.
  ///
  /// A row's `root` is `null` when the path cannot be reported: the workspace
  /// predates jj 0.38.0 and has no recorded path, the store is unreadable, or the
  /// recorded directory moved or was deleted. None of those fails the listing —
  /// the CLI's own list template degrades the same way and points at
  /// [workspaceRoot] for strict path diagnostics. That asymmetry between the two
  /// verbs is reproduced, not smoothed over.
  ///
  /// This read writes no operation. Throws [StateError] synchronously if the
  /// handle is already [_closed]; throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.jj_lib_error`).
  Future<List<WorkspaceEntry>> workspaces() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.workspaces(_handleId);
  }

  /// Return one workspace's absolute root directory (Story 9.7) — the CLI's
  /// `jj workspace root [--name]`.
  ///
  /// A `null` [name] is the CLI's own documented default, the CURRENT workspace;
  /// that path reads the workspace loader alone — no repo load, no store read —
  /// and cannot fail. A PRESENT [name], even the current workspace's own, goes
  /// through the workspace store and can REFUSE, because the CLI's named path
  /// never shortcuts to the loader. An explicitly empty [name] is a VALUE, not an
  /// absence: no workspace is named `''`, so it refuses with
  /// `jj.workspace_not_found`.
  ///
  /// The returned path is absolute and canonicalized; CWD-relative shortening is
  /// the UI's job.
  ///
  /// This read writes no operation — not even on a refusal. Throws [StateError]
  /// synchronously if the handle is already [_closed]; throws [ArgumentError] if
  /// [name] contains an interior NUL (U+0000), which a length-prefixed
  /// FlatBuffers string would carry all the way into a workspace name; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.workspace_not_found`, `jj.workspace_no_recorded_path`,
  /// `jj.workspace_path_unresolved`, `jj.jj_lib_error`).
  Future<String> workspaceRoot({String? name}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.workspaceRoot(_handleId, name: name);
  }

  /// Create local bookmarks pointing at one revision (Story 9.8) — the CLI's
  /// `jj bookmark create`.
  ///
  /// [names] are EXACT, DECODED bookmark names: the revset quoting the CLI
  /// requires (`'foo bar'`, `'foo@bar'`) is terminal input syntax the GUI
  /// replaces, so pass what the user typed. An empty list, or an empty-string
  /// name, is refused with `jj.invalid_input`.
  ///
  /// A `null` [revision] is the CLI's own `-r` default `@` — the LAST-SNAPSHOTTED
  /// working-copy commit, since Zanshin never snapshots. It is a jj reverse-hex
  /// CHANGE id, so a divergent one is refused rather than guessed, and a commit
  /// hex, a revset expression and a hidden commit are unaddressable. ([interdiff]
  /// used to make the same trade; it gained a [CommitIdRef] arm, and this verb was
  /// deliberately left alone.)
  ///
  /// Both per-name preconditions run in ARGUMENT order and are FAIL-FAST: a run
  /// whose second name already exists creates NOTHING — not even the first — and
  /// writes no operation. Unlike the CLI, a created bookmark is never
  /// auto-tracked; `remotes.<r>.auto-track-bookmarks` needs `bookmark track`
  /// (Story 9.11).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ArgumentError] if a name or [revision] contains an interior NUL (U+0000),
  /// which a length-prefixed FlatBuffers string would carry all the way into a
  /// bookmark name; throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.invalid_input`, `jj.change_not_found`,
  /// `jj.bookmark_exists`, `jj.bookmark_tracked_remote_exists`,
  /// `jj.jj_lib_error`).
  Future<MutationResult> bookmarkCreate(List<String> names, {String? revision}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.bookmarkCreate(_handleId, names, revision: revision);
  }

  /// Delete the local bookmarks matching [names] (Story 9.8) — the CLI's
  /// `jj bookmark delete`.
  ///
  /// [names] are string PATTERNS, not exact names, and they are unioned:
  /// `exact:`, `glob:`, `regex:`, `substring:` and the `~`/`&`/`|` operators all
  /// work. **A BARE pattern is a GLOB** — `foo*` deletes both a bookmark
  /// literally named `foo*` and one named `foo1`, so use `exact:"foo*"` to reach
  /// only the literal. An empty list is refused with `jj.invalid_input`.
  ///
  /// Matching NOTHING is a SUCCESS, not a refusal: no operation is written and
  /// the returned `newOpId` is the PRE-CALL op-log head — the machine-readable
  /// form of the CLI's "No bookmarks to delete." A CONFLICTED local bookmark is
  /// deleted like any other.
  ///
  /// A TRACKED `name@remote` SURVIVES by design and keeps appearing in
  /// [bookmarks]: that is jj's "deleted bookmark, propagates on the next push"
  /// state, not a leak. `jj bookmark forget` — the verb that drops the remote
  /// rows too — is Story 9.11's.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ArgumentError] if a name contains an interior NUL (U+0000); throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.jj_lib_error`).
  Future<MutationResult> bookmarkDelete(List<String> names) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.bookmarkDelete(_handleId, names);
  }

  // GC backstop: a Dart Finalizer whose callback enqueues closeRepo on the
  // worker. Best-effort: the callback fires on the event loop so the worker
  // might be gone; all errors are swallowed (a GC-time throw is unacceptable).
  //
  // WHY Dart Finalizer, not NativeFinalizer: NativeFinalizer requires a C
  // function pointer taking a single Pointer<Void>. Closing a repo requires
  // a Dart async call across the isolate boundary — Dart Finalizer is the
  // correct mechanism (R4, Story 3.9).
  static final _finalizer = Finalizer<(ZanshinWorker, int)>((token) {
    final (worker, handleId) = token;
    // WHY: Finalizer callbacks are synchronous; closeRepo is best-effort GC
    // cleanup. .catchError swallows all failures; .ignore() discards the future
    // intentionally (suppresses discarded_futures lint).
    worker.closeRepo(handleId).catchError((_) {}).ignore();
  });
}
