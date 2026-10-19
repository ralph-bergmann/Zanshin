// SPDX-License-Identifier: MIT

import 'dart:collection';

import 'package:meta/meta.dart';

import 'envelope_zanshin.ffi_generated.dart' as fbs;

// ── Dart models ───────────────────────────────────────────────────────────────

/// One caveat a call reported alongside its result — the jj CLI's
/// `Warning: …` block as a coded fact (Story 9.32, mirrors `zanshin_jj::Warning`).
///
/// Warnings never change a call's outcome: the result is the same with or
/// without them. [code] is one of the [ZanshinWarningCode] constants; [message]
/// is the CLI's text for that warning, verbatim (English, without the
/// `Warning: ` heading and without the CLI's hints), paths rendered relative
/// to the workspace root. The one exception is the Zanshin-only
/// [ZanshinWarningCode.loginShellUnresolved] (Story 9.36): Dart builds it
/// itself — it never crosses FFI — and its message is Zanshin's own; no CLI
/// prints it.
@immutable
final class ZanshinWarning {
  const ZanshinWarning({required this.code, required this.message});

  /// The registered warning code — one of [ZanshinWarningCode].
  final String code;

  /// The jj CLI's warning text for this case, verbatim (Zanshin's own text
  /// for the Zanshin-only [ZanshinWarningCode.loginShellUnresolved]).
  final String message;

  @override
  bool operator ==(Object other) => other is ZanshinWarning && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'ZanshinWarning($code, $message)';
}

/// Every registered warning code (Story 9.32) — the registry is the
/// "Warning Codes" section of `docs/rust-error-codes.md`, and each constant
/// equals its registry string.
abstract final class ZanshinWarningCode {
  /// An operation was committed with an empty `user.name` and/or `user.email`.
  static const identityMissing = 'jj.identity_missing';

  /// `@` was immutable, so a new `@` was created on top of it.
  static const workingCopyImmutable = 'jj.working_copy_immutable';

  /// A colocated snapshot found top-level `.jjconflict*` entries.
  static const jjconflictFilesPresent = 'jj.jjconflict_files_present';

  /// Git HEAD could not be moved to `@`'s parent.
  static const gitHeadUpdateFailed = 'jj.git_head_update_failed';

  /// Bookmarks or tags the Git export could not write.
  static const gitExportFailed = 'jj.git_export_failed';

  /// Git refs the import could not read.
  static const gitImportFailed = 'jj.git_import_failed';

  /// New files over `snapshot.max-new-file-size` stayed untracked.
  static const snapshotFilesRefused = 'jj.snapshot_files_refused';

  /// Paths skipped because their names are not valid UTF-8.
  static const snapshotPathsNotUtf8 = 'jj.snapshot_paths_not_utf8';

  /// Working-copy updates skipped because of conflicting on-disk changes.
  static const checkoutFilesSkipped = 'jj.checkout_files_skipped';

  /// Explicitly named paths that match no entry.
  static const pathsUnmatched = 'jj.paths_unmatched';

  /// A `[revset-aliases]` / `[fileset-aliases]` entry that does not load.
  static const configAliasInvalid = 'jj.config_alias_invalid';

  /// A config layer redefines `mutable()`, `immutable()` or `builtin_immutable_heads()`.
  static const configAliasRedefined = 'jj.config_alias_redefined';

  /// A revset parsed with a diagnostic.
  static const revsetDiagnostic = 'jj.revset_diagnostic';

  /// The short-prefixes disambiguation index could not be loaded.
  static const shortPrefixesFailed = 'jj.short_prefixes_failed';

  /// Another remote already uses the URL just added.
  static const remoteUrlDuplicate = 'jj.remote_url_duplicate';

  /// A bookmark was created on an empty, undescribed revision.
  static const bookmarkTargetEmpty = 'jj.bookmark_target_empty';

  /// Exact names given to `bookmark delete` that match no local bookmark.
  static const bookmarkNamesUnmatched = 'jj.bookmark_names_unmatched';

  /// A path `absorb` could not split.
  static const absorbPathSkipped = 'jj.absorb_path_skipped';

  /// A path whose content could not be read.
  static const pathAccessDenied = 'jj.path_access_denied';

  /// A path that exists but is not a file.
  static const pathNotAFile = 'jj.path_not_a_file';

