// SPDX-License-Identifier: MIT

import 'dart:isolate';
import 'dart:typed_data';

import '../ffi/precondition.dart' show Precondition;
import '../ffi/revset_search.dart' show RevsetErrorDetail, RevsetSpan;
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
  /// An exception without a report: [precondition] is `null`, [warnings],
  /// [hints] and [leftBehind] empty. For failures Dart detects in a buffer (a
  /// corrupt or mismatched payload), not for error envelopes.
  const ZanshinFfiException(this.code, [this.context])
    : precondition = null,
      warnings = const [],
      hints = const [],
      leftBehind = const [],
      revsetError = null;

  /// An exception with a report — the shape every error envelope decodes to,
  /// the worker-built ones (`ffi.invalid_handle`, `internal.dispatch_error`)
  /// included: [precondition] `null` when the envelope carries none, [warnings]
  /// in wire order (the CLI's print order), empty when there were none, and
  /// the error's [hints] (Story 9.56), empty when it has none, and what a
  /// failed creation left on disk ([leftBehind], Stories 9.57/9.58), empty
  /// otherwise, and a revset error's structured [revsetError] (Story 9.25),
  /// `null` otherwise. Keeps the [warnings], [hints] and [leftBehind] lists it
  /// is given as is.
  const ZanshinFfiException.withReport(
    this.code,
    this.context, {
    required this.precondition,
    required this.warnings,
    this.hints = const [],
    this.leftBehind = const [],
    this.revsetError,
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

  /// The paths a FAILED creation — `initRepo` (Story 9.58) or `convert`
  /// (Story 9.57) — created and left on disk, outermost first: the
  /// destination the call created (an existing one is reused and never
  /// listed), then the workspace's `.jj/` (only when the call created it) —
  /// each only when it still exists. A later entry may lie inside an earlier
  /// one (the created destination and its `.jj/`). The paths are canonical.
  /// Nothing is deleted on a failure: the disk is as `jj git init` leaves it,
  /// and the UI may offer to remove these. A failure after the `trunk()` alias
  /// step also leaves the secure-config directory
  /// `<config_dir>/jj/repos/<config-id>/`, and a failed new colocated init the
  /// `.git/` it created; neither is listed. Empty for every other error — a
  /// `watcher.io_error` after a successful creation included (the repository
  /// is complete). Unmodifiable on an exception decoded from an error
  /// envelope.
  final List<String> leftBehind;

  /// The structured form of a `jj.revset_parse_error` /
  /// `jj.revset_resolution_error` (Story 9.25) — kind, byte span, the named
  /// symbol and jj-lib's similar names — from `graphTopology`, `findChanges`
  /// and a `revsetCounts` entry's own error; `null` for every other error.
  final RevsetErrorDetail? revsetError;

  @override
  String toString() {
    final buf = StringBuffer('ZanshinFfiException($code');
    if (context != null) {
      buf.write(': $context');
    }
    if (hints.isNotEmpty) {
      buf.write('; hints: ${hints.join(' | ')}');
    }
    if (leftBehind.isNotEmpty) {
      buf.write('; left behind: ${leftBehind.join(' | ')}');
    }
    final RevsetErrorDetail? revset = revsetError;
    if (revset != null) {
      buf.write('; revset: ${revset.kind.name}');
      final RevsetSpan? span = revset.span;
      if (span != null) {
        buf.write(' at ${span.offset}+${span.length ?? '?'}');
      }
      if (revset.symbol != null) {
        buf.write(' `${revset.symbol}`');
      }
      if (revset.message != null) {
        buf.write(' "${revset.message}"');
      }
    }
    buf.write(')');
    return buf.toString();
  }
}
