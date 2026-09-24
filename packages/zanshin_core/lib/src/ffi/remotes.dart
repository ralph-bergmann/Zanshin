// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'request_bytes.dart';
import 'warning.dart';

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_remotes` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). No CString argument: remotes is handle-only,
/// exactly like `zanshinBookmarks`.
Uint8List zanshinRemotes(int rawHandle) => readToken(zanshin_remotes(rawHandle));

// ── Dart models ───────────────────────────────────────────────────────────────

/// One configured git remote (FR-JJ-9).
///
/// Both URLs are verbatim — credentials are NOT scrubbed and SSH is NOT
/// rewritten to HTTPS. The caller is responsible for any display scrubbing.
final class Remote {
  const Remote({required this.name, required this.url, required this.pushUrl});

  /// Remote name (UTF-8), e.g. `"origin"`.
  final String name;

  /// Fetch URL verbatim (no credential scrubbing).
  final String url;

  /// Push URL when it DIFFERS from [url], `null` otherwise — null-for-absence,
  /// never `''`. Absent means "this remote pushes to its fetch URL".
  ///
  /// This is a DIFFERENCE, not a raw `remote.<name>.pushurl` read: it is exactly
  /// the question `jj git remote list` answers when it prints its `(push: …)`
  /// suffix only for remotes whose two URLs differ.
  ///
  /// Because of that, this value is NOT round-trippable back through
  /// `gitRemoteSetUrl`: feeding a `null` back would clear a `pushurl` that was
  /// configured but happened to equal [url]. Treat `null` as "leave the push URL
  /// alone", not "clear it".
  final String? pushUrl;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `Remotes` `Envelope` buffer into a list of [Remote]s that also
/// carries the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.remotes`.
@visibleForTesting
WarnedList<Remote> decodeRemotesEnvelope(Uint8List bytes) => _decodeRemotesEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<Remote> decodeRemotesEnvelopeInternal(Uint8List bytes) => _decodeRemotesEnvelope(bytes);

WarnedList<Remote> _decodeRemotesEnvelope(Uint8List bytes) {
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
  return WarnedList(payload.remotes?.map(_mapRemote).toList() ?? const [], decodeEnvelopeWarningsInternal(env));
}

Remote _mapRemote(fbs.Remote r) => Remote(
  name: r.name ?? '',
  url: r.url ?? '',
  // NO `?? ''` here, unlike the two siblings: coalescing would destroy the
  // absent/present distinction this field exists to carry.
  pushUrl: r.pushUrl,
);
