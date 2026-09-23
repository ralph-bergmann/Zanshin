// SPDX-License-Identifier: MIT

//! `zanshin_show` / `zanshin_evolog` / `zanshin_interdiff` — the three commit READ views
//! (Story 9.6).
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the result into a
//! `FlatBuffers` `Envelope`. The handle is borrowed (not consumed), and none of the three
//! verbs itself writes an operation — not even on a refusal; only the pre-verb snapshot
//! (Story 9.26) in front of each may.
//!
//! All three take a request BUFFER rather than C strings, the ADR-0001 composite-input case
//! Story 9.3 established: `show`'s `revset` and `interdiff`'s two revisions must be
//! distinguishably ABSENT (that absence is what applies the CLI's own `@` default), and
//! `show` and `evolog` additionally carry an optional scalar limit.
//!
//! The two nested shapes — a `Change` and a `[FileChange]` — are built through the shipped
//! construction sites (`change.rs::change_offset`, `status.rs::file_changes_vector`), never a
//! second spelling: a future field added to either must reach every payload that carries it.

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ChangeId, CommitId, CommitViewError, EvologEntry, InterdiffView, RevisionRef, ShowEntry};

use crate::change::change_offset;
use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, map_precondition_err, missing_field,
    precondition_envelope, reject_null_request, session_from_handle, FfiErrorObj, FFI_INVALID_ARGUMENT,
    JJ_CHANGE_NOT_FOUND, JJ_CONFIG_ERROR, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR,
    JJ_REVSET_RESOLUTION_ERROR,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::status::file_changes_vector;

/// Maps a [`CommitViewError`] onto its AR-P-4 code; user data always rides in `context`.
///
/// Every variant lands on an ALREADY-REGISTERED code — Story 9.6 mints none.
fn map_commit_view_err(e: CommitViewError) -> FfiErrorObj {
    let (code, context) = match e {
        CommitViewError::Precondition(e) => return map_precondition_err(e),
        CommitViewError::ChangeNotFound { id } => (JJ_CHANGE_NOT_FOUND, id),
        CommitViewError::InvalidInput { reason } => (JJ_INVALID_INPUT, reason),
        CommitViewError::RevsetParseError { reason } => (JJ_REVSET_PARSE_ERROR, reason),
        CommitViewError::RevsetResolutionError { reason } => (JJ_REVSET_RESOLUTION_ERROR, reason),
        CommitViewError::Config { reason } => (JJ_CONFIG_ERROR, reason),
        CommitViewError::Backend(reason) => (JJ_JJ_LIB_ERROR, reason),
    };
    FfiErrorObj {
        precondition: None,
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
/// explicitly EMPTY string is a value and reaches the revset parser (where it fails). `limit` is
/// `Option<usize>`, reconstructed from the presence-flag pair the schema carries.
struct ShowRequestOwned {
    revset: Option<String>,
    limit: Option<usize>,
}

/// Owned Rust form of an `EvologRequest` buffer. `limit` is `Option<usize>`, reconstructed from
/// the presence-flag pair the schema carries.
struct EvologRequestOwned {
    revset: Option<String>,
    limit: Option<usize>,
}

/// Owned Rust form of an `InterdiffRequest` buffer. Both revisions are `Option`: an absent side
/// is `@`, and BOTH absent is refused by `zanshin-jj` (the CLI's `ArgGroup`). Each present side
/// keeps the wire union's arm, because the two arms resolve differently — the change-id one to a
/// VISIBLE commit, the commit-id one through the visibility-blind index.
struct InterdiffRequestOwned {
    from: Option<RevisionRef>,
    to: Option<RevisionRef>,
    paths: Vec<String>,
}

/// Lift ONE `RevisionRef` union field into `zanshin-jj`'s `Option<RevisionRef>`.
///
/// `NONE` is a genuinely ABSENT side (the CLI's `@` default) and never a lost discriminant: a
/// union's two vtable slots are checked TOGETHER by `Verifier::visit_union`
/// (`flatbuffers verifier.rs`), which refuses any (present, absent) pair as an inconsistent
/// union at ladder rung 2 — before this reader runs. An out-of-RANGE tag byte does verify (a
/// union tag is range-checked no more than a plain enum is), so its refusal is this function's
/// own, and it names the tag. An absent inner `id` under a present tag is the reader's
/// required-field guard, ladder rung 4.
///
/// The caller evaluates BOTH `*_as_change_id_ref()` and `*_as_commit_id_ref()` and hands both in.
/// That is sound because each generated accessor first compares the field's own discriminant and
/// returns `None` unless it matches — so at most one of the two is ever `Some`, `tag` is what
/// selects between them here, and the arm not selected is a `None` this function never reads.
fn read_revision_ref(
    tag: fbs::RevisionRef,
    change: Option<&str>,
    commit: Option<&str>,
    field: &str,
) -> Result<Option<RevisionRef>, FfiErrorObj> {
    match tag {
        fbs::RevisionRef::NONE => Ok(None),
        fbs::RevisionRef::ChangeIdRef => Ok(Some(RevisionRef::ChangeId(ChangeId(
            change.ok_or_else(|| missing_field(&format!("{field}.id")))?.to_owned(),
        )))),
        fbs::RevisionRef::CommitIdRef => Ok(Some(RevisionRef::CommitId(CommitId(
            commit.ok_or_else(|| missing_field(&format!("{field}.id")))?.to_owned(),
        )))),
        other => Err(FfiErrorObj {
            precondition: None,
            code: FFI_INVALID_ARGUMENT.to_owned(),
            context: Some(format!("unknown {field} revision ref: {other:?}")),
        }),
    }
}

/// Parse a `ShowRequest` buffer into an owned [`ShowRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ShowRequest` buffer, or its `kind`
///   is not `Show`.
fn read_show_request(data: *const u8, len: usize) -> Result<ShowRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ShowRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Show)?;
    Ok(ShowRequestOwned {
        revset: req.revset().map(ToOwned::to_owned),
        // Presence pair, not a sentinel: `limit = 0` is a MEANINGFUL value (an empty result),
        // so absence cannot be encoded as zero.
        limit: req.has_limit().then(|| req.limit() as usize),
    })
}

