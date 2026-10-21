// SPDX-License-Identifier: MIT

//! `rebase.rs` — the plan phase of `jj rebase -r`, `-s` and `-b` (Story 9.31), ported from
//! `plan_rebase_revisions` / `plan_rebase_source` / `plan_rebase_branch` /
//! `check_rebase_destinations` (`cli/src/commands/rebase.rs:431-599` @ v0.46.0), plus the CLI's
//! "No revisions to rebase." / "Nothing changed." answer for a planned move
//! ([`rebase_is_no_op`]).
//!
//! The fns are pure: they resolve, check and return the `MoveCommitsLocation` jj-lib's
//! `compute_move_commits` takes, and write nothing. `drop_actions`' three rebase rows call them
//! today; the rebase verb (Story 9.16) is meant to call the same fns. Every refusal is the CLI's
//! `user_error` text as [`MutateError::InvalidInput`]; the commit ids in it are the CLI's
//! `short_commit_hash`, 12 hex digits.

use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::{BackendError, CommitId};
use jj_lib::commit::Commit;
use jj_lib::config::{ConfigLayer, ConfigSource};
use jj_lib::repo::{ReadonlyRepo, Repo as _, RepoLoader};
use jj_lib::revset::{RevsetExpression, UserRevsetExpression};
use jj_lib::rewrite::{
    compute_move_commits, find_duplicate_divergent_commits, EmptyBehavior, MoveCommitsLocation, MoveCommitsTarget,
    RebaseOptions, RewriteRefsOptions,
};
use jj_lib::settings::UserSettings;
use jj_lib::transaction::Transaction;

use crate::mutate::{be, guard_rewritable, MutateError};
use crate::op_support::{resolve_commit_location, resolve_immutable, resolve_ordered, LocationArgs};
use crate::ChangeId;

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
    immutable: &Arc<UserRevsetExpression>,
    revisions: &[ChangeId],
    location: &LocationArgs<'_>,
) -> Result<MoveCommitsLocation, MutateError> {
    let ids = resolve_ordered(tx, Some(revisions))?.unwrap_or_default();
    let resolved = guard_rewritable(tx, immutable, &ids)?;
    // "in reverse topological order" (`rebase.rs:446`): the revset's own order.
    let set = RevsetExpression::commits(ids)
        .evaluate(tx.base_repo().as_ref())
        .map_err(be)?;
    let target_commit_ids: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    let (new_parent_ids, new_child_ids) = resolve_commit_location(tx, &resolved, location, REBASED_COMMITS)?;
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
    immutable: &Arc<UserRevsetExpression>,
    sources: &[ChangeId],
    location: &LocationArgs<'_>,
) -> Result<MoveCommitsLocation, MutateError> {
    let source_ids = resolve_ordered(tx, Some(sources))?.unwrap_or_default();
    let resolved = guard_rewritable(tx, immutable, &source_ids)?;
    let (new_parent_ids, new_child_ids) = resolve_commit_location(tx, &resolved, location, REBASED_COMMITS)?;
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
/// the caller's to resolve and pass, as the rebase verb (Story 9.16) must.
///
/// # Errors
///
/// As [`plan_rebase_source`]: the roots take the sources' place.
pub(crate) fn plan_rebase_branch(
    tx: &Transaction,
    immutable: &Arc<UserRevsetExpression>,
    branch: &[ChangeId],
    location: &LocationArgs<'_>,
) -> Result<MoveCommitsLocation, MutateError> {
    let branch_ids = resolve_ordered(tx, Some(branch))?.unwrap_or_default();
    let resolved = if location.inserts() {
        resolve_immutable(tx.base_repo().as_ref(), immutable)?
    } else {
        RevsetExpression::none()
    };
    let (new_parent_ids, new_child_ids) = resolve_commit_location(tx, &resolved, location, REBASED_COMMITS)?;
    let roots = RevsetExpression::commits(new_parent_ids.clone())
        .range(&RevsetExpression::commits(branch_ids))
        .roots()
        .evaluate(tx.base_repo().as_ref())
        .map_err(be)?;
    let root_ids: Vec<CommitId> = pollster::block_on(roots.stream().try_collect()).map_err(be)?;
    guard_rewritable(tx, immutable, &root_ids)?;
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
            return Err(MutateError::InvalidInput {
                reason: format!("Cannot rebase {:.12} onto descendant {parent_id:.12}", commit.id()),
            });
        }
    }
    Ok(())
}

/// The CLI's `Cannot rebase <12 hex> onto itself`.
fn onto_itself(id: &CommitId) -> MutateError {
    MutateError::InvalidInput {
        reason: format!("Cannot rebase {id:.12} onto itself"),
    }
}

