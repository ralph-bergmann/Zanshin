// SPDX-License-Identifier: MIT

//! `snapshot.rs` — the implicit working-copy snapshot and colocated Git import the jj CLI runs
//! in front of almost every command (Story 9.26, reversing project decision D2).
//!
//! Every CLI command that goes through `workspace_helper` / `workspace_helper_with_stats`
//! (`cli/src/cli_util.rs:472-516` @ v0.44.0) first takes the `git_import_export.lock`, loads the
//! head, and runs `snapshot_impl` (`:1298-1326`): in a colocated workspace `import git head`,
//! then `snapshot working copy`, then `import git refs`; in any other workspace the snapshot
//! alone. [`crate::Repo`] runs the same sequence as the precondition of every verb whose CLI
//! counterpart does, so the op log a CLI user sees after a Zanshin session is the one the CLI
//! itself would have written — and a `git commit`, a `git checkout` or a plain file edit made
//! outside Zanshin is picked up by the very next verb, exactly as by the next `jj` command.
//!
//! Each step is a port of its CLI namesake, minus the terminal output; every fact the CLI would
//! have printed rides [`Precondition`] instead. The ports operate on a `&mut Workspace`, a loaded
//! `Arc<ReadonlyRepo>` and [`Knobs`] read from the effective config, so the verb precondition
//! and the conversion verbs (`do_init`'s `maybe_snapshot` point) share one implementation.

use std::sync::Arc;

use jj_lib::commit::Commit;
use jj_lib::config::StackedConfig;
use jj_lib::git::{self, GitImportOptions};
use jj_lib::gitignore::GitIgnoreFile;
use jj_lib::lock::FileLock;
use jj_lib::matchers::{Matcher, NothingMatcher};
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::OpStoreError;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::revset::{RevsetExpression, UserRevsetExpression};
use jj_lib::rewrite::RebaseOptions;
use jj_lib::working_copy::{self, LockedWorkingCopy, SnapshotOptions, WorkingCopyFreshness};
use jj_lib::workspace::Workspace;

use crate::git::GitExportFailure;
use crate::mutate::{self, flatten_chain, MutateError};
use crate::op_support::start_repo_transaction;
use crate::wc_ops::{self, SnapshotStats};
use crate::GitImportResult;

// ── Public report and error types ─────────────────────────────────────────────────

/// What the implicit pre-verb snapshot did (Story 9.26) — the facts the CLI prints while
/// `workspace_helper` runs, as typed fields.
///
/// Every verb that runs the precondition leaves one behind; [`crate::Repo::take_precondition`]
/// hands it out, and [`crate::Repo::snapshot`] returns it directly. On a failed precondition it
/// is PARTIAL: every field up to the failing step is filled, the rest keep their defaults.
#[derive(Debug, Default)]
// WHY: each bool is an INDEPENDENT fact the CLI reports on its own line (any combination can
// occur in one run), mirrored field for field by the wire table `Precondition` — not a state a
// two-variant enum or a state machine could encode.
#[allow(clippy::struct_excessive_bools)]
pub struct Precondition {
    /// Whether the head operation changed during the precondition — an operation was written,
    /// or the repo was reloaded at a newer working-copy operation. `jj util snapshot`'s own
    /// `was_snapshot_taken` (`cli/src/commands/util/snapshot.rs` @ v0.44.0).
    pub was_snapshot_taken: bool,
    /// What the snapshot could not record — the CLI's `print_snapshot_stats` warnings.
    pub snapshot_stats: SnapshotStats,
    /// Whether an `import git head` operation was written (colocated workspaces only).
    pub git_head_imported: bool,
    /// The CLI's "Reset the working copy parent to the new Git HEAD." — the head import moved
    /// `@` onto a new Git HEAD while a previous one existed.
    pub git_head_reset: bool,
    /// Descendants rebased by the head import (CLI: "Rebased {n} descendant commits.").
    /// Saturates at `u32::MAX`.
    pub git_head_rebased: u32,
    /// Descendants rebased onto the snapshotted `@` (CLI: "Rebased {n} descendant commits onto
    /// updated working copy."). Saturates at `u32::MAX`.
    pub snapshot_rebased: u32,
    /// The CLI's "The working-copy commit is immutable; a new commit has been created on top of
    /// it." — the snapshot found `@` inside the immutable set and created a new `@` on top
    /// instead of rewriting it.
    pub working_copy_immutable_new_commit: bool,
    /// The `import git refs` step's outcome, in [`crate::Repo::git_import`]'s shape. `Some`
    /// exactly when the step RAN (colocated workspaces) while this workspace has an `@` — even
    /// when it changed nothing, so refs that could not be imported still ride
    /// [`GitImportResult::failed_ref_names`]. `None` outside colocation and when `@` is absent
    /// from the view (the projection names `@`; the import itself still ran).
    pub git_refs: Option<GitImportResult>,
    /// Descendants rebased off commits the refs import rewrote (CLI: "Rebased {n} descendant
    /// commits off of commits rewritten from Git."). Saturates at `u32::MAX`.
    pub git_refs_rebased: u32,
    /// The CLI's colocated `.jjconflict` warning: the snapshotted tree has a top-level entry
    /// whose name starts with `.jjconflict` — typically a plain `git checkout` of a conflicted
    /// commit. The snapshot proceeds regardless.
    pub jjconflict_files_present: bool,
    /// The Git HEAD resets and ref exports that ran inside the precondition, merged. `None`
    /// when every fact is at its default.
    pub finish: Option<FinishFacts>,
}