/// Parse an `EvologRequest` buffer into an owned [`EvologRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `EvologRequest` buffer, or its `kind`
///   is not `Evolog`.
fn read_evolog_request(data: *const u8, len: usize) -> Result<EvologRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::EvologRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Evolog)?;
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
/// - `ffi.invalid_argument` — `data` does not verify as an `InterdiffRequest` buffer, its
///   `kind` is not `Interdiff`, or a `RevisionRef` discriminant is outside the union.
/// - `jj.invalid_input` — a present `RevisionRef` carries no `id`.
fn read_interdiff_request(data: *const u8, len: usize) -> Result<InterdiffRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::InterdiffRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Interdiff)?;
    Ok(InterdiffRequestOwned {
        from: read_revision_ref(
            req.from_type(),
            req.from_as_change_id_ref().and_then(|r| r.id()),
            req.from_as_commit_id_ref().and_then(|r| r.id()),
            "from",
        )?,
        to: read_revision_ref(
            req.to_type(),
            req.to_as_change_id_ref().and_then(|r| r.id()),
            req.to_as_commit_id_ref().and_then(|r| r.id()),
            "to",
        )?,
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
    })
}

// ── Payload builders ─────────────────────────────────────────────────────────

/// Serialise `&[ShowEntry]` into a finished `Envelope<ShowView>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): each entry's nested `Change` and its
/// `[FileChange]` vector are complete before the `ShowEntry` table opens, and the outer vector
/// and `ShowView` table come after the loop.
fn show_view_to_envelope(entries: &[ShowEntry], precondition: Option<&zanshin_jj::Precondition>) -> Vec<u8> {
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
    finish_envelope(b, fbs::Payload::ShowView, Some(table.as_union_value()), precondition)
}

/// Serialise `&[EvologEntry]` into a finished `Envelope<EvologView>` buffer.
///
/// `operation_id` is written only when present: null-for-absence is the wire form of "the walk
/// emitted this entry from its flush tail", i.e. the evolution may be truncated.
fn evolog_view_to_envelope(entries: &[EvologEntry], precondition: Option<&zanshin_jj::Precondition>) -> Vec<u8> {
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
    finish_envelope(b, fbs::Payload::EvologView, Some(table.as_union_value()), precondition)
}

