// SPDX-License-Identifier: MIT

//! `rebase.rs` — `jj rebase` (Story 9.16), ported step for step from `cmd_rebase`
//! (`cli/src/commands/rebase.rs:368-429` @ v0.46.0) over its plan fns `plan_rebase_revisions` /
//! `plan_rebase_source` / `plan_rebase_branch` / `check_rebase_destinations` (`:431-599`, Story
//! 9.31) and `tx_description` (`:601-615`), plus the CLI's "No revisions to rebase." / "Nothing
//! changed." answer for a planned move ([`rebase_is_no_op`]).
//!
//! The plan fns are pure: they resolve, check and return the `MoveCommitsLocation` jj-lib's
//! `compute_move_commits` takes, and write nothing. `drop_actions`' three rebase rows and the
//! verb ([`rebase`]) call the same fns, and the preview and the verb apply the move through the
//! one [`apply_move`], so a row and the verb cannot disagree. Every refusal is the CLI's
//! `user_error` text as [`MutateError::InvalidInput`]; the commit ids in it are the CLI's
//! `short_commit_hash`, 12 hex digits.
//!
//! Divergences, all deliberate: clap's argument rules become [`MutateError::InvalidInput`]
//! naming the flags, checked before anything resolves; the status lines (`Rebased N commits…`,
//! `Abandoned N divergent commits…`) are terminal UX and not ported — the abandonments are the
//! result's `abandoned_change_ids`.

use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::{BackendError, CommitId};
use jj_lib::commit::Commit;
use jj_lib::config::{ConfigLayer, ConfigSource};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{ReadonlyRepo, Repo as _, RepoLoader};
use jj_lib::revset::RevsetExpression;
use jj_lib::rewrite::{
    compute_move_commits, find_duplicate_divergent_commits, EmptyBehavior, MoveCommitsLocation, MoveCommitsTarget,
    RebaseOptions as JjRebaseOptions, RebasedCommit, RewriteRefsOptions,
};
use jj_lib::settings::UserSettings;
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::mutate::{
    be, finish_verb, guard_rewritable, mutation_result, no_op_result, resolve_or_wc, MutateError, MutationResult,
};
use crate::op_support::{
    resolve_commit_location, resolve_immutable, resolve_ordered, start_repo_transaction, LocationArgs, NO_LOCATION,
    ONTO_WITH_INSERT,
};
use crate::snapshot::VerbContext;
use crate::template::Templates;
use crate::ChangeId;

/// [`crate::Repo::rebase`]'s arguments — the CLI's `jj rebase` flags, one field each (Story
/// 9.16). An EMPTY list is a flag that was not given (clap cannot pass a flag with no values).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RebaseOptions {
    /// `-b/--branch`, repeatable: rebase the whole branch — the roots of `destination..branch`.
    /// With `source` and `revisions` empty too, the CLI's default `-b @`.
    pub branch: Vec<ChangeId>,
    /// `-s/--source`, repeatable: rebase these revisions with their descendants.
    pub source: Vec<ChangeId>,
    /// `-r/--revision`, repeatable: rebase only these revisions; their descendants move onto
    /// their parents.
    pub revisions: Vec<ChangeId>,
    /// `-o/--onto`, repeatable: the new parents. Excludes `insert_after`/`insert_before`.
    pub onto: Vec<ChangeId>,
    /// `-A/--insert-after`, repeatable.
    pub insert_after: Vec<ChangeId>,
    /// `-B/--insert-before`, repeatable.
    pub insert_before: Vec<ChangeId>,
    /// `--skip-emptied`: a rebased commit that becomes empty is abandoned (one that was empty
    /// before is kept).
    pub skip_emptied: bool,
    /// `--keep-divergent`: keep a divergent commit whose identical twin is already in the
    /// destination, instead of abandoning it.
    pub keep_divergent: bool,
    /// `--simplify-parents`: drop a rebased commit's parents that are ancestors of its other
    /// parents.
    pub simplify_parents: bool,
}

/// The refusal of more than one of `-b`/`-s`/`-r` — clap's `to_rebase` group (`rebase.rs:268`).
const ONE_TARGET_FLAG: &str = "only one of -b/--branch, -s/--source or -r/--revision can be given";

