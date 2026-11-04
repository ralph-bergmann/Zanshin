// SPDX-License-Identifier: MIT
//! `FlatBuffers` `Envelope` builders, AR-P-4 error-code emission, and the `catch_unwind` panic backstop.
//!
//! Every pub ENVELOPE BUILDER returns a finished, owned `Vec<u8>`. Conversion to the FFI
//! `(*mut u8, len)` token happens at the `extern "C"` call site (Story 3.4a) via
//! `ffi_strings::vec_into_ffi_buf` / `vec_into_token`. The builders own nothing beyond
//! the build step; the one exception is `session_from_handle` below, which hands out a
//! borrow of caller-owned state and is why this module depends on `crate::handle` and
//! `crate::repo` at all.

use crate::envelope_generated::zanshin::ffi as fbs;
use crate::handle::handle_from_raw;
use crate::repo::RepoSession;
use flatbuffers::FlatBufferBuilder;
use std::any::Any;
use std::panic::{catch_unwind, UnwindSafe};

/// AR-P-4 single-emission-point: the canonical `catch_unwind` panic error code.
pub const INTERNAL_PANIC: &str = "internal.panic";

/// AR-P-4: emitted by `handle::validate_handle` when a Dart-supplied handle pointer is null.
pub const FFI_INVALID_HANDLE: &str = "ffi.invalid_handle";
/// AR-P-4: emitted by `ffi_strings::cstr_to_string` when a required `*const c_char` is null.
pub const FFI_NULL_POINTER: &str = "ffi.null_pointer";
/// AR-P-4: emitted by `ffi_strings::cstr_to_string` when a `*const c_char` contains invalid UTF-8.
pub const FFI_UTF8_ERROR: &str = "ffi.utf8_error";
/// AR-P-4: emitted when a required argument value is out of the accepted range (e.g. unknown backend discriminant).
pub const FFI_INVALID_ARGUMENT: &str = "ffi.invalid_argument";

/// AR-P-4: emitted by `repo.rs` when a path argument does not exist on disk.
pub const JJ_PATH_NOT_FOUND: &str = "jj.path_not_found";
/// AR-P-4: emitted by `repo.rs` when no jj repo is found at the given path.
pub const JJ_REPO_NOT_FOUND: &str = "jj.repo_not_found";
/// AR-P-4: emitted by `repo.rs` and the read wrappers (`status.rs`, `change.rs`, `op_log.rs`,
/// `bookmarks.rs`, `remotes.rs`, `graph.rs`) for unclassified jj-lib errors; detail in `context`.
pub const JJ_JJ_LIB_ERROR: &str = "jj.jj_lib_error";
/// AR-P-4: emitted — since Story 9.22 — by `file_ops.rs`'s two wrappers when the working copy
/// they must lock has no `@` in the head view (the CLI's "Nothing checked out in this
/// workspace"), and through `repo.rs::map_mutate_err` by `zanshin_commit` (Story 9.49) and
/// `zanshin_workspace_add` (Story 9.23); no `context`.
pub const JJ_NO_WORKING_COPY: &str = "jj.no_working_copy";
/// AR-P-4: emitted by `file_ops.rs::zanshin_file_track`/`_untrack` when the working copy's
/// recorded tree differs from `@`'s tree — `@` rewritten without a checkout by a concurrent
/// writer between the pre-verb snapshot and the verb's own lock; no `context` (Story 9.22). The
/// CLI's "Concurrent working copy operation" check; its own code because the condition is
/// specific to the working copy.
pub const JJ_CONCURRENT_WORKING_COPY: &str = "jj.concurrent_working_copy";
/// AR-P-4: emitted by EVERY wrapper whose verb runs the pre-verb snapshot (Story 9.26) when the
/// working copy is stale — the CLI's `handle_stale_working_copy` refusals. `context` is
/// `"<cause>\n<working_copy_op_id>\n<repo_op_id>\n<message>"` (full hex ids), `cause` one of
/// `stale`, `sibling_operation`, `operation_not_found`, `message` the CLI's error text without
/// its `Error: ` / `Internal error: ` label. Nothing is snapshotted or written.
pub const JJ_STALE_WORKING_COPY: &str = "jj.stale_working_copy";
/// AR-P-4: emitted by `file_ops.rs::zanshin_file_untrack` when matched paths are NOT ignored, so
/// the next snapshot would add them straight back; EVERY offending path in `context`, joined
/// by `\n`, in jj-lib's tree order (Story 9.22). No operation is written. Its own code because
/// the remedy is specific: ignore the paths first, then retry.
pub const JJ_PATH_NOT_IGNORED: &str = "jj.path_not_ignored";
/// AR-P-4: emitted by `change.rs` when no change exists for the given id.
pub const JJ_CHANGE_NOT_FOUND: &str = "jj.change_not_found";
/// AR-P-4: emitted by `commit_contents.rs::zanshin_commit_contents` (Story 4.10) when the
/// pinned operation is not in the operation store (abandoned and garbage-collected); `context`
/// is the CLI's `No operation ID matching "<id>"`. Unrelated to the `operation_not_found` CAUSE
/// inside [`JJ_STALE_WORKING_COPY`]'s context.
pub const JJ_OPERATION_NOT_FOUND: &str = "jj.operation_not_found";
/// AR-P-4: emitted by `file.rs::zanshin_file_annotate` when the path exists in the target
/// revision's tree but is not a regular file (a directory, a symlink, a Git submodule, or a
/// conflict with a non-file side); the repo-relative path in `context`. Distinct from
/// `jj.path_not_found`, which means the path is not there at all — a GUI must be able to
/// tell "you selected a directory" from "you mistyped the path".
pub const JJ_NOT_A_FILE: &str = "jj.not_a_file";
/// AR-P-4: emitted by `repo.rs` (the mutation wrappers) when the caller's arguments are
/// structurally invalid for the mutation (e.g. an empty `parents`/`change_ids` list).
pub const JJ_INVALID_INPUT: &str = "jj.invalid_input";
/// AR-P-4: emitted by `repo.rs` (the rewriting mutation wrappers) when the target is inside
/// the repo's effective immutable set `::(immutable_heads() | root())`; the offending hex
/// commit id in `context`. No operation is committed.
pub const JJ_IMMUTABLE: &str = "jj.immutable";
/// AR-P-4: emitted by `repo.rs::zanshin_undo` when the operation to undo is the op-store
/// root — there is no parent operation to restore to.
pub const JJ_NOTHING_TO_UNDO: &str = "jj.nothing_to_undo";
/// AR-P-4: emitted by `repo.rs::zanshin_undo` when the operation to undo was performed in another
/// workspace and `allow_cross_workspace` is false (jj 0.46, Story 9.39); `context` is
/// `"<operation>\n<workspace>"` — the 12-digit short operation id, then the workspace name.
pub const JJ_UNDO_CROSS_WORKSPACE: &str = "jj.undo_cross_workspace";
/// AR-P-4: emitted by `repo.rs::zanshin_redo` when the head is no undo operation (nor a redo of
/// one) — the CLI's "Nothing to redo" in `context` (Story 9.21). Nothing is written.
pub const JJ_NOTHING_TO_REDO: &str = "jj.nothing_to_redo";
/// AR-P-4: emitted by `repo.rs::zanshin_redo` when the undo operation to redo was performed in
/// another workspace and `allow_cross_workspace` is false (Story 9.21); `context` is
/// `"<operation>\n<workspace>"` — the 12-digit short operation id, then the workspace name.
pub const JJ_REDO_CROSS_WORKSPACE: &str = "jj.redo_cross_workspace";
/// AR-P-4: emitted by `repo.rs::zanshin_git_fetch` when `remote_name` has no configured git
/// remote (a workspace with NO git backend is `jj.not_a_git_repo` instead); and — since Story
/// 9.5 — by `git.rs::zanshin_git_remote_remove`/`_rename`/`_set_url` when the named remote does
/// not exist (for `rename`, the OLD name; for `set_url`, only when at least one URL was given).
pub const JJ_REMOTE_NOT_FOUND: &str = "jj.remote_not_found";
/// AR-P-4: emitted by `git.rs::zanshin_git_remote_add` when the name already has a
/// configured git remote, and by `zanshin_git_remote_rename` when the NEW name does; the
/// offending remote name in `context` (Story 9.5).
///
/// Its own code rather than `jj.invalid_input` because the remedy differs: the remote is
/// already there — re-point it with `zanshin_git_remote_set_url` instead of adding it again.
pub const JJ_REMOTE_EXISTS: &str = "jj.remote_exists";
/// AR-P-4: emitted by `git.rs::zanshin_git_remote_remove`/`_rename` when jj refuses to
/// rewrite the remote's git config — it carries a key outside `url`/`fetch`/`tagOpt`, or a
/// `[branch]` section referencing it carries one outside `remote`/`merge`/`rebase`; the
/// remote name in `context` (Story 9.5).
///
/// Not exotic: jj-lib's own `save_remote` writes a `pushurl` key, so a remote ADDED with a
/// push URL cannot afterwards be removed. The only remedy is editing the git config by
/// hand, which no code in this workspace offers — hence its own code rather than the
/// unclassified `jj.jj_lib_error`.
pub const JJ_REMOTE_NONSTANDARD_CONFIG: &str = "jj.remote_nonstandard_config";
/// AR-P-4: emitted by `bookmark_ops.rs::zanshin_bookmark_create` when a requested name is
/// already a LOCAL bookmark; the offending name in `context` (Story 9.8). Nothing is created
/// — not even the names before it — and no operation is written.
///
/// Its own code rather than `jj.invalid_input` because the remedy is specific: the bookmark
/// is already there, so MOVE it (`bookmark set`, Story 9.11) instead of creating it again.
pub const JJ_BOOKMARK_EXISTS: &str = "jj.bookmark_exists";
/// AR-P-4: emitted by `bookmark_ops.rs::zanshin_bookmark_create` when a requested name has no
/// local bookmark but still has at least one TRACKED remote bookmark — the deleted-but-not-
/// yet-pushed state; the offending name in `context` (Story 9.8).
///
/// Kept DISTINCT from `jj.bookmark_exists` because the remedies differ, which is exactly what
/// the CLI's two separate hints say: recreate the local bookmark with `bookmark set`, or
/// disassociate the remote with `bookmark untrack`. On a GIT-backed repo the default-ignored
/// remote `git` is excluded, so a colocated `name@git` never produces this code there; that
/// exclusion is git-specific, so on any other backend a tracked `name@git` does produce it.
pub const JJ_BOOKMARK_TRACKED_REMOTE_EXISTS: &str = "jj.bookmark_tracked_remote_exists";
/// AR-P-4: emitted by `workspace.rs::zanshin_workspace_root` when no workspace of the requested
/// name exists in the head view; the name in `context` (Story 9.7).
///
/// Its own code rather than `jj.invalid_input` because the remedy is specific: pick a different
/// workspace — `zanshin_workspace_list` names them all.
pub const JJ_WORKSPACE_NOT_FOUND: &str = "jj.workspace_not_found";
/// AR-P-4: emitted by `workspace.rs::zanshin_workspace_root` when the workspace EXISTS but the
/// workspace store holds no path for it; the name in `context` (Story 9.7). Workspaces created
/// before jj 0.38.0 have no recorded path at all, so the answer is simply unavailable. (A path
/// that IS recorded but does not exist is no error since jj 0.46: it is returned with the
/// `jj.workspace_path_inaccessible` warning.)
pub const JJ_WORKSPACE_NO_RECORDED_PATH: &str = "jj.workspace_no_recorded_path";
/// AR-P-4: emitted by `workspace.rs::zanshin_workspace_add` when a workspace of the requested
/// name already exists; the name in `context` (Story 9.23). Nothing is created.
pub const JJ_WORKSPACE_EXISTS: &str = "jj.workspace_exists";
/// AR-P-4: emitted by `workspace.rs::zanshin_workspace_add` when the destination is a file or a
/// non-empty directory (Story 9.23), and since Story 9.20 by `repo.rs::zanshin_repo_clone` for the
/// same condition (the destination in `context`). Nothing is created.
pub const JJ_DESTINATION_NOT_EMPTY: &str = "jj.destination_not_empty";
/// AR-P-4: emitted by `repo.rs::zanshin_repo_init` with `--no-colocate` over a directory that
/// holds `.git/` — the CLI's "Did not create a jj repo because there is an existing Git repo in
/// this directory." (Story 9.20); the path in `context`. Nothing is created.
pub const JJ_GIT_REPO_EXISTS: &str = "jj.git_repo_exists";
/// AR-P-4: emitted by `push.rs::zanshin_git_push` when an explicitly named ref (`-b`, `-t`,
/// `--change`, `--named`) is refused — conflicted, untracked on the remote, new or deleted where
/// that is not allowed (Story 9.20); the CLI's message in `context`. Nothing is pushed or
/// written.
pub const JJ_PUSH_REF_REFUSED: &str = "jj.push_ref_refused";
/// AR-P-4: emitted by `push.rs::zanshin_git_push` when an explicitly named ref would push a commit
/// that is not ready — no description, no author/committer, conflicts, private (Story 9.20); the
/// CLI's "Won't push commit <hash> since it <reasons>" in `context`. Nothing is pushed or written.
pub const JJ_PUSH_COMMIT_REJECTED: &str = "jj.push_commit_rejected";
/// AR-P-4: emitted by `select_tree.rs::zanshin_select_tree` and the tree arms of
/// `zanshin_commit` / `zanshin_split` / `zanshin_squash` / `zanshin_squash_plan` when a GUI hunk
/// selection no longer fits the revision — its `left` is not the revision's parent tree any more,
/// or a key is not a current section of its file (Story 9.50); what no longer fits in `context`.
/// Nothing is written. The remedy: re-read the diff, re-map the selection, select again.
pub const JJ_STALE_SELECTION: &str = "jj.stale_selection";
/// AR-P-4: emitted by `resolve.rs::zanshin_resolve_list` and `zanshin_resolve` when no conflict
/// matches — the CLI's "No conflicts found at this revision" / "No conflicts found at the given
/// path(s)" in `context` (Story 9.17). Nothing is written.
pub const JJ_NO_CONFLICTS: &str = "jj.no_conflicts";
/// AR-P-4: emitted by `resolve.rs::zanshin_resolve` when a conflict is not one a 3-way merge tool
/// can take — not only normal files, more than two sides, or a conflict in the executable bit; the
/// CLI's text in `context` (Story 9.17). Nothing is written.
pub const JJ_CONFLICT_NOT_RESOLVABLE: &str = "jj.conflict_not_resolvable";
/// AR-P-4: emitted by `workspace.rs::zanshin_workspace_add` when the new workspace's Git worktree
/// could not be created — a workspace without a Git backend, or a failing `git`; jj-lib's text in
/// `context` (Story 9.23). The destination directory created before stays, as in the CLI.
pub const JJ_GIT_WORKTREE_FAILED: &str = "jj.git_worktree_failed";
/// AR-P-4: emitted by `repo.rs::zanshin_git_fetch` when the underlying `git` subprocess
/// fails (network, authentication, or transport error); detail in `context`. Also emitted by
/// `repo.rs::zanshin_repo_clone` when its fetch's `git` subprocess fails (Story 9.20 closing run,
/// `map_repo_err`). (`zanshin_git_push` reports such a failure as data — `GitPushResult.failure`.)
pub const JJ_NETWORK_ERROR: &str = "jj.network_error";
/// AR-P-4: emitted by `repo.rs::zanshin_git_fetch` and `repo.rs::zanshin_repo_clone` when the
/// call's cancel token was cancelled through `zanshin_network_cancel` (Story 9.52): the verb
/// refused at a checkpoint, or its `git` failed after the cancel killed it. `context` is
/// "Cancelled". A call without a token never emits it; `zanshin_git_push` reports a cancel as
/// data (`GitPushResult.failure.kind = Cancelled`).
pub const JJ_CANCELLED: &str = "jj.cancelled";
/// AR-P-4: emitted by `repo.rs` when a filesystem I/O error (e.g. EACCES, ENOTDIR) prevented repo-kind classification.
pub const JJ_DETECT_FAILED: &str = "jj.detect_failed";
/// AR-P-4: emitted by `repo.rs` when the path is already a jj workspace (`.jj/` present); convert skipped.
pub const JJ_ALREADY_JJ_REPO: &str = "jj.already_jj_repo";
/// AR-P-4: emitted by `repo.rs` when the path is not a Git repository or does not exist; convert refused.
/// Since Story 9.5 the meaning is WIDENED: `git.rs`'s six wrappers emit it when the OPEN
/// WORKSPACE has no git backend at all (jj-lib's `UnexpectedGitBackendError`), which has no
/// path to name and therefore carries no `context`. Since the Epic 9 git-sync follow-up
/// `repo.rs::zanshin_git_fetch` emits it for that same condition, which it used to report
/// as `jj.remote_not_found`.
pub const JJ_NOT_A_GIT_REPO: &str = "jj.not_a_git_repo";
/// AR-P-4: emitted by `repo.rs` when a jj-lib failure occurred during colocated conversion; detail in `context`.
pub const JJ_CONVERT_FAILED: &str = "jj.convert_failed";
/// AR-P-4: emitted by `graph.rs` when a revset or prioritize expression is syntactically invalid
/// or names an unknown function; jj-lib's reason in `context`.
pub const JJ_REVSET_PARSE_ERROR: &str = "jj.revset_parse_error";
/// AR-P-4: emitted by `graph.rs` when a revset or prioritize expression is well-formed but a
/// symbol cannot be resolved (unknown bookmark/tag, missing `@`, ambiguous id); reason in `context`.
pub const JJ_REVSET_RESOLUTION_ERROR: &str = "jj.revset_resolution_error";
/// AR-P-4: emitted by `log_defaults.rs` and `graph.rs` when the repo's effective jj config
/// cannot be read — a malformed/unreadable config file, a bad `config-id`, or a
/// wrong-typed config value; the offending file path or config key in `context`.
pub const JJ_CONFIG_ERROR: &str = "jj.config_error";
/// AR-P-4: emitted by `config.rs::zanshin_config_get` when no layer sets the name ("Value not
/// found for <name>") and by `zanshin_config_unset` when the file does not hold it (`"<name>"
/// doesn't exist`); the CLI's message in `context` (Story 9.28).
pub const JJ_CONFIG_NOT_FOUND: &str = "jj.config_not_found";
/// AR-P-4: emitted by `config.rs::zanshin_config_set` when the write would overwrite a whole
/// table, or a non-table value with a parent table; jj-lib's reason in `context`, nothing
/// written (Story 9.28).
pub const JJ_CONFIG_WOULD_OVERWRITE: &str = "jj.config_would_overwrite";
/// AR-P-4: emitted by `config.rs::zanshin_config_unset` when the name is a whole table; jj-lib's
/// reason in `context`, nothing written (Story 9.28). Its own code because the remedy differs:
/// unset the table's values, or edit the file.
pub const JJ_CONFIG_WOULD_DELETE_TABLE: &str = "jj.config_would_delete_table";
/// AR-P-4: emitted by `config.rs`'s `set` / `unset` / `file_read` / `file_write` wrappers when
/// the request's `path` (the CLI's `--file`, jj 0.45) is not a location jj recognizes as a
/// config file — the CLI's "Configuration file '…' is not a valid jj configuration file
/// location"; the resolved path in `context`, nothing written.
pub const JJ_CONFIG_UNRECOGNIZED_FILE: &str = "jj.config_unrecognized_file";
/// AR-P-4: emitted by `config.rs` when a config name, a `set` value or `file_write` text is not
/// valid TOML; `context` is `"<start>..<end>\n<message>"` when the parser reports a byte span,
/// else the message (Story 9.28). Nothing is written.
pub const JJ_CONFIG_PARSE_ERROR: &str = "jj.config_parse_error";
/// AR-P-4: emitted by `config.rs` when no file of the requested scope can be determined — the
/// CLI's "No user/repo/workspace config path found[ to edit]" and `gc`'s "No config directory
/// found"; the message in `context` (Story 9.28).
pub const JJ_CONFIG_PATH_NOT_FOUND: &str = "jj.config_path_not_found";
/// AR-P-4: emitted by `graph.rs` when the graph topology call (`zanshin_graph_topology`) finds a
/// Direct/Indirect edge whose target is outside its node set (upstream stream contract
/// violation); the dangling target in `context`.
pub const GRAPH_DANGLING_EDGE: &str = "graph.dangling_edge";
/// AR-P-4: emitted by `repo.rs` when arming the filesystem watcher fails during
/// open/init/clone/convert; detail in `context`. Story 3.5 → Reserved, Story 3.6 →
/// Emitted (single-emission-point: post-arm watch errors ride the event stream
/// as `WatcherEvent { kind: WatchError }`, never this code).
pub const WATCHER_IO_ERROR: &str = "watcher.io_error";

