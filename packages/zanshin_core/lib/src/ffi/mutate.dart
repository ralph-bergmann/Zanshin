// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show FinishFacts, decodeEnvelopeErrorInternal, decodeFinishFactsInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of the whole mutation surface: the Story 6.5
// adapters (describe/new_change/edit/abandon/undo/git_fetch), Story 9.3's two
// content ops (restore/absorb), the MutationResult / AbsorbResult models, and
// their decoders. `dart:ffi` stays inside `ffi/` — only the worker isolate calls
// these adapters.

// ── Request-buffer helpers ───────────────────────────────────────────────────

/// Build a `ChangeIdList` `FlatBuffers` request buffer for [ids] — plus, for
/// `zanshin_new_change` only, [insertAfter] / [insertBefore] (Story 9.48) — and
/// hand it to [fn] through [withRequestBytes].
///
/// [kind] tags the buffer for ONE wrapper: this single table is read by both
/// `zanshin_new_change` (as `parents`) and `zanshin_abandon` (as `change_ids`),
/// and Rust refuses a buffer whose tag is not its own — so mis-routing it can no
/// longer abandon the commits the caller named as parents.
T _withChangeIdListBytes<T>(
  fbs.RequestKind kind,
  List<String> ids,
  T Function(ffi.Pointer<ffi.Uint8>, int) fn, {
  List<String>? insertAfter,
  List<String>? insertBefore,
}) => withRequestBytes(
  fbs.ChangeIdListObjectBuilder(
    kind: kind,
    changeIds: ids,
    insertAfter: insertAfter,
    insertBefore: insertBefore,
  ).toBytes(),
  fn,
);

// ── FFI adapters ──────────────────────────────────────────────────────────────

/// Call `zanshin_describe` with the raw `u64` handle, [changeId], and
/// [description], and return the FlatBuffers `Envelope` bytes.
Uint8List zanshinDescribe(int rawHandle, String changeId, String description) {
  rejectInteriorNul(changeId, 'changeId');
  rejectInteriorNul(description, 'description');
  final ffi.Pointer<Utf8> changeIdPtr = changeId.toNativeUtf8();
  try {
    final ffi.Pointer<Utf8> descriptionPtr = description.toNativeUtf8();
    try {
      return readToken(zanshin_describe(rawHandle, changeIdPtr.cast(), descriptionPtr.cast()));
    } finally {
      calloc.free(descriptionPtr);
    }
  } finally {
    calloc.free(changeIdPtr);
  }
}

/// Call `zanshin_new_change` with the raw `u64` handle, [parents] and the
/// `jj new -A` / `-B` targets [insertAfter] / [insertBefore] (Story 9.48; empty =
/// the flag not given), crossed as one `ChangeIdList` request buffer, and return
/// the FlatBuffers `Envelope` bytes.
Uint8List zanshinNewChange(
  int rawHandle,
  List<String> parents, {
  List<String> insertAfter = const [],
  List<String> insertBefore = const [],
}) {
  rejectInteriorNuls(parents, 'parents');
  rejectInteriorNuls(insertAfter, 'insertAfter');
  rejectInteriorNuls(insertBefore, 'insertBefore');
  return _withChangeIdListBytes(
    fbs.RequestKind.NewChange,
    parents,
    (ptr, len) => readToken(zanshin_new_change(rawHandle, ptr, len)),
    insertAfter: insertAfter,
    insertBefore: insertBefore,
  );
}

/// Call `zanshin_edit` with the raw `u64` handle and [changeId], and return the
/// FlatBuffers `Envelope` bytes.
Uint8List zanshinEdit(int rawHandle, String changeId) {
  rejectInteriorNul(changeId, 'changeId');
  final ffi.Pointer<Utf8> p = changeId.toNativeUtf8();
  try {
    return readToken(zanshin_edit(rawHandle, p.cast()));
  } finally {
    calloc.free(p); // outer: free the C string we allocated
  }
}

