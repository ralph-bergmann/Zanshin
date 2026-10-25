// SPDX-License-Identifier: MIT

//! `zanshin_resolve_list` / `zanshin_resolve` — the CLI's `jj resolve --list` and `jj resolve`
//! (Story 9.17), its merge editor replaced by the GUI's.
//!
//! Each calls `zanshin_jj::Repo::resolve_list` / `resolve` and serialises the result into a
//! `FlatBuffers` `Envelope`. The arguments cross as a `ResolveListRequest` / `ResolveRequest`
//! request BUFFER (ADR-0001 composite-input pattern). The handle is borrowed, never consumed. Both
//! run the pre-verb snapshot (Story 9.26), so every envelope carries the precondition report and
//! the call's warnings.

use flatbuffers::{ForwardsUOffset, Vector, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ChangeId, MutateError, ResolveListOptions, ResolveOptions, ResolveTool, ResolvedFile};

use crate::envelope::{
    catch, expect_request_kind, invalid_request, ok_mutation_result, ok_resolve_list, precondition_envelope,
    reject_null_request, session_from_handle, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

/// A string vector as owned strings; ABSENT is empty.
fn strings(v: Option<Vector<'_, ForwardsUOffset<&str>>>) -> Vec<String> {
    v.map(|v| v.iter().map(ToOwned::to_owned).collect()).unwrap_or_default()
}

/// Parse a `ResolveListRequest` buffer into owned [`ResolveListOptions`]; an absent `revision` is
/// `@`, absent `paths` every path.
///
/// `data`/`len` describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for
/// the call only. The byte slice lives in this function's scope and the result is OWNED, so the
/// unbounded lifetime `std::slice::from_raw_parts` produces cannot outlive the call.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ResolveListRequest` buffer, or its
///   `kind` is not `ResolveList`.
fn read_resolve_list_request(data: *const u8, len: usize) -> Result<ResolveListOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ResolveListRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::ResolveList)?;
    Ok(ResolveListOptions {
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        paths: strings(req.paths()),
    })
}

