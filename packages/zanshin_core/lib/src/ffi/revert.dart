// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'request_bytes.dart';

// This file owns the Dart half of Story 9.18's `revert` adapter. It answers
// the shared `MutationResult`, decoded through `mutate.dart`. `dart:ffi` stays
// inside `ffi/` — only the worker isolate calls the adapter.

/// Reject an interior NUL in any of `revert`'s id lists.
void rejectRevertNuls(List<String> revisions, List<String> onto, List<String> insertAfter, List<String> insertBefore) {
  rejectInteriorNuls(revisions, 'revisions');
  rejectInteriorNuls(onto, 'onto');
  rejectInteriorNuls(insertAfter, 'insertAfter');
  rejectInteriorNuls(insertBefore, 'insertBefore');
}

/// Call `zanshin_revert` with the raw `u64` handle and a `RevertRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.18) —
/// the CLI's `jj revert`.
///
/// [revisions] are change ids (`-r`, required); [onto] / [insertAfter] /
/// [insertBefore] are `-o` / `-A` / `-B` (empty = the flag not given; one is
/// required and [onto] excludes the other two).
Uint8List zanshinRevert(
  int rawHandle, {
  List<String> revisions = const [],
  List<String> onto = const [],
  List<String> insertAfter = const [],
  List<String> insertBefore = const [],
}) {
  rejectRevertNuls(revisions, onto, insertAfter, insertBefore);
  final Uint8List request = fbs.RevertRequestObjectBuilder(
    kind: fbs.RequestKind.Revert,
    revisions: revisions,
    onto: onto,
    insertAfter: insertAfter,
    insertBefore: insertBefore,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_revert(rawHandle, ptr, len));
}
