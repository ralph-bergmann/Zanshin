// SPDX-License-Identifier: MIT

//! `zanshin_workspace_list` / `zanshin_workspace_root` — the two workspace READ verbs
//! (Story 9.7) — and `zanshin_workspace_add` / `zanshin_workspace_update_stale`, the two
//! workspace MUTATIONS of Story 9.23, plus `zanshin_workspace_forget` / `_rename` / `_remove`
//! (Story 9.13).
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the result into a
//! `FlatBuffers` `Envelope`. The handle is borrowed (not consumed), and neither read verb opens
//! a transaction: only `zanshin_workspace_list`'s pre-verb snapshot (Story 9.26) may write an
//! operation (`zanshin_workspace_root` runs none, like the CLI's), and a head load reconciling
//! divergent operation heads in this workspace, as the CLI's does.
//!
//! The two verbs cross the boundary DIFFERENTLY, mirroring the CLI's own argument arity:
//! `zanshin_workspace_list` is handle-only, because `jj workspace list` takes no argument at all
//! (its lone `-T/--template` flag is rendering); `zanshin_workspace_root` takes a request BUFFER,
//! because its `--name` must be distinguishably ABSENT — that absence is what applies the CLI's
//! documented default, the current workspace.
//!
//! They are also asymmetric when no path can be reported, deliberately: a `WorkspaceEntry`'s
//! `root` degrades to absent while `zanshin_workspace_root` refuses with one of two codes; a stale
//! recorded path is reported by both, with a warning from `zanshin_workspace_root`. See
//! `zanshin_jj::workspace`'s module doc for why that is parity rather than an inconsistency.

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{
    SparseInheritance, StaleRecovery, WorkspaceAddResult, WorkspaceEntry, WorkspaceError, WorkspaceRemoveResult,
};

use crate::envelope::{
    build_mutation_result, catch, expect_request_kind, finish_envelope, invalid_request, map_precondition_err,
    missing_field, ok_mutation_result, precondition_envelope, reject_null_request, session_from_handle, CallReport,
    FfiErrorObj, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_WORKSPACE_NOT_FOUND, JJ_WORKSPACE_NO_RECORDED_PATH,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;
use crate::snapshot::{build_checkout_stats, build_stale_recovery};

/// Maps a [`WorkspaceError`] onto its AR-P-4 code; user data always rides in `context`.
///
/// The two refusal variants get two codes rather than one, because their remedies differ — the
/// same test `jj.remote_exists` passed in Story 9.5.
fn map_workspace_err(e: WorkspaceError) -> FfiErrorObj {
    let (code, context) = match e {
        WorkspaceError::Precondition(e) => return map_precondition_err(e),
        WorkspaceError::NotFound { name } => (JJ_WORKSPACE_NOT_FOUND, name),
        WorkspaceError::NoRecordedPath { name } => (JJ_WORKSPACE_NO_RECORDED_PATH, name),
        WorkspaceError::Backend(reason) => (JJ_JJ_LIB_ERROR, reason),
    };
    FfiErrorObj {
        report: None,
        hints: Vec::new(),
        code: code.to_owned(),
        context: Some(context),
    }
}

// ── Request-buffer reader ────────────────────────────────────────────────────
//
// Same discipline as `commit_views.rs`'s, `file.rs`'s and `git.rs`'s readers: `data`/`len`
// describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for the call
// only. The reader builds its OWN byte slice in its own scope and returns an OWNED struct, so
// the unbounded lifetime `std::slice::from_raw_parts` produces provably cannot outlive the call.

/// Owned Rust form of a `WorkspaceRootRequest` buffer. `name` is `Option<String>` — an ABSENT
/// field is the wire form of "the user did not supply `--name`", which selects the CURRENT
/// workspace; an explicitly EMPTY string is a VALUE and refuses as `jj.workspace_not_found`.
struct WorkspaceRootRequestOwned {
    name: Option<String>,
}

/// Parse a `WorkspaceRootRequest` buffer into an owned [`WorkspaceRootRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceRootRequest` buffer, or its
///   `kind` is not `WorkspaceRoot`.
fn read_workspace_root_request(data: *const u8, len: usize) -> Result<WorkspaceRootRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::WorkspaceRootRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::WorkspaceRoot)?;
    Ok(WorkspaceRootRequestOwned {
        name: req.name().map(ToOwned::to_owned),
    })
}

