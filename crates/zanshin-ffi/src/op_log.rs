// SPDX-License-Identifier: MIT

//! `zanshin_op_log` — operation-log read FFI wrapper (Story 3.4b, `op_log` slice) — and the
//! operation verbs `zanshin_op_show`, `zanshin_op_diff` and `zanshin_op_abandon` (Story 9.21;
//! `zanshin_redo` sits beside `zanshin_undo` in `repo.rs`), `zanshin_op_restore`,
//! `zanshin_op_revert` and `zanshin_op_integrate` (Story 9.12).
//!
//! Calls `zanshin_jj::Repo::op_log(limit)` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying an `OpLog` payload. The handle is borrowed
//! (not consumed). `limit` is a fixed scalar (negative ⇒ all). `op show` / `op diff` / `op restore`
//! / `op revert` take a request BUFFER (their strings must be distinguishably ABSENT, `--what` is a
//! list), `op abandon` / `op integrate` their one lone string.

use std::ffi::c_char;

use flatbuffers::{FlatBufferBuilder, VerifierOptions, WIPOffset};
use tracing::debug;
use zanshin_jj::{
    CommitId, OpAbandonResult, OpDiff, OpDiffOptions, OpDiffResult, OpIntegrateResult, OpLogError, OpRefTarget,
    OpRemoteRefChange, OpShow, Operation, RefDistance, RestoreWhat,
};

use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, map_precondition_err, ok_mutation_result,
    precondition_envelope, reject_null_request, session_from_handle, CallReport, FfiErrorObj, FFI_INVALID_ARGUMENT,
    JJ_JJ_LIB_ERROR,
};
use crate::fbs;
use crate::ffi_strings::{cstr_to_string, vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

fn map_op_log_err(e: OpLogError) -> FfiErrorObj {
    match e {
        OpLogError::Precondition(e) => map_precondition_err(e),
        OpLogError::Backend(reason) => FfiErrorObj {
            report: None,
            hints: Vec::new(),
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

/// Builds one `Operation` table; its strings and vectors first (`FlatBuffers` requirement).
fn operation_to_fbs<'a>(b: &mut FlatBufferBuilder<'a>, op: &Operation) -> WIPOffset<fbs::Operation<'a>> {
    let id_off = b.create_string(&op.id.0);
    let parent_offs: Vec<_> = op.parent_ids.iter().map(|p| b.create_string(&p.0)).collect();
    let parents_vec = b.create_vector(&parent_offs);
    let user_off = b.create_string(&op.user);
    let host_off = b.create_string(&op.host);
    let desc_off = b.create_string(&op.description);
    let workspace_off = op.workspace_name.as_deref().map(|name| b.create_string(name));
    let tag_offs: Vec<_> = op
        .tags
        .iter()
        .map(|tag| {
            let key = b.create_string(&tag.key);
            let value = b.create_string(&tag.value);
            fbs::OperationTag::create(
                b,
                &fbs::OperationTagArgs {
                    key: Some(key),
                    value: Some(value),
                },
            )
        })
        .collect();
    let tags_vec = b.create_vector(&tag_offs);
    fbs::Operation::create(
        b,
        &fbs::OperationArgs {
            id: Some(id_off),
            parent_ids: Some(parents_vec),
            timestamp_millis: op.timestamp.millis_since_epoch,
            tz_offset_minutes: op.timestamp.tz_offset_minutes,
            user: Some(user_off),
            host: Some(host_off),
            description: Some(desc_off),
            root_op: op.root_op,
            is_snapshot: op.is_snapshot,
            workspace_name: workspace_off,
            tags: Some(tags_vec),
        },
    )
}

/// Serialise `&[Operation]` into a finished `Envelope<OpLog>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): for each `Operation`, its
/// strings and `parent_ids` vector are built before its table; the `operations`
/// vector and `OpLog` table are built after the loop.
fn op_log_to_envelope(ops: &[Operation], report: &crate::envelope::CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let op_offsets: Vec<_> = ops.iter().map(|op| operation_to_fbs(&mut b, op)).collect();
    let ops_vec = b.create_vector(&op_offsets);
    let oplog_off = fbs::OpLog::create(
        &mut b,
        &fbs::OpLogArgs {
            operations: Some(ops_vec),
        },
    );
    finish_envelope(b, fbs::Payload::OpLog, Some(oplog_off.as_union_value()), report)
}

/// Read the operation log of the repo identified by `handle`.
///
/// `limit < 0` ⇒ all operations; `limit >= 0` ⇒ at most `limit` most-recent ops.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` or the borrow yields `None`.
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
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_op_log(handle: u64, limit: i64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_op_log", handle, limit);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        // limit < 0 ⇒ None (all); 0 ⇒ Some(0); n ⇒ Some(n). No `as` cast (clippy-clean).
        let ops = session.repo.op_log(usize::try_from(limit).ok());
        precondition_envelope(&mut session.repo, ops, map_op_log_err, |v, p| op_log_to_envelope(v, p))
    });
    vec_into_token(buf)
}

// ── op show / op diff / op abandon (Story 9.21) ──────────────────────────────

