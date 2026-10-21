// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'git.dart' show GitRefUpdate, decodeRefUpdatesInternal;
import 'mutate.dart' show MutationResult, decodeMutationResultInternal;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.30's fetch: the `zanshin_git_fetch`
// adapter, its arguments, the `GitFetchResult` model and its decoder. `dart:ffi`
// stays inside `ffi/` — only the worker isolate calls the adapter.

// ── Arguments ────────────────────────────────────────────────────────────────

/// The remotes `gitFetch` fetches from (mirrors `zanshin_jj::FetchRemotes`) —
/// the CLI's either/or of `--remote` and `--all-remotes`.
sealed class FetchRemotes {
  const FetchRemotes();
}

/// No `--remote`: `git.fetch` (a list or a string of name patterns), else the
/// only remote, else `origin` — what `gitFetchRemotes` answers.
final class DefaultFetchRemotes extends FetchRemotes {
  const DefaultFetchRemotes();
}

/// `--remote` (repeatable): the union of [patterns]; a bare word is a glob.
final class NamedFetchRemotes extends FetchRemotes {
  const NamedFetchRemotes(this.patterns);

  /// The remote name patterns.
  final List<String> patterns;
}

/// `--all-remotes`: every remote.
final class AllFetchRemotes extends FetchRemotes {
  const AllFetchRemotes();
}

/// The refs `gitFetch` fetches from each remote (mirrors
/// `zanshin_jj::FetchRefs`) — the CLI's either/or of `--branch`/`--tag` and
/// `--tracked`.
sealed class FetchRefs {
  const FetchRefs();
}

/// None of `--branch`, `--tag`, `--tracked`: `remotes.<name>.fetch-bookmarks`,
/// else the Git config's fetch refspecs; `remotes.<name>.fetch-tags`, else
/// every tag.
final class DefaultFetchRefs extends FetchRefs {
  const DefaultFetchRefs();
}

/// `--branch` / `--tag` (repeatable; a bare word is a glob): the union of each
/// list; an empty list fetches nothing of its kind.
final class PatternFetchRefs extends FetchRefs {
  const PatternFetchRefs({this.branches = const [], this.tags = const []});

  /// The branch name patterns (`-b`).
  final List<String> branches;

  /// The tag name patterns (`-t`).
  final List<String> tags;
}

/// `--tracked`: the bookmarks and tags already tracked from each remote.
final class TrackedFetchRefs extends FetchRefs {
  const TrackedFetchRefs();
}

// ── FFI adapter ──────────────────────────────────────────────────────────────

/// Call `zanshin_git_fetch` with the raw `u64` handle and a `GitFetchRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.30) —
/// the CLI's `jj git fetch` with its parameters passed through.
///
/// Progress rides the same process-global event sink `WatcherEvent` already
/// uses (Story 3.6), tagged with the handle's `session_id` and
/// `operation: "fetch"`. [cancelToken] (Story 9.52) is `0` (not cancellable)
/// or a token from `zanshinNetworkToken`; `zanshinNetworkCancel` cancels the
/// fetch (`jj.cancelled`).
Uint8List zanshinGitFetch(
  int rawHandle, {
  FetchRemotes remotes = const DefaultFetchRemotes(),
  FetchRefs refs = const DefaultFetchRefs(),
  int cancelToken = 0,
}) {
  final Uint8List request = gitFetchRequestBytes(remotes: remotes, refs: refs, cancelToken: cancelToken);
  return callWithRequest(request, (ptr, len) => zanshin_git_fetch(rawHandle, ptr, len));
}

/// The `GitFetchRequest` bytes [zanshinGitFetch] sends: [remotes] and [refs]
/// as their modes and lists, and [cancelToken].
///
/// Throws [ArgumentError] when a pattern contains an interior NUL (U+0000).
@visibleForTesting
Uint8List gitFetchRequestBytes({required FetchRemotes remotes, required FetchRefs refs, required int cancelToken}) {
  _rejectInteriorNuls(remotes, refs);
  final (fbs.FetchRemotesMode remotesMode, List<String>? names) = switch (remotes) {
    DefaultFetchRemotes() => (fbs.FetchRemotesMode.Default, null),
    NamedFetchRemotes(:final patterns) => (fbs.FetchRemotesMode.Named, patterns),
    AllFetchRemotes() => (fbs.FetchRemotesMode.All, null),
  };
  final (fbs.FetchRefsMode refsMode, List<String>? branches, List<String>? tags) = switch (refs) {
    DefaultFetchRefs() => (fbs.FetchRefsMode.Default, null, null),
    PatternFetchRefs(:final branches, :final tags) => (fbs.FetchRefsMode.Patterns, branches, tags),
    TrackedFetchRefs() => (fbs.FetchRefsMode.Tracked, null, null),
  };
  return fbs.GitFetchRequestObjectBuilder(
    kind: fbs.RequestKind.GitFetch,
    remotesMode: remotesMode,
    remotes: names,
    refsMode: refsMode,
    branches: branches,
    tags: tags,
    cancelToken: cancelToken,
  ).toBytes();
}

