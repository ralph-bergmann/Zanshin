// SPDX-License-Identifier: MIT

//! `remotes.rs` — configured git-remote list read (FR-JJ-9) and `git fetch` (FR-JJ-13).
//!
//! Exposes a `jj_lib`/`gix`-type-free view of the repo's configured git remotes
//! and their fetch/push URLs, and lets [`crate::Repo::git_fetch`] actually sync with one.
//! Re-resolves to the head operation per call (ADR-0002), never shells to the `jj`
//! CLI (AR-AP-1). A non-git (native) backend has no remotes and yields an empty list
//! (never an error) from `list_remotes`, or `NotAGitRepo` from `git_fetch`.

use std::io;
use std::sync::Arc;

use gix::remote::Direction;
use jj_lib::git;
use jj_lib::git::{
    expand_fetch_refspecs, GitFetch, GitFetchError, GitFetchRefExpression, GitImportOptions, GitProgress,
    GitSidebandLineTerminator, GitSubprocessCallback, GitSubprocessOptions, UnexpectedGitBackendError,
};
use jj_lib::object_id::ObjectId as _; // for OperationId::hex()/CommitId::hex()
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::repo::Repo as _; // for ReadonlyRepo::store()/view()
use jj_lib::revset::UserRevsetExpression;
use jj_lib::rewrite::RebaseOptions;
use jj_lib::settings::UserSettings;
use jj_lib::str_util::{StringExpression, StringPattern};
use jj_lib::workspace::Workspace;

use crate::mutate::{self, MutateError, MutationResult};
use crate::op_support::resolve_immutable;
use crate::ChangeId;

/// One configured git remote and its fetch/push URLs (FR-JJ-9).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Remote {
    /// Remote name, e.g. `"origin"` (UTF-8).
    pub name: String,
    /// Fetch URL, returned **verbatim**: embedded credentials are NOT scrubbed
    /// and an SSH/`git@…` URL is NOT rewritten to HTTPS. The UI/MCP layer
    /// decides what is safe to display.
    pub url: String,
    /// Push URL when it DIFFERS from [`Remote::url`], `None` otherwise —
    /// null-for-absence, never `Some("")`. Absent means "this remote pushes to
    /// its fetch URL".
    ///
    /// This is a DIFFERENCE test, not a raw `remote.<name>.pushurl` read, for two
    /// reasons. gix resolves `url(Direction::Push)` as
    /// `push_url_alias.or(push_url).or(url(Fetch))` and exposes no public raw
    /// accessor, so "was a `pushurl` configured?" is not answerable through the
    /// API at all. And `jj git remote list` asks the same question this field
    /// does — it prints its `(push: …)` suffix only when the two rendered URLs
    /// differ (`cli/src/commands/git/remote/list.rs:49-55` @ v0.44.0) — so a
    /// `pushurl` that happens to equal `url` yields `None` here, which is CLI
    /// parity rather than information loss.
    ///
    /// Verbatim on the same terms as [`Remote::url`]: credentials survive.
    ///
    /// **Not round-trippable back through the write side.** Feeding this field
    /// straight into [`crate::Repo::git_remote_set_url`] DELETES a `pushurl` that
    /// was configured but happened to equal the fetch URL, because the read
    /// reports it as absent. A caller that re-applies a whole remote's config
    /// must treat `None` as "leave the push URL alone", not "clear it".
    pub push_url: Option<String>,
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

/// The fetch URL of `name` and its push URL WHEN THAT DIFFERS, both **verbatim**
/// (no credential scrubbing, no SSH→HTTPS rewrite). `None` if the remote is
/// missing, malformed, or has no fetch URL — the same skip condition the
/// fetch-only predecessor had.
///
/// Both directions are read here, through ONE renderer called twice, exactly as
/// the CLI's own `get_url` closure is (`cli/src/commands/git/remote/list.rs:49-55`
/// @ v0.44.0), so they can never diverge in how they render — and the CLI's
/// `(push: …)` rule is applied here too: gix's `url(Push)` FALLS BACK to the fetch
/// URL, so comparing the two is the only way to tell "no pushurl" from
/// "pushurl == url". See [`Remote::push_url`].
fn remote_urls(git_repo: &gix::Repository, name: &str) -> Option<(String, Option<String>)> {
    let remote = git_repo.try_find_remote(name)?.ok()?;
    // to_bstring(), NOT to_string()/Display: gix_url's Display REDACTS the
    // password ("redacted"); to_bstring() preserves the URL verbatim. The
    // BString -> String conversion is lossy UTF-8, which is fine for URLs.
    let render = |d| remote.url(d).map(|url| url.to_bstring().to_string());
    let fetch = render(Direction::Fetch)?;
    let push = render(Direction::Push).filter(|p| *p != fetch);
    Some((fetch, push))
}

