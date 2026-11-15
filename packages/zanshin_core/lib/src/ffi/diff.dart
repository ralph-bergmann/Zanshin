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
// pins; Story 5.2 the lines' word-level segments, `zanshin_jj::Segment`),
// plus Story 5.8's `zanshinDiff` adapter and Story 10.43's `zanshinDiffLines`
// (one file's unchanged lines, read on demand). `dart:ffi` stays inside `ffi/` —
// only the worker isolate calls the adapter.

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

/// What a [HunkLine] is (mirrors `zanshin_jj::HunkLineKind`): `jj diff`'s
/// default color-words lines (Story 5.10).
enum HunkLineKind {
  /// An unchanged line with both numbers. At `-w` / `-b` also a context line
  /// whose sides differ in whitespace, with the CLI's marks.
  context,

  /// A line with left content only (right content only under a `-------`
  /// conflict term).
  removed,

  /// A line with right content only (left content only under a `-------`
  /// conflict term).
  added,

  /// An inlined line holding content of both sides.
  changed,

  /// A conflict header line of `diff.color-words.conflict = "pair"`: no
  /// numbers, one equal run.
  conflictHeader,
}

/// What a [Segment] is (mirrors `zanshin_jj::SegmentKind`): the CLI's colour
/// labels.
enum SegmentKind {
  /// A token on both sides.
  equal,

  /// A right-side token (left-side under a `-------` conflict term).
  added,

  /// A left-side token (right-side under a `-------` conflict term).
  removed,
}

/// A run of a [HunkLine]'s text with one [kind] (mirrors `zanshin_jj::Segment`),
/// never empty.
final class Segment {
  const Segment({required this.kind, required this.text});

  /// Which side the run is on.
  final SegmentKind kind;

  /// The run's text.
  final String text;
}

/// One line of a [Hunk] as `jj diff`'s color-words format prints it: its
/// [kind], its [left] and [right] line numbers, its [text], which includes its
/// `\n` (a last line without one keeps that state), and its [segments].
final class HunkLine {
  const HunkLine({required this.kind, required this.text, this.segments = const [], this.left, this.right});

  /// What the line is.
  final HunkLineKind kind;

  /// The line's text — its [segments] joined — decoded lossily as UTF-8.
  final String text;

  /// The line's runs (Story 5.2): jj-lib's words, a token on both sides
  /// [SegmentKind.equal], a left-side token [SegmentKind.removed], a
  /// right-side token [SegmentKind.added]. A changed block is inlined when its
  /// words alternate between the sides at most
  /// `diff.color-words.max-inline-alternation` times per group of changed
  /// lines; otherwise it is its left lines, then its right lines, with
  /// block-wide marks. A changed run can be only a line break. Their texts
  /// concatenate exactly to [text], none is empty, and adjacent runs differ in
  /// kind. Empty only for a payload written without segments.
  final List<Segment> segments;

  /// The 1-based left line number the CLI prints (Story 5.10); null when the
  /// line holds no left content and on a [HunkLineKind.conflictHeader]. One
  /// old line spread over several inlined lines repeats its number.
  final int? left;

  /// The 1-based right line number, like [left].
  final int? right;
}

/// One hunk of a [FileDiff] — the color-words lines between two skipped
/// ranges (mirrors `zanshin_jj::Hunk`).
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

  /// Its lines on the left side, 0-based half-open: from the left counter at
  /// its first line to past its largest left number.
  final ({int start, int end}) before;

  /// Its lines on the right side, counted like [before].
  final ({int start, int end}) after;

  /// The source-symbol line of the skipped range before the hunk, as the CLI
  /// prints it after `    ...    `; null for a first hunk without a skipped
  /// range and for a plain `...`.
  final String? symbol;

  /// The file's sections one of its changed lines falls in — the keys
  /// `selectTree` takes. At `-w` / `-b` this can be a whole section the hunk
  /// shows only part of, or empty.
  final List<HunkKey> sections;

  /// The distinct left numbers on its changed lines.
  final int removed;

  /// The distinct right numbers on its changed lines.
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
    this.whitespaceLines = const [],
    this.leftLineCount = 0,
  });

  /// The repo-relative path, in jj's internal `/`-separated form — a copy's or
  /// rename's target.
  final String path;

  /// How the path changed: a copy record's source first, then presence.
  final FileChangeKind kind;

  /// The source path for [FileChangeKind.renamed] and [FileChangeKind.copied];
  /// null for all other kinds.
  final String? fromPath;

  /// Either side's content is binary, checked before the contents are
  /// compared (a mode-only change or rename of a binary file is binary, as
  /// the CLI's `(binary)`): no hunks.
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

  /// At `-w` / `-b` (Story 10.41): every line that changed only in whitespace,
  /// inside or outside the hunks' context, in file order — a
  /// [HunkLineKind.context] line with both numbers and the segments of jj's
  /// word diff of that one pair, always inlined. It also holds every identical
  /// line between two such lines of one matched run, with ONE
  /// [SegmentKind.equal] segment, so a revealed run has no number gap; a line
  /// with no added or removed segment is such an identical line. Empty at
  /// exact, in summary mode, for binary content and under
  /// `diff.color-words.conflict = "pair"` on a conflicted side.
  final List<HunkLine> whitespaceLines;

  /// The number of lines of the left side (Story 10.43), counted as [HunkLine]
  /// numbers count them (a last line without `\n` counts); 0 when either side
  /// is binary or the left side is absent or empty. Kept in summary mode.
  final int leftLineCount;
}

