// SPDX-License-Identifier: MIT

//! `movement.rs` — `jj next` / `jj prev` (Story 9.10), ported step for step from
//! `cli/src/movement_util.rs` @ v0.46.0: `move_to_commit`, `get_target_commit`,
//! `Direction::build_target_revset` and `Direction::target_not_found_error`.
//!
//! The order is the CLI's: clap's refusals ([`check_movement_args`], before the pre-verb
//! snapshot), the `@` lookup, `ui.movement.edit`, the no-children check, the target revset and its
//! not-found refusal ([`plan_movement`]), choosing one target ([`choose_target`]), then — editing
//! only — the rewritability guard, the transaction and its finish.
//!
//! Divergence, deliberate: where the CLI prompts for one of several targets (`choose_commit`),
//! [`crate::Repo::movement_targets`] returns the candidates and [`MovementOptions::target`] carries
//! the GUI's choice; without a choice the call refuses with the prompt's header. The CLI's status
//! lines are terminal UX and not ported.

use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::commit::Commit;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::revset::{
    ResolvedRevsetExpression, RevsetEvaluationError, RevsetExpression, RevsetFilterPredicate, RevsetStreamExt as _,
};
use jj_lib::workspace::Workspace;

use crate::mutate::{be, cfg, finish_verb, guard_rewritable, mutation_result, MutateError, MutationResult};
use crate::op_support::start_repo_transaction;
use crate::snapshot::VerbContext;
use crate::ChangeId;

/// Which way [`crate::Repo::move_working_copy`] moves: `jj next` or `jj prev`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Direction {
    /// `jj next` — towards the descendants.
    #[default]
    Next,
    /// `jj prev` — towards the ancestors.
    Prev,
}

impl Direction {
    /// The CLI's command name (`Direction::cmd`).
    fn cmd(self) -> &'static str {
        match self {
            Self::Next => "next",
            Self::Prev => "prev",
        }
    }
}

/// [`crate::Repo::move_working_copy`]'s and [`crate::Repo::movement_targets`]' arguments — the
/// CLI's `jj next` / `jj prev` flags, one field each, plus the GUI's answer to the CLI's prompt
/// (Story 9.10).
// WHY: one field per CLI flag (`NextArgs` / `PrevArgs`, FR-JJ-17) — the bools ARE the CLI's
// independent switches, and clap's rules between them are checked, not encoded.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MovementOptions {
    /// `jj next` or `jj prev`.
    pub direction: Direction,
    /// `[OFFSET]`: how many generations to move. `None` is the CLI's default, `1`; `Some` excludes
    /// `conflict`.
    pub offset: Option<u64>,
    /// `-e/--edit`: edit the target instead of creating a new working-copy commit on it.
    pub edit: bool,
    /// `-n/--no-edit`: the inverse of `edit`, overriding `ui.movement.edit = true`. Excludes
    /// `edit`.
    pub no_edit: bool,
    /// `--conflict`: move to the nearest conflicted descendant (`next`) or ancestor (`prev`).
    pub conflict: bool,
    /// The target chosen among [`crate::Repo::movement_targets`]' candidates — the CLI's prompt
    /// answer. `None` when there is nothing to choose; it must be a current candidate.
    pub target: Option<crate::CommitId>,
}

/// What [`crate::Repo::movement_targets`] found: the candidates the CLI's prompt would list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MovementTargets {
    /// Whether the move edits its target (`edit`, or `ui.movement.edit` without `no_edit`) rather
    /// than creating a new working-copy commit on it.
    pub edit: bool,
    /// The candidates, in the CLI's prompt order (the target revset's order); never empty. More
    /// than one is the case the CLI prompts for.
    pub targets: Vec<MovementTarget>,
}

/// One candidate of [`MovementTargets`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MovementTarget {
    /// The commit — what [`MovementOptions::target`] takes (a change id can be divergent).
    pub commit_id: crate::CommitId,
    /// Its change id.
    pub change_id: ChangeId,
}

/// The verb's state once its target revset is evaluated.
struct Plan {
    /// `@` before the move.
    wc_id: CommitId,
    /// `edit || (!no_edit && ui.movement.edit)`.
    should_edit: bool,
    /// The target revset's commits, in its stream order; never empty.
    targets: Vec<Commit>,
}