/// The noun `compute_commit_location`'s loop refusal names for every rebase form.
const REBASED_COMMITS: &str = "rebased commits";

/// `jj rebase -r <revisions> <location>`'s plan (`rebase.rs:431-471` @ v0.46.0): the revisions
/// resolved and checked rewritable, the location computed (`"rebased commits"`), then — with
/// `-o` — the refusal of a revision that is one of the new parents. The target is the revisions in
/// reverse topological order, as the CLI evaluates its revset.
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — a revision or a location id does not resolve.
/// - [`MutateError::Immutable`] — a revision, or a child the location would rewrite, is
///   immutable.
/// - [`MutateError::InvalidInput`] — `Cannot rebase <12 hex> onto itself`, or a location
///   refusal of `compute_commit_location` (the loop text among them).
/// - [`MutateError::Config`] — the `immutable_heads()` alias does not resolve.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
pub(crate) fn plan_rebase_revisions(
    tx: &Transaction,
    templates: &Templates<'_>,
    revisions: &[ChangeId],
    location: &LocationArgs<'_>,
) -> Result<MoveCommitsLocation, MutateError> {
    let ids = resolve_ordered(tx, Some(revisions))?.unwrap_or_default();
    guard_rewritable(tx, templates, &ids)?;
    // "in reverse topological order" (`rebase.rs:446`): the revset's own order.
    let set = RevsetExpression::commits(ids)
        .evaluate(tx.base_repo().as_ref())
        .map_err(be)?;
    let target_commit_ids: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    let (new_parent_ids, new_child_ids) = resolve_commit_location(tx, templates, location, REBASED_COMMITS)?;
    if !location.onto.is_empty() {
        if let Some(id) = target_commit_ids.iter().find(|id| new_parent_ids.contains(id)) {
            return Err(onto_itself(id));
        }
    }
    Ok(MoveCommitsLocation {
        new_parent_ids,
        new_child_ids,
        target: MoveCommitsTarget::Commits(target_commit_ids),
    })
}

/// `jj rebase -s <sources> <location>`'s plan (`rebase.rs:473-512` @ v0.46.0): the sources
/// resolved in argument order and checked rewritable, the location computed (`"rebased
/// commits"`), then — with `-o` — [`check_rebase_destinations`] for every source.
///
/// # Errors
///
/// As [`plan_rebase_revisions`], with [`check_rebase_destinations`]' two refusals in place of the
/// `onto itself` one.
pub(crate) fn plan_rebase_source(
    tx: &Transaction,
    templates: &Templates<'_>,
    sources: &[ChangeId],
    location: &LocationArgs<'_>,
) -> Result<MoveCommitsLocation, MutateError> {
    let source_ids = resolve_ordered(tx, Some(sources))?.unwrap_or_default();
    guard_rewritable(tx, templates, &source_ids)?;
    let (new_parent_ids, new_child_ids) = resolve_commit_location(tx, templates, location, REBASED_COMMITS)?;
    if !location.onto.is_empty() {
        for id in &source_ids {
            let commit = tx.base_repo().store().get_commit(id).map_err(be)?;
            check_rebase_destinations(tx.base_repo().as_ref(), &new_parent_ids, &commit)?;
        }
    }
    Ok(MoveCommitsLocation {
        new_parent_ids,
        new_child_ids,
        target: MoveCommitsTarget::Roots(source_ids),
    })
}

/// `jj rebase -b <branch> <location>`'s plan (`rebase.rs:514-561` @ v0.46.0): the branch
/// revisions resolved in argument order, the location computed (`"rebased commits"`), then the
/// roots of `new_parents..branch` — the commits the move rebases — checked rewritable and, with
/// `-o`, [`check_rebase_destinations`] for every root. The roots may be EMPTY (the branch is
/// already on the destination): the CLI's "No revisions to rebase.", which [`rebase_is_no_op`]
/// answers. The immutable set is resolved for the location only with `-A`/`-B`, whose children
/// the location rewrites. An empty `branch` plans an empty target: the CLI's `-b` default `@` is
/// the caller's to resolve and pass — the verb passes `@`'s commit ([`plan_rebase_branch_ids`]).
///
/// # Errors
///
/// As [`plan_rebase_source`]: the roots take the sources' place.
pub(crate) fn plan_rebase_branch(
    tx: &Transaction,
    templates: &Templates<'_>,
    branch: &[ChangeId],
    location: &LocationArgs<'_>,
) -> Result<MoveCommitsLocation, MutateError> {
    let branch_ids = resolve_ordered(tx, Some(branch))?.unwrap_or_default();
    plan_rebase_branch_ids(tx, templates, branch_ids, location)
}

