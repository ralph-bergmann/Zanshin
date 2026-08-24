// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_log_defaults` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). No CString argument: log-defaults is handle-only,
/// exactly like `zanshinRemotes`.
Uint8List zanshinLogDefaults(int rawHandle) {
  final ffi.Pointer<ZanshinBuf> token = zanshin_log_defaults(rawHandle);
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
}

// ── Dart models ───────────────────────────────────────────────────────────────

/// The repo's EFFECTIVE `jj log` defaults (Story 4.9) — the values the user's own
/// `jj` CLI would apply, after their `[revsets]` / `[ui]` config overrides.
///
/// These are pre-fills for `RepoHandle.graphSlice`'s pass-through parameters
/// (FR-JJ-17), never applied silently — the UI shows them and the user edits
/// them. The compile-time constants in `graph.dart` (`defaultLogRevset`,
/// `defaultGraphPrioritize`, `defaultShortPrefixes`, `defaultSyntheticElided`)
/// are the *builtin* values and stay available for a pre-config pre-fill; this
/// model is the config-resolved source the UI should prefer.
final class LogDefaults {
  /// Wrap the four effective values.
  const LogDefaults({
    required this.log,
    required this.logGraphPrioritize,
    required this.shortPrefixes,
    required this.syntheticElided,
  });

  /// `revsets.log` — the revset `jj log` shows without `-r`.
  final String log;

  /// `revsets.log-graph-prioritize` — the branch emitted first.
  final String logGraphPrioritize;

  /// `revsets.short-prefixes` — the shortest-prefix disambiguation set.
  ///
  /// Falls back to [log] when the config key is absent from every layer; an
  /// EMPTY string means disambiguation is DISABLED and is returned verbatim.
  final String shortPrefixes;

  /// `ui.log-synthetic-elided-nodes` — render elided ancestry as synthetic rows.
  final bool syntheticElided;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `LogDefaults` `Envelope` buffer into a [LogDefaults].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.logDefaults`.
@visibleForTesting
LogDefaults decodeLogDefaultsEnvelope(Uint8List bytes) => _decodeLogDefaultsEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
LogDefaults decodeLogDefaultsEnvelopeInternal(Uint8List bytes) => _decodeLogDefaultsEnvelope(bytes);

LogDefaults _decodeLogDefaultsEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.LogDefaults) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected LogDefaults payload, got ${env.dataType}',
    );
  }
  return _mapLogDefaults(payload);
}

LogDefaults _mapLogDefaults(fbs.LogDefaults d) => LogDefaults(
  log: d.log ?? '',
  logGraphPrioritize: d.logGraphPrioritize ?? '',
  shortPrefixes: d.shortPrefixes ?? '',
  syntheticElided: d.syntheticElided,
);