// ── Warning codes (Story 9.32) ───────────────────────────────────────────────
//
// The codes `Envelope.warnings` carries — one per `zanshin_jj::WarningKind`, registered in the
// "Warning Codes" section of `docs/rust-error-codes.md`. Same single-emission-point rule as the
// error codes: the strings exist only here, and [`warning_code`] is the one mapping.

/// Warning: an operation was committed with an empty `user.name` and/or `user.email`.
pub const JJ_IDENTITY_MISSING: &str = "jj.identity_missing";
/// Warning: `@` was immutable, so a new `@` was created on top of it (snapshot or finish).
pub const JJ_WORKING_COPY_IMMUTABLE: &str = "jj.working_copy_immutable";
/// Warning: a colocated snapshot found top-level `.jjconflict*` entries.
pub const JJ_JJCONFLICT_FILES_PRESENT: &str = "jj.jjconflict_files_present";
/// Warning: Git HEAD could not be moved to `@`'s parent.
pub const JJ_GIT_HEAD_UPDATE_FAILED: &str = "jj.git_head_update_failed";
/// Warning: bookmarks or tags the Git export could not write.
pub const JJ_GIT_EXPORT_FAILED: &str = "jj.git_export_failed";
/// Warning: Git refs the import could not read.
pub const JJ_GIT_IMPORT_FAILED: &str = "jj.git_import_failed";
/// Warning: new files over `snapshot.max-new-file-size` stayed untracked.
pub const JJ_SNAPSHOT_FILES_REFUSED: &str = "jj.snapshot_files_refused";
/// Warning: paths skipped because their names are not valid UTF-8.
pub const JJ_SNAPSHOT_PATHS_NOT_UTF8: &str = "jj.snapshot_paths_not_utf8";
/// Warning: working-copy updates skipped because of conflicting on-disk changes.
pub const JJ_CHECKOUT_FILES_SKIPPED: &str = "jj.checkout_files_skipped";
/// Warning: a checkout moved `@` onto a commit with conflicts; the message lists each conflicted
/// path (Story 9.53).
pub const JJ_UNRESOLVED_CONFLICTS: &str = "jj.unresolved_conflicts";
/// Warning: explicitly named paths that match no entry.
pub const JJ_PATHS_UNMATCHED: &str = "jj.paths_unmatched";
/// Warning: a `[revset-aliases]` / `[fileset-aliases]` entry that does not load.
pub const JJ_CONFIG_ALIAS_INVALID: &str = "jj.config_alias_invalid";
/// Warning: a config layer redefines `mutable()`, `immutable()` or `builtin_immutable_heads()`.
pub const JJ_CONFIG_ALIAS_REDEFINED: &str = "jj.config_alias_redefined";
/// Warning: a revset parsed with a diagnostic.
pub const JJ_REVSET_DIAGNOSTIC: &str = "jj.revset_diagnostic";
/// Warning: the short-prefixes disambiguation index could not be loaded.
pub const JJ_SHORT_PREFIXES_FAILED: &str = "jj.short_prefixes_failed";
/// Warning: another remote already uses the URL just added.
pub const JJ_REMOTE_URL_DUPLICATE: &str = "jj.remote_url_duplicate";
/// Warning: a bookmark was created on an empty, undescribed revision.
pub const JJ_BOOKMARK_TARGET_EMPTY: &str = "jj.bookmark_target_empty";
/// Warning: exact names given to `bookmark delete` / `move` / `advance` that match no local
/// bookmark, or to `bookmark list` that match no local or remote bookmark.
pub const JJ_BOOKMARK_NAMES_UNMATCHED: &str = "jj.bookmark_names_unmatched";
/// Warning: `bookmark create` auto-tracked a remote bookmark that already exists on the remote.
pub const JJ_BOOKMARK_AUTO_TRACK_EXISTING: &str = "jj.bookmark_auto_track_existing";
/// Warning: `bookmark rename` dropped the tracking of a remote where the new name already exists
/// untracked (Story 9.19).
pub const JJ_BOOKMARK_RENAME_REMOTE_EXISTS: &str = "jj.bookmark_rename_remote_exists";
/// Warning: `bookmark rename --overwrite-existing` untracked a remote bookmark of the overwritten
/// name (Story 9.19).
pub const JJ_BOOKMARK_TRACKING_DROPPED: &str = "jj.bookmark_tracking_dropped";
/// Warning: `bookmark rename` left the old name's tracked remote bookmarks unrenamed (Story 9.19).
pub const JJ_BOOKMARK_REMOTES_NOT_RENAMED: &str = "jj.bookmark_remotes_not_renamed";
/// Warning: `bookmark rename` onto a name with tracked remote bookmarks (Story 9.19).
pub const JJ_BOOKMARK_TRACKED_REMOTES_EXIST: &str = "jj.bookmark_tracked_remotes_exist";
/// Warning: `bookmark track` / `untrack` symbols that name no trackable remote bookmark (Story
/// 9.11).
pub const JJ_REMOTE_BOOKMARKS_UNMATCHED: &str = "jj.remote_bookmarks_unmatched";
/// Warning: exact `--remote` names given to `bookmark track` / `untrack` that match no remote
/// (Story 9.11).
pub const JJ_BOOKMARK_REMOTES_UNMATCHED: &str = "jj.bookmark_remotes_unmatched";
/// Warning: `bookmark track` of an already tracked remote bookmark (Story 9.11).
pub const JJ_BOOKMARK_ALREADY_TRACKED: &str = "jj.bookmark_already_tracked";
/// Warning: `bookmark untrack` of a remote bookmark that is not tracked (Story 9.11).
pub const JJ_BOOKMARK_NOT_TRACKED: &str = "jj.bookmark_not_tracked";
/// Warning: `bookmark untrack` of a bookmark on the Git-tracking remote `git` (Story 9.11).
pub const JJ_BOOKMARK_GIT_TRACKING_UNTRACK: &str = "jj.bookmark_git_tracking_untrack";
/// Warning: a path `absorb` could not split.
pub const JJ_ABSORB_PATH_SKIPPED: &str = "jj.absorb_path_skipped";
/// Warning: a path whose content could not be read.
pub const JJ_PATH_ACCESS_DENIED: &str = "jj.path_access_denied";
/// Warning: a path that exists but is not a file.
pub const JJ_PATH_NOT_A_FILE: &str = "jj.path_not_a_file";
/// Warning: `user.name`/`user.email` was set but `@`'s author stays the old one.
pub const JJ_CONFIG_WORKING_COPY_AUTHOR: &str = "jj.config_working_copy_author";
/// Warning: a missing repo or workspace config directory could not be deleted.
pub const JJ_CONFIG_GC_DELETE_FAILED: &str = "jj.config_gc_delete_failed";
/// Warning: `config list` found nothing to list.
pub const JJ_CONFIG_NOTHING_LISTED: &str = "jj.config_nothing_listed";
/// Warning: a failed clone could not remove what it had created (Story 9.33).
pub const JJ_CLONE_CLEANUP_FAILED: &str = "jj.clone_cleanup_failed";
/// Warning: a legacy repo/workspace config file was migrated into the secure config directory
/// at command start (Story 9.37).
pub const JJ_CONFIG_MIGRATED: &str = "jj.config_migrated";
/// Warning: the repo/workspace was copied, so its secure config was forked under a new id at
/// command start (Story 9.37).
pub const JJ_CONFIG_COPIED: &str = "jj.config_copied";
/// Warning: the secure config directory was missing and was regenerated empty at command start
/// (Story 9.37).
pub const JJ_CONFIG_REGENERATED: &str = "jj.config_regenerated";
/// Warning: `undo` undid a `jj git push` operation, which often leaves conflicted bookmarks
/// (Story 9.39).
pub const JJ_UNDO_PUSH_OPERATION: &str = "jj.undo_push_operation";
/// Warning: `undo` undid a workspace removal — the workspace is back, its directory is not
/// (Story 9.39).
pub const JJ_UNDO_WORKSPACE_REMOVAL: &str = "jj.undo_workspace_removal";
/// Warning: a colocating conversion created the repo inside a linked git worktree.
pub const JJ_COLOCATED_IN_GIT_WORKTREE: &str = "jj.colocated_in_git_worktree";
/// Warning: `zanshin_workspace_root` returned a recorded path whose directory does not exist.
pub const JJ_WORKSPACE_PATH_INACCESSIBLE: &str = "jj.workspace_path_inaccessible";
/// Warning: `zanshin_workspace_add` created the workspace inside the current one (a destination
/// without a path separator).
pub const JJ_WORKSPACE_IN_CURRENT_DIRECTORY: &str = "jj.workspace_in_current_directory";
/// Warning: `workspace forget` / `remove` names no workspace of the view has (Story 9.13).
pub const JJ_WORKSPACE_NAMES_UNMATCHED: &str = "jj.workspace_names_unmatched";
/// Warning: `workspace forget` / `remove` could not unlink a Git worktree (Story 9.13).
pub const JJ_GIT_WORKTREE_UNLINK_FAILED: &str = "jj.git_worktree_unlink_failed";
/// Warning: `workspace remove` could not delete a workspace directory (Story 9.13).
pub const JJ_WORKSPACE_DIRECTORY_REMOVE_FAILED: &str = "jj.workspace_directory_remove_failed";
/// Warning: `zanshin_split` selected every change, so the remaining commit is empty (Story 9.15).
pub const JJ_SPLIT_ALL_SELECTED: &str = "jj.split_all_selected";
/// Warning: `zanshin_split` selected no change, so the selected commit is empty (Story 9.15).
pub const JJ_SPLIT_NONE_SELECTED: &str = "jj.split_none_selected";
/// Warning: `zanshin_commit`'s paths select no change of `@`, so the committed `@` is empty
/// (Story 9.49).
pub const JJ_COMMIT_PATHS_UNMATCHED: &str = "jj.commit_paths_unmatched";
/// Warning: `zanshin_git_push`'s exact `--remote` names that match no git remote (Story 9.20).
pub const JJ_PUSH_REMOTES_UNMATCHED: &str = "jj.push_remotes_unmatched";
/// Warning: `zanshin_git_push`'s exact `-b` names that match no bookmark to push (Story 9.20).
pub const JJ_PUSH_BOOKMARKS_UNMATCHED: &str = "jj.push_bookmarks_unmatched";
/// Warning: `zanshin_git_push`'s exact `-t` names that match no tag to push (Story 9.20).
pub const JJ_PUSH_TAGS_UNMATCHED: &str = "jj.push_tags_unmatched";
/// Warning: the bare `zanshin_git_push` found no bookmark or tag in `revsets.git-push` for a remote (Story 9.20).
pub const JJ_PUSH_REVSET_EMPTY: &str = "jj.push_revset_empty";
/// Warning: a `zanshin_git_push` `-r` revision no bookmark or tag points to (Story 9.20).
pub const JJ_PUSH_REVISIONS_EMPTY: &str = "jj.push_revisions_empty";
/// Warning: a ref `zanshin_git_push`'s mode refused and skipped (Story 9.20); an explicitly named ref refuses the push instead ([`JJ_PUSH_REF_REFUSED`]).
pub const JJ_PUSH_REF_SKIPPED: &str = "jj.push_ref_skipped";
/// Warning: a ref `zanshin_git_push` skipped because a commit it would push is not ready (Story 9.20); an explicitly named ref refuses the push instead ([`JJ_PUSH_COMMIT_REJECTED`]).
pub const JJ_PUSH_COMMIT_SKIPPED: &str = "jj.push_commit_skipped";
/// Warning: refs the remote had moved since the last fetch, so `zanshin_git_push`'s lease failed (Story 9.20).
pub const JJ_PUSH_REFS_MOVED_ON_REMOTE: &str = "jj.push_refs_moved_on_remote";
/// Warning: updates the remote rejected during `zanshin_git_push` (Story 9.20).
pub const JJ_PUSH_REMOTE_REJECTED: &str = "jj.push_remote_rejected";
/// Warning: sign-on-push left immutable commits unsigned (Story 9.20).
pub const JJ_PUSH_SIGNING_SKIPPED_IMMUTABLE: &str = "jj.push_signing_skipped_immutable";
/// Warning: `zanshin_repo_clone`'s exact `-b` names the remote does not have (Story 9.20).
pub const JJ_CLONE_BRANCHES_UNMATCHED: &str = "jj.clone_branches_unmatched";
/// Warning: a template a verb renders (`templates.commit_trailers`, `draft_commit_description`, `new_description`, `git_push_bookmark`) parsed with a diagnostic; it still renders (Story 9.51).
pub const JJ_TEMPLATE_DIAGNOSTIC: &str = "jj.template_diagnostic";
/// Warning: `zanshin_git_fetch`'s exact `--remote` / `git.fetch` names (or the implicit `origin`)
/// that match no git remote (Story 9.30); `zanshin_git_fetch_remotes` warns it as the fetch does.
pub const JJ_FETCH_REMOTES_UNMATCHED: &str = "jj.fetch_remotes_unmatched";
/// Warning: a fetch refspec of a remote's Git config that `zanshin_git_fetch` ignores (Story 9.30).
pub const JJ_FETCH_REFSPEC_IGNORED: &str = "jj.fetch_refspec_ignored";
/// Warning: `zanshin_git_fetch`'s exact `-b` names no matched remote has (Story 9.30).
pub const JJ_FETCH_BRANCHES_UNMATCHED: &str = "jj.fetch_branches_unmatched";
/// Warning: the `trunk()` alias does not resolve at the start of the call, which runs with
/// `trunk()` = `root()` (Story 9.56) — every verb that runs the pre-verb snapshot.
pub const JJ_TRUNK_ALIAS_UNRESOLVED: &str = "jj.trunk_alias_unresolved";
/// Warning: `zanshin_duplicate` duplicated a commit as a descendant of itself (Story 9.9).
pub const JJ_DUPLICATE_AS_OWN_DESCENDANT: &str = "jj.duplicate_as_own_descendant";
/// Warning: `zanshin_duplicate` duplicated a commit as an ancestor of itself (Story 9.9).
pub const JJ_DUPLICATE_AS_OWN_ANCESTOR: &str = "jj.duplicate_as_own_ancestor";
/// Warning: `zanshin_fix` could not start a configured tool; it is skipped (Story 9.9).
pub const JJ_FIX_TOOL_START_FAILED: &str = "jj.fix_tool_start_failed";
/// Warning: a `zanshin_fix` tool exited non-zero for a file; its output is discarded (Story 9.9).
pub const JJ_FIX_TOOL_FAILED: &str = "jj.fix_tool_failed";
/// Warning: a `zanshin_fix` tool overran its `fix.tools.<name>.timeout`; it was killed and its
/// output discarded (loop 9.9–9.12 second follow-on).
pub const JJ_FIX_TOOL_TIMED_OUT: &str = "jj.fix_tool_timed_out";
/// Warning: a `fix.tools.<name>.patterns` fileset parsed with a diagnostic (Story 9.9).
pub const JJ_FILESET_DIAGNOSTIC: &str = "jj.fileset_diagnostic";
/// Warning: a config layer uses a deprecated key the CLI migrates at start-up (Story 9.9) — every
/// verb that runs the pre-verb snapshot, and the config verbs.
pub const JJ_CONFIG_DEPRECATED: &str = "jj.config_deprecated";
/// Warning: `zanshin_op_show` / `zanshin_op_diff` could not resolve `show_changes_in`, so the
/// diff has no commit section (Story 9.21).
pub const JJ_OP_DIFF_CHANGES_UNRESOLVED: &str = "jj.op_diff_changes_unresolved";
/// Warning: `zanshin_op_abandon` rewrote the op heads but left this workspace's working copy,
/// which is recorded at an operation that is not a head (Story 9.21).
pub const JJ_OP_ABANDON_WORKING_COPY_NOT_UPDATED: &str = "jj.op_abandon_working_copy_not_updated";
/// Warning: the finished operation's view no longer has this workspace's working-copy commit
/// (e.g. `zanshin_op_restore` of the root operation); the working copy was left (Story 9.12).
pub const JJ_WORKSPACE_NO_LONGER_EXISTS: &str = "jj.workspace_no_longer_exists";
/// Warning: `zanshin_resolve` left conflicts in a revision that is not this workspace's `@`; the
/// message lists them (Story 9.17).
pub const JJ_RESOLVE_CONFLICTS_REMAIN: &str = "jj.resolve_conflicts_remain";

