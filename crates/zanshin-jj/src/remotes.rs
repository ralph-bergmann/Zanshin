// SPDX-License-Identifier: MIT

//! `remotes.rs` — configured git-remote list read (FR-JJ-9) and `git fetch` (FR-JJ-13).
//!
//! Exposes a `jj_lib`/`gix`-type-free view of the repo's configured git remotes
//! and their fetch/push URLs, and lets [`crate::Repo::git_fetch`] actually sync with them (Story
//! 9.30: `jj git fetch`'s remote and ref selection).
//! Re-resolves to the head operation per call (ADR-0002), never shells to the `jj`
//! CLI (AR-AP-1). A non-git (native) backend has no remotes and yields an empty list
//! (never an error) from `list_remotes`, or `NotAGitRepo` from `git_fetch`.

use std::io;

use gix::remote::Direction;
use jj_lib::config::StackedConfig;
use jj_lib::git;
use jj_lib::git::{
    expand_fetch_refspecs, GitFetch, GitFetchError, GitFetchRefExpression, GitProgress, GitRefExpansionError,
    GitSidebandLineTerminator, GitSubprocessCallback, IgnoredRefspec, IgnoredRefspecs, UnexpectedGitBackendError,
};
use jj_lib::ref_name::{RefName, RemoteName, RemoteNameBuf};
use jj_lib::refs::LocalAndRemoteRef;
use jj_lib::repo::Repo as _; // for ReadonlyRepo::store()
use jj_lib::settings::UserSettings;
use jj_lib::str_util::StringExpression;
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::config::FetchField;
use crate::mutate::{self, MutateError, MutationResult};
use crate::op_support::start_repo_transaction;
use crate::snapshot::VerbContext;
use crate::warning::{WarningKind, Warnings};

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
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
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

/// Forwards jj-lib's raw `git` subprocess progress ticks to the caller-supplied [`ProgressFn`] as
/// [`ProgressEvent`]s tagged with `operation` — `"fetch"` (FR-JJ-13), `"clone"` and `"push"`
/// (Story 9.20). Sidebands (auth prompts, remote server messages) are terminal-UX chatter Zanshin
/// replaces, so both hooks are no-ops; a push's progress arrives mostly as sideband text, so a
/// push reports few or no ticks (jj-lib parses only the fetch phases into [`GitProgress`]).
pub(crate) struct ProgressCallback<'a> {
    /// The operation name every event carries.
    pub(crate) operation: &'static str,
    /// The caller's sink.
    pub(crate) progress: &'a ProgressFn,
}

impl GitSubprocessCallback for ProgressCallback<'_> {
    fn needs_progress(&self) -> bool {
        true
    }

    fn progress(&mut self, git_progress: &GitProgress) -> io::Result<()> {
        (self.progress)(ProgressEvent {
            operation: self.operation.to_owned(),
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

/// `jj git fetch`'s arguments (Story 9.30) — the CLI's `GitFetchArgs`
/// (`cli/src/commands/git/fetch.rs:69-133` @ v0.46.0) with its clap conflicts made
/// unrepresentable: the remotes and the refs are each one either/or. The default is the bare
/// `jj git fetch`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GitFetchArgs {
    /// Which remotes to fetch from.
    pub remotes: FetchRemotes,
    /// Which refs to fetch from each remote.
    pub refs: FetchRefs,
}

/// The remotes a [`crate::Repo::git_fetch`] fetches from (Story 9.30).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum FetchRemotes {
    /// No `--remote`: `git.fetch` (a list or a string of name patterns), else the only remote,
    /// else `origin` — [`crate::Repo::git_fetch_remotes`].
    #[default]
    Default,
    /// `--remote` (repeatable): the union of these name patterns; a bare word is a glob.
    Named(Vec<String>),
    /// `--all-remotes`: every remote.
    All,
}

/// The refs a [`crate::Repo::git_fetch`] fetches from each remote (Story 9.30).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum FetchRefs {
    /// Neither `--branch`, `--tag` nor `--tracked`: `remotes.<name>.fetch-bookmarks`, else the
    /// Git config's fetch refspecs; `remotes.<name>.fetch-tags`, else every tag.
    #[default]
    Default,
    /// `--branch` / `--tag` (repeatable; a bare word is a glob): the union of each list, an
    /// empty list fetching nothing of its kind — the CLI's `specific` group.
    Patterns {
        /// The branch name patterns (`-b`).
        branches: Vec<String>,
        /// The tag name patterns (`-t`).
        tags: Vec<String>,
    },
    /// `--tracked`: the bookmarks and tags already tracked from each remote, by exact name.
    Tracked,
}

