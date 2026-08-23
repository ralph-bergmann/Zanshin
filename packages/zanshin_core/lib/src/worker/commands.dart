// SPDX-License-Identifier: MIT

/// Typed command hierarchy for the Zanshin worker isolate (AR-AD-4).
///
/// Commands flow from the main isolate to the single long-running worker via
/// a `SendPort`. Every subtype carries only `int` or `String`
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
/// remove), calls `zanshinGraphSlice(raw, revset, prioritize)`, and replies
/// with a `BufferResult` carrying the FlatBuffers `Envelope<GraphSlice>` bytes.
final class GraphSliceCommand extends WorkerCommand {
  const GraphSliceCommand({
    required super.commandId,
    required this.handleId,
    required this.revset,
    required this.prioritize,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// Revset selecting the rows (caller pass-through, FR-JJ-17).
  final String revset;

  /// Branch-prioritisation revset (caller pass-through; `RepoHandle.graphSlice`
  /// pre-fills the CLI default `present(@)`; `none()` = no prioritisation).
  final String prioritize;
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

/// Request a graceful worker shutdown (Story 3.6).
///
/// The worker closes every repo left in its handle table (joining each
/// session's Rust dispatch thread), unregisters the event sink, closes the
/// `NativeCallable`, and acks — in that order (see `ZanshinWorker.close`).
final class ShutdownCommand extends WorkerCommand {
  const ShutdownCommand({required super.commandId});
}
