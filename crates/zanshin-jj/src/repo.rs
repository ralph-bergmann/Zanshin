// SPDX-License-Identifier: MIT

use std::io;
use std::ops::ControlFlow;
use std::path::{Path, PathBuf};

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::git::{
    expand_fetch_refspecs, GitFetch, GitFetchRefExpression, GitImportOptions, GitProgress, GitSidebandLineTerminator,
    GitSubprocessCallback, GitSubprocessOptions,
};
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::str_util::{StringExpression, StringPattern};
use jj_lib::workspace::Workspace;

/// Errors returned by [`Repo::open`], [`Repo::init`], [`Repo::clone`], and
/// [`crate::convert_colocated`].
#[derive(Debug, thiserror::Error)]
pub enum RepoError {
    /// The supplied path does not exist on the filesystem.
    #[error("path not found: {path}")]
    PathNotFound {
        /// The path that does not exist.
        path: PathBuf,
    },
    /// The path exists but is not a jj workspace (`.jj/` is absent).
    #[error("not a jj repository: {path}")]
    NotARepo {
        /// The path that lacks a `.jj/` directory.
        path: PathBuf,
    },
    /// jj workspace initialisation failed.
    #[error("init failed: {reason}")]
    InitFailed {
        /// Human-readable failure reason from jj-lib.
        reason: String,
    },
    /// jj workspace clone failed (init, remote registration, fetch, or import).
    #[error("clone failed: {reason}")]
    CloneFailed {
        /// Human-readable failure reason from jj-lib.
        reason: String,
    },
    /// The path is already a jj workspace (`.jj/` is present).
    #[error("already a jj repository: {path}")]
    AlreadyJjRepo {
        /// The path that is already a jj workspace.
        path: PathBuf,
    },
    /// The path is not a Git repository (no `.git/`), or does not exist.
    #[error("not a git repository: {path}")]
    NotAGitRepo {
        /// The path that is neither a Git repo nor exists.
        path: PathBuf,
    },
    /// Colocated conversion failed; the partially-created `.jj/` has been rolled back.
    #[error("convert failed: {reason}")]
    ConvertFailed {
        /// Human-readable failure reason from jj-lib or `detect_repo`.
        reason: String,
    },
    /// Underlying `jj_lib` failure, flattened to its Display so no `jj_lib` type escapes the public API.
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Selects the jj backend for a new workspace.
#[derive(Clone, Copy)]
pub enum Backend {
    /// Git-backed workspace (`init --git`).
    Git,
}

/// Handle to an open jj workspace (FR-JJ-16 adapter).
///
/// Created via [`Repo::open`], [`Repo::init`], or [`Repo::clone`]. The handle
/// is a warm `Workspace` loader that re-resolves to the operation-log head on
/// every call (ADR-0002) — it is not an authoritative state cache.
pub struct Repo {
    workspace: Workspace,
    settings: UserSettings,
}

impl std::fmt::Debug for Repo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Repo")
            .field("workspace_root", &self.workspace.workspace_root())
            .finish_non_exhaustive()
    }
}

impl Repo {
    /// Returns the workspace root path.
    #[must_use]
    pub fn workspace_root(&self) -> &Path {
        self.workspace.workspace_root()
    }

    /// Returns a reference to the underlying jj workspace (crate-internal use only).
    pub(crate) fn workspace(&self) -> &Workspace {
        &self.workspace
    }

    /// Returns a mutable reference to the underlying jj workspace (crate-internal use only).
    pub(crate) fn workspace_mut(&mut self) -> &mut Workspace {
        &mut self.workspace
    }

    /// Returns the user settings used to open this workspace (crate-internal use only).
    pub(crate) fn settings(&self) -> &UserSettings {
        &self.settings
    }

    /// Returns the working-copy status: files changed between `@` and `@-`.
    ///
    /// Re-resolves to head on every call (ADR-0002). Read-only — does not snapshot
    /// the working copy.
    ///
    /// # Errors
    ///
    /// Returns [`crate::StatusError::NoWorkingCopy`] if the workspace has no
    /// working-copy commit, or [`crate::StatusError::Backend`] on jj-lib failure.
    pub fn status(&self) -> Result<crate::Status, crate::StatusError> {
        crate::status::working_copy_status(&self.workspace)
    }