/// The outcome of a [`crate::Repo::git_fetch`] (Story 9.30).
#[derive(Debug)]
pub struct GitFetchOutcome {
    /// The shared mutation contract, see [`crate::Repo::git_fetch`].
    pub mutation: MutationResult,
    /// The remotes fetched from, in remote-name order.
    pub remotes: Vec<String>,
    /// Hints the UI shows verbatim: "Fetching from the only existing remote: <name>".
    pub hints: Vec<String>,
    /// The Git refs the import could not read, lossy UTF-8, sorted by name (jj-lib's order) — what
    /// `jj.git_import_failed` lists.
    pub failed_ref_names: Vec<String>,
    /// Remote BOOKMARKS the import changed, in jj-lib's own `symbol` order — the lines the CLI's
    /// `print_imported_changes` prints (`cli/src/git_util.rs:228-266` @ v0.46.0); as
    /// [`crate::GitImportResult::changed_bookmarks`].
    pub changed_bookmarks: Vec<crate::GitRefUpdate>,
    /// Remote TAGS the import changed, in jj-lib's own `symbol` order; as
    /// [`crate::GitImportResult::changed_tags`].
    pub changed_tags: Vec<crate::GitRefUpdate>,
    /// How many commits the import rewrote (the CLI's `Updated {n} rewritten commits.`),
    /// saturating at `u32::MAX`; as [`crate::GitImportResult::num_rewritten`].
    pub num_rewritten: u32,
}

/// The remotes `args` selects (`fetch.rs:142-172` @ v0.46.0), before any transaction. The
/// remote expression is built BEFORE the remotes are listed, in the CLI's order: a malformed
/// `git.fetch` refuses as `Config` even without a Git backend, and `--remote` / `--all-remotes`
/// never read it.
fn resolve_fetch_remotes(
    store: &jj_lib::store::Store,
    remotes: &FetchRemotes,
    ctx: &mut VerbContext,
    hints: &mut Vec<String>,
) -> Result<Vec<RemoteNameBuf>, MutateError> {
    let defaults = crate::push::FETCH_REMOTES;
    // `(given, configured)`: `given` is the `--remote` / `--all-remotes` expression; without it,
    // `configured` is `git.fetch`'s, and `default_remotes` falls back on the remote list.
    let (given, configured) = match remotes {
        FetchRemotes::All => (Some(StringExpression::all()), None),
        FetchRemotes::Named(texts) => (Some(crate::bookmark_ops::union_expression(texts)?), None),
        FetchRemotes::Default => (None, crate::push::configured_remotes(&ctx.config, defaults)?),
    };
    let all_remotes = git::get_all_remote_names(store).map_err(|_| MutateError::NotAGitRepo)?;
    let matching = match given {
        Some(expression) => {
            crate::push::matching_remotes(&all_remotes, &expression, defaults.unmatched, &mut ctx.warnings)
        }
        None => crate::push::default_remotes(&all_remotes, configured, defaults, &mut ctx.warnings, hints),
    };
    if matching.is_empty() {
        return Err(MutateError::invalid("No git remotes to fetch from".to_owned()));
    }
    Ok(matching)
}

/// The default bookmark and tag expressions of one remote (`fetch.rs:209-229` @ v0.46.0) —
/// shared by the fetch and the remote-change poll (Story 9.30): `remotes.<name>.fetch-bookmarks`,
/// else the Git config's fetch refspecs (each refspec jj ignores goes to `ignored`), and
/// `remotes.<name>.fetch-tags`, else every tag. `bookmarks` / `tags` override either part (the
/// CLI's `-b` / `-t`); an overridden part reads nothing.
///
/// # Errors
///
/// - [`MutateError::Config`] — a `remotes.<name>` entry, or the field read, is malformed.
/// - [`MutateError::InvalidInput`] — the Git config of the remote does not read (jj-lib's
///   `GitDefaultRefspecError`, a CLI `user_error`).
pub(crate) fn remote_fetch_refs(
    config: &StackedConfig,
    git_repo: &gix::Repository,
    remote: &RemoteName,
    overrides: (Option<&StringExpression>, Option<&StringExpression>),
    ignored: &mut Vec<IgnoredRefspec>,
) -> Result<GitFetchRefExpression, MutateError> {
    let (bookmarks, tags) = overrides;
    let bookmark = if let Some(expression) = bookmarks {
        expression.clone()
    } else if let Some(expression) =
        crate::config::remote_fetch_expression(config, remote, FetchField::Bookmarks).map_err(mutate::cfg)?
    {
        expression
    } else {
        let (IgnoredRefspecs(refspecs), expression) =
            git::load_default_fetch_bookmarks(remote, git_repo).map_err(invalid)?;
        ignored.extend(refspecs);
        expression
    };
    let tag = if let Some(expression) = tags {
        expression.clone()
    } else if let Some(expression) =
        crate::config::remote_fetch_expression(config, remote, FetchField::Tags).map_err(mutate::cfg)?
    {
        expression
    } else {
        StringExpression::all()
    };
    Ok(GitFetchRefExpression { bookmark, tag })
}