/// Lists configured git remotes with their fetch/push URLs, sorted by name (FR-JJ-9).
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
        if let Some((url, push_url)) = remote_urls(&git_repo, name.as_str()) {
            out.push(Remote {
                name: name.as_str().to_owned(),
                url,
                push_url,
            });
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

/// One progress tick emitted by a long-running mutation such as
/// [`crate::Repo::git_fetch`] (FR-JJ-13).
///
/// There is no synthetic final 100% event — the caller learns completion from
/// `git_fetch`'s own `Result` return, not from a terminal `ProgressEvent`.
#[derive(Debug, Clone, PartialEq)]
pub struct ProgressEvent {
    /// The mutation this progress belongs to, e.g. `"fetch"`.
    pub operation: String,
    /// Overall progress, normalized to `0.0..=1.0`.
    pub progress: f32,
    /// Short freeform status text (e.g. `"resolving deltas: 4/10"`). NOT CLI-exact
    /// terminal wording — only op-log descriptions carry CLI parity (NFR-R-2).
    pub message: String,
}

/// Callback invoked with each [`ProgressEvent`] during a long-running mutation such as
/// [`crate::Repo::git_fetch`] (FR-JJ-13).
pub type ProgressFn = dyn Fn(ProgressEvent) + Send + Sync;

/// Names whichever `git` subprocess phase is currently furthest along (deltas are
/// resolved last, so they take priority when their total is set), formatted as
/// `"<phase>: <fraction>/<total>"`. Freeform text only — NOT CLI-exact wording (see
/// [`ProgressEvent::message`]).
fn progress_message(p: &GitProgress) -> String {
    let phases: [(&str, (u64, u64)); 4] = [
        ("resolving deltas", p.deltas),
        ("receiving objects", p.objects),
        ("compressing objects", p.compressed_objects),
        ("counting objects", p.counted_objects),
    ];
    phases
        .into_iter()
        .find(|(_, (_, total))| *total != 0)
        .map(|(label, (frac, total))| format!("{label}: {frac}/{total}"))
        .unwrap_or_default()
}

/// Forwards jj-lib's raw `git fetch` subprocess progress ticks to the caller-supplied
/// [`ProgressFn`] as [`ProgressEvent`]s (FR-JJ-13). Sidebands (auth prompts, remote
/// server messages) are terminal-UX chatter Zanshin replaces — same no-op treatment
/// `crate::repo::NoopCallback` already gives those two hooks.
struct FetchCallback<'a> {
    progress: &'a ProgressFn,
}

impl GitSubprocessCallback for FetchCallback<'_> {
    fn needs_progress(&self) -> bool {
        true
    }

    fn progress(&mut self, git_progress: &GitProgress) -> io::Result<()> {
        (self.progress)(ProgressEvent {
            operation: "fetch".to_owned(),
            // `overall()` is jj-lib's own computation; clamp defensively so a
            // transient reporting glitch can never violate this field's documented
            // 0.0..=1.0 guarantee.
            progress: git_progress.overall().clamp(0.0, 1.0),
            message: progress_message(git_progress),
        });
        Ok(())
    }

    fn local_sideband(&mut self, _message: &[u8], _term: Option<GitSidebandLineTerminator>) -> io::Result<()> {
        Ok(())
    }

    fn remote_sideband(&mut self, _message: &[u8], _term: Option<GitSidebandLineTerminator>) -> io::Result<()> {
        Ok(())
    }
}

