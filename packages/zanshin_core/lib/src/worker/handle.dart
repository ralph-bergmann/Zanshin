// SPDX-License-Identifier: MIT

import '../ffi/bookmarks.dart' show Bookmark;
import '../ffi/change.dart' show Change;
import '../ffi/commit_contents.dart' show CommitContent;
import '../ffi/commit_views.dart' show ChangeIdRef, CommitIdRef, EvologEntry, InterdiffView, RevisionRef, ShowEntry;
import '../ffi/file.dart' show AnnotationLine, FileContents, FileEntry, FileSearch;
import '../ffi/file_ops.dart' show TrackResult, UntrackResult;
import '../ffi/git.dart' show GitExportResult, GitImportResult;
import '../ffi/graph.dart'
    show GraphTopologyView, defaultGraphAnchors, defaultGraphPrioritize, defaultLogRevset, defaultShortPrefixes;
import '../ffi/log_defaults.dart' show LogDefaults;
import '../ffi/mutate.dart' show AbsorbResult, MutationResult;
import '../ffi/op_log.dart' show Operation;
import '../ffi/precondition.dart' show Precondition;
import '../ffi/push.dart' show GitPushResult;
import '../ffi/remotes.dart' show Remote, RemoteRefChange;
import '../ffi/squash_split.dart' show SplitResult, SquashPlan;
import '../ffi/status.dart' show WorkingCopyStatus;
import '../ffi/warning.dart' show WarnedList, ZanshinWarning;
import '../ffi/workspace.dart'
    show SparseInheritance, StaleRecovery, WorkspaceAddResult, WorkspaceEntry, WorkspaceRootResult;
import '../graph_layout/graph_grid_view.dart' show GraphGridView;
import '../graph_layout/layout_request.dart'
    show LaneOrder, LayoutContractException, LayoutMode, defaultLaneOrder, defaultLayoutBudget, defaultLayoutMode;
import 'isolate.dart';
import 'network_operation.dart';
import 'responses.dart';

/// Main-isolate wrapper around an open jj repository (Model A, Story 3.9).
///
/// Holds an opaque [handleId] that the worker resolves to its internal
/// `*mut Repo` pointer. Raw handles never leave the worker — this class
/// contains only integers.
///
/// Lifecycle:
/// - Created — as an [OpenedRepoHandle] — by [ZanshinWorker.openRepo], or — as
///   a [CreatedRepoHandle] — by [ZanshinWorker.initRepo] /
///   [ZanshinWorker.cloneRepo] / [ZanshinWorker.convert].
/// - Closed explicitly via [close], or implicitly when GC runs the
///   Dart [Finalizer] (belt-and-suspenders).
///
/// Every command's result exposes the call's `warnings` (Story 9.32), exactly
/// as the [ZanshinWorker] method it forwards to; [close] carries none.
///
/// The `NativeFinalizer` rule in project-context applies to wrappers whose
/// callback is a C function pointer. This class frees a resource across the
/// isolate boundary via a Dart call — a Dart [Finalizer] is correct (R4).
final class RepoHandle {
  /// Wrap `handleId` returned by the worker for the given `worker`.
  RepoHandle(this._worker, this._handleId) {
    _finalizer.attach(this, (_worker, _handleId), detach: this);
  }

  final ZanshinWorker _worker;
  final int _handleId;
  var _closed = false;

  /// The opaque dense id in the worker's handle table.
  ///
  /// 3.4b read commands pass this to [ZanshinWorker.send] as the handle
  /// discriminant, e.g. `StatusCommand(commandId: id, handleId: handleId)`.
  int get handleId => _handleId;

  /// The pre-verb snapshot report (Story 9.26) of the latest reply for this
  /// handle that carried one — ok OR error — or `null` before the first.
  ///
  /// Every snapshotting verb (all reads and mutations except [logDefaults],
  /// [workspaceRoot] and the op-pinned [commitContents], Story 4.10) first
  /// snapshots the working copy and, in a colocated
  /// workspace, imports the Git HEAD and refs, exactly as each jj CLI command
  /// does. That can write operations the caller did not ask for; this is where
  /// the facts the CLI would have printed land. On an error it is PARTIAL — up to
  /// the failing step — and, when the error envelope carries one, the same
  /// report the thrown [ZanshinFfiException.precondition] carries, beside that
  /// call's [ZanshinFfiException.warnings] (Story 9.35). An error without one
  /// (e.g. `ffi.invalid_handle`) leaves this at the previous report while the
  /// exception's is `null`.
  Precondition? get lastPrecondition => _worker.lastPreconditionOf(_handleId);

