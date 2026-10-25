// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'bookmarks.dart' show RefDistance;
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_op_log` with the raw `u64` handle and an `i64` limit, and
/// return the FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). `limit < 0` means all operations.
Uint8List zanshinOpLog(int rawHandle, int limit) => readToken(zanshin_op_log(rawHandle, limit));

/// Call `zanshin_op_show` with the raw `u64` handle and an `OpShowRequest`
/// request buffer (Story 9.21), and return the FlatBuffers `Envelope` bytes.
///
/// A `null` [operation] is `@`; a `null` [showChangesIn] reads
/// `revsets.op-diff-changes-in` — both cross ABSENT.
Uint8List zanshinOpShow(int rawHandle, {String? operation, String? showChangesIn}) {
  rejectInteriorNul(operation, 'operation');
  rejectInteriorNul(showChangesIn, 'showChangesIn');
  final Uint8List request = fbs.OpShowRequestObjectBuilder(
    kind: fbs.RequestKind.OpShow,
    operation: operation,
    showChangesIn: showChangesIn,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_op_show(rawHandle, ptr, len));
}

/// Call `zanshin_op_diff` with the raw `u64` handle and an `OpDiffRequest`
/// request buffer (Story 9.21), and return the FlatBuffers `Envelope` bytes.
/// Every `null` crosses ABSENT — the CLI's flag not given.
Uint8List zanshinOpDiff(int rawHandle, {String? operation, String? from, String? to, String? showChangesIn}) {
  rejectInteriorNul(operation, 'operation');
  rejectInteriorNul(from, 'from');
  rejectInteriorNul(to, 'to');
  rejectInteriorNul(showChangesIn, 'showChangesIn');
  final Uint8List request = fbs.OpDiffRequestObjectBuilder(
    kind: fbs.RequestKind.OpDiff,
    operation: operation,
    from: from,
    to: to,
    showChangesIn: showChangesIn,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_op_diff(rawHandle, ptr, len));
}

/// Call `zanshin_op_abandon` with the raw `u64` handle and [operation] (a lone
/// C string, Story 9.21), and return the FlatBuffers `Envelope` bytes.
Uint8List zanshinOpAbandon(int rawHandle, String operation) {
  rejectInteriorNul(operation, 'operation');
  final ffi.Pointer<Utf8> p = operation.toNativeUtf8();
  try {
    return readToken(zanshin_op_abandon(rawHandle, p.cast()));
  } finally {
    calloc.free(p); // outer: free the C string we allocated
  }
}

/// Call `zanshin_op_restore` with the raw `u64` handle and an
/// `OpRestoreRequest` request buffer (Story 9.12), and return the FlatBuffers
/// `Envelope` bytes. An empty [what] crosses EMPTY — the CLI without `--what`.
Uint8List zanshinOpRestore(int rawHandle, String operation, {List<RestoreWhat> what = const []}) {
  rejectInteriorNul(operation, 'operation');
  final Uint8List request = fbs.OpRestoreRequestObjectBuilder(
    kind: fbs.RequestKind.OpRestore,
    operation: operation,
    what: [for (final RestoreWhat portion in what) portion.wire],
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_op_restore(rawHandle, ptr, len));
}

/// Call `zanshin_op_revert` with the raw `u64` handle and an `OpRevertRequest`
/// request buffer (Story 9.12), and return the FlatBuffers `Envelope` bytes.
/// An empty [what] crosses EMPTY — the CLI without `--what`.
Uint8List zanshinOpRevert(int rawHandle, String operation, {List<RestoreWhat> what = const []}) {
  rejectInteriorNul(operation, 'operation');
  final Uint8List request = fbs.OpRevertRequestObjectBuilder(
    kind: fbs.RequestKind.OpRevert,
    operation: operation,
    what: [for (final RestoreWhat portion in what) portion.wire],
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_op_revert(rawHandle, ptr, len));
}

/// Call `zanshin_op_integrate` with the raw `u64` handle and [operation] (a
/// lone C string, Story 9.12), and return the FlatBuffers `Envelope` bytes.
Uint8List zanshinOpIntegrate(int rawHandle, String operation) {
  rejectInteriorNul(operation, 'operation');
  final ffi.Pointer<Utf8> p = operation.toNativeUtf8();
  try {
    return readToken(zanshin_op_integrate(rawHandle, p.cast()));
  } finally {
    calloc.free(p); // outer: free the C string we allocated
  }
}

// ── Dart models ───────────────────────────────────────────────────────────────

/// One `--what` value of `jj op restore` / `jj op revert` (Story 9.12) — the
/// CLI's `RevertWhatToRestore`. An empty list is the flag absent: both.
enum RestoreWhat {
  /// `repo`: the jj repo state and local bookmarks — heads, local bookmarks
  /// and tags, the working-copy commits.
  repo(fbs.RestoreWhat.Repo),

  /// `remote-tracking`: the remote-tracking bookmarks. The CLI's advice: "Do
  /// not restore these if you'd like to push after the undo".
  remoteTracking(fbs.RestoreWhat.RemoteTracking);

  const RestoreWhat(this.wire);

  /// The wire value.
  final fbs.RestoreWhat wire;
}

/// One entry in jj's operation log (FR-JJ-7).
///
/// `user`/`host` are UTF-8 by construction (jj-lib guarantees it).
final class Operation {
  const Operation({
    required this.id,
    required this.parentIds,
    required this.timestampMillis,
    required this.tzOffsetMinutes,
    required this.user,
    required this.host,
    required this.description,
    required this.rootOp,
    required this.isSnapshot,
    this.workspaceName,
    this.tags = const [],
  });

  /// Op id in plain forward-hex form (NOT reverse-hex).
  final String id;

  /// Parent op ids in jj order; empty for the root op; >1 for a DAG fork.
  final List<String> parentIds;

  /// Op end-time, milliseconds since the Unix epoch.
  final int timestampMillis;

  /// Timezone offset, minutes east of UTC.
  final int tzOffsetMinutes;

  /// `metadata.username`; may be empty.
  final String user;

  /// `metadata.hostname`; may be empty.
  final String host;

  /// jj's user-friendly op description; always present, may be empty.
  final String description;

  /// `true` iff this is the op-store root operation.
  final bool rootOp;

  /// `true` if a pure working-copy snapshot op.
  final bool isSnapshot;

  /// The workspace the operation was performed in; `null` when it records
  /// none (the root, an operation another tool wrote) — Story 9.21.
  final String? workspaceName;

  /// The operation's tags (jj's operation attributes), sorted by key — Story
  /// 9.21.
  final List<OperationTag> tags;
}

/// One tag of an [Operation] (Story 9.21).
final class OperationTag {
  const OperationTag({required this.key, required this.value});

  /// The tag's key.
  final String key;

  /// Its value.
  final String value;
}

/// A ref target as `jj op diff` summarises it (mirrors
/// `zanshin_jj::OpRefTarget`): absent ([adds] empty, not [conflicted]), one
/// commit, or a conflict's present adds and removes. Hex commit ids.
final class OpRefTarget {
  const OpRefTarget({required this.adds, required this.removes, required this.conflicted});

  /// The commit a normal target points at, or a conflict's added commits.
  final List<String> adds;

  /// A conflict's removed commits; empty unless [conflicted].
  final List<String> removes;

  /// Whether the target is a conflict.
  final bool conflicted;

  /// Whether the target is absent (no commit).
  bool get isAbsent => adds.isEmpty && !conflicted;
}

/// One changed commit of an operation diff (mirrors
/// `zanshin_jj::OpChangedCommit`): the CLI's `+` / `-` lines as ids.
final class OpChangedCommit {
  const OpChangedCommit({
    required this.commitId,
    required this.abandoned,
    required this.addedCommitIds,
    required this.removedCommitIds,
  });

  /// The row's key: the new commit, or the old one when [abandoned].
  final String commitId;

  /// Whether the change was abandoned.
  final bool abandoned;

  /// The commit the change now is; empty when [abandoned].
  final List<String> addedCommitIds;

  /// The commits it replaced (its predecessors), or the abandoned commit. The
  /// CLI's `--patch` inter-diffs from the FIRST predecessor only, and shows an
  /// abandoned commit's own patch (`show_change_diff`).
  final List<String> removedCommitIds;
}

/// The commit section of an operation diff (mirrors
/// `zanshin_jj::OpCommitsDiff`).
final class OpCommitsDiff {
  const OpCommitsDiff({required this.changes, required this.elidedNewlyVisible, required this.elidedNewlyHidden});

  /// The changed commits in revset order.
  final List<OpChangedCommit> changes;

  /// Newly visible commits outside `showChangesIn` (the CLI's "Elided …").
  final RefDistance elidedNewlyVisible;

  /// Newly hidden commits outside `showChangesIn`.
  final RefDistance elidedNewlyHidden;
}

/// A workspace whose working-copy commit changed (mirrors
/// `zanshin_jj::OpWorkingCopyChange`).
final class OpWorkingCopyChange {
  const OpWorkingCopyChange({required this.workspace, this.from, this.to});

  /// The workspace name.
  final String workspace;

  /// The working-copy commit before; `null` when the workspace did not exist.
  final String? from;

  /// The working-copy commit after; `null` when the workspace was removed.
  final String? to;
}

/// A local bookmark or tag whose target changed (mirrors
/// `zanshin_jj::OpRefChange`).
final class OpRefChange {
  const OpRefChange({required this.name, required this.from, required this.to});

  /// The ref's name.
  final String name;

  /// The target before.
  final OpRefTarget from;

  /// The target after.
  final OpRefTarget to;
}

/// A remote bookmark or tag whose target or tracking state changed (mirrors
/// `zanshin_jj::OpRemoteRefChange`).
final class OpRemoteRefChange {
  const OpRemoteRefChange({
    required this.name,
    required this.remote,
    required this.from,
    required this.fromTracked,
    required this.to,
    required this.toTracked,
  });

  /// The ref's name.
  final String name;

  /// The remote's name.
  final String remote;

  /// The target before.
  final OpRefTarget from;

  /// Whether it was tracked before.
  final bool fromTracked;

  /// The target after.
  final OpRefTarget to;

  /// Whether it is tracked after.
  final bool toTracked;
}

/// The repository changes between two operations (mirrors
/// `zanshin_jj::OpDiff`), in the CLI's section order.
final class OpDiff {
  const OpDiff({
    required this.commits,
    required this.workingCopies,
    required this.localBookmarks,
    required this.localTags,
    required this.remoteBookmarks,
    required this.remoteTags,
  });

  /// The changed commits; `null` when `showChangesIn` did not resolve (warned
  /// `jj.op_diff_changes_unresolved`).
  final OpCommitsDiff? commits;

  /// The workspaces whose working-copy commit changed.
  final List<OpWorkingCopyChange> workingCopies;

  /// The local bookmarks whose target changed.
  final List<OpRefChange> localBookmarks;

  /// The local tags whose target changed.
  final List<OpRefChange> localTags;

  /// The remote bookmarks that changed (a Git repo's `git` remote left out).
  final List<OpRemoteRefChange> remoteBookmarks;

  /// The remote tags that changed.
  final List<OpRemoteRefChange> remoteTags;
}

/// What `RepoHandle.opShow` returns (Story 9.21).
final class OpShow {
  const OpShow({required this.operation, this.diff, this.warnings = const []});

  /// The operation.
  final Operation operation;

  /// Its changes against its parent; `null` for an operation with more than
  /// one parent (the CLI prints no diff).
  final OpDiff? diff;

  /// The call's warnings; empty when there were none.
  final List<ZanshinWarning> warnings;
}

/// What `RepoHandle.opDiff` returns (Story 9.21).
final class OpDiffResult {
  const OpDiffResult({required this.from, required this.to, required this.diff, this.warnings = const []});

  /// The operations diffed from (one for `from`, else the operation's
  /// parents — none for the root).
  final List<Operation> from;

  /// The operation diffed to.
  final Operation to;

  /// The changes.
  final OpDiff diff;

  /// The call's warnings; empty when there were none.
  final List<ZanshinWarning> warnings;
}

/// What `RepoHandle.opAbandon` returns (Story 9.21) — the CLI's status lines
/// as facts.
final class OpAbandonResult {
  const OpAbandonResult({
    required this.abandonedCount,
    required this.reparentedCount,
    required this.nothingChanged,
    required this.headOpIds,
    this.warnings = const [],
  });

  /// Operations that became unreachable; 0 when [nothingChanged].
  final int abandonedCount;

  /// Descendant operations rewritten; 0 when [nothingChanged].
  final int reparentedCount;

  /// The range was empty: the CLI's "Nothing changed.".
  final bool nothingChanged;

  /// The op heads afterwards.
  final List<String> headOpIds;

  /// The call's warnings; empty when there were none.
  final List<ZanshinWarning> warnings;
}

/// What `RepoHandle.opIntegrate` returns (Story 9.12).
final class OpIntegrateResult {
  const OpIntegrateResult({required this.headOpId, required this.reconciled, this.warnings = const []});

  /// The head operation afterwards: the integrated operation, the merge that
  /// reconciled it, or the unchanged head for an operation already in the log.
  final String headOpId;

  /// The integrate itself merged the op heads (the CLI's status line "The
  /// specified operation has been integrated with other existing
  /// operations."); a reconcile the head load wrote first does not count.
  final bool reconciled;

  /// The call's warnings; empty when there were none.
  final List<ZanshinWarning> warnings;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode an `OpLog` `Envelope` buffer into a list of [Operation]s that also
/// carries the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.opLog`.
@visibleForTesting
WarnedList<Operation> decodeOpLogEnvelope(Uint8List bytes) => _decodeOpLogEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<Operation> decodeOpLogEnvelopeInternal(Uint8List bytes) => _decodeOpLogEnvelope(bytes);