/// Fetches all branches and tags from `remote_name` and imports them (FR-JJ-13).
///
/// Mirrors [`crate::Repo::clone`]'s own fetch step (`clone_into`), but forwards real
/// progress via `progress` instead of discarding it via `NoopCallback`. `git_fetch`
/// never moves `@` — it only updates remote-tracking refs — so unlike the P0
/// mutations in `mutate.rs` there is no working-copy capture/sync step; the returned
/// `working_copy_change_id` is simply the (unchanged) post-commit `@`. A fresh
/// operation is committed even when nothing changed (CLI parity).
///
/// `import_options` is supplied by the caller — [`crate::Repo::git_fetch`] reads it from
/// the repo's EFFECTIVE config (FR-JJ-17), mirroring `cli/src/commands/git/fetch.rs:235`
/// @ v0.44.0, which takes both `git.abandon-unreachable-commits` and
/// `git.record-synthetic-predecessors` off config. Nothing here hardcodes either key.
///
/// The returned `abandoned_change_ids` are jj-lib's OWN abandonments — the commits
/// `import_refs` dropped because they became unreachable in git, which is exactly what
/// `git.abandon-unreachable-commits` governs. They are read from the `GitImportStats`
/// `import_refs` returns, through the same [`crate::git::project_abandoned`] helper
/// [`crate::Repo::git_import`] uses, so the two verbs cannot drift; with the key set to
/// `false` the list is empty because the stats are empty, not because anything is
/// hardcoded. `new_change_ids` is always empty — see [`MutationResult::new_change_ids`].
///
/// # Errors
///
/// - [`MutateError::RemoteNotFound`] — `remote_name` has no configured git remote.
/// - [`MutateError::NotAGitRepo`] — the workspace has no git backend at all, so `git fetch`
///   cannot run — jj-lib's `UnexpectedGitBackendError`, the only failure `GitFetch::new`
///   has. The same condition the six `crate::git` verbs already report under this variant.
/// - [`MutateError::Config`] — the immutable-set expression could not be resolved against
///   the transaction's base repo (same fault class `crate::git::git_import` reports).
/// - [`MutateError::NetworkError`] — the underlying `git` subprocess failed (network,
///   auth, or transport error). No operation is committed.
/// - [`MutateError::Backend`] — any other underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn git_fetch(
    workspace: &Workspace,
    settings: &UserSettings,
    remote_name: &str,
    immutable: &Arc<UserRevsetExpression>,
    import_options: &GitImportOptions,
    progress: &ProgressFn,
) -> Result<MutationResult, MutateError> {
    let remote_buf: RemoteNameBuf = remote_name.into();
    let remote: &RemoteName = &remote_buf;

    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let mut tx = readonly.start_transaction();

    let subprocess_options = GitSubprocessOptions::from_settings(settings).map_err(mutate::be)?;

    // WHY: `GitFetch::new`'s error type IS `UnexpectedGitBackendError` (jj-lib 0.44.0
    // `git.rs:3032-3047`) — `get_git_backend` is its only fallible step — so the blanket
    // `map_err` swallows nothing else. "No git backend" is the same condition the six
    // `crate::git` verbs report as `NotAGitRepo`; an unknown REMOTE is raised later, by
    // `fetch()`, as `GitFetchError::NoSuchRemote` below. The explicit parameter type is the
    // GUARD for that premise: a jj-lib bump that widens the error surface stops compiling
    // here instead of silently reporting unrelated faults as `jj.not_a_git_repo`.
    let mut fetcher = GitFetch::new(tx.repo_mut(), subprocess_options, import_options)
        .map_err(|_e: UnexpectedGitBackendError| MutateError::NotAGitRepo)?;

    let expr = GitFetchRefExpression {
        bookmark: StringExpression::Pattern(Box::new(
            // WHY: glob("*") selects all remote branches — this signature has no
            // branch/tag filter param (epics.md's AC only parameterizes remote_name).
            StringPattern::glob("*").map_err(mutate::be)?,
        )),
        tag: StringExpression::Pattern(Box::new(
            // WHY: glob("*") selects all remote tags, same rationale as above.
            StringPattern::glob("*").map_err(mutate::be)?,
        )),
    };
    let refspecs = expand_fetch_refspecs(remote, expr).map_err(mutate::be)?;

    let mut callback = FetchCallback { progress };
    // WHY: `depth: None` = a full (non-shallow) fetch. jj 0.44 dropped `fetch`'s trailing
    // `fetch_tags_override`, so the 0.42 call's second `None` is the one that went away — the
    // remaining one is `depth`, unchanged.
    let depth = None;
    fetcher
        .fetch(remote, refspecs, &mut callback, depth)
        .map_err(|e| match e {
            GitFetchError::NoSuchRemote(_) => MutateError::RemoteNotFound {
                name: remote_name.to_owned(),
            },
            GitFetchError::Subprocess(sub) => MutateError::NetworkError {
                reason: sub.to_string(),
            },
            other => mutate::be(other),
        })?;

    let stats = pollster::block_on(fetcher.import_refs()).map_err(mutate::be)?;
    let abandoned_change_ids = crate::git::project_abandoned(&stats);

    // A descendant pass BEFORE the commit, because `import_refs` calls
    // `record_abandoned_commit` (jj-lib `git.rs:796`), which populates `parent_mapping`, and
    // `Transaction::write` panics while rewrites are outstanding. This is the CLI's own
    // `tx.finish` step — `rebase_mutable_descendants` (`cli/src/cli_util.rs` @ v0.44.0) —
    // which likewise resolves the immutable set against `tx.base_repo()`.
    // Resolve first so the shared borrow of `tx` ends before `repo_mut()`.
    let resolved = resolve_immutable(tx.base_repo().as_ref(), immutable)?;
    pollster::block_on(
        tx.repo_mut()
            .rebase_descendants_with_options(&resolved, &RebaseOptions::default(), |_, _| {}),
    )
    .map_err(mutate::be)?;

    let new_repo =
        pollster::block_on(tx.commit(format!("fetch from git remote(s) {remote_name}"))).map_err(mutate::be)?;

    // git_fetch never moves `@` (it only touches remote-tracking refs), so there is no
    // capture_old_wc/sync_working_copy/check_out step here — just read the (unchanged)
    // post-commit `@`.
    let wc_id = new_repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .ok_or_else(|| MutateError::Backend("workspace has no working-copy commit".to_owned()))?;
    let wc_commit = new_repo.store().get_commit(wc_id).map_err(mutate::be)?;

    Ok(MutationResult {
        new_op_id: crate::OperationId(new_repo.op_id().hex()),
        // WHY empty: `GitImportStats` has no minted-change concept at all — it reports
        // abandonments, changed remote refs, rewritten commit ids and failed ref names.
        // `git_import` leaves this field empty for the same reason. When `@` itself was
        // abandoned, jj-lib's replacement is already reported via `working_copy_change_id`.
        new_change_ids: Vec::new(),
        abandoned_change_ids,
        working_copy_change_id: ChangeId(wc_commit.change_id().reverse_hex()),
    })
}