/// Call `zanshin_abandon` with the raw `u64` handle and [changeIds] (crossed as
/// a `ChangeIdList` request buffer), and return the FlatBuffers `Envelope` bytes.
Uint8List zanshinAbandon(int rawHandle, List<String> changeIds) => _withChangeIdListBytes(
  fbs.RequestKind.Abandon,
  changeIds,
  (ptr, len) => readToken(zanshin_abandon(rawHandle, ptr, len)),
);

/// Call `zanshin_undo` with the raw `u64` handle and [allowCrossWorkspace] (the
/// CLI's `--allow-cross-workspace`, a plain C `bool` — ADR-0001's scalar rule),
/// and return the FlatBuffers `Envelope` bytes.
Uint8List zanshinUndo(int rawHandle, {bool allowCrossWorkspace = false}) =>
    readToken(zanshin_undo(rawHandle, allowCrossWorkspace));

/// Call `zanshin_restore` with the raw `u64` handle and a `RestoreRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// A `null` [from]/[into]/[changesIn] is the wire form of "the user did not
/// supply it", which is what applies the CLI's own defaults: if exactly one of
/// [from]/[into] is given the other is `@`; if neither is, the destination
/// ([changesIn], else `@`) is restored from its PARENT tree. [changesIn] may not
/// be combined with [from]/[into]. An empty [paths] means all paths; entries are
/// repo-relative PREFIXES — and an empty-STRING entry is the repository root, which
/// prefixes everything, so `paths: ['']` matches all paths just as `paths: []` does.
Uint8List zanshinRestore(
  int rawHandle, {
  String? from,
  String? into,
  String? changesIn,
  List<String> paths = const <String>[],
  bool restoreDescendants = false,
}) {
  rejectInteriorNul(from, 'from');
  rejectInteriorNul(into, 'into');
  rejectInteriorNul(changesIn, 'changesIn');
  rejectInteriorNuls(paths, 'paths');
  final Uint8List request = fbs.RestoreRequestObjectBuilder(
    kind: fbs.RequestKind.Restore,
    from: from,
    into: into,
    changesIn: changesIn,
    paths: paths,
    restoreDescendants: restoreDescendants,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_restore(rawHandle, ptr, len)));
}

/// Call `zanshin_absorb` with the raw `u64` handle and an `AbsorbRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// A `null` [from] means the source is `@`. A `null` [into] applies the CLI's own
/// `--into` default, the `mutable()` ALIAS, resolved through the repo's effective
/// config — so the user's `[revset-aliases]` decides what it denotes. Unlike
/// every other mutation argument [into] is a revset EXPRESSION, not a change id.
/// [paths] behaves exactly as in [zanshinRestore], empty-string entry included.
Uint8List zanshinAbsorb(
  int rawHandle, {
  String? from,
  String? into,
  List<String> paths = const <String>[],
}) {
  rejectInteriorNul(from, 'from');
  rejectInteriorNul(into, 'into');
  rejectInteriorNuls(paths, 'paths');
  final Uint8List request = fbs.AbsorbRequestObjectBuilder(
    kind: fbs.RequestKind.Absorb,
    from: from,
    into: into,
    paths: paths,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_absorb(rawHandle, ptr, len)));
}

// ── Dart model ────────────────────────────────────────────────────────────────

/// Outcome of a successful mutation (mirrors `zanshin_jj::MutationResult`).
final class MutationResult {
  const MutationResult({
    required this.newOpId,
    required this.newChangeIds,
    required this.abandonedChangeIds,
    required this.workingCopyChangeId,
    required this.finish,
    this.warnings = const [],
  });

  /// Id of the operation this mutation committed.
  final String newOpId;

  /// Change ids of genuinely new changes minted by this mutation. Empty for a
  /// rewrite ([MutationResult] of `describe`) or a pointer move (`edit`); empty
  /// for `abandon` — and `squash` — unless `@` itself was abandoned (then the
  /// replacement `@`); for `split` the one part with a new change id; always
  /// empty for `undo`, `git_fetch` and `git_import` (jj-lib's import stats have
  /// no minted-change concept, and a replacement `@` is reported through
  /// [workingCopyChangeId]).
  final List<String> newChangeIds;

