// SPDX-License-Identifier: MIT

//! `duplicate.rs` — `jj duplicate` (Story 9.9), ported step for step from `cmd_duplicate`
//! (`cli/src/commands/duplicate.rs` @ v0.46.0). Its plan phase (Story 9.31) — the root refusal,
//! then the location — is [`plan_duplicate`], which `drop_actions`' `duplicate` row calls too;
//! the verb ([`duplicate`]) runs the same fn before its write, so the preview and the verb agree
//! by construction. After the plan the verb warns a duplicate that lands among its own
//! descendants or ancestors, renders `templates.duplicate_description` on each original, and
//! duplicates through jj-lib's `duplicate_commits` / `duplicate_commits_onto_parents`.
//!
//! Divergence, deliberate: the status lines (`Duplicated <hash> as …`, `Rebased N commits onto
//! duplicated commits.`) are terminal UX and not ported; the duplicates' change ids are the
//! result's `new_change_ids`.

use std::collections::HashMap;

use futures::TryStreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::commit::Commit;
use jj_lib::repo::Repo as _;
use jj_lib::revset::RevsetExpression;
use jj_lib::rewrite::{duplicate_commits, duplicate_commits_onto_parents, DuplicateCommitsStats};
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::mutate::{
    be, finish_verb, mutation_result, refuse_git_root_merge, resolve_or_wc, MutateError, MutationResult,
};
use crate::op_support::{
    resolve_commit_location, resolve_ordered, start_repo_transaction, LocationArgs, ONTO_WITH_INSERT,
};
use crate::snapshot::VerbContext;
use crate::template::Templates;
use crate::warning::WarningKind;
use crate::ChangeId;

/// [`crate::Repo::duplicate`]'s arguments — the CLI's `jj duplicate` flags, one field each (Story
/// 9.9). An EMPTY location list is a flag that was not given.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DuplicateOptions {
    /// The revisions to duplicate (`REVSETS` / `-r`). Empty is the CLI's default, `@`.
    pub revisions: Vec<ChangeId>,
    /// `-o/--onto`, repeatable: the duplicates' parents. Excludes `insert_after`/`insert_before`.
    pub onto: Vec<ChangeId>,
    /// `-A/--insert-after`, repeatable.
    pub insert_after: Vec<ChangeId>,
    /// `-B/--insert-before`, repeatable.
    pub insert_before: Vec<ChangeId>,
}

/// What [`plan_duplicate`] decided.
#[derive(Debug)]
pub(crate) struct DuplicatePlan {
    /// The commits to duplicate, in reverse topological order (the CLI's revset order).
    pub(crate) to_duplicate: Vec<CommitId>,
    /// `(parents, children)` of the duplicates for `-o`/`-A`/`-B`; `None` without a location
    /// (each duplicate goes onto its original's parents).
    pub(crate) location: Option<(Vec<CommitId>, Vec<CommitId>)>,
}

/// `jj duplicate <revisions> [<location>]`'s plan: the revisions resolved in reverse topological
/// order, then [`plan_duplicate_ids`].
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — a revision or a location id does not resolve.
/// - [`MutateError::InvalidInput`] — the root commit is among the revisions, or a location
///   refusal of `compute_commit_location`.
/// - [`MutateError::Immutable`] — a child the location would rewrite is immutable.
/// - [`MutateError::Config`] — (a location with children) the `immutable_heads()` alias does not
///   resolve.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
pub(crate) fn plan_duplicate(
    tx: &Transaction,
    templates: &Templates<'_>,
    revisions: &[ChangeId],
    location: &LocationArgs<'_>,
) -> Result<DuplicatePlan, MutateError> {
    let ids = resolve_ordered(tx, templates.prefixes(), Some(revisions))?.unwrap_or_default();
    plan_duplicate_ids(tx, templates, ids, location)
}