/// Throws [ArgumentError] when a pattern of [remotes] or [refs] contains an
/// interior NUL (U+0000) — the request-string guard every adapter runs.
void _rejectInteriorNuls(FetchRemotes remotes, FetchRefs refs) {
  if (remotes case NamedFetchRemotes(:final patterns)) {
    rejectInteriorNuls(patterns, 'remotes');
  }
  if (refs case PatternFetchRefs(:final branches, :final tags)) {
    rejectInteriorNuls(branches, 'branches');
    rejectInteriorNuls(tags, 'tags');
  }
}

// ── Dart model ───────────────────────────────────────────────────────────────

/// Outcome of `gitFetch` (mirrors `zanshin_jj::GitFetchOutcome`).
final class GitFetchResult {
  const GitFetchResult({
    required this.mutation,
    required this.remotes,
    required this.hints,
    required this.failedRefNames,
    required this.changedBookmarks,
    required this.changedTags,
    required this.numRewritten,
    this.warnings = const [],
  });

  /// The shared mutation contract. A fetch writes an operation even when
  /// nothing changed. Its `abandonedChangeIds` are the commits the import
  /// abandoned because they became unreachable in git (what
  /// `git.abandon-unreachable-commits` governs); `newChangeIds` is always
  /// empty. The nested result carries no warnings of its own.
  final MutationResult mutation;

  /// The remotes fetched from, in remote-name order.
  final List<String> remotes;

  /// The CLI's hints, verbatim: `Fetching from the only existing remote: R`
  /// when the default resolution picked a single remote R other than `origin`.
  final List<String> hints;

  /// The Git refs the import could not read — what `jj.git_import_failed`
  /// lists.
  final List<String> failedRefNames;

  /// Remote bookmarks the import changed, as `GitImportResult.changedBookmarks`
  /// reports them — what the CLI prints after a fetch.
  final List<GitRefUpdate> changedBookmarks;

  /// Remote tags the import changed, as `GitImportResult.changedTags`.
  final List<GitRefUpdate> changedTags;

  /// How many commits the import rewrote (the CLI's "Updated {n} rewritten
  /// commits."); it saturates at 4294967295.
  final int numRewritten;

  /// The call's warnings (Story 9.32), in the CLI's print order:
  /// `jj.fetch_remotes_unmatched`, `jj.fetch_refspec_ignored`,
  /// `jj.git_import_failed`, `jj.fetch_branches_unmatched`, then the finish's.
  final List<ZanshinWarning> warnings;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `GitFetchResult` `Envelope` buffer into a [GitFetchResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.gitFetch`.
@visibleForTesting
GitFetchResult decodeGitFetchResultEnvelope(Uint8List bytes) => decodeGitFetchResultEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
GitFetchResult decodeGitFetchResultEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.GitFetchResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected GitFetchResult payload, got ${env.dataType}');
  }
  // Rust always writes every vector, empty ones included — an absent one is a
  // malformed buffer.
  T present<T extends Object>(T? value, String field) =>
      value ?? (throw ZanshinFfiException('ffi.unknown', 'GitFetchResult payload is missing its $field'));
  return GitFetchResult(
    mutation: decodeMutationResultInternal(present(payload.mutation, 'mutation')),
    remotes: present(payload.remotes, 'remotes'),
    hints: present(payload.hints, 'hints'),
    failedRefNames: present(payload.failedRefNames, 'failed_ref_names'),
    changedBookmarks: decodeRefUpdatesInternal(present(payload.changedBookmarks, 'changed_bookmarks')),
    changedTags: decodeRefUpdatesInternal(present(payload.changedTags, 'changed_tags')),
    numRewritten: payload.numRewritten,
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}
