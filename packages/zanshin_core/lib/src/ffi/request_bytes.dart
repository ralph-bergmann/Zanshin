// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'ffi_buffer.dart';

// The one spelling of the request-buffer ownership discipline (AR-P-5 inbound
// rule), shared by every FFI adapter file that passes a FlatBuffers request
// buffer across the boundary: `mutate.dart`, `git.dart`, `file.dart`,
// `commit_views.dart`, `workspace.dart` and `bookmark_ops.dart`.
//
// These helpers are package-visible rather than private because each of those
// files previously carried its own byte-identical copy — six places one edit
// could desync. The docs below are deliberately noun-agnostic; the per-noun
// wording ("a jj change id, revset or path", "a git remote name or URL") lived
// only in the copies.

/// Copy [bytes] into a `malloc`-allocated `Pointer<Uint8>`, invoke [fn] with the
/// pointer and byte length, and free the pointer afterward.
///
/// AR-P-5 inbound rule: Rust only borrows the buffer for the duration of the
/// call, so Dart both allocates and frees it.
///
/// [bytes] must be NON-EMPTY. Every caller passes a finished FlatBuffers buffer,
/// which always carries at least a root offset and a vtable, so the precondition
/// holds by construction — but `malloc.allocate<Uint8>(0)` has no guaranteed
/// shape and is not something to rely on. Deliberately NOT special-cased to a
/// `nullptr`: Rust would then answer `ffi.null_pointer`, which is a different
/// observable outcome.
T withRequestBytes<T>(Uint8List bytes, T Function(ffi.Pointer<ffi.Uint8>, int) fn) {
  final ffi.Pointer<ffi.Uint8> ptr = malloc.allocate<ffi.Uint8>(bytes.length);
  ptr.asTypedList(bytes.length).setAll(0, bytes);
  try {
    return fn(ptr, bytes.length);
  } finally {
    malloc.free(ptr);
  }
}

/// Reject an interior NUL in a caller-supplied string.
///
/// A FlatBuffers string is length-prefixed, so a NUL would survive the wire —
/// and then land in a jj identifier, path, pattern, name or URL, where it can
/// only produce a confusing downstream failure. The C-string adapters must
/// reject it outright, and the buffer adapters guard here to keep the whole
/// surface consistent.
///
/// This is the DIRECT-CALLER backstop, not the primary guard. The primary guard
/// lives on the calling side, in `ZanshinWorker` and `RepoHandle`, because
/// inside the worker isolate a throw here comes back as `internal.dispatch_error`
/// rather than as the documented [ArgumentError]. That is why the check is
/// deliberately spelled at two layers.
void rejectInteriorNul(String? value, String name) {
  if (value != null && value.codeUnits.contains(0)) {
    throw ArgumentError.value(value, name, 'must not contain an interior NUL (U+0000)');
  }
}

/// The list form of [rejectInteriorNul]: apply the same guard to every entry of
/// [values], reporting the OFFENDING ENTRY as the [ArgumentError]'s
/// `invalidValue` and the list's own parameter [name] as its `name`.
///
/// Exists because every list-valued parameter otherwise hand-writes the same
/// `for` loop over the scalar form — the loop is what desyncs, not the guard.
void rejectInteriorNuls(Iterable<String> values, String name) {
  for (final value in values) {
    rejectInteriorNul(value, name);
  }
}

/// Copy the envelope out of a returned token and free the token.
///
/// [token] must be non-null. `FfiBuffer.fromToken` throws an [ArgumentError] on
/// `nullptr`, and inside the worker isolate that surfaces as
/// `internal.dispatch_error` rather than as an FFI error envelope — so a null
/// token is a cdylib bug, not a refusal path a caller can handle. Every
/// `extern "C"` wrapper returns a real token, including on its error arms.
Uint8List readToken(ffi.Pointer<ZanshinBuf> token) {
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
}

/// Invoke [call] with the request bytes and copy the returned envelope out of
/// the token before freeing it.
Uint8List callWithRequest(
  Uint8List request,
  ffi.Pointer<ZanshinBuf> Function(ffi.Pointer<ffi.Uint8>, int) call,
) => withRequestBytes(request, (ptr, len) => readToken(call(ptr, len)));
