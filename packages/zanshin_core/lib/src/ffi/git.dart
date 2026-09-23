// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'mutate.dart' show MutationResult, decodeMutationResultEnvelopeInternal, decodeMutationResultInternal;
import 'request_bytes.dart';

// This file owns the Dart half of Story 9.5's six `jj git` sync + remote-config
// verbs: the adapters (import/export/remote add/remove/rename/set-url), the two
// payload models unique to this noun, and their decoders. `dart:ffi` stays inside
// `ffi/` — only the worker isolate calls these adapters.
//
// Transport follows ADR-0001 per verb, not per file: `import`/`export` take only
// the handle (the CLI's own arg surface is empty for both), `remote remove`/
// `rename` take required lone strings and cross as C strings, and `remote add`/
// `set-url` are composites with a distinguishably-ABSENT `pushUrl` (and, for
// set-url, `url`) and cross as FlatBuffers REQUEST buffers.
//
// The four remote verbs return a plain `MutationResult`, so they reuse
// `mutate.dart`'s model and decoder rather than defining a second one.

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_git_import` with the raw `u64` handle and return the FlatBuffers
/// `Envelope` bytes.
///
/// Takes no arguments — the CLI's `jj git import` has none either. In a colocated
/// workspace the pre-verb snapshot (Story 9.26) has already imported the refs, so
/// this finds nothing left to import — exactly the CLI's outcome there.
Uint8List zanshinGitImport(int rawHandle) => readToken(zanshin_git_import(rawHandle));

/// Call `zanshin_git_export` with the raw `u64` handle and return the FlatBuffers
/// `Envelope` bytes.
///
/// Takes no arguments. In a colocated workspace every finished transaction has
/// already exported, so this usually finds git in sync.
Uint8List zanshinGitExport(int rawHandle) => readToken(zanshin_git_export(rawHandle));

/// Call `zanshin_git_remote_add` with the raw `u64` handle and a
/// `GitRemoteAddRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes.
///
/// A `null` [pushUrl] means the remote pushes to its fetch URL — git's own
/// behaviour. Both URLs cross VERBATIM; unlike the CLI, a relative local path is
/// not resolved against a process CWD.
///
/// Adding a remote WITH a push URL makes it non-removable by
/// [zanshinGitRemoteRemove]: jj-lib writes a `pushurl` key, which its own
/// `remove_remote` then refuses (`jj.remote_nonstandard_config`).
Uint8List zanshinGitRemoteAdd(int rawHandle, {required String name, required String url, String? pushUrl}) {
  rejectInteriorNul(name, 'name');
  rejectInteriorNul(url, 'url');
  rejectInteriorNul(pushUrl, 'pushUrl');
  final Uint8List request = fbs.GitRemoteAddRequestObjectBuilder(
    kind: fbs.RequestKind.GitRemoteAdd,
    name: name,
    url: url,
    pushUrl: pushUrl,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_git_remote_add(rawHandle, ptr, len));
}

/// Call `zanshin_git_remote_remove` with the raw `u64` handle and [name], and
/// return the FlatBuffers `Envelope` bytes.
///
/// Removing the reserved remote `git` SUCCEEDS but writes no operation — it
/// changes the git config and refs, not jj's view.
Uint8List zanshinGitRemoteRemove(int rawHandle, String name) {
  rejectInteriorNul(name, 'name');
  final ffi.Pointer<Utf8> p = name.toNativeUtf8();
  try {
    return readToken(zanshin_git_remote_remove(rawHandle, p.cast()));
  } finally {
    calloc.free(p); // free the C string we allocated
  }
}

/// Call `zanshin_git_remote_rename` with the raw `u64` handle, [oldName] and
/// [newName], and return the FlatBuffers `Envelope` bytes.
///
/// jj-lib validates [newName] BEFORE it reports that [oldName] is missing, so
/// renaming a nonexistent remote to `git` reports the reserved-name refusal. That
/// ordering is jj-lib's own and is reproduced, not corrected.
Uint8List zanshinGitRemoteRename(int rawHandle, String oldName, String newName) {
  rejectInteriorNul(oldName, 'oldName');
  rejectInteriorNul(newName, 'newName');
  final ffi.Pointer<Utf8> oldPtr = oldName.toNativeUtf8();
  try {
    final ffi.Pointer<Utf8> newPtr = newName.toNativeUtf8();
    try {
      return readToken(zanshin_git_remote_rename(rawHandle, oldPtr.cast(), newPtr.cast()));
    } finally {
      calloc.free(newPtr);
    }
  } finally {
    calloc.free(oldPtr);
  }
}

