// SPDX-License-Identifier: MIT

//! `zanshin_status` — working-copy status FFI wrapper (Story 3.4b, status slice).
//!
//! Calls `zanshin_jj::Repo::status()` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying a `Status` payload.  The handle is borrowed
//! (not consumed); `handle_drop` is NOT called here.

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{ChangeKind, Status, StatusError};

use crate::envelope::{catch, FfiErrorObj, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR, JJ_NO_WORKING_COPY};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;
use crate::repo::RepoSession;

// ── Error mapping ─────────────────────────────────────────────────────────────

fn map_status_err(e: StatusError) -> FfiErrorObj {
    match e {
        StatusError::NoWorkingCopy => FfiErrorObj {
            code: JJ_NO_WORKING_COPY.to_owned(),
            context: None,
        },
        StatusError::Backend(reason) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

// ── Status → FlatBuffers builder ──────────────────────────────────────────────

/// Serialise `&Status` into a finished `FlatBuffers` `Envelope<Status>` buffer.
///
/// Children are built before parents (`FlatBuffers` requirement): each
/// `FileChange` table is completed before its offset is collected; the
/// `files` vector, id strings, and `Status` table are built after the loop.
fn status_to_envelope(status: &Status) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);

    // 1) Build one FileChange per entry — strings then table, in order.
    let mut file_offsets = Vec::with_capacity(status.files.len());
    for fc in &status.files {
        let path_off = b.create_string(&fc.path.to_string_lossy());
        let (kind, from_off) = match &fc.kind {
            ChangeKind::Added => (fbs::ChangeKind::Added, None),
            ChangeKind::Modified => (fbs::ChangeKind::Modified, None),
            ChangeKind::Removed => (fbs::ChangeKind::Removed, None),
            ChangeKind::Renamed { from } => (fbs::ChangeKind::Renamed, Some(b.create_string(&from.to_string_lossy()))),
            ChangeKind::Copied { from } => (fbs::ChangeKind::Copied, Some(b.create_string(&from.to_string_lossy()))),
        };
        let fc_off = fbs::FileChange::create(
            &mut b,
            &fbs::FileChangeArgs {
                path: Some(path_off),
                kind,
                from_path: from_off,
            },
        );
        file_offsets.push(fc_off);
    }

    // 2) Build the vector and the two change-id strings (after all FileChange tables).
    let files_vec = b.create_vector(&file_offsets);
    let wc_off = b.create_string(&status.working_copy_change_id.0);
    let parent_off = b.create_string(&status.parent_change_id.0);

    // 3) Status table.
    let status_off = fbs::Status::create(
        &mut b,
        &fbs::StatusArgs {
            files: Some(files_vec),
            working_copy_change_id: Some(wc_off),
            parent_change_id: Some(parent_off),
        },
    );

    // 4) Envelope — plain finish (NOT size-prefixed; length rides in ZanshinBuf.len).
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::Status,
            data: Some(status_off.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

// ── extern "C" ────────────────────────────────────────────────────────────────

/// Read the working-copy status of the repo identified by `handle`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `Status` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.no_working_copy` — the workspace has no working-copy commit (@).
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
        // SAFETY: non-zero handle originated from arm_session's handle_into_raw
        // (Box<RepoSession>) in zanshin_repo_open/init/clone/convert; single-isolate
        // model (AD-2) guarantees no concurrent access.
        let session =
            unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(|| FfiErrorObj {
                code: FFI_INVALID_HANDLE.to_owned(),
                context: None,
            })?;
        let status = session.repo.status().map_err(map_status_err)?;
        Ok(status_to_envelope(&status))
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
            working_copy_change_id: ChangeId("qpvuntsm".to_owned()),
            parent_change_id: ChangeId("zzzzzzzz".to_owned()),
        };

        let buf = status_to_envelope(&status);
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

    /// Verify `map_status_err` maps both `StatusError` variants to their documented
    /// codes — the only test exercising the new `jj.no_working_copy` code and the
    /// `Backend` → `jj.jj_lib_error` context forwarding.
    #[test]
    fn map_status_err_maps_both_variants() {
        use zanshin_jj::StatusError;

        let no_wc = super::map_status_err(StatusError::NoWorkingCopy);
        assert_eq!(no_wc.code, crate::envelope::JJ_NO_WORKING_COPY);
        assert!(no_wc.context.is_none(), "NoWorkingCopy carries no context");

        let backend = super::map_status_err(StatusError::Backend("boom".to_owned()));
        assert_eq!(backend.code, crate::envelope::JJ_JJ_LIB_ERROR);
        assert_eq!(
            backend.context.as_deref(),
            Some("boom"),
            "Backend forwards the jj-lib reason as context"
        );
    }
}
