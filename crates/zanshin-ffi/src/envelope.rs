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
/// AR-P-4: emitted by `status.rs` when the workspace has no working-copy commit (@), and —
/// since Story 9.22 — by `file_ops.rs`'s two wrappers when the working copy they must lock has
/// no `@` in the head view (the CLI's "Nothing checked out in this workspace"); no `context`.
pub const JJ_NO_WORKING_COPY: &str = "jj.no_working_copy";
/// AR-P-4: emitted by `file_ops.rs::zanshin_file_track`/`_untrack` when the working copy's
/// recorded tree differs from `@`'s tree — `@` rewritten without a checkout by a concurrent
/// writer between the pre-verb snapshot and the verb's own lock; no `context` (Story 9.22). The
/// CLI's "Concurrent working copy operation" check; its own code because the condition is
/// specific to the working copy.
pub const JJ_CONCURRENT_WORKING_COPY: &str = "jj.concurrent_working_copy";
/// AR-P-4: emitted by EVERY wrapper whose verb runs the pre-verb snapshot (Story 9.26) when the
/// working copy is stale — the CLI's `handle_stale_working_copy` refusals. `context` is
/// `"<cause>\n<working_copy_op_id>\n<repo_op_id>"` (full hex ids), `cause` one of `stale`,
/// `sibling_operation`, `operation_not_found`. Nothing is snapshotted or written.
pub const JJ_STALE_WORKING_COPY: &str = "jj.stale_working_copy";
/// AR-P-4: emitted by `file_ops.rs::zanshin_file_untrack` when matched paths are NOT ignored, so
/// the next snapshot would add them straight back; EVERY offending path in `context`, joined
/// by `\n`, in jj-lib's tree order (Story 9.22). No operation is written. Its own code because
/// the remedy is specific: ignore the paths first, then retry.
pub const JJ_PATH_NOT_IGNORED: &str = "jj.path_not_ignored";
/// AR-P-4: emitted by `change.rs` when no change exists for the given id.
pub const JJ_CHANGE_NOT_FOUND: &str = "jj.change_not_found";
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
/// AR-P-4: emitted by `repo.rs::zanshin_undo` when the head operation is the op-store
/// root — there is no parent operation to restore to.
pub const JJ_NOTHING_TO_UNDO: &str = "jj.nothing_to_undo";
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
/// workspace store holds no path for it; the name in `context` (Story 9.7).
///
/// Distinct from `jj.workspace_path_unresolved` because there is nothing to repair: workspaces
/// created before jj 0.38.0 have no recorded path at all, so the answer is simply unavailable.
pub const JJ_WORKSPACE_NO_RECORDED_PATH: &str = "jj.workspace_no_recorded_path";
/// AR-P-4: emitted by `workspace.rs::zanshin_workspace_root` when a path IS recorded but does
/// not resolve — the directory moved, was deleted, or is unreachable; the workspace name and the
/// I/O reason in `context` (Story 9.7).
///
/// Distinct from `jj.workspace_no_recorded_path` because the remedy differs: the workspace can
/// be forgotten (Story 9.13) or its directory restored. `zanshin_workspace_list` never emits
/// either — it degrades the row's `root` to absent instead (CLI parity).
pub const JJ_WORKSPACE_PATH_UNRESOLVED: &str = "jj.workspace_path_unresolved";
/// AR-P-4: emitted by `repo.rs::zanshin_git_fetch` when the underlying `git` subprocess
/// fails (network, authentication, or transport error); detail in `context`.
pub const JJ_NETWORK_ERROR: &str = "jj.network_error";
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
/// more than one file could be written and no `path` chose one, or the given `path` is not one
/// of the candidates — the CLI's file prompt; the candidate paths in `context`, one per line,
/// nothing written (Story 9.28).
pub const JJ_CONFIG_AMBIGUOUS_FILE: &str = "jj.config_ambiguous_file";
/// AR-P-4: emitted by `config.rs` when a config name, a `set` value or `file_write` text is not
/// valid TOML; `context` is `"<start>..<end>\n<message>"` when the parser reports a byte span,
/// else the message (Story 9.28). Nothing is written.
pub const JJ_CONFIG_PARSE_ERROR: &str = "jj.config_parse_error";
/// AR-P-4: emitted by `config.rs` when no file of the requested scope can be determined — the
/// CLI's "No user/repo/workspace config path found[ to edit]" and `gc`'s "No config directory
/// found"; the message in `context` (Story 9.28).
pub const JJ_CONFIG_PATH_NOT_FOUND: &str = "jj.config_path_not_found";
/// AR-P-4: emitted by `graph.rs` when the exhausted revset graph stream left a dangling
/// non-`Missing` edge (upstream stream contract violation); the dangling target in `context`.
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
/// Warning: exact names given to `bookmark delete` that match no local bookmark.
pub const JJ_BOOKMARK_NAMES_UNMATCHED: &str = "jj.bookmark_names_unmatched";
/// Warning: a path `absorb` could not split.
pub const JJ_ABSORB_PATH_SKIPPED: &str = "jj.absorb_path_skipped";
/// Warning: a path whose content could not be read.
pub const JJ_PATH_ACCESS_DENIED: &str = "jj.path_access_denied";
/// Warning: a path that exists but is not a file.
pub const JJ_PATH_NOT_A_FILE: &str = "jj.path_not_a_file";
/// Warning: `user.name`/`user.email` was set but `@`'s author stays the old one.
pub const JJ_CONFIG_WORKING_COPY_AUTHOR: &str = "jj.config_working_copy_author";
/// Warning: a missing repo config directory could not be deleted.
pub const JJ_CONFIG_GC_DELETE_FAILED: &str = "jj.config_gc_delete_failed";
/// Warning: `config list` found nothing to list.
pub const JJ_CONFIG_NOTHING_LISTED: &str = "jj.config_nothing_listed";
/// Warning: a failed clone could not remove what it had created (Story 9.33).
pub const JJ_CLONE_CLEANUP_FAILED: &str = "jj.clone_cleanup_failed";
/// Warning: the login shell's environment could not be read at start-up; the environment Zanshin
/// was started with stays in effect (Story 9.36, Zanshin-only).
pub const ENV_LOGIN_SHELL_UNRESOLVED: &str = "env.login_shell_unresolved";

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
        K::PathsUnmatched => JJ_PATHS_UNMATCHED,
        K::ConfigAliasInvalid => JJ_CONFIG_ALIAS_INVALID,
        K::ConfigAliasRedefined => JJ_CONFIG_ALIAS_REDEFINED,
        K::RevsetDiagnostic => JJ_REVSET_DIAGNOSTIC,
        K::ShortPrefixesFailed => JJ_SHORT_PREFIXES_FAILED,
        K::RemoteUrlDuplicate => JJ_REMOTE_URL_DUPLICATE,
        K::BookmarkTargetEmpty => JJ_BOOKMARK_TARGET_EMPTY,
        K::BookmarkNamesUnmatched => JJ_BOOKMARK_NAMES_UNMATCHED,
        K::AbsorbPathSkipped => JJ_ABSORB_PATH_SKIPPED,
        K::PathAccessDenied => JJ_PATH_ACCESS_DENIED,
        K::PathNotAFile => JJ_PATH_NOT_A_FILE,
        K::ConfigWorkingCopyAuthor => JJ_CONFIG_WORKING_COPY_AUTHOR,
        K::ConfigGcDeleteFailed => JJ_CONFIG_GC_DELETE_FAILED,
        K::ConfigNothingListed => JJ_CONFIG_NOTHING_LISTED,
        K::CloneCleanupFailed => JJ_CLONE_CLEANUP_FAILED,
        K::LoginShellUnresolved => ENV_LOGIN_SHELL_UNRESOLVED,
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
/// print order (Story 9.32), written as `Envelope.precondition` / `Envelope.warnings`. The
/// `Default` is a call with neither — both fields then stay ABSENT on the wire.
#[derive(Debug, Default)]
pub struct CallReport {
    /// The pre-verb snapshot report; `None` for a symbol that runs no precondition.
    pub precondition: Option<zanshin_jj::Precondition>,
    /// The call's warnings; empty writes no `warnings` vector.
    pub warnings: Vec<zanshin_jj::Warning>,
}