WarnedList<Operation> _decodeOpLogEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.OpLog) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected OpLog payload, got ${env.dataType}',
    );
  }
  return WarnedList(
    payload.operations?.map(_mapOperation).toList() ?? const [],
    decodeEnvelopeWarningsInternal(env),
  );
}

Operation _mapOperation(fbs.Operation o) => Operation(
  id: o.id ?? '',
  parentIds: o.parentIds?.toList() ?? const [],
  timestampMillis: o.timestampMillis,
  tzOffsetMinutes: o.tzOffsetMinutes,
  user: o.user ?? '',
  host: o.host ?? '',
  description: o.description ?? '',
  rootOp: o.rootOp,
  isSnapshot: o.isSnapshot,
  workspaceName: o.workspaceName,
  tags: [for (final fbs.OperationTag t in o.tags ?? const []) OperationTag(key: t.key ?? '', value: t.value ?? '')],
);

/// Decode an `OpShow` `Envelope` buffer into an [OpShow] (Story 9.21).
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.opShow`.
@visibleForTesting
OpShow decodeOpShowEnvelope(Uint8List bytes) => decodeOpShowEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
OpShow decodeOpShowEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.OpShow) {
    throw ZanshinFfiException('ffi.unknown', 'expected OpShow payload, got ${env.dataType}');
  }
  final fbs.OpDiff? diff = payload.diff;
  return OpShow(
    operation: _mapOperation(
      payload.operation ?? (throw const ZanshinFfiException('ffi.unknown', 'OpShow payload is missing its operation')),
    ),
    diff: diff == null ? null : _mapDiff(diff),
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode an `OpDiffResult` `Envelope` buffer into an [OpDiffResult] (Story
/// 9.21).
@visibleForTesting
OpDiffResult decodeOpDiffResultEnvelope(Uint8List bytes) => decodeOpDiffResultEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
OpDiffResult decodeOpDiffResultEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.OpDiffResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected OpDiffResult payload, got ${env.dataType}');
  }
  return OpDiffResult(
    from: payload.from?.map(_mapOperation).toList() ?? const [],
    to: _mapOperation(
      payload.to ?? (throw const ZanshinFfiException('ffi.unknown', 'OpDiffResult payload is missing its to')),
    ),
    diff: _mapDiff(
      payload.diff ?? (throw const ZanshinFfiException('ffi.unknown', 'OpDiffResult payload is missing its diff')),
    ),
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode an `OpAbandonResult` `Envelope` buffer into an [OpAbandonResult]
/// (Story 9.21).
@visibleForTesting
OpAbandonResult decodeOpAbandonResultEnvelope(Uint8List bytes) => decodeOpAbandonResultEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
OpAbandonResult decodeOpAbandonResultEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.OpAbandonResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected OpAbandonResult payload, got ${env.dataType}');
  }
  return OpAbandonResult(
    abandonedCount: payload.abandonedCount,
    reparentedCount: payload.reparentedCount,
    nothingChanged: payload.nothingChanged,
    headOpIds: payload.headOpIds ?? const [],
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode an `OpIntegrateResult` `Envelope` buffer into an
/// [OpIntegrateResult] (Story 9.12).
@visibleForTesting
OpIntegrateResult decodeOpIntegrateResultEnvelope(Uint8List bytes) => decodeOpIntegrateResultEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
OpIntegrateResult decodeOpIntegrateResultEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.OpIntegrateResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected OpIntegrateResult payload, got ${env.dataType}');
  }
  return OpIntegrateResult(
    headOpId:
        payload.headOpId ??
        (throw const ZanshinFfiException('ffi.unknown', 'OpIntegrateResult payload is missing its head_op_id')),
    reconciled: payload.reconciled,
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

OpDiff _mapDiff(fbs.OpDiff d) {
  final fbs.OpCommitsDiff? commits = d.commits;
  return OpDiff(
    commits: commits == null
        ? null
        : OpCommitsDiff(
            changes: [
              for (final fbs.OpChangedCommit c in commits.changes ?? const [])
                OpChangedCommit(
                  commitId: c.commitId ?? '',
                  abandoned: c.abandoned,
                  addedCommitIds: c.addedCommitIds ?? const [],
                  removedCommitIds: c.removedCommitIds ?? const [],
                ),
            ],
            elidedNewlyVisible: _mapDistance(commits.elidedNewlyVisible),
            elidedNewlyHidden: _mapDistance(commits.elidedNewlyHidden),
          ),
    workingCopies: [
      for (final fbs.OpWorkingCopyChange w in d.workingCopies ?? const [])
        OpWorkingCopyChange(workspace: w.workspace ?? '', from: w.from, to: w.to),
    ],
    localBookmarks: [for (final fbs.OpRefChange r in d.localBookmarks ?? const []) _mapRefChange(r)],
    localTags: [for (final fbs.OpRefChange r in d.localTags ?? const []) _mapRefChange(r)],
    remoteBookmarks: [for (final fbs.OpRemoteRefChange r in d.remoteBookmarks ?? const []) _mapRemoteRefChange(r)],
    remoteTags: [for (final fbs.OpRemoteRefChange r in d.remoteTags ?? const []) _mapRemoteRefChange(r)],
  );
}

/// An absent distance table reads as "none elided" — the producer always writes it.
RefDistance _mapDistance(fbs.RefDistance? d) =>
    d == null ? const RefDistance(lower: 0, upper: 0) : RefDistance(lower: d.lower, upper: d.hasUpper ? d.upper : null);

/// Rebuild an [OpRefTarget] — shared with `git.dart`'s `GitColocationStatus.gitHead` (Story 9.45).
OpRefTarget decodeOpRefTargetInternal(fbs.OpRefTarget? t) => _mapTarget(t);

OpRefTarget _mapTarget(fbs.OpRefTarget? t) =>
    OpRefTarget(adds: t?.adds ?? const [], removes: t?.removes ?? const [], conflicted: t?.conflicted ?? false);

OpRefChange _mapRefChange(fbs.OpRefChange r) =>
    OpRefChange(name: r.name ?? '', from: _mapTarget(r.from), to: _mapTarget(r.to));

OpRemoteRefChange _mapRemoteRefChange(fbs.OpRemoteRefChange r) => OpRemoteRefChange(
  name: r.name ?? '',
  remote: r.remote ?? '',
  from: _mapTarget(r.from),
  fromTracked: r.fromTracked,
  to: _mapTarget(r.to),
  toTracked: r.toTracked,
);
