// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'change.dart' show Change, mapChangeTable;
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'status.dart' show FileChange, mapFileChangeTable;
import 'warning.dart';

// This file owns the Dart half of Story 9.6's three commit READ views: the
// adapters (show/evolog/interdiff), their models, and their decoders.
// `dart:ffi` stays inside `ffi/` — only the worker isolate calls these adapters.
//
// All three cross a FlatBuffers REQUEST buffer rather than C strings: each is a
// composite whose revision argument must be distinguishably ABSENT (null), which
// is what applies the CLI's own `@` default instead of one this layer invented,
// and `show` and `evolog` additionally carry an optional scalar limit.
//
// The two nested shapes — a `Change` and a `[FileChange]` — are decoded through
// `change.dart`'s and `status.dart`'s shared table mappers, never a second
// spelling: a field added to either must reach every payload that carries it.

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_show` with the raw `u64` handle and a `ShowRequest` request
/// buffer, and return the FlatBuffers `Envelope` bytes.
///
/// A `null` [revset] is the wire form of "the user did not supply it", which
/// applies the CLI's own default `@` — the working-copy commit the pre-verb
/// snapshot has just brought up to date (Story 9.26). [revset] is an EXPRESSION, not a change id: the
/// CLI unions its revsets, so entries are per COMMIT — a revset naming two commits
/// of ONE divergent change yields two entries with the same `Change.id`. A BARE
/// divergent change-id symbol does NOT get that far: jj-lib's own `SymbolResolver`
/// refuses it (`RevsetResolutionError::DivergentChangeId`), exactly as
/// `jj show <divergent-id>` fails in the CLI, and it surfaces as
/// `jj.revset_resolution_error`. Union the two COMMIT hexes to address both.
///
/// [limit] is a ZANSHIN-SIDE addition — `jj show` has no `-n/--limit`, because it
/// streams to a pager where this builds ONE buffer whose every entry pays a
/// merged-parent tree diff plus a per-parent copy-record stream. It is sent as a
/// presence-flag pair because `limit: 0` is a MEANINGFUL value (an empty result,
/// not an error), it is applied in RAW REVSET order, and `null` is the CLI-parity
/// default: unbounded. It SATURATES at [_maxWireLimit] and refuses a NEGATIVE
/// value, for the reasons spelled out on [zanshinEvolog].
Uint8List zanshinShow(int rawHandle, {String? revset, int? limit}) {
  rejectInteriorNul(revset, 'revset');
  if (limit != null && limit < 0) {
    throw ArgumentError.value(limit, 'limit', 'must not be negative');
  }
  final Uint8List request = fbs.ShowRequestObjectBuilder(
    kind: fbs.RequestKind.Show,
    revset: revset,
    limit: limit == null ? 0 : (limit > _maxWireLimit ? _maxWireLimit : limit),
    hasLimit: limit != null,
  ).toBytes();
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
    kind: fbs.RequestKind.Evolog,
    revset: revset,
    limit: limit == null ? 0 : (limit > _maxWireLimit ? _maxWireLimit : limit),
    hasLimit: limit != null,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_evolog(rawHandle, ptr, len));
}

/// The largest value the `ShowRequest.limit` / `EvologRequest.limit` `uint` fields
/// can carry.
///
/// Above this a limit is a "give me everything" request in every practical sense
/// — no evolution and no revset has four billion entries — so it saturates rather
/// than wraps.
const _maxWireLimit = 0xFFFFFFFF;

/// Which currency ONE side of [zanshinInterdiff] is written in (mirrors
/// `zanshin_jj::RevisionRef`, and the schema's `RevisionRef` union).
///
/// Modelled as a sealed class so an arm without an id is unrepresentable and a
/// `switch` over the two is exhaustive at compile time — the same reason
/// `BookmarkKind` is one. [zanshinInterdiff] is the ONLY consumer; every other
/// verb keeps its own parameter currency.
sealed class RevisionRef {
  const RevisionRef(this.id);

  /// The prefix, in the currency the concrete arm names.
  final String id;
}

/// A jj reverse-hex CHANGE-ID prefix — the house currency for a single revision.
///
/// Resolves to the one VISIBLE commit carrying it; an unknown, malformed,
/// only-hidden or DIVERGENT prefix is refused (`jj.change_not_found`) rather than
/// guessed. Use a [CommitIdRef] to reach a hidden commit.
final class ChangeIdRef extends RevisionRef {
  const ChangeIdRef(super.id);
}

/// A commit-id HEX prefix, resolved through jj's index.
///
/// That lookup is visibility-BLIND, so a HIDDEN commit resolves —
/// [EvologEntry.predecessorCommitIds] entries among them, which is what lets
/// `evolog` and `interdiff` compose into a version-to-version diff. An ambiguous
/// prefix is refused (`jj.revset_resolution_error`), never guessed; an empty or
/// non-hex value is `jj.invalid_input`; valid hex matching nothing is
/// `jj.change_not_found`. It is a CURRENCY, not a revset symbol resolver: there is
/// no bookmark, tag or change-id fallback.
final class CommitIdRef extends RevisionRef {
  const CommitIdRef(super.id);
}

/// BOTH union slots [ref] occupies — its discriminant and its value table — or
/// `(null, null)` for an ABSENT side.
///
/// The two are returned together, from ONE `switch`, because they must be written
/// together or not at all: the FlatBuffers verifier refuses a half-set union
/// outright, and a MIS-PAIRED one (a `ChangeIdRef` discriminant over a
/// `CommitIdRef` value) would verify and silently route the id to the wrong Rust
/// resolver. Deriving both from a single match makes that unrepresentable.
(fbs.RevisionRefTypeId?, Object?) _revisionRefSlots(RevisionRef? ref) => switch (ref) {
  null => (null, null),
  ChangeIdRef(:final String id) => (
    fbs.RevisionRefTypeId.ChangeIdRef,
    fbs.ChangeIdRefObjectBuilder(id: id),
  ),
  CommitIdRef(:final String id) => (
    fbs.RevisionRefTypeId.CommitIdRef,
    fbs.CommitIdRefObjectBuilder(id: id),
  ),
};

/// Call `zanshin_interdiff` with the raw `u64` handle and an `InterdiffRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// Unlike [zanshinShow], [from] and [to] are single revisions rather than revsets,
/// each written in one of the two [RevisionRef] currencies. Both inherit the CLI
/// `resolve_single_rev`'s ambiguity REFUSAL — an ambiguous revision is rejected,
/// never resolved to one of its candidates. A [ChangeIdRef] reaches only the
/// currently VISIBLE commit of a change; a [CommitIdRef] resolves through the
/// index and therefore reaches a HIDDEN one, which is how
/// [EvologEntry.predecessorCommitIds] become addressable. A revset expression is
/// still unaddressable on either arm. An
/// absent side is `@`, but omitting BOTH is refused with `jj.invalid_input`
/// (the CLI's `ArgGroup … required(true)`). [paths] entries are repo-relative
/// PREFIXES; an empty list means all paths.
Uint8List zanshinInterdiff(
  int rawHandle, {
  RevisionRef? from,
  RevisionRef? to,
  List<String> paths = const <String>[],
}) {
  rejectInteriorNul(from?.id, 'from');
  rejectInteriorNul(to?.id, 'to');
  rejectInteriorNuls(paths, 'paths');
  final Uint8List request = interdiffRequestBytes(from: from, to: to, paths: paths);
  return callWithRequest(request, (ptr, len) => zanshin_interdiff(rawHandle, ptr, len));
}

