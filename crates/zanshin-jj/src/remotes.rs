// SPDX-License-Identifier: MIT

//! `remotes.rs` — configured git-remote list read (FR-JJ-9).
//!
//! Exposes a `jj_lib`/`gix`-type-free view of the repo's configured git remotes
//! and their fetch URLs. Re-resolves to the head operation per call (ADR-0002),
//! never shells to the `jj` CLI (AR-AP-1). A non-git (native) backend has no
//! remotes and yields an empty list (never an error).

use gix::remote::Direction;
use jj_lib::git;
use jj_lib::repo::Repo as _; // for ReadonlyRepo::store()
use jj_lib::workspace::Workspace;

/// One configured git remote and its fetch URL (FR-JJ-9).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Remote {
    /// Remote name, e.g. `"origin"` (UTF-8).
    pub name: String,
    /// Fetch URL, returned **verbatim**: embedded credentials are NOT scrubbed
    /// and an SSH/`git@…` URL is NOT rewritten to HTTPS. The UI/MCP layer
    /// decides what is safe to display.
    pub url: String,
}

/// Errors returned by [`crate::Repo::list_remotes`].
#[derive(Debug, thiserror::Error)]
pub enum RemoteError {
    /// An underlying jj-lib failure (loader read), opaque-string-wrapped so no
    /// `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`RemoteError::Backend`].
fn re<E: std::fmt::Display>(e: E) -> RemoteError {
    RemoteError::Backend(e.to_string())
}

/// The fetch URL of `name`, **verbatim** (no credential scrubbing, no SSH→HTTPS
/// rewrite). `None` if the remote is missing, malformed, or has no fetch URL.
fn fetch_url(git_repo: &gix::Repository, name: &str) -> Option<String> {
    let remote = git_repo.try_find_remote(name)?.ok()?;
    // to_bstring(), NOT to_string()/Display: gix_url's Display REDACTS the
    // password ("redacted"); to_bstring() preserves the URL verbatim. The
    // BString -> String conversion is lossy UTF-8, which is fine for URLs.
    remote.url(Direction::Fetch).map(|url| url.to_bstring().to_string())
}

/// Lists configured git remotes with fetch URLs, sorted by name (FR-JJ-9).
///
/// Re-resolves to the head operation every call (ADR-0002). Read-only; never
/// shells to `jj git remote list` (AR-AP-1). A non-git (native) backend, or a
/// git-backed repo with no remotes, yields `Ok(vec![])`.
///
/// # Errors
///
/// - [`RemoteError::Backend`] — `load_at_head` failed; the jj-lib reason is
///   forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_remotes(workspace: &Workspace) -> Result<Vec<Remote>, RemoteError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(re)?;
    let store = readonly.store();

    // `unwrap_or_default` collapses the native-backend `UnexpectedGitBackendError`
    // to "no remotes". A native repo (`Repo::init(path, None)` -> `init_simple`) is a
    // live, reachable path; it correctly yields an empty list (FR-JJ-9 native-backend AC).
    let names = git::get_all_remote_names(store).unwrap_or_default();
    if names.is_empty() {
        return Ok(Vec::new());
    }

    // names non-empty => the store is git-backed => get_git_repo succeeds.
    let git_repo = git::get_git_repo(store).map_err(re)?;

    let mut out: Vec<Remote> = Vec::with_capacity(names.len());
    for name in &names {
        if let Some(url) = fetch_url(&git_repo, name.as_str()) {
            out.push(Remote {
                name: name.as_str().to_owned(),
                url,
            });
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}