/// Facts from the colocated Git bookkeeping the CLI runs when it finishes a transaction
/// (`finish_transaction`, `cli/src/cli_util.rs:2300-2417` @ v0.44.0) — warnings there, never
/// errors (Story 9.26).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FinishFacts {
    /// The CLI's "The working-copy commit became immutable; a new commit has been created on
    /// top of it." — the transaction left `@` inside the immutable set, so a new, empty `@` was
    /// created on top of it.
    pub working_copy_became_immutable: bool,
    /// Git HEAD could not be moved to `@`'s parent (jj-lib's `GitResetHeadError::UpdateHeadRef`,
    /// e.g. a concurrent `git checkout`). The CLI warns and the next snapshot imports the
    /// actual HEAD.
    pub git_head_update_failed: bool,
    /// Bookmarks the colocated export could not write to Git.
    pub export_failed_bookmarks: Vec<GitExportFailure>,
    /// Tags the colocated export could not write to Git.
    pub export_failed_tags: Vec<GitExportFailure>,
}

impl FinishFacts {
    /// `Some(self)` unless every fact is at its default — the null-for-absence rule the wire
    /// form follows.
    pub(crate) fn into_option(self) -> Option<Self> {
        (self != Self::default()).then_some(self)
    }

    /// Folds `other` into `self`: flags OR together, failure lists concatenate.
    pub(crate) fn merge(&mut self, other: Self) {
        self.working_copy_became_immutable |= other.working_copy_became_immutable;
        self.git_head_update_failed |= other.git_head_update_failed;
        self.export_failed_bookmarks.extend(other.export_failed_bookmarks);
        self.export_failed_tags.extend(other.export_failed_tags);
    }
}

/// Why the working copy is stale — the three refusals of the CLI's `handle_stale_working_copy`
/// (`cli/src/cli_util.rs:2952-3020` @ v0.44.0).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StaleCause {
    /// The working copy was not updated since an operation that rewrote `@` ("The working copy
    /// is stale (not updated since operation …)").
    Stale,
    /// The repo was loaded at an operation that is a SIBLING of the working copy's ("… seems to
    /// be a sibling of the working copy's operation …").
    SiblingOperation,
    /// The working copy's recorded operation does not exist ("Could not read working copy's
    /// operation.").
    OperationNotFound,
}

impl StaleCause {
    /// The stable token for this cause: `stale`, `sibling_operation` or `operation_not_found`.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stale => "stale",
            Self::SiblingOperation => "sibling_operation",
            Self::OperationNotFound => "operation_not_found",
        }
    }
}

