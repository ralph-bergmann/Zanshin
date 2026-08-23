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
const defaultGraphPrioritize = 'present(@)';

/// Call `zanshin_graph_slice` with the raw `u64` handle, a [revset] and a
/// [prioritize] expression, and return the FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). Both C strings are allocated by Dart via
/// `toNativeUtf8` and freed by Dart via `calloc.free` (AR-P-5 inbound rule —
/// Rust only borrows them for the duration of the call).
///
/// Throws [ArgumentError] if [revset] or [prioritize] contains an interior
/// U+0000: a C string cannot carry it, and `toNativeUtf8` would silently
/// truncate the user-typed expression at the NUL, so Rust would evaluate a
/// shorter expression than the one the caller wrote.
///
/// Error codes: see `docs/ffi-abi.md` § `zanshin_graph_slice`
/// (`ffi.null_pointer` / `ffi.utf8_error` never arise from this adapter —
/// it always passes valid, non-null UTF-8 pointers).
Uint8List zanshinGraphSlice(int rawHandle, String revset, String prioritize) {
  if (revset.codeUnits.contains(0)) {
    throw ArgumentError.value(revset, 'revset', 'must not contain an interior NUL (U+0000)');
  }
  if (prioritize.codeUnits.contains(0)) {
    throw ArgumentError.value(prioritize, 'prioritize', 'must not contain an interior NUL (U+0000)');
  }
  final ffi.Pointer<Utf8> revsetPtr = revset.toNativeUtf8();
  try {
    final ffi.Pointer<Utf8> prioritizePtr = prioritize.toNativeUtf8();
    try {
      final ffi.Pointer<ZanshinBuf> token = zanshin_graph_slice(
        rawHandle,
        revsetPtr.cast(),
        prioritizePtr.cast(),
      );
      final buf = FfiBuffer.fromToken(token);
      try {
        return Uint8List.fromList(buf.bytes);
      } finally {
        buf.dispose(); // inner: free the returned buffer
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
