// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../ffi/bookmark_ops.dart' as repo_ffi_bookmark_ops;
import '../ffi/bookmarks.dart' as repo_ffi_bookmarks;
import '../ffi/change.dart' as repo_ffi_change;
import '../ffi/commit.dart' as repo_ffi_commit;
import '../ffi/commit_contents.dart' as repo_ffi_commit_contents;
import '../ffi/commit_views.dart' as repo_ffi_commit_views;
import '../ffi/config.dart' as repo_ffi_config;
import '../ffi/drop_actions.dart' as repo_ffi_drop_actions;
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
import '../ffi/fetch.dart' as repo_ffi_fetch;
import '../ffi/ffi_buffer.dart' show FfiBuffer;
import '../ffi/file.dart' as repo_ffi_file;
import '../ffi/file_ops.dart' as repo_ffi_file_ops;
import '../ffi/git.dart' as repo_ffi_git;
import '../ffi/graph.dart' as repo_ffi_graph;
import '../ffi/log_defaults.dart' as repo_ffi_log_defaults;
import '../ffi/log_forwarder.dart';
import '../ffi/metaedit_duplicate_fix.dart' as repo_ffi_metaedit_duplicate_fix;
import '../ffi/mutate.dart' as repo_ffi_mutate;
import '../ffi/op_log.dart' as repo_ffi_op_log;
import '../ffi/precondition.dart' as repo_ffi_precondition;
import '../ffi/push.dart' as repo_ffi_push;
import '../ffi/rebase.dart' as repo_ffi_rebase;
import '../ffi/remotes.dart' as repo_ffi_remotes;
import '../ffi/repo.dart' as repo_ffi;
import '../ffi/repo_detect.dart' as repo_ffi_detect;
import '../ffi/request_bytes.dart';
import '../ffi/squash_split.dart' as repo_ffi_squash_split;
import '../ffi/status.dart' as repo_ffi_status;
import '../ffi/warning.dart';
import '../ffi/workspace.dart' as repo_ffi_workspace;
import '../graph_layout/graph_grid_view.dart' show GraphGridView;
import '../graph_layout/layout_input.dart' show maxUtcOffsetMin;
import '../graph_layout/layout_reply.dart' show decodeGraphLayoutReplyInternal, layOutTopology;
import '../graph_layout/layout_request.dart' show LaneOrder, LayoutContractException, LayoutMode;