/// A jj-lib error the CLI turns into a `user_error` with its Display. `pub(crate)` for the poll,
/// which refuses what the fetch refuses (Story 9.30).
pub(crate) fn invalid<E: std::fmt::Display>(e: E) -> MutateError {
    MutateError::invalid(e.to_string())
}

/// The CLI's hint for a remote name jj reserves or refuses (`GitFetchError::RemoteName`,
/// `cli/src/command_error.rs:587-588` @ v0.46.0).
pub(crate) const REMOTE_RENAME_HINT: &str = "Run `jj git remote rename` to give a different name.";

/// The CLI's hint for a ref expression that cannot become refspecs
/// (`GitRefExpansionError::Expression`, `cli/src/command_error.rs:604-609` @ v0.46.0).
pub(crate) const REFSPEC_PATTERN_HINT: &str = "Specify patterns in `(positive | ...) & ~(negative | ...)` form.";

/// The CLI's hints for a failed `expand_fetch_refspecs` (`From<GitRefExpansionError>`): the
/// pattern hint for `Expression`, none for `InvalidBranchPattern`.
pub(crate) fn expansion_hints(e: &GitRefExpansionError) -> Vec<String> {
    match e {
        GitRefExpansionError::Expression(_) => vec![REFSPEC_PATTERN_HINT.to_owned()],
        GitRefExpansionError::InvalidBranchPattern(_) => Vec::new(),
    }
}

/// A failed `expand_fetch_refspecs` as the fetch and the remote-change poll refuse it: invalid
/// input, carrying the CLI's hints.
pub(crate) fn expansion_error(e: &GitRefExpansionError) -> MutateError {
    MutateError::InvalidInput {
        reason: e.to_string(),
        hints: expansion_hints(e),
    }
}

/// `--tracked`'s refs of one remote (`fetch.rs:187-206` @ v0.46.0): the exact-name unions of the
/// bookmarks and tags tracked from it.
fn tracked_fetch_refs(view: &jj_lib::view::View, remote: &RemoteName) -> GitFetchRefExpression {
    let tracked = |refs: Vec<(&jj_lib::ref_name::RefName, LocalAndRemoteRef<'_>)>| {
        StringExpression::union_all(
            refs.into_iter()
                .filter(|(_, targets)| targets.remote_ref.is_tracked())
                .map(|(name, _)| StringExpression::exact(name.as_str()))
                .collect(),
        )
    };
    GitFetchRefExpression {
        bookmark: tracked(view.local_remote_bookmarks(remote).collect()),
        tag: tracked(view.local_remote_tags(remote).collect()),
    }
}

/// `warn_ignored_refspecs` (`fetch.rs:323-337` @ v0.46.0): one warning per refspec.
fn warn_ignored_refspecs(sink: &mut Warnings, remote: &RemoteName, ignored: Vec<IgnoredRefspec>) {
    for IgnoredRefspec { refspec, reason } in ignored {
        sink.push(
            WarningKind::FetchRefspecIgnored,
            format!("Ignored refspec `{refspec}` from `{}`: {reason}", remote.as_symbol()),
        );
    }
}

/// The fetch's `-b`/`-t` expressions: `None` each without `Patterns` (the CLI's `specific`
/// group), else the union of the list (`StringExpression::none()` for an empty one).
fn specific_expressions(refs: &FetchRefs) -> Result<(Option<StringExpression>, Option<StringExpression>), MutateError> {
    match refs {
        FetchRefs::Patterns { branches, tags } => Ok((
            Some(crate::bookmark_ops::union_expression(branches)?),
            Some(crate::bookmark_ops::union_expression(tags)?),
        )),
        FetchRefs::Default | FetchRefs::Tracked => Ok((None, None)),
    }
}

