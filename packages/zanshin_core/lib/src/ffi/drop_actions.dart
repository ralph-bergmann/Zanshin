// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.31's two queries: the
// `zanshin_drop_actions` / `zanshin_change_actions` adapters, their arguments,
// the `DropActions` / `ChangeActions` models and their decoders. `dart:ffi`
// stays inside `ffi/` — only the worker isolate calls the adapters.

// ── Arguments ────────────────────────────────────────────────────────────────

/// What is dragged (mirrors `zanshin_jj::DropSource`).
sealed class DropSource {
  const DropSource();
}

/// A whole change.
final class ChangeDropSource extends DropSource {
  const ChangeDropSource(this.changeId);

  /// The dragged change (jj reverse-hex).
  final String changeId;
}

/// The changes to [paths] — repo-relative PREFIXES — inside [changeId]. An
/// empty list is every path for the squash row; the split row refuses it
/// (`jj.invalid_input`, split's no-paths text).
final class SelectionDropSource extends DropSource {
  const SelectionDropSource(this.changeId, this.paths);

  /// The change the paths are selected in (jj reverse-hex).
  final String changeId;

  /// The selected paths.
  final List<String> paths;
}

/// The local bookmark named exactly [name].
final class BookmarkDropSource extends DropSource {
  const BookmarkDropSource(this.name);

  /// The bookmark's name.
  final String name;
}

/// Where it is dropped (mirrors `zanshin_jj::DropLocation`) — the CLI's `-o` /
/// `-A` / `-B`, change ids in jj reverse-hex. An empty list is the flag not
/// given; [onto] excludes the other two, and at least one must be given.
final class DropLocation {
  const DropLocation({this.onto = const [], this.insertAfter = const [], this.insertBefore = const []});

  /// `-o/--onto`.
  final List<String> onto;

  /// `-A/--insert-after`.
  final List<String> insertAfter;

  /// `-B/--insert-before`.
  final List<String> insertBefore;
}

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_drop_actions` with the raw `u64` handle and a
/// `DropActionsRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes (Story 9.31): which verbs [source] can run at each of [locations].
/// Writes no operation of its own.
Uint8List zanshinDropActions(int rawHandle, DropSource source, List<DropLocation> locations) {
  final Uint8List request = dropActionsRequestBytes(source, locations);
  return callWithRequest(request, (ptr, len) => zanshin_drop_actions(rawHandle, ptr, len));
}

/// The `DropActionsRequest` bytes [zanshinDropActions] sends.
///
/// Throws [ArgumentError] when an id, path or name contains an interior NUL
/// (U+0000).
@visibleForTesting
Uint8List dropActionsRequestBytes(DropSource source, List<DropLocation> locations) {
  final (fbs.DropSourceKind kind, String? changeId, List<String>? paths, String? bookmark) = switch (source) {
    ChangeDropSource(:final changeId) => (fbs.DropSourceKind.Change, changeId, null, null),
    SelectionDropSource(:final changeId, :final paths) => (fbs.DropSourceKind.Selection, changeId, paths, null),
    BookmarkDropSource(:final name) => (fbs.DropSourceKind.Bookmark, null, null, name),
  };
  rejectDropActionsNuls(source, locations);
  return fbs.DropActionsRequestObjectBuilder(
    kind: fbs.RequestKind.DropActions,
    sourceKind: kind,
    changeId: changeId,
    paths: paths,
    bookmark: bookmark,
    locations: [
      for (final location in locations)
        fbs.DropLocationObjectBuilder(
          onto: location.onto,
          insertAfter: location.insertAfter,
          insertBefore: location.insertBefore,
        ),
    ],
  ).toBytes();
}