/// A hex commit-id list as a string vector.
fn ids_to_fbs<'a>(
    b: &mut FlatBufferBuilder<'a>,
    ids: &[CommitId],
) -> WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<&'a str>>> {
    let offs: Vec<_> = ids.iter().map(|id| b.create_string(&id.0)).collect();
    b.create_vector(&offs)
}

/// Builds one `OpRefTarget` table.
fn ref_target_to_fbs<'a>(b: &mut FlatBufferBuilder<'a>, target: &OpRefTarget) -> WIPOffset<fbs::OpRefTarget<'a>> {
    let adds = ids_to_fbs(b, &target.adds);
    let removes = ids_to_fbs(b, &target.removes);
    fbs::OpRefTarget::create(
        b,
        &fbs::OpRefTargetArgs {
            adds: Some(adds),
            removes: Some(removes),
            conflicted: target.conflicted,
        },
    )
}

/// Builds one `RefDistance` table; `upper: None` is the presence pair's `has_upper = false`.
fn distance_to_fbs<'a>(b: &mut FlatBufferBuilder<'a>, distance: RefDistance) -> WIPOffset<fbs::RefDistance<'a>> {
    fbs::RefDistance::create(
        b,
        &fbs::RefDistanceArgs {
            lower: distance.lower,
            upper: distance.upper.unwrap_or(0),
            has_upper: distance.upper.is_some(),
        },
    )
}

/// Builds the `OpRemoteRefChange` tables of one remote section.
fn remote_changes_to_fbs<'a>(
    b: &mut FlatBufferBuilder<'a>,
    changes: &[OpRemoteRefChange],
) -> WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<fbs::OpRemoteRefChange<'a>>>> {
    let offs: Vec<_> = changes
        .iter()
        .map(|change| {
            let name = b.create_string(&change.name);
            let remote = b.create_string(&change.remote);
            let from = ref_target_to_fbs(b, &change.from);
            let to = ref_target_to_fbs(b, &change.to);
            fbs::OpRemoteRefChange::create(
                b,
                &fbs::OpRemoteRefChangeArgs {
                    name: Some(name),
                    remote: Some(remote),
                    from: Some(from),
                    from_tracked: change.from_tracked,
                    to: Some(to),
                    to_tracked: change.to_tracked,
                },
            )
        })
        .collect();
    b.create_vector(&offs)
}

/// Builds one `OpDiff` table — `commits` ABSENT when the section is `None`.
fn op_diff_to_fbs<'a>(b: &mut FlatBufferBuilder<'a>, diff: &OpDiff) -> WIPOffset<fbs::OpDiff<'a>> {
    let commits = diff.commits.as_ref().map(|commits| {
        let rows: Vec<_> = commits
            .changes
            .iter()
            .map(|row| {
                let commit_id = b.create_string(&row.commit_id.0);
                let added = ids_to_fbs(b, &row.added_commit_ids);
                let removed = ids_to_fbs(b, &row.removed_commit_ids);
                fbs::OpChangedCommit::create(
                    b,
                    &fbs::OpChangedCommitArgs {
                        commit_id: Some(commit_id),
                        abandoned: row.abandoned,
                        added_commit_ids: Some(added),
                        removed_commit_ids: Some(removed),
                    },
                )
            })
            .collect();
        let changes = b.create_vector(&rows);
        let visible = distance_to_fbs(b, commits.elided_newly_visible);
        let hidden = distance_to_fbs(b, commits.elided_newly_hidden);
        fbs::OpCommitsDiff::create(
            b,
            &fbs::OpCommitsDiffArgs {
                changes: Some(changes),
                elided_newly_visible: Some(visible),
                elided_newly_hidden: Some(hidden),
            },
        )
    });
    let working_copies: Vec<_> = diff
        .working_copies
        .iter()
        .map(|change| {
            let workspace = b.create_string(&change.workspace);
            let from = change.from.as_ref().map(|id| b.create_string(&id.0));
            let to = change.to.as_ref().map(|id| b.create_string(&id.0));
            fbs::OpWorkingCopyChange::create(
                b,
                &fbs::OpWorkingCopyChangeArgs {
                    workspace: Some(workspace),
                    from,
                    to,
                },
            )
        })
        .collect();
    let working_copies = b.create_vector(&working_copies);
    let local = |b: &mut FlatBufferBuilder<'a>, changes: &[zanshin_jj::OpRefChange]| {
        let offs: Vec<_> = changes
            .iter()
            .map(|change| {
                let name = b.create_string(&change.name);
                let from = ref_target_to_fbs(b, &change.from);
                let to = ref_target_to_fbs(b, &change.to);
                fbs::OpRefChange::create(
                    b,
                    &fbs::OpRefChangeArgs {
                        name: Some(name),
                        from: Some(from),
                        to: Some(to),
                    },
                )
            })
            .collect();
        b.create_vector(&offs)
    };
    let local_bookmarks = local(b, &diff.local_bookmarks);
    let local_tags = local(b, &diff.local_tags);
    let remote_bookmarks = remote_changes_to_fbs(b, &diff.remote_bookmarks);
    let remote_tags = remote_changes_to_fbs(b, &diff.remote_tags);
    fbs::OpDiff::create(
        b,
        &fbs::OpDiffArgs {
            commits,
            working_copies: Some(working_copies),
            local_bookmarks: Some(local_bookmarks),
            local_tags: Some(local_tags),
            remote_bookmarks: Some(remote_bookmarks),
            remote_tags: Some(remote_tags),
        },
    )
}

