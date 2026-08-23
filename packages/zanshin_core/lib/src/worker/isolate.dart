// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../ffi/bookmarks.dart' as repo_ffi_bookmarks;
import '../ffi/change.dart' as repo_ffi_change;
// Alias avoids name collision with handle.dart's RepoHandle wrapper.
import '../ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import '../ffi/events.dart'
    show
        RawOpHeadsChangedEvent,
        RawProgressEvent,
        RawWatchErrorEvent,
        RawWorkingCopyHeartbeatEvent,
        ZanshinRawEvent,
        closeEventSink,
        registerEventSink,
        unregisterEventSink;
import '../ffi/graph.dart' as repo_ffi_graph;
import '../ffi/log_forwarder.dart';
import '../ffi/op_log.dart' as repo_ffi_op_log;
import '../ffi/remotes.dart' as repo_ffi_remotes;
import '../ffi/repo.dart' as repo_ffi;
import '../ffi/repo_detect.dart' as repo_ffi_detect;
import '../ffi/status.dart' as repo_ffi_status;

import 'commands.dart';
import 'correlation.dart';
import 'events.dart';
import 'handle.dart';
import 'responses.dart';

final _log = Logger('zanshin.worker');

// Bootstrap record: all SendPorts the worker needs to communicate with main,
// plus two test-only fault-injection flags (3.9-regression tests, AC 15a/15b;
// always false in production — threaded through because a worker isolate's
// entry point can only receive its initial state via this one message).
typedef _WorkerInit = (SendPort, SendPort, SendPort, bool, bool);

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
  // Watcher/progress events (Story 3.6), demuxed to handleId by the worker.
  final ReceivePort _eventPort;
  // For detecting unexpected worker death via addOnExitListener.
  final ReceivePort _exitPort;
  // For detecting worker errors via addErrorListener.
  final ReceivePort _errorPort;
  final Isolate _isolate;
  final CommandCorrelator _correlator;
  final _eventsController = StreamController<RepoEvent>.broadcast();
  var _closed = false;
  // Memoized by [close] so concurrent/repeated callers all await the SAME
  // in-progress shutdown instead of an instantly-completed no-op future.
  Future<void>? _closeFuture;
  // Completed by [_onExitEvent] when the worker isolate's exit event arrives;
  // [_teardown] defers closing _exitPort until then (see [workerExited]).
  final _exited = Completer<void>();

  // Held to satisfy cancel_subscriptions lint; cancelled in _teardown.
  StreamSubscription<dynamic>? _responseSub;
  StreamSubscription<dynamic>? _eventSub;
  StreamSubscription<dynamic>? _exitSub;
  StreamSubscription<dynamic>? _errorSub;

  // Max wait for the worker's startup handshake before treating the spawn as
  // failed (guards against a worker that dies during init before its send).
  static const _handshakeTimeout = Duration(seconds: 10);

  // Max wait for the worker's ShutdownCommand ack before the kill() backstop
  // fires unconditionally (Story 3.6 graceful-shutdown protocol).
  static const _shutdownAckTimeout = Duration(seconds: 5);

  // addErrorListener delivers [errorString, stackTraceString]; pull out the
  // error object (or fall back to the raw message).
  static Object _workerError(dynamic msg) =>
      (msg is List<dynamic> && msg.isNotEmpty) ? (msg[0] as Object) : msg as Object;

  /// Spawn the worker isolate and return when it is ready to accept commands.
  ///
  /// If [Isolate.spawn] throws, the returned [Future] completes with the error
  /// (AC-12). The bootstrap fallback for this path uses `dart:developer` since
  /// FFI logging is not yet available at spawn time.
  ///
  /// [failBeforeHandshake] and [throwAsyncErrorAfterHandshake] are test-only
  /// fault-injection hooks for the two Story 3.9 regression tests (AC 15a/15b)
  /// that this story's pre-handshake event-sink registration and shutdown
  /// protocol organically re-enable; production callers never set them.
  static Future<ZanshinWorker> start({
    @visibleForTesting bool failBeforeHandshake = false,
    @visibleForTesting bool throwAsyncErrorAfterHandshake = false,
  }) async {
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
        (
          bootstrap.sendPort,
          responsePort.sendPort,
          eventPort.sendPort,
          failBeforeHandshake,
          throwAsyncErrorAfterHandshake,
        ),
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
      worker._onExitEvent();
    });
    errorSub.onData((msg) {
      worker._onWorkerDeath(
        StateError('Worker isolate error: ${_workerError(msg)}'),
      );
    });
    worker
      .._responseSub = responsePort.listen(worker._onResponse)
      .._eventSub = eventPort.listen(worker._onEvent)
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

  void _onEvent(dynamic msg) {
    if (msg is! RepoEvent) {
      _log.warning('ZanshinWorker: unexpected event type');
      return;
    }
    _eventsController.add(msg);
  }

  void _onWorkerDeath(Object cause) {
    if (_closed) {
      return;
    }
    _log.warning('ZanshinWorker: worker died unexpectedly');
    _closed = true;
    // FFI-only, any-isolate-safe (AD-2 exemption): the worker cannot cooperate
    // in an unexpected death, so main clears the sink itself — BEFORE the
    // kill: events::dispatch holds the sink lock across the callback
    // invocation, so once unregister returns no in-flight dispatch can still
    // reach the callable, and the kill below cannot race a delivery. Any
    // dispatch thread still holding an open session from the dead worker now
    // hits an empty sink and drops; the event-in-flight-at-the-instant-of-death
    // residual race is documented as accepted (docs/ffi-abi.md "Async events").
    unregisterEventSink();
    // Kill the worker: with errorsAreFatal:false an uncaught worker error is
    // reported but does NOT terminate the isolate, so without this the "dead"
    // worker would keep running and leak its FFI handles. Idempotent — the
    // _closed guard above prevents a double kill via close().
    _isolate.kill(priority: Isolate.immediate);
    _correlator.failAll(cause);
    _teardown();
  }

  // Exit-port handler once the handshake is done: the exit event is the proof
  // the isolate actually terminated (naturally, via the graceful-close
  // backstop kill, or via _onWorkerDeath's kill).
  void _onExitEvent() {
    if (!_exited.isCompleted) {
      _exited.complete();
    }
    if (_closed) {
      // Graceful close (or post-death teardown already ran): finish the exit-
      // port cleanup that _teardown deferred so this event could be observed.
      _exitSub?.cancel().ignore();
      _exitSub = null;
      _exitPort.close();
      return;
    }
    _onWorkerDeath(StateError('Worker isolate exited unexpectedly'));
  }

  void _teardown() {
    // Cancel before closing ports; port close also ends subscriptions implicitly.
    _responseSub?.cancel().ignore();
    _eventSub?.cancel().ignore();
    _errorSub?.cancel().ignore();
    _responseSub = null;
    _eventSub = null;
    _errorSub = null;
    _responsePort.close();
    _eventPort.close();
    _errorPort.close();
    _eventsController.close().ignore();
    if (_exited.isCompleted) {
      _exitSub?.cancel().ignore();
      _exitSub = null;
      _exitPort.close();
    }
    // else: _onExitEvent completes _exited on the isolate's exit event and
    // closes the exit port itself — keeping it open until then is what lets
    // tests observe that the isolate is actually gone (AC 15/15b).
  }

  /// Watcher/progress events (Story 3.6), demuxed to `handleId` by the worker.
  ///
  /// Broadcast: subscribe any number of times. Completes when the worker
  /// isolate shuts down (graceful [close] or unexpected death).
  Stream<RepoEvent> get events => _eventsController.stream;

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
  /// Idempotent: repeated calls return the SAME in-progress future, so every
  /// caller — including the app's `onExitRequested` hook — awaits actual
  /// shutdown completion. Called by [ZanshinWorker] users and (indirectly) by
  /// [RepoHandle]'s Dart [Finalizer].
  ///
  /// Runs the Story 3.6 graceful-shutdown protocol: sends a [ShutdownCommand]
  /// the worker uses to close every open repo (joining each session's Rust
  /// dispatch thread), unregister the event sink, and close its
  /// `NativeCallable` — in that order, so no callback can ever fire after a
  /// closed callable (`NativeCallable.listener`'s close-then-invoke clause is
  /// undefined behaviour, api.dart.dev). Waits for the worker's ack up to
  /// [_shutdownAckTimeout]; ack or timeout, [Isolate.kill] then runs
  /// unconditionally as a backstop, exactly as before this story.
  Future<void> close() {
    final Future<void>? inProgress = _closeFuture;
    if (inProgress != null) {
      return inProgress;
    }
    if (_closed) {
      // _onWorkerDeath already tore everything down — nothing left to await.
      return Future.value();
    }
    return _closeFuture = _doClose();
  }

  Future<void> _doClose() async {
    _closed = true;

    // Sent directly (bypassing _sendCommand's now-true _closed guard) so the
    // shutdown handshake itself isn't blocked by the flag it just set.
    final int shutdownId = _correlator.allocateId();
    final Future<WorkerResponse> ack = _correlator.register(shutdownId);
    _commandPort.send(ShutdownCommand(commandId: shutdownId));
    try {
      await ack.timeout(_shutdownAckTimeout);
    } catch (_) {
      // Timeout, or the worker died mid-shutdown — the kill() backstop below
      // covers both; there is nothing more to wait for.
    }

    _isolate.kill(priority: Isolate.immediate);
    // On the ack-timeout path the worker never processed ShutdownCommand: its
    // sink is still registered and its sessions' dispatch threads still live —
    // the killed isolate's callable must not stay reachable. Clear the sink
    // from main (unconditional-clear is designed for exactly this any-isolate
    // cleanup, AD-2 exemption); a no-op after a graceful ack.
    unregisterEventSink();
    _correlator.failAll(StateError('Worker is closed'));
    _teardown();
  }

  /// Completes when the worker isolate's exit event has been observed — i.e.
  /// the isolate is actually GONE, not merely marked closed.
  ///
  /// Test hook (AC 15/15b evidence): both the graceful [close] backstop and
  /// [_onWorkerDeath] kill the isolate; the exit event is the observable proof.
  @visibleForTesting
  Future<void> get workerExited => _exited.future;

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

  /// Read the lane-assigned commit graph for [revset] in the repo identified by
  /// [handleId] (Story 4.6).
  ///
  /// Both expressions are caller pass-throughs (FR-JJ-17): [prioritize] is the
  /// branch-prioritisation revset (`RepoHandle.graphSlice` pre-fills the CLI
  /// default; `none()` = no prioritisation). The graph is re-derived from head
  /// on every call — nothing is cached here or in Rust (ADR-0002); the UI
  /// re-requests when [events] reports an `OpHeadsChangedEvent`.
  ///
  /// Sends a [GraphSliceCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<GraphSlice>` bytes into a [repo_ffi_graph.GraphSlice].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.jj_lib_error`;
  /// full list: `docs/ffi-abi.md` § `zanshin_graph_slice`).
  /// Completes with a [StateError] after [close]. The close-guard [StateError]
  /// is delivered synchronously by [RepoHandle.graphSlice].
  Future<repo_ffi_graph.GraphSlice> graphSlice(
    int handleId, {
    required String revset,
    required String prioritize,
  }) async {
    final Uint8List bytes = await send(
      GraphSliceCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        revset: revset,
        prioritize: prioritize,
      ),
    );
    return repo_ffi_graph.decodeGraphSliceEnvelopeInternal(bytes);
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
/// [init] carries (bootstrapSP, responseSP, eventSP, failBeforeHandshake,
/// throwAsyncErrorAfterHandshake) as a positional record; the last two are
/// test-only fault-injection flags (AC 15a/15b), always false in production.
void _workerEntry(_WorkerInit init) {
  final (bootstrapSP, responseSP, eventSP, failBeforeHandshake, throwAsyncErrorAfterHandshake) = init;

  if (failBeforeHandshake) {
    // AC 15a regression test: a failure in the pre-handshake window (where
    // registerEventSink now runs, below) must surface through start()'s
    // existing death/timeout race instead of hanging forever.
    throw StateError('failBeforeHandshake test injection');
  }

  // Init log forwarding in the worker. zanshin_log is handle-free and
  // tracing's global subscriber is thread-safe (AR-P-5) — safe from any isolate.
  initLogForwarding(level: Level.ALL);
  final log = Logger('zanshin.worker.isolate');

  final commandPort = ReceivePort();

  // Handle table: dense worker-side id → raw u64 (the Rust `*mut RepoSession`
  // value), plus the session-id → handleId map for event demux (Story 3.6;
  // keyed by the process-unique session id since 2026-07-04 — the raw address
  // was ABA-unsafe across close→reopen). Only this function ever extracts a
  // raw pointer from an FFI envelope.
  final Map<int, int> handles = {};
  final Map<int, int> sessionToId = {};
  var nextHandleId = 0;

  // Registration happens BEFORE the handshake send, so a registration
  // failure surfaces through start()'s existing death/timeout race — this is
  // the first worker-side init code that can fail (Story 3.9 review).
  registerEventSink((raw) {
    final int? id = sessionToId[raw.sessionId];
    if (id == null) {
      // Benign close race: the session closed (and left sessionToId) between
      // the Rust dispatch thread reading the event and this handler running.
      // Session ids are process-unique and never reused, so a stale event can
      // ONLY land here (dropped) — never be misattributed to a later session
      // (the former rawToId ABA race, resolved 2026-07-04).
      log.fine('Worker: event for unknown session ${raw.sessionId} — dropped');
      return;
    }
    eventSP.send(_rawEventToRepoEvent(id, raw));
  });

  // Handshake: send the command port back so main can start sending commands.
  bootstrapSP.send(commandPort.sendPort);

  if (throwAsyncErrorAfterHandshake) {
    // AC 15b regression test: an uncaught async error after the handshake
    // must NOT be silently swallowed — errorsAreFatal:false means the
    // isolate itself keeps running, but main's error listener must fire and
    // _onWorkerDeath must kill it (pending commands then fail via failAll).
    scheduleMicrotask(() => throw StateError('throwAsyncErrorAfterHandshake test injection'));
  }

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
          _replyRepoOp(bytes, commandId, handles, sessionToId, responseSP, log, () => nextHandleId++);

        case InitRepoCommand(:final String path, :final int backend):
          final Uint8List bytes = repo_ffi.zanshinRepoInit(path, backend);
          _replyRepoOp(bytes, commandId, handles, sessionToId, responseSP, log, () => nextHandleId++);

        case CloneRepoCommand(:final String url, :final String targetPath):
          final Uint8List bytes = repo_ffi.zanshinRepoClone(url, targetPath);
          _replyRepoOp(bytes, commandId, handles, sessionToId, responseSP, log, () => nextHandleId++);

        case CloseRepoCommand(:final int handleId):
          final int? raw = handles.remove(handleId);
          sessionToId.removeWhere((_, id) => id == handleId);
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

        case GraphSliceCommand(:final int handleId, :final String revset, :final String prioritize):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GraphSliceCommand for unknown handleId $handleId');
            final Uint8List errorBytes = fbs.EnvelopeObjectBuilder(
              ok: false,
              error: fbs.FfiErrorObjectBuilder(
                code: 'ffi.invalid_handle',
                context: 'unknown or closed handleId: $handleId',
              ),
            ).toBytes();
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_graph.zanshinGraphSlice(raw, revset, prioritize);
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
          _replyRepoOp(bytes, commandId, handles, sessionToId, responseSP, log, () => nextHandleId++);

        case ShutdownCommand():
          // Close every repo left open: each join()s its Rust dispatch thread
          // (AC 8) before the loop below unregisters the sink. Best-effort —
          // an individual close failure must not abort the shutdown.
          for (final int raw in handles.values) {
            try {
              repo_ffi.zanshinRepoClose(raw);
            } catch (e) {
              log.warning('Worker: zanshinRepoClose failed during shutdown: $e');
            }
          }
          handles.clear();
          sessionToId.clear();
          closeEventSink();
          responseSP.send((commandId, BufferResult(fbs.EnvelopeObjectBuilder(ok: true).toBytes())));
          commandPort.close();
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

/// Handle open/init/clone FFI bytes: store the raw handle plus the session-id
/// event-demux mapping and reply with [HandleResult] on success, or forward
/// the error envelope as [BufferResult].
void _replyRepoOp(
  Uint8List bytes,
  int commandId,
  Map<int, int> handles,
  Map<int, int> sessionToId,
  SendPort responseSP,
  Logger log,
  int Function() nextId,
) {
  final env = fbs.Envelope(bytes);
  if (env.ok && env.dataType == fbs.PayloadTypeId.RepoHandle) {
    final rh = env.data as fbs.RepoHandle;
    final int raw = rh.handle;
    final int id = nextId();
    handles[id] = raw;
    sessionToId[rh.sessionId] = id;
    log.fine('Worker: repo opened raw=$raw session=${rh.sessionId} → handleId=$id');
    responseSP.send((commandId, HandleResult(id)));
  } else {
    responseSP.send((commandId, BufferResult(bytes)));
  }
}

/// Map a worker-decoded [ZanshinRawEvent] to the public [RepoEvent] sent to
/// main, substituting the already-resolved `handleId` for the raw handle.
RepoEvent _rawEventToRepoEvent(int handleId, ZanshinRawEvent raw) => switch (raw) {
  RawOpHeadsChangedEvent(:final paths) => OpHeadsChangedEvent(handleId, paths),
  RawWorkingCopyHeartbeatEvent(:final paths) => WorkingCopyHeartbeatEvent(handleId, paths),
  RawWatchErrorEvent(:final message) => WatchErrorEvent(handleId, message),
  RawProgressEvent(:final operation, :final progress, :final message) => ProgressEvent(
    handleId,
    operation,
    progress,
    message,
  ),
};

ZanshinFfiException _envelopeToException(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  final fbs.FfiError? err = env.error;
  return ZanshinFfiException(err?.code ?? 'ffi.unknown', err?.context);
}
