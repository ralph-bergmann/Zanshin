// SPDX-License-Identifier: MIT

//! `op_diff.rs` — the repository changes between two operations as typed data (Story 9.21): the
//! port of the CLI's `show_op_diff` / `compute_operation_commits_diff`
//! (`cli/src/commands/operation/diff.rs` @ v0.46.0) that `op show` and `op diff` share.
//!
//! The CLI prints six sections — changed commits, working copies, local bookmarks, local tags,
//! remote bookmarks, remote tags — through commit-summary templates, a graph and optional
//! patches. Here each section is a list of ids and facts in the CLI's order; the GUI composes
//! summaries (`commit_contents`) and patches (`interdiff` / `show`) from the ids and lays the
//! rows out itself. The commit rows come in the flat (`--no-graph`) revset order.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::slice;
use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::{ChangeId as JjChangeId, CommitId as JjCommitId};
use jj_lib::evolution::accumulate_predecessors;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::{RefTarget, RemoteRef};
use jj_lib::refs::{diff_named_commit_ids, diff_named_ref_targets, diff_named_remote_refs};
use jj_lib::repo::ReadonlyRepo;
use jj_lib::revset::{ResolvedRevsetExpression, RevsetExpression, UserRevsetExpression};
use jj_lib::workspace::Workspace;

use crate::mutate::{be, cfg, MutateError};
use crate::snapshot::VerbContext;
use crate::warning::WarningKind;
use crate::{CommitId, RefDistance};

/// The config key `op show` / `op diff` read when no `show_changes_in` is given.
const CHANGES_IN_KEY: &str = "revsets.op-diff-changes-in";

/// The repository changes from one operation to another — the CLI's `show_op_diff` output as
/// data, section by section in its order. Every list is empty when its section has nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpDiff {
    /// The created, rewritten and abandoned commits within `show_changes_in`; `None` when that
    /// revset did not resolve against one of the two operations (warned
    /// [`WarningKind::OpDiffChangesUnresolved`]) — the CLI then prints no commit section.
    pub commits: Option<OpCommitsDiff>,
    /// The workspaces whose working-copy commit changed, by workspace name.
    pub working_copies: Vec<OpWorkingCopyChange>,
    /// The local bookmarks whose target changed, by name.
    pub local_bookmarks: Vec<OpRefChange>,
    /// The local tags whose target changed, by name.
    pub local_tags: Vec<OpRefChange>,
    /// The remote bookmarks whose target or tracking state changed, by name then remote; the
    /// `git` pseudo-remote of a Git-backed repo is left out, as the CLI leaves it out.
    pub remote_bookmarks: Vec<OpRemoteRefChange>,
    /// The remote tags whose target or tracking state changed, as `remote_bookmarks`.
    pub remote_tags: Vec<OpRemoteRefChange>,
}

/// The CLI's "Changed commits" section (`compute_operation_commits_diff`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpCommitsDiff {
    /// One row per changed commit, in the revset order of the CLI's flat list.
    pub changes: Vec<OpChangedCommit>,
    /// How many newly visible commits lie outside `show_changes_in` (the CLI's "Elided … newly
    /// added" count); `(0, Some(0))` when none.
    pub elided_newly_visible: RefDistance,
    /// How many newly hidden commits lie outside `show_changes_in` ("… newly removed").
    pub elided_newly_hidden: RefDistance,
}

/// One changed commit (the CLI's `ModifiedChange`): its `+` and `-` lines as ids.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpChangedCommit {
    /// The row's key: the new commit for a created or rewritten change, the old one for an
    /// abandoned change.
    pub commit_id: CommitId,
    /// Whether the change was abandoned (`added_commit_ids` is then empty and
    /// `removed_commit_ids` holds `commit_id`).
    pub abandoned: bool,
    /// The commit the change now is (the CLI's `+` line); empty when abandoned.
    pub added_commit_ids: Vec<CommitId>,
    /// The commits it replaced — its predecessors — or, when abandoned, the commit itself (the
    /// CLI's `-` lines). Empty for a newly created commit. The CLI's `--patch` inter-diffs from
    /// the FIRST predecessor only, and shows an abandoned commit's own patch
    /// (`show_change_diff`, `cli/src/commands/operation/diff.rs` @ v0.46.0).
    pub removed_commit_ids: Vec<CommitId>,
}

/// A workspace whose working-copy commit changed (the CLI's "Changed working copy <name>@").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpWorkingCopyChange {
    /// The workspace name.
    pub workspace: String,
    /// The working-copy commit before; `None` when the workspace did not exist.
    pub from: Option<CommitId>,
    /// The working-copy commit after; `None` when the workspace was removed.
    pub to: Option<CommitId>,
}