/// Serialise an [`OpShow`] into a finished `Envelope<OpShow>` buffer.
fn op_show_to_envelope(show: &OpShow, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let operation = operation_to_fbs(&mut b, &show.operation);
    let diff = show.diff.as_ref().map(|diff| op_diff_to_fbs(&mut b, diff));
    let off = fbs::OpShow::create(
        &mut b,
        &fbs::OpShowArgs {
            operation: Some(operation),
            diff,
        },
    );
    finish_envelope(b, fbs::Payload::OpShow, Some(off.as_union_value()), report)
}

/// Serialise an [`OpDiffResult`] into a finished `Envelope<OpDiffResult>` buffer.
fn op_diff_result_to_envelope(result: &OpDiffResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let from: Vec<_> = result.from.iter().map(|op| operation_to_fbs(&mut b, op)).collect();
    let from = b.create_vector(&from);
    let to = operation_to_fbs(&mut b, &result.to);
    let diff = op_diff_to_fbs(&mut b, &result.diff);
    let off = fbs::OpDiffResult::create(
        &mut b,
        &fbs::OpDiffResultArgs {
            from: Some(from),
            to: Some(to),
            diff: Some(diff),
        },
    );
    finish_envelope(b, fbs::Payload::OpDiffResult, Some(off.as_union_value()), report)
}

/// Serialise an [`OpAbandonResult`] into a finished `Envelope<OpAbandonResult>` buffer.
fn op_abandon_to_envelope(result: &OpAbandonResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let heads: Vec<_> = result.head_op_ids.iter().map(|id| b.create_string(&id.0)).collect();
    let heads = b.create_vector(&heads);
    let off = fbs::OpAbandonResult::create(
        &mut b,
        &fbs::OpAbandonResultArgs {
            abandoned_count: result.abandoned_count,
            reparented_count: result.reparented_count,
            nothing_changed: result.nothing_changed,
            head_op_ids: Some(heads),
        },
    );
    finish_envelope(b, fbs::Payload::OpAbandonResult, Some(off.as_union_value()), report)
}

/// Owned form of an `OpShowRequest`: the operation (`@` when absent) and `show_changes_in`.
struct OpShowArgs {
    operation: String,
    show_changes_in: Option<String>,
}

/// Parse an `OpShowRequest` buffer into owned [`OpShowArgs`].
///
/// `data`/`len` describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for
/// the call only, and the result is OWNED (see `repo.rs`'s request-reader comment).
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `OpShowRequest`, or its `kind` is not
///   `OpShow`.
fn read_op_show_request(data: *const u8, len: usize) -> Result<OpShowArgs, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::OpShowRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::OpShow)?;
    Ok(OpShowArgs {
        operation: req.operation().unwrap_or("@").to_owned(),
        show_changes_in: req.show_changes_in().map(ToOwned::to_owned),
    })
}

/// Parse an `OpDiffRequest` buffer into owned [`OpDiffOptions`]; an absent string is "not
/// given".
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `OpDiffRequest`, or its `kind` is not
///   `OpDiff`.
fn read_op_diff_request(data: *const u8, len: usize) -> Result<OpDiffOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see `read_op_show_request`).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::OpDiffRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::OpDiff)?;
    Ok(OpDiffOptions {
        operation: req.operation().map(ToOwned::to_owned),
        from: req.from().map(ToOwned::to_owned),
        to: req.to().map(ToOwned::to_owned),
        show_changes_in: req.show_changes_in().map(ToOwned::to_owned),
    })
}

/// Show one operation of the repo identified by `handle` and its repository changes against its
/// parent — the CLI's `jj op show` @ v0.46.0 (Story 9.21), as data.
///
/// The arguments cross as an `OpShowRequest` `FlatBuffers` request buffer: `operation` (an
/// operation expression — `@`, `@-`, an id prefix; ABSENT = `@`) and `show_changes_in` (the
/// CLI's `--show-changes-in`; ABSENT = `revsets.op-diff-changes-in`). Runs the pre-verb snapshot;
/// writes no operation of its own (a merge op's parents are merged into an unpublished operation,
/// as the CLI does).
///
/// Returns a `FlatBuffers` `Envelope` carrying an `OpShow` payload: the `Operation` and its
/// `OpDiff` — ABSENT for an operation with more than one parent. Warns revset diagnostics
/// (`jj.revset_diagnostic`) and `jj.op_diff_changes_unresolved` (then `OpDiff.commits` is ABSENT).
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `OpShowRequest`, or its `kind` is not
///   `OpShow`.
/// - `jj.operation_not_found` — no operation matches the id prefix; jj-lib's text in `context`.
/// - `jj.invalid_input` — the expression is no valid prefix, ambiguous, or resolves to no or
///   several operations (with the CLI's hint naming them); jj-lib's text in `context`.
/// - `jj.revset_parse_error` — `show_changes_in` does not parse ("Invalid `--show-changes-in`
///   expression: …").
/// - `jj.config_error` — `revsets.op-diff-changes-in` is not a string or does not parse
///   ("Invalid `revsets.op-diff-changes-in`: …"), or the effective config no longer reads.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.OpShowRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_op_show(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_op_show", handle);
    let buf = catch(|| {
        let args = read_op_show_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.op_show(&args.operation, args.show_changes_in.as_deref());
        precondition_envelope(&mut session.repo, result, map_mutate_err, op_show_to_envelope)
    });
    vec_into_token(buf)
}

