// SPDX-License-Identifier: MIT

//! `zanshin_bookmark_*` — the bookmark MUTATION wrappers: `create` and `delete` (Story 9.8),
//! `move`, `advance` and `rename` (Story 9.19), `set`, `forget`, `track` and `untrack` (Story
//! 9.11).
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the result into a
//! `FlatBuffers` `Envelope`. The handle is borrowed (not consumed). Split from
//! `bookmarks.rs` — the read wrapper with its own `BookmarkError` mapper — exactly as
//! `git.rs` is split from `remotes.rs`: one module per error taxonomy, so the whole
//! `MutateError` surface keeps landing in `repo.rs::map_mutate_err` and never grows a
//! second, desyncable spelling.
//!
//! Every verb returns the shipped `MutationResult` payload; none adds a `Payload` union
//! member. Transport follows ADR-0001: each takes a LIST of strings or a distinguishably-ABSENT
//! string (or, for `rename`, two strings and a flag), so each crosses as a request BUFFER rather
//! than as `CString`s.

use flatbuffers::VerifierOptions;
use tracing::debug;
use zanshin_jj::{BookmarkMoveOptions, ChangeId};

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

/// The strings of an optional request vector — ABSENT is EMPTY. Shared with `bookmarks.rs`'s
/// list reader.
pub(crate) fn strings(v: Option<flatbuffers::Vector<'_, flatbuffers::ForwardsUOffset<&str>>>) -> Vec<String> {
    v.into_iter().flatten().map(ToOwned::to_owned).collect()
}

/// Parse a `BookmarkMoveRequest` buffer into owned [`BookmarkMoveOptions`]. Absent vectors are
/// empty; the jj layer refuses neither-names-nor-from with its one message.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkMoveRequest` buffer, or its
///   `kind` is not `BookmarkMove`.
fn read_bookmark_move_request(data: *const u8, len: usize) -> Result<BookmarkMoveOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::BookmarkMoveRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::BookmarkMove)?;
    Ok(BookmarkMoveOptions {
        names: strings(req.names()),
        from: strings(req.from()),
        to: req.to().map(|s| ChangeId(s.to_owned())),
        allow_backwards: req.allow_backwards(),
    })
}

/// Owned Rust form of a `BookmarkAdvanceRequest` buffer; `to` absent applies
/// `revsets.bookmark-advance-to`.
struct BookmarkAdvanceRequestOwned {
    names: Vec<String>,
    to: Option<ChangeId>,
}

/// Parse a `BookmarkAdvanceRequest` buffer into an owned [`BookmarkAdvanceRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkAdvanceRequest` buffer, or its
///   `kind` is not `BookmarkAdvance`.
fn read_bookmark_advance_request(data: *const u8, len: usize) -> Result<BookmarkAdvanceRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::BookmarkAdvanceRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::BookmarkAdvance)?;
    Ok(BookmarkAdvanceRequestOwned {
        names: strings(req.names()),
        to: req.to().map(|s| ChangeId(s.to_owned())),
    })
}

/// Owned Rust form of a `BookmarkRenameRequest` buffer. An absent name becomes the EMPTY name,
/// which the jj layer refuses with its one message.
struct BookmarkRenameRequestOwned {
    old_name: String,
    new_name: String,
    overwrite_existing: bool,
}

/// Parse a `BookmarkRenameRequest` buffer into an owned [`BookmarkRenameRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkRenameRequest` buffer, or its
///   `kind` is not `BookmarkRename`.
fn read_bookmark_rename_request(data: *const u8, len: usize) -> Result<BookmarkRenameRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::BookmarkRenameRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::BookmarkRename)?;
    Ok(BookmarkRenameRequestOwned {
        old_name: req.old_name().unwrap_or_default().to_owned(),
        new_name: req.new_name().unwrap_or_default().to_owned(),
        overwrite_existing: req.overwrite_existing(),
    })
}

/// Owned Rust form of a `BookmarkSetRequest` buffer: absent `names` are empty (the jj layer
/// refuses them), `revision` absent applies the CLI's `-r` default `@`.
struct BookmarkSetRequestOwned {
    names: Vec<String>,
    revision: Option<ChangeId>,
    allow_backwards: bool,
}