/// Refuses what clap refuses, before the pre-verb snapshot: `no_edit` with `edit`
/// (`conflicts_with = "edit"`), then an explicit `offset` with `conflict` (`conflicts_with =
/// "offset"`; clap never fires on the default, so `None` passes).
///
/// # Errors
///
/// [`MutateError::InvalidInput`] — `the argument '--edit' cannot be used with '--no-edit'`, `the
/// argument '--conflict' cannot be used with '[OFFSET]'`.
pub(crate) fn check_movement_args(options: &MovementOptions) -> Result<(), MutateError> {
    if options.edit && options.no_edit {
        return Err(MutateError::invalid(
            "the argument '--edit' cannot be used with '--no-edit'",
        ));
    }
    if options.offset.is_some() && options.conflict {
        return Err(MutateError::invalid(
            "the argument '--conflict' cannot be used with '[OFFSET]'",
        ));
    }
    Ok(())
}

/// `Direction::target_not_found_error`'s message (`movement_util.rs` @ v0.46.0), verbatim.
fn not_found_message(direction: Direction, should_edit: bool, conflict: bool, offset: u64) -> String {
    match (direction, should_edit, conflict) {
        (Direction::Next, true, true) => "The working copy has no descendants with conflicts".to_owned(),
        (Direction::Next, true, false) => {
            format!("No descendant found {offset} commit(s) forward from the working copy")
        }
        (Direction::Next, false, true) => {
            "The working copy parent(s) have no other descendants with conflicts".to_owned()
        }
        (Direction::Next, false, false) => {
            format!("No other descendant found {offset} commit(s) forward from the working copy parent(s)")
        }
        (Direction::Prev, true, true) => "The working copy has no ancestors with conflicts".to_owned(),
        (Direction::Prev, true, false) => format!("No ancestor found {offset} commit(s) back from the working copy"),
        (Direction::Prev, false, true) => "The working copy parent(s) have no ancestors with conflicts".to_owned(),
        (Direction::Prev, false, false) => {
            format!("No ancestor found {offset} commit(s) back from the working copy parents(s)")
        }
    }
}

/// `Direction::build_target_revset`. The non-edit `next` subtracts one with `wrapping_sub`, as the
/// release CLI's `args.offset - 1` does: offset `0` becomes `descendants_at(u64::MAX)`, which
/// jj-lib refuses to evaluate ([`commits`]).
fn build_target_revset(
    direction: Direction,
    wc: &Arc<ResolvedRevsetExpression>,
    start: &Arc<ResolvedRevsetExpression>,
    should_edit: bool,
    conflict: bool,
    offset: u64,
) -> Arc<ResolvedRevsetExpression> {
    let nth = match (direction, should_edit) {
        (Direction::Next, true) => start.descendants_at(offset),
        (Direction::Next, false) => start.children().minus(wc).descendants_at(offset.wrapping_sub(1)),
        (Direction::Prev, _) => start.ancestors_at(offset),
    };
    match (direction, conflict) {
        (_, false) => nth,
        (Direction::Next, true) => nth.descendants().filtered(RevsetFilterPredicate::HasConflict).roots(),
        (Direction::Prev, true) => nth.ancestors().filtered(RevsetFilterPredicate::HasConflict).heads(),
    }
}

/// `expression`'s commits in its stream order.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — jj-lib refuses the expression itself (a generation beyond
///   `u32::MAX`: `Lower bound of generation (<n>) is too large`), the CLI's user error.
/// - [`MutateError::Backend`] — a store read failed.
fn commits(repo: &ReadonlyRepo, expression: &Arc<ResolvedRevsetExpression>) -> Result<Vec<Commit>, MutateError> {
    let set = expression.clone().evaluate(repo).map_err(|e| match e {
        RevsetEvaluationError::Other(_) => MutateError::invalid(e.to_string()),
        RevsetEvaluationError::Backend(_) => be(e),
    })?;
    pollster::block_on(set.stream().commits(repo.store()).try_collect()).map_err(be)
}

