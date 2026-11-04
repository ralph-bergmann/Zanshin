// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal, decodeErrorHintsInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.25's graph search backend: the two
// op-pinned searches (revsetCounts, findChanges) — adapters, models and
// decoders — and the structured revset error detail every revset parse or
// resolution error of the topology call and of these two carries. `dart:ffi`
// stays inside `ffi/` — only the worker isolate calls the adapters.
//
// Both reads are pinned to the operation the shown topology was read at: they
// run no pre-verb snapshot, so their envelopes carry no precondition and
// `RepoHandle.lastPrecondition` is untouched. They do carry warnings (the
// parse diagnostics).

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_revset_counts` with the raw `u64` handle and a
/// `RevsetCountsRequest` request buffer, and return the FlatBuffers
/// `Envelope` bytes. Only the worker isolate calls this.
Uint8List zanshinRevsetCounts(
  int rawHandle, {
  required String operationId,
  required List<String> expressions,
  required int cap,
}) {
  rejectInteriorNul(operationId, 'operationId');
  rejectInteriorNuls(expressions, 'expressions');
  final Uint8List request = fbs.RevsetCountsRequestObjectBuilder(
    kind: fbs.RequestKind.RevsetCounts,
    operationId: operationId,
    expressions: expressions,
    cap: cap,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_revset_counts(rawHandle, ptr, len));
}

/// Call `zanshin_find_changes` with the raw `u64` handle and a
/// `FindChangesRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes. Only the worker isolate calls this.
Uint8List zanshinFindChanges(
  int rawHandle, {
  required String operationId,
  required String expression,
  required int limit,
  required String shortPrefixes,
}) {
  rejectInteriorNul(operationId, 'operationId');
  rejectInteriorNul(expression, 'expression');
  rejectInteriorNul(shortPrefixes, 'shortPrefixes');
  final Uint8List request = fbs.FindChangesRequestObjectBuilder(
    kind: fbs.RequestKind.FindChanges,
    operationId: operationId,
    expression: expression,
    limit: limit,
    shortPrefixes: shortPrefixes,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_find_changes(rawHandle, ptr, len));
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// Which jj-lib revset failure a [RevsetErrorDetail] describes (mirrors
/// `zanshin_jj::RevsetErrorKind`): jj-lib's parse kinds, then its resolution
/// kinds.
enum RevsetErrorKind {
  syntaxError,
  notPostfixOperator,
  notInfixOperator,
  noSuchFunction,
  invalidFunctionArguments,
  fsPathWithoutWorkspace,
  workingCopyWithoutWorkspace,
  redefinedFunctionParameter,
  expression,
  inAliasExpansion,
  inParameterExpansion,
  recursiveAlias,
  noSuchRevision,
  workspaceMissingWorkingCopy,
  emptyString,
  ambiguousCommitIdPrefix,
  ambiguousChangeIdPrefix,
  divergentChangeId,
  conflictedRef,
  backend,
  other,
}

/// Where a revset parse error points in the caller's expression, in BYTES of
/// its UTF-8 text.
final class RevsetSpan {
  const RevsetSpan({required this.offset, required this.length});

  /// Byte offset of the span's start.
  final int offset;

  /// Byte length; `0` for a position, `null` when it is unknown: the span
  /// crosses lines, or jj-lib's render cannot tell an empty span from a
  /// one-char one.
  final int? length;
}

/// The structured form of a revset parse or resolution error (mirrors
/// `zanshin_jj::RevsetErrorDetail`) — what the UI needs to point at the
/// failing part of an expression without parsing the message. The CLI's hints
/// are the exception's `hints`.
final class RevsetErrorDetail {
  const RevsetErrorDetail({
    required this.kind,
    required this.span,
    required this.symbol,
    required this.candidates,
    this.message,
  });

  /// The top-level error's kind (inside an alias: the alias expansion).
  final RevsetErrorKind kind;

  /// The top-level error's span in the call's primary expression (the
  /// topology's `revset`, a search's `expression`); `null` for a resolution
  /// error and for an error in any other text of the call (`prioritize`,
  /// `shortPrefixes`, an anchor).
  final RevsetSpan? span;

  /// The function, revision, alias, operator or prefix the error names, or
  /// `null`.
  final String? symbol;

  /// jj-lib's similar names (or the suggested operator); empty when none.
  final List<String> candidates;

  /// One sentence for a proportional-font UI, built by the backend: a parse
  /// error reads `Syntax error at 5: expected …` (or `Error at 1: …`; the
  /// 1-based char column is dropped without a span), a resolution error is
  /// jj-lib's one-line text; `null` when absent.
  final String? message;
}

/// One expression's entry in [RevsetCounts].
final class RevsetCount {
  const RevsetCount({required this.n, required this.capped, required this.error});

  /// How many commits the revset denotes, at most the call's `cap`; `0` when
  /// [error] is set.
  final int n;

  /// The revset denotes more than `cap` commits.
  final bool capped;

  /// This expression's own parse or resolution error (`jj.revset_parse_error` /
  /// `jj.revset_resolution_error`, with `hints` and `revsetError`), or `null`.
  final ZanshinFfiException? error;
}

/// `RepoHandle.revsetCounts`' answer: one [RevsetCount] per expression, in
/// request order, plus the call's warnings.
typedef RevsetCounts = WarnedList<RevsetCount>;

/// One change `RepoHandle.findChanges` found.
final class FoundChange {
  const FoundChange({
    required this.commitId,
    required this.changeId,
    required this.commitPrefixLen,
    required this.changePrefixLen,
  });

  /// The commit's full hex id.
  final String commitId;

  /// The commit's change id (jj reverse hex).
  final String changeId;

  /// The shortest unique commit id prefix length within the call's
  /// `shortPrefixes`.
  final int commitPrefixLen;

  /// The shortest unique change id prefix length within the call's
  /// `shortPrefixes`.
  final int changePrefixLen;
}

/// `RepoHandle.findChanges`' answer.
final class FoundChanges {
  const FoundChanges({required this.entries, required this.truncated, required this.warnings});

  /// At most `limit` entries, in the revset's iteration order
  /// (`jj log --no-graph`'s).
  final List<FoundChange> entries;

  /// The revset denotes more than `limit` commits.
  final bool truncated;

  /// The call's warnings, in the CLI's print order.
  final List<ZanshinWarning> warnings;
}

// ── Decoders ─────────────────────────────────────────────────────────────────

/// Decode an `FfiError`'s `revset` table: absent reads as `null`.
RevsetErrorDetail? decodeRevsetErrorDetailInternal(fbs.RevsetErrorDetail? detail) {
  if (detail == null) {
    return null;
  }
  final fbs.RevsetSpan? span = detail.span;
  final List<String>? candidates = detail.candidates;
  return RevsetErrorDetail(
    kind: _kind(detail.kind),
    span: span == null ? null : RevsetSpan(offset: span.offset, length: span.length?.value),
    symbol: detail.symbol,
    candidates: candidates == null || candidates.isEmpty ? const [] : List.unmodifiable(candidates),
    message: detail.message,
  );
}

RevsetErrorKind _kind(fbs.RevsetErrorKind kind) => switch (kind) {
  fbs.RevsetErrorKind.SyntaxError => RevsetErrorKind.syntaxError,
  fbs.RevsetErrorKind.NotPostfixOperator => RevsetErrorKind.notPostfixOperator,
  fbs.RevsetErrorKind.NotInfixOperator => RevsetErrorKind.notInfixOperator,
  fbs.RevsetErrorKind.NoSuchFunction => RevsetErrorKind.noSuchFunction,
  fbs.RevsetErrorKind.InvalidFunctionArguments => RevsetErrorKind.invalidFunctionArguments,
  fbs.RevsetErrorKind.FsPathWithoutWorkspace => RevsetErrorKind.fsPathWithoutWorkspace,
  fbs.RevsetErrorKind.WorkingCopyWithoutWorkspace => RevsetErrorKind.workingCopyWithoutWorkspace,
  fbs.RevsetErrorKind.RedefinedFunctionParameter => RevsetErrorKind.redefinedFunctionParameter,
  fbs.RevsetErrorKind.Expression => RevsetErrorKind.expression,
  fbs.RevsetErrorKind.InAliasExpansion => RevsetErrorKind.inAliasExpansion,
  fbs.RevsetErrorKind.InParameterExpansion => RevsetErrorKind.inParameterExpansion,
  fbs.RevsetErrorKind.RecursiveAlias => RevsetErrorKind.recursiveAlias,
  fbs.RevsetErrorKind.NoSuchRevision => RevsetErrorKind.noSuchRevision,
  fbs.RevsetErrorKind.WorkspaceMissingWorkingCopy => RevsetErrorKind.workspaceMissingWorkingCopy,
  fbs.RevsetErrorKind.EmptyString => RevsetErrorKind.emptyString,
  fbs.RevsetErrorKind.AmbiguousCommitIdPrefix => RevsetErrorKind.ambiguousCommitIdPrefix,
  fbs.RevsetErrorKind.AmbiguousChangeIdPrefix => RevsetErrorKind.ambiguousChangeIdPrefix,
  fbs.RevsetErrorKind.DivergentChangeId => RevsetErrorKind.divergentChangeId,
  fbs.RevsetErrorKind.ConflictedRef => RevsetErrorKind.conflictedRef,
  fbs.RevsetErrorKind.Backend => RevsetErrorKind.backend,
  fbs.RevsetErrorKind.Other => RevsetErrorKind.other,
};

/// Decode a `RevsetCounts` `Envelope` buffer. Exposed for decode-contract
/// tests with synthetic buffers; production calls go through
/// `ZanshinWorker.revsetCounts`.
@visibleForTesting
RevsetCounts decodeRevsetCountsEnvelope(Uint8List bytes) => decodeRevsetCountsEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
RevsetCounts decodeRevsetCountsEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.RevsetCounts) {
    throw ZanshinFfiException('ffi.unknown', 'expected RevsetCounts payload, got ${env.dataType}');
  }
  final List<fbs.RevsetCount>? counts = payload.counts;
  if (counts == null) {
    // Rust always writes the vector, an empty list included.
    throw const ZanshinFfiException('ffi.unknown', 'RevsetCounts is missing its counts');
  }
  return WarnedList(counts.map(_count).toList(), decodeEnvelopeWarningsInternal(env));
}

