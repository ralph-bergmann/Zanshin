// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'mutate.dart' show MutationResult, decodeMutationResultInternal;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.9's three calls: the adapters
// (metaedit / duplicate / fix), the `FixResult` / `FixToolStderr` models and
// the fix decoder. `metaedit` and `duplicate` answer the shared
// `MutationResult`, decoded through `mutate.dart`'s one spelling. `dart:ffi`
// stays inside `ffi/` — only the worker isolate calls these adapters.

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_metaedit` with the raw `u64` handle and a `MetaeditRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.9) —
/// the CLI's `jj metaedit`.
///
/// [revisions] are change ids (empty = `@`); a `null` [message] stays ABSENT
/// on the wire (no `-m`), a list is the `-m` paragraphs — an empty one joins to
/// `""`, i.e. `-m ""`, clearing every target's description. A
/// `null` [author] / [authorTimestamp] is the flag not given.
Uint8List zanshinMetaedit(
  int rawHandle, {
  List<String> revisions = const [],
  bool updateChangeId = false,
  List<String>? message,
  bool updateAuthorTimestamp = false,
  bool updateAuthor = false,
  String? author,
  String? authorTimestamp,
  bool forceRewrite = false,
}) {
  rejectInteriorNuls(revisions, 'revisions');
  rejectInteriorNuls(message ?? const [], 'message');
  rejectInteriorNuls([?author], 'author');
  rejectInteriorNuls([?authorTimestamp], 'authorTimestamp');
  final Uint8List request = fbs.MetaeditRequestObjectBuilder(
    kind: fbs.RequestKind.Metaedit,
    revisions: revisions,
    updateChangeId: updateChangeId,
    message: message,
    updateAuthorTimestamp: updateAuthorTimestamp,
    updateAuthor: updateAuthor,
    author: author,
    authorTimestamp: authorTimestamp,
    forceRewrite: forceRewrite,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_metaedit(rawHandle, ptr, len));
}

/// Call `zanshin_duplicate` with the raw `u64` handle and a `DuplicateRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.9) —
/// the CLI's `jj duplicate`.
///
/// [revisions] are change ids (empty = `@`); [onto] / [insertAfter] /
/// [insertBefore] are `-o` / `-A` / `-B` (empty = the flag not given; [onto]
/// excludes the other two).
Uint8List zanshinDuplicate(
  int rawHandle, {
  List<String> revisions = const [],
  List<String> onto = const [],
  List<String> insertAfter = const [],
  List<String> insertBefore = const [],
}) {
  rejectInteriorNuls(revisions, 'revisions');
  rejectInteriorNuls(onto, 'onto');
  rejectInteriorNuls(insertAfter, 'insertAfter');
  rejectInteriorNuls(insertBefore, 'insertBefore');
  final Uint8List request = fbs.DuplicateRequestObjectBuilder(
    kind: fbs.RequestKind.Duplicate,
    revisions: revisions,
    onto: onto,
    insertAfter: insertAfter,
    insertBefore: insertBefore,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_duplicate(rawHandle, ptr, len));
}

/// Call `zanshin_fix` with the raw `u64` handle and a `FixRequest` request
/// buffer, and return the FlatBuffers `Envelope` bytes (Story 9.9) — the CLI's
/// `jj fix`.
///
/// [source] are change ids (empty = the `revsets.fix` setting); [paths] are
/// repo-relative prefixes (empty = every path). [cancelToken] is `0` (not
/// cancellable) or a token from `zanshinNetworkToken`: `zanshinNetworkCancel`
/// kills the running tool's process group and the call refuses `jj.cancelled`
/// with no operation.
Uint8List zanshinFix(
  int rawHandle, {
  List<String> source = const [],
  List<String> paths = const [],
  bool includeUnchangedFiles = false,
  bool allLines = false,
  int cancelToken = 0,
}) {
  rejectInteriorNuls(source, 'source');
  rejectInteriorNuls(paths, 'paths');
  final Uint8List request = fbs.FixRequestObjectBuilder(
    kind: fbs.RequestKind.Fix,
    source: source,
    paths: paths,
    includeUnchangedFiles: includeUnchangedFiles,
    allLines: allLines,
    cancelToken: cancelToken,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_fix(rawHandle, ptr, len));
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// What one `jj fix` tool run wrote to stderr (mirrors
/// `zanshin_jj::FixToolStderr`) — the CLI copies it to the terminal under
/// `<path>:`.
final class FixToolStderr {
  const FixToolStderr({required this.path, required this.stderr});

  /// The file the tool ran on, as the CLI renders it from the workspace root.
  final String path;

  /// The tool's stderr, lossy UTF-8.
  final String stderr;
}

/// Outcome of a successful `fix` (mirrors `zanshin_jj::FixResult`).
final class FixResult {
  const FixResult({
    required this.mutation,
    required this.numFixedCommits,
    required this.numCheckedCommits,
    this.toolStderr = const [],
    this.warnings = const [],
  });

  /// The shared mutation contract; its `newOpId` is the pre-call head when
  /// nothing was fixed.
  final MutationResult mutation;

  /// Commits rewritten because a tool changed a file.
  final int numFixedCommits;

  /// Commits visited: every source and descendant, whether or not a file of
  /// it matched a tool's patterns.
  final int numCheckedCommits;

  /// What the tools wrote to stderr, sorted by path (then text).
  final List<FixToolStderr> toolStderr;

  /// The call's warnings (`jj.fix_tool_failed`, `jj.fix_tool_start_failed`,
  /// `jj.paths_unmatched`, `jj.config_deprecated`, …); empty when there were
  /// none. The nested [mutation] carries none of its own.
  final List<ZanshinWarning> warnings;
}

// ── Decoders ─────────────────────────────────────────────────────────────────

/// Decode a `FixResult` `Envelope` buffer into a [FixResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.fix`.
@visibleForTesting
FixResult decodeFixResultEnvelope(Uint8List bytes) => decodeFixResultEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
FixResult decodeFixResultEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.FixResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected FixResult payload, got ${env.dataType}');
  }
  return FixResult(
    mutation: decodeMutationResultInternal(payload.mutation),
    numFixedCommits: payload.numFixedCommits,
    numCheckedCommits: payload.numCheckedCommits,
    toolStderr: [
      for (final fbs.FixToolStderr entry in payload.toolStderr ?? const [])
        FixToolStderr(
          path: entry.path ?? _missing('tool_stderr.path'),
          stderr: entry.stderr ?? _missing('tool_stderr.stderr'),
        ),
    ],
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

// Rust always writes both strings, so a missing one is a malformed buffer, not
// a modellable state — refused rather than guessed.
Never _missing(String field) => throw ZanshinFfiException('ffi.unknown', 'FixResult payload is missing its $field');
