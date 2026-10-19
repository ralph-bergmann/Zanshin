// SPDX-License-Identifier: MIT

//! `stale.rs` — leaving a stale working copy (Story 9.23): the jj CLI's `jj workspace
//! update-stale` and the `snapshot.auto-update-stale = true` arm of its
//! `workspace_helper_with_stats` (`cli/src/cli_util.rs:473-517` @ v0.46.0).
//!
//! Both CLI callers run ONE function, `recover_stale_working_copy_impl` (`:626-766`), under the
//! Git import/export lock — the explicit verb takes it itself (`recover_stale_working_copy`,
//! `:615-624`), the auto arm runs inside the lock the pre-verb snapshot already holds. [`recover`]
//! is that function; [`run`] is the explicit verb's lock-taking wrapper, and
//! [`crate::snapshot::run`] calls [`recover`] for the auto arm. The conversions' implicit snapshot
//! (`maybe_snapshot`, `:1359-1370`) never recovers, so it never calls it.
//!
//! The recovery, step for step:
//!
//! 1. The working copy's OWN operation is loaded. When it exists:
//!    - the working copy is snapshotted on top of it (a `snapshot working copy` operation when
//!      it was dirty — no Git import at this stage);
//!    - the head is loaded the CLI's way ([`snapshot::load_head`]), reconciling the divergent
//!      heads that snapshot may have created (`reconcile divergent operations`, in this
//!      workspace);
//!    - the freshness check against the head's `@`: fresh — nothing to update ("Attempted
//!      recovery, but the working copy is not stale."); stale or a sibling operation — in a
//!      colocated workspace Git HEAD and the index are reset to the new `@` in an operation of
//!      their own (`reset git head`, committed only when it changed anything), then the working
//!      copy is checked out onto the head's `@` and recorded at the head (or the reset)
//!      operation — WITHOUT an operation of its own;
//!    - the full pre-verb snapshot runs again (`snapshot_impl`: Git HEAD, the working copy, Git
//!      refs), and the stats of both snapshots are merged.
//! 2. When the working copy's operation is gone, jj-lib writes a `recovery commit` on top of the
//!    head's `@` holding the files on disk and checks it out, and the full snapshot runs.
//!
//! The CLI's status lines ("Updated working copy to fresh commit …", "Created and checked out
//! recovery commit …", "Concurrent modification detected, resolving automatically.", "Failed to
//! read working copy's current operation; attempting recovery.") are not warnings, so they are
//! no codes: [`StaleRecovery`] carries their facts.

use std::sync::Arc;

use jj_lib::commit::Commit;
use jj_lib::config::StackedConfig;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::{OpStoreError, OperationId as JjOperationId};
use jj_lib::operation::Operation;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::working_copy::{self, LockedWorkingCopy, WorkingCopyFreshness};
use jj_lib::workspace::Workspace;

use crate::mutate::{self, flatten_chain};
use crate::op_support::start_repo_transaction;
use crate::snapshot::{self, backend, CommandEnv, FinishFacts, Precondition, PreconditionError, StepCtx};
use crate::warning::{self, Warnings};
use crate::wc_ops::{self, SnapshotStats};
use crate::{CommitId, OperationId};

/// What a working-copy checkout did to the files on disk — jj-lib's `CheckoutStats`, the counts
/// behind the CLI's `print_checkout_stats` ("Added N files, modified N files, removed N files").
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CheckoutStats {
    /// Files that did not exist before the checkout.
    pub added: u32,
    /// Files that existed before and after the checkout and changed.
    pub updated: u32,
    /// Files the checkout removed.
    pub removed: u32,
    /// Updates skipped because an untracked (probably ignored) file was in the way — the data
    /// behind the call's `jj.checkout_files_skipped` warning.
    pub skipped: u32,
}

impl CheckoutStats {
    /// Projects jj-lib's stats into the owned, `jj_lib`-free shape.
    pub(crate) fn project(stats: &working_copy::CheckoutStats) -> Self {
        Self {
            added: stats.added_files,
            updated: stats.updated_files,
            removed: stats.removed_files,
            skipped: stats.skipped_files,
        }
    }
}

