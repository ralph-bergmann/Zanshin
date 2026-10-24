// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.50's GUI diff-editor contract: the
// selection models (`HunkKey`, `FileSelection`), the `selectTree` adapter and
// its `SelectedTree` decoder, and the `TreeSelection` / `SourceTree` the tree
// arms of `commit`, `split` and `squash` send. `dart:ffi` stays inside `ffi/` —
// only the worker isolate calls the adapter.

// ── Models ───────────────────────────────────────────────────────────────────

/// One changed section of a file, by where it sits on each side in lines
/// (mirrors `zanshin_jj::HunkKey`) — the builtin diff editor's sections.
///
/// [oldStart] / [newStart] are the 0-based index of the section's first line on
/// the left (parent) / right (revision) side; [oldCount] / [newCount] its lines
/// there (an insertion has [oldCount] 0, a deletion [newCount] 0). Lines are
/// cut like `split_inclusive('\n')`: a last line without `\n` counts.
@immutable
final class HunkKey {
  const HunkKey({required this.oldStart, required this.oldCount, required this.newStart, required this.newCount});

  /// 0-based index of the section's first line on the left side.
  final int oldStart;

  /// The section's lines on the left side.
  final int oldCount;

  /// 0-based index of the section's first line on the right side.
  final int newStart;

  /// The section's lines on the right side.
  final int newCount;

  @override
  bool operator ==(Object other) =>
      other is HunkKey &&
      other.oldStart == oldStart &&
      other.oldCount == oldCount &&
      other.newStart == newStart &&
      other.newCount == newCount;

  @override
  int get hashCode => Object.hash(oldStart, oldCount, newStart, newCount);

  @override
  String toString() => 'HunkKey(-$oldStart,$oldCount +$newStart,$newCount)';
}

/// One file of a selection (mirrors `zanshin_jj::FileSelection`): the whole
/// file, or some of its sections, with or without its mode change.
final class FileSelection {
  /// The whole file at [path]: the revision's value, whatever the change.
  const FileSelection.whole(this.path) : whole = true, mode = false, hunks = const [];

  /// These [hunks] of the file at [path]; the other sections keep the left
  /// side and the file keeps its left mode. An empty list selects nothing of
  /// the file.
  const FileSelection.hunks(this.path, this.hunks) : whole = false, mode = false;

  /// The revision's mode of the file at [path] — the builtin diff editor's mode
  /// toggle — plus these [hunks] (empty: the mode change only). Only a file
  /// whose two sides are a regular file or a file conflict with different
  /// modes has one; else `selectTree` refuses `jj.stale_selection`.
  const FileSelection.modeAndHunks(this.path, this.hunks) : whole = false, mode = true;

  /// The repo-relative path, in jj's internal `/`-separated form (what
  /// `ShowEntry.fileChanges` reports).
  final String path;

  /// Whether the whole file is selected.
  final bool whole;

  /// Whether the revision's mode is selected; never with [whole].
  final bool mode;

  /// The selected sections; empty when [whole].
  final List<HunkKey> hunks;
}

/// A tree `selectTree` wrote (mirrors `zanshin_jj::SelectedTreeId`): its tree
/// ids and conflict labels, exactly as the backend returned them.
final class SelectedTree {
  const SelectedTree({required this.treeIds, required this.labels, this.warnings = const []});

  /// The tree ids, hex, in order — one for a resolved tree, an odd number for a
  /// conflicted one.
  final List<String> treeIds;

  /// The conflict labels; empty = unlabeled, else one per id.
  final List<String> labels;

  /// The call's warnings (the pre-verb snapshot's); empty when there were none.
  final List<ZanshinWarning> warnings;
}

/// A tree arm's selection (mirrors `zanshin_jj::TreeSelection`): the tree
/// `selectTree` returned and the `left` it was selected against.
final class TreeSelection {
  const TreeSelection({required this.treeIds, required this.labels, required this.left});

  /// [tree] with the [left] the selection was made against.
  TreeSelection.of(SelectedTree tree, {required this.left}) : treeIds = tree.treeIds, labels = tree.labels;

  /// As [SelectedTree.treeIds].
  final List<String> treeIds;

  /// As [SelectedTree.labels].
  final List<String> labels;