  /// The change ids `abandon`'s caller passed in, echoed verbatim. Always empty
  /// for every other mutation EXCEPT `git_fetch` and `squash`, which have no
  /// second place for them (a fetch's `GitFetchResult` nests this result) and
  /// so report jj-lib's OWN abandonments here: for
  /// `git_fetch` the commits the import dropped because they became unreachable
  /// in git (what `git.abandon-unreachable-commits` governs) — empty when that
  /// key is off, or when the fetch made nothing unreachable; for `squash` the
  /// sources it abandoned (Story 9.15). `git_import` keeps its
  /// abandonments in `GitImportResult.abandonedChangeIds` instead.
  final List<String> abandonedChangeIds;

  /// Change id of the working-copy commit (`@`) after this mutation.
  final String workingCopyChangeId;

  /// The colocated Git export failures this mutation's commit hit — the jj
  /// CLI's `finish_transaction` export report as data (Story 9.26). `null` when
  /// nothing failed to export, and always outside a colocated workspace. Every
  /// other `finish_transaction` caveat (the empty-identity note, `@` becoming
  /// immutable, a failed Git HEAD update) is one of the [warnings].
  final FinishFacts? finish;

  /// The call's warnings (Story 9.32), in the CLI's print order — empty when
  /// there were none, and always empty on a result nested in another payload
  /// (the enclosing result carries them).
  final List<ZanshinWarning> warnings;
}

/// Rebuild a [MutationResult] from its table — the ONE spelling every payload
/// that nests the shared mutation contract decodes through. An absent table is
/// an empty contract, not a crash. [warnings] are the enclosing envelope's —
/// only a top-level `MutationResult` decode passes any.
MutationResult decodeMutationResultInternal(
  fbs.MutationResult? m, {
  List<ZanshinWarning> warnings = const [],
}) => MutationResult(
  newOpId: m?.newOpId ?? '',
  newChangeIds: m?.newChangeIds?.toList() ?? const [],
  abandonedChangeIds: m?.abandonedChangeIds?.toList() ?? const [],
  workingCopyChangeId: m?.workingCopyChangeId ?? '',
  finish: decodeFinishFactsInternal(m?.finish),
  warnings: warnings,
);

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
    this.warnings = const [],
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
  ///
  /// Crosses the wire as a `uint`: jj-lib counts in `usize`, and a count above
  /// 4294967295 SATURATES at that value rather than wrapping. It is a progress
  /// figure for the UI, never something a decision should key off.
  final int numRebased;

  /// Paths jj-lib refused to split. The CLI prints one warning per entry — each
  /// is also a `jj.absorb_path_skipped` entry of [warnings]; the remaining paths
  /// still absorb.
  final List<SkippedPath> skippedPaths;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none. The nested [mutation] carries none of its own.
  final List<ZanshinWarning> warnings;
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
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.MutationResult) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected MutationResult payload, got ${env.dataType}',
    );
  }
  return decodeMutationResultInternal(payload, warnings: decodeEnvelopeWarningsInternal(env));
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
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.AbsorbResult) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected AbsorbResult payload, got ${env.dataType}',
    );
  }
  return AbsorbResult(
    mutation: decodeMutationResultInternal(payload.mutation),
    rewrittenChangeIds: payload.rewrittenChangeIds?.toList() ?? const [],
    // Null-for-absence: the field is unset when jj-lib abandoned the source or
    // nothing moved — never coerced to ''.
    sourceChangeId: payload.sourceChangeId,
    numRebased: payload.numRebased,
    skippedPaths:
        payload.skippedPaths?.map((p) => SkippedPath(path: p.path ?? '', reason: p.reason ?? '')).toList() ?? const [],
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}
