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

// This file owns the Dart half of Story 9.16's three calls: the adapters
// (rebase / parallelize / arrange) and the `ArrangeAction` model. All three
// answer the shared `MutationResult`, decoded through `mutate.dart`'s one
// spelling. It also owns Story 9.14's `simplify-parents`: its adapter, the
// `SimplifyParentsResult` model and its decoder. `dart:ffi` stays inside
// `ffi/` — only the worker isolate calls these adapters.

// ── Dart models ──────────────────────────────────────────────────────────────

/// One of the `jj arrange` TUI's key actions (mirrors
/// `zanshin_jj::ArrangeAction`), on the commit of [changeId].
sealed class ArrangeAction {
  const ArrangeAction(this.changeId);

  /// The change the action is on — one of the revisions to arrange.
  final String changeId;
}

/// `J`: swap the commit with its parent — ignored unless it has exactly one
/// parent and that parent is among the revisions to arrange.
final class SwapDownAction extends ArrangeAction {
  const SwapDownAction(super.changeId);
}

/// `K`: swap the commit with its child — ignored unless it has exactly one
/// child and that child is among the revisions to arrange.
final class SwapUpAction extends ArrangeAction {
  const SwapUpAction(super.changeId);
}

/// `a`: abandon the commit.
final class AbandonAction extends ArrangeAction {
  const AbandonAction(super.changeId);
}

/// `p`: keep the commit (undoes an [AbandonAction]).
final class KeepAction extends ArrangeAction {
  const KeepAction(super.changeId);
}

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_rebase` with the raw `u64` handle and a `RebaseRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.16) —
/// the CLI's `jj rebase`.
///
/// [branch] / [source] / [revisions] are `-b` / `-s` / `-r` (at most one
/// non-empty; all empty is the CLI's `-b @`), [onto] / [insertAfter] /
/// [insertBefore] are `-o` / `-A` / `-B` (empty = the flag not given; at least
/// one, and [onto] excludes the other two). [skipEmptied], [keepDivergent] and
/// [simplifyParents] are the CLI's flags.
Uint8List zanshinRebase(
  int rawHandle, {
  List<String> branch = const [],
  List<String> source = const [],
  List<String> revisions = const [],
  List<String> onto = const [],
  List<String> insertAfter = const [],
  List<String> insertBefore = const [],
  bool skipEmptied = false,
  bool keepDivergent = false,
  bool simplifyParents = false,
}) {
  rejectInteriorNuls(branch, 'branch');
  rejectInteriorNuls(source, 'source');
  rejectInteriorNuls(revisions, 'revisions');
  rejectInteriorNuls(onto, 'onto');
  rejectInteriorNuls(insertAfter, 'insertAfter');
  rejectInteriorNuls(insertBefore, 'insertBefore');
  final Uint8List request = fbs.RebaseRequestObjectBuilder(
    kind: fbs.RequestKind.Rebase,
    branch: branch,
    source: source,
    revisions: revisions,
    onto: onto,
    insertAfter: insertAfter,
    insertBefore: insertBefore,
    skipEmptied: skipEmptied,
    keepDivergent: keepDivergent,
    simplifyParents: simplifyParents,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_rebase(rawHandle, ptr, len));
}

/// Call `zanshin_parallelize` with the raw `u64` handle and [changeIds]
/// (crossed as a `Parallelize`-tagged `ChangeIdList` request buffer), and
/// return the FlatBuffers `Envelope` bytes (Story 9.16) — the CLI's
/// `jj parallelize`.
Uint8List zanshinParallelize(int rawHandle, List<String> changeIds) {
  rejectInteriorNuls(changeIds, 'changeIds');
  final Uint8List request = fbs.ChangeIdListObjectBuilder(
    kind: fbs.RequestKind.Parallelize,
    changeIds: changeIds,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_parallelize(rawHandle, ptr, len));
}

