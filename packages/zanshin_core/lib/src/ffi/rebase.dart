// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'request_bytes.dart';

// This file owns the Dart half of Story 9.16's three calls: the adapters
// (rebase / parallelize / arrange) and the `ArrangeAction` model. All three
// answer the shared `MutationResult`, decoded through `mutate.dart`'s one
// spelling. `dart:ffi` stays inside `ffi/` — only the worker isolate calls
// these adapters.

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
