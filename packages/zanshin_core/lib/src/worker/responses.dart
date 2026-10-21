// SPDX-License-Identifier: MIT

import 'dart:isolate';
import 'dart:typed_data';

import '../ffi/precondition.dart' show Precondition;
import '../ffi/warning.dart' show ZanshinWarning;
import '../graph_layout/layout_request.dart' show LayoutContractException;

/// Typed response hierarchy sent from the worker isolate to the main isolate.
///
/// Raw handles never appear here — the worker substitutes an opaque `handleId`
/// for open/init/clone successes (Model A). Error envelopes and read-payload
/// responses are forwarded as raw FlatBuffers bytes.
sealed class WorkerResponse {
  const WorkerResponse();
}

/// Signals that an open/init/clone/convert command succeeded.
///
/// The repository is now tracked in the worker's handle table under [handleId].
/// Main references it via `handleId` (wrapped in a `RepoHandle`) — the raw `u64`
/// pointer is consumed in the worker and never exposed on the main side.
final class HandleResult extends WorkerResponse {
  const HandleResult(this.handleId, this.bytes);

  /// Opaque dense id in the worker's `Map<int, int>` handle table.
  final int handleId;

  /// The ok `Envelope` bytes the handle came in. For a creation
  /// (init/clone/convert) the creating call's report rides them (`warnings`,
  /// and `precondition` for convert; Story 9.33); `openRepo` ignores them.
  final Uint8List bytes;
}

/// Carries raw FlatBuffers `Envelope` bytes.
///
/// Used for error envelopes from any command and for read-payload responses
/// from Story-3.4b read commands. The bytes are a heap-owned [Uint8List] copy
/// safe to cross port boundaries and outliving any native buffer.
final class BufferResult extends WorkerResponse {
  const BufferResult(this.bytes);

  /// Raw `Envelope` bytes — decode with `Envelope(bytes)` from the generated
  /// FlatBuffers accessors.
  final Uint8List bytes;
}

/// Carries a FlatBuffers `Envelope` as [TransferableTypedData] — the graph
/// topology's reply (Story 4.12).
///
/// One copy across the isolate boundary instead of two: the worker reads the
/// native buffer `zanshin_graph_topology` returned through a view, copies it
/// ONCE into [data], frees the native buffer and sends this; the receiving side
/// calls `data.materialize()` exactly once, which hands over the bytes without a
/// further copy. Every other reply is a [BufferResult], which costs the
/// `readToken` copy out of native memory plus the `SendPort` copy.
final class TransferResult extends WorkerResponse {
  const TransferResult(this.data);

  /// The `Envelope` bytes; materialize exactly once.
  final TransferableTypedData data;
}

/// Carries a graph layout's reply (Story 4.11): the topology envelope and the layout's grid,
/// each as [TransferableTypedData].
///
/// One copy each across the isolate boundary: the worker copies the native topology envelope
/// ONCE into [topology] and the grid buffer ONCE into [grid]; the receiving side materializes
/// each exactly once, without a further copy. [topology] is always there — an error envelope when
/// the topology call failed. [grid] is `null` when there is no layout: the topology call failed,
/// its buffer could not be read, or the engine refused its input — then [violation] carries the
/// [LayoutContractException], which crosses as the object itself.
final class GraphLayoutResult extends WorkerResponse {
  const GraphLayoutResult({required this.topology, required this.grid, required this.violation});

  /// The `zanshin_graph_topology` `Envelope` bytes; materialize exactly once.
  final TransferableTypedData topology;

  /// The grid buffer (`GraphGridView`'s format), or `null` without a layout; materialize exactly
  /// once.
  final TransferableTypedData? grid;

  /// The contract violation the engine found in the topology's values, or `null`.
  final LayoutContractException? violation;
}

/// Thrown on the main side when the worker reports a failed FFI call
/// (`Envelope.ok == false`).
///
/// [code] follows the `<domain>.<reason>` taxonomy (AR-P-4).
/// [context] is optional human-readable detail (e.g. the offending path).
/// Never put user secrets in [code]; paths and ids go into [context].
///
/// It also carries what the failed call reported before it failed (Story 9.35)
/// — every command, handle-scoped, handle-less or creation, the same way: the
/// error envelope's [precondition] (the pre-verb snapshot report, PARTIAL up to
/// the failing step) and its [warnings]. A refused verb's snapshot may already
/// have written operations; this is where the facts the jj CLI would have
/// printed land when the command itself failed.
final class ZanshinFfiException implements Exception {
  /// An exception without a report: [precondition] is `null`, [warnings] and
  /// [hints] empty. For failures Dart detects in a buffer (a corrupt or
  /// mismatched payload), not for error envelopes.
  const ZanshinFfiException(this.code, [this.context]) : precondition = null, warnings = const [], hints = const [];

  /// An exception with a report — the shape every error envelope decodes to,
  /// the worker-built ones (`ffi.invalid_handle`, `internal.dispatch_error`)
  /// included: [precondition] `null` when the envelope carries none, [warnings]
  /// in wire order (the CLI's print order), empty when there were none, and
  /// the error's [hints] (Story 9.56), empty when it has none. Keeps the
  /// [warnings] and [hints] lists it is given as is.
  const ZanshinFfiException.withReport(
    this.code,
    this.context, {
    required this.precondition,
    required this.warnings,
    this.hints = const [],
  });

  /// Machine-readable error code, e.g. `jj.repo_not_found`.
  final String code;

  /// Optional detail string. May be `null`.
  final String? context;

  /// The failed call's pre-verb snapshot report — PARTIAL: every field up to
  /// the failing step is filled — or `null` when the call ran no precondition
  /// (or failed before it). When a failed handle-scoped call carried one, it
  /// is the same report `RepoHandle.lastPrecondition` holds. Its own
  /// `warnings` are always empty: the call's warnings are [warnings].
  final Precondition? precondition;

  /// The failed call's warnings, in the jj CLI's print order; empty when there
  /// were none — e.g. `jj.clone_cleanup_failed` from a clone that could not
  /// remove what it had created. Unmodifiable on an exception decoded from an
  /// error envelope ([ZanshinFfiException.withReport] keeps the list it is
  /// given).
  final List<ZanshinWarning> warnings;

  /// The jj CLI's hint lines for this error (Story 9.56) — verbatim (a line
  /// may hold newlines) and in the CLI's order, for the UI to show as they
  /// are; empty when the CLI prints none. Never part of [context].
  /// Unmodifiable on an exception decoded from an error envelope.
  final List<String> hints;

  @override
  String toString() {
    final buf = StringBuffer('ZanshinFfiException($code');
    if (context != null) {
      buf.write(': $context');
    }
    if (hints.isNotEmpty) {
      buf.write('; hints: ${hints.join(' | ')}');
    }
    buf.write(')');
    return buf.toString();
  }
}
