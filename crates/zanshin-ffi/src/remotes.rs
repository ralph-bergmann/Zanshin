// SPDX-License-Identifier: MIT

//! `zanshin_remotes` — remote-list read FFI wrapper (Story 3.4b, remotes slice).
//!
//! Calls `zanshin_jj::Repo::list_remotes()` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying a `Remotes` payload. The handle is borrowed
//! (not consumed). Both `url` and `push_url` cross the wire verbatim (no credential
//! scrubbing); `push_url` is ABSENT when the remote pushes to its fetch URL.

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{Remote, RemoteError};

use crate::envelope::{catch, session_from_handle, FfiErrorObj, JJ_JJ_LIB_ERROR};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};

fn map_remotes_err(e: RemoteError) -> FfiErrorObj {
    match e {
        RemoteError::Backend(reason) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

/// Serialise `&[Remote]` into a finished `Envelope<Remotes>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): for each `Remote`, its
/// strings are built before its table; the `remotes` vector and `Remotes` table
/// come after the loop. No kind match — a `Remote` is just plain strings, one of
/// which (`push_url`) is null-for-absence and stays ABSENT rather than `""`.
fn remotes_to_envelope(remotes: &[Remote]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mut offsets = Vec::with_capacity(remotes.len());
    for r in remotes {
        let name_off = b.create_string(&r.name);
        let url_off = b.create_string(&r.url);
        let push_off = r.push_url.as_deref().map(|s| b.create_string(s));
        let r_off = fbs::Remote::create(
            &mut b,
            &fbs::RemoteArgs {
                name: Some(name_off),
                url: Some(url_off),
                push_url: push_off,
            },
        );
        offsets.push(r_off);
    }
    let vec = b.create_vector(&offsets);
    let rems_off = fbs::Remotes::create(&mut b, &fbs::RemotesArgs { remotes: Some(vec) });
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::Remotes,
            data: Some(rems_off.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// List the configured git remotes of the repo identified by `handle`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `Remotes` payload on success.
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
pub unsafe extern "C" fn zanshin_remotes(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_remotes", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let rems = session.repo.list_remotes().map_err(map_remotes_err)?;
        Ok(remotes_to_envelope(&rems))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root;
    use zanshin_jj::{Remote, RemoteError};

    use super::{map_remotes_err, remotes_to_envelope};
    use crate::envelope::JJ_JJ_LIB_ERROR;
    use crate::fbs;

    #[test]
    fn remotes_to_envelope_roundtrips_multiple_entries() {
        // ≥2 distinct entries; one with embedded credentials to assert no scrubbing.
        // Both `push_url` arms are exercised: absent on index 0, present on index 1.
        let remotes = vec![
            Remote {
                name: "origin".to_owned(),
                url: "https://github.com/user/repo.git".to_owned(),
                push_url: None,
            },
            Remote {
                name: "creds".to_owned(),
                url: "https://user:token@example.com/r.git".to_owned(),
                push_url: Some("ssh://user:s3cr3t@example.com/r.git".to_owned()),
            },
        ];
        let buf = remotes_to_envelope(&remotes);
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::Remotes);
        let payload = env.data_as_remotes().expect("expected Remotes payload");
        let items = payload.remotes().expect("remotes vector");
        assert_eq!(items.len(), 2);
        // index 0: origin — remotes_to_envelope preserves insertion order (no sort here;
        // sorting lives upstream in zanshin-jj::list_remotes).
        assert_eq!(items.get(0).name(), Some("origin"));
        assert_eq!(items.get(0).url(), Some("https://github.com/user/repo.git"));
        assert_eq!(
            items.get(0).push_url(),
            None,
            "absence must stay ABSENT on the wire, never an empty string"
        );
        // index 1: creds with embedded credentials — must NOT be scrubbed
        assert_eq!(items.get(1).name(), Some("creds"));
        let creds_url = items.get(1).url().expect("url must be present");
        assert!(
            creds_url.contains("user:token"),
            "embedded credentials must survive verbatim, got: {creds_url}"
        );
        let push_url = items.get(1).push_url().expect("push_url must be present");
        assert_eq!(push_url, "ssh://user:s3cr3t@example.com/r.git");
        assert!(
            push_url.contains("user:s3cr3t"),
            "push-URL credentials must survive verbatim too, got: {push_url}"
        );
    }

    #[test]
    fn remotes_to_envelope_empty_roundtrips() {
        let buf = remotes_to_envelope(&[]);
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::Remotes);
        let payload = env.data_as_remotes().expect("expected Remotes payload");
        assert_eq!(payload.remotes().map_or(0, |r| r.len()), 0);
    }

    #[test]
    fn map_remotes_err_backend_maps_to_jj_lib_error() {
        let obj = map_remotes_err(RemoteError::Backend("boom".to_owned()));
        assert_eq!(obj.code, JJ_JJ_LIB_ERROR);
        assert_eq!(obj.context, Some("boom".to_owned()));
    }
}