/// Owned Rust form of a `WorkspaceAddRequest` buffer (Story 9.23). `name` is `Option<String>`:
/// ABSENT is the CLI's default (the destination's final component), an explicitly EMPTY name is
/// a value. `colocate` folds the CLI's two flags into one tri-state.
struct WorkspaceAddRequestOwned {
    destination: String,
    name: Option<String>,
    revisions: Vec<String>,
    message_paragraphs: Vec<String>,
    colocate: Option<bool>,
    sparse: SparseInheritance,
}

/// Parse a `WorkspaceAddRequest` buffer into an owned [`WorkspaceAddRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceAddRequest` buffer, its
///   `kind` is not `WorkspaceAdd`, or its `sparse_patterns` byte is outside the enum.
/// - `jj.invalid_input` — `destination` is absent, or both `colocate` and `no_colocate` are set
///   (clap's `conflicts_with`).
fn read_workspace_add_request(data: *const u8, len: usize) -> Result<WorkspaceAddRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::WorkspaceAddRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::WorkspaceAdd)?;
    let destination = req
        .destination()
        .ok_or_else(|| missing_field("destination"))?
        .to_owned();
    let colocate = match (req.colocate(), req.no_colocate()) {
        (true, true) => {
            return Err(FfiErrorObj {
                report: None,
                hints: Vec::new(),
                code: JJ_INVALID_INPUT.to_owned(),
                context: Some("colocate and no_colocate cannot be used together".to_owned()),
            })
        }
        (true, false) => Some(true),
        (false, true) => Some(false),
        (false, false) => None,
    };
    let sparse = match req.sparse_patterns() {
        fbs::SparseInheritance::Copy => SparseInheritance::Copy,
        fbs::SparseInheritance::Full => SparseInheritance::Full,
        fbs::SparseInheritance::Empty => SparseInheritance::Empty,
        other => {
            return Err(FfiErrorObj {
                report: None,
                hints: Vec::new(),
                code: crate::envelope::FFI_INVALID_ARGUMENT.to_owned(),
                context: Some(format!("unknown sparse_patterns {other:?}")),
            })
        }
    };
    let strings = |v: Option<flatbuffers::Vector<'_, flatbuffers::ForwardsUOffset<&str>>>| -> Vec<String> {
        v.map(|v| v.iter().map(ToOwned::to_owned).collect()).unwrap_or_default()
    };
    Ok(WorkspaceAddRequestOwned {
        destination,
        name: req.name().map(ToOwned::to_owned),
        revisions: strings(req.revisions()),
        message_paragraphs: strings(req.message_paragraphs()),
        colocate,
        sparse,
    })
}

/// Parse a `WorkspaceNamesRequest` buffer tagged `kind` into its names (Story 9.13); an ABSENT
/// vector is an empty one, which the jj layer reads as forget's default or remove's refusal.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceNamesRequest` buffer, or its
///   `kind` is not `kind`.
fn read_workspace_names_request(
    data: *const u8,
    len: usize,
    kind: fbs::RequestKind,
) -> Result<Vec<String>, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::WorkspaceNamesRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), kind)?;
    Ok(req.names().into_iter().flatten().map(ToOwned::to_owned).collect())
}

/// Parse a `WorkspaceRenameRequest` buffer into its new name (Story 9.13); ABSENT is the empty
/// name, which the jj layer refuses with the CLI's one text.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceRenameRequest` buffer, or its
///   `kind` is not `WorkspaceRename`.
fn read_workspace_rename_request(data: *const u8, len: usize) -> Result<String, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::WorkspaceRenameRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::WorkspaceRename)?;
    Ok(req.new_name().unwrap_or_default().to_owned())
}

// ── Payload builders ─────────────────────────────────────────────────────────