/// A line-level diff between two revisions: `diff`'s files, in order, pinned
/// to the operation and commit(s) it was computed at.
final class Diff {
  const Diff({
    required this.files,
    required this.operationId,
    required this.commitIds,
    this.fromCommitId,
    this.description,
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

  /// The inter-diff forms' description block (Story 10.29 closing run): the
  /// CLI's `JJ-COMMIT-DESCRIPTION` pseudo-file — the from description (`''`
  /// for a created commit) against the commit's, kind modified, no sections.
  /// Never path-filtered; keeps its hunks in summary mode. Null when the
  /// descriptions are equal and for `jj diff`'s forms.
  final FileDiff? description;

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
/// `diff.color-words.context`), [whitespace] `-w` / `-b`, [summary] drops the
/// hunks.
/// [interdiff] reads [from] / [to] as `jj interdiff` does (Story 10.29); with
/// [revision] alone it is `show_inter_diff` with no predecessors — `jj op show
/// --patch`'s created commit: [revision] (exactly one commit) against its
/// parent tree, no copy records. Both fill [Diff.description].
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

/// Call `zanshin_diff_lines` with the raw `u64` handle and a `DiffLinesRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 10.43) —
/// one file's unchanged lines in a left range.
///
/// [revision], [from], [to] and [interdiff] read exactly as [zanshinDiff]'s;
/// [path] is the file (a rename's target, as [FileDiff.path] names it),
/// [whitespace] `-w` / `-b`, and [start] / [end] a 0-based half-open range of
/// left line numbers.
Uint8List zanshinDiffLines(
  int rawHandle, {
  required String path,
  required int start,
  required int end,
  String? revision,
  String? from,
  String? to,
  bool interdiff = false,
  DiffWhitespace whitespace = DiffWhitespace.exact,
}) {
  rejectInteriorNul(revision, 'revision');
  rejectInteriorNul(from, 'from');
  rejectInteriorNul(to, 'to');
  rejectInteriorNul(path, 'path');
  for (final (String name, int value) in [('start', start), ('end', end)]) {
    if (value < 0 || value > 0xFFFFFFFF) {
      throw ArgumentError.value(value, name, 'must fit in 32 bits unsigned');
    }
  }
  final Uint8List request = fbs.DiffLinesRequestObjectBuilder(
    kind: fbs.RequestKind.DiffLines,
    revision: revision,
    from: from,
    to: to,
    interdiff: interdiff,
    path: path,
    whitespace: whitespace.wire,
    start: start,
    end: end,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_diff_lines(rawHandle, ptr, len));
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `Diff` `Envelope` buffer into a [Diff].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.diff`. An out-of-range `HunkLineKind` or
/// `SegmentKind` byte surfaces as the generated accessor's `StateError` (by
/// design: a corrupt buffer, not a refusal).
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
    description: switch (payload.description) {
      final fbs.FileDiff description => _file(description),
      null => null,
    },
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `DiffLines` `Envelope` buffer into its lines (Story 10.43).
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.diffLines`.
@visibleForTesting
List<HunkLine> decodeDiffLinesEnvelope(Uint8List bytes) => decodeDiffLinesEnvelopeInternal(bytes);

/// Internal decoder used by production code.
List<HunkLine> decodeDiffLinesEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.DiffLines) {
    throw ZanshinFfiException('ffi.unknown', 'expected DiffLines payload, got ${env.dataType}');
  }
  return [for (final fbs.HunkLine line in payload.lines ?? const []) _line(line)];
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
  whitespaceLines: [for (final fbs.HunkLine line in file.whitespaceLines ?? const []) _line(line)],
  leftLineCount: file.leftLineCount,
);

Hunk _hunk(fbs.Hunk hunk) => Hunk(
  before: (start: hunk.beforeStart, end: hunk.beforeEnd),
  after: (start: hunk.afterStart, end: hunk.afterEnd),
  symbol: hunk.symbol,
  sections: _keys(hunk.sections),
  removed: hunk.removed,
  added: hunk.added,
  lines: [for (final fbs.HunkLine line in hunk.lines ?? const []) _line(line)],
);

HunkLine _line(fbs.HunkLine line) {
  final String text = line.text ?? '';
  final List<fbs.Segment> segments = line.segments ?? const [];
  return HunkLine(
    kind: switch (line.kind) {
      fbs.HunkLineKind.Context => HunkLineKind.context,
      fbs.HunkLineKind.Removed => HunkLineKind.removed,
      fbs.HunkLineKind.Added => HunkLineKind.added,
      fbs.HunkLineKind.Changed => HunkLineKind.changed,
      fbs.HunkLineKind.ConflictHeader => HunkLineKind.conflictHeader,
    },
    left: line.leftLine == 0 ? null : line.leftLine,
    right: line.rightLine == 0 ? null : line.rightLine,
    text: text,
    segments: [
      for (final fbs.Segment segment in segments)
        Segment(
          kind: switch (segment.kind) {
            fbs.SegmentKind.Equal => SegmentKind.equal,
            fbs.SegmentKind.Added => SegmentKind.added,
            fbs.SegmentKind.Removed => SegmentKind.removed,
          },
          // A lone segment's text is the line's text, so it is not decoded a second time.
          text: segments.length == 1 ? text : segment.text ?? '',
        ),
    ],
  );
}

List<HunkKey> _keys(List<fbs.HunkKey>? keys) => [
  for (final fbs.HunkKey key in keys ?? const [])
    HunkKey(oldStart: key.oldStart, oldCount: key.oldCount, newStart: key.newStart, newCount: key.newCount),
];