impl CallReport {
    /// The report of a handle-less verb, which runs no precondition: only its warnings.
    #[must_use]
    pub fn warnings(warnings: Vec<zanshin_jj::Warning>) -> Self {
        Self {
            precondition: None,
            warnings,
        }
    }

    /// Takes what the last verb left on `repo`: its precondition report and its warnings.
    pub fn take(repo: &mut zanshin_jj::Repo) -> Self {
        Self {
            precondition: repo.take_precondition(),
            warnings: repo.take_warnings(),
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
#[derive(Debug)]
pub struct FfiErrorObj {
    pub code: String,
    pub context: Option<String>,
    pub report: Option<Box<CallReport>>,
}

impl FfiErrorObj {
    /// Attaches the report the failed verb left behind (Stories 9.26 and 9.32).
    #[must_use]
    pub fn with_report(mut self, report: CallReport) -> Self {
        self.report = Some(Box::new(report));
        self
    }
}

/// Maps a failed pre-verb snapshot onto the AR-P-4 taxonomy (Story 9.26): the one NEW code is
/// [`JJ_STALE_WORKING_COPY`]; a config fault is [`JJ_CONFIG_ERROR`] naming the key, anything
/// else [`JJ_JJ_LIB_ERROR`] with jj-lib's own message.
pub(crate) fn map_precondition_err(e: zanshin_jj::PreconditionError) -> FfiErrorObj {
    use zanshin_jj::PreconditionError as P;
    let (code, context) = match e {
        P::StaleWorkingCopy {
            cause,
            working_copy_op_id,
            repo_op_id,
        } => (
            JJ_STALE_WORKING_COPY,
            format!("{}\n{working_copy_op_id}\n{repo_op_id}", cause.as_str()),
        ),
        P::Config { reason } => (JJ_CONFIG_ERROR, reason),
        P::Backend(reason) => (JJ_JJ_LIB_ERROR, reason),
    };
    FfiErrorObj {
        code: code.to_owned(),
        context: Some(context),
        report: None,
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
        code: FFI_INVALID_ARGUMENT.to_owned(),
        context: Some(format!("request kind mismatch: expected {expected:?}, got {actual:?}")),
    })
}

/// The `jj.invalid_input` refusal an ABSENT required request field produces.
///
/// Argument arity is observable CLI behavior: `jj file annotate`'s positional `path`,
/// `jj file search`'s `-p/--pattern`, and `jj git remote add`'s two positionals are all
/// required at v0.44.0, so an omitted field is a caller bug and must be named as one. An
/// explicitly present EMPTY string is a VALUE, not an absence, and is passed through
/// unchanged.
pub(crate) fn missing_field(field: &str) -> FfiErrorObj {
    FfiErrorObj {
        report: None,
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
#[must_use]
pub fn ok_repo_handle(handle: u64, session_id: u64, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128);
    let h = fbs::RepoHandle::create(&mut b, &fbs::RepoHandleArgs { handle, session_id });
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
    let working_copy_change_id_off = b.create_string(&r.working_copy_change_id.0);
    // Written iff `Some`: null for absence (Story 9.26).
    let finish_off = r.finish.as_ref().map(|f| crate::snapshot::build_finish_facts(b, f));
    fbs::MutationResult::create(
        b,
        &fbs::MutationResultArgs {
            new_op_id: Some(new_op_id_off),
            new_change_ids: Some(new_change_vec),
            abandoned_change_ids: Some(abandoned_vec),
            working_copy_change_id: Some(working_copy_change_id_off),
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

/// Build a success `Envelope` with a `Diagnostics` payload and return the finished buffer.
///
/// Sets `ok = true`, `data_type = Payload::Diagnostics`, and populates the three
/// diagnostic fields. All fields are compile-time constants or infallibly resolved
/// values; this builder has no fallible path.
#[must_use]
pub fn ok_diagnostics(app_version: &str, git_sha: &str, log_path: &str) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let app_version_off = b.create_string(app_version);
    let git_sha_off = b.create_string(git_sha);
    let log_path_off = b.create_string(log_path);
    let diag = fbs::Diagnostics::create(
        &mut b,
        &fbs::DiagnosticsArgs {
            app_version: Some(app_version_off),
            git_sha: Some(git_sha_off),
            log_path: Some(log_path_off),
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

/// Build an error `Envelope` and return the finished buffer.
///
/// Sets `ok = false`, `data_type = Payload::NONE`, and populates `FfiError { code, context }`.
/// `code` must be a dotted `<domain>.<reason>` string (see `docs/rust-error-codes.md`).
/// User-visible detail belongs in `context`, never in `code`. Writes no `precondition` and no
/// `warnings` — see [`err_with_report`].
#[must_use]
pub fn err(code: &str, context: Option<&str>) -> Vec<u8> {
    err_with_report(code, context, None)
}

/// [`err`] carrying the report of the verb that failed — its (partial) pre-verb snapshot report
/// as `Envelope.precondition` (Story 9.26) and its warnings as `Envelope.warnings` (Story 9.32).
/// With `None` (or an empty report) it builds exactly [`err`]'s bytes — which is what keeps
/// [`PANIC_FALLBACK_ENVELOPE`] byte-identical.
#[must_use]
pub fn err_with_report(code: &str, context: Option<&str>, report: Option<&CallReport>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let code_off = b.create_string(code);
    let ctx_off = context.map(|c| b.create_string(c));
    let error = fbs::FfiError::create(
        &mut b,
        &fbs::FfiErrorArgs {
            code: Some(code_off),
            context: ctx_off,
        },
    );
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
        Ok(Err(e)) => err_never_unwind(&e.code, e.context.as_deref(), e.report.as_deref()),
        Err(panic) => err_never_unwind(INTERNAL_PANIC, Some(&panic_message(panic.as_ref())), None),
    }
}

/// Build an error `Envelope` without ever unwinding.
///
/// `err` builds a small in-memory `FlatBuffers` buffer, so a panic here is unreachable in
/// practice — but a panic backstop must give a hard guarantee, not a probabilistic one. If
/// `err` ever panics, fall back to the pre-serialised [`PANIC_FALLBACK_ENVELOPE`]. The only
/// remaining failure mode is allocation failure, which aborts the process rather than
/// unwinding — so no panic can cross the C ABI through this path.
fn err_never_unwind(code: &str, context: Option<&str>, report: Option<&CallReport>) -> Vec<u8> {
    let report = std::panic::AssertUnwindSafe(report);
    catch_unwind(|| err_with_report(code, context, *report)).unwrap_or_else(|_| PANIC_FALLBACK_ENVELOPE.to_vec())
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
        let buf = ok_repo_handle(0xdead_beef_cafe_1234, 7, &CallReport::default());
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert!(env.error().is_none());
        assert_eq!(env.data_type(), fbs::Payload::RepoHandle);
        let rh = env.data_as_repo_handle().expect("RepoHandle payload must be present");
        assert_eq!(rh.handle(), 0xdead_beef_cafe_1234);
        assert_eq!(rh.session_id(), 7);
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
        };
        let buf = ok_repo_handle(1, 2, &report);
        let env = verified_envelope(&buf);
        assert_eq!(env.data_as_repo_handle().map(|h| h.handle()), Some(1));
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
        let buf = ok_diagnostics("1.2.3", "abc123", "/tmp/Logs/Zanshin");
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert!(env.error().is_none());
        assert_eq!(env.data_type(), fbs::Payload::Diagnostics);
        let diag = env.data_as_diagnostics().expect("Diagnostics payload must be present");
        assert_eq!(diag.app_version(), Some("1.2.3"));
        assert_eq!(diag.git_sha(), Some("abc123"));
        assert_eq!(diag.log_path(), Some("/tmp/Logs/Zanshin"));
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
            working_copy_change_id: zanshin_jj::ChangeId("qpvuntsm".to_owned()),
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
            err_with_report("jj.x", None, Some(&CallReport::default())),
            err("jj.x", None)
        );
    }

    /// Every `WarningKind` maps to exactly its registry string (`docs/rust-error-codes.md`
    /// § Warning Codes — the same literals as Dart's `ZanshinWarningCode`), so a typo'd or
    /// swapped constant fails here, and no two kinds share a code.
    #[test]
    fn every_warning_kind_has_its_registered_code() {
        use zanshin_jj::WarningKind as K;
        // The registry, literally. No wildcard arm: a new `WarningKind` does not compile here
        // until its registry string is written down.
        fn registered(kind: K) -> &'static str {
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
                K::PathsUnmatched => "jj.paths_unmatched",
                K::ConfigAliasInvalid => "jj.config_alias_invalid",
                K::ConfigAliasRedefined => "jj.config_alias_redefined",
                K::RevsetDiagnostic => "jj.revset_diagnostic",
                K::ShortPrefixesFailed => "jj.short_prefixes_failed",
                K::RemoteUrlDuplicate => "jj.remote_url_duplicate",
                K::BookmarkTargetEmpty => "jj.bookmark_target_empty",
                K::BookmarkNamesUnmatched => "jj.bookmark_names_unmatched",
                K::AbsorbPathSkipped => "jj.absorb_path_skipped",
                K::PathAccessDenied => "jj.path_access_denied",
                K::PathNotAFile => "jj.path_not_a_file",
                K::ConfigWorkingCopyAuthor => "jj.config_working_copy_author",
                K::ConfigGcDeleteFailed => "jj.config_gc_delete_failed",
                K::ConfigNothingListed => "jj.config_nothing_listed",
                K::CloneCleanupFailed => "jj.clone_cleanup_failed",
                K::LoginShellUnresolved => "env.login_shell_unresolved",
            }
        }
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
            K::PathsUnmatched,
            K::ConfigAliasInvalid,
            K::ConfigAliasRedefined,
            K::RevsetDiagnostic,
            K::ShortPrefixesFailed,
            K::RemoteUrlDuplicate,
            K::BookmarkTargetEmpty,
            K::BookmarkNamesUnmatched,
            K::AbsorbPathSkipped,
            K::PathAccessDenied,
            K::PathNotAFile,
            K::ConfigWorkingCopyAuthor,
            K::ConfigGcDeleteFailed,
            K::ConfigNothingListed,
            K::CloneCleanupFailed,
            K::LoginShellUnresolved,
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
            working_copy_change_id: zanshin_jj::ChangeId("qpvuntsm".to_owned()),
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

    #[test]
    fn err_never_unwind_matches_err_on_normal_input() {
        assert_eq!(
            err_never_unwind("jj.repo_not_found", Some("/x"), None),
            err("jj.repo_not_found", Some("/x"))
        );
    }
}
