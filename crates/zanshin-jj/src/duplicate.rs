// SPDX-License-Identifier: MIT

//! `duplicate.rs` — the plan phase of `jj duplicate` (Story 9.31), ported from `cmd_duplicate`
//! (`cli/src/commands/duplicate.rs` @ v0.46.0) up to its transaction: the root refusal, then the
//! location. `drop_actions`' `duplicate` row calls [`plan_duplicate`] today; the duplicate verb
//! (Story 9.9) is meant to call the same fn.

use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::repo::Repo as _;
use jj_lib::revset::{ResolvedRevsetExpression, RevsetExpression, UserRevsetExpression};
use jj_lib::transaction::Transaction;

use crate::mutate::{be, refuse_git_root_merge, MutateError};
use crate::op_support::{resolve_commit_location, resolve_immutable, resolve_ordered, LocationArgs};
use crate::ChangeId;

/// What [`plan_duplicate`] decided.
// WHY: the fields are the duplicate verb's input (Story 9.9); its only caller today,
// `drop_actions`, needs just the refusal. Dropped when the verb lands.
#[allow(dead_code)]
#[derive(Debug)]
pub(crate) struct DuplicatePlan {
    /// The commits to duplicate, in reverse topological order (the CLI's revset order).
    pub(crate) to_duplicate: Vec<CommitId>,
    /// `(parents, children)` of the duplicates for `-o`/`-A`/`-B`; `None` without a location
    /// (each duplicate goes onto its original's parents).
    pub(crate) location: Option<(Vec<CommitId>, Vec<CommitId>)>,
}

/// `jj duplicate <revisions> [<location>]`'s plan: the revisions resolved in reverse topological
/// order, the root refusal (`Cannot duplicate the root commit`, when the last — the oldest — is
/// the root), then the location (`"duplicated commits"`). The immutable set is resolved only for
/// `-A`/`-B`, whose children the location rewrites; `-o` alone never reads it, as in the CLI. Two
/// or more location parents with the root among them refuse up front on a Git-backed store, with
/// the backend's own text — the CLI reaches it at the duplicates' write.
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — a revision or a location id does not resolve.
/// - [`MutateError::InvalidInput`] — the root commit is among the revisions, a location refusal
///   of `compute_commit_location`, or (Git backend) a root merge as the location's parents.
/// - [`MutateError::Immutable`] — (`-A`/`-B`) a child the location would rewrite is immutable.
/// - [`MutateError::Config`] — (`-A`/`-B`) the `immutable_heads()` alias does not resolve.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
pub(crate) fn plan_duplicate(
    tx: &Transaction,
    immutable: &Arc<UserRevsetExpression>,
    revisions: &[ChangeId],
    location: &LocationArgs<'_>,
) -> Result<DuplicatePlan, MutateError> {
    let ids = resolve_ordered(tx, Some(revisions))?.unwrap_or_default();
    let set = RevsetExpression::commits(ids)
        .evaluate(tx.base_repo().as_ref())
        .map_err(be)?;
    let to_duplicate: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    if to_duplicate.last() == Some(tx.base_repo().store().root_commit_id()) {
        return Err(MutateError::InvalidInput {
            reason: "Cannot duplicate the root commit".to_owned(),
        });
    }
    let has_location = !location.onto.is_empty() || location.inserts();
    let location = if has_location {
        let resolved: Arc<ResolvedRevsetExpression> = if location.inserts() {
            resolve_immutable(tx.base_repo().as_ref(), immutable)?
        } else {
            RevsetExpression::none()
        };
        let (parents, children) = resolve_commit_location(tx, &resolved, location, "duplicated commits")?;
        // The Git backend refuses the duplicates' write for a root merge; refused up front so the
        // preview and the verb agree (Story 9.31).
        refuse_git_root_merge(tx.repo().store(), &parents)?;
        Some((parents, children))
    } else {
        None
    };
    Ok(DuplicatePlan { to_duplicate, location })
}
