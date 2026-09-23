// SPDX-License-Identifier: MIT

//! `zanshin_snapshot` — the CLI's `jj util snapshot` (Story 9.26) — plus the one construction
//! site of the `Precondition` / `FinishFacts` tables every envelope of a snapshotting verb
//! carries.
//!
//! The pre-verb snapshot itself lives in `zanshin-jj` (`Repo::precondition`), so MCP inherits it
//! by calling the same verbs; this module only serialises its report. `Envelope.precondition`
//! is written by `envelope.rs::finish_envelope` / `err_with_precondition`, which call
//! [`build_precondition`] — no payload builder builds it itself.

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{FinishFacts, Precondition};

use crate::envelope::{catch, finish_envelope, map_precondition_err, precondition_envelope, session_from_handle};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::file_ops::build_snapshot_stats;
use crate::git::{build_export_failures, build_git_import_result};

/// Build the `FinishFacts` table into `b` and return its offset — shared by
/// `MutationResult.finish` and `Precondition.finish`.
pub(crate) fn build_finish_facts<'a>(
    b: &mut FlatBufferBuilder<'a>,
    f: &FinishFacts,
) -> flatbuffers::WIPOffset<fbs::FinishFacts<'a>> {
    let bookmarks = build_export_failures(b, &f.export_failed_bookmarks);
    let tags = build_export_failures(b, &f.export_failed_tags);
    fbs::FinishFacts::create(
        b,
        &fbs::FinishFactsArgs {
            working_copy_became_immutable: f.working_copy_became_immutable,
            git_head_update_failed: f.git_head_update_failed,
            export_failed_bookmarks: Some(bookmarks),
            export_failed_tags: Some(tags),
        },
    )
}

/// Build the `Precondition` table into `b` and return its offset. `git_refs` and `finish` are
/// written iff present — null for absence.
pub(crate) fn build_precondition<'a>(
    b: &mut FlatBufferBuilder<'a>,
    p: &Precondition,
) -> flatbuffers::WIPOffset<fbs::Precondition<'a>> {
    let stats = build_snapshot_stats(b, &p.snapshot_stats);
    let git_refs = p.git_refs.as_ref().map(|r| build_git_import_result(b, r));
    let finish = p.finish.as_ref().map(|f| build_finish_facts(b, f));
    fbs::Precondition::create(
        b,
        &fbs::PreconditionArgs {
            was_snapshot_taken: p.was_snapshot_taken,
            snapshot_stats: Some(stats),
            git_head_imported: p.git_head_imported,
            git_head_reset: p.git_head_reset,
            git_head_rebased: p.git_head_rebased,
            snapshot_rebased: p.snapshot_rebased,
            working_copy_immutable_new_commit: p.working_copy_immutable_new_commit,
            git_refs,
            git_refs_rebased: p.git_refs_rebased,
            jjconflict_files_present: p.jjconflict_files_present,
            finish,
        },
    )
}

/// `zanshin_snapshot`'s success: `ok` with NO `data` and the report as `Envelope.precondition`
/// (there is no `Payload` member for it).
fn snapshot_to_envelope(p: &Precondition, _pending: Option<&Precondition>) -> Vec<u8> {
    finish_envelope(FlatBufferBuilder::with_capacity(256), fbs::Payload::NONE, None, Some(p))
}

/// Snapshot the working copy of the repo referenced by `handle` — and, in a colocated
/// workspace, import the Git HEAD and refs — right now: the CLI's `jj util snapshot`
/// (Story 9.26).
///
/// It is exactly the pre-verb snapshot every other handle-scoped wrapper runs first, with
/// nothing after it — for the GUI's "sync now" or a future working-tree trigger; the UI
/// decides when to call it, nothing in Zanshin calls it on its own. A
/// clean tree with unchanged refs writes no operation and reports `was_snapshot_taken = false`.
///
/// Returns an ok `FlatBuffers` `Envelope` with NO `data` and `precondition` set on success; an
/// error envelope carries the PARTIAL `precondition` up to the failing step.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.stale_working_copy` — the working copy is stale; `"<cause>\n<working_copy_op_id>\n<repo_op_id>"`
///   in `context`. Nothing is written.
/// - `jj.config_error` — the effective jj config no longer reads, or a knob the snapshot reads
///   has the wrong type (the key in `context`); refused before the Git import/export lock.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; jj-lib's message in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been
/// closed. `0` is detected and returned as `ffi.invalid_handle`. A stale non-zero handle is
/// undefined behaviour; the Dart worker's Model-A handle table (Story 3.9) makes a stale
/// handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_snapshot(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_snapshot", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.snapshot();
        precondition_envelope(&mut session.repo, result, map_precondition_err, snapshot_to_envelope)
    });
    vec_into_token(buf)
}