#[cfg(test)]
mod tests {
    use jj_lib::git::GitSubprocessCallback as _;

    use super::{FetchCallback, ProgressEvent};

    /// `progress_message` picks whichever phase is furthest along by priority
    /// (deltas > objects > `compressed_objects` > `counted_objects`, first nonzero
    /// total wins) and formats it as `"<phase>: <fraction>/<total>"`.
    #[test]
    fn progress_message_selects_the_highest_priority_active_phase() {
        use super::progress_message;
        use jj_lib::git::GitProgress;

        assert_eq!(progress_message(&GitProgress::default()), "", "no phase active yet");

        assert_eq!(
            progress_message(&GitProgress {
                counted_objects: (9, 20),
                ..Default::default()
            }),
            "counting objects: 9/20",
            "counted_objects is the lowest-priority phase but the only one active"
        );

        assert_eq!(
            progress_message(&GitProgress {
                compressed_objects: (2, 4),
                counted_objects: (9, 20),
                ..Default::default()
            }),
            "compressing objects: 2/4",
            "compressed_objects outranks counted_objects"
        );

        assert_eq!(
            progress_message(&GitProgress {
                objects: (3, 10),
                compressed_objects: (2, 4),
                counted_objects: (9, 20),
                ..Default::default()
            }),
            "receiving objects: 3/10",
            "objects outranks compressed_objects and counted_objects"
        );

        assert_eq!(
            progress_message(&GitProgress {
                deltas: (1, 2),
                objects: (3, 10),
                compressed_objects: (2, 4),
                counted_objects: (9, 20),
            }),
            "resolving deltas: 1/2",
            "deltas outranks every other phase when all are active"
        );
    }

    /// `local_sideband` is an unconditional no-op (terminal-UX chatter Zanshin
    /// replaces — see the module doc comment). A real `git fetch` against a local
    /// bare remote never produces a line that reaches this specific hook (client-side
    /// lines from a local transport all carry jj-lib's "remote: " sideband prefix
    /// instead, exercised by the integration tests in `tests/remotes_write.rs`), so
    /// it is exercised directly here.
    #[test]
    fn fetch_callback_local_sideband_is_a_no_op() {
        let progress = |_: ProgressEvent| {};
        let mut callback = FetchCallback { progress: &progress };
        assert!(callback.local_sideband(b"some message", None).is_ok());
    }
}