  /// `user.name`/`user.email` was set but `@`'s author stays the old one.
  static const configWorkingCopyAuthor = 'jj.config_working_copy_author';

  /// A missing repo config directory could not be deleted.
  static const configGcDeleteFailed = 'jj.config_gc_delete_failed';

  /// `config list` found nothing to list.
  static const configNothingListed = 'jj.config_nothing_listed';

  /// A failed clone could not remove what it had created (Story 9.33). Only an
  /// error envelope carries it, so Dart sees it on the thrown
  /// `ZanshinFfiException.warnings` (Story 9.35).
  static const cloneCleanupFailed = 'jj.clone_cleanup_failed';

  /// A legacy `.jj/repo/config.toml` / `.jj/workspace-config.toml` was
  /// migrated into the secure config directory at command start (Story 9.37):
  /// by `openRepo`, any command that runs the pre-verb snapshot, or a config
  /// command given a workspace root.
  static const configMigrated = 'jj.config_migrated';

  /// The repo was copied, so its secure config was forked under a new id at
  /// command start (Story 9.37).
  static const configCopied = 'jj.config_copied';

  /// The secure config directory was missing and was regenerated empty at
  /// command start (Story 9.37).
  static const configRegenerated = 'jj.config_regenerated';

  /// `undo` undid a `jj git push` operation, which often leaves conflicted
  /// bookmarks (Story 9.39).
  static const undoPushOperation = 'jj.undo_push_operation';

  /// `undo` undid a workspace removal: the workspace is back, its directory is
  /// not (Story 9.39).
  static const undoWorkspaceRemoval = 'jj.undo_workspace_removal';

  /// A colocating conversion created the repo inside a linked git worktree,
  /// where a workspace of the main repository was probably meant.
  static const colocatedInGitWorktree = 'jj.colocated_in_git_worktree';

  /// `workspaceRoot` named a workspace whose recorded directory does not exist;
  /// the recorded path is returned anyway.
  static const workspacePathInaccessible = 'jj.workspace_path_inaccessible';

  /// `workspaceAdd` was given a destination without a path separator, so the
  /// workspace was created inside the current one (Story 9.23).
  static const workspaceInCurrentDirectory = 'jj.workspace_in_current_directory';

  /// `split` selected every change of the target, so the remaining commit is
  /// empty; the split still ran (Story 9.15).
  static const splitAllSelected = 'jj.split_all_selected';

  /// `split` selected no change of the target, so the selected commit is
  /// empty; the split still ran (Story 9.15).
  static const splitNoneSelected = 'jj.split_none_selected';

  /// `commit`'s paths select no change of `@`, so the committed `@` is empty
  /// and the new `@` holds every change; the commit still ran (Story 9.49).
  static const commitPathsUnmatched = 'jj.commit_paths_unmatched';

  /// `gitPush` named `remotes` that match no configured remote ("No matching remotes for names: …"); the push goes on with the rest (Story 9.20).
  static const pushRemotesUnmatched = 'jj.push_remotes_unmatched';

  /// `gitPush`'s `bookmarks` names match no bookmark on a remote (Story 9.20).
  static const pushBookmarksUnmatched = 'jj.push_bookmarks_unmatched';

  /// `gitPush`'s `tags` names match no tag on a remote (Story 9.20).
  static const pushTagsUnmatched = 'jj.push_tags_unmatched';

  /// The bare `gitPush` found no bookmark or tag in `revsets.git-push` for a remote (Story 9.20).
  static const pushRevsetEmpty = 'jj.push_revset_empty';

  /// `gitPush`'s `revisions` point at no bookmark or tag (Story 9.20).
  static const pushRevisionsEmpty = 'jj.push_revisions_empty';

  /// A skipping `gitPush` mode refused a ref and left it out; its row carries the refusal (Story 9.20).
  static const pushRefSkipped = 'jj.push_ref_skipped';

  /// A skipping `gitPush` mode left a ref out because its commit is not ready; its row carries the rejection (Story 9.20).
  static const pushCommitSkipped = 'jj.push_commit_skipped';

  /// `gitPush`: refs moved on the remote since the last fetch, so their lease failed (Story 9.20).
  static const pushRefsMovedOnRemote = 'jj.push_refs_moved_on_remote';

