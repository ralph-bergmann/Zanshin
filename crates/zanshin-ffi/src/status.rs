// SPDX-License-Identifier: MIT

//! `zanshin_status` — working-copy status FFI wrapper (Story 3.4b, status slice).
//!
//! Calls `zanshin_jj::Repo::status()` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying a `Status` payload.  The handle is borrowed
//! (not consumed); `handle_drop` is NOT called here.

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{ChangeKind, FileChange, Status, StatusError};

use crate::envelope::{
    catch, finish_envelope, map_precondition_err, precondition_envelope, session_from_handle, FfiErrorObj,
    JJ_JJ_LIB_ERROR,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};

// ── Error mapping ─────────────────────────────────────────────────────────────

fn map_status_err(e: StatusError) -> FfiErrorObj {
    match e {
        StatusError::Precondition(e) => map_precondition_err(e),
        StatusError::Backend(reason) => FfiErrorObj {
            report: None,
            hints: Vec::new(),
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

// ── Status → FlatBuffers builder ──────────────────────────────────────────────

/// Build the `[FileChange]` vector into `b` and return its offset.
///
/// Children are built before parents (`FlatBuffers` requirement): each `FileChange` table is
/// completed before its offset is collected, and the vector comes after the loop. `from_path`
/// is written ONLY for Renamed/Copied — null-for-absence.
///
/// Extracted so `status`, Story 9.6's `ShowEntry` and its `InterdiffView` all serialise the
/// shipped per-path change vocabulary through one construction site — the same move Story 9.5
/// made for `build_mutation_result`.
pub(crate) fn file_changes_vector<'a>(
    b: &mut FlatBufferBuilder<'a>,
    files: &[FileChange],
) -> flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<fbs::FileChange<'a>>>> {
    let mut file_offsets = Vec::with_capacity(files.len());
    for fc in files {
        let path_off = b.create_string(&fc.path.to_string_lossy());
        let (kind, from_off) = change_kind_offset(b, &fc.kind);
        let fc_off = fbs::FileChange::create(
            b,
            &fbs::FileChangeArgs {
                path: Some(path_off),
                kind,
                from_path: from_off,
            },
        );
        file_offsets.push(fc_off);
    }
    b.create_vector(&file_offsets)
}

/// The wire `ChangeKind` and its `from_path` — written ONLY for Renamed/Copied. Shared with the
/// `Diff` payload's `FileDiff` (Story 5.6).
pub(crate) fn change_kind_offset<'a>(
    b: &mut FlatBufferBuilder<'a>,
    kind: &ChangeKind,
) -> (fbs::ChangeKind, Option<flatbuffers::WIPOffset<&'a str>>) {
    match kind {
        ChangeKind::Added => (fbs::ChangeKind::Added, None),
        ChangeKind::Modified => (fbs::ChangeKind::Modified, None),
        ChangeKind::Removed => (fbs::ChangeKind::Removed, None),
        ChangeKind::Renamed { from } => (fbs::ChangeKind::Renamed, Some(b.create_string(&from.to_string_lossy()))),
        ChangeKind::Copied { from } => (fbs::ChangeKind::Copied, Some(b.create_string(&from.to_string_lossy()))),
    }
}

/// Serialise `&Status` into a finished `FlatBuffers` `Envelope<Status>` buffer.
fn status_to_envelope(status: &Status, report: &crate::envelope::CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);

    // 1)+2) Build the FileChange vector, then the two change-id strings — each only when
    // present (absent exactly when the workspace has no `@`; null-for-absence).
    let files_vec = file_changes_vector(&mut b, &status.files);
    let wc_off = status.working_copy_change_id.as_ref().map(|id| b.create_string(&id.0));
    let parent_off = status.parent_change_id.as_ref().map(|id| b.create_string(&id.0));

    // 3) Status table.
    let status_off = fbs::Status::create(
        &mut b,
        &fbs::StatusArgs {
            files: Some(files_vec),
            working_copy_change_id: wc_off,
            parent_change_id: parent_off,
        },
    );

    // 4) Envelope — plain finish (NOT size-prefixed; length rides in ZanshinBuf.len).
    finish_envelope(b, fbs::Payload::Status, Some(status_off.as_union_value()), report)
}

// ── extern "C" ────────────────────────────────────────────────────────────────

