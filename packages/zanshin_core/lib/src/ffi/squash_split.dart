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

// This file owns the Dart half of Story 9.15's three calls: the adapters
// (squash / squashPlan / split), the `SquashPlan` and `SplitResult` models and
// their decoders. `squash` answers the shared `MutationResult`, decoded through
// `mutate.dart`'s one spelling. `dart:ffi` stays inside `ffi/` — only the
// worker isolate calls these adapters.

// ── Request-buffer helpers ───────────────────────────────────────────────────

/// The `SquashRequest` both `zanshin_squash` and `zanshin_squash_plan` read —
/// one field per `jj squash` flag. A `null` [message] stays ABSENT on the wire
/// (no `-m`).
Uint8List _squashRequest({
  required String? revision,
  required List<String> from,
  required String? into,
  required List<String> paths,
  required List<String>? message,
  required bool useDestinationMessage,
  required bool keepEmptied,
}) {
  rejectInteriorNul(revision, 'revision');
  rejectInteriorNuls(from, 'from');
  rejectInteriorNul(into, 'into');
  rejectInteriorNuls(paths, 'paths');
  rejectInteriorNuls(message ?? const [], 'message');
  return fbs.SquashRequestObjectBuilder(
    kind: fbs.RequestKind.Squash,
    revision: revision,
    from: from,
    into: into,
    paths: paths,
    message: message,
    useDestinationMessage: useDestinationMessage,
    keepEmptied: keepEmptied,
  ).toBytes();
}

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_squash` with the raw `u64` handle and a `SquashRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.15) —
/// the CLI's `jj squash`, paths only.
///
/// [revision] is `-r` (`null` with [from]/[into] unset: `@` into its one
/// parent); [from] (`--from`, empty with [into] set: `@`) and [into]
/// (`--into`, `null` with [from] set: `@`) conflict with it. [paths] are
/// repo-relative PREFIXES (empty = every path). [message] is the repeatable
/// `-m` — `null` is no `-m`, where the CLI's editor case writes the buffer
/// saved unchanged (ask with [zanshinSquashPlan] first).
/// [useDestinationMessage] is `-u`, [keepEmptied] is `-k`.
Uint8List zanshinSquash(
  int rawHandle, {
  String? revision,
  List<String> from = const [],
  String? into,
  List<String> paths = const [],
  List<String>? message,
  bool useDestinationMessage = false,
  bool keepEmptied = false,
}) {
  final Uint8List request = _squashRequest(
    revision: revision,
    from: from,
    into: into,
    paths: paths,
    message: message,
    useDestinationMessage: useDestinationMessage,
    keepEmptied: keepEmptied,
  );
  return callWithRequest(request, (ptr, len) => zanshin_squash(rawHandle, ptr, len));
}

/// Call `zanshin_squash_plan` with the raw `u64` handle and the same
/// `SquashRequest` [zanshinSquash] sends, and return the FlatBuffers
/// `Envelope` bytes (Story 9.15): the description the squash would have to ask
/// for. Writes no operation of its own.
Uint8List zanshinSquashPlan(
  int rawHandle, {
  String? revision,
  List<String> from = const [],
  String? into,
  List<String> paths = const [],
  List<String>? message,
  bool useDestinationMessage = false,
  bool keepEmptied = false,
}) {
  final Uint8List request = _squashRequest(
    revision: revision,
    from: from,
    into: into,
    paths: paths,
    message: message,
    useDestinationMessage: useDestinationMessage,
    keepEmptied: keepEmptied,
  );
  return callWithRequest(request, (ptr, len) => zanshin_squash_plan(rawHandle, ptr, len));
}

