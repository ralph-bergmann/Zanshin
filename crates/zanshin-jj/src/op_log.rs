// SPDX-License-Identifier: MIT

//! `op_log.rs` — jj operation-log read (FR-JJ-7) and the operation verbs: `undo` (Story 9.39),
//! `redo`, `op show`, `op diff` and `op abandon` (Story 9.21), `op restore`, `op revert` and
//! `op integrate` (Story 9.12).
//!
//! Exposes a `jj_lib`-type-free view of jj's operation log: a reverse-
//! chronological list of operations (head first, root last). The read
//! re-resolves to the head operation per call (ADR-0002) and never shells to
//! the `jj` CLI (AR-AP-1).
//!
//! Operation expressions (`@`, `@-`, `@+`, id prefixes) resolve through jj-lib's `op_walk`
//! exactly as the CLI resolves them: `op show` / `op diff` / `op restore` / `op revert` /
//! `op integrate` at the head repo (the CLI's `resolve_single_op`), `op abandon` at the current,
//! unmerged op heads.

use std::slice;
use std::sync::Arc;

use futures::StreamExt as _;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_heads_store;
use jj_lib::op_store;
use jj_lib::op_walk::{self, OpsetEvaluationError, OpsetResolutionError};
use jj_lib::operation::Operation as JjOperation;
use jj_lib::repo::{ReadonlyRepo, Repo as _, RepoLoader, RepoLoaderError};
use jj_lib::workspace::Workspace;

use crate::mutate::{self, MutateError, MutationResult};
use crate::op_diff::OpDiff;
use crate::op_support::start_repo_transaction;
use crate::snapshot::VerbContext;
use crate::warning::{WarningKind, Warnings};
use crate::Timestamp;

/// A jj operation-log id in plain forward-hex display form (e.g. `"abc123…"`).
///
/// NOT reverse-hex — operation ids are not change ids. `jj_lib`-type-free (FR-JJ-16).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperationId(pub String);

/// One entry in jj's operation log (FR-JJ-7).
///
/// `user`/`host` come from jj-lib `String` fields and are UTF-8 by construction
/// (no lossy conversion needed — jj-lib stores `OperationMetadata.username` /
/// `.hostname` as `String`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Operation {
    /// Forward-hex op id (`op.id().hex()`).
    pub id: OperationId,
    /// Parent op ids in jj order; empty for the root op. May have >1 entries for a DAG fork.
    pub parent_ids: Vec<OperationId>,
    /// Operation completion time (`metadata.time.end`), raw jj timestamp.
    pub timestamp: Timestamp,
    /// `metadata.username` — may be empty.
    pub user: String,
    /// `metadata.hostname` — may be empty.
    pub host: String,
    /// jj's user-friendly op description; always present, may be empty (root op = `""`).
    pub description: String,
    /// `true` iff this is the op-store root operation (parents empty).
    pub root_op: bool,
    /// `true` if a pure working-copy snapshot op (`metadata.is_snapshot`).
    pub is_snapshot: bool,
    /// The workspace the operation was performed in (`metadata.workspace_name`, Story 9.21);
    /// `None` when it records none (the root operation, an operation another tool wrote).
    pub workspace_name: Option<String>,
    /// The operation's tags — jj's `OperationMetadata.attributes`, e.g. the CLI's `args` —
    /// sorted by key (Story 9.21). Empty when it has none.
    pub tags: Vec<OperationTag>,
}

/// One tag of an [`Operation`]: a key and its value (Story 9.21).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperationTag {
    /// The tag's key.
    pub key: String,
    /// The tag's value.
    pub value: String,
}

/// Errors returned by [`crate::Repo::op_log`].
#[derive(Debug, thiserror::Error)]
pub enum OpLogError {
    /// An underlying jj-lib failure (op-store read / loader / walk),
    /// opaque-string-wrapped so no `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
    /// The pre-verb snapshot failed (Story 9.26); the log was not read.
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
}

/// Converts any jj-lib error to [`OpLogError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> OpLogError {
    OpLogError::Backend(e.to_string())
}

/// Reads the operation log, most-recent-first, root op last (FR-JJ-7).
///
/// Re-resolves to the head operation every call (ADR-0002). Read-only; never
/// shells to `jj op log` (AR-AP-1). `limit = None` means "all"; `Some(0)`
/// returns an empty `Vec`.
///
/// # Errors
///
/// - [`OpLogError::Backend`] — `load_at_head` or the op-store walk failed; the
///   jj-lib reason is forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn op_log(workspace: &Workspace, limit: Option<usize>) -> Result<Vec<Operation>, OpLogError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let root_id = readonly.op_store().root_operation_id().clone();
    let head_op = readonly.operation().clone();

    let mut out = Vec::new();
    pollster::block_on(async {
        let mut stream = Box::pin(op_walk::walk_ancestors(std::slice::from_ref(&head_op)));
        loop {
            // Check the limit BEFORE pulling the next item: a limited walk never
            // fetches — and so never silently discards — the (n+1)th op's Result.
            if limit.is_some_and(|n| out.len() >= n) {
                break;
            }
            let Some(item) = stream.next().await else {
                break;
            };
            let op = item.map_err(be)?;
            out.push(operation(&op, &root_id));
        }
        Ok::<(), OpLogError>(())
    })?;
    Ok(out)
}

/// `op` as this crate's [`Operation`]; `root_id` is the op store's root operation id.
fn operation(op: &JjOperation, root_id: &op_store::OperationId) -> Operation {
    let md = op.metadata();
    let end = md.time.end;
    Operation {
        id: OperationId(op.id().hex()),
        parent_ids: op.parent_ids().iter().map(|p| OperationId(p.hex())).collect(),
        timestamp: Timestamp {
            millis_since_epoch: end.timestamp.0,
            tz_offset_minutes: end.tz_offset,
        },
        user: md.username.clone(),
        host: md.hostname.clone(),
        description: md.description.clone(),
        root_op: op.id() == root_id,
        is_snapshot: md.is_snapshot,
        workspace_name: md.workspace_name.as_ref().map(|name| name.as_str().to_owned()),
        tags: md
            .attributes
            .iter()
            .map(|(key, value)| OperationTag {
                key: key.clone(),
                value: value.clone(),
            })
            .collect(),
    }
}

