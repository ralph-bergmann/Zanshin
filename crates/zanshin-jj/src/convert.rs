// SPDX-License-Identifier: MIT

//! Git → jj conversion helpers (FR-JJ-18a / FR-JJ-18b).
//!
//! Two distinct conversion modes are provided:
//!
//! ## Colocated conversion — [`convert_colocated`] (FR-JJ-18a)
//!
//! Creates a jj workspace **in-place** inside an existing Git repo: a `.jj/` is
//! added alongside the existing `.git/`; the two share the **same directory** and
//! the same object store.  The Git CLI keeps working; `jj` leads on the snapshot
//! schedule.  Deleting `.jj/` fully restores the plain Git repo.
//!
//! Mirrors `jj git init --colocate` over an existing `.git/`.
//!
//! ## jj-native import — [`convert_import`] (FR-JJ-18b)
//!
//! Creates a **separate**, non-colocated jj workspace at a **user-chosen
//! destination directory**, backed by the object store of an existing Git repo.
//! The destination gets a `.jj/` and **no** `.git/`; jj leads exclusively.
//!
//! **This is NOT a clone.** The new workspace shares the source's Git object
//! store (`.jj/repo/store/git_target` → `<source>/.git`); the source repo must
//! continue to exist after the import — moving or deleting it corrupts the jj
//! workspace.  Use [`convert_colocated`] if you want everything in one directory,
//! or `Repo::clone` if you need a self-contained copy of the objects.
//!
//! Mirrors `jj git init --git-repo=<source> <destination>` (non-colocated).
//! A **bare** source repo is supported (unlike `convert_colocated`).
//!
//! ### jj 0.42 note
//!
//! In-place jj-native conversion of an existing `.git/` is impossible in jj
//! 0.42: `jj git init --no-colocate` over an existing `.git/` is a hard error.
//! A genuinely non-colocated result always requires a separate destination
//! directory, hence the two-parameter signature of `convert_import`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use jj_lib::git::{import_head, import_refs, GitImportOptions};
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;

use crate::repo::make_settings;
use crate::{detect_repo, Repo, RepoError, RepoKind};

/// Converts the Git repository at `path` into a colocated jj workspace (FR-JJ-18a).
///
/// Additive and reversible: a `.jj/` is created alongside the existing,
/// non-destructively-reused `.git/`; the working-copy files are never
/// overwritten. Returns a warm [`Repo`] handle for the now-colocated workspace.
///
/// # Errors
///
/// - [`RepoError::AlreadyJjRepo`] — `path` is already a jj workspace.
/// - [`RepoError::NotAGitRepo`] — `path` is neither a Git repo nor exists.
/// - [`RepoError::ConvertFailed`] — a jj-lib failure (or a `detect_repo` I/O
///   error) during conversion; the partially-created `.jj/` is rolled back.
pub fn convert_colocated(path: &Path) -> Result<Repo, RepoError> {
    match detect_repo(path) {
        Ok(RepoKind::Jj) => return Err(RepoError::AlreadyJjRepo { path: path.to_owned() }),
        Ok(RepoKind::Git) => {}
        Ok(RepoKind::Neither | RepoKind::PathNotFound) => return Err(RepoError::NotAGitRepo { path: path.to_owned() }),
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }

    let settings = make_settings()?;
    match convert_into(&settings, path) {
        Ok(()) => Repo::open(path),
        Err(e) => {
            // Roll back only what convert created: the `.jj/` dir. Never touch `.git/`.
            let _ = std::fs::remove_dir_all(path.join(".jj"));
            Err(e)
        }
    }
}