/// Call `zanshin_git_remote_set_url` with the raw `u64` handle and a
/// `GitRemoteSetUrlRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes.
///
/// A `null` [url]/[pushUrl] leaves that side unchanged — jj-lib cannot REMOVE a
/// URL. With BOTH null the call succeeds and does nothing, even for a remote that
/// does not exist (jj-lib returns early before its own existence check). This verb
/// never writes an operation, so `newOpId` is always the pre-call op-log head.
Uint8List zanshinGitRemoteSetUrl(int rawHandle, {required String name, String? url, String? pushUrl}) {
  rejectInteriorNul(name, 'name');
  rejectInteriorNul(url, 'url');
  rejectInteriorNul(pushUrl, 'pushUrl');
  final Uint8List request = fbs.GitRemoteSetUrlRequestObjectBuilder(
    kind: fbs.RequestKind.GitRemoteSetUrl,
    name: name,
    url: url,
    pushUrl: pushUrl,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_git_remote_set_url(rawHandle, ptr, len));
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// How one remote ref changed during a `git import` (mirrors
/// `zanshin_jj::GitRefUpdateKind`).
///
/// The first member is [created], not `new`, ONLY because `new` is a Dart keyword — it is
/// the same wire value as the schema's and Rust's `New` (discriminant 0). The other two
/// members keep their upstream spelling.
enum GitRefUpdateKind {
  /// jj had no such remote ref; the import created it. The wire/Rust member is `New`;
  /// `new` is a Dart keyword, so this layer spells it [created].
  created,

  /// The remote ref existed and now points somewhere else.
  updated,

  /// The remote ref existed and the import removed it.
  deleted,
}

/// One remote bookmark or tag a `git import` changed (mirrors
/// `zanshin_jj::GitRefUpdate`).
final class GitRefUpdate {
  const GitRefUpdate({
    required this.name,
    required this.remote,
    required this.kind,
    required this.tracked,
  });

  /// Bookmark or tag name.
  final String name;

  /// The remote it belongs to, e.g. `origin`.
  final String remote;

  /// Whether the import created, updated, or deleted it.
  final GitRefUpdateKind kind;

  /// Whether the ref is TRACKED afterwards — read from the post-import view, not
  /// from the state it had before.
  final bool tracked;
}

/// Outcome of a successful `gitImport` (mirrors `zanshin_jj::GitImportResult`).
final class GitImportResult {
  const GitImportResult({
    required this.mutation,
    required this.changedBookmarks,
    required this.changedTags,
    required this.abandonedChangeIds,
    required this.numRewritten,
    required this.failedRefNames,
  });

  /// The shared mutation contract: op id (the PRE-CALL head when nothing needed
  /// importing) and the working-copy change id afterwards. Its `newChangeIds` /
  /// `abandonedChangeIds` are always empty — an import's own abandonments are
  /// [abandonedChangeIds] on this class.
  final MutationResult mutation;

  /// Remote bookmarks the import changed.
  final List<GitRefUpdate> changedBookmarks;

  /// Remote tags the import changed.
  final List<GitRefUpdate> changedTags;

  /// Change ids of the commits the import abandoned because they became
  /// unreachable in git. If `@` was among them, jj gave the working copy a new
  /// empty commit, whose id is `mutation.workingCopyChangeId`.
  final List<String> abandonedChangeIds;

  /// How many commits the import rewrote. A count is all the CLI reports; it
  /// saturates at 4294967295.
  final int numRewritten;

  /// Git ref names the import could not read. A failed ref is NEVER an error —
  /// the CLI warns and exits 0 — and nothing in the repository state lets a caller
  /// re-derive this list afterwards. A name under `refs/remotes/git/` is the
  /// reserved-namespace case.
  final List<String> failedRefNames;
}

/// One remote ref a `git export` could not write to git (mirrors
/// `zanshin_jj::GitExportFailure`).
final class GitExportFailure {
  const GitExportFailure({required this.name, required this.remote, required this.reason});

  /// Bookmark or tag name.
  final String name;

  /// The remote it belongs to — `git` for the local git repo's own refs.
  final String remote;

  /// jj-lib's reason, flattened along its whole `source()` chain and joined by
  /// `": "`, exactly as the CLI prints it.
  final String reason;
}

/// Outcome of a successful `gitExport` (mirrors `zanshin_jj::GitExportResult`).
final class GitExportResult {
  const GitExportResult({
    required this.mutation,
    required this.failedBookmarks,
    required this.failedTags,
  });

  /// The shared mutation contract: op id (the PRE-CALL head when git already
  /// matched) and the working-copy change id. Export never moves `@`.
  final MutationResult mutation;

  /// Bookmarks that could not be exported. The classic case is two bookmarks
  /// named `foo` and `foo/bar`, which git cannot both hold.
  final List<GitExportFailure> failedBookmarks;

  /// Tags that could not be exported — only ever `@git` tags, since git has no
  /// remote tags.
  final List<GitExportFailure> failedTags;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `GitImportResult` `Envelope` buffer into a [GitImportResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.gitImport`.
@visibleForTesting
GitImportResult decodeGitImportResultEnvelope(Uint8List bytes) => _decodeGitImportResultEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
GitImportResult decodeGitImportResultEnvelopeInternal(Uint8List bytes) => _decodeGitImportResultEnvelope(bytes);

GitImportResult _decodeGitImportResultEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.GitImportResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected GitImportResult payload, got ${env.dataType}');
  }
  return decodeGitImportResultInternal(payload);
}

/// Rebuild a [GitImportResult] from its table — shared by `gitImport` and the
/// Story 9.26 precondition report's `gitRefs`.
GitImportResult decodeGitImportResultInternal(fbs.GitImportResult payload) => GitImportResult(
  mutation: decodeMutationResultInternal(payload.mutation),
  changedBookmarks: _refUpdates(payload.changedBookmarks),
  changedTags: _refUpdates(payload.changedTags),
  abandonedChangeIds: payload.abandonedChangeIds?.toList() ?? const [],
  numRewritten: payload.numRewritten,
  failedRefNames: payload.failedRefNames?.toList() ?? const [],
);

/// Decode a `GitExportResult` `Envelope` buffer into a [GitExportResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.gitExport`.
@visibleForTesting
GitExportResult decodeGitExportResultEnvelope(Uint8List bytes) => _decodeGitExportResultEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
GitExportResult decodeGitExportResultEnvelopeInternal(Uint8List bytes) => _decodeGitExportResultEnvelope(bytes);

GitExportResult _decodeGitExportResultEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.GitExportResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected GitExportResult payload, got ${env.dataType}');
  }
  return GitExportResult(
    mutation: decodeMutationResultInternal(payload.mutation),
    failedBookmarks: decodeExportFailuresInternal(payload.failedBookmarks),
    failedTags: decodeExportFailuresInternal(payload.failedTags),
  );
}

/// Decode a `MutationResult` `Envelope` buffer for the four remote verbs.
///
/// Deliberately the SAME decoder the mutation surface already uses — the four
/// verbs return exactly that payload, and a second decoder would be a second,
/// desyncable spelling of one contract.
MutationResult decodeGitRemoteEnvelopeInternal(Uint8List bytes) => decodeMutationResultEnvelopeInternal(bytes);

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  return env;
}

List<GitRefUpdate> _refUpdates(List<fbs.GitRefUpdate>? raw) =>
    raw
        ?.map(
          (u) => GitRefUpdate(
            name: u.name ?? '',
            remote: u.remote ?? '',
            kind: _mapRefUpdateKind(u.kind),
            tracked: u.tracked,
          ),
        )
        .toList() ??
    const [];

/// Rebuild a `GitExportFailure` list; an absent vector is empty.
List<GitExportFailure> decodeExportFailuresInternal(List<fbs.GitExportFailure>? raw) =>
    raw?.map((f) => GitExportFailure(name: f.name ?? '', remote: f.remote ?? '', reason: f.reason ?? '')).toList() ??
    const [];

GitRefUpdateKind _mapRefUpdateKind(fbs.GitRefUpdateKind kind) => switch (kind) {
  fbs.GitRefUpdateKind.New => GitRefUpdateKind.created,
  fbs.GitRefUpdateKind.Updated => GitRefUpdateKind.updated,
  fbs.GitRefUpdateKind.Deleted => GitRefUpdateKind.deleted,
};