/// Undoes the last operation — the port of the CLI's `cmd_undo` (`cli/src/commands/undo.rs` @
/// v0.46.0) with its undo STACK (Story 9.39): a repeated `undo` goes further back into the past.
///
/// The step, as in the CLI:
///
/// 1. The target is the head operation — unless the head is itself an undo operation
///    (description `undo: restore to operation <hex>`), then it is the operation that undo
///    restored to, so the next undo goes one further back.
/// 2. Unless `allow_cross_workspace`, a target performed in ANOTHER workspace refuses
///    ([`MutateError::UndoCrossWorkspace`], jj 0.46). An operation that records no workspace
///    never refuses.
/// 3. Undoing a `push …` operation warns `jj.undo_push_operation`, undoing a `remove workspace…`
///    operation `jj.undo_workspace_removal` — the CLI's two warnings, in its order.
/// 4. The target's single parent is restored; when that parent is an undo operation itself, the
///    operation IT restored to is used instead, so undos never form a linked list.
/// 5. The restored view takes the repo state (`head_ids`, local bookmarks/tags, `wc_commit_ids`)
///    and the remote-tracking bookmarks from the restored operation and keeps `git_refs` /
///    `git_heads` at their current values (`DEFAULT_REVERT_WHAT`), committed as
///    `undo: restore to operation <hex>` — the description is the stack: the CLI and Zanshin
///    continue each other's undo stacks through it.
/// 6. A restored view EQUAL to the current one writes no operation — the CLI's `tx.finish` prints
///    "Nothing changed." (Story 9.40) — and the result carries the pre-call head op id.
///
/// No `rebase_descendants()` call — a raw `set_view` records no rewrites, matching the
/// CLI (which doesn't call it either).
///
/// # Errors
///
/// - [`MutateError::UndoCrossWorkspace`] — the target was performed in another workspace and
///   `allow_cross_workspace` is `false`.
/// - [`MutateError::NothingToUndo`] — the target is the op-store root operation ("Cannot undo
///   root operation"), e.g. after an undo stack walked back to the very first operation.
/// - [`MutateError::InvalidInput`] — the target has more than one parent (a "reconcile divergent
///   operations" merge op) — the CLI's "Cannot undo a merge operation".
/// - [`MutateError::Backend`] — an undo operation's description names no valid operation id, or
///   an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn undo(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    allow_cross_workspace: bool,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let workspace_name = workspace.workspace_name().to_owned();

    let target_op = through_prefix(
        workspace,
        readonly.operation().clone(),
        (
            UNDO_OP_DESC_PREFIX,
            "Failed to parse ID of target operation in undo-stack",
        ),
    )?;
    if !allow_cross_workspace {
        if let Some(op_workspace) = &target_op.metadata().workspace_name {
            if *op_workspace != workspace_name {
                return Err(MutateError::UndoCrossWorkspace {
                    operation: format!("{:.12}", target_op.id()),
                    workspace: op_workspace.as_str().to_owned(),
                });
            }
        }
    }
    let description = &target_op.metadata().description;
    if description.starts_with(PUSH_OP_DESC_PREFIX) {
        ctx.warnings.push(WarningKind::UndoPushOperation, UNDO_PUSH_OPERATION);
    }
    if description.starts_with("remove workspace") {
        ctx.warnings
            .push(WarningKind::UndoWorkspaceRemoval, UNDO_WORKSPACE_REMOVAL);
    }

    let parents = pollster::block_on(target_op.parents()).map_err(mutate::be)?;
    let target_parent = match <[JjOperation; 1]>::try_from(parents) {
        Ok([parent]) => parent,
        Err(parents) if parents.is_empty() => return Err(MutateError::NothingToUndo),
        Err(_) => {
            return Err(MutateError::invalid_hinted(
                "Cannot undo a merge operation",
                "Consider using `jj op restore` instead",
            ))
        }
    };
    let target_parent = through_prefix(
        workspace,
        target_parent,
        (
            UNDO_OP_DESC_PREFIX,
            "Failed to parse ID of target operation's parent in undo-stack",
        ),
    )?;
    let target_view = pollster::block_on(target_parent.view()).map_err(mutate::be)?;

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    tx.repo_mut().set_view(view_with_desired_portions_restored(
        target_view.store_view(),
        readonly.view().store_view(),
        &DEFAULT_RESTORE_WHAT,
    ));
    let description = format!("{UNDO_OP_DESC_PREFIX}{}", target_parent.id().hex());
    let finish = mutate::finish_verb(workspace, tx, &description, ctx)?;
    Ok(mutate::mutation_result(&finish, Vec::new(), Vec::new()))
}

/// The description prefix that makes an operation an undo operation — the CLI's
/// `UNDO_OP_DESC_PREFIX` (`cli/src/commands/undo.rs:55` @ v0.46.0). It is the undo stack's only
/// record, so it must stay byte-identical to the CLI's.
const UNDO_OP_DESC_PREFIX: &str = "undo: restore to operation ";

/// The description prefix of a `jj git push` operation — the CLI's `TX_DESC_PUSH`, which
/// `is_push_operation` tests (`cli/src/commands/git/push.rs:272`, `:1492-1494` @ v0.46.0).
const PUSH_OP_DESC_PREFIX: &str = "push ";

/// The CLI's warning for undoing a push (`undo.rs:134-141` @ v0.46.0), minus its hint.
const UNDO_PUSH_OPERATION: &str = "Undoing a push operation often leads to conflicted bookmarks.";

