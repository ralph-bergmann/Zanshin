// SPDX-License-Identifier: MIT

//! `view.rs` — the direct `View` reads of ADR-0003 §5: tags, heads, and per-workspace
//! working-copy commits.
//!
//! Everything here is read straight off the head-resolved `View` — no revset is evaluated —
//! and returned `jj_lib`-type-free. Re-resolves to the head operation per call (ADR-0002) and
//! never shells to the `jj` CLI (AR-AP-1). `bookmarks.rs` is the sibling listing; the two
//! deliberately share one idiom.

use std::collections::HashSet;

use jj_lib::config::StackedConfig;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::RefTarget;
use jj_lib::repo::Repo as _;
use jj_lib::str_util::StringMatcher;
use jj_lib::workspace::Workspace;

use crate::bookmarks::{collect_items, Include, Item, Predicates, Primary};
use crate::{ChangeId, CommitId, ConfigError};

/// Whether a tag row is the local tag or a remote one, with the remote-only facts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TagKind {
    /// A tag local to this repository.
    Local,
    /// A remote tag, tracked or not. `remote_name` is always present for a `Remote` entry (never
    /// `None`); it may be the empty string only in the theoretical empty-remote edge case (jj does
    /// not forbid an empty remote name).
    Remote {
        /// The remote this tag lives on (e.g. `"origin"`).
        remote_name: String,
        /// Whether the local tag tracks this remote tag (jj-lib `RemoteRef::is_tracked`).
        tracked: bool,
    },
}

/// One row of `jj tag list --all-remotes` (Story 9.59), the `@git` rows left out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tag {
    /// Tag name, preserved as UTF-8 (jj-lib `RefName`).
    pub name: String,
    /// Target change id in jj reverse-hex form; for a conflicted target the first added commit's
    /// change id — the same rule [`crate::Bookmark::target`] uses. `None` when the row's target is
    /// absent: a local tag deleted while still tracking a remote, or a tracked remote tag not
    /// pushed yet.
    pub target: Option<ChangeId>,
    /// The target is an unresolved conflict (`!RefTarget::is_resolved`).
    pub conflicted: bool,
    /// Local row: every tracked remote tag of this name points where the local one does (true when
    /// none is tracked). Remote row: tracked and pointing where the local one does.
    pub synced: bool,
    /// Whether this row is the local tag or a remote one.
    pub kind: TagKind,
}

/// One workspace's working-copy commit — the view half of `jj workspace list`.
///
/// Carries a [`CommitId`], not a [`ChangeId`]: that is literally what `View::wc_commit_ids()`
/// holds. The change-id form for the *current* workspace is
/// [`crate::Status::working_copy_change_id`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkingCopy {
    /// The jj workspace name (`"default"` for a single-workspace repo).
    pub workspace_name: String,
    /// Hex commit id of that workspace's working-copy commit.
    pub commit_id: CommitId,
}

