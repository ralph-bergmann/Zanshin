// SPDX-License-Identifier: MIT

//! `duplicate.rs` — the plan phase of `jj duplicate` (Story 9.31), ported from `cmd_duplicate`
//! (`cli/src/commands/duplicate.rs` @ v0.46.0) up to its transaction: the root refusal, then the
//! location. `drop_actions`' `duplicate` row calls [`plan_duplicate`] today; the duplicate verb
//! (Story 9.9) is meant to call the same fn.

use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::repo::Repo as _;
use jj_lib::revset::{ResolvedRevsetExpression, RevsetExpression};
use jj_lib::transaction::Transaction;

use crate::mutate::{be, refuse_git_root_merge, MutateError};
use crate::op_support::{resolve_commit_location, resolve_immutable, resolve_ordered, LocationArgs};
use crate::template::Templates;
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
/// the root), then the location (`"duplicated commits"`). The immutable set is resolved for
/// `-A`/`-B` with the location, whose children it rewrites; otherwise last, where the CLI's
/// `tx.finish` resolves it — every duplicate writes (Story 9.56). Two or more location parents
/// with the root among them refuse up front on a Git-backed store, with the backend's own text —
/// the CLI reaches it at the duplicates' write.
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — a revision or a location id does not resolve.
/// - [`MutateError::InvalidInput`] — the root commit is among the revisions, a location refusal
///   of `compute_commit_location`, or (Git backend) a root merge as the location's parents.
/// - [`MutateError::Immutable`] — (`-A`/`-B`) a child the location would rewrite is immutable.
/// - [`MutateError::Config`] — the `immutable_heads()` alias does not resolve.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
pub(crate) fn plan_duplicate(
    tx: &Transaction,
    templates: &Templates<'_>,
    revisions: &[ChangeId],
    location: &LocationArgs<'_>,
) -> Result<DuplicatePlan, MutateError> {
    let ids = resolve_ordered(tx, Some(revisions))?.unwrap_or_default();
    let set = RevsetExpression::commits(ids)
        .evaluate(tx.base_repo().as_ref())
        .map_err(be)?;
    let to_duplicate: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    if to_duplicate.last() == Some(tx.base_repo().store().root_commit_id()) {
        return Err(MutateError::invalid("Cannot duplicate the root commit".to_owned()));
    }
    let inserts = location.inserts();
    let has_location = !location.onto.is_empty() || inserts;
    let location = if has_location {
        let resolved: Arc<ResolvedRevsetExpression> = if inserts {
            resolve_immutable(tx.base_repo().as_ref(), templates.immutable())?
        } else {
            RevsetExpression::none()
        };
        let (parents, children) = resolve_commit_location(tx, &resolved, templates, location, "duplicated commits")?;
        // The Git backend refuses the duplicates' write for a root merge; refused up front so the
        // preview and the verb agree (Story 9.31).
        refuse_git_root_merge(tx.repo().store(), &parents)?;
        Some((parents, children))
    } else {
        None
    };
    if !inserts {
        resolve_immutable(tx.base_repo().as_ref(), templates.immutable())?;
    }
    Ok(DuplicatePlan { to_duplicate, location })
}

#[cfg(test)]
mod tests {
    /// No location and `-A`: the arms `drop_actions`' `duplicate` row (always `-o`) never takes.
    /// The fixture is `root → Commit 1 → Commit 2 → Commit 3` plus an empty `@` off the root;
    /// `@ -A "Commit 1"` inserts the duplicate above Commit 2, unless Commit 2 is immutable.
    #[test]
    fn plan_duplicate_without_a_location_and_with_an_insert_location() {
        use std::sync::Arc;

        use jj_lib::backend::CommitId;
        use jj_lib::object_id::ObjectId as _;
        use jj_lib::repo::Repo as _;
        use jj_lib::revset::{RevsetExpression, UserRevsetExpression};

        use crate::mutate::MutateError;
        use crate::op_support::LocationArgs;
        use crate::template::Templates;

        test_helpers::pin_test_env();
        let fixture = test_helpers::extract_fixture("tiny-3-commits").expect("fixture");
        let repo = crate::Repo::open(&fixture.path).expect("open");
        let name = repo.workspace().workspace_name().to_owned();
        let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("head");
        let store = readonly.store();
        let by_description = |description: &str| -> jj_lib::commit::Commit {
            let mut pending: Vec<CommitId> = readonly.view().heads().iter().cloned().collect();
            std::iter::from_fn(|| {
                let commit = store.get_commit(&pending.pop()?).expect("commit");
                pending.extend(commit.parent_ids().iter().cloned());
                Some(commit)
            })
            .find(|commit| commit.description().trim_end() == description)
            .ok_or(description)
            .expect("no commit described")
        };
        let change = |commit: &jj_lib::commit::Commit| crate::ChangeId(commit.change_id().reverse_hex());
        let (c1, c2) = (by_description("Commit 1"), by_description("Commit 2"));
        let wc_id = readonly.view().get_wc_commit_id(&name).expect("@").clone();
        let at = store.get_commit(&wc_id).expect("@ commit");
        let tx = crate::op_support::start_repo_transaction(&readonly, &name);
        let config = crate::config::load(&repo).expect("config");
        let env =
            crate::snapshot::CommandEnv::load(repo.workspace(), &config, &mut crate::warning::Warnings::default())
                .expect("start-up");
        let root: Arc<UserRevsetExpression> = RevsetExpression::root();
        let immutable: Arc<UserRevsetExpression> = RevsetExpression::commits(vec![c2.id().clone()]);
        let mutable_all = Templates::new(&config, &root, &env.template_startup, repo.workspace());
        let c2_immutable = Templates::new(&config, &immutable, &env.template_startup, repo.workspace());

        let nowhere = LocationArgs {
            onto: &[],
            insert_after: &[],
            insert_before: &[],
        };
        let plan = super::plan_duplicate(&tx, &mutable_all, &[change(&c2)], &nowhere).expect("no location");
        assert_eq!(plan.to_duplicate, [c2.id().clone()]);
        assert!(plan.location.is_none());

        let after = [change(&c1)];
        let insert = LocationArgs {
            onto: &[],
            insert_after: &after,
            insert_before: &[],
        };
        let plan = super::plan_duplicate(&tx, &mutable_all, &[change(&at)], &insert).expect("-A");
        assert_eq!(plan.location, Some((vec![c1.id().clone()], vec![c2.id().clone()])));

        let refused = super::plan_duplicate(&tx, &c2_immutable, &[change(&at)], &insert);
        assert!(
            matches!(&refused, Err(MutateError::Immutable { commit_id, .. }) if *commit_id == c2.id().hex()),
            "{refused:?}"
        );
    }
}
