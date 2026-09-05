// SPDX-License-Identifier: MIT

//! `zanshin_change` — change metadata FFI wrapper (Story 3.4b, change slice).
//!
//! Calls `zanshin_jj::Repo::get_change()` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying a `Change` payload. The handle is borrowed
//! (not consumed); `handle_drop` is NOT called here.

use std::ffi::c_char;
use std::path::PathBuf;

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{Change, ChangeError, ChangeId, ConflictState, Signature};

use crate::envelope::{catch, session_from_handle, FfiErrorObj, JJ_CHANGE_NOT_FOUND, JJ_JJ_LIB_ERROR};
use crate::fbs;
use crate::ffi_strings::{cstr_to_string, vec_into_token, ZanshinBuf};

// ── Error mapping ─────────────────────────────────────────────────────────────

fn map_change_err(e: ChangeError) -> FfiErrorObj {
    match e {
        ChangeError::NotFound { id } => FfiErrorObj {
            code: JJ_CHANGE_NOT_FOUND.to_owned(),
            context: Some(id),
        },
        ChangeError::Backend(reason) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

// ── Change → FlatBuffers builder ──────────────────────────────────────────────

/// Build a `FlatBuffers` `Signature` table from the domain type.
///
/// Children (name/email strings) are created before the table itself.
fn signature_offset<'a>(b: &mut FlatBufferBuilder<'a>, sig: &Signature) -> flatbuffers::WIPOffset<fbs::Signature<'a>> {
    let name = b.create_string(&sig.name);
    let email = b.create_string(&sig.email);
    fbs::Signature::create(
        b,
        &fbs::SignatureArgs {
            name: Some(name),
            email: Some(email),
            timestamp_millis: sig.timestamp.millis_since_epoch,
            tz_offset_minutes: sig.timestamp.tz_offset_minutes,
        },
    )
}

/// Build the `Change` table into `b` and return its offset.
///
/// Children are built before parents (`FlatBuffers` requirement):
/// - Both `Signature` tables (author/committer) are built first.
/// - `parents` string vector and `conflicted_paths` string vector next.
/// - `id`, `commit_id`, and `description` strings after.
/// - `Change` table last.
///
/// Extracted so the TOP-LEVEL form ([`change_to_envelope`], `zanshin_change`) and the NESTED
/// form (Story 9.6's `ShowEntry`/`EvologEntry` in `commit_views.rs`) have exactly one
/// construction site and cannot drift apart — the same move Story 9.5 made for
/// `build_mutation_result`.
pub(crate) fn change_offset<'a>(
    b: &mut FlatBufferBuilder<'a>,
    change: &Change,
) -> flatbuffers::WIPOffset<fbs::Change<'a>> {
    // 1) Children: both Signature tables (their strings first, then the table).
    let author_off = signature_offset(b, &change.author);
    let committer_off = signature_offset(b, &change.committer);

    // 2) parents vector: ChangeId.0 strings → [string].
    let parent_offs: Vec<_> = change.parents.iter().map(|p| b.create_string(&p.0)).collect();
    let parents_vec = b.create_vector(&parent_offs);

    // 3) Conflict state + conflicted_paths vector (if any).
    let (conflict, conflicted_paths_vec) = match &change.conflict {
        ConflictState::Clean => (fbs::ConflictState::Clean, None),
        ConflictState::Conflicted { paths } => {
            let offs: Vec<_> = paths
                .iter()
                .map(|p: &PathBuf| b.create_string(&p.to_string_lossy()))
                .collect();
            (fbs::ConflictState::Conflicted, Some(b.create_vector(&offs)))
        }
    };

    // 4) id / commit_id / description strings.
    let id_off = b.create_string(&change.id.0);
    let commit_id_off = b.create_string(&change.commit_id.0);
    let desc_off = b.create_string(&change.description);

    // 5) Change table.
    fbs::Change::create(
        b,
        &fbs::ChangeArgs {
            id: Some(id_off),
            commit_id: Some(commit_id_off),
            parents: Some(parents_vec),
            description: Some(desc_off),
            author: Some(author_off),
            committer: Some(committer_off),
            is_signed: change.is_signed,
            conflict,
            conflicted_paths: conflicted_paths_vec,
            is_anonymous: change.is_anonymous,
            divergent: change.divergent,
        },
    )
}

