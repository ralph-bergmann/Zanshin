// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;

// No FFI adapter yet: Story 4.6 adds the `zanshin_graph_*` extern fns and the
// worker command. This file owns the Dart half of the GraphSlice wire contract
// (models + decoder) so it needs no `dart:ffi` / `bindings.dart` import.

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

/// One lane-assigned commit row (mirrors `zanshin_graph::Row`).
final class GraphRow {
  const GraphRow({
    required this.commitId,
    required this.lane,
    required this.colorIdx,
    required this.edges,
  });

  /// The commit id this row represents (hex). Rows are keyed by commit id.
  final String commitId;

  /// The lane this commit was placed on.
  final int lane;

  /// Deterministic palette color index (`lane % PALETTE_SIZE`).
  final int colorIdx;

  /// One edge per input parent edge, in the same order.
  final List<GraphRowEdge> edges;
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
/// go through the worker (Story 4.6).
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

/// Internal decoder used by production code (wired in Story 4.6).
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
