// SPDX-License-Identifier: MIT

//! `revert.rs` — `jj revert` (Story 9.18), ported step for step from `cmd_revert`
//! (`cli/src/commands/revert.rs` @ v0.46.0). Its plan phase (Story 9.31 follow-on) — the
//! revisions in reverse topological order, then the location — is [`plan_revert`], which
//! `drop_actions`' `revert` rows call too; the verb ([`revert`]) runs the same fn before its
//! write, so the preview and the verb agree by construction. After the plan the verb renders
//! `templates.revert_description` on each reverted commit, writes each reverse commit — a 3-way
//! merge of the destination, the reverted tree and its parents' tree — chained one onto the
//! other, and rebases the location's children onto the last one.
//!
//! Divergence, deliberate: the status lines (`Reverted N commits as follows:`, `Rebased N
//! descendant commits.`) are terminal UX and not ported; the reverse commits' change ids are the
//! result's `new_change_ids`.

use std::collections::HashSet;

use futures::TryStreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::commit::{conflict_label_for_commits, Commit};
use jj_lib::merge::Merge;
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId;
use jj_lib::repo::Repo as _;
use jj_lib::revset::RevsetExpression;
use jj_lib::rewrite::{merge_commit_trees, CommitRewriter};
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::mutate::{
    be, finish_verb, mutation_result, no_op_result, refuse_git_root_merge, MutateError, MutationResult,
};
use crate::op_support::{
    resolve_commit_location, resolve_ordered, start_repo_transaction, LocationArgs, NO_LOCATION, ONTO_WITH_INSERT,
};
use crate::snapshot::VerbContext;
use crate::template::Templates;
use crate::ChangeId;

/// [`crate::Repo::revert`]'s arguments — the CLI's `jj revert` flags, one field each (Story
/// 9.18). An EMPTY location list is a flag that was not given.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RevertOptions {
    /// The revisions to apply the reverse of (`-r`, required).
    pub revisions: Vec<ChangeId>,
    /// `-o/--onto`, repeatable: the first reverse commit's parents. Excludes
    /// `insert_after`/`insert_before`.
    pub onto: Vec<ChangeId>,
    /// `-A/--insert-after`, repeatable.
    pub insert_after: Vec<ChangeId>,
    /// `-B/--insert-before`, repeatable.
    pub insert_before: Vec<ChangeId>,
}

/// What [`plan_revert`] decided.
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
/// no operation) — then the location (`"reverted commits"`). The plan resolves the immutable set
/// only where the CLI's `compute_commit_location` does: for a location with children, which it
/// rewrites (the reverted commits themselves are never rewritten). Otherwise the verb parses
/// `templates.revert_description` first and its finish resolves the set, the CLI's order (Story
/// 9.18 closing run). Two or more location parents with the root among them refuse up
/// front on a Git-backed store, with the backend's own text — the CLI reaches it at the first
/// reverted commit's write.
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — a revision or a location id does not resolve.
/// - [`MutateError::InvalidInput`] — a location refusal of `compute_commit_location` (the loop
///   text among them), or (Git backend) a root merge as the location's parents.
/// - [`MutateError::Immutable`] — a child the location would rewrite is immutable.
/// - [`MutateError::Config`] — (a location with children) the `immutable_heads()` alias does not
///   resolve.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
pub(crate) fn plan_revert(
    tx: &Transaction,
    templates: &Templates<'_>,
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
    let (new_parent_ids, new_child_ids) = resolve_commit_location(tx, templates, location, "reverted commits")?;
    // The Git backend refuses the first reverted commit's write for a root merge; refused up
    // front so the preview and the verb agree (Story 9.31).
    refuse_git_root_merge(tx.repo().store(), &new_parent_ids)?;
    Ok(Some(RevertPlan {
        to_revert,
        new_parent_ids,
        new_child_ids,
    }))
}

/// Refuses what clap refuses, before the pre-verb snapshot ([`crate::Repo::revert`]), in clap's
/// validation order (conflicts before required arguments): `onto` together with
/// `insert_after`/`insert_before` (`conflicts_with = "onto"`), then no revision (`-r` is
/// `required = true`), then none of the three location flags (the required `location` group) —
/// the location texts are `compute_commit_location`'s, as `drop_actions` refuses them.
///
/// # Errors
///
/// [`MutateError::InvalidInput`] naming the missing or conflicting flags.
pub(crate) fn check_revert_args(options: &RevertOptions) -> Result<(), MutateError> {
    let inserts = !options.insert_after.is_empty() || !options.insert_before.is_empty();
    if !options.onto.is_empty() && inserts {
        return Err(MutateError::invalid(ONTO_WITH_INSERT));
    }
    if options.revisions.is_empty() {
        return Err(MutateError::invalid("revert requires at least one revision"));
    }
    if options.onto.is_empty() && !inserts {
        return Err(MutateError::invalid(NO_LOCATION));
    }
    Ok(())
}

