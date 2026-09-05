// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'change.dart' show Change, mapChangeTable;
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'request_bytes.dart';
import 'status.dart' show FileChange, mapFileChangeTable;

// This file owns the Dart half of Story 9.6's three commit READ views: the
// adapters (show/evolog/interdiff), their models, and their decoders.
// `dart:ffi` stays inside `ffi/` — only the worker isolate calls these adapters.
//
// All three cross a FlatBuffers REQUEST buffer rather than C strings: each is a
// composite whose revision argument must be distinguishably ABSENT (null), which
// is what applies the CLI's own `@` default instead of one this layer invented,
// and `evolog` additionally carries an optional scalar limit.
//
// The two nested shapes — a `Change` and a `[FileChange]` — are decoded through
// `change.dart`'s and `status.dart`'s shared table mappers, never a second
// spelling: a field added to either must reach every payload that carries it.

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_show` with the raw `u64` handle and a `ShowRequest` request
/// buffer, and return the FlatBuffers `Envelope` bytes.
///
/// A `null` [revset] is the wire form of "the user did not supply it", which
/// applies the CLI's own default `@` — the LAST-SNAPSHOTTED working-copy commit,
/// since Zanshin never snapshots. [revset] is an EXPRESSION, not a change id: the
/// CLI unions its revsets, so entries are per COMMIT — a revset naming two commits
/// of ONE divergent change yields two entries with the same `Change.id`. A BARE
/// divergent change-id symbol does NOT get that far: jj-lib's own `SymbolResolver`
/// refuses it (`RevsetResolutionError::DivergentChangeId`), exactly as
/// `jj show <divergent-id>` fails in the CLI, and it surfaces as
/// `jj.revset_resolution_error`. Union the two COMMIT hexes to address both.
Uint8List zanshinShow(int rawHandle, {String? revset}) {
  rejectInteriorNul(revset, 'revset');
  final Uint8List request = fbs.ShowRequestObjectBuilder(revset: revset).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_show(rawHandle, ptr, len));
}

/// Call `zanshin_evolog` with the raw `u64` handle and an `EvologRequest` request
/// buffer, and return the FlatBuffers `Envelope` bytes.
///
/// [revset] behaves as in [zanshinShow]. [limit] is the CLI's `-n/--limit`, sent
/// as a presence-flag pair because `limit: 0` is a MEANINGFUL value (an empty
/// result, not an error) and so cannot be encoded as absence.
///
/// [limit] SATURATES at [_maxWireLimit] (4294967295), the schema's documented
/// saturating-`uint` convention. Dart ints are 64-bit while the wire field is a
/// `uint`, so an unclamped `4294967296` would be written as `0` and come back as
/// an EMPTY evolog — the most misleading possible answer to "give me lots of
/// entries". Clamping makes an over-large limit mean "everything", which is what
/// the caller asked for. A NEGATIVE limit is refused instead of clamped: it can
/// only be a caller bug, and both `0` and "no limit" are already spelled.
Uint8List zanshinEvolog(int rawHandle, {String? revset, int? limit}) {
  rejectInteriorNul(revset, 'revset');
  if (limit != null && limit < 0) {
    throw ArgumentError.value(limit, 'limit', 'must not be negative');
  }
  final Uint8List request = fbs.EvologRequestObjectBuilder(
    revset: revset,
    limit: limit == null ? 0 : (limit > _maxWireLimit ? _maxWireLimit : limit),
    hasLimit: limit != null,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_evolog(rawHandle, ptr, len));
}

/// The largest value the `EvologRequest.limit` `uint` field can carry.
///
/// Above this a limit is a "give me everything" request in every practical sense
/// — no evolution has four billion versions — so it saturates rather than wraps.
const _maxWireLimit = 0xFFFFFFFF;

/// Call `zanshin_interdiff` with the raw `u64` handle and an `InterdiffRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// Unlike [zanshinShow], [from] and [to] are single jj reverse-hex CHANGE IDS.
/// They inherit the CLI `resolve_single_rev`'s ambiguity REFUSAL but NOT its
/// address space: each side resolves to the one VISIBLE commit carrying that
/// change-id prefix, so a commit hex, a revset expression and a HIDDEN commit are
/// all unaddressable here — [EvologEntry.predecessorCommitIds] among them. An
/// absent side is `@`, but omitting BOTH is refused with `jj.invalid_input`
/// (the CLI's `ArgGroup … required(true)`). [paths] entries are repo-relative
/// PREFIXES; an empty list means all paths.
Uint8List zanshinInterdiff(
  int rawHandle, {
  String? from,
  String? to,
  List<String> paths = const <String>[],
}) {
  rejectInteriorNul(from, 'from');
  rejectInteriorNul(to, 'to');
  for (final path in paths) {
    rejectInteriorNul(path, 'paths');
  }
  final Uint8List request = fbs.InterdiffRequestObjectBuilder(from: from, to: to, paths: paths).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_interdiff(rawHandle, ptr, len));
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// One revision as `show` presents it (mirrors `zanshin_jj::ShowEntry`).
final class ShowEntry {
  const ShowEntry({required this.change, required this.fileChanges});