/// A local bookmark or tag whose target changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpRefChange {
    /// The ref's name.
    pub name: String,
    /// The target before.
    pub from: OpRefTarget,
    /// The target after.
    pub to: OpRefTarget,
}

/// A remote bookmark or tag whose target or tracking state changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpRemoteRefChange {
    /// The ref's name.
    pub name: String,
    /// The remote's name.
    pub remote: String,
    /// The target before.
    pub from: OpRefTarget,
    /// Whether the ref was tracked before (the CLI's `tracked` / `untracked`).
    pub from_tracked: bool,
    /// The target after.
    pub to: OpRefTarget,
    /// Whether the ref is tracked after.
    pub to_tracked: bool,
}

/// A ref target as the CLI summarises it (`write_ref_target_summary`): absent (`adds` empty,
/// not `conflicted`), one commit, or a conflict's present adds and removes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpRefTarget {
    /// The commit a normal target points at, or a conflict's present added commits.
    pub adds: Vec<CommitId>,
    /// A conflict's present removed commits; empty unless `conflicted`.
    pub removes: Vec<CommitId>,
    /// Whether the target is a conflict.
    pub conflicted: bool,
}

/// The CLI's `parse_op_diff_changes_in` (`diff.rs:189-223` @ v0.46.0): `show_changes_in`, or the
/// effective `revsets.op-diff-changes-in`, parsed with its diagnostics recorded under the CLI's
/// context line.
///
/// # Errors
///
/// - [`MutateError::Config`] — the config value is not a string or does not parse ("Invalid
///   `revsets.op-diff-changes-in`: …"), or the alias tables do not read.
/// - [`MutateError::RevsetParseError`] — `show_changes_in` does not parse ("Invalid
///   `--show-changes-in` expression: <text>: …").
pub(crate) fn parse_changes_in(
    workspace: &Workspace,
    ctx: &mut VerbContext,
    show_changes_in: Option<&str>,
) -> Result<Arc<UserRevsetExpression>, MutateError> {
    let (text, is_config) = if let Some(text) = show_changes_in {
        (text.to_owned(), false)
    } else {
        let text: String = ctx
            .config
            .get(CHANGES_IN_KEY)
            .map_err(|e| cfg(crate::config::value_error(&e)))?;
        (text, true)
    };
    let context = if is_config {
        "In `revsets.op-diff-changes-in`"
    } else {
        "In `--show-changes-in`"
    };
    let parse_config = crate::revset::revset_config(&ctx.config, &mut ctx.warnings).map_err(cfg)?;
    crate::revset::parse_diagnosed(workspace, &parse_config, (&text, context), &mut ctx.warnings).map_err(|e| {
        let reason = crate::template::parse_reason(e);
        if is_config {
            MutateError::Config {
                reason: format!("Invalid `{CHANGES_IN_KEY}`: {reason}"),
            }
        } else {
            MutateError::RevsetParseError {
                reason: format!("Invalid `--show-changes-in` expression: {text}: {reason}"),
                hints: Vec::new(),
            }
        }
    })
}