/// Compare two operations of the repo identified by `handle` — the CLI's `jj op diff` @ v0.46.0
/// (Story 9.21), as data.
///
/// The arguments cross as an `OpDiffRequest` `FlatBuffers` request buffer, every string ABSENT
/// when its flag was not given: `from` / `to` (a missing one `@`), or `operation` (default `@`)
/// against its parents, and `show_changes_in`. `operation` together with `from` or `to` is clap's
/// conflict. Runs the pre-verb snapshot; writes no operation of its own (several from-operations
/// — a merge op's parents — are merged into an unpublished operation, as the CLI does).
///
/// Returns a `FlatBuffers` `Envelope` carrying an `OpDiffResult` payload: the operations diffed
/// from, the one diffed to, and the `OpDiff`. Warns as `zanshin_op_show`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `OpDiffRequest`, or its `kind` is not
///   `OpDiff`.
/// - `jj.invalid_input` — `operation` with `from` / `to` ("the argument '--operation' cannot be
///   used with '--from'"), refused before the snapshot: no `precondition`, nothing written; or an
///   operation expression as in `zanshin_op_show`.
/// - `jj.operation_not_found` — no operation matches an id prefix; jj-lib's text in `context`.
/// - `jj.revset_parse_error` — `show_changes_in` does not parse.
/// - `jj.config_error` — `revsets.op-diff-changes-in` is not a string or does not parse, or the
///   effective config no longer reads.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// As `zanshin_op_show`; `data` is built by `fbs.OpDiffRequestObjectBuilder(...).toBytes()`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_op_diff(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_op_diff", handle);
    let buf = catch(|| {
        let options = read_op_diff_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.op_diff(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, op_diff_result_to_envelope)
    });
    vec_into_token(buf)
}

/// Abandon operation history of the repo identified by `handle` — the CLI's `jj op abandon`
/// @ v0.46.0 (Story 9.21).
///
/// `operation` is the CLI's argument as a lone string: a range `a..b` (`..<op>` abandons `<op>`
/// and all its ancestors, `<op>..@-` the recent ones) or one operation. The range's descendants
/// are reparented onto `a`, the op heads replaced and this workspace's working copy remapped.
/// Like the CLI it runs NO pre-verb snapshot — only the start-up secure-config fix-up — so the
/// envelope never carries a `precondition`; it writes no operation, it rewrites the history.
///
/// Returns a `FlatBuffers` `Envelope` carrying an `OpAbandonResult` payload: the CLI's status
/// line as counts, or `nothing_changed`, and the op heads afterwards. Warns
/// `jj.op_abandon_working_copy_not_updated` when the working copy is recorded at an operation
/// that is not a head (it is then left as it is).
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `operation` is a null pointer.
/// - `ffi.utf8_error` — `operation` is not valid UTF-8.
/// - `jj.invalid_input` — "Cannot abandon the current operation <id>" (with the CLI's hint when
///   there is one head), "Cannot abandon the root operation", "Cannot abandon a merge operation",
///   or an operation expression that does not resolve to one operation; nothing is written.
/// - `jj.operation_not_found` — no operation matches an id prefix; jj-lib's text in `context`.
/// - `jj.config_error` — the effective config stack no longer reads.
/// - `jj.jj_lib_error` — an op-store, op-heads or working-copy failure; detail in `context`.
///
/// # Safety
/// `handle` as `zanshin_op_show`. `operation` must be null or a NUL-terminated string Dart
/// allocates and frees; Rust only borrows it for the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_op_abandon(handle: u64, operation: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_op_abandon", handle);
    let buf = catch(|| {
        // SAFETY: the caller's NUL-terminated string, borrowed for this call only.
        let operation = unsafe { cstr_to_string(operation) }?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.op_abandon(&operation);
        precondition_envelope(&mut session.repo, result, map_mutate_err, op_abandon_to_envelope)
    });
    vec_into_token(buf)
}

// ── op restore / op revert / op integrate (Story 9.12) ───────────────────────

/// Serialise an [`OpIntegrateResult`] into a finished `Envelope<OpIntegrateResult>` buffer.
fn op_integrate_to_envelope(result: &OpIntegrateResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let head = b.create_string(&result.head_op_id.0);
    let off = fbs::OpIntegrateResult::create(
        &mut b,
        &fbs::OpIntegrateResultArgs {
            head_op_id: Some(head),
            reconciled: result.reconciled,
        },
    );
    finish_envelope(b, fbs::Payload::OpIntegrateResult, Some(off.as_union_value()), report)
}

