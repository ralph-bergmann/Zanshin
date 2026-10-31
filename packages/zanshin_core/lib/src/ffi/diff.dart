// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'select_tree.dart' show HunkKey;
import 'status.dart' show FileChangeKind, mapChangeKind;
import 'warning.dart';

// This file owns the Dart half of Story 5.5's line-level `Diff` payload: the
// models mirroring `zanshin_jj::RevisionDiff` / `FileDiff` / `Hunk` /
// `HunkLine` and their decoder (Story 5.6 adds kinds, counts, fingerprints and
// pins). The extern, worker command and `RepoHandle` method are Story 5.8's.

// ── Models ───────────────────────────────────────────────────────────────────

/// What a [HunkLine] is (mirrors `zanshin_jj::HunkLine`'s variants).
enum HunkLineKind {
  /// On both sides, as the right side's text.
  context,

  /// On the left side only.
  removed,

  /// On the right side only.
  added,
}

/// One line of a [Hunk]: its [kind] and [text], which includes its `\n` (a last
/// line without one keeps that state).
final class HunkLine {
  const HunkLine({required this.kind, required this.text});

  /// Whether the line is context, removed or added.
  final HunkLineKind kind;

  /// The line's text, decoded lossily as UTF-8; a context line carries the
  /// right side's text.
  final String text;
}

/// One hunk of a [FileDiff] — what `jj diff --git` prints under one `@@`
/// header (mirrors `zanshin_jj::Hunk`).
final class Hunk {
  const Hunk({
    required this.before,
    required this.after,
    required this.symbol,
    required this.sections,
    required this.removed,
    required this.added,
    required this.lines,
  });

  /// Its lines on the left side, 0-based half-open.
  final ({int start, int end}) before;

  /// Its lines on the right side, 0-based half-open.
  final ({int start, int end}) after;

  /// The header's source symbol, cut at 80 bytes; null when the file's
  /// language has no pattern or no symbol precedes the hunk.
  final String? symbol;

  /// The file's sections one of its removed or added lines falls in — the keys
  /// `selectTree` takes. At `-w` / `-b` this can be a whole section the hunk
  /// shows only part of, or empty.
  final List<HunkKey> sections;

  /// Its removed lines.
  final int removed;

  /// Its added lines.
  final int added;

  /// Its lines in order.
  final List<HunkLine> lines;
}

/// One changed path of a [Diff] (mirrors `zanshin_jj::FileDiff`).
final class FileDiff {
  const FileDiff({
    required this.path,
    required this.kind,
    required this.fromPath,
    required this.binary,
    required this.modeChange,
    required this.sections,
    required this.hunks,
    required this.removed,
    required this.added,
    required this.fingerprint,
  });

  /// The repo-relative path, in jj's internal `/`-separated form — a copy's or
  /// rename's target.
  final String path;

  /// How the path changed: a copy record's source first, then presence.
  final FileChangeKind kind;

  /// The source path for [FileChangeKind.renamed] and [FileChangeKind.copied];
  /// null for all other kinds.
  final String? fromPath;

  /// The contents differ and either side's is binary: no hunks.
  final bool binary;

  /// Both sides are file-like and differ in the executable bit — the builtin
  /// diff editor's mode toggle (`FileSelection`'s mode).
  final bool modeChange;

  /// Every section `selectTree` accepts for the file; empty when it can only
  /// be selected whole (always for a copy or rename), or by its mode when
  /// [modeChange].
  final List<HunkKey> sections;

  /// The hunks, in file order; none for binary content, a mode-only change, or
  /// in summary mode.
  final List<Hunk> hunks;

  /// The sum of its hunks' removed lines (kept in summary mode).
  final int removed;

  /// The sum of its hunks' added lines (kept in summary mode).
  final int added;

  /// A stable fingerprint of the changed lines (no line numbers, no context),
  /// lowercase hex — equal changes at shifted line numbers share it. It depends
  /// on the call's whitespace mode and the effective `ui.conflict-marker-style`
  /// and covers content only (no path, no kind): every content-less change (a
  /// pure rename, an empty file added) shares one value, so a Viewed key
  /// combines it with [path].
  final String fingerprint;
}

/// A line-level diff between two revisions: `diff`'s files, in order, pinned
/// to the operation and commit(s) it was computed at.
final class Diff {
  const Diff({
    required this.files,
    required this.operationId,
    required this.commitId,
    this.fromCommitId,
    this.warnings = const [],
  });

  /// The changed files, in order.
  final List<FileDiff> files;

  /// The operation the diff was read at, full hex.
  final String operationId;

  /// The revision (`-r`) or `to` (`--from`/`--to`), full hex.
  final String commitId;

  /// `from` for `--from`/`--to`; null for the revision form.
  final String? fromCommitId;

  /// The call's warnings; empty when there were none.
  final List<ZanshinWarning> warnings;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `Diff` `Envelope` buffer into a [Diff].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// arrive with Story 5.8's worker command. An out-of-range `HunkLineKind` byte
/// surfaces as the generated accessor's `StateError` (by design: a corrupt
/// buffer, not a refusal).
@visibleForTesting
Diff decodeDiffEnvelope(Uint8List bytes) => decodeDiffEnvelopeInternal(bytes);

/// Internal decoder used by production code.
Diff decodeDiffEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Diff) {
    throw ZanshinFfiException('ffi.unknown', 'expected Diff payload, got ${env.dataType}');
  }
  return Diff(
    files: [for (final fbs.FileDiff file in payload.files ?? const []) _file(file)],
    operationId: payload.operationId ?? '',
    commitId: payload.commitId ?? '',
    fromCommitId: payload.fromCommitId,
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

FileDiff _file(fbs.FileDiff file) => FileDiff(
  path: file.path ?? '',
  kind: mapChangeKind(file.kind),
  fromPath: file.fromPath,
  binary: file.binary,
  modeChange: file.modeChange,
  sections: _keys(file.sections),
  hunks: [for (final fbs.Hunk hunk in file.hunks ?? const []) _hunk(hunk)],
  removed: file.removed,
  added: file.added,
  fingerprint: file.fingerprint ?? '',
);

Hunk _hunk(fbs.Hunk hunk) => Hunk(
  before: (start: hunk.beforeStart, end: hunk.beforeEnd),
  after: (start: hunk.afterStart, end: hunk.afterEnd),
  symbol: hunk.symbol,
  sections: _keys(hunk.sections),
  removed: hunk.removed,
  added: hunk.added,
  lines: [
    for (final fbs.HunkLine line in hunk.lines ?? const [])
      HunkLine(
        kind: switch (line.kind) {
          fbs.HunkLineKind.Context => HunkLineKind.context,
          fbs.HunkLineKind.Removed => HunkLineKind.removed,
          fbs.HunkLineKind.Added => HunkLineKind.added,
        },
        text: line.text ?? '',
      ),
  ],
);

List<HunkKey> _keys(List<fbs.HunkKey>? keys) => [
  for (final fbs.HunkKey key in keys ?? const [])
    HunkKey(oldStart: key.oldStart, oldCount: key.oldCount, newStart: key.newStart, newCount: key.newCount),
];