/// The CLI's warning for undoing a workspace removal (`undo.rs:142-156` @ v0.46.0), minus its
/// hint.
const UNDO_WORKSPACE_REMOVAL: &str =
    "Undoing a workspace removal restores the workspace, but does not restore the workspace directory.";

/// `op` itself — or, when `op`'s description starts with `prefix` (an undo or a redo operation),
/// the operation it restored to (the CLI's `strip_prefix(UNDO_OP_DESC_PREFIX)` /
/// `strip_prefix(REDO_OP_DESC_PREFIX)` look-ups). A description whose id does not parse is the
/// CLI's internal error `parse_failure`.
fn through_prefix(
    workspace: &Workspace,
    op: JjOperation,
    (prefix, parse_failure): (&str, &str),
) -> Result<JjOperation, MutateError> {
    let Some(hex) = op.metadata().description.strip_prefix(prefix) else {
        return Ok(op);
    };
    let id = op_store::OperationId::try_from_hex(hex).ok_or_else(|| MutateError::Backend(parse_failure.to_owned()))?;
    pollster::block_on(workspace.repo_loader().load_operation(&id)).map_err(mutate::be)
}

/// What portions of the local state `op restore` / `op revert` restore (Story 9.12) — the CLI's
/// `RevertWhatToRestore` (`cli/src/commands/operation/mod.rs:76-84` @ v0.46.0), one `--what`
/// value each.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum RestoreWhat {
    /// `repo`: the jj repo state and local bookmarks — `head_ids`, local bookmarks and tags, the
    /// working-copy commits.
    Repo,
    /// `remote-tracking`: the remote-tracking bookmarks (`remote_views`). Do not restore these to
    /// push after the restore.
    RemoteTracking,
}

/// The CLI's `DEFAULT_REVERT_WHAT` (`operation/mod.rs:87-90` @ v0.46.0): both portions — what
/// `undo` / `redo` always restore and what an empty `what` list (the flag absent) means.
const DEFAULT_RESTORE_WHAT: [RestoreWhat; 2] = [RestoreWhat::Repo, RestoreWhat::RemoteTracking];

/// The port of the CLI's `view_with_desired_portions_restored` (`operation/mod.rs:93-117` @
/// v0.46.0), shared by `undo`, `redo`, `op restore` and `op revert`: the repo portion (`head_ids`,
/// local bookmarks/tags, `wc_commit_ids`) comes from `being_restored` when `what` contains
/// [`RestoreWhat::Repo`], the remote portion (`remote_views`) when it contains
/// [`RestoreWhat::RemoteTracking`], each else from `current`; `git_refs` / `git_heads` always stay
/// at `current`. An empty `what` is the CLI without `--what`: [`DEFAULT_RESTORE_WHAT`].
fn view_with_desired_portions_restored(
    being_restored: &op_store::View,
    current: &op_store::View,
    what: &[RestoreWhat],
) -> op_store::View {
    let what = if what.is_empty() {
        &DEFAULT_RESTORE_WHAT[..]
    } else {
        what
    };
    let repo_source = if what.contains(&RestoreWhat::Repo) {
        being_restored
    } else {
        current
    };
    let remote_source = if what.contains(&RestoreWhat::RemoteTracking) {
        being_restored
    } else {
        current
    };
    op_store::View {
        head_ids: repo_source.head_ids.clone(),
        local_bookmarks: repo_source.local_bookmarks.clone(),
        local_tags: repo_source.local_tags.clone(),
        remote_views: remote_source.remote_views.clone(),
        git_refs: current.git_refs.clone(),
        git_heads: current.git_heads.clone(),
        wc_commit_ids: repo_source.wc_commit_ids.clone(),
    }
}

/// The description prefix that makes an operation a redo operation — the CLI's
/// `REDO_OP_DESC_PREFIX` (`cli/src/commands/redo.rs:51` @ v0.46.0). Like
/// [`UNDO_OP_DESC_PREFIX`] it is the redo stack's only record, so it must stay byte-identical.
const REDO_OP_DESC_PREFIX: &str = "redo: restore to operation ";

/// Redoes the most recently undone operation — the port of the CLI's `cmd_redo`
/// (`cli/src/commands/redo.rs:51-171` @ v0.46.0, Story 9.21), `undo`'s counterpart.
///
/// The step, as in the CLI:
///
/// 1. The target is the head operation — unless the head is a redo operation, then it is the
///    operation that redo restored to, so a repeated redo goes one further forward.
/// 2. A target that is not an undo operation refuses [`MutateError::NothingToRedo`].
/// 3. Unless `allow_cross_workspace`, a target performed in ANOTHER workspace refuses
///    [`MutateError::RedoCrossWorkspace`]; an operation that records no workspace never refuses.
/// 4. The undo operation's single parent is restored; when that parent is a redo operation
///    itself, the operation IT restored to is used instead, so redos never form a linked list.
/// 5. The restored view is `undo`'s ([`view_with_desired_portions_restored`] with the CLI's
///    `DEFAULT_REVERT_WHAT`), committed as `redo: restore to operation <hex>` — or, equal to the
///    current view, no operation at all and the pre-call head op id (Story 9.40).
///
/// # Errors
///
/// - [`MutateError::NothingToRedo`] — the target is not an undo operation.
/// - [`MutateError::RedoCrossWorkspace`] — the undo operation was performed in another
///   workspace and `allow_cross_workspace` is `false`.
/// - [`MutateError::Backend`] — a redo or undo description names no valid operation id, the undo
///   operation has more than one parent (the CLI's internal "Undo operation should have a single
///   parent"), or an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn redo(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    allow_cross_workspace: bool,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let workspace_name = workspace.workspace_name().to_owned();

    let target_op = through_prefix(
        workspace,
        readonly.operation().clone(),
        (
            REDO_OP_DESC_PREFIX,
            "Failed to parse ID of target operation in redo-stack",
        ),
    )?;
    if !target_op.metadata().description.starts_with(UNDO_OP_DESC_PREFIX) {
        return Err(MutateError::NothingToRedo);
    }
    if !allow_cross_workspace {
        if let Some(op_workspace) = &target_op.metadata().workspace_name {
            if *op_workspace != workspace_name {
                return Err(MutateError::RedoCrossWorkspace {
                    operation: format!("{:.12}", target_op.id()),
                    workspace: op_workspace.as_str().to_owned(),
                });
            }
        }
    }
    let parents = pollster::block_on(target_op.parents()).map_err(mutate::be)?;
    let Ok([target_parent]) = <[JjOperation; 1]>::try_from(parents) else {
        return Err(MutateError::Backend(
            "Undo operation should have a single parent".to_owned(),
        ));
    };
    let target_parent = through_prefix(
        workspace,
        target_parent,
        (
            REDO_OP_DESC_PREFIX,
            "Failed to parse ID of target operation's parent in redo-stack",
        ),
    )?;
    let target_view = pollster::block_on(target_parent.view()).map_err(mutate::be)?;

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    tx.repo_mut().set_view(view_with_desired_portions_restored(
        target_view.store_view(),
        readonly.view().store_view(),
        &DEFAULT_RESTORE_WHAT,
    ));
    let description = format!("{REDO_OP_DESC_PREFIX}{}", target_parent.id().hex());
    let finish = mutate::finish_verb(workspace, tx, &description, ctx)?;
    Ok(mutate::mutation_result(&finish, Vec::new(), Vec::new()))
}

