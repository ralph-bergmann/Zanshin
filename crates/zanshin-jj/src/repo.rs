// SPDX-License-Identifier: MIT

use std::io;
use std::ops::ControlFlow;
use std::path::{Path, PathBuf};

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::git::{
    expand_fetch_refspecs, GitFetch, GitFetchRefExpression, GitImportOptions, GitProgress, GitSidebandLineTerminator,
    GitSubprocessCallback, GitSubprocessOptions,
};
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::repo::{Repo as _, StoreFactories};
use jj_lib::settings::UserSettings;
use jj_lib::str_util::{StringExpression, StringPattern};
use jj_lib::workspace::{default_working_copy_factories, Workspace};

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

    /// Streams the commit graph of `revset` — one [`crate::GraphNode`] per commit, children
    /// before parents — through `visit`, in the order `jj log -r <revset>` prints it with
    /// `revsets.log-graph-prioritize = <prioritize>` (NFR-R-2, ADR-0003).
    ///
    /// Both expressions are caller pass-throughs (FR-JJ-17); [`crate::DEFAULT_GRAPH_PRIORITIZE`]
    /// is the CLI's default for `prioritize`. Only the `trunk()` alias is defined — other CLI
    /// aliases (`immutable_heads()`, …) fail to parse. Re-resolves to the head operation per
    /// call (ADR-0002); nothing is retained across calls. The stream is lazy: `visit` returning
    /// `ControlFlow::Break` stops it early, and the result is `Ok(Break)`; `Ok(Continue)` means
    /// the stream was exhausted. Read-only; never shells to `jj log` (AR-AP-1).
    ///
    /// # Errors
    ///
    /// - [`crate::RevsetError::ParseError`] — either expression is syntactically invalid.
    /// - [`crate::RevsetError::ResolutionError`] — a symbol in either expression cannot be
    ///   resolved.
    /// - [`crate::RevsetError::JjLibError`] — `load_at_head`, evaluation, or a per-item
    ///   stream failure; the jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn walk_graph(
        &self,
        revset: &str,
        prioritize: &str,
        visit: impl FnMut(crate::GraphNode) -> ControlFlow<()>,
    ) -> Result<ControlFlow<()>, crate::RevsetError> {
        crate::graph::walk_graph(self, revset, prioritize, visit)
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
            &StoreFactories::default(),
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
            Some(Backend::Git) => pollster::block_on(Workspace::init_internal_git(&settings, path))
                .map_err(|e| RepoError::InitFailed { reason: e.to_string() })?,
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
        let (_workspace_init, repo) = pollster::block_on(Workspace::init_internal_git(settings, target_path))
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
            jj_lib::git::add_remote(tx.repo_mut(), remote_name, url, None, gix::remote::fetch::Tags::All)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            // tx is intentionally dropped without commit.
        }

        // Step 3: Reload workspace so Workspace::load constructs a fresh Store /
        // GitBackend that reads the git config from disk (now containing "origin").
        let mut workspace = Workspace::load(
            settings,
            target_path,
            &StoreFactories::default(),
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
            fetcher
                .fetch(remote_name, refspecs, &mut NoopCallback, None, None)
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
            import_stats
                .changed_remote_bookmarks
                .iter()
                .find_map(|(symbol, (_old_ref, new_target))| {
                    if &symbol.name == branch && symbol.remote == remote_name_buf {
                        new_target.as_normal()
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
            &StoreFactories::default(),
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
