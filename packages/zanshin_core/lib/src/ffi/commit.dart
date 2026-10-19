// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'request_bytes.dart';

// This file owns the Dart half of Story 9.49's `commit`: the request builder
// and the adapter. It answers the shared `MutationResult`, decoded through
// `mutate.dart`'s one spelling (`decodeMutationResultEnvelopeInternal`).
// `dart:ffi` stays inside `ffi/` — only the worker isolate calls this adapter.

/// Call `zanshin_commit` with the raw `u64` handle and a `CommitRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.49) —
/// the CLI's `jj commit -m <message> [paths]`.
///
/// [message] is the repeatable `-m` (required; an empty list is `-m ""`).
/// [paths] are repo-relative PREFIXES of the changes the committed `@` keeps
/// (empty = every change).
Uint8List zanshinCommit(int rawHandle, {required List<String> message, List<String> paths = const []}) {
  rejectInteriorNuls(paths, 'paths');
  rejectInteriorNuls(message, 'message');
  final Uint8List request = fbs.CommitRequestObjectBuilder(
    kind: fbs.RequestKind.Commit,
    paths: paths,
    message: message,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_commit(rawHandle, ptr, len));
}