/// Throws [ArgumentError] when an id, path or name of [source] or [locations]
/// contains an interior NUL (U+0000) — the request-string guard every adapter
/// runs, and the worker runs before it sends the command.
void rejectDropActionsNuls(DropSource source, List<DropLocation> locations) {
  switch (source) {
    case ChangeDropSource(:final changeId):
      rejectInteriorNul(changeId, 'changeId');
    case SelectionDropSource(:final changeId, :final paths):
      rejectInteriorNul(changeId, 'changeId');
      rejectInteriorNuls(paths, 'paths');
    case BookmarkDropSource(:final name):
      rejectInteriorNul(name, 'bookmark');
  }
  for (final location in locations) {
    rejectInteriorNuls(location.onto, 'onto');
    rejectInteriorNuls(location.insertAfter, 'insertAfter');
    rejectInteriorNuls(location.insertBefore, 'insertBefore');
  }
}

/// Call `zanshin_change_actions` with the raw `u64` handle and [changeId], and
/// return the FlatBuffers `Envelope` bytes (Story 9.31): the card menu's verbs
/// for one change. Writes no operation of its own.
Uint8List zanshinChangeActions(int rawHandle, String changeId) {
  rejectInteriorNul(changeId, 'changeId');
  final ffi.Pointer<Utf8> p = changeId.toNativeUtf8();
  try {
    return readToken(zanshin_change_actions(rawHandle, p.cast()));
  } finally {
    calloc.free(p); // outer: free the C string we allocated
  }
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// The verb a [DropAction] previews (mirrors `zanshin_jj::DropVerb`), with `S`
/// the source and `T…` the location's ids.
enum DropVerb {
  /// `jj rebase -s S -o T…`.
  rebaseSource,

  /// `jj rebase -r S -o T…`, or with `-A`/`-B`.
  rebaseRevisions,

  /// `jj squash --from S --into T [paths]`.
  squash,

  /// `jj new T… S`.
  newMerge,

  /// `jj duplicate S -o T…`.
  duplicate,

  /// `jj split -r S <paths> -A/-B …`.
  split,

  /// `jj bookmark move N --to T`.
  bookmarkMove,
}

/// Whether a previewed verb would run (mirrors `zanshin_jj::ActionStatus`).
enum ActionStatus {
  /// It would run and write an operation.
  available,

  /// It would run and write NO operation (rebase, squash, bookmark move only).
  noOp,

  /// It would refuse; [ActionOutcome.refusal] says why.
  refused,
}

/// A previewed verb's refusal: the code and `context` the verb's own call
/// fails with (`jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
/// `jj.config_error`, …).
final class ActionRefusal {
  const ActionRefusal(this.code, this.context);

  /// Machine-readable error code, e.g. `jj.immutable`.
  final String code;

  /// The detail the verb's error carries; `null` when it carries none.
  final String? context;
}

/// One previewed verb's answer (mirrors `zanshin_jj::ActionOutcome`).
final class ActionOutcome {
  const ActionOutcome({
    required this.status,
    required this.refusal,
    required this.combinedDescriptionNeeded,
    required this.allowBackwardsNeeded,
  });

  /// Whether the verb would run.
  final ActionStatus status;

  /// The verb's refusal — non-null exactly when [status] is
  /// [ActionStatus.refused].
  final ActionRefusal? refusal;

  /// A squash row: two or more non-empty descriptions would be combined — ask
  /// `RepoHandle.squashPlan` for the text.
  final bool combinedDescriptionNeeded;

  /// A bookmark row: the move is not a fast-forward (the CLI's
  /// `--allow-backwards`).
  final bool allowBackwardsNeeded;
}

/// One row of [DropActions] (mirrors `zanshin_jj::DropAction`).
final class DropAction {
  const DropAction({required this.verb, required this.location, required this.outcome});

  /// The previewed verb.
  final DropVerb verb;

  /// The index of the location in the call's `locations`.
  final int location;

  /// Its answer.
  final ActionOutcome outcome;
}

/// `RepoHandle.dropActions`' answer (mirrors `zanshin_jj::DropActions`).
final class DropActions {
  const DropActions({required this.actions, this.warnings = const []});

  /// Every location's rows, in location order.
  final List<DropAction> actions;

  /// The call's warnings — the pre-verb snapshot's only; empty when there were
  /// none.
  final List<ZanshinWarning> warnings;
}

/// `RepoHandle.changeActions`' answer: the card menu's verbs for one change
/// `X` (mirrors `zanshin_jj::ChangeActions`).
final class ChangeActions {
  const ChangeActions({
    required this.newOnto,
    required this.newInsertAfter,
    required this.newInsertBefore,
    required this.edit,
    required this.describe,
    required this.squashIntoParent,
    required this.abandon,
    this.warnings = const [],
  });

  /// `jj new X`.
  final ActionOutcome newOnto;

  /// `jj new -A X`.
  final ActionOutcome newInsertAfter;

  /// `jj new -B X`.
  final ActionOutcome newInsertBefore;

  /// `jj edit X`.
  final ActionOutcome edit;

  /// `jj describe X`.
  final ActionOutcome describe;

  /// `jj squash -r X`, with [ActionOutcome.combinedDescriptionNeeded].
  final ActionOutcome squashIntoParent;

  /// `jj abandon X`.
  final ActionOutcome abandon;

  /// The call's warnings — the pre-verb snapshot's only.
  final List<ZanshinWarning> warnings;
}

// ── Decoders ─────────────────────────────────────────────────────────────────

/// Decode a `DropActions` `Envelope` buffer into [DropActions].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.dropActions`.
@visibleForTesting
DropActions decodeDropActionsEnvelope(Uint8List bytes) => decodeDropActionsEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
DropActions decodeDropActionsEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.DropActions) {
    throw ZanshinFfiException('ffi.unknown', 'expected DropActions payload, got ${env.dataType}');
  }
  return DropActions(
    actions: [
      for (final fbs.DropAction row in payload.actions ?? const <fbs.DropAction>[])
        DropAction(verb: _verb(row.verb), location: row.location, outcome: _outcome(row.outcome)),
    ],
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `ChangeActions` `Envelope` buffer into [ChangeActions].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.changeActions`.
@visibleForTesting
ChangeActions decodeChangeActionsEnvelope(Uint8List bytes) => decodeChangeActionsEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
ChangeActions decodeChangeActionsEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.ChangeActions) {
    throw ZanshinFfiException('ffi.unknown', 'expected ChangeActions payload, got ${env.dataType}');
  }
  return ChangeActions(
    newOnto: _outcome(payload.newOnto),
    newInsertAfter: _outcome(payload.newInsertAfter),
    newInsertBefore: _outcome(payload.newInsertBefore),
    edit: _outcome(payload.edit),
    describe: _outcome(payload.describe),
    squashIntoParent: _outcome(payload.squashIntoParent),
    abandon: _outcome(payload.abandon),
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Rust always writes every outcome, and a refused one's code: a missing one is
/// a malformed buffer, not a modellable state — refused rather than guessed.
ActionOutcome _outcome(fbs.ActionOutcome? outcome) {
  if (outcome == null) {
    throw const ZanshinFfiException('ffi.unknown', 'ActionOutcome is missing');
  }
  final fbs.FfiError? refusal = outcome.refusal;
  return ActionOutcome(
    status: switch (outcome.status) {
      fbs.ActionStatus.Available => ActionStatus.available,
      fbs.ActionStatus.NoOp => ActionStatus.noOp,
      fbs.ActionStatus.Refused => ActionStatus.refused,
    },
    refusal: refusal == null
        ? null
        : ActionRefusal(
            refusal.code ?? (throw const ZanshinFfiException('ffi.unknown', 'a refusal is missing its code')),
            refusal.context,
          ),
    combinedDescriptionNeeded: outcome.combinedDescriptionNeeded,
    allowBackwardsNeeded: outcome.allowBackwardsNeeded,
  );
}

DropVerb _verb(fbs.DropVerb verb) => switch (verb) {
  fbs.DropVerb.RebaseSource => DropVerb.rebaseSource,
  fbs.DropVerb.RebaseRevisions => DropVerb.rebaseRevisions,
  fbs.DropVerb.Squash => DropVerb.squash,
  fbs.DropVerb.NewMerge => DropVerb.newMerge,
  fbs.DropVerb.Duplicate => DropVerb.duplicate,
  fbs.DropVerb.Split => DropVerb.split,
  fbs.DropVerb.BookmarkMove => DropVerb.bookmarkMove,
};

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  return env;
}