/// Serialise `&[WorkspaceEntry]` into a finished `Envelope<WorkspaceList>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): each row's strings are built before its
/// table, and the outer vector and `WorkspaceList` table come after the loop. `root` is written
/// only when present — null-for-absence is the wire form of "this workspace's path cannot be
/// reported", which is never an error here.
fn workspace_list_to_envelope(entries: &[WorkspaceEntry], report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let offsets: Vec<_> = entries
        .iter()
        .map(|e| {
            let name = b.create_string(&e.name);
            let wc = b.create_string(&e.wc_commit_id.0);
            // `to_string_lossy` is the crate's path→wire rule (`repo.rs:271`): a path is bytes,
            // the wire field is a UTF-8 string, and a lossy rendering beats refusing to answer.
            let root = e.root.as_ref().map(|p| b.create_string(&p.to_string_lossy()));
            fbs::WorkspaceEntry::create(
                &mut b,
                &fbs::WorkspaceEntryArgs {
                    name: Some(name),
                    wc_commit_id: Some(wc),
                    root,
                },
            )
        })
        .collect();
    let vec = b.create_vector(&offsets);
    let table = fbs::WorkspaceList::create(&mut b, &fbs::WorkspaceListArgs { entries: Some(vec) });
    finish_envelope(b, fbs::Payload::WorkspaceList, Some(table.as_union_value()), report)
}

/// Serialise one resolved workspace root into a finished `Envelope<WorkspaceRoot>` buffer.
///
/// Unlike a list row's `root`, this field is always present: the verb refuses rather than
/// reporting an absent path. `report` carries its warnings (`jj.workspace_path_inaccessible`).
fn workspace_root_to_envelope(root: &std::path::Path, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let root_off = b.create_string(&root.to_string_lossy());
    let table = fbs::WorkspaceRoot::create(&mut b, &fbs::WorkspaceRootArgs { root: Some(root_off) });
    finish_envelope(b, fbs::Payload::WorkspaceRoot, Some(table.as_union_value()), report)
}

/// Serialise a [`WorkspaceAddResult`] into a finished `Envelope<WorkspaceAddResult>` buffer
/// (Story 9.23).
fn workspace_add_to_envelope(r: &WorkspaceAddResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let mutation = build_mutation_result(&mut b, &r.mutation);
    let name = b.create_string(&r.workspace_name);
    let root = b.create_string(&r.workspace_root.to_string_lossy());
    let checkout = build_checkout_stats(&mut b, &r.checkout);
    let table = fbs::WorkspaceAddResult::create(
        &mut b,
        &fbs::WorkspaceAddResultArgs {
            mutation: Some(mutation),
            workspace_name: Some(name),
            workspace_root: Some(root),
            git_worktree_created: r.git_worktree_created,
            checkout: Some(checkout),
        },
    );
    finish_envelope(
        b,
        fbs::Payload::WorkspaceAddResult,
        Some(table.as_union_value()),
        report,
    )
}

/// Serialise a [`WorkspaceRemoveResult`] into a finished `Envelope<WorkspaceRemoveResult>` buffer
/// (Story 9.13). Paths cross lossily, the crate's path→wire rule.
fn workspace_remove_to_envelope(r: &WorkspaceRemoveResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let mutation = build_mutation_result(&mut b, &r.mutation);
    let mut paths = |list: &[std::path::PathBuf]| {
        let offsets: Vec<_> = list.iter().map(|p| b.create_string(&p.to_string_lossy())).collect();
        b.create_vector(&offsets)
    };
    let git_worktrees_removed = paths(&r.git_worktrees_removed);
    let directories_removed = paths(&r.directories_removed);
    let table = fbs::WorkspaceRemoveResult::create(
        &mut b,
        &fbs::WorkspaceRemoveResultArgs {
            mutation: Some(mutation),
            git_worktrees_removed: Some(git_worktrees_removed),
            directories_removed: Some(directories_removed),
        },
    );
    finish_envelope(
        b,
        fbs::Payload::WorkspaceRemoveResult,
        Some(table.as_union_value()),
        report,
    )
}

