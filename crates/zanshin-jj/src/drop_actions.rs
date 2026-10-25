// SPDX-License-Identifier: MIT

//! `drop_actions.rs` — the drop-action capability query (Story 9.31): which jj verbs a dragged
//! change, path selection or bookmark can run at a target, and the card menu's verbs for one
//! change — each answered BEFORE anything runs, with the verb's own refusal.
//!
//! Nothing here decides a rule of its own. Every row is answered by the verb's pure plan fn —
//! [`crate::mutate::plan_new`], [`crate::mutate::plan_edit`], [`crate::mutate::plan_describe`],
//! [`crate::mutate::plan_abandon`], [`crate::mutate::plan_restore`],
//! [`crate::mutate::plan_absorb`], [`crate::commit_views::plan_interdiff`],
//! [`crate::squash_split::plan_squash`], [`crate::squash_split::prepare_split`],
//! [`crate::rebase::plan_rebase_source`], [`crate::rebase::plan_rebase_revisions`],
//! [`crate::rebase::plan_rebase_branch`], [`crate::revert::plan_revert`],
//! [`crate::duplicate::plan_duplicate`] and [`crate::bookmark_ops::plan_bookmark_move`] — the same
//! fn the verb runs (or, for the verbs not shipped yet, is meant to run) before its first write.
//! So a row's refusal is exactly the [`MutateError`] the verb returns: same variant, same text
//! (interdiff's [`CommitViewError`] mapped variant for variant).
//!
//! Both queries run after the pre-verb snapshot, like every verb, and write no operation of their
//! own: each row plans on its own transaction, started from ONE head the call loads, and drops it.
//! The warnings a row's plan records are discarded — the verb reports its own when it runs — so
//! the call's warnings are the precondition's only.

use std::sync::Arc;

use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::revset::RevsetExpression;
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::bookmark_ops::{plan_bookmark_move, BookmarkMovePlan};
use crate::commit_views::plan_interdiff;
use crate::duplicate::plan_duplicate;
use crate::mutate::{
    given, plan_abandon, plan_absorb, plan_describe, plan_edit, plan_new, plan_restore, refuse_git_root_merge,
    resolve_commit, MutateError,
};
use crate::op_support::{resolve_immutable, start_repo_transaction, LocationArgs, NO_LOCATION, ONTO_WITH_INSERT};
use crate::rebase::{
    load_dry_run_head, plan_rebase_branch, plan_rebase_revisions, plan_rebase_source, rebase_is_no_op,
};
use crate::revert::plan_revert;
use crate::snapshot::VerbContext;
use crate::squash_split::{combined_description_needed, plan_squash, prepare_split};
use crate::{ChangeId, CommitViewError, RevisionRef, SplitOptions, SquashOptions};

/// What is dragged (Story 9.31).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DropSource {
    /// A whole change (`S`).
    Change(ChangeId),
    /// The changes to `paths` — repo-relative PREFIXES, as for [`crate::Repo::squash`] — inside
    /// `change`.
    Selection {
        /// The change the paths are selected in.
        change: ChangeId,
        /// The selected paths. Empty is every path for the squash row; the split row refuses it
        /// with split's no-paths text (the CLI's no-paths split is its interactive diff editor).
        paths: Vec<String>,
    },
    /// The local bookmark of this exact name.
    Bookmark(String),
}

/// Where it is dropped — the CLI's `-o`/`-A`/`-B` passed through (Story 9.31). An EMPTY list is a
/// flag that is not given. `onto` excludes the other two, and at least one must be given.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DropLocation {
    /// `-o/--onto`.
    pub onto: Vec<ChangeId>,
    /// `-A/--insert-after`.
    pub insert_after: Vec<ChangeId>,
    /// `-B/--insert-before`.
    pub insert_before: Vec<ChangeId>,
}

