// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'bindings.dart' as bindings;

// FFI log-level contract — MUST mirror `crates/zanshin-ffi/src/logging.rs`.
// Deliberately small + stable; NOT `package:logging`'s numeric levels (those are
// mapped onto these by [ffiLogLevel]).
const _levelError = 1;
const _levelWarn = 2;
const _levelInfo = 3;
const _levelDebug = 4;
const _levelTrace = 5;

StreamSubscription<LogRecord>? _subscription;

/// Route every `package:logging` record into the Rust `tracing` sink (AR-P-5).
///
/// Rust owns the only log file; this attaches a single listener to [Logger.root]
/// that forwards each record across the FFI boundary via `zanshin_log`. Idempotent
/// — calling it again is a no-op. Call once at startup. Safe to call from any
/// isolate: `zanshin_log` is handle-free and `tracing`'s subscriber is thread-safe.
void initLogForwarding({Level level = Level.INFO}) {
  Logger.root.level = level;
  _subscription ??= Logger.root.onRecord.listen(forwardLogRecord);
}

/// Detach the forwarding listener. Mainly for tests and clean teardown.
Future<void> stopLogForwarding() async {
  await _subscription?.cancel();
  _subscription = null;
}

/// Map a `package:logging` [Level] onto the small, stable FFI level contract
/// (1=error … 5=trace). Thresholds, not equality, so custom levels between the
/// named ones bucket sensibly.
@visibleForTesting
int ffiLogLevel(Level level) {
  final int value = level.value;
  if (value >= Level.SEVERE.value) {
    return _levelError; // SEVERE, SHOUT
  }
  if (value >= Level.WARNING.value) {
    return _levelWarn; // WARNING
  }
  if (value >= Level.CONFIG.value) {
    return _levelInfo; // CONFIG, INFO
  }
  if (value >= Level.FINE.value) {
    return _levelDebug; // FINE
  }
  return _levelTrace; // FINER, FINEST, ALL
}

/// Forward a single record across the FFI boundary.
///
/// Dart allocates the two C strings and frees them after the call (the reverse of
/// the outbound `zanshin_string_free` rule). On any failure — e.g. the cdylib not
/// yet loaded during bootstrap — it degrades to `dart:developer` so logging never
/// throws back into the caller.
void forwardLogRecord(LogRecord record) {
  final int levelInt = ffiLogLevel(record.level);
  final String message = _composeMessage(record);
  final Pointer<Utf8> targetPtr = record.loggerName.toNativeUtf8();
  final Pointer<Utf8> messagePtr = message.toNativeUtf8();
  try {
    bindings.zanshin_log(levelInt, targetPtr.cast(), messagePtr.cast());
  } catch (_) {
    developer.log(message, name: record.loggerName, level: record.level.value);
  } finally {
    malloc
      ..free(targetPtr)
      ..free(messagePtr);
  }
}

/// Fold a record's optional error and stack trace into the forwarded message so
/// they survive into the single Rust log file (the support scenario AR-P-5 cares
/// about). Returns the bare message when neither is present.
String _composeMessage(LogRecord record) {
  if (record.error == null && record.stackTrace == null) {
    return record.message;
  }
  final buffer = StringBuffer(record.message);
  if (record.error != null) {
    buffer.write('\nerror: ${record.error}');
  }
  if (record.stackTrace != null) {
    buffer.write('\n${record.stackTrace}');
  }
  return buffer.toString();
}