/// `warn_if_branches_not_found` (`fetch.rs:292-321` @ v0.46.0): the exact branch names the
/// matcher accepts that no matched remote has, in the transaction's view or its base.
fn warn_if_branches_not_found(
    sink: &mut Warnings,
    tx: &Transaction,
    expression: &StringExpression,
    remotes: &[RemoteNameBuf],
) {
    let matcher = expression.to_matcher();
    let missing: Vec<String> = expression
        .exact_strings()
        .filter(|name| matcher.is_match(name))
        .map(RefName::new)
        .filter(|name| {
            remotes.iter().all(|remote| {
                let symbol = name.to_remote_symbol(remote);
                tx.repo().view().get_remote_bookmark(symbol).is_absent()
                    && tx.base_repo().view().get_remote_bookmark(symbol).is_absent()
            })
        })
        .map(|name| name.as_symbol().to_string())
        .collect();
    if !missing.is_empty() {
        sink.push(
            WarningKind::FetchBranchesUnmatched,
            format!(
                "No matching branches found on any specified/configured remote: {}",
                missing.join(", ")
            ),
        );
    }
}

/// The operation description (`fetch.rs:255-258` @ v0.46.0): every matched remote as its symbol,
/// joined by `","`.
fn fetch_description(remotes: &[RemoteNameBuf]) -> String {
    let names: Vec<String> = remotes.iter().map(|r| r.as_symbol().to_string()).collect();
    format!("fetch from git remote(s) {}", names.join(","))
}

/// Maps one remote's `GitFetch::fetch` failure — exhaustive, in the CLI's classification
/// (`From<GitFetchError>`, `cli/src/command_error.rs:583-593` @ v0.46.0): every variant is a
/// `user_error`; `RemoteName` carries the CLI's hint (Story 9.56).
fn fetch_error(e: GitFetchError, cancel: Option<&crate::cancel::CancelGuard>) -> MutateError {
    match e {
        GitFetchError::NoSuchRemote(name) => MutateError::RemoteNotFound {
            name: name.into_string(),
        },
        GitFetchError::RemoteName(e) => MutateError::invalid_hinted(e.to_string(), REMOTE_RENAME_HINT),
        rejected @ GitFetchError::RejectedUpdates(_) => invalid(rejected),
        GitFetchError::Subprocess(_) if crate::cancel::is_cancelled(cancel) => MutateError::Cancelled,
        GitFetchError::Subprocess(sub) => MutateError::NetworkError {
            reason: sub.to_string(),
        },
    }
}

