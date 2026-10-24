// SPDX-License-Identifier: MIT

//! `workspace.rs` — the two workspace READ verbs of ADR-0003: `jj workspace list` and
//! `jj workspace root` (Story 9.7, Epic 9 Tier A).
//!
//! Both are READS: they resolve to the head operation per call (ADR-0002) and open no
//! transaction. Only a head load that reconciles divergent operation heads (as the CLI's does)
//! — or `list`'s pre-verb snapshot — may write an operation.
//!
//! CLI parity is at tag **v0.46.0** (`cli/src/commands/workspace/{list,root}.rs` plus
//! `cli/src/commit_templater.rs`'s `WorkspaceRef` `root` method) for the observable behavior —
//! argument arity, defaults, refusals and warnings — never for its terminal UX (NFR-R-2,
//! ADR-0003). Deliberate divergences:
//!
//! - **No terminal UX**: no templates, `-T`, `templates.workspace_list`, `root.relative()`
//!   rendering or CWD-relative shortening. The GUI formats; the backend returns ABSOLUTE paths.
//! - **No mutation**: `workspace add` and `update-stale` live in [`crate::workspace_add`] and
//!   [`crate::stale`] (Story 9.23), `forget`/`rename`/`remove` in [`crate::workspace_ops`] (Story
//!   9.13), so `WorkspaceStore::{add,forget,rename}` is never called from here.
//!
//! Since jj 0.46 (`d7e6ca981`, "don't overly canonicalize, print unreachable paths") both verbs
//! report the RECORDED path as the store returns it — never canonicalized, never dropped for not
//! existing. [`resolve_root`] with a name still REFUSES when nothing is recorded, with one error
//! per CLI `user_error` (`commands/workspace/root.rs:42-66` @ v0.46.0), and WARNS
//! (`jj.workspace_path_inaccessible`) when the recorded directory does not exist. A list row
//! reports no root only when nothing is recorded, or — widened here so a broken store cannot
//! fail the whole listing — when the store does not load or read (the CLI's template renders an
//! error in that row instead).
//!
//! Two facts the implementation relies on. The store is loaded afresh per call through jj-lib's
//! own factory, as every CLI command loads it at start-up — and that load is **not** a pure read:
//! a missing `workspace_store/` directory, `type` file or index is CREATED, the index empty
//! (`jj-lib repo.rs:543-564` / `simple_workspace_store.rs:91-100` @ 0.46.0, for repos predating
//! jj 0.38.0) — jj-lib's own behavior, the CLI triggers it too, and it writes NO operation. And
//! the store resolves the `.jj/repo`-relative stored path itself (`simple_workspace_store.rs:
//! 224-239`): what it returns is absolute and LEXICALLY normalized — `..` collapsed, symlinks
//! kept — and is reported as is.

use std::path::PathBuf;

use jj_lib::default_backend_factories::default_backend_factories;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::workspace::Workspace;
use jj_lib::workspace_store::WorkspaceStore;

use crate::warning::{WarningKind, Warnings};
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
    /// Absolute path the store records for the workspace's root directory — reported even when
    /// that directory no longer exists (moved or deleted), as the CLI does since jj 0.46. `None`
    /// when nothing can be reported: the workspace predates jj 0.38.0 and has no recorded path,
    /// or the store does not load or read. Null-for-absence — never a sentinel — and NEVER a
    /// reason to fail the listing.
    pub root: Option<PathBuf>,
}