/// The registered code of a warning kind (Story 9.32) — the one mapping from
/// `zanshin_jj::WarningKind` to the wire, exhaustive so a new kind cannot ship without a code.
#[must_use]
pub fn warning_code(kind: zanshin_jj::WarningKind) -> &'static str {
    use zanshin_jj::WarningKind as K;
    match kind {
        K::IdentityMissing => JJ_IDENTITY_MISSING,
        K::WorkingCopyImmutable => JJ_WORKING_COPY_IMMUTABLE,
        K::JjconflictFilesPresent => JJ_JJCONFLICT_FILES_PRESENT,
        K::GitHeadUpdateFailed => JJ_GIT_HEAD_UPDATE_FAILED,
        K::GitExportFailed => JJ_GIT_EXPORT_FAILED,
        K::GitImportFailed => JJ_GIT_IMPORT_FAILED,
        K::SnapshotFilesRefused => JJ_SNAPSHOT_FILES_REFUSED,
        K::SnapshotPathsNotUtf8 => JJ_SNAPSHOT_PATHS_NOT_UTF8,
        K::CheckoutFilesSkipped => JJ_CHECKOUT_FILES_SKIPPED,
        K::UnresolvedConflicts => JJ_UNRESOLVED_CONFLICTS,
        K::PathsUnmatched => JJ_PATHS_UNMATCHED,
        K::ConfigAliasInvalid => JJ_CONFIG_ALIAS_INVALID,
        K::ConfigAliasRedefined => JJ_CONFIG_ALIAS_REDEFINED,
        K::RevsetDiagnostic => JJ_REVSET_DIAGNOSTIC,
        K::ShortPrefixesFailed => JJ_SHORT_PREFIXES_FAILED,
        K::RemoteUrlDuplicate => JJ_REMOTE_URL_DUPLICATE,
        K::BookmarkTargetEmpty => JJ_BOOKMARK_TARGET_EMPTY,
        K::BookmarkNamesUnmatched => JJ_BOOKMARK_NAMES_UNMATCHED,
        K::BookmarkAutoTrackExisting => JJ_BOOKMARK_AUTO_TRACK_EXISTING,
        K::BookmarkRenameRemoteExists => JJ_BOOKMARK_RENAME_REMOTE_EXISTS,
        K::BookmarkTrackingDropped => JJ_BOOKMARK_TRACKING_DROPPED,
        K::BookmarkRemotesNotRenamed => JJ_BOOKMARK_REMOTES_NOT_RENAMED,
        K::BookmarkTrackedRemotesExist => JJ_BOOKMARK_TRACKED_REMOTES_EXIST,
        K::RemoteBookmarksUnmatched => JJ_REMOTE_BOOKMARKS_UNMATCHED,
        K::BookmarkRemotesUnmatched => JJ_BOOKMARK_REMOTES_UNMATCHED,
        K::BookmarkAlreadyTracked => JJ_BOOKMARK_ALREADY_TRACKED,
        K::BookmarkNotTracked => JJ_BOOKMARK_NOT_TRACKED,
        K::BookmarkGitTrackingUntrack => JJ_BOOKMARK_GIT_TRACKING_UNTRACK,
        K::AbsorbPathSkipped => JJ_ABSORB_PATH_SKIPPED,
        K::PathAccessDenied => JJ_PATH_ACCESS_DENIED,
        K::PathNotAFile => JJ_PATH_NOT_A_FILE,
        K::ConfigWorkingCopyAuthor => JJ_CONFIG_WORKING_COPY_AUTHOR,
        K::ConfigGcDeleteFailed => JJ_CONFIG_GC_DELETE_FAILED,
        K::ConfigNothingListed => JJ_CONFIG_NOTHING_LISTED,
        K::CloneCleanupFailed => JJ_CLONE_CLEANUP_FAILED,
        K::ConfigMigrated => JJ_CONFIG_MIGRATED,
        K::ConfigCopied => JJ_CONFIG_COPIED,
        K::ConfigRegenerated => JJ_CONFIG_REGENERATED,
        K::UndoPushOperation => JJ_UNDO_PUSH_OPERATION,
        K::UndoWorkspaceRemoval => JJ_UNDO_WORKSPACE_REMOVAL,
        K::ColocatedInGitWorktree => JJ_COLOCATED_IN_GIT_WORKTREE,
        K::WorkspacePathInaccessible => JJ_WORKSPACE_PATH_INACCESSIBLE,
        K::WorkspaceInCurrentDirectory => JJ_WORKSPACE_IN_CURRENT_DIRECTORY,
        K::WorkspaceNamesUnmatched => JJ_WORKSPACE_NAMES_UNMATCHED,
        K::GitWorktreeUnlinkFailed => JJ_GIT_WORKTREE_UNLINK_FAILED,
        K::WorkspaceDirectoryRemoveFailed => JJ_WORKSPACE_DIRECTORY_REMOVE_FAILED,
        K::SplitAllSelected => JJ_SPLIT_ALL_SELECTED,
        K::SplitNoneSelected => JJ_SPLIT_NONE_SELECTED,
        K::CommitPathsUnmatched => JJ_COMMIT_PATHS_UNMATCHED,
        K::PushRemotesUnmatched => JJ_PUSH_REMOTES_UNMATCHED,
        K::PushBookmarksUnmatched => JJ_PUSH_BOOKMARKS_UNMATCHED,
        K::PushTagsUnmatched => JJ_PUSH_TAGS_UNMATCHED,
        K::PushRevsetEmpty => JJ_PUSH_REVSET_EMPTY,
        K::PushRevisionsEmpty => JJ_PUSH_REVISIONS_EMPTY,
        K::PushRefSkipped => JJ_PUSH_REF_SKIPPED,
        K::PushCommitSkipped => JJ_PUSH_COMMIT_SKIPPED,
        K::PushRefsMovedOnRemote => JJ_PUSH_REFS_MOVED_ON_REMOTE,
        K::PushRemoteRejected => JJ_PUSH_REMOTE_REJECTED,
        K::PushSigningSkippedImmutable => JJ_PUSH_SIGNING_SKIPPED_IMMUTABLE,
        K::CloneBranchesUnmatched => JJ_CLONE_BRANCHES_UNMATCHED,
        K::TemplateDiagnostic => JJ_TEMPLATE_DIAGNOSTIC,
        K::FetchRemotesUnmatched => JJ_FETCH_REMOTES_UNMATCHED,
        K::FetchRefspecIgnored => JJ_FETCH_REFSPEC_IGNORED,
        K::FetchBranchesUnmatched => JJ_FETCH_BRANCHES_UNMATCHED,
        K::TrunkAliasUnresolved => JJ_TRUNK_ALIAS_UNRESOLVED,
        K::DuplicateAsOwnDescendant => JJ_DUPLICATE_AS_OWN_DESCENDANT,
        K::DuplicateAsOwnAncestor => JJ_DUPLICATE_AS_OWN_ANCESTOR,
        K::FixToolStartFailed => JJ_FIX_TOOL_START_FAILED,
        K::FixToolFailed => JJ_FIX_TOOL_FAILED,
        K::FixToolTimedOut => JJ_FIX_TOOL_TIMED_OUT,
        K::FilesetDiagnostic => JJ_FILESET_DIAGNOSTIC,
        K::ConfigDeprecated => JJ_CONFIG_DEPRECATED,
        K::OpDiffChangesUnresolved => JJ_OP_DIFF_CHANGES_UNRESOLVED,
        K::OpAbandonWorkingCopyNotUpdated => JJ_OP_ABANDON_WORKING_COPY_NOT_UPDATED,
        K::WorkspaceNoLongerExists => JJ_WORKSPACE_NO_LONGER_EXISTS,
        K::ResolveConflictsRemain => JJ_RESOLVE_CONFLICTS_REMAIN,
    }
}

/// Pre-serialised, input-free `internal.panic` `Envelope` buffer.
///
/// Last-resort backstop for [`catch`]: returned only if building a normal error `Envelope`
/// *itself* panics (essentially unreachable — `err` builds a small in-memory buffer — but a
/// panic backstop must never unwind across the C ABI). These bytes are exactly
/// `err(INTERNAL_PANIC, None)`; the `panic_fallback_const_matches_builder` test keeps them in sync.
const PANIC_FALLBACK_ENVELOPE: &[u8] = &[
    12, 0, 0, 0, 8, 0, 10, 0, 0, 0, 4, 0, 8, 0, 0, 0, 12, 0, 0, 0, 0, 0, 6, 0, 8, 0, 4, 0, 6, 0, 0, 0, 4, 0, 0, 0, 14,
    0, 0, 0, 105, 110, 116, 101, 114, 110, 97, 108, 46, 112, 97, 110, 105, 99, 0, 0,
];

/// The call-level facts every verb envelope carries beside its payload or its error: the
/// (possibly partial) pre-verb snapshot report (Story 9.26) and the call's warnings in the CLI's
/// print order (Story 9.32), written as `Envelope.precondition` / `Envelope.warnings`, and what a
/// failed init or conversion left on disk (Stories 9.57/9.58), written as `FfiError.left_behind`
/// by the error writer only. The `Default` is a call with none — every field then stays ABSENT on
/// the wire.
#[derive(Debug, Default)]
pub struct CallReport {
    /// The pre-verb snapshot report; `None` for a symbol that runs no precondition.
    pub precondition: Option<zanshin_jj::Precondition>,
    /// The call's warnings; empty writes no `warnings` vector.
    pub warnings: Vec<zanshin_jj::Warning>,
    /// The paths a failed init or conversion created and left, outermost first; empty (every
    /// other call) writes no `left_behind` vector.
    pub left_behind: Vec<String>,
    /// The structured detail of a revset parse or resolution error (Story 9.25), written as
    /// `FfiError.revset` by the error writer only; `None` (no field) everywhere else.
    pub revset: Option<zanshin_jj::RevsetErrorDetail>,
}

impl CallReport {
    /// The report of a handle-less verb, which runs no precondition: only its warnings.
    #[must_use]
    pub fn warnings(warnings: Vec<zanshin_jj::Warning>) -> Self {
        Self {
            warnings,
            ..Self::default()
        }
    }

    /// Takes what the last verb left on `repo`: its precondition report and its warnings.
    pub fn take(repo: &mut zanshin_jj::Repo) -> Self {
        Self {
            precondition: repo.take_precondition(),
            warnings: repo.take_warnings(),
            left_behind: Vec::new(),
            revset: None,
        }
    }

    /// The report of an error that carries only a revset error's detail (Story 9.25).
    #[must_use]
    pub fn revset(detail: zanshin_jj::RevsetErrorDetail) -> Self {
        Self {
            revset: Some(detail),
            ..Self::default()
        }
    }
}

/// Rust-side mirror of the `FlatBuffers` `FfiError` table (`schemas/envelope.fbs`).
///
/// `code` — dotted `<domain>.<reason>` string (see `docs/rust-error-codes.md`).
/// `context` — optional human-readable detail; user data goes here, never in `code`.
/// `report` — the precondition report and warnings of the verb that failed (Stories 9.26 and
/// 9.32), written as `Envelope.precondition` / `Envelope.warnings` on the error envelope; `None`
/// everywhere else. Boxed so the `Err` side of every wrapper's `Result` stays small.
/// `hints` — the CLI's hint lines for the refusal, verbatim and in the CLI's order (Story 9.56),
/// written as `FfiError.hints`; empty (no field on the wire) for an error without hints.
#[derive(Debug)]
pub struct FfiErrorObj {
    pub code: String,
    pub context: Option<String>,
    pub report: Option<Box<CallReport>>,
    pub hints: Vec<String>,
}

impl FfiErrorObj {
    /// Attaches the report the failed verb left behind (Stories 9.26 and 9.32). A revset detail
    /// the error's mapper already set (Story 9.25) is kept.
    #[must_use]
    pub fn with_report(mut self, mut report: CallReport) -> Self {
        if let Some(previous) = self.report.take() {
            report.revset = report.revset.or(previous.revset);
        }
        self.report = Some(Box::new(report));
        self
    }
}

/// Maps a failed pre-verb snapshot onto the AR-P-4 taxonomy (Story 9.26): the one NEW code is
/// [`JJ_STALE_WORKING_COPY`]; a config fault is [`JJ_CONFIG_ERROR`] naming the key, anything
/// else [`JJ_JJ_LIB_ERROR`] with jj-lib's own message. The stale recovery's concurrent-writer
/// refusal (Story 9.23) reuses [`JJ_CONCURRENT_WORKING_COPY`], without `context`, as
/// `map_mutate_err` reports the same condition.
pub(crate) fn map_precondition_err(e: zanshin_jj::PreconditionError) -> FfiErrorObj {
    use zanshin_jj::PreconditionError as P;
    let hints = e.hints();
    let message = e.message();
    let (code, context) = match e {
        P::StaleWorkingCopy {
            cause,
            working_copy_op_id,
            repo_op_id,
        } => (
            JJ_STALE_WORKING_COPY,
            format!(
                "{}\n{working_copy_op_id}\n{repo_op_id}\n{}",
                cause.as_str(),
                message.unwrap_or_default()
            ),
        ),
        P::Config { reason } => (JJ_CONFIG_ERROR, reason),
        P::ConcurrentWorkingCopy => {
            return FfiErrorObj {
                code: JJ_CONCURRENT_WORKING_COPY.to_owned(),
                context: None,
                report: None,
                hints: Vec::new(),
            }
        }
        P::Backend(reason) => (JJ_JJ_LIB_ERROR, reason),
    };
    FfiErrorObj {
        code: code.to_owned(),
        context: Some(context),
        report: None,
        hints,
    }
}

/// The tail of every wrapper whose verb runs the pre-verb snapshot (Stories 9.26 and 9.32):
/// takes the report and the warnings the verb left on `repo` and stamps them onto BOTH outcomes
/// — the ok envelope through `build`, the error envelope through [`FfiErrorObj::with_report`].
///
/// # Errors
/// - Whatever `map_err` makes of the verb's error, carrying the (partial) report.
pub(crate) fn precondition_envelope<T, E>(
    repo: &mut zanshin_jj::Repo,
    result: Result<T, E>,
    map_err: impl FnOnce(E) -> FfiErrorObj,
    build: impl FnOnce(&T, &CallReport) -> Vec<u8>,
) -> Result<Vec<u8>, FfiErrorObj> {
    let report = CallReport::take(repo);
    match result {
        Ok(value) => Ok(build(&value, &report)),
        Err(e) => Err(map_err(e).with_report(report)),
    }
}

