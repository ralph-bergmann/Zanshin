// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../ffi/bookmarks.dart' as repo_ffi_bookmarks;
import '../ffi/change.dart' as repo_ffi_change;
// Alias avoids name collision with handle.dart's RepoHandle wrapper.
import '../ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import '../ffi/log_forwarder.dart';
import '../ffi/op_log.dart' as repo_ffi_op_log;
import '../ffi/remotes.dart' as repo_ffi_remotes;
import '../ffi/repo.dart' as repo_ffi;
import '../ffi/repo_detect.dart' as repo_ffi_detect;
import '../ffi/status.dart' as repo_ffi_status;

import 'commands.dart';
import 'correlation.dart';
import 'handle.dart';
import 'responses.dart';

final _log = Logger('zanshin.worker');

// Bootstrap record: all SendPorts the worker needs to communicate with main.
typedef _WorkerInit = (SendPort, SendPort, SendPort);

/// The main-isolate interface to the single long-running worker isolate
/// (AR-AD-4, Story 3.9).
///
/// Spawn via [ZanshinWorker.start]; shut down via [close]. The worker owns all
/// FFI handles for app lifetime — raw pointers never leave the worker (Model A).
class ZanshinWorker {
  ZanshinWorker._({
    required this._commandPort,
    required this._responsePort,
    required this._eventPort,
    required this._exitPort,
    required this._errorPort,
    required this._isolate,
    required this._correlator,
  });

  final SendPort _commandPort;
  // Main's receive end for worker responses.
  final ReceivePort _responsePort;
  // Reserved for Story 3.6 watcher/progress events. No traffic yet, but the
  // port exists so 3.6 can wire the producer without reshaping ZanshinWorker.
  final ReceivePort _eventPort;
  // For detecting unexpected worker death via addOnExitListener.
  final ReceivePort _exitPort;
  // For detecting worker errors via addErrorListener.
  final ReceivePort _errorPort;
  final Isolate _isolate;
  final CommandCorrelator _correlator;
  var _closed = false;

  // Held to satisfy cancel_subscriptions lint; cancelled in _teardown.
  StreamSubscription<dynamic>? _responseSub;
  StreamSubscription<dynamic>? _exitSub;
  StreamSubscription<dynamic>? _errorSub;

  // Max wait for the worker's startup handshake before treating the spawn as
  // failed (guards against a worker that dies during init before its send).
  static const _handshakeTimeout = Duration(seconds: 10);

  // addErrorListener delivers [errorString, stackTraceString]; pull out the
  // error object (or fall back to the raw message).
  static Object _workerError(dynamic msg) =>
      (msg is List<dynamic> && msg.isNotEmpty) ? (msg[0] as Object) : msg as Object;