/// The verb a [`DropAction`] row previews, with `S` the source and `T…` the location's ids.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropVerb {
    /// `jj rebase -s S -o T…`.
    RebaseSource,
    /// `jj rebase -r S -o T…`, or with `-A`/`-B`.
    RebaseRevisions,
    /// `jj squash --from S --into T [paths]`.
    Squash,
    /// `jj new T… S`.
    NewMerge,
    /// `jj duplicate S -o T…`.
    Duplicate,
    /// `jj split -r S <paths> -A/-B …`.
    Split,
    /// `jj bookmark move N --to T`.
    BookmarkMove,
    /// `jj rebase -b S -o T…`.
    RebaseBranch,
    /// `jj revert -r S -o T…`, or with `-A`/`-B`.
    Revert,
    /// `jj restore --from S --into T` with no paths: T's WHOLE tree becomes S's.
    Restore,
    /// `jj absorb --from S --into T`.
    Absorb,
    /// `jj interdiff --from S --to T` — a read: never `NoOp`, and Available for any two changes
    /// that resolve.
    Interdiff,
}

/// Whether a previewed verb would run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActionStatus {
    /// It would run — writing an operation, except [`DropVerb::Interdiff`], which only reads.
    Available,
    /// It would run and write NO operation — the CLI's "Nothing changed." / "No bookmarks to
    /// update." / "No revisions to rebase." / "No revisions to revert." (unreachable through
    /// `drop_actions`: a row always names one change). Only `rebase`, `squash`, `bookmark move`,
    /// `revert`, `restore` and `absorb` report it.
    NoOp,
    /// It would refuse; [`ActionOutcome::refusal`] says why.
    Refused,
}

/// One previewed verb's answer (Story 9.31).
#[derive(Debug)]
pub struct ActionOutcome {
    /// Whether the verb would run.
    pub status: ActionStatus,
    /// The verb's own refusal — the [`MutateError`] it returns, same variant and text — exactly
    /// when `status` is [`ActionStatus::Refused`].
    pub refusal: Option<MutateError>,
    /// A squash row: the squash would combine two or more non-empty descriptions — the case the
    /// CLI opens its editor for; [`crate::Repo::squash_plan`] returns the text.
    pub combined_description_needed: bool,
    /// A bookmark row: the move goes backwards or sideways, which the CLI refuses without
    /// `--allow-backwards`.
    pub allow_backwards_needed: bool,
}

/// One row of [`crate::Repo::drop_actions`]' answer.
#[derive(Debug)]
pub struct DropAction {
    /// The verb.
    pub verb: DropVerb,
    /// The index of the location in the call's `locations`.
    pub location: usize,
    /// Its answer.
    pub outcome: ActionOutcome,
}

/// [`crate::Repo::drop_actions`]' answer: the rows of every location, in location order.
#[derive(Debug)]
pub struct DropActions {
    /// The rows.
    pub actions: Vec<DropAction>,
}

/// [`crate::Repo::change_actions`]' answer: the card menu's verbs for one change `X`.
#[derive(Debug)]
pub struct ChangeActions {
    /// `jj new X`.
    pub new_onto: ActionOutcome,
    /// `jj new -A X`.
    pub new_insert_after: ActionOutcome,
    /// `jj new -B X`.
    pub new_insert_before: ActionOutcome,
    /// `jj edit X`.
    pub edit: ActionOutcome,
    /// `jj describe X`.
    pub describe: ActionOutcome,
    /// `jj squash -r X` (into its parent), with the combined-description flag.
    pub squash_into_parent: ActionOutcome,
    /// `jj abandon X`.
    pub abandon: ActionOutcome,
}

/// What a row's plan decided when it did not refuse.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct Planned {
    no_op: bool,
    combined_description_needed: bool,
    allow_backwards_needed: bool,
}

impl Planned {
    const AVAILABLE: Self = Self {
        no_op: false,
        combined_description_needed: false,
        allow_backwards_needed: false,
    };
}

/// A row's plan result as its outcome: a refusal becomes the row's, except the two errors that
/// say nothing about the verb — a failed precondition and a jj-lib failure — which fail the
/// query.
fn outcome(planned: Result<Planned, MutateError>) -> Result<ActionOutcome, MutateError> {
    match planned {
        Ok(planned) => Ok(ActionOutcome {
            status: if planned.no_op {
                ActionStatus::NoOp
            } else {
                ActionStatus::Available
            },
            refusal: None,
            combined_description_needed: planned.combined_description_needed,
            allow_backwards_needed: planned.allow_backwards_needed,
        }),
        Err(e @ (MutateError::Backend(_) | MutateError::Precondition(_))) => Err(e),
        Err(refusal) => Ok(ActionOutcome {
            status: ActionStatus::Refused,
            refusal: Some(refusal),
            combined_description_needed: false,
            allow_backwards_needed: false,
        }),
    }
}