/// Serialise a [`StaleRecovery`] into a finished `Envelope<StaleRecovery>` buffer (Story 9.23).
fn stale_recovery_to_envelope(r: &StaleRecovery, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let table = build_stale_recovery(&mut b, r);
    finish_envelope(b, fbs::Payload::StaleRecovery, Some(table.as_union_value()), report)
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// List every workspace of the repo identified by `handle`, with its working-copy commit and
/// root directory — the CLI's `jj workspace list`.
///
/// Handle-only: the CLI verb takes no argument at all, and its `-T/--template` flag is rendering.
/// Rows come in jj-lib's own `BTreeMap` order (lexicographic by workspace name). A row's `root`
/// is the RECORDED path, reported even when that directory moved or was deleted (jj 0.46); it is
/// ABSENT only when nothing can be reported — no recorded path (a workspace predating jj 0.38.0)
/// or an unreadable store. Neither fails the call; the CLI points at `zanshin_workspace_root` for
/// strict diagnostics. This read writes NO operation of its own.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `WorkspaceList` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.config_error` — the pre-verb snapshot (Story 9.26) found the effective jj config
///   unreadable or a knob it reads wrongly typed (the key in `context`). Operations the snapshot
///   committed before the fault stay, as in the CLI (colocated: `import git head`); the partial
///   `precondition` says which.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
/// - `jj.jj_lib_error` — the head load failed, i.e. the VIEW half could not be read; detail in
///   `context`. No path failure reaches this.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_workspace_list(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_workspace_list", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let entries = session.repo.list_workspaces();
        precondition_envelope(&mut session.repo, entries, map_workspace_err, |v, p| {
            workspace_list_to_envelope(v, p)
        })
    });
    vec_into_token(buf)
}

/// Return one workspace's root directory in the repo identified by `handle` — the CLI's
/// `jj workspace root [--name]`.
///
/// The argument crosses as a `WorkspaceRootRequest` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern), because the CLI's `--name` must be distinguishably ABSENT. Both forms
/// first run the CLI's command start-up — the secure-config fix-up and the effective config — and
/// carry its warnings first: `jj.config_migrated` / `jj.config_copied` / `jj.config_regenerated`,
/// then `jj.config_deprecated`. An absent `name` selects the CURRENT workspace and then reads the
/// workspace loader alone — no repo load, no store read; it returns exactly what
/// `zanshin_jj::Repo::workspace_root` reports. A PRESENT name, even the current workspace's own,
/// also runs the start-up of the CLI's `workspace_helper_no_snapshot` — the alias tables (their
/// warnings next), the `immutable_heads()` / short-prefixes parse and the `trunk()` fallback
/// (`jj.trunk_alias_unresolved`) — then goes through the `WorkspaceStore` and can refuse: the
/// CLI's named path never shortcuts to the loader, and that asymmetry is reproduced rather than
/// smoothed over. An explicitly present EMPTY name is a VALUE, not an absence, and refuses as
/// `jj.workspace_not_found`. The returned path is ABSOLUTE — for a name, the recorded path, not
/// canonicalized (jj 0.46); CWD-relative shortening is the GUI's job. This read runs no pre-verb
/// snapshot and carries no `precondition`; its own head load may reconcile divergent operation
/// heads in this workspace, as the CLI's does.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `WorkspaceRoot` payload on success; a recorded
/// directory that does not exist warns `jj.workspace_path_inaccessible`, the call's last warning
/// — the path is still returned, as the CLI prints it. The warnings ride the ok AND the error
/// envelope.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceRootRequest` buffer, or its `kind`
///   is not `WorkspaceRoot`, i.e. the buffer was built for a different wrapper.
/// - `jj.config_error` — the start-up failed: the config stack does not resolve (either form), or
///   with a name an alias table, `immutable_heads()` or short-prefixes revset does not parse; the
///   reason in `context`.
/// - `jj.workspace_not_found` — no workspace of that name is in the head view; the name in
///   `context`.
/// - `jj.workspace_no_recorded_path` — the workspace exists but the store holds no path for it;
///   the name in `context`.
/// - `jj.jj_lib_error` — the workspace store could not be loaded or read, or the head load
///   failed; with a name also a jj-lib failure of the start-up (the colocation check, the
///   start-up environment, the `trunk()` fallback's head load); detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.WorkspaceRootRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_workspace_root(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_workspace_root", handle);
    let buf = catch(|| {
        let req = read_workspace_root_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let root = session.repo.resolve_workspace_root(req.name.as_deref());
        precondition_envelope(&mut session.repo, root, map_workspace_err, |root, report| {
            workspace_root_to_envelope(root, report)
        })
    });
    vec_into_token(buf)
}

