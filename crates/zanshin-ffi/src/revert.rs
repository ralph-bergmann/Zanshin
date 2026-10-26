// SPDX-License-Identifier: MIT

//! `zanshin_revert` — the CLI's `jj revert` (Story 9.18).
//!
//! Calls `zanshin_jj::Repo::revert` and serialises the result into a `FlatBuffers` `Envelope`
//! carrying the shared `MutationResult`. The arguments cross as a `RevertRequest` request BUFFER
//! (ADR-0001 composite-input pattern). The handle is borrowed, never consumed. The call runs the
//! pre-verb snapshot (Story 9.26) unless clap's rules refuse it first, so the envelope carries the
//! precondition report and the call's warnings.

use flatbuffers::{ForwardsUOffset, Vector, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ChangeId, RevertOptions};

use crate::envelope::{
    catch, expect_request_kind, invalid_request, ok_mutation_result, precondition_envelope, reject_null_request,
    session_from_handle, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

/// Parse a `RevertRequest` buffer into owned [`RevertOptions`]; an ABSENT vector is empty — the
/// flag not given.
///
/// `data`/`len` describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for
/// the call only. The byte slice lives in this function's scope and the result is OWNED, so the
/// unbounded lifetime `std::slice::from_raw_parts` produces cannot outlive the call.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `RevertRequest` buffer, or its `kind` is
///   not `Revert`.
fn read_revert_request(data: *const u8, len: usize) -> Result<RevertOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::RevertRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Revert)?;
    let ids = |v: Option<Vector<'_, ForwardsUOffset<&str>>>| -> Vec<ChangeId> {
        v.map(|v| v.iter().map(|s| ChangeId(s.to_owned())).collect())
            .unwrap_or_default()
    };
    Ok(RevertOptions {
        revisions: ids(req.revisions()),
        onto: ids(req.onto()),
        insert_after: ids(req.insert_after()),
        insert_before: ids(req.insert_before()),
    })
}

/// Apply the reverse of existing changes, in the repo identified by `handle` — the CLI's `jj
/// revert` (Story 9.18).
///
/// The arguments cross as a `RevertRequest` `FlatBuffers` request buffer: `revisions` (`-r`,
/// required) and the location — `onto` (`-o`) or `insert_after` / `insert_before` (`-A` / `-B`),
/// one of them required. The revisions are reverted newest first: each reverse is a new change
/// whose tree is the 3-way merge of the destination, the reverted tree and its parents' tree (a
/// conflict labelled as the CLI labels it when a later change overwrote what is reverted), the
/// first onto the location's parents, each later one onto the previous; `-A`/`-B` rebase the
/// location's children onto the last one. Each is described with `templates.revert_description`
/// rendered on the reverted change. The operation is the CLI's `revert commit <hex>` (`… and <n>
/// more` for several). The working copy is snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success: the reverse
/// changes' ids in `new_change_ids`, in creation order.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `RevertRequest` buffer, or its `kind` is
///   not `Revert`.
/// - `jj.invalid_input` — no revision, `onto` with `insert_after`/`insert_before`, or no location
///   (clap's refusals: before the snapshot, nothing written, no `precondition`); a location that
///   would create a loop or resolves no parent; a merge with the root commit as a parent in a Git
///   repo; detail in `context`.
/// - `jj.change_not_found` — an id is malformed or carried by no VISIBLE commit; the id in `context`.
/// - `jj.revset_resolution_error` — an id is an ambiguous change-id prefix or a divergent change (the CLI's hints
///   in `hints`), or `revsets.short-prefixes` fails to resolve.
/// - `jj.immutable` — a child `insert_after`/`insert_before` would rewrite is immutable.
/// - `jj.config_error` — the revert-description template setting is not a string or does not
///   parse, or the config or its `immutable_heads()` alias does not read or resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.not_a_git_repo` — the colocated finish found no Git backend.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.RevertRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_revert(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_revert", handle);
    let buf = catch(|| {
        let options = read_revert_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.revert(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use super::read_revert_request;
    use crate::envelope::FFI_INVALID_ARGUMENT;
    use crate::fbs;

    fn request(kind: fbs::RequestKind) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let mut list = |ids: &[&str]| {
            let ids: Vec<_> = ids.iter().map(|s| b.create_string(s)).collect();
            b.create_vector(&ids)
        };
        let (revisions, onto, after, before) = (list(&["r1", "r2"]), list(&["o"]), list(&["a"]), list(&["b"]));
        let req = fbs::RevertRequest::create(
            &mut b,
            &fbs::RevertRequestArgs {
                kind,
                revisions: Some(revisions),
                onto: Some(onto),
                insert_after: Some(after),
                insert_before: Some(before),
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    #[test]
    fn the_reader_reads_every_field_and_refuses_another_kind() {
        let id = |s: &str| zanshin_jj::ChangeId(s.to_owned());
        let bytes = request(fbs::RequestKind::Revert);
        let options = read_revert_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert_eq!(
            (
                options.revisions,
                options.onto,
                options.insert_after,
                options.insert_before
            ),
            (vec![id("r1"), id("r2")], vec![id("o")], vec![id("a")], vec![id("b")])
        );

        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
        let req = fbs::RevertRequest::create(
            &mut b,
            &fbs::RevertRequestArgs {
                kind: fbs::RequestKind::Revert,
                ..fbs::RevertRequestArgs::default()
            },
        );
        b.finish(req, None);
        let bytes = b.finished_data().to_vec();
        let options = read_revert_request(bytes.as_ptr(), bytes.len()).expect("absent fields");
        assert_eq!(options, zanshin_jj::RevertOptions::default());

        let bytes = request(fbs::RequestKind::Duplicate);
        let err = read_revert_request(bytes.as_ptr(), bytes.len()).expect_err("wrong kind");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
    }
}