/// Refuses a location clap would refuse before anything resolves: `onto` with `-A`/`-B`, or none
/// of the three — `compute_commit_location`'s two texts.
fn check_location(location: &DropLocation) -> Result<(), MutateError> {
    let inserts = !location.insert_after.is_empty() || !location.insert_before.is_empty();
    let reason = match (location.onto.is_empty(), inserts) {
        (false, true) => ONTO_WITH_INSERT,
        (true, false) => NO_LOCATION,
        _ => return Ok(()),
    };
    Err(MutateError::invalid(reason.to_owned()))
}

/// The three forms of `jj rebase` a row previews.
#[derive(Debug, Clone, Copy)]
enum RebaseForm {
    /// `-s`.
    Source,
    /// `-r`.
    Revisions,
    /// `-b`.
    Branch,
}

/// Interdiff's refusal as the [`MutateError`] a row carries, variant for variant — the FFI maps
/// both types' same-named variants to the same code. A row reaches only `ChangeNotFound`.
fn view_err(e: CommitViewError) -> MutateError {
    match e {
        CommitViewError::Precondition(inner) => MutateError::Precondition(inner),
        CommitViewError::ChangeNotFound { id } => MutateError::ChangeNotFound { id },
        CommitViewError::InvalidInput { reason } => MutateError::invalid(reason),
        CommitViewError::RevsetParseError { reason, hints } => MutateError::RevsetParseError { reason, hints },
        CommitViewError::RevsetResolutionError { reason, hints } => {
            MutateError::RevsetResolutionError { reason, hints }
        }
        CommitViewError::Config { reason } => MutateError::Config { reason },
        CommitViewError::Backend(reason) => MutateError::Backend(reason),
    }
}

/// The head every row plans on, and the workspace the plans read.
struct Rows<'a> {
    workspace: &'a Workspace,
    readonly: Arc<ReadonlyRepo>,
}

