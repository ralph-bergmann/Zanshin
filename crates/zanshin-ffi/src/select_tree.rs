// SPDX-License-Identifier: MIT

//! `zanshin_select_tree` — a GUI hunk selection turned into a tree (Story 9.50), the CLI's builtin
//! diff editor applying the same choice; plus the `TreeSelection` reader the tree arms of
//! `zanshin_commit` / `zanshin_split` / `zanshin_squash` share.
//!
//! Calls `zanshin_jj::Repo::select_tree` and serialises the result into a `FlatBuffers`
//! `Envelope`. The arguments cross as a `SelectTreeRequest` request BUFFER (ADR-0001
//! composite-input pattern). The handle is borrowed, never consumed. The call runs the pre-verb
//! snapshot (Story 9.26), so every envelope carries the precondition report and the call's
//! warnings.

use flatbuffers::{ForwardsUOffset, Vector, VerifierOptions};
use tracing::debug;
use zanshin_jj::{
    ChangeId, FileChoice, FileSelection, HunkKey, MutateError, SelectTreeOptions, SelectedTreeId, TreeSelection,
};

use crate::envelope::{
    catch, expect_request_kind, invalid_request, ok_selected_tree, precondition_envelope, reject_null_request,
    session_from_handle, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

/// A string vector as owned strings; ABSENT is empty.
fn strings(v: Option<Vector<'_, ForwardsUOffset<&str>>>) -> Vec<String> {
    v.map(|v| v.iter().map(ToOwned::to_owned).collect()).unwrap_or_default()
}

/// A `TreeSelection` table as the owned [`TreeSelection`] the tree arms take; absent vectors are
/// empty (which `zanshin_jj` refuses as `jj.invalid_input` for the ids and `left`).
pub(crate) fn tree_selection(table: fbs::TreeSelection<'_>) -> TreeSelection {
    TreeSelection {
        tree: SelectedTreeId {
            tree_ids: strings(table.tree_ids()),
            labels: strings(table.labels()),
        },
        left: strings(table.left()),
    }
}

/// A `FileSelection` table as an owned [`FileSelection`].
///
/// # Errors
/// - `jj.invalid_input` — `whole` together with a non-empty `hunks` or with `mode`: whole excludes
///   the other ways of selecting a file.
fn file_selection(table: fbs::FileSelection<'_>) -> Result<FileSelection, FfiErrorObj> {
    let path = table.path().unwrap_or_default().to_owned();
    let hunks: Vec<HunkKey> = table
        .hunks()
        .map(|hunks| {
            hunks
                .iter()
                .map(|key| HunkKey {
                    old_start: key.old_start(),
                    old_count: key.old_count(),
                    new_start: key.new_start(),
                    new_count: key.new_count(),
                })
                .collect()
        })
        .unwrap_or_default();
    let choice = match (table.whole(), table.mode(), hunks.is_empty()) {
        (true, _, false) => {
            return Err(map_mutate_err(MutateError::invalid(format!(
                "{path} is selected whole and by hunks"
            ))))
        }
        (true, true, true) => {
            return Err(map_mutate_err(MutateError::invalid(format!(
                "{path} is selected whole and by its mode"
            ))))
        }
        (true, false, true) => FileChoice::Whole,
        (false, true, _) => FileChoice::ModeAndHunks(hunks),
        (false, false, _) => FileChoice::Hunks(hunks),
    };
    Ok(FileSelection { path, choice })
}

/// Parse a `SelectTreeRequest` buffer into owned [`SelectTreeOptions`]; absent vectors are empty,
/// an absent `revision` is `@`.
///
/// `data`/`len` describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for
/// the call only. The byte slice lives in this function's scope and the result is OWNED, so the
/// unbounded lifetime `std::slice::from_raw_parts` produces cannot outlive the call.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `SelectTreeRequest` buffer, or its
///   `kind` is not `SelectTree`.
/// - `jj.invalid_input` — a file is selected `whole` and by `hunks` or its `mode`.
fn read_select_tree_request(data: *const u8, len: usize) -> Result<SelectTreeOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::SelectTreeRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::SelectTree)?;
    let files = req
        .files()
        .map(|files| files.iter().map(file_selection).collect::<Result<Vec<_>, _>>())
        .transpose()?
        .unwrap_or_default();
    Ok(SelectTreeOptions {
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        left: strings(req.left()),
        files,
    })
}

