// SPDX-License-Identifier: MIT

//! `bookmarks.rs` — jj bookmark list read (FR-JJ-8, Story 9.29).
//!
//! Exposes a `jj_lib`-type-free view of jj's bookmarks: the row set and the facts
//! `jj bookmark list --all-remotes` prints — local rows (present, or `(deleted)` with tracked
//! remotes), tracked remote rows (synced or not, present or `(not created yet)`) and untracked
//! remote rows, each with its target change id, `conflicted`/`synced`, and on a remote row
//! `tracked` plus the ahead/behind distances to the local target. Re-resolves to the head
//! operation per call (ADR-0002) and never shells to the `jj` CLI (AR-AP-1).

use jj_lib::backend::CommitId;
use jj_lib::op_store::{LocalRemoteRefTarget, RefTarget, RemoteRef};
use jj_lib::repo::Repo as _;
use jj_lib::revset::walk_revs;
use jj_lib::workspace::Workspace;

use crate::ChangeId;

/// A commit count between a remote bookmark and its local counterpart, as jj-lib's
/// `Revset::count_estimate` reports it (the CLI's `tracking_ahead_count` /
/// `tracking_behind_count`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RefDistance {
    /// At least this many commits.
    pub lower: u64,
    /// At most this many commits; `None` when jj-lib could not bound the count (the CLI's
    /// "at least N commits"). Equal to `lower` for an exact count.
    pub upper: Option<u64>,
}

/// The distance of a synced pair — the CLI's `(0, Some(0))` fast path.
const SYNCED: RefDistance = RefDistance {
    lower: 0,
    upper: Some(0),
};

/// Whether a bookmark row is the local bookmark or a remote one, with the remote-only facts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BookmarkKind {
    /// A bookmark local to this repository.
    Local,
    /// A remote bookmark, tracked or not. `remote_name` is always present for a `Remote`
    /// entry (never `None`); it may be the empty string only in the theoretical
    /// empty-remote edge case (jj does not forbid an empty remote name). It is
    /// never fabricated — an absent value across the FFI wire is corruption.
    Remote {
        /// The remote this bookmark lives on (e.g. `"origin"`, or `"git"` in a colocated repo).
        remote_name: String,
        /// Whether the local bookmark tracks this remote bookmark (jj-lib `RemoteRef::is_tracked`).
        tracked: bool,
        /// Commits this remote target has that the local target lacks (`local..remote`).
        /// Present only on a tracked row whose own target and the local target are both present.
        ahead: Option<RefDistance>,
        /// Commits the local target has that this remote target lacks (`remote..local`).
        /// Present exactly when `ahead` is.
        behind: Option<RefDistance>,
    },
}

/// One row of `jj bookmark list --all-remotes` (FR-JJ-8, Story 9.29).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bookmark {
    /// Bookmark name, preserved as UTF-8 (jj-lib `RefName`).
    pub name: String,
    /// Target change id in jj reverse-hex form; for a conflicted target the first added
    /// commit's change id. `None` when the row's target is absent: a local bookmark that was
    /// deleted while still tracking a remote (the CLI's `(deleted)`), or a tracked remote
    /// bookmark not pushed yet (the CLI's `(not created yet)`).
    pub target: Option<ChangeId>,
    /// The target is an unresolved conflict (`!RefTarget::is_resolved`).
    pub conflicted: bool,
    /// Local row: every tracked remote bookmark of this name points where the local one does
    /// (true when none is tracked). Remote row: tracked and pointing where the local one does.
    pub synced: bool,
    /// Whether this row is the local bookmark or a remote one.
    pub kind: BookmarkKind,
}

/// Errors returned by [`crate::Repo::list_bookmarks`].
#[derive(Debug, thiserror::Error)]
pub enum BookmarkError {
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
    /// An underlying jj-lib failure (loader / view / store read / distance revset),
    /// opaque-string-wrapped so no `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`BookmarkError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> BookmarkError {
    BookmarkError::Backend(e.to_string())
}

