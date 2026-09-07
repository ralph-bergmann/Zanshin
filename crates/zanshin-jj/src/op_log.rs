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
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;

use crate::mutate::{self, MutateError, MutationResult};
use crate::op_support::start_repo_transaction;
use crate::{ChangeId, Timestamp};

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

/// Reverts the last operation, one step back from the CURRENT head (FR-JJ-14a).
///
/// Restores the head operation's single parent's view — repo state (`head_ids`, local
/// bookmarks/tags) plus remote-tracking bookmarks, matching the CLI's default (unflagged)
/// `jj undo` portions — onto a freshly-committed op, leaving `git_refs`/`git_head` at
/// their CURRENT (pre-undo) values. Mirrors the CLI's `cmd_undo` (`../jj` `v0.42.0`
/// `cli/src/commands/undo.rs`) minus its `UNDO_OP_DESC_PREFIX` "jump over old
/// undo-stacks" optimization: this is a single-step walk-back from the current head, not
/// a description-parsed redo/undo stack. Calling `undo()` twice in a row still redoes the
/// first `undo()`: each call's target is the current head's parent, and the first undo
/// op's parent IS the pre-undo (post-mutation) state.
///
/// No `rebase_descendants()` call — a raw `set_view` records no rewrites, matching the
/// CLI (which doesn't call it either).
///
/// # Errors
///
/// - [`MutateError::NothingToUndo`] — the head operation IS the op-store root operation
///   (no parent to restore to).
/// - [`MutateError::InvalidInput`] — the head operation has more than one parent (a
///   divergent-write "reconcile divergent operations" merge op) — mirrors the CLI's own
///   refusal to undo a merge operation, rather than silently picking one parent.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn undo(workspace: &mut Workspace) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let head_op = readonly.operation().clone();
    let parent_ids = head_op.parent_ids();
    if parent_ids.is_empty() {
        return Err(MutateError::NothingToUndo);
    }
    let [target_parent_id] = parent_ids else {
        return Err(MutateError::InvalidInput {
            reason: "cannot undo a merge operation".to_owned(),
        });
    };
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = mutate::capture_old_wc(&readonly, &workspace_name)?;

    let target_parent =
        pollster::block_on(workspace.repo_loader().load_operation(target_parent_id)).map_err(mutate::be)?;
    let target_view = pollster::block_on(target_parent.view()).map_err(mutate::be)?;

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    tx.repo_mut()
        .set_view(restored_view(target_view.store_view(), readonly.view().store_view()));
    let new_repo = pollster::block_on(tx.commit(format!("undo: restore to operation {}", target_parent.id().hex())))
        .map_err(mutate::be)?;
    let new_op_id = OperationId(new_repo.op_id().hex());

    let new_wc_commit = mutate::sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    Ok(MutationResult {
        new_op_id,
        new_change_ids: Vec::new(),
        abandoned_change_ids: Vec::new(),
        working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
    })
}

/// Restores only the portions of the view the CLI's default (unflagged) `jj undo`
/// restores — `DEFAULT_REVERT_WHAT` = Repo + `RemoteTracking`, both always on for plain
/// `undo` (no flag exists on `undo` itself to change this). Reimplements
/// `cli/src/commands/operation/mod.rs`'s `view_with_desired_portions_restored` inline
/// (small, pure, single-use — CLI-only orchestration jj-lib doesn't expose): `head_ids`,
/// local bookmarks/tags, remote-tracking views, and `wc_commit_ids` come from `target`;
/// `git_refs`/`git_head` stay at `current`.
fn restored_view(target: &op_store::View, current: &op_store::View) -> op_store::View {
    op_store::View {
        head_ids: target.head_ids.clone(),
        local_bookmarks: target.local_bookmarks.clone(),
        local_tags: target.local_tags.clone(),
        remote_views: target.remote_views.clone(),
        git_refs: current.git_refs.clone(),
        git_head: current.git_head.clone(),
        wc_commit_ids: target.wc_commit_ids.clone(),
    }
}