/// Creates a **jj-native** (non-colocated) workspace at `workspace_path` from the
/// existing Git repository at `git_repo_path` (FR-JJ-18b).
///
/// Mirrors `jj git init --git-repo=<git_repo_path> <workspace_path>`: jj leads,
/// the original repo stays a working Git repo, and the two **share the Git object
/// store**.
///
/// **This is NOT a clone** — the new workspace depends on `git_repo_path`
/// continuing to exist; deleting or moving the source corrupts it.  Unlike
/// [`convert_colocated`] (in-place, colocated), the jj workspace lives in a
/// **separate** directory and ends up with a `.jj/` and no `.git/`.  A **bare**
/// source repo is supported.
///
/// The source's user-visible refs (`refs/heads`, `refs/tags`) and `HEAD` are never
/// modified; jj only adds its own objects (commit objects, `refs/jj/keep/*`
/// GC-keep markers) to the shared store.
///
/// # Errors
///
/// - [`RepoError::AlreadyJjRepo`] — `workspace_path` (or `git_repo_path`) is
///   already a jj workspace.
/// - [`RepoError::NotAGitRepo`] — `git_repo_path` is not a Git repo (normal or
///   bare) or does not exist.
/// - [`RepoError::ConvertFailed`] — a jj-lib failure (or a `detect_repo` I/O
///   error); the partially-created destination is rolled back.
pub fn convert_import(git_repo_path: &Path, workspace_path: &Path) -> Result<Repo, RepoError> {
    // Precondition 1: source must be a Git repo (normal OR bare) and not already jj.
    // Note: detect_repo returns Neither for a bare repo (no `.jj/` and no `.git/`
    // child). We check is_bare_git_dir() locally — do NOT extend detect_repo (D3).
    match detect_repo(git_repo_path) {
        Ok(RepoKind::Jj) => {
            return Err(RepoError::AlreadyJjRepo {
                path: git_repo_path.to_owned(),
            })
        }
        Ok(RepoKind::Git) => {}
        Ok(RepoKind::Neither | RepoKind::PathNotFound) => {
            if !is_bare_git_dir(git_repo_path) {
                return Err(RepoError::NotAGitRepo {
                    path: git_repo_path.to_owned(),
                });
            }
            // bare source — SUPPORTED (CLI parity, D9)
        }
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }
    // Precondition 2: destination must not already be a jj workspace.
    match detect_repo(workspace_path) {
        Ok(RepoKind::Jj) => {
            return Err(RepoError::AlreadyJjRepo {
                path: workspace_path.to_owned(),
            })
        }
        Ok(_) => {}
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }

    let settings = make_settings()?;
    let created_dir = !workspace_path.exists();
    match import_into(&settings, git_repo_path, workspace_path) {
        Ok(()) => Repo::open(workspace_path),
        Err(e) => {
            if created_dir {
                let _ = std::fs::remove_dir_all(workspace_path);
            } else {
                let _ = std::fs::remove_dir_all(workspace_path.join(".jj"));
            }
            Err(e)
        }
    }
}

/// Stat-only: is `path` itself a (bare) git directory?
///
/// Uses git's own gitdir heuristic: HEAD file + objects/ dir + refs/ dir.
/// `detect_repo` classifies a bare repo as `Neither` (correct for the file-picker;
/// bare repos have no `.jj/` and no `.git/` child), so the bare-source case is
/// recognised here locally — NOT by extending `detect_repo` (D3).
fn is_bare_git_dir(path: &Path) -> bool {
    path.join("HEAD").is_file() && path.join("objects").is_dir() && path.join("refs").is_dir()
}

/// Resolves the backing git dir exactly as `do_init` in the jj CLI:
/// append `.git` unless the path already ends with `.git`; fall back to the
/// path itself for a bare repo.
fn resolve_git_repo_path(arg: &Path) -> PathBuf {
    if arg.ends_with(".git") {
        return arg.to_owned();
    }
    let dot_git = arg.join(".git");
    if dot_git.exists() {
        dot_git
    } else {
        arg.to_owned()
    }
}

/// Port of `cli/src/git_util.rs::is_colocated_git_workspace` (@ v0.42.0).
///
/// Guards the working-copy materialisation step: we only create a jj-native `@`
/// when the workspace is NOT colocated (i.e. when `workspace_root ≠ git workdir`).
/// For the intended two-path use this is always false, but if a caller passes
/// `workspace_path == git_repo_path` jj silently creates a colocated result (D5).
fn is_colocated(repo: &impl jj_lib::repo::Repo, workspace_root: &Path) -> bool {
    let Ok(git_backend) = jj_lib::git::get_git_backend(repo.store()) else {
        return false;
    };
    let Some(git_workdir) = git_backend.git_workdir() else {
        return false; // bare backing repo → not colocated
    };
    git_workdir == workspace_root
}