/// Call `zanshin_split` with the raw `u64` handle and a `SplitRequest` request
/// buffer, and return the FlatBuffers `Envelope` bytes (Story 9.15) — the
/// CLI's `jj split`, paths only.
///
/// [revision] is `-r` (`null`: `@`). [paths] are repo-relative PREFIXES, at
/// least one (no paths is the CLI's interactive diff editor, refused). [message]
/// is `-m` for the SELECTED commit (`null`: both keep the original
/// description). [parallel] is `--parallel`; [onto] / [insertAfter] /
/// [insertBefore] are `-o` / `-A` / `-B` — `null` is the flag not given, an
/// empty list the flag given with no revision.
Uint8List zanshinSplit(
  int rawHandle, {
  required List<String> paths,
  String? revision,
  List<String>? message,
  bool parallel = false,
  List<String>? onto,
  List<String>? insertAfter,
  List<String>? insertBefore,
}) {
  rejectInteriorNul(revision, 'revision');
  rejectInteriorNuls(paths, 'paths');
  rejectInteriorNuls(message ?? const [], 'message');
  rejectInteriorNuls(onto ?? const [], 'onto');
  rejectInteriorNuls(insertAfter ?? const [], 'insertAfter');
  rejectInteriorNuls(insertBefore ?? const [], 'insertBefore');
  final Uint8List request = fbs.SplitRequestObjectBuilder(
    kind: fbs.RequestKind.Split,
    revision: revision,
    paths: paths,
    message: message,
    parallel: parallel,
    onto: onto,
    insertAfter: insertAfter,
    insertBefore: insertBefore,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_split(rawHandle, ptr, len));
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// The description a squash would have to ask for (mirrors
/// `zanshin_jj::SquashPlan`).
final class SquashPlan {
  const SquashPlan({required this.combinedDescription, this.warnings = const []});

  /// The combined description — the text the CLI's editor holds, saved
  /// unchanged, and exactly what `squash` writes without `message` — when the
  /// abandoned sources and the destination carry two or more non-empty
  /// descriptions and neither `message` nor `useDestinationMessage` is set;
  /// `null` otherwise (nothing to ask).
  final String? combinedDescription;

  /// The call's warnings (e.g. `jj.paths_unmatched`); empty when there were
  /// none.
  final List<ZanshinWarning> warnings;
}

/// Outcome of a successful `split` (mirrors `zanshin_jj::SplitResult`).
final class SplitResult {
  const SplitResult({
    required this.mutation,
    required this.selectedChangeId,
    required this.remainingChangeId,
    this.warnings = const [],
  });

  /// The shared mutation contract; its `newChangeIds` holds the one commit that
  /// got a new change id.
  final MutationResult mutation;

  /// Change id of the commit holding the SELECTED changes.
  final String selectedChangeId;

  /// Change id of the commit holding the REMAINING changes — `@` ends here when
  /// the target was `@`.
  final String remainingChangeId;

  /// The call's warnings (`jj.split_all_selected`, `jj.split_none_selected`,
  /// `jj.paths_unmatched`, …); empty when there were none. The nested
  /// [mutation] carries none of its own.
  final List<ZanshinWarning> warnings;
}

// ── Decoders ─────────────────────────────────────────────────────────────────

/// Decode a `SquashPlan` `Envelope` buffer into a [SquashPlan].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.squashPlan`.
@visibleForTesting
SquashPlan decodeSquashPlanEnvelope(Uint8List bytes) => decodeSquashPlanEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
SquashPlan decodeSquashPlanEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.SquashPlan) {
    throw ZanshinFfiException('ffi.unknown', 'expected SquashPlan payload, got ${env.dataType}');
  }
  // Null-for-absence: an absent text means "nothing to ask" — never coerced to ''.
  return SquashPlan(combinedDescription: payload.combinedDescription, warnings: decodeEnvelopeWarningsInternal(env));
}

/// Decode a `SplitResult` `Envelope` buffer into a [SplitResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.split`.
@visibleForTesting
SplitResult decodeSplitResultEnvelope(Uint8List bytes) => decodeSplitResultEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
SplitResult decodeSplitResultEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.SplitResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected SplitResult payload, got ${env.dataType}');
  }
  // Rust always writes both ids on success, so a missing one is a malformed
  // buffer, not a modellable state — refused rather than guessed.
  return SplitResult(
    mutation: decodeMutationResultInternal(payload.mutation),
    selectedChangeId: payload.selectedChangeId ?? _missing('selected_change_id'),
    remainingChangeId: payload.remainingChangeId ?? _missing('remaining_change_id'),
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

Never _missing(String field) => throw ZanshinFfiException('ffi.unknown', 'SplitResult payload is missing its $field');

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  return env;
}