/// Add a workspace to the repo identified by `handle` — the CLI's `jj workspace add` (Story 9.23).
///
/// The arguments cross as a `WorkspaceAddRequest` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern), every CLI argument passed through: `destination` (required, against
/// the current workspace root), `name` (absent → the destination's final component), the
/// repeatable `revisions` revsets and `message_paragraphs`, the two colocation flags and
/// `sparse_patterns`. Runs the pre-verb snapshot of the CURRENT workspace first. Operations in
/// the CLI's order: `add workspace '<name>'`, then `create initial working-copy commit in
/// workspace <name>`, whose finish checks the new `@` out into the destination.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `WorkspaceAddResult` payload on success; a
/// destination without a path separator warns `jj.workspace_in_current_directory`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceAddRequest` buffer, its
///   `kind` is not `WorkspaceAdd`, or `sparse_patterns` is outside the enum.
/// - `jj.invalid_input` — `destination` is absent, both colocation flags are set, the name is
///   empty, the destination has no final component, or `revisions` resolve to no commit ("Empty
///   revision set" — the workspace and its `add workspace` operation exist by then).
/// - `jj.workspace_exists` — a workspace of that name exists; the name in `context`.
/// - `jj.destination_not_empty` — the destination is a file or a non-empty directory.
/// - `jj.git_worktree_failed` — the Git worktree could not be created; jj-lib's text in
///   `context`. The created directory stays, as in the CLI.
/// - `jj.revset_parse_error` / `jj.revset_resolution_error` — a `revisions` entry.
/// - `jj.config_error` — the pre-verb snapshot found the config unreadable or a knob it reads
///   wrongly typed, or `git.colocate` / `git.executable-path` is wrongly typed; key in `context`.
///   Or (a non-empty message, Story 9.51) `templates.commit_trailers` does not parse or render —
///   the CLI's text in `context`; the workspace and its `add workspace` operation exist by then, as
///   in the CLI.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the current working copy stale.
/// - `jj.no_working_copy` — the new workspace has no `@` to lock for its sparse patterns.
/// - `jj.concurrent_working_copy` — the new working copy's recorded tree is not its `@`'s.
/// - `jj.jj_lib_error` — the directory could not be created, or any other jj-lib failure.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.WorkspaceAddRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_workspace_add(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_workspace_add", handle);
    let buf = catch(|| {
        let req = read_workspace_add_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.workspace_add(
            &req.destination,
            req.name.as_deref(),
            &req.revisions,
            &req.message_paragraphs,
            req.colocate,
            req.sparse,
        );
        precondition_envelope(&mut session.repo, result, map_mutate_err, workspace_add_to_envelope)
    });
    vec_into_token(buf)
}

/// Bring the stale working copy of the repo identified by `handle` up to date — the CLI's
/// `jj workspace update-stale` (Story 9.23).
///
/// Handle-only: the CLI verb takes no argument. Runs NO pre-verb snapshot — it is the recovery:
/// the working copy is snapshotted at its own operation, a stale one is checked out onto the
/// head's `@` (after a `reset git head` operation in a colocated workspace, without an operation
/// of its own), a lost operation gets jj-lib's `recovery commit`, and the full snapshot runs
/// last. The envelope's `precondition` is that LAST snapshot's report.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `StaleRecovery` payload on success; the merged
/// snapshot stats warn `jj.snapshot_files_refused` / `jj.snapshot_paths_not_utf8`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.concurrent_working_copy` — the working copy's recorded tree is not the stale `@`'s.
/// - `jj.config_error` — the config does not read, or a value a snapshot reads is wrong-typed.
/// - `jj.stale_working_copy` — another operation made the working copy stale again before the
///   trailing snapshot.
/// - `jj.jj_lib_error` — the workspace has no `@`, or any underlying jj-lib failure.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_workspace_update_stale(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_workspace_update_stale", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.workspace_update_stale();
        precondition_envelope(&mut session.repo, result, map_mutate_err, stale_recovery_to_envelope)
    });
    vec_into_token(buf)
}