/// Build the `InterdiffRequest` buffer [zanshinInterdiff] sends.
///
/// This is the PRODUCTION builder — [zanshinInterdiff] calls it — kept as its own
/// public function so a test can read the WIRE SHAPE back: the two union fields
/// are the only request fields whose discriminant and value must be written
/// together (a half-written pair is refused outright by the Rust verifier), and a
/// call through [zanshinInterdiff] hands the bytes straight to the cdylib, leaving
/// a test nothing to inspect. The interior-NUL guards stay on [zanshinInterdiff],
/// which is the adapter boundary they belong to.
Uint8List interdiffRequestBytes({
  RevisionRef? from,
  RevisionRef? to,
  List<String> paths = const <String>[],
}) {
  final (fbs.RevisionRefTypeId? fromType, Object? fromValue) = _revisionRefSlots(from);
  final (fbs.RevisionRefTypeId? toType, Object? toValue) = _revisionRefSlots(to);
  return fbs.InterdiffRequestObjectBuilder(
    kind: fbs.RequestKind.Interdiff,
    fromType: fromType,
    from: fromValue,
    toType: toType,
    to: toValue,
    paths: paths,
  ).toBytes();
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// One revision as `show` presents it (mirrors `zanshin_jj::ShowEntry`).
final class ShowEntry {
  const ShowEntry({
    required this.change,
    required this.fileChanges,
    this.parentTreeIds = const [],
    this.treeIds = const [],
  });

  /// Full metadata for the revision — the same [Change] `getChange` returns for
  /// this commit.
  final Change change;

  /// Per-path changes relative to the MERGED parent tree, in jj's own diff order.
  /// For a merge commit that is only what the merge itself changed; for the root
  /// commit it is empty. `renamed`/`copied` entries CAN appear here, unlike in
  /// [zanshinInterdiff]'s result.
  final List<FileChange> fileChanges;

  /// The tree [fileChanges] diff against — the merged parent tree that `split`,
  /// `squash` and `commit` diff against too — as hex tree ids in order (one for
  /// a resolved tree, several for a conflicted merge of parents). It is the
  /// `left` a hunk selection is made against (`RepoHandle.selectTree`, Story
  /// 9.50).
  final List<String> parentTreeIds;

  /// The revision's OWN tree as hex tree ids in order (Story 9.17) — the
  /// `left` of a selection made against it as `selectTree(from:)`, for
  /// `RepoHandle.diffedit`'s `from` / `to` form.
  final List<String> treeIds;
}

/// What `interdiff` reports (mirrors `zanshin_jj::InterdiffView`).
final class InterdiffView {
  const InterdiffView({required this.fileChanges, required this.baseHasConflicts, this.warnings = const []});

  /// Per-path changes `to` makes that `from` does not, in jj's own diff order. No
  /// `renamed`/`copied` entry is ever produced — `interdiff` passes no copy
  /// records, the CLI's own asymmetry with [zanshinShow].
  final List<FileChange> fileChanges;

  /// Whether the REBASED `from` tree — the LEFT side of the diff, which exists
  /// only in memory — is conflicted. A ZANSHIN-SIDE addition: the CLI signals
  /// this by rendering conflict markers in the patch TEXT (Epic 5's surface
  /// here), so without it a caller sees a plausible [fileChanges] list derived
  /// from a conflicted rebase with no way to tell.
  ///
  /// True whatever the cause — the 3-way merge behind the rebase left the
  /// conflict, or its fast path (the two revisions already share parents)
  /// returned `from`'s own already-conflicted tree. `to`'s own conflict state is
  /// NOT reported here; that is `Change.conflict`'s job, via [zanshinShow] or
  /// `getChange`. It describes the TREE, not the filtered result: a `paths`
  /// filter matching nothing still leaves it set.
  final bool baseHasConflicts;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none.
  final List<ZanshinWarning> warnings;
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
  /// HIDDEN commits, so they are addressable by [zanshinInterdiff] only as a
  /// [CommitIdRef] — the arm whose index lookup ignores visibility. Passing one as
  /// a [ChangeIdRef] is refused: a commit hex is not a reverse-hex change id.
  final List<String> predecessorCommitIds;

  /// The operation that created or rewrote this commit, or `null` for an entry
  /// the walk emitted from its flush tail — it reached an operation storing no
  /// predecessors and could go no further. That `null` is the only signal that an
  /// evolution may be TRUNCATED; the CLI truncates silently.
  final String? operationId;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `ShowView` `Envelope` buffer into a `List<ShowEntry>` that also
/// carries the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.show`.
@visibleForTesting
WarnedList<ShowEntry> decodeShowViewEnvelope(Uint8List bytes) => _decodeShowViewEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<ShowEntry> decodeShowViewEnvelopeInternal(Uint8List bytes) => _decodeShowViewEnvelope(bytes);

WarnedList<ShowEntry> _decodeShowViewEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.ShowView) {
    throw ZanshinFfiException('ffi.unknown', 'expected ShowView payload, got ${env.dataType}');
  }
  return WarnedList(payload.entries?.map(_mapShowEntry).toList() ?? const [], decodeEnvelopeWarningsInternal(env));
}

