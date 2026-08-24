// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

// This file owns the Dart half of the GraphSlice wire contract: the
// `zanshin_graph_slice` FFI adapter (Story 4.6), the models, and the decoder.
// `dart:ffi` stays inside `ffi/` — only the worker isolate calls the adapter.

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// The CLI-default branch-prioritisation revset, pre-filled by
/// `RepoHandle.graphSlice` and editable by the caller (FR-JJ-17).
///
/// Mirrors `zanshin_jj::DEFAULT_GRAPH_PRIORITIZE` — `jj log`'s
/// `revsets.log-graph-prioritize` default. `'none()'` is the canonical
/// "no prioritisation" value; a blank expression is a `jj.revset_parse_error`.
///
/// This is the BUILTIN default. The user's config may override it — prefer
/// `RepoHandle.logDefaults()` (Story 4.9), whose `logGraphPrioritize` is the
/// effective value their own CLI would apply.
const defaultGraphPrioritize = 'present(@)';

/// The CLI-default log revset (`revsets.log`) — the rows `jj log` shows without
/// `-r`. Mirrors `zanshin_jj::DEFAULT_LOG_REVSET`.
///
/// A pre-fill for the caller's `revset`, never applied silently (FR-JJ-17); the
/// UI passes `revset` explicitly.
///
/// This is the BUILTIN default. The user's config may override it — prefer
/// `RepoHandle.logDefaults()` (Story 4.9), whose `log` is the effective value
/// their own CLI would apply.
const defaultLogRevset = 'present(@) | ancestors(immutable_heads().., 2) | trunk()';

/// The CLI-default for rendering elided ancestry as synthetic "(elided
/// revisions)" rows, pre-filled by `RepoHandle.graphSlice` and editable by the
/// caller (FR-JJ-17).
///
/// Mirrors the CLI's `ui.log-synthetic-elided-nodes` default. `false` restores
/// plain `GraphEdgeKind.indirect` edges with no synthetic rows.
///
/// This is the BUILTIN default. The user's config may override it — prefer
/// `RepoHandle.logDefaults()` (Story 4.9), whose `syntheticElided` is the
/// effective value their own CLI would apply.
const defaultSyntheticElided = true;

/// The CLI-default shortest-prefix disambiguation set, pre-filled by
/// `RepoHandle.graphSlice` and editable by the caller (FR-JJ-17).
///
/// The CLI's `revsets.short-prefixes` falls back to `revsets.log`, so this is the
/// same expression as [defaultLogRevset]. An EMPTY string DISABLES disambiguation
/// (full-index prefix lengths) — the CLI's toggle semantic, deliberately unlike
/// [defaultGraphPrioritize], where a blank expression is a parse error.
///
/// This is the BUILTIN default. The user's config may override it — prefer
/// `RepoHandle.logDefaults()` (Story 4.9), whose `shortPrefixes` is the
/// effective value their own CLI would apply (it follows `revsets.log` when
/// `revsets.short-prefixes` is unset).
const String defaultShortPrefixes = defaultLogRevset;