impl std::fmt::Display for StaleCause {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Why the pre-verb snapshot failed (Story 9.26). No operation beyond the ones the partial
/// [`Precondition`] reports was written.
#[derive(Debug, thiserror::Error)]
pub enum PreconditionError {
    /// The working copy is stale — see [`StaleCause`]. Nothing is snapshotted or written; the
    /// CLI's remedy is `jj workspace update-stale` (or `snapshot.auto-update-stale = true`).
    #[error("stale working copy ({cause}): working copy at operation {working_copy_op_id}, repo at {repo_op_id}")]
    StaleWorkingCopy {
        /// Which of the CLI's three refusals applies.
        cause: StaleCause,
        /// Full hex id of the operation the working copy was last updated at.
        working_copy_op_id: String,
        /// Full hex id of the operation the repo was loaded at.
        repo_op_id: String,
    },
    /// The effective config could not be read, or a knob the snapshot reads has the wrong type
    /// (the key is named). Refused before the Git import/export lock is taken.
    #[error("config error: {reason}")]
    Config {
        /// Human-readable failure, naming the file or the config key.
        reason: String,
    },
    /// An underlying jj-lib failure — jj-lib's message, its source chain included.
    #[error("jj-lib error: {0}")]
    Backend(String),
}

impl From<MutateError> for PreconditionError {
    fn from(e: MutateError) -> Self {
        match e {
            MutateError::Config { reason } => Self::Config { reason },
            MutateError::Precondition(inner) => inner,
            MutateError::Backend(reason) => Self::Backend(reason),
            other => Self::Backend(other.to_string()),
        }
    }
}

impl From<crate::ConfigError> for PreconditionError {
    fn from(e: crate::ConfigError) -> Self {
        let crate::ConfigError::Load { reason } = e;
        Self::Config { reason }
    }
}

/// A jj-lib failure with its whole source chain, the way the CLI prints it.
fn backend(e: &(dyn std::error::Error + 'static)) -> PreconditionError {
    PreconditionError::Backend(flatten_chain(e))
}

/// Saturating `usize` → `u32`, like every other rebased count in this crate.
fn saturate(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

// ── The Git import/export lock ────────────────────────────────────────────────────

/// Proof that `<repo_path>/git_import_export.lock` is held — the CLI's `GitImportExportLock`
/// (`cli/src/cli_util.rs:981-996` @ v0.44.0). Empty (`None`) outside a colocated workspace,
/// where the CLI takes no lock either. Dropping it releases the lock.
pub(crate) struct GitImportExportLock {
    _lock: Option<FileLock>,
}

/// Takes the Git import/export lock for a colocated workspace, BLOCKING until it is free
/// (`FileLock::lock`) — a concurrent CLI holding it is waited for, never reported as busy.
///
/// It is jj's own lock, taken exactly where the CLI takes it, so a Zanshin HEAD/ref
/// import-export and a CLI one never interleave.
///
/// # Errors
///
/// - [`MutateError::Backend`] — the lock file could not be created or locked.
pub(crate) fn lock_git_import_export(
    workspace: &Workspace,
    colocated: bool,
) -> Result<GitImportExportLock, MutateError> {
    let lock = if colocated {
        let lock_path = workspace.repo_path().join("git_import_export.lock");
        Some(FileLock::lock(lock_path).map_err(|e| {
            MutateError::Backend(format!(
                "Failed to take lock for Git import/export: {}",
                flatten_chain(&e)
            ))
        })?)
    } else {
        None
    };
    Ok(GitImportExportLock { _lock: lock })
}

// ── Knobs ────────────────────────────────────────────────────────────────────────

/// Every config value the snapshot path reads, read and type-checked up front — BEFORE the
/// lock, so a wrong-typed knob refuses without waiting for a concurrent holder.
///
/// Only the knobs the CLI's `snapshot_impl` itself reads are here: the Git import options only
/// in a colocated workspace (the CLI reads them in `import_git_refs`, which runs only there), and
/// `snapshot.auto-update-stale` not at all — the CLI reads it only on a stale working copy
/// (`cli_util.rs:499` @ v0.44.0), so [`crate::Repo`] does the same on that error path.
pub(crate) struct Knobs {
    auto_tracking: Box<dyn Matcher>,
    max_new_file_size: u64,
    base_ignores: Arc<GitIgnoreFile>,
    /// The refs import options — `git.*` plus `remotes.<name>.auto-track-bookmarks`. `Some`
    /// exactly in a colocated workspace, and it is what gates the `import git refs` step.
    import_options: Option<GitImportOptions>,
    /// `::(immutable_heads() | root())` as the effective config defines it.
    pub(crate) immutable: Arc<UserRevsetExpression>,
}

impl Knobs {
    /// Reads every knob off `config` for `workspace`; the import options only when `colocated`.
    ///
    /// # Errors
    ///
    /// - [`PreconditionError::Config`] — a knob has the wrong type, `snapshot.auto-track` or (in
    ///   a colocated workspace) a `remotes.<name>.auto-track-bookmarks` does not parse, or the
    ///   `immutable_heads()` alias does not parse.
    /// - [`PreconditionError::Backend`] — an ignore file could not be read.
    pub(crate) fn read(
        workspace: &Workspace,
        config: &StackedConfig,
        colocated: bool,
    ) -> Result<Self, PreconditionError> {
        let auto_tracking = wc_ops::auto_tracking_matcher(config)?;
        let max_new_file_size = crate::config::snapshot_max_new_file_size(config)?;
        let base_ignores = wc_ops::base_ignores(workspace)?;
        let import_options = colocated
            .then(|| crate::config::git_import_options(config))
            .transpose()?;
        let immutable = crate::op_support::immutable_user_expression(workspace, config)?;
        Ok(Self {
            auto_tracking,
            max_new_file_size,
            base_ignores,
            import_options,
            immutable,
        })
    }

    /// The CLI's `snapshot_options_with_start_tracking_matcher` over the auto-track matcher.
    fn snapshot_options(&self) -> SnapshotOptions<'_> {
        SnapshotOptions {
            base_ignores: Arc::clone(&self.base_ignores),
            progress: None,
            start_tracking_matcher: self.auto_tracking.as_ref(),
            force_tracking_matcher: &NothingMatcher,
            max_new_file_size: self.max_new_file_size,
        }
    }
}

/// What a verb carries out of a successful precondition: the effective config it was read
/// from, the knobs a verb reuses rather than re-reading, and the pre-verb snapshot's raw stats.
pub(crate) struct VerbContext {
    /// The effective config stack the precondition read.
    pub(crate) config: StackedConfig,
    /// `::(immutable_heads() | root())` as that config defines it.
    pub(crate) immutable: Arc<UserRevsetExpression>,
    /// Whether the working copy is shared with a Git work tree.
    pub(crate) colocated: bool,
    /// jj-lib's own stats of the pre-verb snapshot — `file track` merges them into its own.
    pub(crate) auto_stats: working_copy::SnapshotStats,
}

impl VerbContext {
    /// Assembles the context from the knobs the precondition consumed.
    pub(crate) fn new(
        config: StackedConfig,
        knobs: Knobs,
        colocated: bool,
        auto_stats: working_copy::SnapshotStats,
    ) -> Self {
        Self {
            config,
            immutable: knobs.immutable,
            colocated,
            auto_stats,
        }
    }
}

// ── The precondition ─────────────────────────────────────────────────────────────

/// Takes the lock, loads the head and runs [`snapshot_impl`] — the body of the CLI's
/// `workspace_helper_with_stats` after its knobs are known.
///
/// Fills `report` as it goes, so a failure leaves the partial facts behind. Returns jj-lib's
/// raw snapshot stats, which `file track` merges into its own (`print_track_snapshot_stats`).
/// The lock is released on return.
///
/// # Errors
///
/// Anything [`snapshot_impl`] returns, and [`PreconditionError::Backend`] for the lock or the
/// head load.
pub(crate) fn run(
    workspace: &mut Workspace,
    knobs: &Knobs,
    colocated: bool,
    report: &mut Precondition,
) -> Result<working_copy::SnapshotStats, PreconditionError> {
    let lock = lock_git_import_export(workspace, colocated)?;
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(|e| backend(&e))?;
    let loaded_op_id = repo.op_id().clone();
    match snapshot_impl(workspace, repo, knobs, colocated, &lock, report) {
        Ok((repo, stats)) => {
            report.was_snapshot_taken = repo.op_id() != &loaded_op_id;
            Ok(stats)
        }
        Err(e) => {
            // A later step failed after an earlier one may have committed (e.g. `import git
            // head`, then a snapshot jj-lib refuses): the partial report says so. A head that
            // no longer loads leaves the flag at its default.
            if let Ok(head) = pollster::block_on(workspace.repo_loader().load_at_head()) {
                report.was_snapshot_taken = head.op_id() != &loaded_op_id;
            }
            Err(e)
        }
    }
}

/// Port of `snapshot_impl` (`cli/src/cli_util.rs:1298-1326` @ v0.44.0): colocated → import the
/// Git HEAD, then snapshot, then import the Git refs; otherwise the snapshot alone.
///
/// `_lock` must be the held [`GitImportExportLock`]; every step runs under it.
///
/// # Errors
///
/// - [`PreconditionError::StaleWorkingCopy`] — see [`StaleCause`].
/// - [`PreconditionError::Config`] — the immutable set could not be resolved.
/// - [`PreconditionError::Backend`] — any underlying jj-lib failure.
pub(crate) fn snapshot_impl(
    workspace: &mut Workspace,
    repo: Arc<ReadonlyRepo>,
    knobs: &Knobs,
    colocated: bool,
    lock: &GitImportExportLock,
    report: &mut Precondition,
) -> Result<(Arc<ReadonlyRepo>, working_copy::SnapshotStats), PreconditionError> {
    let mut facts = FinishFacts::default();
    let result = snapshot_steps(workspace, repo, knobs, colocated, lock, report, &mut facts);
    report.finish = facts.into_option();
    result
}

/// The three steps, with the finish facts collected separately so [`snapshot_impl`] can record
/// them on the error path too.
fn snapshot_steps(
    workspace: &mut Workspace,
    repo: Arc<ReadonlyRepo>,
    knobs: &Knobs,
    colocated: bool,
    lock: &GitImportExportLock,
    report: &mut Precondition,
    facts: &mut FinishFacts,
) -> Result<(Arc<ReadonlyRepo>, working_copy::SnapshotStats), PreconditionError> {
    let ctx = StepCtx { knobs, colocated, lock };
    let repo = if colocated {
        import_git_head(workspace, repo, &ctx, report, facts)?
    } else {
        repo
    };
    let (repo, stats) = snapshot_working_copy(workspace, repo, &ctx, report, facts)?;
    let repo = match &knobs.import_options {
        Some(options) => import_git_refs(workspace, repo, &ctx, options, report, facts)?,
        None => repo,
    };
    Ok((repo, stats))
}

/// What every step needs besides the workspace and the repo.
struct StepCtx<'a> {
    knobs: &'a Knobs,
    colocated: bool,
    lock: &'a GitImportExportLock,
}

impl StepCtx<'_> {
    fn finish_ctx(&self) -> mutate::FinishCtx<'_> {
        mutate::FinishCtx {
            immutable: &self.knobs.immutable,
            colocated: self.colocated,
            _lock: self.lock,
        }
    }
}

