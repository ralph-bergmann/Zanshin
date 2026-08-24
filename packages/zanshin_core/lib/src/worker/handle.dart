// SPDX-License-Identifier: MIT

import '../ffi/bookmarks.dart' show Bookmark;
import '../ffi/change.dart' show Change;
import '../ffi/graph.dart'
    show GraphSlice, defaultGraphPrioritize, defaultLogRevset, defaultShortPrefixes, defaultSyntheticElided;
import '../ffi/log_defaults.dart' show LogDefaults;
import '../ffi/mutate.dart' show MutationResult;
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
  /// `jj.change_not_found`, `jj.invalid_input`).
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
  /// `jj.change_not_found`).
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
  /// `jj.invalid_input`, `jj.change_not_found`).
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