/// What `op show` returns (Story 9.21): the operation and its changes against its parent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpShow {
    /// The operation.
    pub operation: Operation,
    /// The repository changes against its parent; `None` for an operation with more than one
    /// parent, for which the CLI prints no diff.
    pub diff: Option<OpDiff>,
}

/// The arguments of `op diff` (Story 9.21) — the CLI's `jj op diff` flags; `None` is "not
/// given".
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OpDiffOptions {
    /// `--operation`: diff this operation against its parents. With `from` and `to` absent too,
    /// `@`. May NOT be combined with `from` / `to` (clap's `conflicts_with`).
    pub operation: Option<String>,
    /// `--from`: the operation to diff from; with only `to` given, `@`.
    pub from: Option<String>,
    /// `--to`: the operation to diff to; with only `from` given, `@`.
    pub to: Option<String>,
    /// `--show-changes-in`: the revset the commit section is limited to; `None` reads
    /// `revsets.op-diff-changes-in`.
    pub show_changes_in: Option<String>,
}

/// What `op diff` returns (Story 9.21).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpDiffResult {
    /// The operations diffed from — one for `from`, the parents of the `operation` otherwise
    /// (merged into one, as the CLI merges them, when there are several; none for the root).
    pub from: Vec<Operation>,
    /// The operation diffed to.
    pub to: Operation,
    /// The repository changes.
    pub diff: OpDiff,
}

/// Shows one operation — the port of the CLI's `cmd_op_show`
/// (`cli/src/commands/operation/show.rs:83-171` @ v0.46.0, Story 9.21).
///
/// `operation` resolves at the head repo (`@`, `@-`, an id prefix, …). Its parents are merged as
/// the CLI merges them (writing the unpublished merge operation it writes for a merge op), then
/// `show_changes_in` is parsed (the config's `revsets.op-diff-changes-in` when `None`). An
/// operation with more than one parent gets no diff, as in the CLI.
///
/// # Errors
///
/// - [`MutateError::OperationNotFound`] / [`MutateError::InvalidInput`] — `operation` does not
///   resolve to one operation (see [`opset`]).
/// - [`MutateError::Config`] / [`MutateError::RevsetParseError`] — the revset does not parse
///   (see [`crate::op_diff::parse_changes_in`]).
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn op_show(
    workspace: &Workspace,
    ctx: &mut VerbContext,
    operation_str: &str,
    show_changes_in: Option<&str>,
) -> Result<OpShow, MutateError> {
    let loader = workspace.repo_loader();
    let head = pollster::block_on(loader.load_at_head()).map_err(mutate::be)?;
    let op = pollster::block_on(op_walk::resolve_op_with_repo(&head, operation_str)).map_err(opset)?;
    let parent_ops = pollster::block_on(op.parents()).map_err(mutate::be)?;
    let merged_parents = parent_ops.len() > 1;
    let parent_repo = merged_repo(loader, parent_ops)?;
    let repo = pollster::block_on(loader.load_at(&op)).map_err(mutate::be)?;
    let changes_in = crate::op_diff::parse_changes_in(workspace, ctx, show_changes_in)?;
    let diff = if merged_parents {
        None
    } else {
        Some(crate::op_diff::op_diff(
            ctx,
            repo.as_ref(),
            (&parent_repo, &repo),
            &changes_in,
        )?)
    };
    Ok(OpShow {
        operation: operation(&op, head.op_store().root_operation_id()),
        diff,
    })
}

/// `op diff`'s clap rule: `--operation` conflicts with `--from` and `--to`.
///
/// # Errors
///
/// [`MutateError::InvalidInput`] naming the two flags, in the wording of the other clap refusals.
pub(crate) fn check_op_diff_flags(options: &OpDiffOptions) -> Result<(), MutateError> {
    if options.operation.is_none() {
        return Ok(());
    }
    let conflict = [("--from", options.from.is_some()), ("--to", options.to.is_some())]
        .into_iter()
        .find_map(|(flag, given)| given.then_some(flag));
    match conflict {
        Some(flag) => Err(MutateError::invalid(format!(
            "the argument '--operation' cannot be used with '{flag}'"
        ))),
        None => Ok(()),
    }
}

