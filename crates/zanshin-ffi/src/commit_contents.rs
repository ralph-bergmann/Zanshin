// SPDX-License-Identifier: MIT

//! `zanshin_commit_contents` — the op-pinned batch content lookup (Story 4.10).
//!
//! Calls `zanshin_jj::Repo::commit_contents` and serialises the object half of each requested
//! commit into a `FlatBuffers` `Envelope<CommitContents>`. The read is the CONTINUATION of the
//! topology call's `jj log`, pinned to the operation that call returned: it runs no pre-verb
//! snapshot and records no warning, so its envelope carries NO `precondition` and NO `warnings`
//! — on the ok arm and on every error arm alike. It writes no operation and no op head.
//!
//! The arguments cross as a `CommitContentsRequest` request buffer (ADR-0001 composite-input
//! pattern: a list of ids is composite). Same reader discipline as `workspace.rs`: `data`/`len`
//! describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for the call only
//! and the reader returns an OWNED struct. Interior-NUL guards live Dart-side
//! (`docs/ffi-abi.md` § Interior NUL); a NUL that reaches Rust is simply not hex.

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{CommitContent, CommitContentError, CommitId, OperationId};

use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, missing_field, reject_null_request,
    session_from_handle, CallReport, FfiErrorObj, JJ_CHANGE_NOT_FOUND, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR,
    JJ_OPERATION_NOT_FOUND,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};

/// Maps a [`CommitContentError`] onto its AR-P-4 code; ids always ride in `context`.
///
/// An id the pinned index does not carry reuses `jj.change_not_found` — the Epic 9 follow-up I
/// precedent for a commit id "which no INDEXED commit carries" — with the caller's hex as the
/// context; a vanished operation is the one new code, `jj.operation_not_found`, whose context is
/// the CLI's `No operation ID matching "<id>"`.
fn map_commit_content_err(e: CommitContentError) -> FfiErrorObj {
    let (code, context) = match e {
        CommitContentError::InvalidInput(reason) => (JJ_INVALID_INPUT, reason),
        e @ CommitContentError::OperationNotFound(_) => (JJ_OPERATION_NOT_FOUND, e.to_string()),
        CommitContentError::CommitNotFound(hex) => (JJ_CHANGE_NOT_FOUND, hex),
        CommitContentError::Backend(reason) => (JJ_JJ_LIB_ERROR, reason),
    };
    FfiErrorObj {
        report: None,
        hints: Vec::new(),
        code: code.to_owned(),
        context: Some(context),
    }
}

// ── Request-buffer reader ────────────────────────────────────────────────────

/// Owned Rust form of a `CommitContentsRequest` buffer. An absent `commit_ids` vector is an
/// empty request, which answers with an empty list.
struct CommitContentsRequestOwned {
    operation_id: OperationId,
    commit_ids: Vec<CommitId>,
}

/// Parse a `CommitContentsRequest` buffer into an owned [`CommitContentsRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `CommitContentsRequest` buffer, or its
///   `kind` is not `CommitContents`.
/// - `jj.invalid_input` — `operation_id` is absent (`operation_id is required`).
fn read_commit_contents_request(data: *const u8, len: usize) -> Result<CommitContentsRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::CommitContentsRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::CommitContents)?;
    let operation_id = req.operation_id().ok_or_else(|| missing_field("operation_id"))?;
    Ok(CommitContentsRequestOwned {
        operation_id: OperationId(operation_id.to_owned()),
        commit_ids: req
            .commit_ids()
            .into_iter()
            .flatten()
            .map(|id| CommitId(id.to_owned()))
            .collect(),
    })
}

// ── Payload builder ──────────────────────────────────────────────────────────

/// Serialise `&[CommitContent]` into a finished `Envelope<CommitContents>` buffer, in the given
/// (request) order. The envelope carries no `precondition` and no `warnings`: the verb runs
/// neither.
fn commit_contents_to_envelope(contents: &[CommitContent]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256 + contents.len() * 256);
    let offsets: Vec<_> = contents
        .iter()
        .map(|c| {
            let commit_id = b.create_string(&c.commit_id.0);
            let author_name = b.create_string(&c.author_name);
            let author_email = b.create_string(&c.author_email);
            let description = b.create_string(&c.description);
            fbs::CommitContent::create(
                &mut b,
                &fbs::CommitContentArgs {
                    commit_id: Some(commit_id),
                    author_name: Some(author_name),
                    author_email: Some(author_email),
                    committer_timestamp_millis: c.committer_timestamp.millis_since_epoch,
                    committer_tz_offset_minutes: c.committer_timestamp.tz_offset_minutes,
                    description: Some(description),
                    conflict: c.conflict,
                    empty: c.empty,
                },
            )
        })
        .collect();
    let vec = b.create_vector(&offsets);
    let table = fbs::CommitContents::create(&mut b, &fbs::CommitContentsArgs { contents: Some(vec) });
    finish_envelope(
        b,
        fbs::Payload::CommitContents,
        Some(table.as_union_value()),
        &CallReport::default(),
    )
}

// ── extern "C" wrapper ───────────────────────────────────────────────────────