/// The CLI's op description: `revert commit <hex>`, or `revert commit <hex> and <n-1> more`.
fn op_description(to_revert: &[CommitId]) -> String {
    let first = to_revert.first().map(ObjectId::hex).unwrap_or_default();
    match to_revert.len() {
        1 => format!("revert commit {first}"),
        n => format!("revert commit {first} and {} more", n - 1),
    }
}

/// Writes the reverse of each of `commits` (`revert.rs:149-201` @ v0.46.0), chained: the first
/// onto the plan's parents, each later one onto the previous. Returns the reverse commits in
/// creation order and the loop's final parent ids — the heads the location's children move onto.
fn write_reverse_commits(
    tx: &mut Transaction,
    plan: &RevertPlan,
    commits: &[Commit],
    descriptions: &[String],
) -> Result<(Vec<Commit>, Vec<CommitId>), MutateError> {
    let new_parents: Vec<Commit> = plan
        .new_parent_ids
        .iter()
        .map(|id| tx.repo().store().get_commit(id).map_err(be))
        .collect::<Result<_, _>>()?;
    let mut new_base_tree = pollster::block_on(merge_commit_trees(tx.repo(), &new_parents)).map_err(be)?;
    let mut parent_ids = plan.new_parent_ids.clone();
    let mut parent_labels = conflict_label_for_commits(&new_parents);
    let mut reverted = Vec::with_capacity(commits.len());
    for (commit, description) in commits.iter().zip(descriptions) {
        let old_parents = pollster::block_on(commit.parents()).map_err(be)?;
        let old_base_tree = pollster::block_on(commit.parent_tree(tx.repo())).map_err(be)?;
        let new_tree = pollster::block_on(MergedTree::merge(Merge::from_vec(vec![
            (new_base_tree, format!("{parent_labels} (revert destination)")),
            (
                commit.tree(),
                format!("{} (reverted revision)", commit.conflict_label()),
            ),
            (
                old_base_tree,
                format!(
                    "{} (parents of reverted revision)",
                    conflict_label_for_commits(&old_parents)
                ),
            ),
        ])))
        .map_err(be)?;
        let new_commit = pollster::block_on(
            tx.repo_mut()
                .new_commit(parent_ids, new_tree.clone())
                .set_description(description)
                .write(),
        )
        .map_err(be)?;
        parent_ids = vec![new_commit.id().clone()];
        parent_labels = new_commit.conflict_label();
        new_base_tree = new_tree;
        reverted.push(new_commit);
    }
    Ok((reverted, parent_ids))
}

/// Rebases the location's children onto `head_ids` (`revert.rs:203-232` @ v0.46.0): a child's
/// parents among the location's ORIGINAL parents are replaced by the heads, the heads are added
/// when absent (insertion order, the CLI's `IndexSet`); every other descendant is rebased.
fn rebase_new_children(tx: &mut Transaction, plan: &RevertPlan, head_ids: &[CommitId]) -> Result<(), MutateError> {
    let original_parents: HashSet<&CommitId> = plan.new_parent_ids.iter().collect();
    let children: HashSet<&CommitId> = plan.new_child_ids.iter().collect();
    pollster::block_on(tx.repo_mut().transform_descendants(
        plan.new_child_ids.clone(),
        async |mut rewriter: CommitRewriter<'_>| {
            if children.contains(rewriter.old_commit().id()) {
                let mut new_parents: Vec<CommitId> = Vec::new();
                let mut add = |id: &CommitId| {
                    if !new_parents.contains(id) {
                        new_parents.push(id.clone());
                    }
                };
                for old_parent in rewriter.old_commit().parent_ids() {
                    if original_parents.contains(old_parent) {
                        head_ids.iter().for_each(&mut add);
                    } else {
                        add(old_parent);
                    }
                }
                head_ids.iter().for_each(&mut add);
                rewriter.set_new_parents(new_parents);
            }
            rewriter.rebase().await?.write().await?;
            Ok(())
        },
    ))
    .map_err(be)
}

/// `jj revert` (Story 9.18) — see [`crate::Repo::revert`], which ran [`check_revert_args`]
/// before the snapshot: [`plan_revert`] ("No revisions to revert." writes nothing),
/// `templates.revert_description` on every reverted commit, the reverse commits, the children's
/// rebase, then the finish with the CLI's `revert commit <hex>[ and <n> more]`.
///
/// # Errors
///
/// See [`crate::Repo::revert`].
pub(crate) fn revert(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &RevertOptions,
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let location = LocationArgs {
        onto: &options.onto,
        insert_after: &options.insert_after,
        insert_before: &options.insert_before,
    };
    let plan = plan_revert(&tx, &ctx.templates(workspace), &options.revisions, &location)?;
    let Some(plan) = plan else {
        // "No revisions to revert."
        drop(tx);
        return no_op_result(&workspace_name, &readonly);
    };
    let description = op_description(&plan.to_revert);

    let commits: Vec<Commit> = plan
        .to_revert
        .iter()
        .map(|id| tx.repo().store().get_commit(id).map_err(be))
        .collect::<Result<_, _>>()?;
    let descriptions = {
        let templates = Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, workspace);
        templates.revert_descriptions(tx.base_repo().as_ref(), &commits, &mut ctx.warnings)?
    };

    let (reverted, head_ids) = write_reverse_commits(&mut tx, &plan, &commits, &descriptions)?;
    rebase_new_children(&mut tx, &plan, &head_ids)?;

    let finish = finish_verb(workspace, tx, &description, ctx)?;
    let new_change_ids = reverted
        .iter()
        .map(|commit| ChangeId(commit.change_id().reverse_hex()))
        .collect();
    Ok(mutation_result(&finish, new_change_ids, Vec::new()))
}