/// [`plan_duplicate`] over already-resolved commits — the verb's `@` default passes `@`'s commit
/// itself (the CLI evaluates `@` to its commit id), never its change id, which a divergent `@`
/// would not resolve. The commits are put in reverse topological order, then the root refusal
/// (`Cannot duplicate the root commit`, when the last — the oldest — is the root), then the
/// location (`"duplicated commits"`). The plan resolves the immutable set only where the CLI's
/// `compute_commit_location` does: for a location with children, which it rewrites. Otherwise the
/// verb parses `templates.duplicate_description` first and its finish resolves the set, the CLI's
/// order (Story 9.18 closing run). The plan does not refuse a root merge (two or more location
/// parents with the root among them, Git-backed store): the verb refuses it after its template
/// parse, right before the duplicates' write where the CLI's backend does, and `drop_actions`'
/// `duplicate` row right after this plan.
///
/// # Errors
///
/// As [`plan_duplicate`].
pub(crate) fn plan_duplicate_ids(
    tx: &Transaction,
    templates: &Templates<'_>,
    ids: Vec<CommitId>,
    location: &LocationArgs<'_>,
) -> Result<DuplicatePlan, MutateError> {
    let set = RevsetExpression::commits(ids)
        .evaluate(tx.base_repo().as_ref())
        .map_err(be)?;
    let to_duplicate: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    if to_duplicate.last() == Some(tx.base_repo().store().root_commit_id()) {
        return Err(MutateError::invalid("Cannot duplicate the root commit".to_owned()));
    }
    let has_location = !location.onto.is_empty() || location.inserts();
    let location = if has_location {
        Some(resolve_commit_location(tx, templates, location, "duplicated commits")?)
    } else {
        None
    };
    Ok(DuplicatePlan { to_duplicate, location })
}

/// Refuses what clap refuses, before the pre-verb snapshot ([`crate::Repo::duplicate`]): `onto`
/// together with `insert_after`/`insert_before` (`conflicts_with = "onto"`).
///
/// # Errors
///
/// [`MutateError::InvalidInput`] — `--onto cannot be combined with -A/--insert-after or
/// -B/--insert-before`.
pub(crate) fn check_duplicate_args(options: &DuplicateOptions) -> Result<(), MutateError> {
    let inserts = !options.insert_after.is_empty() || !options.insert_before.is_empty();
    if !options.onto.is_empty() && inserts {
        return Err(MutateError::invalid(ONTO_WITH_INSERT));
    }
    Ok(())
}

/// The two self-placement warnings (`duplicate.rs:145-178` @ v0.46.0): with location parents, a
/// duplicated commit that is an ancestor of one of them lands among its own descendants; a new
/// child that is an ancestor of a duplicated commit puts the duplicate among its ancestors. One
/// warning per commit, every descendant one before every ancestor one.
fn warn_self_placement(tx: &Transaction, plan: &DuplicatePlan, ctx: &mut VerbContext) -> Result<(), MutateError> {
    let Some((parents, children)) = &plan.location else {
        return Ok(());
    };
    if parents.is_empty() {
        return Ok(());
    }
    let index = tx.repo().index();
    let is_ancestor = |ancestor: &CommitId, descendant: &CommitId| {
        pollster::block_on(index.is_ancestor(ancestor, descendant)).map_err(be)
    };
    for id in &plan.to_duplicate {
        for parent in parents {
            if is_ancestor(id, parent)? {
                ctx.warnings.push(
                    WarningKind::DuplicateAsOwnDescendant,
                    format!("Duplicating commit {id:.12} as a descendant of itself."),
                );
                break;
            }
        }
    }
    for id in &plan.to_duplicate {
        for child in children {
            if is_ancestor(child, id)? {
                ctx.warnings.push(
                    WarningKind::DuplicateAsOwnAncestor,
                    format!("Duplicating commit {id:.12} as an ancestor of itself."),
                );
                break;
            }
        }
    }
    Ok(())
}

