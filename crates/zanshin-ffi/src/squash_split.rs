// SPDX-License-Identifier: MIT

//! `zanshin_squash` / `zanshin_squash_plan` / `zanshin_split` — the CLI's `jj squash` and
//! `jj split`, paths only (Story 9.15).
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the result into a
//! `FlatBuffers` `Envelope`. The arguments cross as request BUFFERS (ADR-0001 composite-input
//! pattern): `SquashRequest`, read by BOTH squash wrappers, and `SplitRequest`. The handle is
//! borrowed, never consumed. Every call runs the pre-verb snapshot (Story 9.26), so every envelope
//! carries the precondition report and the call's warnings — `zanshin_split`'s
//! `jj.split_all_selected` / `jj.split_none_selected` among them.

use flatbuffers::{ForwardsUOffset, Vector, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ChangeId, SplitOptions, SquashOptions};

use crate::envelope::{
    catch, expect_request_kind, invalid_request, ok_mutation_result, ok_split_result, ok_squash_plan,
    precondition_envelope, reject_null_request, session_from_handle, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

// ── Request-buffer readers ───────────────────────────────────────────────────
//
// Same discipline as `repo.rs`'s readers: `data`/`len` describe a caller-owned buffer Dart builds
// and frees itself; Rust borrows it for the call only. Each reader builds its OWN byte slice in
// its own scope and returns an OWNED value, so the unbounded lifetime
// `std::slice::from_raw_parts` produces provably cannot outlive the call.

/// A string vector as owned strings; an ABSENT vector is `None` — the CLI's "flag not given",
/// distinct from a present EMPTY one.
fn strings(v: Option<Vector<'_, ForwardsUOffset<&str>>>) -> Option<Vec<String>> {
    v.map(|v| v.iter().map(ToOwned::to_owned).collect())
}

/// A string vector as change ids; ABSENT is `None`, as in [`strings`].
fn change_ids(v: Option<Vector<'_, ForwardsUOffset<&str>>>) -> Option<Vec<ChangeId>> {
    v.map(|v| v.iter().map(|s| ChangeId(s.to_owned())).collect())
}

/// Parse a `SquashRequest` buffer into owned [`SquashOptions`]. `message` stays `None` when the
/// vector is ABSENT (no `-m`); `from` and `paths` treat absence as empty.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `SquashRequest` buffer, or its `kind`
///   is not `Squash`.
fn read_squash_request(data: *const u8, len: usize) -> Result<SquashOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::SquashRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Squash)?;
    Ok(SquashOptions {
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        from: change_ids(req.from()).unwrap_or_default(),
        // WHY the fully-qualified inherent call: the generated accessor is named after the schema
        // field `into`, which collides with the blanket `Into::into` (see `repo.rs`).
        into: fbs::SquashRequest::into(&req).map(|s| ChangeId(s.to_owned())),
        paths: strings(req.paths()).unwrap_or_default(),
        message: strings(req.message()),
        use_destination_message: req.use_destination_message(),
        keep_emptied: req.keep_emptied(),
    })
}