/// Parse a `ResolveRequest` buffer into owned [`ResolveOptions`]; an absent `revision` is `@`,
/// absent `paths` / `files` / a file's `term_ids` empty (`zanshin_jj` refuses a file without term
/// ids as `jj.invalid_input`), an absent term `id` no file on that term.
///
/// `data`/`len` as for [`read_resolve_list_request`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ResolveRequest` buffer, or its `kind`
///   is not `Resolve`.
/// - `jj.invalid_input` — `files` together with `tool` `Ours` or `Theirs`, or an unknown `tool`.
fn read_resolve_request(data: *const u8, len: usize) -> Result<ResolveOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ResolveRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Resolve)?;
    let files: Vec<ResolvedFile> = req
        .files()
        .map(|files| {
            files
                .iter()
                .map(|file| ResolvedFile {
                    path: file.path().unwrap_or_default().to_owned(),
                    content: file.content().map(|c| c.bytes().to_vec()).unwrap_or_default(),
                    term_ids: file
                        .term_ids()
                        .map(|ids| ids.iter().map(|id| id.id().map(ToOwned::to_owned)).collect())
                        .unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default();
    let tool = match req.tool() {
        fbs::ResolveTool::Ours if files.is_empty() => ResolveTool::Ours,
        fbs::ResolveTool::Theirs if files.is_empty() => ResolveTool::Theirs,
        fbs::ResolveTool::Ours | fbs::ResolveTool::Theirs => {
            return Err(map_mutate_err(MutateError::invalid(
                "files can only be given with the files tool".to_owned(),
            )))
        }
        fbs::ResolveTool::Files => ResolveTool::Files(files),
        other => {
            return Err(map_mutate_err(MutateError::invalid(format!(
                "unknown resolve tool {}",
                other.0
            ))))
        }
    };
    Ok(ResolveOptions {
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        paths: strings(req.paths()),
        tool,
    })
}

/// List a revision's conflicts with what a merge editor needs, in the repo identified by `handle`
/// — the CLI's `jj resolve --list` (Story 9.17), plus each file conflict's merge hunks.
///
/// The arguments cross as a `ResolveListRequest` `FlatBuffers` request buffer: `revision` (absent:
/// `@`) and `paths` (repo-relative PREFIXES; absent or empty: every conflict). An explicitly named
/// absent path warns `jj.paths_unmatched`. Writes NO operation beyond the pre-verb snapshot's.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `ResolveList` payload on success: per matched
/// conflict, in tree order, its path, the CLI's `--list` description, its side count, why
/// `zanshin_resolve` would refuse it (absent: it can take it) and — for a file conflict — its
/// labels, merge hunks (each conflicting hunk's terms: side 1, base 1, side 2, …) and term ids
/// (hex, an absent `id` = no file on that term), which `zanshin_resolve`'s files send back.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ResolveListRequest` buffer, or its
///   `kind` is not `ResolveList`.
/// - `jj.invalid_input` — a `paths` entry is not a valid repo path.
/// - `jj.change_not_found` — `revision` is malformed, carried by no VISIBLE commit, or divergent.
/// - `jj.revset_resolution_error` — an omitted revision's `@` in a workspace with no working-copy
///   commit.
/// - `jj.no_conflicts` — nothing matched; the CLI's text in `context`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.ResolveListRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_resolve_list(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_resolve_list", handle);
    let buf = catch(|| {
        let options = read_resolve_list_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.resolve_list(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_resolve_list)
    });
    vec_into_token(buf)
}

/// Resolve a revision's conflicts in the repo identified by `handle` — the CLI's `jj resolve`
/// (Story 9.17).
///
/// The arguments cross as a `ResolveRequest` `FlatBuffers` request buffer: `revision` (absent:
/// `@`), `paths` (repo-relative PREFIXES; absent or empty: every conflict) and `tool` — `Ours` /
/// `Theirs` take side 1 / side 2 (`--tool :ours` / `:theirs`), `Files` writes each of `files` (the
/// GUI merge editor's output; the files are the paths) as the builtin merge editor writes a file,
/// each carrying the `term_ids` `zanshin_resolve_list` reported (the staleness token).
/// The revision must be rewritable; its descendants are rebased; the operation is `Resolve
/// conflicts in commit <hex>`. A revision that is not `@` and still has conflicts warns
/// `jj.resolve_conflicts_remain`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ResolveRequest` buffer, or its `kind`
///   is not `Resolve`.
/// - `jj.invalid_input` — `files` with `Ours`/`Theirs`, `Files` with `paths` or without files, an
///   invalid, root or duplicate file path, a file without `term_ids` (all before the snapshot:
///   nothing written, no `precondition`), or a `paths` entry is not a valid repo path; detail in
///   `context`.
/// - `jj.change_not_found` — `revision` is malformed, carried by no VISIBLE commit, or divergent.
/// - `jj.revset_resolution_error` — an omitted revision's `@` in a workspace with no working-copy
///   commit.
/// - `jj.no_conflicts` — nothing matched; the CLI's text in `context`.
/// - `jj.immutable` — the revision is inside the immutable set; its hex id in `context`.
/// - `jj.stale_selection` — a file is not a conflict at the revision (the CLI's text in
///   `context`), or its conflict's term ids are no longer the file's `term_ids`, or it is not a
///   file conflict (a non-file conflict cannot go through `Files`).
/// - `jj.conflict_not_resolvable` — a conflict a 3-way merge tool cannot take; the CLI's text in
///   `context`.
/// - `jj.config_error` — the `immutable_heads()` alias does not resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.not_a_git_repo` — the colocated finish found no Git backend.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// As [`zanshin_resolve_list`], with a `ResolveRequest` buffer
/// (`fbs.ResolveRequestObjectBuilder(...).toBytes()`).
#[no_mangle]
pub unsafe extern "C" fn zanshin_resolve(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_resolve", handle);
    let buf = catch(|| {
        let options = read_resolve_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.resolve(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use zanshin_jj::ResolveTool;

    use super::{read_resolve_list_request, read_resolve_request};
    use crate::envelope::{FFI_INVALID_ARGUMENT, JJ_INVALID_INPUT};
    use crate::fbs;

    fn list_request(kind: fbs::RequestKind) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
        let revision = b.create_string("rev");
        let path = b.create_string("p");
        let paths = b.create_vector(&[path]);
        let req = fbs::ResolveListRequest::create(
            &mut b,
            &fbs::ResolveListRequestArgs {
                kind,
                revision: Some(revision),
                paths: Some(paths),
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    fn resolve_request(kind: fbs::RequestKind, tool: fbs::ResolveTool, files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let files: Vec<_> = files
            .iter()
            .map(|&(path, content)| {
                let path = b.create_string(path);
                let content = b.create_vector(content);
                let id = b.create_string("ab");
                let present = fbs::ConflictTermId::create(&mut b, &fbs::ConflictTermIdArgs { id: Some(id) });
                let absent = fbs::ConflictTermId::create(&mut b, &fbs::ConflictTermIdArgs { id: None });
                let term_ids = b.create_vector(&[present, absent]);
                fbs::ResolvedFile::create(
                    &mut b,
                    &fbs::ResolvedFileArgs {
                        path: Some(path),
                        content: Some(content),
                        term_ids: Some(term_ids),
                    },
                )
            })
            .collect();
        let files = b.create_vector(&files);
        let req = fbs::ResolveRequest::create(
            &mut b,
            &fbs::ResolveRequestArgs {
                kind,
                revision: None,
                paths: None,
                tool,
                files: Some(files),
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    #[test]
    fn the_list_reader_reads_every_field_and_refuses_another_kind() {
        let bytes = list_request(fbs::RequestKind::ResolveList);
        let options = read_resolve_list_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert_eq!(options.revision.map(|r| r.0).as_deref(), Some("rev"));
        assert_eq!(options.paths, ["p"]);
        let bytes = list_request(fbs::RequestKind::Resolve);
        let err = read_resolve_list_request(bytes.as_ptr(), bytes.len()).expect_err("wrong kind");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
    }

    #[test]
    fn the_resolve_reader_maps_each_tool_and_refuses_files_with_ours_or_theirs() {
        let bytes = resolve_request(fbs::RequestKind::Resolve, fbs::ResolveTool::Files, &[("c", b"x\n")]);
        let options = read_resolve_request(bytes.as_ptr(), bytes.len()).expect("files");
        let ResolveTool::Files(files) = options.tool else {
            panic!("files tool");
        };
        assert_eq!(files[0].path, "c");
        assert_eq!(files[0].content, b"x\n");
        assert_eq!(files[0].term_ids, [Some("ab".to_owned()), None]);
        assert!(options.revision.is_none() && options.paths.is_empty());
        for (wire, tool) in [
            (fbs::ResolveTool::Ours, ResolveTool::Ours),
            (fbs::ResolveTool::Theirs, ResolveTool::Theirs),
        ] {
            let bytes = resolve_request(fbs::RequestKind::Resolve, wire, &[]);
            assert_eq!(
                read_resolve_request(bytes.as_ptr(), bytes.len()).expect("tool").tool,
                tool
            );
            let bytes = resolve_request(fbs::RequestKind::Resolve, wire, &[("c", b"x")]);
            let err = read_resolve_request(bytes.as_ptr(), bytes.len()).expect_err("files with a tool");
            assert_eq!(err.code, JJ_INVALID_INPUT);
        }
        let bytes = resolve_request(fbs::RequestKind::Resolve, fbs::ResolveTool(9), &[]);
        let err = read_resolve_request(bytes.as_ptr(), bytes.len()).expect_err("unknown tool");
        assert_eq!(err.code, JJ_INVALID_INPUT);
        let bytes = resolve_request(fbs::RequestKind::ResolveList, fbs::ResolveTool::Ours, &[]);
        let err = read_resolve_request(bytes.as_ptr(), bytes.len()).expect_err("wrong kind");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
    }
}