/// Whether the rebase `loc` plans would write no operation: an empty target is the CLI's "No
/// revisions to rebase." (`cmd_rebase`, `rebase.rs:395-399` @ v0.46.0), answered before anything
/// is computed; otherwise the CLI's "Nothing changed." guard (`cli_util.rs:2851`) after
/// `cmd_rebase`'s move (`rebase.rs:403-424` @ v0.46.0): jj-lib's
/// `compute_move_commits`, the divergent duplicates already in the destination recorded to
/// abandon (no `--keep-divergent`), and `apply` with the CLI's default options. Exact by
/// construction: it is the move the verb runs.
///
/// The move is applied to `tx`, which the caller drops afterwards. `tx` must start from a head
/// loaded by [`load_dry_run_head`] (`signing.behavior = "drop"`): a preview must never invoke the
/// user's signer for commits it throws away.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — the backend refuses a commit of the move as unsupported
///   (the Git backend's "…merge commits with the root commit as one of the parents."), its text
///   verbatim: the CLI reports it as a user error.
/// - [`MutateError::Backend`] — any other jj-lib failure.
pub(crate) fn rebase_is_no_op(tx: &mut Transaction, loc: &MoveCommitsLocation) -> Result<bool, MutateError> {
    let (MoveCommitsTarget::Commits(target_ids) | MoveCommitsTarget::Roots(target_ids)) = &loc.target;
    if target_ids.is_empty() {
        return Ok(true);
    }
    let mut computed = pollster::block_on(compute_move_commits(tx.repo(), loc)).map_err(unsupported)?;
    let divergent = pollster::block_on(find_duplicate_divergent_commits(
        tx.repo(),
        &loc.new_parent_ids,
        &loc.target,
    ))
    .map_err(unsupported)?;
    computed.record_to_abandon(divergent.iter().map(Commit::id).cloned());
    let options = RebaseOptions {
        empty: EmptyBehavior::Keep,
        rewrite_refs: RewriteRefsOptions {
            delete_abandoned_bookmarks: false,
        },
        simplify_ancestor_merge: false,
    };
    pollster::block_on(computed.apply(tx.repo_mut(), &options)).map_err(unsupported)?;
    Ok(!tx.repo().has_changes())
}

/// The repo's head operation loaded through `loader`'s stores with [`dry_run_settings`], once
/// per query: every transaction started from it writes its commits unsigned.
///
/// # Errors
///
/// - [`MutateError::Backend`] — the settings could not be built or the head could not be loaded.
pub(crate) fn load_dry_run_head(loader: &RepoLoader) -> Result<Arc<ReadonlyRepo>, MutateError> {
    let preview = RepoLoader::new(
        dry_run_settings(loader.settings())?,
        loader.store().clone(),
        loader.workspace_store().clone(),
        loader.op_store().clone(),
        loader.op_heads_store().clone(),
        loader.index_store().clone(),
        loader.submodule_store().clone(),
    );
    pollster::block_on(preview.load_at_head()).map_err(be)
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
        BackendError::Unsupported(reason) => MutateError::InvalidInput { reason },
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

        type Plan = fn(
            &Transaction,
            &Arc<UserRevsetExpression>,
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
            .expect("a commit with that description")
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
        let immutable = RevsetExpression::commits(vec![c2.id().clone()]);

        let plans: [(&str, Plan); 2] = [("-s", super::plan_rebase_source), ("-b", super::plan_rebase_branch)];
        for (flag, plan) in plans {
            let loc = plan(&tx, &RevsetExpression::root(), &[change(&at)], &location).expect(flag);
            assert_eq!(loc.new_parent_ids, [c1.id().clone()], "{flag}");
            assert_eq!(loc.new_child_ids, [c2.id().clone()], "{flag}");
            assert!(
                matches!(&loc.target, MoveCommitsTarget::Roots(roots) if roots == &[at.id().clone()]),
                "{flag}"
            );

            let refused = plan(&tx, &immutable, &[change(&at)], &location);
            assert!(
                matches!(&refused, Err(MutateError::Immutable { commit_id }) if *commit_id == c2.id().hex()),
                "{flag}: {refused:?}"
            );
        }
    }

    #[test]
    fn unsupported_is_the_backends_text_as_invalid_input() {
        use jj_lib::backend::BackendError;

        use crate::mutate::MutateError;
        let refused = super::unsupported(BackendError::Unsupported("no".to_owned()));
        assert!(matches!(refused, MutateError::InvalidInput { reason } if reason == "no"));
        let other = super::unsupported(BackendError::Other("x".into()));
        assert!(matches!(other, MutateError::Backend(_)));
    }
}
