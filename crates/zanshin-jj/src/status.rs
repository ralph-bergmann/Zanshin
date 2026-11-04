// SPDX-License-Identifier: MIT

use std::path::PathBuf;

use futures::StreamExt as _;
use jj_lib::copies::{CopyOperation, CopyRecords};
use jj_lib::matchers::EverythingMatcher;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;

/// The working-copy status of a jj repository.
#[derive(Debug)]
pub struct Status {
    /// Files that differ between `@` and its parent (empty when the workspace has no `@`).
    pub files: Vec<FileChange>,
    /// Change identifier of the working-copy commit (`@`), in jj reverse-hex form; `None`
    /// exactly when this workspace has no `@` (the CLI's "No working copy.").
    pub working_copy_change_id: Option<ChangeId>,
    /// Change identifier of the parent commit (`@-`), in jj reverse-hex form (the root commit's
    /// when `@` has no parent); `None` together with
    /// [`working_copy_change_id`](Self::working_copy_change_id).
    pub parent_change_id: Option<ChangeId>,
}

/// A single changed file in the working copy.
#[derive(Debug)]
pub struct FileChange {
    /// Repository-relative path of the changed file.
    pub path: PathBuf,
    /// How the file changed between `@-` and `@`.
    pub kind: ChangeKind,
}

/// How the file changed between `@-` and `@` (as [`crate::FileDiff::kind`]: between the diff's
/// two sides).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChangeKind {
    /// The file was added in `@` (not present in `@-`).
    Added,
    /// The file was modified in `@` (present in both `@-` and `@` with different content).
    Modified,
    /// The file was removed from `@` (present in `@-` but absent in `@`).
    Removed,
    /// The file was renamed; `from` is the previous path.
    Renamed {
        /// The path the file was renamed from.
        from: PathBuf,
    },
    /// The file was copied; `from` is the source path.
    Copied {
        /// The path the file was copied from.
        from: PathBuf,
    },
}

/// A jj change identifier in jj's canonical reverse-hex (`z-k`) display form —
/// the `qpvuntsm`-style id shown by `jj log`. `jj_lib`-type-free (FR-JJ-16).
/// Reused by Story 2.6 (`change.rs`), 2.7 (`op_log.rs`), and 2.8 (`bookmarks.rs`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangeId(pub String);

/// Errors returned by [`crate::Repo::status`].
#[derive(Debug, thiserror::Error)]
pub enum StatusError {
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
    /// Underlying jj-lib failure, opaque-string-wrapped so no `jj_lib` type escapes.
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts a jj-lib error to [`StatusError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> StatusError {
    StatusError::Backend(e.to_string())
}

/// Converts a `RepoPath` to a `PathBuf`.
///
/// Infallible: jj-lib enforces UTF-8 on all repo paths (`RepoPathBuf` wraps `String`).
fn repo_path_to_pathbuf(p: &jj_lib::repo_path::RepoPath) -> PathBuf {
    PathBuf::from(p.as_internal_file_string())
}

/// Computes working-copy status for the given workspace.
///
/// Re-resolves to head on every call (ADR-0002: the handle is a warm loader,
/// not a state cache). Read-only; [`crate::Repo::status`] runs the pre-verb snapshot
/// (Story 9.26) before calling it.
///
/// # Errors
///
/// Returns [`StatusError::Backend`] on any jj-lib failure. A workspace without a working-copy
/// commit is no error: as the CLI's `jj status` prints "No working copy." and succeeds, the
/// status then has no files and no change ids.
pub(crate) fn working_copy_status(workspace: &Workspace) -> Result<Status, StatusError> {
    // Re-resolve to head — ADR-0002.
    let repo = crate::snapshot::reload_head(workspace).map_err(be)?;

    // Resolve @: get the working-copy commit id and load the commit (SYNC).
    let Some(wc_id) = repo.view().get_wc_commit_id(workspace.workspace_name()) else {
        return Ok(Status {
            files: vec![],
            working_copy_change_id: None,
            parent_change_id: None,
        });
    };
    let wc_commit = repo.store().get_commit(wc_id).map_err(be)?;

    // Trees: `after` is sync; `before` merges all parents (root-safe, async).
    let after = wc_commit.tree();
    let before = pollster::block_on(wc_commit.parent_tree(repo.index())).map_err(be)?;

    // Parent commit for copy records + `parent_change_id`.
    // WHY: get_copy_records takes a single root CommitId. For the common single-parent @,
    // use the first parent id. For a merge @ (multiple parents) we still pick the first;
    // `parent_tree` (which merges all parents, root-safe) handles the diff correctly.
    // Full multi-parent copy attribution is out of WIP scope (D4).
    // When @ has no parents (@ IS the root commit), fall back to the store's root commit —
    // the diff `before` is already empty in that case.
    let (parent_commit_id, parent_change_id) = if let Some(id) = wc_commit.parent_ids().first() {
        let parent_commit = repo.store().get_commit(id).map_err(be)?;
        (id.clone(), ChangeId(parent_commit.change_id().reverse_hex()))
    } else {
        let root_id = repo.store().root_commit_id().clone();
        let root_commit = repo.store().get_commit(&root_id).map_err(be)?;
        (root_id, ChangeId(root_commit.change_id().reverse_hex()))
    };

    // Build copy records. On native (SimpleBackend), the stream is empty → graceful
    // degradation to Added+Removed pairs (AC-12).
    let mut records = CopyRecords::default();
    let mut copy_stream = repo
        .store()
        .get_copy_records(None, &parent_commit_id, wc_id)
        .map_err(be)?;
    pollster::block_on(async {
        while let Some(result) = copy_stream.next().await {
            match result {
                Ok(r) => records.add_records([r]),
                Err(e) => return Err(be(e)),
            }
        }
        Ok::<(), StatusError>(())
    })?;

    // Copies-aware diff: one code path for renames/copies and plain changes (D4).
    let mut diff_stream = before.diff_with_copies(&after, &EverythingMatcher, &records);
    let mut files: Vec<FileChange> = Vec::new();
    pollster::block_on(async {
        while let Some(entry) = diff_stream.next().await {
            let d = entry.values.map_err(be)?;
            let kind = if let Some((src, op)) = entry.path.source {
                match op {
                    CopyOperation::Rename => ChangeKind::Renamed {
                        from: repo_path_to_pathbuf(&src),
                    },
                    CopyOperation::Copy => ChangeKind::Copied {
                        from: repo_path_to_pathbuf(&src),
                    },
                }
            } else if d.before.is_absent() && d.after.is_present() {
                ChangeKind::Added
            } else if d.before.is_present() && d.after.is_absent() {
                ChangeKind::Removed
            } else {
                ChangeKind::Modified
            };
            files.push(FileChange {
                path: repo_path_to_pathbuf(&entry.path.target),
                kind,
            });
        }
        Ok::<(), StatusError>(())
    })?;

    Ok(Status {
        files,
        working_copy_change_id: Some(ChangeId(wc_commit.change_id().reverse_hex())),
        parent_change_id: Some(parent_change_id),
    })
}

#[cfg(test)]
mod tests {
    use super::{working_copy_status, StatusError};

    /// A head that no longer loads is this module's own `Backend` failure. Through
    /// [`crate::Repo`] the pre-verb snapshot (Story 9.26) hits it first, so the module function
    /// is called directly.
    #[test]
    fn a_head_that_no_longer_loads_is_a_backend_error() {
        let (_tmp, repo) = crate::test_support::repo_with_a_broken_head();
        let result = working_copy_status(repo.workspace());
        assert!(matches!(result, Err(StatusError::Backend(_))), "{result:?}");
    }
}
