// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'file_ops.dart' show SnapshotStats, decodeSnapshotStatsInternal;
import 'mutate.dart' show MutationResult, decodeMutationResultInternal;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.7's two workspace READ verbs: the
// adapters (workspaceList / workspaceRoot), the list-row model, and the two
// decoders — and of Story 9.23's two workspace MUTATIONS (workspaceAdd /
// workspaceUpdateStale): their adapters, models and decoders, including the
// `StaleRecovery` a `Precondition` carries when `snapshot.auto-update-stale`
// recovered in front of a verb. `dart:ffi` stays inside `ffi/` — only the worker isolate calls these
// adapters.
//
// The two verbs cross the boundary DIFFERENTLY, mirroring the CLI's own argument
// arity: `workspace list` is handle-only (its lone `-T/--template` flag is
// rendering), while `workspace root` sends a FlatBuffers REQUEST buffer, because
// its `--name` must be distinguishably ABSENT — that absence is what applies the
// CLI's documented default, the current workspace.
//
// They are also asymmetric when no path can be reported, deliberately: a
// [WorkspaceEntry.root] degrades to `null` while [workspaceRoot] refuses. The
// CLI's own list template degrades the same way. A recorded directory that no
// longer exists is reported by both (jj 0.46); [workspaceRoot] adds a warning.

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_workspace_list` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). No argument: `jj workspace list` takes none, and its
/// `-T/--template` flag is rendering.
Uint8List zanshinWorkspaceList(int rawHandle) => readToken(zanshin_workspace_list(rawHandle));

/// Call `zanshin_workspace_root` with the raw `u64` handle and a
/// `WorkspaceRootRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes.
///
/// A `null` [name] is the wire form of "the user did not supply `--name`", which
/// applies the CLI's own default — the CURRENT workspace — and reads the
/// workspace loader alone, the one path that cannot fail. A PRESENT [name], even
/// the current workspace's own, goes through the workspace store and can REFUSE
/// or WARN: the CLI's named path never shortcuts to the loader. An explicitly EMPTY [name]
/// is a VALUE, not an absence, and refuses as `jj.workspace_not_found`.
Uint8List zanshinWorkspaceRoot(int rawHandle, {String? name}) {
  rejectInteriorNul(name, 'name');
  final Uint8List request = fbs.WorkspaceRootRequestObjectBuilder(
    kind: fbs.RequestKind.WorkspaceRoot,
    name: name,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_workspace_root(rawHandle, ptr, len)));
}

/// Call `zanshin_workspace_add` with the raw `u64` handle and a
/// `WorkspaceAddRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes (Story 9.23) — the CLI's `jj workspace add`, every argument passed
/// through.
///
/// [destination] is resolved against the current workspace root (an absolute
/// path stays absolute). A `null` [name] is the CLI's default — the
/// destination's final component; an EMPTY [name] is a value and refused.
/// [revisions] are the CLI's repeatable `-r` revsets, [messageParagraphs] its
/// repeatable `-m`. [colocate] `true`/`false` are `--colocate`/`--no-colocate`;
/// `null` leaves the decision to the CLI's default (colocated current workspace
/// and `git.colocate`). [sparse] is `--sparse-patterns`.
Uint8List zanshinWorkspaceAdd(
  int rawHandle, {
  required String destination,
  String? name,
  List<String> revisions = const [],
  List<String> messageParagraphs = const [],
  bool? colocate,
  SparseInheritance sparse = SparseInheritance.copy,
}) {
  rejectInteriorNul(destination, 'destination');
  rejectInteriorNul(name, 'name');
  rejectInteriorNuls(revisions, 'revisions');
  rejectInteriorNuls(messageParagraphs, 'messageParagraphs');
  final Uint8List request = fbs.WorkspaceAddRequestObjectBuilder(
    kind: fbs.RequestKind.WorkspaceAdd,
    destination: destination,
    name: name,
    revisions: revisions,
    messageParagraphs: messageParagraphs,
    colocate: colocate ?? false,
    noColocate: colocate == false,
    sparsePatterns: switch (sparse) {
      SparseInheritance.copy => fbs.SparseInheritance.Copy,
      SparseInheritance.full => fbs.SparseInheritance.Full,
      SparseInheritance.empty => fbs.SparseInheritance.Empty,
    },
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_workspace_add(rawHandle, ptr, len));
}

