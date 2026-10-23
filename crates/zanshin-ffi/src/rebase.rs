// SPDX-License-Identifier: MIT

//! `zanshin_rebase` / `zanshin_parallelize` / `zanshin_arrange` — the CLI's `jj rebase`,
//! `jj parallelize` and `jj arrange` (its TUI replaced by key actions as data; Story 9.16).
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the shared `MutationResult`
//! into a `FlatBuffers` `Envelope`. The arguments cross as request BUFFERS (ADR-0001
//! composite-input pattern): `RebaseRequest`, a `Parallelize`-tagged `ChangeIdList` and
//! `ArrangeRequest`. The handle is borrowed, never consumed. Every call runs the pre-verb snapshot
//! (Story 9.26), so every envelope carries the precondition report and the call's warnings.

use flatbuffers::{ForwardsUOffset, Vector, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ArrangeAction, ArrangeOptions, ChangeId, RebaseOptions};

use crate::envelope::{
    catch, expect_request_kind, invalid_request, missing_field, ok_mutation_result, precondition_envelope,
    reject_null_request, session_from_handle, FfiErrorObj, FFI_INVALID_ARGUMENT,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::{map_mutate_err, read_change_id_list};

// ── Request-buffer readers ───────────────────────────────────────────────────
//
// Same discipline as `squash_split.rs`'s readers: `data`/`len` describe a caller-owned buffer Dart
// builds and frees itself; Rust borrows it for the call only, and each reader returns OWNED values.

/// A string vector as change ids; ABSENT is empty — the flag not given.
fn change_ids(v: Option<Vector<'_, ForwardsUOffset<&str>>>) -> Vec<ChangeId> {
    v.map(|v| v.iter().map(|s| ChangeId(s.to_owned())).collect())
        .unwrap_or_default()
}

/// Parse a `RebaseRequest` buffer into owned [`RebaseOptions`]; an ABSENT vector is empty.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `RebaseRequest` buffer, or its `kind`
///   is not `Rebase`.
fn read_rebase_request(data: *const u8, len: usize) -> Result<RebaseOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::RebaseRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Rebase)?;
    Ok(RebaseOptions {
        branch: change_ids(req.branch()),
        source: change_ids(req.source()),
        revisions: change_ids(req.revisions()),
        onto: change_ids(req.onto()),
        insert_after: change_ids(req.insert_after()),
        insert_before: change_ids(req.insert_before()),
        skip_emptied: req.skip_emptied(),
        keep_divergent: req.keep_divergent(),
        simplify_parents: req.simplify_parents(),
    })
}

/// One `ArrangeAction` table as the owned [`ArrangeAction`].
///
/// # Errors
/// - `ffi.invalid_argument` — its `kind` is `Unspecified` (absent) or not a known
///   `ArrangeActionKind`.
/// - `jj.invalid_input` — its `change_id` is absent: "`change_id` is required".
fn read_arrange_action(action: fbs::ArrangeAction<'_>) -> Result<ArrangeAction, FfiErrorObj> {
    let change = || {
        action
            .change_id()
            .map(|s| ChangeId(s.to_owned()))
            .ok_or_else(|| missing_field("change_id"))
    };
    Ok(match action.kind() {
        fbs::ArrangeActionKind::SwapDown => ArrangeAction::SwapDown(change()?),
        fbs::ArrangeActionKind::SwapUp => ArrangeAction::SwapUp(change()?),
        fbs::ArrangeActionKind::Abandon => ArrangeAction::Abandon(change()?),
        fbs::ArrangeActionKind::Keep => ArrangeAction::Keep(change()?),
        other => {
            return Err(FfiErrorObj {
                report: None,
                hints: Vec::new(),
                code: FFI_INVALID_ARGUMENT.to_owned(),
                context: Some(format!("unknown arrange action kind: {other:?}")),
            })
        }
    })
}