/// Serialise an [`InterdiffView`] into a finished `Envelope<InterdiffView>` buffer.
///
/// `base_has_conflicts` rides alongside the change list rather than replacing it: a conflicted
/// rebase base is a fact about the comparison, never a refusal.
fn interdiff_view_to_envelope(view: &InterdiffView, precondition: Option<&zanshin_jj::Precondition>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let vec = file_changes_vector(&mut b, &view.file_changes);
    let table = fbs::InterdiffView::create(
        &mut b,
        &fbs::InterdiffViewArgs {
            file_changes: Some(vec),
            base_has_conflicts: view.base_has_conflicts,
        },
    );
    finish_envelope(
        b,
        fbs::Payload::InterdiffView,
        Some(table.as_union_value()),
        precondition,
    )
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// Show each revision the request's revset denotes, with what it changed, in the repo
/// identified by `handle` — the CLI's `jj show`.
///
/// The argument crosses as a `ShowRequest` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern). An ABSENT `revset` is the wire form of "the user did not supply
/// it", which applies the CLI's own default `@` — the working-copy commit the pre-verb snapshot
/// has just brought up to date (Story 9.26). `revset` is an EXPRESSION, not a change id: the CLI
/// unions its revsets, so entries are per COMMIT — a revset naming two commits of ONE divergent
/// change yields two entries carrying the same `Change.id`. A BARE divergent change-id symbol
/// does NOT get that far: jj-lib's own `SymbolResolver` refuses it
/// (`RevsetResolutionError::DivergentChangeId`, `revset.rs:2827` @ 0.44.0), exactly as
/// `jj show <divergent-id>` fails in the CLI, and it surfaces here as
/// `jj.revset_resolution_error` — a different refusal from `zanshin_interdiff`'s
/// `jj.change_not_found`. Union the two COMMIT hexes to address both.
/// Each entry's `file_changes` is the diff against the commit's MERGED parent tree; there is no
/// path filter and no textual patch (Epic 5 owns hunks). This read writes NO operation of its own.
///
/// `limit` is a ZANSHIN-SIDE addition — `jj show` has no `-n/--limit`, because it streams to a
/// pager where this builds ONE buffer whose every entry pays a merged-parent tree diff plus a
/// per-parent copy-record stream. It uses the established presence-flag pair (`has_limit`)
/// because `limit = 0` is a MEANINGFUL value (an empty result, not an error), it is applied in
/// RAW REVSET order BEFORE that per-entry work, and ABSENCE is the CLI-parity default:
/// unbounded, byte-identical to a buffer built before the field existed.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `ShowView` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ShowRequest` buffer, or its `kind`
///   is not `Show`, i.e. the buffer was built for a different wrapper.
/// - `jj.revset_parse_error` — `revset` is syntactically invalid or names an unknown function;
///   jj-lib's reason in `context`.
/// - `jj.revset_resolution_error` — a symbol in `revset` cannot be resolved; reason in
///   `context`.
/// - `jj.config_error` — the repo's effective jj config, which the revset aliases come from, is
///   unreadable or malformed.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
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
        let req = read_show_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let entries = session.repo.show(req.revset.as_deref(), req.limit);
        precondition_envelope(&mut session.repo, entries, map_commit_view_err, |v, p| {
            show_view_to_envelope(v, p)
        })
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
/// - `ffi.invalid_argument` — `data` does not verify as an `EvologRequest` buffer, or its `kind`
///   is not `Evolog`, i.e. the buffer was built for a different wrapper.
/// - `jj.revset_parse_error` — `revset` is syntactically invalid; reason in `context`.
/// - `jj.revset_resolution_error` — a symbol in `revset` cannot be resolved.
/// - `jj.config_error` — the repo's effective jj config is unreadable or malformed.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
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
        let req = read_evolog_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let entries = session.repo.evolog(req.revset.as_deref(), req.limit);
        precondition_envelope(&mut session.repo, entries, map_commit_view_err, |v, p| {
            evolog_view_to_envelope(v, p)
        })
    });
    vec_into_token(buf)
}

