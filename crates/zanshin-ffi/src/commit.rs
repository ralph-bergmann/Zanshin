// SPDX-License-Identifier: MIT

//! `zanshin_commit` — the CLI's `jj commit -m <message> [paths]` (Story 9.49).
//!
//! Calls `zanshin_jj::Repo::commit` and serialises the result into a `FlatBuffers` `Envelope`.
//! The arguments cross as a `CommitRequest` request BUFFER (ADR-0001 composite-input pattern).
//! The handle is borrowed, never consumed. The call runs the pre-verb snapshot (Story 9.26), so
//! every envelope carries the precondition report and the call's warnings —
//! `jj.commit_paths_unmatched` among them.

use flatbuffers::VerifierOptions;
use tracing::debug;
use zanshin_jj::CommitOptions;

use crate::envelope::{
    catch, expect_request_kind, invalid_request, ok_mutation_result, precondition_envelope, reject_null_request,
    session_from_handle, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

/// Parse a `CommitRequest` buffer into owned [`CommitOptions`]; an ABSENT vector is empty (no
/// paths = every change, no paragraph = `-m ""`).
///
/// `data`/`len` describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for
/// the call only. The byte slice lives in this function's scope and the result is OWNED, so the
/// unbounded lifetime `std::slice::from_raw_parts` produces cannot outlive the call.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `CommitRequest` buffer, or its `kind`
///   is not `Commit`.
fn read_commit_request(data: *const u8, len: usize) -> Result<CommitOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::CommitRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Commit)?;
    let owned = |v: Option<flatbuffers::Vector<'_, flatbuffers::ForwardsUOffset<&str>>>| -> Vec<String> {
        v.map(|v| v.iter().map(ToOwned::to_owned).collect()).unwrap_or_default()
    };
    Ok(CommitOptions {
        paths: owned(req.paths()),
        message: owned(req.message()),
    })
}

/// Commit the working-copy commit, in the repo identified by `handle` — the CLI's
/// `jj commit -m <message> [paths]` (Story 9.49).
///
/// The arguments cross as a `CommitRequest` `FlatBuffers` request buffer: `paths` (repo-relative
/// PREFIXES of the changes the committed `@` keeps; empty = every change) and `message` (the
/// CLI's repeatable `-m`; empty = `-m ""`). The selection starts from `@`'s PARENT tree. `@` is
/// rewritten in place (same change id) with the selected changes and the description — its
/// bookmarks follow it and its descendants are rebased onto it — and a NEW `@` on top of it holds
/// the old `@`'s full tree, for every workspace whose `@` was the old `@`. Bookmarks on `@`'s
/// parents that `experimental-advance-branches` selects move to the committed `@`. The operation
/// is `commit <old @ commit hex>`. The working copy is snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success; the new `@`
/// is `new_change_ids`' one entry. `paths` that select no change of `@` warn
/// `jj.commit_paths_unmatched` and still commit.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `CommitRequest` buffer, or its `kind` is
///   not `Commit`.
/// - `jj.no_working_copy` — this workspace has no working-copy commit.
/// - `jj.invalid_input` — a `paths` entry is not a valid repo path, or an
///   `experimental-advance-branches` pattern does not parse; detail in `context`.
/// - `jj.config_error` — an `experimental-advance-branches` list is not a list of strings, or the
///   config does not read.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.CommitRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_commit(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_commit", handle);
    let buf = catch(|| {
        let options = read_commit_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.commit(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use super::read_commit_request;
    use crate::fbs;

    fn request(paths: Option<&[&str]>, message: Option<&[&str]>) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let mut vector = |items: Option<&[&str]>| {
            items.map(|items| {
                let offsets: Vec<_> = items.iter().map(|s| b.create_string(s)).collect();
                b.create_vector(&offsets)
            })
        };
        let paths = vector(paths);
        let message = vector(message);
        let req = fbs::CommitRequest::create(
            &mut b,
            &fbs::CommitRequestArgs {
                kind: fbs::RequestKind::Commit,
                paths,
                message,
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    /// Absent vectors are empty; present ones are read in order.
    #[test]
    fn the_reader_treats_absent_vectors_as_empty() {
        let bytes = request(None, None);
        let options = read_commit_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert!(options.paths.is_empty() && options.message.is_empty());

        let bytes = request(Some(&["x.txt", "dir"]), Some(&["subject", "body"]));
        let options = read_commit_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert_eq!(options.paths, ["x.txt", "dir"]);
        assert_eq!(options.message, ["subject", "body"]);
    }
}
