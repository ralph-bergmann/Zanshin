// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_remotes` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). No CString argument: remotes is handle-only,
/// exactly like `zanshinBookmarks`.
Uint8List zanshinRemotes(int rawHandle) => readToken(zanshin_remotes(rawHandle));

/// Call `zanshin_git_push_remotes` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes (Story 9.54): the remotes `jj git push`
/// without `--remote` would push to. Handle-only, like [zanshinRemotes].
Uint8List zanshinGitPushRemotes(int rawHandle) => readToken(zanshin_git_push_remotes(rawHandle));

/// Call `zanshin_git_fetch_remotes` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes (Story 9.30): the remotes `jj git fetch`
/// without `--remote` would fetch from. Handle-only, like [zanshinRemotes].
Uint8List zanshinGitFetchRemotes(int rawHandle) => readToken(zanshin_git_fetch_remotes(rawHandle));

/// Call `zanshin_git_remote_changes` with the raw `u64` handle, [remoteName]
/// and [cancelToken], and return the FlatBuffers `Envelope` bytes (Story 9.24):
/// the `git ls-remote` poll, diffed against the head view without fetching.
///
/// [cancelToken] (Story 9.52) is `0` (not cancellable) or a token from
/// `zanshinNetworkToken`; `zanshinNetworkCancel` cancels the poll
/// (`jj.cancelled`). git sends no progress for it.
Uint8List zanshinGitRemoteChanges(int rawHandle, String remoteName, {int cancelToken = 0}) {
  rejectInteriorNul(remoteName, 'remoteName');
  final ffi.Pointer<Utf8> p = remoteName.toNativeUtf8();
  try {
    return readToken(zanshin_git_remote_changes(rawHandle, p.cast(), cancelToken));
  } finally {
    calloc.free(p);
  }
}

// ── Dart models ───────────────────────────────────────────────────────────────

/// One configured git remote (FR-JJ-9).
///
/// Both URLs are verbatim — credentials are NOT scrubbed and SSH is NOT
/// rewritten to HTTPS. The caller is responsible for any display scrubbing.
final class Remote {
  const Remote({required this.name, required this.url, required this.pushUrl});

  /// Remote name (UTF-8), e.g. `"origin"`.
  final String name;

  /// Fetch URL verbatim (no credential scrubbing); `null` for a remote with
  /// only a push URL — the CLI's `<no URL> (push: …)` row (Story 9.46).
  final String? url;

  /// Push URL when it DIFFERS from [url], `null` otherwise — null-for-absence,
  /// never `''`. Absent means "this remote pushes to its fetch URL". For a
  /// push-only remote ([url] `null`) it is always set.
  ///
  /// This is a DIFFERENCE, not a raw `remote.<name>.pushurl` read: it is exactly
  /// the question `jj git remote list` answers when it prints its `(push: …)`
  /// suffix only for remotes whose two URLs differ.
  ///
  /// Because of that, this value is NOT round-trippable back through
  /// `gitRemoteSetUrl`: feeding a `null` back would clear a `pushurl` that was
  /// configured but happened to equal [url]. Treat `null` as "leave the push URL
  /// alone", not "clear it" — and the same for a `null` [url]: never clear a
  /// `url` or `pushurl` from these values.
  final String? pushUrl;
}

/// Which kind of ref a [RemoteRefChange] is about (mirrors
/// `zanshin_jj::RemoteRefKind`).
enum RemoteRefKind {
  /// A bookmark — a Git branch under `refs/heads/`.
  bookmark,

  /// A tag — under `refs/tags/`.
  tag,
}

/// How a [RemoteRefChange]'s ref differs from the view (mirrors
/// `zanshin_jj::RemoteRefChangeKind`).
///
/// The second member is [created], not `new`, ONLY because `new` is a Dart
/// keyword — it is the same wire value as the schema's and Rust's `New`, as in
/// `GitRefUpdateKind`.
enum RemoteRefChangeKind {
  /// The remote advertises another commit than the view's target (or that
  /// target is conflicted).
  moved,

  /// The remote advertises a ref the view has no `<name>@<remote>` target for.
  /// The wire/Rust member is `New`.
  created,

  /// The view has a `<name>@<remote>` target the remote no longer advertises.
  deleted,
}

/// One ref whose `<name>@<remote>` target in the head view differs from what
/// the remote advertises now (Story 9.24) — an entry of
/// `RepoHandle.remoteChanges`' result.
final class RemoteRefChange {
  const RemoteRefChange({
    required this.kind,
    required this.name,
    required this.change,
    required this.oldCommitIds,
    required this.newCommitId,
  });

  /// Bookmark or tag.
  final RemoteRefKind kind;

  /// The ref's name without its namespace, e.g. `"main"`.
  final String name;

  /// Moved, created upstream, or deleted upstream.
  final RemoteRefChangeKind change;