// ── Shared request-buffer guards ─────────────────────────────────────────────
//
// Every request-BUFFER reader (`repo.rs`, `file.rs`) builds its OWN byte slice in its own
// scope and returns an OWNED struct — see the module comment in `repo.rs` for why a shared
// generic reader would be unsound. Only the null check and the two error shapes are
// genuinely shared, so they live here rather than once per noun module.

/// Reject a null request pointer before any dereference.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
pub(crate) fn reject_null_request(data: *const u8) -> Result<(), FfiErrorObj> {
    if data.is_null() {
        return Err(FfiErrorObj {
            report: None,
            hints: Vec::new(),
            code: FFI_NULL_POINTER.to_owned(),
            context: None,
        });
    }
    Ok(())
}

/// The `ffi.invalid_argument` error a failed request-buffer verification produces.
pub(crate) fn invalid_request(e: &flatbuffers::InvalidFlatbuffer) -> FfiErrorObj {
    FfiErrorObj {
        report: None,
        hints: Vec::new(),
        code: FFI_INVALID_ARGUMENT.to_owned(),
        context: Some(e.to_string()),
    }
}

/// Reject a request buffer that was built for a different wrapper.
///
/// Nothing in the `FlatBuffers` layer distinguishes one request table from another — a buffer
/// built for one verb VERIFIES as another verb's table — so every request table carries a
/// `RequestKind` tag as field 0 and every reader checks it here, immediately after
/// `root_with_opts` and BEFORE any other field is read. `RequestKind::Unspecified` is
/// `FlatBuffers`' absent-field default, so a producer that never set the tag lands here too and
/// is refused; nothing untagged is ever accepted. A byte outside the enum is refused the same
/// way and prints as `<UNKNOWN n>` — the tag is caller-supplied data, never trusted.
///
/// WHY this must precede the handle borrow: a mis-routed buffer has to be refused on its own
/// merits, not only when the caller happens to hold a live handle. Each wrapper therefore calls
/// its reader BEFORE `session_from_handle`, which puts the four request-buffer rungs (null →
/// verify → kind → fields) ahead of the handle rung. The message names the `RequestKind`
/// VARIANT rather than the table: `ChangeIdList` is read by two wrappers, so a table-named
/// message would read `expected ChangeIdList, got ChangeIdList` for the one pair where the
/// distinction matters most.
///
/// # Errors
/// - `ffi.invalid_argument` — `actual` is not `expected`.
pub(crate) fn expect_request_kind(actual: fbs::RequestKind, expected: fbs::RequestKind) -> Result<(), FfiErrorObj> {
    if actual == expected {
        return Ok(());
    }
    Err(FfiErrorObj {
        report: None,
        hints: Vec::new(),
        code: FFI_INVALID_ARGUMENT.to_owned(),
        context: Some(format!("request kind mismatch: expected {expected:?}, got {actual:?}")),
    })
}

/// The `jj.invalid_input` refusal an ABSENT required request field produces.
///
/// Argument arity is observable CLI behavior: `jj file annotate`'s positional `path`,
/// `jj file search`'s `-p/--pattern`, and `jj git remote add`'s two positionals are all
/// required at v0.46.0, so an omitted field is a caller bug and must be named as one. An
/// explicitly present EMPTY string is a VALUE, not an absence, and is passed through
/// unchanged.
pub(crate) fn missing_field(field: &str) -> FfiErrorObj {
    FfiErrorObj {
        report: None,
        hints: Vec::new(),
        code: JJ_INVALID_INPUT.to_owned(),
        context: Some(format!("{field} is required")),
    }
}

// ── Shared handle borrow ─────────────────────────────────────────────────────
//
// The crate's one spelling of the unbounded-lifetime contract: 32 call sites across 13
// modules, every wrapper that borrows a session behind a raw handle. Unlike the builders
// in this module it returns a BORROW, not a finished buffer — hence its own banner.
//
// This is now the ONLY `.ok_or_else(…)` spelling of that borrow in the crate: the nine
// modules that used to inline it (`repo.rs`, `file.rs`, `status.rs`, `change.rs`,
// `graph.rs`, `op_log.rs`, `bookmarks.rs`, `remotes.rs`, `log_defaults.rs`) all call this
// helper. The one deliberate non-user is `zanshin_repo_close` in `repo.rs`, whose close
// path is a different shape — `if let Some(session) = …` followed by `handle_drop`, with
// its own SAFETY comment about close ordering — not a fallible borrow.

/// Borrow the [`RepoSession`] behind a raw handle, or produce `ffi.invalid_handle`.
///
/// # Safety
/// - `handle` must be `0` or a live value returned by a successful handle-producing wrapper.
/// - At most ONE borrow per handle may be live at a time. The returned lifetime `'a` is
///   unbounded, so two calls with the same non-zero handle mint two aliasing `&mut` —
///   undefined behaviour. Call this once per wrapper invocation and pass the borrow down.
/// - The borrow must not outlive the `extern "C"` call it was taken in: the handle's owner
///   is the Dart side, which may close (and free) the session as soon as the call returns.
pub(crate) unsafe fn session_from_handle<'a>(handle: u64) -> Result<&'a mut RepoSession, FfiErrorObj> {
    // SAFETY: non-zero handle originated from arm_session's handle_into_raw
    // (Box<RepoSession>) in zanshin_repo_open/init/clone/convert; single-isolate model
    // (AD-2) guarantees no concurrent access.
    unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(|| FfiErrorObj {
        report: None,
        hints: Vec::new(),
        code: FFI_INVALID_HANDLE.to_owned(),
        context: None,
    })
}

/// Build a success `Envelope` with no payload and return the finished buffer.
///
/// Sets `ok = true`, `error = None`, `data_type = Payload::NONE`. The first real
/// payload builder (`ok(payload)`) arrives in Story 3.4a; this covers the no-payload case.
#[must_use]
pub fn ok_empty() -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128);
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::NONE,
            data: None,
            precondition: None,
            warnings: None,
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// Build a success `Envelope` with a `RepoHandle` payload and return the finished buffer.
///
/// Sets `ok = true`, `data_type = Payload::RepoHandle`, `data.handle = handle`,
/// `data.session_id = session_id`.
/// `handle` is the raw `*mut RepoSession` cast to `u64` via `handle_into_raw`; Dart
/// stores it and passes it back verbatim to `zanshin_repo_close`. `session_id` is
/// the process-unique, never-reused id async events carry as their correlation id
/// (the raw address is ABA-unsafe across close→reopen; the session id is not).
///
/// `report` is the creating call's (Story 9.33): its warnings and — convert only — the
/// conversion's snapshot report. `zanshin_repo_open` passes `&CallReport::default()`, which
/// writes neither field.
///
/// `trackable` is the creation's trackable remote bookmarks (Story 11.22); an empty list stays
/// ABSENT on the wire.
#[must_use]
pub fn ok_repo_handle(handle: u64, session_id: u64, trackable: &[String], report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128);
    let trackable_remote_bookmarks = (!trackable.is_empty()).then(|| {
        let items: Vec<_> = trackable.iter().map(|s| b.create_string(s)).collect();
        b.create_vector(&items)
    });
    let h = fbs::RepoHandle::create(
        &mut b,
        &fbs::RepoHandleArgs {
            handle,
            session_id,
            trackable_remote_bookmarks,
        },
    );
    finish_envelope(b, fbs::Payload::RepoHandle, Some(h.as_union_value()), report)
}

/// Build the `MutationResult` table into `b` and return its offset.
///
/// Children (the two string vectors) are built before the string scalars, before the
/// table itself — the same bottom-up order as `ok_diagnostics`/`change_to_envelope`.
///
/// Extracted so the TOP-LEVEL form (`ok_mutation_result`, six Story 6.5 wrappers plus
/// `zanshin_restore`) and the NESTED form (`ok_absorb_result`, Story 9.3, plus Story 9.5's
/// `GitImportResult`/`GitExportResult` in `git.rs`) have exactly one construction site and
/// cannot drift apart. `pub(crate)` since Story 9.5, whose two nested payloads are built in
/// their own noun file.
pub(crate) fn build_mutation_result<'a>(
    b: &mut FlatBufferBuilder<'a>,
    r: &zanshin_jj::MutationResult,
) -> flatbuffers::WIPOffset<fbs::MutationResult<'a>> {
    let new_change_offs: Vec<_> = r.new_change_ids.iter().map(|c| b.create_string(&c.0)).collect();
    let new_change_vec = b.create_vector(&new_change_offs);
    let abandoned_offs: Vec<_> = r.abandoned_change_ids.iter().map(|c| b.create_string(&c.0)).collect();
    let abandoned_vec = b.create_vector(&abandoned_offs);
    let new_op_id_off = b.create_string(&r.new_op_id.0);
    // Both written iff `Some`: null for absence (Stories 9.26, 9.12).
    let working_copy_change_id_off = r.working_copy_change_id.as_ref().map(|id| b.create_string(&id.0));
    let finish_off = r.finish.as_ref().map(|f| crate::snapshot::build_finish_facts(b, f));
    fbs::MutationResult::create(
        b,
        &fbs::MutationResultArgs {
            new_op_id: Some(new_op_id_off),
            new_change_ids: Some(new_change_vec),
            abandoned_change_ids: Some(abandoned_vec),
            working_copy_change_id: working_copy_change_id_off,
            finish: finish_off,
        },
    )
}

/// Build a success `Envelope` with a `MutationResult` payload and return the finished buffer.
///
/// Sets `ok = true`, `data_type = Payload::MutationResult`. Shared by all six Story 6.5
/// mutation wrappers and Story 9.3's `zanshin_restore` (`repo.rs`), not owned by one noun
/// file.
#[must_use]
pub fn ok_mutation_result(r: &zanshin_jj::MutationResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let mutation_result = build_mutation_result(&mut b, r);
    finish_envelope(
        b,
        fbs::Payload::MutationResult,
        Some(mutation_result.as_union_value()),
        report,
    )
}

/// Build a success `Envelope` with an `AbsorbResult` payload and return the finished buffer.
///
/// Sets `ok = true`, `data_type = Payload::AbsorbResult` (Story 9.3). The nested
/// `MutationResult` is built first through [`build_mutation_result`], then the string
/// vector, the optional `source_change_id`, and each `SkippedPath` — every child
/// completed before the `AbsorbResult` table opens, as `FlatBuffers` requires.
///
/// `source_change_id` is written only when present: null-for-absence is the wire form of
/// "jj-lib abandoned the source, or nothing moved".
#[must_use]
pub fn ok_absorb_result(r: &zanshin_jj::AbsorbResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let mutation = build_mutation_result(&mut b, &r.mutation);
    let rewritten_offs: Vec<_> = r.rewritten_change_ids.iter().map(|c| b.create_string(&c.0)).collect();
    let rewritten_vec = b.create_vector(&rewritten_offs);
    let source_off = r.source_change_id.as_ref().map(|c| b.create_string(&c.0));
    let skipped_offs: Vec<_> = r
        .skipped_paths
        .iter()
        .map(|s| {
            let path = b.create_string(&s.path);
            let reason = b.create_string(&s.reason);
            fbs::SkippedPath::create(
                &mut b,
                &fbs::SkippedPathArgs {
                    path: Some(path),
                    reason: Some(reason),
                },
            )
        })
        .collect();
    let skipped_vec = b.create_vector(&skipped_offs);
    let absorb_result = fbs::AbsorbResult::create(
        &mut b,
        &fbs::AbsorbResultArgs {
            mutation: Some(mutation),
            rewritten_change_ids: Some(rewritten_vec),
            source_change_id: source_off,
            num_rebased: r.num_rebased,
            skipped_paths: Some(skipped_vec),
        },
    );
    finish_envelope(
        b,
        fbs::Payload::AbsorbResult,
        Some(absorb_result.as_union_value()),
        report,
    )
}

/// Build a success `Envelope` with a `SquashPlan` payload and return the finished buffer
/// (Story 9.15).
///
/// `combined_description` is written only when present: null-for-absence is the wire form of
/// "nothing to ask".
#[must_use]
pub fn ok_squash_plan(r: &zanshin_jj::SquashPlan, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let combined = r.combined_description.as_deref().map(|text| b.create_string(text));
    let plan = fbs::SquashPlan::create(
        &mut b,
        &fbs::SquashPlanArgs {
            combined_description: combined,
        },
    );
    finish_envelope(b, fbs::Payload::SquashPlan, Some(plan.as_union_value()), report)
}

/// Build a success `Envelope` with a `SelectedTree` payload and return the finished buffer
/// (Story 9.50): the tree ids and labels exactly as `zanshin_jj` returned them.
#[must_use]
pub fn ok_selected_tree(r: &zanshin_jj::SelectedTreeId, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let mut strings = |values: &[String]| {
        let offsets: Vec<_> = values.iter().map(|v| b.create_string(v)).collect();
        b.create_vector(&offsets)
    };
    let tree_ids = strings(&r.tree_ids);
    let labels = strings(&r.labels);
    let tree = fbs::SelectedTree::create(
        &mut b,
        &fbs::SelectedTreeArgs {
            tree_ids: Some(tree_ids),
            labels: Some(labels),
        },
    );
    finish_envelope(b, fbs::Payload::SelectedTree, Some(tree.as_union_value()), report)
}

/// Build a success `Envelope` with a `ResolveList` payload and return the finished buffer (Story
/// 9.17): each conflicted path with its description, side count, refusal text (absent =
/// resolvable), labels and merge hunks.
#[must_use]
pub fn ok_resolve_list(r: &zanshin_jj::ResolveList, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let files: Vec<_> = r
        .files
        .iter()
        .map(|file| {
            let hunks: Vec<_> = file
                .hunks
                .iter()
                .map(|hunk| {
                    let terms: Vec<_> = hunk
                        .terms
                        .iter()
                        .map(|term| {
                            let content = b.create_vector(term);
                            fbs::ConflictTerm::create(&mut b, &fbs::ConflictTermArgs { content: Some(content) })
                        })
                        .collect();
                    let terms = b.create_vector(&terms);
                    fbs::ConflictHunk::create(&mut b, &fbs::ConflictHunkArgs { terms: Some(terms) })
                })
                .collect();
            let hunks = b.create_vector(&hunks);
            let labels: Vec<_> = file.labels.iter().map(|l| b.create_string(l)).collect();
            let labels = b.create_vector(&labels);
            let path = b.create_string(&file.path);
            let description = b.create_string(&file.description);
            let unresolvable = file.unresolvable.as_deref().map(|u| b.create_string(u));
            let term_ids: Vec<_> = file
                .term_ids
                .iter()
                .map(|id| {
                    let id = id.as_deref().map(|id| b.create_string(id));
                    fbs::ConflictTermId::create(&mut b, &fbs::ConflictTermIdArgs { id })
                })
                .collect();
            let term_ids = b.create_vector(&term_ids);
            fbs::ConflictedFile::create(
                &mut b,
                &fbs::ConflictedFileArgs {
                    path: Some(path),
                    description: Some(description),
                    num_sides: file.num_sides,
                    unresolvable,
                    labels: Some(labels),
                    hunks: Some(hunks),
                    term_ids: Some(term_ids),
                },
            )
        })
        .collect();
    let files = b.create_vector(&files);
    let list = fbs::ResolveList::create(&mut b, &fbs::ResolveListArgs { files: Some(files) });
    finish_envelope(b, fbs::Payload::ResolveList, Some(list.as_union_value()), report)
}

/// Build a success `Envelope` with a `MovementTargets` payload and return the finished buffer
/// (Story 9.10): `edit` and the candidates in `zanshin_jj`'s order (the CLI's prompt order).
#[must_use]
pub fn ok_movement_targets(r: &zanshin_jj::MovementTargets, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let target_offs: Vec<_> = r
        .targets
        .iter()
        .map(|target| {
            let commit_id = b.create_string(&target.commit_id.0);
            let change_id = b.create_string(&target.change_id.0);
            fbs::MovementTarget::create(
                &mut b,
                &fbs::MovementTargetArgs {
                    commit_id: Some(commit_id),
                    change_id: Some(change_id),
                },
            )
        })
        .collect();
    let targets = b.create_vector(&target_offs);
    let movement = fbs::MovementTargets::create(
        &mut b,
        &fbs::MovementTargetsArgs {
            edit: r.edit,
            targets: Some(targets),
        },
    );
    finish_envelope(
        b,
        fbs::Payload::MovementTargets,
        Some(movement.as_union_value()),
        report,
    )
}

