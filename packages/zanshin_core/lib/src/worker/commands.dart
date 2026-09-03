// SPDX-License-Identifier: MIT

/// Typed command hierarchy for the Zanshin worker isolate (AR-AD-4).
///
/// Commands flow from the main isolate to the single long-running worker via
/// a `SendPort`. Every subtype carries only `int`, `String` or `bool`
/// fields so instances are sendable across isolate boundaries without copying.
///
/// Handle-taking commands carry the opaque `handleId` from the worker's
/// handle table, never the raw `*mut Repo` pointer (Model A, Story 3.9).
sealed class WorkerCommand {
  const WorkerCommand({required this.commandId});

  /// Correlation id allocated by the correlator. The worker echoes it
  /// back in the response so the main isolate can match futures.
  final int commandId;
}

/// Open an existing jj repository at [path].
final class OpenRepoCommand extends WorkerCommand {
  const OpenRepoCommand({required super.commandId, required this.path});

  /// Filesystem path of the jj repository root.
  final String path;
}

/// Initialise a new jj repository at [path].
final class InitRepoCommand extends WorkerCommand {
  const InitRepoCommand({
    required super.commandId,
    required this.path,
    required this.backend,
  });

  /// Filesystem path at which to create the repository.
  final String path;

  /// Storage backend: `0` = native/simple, `1` = Git.
  final int backend;
}

/// Clone a remote repository from [url] into [targetPath].
final class CloneRepoCommand extends WorkerCommand {
  const CloneRepoCommand({
    required super.commandId,
    required this.url,
    required this.targetPath,
  });

  /// Remote URL to clone from.
  final String url;

  /// Local filesystem path to clone into.
  final String targetPath;
}

/// Close the repository identified by [handleId] in the worker's handle table.
///
/// An unknown or already-closed [handleId] is rejected by the worker as
/// `ffi.invalid_handle` (Model A — no use-after-free is possible).
final class CloseRepoCommand extends WorkerCommand {
  const CloseRepoCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id previously assigned by the worker on open/init/clone.
  final int handleId;
}

/// Read the working-copy status of the repo identified by [handleId].
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_status`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<Status>` bytes.
final class StatusCommand extends WorkerCommand {
  const StatusCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;
}

/// Read the bookmark list for the repo identified by [handleId].
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_bookmarks(handle)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<Bookmarks>` bytes.
final class BookmarksCommand extends WorkerCommand {
  const BookmarksCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;
}

/// Read the configured git remotes for the repo identified by [handleId].
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_remotes(handle)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<Remotes>` bytes.
final class RemotesCommand extends WorkerCommand {
  const RemotesCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;
}

/// Read the effective `jj log` defaults for the repo identified by [handleId]
/// (Story 4.9).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_log_defaults(handle)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<LogDefaults>` bytes.
final class LogDefaultsCommand extends WorkerCommand {
  const LogDefaultsCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;
}