    /// Returns full metadata for the change identified by `id` (jj reverse-hex form).
    ///
    /// Re-resolves to head on every call (ADR-0002). Read-only.
    ///
    /// # Errors
    ///
    /// - [`crate::ChangeError::NotFound`] — `id` is malformed (not valid reverse-hex),
    ///   absent from the index, or only points to hidden/abandoned commits.
    /// - [`crate::ChangeError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn get_change(&self, id: &crate::ChangeId) -> Result<crate::Change, crate::ChangeError> {
        crate::change::get_change(&self.workspace, id)
    }

    /// Returns the operation log in reverse-chronological order (most-recent first, root op last).
    ///
    /// `limit = None` returns the full history; `Some(n)` returns at most the `n` most-recent
    /// operations. Re-resolves to the head operation per call (ADR-0002). Read-only; never shells
    /// to `jj op log` (AR-AP-1).
    ///
    /// # Errors
    ///
    /// - [`crate::OpLogError::Backend`] — `load_at_head` or the op-store walk failed; the
    ///   jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn op_log(&self, limit: Option<usize>) -> Result<Vec<crate::Operation>, crate::OpLogError> {
        crate::op_log::op_log(self.workspace(), limit)
    }

    /// Lists local + tracked-remote bookmarks, sorted by name then kind (FR-JJ-8).
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells
    /// to `jj bookmark list` (AR-AP-1). A conflicted target resolves to the first added
    /// commit's change id (listing scope only).
    ///
    /// # Errors
    ///
    /// - [`crate::BookmarkError::Backend`] — `load_at_head` or a store read failed; the
    ///   jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_bookmarks(&self) -> Result<Vec<crate::Bookmark>, crate::BookmarkError> {
        crate::bookmarks::list_bookmarks(self.workspace())
    }

    /// Lists configured git remotes with fetch URLs, sorted by name (FR-JJ-9).
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never
    /// shells to `jj git remote list` (AR-AP-1). A non-git (native) backend, or a
    /// git-backed repo with no remotes, yields `Ok(vec![])`.
    ///
    /// # Errors
    ///
    /// - [`crate::RemoteError::Backend`] — `load_at_head` failed; the jj-lib
    ///   reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_remotes(&self) -> Result<Vec<crate::Remote>, crate::RemoteError> {
        crate::remotes::list_remotes(self.workspace())
    }

    /// Returns the effective `jj log` defaults of this repo (Story 4.9): the values the
    /// user's own `jj` CLI would apply for `revsets.log`, `revsets.log-graph-prioritize`,
    /// `revsets.short-prefixes` and `ui.log-synthetic-elided-nodes`.
    ///
    /// The config stack is re-read on every call and never cached — config files change
    /// externally and the op-heads watcher does not cover them. Read-only: nothing is
    /// created, migrated or symlinked.
    ///
    /// These are *offers*, not policy: [`Repo::walk_graph`]'s parameters stay caller
    /// pass-throughs (FR-JJ-17), so the UI pre-fills these values and the user edits them.
    /// `short_prefixes` falls back to `log` when the key is absent from every layer; an
    /// explicit empty string means "disambiguation disabled" and is returned verbatim.
    ///
    /// # Errors
    ///
    /// - [`crate::ConfigError::Load`] — a config file is unreadable or not valid TOML, a
    ///   `config-id` is malformed, or one of the four values has the wrong type. Never a
    ///   silent fall-back to the builtin defaults.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn log_defaults(&self) -> Result<crate::LogDefaults, crate::ConfigError> {
        crate::config::log_defaults(&crate::config::load(self)?)
    }

    /// Streams the commit graph of `revset` — one [`crate::GraphNode`] per commit, children
    /// before parents — through `visit`, in the order `jj log -r <revset>` prints it with
    /// `revsets.log-graph-prioritize = <prioritize>` (NFR-R-2, ADR-0003).
    ///
    /// Every node also carries its [`crate::CommitMeta`] — the `jj log`-parity display
    /// metadata — extracted from the SAME head-resolved snapshot in the same pass (Story
    /// 4.8), so a row's lanes and its content can never disagree.
    ///
    /// All three expressions are caller pass-throughs (FR-JJ-17);
    /// [`crate::DEFAULT_GRAPH_PRIORITIZE`] is the CLI's default for `prioritize` and
    /// [`crate::DEFAULT_LOG_REVSET`] the CLI's default for `revset` / `short_prefixes`
    /// (the repo's *effective* values are [`Repo::log_defaults`]). Aliases are resolved
    /// from the repo's effective jj config, builtin defaults included — a user's
    /// `[revset-aliases]` override of `trunk()` or `immutable_heads()` changes the row set
    /// and the per-row `immutable` flag exactly as it does in their CLI (Story 4.9). The
    /// config is re-read per call and never cached.
    /// Re-resolves to the head operation per call (ADR-0002); nothing is retained across
    /// calls. The stream is lazy: `visit` returning `ControlFlow::Break` stops it early, and
    /// the result is `Ok(Break)`; `Ok(Continue)` means the stream was exhausted. Read-only;
    /// never shells to `jj log` (AR-AP-1).
    ///
    /// `"none()"` is the canonical "no prioritization" value; an empty/blank `prioritize` is a
    /// [`crate::RevsetError::ParseError`], as the CLI fails on an empty config value. An EMPTY
    /// `short_prefixes` instead DISABLES prefix disambiguation (full-index prefix lengths) —
    /// the CLI's `revsets.short-prefixes` toggle semantic. The
    /// prioritized set (`prioritize ∩ revset`) is materialized before streaming — keep it small
    /// (the CLI default `present(@)` is one commit; `all()` would materialize every id). The
    /// `jj log` order parity holds for the CLI's graph mode without `--reversed`/`--limit`
    /// (paging/presentation concerns). Nodes already handed to `visit` before an `Err` are not
    /// retracted — discard partial output on `Err`. No internal locking: callers serialize
    /// access (single worker isolate, AD-2).
    ///
    /// # Errors
    ///
    /// - [`crate::RevsetError::ParseError`] — any expression is syntactically invalid.
    /// - [`crate::RevsetError::ResolutionError`] — a symbol in `revset` or `prioritize`
    ///   cannot be resolved. An unresolvable `short_prefixes` is NOT an error: like the
    ///   CLI, it warns and degrades to full-index prefix lengths.
    /// - [`crate::RevsetError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable. A single bad `[revset-aliases]` entry is NOT an error: like the CLI, it
    ///   warns and is skipped.
    /// - [`crate::RevsetError::JjLibError`] — `load_at_head`, evaluation, metadata
    ///   extraction, or a per-item stream failure; the jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn walk_graph(
        &self,
        revset: &str,
        prioritize: &str,
        short_prefixes: &str,
        visit: impl FnMut(crate::GraphNode) -> ControlFlow<()>,
    ) -> Result<ControlFlow<()>, crate::RevsetError> {
        crate::graph::walk_graph(self, revset, prioritize, short_prefixes, visit)
    }

    /// Rewrites `change_id`'s description to `description` (FR-JJ-10a).
    ///
    /// Opens a jj-lib transaction, mutates via `tx.repo_mut()`, and commits with a
    /// CLI-parity op-log description (NFR-R-2) — jj-lib only, never shells to `jj`
    /// (AR-AP-1). `description` may be empty (jj convention).
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::ChangeNotFound`] — `change_id` is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::InvalidInput`] — `change_id` resolves to the root commit.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: signature (owned `ChangeId`) is fixed by epics.md Story 6.1 / AC-1; the
    // implementation only needs to borrow it, but the public API takes ownership.
    #[allow(clippy::needless_pass_by_value)]
    pub fn describe(
        &mut self,
        change_id: crate::ChangeId,
        description: &str,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        crate::mutate::describe(self.workspace_mut(), &change_id, description)
    }

    /// Creates a new, empty change on top of `parents` (FR-JJ-10a) — a merge commit
    /// when `parents.len() > 1` — and switches the working copy to it.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `parents` is empty.
    /// - [`crate::MutateError::ChangeNotFound`] — a parent id is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn new_change(&mut self, parents: &[crate::ChangeId]) -> Result<crate::MutationResult, crate::MutateError> {
        crate::mutate::new_change(self.workspace_mut(), parents)
    }

    /// Switches the working copy to `change_id` without creating a new commit
    /// (FR-JJ-10a).
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::ChangeNotFound`] — `change_id` is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: signature (owned `ChangeId`) is fixed by epics.md Story 6.1 / AC-1; the
    // implementation only needs to borrow it, but the public API takes ownership.
    #[allow(clippy::needless_pass_by_value)]
    pub fn edit(&mut self, change_id: crate::ChangeId) -> Result<crate::MutationResult, crate::MutateError> {
        crate::mutate::edit(self.workspace_mut(), &change_id)
    }

    /// Abandons `change_ids`, rebasing descendants onto their parents and deleting any
    /// bookmarks that pointed only at the abandoned commits (FR-JJ-10a). If `@` itself
    /// is among `change_ids`, jj-lib creates a fresh empty commit at the (merged)
    /// parent(s) and repoints the working copy at it automatically — its change id is
    /// reported in the result's `new_change_ids`.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `change_ids` is empty, or resolves the
    ///   root commit.
    /// - [`crate::MutateError::ChangeNotFound`] — a target id is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn abandon(&mut self, change_ids: &[crate::ChangeId]) -> Result<crate::MutationResult, crate::MutateError> {
        crate::mutate::abandon(self.workspace_mut(), change_ids)
    }

    /// Reverts the last operation, one step back from the current head (FR-JJ-14a).
    ///
    /// Mirrors the CLI's `jj undo`: restores the head operation's single parent's repo
    /// state + local bookmarks/tags + remote-tracking bookmarks (leaving `git_refs`/
    /// `git_head` untouched) onto a freshly-committed op. Calling `undo()` twice in a
    /// row redoes the first `undo()`.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::NothingToUndo`] — the head operation IS the op-store root
    ///   (no parent to restore to).
    /// - [`crate::MutateError::InvalidInput`] — the head operation has more than one
    ///   parent (a divergent-write merge op) — undoing a merge operation is refused.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn undo(&mut self) -> Result<crate::MutationResult, crate::MutateError> {
        crate::op_log::undo(self.workspace_mut())
    }

    /// Fetches all branches and tags from `remote_name` and imports them (FR-JJ-13).
    ///
    /// Always fetches ALL branches and tags — there is no branch/tag filter
    /// parameter (unlike the CLI's `jj git fetch -b`/`--branch`). Mirrors
    /// [`Repo::clone`]'s own fetch step, but forwards real progress via `progress`
    /// instead of discarding it, and never moves `@` — fetch only updates
    /// remote-tracking refs. A fresh operation is committed even when nothing changed
    /// (CLI parity).
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::RemoteNotFound`] — `remote_name` has no configured git
    ///   remote, or the repo has no git backend at all.
    /// - [`crate::MutateError::NetworkError`] — the underlying `git` subprocess
    ///   failed.
    /// - [`crate::MutateError::Backend`] — any other underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_fetch(
        &mut self,
        remote_name: &str,
        progress: &crate::ProgressFn,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        crate::remotes::git_fetch(self.workspace(), self.settings(), remote_name, progress)
    }

    /// Opens an existing jj workspace rooted at `path`.
    ///
    /// # Errors
    ///
    /// Returns [`RepoError::PathNotFound`] if `path` does not exist,
    /// [`RepoError::NotARepo`] if `.jj` is absent, or [`RepoError::Backend`] on jj-lib failure.
    pub fn open(path: &Path) -> Result<Self, RepoError> {
        if !path.exists() {
            return Err(RepoError::PathNotFound { path: path.to_owned() });
        }
        if !path.join(".jj").is_dir() {
            return Err(RepoError::NotARepo { path: path.to_owned() });
        }
        let settings = make_settings()?;
        let workspace = Workspace::load(
            &settings,
            path,
            &default_backend_factories(),
            &default_working_copy_factories(),
        )
        .map_err(|e| RepoError::Backend(e.to_string()))?;
        Ok(Self { workspace, settings })
    }

    /// Initialises a new jj workspace at `path`.
    ///
    /// `backend = Some(Backend::Git)` creates a git-backed workspace;
    /// `backend = None` uses jj's native backend.
    ///
    /// # Errors
    ///
    /// Returns [`RepoError::InitFailed`] on jj-lib workspace initialisation failure.
    pub fn init(path: &Path, backend: Option<Backend>) -> Result<Self, RepoError> {
        let settings = make_settings()?;
        let (workspace, _repo) = match backend {
            // WHY: `object_hash` is jj 0.44's new parameter. jj's CLI resolves it from the
            // `git.object-hash` config, whose builtin default is "sha1" — passing `Sha1` here
            // mirrors that default and reproduces pre-0.44 behaviour exactly. Exposing it as a
            // caller parameter (FR-JJ-17) belongs to Story 9.20 (`git init`/`git clone`), not to
            // this pin bump.
            Some(Backend::Git) => {
                pollster::block_on(Workspace::init_internal_git(&settings, path, gix::hash::Kind::Sha1))
                    .map_err(|e| RepoError::InitFailed { reason: e.to_string() })?
            }
            None => pollster::block_on(Workspace::init_simple(&settings, path))
                .map_err(|e| RepoError::InitFailed { reason: e.to_string() })?,
        };
        Ok(Self { workspace, settings })
    }

    /// Clones a remote Git repository into a new jj workspace at `target_path`.
    ///
    /// Composes: `init_internal_git` → `add_remote("origin")` → `GitFetch::fetch` → `import_refs`,
    /// then points the working copy at the fetched default branch (a fresh `@` commit on its tip).
    ///
    /// On failure, any partial workspace created under `target_path` is rolled back so a
    /// retry into the same path starts clean.
    ///
    /// # Errors
    ///
    /// Returns [`RepoError::CloneFailed`] if init, remote registration, fetch, or import fails.
    pub fn clone(url: &str, target_path: &Path) -> Result<Self, RepoError> {
        let settings = make_settings()?;
        let created_dir = !target_path.exists();

        match Self::clone_into(&settings, url, target_path) {
            Ok(workspace) => Ok(Self { workspace, settings }),
            Err(e) => {
                // Roll back only what clone created: the whole dir if we created it,
                // otherwise just the `.jj/` that init_internal_git wrote.
                if created_dir {
                    let _ = std::fs::remove_dir_all(target_path);
                } else {
                    let _ = std::fs::remove_dir_all(target_path.join(".jj"));
                }
                Err(e)
            }
        }
    }

    /// Composes the clone steps, returning the workspace reloaded at the committed head.
    fn clone_into(settings: &UserSettings, url: &str, target_path: &Path) -> Result<Workspace, RepoError> {
        // Step 1: Create git-backed jj workspace.
        // WHY: `gix::hash::Kind::Sha1` mirrors jj's own `git.object-hash` default (see
        // `Repo::init`); making it a caller parameter is Story 9.20's scope.
        let (_workspace_init, repo) = pollster::block_on(Workspace::init_internal_git(
            settings,
            target_path,
            gix::hash::Kind::Sha1,
        ))
        .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        let remote_name_buf: RemoteNameBuf = "origin".into();
        let remote_name: &RemoteName = &remote_name_buf;

        // Step 2: Write remote to disk via a throwaway transaction.
        // add_remote calls save_git_config() which writes to disk immediately but
        // does NOT update the gix::ThreadSafeRepository's in-memory config cache.
        // We therefore drop this transaction without committing — its only purpose
        // is the disk side-effect. Step 3 reloads from disk to pick it up.
        {
            let mut tx = repo.start_transaction();
            // WHY: jj 0.44 dropped `add_remote`'s trailing `fetch_tags` argument — tag selection
            // is now driven purely by the fetch refspec, which `fetch_expr` below already sets to
            // glob("*"), i.e. the same "all tags" behaviour the old `Tags::All` requested.
            jj_lib::git::add_remote(tx.repo_mut(), remote_name, url, None)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            // tx is intentionally dropped without commit.
        }

        // Step 3: Reload workspace so Workspace::load constructs a fresh Store /
        // GitBackend that reads the git config from disk (now containing "origin").
        let mut workspace = Workspace::load(
            settings,
            target_path,
            &default_backend_factories(),
            &default_working_copy_factories(),
        )
        .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
        let workspace_name = workspace.workspace_name().to_owned();

        let fresh_repo = pollster::block_on(workspace.repo_loader().load_at_head())
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        // Step 4: Fetch + import refs using the fresh repo whose GitBackend sees "origin".
        let subprocess_options = GitSubprocessOptions::from_settings(settings)
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        let import_options = GitImportOptions {
            record_synthetic_predecessors: false,
            abandon_unreachable_commits: true,
            remote_auto_track_bookmarks: std::collections::HashMap::new(),
        };

        let fetch_expr = GitFetchRefExpression {
            bookmark: StringExpression::Pattern(Box::new(
                // WHY: glob("*") selects all remote branches for a full clone.
                StringPattern::glob("*").map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?,
            )),
            tag: StringExpression::Pattern(Box::new(
                // WHY: glob("*") selects all remote tags for a full clone.
                StringPattern::glob("*").map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?,
            )),
        };
        let refspecs = expand_fetch_refspecs(remote_name, fetch_expr)
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        let import_stats;
        let default_branch;
        let mut tx = fresh_repo.start_transaction();
        {
            let mut_repo = tx.repo_mut();
            let mut fetcher = GitFetch::new(mut_repo, subprocess_options, &import_options)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            // TODO(FR-JJ-13, Epic 6 Story 6.4a): wire NativeCallable progress callback
            // WHY: `depth: None` = a full (non-shallow) clone. jj 0.44 dropped `fetch`'s
            // trailing `fetch_tags_override`, so the 0.42 call's second `None` is the one that
            // went away — the remaining one is `depth`, unchanged.
            let depth = None;
            fetcher
                .fetch(remote_name, refspecs, &mut NoopCallback, depth)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            import_stats = pollster::block_on(fetcher.import_refs())
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            default_branch = fetcher
                .get_default_branch(remote_name)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
        }

        // Point `@` at the fetched default branch: create a fresh working-copy commit
        // on its tip so the cloned workspace shows the default branch's files.
        let target_commit_id = default_branch.as_ref().and_then(|branch| {
            import_stats.changed_remote_bookmarks.iter().find_map(|update| {
                if &update.symbol.name == branch && update.symbol.remote == remote_name_buf {
                    update.new_target.as_normal()
                } else {
                    None
                }
            })
        });

        let new_wc_commit = match target_commit_id {
            Some(commit_id) => {
                let mut_repo = tx.repo_mut();
                let commit = mut_repo
                    .store()
                    .get_commit(commit_id)
                    .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
                let wc_commit = pollster::block_on(mut_repo.check_out(workspace_name.clone(), &commit))
                    .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
                // check_out rewrites the working-copy commit; jj requires descendants to be
                // rebased before the transaction can commit.
                pollster::block_on(mut_repo.rebase_descendants())
                    .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
                Some(wc_commit)
            }
            None => None,
        };

        let new_repo =
            pollster::block_on(tx.commit("clone")).map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        // Materialise the working copy on disk to match the new `@` commit.
        if let Some(wc_commit) = &new_wc_commit {
            pollster::block_on(workspace.check_out(new_repo.op_id().clone(), None, wc_commit))
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
        }

        // Reload so the returned handle reflects the committed clone + checked-out working copy.
        let workspace = Workspace::load(
            settings,
            target_path,
            &default_backend_factories(),
            &default_working_copy_factories(),
        )
        .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        Ok(workspace)
    }
}

/// No-op subprocess callback — discards all progress and sideband output.
/// Replaced by a `NativeCallable` in Epic 6 Story 6.4a (FR-JJ-13).
struct NoopCallback;

impl GitSubprocessCallback for NoopCallback {
    fn needs_progress(&self) -> bool {
        false
    }

    fn progress(&mut self, _progress: &GitProgress) -> io::Result<()> {
        Ok(())
    }

    fn local_sideband(&mut self, _message: &[u8], _term: Option<GitSidebandLineTerminator>) -> io::Result<()> {
        Ok(())
    }

    fn remote_sideband(&mut self, _message: &[u8], _term: Option<GitSidebandLineTerminator>) -> io::Result<()> {
        Ok(())
    }
}

pub(crate) fn make_settings() -> Result<UserSettings, RepoError> {
    let mut config = StackedConfig::with_defaults();
    config.add_layer(
        ConfigLayer::parse(
            ConfigSource::User,
            r#"
                    [user]
                    name = "Zanshin"
                    email = "zanshin@localhost"
                    [operation]
                    username = "zanshin"
                    hostname = "localhost"
                "#,
        )
        .map_err(|e| RepoError::Backend(e.to_string()))?,
    );
    UserSettings::from_config(config).map_err(|e| RepoError::Backend(e.to_string()))
}
