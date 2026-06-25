// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_remotes` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). No CString argument: remotes is handle-only,
/// exactly like `zanshinBookmarks`.
Uint8List zanshinRemotes(int rawHandle) {
  final ffi.Pointer<ZanshinBuf> token = zanshin_remotes(rawHandle);
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
}

// ── Dart models ───────────────────────────────────────────────────────────────

/// One configured git remote (FR-JJ-9).
///
/// `url` is the fetch URL verbatim — credentials are NOT scrubbed and SSH is
/// NOT rewritten to HTTPS. The caller is responsible for any display scrubbing.
final class Remote {
  const Remote({required this.name, required this.url});

  /// Remote name (UTF-8), e.g. `"origin"`.
  final String name;

  /// Fetch URL verbatim (no credential scrubbing).
  final String url;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `Remotes` `Envelope` buffer into a list of [Remote]s.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.remotes`.
@visibleForTesting
List<Remote> decodeRemotesEnvelope(Uint8List bytes) => _decodeRemotesEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
List<Remote> decodeRemotesEnvelopeInternal(Uint8List bytes) => _decodeRemotesEnvelope(bytes);

List<Remote> _decodeRemotesEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Remotes) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected Remotes payload, got ${env.dataType}',
    );
  }
  return payload.remotes?.map(_mapRemote).toList() ?? const [];
}

Remote _mapRemote(fbs.Remote r) => Remote(
  name: r.name ?? '',
  url: r.url ?? '',
);
