// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_bookmarks` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). No CString argument: bookmarks is handle-only,
/// exactly like `zanshinStatus`.
Uint8List zanshinBookmarks(int rawHandle) => readToken(zanshin_bookmarks(rawHandle));

// ── Dart models ───────────────────────────────────────────────────────────────

/// Whether a bookmark row is the local bookmark or a remote one (tracked or not).
///
/// Modelled as a sealed class so that a [RemoteBookmark] with no remote name
/// is unrepresentable — illegal state is a compile-time error, not a runtime
/// `null`-check.
sealed class BookmarkKind {
  const BookmarkKind();
}

/// The bookmark local to this repository.
final class LocalBookmark extends BookmarkKind {
  const LocalBookmark();
}

/// A bookmark on [remoteName], tracked by the local bookmark or not (Story 9.29).
final class RemoteBookmark extends BookmarkKind {
  const RemoteBookmark(this.remoteName, {required this.tracked, this.ahead, this.behind});

  /// The remote this bookmark lives on (e.g. `"origin"`, or `"git"` in a
  /// colocated repo). Always present for a `Remote` entry — an absent wire field
  /// is rejected as `ffi.unknown` corruption, never silently coerced to `''`. May
  /// be the empty string only in the theoretical empty-remote edge case (jj does
  /// not forbid an empty remote name).
  final String remoteName;

  /// Whether the local bookmark tracks this remote bookmark.
  final bool tracked;

  /// Commits this remote target has that the local target lacks — the CLI's
  /// "ahead by N commits". Null unless [tracked] and both targets are present.
  final RefDistance? ahead;

  /// Commits the local target has that this remote target lacks — the CLI's
  /// "behind by N commits". Null exactly when [ahead] is.
  final RefDistance? behind;
}

/// A commit count between a remote bookmark and its local counterpart
/// (jj-lib's `count_estimate`).
final class RefDistance {
  const RefDistance({required this.lower, this.upper});

  /// At least this many commits.
  final int lower;

  /// At most this many commits; null when jj could not bound the count (the
  /// CLI's "at least N commits"). Equal to [lower] for an exact count.
  final int? upper;
}

/// One row of `jj bookmark list --all-remotes` (FR-JJ-8, Story 9.29).
///
/// A bookmark that is both local and on a remote appears as separate [Bookmark]
/// entries — one [LocalBookmark] and one [RemoteBookmark] per remote.
final class Bookmark {
  const Bookmark({
    required this.name,
    required this.target,
    required this.kind,
    required this.conflicted,
    required this.synced,
  });

  /// Bookmark name (UTF-8).
  final String name;

  /// Target change id in jj reverse-hex form (stable across rebases); for a
  /// conflicted target the first added commit's. Null when the row's target is
  /// absent: a local bookmark deleted while still tracking a remote (the CLI's
  /// `(deleted)`), or a tracked remote bookmark not pushed yet (`(not created
  /// yet)`).
  final String? target;

  /// The target is an unresolved conflict (`!RefTarget::is_resolved`).
  final bool conflicted;

  /// Local row: every tracked remote bookmark of this name points where the
  /// local one does (true when none is tracked). Remote row: tracked and
  /// pointing where the local one does.
  final bool synced;

  /// Whether this entry is the local bookmark or a remote one.
  final BookmarkKind kind;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `Bookmarks` `Envelope` buffer into a list of [Bookmark]s that also
/// carries the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.bookmarks`.
@visibleForTesting
WarnedList<Bookmark> decodeBookmarksEnvelope(Uint8List bytes) => _decodeBookmarksEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<Bookmark> decodeBookmarksEnvelopeInternal(Uint8List bytes) => _decodeBookmarksEnvelope(bytes);

WarnedList<Bookmark> _decodeBookmarksEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Bookmarks) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected Bookmarks payload, got ${env.dataType}',
    );
  }
  return WarnedList(payload.bookmarks?.map(_mapBookmark).toList() ?? const [], decodeEnvelopeWarningsInternal(env));
}

Bookmark _mapBookmark(fbs.Bookmark b) => Bookmark(
  name: b.name ?? '',
  target: b.target,
  conflicted: b.conflicted,
  synced: b.synced,
  kind: _mapKind(b),
);

BookmarkKind _mapKind(fbs.Bookmark b) => switch (b.kind) {
  fbs.BookmarkKind.Local => const LocalBookmark(),
  fbs.BookmarkKind.Remote => switch (b.remoteName) {
    // A Remote entry must carry its remote name (its identity). An absent wire
    // field is corruption, not a legitimate null — reject it, never fabricate ''.
    null => throw const ZanshinFfiException('ffi.unknown', 'Remote bookmark missing remote_name'),
    final String name => RemoteBookmark(
      name,
      tracked: b.tracked,
      ahead: _mapDistance(b.ahead),
      behind: _mapDistance(b.behind),
    ),
  },
};

RefDistance? _mapDistance(fbs.RefDistance? d) =>
    d == null ? null : RefDistance(lower: d.lower, upper: d.hasUpper ? d.upper : null);