/// Which of the recovery's three arms ran.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StaleRecoveryOutcome {
    /// The working copy was not stale — the CLI's "Attempted recovery, but the working copy is
    /// not stale." Nothing was checked out; a dirty working copy was still snapshotted.
    NotStale,
    /// The working copy was checked out onto the head's `@` — the CLI's "Updated working copy
    /// to fresh commit …".
    Updated,
    /// The working copy's operation was missing, so a recovery commit holding the files on disk
    /// was created on top of `@` and checked out — the CLI's "Created and checked out recovery
    /// commit …".
    Recovered,
}

/// What leaving a stale working copy did (Story 9.23) — the facts the CLI prints while
/// `recover_stale_working_copy_impl` runs, as typed fields.
///
/// [`crate::Repo::workspace_update_stale`] returns it; the auto arm
/// (`snapshot.auto-update-stale = true`) leaves it in [`Precondition::stale_recovery`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StaleRecovery {
    /// Which arm ran.
    pub outcome: StaleRecoveryOutcome,
    /// Full hex id of the commit the recovery checked out: the fresh `@`
    /// ([`StaleRecoveryOutcome::Updated`]), or the recovery commit AS JJ-LIB CREATED IT
    /// ([`StaleRecoveryOutcome::Recovered`]) — the trailing snapshot may since have rewritten it
    /// (same change, new commit id), exactly the commit the CLI's "Created and checked out
    /// recovery commit …" names. `None` when the working copy was not stale.
    pub commit_id: Option<CommitId>,
    /// What the checkout onto the fresh `@` did to the files on disk. `None` unless
    /// [`StaleRecoveryOutcome::Updated`].
    pub checkout: Option<CheckoutStats>,
    /// The `reset git head` operation a colocated workspace wrote before the checkout. `None`
    /// outside colocation, when the working copy was not stale, or when Git HEAD and the index
    /// already matched.
    pub git_head_reset_op_id: Option<OperationId>,
    /// What the recovery's snapshots could not record: the stale working copy's snapshot and
    /// the trailing one, merged (only the trailing one after a recovery commit) — the data behind
    /// the call's `jj.snapshot_files_refused` / `jj.snapshot_paths_not_utf8` warnings.
    pub snapshot_stats: SnapshotStats,
    /// The head operation after the recovery.
    pub op_id: OperationId,
}

/// The recovery commit's description, verbatim from the CLI's
/// `create_and_check_out_recovery_commit` (`cli/src/cli_util.rs:1544-1551` @ v0.46.0).
const RECOVERY_COMMIT_DESCRIPTION: &str = "RECOVERY COMMIT FROM `jj workspace update-stale`

This commit contains changes that were written to the working copy by an
operation that was subsequently lost (or was at least unavailable when you ran
`jj workspace update-stale`). Because the operation was lost, we don't know
what the parent commits are supposed to be. That means that the diff compared
to the current parents may contain changes from multiple commits.
";

/// `jj workspace update-stale`: the CLI's `recover_stale_working_copy` (`cli_util.rs:615-624` @
/// v0.46.0) — takes the Git import/export lock and runs [`recover`] under it. The pre-verb
/// precondition does NOT run: this is the recovery.
///
/// # Errors
///
/// Anything [`recover`] returns, and [`PreconditionError::Backend`] for the lock.
pub(crate) fn run(
    workspace: &mut Workspace,
    config: &StackedConfig,
    env: &CommandEnv,
    colocated: bool,
    report: &mut Precondition,
    sink: &mut Warnings,
) -> Result<(StaleRecovery, working_copy::SnapshotStats), PreconditionError> {
    let lock = snapshot::lock_git_import_export(workspace, colocated)?;
    let ctx = StepCtx {
        config,
        env,
        colocated,
        lock: &lock,
    };
    recover(workspace, &ctx, report, sink)
}

