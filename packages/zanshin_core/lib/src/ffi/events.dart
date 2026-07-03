// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

final _log = Logger('zanshin.ffi.events');

/// Worker-local decoding of an event `Envelope` — carries the **raw** repo
/// handle (the Rust `*mut RepoSession` value reinterpreted as `u64`), never
/// the small dense `handleId`. The worker demuxes raw → `handleId` before
/// constructing the public [RepoEvent][] sent to main (Model A holds — raw
/// handles never reach main).
///
/// [RepoEvent]: package:zanshin_core/src/worker/events.dart
sealed class ZanshinRawEvent {
  const ZanshinRawEvent(this.repoHandle);

  /// The raw `*mut RepoSession` value, as held by the worker's handle table.
  final int repoHandle;
}

/// One or more files changed under `.jj/repo/op_heads/heads/`.
final class RawOpHeadsChangedEvent extends ZanshinRawEvent {
  const RawOpHeadsChangedEvent(super.repoHandle, this.paths);

  /// Paths that changed.
  final List<String> paths;
}

/// The working-copy checkout file changed (heartbeat).
final class RawWorkingCopyHeartbeatEvent extends ZanshinRawEvent {
  const RawWorkingCopyHeartbeatEvent(super.repoHandle, this.paths);

  /// Paths that changed.
  final List<String> paths;
}

/// The filesystem-watch subsystem encountered an error (degraded watch, not a
/// failed call — see `docs/rust-error-codes.md`'s `watcher.io_error` note).
final class RawWatchErrorEvent extends ZanshinRawEvent {
  const RawWatchErrorEvent(super.repoHandle, this.message);

  /// Human-readable error description.
  final String message;
}

/// Progress notification for a long-running operation (FR-FFI-8).
final class RawProgressEvent extends ZanshinRawEvent {
  const RawProgressEvent(super.repoHandle, this.operation, this.progress, this.message);

  /// The operation name, e.g. `"fetch"`.
  final String operation;

  /// Fractional completion in `[0, 1]`.
  final double progress;

  /// Human-readable status message.
  final String message;
}

/// Decodes a raw `Envelope<WatcherEvent|Progress>` buffer into a [ZanshinRawEvent].
///
/// Event envelopes are always `ok == true` (a degraded watch is data, not a
/// failed call — R5); this only decodes the payload, matching the established
/// discriminant-guard idiom (`status.dart`/`repo_detect.dart`).
///
/// Throws [ZanshinFfiException] (`ffi.unknown`) for any other payload.
ZanshinRawEvent decodeEventEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  final Object? payload = env.data;
  if (payload is fbs.WatcherEvent) {
    return switch (payload.kind) {
      fbs.WatcherEventKind.OpHeadsChanged => RawOpHeadsChangedEvent(payload.repoHandle, payload.paths ?? const []),
      fbs.WatcherEventKind.WorkingCopyHeartbeat => RawWorkingCopyHeartbeatEvent(
        payload.repoHandle,
        payload.paths ?? const [],
      ),
      fbs.WatcherEventKind.WatchError => RawWatchErrorEvent(payload.repoHandle, payload.message ?? ''),
    };
  }
  if (payload is fbs.Progress) {
    return RawProgressEvent(payload.repoHandle, payload.operation ?? '', payload.progress, payload.message ?? '');
  }
  throw ZanshinFfiException('ffi.unknown', 'expected WatcherEvent or Progress payload, got ${env.dataType}');
}

// ── NativeCallable registration ───────────────────────────────────────────────

// One process-global sink registered by the worker isolate (Story 3.6): the
// same NativeCallable.listener mechanism serves watcher events AND progress
// notifications, per project-context's "no special-case channels" rule.
ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ZanshinBuf>)>? _callable;

void _handleNativeEvent(void Function(ZanshinRawEvent event) onEvent, ffi.Pointer<ZanshinBuf> token) {
  try {
    final buf = FfiBuffer.fromToken(token);
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose();
    }
    onEvent(decodeEventEnvelope(bytes));
  } catch (e, st) {
    // A malformed buffer or decode failure must NOT become an uncaught async
    // error — that would kill the worker isolate (that failure mode is
    // reserved for the deliberate fault-injection test, AC 15b). Production
    // decode is always try/caught here.
    _log.warning('dropping malformed event: $e', e, st);
  }
}

/// Create the `NativeCallable.listener`, register its native function pointer
/// as the process-global event sink, and forward every decoded event to
/// [onEvent].
///
/// Must be called from the isolate that will also call [closeEventSink] — the
/// callable keeps that isolate alive until closed (`NativeCallable.listener`
/// contract, api.dart.dev), which is precisely why graceful worker shutdown
/// needs the `ShutdownCommand` handshake (see `worker/isolate.dart`).
///
/// Throws [StateError] if this isolate already registered a sink: silently
/// replacing `_callable` would orphan the previous `NativeCallable`, and an
/// unclosed listener keeps its isolate alive forever. Production registers
/// exactly once per worker; a second call is a programming error.
void registerEventSink(void Function(ZanshinRawEvent event) onEvent) {
  if (_callable != null) {
    throw StateError('registerEventSink: a sink is already registered in this isolate — closeEventSink() first');
  }
  final callable = ffi.NativeCallable<ffi.Void Function(ffi.Pointer<ZanshinBuf>)>.listener(
    (ffi.Pointer<ZanshinBuf> token) => _handleNativeEvent(onEvent, token),
  );
  _callable = callable;
  zanshin_events_register(callable.nativeFunction);
}

/// Clear the FFI-side sink only — does **not** close the `NativeCallable`.
///
/// Handle-free and callable from **any** isolate (AD-2 exemption, like
/// `zanshin_log`): the **main** isolate calls this on unexpected worker death
/// so no later native dispatch invokes the dead worker's now-unreachable
/// callable. Idempotent (mirrors `zanshin_events_unregister`'s contract).
void unregisterEventSink() {
  zanshin_events_unregister();
}

/// Unregister the sink, **then** close the `NativeCallable` — in that order.
///
/// Invoking a `NativeCallable`'s pointer after `close()` is undefined
/// behaviour (api.dart.dev); unregistering first guarantees no in-flight
/// dispatch can reach the callable once it starts closing. Call only from the
/// isolate that created the callable via [registerEventSink].
void closeEventSink() {
  zanshin_events_unregister();
  _callable?.close();
  _callable = null;
}
