// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_bookmarks` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). No CString argument: bookmarks is handle-only,
/// exactly like `zanshinStatus`.
Uint8List zanshinBookmarks(int rawHandle) {
  final ffi.Pointer<ZanshinBuf> token = zanshin_bookmarks(rawHandle);
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
}

// ── Dart models ───────────────────────────────────────────────────────────────

/// Whether a bookmark is local-only or a tracked remote bookmark.
///
/// Modelled as a sealed class so that a [RemoteBookmark] with no remote name
/// is unrepresentable — illegal state is a compile-time error, not a runtime
/// `null`-check.
sealed class BookmarkKind {
  const BookmarkKind();
}

/// A bookmark that exists only in the local repository.
final class LocalBookmark extends BookmarkKind {
  const LocalBookmark();
}

/// A tracked remote bookmark on [remoteName].
final class RemoteBookmark extends BookmarkKind {
  const RemoteBookmark(this.remoteName);

  /// The remote this bookmark tracks (e.g. `"origin"`). Always present for a
  /// `Remote` entry — an absent wire field is rejected as `ffi.unknown`
  /// corruption, never silently coerced to `''`. May be the empty string only in
  /// the theoretical empty-remote edge case (jj does not forbid an empty remote
  /// name).
  final String remoteName;
}

/// One jj bookmark: local or tracked-remote (FR-JJ-8).
///
/// A bookmark that is both local and remote-tracked appears as two separate
/// [Bookmark] entries — one [LocalBookmark], one [RemoteBookmark].
final class Bookmark {
  const Bookmark({required this.name, required this.target, required this.kind});

  /// Bookmark name (UTF-8).
  final String name;

  /// Target change id in jj reverse-hex form (stable across rebases).
  final String target;

  /// Whether this entry is a local bookmark or a tracked-remote bookmark.
  final BookmarkKind kind;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `Bookmarks` `Envelope` buffer into a list of [Bookmark]s.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.bookmarks`.
@visibleForTesting
List<Bookmark> decodeBookmarksEnvelope(Uint8List bytes) => _decodeBookmarksEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
List<Bookmark> decodeBookmarksEnvelopeInternal(Uint8List bytes) => _decodeBookmarksEnvelope(bytes);

List<Bookmark> _decodeBookmarksEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Bookmarks) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected Bookmarks payload, got ${env.dataType}',
    );
  }
  return payload.bookmarks?.map(_mapBookmark).toList() ?? const [];
}

Bookmark _mapBookmark(fbs.Bookmark b) => Bookmark(
  name: b.name ?? '',
  target: b.target ?? '',
  kind: _mapKind(b.kind, b.remoteName),
);

BookmarkKind _mapKind(fbs.BookmarkKind kind, String? remoteName) => switch (kind) {
  fbs.BookmarkKind.Local => const LocalBookmark(),
  fbs.BookmarkKind.Remote => switch (remoteName) {
    // A Remote entry must carry its remote name (its identity). An absent wire
    // field is corruption, not a legitimate null — reject it, never fabricate ''.
    null => throw const ZanshinFfiException('ffi.unknown', 'Remote bookmark missing remote_name'),
    final String name => RemoteBookmark(name),
  },
};