/// Call `zanshin_workspace_update_stale` with the raw `u64` handle and return
/// the FlatBuffers `Envelope` bytes (Story 9.23) — the CLI's `jj workspace
/// update-stale`. No argument: the CLI verb takes none.
Uint8List zanshinWorkspaceUpdateStale(int rawHandle) => readToken(zanshin_workspace_update_stale(rawHandle));

// ── Dart models ──────────────────────────────────────────────────────────────

/// How `workspaceAdd` sets the new workspace's sparse patterns — the CLI's
/// `--sparse-patterns` (mirrors `zanshin_jj::SparseInheritance`).
enum SparseInheritance {
  /// Copy the current workspace's sparse patterns (the CLI's default).
  copy,

  /// Include every file.
  full,

  /// No file at all — the workspace starts empty.
  empty,
}

/// What a working-copy checkout did to the files on disk (mirrors
/// `zanshin_jj::CheckoutStats`) — the counts behind the CLI's "Added N files,
/// modified N files, removed N files".
final class CheckoutStats {
  const CheckoutStats({required this.added, required this.updated, required this.removed, required this.skipped});

  /// Files that did not exist before.
  final int added;

  /// Files that existed before and changed.
  final int updated;

  /// Files the checkout removed.
  final int removed;

  /// Updates skipped because an untracked file was in the way — the data behind
  /// the `jj.checkout_files_skipped` warning.
  final int skipped;
}

/// Which arm of the stale-working-copy recovery ran (mirrors
/// `zanshin_jj::StaleRecoveryOutcome`).
enum StaleRecoveryOutcome {
  /// The working copy was not stale; nothing was checked out.
  notStale,

  /// The working copy was checked out onto the fresh `@`.
  updated,

  /// The working copy's operation was missing, so a recovery commit holding the
  /// files on disk was created and checked out.
  recovered,
}

/// What leaving a stale working copy did (mirrors `zanshin_jj::StaleRecovery`)
/// — `RepoHandle.workspaceUpdateStale`'s result, and `Precondition.staleRecovery`
/// when `snapshot.auto-update-stale = true` recovered in front of a verb.
final class StaleRecovery {
  const StaleRecovery({
    required this.outcome,
    required this.commitId,
    required this.checkout,
    required this.gitHeadResetOpId,
    required this.snapshotStats,
    required this.opId,
    this.warnings = const [],
  });

  /// Which arm ran.
  final StaleRecoveryOutcome outcome;

  /// Full hex id of the fresh `@` ([StaleRecoveryOutcome.updated]) or of the
  /// recovery commit ([StaleRecoveryOutcome.recovered]); `null` when not stale.
  final String? commitId;

  /// What the checkout did; non-null only for [StaleRecoveryOutcome.updated].
  final CheckoutStats? checkout;

  /// The `reset git head` operation a colocated workspace wrote before the
  /// checkout; `null` otherwise.
  final String? gitHeadResetOpId;

  /// What the recovery's snapshots could not record, merged.
  final SnapshotStats snapshotStats;

  /// The head operation after the recovery.
  final String opId;

  /// The call's warnings when this is `workspaceUpdateStale`'s result, in the
  /// CLI's print order (e.g. `jj.checkout_files_skipped`, then
  /// `jj.unresolved_conflicts` when the fresh `@` has conflicts); always empty
  /// on a `Precondition.staleRecovery`.
  final List<ZanshinWarning> warnings;
}