/// Runs the colocated external-git init + ref/head import. On `Err`, the caller
/// rolls back `.jj/`.
fn convert_into(settings: &UserSettings, path: &Path) -> Result<(), RepoError> {
    // 1. Open the EXISTING `.git` as the backing store (gix::open — strictly
    //    non-destructive). Because `.git` is inside `path`, the workspace is
    //    colocated. This is what `jj git init --colocate` does for an existing
    //    repo (cli/src/commands/git/init.rs @ v0.42.0 -> GitInitMode::External).
    let git_repo_path = path.join(".git");
    let (_workspace, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
        settings,
        path,
        &git_repo_path,
    ))
    .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    // 2. Import existing Git history into jj's view — no WORKING-COPY writes (no
    //    check_out/snapshot); the `tx.commit` below persists the new op/view to
    //    `.jj/`. branches/tags -> bookmarks (makes the HEAD commit reachable via
    //    its branch), and HEAD -> git_head + the HEAD commit object (covers a
    //    detached HEAD too). NO `@`-reparent, NO working-copy snapshot/check_out
    //    (D3/D3a): `@` settles onto HEAD on the next colocated snapshot.
    let import_options = GitImportOptions {
        abandon_unreachable_commits: false, // fresh import: no stale jj refs (CLI init path)
        record_synthetic_predecessors: false,
        remote_auto_track_bookmarks: HashMap::new(),
    };
    let mut tx = repo.start_transaction();
    pollster::block_on(import_refs(tx.repo_mut(), &import_options))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    pollster::block_on(import_head(tx.repo_mut())).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    pollster::block_on(tx.commit("convert to colocated"))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    Ok(())
}

/// Ports `do_init`'s `GitInitMode::External` (non-colocated) branch (jj CLI @
/// v0.42.0). Creates and populates the jj workspace at `workspace_path`. On
/// `Err`, the caller rolls back the destination.
///
/// Single transaction (`"import git repo"`): the CLI uses two ops ("import git
/// refs" then "import git head"); we fold into one. The op-log *effect*
/// (one visible, reversible op for the conversion) is preserved; the exact
/// op-count is cosmetic and not replicated (consistent with `convert_colocated`).
fn import_into(settings: &UserSettings, git_repo_path: &Path, workspace_path: &Path) -> Result<(), RepoError> {
    std::fs::create_dir_all(workspace_path).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    let resolved = resolve_git_repo_path(git_repo_path);

    // 1. Open the existing repo as the backing store (gix::open — non-destructive).
    //    Keep `workspace`: we materialise the working copy into the dest below.
    let (mut workspace, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
        settings,
        workspace_path,
        &resolved,
    ))
    .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    let workspace_name = workspace.workspace_name().to_owned();

    let import_options = GitImportOptions {
        abandon_unreachable_commits: false,
        record_synthetic_predecessors: false,
        remote_auto_track_bookmarks: HashMap::new(),
    };
    let mut tx = repo.start_transaction();
    pollster::block_on(import_refs(tx.repo_mut(), &import_options))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    pollster::block_on(import_head(tx.repo_mut())).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    // 2. For a jj-native (non-colocated) workspace, create `@` on top of the
    //    imported HEAD commit and materialise the working copy.
    //    Skip entirely if: (a) colocated (dest == source path), or (b) HEAD is
    //    unborn (git_head().as_normal() == None — e.g. fresh `git init` with no
    //    commits). This mirrors `clone_into` (repo.rs:~346–371).
    let new_wc_commit = if is_colocated(tx.repo(), workspace_path) {
        None
    } else if let Some(git_head_id) = tx.repo().view().git_head().as_normal().cloned() {
        let mut_repo = tx.repo_mut();
        let commit = mut_repo
            .store()
            .get_commit(&git_head_id)
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        let wc = pollster::block_on(mut_repo.check_out(workspace_name.clone(), &commit))
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        pollster::block_on(mut_repo.rebase_descendants())
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        Some(wc)
    } else {
        None
    };

    let new_repo = pollster::block_on(tx.commit("import git repo"))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    // 3. Materialise HEAD's tree into the (empty) destination directory.
    if let Some(wc_commit) = &new_wc_commit {
        pollster::block_on(workspace.check_out(new_repo.op_id().clone(), None, wc_commit))
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repo::make_settings;

    #[test]
    fn is_colocated_with_simple_backend_returns_false() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let settings = make_settings().expect("settings");
        let (_ws, repo) =
            pollster::block_on(jj_lib::workspace::Workspace::init_simple(&settings, tmp.path())).expect("init_simple");
        assert!(!is_colocated(repo.as_ref(), tmp.path()));
    }

    #[test]
    fn is_colocated_with_colocated_workspace_returns_true() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        // Canonicalize so path comparison matches what gix reports for work_dir.
        let root = tmp.path().canonicalize().expect("canonicalize");
        let settings = make_settings().expect("settings");
        std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(&root)
            .env("GIT_CONFIG_GLOBAL", "")
            .status()
            .expect("git init");
        let git_dir = root.join(".git");
        let (_ws, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
            &settings, &root, &git_dir,
        ))
        .expect("init_external_git");
        assert!(is_colocated(repo.as_ref(), &root));
    }
}
