// SPDX-License-Identifier: MIT

import '../ffi/bookmarks.dart' show BookmarkSortKey;
import '../ffi/commit_views.dart' show ChangeIdRef, CommitIdRef, RevisionRef;
import '../ffi/config.dart' show ConfigScope, ConfigTarget;
import '../ffi/drop_actions.dart' show DropLocation, DropSource;
import '../ffi/fetch.dart' show FetchRefs, FetchRemotes;
import '../ffi/movement.dart' show MovementDirection;
import '../ffi/op_log.dart' show RestoreWhat;
import '../ffi/rebase.dart' show ArrangeAction;
import '../ffi/repo.dart' show ObjectHash;
import '../ffi/resolve.dart' show ResolveFiles, ResolveTool;
import '../ffi/select_tree.dart' show FileSelection, SourceTree, TreeSelection;
import '../ffi/workspace.dart' show SparseInheritance;
import '../graph_layout/layout_request.dart' show LaneOrder, LayoutMode;

/// Typed command hierarchy for the Zanshin worker isolate (AR-AD-4).
///
/// Commands flow from the main isolate to the single long-running worker via
/// a `SendPort`. Almost every subtype carries only `int`, `String` or `bool`
/// fields so instances are sendable across isolate boundaries without copying;
/// the one exception is [InterdiffCommand]'s [RevisionRef] pair, which is a
/// plain final-field class and therefore sendable too — `Isolate.spawn`
/// isolates share a code group.
///
/// Handle-taking commands carry the opaque `handleId` from the worker's
/// handle table, never the raw `*mut Repo` pointer (Model A, Story 3.9).
sealed class WorkerCommand {
  const WorkerCommand({required this.commandId});

  /// Correlation id allocated by the correlator. The worker echoes it
  /// back in the response so the main isolate can match futures.
  final int commandId;
}

/// A command addressed to ONE open repository by its worker-side [handleId].
///
/// `ZanshinWorker.send` keys the per-handle bookkeeping it does on every reply
/// (the Story 9.26 `RepoHandle.lastPrecondition`) off this interface.
abstract interface class HandleScopedCommand {
  /// Opaque dense handle id assigned by the worker on open/init/clone.
  int get handleId;
}

/// Open an existing jj repository at [path].
final class OpenRepoCommand extends WorkerCommand {
  const OpenRepoCommand({required super.commandId, required this.path});

  /// Filesystem path of the jj repository root.
  final String path;
}

/// Initialise a new jj repository at [path] — `jj git init` for [backend]
/// `1`, a native workspace for `0` (Story 9.20 adds the CLI's flags).
final class InitRepoCommand extends WorkerCommand {
  const InitRepoCommand({
    required super.commandId,
    required this.path,
    required this.backend,
    this.colocate = false,
    this.noColocate = false,
    this.objectHash,
  });

  /// Filesystem path at which to create the repository.
  final String path;

  /// Storage backend: `0` = native/simple, `1` = Git.
  final int backend;

  /// `--colocate`.
  final bool colocate;

  /// `--no-colocate`.
  final bool noColocate;

  /// `--object-hash`; `null` = not given.
  final ObjectHash? objectHash;
}

/// Clone the Git repository at [source] into [destination] — the CLI's
/// `jj git clone` (Story 9.20).
final class CloneRepoCommand extends WorkerCommand {
  const CloneRepoCommand({
    required super.commandId,
    required this.source,
    required this.destination,
    this.remoteName,
    this.colocate = false,
    this.noColocate = false,
    this.depth,
    this.branches,
    this.tags,
    this.objectHash,
  });

  /// The URL or path to clone from.
  final String source;

  /// Local filesystem path to clone into: missing or an empty directory.
  final String destination;

  /// `--remote`; `null` = `origin`.
  final String? remoteName;

  /// `--colocate`.
  final bool colocate;

  /// `--no-colocate`.
  final bool noColocate;

  /// `--depth`; `null` = the whole history.
  final int? depth;

  /// `-b` patterns; `null` = the flag not given.
  final List<String>? branches;

  /// `-t` patterns; `null` = the flag not given.
  final List<String>? tags;

  /// `--object-hash`; `null` = not given.
  final ObjectHash? objectHash;
}

