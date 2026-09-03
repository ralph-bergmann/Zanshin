// SPDX-License-Identifier: MIT

//! `zanshin_show` / `zanshin_evolog` / `zanshin_interdiff` — the three commit READ views
//! (Story 9.6).
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the result into a
//! `FlatBuffers` `Envelope`. The handle is borrowed (not consumed), and none of the three
//! writes an operation — not even on a refusal.
//!
//! All three take a request BUFFER rather than C strings, the ADR-0001 composite-input case
//! Story 9.3 established: `show`'s `revset` and `interdiff`'s two revisions must be
//! distinguishably ABSENT (that absence is what applies the CLI's own `@` default), and
//! `evolog` additionally carries an optional scalar limit.
//!
//! The two nested shapes — a `Change` and a `[FileChange]` — are built through the shipped
//! construction sites (`change.rs::change_offset`, `status.rs::file_changes_vector`), never a
//! second spelling: a future field added to either must reach every payload that carries it.

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ChangeId, CommitViewError, EvologEntry, FileChange, ShowEntry};

use crate::change::change_offset;
use crate::envelope::{
    catch, finish_envelope, invalid_request, reject_null_request, FfiErrorObj, FFI_INVALID_HANDLE, JJ_CHANGE_NOT_FOUND,
    JJ_CONFIG_ERROR, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;
use crate::repo::RepoSession;
use crate::status::file_changes_vector;

/// Maps a [`CommitViewError`] onto its AR-P-4 code; user data always rides in `context`.
///
/// Every variant lands on an ALREADY-REGISTERED code — Story 9.6 mints none.
fn map_commit_view_err(e: CommitViewError) -> FfiErrorObj {
    let (code, context) = match e {
        CommitViewError::ChangeNotFound { id } => (JJ_CHANGE_NOT_FOUND, id),
        CommitViewError::InvalidInput { reason } => (JJ_INVALID_INPUT, reason),
        CommitViewError::RevsetParseError { reason } => (JJ_REVSET_PARSE_ERROR, reason),
        CommitViewError::RevsetResolutionError { reason } => (JJ_REVSET_RESOLUTION_ERROR, reason),
        CommitViewError::Config { reason } => (JJ_CONFIG_ERROR, reason),
        CommitViewError::Backend(reason) => (JJ_JJ_LIB_ERROR, reason),
    };
    FfiErrorObj {
        code: code.to_owned(),
        context: Some(context),
    }
}

// ── Request-buffer readers ───────────────────────────────────────────────────
//
// Same discipline as `repo.rs`'s, `file.rs`'s and `git.rs`'s readers: `data`/`len` describe a
// caller-owned buffer Dart builds and frees itself; Rust borrows it for the call only. Each
// reader builds its OWN byte slice in its own scope and returns an OWNED struct, so the
// unbounded lifetime `std::slice::from_raw_parts` produces provably cannot outlive the call.

/// Owned Rust form of a `ShowRequest` buffer. `revset` is `Option<String>` — an ABSENT field is
/// the wire form of "the user did not supply it", which applies the CLI's `@` default; an
/// explicitly EMPTY string is a value and reaches the revset parser (where it fails).
struct ShowRequestOwned {
    revset: Option<String>,
}

/// Owned Rust form of an `EvologRequest` buffer. `limit` is `Option<usize>`, reconstructed from
/// the presence-flag pair the schema carries.
struct EvologRequestOwned {
    revset: Option<String>,
    limit: Option<usize>,
}

/// Owned Rust form of an `InterdiffRequest` buffer. Both revisions are `Option`: an absent side
/// is `@`, and BOTH absent is refused by `zanshin-jj` (the CLI's `ArgGroup`).
struct InterdiffRequestOwned {
    from: Option<ChangeId>,
    to: Option<ChangeId>,
    paths: Vec<String>,
}

/// Parse a `ShowRequest` buffer into an owned [`ShowRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ShowRequest` buffer.
fn read_show_request(data: *const u8, len: usize) -> Result<ShowRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ShowRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    Ok(ShowRequestOwned {
        revset: req.revset().map(ToOwned::to_owned),
    })
}