/// The verb up to choosing a target (`move_to_commit` + `get_target_commit` up to
/// `choose_commit`): `@`, `ui.movement.edit`, the no-children check, the target revset, and the
/// not-found refusal with one hint per start commit. Writes nothing.
///
/// # Errors
///
/// - [`MutateError::NoWorkingCopy`] — the workspace has no `@`.
/// - [`MutateError::Config`] — `ui.movement.edit` is not a boolean, or `templates.commit_summary`
///   (the hints) is not a string or does not parse.
/// - [`MutateError::InvalidInput`] — `@` has children and the move does not edit; an offset
///   jj-lib cannot evaluate ([`commits`]); no target.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
fn plan_movement(
    repo: &ReadonlyRepo,
    workspace: &Workspace,
    ctx: &VerbContext,
    options: &MovementOptions,
) -> Result<Plan, MutateError> {
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .ok_or(MutateError::NoWorkingCopy)?
        .clone();
    // Read before the flags are looked at, as the CLI reads it: a bad value refuses `--edit` too.
    let config_edit = crate::config::ui_movement_edit(&ctx.config).map_err(cfg)?;
    let should_edit = options.edit || (!options.no_edit && config_edit);
    if !should_edit && !repo.view().heads().contains(&wc_id) {
        return Err(MutateError::invalid_hinted(
            "The working copy must not have any children",
            "Create a new commit on top of this one or use `--edit`",
        ));
    }
    let wc = RevsetExpression::commit(wc_id.clone());
    let start = if should_edit { wc.clone() } else { wc.parents() };
    let offset = options.offset.unwrap_or(1);
    let target = build_target_revset(options.direction, &wc, &start, should_edit, options.conflict, offset);
    let targets = commits(repo, &target)?;
    if targets.is_empty() {
        let templates = ctx.templates(workspace);
        let label = if should_edit {
            "Working copy: "
        } else {
            "Working copy parent: "
        };
        let hints = commits(repo, &start)?
            .iter()
            .map(|commit| Ok(format!("{label}{}", templates.commit_summary(repo, commit)?)))
            .collect::<Result<_, MutateError>>()?;
        return Err(MutateError::InvalidInput {
            reason: not_found_message(options.direction, should_edit, options.conflict, offset),
            hints,
        });
    }
    Ok(Plan {
        wc_id,
        should_edit,
        targets,
    })
}

/// The one target of `plan`: the GUI's choice when it is a candidate, else the only candidate.
///
/// # Errors
///
/// - [`MutateError::StaleSelection`] — `target` is not a candidate.
/// - [`MutateError::InvalidInput`] — no `target` and several candidates: the CLI's prompt header.
fn choose_target<'a>(
    direction: Direction,
    plan: &'a Plan,
    target: Option<&crate::CommitId>,
) -> Result<&'a Commit, MutateError> {
    match (target, plan.targets.as_slice()) {
        (Some(id), targets) => {
            targets
                .iter()
                .find(|commit| commit.id().hex() == id.0)
                .ok_or_else(|| MutateError::StaleSelection {
                    reason: format!("{} is not a {} target", id.0, direction.cmd()),
                })
        }
        (None, [only]) => Ok(only),
        (None, _) => Err(MutateError::invalid(format!(
            "ambiguous {} commit, choose one to target",
            direction.cmd()
        ))),
    }
}

/// The operation description (`move_to_commit`), with the CLI's 12-hex `short_commit_hash`.
fn tx_description(direction: Direction, should_edit: bool, from: &CommitId, to: &CommitId) -> String {
    let editing = if should_edit { "editing " } else { "" };
    format!("{}: {:.12} -> {editing}{:.12}", direction.cmd(), from.hex(), to.hex())
}

/// [`crate::Repo::movement_targets`] — the verb up to choosing a target.
///
/// # Errors
///
/// See [`crate::Repo::movement_targets`].
pub(crate) fn movement_targets(
    workspace: &Workspace,
    ctx: &VerbContext,
    options: &MovementOptions,
) -> Result<MovementTargets, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let plan = plan_movement(&readonly, workspace, ctx, options)?;
    Ok(MovementTargets {
        edit: plan.should_edit,
        targets: plan
            .targets
            .iter()
            .map(|commit| MovementTarget {
                commit_id: crate::CommitId(commit.id().hex()),
                change_id: ChangeId(commit.change_id().reverse_hex()),
            })
            .collect(),
    })
}

/// `jj next` / `jj prev` (Story 9.10) — see [`crate::Repo::move_working_copy`], which ran
/// [`check_movement_args`] before the snapshot.
///
/// # Errors
///
/// See [`crate::Repo::move_working_copy`].
pub(crate) fn move_working_copy(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &MovementOptions,
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let plan = plan_movement(&readonly, workspace, ctx, options)?;
    let target = choose_target(options.direction, &plan, options.target.as_ref())?;
    let description = tx_description(options.direction, plan.should_edit, &plan.wc_id, target.id());

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    if plan.should_edit {
        guard_rewritable(&tx, &ctx.templates(workspace), std::slice::from_ref(target.id()))?;
        pollster::block_on(tx.repo_mut().edit(workspace_name, target)).map_err(be)?;
    } else {
        pollster::block_on(tx.repo_mut().check_out(workspace_name, target)).map_err(be)?;
    }
    // See `mutate::edit`: leaving a discardable `@` abandons it, a rewrite to rebase before commit.
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let finish = finish_verb(workspace, tx, &description, ctx)?;
    Ok(mutation_result(&finish, Vec::new(), Vec::new()))
}

