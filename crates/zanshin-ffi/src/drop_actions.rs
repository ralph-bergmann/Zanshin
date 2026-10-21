// SPDX-License-Identifier: MIT

//! `zanshin_drop_actions` / `zanshin_change_actions` — the drop-action capability query and the
//! card menu's verbs for one change (Story 9.31).
//!
//! Each calls the matching `zanshin_jj::Repo` query and serialises the answer into a `FlatBuffers`
//! `Envelope`. `zanshin_drop_actions` takes a `DropActionsRequest` request BUFFER (ADR-0001
//! composite-input pattern); `zanshin_change_actions` takes the change id as a lone C string, like
//! `zanshin_edit`. The handle is borrowed, never consumed. Both run the pre-verb snapshot (Story
//! 9.26), so every envelope carries the precondition report and the call's warnings — the
//! precondition's only: the rows' plan warnings are discarded.
//!
//! A row's refusal crosses as an `FfiError` mapped through `map_mutate_err`, the mapping the
//! verb's own wrapper uses: preview and execution report the same code and `context`.

use core::ffi::c_char;

use flatbuffers::{ForwardsUOffset, Vector, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ChangeId, DropLocation, DropSource};

use crate::envelope::{
    catch, expect_request_kind, invalid_request, missing_field, ok_change_actions, ok_drop_actions,
    precondition_envelope, reject_null_request, session_from_handle, ChangeActionsObj, DropActionsObj, FfiErrorObj,
    FFI_INVALID_ARGUMENT,
};
use crate::fbs;
use crate::ffi_strings::{cstr_to_string, vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

/// A string vector as change ids; ABSENT is empty — the flag not given.
fn change_ids(v: Option<Vector<'_, ForwardsUOffset<&str>>>) -> Vec<ChangeId> {
    v.map(|v| v.iter().map(|s| ChangeId(s.to_owned())).collect())
        .unwrap_or_default()
}

/// Parse a `DropActionsRequest` buffer into the owned source and locations. Same discipline as
/// `squash_split.rs`'s readers: the caller-owned buffer is borrowed for the call only, and the
/// reader returns owned values.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `DropActionsRequest` buffer, its `kind`
///   is not `DropActions`, or its `source_kind` is not a known `DropSourceKind`.
/// - `jj.invalid_input` — the field the `source_kind` needs (`change_id` or `bookmark`) is absent:
///   "<field> is required".
fn read_drop_actions_request(data: *const u8, len: usize) -> Result<(DropSource, Vec<DropLocation>), FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the function comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::DropActionsRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::DropActions)?;
    let change = || {
        req.change_id()
            .map(|s| ChangeId(s.to_owned()))
            .ok_or_else(|| missing_field("change_id"))
    };
    let source = match req.source_kind() {
        fbs::DropSourceKind::Change => DropSource::Change(change()?),
        fbs::DropSourceKind::Selection => DropSource::Selection {
            change: change()?,
            paths: req
                .paths()
                .map(|v| v.iter().map(ToOwned::to_owned).collect())
                .unwrap_or_default(),
        },
        fbs::DropSourceKind::Bookmark => {
            DropSource::Bookmark(req.bookmark().ok_or_else(|| missing_field("bookmark"))?.to_owned())
        }
        other => {
            return Err(FfiErrorObj {
                report: None,
                code: FFI_INVALID_ARGUMENT.to_owned(),
                context: Some(format!("unknown drop source kind: {other:?}")),
            })
        }
    };
    let locations = req
        .locations()
        .map(|v| {
            v.iter()
                .map(|l| DropLocation {
                    onto: change_ids(l.onto()),
                    insert_after: change_ids(l.insert_after()),
                    insert_before: change_ids(l.insert_before()),
                })
                .collect()
        })
        .unwrap_or_default();
    Ok((source, locations))
}

/// Preview which verbs a dragged change, path selection or bookmark can run at each drop location,
/// in the repo identified by `handle` (Story 9.31) — before anything runs, with each verb's own
/// refusal.
///
/// The arguments cross as a `DropActionsRequest` `FlatBuffers` request buffer: the source
/// (`source_kind` with `change_id`, `paths` or `bookmark`) and the `locations` (each the CLI's
/// `-o` / `-A` / `-B`). The rows per location, in order: a `Change` at `onto` — `RebaseSource`,
/// `RebaseRevisions`, `Squash` (only for exactly one target), `NewMerge`, `Duplicate`; at `-A`/`-B`
/// — `RebaseRevisions`. A `Selection` at `onto` with one target — `Squash` with the paths; at
/// `-A`/`-B` — `Split`. A `Bookmark` at `onto` with one target — `BookmarkMove`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `DropActions` payload on success: each row's
/// verb, location index, status (`Available`, `NoOp` — the verb would write no operation — or
/// `Refused`), the refusal as the `FfiError` the verb's own wrapper returns, and the two flags
/// (`combined_description_needed`, `allow_backwards_needed`). An id that does not resolve refuses
/// every row it affects with `jj.change_not_found`. Writes NO operation of its own, only the
/// pre-verb snapshot's.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `DropActionsRequest` buffer, its `kind`
///   is not `DropActions`, or its `source_kind` is unknown.
/// - `jj.invalid_input` — the `change_id` / `bookmark` the source kind needs is absent; or a
///   location gives `onto` together with `insert_after`/`insert_before` ("--onto cannot be
///   combined with -A/--insert-after or -B/--insert-before") or none of the three ("expected at
///   least one of --onto, -A/--insert-after or -B/--insert-before"), checked before anything
///   resolves; detail in `context`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.config_error` — the pre-verb snapshot could not read the config (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure, a row's included; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.DropActionsRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_drop_actions(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_drop_actions", handle);
    let buf = catch(|| {
        let (source, locations) = read_drop_actions_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.drop_actions(&source, &locations).map(DropActionsObj::from);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_drop_actions)
    });
    vec_into_token(buf)
}

/// Preview the card menu's verbs for `change_id`, in the repo identified by `handle` (Story
/// 9.31): `new` onto it, `new -A` / `new -B` it, `edit`, `describe`, `squash -r` (into its parent,
/// with `combined_description_needed`) and `abandon` — each answered by the verb's own plan, its
/// refusal the `FfiError` the verb's wrapper returns.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `ChangeActions` payload on success; every one of
/// its seven outcomes is present. An id that does not resolve refuses every row with
/// `jj.change_not_found`. Writes NO operation of its own, only the pre-verb snapshot's.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `change_id` is a null pointer.
/// - `ffi.utf8_error` — `change_id` is not valid UTF-8.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.config_error` — the pre-verb snapshot could not read the config (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure, a row's included; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `change_id` must be a NUL-terminated UTF-8 C string owned by the caller (Dart allocates via
/// `toNativeUtf8()` and frees with `calloc.free()` after this call returns — AR-P-5 inbound rule).
/// Rust only borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_change_actions(handle: u64, change_id: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_change_actions", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        // SAFETY: change_id is a caller-owned NUL-terminated C string (Dart allocates + frees).
        let id = unsafe { cstr_to_string(change_id) }?;
        let result = session.repo.change_actions(&ChangeId(id)).map(ChangeActionsObj::from);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_change_actions)
    });
    vec_into_token(buf)
}
