// SPDX-License-Identifier: MIT

//! `op_log.rs` — jj operation-log read (FR-JJ-7).
//!
//! Exposes a `jj_lib`-type-free view of jj's operation log: a reverse-
//! chronological list of operations (head first, root last). The read
//! re-resolves to the head operation per call (ADR-0002) and never shells to
//! the `jj` CLI (AR-AP-1).

use futures::StreamExt as _;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store;
use jj_lib::op_walk;
use jj_lib::operation::Operation as JjOperation;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;

use crate::mutate::{self, MutateError, MutationResult};
use crate::op_support::start_repo_transaction;
use crate::snapshot::VerbContext;
use crate::warning::WarningKind;
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
            let md = op.metadata();
            let end = md.time.end;
            out.push(Operation {
                id: OperationId(op.id().hex()),
                parent_ids: op.parent_ids().iter().map(|p| OperationId(p.hex())).collect(),
                timestamp: Timestamp {
                    millis_since_epoch: end.timestamp.0,
                    tz_offset_minutes: end.tz_offset,
                },
                user: md.username.clone(),
                host: md.hostname.clone(),
                description: md.description.clone(),
                root_op: op.id() == &root_id,
                is_snapshot: md.is_snapshot,
            });
        }
        Ok::<(), OpLogError>(())
    })?;
    Ok(out)
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

    let target_op = through_undo(
        workspace,
        readonly.operation().clone(),
        "Failed to parse ID of target operation in undo-stack",
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
    let target_parent = through_undo(
        workspace,
        target_parent,
        "Failed to parse ID of target operation's parent in undo-stack",
    )?;
    let target_view = pollster::block_on(target_parent.view()).map_err(mutate::be)?;

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    tx.repo_mut()
        .set_view(restored_view(target_view.store_view(), readonly.view().store_view()));
    let description = format!("{UNDO_OP_DESC_PREFIX}{}", target_parent.id().hex());
    let finish = mutate::finish_verb(workspace, tx, &description, ctx)?;
    mutate::mutation_result(&finish, Vec::new(), Vec::new())
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

/// `op` itself — or, when `op` is an undo operation, the operation it restored to (the CLI's two
/// `strip_prefix(UNDO_OP_DESC_PREFIX)` look-ups). A description whose id does not parse is the
/// CLI's internal error `parse_failure`.
fn through_undo(workspace: &Workspace, op: JjOperation, parse_failure: &str) -> Result<JjOperation, MutateError> {
    let Some(hex) = op.metadata().description.strip_prefix(UNDO_OP_DESC_PREFIX) else {
        return Ok(op);
    };
    let id = op_store::OperationId::try_from_hex(hex).ok_or_else(|| MutateError::Backend(parse_failure.to_owned()))?;
    pollster::block_on(workspace.repo_loader().load_operation(&id)).map_err(mutate::be)
}

/// Restores only the portions of the view the CLI's default (unflagged) `jj undo`
/// restores — `DEFAULT_REVERT_WHAT` = Repo + `RemoteTracking`, both always on for plain
/// `undo` (no flag exists on `undo` itself to change this). Reimplements
/// `cli/src/commands/operation/mod.rs`'s `view_with_desired_portions_restored` inline
/// (small, pure, single-use — CLI-only orchestration jj-lib doesn't expose): `head_ids`,
/// local bookmarks/tags, remote-tracking views, and `wc_commit_ids` come from `target`;
/// `git_refs`/`git_heads` stay at `current`.
fn restored_view(target: &op_store::View, current: &op_store::View) -> op_store::View {
    op_store::View {
        head_ids: target.head_ids.clone(),
        local_bookmarks: target.local_bookmarks.clone(),
        local_tags: target.local_tags.clone(),
        remote_views: target.remote_views.clone(),
        git_refs: current.git_refs.clone(),
        git_heads: current.git_heads.clone(),
        wc_commit_ids: target.wc_commit_ids.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::{op_log, OpLogError};

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
