// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import '../ffi/precondition.dart' show Precondition;
import '../ffi/warning.dart' show ZanshinWarning;

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
  /// An exception without a report: [precondition] is `null` and [warnings]
  /// empty. For failures Dart detects in a buffer (a corrupt or mismatched
  /// payload), not for error envelopes.
  const ZanshinFfiException(this.code, [this.context]) : precondition = null, warnings = const [];

  /// An exception with a report — the shape every error envelope decodes to,
  /// the worker-built ones (`ffi.invalid_handle`, `internal.dispatch_error`)
  /// included: [precondition] `null` when the envelope carries none, [warnings]
  /// in wire order (the CLI's print order), empty when there were none. Keeps
  /// the [warnings] list it is given as is.
  const ZanshinFfiException.withReport(
    this.code,
    this.context, {
    required this.precondition,
    required this.warnings,
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

  @override
  String toString() {
    final buf = StringBuffer('ZanshinFfiException($code');
    if (context != null) {
      buf.write(': $context');
    }
    buf.write(')');
    return buf.toString();
  }
}
