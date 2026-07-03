// SPDX-License-Identifier: MIT

//! `zanshin_bookmarks` — bookmark-list read FFI wrapper (Story 3.4b, bookmarks slice).
//!
//! Calls `zanshin_jj::Repo::list_bookmarks()` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying a `Bookmarks` payload. The handle is borrowed
//! (not consumed).

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{Bookmark, BookmarkError, BookmarkKind};

use crate::envelope::{catch, FfiErrorObj, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;
use crate::repo::RepoSession;

fn map_bookmarks_err(e: BookmarkError) -> FfiErrorObj {
    match e {
        BookmarkError::Backend(reason) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

/// Serialise `&[Bookmark]` into a finished `Envelope<Bookmarks>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): for each `Bookmark`, its
/// strings are built before its table; the `bookmarks` vector and `Bookmarks` table
/// come after the loop. `remote_name` is only created for `Remote` entries.
fn bookmarks_to_envelope(bookmarks: &[Bookmark]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mut offsets = Vec::with_capacity(bookmarks.len());
    for bm in bookmarks {
        let name_off = b.create_string(&bm.name);
        let target_off = b.create_string(&bm.target.0);
        let (kind, remote_off) = match &bm.kind {
            BookmarkKind::Local => (fbs::BookmarkKind::Local, None),
            BookmarkKind::Remote { remote_name } => (fbs::BookmarkKind::Remote, Some(b.create_string(remote_name))),
        };
        let bm_off = fbs::Bookmark::create(
            &mut b,
            &fbs::BookmarkArgs {
                name: Some(name_off),
                target: Some(target_off),
                kind,
                remote_name: remote_off,
            },
        );
        offsets.push(bm_off);
    }
    let vec = b.create_vector(&offsets);
    let bms_off = fbs::Bookmarks::create(&mut b, &fbs::BookmarksArgs { bookmarks: Some(vec) });
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::Bookmarks,
            data: Some(bms_off.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// List local + tracked-remote bookmarks of the repo identified by `handle`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `Bookmarks` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` or the borrow yields `None`.
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
pub unsafe extern "C" fn zanshin_bookmarks(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmarks", handle);
    let buf = catch(|| {
        // SAFETY: non-zero handle originated from arm_session's handle_into_raw
        // (Box<RepoSession>) in zanshin_repo_open/init/clone/convert; single-isolate
        // model (AD-2) guarantees no concurrent access.
        let session =
            unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(|| FfiErrorObj {
                code: FFI_INVALID_HANDLE.to_owned(),
                context: None,
            })?;
        let bms = session.repo.list_bookmarks().map_err(map_bookmarks_err)?;
        Ok(bookmarks_to_envelope(&bms))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use zanshin_jj::{Bookmark, BookmarkError, BookmarkKind};

    use super::{bookmarks_to_envelope, map_bookmarks_err};
    use crate::fbs;
    use crate::JJ_JJ_LIB_ERROR;

    fn make_bookmark(name: &str, target: &str, kind: BookmarkKind) -> Bookmark {
        Bookmark {
            name: name.to_owned(),
            target: zanshin_jj::ChangeId(target.to_owned()),
            kind,
        }
    }

    #[test]
    fn bookmarks_to_envelope_roundtrips_both_kinds() {
        let local = make_bookmark("main", "zxqpvuts", BookmarkKind::Local);
        let remote = make_bookmark(
            "feature",
            "qpmxrolk",
            BookmarkKind::Remote {
                remote_name: "origin".to_owned(),
            },
        );

        let buf = bookmarks_to_envelope(&[local.clone(), remote.clone()]);

        let env = fb_root::<fbs::Envelope>(&buf).expect("FlatBuffers Verifier must pass");
        assert!(env.ok(), "envelope must be ok");
        assert_eq!(env.data_type(), fbs::Payload::Bookmarks, "data_type must be Bookmarks");

        let payload = env.data_as_bookmarks().expect("data_as_bookmarks must succeed");
        let fbs_bms = payload.bookmarks().expect("bookmarks must be present");
        assert_eq!(fbs_bms.len(), 2, "must have 2 bookmark entries");

        // Local entry — distinct name/target from the Remote entry, so a
        // cross-wired offset-vector bug would fail this test.
        let fbs_local = fbs_bms.get(0);
        assert_eq!(fbs_local.name(), Some("main"), "local name");
        assert_eq!(fbs_local.target(), Some("zxqpvuts"), "local target");
        assert_eq!(fbs_local.kind(), fbs::BookmarkKind::Local, "local kind");
        assert_eq!(
            fbs_local.remote_name(),
            None,
            "local remote_name must be absent (never serialized for Local)"
        );

        // Remote entry
        let fbs_remote = fbs_bms.get(1);
        assert_eq!(fbs_remote.name(), Some("feature"), "remote name");
        assert_eq!(fbs_remote.target(), Some("qpmxrolk"), "remote target");
        assert_eq!(fbs_remote.kind(), fbs::BookmarkKind::Remote, "remote kind");
        assert_eq!(fbs_remote.remote_name(), Some("origin"), "remote_name must be 'origin'");
    }

    #[test]
    fn bookmarks_to_envelope_empty_roundtrips() {
        let buf = bookmarks_to_envelope(&[]);
        let env = fb_root::<fbs::Envelope>(&buf).expect("verifier must pass");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::Bookmarks);
        let payload = env.data_as_bookmarks().expect("data_as_bookmarks");
        assert_eq!(payload.bookmarks().map_or(0, |b| b.len()), 0, "empty bookmarks list");
    }

    #[test]
    fn map_bookmarks_err_backend_maps_to_jj_lib_error() {
        let obj = map_bookmarks_err(BookmarkError::Backend("boom".into()));
        assert_eq!(obj.code, JJ_JJ_LIB_ERROR, "code must be jj.jj_lib_error");
        assert_eq!(obj.context, Some("boom".to_owned()), "context must be forwarded");
    }
}