/// Parse an `EvologRequest` buffer into an owned [`EvologRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `EvologRequest` buffer.
fn read_evolog_request(data: *const u8, len: usize) -> Result<EvologRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::EvologRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    Ok(EvologRequestOwned {
        revset: req.revset().map(ToOwned::to_owned),
        // Presence pair, not a sentinel: `limit = 0` is a MEANINGFUL value (an empty result),
        // so absence cannot be encoded as zero.
        limit: req.has_limit().then(|| req.limit() as usize),
    })
}

/// Parse an `InterdiffRequest` buffer into an owned [`InterdiffRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `InterdiffRequest` buffer.
fn read_interdiff_request(data: *const u8, len: usize) -> Result<InterdiffRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::InterdiffRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    Ok(InterdiffRequestOwned {
        from: req.from().map(|s| ChangeId(s.to_owned())),
        to: req.to().map(|s| ChangeId(s.to_owned())),
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
    })
}

// ── Payload builders ─────────────────────────────────────────────────────────

/// Serialise `&[ShowEntry]` into a finished `Envelope<ShowView>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): each entry's nested `Change` and its
/// `[FileChange]` vector are complete before the `ShowEntry` table opens, and the outer vector
/// and `ShowView` table come after the loop.
fn show_view_to_envelope(entries: &[ShowEntry]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(2048);
    let offsets: Vec<_> = entries
        .iter()
        .map(|e| {
            let change = change_offset(&mut b, &e.change);
            let file_changes = file_changes_vector(&mut b, &e.file_changes);
            fbs::ShowEntry::create(
                &mut b,
                &fbs::ShowEntryArgs {
                    change: Some(change),
                    file_changes: Some(file_changes),
                },
            )
        })
        .collect();
    let vec = b.create_vector(&offsets);
    let table = fbs::ShowView::create(&mut b, &fbs::ShowViewArgs { entries: Some(vec) });
    finish_envelope(b, fbs::Payload::ShowView, table.as_union_value())
}

/// Serialise `&[EvologEntry]` into a finished `Envelope<EvologView>` buffer.
///
/// `operation_id` is written only when present: null-for-absence is the wire form of "the walk
/// emitted this entry from its flush tail", i.e. the evolution may be truncated.
fn evolog_view_to_envelope(entries: &[EvologEntry]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(2048);
    let offsets: Vec<_> = entries
        .iter()
        .map(|e| {
            let change = change_offset(&mut b, &e.change);
            let pred_offs: Vec<_> = e.predecessor_commit_ids.iter().map(|c| b.create_string(&c.0)).collect();
            let preds = b.create_vector(&pred_offs);
            let op = e.operation_id.as_ref().map(|o| b.create_string(&o.0));
            fbs::EvologEntry::create(
                &mut b,
                &fbs::EvologEntryArgs {
                    change: Some(change),
                    predecessor_commit_ids: Some(preds),
                    operation_id: op,
                },
            )
        })
        .collect();
    let vec = b.create_vector(&offsets);
    let table = fbs::EvologView::create(&mut b, &fbs::EvologViewArgs { entries: Some(vec) });
    finish_envelope(b, fbs::Payload::EvologView, table.as_union_value())
}

/// Serialise `&[FileChange]` into a finished `Envelope<InterdiffView>` buffer.
fn interdiff_view_to_envelope(file_changes: &[FileChange]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let vec = file_changes_vector(&mut b, file_changes);
    let table = fbs::InterdiffView::create(
        &mut b,
        &fbs::InterdiffViewArgs {
            file_changes: Some(vec),
        },
    );
    finish_envelope(b, fbs::Payload::InterdiffView, table.as_union_value())
}