import 'commands.dart';
import 'correlation.dart';
import 'events.dart';
import 'handle.dart';
import 'network_operation.dart';
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
///
/// Every command's result exposes the call's `warnings` (Story 9.32) — the jj
/// CLI's `Warning: …` blocks as [ZanshinWarning]s, in the CLI's print order,
/// empty when there were none. A list result is a [WarnedList]; a result that
/// was a bare `String` or `void` is a small class carrying the value and the
/// warnings. The creations — [initRepo], [cloneRepo] and [convert] — return a
/// [CreatedRepoHandle]: a [RepoHandle] that also carries the creating call's
/// warnings and, for [convert], its snapshot report (Story 9.33); [openRepo]
/// returns an [OpenedRepoHandle] carrying the warnings of the jj CLI's start-up
/// secure-config fix-up (Story 9.37). Two kinds of member carry none:
/// [closeRepo] and [close] (lifecycle, no CLI counterpart); and [events] (a
/// stream, not a command).
///
/// A failed command throws [ZanshinFfiException], which carries the error
/// envelope's report the same way for every command (Story 9.35): its
/// `warnings` and its `precondition` (the PARTIAL pre-verb snapshot report).
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
    if (msg is _NetworkHandleAnnouncement) {
      _announcedHandles[msg.commandId] = msg.handleId;
      return;
    }
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

  // The handle id of a STARTED network call, by its command id (Story 9.52) —
  // what its NetworkOperation's progress filters on; absent while it is queued.
  final Map<int, int> _announcedHandles = {};

  /// Sends a network call's command through [start] and wraps it as a
  /// [NetworkOperation] (Story 9.52): its `progress` is [events] filtered by
  /// [operation] and the handle id [handleId] answers, subscribed BEFORE the
  /// command goes out so no event is missed. A closed worker fails the result
  /// with a [StateError], as every command's future does.
  NetworkOperation<T> _networkOperation<T>({
    required int commandId,
    required String operation,
    required int? Function() handleId,
    required Future<T> Function() start,
  }) {
    final progress = StreamController<ProgressEvent>();
    final StreamSubscription<RepoEvent> subscription = _eventsController.stream.listen((event) {
      if (event is ProgressEvent && event.operation == operation && event.handleId == handleId()) {
        progress.add(event);
      }
    });
    final Future<T> result = Future.sync(start);
    var done = false;
    result.whenComplete(() {
      done = true;
      _announcedHandles.remove(commandId);
      subscription.cancel().ignore();
      progress.close().ignore();
    }).ignore();
    return NetworkOperation<T>(
      result: result,
      progress: progress.stream,
      cancel: () => done ? Future<void>.value() : _cancelNetwork(commandId),
    );
  }

  Future<void> _cancelNetwork(int targetCommandId) async {
    if (_closed) {
      return;
    }
    await _sendCommand(
      NetworkCancelCommand(commandId: _correlator.allocateId(), targetCommandId: targetCommandId),
    ).then<void>(
      (_) {},
      // The worker closed or died before it answered: nothing is left to cancel.
      onError: (Object _) {},
    );
  }

  // ── Typed command API ─────────────────────────────────────────────────────

  /// Open an existing jj repository at [path].
  ///
  /// Returns an [OpenedRepoHandle] with `handleId` as a small dense integer
  /// (first is `0`). Opening runs the jj CLI's start-up secure-config fix-up
  /// (Story 9.37); its one-shot notices — `jj.config_migrated`,
  /// `jj.config_copied`, `jj.config_regenerated` — are the handle's `warnings`,
  /// and ride a refusal's [ZanshinFfiException] too. Throws
  /// [ZanshinFfiException] on FFI errors (`jj.repo_not_found` /
  /// `jj.path_not_found`). Throws [StateError] synchronously after [close].
  Future<OpenedRepoHandle> openRepo(String path) async {
    final WorkerResponse response = await _sendCommand(
      OpenRepoCommand(commandId: _correlator.allocateId(), path: path),
    );
    switch (response) {
      case HandleResult(:final handleId, :final bytes):
        final (:List<ZanshinWarning> warnings, precondition: _) = repo_ffi_precondition.decodeCreationReportInternal(
          bytes,
        );
        return OpenedRepoHandle(this, handleId, warnings: warnings);
      case BufferResult(:final bytes):
        throw _envelopeToException(bytes);
      case TransferResult():
        throw StateError('openRepo received TransferResult — only GraphTopologyCommand replies with one');
      case GraphLayoutResult():
        throw StateError('openRepo received GraphLayoutResult — only GraphLayoutCommand replies with one');
    }
  }

  /// Initialise a new jj repository at [path] (Story 9.20: `jj git init` for
  /// [backend] `1`, a native workspace for `0`).
  ///
  /// [colocate] / [noColocate] are the CLI's flags (both is
  /// `jj.invalid_input`); neither = the `git.colocate` config, whose builtin
  /// default colocates. [objectHash] is `--object-hash`. A git init creates a
  /// missing [path] (one level), refuses a directory holding `.git/` with
  /// [noColocate] (`jj.git_repo_exists`) and turns it into a colocated
  /// workspace otherwise. The returned handle's `warnings` are the init's —
  /// the start-up environment's alias-table and `immutable_heads()` warnings,
  /// then the colocated finish's (Story 9.33); its `precondition` is `null`
  /// unless an init over `.git/` imported refs.
  ///
  /// A refused init throws [ZanshinFfiException] carrying its warnings. A
  /// failure is not rolled back: the disk is as `jj git init` leaves it, and
  /// the exception's `leftBehind` names, outermost first, the destination the
  /// call created, the `.jj/` it created and — for a new colocated init — the
  /// `.git/` it created (Story 9.58), each while it still
  /// exists — empty for a refusal that wrote nothing — so the UI can offer to
  /// remove them. A `watcher.io_error` comes after a successful init: the
  /// repository is complete, `leftBehind` is empty, and it can be opened
  /// again.
  ///
  /// Throws [ArgumentError] if [path] contains an interior NUL (U+0000) or
  /// [backend] is not `0`/`1`.
  Future<CreatedRepoHandle> initRepo(
    String path, {
    required int backend,
    bool colocate = false,
    bool noColocate = false,
    repo_ffi.ObjectHash? objectHash,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNul(path, 'path');
    if (backend != 0 && backend != 1) {
      throw ArgumentError.value(backend, 'backend', 'must be 0 (native) or 1 (git)');
    }
    final WorkerResponse response = await _sendCommand(
      InitRepoCommand(
        commandId: _correlator.allocateId(),
        path: path,
        backend: backend,
        colocate: colocate,
        noColocate: noColocate,
        objectHash: objectHash,
      ),
    );
    return _createdOrThrow(response);
  }

  /// Clone the Git repository at [source] into [destination] — the CLI's
  /// `jj git clone` (Story 9.20).
  ///
  /// [destination] must be missing or an empty directory
  /// (`jj.destination_not_empty` otherwise, before anything is created).
  /// [remoteName] is `--remote` (`null` = `origin`), [colocate] / [noColocate]
  /// the CLI's flags (neither = `git.colocate`), [depth] `--depth`,
  /// [branches] / [tags] the `-b` / `-t` patterns (`null` = not given),
  /// [objectHash] `--object-hash`. Like the CLI the clone writes three
  /// operations — add the remote, fetch, check out the working branch (the
  /// first exact [branches] name the remote has, else its default branch) — and
  /// the repo presets (`trunk()`, the remote's fetch patterns).
  ///
  /// The returned handle's `warnings` are the clone's, in the jj CLI's order:
  /// the start-up environment's (twice, as the CLI loads it twice),
  /// `jj.clone_branches_unmatched`, `jj.git_import_failed`, then
  /// `jj.identity_missing` once per operation when `user.name`/`user.email` is
  /// empty. A refused clone (`jj.invalid_input`, `jj.destination_not_empty`,
  /// `jj.network_error`, `jj.cancelled`, `jj.jj_lib_error`, `jj.config_error`,
  /// `watcher.io_error`) throws [ZanshinFfiException] carrying the clone's
  /// warnings (Story 9.35) — including `jj.clone_cleanup_failed`, which only an
  /// error envelope carries. A `watcher.io_error` comes after a successful
  /// clone: the repository is complete, `leftBehind` is empty, and it can be
  /// opened again. Progress rides [events] as `operation: "clone"`, under the
  /// handle id the clone gets.
  ///
  /// Returns a [NetworkOperation] (Story 9.52): the clone runs on a helper
  /// isolate, so its `progress` arrives while `result` is pending, and
  /// `cancel()` stops it — `result` then throws `jj.cancelled`, and what the
  /// clone created is removed (a pre-existing empty [destination] stays).
  ///
  /// Throws [ArgumentError] synchronously if a string contains an interior NUL
  /// (U+0000) or [depth] is not in `1..0xFFFFFFFF` (the wire's `uint32`). After
  /// [close] the `result` completes with a [StateError].
  NetworkOperation<CreatedRepoHandle> cloneRepo({
    required String source,
    required String destination,
    String? remoteName,
    bool colocate = false,
    bool noColocate = false,
    int? depth,
    List<String>? branches,
    List<String>? tags,
    repo_ffi.ObjectHash? objectHash,
  }) {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNul(source, 'source');
    rejectInteriorNul(destination, 'destination');
    rejectInteriorNul(remoteName, 'remoteName');
    rejectInteriorNuls(branches ?? const [], 'branches');
    rejectInteriorNuls(tags ?? const [], 'tags');
    if (depth != null && depth <= 0) {
      throw ArgumentError.value(depth, 'depth', 'must be positive');
    }
    if (depth != null && depth > 0xFFFFFFFF) {
      throw ArgumentError.value(depth, 'depth', 'must fit in 32 bits');
    }
    final int commandId = _correlator.allocateId();
    return _networkOperation(
      commandId: commandId,
      operation: 'clone',
      handleId: () => _announcedHandles[commandId],
      start: () => _sendCommand(
        CloneRepoCommand(
          commandId: commandId,
          source: source,
          destination: destination,
          remoteName: remoteName,
          colocate: colocate,
          noColocate: noColocate,
          depth: depth,
          branches: branches,
          tags: tags,
          objectHash: objectHash,
        ),
      ).then(_createdOrThrow),
    );
  }

  /// A creation's reply: the [CreatedRepoHandle] with the report its ok
  /// envelope carries (Story 9.33), or the refusal as [ZanshinFfiException].
  CreatedRepoHandle _createdOrThrow(WorkerResponse response) {
    switch (response) {
      case HandleResult(:final handleId, :final bytes):
        final (:List<ZanshinWarning> warnings, :repo_ffi_precondition.Precondition? precondition) =
            repo_ffi_precondition.decodeCreationReportInternal(bytes);
        return CreatedRepoHandle(this, handleId, warnings: warnings, precondition: precondition);
      case BufferResult(:final bytes):
        throw _envelopeToException(bytes);
      case TransferResult():
        throw StateError('a creation received TransferResult — only GraphTopologyCommand replies with one');
      case GraphLayoutResult():
        throw StateError('a creation received GraphLayoutResult — only GraphLayoutCommand replies with one');
    }
  }

  /// Generic path for read commands (Story 3.4b).
  ///
  /// Sends [cmd] to the worker and returns the raw `Envelope` bytes for the
  /// caller to decode via the generated FlatBuffers accessors.
  ///
  /// Throws [StateError] (`'Worker is closed'`) synchronously after [close].
  ///
  /// This is also the ONE choke point that records a handle-scoped reply's
  /// `Envelope.precondition` (Story 9.26) — ok or error — for
  /// [lastPreconditionOf]; a reply without one (a verb that runs no pre-verb
  /// snapshot, or a refusal before Rust was reached) leaves the last one standing.
  Future<Uint8List> send(WorkerCommand cmd) async {
    final WorkerResponse response = await _sendCommand(cmd);
    return switch (response) {
      BufferResult(:final bytes) => _recordPrecondition(cmd, bytes),
      // The graph topology's one-copy reply (Story 4.12): materialize() hands the
      // bytes over without a further copy.
      TransferResult(:final data) => _recordPrecondition(cmd, data.materialize().asUint8List()),
      HandleResult() => throw StateError('send() received HandleResult — use openRepo/initRepo/cloneRepo'),
      GraphLayoutResult() => throw StateError('send() received GraphLayoutResult — use graphLayout'),
    };
  }

  /// Sends the command [build] makes from a fresh command id and returns the
  /// worker's raw reply, without decoding it or recording its precondition.
  ///
  /// Test hook (Story 4.12): the only way to observe WHICH response type crossed
  /// the isolate boundary — a materialized `TransferableTypedData` and a
  /// `SendPort` copy are indistinguishable once decoded.
  @visibleForTesting
  Future<WorkerResponse> sendRaw(WorkerCommand Function(int commandId) build) =>
      _sendCommand(build(_correlator.allocateId()));

  // Latest pre-verb snapshot report per handle id (Story 9.26); dropped on close.
  final Map<int, repo_ffi_precondition.Precondition> _lastPreconditions = {};

  Uint8List _recordPrecondition(WorkerCommand cmd, Uint8List bytes) {
    if (cmd case HandleScopedCommand(:final int handleId)) {
      final repo_ffi_precondition.Precondition? p = repo_ffi_precondition.decodeEnvelopePreconditionInternal(bytes);
      if (p != null) {
        _lastPreconditions[handleId] = p;
      }
    }
    return bytes;
  }

  /// The pre-verb snapshot report (Story 9.26) of the latest reply for
  /// [handleId] that carried one, or `null` when none has yet. See
  /// [RepoHandle.lastPrecondition].
  repo_ffi_precondition.Precondition? lastPreconditionOf(int handleId) => _lastPreconditions[handleId];

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
    _lastPreconditions.remove(handleId);
    final WorkerResponse response = await _sendCommand(
      CloseRepoCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    switch (response) {
      case BufferResult(:final bytes):
        final env = fbs.Envelope(bytes);
        if (!env.ok) {
          throw repo_ffi_precondition.decodeEnvelopeErrorInternal(env);
        }
      case HandleResult():
        // Should never happen for a close command — no action needed.
        break;
      case TransferResult():
        throw StateError('closeRepo received TransferResult — only GraphTopologyCommand replies with one');
      case GraphLayoutResult():
        throw StateError('closeRepo received GraphLayoutResult — only GraphLayoutCommand replies with one');
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

  /// Read the whole revset's index-only graph topology in the repo identified by
  /// [handleId] (Story 4.12): every node of [revset] in `jj log` order with its
  /// ids, flags, prefix lengths, parent count, edges, refs and working copies,
  /// the node indices each of [anchors] selects, `|all()|`, and — with
  /// [withTimestamps] — every non-root committer timestamp.
  ///
  /// Every argument is a caller pass-through (FR-JJ-17; `RepoHandle.graphTopology`
  /// pre-fills [prioritize] and [shortPrefixes]). The call runs the pre-verb
  /// snapshot (recorded for [lastPreconditionOf]) and re-derives from head;
  /// nothing is cached here or in Rust (ADR-0002) — re-request when [events]
  /// reports an `OpHeadsChangedEvent`.
  ///
  /// Sends a [GraphTopologyCommand]; its reply crosses the isolate boundary
  /// with ONE copy (a `TransferResult`) and is read through the returned
  /// [repo_ffi_graph.GraphTopologyView], which owns its bytes.
  ///
  /// Throws [ArgumentError] if [revset], [prioritize], [shortPrefixes] or an
  /// anchor contains an interior NUL (U+0000). Throws [ZanshinFfiException] on
  /// FFI errors (e.g. `ffi.invalid_handle`, `jj.revset_parse_error`,
  /// `jj.revset_resolution_error`, `jj.jj_lib_error`; full list: `docs/ffi-abi.md`
  /// § `zanshin_graph_topology`). Completes with a [StateError] after [close];
  /// the close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.graphTopology].
  Future<repo_ffi_graph.GraphTopologyView> graphTopology(
    int handleId, {
    required String revset,
    required String prioritize,
    required String shortPrefixes,
    required List<String> anchors,
    required bool withTimestamps,
  }) async {
    // WHY here and not only in the adapter: the adapter runs in the WORKER
    // isolate, where a throw comes back as `internal.dispatch_error` rather than
    // the documented [ArgumentError] (same rule as [commitContents]).
    rejectInteriorNul(revset, 'revset');
    rejectInteriorNul(prioritize, 'prioritize');
    rejectInteriorNul(shortPrefixes, 'shortPrefixes');
    rejectInteriorNuls(anchors, 'anchors');
    final Uint8List bytes = await send(
      GraphTopologyCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        revset: revset,
        prioritize: prioritize,
        shortPrefixes: shortPrefixes,
        anchors: anchors,
        withTimestamps: withTimestamps,
      ),
    );
    return repo_ffi_graph.GraphTopologyView.fromEnvelope(bytes);
  }

  /// Lay out the whole revset's graph in the repo identified by [handleId] (Story 4.11): the
  /// topology of [graphTopology] — re-derived from head on every call, with timestamps iff [mode]
  /// is `free` — laid out by the Dart layout engine on the worker isolate (docs/graph-layout.md).
  ///
  /// Every argument is a caller pass-through (FR-JJ-17; `RepoHandle.graphLayout` pre-fills all
  /// but [revset], [anchors] and [utcOffsetMin]). The call runs the topology call's pre-verb
  /// snapshot, recorded for [lastPreconditionOf]; its warnings are the returned topology's.
  /// Nothing is kept in the worker between commands (ADR-0002). The reply crosses the isolate
  /// boundary as one copy of the topology and one of the grid (`GraphLayoutResult`); both views
  /// own their bytes.
  ///
  /// With [stacks] (Story 4.13) the layout groups linear runs into stack nodes (docs/graph-layout.md
  /// §4.8): [expandedKeys], [collapsedKeys] and [keepOpenKeys] resolve against the topology in the
  /// worker, and the grid has format version 2. With [stacks] false the key lists are ignored.
  ///
  /// Throws [ArgumentError] — before anything is sent — if [revset], [prioritize],
  /// [shortPrefixes] or an anchor contains an interior NUL (U+0000), if [utcOffsetMin] is not
  /// within ±1440 or if [budget] is negative. Throws [ZanshinFfiException] on the topology call's
  /// errors (e.g. `ffi.invalid_handle`, `jj.revset_parse_error`; full list: `docs/ffi-abi.md`
  /// § `zanshin_graph_topology`) and [LayoutContractException] when the topology's values break
  /// a contract rule of docs/graph-layout.md §2. Completes with a [StateError] after [close]; the
  /// close-guard [StateError] is delivered synchronously by [RepoHandle.graphLayout].
  Future<({repo_ffi_graph.GraphTopologyView topology, GraphGridView grid})> graphLayout(
    int handleId, {
    required String revset,
    required String prioritize,
    required String shortPrefixes,
    required List<String> anchors,
    required LayoutMode mode,
    required LaneOrder order,
    required int utcOffsetMin,
    required int budget,
    required bool stacks,
    required List<String> expandedKeys,
    required List<String> collapsedKeys,
    required List<String> keepOpenKeys,
  }) async {
    // WHY here: the worker isolate would report a throw as `internal.dispatch_error` (same rule as
    // [graphTopology]).
    rejectInteriorNul(revset, 'revset');
    rejectInteriorNul(prioritize, 'prioritize');
    rejectInteriorNul(shortPrefixes, 'shortPrefixes');
    rejectInteriorNuls(anchors, 'anchors');
    RangeError.checkValueInInterval(utcOffsetMin, -maxUtcOffsetMin, maxUtcOffsetMin, 'utcOffsetMin');
    RangeError.checkNotNegative(budget, 'budget');
    final cmd = GraphLayoutCommand(
      commandId: _correlator.allocateId(),
      handleId: handleId,
      revset: revset,
      prioritize: prioritize,
      shortPrefixes: shortPrefixes,
      anchors: anchors,
      mode: mode,
      order: order,
      utcOffsetMin: utcOffsetMin,
      budget: budget,
      stacks: stacks,
      expandedKeys: expandedKeys,
      collapsedKeys: collapsedKeys,
      keepOpenKeys: keepOpenKeys,
    );
    final WorkerResponse response = await _sendCommand(cmd);
    switch (response) {
      case GraphLayoutResult(:final topology):
        // materialize() hands the one copy over without a further one.
        final Uint8List bytes = _recordPrecondition(cmd, topology.materialize().asUint8List());
        return decodeGraphLayoutReplyInternal(bytes, response);
      case BufferResult(:final bytes):
        throw _envelopeToException(_recordPrecondition(cmd, bytes));
      case HandleResult():
        throw StateError('graphLayout received HandleResult');
      case TransferResult():
        throw StateError('graphLayout received TransferResult — only GraphTopologyCommand replies with one');
    }
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
  Future<WarnedList<repo_ffi_op_log.Operation>> opLog(int handleId, int limit) async {
    final Uint8List bytes = await send(
      OpLogCommand(commandId: _correlator.allocateId(), handleId: handleId, limit: limit),
    );
    return repo_ffi_op_log.decodeOpLogEnvelopeInternal(bytes);
  }

  /// Read the bookmarks of the repo identified by [handleId] — the rows
  /// `jj bookmark list` prints for the given arguments, in its order, with their
  /// tracking facts (Stories 9.29 and 9.19). See [RepoHandle.bookmarks].
  ///
  /// Sends a [BookmarksCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<Bookmarks>` bytes into a `List<Bookmark>`.
  ///
  /// Throws [ArgumentError] if any pattern or revset contains an interior NUL
  /// (U+0000). Throws [ZanshinFfiException] on FFI errors (e.g.
  /// `ffi.invalid_handle`, `jj.invalid_input`, `jj.revset_parse_error`,
  /// `jj.config_error`, `jj.jj_lib_error`). Completes with a [StateError] after
  /// [close]. The close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.bookmarks].
  Future<WarnedList<repo_ffi_bookmarks.Bookmark>> bookmarks(
    int handleId, {
    List<String> names = const [],
    List<String> revisions = const [],
    List<String> remotes = const [],
    bool allRemotes = false,
    bool tracked = false,
    bool conflicted = false,
    List<repo_ffi_bookmarks.BookmarkSortKey> sort = const [],
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(names, 'names');
    rejectInteriorNuls(revisions, 'revisions');
    rejectInteriorNuls(remotes, 'remotes');
    final Uint8List bytes = await send(
      BookmarksCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        names: names,
        revisions: revisions,
        remotes: remotes,
        allRemotes: allRemotes,
        tracked: tracked,
        conflicted: conflicted,
        sort: sort,
      ),
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
  Future<WarnedList<repo_ffi_remotes.Remote>> remotes(int handleId) async {
    final Uint8List bytes = await send(
      RemotesCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_remotes.decodeRemotesEnvelopeInternal(bytes);
  }

  /// Read the remotes `jj git push` without `--remote` would push to, for the
  /// repo identified by [handleId] (Story 9.54): `git.push`, else the single
  /// remote, else `origin` — each only when it exists, in remote-name order.
  /// Empty when none matches and on a non-Git backend.
  ///
  /// Sends a [GitPushRemotesCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<GitPushRemotes>` bytes.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.config_error`, `jj.invalid_input`, `jj.stale_working_copy`,
  /// `jj.jj_lib_error`). Completes with a [StateError] after [close]; the
  /// close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.gitPushRemotes].
  Future<WarnedList<String>> gitPushRemotes(int handleId) async {
    final Uint8List bytes = await send(
      GitPushRemotesCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_remotes.decodeGitPushRemotesEnvelopeInternal(bytes);
  }

  /// Read the remotes `jj git fetch` without `--remote` would fetch from, for
  /// the repo identified by [handleId] (Story 9.30): `git.fetch`, else the
  /// single remote, else `origin` — each only when it exists, in remote-name
  /// order. Empty when none matches (the Fetch button's enable rule) and on a
  /// non-Git backend.
  ///
  /// Sends a [GitFetchRemotesCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<GitFetchRemotes>` bytes.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.config_error`, `jj.invalid_input`, `jj.stale_working_copy`,
  /// `jj.jj_lib_error`). Completes with a [StateError] after [close]; the
  /// close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.gitFetchRemotes].
  Future<WarnedList<String>> gitFetchRemotes(int handleId) async {
    final Uint8List bytes = await send(
      GitFetchRemotesCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_remotes.decodeGitFetchRemotesEnvelopeInternal(bytes);
  }

  /// Read the effective `jj log` defaults for the repo identified by [handleId]
  /// (Story 4.9).
  ///
  /// Sends a [LogDefaultsCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<LogDefaults>` bytes into a `LogDefaults`.
  ///
  /// The config stack is re-read Rust-side on every call (never cached), so a
  /// config file edited between two calls is reflected in the second.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.config_error`). Completes with a [StateError] after [close].
  /// The close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.logDefaults].
  Future<repo_ffi_log_defaults.LogDefaults> logDefaults(int handleId) async {
    final Uint8List bytes = await send(
      LogDefaultsCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_log_defaults.decodeLogDefaultsEnvelopeInternal(bytes);
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
  /// On success returns a [CreatedRepoHandle] backed by the new workspace. Its
  /// `precondition` is the report of the snapshot the conversion runs (the jj
  /// CLI's `jj git init` snapshots the working copy once) and its `warnings`
  /// are the conversion's, in the CLI's order — e.g. `jj.git_import_failed`,
  /// `jj.snapshot_files_refused`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `jj.already_jj_repo`,
  /// `jj.not_a_git_repo`, `jj.convert_failed`), carrying the failed
  /// conversion's warnings and its PARTIAL snapshot report (Story 9.35). The
  /// conversion never touches the working copy or `.git/`, and a failure is
  /// not rolled back: the disk is as `jj git init` leaves it, and the
  /// exception's `leftBehind` names the `.jj/` it left (Story 9.57), so the UI
  /// can offer to remove it. A `watcher.io_error` comes after a successful
  /// conversion: the repository is complete, `leftBehind` is empty, and it
  /// can be opened again.
  Future<CreatedRepoHandle> convert(String path) async {
    final WorkerResponse response = await _sendCommand(
      ConvertRepoCommand(commandId: _correlator.allocateId(), path: path),
    );
    return _createdOrThrow(response);
  }

  /// Rewrite the description of [changeId] in the repo identified by [handleId]
  /// (Story 6.5).
  ///
  /// Sends a [DescribeCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes into a [repo_ffi_mutate.MutationResult].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.change_not_found`, `jj.invalid_input`, `jj.immutable`,
  /// `jj.config_error`). Completes with a [StateError]
  /// after [close]. The close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.describe].
  Future<repo_ffi_mutate.MutationResult> describe(
    int handleId, {
    required String changeId,
    required String description,
  }) async {
    final Uint8List bytes = await send(
      DescribeCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        changeId: changeId,
        description: description,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Create a new, empty change in the repo identified by [handleId] — on top
  /// of [parents], or inserted after [insertAfter] / before [insertBefore]
  /// (`jj new -A` / `-B`, Story 9.48; empty = the flag not given) — and switch
  /// the working copy to it (Story 6.5).
  ///
  /// Sends a [NewChangeCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes into a [repo_ffi_mutate.MutationResult].
  ///
  /// Throws [ArgumentError] if a [parents] / [insertAfter] / [insertBefore]
  /// entry contains an interior NUL (U+0000). Throws [ZanshinFfiException] on FFI errors (e.g.
  /// `ffi.invalid_handle`, `jj.invalid_input`, `jj.change_not_found`,
  /// `jj.immutable`, `jj.config_error`). Completes with a [StateError] after
  /// [close]. The close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.newChange].
  Future<repo_ffi_mutate.MutationResult> newChange(
    int handleId,
    List<String> parents, {
    List<String> insertAfter = const [],
    List<String> insertBefore = const [],
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(parents, 'parents');
    rejectInteriorNuls(insertAfter, 'insertAfter');
    rejectInteriorNuls(insertBefore, 'insertBefore');
    final Uint8List bytes = await send(
      NewChangeCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        parents: parents,
        insertAfter: insertAfter,
        insertBefore: insertBefore,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Switch the working copy to [changeId] without creating a new commit, in
  /// the repo identified by [handleId] (Story 6.5).
  ///
  /// Sends an [EditCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes into a [repo_ffi_mutate.MutationResult].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.change_not_found`, `jj.immutable`, `jj.config_error`). Completes with a
  /// [StateError] after [close]. The close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.edit].
  Future<repo_ffi_mutate.MutationResult> edit(int handleId, String changeId) async {
    final Uint8List bytes = await send(
      EditCommand(commandId: _correlator.allocateId(), handleId: handleId, changeId: changeId),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Abandon [changeIds] in the repo identified by [handleId] (Story 6.5).
  ///
  /// Sends an [AbandonCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes into a [repo_ffi_mutate.MutationResult].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`). Completes with a [StateError]
  /// after [close]. The close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.abandon].
  Future<repo_ffi_mutate.MutationResult> abandon(int handleId, List<String> changeIds) async {
    final Uint8List bytes = await send(
      AbandonCommand(commandId: _correlator.allocateId(), handleId: handleId, changeIds: changeIds),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Undo the last operation of the repo identified by [handleId] — the CLI's
  /// `jj undo` with its undo stack (Story 6.5, Story 9.39); see
  /// [RepoHandle.undo] for [allowCrossWorkspace].
  ///
  /// Sends an [UndoCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes into a [repo_ffi_mutate.MutationResult].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.undo_cross_workspace`, `jj.nothing_to_undo`). Completes with a
  /// [StateError] after [close]. The close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.undo].
  Future<repo_ffi_mutate.MutationResult> undo(
    int handleId, {
    bool allowCrossWorkspace = false,
  }) async {
    final Uint8List bytes = await send(
      UndoCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        allowCrossWorkspace: allowCrossWorkspace,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Fetch the [remotes] and [refs] selected and import them, in the repo
  /// identified by [handleId] — the CLI's `jj git fetch` (Stories 6.5, 9.30).
  /// See [RepoHandle.gitFetch].
  ///
  /// Progress rides [events] as a `ProgressEvent` with this [handleId], demuxed
  /// by the worker's session-id table (same mechanism as watcher events).
  ///
  /// Sends a [GitFetchCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<GitFetchResult>` bytes into a [repo_ffi_fetch.GitFetchResult].
  ///
  /// The `result` throws [ZanshinFfiException] on FFI errors (e.g.
  /// `ffi.invalid_handle`, `jj.invalid_input` — "No git remotes to fetch from"
  /// included —, `jj.not_a_git_repo`, `jj.config_error`, `jj.remote_not_found`
  /// — a matched remote that vanished —, `jj.network_error`, `jj.cancelled`,
  /// `jj.jj_lib_error`); a pattern with an interior NUL
  /// (U+0000) is refused inside the helper isolate by the FFI adapter's guard
  /// and answers `internal.dispatch_error`.
  ///
  /// Returns a [NetworkOperation] (Story 9.52): the fetch runs on a helper
  /// isolate — later commands for [handleId] wait for it, other repos do not —
  /// so its `progress` arrives while `result` is pending, and `cancel()` stops
  /// it: `result` then throws `jj.cancelled` and no operation is written.
  /// After [close] the `result` completes with a [StateError]; the
  /// closed-handle [StateError] is thrown synchronously by
  /// [RepoHandle.gitFetch].
  NetworkOperation<repo_ffi_fetch.GitFetchResult> gitFetch(
    int handleId, {
    repo_ffi_fetch.FetchRemotes remotes = const repo_ffi_fetch.DefaultFetchRemotes(),
    repo_ffi_fetch.FetchRefs refs = const repo_ffi_fetch.DefaultFetchRefs(),
  }) {
    final int commandId = _correlator.allocateId();
    return _networkOperation(
      commandId: commandId,
      operation: 'fetch',
      handleId: () => _announcedHandles[commandId],
      start: () => send(
        GitFetchCommand(commandId: commandId, handleId: handleId, remotes: remotes, refs: refs),
      ).then(repo_ffi_fetch.decodeGitFetchResultEnvelopeInternal),
    );
  }

  /// Ask [remoteName] what it has now and diff that against the head view,
  /// without fetching, in the repo identified by [handleId] (Story 9.24). See
  /// [RepoHandle.remoteChanges].
  ///
  /// Sends a [GitRemoteChangesCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<RemoteChanges>` bytes. A [NetworkOperation] like
  /// [gitFetch]: it runs on a helper isolate, later commands for [handleId]
  /// wait for it, and `cancel()` stops its git (`jj.cancelled`). git sends no
  /// progress for it, so `progress` stays empty.
  NetworkOperation<WarnedList<repo_ffi_remotes.RemoteRefChange>> remoteChanges(int handleId, String remoteName) {
    final int commandId = _correlator.allocateId();
    return _networkOperation(
      commandId: commandId,
      operation: 'remote_changes',
      handleId: () => _announcedHandles[commandId],
      start: () => send(
        GitRemoteChangesCommand(commandId: commandId, handleId: handleId, remoteName: remoteName),
      ).then(repo_ffi_remotes.decodeRemoteChangesEnvelopeInternal),
    );
  }

  /// Push bookmarks and tags to git remotes, in the repo identified by
  /// [handleId] (Story 9.20) — the CLI's `jj git push`. See
  /// [RepoHandle.gitPush].
  ///
  /// Sends a [GitPushCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<GitPushResult>` bytes.
  ///
  /// Returns a [NetworkOperation] (Story 9.52): the push runs on a helper
  /// isolate — later commands for [handleId] wait for it — and `cancel()`
  /// stops it before the next remote; the cancel is data
  /// (`failure.kind == PushFailureKind.cancelled`, nothing recorded).
  ///
  /// Throws [ArgumentError] synchronously if an argument contains an interior
  /// NUL (U+0000). After [close] the `result` completes with a [StateError].
  NetworkOperation<repo_ffi_push.GitPushResult> gitPush(
    int handleId, {
    List<String>? remotes,
    List<String> bookmarks = const [],
    List<String> tags = const [],
    bool all = false,
    bool tracked = false,
    bool deleted = false,
    bool allowEmptyDescription = false,
    bool allowPrivate = false,
    bool allowConflicts = false,
    List<String> revisions = const [],
    List<String> changes = const [],
    List<String> named = const [],
    bool dryRun = false,
    List<String> options = const [],
  }) {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(remotes ?? const [], 'remotes');
    rejectInteriorNuls(bookmarks, 'bookmarks');
    rejectInteriorNuls(tags, 'tags');
    rejectInteriorNuls(revisions, 'revisions');
    rejectInteriorNuls(changes, 'changes');
    rejectInteriorNuls(named, 'named');
    rejectInteriorNuls(options, 'options');
    final int commandId = _correlator.allocateId();
    return _networkOperation(
      commandId: commandId,
      operation: 'push',
      handleId: () => _announcedHandles[commandId],
      start: () => send(
        GitPushCommand(
          commandId: commandId,
          handleId: handleId,
          remotes: remotes,
          bookmarks: bookmarks,
          tags: tags,
          all: all,
          tracked: tracked,
          deleted: deleted,
          allowEmptyDescription: allowEmptyDescription,
          allowPrivate: allowPrivate,
          allowConflicts: allowConflicts,
          revisions: revisions,
          changes: changes,
          named: named,
          dryRun: dryRun,
          options: options,
        ),
      ).then(repo_ffi_push.decodeGitPushResultEnvelopeInternal),
    );
  }

  /// Give the paths in [paths] the content they have in another commit, in the
  /// repo identified by [handleId] (Story 9.3).
  ///
  /// A `null` [from]/[into]/[changesIn] applies the CLI's own defaults — see
  /// [RepoHandle.restore]. If the resulting tree already equals the
  /// destination's, no operation is written and `newOpId` is the pre-call head.
  ///
  /// Sends a [RestoreCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes into a [repo_ffi_mutate.MutationResult].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`). Completes with a [StateError] after [close]. The
  /// close-guard [StateError] is delivered synchronously by [RepoHandle.restore].
  Future<repo_ffi_mutate.MutationResult> restore(
    int handleId, {
    String? from,
    String? into,
    String? changesIn,
    List<String> paths = const <String>[],
    bool restoreDescendants = false,
  }) async {
    final Uint8List bytes = await send(
      RestoreCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        from: from,
        into: into,
        changesIn: changesIn,
        paths: paths,
        restoreDescendants: restoreDescendants,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Move each hunk of [from] into the closest commit in [into] where the
  /// corresponding lines were last modified, in the repo identified by
  /// [handleId] (Story 9.3).
  ///
  /// Sends an [AbsorbCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<AbsorbResult>` bytes into a [repo_ffi_mutate.AbsorbResult].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`,
  /// `jj.change_not_found`, `jj.immutable`, `jj.config_error`). Completes with a
  /// [StateError] after [close]. The close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.absorb].
  Future<repo_ffi_mutate.AbsorbResult> absorb(
    int handleId, {
    String? from,
    String? into,
    List<String> paths = const <String>[],
  }) async {
    final Uint8List bytes = await send(
      AbsorbCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        from: from,
        into: into,
        paths: paths,
      ),
    );
    return repo_ffi_mutate.decodeAbsorbResultEnvelopeInternal(bytes);
  }

  /// Move changes from one or more revisions into another, in the repo
  /// identified by [handleId] (Story 9.15) — the CLI's `jj squash`, paths only.
  ///
  /// [revision] (`-r`), [from] (`--from`), [into] (`--into`), [paths],
  /// [message] (`-m`; `null` = no `-m`), [useDestinationMessage] (`-u`) and
  /// [keepEmptied] (`-k`) cross unchanged. Without [message], where the CLI
  /// opens its editor, the combined text [squashPlan] returns is written —
  /// or [editedDescription] (Story 9.54), the user's edit of it, written
  /// without trailers (with [message]: `jj.invalid_input`).
  ///
  /// Sends a [SquashCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if an argument contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error`). Completes
  /// with a [StateError] after [close]; the close-guard [StateError] is
  /// delivered synchronously by [RepoHandle.squash].
  Future<repo_ffi_mutate.MutationResult> squash(
    int handleId, {
    String? revision,
    List<String> from = const [],
    String? into,
    List<String> paths = const [],
    List<String>? message,
    bool useDestinationMessage = false,
    bool keepEmptied = false,
    String? editedDescription,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    _rejectSquashNuls(revision, from, into, paths, message);
    rejectInteriorNul(editedDescription, 'editedDescription');
    final Uint8List bytes = await send(
      SquashCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        revision: revision,
        from: from,
        into: into,
        paths: paths,
        message: message,
        useDestinationMessage: useDestinationMessage,
        keepEmptied: keepEmptied,
        editedDescription: editedDescription,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// The description [squash] with the same arguments would have to ask for,
  /// in the repo identified by [handleId] (Story 9.15). Writes no operation of
  /// its own.
  ///
  /// Sends a [SquashPlanCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<SquashPlan>` bytes.
  ///
  /// Throws as [squash]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.squashPlan].
  Future<repo_ffi_squash_split.SquashPlan> squashPlan(
    int handleId, {
    String? revision,
    List<String> from = const [],
    String? into,
    List<String> paths = const [],
    List<String>? message,
    bool useDestinationMessage = false,
    bool keepEmptied = false,
  }) async {
    _rejectSquashNuls(revision, from, into, paths, message);
    final Uint8List bytes = await send(
      SquashPlanCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        revision: revision,
        from: from,
        into: into,
        paths: paths,
        message: message,
        useDestinationMessage: useDestinationMessage,
        keepEmptied: keepEmptied,
      ),
    );
    return repo_ffi_squash_split.decodeSquashPlanEnvelopeInternal(bytes);
  }

  /// Which verbs [source] can run at each of [locations], in the repo
  /// identified by [handleId] (Story 9.31). Writes no operation of its own.
  ///
  /// Sends a [DropActionsCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<DropActions>` bytes.
  ///
  /// Throws [ArgumentError] (before anything is sent) when an id, path or name
  /// contains an interior NUL, and [ZanshinFfiException] on FFI errors (e.g.
  /// `ffi.invalid_handle`, `jj.invalid_input` for a malformed location). Completes
  /// with a [StateError] after [close]. The close-guard [StateError] is
  /// delivered synchronously by [RepoHandle.dropActions].
  Future<repo_ffi_drop_actions.DropActions> dropActions(
    int handleId,
    repo_ffi_drop_actions.DropSource source,
    List<repo_ffi_drop_actions.DropLocation> locations,
  ) async {
    repo_ffi_drop_actions.rejectDropActionsNuls(source, locations);
    final Uint8List bytes = await send(
      DropActionsCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        source: source,
        locations: locations,
      ),
    );
    return repo_ffi_drop_actions.decodeDropActionsEnvelopeInternal(bytes);
  }

  /// The card menu's verbs for [changeId], in the repo identified by
  /// [handleId] (Story 9.31). Writes no operation of its own.
  ///
  /// Sends a [ChangeActionsCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<ChangeActions>` bytes.
  ///
  /// Throws [ArgumentError] (before anything is sent) for an interior NUL, and
  /// [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`). Completes
  /// with a [StateError] after [close]. The close-guard [StateError] is
  /// delivered synchronously by [RepoHandle.changeActions].
  Future<repo_ffi_drop_actions.ChangeActions> changeActions(int handleId, String changeId) async {
    rejectInteriorNul(changeId, 'changeId');
    final Uint8List bytes = await send(
      ChangeActionsCommand(commandId: _correlator.allocateId(), handleId: handleId, changeId: changeId),
    );
    return repo_ffi_drop_actions.decodeChangeActionsEnvelopeInternal(bytes);
  }

  /// Split a revision in two, in the repo identified by [handleId] (Story
  /// 9.15) — the CLI's `jj split`, paths only.
  ///
  /// [revision] (`-r`, `null` = `@`), [paths] (at least one), [message] (`-m`
  /// for the selected commit), [parallel] and the [onto] / [insertAfter] /
  /// [insertBefore] locations (`null` = the flag not given) cross unchanged,
  /// and so do [editedSelectedDescription] / [editedRemainingDescription]
  /// (Story 9.54, both or neither: the user's edits of the two editor texts,
  /// written without trailers).
  ///
  /// Sends a [SplitCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<SplitResult>` bytes.
  ///
  /// Throws [ArgumentError] if an argument contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error`). Completes
  /// with a [StateError] after [close]; the close-guard [StateError] is
  /// delivered synchronously by [RepoHandle.split].
  Future<repo_ffi_squash_split.SplitResult> split(
    int handleId, {
    required List<String> paths,
    String? revision,
    List<String>? message,
    bool parallel = false,
    List<String>? onto,
    List<String>? insertAfter,
    List<String>? insertBefore,
    String? editedSelectedDescription,
    String? editedRemainingDescription,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNul(revision, 'revision');
    rejectInteriorNuls(paths, 'paths');
    rejectInteriorNuls(message ?? const [], 'message');
    rejectInteriorNuls(onto ?? const [], 'onto');
    rejectInteriorNuls(insertAfter ?? const [], 'insertAfter');
    rejectInteriorNuls(insertBefore ?? const [], 'insertBefore');
    rejectInteriorNul(editedSelectedDescription, 'editedSelectedDescription');
    rejectInteriorNul(editedRemainingDescription, 'editedRemainingDescription');
    final Uint8List bytes = await send(
      SplitCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        revision: revision,
        paths: paths,
        message: message,
        parallel: parallel,
        onto: onto,
        insertAfter: insertAfter,
        insertBefore: insertBefore,
        editedSelectedDescription: editedSelectedDescription,
        editedRemainingDescription: editedRemainingDescription,
      ),
    );
    return repo_ffi_squash_split.decodeSplitResultEnvelopeInternal(bytes);
  }

  /// Commit the working-copy commit, in the repo identified by [handleId]
  /// (Story 9.49) — the CLI's `jj commit -m <message> [paths]`.
  ///
  /// [message] (`-m`, required) and [paths] (PREFIXES, empty = every change)
  /// cross unchanged.
  ///
  /// Sends a [CommitCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if an argument contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.no_working_copy`, `jj.invalid_input`, `jj.config_error`,
  /// `jj.stale_working_copy`, `jj.jj_lib_error`). Completes with a
  /// [StateError] after [close]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.commit].
  Future<repo_ffi_mutate.MutationResult> commit(
    int handleId, {
    required List<String> message,
    List<String> paths = const [],
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(paths, 'paths');
    rejectInteriorNuls(message, 'message');
    final Uint8List bytes = await send(
      CommitCommand(commandId: _correlator.allocateId(), handleId: handleId, paths: paths, message: message),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Move revisions to a new place in the graph, in the repo identified by
  /// [handleId] (Story 9.16) — the CLI's `jj rebase`.
  ///
  /// [branch] / [source] / [revisions] (`-b` / `-s` / `-r`; all empty = `-b
  /// @`), [onto] / [insertAfter] / [insertBefore] (`-o` / `-A` / `-B`) and the
  /// three flags cross unchanged.
  ///
  /// Sends a [RebaseCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if an id contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error`). Completes
  /// with a [StateError] after [close]; the close-guard [StateError] is
  /// delivered synchronously by [RepoHandle.rebase].
  Future<repo_ffi_mutate.MutationResult> rebase(
    int handleId, {
    List<String> branch = const [],
    List<String> source = const [],
    List<String> revisions = const [],
    List<String> onto = const [],
    List<String> insertAfter = const [],
    List<String> insertBefore = const [],
    bool skipEmptied = false,
    bool keepDivergent = false,
    bool simplifyParents = false,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(branch, 'branch');
    rejectInteriorNuls(source, 'source');
    rejectInteriorNuls(revisions, 'revisions');
    rejectInteriorNuls(onto, 'onto');
    rejectInteriorNuls(insertAfter, 'insertAfter');
    rejectInteriorNuls(insertBefore, 'insertBefore');
    final Uint8List bytes = await send(
      RebaseCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        branch: branch,
        source: source,
        revisions: revisions,
        onto: onto,
        insertAfter: insertAfter,
        insertBefore: insertBefore,
        skipEmptied: skipEmptied,
        keepDivergent: keepDivergent,
        simplifyParents: simplifyParents,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Make [changeIds] siblings, in the repo identified by [handleId] (Story
  /// 9.16) — the CLI's `jj parallelize`.
  ///
  /// Sends a [ParallelizeCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if an id contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.change_not_found`, `jj.immutable`, `jj.config_error`,
  /// `jj.stale_working_copy`, `jj.jj_lib_error`). Completes with a
  /// [StateError] after [close]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.parallelize].
  Future<repo_ffi_mutate.MutationResult> parallelize(int handleId, List<String> changeIds) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(changeIds, 'changeIds');
    final Uint8List bytes = await send(
      ParallelizeCommand(commandId: _correlator.allocateId(), handleId: handleId, changeIds: changeIds),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Rearrange revisions, in the repo identified by [handleId] (Story 9.16) —
  /// the CLI's `jj arrange` with its TUI session as data: [revisions] (empty =
  /// the `revsets.arrange` setting) and the TUI's key [actions], replayed in
  /// order.
  ///
  /// Sends an [ArrangeCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if an id contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`,
  /// `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error`). Completes
  /// with a [StateError] after [close]; the close-guard [StateError] is
  /// delivered synchronously by [RepoHandle.arrange].
  Future<repo_ffi_mutate.MutationResult> arrange(
    int handleId, {
    List<String> revisions = const [],
    List<repo_ffi_rebase.ArrangeAction> actions = const [],
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(revisions, 'revisions');
    rejectInteriorNuls([for (final action in actions) action.changeId], 'actions');
    final Uint8List bytes = await send(
      ArrangeCommand(commandId: _correlator.allocateId(), handleId: handleId, revisions: revisions, actions: actions),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Modify revisions' metadata, in the repo identified by [handleId] (Story
  /// 9.9) — the CLI's `jj metaedit`.
  ///
  /// [revisions] (empty = `@`), [message] (`null` = no `-m`), [author] /
  /// [updateAuthor], [authorTimestamp] / [updateAuthorTimestamp],
  /// [updateChangeId] and [forceRewrite] cross unchanged.
  ///
  /// Sends a [MetaeditCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if a value contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.revset_resolution_error`,
  /// `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`,
  /// `jj.jj_lib_error`). Completes with a [StateError] after [close]; the
  /// close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.metaedit].
  Future<repo_ffi_mutate.MutationResult> metaedit(
    int handleId, {
    List<String> revisions = const [],
    bool updateChangeId = false,
    List<String>? message,
    bool updateAuthorTimestamp = false,
    bool updateAuthor = false,
    String? author,
    String? authorTimestamp,
    bool forceRewrite = false,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(revisions, 'revisions');
    rejectInteriorNuls(message ?? const [], 'message');
    rejectInteriorNuls([?author], 'author');
    rejectInteriorNuls([?authorTimestamp], 'authorTimestamp');
    final Uint8List bytes = await send(
      MetaeditCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        revisions: revisions,
        updateChangeId: updateChangeId,
        message: message,
        updateAuthorTimestamp: updateAuthorTimestamp,
        updateAuthor: updateAuthor,
        author: author,
        authorTimestamp: authorTimestamp,
        forceRewrite: forceRewrite,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Duplicate revisions, in the repo identified by [handleId] (Story 9.9) —
  /// the CLI's `jj duplicate`: [revisions] (empty = `@`) onto their parents, or
  /// to [onto] / [insertAfter] / [insertBefore] (`-o` / `-A` / `-B`).
  ///
  /// Sends a [DuplicateCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if an id contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.revset_resolution_error`,
  /// `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`,
  /// `jj.jj_lib_error`). Completes with a [StateError] after [close]; the
  /// close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.duplicate].
  Future<repo_ffi_mutate.MutationResult> duplicate(
    int handleId, {
    List<String> revisions = const [],
    List<String> onto = const [],
    List<String> insertAfter = const [],
    List<String> insertBefore = const [],
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(revisions, 'revisions');
    rejectInteriorNuls(onto, 'onto');
    rejectInteriorNuls(insertAfter, 'insertAfter');
    rejectInteriorNuls(insertBefore, 'insertBefore');
    final Uint8List bytes = await send(
      DuplicateCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        revisions: revisions,
        onto: onto,
        insertAfter: insertAfter,
        insertBefore: insertBefore,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Run the configured fix tools, in the repo identified by [handleId] (Story
  /// 9.9) — the CLI's `jj fix`: [source] (empty = the `revsets.fix` setting),
  /// [paths] (prefixes; empty = every path), [includeUnchangedFiles],
  /// [allLines].
  ///
  /// Sends a [FixCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<FixResult>` bytes.
  ///
  /// Throws [ArgumentError] if a value contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.config_error`, `jj.invalid_input`, `jj.change_not_found`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.immutable`,
  /// `jj.stale_working_copy`, `jj.jj_lib_error`). Completes with a
  /// [StateError] after [close]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.fix].
  Future<repo_ffi_metaedit_duplicate_fix.FixResult> fix(
    int handleId, {
    List<String> source = const [],
    List<String> paths = const [],
    bool includeUnchangedFiles = false,
    bool allLines = false,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(source, 'source');
    rejectInteriorNuls(paths, 'paths');
    final Uint8List bytes = await send(
      FixCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        source: source,
        paths: paths,
        includeUnchangedFiles: includeUnchangedFiles,
        allLines: allLines,
      ),
    );
    return repo_ffi_metaedit_duplicate_fix.decodeFixResultEnvelopeInternal(bytes);
  }

  /// The calling-side interior-NUL guard of [squash] and [squashPlan].
  static void _rejectSquashNuls(
    String? revision,
    List<String> from,
    String? into,
    List<String> paths,
    List<String>? message,
  ) {
    rejectInteriorNul(revision, 'revision');
    rejectInteriorNuls(from, 'from');
    rejectInteriorNul(into, 'into');
    rejectInteriorNuls(paths, 'paths');
    rejectInteriorNuls(message ?? const [], 'message');
  }

  /// List the entries of a revision's tree in the repo identified by [handleId]
  /// (Story 9.4) — the CLI's `jj file list`.
  ///
  /// A `null` [revision] applies the CLI's own `-r` default `@`, snapshotted first
  /// as in the CLI. [paths] entries are repo-relative
  /// PREFIXES; an empty list means all paths. This read writes no operation of its own.
  ///
  /// Sends a [FileListCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<FileList>` bytes into a `List<FileEntry>`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.change_not_found`, `jj.invalid_input`). Completes with a [StateError]
  /// after [close]; the close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.fileList].
  Future<WarnedList<repo_ffi_file.FileEntry>> fileList(
    int handleId, {
    String? revision,
    List<String> paths = const <String>[],
  }) async {
    final Uint8List bytes = await send(
      FileListCommand(commandId: _correlator.allocateId(), handleId: handleId, revision: revision, paths: paths),
    );
    return repo_ffi_file.decodeFileListEnvelopeInternal(bytes);
  }

  /// Read the contents of the files selected by [paths] in the repo identified by
  /// [handleId] (Story 9.4) — the CLI's `jj file show`.
  ///
  /// [paths] may not be empty. Paths that exist but are not renderable as file
  /// content are reported in `FileContents.skipped` rather than failing the call.
  ///
  /// Sends a [FileShowCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<FileContents>` bytes into a [repo_ffi_file.FileContents].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.path_not_found`, `jj.change_not_found`,
  /// `jj.config_error` — this is the only file read that consults the repo's
  /// effective jj config). Completes with a [StateError] after [close]; the
  /// close-guard [StateError] is delivered synchronously by [RepoHandle.fileShow].
  Future<repo_ffi_file.FileContents> fileShow(
    int handleId, {
    required List<String> paths,
    String? revision,
  }) async {
    final Uint8List bytes = await send(
      FileShowCommand(commandId: _correlator.allocateId(), handleId: handleId, revision: revision, paths: paths),
    );
    return repo_ffi_file.decodeFileContentsEnvelopeInternal(bytes);
  }

  /// Annotate [path] line by line in the repo identified by [handleId]
  /// (Story 9.4) — the CLI's `jj file annotate`.
  ///
  /// Sends a [FileAnnotateCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<FileAnnotation>` bytes into a `List<AnnotationLine>`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.path_not_found`, `jj.not_a_file`, `jj.change_not_found`). Completes with a
  /// [StateError] after [close]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.fileAnnotate].
  Future<WarnedList<repo_ffi_file.AnnotationLine>> fileAnnotate(
    int handleId, {
    required String path,
    String? revision,
  }) async {
    final Uint8List bytes = await send(
      FileAnnotateCommand(commandId: _correlator.allocateId(), handleId: handleId, revision: revision, path: path),
    );
    return repo_ffi_file.decodeFileAnnotationEnvelopeInternal(bytes);
  }

  /// Search the files of a revision for [pattern] in the repo identified by
  /// [handleId] (Story 9.4) — the CLI's `jj file search`.
  ///
  /// Sends a [FileSearchCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<FileSearch>` bytes into a [repo_ffi_file.FileSearch].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`). Completes with a [StateError]
  /// after [close]; the close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.fileSearch].
  Future<repo_ffi_file.FileSearch> fileSearch(
    int handleId, {
    required String pattern,
    String? revision,
    List<String> paths = const <String>[],
    bool nameOnly = false,
  }) async {
    final Uint8List bytes = await send(
      FileSearchCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        revision: revision,
        pattern: pattern,
        paths: paths,
        nameOnly: nameOnly,
      ),
    );
    return repo_ffi_file.decodeFileSearchEnvelopeInternal(bytes);
  }

  /// Import the backing git repo's refs into jj's view, in the repo identified by
  /// [handleId] (Story 9.5) — the CLI's `jj git import`.
  ///
  /// In a colocated workspace the pre-verb snapshot has already imported the
  /// refs — see [RepoHandle.gitImport]. If nothing needed importing, no operation is written
  /// and `mutation.newOpId` is the pre-call op-log head. A ref that could not be
  /// imported lands in `failedRefNames` and does NOT fail the call.
  ///
  /// Sends a [GitImportCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<GitImportResult>` bytes into a [repo_ffi_git.GitImportResult].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.not_a_git_repo`, `jj.config_error`). Completes with a [StateError] after
  /// [close]; the close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.gitImport].
  Future<repo_ffi_git.GitImportResult> gitImport(int handleId) async {
    final Uint8List bytes = await send(GitImportCommand(commandId: _correlator.allocateId(), handleId: handleId));
    return repo_ffi_git.decodeGitImportResultEnvelopeInternal(bytes);
  }

  /// Write jj's bookmarks and tags back to the backing git repo, in the repo
  /// identified by [handleId] (Story 9.5) — the CLI's `jj git export`.
  ///
  /// Sends a [GitExportCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<GitExportResult>` bytes into a [repo_ffi_git.GitExportResult].
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.not_a_git_repo`). Completes with a [StateError] after [close]; the
  /// close-guard [StateError] is delivered synchronously by [RepoHandle.gitExport].
  Future<repo_ffi_git.GitExportResult> gitExport(int handleId) async {
    final Uint8List bytes = await send(GitExportCommand(commandId: _correlator.allocateId(), handleId: handleId));
    return repo_ffi_git.decodeGitExportResultEnvelopeInternal(bytes);
  }

  /// Register a new git remote in the repo identified by [handleId] (Story 9.5).
  ///
  /// Sends a [GitRemoteAddCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.remote_exists`, `jj.invalid_input`, `jj.not_a_git_repo`). Completes with
  /// a [StateError] after [close]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.gitRemoteAdd].
  Future<repo_ffi_mutate.MutationResult> gitRemoteAdd(
    int handleId, {
    required String name,
    required String url,
    String? pushUrl,
  }) async {
    final Uint8List bytes = await send(
      GitRemoteAddCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        name: name,
        url: url,
        pushUrl: pushUrl,
      ),
    );
    return repo_ffi_git.decodeGitRemoteEnvelopeInternal(bytes);
  }

  /// Remove a git remote and forget its bookmarks, in the repo identified by
  /// [handleId] (Story 9.5).
  ///
  /// Sends a [GitRemoteRemoveCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.remote_not_found`, `jj.remote_nonstandard_config`). Completes with a
  /// [StateError] after [close]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.gitRemoteRemove].
  Future<repo_ffi_mutate.MutationResult> gitRemoteRemove(int handleId, String name) async {
    final Uint8List bytes = await send(
      GitRemoteRemoveCommand(commandId: _correlator.allocateId(), handleId: handleId, name: name),
    );
    return repo_ffi_git.decodeGitRemoteEnvelopeInternal(bytes);
  }

  /// Rename a git remote in the repo identified by [handleId] (Story 9.5).
  ///
  /// Sends a [GitRemoteRenameCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.remote_not_found`, `jj.remote_exists`, `jj.invalid_input`,
  /// `jj.remote_nonstandard_config`). Completes with a [StateError] after [close];
  /// the close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.gitRemoteRename].
  Future<repo_ffi_mutate.MutationResult> gitRemoteRename(int handleId, String oldName, String newName) async {
    final Uint8List bytes = await send(
      GitRemoteRenameCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        oldName: oldName,
        newName: newName,
      ),
    );
    return repo_ffi_git.decodeGitRemoteEnvelopeInternal(bytes);
  }

  /// Re-point a git remote's fetch and/or push URL, in the repo identified by
  /// [handleId] (Story 9.5). Never writes an operation.
  ///
  /// Sends a [GitRemoteSetUrlCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.remote_not_found`, `jj.invalid_input`). Completes with a [StateError]
  /// after [close]; the close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.gitRemoteSetUrl].
  Future<repo_ffi_mutate.MutationResult> gitRemoteSetUrl(
    int handleId, {
    required String name,
    String? url,
    String? pushUrl,
  }) async {
    final Uint8List bytes = await send(
      GitRemoteSetUrlCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        name: name,
        url: url,
        pushUrl: pushUrl,
      ),
    );
    return repo_ffi_git.decodeGitRemoteEnvelopeInternal(bytes);
  }

  /// Show each revision [revset] denotes with what it changed, in the repo
  /// identified by [handleId] (Story 9.6) — the CLI's `jj show`.
  ///
  /// A `null` [revset] applies the CLI's own default `@`. [revset] is an
  /// EXPRESSION, not a change id, so entries are per COMMIT: a revset naming two
  /// commits of ONE divergent change yields two entries with the same `Change.id`.
  /// A BARE divergent change-id symbol is REFUSED by jj-lib's own `SymbolResolver`
  /// (`jj.revset_resolution_error`), exactly as `jj show <divergent-id>` fails in
  /// the CLI; union the two COMMIT hexes to address both. Unlike [interdiff]'s
  /// two SINGLE revisions, a revset can also name a set and use aliases. This read
  /// writes no operation.
  ///
  /// [limit] is a ZANSHIN-SIDE cap the CLI has no counterpart for, applied in RAW
  /// REVSET order; `null` is the CLI-parity default (unbounded) and `0` is an
  /// empty result, not an error. A limit above the wire field's `uint` ceiling
  /// (4294967295) SATURATES there rather than wrapping to an empty result; a
  /// negative [limit] is an [ArgumentError].
  ///
  /// Sends a [ShowCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<ShowView>` bytes into a `List<ShowEntry>`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error`).
  /// Completes with a [StateError] after [close]; the close-guard [StateError] is
  /// delivered synchronously by [RepoHandle.show].
  Future<WarnedList<repo_ffi_commit_views.ShowEntry>> show(int handleId, {String? revset, int? limit}) async {
    // WHY here and not only in the adapter: the adapter runs in the WORKER
    // isolate, where a throw is caught by the dispatch loop and comes back as
    // `internal.dispatch_error` — not as the [ArgumentError] this method and
    // [RepoHandle.show] both document. Rejecting on the calling side keeps the
    // documented type and spares the round trip. The adapter keeps its own guard
    // as the backstop for a direct caller.
    if (limit != null && limit < 0) {
      throw ArgumentError.value(limit, 'limit', 'must not be negative');
    }
    final Uint8List bytes = await send(
      ShowCommand(commandId: _correlator.allocateId(), handleId: handleId, revset: revset, limit: limit),
    );
    return repo_ffi_commit_views.decodeShowViewEnvelopeInternal(bytes);
  }

  /// Walk the evolution of the changes [revset] denotes, in the repo identified
  /// by [handleId] (Story 9.6) — the CLI's `jj evolog`.
  ///
  /// [limit] is applied in WALK order (the CLI limits before reversing); `0` is an
  /// empty result, not an error, and a limit above the wire field's `uint` ceiling
  /// (4294967295) SATURATES there rather than wrapping to an empty result. A
  /// negative [limit] is an [ArgumentError]. This read writes no operation of its own.
  ///
  /// Sends an [EvologCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<EvologView>` bytes into a `List<EvologEntry>`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error`).
  /// Completes with a [StateError] after [close]; the close-guard [StateError] is
  /// delivered synchronously by [RepoHandle.evolog].
  Future<WarnedList<repo_ffi_commit_views.EvologEntry>> evolog(int handleId, {String? revset, int? limit}) async {
    // WHY here and not only in the adapter: the adapter runs in the WORKER
    // isolate, where a throw is caught by the dispatch loop and comes back as
    // `internal.dispatch_error` — not as the [ArgumentError] this method and
    // [RepoHandle.evolog] both document. Rejecting on the calling side keeps the
    // documented type and spares the round trip. The adapter keeps its own guard
    // as the backstop for a direct caller.
    if (limit != null && limit < 0) {
      throw ArgumentError.value(limit, 'limit', 'must not be negative');
    }
    final Uint8List bytes = await send(
      EvologCommand(commandId: _correlator.allocateId(), handleId: handleId, revset: revset, limit: limit),
    );
    return repo_ffi_commit_views.decodeEvologViewEnvelopeInternal(bytes);
  }

  /// Compare what two revisions each CHANGE, with the parent difference factored
  /// out, in the repo identified by [handleId] (Story 9.6) — the CLI's
  /// `jj interdiff`.
  ///
  /// Each side is a single revision in one of the two `RevisionRef` currencies: a
  /// `ChangeIdRef` (reverse-hex change-id prefix, resolving only to the currently
  /// VISIBLE commit) or a `CommitIdRef` (commit-id hex prefix, resolved through
  /// the index and therefore reaching a HIDDEN commit — which is how [evolog]'s
  /// predecessors are fed back in). Both inherit the CLI `resolve_single_rev`'s
  /// ambiguity REFUSAL; a revset expression is unaddressable on either arm. An
  /// absent side is `@`;
  /// omitting BOTH is refused with `jj.invalid_input`. No
  /// `renamed`/`copied` entry is ever produced — `interdiff` passes no copy
  /// records, the CLI's own asymmetry with `show`. This read writes no operation of its own.
  ///
  /// `InterdiffView.baseHasConflicts` reports whether the REBASED `from` tree —
  /// the left side of the diff — is conflicted; that never turns the call into a
  /// refusal, and it describes the TREE, not the filtered result.
  ///
  /// Sends an [InterdiffCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<InterdiffView>` bytes into an `InterdiffView`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`). Completes with a [StateError]
  /// after [close]; the close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.interdiff].
  Future<repo_ffi_commit_views.InterdiffView> interdiff(
    int handleId, {
    repo_ffi_commit_views.RevisionRef? from,
    repo_ffi_commit_views.RevisionRef? to,
    List<String> paths = const <String>[],
  }) async {
    final Uint8List bytes = await send(
      InterdiffCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        from: from,
        to: to,
        paths: paths,
      ),
    );
    return repo_ffi_commit_views.decodeInterdiffViewEnvelopeInternal(bytes);
  }

  /// List every workspace with its working-copy commit and root directory, in the
  /// repo identified by [handleId] (Story 9.7) — the CLI's `jj workspace list`.
  ///
  /// The name/commit columns are `View::wc_commit_ids()`'s own pair, in jj-lib's
  /// lexicographic order; the path half comes from the workspace store. A row's
  /// `root` is `null` when the path cannot be reported (no recorded path, an
  /// unreadable store, or a directory that moved or was deleted) — that never
  /// fails the listing, which is the CLI's own degradation. This read writes no operation of its own —
  /// the pre-verb snapshot may write one.
  ///
  /// Sends a [WorkspaceListCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<WorkspaceList>` bytes into a `List<WorkspaceEntry>`.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.jj_lib_error`). Completes with a [StateError] after [close]; the
  /// close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.workspaces].
  Future<WarnedList<repo_ffi_workspace.WorkspaceEntry>> workspaces(int handleId) async {
    final Uint8List bytes = await send(
      WorkspaceListCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_workspace.decodeWorkspaceListEnvelopeInternal(bytes);
  }

  /// Return one workspace's absolute root directory, in the repo identified by
  /// [handleId] (Story 9.7) — the CLI's `jj workspace root [--name]`.
  ///
  /// A `null` [name] is the CLI's own default, the CURRENT workspace, and reads
  /// the workspace loader alone — the one path that cannot fail. A PRESENT
  /// [name], even the current workspace's own, goes through the workspace store
  /// and can REFUSE or WARN, because the CLI's named path never shortcuts to the
  /// loader; a recorded directory that does not exist comes back with a
  /// `jj.workspace_path_inaccessible` warning. An explicitly empty [name] is a
  /// VALUE, not an absence. This read writes no operation — not even on a
  /// refusal.
  ///
  /// Sends a [WorkspaceRootCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<WorkspaceRoot>` bytes into the path and the call's
  /// warnings.
  ///
  /// Throws [ArgumentError] if [name] contains an interior NUL (U+0000). Throws
  /// [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.workspace_not_found`, `jj.workspace_no_recorded_path`,
  /// `jj.jj_lib_error`). Completes with a
  /// [StateError] after [close]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.workspaceRoot].
  Future<repo_ffi_workspace.WorkspaceRootResult> workspaceRoot(int handleId, {String? name}) async {
    // WHY here and not only in the adapter: the adapter runs in the WORKER
    // isolate, where a throw is caught by the dispatch loop and comes back as
    // `internal.dispatch_error` — not as the [ArgumentError] this method and
    // [RepoHandle.workspaceRoot] both document. Rejecting on the calling side
    // keeps the documented type and spares the round trip. The adapter keeps its
    // own guard as the backstop for a direct caller. (Same fix Story 9.6's
    // review made for `evolog`'s negative limit.)
    rejectInteriorNul(name, 'name');
    final Uint8List bytes = await send(
      WorkspaceRootCommand(commandId: _correlator.allocateId(), handleId: handleId, name: name),
    );
    return repo_ffi_workspace.decodeWorkspaceRootEnvelopeInternal(bytes);
  }

  /// Add a workspace to the repo identified by [handleId] (Story 9.23) — the
  /// CLI's `jj workspace add`, every argument passed through.
  ///
  /// [destination] is resolved against the current workspace root; a `null`
  /// [name] names the workspace after its final component; [revisions] (the
  /// CLI's `-r` revsets, empty = the current `@`'s parents), [messageParagraphs]
  /// (`-m`), [colocate] (`--colocate` / `--no-colocate`, `null` = the CLI's
  /// default) and [sparse] (`--sparse-patterns`) cross unchanged. The new
  /// workspace is opened with `openRepo(result.workspaceRoot)`.
  ///
  /// Sends a [WorkspaceAddCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<WorkspaceAddResult>` bytes.
  ///
  /// Throws [ArgumentError] if an argument contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (`jj.invalid_input`,
  /// `jj.workspace_exists`, `jj.destination_not_empty`,
  /// `jj.git_worktree_failed`, the revset codes, …). Completes with a
  /// [StateError] after [close]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.workspaceAdd].
  Future<repo_ffi_workspace.WorkspaceAddResult> workspaceAdd(
    int handleId, {
    required String destination,
    String? name,
    List<String> revisions = const [],
    List<String> messageParagraphs = const [],
    bool? colocate,
    repo_ffi_workspace.SparseInheritance sparse = repo_ffi_workspace.SparseInheritance.copy,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNul(destination, 'destination');
    rejectInteriorNul(name, 'name');
    rejectInteriorNuls(revisions, 'revisions');
    rejectInteriorNuls(messageParagraphs, 'messageParagraphs');
    final Uint8List bytes = await send(
      WorkspaceAddCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        destination: destination,
        name: name,
        revisions: revisions,
        messageParagraphs: messageParagraphs,
        colocate: colocate,
        sparse: sparse,
      ),
    );
    return repo_ffi_workspace.decodeWorkspaceAddEnvelopeInternal(bytes);
  }

  /// Bring the stale working copy of the repo identified by [handleId] up to
  /// date (Story 9.23) — the CLI's `jj workspace update-stale`.
  ///
  /// Runs no pre-verb snapshot — it is the recovery a `jj.stale_working_copy`
  /// refusal names. The reply's `precondition` (recorded for
  /// [lastPreconditionOf]) is the recovery's trailing snapshot report.
  ///
  /// Sends a [WorkspaceUpdateStaleCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<StaleRecovery>` bytes.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.concurrent_working_copy`, `jj.config_error`, `jj.stale_working_copy`,
  /// `jj.jj_lib_error`).
  /// Completes with a [StateError] after [close]; the close-guard [StateError]
  /// is delivered synchronously by [RepoHandle.workspaceUpdateStale].
  Future<repo_ffi_workspace.StaleRecovery> workspaceUpdateStale(int handleId) async {
    final Uint8List bytes = await send(
      WorkspaceUpdateStaleCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_workspace.decodeStaleRecoveryEnvelopeInternal(bytes);
  }

  /// Return the object half of each commit in [commitIds] — author, committer
  /// timestamp, FULL description, conflict, empty — read at the pinned operation
  /// [operationId], in [commitIds]' order, in the repo identified by [handleId]
  /// (Story 4.10).
  ///
  /// The continuation of the graph topology call's `jj log`, pinned to the
  /// operation that call returned: it runs no pre-verb snapshot (so
  /// `lastPrecondition` is untouched), records no warning (the result's
  /// `warnings` is always empty) and writes no operation. Ids are FULL hex only.
  ///
  /// Sends a [CommitContentsCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<CommitContents>` bytes.
  ///
  /// Throws [ArgumentError] if [operationId] or any commit id contains an
  /// interior NUL (U+0000). Throws [ZanshinFfiException] on FFI errors (e.g.
  /// `ffi.invalid_handle`, `jj.invalid_input`, `jj.operation_not_found`,
  /// `jj.change_not_found`, `jj.jj_lib_error`). Completes with a [StateError]
  /// after [close]; the close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.commitContents].
  Future<WarnedList<repo_ffi_commit_contents.CommitContent>> commitContents(
    int handleId, {
    required String operationId,
    required List<String> commitIds,
  }) async {
    // WHY here and not only in the adapter: the adapter runs in the WORKER
    // isolate, where a throw comes back as `internal.dispatch_error` rather than
    // the documented [ArgumentError] (same rule as [workspaceRoot]).
    rejectInteriorNul(operationId, 'operationId');
    rejectInteriorNuls(commitIds, 'commitIds');
    final Uint8List bytes = await send(
      CommitContentsCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        operationId: operationId,
        commitIds: commitIds,
      ),
    );
    return repo_ffi_commit_contents.decodeCommitContentsEnvelopeInternal(bytes);
  }

  /// Create local bookmarks pointing at one revision, in the repo identified by
  /// [handleId] (Story 9.8) — the CLI's `jj bookmark create`.
  ///
  /// [names] are EXACT, DECODED bookmark names — the revset quoting the CLI
  /// requires is terminal input syntax the GUI replaces. A `null` [revision] is
  /// the CLI's own `-r` default `@` (snapshotted first, as in the CLI); it is a
  /// jj reverse-hex CHANGE id, so a divergent one is refused, never guessed.
  /// Both per-name preconditions run in ARGUMENT order and are FAIL-FAST: a run
  /// whose second name already exists creates nothing and writes no operation.
  /// A created name is auto-tracked as in the CLI: on every remote with a
  /// remote view whose `remotes.<r>.auto-track-bookmarks` /
  /// `auto-track-created-bookmarks` matches it, the `name@remote` row becomes
  /// tracked. Warnings: `jj.bookmark_target_empty`, then
  /// `jj.bookmark_auto_track_existing` per remote that already holds the name.
  ///
  /// Sends a [BookmarkCreateCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if any name or [revision] contains an interior NUL
  /// (U+0000). Throws [ZanshinFfiException] on FFI errors (e.g.
  /// `ffi.invalid_handle`, `jj.invalid_input`, `jj.change_not_found`,
  /// `jj.bookmark_exists`, `jj.bookmark_tracked_remote_exists`,
  /// `jj.config_error` — e.g. an unparsable `remotes.<r>.auto-track-*` value).
  /// Completes with a [StateError] after [close]; the close-guard [StateError]
  /// is delivered synchronously by [RepoHandle.bookmarkCreate].
  Future<repo_ffi_mutate.MutationResult> bookmarkCreate(
    int handleId,
    List<String> names, {
    String? revision,
  }) async {
    // WHY here and not only in the adapter: the adapter runs in the WORKER
    // isolate, where a throw is caught by the dispatch loop and comes back as
    // `internal.dispatch_error` — not as the [ArgumentError] this method and
    // [RepoHandle.bookmarkCreate] both document. Rejecting on the calling side
    // keeps the documented type and spares the round trip. The adapter keeps its
    // own guard as the backstop for a direct caller. (Same fix Stories 9.6 and
    // 9.7 each had to make in review.)
    rejectInteriorNuls(names, 'names');
    rejectInteriorNul(revision, 'revision');
    final Uint8List bytes = await send(
      BookmarkCreateCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        names: names,
        revision: revision,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Delete the local bookmarks matching [names], in the repo identified by
  /// [handleId] (Story 9.8) — the CLI's `jj bookmark delete`.
  ///
  /// [names] are string PATTERNS, unioned and passed through verbatim: `exact:`,
  /// `glob:`, `regex:`, `substring:` and the `~`/`&`/`|` operators all work, and
  /// a BARE pattern is a GLOB, so a name containing `*`, `?` or `[` needs
  /// `exact:"…"`. Matching NOTHING is a SUCCESS that writes no operation, so the
  /// returned `newOpId` is the pre-call op-log head. A tracked `name@remote`
  /// survives by design and keeps showing up in [bookmarks].
  ///
  /// Sends a [BookmarkDeleteCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if any name contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.invalid_input`). Completes with a [StateError] after [close]; the
  /// close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.bookmarkDelete].
  Future<repo_ffi_mutate.MutationResult> bookmarkDelete(int handleId, List<String> names) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(names, 'names');
    final Uint8List bytes = await send(
      BookmarkDeleteCommand(commandId: _correlator.allocateId(), handleId: handleId, names: names),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Move existing local bookmarks to one revision, in the repo identified by
  /// [handleId] (Story 9.19) — the CLI's `jj bookmark move`. See
  /// [RepoHandle.bookmarkMove].
  ///
  /// Sends a [BookmarkMoveCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if a name, a [from] revset or [to] contains an
  /// interior NUL (U+0000). Throws [ZanshinFfiException] on FFI errors (e.g.
  /// `ffi.invalid_handle`, `jj.invalid_input`, `jj.change_not_found`,
  /// `jj.revset_parse_error`). Completes with a [StateError] after [close].
  Future<repo_ffi_mutate.MutationResult> bookmarkMove(
    int handleId,
    List<String> names, {
    List<String> from = const [],
    String? to,
    bool allowBackwards = false,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(names, 'names');
    rejectInteriorNuls(from, 'from');
    rejectInteriorNul(to, 'to');
    final Uint8List bytes = await send(
      BookmarkMoveCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        names: names,
        from: from,
        to: to,
        allowBackwards: allowBackwards,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Advance the closest bookmarks to a revision, in the repo identified by
  /// [handleId] (Story 9.19) — the CLI's `jj bookmark advance`. See
  /// [RepoHandle.bookmarkAdvance].
  ///
  /// Sends a [BookmarkAdvanceCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if a name or [to] contains an interior NUL
  /// (U+0000). Throws [ZanshinFfiException] on FFI errors (e.g.
  /// `ffi.invalid_handle`, `jj.invalid_input`, `jj.revset_resolution_error`).
  /// Completes with a [StateError] after [close].
  Future<repo_ffi_mutate.MutationResult> bookmarkAdvance(
    int handleId, {
    List<String> names = const [],
    String? to,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(names, 'names');
    rejectInteriorNul(to, 'to');
    final Uint8List bytes = await send(
      BookmarkAdvanceCommand(commandId: _correlator.allocateId(), handleId: handleId, names: names, to: to),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Rename a local bookmark, in the repo identified by [handleId] (Story
  /// 9.19) — the CLI's `jj bookmark rename`. See [RepoHandle.bookmarkRename].
  ///
  /// Sends a [BookmarkRenameCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<MutationResult>` bytes.
  ///
  /// Throws [ArgumentError] if a name contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.bookmark_exists`). Completes with a [StateError]
  /// after [close].
  Future<repo_ffi_mutate.MutationResult> bookmarkRename(
    int handleId,
    String oldName,
    String newName, {
    bool overwriteExisting = false,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNul(oldName, 'oldName');
    rejectInteriorNul(newName, 'newName');
    final Uint8List bytes = await send(
      BookmarkRenameCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        oldName: oldName,
        newName: newName,
        overwriteExisting: overwriteExisting,
      ),
    );
    return repo_ffi_mutate.decodeMutationResultEnvelopeInternal(bytes);
  }

  /// Start tracking the working-copy paths matching [paths], in the repo
  /// identified by [handleId] (Story 9.22) — the CLI's `jj file track`.
  ///
  /// [paths] are repo-relative PREFIXES; [includeIgnored] is the CLI's
  /// `--include-ignored`. An operation (`track paths`) is ALWAYS written; `@` is
  /// unchanged until the next snapshot (jj's GH #8298).
  ///
  /// Sends a [FileTrackCommand] via [send] and decodes the returned FlatBuffers
  /// `Envelope<TrackResult>` bytes.
  ///
  /// Throws [ArgumentError] if any path contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.concurrent_working_copy`). Completes with a
  /// [StateError] after [close]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.fileTrack].
  Future<repo_ffi_file_ops.TrackResult> fileTrack(
    int handleId,
    List<String> paths, {
    bool includeIgnored = false,
  }) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(paths, 'paths');
    final Uint8List bytes = await send(
      FileTrackCommand(
        commandId: _correlator.allocateId(),
        handleId: handleId,
        paths: paths,
        includeIgnored: includeIgnored,
      ),
    );
    return repo_ffi_file_ops.decodeTrackResultEnvelopeInternal(bytes);
  }

  /// Stop tracking the working-copy paths matching [paths], in the repo
  /// identified by [handleId] (Story 9.22) — the CLI's `jj file untrack`.
  ///
  /// Every matched path must already be ignored; otherwise the call refuses with
  /// `jj.path_not_ignored` (every offender in the exception's context, one per
  /// line) and writes nothing.
  ///
  /// Sends a [FileUntrackCommand] via [send] and decodes the returned
  /// FlatBuffers `Envelope<UntrackResult>` bytes.
  ///
  /// Throws [ArgumentError] if any path contains an interior NUL (U+0000).
  /// Throws [ZanshinFfiException] on FFI errors. Completes with a [StateError]
  /// after [close]; the close-guard [StateError] is delivered synchronously by
  /// [RepoHandle.fileUntrack].
  Future<repo_ffi_file_ops.UntrackResult> fileUntrack(int handleId, List<String> paths) async {
    // See [bookmarkCreate] for why this guard is on the calling side.
    rejectInteriorNuls(paths, 'paths');
    final Uint8List bytes = await send(
      FileUntrackCommand(commandId: _correlator.allocateId(), handleId: handleId, paths: paths),
    );
    return repo_ffi_file_ops.decodeUntrackResultEnvelopeInternal(bytes);
  }

  /// Snapshot the working copy of the repo identified by [handleId] right now —
  /// and, in a colocated workspace, import the Git HEAD and refs (Story 9.26) —
  /// the CLI's `jj util snapshot`.
  ///
  /// It is exactly the pre-verb snapshot every other handle-scoped verb runs
  /// first, with nothing after it. A clean tree with unchanged refs writes no
  /// operation and reports `wasSnapshotTaken == false`.
  ///
  /// Sends a [SnapshotCommand] via [send] and decodes the report from the
  /// returned envelope's `precondition`, carrying the envelope's warnings.
  ///
  /// Throws [ZanshinFfiException] on FFI errors (e.g. `ffi.invalid_handle`,
  /// `jj.stale_working_copy`, `jj.config_error`, `jj.jj_lib_error`). Completes
  /// with a [StateError] after [close]; the close-guard [StateError] is delivered
  /// synchronously by [RepoHandle.snapshot].
  Future<repo_ffi_precondition.Precondition> snapshot(int handleId) async {
    final Uint8List bytes = await send(SnapshotCommand(commandId: _correlator.allocateId(), handleId: handleId));
    return repo_ffi_precondition.decodeSnapshotEnvelopeInternal(bytes);
  }

  // ── The config surface (Story 9.28) ────────────────────────────────────────
  //
  // Handle-free, like [detect]: [workspaceRoot] is the CLI's `-R` (`null` = no
  // workspace), so a config that makes [openRepo] fail can still be listed and
  // repaired through these. Every method throws [ArgumentError] for a string
  // argument with an interior NUL (U+0000) and [ZanshinFfiException] for an FFI
  // error (`jj.config_*`, `jj.path_not_found`, `jj.repo_not_found`, …; see
  // `docs/ffi-abi.md`). A [workspaceRoot] makes every one of them but the `gc`
  // pair run the jj CLI's start-up secure-config fix-up first (Story 9.37): it
  // may migrate a legacy config, fork a copied repo's or regenerate a missing
  // secure directory on disk, and reports `jj.config_migrated` /
  // `jj.config_copied` / `jj.config_regenerated` as the call's first warnings,
  // ok or error.

  /// `jj config list [NAME] [--user|--repo|--workspace] [--include-defaults]
  /// [--include-overridden]` — every value of the effective stack with its
  /// source, lowest layer first. A [scope] together with [includeDefaults] is
  /// refused (`jj.invalid_input`).
  Future<WarnedList<repo_ffi_config.ConfigEntry>> configList({
    String? workspaceRoot,
    String? name,
    repo_ffi_config.ConfigScope? scope,
    bool includeDefaults = false,
    bool includeOverridden = false,
  }) async {
    rejectInteriorNul(workspaceRoot, 'workspaceRoot');
    rejectInteriorNul(name, 'name');
    final Uint8List bytes = await send(
      ConfigListCommand(
        commandId: _correlator.allocateId(),
        workspaceRoot: workspaceRoot,
        name: name,
        scope: scope,
        includeDefaults: includeDefaults,
        includeOverridden: includeOverridden,
      ),
    );
    return repo_ffi_config.decodeConfigListEnvelopeInternal(bytes);
  }

  /// `jj config get NAME` — a string unquoted, anything else as TOML text
  /// (with the call's warnings).
  Future<repo_ffi_config.ConfigGetResult> configGet(String name, {String? workspaceRoot}) async {
    rejectInteriorNul(workspaceRoot, 'workspaceRoot');
    rejectInteriorNul(name, 'name');
    final Uint8List bytes = await send(
      ConfigGetCommand(commandId: _correlator.allocateId(), workspaceRoot: workspaceRoot, name: name),
    );
    return repo_ffi_config.decodeConfigGetEnvelopeInternal(bytes);
  }

  /// `jj config path --user|--repo|--workspace`. Repo / workspace scope CREATES
  /// the secure config directory and id file when missing (the CLI's side effect).
  Future<WarnedList<String>> configPath(repo_ffi_config.ConfigScope scope, {String? workspaceRoot}) async {
    rejectInteriorNul(workspaceRoot, 'workspaceRoot');
    final Uint8List bytes = await send(
      ConfigPathCommand(commandId: _correlator.allocateId(), workspaceRoot: workspaceRoot, scope: scope),
    );
    return repo_ffi_config.decodeConfigPathEnvelopeInternal(bytes);
  }

  /// `jj config set --<scope>|--file PATH NAME VALUE`. [value] is TOML text (a
  /// bare string when it does not look like TOML). [target] picks the file as
  /// the CLI does since jj 0.45: a scope's FIRST file, or one named file, which
  /// must be a location jj recognizes (else `jj.config_unrecognized_file`). The
  /// config write itself writes no operation; only the `user.name`/`user.email`
  /// check's snapshot may (a dirty `@`), exactly as the CLI's `check_wc_author`.
  Future<repo_ffi_config.ConfigSetResult> configSet(
    repo_ffi_config.ConfigTarget target,
    String name,
    String value, {
    String? workspaceRoot,
  }) async {
    rejectInteriorNuls([name, value], 'name/value');
    rejectInteriorNul(workspaceRoot, 'workspaceRoot');
    _rejectTargetNul(target);
    final Uint8List bytes = await send(
      ConfigSetCommand(
        commandId: _correlator.allocateId(),
        workspaceRoot: workspaceRoot,
        target: target,
        name: name,
        value: value,
      ),
    );
    return repo_ffi_config.decodeConfigSetEnvelopeInternal(bytes);
  }

  /// `jj config unset --<scope>|--file PATH NAME`, [target] as in [configSet];
  /// returns the file written (and the call's warnings).
  Future<repo_ffi_config.ConfigUnsetResult> configUnset(
    repo_ffi_config.ConfigTarget target,
    String name, {
    String? workspaceRoot,
  }) async {
    rejectInteriorNul(name, 'name');
    rejectInteriorNul(workspaceRoot, 'workspaceRoot');
    _rejectTargetNul(target);
    final Uint8List bytes = await send(
      ConfigUnsetCommand(
        commandId: _correlator.allocateId(),
        workspaceRoot: workspaceRoot,
        target: target,
        name: name,
      ),
    );
    return repo_ffi_config.decodeConfigUnsetEnvelopeInternal(bytes);
  }

  /// `jj config edit`, editor half 1: the file [target] picks (as in
  /// [configSet]) and its exact text, creating an absent file first (as the CLI
  /// does before starting the editor).
  Future<repo_ffi_config.ConfigFileText> configFileRead(
    repo_ffi_config.ConfigTarget target, {
    String? workspaceRoot,
  }) async {
    rejectInteriorNul(workspaceRoot, 'workspaceRoot');
    _rejectTargetNul(target);
    final Uint8List bytes = await send(
      ConfigFileReadCommand(
        commandId: _correlator.allocateId(),
        workspaceRoot: workspaceRoot,
        target: target,
      ),
    );
    return repo_ffi_config.decodeConfigFileTextEnvelopeInternal(bytes);
  }

  /// The calling-side NUL guard for a [repo_ffi_config.ConfigFileTarget]'s path.
  static void _rejectTargetNul(repo_ffi_config.ConfigTarget target) {
    if (target case repo_ffi_config.ConfigFileTarget(:final path)) {
      rejectInteriorNul(path, 'path');
    }
  }

  /// `jj config edit`, editor half 2: replaces the file's text — refused with
  /// `jj.config_parse_error` (nothing written) unless [text] is valid TOML.
  Future<repo_ffi_config.ConfigFileWriteResult> configFileWrite(
    String path,
    String text, {
    String? workspaceRoot,
  }) async {
    rejectInteriorNuls([path, text], 'path/text');
    rejectInteriorNul(workspaceRoot, 'workspaceRoot');
    final Uint8List bytes = await send(
      ConfigFileWriteCommand(commandId: _correlator.allocateId(), workspaceRoot: workspaceRoot, path: path, text: text),
    );
    return repo_ffi_config.decodeConfigFileWriteEnvelopeInternal(bytes);
  }

  /// `jj config gc`, half 1: the repo config directories whose repo is gone.
  Future<WarnedList<repo_ffi_config.MissingRepoConfig>> configGcList() async {
    final Uint8List bytes = await send(ConfigGcListCommand(commandId: _correlator.allocateId()));
    return repo_ffi_config.decodeConfigGcListEnvelopeInternal(bytes);
  }

  /// `jj config gc`, half 2: deletes those of [configDirs] that are still missing
  /// repo config directories; everything else rides `failed`.
  Future<repo_ffi_config.ConfigGcResult> configGcDelete(List<String> configDirs) async {
    rejectInteriorNuls(configDirs, 'configDirs');
    final Uint8List bytes = await send(
      ConfigGcDeleteCommand(commandId: _correlator.allocateId(), configDirs: configDirs),
    );
    return repo_ffi_config.decodeConfigGcResultEnvelopeInternal(bytes);
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

  // Story 9.52: network calls run on helper isolates; the scheduler keeps every
  // call on one handle serialized while this event loop keeps serving the rest.
  late final _NetworkScheduler scheduler;

  void dispatch(WorkerCommand msg) {
    final int commandId = msg.commandId;

    try {
      switch (msg) {
        case OpenRepoCommand(:final String path):
          final Uint8List bytes = repo_ffi.zanshinRepoOpen(path);
          _replyRepoOp(bytes, commandId, handles, sessionToId, responseSP, log, () => nextHandleId++);

        case InitRepoCommand(
          :final String path,
          :final int backend,
          :final bool colocate,
          :final bool noColocate,
          :final repo_ffi.ObjectHash? objectHash,
        ):
          final Uint8List bytes = repo_ffi.zanshinRepoInit(
            path,
            backend: backend,
            colocate: colocate,
            noColocate: noColocate,
            objectHash: objectHash,
          );
          _replyRepoOp(bytes, commandId, handles, sessionToId, responseSP, log, () => nextHandleId++);

        case final CloneRepoCommand clone:
          // The handle id is reserved and the clone's session id (its token)
          // mapped BEFORE the helper runs, so its progress reaches main live.
          final int reserved = nextHandleId++;
          scheduler.run(
            commandId: commandId,
            handleId: null,
            call: (token) {
              sessionToId[token] = reserved;
              eventSP.send(_NetworkHandleAnnouncement(commandId, reserved));
              return _cloneOnHelper(clone, token);
            },
            reply: (bytes, token) {
              final env = fbs.Envelope(bytes);
              if (env.ok && env.dataType == fbs.PayloadTypeId.RepoHandle) {
                final rh = env.data as fbs.RepoHandle;
                handles[reserved] = rh.handle;
                sessionToId[rh.sessionId] = reserved;
                log.fine('Worker: repo cloned session=${rh.sessionId} → handleId=$reserved');
                responseSP.send((commandId, HandleResult(reserved, bytes)));
              } else {
                sessionToId.remove(token);
                responseSP.send((commandId, BufferResult(bytes)));
              }
            },
            fail: (e, token) {
              sessionToId.remove(token);
              log.warning('Worker: clone helper failed for command $commandId: $e');
              responseSP.send((commandId, BufferResult(_dispatchErrorEnvelope(e))));
            },
          );

        case CloseRepoCommand(:final int handleId):
          final int? raw = handles.remove(handleId);
          sessionToId.removeWhere((_, id) => id == handleId);
          if (raw == null) {
            log.warning('Worker: CloseRepoCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
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
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_status.zanshinStatus(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GetChangeCommand(:final int handleId, :final String changeId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GetChangeCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_change.zanshinChange(raw, changeId);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GraphTopologyCommand(
          :final int handleId,
          :final String revset,
          :final String prioritize,
          :final String shortPrefixes,
          :final List<String> anchors,
          :final bool withTimestamps,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GraphTopologyCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final FfiBuffer buf = repo_ffi_graph.zanshinGraphTopology(
              raw,
              revset: revset,
              prioritize: prioritize,
              shortPrefixes: shortPrefixes,
              anchors: anchors,
              withTimestamps: withTimestamps,
            );
            // The ONE copy across the isolate boundary (Story 4.12): out of the native
            // buffer straight into the transferable, then the native buffer is freed.
            final TransferableTypedData data;
            try {
              data = TransferableTypedData.fromList([buf.bytes]);
            } finally {
              buf.dispose();
            }
            responseSP.send((commandId, TransferResult(data)));
          }

        case GraphLayoutCommand(
          :final int handleId,
          :final String revset,
          :final String prioritize,
          :final String shortPrefixes,
          :final List<String> anchors,
          :final LayoutMode mode,
          :final LaneOrder order,
          :final int utcOffsetMin,
          :final int budget,
          :final bool stacks,
          :final List<String> expandedKeys,
          :final List<String> collapsedKeys,
          :final List<String> keepOpenKeys,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GraphLayoutCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final FfiBuffer buf = repo_ffi_graph.zanshinGraphTopology(
              raw,
              revset: revset,
              prioritize: prioritize,
              shortPrefixes: shortPrefixes,
              anchors: anchors,
              withTimestamps: mode == LayoutMode.free,
            );
            final TransferableTypedData topology;
            final ({Uint8List? grid, LayoutContractException? violation}) layout;
            try {
              // The ONE copy of the topology across the isolate boundary (Story 4.12's rule), and
              // the layout over the same native bytes — before the native buffer is freed.
              topology = TransferableTypedData.fromList([buf.bytes]);
              layout = layOutTopology(
                buf.bytes,
                mode: mode,
                order: order,
                utcOffsetMin: utcOffsetMin,
                budget: budget,
                stacks: stacks,
                expandedKeys: expandedKeys,
                collapsedKeys: collapsedKeys,
                keepOpenKeys: keepOpenKeys,
              );
            } finally {
              buf.dispose();
            }
            final Uint8List? grid = layout.grid;
            responseSP.send((
              commandId,
              GraphLayoutResult(
                topology: topology,
                grid: grid == null ? null : TransferableTypedData.fromList([grid]),
                violation: layout.violation,
              ),
            ));
          }

        case OpLogCommand(:final int handleId, :final int limit):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: OpLogCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_op_log.zanshinOpLog(raw, limit);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case BookmarksCommand(
          :final int handleId,
          :final List<String> names,
          :final List<String> revisions,
          :final List<String> remotes,
          :final bool allRemotes,
          :final bool tracked,
          :final bool conflicted,
          :final List<repo_ffi_bookmarks.BookmarkSortKey> sort,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: BookmarksCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_bookmarks.zanshinBookmarks(
              raw,
              names: names,
              revisions: revisions,
              remotes: remotes,
              allRemotes: allRemotes,
              tracked: tracked,
              conflicted: conflicted,
              sort: sort,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case RemotesCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: RemotesCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_remotes.zanshinRemotes(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GitPushRemotesCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitPushRemotesCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_remotes.zanshinGitPushRemotes(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GitFetchRemotesCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitFetchRemotesCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_remotes.zanshinGitFetchRemotes(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case LogDefaultsCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: LogDefaultsCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_log_defaults.zanshinLogDefaults(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case DetectRepoCommand(:final String path):
          final Uint8List bytes = repo_ffi.zanshinRepoDetect(path);
          responseSP.send((commandId, BufferResult(bytes)));

        case ConvertRepoCommand(:final String path):
          final Uint8List bytes = repo_ffi.zanshinRepoConvert(path);
          _replyRepoOp(bytes, commandId, handles, sessionToId, responseSP, log, () => nextHandleId++);

        case DescribeCommand(:final int handleId, :final String changeId, :final String description):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: DescribeCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_mutate.zanshinDescribe(raw, changeId, description);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case NewChangeCommand(
          :final int handleId,
          :final List<String> parents,
          :final List<String> insertAfter,
          :final List<String> insertBefore,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: NewChangeCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_mutate.zanshinNewChange(
              raw,
              parents,
              insertAfter: insertAfter,
              insertBefore: insertBefore,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case EditCommand(:final int handleId, :final String changeId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: EditCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_mutate.zanshinEdit(raw, changeId);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case AbandonCommand(:final int handleId, :final List<String> changeIds):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: AbandonCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_mutate.zanshinAbandon(raw, changeIds);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case UndoCommand(:final int handleId, :final bool allowCrossWorkspace):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: UndoCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_mutate.zanshinUndo(
              raw,
              allowCrossWorkspace: allowCrossWorkspace,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case final GitFetchCommand fetch:
          final int handleId = fetch.handleId;
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitFetchCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            scheduler.run(
              commandId: commandId,
              handleId: handleId,
              call: (token) {
                eventSP.send(_NetworkHandleAnnouncement(commandId, handleId));
                return _fetchOnHelper(raw, fetch, token);
              },
              reply: (bytes, _) => responseSP.send((commandId, BufferResult(bytes))),
              fail: (e, _) {
                log.warning('Worker: fetch helper failed for command $commandId: $e');
                responseSP.send((commandId, BufferResult(_dispatchErrorEnvelope(e))));
              },
            );
          }

        case GitRemoteChangesCommand(:final int handleId, :final String remoteName):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitRemoteChangesCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            scheduler.run(
              commandId: commandId,
              handleId: handleId,
              call: (token) {
                eventSP.send(_NetworkHandleAnnouncement(commandId, handleId));
                return _remoteChangesOnHelper(raw, remoteName, token);
              },
              reply: (bytes, _) => responseSP.send((commandId, BufferResult(bytes))),
              fail: (e, _) {
                log.warning('Worker: remote-changes helper failed for command $commandId: $e');
                responseSP.send((commandId, BufferResult(_dispatchErrorEnvelope(e))));
              },
            );
          }

        case final GitPushCommand push:
          final int handleId = push.handleId;
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitPushCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            scheduler.run(
              commandId: commandId,
              handleId: handleId,
              call: (token) {
                eventSP.send(_NetworkHandleAnnouncement(commandId, handleId));
                return _pushOnHelper(raw, push, token);
              },
              reply: (bytes, _) => responseSP.send((commandId, BufferResult(bytes))),
              fail: (e, _) {
                log.warning('Worker: push helper failed for command $commandId: $e');
                responseSP.send((commandId, BufferResult(_dispatchErrorEnvelope(e))));
              },
            );
          }

        case RestoreCommand(
          :final int handleId,
          :final String? from,
          :final String? into,
          :final String? changesIn,
          :final List<String> paths,
          :final bool restoreDescendants,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: RestoreCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_mutate.zanshinRestore(
              raw,
              from: from,
              into: into,
              changesIn: changesIn,
              paths: paths,
              restoreDescendants: restoreDescendants,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case AbsorbCommand(
          :final int handleId,
          :final String? from,
          :final String? into,
          :final List<String> paths,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: AbsorbCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_mutate.zanshinAbsorb(raw, from: from, into: into, paths: paths);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case RebaseCommand(
          :final int handleId,
          :final List<String> branch,
          :final List<String> source,
          :final List<String> revisions,
          :final List<String> onto,
          :final List<String> insertAfter,
          :final List<String> insertBefore,
          :final bool skipEmptied,
          :final bool keepDivergent,
          :final bool simplifyParents,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: RebaseCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_rebase.zanshinRebase(
              raw,
              branch: branch,
              source: source,
              revisions: revisions,
              onto: onto,
              insertAfter: insertAfter,
              insertBefore: insertBefore,
              skipEmptied: skipEmptied,
              keepDivergent: keepDivergent,
              simplifyParents: simplifyParents,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case ParallelizeCommand(:final int handleId, :final List<String> changeIds):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: ParallelizeCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_rebase.zanshinParallelize(raw, changeIds);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case ArrangeCommand(
          :final int handleId,
          :final List<String> revisions,
          :final List<repo_ffi_rebase.ArrangeAction> actions,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: ArrangeCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_rebase.zanshinArrange(raw, revisions: revisions, actions: actions);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case MetaeditCommand(
          :final int handleId,
          :final List<String> revisions,
          :final bool updateChangeId,
          :final List<String>? message,
          :final bool updateAuthorTimestamp,
          :final bool updateAuthor,
          :final String? author,
          :final String? authorTimestamp,
          :final bool forceRewrite,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: MetaeditCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_metaedit_duplicate_fix.zanshinMetaedit(
              raw,
              revisions: revisions,
              updateChangeId: updateChangeId,
              message: message,
              updateAuthorTimestamp: updateAuthorTimestamp,
              updateAuthor: updateAuthor,
              author: author,
              authorTimestamp: authorTimestamp,
              forceRewrite: forceRewrite,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case DuplicateCommand(
          :final int handleId,
          :final List<String> revisions,
          :final List<String> onto,
          :final List<String> insertAfter,
          :final List<String> insertBefore,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: DuplicateCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_metaedit_duplicate_fix.zanshinDuplicate(
              raw,
              revisions: revisions,
              onto: onto,
              insertAfter: insertAfter,
              insertBefore: insertBefore,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case FixCommand(
          :final int handleId,
          :final List<String> source,
          :final List<String> paths,
          :final bool includeUnchangedFiles,
          :final bool allLines,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: FixCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_metaedit_duplicate_fix.zanshinFix(
              raw,
              source: source,
              paths: paths,
              includeUnchangedFiles: includeUnchangedFiles,
              allLines: allLines,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case SquashCommand(
          :final int handleId,
          :final String? revision,
          :final List<String> from,
          :final String? into,
          :final List<String> paths,
          :final List<String>? message,
          :final bool useDestinationMessage,
          :final bool keepEmptied,
          :final String? editedDescription,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: SquashCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_squash_split.zanshinSquash(
              raw,
              revision: revision,
              from: from,
              into: into,
              paths: paths,
              message: message,
              useDestinationMessage: useDestinationMessage,
              keepEmptied: keepEmptied,
              editedDescription: editedDescription,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case SquashPlanCommand(
          :final int handleId,
          :final String? revision,
          :final List<String> from,
          :final String? into,
          :final List<String> paths,
          :final List<String>? message,
          :final bool useDestinationMessage,
          :final bool keepEmptied,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: SquashPlanCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_squash_split.zanshinSquashPlan(
              raw,
              revision: revision,
              from: from,
              into: into,
              paths: paths,
              message: message,
              useDestinationMessage: useDestinationMessage,
              keepEmptied: keepEmptied,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case DropActionsCommand(
          :final int handleId,
          :final repo_ffi_drop_actions.DropSource source,
          :final List<repo_ffi_drop_actions.DropLocation> locations,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: DropActionsCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_drop_actions.zanshinDropActions(raw, source, locations);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case ChangeActionsCommand(:final int handleId, :final String changeId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: ChangeActionsCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_drop_actions.zanshinChangeActions(raw, changeId);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case SplitCommand(
          :final int handleId,
          :final String? revision,
          :final List<String> paths,
          :final List<String>? message,
          :final bool parallel,
          :final List<String>? onto,
          :final List<String>? insertAfter,
          :final List<String>? insertBefore,
          :final String? editedSelectedDescription,
          :final String? editedRemainingDescription,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: SplitCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_squash_split.zanshinSplit(
              raw,
              revision: revision,
              paths: paths,
              message: message,
              parallel: parallel,
              onto: onto,
              insertAfter: insertAfter,
              insertBefore: insertBefore,
              editedSelectedDescription: editedSelectedDescription,
              editedRemainingDescription: editedRemainingDescription,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case CommitCommand(:final int handleId, :final List<String> paths, :final List<String> message):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: CommitCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_commit.zanshinCommit(raw, message: message, paths: paths);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case FileListCommand(
          :final int handleId,
          :final String? revision,
          :final List<String> paths,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: FileListCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_file.zanshinFileList(raw, revision: revision, paths: paths);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case FileShowCommand(
          :final int handleId,
          :final String? revision,
          :final List<String> paths,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: FileShowCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_file.zanshinFileShow(raw, revision: revision, paths: paths);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case FileAnnotateCommand(
          :final int handleId,
          :final String? revision,
          :final String path,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: FileAnnotateCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_file.zanshinFileAnnotate(raw, path: path, revision: revision);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case FileSearchCommand(
          :final int handleId,
          :final String? revision,
          :final String pattern,
          :final List<String> paths,
          :final bool nameOnly,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: FileSearchCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_file.zanshinFileSearch(
              raw,
              pattern: pattern,
              revision: revision,
              paths: paths,
              nameOnly: nameOnly,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GitImportCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitImportCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_git.zanshinGitImport(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GitExportCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitExportCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_git.zanshinGitExport(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GitRemoteAddCommand(
          :final int handleId,
          :final String name,
          :final String url,
          :final String? pushUrl,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitRemoteAddCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_git.zanshinGitRemoteAdd(raw, name: name, url: url, pushUrl: pushUrl);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GitRemoteRemoveCommand(:final int handleId, :final String name):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitRemoteRemoveCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_git.zanshinGitRemoteRemove(raw, name);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GitRemoteRenameCommand(:final int handleId, :final String oldName, :final String newName):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitRemoteRenameCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_git.zanshinGitRemoteRename(raw, oldName, newName);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case GitRemoteSetUrlCommand(
          :final int handleId,
          :final String name,
          :final String? url,
          :final String? pushUrl,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: GitRemoteSetUrlCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_git.zanshinGitRemoteSetUrl(raw, name: name, url: url, pushUrl: pushUrl);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case ShowCommand(:final int handleId, :final String? revset, :final int? limit):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: ShowCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_commit_views.zanshinShow(raw, revset: revset, limit: limit);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case EvologCommand(:final int handleId, :final String? revset, :final int? limit):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: EvologCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_commit_views.zanshinEvolog(raw, revset: revset, limit: limit);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case InterdiffCommand(
          :final int handleId,
          :final repo_ffi_commit_views.RevisionRef? from,
          :final repo_ffi_commit_views.RevisionRef? to,
          :final List<String> paths,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: InterdiffCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_commit_views.zanshinInterdiff(raw, from: from, to: to, paths: paths);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case WorkspaceListCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: WorkspaceListCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_workspace.zanshinWorkspaceList(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case WorkspaceRootCommand(:final int handleId, :final String? name):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: WorkspaceRootCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_workspace.zanshinWorkspaceRoot(raw, name: name);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case WorkspaceAddCommand(
          :final int handleId,
          :final String destination,
          :final String? name,
          :final List<String> revisions,
          :final List<String> messageParagraphs,
          :final bool? colocate,
          :final repo_ffi_workspace.SparseInheritance sparse,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: WorkspaceAddCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_workspace.zanshinWorkspaceAdd(
              raw,
              destination: destination,
              name: name,
              revisions: revisions,
              messageParagraphs: messageParagraphs,
              colocate: colocate,
              sparse: sparse,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case WorkspaceUpdateStaleCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: WorkspaceUpdateStaleCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_workspace.zanshinWorkspaceUpdateStale(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case CommitContentsCommand(
          :final int handleId,
          :final String operationId,
          :final List<String> commitIds,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: CommitContentsCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_commit_contents.zanshinCommitContents(
              raw,
              operationId: operationId,
              commitIds: commitIds,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case BookmarkCreateCommand(:final int handleId, :final List<String> names, :final String? revision):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: BookmarkCreateCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_bookmark_ops.zanshinBookmarkCreate(raw, names, revision: revision);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case BookmarkDeleteCommand(:final int handleId, :final List<String> names):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: BookmarkDeleteCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_bookmark_ops.zanshinBookmarkDelete(raw, names);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case BookmarkMoveCommand(
          :final int handleId,
          :final List<String> names,
          :final List<String> from,
          :final String? to,
          :final bool allowBackwards,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: BookmarkMoveCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_bookmark_ops.zanshinBookmarkMove(
              raw,
              names,
              from: from,
              to: to,
              allowBackwards: allowBackwards,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case BookmarkAdvanceCommand(:final int handleId, :final List<String> names, :final String? to):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: BookmarkAdvanceCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_bookmark_ops.zanshinBookmarkAdvance(raw, names: names, to: to);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case BookmarkRenameCommand(
          :final int handleId,
          :final String oldName,
          :final String newName,
          :final bool overwriteExisting,
        ):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: BookmarkRenameCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_bookmark_ops.zanshinBookmarkRename(
              raw,
              oldName,
              newName,
              overwriteExisting: overwriteExisting,
            );
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case FileTrackCommand(:final int handleId, :final List<String> paths, :final bool includeIgnored):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: FileTrackCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_file_ops.zanshinFileTrack(raw, paths, includeIgnored: includeIgnored);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case FileUntrackCommand(:final int handleId, :final List<String> paths):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: FileUntrackCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_file_ops.zanshinFileUntrack(raw, paths);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case SnapshotCommand(:final int handleId):
          final int? raw = handles[handleId]; // lookup — never remove
          if (raw == null) {
            log.warning('Worker: SnapshotCommand for unknown handleId $handleId');
            final Uint8List errorBytes = _invalidHandleEnvelope(handleId);
            responseSP.send((commandId, BufferResult(errorBytes)));
          } else {
            final Uint8List bytes = repo_ffi_precondition.zanshinSnapshot(raw);
            responseSP.send((commandId, BufferResult(bytes)));
          }

        case ConfigListCommand(
          :final String? workspaceRoot,
          :final String? name,
          :final repo_ffi_config.ConfigScope? scope,
          :final bool includeDefaults,
          :final bool includeOverridden,
        ):
          final Uint8List bytes = repo_ffi_config.zanshinConfigList(
            workspaceRoot: workspaceRoot,
            name: name,
            scope: scope,
            includeDefaults: includeDefaults,
            includeOverridden: includeOverridden,
          );
          responseSP.send((commandId, BufferResult(bytes)));

        case ConfigGetCommand(:final String? workspaceRoot, :final String name):
          final Uint8List bytes = repo_ffi_config.zanshinConfigGet(name, workspaceRoot: workspaceRoot);
          responseSP.send((commandId, BufferResult(bytes)));

        case ConfigPathCommand(:final String? workspaceRoot, :final repo_ffi_config.ConfigScope scope):
          final Uint8List bytes = repo_ffi_config.zanshinConfigPath(scope, workspaceRoot: workspaceRoot);
          responseSP.send((commandId, BufferResult(bytes)));

        case ConfigSetCommand(
          :final String? workspaceRoot,
          :final repo_ffi_config.ConfigTarget target,
          :final String name,
          :final String value,
        ):
          final Uint8List bytes = repo_ffi_config.zanshinConfigSet(
            target,
            name,
            value,
            workspaceRoot: workspaceRoot,
          );
          responseSP.send((commandId, BufferResult(bytes)));

        case ConfigUnsetCommand(
          :final String? workspaceRoot,
          :final repo_ffi_config.ConfigTarget target,
          :final String name,
        ):
          final Uint8List bytes = repo_ffi_config.zanshinConfigUnset(target, name, workspaceRoot: workspaceRoot);
          responseSP.send((commandId, BufferResult(bytes)));

        case ConfigFileReadCommand(:final String? workspaceRoot, :final repo_ffi_config.ConfigTarget target):
          final Uint8List bytes = repo_ffi_config.zanshinConfigFileRead(target, workspaceRoot: workspaceRoot);
          responseSP.send((commandId, BufferResult(bytes)));

        case ConfigFileWriteCommand(:final String? workspaceRoot, :final String path, :final String text):
          final Uint8List bytes = repo_ffi_config.zanshinConfigFileWrite(path, text, workspaceRoot: workspaceRoot);
          responseSP.send((commandId, BufferResult(bytes)));

        case ConfigGcListCommand():
          final Uint8List bytes = repo_ffi_config.zanshinConfigGcList();
          responseSP.send((commandId, BufferResult(bytes)));

        case ConfigGcDeleteCommand(:final List<String> configDirs):
          final Uint8List bytes = repo_ffi_config.zanshinConfigGcDelete(configDirs);
          responseSP.send((commandId, BufferResult(bytes)));

        case NetworkCancelCommand(:final int targetCommandId):
          scheduler.cancel(targetCommandId);
          responseSP.send((commandId, BufferResult(fbs.EnvelopeObjectBuilder(ok: true).toBytes())));

        case ShutdownCommand():
          // Story 9.52: every network call is cancelled first, and the repos
          // are closed only once no helper isolate still uses a session.
          scheduler.shutDown(() {
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
          });
      }
    } catch (e, st) {
      log.warning('Worker: dispatch error for command $commandId: $e\n$st');
      responseSP.send((commandId, BufferResult(_dispatchErrorEnvelope(e))));
    }
  }

  scheduler = _NetworkScheduler(dispatch, (commandId, e) {
    log.warning('Worker: answering network command $commandId failed: $e');
    responseSP.send((commandId, BufferResult(_dispatchErrorEnvelope(e))));
  });
  commandPort.listen((msg) {
    if (msg is! WorkerCommand) {
      log.warning('Worker: received unexpected message type');
      return;
    }
    scheduler.accept(msg);
  });
}

/// The `internal.dispatch_error` envelope the worker answers a command with
/// when its arm threw — on this isolate or on a network call's helper isolate.
Uint8List _dispatchErrorEnvelope(Object e) => fbs.EnvelopeObjectBuilder(
  ok: false,
  error: fbs.FfiErrorObjectBuilder(code: 'internal.dispatch_error', context: '$e'),
).toBytes();

/// Sent on the event port when a network call actually starts (Story 9.52): the
/// handle id of command [commandId] — for a clone the one the worker reserved —
/// so main forwards the call's progress, and only from then on (a call queued
/// behind another on its handle must not take that call's events). Not a
/// [RepoEvent] — main consumes it.
final class _NetworkHandleAnnouncement {
  const _NetworkHandleAnnouncement(this.commandId, this.handleId);

  final int commandId;
  final int handleId;
}

/// The worker's serialization of network calls (Story 9.52).
///
/// A network call — fetch, push, clone, remote-change poll — runs on a
/// short-lived helper isolate ([Isolate.run]) so the worker's event loop keeps
/// forwarding progress and serving other repos. While a fetch, poll or push
/// holds handle H, every
/// [HandleScopedCommand] for H — [CloseRepoCommand] included — waits in
/// arrival order and runs after it, so the helper is the only isolate that
/// touches H's raw session (AD-2: Rust adds no handle locking). Calls on other
/// handles, handle-free commands and events do not wait.
///
/// Each call carries a cancel token (`zanshin_network_token`, allocated when
/// the call starts) that [cancel] cancels; a cancel of a queued call is
/// remembered, so the call starts with a cancelled token. [shutDown] cancels
/// every token and runs the shutdown once no call is in flight.
final class _NetworkScheduler {
  _NetworkScheduler(this._dispatch, this._answerError);

  final void Function(WorkerCommand command) _dispatch;
  final void Function(int commandId, Object error) _answerError;
  final Set<int> _busy = {};
  final Map<int, Queue<WorkerCommand>> _waiting = {};
  final Map<int, int> _tokens = {};
  final Set<int> _cancelledWhileQueued = {};
  var _inFlight = 0;
  var _shuttingDown = false;
  void Function()? _whenIdle;

  /// Runs [command] now, or queues it behind its handle's network call.
  void accept(WorkerCommand command) {
    if (command case HandleScopedCommand(:final int handleId) when _busy.contains(handleId)) {
      _waiting.putIfAbsent(handleId, Queue.new).add(command);
    } else {
      _dispatch(command);
    }
  }

  /// Starts the network call of [commandId]: allocates its token, holds
  /// [handleId] (if any) and runs [call] — which must hand the FFI call to a
  /// helper isolate — then hands its bytes to [reply], or its error to [fail],
  /// and releases the handle.
  void run({
    required int commandId,
    required int? handleId,
    required Future<Uint8List> Function(int token) call,
    required void Function(Uint8List bytes, int token) reply,
    required void Function(Object error, int token) fail,
  }) {
    final int token = repo_ffi.zanshinNetworkToken();
    _tokens[commandId] = token;
    if (_cancelledWhileQueued.remove(commandId) || _shuttingDown) {
      repo_ffi.zanshinNetworkCancel(token);
    }
    if (handleId != null) {
      _busy.add(handleId);
    }
    _inFlight++;
    Future<Uint8List> running;
    try {
      running = call(token);
    } catch (e) {
      running = Future.error(e);
    }
    // A throw while answering (a decode, say) still answers — `internal.dispatch_error` — and the
    // handle is released below either way.
    void answer(void Function() step) {
      try {
        step();
      } catch (e) {
        _answerError(commandId, e);
      }
    }

    running
        .then((bytes) => answer(() => reply(bytes, token)), onError: (Object e) => answer(() => fail(e, token)))
        .whenComplete(() {
          _tokens.remove(commandId);
          _inFlight--;
          if (handleId != null) {
            _busy.remove(handleId);
            _drain(handleId);
          }
          if (_inFlight == 0) {
            final void Function()? idle = _whenIdle;
            _whenIdle = null;
            idle?.call();
          }
        })
        .ignore();
  }

  void _drain(int handleId) {
    final Queue<WorkerCommand>? queue = _waiting[handleId];
    while (queue != null && queue.isNotEmpty && !_busy.contains(handleId)) {
      _dispatch(queue.removeFirst());
    }
    if (queue != null && queue.isEmpty) {
      _waiting.remove(handleId);
    }
  }

  /// Cancels the network call of [targetCommandId]: its token if it runs, else
  /// — when it waits in a queue — the token it will start with. Otherwise a
  /// no-op (finished, unknown, or not a network call).
  void cancel(int targetCommandId) {
    final int? token = _tokens[targetCommandId];
    if (token != null) {
      repo_ffi.zanshinNetworkCancel(token);
    } else if (_waiting.values.any(
      (queue) => queue.any(
        (command) =>
            command.commandId == targetCommandId &&
            (command is GitFetchCommand || command is GitRemoteChangesCommand || command is GitPushCommand),
      ),
    )) {
      _cancelledWhileQueued.add(targetCommandId);
    }
  }

  /// Cancels every network call — running or still to start — and runs
  /// [shutdown] once none is in flight, so no session is freed while a helper
  /// still uses it.
  void shutDown(void Function() shutdown) {
    _shuttingDown = true;
    _tokens.values.forEach(repo_ffi.zanshinNetworkCancel);
    if (_inFlight == 0) {
      shutdown();
    } else {
      _whenIdle = shutdown;
    }
  }
}

/// The helper-isolate half of a fetch (Story 9.52). Top-level, so the closure
/// [Isolate.run] sends captures nothing but its arguments.
Future<Uint8List> _fetchOnHelper(int raw, GitFetchCommand c, int token) => Isolate.run(
  () => repo_ffi_fetch.zanshinGitFetch(raw, remotes: c.remotes, refs: c.refs, cancelToken: token),
  debugName: 'ZanshinNetwork',
);

/// The helper-isolate half of a remote-change poll (Story 9.24); see
/// [_fetchOnHelper].
Future<Uint8List> _remoteChangesOnHelper(int raw, String remoteName, int token) => Isolate.run(
  () => repo_ffi_remotes.zanshinGitRemoteChanges(raw, remoteName, cancelToken: token),
  debugName: 'ZanshinNetwork',
);

/// The helper-isolate half of a push (Story 9.52); see [_fetchOnHelper].
Future<Uint8List> _pushOnHelper(int raw, GitPushCommand c, int token) => Isolate.run(
  () => repo_ffi_push.zanshinGitPush(
    raw,
    remotes: c.remotes,
    bookmarks: c.bookmarks,
    tags: c.tags,
    all: c.all,
    tracked: c.tracked,
    deleted: c.deleted,
    allowEmptyDescription: c.allowEmptyDescription,
    allowPrivate: c.allowPrivate,
    allowConflicts: c.allowConflicts,
    revisions: c.revisions,
    changes: c.changes,
    named: c.named,
    dryRun: c.dryRun,
    options: c.options,
    cancelToken: token,
  ),
  debugName: 'ZanshinNetwork',
);

/// The helper-isolate half of a clone (Story 9.52); see [_fetchOnHelper].
Future<Uint8List> _cloneOnHelper(CloneRepoCommand c, int token) => Isolate.run(
  () => repo_ffi.zanshinRepoClone(
    source: c.source,
    destination: c.destination,
    remoteName: c.remoteName,
    colocate: c.colocate,
    noColocate: c.noColocate,
    depth: c.depth,
    branches: c.branches,
    tags: c.tags,
    objectHash: c.objectHash,
    cancelToken: token,
  ),
  debugName: 'ZanshinNetwork',
);

/// The synthesized `ffi.invalid_handle` envelope every command arm replies with
/// when [handleId] names no live handle.
///
/// Rust never sees the call — the handle is gone on this side — so the worker
/// builds the refusal itself, in exactly the shape `envelope.rs` would have
/// produced, except that `context` names the Dart-side handle id the caller
/// actually passed. One definition rather than one per arm: 33 copies of a
/// literal error code and context string are 33 chances to desync.
Uint8List _invalidHandleEnvelope(int handleId) => fbs.EnvelopeObjectBuilder(
  ok: false,
  error: fbs.FfiErrorObjectBuilder(
    code: 'ffi.invalid_handle',
    context: 'unknown or closed handleId: $handleId',
  ),
).toBytes();

/// Handle open/init/clone/convert FFI bytes: store the raw handle plus the
/// session-id event-demux mapping and reply with [HandleResult] — carrying the ok
/// envelope, whose report main decodes (Story 9.33) — on success, or forward the
/// error envelope as [BufferResult].
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
    responseSP.send((commandId, HandleResult(id, bytes)));
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

ZanshinFfiException _envelopeToException(Uint8List bytes) =>
    repo_ffi_precondition.decodeEnvelopeErrorInternal(fbs.Envelope(bytes));
