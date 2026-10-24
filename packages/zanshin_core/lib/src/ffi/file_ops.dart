// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'git.dart' show GitExportFailure, decodeExportFailuresInternal;
import 'mutate.dart' show MutationResult, decodeMutationResultInternal;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.22's two working-copy tracking verbs:
// the request builders and adapters (fileTrack / fileUntrack), the payload models
// (TrackResult, UntrackResult and the SnapshotStats shape both share, which Story
// 9.26's pre-verb snapshot report reuses) and their decoders — and Story 9.13's
// fileChmod adapter (its result is the shared MutationResult). `dart:ffi` stays inside
// `ffi/` — only the worker isolate calls these adapters.
//
// The shared `rejectInteriorNuls` calls below are the DIRECT-CALLER backstop: the
// primary guard lives on the calling side, in `ZanshinWorker` and `RepoHandle`,
// because inside the worker isolate a throw here comes back as
// `internal.dispatch_error` rather than as the documented `ArgumentError`.

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_file_track` with the raw `u64` handle and a `FileTrackRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// [paths] are repo-relative PREFIXES (the fileset DSL is not parsed); an empty
/// list is refused by the jj layer as `jj.invalid_input`. [includeIgnored] is the
/// CLI's `--include-ignored`.
Uint8List zanshinFileTrack(int rawHandle, List<String> paths, {bool includeIgnored = false}) {
  rejectInteriorNuls(paths, 'paths');
  final Uint8List request = fbs.FileTrackRequestObjectBuilder(
    kind: fbs.RequestKind.FileTrack,
    paths: paths,
    includeIgnored: includeIgnored,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_file_track(rawHandle, ptr, len));
}

/// Call `zanshin_file_untrack` with the raw `u64` handle and a
/// `FileUntrackRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes. [paths] as for [zanshinFileTrack]; every matched path must already be
/// ignored (`jj.path_not_ignored` otherwise).
Uint8List zanshinFileUntrack(int rawHandle, List<String> paths) {
  rejectInteriorNuls(paths, 'paths');
  final Uint8List request = fbs.FileUntrackRequestObjectBuilder(
    kind: fbs.RequestKind.FileUntrack,
    paths: paths,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_file_untrack(rawHandle, ptr, len));
}