  /// The view's target, full hex — several ids for a conflicted target, empty
  /// for [RemoteRefChangeKind.created].
  final List<String> oldCommitIds;

  /// The advertised commit, full hex (an annotated tag at the commit it peels
  /// to); `null` for [RemoteRefChangeKind.deleted].
  final String? newCommitId;

  @override
  String toString() => 'RemoteRefChange(${kind.name} $name ${change.name} $oldCommitIds -> $newCommitId)';
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `Remotes` `Envelope` buffer into a list of [Remote]s that also
/// carries the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.remotes`.
@visibleForTesting
WarnedList<Remote> decodeRemotesEnvelope(Uint8List bytes) => _decodeRemotesEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<Remote> decodeRemotesEnvelopeInternal(Uint8List bytes) => _decodeRemotesEnvelope(bytes);

WarnedList<Remote> _decodeRemotesEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Remotes) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected Remotes payload, got ${env.dataType}',
    );
  }
  return WarnedList(payload.remotes?.map(_mapRemote).toList() ?? const [], decodeEnvelopeWarningsInternal(env));
}

Remote _mapRemote(fbs.Remote r) => Remote(
  name: r.name ?? '',
  // NO `?? ''` on either URL: coalescing would destroy the absent/present
  // distinction they carry.
  url: r.url,
  pushUrl: r.pushUrl,
);

/// Decode a `GitPushRemotes` `Envelope` buffer into the remote names, in
/// remote-name order, carrying the call's warnings (Story 9.54).
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.gitPushRemotes`.
@visibleForTesting
WarnedList<String> decodeGitPushRemotesEnvelope(Uint8List bytes) => decodeGitPushRemotesEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<String> decodeGitPushRemotesEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.GitPushRemotes) {
    throw ZanshinFfiException('ffi.unknown', 'expected GitPushRemotes payload, got ${env.dataType}');
  }
  // Rust always writes the vector, an empty one included — an absent one is a
  // malformed buffer, not "no remotes".
  final List<String>? names = payload.names;
  if (names == null) {
    throw const ZanshinFfiException('ffi.unknown', 'GitPushRemotes payload is missing its names');
  }
  return WarnedList(names, decodeEnvelopeWarningsInternal(env));
}

/// Decode a `GitFetchRemotes` `Envelope` buffer into the remote names, in
/// remote-name order, carrying the call's warnings (Story 9.30).
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.gitFetchRemotes`.
@visibleForTesting
WarnedList<String> decodeGitFetchRemotesEnvelope(Uint8List bytes) => decodeGitFetchRemotesEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<String> decodeGitFetchRemotesEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.GitFetchRemotes) {
    throw ZanshinFfiException('ffi.unknown', 'expected GitFetchRemotes payload, got ${env.dataType}');
  }
  // Rust always writes the vector, an empty one included — an absent one is a
  // malformed buffer, not "no remotes".
  final List<String>? names = payload.names;
  if (names == null) {
    throw const ZanshinFfiException('ffi.unknown', 'GitFetchRemotes payload is missing its names');
  }
  return WarnedList(names, decodeEnvelopeWarningsInternal(env));
}

/// Decode a `RemoteChanges` `Envelope` buffer into the changed refs —
/// bookmarks before tags, each by name; empty when nothing is new — carrying
/// the call's warnings (Story 9.24).
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.remoteChanges`.
@visibleForTesting
WarnedList<RemoteRefChange> decodeRemoteChangesEnvelope(Uint8List bytes) => decodeRemoteChangesEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<RemoteRefChange> decodeRemoteChangesEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.RemoteChanges) {
    throw ZanshinFfiException('ffi.unknown', 'expected RemoteChanges payload, got ${env.dataType}');
  }
  return WarnedList(
    payload.changes?.map(_mapRemoteRefChange).toList() ?? const [],
    decodeEnvelopeWarningsInternal(env),
  );
}

RemoteRefChange _mapRemoteRefChange(fbs.RemoteRefChange c) => RemoteRefChange(
  kind: switch (c.kind) {
    fbs.RemoteRefKind.Bookmark => RemoteRefKind.bookmark,
    fbs.RemoteRefKind.Tag => RemoteRefKind.tag,
  },
  name: c.name ?? '',
  change: switch (c.change) {
    fbs.RemoteRefChangeKind.Moved => RemoteRefChangeKind.moved,
    fbs.RemoteRefChangeKind.New => RemoteRefChangeKind.created,
    fbs.RemoteRefChangeKind.Deleted => RemoteRefChangeKind.deleted,
  },
  oldCommitIds: List.unmodifiable(c.oldCommitIds ?? const <String>[]),
  // Null-for-absence: absent is the wire form of a deleted ref.
  newCommitId: c.newCommitId,
);