/// An `ffi.invalid_argument` refusal of a request field, `detail` in `context`.
fn invalid_argument(detail: String) -> FfiErrorObj {
    FfiErrorObj {
        report: None,
        hints: Vec::new(),
        code: FFI_INVALID_ARGUMENT.to_owned(),
        context: Some(detail),
    }
}

/// The `--what` list of a request: ABSENT is empty (the flag absent); an `Unspecified` or unknown
/// member is refused.
///
/// # Errors
/// - `ffi.invalid_argument` — a member is `Unspecified` or a value this build does not know.
fn restore_what(what: Option<flatbuffers::Vector<'_, fbs::RestoreWhat>>) -> Result<Vec<RestoreWhat>, FfiErrorObj> {
    what.into_iter()
        .flatten()
        .map(|member| match member {
            fbs::RestoreWhat::Repo => Ok(RestoreWhat::Repo),
            fbs::RestoreWhat::RemoteTracking => Ok(RestoreWhat::RemoteTracking),
            other => Err(invalid_argument(format!("invalid restore what: {other:?}"))),
        })
        .collect()
}

/// Owned form of an `OpRestoreRequest` / `OpRevertRequest`: the operation and `--what`.
struct OpEditArgs {
    operation: String,
    what: Vec<RestoreWhat>,
}

/// Parse an `OpRestoreRequest` buffer into owned [`OpEditArgs`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `OpRestoreRequest`, its `kind` is not
///   `OpRestore`, `operation` is ABSENT, or a `what` member is `Unspecified` or unknown.
fn read_op_restore_request(data: *const u8, len: usize) -> Result<OpEditArgs, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see `read_op_show_request`).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::OpRestoreRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::OpRestore)?;
    let operation = req
        .operation()
        .ok_or_else(|| invalid_argument("operation is required".to_owned()))?;
    Ok(OpEditArgs {
        operation: operation.to_owned(),
        what: restore_what(req.what())?,
    })
}

/// Parse an `OpRevertRequest` buffer into owned [`OpEditArgs`]; an ABSENT `operation` is `@`.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `OpRevertRequest`, its `kind` is not
///   `OpRevert`, or a `what` member is `Unspecified` or unknown.
fn read_op_revert_request(data: *const u8, len: usize) -> Result<OpEditArgs, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see `read_op_show_request`).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::OpRevertRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::OpRevert)?;
    Ok(OpEditArgs {
        operation: req.operation().unwrap_or("@").to_owned(),
        what: restore_what(req.what())?,
    })
}