/// The CLI's `show_op_diff` (`diff.rs:253-582` @ v0.46.0) as data: the changes from `from_repo`
/// to `to_repo`, with `current` holding both repos' commits in its index (the CLI's
/// `current_repo`). A `changes_in` that does not resolve against either repo warns
/// [`WarningKind::OpDiffChangesUnresolved`] and leaves `commits` `None`, as the CLI goes on
/// without its commit section.
///
/// # Errors
///
/// [`MutateError::Backend`] — an index, revset or predecessor walk failed.
pub(crate) fn op_diff(
    ctx: &mut VerbContext,
    current: &dyn jj_lib::repo::Repo,
    (from_repo, to_repo): (&Arc<ReadonlyRepo>, &Arc<ReadonlyRepo>),
    changes_in: &Arc<UserRevsetExpression>,
) -> Result<OpDiff, MutateError> {
    let commits = match resolve_both(changes_in, from_repo, to_repo) {
        Ok(exprs) => Some(commits_diff(current, (from_repo, to_repo), exprs)?),
        Err(reason) => {
            ctx.warnings.push(
                WarningKind::OpDiffChangesUnresolved,
                format!("Could not resolve revset expression for elision: {reason}\n   (Use --show-changes-in=all() to see all changes)"),
            );
            None
        }
    };
    let (from, to) = (from_repo.view(), to_repo.view());
    let working_copies = diff_named_commit_ids(from.wc_commit_ids(), to.wc_commit_ids())
        .map(|(name, (before, after))| OpWorkingCopyChange {
            workspace: name.as_str().to_owned(),
            from: before.map(commit_id),
            to: after.map(commit_id),
        })
        .collect();
    let ref_change = |(name, (before, after)): (&jj_lib::ref_name::RefName, (&RefTarget, &RefTarget))| OpRefChange {
        name: name.as_str().to_owned(),
        from: ref_target(before),
        to: ref_target(after),
    };
    let local_bookmarks = diff_named_ref_targets(from.local_bookmarks(), to.local_bookmarks())
        .map(ref_change)
        .collect();
    let local_tags = diff_named_ref_targets(from.local_tags(), to.local_tags())
        .map(ref_change)
        .collect();
    let ignored = jj_lib::git::get_git_backend(current.store())
        .is_ok()
        .then_some(jj_lib::git::REMOTE_NAME_FOR_LOCAL_GIT_REPO);
    let remote_changes = |pairs: Vec<(jj_lib::ref_name::RemoteRefSymbol<'_>, (&RemoteRef, &RemoteRef))>| {
        pairs
            .into_iter()
            .filter(|(symbol, _)| ignored.is_none_or(|ignored| symbol.remote != ignored))
            .map(|(symbol, (before, after))| OpRemoteRefChange {
                name: symbol.name.as_str().to_owned(),
                remote: symbol.remote.as_str().to_owned(),
                from: ref_target(&before.target),
                from_tracked: before.is_tracked(),
                to: ref_target(&after.target),
                to_tracked: after.is_tracked(),
            })
            .collect()
    };
    let remote_bookmarks =
        remote_changes(diff_named_remote_refs(from.all_remote_bookmarks(), to.all_remote_bookmarks()).collect());
    let remote_tags = remote_changes(diff_named_remote_refs(from.all_remote_tags(), to.all_remote_tags()).collect());
    Ok(OpDiff {
        commits,
        working_copies,
        local_bookmarks,
        local_tags,
        remote_bookmarks,
        remote_tags,
    })
}

/// `changes_in` resolved against the from-repo and the to-repo — the CLI's
/// `resolve_op_diff_changes_exprs` (`diff.rs:227-246`); the error is jj-lib's resolution text.
fn resolve_both(
    changes_in: &Arc<UserRevsetExpression>,
    from_repo: &Arc<ReadonlyRepo>,
    to_repo: &Arc<ReadonlyRepo>,
) -> Result<(Arc<ResolvedRevsetExpression>, Arc<ResolvedRevsetExpression>), String> {
    let resolve = |repo: &Arc<ReadonlyRepo>| {
        crate::revset::resolve_expression(repo.as_ref(), changes_in).map_err(|e| match e {
            crate::RevsetError::ResolutionError { reason } => reason,
            other => other.to_string(),
        })
    };
    Ok((resolve(from_repo)?, resolve(to_repo)?))
}

