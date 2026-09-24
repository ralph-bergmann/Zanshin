// SPDX-License-Identifier: MIT

import 'dart:typed_data';

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
final class ZanshinFfiException implements Exception {
  const ZanshinFfiException(this.code, [this.context]);

  /// Machine-readable error code, e.g. `jj.repo_not_found`.
  final String code;

  /// Optional detail string. May be `null`.
  final String? context;

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