/// Call `zanshin_graph_slice` with the raw `u64` handle, a [revset], a
/// [prioritize] expression, the [syntheticElided] toggle and a [shortPrefixes]
/// expression, and return the FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). All three C strings are allocated by Dart via
/// `toNativeUtf8` and freed by Dart via `calloc.free` (AR-P-5 inbound rule —
/// Rust only borrows them for the duration of the call).
///
/// Throws [ArgumentError] if [revset], [prioritize] or [shortPrefixes] contains
/// an interior U+0000: a C string cannot carry it, and `toNativeUtf8` would
/// silently truncate the user-typed expression at the NUL, so Rust would
/// evaluate a shorter expression than the one the caller wrote.
///
/// Error codes: see `docs/ffi-abi.md` § `zanshin_graph_slice`
/// (`ffi.null_pointer` / `ffi.utf8_error` never arise from this adapter —
/// it always passes valid, non-null UTF-8 pointers).
// WHY(named trailing parameters): `avoid_positional_boolean_parameters` forbids a
// positional `bool`, so the two Story-4.8 parameters are named while the pre-4.8
// positional prefix stays put — the C signature's order is unchanged.
Uint8List zanshinGraphSlice(
  int rawHandle,
  String revset,
  String prioritize, {
  required bool syntheticElided,
  required String shortPrefixes,
}) {
  if (revset.codeUnits.contains(0)) {
    throw ArgumentError.value(revset, 'revset', 'must not contain an interior NUL (U+0000)');
  }
  if (prioritize.codeUnits.contains(0)) {
    throw ArgumentError.value(prioritize, 'prioritize', 'must not contain an interior NUL (U+0000)');
  }
  if (shortPrefixes.codeUnits.contains(0)) {
    throw ArgumentError.value(shortPrefixes, 'shortPrefixes', 'must not contain an interior NUL (U+0000)');
  }
  final ffi.Pointer<Utf8> revsetPtr = revset.toNativeUtf8();
  try {
    final ffi.Pointer<Utf8> prioritizePtr = prioritize.toNativeUtf8();
    try {
      final ffi.Pointer<Utf8> shortPrefixesPtr = shortPrefixes.toNativeUtf8();
      try {
        final ffi.Pointer<ZanshinBuf> token = zanshin_graph_slice(
          rawHandle,
          revsetPtr.cast(),
          prioritizePtr.cast(),
          syntheticElided,
          shortPrefixesPtr.cast(),
        );
        final buf = FfiBuffer.fromToken(token);
        try {
          return Uint8List.fromList(buf.bytes);
        } finally {
          buf.dispose(); // inner: free the returned buffer
        }
      } finally {
        calloc.free(shortPrefixesPtr);
      }
    } finally {
      calloc.free(prioritizePtr); // each C string is freed by its own finally
    }
  } finally {
    calloc.free(revsetPtr);
  }
}

// ── Dart models ───────────────────────────────────────────────────────────────

/// How a graph edge's target was classified by the revset-graph stream
/// (mirrors `zanshin_graph::EdgeKind`).
enum GraphEdgeKind {
  /// The parent is in the revset.
  direct,

  /// The direct parent was elided from the revset; the edge points at the
  /// closest in-set ancestor. Renderers may draw it dashed.
  indirect,

  /// The edge leads outside the revset; no lane is ever reserved for it.
  /// Renderers may draw it as a stub.
  missing,
}

/// One routed parent edge of a [GraphRow] (mirrors `zanshin_graph::RowEdge`).
final class GraphRowEdge {
  const GraphRowEdge({
    required this.target,
    required this.targetLane,
    required this.kind,
  });

  /// The parent commit id (hex).
  final String target;

  /// The lane this edge is routed to. `null` iff [kind] is
  /// [GraphEdgeKind.missing] — a missing edge never lands in a lane (the wire
  /// carries a `0` placeholder; presence rides on `kind`).
  final int? targetLane;

  /// How the edge was classified.
  final GraphEdgeKind kind;
}

/// One lane passing vertically THROUGH a [GraphRow] (mirrors
/// `zanshin_graph::ActiveLane`) — it neither starts nor ends at that row's node.
final class GraphActiveLane {
  const GraphActiveLane({required this.lane, required this.kind});

  /// The lane the segment occupies. Its color is `lane % PALETTE_SIZE`.
  final int lane;

  /// The kind of the edge that opened the segment (so a renderer can dash an
  /// elided pass-through without reading any neighbouring row).
  final GraphEdgeKind kind;
}

/// One bookmark or tag entry on a [GraphRowMeta] (mirrors
/// `zanshin_jj::CommitRef`).
///
/// The CLI renders `name`, then `@remote` for a remote entry, then `??` when
/// [conflicted] or `*` when a local entry is not [synced]. Which glyph (if any)
/// is drawn is the UI's decision.
final class GraphCommitRef {
  const GraphCommitRef({
    required this.name,
    required this.remote,
    required this.synced,
    required this.conflicted,
  });

  /// Bookmark or tag name.
  final String name;

  /// The remote this entry belongs to; `null` for the local entry.
  final String? remote;

  /// Local entry: every tracking remote agrees with the local target. Remote
  /// entry: the remote is tracked AND agrees with the local target.
  final bool synced;

  /// This entry's ref target is a conflict (more than one added commit).
  final bool conflicted;
}