/// Read the operation log for the repo identified by [handleId].
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshin_op_log(handle, limit)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<OpLog>` bytes.
final class OpLogCommand extends WorkerCommand {
  const OpLogCommand({
    required super.commandId,
    required this.handleId,
    required this.limit,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
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
final class GetChangeCommand extends WorkerCommand {
  const GetChangeCommand({
    required super.commandId,
    required this.handleId,
    required this.changeId,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// jj reverse-hex change identifier (sendable across the isolate port).
  final String changeId;
}

/// Read the lane-assigned commit graph for [revset] in the repo identified by
/// [handleId] (Story 4.6).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls
/// `zanshinGraphSlice(raw, revset, prioritize, syntheticElided, shortPrefixes)`,
/// and replies with a `BufferResult` carrying the FlatBuffers
/// `Envelope<GraphSlice>` bytes.
final class GraphSliceCommand extends WorkerCommand {
  const GraphSliceCommand({
    required super.commandId,
    required this.handleId,
    required this.revset,
    required this.prioritize,
    required this.syntheticElided,
    required this.shortPrefixes,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// Revset selecting the rows (caller pass-through, FR-JJ-17).
  final String revset;

  /// Branch-prioritisation revset (caller pass-through; `RepoHandle.graphSlice`
  /// pre-fills the CLI default `present(@)`; `none()` = no prioritisation).
  final String prioritize;

  /// Render elided ancestry as synthetic "(elided revisions)" rows (caller
  /// pass-through; the CLI's `ui.log-synthetic-elided-nodes` default is `true`).
  final bool syntheticElided;

  /// Disambiguation revset for the shortest-prefix lengths (caller
  /// pass-through; `RepoHandle.graphSlice` pre-fills the CLI default; an EMPTY
  /// string disables disambiguation).
  final String shortPrefixes;
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
final class DescribeCommand extends WorkerCommand {
  const DescribeCommand({
    required super.commandId,
    required this.handleId,
    required this.changeId,
    required this.description,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// jj reverse-hex change identifier to rewrite.
  final String changeId;

  /// New description text.
  final String description;
}

/// Create a new, empty change on top of [parents] in the repo identified by
/// [handleId], and switch the working copy to it (Story 6.5).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinNewChange(raw, parents)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class NewChangeCommand extends WorkerCommand {
  const NewChangeCommand({
    required super.commandId,
    required this.handleId,
    required this.parents,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// jj reverse-hex change identifiers of the new change's parents.
  final List<String> parents;
}

/// Switch the working copy to [changeId] without creating a new commit, in the
/// repo identified by [handleId] (Story 6.5).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinEdit(raw, changeId)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class EditCommand extends WorkerCommand {
  const EditCommand({
    required super.commandId,
    required this.handleId,
    required this.changeId,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// jj reverse-hex change identifier to switch the working copy to.
  final String changeId;
}

/// Abandon [changeIds] in the repo identified by [handleId] (Story 6.5).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinAbandon(raw, changeIds)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class AbandonCommand extends WorkerCommand {
  const AbandonCommand({
    required super.commandId,
    required this.handleId,
    required this.changeIds,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// jj reverse-hex change identifiers to abandon.
  final List<String> changeIds;
}

/// Revert the last operation of the repo identified by [handleId], one step
/// back from the current head (Story 6.5).
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinUndo(raw)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class UndoCommand extends WorkerCommand {
  const UndoCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;
}

/// Fetch all branches and tags from [remoteName] and import them, in the repo
/// identified by [handleId] (Story 6.5). Never moves `@`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinGitFetch(raw, remoteName)`, and replies with a
/// `BufferResult` carrying the FlatBuffers `Envelope<MutationResult>` bytes.
/// Progress rides the same process-global event sink `WatcherEvent` already
/// uses, tagged with the handle's `session_id`.
final class GitFetchCommand extends WorkerCommand {
  const GitFetchCommand({
    required super.commandId,
    required this.handleId,
    required this.remoteName,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// Name of the configured git remote to fetch from.
  final String remoteName;
}

/// Give the paths selected here the content they have in another commit, in the
/// repo identified by [handleId] (Story 9.3) — the CLI's `jj restore`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinRestore(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class RestoreCommand extends WorkerCommand {
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
final class AbsorbCommand extends WorkerCommand {
  const AbsorbCommand({
    required super.commandId,
    required this.handleId,
    required this.from,
    required this.into,
    required this.paths,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// Source revision, jj reverse-hex change id; `null` = `@`.
  final String? from;

  /// Destination REVSET expression (not a change id); `null` = the CLI's
  /// `mutable()` default, resolved through the repo's effective config.
  final String? into;

  /// Repo-relative paths interpreted as PREFIXES; empty = all paths.
  final List<String> paths;
}

/// Request a graceful worker shutdown (Story 3.6).
///
/// The worker closes every repo left in its handle table (joining each
/// session's Rust dispatch thread), unregisters the event sink, closes the
/// `NativeCallable`, and acks — in that order (see `ZanshinWorker.close`).
final class ShutdownCommand extends WorkerCommand {
  const ShutdownCommand({required super.commandId});
}