/// The CLI's `compute_operation_commits_diff` (`diff.rs:739-823` @ v0.46.0), ordered by the
/// revset of its keys as the flat list prints them.
///
/// # Errors
///
/// [`MutateError::Backend`] — an evaluation or the predecessor walk failed.
fn commits_diff(
    current: &dyn jj_lib::repo::Repo,
    (from_repo, to_repo): (&Arc<ReadonlyRepo>, &Arc<ReadonlyRepo>),
    (from_changes_in, to_changes_in): (Arc<ResolvedRevsetExpression>, Arc<ResolvedRevsetExpression>),
) -> Result<OpCommitsDiff, MutateError> {
    let heads = |repo: &Arc<ReadonlyRepo>| RevsetExpression::commits(repo.view().heads().iter().cloned().collect());
    let (from_expr, to_expr) = (heads(from_repo), heads(to_repo));
    let newly_hidden_expr = to_expr.range(&from_expr);
    let newly_visible_expr = from_expr.range(&to_expr);

    let predecessors: BTreeMap<JjCommitId, Vec<JjCommitId>> = pollster::block_on(accumulate_predecessors(
        slice::from_ref(to_repo.operation()),
        slice::from_ref(from_repo.operation()),
    ))
    .map_err(be)?;

    let estimate = |expr: Arc<ResolvedRevsetExpression>| -> Result<RefDistance, MutateError> {
        let (lower, upper) = expr.evaluate(current).map_err(be)?.count_estimate().map_err(be)?;
        Ok(RefDistance {
            lower: lower as u64,
            upper: upper.map(|upper| upper as u64),
        })
    };
    let elided_newly_visible = estimate(newly_visible_expr.minus(&to_changes_in))?;
    let elided_newly_hidden = estimate(newly_hidden_expr.minus(&from_changes_in))?;

    let pairs = |expr: Arc<ResolvedRevsetExpression>| -> Result<Vec<(JjCommitId, JjChangeId)>, MutateError> {
        let set = expr.evaluate(current).map_err(be)?;
        pollster::block_on(set.commit_change_ids().try_collect()).map_err(be)
    };
    // Divergent hidden commits: just pick one, as the CLI does — they are not "squashed" into
    // the new commit.
    let mut hidden_by_change: HashMap<JjChangeId, JjCommitId> = HashMap::new();
    let mut abandoned: HashSet<JjCommitId> = HashSet::new();
    for (commit, change) in pairs(newly_hidden_expr.intersection(&from_changes_in))? {
        hidden_by_change.entry(change).or_insert_with(|| commit.clone());
        abandoned.insert(commit);
    }
    let mut rows: HashMap<JjCommitId, OpChangedCommit> = HashMap::new();
    for (commit, change) in pairs(newly_visible_expr.intersection(&to_changes_in))? {
        let replaced: &[JjCommitId] = match (predecessors.get(&commit), hidden_by_change.get(&change)) {
            (Some(ids), _) => ids,
            (None, Some(id)) => slice::from_ref(id),
            (None, None) => &[],
        };
        for id in replaced {
            abandoned.remove(id);
        }
        rows.insert(
            commit.clone(),
            OpChangedCommit {
                commit_id: commit_id(&commit),
                abandoned: false,
                added_commit_ids: vec![commit_id(&commit)],
                removed_commit_ids: replaced.iter().map(commit_id).collect(),
            },
        );
    }
    for commit in abandoned {
        rows.insert(
            commit.clone(),
            OpChangedCommit {
                commit_id: commit_id(&commit),
                abandoned: true,
                added_commit_ids: Vec::new(),
                removed_commit_ids: vec![commit_id(&commit)],
            },
        );
    }

    let keys: Vec<JjCommitId> = rows.keys().cloned().collect();
    let order = RevsetExpression::commits(keys).evaluate(current).map_err(be)?;
    let ordered: Vec<JjCommitId> = pollster::block_on(order.stream().try_collect()).map_err(be)?;
    Ok(OpCommitsDiff {
        changes: ordered.iter().filter_map(|id| rows.remove(id)).collect(),
        elided_newly_visible,
        elided_newly_hidden,
    })
}

/// A ref target as the CLI's `write_ref_target_summary` (`diff.rs:641-690`) shows it.
fn ref_target(target: &RefTarget) -> OpRefTarget {
    if target.is_resolved() {
        OpRefTarget {
            adds: target.as_normal().map(commit_id).into_iter().collect(),
            removes: Vec::new(),
            conflicted: false,
        }
    } else {
        OpRefTarget {
            adds: target.present_adds().map(commit_id).collect(),
            removes: target.present_removes().map(commit_id).collect(),
            conflicted: true,
        }
    }
}

/// A jj-lib commit id as this crate's hex [`CommitId`].
fn commit_id(id: &JjCommitId) -> CommitId {
    CommitId(id.hex())
}

#[cfg(test)]
mod tests {
    use jj_lib::backend::CommitId as JjCommitId;
    use jj_lib::op_store::RefTarget;

    use super::{ref_target, OpRefTarget};
    use crate::CommitId;

    fn id(byte: u8) -> JjCommitId {
        JjCommitId::new(vec![byte; 20])
    }

    fn hex(byte: u8) -> CommitId {
        CommitId(format!("{byte:02x}").repeat(20))
    }

    /// The three shapes `write_ref_target_summary` prints: absent, one commit, a conflict's
    /// present adds and removes.
    #[test]
    fn ref_targets_map_like_the_cli_summary() {
        assert_eq!(
            ref_target(&RefTarget::absent()),
            OpRefTarget {
                adds: vec![],
                removes: vec![],
                conflicted: false
            }
        );
        assert_eq!(
            ref_target(&RefTarget::normal(id(1))),
            OpRefTarget {
                adds: vec![hex(1)],
                removes: vec![],
                conflicted: false
            }
        );
        let conflict = RefTarget::from_legacy_form([id(3)], [id(1), id(2)]);
        assert_eq!(
            ref_target(&conflict),
            OpRefTarget {
                adds: vec![hex(1), hex(2)],
                removes: vec![hex(3)],
                conflicted: true
            }
        );
    }
}