/// Call `zanshin_file_chmod` with the raw `u64` handle and a `FileChmodRequest`
/// request buffer (Story 9.13), and return the FlatBuffers `Envelope` bytes — the
/// CLI's `jj file chmod x|n`. [executable] is `x`; a `null` [revision] applies
/// the CLI's `-r` default `@`. [paths] as for [zanshinFileTrack].
Uint8List zanshinFileChmod(int rawHandle, List<String> paths, {required bool executable, String? revision}) {
  rejectInteriorNuls(paths, 'paths');
  rejectInteriorNul(revision, 'revision');
  final Uint8List request = fbs.FileChmodRequestObjectBuilder(
    kind: fbs.RequestKind.FileChmod,
    executable: executable,
    revision: revision,
    paths: paths,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_file_chmod(rawHandle, ptr, len));
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// Why a new file stayed untracked after a snapshot (mirrors
/// `zanshin_jj::UntrackedReason`). Sealed so a `switch` over it is exhaustive.
sealed class UntrackedReason {
  const UntrackedReason();
}

/// The file is larger than the effective `snapshot.max-new-file-size`.
final class FileTooLarge extends UntrackedReason {
  const FileTooLarge({required this.size, required this.maxSize});

  /// The file's size in bytes.
  final int size;

  /// The limit it exceeded, in bytes.
  final int maxSize;
}

/// The file does not match the snapshot's start-tracking fileset —
/// `snapshot.auto-track`, or the paths a `fileTrack` named.
final class FileNotAutoTracked extends UntrackedReason {
  const FileNotAutoTracked();
}

/// One new file a snapshot left untracked, and why (mirrors
/// `zanshin_jj::UntrackedPath`).
final class UntrackedPath {
  const UntrackedPath({required this.path, required this.reason});

  /// Repo-relative path in jj's internal (`/`-separated) form.
  final String path;

  /// Why it stayed untracked.
  final UntrackedReason reason;
}

/// What a working-copy snapshot could NOT record (mirrors
/// `zanshin_jj::SnapshotStats`) — the facts the CLI's snapshot warnings print.
final class SnapshotStats {
  const SnapshotStats({required this.untracked, required this.invalidUtf8Paths});

  /// New files that stayed untracked, in jj's (path) order.
  final List<UntrackedPath> untracked;

  /// Files skipped because their NAME is not valid UTF-8, rendered as
  /// `"<dir>/<name>"` with the name lossily decoded.
  final List<String> invalidUtf8Paths;
}

/// Outcome of a successful `fileTrack` (mirrors `zanshin_jj::TrackResult`).
final class TrackResult {
  const TrackResult({
    required this.mutation,
    required this.numRebased,
    required this.snapshotStats,
    this.warnings = const [],
  });

  /// The shared mutation contract. An operation (`track paths`) is ALWAYS
  /// written; `workingCopyChangeId` is the pre-call `@` — the tracked paths live
  /// in the working-copy state until the next snapshot (jj's GH #8298).
  final MutationResult mutation;

  /// Descendants the verb rebased — always 0 today, for the reason above;
  /// saturates at 4294967295.
  final int numRebased;

  /// What the track snapshot left untracked.
  final SnapshotStats snapshotStats;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none. The nested [mutation] carries none of its own.
  final List<ZanshinWarning> warnings;
}

/// Outcome of a successful `fileUntrack` (mirrors `zanshin_jj::UntrackResult`).
final class UntrackResult {
  const UntrackResult({
    required this.mutation,
    required this.numRebased,
    required this.unmatchedPaths,
    required this.snapshotStats,
    required this.failedBookmarks,
    required this.failedTags,
    this.warnings = const [],
  });

  /// The shared mutation contract. An operation (`untrack paths`) is ALWAYS
  /// written; `@` is rewritten without the matched entries (same change id).
  final MutationResult mutation;

  /// Descendants of `@` rebased onto the rewritten `@`; saturates at 4294967295.
  final int numRebased;

  /// Requested paths with no entry in the pre-call `@`, in request order — the
  /// CLI's "No matching entries for paths" warning.
  final List<String> unmatchedPaths;

  /// What the post-reset snapshot left untracked.
  final SnapshotStats snapshotStats;

  /// Bookmarks the colocated git export could not write; empty outside a
  /// colocated workspace.
  final List<GitExportFailure> failedBookmarks;

  /// Tags the colocated git export could not write; empty outside a colocated
  /// workspace.
  final List<GitExportFailure> failedTags;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none. The nested [mutation] carries none of its own.
  final List<ZanshinWarning> warnings;
}

// ── Decoders ─────────────────────────────────────────────────────────────────

/// Decode a `TrackResult` `Envelope` buffer into a [TrackResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.fileTrack`.
@visibleForTesting
TrackResult decodeTrackResultEnvelope(Uint8List bytes) => _decodeTrackResultEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
TrackResult decodeTrackResultEnvelopeInternal(Uint8List bytes) => _decodeTrackResultEnvelope(bytes);

TrackResult _decodeTrackResultEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.TrackResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected TrackResult payload, got ${env.dataType}');
  }
  return TrackResult(
    mutation: decodeMutationResultInternal(payload.mutation),
    numRebased: payload.numRebased,
    snapshotStats: decodeSnapshotStatsInternal(payload.snapshotStats),
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode an `UntrackResult` `Envelope` buffer into an [UntrackResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.fileUntrack`.
@visibleForTesting
UntrackResult decodeUntrackResultEnvelope(Uint8List bytes) => _decodeUntrackResultEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
UntrackResult decodeUntrackResultEnvelopeInternal(Uint8List bytes) => _decodeUntrackResultEnvelope(bytes);

UntrackResult _decodeUntrackResultEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.UntrackResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected UntrackResult payload, got ${env.dataType}');
  }
  return UntrackResult(
    mutation: decodeMutationResultInternal(payload.mutation),
    numRebased: payload.numRebased,
    unmatchedPaths: payload.unmatchedPaths?.toList() ?? const [],
    snapshotStats: decodeSnapshotStatsInternal(payload.snapshotStats),
    failedBookmarks: decodeExportFailuresInternal(payload.failedBookmarks),
    failedTags: decodeExportFailuresInternal(payload.failedTags),
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  return env;
}

/// Rebuild a [SnapshotStats]; an absent table is empty stats, not a crash.
/// Shared by the track verbs and the Story 9.26 precondition report.
SnapshotStats decodeSnapshotStatsInternal(fbs.SnapshotStats? s) => SnapshotStats(
  untracked: s?.untracked?.map((u) => UntrackedPath(path: u.path ?? '', reason: _reason(u))).toList() ?? const [],
  invalidUtf8Paths: s?.invalidUtf8Paths?.toList() ?? const [],
);

/// The union arm of one `UntrackedPath`. Rust always writes one, so a missing arm
/// is a corrupt buffer and refused rather than guessed.
UntrackedReason _reason(fbs.UntrackedPath u) => switch (u.reason) {
  final fbs.FileTooLarge r => FileTooLarge(size: r.size, maxSize: r.maxSize),
  fbs.FileNotAutoTracked() => const FileNotAutoTracked(),
  _ => throw ZanshinFfiException('ffi.unknown', 'UntrackedPath.reason missing for ${u.path}'),
};