/// Port of `import_git_head` (`cli/src/cli_util.rs:1352-1416` @ v0.44.0).
///
/// When the Git HEAD moved to a commit, `@` is checked out onto it (the old `@` abandoned if
/// discardable) and the working-copy STATE is reset to the new `@` WITHOUT touching a file —
/// the files are presumably what the `git` command that moved HEAD left behind. When HEAD was
/// deleted, only the descendants are rebased and the transaction finishes normally. Nothing is
/// written when the import changed nothing.
fn import_git_head(
    workspace: &mut Workspace,
    repo: Arc<ReadonlyRepo>,
    ctx: &StepCtx<'_>,
    report: &mut Precondition,
    facts: &mut FinishFacts,
) -> Result<Arc<ReadonlyRepo>, PreconditionError> {
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&repo, &workspace_name);
    pollster::block_on(git::import_head(tx.repo_mut())).map_err(|e| backend(&e))?;
    if !tx.repo().has_changes() {
        return Ok(repo);
    }

    let old_git_head_present = repo.view().git_head().is_present();
    let new_git_head = tx.repo().view().git_head().clone();
    if let Some(new_git_head_id) = new_git_head.as_normal() {
        let new_git_head_commit = tx.repo().store().get_commit(new_git_head_id).map_err(|e| backend(&e))?;
        let wc_commit = pollster::block_on(tx.repo_mut().check_out(workspace_name, &new_git_head_commit))
            .map_err(|e| backend(&e))?;
        let mut locked_ws = pollster::block_on(workspace.start_working_copy_mutation()).map_err(|e| backend(&e))?;
        pollster::block_on(locked_ws.locked_wc().reset(&wc_commit)).map_err(|e| backend(&e))?;
        let num_rebased = pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(|e| backend(&e))?;
        let new_repo = pollster::block_on(tx.commit("import git head")).map_err(|e| backend(&e))?;
        pollster::block_on(locked_ws.finish(new_repo.op_id().clone())).map_err(|e| backend(&e))?;
        report.git_head_imported = true;
        report.git_head_rebased = saturate(num_rebased);
        report.git_head_reset = old_git_head_present;
        Ok(new_repo)
    } else {
        let num_rebased = pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(|e| backend(&e))?;
        let finish = mutate::finish_transaction(workspace, tx, "import git head", &ctx.finish_ctx())?;
        report.git_head_imported = true;
        report.git_head_rebased = saturate(num_rebased);
        facts.merge(finish.facts);
        Ok(finish.repo)
    }
}