/// Return the object half of each requested commit — author, committer timestamp, FULL
/// description, conflict, empty — read at the PINNED operation `operation_id`, in request order
/// (Story 4.10).
///
/// The continuation of the topology call's `jj log` (the CLI's per-row commit load), pinned to
/// the operation that call returned: `load_operation` + `load_at`, never `load_at_head`. It runs
/// no pre-verb snapshot, no import, no config load and no fix-up, writes no operation and no op
/// head, and its envelope carries NO `precondition` and NO `warnings` (ok and error alike). The
/// values are commit-intrinsic, so a head that moved since the topology call changes nothing. Ids
/// are FULL hex only — prefixes are not resolved. An empty `commit_ids` list answers with an empty
/// list.
///
/// The arguments cross as a `CommitContentsRequest` `FlatBuffers` request buffer. Returns a
/// `FlatBuffers` `Envelope` carrying a `CommitContents` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `CommitContentsRequest` buffer, or its
///   `kind` is not `CommitContents`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `operation_id` is absent, empty, not hex or not a full id (an empty or
///   non-hex id gets the CLI's "is not a valid hexadecimal prefix" text); or a commit id is empty,
///   not hex or not a full id. Every commit id is checked before any load.
/// - `jj.operation_not_found` — the operation is not in the operation store; `context` is the
///   CLI's `No operation ID matching "<id>"`.
/// - `jj.change_not_found` — a commit id is not in the pinned operation's index; the hex in
///   `context`.
/// - `jj.jj_lib_error` — loading the operation, its repo, or an indexed commit (or, for `empty`,
///   its parent) failed; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.CommitContentsRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call. The request is read BEFORE the handle is borrowed.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_commit_contents(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_commit_contents", handle);
    let buf = catch(|| {
        let req = read_commit_contents_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let contents = session
            .repo
            .commit_contents(&req.operation_id, &req.commit_ids)
            .map_err(map_commit_content_err)?;
        Ok(commit_contents_to_envelope(&contents))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root;
    use zanshin_jj::{CommitContent, CommitContentError, CommitId, Timestamp};

    use super::{commit_contents_to_envelope, map_commit_content_err};
    use crate::envelope::{JJ_CHANGE_NOT_FOUND, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_OPERATION_NOT_FOUND};
    use crate::fbs;

    fn content(id: &str, description: &str) -> CommitContent {
        CommitContent {
            commit_id: CommitId(id.to_owned()),
            author_name: "Ada".to_owned(),
            author_email: String::new(),
            committer_timestamp: Timestamp {
                millis_since_epoch: 1_700_000_000_123,
                tz_offset_minutes: -120,
            },
            description: description.to_owned(),
            conflict: true,
            empty: false,
        }
    }

    #[test]
    fn commit_contents_roundtrip_every_field_in_order_without_precondition_or_warnings() {
        let buf = commit_contents_to_envelope(&[content("bb", "Subject\n\nBody\n"), content("aa", "")]);
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert!(env.precondition().is_none(), "the verb runs no precondition");
        assert!(env.warnings().is_none(), "the verb records no warning");
        assert_eq!(env.data_type(), fbs::Payload::CommitContents);
        let items = env
            .data_as_commit_contents()
            .expect("expected CommitContents payload")
            .contents()
            .expect("contents vector");
        assert_eq!(items.len(), 2);
        let first = items.get(0);
        assert_eq!(first.commit_id(), Some("bb"));
        assert_eq!(first.author_name(), Some("Ada"));
        assert_eq!(
            first.author_email(),
            Some(""),
            "an empty author email is present, not absent"
        );
        assert_eq!(first.committer_timestamp_millis(), 1_700_000_000_123);
        assert_eq!(first.committer_tz_offset_minutes(), -120);
        assert_eq!(first.description(), Some("Subject\n\nBody\n"), "the FULL description");
        assert!(first.conflict());
        assert!(!first.empty());
        assert_eq!(items.get(1).commit_id(), Some("aa"));
        assert_eq!(items.get(1).description(), Some(""));
    }

    #[test]
    fn commit_contents_empty_list_roundtrips() {
        let buf = commit_contents_to_envelope(&[]);
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        let payload = env.data_as_commit_contents().expect("expected CommitContents payload");
        assert_eq!(payload.contents().map_or(0, |c| c.len()), 0);
    }

    #[test]
    fn every_commit_content_error_variant_maps_to_its_own_code_with_the_id_in_context() {
        let invalid = map_commit_content_err(CommitContentError::InvalidInput("bad".to_owned()));
        assert_eq!(invalid.code, JJ_INVALID_INPUT);
        assert_eq!(invalid.context.as_deref(), Some("bad"));

        let vanished = map_commit_content_err(CommitContentError::OperationNotFound("ab".to_owned()));
        assert_eq!(vanished.code, JJ_OPERATION_NOT_FOUND);
        assert_eq!(vanished.context.as_deref(), Some(r#"No operation ID matching "ab""#));

        let unindexed = map_commit_content_err(CommitContentError::CommitNotFound("cd".to_owned()));
        assert_eq!(unindexed.code, JJ_CHANGE_NOT_FOUND);
        assert_eq!(unindexed.context.as_deref(), Some("cd"));

        let backend = map_commit_content_err(CommitContentError::Backend("boom".to_owned()));
        assert_eq!(backend.code, JJ_JJ_LIB_ERROR);
        assert_eq!(backend.context.as_deref(), Some("boom"));

        for e in [invalid, vanished, unindexed, backend] {
            assert!(e.report.is_none(), "no precondition, no warnings on any error arm");
        }
    }
}
