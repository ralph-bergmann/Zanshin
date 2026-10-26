// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 4.10's op-pinned batch content lookup:
// the adapter (commitContents), the model and the decoder. `dart:ffi` stays
// inside `ffi/` — only the worker isolate calls the adapter.
//
// The call is the continuation of the topology call's `jj log`, pinned to the
// operation that call returned: it runs no pre-verb snapshot and records no
// warning, so its envelope carries neither — the result's `warnings` is always
// empty (Story 9.32's "every result exposes warnings" convention).

// ── FFI adapter ──────────────────────────────────────────────────────────────

/// Call `zanshin_commit_contents` with the raw `u64` handle and a
/// `CommitContentsRequest` request buffer, and return the FlatBuffers
/// `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). [operationId], every entry of [extraOperationIds] and
/// every entry of [commitIds] are FULL hex ids; the answer comes back in
/// [commitIds]' order. [extraOperationIds] is the topology's
/// `extraOperationIds` — the operations its revset's `at_operation()`s brought
/// in; with any, the ids are checked and loaded against the pinned index merged
/// with theirs.
Uint8List zanshinCommitContents(
  int rawHandle, {
  required String operationId,
  required List<String> commitIds,
  List<String> extraOperationIds = const [],
}) {
  rejectInteriorNul(operationId, 'operationId');
  rejectInteriorNuls(extraOperationIds, 'extraOperationIds');
  rejectInteriorNuls(commitIds, 'commitIds');
  final Uint8List request = fbs.CommitContentsRequestObjectBuilder(
    kind: fbs.RequestKind.CommitContents,
    operationId: operationId,
    commitIds: commitIds,
    extraOperationIds: extraOperationIds,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_commit_contents(rawHandle, ptr, len));
}

// ── Dart model ───────────────────────────────────────────────────────────────

/// The object half of one `jj log` row (mirrors `zanshin_jj::CommitContent`):
/// what only the loaded commit answers.
///
/// Commit-intrinsic — a commit is content-addressed — so a caller may cache it
/// by [commitId] across operations. The view half (change id, refs, flags)
/// arrives with the graph topology.
final class CommitContent {
  const CommitContent({
    required this.commitId,
    required this.authorName,
    required this.authorEmail,
    required this.committerTimestampMillis,
    required this.committerTzOffsetMinutes,
    required this.description,
    required this.conflict,
    required this.empty,
  });

  /// The commit's full hex id (lowercase), so an entry describes itself.
  final String commitId;

  /// Author name; may be empty (jj allows it).
  final String authorName;

  /// Author email; may be empty (jj allows it).
  final String authorEmail;

  /// The COMMITTER timestamp — what `jj log` shows — in millis since the Unix
  /// epoch.
  final int committerTimestampMillis;

  /// The committer timestamp's offset, minutes east of UTC.
  final int committerTzOffsetMinutes;

  /// The FULL description; `''` when it is empty. A card derives the first line.
  final String description;

  /// The commit's tree has unresolved conflicts.
  final bool conflict;

  /// The tree equals the merged parent trees (description is not considered);
  /// `null` when jj-lib cannot tell — a merge whose common ancestors are outside
  /// the index it is read against (where `jj log` prints an inline template
  /// error).
  final bool? empty;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `CommitContents` `Envelope` buffer into the entries, in request
/// order, plus the call's warnings (always empty for this verb).
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.commitContents`.
@visibleForTesting
WarnedList<CommitContent> decodeCommitContentsEnvelope(Uint8List bytes) => _decodeCommitContentsEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<CommitContent> decodeCommitContentsEnvelopeInternal(Uint8List bytes) => _decodeCommitContentsEnvelope(bytes);

WarnedList<CommitContent> _decodeCommitContentsEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.CommitContents) {
    throw ZanshinFfiException('ffi.unknown', 'expected CommitContents payload, got ${env.dataType}');
  }
  final List<fbs.CommitContent>? contents = payload.contents;
  if (contents == null) {
    // Rust always writes the vector, an empty list included — an absent one is a malformed
    // buffer, not a modellable state, so no `?? const []`.
    throw const ZanshinFfiException('ffi.unknown', 'CommitContents is missing its contents');
  }
  return WarnedList(contents.map(_mapCommitContent).toList(), decodeEnvelopeWarningsInternal(env));
}

CommitContent _mapCommitContent(fbs.CommitContent c) => CommitContent(
  commitId: _required(c.commitId, 'commit_id'),
  authorName: _required(c.authorName, 'author_name'),
  authorEmail: _required(c.authorEmail, 'author_email'),
  committerTimestampMillis: c.committerTimestampMillis,
  committerTzOffsetMinutes: c.committerTzOffsetMinutes,
  description: _required(c.description, 'description'),
  conflict: c.conflict,
  empty: c.emptyUnknown ? null : c.empty,
);

/// Rust always writes every string of a `CommitContent` (an empty one as `""`),
/// so an absent one is a malformed buffer, not a modellable state — no `?? ''`.
String _required(String? value, String field) {
  if (value == null) {
    throw ZanshinFfiException('ffi.unknown', 'CommitContent is missing its $field');
  }
  return value;
}