/// Compares two operations — the port of the CLI's `cmd_op_diff`
/// (`cli/src/commands/operation/diff.rs:95-186` @ v0.46.0, Story 9.21).
///
/// `from` / `to` given (either): those two, a missing one `@`; else `operation` (default `@`)
/// against its parents. The from-operations are merged as the CLI merges them, the from-repo's
/// index is merged into a throw-away transaction on the to-repo (never committed) so both
/// repos' commits evaluate, then `show_changes_in` is parsed and the diff computed.
///
/// # Errors
///
/// - [`MutateError::OperationNotFound`] / [`MutateError::InvalidInput`] — an operation
///   expression does not resolve to one operation (see [`opset`]).
/// - [`MutateError::Config`] / [`MutateError::RevsetParseError`] — the revset does not parse.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn op_diff(
    workspace: &Workspace,
    ctx: &mut VerbContext,
    options: &OpDiffOptions,
) -> Result<OpDiffResult, MutateError> {
    let loader = workspace.repo_loader();
    let head = pollster::block_on(loader.load_at_head()).map_err(mutate::be)?;
    let resolve = |text: Option<&String>| {
        pollster::block_on(op_walk::resolve_op_with_repo(&head, text.map_or("@", String::as_str))).map_err(opset)
    };
    let (from_ops, to_op) = if options.from.is_some() || options.to.is_some() {
        let from = resolve(options.from.as_ref())?;
        (vec![from], resolve(options.to.as_ref())?)
    } else {
        let to = resolve(options.operation.as_ref())?;
        (pollster::block_on(to.parents()).map_err(mutate::be)?, to)
    };
    let from_repo = merged_repo(loader, from_ops.clone())?;
    let to_repo = pollster::block_on(loader.load_at(&to_op)).map_err(mutate::be)?;
    // Never committed — the CLI's throw-away `to_repo.start_transaction()`, opened through the
    // sanctioned opener like every transaction of this crate.
    let mut tx = start_repo_transaction(&to_repo, workspace.workspace_name());
    tx.repo_mut().merge_index(&from_repo).map_err(mutate::be)?;
    let changes_in = crate::op_diff::parse_changes_in(workspace, ctx, options.show_changes_in.as_deref())?;
    let diff = crate::op_diff::op_diff(ctx, tx.repo(), (&from_repo, &to_repo), &changes_in)?;
    let root_id = head.op_store().root_operation_id();
    Ok(OpDiffResult {
        from: from_ops.iter().map(|op| operation(op, root_id)).collect(),
        to: operation(&to_op, root_id),
        diff,
    })
}

/// The repo at the merge of `ops` — the CLI's `merge_operations(None, …)`
/// (`cli/src/cli_util.rs:853-878` @ v0.46.0): the root repo for none, the op's own repo for one,
/// else an unpublished merge operation (written to the op store, as the CLI writes it).
fn merged_repo(loader: &RepoLoader, ops: Vec<JjOperation>) -> Result<Arc<ReadonlyRepo>, MutateError> {
    let (repo, _rebased) =
        pollster::block_on(loader.merge_operations(ops, None, None, Vec::new())).map_err(mutate::be)?;
    Ok(repo)
}

/// What `op abandon` did (Story 9.21) — the CLI's status lines as facts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpAbandonResult {
    /// The operations that became unreachable (the CLI's "Abandoned N operations"); 0 when
    /// `nothing_changed`.
    pub abandoned_count: u64,
    /// The descendant operations rewritten onto the new parent (the CLI's "reparented M
    /// descendant operations"); 0 when `nothing_changed`.
    pub reparented_count: u64,
    /// The range was already empty: no op head moved (the CLI's "Nothing changed.").
    pub nothing_changed: bool,
    /// The op heads afterwards, in the order of the heads before.
    pub head_op_ids: Vec<OperationId>,
}

/// `op abandon`'s hint when the current operation is the only head (`abandon.rs:98-100`).
const ABANDON_CURRENT_HINT: &str = "Run `jj undo` to revert the current operation, then use `jj op abandon`";