/// [`plan_rebase_branch`] over already-resolved branch commits — the verb's `-b @` default
/// passes `@`'s commit itself (the CLI's `resolve_single_rev(@)`), never its change id, which a
/// divergent `@` would not resolve.
///
/// # Errors
///
/// As [`plan_rebase_branch`].
fn plan_rebase_branch_ids(
    tx: &Transaction,
    templates: &Templates<'_>,
    branch_ids: Vec<CommitId>,
    location: &LocationArgs<'_>,
) -> Result<MoveCommitsLocation, MutateError> {
    // WHY: keeps `rebase -b`'s refusal order (Config before an unresolvable location id); rebase
    // parses no template, so the CLI's order is not observable otherwise.
    if location.inserts() {
        resolve_immutable(tx.base_repo().as_ref(), templates.immutable())?;
    }
    let (new_parent_ids, new_child_ids) = resolve_commit_location(tx, templates, location, REBASED_COMMITS)?;
    let roots = RevsetExpression::commits(new_parent_ids.clone())
        .range(&RevsetExpression::commits(branch_ids))
        .roots()
        .evaluate(tx.base_repo().as_ref())
        .map_err(be)?;
    let root_ids: Vec<CommitId> = pollster::block_on(roots.stream().try_collect()).map_err(be)?;
    guard_rewritable(tx, templates, &root_ids)?;
    if !location.onto.is_empty() {
        for id in &root_ids {
            let commit = tx.base_repo().store().get_commit(id).map_err(be)?;
            check_rebase_destinations(tx.base_repo().as_ref(), &new_parent_ids, &commit)?;
        }
    }
    Ok(MoveCommitsLocation {
        new_parent_ids,
        new_child_ids,
        target: MoveCommitsTarget::Roots(root_ids),
    })
}

/// Refuses a new parent that is `commit` itself or one of its descendants
/// (`rebase.rs:565-585` @ v0.46.0), in `new_parents` order.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `Cannot rebase <12 hex> onto itself` or `Cannot rebase
///   <12 hex> onto descendant <12 hex>`.
/// - [`MutateError::Backend`] — an index read failed.
pub(crate) fn check_rebase_destinations(
    repo: &dyn jj_lib::repo::Repo,
    new_parents: &[CommitId],
    commit: &Commit,
) -> Result<(), MutateError> {
    for parent_id in new_parents {
        if parent_id == commit.id() {
            return Err(onto_itself(commit.id()));
        }
        if pollster::block_on(repo.index().is_ancestor(commit.id(), parent_id)).map_err(be)? {
            return Err(MutateError::invalid(format!(
                "Cannot rebase {:.12} onto descendant {parent_id:.12}",
                commit.id()
            )));
        }
    }
    Ok(())
}

/// The CLI's `Cannot rebase <12 hex> onto itself`.
fn onto_itself(id: &CommitId) -> MutateError {
    MutateError::invalid(format!("Cannot rebase {id:.12} onto itself"))
}

/// Whether the rebase `loc` plans would write no operation: an empty target is the CLI's "No
/// revisions to rebase." (`cmd_rebase`, `rebase.rs:395-399` @ v0.46.0), answered before anything
/// is computed; otherwise the CLI's "Nothing changed." guard (`cli_util.rs:2851`) after
/// [`apply_move`] with the CLI's default options (no `--skip-emptied`, no `--keep-divergent`, no
/// `--simplify-parents`). Exact by construction: it is the move the verb runs.
///
/// The move is applied to `tx`, which the caller drops afterwards. `tx` must start from a head
/// loaded by [`load_dry_run_head`] (`signing.behavior = "drop"`): a preview must never invoke the
/// user's signer for commits it throws away.
///
/// # Errors
///
/// As [`apply_move`].
pub(crate) fn rebase_is_no_op(tx: &mut Transaction, loc: &MoveCommitsLocation) -> Result<bool, MutateError> {
    if target_ids(loc).is_empty() {
        return Ok(true);
    }
    apply_move(tx, loc, &jj_rebase_options(&RebaseOptions::default()), false)?;
    Ok(!tx.repo().has_changes())
}