/// Stop tracking workspaces in the repo identified by `handle` — the CLI's `jj workspace forget`
/// (Story 9.13).
///
/// The arguments cross as a `WorkspaceNamesRequest` (`kind` `WorkspaceForget`); `names` empty or
/// absent forgets the CURRENT workspace. A name no workspace has warns
/// `jj.workspace_names_unmatched`; with none left nothing is written. The rest leave the view in
/// one operation (`forget workspace <n>` / `forget workspaces <a>, <b>`); their recorded paths
/// stay in the workspace store, their files on disk. Each one's Git worktree is unlinked
/// (`WorkspaceRemoveResult.git_worktrees_removed`; a failure warns `jj.git_worktree_unlink_failed`).
/// Forgetting the current workspace warns `jj.workspace_no_longer_exists` and leaves
/// `working_copy_change_id` absent.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `WorkspaceRemoveResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceNamesRequest` buffer, or its
///   `kind` is not `WorkspaceForget`.
/// - `jj.config_error` — the effective config no longer reads, `immutable_heads()` does not
///   resolve, or `git.executable-path` does not read (after the operation).
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — the workspace store or any other jj-lib step failed.
///
/// # Safety
/// Same handle contract as `zanshin_workspace_add`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.WorkspaceNamesRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_workspace_forget(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_workspace_forget", handle);
    let buf = catch(|| {
        let names = read_workspace_names_request(data, len, fbs::RequestKind::WorkspaceForget)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.workspace_forget(&names);
        precondition_envelope(&mut session.repo, result, map_mutate_err, workspace_remove_to_envelope)
    });
    vec_into_token(buf)
}

