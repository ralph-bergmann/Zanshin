// SPDX-License-Identifier: MIT

//! `simplify_parents.rs` — `jj simplify-parents` (Story 9.14), ported step for step from
//! `cmd_simplify_parents` (`cli/src/commands/simplify_parents.rs` @ v0.46.0).
//!
//! Every target with more than one parent loses each parent that is also an ancestor of another
//! of its parents; descendants follow. Contents never change. The revisions are change ids (the
//! CLI's revset arguments are terminal input language, ADR-0003); with neither `source` nor
//! `revisions` the `revsets.simplify-parents` setting is the target set, as in the CLI. The CLI's
//! status lines ("Removed {edges} edges from {simplified} out of {n} commits.", "Rebased {n}
//! descendant commits.") are the result's counts.

use std::collections::HashSet;

use futures::TryStreamExt as _;
use jj_lib::backend::{BackendError, CommitId};
use jj_lib::revset::RevsetExpression;
use jj_lib::workspace::Workspace;

use crate::mutate::{be, finish_verb, guard_rewritable, mutation_result, no_op_result, MutateError, MutationResult};
use crate::op_support::{resolve_ordered, start_repo_transaction};
use crate::snapshot::VerbContext;
use crate::ChangeId;

/// [`crate::Repo::simplify_parents`]'s arguments (Story 9.14): the CLI's `jj simplify-parents`
/// flags. Both empty is the CLI's default, the `revsets.simplify-parents` setting (jj's default
/// `reachable(@, mutable())`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SimplifyParentsOptions {
    /// `-s/--source`, repeatable: simplify these revisions together with their descendants.
    pub source: Vec<ChangeId>,
    /// `-r/--revisions`, repeatable: simplify these revisions.
    pub revisions: Vec<ChangeId>,
}

/// Outcome of a successful [`crate::Repo::simplify_parents`] (Story 9.14) — the CLI's status
/// lines as typed facts. Every count saturates at `u32::MAX`.
#[derive(Debug)]
pub struct SimplifyParentsResult {
    /// The shared mutation contract; `new_op_id` is the pre-call head when nothing changed.
    /// `new_change_ids` and `abandoned_change_ids` are always empty.
    pub mutation: MutationResult,
    /// The commits in the target set — the operation's `simplify <n> commits`.
    pub num_target_commits: u32,
    /// Targets that lost at least one parent edge.
    pub num_simplified_commits: u32,
    /// Parent edges removed in total.
    pub num_removed_edges: u32,
    /// Rewritten commits that lost no parent edge — rebased onto a rewritten parent, targets
    /// included (the CLI's "Rebased <n> descendant commits.").
    pub num_rebased_descendants: u32,
}

/// A count as the result's `u32`, saturating.
fn count(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

/// `jj simplify-parents` (Story 9.14) — see [`crate::Repo::simplify_parents`].
///
/// # Errors
///
/// See [`crate::Repo::simplify_parents`].
pub(crate) fn simplify_parents(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &SimplifyParentsOptions,
) -> Result<SimplifyParentsResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);

    let target = if options.source.is_empty() && options.revisions.is_empty() {
        crate::arrange::target_expression(&tx, workspace, ctx, &[], "revsets.simplify-parents")?
    } else {
        // The CLI parses `-s` before `-r`; an empty flag is `none()`.
        let source = resolve_ordered(&tx, Some(&options.source))?.unwrap_or_default();
        let revisions = resolve_ordered(&tx, Some(&options.revisions))?.unwrap_or_default();
        RevsetExpression::commits(source)
            .descendants()
            .union(&RevsetExpression::commits(revisions))
    };
    let set = target.evaluate(tx.base_repo().as_ref()).map_err(be)?;
    let commit_ids: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    guard_rewritable(&tx, &ctx.templates(workspace), &commit_ids)?;
    let commit_ids_set: HashSet<CommitId> = commit_ids.iter().cloned().collect();
    let num_target_commits = commit_ids.len();

    let mut simplified_commits = 0;
    let mut edges = 0;
    let mut reparented_descendants = 0;
    pollster::block_on(tx.repo_mut().transform_descendants(commit_ids, async |mut rewriter| {
        // The MAPPED parent count — a parent rewritten earlier in the walk counts once.
        let num_old_heads = rewriter.new_parents().len();
        if commit_ids_set.contains(rewriter.old_commit().id()) && num_old_heads > 1 {
            rewriter
                .simplify_ancestor_merge()
                .await
                .map_err(|err| BackendError::Other(err.into()))?;
        }
        let num_new_heads = rewriter.new_parents().len();
        if rewriter.parents_changed() {
            rewriter.reparent().write().await?;
            if num_new_heads < num_old_heads {
                simplified_commits += 1;
                edges += num_old_heads - num_new_heads;
            } else {
                reparented_descendants += 1;
            }
        }
        Ok(())
    }))
    .map_err(be)?;

    // `WorkspaceCommandTransaction::finish`'s "Nothing changed." guard (`cli_util.rs:2852`).
    let mutation = if tx.repo().has_changes() {
        let description = format!("simplify {num_target_commits} commits");
        let finish = finish_verb(workspace, tx, &description, ctx)?;
        mutation_result(&finish, Vec::new(), Vec::new())
    } else {
        drop(tx);
        no_op_result(&workspace_name, &readonly)?
    };
    Ok(SimplifyParentsResult {
        mutation,
        num_target_commits: count(num_target_commits),
        num_simplified_commits: count(simplified_commits),
        num_removed_edges: count(edges),
        num_rebased_descendants: count(reparented_descendants),
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn count_saturates() {
        assert_eq!(super::count(7), 7);
        assert_eq!(super::count(usize::MAX), u32::MAX);
    }
}