/// The commits `loc` moves — the CLI's `target_ids` (`rebase.rs:390-393`).
fn target_ids(loc: &MoveCommitsLocation) -> &[CommitId] {
    let (MoveCommitsTarget::Commits(ids) | MoveCommitsTarget::Roots(ids)) = &loc.target;
    ids
}

/// jj-lib's options for the CLI's three flags (`rebase.rs:374-383` @ v0.46.0); bookmarks of an
/// abandoned commit are never deleted.
fn jj_rebase_options(options: &RebaseOptions) -> JjRebaseOptions {
    JjRebaseOptions {
        empty: if options.skip_emptied {
            EmptyBehavior::AbandonNewlyEmpty
        } else {
            EmptyBehavior::Keep
        },
        rewrite_refs: RewriteRefsOptions {
            delete_abandoned_bookmarks: false,
        },
        simplify_ancestor_merge: options.simplify_parents,
    }
}

/// `cmd_rebase`'s move (`rebase.rs:402-424` @ v0.46.0), on `tx`: jj-lib's
/// `compute_move_commits`; unless `keep_divergent`, the divergent duplicates already in the
/// destination recorded to abandon; then `apply` with `options`. Shared by the verb and
/// [`rebase_is_no_op`], so preview and execution apply the same move.
///
/// Returns the commits the move abandoned: the divergent duplicates (in jj-lib's order), then the
/// newly emptied ones (`--skip-emptied`), ordered by commit id.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — the backend refuses a commit of the move as unsupported
///   (the Git backend's "…merge commits with the root commit as one of the parents."), its text
///   verbatim: the CLI reports it as a user error.
/// - [`MutateError::Backend`] — any other jj-lib failure.
pub(crate) fn apply_move(
    tx: &mut Transaction,
    loc: &MoveCommitsLocation,
    options: &JjRebaseOptions,
    keep_divergent: bool,
) -> Result<Vec<Commit>, MutateError> {
    let mut computed = pollster::block_on(compute_move_commits(tx.repo(), loc)).map_err(unsupported)?;
    let mut abandoned = Vec::new();
    if !keep_divergent {
        abandoned = pollster::block_on(find_duplicate_divergent_commits(
            tx.repo(),
            &loc.new_parent_ids,
            &loc.target,
        ))
        .map_err(unsupported)?;
        computed.record_to_abandon(abandoned.iter().map(Commit::id).cloned());
    }
    let stats = pollster::block_on(computed.apply(tx.repo_mut(), options)).map_err(unsupported)?;
    let mut emptied: Vec<&CommitId> = stats
        .rebased_commits
        .iter()
        .filter(|(_, rebased)| matches!(rebased, RebasedCommit::Abandoned { .. }))
        .map(|(id, _)| id)
        .collect();
    emptied.sort();
    for id in emptied {
        abandoned.push(tx.repo().store().get_commit(id).map_err(be)?);
    }
    Ok(abandoned)
}

/// The operation description — `tx_description` (`rebase.rs:601-615` @ v0.46.0), full hex ids.
fn tx_description(target: &MoveCommitsTarget) -> String {
    match target {
        MoveCommitsTarget::Commits(ids) => match &ids[..] {
            [] => format!("rebase {} commits", ids.len()),
            [id] => format!("rebase commit {}", id.hex()),
            [first, others @ ..] => format!("rebase commit {} and {} more", first.hex(), others.len()),
        },
        MoveCommitsTarget::Roots(ids) => match &ids[..] {
            [id] => format!("rebase commit {} and descendants", id.hex()),
            _ => format!("rebase {} commits and their descendants", ids.len()),
        },
    }
}

