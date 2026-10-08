// SPDX-License-Identifier: MIT

//! `bookmarks.rs` — jj bookmark list read (FR-JJ-8).
//!
//! Exposes a `jj_lib`-type-free view of jj's bookmarks: local bookmarks and
//! tracked remote bookmarks, each resolved to its target change id. Re-resolves
//! to the head operation per call (ADR-0002) and never shells to the `jj` CLI
//! (AR-AP-1).

use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;

use crate::ChangeId;

/// Whether a bookmark is local or a tracked remote bookmark.
///
/// `PartialOrd`/`Ord` order `Local` before `Remote`, then remotes by
/// `remote_name` — the secondary sort key for [`crate::Repo::list_bookmarks`] (FR-JJ-8).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum BookmarkKind {
    /// A bookmark local to this repository.
    Local,
    /// A tracked remote bookmark. `remote_name` is always present for a `Remote`
    /// entry (never `None`); it may be the empty string only in the theoretical
    /// empty-remote edge case (jj does not forbid an empty remote name). It is
    /// never fabricated — an absent value across the FFI wire is corruption.
    Remote {
        /// The remote this bookmark tracks (e.g. `"origin"`).
        remote_name: String,
    },
}

/// One jj bookmark (local or tracked-remote) and its target change (FR-JJ-8).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bookmark {
    /// Bookmark name, preserved as UTF-8 (jj-lib `RefName`).
    pub name: String,
    /// Target change id in jj reverse-hex form. For a conflicted/divergent
    /// target, the first added commit's change id (listing scope only).
    pub target: ChangeId,
    /// Whether this entry is the local bookmark or a tracked-remote bookmark.
    pub kind: BookmarkKind,
}

/// Errors returned by [`crate::Repo::list_bookmarks`].
#[derive(Debug, thiserror::Error)]
pub enum BookmarkError {
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
    /// An underlying jj-lib failure (loader / view / store read),
    /// opaque-string-wrapped so no `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`BookmarkError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> BookmarkError {
    BookmarkError::Backend(e.to_string())
}

/// Lists local + tracked-remote bookmarks, sorted by name then kind (FR-JJ-8).
///
/// Re-resolves to the head operation every call (ADR-0002). Read-only; never
/// shells to `jj bookmark list` (AR-AP-1). A conflicted target resolves to the
/// first added commit's change id (listing scope only).
///
/// # Errors
///
/// - [`BookmarkError::Backend`] — `load_at_head` or a store read failed; the
///   jj-lib reason is forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_bookmarks(workspace: &Workspace) -> Result<Vec<Bookmark>, BookmarkError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let view = readonly.view();
    let store = readonly.store();

    // CommitId → ChangeId (reverse-hex), the codebase idiom (change.rs:172-176).
    let to_change = |commit_id| -> Result<ChangeId, BookmarkError> {
        let commit = store.get_commit(commit_id).map_err(be)?;
        Ok(ChangeId(commit.change_id().reverse_hex()))
    };

    let mut out: Vec<Bookmark> = Vec::new();

    // Local bookmarks — already absent-pruned by jj-lib (view.rs:176).
    for (name, target) in view.local_bookmarks() {
        // added_ids().next() handles normal AND conflicted targets uniformly
        // (a normal target is a one-add merge; no dead else-branch).
        if let Some(commit_id) = target.present_adds().next() {
            out.push(Bookmark {
                name: name.as_str().to_owned(),
                target: to_change(commit_id)?,
                kind: BookmarkKind::Local,
            });
        }
    }

    // Remote bookmarks — NOT pre-pruned: skip absent + untracked (view.rs:245-260).
    for (symbol, remote_ref) in view.all_remote_bookmarks() {
        if !remote_ref.is_present() || !remote_ref.is_tracked() {
            continue;
        }
        if let Some(commit_id) = remote_ref.target.present_adds().next() {
            out.push(Bookmark {
                name: symbol.name.as_str().to_owned(),
                target: to_change(commit_id)?,
                kind: BookmarkKind::Remote {
                    remote_name: symbol.remote.as_str().to_owned(),
                },
            });
        }
    }

    out.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.kind.cmp(&b.kind)));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::{list_bookmarks, BookmarkError};

    /// A head that no longer loads is this module's own `Backend` failure. Through
    /// [`crate::Repo`] the pre-verb snapshot (Story 9.26) hits it first, so the module function
    /// is called directly.
    #[test]
    fn a_head_that_no_longer_loads_is_a_backend_error() {
        let (_tmp, repo) = crate::test_support::repo_with_a_broken_head();
        let result = list_bookmarks(repo.workspace());
        assert!(matches!(result, Err(BookmarkError::Backend(_))), "{result:?}");
    }
}