/// Build a success `Envelope` with a `SplitResult` payload and return the finished buffer
/// (Story 9.15). The nested `MutationResult` is built first through [`build_mutation_result`],
/// then the two change-id strings — every child completed before the `SplitResult` table opens.
#[must_use]
pub fn ok_split_result(r: &zanshin_jj::SplitResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let mutation = build_mutation_result(&mut b, &r.mutation);
    let selected = b.create_string(&r.selected_change_id.0);
    let remaining = b.create_string(&r.remaining_change_id.0);
    let split = fbs::SplitResult::create(
        &mut b,
        &fbs::SplitResultArgs {
            mutation: Some(mutation),
            selected_change_id: Some(selected),
            remaining_change_id: Some(remaining),
        },
    );
    finish_envelope(b, fbs::Payload::SplitResult, Some(split.as_union_value()), report)
}

/// Build a success `Envelope` with a `FixResult` payload and return the finished buffer (Story
/// 9.9). The nested `MutationResult` is built first through [`build_mutation_result`], then each
/// `FixToolStderr` — every child completed before the `FixResult` table opens.
#[must_use]
pub fn ok_fix_result(r: &zanshin_jj::FixResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let mutation = build_mutation_result(&mut b, &r.mutation);
    let stderr_offs: Vec<_> = r
        .tool_stderr
        .iter()
        .map(|entry| {
            let path = b.create_string(&entry.path);
            let stderr = b.create_string(&entry.stderr);
            fbs::FixToolStderr::create(
                &mut b,
                &fbs::FixToolStderrArgs {
                    path: Some(path),
                    stderr: Some(stderr),
                },
            )
        })
        .collect();
    let tool_stderr = b.create_vector(&stderr_offs);
    let fix = fbs::FixResult::create(
        &mut b,
        &fbs::FixResultArgs {
            mutation: Some(mutation),
            num_fixed_commits: r.num_fixed_commits,
            num_checked_commits: r.num_checked_commits,
            tool_stderr: Some(tool_stderr),
        },
    );
    finish_envelope(b, fbs::Payload::FixResult, Some(fix.as_union_value()), report)
}

/// Build a success `Envelope` with a `SimplifyParentsResult` payload and return the finished
/// buffer (Story 9.14). The nested `MutationResult` is built first through
/// [`build_mutation_result`], before the `SimplifyParentsResult` table opens.
#[must_use]
pub fn ok_simplify_parents_result(r: &zanshin_jj::SimplifyParentsResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let mutation = build_mutation_result(&mut b, &r.mutation);
    let result = fbs::SimplifyParentsResult::create(
        &mut b,
        &fbs::SimplifyParentsResultArgs {
            mutation: Some(mutation),
            num_target_commits: r.num_target_commits,
            num_simplified_commits: r.num_simplified_commits,
            num_removed_edges: r.num_removed_edges,
            num_rebased_descendants: r.num_rebased_descendants,
        },
    );
    finish_envelope(
        b,
        fbs::Payload::SimplifyParentsResult,
        Some(result.as_union_value()),
        report,
    )
}

/// One previewed verb's answer with its refusal already mapped onto the AR-P-4 taxonomy (Story
/// 9.31) — the wire form of `zanshin_jj::ActionOutcome`. The refusal goes through
/// `map_mutate_err`, the mapping the verb's own wrapper uses, so a row and the verb it previews
/// carry the same code and `context` by construction.
#[derive(Debug)]
pub struct ActionOutcomeObj {
    /// Whether the verb would run.
    pub status: fbs::ActionStatus,
    /// The verb's refusal, present exactly for `ActionStatus::Refused`.
    pub refusal: Option<FfiErrorObj>,
    /// A squash row: the squash needs a combined description.
    pub combined_description_needed: bool,
    /// A bookmark row: the move is not a fast-forward.
    pub allow_backwards_needed: bool,
}

impl From<zanshin_jj::ActionOutcome> for ActionOutcomeObj {
    fn from(outcome: zanshin_jj::ActionOutcome) -> Self {
        Self {
            status: match outcome.status {
                zanshin_jj::ActionStatus::Available => fbs::ActionStatus::Available,
                zanshin_jj::ActionStatus::NoOp => fbs::ActionStatus::NoOp,
                zanshin_jj::ActionStatus::Refused => fbs::ActionStatus::Refused,
            },
            refusal: outcome.refusal.map(crate::repo::map_mutate_err),
            combined_description_needed: outcome.combined_description_needed,
            allow_backwards_needed: outcome.allow_backwards_needed,
        }
    }
}

/// One row of `zanshin_drop_actions`' answer in wire form (Story 9.31).
#[derive(Debug)]
pub struct DropActionObj {
    /// The previewed verb.
    pub verb: fbs::DropVerb,
    /// The index into the request's `locations`; an index above `u32::MAX` saturates (a request
    /// that large cannot be built).
    pub location: u32,
    /// Its answer.
    pub outcome: ActionOutcomeObj,
}

impl From<zanshin_jj::DropAction> for DropActionObj {
    fn from(action: zanshin_jj::DropAction) -> Self {
        Self {
            verb: match action.verb {
                zanshin_jj::DropVerb::RebaseSource => fbs::DropVerb::RebaseSource,
                zanshin_jj::DropVerb::RebaseRevisions => fbs::DropVerb::RebaseRevisions,
                zanshin_jj::DropVerb::Squash => fbs::DropVerb::Squash,
                zanshin_jj::DropVerb::NewMerge => fbs::DropVerb::NewMerge,
                zanshin_jj::DropVerb::Duplicate => fbs::DropVerb::Duplicate,
                zanshin_jj::DropVerb::Split => fbs::DropVerb::Split,
                zanshin_jj::DropVerb::BookmarkMove => fbs::DropVerb::BookmarkMove,
                zanshin_jj::DropVerb::RebaseBranch => fbs::DropVerb::RebaseBranch,
                zanshin_jj::DropVerb::Revert => fbs::DropVerb::Revert,
                zanshin_jj::DropVerb::Restore => fbs::DropVerb::Restore,
                zanshin_jj::DropVerb::Absorb => fbs::DropVerb::Absorb,
                zanshin_jj::DropVerb::Interdiff => fbs::DropVerb::Interdiff,
            },
            location: u32::try_from(action.location).unwrap_or(u32::MAX),
            outcome: action.outcome.into(),
        }
    }
}

/// `zanshin_drop_actions`' answer in wire form (Story 9.31): the rows in order.
#[derive(Debug)]
pub struct DropActionsObj {
    /// The rows.
    pub actions: Vec<DropActionObj>,
}

impl From<zanshin_jj::DropActions> for DropActionsObj {
    fn from(actions: zanshin_jj::DropActions) -> Self {
        Self {
            actions: actions.actions.into_iter().map(DropActionObj::from).collect(),
        }
    }
}

/// `zanshin_change_actions`' answer in wire form (Story 9.31): the seven card-menu outcomes in
/// `zanshin_jj::ChangeActions`' field order.
#[derive(Debug)]
pub struct ChangeActionsObj {
    /// `new X`, `new -A X`, `new -B X`, `edit X`, `describe X`, `squash -r X`, `abandon X`.
    pub outcomes: [ActionOutcomeObj; 7],
}

impl From<zanshin_jj::ChangeActions> for ChangeActionsObj {
    fn from(actions: zanshin_jj::ChangeActions) -> Self {
        Self {
            outcomes: [
                actions.new_onto.into(),
                actions.new_insert_after.into(),
                actions.new_insert_before.into(),
                actions.edit.into(),
                actions.describe.into(),
                actions.squash_into_parent.into(),
                actions.abandon.into(),
            ],
        }
    }
}

/// Builds one `ActionOutcome` table; the refusal, when present, as an `FfiError` table.
fn build_action_outcome<'a>(
    b: &mut FlatBufferBuilder<'a>,
    outcome: &ActionOutcomeObj,
) -> flatbuffers::WIPOffset<fbs::ActionOutcome<'a>> {
    let refusal = outcome
        .refusal
        .as_ref()
        .map(|e| build_ffi_error(b, &e.code, e.context.as_deref(), &e.hints, &[], None));
    fbs::ActionOutcome::create(
        b,
        &fbs::ActionOutcomeArgs {
            status: outcome.status,
            refusal,
            combined_description_needed: outcome.combined_description_needed,
            allow_backwards_needed: outcome.allow_backwards_needed,
        },
    )
}

/// Build a success `Envelope` with a `DropActions` payload and return the finished buffer
/// (Story 9.31): every row in order, each outcome completed before its `DropAction` opens.
#[must_use]
pub fn ok_drop_actions(rows: &DropActionsObj, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let offsets: Vec<_> = rows
        .actions
        .iter()
        .map(|row| {
            let outcome = build_action_outcome(&mut b, &row.outcome);
            fbs::DropAction::create(
                &mut b,
                &fbs::DropActionArgs {
                    verb: row.verb,
                    location: row.location,
                    outcome: Some(outcome),
                },
            )
        })
        .collect();
    let actions = b.create_vector(&offsets);
    let payload = fbs::DropActions::create(&mut b, &fbs::DropActionsArgs { actions: Some(actions) });
    finish_envelope(b, fbs::Payload::DropActions, Some(payload.as_union_value()), report)
}

/// Build a success `Envelope` with a `ChangeActions` payload and return the finished buffer
/// (Story 9.31); every one of the seven outcomes is written.
#[must_use]
pub fn ok_change_actions(actions: &ChangeActionsObj, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let [new_onto, new_insert_after, new_insert_before, edit, describe, squash_into_parent, abandon] = actions
        .outcomes
        .each_ref()
        .map(|outcome| build_action_outcome(&mut b, outcome));
    let payload = fbs::ChangeActions::create(
        &mut b,
        &fbs::ChangeActionsArgs {
            new_onto: Some(new_onto),
            new_insert_after: Some(new_insert_after),
            new_insert_before: Some(new_insert_before),
            edit: Some(edit),
            describe: Some(describe),
            squash_into_parent: Some(squash_into_parent),
            abandon: Some(abandon),
        },
    );
    finish_envelope(b, fbs::Payload::ChangeActions, Some(payload.as_union_value()), report)
}

/// Build a success `Envelope` with a `Diagnostics` payload and return the finished buffer.
///
/// Sets `ok = true`, `data_type = Payload::Diagnostics`, and populates the four
/// diagnostic fields. All fields are compile-time constants or infallibly resolved
/// values; this builder has no fallible path.
#[must_use]
pub fn ok_diagnostics(app_version: &str, git_sha: &str, log_path: &str, jj_lib_version: &str) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let app_version_off = b.create_string(app_version);
    let git_sha_off = b.create_string(git_sha);
    let log_path_off = b.create_string(log_path);
    let jj_lib_version_off = b.create_string(jj_lib_version);
    let diag = fbs::Diagnostics::create(
        &mut b,
        &fbs::DiagnosticsArgs {
            app_version: Some(app_version_off),
            git_sha: Some(git_sha_off),
            log_path: Some(log_path_off),
            jj_lib_version: Some(jj_lib_version_off),
        },
    );
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::Diagnostics,
            data: Some(diag.as_union_value()),
            precondition: None,
            warnings: None,
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// Wrap an already-built payload offset in an ok `Envelope` and finish the buffer.
///
/// The generic tail every payload builder ends with. The payload BUILDERS stay in their noun
/// file — `status.rs:41` / `bookmarks.rs:33` set that rule — but the envelope shape itself has
/// exactly one construction site, so no noun can introduce a second spelling of it.
///
/// `data` is `None` only for `zanshin_snapshot` (Story 9.26) and `zanshin_environment_adopt`
/// (Story 9.36), whose successes carry no payload.
/// `report` is written as `Envelope.precondition` (a verb that ran the pre-verb snapshot) and
/// `Envelope.warnings` (Story 9.32); a builder with neither passes `&CallReport::default()`,
/// which writes neither field.
pub(crate) fn finish_envelope(
    mut b: FlatBufferBuilder<'_>,
    data_type: fbs::Payload,
    data: Option<flatbuffers::WIPOffset<flatbuffers::UnionWIPOffset>>,
    report: &CallReport,
) -> Vec<u8> {
    let precondition = report
        .precondition
        .as_ref()
        .map(|p| crate::snapshot::build_precondition(&mut b, p));
    let warnings = build_warnings(&mut b, &report.warnings);
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type,
            data,
            precondition,
            warnings,
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// Builds `Envelope.warnings` — `None` for an empty list, so a call without warnings writes no
/// field (null for absence; it also keeps [`PANIC_FALLBACK_ENVELOPE`] byte-identical).
fn build_warnings<'a>(
    b: &mut FlatBufferBuilder<'a>,
    warnings: &[zanshin_jj::Warning],
) -> Option<flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<fbs::Warning<'a>>>>> {
    if warnings.is_empty() {
        return None;
    }
    let offsets: Vec<_> = warnings
        .iter()
        .map(|w| {
            let code = b.create_string(warning_code(w.kind));
            let message = b.create_string(&w.message);
            fbs::Warning::create(
                b,
                &fbs::WarningArgs {
                    code: Some(code),
                    message: Some(message),
                },
            )
        })
        .collect();
    Some(b.create_vector(&offsets))
}

/// Builds one `FfiError` table. `hints` empty writes no `hints` vector (Story 9.56: absent =
/// none) and `left_behind` empty no `left_behind` vector (Story 9.57), so an error with neither
/// keeps its pre-9.56 bytes — [`PANIC_FALLBACK_ENVELOPE`] included. `revset` `None` writes no
/// `revset` table (Story 9.25).
pub(crate) fn build_ffi_error<'a>(
    b: &mut FlatBufferBuilder<'a>,
    code: &str,
    context: Option<&str>,
    hints: &[String],
    left_behind: &[String],
    revset: Option<&zanshin_jj::RevsetErrorDetail>,
) -> flatbuffers::WIPOffset<fbs::FfiError<'a>> {
    let code = b.create_string(code);
    let context = context.map(|c| b.create_string(c));
    let hints = build_strings(b, hints);
    let left_behind = build_strings(b, left_behind);
    let revset = revset.map(|detail| build_revset_detail(b, detail));
    fbs::FfiError::create(
        b,
        &fbs::FfiErrorArgs {
            code: Some(code),
            context,
            hints,
            left_behind,
            revset,
        },
    )
}

/// Builds one `RevsetErrorDetail` table (Story 9.25).
fn build_revset_detail<'a>(
    b: &mut FlatBufferBuilder<'a>,
    detail: &zanshin_jj::RevsetErrorDetail,
) -> flatbuffers::WIPOffset<fbs::RevsetErrorDetail<'a>> {
    let span = detail.span.map(|span| {
        let length = span.length.map(fbs::RevsetSpanLength::new);
        fbs::RevsetSpan::create(
            b,
            &fbs::RevsetSpanArgs {
                offset: span.offset,
                length: length.as_ref(),
            },
        )
    });
    let symbol = detail.symbol.as_deref().map(|s| b.create_string(s));
    let candidates = build_strings(b, &detail.candidates);
    let message = (!detail.message.is_empty()).then(|| b.create_string(&detail.message));
    fbs::RevsetErrorDetail::create(
        b,
        &fbs::RevsetErrorDetailArgs {
            kind: revset_error_kind(detail.kind),
            span,
            symbol,
            candidates,
            message,
        },
    )
}

/// The wire form of a [`zanshin_jj::RevsetErrorKind`], one to one.
fn revset_error_kind(kind: zanshin_jj::RevsetErrorKind) -> fbs::RevsetErrorKind {
    use fbs::RevsetErrorKind as W;
    use zanshin_jj::RevsetErrorKind as K;
    match kind {
        K::SyntaxError => W::SyntaxError,
        K::NotPostfixOperator => W::NotPostfixOperator,
        K::NotInfixOperator => W::NotInfixOperator,
        K::NoSuchFunction => W::NoSuchFunction,
        K::InvalidFunctionArguments => W::InvalidFunctionArguments,
        K::FsPathWithoutWorkspace => W::FsPathWithoutWorkspace,
        K::WorkingCopyWithoutWorkspace => W::WorkingCopyWithoutWorkspace,
        K::RedefinedFunctionParameter => W::RedefinedFunctionParameter,
        K::Expression => W::Expression,
        K::InAliasExpansion => W::InAliasExpansion,
        K::InParameterExpansion => W::InParameterExpansion,
        K::RecursiveAlias => W::RecursiveAlias,
        K::NoSuchRevision => W::NoSuchRevision,
        K::WorkspaceMissingWorkingCopy => W::WorkspaceMissingWorkingCopy,
        K::EmptyString => W::EmptyString,
        K::AmbiguousCommitIdPrefix => W::AmbiguousCommitIdPrefix,
        K::AmbiguousChangeIdPrefix => W::AmbiguousChangeIdPrefix,
        K::DivergentChangeId => W::DivergentChangeId,
        K::ConflictedRef => W::ConflictedRef,
        K::Backend => W::Backend,
        K::Other => W::Other,
    }
}

/// A `[string]` vector of `strings`, in order; `None` (no field) when there are none.
fn build_strings<'a>(
    b: &mut FlatBufferBuilder<'a>,
    strings: &[String],
) -> Option<flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<&'a str>>>> {
    if strings.is_empty() {
        return None;
    }
    let offsets: Vec<_> = strings.iter().map(|s| b.create_string(s)).collect();
    Some(b.create_vector(&offsets))
}