/// Refuses what clap refuses, before the pre-verb snapshot ([`crate::Repo::rebase`]): more than
/// one of `-b`/`-s`/`-r` (the `to_rebase` group), `-o` together with `-A`/`-B`, or none of the
/// three location flags (the required `RebaseDestinationArgs` group) — the location texts are
/// `compute_commit_location`'s, as `drop_actions` refuses them.
///
/// # Errors
///
/// [`MutateError::InvalidInput`] naming the conflicting flags.
pub(crate) fn check_rebase_args(options: &RebaseOptions) -> Result<(), MutateError> {
    let given = [&options.branch, &options.source, &options.revisions]
        .iter()
        .filter(|ids| !ids.is_empty())
        .count();
    if given > 1 {
        return Err(MutateError::invalid(ONE_TARGET_FLAG));
    }
    let inserts = !options.insert_after.is_empty() || !options.insert_before.is_empty();
    match (options.onto.is_empty(), inserts) {
        (false, true) => Err(MutateError::invalid(ONTO_WITH_INSERT)),
        (true, false) => Err(MutateError::invalid(NO_LOCATION)),
        _ => Ok(()),
    }
}

/// `jj rebase` (Story 9.16) — see [`crate::Repo::rebase`], which ran [`check_rebase_args`]
/// before the snapshot: the plan of the given form (`-b @` when none), "No revisions to rebase."
/// for an empty target, [`apply_move`] with the caller's flags, the "Nothing changed." gate,
/// then the finish with the CLI's description.
///
/// # Errors
///
/// See [`crate::Repo::rebase`].
pub(crate) fn rebase(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &RebaseOptions,
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let old_wc_id = readonly.view().get_wc_commit_id(&workspace_name).cloned();

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let location = LocationArgs {
        onto: &options.onto,
        insert_after: &options.insert_after,
        insert_before: &options.insert_before,
    };
    let loc = {
        let templates = ctx.templates(workspace);
        if !options.revisions.is_empty() {
            plan_rebase_revisions(&tx, &templates, &options.revisions, &location)?
        } else if !options.source.is_empty() {
            plan_rebase_source(&tx, &templates, &options.source, &location)?
        } else if !options.branch.is_empty() {
            plan_rebase_branch(&tx, &templates, &options.branch, &location)?
        } else {
            let at = resolve_or_wc(tx.repo(), &workspace_name, None)?;
            plan_rebase_branch_ids(&tx, &templates, vec![at.id().clone()], &location)?
        }
    };
    // "No revisions to rebase." (`rebase.rs:394-401`): nothing is computed or written.
    if target_ids(&loc).is_empty() {
        drop(tx);
        return no_op_result(&workspace_name, &readonly);
    }
    let abandoned = apply_move(&mut tx, &loc, &jj_rebase_options(options), options.keep_divergent)?;
    // `WorkspaceCommandTransaction::finish`'s "Nothing changed." guard (`cli_util.rs:2852`).
    if !tx.repo().has_changes() {
        drop(tx);
        return no_op_result(&workspace_name, &readonly);
    }
    let finish = finish_verb(workspace, tx, &tx_description(&loc.target), ctx)?;
    let wc_abandoned = old_wc_id
        .as_ref()
        .is_some_and(|id| abandoned.iter().any(|c| c.id() == id));
    let new_change_ids = match (&finish.wc_commit, wc_abandoned) {
        (Some(new_wc_commit), true) => vec![ChangeId(new_wc_commit.change_id().reverse_hex())],
        _ => Vec::new(),
    };
    let abandoned_change_ids = abandoned
        .iter()
        .map(|c| ChangeId(c.change_id().reverse_hex()))
        .collect();
    Ok(mutation_result(&finish, new_change_ids, abandoned_change_ids))
}

/// The repo's head operation loaded through `workspace`'s stores with [`dry_run_settings`],
/// once per query: every transaction started from it writes its commits unsigned. The head is
/// resolved through the workspace's OWN loader first — divergent heads reconciled as the CLI
/// reconciles them, in this workspace and with its real settings (a reconcile that rebases
/// descendants must not drop their signatures) — and only then loaded with the preview settings.
///
/// # Errors
///
/// - [`MutateError::Backend`] — the settings could not be built or the head could not be loaded.
pub(crate) fn load_dry_run_head(workspace: &Workspace) -> Result<Arc<ReadonlyRepo>, MutateError> {
    let head = crate::snapshot::reload_head(workspace).map_err(be)?;
    let loader = workspace.repo_loader();
    let preview = RepoLoader::new(
        dry_run_settings(loader.settings())?,
        loader.store().clone(),
        loader.workspace_store().clone(),
        loader.op_store().clone(),
        loader.op_heads_store().clone(),
        loader.index_store().clone(),
        loader.submodule_store().clone(),
    );
    pollster::block_on(preview.load_at(head.operation())).map_err(be)
}

