// SPDX-License-Identifier: MIT

//! `revert.rs` — the plan phase of `jj revert` (Story 9.31 follow-on), ported from `cmd_revert`
//! (`cli/src/commands/revert.rs` @ v0.46.0) up to its template parse: the revisions in reverse
//! topological order, then the location. `drop_actions`' `revert` rows call [`plan_revert`]
//! today; the revert verb (Story 9.18) is meant to call the same fn, and keeps the
//! `templates.revert_description` parse and the transaction for itself.

use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::repo::Repo as _;
use jj_lib::revset::{ResolvedRevsetExpression, RevsetExpression, UserRevsetExpression};
use jj_lib::transaction::Transaction;

use crate::mutate::{be, refuse_git_root_merge, MutateError};
use crate::op_support::{resolve_commit_location, resolve_immutable, resolve_ordered, LocationArgs};
use crate::ChangeId;

/// What [`plan_revert`] decided.
// WHY: the struct's FIELDS are the revert verb's input (Story 9.18) and unused until it lands;
// the only caller today, `drop_actions`, uses the refusal and whether a plan exists.
#[allow(dead_code)]
#[derive(Debug)]
pub(crate) struct RevertPlan {
    /// The commits to revert, in reverse topological order (the CLI's revset order): the first
    /// is reverted first, onto the location's parents.
    pub(crate) to_revert: Vec<CommitId>,
    /// The parents of the first reverted commit.
    pub(crate) new_parent_ids: Vec<CommitId>,
    /// The children rebased onto the last reverted commit (`-A`/`-B`).
    pub(crate) new_child_ids: Vec<CommitId>,
}

/// `jj revert -r <revisions> <location>`'s plan: the revisions resolved and evaluated in reverse
/// topological order — none is the CLI's "No revisions to revert." (`Ok(None)`, the verb writes
/// no operation) — then the location (`"reverted commits"`). The immutable set is resolved for
/// `-A`/`-B` with the location, whose children it rewrites (the reverted commits themselves are
/// never rewritten); otherwise last, where the CLI's `tx.finish` resolves it for a revert that
/// writes (Story 9.56). Two or more location parents with the root among them refuse up front on a
/// Git-backed store, with the backend's own text — the CLI reaches it at the first reverted
/// commit's write.
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — a revision or a location id does not resolve.
/// - [`MutateError::InvalidInput`] — a location refusal of `compute_commit_location` (the loop
///   text among them), or (Git backend) a root merge as the location's parents.
/// - [`MutateError::Immutable`] — (`-A`/`-B`) a child the location would rewrite is immutable.
/// - [`MutateError::Config`] — the `immutable_heads()` alias does not resolve (never for "No
///   revisions to revert.").
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
pub(crate) fn plan_revert(
    tx: &Transaction,
    immutable: &Arc<UserRevsetExpression>,
    revisions: &[ChangeId],
    location: &LocationArgs<'_>,
) -> Result<Option<RevertPlan>, MutateError> {
    let ids = resolve_ordered(tx, Some(revisions))?.unwrap_or_default();
    let set = RevsetExpression::commits(ids)
        .evaluate(tx.base_repo().as_ref())
        .map_err(be)?;
    let to_revert: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    if to_revert.is_empty() {
        return Ok(None);
    }
    let resolved: Arc<ResolvedRevsetExpression> = if location.inserts() {
        resolve_immutable(tx.base_repo().as_ref(), immutable)?
    } else {
        RevsetExpression::none()
    };
    let (new_parent_ids, new_child_ids) = resolve_commit_location(tx, &resolved, location, "reverted commits")?;
    // The Git backend refuses the first reverted commit's write for a root merge; refused up
    // front so the preview and the verb agree (Story 9.31).
    refuse_git_root_merge(tx.repo().store(), &new_parent_ids)?;
    if !location.inserts() {
        resolve_immutable(tx.base_repo().as_ref(), immutable)?;
    }
    Ok(Some(RevertPlan {
        to_revert,
        new_parent_ids,
        new_child_ids,
    }))
}

#[cfg(test)]
mod tests {
    use jj_lib::repo::Repo as _;

    use super::plan_revert;
    use crate::op_support::LocationArgs;

    /// No revision is the CLI's "No revisions to revert." — no plan, no refusal. A drop row
    /// always names one change, so only this direct call reaches the branch.
    #[test]
    fn no_revisions_plan_nothing() {
        test_helpers::pin_test_env();
        let fixture = test_helpers::extract_fixture("tiny-3-commits").expect("fixture");
        let repo = crate::Repo::open(&fixture.path).expect("open");
        let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("head");
        let tx = crate::op_support::start_repo_transaction(&readonly, repo.workspace().workspace_name());
        let root = crate::ChangeId(readonly.store().root_commit().change_id().reverse_hex());
        let onto = [root];
        let location = LocationArgs {
            onto: &onto,
            insert_after: &[],
            insert_before: &[],
        };
        let immutable = jj_lib::revset::RevsetExpression::root();
        assert!(plan_revert(&tx, &immutable, &[], &location).expect("plan").is_none());
    }
}
