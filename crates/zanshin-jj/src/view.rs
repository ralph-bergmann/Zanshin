// SPDX-License-Identifier: MIT

//! `view.rs` — the direct `View` reads of ADR-0003 §5: tags, heads, and per-workspace
//! working-copy commits.
//!
//! Everything here is read straight off the head-resolved `View` — no revset is evaluated —
//! and returned `jj_lib`-type-free. Re-resolves to the head operation per call (ADR-0002) and
//! never shells to the `jj` CLI (AR-AP-1). `bookmarks.rs` is the sibling listing; the two
//! deliberately share one idiom.

use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;

use crate::{ChangeId, CommitId};

/// Whether a tag is local or a tracked remote tag.
///
/// `PartialOrd`/`Ord` order `Local` before `Remote`, then remotes by `remote_name` — the
/// secondary sort key for [`crate::Repo::list_tags`], mirroring [`crate::BookmarkKind`].
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum TagKind {
    /// A tag local to this repository.
    Local,
    /// A tracked remote tag. `remote_name` is always present for a `Remote` entry (never
    /// `None`); it may be the empty string only in the theoretical empty-remote edge case
    /// (jj does not forbid an empty remote name).
    Remote {
        /// The remote this tag tracks (e.g. `"origin"`).
        remote_name: String,
    },
}

/// One jj tag (local or tracked-remote) and its target change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tag {
    /// Tag name, preserved as UTF-8 (jj-lib `RefName`).
    pub name: String,
    /// Target change id in jj reverse-hex form. For a conflicted target, the first added
    /// commit's change id (listing scope only) — the same rule [`crate::Bookmark::target`] uses.
    pub target: ChangeId,
    /// Whether this entry is the local tag or a tracked-remote tag.
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
    /// An underlying jj-lib failure (loader / view / store read), opaque-string-wrapped so no
    /// `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`ViewError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> ViewError {
    ViewError::Backend(e.to_string())
}

/// Lists local + tracked-remote tags, sorted by name then kind.
///
/// Unlike the CLI's `jj tag list`, a tracked remote tag whose target equals the local one is
/// NOT hidden (`cli/src/commit_ref_list.rs:89-91` @ v0.44.0 drops it via
/// `include_synced_remotes`). That filter is a *display* default: the filtered, per-row view is
/// [`crate::CommitMeta::tags`]' job, and the unfiltered view is this function's — exactly the
/// split [`crate::Repo::list_bookmarks`] already makes. The backend classifies and offers; the
/// UI decides.
///
/// # Errors
///
/// - [`ViewError::Backend`] — `load_at_head` or a store read failed; the jj-lib reason is
///   forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_tags(workspace: &Workspace) -> Result<Vec<Tag>, ViewError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let view = readonly.view();
    let store = readonly.store();

    // CommitId → ChangeId (reverse-hex), the codebase idiom (bookmarks.rs:76-79).
    let to_change = |commit_id| -> Result<ChangeId, ViewError> {
        let commit = store.get_commit(commit_id).map_err(be)?;
        Ok(ChangeId(commit.change_id().reverse_hex()))
    };

    let mut out: Vec<Tag> = Vec::new();

    // Local tags — already absent-pruned by jj-lib (`set_local_tag_target` removes on absent).
    for (name, target) in view.local_tags() {
        // added_ids().next() handles normal AND conflicted targets uniformly
        // (a normal target is a one-add merge; no dead else-branch).
        if let Some(commit_id) = target.added_ids().next() {
            out.push(Tag {
                name: name.as_str().to_owned(),
                target: to_change(commit_id)?,
                kind: TagKind::Local,
            });
        }
    }

    // Remote tags — NOT pre-pruned: skip absent + untracked, mirroring `list_bookmarks`.
    for (symbol, remote_ref) in view.all_remote_tags() {
        if !remote_ref.is_present() || !remote_ref.is_tracked() {
            continue;
        }
        if let Some(commit_id) = remote_ref.target.added_ids().next() {
            out.push(Tag {
                name: symbol.name.as_str().to_owned(),
                target: to_change(commit_id)?,
                kind: TagKind::Remote {
                    remote_name: symbol.remote.as_str().to_owned(),
                },
            });
        }
    }

    out.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.kind.cmp(&b.kind)));
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
/// - [`ViewError::Backend`] — `load_at_head` failed; the jj-lib reason is forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_heads(workspace: &Workspace) -> Result<Vec<CommitId>, ViewError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let mut out: Vec<CommitId> = readonly.view().heads().iter().map(|id| CommitId(id.hex())).collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

/// Lists every workspace of this repo with its working-copy commit id.
///
/// The view half of `jj workspace list` (`cli/src/commands/workspace/list.rs:74` @ v0.44.0
/// iterates the same map): name → commit id, in jj-lib's own `BTreeMap` order (lexicographic by
/// workspace name), which is preserved rather than re-sorted. No workspace *path* is reported —
/// that lives in the `WorkspaceStore`, not the `View`.
///
/// # Errors
///
/// - [`ViewError::Backend`] — `load_at_head` failed; the jj-lib reason is forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_working_copies(workspace: &Workspace) -> Result<Vec<WorkingCopy>, ViewError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
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
