// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of the tags (Story 9.59): the list adapter, its
// `Tag` model and decoder, and the request builders and adapters of the four tag
// verbs (`set`, `delete`, `track`, `untrack`). `dart:ffi` stays inside `ffi/` —
// only the worker isolate calls these adapters. The verbs return the shipped
// `MutationResult`, decoded in `isolate.dart` by `mutate.dart`'s decoder.
//
// The `rejectInteriorNul(s)` calls are the DIRECT-CALLER backstop; the primary
// guard lives on the calling side, in `ZanshinWorker` and `RepoHandle`.

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_tags` with the raw `u64` handle and return the FlatBuffers
/// `Envelope` bytes — the rows of `jj tag list --all-remotes` minus the `git`
/// remote's.
Uint8List zanshinTags(int rawHandle) => readToken(zanshin_tags(rawHandle));

/// Call `zanshin_tag_set` with the raw `u64` handle and a `TagSetRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// [names] are DECODED names; a `null` [revision] applies the CLI's `-r`
/// default `@`. Without [allowMove] a name that is a local tag already is
/// refused (`jj.invalid_input`).
Uint8List zanshinTagSet(int rawHandle, List<String> names, {String? revision, bool allowMove = false}) {
  rejectInteriorNuls(names, 'names');
  rejectInteriorNul(revision, 'revision');
  final Uint8List request = fbs.TagSetRequestObjectBuilder(
    kind: fbs.RequestKind.TagSet,
    names: names,
    revision: revision,
    allowMove: allowMove,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_tag_set(rawHandle, ptr, len)));
}

/// Call `zanshin_tag_delete` with the raw `u64` handle and a
/// `TagDeleteRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes. [names] are string PATTERNS (a bare one is a GLOB).
Uint8List zanshinTagDelete(int rawHandle, List<String> names) {
  rejectInteriorNuls(names, 'names');
  final Uint8List request = fbs.TagDeleteRequestObjectBuilder(
    kind: fbs.RequestKind.TagDelete,
    names: names,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_tag_delete(rawHandle, ptr, len)));
}

/// Call `zanshin_tag_track` with the raw `u64` handle and a `TagTrackRequest`
/// request buffer tagged `TagTrack`, and return the FlatBuffers `Envelope`
/// bytes.
///
/// [names] are the CLI's `TAG[@REMOTE]` texts: a `name@remote` symbol names one
/// remote tag exactly, anything else is a string pattern. [remotes] are
/// remote-name patterns (`--remote`; empty = not given).
Uint8List zanshinTagTrack(int rawHandle, List<String> names, {List<String> remotes = const []}) =>
    _trackRequest(rawHandle, names, remotes, fbs.RequestKind.TagTrack, zanshin_tag_track);

/// Call `zanshin_tag_untrack` with the raw `u64` handle and a `TagTrackRequest`
/// request buffer tagged `TagUntrack`, and return the FlatBuffers `Envelope`
/// bytes. Arguments as [zanshinTagTrack]'s.
Uint8List zanshinTagUntrack(int rawHandle, List<String> names, {List<String> remotes = const []}) =>
    _trackRequest(rawHandle, names, remotes, fbs.RequestKind.TagUntrack, zanshin_tag_untrack);

Uint8List _trackRequest(
  int rawHandle,
  List<String> names,
  List<String> remotes,
  fbs.RequestKind kind,
  ffi.Pointer<ZanshinBuf> Function(int, ffi.Pointer<ffi.Uint8>, int) wrapper,
) {
  rejectInteriorNuls(names, 'names');
  rejectInteriorNuls(remotes, 'remotes');
  final Uint8List request = fbs.TagTrackRequestObjectBuilder(kind: kind, names: names, remotes: remotes).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(wrapper(rawHandle, ptr, len)));
}

// ── Dart models ───────────────────────────────────────────────────────────────

/// Whether a tag row is the local tag or a remote one (tracked or not).
///
/// Sealed so that a [RemoteTag] without a remote name is unrepresentable.
sealed class TagKind {
  const TagKind();
}

/// The tag local to this repository.
final class LocalTag extends TagKind {
  const LocalTag();
}

/// A tag on [remoteName], tracked by the local tag or not.
final class RemoteTag extends TagKind {
  const RemoteTag(this.remoteName, {required this.tracked});

  /// The remote this tag lives on (e.g. `"origin"`). Always present for a
  /// `Remote` entry — an absent wire field is rejected as `ffi.unknown`
  /// corruption. Never `git`: the list leaves that remote out.
  final String remoteName;

  /// Whether the local tag tracks this remote tag.
  final bool tracked;
}

/// One row of `jj tag list --all-remotes` (Story 9.59). A tag that is both local
/// and on a remote appears as one [LocalTag] row and one [RemoteTag] row per
/// remote.
final class Tag {
  const Tag({
    required this.name,
    required this.target,
    required this.kind,
    required this.conflicted,
    required this.synced,
  });

  /// Tag name (UTF-8).
  final String name;

  /// Target change id in jj reverse-hex form; for a conflicted target the first
  /// added commit's. Null when the row's target is absent: a local tag deleted
  /// while still tracking a remote, or a tracked remote tag not pushed yet.
  final String? target;

  /// The target is an unresolved conflict.
  final bool conflicted;

  /// Local row: every tracked remote tag of this name points where the local one
  /// does (true when none is tracked). Remote row: tracked and pointing where the
  /// local one does.
  final bool synced;

  /// Whether this entry is the local tag or a remote one.
  final TagKind kind;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `Tags` `Envelope` buffer into a list of [Tag]s that also carries the
/// call's warnings. Exposed for decode-contract tests with synthetic buffers.
@visibleForTesting
WarnedList<Tag> decodeTagsEnvelope(Uint8List bytes) => _decodeTagsEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<Tag> decodeTagsEnvelopeInternal(Uint8List bytes) => _decodeTagsEnvelope(bytes);

WarnedList<Tag> _decodeTagsEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Tags) {
    throw ZanshinFfiException('ffi.unknown', 'expected Tags payload, got ${env.dataType}');
  }
  return WarnedList(payload.tags?.map(_mapTag).toList() ?? const [], decodeEnvelopeWarningsInternal(env));
}

Tag _mapTag(fbs.Tag t) => Tag(
  // The name is the row's identity: an absent field is corruption, never ''.
  name: t.name ?? (throw const ZanshinFfiException('ffi.unknown', 'Tag missing name')),
  target: t.target,
  conflicted: t.conflicted,
  synced: t.synced,
  kind: switch (t.kind) {
    fbs.TagKind.Local => const LocalTag(),
    fbs.TagKind.Remote => switch (t.remoteName) {
      // A Remote entry must carry its remote name; an absent field is corruption.
      null => throw const ZanshinFfiException('ffi.unknown', 'Remote tag missing remote_name'),
      final String name => RemoteTag(name, tracked: t.tracked),
    },
  },
);
