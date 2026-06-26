// SPDX-License-Identifier: MIT

//! Repository-kind detection (FR-JJ-17).
//!
//! Stat-only classification of a filesystem path for the open-project flow.
//! Reports *structural presence* of repo markers, **not** integrity — a
//! structurally-present but corrupt repo is `Repo::open`'s problem, not this
//! module's. Never loads a workspace, never mutates the filesystem, never panics.

use std::path::Path;

/// How a filesystem path looks to the open-project flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepoKind {
    /// Contains a `.jj/` directory — a jj workspace (colocated repos count as Jj).
    Jj,
    /// Contains a `.git` entry but no `.jj/` directory — a (convertible) Git repo.
    Git,
    /// Exists but contains neither `.jj/` nor `.git`.
    Neither,
    /// The path was looked up and is genuinely absent.
    PathNotFound,
}

/// A genuine I/O failure while inspecting a path.
///
/// Distinct from [`RepoKind::PathNotFound`]: "not found" is a normal
/// classification, whereas this means the path *could not be inspected at all*
/// (e.g. permission denied, or a non-directory component in the path).
#[derive(Debug, thiserror::Error)]
pub enum DetectError {
    /// Determining whether the path exists failed with an I/O error other than
    /// "not found" (e.g. `EACCES` permission denied, or `ENOTDIR`).
    #[error("failed to inspect path: {0}")]
    Io(String),
}

/// Classifies `path` as a jj workspace, a Git repo, neither, or a missing path (FR-JJ-17).
///
/// Stat-only and cheap enough to call on every folder in a file picker. Reports
/// *structural presence*, not integrity: a `.jj` that is a regular file (not a
/// directory) is treated as corruption and does **not** classify as [`RepoKind::Jj`]
/// — integrity is [`crate::Repo::open`]'s job. Symlinked `.jj`/`.git` entries are
/// followed to their target (`stat`, not `lstat`). Never panics.
///
/// A genuinely absent path is [`RepoKind::PathNotFound`] — a normal classification,
/// not an error. The error case is reserved for a path that *exists* (or might) but
/// cannot be inspected; see Errors.
///
/// # Errors
///
/// Returns [`DetectError::Io`] when the path's existence cannot be determined
/// because the `stat` failed with an I/O error other than "not found" (e.g.
/// `EACCES` permission denied, or a non-directory component in the path).
pub fn detect_repo(path: &Path) -> Result<RepoKind, DetectError> {
    // `try_exists` distinguishes a genuinely-absent path (`Ok(false)`) from a path
    // that could not be inspected (`Err`, e.g. EACCES/ENOTDIR) — unlike `exists()`,
    // which collapses every error into `false`.
    match path.try_exists() {
        Ok(false) => return Ok(RepoKind::PathNotFound),
        Err(e) => return Err(DetectError::Io(e.to_string())),
        Ok(true) => {}
    }
    if path.join(".jj").is_dir() {
        return Ok(RepoKind::Jj);
    }
    if path.join(".git").exists() {
        return Ok(RepoKind::Git);
    }
    Ok(RepoKind::Neither)
}