  /// The tree the selection was made against — the revision's parent tree
  /// (`ShowEntry.parentTreeIds`), or for `diffedit` with `from` that revision's
  /// own tree (`ShowEntry.treeIds`); the verb refuses `jj.stale_selection` when
  /// it moved.
  final List<String> left;
}

/// One squash source's selected tree (mirrors `zanshin_jj::SourceTree`).
final class SourceTree {
  const SourceTree({required this.source, required this.tree});

  /// The source's change id.
  final String source;

  /// Its selection.
  final TreeSelection tree;
}

// ── Request-buffer helpers ───────────────────────────────────────────────────

/// Reject an interior NUL anywhere in [selection].
void rejectTreeSelectionNuls(TreeSelection? selection) {
  if (selection == null) {
    return;
  }
  rejectInteriorNuls(selection.treeIds, 'treeIds');
  rejectInteriorNuls(selection.labels, 'labels');
  rejectInteriorNuls(selection.left, 'left');
}

/// Reject an interior NUL anywhere in [trees].
void rejectSourceTreeNuls(List<SourceTree> trees) {
  for (final entry in trees) {
    rejectInteriorNul(entry.source, 'source');
    rejectTreeSelectionNuls(entry.tree);
  }
}

/// Reject an interior NUL in [revision], [left] or a path of [files].
void rejectSelectTreeNuls(String? revision, List<String> left, List<FileSelection> files) {
  rejectInteriorNul(revision, 'revision');
  rejectInteriorNuls(left, 'left');
  rejectInteriorNuls([for (final FileSelection file in files) file.path], 'files');
}

/// The `TreeSelection` table [selection] crosses as; `null` stays ABSENT (the
/// paths arm).
fbs.TreeSelectionObjectBuilder? treeSelectionBuilder(TreeSelection? selection) => selection == null
    ? null
    : fbs.TreeSelectionObjectBuilder(treeIds: selection.treeIds, labels: selection.labels, left: selection.left);

/// The `SourceTree` tables [trees] cross as.
List<fbs.SourceTreeObjectBuilder> sourceTreeBuilders(List<SourceTree> trees) => [
  for (final SourceTree entry in trees)
    fbs.SourceTreeObjectBuilder(source: entry.source, tree: treeSelectionBuilder(entry.tree)),
];

// ── FFI adapter ──────────────────────────────────────────────────────────────

/// Call `zanshin_select_tree` with the raw `u64` handle and a
/// `SelectTreeRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes (Story 9.50) — the CLI's builtin diff editor applying the same choice.
///
/// [revision] is the revision the selection was made in (`null`: `@`), [from]
/// (Story 9.17) the revision whose OWN tree is the diff's left side
/// (`diffedit --from`; `null`: the revision's parent tree), [left] that left
/// tree as `ShowEntry.parentTreeIds` — or, with [from], `ShowEntry.treeIds` —
/// reported it, [files] the selected files; a changed file not listed keeps its
/// left side.
Uint8List zanshinSelectTree(
  int rawHandle, {
  required List<String> left,
  required List<FileSelection> files,
  String? revision,
  String? from,
}) {
  rejectSelectTreeNuls(revision, left, files);
  rejectInteriorNul(from, 'from');
  final Uint8List request = fbs.SelectTreeRequestObjectBuilder(
    kind: fbs.RequestKind.SelectTree,
    revision: revision,
    from: from,
    left: left,
    files: [
      for (final FileSelection file in files)
        fbs.FileSelectionObjectBuilder(
          path: file.path,
          whole: file.whole,
          mode: file.mode,
          hunks: [
            for (final HunkKey key in file.hunks)
              fbs.HunkKeyObjectBuilder(
                oldStart: key.oldStart,
                oldCount: key.oldCount,
                newStart: key.newStart,
                newCount: key.newCount,
              ),
          ],
        ),
    ],
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_select_tree(rawHandle, ptr, len));
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `SelectedTree` `Envelope` buffer into a [SelectedTree].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.selectTree`.
@visibleForTesting
SelectedTree decodeSelectedTreeEnvelope(Uint8List bytes) => decodeSelectedTreeEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
SelectedTree decodeSelectedTreeEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.SelectedTree) {
    throw ZanshinFfiException('ffi.unknown', 'expected SelectedTree payload, got ${env.dataType}');
  }
  return SelectedTree(
    treeIds: payload.treeIds ?? const [],
    labels: payload.labels ?? const [],
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}
