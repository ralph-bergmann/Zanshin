// SPDX-License-Identifier: MIT

//! `zanshin_file_track` / `zanshin_file_untrack` — the two working-copy tracking wrappers
//! (Story 9.22) — `zanshin_file_chmod` (Story 9.13), and `zanshin_file_edit` /
//! `zanshin_file_delete` (Story 9.44).
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the result into a
//! `FlatBuffers` `Envelope`. The handle is borrowed (not consumed). Split from `file.rs` — the
//! four file READ wrappers with their own `FileError` mapper — exactly as `bookmark_ops.rs` is
//! split from `bookmarks.rs`: one module per error taxonomy, so the whole `MutateError` surface
//! keeps landing in `repo.rs::map_mutate_err`.
//!
//! Transport follows ADR-0001: both take a LIST of paths (plus, for track, a flag), so both
//! cross as request BUFFERS. The two result payloads share ONE `SnapshotStats` builder.

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{SnapshotStats, TrackResult, UntrackResult, UntrackedReason};

use crate::envelope::{
    build_mutation_result, catch, expect_request_kind, finish_envelope, invalid_request, missing_field,
    ok_mutation_result, precondition_envelope, reject_null_request, session_from_handle, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::git::build_export_failures;
use crate::repo::map_mutate_err;

// ── Request-buffer readers ───────────────────────────────────────────────────
//
// Same discipline as every other noun module's readers: `data`/`len` describe a caller-owned
// buffer Dart builds and frees itself; Rust borrows it for the call only. Each reader builds
// its OWN byte slice in its own scope and returns an OWNED struct, so the unbounded lifetime
// `std::slice::from_raw_parts` produces provably cannot outlive the call.

/// Owned Rust form of a `FileTrackRequest` buffer. An ABSENT `paths` vector becomes an EMPTY
/// `Vec`: the jj layer refuses an empty list with the one canonical message (clap's
/// `required = true`), so a second, reader-level refusal would give one wire state two
/// different `context` strings.
struct FileTrackRequestOwned {
    paths: Vec<String>,
    include_ignored: bool,
}

/// Owned Rust form of a `FileUntrackRequest` buffer; an absent `paths` vector becomes an empty
/// `Vec` for the same reason as above.
struct FileUntrackRequestOwned {
    paths: Vec<String>,
}

/// Parse a `FileTrackRequest` buffer into an owned [`FileTrackRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileTrackRequest` buffer, or its
///   `kind` is not `FileTrack`.
fn read_file_track_request(data: *const u8, len: usize) -> Result<FileTrackRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::FileTrackRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::FileTrack)?;
    Ok(FileTrackRequestOwned {
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
        include_ignored: req.include_ignored(),
    })
}

/// Parse a `FileUntrackRequest` buffer into an owned [`FileUntrackRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileUntrackRequest` buffer, or its
///   `kind` is not `FileUntrack`.
fn read_file_untrack_request(data: *const u8, len: usize) -> Result<FileUntrackRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::FileUntrackRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::FileUntrack)?;
    Ok(FileUntrackRequestOwned {
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
    })
}

/// Owned Rust form of a `FileChmodRequest` buffer (Story 9.13). `revision` ABSENT is the CLI's
/// `-r` default `@`; an absent `paths` vector becomes an empty `Vec`, which the jj layer refuses.
struct FileChmodRequestOwned {
    executable: bool,
    revision: Option<zanshin_jj::ChangeId>,
    paths: Vec<String>,
}

/// Parse a `FileChmodRequest` buffer into an owned [`FileChmodRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileChmodRequest` buffer, or its
///   `kind` is not `FileChmod`.
fn read_file_chmod_request(data: *const u8, len: usize) -> Result<FileChmodRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::FileChmodRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::FileChmod)?;
    Ok(FileChmodRequestOwned {
        executable: req.executable(),
        revision: req.revision().map(|r| zanshin_jj::ChangeId(r.to_owned())),
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
    })
}