/// Write the tree a hunk selection yields, in the repo identified by `handle` — the CLI's builtin
/// diff editor applying the same choice (Story 9.50), for the tree arms of `zanshin_commit`,
/// `zanshin_split` and `zanshin_squash`.
///
/// The arguments cross as a `SelectTreeRequest` `FlatBuffers` request buffer: `revision` (absent:
/// `@`), `left` (the revision's parent tree the selection was made against, as
/// `ShowEntry.parent_tree_ids` reports it) and `files` (per path `whole`, or the selected `hunks`
/// by their `HunkKey` with or without `mode`, the builtin editor's mode toggle; a changed file not
/// listed, and every unselected section, keeps its left side). A file has sections when both
/// sides are a regular file or a file conflict (materialized with `ui.conflict-marker-style`) and
/// UTF-8 text without NUL bytes, and a mode toggle when both such sides differ in mode; added and
/// deleted files, symlinks, submodules, non-file conflicts and binary content are selected whole.
/// Writes NO operation — only the tree's objects
/// reach the store — beyond the pre-verb snapshot's (Story 9.26). A change to the revision's own
/// content after the selection is not stale.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `SelectedTree` payload on success: the tree ids
/// and labels to pass, with `left`, as a verb's `TreeSelection`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `SelectTreeRequest` buffer, or its
///   `kind` is not `SelectTree`.
/// - `jj.invalid_input` — a file selected `whole` and by `hunks` or its `mode`, `left` malformed or of an even or
///   zero count, a path invalid, the root or listed twice — all before the snapshot: nothing
///   written, no `precondition`; detail in `context`.
/// - `jj.change_not_found` — `revision` is malformed, carried by no VISIBLE commit, or divergent.
/// - `jj.revset_resolution_error` — an omitted revision's `@` in a workspace with no working-copy
///   commit.
/// - `jj.stale_selection` — the revision's parent tree is not `left`, a key is not a current
///   section of its file, or `mode` names a file without a mode change; detail in `context`.
/// - `jj.config_error` — the effective config does not read, or `ui.conflict-marker-style` is not
///   one of jj's styles.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.SelectTreeRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_select_tree(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_select_tree", handle);
    let buf = catch(|| {
        let options = read_select_tree_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.select_tree(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_selected_tree)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use zanshin_jj::{FileChoice, HunkKey};

    use super::read_select_tree_request;
    use crate::envelope::{FFI_INVALID_ARGUMENT, JJ_INVALID_INPUT};
    use crate::fbs;

    /// One file: `path`, `whole`, `mode`, and `hunks` as `(old_start, old_count, new_start,
    /// new_count)`.
    type File<'a> = (&'a str, bool, bool, Option<&'a [(u32, u32, u32, u32)]>);

    fn request(kind: fbs::RequestKind, revision: Option<&str>, left: &[&str], files: &[File<'_>]) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let file_offsets: Vec<_> = files
            .iter()
            .map(|&(path, whole, mode, hunks)| {
                let path = b.create_string(path);
                let hunks = hunks.map(|hunks| {
                    let keys: Vec<_> = hunks
                        .iter()
                        .map(|&(old_start, old_count, new_start, new_count)| {
                            fbs::HunkKey::create(
                                &mut b,
                                &fbs::HunkKeyArgs {
                                    old_start,
                                    old_count,
                                    new_start,
                                    new_count,
                                },
                            )
                        })
                        .collect();
                    b.create_vector(&keys)
                });
                fbs::FileSelection::create(
                    &mut b,
                    &fbs::FileSelectionArgs {
                        path: Some(path),
                        whole,
                        hunks,
                        mode,
                    },
                )
            })
            .collect();
        let files = b.create_vector(&file_offsets);
        let left: Vec<_> = left.iter().map(|id| b.create_string(id)).collect();
        let left = b.create_vector(&left);
        let revision = revision.map(|r| b.create_string(r));
        let req = fbs::SelectTreeRequest::create(
            &mut b,
            &fbs::SelectTreeRequestArgs {
                kind,
                revision,
                left: Some(left),
                files: Some(files),
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    /// Every field is read; a file is whole, or its hunks (absent hunks: none), with or without
    /// its mode.
    #[test]
    fn the_reader_reads_every_field() {
        let bytes = request(
            fbs::RequestKind::SelectTree,
            Some("rev"),
            &["l1"],
            &[
                ("a", true, false, None),
                ("b", false, false, Some(&[(0, 1, 0, 2)])),
                ("c", false, false, None),
                ("d", false, true, None),
                ("e", false, true, Some(&[(0, 1, 0, 2)])),
            ],
        );
        let options = read_select_tree_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert_eq!(options.revision.map(|r| r.0).as_deref(), Some("rev"));
        assert_eq!(options.left, ["l1"]);
        assert_eq!(options.files[0].choice, FileChoice::Whole);
        assert_eq!(
            options.files[1].choice,
            FileChoice::Hunks(vec![HunkKey {
                old_start: 0,
                old_count: 1,
                new_start: 0,
                new_count: 2,
            }])
        );
        assert_eq!(options.files[2].choice, FileChoice::Hunks(Vec::new()));
        assert_eq!(options.files[1].path, "b");
        assert_eq!(options.files[3].choice, FileChoice::ModeAndHunks(Vec::new()));
        assert_eq!(
            options.files[4].choice,
            FileChoice::ModeAndHunks(vec![HunkKey {
                old_start: 0,
                old_count: 1,
                new_start: 0,
                new_count: 2,
            }])
        );
    }

    /// `whole` together with hunks or with the mode refuses `jj.invalid_input`; a request of
    /// another kind `ffi.invalid_argument`.
    #[test]
    fn the_reader_refuses_whole_with_hunks_or_mode_and_another_kind() {
        let bytes = request(
            fbs::RequestKind::SelectTree,
            None,
            &["l1"],
            &[("a", true, false, Some(&[(0, 1, 0, 1)]))],
        );
        let err = read_select_tree_request(bytes.as_ptr(), bytes.len()).expect_err("whole with hunks");
        assert_eq!(err.code, JJ_INVALID_INPUT);

        let bytes = request(fbs::RequestKind::SelectTree, None, &["l1"], &[("a", true, true, None)]);
        let err = read_select_tree_request(bytes.as_ptr(), bytes.len()).expect_err("whole with mode");
        assert_eq!(err.code, JJ_INVALID_INPUT);
        assert_eq!(err.context.as_deref(), Some("a is selected whole and by its mode"));

        let bytes = request(fbs::RequestKind::Commit, None, &["l1"], &[]);
        let err = read_select_tree_request(bytes.as_ptr(), bytes.len()).expect_err("wrong kind");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
    }
}