/// Parse a `BookmarkSetRequest` buffer into an owned [`BookmarkSetRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkSetRequest` buffer, or its
///   `kind` is not `BookmarkSet`.
fn read_bookmark_set_request(data: *const u8, len: usize) -> Result<BookmarkSetRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::BookmarkSetRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::BookmarkSet)?;
    Ok(BookmarkSetRequestOwned {
        names: strings(req.names()),
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        allow_backwards: req.allow_backwards(),
    })
}

/// Owned Rust form of a `BookmarkForgetRequest` buffer; absent `names` are empty.
struct BookmarkForgetRequestOwned {
    names: Vec<String>,
    include_remotes: bool,
}

/// Parse a `BookmarkForgetRequest` buffer into an owned [`BookmarkForgetRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkForgetRequest` buffer, or its
///   `kind` is not `BookmarkForget`.
fn read_bookmark_forget_request(data: *const u8, len: usize) -> Result<BookmarkForgetRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::BookmarkForgetRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::BookmarkForget)?;
    Ok(BookmarkForgetRequestOwned {
        names: strings(req.names()),
        include_remotes: req.include_remotes(),
    })
}

/// Owned Rust form of a `BookmarkTrackRequest` buffer; absent vectors are empty.
struct BookmarkTrackRequestOwned {
    names: Vec<String>,
    remotes: Vec<String>,
}