/// Read the working-copy status of the repo identified by `handle`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `Status` payload on success. A workspace
/// without a working-copy commit (@) succeeds like the CLI's `jj status` ("No working copy."):
/// `files` is empty and both change ids are ABSENT.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.config_error` — the pre-verb snapshot (Story 9.26) found the effective jj config
///   unreadable or a knob it reads wrongly typed (the key in `context`). Operations the snapshot
///   committed before the fault stay, as in the CLI (colocated: `import git head`); the partial
///   `precondition` says which.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
/// - `jj.jj_lib_error` — an unclassified jj-lib error; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, or `zanshin_repo_clone` that has not been closed.
/// `0` is detected and returned as `ffi.invalid_handle`.
/// A stale non-zero handle is undefined behaviour; the Dart worker's Model-A
/// handle table (Story 3.9) makes a stale handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_status(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_status", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let status = session.repo.status();
        precondition_envelope(&mut session.repo, status, map_status_err, status_to_envelope)
    });
    vec_into_token(buf)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use std::path::PathBuf;
    use zanshin_jj::{ChangeId, ChangeKind, FileChange, Status};

    use crate::fbs;

    use super::status_to_envelope;

    /// Verify the `Status → Envelope` builder for all five `ChangeKind` variants.
    ///
    /// Constructs a synthetic `Status` with one entry per kind, serialises it,
    /// parses it back through the generated typed accessors and the `FlatBuffers`
    /// `Verifier`, and asserts structural correctness.
    #[test]
    fn status_to_envelope_all_change_kinds() {
        let status = Status {
            files: vec![
                FileChange {
                    path: PathBuf::from("added.rs"),
                    kind: ChangeKind::Added,
                },
                FileChange {
                    path: PathBuf::from("modified.rs"),
                    kind: ChangeKind::Modified,
                },
                FileChange {
                    path: PathBuf::from("removed.rs"),
                    kind: ChangeKind::Removed,
                },
                FileChange {
                    path: PathBuf::from("new_name.rs"),
                    kind: ChangeKind::Renamed {
                        from: PathBuf::from("old_name.rs"),
                    },
                },
                FileChange {
                    path: PathBuf::from("copy.rs"),
                    kind: ChangeKind::Copied {
                        from: PathBuf::from("source.rs"),
                    },
                },
            ],
            working_copy_change_id: Some(ChangeId("qpvuntsm".to_owned())),
            parent_change_id: Some(ChangeId("zzzzzzzz".to_owned())),
        };

        let buf = status_to_envelope(&status, &crate::envelope::CallReport::default());
        let env = fb_root::<fbs::Envelope>(&buf).expect("Verifier must pass");

        assert!(env.ok(), "envelope ok must be true");
        assert_eq!(env.data_type(), fbs::Payload::Status, "data_type must be Status");

        let payload = env
            .data_as_status()
            .expect("data_as_status must succeed for Payload::Status");

        let files = payload.files().expect("files must be present");
        assert_eq!(files.len(), 5, "must have five FileChange entries");

        // Added
        let f0 = files.get(0);
        assert_eq!(f0.path(), Some("added.rs"));
        assert_eq!(f0.kind(), fbs::ChangeKind::Added);
        assert!(f0.from_path().is_none(), "Added must have no from_path");

        // Modified
        let f1 = files.get(1);
        assert_eq!(f1.path(), Some("modified.rs"));
        assert_eq!(f1.kind(), fbs::ChangeKind::Modified);
        assert!(f1.from_path().is_none());

        // Removed
        let f2 = files.get(2);
        assert_eq!(f2.path(), Some("removed.rs"));
        assert_eq!(f2.kind(), fbs::ChangeKind::Removed);
        assert!(f2.from_path().is_none());

        // Renamed
        let f3 = files.get(3);
        assert_eq!(f3.path(), Some("new_name.rs"));
        assert_eq!(f3.kind(), fbs::ChangeKind::Renamed);
        assert_eq!(f3.from_path(), Some("old_name.rs"), "Renamed must carry from_path");

        // Copied
        let f4 = files.get(4);
        assert_eq!(f4.path(), Some("copy.rs"));
        assert_eq!(f4.kind(), fbs::ChangeKind::Copied);
        assert_eq!(f4.from_path(), Some("source.rs"), "Copied must carry from_path");

        // Change-id round-trip
        assert_eq!(payload.working_copy_change_id(), Some("qpvuntsm"));
        assert_eq!(payload.parent_change_id(), Some("zzzzzzzz"));
    }

    /// A workspace without `@` serialises as an ok `Status` with no files and both change ids
    /// ABSENT — the CLI's "No working copy.".
    #[test]
    fn status_to_envelope_without_a_working_copy_leaves_both_ids_absent() {
        let status = Status {
            files: vec![],
            working_copy_change_id: None,
            parent_change_id: None,
        };

        let buf = status_to_envelope(&status, &crate::envelope::CallReport::default());
        let env = fb_root::<fbs::Envelope>(&buf).expect("Verifier must pass");

        assert!(env.ok());
        let payload = env.data_as_status().expect("a Status payload");
        assert_eq!(payload.files().map(|files| files.len()), Some(0));
        assert_eq!(payload.working_copy_change_id(), None);
        assert_eq!(payload.parent_change_id(), None);
    }

    /// Verify `map_status_err` maps `Backend` to `jj.jj_lib_error`, forwarding the reason as
    /// context.
    #[test]
    fn map_status_err_maps_backend_to_jj_lib_error() {
        use zanshin_jj::StatusError;

        let backend = super::map_status_err(StatusError::Backend("boom".to_owned()));
        assert_eq!(backend.code, crate::envelope::JJ_JJ_LIB_ERROR);
        assert_eq!(
            backend.context.as_deref(),
            Some("boom"),
            "Backend forwards the jj-lib reason as context"
        );
    }
}