/// Build an error `Envelope` and return the finished buffer.
///
/// Sets `ok = false`, `data_type = Payload::NONE`, and populates `FfiError { code, context }`.
/// `code` must be a dotted `<domain>.<reason>` string (see `docs/rust-error-codes.md`).
/// User-visible detail belongs in `context`, never in `code`. Writes no `hints`, no
/// `precondition` and no `warnings` — see [`err_with_report`].
#[must_use]
pub fn err(code: &str, context: Option<&str>) -> Vec<u8> {
    err_with_report(code, context, &[], None)
}

/// [`err`] carrying the CLI's hint lines as `FfiError.hints` (Story 9.56) and the report of the
/// verb that failed — its (partial) pre-verb snapshot report as `Envelope.precondition` (Story
/// 9.26), its warnings as `Envelope.warnings` (Story 9.32) and what a failed init or conversion
/// left on disk as `FfiError.left_behind` (Stories 9.57/9.58). With no hints and `None` (or an
/// empty report) it builds exactly [`err`]'s bytes — which is what keeps
/// [`PANIC_FALLBACK_ENVELOPE`] byte-identical.
#[must_use]
pub fn err_with_report(code: &str, context: Option<&str>, hints: &[String], report: Option<&CallReport>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let left_behind = report.map_or(&[][..], |r| r.left_behind.as_slice());
    let revset = report.and_then(|r| r.revset.as_ref());
    let error = build_ffi_error(&mut b, code, context, hints, left_behind, revset);
    let precondition = report
        .and_then(|r| r.precondition.as_ref())
        .map(|p| crate::snapshot::build_precondition(&mut b, p));
    let warnings = match report {
        Some(r) => build_warnings(&mut b, &r.warnings),
        None => None,
    };
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: false,
            error: Some(error),
            data_type: fbs::Payload::NONE,
            data: None,
            precondition,
            warnings,
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// Wrap a fallible closure in `std::panic::catch_unwind` and return a finished `Envelope` buffer.
///
/// The closure `f` returns `Result<Vec<u8>, FfiErrorObj>` where `Ok(buf)` is an
/// already-finished `Envelope` buffer (e.g. from `ok_empty()`) and `Err(e)` is an
/// error to be converted via `err()`. Keeping `FlatBufferBuilder` inside the closure (which
/// produces a plain `Vec<u8>`, which is `UnwindSafe`) means only `f` itself must satisfy
/// `UnwindSafe` — no `AssertUnwindSafe` gymnastics needed here.
///
/// Outcome mapping:
/// - `Ok(Ok(buf))` — the success buffer the closure built is returned as-is.
/// - `Ok(Err(e))` — converted to an error `Envelope` via `err_never_unwind`.
/// - `Err(panic)` — converted to `err_never_unwind(INTERNAL_PANIC, <panic message>)`.
///
/// The error/panic arms build their `Envelope` via [`err_never_unwind`], so a (essentially
/// unreachable) panic *inside* `err` can never unwind out of this backstop and across the C
/// ABI. This relies on the crate being built with `panic = "unwind"` (the workspace default);
/// under `panic = "abort"`, `catch_unwind` cannot intercept at all.
#[must_use]
pub fn catch<F>(f: F) -> Vec<u8>
where
    F: FnOnce() -> Result<Vec<u8>, FfiErrorObj> + UnwindSafe,
{
    match catch_unwind(f) {
        Ok(Ok(buf)) => buf,
        Ok(Err(e)) => err_never_unwind(&e.code, e.context.as_deref(), &e.hints, e.report.as_deref()),
        Err(panic) => err_never_unwind(INTERNAL_PANIC, Some(&panic_message(panic.as_ref())), &[], None),
    }
}

/// Build an error `Envelope` without ever unwinding.
///
/// `err` builds a small in-memory `FlatBuffers` buffer, so a panic here is unreachable in
/// practice — but a panic backstop must give a hard guarantee, not a probabilistic one. If
/// `err` ever panics, fall back to the pre-serialised [`PANIC_FALLBACK_ENVELOPE`]. The only
/// remaining failure mode is allocation failure, which aborts the process rather than
/// unwinding — so no panic can cross the C ABI through this path.
fn err_never_unwind(code: &str, context: Option<&str>, hints: &[String], report: Option<&CallReport>) -> Vec<u8> {
    let report = std::panic::AssertUnwindSafe(report);
    catch_unwind(|| err_with_report(code, context, hints, *report)).unwrap_or_else(|_| PANIC_FALLBACK_ENVELOPE.to_vec())
}

fn panic_message(p: &(dyn Any + Send)) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        return (*s).to_owned();
    }
    if let Some(s) = p.downcast_ref::<String>() {
        return s.clone();
    }
    "<unknown panic payload>".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope_generated::zanshin::ffi as fbs;
    use flatbuffers::VerifierOptions;

    fn verified_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
        let opts = VerifierOptions::default();
        flatbuffers::root_with_opts::<fbs::Envelope>(&opts, bytes)
            .expect("FlatBuffers Verifier must pass for a well-formed Envelope buffer")
    }

    #[test]
    fn ok_repo_handle_produces_repo_handle_envelope() {
        let buf = ok_repo_handle(0xdead_beef_cafe_1234, 7, &[], &CallReport::default());
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert!(env.error().is_none());
        assert_eq!(env.data_type(), fbs::Payload::RepoHandle);
        let rh = env.data_as_repo_handle().expect("RepoHandle payload must be present");
        assert_eq!(rh.handle(), 0xdead_beef_cafe_1234);
        assert_eq!(rh.session_id(), 7);
        // Story 11.22: no trackable remote bookmarks = the field stays absent.
        assert!(rh.trackable_remote_bookmarks().is_none());
        // Story 9.33: an empty report (`open`, or a creation with nothing to report) writes
        // neither field.
        assert!(env.precondition().is_none());
        assert!(env.warnings().is_none());
    }

    /// Story 9.33: a creation's ok envelope carries its report beside the handle — the
    /// conversion's snapshot report and the warnings in order.
    #[test]
    fn ok_repo_handle_carries_the_creation_report() {
        let report = CallReport {
            precondition: Some(zanshin_jj::Precondition {
                was_snapshot_taken: true,
                ..zanshin_jj::Precondition::default()
            }),
            warnings: vec![
                warning(zanshin_jj::WarningKind::SnapshotFilesRefused, "refused"),
                warning(zanshin_jj::WarningKind::IdentityMissing, "identity"),
            ],
            left_behind: Vec::new(),
            revset: None,
        };
        let trackable = ["main@origin".to_owned(), "dev@upstream".to_owned()];
        let buf = ok_repo_handle(1, 2, &trackable, &report);
        let env = verified_envelope(&buf);
        assert_eq!(env.data_as_repo_handle().map(|h| h.handle()), Some(1));
        let wire: Vec<_> = env
            .data_as_repo_handle()
            .and_then(|h| h.trackable_remote_bookmarks())
            .expect("trackable")
            .iter()
            .collect();
        assert_eq!(wire, ["main@origin", "dev@upstream"]);
        assert!(env.precondition().is_some_and(|p| p.was_snapshot_taken()));
        assert_eq!(
            wire_warnings(&env),
            [
                ("jj.snapshot_files_refused".to_owned(), "refused".to_owned()),
                ("jj.identity_missing".to_owned(), "identity".to_owned()),
            ]
        );
    }

    #[test]
    fn ok_diagnostics_produces_diagnostics_envelope() {
        let buf = ok_diagnostics("1.2.3", "abc123", "/tmp/Logs/Zanshin", "0.46.0");
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert!(env.error().is_none());
        assert_eq!(env.data_type(), fbs::Payload::Diagnostics);
        let diag = env.data_as_diagnostics().expect("Diagnostics payload must be present");
        assert_eq!(diag.app_version(), Some("1.2.3"));
        assert_eq!(diag.git_sha(), Some("abc123"));
        assert_eq!(diag.log_path(), Some("/tmp/Logs/Zanshin"));
        assert_eq!(diag.jj_lib_version(), Some("0.46.0"));
    }

    #[test]
    fn ok_mutation_result_produces_mutation_result_envelope() {
        let r = zanshin_jj::MutationResult {
            finish: None,
            new_op_id: zanshin_jj::OperationId("abc123".to_owned()),
            new_change_ids: vec![zanshin_jj::ChangeId("qpvuntsm".to_owned())],
            abandoned_change_ids: vec![
                zanshin_jj::ChangeId("rlvkpnrz".to_owned()),
                zanshin_jj::ChangeId("zsuskuln".to_owned()),
            ],
            working_copy_change_id: Some(zanshin_jj::ChangeId("qpvuntsm".to_owned())),
        };
        let buf = ok_mutation_result(&r, &CallReport::default());
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert!(env.error().is_none());
        assert_eq!(env.data_type(), fbs::Payload::MutationResult);
        let mr = env
            .data_as_mutation_result()
            .expect("MutationResult payload must be present");
        assert_eq!(mr.new_op_id(), Some("abc123"));
        assert_eq!(
            mr.new_change_ids().map(|v| v.iter().collect::<Vec<_>>()),
            Some(vec!["qpvuntsm"])
        );
        assert_eq!(
            mr.abandoned_change_ids().map(|v| v.iter().collect::<Vec<_>>()),
            Some(vec!["rlvkpnrz", "zsuskuln"])
        );
        assert_eq!(mr.working_copy_change_id(), Some("qpvuntsm"));
        assert!(mr.finish().is_none(), "None must be ABSENT on the wire");
        assert!(env.warnings().is_none(), "no warnings: the field is ABSENT");

        // No working-copy commit afterwards (a restore to the root operation, Story 9.12).
        let r = zanshin_jj::MutationResult {
            working_copy_change_id: None,
            ..r
        };
        let buf = ok_mutation_result(&r, &CallReport::default());
        let mr = verified_envelope(&buf)
            .data_as_mutation_result()
            .expect("MutationResult");
        assert_eq!(mr.working_copy_change_id(), None, "None must be ABSENT on the wire");
    }

    fn warning(kind: zanshin_jj::WarningKind, message: &str) -> zanshin_jj::Warning {
        zanshin_jj::Warning {
            kind,
            message: message.to_owned(),
        }
    }

    fn wire_warnings(env: &fbs::Envelope<'_>) -> Vec<(String, String)> {
        env.warnings()
            .map(|v| {
                v.iter()
                    .map(|w| (w.code().unwrap_or("").to_owned(), w.message().unwrap_or("").to_owned()))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Story 9.32: the ok arm writes the report's warnings in order, each under its registered
    /// code; the precondition rides along untouched.
    #[test]
    fn the_ok_arm_writes_the_warnings_in_order_under_their_codes() {
        let report = CallReport {
            precondition: Some(zanshin_jj::Precondition::default()),
            warnings: vec![
                warning(zanshin_jj::WarningKind::ConfigAliasInvalid, "first"),
                warning(zanshin_jj::WarningKind::IdentityMissing, "second"),
            ],
            left_behind: Vec::new(),
            revset: None,
        };
        let buf = ok_mutation_result(&sample_mutation_result(), &report);
        let env = verified_envelope(&buf);
        assert!(env.precondition().is_some());
        assert_eq!(
            wire_warnings(&env),
            [
                ("jj.config_alias_invalid".to_owned(), "first".to_owned()),
                ("jj.identity_missing".to_owned(), "second".to_owned()),
            ]
        );
    }

    /// Story 9.32: the error arm carries the warnings too — a refusal keeps what was warned
    /// before it — and `catch` forwards them from the `FfiErrorObj`.
    #[test]
    fn the_error_arm_writes_the_warnings_too() {
        let buf = catch(|| {
            Err(FfiErrorObj {
                report: None,
                hints: Vec::new(),
                code: JJ_IMMUTABLE.to_owned(),
                context: Some("abc".to_owned()),
            }
            .with_report(CallReport::warnings(vec![warning(
                zanshin_jj::WarningKind::PathsUnmatched,
                "No matching entries for paths: x",
            )])))
        });
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_IMMUTABLE));
        assert!(env.precondition().is_none(), "a handle-less report has no precondition");
        assert_eq!(
            wire_warnings(&env),
            [(
                "jj.paths_unmatched".to_owned(),
                "No matching entries for paths: x".to_owned()
            )]
        );
    }

    /// An EMPTY report writes exactly `err`'s bytes: absent means empty, on both arms.
    #[test]
    fn an_empty_report_writes_no_warnings_field() {
        assert_eq!(
            err_with_report("jj.x", None, &[], Some(&CallReport::default())),
            err("jj.x", None)
        );
    }

    /// The registry, literally (`docs/rust-error-codes.md` § Warning Codes). No wildcard arm: a new
    /// `WarningKind` does not compile here until its registry string is written down.
    fn registered(kind: zanshin_jj::WarningKind) -> &'static str {
        use zanshin_jj::WarningKind as K;
        match kind {
            K::IdentityMissing => "jj.identity_missing",
            K::WorkingCopyImmutable => "jj.working_copy_immutable",
            K::JjconflictFilesPresent => "jj.jjconflict_files_present",
            K::GitHeadUpdateFailed => "jj.git_head_update_failed",
            K::GitExportFailed => "jj.git_export_failed",
            K::GitImportFailed => "jj.git_import_failed",
            K::SnapshotFilesRefused => "jj.snapshot_files_refused",
            K::SnapshotPathsNotUtf8 => "jj.snapshot_paths_not_utf8",
            K::CheckoutFilesSkipped => "jj.checkout_files_skipped",
            K::UnresolvedConflicts => "jj.unresolved_conflicts",
            K::PathsUnmatched => "jj.paths_unmatched",
            K::ConfigAliasInvalid => "jj.config_alias_invalid",
            K::ConfigAliasRedefined => "jj.config_alias_redefined",
            K::RevsetDiagnostic => "jj.revset_diagnostic",
            K::ShortPrefixesFailed => "jj.short_prefixes_failed",
            K::RemoteUrlDuplicate => "jj.remote_url_duplicate",
            K::BookmarkTargetEmpty => "jj.bookmark_target_empty",
            K::BookmarkNamesUnmatched => "jj.bookmark_names_unmatched",
            K::BookmarkAutoTrackExisting => "jj.bookmark_auto_track_existing",
            K::BookmarkRenameRemoteExists => "jj.bookmark_rename_remote_exists",
            K::BookmarkTrackingDropped => "jj.bookmark_tracking_dropped",
            K::BookmarkRemotesNotRenamed => "jj.bookmark_remotes_not_renamed",
            K::BookmarkTrackedRemotesExist => "jj.bookmark_tracked_remotes_exist",
            K::RemoteBookmarksUnmatched => "jj.remote_bookmarks_unmatched",
            K::BookmarkRemotesUnmatched => "jj.bookmark_remotes_unmatched",
            K::BookmarkAlreadyTracked => "jj.bookmark_already_tracked",
            K::BookmarkNotTracked => "jj.bookmark_not_tracked",
            K::BookmarkGitTrackingUntrack => "jj.bookmark_git_tracking_untrack",
            K::AbsorbPathSkipped => "jj.absorb_path_skipped",
            K::PathAccessDenied => "jj.path_access_denied",
            K::PathNotAFile => "jj.path_not_a_file",
            K::ConfigWorkingCopyAuthor => "jj.config_working_copy_author",
            K::ConfigGcDeleteFailed => "jj.config_gc_delete_failed",
            K::ConfigNothingListed => "jj.config_nothing_listed",
            K::CloneCleanupFailed => "jj.clone_cleanup_failed",
            K::ConfigMigrated => "jj.config_migrated",
            K::ConfigCopied => "jj.config_copied",
            K::ConfigRegenerated => "jj.config_regenerated",
            K::UndoPushOperation => "jj.undo_push_operation",
            K::UndoWorkspaceRemoval => "jj.undo_workspace_removal",
            K::ColocatedInGitWorktree => "jj.colocated_in_git_worktree",
            K::WorkspacePathInaccessible => "jj.workspace_path_inaccessible",
            K::WorkspaceInCurrentDirectory => "jj.workspace_in_current_directory",
            K::WorkspaceNamesUnmatched => "jj.workspace_names_unmatched",
            K::GitWorktreeUnlinkFailed => "jj.git_worktree_unlink_failed",
            K::WorkspaceDirectoryRemoveFailed => "jj.workspace_directory_remove_failed",
            K::SplitAllSelected => "jj.split_all_selected",
            K::SplitNoneSelected => "jj.split_none_selected",
            K::CommitPathsUnmatched => "jj.commit_paths_unmatched",
            K::PushRemotesUnmatched => "jj.push_remotes_unmatched",
            K::PushBookmarksUnmatched => "jj.push_bookmarks_unmatched",
            K::PushTagsUnmatched => "jj.push_tags_unmatched",
            K::PushRevsetEmpty => "jj.push_revset_empty",
            K::PushRevisionsEmpty => "jj.push_revisions_empty",
            K::PushRefSkipped => "jj.push_ref_skipped",
            K::PushCommitSkipped => "jj.push_commit_skipped",
            K::PushRefsMovedOnRemote => "jj.push_refs_moved_on_remote",
            K::PushRemoteRejected => "jj.push_remote_rejected",
            K::PushSigningSkippedImmutable => "jj.push_signing_skipped_immutable",
            K::CloneBranchesUnmatched => "jj.clone_branches_unmatched",
            K::TemplateDiagnostic => "jj.template_diagnostic",
            K::FetchRemotesUnmatched => "jj.fetch_remotes_unmatched",
            K::FetchRefspecIgnored => "jj.fetch_refspec_ignored",
            K::FetchBranchesUnmatched => "jj.fetch_branches_unmatched",
            K::TrunkAliasUnresolved => "jj.trunk_alias_unresolved",
            K::DuplicateAsOwnDescendant => "jj.duplicate_as_own_descendant",
            K::DuplicateAsOwnAncestor => "jj.duplicate_as_own_ancestor",
            K::FixToolStartFailed => "jj.fix_tool_start_failed",
            K::FixToolFailed => "jj.fix_tool_failed",
            K::FixToolTimedOut => "jj.fix_tool_timed_out",
            K::FilesetDiagnostic => "jj.fileset_diagnostic",
            K::ConfigDeprecated => "jj.config_deprecated",
            K::OpDiffChangesUnresolved => "jj.op_diff_changes_unresolved",
            K::OpAbandonWorkingCopyNotUpdated => "jj.op_abandon_working_copy_not_updated",
            K::WorkspaceNoLongerExists => "jj.workspace_no_longer_exists",
            K::ResolveConflictsRemain => "jj.resolve_conflicts_remain",
        }
    }

    /// Every `WarningKind` maps to exactly its registry string (`docs/rust-error-codes.md`
    /// § Warning Codes — the same literals as Dart's `ZanshinWarningCode`), so a typo'd or
    /// swapped constant fails here, and no two kinds share a code.
    #[test]
    fn every_warning_kind_has_its_registered_code() {
        use zanshin_jj::WarningKind as K;
        let kinds = [
            K::IdentityMissing,
            K::WorkingCopyImmutable,
            K::JjconflictFilesPresent,
            K::GitHeadUpdateFailed,
            K::GitExportFailed,
            K::GitImportFailed,
            K::SnapshotFilesRefused,
            K::SnapshotPathsNotUtf8,
            K::CheckoutFilesSkipped,
            K::UnresolvedConflicts,
            K::PathsUnmatched,
            K::ConfigAliasInvalid,
            K::ConfigAliasRedefined,
            K::RevsetDiagnostic,
            K::ShortPrefixesFailed,
            K::RemoteUrlDuplicate,
            K::BookmarkTargetEmpty,
            K::BookmarkNamesUnmatched,
            K::BookmarkAutoTrackExisting,
            K::BookmarkRenameRemoteExists,
            K::BookmarkTrackingDropped,
            K::BookmarkRemotesNotRenamed,
            K::BookmarkTrackedRemotesExist,
            K::RemoteBookmarksUnmatched,
            K::BookmarkRemotesUnmatched,
            K::BookmarkAlreadyTracked,
            K::BookmarkNotTracked,
            K::BookmarkGitTrackingUntrack,
            K::AbsorbPathSkipped,
            K::PathAccessDenied,
            K::PathNotAFile,
            K::ConfigWorkingCopyAuthor,
            K::ConfigGcDeleteFailed,
            K::ConfigNothingListed,
            K::CloneCleanupFailed,
            K::ConfigMigrated,
            K::ConfigCopied,
            K::ConfigRegenerated,
            K::UndoPushOperation,
            K::UndoWorkspaceRemoval,
            K::ColocatedInGitWorktree,
            K::WorkspacePathInaccessible,
            K::WorkspaceInCurrentDirectory,
            K::WorkspaceNamesUnmatched,
            K::GitWorktreeUnlinkFailed,
            K::WorkspaceDirectoryRemoveFailed,
            K::SplitAllSelected,
            K::SplitNoneSelected,
            K::CommitPathsUnmatched,
            K::PushRemotesUnmatched,
            K::PushBookmarksUnmatched,
            K::PushTagsUnmatched,
            K::PushRevsetEmpty,
            K::PushRevisionsEmpty,
            K::PushRefSkipped,
            K::PushCommitSkipped,
            K::PushRefsMovedOnRemote,
            K::PushRemoteRejected,
            K::PushSigningSkippedImmutable,
            K::CloneBranchesUnmatched,
            K::TemplateDiagnostic,
            K::FetchRemotesUnmatched,
            K::FetchRefspecIgnored,
            K::FetchBranchesUnmatched,
            K::TrunkAliasUnresolved,
            K::DuplicateAsOwnDescendant,
            K::DuplicateAsOwnAncestor,
            K::FixToolStartFailed,
            K::FixToolFailed,
            K::FixToolTimedOut,
            K::FilesetDiagnostic,
            K::ConfigDeprecated,
            K::OpDiffChangesUnresolved,
            K::OpAbandonWorkingCopyNotUpdated,
            K::WorkspaceNoLongerExists,
            K::ResolveConflictsRemain,
        ];
        for kind in kinds {
            assert_eq!(warning_code(kind), registered(kind), "{kind:?}");
        }
        let codes: std::collections::BTreeSet<&str> = kinds.iter().map(|k| registered(*k)).collect();
        assert_eq!(codes.len(), kinds.len(), "one code per kind");
    }

    fn sample_mutation_result() -> zanshin_jj::MutationResult {
        zanshin_jj::MutationResult {
            finish: None,
            new_op_id: zanshin_jj::OperationId("op99".to_owned()),
            new_change_ids: Vec::new(),
            abandoned_change_ids: Vec::new(),
            working_copy_change_id: Some(zanshin_jj::ChangeId("qpvuntsm".to_owned())),
        }
    }

    #[test]
    fn ok_absorb_result_produces_absorb_result_envelope() {
        let r = zanshin_jj::AbsorbResult {
            mutation: sample_mutation_result(),
            rewritten_change_ids: vec![
                zanshin_jj::ChangeId("rlvkpnrz".to_owned()),
                zanshin_jj::ChangeId("zsuskuln".to_owned()),
            ],
            source_change_id: Some(zanshin_jj::ChangeId("kkmpptxz".to_owned())),
            num_rebased: 3,
            skipped_paths: vec![zanshin_jj::SkippedPath {
                path: "dir/link".to_owned(),
                reason: "Is a symlink".to_owned(),
            }],
        };
        let buf = ok_absorb_result(&r, &CallReport::default());
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::AbsorbResult);
        let ar = env
            .data_as_absorb_result()
            .expect("AbsorbResult payload must be present");
        let nested = ar.mutation().expect("the nested MutationResult must be present");
        assert_eq!(nested.new_op_id(), Some("op99"));
        assert_eq!(nested.working_copy_change_id(), Some("qpvuntsm"));
        assert_eq!(
            ar.rewritten_change_ids().map(|v| v.iter().collect::<Vec<_>>()),
            Some(vec!["rlvkpnrz", "zsuskuln"])
        );
        assert_eq!(ar.source_change_id(), Some("kkmpptxz"));
        assert_eq!(ar.num_rebased(), 3);
        let skipped = ar.skipped_paths().expect("skipped_paths must be present");
        assert_eq!(skipped.len(), 1);
        assert_eq!(skipped.get(0).path(), Some("dir/link"));
        assert_eq!(skipped.get(0).reason(), Some("Is a symlink"));
    }

    /// `source_change_id` is null-for-absence: the abandoned-source / nothing-moved shape
    /// must leave the field unset rather than writing an empty string.
    #[test]
    fn ok_absorb_result_omits_an_absent_source_change_id() {
        let r = zanshin_jj::AbsorbResult {
            mutation: sample_mutation_result(),
            rewritten_change_ids: Vec::new(),
            source_change_id: None,
            num_rebased: 0,
            skipped_paths: Vec::new(),
        };
        let buf = ok_absorb_result(&r, &CallReport::default());
        let env = verified_envelope(&buf);
        let ar = env
            .data_as_absorb_result()
            .expect("AbsorbResult payload must be present");
        assert!(ar.source_change_id().is_none());
        assert!(ar.rewritten_change_ids().is_some_and(|v| v.is_empty()));
        assert!(ar.skipped_paths().is_some_and(|v| v.is_empty()));
    }

    /// Story 9.15: the plan's text is written when present and ABSENT (never `""`) when there is
    /// nothing to ask.
    #[test]
    fn ok_squash_plan_writes_the_text_or_leaves_it_absent() {
        let present = zanshin_jj::SquashPlan {
            combined_description: Some("B\n\nC\n".to_owned()),
        };
        let buf = ok_squash_plan(&present, &CallReport::default());
        let env = verified_envelope(&buf);
        assert_eq!(env.data_type(), fbs::Payload::SquashPlan);
        let plan = env.data_as_squash_plan().expect("SquashPlan payload");
        assert_eq!(plan.combined_description(), Some("B\n\nC\n"));

        let absent = zanshin_jj::SquashPlan {
            combined_description: None,
        };
        let buf = ok_squash_plan(&absent, &CallReport::default());
        let env = verified_envelope(&buf);
        assert!(env
            .data_as_squash_plan()
            .expect("SquashPlan payload")
            .combined_description()
            .is_none());
    }

    fn outcome(
        status: zanshin_jj::ActionStatus,
        refusal: Option<zanshin_jj::MutateError>,
    ) -> zanshin_jj::ActionOutcome {
        zanshin_jj::ActionOutcome {
            status,
            refusal,
            combined_description_needed: false,
            allow_backwards_needed: false,
        }
    }

    /// Story 9.31: every verb and status crosses as its wire value, the location as an index, the
    /// refusal as the `FfiError` `map_mutate_err` makes of it, and the flags as given.
    #[test]
    fn ok_drop_actions_writes_every_row_with_its_mapped_refusal() {
        use zanshin_jj::{ActionStatus as S, DropVerb as V};
        let verbs = [
            (V::RebaseSource, fbs::DropVerb::RebaseSource),
            (V::RebaseRevisions, fbs::DropVerb::RebaseRevisions),
            (V::Squash, fbs::DropVerb::Squash),
            (V::NewMerge, fbs::DropVerb::NewMerge),
            (V::Duplicate, fbs::DropVerb::Duplicate),
            (V::Split, fbs::DropVerb::Split),
            (V::BookmarkMove, fbs::DropVerb::BookmarkMove),
            (V::RebaseBranch, fbs::DropVerb::RebaseBranch),
            (V::Revert, fbs::DropVerb::Revert),
            (V::Restore, fbs::DropVerb::Restore),
            (V::Absorb, fbs::DropVerb::Absorb),
            (V::Interdiff, fbs::DropVerb::Interdiff),
        ];
        let mut actions: Vec<zanshin_jj::DropAction> = verbs
            .iter()
            .enumerate()
            .map(|(i, (verb, _))| zanshin_jj::DropAction {
                verb: *verb,
                location: i,
                outcome: outcome(S::Available, None),
            })
            .collect();
        actions[1].outcome = outcome(S::NoOp, None);
        actions[2].outcome.combined_description_needed = true;
        actions[3].outcome = outcome(
            S::Refused,
            Some(zanshin_jj::MutateError::Immutable {
                commit_id: "abc".to_owned(),
                hints: vec!["first".to_owned(), "second\nline".to_owned()],
            }),
        );
        actions[6].outcome.allow_backwards_needed = true;
        actions.push(zanshin_jj::DropAction {
            verb: V::Squash,
            location: usize::MAX,
            outcome: outcome(S::Refused, Some(zanshin_jj::MutateError::NothingToUndo)),
        });

        let wire = DropActionsObj::from(zanshin_jj::DropActions { actions });
        let buf = ok_drop_actions(&wire, &CallReport::default());
        let env = verified_envelope(&buf);
        assert_eq!(env.data_type(), fbs::Payload::DropActions);
        let rows: Vec<_> = env
            .data_as_drop_actions()
            .expect("DropActions payload")
            .actions()
            .expect("actions")
            .iter()
            .collect();
        assert_eq!(rows.len(), verbs.len() + 1);
        for (i, (_, wire_verb)) in verbs.iter().enumerate() {
            assert_eq!(rows[i].verb(), *wire_verb);
            assert_eq!(rows[i].location(), u32::try_from(i).expect("small"));
        }
        let status = |i: usize| rows[i].outcome().expect("outcome").status();
        assert_eq!(status(0), fbs::ActionStatus::Available);
        assert_eq!(status(1), fbs::ActionStatus::NoOp);
        assert_eq!(status(3), fbs::ActionStatus::Refused);
        assert!(rows[2].outcome().expect("outcome").combined_description_needed());
        assert!(rows[6].outcome().expect("outcome").allow_backwards_needed());
        assert!(rows[0].outcome().expect("outcome").refusal().is_none());
        let refusal = rows[3].outcome().expect("outcome").refusal().expect("refusal");
        assert_eq!((refusal.code(), refusal.context()), (Some(JJ_IMMUTABLE), Some("abc")));
        // Story 9.56: a refusal's hints ride its `FfiError`, in order, embedded newlines kept.
        let hints: Vec<&str> = refusal.hints().expect("hints").iter().collect();
        assert_eq!(hints, ["first", "second\nline"]);
        let last = verbs.len();
        assert_eq!(rows[last].location(), u32::MAX, "an index past u32 saturates");
        let refusal = rows[last].outcome().expect("outcome").refusal().expect("refusal");
        assert_eq!((refusal.code(), refusal.context()), (Some(JJ_NOTHING_TO_UNDO), None));
        assert!(refusal.hints().is_none(), "a hint-less refusal writes no field");
    }

    /// Story 9.31: all seven card-menu outcomes are written, in field order.
    #[test]
    fn ok_change_actions_writes_all_seven_outcomes() {
        use zanshin_jj::ActionStatus as S;
        let actions = zanshin_jj::ChangeActions {
            new_onto: outcome(S::Available, None),
            new_insert_after: outcome(S::NoOp, None),
            new_insert_before: outcome(
                S::Refused,
                Some(zanshin_jj::MutateError::ChangeNotFound { id: "x".to_owned() }),
            ),
            edit: outcome(S::Available, None),
            describe: outcome(
                S::Refused,
                Some(zanshin_jj::MutateError::Config { reason: "c".to_owned() }),
            ),
            squash_into_parent: zanshin_jj::ActionOutcome {
                combined_description_needed: true,
                ..outcome(S::Available, None)
            },
            abandon: outcome(S::Refused, Some(zanshin_jj::MutateError::invalid("r".to_owned()))),
        };
        let buf = ok_change_actions(&ChangeActionsObj::from(actions), &CallReport::default());
        let env = verified_envelope(&buf);
        assert_eq!(env.data_type(), fbs::Payload::ChangeActions);
        let card = env.data_as_change_actions().expect("ChangeActions payload");
        let all = [
            card.new_onto(),
            card.new_insert_after(),
            card.new_insert_before(),
            card.edit(),
            card.describe(),
            card.squash_into_parent(),
            card.abandon(),
        ]
        .map(|o| o.expect("present"));
        let statuses = all.map(|o| o.status());
        assert_eq!(
            statuses,
            [
                fbs::ActionStatus::Available,
                fbs::ActionStatus::NoOp,
                fbs::ActionStatus::Refused,
                fbs::ActionStatus::Available,
                fbs::ActionStatus::Refused,
                fbs::ActionStatus::Available,
                fbs::ActionStatus::Refused,
            ]
        );
        let codes = all.map(|o| o.refusal().and_then(|e| e.code()));
        assert_eq!(
            codes,
            [
                None,
                None,
                Some(JJ_CHANGE_NOT_FOUND),
                None,
                Some(JJ_CONFIG_ERROR),
                None,
                Some(JJ_INVALID_INPUT)
            ]
        );
        assert!(all[5].combined_description_needed());
    }

    #[test]
    fn ok_selected_tree_carries_the_ids_and_labels_in_order() {
        let r = zanshin_jj::SelectedTreeId {
            tree_ids: vec!["a1".to_owned(), "b2".to_owned(), "c3".to_owned()],
            labels: vec!["x".to_owned(), "base".to_owned(), "y".to_owned()],
        };
        let buf = ok_selected_tree(&r, &CallReport::default());
        let env = verified_envelope(&buf);
        assert_eq!(env.data_type(), fbs::Payload::SelectedTree);
        let tree = env.data_as_selected_tree().expect("SelectedTree payload");
        let read = |v: Option<flatbuffers::Vector<'_, flatbuffers::ForwardsUOffset<&str>>>| -> Vec<String> {
            v.expect("present").iter().map(ToOwned::to_owned).collect()
        };
        assert_eq!(read(tree.tree_ids()), r.tree_ids);
        assert_eq!(read(tree.labels()), r.labels);
    }

    /// Story 9.17: every field of every conflicted file survives — labels, a present and an
    /// absent `unresolvable`, multi-term and one-term hunks, and a file without hunks.
    #[test]
    fn ok_resolve_list_carries_every_field_of_every_file() {
        let hunk = |terms: &[&[u8]]| zanshin_jj::ConflictHunk {
            terms: terms.iter().map(|t| t.to_vec()).collect(),
        };
        let r = zanshin_jj::ResolveList {
            files: vec![
                zanshin_jj::ConflictedFile {
                    path: "c.txt".to_owned(),
                    description: "2-sided conflict".to_owned(),
                    num_sides: 2,
                    unresolvable: None,
                    labels: vec!["x".to_owned(), "a".to_owned(), "y".to_owned()],
                    hunks: vec![hunk(&[b"top\n"]), hunk(&[b"x\n", b"", b"y\n"])],
                    term_ids: vec![Some("ab".to_owned()), None, Some("cd".to_owned())],
                },
                zanshin_jj::ConflictedFile {
                    path: "s".to_owned(),
                    description: "2-sided conflict including a symlink".to_owned(),
                    num_sides: 2,
                    unresolvable: Some("Only conflicts that involve normal files".to_owned()),
                    labels: Vec::new(),
                    hunks: Vec::new(),
                    term_ids: Vec::new(),
                },
            ],
        };
        let buf = ok_resolve_list(&r, &CallReport::default());
        let env = verified_envelope(&buf);
        assert_eq!(env.data_type(), fbs::Payload::ResolveList);
        let files = env
            .data_as_resolve_list()
            .expect("ResolveList payload")
            .files()
            .expect("files");
        let decoded: Vec<zanshin_jj::ConflictedFile> = files
            .iter()
            .map(|file| zanshin_jj::ConflictedFile {
                path: file.path().expect("path").to_owned(),
                description: file.description().expect("description").to_owned(),
                num_sides: file.num_sides(),
                unresolvable: file.unresolvable().map(ToOwned::to_owned),
                labels: file.labels().expect("labels").iter().map(ToOwned::to_owned).collect(),
                hunks: file
                    .hunks()
                    .expect("hunks")
                    .iter()
                    .map(|hunk| zanshin_jj::ConflictHunk {
                        terms: hunk
                            .terms()
                            .expect("terms")
                            .iter()
                            .map(|term| term.content().expect("content").bytes().to_vec())
                            .collect(),
                    })
                    .collect(),
                term_ids: file
                    .term_ids()
                    .expect("term ids")
                    .iter()
                    .map(|id| id.id().map(ToOwned::to_owned))
                    .collect(),
            })
            .collect();
        assert_eq!(decoded, r.files);
    }

    #[test]
    fn ok_movement_targets_carries_edit_and_the_candidates_in_order() {
        let target = |commit: &str, change: &str| zanshin_jj::MovementTarget {
            commit_id: zanshin_jj::CommitId(commit.to_owned()),
            change_id: zanshin_jj::ChangeId(change.to_owned()),
        };
        let r = zanshin_jj::MovementTargets {
            edit: true,
            targets: vec![target("c1", "k1"), target("c2", "k2")],
        };
        let buf = ok_movement_targets(&r, &CallReport::default());
        let env = verified_envelope(&buf);
        assert_eq!(env.data_type(), fbs::Payload::MovementTargets);
        let movement = env.data_as_movement_targets().expect("MovementTargets payload");
        assert!(movement.edit());
        let read: Vec<(&str, &str)> = movement
            .targets()
            .expect("present")
            .iter()
            .map(|t| (t.commit_id().expect("commit id"), t.change_id().expect("change id")))
            .collect();
        assert_eq!(read, [("c1", "k1"), ("c2", "k2")]);
    }

    #[test]
    fn ok_split_result_nests_the_mutation_and_names_both_parts() {
        let r = zanshin_jj::SplitResult {
            mutation: sample_mutation_result(),
            selected_change_id: zanshin_jj::ChangeId("selected".to_owned()),
            remaining_change_id: zanshin_jj::ChangeId("remaining".to_owned()),
        };
        let buf = ok_split_result(&r, &CallReport::default());
        let env = verified_envelope(&buf);
        assert_eq!(env.data_type(), fbs::Payload::SplitResult);
        let split = env.data_as_split_result().expect("SplitResult payload");
        assert_eq!(split.mutation().and_then(|m| m.new_op_id()), Some("op99"));
        assert_eq!(split.selected_change_id(), Some("selected"));
        assert_eq!(split.remaining_change_id(), Some("remaining"));
    }

    #[test]
    fn ok_fix_result_nests_the_mutation_and_carries_the_counts_and_stderr() {
        let r = zanshin_jj::FixResult {
            mutation: sample_mutation_result(),
            num_fixed_commits: 2,
            num_checked_commits: 3,
            tool_stderr: vec![zanshin_jj::FixToolStderr {
                path: "a.txt".to_owned(),
                stderr: "oops\n".to_owned(),
            }],
        };
        let buf = ok_fix_result(&r, &CallReport::default());
        let env = verified_envelope(&buf);
        assert_eq!(env.data_type(), fbs::Payload::FixResult);
        let fix = env.data_as_fix_result().expect("FixResult payload");
        assert_eq!(fix.mutation().and_then(|m| m.new_op_id()), Some("op99"));
        assert_eq!((fix.num_fixed_commits(), fix.num_checked_commits()), (2, 3));
        let stderr = fix.tool_stderr().expect("tool_stderr");
        assert_eq!(stderr.len(), 1);
        assert_eq!(
            (stderr.get(0).path(), stderr.get(0).stderr()),
            (Some("a.txt"), Some("oops\n"))
        );
    }

    #[test]
    fn ok_simplify_parents_result_nests_the_mutation_and_carries_the_counts() {
        let r = zanshin_jj::SimplifyParentsResult {
            mutation: sample_mutation_result(),
            num_target_commits: 6,
            num_simplified_commits: 2,
            num_removed_edges: 3,
            num_rebased_descendants: 4,
        };
        let buf = ok_simplify_parents_result(&r, &CallReport::default());
        let env = verified_envelope(&buf);
        assert_eq!(env.data_type(), fbs::Payload::SimplifyParentsResult);
        let result = env
            .data_as_simplify_parents_result()
            .expect("SimplifyParentsResult payload");
        assert_eq!(result.mutation().and_then(|m| m.new_op_id()), Some("op99"));
        assert_eq!(
            (
                result.num_target_commits(),
                result.num_simplified_commits(),
                result.num_removed_edges(),
                result.num_rebased_descendants()
            ),
            (6, 2, 3, 4)
        );
    }

    #[test]
    fn ok_empty_produces_success_envelope() {
        let buf = ok_empty();
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert!(env.error().is_none());
        assert_eq!(env.data_type(), fbs::Payload::NONE);
    }

    /// The refusal arm of the shared handle borrow. A zero handle is the one input the
    /// helper can be handed safely without a live session, and it must produce exactly the
    /// `ffi.invalid_handle` shape all 13 call sites forward — code set, `context` absent.
    #[test]
    fn session_from_handle_refuses_a_zero_handle() {
        // SAFETY: 0 is the documented "no handle" input; nothing is dereferenced.
        // `.err().expect(…)` rather than `expect_err` (which would need `RepoSession: Debug`)
        // or a `let … else` (whose `panic!` arm would be an uncovered line).
        let e = unsafe { session_from_handle(0) }
            .err()
            .expect("a zero handle must be refused");
        assert_eq!(e.code, FFI_INVALID_HANDLE);
        assert_eq!(e.context, None);
    }

    #[test]
    fn err_with_context_roundtrip() {
        let buf = err("jj.repo_not_found", Some("/no/such/path"));
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present when ok==false");
        assert_eq!(e.code(), Some("jj.repo_not_found"));
        assert_eq!(e.context(), Some("/no/such/path"));
    }

    #[test]
    fn err_without_context_has_none() {
        let buf = err("ffi.null_pointer", None);
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present");
        assert_eq!(e.code(), Some("ffi.null_pointer"));
        assert!(e.context().is_none());
    }

    #[test]
    fn catch_ok_closure_returns_success_envelope() {
        let buf = catch(|| Ok(ok_empty()));
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert!(env.error().is_none());
        assert_eq!(env.data_type(), fbs::Payload::NONE);
    }

    #[test]
    fn catch_err_closure_returns_error_envelope() {
        let buf = catch(|| {
            Err(FfiErrorObj {
                report: None,
                hints: Vec::new(),
                code: "ffi.invalid_handle".to_owned(),
                context: Some("handle was zero".to_owned()),
            })
        });
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present");
        assert_eq!(e.code(), Some("ffi.invalid_handle"));
        assert_eq!(e.context(), Some("handle was zero"));
    }

    #[test]
    fn catch_panic_macro_captures_str_message() {
        let buf = catch(|| -> Result<Vec<u8>, FfiErrorObj> { panic!("boom") });
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present after panic");
        assert_eq!(e.code(), Some(INTERNAL_PANIC));
        assert!(
            e.context().is_some_and(|c| c.contains("boom")),
            "panic message 'boom' must appear in context"
        );
    }

    #[test]
    fn catch_panic_string_payload_captures_message() {
        let buf = catch(|| -> Result<Vec<u8>, FfiErrorObj> { std::panic::panic_any(String::from("string payload")) });
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present");
        assert_eq!(e.code(), Some(INTERNAL_PANIC));
        assert_eq!(e.context(), Some("string payload"));
    }

    #[test]
    fn catch_panic_non_string_payload_yields_unknown() {
        let buf = catch(|| -> Result<Vec<u8>, FfiErrorObj> { std::panic::panic_any(42u8) });
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present");
        assert_eq!(e.code(), Some(INTERNAL_PANIC));
        assert_eq!(e.context(), Some("<unknown panic payload>"));
    }

    #[test]
    fn panic_fallback_const_matches_builder() {
        // Keeps PANIC_FALLBACK_ENVELOPE honest: it must be byte-identical to the builder's
        // output for the input-free internal.panic error, or err_never_unwind's last resort
        // would ship a stale buffer.
        assert_eq!(err(INTERNAL_PANIC, None).as_slice(), PANIC_FALLBACK_ENVELOPE);
    }

    #[test]
    fn panic_fallback_const_is_a_valid_error_envelope() {
        let env = verified_envelope(PANIC_FALLBACK_ENVELOPE);
        assert!(!env.ok());
        let e = env.error().expect("fallback must carry an error");
        assert_eq!(e.code(), Some(INTERNAL_PANIC));
        assert!(e.context().is_none());
        assert!(env.warnings().is_none(), "the panic fallback never carries warnings");
    }

    /// Story 9.56: hints are written in order, verbatim; none writes no `hints` field, so a
    /// hint-less error keeps exactly `err`'s bytes.
    #[test]
    fn err_with_report_writes_hints_only_when_there_are_some() {
        assert_eq!(err_with_report("jj.x", Some("c"), &[], None), err("jj.x", Some("c")));
        let buf = err_with_report("jj.x", Some("c"), &["one".to_owned(), "two\nlines".to_owned()], None);
        let env = verified_envelope(&buf);
        let error = env.error().expect("error");
        assert_eq!((error.code(), error.context()), (Some("jj.x"), Some("c")));
        let hints: Vec<&str> = error.hints().expect("hints").iter().collect();
        assert_eq!(hints, ["one", "two\nlines"]);
        assert!(verified_envelope(&err("jj.x", None))
            .error()
            .expect("error")
            .hints()
            .is_none());
    }

    /// Story 9.57: a report's `left_behind` is written as `FfiError.left_behind`, in order; a
    /// report without one writes no field, so the error keeps exactly `err`'s bytes — and the
    /// panic fallback with them.
    #[test]
    fn err_with_report_writes_left_behind_only_when_there_is_some() {
        let empty = CallReport::default();
        assert_eq!(
            err_with_report("jj.x", Some("c"), &[], Some(&empty)),
            err("jj.x", Some("c"))
        );
        assert_eq!(
            err_with_report(INTERNAL_PANIC, None, &[], Some(&empty)),
            PANIC_FALLBACK_ENVELOPE
        );
        assert!(verified_envelope(PANIC_FALLBACK_ENVELOPE)
            .error()
            .expect("error")
            .left_behind()
            .is_none());

        let report = CallReport {
            left_behind: vec!["/w".to_owned(), "/w/.jj".to_owned()],
            ..CallReport::default()
        };
        let buf = err_with_report("jj.convert_failed", Some("c"), &["h".to_owned()], Some(&report));
        let error = verified_envelope(&buf).error().expect("error");
        let left: Vec<&str> = error.left_behind().expect("left_behind").iter().collect();
        assert_eq!(left, ["/w", "/w/.jj"]);
        let hints: Vec<&str> = error.hints().expect("hints").iter().collect();
        assert_eq!(hints, ["h"], "the hints ride beside it untouched");
    }

    /// Story 9.25: a revset detail rides as `FfiError.revset` with every kind one to one, and
    /// `with_report` keeps the detail the mapper set; no detail writes no field.
    #[test]
    fn a_revset_detail_rides_the_error_and_survives_the_verbs_report() {
        use zanshin_jj::RevsetErrorKind as K;
        let detail = |kind| zanshin_jj::RevsetErrorDetail {
            kind,
            span: Some(zanshin_jj::RevsetSpan {
                offset: 1,
                length: Some(2),
            }),
            symbol: None,
            candidates: Vec::new(),
            hints: Vec::new(),
            message: String::new(),
        };
        let kinds = [
            (K::SyntaxError, fbs::RevsetErrorKind::SyntaxError),
            (K::NotPostfixOperator, fbs::RevsetErrorKind::NotPostfixOperator),
            (K::NotInfixOperator, fbs::RevsetErrorKind::NotInfixOperator),
            (K::NoSuchFunction, fbs::RevsetErrorKind::NoSuchFunction),
            (
                K::InvalidFunctionArguments,
                fbs::RevsetErrorKind::InvalidFunctionArguments,
            ),
            (K::FsPathWithoutWorkspace, fbs::RevsetErrorKind::FsPathWithoutWorkspace),
            (
                K::WorkingCopyWithoutWorkspace,
                fbs::RevsetErrorKind::WorkingCopyWithoutWorkspace,
            ),
            (
                K::RedefinedFunctionParameter,
                fbs::RevsetErrorKind::RedefinedFunctionParameter,
            ),
            (K::Expression, fbs::RevsetErrorKind::Expression),
            (K::InAliasExpansion, fbs::RevsetErrorKind::InAliasExpansion),
            (K::InParameterExpansion, fbs::RevsetErrorKind::InParameterExpansion),
            (K::RecursiveAlias, fbs::RevsetErrorKind::RecursiveAlias),
            (K::NoSuchRevision, fbs::RevsetErrorKind::NoSuchRevision),
            (
                K::WorkspaceMissingWorkingCopy,
                fbs::RevsetErrorKind::WorkspaceMissingWorkingCopy,
            ),
            (K::EmptyString, fbs::RevsetErrorKind::EmptyString),
            (
                K::AmbiguousCommitIdPrefix,
                fbs::RevsetErrorKind::AmbiguousCommitIdPrefix,
            ),
            (
                K::AmbiguousChangeIdPrefix,
                fbs::RevsetErrorKind::AmbiguousChangeIdPrefix,
            ),
            (K::DivergentChangeId, fbs::RevsetErrorKind::DivergentChangeId),
            (K::ConflictedRef, fbs::RevsetErrorKind::ConflictedRef),
            (K::Backend, fbs::RevsetErrorKind::Backend),
            (K::Other, fbs::RevsetErrorKind::Other),
        ];
        for (kind, wire) in kinds {
            let buf = err_with_report("jj.x", None, &[], Some(&CallReport::revset(detail(kind))));
            let revset = verified_envelope(&buf)
                .error()
                .expect("error")
                .revset()
                .expect("revset");
            assert_eq!(revset.kind(), wire);
            let span = revset.span().expect("span");
            assert_eq!(
                (span.offset(), span.length().map(fbs::RevsetSpanLength::value)),
                (1, Some(2))
            );
        }

        let mapped = FfiErrorObj {
            code: "jj.x".to_owned(),
            context: None,
            report: Some(Box::new(CallReport::revset(detail(K::Other)))),
            hints: Vec::new(),
        }
        .with_report(CallReport::warnings(vec![zanshin_jj::Warning {
            kind: zanshin_jj::WarningKind::RevsetDiagnostic,
            message: "w".to_owned(),
        }]));
        let report = mapped.report.expect("report");
        assert_eq!(report.revset, Some(detail(K::Other)), "kept");
        assert_eq!(report.warnings.len(), 1, "the verb's report attached");
        assert!(verified_envelope(&err("jj.x", None))
            .error()
            .expect("error")
            .revset()
            .is_none());
    }

    /// `catch` writes an `FfiErrorObj`'s hints on its error envelope (Story 9.56).
    #[test]
    fn catch_writes_the_errors_hints() {
        let buf = catch(|| {
            Err(FfiErrorObj {
                code: "jj.x".to_owned(),
                context: None,
                report: None,
                hints: vec!["h".to_owned()],
            })
        });
        let env = verified_envelope(&buf);
        let hints: Vec<&str> = env.error().expect("error").hints().expect("hints").iter().collect();
        assert_eq!(hints, ["h"]);
    }

    #[test]
    fn err_never_unwind_matches_err_on_normal_input() {
        assert_eq!(
            err_never_unwind("jj.repo_not_found", Some("/x"), &[], None),
            err("jj.repo_not_found", Some("/x"))
        );
    }
}
