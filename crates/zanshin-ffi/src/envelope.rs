// SPDX-License-Identifier: MIT
//! `FlatBuffers` `Envelope` builders, AR-P-4 error-code emission, and the `catch_unwind` panic backstop.
//!
//! Every pub ENVELOPE BUILDER returns a finished, owned `Vec<u8>`. Conversion to the FFI
//! `(*mut u8, len)` token happens at the `extern "C"` call site (Story 3.4a) via
//! `ffi_strings::vec_into_ffi_buf` / `vec_into_token`. This module owns nothing beyond
//! the build step.

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
/// AR-P-4: emitted by `status.rs` when the workspace has no working-copy commit (@).
pub const JJ_NO_WORKING_COPY: &str = "jj.no_working_copy";
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
/// AR-P-4: emitted by `repo.rs::zanshin_git_fetch` when `remote_name` has no configured
/// git remote, or the repo has no git backend at all; and — since Story 9.5 — by
/// `git.rs::zanshin_git_remote_remove`/`_rename`/`_set_url` when the named remote does not
/// exist (for `rename`, the OLD name; for `set_url`, only when at least one URL was given).
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
/// disassociate the remote with `bookmark untrack`. The default-ignored remote `git` is
/// excluded, so a colocated `name@git` never produces this code.
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
/// path to name and therefore carries no `context`.
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
/// AR-P-4: emitted by `graph.rs` when the exhausted revset graph stream left a dangling
/// non-`Missing` edge (upstream stream contract violation); the dangling target in `context`.
pub const GRAPH_DANGLING_EDGE: &str = "graph.dangling_edge";
/// AR-P-4: emitted by `repo.rs` when arming the filesystem watcher fails during
/// open/init/clone/convert; detail in `context`. Story 3.5 → Reserved, Story 3.6 →
/// Emitted (single-emission-point: post-arm watch errors ride the event stream
/// as `WatcherEvent { kind: WatchError }`, never this code).
pub const WATCHER_IO_ERROR: &str = "watcher.io_error";

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

/// Rust-side mirror of the `FlatBuffers` `FfiError` table (`schemas/envelope.fbs`).
///
/// `code` — dotted `<domain>.<reason>` string (see `docs/rust-error-codes.md`).
/// `context` — optional human-readable detail; user data goes here, never in `code`.
#[derive(Debug, Clone)]
pub struct FfiErrorObj {
    pub code: String,
    pub context: Option<String>,
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
            code: FFI_NULL_POINTER.to_owned(),
            context: None,
        });
    }
    Ok(())
}

/// The `ffi.invalid_argument` error a failed request-buffer verification produces.
pub(crate) fn invalid_request(e: &flatbuffers::InvalidFlatbuffer) -> FfiErrorObj {
    FfiErrorObj {
        code: FFI_INVALID_ARGUMENT.to_owned(),
        context: Some(e.to_string()),
    }
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
        code: JJ_INVALID_INPUT.to_owned(),
        context: Some(format!("{field} is required")),
    }
}

// ── Shared handle borrow ─────────────────────────────────────────────────────
//
// The one spelling of the unbounded-lifetime contract, shared by every noun module whose
// wrappers take a handle as their first argument (`git.rs`, `commit_views.rs`,
// `workspace.rs`, `bookmark_ops.rs`). Unlike the builders above this returns a BORROW, not
// a finished buffer — hence its own banner.