/// Compare what two revisions each CHANGE, with the parent difference factored out, in the repo
/// identified by `handle` — the CLI's `jj interdiff`.
///
/// The arguments cross as an `InterdiffRequest` `FlatBuffers` request buffer. Unlike
/// `zanshin_show`, each side is a SINGLE revision, carried by the schema's `RevisionRef` UNION:
/// a `ChangeIdRef` is the house reverse-hex change-id prefix, resolved to the one VISIBLE commit
/// carrying it, and a `CommitIdRef` is a commit-id hex prefix resolved through jj-lib's index,
/// which is visibility-BLIND. Both inherit the CLI `resolve_single_rev`'s REFUSAL — an ambiguous
/// revision is rejected rather than guessed, never resolved to one of the candidates. The
/// commit-id arm is what makes the predecessors `zanshin_evolog` reports — hidden by
/// construction — addressable, so the two verbs compose into a version-to-version diff. A revset
/// expression remains unaddressable on either arm, where the CLI accepts one. An
/// absent side is `@`; omitting BOTH is refused with `jj.invalid_input`, mirroring the CLI's
/// `ArgGroup … required(true)`. `paths` entries are repo-relative PREFIXES; an empty list means
/// all paths, and a filter matching nothing yields an empty list rather than a refusal.
///
/// No `Renamed`/`Copied` entry is ever produced — the CLI's `show_inter_diff` passes no copy
/// records, and that asymmetry with `zanshin_show` is reproduced deliberately. The rebase behind
/// it is in-memory only, so this read writes NO operation of its own.
///
/// The payload's `base_has_conflicts` is a ZANSHIN-SIDE addition reporting whether the REBASED
/// `from` tree — the left side of the diff — is conflicted. The CLI signals this by rendering
/// conflict markers in the patch TEXT, which is Epic 5's surface here, so without the flag a
/// caller sees a plausible change list derived from a conflicted rebase with no way to tell. It
/// never turns the call into a refusal, and it describes the TREE, not the filtered result: a
/// `paths` filter matching nothing still leaves it set.
///
/// Returns a `FlatBuffers` `Envelope` carrying an `InterdiffView` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `InterdiffRequest` buffer (an
///   inconsistent `RevisionRef` union — one of its two vtable slots set — is refused here by the
///   verifier), its `kind` is not `Interdiff`, i.e. the buffer was built for a different wrapper,
///   or a `RevisionRef` discriminant is outside the union; the offending tag in `context`.
/// - `jj.invalid_input` — both `from` and `to` are absent from the buffer, a present
///   `RevisionRef` carries no `id`, a `CommitIdRef` is empty or not valid hex, or a `paths` entry
///   is not a valid repo path; detail in `context`.
/// - `jj.change_not_found` — a `ChangeIdRef` is malformed, carried by no VISIBLE commit (unknown
///   or only-hidden), or divergent; or a `CommitIdRef` is valid hex that no indexed commit
///   carries. The offending id in `context`. An ABSENT side is not an error — ONE absent side
///   applies the CLI's `--from`/`--to` default `@`, and omitting BOTH is the `jj.invalid_input`
///   bullet above.
/// - `jj.revset_resolution_error` — a `CommitIdRef` prefix is carried by two or more commits;
///   jj-lib's own ambiguity wording in `context`.
/// - `jj.config_error` — the pre-verb snapshot (Story 9.26) found the effective jj config
///   unreadable or a knob it reads wrongly typed (the key in `context`); nothing is written.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
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
        let req = read_interdiff_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let view = session.repo.interdiff(req.from, req.to, &req.paths);
        precondition_envelope(&mut session.repo, view, map_commit_view_err, interdiff_view_to_envelope)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use std::path::PathBuf;
    use zanshin_jj::{
        Change, ChangeId, ChangeKind, CommitId, CommitViewError, ConflictState, EvologEntry, FileChange, InterdiffView,
        OperationId, ShowEntry, Signature, Timestamp, Timestamps,
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
            // Story 9.26: a failed pre-verb snapshot takes the shared precondition mapping.
            (
                map_commit_view_err(CommitViewError::Precondition(zanshin_jj::PreconditionError::Config {
                    reason: "snapshot.auto-track".to_owned(),
                })),
                JJ_CONFIG_ERROR,
                "snapshot.auto-track",
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

        let buf = show_view_to_envelope(&entries, None);
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

        let buf = evolog_view_to_envelope(&entries, None);
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

    /// Both `base_has_conflicts` arms, because a writer that hardcoded either one would still
    /// produce a well-formed payload — and the `false` arm is the byte-identical-to-before
    /// default a caller reads when nothing conflicted.
    #[test]
    fn interdiff_view_carries_the_change_list_and_both_conflict_arms() {
        for base_has_conflicts in [false, true] {
            let buf = interdiff_view_to_envelope(
                &InterdiffView {
                    file_changes: vec![FileChange {
                        path: PathBuf::from("b.txt"),
                        kind: ChangeKind::Added,
                    }],
                    base_has_conflicts,
                },
                None,
            );
            let env = verified(&buf);
            assert_eq!(env.data_type(), fbs::Payload::InterdiffView);
            let view = env.data_as_interdiff_view().expect("InterdiffView payload");
            let files = view.file_changes().expect("file_changes present");
            assert_eq!(files.len(), 1);
            assert_eq!(files.get(0).path(), Some("b.txt"));
            assert_eq!(files.get(0).kind(), fbs::ChangeKind::Added);
            assert_eq!(
                view.base_has_conflicts(),
                base_has_conflicts,
                "the flag must survive the round trip in BOTH directions"
            );
        }
    }

    #[test]
    fn empty_results_still_produce_ok_envelopes() {
        for (buf, expected) in [
            (show_view_to_envelope(&[], None), fbs::Payload::ShowView),
            (evolog_view_to_envelope(&[], None), fbs::Payload::EvologView),
            (
                interdiff_view_to_envelope(
                    &InterdiffView {
                        file_changes: Vec::new(),
                        base_has_conflicts: false,
                    },
                    None,
                ),
                fbs::Payload::InterdiffView,
            ),
        ] {
            let env = verified(&buf);
            assert!(env.ok(), "an empty result is a success, not an error");
            assert_eq!(env.data_type(), expected);
        }
    }
}