/// Port of `snapshot_working_copy` (`cli/src/cli_util.rs:2058-2231` @ v0.44.0).
///
/// Locks the working copy, settles its freshness ([`handle_stale_working_copy`]), snapshots,
/// and — only when the tree changed — writes `snapshot working copy` (`is_snapshot = true`):
/// `@` rewritten with the new tree, or, when `@` is immutable, a NEW commit on top of it. In a
/// colocated workspace the change is exported to Git inside the same transaction. The working
/// copy is ALWAYS finished at the resulting operation, which writes nothing when neither the
/// tree state nor the operation id changed (`local_working_copy.rs:2922-2948` @ 0.44.0).
fn snapshot_working_copy(
    workspace: &mut Workspace,
    repo: Arc<ReadonlyRepo>,
    ctx: &StepCtx<'_>,
    report: &mut Precondition,
    facts: &mut FinishFacts,
) -> Result<(Arc<ReadonlyRepo>, working_copy::SnapshotStats), PreconditionError> {
    let workspace_name = workspace.workspace_name().to_owned();
    let options = ctx.knobs.snapshot_options();
    let mut locked_ws = pollster::block_on(workspace.start_working_copy_mutation()).map_err(|e| backend(&e))?;
    let Some((mut repo, wc_commit)) =
        handle_stale_working_copy(locked_ws.locked_wc(), Arc::clone(&repo), &workspace_name)?
    else {
        // The workspace is gone from the view: the CLI skips the snapshot and drops the lock
        // without finishing.
        return Ok((repo, working_copy::SnapshotStats::default()));
    };
    let (new_tree, stats) = pollster::block_on(locked_ws.locked_wc().snapshot(&options)).map_err(|e| backend(&e))?;
    report.snapshot_stats = wc_ops::project_stats(&stats);

    if new_tree.tree_ids_and_labels() != wc_commit.tree().tree_ids_and_labels() {
        repo = commit_snapshot(&repo, &workspace_name, &wc_commit, &new_tree, ctx, report, facts)?;
    }

    if ctx.colocated && has_jjconflict_entries(&new_tree)? {
        report.jjconflict_files_present = true;
    }

    pollster::block_on(locked_ws.finish(repo.op_id().clone())).map_err(|e| backend(&e))?;
    Ok((repo, stats))
}