/// Parse a `BookmarkTrackRequest` buffer tagged `kind` (`BookmarkTrack` or `BookmarkUntrack`) into
/// an owned [`BookmarkTrackRequestOwned`]. The tag is what keeps a track buffer from untracking.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkTrackRequest` buffer, or its
///   `kind` is not `kind`.
fn read_bookmark_track_request(
    data: *const u8,
    len: usize,
    kind: fbs::RequestKind,
) -> Result<BookmarkTrackRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::BookmarkTrackRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), kind)?;
    Ok(BookmarkTrackRequestOwned {
        names: strings(req.names()),
        remotes: strings(req.remotes()),
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
/// A created name is AUTO-TRACKED as in the CLI: on every remote with a remote view whose
/// `remotes.<r>.auto-track-bookmarks` / `auto-track-created-bookmarks` matches it, the
/// `name@remote` row becomes tracked (`zanshin_bookmarks` shows it). Warnings:
/// `jj.bookmark_target_empty` (empty, undescribed target), then
/// `jj.bookmark_auto_track_existing` per remote that already holds the name. Returns a
/// `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkCreateRequest` buffer, or its `kind`
///   is not `BookmarkCreate`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `names` is empty (or absent from the buffer), or a name is the
///   empty string.
/// - `jj.change_not_found` — `revision` is malformed, carried by no VISIBLE commit (unknown
///   or only-hidden); the id in `context`. An ABSENT `revision` is not an
///   error — it is what applies the CLI's `-r` default `@`. An explicitly present EMPTY
///   string is a VALUE, not an absence, and lands here.
/// - `jj.revset_resolution_error` — `revision` is an ambiguous change-id prefix or a divergent change (the CLI's
///   hints in `hints`), or `revsets.short-prefixes` fails to resolve.
/// - `jj.revset_resolution_error` — an absent `revision`'s `@` default in a workspace with no
///   working-copy commit; the CLI's text in `context`.
/// - `jj.bookmark_exists` — a name is already a local bookmark; the name in `context`.
/// - `jj.bookmark_tracked_remote_exists` — a name's local bookmark is absent but it still has
///   a tracked remote bookmark; the name in `context`.
/// - `jj.config_error` — the repo's effective jj config stack changed under the open handle and no
///   longer reads (Story 9.27 — the pre-verb settings refresh); nothing is written. Or the
///   pre-verb snapshot (Story 9.26) found a value it reads wrongly typed (the key in
///   `context`): operations it committed before the fault stay, as in the CLI (colocated:
///   `import git head`), and the partial `precondition` says which. Or, after both per-name
///   guards, a `remotes.<r>.auto-track-bookmarks` / `auto-track-created-bookmarks` value does
///   not parse (the CLI's ``Invalid `remotes.<r>.<field>`: …`` in `context`); nothing is
///   written.
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
///   longer reads (Story 9.27 — the pre-verb settings refresh); nothing is written. Or the
///   pre-verb snapshot (Story 9.26) found a value it reads wrongly typed (the key in
///   `context`): operations it committed before the fault stay, as in the CLI (colocated:
///   `import git head`), and the partial `precondition` says which.
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

/// Move existing local bookmarks to one revision, in the repo referenced by `handle` — the CLI's
/// `jj bookmark move` (Story 9.19).
///
/// The arguments cross as a `BookmarkMoveRequest` `FlatBuffers` request buffer. `names` are EXACT
/// bookmark names (the CLI's `exact:"…"`), `from` revset TEXTS (`--from`, unioned) — at least one
/// is required; a bookmark moves when its name is named (any, without names) AND, with `from`, a
/// target of it is in `from`. `to` ABSENT is the CLI's default `@` (snapshotted first, Story
/// 9.26), present a change id. A bookmark already at the target is skipped; nothing left is a
/// SUCCESS writing no operation (`MutationResult.new_op_id` is the pre-call head). Every moved
/// bookmark gets a NORMAL target, so a conflicted one is resolved. Warnings:
/// `jj.bookmark_names_unmatched`, `jj.bookmark_target_empty`. Op-log description `point bookmark
/// {names} to commit {hex}`. Returns a `FlatBuffers` `Envelope` carrying a `MutationResult`
/// payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkMoveRequest` buffer, or its
///   `kind` is not `BookmarkMove`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — neither `names` nor `from`; or, without `allow_backwards`, a backwards
///   or sideways move ("Refusing to move bookmark backwards or sideways: {name}", the hint "Use
///   --allow-backwards to allow it." in `hints`).
/// - `jj.change_not_found` — `to` is malformed, unknown or hidden; the id in `context`.
/// - `jj.revset_parse_error` / `jj.revset_resolution_error` — a `from` text, or no `@` for `to`'s
///   default.
/// - `jj.revset_resolution_error` — `to` is an ambiguous change-id prefix or a divergent change (the CLI's hints
///   in `hints`), or `revsets.short-prefixes` fails to resolve.
/// - `jj.config_error` — the effective config changed and no longer reads, the pre-verb snapshot
///   found a wrongly typed knob, or the revset aliases do not load.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale; nothing is
///   written.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_bookmark_create`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.BookmarkMoveRequestObjectBuilder(...).toBytes()`); Rust only borrows it for
/// the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_bookmark_move(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmark_move", handle);
    let buf = catch(|| {
        let options = read_bookmark_move_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.bookmark_move(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Advance the closest bookmarks to a revision, in the repo referenced by `handle` — the CLI's
/// `jj bookmark advance` (Story 9.19).
///
/// The arguments cross as a `BookmarkAdvanceRequest` `FlatBuffers` request buffer. `to` ABSENT
/// applies `revsets.bookmark-advance-to` (default `@`), which must resolve to exactly one commit;
/// present it is a change id. `names` are EXACT bookmark names; absent/empty applies the CLI's
/// default candidates, the local bookmarks with a target in `revsets.bookmark-advance-from`
/// (default `heads(::to & bookmarks())`). Then as `zanshin_bookmark_move` without
/// `allow_backwards`. Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on
/// success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkAdvanceRequest` buffer, or its
///   `kind` is not `BookmarkAdvance`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — a backwards or sideways candidate ("Refusing to advance bookmark
///   backwards or sideways: {name}", no hint).
/// - `jj.change_not_found` — `to` does not resolve; the id in `context`.
/// - `jj.revset_parse_error` / `jj.revset_resolution_error` — the default target does not parse
///   or resolve to exactly one commit (`hints` carry "`revsets.bookmark-advance-to` controls the
///   default target. …"), or the from revset does not parse or resolve.
/// - `jj.config_error` — a `revsets.bookmark-advance-*` value is not a string, the revset aliases
///   do not load, or the pre-verb refresh / snapshot faults as for `zanshin_bookmark_move`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_bookmark_create`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.BookmarkAdvanceRequestObjectBuilder(...).toBytes()`); Rust only borrows it for
/// the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_bookmark_advance(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmark_advance", handle);
    let buf = catch(|| {
        let req = read_bookmark_advance_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.bookmark_advance(&req.names, req.to.as_ref());
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Rename a local bookmark, in the repo referenced by `handle` — the CLI's `jj bookmark rename`
/// (Story 9.19).
///
/// The arguments cross as a `BookmarkRenameRequest` `FlatBuffers` request buffer: `old_name` and
/// `new_name` are DECODED names, `overwrite_existing` is `--overwrite-existing`. The new name
/// points where the old one did, the old one is gone, and the tracking of the old name's remotes
/// moves to the new name (the remote bookmarks themselves are not renamed). Renaming to the same
/// name with `overwrite_existing` writes no operation. Warnings:
/// `jj.bookmark_rename_remote_exists`, `jj.bookmark_tracking_dropped`,
/// `jj.bookmark_remotes_not_renamed`, `jj.bookmark_tracked_remotes_exist`. Op-log description
/// `rename bookmark {old} to {new}`. Returns a `FlatBuffers` `Envelope` carrying a
/// `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkRenameRequest` buffer, or its
///   `kind` is not `BookmarkRename`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — a name is empty or absent, or `old_name` is not a local bookmark ("No
///   such bookmark: {old}").
/// - `jj.bookmark_exists` — `new_name` is a local bookmark and `overwrite_existing` is off (also
///   for the same name, as in the CLI); the name in `context`.
/// - `jj.config_error` — the pre-verb refresh or snapshot faults as for `zanshin_bookmark_move`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_bookmark_create`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.BookmarkRenameRequestObjectBuilder(...).toBytes()`); Rust only borrows it for
/// the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_bookmark_rename(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmark_rename", handle);
    let buf = catch(|| {
        let req = read_bookmark_rename_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session
            .repo
            .bookmark_rename(&req.old_name, &req.new_name, req.overwrite_existing);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Create or move local bookmarks to one revision by name, in the repo referenced by `handle` —
/// the CLI's `jj bookmark set` (Story 9.11).
///
/// The arguments cross as a `BookmarkSetRequest` `FlatBuffers` request buffer: `names` are DECODED
/// names (as `zanshin_bookmark_create`'s), `revision` ABSENT is the CLI's `-r` default `@`
/// (snapshotted first, Story 9.26), present a change id; `allow_backwards` is
/// `--allow-backwards`. Per name in argument order, fail-fast: a backwards or sideways move
/// without `allow_backwards` refuses and nothing is set. A name with no local bookmark and no
/// tracked remote is CREATED and auto-tracked as `zanshin_bookmark_create` does it; an absent one
/// that still tracks a remote is resurrected without auto-tracking. Every name gets a NORMAL
/// target. Setting every name where it already points writes no operation
/// (`MutationResult.new_op_id` is the pre-call head). Warnings: `jj.bookmark_target_empty`, then
/// `jj.bookmark_auto_track_existing`. Op-log description `point bookmark {names} to commit
/// {hex}`. Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkSetRequest` buffer, or its
///   `kind` is not `BookmarkSet`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — `names` is empty (or absent) or holds an empty name, before the
///   snapshot; or, without `allow_backwards`, a backwards or sideways move ("Refusing to move
///   bookmark backwards or sideways: {name}", the hint "Use --allow-backwards to allow it." in
///   `hints`).
/// - `jj.change_not_found` — `revision` is malformed, unknown or hidden; the id in `context`.
/// - `jj.revset_resolution_error` — no `@` for `revision`'s default; `revision` is an ambiguous change-id prefix
///   or a divergent change (the CLI's hints in `hints`), or `revsets.short-prefixes` fails to resolve.
/// - `jj.config_error` — the pre-verb refresh or snapshot faults as for `zanshin_bookmark_move`,
///   or a `remotes.<r>` auto-track value does not parse; nothing is written.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_bookmark_create`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.BookmarkSetRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_bookmark_set(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmark_set", handle);
    let buf = catch(|| {
        let req = read_bookmark_set_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session
            .repo
            .bookmark_set(&req.names, req.revision.as_ref(), req.allow_backwards);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Forget bookmarks, in the repo referenced by `handle` — the CLI's `jj bookmark forget` (Story
/// 9.11): the local bookmark goes WITHOUT becoming a deletion the next push propagates.
///
/// The arguments cross as a `BookmarkForgetRequest` `FlatBuffers` request buffer: `names` are
/// string PATTERNS passed through verbatim (a BARE one is a GLOB), matching bookmark names with a
/// local or a remote row; `include_remotes` is `--include-remotes`. Each matched local bookmark
/// becomes absent and its remote bookmarks are untracked (the Git-tracking `git` remote is left
/// alone) — or, with `include_remotes`, forgotten too, `git` included. Matching or changing
/// nothing writes no operation. Warning: `jj.bookmark_names_unmatched`. Op-log description
/// `forget bookmark {names}`. Returns a `FlatBuffers` `Envelope` carrying a `MutationResult`
/// payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkForgetRequest` buffer, or its
///   `kind` is not `BookmarkForget`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — `names` is empty (or absent), before the snapshot; or a pattern does not
///   parse, after it (jj-lib's reason in `context`).
/// - `jj.config_error` — the pre-verb refresh or snapshot faults as for `zanshin_bookmark_move`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_bookmark_create`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.BookmarkForgetRequestObjectBuilder(...).toBytes()`); Rust only borrows it for
/// the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_bookmark_forget(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmark_forget", handle);
    let buf = catch(|| {
        let req = read_bookmark_forget_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.bookmark_forget(&req.names, req.include_remotes);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Start tracking remote bookmarks, in the repo referenced by `handle` — the CLI's `jj bookmark
/// track` (Story 9.11).
///
/// The arguments cross as a `BookmarkTrackRequest` `FlatBuffers` request buffer tagged
/// `BookmarkTrack`: `names` are the CLI's `BOOKMARK[@REMOTE]` texts passed through — a
/// `name@remote` symbol names one remote bookmark exactly (revset-quoted where needed), any other
/// text is a string pattern (a BARE one a GLOB) matched on the `remotes` (remote-name PATTERNS,
/// `--remote`; absent/empty = every remote but `git` on a Git-backed repo). A local bookmark a
/// remote does not have yet is trackable there too. Tracking merges the remote target into the
/// local bookmark. Nothing to track writes no operation. Warnings: `jj.remote_bookmarks_unmatched`
/// or `jj.bookmark_names_unmatched` + `jj.bookmark_remotes_unmatched`, then
/// `jj.bookmark_already_tracked`. Op-log description `track remote bookmark {symbols}`. Returns a
/// `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkTrackRequest` buffer, or its
///   `kind` is not `BookmarkTrack`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — `names` is empty (or absent), before the snapshot; after it, a name or
///   remote that does not parse, patterns mixed with symbols ("Cannot specify both <bookmark>
///   patterns and <bookmark>@<remote> symbols"), or `remotes` with symbols ("--remote cannot be
///   used with <bookmark>@<remote> symbols").
/// - `jj.config_error` — the pre-verb refresh or snapshot faults as for `zanshin_bookmark_move`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_bookmark_create`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.BookmarkTrackRequestObjectBuilder(...).toBytes()`); Rust only borrows it for
/// the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_bookmark_track(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmark_track", handle);
    let buf = catch(|| {
        let req = read_bookmark_track_request(data, len, fbs::RequestKind::BookmarkTrack)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.bookmark_track(&req.names, &req.remotes);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Stop tracking remote bookmarks, in the repo referenced by `handle` — the CLI's `jj bookmark
/// untrack` (Story 9.11).
///
/// The arguments cross as a `BookmarkTrackRequest` `FlatBuffers` request buffer tagged
/// `BookmarkUntrack`; `names` and `remotes` as `zanshin_bookmark_track`'s. The matched tracked
/// refs are untracked — the local bookmark stays. Nothing to untrack writes no operation.
/// Warnings: `jj.remote_bookmarks_unmatched` or `jj.bookmark_names_unmatched` +
/// `jj.bookmark_remotes_unmatched`, then `jj.bookmark_git_tracking_untrack` (a `git` ref) and
/// `jj.bookmark_not_tracked`. Op-log description `untrack remote bookmark {symbols}`. Returns a
/// `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkTrackRequest` buffer, or its
///   `kind` is not `BookmarkUntrack`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — as for `zanshin_bookmark_track`: empty `names` before the snapshot; an
///   unparsable name or remote, mixed patterns and symbols, or `remotes` with symbols after it.
/// - `jj.config_error` — the pre-verb refresh or snapshot faults as for `zanshin_bookmark_move`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_bookmark_create`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.BookmarkTrackRequestObjectBuilder(...).toBytes()`); Rust only borrows it for
/// the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_bookmark_untrack(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmark_untrack", handle);
    let buf = catch(|| {
        let req = read_bookmark_track_request(data, len, fbs::RequestKind::BookmarkUntrack)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.bookmark_untrack(&req.names, &req.remotes);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}