/// Serialise `&Change` into a finished `FlatBuffers` `Envelope<Change>` buffer.
fn change_to_envelope(change: &Change) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let change_off = change_offset(&mut b, change);

    // Envelope — plain finish (NOT size-prefixed; length rides in ZanshinBuf.len).
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::Change,
            data: Some(change_off.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

// ── extern "C" ────────────────────────────────────────────────────────────────

/// Read full metadata for the change identified by `change_id` in the repo
/// referenced by `handle`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `Change` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `change_id` is a null pointer.
/// - `ffi.utf8_error` — `change_id` is not valid UTF-8.
/// - `jj.change_not_found` — no change for the given id (malformed, absent, or hidden-only).
/// - `jj.jj_lib_error` — an unclassified jj-lib error; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, or `zanshin_repo_clone` that has not been closed.
/// `0` is detected and returned as `ffi.invalid_handle`.
/// A stale non-zero handle is undefined behaviour; the Dart worker's Model-A
/// handle table (Story 3.9) makes a stale handle unreachable.
/// `change_id` must be a NUL-terminated UTF-8 C string owned by the caller
/// (Dart allocates it via `toNativeUtf8()` and frees it with `calloc.free()`
/// after this call returns — AR-P-5 inbound rule). Rust only borrows it for
/// the duration of the call; it is never freed on the Rust side.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_change(handle: u64, change_id: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_change", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        // SAFETY: change_id is a caller-owned NUL-terminated C string (Dart allocates + frees).
        let id = unsafe { cstr_to_string(change_id) }?; // null → ffi.null_pointer; bad utf8 → ffi.utf8_error
        let change = session.repo.get_change(&ChangeId(id)).map_err(map_change_err)?;
        Ok(change_to_envelope(&change))
    });
    vec_into_token(buf)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use flatbuffers::root as fb_root;
    use zanshin_jj::{Change, ChangeError, ChangeId, CommitId, ConflictState, Signature, Timestamp, Timestamps};

    use crate::fbs;

    use super::{change_to_envelope, map_change_err};

    fn make_change(conflict: ConflictState, divergent: bool, is_signed: bool, is_anonymous: bool) -> Change {
        Change {
            id: ChangeId("qpvuntsm".to_owned()),
            commit_id: CommitId("aabbccdd1122".to_owned()),
            parents: vec![ChangeId("parent111".to_owned()), ChangeId("parent222".to_owned())],
            description: "my feature".to_owned(),
            author: Signature {
                name: "Alice".to_owned(),
                email: "alice@example.com".to_owned(),
                timestamp: Timestamp {
                    millis_since_epoch: 1_700_000_000_000,
                    tz_offset_minutes: 60,
                },
            },
            committer: Signature {
                name: "Bob".to_owned(),
                email: "bob@example.com".to_owned(),
                timestamp: Timestamp {
                    millis_since_epoch: 1_700_001_000_000,
                    tz_offset_minutes: 0,
                },
            },
            timestamps: Timestamps {
                authored_at: Timestamp {
                    millis_since_epoch: 1_700_000_000_000,
                    tz_offset_minutes: 60,
                },
                committed_at: Timestamp {
                    millis_since_epoch: 1_700_001_000_000,
                    tz_offset_minutes: 0,
                },
            },
            is_signed,
            conflict,
            is_anonymous,
            divergent,
        }
    }

    /// Builder unit test — fully-populated `Change` with `Conflicted` state.
    /// Exercises every field, ≥2 parents, distinct author/committer, and the
    /// nested `conflicted_paths` vector.
    #[test]
    fn change_to_envelope_conflicted_roundtrips_all_fields() {
        let conflict_path = PathBuf::from("src/lib.rs");
        let change = make_change(
            ConflictState::Conflicted {
                paths: vec![conflict_path.clone()],
            },
            true,  // divergent
            true,  // is_signed
            false, // is_anonymous
        );

        let buf = change_to_envelope(&change);
        let env = fb_root::<fbs::Envelope>(&buf).expect("FlatBuffers Verifier must pass");

        assert!(env.ok(), "envelope ok must be true");
        assert_eq!(env.data_type(), fbs::Payload::Change, "data_type must be Change");

        let payload = env
            .data_as_change()
            .expect("data_as_change must succeed for Payload::Change");

        assert_eq!(payload.id(), Some("qpvuntsm"), "id round-trips");
        assert_eq!(payload.commit_id(), Some("aabbccdd1122"), "commit_id round-trips");
        assert_eq!(payload.description(), Some("my feature"), "description round-trips");
        assert!(payload.is_signed(), "is_signed round-trips");
        assert!(payload.divergent(), "divergent round-trips");
        assert!(!payload.is_anonymous(), "is_anonymous round-trips");

        let parents = payload.parents().expect("parents must be present");
        assert_eq!(parents.len(), 2);
        assert_eq!(parents.get(0), "parent111");
        assert_eq!(parents.get(1), "parent222");

        let author = payload.author().expect("author must be present");
        assert_eq!(author.name(), Some("Alice"));
        assert_eq!(author.email(), Some("alice@example.com"));
        assert_eq!(author.timestamp_millis(), 1_700_000_000_000);
        assert_eq!(author.tz_offset_minutes(), 60);

        let committer = payload.committer().expect("committer must be present");
        assert_eq!(committer.name(), Some("Bob"));
        assert_eq!(committer.email(), Some("bob@example.com"));
        assert_eq!(committer.timestamp_millis(), 1_700_001_000_000);
        assert_eq!(committer.tz_offset_minutes(), 0);

        assert_eq!(
            payload.conflict(),
            fbs::ConflictState::Conflicted,
            "conflict state round-trips"
        );
        let conflict_paths = payload.conflicted_paths().expect("conflicted_paths must be present");
        assert_eq!(conflict_paths.len(), 1);
        assert_eq!(conflict_paths.get(0), "src/lib.rs");
    }

    /// Builder unit test — clean `Change` (no conflict, divergent == false).
    #[test]
    fn change_to_envelope_clean_has_no_conflicted_paths() {
        let change = make_change(
            ConflictState::Clean,
            false, // divergent
            false, // is_signed
            true,  // is_anonymous
        );

        let buf = change_to_envelope(&change);
        let env = fb_root::<fbs::Envelope>(&buf).expect("FlatBuffers Verifier must pass");
        assert!(env.ok());

        let payload = env.data_as_change().unwrap();
        assert_eq!(
            payload.conflict(),
            fbs::ConflictState::Clean,
            "clean conflict state round-trips"
        );
        assert!(
            payload.conflicted_paths().is_none(),
            "clean Change must have no conflicted_paths"
        );
        assert!(!payload.divergent(), "divergent round-trips false");
        assert!(payload.is_anonymous(), "is_anonymous round-trips true");
    }

    /// `map_change_err` unit test — covers both `ChangeError` variants.
    /// The `jj.change_not_found` code is otherwise untested (no other test can
    /// trigger a real backend not-found through the FFI without a full fixture).
    #[test]
    fn map_change_err_maps_both_variants() {
        let not_found = map_change_err(ChangeError::NotFound {
            id: "abc123".to_owned(),
        });
        assert_eq!(not_found.code, crate::envelope::JJ_CHANGE_NOT_FOUND);
        assert_eq!(
            not_found.context.as_deref(),
            Some("abc123"),
            "NotFound forwards the id as context"
        );

        let backend = map_change_err(ChangeError::Backend("boom".to_owned()));
        assert_eq!(backend.code, crate::envelope::JJ_JJ_LIB_ERROR);
        assert_eq!(
            backend.context.as_deref(),
            Some("boom"),
            "Backend forwards the reason as context"
        );
    }
}
