// SPDX-License-Identifier: MIT

import '../ffi/bookmarks.dart' show Bookmark;
import '../ffi/change.dart' show Change;
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