/// Errors returned by [`crate::Repo::list_tags`], [`crate::Repo::list_heads`] and
/// [`crate::Repo::list_working_copies`].
#[derive(Debug, thiserror::Error)]
pub enum ViewError {
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
    /// The effective config could not be read: `ui.tag-list-sort-keys` is not an array of the CLI's
    /// key names ([`crate::Repo::list_tags`], Story 9.59).
    #[error(transparent)]
    Config(#[from] ConfigError),
    /// An underlying jj-lib failure (loader / view / store read), opaque-string-wrapped so no
    /// `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`ViewError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> ViewError {
    ViewError::Backend(e.to_string())
}

/// Lists the rows `jj tag list --all-remotes` prints (Story 9.59) — `cmd_tag_list`
/// (`tag/list.rs:139-213` @ v0.47.0) with that one argument and without its template — minus the
/// rows of the default-ignored remote (`git` on a Git-backed repo).
///
/// The rows come from the bookmark list's `collect_items` over every tag name: each local row, then
/// its tracked remote rows, then the name's untracked remote rows, in name order; then sorted by
/// `ui.tag-list-sort-keys` (read from `config`, default `["name"]`). The `git` rows are dropped
/// AFTER collecting, so a local row's `synced` still sees the `git` ref as the CLI does.
///
/// # Errors
///
/// - [`ViewError::Config`] — `ui.tag-list-sort-keys` is malformed.
/// - [`ViewError::Backend`] — the head load or a store read failed; the jj-lib reason is
///   forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_tags(workspace: &Workspace, config: &StackedConfig) -> Result<Vec<Tag>, ViewError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let predicates = Predicates {
        name_matcher: StringMatcher::all(),
        remote_matcher: StringMatcher::all(),
        matched_local_targets: HashSet::new(),
        conflicted: false,
        include: Include {
            local_only: true,
            synced_remotes: true,
            untracked_remotes: true,
        },
    };
    let mut items = collect_items(readonly.view().tags(), &predicates);
    let sort_keys = crate::config::ui_tag_list_sort_keys(config)?;
    crate::bookmarks::sort(readonly.store(), &mut items, &sort_keys).map_err(be)?;

    let ignored =
        crate::bookmark_ops::default_ignored_remote(readonly.store()).map(jj_lib::ref_name::RemoteName::as_str);
    let change_of = |target: &RefTarget| -> Result<Option<ChangeId>, ViewError> {
        target
            .present_adds()
            .next()
            .map(|commit_id| {
                let commit = readonly.store().get_commit(commit_id).map_err(be)?;
                Ok(ChangeId(commit.change_id().reverse_hex()))
            })
            .transpose()
    };
    let mut out = Vec::new();
    for item in &items {
        let Item {
            name,
            local_target,
            primary,
            tracked,
        } = item;
        let remote_row = |remote: &str, target: &RefTarget, is_tracked: bool| -> Result<Tag, ViewError> {
            Ok(Tag {
                name: name.as_str().to_owned(),
                target: change_of(target)?,
                conflicted: !target.is_resolved(),
                synced: is_tracked && target == *local_target,
                kind: TagKind::Remote {
                    remote_name: remote.to_owned(),
                    tracked: is_tracked,
                },
            })
        };
        match primary {
            Primary::Local { remote_refs } => out.push(Tag {
                name: name.as_str().to_owned(),
                target: change_of(local_target)?,
                conflicted: !local_target.is_resolved(),
                synced: remote_refs
                    .iter()
                    .all(|(_, remote_ref)| !remote_ref.is_tracked() || remote_ref.target == **local_target),
                kind: TagKind::Local,
            }),
            Primary::Untracked { remote, remote_ref } => {
                if Some(remote.as_str()) != ignored {
                    out.push(remote_row(remote.as_str(), &remote_ref.target, false)?);
                }
            }
        }
        for (remote, remote_ref) in tracked {
            if Some(remote.as_str()) != ignored {
                out.push(remote_row(remote.as_str(), &remote_ref.target, true)?);
            }
        }
    }
    Ok(out)
}

/// Lists the repo's visible head commits, sorted by hex commit id.
///
/// jj-lib's `View::heads()` is an unordered `HashSet`, so the sort is ours — and it is the
/// determinism guarantee callers may rely on. Head identity is per COMMIT, not per change: two
/// divergent commits of one change can both be heads, so collapsing to change ids would
/// fabricate duplicates.
///
/// # Errors
///
/// - [`ViewError::Backend`] — the head load failed; the jj-lib reason is forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_heads(workspace: &Workspace) -> Result<Vec<CommitId>, ViewError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let mut out: Vec<CommitId> = readonly.view().heads().iter().map(|id| CommitId(id.hex())).collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

/// Lists every workspace of this repo with its working-copy commit id.
///
/// The view half of `jj workspace list` (`cli/src/commands/workspace/list.rs:74` @ v0.46.0
/// iterates the same map): name → commit id, in jj-lib's own `BTreeMap` order (lexicographic by
/// workspace name), which is preserved rather than re-sorted. No workspace *path* is reported —
/// that lives in the `WorkspaceStore`, not the `View`.
///
/// # Errors
///
/// - [`ViewError::Backend`] — the head load failed; the jj-lib reason is forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_working_copies(workspace: &Workspace) -> Result<Vec<WorkingCopy>, ViewError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    Ok(readonly
        .view()
        .wc_commit_ids()
        .iter()
        .map(|(name, commit_id)| WorkingCopy {
            workspace_name: name.as_str().to_owned(),
            commit_id: CommitId(commit_id.hex()),
        })
        .collect())
}