  /// Close the repository on the worker and release the handle table entry.
  ///
  /// Idempotent: subsequent calls are silently no-ops.
  ///
  /// Swallows `StateError('Worker is closed')` — a closed worker has already
  /// released all handles with the process. A genuine `ffi.invalid_handle`
  /// surfaces as [ZanshinFfiException] (it would signal a bug in the table).
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _finalizer.detach(this);
    try {
      await _worker.closeRepo(_handleId);
    } catch (e) {
      // WHY: During closeRepo, if the worker shuts down concurrently,
      // correlator.failAll propagates StateError('Worker is closed') through
      // the awaited future. Swallowing it is correct — the OS reclaims FFI
      // handles at process exit. All other exceptions are re-thrown.
      if (e is! StateError) {
        rethrow;
      }
    }
  }

  /// Read the working-copy status for this repository.
  ///
  /// Throws [StateError] if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.no_working_copy`, `jj.jj_lib_error`).
  Future<WorkingCopyStatus> status() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.status(_handleId);
  }

  /// Read full change metadata for the change identified by [changeId].
  ///
  /// Throws [StateError] if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.change_not_found`, `jj.jj_lib_error`).
  Future<Change> getChange(String changeId) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.getChange(_handleId, changeId);
  }

  /// Read the whole revset's index-only graph topology (Story 4.12; the verb is
  /// Story 4.10's): every node of [revset] in `jj log` order, its edges, refs,
  /// working copies and flags, the node indices each anchor selects, `|all()|`
  /// and the operation the call loaded — read lazily through the returned
  /// [GraphTopologyView].
  ///
  /// Every parameter is a CLI pass-through (FR-JJ-17):
  ///
  /// - [revset] — the nodes; [defaultLogRevset] is the CLI's default, exported
  ///   for the UI to pre-fill, never applied silently.
  /// - [prioritize] — branch-prioritisation revset, pre-filled
  ///   [defaultGraphPrioritize] (`present(@)`); `'none()'` means none.
  /// - [shortPrefixes] — disambiguation revset for the shortest-prefix lengths,
  ///   pre-filled [defaultShortPrefixes]; `''` DISABLES disambiguation.
  /// - [anchors] — ordered revsets for the layout's priority rule (required;
  ///   [defaultGraphAnchors] is the editable pre-fill).
  /// - [withTimestamps] — load every non-root committer timestamp (required: the
  ///   cost is the layout mode's call).
  ///
  /// The card content of a node is [commitContents] at the view's
  /// `operationId`. The topology is re-derived from head on every call
  /// (ADR-0002) — re-request on an `OpHeadsChangedEvent`.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ArgumentError] on an interior NUL in any expression. Throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.jj_lib_error`;
  /// full list: `docs/ffi-abi.md` § `zanshin_graph_topology`).
  Future<GraphTopologyView> graphTopology({
    required String revset,
    required List<String> anchors,
    required bool withTimestamps,
    String prioritize = defaultGraphPrioritize,
    String shortPrefixes = defaultShortPrefixes,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.graphTopology(
      _handleId,
      revset: revset,
      prioritize: prioritize,
      shortPrefixes: shortPrefixes,
      anchors: anchors,
      withTimestamps: withTimestamps,
    );
  }

  /// Lay out the whole revset's graph (Story 4.11): the [graphTopology] of [revset] — with the
  /// committer timestamps iff [mode] is `free` — laid out on the worker isolate by the Dart
  /// layout engine (docs/graph-layout.md), returned as the topology and the grid.
  ///
  /// Every parameter is a CLI or layout pass-through (FR-JJ-17); the defaults are editable
  /// pre-fills:
  ///
  /// - [revset] — the nodes; prefer [logDefaults]' `log` over [defaultLogRevset].
  /// - [anchors] — ordered revsets for the priority rule (§11.2); [defaultGraphAnchors] is the
  ///   pre-fill.
  /// - [utcOffsetMin] — the viewer's fixed UTC offset for `free`'s day buckets; `compact`'s layout
  ///   does not read it, but it must lie within ±1440 in every mode.
  /// - [prioritize], [shortPrefixes] — as in [graphTopology], pre-filled [defaultGraphPrioritize]
  ///   and [defaultShortPrefixes]; prefer [logDefaults]' effective values.
  /// - [mode], [order] — pre-filled [defaultLayoutMode] (`free`) and [defaultLaneOrder]
  ///   (`compact`).
  /// - [budget] — the `compact` order's work units, pre-filled [defaultLayoutBudget].
  /// - [stacks] — Story 4.13's commit stacks (docs/graph-layout.md §4.8): linear runs grouped into
  ///   stack nodes, the columns kept, only rows compacted; the grid then has format version 2 and
  ///   carries the runs. The "Group stacks" switch (Story 10.7) decides it; `false` here is 4.11's
  ///   layout byte for byte and ignores the three key lists.
  /// - [expandedKeys], [collapsedKeys] — the runs the user toggled (Story 10.17), by a run's key:
  ///   the bare key of its oldest member, `runMembers[runStarts[k]]` in the grid (no design-style
  ///   `grp:` prefix).
  /// - [keepOpenKeys] — node keys whose run stays expanded whatever else holds: the selected card
  ///   and a pending go-to-change target (Story 10.5). They name nodes; a collapsed stack's own
  ///   card is no node, so selecting it keeps nothing open.
  ///
  ///   Keys follow Story 10.1's key rule — a change id, or the commit id of a hidden or divergent
  ///   commit — and resolve in the worker; a key that names no current run (for [keepOpenKeys]: no
  ///   member) is ignored. Without an explicit key a run is collapsed, except a run of mutable
  ///   ancestors of this workspace's `@`.
  ///
  /// The topology is re-derived from head on every call and nothing is kept between calls
  /// (ADR-0002) — re-request on an `OpHeadsChangedEvent`. The topology's `warnings` and
  /// [lastPrecondition] carry the call's report; card content is [commitContents] at the
  /// topology's `operationId`.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]. Throws [ArgumentError]
  /// on an interior NUL in any expression, an offset beyond ±1440 or a negative budget. Throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`, `jj.revset_parse_error`,
  /// `jj.revset_resolution_error`, `jj.jj_lib_error`; full list: `docs/ffi-abi.md`
  /// § `zanshin_graph_topology`) and [LayoutContractException] when the topology breaks a
  /// contract rule of the layout's input.
  Future<({GraphTopologyView topology, GraphGridView grid})> graphLayout({
    required String revset,
    required List<String> anchors,
    required int utcOffsetMin,
    String prioritize = defaultGraphPrioritize,
    String shortPrefixes = defaultShortPrefixes,
    LayoutMode mode = defaultLayoutMode,
    LaneOrder order = defaultLaneOrder,
    int budget = defaultLayoutBudget,
    bool stacks = false,
    List<String> expandedKeys = const [],
    List<String> collapsedKeys = const [],
    List<String> keepOpenKeys = const [],
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.graphLayout(
      _handleId,
      revset: revset,
      prioritize: prioritize,
      shortPrefixes: shortPrefixes,
      anchors: anchors,
      mode: mode,
      order: order,
      utcOffsetMin: utcOffsetMin,
      budget: budget,
      stacks: stacks,
      expandedKeys: expandedKeys,
      collapsedKeys: collapsedKeys,
      keepOpenKeys: keepOpenKeys,
    );
  }

  /// Read the operation log for this repository.
  ///
  /// `limit < 0` (default `-1`) returns all operations; `limit >= 0` returns
  /// at most [limit] most-recent operations.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.jj_lib_error`).
  Future<WarnedList<Operation>> opLog({int limit = -1}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.opLog(_handleId, limit);
  }

  /// Read the bookmarks of this repository — the `jj bookmark list --all-remotes`
  /// row set with its tracking facts (Story 9.29).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.jj_lib_error`).
  Future<WarnedList<Bookmark>> bookmarks() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.bookmarks(_handleId);
  }

  /// Read the configured git remotes for this repository.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.jj_lib_error`).
  Future<WarnedList<Remote>> remotes() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.remotes(_handleId);
  }

  /// Read the remotes `jj git push` without `--remote` would push to (Story
  /// 9.54) — the CLI's default-remote resolution: the remotes `git.push` names
  /// (a name, a list or a pattern), else the single remote, else `origin`,
  /// each only when it exists, in remote-name order. Empty when none matches
  /// and on a non-Git backend; an exact name no remote carries (a `git.push`
  /// name, or the implicit `origin`) warns `jj.push_remotes_unmatched`, as the
  /// push does.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.config_error`, `jj.invalid_input`, `jj.stale_working_copy`,
  /// `jj.jj_lib_error`).
  Future<WarnedList<String>> gitPushRemotes() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitPushRemotes(_handleId);
  }

  /// Read the effective `jj log` defaults for this repository (Story 4.9) —
  /// what the user's own `jj` CLI would apply after their config overrides.
  ///
  /// Use these to pre-fill [graphTopology]'s `revset` / `prioritize` /
  /// `shortPrefixes` instead of the builtin constants [defaultLogRevset] /
  /// [defaultGraphPrioritize] / [defaultShortPrefixes]; they are offers, still
  /// editable by the user (FR-JJ-17). The config is re-read Rust-side on every
  /// call and never cached, so an externally edited config file shows up on the
  /// next call without reopening the handle.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.config_error`).
  Future<LogDefaults> logDefaults() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.logDefaults(_handleId);
  }

  /// Read the object half of each commit in [commitIds] — author, committer
  /// timestamp, FULL description, conflict, empty — at the pinned operation
  /// [operationId], in [commitIds]' order (Story 4.10).
  ///
  /// The continuation of [graphTopology]'s `jj log`: pass the `operationId` its
  /// view carries and the ids of the cards to show. It runs no pre-verb
  /// snapshot, so [lastPrecondition] is left unchanged, and records no warning
  /// (the result's `warnings` is always empty). The values are commit-intrinsic,
  /// so a head that moved since the topology call changes nothing. Ids are FULL
  /// hex only.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ArgumentError] if an id contains an interior NUL (U+0000). Throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.operation_not_found`, `jj.change_not_found`,
  /// `jj.jj_lib_error`).
  Future<WarnedList<CommitContent>> commitContents({
    required String operationId,
    required List<String> commitIds,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.commitContents(_handleId, operationId: operationId, commitIds: commitIds);
  }

  /// Rewrite the description of [changeId] to [description] (Story 6.5).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.change_not_found`, `jj.invalid_input`, `jj.immutable`,
  /// `jj.config_error`).
  Future<MutationResult> describe({required String changeId, required String description}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.describe(_handleId, changeId: changeId, description: description);
  }

  /// Create a new, empty change and switch the working copy to it — the CLI's
  /// `jj new <parents>` (Story 6.5), `jj new -A <insertAfter>` and
  /// `jj new -B <insertBefore>` (Story 9.48).
  ///
  /// An empty list is the flag not given; [parents] cannot be combined with
  /// either insert list, and at least one list must be non-empty (`@` is passed
  /// explicitly). Each list resolves in order with duplicates dropped, so
  /// `[c, c]` is one parent.
  ///
  /// - [parents]: the new change sits on them — a merge commit for two or more.
  ///   With exactly one, the `experimental-advance-branches` bookmarks advance.
  /// - [insertAfter]: the new change sits on the targets; their children are
  ///   rebased onto it.
  /// - [insertBefore]: the new change sits on the targets' parents; the targets
  ///   are rebased onto it.
  /// - both: the new change sits on [insertAfter]; [insertBefore] is rebased
  ///   onto it, keeping its other parents.
  ///
  /// `MutationResult.newChangeIds` holds the new change, which is also
  /// `workingCopyChangeId`.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ArgumentError] if a [parents] / [insertAfter] / [insertBefore]
  /// entry contains an interior NUL (U+0000); throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.invalid_input` — incl. the CLI's loop refusal,
  /// `jj.change_not_found`, `jj.immutable`, `jj.config_error`,
  /// `jj.stale_working_copy`, `jj.jj_lib_error`).
  Future<MutationResult> newChange(
    List<String> parents, {
    List<String> insertAfter = const [],
    List<String> insertBefore = const [],
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.newChange(_handleId, parents, insertAfter: insertAfter, insertBefore: insertBefore);
  }

  /// Switch the working copy to [changeId] without creating a new commit
  /// (Story 6.5).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.change_not_found`, `jj.immutable`, `jj.config_error`). Unlike [describe]
  /// and [abandon] this has no separate root-commit guard, so editing the root
  /// commit reports `jj.immutable` (which is what the jj CLI reports for it).
  Future<MutationResult> edit(String changeId) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.edit(_handleId, changeId);
  }

  /// Abandon [changeIds], rebasing descendants onto their parents and deleting
  /// any bookmarks that pointed only at the abandoned commits (Story 6.5).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`).
  Future<MutationResult> abandon(List<String> changeIds) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.abandon(_handleId, changeIds);
  }

  /// Undo the last operation — the CLI's `jj undo` @ v0.46.0 with its undo
  /// stack (Story 6.5, Story 9.39): calling this twice in a row goes further
  /// back instead of redoing the first `undo`, and an undo stack the CLI
  /// started is continued. [allowCrossWorkspace] is the CLI's
  /// `--allow-cross-workspace` (default `false`, as in the CLI): without it an
  /// operation performed in another workspace is refused. Undoing a push or a
  /// workspace removal warns (`jj.undo_push_operation`,
  /// `jj.undo_workspace_removal`).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.undo_cross_workspace` — `context` is `"<operation>\n<workspace>"` —,
  /// `jj.nothing_to_undo`).
  Future<MutationResult> undo({bool allowCrossWorkspace = false}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.undo(_handleId, allowCrossWorkspace: allowCrossWorkspace);
  }

  /// Fetch all branches and tags from [remoteName] and import them
  /// (Story 6.5). Never moves `@` — fetch only updates remote-tracking refs.
  ///
  /// Progress rides `ZanshinWorker.events` as a `ProgressEvent` carrying this
  /// handle's [handleId].
  ///
  /// `git.abandon-unreachable-commits` and `git.record-synthetic-predecessors` are
  /// read from the repo's effective config per call, never hardcoded.
  ///
  /// The result's `abandonedChangeIds` carries the commits the import abandoned
  /// because they became unreachable in git — jj-lib's OWN abandonments, not a
  /// caller echo, and empty when `git.abandon-unreachable-commits` is off.
  /// `newChangeIds` is always empty: a fetch mints nothing.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.remote_not_found`, `jj.not_a_git_repo`, `jj.config_error`,
  /// `jj.network_error`, `jj.cancelled`, `jj.jj_lib_error`). A workspace with no git backend is
  /// `jj.not_a_git_repo` — not `jj.remote_not_found`, which now means only
  /// "no remote of that name".
  ///
  /// Returns a [NetworkOperation] (Story 9.52): the fetch runs on a helper
  /// isolate, so its `progress` arrives while `result` is pending, and
  /// `cancel()` stops it (`jj.cancelled`, nothing written). Later calls on
  /// this handle — [close] included — wait for it; other repos do not.
  NetworkOperation<MutationResult> gitFetch(String remoteName) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitFetch(_handleId, remoteName);
  }

  /// Asks [remoteName] what it has now and diffs that against the head view,
  /// without fetching (Story 9.24): the Fetch button's "something new
  /// upstream" poll. `git ls-remote --heads --tags` runs the way jj-lib runs
  /// every git (`git.executable-path`, the user's git auth, the adopted
  /// login-shell environment); each advertised branch and tag is compared with
  /// the view's `<name>@<remote>` target, an annotated tag at the commit it
  /// peels to.
  ///
  /// The result lists the refs that moved, were created or deleted upstream —
  /// bookmarks before tags, each by name; an empty list means a fetch would
  /// bring nothing new. No snapshot (a dirty working copy stays as it is), no
  /// operation, no object download; the call's warnings are the start-up
  /// secure-config fix-up's, and [lastPrecondition] is not touched.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `ffi.null_pointer`, `ffi.invalid_argument` — an interior NUL in
  /// [remoteName] —, `jj.remote_not_found` — no remote of exactly that name,
  /// git never runs —, `jj.not_a_git_repo`, `jj.config_error`,
  /// `jj.network_error`, `jj.cancelled`, `jj.jj_lib_error`).
  ///
  /// Returns a [NetworkOperation] like [gitFetch]: the poll runs on a helper
  /// isolate, later calls on this handle — [close] included — wait for it, and
  /// `cancel()` kills its git (`jj.cancelled`). git sends no progress, so
  /// `progress` stays empty.
  NetworkOperation<WarnedList<RemoteRefChange>> remoteChanges(String remoteName) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.remoteChanges(_handleId, remoteName);
  }

  /// Push bookmarks and tags to git remotes (Story 9.20) — the CLI's
  /// `jj git push` with every parameter passed through.
  ///
  /// [remotes] is `--remote` (`null` = not given: `git.push`, else the only
  /// remote, else `origin`). The specific refs — [bookmarks] / [tags] (`-b` /
  /// `-t` patterns), [revisions] (`-r`), [changes] (`-c`, creates `push-…`
  /// bookmarks) and [named] (`--named NAME=REVISION`) — combine with each
  /// other; [all] and [tracked] exclude each other and the specific refs;
  /// [deleted] excludes the specific refs and combines with [all] / [tracked]
  /// (the CLI's argument groups). None of them is the `revsets.git-push`
  /// default.
  /// [allowEmptyDescription] / [allowPrivate] / [allowConflicts] relax the
  /// commit checks; [options] are `--option` push options.
  ///
  /// [dryRun] answers the plan — the same planning the real push does: every
  /// matched remote's rows with their action, path (push / skip / abort),
  /// refusals and commit rejections — and writes nothing. The real push signs
  /// with `git.sign-on-push`, pushes per remote and records an operation when
  /// every ref succeeded or one was exported. A push that fails once the
  /// network is involved is DATA (`GitPushResult.failure`); a refusal before
  /// the network throws.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`,
  /// `jj.bookmark_exists`, `jj.bookmark_tracked_remote_exists`,
  /// `jj.push_ref_refused`, `jj.push_commit_rejected`, `jj.revset_parse_error`,
  /// `jj.revset_resolution_error`, `jj.config_error`, `jj.not_a_git_repo`,
  /// `jj.stale_working_copy`, `jj.jj_lib_error`).
  ///
  /// Returns a [NetworkOperation] (Story 9.52): the push runs on a helper
  /// isolate, and `cancel()` stops it before the next remote — reported as
  /// data, `failure.kind == PushFailureKind.cancelled`, nothing recorded, the
  /// per-remote rows saying which remotes already got their refs. Later calls
  /// on this handle wait for it.
  NetworkOperation<GitPushResult> gitPush({
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
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitPush(
      _handleId,
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
    );
  }

  /// Give the paths in [paths] the content they have in another commit
  /// (Story 9.3) — the CLI's `jj restore`, whole-file only.
  ///
  /// A `null` [from]/[into]/[changesIn] applies the CLI's own defaults: if
  /// exactly one of [from]/[into] is given the other is `@`; if neither is, the
  /// destination ([changesIn], else `@`) is restored from its PARENT tree, which
  /// undoes its own diff while keeping its description. [changesIn] cannot be
  /// combined with [from]/[into].
  ///
  /// [paths] entries are repo-relative paths interpreted as PREFIXES (an empty
  /// list means all paths); an empty-STRING entry is the repository root, which
  /// prefixes everything, so `paths: ['']` matches all paths just as `paths: []`
  /// does. [restoreDescendants] reparents children (preserving their content)
  /// instead of rebasing them.
  ///
  /// A path that matches nothing is silently a no-op, where the CLI would warn —
  /// `MutationResult` has no warning channel.
  ///
  /// If the resulting tree already equals the destination's, NO operation is
  /// written and `newOpId` is the pre-call op-log head. The working copy is
  /// snapshotted first, as by the CLI, so on-disk edits are part of `@`.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`).
  Future<MutationResult> restore({
    String? from,
    String? into,
    String? changesIn,
    List<String> paths = const <String>[],
    bool restoreDescendants = false,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.restore(
      _handleId,
      from: from,
      into: into,
      changesIn: changesIn,
      paths: paths,
      restoreDescendants: restoreDescendants,
    );
  }

  /// Move each hunk of [from] into the closest commit in [into] where the
  /// corresponding lines were last modified (Story 9.3) — the CLI's
  /// `jj absorb`, non-interactive only.
  ///
  /// A `null` [from] means `@`. A `null` [into] applies the CLI's own default,
  /// the `mutable()` ALIAS resolved through the repo's effective config — and
  /// unlike every other mutation argument [into] is a revset EXPRESSION, not a
  /// change id. [paths] behaves as in [restore].
  ///
  /// Paths jj-lib refuses to split are reported in `AbsorbResult.skippedPaths`
  /// rather than failing the call. If nothing was absorbable, no operation is
  /// written and `rewrittenChangeIds` is empty. On an ERROR the skipped-path list
  /// is lost (an exception carries no payload), where a CLI user would still have
  /// seen the per-path warnings.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed].
  /// Throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`,
  /// `jj.change_not_found`, `jj.immutable`, `jj.config_error`).
  Future<AbsorbResult> absorb({String? from, String? into, List<String> paths = const <String>[]}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.absorb(_handleId, from: from, into: into, paths: paths);
  }

  /// Move changes from one or more revisions into another (Story 9.15) — the
  /// CLI's `jj squash`, paths only.
  ///
  /// Neither [from] nor [into]: [revision] (`null` = `@`) into its ONE parent;
  /// a merge or the root commit refuses. Otherwise the [from] change ids
  /// (empty = `@`) into [into] (`null` = `@`); the destination is silently
  /// dropped from the sources, so squashing `@` into `@` writes nothing (the
  /// result's `newOpId` is the pre-call head). [paths] are repo-relative
  /// PREFIXES (empty = everything). A source whose changes all moved is
  /// abandoned unless [keepEmptied] (`-k`); the abandoned sources are the
  /// result's `abandonedChangeIds`, an abandoned `@`'s replacement its
  /// `newChangeIds`.
  ///
  /// The description: [message] (the CLI's `-m`), else the destination's
  /// ([useDestinationMessage], `-u`), else the one non-empty description of
  /// the abandoned sources and the destination. When two or more are non-empty
  /// the CLI asks in its editor — ask the user first with [squashPlan] and pass
  /// the edited text as [editedDescription] (Story 9.54), NOT as [message],
  /// which would add `templates.commit_trailers` again; without either, the
  /// combined text the plan returns is written. [editedDescription] is the
  /// CLI's `--editor` saving exactly that text: written cleaned up, with no
  /// trailers added; with [message] it is refused (`jj.invalid_input`).
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ArgumentError] if an argument contains an interior NUL (U+0000);
  /// throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error`).
  Future<MutationResult> squash({
    String? revision,
    List<String> from = const [],
    String? into,
    List<String> paths = const [],
    List<String>? message,
    bool useDestinationMessage = false,
    bool keepEmptied = false,
    String? editedDescription,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.squash(
      _handleId,
      revision: revision,
      from: from,
      into: into,
      paths: paths,
      message: message,
      useDestinationMessage: useDestinationMessage,
      keepEmptied: keepEmptied,
      editedDescription: editedDescription,
    );
  }

  /// The description [squash] with the same arguments would have to ask for
  /// (Story 9.15): `SquashPlan.combinedDescription` is the text the CLI's
  /// editor holds — what [squash] writes without [message] — and `null` when
  /// there is nothing to ask. Refuses and warns exactly as [squash]; writes no
  /// operation of its own.
  ///
  /// Throws as [squash].
  Future<SquashPlan> squashPlan({
    String? revision,
    List<String> from = const [],
    String? into,
    List<String> paths = const [],
    List<String>? message,
    bool useDestinationMessage = false,
    bool keepEmptied = false,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.squashPlan(
      _handleId,
      revision: revision,
      from: from,
      into: into,
      paths: paths,
      message: message,
      useDestinationMessage: useDestinationMessage,
      keepEmptied: keepEmptied,
    );
  }

  /// Split a revision in two (Story 9.15) — the CLI's `jj split`, paths only.
  ///
  /// [revision] (`null` = `@`) is split into the changes to [paths] —
  /// repo-relative PREFIXES, at least one (no paths is the CLI's interactive
  /// diff editor, refused as `jj.invalid_input`) — and the rest. Plain: the
  /// selected commit keeps the change id, the remaining one becomes its child;
  /// [parallel]: both on the target's parents; [onto] / [insertAfter] /
  /// [insertBefore] (`-o` / `-A` / `-B`, `null` = not given): the selected
  /// changes become a NEW change there and the remaining commit keeps the
  /// change id. `@` ends on the remaining commit.
  ///
  /// [message] (`-m`) describes the selected commit; without it both keep the
  /// original description. [editedSelectedDescription] and
  /// [editedRemainingDescription] (Story 9.54, both or neither) are the user's
  /// edits of the two editor texts — written cleaned up, with no trailers
  /// added; one alone, or either with [message], is refused
  /// (`jj.invalid_input`). Selecting everything warns `jj.split_all_selected`,
  /// nothing `jj.split_none_selected`; the split runs either way.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ArgumentError] if an argument contains an interior NUL (U+0000);
  /// throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`,
  /// `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error`).
  Future<SplitResult> split({
    required List<String> paths,
    String? revision,
    List<String>? message,
    bool parallel = false,
    List<String>? onto,
    List<String>? insertAfter,
    List<String>? insertBefore,
    String? editedSelectedDescription,
    String? editedRemainingDescription,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.split(
      _handleId,
      revision: revision,
      paths: paths,
      message: message,
      parallel: parallel,
      onto: onto,
      insertAfter: insertAfter,
      insertBefore: insertBefore,
      editedSelectedDescription: editedSelectedDescription,
      editedRemainingDescription: editedRemainingDescription,
    );
  }

  /// Commit the working-copy commit (Story 9.49) — the CLI's
  /// `jj commit -m <message> [paths]`.
  ///
  /// The selection starts from `@`'s PARENT tree: the changes `@` makes to
  /// [paths] — repo-relative PREFIXES; empty is every change (the CLI's
  /// "describe + new"). `@` is rewritten in place (same change id) with the
  /// selected changes and [message] (the repeatable `-m`; an empty list is
  /// `-m ""`), so its bookmarks follow it and its descendants are rebased onto
  /// it; a NEW `@` on top of it holds the old `@`'s full tree, for every
  /// workspace whose `@` was the old `@`. Bookmarks on `@`'s parents that
  /// `experimental-advance-branches` selects move to the committed `@`. The new
  /// `@` is `MutationResult.newChangeIds`' one entry.
  ///
  /// [paths] that select no change of `@` warn `jj.commit_paths_unmatched`; the
  /// commit runs anyway.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ArgumentError] if an argument contains an interior NUL (U+0000);
  /// throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.no_working_copy`, `jj.invalid_input`, `jj.config_error`,
  /// `jj.stale_working_copy`, `jj.jj_lib_error`).
  Future<MutationResult> commit({required List<String> message, List<String> paths = const []}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.commit(_handleId, message: message, paths: paths);
  }

  /// List the entries of a revision's tree (Story 9.4) — the CLI's
  /// `jj file list`.
  ///
  /// A `null` [revision] applies the CLI's own `-r` default `@` — snapshotted
  /// first, so on-disk edits are part of it, exactly as in the CLI. It is
  /// a jj reverse-hex CHANGE ID, not a revset; a divergent id is refused rather
  /// than guessed, exactly as the CLI's `-r` refuses an ambiguous revision.
  ///
  /// [paths] entries are repo-relative paths interpreted as PREFIXES (an empty
  /// list means all paths); an empty-STRING entry is the repository root, which
  /// prefixes everything, so `paths: ['']` matches all paths just as `paths: []`
  /// does. The fileset DSL is not parsed.
  ///
  /// Entries come in jj's own tree order. A path matching nothing simply
  /// contributes no entry, where the CLI prints a warning. Subtrees are visited
  /// recursively and never listed — except a subtree that CONFLICTS with a
  /// non-tree, which arrives as one `FileType.conflict` entry.
  ///
  /// This read writes no operation of its own. Throws [StateError] synchronously if the
  /// handle is already [_closed]; throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.change_not_found`, `jj.invalid_input`,
  /// `jj.jj_lib_error`).
  Future<WarnedList<FileEntry>> fileList({String? revision, List<String> paths = const <String>[]}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.fileList(_handleId, revision: revision, paths: paths);
  }

  /// Read the contents of the files selected by [paths] (Story 9.4) — the CLI's
  /// `jj file show`.
  ///
  /// [revision] and [paths] behave as in [fileList], with one difference the CLI
  /// also makes: [paths] may NOT be empty (its FILESETS argument is `required`).
  /// A directory is read recursively.
  ///
  /// With exactly ONE path an absent path is refused (`jj.path_not_found`); with
  /// several, an absent path simply contributes nothing — that asymmetry is the
  /// CLI's, reproduced deliberately. A conflicted file's content is the
  /// MATERIALIZED merge, with markers in the style the repo's effective
  /// `ui.conflict-marker-style` selects. Paths that exist but are not renderable
  /// as file content (a symlink, a submodule, a blob whose access is denied) land
  /// in `FileContents.skipped` instead of failing the call.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.path_not_found`, `jj.change_not_found`,
  /// `jj.config_error` — this is the only file read that consults the repo's
  /// effective jj config — `jj.jj_lib_error`).
  Future<FileContents> fileShow({required List<String> paths, String? revision}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.fileShow(_handleId, revision: revision, paths: paths);
  }

  /// Annotate [path] line by line (Story 9.4) — the CLI's `jj file annotate`.
  ///
  /// [path] is a single PLAIN repo-relative path, not a prefix and not a fileset.
  /// The search domain is `all()`, hardcoded exactly as the CLI hardcodes it.
  ///
  /// One entry per line of the file, in file order, so a line's own 1-based
  /// number is its index in the returned list + 1 — which is why
  /// `AnnotationLine` carries only `originalLineNumber`, the line's number in the
  /// ORIGINATING commit. Where the CLI collapses "the search stopped outside the
  /// domain" to the root commit, `AnnotationLine.originFound` keeps it.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.path_not_found`, `jj.not_a_file`,
  /// `jj.change_not_found`, `jj.jj_lib_error`).
  Future<WarnedList<AnnotationLine>> fileAnnotate({required String path, String? revision}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.fileAnnotate(_handleId, path: path, revision: revision);
  }

  /// Search the files of a revision for [pattern] (Story 9.4) — the CLI's
  /// `jj file search`.
  ///
  /// [pattern] is jj's own `kind:pattern` string-pattern syntax passed through
  /// verbatim; a bare pattern defaults to kind `regex`, and the FIRST `:`
  /// separates. [revision] and [paths] behave as in [fileList].
  ///
  /// [nameOnly] stops a file's scan at its first match — it changes the WORK done,
  /// not the result shape, so each matching file still contributes its first
  /// matching line (a superset of what the CLI prints). The CLI's `--line-number`
  /// has no counterpart: `SearchMatch.lineNumber` is always carried.
  ///
  /// A conflicted path is searched side by side, with `conflictSide` set and line
  /// numbers restarting at each side. Symlinks, submodules and non-file conflicts
  /// are SILENTLY not searched, as the CLI skips them; a path whose blob could not
  /// be READ lands in `FileSearch.skipped` — the only case `jj file search` warns
  /// about — and does not fail the call.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed];
  /// throws [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.jj_lib_error`).
  Future<FileSearch> fileSearch({
    required String pattern,
    String? revision,
    List<String> paths = const <String>[],
    bool nameOnly = false,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.fileSearch(_handleId, pattern: pattern, revision: revision, paths: paths, nameOnly: nameOnly);
  }

  /// Import the backing git repo's refs into jj's view (Story 9.5) — the CLI's
  /// `jj git import`.
  ///
  /// Takes no arguments; the CLI's own `jj git import` has none either. In a
  /// colocated workspace the pre-verb snapshot has already imported the refs (its
  /// outcome is [lastPrecondition]`.gitRefs`); the verb then returns the no-op
  /// result before opening any transaction and writes no operation of its own —
  /// the CLI's early return ("No import needed in colocated workspaces.").
  ///
  /// `git.abandon-unreachable-commits`, `git.record-synthetic-predecessors` and
  /// `remotes.<name>.auto-track-bookmarks` are read from the repo's effective jj
  /// config per call.
  ///
  /// If nothing needed importing, no operation is written and `mutation.newOpId` is
  /// the pre-call op-log head. A ref that could not be imported lands in
  /// `failedRefNames` and does NOT fail the call — the CLI warns and exits 0.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.not_a_git_repo`, `jj.config_error`, `jj.jj_lib_error`).
  Future<GitImportResult> gitImport() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitImport(_handleId);
  }

  /// Write jj's bookmarks and tags back to the backing git repo (Story 9.5) — the
  /// CLI's `jj git export`.
  ///
  /// In a colocated workspace every finished transaction has already exported,
  /// so — as with [gitImport] — the verb returns the no-op result before opening
  /// any transaction, after the pre-verb snapshot: the CLI's early return ("No
  /// export needed in colocated workspaces."). Export never moves `@` and
  /// rewrites no commit.
  ///
  /// If git already matched, no operation is written and `mutation.newOpId` is the
  /// pre-call op-log head. Refs that could not be written land in `failedBookmarks`
  /// / `failedTags` and do NOT fail the call; the classic case is two bookmarks
  /// named `foo` and `foo/bar`, which git cannot both hold.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.not_a_git_repo`, `jj.jj_lib_error`).
  Future<GitExportResult> gitExport() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitExport(_handleId);
  }

  /// Register a new git remote (Story 9.5) — the CLI's `jj git remote add`.
  ///
  /// [url] and [pushUrl] are passed through verbatim; unlike the CLI, a relative
  /// local path is not resolved against a process CWD. A `null` [pushUrl] means the
  /// remote pushes to [url], which is git's own behaviour.
  ///
  /// [remotes] on this SAME handle reflects the new remote immediately.
  ///
  /// One caveat worth surfacing in a UI: a remote added WITH a push URL cannot
  /// later be removed — jj writes a `pushurl` key, which its own remove refuses as
  /// `jj.remote_nonstandard_config`.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.remote_exists`, `jj.invalid_input`, `jj.not_a_git_repo`,
  /// `jj.jj_lib_error`).
  Future<MutationResult> gitRemoteAdd({required String name, required String url, String? pushUrl}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitRemoteAdd(_handleId, name: name, url: url, pushUrl: pushUrl);
  }

  /// Remove a git remote and forget its bookmarks (Story 9.5) — the CLI's
  /// `jj git remote remove`.
  ///
  /// [remotes] on this SAME handle reflects the removal immediately. Removing the
  /// reserved remote `git` SUCCEEDS but writes no operation — it changes the git
  /// config and refs, not jj's view.
  ///
  /// The repo-level jj config file is rewritten as well, exactly as the CLI does:
  /// the `[remotes.<name>]` section is dropped, and a `revset-aliases.'trunk()'`
  /// that is a plain remote symbol naming this remote is deleted — so the REPO
  /// layer stops defining `trunk()` and the rest of the stack decides, which is
  /// the builtin unless the workspace or user layer defines its own `trunk()`. It
  /// is the file this repo's config layer reads
  /// (`<config_dir>/jj/repos/<config-id>/config.toml`, or the legacy
  /// `.jj/repo/config.toml`); with no such file nothing is written and none is
  /// created.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.config_error`, `jj.remote_not_found`, `jj.remote_nonstandard_config`,
  /// `jj.not_a_git_repo`, `jj.jj_lib_error`).
  Future<MutationResult> gitRemoteRemove(String name) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitRemoteRemove(_handleId, name);
  }

  /// Rename a git remote (Story 9.5) — the CLI's `jj git remote rename`.
  ///
  /// [remotes] on this SAME handle reflects the rename immediately. Renaming FROM
  /// the reserved remote `git` writes no operation, for the same reason removing it
  /// does not.
  ///
  /// The repo-level jj config file is rewritten as well — see [gitRemoteRemove] for
  /// which file that is and when nothing is written. Here `[remotes.<oldName>]`
  /// becomes `[remotes.<newName>]` with its value untouched, and a
  /// plain-remote-symbol `trunk()` naming [oldName] is re-pointed at [newName],
  /// keeping its bookmark.
  ///
  /// jj validates [newName] BEFORE it reports that [oldName] is missing, so
  /// renaming a nonexistent remote to `git` reports the reserved-name refusal. That
  /// ordering is jj's own and is reproduced, not corrected.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.config_error`, `jj.invalid_input`, `jj.remote_not_found`,
  /// `jj.remote_exists`, `jj.remote_nonstandard_config`, `jj.not_a_git_repo`,
  /// `jj.jj_lib_error`).
  Future<MutationResult> gitRemoteRename(String oldName, String newName) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitRemoteRename(_handleId, oldName, newName);
  }

  /// Re-point a git remote's fetch and/or push URL (Story 9.5) — the CLI's
  /// `jj git remote set-url`.
  ///
  /// NEVER writes an operation: jj takes no transaction for this verb, and neither
  /// does the CLI — so the returned `newOpId` is always the pre-call op-log head.
  /// [remotes] on this SAME handle still reports the new URL.
  ///
  /// A `null` [url]/[pushUrl] leaves that side unchanged (a URL cannot be REMOVED
  /// from a remote). With BOTH null the call succeeds and does nothing, even for a
  /// remote that does not exist — jj returns early before its own existence check,
  /// and inventing a refusal there would be a divergence.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.remote_not_found`, `jj.invalid_input`, `jj.not_a_git_repo`,
  /// `jj.jj_lib_error`).
  Future<MutationResult> gitRemoteSetUrl({required String name, String? url, String? pushUrl}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.gitRemoteSetUrl(_handleId, name: name, url: url, pushUrl: pushUrl);
  }

  /// Show each revision [revset] denotes with what it changed (Story 9.6) — the
  /// CLI's `jj show`.
  ///
  /// A `null` [revset] applies the CLI's own default `@`, snapshotted first as in
  /// the CLI. Unlike
  /// [interdiff]'s two single revisions, [revset] is a pass-through EXPRESSION:
  /// the CLI unions its revsets, so entries are per COMMIT — a revset naming
  /// two commits of ONE divergent change yields two entries with the same
  /// `Change.id`, both flagged `divergent`. A BARE divergent change-id symbol does
  /// NOT get that far: jj-lib's own `SymbolResolver` refuses it
  /// (`RevsetResolutionError::DivergentChangeId`), exactly as
  /// `jj show <divergent-id>` fails in the CLI, so it throws
  /// `jj.revset_resolution_error` — a DIFFERENT refusal from [interdiff]'s
  /// `jj.change_not_found`. Address both commits by unioning their COMMIT hexes,
  /// which are ordinary revset symbols. Aliases come from the repo's effective jj
  /// config, re-read per call.
  ///
  /// Entries come in raw revset order (topological, children before parents). Each
  /// entry's `fileChanges` is the diff against the commit's MERGED parent tree —
  /// for a merge, only what the merge itself changed; for the root commit, empty.
  /// There is no path filter and no textual patch: the CLI has no path argument
  /// here, and line/word-level diffing is Epic 5's.
  ///
  /// [limit] is a ZANSHIN-SIDE cap the CLI has no counterpart for — `jj show` has
  /// no `-n/--limit`, because it streams to a pager where this materialises one
  /// list whose every entry pays a merged-parent tree diff. It is applied in RAW
  /// REVSET order, the same order the unbounded call returns; `limit: 0` is an
  /// empty list, not an error, and `null` is the CLI-parity default (unbounded).
  /// A [limit] above the wire field's `uint` ceiling (4294967295) SATURATES
  /// there, so an over-large limit means "everything" rather than wrapping to an
  /// empty list; a NEGATIVE [limit] throws [ArgumentError].
  ///
  /// This read writes no operation of its own. Throws [StateError] synchronously if the
  /// handle is already [_closed]; throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.revset_parse_error`, `jj.revset_resolution_error`,
  /// `jj.config_error`, `jj.jj_lib_error`).
  Future<WarnedList<ShowEntry>> show({String? revset, int? limit}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.show(_handleId, revset: revset, limit: limit);
  }

  /// Walk the evolution of the changes [revset] denotes (Story 9.6) — the CLI's
  /// `jj evolog`.
  ///
  /// [revset] behaves as in [show]. [limit] is the CLI's `-n/--limit`, applied in
  /// WALK order (the CLI limits before reversing); `limit: 0` is an empty list,
  /// not an error. A [limit] above the wire field's `uint` ceiling (4294967295)
  /// SATURATES there, so an over-large limit means "everything" rather than
  /// wrapping to an empty list; a NEGATIVE [limit] throws [ArgumentError]. The
  /// CLI's `--reversed` and its graph mode's re-ordering are rendering the UI does
  /// itself and are not applied.
  ///
  /// Rows carry COMMIT ids, not change ids: every predecessor shares the change's
  /// id, and predecessors are hidden by construction. A `null`
  /// `EvologEntry.operationId` marks an entry the walk emitted from its flush tail
  /// — the only signal that an evolution may be TRUNCATED, which the CLI leaves
  /// silent.
  ///
  /// The CLI's `-p/--patch` has no counterpart: it *is* an interdiff of each
  /// entry's predecessors — so a caller composes the two verbs, feeding an
  /// `EvologEntry.predecessorCommitIds` entry to [interdiff] as a [CommitIdRef],
  /// the arm that reaches hidden commits.
  ///
  /// `EvologEntry.change` carries two fields derived against the CURRENT view
  /// rather than this version's moment: `divergent` (whether the change has
  /// several visible commits right now — the same answer on every row) and
  /// `isAnonymous` (today's local bookmarks).
  ///
  /// This read writes no operation of its own. Throws [StateError] synchronously if the
  /// handle is already [_closed]; throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.revset_parse_error`, `jj.revset_resolution_error`,
  /// `jj.config_error`, `jj.jj_lib_error`).
  Future<WarnedList<EvologEntry>> evolog({String? revset, int? limit}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.evolog(_handleId, revset: revset, limit: limit);
  }

  /// Compare what two revisions each CHANGE, with the parent difference factored
  /// out (Story 9.6) — the CLI's `jj interdiff`.
  ///
  /// Unlike [show], each side is a SINGLE revision, written as a [ChangeIdRef]
  /// (the house reverse-hex change-id prefix) or a [CommitIdRef] (a commit-id hex
  /// prefix). Each inherits the CLI `resolve_single_rev`'s REFUSAL — an ambiguous
  /// revision is rejected rather than guessed. A [ChangeIdRef] resolves only to the
  /// currently VISIBLE commit carrying it; a [CommitIdRef] resolves through jj's
  /// index, which ignores visibility, so the
  /// `EvologEntry.predecessorCommitIds` [evolog] reports — hidden by construction
  /// — ARE addressable and the two verbs compose into a version-to-version diff.
  /// A revset expression (`main`, `@-`) is still unaddressable on either arm,
  /// where the CLI accepts one. An absent side is `@` —
  /// but omitting BOTH is refused with `jj.invalid_input`, mirroring the CLI's
  /// required argument group: interdiffing `@` against itself is trivially empty
  /// and never what a caller meant.
  ///
  /// [paths] entries are repo-relative paths interpreted as PREFIXES (an empty
  /// list means all paths); an empty-STRING entry is the repository root, which
  /// prefixes everything. A filter matching nothing yields an empty list, where
  /// the CLI prints a warning.
  ///
  /// No `renamed`/`copied` entry is ever produced: `interdiff` passes no copy
  /// records, and that asymmetry with [show] is the CLI's own, reproduced
  /// deliberately.
  ///
  /// `InterdiffView.baseHasConflicts` reports whether the REBASED `from` tree —
  /// the LEFT side of the diff, which exists only in memory — is conflicted. That
  /// is a ZANSHIN-SIDE addition: the CLI signals it by rendering conflict markers
  /// in the patch TEXT, which is Epic 5's surface here. It never turns the call
  /// into a refusal, and it describes the TREE, not the filtered result.
  ///
  /// This read writes no operation of its own — the rebase behind it is in-memory only.
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.change_not_found`, `jj.revset_resolution_error` —
  /// an ambiguous [CommitIdRef] prefix — `jj.jj_lib_error`).
  Future<InterdiffView> interdiff({RevisionRef? from, RevisionRef? to, List<String> paths = const <String>[]}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.interdiff(_handleId, from: from, to: to, paths: paths);
  }

  /// List every workspace with its working-copy commit and root directory
  /// (Story 9.7) — the CLI's `jj workspace list`.
  ///
  /// Takes no argument: the CLI verb takes none either (its `-T/--template` flag
  /// is rendering). Rows come in jj-lib's own lexicographic-by-name order, which
  /// is preserved rather than re-sorted, and each carries the same
  /// name/working-copy-commit pair the repo's `View` holds plus an ABSOLUTE root
  /// path.
  ///
  /// A row's `root` is the RECORDED path, reported even when the directory moved
  /// or was deleted (jj 0.46). It is `null` when no path can be reported: the
  /// workspace predates jj 0.38.0 and has no recorded path, or the store is
  /// unreadable. Neither fails the listing — the CLI's own list template degrades
  /// the same way, where [workspaceRoot] refuses. That asymmetry between the two
  /// verbs is reproduced, not smoothed over.
  ///
  /// This read writes no operation of its own. Throws [StateError] synchronously if the
  /// handle is already [_closed]; throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.jj_lib_error`).
  Future<WarnedList<WorkspaceEntry>> workspaces() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.workspaces(_handleId);
  }

  /// Return one workspace's absolute root directory (Story 9.7) — the CLI's
  /// `jj workspace root [--name]`.
  ///
  /// A `null` [name] is the CLI's own documented default, the CURRENT workspace;
  /// that path reads the workspace loader alone — no repo load, no store read —
  /// and cannot fail. A PRESENT [name], even the current workspace's own, goes
  /// through the workspace store and can REFUSE or WARN, because the CLI's named
  /// path never shortcuts to the loader. An explicitly empty [name] is a VALUE,
  /// not an absence: no workspace is named `''`, so it refuses with
  /// `jj.workspace_not_found`.
  ///
  /// The returned path is absolute. A named workspace's path is the RECORDED one,
  /// not canonicalized (jj 0.46); when that directory does not exist it comes
  /// back anyway, with a `jj.workspace_path_inaccessible` warning. CWD-relative
  /// shortening is the UI's job.
  ///
  /// This read writes no operation — not even on a refusal. Throws [StateError]
  /// synchronously if the handle is already [_closed]; throws [ArgumentError] if
  /// [name] contains an interior NUL (U+0000), which a length-prefixed
  /// FlatBuffers string would carry all the way into a workspace name; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.workspace_not_found`, `jj.workspace_no_recorded_path`,
  /// `jj.jj_lib_error`).
  Future<WorkspaceRootResult> workspaceRoot({String? name}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.workspaceRoot(_handleId, name: name);
  }

  /// Add a workspace of this repo (Story 9.23) — the CLI's `jj workspace add`,
  /// every argument passed through.
  ///
  /// [destination] is resolved against this workspace's root (an absolute path
  /// stays absolute); a missing directory is created, an existing one must be
  /// empty. A `null` [name] names the workspace after the destination's final
  /// component. [revisions] are the CLI's `-r` revsets, evaluated in THIS
  /// workspace (`@` is this `@`); their union becomes the new `@`'s parents —
  /// empty: this `@`'s parents. [messageParagraphs] are the CLI's `-m`.
  /// [colocate] `true`/`false` are `--colocate`/`--no-colocate`; `null` creates a
  /// Git worktree exactly when this workspace is colocated and `git.colocate` is
  /// set. [sparse] is `--sparse-patterns`.
  ///
  /// Runs this workspace's pre-verb snapshot first, then writes the operations
  /// `add workspace 'NAME'` and `create initial working-copy commit in workspace
  /// NAME`, and
  /// checks the new `@` out into the destination. Open the new workspace with
  /// `ZanshinWorker.openRepo(result.workspaceRoot)`.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ArgumentError] if an argument contains an interior NUL (U+0000); throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`, `jj.invalid_input`,
  /// `jj.workspace_exists`, `jj.destination_not_empty`, `jj.git_worktree_failed`,
  /// `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error`,
  /// `jj.stale_working_copy`, `jj.no_working_copy`, `jj.concurrent_working_copy`,
  /// `jj.jj_lib_error`).
  Future<WorkspaceAddResult> workspaceAdd({
    required String destination,
    String? name,
    List<String> revisions = const [],
    List<String> messageParagraphs = const [],
    bool? colocate,
    SparseInheritance sparse = SparseInheritance.copy,
  }) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.workspaceAdd(
      _handleId,
      destination: destination,
      name: name,
      revisions: revisions,
      messageParagraphs: messageParagraphs,
      colocate: colocate,
      sparse: sparse,
    );
  }

  /// Bring this workspace's stale working copy up to date (Story 9.23) — the
  /// CLI's `jj workspace update-stale`, the remedy a `jj.stale_working_copy`
  /// refusal names.
  ///
  /// A stale working copy is checked out onto the fresh `@` (in a colocated
  /// workspace after a `reset git head` operation); one whose operation was lost
  /// gets a recovery commit holding the files on disk; a fresh one reports
  /// `StaleRecoveryOutcome.notStale`. A dirty working copy is snapshotted first:
  /// its edits are kept in a (divergent) commit, and the working copy then holds
  /// the fresh `@`'s files, so those edits leave the disk — as in the CLI.
  /// [lastPrecondition] then holds the recovery's trailing snapshot report.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.concurrent_working_copy`, `jj.config_error`, `jj.stale_working_copy`,
  /// `jj.jj_lib_error`).
  Future<StaleRecovery> workspaceUpdateStale() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.workspaceUpdateStale(_handleId);
  }

  /// Create local bookmarks pointing at one revision (Story 9.8) — the CLI's
  /// `jj bookmark create`.
  ///
  /// [names] are EXACT, DECODED bookmark names: the revset quoting the CLI
  /// requires (`'foo bar'`, `'foo@bar'`) is terminal input syntax the GUI
  /// replaces, so pass what the user typed. An empty list, or an empty-string
  /// name, is refused with `jj.invalid_input`.
  ///
  /// A `null` [revision] is the CLI's own `-r` default `@`, snapshotted first as
  /// in the CLI. It is a jj reverse-hex
  /// CHANGE id, so a divergent one is refused rather than guessed, and a commit
  /// hex, a revset expression and a hidden commit are unaddressable. ([interdiff]
  /// used to make the same trade; it gained a [CommitIdRef] arm, and this verb was
  /// deliberately left alone.)
  ///
  /// Both per-name preconditions run in ARGUMENT order and are FAIL-FAST: a run
  /// whose second name already exists creates NOTHING — not even the first — and
  /// writes no operation.
  ///
  /// A created name is auto-tracked as in the CLI: on every remote with a
  /// remote view whose `remotes.<r>.auto-track-bookmarks` /
  /// `auto-track-created-bookmarks` matches it, the `name@remote` row becomes
  /// tracked ([bookmarks] shows it). Warnings: `jj.bookmark_target_empty`, then
  /// `jj.bookmark_auto_track_existing` per remote that already holds the name.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ArgumentError] if a name or [revision] contains an interior NUL (U+0000),
  /// which a length-prefixed FlatBuffers string would carry all the way into a
  /// bookmark name; throws [ZanshinFfiException] on FFI errors
  /// (`ffi.invalid_handle`, `jj.invalid_input`, `jj.change_not_found`,
  /// `jj.bookmark_exists`, `jj.bookmark_tracked_remote_exists`,
  /// `jj.config_error` — e.g. an unparsable `remotes.<r>.auto-track-*` value —
  /// `jj.jj_lib_error`).
  Future<MutationResult> bookmarkCreate(List<String> names, {String? revision}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.bookmarkCreate(_handleId, names, revision: revision);
  }

  /// Delete the local bookmarks matching [names] (Story 9.8) — the CLI's
  /// `jj bookmark delete`.
  ///
  /// [names] are string PATTERNS, not exact names, and they are unioned:
  /// `exact:`, `glob:`, `regex:`, `substring:` and the `~`/`&`/`|` operators all
  /// work. **A BARE pattern is a GLOB** — `foo*` deletes both a bookmark
  /// literally named `foo*` and one named `foo1`, so use `exact:"foo*"` to reach
  /// only the literal. An empty list is refused with `jj.invalid_input`.
  ///
  /// Matching NOTHING is a SUCCESS, not a refusal: no operation is written and
  /// the returned `newOpId` is the PRE-CALL op-log head — the machine-readable
  /// form of the CLI's "No bookmarks to delete." A CONFLICTED local bookmark is
  /// deleted like any other.
  ///
  /// A TRACKED `name@remote` SURVIVES by design and keeps appearing in
  /// [bookmarks]: that is jj's "deleted bookmark, propagates on the next push"
  /// state, not a leak. `jj bookmark forget` — the verb that drops the remote
  /// rows too — is Story 9.11's.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ArgumentError] if a name contains an interior NUL (U+0000); throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.jj_lib_error`).
  Future<MutationResult> bookmarkDelete(List<String> names) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.bookmarkDelete(_handleId, names);
  }

  /// Start tracking the working-copy paths matching [paths] (Story 9.22) — the
  /// CLI's `jj file track [--include-ignored]`.
  ///
  /// [paths] are repo-relative PREFIXES; an empty list is refused with
  /// `jj.invalid_input`. [includeIgnored] tracks matching files even when they
  /// are ignored or larger than `snapshot.max-new-file-size`.
  ///
  /// An operation (`track paths`) is ALWAYS written, even when nothing matched.
  /// Like the CLI, `@` does NOT change: the tracked paths live in the working-copy
  /// state until the next snapshot moves them into `@` (jj's GH #8298) — which
  /// is the pre-verb snapshot of the very next call on this handle.
  /// `snapshotStats` merges the pre-verb snapshot's stats with the track's own,
  /// as the CLI prints them.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ArgumentError] if a path contains an interior NUL (U+0000); throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.config_error`, `jj.no_working_copy`,
  /// `jj.concurrent_working_copy`, `jj.jj_lib_error`).
  Future<TrackResult> fileTrack(List<String> paths, {bool includeIgnored = false}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.fileTrack(_handleId, paths, includeIgnored: includeIgnored);
  }

  /// Stop tracking the working-copy paths matching [paths] (Story 9.22) — the
  /// CLI's `jj file untrack`.
  ///
  /// The matched entries are removed from `@` and the files stay on disk; an
  /// operation (`untrack paths`) is always written. Every matched path must
  /// already be ignored — otherwise the call refuses with `jj.path_not_ignored`
  /// (each offender on its own line of the exception's context) and writes
  /// nothing. In a colocated workspace the git index and refs are updated in the
  /// same operation; per-ref export failures ride the result.
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ArgumentError] if a path contains an interior NUL (U+0000); throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.invalid_input`, `jj.config_error`, `jj.no_working_copy`,
  /// `jj.concurrent_working_copy`, `jj.path_not_ignored`, `jj.jj_lib_error`).
  Future<UntrackResult> fileUntrack(List<String> paths) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.fileUntrack(_handleId, paths);
  }

  /// Snapshot the working copy right now — and, in a colocated workspace, import
  /// the Git HEAD and refs (Story 9.26) — the CLI's `jj util snapshot`.
  ///
  /// It is exactly the pre-verb snapshot every other snapshotting verb runs
  /// first, with nothing after it: the GUI's "sync now" or a future working-tree
  /// trigger; the UI decides when to call it. A clean tree with unchanged refs
  /// writes no operation and returns `wasSnapshotTaken == false`. The report
  /// also becomes [lastPrecondition].
  ///
  /// Throws [StateError] synchronously if the handle is already [_closed]; throws
  /// [ZanshinFfiException] on FFI errors (`ffi.invalid_handle`,
  /// `jj.stale_working_copy` — `"<cause>\n<working_copy_op_id>\n<repo_op_id>"`
  /// in the context, `jj.config_error`, `jj.jj_lib_error`). The exception
  /// carries the PARTIAL report as its `precondition` (whose `warnings` stay
  /// empty) and the call's warnings as its `warnings` (Story 9.35).
  Future<Precondition> snapshot() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.snapshot(_handleId);
  }

  // GC backstop: a Dart Finalizer whose callback enqueues closeRepo on the
  // worker. Best-effort: the callback fires on the event loop so the worker
  // might be gone; all errors are swallowed (a GC-time throw is unacceptable).
  //
  // WHY Dart Finalizer, not NativeFinalizer: NativeFinalizer requires a C
  // function pointer taking a single Pointer<Void>. Closing a repo requires
  // a Dart async call across the isolate boundary — Dart Finalizer is the
  // correct mechanism (R4, Story 3.9).
  static final _finalizer = Finalizer<(ZanshinWorker, int)>((token) {
    final (worker, handleId) = token;
    // WHY: Finalizer callbacks are synchronous; closeRepo is best-effort GC
    // cleanup. .catchError swallows all failures; .ignore() discards the future
    // intentionally (suppresses discarded_futures lint).
    worker.closeRepo(handleId).catchError((_) {}).ignore();
  });
}

/// A [RepoHandle] fresh from a creation — [ZanshinWorker.initRepo],
/// [ZanshinWorker.cloneRepo] or [ZanshinWorker.convert] — carrying what the
/// creating call reported (Story 9.33).
///
/// It IS a [RepoHandle]: every verb, [close] and the finalizer behave exactly as
/// on one from [ZanshinWorker.openRepo], so a caller that types the result as a
/// plain [RepoHandle] keeps working unchanged.
///
/// Only a SUCCESSFUL creation yields one: a refused creation throws
/// [ZanshinFfiException], which carries the same report — its `warnings` and,
/// for a conversion, its PARTIAL `precondition` (Story 9.35).
final class CreatedRepoHandle extends RepoHandle {
  /// Wrap `handleId` returned by the worker, with the creating call's report.
  CreatedRepoHandle(super._worker, super._handleId, {required this.warnings, required this.precondition});

  /// The creating call's warnings, in the jj CLI's print order; empty when
  /// there were none — e.g. `jj.identity_missing` after a clone with an empty
  /// identity, `jj.snapshot_files_refused` for a new file a conversion could
  /// not snapshot.
  final List<ZanshinWarning> warnings;

  /// The conversion's implicit snapshot report — non-null only from
  /// [ZanshinWorker.convert], whose `jj git init` flow snapshots the working
  /// copy once; `null` from [ZanshinWorker.initRepo] and
  /// [ZanshinWorker.cloneRepo].
  ///
  /// Not [lastPrecondition]: that one is the last VERB's report on this handle,
  /// and a creation is not a verb on the handle — it stays `null` until the
  /// first verb runs.
  final Precondition? precondition;
}

/// A [RepoHandle] fresh from [ZanshinWorker.openRepo], carrying what opening
/// reported (Story 9.37).
///
/// Opening plays a jj CLI command's start-up: the CLI's secure-config fix-up
/// runs for the repo, then the workspace layer — a legacy config file migrated
/// into the secure config directory, a copied repo's config forked, a missing
/// secure directory regenerated. Those one-shot notices are [warnings]; opening
/// runs no snapshot, so there is no report beyond them.
///
/// It IS a [RepoHandle]: a caller that types the result as a plain
/// [RepoHandle] keeps working unchanged. A refused open throws
/// [ZanshinFfiException], which carries the same warnings (Story 9.35).
final class OpenedRepoHandle extends RepoHandle {
  /// Wrap `handleId` returned by the worker, with the opening call's warnings.
  OpenedRepoHandle(super._worker, super._handleId, {required this.warnings});

  /// The opening call's warnings, in the jj CLI's print order; empty when
  /// there were none — `jj.config_migrated`, `jj.config_copied` or
  /// `jj.config_regenerated`.
  final List<ZanshinWarning> warnings;
}