/// Parse a `SplitRequest` buffer into owned [`SplitOptions`]. `message` and the three location
/// vectors stay `None` when ABSENT (the flag not given); a present EMPTY vector is a value.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `SplitRequest` buffer, or its `kind`
///   is not `Split`.
fn read_split_request(data: *const u8, len: usize) -> Result<SplitOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::SplitRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Split)?;
    Ok(SplitOptions {
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        paths: strings(req.paths()).unwrap_or_default(),
        message: strings(req.message()),
        parallel: req.parallel(),
        onto: change_ids(req.onto()),
        insert_after: change_ids(req.insert_after()),
        insert_before: change_ids(req.insert_before()),
    })
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// Move changes from one or more revisions into another, in the repo identified by `handle` —
/// the CLI's `jj squash`, paths only (Story 9.15).
///
/// The arguments cross as a `SquashRequest` `FlatBuffers` request buffer, one field per CLI flag:
/// `revision` (absent with `from`/`into` absent too: `@` into its one parent), `from` (empty with
/// `into` present: `@`), `into` (absent with `from` present: `@`), `paths` (repo-relative
/// PREFIXES, empty = every path), `message` (the CLI's `-m`; ABSENT = no `-m`),
/// `use_destination_message` (`-u`) and `keep_emptied` (`-k`). Without `message`, where the CLI
/// opens its editor (two or more non-empty descriptions among the abandoned sources and the
/// destination), the combined text the editor holds is written as if saved unchanged — preview it
/// with `zanshin_squash_plan` first. The operation is `squash commits into <destination hex>`;
/// squashing `@` into `@` writes NO operation and `MutationResult.new_op_id` carries the PRE-CALL
/// head. The working copy is snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success: an
/// abandoned `@`'s replacement in `new_change_ids`, the abandoned sources in
/// `abandoned_change_ids`. An explicit path no selected source holds warns `jj.paths_unmatched`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `SquashRequest` buffer, or its `kind`
///   is not `Squash`.
/// - `jj.invalid_input` — `revision` combined with `from`/`into`, `message` with
///   `use_destination_message`, a merge or the root commit as the revision ("Cannot squash merge
///   commits without a specified destination"), or a `paths` entry that is not a valid repo path;
///   detail in `context`.
/// - `jj.change_not_found` — `revision`, a `from` entry or `into` is malformed, carried by no
///   VISIBLE commit, or divergent; the id in `context`.
/// - `jj.immutable` — a source or the destination is immutable; its hex commit id in `context`.
/// - `jj.config_error` — the config or its `immutable_heads()` alias does not read or resolve; or
///   (Story 9.51) `templates.commit_trailers` or (the editor case) `templates.draft_commit_description`
///   does not parse or render — the CLI's text ("Failed to parse template: …" with its cause lines, "Trailers should be valid utf-8", jj-lib's trailer-parse text) in `context`, nothing written.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.SquashRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_squash(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_squash", handle);
    let buf = catch(|| {
        let options = read_squash_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.squash(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Preview the description `zanshin_squash` would have to ask for, in the repo identified by
/// `handle` (Story 9.15): the squash with the same `SquashRequest`, prepared up to where the CLI
/// opens its editor, and dropped.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `SquashPlan` payload on success:
/// `combined_description` is the text the CLI's editor holds, saved unchanged — exactly what
/// `zanshin_squash` writes without `message` — and ABSENT when there is nothing to ask. Refuses
/// and warns exactly as `zanshin_squash`. Writes NO operation of its own, only the pre-verb
/// snapshot's.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `SquashRequest` buffer, or its `kind`
///   is not `Squash`.
/// - `jj.invalid_input` — as `zanshin_squash`: conflicting flags, a merge or root revision, an
///   invalid path; detail in `context`.
/// - `jj.change_not_found` — `revision`, a `from` entry or `into` does not resolve; the id in
///   `context`.
/// - `jj.immutable` — a source or the destination is immutable; its hex commit id in `context`.
/// - `jj.config_error` — the config or its `immutable_heads()` alias does not read or resolve; or
///   (Story 9.51) `templates.commit_trailers` or (the editor case) `templates.draft_commit_description`
///   does not parse or render — the CLI's text ("Failed to parse template: …" with its cause lines, "Trailers should be valid utf-8", jj-lib's trailer-parse text) in `context`, nothing written.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.SquashRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_squash_plan(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_squash_plan", handle);
    let buf = catch(|| {
        let options = read_squash_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.squash_plan(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_squash_plan)
    });
    vec_into_token(buf)
}

/// Split a revision in two, in the repo identified by `handle` — the CLI's `jj split`, paths only
/// (Story 9.15).
///
/// The arguments cross as a `SplitRequest` `FlatBuffers` request buffer, one field per CLI flag:
/// `revision` (absent: `@`), `paths` (repo-relative PREFIXES, at least one — no paths is the CLI's
/// interactive diff editor), `message` (the CLI's `-m` for the SELECTED commit; ABSENT: both keep
/// the original description), `parallel`, and the `onto` / `insert_after` / `insert_before`
/// locations (ABSENT = the flag not given). Plain and parallel splits keep the target's change id
/// on the selected commit; with a location the selected changes become a NEW change there and
/// the remaining commit keeps the target's change id. Bookmarks follow
/// `split.legacy-bookmark-behavior`; `@` ends on the remaining commit. The operation is
/// `split commit <target hex>`. The working copy is snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `SplitResult` payload on success; selecting
/// every change warns `jj.split_all_selected`, selecting none `jj.split_none_selected`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `SplitRequest` buffer, or its `kind` is
///   not `Split`.
/// - `jj.invalid_input` — `paths` is empty or holds an invalid repo path, `parallel` is combined
///   with a location, `onto` with `insert_after`/`insert_before`, the location resolves no parent,
///   or it would create a loop; detail in `context`.
/// - `jj.change_not_found` — `revision` or a location entry is malformed, carried by no VISIBLE
///   commit, or divergent; the id in `context`.
/// - `jj.immutable` — the target, or a child the location would rewrite, is immutable.
/// - `jj.config_error` — `split.legacy-bookmark-behavior` is not a boolean, or the config or its
///   `immutable_heads()` alias does not read or resolve; or (Story 9.51) `templates.commit_trailers`
///   or (without `message`) `templates.draft_commit_description` does not parse or render —
///   the CLI's text ("Failed to parse template: …" with its cause lines, "Trailers should be valid utf-8", jj-lib's trailer-parse text) in `context`, nothing written.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.SplitRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_split(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_split", handle);
    let buf = catch(|| {
        let options = read_split_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.split(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_split_result)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use super::{read_split_request, read_squash_request};
    use crate::fbs;

    fn squash_request(message: Option<Vec<&str>>) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let message = message.map(|m| {
            let offsets: Vec<_> = m.iter().map(|s| b.create_string(s)).collect();
            b.create_vector(&offsets)
        });
        let into = b.create_string("into");
        let req = fbs::SquashRequest::create(
            &mut b,
            &fbs::SquashRequestArgs {
                kind: fbs::RequestKind::Squash,
                into: Some(into),
                message,
                keep_emptied: true,
                ..fbs::SquashRequestArgs::default()
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    /// `message` absent is "no `-m`"; present-empty is a value; absent `from`/`paths` are empty.
    #[test]
    fn the_squash_reader_keeps_an_absent_message_apart_from_an_empty_one() {
        let bytes = squash_request(None);
        let options = read_squash_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert_eq!(options.message, None);
        assert_eq!(options.into, Some(zanshin_jj::ChangeId("into".to_owned())));
        assert!(options.from.is_empty() && options.paths.is_empty() && options.revision.is_none());
        assert!(options.keep_emptied && !options.use_destination_message);

        let bytes = squash_request(Some(vec![]));
        assert_eq!(
            read_squash_request(bytes.as_ptr(), bytes.len()).expect("valid").message,
            Some(Vec::new())
        );
        let bytes = squash_request(Some(vec!["T", "U"]));
        assert_eq!(
            read_squash_request(bytes.as_ptr(), bytes.len()).expect("valid").message,
            Some(vec!["T".to_owned(), "U".to_owned()])
        );
    }

    /// An absent location vector is "flag not given"; a present-empty one is a value.
    #[test]
    fn the_split_reader_keeps_absent_and_empty_locations_apart() {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let path = b.create_string("c.txt");
        let paths = b.create_vector(&[path]);
        let before_id = b.create_string("b");
        let before = b.create_vector(&[before_id]);
        let after = b.create_vector::<flatbuffers::ForwardsUOffset<&str>>(&[]);
        let req = fbs::SplitRequest::create(
            &mut b,
            &fbs::SplitRequestArgs {
                kind: fbs::RequestKind::Split,
                paths: Some(paths),
                insert_after: Some(after),
                insert_before: Some(before),
                parallel: true,
                ..fbs::SplitRequestArgs::default()
            },
        );
        b.finish(req, None);
        let bytes = b.finished_data().to_vec();

        let options = read_split_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert_eq!(options.paths, ["c.txt"]);
        assert_eq!(options.onto, None);
        assert_eq!(options.insert_after, Some(Vec::new()));
        assert_eq!(options.insert_before, Some(vec![zanshin_jj::ChangeId("b".to_owned())]));
        assert_eq!(options.message, None);
        assert!(options.parallel && options.revision.is_none());
    }

    /// A buffer built for the other verb is refused before anything is read.
    #[test]
    fn a_squash_buffer_is_not_a_split_request() {
        let bytes = squash_request(None);
        let err = read_split_request(bytes.as_ptr(), bytes.len()).expect_err("wrong kind");
        assert_eq!(err.code, crate::envelope::FFI_INVALID_ARGUMENT);
    }
}