/// Outcome of a successful `workspaceAdd` (mirrors
/// `zanshin_jj::WorkspaceAddResult`).
final class WorkspaceAddResult {
  const WorkspaceAddResult({
    required this.mutation,
    required this.workspaceName,
    required this.workspaceRoot,
    required this.gitWorktreeCreated,
    required this.checkout,
    this.warnings = const [],
  });

  /// The call's last operation, `create initial working-copy commit in
  /// workspace NAME`; its `workingCopyChangeId` is the NEW workspace's `@`.
  final MutationResult mutation;

  /// The new workspace's name.
  final String workspaceName;

  /// The new workspace's root directory, absolute and canonical — what
  /// `ZanshinWorker.openRepo` opens it with.
  final String workspaceRoot;

  /// Whether a Git worktree was created for it.
  final bool gitWorktreeCreated;

  /// What checking the new `@` out into the destination did.
  final CheckoutStats checkout;

  /// The call's warnings, in the CLI's print order (e.g.
  /// `jj.workspace_in_current_directory`); empty when there were none.
  final List<ZanshinWarning> warnings;
}

/// One row of `jj workspace list` (mirrors `zanshin_jj::WorkspaceEntry`).
final class WorkspaceEntry {
  const WorkspaceEntry({required this.name, required this.wcCommitId, required this.root});

  /// The jj workspace name (`"default"` in a single-workspace repo).
  final String name;

  /// Hex commit id of that workspace's working-copy commit — the entry jj's
  /// `View::wc_commit_ids()` holds for this workspace name. For the CURRENT
  /// workspace it is the commit whose change id `status.dart`'s
  /// `WorkingCopyStatus.workingCopyChangeId` reports.
  final String wcCommitId;

  /// Absolute RECORDED path of the workspace's root directory — reported even
  /// when that directory moved or was deleted (jj 0.46) — or `null` when no path
  /// can be reported: the workspace predates jj 0.38.0 and has no recorded path,
  /// or the store is unreadable. Null-for-absence — never a sentinel — and never
  /// a reason for the listing to fail.
  final String? root;
}

/// The result of `workspaceRoot` (Story 9.32): the absolute root path plus the
/// call's warnings.
final class WorkspaceRootResult {
  const WorkspaceRootResult({required this.path, this.warnings = const []});

  /// Absolute path of the named workspace's root directory.
  final String path;

  /// The call's warnings, in the CLI's print order; empty when there were none.
  final List<ZanshinWarning> warnings;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `WorkspaceList` `Envelope` buffer into a `List<WorkspaceEntry>` that
/// also carries the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.workspaceList`.
@visibleForTesting
WarnedList<WorkspaceEntry> decodeWorkspaceListEnvelope(Uint8List bytes) => _decodeWorkspaceListEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<WorkspaceEntry> decodeWorkspaceListEnvelopeInternal(Uint8List bytes) => _decodeWorkspaceListEnvelope(bytes);

WarnedList<WorkspaceEntry> _decodeWorkspaceListEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.WorkspaceList) {
    throw ZanshinFfiException('ffi.unknown', 'expected WorkspaceList payload, got ${env.dataType}');
  }
  return WarnedList(
    payload.entries?.map(_mapWorkspaceEntry).toList() ?? const [],
    decodeEnvelopeWarningsInternal(env),
  );
}

WorkspaceEntry _mapWorkspaceEntry(fbs.WorkspaceEntry e) => WorkspaceEntry(
  name: e.name ?? '',
  wcCommitId: e.wcCommitId ?? '',
  // Null-for-absence, not a sentinel: an absent root means the path cannot be
  // reported, which is a modelled state rather than an error.
  root: e.root,
);

/// Decode a `WorkspaceRoot` `Envelope` buffer into the absolute root path and
/// the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.workspaceRoot`.
@visibleForTesting
WorkspaceRootResult decodeWorkspaceRootEnvelope(Uint8List bytes) => _decodeWorkspaceRootEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WorkspaceRootResult decodeWorkspaceRootEnvelopeInternal(Uint8List bytes) => _decodeWorkspaceRootEnvelope(bytes);