/// The transaction half of [`snapshot_working_copy`]: record `new_tree` as `@`'s content.
fn commit_snapshot(
    repo: &Arc<ReadonlyRepo>,
    workspace_name: &WorkspaceName,
    wc_commit: &Commit,
    new_tree: &MergedTree,
    ctx: &StepCtx<'_>,
    report: &mut Precondition,
    facts: &mut FinishFacts,
) -> Result<Arc<ReadonlyRepo>, PreconditionError> {
    let mut tx = start_repo_transaction(repo, workspace_name);
    tx.set_is_snapshot(true);
    let wc_immutable = {
        let immutable = crate::op_support::resolve_immutable(tx.repo(), &ctx.knobs.immutable)?;
        let set = immutable
            .intersection(&RevsetExpression::commit(wc_commit.id().clone()))
            .evaluate(tx.repo())
            .map_err(|e| backend(&e))?;
        !set.is_empty().map_err(|e| backend(&e))?
    };
    let mut_repo = tx.repo_mut();
    let new_wc_commit = if wc_immutable {
        report.working_copy_immutable_new_commit = true;
        pollster::block_on(
            mut_repo
                .new_commit(vec![wc_commit.id().clone()], new_tree.clone())
                .write(),
        )
    } else {
        pollster::block_on(mut_repo.rewrite_commit(wc_commit).set_tree(new_tree.clone()).write())
    }
    .map_err(|e| backend(&e))?;
    mut_repo
        .set_wc_commit(workspace_name.to_owned(), new_wc_commit.id().clone())
        .map_err(|e| backend(&e))?;
    let num_rebased = pollster::block_on(mut_repo.rebase_descendants()).map_err(|e| backend(&e))?;
    report.snapshot_rebased = saturate(num_rebased);

    if ctx.colocated {
        if wc_immutable {
            // A new working-copy commit was created on top: reset Git HEAD and the index.
            mutate::try_reset_git_head(mut_repo, &new_wc_commit, facts)?;
        } else {
            // `export_working_copy_changes_to_git` (`cli_util.rs:2650-2661`).
            pollster::block_on(git::update_intent_to_add(
                mut_repo.base_repo().as_ref(),
                &wc_commit.tree(),
                &new_wc_commit.tree(),
            ))
            .map_err(|e| backend(&e))?;
        }
        mutate::export_refs_into(mut_repo, facts)?;
    }
    pollster::block_on(tx.commit("snapshot working copy")).map_err(|e| backend(&e))
}