/// Restore the repo identified by `handle` to the state at an operation — the CLI's
/// `jj op restore` @ v0.46.0 (Story 9.12).
///
/// The arguments cross as an `OpRestoreRequest` `FlatBuffers` request buffer: `operation` (an
/// operation expression — `@-`, an id prefix; REQUIRED) and `what` (the CLI's repeatable
/// `--what`; ABSENT or EMPTY = both portions). Runs the pre-verb snapshot, then restores the
/// chosen portions of the operation's view (`git_refs` / `git_heads` stay current).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload, the operation
/// described `restore to operation <hex>`. A restored view equal to the current one writes no
/// operation and `new_op_id` is the head the verb started from (Story 9.40). A view without this
/// workspace's working-copy commit (the root operation's) leaves `working_copy_change_id` ABSENT
/// and warns `jj.workspace_no_longer_exists`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `OpRestoreRequest`, its `kind` is not
///   `OpRestore`, `operation` is ABSENT, or a `what` member is `Unspecified` or unknown.
/// - `jj.operation_not_found` — no operation matches the id prefix; jj-lib's text in `context`.
/// - `jj.invalid_input` — the expression is no valid prefix, ambiguous, or resolves to no or
///   several operations (with the CLI's hint naming them); jj-lib's text in `context`.
/// - `jj.config_error` — the effective config no longer reads, the pre-verb snapshot found a
///   value wrongly typed, or the finish's immutable set does not resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// As `zanshin_op_show`; `data` is built by `fbs.OpRestoreRequestObjectBuilder(...).toBytes()`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_op_restore(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_op_restore", handle);
    let buf = catch(|| {
        let args = read_op_restore_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.op_restore(&args.operation, &args.what);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Revert one operation of the repo identified by `handle` by applying its inverse — the CLI's
/// `jj op revert` @ v0.46.0 (Story 9.12).
///
/// The arguments cross as an `OpRevertRequest` `FlatBuffers` request buffer: `operation` (ABSENT =
/// `@`, the CLI's default) and `what` (`--what`; ABSENT or EMPTY = both portions). Runs the
/// pre-verb snapshot; the operation's parent state is merged in three-way against its own, so
/// later work stays and descendants of rewritten commits are rebased.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload, the operation
/// described `revert operation <hex>`; when nothing changed, no operation and `new_op_id` is the
/// head the verb started from (Story 9.40). A revert that drops this workspace's working-copy
/// commit (of the `add workspace` operation) leaves `working_copy_change_id` ABSENT and warns
/// `jj.workspace_no_longer_exists`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `OpRevertRequest`, its `kind` is not
///   `OpRevert`, or a `what` member is `Unspecified` or unknown.
/// - `jj.invalid_input` — "Cannot revert root operation", "Cannot revert a merge operation"
///   (nothing written by the verb), or an operation expression as in `zanshin_op_restore`.
/// - `jj.operation_not_found` — no operation matches the id prefix; jj-lib's text in `context`.
/// - `jj.config_error` / `jj.stale_working_copy` / `jj.jj_lib_error` — as `zanshin_op_restore`.
///
/// # Safety
/// As `zanshin_op_show`; `data` is built by `fbs.OpRevertRequestObjectBuilder(...).toBytes()`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_op_revert(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_op_revert", handle);
    let buf = catch(|| {
        let args = read_op_revert_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.op_revert(&args.operation, &args.what);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Make an operation part of the operation log of the repo identified by `handle` — the CLI's
/// `jj op integrate` @ v0.46.0 (Story 9.12).
///
/// `operation` is the CLI's argument as a lone string (an id prefix names an unpublished
/// operation too). The op heads gain it in place of its parents: a descendant of the head becomes
/// the head, a divergent one is merged with the other heads into a
/// `reconcile divergent operations` operation in this workspace, one already in the log changes
/// nothing. Like the CLI's `workspace_helper_no_snapshot` it runs the start-up (the secure-config
/// fix-up, the effective config, the alias tables, the `immutable_heads()` / short-prefixes parse,
/// the `trunk()` fallback, each with its warnings) but NO pre-verb snapshot and no Git import, so
/// the envelope never carries a `precondition`.
///
/// Returns a `FlatBuffers` `Envelope` carrying an `OpIntegrateResult` payload: the head operation
/// afterwards and `reconciled` (the integrate itself merged the heads; a reconcile the head load
/// wrote first does not count).
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `operation` is a null pointer.
/// - `ffi.utf8_error` — `operation` is not valid UTF-8.
/// - `jj.operation_not_found` — no operation matches the id prefix; nothing is written.
/// - `jj.invalid_input` — the expression is no valid prefix, ambiguous, or resolves to no or
///   several operations; nothing is written.
/// - `jj.config_error` — the start-up found the effective config unreadable, or an alias table,
///   `immutable_heads()` or short-prefixes revset that does not parse; nothing is written.
/// - `jj.jj_lib_error` — the head could not be loaded, or an op-store / op-heads failure; detail in
///   `context`.
///
/// # Safety
/// `handle` as `zanshin_op_show`. `operation` must be null or a NUL-terminated string Dart
/// allocates and frees; Rust only borrows it for the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_op_integrate(handle: u64, operation: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_op_integrate", handle);
    let buf = catch(|| {
        // SAFETY: the caller's NUL-terminated string, borrowed for this call only.
        let operation = unsafe { cstr_to_string(operation) }?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.op_integrate(&operation);
        precondition_envelope(&mut session.repo, result, map_mutate_err, op_integrate_to_envelope)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use zanshin_jj::{OpLogError, Operation, OperationId, Timestamp};

    use super::{map_op_log_err, op_log_to_envelope};
    use crate::fbs;
    use crate::JJ_JJ_LIB_ERROR;

    #[allow(clippy::too_many_arguments)]
    fn make_op(
        id: &str,
        parent_ids: Vec<&str>,
        millis: i64,
        tz: i32,
        user: &str,
        host: &str,
        desc: &str,
        root_op: bool,
        is_snapshot: bool,
    ) -> Operation {
        Operation {
            id: OperationId(id.to_owned()),
            parent_ids: parent_ids.into_iter().map(|p| OperationId(p.to_owned())).collect(),
            timestamp: Timestamp {
                millis_since_epoch: millis,
                tz_offset_minutes: tz,
            },
            user: user.to_owned(),
            host: host.to_owned(),
            description: desc.to_owned(),
            root_op,
            is_snapshot,
            workspace_name: None,
            tags: Vec::new(),
        }
    }

    #[test]
    fn op_log_to_envelope_roundtrips_all_fields() {
        let root_op = make_op("aabbcc", vec![], 0, 0, "", "", "", true, false);
        let non_root = make_op(
            "ddeeff",
            vec!["aabbcc"],
            1_700_000_000_000,
            60,
            "alice",
            "host.local",
            "new empty commit",
            false,
            false,
        );
        let mut multi_parent = make_op(
            "112233",
            vec!["ddeeff", "aabbcc"],
            1_700_000_001_000,
            -120,
            "bob",
            "builder",
            "snapshot working copy",
            false,
            true,
        );
        multi_parent.workspace_name = Some("second".to_owned());
        multi_parent.tags = vec![zanshin_jj::OperationTag {
            key: "args".to_owned(),
            value: "jj new".to_owned(),
        }];

        let ops = vec![multi_parent.clone(), non_root.clone(), root_op.clone()];
        let buf = op_log_to_envelope(&ops, &crate::envelope::CallReport::default());

        let env = fb_root::<fbs::Envelope>(&buf).expect("FlatBuffers Verifier must pass");
        assert!(env.ok(), "envelope must be ok");
        assert_eq!(env.data_type(), fbs::Payload::OpLog, "data_type must be OpLog");

        let payload = env.data_as_op_log().expect("data_as_op_log must succeed");
        let fbs_ops = payload.operations().expect("operations must be present");
        assert_eq!(fbs_ops.len(), 3, "must have 3 operations");

        // multi_parent op
        let fbs_mp = fbs_ops.get(0);
        assert_eq!(fbs_mp.id(), Some("112233"), "multi-parent id");
        let pids: Vec<_> = fbs_mp.parent_ids().map(|v| v.iter().collect()).unwrap_or_default();
        assert_eq!(pids, vec!["ddeeff", "aabbcc"], "multi-parent parent_ids");
        assert_eq!(fbs_mp.timestamp_millis(), 1_700_000_001_000, "multi-parent timestamp");
        assert_eq!(fbs_mp.tz_offset_minutes(), -120, "multi-parent tz");
        assert_eq!(fbs_mp.user(), Some("bob"), "multi-parent user");
        assert_eq!(fbs_mp.host(), Some("builder"), "multi-parent host");
        assert_eq!(fbs_mp.description(), Some("snapshot working copy"), "multi-parent desc");
        assert!(!fbs_mp.root_op(), "multi-parent root_op must be false");
        assert!(fbs_mp.is_snapshot(), "multi-parent is_snapshot must be true");
        assert_eq!(fbs_mp.workspace_name(), Some("second"), "Story 9.21: the workspace");
        let tags = fbs_mp.tags().expect("tags");
        assert_eq!((tags.get(0).key(), tags.get(0).value()), (Some("args"), Some("jj new")));

        // non-root op
        let fbs_nr = fbs_ops.get(1);
        assert_eq!(fbs_nr.id(), Some("ddeeff"), "non-root id");
        let nr_pids: Vec<_> = fbs_nr.parent_ids().map(|v| v.iter().collect()).unwrap_or_default();
        assert_eq!(nr_pids, vec!["aabbcc"], "non-root parent_ids");
        assert_eq!(fbs_nr.timestamp_millis(), 1_700_000_000_000, "non-root timestamp");
        assert_eq!(fbs_nr.tz_offset_minutes(), 60, "non-root tz");
        assert!(!fbs_nr.root_op(), "non-root root_op must be false");
        assert!(!fbs_nr.is_snapshot(), "non-root is_snapshot must be false");
        assert_eq!(fbs_nr.workspace_name(), None, "no workspace recorded = ABSENT");
        assert_eq!(fbs_nr.tags().map(|tags| tags.len()), Some(0));

        // root op
        let fbs_root = fbs_ops.get(2);
        assert_eq!(fbs_root.id(), Some("aabbcc"), "root id");
        let root_pids: Vec<_> = fbs_root.parent_ids().map(|v| v.iter().collect()).unwrap_or_default();
        assert!(root_pids.is_empty(), "root parent_ids must be empty");
        assert!(fbs_root.root_op(), "root root_op must be true");
        assert_eq!(fbs_root.description(), Some(""), "root description must be empty");
    }

    #[test]
    fn map_op_log_err_backend_maps_to_jj_lib_error() {
        let obj = map_op_log_err(OpLogError::Backend("boom".into()));
        assert_eq!(obj.code, JJ_JJ_LIB_ERROR, "code must be jj.jj_lib_error");
        assert_eq!(obj.context, Some("boom".to_owned()), "context must be forwarded");
    }

    fn commit(hex: &str) -> zanshin_jj::CommitId {
        zanshin_jj::CommitId(hex.to_owned())
    }

    fn full_diff() -> zanshin_jj::OpDiff {
        let target = zanshin_jj::OpRefTarget {
            adds: vec![commit("a1"), commit("a2")],
            removes: vec![commit("r1")],
            conflicted: true,
        };
        let absent = zanshin_jj::OpRefTarget {
            adds: Vec::new(),
            removes: Vec::new(),
            conflicted: false,
        };
        let remote = zanshin_jj::OpRemoteRefChange {
            name: "main".to_owned(),
            remote: "origin".to_owned(),
            from: absent.clone(),
            from_tracked: false,
            to: target.clone(),
            to_tracked: true,
        };
        zanshin_jj::OpDiff {
            commits: Some(zanshin_jj::OpCommitsDiff {
                changes: vec![zanshin_jj::OpChangedCommit {
                    commit_id: commit("c1"),
                    abandoned: true,
                    added_commit_ids: Vec::new(),
                    removed_commit_ids: vec![commit("c1")],
                }],
                elided_newly_visible: zanshin_jj::RefDistance { lower: 2, upper: None },
                elided_newly_hidden: zanshin_jj::RefDistance {
                    lower: 1,
                    upper: Some(1),
                },
            }),
            working_copies: vec![zanshin_jj::OpWorkingCopyChange {
                workspace: "default".to_owned(),
                from: None,
                to: Some(commit("w2")),
            }],
            local_bookmarks: vec![zanshin_jj::OpRefChange {
                name: "b".to_owned(),
                from: absent.clone(),
                to: target.clone(),
            }],
            local_tags: vec![zanshin_jj::OpRefChange {
                name: "t".to_owned(),
                from: target,
                to: absent,
            }],
            remote_bookmarks: vec![remote.clone()],
            remote_tags: vec![remote],
        }
    }

    /// Every `OpDiff` section crosses with its values; a `None` commit section and an absent
    /// working-copy side are ABSENT on the wire.
    #[test]
    fn op_show_crosses_every_diff_section() {
        let op = make_op("o1", vec!["o0"], 1, 0, "u", "h", "d", false, false);
        let show = zanshin_jj::OpShow {
            operation: op,
            diff: Some(full_diff()),
        };
        let buf = super::op_show_to_envelope(&show, &crate::envelope::CallReport::default());
        let env = fb_root::<fbs::Envelope>(&buf).expect("verifies");
        let payload = env.data_as_op_show().expect("OpShow");
        assert_eq!(payload.operation().and_then(|op| op.id()), Some("o1"));
        let diff = payload.diff().expect("diff");
        let commits = diff.commits().expect("commits");
        let row = commits.changes().unwrap().get(0);
        assert_eq!(row.commit_id(), Some("c1"));
        assert!(row.abandoned());
        assert_eq!(row.added_commit_ids().map(|v| v.len()), Some(0));
        assert_eq!(row.removed_commit_ids().unwrap().get(0), "c1");
        let visible = commits.elided_newly_visible().unwrap();
        assert_eq!((visible.lower(), visible.has_upper()), (2, false));
        let hidden = commits.elided_newly_hidden().unwrap();
        assert_eq!((hidden.lower(), hidden.upper(), hidden.has_upper()), (1, 1, true));
        let wc = diff.working_copies().unwrap().get(0);
        assert_eq!(
            (wc.workspace(), wc.from(), wc.to()),
            (Some("default"), None, Some("w2"))
        );
        let bookmark = diff.local_bookmarks().unwrap().get(0);
        assert_eq!(bookmark.name(), Some("b"));
        let to = bookmark.to().unwrap();
        assert!(to.conflicted());
        assert_eq!(to.adds().unwrap().iter().collect::<Vec<_>>(), ["a1", "a2"]);
        assert_eq!(to.removes().unwrap().iter().collect::<Vec<_>>(), ["r1"]);
        assert!(!bookmark.from().unwrap().conflicted());
        assert_eq!(diff.local_tags().unwrap().get(0).name(), Some("t"));
        for remote in [
            diff.remote_bookmarks().unwrap().get(0),
            diff.remote_tags().unwrap().get(0),
        ] {
            assert_eq!((remote.name(), remote.remote()), (Some("main"), Some("origin")));
            assert!(!remote.from_tracked() && remote.to_tracked());
        }

        let merge = zanshin_jj::OpShow {
            operation: make_op("m", vec!["a", "b"], 1, 0, "", "", "", false, false),
            diff: None,
        };
        let buf = super::op_show_to_envelope(&merge, &crate::envelope::CallReport::default());
        let env = fb_root::<fbs::Envelope>(&buf).expect("verifies");
        assert!(env.data_as_op_show().unwrap().diff().is_none(), "no diff = ABSENT");

        let mut unresolved = full_diff();
        unresolved.commits = None;
        let result = zanshin_jj::OpDiffResult {
            from: vec![make_op("f", vec![], 1, 0, "", "", "", true, false)],
            to: make_op("t", vec!["f"], 1, 0, "", "", "", false, false),
            diff: unresolved,
        };
        let buf = super::op_diff_result_to_envelope(&result, &crate::envelope::CallReport::default());
        let env = fb_root::<fbs::Envelope>(&buf).expect("verifies");
        let payload = env.data_as_op_diff_result().expect("OpDiffResult");
        assert_eq!(payload.from().unwrap().get(0).id(), Some("f"));
        assert_eq!(payload.to().and_then(|op| op.id()), Some("t"));
        assert!(payload.diff().unwrap().commits().is_none(), "unresolved = ABSENT");
    }

    #[test]
    fn op_integrate_result_crosses_its_head_and_flag() {
        for reconciled in [false, true] {
            let result = zanshin_jj::OpIntegrateResult {
                head_op_id: OperationId("h".to_owned()),
                reconciled,
            };
            let buf = super::op_integrate_to_envelope(&result, &crate::envelope::CallReport::default());
            let env = fb_root::<fbs::Envelope>(&buf).expect("verifies");
            let payload = env.data_as_op_integrate_result().expect("OpIntegrateResult");
            assert_eq!((payload.head_op_id(), payload.reconciled()), (Some("h"), reconciled));
        }
    }

    #[test]
    fn op_abandon_result_crosses_its_counts_and_heads() {
        let result = zanshin_jj::OpAbandonResult {
            abandoned_count: 4,
            reparented_count: 1,
            nothing_changed: false,
            head_op_ids: vec![OperationId("h".to_owned())],
        };
        let buf = super::op_abandon_to_envelope(&result, &crate::envelope::CallReport::default());
        let env = fb_root::<fbs::Envelope>(&buf).expect("verifies");
        let payload = env.data_as_op_abandon_result().expect("OpAbandonResult");
        assert_eq!((payload.abandoned_count(), payload.reparented_count()), (4, 1));
        assert!(!payload.nothing_changed());
        assert_eq!(payload.head_op_ids().unwrap().get(0), "h");
    }
}