/// Close the repository identified by [handleId] in the worker's handle table.
///
/// An unknown or already-closed [handleId] is rejected by the worker as
/// `ffi.invalid_handle` (Model A — no use-after-free is possible).
final class CloseRepoCommand extends WorkerCommand implements HandleScopedCommand {
  const CloseRepoCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id previously assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

/// Read the working-copy status of the repo identified by [handleId].
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_status`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<Status>` bytes.
final class StatusCommand extends WorkerCommand implements HandleScopedCommand {
  const StatusCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

/// Read the bookmark list for the repo identified by [handleId] — the CLI's
/// `jj bookmark list` with its arguments (Story 9.19).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinBookmarks(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<Bookmarks>` bytes.
final class BookmarksCommand extends WorkerCommand implements HandleScopedCommand {
  const BookmarksCommand({
    required super.commandId,
    required this.handleId,
    this.names = const [],
    this.revisions = const [],
    this.remotes = const [],
    this.allRemotes = false,
    this.tracked = false,
    this.conflicted = false,
    this.sort = const [],
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Name PATTERNS (a bare one is a glob), OR-ed with [revisions].
  final List<String> names;

  /// Revsets matching LOCAL targets.
  final List<String> revisions;

  /// Remote-name patterns (`--remote`).
  final List<String> remotes;

  /// `--all-remotes`.
  final bool allRemotes;

  /// `--tracked`.
  final bool tracked;

  /// `--conflicted`.
  final bool conflicted;

  /// `--sort`; empty applies `ui.bookmark-list-sort-keys`.
  final List<BookmarkSortKey> sort;
}

/// Read the configured git remotes for the repo identified by [handleId].
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_remotes(handle)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<Remotes>` bytes.
final class RemotesCommand extends WorkerCommand implements HandleScopedCommand {
  const RemotesCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

/// Read the remotes `jj git push` without `--remote` would push to, for the
/// repo identified by [handleId] (Story 9.54).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_git_push_remotes(handle)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<GitPushRemotes>` bytes.
final class GitPushRemotesCommand extends WorkerCommand implements HandleScopedCommand {
  const GitPushRemotesCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

/// Read the remotes `jj git fetch` without `--remote` would fetch from, for
/// the repo identified by [handleId] (Story 9.30).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_git_fetch_remotes(handle)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<GitFetchRemotes>` bytes.
final class GitFetchRemotesCommand extends WorkerCommand implements HandleScopedCommand {
  const GitFetchRemotesCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

/// Read the effective `jj log` defaults for the repo identified by [handleId]
/// (Story 4.9).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_log_defaults(handle)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<LogDefaults>` bytes.
final class LogDefaultsCommand extends WorkerCommand implements HandleScopedCommand {
  const LogDefaultsCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

/// Read the operation log for the repo identified by [handleId].
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_op_log(handle, limit)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<OpLog>` bytes.
final class OpLogCommand extends WorkerCommand implements HandleScopedCommand {
  const OpLogCommand({
    required super.commandId,
    required this.handleId,
    required this.limit,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Max operations to return; `< 0` means all.
  final int limit;
}

/// Read full change metadata for the change identified by [changeId] in the
/// repo identified by [handleId].
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_change`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<Change>` bytes.
final class GetChangeCommand extends WorkerCommand implements HandleScopedCommand {
  const GetChangeCommand({
    required super.commandId,
    required this.handleId,
    required this.changeId,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// jj reverse-hex change identifier (sendable across the isolate port).
  final String changeId;
}

/// Read the whole revset's index-only graph topology in the repo identified by
/// [handleId] (Story 4.12).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinGraphTopology(raw, …)`, copies the returned native
/// envelope ONCE into a `TransferableTypedData`, frees the native buffer, and
/// replies with a `TransferResult` — the one command whose reply is not a
/// `BufferResult` copy (an unknown handle still replies `BufferResult`).
final class GraphTopologyCommand extends WorkerCommand implements HandleScopedCommand {
  const GraphTopologyCommand({
    required super.commandId,
    required this.handleId,
    required this.revset,
    required this.prioritize,
    required this.shortPrefixes,
    required this.anchors,
    required this.withTimestamps,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Revset selecting the nodes (caller pass-through, FR-JJ-17).
  final String revset;

  /// Branch-prioritisation revset (caller pass-through; `RepoHandle.graphTopology`
  /// pre-fills the CLI default `present(@)`; `none()` = no prioritisation).
  final String prioritize;

  /// Disambiguation revset for the shortest-prefix lengths (caller
  /// pass-through; `RepoHandle.graphTopology` pre-fills the CLI default; an
  /// EMPTY string disables disambiguation).
  final String shortPrefixes;

  /// Ordered revsets whose selected nodes the layout's priority rule reads
  /// (caller pass-through; `defaultGraphAnchors` is the editable pre-fill).
  final List<String> anchors;

  /// Load each non-root node's committer timestamp.
  final bool withTimestamps;
}

/// Lay out the whole revset's graph in the repo identified by [handleId] (Story 4.11).
///
/// The worker looks up the raw handle in its Model-A table (read — never remove), calls
/// `zanshinGraphTopology(raw, …)` with timestamps iff [mode] is `free`, lays the topology out
/// with the Dart layout engine while the native envelope is still alive, copies the envelope and
/// the grid ONCE each into a `TransferableTypedData`, frees the native buffer, and replies with a
/// `GraphLayoutResult` (an unknown handle still replies `BufferResult`). Nothing is kept in the
/// worker between commands (ADR-0002).
final class GraphLayoutCommand extends WorkerCommand implements HandleScopedCommand {
  const GraphLayoutCommand({
    required super.commandId,
    required this.handleId,
    required this.revset,
    required this.prioritize,
    required this.shortPrefixes,
    required this.anchors,
    required this.mode,
    required this.order,
    required this.utcOffsetMin,
    required this.budget,
    required this.stacks,
    required this.expandedKeys,
    required this.collapsedKeys,
    required this.keepOpenKeys,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Revset selecting the nodes (caller pass-through, FR-JJ-17).
  final String revset;

  /// Branch-prioritisation revset (caller pass-through; `none()` = no prioritisation).
  final String prioritize;

  /// Disambiguation revset for the shortest-prefix lengths (caller pass-through; an EMPTY string
  /// disables disambiguation).
  final String shortPrefixes;

  /// Ordered revsets whose selected nodes the layout's priority rule reads (caller pass-through).
  final List<String> anchors;

  /// The layout's vertical model; `free` loads the committer timestamps.
  final LayoutMode mode;

  /// The layout's lane order.
  final LaneOrder order;

  /// The fixed UTC offset in minutes for `free`'s day buckets, within ±1440.
  final int utcOffsetMin;

  /// The work units the `compact` lane order may spend, ≥ 0.
  final int budget;

  /// Whether the layout groups linear runs into stacks (Story 4.13, docs/graph-layout.md §4.8);
  /// `false` is 4.11's layout and ignores the key lists.
  final bool stacks;

  /// Keys of runs the user expanded (a run's key is its oldest member's).
  final List<String> expandedKeys;

  /// Keys of runs the user collapsed.
  final List<String> collapsedKeys;

  /// Keys of nodes whose run stays expanded whatever else holds (the selection, a go-to target).
  final List<String> keepOpenKeys;
}

/// Detect the repository kind at [path] (FR-JJ-17).
///
/// Handle-free: the worker calls `zanshinRepoDetect` directly and replies with
/// a `BufferResult` carrying the FlatBuffers `Envelope<RepoDetect>` bytes.
final class DetectRepoCommand extends WorkerCommand {
  const DetectRepoCommand({required super.commandId, required this.path});

  /// Filesystem path to classify.
  final String path;
}

/// Convert the Git repository at [path] to a colocated jj workspace.
///
/// Handle-free: the worker calls `zanshinRepoConvert` and, on success, stores
/// the returned handle in its Model-A table and replies with a `HandleResult`.
/// A failed conversion is not rolled back; its error names what it left
/// (Story 9.57).
final class ConvertRepoCommand extends WorkerCommand {
  const ConvertRepoCommand({required super.commandId, required this.path});

  /// Filesystem path of the Git repository to convert.
  final String path;
}

/// Rewrite the description of the change identified by [changeId] in the repo
/// identified by [handleId] (Story 6.5).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinDescribe(raw, changeId, description)`, and replies
/// with a `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class DescribeCommand extends WorkerCommand implements HandleScopedCommand {
  const DescribeCommand({
    required super.commandId,
    required this.handleId,
    required this.changeId,
    required this.description,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// jj reverse-hex change identifier to rewrite.
  final String changeId;

  /// New description text.
  final String description;
}

/// Create a new, empty change in the repo identified by [handleId] — on top of
/// [parents], or inserted after [insertAfter] / before [insertBefore] (`jj new
/// -A` / `-B`, Story 9.48) — and switch the working copy to it (Story 6.5).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinNewChange(raw, parents, insertAfter:, insertBefore:)`,
/// and replies with a `BufferResult` carrying the FlatBuffers
/// `Envelope<MutationResult>` bytes.
final class NewChangeCommand extends WorkerCommand implements HandleScopedCommand {
  const NewChangeCommand({
    required super.commandId,
    required this.handleId,
    required this.parents,
    this.insertAfter = const [],
    this.insertBefore = const [],
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// jj reverse-hex change identifiers of the new change's parents.
  final List<String> parents;

  /// `-A` targets (jj reverse-hex change ids); empty = the flag not given.
  final List<String> insertAfter;

  /// `-B` targets (jj reverse-hex change ids); empty = the flag not given.
  final List<String> insertBefore;
}

/// Switch the working copy to [changeId] without creating a new commit, in the
/// repo identified by [handleId] (Story 6.5).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinEdit(raw, changeId)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class EditCommand extends WorkerCommand implements HandleScopedCommand {
  const EditCommand({
    required super.commandId,
    required this.handleId,
    required this.changeId,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// jj reverse-hex change identifier to switch the working copy to.
  final String changeId;
}

/// Abandon [changeIds] in the repo identified by [handleId] (Story 6.5).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinAbandon(raw, changeIds)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class AbandonCommand extends WorkerCommand implements HandleScopedCommand {
  const AbandonCommand({
    required super.commandId,
    required this.handleId,
    required this.changeIds,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// jj reverse-hex change identifiers to abandon.
  final List<String> changeIds;
}

/// Undo the last operation of the repo identified by [handleId] — the CLI's
/// `jj undo` with its undo stack (Story 6.5, Story 9.39).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinUndo(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class UndoCommand extends WorkerCommand implements HandleScopedCommand {
  const UndoCommand({
    required super.commandId,
    required this.handleId,
    required this.allowCrossWorkspace,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The CLI's `--allow-cross-workspace`: undo an operation performed in
  /// another workspace instead of refusing (`jj.undo_cross_workspace`).
  final bool allowCrossWorkspace;
}

/// Redo the most recently undone operation of the repo identified by
/// [handleId] — the CLI's `jj redo` (Story 9.21).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinRedo(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class RedoCommand extends WorkerCommand implements HandleScopedCommand {
  const RedoCommand({required super.commandId, required this.handleId, required this.allowCrossWorkspace});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The CLI's `--allow-cross-workspace`: redo an undo performed in another
  /// workspace instead of refusing (`jj.redo_cross_workspace`).
  final bool allowCrossWorkspace;
}

/// Show one operation of the repo identified by [handleId] and its changes —
/// the CLI's `jj op show` (Story 9.21).
///
/// The worker calls `zanshinOpShow(raw, …)` and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<OpShow>` bytes.
final class OpShowCommand extends WorkerCommand implements HandleScopedCommand {
  const OpShowCommand({
    required super.commandId,
    required this.handleId,
    required this.operation,
    required this.showChangesIn,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The operation expression; `null` = `@`.
  final String? operation;

  /// `--show-changes-in`; `null` = `revsets.op-diff-changes-in`.
  final String? showChangesIn;
}

/// Compare two operations of the repo identified by [handleId] — the CLI's
/// `jj op diff` (Story 9.21).
///
/// The worker calls `zanshinOpDiff(raw, …)` and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<OpDiffResult>` bytes.
final class OpDiffCommand extends WorkerCommand implements HandleScopedCommand {
  const OpDiffCommand({
    required super.commandId,
    required this.handleId,
    required this.operation,
    required this.from,
    required this.to,
    required this.showChangesIn,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `--operation`; `null` = not given.
  final String? operation;

  /// `--from`; `null` = not given.
  final String? from;

  /// `--to`; `null` = not given.
  final String? to;

  /// `--show-changes-in`; `null` = `revsets.op-diff-changes-in`.
  final String? showChangesIn;
}

/// Abandon operation history of the repo identified by [handleId] — the
/// CLI's `jj op abandon` (Story 9.21).
///
/// The worker calls `zanshinOpAbandon(raw, …)` and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<OpAbandonResult>` bytes.
final class OpAbandonCommand extends WorkerCommand implements HandleScopedCommand {
  const OpAbandonCommand({required super.commandId, required this.handleId, required this.operation});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The operation or range to abandon (`..@-`, `<id>`, …).
  final String operation;
}

/// Restore the repo identified by [handleId] to the state at an operation —
/// the CLI's `jj op restore` (Story 9.12).
///
/// The worker calls `zanshinOpRestore(raw, …)` and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class OpRestoreCommand extends WorkerCommand implements HandleScopedCommand {
  const OpRestoreCommand({
    required super.commandId,
    required this.handleId,
    required this.operation,
    required this.what,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The operation expression to restore to.
  final String operation;

  /// `--what`; empty = both portions.
  final List<RestoreWhat> what;
}

/// Revert one operation of the repo identified by [handleId] — the CLI's
/// `jj op revert` (Story 9.12).
///
/// The worker calls `zanshinOpRevert(raw, …)` and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class OpRevertCommand extends WorkerCommand implements HandleScopedCommand {
  const OpRevertCommand({
    required super.commandId,
    required this.handleId,
    required this.operation,
    required this.what,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The operation expression to revert (`@` is the CLI's default).
  final String operation;

  /// `--what`; empty = both portions.
  final List<RestoreWhat> what;
}

/// Make an operation part of the operation log of the repo identified by
/// [handleId] — the CLI's `jj op integrate` (Story 9.12).
///
/// The worker calls `zanshinOpIntegrate(raw, …)` and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<OpIntegrateResult>` bytes.
final class OpIntegrateCommand extends WorkerCommand implements HandleScopedCommand {
  const OpIntegrateCommand({required super.commandId, required this.handleId, required this.operation});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The operation to integrate (an id prefix names an unpublished one too).
  final String operation;
}

/// Fetch the [remotes] and [refs] selected, and import them, in the repo
/// identified by [handleId] — the CLI's `jj git fetch` (Stories 6.5, 9.30).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), runs `zanshinGitFetch(raw, remotes: …, refs: …, cancelToken: …)`
/// on a helper isolate (Story 9.52) while later commands for the same handle
/// wait, and replies with a `BufferResult` carrying the FlatBuffers
/// `Envelope<GitFetchResult>` bytes.
/// Progress rides the same process-global event sink `WatcherEvent` already
/// uses, tagged with the handle's `session_id`.
final class GitFetchCommand extends WorkerCommand implements HandleScopedCommand {
  const GitFetchCommand({
    required super.commandId,
    required this.handleId,
    required this.remotes,
    required this.refs,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Which remotes to fetch from.
  final FetchRemotes remotes;

  /// Which refs to fetch from each remote.
  final FetchRefs refs;
}

/// Ask [remoteName] what it has now and diff that against the head view,
/// without fetching, in the repo identified by [handleId] (Story 9.24) — the
/// `git ls-remote` poll behind the Fetch button's badge.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), runs `zanshinGitRemoteChanges(raw, remoteName, cancelToken: …)` on
/// a helper isolate (Story 9.52) while later commands for the same handle wait,
/// and replies with a `BufferResult` carrying the FlatBuffers
/// `Envelope<RemoteChanges>` bytes. No snapshot, no operation, no progress.
final class GitRemoteChangesCommand extends WorkerCommand implements HandleScopedCommand {
  const GitRemoteChangesCommand({
    required super.commandId,
    required this.handleId,
    required this.remoteName,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Name of the configured git remote to ask, exactly.
  final String remoteName;
}

/// Push bookmarks and tags to git remotes, in the repo identified by
/// [handleId] (Story 9.20) — the CLI's `jj git push`, every parameter passed
/// through.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), runs `zanshinGitPush(raw, …)` on a helper isolate (Story 9.52)
/// while later commands for the same handle wait, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<GitPushResult>` bytes.
final class GitPushCommand extends WorkerCommand implements HandleScopedCommand {
  const GitPushCommand({
    required super.commandId,
    required this.handleId,
    required this.remotes,
    required this.bookmarks,
    required this.tags,
    required this.all,
    required this.tracked,
    required this.deleted,
    required this.allowEmptyDescription,
    required this.allowPrivate,
    required this.allowConflicts,
    required this.revisions,
    required this.changes,
    required this.named,
    required this.dryRun,
    required this.options,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `--remote`; `null` = not given.
  final List<String>? remotes;

  /// `-b` patterns.
  final List<String> bookmarks;

  /// `-t` patterns.
  final List<String> tags;

  /// `--all`.
  final bool all;

  /// `--tracked`.
  final bool tracked;

  /// `--deleted`.
  final bool deleted;

  /// `--allow-empty-description`.
  final bool allowEmptyDescription;

  /// `--allow-private`.
  final bool allowPrivate;

  /// `--allow-conflicts` (hidden in the CLI).
  final bool allowConflicts;

  /// `-r` revsets.
  final List<String> revisions;

  /// `-c` revsets.
  final List<String> changes;

  /// `--named NAME=REVISION`.
  final List<String> named;

  /// `--dry-run`.
  final bool dryRun;

  /// `--option` push options.
  final List<String> options;
}

/// Give the paths selected here the content they have in another commit, in the
/// repo identified by [handleId] (Story 9.3) — the CLI's `jj restore`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinRestore(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class RestoreCommand extends WorkerCommand implements HandleScopedCommand {
  const RestoreCommand({
    required super.commandId,
    required this.handleId,
    required this.from,
    required this.into,
    required this.changesIn,
    required this.paths,
    required this.restoreDescendants,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Source revision, jj reverse-hex change id; `null` = `@` (or, when [into]
  /// and [changesIn] are also `null`, the destination's parent tree).
  final String? from;

  /// Destination revision, jj reverse-hex change id; `null` = `@`.
  final String? into;

  /// Undo this revision's own diff; `null` = not used. Cannot be combined with
  /// [from]/[into].
  final String? changesIn;

  /// Repo-relative paths interpreted as PREFIXES; empty = all paths.
  final List<String> paths;

  /// Reparent children (preserving their content) instead of rebasing them.
  final bool restoreDescendants;
}

/// Move each hunk of the source revision into the closest destination where the
/// corresponding lines were last modified, in the repo identified by [handleId]
/// (Story 9.3) — the CLI's `jj absorb`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinAbsorb(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<AbsorbResult>` bytes.
final class AbsorbCommand extends WorkerCommand implements HandleScopedCommand {
  const AbsorbCommand({
    required super.commandId,
    required this.handleId,
    required this.from,
    required this.into,
    required this.paths,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Source revision, jj reverse-hex change id; `null` = `@`.
  final String? from;

  /// Destination REVSET expression (not a change id); `null` = the CLI's
  /// `mutable()` default, resolved through the repo's effective config.
  final String? into;

  /// Repo-relative paths interpreted as PREFIXES; empty = all paths.
  final List<String> paths;
}

/// List the entries of a revision's tree in the repo identified by [handleId]
/// (Story 9.4) — the CLI's `jj file list`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinFileList(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<FileList>` bytes.
final class FileListCommand extends WorkerCommand implements HandleScopedCommand {
  const FileListCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.paths,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Revision to list, jj reverse-hex change id; `null` = `@` (the CLI's `-r`
  /// default, snapshotted first as in the CLI).
  final String? revision;

  /// Repo-relative paths interpreted as PREFIXES; empty = all paths.
  final List<String> paths;
}

/// Read the contents of the files selected by [paths] in the repo identified by
/// [handleId] (Story 9.4) — the CLI's `jj file show`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinFileShow(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<FileContents>` bytes.
final class FileShowCommand extends WorkerCommand implements HandleScopedCommand {
  const FileShowCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.paths,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Revision to read from, jj reverse-hex change id; `null` = `@`.
  final String? revision;

  /// Repo-relative paths interpreted as PREFIXES. Unlike every other verb this
  /// list may NOT be empty — the CLI marks its FILESETS argument `required`.
  final List<String> paths;
}

/// Annotate [path] line by line in the repo identified by [handleId]
/// (Story 9.4) — the CLI's `jj file annotate`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinFileAnnotate(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<FileAnnotation>` bytes.
final class FileAnnotateCommand extends WorkerCommand implements HandleScopedCommand {
  const FileAnnotateCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.path,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Revision to annotate, jj reverse-hex change id; `null` = `@`.
  final String? revision;

  /// A single PLAIN repo-relative path — not a prefix, not a fileset.
  final String path;
}

/// Search the files of a revision for [pattern] in the repo identified by
/// [handleId] (Story 9.4) — the CLI's `jj file search`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinFileSearch(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<FileSearch>` bytes.
final class FileSearchCommand extends WorkerCommand implements HandleScopedCommand {
  const FileSearchCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.pattern,
    required this.paths,
    required this.nameOnly,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Revision to search, jj reverse-hex change id; `null` = `@`.
  final String? revision;

  /// jj's `kind:pattern` string-pattern syntax; a bare pattern is a `regex`.
  final String pattern;

  /// Repo-relative paths interpreted as PREFIXES; empty = all paths.
  final List<String> paths;

  /// Stop a file's scan at its first match.
  final bool nameOnly;
}

/// Import the backing git repo's refs into jj's view, in the repo identified by
/// [handleId] (Story 9.5) — the CLI's `jj git import`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinGitImport(raw)`, and replies with a `BufferResult` carrying the
/// FlatBuffers `Envelope<GitImportResult>` bytes. Takes no arguments — the CLI's
/// own `jj git import` has none either.
final class GitImportCommand extends WorkerCommand implements HandleScopedCommand {
  const GitImportCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

/// Write jj's bookmarks and tags back to the backing git repo, in the repo
/// identified by [handleId] (Story 9.5) — the CLI's `jj git export`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinGitExport(raw)`, and replies with a `BufferResult` carrying the
/// FlatBuffers `Envelope<GitExportResult>` bytes.
final class GitExportCommand extends WorkerCommand implements HandleScopedCommand {
  const GitExportCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

/// Register a new git remote in the repo identified by [handleId] (Story 9.5) —
/// the CLI's `jj git remote add`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinGitRemoteAdd(raw, …)`, and replies with a `BufferResult` carrying
/// the FlatBuffers `Envelope<MutationResult>` bytes.
final class GitRemoteAddCommand extends WorkerCommand implements HandleScopedCommand {
  const GitRemoteAddCommand({
    required super.commandId,
    required this.handleId,
    required this.name,
    required this.url,
    required this.pushUrl,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The remote's name, e.g. `origin`.
  final String name;

  /// The remote's fetch URL or path, passed through verbatim.
  final String url;

  /// The URL used for push; `null` = push to [url], which is git's own behaviour.
  final String? pushUrl;
}

/// Remove a git remote and forget its bookmarks, in the repo identified by
/// [handleId] (Story 9.5) — the CLI's `jj git remote remove`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinGitRemoteRemove(raw, name)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class GitRemoteRemoveCommand extends WorkerCommand implements HandleScopedCommand {
  const GitRemoteRemoveCommand({
    required super.commandId,
    required this.handleId,
    required this.name,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The remote to remove. The reserved remote `git` is removable and writes no
  /// operation.
  final String name;
}

/// Rename a git remote in the repo identified by [handleId] (Story 9.5) — the
/// CLI's `jj git remote rename`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinGitRemoteRename(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class GitRemoteRenameCommand extends WorkerCommand implements HandleScopedCommand {
  const GitRemoteRenameCommand({
    required super.commandId,
    required this.handleId,
    required this.oldName,
    required this.newName,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The name of an existing remote.
  final String oldName;

  /// The desired name for [oldName]. Validated BEFORE [oldName]'s existence is
  /// checked — jj-lib's own ordering.
  final String newName;
}

/// Re-point a git remote's fetch and/or push URL, in the repo identified by
/// [handleId] (Story 9.5) — the CLI's `jj git remote set-url`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinGitRemoteSetUrl(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes. This verb never
/// writes an operation.
final class GitRemoteSetUrlCommand extends WorkerCommand implements HandleScopedCommand {
  const GitRemoteSetUrlCommand({
    required super.commandId,
    required this.handleId,
    required this.name,
    required this.url,
    required this.pushUrl,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The remote to re-point.
  final String name;

  /// New fetch URL; `null` = leave it unchanged (a URL cannot be removed).
  final String? url;

  /// New push URL; `null` = leave it unchanged.
  final String? pushUrl;
}

/// Show each revision [revset] denotes with what it changed, in the repo
/// identified by [handleId] (Story 9.6) — the CLI's `jj show`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinShow(raw, …)`, and replies with a `BufferResult` carrying the
/// FlatBuffers `Envelope<ShowView>` bytes.
final class ShowCommand extends WorkerCommand implements HandleScopedCommand {
  const ShowCommand({
    required super.commandId,
    required this.handleId,
    required this.revset,
    required this.limit,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Revset EXPRESSION (not a change id — the CLI unions its revsets); `null` =
  /// `@`, the CLI's own default.
  final String? revset;

  /// A ZANSHIN-SIDE cap the CLI has no counterpart for, applied in raw revset
  /// order; `null` = no limit, which is the CLI-parity default. `0` is a
  /// meaningful value — an empty result, not an error.
  final int? limit;
}

/// Walk the evolution of the changes [revset] denotes, in the repo identified by
/// [handleId] (Story 9.6) — the CLI's `jj evolog`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinEvolog(raw, …)`, and replies with a `BufferResult` carrying the
/// FlatBuffers `Envelope<EvologView>` bytes.
final class EvologCommand extends WorkerCommand implements HandleScopedCommand {
  const EvologCommand({
    required super.commandId,
    required this.handleId,
    required this.revset,
    required this.limit,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Revset EXPRESSION; `null` = `@`, as in [ShowCommand].
  final String? revset;

  /// The CLI's `-n/--limit`, applied in walk order; `null` = no limit. `0` is a
  /// meaningful value — an empty result, not an error.
  final int? limit;
}

/// Compare what two revisions each CHANGE, with the parent difference factored
/// out, in the repo identified by [handleId] (Story 9.6) — the CLI's
/// `jj interdiff`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinInterdiff(raw, …)`, and replies with a `BufferResult` carrying
/// the FlatBuffers `Envelope<InterdiffView>` bytes.
final class InterdiffCommand extends WorkerCommand implements HandleScopedCommand {
  const InterdiffCommand({
    required super.commandId,
    required this.handleId,
    required this.from,
    required this.to,
    required this.paths,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// First revision — a [ChangeIdRef] (reverse-hex change-id prefix, visible
  /// commits only) or a [CommitIdRef] (commit-id hex prefix, reaches hidden
  /// commits); `null` = `@`. Omitting BOTH sides is refused
  /// (`jj.invalid_input`).
  ///
  /// The first non-primitive field to cross the port. `Isolate.spawn` isolates
  /// share a code group, so a plain final-field class is sendable as-is.
  final RevisionRef? from;

  /// Second revision, same two currencies as [from]; `null` = `@`.
  final RevisionRef? to;

  /// Repo-relative paths interpreted as PREFIXES; empty = all paths.
  final List<String> paths;
}

/// List every workspace with its working-copy commit and root directory, in the
/// repo identified by [handleId] (Story 9.7) — the CLI's `jj workspace list`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinWorkspaceList(raw)`, and replies with a `BufferResult` carrying
/// the FlatBuffers `Envelope<WorkspaceList>` bytes. No argument field: the CLI
/// verb takes none.
final class WorkspaceListCommand extends WorkerCommand implements HandleScopedCommand {
  const WorkspaceListCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

/// Return one workspace's root directory, in the repo identified by [handleId]
/// (Story 9.7) — the CLI's `jj workspace root [--name]`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinWorkspaceRoot(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<WorkspaceRoot>` bytes.
final class WorkspaceRootCommand extends WorkerCommand implements HandleScopedCommand {
  const WorkspaceRootCommand({
    required super.commandId,
    required this.handleId,
    required this.name,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Workspace name; `null` = the CURRENT workspace, the CLI's own default. A
  /// present name — even the current workspace's own — goes through the workspace
  /// store and can refuse.
  final String? name;
}

/// Add a workspace to the repo identified by [handleId] (Story 9.23) — the
/// CLI's `jj workspace add`, every argument passed through.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinWorkspaceAdd(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<WorkspaceAddResult>` bytes.
final class WorkspaceAddCommand extends WorkerCommand implements HandleScopedCommand {
  const WorkspaceAddCommand({
    required super.commandId,
    required this.handleId,
    required this.destination,
    required this.name,
    required this.revisions,
    required this.messageParagraphs,
    required this.colocate,
    required this.sparse,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The CLI's `DESTINATION`, against the current workspace root.
  final String destination;

  /// The CLI's `--name`; `null` = the destination's final component.
  final String? name;

  /// The CLI's repeatable `-r` revsets; empty = the current `@`'s parents.
  final List<String> revisions;

  /// The CLI's repeatable `-m`.
  final List<String> messageParagraphs;

  /// `--colocate` (`true`) / `--no-colocate` (`false`); `null` = the CLI's default.
  final bool? colocate;

  /// The CLI's `--sparse-patterns`.
  final SparseInheritance sparse;
}

/// Forget ([remove] false) or remove ([remove] true) workspaces of the repo
/// identified by [handleId] (Story 9.13) — the CLI's `jj workspace forget` /
/// `remove`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinWorkspaceForget` or `zanshinWorkspaceRemove`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<WorkspaceRemoveResult>`
/// bytes.
final class WorkspaceRemoveCommand extends WorkerCommand implements HandleScopedCommand {
  const WorkspaceRemoveCommand({
    required super.commandId,
    required this.handleId,
    required this.names,
    required this.remove,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Workspace names; for forget, empty = the current workspace.
  final List<String> names;

  /// `remove` rather than `forget`.
  final bool remove;
}

/// Rename the current workspace of the repo identified by [handleId] (Story
/// 9.13) — the CLI's `jj workspace rename`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinWorkspaceRename(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class WorkspaceRenameCommand extends WorkerCommand implements HandleScopedCommand {
  const WorkspaceRenameCommand({
    required super.commandId,
    required this.handleId,
    required this.newName,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The new name; empty is refused (`jj.invalid_input`).
  final String newName;
}

/// Bring the stale working copy of the repo identified by [handleId] up to date
/// (Story 9.23) — the CLI's `jj workspace update-stale`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinWorkspaceUpdateStale(raw)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<StaleRecovery>` bytes. No argument field:
/// the CLI verb takes none.
final class WorkspaceUpdateStaleCommand extends WorkerCommand implements HandleScopedCommand {
  const WorkspaceUpdateStaleCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

/// Read the object half of each commit in [commitIds] at the pinned operation
/// [operationId], in the repo identified by [handleId] (Story 4.10) — the
/// continuation of the graph topology call's `jj log`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinCommitContents(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<CommitContents>` bytes. It runs no pre-verb
/// snapshot, so `lastPrecondition` is left untouched.
final class CommitContentsCommand extends WorkerCommand implements HandleScopedCommand {
  const CommitContentsCommand({
    required super.commandId,
    required this.handleId,
    required this.operationId,
    required this.commitIds,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The FULL hex id of the operation the topology call loaded.
  final String operationId;

  /// FULL hex commit ids; the answer comes back in this order.
  final List<String> commitIds;
}

/// Create local bookmarks pointing at one revision, in the repo identified by
/// [handleId] (Story 9.8) — the CLI's `jj bookmark create`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinBookmarkCreate(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class BookmarkCreateCommand extends WorkerCommand implements HandleScopedCommand {
  const BookmarkCreateCommand({
    required super.commandId,
    required this.handleId,
    required this.names,
    required this.revision,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// EXACT, DECODED bookmark names — never CLI argument text, so no revset
  /// quoting. An empty list is refused (`jj.invalid_input`), and so is an
  /// empty-string name. Preconditions are checked in THIS order, fail-fast.
  final List<String> names;

  /// jj reverse-hex change id of the target; `null` = `@`, the CLI's own `-r`
  /// default.
  final String? revision;
}

/// Delete the local bookmarks matching [names], in the repo identified by
/// [handleId] (Story 9.8) — the CLI's `jj bookmark delete`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinBookmarkDelete(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class BookmarkDeleteCommand extends WorkerCommand implements HandleScopedCommand {
  const BookmarkDeleteCommand({
    required super.commandId,
    required this.handleId,
    required this.names,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// String PATTERNS, unioned — NOT exact names. A bare pattern is a GLOB; use
  /// `exact:"…"` for a name containing `*`, `?` or `[`. An empty list is refused;
  /// a pattern matching nothing succeeds and writes no operation.
  final List<String> names;
}

/// Move existing local bookmarks to one revision, in the repo identified by
/// [handleId] (Story 9.19) — the CLI's `jj bookmark move`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinBookmarkMove(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class BookmarkMoveCommand extends WorkerCommand implements HandleScopedCommand {
  const BookmarkMoveCommand({
    required super.commandId,
    required this.handleId,
    required this.names,
    required this.from,
    required this.to,
    required this.allowBackwards,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// EXACT bookmark names.
  final List<String> names;

  /// Revset texts (`--from`).
  final List<String> from;

  /// jj reverse-hex change id of the target; `null` = `@`.
  final String? to;

  /// `--allow-backwards`.
  final bool allowBackwards;
}

/// Advance the closest bookmarks to a revision, in the repo identified by
/// [handleId] (Story 9.19) — the CLI's `jj bookmark advance`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinBookmarkAdvance(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class BookmarkAdvanceCommand extends WorkerCommand implements HandleScopedCommand {
  const BookmarkAdvanceCommand({
    required super.commandId,
    required this.handleId,
    required this.names,
    required this.to,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// EXACT bookmark names; empty = the CLI's default candidates.
  final List<String> names;

  /// jj reverse-hex change id of the target; `null` = `revsets.bookmark-advance-to`.
  final String? to;
}

/// Rename a local bookmark, in the repo identified by [handleId] (Story 9.19) —
/// the CLI's `jj bookmark rename`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinBookmarkRename(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class BookmarkRenameCommand extends WorkerCommand implements HandleScopedCommand {
  const BookmarkRenameCommand({
    required super.commandId,
    required this.handleId,
    required this.oldName,
    required this.newName,
    required this.overwriteExisting,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The DECODED name to rename.
  final String oldName;

  /// The DECODED new name.
  final String newName;

  /// `--overwrite-existing`.
  final bool overwriteExisting;
}

/// Create or move local bookmarks to one revision by name, in the repo
/// identified by [handleId] (Story 9.11) — the CLI's `jj bookmark set`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinBookmarkSet(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class BookmarkSetCommand extends WorkerCommand implements HandleScopedCommand {
  const BookmarkSetCommand({
    required super.commandId,
    required this.handleId,
    required this.names,
    required this.revision,
    required this.allowBackwards,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// DECODED bookmark names.
  final List<String> names;

  /// jj reverse-hex change id of the target; `null` = `@`.
  final String? revision;

  /// `--allow-backwards`.
  final bool allowBackwards;
}

/// Forget bookmarks, in the repo identified by [handleId] (Story 9.11) — the
/// CLI's `jj bookmark forget`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinBookmarkForget(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class BookmarkForgetCommand extends WorkerCommand implements HandleScopedCommand {
  const BookmarkForgetCommand({
    required super.commandId,
    required this.handleId,
    required this.names,
    required this.includeRemotes,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// String PATTERNS (a bare one is a GLOB).
  final List<String> names;

  /// `--include-remotes`.
  final bool includeRemotes;
}

/// Start ([untrack] false) or stop ([untrack] true) tracking remote bookmarks,
/// in the repo identified by [handleId] (Story 9.11) — the CLI's `jj bookmark
/// track` / `untrack`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinBookmarkTrack` or `zanshinBookmarkUntrack`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class BookmarkTrackCommand extends WorkerCommand implements HandleScopedCommand {
  const BookmarkTrackCommand({
    required super.commandId,
    required this.handleId,
    required this.names,
    required this.remotes,
    required this.untrack,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `BOOKMARK[@REMOTE]` texts: `name@remote` symbols or string patterns.
  final List<String> names;

  /// Remote-name patterns (`--remote`); empty = not given.
  final List<String> remotes;

  /// `untrack` rather than `track`.
  final bool untrack;
}

/// Start tracking the working-copy paths matching [paths], in the repo
/// identified by [handleId] (Story 9.22) — the CLI's `jj file track`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinFileTrack(raw, …)`, and replies with a `BufferResult` carrying
/// the FlatBuffers `Envelope<TrackResult>` bytes.
final class FileTrackCommand extends WorkerCommand implements HandleScopedCommand {
  const FileTrackCommand({
    required super.commandId,
    required this.handleId,
    required this.paths,
    required this.includeIgnored,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Repo-relative PREFIXES; an empty list is refused (`jj.invalid_input`).
  final List<String> paths;

  /// The CLI's `--include-ignored`: track matching files even when ignored or
  /// larger than `snapshot.max-new-file-size`.
  final bool includeIgnored;
}

/// Stop tracking the working-copy paths matching [paths], in the repo
/// identified by [handleId] (Story 9.22) — the CLI's `jj file untrack`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinFileUntrack(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<UntrackResult>` bytes.
final class FileUntrackCommand extends WorkerCommand implements HandleScopedCommand {
  const FileUntrackCommand({
    required super.commandId,
    required this.handleId,
    required this.paths,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Repo-relative PREFIXES, each of which must already be ignored; an empty
  /// list is refused (`jj.invalid_input`).
  final List<String> paths;
}

/// Set or clear the executable bit of the files matching [paths] in one revision
/// of the repo identified by [handleId] (Story 9.13) — the CLI's `jj file chmod`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinFileChmod(raw, …)`, and replies with a `BufferResult` carrying
/// the FlatBuffers `Envelope<MutationResult>` bytes.
final class FileChmodCommand extends WorkerCommand implements HandleScopedCommand {
  const FileChmodCommand({
    required super.commandId,
    required this.handleId,
    required this.paths,
    required this.executable,
    required this.revision,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Repo-relative PREFIXES; an empty list is refused (`jj.invalid_input`).
  final List<String> paths;

  /// `x` (`true`) or `n` (`false`).
  final bool executable;

  /// jj reverse-hex change id of the revision; `null` = `@`.
  final String? revision;
}

/// Snapshot the working copy of the repo identified by [handleId] right now —
/// and, in a colocated workspace, import the Git HEAD and refs (Story 9.26) — the
/// CLI's `jj util snapshot`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinSnapshot(raw)`, and replies with a `BufferResult` carrying an
/// ok `Envelope` with NO `data` and the report in `Envelope.precondition`.
final class SnapshotCommand extends WorkerCommand implements HandleScopedCommand {
  const SnapshotCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;
}

// ── The config surface (Story 9.28) ─────────────────────────────────────────
//
// Nine HANDLE-FREE commands (like [DetectRepoCommand]): the workspace root rides
// the command (`null` = no workspace), so a config that makes `openRepo` fail can
// still be listed and repaired. Each worker arm calls its `zanshinConfig*`
// adapter and replies with a `BufferResult` carrying the envelope bytes.

/// `jj config list` — see `ZanshinWorker.configList`.
final class ConfigListCommand extends WorkerCommand {
  const ConfigListCommand({
    required super.commandId,
    required this.workspaceRoot,
    required this.name,
    required this.scope,
    required this.includeDefaults,
    required this.includeOverridden,
  });

  /// The workspace root (the CLI's `-R`); `null` = no workspace.
  final String? workspaceRoot;

  /// Only values under this dotted prefix; `null` = everything.
  final String? name;

  /// Only values of this scope; `null` = no scope flag.
  final ConfigScope? scope;

  /// The CLI's `--include-defaults`.
  final bool includeDefaults;

  /// The CLI's `--include-overridden`.
  final bool includeOverridden;
}

/// `jj config get NAME` — see `ZanshinWorker.configGet`.
final class ConfigGetCommand extends WorkerCommand {
  const ConfigGetCommand({required super.commandId, required this.workspaceRoot, required this.name});

  /// The workspace root; `null` = no workspace.
  final String? workspaceRoot;

  /// The dotted config name.
  final String name;
}

/// `jj config path` — see `ZanshinWorker.configPath`.
final class ConfigPathCommand extends WorkerCommand {
  const ConfigPathCommand({required super.commandId, required this.workspaceRoot, required this.scope});

  /// The workspace root; `null` = no workspace.
  final String? workspaceRoot;

  /// The scope.
  final ConfigScope scope;
}

/// `jj config set` — see `ZanshinWorker.configSet`.
final class ConfigSetCommand extends WorkerCommand {
  const ConfigSetCommand({
    required super.commandId,
    required this.workspaceRoot,
    required this.target,
    required this.name,
    required this.value,
  });

  /// The workspace root; `null` = no workspace.
  final String? workspaceRoot;

  /// The file to write: a scope's first file, or one named file.
  final ConfigTarget target;

  /// The dotted config name.
  final String name;

  /// The value as TOML text (a bare string when it does not look like TOML).
  final String value;
}

/// `jj config unset` — see `ZanshinWorker.configUnset`.
final class ConfigUnsetCommand extends WorkerCommand {
  const ConfigUnsetCommand({
    required super.commandId,
    required this.workspaceRoot,
    required this.target,
    required this.name,
  });

  /// The workspace root; `null` = no workspace.
  final String? workspaceRoot;

  /// The file to write: a scope's first file, or one named file.
  final ConfigTarget target;

  /// The dotted config name.
  final String name;
}

/// `jj config edit`, half 1 — see `ZanshinWorker.configFileRead`.
final class ConfigFileReadCommand extends WorkerCommand {
  const ConfigFileReadCommand({
    required super.commandId,
    required this.workspaceRoot,
    required this.target,
  });

  /// The workspace root; `null` = no workspace.
  final String? workspaceRoot;

  /// The file to read: a scope's first file, or one named file.
  final ConfigTarget target;
}

/// `jj config edit`, half 2 — see `ZanshinWorker.configFileWrite`.
final class ConfigFileWriteCommand extends WorkerCommand {
  const ConfigFileWriteCommand({
    required super.commandId,
    required this.workspaceRoot,
    required this.path,
    required this.text,
  });

  /// The workspace root; `null` = no workspace.
  final String? workspaceRoot;

  /// The file, as `configFileRead` returned it.
  final String path;

  /// The new text; refused (nothing written) unless it is valid TOML.
  final String text;
}

/// `jj config gc`, half 1 — see `ZanshinWorker.configGcList`.
final class ConfigGcListCommand extends WorkerCommand {
  const ConfigGcListCommand({required super.commandId});
}

/// `jj config gc`, half 2 — see `ZanshinWorker.configGcDelete`.
final class ConfigGcDeleteCommand extends WorkerCommand {
  const ConfigGcDeleteCommand({required super.commandId, required this.configDirs});

  /// The config directories to delete.
  final List<String> configDirs;
}

/// Move changes from one or more revisions into another, in the repo
/// identified by [handleId] (Story 9.15) — the CLI's `jj squash`, paths only.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinSquash(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class SquashCommand extends WorkerCommand implements HandleScopedCommand {
  const SquashCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.from,
    required this.into,
    required this.paths,
    required this.message,
    required this.useDestinationMessage,
    required this.keepEmptied,
    this.editedDescription,
    this.trees = const [],
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `-r`, a change id; `null` = `@` into its parent (with [from]/[into] unset).
  final String? revision;

  /// `--from` change ids; empty = `@` (with [into] set).
  final List<String> from;

  /// `--into` change id; `null` = `@` (with [from] set).
  final String? into;

  /// Repo-relative paths interpreted as PREFIXES; empty = all paths.
  final List<String> paths;

  /// The repeatable `-m`; `null` = no `-m`.
  final List<String>? message;

  /// `-u`.
  final bool useDestinationMessage;

  /// `-k`.
  final bool keepEmptied;

  /// The user's edit of the editor text (Story 9.54) — the CLI's `--editor`
  /// saving exactly this text, written without trailers; `null` = no editor.
  final String? editedDescription;

  /// The tree arm (Story 9.50): per source, the tree selected against that
  /// source's parent tree; empty = the paths arm.
  final List<SourceTree> trees;
}

/// Preview the description a [SquashCommand] with the same arguments would
/// have to ask for, in the repo identified by [handleId] (Story 9.15).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinSquashPlan(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<SquashPlan>` bytes.
final class SquashPlanCommand extends WorkerCommand implements HandleScopedCommand {
  const SquashPlanCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.from,
    required this.into,
    required this.paths,
    required this.message,
    required this.useDestinationMessage,
    required this.keepEmptied,
    this.trees = const [],
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// As [SquashCommand.revision].
  final String? revision;

  /// As [SquashCommand.from].
  final List<String> from;

  /// As [SquashCommand.into].
  final String? into;

  /// As [SquashCommand.paths].
  final List<String> paths;

  /// As [SquashCommand.message].
  final List<String>? message;

  /// As [SquashCommand.useDestinationMessage].
  final bool useDestinationMessage;

  /// As [SquashCommand.keepEmptied].
  final bool keepEmptied;

  /// As [SquashCommand.trees].
  final List<SourceTree> trees;
}

/// Preview which verbs [source] can run at each of [locations], in the repo
/// identified by [handleId] (Story 9.31). Writes no operation of its own.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinDropActions(raw, source, locations)`, and replies
/// with a `BufferResult` carrying the FlatBuffers `Envelope<DropActions>`
/// bytes.
final class DropActionsCommand extends WorkerCommand implements HandleScopedCommand {
  const DropActionsCommand({
    required super.commandId,
    required this.handleId,
    required this.source,
    required this.locations,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// What is dragged.
  final DropSource source;

  /// Where it is dropped.
  final List<DropLocation> locations;
}

/// Preview the card menu's verbs for [changeId], in the repo identified by
/// [handleId] (Story 9.31). Writes no operation of its own.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinChangeActions(raw, changeId)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<ChangeActions>` bytes.
final class ChangeActionsCommand extends WorkerCommand implements HandleScopedCommand {
  const ChangeActionsCommand({
    required super.commandId,
    required this.handleId,
    required this.changeId,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// jj reverse-hex change identifier of the card.
  final String changeId;
}

/// Split a revision in two, in the repo identified by [handleId] (Story 9.15)
/// — the CLI's `jj split`, paths only.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinSplit(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<SplitResult>` bytes.
final class SplitCommand extends WorkerCommand implements HandleScopedCommand {
  const SplitCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.paths,
    required this.message,
    required this.parallel,
    required this.onto,
    required this.insertAfter,
    required this.insertBefore,
    this.editedSelectedDescription,
    this.editedRemainingDescription,
    this.tree,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `-r`, a change id; `null` = `@`.
  final String? revision;

  /// Repo-relative paths interpreted as PREFIXES; empty with [tree] set.
  final List<String> paths;

  /// `-m` for the selected commit; `null` = no `-m`.
  final List<String>? message;

  /// `--parallel`.
  final bool parallel;

  /// `-o` change ids; `null` = the flag not given.
  final List<String>? onto;

  /// `-A` change ids; `null` = the flag not given.
  final List<String>? insertAfter;

  /// `-B` change ids; `null` = the flag not given.
  final List<String>? insertBefore;

  /// The user's edit of the selected commit's editor text (Story 9.54); both
  /// or neither with [editedRemainingDescription]; `null` = no editor.
  final String? editedSelectedDescription;

  /// The user's edit of the remaining commit's editor text (Story 9.54).
  final String? editedRemainingDescription;

  /// The tree arm (Story 9.50): the selected commit's tree; `null` = the paths
  /// arm.
  final TreeSelection? tree;
}

/// Commit the working-copy commit, in the repo identified by [handleId] (Story
/// 9.49) — the CLI's `jj commit -m <message> [paths]`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinCommit(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class CommitCommand extends WorkerCommand implements HandleScopedCommand {
  const CommitCommand({
    required super.commandId,
    required this.handleId,
    required this.paths,
    required this.message,
    this.tree,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// Repo-relative paths interpreted as PREFIXES; empty = every change.
  final List<String> paths;

  /// `-m`, required; empty = `-m ""`.
  final List<String> message;

  /// The tree arm (Story 9.50): the committed `@`'s tree; `null` = the paths
  /// arm.
  final TreeSelection? tree;
}

/// Write the tree a hunk selection yields, in the repo identified by
/// [handleId] (Story 9.50) — the CLI's builtin diff editor applying the same
/// choice. Writes no operation of its own.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinSelectTree(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<SelectedTree>` bytes.
final class SelectTreeCommand extends WorkerCommand implements HandleScopedCommand {
  const SelectTreeCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.left,
    required this.files,
    this.from,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The revision the selection was made in; `null` = `@`.
  final String? revision;

  /// The tree the selection was made against: the revision's parent tree, or
  /// [from]'s own tree.
  final List<String> left;

  /// The selected files.
  final List<FileSelection> files;

  /// Story 9.17: the revision whose own tree is the diff's left side
  /// (`diffedit --from`); `null` = the revision's parent tree.
  final String? from;
}

/// List a revision's conflicts with what a merge editor needs, in the repo
/// identified by [handleId] (Story 9.17) — the CLI's `jj resolve --list`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinResolveList(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<ResolveList>` bytes.
final class ResolveListCommand extends WorkerCommand implements HandleScopedCommand {
  const ResolveListCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.paths,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `-r`; `null` = `@`.
  final String? revision;

  /// Repo-relative prefixes; empty = every conflict.
  final List<String> paths;
}

/// Resolve a revision's conflicts, in the repo identified by [handleId]
/// (Story 9.17) — the CLI's `jj resolve`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinResolve(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class ResolveCommand extends WorkerCommand implements HandleScopedCommand {
  const ResolveCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.paths,
    required this.tool,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `-r`; `null` = `@`.
  final String? revision;

  /// Repo-relative prefixes; empty = every conflict. Not with
  /// [ResolveFiles].
  final List<String> paths;

  /// What resolves them.
  final ResolveTool tool;
}

/// Touch up a revision's content with a GUI-selected tree, in the repo
/// identified by [handleId] (Story 9.17) — the CLI's `jj diffedit`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinDiffedit(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class DiffeditCommand extends WorkerCommand implements HandleScopedCommand {
  const DiffeditCommand({
    required super.commandId,
    required this.handleId,
    required this.tree,
    required this.right,
    this.revision,
    this.from,
    this.to,
    this.restoreDescendants = false,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The edited tree and the `left` it was selected against.
  final TreeSelection tree;

  /// The target's tree ids the selection saw (its `ShowEntry.treeIds`).
  final List<String> right;

  /// `-r`; not with [from] / [to].
  final String? revision;

  /// `--from`.
  final String? from;

  /// `--to`.
  final String? to;

  /// `--restore-descendants`.
  final bool restoreDescendants;
}

/// Cancel the network call — fetch, push or clone — sent as command
/// [targetCommandId] (Story 9.52).
///
/// The worker owns the cancel tokens: a running call's token is cancelled, a
/// call still queued behind its handle starts with a cancelled token, and a
/// finished or unknown target is a no-op. The worker acks with an ok envelope
/// once it has processed the cancel.
final class NetworkCancelCommand extends WorkerCommand {
  const NetworkCancelCommand({required super.commandId, required this.targetCommandId});

  /// The `commandId` of the network call to cancel.
  final int targetCommandId;
}

/// Move revisions to a new place in the graph, in the repo identified by
/// [handleId] (Story 9.16) — the CLI's `jj rebase`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinRebase(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class RebaseCommand extends WorkerCommand implements HandleScopedCommand {
  const RebaseCommand({
    required super.commandId,
    required this.handleId,
    required this.branch,
    required this.source,
    required this.revisions,
    required this.onto,
    required this.insertAfter,
    required this.insertBefore,
    required this.skipEmptied,
    required this.keepDivergent,
    required this.simplifyParents,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `-b` change ids; empty = the flag not given.
  final List<String> branch;

  /// `-s` change ids; empty = the flag not given.
  final List<String> source;

  /// `-r` change ids; empty = the flag not given.
  final List<String> revisions;

  /// `-o` change ids; empty = the flag not given.
  final List<String> onto;

  /// `-A` change ids; empty = the flag not given.
  final List<String> insertAfter;

  /// `-B` change ids; empty = the flag not given.
  final List<String> insertBefore;

  /// `--skip-emptied`.
  final bool skipEmptied;

  /// `--keep-divergent`.
  final bool keepDivergent;

  /// `--simplify-parents`.
  final bool simplifyParents;
}

/// Make revisions siblings, in the repo identified by [handleId] (Story 9.16)
/// — the CLI's `jj parallelize`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinParallelize(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class ParallelizeCommand extends WorkerCommand implements HandleScopedCommand {
  const ParallelizeCommand({required super.commandId, required this.handleId, required this.changeIds});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The revisions to parallelize.
  final List<String> changeIds;
}

/// Rearrange revisions, in the repo identified by [handleId] (Story 9.16) —
/// the CLI's `jj arrange` with its TUI session as data.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinArrange(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class ArrangeCommand extends WorkerCommand implements HandleScopedCommand {
  const ArrangeCommand({
    required super.commandId,
    required this.handleId,
    required this.revisions,
    required this.actions,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The revisions to arrange; empty = the `revsets.arrange` setting.
  final List<String> revisions;

  /// The TUI's key actions, replayed in order.
  final List<ArrangeAction> actions;
}

/// Drop redundant parent edges, in the repo identified by [handleId] (Story
/// 9.14) — the CLI's `jj simplify-parents`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinSimplifyParents(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<SimplifyParentsResult>`
/// bytes.
final class SimplifyParentsCommand extends WorkerCommand implements HandleScopedCommand {
  const SimplifyParentsCommand({
    required super.commandId,
    required this.handleId,
    required this.source,
    required this.revisions,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `-s`: these revisions with their descendants.
  final List<String> source;

  /// `-r`: these revisions. Both empty = the `revsets.simplify-parents`
  /// setting.
  final List<String> revisions;
}

/// Modify revisions' metadata, in the repo identified by [handleId] (Story
/// 9.9) — the CLI's `jj metaedit`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinMetaedit(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class MetaeditCommand extends WorkerCommand implements HandleScopedCommand {
  const MetaeditCommand({
    required super.commandId,
    required this.handleId,
    required this.revisions,
    required this.updateChangeId,
    required this.message,
    required this.updateAuthorTimestamp,
    required this.updateAuthor,
    required this.author,
    required this.authorTimestamp,
    required this.forceRewrite,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The revisions to modify; empty = `@`.
  final List<String> revisions;

  /// `--update-change-id`.
  final bool updateChangeId;

  /// The `-m` paragraphs; `null` = no `-m`.
  final List<String>? message;

  /// `--update-author-timestamp`.
  final bool updateAuthorTimestamp;

  /// `--update-author`.
  final bool updateAuthor;

  /// `--author` (`Name <email>`); `null` = not given.
  final String? author;

  /// `--author-timestamp` (RFC 2822 / RFC 3339); `null` = not given.
  final String? authorTimestamp;

  /// `--force-rewrite`.
  final bool forceRewrite;
}

/// Move the working copy to a child or parent, in the repo identified by
/// [handleId] (Story 9.10) — the CLI's `jj next` / `jj prev`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinMoveWorkingCopy(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class MoveWorkingCopyCommand extends WorkerCommand implements HandleScopedCommand {
  const MoveWorkingCopyCommand({
    required super.commandId,
    required this.handleId,
    required this.direction,
    required this.offset,
    required this.edit,
    required this.noEdit,
    required this.conflict,
    required this.target,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `jj next` or `jj prev`.
  final MovementDirection direction;

  /// `[OFFSET]`; `null` = the CLI's default `1`.
  final int? offset;

  /// `-e/--edit`.
  final bool edit;

  /// `-n/--no-edit`.
  final bool noEdit;

  /// `--conflict`.
  final bool conflict;

  /// The chosen candidate's hex commit id; `null` = no choice.
  final String? target;
}

/// List the targets a working-copy move chooses from, in the repo identified
/// by [handleId] (Story 9.10).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinMovementTargets(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MovementTargets>` bytes.
final class MovementTargetsCommand extends WorkerCommand implements HandleScopedCommand {
  const MovementTargetsCommand({
    required super.commandId,
    required this.handleId,
    required this.direction,
    required this.offset,
    required this.edit,
    required this.noEdit,
    required this.conflict,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `jj next` or `jj prev`.
  final MovementDirection direction;

  /// `[OFFSET]`; `null` = the CLI's default `1`.
  final int? offset;

  /// `-e/--edit`.
  final bool edit;

  /// `-n/--no-edit`.
  final bool noEdit;

  /// `--conflict`.
  final bool conflict;
}

/// Duplicate revisions, in the repo identified by [handleId] (Story 9.9) — the
/// CLI's `jj duplicate`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinDuplicate(raw, …)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class DuplicateCommand extends WorkerCommand implements HandleScopedCommand {
  const DuplicateCommand({
    required super.commandId,
    required this.handleId,
    required this.revisions,
    required this.onto,
    required this.insertAfter,
    required this.insertBefore,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The revisions to duplicate; empty = `@`.
  final List<String> revisions;

  /// `-o` change ids; empty = the flag not given.
  final List<String> onto;

  /// `-A` change ids; empty = the flag not given.
  final List<String> insertAfter;

  /// `-B` change ids; empty = the flag not given.
  final List<String> insertBefore;
}

/// Apply the reverse of revisions, in the repo identified by [handleId] (Story
/// 9.18) — the CLI's `jj revert`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinRevert(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class RevertCommand extends WorkerCommand implements HandleScopedCommand {
  const RevertCommand({
    required super.commandId,
    required this.handleId,
    required this.revisions,
    required this.onto,
    required this.insertAfter,
    required this.insertBefore,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// The revisions to revert (`-r`, required).
  final List<String> revisions;

  /// `-o` change ids; empty = the flag not given.
  final List<String> onto;

  /// `-A` change ids; empty = the flag not given.
  final List<String> insertAfter;

  /// `-B` change ids; empty = the flag not given.
  final List<String> insertBefore;
}

/// Run the configured fix tools, in the repo identified by [handleId] (Story
/// 9.9) — the CLI's `jj fix`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), runs `zanshinFix(raw, …, cancelToken: …)` on a helper isolate
/// like the network calls (a tool may run long; `NetworkCancelCommand` cancels
/// it), and replies with a `BufferResult` carrying the FlatBuffers
/// `Envelope<FixResult>` bytes. Later commands for [handleId] wait for it.
final class FixCommand extends WorkerCommand implements HandleScopedCommand {
  const FixCommand({
    required super.commandId,
    required this.handleId,
    required this.source,
    required this.paths,
    required this.includeUnchangedFiles,
    required this.allLines,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  @override
  final int handleId;

  /// `-s` change ids; empty = the `revsets.fix` setting.
  final List<String> source;

  /// Repo-relative prefixes to fix; empty = every path.
  final List<String> paths;

  /// `--include-unchanged-files`.
  final bool includeUnchangedFiles;

  /// `--all-lines`.
  final bool allLines;
}

/// Request a graceful worker shutdown (Story 3.6).
///
/// The worker closes every repo left in its handle table (joining each
/// session's Rust dispatch thread), unregisters the event sink, closes the
/// `NativeCallable`, and acks — in that order (see `ZanshinWorker.close`).
final class ShutdownCommand extends WorkerCommand {
  const ShutdownCommand({required super.commandId});
}
