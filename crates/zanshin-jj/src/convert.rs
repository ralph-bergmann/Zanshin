// SPDX-License-Identifier: MIT

//! Colocated Git → jj conversion (FR-JJ-18a).
//!
//! Converts an existing Git repository into a colocated jj workspace: a `.jj/`
//! is created next to the existing, **untouched** `.git/`, full history is
//! imported, and the `git` CLI keeps working. Additive and reversible —
//! deleting `.jj/` restores the plain Git repo. Acts only on the caller's
//! explicit choice; the conversion never overwrites a working-copy file.

use std::collections::HashMap;
use std::path::Path;

use jj_lib::git::{import_head, import_refs, GitImportOptions};
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

/// Runs the external-git init + ref/head import. On `Err`, the caller rolls back `.jj/`.
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
