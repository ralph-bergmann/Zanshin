// SPDX-License-Identifier: MIT

//! Repository-kind detection (FR-JJ-17).
//!
//! Stat-only classification of a filesystem path for the open-project flow.
//! Reports *structural presence* of repo markers, **not** integrity — a
//! structurally-present but corrupt repo is `Repo::open`'s problem, not this
//! module's. Never loads a workspace, never mutates the filesystem, never panics.

use std::path::{Path, PathBuf};

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

/// A repository root discovered by walking up from a start path ([`find_repo_root`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoRoot {
    /// The directory that is the repository root.
    pub root: PathBuf,
    /// The kind of repository found. Only ever [`RepoKind::Jj`] or [`RepoKind::Git`]
    /// — `find_repo_root` never yields a `RepoRoot` for `Neither`/`PathNotFound`.
    pub kind: RepoKind,
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

/// Walks up from `start` to the nearest enclosing repository root (FR-JJ-17).
///
/// Evaluates `start`, then each ancestor, returning the first directory that
/// [`detect_repo`] classifies as [`RepoKind::Jj`] or [`RepoKind::Git`]. The upward
/// walk is bounded by the **`$HOME` ceiling**: it never climbs to `$HOME` or above,
/// so a dotfiles repo at `~` is not surfaced when opening an unrelated folder under
/// home. The ceiling bounds the walk-*up* only — `start` itself is always classified,
/// so explicitly opening `~` still finds `~/.jj`/`~/.git`. Returns `Ok(None)` if no
/// repository is found within the ceiling.
///
/// Stat-only — composes [`detect_repo`] per level (same `.jj`-is-dir / `.git`-exists
/// semantics, symlinks followed). Never loads, mutates, or panics.
///
/// # Consent-gated use
///
/// On `Ok(Some(root))`, compare `root` against `start`: `root == start` ⇒ the chosen
/// path is itself a repository (open directly); `root != start` ⇒ a *suggestion* of an
/// **enclosing** repository the caller should **surface for confirmation** (UI prompt,
/// or MCP message such as "not a jj workspace here; the nearest is `<root>`"). This
/// function never opens anything — it only reports.
///
/// # Errors
///
/// Returns [`DetectError::Io`] if a visited level cannot be inspected (the I/O error
/// surfaced by [`detect_repo`], e.g. `EACCES`/`ENOTDIR`) — propagated **fail-fast**,
/// never collapsed to `Ok(None)`. Because statting `start` already requires search
/// permission on every ancestor, this can only occur on `start` itself (a
/// non-directory path component, or an unsearchable prefix); surfacing it lets the
/// caller report "could not inspect this path" instead of "not a repository".
pub fn find_repo_root(start: &Path) -> Result<Option<RepoRoot>, DetectError> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    find_repo_root_within(start, home.as_deref())
}

/// Core walk-up with an explicit `ceiling` (crate-private so the `$HOME` ceiling is
/// unit-testable without depending on the real `$HOME`). Classifies `start`, then
/// ancestors strictly below `ceiling`; `ceiling` and anything above is never climbed
/// into, except that `start` itself is always classified. `ceiling == None` ⇒ walk
/// to the filesystem root. Propagates a [`detect_repo`] I/O error fail-fast.
fn find_repo_root_within(start: &Path, ceiling: Option<&Path>) -> Result<Option<RepoRoot>, DetectError> {
    for dir in start
        .ancestors()
        .take_while(|dir| *dir == start || ceiling.is_none_or(|c| !c.starts_with(dir)))
    {
        match detect_repo(dir)? {
            RepoKind::Jj => {
                return Ok(Some(RepoRoot {
                    root: dir.to_owned(),
                    kind: RepoKind::Jj,
                }))
            }
            RepoKind::Git => {
                return Ok(Some(RepoRoot {
                    root: dir.to_owned(),
                    kind: RepoKind::Git,
                }))
            }
            RepoKind::Neither | RepoKind::PathNotFound => {}
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::TempDir;

    use super::{find_repo_root_within, RepoKind, RepoRoot};

    // Helper: create a `.jj` dir marker inside `dir`.
    fn make_jj(dir: &std::path::Path) {
        fs::create_dir(dir.join(".jj")).unwrap();
    }

    // AC-9 case 8a: start below ceiling C, repo marker only at C -> Ok(None)
    #[test]
    fn ceiling_blocks_repo_at_ceiling_level() {
        let root = TempDir::new().unwrap();
        // C is the ceiling dir; it has a .jj marker.
        let ceiling = root.path().join("home");
        fs::create_dir(&ceiling).unwrap();
        make_jj(&ceiling);
        // start is strictly below the ceiling.
        let start = ceiling.join("projects").join("myapp");
        fs::create_dir_all(&start).unwrap();
        // The repo at the ceiling must NOT be surfaced.
        let result = find_repo_root_within(&start, Some(&ceiling)).unwrap();
        assert_eq!(result, None);
    }

    // AC-9 case 8b: start == C and C is itself a repo -> Ok(Some(root == C))
    #[test]
    fn ceiling_carve_out_start_equals_ceiling() {
        let root = TempDir::new().unwrap();
        let ceiling = root.path().join("home");
        fs::create_dir(&ceiling).unwrap();
        make_jj(&ceiling);
        // start IS the ceiling — carve-out means it is always classified.
        let result = find_repo_root_within(&ceiling, Some(&ceiling)).unwrap();
        assert_eq!(
            result,
            Some(RepoRoot {
                root: ceiling.clone(),
                kind: RepoKind::Jj
            })
        );
    }

    // AC-9 case 8c: ceiling = None -> walks past where a ceiling would have stopped
    #[test]
    fn no_ceiling_finds_repo_above_where_ceiling_would_stop() {
        let root = TempDir::new().unwrap();
        // Repo marker at the root level.
        make_jj(root.path());
        // Start deep inside.
        let start = root.path().join("a").join("b");
        fs::create_dir_all(&start).unwrap();
        // With ceiling = None the walk reaches root and finds the repo.
        let result = find_repo_root_within(&start, None).unwrap();
        assert_eq!(
            result,
            Some(RepoRoot {
                root: root.path().to_owned(),
                kind: RepoKind::Jj
            })
        );
    }

    // AC-9 case 8d: repo strictly below C is still found
    #[test]
    fn ceiling_does_not_block_repo_below_ceiling() {
        let root = TempDir::new().unwrap();
        let ceiling = root.path().join("home");
        fs::create_dir(&ceiling).unwrap();
        // Repo lives strictly below the ceiling.
        let repo_dir = ceiling.join("projects").join("myapp");
        fs::create_dir_all(&repo_dir).unwrap();
        make_jj(&repo_dir);
        // Start inside the repo.
        let start = repo_dir.join("src");
        fs::create_dir(&start).unwrap();
        let result = find_repo_root_within(&start, Some(&ceiling)).unwrap();
        assert_eq!(
            result,
            Some(RepoRoot {
                root: repo_dir.clone(),
                kind: RepoKind::Jj
            })
        );
    }
}