/// Abandons operation history — the port of the CLI's `cmd_op_abandon`
/// (`cli/src/commands/operation/abandon.rs:51-156` @ v0.46.0, Story 9.21). Loads no repo and
/// runs no snapshot, as the CLI's `load_workspace`.
///
/// `operation` is a range `a..b` (an empty `a` = the root operation, an empty `b` = the current
/// heads) or one operation (= its sole parent `..` it). The range's descendants are reparented
/// onto `a` ([`op_walk::reparent_range`]), each changed op head is replaced, and the working
/// copy's recorded operation is remapped — or, when it is not one of the heads, left as it is
/// with the warning [`WarningKind::OpAbandonWorkingCopyNotUpdated`]. No head moving is the CLI's
/// "Nothing changed.": `nothing_changed`, nothing replaced.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — a range ending at a current head ("Cannot abandon the
///   current operation <id>", with the CLI's hint when there is one head), the root operation
///   ("Cannot abandon the root operation"), a merge operation ("Cannot abandon a merge
///   operation"), or an operation expression that does not resolve to one operation.
/// - [`MutateError::OperationNotFound`] — no operation matches an id prefix.
/// - [`MutateError::Backend`] — an op-store, op-heads or working-copy failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn op_abandon(
    workspace: &mut Workspace,
    operation_str: &str,
    warnings: &mut Warnings,
) -> Result<OpAbandonResult, MutateError> {
    let loader = workspace.repo_loader().clone();
    let op_store = loader.op_store();
    let op_heads_store = loader.op_heads_store();
    let current =
        pollster::block_on(op_walk::get_current_head_ops(op_store, op_heads_store.as_ref())).map_err(opset)?;
    let resolve = |text: &str| pollster::block_on(op_walk::resolve_op_at(op_store, &current, text)).map_err(opset);
    let (root_op, head_ops) = if let Some((root_str, head_str)) = operation_str.split_once("..") {
        let root_op = if root_str.is_empty() {
            pollster::block_on(loader.root_operation())
        } else {
            resolve(root_str)?
        };
        let head_ops = if head_str.is_empty() {
            current.clone()
        } else {
            vec![resolve(head_str)?]
        };
        (root_op, head_ops)
    } else {
        let op = resolve(operation_str)?;
        let parents = pollster::block_on(op.parents()).map_err(mutate::be)?;
        match <[JjOperation; 1]>::try_from(parents) {
            Ok([parent]) => (parent, vec![op]),
            Err(parents) if parents.is_empty() => {
                return Err(MutateError::invalid("Cannot abandon the root operation"))
            }
            Err(_) => return Err(MutateError::invalid("Cannot abandon a merge operation")),
        }
    };
    if let Some(op) = head_ops.iter().find(|op| current.contains(op)) {
        let reason = format!("Cannot abandon the current operation {:.12}", op.id());
        return Err(if current.len() == 1 {
            MutateError::invalid_hinted(reason, ABANDON_CURRENT_HINT)
        } else {
            MutateError::invalid(reason)
        });
    }

    let stats = pollster::block_on(op_walk::reparent_range(
        op_store.as_ref(),
        &head_ops,
        &current,
        &root_op,
    ))
    .map_err(mutate::be)?;
    let head_op_ids: Vec<OperationId> = stats.new_head_ids.iter().map(|id| OperationId(id.hex())).collect();
    let changed: Vec<(&JjOperation, &op_store::OperationId)> = current
        .iter()
        .zip(&stats.new_head_ids)
        .filter(|(old, new_id)| old.id() != *new_id)
        .collect();
    if changed.is_empty() {
        return Ok(OpAbandonResult {
            abandoned_count: 0,
            reparented_count: 0,
            nothing_changed: true,
            head_op_ids,
        });
    }
    for (old, new_id) in &changed {
        pollster::block_on(op_heads_store.update_op_heads(slice::from_ref(old.id()), new_id)).map_err(mutate::be)?;
    }
    // Remap this workspace's working-copy operation; a divergent one stays (the CLI: "user will
    // need to re-abandon their ancestors").
    let mut locked = pollster::block_on(workspace.start_working_copy_mutation()).map_err(mutate::be)?;
    let old_op_id = locked.locked_wc().old_operation_id().clone();
    // Every head pair, changed or not, as the CLI's `reparented_head_ops()` search.
    if let Some((_, new_id)) = current
        .iter()
        .zip(&stats.new_head_ids)
        .find(|(old, _)| *old.id() == old_op_id)
    {
        pollster::block_on(locked.finish(new_id.clone())).map_err(mutate::be)?;
    } else {
        drop(locked);
        warnings.push(
            WarningKind::OpAbandonWorkingCopyNotUpdated,
            format!(
                "The working copy operation {old_op_id:.12} is not updated because it differs from the repo {}.",
                current
                    .iter()
                    .map(|op| format!("{:.12}", op.id()))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        );
    }
    Ok(OpAbandonResult {
        abandoned_count: stats.unreachable_count as u64,
        reparented_count: stats.rewritten_count as u64,
        nothing_changed: false,
        head_op_ids,
    })
}

/// Restores the repo to the state at an operation — the port of the CLI's `cmd_op_restore`
/// (`cli/src/commands/operation/restore.rs:48-70` @ v0.46.0, Story 9.12).
///
/// The step, as in the CLI:
///
/// 1. `operation_str` resolves at the head repo (`resolve_single_op`, as `op show`).
/// 2. The restored view is [`view_with_desired_portions_restored`] of the target operation's
///    view over the head's, `what` choosing the portions (empty = both, `DEFAULT_REVERT_WHAT`).
/// 3. It is committed as `restore to operation <hex>` — or, equal to the current view, no
///    operation at all and the pre-call head op id (the CLI's "Nothing changed.", Story 9.40).
///
/// A raw `set_view` records no rewrites, so the finish rebases nothing, as in the CLI.
///
/// # Errors
///
/// - [`MutateError::OperationNotFound`] / [`MutateError::InvalidInput`] — `operation_str` does
///   not resolve to one operation (see [`opset`]).
/// - [`MutateError::Config`] — the finish's immutable set does not resolve.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn op_restore(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    operation_str: &str,
    what: &[RestoreWhat],
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let target_op = pollster::block_on(op_walk::resolve_op_with_repo(&readonly, operation_str)).map_err(opset)?;
    let target_view = pollster::block_on(target_op.view()).map_err(mutate::be)?;
    let mut tx = start_repo_transaction(&readonly, workspace.workspace_name());
    tx.repo_mut().set_view(view_with_desired_portions_restored(
        target_view.store_view(),
        readonly.view().store_view(),
        what,
    ));
    let description = format!("restore to operation {}", target_op.id().hex());
    let finish = mutate::finish_verb(workspace, tx, &description, ctx)?;
    Ok(mutate::mutation_result(&finish, Vec::new(), Vec::new()))
}

