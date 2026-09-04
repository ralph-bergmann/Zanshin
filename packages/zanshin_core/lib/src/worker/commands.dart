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

/// List the entries of a revision's tree in the repo identified by [handleId]
/// (Story 9.4) — the CLI's `jj file list`.
///
/// The worker looks up the raw handle in its Model-A table (read — never
/// remove), calls `zanshinFileList(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<FileList>` bytes.
final class FileListCommand extends WorkerCommand {
  const FileListCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.paths,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// Revision to list, jj reverse-hex change id; `null` = `@` (the CLI's `-r`
  /// default, here the last-snapshotted working-copy commit).
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
final class FileShowCommand extends WorkerCommand {
  const FileShowCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.paths,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
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
final class FileAnnotateCommand extends WorkerCommand {
  const FileAnnotateCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.path,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
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
final class FileSearchCommand extends WorkerCommand {
  const FileSearchCommand({
    required super.commandId,
    required this.handleId,
    required this.revision,
    required this.pattern,
    required this.paths,
    required this.nameOnly,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
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
final class GitImportCommand extends WorkerCommand {
  const GitImportCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;
}

/// Write jj's bookmarks and tags back to the backing git repo, in the repo
/// identified by [handleId] (Story 9.5) — the CLI's `jj git export`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinGitExport(raw)`, and replies with a `BufferResult` carrying the
/// FlatBuffers `Envelope<GitExportResult>` bytes.
final class GitExportCommand extends WorkerCommand {
  const GitExportCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;
}

/// Register a new git remote in the repo identified by [handleId] (Story 9.5) —
/// the CLI's `jj git remote add`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinGitRemoteAdd(raw, …)`, and replies with a `BufferResult` carrying
/// the FlatBuffers `Envelope<MutationResult>` bytes.
final class GitRemoteAddCommand extends WorkerCommand {
  const GitRemoteAddCommand({
    required super.commandId,
    required this.handleId,
    required this.name,
    required this.url,
    required this.pushUrl,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
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
final class GitRemoteRemoveCommand extends WorkerCommand {
  const GitRemoteRemoveCommand({
    required super.commandId,
    required this.handleId,
    required this.name,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
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
final class GitRemoteRenameCommand extends WorkerCommand {
  const GitRemoteRenameCommand({
    required super.commandId,
    required this.handleId,
    required this.oldName,
    required this.newName,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
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
final class GitRemoteSetUrlCommand extends WorkerCommand {
  const GitRemoteSetUrlCommand({
    required super.commandId,
    required this.handleId,
    required this.name,
    required this.url,
    required this.pushUrl,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
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
final class ShowCommand extends WorkerCommand {
  const ShowCommand({
    required super.commandId,
    required this.handleId,
    required this.revset,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// Revset EXPRESSION (not a change id — the CLI unions its revsets); `null` =
  /// `@`, the CLI's own default.
  final String? revset;
}

/// Walk the evolution of the changes [revset] denotes, in the repo identified by
/// [handleId] (Story 9.6) — the CLI's `jj evolog`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinEvolog(raw, …)`, and replies with a `BufferResult` carrying the
/// FlatBuffers `Envelope<EvologView>` bytes.
final class EvologCommand extends WorkerCommand {
  const EvologCommand({
    required super.commandId,
    required this.handleId,
    required this.revset,
    required this.limit,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
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
final class InterdiffCommand extends WorkerCommand {
  const InterdiffCommand({
    required super.commandId,
    required this.handleId,
    required this.from,
    required this.to,
    required this.paths,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// First revision, jj reverse-hex change id; `null` = `@`. Omitting BOTH sides
  /// is refused (`jj.invalid_input`).
  final String? from;

  /// Second revision, jj reverse-hex change id; `null` = `@`.
  final String? to;

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
final class WorkspaceListCommand extends WorkerCommand {
  const WorkspaceListCommand({required super.commandId, required this.handleId});

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;
}

/// Return one workspace's root directory, in the repo identified by [handleId]
/// (Story 9.7) — the CLI's `jj workspace root [--name]`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinWorkspaceRoot(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<WorkspaceRoot>` bytes.
final class WorkspaceRootCommand extends WorkerCommand {
  const WorkspaceRootCommand({
    required super.commandId,
    required this.handleId,
    required this.name,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// Workspace name; `null` = the CURRENT workspace, the CLI's own default. A
  /// present name — even the current workspace's own — goes through the workspace
  /// store and can refuse.
  final String? name;
}

/// Create local bookmarks pointing at one revision, in the repo identified by
/// [handleId] (Story 9.8) — the CLI's `jj bookmark create`.
///
/// The worker looks up the raw handle in its Model-A table (read — never remove),
/// calls `zanshinBookmarkCreate(raw, …)`, and replies with a `BufferResult`
/// carrying the FlatBuffers `Envelope<MutationResult>` bytes.
final class BookmarkCreateCommand extends WorkerCommand {
  const BookmarkCreateCommand({
    required super.commandId,
    required this.handleId,
    required this.names,
    required this.revision,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
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
final class BookmarkDeleteCommand extends WorkerCommand {
  const BookmarkDeleteCommand({
    required super.commandId,
    required this.handleId,
    required this.names,
  });

  /// Opaque dense handle id assigned by the worker on open/init/clone.
  final int handleId;

  /// String PATTERNS, unioned — NOT exact names. A bare pattern is a GLOB; use
  /// `exact:"…"` for a name containing `*`, `?` or `[`. An empty list is refused;
  /// a pattern matching nothing succeeds and writes no operation.
  final List<String> names;
}

/// Request a graceful worker shutdown (Story 3.6).
///
/// The worker closes every repo left in its handle table (joining each
/// session's Rust dispatch thread), unregisters the event sink, closes the
/// `NativeCallable`, and acks — in that order (see `ZanshinWorker.close`).
final class ShutdownCommand extends WorkerCommand {
  const ShutdownCommand({required super.commandId});
}