  /// Full metadata for the revision — the same [Change] `getChange` returns for
  /// this commit.
  final Change change;

  /// Per-path changes relative to the MERGED parent tree, in jj's own diff order.
  /// For a merge commit that is only what the merge itself changed; for the root
  /// commit it is empty. `renamed`/`copied` entries CAN appear here, unlike in
  /// [zanshinInterdiff]'s result.
  final List<FileChange> fileChanges;
}

/// One step of a change's evolution (mirrors `zanshin_jj::EvologEntry`).
final class EvologEntry {
  const EvologEntry({
    required this.change,
    required this.predecessorCommitIds,
    required this.operationId,
  });

  /// Full metadata for this version of the change — with two exceptions that come
  /// from reusing the single [Change] construction site: `divergent` reports
  /// whether the change has several VISIBLE commits RIGHT NOW (the same answer on
  /// every row of one evolution, never a statement about this historical version)
  /// and `isAnonymous` reads today's local bookmarks. Everything else (`commitId`,
  /// `parents`, `description`, signatures, timestamps, `conflict`) is this
  /// version's own.
  final Change change;

  /// The commit ids (hex) this version was rewritten FROM. Empty when
  /// [operationId] is `null`, and for a commit that was never rewritten. These are
  /// HIDDEN commits, so they cannot be passed to [zanshinInterdiff].
  final List<String> predecessorCommitIds;

  /// The operation that created or rewrote this commit, or `null` for an entry
  /// the walk emitted from its flush tail — it reached an operation storing no
  /// predecessors and could go no further. That `null` is the only signal that an
  /// evolution may be TRUNCATED; the CLI truncates silently.
  final String? operationId;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `ShowView` `Envelope` buffer into a `List<ShowEntry>`.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.show`.
@visibleForTesting
List<ShowEntry> decodeShowViewEnvelope(Uint8List bytes) => _decodeShowViewEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
List<ShowEntry> decodeShowViewEnvelopeInternal(Uint8List bytes) => _decodeShowViewEnvelope(bytes);

List<ShowEntry> _decodeShowViewEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.ShowView) {
    throw ZanshinFfiException('ffi.unknown', 'expected ShowView payload, got ${env.dataType}');
  }
  return payload.entries?.map(_mapShowEntry).toList() ?? const [];
}

ShowEntry _mapShowEntry(fbs.ShowEntry e) => ShowEntry(
  change: _requireChange(e.change, 'ShowEntry'),
  fileChanges: e.fileChanges?.map(mapFileChangeTable).toList() ?? const [],
);

/// Decode an `EvologView` `Envelope` buffer into a `List<EvologEntry>`.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.evolog`.
@visibleForTesting
List<EvologEntry> decodeEvologViewEnvelope(Uint8List bytes) => _decodeEvologViewEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
List<EvologEntry> decodeEvologViewEnvelopeInternal(Uint8List bytes) => _decodeEvologViewEnvelope(bytes);

List<EvologEntry> _decodeEvologViewEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.EvologView) {
    throw ZanshinFfiException('ffi.unknown', 'expected EvologView payload, got ${env.dataType}');
  }
  return payload.entries?.map(_mapEvologEntry).toList() ?? const [];
}

EvologEntry _mapEvologEntry(fbs.EvologEntry e) => EvologEntry(
  change: _requireChange(e.change, 'EvologEntry'),
  predecessorCommitIds: e.predecessorCommitIds?.toList() ?? const [],
  // Null-for-absence, not a sentinel: an absent operation id means the walk
  // reached its flush tail, i.e. the evolution may be truncated.
  operationId: e.operationId,
);

/// Decode an `InterdiffView` `Envelope` buffer into a `List<FileChange>`.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.interdiff`.
@visibleForTesting
List<FileChange> decodeInterdiffViewEnvelope(Uint8List bytes) => _decodeInterdiffViewEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
List<FileChange> decodeInterdiffViewEnvelopeInternal(Uint8List bytes) => _decodeInterdiffViewEnvelope(bytes);

List<FileChange> _decodeInterdiffViewEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.InterdiffView) {
    throw ZanshinFfiException('ffi.unknown', 'expected InterdiffView payload, got ${env.dataType}');
  }
  return payload.fileChanges?.map(mapFileChangeTable).toList() ?? const [];
}

/// Unwrap a nested `Change` table, which Rust always writes.
///
/// A missing one is a malformed buffer, not a modellable state — so it surfaces
/// as the `ffi.unknown` sentinel rather than a raw `TypeError` or a fabricated
/// empty [Change].
Change _requireChange(fbs.Change? change, String owner) {
  if (change == null) {
    throw ZanshinFfiException('ffi.unknown', '$owner is missing its nested Change table');
  }
  return mapChangeTable(change);
}

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  return env;
}