/// Port of `recover_stale_working_copy_impl` (`cli/src/cli_util.rs:626-766` @ v0.46.0) under the
/// held `ctx.lock` — see the module docs for the steps.
///
/// `report` receives the TRAILING snapshot's facts, its `snapshot_stats` replaced by the merged
/// stats and its `finish` merged with what the earlier steps exported; the merged raw stats are
/// returned for the caller's `print_snapshot_stats` warnings.
///
/// # Errors
///
/// - [`PreconditionError::ConcurrentWorkingCopy`] — the working copy's recorded tree is not the
///   stale `@`'s ("Concurrent working copy operation. Try again."); a `reset git head` written
///   before the check stays, as in the CLI.
/// - [`PreconditionError::Config`] — a snapshot knob or Git import option the snapshots read is
///   wrong-typed.
/// - [`PreconditionError::Backend`] — the workspace has no `@`, or any jj-lib failure.
pub(crate) fn recover(
    workspace: &mut Workspace,
    ctx: &StepCtx<'_>,
    report: &mut Precondition,
    sink: &mut Warnings,
) -> Result<(StaleRecovery, working_copy::SnapshotStats), PreconditionError> {
    let op_id = working_copy_operation_id(workspace)?;
    match pollster::block_on(workspace.repo_loader().load_operation(&op_id)) {
        Ok(op) => recover_at(workspace, &op, ctx, report, sink),
        Err(OpStoreError::ObjectNotFound { .. }) => recover_lost(workspace, ctx, report, sink),
        Err(e) => Err(backend(&e)),
    }
}

/// The operation the working copy was last recorded at, read from DISK.
///
/// The CLI loads the workspace per command, so its `working_copy().operation_id()` is what is
/// on disk. A [`crate::Repo`] handle keeps its `Workspace` across calls (ADR-0002), and jj-lib
/// caches the checkout state when it loads the working copy — another process may have recorded
/// the working copy at a different operation since. Taking the working-copy lock re-reads it.
fn working_copy_operation_id(workspace: &mut Workspace) -> Result<JjOperationId, PreconditionError> {
    let mut locked_ws = pollster::block_on(workspace.start_working_copy_mutation()).map_err(|e| backend(&e))?;
    Ok(locked_ws.locked_wc().old_operation_id().clone())
}

/// `@` of `workspace_name` in `repo` — the CLI's `get_wc_commit` / `prepare_working_copy_mutation`
/// ("Nothing checked out in this workspace").
fn wc_commit(repo: &ReadonlyRepo, workspace_name: &WorkspaceName) -> Result<Commit, PreconditionError> {
    let id = repo
        .view()
        .get_wc_commit_id(workspace_name)
        .ok_or_else(|| PreconditionError::Backend("Nothing checked out in this workspace".to_owned()))?;
    repo.store().get_commit(id).map_err(|e| backend(&e))
}

