// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.10's two calls: the adapters
// (moveWorkingCopy / movementTargets), the `MovementDirection`,
// `MovementTargets` and `MovementTarget` models and the targets decoder. The
// move answers the shared `MutationResult`, decoded through `mutate.dart`'s one
// spelling. `dart:ffi` stays inside `ffi/` — only the worker isolate calls
// these adapters.

// ── Dart models ──────────────────────────────────────────────────────────────

/// Which way a working-copy move goes: `jj next` or `jj prev` (mirrors
/// `zanshin_jj::Direction`).
enum MovementDirection {
  /// `jj next` — towards the descendants.
  next,

  /// `jj prev` — towards the ancestors.
  prev,
}

/// One candidate of [MovementTargets] (mirrors `zanshin_jj::MovementTarget`).
final class MovementTarget {
  const MovementTarget({required this.commitId, required this.changeId});

  /// The hex commit id — what `moveWorkingCopy`'s `target` takes (a change id
  /// can be divergent).
  final String commitId;

  /// The reverse-hex change id.
  final String changeId;
}

/// What `movementTargets` found (mirrors `zanshin_jj::MovementTargets`): the
/// candidates the CLI's prompt would list.
final class MovementTargets {
  const MovementTargets({required this.edit, required this.targets, this.warnings = const []});

  /// Whether the move edits its target (`edit`, or `ui.movement.edit` without
  /// `noEdit`) rather than creating a new working-copy commit on it.
  final bool edit;

  /// The candidates in the CLI's prompt order; never empty. More than one is
  /// where the CLI prompts.
  final List<MovementTarget> targets;

  /// The call's warnings (the pre-verb snapshot's); empty when there were none.
  final List<ZanshinWarning> warnings;
}

// ── FFI adapters ─────────────────────────────────────────────────────────────

Uint8List _movementRequest({
  required MovementDirection direction,
  required int? offset,
  required bool edit,
  required bool noEdit,
  required bool conflict,
  required String? target,
}) {
  rejectInteriorNuls([?target], 'target');
  if (offset != null && offset < 0) {
    throw ArgumentError.value(offset, 'offset', 'must not be negative');
  }
  return fbs.MovementRequestObjectBuilder(
    kind: fbs.RequestKind.Movement,
    direction: switch (direction) {
      MovementDirection.next => fbs.MovementDirection.Next,
      MovementDirection.prev => fbs.MovementDirection.Prev,
    },
    offset: offset == null ? null : fbs.MovementOffsetObjectBuilder(value: offset),
    edit: edit,
    noEdit: noEdit,
    conflict: conflict,
    target: target,
  ).toBytes();
}

/// Call `zanshin_move_working_copy` with the raw `u64` handle and a
/// `MovementRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes (Story 9.10) — the CLI's `jj next` / `jj prev`.
///
/// A `null` [offset] stays ABSENT on the wire (the CLI's default `1`); a
/// `null` [target] is no choice. Throws [ArgumentError] for a negative
/// [offset] or an interior NUL in [target].
Uint8List zanshinMoveWorkingCopy(
  int rawHandle, {
  MovementDirection direction = MovementDirection.next,
  int? offset,
  bool edit = false,
  bool noEdit = false,
  bool conflict = false,
  String? target,
}) {
  final Uint8List request = _movementRequest(
    direction: direction,
    offset: offset,
    edit: edit,
    noEdit: noEdit,
    conflict: conflict,
    target: target,
  );
  return callWithRequest(request, (ptr, len) => zanshin_move_working_copy(rawHandle, ptr, len));
}

/// Call `zanshin_movement_targets` with the raw `u64` handle and a
/// `MovementRequest` request buffer (no `target`), and return the FlatBuffers
/// `Envelope` bytes (Story 9.10).
///
/// Throws [ArgumentError] for a negative [offset].
Uint8List zanshinMovementTargets(
  int rawHandle, {
  MovementDirection direction = MovementDirection.next,
  int? offset,
  bool edit = false,
  bool noEdit = false,
  bool conflict = false,
}) {
  final Uint8List request = _movementRequest(
    direction: direction,
    offset: offset,
    edit: edit,
    noEdit: noEdit,
    conflict: conflict,
    target: null,
  );
  return callWithRequest(request, (ptr, len) => zanshin_movement_targets(rawHandle, ptr, len));
}

// ── Decoders ─────────────────────────────────────────────────────────────────

/// Decode a `MovementTargets` `Envelope` buffer into a [MovementTargets].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.movementTargets`.
@visibleForTesting
MovementTargets decodeMovementTargetsEnvelope(Uint8List bytes) => decodeMovementTargetsEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
MovementTargets decodeMovementTargetsEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.MovementTargets) {
    throw ZanshinFfiException('ffi.unknown', 'expected MovementTargets payload, got ${env.dataType}');
  }
  return MovementTargets(
    edit: payload.edit,
    targets: [
      for (final fbs.MovementTarget target in payload.targets ?? const [])
        MovementTarget(
          commitId: target.commitId ?? _missing('commit_id'),
          changeId: target.changeId ?? _missing('change_id'),
        ),
    ],
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

// Rust always writes both ids, so a missing one is a malformed buffer, not a
// modellable state — refused rather than guessed.
Never _missing(String field) => throw ZanshinFfiException('ffi.unknown', 'MovementTarget is missing its $field');
