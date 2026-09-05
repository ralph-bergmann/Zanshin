// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'request_bytes.dart';

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

// The shared `rejectInteriorNul` calls below are the DIRECT-CALLER backstop: the
// primary guard lives on the calling side, in `ZanshinWorker` and `RepoHandle`,
// because inside the worker isolate a throw here comes back as
// `internal.dispatch_error` rather than as the documented `ArgumentError`.

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
    rejectInteriorNul(name, 'names');
  }
  rejectInteriorNul(revision, 'revision');
  final Uint8List request = fbs.BookmarkCreateRequestObjectBuilder(names: names, revision: revision).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_bookmark_create(rawHandle, ptr, len)));
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
    rejectInteriorNul(name, 'names');
  }
  final Uint8List request = fbs.BookmarkDeleteRequestObjectBuilder(names: names).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_bookmark_delete(rawHandle, ptr, len)));
}