/// Whether `tree` resolves and has a top-level entry whose name starts with `.jjconflict` —
/// the CLI's colocated warning condition (`cli_util.rs:2195-2222`). A conflicted tree does not
/// resolve and never triggers it, exactly as there.
fn has_jjconflict_entries(tree: &MergedTree) -> Result<bool, PreconditionError> {
    let trees = pollster::block_on(tree.trees()).map_err(|e| backend(&e))?;
    Ok(trees.into_resolved().is_ok_and(|resolved| {
        resolved
            .entries_non_recursive()
            .any(|entry| entry.name().as_internal_str().starts_with(".jjconflict"))
    }))
}

/// Port of `import_git_refs` (`cli/src/cli_util.rs:1428-1460` @ v0.44.0): import the Git refs
/// with the effective `options`, and — only when that changed anything — rebase the MUTABLE
/// descendants (immutable set resolved against the BASE repo, `rebase_mutable_descendants`)
/// and finish the transaction as `import git refs`.
///
/// The report's [`Precondition::git_refs`] projection names `@`, so it is skipped when this
/// workspace has no `@` in the view (forgotten elsewhere); the import itself runs regardless,
/// exactly as the CLI's does.
fn import_git_refs(
    workspace: &mut Workspace,
    repo: Arc<ReadonlyRepo>,
    ctx: &StepCtx<'_>,
    options: &GitImportOptions,
    report: &mut Precondition,
    facts: &mut FinishFacts,
) -> Result<Arc<ReadonlyRepo>, PreconditionError> {
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&repo, &workspace_name);
    let stats = pollster::block_on(git::import_refs(tx.repo_mut(), options)).map_err(|e| backend(&e))?;
    if !tx.repo().has_changes() {
        drop(tx);
        if repo.view().get_wc_commit_id(&workspace_name).is_some() {
            let mutation = mutate::no_op_result(&workspace_name, &repo)?;
            report.git_refs = Some(crate::git::project_import(&stats, &repo, false, mutation));
        }
        return Ok(repo);
    }

    let immutable = crate::op_support::resolve_immutable(tx.base_repo().as_ref(), &ctx.knobs.immutable)?;
    let mut num_rebased = 0_usize;
    pollster::block_on(
        tx.repo_mut()
            .rebase_descendants_with_options(&immutable, &RebaseOptions::default(), |_, _| num_rebased += 1),
    )
    .map_err(|e| backend(&e))?;
    report.git_refs_rebased = saturate(num_rebased);
    let finish = mutate::finish_transaction(workspace, tx, "import git refs", &ctx.finish_ctx())?;
    if finish.wc_commit.is_some() {
        let mutation = mutate::mutation_result(&finish, Vec::new(), Vec::new())?;
        report.git_refs = Some(crate::git::project_import(&stats, &finish.repo, true, mutation));
    }
    facts.merge(finish.facts);
    Ok(finish.repo)
}

