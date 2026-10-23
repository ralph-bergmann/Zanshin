// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'request_bytes.dart';

// This file owns the Dart half of the bookmark MUTATIONS: the request builders
// and the adapters (Story 9.8's bookmarkCreate / bookmarkDelete, Story 9.19's
// bookmarkMove / bookmarkAdvance / bookmarkRename). `dart:ffi` stays inside
// `ffi/` — only the worker isolate calls these adapters.
//
// There is deliberately NO model and NO decoder here: every verb returns the
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
  rejectInteriorNuls(names, 'names');
  rejectInteriorNul(revision, 'revision');
  final Uint8List request = fbs.BookmarkCreateRequestObjectBuilder(
    kind: fbs.RequestKind.BookmarkCreate,
    names: names,
    revision: revision,
  ).toBytes();
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
  rejectInteriorNuls(names, 'names');
  final Uint8List request = fbs.BookmarkDeleteRequestObjectBuilder(
    kind: fbs.RequestKind.BookmarkDelete,
    names: names,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_bookmark_delete(rawHandle, ptr, len)));
}

/// Call `zanshin_bookmark_move` with the raw `u64` handle and a
/// `BookmarkMoveRequest` request buffer (Story 9.19), and return the FlatBuffers
/// `Envelope` bytes.
///
/// [names] are EXACT bookmark names (the CLI's `exact:"…"`), [from] revset
/// texts (`--from`); at least one must be non-empty, else `jj.invalid_input`. A
/// `null` [to] applies the CLI's `--to` default `@`.
Uint8List zanshinBookmarkMove(
  int rawHandle,
  List<String> names, {
  List<String> from = const [],
  String? to,
  bool allowBackwards = false,
}) {
  rejectInteriorNuls(names, 'names');
  rejectInteriorNuls(from, 'from');
  rejectInteriorNul(to, 'to');
  final Uint8List request = fbs.BookmarkMoveRequestObjectBuilder(
    kind: fbs.RequestKind.BookmarkMove,
    names: names,
    from: from,
    to: to,
    allowBackwards: allowBackwards,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_bookmark_move(rawHandle, ptr, len)));
}

/// Call `zanshin_bookmark_advance` with the raw `u64` handle and a
/// `BookmarkAdvanceRequest` request buffer (Story 9.19), and return the
/// FlatBuffers `Envelope` bytes.
///
/// Empty [names] applies the CLI's default candidates
/// (`revsets.bookmark-advance-from`); a `null` [to] applies
/// `revsets.bookmark-advance-to`.
Uint8List zanshinBookmarkAdvance(int rawHandle, {List<String> names = const [], String? to}) {
  rejectInteriorNuls(names, 'names');
  rejectInteriorNul(to, 'to');
  final Uint8List request = fbs.BookmarkAdvanceRequestObjectBuilder(
    kind: fbs.RequestKind.BookmarkAdvance,
    names: names,
    to: to,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_bookmark_advance(rawHandle, ptr, len)));
}

/// Call `zanshin_bookmark_rename` with the raw `u64` handle and a
/// `BookmarkRenameRequest` request buffer (Story 9.19), and return the
/// FlatBuffers `Envelope` bytes. Both names are DECODED names.
Uint8List zanshinBookmarkRename(int rawHandle, String oldName, String newName, {bool overwriteExisting = false}) {
  rejectInteriorNul(oldName, 'oldName');
  rejectInteriorNul(newName, 'newName');
  final Uint8List request = fbs.BookmarkRenameRequestObjectBuilder(
    kind: fbs.RequestKind.BookmarkRename,
    oldName: oldName,
    newName: newName,
    overwriteExisting: overwriteExisting,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_bookmark_rename(rawHandle, ptr, len)));
}
