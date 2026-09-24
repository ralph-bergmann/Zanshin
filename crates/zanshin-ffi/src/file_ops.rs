// SPDX-License-Identifier: MIT

//! `zanshin_file_track` / `zanshin_file_untrack` — the two working-copy tracking wrappers
//! (Story 9.22).
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
    build_mutation_result, catch, expect_request_kind, finish_envelope, invalid_request, precondition_envelope,
    reject_null_request, session_from_handle, FfiErrorObj,
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
