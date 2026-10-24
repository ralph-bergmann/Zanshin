// SPDX-License-Identifier: MIT

//! `zanshin_move_working_copy` / `zanshin_movement_targets` — the CLI's `jj next` and `jj prev`
//! (Story 9.10).
//!
//! Both call the matching `zanshin_jj::Repo` method and serialise its result into a `FlatBuffers`
//! `Envelope`: the shared `MutationResult` for the move, a `MovementTargets` for the targets call.
//! The arguments cross as a `MovementRequest` request BUFFER (ADR-0001 composite-input pattern).
//! The handle is borrowed, never consumed. Every call runs the pre-verb snapshot (Story 9.26)
//! unless clap's rules refuse it first, so the envelope carries the precondition report and the
//! call's warnings.

use flatbuffers::VerifierOptions;
use tracing::debug;
use zanshin_jj::{CommitId, Direction, MovementOptions};

use crate::envelope::{
    catch, expect_request_kind, invalid_request, ok_movement_targets, ok_mutation_result, precondition_envelope,
    reject_null_request, session_from_handle, FfiErrorObj, FFI_INVALID_ARGUMENT,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

/// Parse a `MovementRequest` buffer into owned [`MovementOptions`]: an ABSENT `offset` is the
/// CLI's default (`None`), an ABSENT `target` is no choice.
///
/// `data`/`len` describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for
/// the call only and returns OWNED values.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `MovementRequest` buffer, its `kind` is
///   not `Movement`, or its `direction` is outside the enum.
fn read_movement_request(data: *const u8, len: usize) -> Result<MovementOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the doc comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::MovementRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Movement)?;
    let direction = match req.direction() {
        fbs::MovementDirection::Next => Direction::Next,
        fbs::MovementDirection::Prev => Direction::Prev,
        other => {
            return Err(FfiErrorObj {
                report: None,
                hints: Vec::new(),
                code: FFI_INVALID_ARGUMENT.to_owned(),
                context: Some(format!("invalid movement direction: {other:?}")),
            })
        }
    };
    Ok(MovementOptions {
        direction,
        offset: req.offset().map(fbs::MovementOffset::value),
        edit: req.edit(),
        no_edit: req.no_edit(),
        conflict: req.conflict(),
        target: req.target().map(|id| CommitId(id.to_owned())),
    })
}

/// Move the working copy to a child or parent in the repo identified by `handle` — the CLI's `jj
/// next` / `jj prev` (Story 9.10).
///
/// The arguments cross as a `MovementRequest` `FlatBuffers` request buffer: `direction` (`Next` /
/// `Prev`), `offset` (ABSENT = the CLI's `1`), `edit` / `no_edit` (against `ui.movement.edit`),
/// `conflict` (the nearest conflicted descendant / ancestor) and `target` — the hex commit id
/// chosen among `zanshin_movement_targets`' candidates where the CLI would prompt. Without
/// editing, a new empty `@` is created on the target (`@` must be a head); editing makes the
/// target `@` (it must be rewritable). The operation is the CLI's `next: <@> -> <target>` /
/// `next: <@> -> editing <target>` (`prev: …` likewise, 12-hex ids); a move that changes nothing
/// writes NO operation and `MutationResult.new_op_id` carries the PRE-CALL head. The working copy
/// is snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `MovementRequest` buffer, its `kind` is
///   not `Movement`, or its `direction` is outside the enum.
/// - `jj.invalid_input` — clap's refusals, before the snapshot (nothing written, no
///   `precondition`): `edit` with `no_edit`, a present `offset` with `conflict`. Then `@` has
///   children and the move does not edit ("The working copy must not have any children", one
///   hint); an offset jj-lib cannot evaluate ("Lower bound of generation (<n>) is too large");
///   no target (the CLI's not-found text, one `Working copy: …` / `Working copy parent: …` hint
///   per start commit); several candidates and no `target` ("ambiguous next commit, choose one to
///   target"). Detail in `context`, hints in `hints`.
/// - `jj.stale_selection` — `target` is not a current candidate; nothing written.
/// - `jj.no_working_copy` — the workspace has no working-copy commit.
/// - `jj.immutable` — (editing) the target is immutable (the root commit included); its hex
///   commit id in `context`.
/// - `jj.config_error` — `ui.movement.edit` is not a boolean, the commit-summary template (the
///   hints) does not parse, or the `immutable_heads()` alias does not resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.MovementRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_move_working_copy(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_move_working_copy", handle);
    let buf = catch(|| {
        let options = read_movement_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.move_working_copy(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// List the targets `zanshin_move_working_copy` chooses from, in the repo identified by `handle`
/// (Story 9.10): the move with the same `MovementRequest`, run up to where the CLI picks its
/// target or prompts for one. `target` is ignored.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MovementTargets` payload on success: `edit` (the
/// move edits its target) and the candidates in the CLI's prompt order — never empty; more than
/// one is where the CLI prompts, and each `commit_id` is what `MovementRequest.target` takes; no
/// rewritability guard runs here, so (editing) an immutable candidate is listed and still refuses
/// `jj.immutable` at the move. Writes NO operation of its own, only the pre-verb snapshot's.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `MovementRequest` buffer, its `kind` is
///   not `Movement`, or its `direction` is outside the enum.
/// - `jj.invalid_input` — as `zanshin_move_working_copy` up to choosing a target: clap's two
///   refusals before the snapshot, children of a non-edit `@`, an offset jj-lib cannot evaluate,
///   no target (with its hints).
/// - `jj.no_working_copy` — the workspace has no working-copy commit.
/// - `jj.config_error` — `ui.movement.edit` is not a boolean, or the commit-summary template (the
///   hints) does not parse.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// As `zanshin_move_working_copy`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_movement_targets(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_movement_targets", handle);
    let buf = catch(|| {
        let options = read_movement_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.movement_targets(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_movement_targets)
    });
    vec_into_token(buf)
}