/// Call `zanshin_arrange` with the raw `u64` handle and an `ArrangeRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.16) —
/// the CLI's `jj arrange` with its TUI session as data.
///
/// [revisions] are the change ids to arrange (empty = the `revsets.arrange`
/// setting); [actions] are the TUI's keys, replayed in order.
Uint8List zanshinArrange(
  int rawHandle, {
  List<String> revisions = const [],
  List<ArrangeAction> actions = const [],
}) {
  rejectInteriorNuls(revisions, 'revisions');
  rejectInteriorNuls([for (final action in actions) action.changeId], 'actions');
  final Uint8List request = fbs.ArrangeRequestObjectBuilder(
    kind: fbs.RequestKind.Arrange,
    revisions: revisions,
    actions: [
      for (final action in actions)
        fbs.ArrangeActionObjectBuilder(kind: _actionKind(action), changeId: action.changeId),
    ],
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_arrange(rawHandle, ptr, len));
}

fbs.ArrangeActionKind _actionKind(ArrangeAction action) => switch (action) {
  SwapDownAction() => fbs.ArrangeActionKind.SwapDown,
  SwapUpAction() => fbs.ArrangeActionKind.SwapUp,
  AbandonAction() => fbs.ArrangeActionKind.Abandon,
  KeepAction() => fbs.ArrangeActionKind.Keep,
};

/// Call `zanshin_simplify_parents` with the raw `u64` handle and a
/// `SimplifyParentsRequest` request buffer, and return the FlatBuffers
/// `Envelope` bytes (Story 9.14) — the CLI's `jj simplify-parents`.
///
/// [source] / [revisions] are `-s` / `-r` change ids; both empty is the
/// `revsets.simplify-parents` setting.
Uint8List zanshinSimplifyParents(
  int rawHandle, {
  List<String> source = const [],
  List<String> revisions = const [],
}) {
  rejectInteriorNuls(source, 'source');
  rejectInteriorNuls(revisions, 'revisions');
  final Uint8List request = fbs.SimplifyParentsRequestObjectBuilder(
    kind: fbs.RequestKind.SimplifyParents,
    source: source,
    revisions: revisions,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_simplify_parents(rawHandle, ptr, len));
}

/// Outcome of a successful `simplifyParents` (mirrors
/// `zanshin_jj::SimplifyParentsResult`) — the CLI's status lines as counts.
final class SimplifyParentsResult {
  const SimplifyParentsResult({
    required this.mutation,
    required this.numTargetCommits,
    required this.numSimplifiedCommits,
    required this.numRemovedEdges,
    required this.numRebasedDescendants,
    this.warnings = const [],
  });

  /// The shared mutation contract; its `newOpId` is the pre-call head when
  /// nothing changed.
  final MutationResult mutation;

  /// The commits in the target set — the operation's `simplify <n> commits`.
  final int numTargetCommits;

  /// Targets that lost at least one parent edge.
  final int numSimplifiedCommits;

  /// Parent edges removed in total.
  final int numRemovedEdges;

  /// Rewritten commits that lost no parent edge — rebased onto a rewritten
  /// parent, targets included.
  final int numRebasedDescendants;

  /// The call's warnings (`jj.revset_diagnostic`, `jj.config_deprecated`, …);
  /// empty when there were none. The nested [mutation] carries none of its
  /// own.
  final List<ZanshinWarning> warnings;
}

/// Decode a `SimplifyParentsResult` `Envelope` buffer into a
/// [SimplifyParentsResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.simplifyParents`.
@visibleForTesting
SimplifyParentsResult decodeSimplifyParentsResultEnvelope(Uint8List bytes) =>
    decodeSimplifyParentsResultEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
SimplifyParentsResult decodeSimplifyParentsResultEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.SimplifyParentsResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected SimplifyParentsResult payload, got ${env.dataType}');
  }
  return SimplifyParentsResult(
    mutation: decodeMutationResultInternal(payload.mutation),
    numTargetCommits: payload.numTargetCommits,
    numSimplifiedCommits: payload.numSimplifiedCommits,
    numRemovedEdges: payload.numRemovedEdges,
    numRebasedDescendants: payload.numRebasedDescendants,
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}
