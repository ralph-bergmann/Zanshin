// SPDX-License-Identifier: MIT

//! `rebase.rs` — the plan phase of `jj rebase -r` and `jj rebase -s` (Story 9.31), ported from
//! `plan_rebase_revisions` / `plan_rebase_source` / `check_rebase_destinations`
//! (`cli/src/commands/rebase.rs:431-599` @ v0.46.0), plus the CLI's "Nothing changed." answer for
//! a planned move ([`rebase_is_no_op`]).
//!
//! The fns are pure: they resolve, check and return the `MoveCommitsLocation` jj-lib's
//! `compute_move_commits` takes, and write nothing. `drop_actions`' two rebase rows call them
//! today; the rebase verb (Story 9.16) is meant to call the same fns. Every refusal is the CLI's
//! `user_error` text as [`MutateError::InvalidInput`]; the commit ids in it are the CLI's
//! `short_commit_hash`, 12 hex digits.

use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::{BackendError, CommitId};
use jj_lib::commit::Commit;
use jj_lib::config::{ConfigLayer, ConfigSource};
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{ReadonlyRepo, Repo as _, RepoLoader};
use jj_lib::revset::{RevsetExpression, UserRevsetExpression};
use jj_lib::rewrite::{
    compute_move_commits, find_duplicate_divergent_commits, EmptyBehavior, MoveCommitsLocation, MoveCommitsTarget,
    RebaseOptions, RewriteRefsOptions,
};
use jj_lib::settings::UserSettings;
use jj_lib::transaction::Transaction;

use crate::mutate::{be, guard_rewritable, MutateError};
use crate::op_support::{resolve_commit_location, resolve_ordered, start_repo_transaction, LocationArgs};
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

/// Whether the rebase `loc` plans would write no operation — the CLI's "Nothing changed." guard
/// (`cli_util.rs:2851`) after `cmd_rebase`'s move (`rebase.rs:403-424` @ v0.46.0): jj-lib's
/// `compute_move_commits`, the divergent duplicates already in the destination recorded to
/// abandon (no `--keep-divergent`), and `apply` with the CLI's default options. Exact by
/// construction: it is the move the verb runs.
///
/// The move runs on a transaction of its own, started from `base`'s operation re-loaded with
/// [`dry_run_settings`] (`signing.behavior = "drop"`), and dropped — a preview must never invoke
/// the user's signer for commits it throws away.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — the backend refuses a commit of the move as unsupported
///   (the Git backend's "…merge commits with the root commit as one of the parents."), its text
///   verbatim: the CLI reports it as a user error.
/// - [`MutateError::Backend`] — any other jj-lib failure.
pub(crate) fn rebase_is_no_op(
    base: &Arc<ReadonlyRepo>,
    workspace_name: &WorkspaceName,
    loc: &MoveCommitsLocation,
) -> Result<bool, MutateError> {
    let loader = base.loader();
    let preview = RepoLoader::new(
        dry_run_settings(base.settings())?,
        loader.store().clone(),
        loader.workspace_store().clone(),
        loader.op_store().clone(),
        loader.op_heads_store().clone(),
        loader.index_store().clone(),
        loader.submodule_store().clone(),
    );
    let repo = pollster::block_on(preview.load_at(base.operation())).map_err(be)?;
    let mut tx = start_repo_transaction(&repo, workspace_name);
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