ShowEntry _mapShowEntry(fbs.ShowEntry e) => ShowEntry(
  change: _requireChange(e.change, 'ShowEntry'),
  fileChanges: e.fileChanges?.map(mapFileChangeTable).toList() ?? const [],
  parentTreeIds: e.parentTreeIds ?? const [],
  treeIds: e.treeIds ?? const [],
);

/// Decode an `EvologView` `Envelope` buffer into a `List<EvologEntry>` that also
/// carries the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.evolog`.
@visibleForTesting
WarnedList<EvologEntry> decodeEvologViewEnvelope(Uint8List bytes) => _decodeEvologViewEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<EvologEntry> decodeEvologViewEnvelopeInternal(Uint8List bytes) => _decodeEvologViewEnvelope(bytes);

WarnedList<EvologEntry> _decodeEvologViewEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.EvologView) {
    throw ZanshinFfiException('ffi.unknown', 'expected EvologView payload, got ${env.dataType}');
  }
  return WarnedList(payload.entries?.map(_mapEvologEntry).toList() ?? const [], decodeEnvelopeWarningsInternal(env));
}

EvologEntry _mapEvologEntry(fbs.EvologEntry e) => EvologEntry(
  change: _requireChange(e.change, 'EvologEntry'),
  predecessorCommitIds: e.predecessorCommitIds?.toList() ?? const [],
  // Null-for-absence, not a sentinel: an absent operation id means the walk
  // reached its flush tail, i.e. the evolution may be truncated.
  operationId: e.operationId,
);

/// Decode an `InterdiffView` `Envelope` buffer into an [InterdiffView].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.interdiff`.
@visibleForTesting
InterdiffView decodeInterdiffViewEnvelope(Uint8List bytes) => _decodeInterdiffViewEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
InterdiffView decodeInterdiffViewEnvelopeInternal(Uint8List bytes) => _decodeInterdiffViewEnvelope(bytes);

InterdiffView _decodeInterdiffViewEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.InterdiffView) {
    throw ZanshinFfiException('ffi.unknown', 'expected InterdiffView payload, got ${env.dataType}');
  }
  return InterdiffView(
    fileChanges: payload.fileChanges?.map(mapFileChangeTable).toList() ?? const [],
    baseHasConflicts: payload.baseHasConflicts,
    warnings: decodeEnvelopeWarningsInternal(env),
  );
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
    throw decodeEnvelopeErrorInternal(env);
  }
  return env;
}