/// `jj git fetch` (FR-JJ-13, Story 9.30) — see [`crate::Repo::git_fetch`] for the contract. A port
/// of `cmd_git_fetch` (`cli/src/commands/git/fetch.rs:135-264` @ v0.46.0), in its order.
///
/// Shares its progress forwarding ([`ProgressCallback`]) with [`crate::Repo::clone`]'s fetch
/// step (Story 9.20), which reports as `"clone"` where this reports as `"fetch"`. The
/// transaction finishes through [`mutate::finish_verb`] like the CLI's `tx.finish` (Story 9.26).
///
/// # Errors
///
/// See [`crate::Repo::git_fetch`].
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn git_fetch(
    workspace: &mut Workspace,
    settings: &UserSettings,
    args: &GitFetchArgs,
    ctx: &mut VerbContext,
    progress: &ProgressFn,
    cancel: Option<&crate::cancel::CancelGuard>,
) -> Result<GitFetchOutcome, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let mut hints = Vec::new();
    let remotes = resolve_fetch_remotes(readonly.store(), &args.remotes, ctx, &mut hints)?;

    let mut tx = start_repo_transaction(&readonly, workspace.workspace_name());
    // WHY read and discard: the CLI's `tx.settings().remote_settings()?` (`fetch.rs:174`) reads
    // every `remotes.<name>` entry right after the transaction starts, so a malformed one refuses
    // whatever `args` select — `--tracked` included.
    crate::config::every_remote_settings(&ctx.config).map_err(mutate::cfg)?;
    let (common_bookmarks, common_tags) = specific_expressions(&args.refs)?;
    let mut expansions = Vec::with_capacity(remotes.len());
    if args.refs == FetchRefs::Tracked {
        for remote in &remotes {
            let expression = tracked_fetch_refs(tx.repo().view(), remote);
            expansions.push(expand_fetch_refspecs(remote, expression).map_err(|e| expansion_error(&e))?);
        }
    } else {
        let git_repo = git::get_git_repo(tx.repo().store()).map_err(|_| MutateError::NotAGitRepo)?;
        for remote in &remotes {
            let mut ignored = Vec::new();
            let expression = remote_fetch_refs(
                &ctx.config,
                &git_repo,
                remote,
                (common_bookmarks.as_ref(), common_tags.as_ref()),
                &mut ignored,
            );
            // The CLI warns them as soon as the refspecs load, before it parses `fetch-tags`.
            warn_ignored_refspecs(&mut ctx.warnings, remote, ignored);
            let expression = expression?;
            expansions.push(expand_fetch_refspecs(remote, expression).map_err(|e| expansion_error(&e))?);
        }
    }

    let import_options = crate::config::git_import_options(&ctx.config).map_err(mutate::cfg)?;
    let subprocess_options = crate::environment::git_subprocess_options(settings, cancel).map_err(mutate::be)?;
    // WHY: `GitFetch::new`'s error type IS `UnexpectedGitBackendError` (jj-lib 0.46.0) —
    // `get_git_backend` is its only fallible step — so the blanket `map_err` swallows nothing
    // else. The explicit parameter type is the GUARD for that premise: a jj-lib bump that widens
    // the error surface stops compiling here instead of silently reporting unrelated faults as
    // `jj.not_a_git_repo`.
    crate::cancel::watch_store(cancel, tx.repo().store());
    let mut fetcher = GitFetch::new(tx.repo_mut(), subprocess_options, &import_options)
        .map_err(|_e: UnexpectedGitBackendError| MutateError::NotAGitRepo)?;

    let mut callback = ProgressCallback {
        operation: "fetch",
        progress,
    };
    // WHY: `depth: None` = a full (non-shallow) fetch, as the CLI's `fetch(.., None)`.
    let depth = None;
    // Story 9.52's checkpoints: before each remote's git work, and after the last but before the
    // import, so a cancelled fetch records nothing. A git that failed after the cancel killed it
    // is the cancel.
    for (remote, refspecs) in remotes.iter().zip(expansions) {
        crate::cancel::checkpoint(cancel)?;
        fetcher
            .fetch(remote, refspecs, &mut callback, depth)
            .map_err(|e| fetch_error(e, cancel))?;
    }
    crate::cancel::checkpoint(cancel)?;

    let stats = pollster::block_on(fetcher.import_refs()).map_err(mutate::be)?;
    // `print_git_import_stats`, right after the import (`fetch.rs:247-248`, Story 9.32).
    ctx.warnings.extend(crate::warning::git_import_failed(&stats));
    if let Some(expression) = &common_bookmarks {
        warn_if_branches_not_found(&mut ctx.warnings, &tx, expression, &remotes);
    }

    // `import_refs` calls `record_abandoned_commit` (jj-lib `git.rs`), which populates
    // `parent_mapping`; the shared finish rebases those descendants — the CLI's own `tx.finish`
    // step, `rebase_mutable_descendants` — against the immutable set of `tx.base_repo()`.
    let finish = mutate::finish_verb(workspace, tx, &fetch_description(&remotes), ctx)?;
    // WHY `new_change_ids` empty: `GitImportStats` has no minted-change concept at all — it
    // reports abandonments, changed remote refs, rewritten commit ids and failed ref names.
    // `git_import` leaves this field empty for the same reason. When `@` itself was abandoned,
    // jj-lib's replacement is already reported via `working_copy_change_id`.
    let mutation = mutate::mutation_result(&finish, Vec::new(), crate::git::project_abandoned(&stats));
    let import = crate::git::project_import(&stats, &finish.repo, finish.committed, mutation);
    Ok(GitFetchOutcome {
        mutation: import.mutation,
        remotes: remotes.into_iter().map(RemoteNameBuf::into_string).collect(),
        hints,
        failed_ref_names: import.failed_ref_names,
        changed_bookmarks: import.changed_bookmarks,
        changed_tags: import.changed_tags,
        num_rewritten: import.num_rewritten,
    })
}

#[cfg(test)]
mod tests {
    use jj_lib::git::GitSubprocessCallback as _;

