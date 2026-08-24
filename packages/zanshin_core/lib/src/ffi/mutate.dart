// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

// This file owns the Dart half of the Story 6.5 mutation surface: the six
// zanshin_* adapters (describe/new_change/edit/abandon/undo/git_fetch), the
// MutationResult model, and its decoder. `dart:ffi` stays inside `ffi/` — only
// the worker isolate calls these adapters.

// ── Request-buffer helper ────────────────────────────────────────────────────

/// Build a `ChangeIdList` `FlatBuffers` request buffer for [ids], copy it into a
/// `malloc`-allocated `Pointer<Uint8>`, invoke [fn] with the pointer and byte
/// length, and free the pointer afterward.
///
/// Same ownership discipline as the lone-string adapters' `toNativeUtf8()` /
/// `calloc.free()` pairs (AR-P-5 inbound rule), generalized to raw bytes: Rust
/// only borrows the buffer for the duration of the call.
T _withChangeIdListBytes<T>(List<String> ids, T Function(ffi.Pointer<ffi.Uint8>, int) fn) {
  final Uint8List bytes = fbs.ChangeIdListObjectBuilder(changeIds: ids).toBytes();
  final ffi.Pointer<ffi.Uint8> ptr = malloc.allocate<ffi.Uint8>(bytes.length);
  ptr.asTypedList(bytes.length).setAll(0, bytes);
  try {
    return fn(ptr, bytes.length);
  } finally {
    malloc.free(ptr);
  }
}

// ── FFI adapters ──────────────────────────────────────────────────────────────

/// Call `zanshin_describe` with the raw `u64` handle, [changeId], and
/// [description], and return the FlatBuffers `Envelope` bytes.
Uint8List zanshinDescribe(int rawHandle, String changeId, String description) {
  if (changeId.codeUnits.contains(0)) {
    throw ArgumentError.value(changeId, 'changeId', 'must not contain an interior NUL (U+0000)');
  }
  if (description.codeUnits.contains(0)) {
    throw ArgumentError.value(description, 'description', 'must not contain an interior NUL (U+0000)');
  }
  final ffi.Pointer<Utf8> changeIdPtr = changeId.toNativeUtf8();
  try {
    final ffi.Pointer<Utf8> descriptionPtr = description.toNativeUtf8();
    try {
      final ffi.Pointer<ZanshinBuf> token = zanshin_describe(rawHandle, changeIdPtr.cast(), descriptionPtr.cast());
      final buf = FfiBuffer.fromToken(token);
      try {
        return Uint8List.fromList(buf.bytes);
      } finally {
        buf.dispose(); // inner: free the returned buffer
      }
    } finally {
      calloc.free(descriptionPtr);
    }
  } finally {
    calloc.free(changeIdPtr);
  }
}

/// Call `zanshin_new_change` with the raw `u64` handle and [parents] (crossed as
/// a `ChangeIdList` request buffer), and return the FlatBuffers `Envelope` bytes.
Uint8List zanshinNewChange(int rawHandle, List<String> parents) => _withChangeIdListBytes(parents, (ptr, len) {
  final ffi.Pointer<ZanshinBuf> token = zanshin_new_change(rawHandle, ptr, len);
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
});

/// Call `zanshin_edit` with the raw `u64` handle and [changeId], and return the
/// FlatBuffers `Envelope` bytes.
Uint8List zanshinEdit(int rawHandle, String changeId) {
  if (changeId.codeUnits.contains(0)) {
    throw ArgumentError.value(changeId, 'changeId', 'must not contain an interior NUL (U+0000)');
  }
  final ffi.Pointer<Utf8> p = changeId.toNativeUtf8();
  try {
    final ffi.Pointer<ZanshinBuf> token = zanshin_edit(rawHandle, p.cast());
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose(); // inner: free the returned buffer
    }
  } finally {
    calloc.free(p); // outer: free the C string we allocated
  }
}

/// Call `zanshin_abandon` with the raw `u64` handle and [changeIds] (crossed as
/// a `ChangeIdList` request buffer), and return the FlatBuffers `Envelope` bytes.
Uint8List zanshinAbandon(int rawHandle, List<String> changeIds) => _withChangeIdListBytes(changeIds, (ptr, len) {
  final ffi.Pointer<ZanshinBuf> token = zanshin_abandon(rawHandle, ptr, len);
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
});

/// Call `zanshin_undo` with the raw `u64` handle, and return the FlatBuffers
/// `Envelope` bytes.
Uint8List zanshinUndo(int rawHandle) {
  final ffi.Pointer<ZanshinBuf> token = zanshin_undo(rawHandle);
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
}

/// Call `zanshin_git_fetch` with the raw `u64` handle and [remoteName], and
/// return the FlatBuffers `Envelope` bytes.
///
/// Progress rides the same process-global event sink `WatcherEvent` already
/// uses (Story 3.6), tagged with the handle's `session_id` — register a
/// `zanshin_events_register` sink and demux by `session_id` to observe it.
Uint8List zanshinGitFetch(int rawHandle, String remoteName) {
  if (remoteName.codeUnits.contains(0)) {
    throw ArgumentError.value(remoteName, 'remoteName', 'must not contain an interior NUL (U+0000)');
  }
  final ffi.Pointer<Utf8> p = remoteName.toNativeUtf8();
  try {
    final ffi.Pointer<ZanshinBuf> token = zanshin_git_fetch(rawHandle, p.cast());
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose(); // inner: free the returned buffer
    }
  } finally {
    calloc.free(p); // outer: free the C string we allocated
  }
}

// ── Dart model ────────────────────────────────────────────────────────────────

/// Outcome of a successful mutation (mirrors `zanshin_jj::MutationResult`).
final class MutationResult {
  const MutationResult({
    required this.newOpId,
    required this.newChangeIds,
    required this.abandonedChangeIds,
    required this.workingCopyChangeId,
  });

  /// Id of the operation this mutation committed.
  final String newOpId;

  /// Change ids of genuinely new changes minted by this mutation. Empty for a
  /// rewrite ([MutationResult] of `describe`) or a pointer move (`edit`); empty
  /// for `abandon` unless `@` itself was among the abandoned ids; always empty
  /// for `undo` and `git_fetch`.
  final List<String> newChangeIds;

  /// The change ids `abandon`'s caller passed in, echoed verbatim. Always empty
  /// for every other mutation.
  final List<String> abandonedChangeIds;

  /// Change id of the working-copy commit (`@`) after this mutation.
  final String workingCopyChangeId;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `MutationResult` `Envelope` buffer into a [MutationResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker`'s mutation methods.
@visibleForTesting
MutationResult decodeMutationResultEnvelope(Uint8List bytes) => _decodeMutationResultEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
MutationResult decodeMutationResultEnvelopeInternal(Uint8List bytes) => _decodeMutationResultEnvelope(bytes);

MutationResult _decodeMutationResultEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.MutationResult) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected MutationResult payload, got ${env.dataType}',
    );
  }
  return MutationResult(
    newOpId: payload.newOpId ?? '',
    newChangeIds: payload.newChangeIds?.toList() ?? const [],
    abandonedChangeIds: payload.abandonedChangeIds?.toList() ?? const [],
    workingCopyChangeId: payload.workingCopyChangeId ?? '',
  );
}
