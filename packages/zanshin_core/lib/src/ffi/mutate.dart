// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

// This file owns the Dart half of the whole mutation surface: the Story 6.5
// adapters (describe/new_change/edit/abandon/undo/git_fetch), Story 9.3's two
// content ops (restore/absorb), the MutationResult / AbsorbResult models, and
// their decoders. `dart:ffi` stays inside `ffi/` — only the worker isolate calls
// these adapters.

// ── Request-buffer helpers ───────────────────────────────────────────────────

/// Copy [bytes] into a `malloc`-allocated `Pointer<Uint8>`, invoke [fn] with the
/// pointer and byte length, and free the pointer afterward.
///
/// Same ownership discipline as the lone-string adapters' `toNativeUtf8()` /
/// `calloc.free()` pairs (AR-P-5 inbound rule), generalized to raw bytes: Rust
/// only borrows the buffer for the duration of the call.
T _withRequestBytes<T>(Uint8List bytes, T Function(ffi.Pointer<ffi.Uint8>, int) fn) {
  final ffi.Pointer<ffi.Uint8> ptr = malloc.allocate<ffi.Uint8>(bytes.length);
  ptr.asTypedList(bytes.length).setAll(0, bytes);
  try {
    return fn(ptr, bytes.length);
  } finally {
    malloc.free(ptr);
  }
}

/// Build a `ChangeIdList` `FlatBuffers` request buffer for [ids] and hand it to
/// [fn] through [_withRequestBytes].
T _withChangeIdListBytes<T>(List<String> ids, T Function(ffi.Pointer<ffi.Uint8>, int) fn) =>
    _withRequestBytes(fbs.ChangeIdListObjectBuilder(changeIds: ids).toBytes(), fn);