/// The `Ok(op)` arm: the working copy's operation exists.
fn recover_at(
    workspace: &mut Workspace,
    op: &Operation,
    ctx: &StepCtx<'_>,
    report: &mut Precondition,
    sink: &mut Warnings,
) -> Result<(StaleRecovery, working_copy::SnapshotStats), PreconditionError> {
    let workspace_name = workspace.workspace_name().to_owned();
    let workspace_root = workspace.workspace_root().to_owned();
    let wc_repo = pollster::block_on(workspace.repo_loader().load_at(op)).map_err(|e| backend(&e))?;

    // Snapshot on top of the working copy's own operation; the head load below reconciles the
    // divergent heads a dirty snapshot creates.
    let mut facts = FinishFacts::default();
    let mut stale_report = Precondition::default();
    let (stale_repo, stale_stats) =
        snapshot::snapshot_working_copy(workspace, wc_repo, ctx, &mut stale_report, &mut facts, sink)?;
    let stale_wc_commit = wc_commit(&stale_repo, &workspace_name)?;

    let mut repo = snapshot::load_head(workspace)?;
    let desired_wc_commit = wc_commit(&repo, &workspace_name)?;
    let mut locked_ws = pollster::block_on(workspace.start_working_copy_mutation()).map_err(|e| backend(&e))?;
    let freshness = pollster::block_on(WorkingCopyFreshness::check_stale(
        locked_ws.locked_wc(),
        &desired_wc_commit,
        &repo,
    ))
    .map_err(|e| backend(&e))?;
    let mut recovery = StaleRecovery {
        outcome: StaleRecoveryOutcome::NotStale,
        commit_id: None,
        checkout: None,
        git_head_reset_op_id: None,
        snapshot_stats: SnapshotStats::default(),
        op_id: OperationId(String::new()),
    };
    match freshness {
        WorkingCopyFreshness::Fresh | WorkingCopyFreshness::Updated(_) => drop(locked_ws),
        WorkingCopyFreshness::WorkingCopyStale | WorkingCopyFreshness::SiblingOperation => {
            if ctx.colocated {
                let mut tx = start_repo_transaction(&repo, &workspace_name);
                mutate::try_reset_git_head(
                    tx.repo_mut(),
                    &workspace_name,
                    &workspace_root,
                    &desired_wc_commit,
                    sink,
                )?;
                if tx.repo().has_changes() {
                    repo = pollster::block_on(tx.commit("reset git head")).map_err(|e| backend(&e))?;
                    recovery.git_head_reset_op_id = Some(OperationId(repo.op_id().hex()));
                }
            }
            let stats = update_stale_working_copy(locked_ws.locked_wc(), &stale_wc_commit, &desired_wc_commit)?;
            pollster::block_on(locked_ws.finish(repo.op_id().clone())).map_err(|e| backend(&e))?;
            // `print_updated_working_copy_stats` → `print_checkout_stats`.
            sink.extend(warning::checkout_files_skipped(stats.skipped_files));
            recovery.outcome = StaleRecoveryOutcome::Updated;
            recovery.commit_id = Some(CommitId(desired_wc_commit.id().hex()));
            recovery.checkout = Some(CheckoutStats::project(&stats));
        }
    }

    // "There may be Git refs to import, so snapshot again."
    let (repo, fresh_stats) = trailing_snapshot(workspace, repo, ctx, report, facts, sink)?;
    let mut merged = stale_stats;
    merged.untracked_paths.extend(fresh_stats.untracked_paths);
    merged.invalid_utf8_paths.extend(fresh_stats.invalid_utf8_paths);
    report.snapshot_stats = wc_ops::project_stats(&merged);
    recovery.snapshot_stats = report.snapshot_stats.clone();
    recovery.op_id = OperationId(repo.op_id().hex());
    Ok((recovery, merged))
}

/// `update_stale_working_copy` (`cli_util.rs:3081-3107` @ v0.46.0): the same check as
/// `start_working_copy_mutation`, against the STALE `@` — a recorded tree that is not the stale
/// `@`'s means another writer is at work and nothing is checked out — then the checkout onto the
/// head's `@`.
///
/// # Errors
///
/// - [`PreconditionError::ConcurrentWorkingCopy`] — the recorded tree is not `stale_wc_commit`'s.
/// - [`PreconditionError::Backend`] — the checkout failed ("Failed to check out commit …").
fn update_stale_working_copy(
    locked_wc: &mut dyn LockedWorkingCopy,
    stale_wc_commit: &Commit,
    desired_wc_commit: &Commit,
) -> Result<working_copy::CheckoutStats, PreconditionError> {
    if stale_wc_commit.tree().tree_ids_and_labels() != locked_wc.old_tree().tree_ids_and_labels() {
        return Err(PreconditionError::ConcurrentWorkingCopy);
    }
    pollster::block_on(locked_wc.check_out(desired_wc_commit)).map_err(|e| {
        PreconditionError::Backend(format!(
            "Failed to check out commit {}: {}",
            desired_wc_commit.id().hex(),
            flatten_chain(&e)
        ))
    })
}

/// The `ObjectNotFound` arm: `create_and_check_out_recovery_commit` (`cli_util.rs:1531-1566` @
/// v0.46.0) on the head, then the full snapshot.
fn recover_lost(
    workspace: &mut Workspace,
    ctx: &StepCtx<'_>,
    report: &mut Precondition,
    sink: &mut Warnings,
) -> Result<(StaleRecovery, working_copy::SnapshotStats), PreconditionError> {
    let workspace_name = workspace.workspace_name().to_owned();
    let repo = snapshot::load_head(workspace)?;
    let mut locked_ws = pollster::block_on(workspace.start_working_copy_mutation()).map_err(|e| backend(&e))?;
    let (repo, recovery_commit) = pollster::block_on(working_copy::create_and_check_out_recovery_commit(
        locked_ws.locked_wc(),
        &repo,
        workspace_name,
        RECOVERY_COMMIT_DESCRIPTION,
    ))
    .map_err(|e| backend(&e))?;
    pollster::block_on(locked_ws.finish(repo.op_id().clone())).map_err(|e| backend(&e))?;

    let (repo, stats) = trailing_snapshot(workspace, repo, ctx, report, FinishFacts::default(), sink)?;
    let recovery = StaleRecovery {
        outcome: StaleRecoveryOutcome::Recovered,
        commit_id: Some(CommitId(recovery_commit.id().hex())),
        checkout: None,
        git_head_reset_op_id: None,
        snapshot_stats: report.snapshot_stats.clone(),
        op_id: OperationId(repo.op_id().hex()),
    };
    Ok((recovery, stats))
}