/// Errors returned by [`crate::Repo::list_workspaces`] and
/// [`crate::Repo::resolve_workspace_root`].
///
/// The two refusal variants are one per CLI `user_error` in `cli/src/commands/workspace/root.rs`
/// @ v0.46.0, kept apart because the REMEDIES differ — the same test
/// [`crate::MutateError::RemoteExists`] passed. Only [`resolve_root`] can produce them;
/// [`list_workspaces`] collapses every path-side failure to `root: None`.
#[derive(Debug, thiserror::Error)]
pub enum WorkspaceError {
    /// The pre-verb snapshot of `list` (Story 9.26) or the command start-up of `root` (the
    /// secure-config fix-up, the effective config; with a name also the colocation check, the
    /// alias tables, the `immutable_heads()` parse and the `trunk()` fallback's head load) failed,
    /// so the read never ran — see [`crate::PreconditionError`]: a config fault is its `Config`,
    /// a jj-lib failure of those steps its `Backend`.
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
    /// not recorded anywhere. (A path that IS recorded but no longer exists is no error: it is
    /// returned with a `jj.workspace_path_inaccessible` warning.)
    #[error("workspace has no recorded path: {name}")]
    NoRecordedPath {
        /// The workspace name whose store entry is absent.
        name: String,
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

/// One workspace's RECORDED path, as the store returns it (absolute, lexically normalized) — the
/// stage both verbs share. Existence is not checked here: [`resolve_root`] warns about a missing
/// directory, a list row just reports it.
fn recorded_root(store: &dyn WorkspaceStore, name: &str) -> Result<PathBuf, WorkspaceError> {
    // Names are UTF-8 by construction (`WorkspaceNameBuf` wraps a `String`), so the ref-cast is
    // total — only PATHS need lossy handling.
    store
        .get_workspace_path(WorkspaceName::new(name))
        .map_err(be)?
        .ok_or_else(|| WorkspaceError::NoRecordedPath { name: name.to_owned() })
}

/// Loads the workspace store afresh, the way every CLI command's start-up does
/// (`StoreFactories::load_workspace_store`, jj-lib `repo.rs:543-564` @ 0.46.0) — NOT the store
/// this handle's loader captured when it was opened: a store directory deleted under an open
/// handle is recreated EMPTY here, exactly as the next CLI command recreates it, instead of
/// failing every read of the captured one.
pub(crate) fn load_store(workspace: &Workspace) -> Result<Box<dyn WorkspaceStore>, WorkspaceError> {
    default_backend_factories()
        .load_workspace_store(
            workspace.repo_loader().settings(),
            &workspace.repo_path().join("workspace_store"),
        )
        .map_err(be)
}

/// Lists every workspace of this repo with its working-copy commit and root directory.
///
/// The view half is [`crate::view::list_working_copies`], reused rather than copied, so the
/// name/commit columns are byte-identical to what [`crate::Repo::list_working_copies`] reports;
/// the path half is one `WorkspaceStore` lookup per row. Rows keep jj-lib's own `BTreeMap` order
/// (lexicographic by workspace name).
///
/// A row's `root` is the recorded path even when the directory is gone — the `WorkspaceRef` `root`
/// method returns `get_workspace_path` unchecked since jj 0.46 (`cli/src/commit_templater.rs:
/// 1896-1906` @ v0.46.0). Every other path-side failure — store load, store read, an absent entry
/// — collapses to `root: None`, so a broken store can never fail the listing; the CLI's comment
/// there points at `jj workspace root --name` ([`resolve_root`]) for strict diagnostics.
///
/// # Errors
///
/// - [`WorkspaceError::Backend`] — the head load failed, i.e. the VIEW half could not be read;
///   the jj-lib reason is forwarded as a string. No path failure reaches this.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_workspaces(workspace: &Workspace) -> Result<Vec<WorkspaceEntry>, WorkspaceError> {
    let rows = crate::view::list_working_copies(workspace).map_err(from_view)?;
    // Loaded ONCE, looked up per row: `get_workspace_path` re-decodes the whole protobuf index
    // per call either way, and a failed load must not fail the listing.
    let store = load_store(workspace).ok();
    Ok(rows
        .into_iter()
        .map(|row| WorkspaceEntry {
            root: store
                .as_ref()
                .and_then(|s| recorded_root(s.as_ref(), &row.workspace_name).ok()),
            name: row.workspace_name,
            wc_commit_id: row.commit_id,
        })
        .collect())
}

/// Returns the root directory of `name`'s workspace — the named form of `jj workspace root`; the
/// bare form is [`crate::Repo::resolve_workspace_root`]'s own (the loader's root, no store read).
///
/// The CLI's stages run in ITS order: load the store, check view membership, read the recorded
/// path. The path is returned as recorded — not canonicalized — and a directory that does not
/// exist is no refusal but a `jj.workspace_path_inaccessible` warning pushed into `sink`, the
/// CLI's "Cannot access workspace path: …" (`root.rs:60-66`). The named path never shortcuts to
/// the loader, so the current workspace's own name CAN refuse or warn where the bare form does
/// not — the CLI behaves the same way.
///
/// An explicitly present EMPTY name is a VALUE, not an absence: no workspace is named `""`, so it
/// is a [`WorkspaceError::NotFound`].
///
/// # Errors
///
/// - [`WorkspaceError::NotFound`] — no workspace of that name is in the head view.
/// - [`WorkspaceError::NoRecordedPath`] — the workspace exists but the store holds no path.
/// - [`WorkspaceError::Backend`] — the store could not be loaded or read, or the head load
///   failed.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn resolve_root(workspace: &Workspace, name: &str, sink: &mut Warnings) -> Result<PathBuf, WorkspaceError> {
    let store = load_store(workspace)?;
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    if !readonly.view().wc_commit_ids().contains_key(WorkspaceName::new(name)) {
        return Err(WorkspaceError::NotFound { name: name.to_owned() });
    }
    let path = recorded_root(store.as_ref(), name)?;
    if !path.exists() {
        sink.push(
            WarningKind::WorkspacePathInaccessible,
            format!("Cannot access workspace path: {}", path.display()),
        );
    }
    Ok(path)
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