#[cfg(test)]
mod tests {
    use jj_lib::backend::CommitId;
    use jj_lib::repo::Repo as _;

    use super::{check_revert_args, op_description, plan_revert, RevertOptions};
    use crate::mutate::MutateError;
    use crate::op_support::{LocationArgs, NO_LOCATION, ONTO_WITH_INSERT};

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
        let config = crate::config::load(&repo).expect("config");
        let env =
            crate::snapshot::CommandEnv::load(repo.workspace(), &config, &mut crate::warning::Warnings::default())
                .expect("start-up");
        let templates =
            crate::template::Templates::new(&config, &env.immutable, &env.template_startup, repo.workspace());
        assert!(plan_revert(&tx, &templates, &[], &location).expect("plan").is_none());
    }

    /// The verb maps "No revisions to revert." to the house no-op result: no operation, the
    /// head it loaded, no new change. `Repo::revert` refuses empty revisions before getting here.
    #[test]
    fn the_verb_writes_nothing_without_revisions() {
        use jj_lib::object_id::ObjectId as _;
        use jj_lib::working_copy::SnapshotStats;

        use crate::snapshot::VerbContext;
        use crate::warning::Warnings;

        test_helpers::pin_test_env();
        let fixture = test_helpers::extract_fixture("tiny-3-commits").expect("fixture");
        let mut repo = crate::Repo::open(&fixture.path).expect("open");
        let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("head");
        let root = crate::ChangeId(readonly.store().root_commit().change_id().reverse_hex());
        let config = crate::config::load(&repo).expect("config");
        let mut sink = Warnings::default();
        let env = crate::snapshot::CommandEnv::load(repo.workspace(), &config, &mut sink).expect("start-up");
        let mut ctx = VerbContext::new(config, env, false, SnapshotStats::default(), sink);
        let options = RevertOptions {
            onto: vec![root],
            ..RevertOptions::default()
        };
        let result = super::revert(repo.workspace_mut(), &mut ctx, &options).expect("no-op");
        assert_eq!(result.new_op_id.0, readonly.op_id().hex());
        assert!(result.new_change_ids.is_empty());
    }

    /// clap's refusals, in its order (conflicts before required arguments): `-o` with `-A`/`-B`
    /// — even without `-r` — then the required `-r`, then the required location group.
    #[test]
    fn check_revert_args_refuses_what_clap_refuses() {
        let id = || vec![crate::ChangeId("x".to_owned())];
        let message = |options: &RevertOptions| {
            check_revert_args(options).err().map(|e| {
                assert!(matches!(&e, MutateError::InvalidInput { hints, .. } if hints.is_empty()));
                e.to_string().replacen("invalid input: ", "", 1)
            })
        };
        let no_revision = RevertOptions {
            onto: id(),
            ..RevertOptions::default()
        };
        assert_eq!(
            message(&no_revision).as_deref(),
            Some("revert requires at least one revision")
        );
        let both = RevertOptions {
            revisions: id(),
            onto: id(),
            insert_before: id(),
            ..RevertOptions::default()
        };
        assert_eq!(message(&both).as_deref(), Some(ONTO_WITH_INSERT));
        let both_without_revision = RevertOptions {
            revisions: Vec::new(),
            ..both
        };
        assert_eq!(message(&both_without_revision).as_deref(), Some(ONTO_WITH_INSERT));
        let nowhere = RevertOptions {
            revisions: id(),
            ..RevertOptions::default()
        };
        assert_eq!(message(&nowhere).as_deref(), Some(NO_LOCATION));
        for ok in [
            RevertOptions {
                revisions: id(),
                insert_after: id(),
                insert_before: id(),
                ..RevertOptions::default()
            },
            RevertOptions {
                revisions: id(),
                onto: id(),
                ..RevertOptions::default()
            },
        ] {
            assert_eq!(message(&ok), None);
        }
    }

    /// `revert commit <hex>` for one, `revert commit <first hex> and <n-1> more` for more.
    #[test]
    fn op_description_has_the_clis_shape() {
        let a = CommitId::new(vec![0xab; 20]);
        let b = CommitId::new(vec![0xcd; 20]);
        let hex = "ab".repeat(20);
        assert_eq!(op_description(std::slice::from_ref(&a)), format!("revert commit {hex}"));
        assert_eq!(
            op_description(&[a.clone(), b.clone(), b]),
            format!("revert commit {hex} and 2 more")
        );
    }
}