WorkspaceRootResult _decodeWorkspaceRootEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.WorkspaceRoot) {
    throw ZanshinFfiException('ffi.unknown', 'expected WorkspaceRoot payload, got ${env.dataType}');
  }
  final String? root = payload.root;
  if (root == null) {
    // Unlike a list row's root, this field is ALWAYS written on success — the
    // verb refuses rather than reporting an absent path. A missing one is a
    // malformed buffer, not a modellable state.
    throw const ZanshinFfiException('ffi.unknown', 'WorkspaceRoot payload is missing its root');
  }
  return WorkspaceRootResult(path: root, warnings: decodeEnvelopeWarningsInternal(env));
}

/// Decode a `WorkspaceAddResult` `Envelope` buffer into a [WorkspaceAddResult].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.workspaceAdd`.
@visibleForTesting
WorkspaceAddResult decodeWorkspaceAddEnvelope(Uint8List bytes) => decodeWorkspaceAddEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WorkspaceAddResult decodeWorkspaceAddEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.WorkspaceAddResult) {
    throw ZanshinFfiException('ffi.unknown', 'expected WorkspaceAddResult payload, got ${env.dataType}');
  }
  // Rust always writes these on success, so a missing one is a malformed buffer, not a
  // modellable state — refused rather than guessed, as for WorkspaceRoot's root.
  return WorkspaceAddResult(
    mutation: decodeMutationResultInternal(payload.mutation),
    workspaceName: payload.workspaceName ?? _missing('WorkspaceAddResult', 'workspace_name'),
    workspaceRoot: payload.workspaceRoot ?? _missing('WorkspaceAddResult', 'workspace_root'),
    gitWorktreeCreated: payload.gitWorktreeCreated,
    checkout: _decodeCheckoutStats(payload.checkout) ?? _missing('WorkspaceAddResult', 'checkout'),
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `StaleRecovery` `Envelope` buffer into a [StaleRecovery] carrying
/// the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.workspaceUpdateStale`.
@visibleForTesting
StaleRecovery decodeStaleRecoveryEnvelope(Uint8List bytes) => decodeStaleRecoveryEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
StaleRecovery decodeStaleRecoveryEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.StaleRecovery) {
    throw ZanshinFfiException('ffi.unknown', 'expected StaleRecovery payload, got ${env.dataType}');
  }
  return decodeStaleRecoveryInternal(payload, warnings: decodeEnvelopeWarningsInternal(env))!;
}

/// Rebuild a [StaleRecovery]; an ABSENT table is `null` (null for absence).
/// Shared by `workspaceUpdateStale` and `Precondition.staleRecovery`.
StaleRecovery? decodeStaleRecoveryInternal(fbs.StaleRecovery? r, {List<ZanshinWarning> warnings = const []}) =>
    r == null
    ? null
    : StaleRecovery(
        outcome: switch (r.outcome) {
          fbs.StaleRecoveryOutcome.NotStale => StaleRecoveryOutcome.notStale,
          fbs.StaleRecoveryOutcome.Updated => StaleRecoveryOutcome.updated,
          fbs.StaleRecoveryOutcome.Recovered => StaleRecoveryOutcome.recovered,
        },
        commitId: r.commitId,
        checkout: _decodeCheckoutStats(r.checkout),
        gitHeadResetOpId: r.gitHeadResetOpId,
        snapshotStats: decodeSnapshotStatsInternal(r.snapshotStats),
        opId: r.opId ?? _missing('StaleRecovery', 'op_id'),
        warnings: warnings,
      );

/// Refuses a payload whose required field [field] of [table] is absent.
Never _missing(String table, String field) =>
    throw ZanshinFfiException('ffi.unknown', '$table payload is missing its $field');

CheckoutStats? _decodeCheckoutStats(fbs.CheckoutStats? c) =>
    c == null ? null : CheckoutStats(added: c.added, updated: c.updated, removed: c.removed, skipped: c.skipped);

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  return env;
}
