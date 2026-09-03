// SPDX-License-Identifier: MIT

import '../ffi/bookmarks.dart' show Bookmark;
import '../ffi/change.dart' show Change;
import '../ffi/file.dart' show AnnotationLine, FileContents, FileEntry, SearchMatch;
import '../ffi/graph.dart'
    show GraphSlice, defaultGraphPrioritize, defaultLogRevset, defaultShortPrefixes, defaultSyntheticElided;
import '../ffi/log_defaults.dart' show LogDefaults;
import '../ffi/mutate.dart' show AbsorbResult, MutationResult;
import '../ffi/op_log.dart' show Operation;
import '../ffi/remotes.dart' show Remote;
import '../ffi/status.dart' show WorkingCopyStatus;
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
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.remote_not_found`, `jj.network_error`).
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
  /// numbers restarting at each side. Symlinks, submodules, non-file conflicts and
  /// unreadable blobs are silently not searched, as the CLI skips them.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.jj_lib_error`).
  Future<List<SearchMatch>> fileSearch({
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