/// Owned Rust form of a `FileEditRequest` buffer (Story 9.44). `revision` ABSENT is the CLI's
/// `-r` default `@`.
struct FileEditRequestOwned {
    revision: Option<zanshin_jj::ChangeId>,
    restore_descendants: bool,
    path: String,
    content: Vec<u8>,
}

/// Parse a `FileEditRequest` buffer into an owned [`FileEditRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileEditRequest` buffer, or its
///   `kind` is not `FileEdit`.
/// - `jj.invalid_input` — `path` or `content` is absent (an empty `content` is an empty file).
fn read_file_edit_request(data: *const u8, len: usize) -> Result<FileEditRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::FileEditRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::FileEdit)?;
    Ok(FileEditRequestOwned {
        revision: req.revision().map(|r| zanshin_jj::ChangeId(r.to_owned())),
        restore_descendants: req.restore_descendants(),
        path: req.path().ok_or_else(|| missing_field("path"))?.to_owned(),
        content: req.content().ok_or_else(|| missing_field("content"))?.bytes().to_vec(),
    })
}

/// Owned Rust form of a `FileDeleteRequest` buffer (Story 9.44). `revision` ABSENT is the CLI's
/// `-r` default `@`; an absent `paths` vector becomes an empty `Vec`, which the jj layer refuses.
struct FileDeleteRequestOwned {
    revision: Option<zanshin_jj::ChangeId>,
    restore_descendants: bool,
    paths: Vec<String>,
}

/// Parse a `FileDeleteRequest` buffer into an owned [`FileDeleteRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileDeleteRequest` buffer, or its
///   `kind` is not `FileDelete`.
fn read_file_delete_request(data: *const u8, len: usize) -> Result<FileDeleteRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::FileDeleteRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::FileDelete)?;
    Ok(FileDeleteRequestOwned {
        revision: req.revision().map(|r| zanshin_jj::ChangeId(r.to_owned())),
        restore_descendants: req.restore_descendants(),
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
    })
}

// ── Payload builders ─────────────────────────────────────────────────────────

/// Build the `SnapshotStats` table into `b` and return its offset — the ONE construction site
/// both result payloads (and Story 9.26) share.
///
/// Children before parents: each `UntrackedPath`'s string and union arm are built before its
/// table, the vectors after their elements.
pub(crate) fn build_snapshot_stats<'a>(
    b: &mut FlatBufferBuilder<'a>,
    s: &SnapshotStats,
) -> flatbuffers::WIPOffset<fbs::SnapshotStats<'a>> {
    let untracked: Vec<_> = s
        .untracked
        .iter()
        .map(|u| {
            let path = b.create_string(&u.path);
            let (reason_type, reason) = match u.reason {
                UntrackedReason::FileTooLarge { size, max_size } => (
                    fbs::UntrackedReason::FileTooLarge,
                    fbs::FileTooLarge::create(b, &fbs::FileTooLargeArgs { size, max_size }).as_union_value(),
                ),
                UntrackedReason::FileNotAutoTracked => (
                    fbs::UntrackedReason::FileNotAutoTracked,
                    fbs::FileNotAutoTracked::create(b, &fbs::FileNotAutoTrackedArgs {}).as_union_value(),
                ),
            };
            fbs::UntrackedPath::create(
                b,
                &fbs::UntrackedPathArgs {
                    path: Some(path),
                    reason_type,
                    reason: Some(reason),
                },
            )
        })
        .collect();
    let untracked = b.create_vector(&untracked);
    let invalid: Vec<_> = s.invalid_utf8_paths.iter().map(|p| b.create_string(p)).collect();
    let invalid = b.create_vector(&invalid);
    fbs::SnapshotStats::create(
        b,
        &fbs::SnapshotStatsArgs {
            untracked: Some(untracked),
            invalid_utf8_paths: Some(invalid),
        },
    )
}

/// Serialise a [`TrackResult`] into a finished `Envelope<TrackResult>` buffer.
fn track_result_to_envelope(r: &TrackResult, report: &crate::envelope::CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let mutation = build_mutation_result(&mut b, &r.mutation);
    let stats = build_snapshot_stats(&mut b, &r.snapshot_stats);
    let table = fbs::TrackResult::create(
        &mut b,
        &fbs::TrackResultArgs {
            mutation: Some(mutation),
            num_rebased: r.num_rebased,
            snapshot_stats: Some(stats),
        },
    );
    finish_envelope(b, fbs::Payload::TrackResult, Some(table.as_union_value()), report)
}