/// `settings` with `signing.behavior = "drop"` layered on top, so `sign_settings().should_sign`
/// is false for every commit a dry run writes.
///
/// # Errors
///
/// - [`MutateError::Backend`] — the layer or the settings could not be built.
pub(crate) fn dry_run_settings(settings: &UserSettings) -> Result<UserSettings, MutateError> {
    let mut config = settings.config().clone();
    let mut layer = ConfigLayer::empty(ConfigSource::CommandArg);
    layer.set_value("signing.behavior", "drop").map_err(be)?;
    config.add_layer(layer);
    settings.with_new_config(config).map_err(be)
}

/// A backend's `Unsupported` refusal as the user error the CLI reports it as; anything else is a
/// jj-lib failure.
fn unsupported(e: BackendError) -> MutateError {
    match e {
        BackendError::Unsupported(reason) => MutateError::invalid(reason),
        e => be(e),
    }
}

#[cfg(test)]
mod tests {
    use jj_lib::config::{ConfigLayer, ConfigSource};
    use jj_lib::settings::SignBehavior;

    use super::dry_run_settings;

    #[test]
    fn dry_run_settings_drop_signing_even_when_the_config_signs_own() {
        let base = test_helpers::test_settings();
        let mut config = base.config().clone();
        let mut layer = ConfigLayer::empty(ConfigSource::Repo);
        layer.set_value("signing.behavior", "own").expect("own");
        config.add_layer(layer);
        let own = base.with_new_config(config).expect("settings");
        assert_eq!(own.sign_settings().behavior, SignBehavior::Own);

        let dry = dry_run_settings(&own).expect("dry-run settings");
        assert_eq!(dry.sign_settings().behavior, SignBehavior::Drop);
    }

    /// `-s` and `-b` with `-A`: `-b`'s only arm that resolves the immutable set for the location,
    /// and the one `-s` arm that skips the `-o` destination checks (the drop rows use `-s`/`-b` at
    /// `onto` only). The fixture is `root → Commit 1 → Commit 2 → Commit 3` plus an empty `@` off
    /// the root; `-s @ -A "Commit 1"` and `-b @ -A "Commit 1"` insert `@` above Commit 2, unless
    /// Commit 2 is immutable.
    #[test]
    fn plan_rebase_source_and_branch_with_an_insert_location_check_the_children() {
        use std::sync::Arc;

        use jj_lib::backend::CommitId;
        use jj_lib::object_id::ObjectId as _;
        use jj_lib::repo::Repo as _;
        use jj_lib::revset::{RevsetExpression, UserRevsetExpression};
        use jj_lib::rewrite::{MoveCommitsLocation, MoveCommitsTarget};
        use jj_lib::transaction::Transaction;

        use crate::mutate::MutateError;
        use crate::op_support::LocationArgs;
        use crate::template::Templates;

        type Plan = fn(
            &Transaction,
            &Templates<'_>,
            &[crate::ChangeId],
            &LocationArgs<'_>,
        ) -> Result<MoveCommitsLocation, MutateError>;

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
        let after = [change(&c1)];
        let location = LocationArgs {
            onto: &[],
            insert_after: &after,
            insert_before: &[],
        };
        let tx = crate::op_support::start_repo_transaction(&readonly, &name);
        let config = crate::config::load(&repo).expect("config");
        let env =
            crate::snapshot::CommandEnv::load(repo.workspace(), &config, &mut crate::warning::Warnings::default())
                .expect("start-up");
        let root: Arc<UserRevsetExpression> = RevsetExpression::root();
        let immutable: Arc<UserRevsetExpression> = RevsetExpression::commits(vec![c2.id().clone()]);
        let mutable_all = Templates::new(&config, &root, &env.template_startup, repo.workspace());
        let c2_immutable = Templates::new(&config, &immutable, &env.template_startup, repo.workspace());

        let plans: [(&str, Plan); 2] = [("-s", super::plan_rebase_source), ("-b", super::plan_rebase_branch)];
        for (flag, plan) in plans {
            let loc = plan(&tx, &mutable_all, &[change(&at)], &location).expect(flag);
            assert_eq!(loc.new_parent_ids, [c1.id().clone()], "{flag}");
            assert_eq!(loc.new_child_ids, [c2.id().clone()], "{flag}");
            assert!(
                matches!(&loc.target, MoveCommitsTarget::Roots(roots) if roots == &[at.id().clone()]),
                "{flag}"
            );

            let refused = plan(&tx, &c2_immutable, &[change(&at)], &location);
            assert!(
                matches!(&refused, Err(MutateError::Immutable { commit_id, .. }) if *commit_id == c2.id().hex()),
                "{flag}: {refused:?}"
            );
        }
    }

