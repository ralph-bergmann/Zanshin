// SPDX-License-Identifier: MIT

//! `workspace.rs` — the two workspace READ verbs of ADR-0003: `jj workspace list` and
//! `jj workspace root` (Story 9.7, Epic 9 Tier A).
//!
//! Both are READS: they resolve to the head operation per call (ADR-0002) and open no
//! transaction, so neither writes an operation — not even on a refusal.
//!
//! CLI parity is at tag **v0.44.0** (`cli/src/commands/workspace/{list,root}.rs` plus
//! `cli/src/commit_templater.rs::WorkspaceRef::root`) for the observable behavior — argument
//! arity, defaults and refusals — never for its terminal UX (NFR-R-2, ADR-0003). Deliberate
//! divergences:
//!
//! - **No terminal UX**: no templates, `-T`, `templates.workspace_list`, `root.relative()`
//!   rendering or CWD-relative shortening. The GUI formats; the backend returns ABSOLUTE paths.
//! - **`std::fs::canonicalize`, not `dunce::canonicalize`**: the two differ only on Windows (UNC
//!   avoidance) and Zanshin is macOS-only, so `std` is the faithful equivalent and adds no
//!   dependency. The consequence to respect is the `/var` → `/private/var` symlink: compare
//!   canonicalized paths on BOTH sides.
//! - **No mutation**: `workspace add`/`forget`/`rename`/`update-stale` are Stories 9.13/9.23, so
//!   `WorkspaceStore::{add,forget,rename}` is never called from here.
//!
//! The two verbs are deliberately ASYMMETRIC on an unusable recorded path, exactly as the CLI is:
//! [`list_workspaces`] DEGRADES (the row keeps its name and commit and reports no root —
//! `commit_templater.rs:1787`'s `dunce::canonicalize(..).ok()`, widened here so that a store-load
//! or store-read failure also collapses rather than failing the whole listing), while
//! [`resolve_root`] with a name REFUSES, with one error per CLI `user_error`
//! (`commands/workspace/root.rs:50-72`). Do not unify them: the CLI's own comment
//! (`commit_templater.rs:1781-1783`) says list templates must keep rendering and points at
//! `jj workspace root --name` for strict path diagnostics.
//!
//! Two traps the implementation respects. `SimpleWorkspaceStore::load` is **not** a pure read:
//! on a repo with no `workspace_store/` directory it CREATES one and writes an empty store
//! (`jj-lib workspace_store.rs:117-125`, for repos predating jj 0.38.0). That is jj-lib's own
//! behavior, the CLI triggers it too, and it writes NO operation. And the stored path is relative
//! to `.jj/repo` (`workspace_store.rs:176-181`), not to the workspace root, so the join base is
//! [`Workspace::repo_path`] and the joined path keeps `../..` segments only `canonicalize`
//! resolves.

use std::path::{Path, PathBuf};

use jj_lib::ref_name::WorkspaceName;
use jj_lib::workspace::Workspace;
use jj_lib::workspace_store::{SimpleWorkspaceStore, WorkspaceStore as _};

use crate::CommitId;

/// One row of `jj workspace list`: a workspace, its working-copy commit and where it lives.
///
/// The view half (`name`, `wc_commit_id`) is [`crate::WorkingCopy`]'s, reused rather than
/// re-derived; `root` is the half that lives in the `WorkspaceStore` instead of the `View`. The
/// two shapes stay distinct on purpose: [`crate::WorkingCopy`] is the raw `View` row and
/// [`WorkspaceEntry`] is the `jj workspace list` row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceEntry {
    /// The jj workspace name (`"default"` for a single-workspace repo).
    pub name: String,
    /// Hex commit id of that workspace's working-copy commit.
    pub wc_commit_id: CommitId,
    /// Absolute path of the workspace's root directory, or `None` when it cannot be reported:
    /// the workspace predates jj 0.38.0 and has no recorded path, the store is unreadable, or
    /// the recorded path no longer resolves (the directory moved or was deleted). Null-for-absence
    /// — never a sentinel — and NEVER a reason to fail the listing.
    pub root: Option<PathBuf>,
}