/// `jj duplicate` (Story 9.9) — see [`crate::Repo::duplicate`], which ran
/// [`check_duplicate_args`] before the snapshot: [`plan_duplicate`] (`@` when no revision is
/// given), the self-placement warnings, `templates.duplicate_description` on every original, the
/// duplication, then the finish with the CLI's `duplicate <n> commit(s)`.
///
/// # Errors
///
/// See [`crate::Repo::duplicate`].
pub(crate) fn duplicate(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &DuplicateOptions,
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let location = LocationArgs {
        onto: &options.onto,
        insert_after: &options.insert_after,
        insert_before: &options.insert_before,
    };
    let plan = {
        let templates = ctx.templates(workspace);
        if options.revisions.is_empty() {
            let at = resolve_or_wc(tx.repo(), &workspace_name, templates.prefixes(), None)?;
            plan_duplicate_ids(&tx, &templates, vec![at.id().clone()], &location)?
        } else {
            plan_duplicate(&tx, &templates, &options.revisions, &location)?
        }
    };
    warn_self_placement(&tx, &plan, ctx)?;

    let originals: Vec<Commit> = plan
        .to_duplicate
        .iter()
        .map(|id| tx.repo().store().get_commit(id).map_err(be))
        .collect::<Result<_, _>>()?;
    let descriptions = {
        let templates = Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, workspace);
        templates.duplicate_descriptions(tx.repo(), &originals, &mut ctx.warnings)?
    };
    let new_descriptions: HashMap<CommitId, String> = plan.to_duplicate.iter().cloned().zip(descriptions).collect();

    let DuplicateCommitsStats { duplicated_commits, .. } = match &plan.location {
        Some((parents, children)) => {
            // The Git backend refuses this write for a root merge; refused before it, after the
            // template parse — the CLI's order.
            refuse_git_root_merge(tx.repo().store(), parents)?;
            pollster::block_on(duplicate_commits(
                tx.repo_mut(),
                &plan.to_duplicate,
                &new_descriptions,
                parents,
                children,
            ))
        }
        None => pollster::block_on(duplicate_commits_onto_parents(
            tx.repo_mut(),
            &plan.to_duplicate,
            &new_descriptions,
        )),
    }
    .map_err(be)?;

    let description = format!("duplicate {} commit(s)", plan.to_duplicate.len());
    let finish = finish_verb(workspace, tx, &description, ctx)?;
    let new_change_ids = duplicated_commits
        .values()
        .map(|commit| ChangeId(commit.change_id().reverse_hex()))
        .collect();
    Ok(mutation_result(&finish, new_change_ids, Vec::new()))
}

#[cfg(test)]
mod tests {
    /// No location and `-A`: the arms `drop_actions`' `duplicate` row (always `-o`) never takes.
    /// The fixture is `root → Commit 1 → Commit 2 → Commit 3` plus an empty `@` off the root;
    /// `@ -A "Commit 1"` inserts the duplicate between Commit 1 and Commit 2, unless Commit 2 is immutable.
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

    /// A location with no parents warns nothing, as the CLI's `&& !parent_commit_ids.is_empty()`
    /// guard has it — `resolve_commit_location` refuses empty parents, so the verb never gets
    /// here. Without the guard, Commit 1 (a new child) being an ancestor of Commit 2 would warn.
    #[test]
    fn warn_self_placement_without_parents_warns_nothing() {
        use jj_lib::backend::CommitId;
        use jj_lib::repo::Repo as _;
        use jj_lib::working_copy::SnapshotStats;

        use crate::snapshot::VerbContext;
        use crate::warning::{WarningKind, Warnings};

        test_helpers::pin_test_env();
        let fixture = test_helpers::extract_fixture("tiny-3-commits").expect("fixture");
        let repo = crate::Repo::open(&fixture.path).expect("open");
        let name = repo.workspace().workspace_name().to_owned();
        let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("head");
        let store = readonly.store();
        let by_description = |description: &str| -> CommitId {
            let mut pending: Vec<CommitId> = readonly.view().heads().iter().cloned().collect();
            std::iter::from_fn(|| {
                let commit = store.get_commit(&pending.pop()?).expect("commit");
                pending.extend(commit.parent_ids().iter().cloned());
                Some(commit)
            })
            .find(|commit| commit.description().trim_end() == description)
            .map(|commit| commit.id().clone())
            .expect("no commit described")
        };
        let (c1, c2) = (by_description("Commit 1"), by_description("Commit 2"));
        let tx = crate::op_support::start_repo_transaction(&readonly, &name);
        let config = crate::config::load(&repo).expect("config");
        let mut sink = Warnings::default();
        let env = crate::snapshot::CommandEnv::load(repo.workspace(), &config, &mut sink).expect("start-up");
        let mut ctx = VerbContext::new(config, env, false, SnapshotStats::default(), sink);

        // Control: with a parent the same children warn — Commit 1 is an ancestor of Commit 2.
        let with_parent = super::DuplicatePlan {
            to_duplicate: vec![c2.clone()],
            location: Some((vec![store.root_commit_id().clone()], vec![c1.clone()])),
        };
        super::warn_self_placement(&tx, &with_parent, &mut ctx).expect("a parent");
        let kinds: Vec<WarningKind> = ctx.warnings.take().into_iter().map(|warning| warning.kind).collect();
        assert_eq!(kinds, [WarningKind::DuplicateAsOwnAncestor]);

        let plan = super::DuplicatePlan {
            to_duplicate: vec![c2],
            location: Some((vec![], vec![c1])),
        };
        super::warn_self_placement(&tx, &plan, &mut ctx).expect("no parents");
        assert!(ctx.warnings.take().is_empty(), "no warning without parents");
    }
}
