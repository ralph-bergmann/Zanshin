// SPDX-License-Identifier: MIT

//! `op_log.rs` — jj operation-log read (FR-JJ-7).
//!
//! Exposes a `jj_lib`-type-free view of jj's operation log: a reverse-
//! chronological list of operations (head first, root last). The read
//! re-resolves to the head operation per call (ADR-0002) and never shells to
//! the `jj` CLI (AR-AP-1).

use futures::StreamExt as _;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_walk;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;

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
