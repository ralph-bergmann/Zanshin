// SPDX-License-Identifier: MIT

//! `zanshin_snapshot` — the CLI's `jj util snapshot` (Story 9.26) — plus the one construction
//! site of the `Precondition` / `FinishFacts` tables every envelope of a snapshotting verb
//! carries.
//!
//! The pre-verb snapshot itself lives in `zanshin-jj` (`Repo::precondition`), so MCP inherits it
//! by calling the same verbs; this module only serialises its report. `Envelope.precondition`
//! is written by `envelope.rs::finish_envelope` / `err_with_report`, which call
//! [`build_precondition`] — no payload builder builds it itself.

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{CheckoutStats, FinishFacts, Precondition, StaleRecovery, StaleRecoveryOutcome};

use crate::envelope::{catch, finish_envelope, map_precondition_err, session_from_handle, CallReport};
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
            export_failed_bookmarks: Some(bookmarks),
            export_failed_tags: Some(tags),
        },
    )
}

/// Build the `CheckoutStats` table into `b` and return its offset — shared by `StaleRecovery`
/// and `WorkspaceAddResult` (Story 9.23).
pub(crate) fn build_checkout_stats<'a>(
    b: &mut FlatBufferBuilder<'a>,
    c: &CheckoutStats,
) -> flatbuffers::WIPOffset<fbs::CheckoutStats<'a>> {
    fbs::CheckoutStats::create(
        b,
        &fbs::CheckoutStatsArgs {
            added: c.added,
            updated: c.updated,
            removed: c.removed,
            skipped: c.skipped,
        },
    )
}

/// Build the `StaleRecovery` table into `b` and return its offset — the ONE construction site of
/// `zanshin_workspace_update_stale`'s payload and `Precondition.stale_recovery` (Story 9.23).
/// `commit_id`, `checkout` and `git_head_reset_op_id` are written iff present.
pub(crate) fn build_stale_recovery<'a>(
    b: &mut FlatBufferBuilder<'a>,
    r: &StaleRecovery,
) -> flatbuffers::WIPOffset<fbs::StaleRecovery<'a>> {
    let commit_id = r.commit_id.as_ref().map(|c| b.create_string(&c.0));
    let checkout = r.checkout.as_ref().map(|c| build_checkout_stats(b, c));
    let git_head_reset_op_id = r.git_head_reset_op_id.as_ref().map(|o| b.create_string(&o.0));
    let snapshot_stats = build_snapshot_stats(b, &r.snapshot_stats);
    let op_id = b.create_string(&r.op_id.0);
    fbs::StaleRecovery::create(
        b,
        &fbs::StaleRecoveryArgs {
            outcome: match r.outcome {
                StaleRecoveryOutcome::NotStale => fbs::StaleRecoveryOutcome::NotStale,
                StaleRecoveryOutcome::Updated => fbs::StaleRecoveryOutcome::Updated,
                StaleRecoveryOutcome::Recovered => fbs::StaleRecoveryOutcome::Recovered,
            },
            commit_id,
            checkout,
            git_head_reset_op_id,
            snapshot_stats: Some(snapshot_stats),
            op_id: Some(op_id),
        },
    )
}

/// Build the `Precondition` table into `b` and return its offset. `git_refs`, `finish` and
/// `stale_recovery` are written iff present — null for absence.
pub(crate) fn build_precondition<'a>(
    b: &mut FlatBufferBuilder<'a>,
    p: &Precondition,
) -> flatbuffers::WIPOffset<fbs::Precondition<'a>> {
    let stats = build_snapshot_stats(b, &p.snapshot_stats);
    let git_refs = p.git_refs.as_ref().map(|r| build_git_import_result(b, r));
    let finish = p.finish.as_ref().map(|f| build_finish_facts(b, f));
    let stale_recovery = p.stale_recovery.as_ref().map(|r| build_stale_recovery(b, r));
    fbs::Precondition::create(
        b,
        &fbs::PreconditionArgs {
            was_snapshot_taken: p.was_snapshot_taken,
            snapshot_stats: Some(stats),
            git_head_imported: p.git_head_imported,
            git_head_reset: p.git_head_reset,
            git_head_rebased: p.git_head_rebased,
            snapshot_rebased: p.snapshot_rebased,
            git_refs,
            git_refs_rebased: p.git_refs_rebased,
            finish,
            stale_recovery,
        },
    )
}

