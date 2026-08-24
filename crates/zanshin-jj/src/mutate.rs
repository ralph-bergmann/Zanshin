// SPDX-License-Identifier: MIT

//! `mutate.rs` — the four P0 change mutations: describe, new, edit, abandon (FR-JJ-10a).
//!
//! Every mutation opens a jj-lib transaction, mutates via `tx.repo_mut()`, and commits
//! with a CLI-parity op-log description (NFR-R-2) — jj-lib only, never shells to `jj`
//! (AR-AP-1). The transaction boundary stays entirely inside this function; no mutation
//! primitive crosses the crate's public API (ADR-0003).

use std::sync::Arc;

use jj_lib::commit::Commit;
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{MutableRepo, ReadonlyRepo, Repo as _};
use jj_lib::rewrite::{merge_commit_trees, RebaseOptions, RewriteRefsOptions};
use jj_lib::workspace::Workspace;

use crate::ChangeId;

/// Outcome of a successful mutation (FR-JJ-10a).
#[derive(Debug)]
pub struct MutationResult {
    /// Id of the operation this mutation committed — `jj op log`'s most-recent entry
    /// immediately afterward (NFR-R-2).
    pub new_op_id: crate::OperationId,
    /// Change ids of genuinely NEW changes minted by this mutation: [`new_change`]'s
    /// created commit, or the replacement `@` jj-lib auto-creates when [`abandon`]
    /// abandons `@` itself. A rewrite ([`describe`]) or a pointer move ([`edit`]) never
    /// mints a new change id, so this is empty for those. Empty for [`abandon`] unless
    /// `@` itself was among the abandoned ids. Always empty for [`crate::op_log::undo`]
    /// (it restores state, it doesn't mint anything).
    pub new_change_ids: Vec<ChangeId>,
    /// The change ids [`abandon`]'s caller passed in, echoed verbatim. Always empty for
    /// `describe`/`new_change`/`edit` — jj-lib's own side effects (e.g. `edit()`'s
    /// implicit abandon of a discardable previous `@`) are never reflected here. Always
    /// empty for [`crate::op_log::undo`] too (it restores state, it doesn't abandon
    /// anything).
    pub abandoned_change_ids: Vec<ChangeId>,
    /// Change id of the working-copy commit (`@`) after this mutation — whether or not
    /// this mutation is what moved it.
    pub working_copy_change_id: ChangeId,
}

/// Errors returned by [`crate::Repo::describe`], [`crate::Repo::new_change`],
/// [`crate::Repo::edit`], and [`crate::Repo::abandon`].
#[derive(Debug, thiserror::Error)]
pub enum MutateError {
    /// No change exists for a given id, or it cannot be resolved unambiguously — same
    /// not-found semantics as [`crate::ChangeError::NotFound`] (empty/malformed
    /// reverse-hex, absent, only-hidden, and DIVERGENT are all indistinguishable; a
    /// divergent id is refused rather than mutating an arbitrary one of its targets).
    #[error("change not found: {id}")]
    ChangeNotFound {
        /// The reverse-hex change id that could not be resolved.
        id: String,
    },
    /// The caller's arguments are structurally invalid for this mutation (e.g. an
    /// empty parent list for `new_change`, or an empty id list for `abandon`).
    #[error("invalid input: {reason}")]
    InvalidInput {
        /// Human-readable reason the input was rejected.
        reason: String,
    },
    /// [`crate::Repo::undo`] was called with the head operation at the op-store root —
    /// there is no parent operation to restore to. Currently unreachable through this
    /// crate's own public API alone: `Workspace::init_*` always commits an
    /// "add workspace" op on top of root, so a freshly opened repo's head always has at
    /// least one parent. It exists as a defensive CLI-parity guard mirroring the CLI's
    /// own `Cannot undo root operation` refusal, not a normally-reachable path — it only
    /// fires against a hand-crafted or externally-mutated op-store (see
    /// `tests/op_log.rs`'s `undo_at_root_operation_returns_nothing_to_undo`, which has to
    /// engineer that state via direct `op_heads` file manipulation).
    #[error("nothing to undo")]
    NothingToUndo,
    /// An underlying jj-lib failure, opaque-string-wrapped so no `jj_lib` type escapes
    /// the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`MutateError::Backend`]. `pub(crate)` so
/// [`crate::op_log::undo`] can reuse it instead of duplicating an identical helper.
pub(crate) fn be<E: std::fmt::Display>(e: E) -> MutateError {
    MutateError::Backend(e.to_string())
}

/// Resolves `id` to its visible jj-lib [`Commit`] — same pattern as
/// `change.rs::get_change` (empty/malformed reverse-hex, absent, or only-hidden all
/// collapse to `ChangeNotFound`), but against `repo`, which may be a `MutableRepo`
/// mid-transaction — `resolve_change_id` works identically on both.
///
/// Unlike the read-only `get_change` (which reports divergence via `Change::divergent`
/// and silently picks the first visible target), a DIVERGENT id also collapses to
/// `ChangeNotFound` here: silently mutating an arbitrary one of several ambiguous
/// commits would be unsafe, and the real `jj` CLI likewise refuses an ambiguous
/// revision argument rather than guessing.
fn resolve_commit(repo: &MutableRepo, id: &ChangeId) -> Result<Commit, MutateError> {
    if id.0.is_empty() {
        return Err(MutateError::ChangeNotFound { id: id.0.clone() });
    }
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0)
        .ok_or_else(|| MutateError::ChangeNotFound { id: id.0.clone() })?;
    let targets = repo
        .resolve_change_id(&jj_id)
        .map_err(be)?
        .ok_or_else(|| MutateError::ChangeNotFound { id: id.0.clone() })?;
    let visible = targets
        .into_visible()
        .ok_or_else(|| MutateError::ChangeNotFound { id: id.0.clone() })?;
    let [commit_id] = visible.as_slice() else {
        return Err(MutateError::ChangeNotFound { id: id.0.clone() });
    };
    repo.store().get_commit(commit_id).map_err(be)
}