impl Rows<'_> {
    /// Runs `plan` on a fresh transaction from the call's head, drops the transaction, and maps
    /// the result through [`outcome`].
    fn row(
        &self,
        ctx: &mut VerbContext,
        plan: impl FnOnce(&mut Transaction, &mut VerbContext) -> Result<Planned, MutateError>,
    ) -> Result<ActionOutcome, MutateError> {
        let mut tx = start_repo_transaction(&self.readonly, self.workspace.workspace_name());
        let planned = plan(&mut tx, ctx);
        drop(tx);
        outcome(planned)
    }

    /// `jj rebase -s S <location>` / `-r S <location>` / `-b S <location>`.
    fn rebase(
        &self,
        ctx: &mut VerbContext,
        form: RebaseForm,
        change: &ChangeId,
        location: &LocationArgs<'_>,
    ) -> Result<ActionOutcome, MutateError> {
        self.row(ctx, |tx, ctx| {
            let changes = std::slice::from_ref(change);
            let loc = match form {
                RebaseForm::Source => plan_rebase_source(tx, &ctx.templates(self.workspace), changes, location)?,
                RebaseForm::Revisions => plan_rebase_revisions(tx, &ctx.templates(self.workspace), changes, location)?,
                RebaseForm::Branch => plan_rebase_branch(tx, &ctx.templates(self.workspace), changes, location)?,
            };
            Ok(Planned {
                no_op: rebase_is_no_op(tx, &loc)?,
                ..Planned::AVAILABLE
            })
        })
    }

    /// `jj squash` with `options`: no-op when nothing would be squashed, with the
    /// combined-description flag.
    fn squash(&self, ctx: &mut VerbContext, options: &SquashOptions) -> Result<ActionOutcome, MutateError> {
        self.row(ctx, |tx, ctx| {
            let plan = plan_squash(tx, self.workspace, ctx, options)?;
            Ok(Planned {
                no_op: plan.squashed.is_none(),
                combined_description_needed: combined_description_needed(&plan),
                allow_backwards_needed: false,
            })
        })
    }

    /// `jj revert -r S <location>`: no-op when there is nothing to revert.
    fn revert(
        &self,
        ctx: &mut VerbContext,
        change: &ChangeId,
        location: &LocationArgs<'_>,
    ) -> Result<ActionOutcome, MutateError> {
        self.row(ctx, |tx, ctx| {
            let plan = plan_revert(
                tx,
                &ctx.templates(self.workspace),
                std::slice::from_ref(change),
                location,
            )?;
            // A revert that writes resolves the immutable set in the CLI's `tx.finish` (Story
            // 9.56); "No revisions to revert." never reaches it. Rows never parse the description
            // template, so with a broken template the verb's refusal (template parse) differs.
            // A row reverts exactly one resolved change, so `plan_revert` never returns `None`
            // here; the `Option` form keeps the CLI's rule (only a writing plan resolves the set)
            // without a branch no row can take.
            // The verb refuses a root merge at its write (after the template); rows keep it.
            plan.as_ref()
                .map(|plan| {
                    refuse_git_root_merge(tx.repo().store(), &plan.new_parent_ids)?;
                    resolve_immutable(tx.base_repo().as_ref(), &ctx.immutable)
                })
                .transpose()?;
            Ok(Planned {
                no_op: plan.is_none(),
                ..Planned::AVAILABLE
            })
        })
    }

    /// The rows only a one-target `onto` has besides squash: `jj restore --from S --into T`
    /// (no-op on the same tree), `jj absorb --from S --into T` (no-op when nothing is
    /// absorbable; `T` resolved like every location id) and `jj interdiff --from S --to T`.
    fn one_target_rows(
        &self,
        ctx: &mut VerbContext,
        change: &ChangeId,
        target: &ChangeId,
    ) -> Result<[(DropVerb, ActionOutcome); 3], MutateError> {
        let restore = self.row(ctx, |tx, ctx| {
            let plan = plan_restore(tx, self.workspace, ctx, Some(change), Some(target), None, &[])?;
            Ok(Planned {
                no_op: plan.restored.is_none(),
                ..Planned::AVAILABLE
            })
        })?;
        let absorb = self.row(ctx, |tx, ctx| {
            let into = |repo: &jj_lib::repo::MutableRepo| {
                Ok(RevsetExpression::commits(vec![resolve_commit(repo, target)?
                    .id()
                    .clone()]))
            };
            let plan = plan_absorb(tx, self.workspace, ctx, Some(change), into, &[])?;
            Ok(Planned {
                no_op: plan.target_commits.is_empty(),
                ..Planned::AVAILABLE
            })
        })?;
        let interdiff = self.row(ctx, |tx, _ctx| {
            let from = RevisionRef::ChangeId(change.clone());
            let to = RevisionRef::ChangeId(target.clone());
            plan_interdiff(tx.repo(), self.workspace.workspace_name(), Some(&from), Some(&to)).map_err(view_err)?;
            Ok(Planned::AVAILABLE)
        })?;
        Ok([
            (DropVerb::Restore, restore),
            (DropVerb::Absorb, absorb),
            (DropVerb::Interdiff, interdiff),
        ])
    }

    /// `jj new` with the three lists of [`plan_new`].
    fn new_change(
        &self,
        ctx: &mut VerbContext,
        parents: &[ChangeId],
        insert_after: &[ChangeId],
        insert_before: &[ChangeId],
    ) -> Result<ActionOutcome, MutateError> {
        self.row(ctx, |tx, ctx| {
            let location = plan_new(tx, &ctx.templates(self.workspace), parents, insert_after, insert_before)?;
            // The verb refuses a root merge at its write (after the template); rows keep it.
            refuse_git_root_merge(tx.repo().store(), &location.parents)?;
            // Every `new` writes, so the CLI's `tx.finish` resolves the immutable set (Story
            // 9.56). Rows never parse the description template, so with a broken template the
            // verb's refusal (template parse) differs.
            resolve_immutable(tx.base_repo().as_ref(), &ctx.immutable)?;
            Ok(Planned::AVAILABLE)
        })
    }

    /// The rows of `source` at one location: the design's rows in its order, then the rows added
    /// after it (Story 9.31 follow-on) — appended, so no earlier row moves.
    fn location_rows(
        &self,
        ctx: &mut VerbContext,
        source: &DropSource,
        location: &DropLocation,
    ) -> Result<Vec<(DropVerb, ActionOutcome)>, MutateError> {
        let args = LocationArgs {
            onto: &location.onto,
            insert_after: &location.insert_after,
            insert_before: &location.insert_before,
        };
        let onto_one = match location.onto.as_slice() {
            [target] => Some(target),
            _ => None,
        };
        let mut rows = Vec::new();
        match source {
            DropSource::Change(change) if !location.onto.is_empty() => {
                rows.push((
                    DropVerb::RebaseSource,
                    self.rebase(ctx, RebaseForm::Source, change, &args)?,
                ));
                rows.push((
                    DropVerb::RebaseRevisions,
                    self.rebase(ctx, RebaseForm::Revisions, change, &args)?,
                ));
                if let Some(target) = onto_one {
                    rows.push((DropVerb::Squash, self.squash(ctx, &squash_into(change, target, &[]))?));
                }
                let mut parents = location.onto.clone();
                parents.push(change.clone());
                rows.push((DropVerb::NewMerge, self.new_change(ctx, &parents, &[], &[])?));
                let duplicate = self.row(ctx, |tx, ctx| {
                    let plan = plan_duplicate(tx, &ctx.templates(self.workspace), std::slice::from_ref(change), &args)?;
                    // The verb refuses a root merge at its write (after the template); rows keep it.
                    // Always `-o`, so never `None`: the Revert row's `Option` form gives that dead case no line.
                    plan.location
                        .as_ref()
                        .map(|(parents, _)| refuse_git_root_merge(tx.repo().store(), parents))
                        .transpose()?;
                    // Every duplicate writes, so the CLI's `tx.finish` resolves the immutable set
                    // (Story 9.56). Rows never parse the description template, so with a broken
                    // template the verb's refusal (template parse) differs.
                    resolve_immutable(tx.base_repo().as_ref(), &ctx.immutable)?;
                    Ok(Planned::AVAILABLE)
                })?;
                rows.push((DropVerb::Duplicate, duplicate));
                rows.push((
                    DropVerb::RebaseBranch,
                    self.rebase(ctx, RebaseForm::Branch, change, &args)?,
                ));
                rows.push((DropVerb::Revert, self.revert(ctx, change, &args)?));
                if let Some(target) = onto_one {
                    rows.extend(self.one_target_rows(ctx, change, target)?);
                }
            }
            DropSource::Change(change) => {
                rows.push((
                    DropVerb::RebaseRevisions,
                    self.rebase(ctx, RebaseForm::Revisions, change, &args)?,
                ));
                rows.push((DropVerb::Revert, self.revert(ctx, change, &args)?));
            }
            DropSource::Selection { change, paths } if !location.onto.is_empty() => {
                if let Some(target) = onto_one {
                    rows.push((DropVerb::Squash, self.squash(ctx, &squash_into(change, target, paths))?));
                }
            }
            DropSource::Selection { change, paths } => {
                let options = SplitOptions {
                    revision: Some(change.clone()),
                    paths: paths.clone(),
                    insert_after: given(&location.insert_after).map(<[ChangeId]>::to_vec),
                    insert_before: given(&location.insert_before).map(<[ChangeId]>::to_vec),
                    ..SplitOptions::default()
                };
                let split = self.row(ctx, |tx, ctx| {
                    prepare_split(tx, self.workspace, ctx, &options)?;
                    Ok(Planned::AVAILABLE)
                })?;
                rows.push((DropVerb::Split, split));
            }
            DropSource::Bookmark(name) => {
                if let Some(target) = onto_one {
                    let bookmark = self.row(ctx, |tx, ctx| {
                        let target = resolve_commit(tx.repo(), target)?;
                        let plan = plan_bookmark_move(tx.repo(), name, target.id())?;
                        // A move that writes resolves the immutable set in the CLI's `tx.finish`
                        // (Story 9.56); a no-op never reaches it.
                        if plan != BookmarkMovePlan::NoOp {
                            resolve_immutable(tx.base_repo().as_ref(), &ctx.immutable)?;
                        }
                        Ok(match plan {
                            BookmarkMovePlan::NoOp => Planned {
                                no_op: true,
                                ..Planned::AVAILABLE
                            },
                            BookmarkMovePlan::FastForward => Planned::AVAILABLE,
                            BookmarkMovePlan::Backwards => Planned {
                                allow_backwards_needed: true,
                                ..Planned::AVAILABLE
                            },
                        })
                    })?;
                    rows.push((DropVerb::BookmarkMove, bookmark));
                }
            }
        }
        Ok(rows)
    }
}

