// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'select_tree.dart' show HunkKey;
import 'status.dart' show FileChangeKind, mapChangeKind;
import 'warning.dart';

// This file owns the Dart half of Story 5.5's line-level `Diff` payload: the
// models mirroring `zanshin_jj::RevisionDiff` / `FileDiff` / `Hunk` /
// `HunkLine` and their decoder (Story 5.6 adds kinds, counts, fingerprints and
// pins), plus Story 5.8's `zanshinDiff` adapter. `dart:ffi` stays inside
// `ffi/` — only the worker isolate calls the adapter.

// ── Models ───────────────────────────────────────────────────────────────────

/// How a diff compares lines (mirrors `zanshin_jj::Whitespace`).
enum DiffWhitespace {
  /// Literally.
  exact,

  /// Ignoring every whitespace occurrence (`-w`, `--ignore-all-space`).
  ignoreAllSpace,

  /// Ignoring changes in the amount of whitespace (`-b`,
  /// `--ignore-space-change`).
  ignoreSpaceChange;

  /// The value this crosses the wire as.
  @visibleForTesting
  fbs.DiffWhitespace get wire => switch (this) {
    DiffWhitespace.exact => fbs.DiffWhitespace.Exact,
    DiffWhitespace.ignoreAllSpace => fbs.DiffWhitespace.IgnoreAllSpace,
    DiffWhitespace.ignoreSpaceChange => fbs.DiffWhitespace.IgnoreSpaceChange,
  };
}

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
  /// plus a binary change's contents and a mode change's marker, lowercase
  /// hex — equal changes at shifted line numbers share it. It depends
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
    required this.commitIds,
    this.fromCommitId,
    this.warnings = const [],
  });

  /// The changed files, in order.
  final List<FileDiff> files;

  /// The operation the diff was read at, full hex.
  final String operationId;

  /// The right side's commits, full hex: the `-r` set's heads in revset order
  /// (empty for an empty set) or `[to]` (`--from`/`--to`).
  final List<String> commitIds;

  /// `from` for `--from`/`--to`; null for the revision form.
  final String? fromCommitId;

  /// The call's warnings; empty when there were none.
  final List<ZanshinWarning> warnings;
}

// ── FFI adapter ──────────────────────────────────────────────────────────────

/// Call `zanshin_diff` with the raw `u64` handle and a `DiffRequest` request
/// buffer, and return the FlatBuffers `Envelope` bytes (Story 5.8) — `jj diff`
/// as data.
///
/// [revision] is `-r` (`null`: `@`), a revset diffed as one set — the merged
/// parents of its roots against its merged heads (a set with gaps is refused,
/// `jj.invalid_input`); [from] / [to] are `--from` / `--to` — either set
/// selects that form, the other side `null` = `@`; each is a revset that must
/// resolve to exactly one commit (a commit id reaches a hidden commit; parse
/// diagnostics land on the call's warnings); [revision] together with either
/// is refused
/// (`jj.invalid_input`). [paths] are repo-relative prefixes (empty: every
/// path), [context] the context lines (`null`: the effective
/// `diff.git.context`), [whitespace] `-w` / `-b`, [summary] drops the hunks.
/// [interdiff] reads [from] / [to] as `jj interdiff` does (Story 10.29).
Uint8List zanshinDiff(
  int rawHandle, {
  String? revision,
  String? from,
  String? to,
  List<String> paths = const [],
  int? context,
  DiffWhitespace whitespace = DiffWhitespace.exact,
  bool summary = false,
  bool interdiff = false,
}) {
  rejectInteriorNul(revision, 'revision');
  rejectInteriorNul(from, 'from');
  rejectInteriorNul(to, 'to');
  rejectInteriorNuls(paths, 'paths');
  if (context != null && context < 0) {
    throw ArgumentError.value(context, 'context', 'must not be negative');
  }
  if (context != null && context > 0xFFFFFFFF) {
    throw ArgumentError.value(context, 'context', 'must fit in 32 bits');
  }
  final Uint8List request = fbs.DiffRequestObjectBuilder(
    kind: fbs.RequestKind.Diff,
    revision: revision,
    from: from,
    to: to,
    paths: paths,
    context: context == null ? null : fbs.DiffContextObjectBuilder(value: context),
    whitespace: whitespace.wire,
    summary: summary,
    interdiff: interdiff,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_diff(rawHandle, ptr, len));
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `Diff` `Envelope` buffer into a [Diff].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.diff`. An out-of-range `HunkLineKind` byte
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
    commitIds: [...?payload.commitIds],
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