/// Reverts one operation by applying its inverse — the port of the CLI's `cmd_op_revert`
/// (`cli/src/commands/operation/revert.rs:53-85` @ v0.46.0, Story 9.12).
///
/// The step, as in the CLI:
///
/// 1. `operation_str` (the CLI's default `@`) resolves at the head repo (`resolve_single_op`).
/// 2. Its parents are `at_most_one` (`:61-65`): none refuses "Cannot revert root operation",
///    several "Cannot revert a merge operation" — before any transaction.
/// 3. `merge(repo at the target, repo at its parent)` applies the inverse onto the head repo
///    (`:67-73`): the indexes merge, the views merge three-way, and the rewrites the merge
///    records are rebased by the finish.
/// 4. The restored portions of that merged view are taken over the head's
///    ([`view_with_desired_portions_restored`], `:74-79`; `what` empty = both), so `git_refs` /
///    `git_heads` (and an unselected portion) stay current.
/// 5. Committed as `revert operation <hex>` (`tx_description`, `:49-51`) — or, when nothing
///    changed, no operation and the pre-call head op id (Story 9.40).
///
/// # Errors
///
/// - [`MutateError::OperationNotFound`] / [`MutateError::InvalidInput`] — `operation_str` does
///   not resolve to one operation (see [`opset`]).
/// - [`MutateError::InvalidInput`] — the target is the root operation or a merge operation.
/// - [`MutateError::Config`] — the finish's immutable set does not resolve.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn op_revert(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    operation_str: &str,
    what: &[RestoreWhat],
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let target_op = pollster::block_on(op_walk::resolve_op_with_repo(&readonly, operation_str)).map_err(opset)?;
    let parents = pollster::block_on(target_op.parents()).map_err(mutate::be)?;
    let target_parent = match <[JjOperation; 1]>::try_from(parents) {
        Ok([parent]) => parent,
        Err(parents) if parents.is_empty() => return Err(MutateError::invalid("Cannot revert root operation")),
        Err(_) => return Err(MutateError::invalid("Cannot revert a merge operation")),
    };

    let mut tx = start_repo_transaction(&readonly, workspace.workspace_name());
    let loader = readonly.loader();
    let repo_at_target = pollster::block_on(loader.load_at(&target_op)).map_err(mutate::be)?;
    let repo_at_parent = pollster::block_on(loader.load_at(&target_parent)).map_err(mutate::be)?;
    pollster::block_on(tx.repo_mut().merge(&repo_at_target, &repo_at_parent)).map_err(mutate::be)?;
    let new_view =
        view_with_desired_portions_restored(tx.repo().view().store_view(), tx.base_repo().view().store_view(), what);
    tx.repo_mut().set_view(new_view);
    let description = format!("revert operation {}", target_op.id().hex());
    let finish = mutate::finish_verb(workspace, tx, &description, ctx)?;
    Ok(mutate::mutation_result(&finish, Vec::new(), Vec::new()))
}

/// What `op integrate` did (Story 9.12) — the CLI's effect as facts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpIntegrateResult {
    /// The head operation afterwards: the integrated operation, the merge operation that
    /// reconciled it with the other heads, or — for an operation already in the log — the
    /// unchanged head.
    pub head_op_id: OperationId,
    /// The integrate itself merged the op heads into a `reconcile divergent operations`
    /// operation — the CLI's status line "The specified operation has been integrated with other
    /// existing operations.", printed only from integrate's own resolver. A reconcile the head
    /// load wrote first (divergent heads before the call) does not count.
    pub reconciled: bool,
}

/// The description of the merge operation `op integrate` (and every head load) writes for
/// divergent op heads — the CLI's (`cli/src/commands/operation/integrate.rs:54` @ v0.46.0).
const RECONCILE_DESCRIPTION: &str = "reconcile divergent operations";

/// Makes an operation part of the operation log — the port of the CLI's `cmd_op_integrate`
/// (`cli/src/commands/operation/integrate.rs:36-66` @ v0.46.0, Story 9.12).
///
/// As the CLI's `workspace_helper_no_snapshot` (`cli/src/cli_util.rs:522-529`): no snapshot and
/// no Git import. The head is loaded the CLI's way ([`crate::snapshot::load_head`], which may
/// reconcile divergent heads), `operation_str` resolves at it, the op heads gain the target in
/// place of its parents (`update_op_heads`), and `resolve_op_heads` drops heads that are
/// ancestors of others — merging what remains, when more than one, into a
/// `reconcile divergent operations` operation in this workspace (`merge_operations`, without the
/// CLI's `args` attribute). An operation already in the log changes nothing.
///
/// # Errors
///
/// - [`MutateError::OperationNotFound`] / [`MutateError::InvalidInput`] — `operation_str` does
///   not resolve to one operation (see [`opset`]); nothing is written.
/// - [`MutateError::Precondition`] — the head could not be loaded.
/// - [`MutateError::Backend`] — an op-store or op-heads failure, or the merge failed.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn op_integrate(workspace: &Workspace, operation_str: &str) -> Result<OpIntegrateResult, MutateError> {
    let head = crate::snapshot::load_head(workspace)?;
    let target_op = pollster::block_on(op_walk::resolve_op_with_repo(&head, operation_str)).map_err(opset)?;
    let loader = workspace.repo_loader();
    let op_heads_store = loader.op_heads_store();
    pollster::block_on(op_heads_store.update_op_heads(target_op.parent_ids(), target_op.id())).map_err(mutate::be)?;
    let workspace_name = workspace.workspace_name();
    let mut reconciled = false;
    let head_op = pollster::block_on(op_heads_store::resolve_op_heads(
        op_heads_store.as_ref(),
        loader.op_store(),
        async |op_heads| -> Result<JjOperation, RepoLoaderError> {
            let (merged, _num_rebased) = loader
                .merge_operations(op_heads, Some(workspace_name), Some(RECONCILE_DESCRIPTION), [])
                .await?;
            reconciled = true;
            Ok(merged.operation().clone())
        },
    ))
    .map_err(mutate::be)?;
    Ok(OpIntegrateResult {
        head_op_id: OperationId(head_op.id().hex()),
        reconciled,
    })
}

