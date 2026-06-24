// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_op_log` with the raw `u64` handle and an `i64` limit, and
/// return the FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). `limit < 0` means all operations.
Uint8List zanshinOpLog(int rawHandle, int limit) {
  final ffi.Pointer<ZanshinBuf> token = zanshin_op_log(rawHandle, limit);
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
}

// ── Dart models ───────────────────────────────────────────────────────────────

/// One entry in jj's operation log (FR-JJ-7).
///
/// `user`/`host` are UTF-8 by construction (jj-lib guarantees it).
final class Operation {
  const Operation({
    required this.id,
    required this.parentIds,
    required this.timestampMillis,
    required this.tzOffsetMinutes,
    required this.user,
    required this.host,
    required this.description,
    required this.rootOp,
    required this.isSnapshot,
  });

  /// Op id in plain forward-hex form (NOT reverse-hex).
  final String id;

  /// Parent op ids in jj order; empty for the root op; >1 for a DAG fork.
  final List<String> parentIds;

  /// Op end-time, milliseconds since the Unix epoch.
  final int timestampMillis;

  /// Timezone offset, minutes east of UTC.
  final int tzOffsetMinutes;

  /// `metadata.username`; may be empty.
  final String user;

  /// `metadata.hostname`; may be empty.
  final String host;

  /// jj's user-friendly op description; always present, may be empty.
  final String description;

  /// `true` iff this is the op-store root operation.
  final bool rootOp;

  /// `true` if a pure working-copy snapshot op.
  final bool isSnapshot;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode an `OpLog` `Envelope` buffer into a list of [Operation]s.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.opLog`.
@visibleForTesting
List<Operation> decodeOpLogEnvelope(Uint8List bytes) => _decodeOpLogEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
List<Operation> decodeOpLogEnvelopeInternal(Uint8List bytes) => _decodeOpLogEnvelope(bytes);

List<Operation> _decodeOpLogEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.OpLog) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected OpLog payload, got ${env.dataType}',
    );
  }
  return payload.operations?.map(_mapOperation).toList() ?? const [];
}

Operation _mapOperation(fbs.Operation o) => Operation(
  id: o.id ?? '',
  parentIds: o.parentIds?.toList() ?? const [],
  timestampMillis: o.timestampMillis,
  tzOffsetMinutes: o.tzOffsetMinutes,
  user: o.user ?? '',
  host: o.host ?? '',
  description: o.description ?? '',
  rootOp: o.rootOp,
  isSnapshot: o.isSnapshot,
);
