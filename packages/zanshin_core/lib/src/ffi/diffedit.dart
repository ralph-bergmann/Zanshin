// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'request_bytes.dart';
import 'select_tree.dart' show TreeSelection, rejectTreeSelectionNuls, treeSelectionBuilder;

// This file owns the Dart half of Story 9.17's `diffedit` adapter. It answers
// the shared `MutationResult`, decoded through `mutate.dart`; its tree is a
// `select_tree.dart` `TreeSelection`. `dart:ffi` stays inside `ffi/` — only the
// worker isolate calls the adapter.

/// Reject an interior NUL in an id, in [tree] or in [right].
void rejectDiffeditNuls(String? revision, String? from, String? to, TreeSelection tree, List<String> right) {
  rejectInteriorNul(revision, 'revision');
  rejectInteriorNul(from, 'from');
  rejectInteriorNul(to, 'to');
  rejectTreeSelectionNuls(tree);
  rejectInteriorNuls(right, 'right');
}

/// Call `zanshin_diffedit` with the raw `u64` handle and a `DiffeditRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.17) —
/// the CLI's `jj diffedit` with its builtin diff editor, the GUI's.
///
/// [tree] is what `selectTree` returned for the diff (with `from:` = [from] in
/// the [from] / [to] form) and the `left` it was selected against; [right] is
/// the target's tree ids the selection saw (its `ShowEntry.treeIds`) — a
/// target tree that differs now refuses `jj.stale_selection`;
/// [revision] is `-r` (against its parents; not with [from] / [to]), [from] /
/// [to] are `--from` / `--to` (`null`: `@`), [restoreDescendants]
/// `--restore-descendants`.
Uint8List zanshinDiffedit(
  int rawHandle, {
  required TreeSelection tree,
  required List<String> right,
  String? revision,
  String? from,
  String? to,
  bool restoreDescendants = false,
}) {
  rejectDiffeditNuls(revision, from, to, tree, right);
  final Uint8List request = fbs.DiffeditRequestObjectBuilder(
    kind: fbs.RequestKind.Diffedit,
    revision: revision,
    from: from,
    to: to,
    tree: treeSelectionBuilder(tree),
    restoreDescendants: restoreDescendants,
    right: right,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_diffedit(rawHandle, ptr, len));
}