RevsetCount _count(fbs.RevsetCount count) {
  final fbs.FfiError? error = count.error;
  return RevsetCount(
    n: count.n,
    capped: count.capped,
    error: error == null
        ? null
        : ZanshinFfiException.withReport(
            error.code ?? (throw const ZanshinFfiException('ffi.unknown', 'a count error is missing its code')),
            error.context,
            precondition: null,
            warnings: const [],
            hints: decodeErrorHintsInternal(error),
            revsetError: decodeRevsetErrorDetailInternal(error.revset),
          ),
  );
}

/// Decode a `FoundChanges` `Envelope` buffer. Exposed for decode-contract
/// tests with synthetic buffers; production calls go through
/// `ZanshinWorker.findChanges`.
@visibleForTesting
FoundChanges decodeFoundChangesEnvelope(Uint8List bytes) => decodeFoundChangesEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
FoundChanges decodeFoundChangesEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.FoundChanges) {
    throw ZanshinFfiException('ffi.unknown', 'expected FoundChanges payload, got ${env.dataType}');
  }
  final List<fbs.FoundChange>? entries = payload.entries;
  if (entries == null) {
    // Rust always writes the vector, an empty list included.
    throw const ZanshinFfiException('ffi.unknown', 'FoundChanges is missing its entries');
  }
  return FoundChanges(
    entries: List.unmodifiable(entries.map(_found)),
    truncated: payload.truncated,
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

FoundChange _found(fbs.FoundChange entry) => FoundChange(
  commitId: entry.commitId ?? (throw const ZanshinFfiException('ffi.unknown', 'FoundChange is missing its commit_id')),
  changeId: entry.changeId ?? (throw const ZanshinFfiException('ffi.unknown', 'FoundChange is missing its change_id')),
  commitPrefixLen: entry.commitPrefixLen,
  changePrefixLen: entry.changePrefixLen,
);