    use super::{fetch_description, list_remotes, ProgressCallback, ProgressEvent, RemoteError};

    /// Story 9.56: an `Expression` failure carries the CLI's pattern hint, an
    /// `InvalidBranchPattern` none (`command_error.rs:604-609` @ v0.46.0).
    #[test]
    fn only_an_expression_failure_carries_the_pattern_hint() {
        use jj_lib::git::{GitRefExpansionError, GitRefExpressionError};
        use jj_lib::str_util::StringPattern;

        let e = super::expansion_error(&GitRefExpansionError::Expression(
            GitRefExpressionError::PositiveIntersection,
        ));
        assert_eq!(
            e.hints(),
            ["Specify patterns in `(positive | ...) & ~(negative | ...)` form."]
        );
        let e = super::expansion_error(&GitRefExpansionError::InvalidBranchPattern(StringPattern::exact("a?b")));
        assert!(e.hints().is_empty(), "{e:?}");
    }

    /// The description quotes a remote whose name is no plain revset symbol, as the CLI's
    /// `as_symbol` does, and joins several with `","` (Story 9.30).
    #[test]
    fn the_fetch_description_quotes_each_remote_as_a_symbol() {
        use jj_lib::ref_name::RemoteNameBuf;
        let remotes: Vec<RemoteNameBuf> = ["origin", "my remote", "up"].map(Into::into).into();
        assert_eq!(
            fetch_description(&remotes),
            "fetch from git remote(s) origin,\"my remote\",up"
        );
        assert_eq!(fetch_description(&remotes[..1]), "fetch from git remote(s) origin");
    }

    /// A remote gone before its fetch is `RemoteNotFound`; a rejected ref update and a remote
    /// name jj cannot use are `InvalidInput` carrying jj-lib's Display — the CLI's `user_error`s
    /// (`command_error.rs:583-593` @ v0.46.0), the latter with the CLI's hint. `NoSuchRemote` is
    /// not reachable through a fetch fixture (the remotes are resolved from the store just
    /// before), and `RejectedUpdates` hardly is (jj-lib force-updates remote refs; its own note
    /// names implicit tag updates as the one exception), so the mapping is called directly. The
    /// `RemoteName` refusal through a real fetch is pinned in `tests/it/git_fetch_parity.rs`.
    #[test]
    fn fetch_failures_map_to_their_mutate_errors() {
        use super::fetch_error;
        use crate::MutateError;
        use jj_lib::git::{GitFetchError, GitRemoteNameError};

        let gone = fetch_error(GitFetchError::NoSuchRemote("gone".into()), None);
        assert!(
            matches!(&gone, MutateError::RemoteNotFound { name } if name == "gone"),
            "{gone:?}"
        );
        let rejected = fetch_error(GitFetchError::RejectedUpdates(vec!["refs/heads/main".into()]), None);
        assert!(
            matches!(&rejected, MutateError::InvalidInput { reason, hints }
                if reason.starts_with("Failed to update refs: ") && reason.contains("refs/heads/main")
                    && hints.is_empty()),
            "{rejected:?}"
        );
        let reserved = fetch_error(
            GitFetchError::RemoteName(GitRemoteNameError::ReservedForLocalGitRepo),
            None,
        );
        assert!(
            matches!(&reserved, MutateError::InvalidInput { reason, hints }
                if *reason == GitRemoteNameError::ReservedForLocalGitRepo.to_string()
                    && *hints == ["Run `jj git remote rename` to give a different name."]),
            "{reserved:?}"
        );
    }

    /// A head that no longer loads is this module's own `Backend` failure. Through
    /// [`crate::Repo`] the pre-verb snapshot (Story 9.26) hits it first, so the module function
    /// is called directly.
    #[test]
    fn a_head_that_no_longer_loads_is_a_backend_error() {
        let (_tmp, repo) = crate::test_support::repo_with_a_broken_head();
        let result = list_remotes(repo.workspace());
        assert!(matches!(result, Err(RemoteError::Backend(_))), "{result:?}");
    }

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
    /// instead, exercised by the integration tests in `tests/it/remotes_write.rs`), so
    /// it is exercised directly here.
    #[test]
    fn progress_callback_local_sideband_is_a_no_op() {
        let progress = |_: ProgressEvent| {};
        let mut callback = ProgressCallback {
            operation: "push",
            progress: &progress,
        };
        assert!(callback.local_sideband(b"some message", None).is_ok());
    }
}