/// Lists the `jj bookmark list --all-remotes` row set, sorted by name, then the local row,
/// then remote rows by remote name (FR-JJ-8, Story 9.29).
///
/// Mirrors the CLI's `commit_ref_list::collect_items` with every predicate open and
/// `commit_templater::CommitRef::{local, remote, remote_only}` for the facts (@ v0.46.0).
/// Re-resolves to the head operation every call (ADR-0002). Read-only; never shells to
/// `jj bookmark list` (AR-AP-1).
///
/// # Errors
///
/// - [`BookmarkError::Backend`] — `load_at_head`, a store read or a distance revset failed;
///   the jj-lib reason is forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_bookmarks(workspace: &Workspace) -> Result<Vec<Bookmark>, BookmarkError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let lister = Lister { repo: &readonly };

    let mut out: Vec<Bookmark> = Vec::new();
    for (name, targets) in readonly.view().bookmarks() {
        lister.push_rows(name.as_str(), &targets, &mut out)?;
    }

    out.sort_by(|a, b| {
        a.name
            .cmp(&b.name)
            .then_with(|| remote_sort_key(&a.kind).cmp(&remote_sort_key(&b.kind)))
    });
    Ok(out)
}

/// The secondary sort key: the local row (`None`) before remote rows by remote name.
fn remote_sort_key(kind: &BookmarkKind) -> Option<&str> {
    match kind {
        BookmarkKind::Local => None,
        BookmarkKind::Remote { remote_name, .. } => Some(remote_name),
    }
}

/// The head repo one listing reads.
struct Lister<'a> {
    repo: &'a jj_lib::repo::ReadonlyRepo,
}

impl Lister<'_> {
    /// Appends one name's rows: the local row when the local target is present or a remote is
    /// tracked, then one row per remote ref (`collect_items` with `--all-remotes`).
    fn push_rows(
        &self,
        name: &str,
        targets: &LocalRemoteRefTarget<'_>,
        out: &mut Vec<Bookmark>,
    ) -> Result<(), BookmarkError> {
        let local_target = targets.local_target;
        let remote_refs = &targets.remote_refs;

        if local_target.is_present() || remote_refs.iter().any(|(_, remote_ref)| remote_ref.is_tracked()) {
            out.push(Bookmark {
                name: name.to_owned(),
                target: self.change_of(local_target)?,
                conflicted: !local_target.is_resolved(),
                synced: remote_refs
                    .iter()
                    .all(|(_, remote_ref)| !remote_ref.is_tracked() || remote_ref.target == *local_target),
                kind: BookmarkKind::Local,
            });
        }

        for (remote_name, remote_ref) in remote_refs {
            out.push(self.remote_row(name, remote_name.as_str(), remote_ref, local_target)?);
        }
        Ok(())
    }

    /// One remote row (`CommitRef::remote` when tracked, `CommitRef::remote_only` otherwise).
    fn remote_row(
        &self,
        name: &str,
        remote_name: &str,
        remote_ref: &RemoteRef,
        local_target: &RefTarget,
    ) -> Result<Bookmark, BookmarkError> {
        let tracked = remote_ref.is_tracked();
        let synced = tracked && remote_ref.target == *local_target;
        let distances = if tracked && remote_ref.target.is_present() && local_target.is_present() {
            Some(if synced {
                (SYNCED, SYNCED)
            } else {
                let remote_ids: Vec<CommitId> = remote_ref.target.present_adds().cloned().collect();
                let local_ids: Vec<CommitId> = local_target.present_adds().cloned().collect();
                (
                    self.distance(&remote_ids, &local_ids)?,
                    self.distance(&local_ids, &remote_ids)?,
                )
            })
        } else {
            None
        };
        let (ahead, behind) = distances.unzip();
        Ok(Bookmark {
            name: name.to_owned(),
            target: self.change_of(&remote_ref.target)?,
            conflicted: !remote_ref.target.is_resolved(),
            synced,
            kind: BookmarkKind::Remote {
                remote_name: remote_name.to_owned(),
                tracked,
                ahead,
                behind,
            },
        })
    }

    /// The change id of `target`'s first present add, `None` when absent.
    fn change_of(&self, target: &RefTarget) -> Result<Option<ChangeId>, BookmarkError> {
        target
            .present_adds()
            .next()
            .map(|commit_id| {
                let commit = self.repo.store().get_commit(commit_id).map_err(be)?;
                Ok(ChangeId(commit.change_id().reverse_hex()))
            })
            .transpose()
    }

    /// `count_estimate` of `unwanted..wanted` (jj-lib `walk_revs`), as the CLI counts.
    fn distance(&self, wanted: &[CommitId], unwanted: &[CommitId]) -> Result<RefDistance, BookmarkError> {
        let (lower, upper) = walk_revs(self.repo, wanted, unwanted)
            .map_err(be)?
            .count_estimate()
            .map_err(be)?;
        Ok(RefDistance {
            lower: lower as u64,
            upper: upper.map(|upper| upper as u64),
        })
    }
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
