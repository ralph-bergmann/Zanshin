// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.20's push: the `zanshin_git_push`
// adapter, the `GitPushResult` model and its decoder. `dart:ffi` stays inside
// `ffi/` — only the worker isolate calls the adapter.

// ── FFI adapter ──────────────────────────────────────────────────────────────

/// Call `zanshin_git_push` with the raw `u64` handle and a `GitPushRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.20) —
/// the CLI's `jj git push` with every parameter passed through.
///
/// [remotes] is `--remote` (`null` = not given: `git.push`, else the only
/// remote, else `origin`); [bookmarks] / [tags] are `-b` / `-t` patterns;
/// [all] / [tracked] / [deleted] the bulk modes; [allowEmptyDescription] /
/// [allowPrivate] / [allowConflicts] the commit-check overrides; [revisions]
/// is `-r`, [changes] `-c`, [named] `--named NAME=REVISION`; [dryRun] plans
/// without pushing; [options] are `--option` push options. Progress rides the
/// event sink as `operation: "push"`. [cancelToken] (Story 9.52) is `0` (not
/// cancellable) or a token from `zanshinNetworkToken`; a cancel stops the push
/// before the next remote and is reported as data
/// ([PushFailureKind.cancelled]).
Uint8List zanshinGitPush(
  int rawHandle, {
  List<String>? remotes,
  List<String> bookmarks = const [],
  List<String> tags = const [],
  bool all = false,
  bool tracked = false,
  bool deleted = false,
  bool allowEmptyDescription = false,
  bool allowPrivate = false,
  bool allowConflicts = false,
  List<String> revisions = const [],
  List<String> changes = const [],
  List<String> named = const [],
  bool dryRun = false,
  List<String> options = const [],
  int cancelToken = 0,
}) {
  rejectInteriorNuls(remotes ?? const [], 'remotes');
  rejectInteriorNuls(bookmarks, 'bookmarks');
  rejectInteriorNuls(tags, 'tags');
  rejectInteriorNuls(revisions, 'revisions');
  rejectInteriorNuls(changes, 'changes');
  rejectInteriorNuls(named, 'named');
  rejectInteriorNuls(options, 'options');
  final Uint8List request = fbs.GitPushRequestObjectBuilder(
    kind: fbs.RequestKind.GitPush,
    remotes: remotes,
    bookmarks: bookmarks,
    tags: tags,
    all: all,
    tracked: tracked,
    deleted: deleted,
    allowEmptyDescription: allowEmptyDescription,
    allowPrivate: allowPrivate,
    allowConflicts: allowConflicts,
    revisions: revisions,
    changes: changes,
    named: named,
    dryRun: dryRun,
    options: options,
    cancelToken: cancelToken,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_git_push(rawHandle, ptr, len));
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// Which kind of ref a push row moves.
enum PushRefKind {
  /// A bookmark (`refs/heads/…` on the remote).
  bookmark,

  /// A tag (`refs/tags/…` on the remote).
  tag,
}

/// What the push does with a row.
enum PushPath {
  /// The ref is pushed (a dry run: would be).
  push,

  /// A skipping mode (bare, `-r`, `--all`, `--tracked`, `--deleted`) refused
  /// the ref and warned; the rest goes on.
  skip,

  /// An explicitly named ref was refused — a dry run's plan only (the real run
  /// answers an error envelope).
  abort,
}

/// Where a row ended after the push.
enum PushRefStatus {
  /// The push did not reach this ref (a dry run, a skipped row, or the push
  /// stopped before this remote).
  notReached,

  /// Pushed.
  pushed,

  /// The remote's ref moved since the last fetch (the lease failed).
  leaseRejected,

  /// The remote refused the update (e.g. a hook).
  remoteRejected,
}

/// How a push did not fully succeed.
enum PushFailureKind {
  /// A dry run's explicit ref refusal.
  refRefused,

  /// A dry run's explicit commit rejection.
  commitRejected,

  /// "Failed to push some bookmarks" — possibly recorded.
  someRefsFailed,

  /// The push stopped at a remote, nothing recorded; or a step after the push
  /// loop failed, and [GitPushResult.recorded] says whether the operation was
  /// written.
  pushError,

  /// The push's cancel was requested (Story 9.52): it stopped before the next
  /// remote, nothing recorded; [PushRemote.finished] says which remotes
  /// already got their refs.
  cancelled,
}

/// A refusal of a ref, verbatim from the CLI.
final class PushRefusal {
  const PushRefusal({required this.message, this.hint});

  /// The CLI's message.
  final String message;

  /// The CLI's hint, when it gives one.
  final String? hint;
}

/// A commit a ref would push that is not ready (no description, no author, a
/// conflict, private, …).
final class PushCommitRejection {
  const PushCommitRejection({
    required this.commitId,
    required this.reasons,
    required this.message,
    this.hints = const [],
  });

  /// The rejected commit, full hex.
  final String commitId;

  /// The reasons, the CLI's words ("has no description", …).
  final List<String> reasons;

  /// The CLI's message ("Won't push commit … since it …").
  final String message;

  /// The CLI's hints.
  final List<String> hints;
}

/// One ref a push moves on one remote.
final class PushRef {
  const PushRef({
    required this.kind,
    required this.name,
    required this.path,
    required this.status,
    this.before,
    this.after,
    this.action,
    this.refusal,
    this.explicitRefusal,
    this.rejection,
    this.statusReason,
  });

  /// Bookmark or tag.
  final PushRefKind kind;

  /// The ref's name.
  final String name;

  /// The remote's target, full hex; `null` when absent there, or for a ref
  /// refused as conflicted or untracked.
  final String? before;

  /// The pushed target, full hex; `null` for a deletion, or for a ref refused
  /// as conflicted or untracked.
  final String? after;

  /// jj's words: "move forward from … to …", "add to …", "delete from …"; `null` for a
  /// ref refused as conflicted or untracked.
  final String? action;

  /// Push, skip or abort.
  final PushPath path;

  /// Why the mode refused the ref; `null` when it did not.
  final PushRefusal? refusal;

  /// What naming the ref explicitly (`-b` / `-t`) would get; `null` = the ref
  /// can be pushed explicitly.
  final PushRefusal? explicitRefusal;

  /// The commit check's rejection; `null` when the commit is ready.
  final PushCommitRejection? rejection;

  /// Where the row ended.
  final PushRefStatus status;

  /// The remote's reason for a rejected row.
  final String? statusReason;
}

/// A ref by kind and name.
final class PushRefName {
  const PushRefName({required this.kind, required this.name});

  /// Bookmark or tag.
  final PushRefKind kind;

  /// The ref's name.
  final String name;
}

/// The push to one remote.
final class PushRemote {
  const PushRemote({
    required this.name,
    required this.refs,
    required this.alreadyMatches,
    required this.finished,
    this.error,
  });

  /// The remote's name.
  final String name;

  /// The rows, in the CLI's order.
  final List<PushRef> refs;

  /// Explicit refs already where the push would put them ("Bookmark N@R
  /// already matches N").
  final List<PushRefName> alreadyMatches;

  /// The push to this remote ran.
  final bool finished;

  /// The error that stopped the push here; `null` when none did.
  final String? error;
}

/// A bookmark `--change` created.
final class PushCreatedBookmark {
  const PushCreatedBookmark({required this.name, required this.changeId});

  /// The bookmark's name (`push-…`).
  final String name;

  /// The change it points at.
  final String changeId;
}

/// What `git.sign-on-push` did.
final class PushSigning {
  const PushSigning({required this.updatedSignatures, required this.rebasedDescendants});

  /// Commits signed.
  final int updatedSignatures;

  /// Descendants rebased onto the signed commits.
  final int rebasedDescendants;
}

/// How a push did not fully succeed.
final class PushFailure {
  const PushFailure({required this.kind, required this.message, this.hint});

  /// The failure's kind.
  final PushFailureKind kind;

  /// The CLI's message.
  final String message;

  /// The CLI's hint, when it gives one.
  final String? hint;
}

/// Outcome of `gitPush` (mirrors `zanshin_jj::GitPushOutcome`). A push that
/// fails once the network is involved is DATA here ([failure]), not an error.
final class GitPushResult {
  const GitPushResult({
    required this.remotes,
    required this.createdBookmarks,
    required this.hints,
    required this.nothingChanged,
    required this.dryRun,
    required this.recorded,
    required this.newOpId,
    this.signing,
    this.description,
    this.failure,
    this.warnings = const [],
  });

  /// One entry per matched remote, sorted by name.
  final List<PushRemote> remotes;

  /// The bookmarks `--change` created.
  final List<PushCreatedBookmark> createdBookmarks;

  /// Hints to show verbatim.
  final List<String> hints;

  /// What sign-on-push did; `null` when it signed nothing.
  final PushSigning? signing;

  /// The CLI's "Nothing changed."
  final bool nothingChanged;

  /// This was a plan.
  final bool dryRun;

  /// An operation was written.
  final bool recorded;

  /// The operation's description; `null` when nothing changed.
  final String? description;

  /// The operation-log head after the call.
  final String newOpId;

  /// The failure; `null` on full success.
  final PushFailure? failure;

  /// The call's warnings; empty when there were none.
  final List<ZanshinWarning> warnings;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `GitPushResult` `Envelope` buffer into a [GitPushResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.gitPush`.
@visibleForTesting
GitPushResult decodeGitPushResultEnvelope(Uint8List bytes) => decodeGitPushResultEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
GitPushResult decodeGitPushResultEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.GitPushResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected GitPushResult payload, got ${env.dataType}');
  }
  final fbs.PushSigning? signing = payload.signing;
  final fbs.PushFailure? failure = payload.failure;
  return GitPushResult(
    remotes: [for (final remote in payload.remotes ?? const <fbs.PushRemote>[]) _remote(remote)],
    createdBookmarks: [
      for (final created in payload.createdBookmarks ?? const <fbs.PushCreatedBookmark>[])
        PushCreatedBookmark(
          name: created.name ?? _missing('created_bookmarks.name'),
          changeId: created.changeId ?? _missing('created_bookmarks.change_id'),
        ),
    ],
    hints: payload.hints ?? const [],
    signing: signing == null
        ? null
        : PushSigning(updatedSignatures: signing.updatedSignatures, rebasedDescendants: signing.rebasedDescendants),
    nothingChanged: payload.nothingChanged,
    dryRun: payload.dryRun,
    recorded: payload.recorded,
    description: payload.description,
    newOpId: payload.newOpId ?? _missing('new_op_id'),
    failure: failure == null
        ? null
        : PushFailure(
            kind: _failureKind(failure.kind),
            message: failure.message ?? _missing('failure.message'),
            hint: failure.hint,
          ),
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

PushRemote _remote(fbs.PushRemote remote) => PushRemote(
  name: remote.name ?? _missing('remotes.name'),
  refs: [for (final row in remote.refs ?? const <fbs.PushRef>[]) _ref(row)],
  alreadyMatches: [
    for (final name in remote.alreadyMatches ?? const <fbs.PushRefName>[])
      PushRefName(kind: _kind(name.kind), name: name.name ?? _missing('already_matches.name')),
  ],
  finished: remote.finished,
  error: remote.error,
);

PushRef _ref(fbs.PushRef row) {
  final fbs.PushCommitRejection? rejection = row.rejection;
  return PushRef(
    kind: _kind(row.kind),
    name: row.name ?? _missing('refs.name'),
    before: row.before,
    after: row.after,
    action: row.action,
    path: _path(row.path),
    refusal: _refusal(row.refusal),
    explicitRefusal: _refusal(row.explicitRefusal),
    rejection: rejection == null
        ? null
        : PushCommitRejection(
            commitId: rejection.commitId ?? _missing('rejection.commit_id'),
            reasons: rejection.reasons ?? const [],
            message: rejection.message ?? _missing('rejection.message'),
            hints: rejection.hints ?? const [],
          ),
    status: _status(row.status),
    statusReason: row.statusReason,
  );
}

PushRefusal? _refusal(fbs.PushRefusal? refusal) =>
    refusal == null ? null : PushRefusal(message: refusal.message ?? _missing('refusal.message'), hint: refusal.hint);

PushRefKind _kind(fbs.PushRefKind kind) => switch (kind) {
  fbs.PushRefKind.Bookmark => PushRefKind.bookmark,
  fbs.PushRefKind.Tag => PushRefKind.tag,
};

PushPath _path(fbs.PushPath path) => switch (path) {
  fbs.PushPath.Push => PushPath.push,
  fbs.PushPath.Skip => PushPath.skip,
  fbs.PushPath.Abort => PushPath.abort,
};

PushRefStatus _status(fbs.PushRefStatus status) => switch (status) {
  fbs.PushRefStatus.NotReached => PushRefStatus.notReached,
  fbs.PushRefStatus.Pushed => PushRefStatus.pushed,
  fbs.PushRefStatus.LeaseRejected => PushRefStatus.leaseRejected,
  fbs.PushRefStatus.RemoteRejected => PushRefStatus.remoteRejected,
};

PushFailureKind _failureKind(fbs.PushFailureKind kind) => switch (kind) {
  fbs.PushFailureKind.RefRefused => PushFailureKind.refRefused,
  fbs.PushFailureKind.CommitRejected => PushFailureKind.commitRejected,
  fbs.PushFailureKind.SomeRefsFailed => PushFailureKind.someRefsFailed,
  fbs.PushFailureKind.PushError => PushFailureKind.pushError,
  fbs.PushFailureKind.Cancelled => PushFailureKind.cancelled,
};

Never _missing(String field) => throw ZanshinFfiException('ffi.unknown', 'GitPushResult payload is missing its $field');