/// Captures the working-copy commit's id and tree BEFORE a transaction starts, so the
/// post-commit sync step can tell whether this mutation moved `@`, and so
/// `workspace.check_out` gets the pre-mutation tree for jj-lib's own
/// concurrent-modification guard.
pub(crate) fn capture_old_wc(
    readonly: &ReadonlyRepo,
    workspace_name: &WorkspaceName,
) -> Result<(Option<jj_lib::backend::CommitId>, Option<MergedTree>), MutateError> {
    let old_wc_id = readonly.view().get_wc_commit_id(workspace_name).cloned();
    let old_tree = match &old_wc_id {
        Some(id) => Some(readonly.store().get_commit(id).map_err(be)?.tree()),
        None => None,
    };
    Ok((old_wc_id, old_tree))
}

/// Syncs the on-disk working copy to the just-committed transaction's `@`, but ONLY if
/// this mutation actually moved it (AC-3: no `workspace.check_out` call otherwise).
/// Returns the new `@` commit either way, so callers can read its change id.
pub(crate) fn sync_working_copy(
    workspace: &mut Workspace,
    workspace_name: &WorkspaceName,
    old_wc_id: Option<&jj_lib::backend::CommitId>,
    old_tree: Option<&MergedTree>,
    new_repo: &Arc<ReadonlyRepo>,
) -> Result<Commit, MutateError> {
    let new_wc_id = new_repo
        .view()
        .get_wc_commit_id(workspace_name)
        .cloned()
        .ok_or_else(|| MutateError::Backend("workspace has no working-copy commit".to_owned()))?;
    let new_wc_commit = new_repo.store().get_commit(&new_wc_id).map_err(be)?;
    if Some(&new_wc_id) != old_wc_id {
        pollster::block_on(workspace.check_out(new_repo.op_id().clone(), old_tree, &new_wc_commit)).map_err(be)?;
    }
    Ok(new_wc_commit)
}

/// Rewrites `change_id`'s description to `description` (FR-JJ-10a).
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — `change_id` is malformed, absent, only-hidden, or
///   divergent.
/// - [`MutateError::InvalidInput`] — `change_id` resolves to the root commit.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn describe(
    workspace: &mut Workspace,
    change_id: &ChangeId,
    description: &str,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = readonly.start_transaction();
    let commit = resolve_commit(tx.repo(), change_id)?;
    // jj-lib's `rewrite_commit` internally asserts the target isn't the root commit
    // (`assert_ne!`) rather than returning an error — guard explicitly so a caller gets
    // a normal `MutateError` instead of a process-crashing panic.
    if commit.id() == tx.repo().store().root_commit_id() {
        return Err(MutateError::InvalidInput {
            reason: "cannot describe the root commit".to_owned(),
        });
    }
    pollster::block_on(
        tx.repo_mut()
            .rewrite_commit(&commit)
            .set_description(description)
            .write(),
    )
    .map_err(be)?;
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let new_repo = pollster::block_on(tx.commit(format!("describe commit {}", commit.id().hex()))).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());

    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    Ok(MutationResult {
        new_op_id,
        new_change_ids: Vec::new(),
        abandoned_change_ids: Vec::new(),
        working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
    })
}