/// Reject an interior NUL in a caller-supplied string.
///
/// A FlatBuffers string is length-prefixed, so a NUL would survive the wire —
/// and then land in a jj change id, revset or path, where it can only produce a
/// confusing downstream failure. Guarding here keeps the whole mutation surface
/// consistent with the C-string adapters above, which must reject it.
void _rejectInteriorNul(String? value, String name) {
  if (value != null && value.codeUnits.contains(0)) {
    throw ArgumentError.value(value, name, 'must not contain an interior NUL (U+0000)');
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

/// Call `zanshin_restore` with the raw `u64` handle and a `RestoreRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// A `null` [from]/[into]/[changesIn] is the wire form of "the user did not
/// supply it", which is what applies the CLI's own defaults: if exactly one of
/// [from]/[into] is given the other is `@`; if neither is, the destination
/// ([changesIn], else `@`) is restored from its PARENT tree. [changesIn] may not
/// be combined with [from]/[into]. An empty [paths] means all paths; entries are
/// repo-relative PREFIXES.
Uint8List zanshinRestore(
  int rawHandle, {
  String? from,
  String? into,
  String? changesIn,
  List<String> paths = const <String>[],
  bool restoreDescendants = false,
}) {
  _rejectInteriorNul(from, 'from');
  _rejectInteriorNul(into, 'into');
  _rejectInteriorNul(changesIn, 'changesIn');
  for (final path in paths) {
    _rejectInteriorNul(path, 'paths');
  }
  final Uint8List request = fbs.RestoreRequestObjectBuilder(
    from: from,
    into: into,
    changesIn: changesIn,
    paths: paths,
    restoreDescendants: restoreDescendants,
  ).toBytes();
  return _withRequestBytes(request, (ptr, len) {
    final ffi.Pointer<ZanshinBuf> token = zanshin_restore(rawHandle, ptr, len);
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose();
    }
  });
}

/// Call `zanshin_absorb` with the raw `u64` handle and an `AbsorbRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// A `null` [from] means the source is `@`. A `null` [into] applies the CLI's own
/// `--into` default, the `mutable()` ALIAS, resolved through the repo's effective
/// config — so the user's `[revset-aliases]` decides what it denotes. Unlike
/// every other mutation argument [into] is a revset EXPRESSION, not a change id.
Uint8List zanshinAbsorb(
  int rawHandle, {
  String? from,
  String? into,
  List<String> paths = const <String>[],
}) {
  _rejectInteriorNul(from, 'from');
  _rejectInteriorNul(into, 'into');
  for (final path in paths) {
    _rejectInteriorNul(path, 'paths');
  }
  final Uint8List request = fbs.AbsorbRequestObjectBuilder(from: from, into: into, paths: paths).toBytes();
  return _withRequestBytes(request, (ptr, len) {
    final ffi.Pointer<ZanshinBuf> token = zanshin_absorb(rawHandle, ptr, len);
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose();
    }
  });
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

/// One path `absorb` could not split, with jj-lib's verbatim reason
/// (mirrors `zanshin_jj::SkippedPath`).
final class SkippedPath {
  const SkippedPath({required this.path, required this.reason});

  /// Repo-relative path in jj's internal (`/`-separated) form.
  final String path;

  /// jj-lib's own message — e.g. `Is a symlink`, `Is a conflict`,
  /// `Is a Git submodule`, `Access is denied: …`.
  final String reason;
}

/// Outcome of a successful `absorb` (mirrors `zanshin_jj::AbsorbResult`).
final class AbsorbResult {
  const AbsorbResult({
    required this.mutation,
    required this.rewrittenChangeIds,
    required this.sourceChangeId,
    required this.numRebased,
    required this.skippedPaths,
  });

  /// The shared mutation contract: op id (the PRE-CALL head when nothing was
  /// absorbed) and the working-copy change id afterwards. Its `newChangeIds` /
  /// `abandonedChangeIds` are always empty for absorb.
  final MutationResult mutation;

  /// Change ids of the destination commits the hunks were absorbed INTO, in
  /// forward topological order. EMPTY means nothing was absorbable — and then no
  /// operation was written either.
  final List<String> rewrittenChangeIds;

  /// Change id of the source commit after the absorbed hunks were removed from
  /// it, or `null` when jj-lib abandoned the source (it became discardable) or
  /// nothing moved.
  final String? sourceChangeId;

  /// Number of descendant commits rebased. Excludes the destinations; includes
  /// the rewritten source.
  final int numRebased;

  /// Paths jj-lib refused to split. The CLI prints one warning per entry; the
  /// remaining paths still absorb.
  final List<SkippedPath> skippedPaths;
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

/// Decode an `AbsorbResult` `Envelope` buffer into an [AbsorbResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.absorb`.
@visibleForTesting
AbsorbResult decodeAbsorbResultEnvelope(Uint8List bytes) => _decodeAbsorbResultEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
AbsorbResult decodeAbsorbResultEnvelopeInternal(Uint8List bytes) => _decodeAbsorbResultEnvelope(bytes);

AbsorbResult _decodeAbsorbResultEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.AbsorbResult) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected AbsorbResult payload, got ${env.dataType}',
    );
  }
  final fbs.MutationResult? nested = payload.mutation;
  return AbsorbResult(
    mutation: MutationResult(
      newOpId: nested?.newOpId ?? '',
      newChangeIds: nested?.newChangeIds?.toList() ?? const [],
      abandonedChangeIds: nested?.abandonedChangeIds?.toList() ?? const [],
      workingCopyChangeId: nested?.workingCopyChangeId ?? '',
    ),
    rewrittenChangeIds: payload.rewrittenChangeIds?.toList() ?? const [],
    // Null-for-absence: the field is unset when jj-lib abandoned the source or
    // nothing moved — never coerced to ''.
    sourceChangeId: payload.sourceChangeId,
    numRebased: payload.numRebased,
    skippedPaths:
        payload.skippedPaths?.map((p) => SkippedPath(path: p.path ?? '', reason: p.reason ?? '')).toList() ?? const [],
  );
}