/// Rename the CURRENT workspace of the repo identified by `handle` — the CLI's `jj workspace
/// rename` (Story 9.13).
///
/// The argument crosses as a `WorkspaceRenameRequest`. The view, the workspace store and the
/// working copy are renamed in one operation, `Renamed workspace '<old>' to '<new>'`, committed
/// without a finish (no Git export, no identity warning); the handle then runs as the renamed
/// workspace. The current name writes nothing.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceRenameRequest` buffer, or its
///   `kind` is not `WorkspaceRename`.
/// - `jj.invalid_input` — `new_name` is empty or absent ("New workspace name cannot be empty"),
///   before the pre-verb snapshot.
/// - `jj.no_working_copy` — the current workspace has no `@` in the view: the CLI's refusal "The
///   current workspace '<name>' is not tracked in the repo.", reported without that text (no
///   `context`).
/// - `jj.workspace_exists` — another workspace has the name; the name in `context`.
/// - `jj.concurrent_working_copy` — the working copy's recorded tree is not `@`'s.
/// - `jj.config_error` — the effective config no longer reads.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — the store, the commit or the working-copy finish failed.
///
/// # Safety
/// Same handle contract as `zanshin_workspace_add`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.WorkspaceRenameRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_workspace_rename(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_workspace_rename", handle);
    let buf = catch(|| {
        let new_name = read_workspace_rename_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.workspace_rename(&new_name);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Remove workspaces and delete their directories in the repo identified by `handle` — the CLI's
/// `jj workspace remove` (Story 9.13, new in jj 0.46).
///
/// The arguments cross as a `WorkspaceNamesRequest` (`kind` `WorkspaceRemove`). A name no
/// workspace has warns `jj.workspace_names_unmatched`; with none left nothing is written. Every
/// remaining workspace is checked before anything is written, then snapshotted (its own
/// operation when its files changed), removed from the view in one operation (`remove workspace
/// <n>` / `remove workspaces <a>, <b>`), forgotten in the workspace store, its Git worktree
/// unlinked (`git_worktrees_removed`; a failure warns `jj.git_worktree_unlink_failed`) and its
/// directory deleted (`directories_removed`; a failure warns `jj.workspace_directory_remove_failed`).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `WorkspaceRemoveResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceNamesRequest` buffer, or its
///   `kind` is not `WorkspaceRemove`.
/// - `jj.invalid_input` — `names` is empty or absent (before the pre-verb snapshot), or a
///   workspace cannot be removed: no recorded path, a directory that does not resolve, the
///   repository inside it (`default`), another repository's workspace there, or none loads there
///   — the CLI's texts. The first two and the other-repository refusal carry the hint "Use `jj
///   workspace forget` to stop tracking a workspace without deleting files."; the repository
///   refusal carries none, a load error the CLI's own (none, or its `jj git init` hint). Nothing
///   is written.
/// - `jj.config_error` — the effective config no longer reads, `immutable_heads()` does not
///   resolve, or `git.executable-path` does not read (after the operation).
/// - `jj.stale_working_copy` — the pre-verb snapshot or a target workspace's snapshot found a
///   stale working copy; earlier snapshots stay.
/// - `jj.jj_lib_error` — a workspace load failed internally, or any other jj-lib step.
///
/// # Safety
/// Same handle contract as `zanshin_workspace_add`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.WorkspaceNamesRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_workspace_remove(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_workspace_remove", handle);
    let buf = catch(|| {
        let names = read_workspace_names_request(data, len, fbs::RequestKind::WorkspaceRemove)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.workspace_remove(&names);
        precondition_envelope(&mut session.repo, result, map_mutate_err, workspace_remove_to_envelope)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use flatbuffers::root;
    use zanshin_jj::{CommitId, WorkspaceEntry, WorkspaceError};

    use super::{map_workspace_err, workspace_list_to_envelope, workspace_root_to_envelope};
    use crate::envelope::{CallReport, JJ_JJ_LIB_ERROR, JJ_WORKSPACE_NOT_FOUND, JJ_WORKSPACE_NO_RECORDED_PATH};
    use crate::fbs;

    fn entry(name: &str, root: Option<&str>) -> WorkspaceEntry {
        WorkspaceEntry {
            name: name.to_owned(),
            wc_commit_id: CommitId(format!("{name}-commit")),
            root: root.map(PathBuf::from),
        }
    }

    #[test]
    fn workspace_list_writes_present_and_absent_roots_in_order() {
        let buf = workspace_list_to_envelope(
            &[entry("default", Some("/tmp/ws")), entry("second", None)],
            &CallReport::default(),
        );
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::WorkspaceList);
        let items = env
            .data_as_workspace_list()
            .expect("expected WorkspaceList payload")
            .entries()
            .expect("entries vector");
        assert_eq!(items.len(), 2);
        assert_eq!(items.get(0).name(), Some("default"));
        assert_eq!(items.get(0).wc_commit_id(), Some("default-commit"));
        assert_eq!(items.get(0).root(), Some("/tmp/ws"));
        // Null-for-absence: an unreportable path is an absent field, never an empty string.
        assert_eq!(items.get(1).name(), Some("second"));
        assert_eq!(items.get(1).root(), None);
    }

    #[test]
    fn workspace_list_empty_roundtrips() {
        let buf = workspace_list_to_envelope(&[], &CallReport::default());
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        let payload = env.data_as_workspace_list().expect("expected WorkspaceList payload");
        assert_eq!(payload.entries().map_or(0, |e| e.len()), 0);
    }

    #[test]
    fn workspace_root_roundtrips_with_its_warnings() {
        let warning = zanshin_jj::Warning {
            kind: zanshin_jj::WarningKind::WorkspacePathInaccessible,
            message: "Cannot access workspace path: /tmp/ws/second".to_owned(),
        };
        let buf = workspace_root_to_envelope(&PathBuf::from("/tmp/ws/second"), &CallReport::warnings(vec![warning]));
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::WorkspaceRoot);
        assert_eq!(
            env.data_as_workspace_root().expect("payload").root(),
            Some("/tmp/ws/second")
        );
        let warnings = env.warnings().expect("warnings");
        assert_eq!(warnings.len(), 1);
        assert_eq!(warnings.get(0).code(), Some("jj.workspace_path_inaccessible"));
    }

    fn add_request(colocate: bool, no_colocate: bool, sparse: fbs::SparseInheritance) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
        let destination = b.create_string("../ws2");
        let req = fbs::WorkspaceAddRequest::create(
            &mut b,
            &fbs::WorkspaceAddRequestArgs {
                kind: fbs::RequestKind::WorkspaceAdd,
                destination: Some(destination),
                colocate,
                no_colocate,
                sparse_patterns: sparse,
                ..fbs::WorkspaceAddRequestArgs::default()
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    /// The reader folds the CLI's two colocation flags into one tri-state and maps every
    /// `--sparse-patterns` value (Story 9.23).
    #[test]
    fn the_add_request_reader_maps_the_flags_and_the_sparse_mode() {
        let read = |colocate, no_colocate, sparse| {
            let bytes = add_request(colocate, no_colocate, sparse);
            super::read_workspace_add_request(bytes.as_ptr(), bytes.len()).expect("valid request")
        };
        let req = read(true, false, fbs::SparseInheritance::Empty);
        assert_eq!(req.colocate, Some(true));
        assert_eq!(req.sparse, zanshin_jj::SparseInheritance::Empty);
        assert_eq!(req.destination, "../ws2");
        assert_eq!(req.name, None);
        let req = read(false, true, fbs::SparseInheritance::Full);
        assert_eq!(req.colocate, Some(false));
        assert_eq!(req.sparse, zanshin_jj::SparseInheritance::Full);
        let req = read(false, false, fbs::SparseInheritance::Copy);
        assert_eq!(req.colocate, None);
        assert_eq!(req.sparse, zanshin_jj::SparseInheritance::Copy);
    }

    /// Every recovery outcome crosses the wire as its own enum value (Story 9.23).
    #[test]
    fn every_stale_recovery_outcome_round_trips() {
        use zanshin_jj::{OperationId, SnapshotStats, StaleRecovery, StaleRecoveryOutcome as O};
        for (outcome, wire) in [
            (O::NotStale, fbs::StaleRecoveryOutcome::NotStale),
            (O::Updated, fbs::StaleRecoveryOutcome::Updated),
            (O::Recovered, fbs::StaleRecoveryOutcome::Recovered),
        ] {
            let recovery = StaleRecovery {
                outcome,
                commit_id: None,
                checkout: None,
                git_head_reset_op_id: None,
                snapshot_stats: SnapshotStats::default(),
                op_id: OperationId("head".to_owned()),
            };
            let buf = super::stale_recovery_to_envelope(&recovery, &CallReport::default());
            let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
            let payload = env.data_as_stale_recovery().expect("payload");
            assert_eq!(payload.outcome(), wire);
            assert_eq!(payload.commit_id(), None);
            assert_eq!(payload.op_id(), Some("head"));
        }
    }

    /// Story 9.23's three new refusals, each under its own code — the arms
    /// `zanshin_workspace_add` reaches only on a refused add.
    #[test]
    fn the_workspace_add_refusals_map_to_their_own_codes() {
        use zanshin_jj::MutateError;
        let exists = crate::repo::map_mutate_err(MutateError::WorkspaceExists { name: "ws".to_owned() });
        assert_eq!(
            (exists.code.as_str(), exists.context.as_deref()),
            ("jj.workspace_exists", Some("ws"))
        );
        let busy = crate::repo::map_mutate_err(MutateError::DestinationNotEmpty);
        assert_eq!((busy.code.as_str(), busy.context), ("jj.destination_not_empty", None));
        let worktree = crate::repo::map_mutate_err(MutateError::GitWorktree("git".to_owned()));
        assert_eq!(
            (worktree.code.as_str(), worktree.context.as_deref()),
            ("jj.git_worktree_failed", Some("git"))
        );
        let concurrent = crate::envelope::map_precondition_err(zanshin_jj::PreconditionError::ConcurrentWorkingCopy);
        assert_eq!(
            (concurrent.code.as_str(), concurrent.context),
            ("jj.concurrent_working_copy", None)
        );
    }

    #[test]
    fn every_workspace_error_variant_maps_to_its_own_code() {
        let not_found = map_workspace_err(WorkspaceError::NotFound {
            name: "nosuch".to_owned(),
        });
        assert_eq!(not_found.code, JJ_WORKSPACE_NOT_FOUND);
        assert_eq!(not_found.context, Some("nosuch".to_owned()));

        let no_path = map_workspace_err(WorkspaceError::NoRecordedPath {
            name: "legacy".to_owned(),
        });
        assert_eq!(no_path.code, JJ_WORKSPACE_NO_RECORDED_PATH);
        assert_eq!(no_path.context, Some("legacy".to_owned()));

        let backend = map_workspace_err(WorkspaceError::Backend("boom".to_owned()));
        assert_eq!(backend.code, JJ_JJ_LIB_ERROR);
        assert_eq!(backend.context, Some("boom".to_owned()));
    }
}
