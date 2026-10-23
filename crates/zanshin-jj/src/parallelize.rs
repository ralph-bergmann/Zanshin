// SPDX-License-Identifier: MIT

//! `parallelize.rs` — `jj parallelize` (Story 9.16), ported step for step from `cmd_parallelize`
//! (`cli/src/commands/parallelize.rs:71-156` @ v0.46.0).
//!
//! The revisions become siblings: each keeps its parents outside the set and inherits, in place of
//! a parent inside the set, that parent's new parents; a commit outside the set whose parent is in
//! the set gets that parent's in-set parents as direct parents too. Only the targets that need a
//! rewrite are checked rewritable — an immutable root of the set stays where it is. The revisions
//! are change ids (the CLI's revset arguments are terminal input language, ADR-0003); an empty
//! list rewrites nothing and writes no operation, as the CLI's empty union does.

use std::collections::HashMap;

use futures::TryStreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::commit::Commit;
use jj_lib::repo::Repo as _;
use jj_lib::revset::RevsetExpression;
use jj_lib::workspace::Workspace;

use crate::mutate::{be, finish_verb, guard_rewritable, mutation_result, no_op_result, MutateError, MutationResult};
use crate::op_support::{resolve_ordered, start_repo_transaction};
use crate::snapshot::VerbContext;
use crate::ChangeId;

/// `jj parallelize` (Story 9.16) — see [`crate::Repo::parallelize`].
///
/// # Errors
///
/// See [`crate::Repo::parallelize`].
pub(crate) fn parallelize(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    change_ids: &[ChangeId],
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);

    // The targets, "ordered here with children before parents" (`parallelize.rs:77-82`): the
    // revset's own order.
    let ids = resolve_ordered(&tx, Some(change_ids))?.unwrap_or_default();
    let set = RevsetExpression::commits(ids)
        .evaluate(tx.base_repo().as_ref())
        .map_err(be)?;
    let ordered: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    let target_commits: Vec<Commit> = ordered
        .iter()
        .map(|id| tx.base_repo().store().get_commit(id).map_err(be))
        .collect::<Result<_, _>>()?;

    // New parents for the targets: a parent in the set is replaced by ITS new parents,
    // recursively (`:84-101`).
    let mut new_target_parents: HashMap<CommitId, Vec<CommitId>> = HashMap::new();
    let mut needs_rewrite: Vec<CommitId> = Vec::new();
    for commit in target_commits.iter().rev() {
        let mut new_parents = vec![];
        for old_parent in commit.parent_ids() {
            if let Some(grand_parents) = new_target_parents.get(old_parent) {
                new_parents.extend_from_slice(grand_parents);
                needs_rewrite.push(commit.id().clone());
            } else {
                new_parents.push(old_parent.clone());
            }
        }
        new_target_parents.insert(commit.id().clone(), new_parents);
    }
    guard_rewritable(&tx, &ctx.templates(workspace), &needs_rewrite)?;

    // A child outside the set gets its in-set parent's in-set ancestors as direct parents too
    // (`:107-120`), each once, in first-seen order — the CLI's `IndexSet`.
    let mut new_child_parents: HashMap<CommitId, Vec<CommitId>> = HashMap::new();
    for commit in target_commits.iter().rev() {
        let mut new_parents: Vec<CommitId> = Vec::new();
        for old_parent in commit.parent_ids() {
            for parent in new_child_parents.get(old_parent).into_iter().flatten() {
                if !new_parents.contains(parent) {
                    new_parents.push(parent.clone());
                }
            }
        }
        if !new_parents.contains(commit.id()) {
            new_parents.push(commit.id().clone());
        }
        new_child_parents.insert(commit.id().clone(), new_parents);
    }

    pollster::block_on(tx.repo_mut().transform_descendants(ordered, async |mut rewriter| {
        if let Some(new_parents) = new_target_parents.get(rewriter.old_commit().id()) {
            rewriter.set_new_rewritten_parents(new_parents);
        } else if rewriter
            .old_commit()
            .parent_ids()
            .iter()
            .any(|id| new_child_parents.contains_key(id))
        {
            let mut new_parents = vec![];
            for parent in rewriter.old_commit().parent_ids() {
                if let Some(parents) = new_child_parents.get(parent) {
                    new_parents.extend(parents.iter().cloned());
                } else {
                    new_parents.push(parent.clone());
                }
            }
            rewriter.set_new_rewritten_parents(&new_parents);
        }
        if rewriter.parents_changed() {
            let builder = rewriter.rebase().await?;
            builder.write().await?;
        }
        Ok(())
    }))
    .map_err(be)?;

    // `WorkspaceCommandTransaction::finish`'s "Nothing changed." guard (`cli_util.rs:2852`).
    if !tx.repo().has_changes() {
        drop(tx);
        return no_op_result(&workspace_name, &readonly);
    }
    let description = format!("parallelize {} commits", target_commits.len());
    let finish = finish_verb(workspace, tx, &description, ctx)?;
    mutation_result(&finish, Vec::new(), Vec::new())
}