#[cfg(test)]
mod tests {
    use jj_lib::backend::CommitId;
    use jj_lib::revset::RevsetExpression;

    use super::{
        build_target_revset, check_movement_args, not_found_message, tx_description, Direction, MovementOptions,
    };
    use crate::mutate::MutateError;

    fn reason(options: &MovementOptions) -> Option<String> {
        check_movement_args(options).err().map(|e| {
            assert!(matches!(&e, MutateError::InvalidInput { hints, .. } if hints.is_empty()));
            e.to_string().replacen("invalid input: ", "", 1)
        })
    }

    #[test]
    fn check_movement_args_refuses_what_clap_refuses() {
        assert_eq!(reason(&MovementOptions::default()), None);
        let conflict = MovementOptions {
            conflict: true,
            ..MovementOptions::default()
        };
        assert_eq!(reason(&conflict), None, "clap never fires on the default offset");
        assert_eq!(
            reason(&MovementOptions {
                offset: Some(1),
                ..conflict.clone()
            })
            .as_deref(),
            Some("the argument '--conflict' cannot be used with '[OFFSET]'")
        );
        let both = MovementOptions {
            edit: true,
            no_edit: true,
            ..MovementOptions::default()
        };
        assert_eq!(
            reason(&both).as_deref(),
            Some("the argument '--edit' cannot be used with '--no-edit'")
        );
        assert_eq!(
            reason(&MovementOptions {
                offset: Some(2),
                conflict: true,
                direction: Direction::Prev,
                ..both
            })
            .as_deref(),
            Some("the argument '--edit' cannot be used with '--no-edit'"),
            "the edit pair first"
        );
    }

    #[test]
    fn not_found_messages_are_the_clis_eight() {
        let message = |direction, edit, conflict| not_found_message(direction, edit, conflict, 3);
        assert_eq!(
            message(Direction::Next, true, true),
            "The working copy has no descendants with conflicts"
        );
        assert_eq!(
            message(Direction::Next, true, false),
            "No descendant found 3 commit(s) forward from the working copy"
        );
        assert_eq!(
            message(Direction::Next, false, true),
            "The working copy parent(s) have no other descendants with conflicts"
        );
        assert_eq!(
            message(Direction::Next, false, false),
            "No other descendant found 3 commit(s) forward from the working copy parent(s)"
        );
        assert_eq!(
            message(Direction::Prev, true, true),
            "The working copy has no ancestors with conflicts"
        );
        assert_eq!(
            message(Direction::Prev, true, false),
            "No ancestor found 3 commit(s) back from the working copy"
        );
        assert_eq!(
            message(Direction::Prev, false, true),
            "The working copy parent(s) have no ancestors with conflicts"
        );
        assert_eq!(
            message(Direction::Prev, false, false),
            "No ancestor found 3 commit(s) back from the working copy parents(s)"
        );
    }

    #[test]
    fn tx_descriptions_use_twelve_hex_digits() {
        let from = CommitId::from_hex("0123456789abcdef0123456789abcdef01234567");
        let to = CommitId::from_hex("fedcba9876543210fedcba9876543210fedcba98");
        assert_eq!(
            tx_description(Direction::Next, false, &from, &to),
            "next: 0123456789ab -> fedcba987654"
        );
        assert_eq!(
            tx_description(Direction::Prev, true, &from, &to),
            "prev: 0123456789ab -> editing fedcba987654"
        );
    }

    /// The release CLI's `args.offset - 1` wraps: offset 0 asks for generation `u64::MAX`.
    #[test]
    fn non_edit_next_offset_zero_wraps_to_an_empty_generation() {
        let wc = RevsetExpression::commit(CommitId::from_hex("aa"));
        let start = wc.parents();
        let wrapped = build_target_revset(Direction::Next, &wc, &start, false, false, 0);
        let max = u64::MAX;
        assert!(
            format!("{wrapped:?}").contains(&format!("generation: {max}..{max}")),
            "{wrapped:?}"
        );
        let one = build_target_revset(Direction::Next, &wc, &start, false, false, 1);
        assert!(format!("{one:?}").contains("generation: 0..1"), "{one:?}");
    }
}
