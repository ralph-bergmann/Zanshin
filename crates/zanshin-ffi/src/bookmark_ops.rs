// SPDX-License-Identifier: MIT

//! `zanshin_bookmark_*` — the two bookmark MUTATION wrappers (Story 9.8): `create` and
//! `delete`.
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the result into a
//! `FlatBuffers` `Envelope`. The handle is borrowed (not consumed). Split from
//! `bookmarks.rs` — the read wrapper with its own `BookmarkError` mapper — exactly as
//! `git.rs` is split from `remotes.rs`: one module per error taxonomy, so the whole
//! `MutateError` surface keeps landing in `repo.rs::map_mutate_err` and never grows a
//! second, desyncable spelling.
//!
//! Both verbs return the shipped `MutationResult` payload; neither adds a `Payload` union
//! member. Transport follows ADR-0001: both take a LIST of strings (plus, for `create`, a
//! distinguishably-ABSENT `revision`), so both cross as request BUFFERS rather than as
//! `CString`s.

use flatbuffers::VerifierOptions;
use tracing::debug;
use zanshin_jj::ChangeId;

use crate::envelope::{
    catch, expect_request_kind, invalid_request, ok_mutation_result, precondition_envelope, reject_null_request,
    session_from_handle, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

// ── Request-buffer readers ───────────────────────────────────────────────────
//
// Same discipline as `repo.rs`'s, `file.rs`'s and `git.rs`'s readers: `data`/`len` describe
// a caller-owned buffer Dart builds and frees itself; Rust borrows it for the call only.
// Each reader builds its OWN byte slice in its own scope and returns an OWNED struct, so
// the unbounded lifetime `std::slice::from_raw_parts` produces provably cannot outlive the
// call.

/// Owned Rust form of a `BookmarkCreateRequest` buffer.
///
/// An ABSENT `names` vector becomes an EMPTY `Vec` rather than a reader-level refusal: the
/// jj layer already refuses an empty name list with the one canonical message (clap's
/// `required = true`), and duplicating that refusal here would give one wire state two
/// different `context` strings. `revision` stays `Option` — absence is what applies the
/// CLI's `-r` default `@`.
struct BookmarkCreateRequestOwned {
    names: Vec<String>,
    revision: Option<ChangeId>,
}

/// Owned Rust form of a `BookmarkDeleteRequest` buffer. Its `names` are string PATTERNS, and
/// an absent vector becomes an empty `Vec` for the same reason as above.
struct BookmarkDeleteRequestOwned {
    names: Vec<String>,
}

/// Parse a `BookmarkCreateRequest` buffer into an owned [`BookmarkCreateRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkCreateRequest` buffer, or its
///   `kind` is not `BookmarkCreate`. The tag is what stops a create buffer from reaching
///   `zanshin_bookmark_delete`, whose `names` are GLOB-by-default patterns.
fn read_bookmark_create_request(data: *const u8, len: usize) -> Result<BookmarkCreateRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::BookmarkCreateRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::BookmarkCreate)?;
    Ok(BookmarkCreateRequestOwned {
        names: req.names().into_iter().flatten().map(ToOwned::to_owned).collect(),
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
    })
}

/// Parse a `BookmarkDeleteRequest` buffer into an owned [`BookmarkDeleteRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkDeleteRequest` buffer, or its
///   `kind` is not `BookmarkDelete`.
fn read_bookmark_delete_request(data: *const u8, len: usize) -> Result<BookmarkDeleteRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::BookmarkDeleteRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::BookmarkDelete)?;
    Ok(BookmarkDeleteRequestOwned {
        names: req.names().into_iter().flatten().map(ToOwned::to_owned).collect(),
    })
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// Create local bookmarks pointing at one revision, in the repo referenced by `handle` — the
/// CLI's `jj bookmark create`.
///
/// The arguments cross as a `BookmarkCreateRequest` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern): `revision` must be distinguishably ABSENT, which is what applies
/// the CLI's `-r` default `@` (snapshotted first, as in the CLI — Story 9.26). `names` are
/// EXACT, DECODED bookmark names, not CLI argument text: revset quoting is
/// terminal input syntax the GUI replaces (ADR-0003).
///
/// Both per-name preconditions run in ARGUMENT order and are FAIL-FAST, as in the CLI: a run
/// whose second name already exists creates NOTHING and writes no operation.
///
/// Unlike the CLI a created bookmark is never AUTO-TRACKED — that needs `track_remote_bookmark`
/// (Story 9.11). Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on
/// success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkCreateRequest` buffer, or its `kind`
///   is not `BookmarkCreate`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `names` is empty (or absent from the buffer), or a name is the
///   empty string.
/// - `jj.change_not_found` — `revision` is malformed, carried by no VISIBLE commit (unknown
///   or only-hidden), or divergent; the id in `context`. An ABSENT `revision` is not an
///   error — it is what applies the CLI's `-r` default `@`. An explicitly present EMPTY
///   string is a VALUE, not an absence, and lands here.
/// - `jj.bookmark_exists` — a name is already a local bookmark; the name in `context`.
/// - `jj.bookmark_tracked_remote_exists` — a name's local bookmark is absent but it still has
///   a tracked remote bookmark; the name in `context`.
/// - `jj.config_error` — the repo's effective jj config stack changed under the open handle and no
///   longer reads (Story 9.27 — the pre-verb settings refresh); nothing is written.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been
/// closed. `0` is detected and returned as `ffi.invalid_handle`. A stale non-zero handle is
/// undefined behaviour; the Dart worker's Model-A handle table (Story 3.9) makes a stale
/// handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.BookmarkCreateRequestObjectBuilder(...).toBytes()`); Rust only borrows it
/// for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_bookmark_create(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmark_create", handle);
    let buf = catch(|| {
        let req = read_bookmark_create_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.bookmark_create(&req.names, req.revision.as_ref());
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Delete the local bookmarks matching the requested patterns, in the repo referenced by
/// `handle` — the CLI's `jj bookmark delete`.
///
/// The arguments cross as a `BookmarkDeleteRequest` `FlatBuffers` request buffer. Its `names`
/// are string PATTERNS, passed through verbatim (FR-JJ-17) and unioned: `exact:`, `glob:`,
/// `regex:`, `substring:` and the `~`/`&`/`|` operators all work. **A BARE pattern is a GLOB,
/// not an exact name** — deleting a bookmark whose name contains `*`, `?` or `[` requires
/// `exact:"…"`.
///
/// Matching NOTHING is a SUCCESS: no operation is written and `MutationResult.new_op_id`
/// carries the PRE-CALL op-log head, which is the machine-readable form of the CLI's "No
/// bookmarks to delete." A TRACKED `name@remote` SURVIVES the delete by design and keeps
/// showing up in `zanshin_bookmarks` — jj's "deleted, propagates on the next push" state.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkDeleteRequest` buffer, or its `kind`
///   is not `BookmarkDelete`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `names` is empty (or absent from the buffer), or a pattern does not
///   parse; jj-lib's reason in `context`.
/// - `jj.config_error` — the repo's effective jj config stack changed under the open handle and no
///   longer reads (Story 9.27 — the pre-verb settings refresh); nothing is written.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_bookmark_create`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.BookmarkDeleteRequestObjectBuilder(...).toBytes()`); Rust only borrows it
/// for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_bookmark_delete(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmark_delete", handle);
    let buf = catch(|| {
        let req = read_bookmark_delete_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.bookmark_delete(&req.names);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}