/// Errors returned by [`crate::Repo::list_workspaces`] and
/// [`crate::Repo::resolve_workspace_root`].
///
/// The three non-`Backend` variants are one per CLI `user_error` in
/// `cli/src/commands/workspace/root.rs` @ v0.44.0, kept apart because the REMEDIES differ — the
/// same test [`crate::MutateError::RemoteExists`] passed. Only [`resolve_root`] can produce them;
/// [`list_workspaces`] collapses every path-side failure to `root: None`.
#[derive(Debug, thiserror::Error)]
pub enum WorkspaceError {
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
    /// No workspace of that name is in the head view's `wc_commit_ids()`. The remedy is to pick a
    /// different workspace — `jj workspace list` names them all.
    #[error("no such workspace: {name}")]
    NotFound {
        /// The workspace name that was asked for.
        name: String,
    },
    /// The workspace exists but the store holds no path for it — it was created before jj 0.38.0,
    /// or its store entry was wiped. Nothing can be done about it from here; the path is simply
    /// not recorded anywhere.
    #[error("workspace has no recorded path: {name}")]
    NoRecordedPath {
        /// The workspace name whose store entry is absent.
        name: String,
    },
    /// A path IS recorded but does not resolve: the directory moved, was deleted, or is
    /// unreachable. Distinct from [`WorkspaceError::NoRecordedPath`] because the remedy is
    /// distinct — the workspace can be forgotten (Story 9.13) or its directory restored.
    #[error("cannot resolve absolute workspace path for {name}: {reason}")]
    PathUnresolved {
        /// The workspace name whose recorded path does not resolve.
        name: String,
        /// The I/O reason `canonicalize` gave.
        reason: String,
    },
    /// An underlying jj-lib failure (loader, view, or workspace-store read), opaque-string-wrapped
    /// so no `jj_lib` type escapes the public API (FR-JJ-16). `WorkspaceStoreError` is a
    /// non-matchable `Other(Box<dyn Error>)`, so its message is all there is to forward.
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`WorkspaceError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> WorkspaceError {
    WorkspaceError::Backend(e.to_string())
}

/// Converts the view half's error into this module's taxonomy, variant for variant.
fn from_view(e: crate::ViewError) -> WorkspaceError {
    match e {
        crate::ViewError::Backend(reason) => WorkspaceError::Backend(reason),
        crate::ViewError::Precondition(inner) => WorkspaceError::Precondition(inner),
    }
}

/// Resolves one workspace's RECORDED path to an absolute directory — the stage both verbs share.
///
/// The stored path is relative to `.jj/repo`, so `repo_path` is the join base; the join keeps
/// `../..` segments that only `canonicalize` resolves. The three failure stages are kept apart
/// here so [`resolve_root`] can report them apart; [`list_workspaces`] discards the distinction
/// with `.ok()`, which is precisely the CLI's own asymmetry.
fn resolve_recorded_root(
    store: &SimpleWorkspaceStore,
    repo_path: &Path,
    name: &str,
) -> Result<PathBuf, WorkspaceError> {
    // Names are UTF-8 by construction (`WorkspaceNameBuf` wraps a `String`), so the ref-cast is
    // total — only PATHS need lossy handling.
    let recorded = store
        .get_workspace_path(WorkspaceName::new(name))
        .map_err(be)?
        .ok_or_else(|| WorkspaceError::NoRecordedPath { name: name.to_owned() })?;
    let joined = repo_path.join(recorded);
    std::fs::canonicalize(&joined).map_err(|e| WorkspaceError::PathUnresolved {
        name: name.to_owned(),
        reason: e.to_string(),
    })
}

/// Lists every workspace of this repo with its working-copy commit and root directory.
///
/// The view half is [`crate::view::list_working_copies`], reused rather than copied, so the
/// name/commit columns are byte-identical to what [`crate::Repo::list_working_copies`] reports;
/// the path half is one `WorkspaceStore` lookup per row. Rows keep jj-lib's own `BTreeMap` order
/// (lexicographic by workspace name).
///
/// Every path-side failure — store load, store read, an absent entry, a `canonicalize` that fails
/// — collapses to `root: None`, so a broken path can never fail the listing. That is
/// `WorkspaceRef::root`'s contract (`cli/src/commit_templater.rs:1771-1789` @ v0.44.0): list
/// templates must keep rendering, and [`resolve_root`] is where strict path diagnostics live.
///
/// # Errors
///
/// - [`WorkspaceError::Backend`] — `load_at_head` failed, i.e. the VIEW half could not be read;
///   the jj-lib reason is forwarded as a string. No path failure reaches this.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_workspaces(workspace: &Workspace) -> Result<Vec<WorkspaceEntry>, WorkspaceError> {
    let rows = crate::view::list_working_copies(workspace).map_err(from_view)?;
    let repo_path = workspace.repo_path();
    // Loaded ONCE, looked up per row: `get_workspace_path` re-decodes the whole protobuf index
    // per call either way, and a failed load must not fail the listing.
    let store = SimpleWorkspaceStore::load(repo_path).ok();
    Ok(rows
        .into_iter()
        .map(|row| WorkspaceEntry {
            root: store
                .as_ref()
                .and_then(|s| resolve_recorded_root(s, repo_path, &row.workspace_name).ok()),
            name: row.workspace_name,
            wc_commit_id: row.commit_id,
        })
        .collect())
}

/// Returns the root directory of `name`'s workspace, or of the OPEN one when `name` is `None`.
///
/// With `name` absent this reads the loader only — no repo load, no store read — exactly as
/// `cli/src/commands/workspace/root.rs:78` @ v0.44.0 does, and it is the one path that cannot
/// fail. With a name present the CLI's four stages run in ITS order, each with its own refusal:
/// load the store, check view membership, read the recorded path, then join and canonicalize.
/// The named path never shortcuts to the loader, so `resolve_root(Some(<the current workspace's
/// own name>))` CAN refuse where `resolve_root(None)` succeeds — the CLI behaves the same way.
///
/// An explicitly present EMPTY name is a VALUE, not an absence: no workspace is named `""`, so it
/// is a [`WorkspaceError::NotFound`].
///
/// # Errors
///
/// - [`WorkspaceError::NotFound`] — no workspace of that name is in the head view.
/// - [`WorkspaceError::NoRecordedPath`] — the workspace exists but the store holds no path.
/// - [`WorkspaceError::PathUnresolved`] — a path is recorded but does not resolve; the I/O reason
///   rides in `reason`.
/// - [`WorkspaceError::Backend`] — the store could not be loaded or read, or `load_at_head`
///   failed.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn resolve_root(workspace: &Workspace, name: Option<&str>) -> Result<PathBuf, WorkspaceError> {
    let Some(name) = name else {
        return Ok(workspace.workspace_root().to_owned());
    };
    let repo_path = workspace.repo_path();
    let store = SimpleWorkspaceStore::load(repo_path).map_err(be)?;
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    if !readonly.view().wc_commit_ids().contains_key(WorkspaceName::new(name)) {
        return Err(WorkspaceError::NotFound { name: name.to_owned() });
    }
    resolve_recorded_root(&store, repo_path, name)
}

#[cfg(test)]
mod tests {
    use super::{from_view, list_workspaces, WorkspaceError};

    /// A head that no longer loads is this module's own `Backend` failure. Through
    /// [`crate::Repo`] the pre-verb snapshot (Story 9.26) hits it first, so the module function
    /// is called directly.
    #[test]
    fn a_head_that_no_longer_loads_is_a_backend_error() {
        let (_tmp, repo) = crate::test_support::repo_with_a_broken_head();
        let result = list_workspaces(repo.workspace());
        assert!(matches!(result, Err(WorkspaceError::Backend(_))), "{result:?}");
    }

    /// The view half's two variants map one-to-one; the precondition one is only produced by
    /// [`crate::Repo`]'s own pre-verb snapshot, never by the view read this module calls.
    #[test]
    fn view_errors_keep_their_variant() {
        assert!(matches!(
            from_view(crate::ViewError::Precondition(crate::PreconditionError::Backend("p".to_owned()))),
            WorkspaceError::Precondition(crate::PreconditionError::Backend(reason)) if reason == "p"
        ));
    }
}
