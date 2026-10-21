// SPDX-License-Identifier: MIT

//! `drop_actions.rs` — the drop-action capability query (Story 9.31): which jj verbs a dragged
//! change, path selection or bookmark can run at a target, and the card menu's verbs for one
//! change — each answered BEFORE anything runs, with the verb's own refusal.
//!
//! Nothing here decides a rule of its own. Every row is answered by the verb's pure plan fn —
//! [`crate::mutate::plan_new`], [`crate::mutate::plan_edit`], [`crate::mutate::plan_describe`],
//! [`crate::mutate::plan_abandon`], [`crate::squash_split::plan_squash`],
//! [`crate::squash_split::prepare_split`], [`crate::rebase::plan_rebase_source`],
//! [`crate::rebase::plan_rebase_revisions`], [`crate::duplicate::plan_duplicate`] and
//! [`crate::bookmark_ops::plan_bookmark_move`] — the same fn the verb runs (or, for the verbs not
//! shipped yet, is meant to run) before its first write. So a row's refusal is exactly the
//! [`MutateError`] the verb returns: same variant, same text.
//!
//! Both queries run after the pre-verb snapshot, like every verb, and write no operation of their
//! own: each row plans on its own transaction, started from ONE head the call loads, and drops it.
//! The warnings a row's plan records are discarded — the verb reports its own when it runs — so
//! the call's warnings are the precondition's only.

use std::sync::Arc;

use jj_lib::repo::ReadonlyRepo;
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::bookmark_ops::{plan_bookmark_move, BookmarkMovePlan};
use crate::duplicate::plan_duplicate;
use crate::mutate::{be, given, plan_abandon, plan_describe, plan_edit, plan_new, resolve_commit, MutateError};
use crate::op_support::{start_repo_transaction, LocationArgs, NO_LOCATION, ONTO_WITH_INSERT};
use crate::rebase::{plan_rebase_revisions, plan_rebase_source, rebase_is_no_op};
use crate::snapshot::VerbContext;
use crate::squash_split::{combined_description_needed, plan_squash, prepare_split};
use crate::{ChangeId, SplitOptions, SquashOptions};

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
}

/// Whether a previewed verb would run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActionStatus {
    /// It would run and write an operation.
    Available,
    /// It would run and write NO operation — the CLI's "Nothing changed." / "No bookmarks to
    /// update." Only `rebase`, `squash` and `bookmark move` report it.
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
    Err(MutateError::InvalidInput {
        reason: reason.to_owned(),
    })
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

    /// `jj rebase -s S <location>` / `-r S <location>` (`source == true` for `-s`).
    fn rebase(
        &self,
        ctx: &mut VerbContext,
        source: bool,
        change: &ChangeId,
        location: &LocationArgs<'_>,
    ) -> Result<ActionOutcome, MutateError> {
        self.row(ctx, |tx, ctx| {
            let changes = std::slice::from_ref(change);
            let loc = if source {
                plan_rebase_source(tx, &ctx.immutable, changes, location)?
            } else {
                plan_rebase_revisions(tx, &ctx.immutable, changes, location)?
            };
            Ok(Planned {
                no_op: rebase_is_no_op(&self.readonly, self.workspace.workspace_name(), &loc)?,
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

    /// `jj new` with the three lists of [`plan_new`].
    fn new_change(
        &self,
        ctx: &mut VerbContext,
        parents: &[ChangeId],
        insert_after: &[ChangeId],
        insert_before: &[ChangeId],
    ) -> Result<ActionOutcome, MutateError> {
        self.row(ctx, |tx, ctx| {
            plan_new(tx, &ctx.immutable, parents, insert_after, insert_before)?;
            Ok(Planned::AVAILABLE)
        })
    }

    /// The rows of `source` at one location, in the design's order.
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
                rows.push((DropVerb::RebaseSource, self.rebase(ctx, true, change, &args)?));
                rows.push((DropVerb::RebaseRevisions, self.rebase(ctx, false, change, &args)?));
                if let Some(target) = onto_one {
                    rows.push((DropVerb::Squash, self.squash(ctx, &squash_into(change, target, &[]))?));
                }
                let mut parents = location.onto.clone();
                parents.push(change.clone());
                rows.push((DropVerb::NewMerge, self.new_change(ctx, &parents, &[], &[])?));
                let duplicate = self.row(ctx, |tx, ctx| {
                    plan_duplicate(tx, &ctx.immutable, std::slice::from_ref(change), &args)?;
                    Ok(Planned::AVAILABLE)
                })?;
                rows.push((DropVerb::Duplicate, duplicate));
            }
            DropSource::Change(change) => {
                rows.push((DropVerb::RebaseRevisions, self.rebase(ctx, false, change, &args)?));
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
                    let bookmark = self.row(ctx, |tx, _ctx| {
                        let target = resolve_commit(tx.repo(), target)?;
                        Ok(match plan_bookmark_move(tx.repo(), name, target.id())? {
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

/// Runs `query` with the call's head loaded, then puts the precondition's warnings back as the
/// call's only ones — whatever the rows recorded is dropped, on every path.
fn with_rows<T>(
    workspace: &Workspace,
    ctx: &mut VerbContext,
    query: impl FnOnce(&Rows<'_>, &mut VerbContext) -> Result<T, MutateError>,
) -> Result<T, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
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
                plan_edit(tx, &ctx.immutable, change)?;
                Ok(Planned::AVAILABLE)
            })?,
            describe: rows.row(ctx, |tx, ctx| {
                plan_describe(tx, &ctx.immutable, change)?;
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
                plan_abandon(tx, &ctx.immutable, one)?;
                Ok(Planned::AVAILABLE)
            })?,
        })
    })
}

#[cfg(test)]
mod tests {
    use super::{check_location, outcome, ActionStatus, DropLocation, Planned};
    use crate::mutate::MutateError;
    use crate::op_support::{NO_LOCATION, ONTO_WITH_INSERT};
    use crate::ChangeId;

    fn ids(list: &[&str]) -> Vec<ChangeId> {
        list.iter().map(|s| ChangeId((*s).to_owned())).collect()
    }

    fn reason(location: &DropLocation) -> Option<String> {
        match check_location(location) {
            Ok(()) => None,
            Err(MutateError::InvalidInput { reason }) => Some(reason),
            Err(other) => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn check_location_refuses_clap_shapes_with_compute_commit_locations_texts() {
        assert_eq!(reason(&DropLocation::default()).as_deref(), Some(NO_LOCATION));
        let both = DropLocation {
            onto: ids(&["a"]),
            insert_after: ids(&["b"]),
            ..DropLocation::default()
        };
        assert_eq!(reason(&both).as_deref(), Some(ONTO_WITH_INSERT));
        let onto_before = DropLocation {
            onto: ids(&["a"]),
            insert_before: ids(&["b"]),
            ..DropLocation::default()
        };
        assert_eq!(reason(&onto_before).as_deref(), Some(ONTO_WITH_INSERT));
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
            assert_eq!(reason(&ok), None, "{ok:?}");
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
            MutateError::InvalidInput { reason: "r".to_owned() },
            MutateError::Immutable {
                commit_id: "c".to_owned(),
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
}