/// Port of `handle_stale_working_copy` (`cli/src/cli_util.rs:2952-3020` @ v0.44.0).
///
/// Returns `None` when the workspace has no `@` in the view (it was deleted), otherwise the repo
/// to snapshot against — reloaded at the working copy's operation when that one is NEWER
/// (`Updated`) — and its `@`.
fn handle_stale_working_copy(
    locked_wc: &mut dyn LockedWorkingCopy,
    repo: Arc<ReadonlyRepo>,
    workspace_name: &WorkspaceName,
) -> Result<Option<(Arc<ReadonlyRepo>, Commit)>, PreconditionError> {
    let get_wc_commit = |repo: &ReadonlyRepo| -> Result<Option<Commit>, PreconditionError> {
        repo.view()
            .get_wc_commit_id(workspace_name)
            .map(|id| repo.store().get_commit(id))
            .transpose()
            .map_err(|e| backend(&e))
    };
    let Some(wc_commit) = get_wc_commit(&repo)? else {
        return Ok(None);
    };
    let old_op_id = locked_wc.old_operation_id().clone();
    let stale = |cause: StaleCause| PreconditionError::StaleWorkingCopy {
        cause,
        working_copy_op_id: old_op_id.hex(),
        repo_op_id: repo.op_id().hex(),
    };
    match pollster::block_on(WorkingCopyFreshness::check_stale(locked_wc, &wc_commit, &repo)) {
        Ok(WorkingCopyFreshness::Fresh) => Ok(Some((repo, wc_commit))),
        Ok(WorkingCopyFreshness::Updated(wc_operation)) => {
            let repo = pollster::block_on(repo.reload_at(&wc_operation)).map_err(|e| backend(&e))?;
            Ok(get_wc_commit(&repo)?.map(|wc_commit| (repo, wc_commit)))
        }
        Ok(WorkingCopyFreshness::WorkingCopyStale) => Err(stale(StaleCause::Stale)),
        Ok(WorkingCopyFreshness::SiblingOperation) => Err(stale(StaleCause::SiblingOperation)),
        Err(OpStoreError::ObjectNotFound { .. }) => Err(stale(StaleCause::OperationNotFound)),
        Err(e) => Err(backend(&e)),
    }
}

#[cfg(test)]
mod tests {
    use super::{FinishFacts, PreconditionError, StaleCause};
    use crate::git::GitExportFailure;
    use crate::mutate::MutateError;

    fn failure(name: &str) -> GitExportFailure {
        GitExportFailure {
            name: name.to_owned(),
            remote: "git".to_owned(),
            reason: "r".to_owned(),
        }
    }

    #[test]
    fn default_finish_facts_are_absent_and_anything_else_is_present() {
        assert_eq!(FinishFacts::default().into_option(), None);
        let facts = FinishFacts {
            git_head_update_failed: true,
            ..FinishFacts::default()
        };
        assert_eq!(facts.clone().into_option(), Some(facts));
    }

    #[test]
    fn merged_finish_facts_or_the_flags_and_concatenate_the_failures() {
        let mut facts = FinishFacts {
            working_copy_became_immutable: true,
            export_failed_bookmarks: vec![failure("a")],
            ..FinishFacts::default()
        };
        facts.merge(FinishFacts {
            git_head_update_failed: true,
            export_failed_bookmarks: vec![failure("b")],
            export_failed_tags: vec![failure("t")],
            ..FinishFacts::default()
        });
        assert_eq!(
            facts,
            FinishFacts {
                working_copy_became_immutable: true,
                git_head_update_failed: true,
                export_failed_bookmarks: vec![failure("a"), failure("b")],
                export_failed_tags: vec![failure("t")],
            }
        );
    }

    #[test]
    fn stale_causes_render_as_their_stable_tokens() {
        assert_eq!(StaleCause::Stale.to_string(), "stale");
        assert_eq!(StaleCause::SiblingOperation.to_string(), "sibling_operation");
        assert_eq!(StaleCause::OperationNotFound.as_str(), "operation_not_found");
    }

    /// A mutation-side failure inside the precondition keeps its class: config stays config,
    /// a nested precondition error is unwrapped, everything else is a backend failure.
    #[test]
    fn mutate_errors_map_onto_the_precondition_taxonomy() {
        assert!(matches!(
            PreconditionError::from(MutateError::Config { reason: "k".to_owned() }),
            PreconditionError::Config { reason } if reason == "k"
        ));
        assert!(matches!(
            PreconditionError::from(MutateError::Backend("b".to_owned())),
            PreconditionError::Backend(reason) if reason == "b"
        ));
        assert!(matches!(
            PreconditionError::from(MutateError::Precondition(PreconditionError::Backend("n".to_owned()))),
            PreconditionError::Backend(reason) if reason == "n"
        ));
        assert!(matches!(
            PreconditionError::from(MutateError::NotAGitRepo),
            PreconditionError::Backend(reason) if reason == "not a git repository"
        ));
        assert!(matches!(
            PreconditionError::from(crate::ConfigError::Load { reason: "c".to_owned() }),
            PreconditionError::Config { reason } if reason == "c"
        ));
    }
}