/// `jj squash --from <change> --into <target> [paths]`.
fn squash_into(change: &ChangeId, target: &ChangeId, paths: &[String]) -> SquashOptions {
    SquashOptions {
        from: vec![change.clone()],
        into: Some(target.clone()),
        paths: paths.to_vec(),
        ..SquashOptions::default()
    }
}

/// Runs `query` with the call's head loaded once — with signing dropped
/// ([`load_dry_run_head`]), since the rebase rows' dry run writes commits it throws away — then
/// puts the precondition's warnings back as the call's only ones: whatever the rows recorded is
/// dropped, on every path.
fn with_rows<T>(
    workspace: &Workspace,
    ctx: &mut VerbContext,
    query: impl FnOnce(&Rows<'_>, &mut VerbContext) -> Result<T, MutateError>,
) -> Result<T, MutateError> {
    let readonly = load_dry_run_head(workspace)?;
    let precondition_warnings = ctx.warnings.take();
    let result = query(&Rows { workspace, readonly }, ctx);
    let _row_warnings = ctx.warnings.take();
    ctx.warnings.extend(precondition_warnings);
    result
}

/// [`crate::Repo::drop_actions`]: the locations checked first, then the rows of every location.
///
/// # Errors
///
/// See [`crate::Repo::drop_actions`].
pub(crate) fn drop_actions(
    workspace: &Workspace,
    ctx: &mut VerbContext,
    source: &DropSource,
    locations: &[DropLocation],
) -> Result<DropActions, MutateError> {
    for location in locations {
        check_location(location)?;
    }
    with_rows(workspace, ctx, |rows, ctx| {
        let mut actions = Vec::new();
        for (index, location) in locations.iter().enumerate() {
            for (verb, outcome) in rows.location_rows(ctx, source, location)? {
                actions.push(DropAction {
                    verb,
                    location: index,
                    outcome,
                });
            }
        }
        Ok(DropActions { actions })
    })
}

/// [`crate::Repo::change_actions`]: the seven card-menu rows for `change`.
///
/// # Errors
///
/// See [`crate::Repo::change_actions`].
pub(crate) fn change_actions(
    workspace: &Workspace,
    ctx: &mut VerbContext,
    change: &ChangeId,
) -> Result<ChangeActions, MutateError> {
    with_rows(workspace, ctx, |rows, ctx| {
        let one = std::slice::from_ref(change);
        Ok(ChangeActions {
            new_onto: rows.new_change(ctx, one, &[], &[])?,
            new_insert_after: rows.new_change(ctx, &[], one, &[])?,
            new_insert_before: rows.new_change(ctx, &[], &[], one)?,
            edit: rows.row(ctx, |tx, ctx| {
                plan_edit(tx, &ctx.templates(rows.workspace), change)?;
                Ok(Planned::AVAILABLE)
            })?,
            describe: rows.row(ctx, |tx, ctx| {
                plan_describe(tx, &ctx.templates(rows.workspace), change)?;
                Ok(Planned::AVAILABLE)
            })?,
            squash_into_parent: rows.squash(
                ctx,
                &SquashOptions {
                    revision: Some(change.clone()),
                    ..SquashOptions::default()
                },
            )?,
            abandon: rows.row(ctx, |tx, ctx| {
                plan_abandon(tx, &ctx.templates(rows.workspace), one)?;
                Ok(Planned::AVAILABLE)
            })?,
        })
    })
}

#[cfg(test)]
mod tests {
    use super::{check_location, outcome, view_err, ActionStatus, DropLocation, Planned};
    use crate::mutate::MutateError;
    use crate::op_support::{NO_LOCATION, ONTO_WITH_INSERT};
    use crate::ChangeId;
    use crate::CommitViewError;

    fn ids(list: &[&str]) -> Vec<ChangeId> {
        list.iter().map(|s| ChangeId((*s).to_owned())).collect()
    }

    /// Asserts `check_location` accepts `location` (`expected` is `None`) or refuses it as
    /// `InvalidInput` reading exactly `expected`.
    fn assert_refusal(location: &DropLocation, expected: Option<&str>) {
        let result = check_location(location);
        let as_expected = match expected {
            None => result.is_ok(),
            Some(text) => matches!(&result, Err(MutateError::InvalidInput { reason, .. }) if reason == text),
        };
        assert!(as_expected, "{location:?}: expected {expected:?}, got {result:?}");
    }

    #[test]
    fn check_location_refuses_clap_shapes_with_compute_commit_locations_texts() {
        assert_refusal(&DropLocation::default(), Some(NO_LOCATION));
        let both = DropLocation {
            onto: ids(&["a"]),
            insert_after: ids(&["b"]),
            ..DropLocation::default()
        };
        assert_refusal(&both, Some(ONTO_WITH_INSERT));
        let onto_before = DropLocation {
            onto: ids(&["a"]),
            insert_before: ids(&["b"]),
            ..DropLocation::default()
        };
        assert_refusal(&onto_before, Some(ONTO_WITH_INSERT));
        for ok in [
            DropLocation {
                onto: ids(&["a", "b"]),
                ..DropLocation::default()
            },
            DropLocation {
                insert_after: ids(&["a"]),
                insert_before: ids(&["b"]),
                ..DropLocation::default()
            },
            DropLocation {
                insert_before: ids(&["b"]),
                ..DropLocation::default()
            },
        ] {
            assert_refusal(&ok, None);
        }
    }

    #[test]
    fn outcome_maps_plans_and_refusals_and_fails_on_backend_and_precondition() {
        let available = outcome(Ok(Planned::AVAILABLE)).expect("ok");
        assert_eq!(available.status, ActionStatus::Available);
        assert!(available.refusal.is_none());
        let flagged = outcome(Ok(Planned {
            combined_description_needed: true,
            allow_backwards_needed: true,
            ..Planned::AVAILABLE
        }))
        .expect("ok");
        assert!(flagged.combined_description_needed && flagged.allow_backwards_needed);
        let no_op = outcome(Ok(Planned {
            no_op: true,
            ..Planned::AVAILABLE
        }))
        .expect("ok");
        assert_eq!(no_op.status, ActionStatus::NoOp);

        for refusal in [
            MutateError::ChangeNotFound { id: "z".to_owned() },
            MutateError::invalid("r".to_owned()),
            MutateError::Immutable {
                commit_id: "c".to_owned(),
                hints: Vec::new(),
            },
            MutateError::Config { reason: "c".to_owned() },
        ] {
            let text = format!("{refusal:?}");
            let refused = outcome(Err(refusal)).expect("a refusal is a row");
            assert_eq!(refused.status, ActionStatus::Refused);
            assert_eq!(format!("{:?}", refused.refusal.expect("refusal")), text);
            assert!(!refused.combined_description_needed && !refused.allow_backwards_needed);
        }

        assert!(matches!(
            outcome(Err(MutateError::Backend("b".to_owned()))),
            Err(MutateError::Backend(_))
        ));
        assert!(matches!(
            outcome(Err(MutateError::Precondition(crate::PreconditionError::Backend(
                "p".to_owned()
            )))),
            Err(MutateError::Precondition(_))
        ));
    }

    #[test]
    fn view_err_maps_every_commit_view_error_to_the_same_named_mutate_error() {
        let precondition = || crate::PreconditionError::Backend("p".to_owned());
        let r = || "r".to_owned();
        let cases = [
            (
                CommitViewError::Precondition(precondition()),
                MutateError::Precondition(precondition()),
            ),
            (
                CommitViewError::ChangeNotFound { id: r() },
                MutateError::ChangeNotFound { id: r() },
            ),
            (CommitViewError::InvalidInput { reason: r() }, MutateError::invalid(r())),
            (
                CommitViewError::RevsetParseError {
                    reason: r(),
                    hints: vec![r()],
                },
                MutateError::RevsetParseError {
                    reason: r(),
                    hints: vec![r()],
                },
            ),
            (
                CommitViewError::RevsetResolutionError {
                    reason: r(),
                    hints: vec![r()],
                },
                MutateError::RevsetResolutionError {
                    reason: r(),
                    hints: vec![r()],
                },
            ),
            (
                CommitViewError::Config { reason: r() },
                MutateError::Config { reason: r() },
            ),
            (CommitViewError::Backend(r()), MutateError::Backend(r())),
        ];
        for (view, expected) in cases {
            assert_eq!(format!("{:?}", view_err(view)), format!("{expected:?}"));
        }
    }
}