/// `jj log`-parity display metadata for one commit row (mirrors
/// `zanshin_jj::CommitMeta`), from the same head-resolved snapshot as the lanes.
final class GraphRowMeta {
  const GraphRowMeta({
    required this.changeId,
    required this.changeIdPrefixLen,
    required this.commitIdPrefixLen,
    required this.changeOffset,
    required this.authorName,
    required this.authorEmail,
    required this.committerTimestampMillis,
    required this.committerTzOffsetMinutes,
    required this.bookmarks,
    required this.tags,
    required this.workingCopies,
    required this.workingCopy,
    required this.immutable,
    required this.conflict,
    required this.empty,
    required this.hidden,
    required this.divergent,
    required this.root,
    required this.descriptionFirstLine,
  });

  /// Change id in jj reverse-hex display form (divergent changes share it).
  final String changeId;

  /// Shortest unique prefix length of [changeId], within the `shortPrefixes`
  /// disambiguation set (or the full index when it is disabled).
  final int changeIdPrefixLen;

  /// Shortest unique prefix length of [GraphRow.commitId], same scoping.
  final int commitIdPrefixLen;

  /// Index of this commit among the commits sharing its change id, or `null`
  /// when jj-lib yields none (the wire's presence pair restores the `null`).
  /// The CLI renders it (`/<offset>`) only when [hidden] or [divergent].
  final int? changeOffset;

  /// Author name; may be empty (jj allows it).
  final String authorName;

  /// Author email; may be empty (jj allows it). The CLI's compact log shows it.
  final String authorEmail;

  /// The **committer** timestamp, millis since the Unix epoch.
  final int committerTimestampMillis;

  /// Timezone offset of the committer timestamp, minutes east of UTC.
  final int committerTzOffsetMinutes;

  /// Bookmarks pointing at this commit, CLI-filtered (a tracked-and-synced
  /// remote entry is not part of a `jj log` row and is not emitted).
  final List<GraphCommitRef> bookmarks;

  /// Tags pointing at this commit, same shape and filter.
  final List<GraphCommitRef> tags;

  /// Names of the workspaces whose working-copy commit this is. Always empty in
  /// a single-workspace repo (the CLI's guard).
  final List<String> workingCopies;

  /// This workspace's `@`.
  final bool workingCopy;

  /// Contained in `::(immutable_heads() | root())`.
  final bool immutable;

  /// The commit's tree has unresolved conflicts.
  final bool conflict;

  /// The tree equals the merged parent trees (description is not considered).
  final bool empty;

  /// The commit is not visible.
  final bool hidden;

  /// The change id resolves to more than one visible commit.
  final bool divergent;

  /// The repository's root commit.
  final bool root;

  /// First line of the description; `''` when the description is empty
  /// (the "(no description set)" placeholder is UI text).
  final String descriptionFirstLine;
}

/// One lane-assigned commit row (mirrors `zanshin_graph::Row`).
final class GraphRow {
  const GraphRow({
    required this.commitId,
    required this.lane,
    required this.colorIdx,
    required this.edges,
    required this.activeLanes,
    required this.syntheticElided,
    required this.meta,
  });

  /// The commit id this row represents (hex). On a synthetic elided row this is
  /// the ELIDED TARGET's commit id.
  ///
  /// NOT a unique row key while [syntheticElided] rows are enabled (the
  /// default): the synthetic row and the real commit it stands for share this
  /// id, and the child's [GraphRowEdge.target] names it with no synthetic
  /// marker. A synthetic row always sits IMMEDIATELY after the child that
  /// elided to it, and [lane] / [GraphRowEdge.targetLane] are the linkage. Key
  /// rows by position, or by `(commitId, syntheticElided)`.
  final String commitId;

  /// The lane this commit was placed on.
  final int lane;

  /// Deterministic palette color index (`lane % PALETTE_SIZE`).
  final int colorIdx;

  /// One edge per input parent edge, in the same order.
  final List<GraphRowEdge> edges;

  /// Lanes carrying a vertical segment THROUGH this row, ascending. Together
  /// with [lane] and [edges] this is everything a renderer needs to paint the
  /// row's complete graph cross-section without any neighbouring row.
  final List<GraphActiveLane> activeLanes;

  /// This is a synthetic "(elided revisions)" row, not a real commit.
  final bool syntheticElided;

  /// `jj log`-parity display metadata; `null` iff [syntheticElided].
  final GraphRowMeta? meta;
}

/// A slice of the lane-assigned commit graph, in stream (`jj log`) order.
final class GraphSlice {
  const GraphSlice({required this.rows, required this.totalRows});