  /// Spawn the worker isolate and return when it is ready to accept commands.
  ///
  /// If [Isolate.spawn] throws, the returned [Future] completes with the error
  /// (AC-12). The bootstrap fallback for this path uses `dart:developer` since
  /// FFI logging is not yet available at spawn time.
  static Future<ZanshinWorker> start() async {
    final bootstrap = ReceivePort();
    final responsePort = ReceivePort();
    final eventPort = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();

    void closeAllPorts() {
      bootstrap.close();
      responsePort.close();
      eventPort.close();
      exitPort.close();
      errorPort.close();
    }

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn<_WorkerInit>(
        _workerEntry,
        (bootstrap.sendPort, responsePort.sendPort, eventPort.sendPort),
        debugName: 'ZanshinWorker',
        errorsAreFatal: false,
      );
    } catch (e, st) {
      closeAllPorts();
      developer.log(
        'ZanshinWorker: Isolate.spawn failed: $e',
        name: 'zanshin.worker',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }

    // errorsAreFatal:false routes a worker init crash to the error listener;
    // addOnExitListener routes a clean early exit. Attach both before the
    // handshake so neither can be missed.
    isolate
      ..addOnExitListener(exitPort.sendPort)
      ..addErrorListener(errorPort.sendPort);

    // Resolve the handshake by racing the worker's command-port message against
    // early worker death (exit/error) and a timeout. Without the race, a crash
    // before `bootstrapSP.send` would leave `bootstrap` with no message and
    // hang start() — and therefore app boot — forever.
    final handshake = Completer<SendPort>();
    final StreamSubscription<dynamic> bootstrapSub = bootstrap.listen((msg) {
      if (!handshake.isCompleted) {
        handshake.complete(msg! as SendPort);
      }
    });
    final StreamSubscription<dynamic> exitSub = exitPort.listen((_) {
      if (!handshake.isCompleted) {
        handshake.completeError(
          StateError('Worker isolate exited before handshake'),
        );
      }
    });
    final StreamSubscription<dynamic> errorSub = errorPort.listen((msg) {
      if (!handshake.isCompleted) {
        handshake.completeError(
          StateError('Worker isolate error before handshake: ${_workerError(msg)}'),
        );
      }
    });

    final SendPort commandPort;
    try {
      commandPort = await handshake.future.timeout(_handshakeTimeout);
    } catch (e, st) {
      await bootstrapSub.cancel();
      await exitSub.cancel();
      await errorSub.cancel();
      isolate.kill(priority: Isolate.immediate);
      closeAllPorts();
      developer.log(
        'ZanshinWorker: worker failed during startup: $e',
        name: 'zanshin.worker',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }

    // Handshake done. Drop the bootstrap channel and repoint the exit/error
    // subscriptions at the permanent death handler. ReceivePort is
    // single-subscription, so we swap onData rather than re-listen. No await
    // between here and the repoint, so no death event can slip past the stale
    // handshake handlers.
    unawaited(bootstrapSub.cancel());
    bootstrap.close();

    final correlator = CommandCorrelator();
    final worker = ZanshinWorker._(
      commandPort: commandPort,
      responsePort: responsePort,
      eventPort: eventPort,
      exitPort: exitPort,
      errorPort: errorPort,
      isolate: isolate,
      correlator: correlator,
    );

    exitSub.onData((_) {
      worker._onWorkerDeath(StateError('Worker isolate exited unexpectedly'));
    });
    errorSub.onData((msg) {
      worker._onWorkerDeath(
        StateError('Worker isolate error: ${_workerError(msg)}'),
      );
    });
    worker
      .._responseSub = responsePort.listen(worker._onResponse)
      .._exitSub = exitSub
      .._errorSub = errorSub;

    return worker;
  }

  void _onResponse(dynamic msg) {
    if (msg is! (int, WorkerResponse)) {
      _log.warning('ZanshinWorker: unexpected response type');
      return;
    }
    final (int id, WorkerResponse response) = msg;
    _correlator.resolve(id, response);
  }

  void _onWorkerDeath(Object cause) {
    if (_closed) {
      return;
    }
    _log.warning('ZanshinWorker: worker died unexpectedly');
    _closed = true;
    // Kill the worker: with errorsAreFatal:false an uncaught worker error is
    // reported but does NOT terminate the isolate, so without this the "dead"
    // worker would keep running and leak its FFI handles. Idempotent — the
    // _closed guard above prevents a double kill via close().
    _isolate.kill(priority: Isolate.immediate);
    _correlator.failAll(cause);
    _teardown();
  }

  void _teardown() {
    // Cancel before closing ports; port close also ends subscriptions implicitly.
    _responseSub?.cancel().ignore();
    _exitSub?.cancel().ignore();
    _errorSub?.cancel().ignore();
    _responseSub = null;
    _exitSub = null;
    _errorSub = null;
    _responsePort.close();
    _eventPort.close();
    _exitPort.close();
    _errorPort.close();
  }

  // ── Typed command API ─────────────────────────────────────────────────────

  /// Open an existing jj repository at [path].
  ///
  /// Returns a [RepoHandle] with `handleId` as a small dense integer (first
  /// is `0`). Throws [ZanshinFfiException] on FFI errors (`jj.repo_not_found`
  /// / `jj.path_not_found`). Throws [StateError] synchronously after [close].
  Future<RepoHandle> openRepo(String path) async {
    final WorkerResponse response = await _sendCommand(
      OpenRepoCommand(commandId: _correlator.allocateId(), path: path),
    );
    return _handleOrThrow(response);
  }

  /// Initialise a new jj repository at [path].
  ///
  /// [backend]: `0` = native/simple, `1` = Git.
  Future<RepoHandle> initRepo(String path, {required int backend}) async {
    final WorkerResponse response = await _sendCommand(
      InitRepoCommand(
        commandId: _correlator.allocateId(),
        path: path,
        backend: backend,
      ),
    );
    return _handleOrThrow(response);
  }

  /// Clone a remote repository from [url] into [targetPath].
  Future<RepoHandle> cloneRepo({
    required String url,
    required String targetPath,
  }) async {
    final WorkerResponse response = await _sendCommand(
      CloneRepoCommand(
        commandId: _correlator.allocateId(),
        url: url,
        targetPath: targetPath,
      ),
    );
    return _handleOrThrow(response);
  }

  RepoHandle _handleOrThrow(WorkerResponse response) => switch (response) {
    HandleResult(:final handleId) => RepoHandle(this, handleId),
    BufferResult(:final bytes) => throw _envelopeToException(bytes),
  };

  /// Generic path for read commands (Story 3.4b).
  ///
  /// Sends [cmd] to the worker and returns the raw `Envelope` bytes for the
  /// caller to decode via the generated FlatBuffers accessors.
  ///
  /// Throws [StateError] (`'Worker is closed'`) synchronously after [close].
  Future<Uint8List> send(WorkerCommand cmd) async {
    final WorkerResponse response = await _sendCommand(cmd);
    return switch (response) {
      BufferResult(:final bytes) => bytes,
      HandleResult() => throw StateError('send() received HandleResult — use openRepo/initRepo/cloneRepo'),
    };
  }

  Future<WorkerResponse> _sendCommand(WorkerCommand cmd) {
    if (_closed) {
      throw StateError('Worker is closed');
    }
    final Future<WorkerResponse> future = _correlator.register(cmd.commandId);
    _commandPort.send(cmd);
    return future;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Close the worker isolate and fail all in-flight commands.
  ///
  /// Idempotent: subsequent calls are no-ops. Called by [ZanshinWorker] users
  /// and (indirectly) by [RepoHandle]'s Dart [Finalizer].
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _correlator.failAll(StateError('Worker is closed'));
    _isolate.kill(priority: Isolate.immediate);
    _teardown();
  }

  /// Close the repository identified by [handleId] on the worker side.
  ///
  /// Called by [RepoHandle.close] and its Dart [Finalizer]. Returns silently
  /// when the worker is already closed (caller swallows [StateError]); a
  /// genuine `ffi.invalid_handle` surfaces as [ZanshinFfiException].
  Future<void> closeRepo(int handleId) async {
    if (_closed) {
      return;
    }
    final WorkerResponse response = await _sendCommand(
      CloseRepoCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    switch (response) {
      case BufferResult(:final bytes):
        final env = fbs.Envelope(bytes);
        if (!env.ok) {
          final fbs.FfiError? err = env.error;
          throw ZanshinFfiException(err?.code ?? 'ffi.unknown', err?.context);
        }
      case HandleResult():
        // Should never happen for a close command — no action needed.
        break;
    }
  }

  /// Read the working-copy status for the repo identified by [handleId].
  ///
  /// Sends a [StatusCommand] via the existing [send] path and decodes the
  /// returned FlatBuffers `Envelope<Status>` bytes into a `WorkingCopyStatus`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.no_working_copy`). Completes with a [StateError] after [close] (this
  /// method is `async`, so the close-guard error is delivered via the Future).
  Future<repo_ffi_status.WorkingCopyStatus> status(int handleId) async {
    final Uint8List bytes = await send(
      StatusCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_status.decodeStatusEnvelopeInternal(bytes);
  }

  /// Read full change metadata for [changeId] in the repo identified by [handleId].
  ///
  /// Sends a [GetChangeCommand] via the existing [send] path and decodes the
  /// returned FlatBuffers `Envelope<Change>` bytes into a [repo_ffi_change.Change].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.change_not_found`). Completes with a [StateError] after [close] (this
  /// method is `async`, so the close-guard error is delivered via the Future).
  Future<repo_ffi_change.Change> getChange(int handleId, String changeId) async {
    final Uint8List bytes = await send(
      GetChangeCommand(commandId: _correlator.allocateId(), handleId: handleId, changeId: changeId),
    );
    return repo_ffi_change.decodeChangeEnvelopeInternal(bytes);
  }

  /// Read the operation log for the repo identified by [handleId].
  ///
  /// `limit < 0` returns all operations; `limit >= 0` returns at most [limit]
  /// most-recent operations. Sends an [OpLogCommand] via [send] and decodes the
  /// returned FlatBuffers `Envelope<OpLog>` bytes into a `List<Operation>`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.jj_lib_error`). Completes with a [StateError] after [close].
  /// The close-guard [StateError] is delivered synchronously by [RepoHandle.opLog].
  Future<List<repo_ffi_op_log.Operation>> opLog(int handleId, int limit) async {
    final Uint8List bytes = await send(
      OpLogCommand(commandId: _correlator.allocateId(), handleId: handleId, limit: limit),
    );
    return repo_ffi_op_log.decodeOpLogEnvelopeInternal(bytes);
  }

  /// Read local + tracked-remote bookmarks for the repo identified by [handleId].
  ///
  /// Sends a [BookmarksCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<Bookmarks>` bytes into a `List<Bookmark>`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.jj_lib_error`). Completes with a [StateError] after [close].
  /// The close-guard [StateError] is delivered synchronously by [RepoHandle.bookmarks].
  Future<List<repo_ffi_bookmarks.Bookmark>> bookmarks(int handleId) async {
    final Uint8List bytes = await send(
      BookmarksCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_bookmarks.decodeBookmarksEnvelopeInternal(bytes);
  }

  /// Read the configured git remotes for the repo identified by [handleId].
  ///
  /// Sends a [RemotesCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<Remotes>` bytes into a `List<Remote>`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.jj_lib_error`). Completes with a [StateError] after [close].
  /// The close-guard [StateError] is delivered synchronously by [RepoHandle.remotes].
  Future<List<repo_ffi_remotes.Remote>> remotes(int handleId) async {
    final Uint8List bytes = await send(
      RemotesCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_remotes.decodeRemotesEnvelopeInternal(bytes);
  }

  /// Detect the repository kind at [path] (FR-JJ-17).
  ///
  /// Returns a [repo_ffi_detect.RepoDetectResult] with the classification and,
  /// when `kind` is `neither`/`pathNotFound`, an optional enclosing-repo
  /// suggestion from the consent-gated ancestor walk (FR-JJ-14).
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `jj.detect_failed`).
  Future<repo_ffi_detect.RepoDetectResult> detect(String path) async {
    final Uint8List bytes = await send(
      DetectRepoCommand(commandId: _correlator.allocateId(), path: path),
    );
    return repo_ffi_detect.decodeRepoDetectEnvelopeInternal(bytes);
  }

  /// Convert the Git repository at [path] to a colocated jj workspace.
  ///
  /// On success returns a [RepoHandle] backed by the new workspace.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `jj.already_jj_repo`,
  /// `jj.not_a_git_repo`, `jj.convert_failed`).
  Future<RepoHandle> convert(String path) async {
    final WorkerResponse response = await _sendCommand(
      ConvertRepoCommand(commandId: _correlator.allocateId(), path: path),
    );
    return _handleOrThrow(response);
  }
}

// ─── Worker entry point ───────────────────────────────────────────────────────

/// Top-level worker-isolate entry point (AR-AD-4, Story 3.9).
///
/// Owns the handle table (`handleId → rawHandle`). Raw `*mut Repo` pointers
/// are extracted from FFI envelopes here and never forwarded to main (Model A).
///
/// [init] carries (bootstrapSP, responseSP, eventSP) as a positional record.
void _workerEntry(_WorkerInit init) {
  final (bootstrapSP, responseSP, _) = init; // eventSP reserved for Story 3.6

  // Init log forwarding in the worker. zanshin_log is handle-free and
  // tracing's global subscriber is thread-safe (AR-P-5) — safe from any isolate.
  initLogForwarding(level: Level.ALL);
  final log = Logger('zanshin.worker.isolate');

  final commandPort = ReceivePort();
  // Handshake: send the command port back so main can start sending commands.
  bootstrapSP.send(commandPort.sendPort);

  // Handle table: dense worker-side id → raw u64 (the Rust `*mut Repo` value).
  // Only this function ever extracts a raw pointer from an FFI envelope.
  final Map<int, int> handles = {};
  var nextHandleId = 0;

  commandPort.listen((msg) {
    if (msg is! WorkerCommand) {
      log.warning('Worker: received unexpected message type');
      return;
    }

    final int commandId = msg.commandId;

    try {
      switch (msg) {
        case OpenRepoCommand(:final String path):
          final Uint8List bytes = repo_ffi.zanshinRepoOpen(path);
          _replyRepoOp(bytes, commandId, handles, responseSP, log, () => nextHandleId++);

        case InitRepoCommand(:final String path, :final int backend):
          final Uint8List bytes = repo_ffi.zanshinRepoInit(path, backend);
          _replyRepoOp(bytes, commandId, handles, responseSP, log, () => nextHandleId++);

        case CloneRepoCommand(:final String url, :final String targetPath):
          final Uint8List bytes = repo_ffi.zanshinRepoClone(url, targetPath);
          _replyRepoOp(bytes, commandId, handles, responseSP, log, () => nextHandleId++);

        case CloseRepoCommand(:final int handleId):
          final int? raw = handles.remove(handleId);
          if (raw == null) {
            log.warning('Worker: CloseRepoCommand for unknown handleId $handleId');
            final Uint8List errorBytes = fbs.EnvelopeObjectBuilder(
              ok: false,
              error: fbs.FfiErrorObjectBuilder(
                code: 'ffi.invalid_handle',
                context: 'unknown or closed handleId: $handleId',
              ),
            ).toBytes();
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi.zanshinRepoClose(raw);
            log.fine('Worker: closed handleId $handleId');
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case StatusCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: StatusCommand for unknown handleId $handleId');
            final Uint8List errorBytes = fbs.EnvelopeObjectBuilder(
              ok: false,
              error: fbs.FfiErrorObjectBuilder(
                code: 'ffi.invalid_handle',
                context: 'unknown or closed handleId: $handleId',
              ),
            ).toBytes();
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_status.zanshinStatus(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GetChangeCommand(:final int handleId, :final String changeId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GetChangeCommand for unknown handleId $handleId');
            final Uint8List errorBytes = fbs.EnvelopeObjectBuilder(
              ok: false,
              error: fbs.FfiErrorObjectBuilder(
                code: 'ffi.invalid_handle',
                context: 'unknown or closed handleId: $handleId',
              ),
            ).toBytes();
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_change.zanshinChange(raw, changeId);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case OpLogCommand(:final int handleId, :final int limit):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: OpLogCommand for unknown handleId $handleId');
            final Uint8List errorBytes = fbs.EnvelopeObjectBuilder(
              ok: false,
              error: fbs.FfiErrorObjectBuilder(
                code: 'ffi.invalid_handle',
                context: 'unknown or closed handleId: $handleId',
              ),
            ).toBytes();
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_op_log.zanshinOpLog(raw, limit);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case BookmarksCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: BookmarksCommand for unknown handleId $handleId');
            final Uint8List errorBytes = fbs.EnvelopeObjectBuilder(
              ok: false,
              error: fbs.FfiErrorObjectBuilder(
                code: 'ffi.invalid_handle',
                context: 'unknown or closed handleId: $handleId',
              ),
            ).toBytes();
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_bookmarks.zanshinBookmarks(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case RemotesCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: RemotesCommand for unknown handleId $handleId');
            final Uint8List errorBytes = fbs.EnvelopeObjectBuilder(
              ok: false,
              error: fbs.FfiErrorObjectBuilder(
                code: 'ffi.invalid_handle',
                context: 'unknown or closed handleId: $handleId',
              ),
            ).toBytes();
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_remotes.zanshinRemotes(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case DetectRepoCommand(:final String path):
          final Uint8List bytes = repo_ffi.zanshinRepoDetect(path);
          responseSP.send((commandId, BufferResult(bytes)));

        case ConvertRepoCommand(:final String path):
          final Uint8List bytes = repo_ffi.zanshinRepoConvert(path);
          _replyRepoOp(bytes, commandId, handles, responseSP, log, () => nextHandleId++);
      }
    } catch (e, st) {
      log.warning('Worker: dispatch error for command $commandId: $e\n$st');
      final Uint8List errorBytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'internal.dispatch_error',
          context: '$e',
        ),
      ).toBytes();
      responseSP.send((commandId, BufferResult(errorBytes)));
    }
  });
}

/// Handle open/init/clone FFI bytes: store the raw handle and reply with
/// [HandleResult] on success, or forward the error envelope as [BufferResult].
void _replyRepoOp(
  Uint8List bytes,
  int commandId,
  Map<int, int> handles,
  SendPort responseSP,
  Logger log,
  int Function() nextId,
) {
  final env = fbs.Envelope(bytes);
  if (env.ok && env.dataType == fbs.PayloadTypeId.RepoHandle) {
    final int raw = (env.data as fbs.RepoHandle).handle;
    final int id = nextId();
    handles[id] = raw;
    log.fine('Worker: repo opened raw=$raw → handleId=$id');
    responseSP.send((commandId, HandleResult(id)));
  } else {
    responseSP.send((commandId, BufferResult(bytes)));
  }
}

ZanshinFfiException _envelopeToException(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  final fbs.FfiError? err = env.error;
  return ZanshinFfiException(err?.code ?? 'ffi.unknown', err?.context);
}