    /// `tx_description`'s five shapes, as the CLI writes them (`rebase.rs:601-615` @ v0.46.0).
    #[test]
    fn tx_description_names_the_target_as_the_cli_does() {
        use jj_lib::backend::CommitId;
        use jj_lib::rewrite::MoveCommitsTarget;

        let a = CommitId::from_hex("aa");
        let b = CommitId::from_hex("bb");
        let c = CommitId::from_hex("cc");
        let describe = |target: MoveCommitsTarget| super::tx_description(&target);
        assert_eq!(describe(MoveCommitsTarget::Commits(vec![])), "rebase 0 commits");
        assert_eq!(
            describe(MoveCommitsTarget::Commits(vec![a.clone()])),
            "rebase commit aa"
        );
        assert_eq!(
            describe(MoveCommitsTarget::Commits(vec![a.clone(), b.clone(), c])),
            "rebase commit aa and 2 more"
        );
        assert_eq!(
            describe(MoveCommitsTarget::Roots(vec![a.clone()])),
            "rebase commit aa and descendants"
        );
        assert_eq!(
            describe(MoveCommitsTarget::Roots(vec![a, b])),
            "rebase 2 commits and their descendants"
        );
    }

    /// clap's rules, refused before anything resolves — the ids need not exist.
    #[test]
    fn check_rebase_args_refuses_what_clap_refuses() {
        use super::{check_rebase_args, RebaseOptions, ONE_TARGET_FLAG};
        use crate::mutate::MutateError;
        use crate::op_support::{NO_LOCATION, ONTO_WITH_INSERT};
        use crate::ChangeId;

        let id = || vec![ChangeId("zz".to_owned())];
        let reason = |options: RebaseOptions| {
            check_rebase_args(&options).err().map(|e| {
                assert!(matches!(&e, MutateError::InvalidInput { hints, .. } if hints.is_empty()));
                e.to_string().replacen("invalid input: ", "", 1)
            })
        };
        let onto = RebaseOptions {
            onto: id(),
            ..RebaseOptions::default()
        };
        assert_eq!(reason(onto.clone()), None, "-b @ -o X");
        for (branch, source, revisions) in [(true, true, false), (true, false, true), (false, true, true)] {
            let options = RebaseOptions {
                branch: if branch { id() } else { vec![] },
                source: if source { id() } else { vec![] },
                revisions: if revisions { id() } else { vec![] },
                ..onto.clone()
            };
            assert_eq!(reason(options).as_deref(), Some(ONE_TARGET_FLAG));
        }
        assert_eq!(
            reason(RebaseOptions {
                revisions: id(),
                ..RebaseOptions::default()
            })
            .as_deref(),
            Some(NO_LOCATION)
        );
        for (after, before) in [(true, false), (false, true)] {
            let options = RebaseOptions {
                insert_after: if after { id() } else { vec![] },
                insert_before: if before { id() } else { vec![] },
                ..onto.clone()
            };
            assert_eq!(reason(options).as_deref(), Some(ONTO_WITH_INSERT));
        }
        assert_eq!(
            reason(RebaseOptions {
                insert_after: id(),
                insert_before: id(),
                ..RebaseOptions::default()
            }),
            None,
            "-A and -B together"
        );
    }

    #[test]
    fn unsupported_is_the_backends_text_as_invalid_input() {
        use jj_lib::backend::BackendError;

        use crate::mutate::MutateError;
        let refused = super::unsupported(BackendError::Unsupported("no".to_owned()));
        assert!(matches!(refused, MutateError::InvalidInput { reason, .. } if reason == "no"));
        let other = super::unsupported(BackendError::Other("x".into()));
        assert!(matches!(other, MutateError::Backend(_)));
    }
}
