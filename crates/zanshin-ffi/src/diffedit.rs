// SPDX-License-Identifier: MIT

//! `zanshin_diffedit` — the CLI's `jj diffedit` with its builtin diff editor, the GUI's (Story
//! 9.17): the target takes a tree `zanshin_select_tree` built.
//!
//! Calls `zanshin_jj::Repo::diffedit` and serialises the result into a `FlatBuffers` `Envelope`.
//! The arguments cross as a `DiffeditRequest` request BUFFER (ADR-0001 composite-input pattern).
//! The handle is borrowed, never consumed. The call runs the pre-verb snapshot (Story 9.26), so
//! every envelope carries the precondition report and the call's warnings.

use flatbuffers::VerifierOptions;
use tracing::debug;
use zanshin_jj::{ChangeId, DiffeditOptions};

use crate::envelope::{
    catch, expect_request_kind, invalid_request, ok_mutation_result, precondition_envelope, reject_null_request,
    session_from_handle, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;
use crate::select_tree::{strings, tree_selection};

/// Parse a `DiffeditRequest` buffer into owned [`DiffeditOptions`]; absent ids take the CLI's
/// defaults, an absent `tree` or `right` is empty (which `zanshin_jj` refuses as
/// `jj.invalid_input`).
///
/// `data`/`len` describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for
/// the call only. The byte slice lives in this function's scope and the result is OWNED, so the
/// unbounded lifetime `std::slice::from_raw_parts` produces cannot outlive the call.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `DiffeditRequest` buffer, or its `kind`
///   is not `Diffedit`.
fn read_diffedit_request(data: *const u8, len: usize) -> Result<DiffeditOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::DiffeditRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Diffedit)?;
    let id = |s: Option<&str>| s.map(|s| ChangeId(s.to_owned()));
    Ok(DiffeditOptions {
        revision: id(req.revision()),
        from: id(req.from()),
        to: id(req.to()),
        tree: req.tree().map(tree_selection).unwrap_or_default(),
        right: strings(req.right()),
        restore_descendants: req.restore_descendants(),
    })
}

/// Touch up a revision's content with a GUI-selected tree, in the repo identified by `handle` —
/// the CLI's `jj diffedit` (Story 9.17).
///
/// The arguments cross as a `DiffeditRequest` `FlatBuffers` request buffer: `revision` (`-r`,
/// diffed against its parents; absent with neither `from` nor `to`: `@`), `from` / `to`
/// (`--from` / `--to`: `to`, absent `@`, diffed against `from`'s own tree, absent `@`), `tree`
/// (what `zanshin_select_tree` returned for that diff and its `left`), `restore_descendants` and
/// `right` (the target's `ShowEntry.tree_ids` the selection saw, required). The target must be
/// rewritable; a base tree that is no longer `tree.left`, or then a target tree that is no longer
/// `right`, is stale. A tree equal to the target's writes NO operation (`MutationResult.new_op_id`
/// is the pre-call head); otherwise the target gets the tree, its descendants are rebased
/// (reparented with `restore_descendants`) and the operation is `edit commit <hex>`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `DiffeditRequest` buffer, or its `kind`
///   is not `Diffedit`.
/// - `jj.invalid_input` — `revision` together with `from`/`to`, a `tree` of the wrong shape, or an
///   absent / malformed `right` — before the snapshot: nothing written, no `precondition`; detail
///   in `context`.
/// - `jj.change_not_found` — an id is malformed, carried by no VISIBLE commit, or divergent.
/// - `jj.revset_resolution_error` — an omitted id's `@` in a workspace with no working-copy commit.
/// - `jj.immutable` — the target is inside the immutable set; its hex id in `context`.
/// - `jj.stale_selection` — the base tree is not the selection's `left`, or the target's tree is
///   not `right`; detail in `context`.
/// - `jj.config_error` — the `immutable_heads()` alias does not resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.not_a_git_repo` — the colocated finish found no Git backend.
/// - `jj.jj_lib_error` — an underlying jj-lib failure (an unknown tree id among them).
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.DiffeditRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_diffedit(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_diffedit", handle);
    let buf = catch(|| {
        let options = read_diffedit_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.diffedit(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use super::read_diffedit_request;
    use crate::envelope::FFI_INVALID_ARGUMENT;
    use crate::fbs;

    fn request(kind: fbs::RequestKind, with_tree: bool) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let tree = with_tree.then(|| {
            let id = b.create_string("t");
            let tree_ids = b.create_vector(&[id]);
            let id = b.create_string("l");
            let left = b.create_vector(&[id]);
            fbs::TreeSelection::create(
                &mut b,
                &fbs::TreeSelectionArgs {
                    tree_ids: Some(tree_ids),
                    labels: None,
                    left: Some(left),
                },
            )
        });
        let from = b.create_string("f");
        let to = b.create_string("t");
        let right = with_tree.then(|| {
            let id = b.create_string("r");
            b.create_vector(&[id])
        });
        let req = fbs::DiffeditRequest::create(
            &mut b,
            &fbs::DiffeditRequestArgs {
                kind,
                revision: None,
                from: Some(from),
                to: Some(to),
                tree,
                restore_descendants: true,
                right,
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    #[test]
    fn the_reader_reads_every_field_and_refuses_another_kind() {
        let bytes = request(fbs::RequestKind::Diffedit, true);
        let options = read_diffedit_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert!(options.revision.is_none());
        assert_eq!(options.from.map(|r| r.0).as_deref(), Some("f"));
        assert_eq!(options.to.map(|r| r.0).as_deref(), Some("t"));
        assert_eq!(options.tree.tree.tree_ids, ["t"]);
        assert_eq!(options.tree.left, ["l"]);
        assert!(options.restore_descendants);
        assert_eq!(options.right, ["r"]);
        let bytes = request(fbs::RequestKind::Diffedit, false);
        let options = read_diffedit_request(bytes.as_ptr(), bytes.len()).expect("no tree");
        assert!(options.tree.tree.tree_ids.is_empty());
        assert!(options.right.is_empty());
        let bytes = request(fbs::RequestKind::Resolve, true);
        let err = read_diffedit_request(bytes.as_ptr(), bytes.len()).expect_err("wrong kind");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
    }
}
