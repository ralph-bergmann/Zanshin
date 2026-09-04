// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

// This file owns the Dart half of Story 9.8's two bookmark MUTATIONS: the request
// builders and the two adapters (bookmarkCreate / bookmarkDelete). `dart:ffi`
// stays inside `ffi/` — only the worker isolate calls these adapters.
//
// There is deliberately NO model and NO decoder here: both verbs return the
// shipped `MutationResult`, so `isolate.dart` decodes their envelopes with
// `mutate.dart`'s own `decodeMutationResultEnvelopeInternal`. A second spelling
// of that decoder would be a second thing to keep in sync with one wire table.
//
// The two `names` fields look alike and mean different things — a create name is
// an EXACT, DECODED bookmark name, a delete name is a string PATTERN whose bare
// form is a GLOB. That asymmetry is the CLI's own (`bookmark create` runs its
// names through `parse_bookmark_name`, `bookmark delete` does not) and is
// documented on each adapter rather than smoothed over.

// ── Request-buffer helpers ───────────────────────────────────────────────────

/// Copy [bytes] into a `malloc`-allocated `Pointer<Uint8>`, invoke [fn] with the
/// pointer and byte length, and free the pointer afterward.
///
/// Same ownership discipline as `mutate.dart`'s identical helper (AR-P-5 inbound
/// rule): Rust only borrows the buffer for the duration of the call.
T _withRequestBytes<T>(Uint8List bytes, T Function(ffi.Pointer<ffi.Uint8>, int) fn) {
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
/// A FlatBuffers string is length-prefixed, so a NUL would survive the wire — and
/// then land in a bookmark name or a jj string pattern, where it can only produce
/// a confusing downstream failure. This is the DIRECT-CALLER backstop: the
/// primary guard lives on the calling side, in `ZanshinWorker` and `RepoHandle`,
/// because inside the worker isolate a throw here comes back as
/// `internal.dispatch_error` rather than as the documented [ArgumentError].
void _rejectInteriorNul(String? value, String name) {
  if (value != null && value.codeUnits.contains(0)) {
    throw ArgumentError.value(value, name, 'must not contain an interior NUL (U+0000)');
  }
}

/// Copy the envelope out of a returned token before freeing it.
Uint8List _readToken(ffi.Pointer<ZanshinBuf> token) {
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
}

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_bookmark_create` with the raw `u64` handle and a
/// `BookmarkCreateRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes.
///
/// [names] are EXACT, DECODED bookmark names — the revset quoting the CLI
/// requires is terminal input syntax the GUI replaces (ADR-0003). An empty list,
/// or an empty-string name, is refused by the jj layer as `jj.invalid_input`.
///
/// A `null` [revision] is the wire form of "the user did not supply `-r`", which
/// applies the CLI's own clap default `@`.
Uint8List zanshinBookmarkCreate(int rawHandle, List<String> names, {String? revision}) {
  for (final name in names) {
    _rejectInteriorNul(name, 'names');
  }
  _rejectInteriorNul(revision, 'revision');
  final Uint8List request = fbs.BookmarkCreateRequestObjectBuilder(names: names, revision: revision).toBytes();
  return _withRequestBytes(request, (ptr, len) => _readToken(zanshin_bookmark_create(rawHandle, ptr, len)));
}

/// Call `zanshin_bookmark_delete` with the raw `u64` handle and a
/// `BookmarkDeleteRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes.
///
/// [names] are string PATTERNS, not exact names: a BARE pattern is a GLOB, so
/// deleting a bookmark whose name contains `*`, `?` or `[` needs `exact:"…"`.
/// An empty list is refused by the jj layer as `jj.invalid_input`; a pattern
/// matching nothing SUCCEEDS and writes no operation.
Uint8List zanshinBookmarkDelete(int rawHandle, List<String> names) {
  for (final name in names) {
    _rejectInteriorNul(name, 'names');
  }
  final Uint8List request = fbs.BookmarkDeleteRequestObjectBuilder(names: names).toBytes();
  return _withRequestBytes(request, (ptr, len) => _readToken(zanshin_bookmark_delete(rawHandle, ptr, len)));
}