/// The recovery's closing `snapshot_impl` into `report`, with [`Precondition::finish`] merged in
/// the order the exports ran: whatever `report` already held (the auto arm's failed attempt),
/// `earlier` (the stale working copy's snapshot), then the trailing snapshot's own — on success
/// and on failure.
fn trailing_snapshot(
    workspace: &mut Workspace,
    repo: Arc<ReadonlyRepo>,
    ctx: &StepCtx<'_>,
    report: &mut Precondition,
    earlier: FinishFacts,
    sink: &mut Warnings,
) -> Result<(Arc<ReadonlyRepo>, working_copy::SnapshotStats), PreconditionError> {
    let mut finish = report.finish.take().unwrap_or_default();
    finish.merge(earlier);
    let result = snapshot::snapshot_locked(workspace, repo, ctx, report, sink);
    if let Some(trailing) = report.finish.take() {
        finish.merge(trailing);
    }
    report.finish = finish.into_option();
    result
}

#[cfg(test)]
mod tests {
    use super::{CheckoutStats, RECOVERY_COMMIT_DESCRIPTION};

    #[test]
    fn checkout_stats_keep_jj_libs_counts() {
        let stats = jj_lib::working_copy::CheckoutStats {
            updated_files: 1,
            added_files: 2,
            removed_files: 3,
            skipped_files: 4,
        };
        assert_eq!(
            CheckoutStats::project(&stats),
            CheckoutStats {
                added: 2,
                updated: 1,
                removed: 3,
                skipped: 4,
            }
        );
    }

    /// The update-stale checkout refuses when the working copy's recorded tree is not the stale
    /// `@`'s — the CLI's "Concurrent working copy operation. Try again." — and checks nothing
    /// out. Inside the recovery only a concurrent writer between its snapshot and its lock can
    /// cause it, so the step is exercised directly: the recorded tree is the initial empty one,
    /// the "stale" `@` passed in is a rewrite holding a file.
    #[test]
    fn a_recorded_tree_other_than_the_stale_ats_is_a_concurrent_working_copy() {
        use jj_lib::object_id::ObjectId as _;
        use jj_lib::repo::Repo as _;

        test_helpers::pin_test_env();
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let mut repo = crate::Repo::init(tmp.path(), None).result.expect("init");
        let load_head =
            |repo: &crate::Repo| pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("head");
        let name = repo.workspace().workspace_name().to_owned();
        let at = load_head(&repo).view().get_wc_commit_id(&name).expect("@").hex();
        let _ = test_helpers::rewrite_commit_files(repo.workspace_root(), &at, &[("elsewhere.txt", "x")]);
        let head = load_head(&repo);
        let rewritten = head
            .store()
            .get_commit(head.view().get_wc_commit_id(&name).expect("@"))
            .expect("commit");

        let mut locked_ws =
            pollster::block_on(repo.workspace_mut().start_working_copy_mutation()).expect("lock the working copy");
        let result = super::update_stale_working_copy(locked_ws.locked_wc(), &rewritten, &rewritten);
        assert!(matches!(result, Err(crate::PreconditionError::ConcurrentWorkingCopy)));
        drop(locked_ws);
        assert!(
            !repo.workspace_root().join("elsewhere.txt").exists(),
            "nothing checked out"
        );
    }

    #[test]
    fn the_recovery_description_is_the_clis() {
        assert!(RECOVERY_COMMIT_DESCRIPTION.starts_with("RECOVERY COMMIT FROM `jj workspace update-stale`\n\n"));
        assert!(RECOVERY_COMMIT_DESCRIPTION.ends_with("may contain changes from multiple commits.\n"));
    }
}