/// Creates a new, empty change on top of `parents` (FR-JJ-10a) — a merge commit when
/// `parents.len() > 1`, via jj-lib's `merge_commit_trees` — and switches the working
/// copy to it.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `parents` is empty.
/// - [`MutateError::ChangeNotFound`] — a parent id is malformed, absent, only-hidden, or
///   divergent.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn new_change(workspace: &mut Workspace, parents: &[ChangeId]) -> Result<MutationResult, MutateError> {
    if parents.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "new_change requires at least one parent".to_owned(),
        });
    }

    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = readonly.start_transaction();
    let mut parent_commits = Vec::with_capacity(parents.len());
    for change_id in parents {
        parent_commits.push(resolve_commit(tx.repo(), change_id)?);
    }
    let parent_ids: Vec<_> = parent_commits.iter().map(|c| c.id().clone()).collect();
    let merged_tree = pollster::block_on(merge_commit_trees(tx.repo(), &parent_commits)).map_err(be)?;
    let new_commit = pollster::block_on(tx.repo_mut().new_commit(parent_ids, merged_tree).write()).map_err(be)?;
    // Matches the CLI's `jj new`: a plain new_commit records no rewrite, so this is
    // usually a no-op — kept for parity with the CLI's own descendant-rebase step.
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    pollster::block_on(tx.repo_mut().edit(workspace_name.clone(), &new_commit)).map_err(be)?;
    // edit() may have just recorded the previous `@` as abandoned (if it was
    // discardable — empty description, no diff from its parent), which leaves an
    // un-rebased entry in the transaction that would trip tx.commit()'s
    // has_rewrites() assertion. The CLI clears it via an unconditional final
    // rebase_descendants() in finish_transaction; do the same here.
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let new_change_id = ChangeId(new_commit.change_id().reverse_hex());
    let new_repo = pollster::block_on(tx.commit("new empty commit")).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());

    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    Ok(MutationResult {
        new_op_id,
        new_change_ids: vec![new_change_id],
        abandoned_change_ids: Vec::new(),
        working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
    })
}

/// Switches the working copy to `change_id` without creating a new commit (FR-JJ-10a).
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — `change_id` is malformed, absent, only-hidden, or
///   divergent.
/// - [`MutateError::Backend`] — an underlying jj-lib failure (includes attempting to
///   edit the root commit — jj-lib returns a graceful error for that case, unlike
///   `describe`/`abandon`'s internal assertions).
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn edit(workspace: &mut Workspace, change_id: &ChangeId) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = readonly.start_transaction();
    let commit = resolve_commit(tx.repo(), change_id)?;
    pollster::block_on(tx.repo_mut().edit(workspace_name.clone(), &commit)).map_err(be)?;
    // See new_change's comment: edit() may implicitly abandon a discardable previous
    // `@`, leaving an un-rebased rewrite that would trip tx.commit()'s assertion.
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let new_repo = pollster::block_on(tx.commit(format!("edit commit {}", commit.id().hex()))).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());

    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    Ok(MutationResult {
        new_op_id,
        new_change_ids: Vec::new(),
        abandoned_change_ids: Vec::new(),
        working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
    })
}

/// Abandons `change_ids`, rebasing descendants onto their parents and deleting any
/// bookmarks that pointed only at the abandoned commits (FR-JJ-10a).
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `change_ids` is empty, or resolves the root commit.
/// - [`MutateError::ChangeNotFound`] — a target id is malformed, absent, only-hidden, or
///   divergent.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn abandon(workspace: &mut Workspace, change_ids: &[ChangeId]) -> Result<MutationResult, MutateError> {
    if change_ids.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "abandon requires at least one change id".to_owned(),
        });
    }

    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = readonly.start_transaction();
    let mut commits = Vec::with_capacity(change_ids.len());
    for change_id in change_ids {
        let commit = resolve_commit(tx.repo(), change_id)?;
        // jj-lib's `record_abandoned_commit` internally asserts the target isn't the
        // root commit rather than returning an error — guard explicitly so a caller
        // gets a normal `MutateError` instead of a process-crashing panic.
        if commit.id() == tx.repo().store().root_commit_id() {
            return Err(MutateError::InvalidInput {
                reason: "cannot abandon the root commit".to_owned(),
            });
        }
        commits.push(commit);
    }
    // Whether `@` itself is among the abandoned commits determines whether jj-lib's
    // own update_wc_commits() mints a genuinely NEW change to replace it (vs. `@`
    // merely being rebased because it descends from an abandoned ancestor, which
    // keeps its change id).
    let wc_was_abandoned = old_wc_id
        .as_ref()
        .is_some_and(|id| commits.iter().any(|c| c.id() == id));

    for commit in &commits {
        tx.repo_mut().record_abandoned_commit(commit);
    }
    let options = RebaseOptions {
        rewrite_refs: RewriteRefsOptions {
            delete_abandoned_bookmarks: true,
        },
        ..Default::default()
    };
    pollster::block_on(tx.repo_mut().rebase_descendants_with_options(&options, |_, _| {})).map_err(be)?;

    let description = if let [only] = commits.as_slice() {
        format!("abandon commit {}", only.id().hex())
    } else {
        format!(
            "abandon commit {} and {} more",
            commits[0].id().hex(),
            commits.len() - 1
        )
    };
    let new_repo = pollster::block_on(tx.commit(description)).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());

    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    let new_change_ids = if wc_was_abandoned {
        vec![ChangeId(new_wc_commit.change_id().reverse_hex())]
    } else {
        Vec::new()
    };
    Ok(MutationResult {
        new_op_id,
        new_change_ids,
        abandoned_change_ids: change_ids.to_vec(),
        working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
    })
}