/// Borrow the [`RepoSession`] behind a raw handle, or produce `ffi.invalid_handle`.
///
/// # Safety
/// `handle` must be `0` or a live value returned by a successful handle-producing wrapper.
unsafe fn session_from_handle<'a>(handle: u64) -> Result<&'a mut RepoSession, FfiErrorObj> {
    // SAFETY: non-zero handle originated from arm_session's handle_into_raw
    // (Box<RepoSession>) in zanshin_repo_open/init/clone/convert; single-isolate model
    // (AD-2) guarantees no concurrent access.
    unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(|| FfiErrorObj {
        code: FFI_INVALID_HANDLE.to_owned(),
        context: None,
    })
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// Show each revision the request's revset denotes, with what it changed, in the repo
/// identified by `handle` — the CLI's `jj show`.
///
/// The argument crosses as a `ShowRequest` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern). An ABSENT `revset` is the wire form of "the user did not supply
/// it", which applies the CLI's own default `@` — here the LAST-SNAPSHOTTED working-copy commit,
/// because Zanshin never snapshots (D2). `revset` is an EXPRESSION, not a change id: the CLI
/// unions its revsets, so entries are per COMMIT — a revset naming two commits of ONE divergent
/// change yields two entries carrying the same `Change.id`. A BARE divergent change-id symbol
/// does NOT get that far: jj-lib's own `SymbolResolver` refuses it
/// (`RevsetResolutionError::DivergentChangeId`, `revset.rs:2827` @ 0.44.0), exactly as
/// `jj show <divergent-id>` fails in the CLI, and it surfaces here as
/// `jj.revset_resolution_error` — a different refusal from `zanshin_interdiff`'s
/// `jj.change_not_found`. Union the two COMMIT hexes to address both.
/// Each entry's `file_changes` is the diff against the commit's MERGED parent tree; there is no
/// path filter and no textual patch (Epic 5 owns hunks). This read writes NO operation.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `ShowView` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ShowRequest` buffer.
/// - `jj.revset_parse_error` — `revset` is syntactically invalid or names an unknown function;
///   jj-lib's reason in `context`.
/// - `jj.revset_resolution_error` — a symbol in `revset` cannot be resolved; reason in
///   `context`.
/// - `jj.config_error` — the repo's effective jj config, which the revset aliases come from, is
///   unreadable or malformed.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.ShowRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_show(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_show", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let req = read_show_request(data, len)?;
        let entries = session.repo.show(req.revset.as_deref()).map_err(map_commit_view_err)?;
        Ok(show_view_to_envelope(&entries))
    });
    vec_into_token(buf)
}

/// Walk the evolution of the changes the request's revset denotes, in the repo identified by
/// `handle` — the CLI's `jj evolog`.
///
/// The arguments cross as an `EvologRequest` `FlatBuffers` request buffer. `revset` behaves as
/// for `zanshin_show`. `limit` uses the established presence-flag pair (`has_limit`) because
/// `limit = 0` is a MEANINGFUL value — an empty result, not an error — so absence cannot be
/// encoded as zero. It is applied in WALK order: the CLI limits before reversing, and both the
/// reversal and its graph mode's re-ordering are rendering the GUI does itself. This read writes
/// NO operation.
///
/// Returns a `FlatBuffers` `Envelope` carrying an `EvologView` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `EvologRequest` buffer.
/// - `jj.revset_parse_error` — `revset` is syntactically invalid; reason in `context`.
/// - `jj.revset_resolution_error` — a symbol in `revset` cannot be resolved.
/// - `jj.config_error` — the repo's effective jj config is unreadable or malformed.
/// - `jj.jj_lib_error` — an underlying jj-lib failure, including jj-lib's own
///   predecessor-cycle detection; detail in `context`.
///
/// # Safety
/// Same handle and buffer contract as `zanshin_show`; `data` is a
/// `fbs.EvologRequestObjectBuilder(...).toBytes()` buffer.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_evolog(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_evolog", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let req = read_evolog_request(data, len)?;
        let entries = session
            .repo
            .evolog(req.revset.as_deref(), req.limit)
            .map_err(map_commit_view_err)?;
        Ok(evolog_view_to_envelope(&entries))
    });
    vec_into_token(buf)
}