/// An operation-expression failure as the CLI reports it (`command_error.rs:376-389`,
/// `:876-890` @ v0.46.0): no operation for an id prefix is [`MutateError::OperationNotFound`];
/// every other resolution failure is [`MutateError::InvalidInput`] with jj-lib's text — an
/// expression resolving to several operations with the CLI's hint naming them; an op-store or
/// op-heads failure is [`MutateError::Backend`].
fn opset(error: OpsetEvaluationError) -> MutateError {
    match error {
        OpsetEvaluationError::OpsetResolution(error) => match &error {
            OpsetResolutionError::NoSuchOperation(_) => MutateError::OperationNotFound {
                reason: error.to_string(),
            },
            OpsetResolutionError::MultipleOperations { candidates, .. } => MutateError::invalid_hinted(
                error.to_string(),
                format!(
                    "Try specifying one of the operations by ID: {}",
                    candidates
                        .iter()
                        .map(|id| format!("{id:.12}"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            ),
            OpsetResolutionError::EmptyOperations(_)
            | OpsetResolutionError::InvalidIdPrefix(_)
            | OpsetResolutionError::AmbiguousIdPrefix(_) => MutateError::invalid(error.to_string()),
        },
        other => mutate::be(other),
    }
}

#[cfg(test)]
mod tests {
    use jj_lib::op_store::{OpStoreError, OperationId as JjOperationId};
    use jj_lib::op_walk::{OpsetEvaluationError, OpsetResolutionError};

    use std::collections::{BTreeMap, HashSet};

    use jj_lib::backend::CommitId;
    use jj_lib::op_store::{RefTarget, RemoteRef, RemoteRefState, RemoteView, View};

    use super::{op_log, opset, view_with_desired_portions_restored, OpLogError, RestoreWhat};
    use crate::MutateError;

    /// A view whose every field names commit `n`, so each field's source is visible.
    fn view(n: u8) -> View {
        let id = CommitId::new(vec![n]);
        let target = RefTarget::normal(id.clone());
        let remote = RemoteView {
            bookmarks: BTreeMap::from([(
                "main".into(),
                RemoteRef {
                    target: target.clone(),
                    state: RemoteRefState::Tracked,
                },
            )]),
            tags: BTreeMap::new(),
        };
        View {
            head_ids: HashSet::from([id.clone()]),
            local_bookmarks: BTreeMap::from([("b".into(), target.clone())]),
            local_tags: BTreeMap::from([("t".into(), target.clone())]),
            remote_views: BTreeMap::from([("origin".into(), remote)]),
            git_refs: BTreeMap::from([("refs/heads/b".into(), target.clone())]),
            git_heads: BTreeMap::from([("default".into(), target)]),
            wc_commit_ids: BTreeMap::from([("default".into(), id)]),
        }
    }

    /// The CLI's `view_with_desired_portions_restored`: `Repo` takes heads, local bookmarks/tags
    /// and the working-copy commits from the restored view, `RemoteTracking` the remote views;
    /// `git_refs` / `git_heads` always stay current; an empty list is both (the flag absent).
    #[test]
    fn view_restore_takes_each_portion_per_what() {
        let (restored, current) = (view(1), view(2));
        let restore = |what: &[RestoreWhat]| view_with_desired_portions_restored(&restored, &current, what);
        let repo_from = |v: &View, from: &View| {
            v.head_ids == from.head_ids
                && v.local_bookmarks == from.local_bookmarks
                && v.local_tags == from.local_tags
                && v.wc_commit_ids == from.wc_commit_ids
        };
        for (what, repo, remote) in [
            (&[][..], true, true),
            (&[RestoreWhat::Repo, RestoreWhat::RemoteTracking][..], true, true),
            (&[RestoreWhat::Repo][..], true, false),
            (&[RestoreWhat::RemoteTracking][..], false, true),
            (
                &[RestoreWhat::RemoteTracking, RestoreWhat::RemoteTracking][..],
                false,
                true,
            ),
        ] {
            let v = restore(what);
            assert!(repo_from(&v, if repo { &restored } else { &current }), "{what:?}");
            let remote_source = if remote { &restored } else { &current };
            assert_eq!(v.remote_views, remote_source.remote_views, "{what:?}");
            assert_eq!(v.git_refs, current.git_refs, "{what:?}: git refs stay current");
            assert_eq!(v.git_heads, current.git_heads, "{what:?}: git heads stay current");
        }
    }

    /// The CLI's opset error mapping: no match is its own variant, the other resolution failures
    /// are invalid input with jj-lib's text (several matches with the hint naming them, 12 hex
    /// digits each), an op-store failure is a backend error.
    #[test]
    fn opset_errors_map_like_the_cli() {
        let resolution = |e: OpsetResolutionError| opset(OpsetEvaluationError::OpsetResolution(e));
        assert!(matches!(
            resolution(OpsetResolutionError::NoSuchOperation("ab".to_owned())),
            MutateError::OperationNotFound { reason } if reason == r#"No operation ID matching "ab""#
        ));
        assert!(matches!(
            resolution(OpsetResolutionError::AmbiguousIdPrefix("a".to_owned())),
            MutateError::InvalidInput { reason, hints } if reason == r#"Operation ID prefix "a" is ambiguous"# && hints.is_empty()
        ));
        let several = resolution(OpsetResolutionError::MultipleOperations {
            expr: "@".to_owned(),
            candidates: vec![JjOperationId::new(vec![0xab; 64]), JjOperationId::new(vec![0xcd; 64])],
        });
        assert_eq!(
            several.hints(),
            ["Try specifying one of the operations by ID: abababababab, cdcdcdcdcdcd"]
        );
        assert!(matches!(
            opset(OpsetEvaluationError::OpStore(OpStoreError::Other("broken".into()))),
            MutateError::Backend(reason) if reason == "broken"
        ));
    }

    /// A head that no longer loads is this module's own `Backend` failure. Through
    /// [`crate::Repo`] the pre-verb snapshot (Story 9.26) hits it first, so the module function
    /// is called directly.
    #[test]
    fn a_head_that_no_longer_loads_is_a_backend_error() {
        let (_tmp, repo) = crate::test_support::repo_with_a_broken_head();
        let result = op_log(repo.workspace(), None);
        assert!(matches!(result, Err(OpLogError::Backend(_))), "{result:?}");
    }
}