  /// Rows in stream order.
  final List<GraphRow> rows;

  /// Total row count; equals `rows.length` under WIP return-all semantics.
  final int totalRows;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `GraphSlice` `Envelope` buffer into a [GraphSlice].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.graphSlice`.
///
/// A `GraphEdgeKind` byte outside `0..=2` surfaces as the generated `StateError`
/// from `GraphEdgeKind.fromValue`, not as a [ZanshinFfiException]. This is by
/// design (same rule as `RepoKind` in `repo_detect.dart`): both sides are
/// generated from one schema and the Rust producer only emits `0..=2`, so an
/// out-of-range byte means cdylib/bindings version-skew or memory corruption —
/// a programming error that must crash loudly, not a recoverable condition.
/// The `avoid_catching_errors` lint correctly forbids converting it.
@visibleForTesting
GraphSlice decodeGraphSliceEnvelope(Uint8List bytes) => _decodeGraphSliceEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`
/// (`ZanshinWorker.graphSlice`).
GraphSlice decodeGraphSliceEnvelopeInternal(Uint8List bytes) => _decodeGraphSliceEnvelope(bytes);

GraphSlice _decodeGraphSliceEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.GraphSlice) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected GraphSlice payload, got ${env.dataType}',
    );
  }
  return GraphSlice(
    rows: payload.rows?.map(_mapRow).toList() ?? const [],
    totalRows: payload.totalRows,
  );
}

GraphRow _mapRow(fbs.GraphRow r) => GraphRow(
  commitId: r.commitId ?? '',
  lane: r.lane,
  colorIdx: r.colorIdx,
  edges: r.edges?.map(_mapEdge).toList() ?? const [],
  activeLanes: r.activeLanes?.map(_mapActiveLane).toList() ?? const [],
  syntheticElided: r.syntheticElided,
  // Absent iff the row is a synthetic elided row (null-for-absence).
  meta: r.meta == null ? null : _mapMeta(r.meta!),
);

GraphActiveLane _mapActiveLane(fbs.GraphActiveLane l) => GraphActiveLane(lane: l.lane, kind: _mapEdgeKind(l.kind));

GraphCommitRef _mapCommitRef(fbs.GraphCommitRef r) => GraphCommitRef(
  name: r.name ?? '',
  remote: r.remote, // absent for the local entry
  synced: r.synced,
  conflicted: r.conflicted,
);

GraphRowMeta _mapMeta(fbs.GraphRowMeta m) => GraphRowMeta(
  changeId: m.changeId ?? '',
  changeIdPrefixLen: m.changeIdPrefixLen,
  commitIdPrefixLen: m.commitIdPrefixLen,
  // Presence pair: the wire carries a 0 placeholder when the flag is clear.
  changeOffset: m.hasChangeOffset ? m.changeOffset : null,
  authorName: m.authorName ?? '',
  authorEmail: m.authorEmail ?? '',
  committerTimestampMillis: m.committerTimestampMillis,
  committerTzOffsetMinutes: m.committerTzOffsetMinutes,
  bookmarks: m.bookmarks?.map(_mapCommitRef).toList() ?? const [],
  tags: m.tags?.map(_mapCommitRef).toList() ?? const [],
  workingCopies: m.workingCopies?.toList() ?? const [],
  workingCopy: m.workingCopy,
  immutable: m.immutable,
  conflict: m.conflict,
  empty: m.empty,
  hidden: m.hidden,
  divergent: m.divergent,
  root: m.root,
  descriptionFirstLine: m.descriptionFirstLine ?? '',
);

GraphRowEdge _mapEdge(fbs.GraphRowEdge e) {
  final GraphEdgeKind kind = _mapEdgeKind(e.kind);
  return GraphRowEdge(
    target: e.target ?? '',
    targetLane: kind == GraphEdgeKind.missing ? null : e.targetLane,
    kind: kind,
  );
}

GraphEdgeKind _mapEdgeKind(fbs.GraphEdgeKind kind) => switch (kind) {
  fbs.GraphEdgeKind.Direct => GraphEdgeKind.direct,
  fbs.GraphEdgeKind.Indirect => GraphEdgeKind.indirect,
  fbs.GraphEdgeKind.Missing => GraphEdgeKind.missing,
};