/// Compare what two revisions each CHANGE, with the parent difference factored out, in the repo
/// identified by `handle` — the CLI's `jj interdiff`.
///
/// The arguments cross as an `InterdiffRequest` `FlatBuffers` request buffer. Unlike
/// `zanshin_show`, both sides are single jj reverse-hex CHANGE IDS. They inherit the CLI
/// `resolve_single_rev`'s REFUSAL — a divergent id is rejected rather than guessed — but NOT
/// its address space: each side resolves to the one VISIBLE commit carrying that change-id
/// prefix, so a commit hex, a revset expression and a HIDDEN commit are all unaddressable
/// here, where the CLI accepts all three. In particular the predecessors `zanshin_evolog`
/// reports are hidden, so the two cannot be composed into a version-to-version diff. An
/// absent side is `@`; omitting BOTH is refused with `jj.invalid_input`, mirroring the CLI's
/// `ArgGroup … required(true)`. `paths` entries are repo-relative PREFIXES; an empty list means
/// all paths, and a filter matching nothing yields an empty list rather than a refusal.
///
/// No `Renamed`/`Copied` entry is ever produced — the CLI's `show_inter_diff` passes no copy
/// records, and that asymmetry with `zanshin_show` is reproduced deliberately. The rebase behind
/// it is in-memory only, so this read writes NO operation.
///
/// Returns a `FlatBuffers` `Envelope` carrying an `InterdiffView` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `InterdiffRequest` buffer.
/// - `jj.invalid_input` — both `from` and `to` are absent from the buffer, or a `paths` entry is
///   not a valid repo path; detail in `context`.
/// - `jj.change_not_found` — `from` or `to` is malformed, absent, only-hidden, or divergent; the
///   offending id in `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle and buffer contract as `zanshin_show`; `data` is a
/// `fbs.InterdiffRequestObjectBuilder(...).toBytes()` buffer.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_interdiff(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_interdiff", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let req = read_interdiff_request(data, len)?;
        let changes = session
            .repo
            .interdiff(req.from, req.to, &req.paths)
            .map_err(map_commit_view_err)?;
        Ok(interdiff_view_to_envelope(&changes))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use std::path::PathBuf;
    use zanshin_jj::{
        Change, ChangeId, ChangeKind, CommitId, CommitViewError, ConflictState, EvologEntry, FileChange, OperationId,
        ShowEntry, Signature, Timestamp, Timestamps,
    };

    use super::{evolog_view_to_envelope, interdiff_view_to_envelope, map_commit_view_err, show_view_to_envelope};
    use crate::fbs;
    use crate::{
        JJ_CHANGE_NOT_FOUND, JJ_CONFIG_ERROR, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR,
        JJ_REVSET_RESOLUTION_ERROR,
    };

    fn verified(bytes: &[u8]) -> fbs::Envelope<'_> {
        fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass")
    }

    fn sig(name: &str) -> Signature {
        Signature {
            name: name.to_owned(),
            email: format!("{name}@localhost"),
            timestamp: Timestamp {
                millis_since_epoch: 42,
                tz_offset_minutes: 60,
            },
        }
    }

    fn sample_change(id: &str, commit: &str) -> Change {
        let author = sig("zanshin");
        let committer = sig("zanshin");
        Change {
            id: ChangeId(id.to_owned()),
            commit_id: CommitId(commit.to_owned()),
            parents: vec![ChangeId("parent".to_owned())],
            description: "a description".to_owned(),
            timestamps: Timestamps {
                authored_at: author.timestamp,
                committed_at: committer.timestamp,
            },
            author,
            committer,
            is_signed: false,
            conflict: ConflictState::Clean,
            is_anonymous: false,
            divergent: false,
        }
    }

    #[test]
    fn map_commit_view_err_covers_every_variant() {
        let cases = [
            (
                map_commit_view_err(CommitViewError::ChangeNotFound { id: "zzz".to_owned() }),
                JJ_CHANGE_NOT_FOUND,
                "zzz",
            ),
            (
                map_commit_view_err(CommitViewError::InvalidInput {
                    reason: "at least one of `from` or `to` is required".to_owned(),
                }),
                JJ_INVALID_INPUT,
                "at least one of `from` or `to` is required",
            ),
            (
                map_commit_view_err(CommitViewError::RevsetParseError {
                    reason: "syntax error".to_owned(),
                }),
                JJ_REVSET_PARSE_ERROR,
                "syntax error",
            ),
            (
                map_commit_view_err(CommitViewError::RevsetResolutionError {
                    reason: "no such bookmark".to_owned(),
                }),
                JJ_REVSET_RESOLUTION_ERROR,
                "no such bookmark",
            ),
            (
                map_commit_view_err(CommitViewError::Config {
                    reason: "not a table".to_owned(),
                }),
                JJ_CONFIG_ERROR,
                "not a table",
            ),
            (
                map_commit_view_err(CommitViewError::Backend("boom".to_owned())),
                JJ_JJ_LIB_ERROR,
                "boom",
            ),
        ];
        for (obj, code, context) in cases {
            assert_eq!(obj.code, code, "code for {context}");
            assert_eq!(obj.context.as_deref(), Some(context), "context is never in the code");
        }
    }

    #[test]
    fn show_view_nests_the_shipped_change_and_file_change_tables() {
        let entries = vec![ShowEntry {
            change: sample_change("qpvuntsm", "abc123"),
            file_changes: vec![
                FileChange {
                    path: PathBuf::from("a.txt"),
                    kind: ChangeKind::Added,
                },
                FileChange {
                    path: PathBuf::from("new.txt"),
                    kind: ChangeKind::Renamed {
                        from: PathBuf::from("old.txt"),
                    },
                },
            ],
        }];

        let buf = show_view_to_envelope(&entries);
        let env = verified(&buf);
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::ShowView);
        let view = env.data_as_show_view().expect("ShowView payload");
        let fbs_entries = view.entries().expect("entries present");
        assert_eq!(fbs_entries.len(), 1);

        let change = fbs_entries.get(0).change().expect("the nested Change is present");
        assert_eq!(change.id(), Some("qpvuntsm"));
        assert_eq!(change.commit_id(), Some("abc123"));
        assert_eq!(change.description(), Some("a description"));
        assert_eq!(change.author().and_then(|a| a.name()), Some("zanshin"));

        let files = fbs_entries.get(0).file_changes().expect("file_changes present");
        assert_eq!(files.len(), 2);
        assert_eq!(files.get(0).path(), Some("a.txt"));
        assert_eq!(files.get(0).kind(), fbs::ChangeKind::Added);
        assert!(
            files.get(0).from_path().is_none(),
            "from_path is null-for-absence outside Renamed/Copied"
        );
        assert_eq!(files.get(1).kind(), fbs::ChangeKind::Renamed);
        assert_eq!(files.get(1).from_path(), Some("old.txt"));
    }

    #[test]
    fn evolog_view_omits_an_absent_operation_id() {
        let entries = vec![
            EvologEntry {
                change: sample_change("qpvuntsm", "cur"),
                predecessor_commit_ids: vec![CommitId("prev".to_owned())],
                operation_id: Some(OperationId("op1".to_owned())),
            },
            EvologEntry {
                change: sample_change("qpvuntsm", "prev"),
                predecessor_commit_ids: Vec::new(),
                operation_id: None,
            },
        ];

        let buf = evolog_view_to_envelope(&entries);
        let env = verified(&buf);
        assert_eq!(env.data_type(), fbs::Payload::EvologView);
        let view = env.data_as_evolog_view().expect("EvologView payload");
        let fbs_entries = view.entries().expect("entries present");
        assert_eq!(fbs_entries.len(), 2);
        assert_eq!(
            fbs_entries
                .get(0)
                .predecessor_commit_ids()
                .map(|v| v.iter().collect::<Vec<_>>()),
            Some(vec!["prev"])
        );
        assert_eq!(fbs_entries.get(0).operation_id(), Some("op1"));
        assert!(
            fbs_entries.get(1).operation_id().is_none(),
            "the walk's flush tail carries no operation id"
        );
        assert!(fbs_entries
            .get(1)
            .predecessor_commit_ids()
            .is_some_and(|v| v.is_empty()));
    }

    #[test]
    fn interdiff_view_carries_the_change_list() {
        let changes = vec![FileChange {
            path: PathBuf::from("b.txt"),
            kind: ChangeKind::Added,
        }];
        let buf = interdiff_view_to_envelope(&changes);
        let env = verified(&buf);
        assert_eq!(env.data_type(), fbs::Payload::InterdiffView);
        let view = env.data_as_interdiff_view().expect("InterdiffView payload");
        let files = view.file_changes().expect("file_changes present");
        assert_eq!(files.len(), 1);
        assert_eq!(files.get(0).path(), Some("b.txt"));
        assert_eq!(files.get(0).kind(), fbs::ChangeKind::Added);
    }

    #[test]
    fn empty_results_still_produce_ok_envelopes() {
        for (buf, expected) in [
            (show_view_to_envelope(&[]), fbs::Payload::ShowView),
            (evolog_view_to_envelope(&[]), fbs::Payload::EvologView),
            (interdiff_view_to_envelope(&[]), fbs::Payload::InterdiffView),
        ] {
            let env = verified(&buf);
            assert!(env.ok(), "an empty result is a success, not an error");
            assert_eq!(env.data_type(), expected);
        }
    }
}