/// Parse an `ArrangeRequest` buffer into owned [`ArrangeOptions`]; an ABSENT vector is empty.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `ArrangeRequest` buffer, its `kind` is
///   not `Arrange`, or an action's `kind` is absent or not a known `ArrangeActionKind`.
/// - `jj.invalid_input` — an action's `change_id` is absent: "`change_id` is required".
fn read_arrange_request(data: *const u8, len: usize) -> Result<ArrangeOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ArrangeRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Arrange)?;
    let actions = req
        .actions()
        .into_iter()
        .flatten()
        .map(read_arrange_action)
        .collect::<Result<_, _>>()?;
    Ok(ArrangeOptions {
        revisions: change_ids(req.revisions()),
        actions,
    })
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// Move revisions to a new place in the graph, in the repo identified by `handle` — the CLI's
/// `jj rebase` (Story 9.16).
///
/// The arguments cross as a `RebaseRequest` `FlatBuffers` request buffer, one field per CLI flag:
/// what moves — `branch` (`-b`, the roots of `destination..branch` with their descendants),
/// `source` (`-s`, with their descendants) or `revisions` (`-r`, only these; at most one of the
/// three, none = the CLI's `-b @`) — where — `onto` (`-o`) or `insert_after` / `insert_before`
/// (`-A` / `-B`) — and the flags `skip_emptied`, `keep_divergent`, `simplify_parents`. A move
/// with nothing to rebase or that changes nothing writes NO operation and
/// `MutationResult.new_op_id` carries the PRE-CALL head. Otherwise the operation is the CLI's
/// (`rebase commit <hex>`, `rebase commit <hex> and <n> more`, `rebase <n> commits`, `rebase commit
/// <hex> and descendants`, `rebase <n> commits and their descendants`). The working copy is
/// snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success: the
/// commits the move abandoned (divergent twins already in the destination, newly emptied commits)
/// in `abandoned_change_ids`, an abandoned `@`'s replacement in `new_change_ids`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `RebaseRequest` buffer, or its `kind`
///   is not `Rebase`.
/// - `jj.invalid_input` — more than one of `branch`/`source`/`revisions`, `onto` with
///   `insert_after`/`insert_before`, or no location (refused before anything resolves); "Cannot
///   rebase <12 hex> onto itself" / "… onto descendant <12 hex>"; a location that would create a
///   loop or resolves no parent; a merge with the root commit as a parent in a Git repo; detail in
///   `context`.
/// - `jj.change_not_found` — an id is malformed, carried by no VISIBLE commit, or divergent; the id
///   in `context`.
/// - `jj.immutable` — a commit the move rewrites, or a child the location would rewrite, is
///   immutable; its hex commit id in `context`.
/// - `jj.config_error` — the config or its `immutable_heads()` alias does not read or resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.RebaseRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_rebase(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_rebase", handle);
    let buf = catch(|| {
        let options = read_rebase_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.rebase(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Make revisions siblings, in the repo identified by `handle` — the CLI's `jj parallelize`
/// (Story 9.16).
///
/// The revisions cross as a `ChangeIdList` `FlatBuffers` request buffer tagged `Parallelize`
/// (`change_ids`; `insert_after` / `insert_before` are ignored). Each keeps its parents outside the
/// set and inherits an in-set parent's new parents; a child of the set keeps every target it
/// descended from as an ancestor. Only the targets that move are checked rewritable. A set that
/// changes nothing (one revision, none) writes NO operation and `MutationResult.new_op_id` carries
/// the PRE-CALL head; otherwise the operation is `parallelize <n> commits`. The working copy is
/// snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ChangeIdList` buffer, or its `kind` is
///   not `Parallelize` — a `NewChange`- or `Abandon`-tagged buffer is refused here.
/// - `jj.change_not_found` — an id is malformed, carried by no VISIBLE commit, or divergent; the id
///   in `context`.
/// - `jj.immutable` — a target that would move is immutable; its hex commit id in `context`.
/// - `jj.config_error` — the config or its `immutable_heads()` alias does not read or resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.ChangeIdListObjectBuilder(...).toBytes()`); Rust only borrows it for the duration of
/// the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_parallelize(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_parallelize", handle);
    let buf = catch(|| {
        let change_ids = read_change_id_list(data, len, fbs::RequestKind::Parallelize)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.parallelize(&change_ids);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Rearrange revisions, in the repo identified by `handle` — the CLI's `jj arrange` with its TUI
/// session sent as data (Story 9.16).
///
/// The arguments cross as an `ArrangeRequest` `FlatBuffers` request buffer: `revisions` (ABSENT or
/// EMPTY = the `revsets.arrange` setting, jj's default `reachable(@, mutable())`, whose parse
/// diagnostics warn "In revset expression") and `actions` — the TUI's keys, replayed in order:
/// `SwapDown` / `SwapUp` swap a commit with its one parent / child in the set (ignored otherwise,
/// as the TUI ignores it), `Abandon` / `Keep` mark it. An empty set or actions that change nothing
/// write NO operation and `MutationResult.new_op_id` carries the PRE-CALL head; otherwise the
/// operation is `arrange revisions`. The working copy is snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success: the commits
/// marked abandoned in `abandoned_change_ids`, an abandoned `@`'s replacement in
/// `new_change_ids`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `ArrangeRequest` buffer, its `kind` is
///   not `Arrange`, or an action's `kind` is absent (`Unspecified`) or unknown.
/// - `jj.invalid_input` — an action's `change_id` is absent ("`change_id` is required"); the set has
///   a gap ("Cannot arrange revset with gaps in.", with the hint "Revision <12 hex> would need to be
///   in the set."); an action names a change outside the set ("… is not among the revisions
///   to arrange").
/// - `jj.change_not_found` — a revision or an action's change id is malformed, carried by no
///   VISIBLE commit, or divergent; the id in `context`.
/// - `jj.immutable` — a target is immutable; its hex commit id in `context`.
/// - `jj.revset_parse_error` / `jj.revset_resolution_error` — the arrange revset setting (the
///   default target set) does not parse or resolve.
/// - `jj.config_error` — the arrange revset setting is not a string, or the config or its
///   `immutable_heads()` alias does not read or resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.ArrangeRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_arrange(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_arrange", handle);
    let buf = catch(|| {
        let options = read_arrange_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.arrange(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use zanshin_jj::{ArrangeAction, ChangeId};

    use super::{read_arrange_request, read_rebase_request};
    use crate::envelope::{FFI_INVALID_ARGUMENT, JJ_INVALID_INPUT};
    use crate::fbs;

    fn id(s: &str) -> ChangeId {
        ChangeId(s.to_owned())
    }

    /// A `RebaseRequest` with `-b b -r r -A a` and the three flags as given.
    fn rebase_request(flags: [bool; 3]) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let mut one = |s: &str| {
            let s = b.create_string(s);
            b.create_vector(&[s])
        };
        let (branch, revisions, after) = (one("b"), one("r"), one("a"));
        let req = fbs::RebaseRequest::create(
            &mut b,
            &fbs::RebaseRequestArgs {
                kind: fbs::RequestKind::Rebase,
                branch: Some(branch),
                revisions: Some(revisions),
                insert_after: Some(after),
                skip_emptied: flags[0],
                keep_divergent: flags[1],
                simplify_parents: flags[2],
                ..fbs::RebaseRequestArgs::default()
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    /// Absent vectors are empty; present ones and each flag cross unchanged, field for field.
    #[test]
    fn the_rebase_reader_carries_every_flag() {
        for flags in [[true, false, true], [false, true, false]] {
            let bytes = rebase_request(flags);
            let options = read_rebase_request(bytes.as_ptr(), bytes.len()).expect("valid");
            assert_eq!(options.branch, [id("b")]);
            assert_eq!(options.revisions, [id("r")]);
            assert_eq!(options.insert_after, [id("a")]);
            assert!(options.source.is_empty() && options.onto.is_empty() && options.insert_before.is_empty());
            assert_eq!(
                [options.skip_emptied, options.keep_divergent, options.simplify_parents],
                flags
            );
        }
    }

    fn arrange_request(kind: fbs::RequestKind, actions: &[(fbs::ArrangeActionKind, Option<&str>)]) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let offsets: Vec<_> = actions
            .iter()
            .map(|(kind, change)| {
                let change_id = change.map(|c| b.create_string(c));
                fbs::ArrangeAction::create(&mut b, &fbs::ArrangeActionArgs { kind: *kind, change_id })
            })
            .collect();
        let actions = b.create_vector(&offsets);
        let req = fbs::ArrangeRequest::create(
            &mut b,
            &fbs::ArrangeRequestArgs {
                kind,
                revisions: None,
                actions: Some(actions),
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    #[test]
    fn the_arrange_reader_maps_every_action_kind() {
        use fbs::ArrangeActionKind as K;
        let bytes = arrange_request(
            fbs::RequestKind::Arrange,
            &[
                (K::SwapDown, Some("d")),
                (K::SwapUp, Some("u")),
                (K::Abandon, Some("a")),
                (K::Keep, Some("k")),
            ],
        );
        let options = read_arrange_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert!(options.revisions.is_empty(), "absent revisions are empty");
        assert_eq!(
            options.actions,
            [
                ArrangeAction::SwapDown(id("d")),
                ArrangeAction::SwapUp(id("u")),
                ArrangeAction::Abandon(id("a")),
                ArrangeAction::Keep(id("k")),
            ]
        );
    }

    #[test]
    fn the_arrange_reader_refuses_a_missing_id_an_unknown_kind_and_a_wrong_tag() {
        use fbs::ArrangeActionKind as K;
        let bytes = arrange_request(fbs::RequestKind::Arrange, &[(K::Keep, None)]);
        let err = read_arrange_request(bytes.as_ptr(), bytes.len()).expect_err("missing id");
        assert_eq!(err.code, JJ_INVALID_INPUT);
        assert_eq!(err.context.as_deref(), Some("change_id is required"));

        let bytes = arrange_request(fbs::RequestKind::Arrange, &[(K(9), Some("x"))]);
        let err = read_arrange_request(bytes.as_ptr(), bytes.len()).expect_err("unknown kind");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);

        // An ABSENT kind is `Unspecified`, refused — never a silent `SwapDown`.
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
        let change_id = Some(b.create_string("x"));
        let action = fbs::ArrangeAction::create(
            &mut b,
            &fbs::ArrangeActionArgs {
                change_id,
                ..fbs::ArrangeActionArgs::default()
            },
        );
        let actions = b.create_vector(&[action]);
        let req = fbs::ArrangeRequest::create(
            &mut b,
            &fbs::ArrangeRequestArgs {
                kind: fbs::RequestKind::Arrange,
                revisions: None,
                actions: Some(actions),
            },
        );
        b.finish(req, None);
        let bytes = b.finished_data().to_vec();
        let err = read_arrange_request(bytes.as_ptr(), bytes.len()).expect_err("absent kind");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
        assert_eq!(err.context.as_deref(), Some("unknown arrange action kind: Unspecified"));

        let bytes = arrange_request(fbs::RequestKind::Rebase, &[]);
        let err = read_arrange_request(bytes.as_ptr(), bytes.len()).expect_err("wrong tag");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
        let bytes = arrange_request(fbs::RequestKind::Arrange, &[]);
        let err = read_rebase_request(bytes.as_ptr(), bytes.len()).expect_err("an arrange buffer");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
    }
}