/// `zanshin_snapshot`'s success: `ok` with NO `data` and the report as `Envelope.precondition`
/// (there is no `Payload` member for it), plus the call's warnings.
fn snapshot_to_envelope(report: &CallReport) -> Vec<u8> {
    finish_envelope(FlatBufferBuilder::with_capacity(256), fbs::Payload::NONE, None, report)
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
/// error envelope carries the PARTIAL `precondition` up to the failing step. Both carry the
/// call's warnings (Story 9.32).
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.stale_working_copy` — the working copy is stale; `"<cause>\n<working_copy_op_id>\n<repo_op_id>"`
///   in `context`. Nothing is written.
/// - `jj.config_error` — the effective jj config no longer reads, or a value the snapshot reads
///   has the wrong type (the key in `context`). Each is refused where the CLI reads it (Story
///   9.34): the start-up environment (the alias tables, the `immutable_heads()` parse) before the
///   Git import/export lock, writing nothing; the snapshot knobs (`snapshot.auto-track`,
///   `snapshot.max-new-file-size`) after the head import; the Git import options inside the refs
///   step, after the head import and the snapshot; `snapshot.auto-update-stale` only on a stale
///   working copy. Operations committed before the fault stay, as in the CLI; the partial
///   `precondition` says which.
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
        // `Repo::snapshot` hands its report out ITSELF, so the shared `precondition_envelope`
        // tail (which takes it off the repo) does not fit: the report is the ok value here.
        let result = session.repo.snapshot();
        let warnings = session.repo.take_warnings();
        match result {
            Ok(precondition) => Ok(snapshot_to_envelope(&CallReport {
                precondition: Some(precondition),
                warnings,
            })),
            Err(e) => Err(map_precondition_err(e).with_report(CallReport {
                precondition: session.repo.take_precondition(),
                warnings,
            })),
        }
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use crate::envelope::{err_with_report, finish_envelope, CallReport};
    use crate::envelope_generated::zanshin::ffi as fbs;
    use flatbuffers::{FlatBufferBuilder, VerifierOptions};
    use zanshin_jj::{
        ChangeId, FinishFacts, GitExportFailure, GitImportResult, GitRefUpdate, GitRefUpdateKind, MutationResult,
        OperationId, Precondition, SnapshotStats, UntrackedPath, UntrackedReason,
    };

    fn export_failure(name: &str, reason: &str) -> GitExportFailure {
        GitExportFailure {
            name: name.to_owned(),
            remote: "git".to_owned(),
            reason: reason.to_owned(),
        }
    }

    /// A report with a DISTINCT non-default value in every field, so a swapped or dropped
    /// field in [`super::build_precondition`] cannot round-trip unnoticed.
    fn full_precondition() -> Precondition {
        Precondition {
            was_snapshot_taken: true,
            snapshot_stats: SnapshotStats {
                untracked: vec![
                    UntrackedPath {
                        path: "big.bin".to_owned(),
                        reason: UntrackedReason::FileTooLarge { size: 11, max_size: 13 },
                    },
                    UntrackedPath {
                        path: "skip.txt".to_owned(),
                        reason: UntrackedReason::FileNotAutoTracked,
                    },
                ],
                invalid_utf8_paths: vec!["bad\u{fffd}".to_owned()],
            },
            git_head_imported: true,
            git_head_reset: true,
            git_head_rebased: 3,
            snapshot_rebased: 5,
            git_refs: Some(GitImportResult {
                mutation: MutationResult {
                    finish: None,
                    new_op_id: OperationId("op42".to_owned()),
                    new_change_ids: Vec::new(),
                    abandoned_change_ids: Vec::new(),
                    working_copy_change_id: ChangeId("qpvuntsm".to_owned()),
                },
                changed_bookmarks: vec![GitRefUpdate {
                    name: "main".to_owned(),
                    remote: "origin".to_owned(),
                    kind: GitRefUpdateKind::Updated,
                    tracked: true,
                }],
                changed_tags: vec![GitRefUpdate {
                    name: "v1".to_owned(),
                    remote: "git".to_owned(),
                    kind: GitRefUpdateKind::Deleted,
                    tracked: false,
                }],
                abandoned_change_ids: vec![ChangeId("rlvkpnrz".to_owned())],
                num_rewritten: 9,
                failed_ref_names: vec!["refs/remotes/git/x".to_owned()],
            }),
            git_refs_rebased: 7,
            finish: Some(FinishFacts {
                export_failed_bookmarks: vec![export_failure("foo/bar", "r1")],
                export_failed_tags: vec![export_failure("t1", "r2")],
            }),
            stale_recovery: Some(zanshin_jj::StaleRecovery {
                outcome: zanshin_jj::StaleRecoveryOutcome::Updated,
                commit_id: Some(zanshin_jj::CommitId("c0ffee".to_owned())),
                checkout: Some(zanshin_jj::CheckoutStats {
                    added: 2,
                    updated: 4,
                    removed: 6,
                    skipped: 8,
                }),
                git_head_reset_op_id: Some(OperationId("reset".to_owned())),
                snapshot_stats: SnapshotStats::default(),
                op_id: OperationId("head".to_owned()),
            }),
        }
    }

    fn strings<'a>(v: Option<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<&'a str>>>) -> Vec<&'a str> {
        v.expect("vector present").iter().collect()
    }

    fn assert_ref_update(
        u: &fbs::GitRefUpdate<'_>,
        name: &str,
        remote: &str,
        kind: fbs::GitRefUpdateKind,
        tracked: bool,
    ) {
        assert_eq!(
            (u.name(), u.remote(), u.kind(), u.tracked()),
            (Some(name), Some(remote), kind, tracked)
        );
    }

    fn assert_export_failure(f: &fbs::GitExportFailure<'_>, name: &str, reason: &str) {
        assert_eq!(
            (f.name(), f.remote(), f.reason()),
            (Some(name), Some("git"), Some(reason))
        );
    }

    /// Every field of the decoded wire table equals [`full_precondition`]'s.
    fn assert_full_precondition(p: &fbs::Precondition<'_>) {
        assert!(p.was_snapshot_taken());
        assert!(p.git_head_imported());
        assert!(p.git_head_reset());
        assert_eq!(p.git_head_rebased(), 3);
        assert_eq!(p.snapshot_rebased(), 5);
        assert_eq!(p.git_refs_rebased(), 7);

        let stats = p.snapshot_stats().expect("snapshot_stats present");
        let untracked: Vec<_> = stats.untracked().expect("untracked present").iter().collect();
        assert_eq!(untracked.len(), 2);
        assert_eq!(untracked[0].path(), Some("big.bin"));
        let too_large = untracked[0].reason_as_file_too_large().expect("FileTooLarge");
        assert_eq!((too_large.size(), too_large.max_size()), (11, 13));
        assert_eq!(untracked[1].path(), Some("skip.txt"));
        assert!(untracked[1].reason_as_file_not_auto_tracked().is_some());
        assert_eq!(strings(stats.invalid_utf8_paths()), ["bad\u{fffd}"]);

        let refs = p.git_refs().expect("git_refs present");
        let mutation = refs.mutation().expect("mutation present");
        assert_eq!(mutation.new_op_id(), Some("op42"));
        assert_eq!(mutation.working_copy_change_id(), Some("qpvuntsm"));
        let bookmarks: Vec<_> = refs.changed_bookmarks().expect("bookmarks").iter().collect();
        assert_eq!(bookmarks.len(), 1);
        assert_ref_update(&bookmarks[0], "main", "origin", fbs::GitRefUpdateKind::Updated, true);
        let tags: Vec<_> = refs.changed_tags().expect("tags").iter().collect();
        assert_eq!(tags.len(), 1);
        assert_ref_update(&tags[0], "v1", "git", fbs::GitRefUpdateKind::Deleted, false);
        assert_eq!(strings(refs.abandoned_change_ids()), ["rlvkpnrz"]);
        assert_eq!(refs.num_rewritten(), 9);
        assert_eq!(strings(refs.failed_ref_names()), ["refs/remotes/git/x"]);

        let finish = p.finish().expect("finish present");
        let failed_bookmarks: Vec<_> = finish.export_failed_bookmarks().expect("bookmarks").iter().collect();
        assert_eq!(failed_bookmarks.len(), 1);
        assert_export_failure(&failed_bookmarks[0], "foo/bar", "r1");
        let failed_tags: Vec<_> = finish.export_failed_tags().expect("tags").iter().collect();
        assert_eq!(failed_tags.len(), 1);
        assert_export_failure(&failed_tags[0], "t1", "r2");

        let recovery = p.stale_recovery().expect("stale_recovery present");
        assert_eq!(recovery.outcome(), fbs::StaleRecoveryOutcome::Updated);
        assert_eq!(recovery.commit_id(), Some("c0ffee"));
        let checkout = recovery.checkout().expect("checkout present");
        assert_eq!(
            (
                checkout.added(),
                checkout.updated(),
                checkout.removed(),
                checkout.skipped()
            ),
            (2, 4, 6, 8)
        );
        assert_eq!(recovery.git_head_reset_op_id(), Some("reset"));
        assert!(recovery.snapshot_stats().is_some());
        assert_eq!(recovery.op_id(), Some("head"));
    }

    fn envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
        flatbuffers::root_with_opts::<fbs::Envelope>(&VerifierOptions::default(), bytes).expect("verified envelope")
    }

    /// Every `Precondition` field survives the wire, on the ok path AND the error path.
    #[test]
    fn a_full_precondition_round_trips_through_both_envelope_arms() {
        let report = CallReport {
            precondition: Some(full_precondition()),
            warnings: Vec::new(),
        };

        let ok = finish_envelope(FlatBufferBuilder::with_capacity(256), fbs::Payload::NONE, None, &report);
        let env = envelope(&ok);
        assert!(env.ok());
        assert_full_precondition(&env.precondition().expect("ok-arm precondition"));
        assert!(env.warnings().is_none(), "no warnings: absent");

        let err = err_with_report("jj.config_error", Some("k"), Some(&report));
        let env = envelope(&err);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some("jj.config_error"));
        assert_full_precondition(&env.precondition().expect("error-arm precondition"));
    }
}