/// Serialise an [`UntrackResult`] into a finished `Envelope<UntrackResult>` buffer.
fn untrack_result_to_envelope(r: &UntrackResult, report: &crate::envelope::CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let mutation = build_mutation_result(&mut b, &r.mutation);
    let unmatched: Vec<_> = r.unmatched_paths.iter().map(|p| b.create_string(p)).collect();
    let unmatched = b.create_vector(&unmatched);
    let stats = build_snapshot_stats(&mut b, &r.snapshot_stats);
    let bookmarks = build_export_failures(&mut b, &r.failed_bookmarks);
    let tags = build_export_failures(&mut b, &r.failed_tags);
    let table = fbs::UntrackResult::create(
        &mut b,
        &fbs::UntrackResultArgs {
            mutation: Some(mutation),
            num_rebased: r.num_rebased,
            unmatched_paths: Some(unmatched),
            snapshot_stats: Some(stats),
            failed_bookmarks: Some(bookmarks),
            failed_tags: Some(tags),
        },
    );
    finish_envelope(b, fbs::Payload::UntrackResult, Some(table.as_union_value()), report)
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// Start tracking the working-copy paths matching the requested prefixes, in the repo
/// referenced by `handle` — the CLI's `jj file track [--include-ignored] <paths>`.
///
/// The arguments cross as a `FileTrackRequest` `FlatBuffers` request buffer. `paths` are
/// repo-relative PREFIXES (the fileset DSL is not parsed); `include_ignored` is the CLI's
/// `--include-ignored`. The working copy is locked and snapshotted with the repo's EFFECTIVE
/// `snapshot.*` config, and the operation `track paths` is written UNCONDITIONALLY — even when
/// nothing matched — exactly as the CLI commits it.
///
/// `@` is NOT changed: like the CLI, the verb records the tracked paths only in the
/// working-copy state, and the NEXT verb's pre-verb snapshot moves them into `@` (jj's GH
/// #8298). Returns a `FlatBuffers` `Envelope` carrying a `TrackResult` payload on success; every
/// envelope, ok or error, carries `precondition` (Story 9.26).
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileTrackRequest` buffer, or its `kind`
///   is not `FileTrack`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `paths` is empty (or absent from the buffer), or an entry is the empty
///   string or escapes the workspace (parsed like the CLI's path argument, cwd = the workspace
///   root); refused before the working copy is locked.
/// - `jj.config_error` — the repo's effective jj config no longer reads, or
///   `snapshot.max-new-file-size` has the wrong type (the key in `context`). Operations the
///   pre-verb snapshot committed before the fault stay, as in the CLI (colocated:
///   `import git head`); the partial `precondition` says which.
/// - `jj.no_working_copy` — the workspace has no `@` in the head view; no `context`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
/// - `jj.concurrent_working_copy` — the working copy's recorded tree differs from `@`'s (`@`
///   rewritten without a checkout by a concurrent writer after the pre-verb snapshot); no
///   `context`, nothing is written.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been
/// closed. `0` is detected and returned as `ffi.invalid_handle`. A stale non-zero handle is
/// undefined behaviour; the Dart worker's Model-A handle table (Story 3.9) makes a stale
/// handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.FileTrackRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_file_track(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_file_track", handle);
    let buf = catch(|| {
        let req = read_file_track_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.file_track(&req.paths, req.include_ignored);
        precondition_envelope(&mut session.repo, result, map_mutate_err, track_result_to_envelope)
    });
    vec_into_token(buf)
}

/// Stop tracking the working-copy paths matching the requested prefixes, in the repo referenced
/// by `handle` — the CLI's `jj file untrack <paths>`.
///
/// The arguments cross as a `FileUntrackRequest` `FlatBuffers` request buffer; `paths` as for
/// `zanshin_file_track`. The matched entries are removed from `@` (a rewrite: same change id,
/// descendants rebased) and the working-copy state is reset WITHOUT touching a file — the files
/// stay on disk — and the operation `untrack paths` is written unconditionally. In a COLOCATED
/// workspace the git index's intent-to-add entries are updated and jj's refs exported in the
/// same operation; per-ref export failures ride `UntrackResult.failed_bookmarks`/`failed_tags`,
/// never an error envelope. Requested paths with no entry in `@` ride
/// `UntrackResult.unmatched_paths`.
///
/// Returns a `FlatBuffers` `Envelope` carrying an `UntrackResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileUntrackRequest` buffer, or its `kind`
///   is not `FileUntrack`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `paths` is empty (or absent from the buffer), or an entry is the empty
///   string or escapes the workspace (parsed like the CLI's path argument, cwd = the workspace
///   root); refused before the working copy is locked.
/// - `jj.config_error` — the repo's effective jj config no longer reads, `snapshot.auto-track` is
///   not a valid fileset, or `snapshot.max-new-file-size` has the wrong type. Operations the
///   pre-verb snapshot committed before the fault stay, as in the CLI (colocated:
///   `import git head`); the partial `precondition` says which.
/// - `jj.no_working_copy` — the workspace has no `@` in the head view; no `context`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
/// - `jj.concurrent_working_copy` — the working copy's recorded tree differs from `@`'s (`@`
///   rewritten without a checkout by a concurrent writer after the pre-verb snapshot); no
///   `context`, nothing is written.
/// - `jj.path_not_ignored` — matched paths are not ignored, so the next snapshot would re-add
///   them; every offending path in `context`, joined by `\n`. No operation is written and the
///   working-copy state is unchanged.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_file_track`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.FileUntrackRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_file_untrack(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_file_untrack", handle);
    let buf = catch(|| {
        let req = read_file_untrack_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.file_untrack(&req.paths);
        precondition_envelope(&mut session.repo, result, map_mutate_err, untrack_result_to_envelope)
    });
    vec_into_token(buf)
}

/// Set (`executable` true) or clear the executable bit of the files matching the requested
/// prefixes in one revision of the repo referenced by `handle` — the CLI's `jj file chmod x|n
/// <paths> [-r]` (Story 9.13).
///
/// The arguments cross as a `FileChmodRequest` `FlatBuffers` request buffer: `revision` absent is
/// `-r`'s default `@`, else a reverse-hex change id; `paths` as for `zanshin_file_track`. Every
/// matching entry must be a file, or a conflict whose every side is a file — each file side takes
/// the bit. The revision is rewritten (descendants rebased) as `make paths executable in commit
/// <hex>` / `make paths non-executable in commit <hex>`; the rewrite is always recorded, so the
/// operation is always written, as in the CLI. A path that matches nothing warns
/// `jj.paths_unmatched`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileChmodRequest` buffer, or its `kind`
///   is not `FileChmod`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `paths` is empty or absent (before the pre-verb snapshot), an entry is
///   the empty string or escapes the workspace, or a matching entry is not a file ("Found neither
///   a file nor a conflict at '<path>'.") or a conflict with a non-file side ("Some of the sides
///   of the conflict are not files at '<path>'."); nothing is written.
/// - `jj.change_not_found` — `revision` is malformed, absent, only-hidden or divergent.
/// - `jj.revset_resolution_error` — no `revision` in a workspace without a working-copy commit
///   ("Workspace `<name>` doesn't have a working-copy commit").
/// - `jj.immutable` — the revision is immutable (the root included); hints as for every rewrite.
/// - `jj.config_error` — the effective config no longer reads, or `immutable_heads()` does not
///   resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_file_track`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.FileChmodRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_file_chmod(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_file_chmod", handle);
    let buf = catch(|| {
        let req = read_file_chmod_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session
            .repo
            .file_chmod(req.executable, req.revision.as_ref(), &req.paths);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Replace one file's content in one revision of the repo referenced by `handle`, without
/// touching the working copy — the CLI's `jj file edit [-r] [--restore-descendants] <path>`
/// (Story 9.44), with the request's `content` in place of the editor's saved buffer.
///
/// The arguments cross as a `FileEditRequest` `FlatBuffers` request buffer: `revision` absent is
/// `-r`'s default `@`, else a reverse-hex change id; `path` one path, parsed as the CLI parses it
/// from the workspace root (`""` the root); `content` the new bytes (empty = an empty file). The
/// CLI's mechanism runs: a temporary sparse working copy holding only `path`, checked out from
/// the revision (a conflict materialized in `ui.conflict-marker-style`), `content` written,
/// snapshotted — an absent path becomes a new non-executable file, a file keeps its executable
/// bit, conflict markers parse back. An unchanged tree writes no operation (`new_op_id` is the
/// pre-call head); otherwise the revision is rewritten (descendants rebased, or reparented with
/// `restore_descendants`) as `edit file <path> in commit <hex>`.
///
/// Deliberate divergence: a path below an existing non-directory is refused with Zanshin's own
/// text, where the CLI's editor either cannot save (no change) or, creating the directory, makes
/// jj-lib replace that file with a directory. Missing parent directories are created, as a
/// directory-creating editor would; an existing entry is never replaced.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileEditRequest` buffer, or its `kind`
///   is not `FileEdit`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `path` or `content` is absent (`<field> is required`, before the
///   pre-verb snapshot), `path` is malformed or escapes the workspace, or names a directory
///   ("Path is a directory: <path>"), a symlink or submodule ("Path '<path>' is not a regular
///   file") or a conflict with a non-file side ("Path '<path>' has a non-file conflict and cannot
///   be edited") — the CLI's texts — or lies below an existing non-directory ("Failed to edit
///   file: '<ancestor>' is not a directory", the divergence above); nothing is written.
/// - `jj.change_not_found` — `revision` is malformed, absent, only-hidden or divergent.
/// - `jj.revset_resolution_error` — no `revision` in a workspace without a working-copy commit
///   ("Workspace `<name>` doesn't have a working-copy commit").
/// - `jj.immutable` — the revision is immutable (the root included), even when nothing would
///   change; hints as for every rewrite.
/// - `jj.config_error` — the effective config no longer reads, `ui.conflict-marker-style` is not
///   a style name, or `immutable_heads()` does not resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib or temporary-directory failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_file_track`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.FileEditRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_file_edit(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_file_edit", handle);
    let buf = catch(|| {
        let req = read_file_edit_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session
            .repo
            .file_edit(req.revision.as_ref(), req.restore_descendants, &req.path, &req.content);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Remove the entries matching the requested prefixes from one revision of the repo referenced
/// by `handle` — the CLI's `jj file delete [-r] [--restore-descendants] <paths>` (Story 9.44).
///
/// The arguments cross as a `FileDeleteRequest` `FlatBuffers` request buffer: `revision` and
/// `restore_descendants` as for `zanshin_file_edit`, `paths` as for `zanshin_file_track`. Every
/// matching entry is removed, conflicts included; a path that matches nothing warns
/// `jj.paths_unmatched`. An unchanged tree writes no operation (`new_op_id` is the pre-call
/// head); otherwise the revision is rewritten (descendants rebased, or reparented with
/// `restore_descendants`) as `delete paths in commit <hex>`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileDeleteRequest` buffer, or its
///   `kind` is not `FileDelete`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `paths` is empty or absent (before the pre-verb snapshot), or an entry
///   is the empty string or escapes the workspace; nothing is written.
/// - `jj.change_not_found` — `revision` is malformed, absent, only-hidden or divergent.
/// - `jj.revset_resolution_error` — no `revision` in a workspace without a working-copy commit
///   ("Workspace `<name>` doesn't have a working-copy commit").
/// - `jj.immutable` — the revision is immutable (the root included), even when nothing would
///   change; hints as for every rewrite.
/// - `jj.config_error` — the effective config no longer reads, or `immutable_heads()` does not
///   resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_file_track`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.FileDeleteRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_file_delete(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_file_delete", handle);
    let buf = catch(|| {
        let req = read_file_delete_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session
            .repo
            .file_delete(req.revision.as_ref(), req.restore_descendants, &req.paths);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}