/// Borrow the [`RepoSession`] behind a raw handle, or produce `ffi.invalid_handle`.
///
/// # Safety
/// `handle` must be `0` or a live value returned by a successful handle-producing wrapper.
pub(crate) unsafe fn session_from_handle<'a>(handle: u64) -> Result<&'a mut RepoSession, FfiErrorObj> {
    // SAFETY: non-zero handle originated from arm_session's handle_into_raw
    // (Box<RepoSession>) in zanshin_repo_open/init/clone/convert; single-isolate model
    // (AD-2) guarantees no concurrent access.
    unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(|| FfiErrorObj {
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
#[must_use]
pub fn ok_repo_handle(handle: u64, session_id: u64) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128);
    let h = fbs::RepoHandle::create(&mut b, &fbs::RepoHandleArgs { handle, session_id });
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::RepoHandle,
            data: Some(h.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
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
    fbs::MutationResult::create(
        b,
        &fbs::MutationResultArgs {
            new_op_id: Some(new_op_id_off),
            new_change_ids: Some(new_change_vec),
            abandoned_change_ids: Some(abandoned_vec),
            working_copy_change_id: Some(working_copy_change_id_off),
        },
    )
}

/// Build a success `Envelope` with a `MutationResult` payload and return the finished buffer.
///
/// Sets `ok = true`, `data_type = Payload::MutationResult`. Shared by all six Story 6.5
/// mutation wrappers and Story 9.3's `zanshin_restore` (`repo.rs`), not owned by one noun
/// file.
#[must_use]
pub fn ok_mutation_result(r: &zanshin_jj::MutationResult) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let mutation_result = build_mutation_result(&mut b, r);
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::MutationResult,
            data: Some(mutation_result.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
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
pub fn ok_absorb_result(r: &zanshin_jj::AbsorbResult) -> Vec<u8> {
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
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::AbsorbResult,
            data: Some(absorb_result.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
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
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// Wrap an already-built payload offset in an ok `Envelope` and finish the buffer.
///
/// The generic tail every noun-module payload builder ends with (`file.rs`'s four, `git.rs`'s
/// two). The payload BUILDERS stay in their noun file — `status.rs:41` / `bookmarks.rs:33`
/// set that rule — but the envelope shape itself has exactly one construction site, so a
/// third noun cannot introduce a fourth spelling of it.
pub(crate) fn finish_envelope(
    mut b: FlatBufferBuilder<'_>,
    data_type: fbs::Payload,
    data: flatbuffers::WIPOffset<flatbuffers::UnionWIPOffset>,
) -> Vec<u8> {
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type,
            data: Some(data),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// Build an error `Envelope` and return the finished buffer.
///
/// Sets `ok = false`, `data_type = Payload::NONE`, and populates `FfiError { code, context }`.
/// `code` must be a dotted `<domain>.<reason>` string (see `docs/rust-error-codes.md`).
/// User-visible detail belongs in `context`, never in `code`.
#[must_use]
pub fn err(code: &str, context: Option<&str>) -> Vec<u8> {
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
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: false,
            error: Some(error),
            data_type: fbs::Payload::NONE,
            data: None,
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
        Ok(Err(e)) => err_never_unwind(&e.code, e.context.as_deref()),
        Err(panic) => err_never_unwind(INTERNAL_PANIC, Some(&panic_message(panic.as_ref()))),
    }
}

/// Build an error `Envelope` without ever unwinding.
///
/// `err` builds a small in-memory `FlatBuffers` buffer, so a panic here is unreachable in
/// practice — but a panic backstop must give a hard guarantee, not a probabilistic one. If
/// `err` ever panics, fall back to the pre-serialised [`PANIC_FALLBACK_ENVELOPE`]. The only
/// remaining failure mode is allocation failure, which aborts the process rather than
/// unwinding — so no panic can cross the C ABI through this path.
fn err_never_unwind(code: &str, context: Option<&str>) -> Vec<u8> {
    catch_unwind(|| err(code, context)).unwrap_or_else(|_| PANIC_FALLBACK_ENVELOPE.to_vec())
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
        let buf = ok_repo_handle(0xdead_beef_cafe_1234, 7);
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert!(env.error().is_none());
        assert_eq!(env.data_type(), fbs::Payload::RepoHandle);
        let rh = env.data_as_repo_handle().expect("RepoHandle payload must be present");
        assert_eq!(rh.handle(), 0xdead_beef_cafe_1234);
        assert_eq!(rh.session_id(), 7);
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
            new_op_id: zanshin_jj::OperationId("abc123".to_owned()),
            new_change_ids: vec![zanshin_jj::ChangeId("qpvuntsm".to_owned())],
            abandoned_change_ids: vec![
                zanshin_jj::ChangeId("rlvkpnrz".to_owned()),
                zanshin_jj::ChangeId("zsuskuln".to_owned()),
            ],
            working_copy_change_id: zanshin_jj::ChangeId("qpvuntsm".to_owned()),
        };
        let buf = ok_mutation_result(&r);
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
    }

    fn sample_mutation_result() -> zanshin_jj::MutationResult {
        zanshin_jj::MutationResult {
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
        let buf = ok_absorb_result(&r);
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
        let buf = ok_absorb_result(&r);
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
    }

    #[test]
    fn err_never_unwind_matches_err_on_normal_input() {
        assert_eq!(
            err_never_unwind("jj.repo_not_found", Some("/x")),
            err("jj.repo_not_found", Some("/x"))
        );
    }
}