  /// `gitPush`: the remote rejected updates, e.g. in a hook (Story 9.20).
  static const pushRemoteRejected = 'jj.push_remote_rejected';

  /// `gitPush` pushed bookmarks whose remote-tracking refs could not be updated locally (Story 9.20).
  static const pushBookmarksNotUpdatedLocally = 'jj.push_bookmarks_not_updated_locally';

  /// `git.sign-on-push` left immutable commits unsigned (Story 9.20).
  static const pushSigningSkippedImmutable = 'jj.push_signing_skipped_immutable';

  /// `cloneRepo`'s exact `branches` names match no branch on the remote (Story 9.20).
  static const cloneBranchesUnmatched = 'jj.clone_branches_unmatched';

  /// The login shell's environment could not be read at start-up; the
  /// environment Zanshin was started with stays in effect (Story 9.36). The one
  /// Zanshin-only code — no jj CLI prints it — and the one built in Dart: it is
  /// never on an envelope, only in `adoptLoginShellEnvironment`'s result.
  static const loginShellUnresolved = 'env.login_shell_unresolved';

  /// Every constant above, in registry order.
  static const List<String> values = [
    identityMissing,
    workingCopyImmutable,
    jjconflictFilesPresent,
    gitHeadUpdateFailed,
    gitExportFailed,
    gitImportFailed,
    snapshotFilesRefused,
    snapshotPathsNotUtf8,
    checkoutFilesSkipped,
    pathsUnmatched,
    configAliasInvalid,
    configAliasRedefined,
    revsetDiagnostic,
    shortPrefixesFailed,
    remoteUrlDuplicate,
    bookmarkTargetEmpty,
    bookmarkNamesUnmatched,
    absorbPathSkipped,
    pathAccessDenied,
    pathNotAFile,
    configWorkingCopyAuthor,
    configGcDeleteFailed,
    configNothingListed,
    cloneCleanupFailed,
    configMigrated,
    configCopied,
    configRegenerated,
    undoPushOperation,
    undoWorkspaceRemoval,
    colocatedInGitWorktree,
    workspacePathInaccessible,
    workspaceInCurrentDirectory,
    splitAllSelected,
    splitNoneSelected,
    commitPathsUnmatched,
    pushRemotesUnmatched,
    pushBookmarksUnmatched,
    pushTagsUnmatched,
    pushRevsetEmpty,
    pushRevisionsEmpty,
    pushRefSkipped,
    pushCommitSkipped,
    pushRefsMovedOnRemote,
    pushRemoteRejected,
    pushBookmarksNotUpdatedLocally,
    pushSigningSkippedImmutable,
    cloneBranchesUnmatched,
    loginShellUnresolved,
  ];
}

/// A list result that also carries the call's [warnings] (Story 9.32).
///
/// Returned by the commands whose result is a list (`opLog`, `bookmarks`,
/// `fileList`, `configList`, …): it IS the list — reads, iteration and
/// mutation go to the decoded elements exactly as before — so a caller that
/// only wants the elements keeps using it as a plain [List].
final class WarnedList<E> extends ListBase<E> {
  WarnedList(List<E> elements, this.warnings) : _elements = elements;

  final List<E> _elements;

  /// The call's warnings, in the CLI's print order; empty when there were none.
  final List<ZanshinWarning> warnings;

  @override
  int get length => _elements.length;

  @override
  set length(int newLength) => _elements.length = newLength;

  @override
  E operator [](int index) => _elements[index];

  @override
  void operator []=(int index, E value) => _elements[index] = value;

  @override
  void add(E element) => _elements.add(element);

  @override
  void addAll(Iterable<E> iterable) => _elements.addAll(iterable);
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode an envelope's `warnings` vector — the ONE helper every top-level
/// decoder calls (Story 9.32).
///
/// The vector is absent on the wire when a call has nothing to warn about; that
/// reads as an empty list. The returned list is unmodifiable and keeps the
/// wire order (the CLI's print order).
List<ZanshinWarning> decodeEnvelopeWarningsInternal(fbs.Envelope env) {
  final List<fbs.Warning>? warnings = env.warnings;
  if (warnings == null || warnings.isEmpty) {
    return const [];
  }
  return List.unmodifiable(warnings.map((w) => ZanshinWarning(code: w.code ?? '', message: w.message ?? '')));
}
