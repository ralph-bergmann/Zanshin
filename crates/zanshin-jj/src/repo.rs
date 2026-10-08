// SPDX-License-Identifier: MIT

use std::io;
use std::ops::ControlFlow;
use std::path::{Path, PathBuf};

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::git::{
    expand_fetch_refspecs, GitFetch, GitFetchRefExpression, GitImportOptions, GitProgress, GitSidebandLineTerminator,
    GitSubprocessCallback,
};
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::str_util::{StringExpression, StringPattern};
use jj_lib::workspace::{DefaultWorkspaceLoaderFactory, Workspace, WorkspaceInitError, WorkspaceLoaderFactory as _};

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
    /// The effective jj config stack could not be read — a stack file is unreadable or not
    /// valid TOML, a `config-id` is malformed, or a value has the wrong type. The CLI fails at
    /// start-up on the same faults, so nothing is opened or written.
    #[error("config error: {reason}")]
    Config {
        /// Human-readable failure, naming the offending file path or config key.
        reason: String,
    },
    /// Underlying `jj_lib` failure, flattened to its Display so no `jj_lib` type escapes the public API.
    #[error("jj-lib error: {0}")]
    Backend(String),
}

impl From<crate::ConfigError> for RepoError {
    fn from(e: crate::ConfigError) -> Self {
        let crate::ConfigError::Load { reason } = e;
        Self::Config { reason }
    }
}

/// A failed git-backed workspace CREATION as a [`RepoError`]: the git backend's own read of
/// its `git.*` keys ([`crate::config::init_config_fault`]) is a [`RepoError::Config`], like
/// every other fault of the stack the workspace is created with; anything else is `other`.
pub(crate) fn creation_error(e: &WorkspaceInitError, other: impl FnOnce(String) -> RepoError) -> RepoError {
    crate::config::init_config_fault(e).map_or_else(|| other(e.to_string()), RepoError::from)
}

/// What a workspace CREATION reports (Story 9.33) — [`Repo::init`], [`Repo::clone`],
/// [`crate::convert_colocated`] and [`crate::convert_import`] — and, since Story 9.37, what
/// [`Repo::open_with_report`] reports, in [`crate::ConfigSetOutcome`]'s shape: the result, and
/// what the jj CLI would have printed on the way, on success AND on failure.
#[derive(Debug)]
pub struct CreationOutcome {
    /// The created workspace, or why it was not created.
    pub result: Result<Repo, RepoError>,
    /// The conversion's implicit snapshot report (`do_init`'s `maybe_snapshot`): `Some` iff that
    /// snapshot started — only the two conversions run it — and PARTIAL when a step of it failed.
    /// On a conversion that failed before its re-open it describes state the rollback has since
    /// removed; a failed re-open leaves `.jj/` in place.
    pub precondition: Option<crate::Precondition>,
    /// The call's warnings in the CLI's print order, including those recorded before a failure.
    pub warnings: Vec<crate::Warning>,
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
/// *(2026-09-30, Story 4.10: one read is pinned instead — [`Repo::commit_contents`] answers at
/// the caller-supplied operation and returns commit-intrinsic values only; see the ADR-0002
/// Addendum 2026-09-30.)*
///
/// The `UserSettings` it writes with (commit author, operation user/host, working-copy
/// knobs) come from the workspace's EFFECTIVE jj config stack — the CLI's own — and are
/// re-derived before a mutation whenever that stack changed (Story 9.27).
///
/// Every verb whose CLI counterpart snapshots first (`workspace_helper`) runs the same implicit
/// snapshot + colocated Git import before it does anything else (Story 9.26); its report is
/// [`Repo::take_precondition`], and the warnings the call collected — the CLI's `ui.warning_*`
/// lines, precondition and verb alike — are [`Repo::take_warnings`] (Story 9.32).
pub struct Repo {
    workspace: Workspace,
    settings: UserSettings,
    /// What `settings` was derived from — see [`Repo::refresh_settings`].
    stack_fingerprint: crate::config::StackFingerprint,
    /// The last precondition's report, until [`Repo::take_precondition`] takes it.
    pending_precondition: Option<crate::Precondition>,
    /// The last verb's warnings, until [`Repo::take_warnings`] takes them. Reset at the start of
    /// every verb that runs the precondition.
    pending_warnings: crate::warning::Warnings,
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

    /// Loads the workspace at `root` with settings from ITS OWN effective config stack.
    ///
    /// `Workspace::load`'s body split in two (`jj-lib workspace.rs:410-419`): the loader
    /// resolves `.jj/repo` (following a secondary workspace's FILE indirection) BEFORE the
    /// repo is loaded, so the repo and workspace layers are known when the settings are
    /// built. Right after the loader, the CLI's start-up secure-config fix-up runs (Story 9.37,
    /// [`crate::config::fix_up_secure_config`]; its warnings land in `warnings`, on success AND
    /// on failure), so the fingerprint taken next is POST-fix-up and a migration costs no
    /// second reload. The fingerprint is taken before the settings — a change in between costs
    /// one redundant reload later, never a missed one. The two error mappers let
    /// [`Repo::open_with_report`] and [`Repo::refresh_settings`] share the sequence under their
    /// own error types.
    fn load_effective<E>(
        root: &Path,
        config_error: impl Fn(crate::ConfigError) -> E,
        load_error: impl Fn(String) -> E,
        warnings: &mut Vec<crate::Warning>,
    ) -> Result<Self, E> {
        let loader = DefaultWorkspaceLoaderFactory
            .create(root)
            .map_err(|e| load_error(e.to_string()))?;
        let paths = crate::config::WorkspacePaths {
            repo_path: loader.repo_path(),
            workspace_root: loader.workspace_root(),
        };
        crate::config::fix_up_secure_config(&crate::config::ConfigEnv::from_env(), paths, warnings)
            .map_err(&config_error)?;
        let stack_fingerprint =
            crate::config::stack_fingerprint(loader.repo_path(), loader.workspace_root()).map_err(&config_error)?;
        let settings = crate::config::user_settings_for(&*loader).map_err(&config_error)?;
        let workspace = loader
            .load(
                &settings,
                &default_backend_factories(),
                &default_working_copy_factories(),
            )
            // jj-lib reads keys itself while loading (the git backend's `git.*`, the working
            // copy's `ui.conflict-marker-style`/`working-copy.*`/`fsmonitor.*`): a wrong-typed
            // one is a CONFIG fault, reported as such, not as an opaque load failure.
            .map_err(|e| {
                crate::config::load_config_fault(&e).map_or_else(|| load_error(e.to_string()), &config_error)
            })?;
        Ok(Self {
            workspace,
            settings,
            stack_fingerprint,
            pending_precondition: None,
            pending_warnings: crate::warning::Warnings::default(),
        })
    }

    /// Re-derives the settings — and reloads the workspace, whose `RepoLoader` and working
    /// copy captured the old ones — iff the effective config stack changed since they were
    /// last derived.
    ///
    /// The CLI builds its `UserSettings` per invocation, so an external `jj config set` (or a
    /// Zanshin config edit) takes effect on its very next command; this is the same, at the
    /// cost of one fix-up pass per verb — a load of the raw stack (system, user, repo and
    /// workspace files parsed) — plus a few `stat`s for the fingerprint. [`Repo::precondition`]
    /// calls it FIRST, so every verb that snapshots sees the current stack.
    ///
    /// Every call starts with the CLI's start-up secure-config fix-up (Story 9.37,
    /// [`crate::config::fix_up_secure_config`]) — BEFORE the fingerprint comparison, because a
    /// fix-up may change no stamped file (a regenerated `metadata.binpb`, a re-pointed moved
    /// repo) and must still run every verb, as in the CLI. Its warnings go to the caller's
    /// `warnings` (a reload replaces `*self`, collector included); the reload's own fix-up is
    /// then a no-op.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::Config`] — the fix-up failed or the changed stack no longer
    ///   reads (the CLI would fail at start-up); the handle keeps its previous settings.
    /// - [`crate::MutateError::Backend`] — the workspace could not be reloaded.
    pub(crate) fn refresh_settings(&mut self, warnings: &mut Vec<crate::Warning>) -> Result<(), crate::MutateError> {
        let paths = crate::config::WorkspacePaths {
            repo_path: self.workspace.repo_path(),
            workspace_root: self.workspace.workspace_root(),
        };
        crate::config::fix_up_secure_config(&crate::config::ConfigEnv::from_env(), paths, warnings)
            .map_err(crate::mutate::cfg)?;
        let current = crate::config::stack_fingerprint(self.workspace.repo_path(), self.workspace.workspace_root())
            .map_err(crate::mutate::cfg)?;
        if current != self.stack_fingerprint {
            let root = self.workspace.workspace_root().to_owned();
            *self = Self::load_effective(&root, crate::mutate::cfg, crate::mutate::be, warnings)?;
        }
        Ok(())
    }

    /// The implicit snapshot every CLI command whose helper is `workspace_helper` runs first
    /// (Story 9.26) — `cli/src/cli_util.rs:472-516` @ v0.44.0.
    ///
    /// 1. [`Repo::refresh_settings`] — the CLI's start-up secure-config fix-up (Story 9.37), then
    ///    the settings re-derived if the stack changed — so the snapshot runs with the current
    ///    config stack. The fix-up's warnings are the call's FIRST, also when the refresh fails.
    /// 2. The CLI's start-up environment ([`crate::snapshot::CommandEnv`]: the fileset and
    ///    revset alias tables, the `immutable_heads()` parse) is built — BEFORE the lock, as
    ///    `workspace_helper_with_stats` builds it (`cli_util.rs:477`), so a bad
    ///    `immutable_heads()` alias refuses without waiting and writes nothing.
    /// 3. Colocated workspaces take jj's `git_import_export.lock` (blocking), then the head is
    ///    loaded and `snapshot_impl` runs: `import git head`, `snapshot working copy`,
    ///    `import git refs` (colocated) or the snapshot alone. Each step reads its own config
    ///    where the CLI does (Story 9.34): the snapshot knobs (`snapshot.auto-track`, the ignore
    ///    files, `snapshot.max-new-file-size`) at the start of the snapshot step, AFTER the head
    ///    import (`cli_util.rs:2065-2070`); the Git import options at the start of the refs step
    ///    (`cli_util.rs:1434-1437`). A fault in either fails after the earlier steps committed,
    ///    and their operations stay, as in the CLI. `snapshot.auto-update-stale` is read only on
    ///    a stale working copy (`cli_util.rs:499`).
    /// 4. The report is stored for [`Repo::take_precondition`] — a PARTIAL one when a later
    ///    step failed — and the lock is released.
    /// 5. On success, the snapshot's stats warn (`print_snapshot_stats`, which `workspace_helper`
    ///    prints right after the snapshot) — unless `warn_stats` is `false`: `file track` prints
    ///    only its MERGED stats (`workspace_helper_with_stats`).
    ///
    /// The call's warning collector starts fresh here (Story 9.32); on success it moves into the
    /// returned context, on failure it stays for [`Repo::take_warnings`].
    ///
    /// No caching, debouncing or "did anything change" heuristic: the trigger is the verb
    /// call, exactly like the CLI. A precondition that finds nothing to do writes no
    /// operation, which is what keeps a watcher-driven refresh loop-free.
    ///
    /// # Errors
    ///
    /// Any [`crate::PreconditionError`].
    fn precondition(&mut self, warn_stats: bool) -> Result<crate::snapshot::VerbContext, crate::PreconditionError> {
        let mut fix_ups = Vec::new();
        let refreshed = self.refresh_settings(&mut fix_ups);
        self.pending_precondition = Some(crate::Precondition::default());
        self.pending_warnings = crate::warning::Warnings::default();
        self.pending_warnings.extend(fix_ups);
        refreshed?;
        let config = crate::config::load(self)?;
        let colocated = crate::wc_ops::is_colocated_git_workspace(&self.workspace)
            .map_err(|e| crate::PreconditionError::Backend(crate::mutate::flatten_chain(&e)))?;
        let env = crate::snapshot::CommandEnv::load(&self.workspace, &config, &mut self.pending_warnings)?;
        let mut report = crate::Precondition::default();
        let result = crate::snapshot::run(
            &mut self.workspace,
            &config,
            &env,
            colocated,
            &mut report,
            &mut self.pending_warnings,
        );
        self.pending_precondition = Some(report);
        let auto_stats = match result {
            Err(stale @ crate::PreconditionError::StaleWorkingCopy { .. }) => {
                // The CLI reads `snapshot.auto-update-stale` only here (`cli_util.rs:499` @
                // v0.44.0). Its `true` arm is Story 9.23's stale recovery; until that lands a
                // stale working copy refuses either way, but a wrong-typed value is still a
                // config fault, as in the CLI.
                let _auto_update_stale = crate::config::snapshot_auto_update_stale(&config)?;
                return Err(stale);
            }
            other => other?,
        };
        if warn_stats {
            self.pending_warnings.extend(crate::warning::snapshot_stats(
                self.workspace.workspace_root(),
                &auto_stats,
            ));
        }
        Ok(crate::snapshot::VerbContext::new(
            config,
            env,
            colocated,
            auto_stats,
            std::mem::take(&mut self.pending_warnings),
        ))
    }

    /// Runs the precondition, then `verb` with its context — and keeps the call's warnings for
    /// [`Repo::take_warnings`] on EVERY path: a failed precondition, a failed verb, a success.
    fn with_verb<T, E: From<crate::PreconditionError>>(
        &mut self,
        verb: impl FnOnce(&mut Self, &mut crate::snapshot::VerbContext) -> Result<T, E>,
    ) -> Result<T, E> {
        self.with_verb_stats(true, verb)
    }

    /// [`Repo::with_verb`] with the precondition's snapshot-stats warnings switched by
    /// `warn_stats` (see [`Repo::precondition`]).
    fn with_verb_stats<T, E: From<crate::PreconditionError>>(
        &mut self,
        warn_stats: bool,
        verb: impl FnOnce(&mut Self, &mut crate::snapshot::VerbContext) -> Result<T, E>,
    ) -> Result<T, E> {
        let mut ctx = self.precondition(warn_stats)?;
        let result = verb(self, &mut ctx);
        self.pending_warnings = std::mem::take(&mut ctx.warnings);
        result
    }

    /// Snapshots the working copy — and, in a colocated workspace, imports the Git HEAD and
    /// refs — right now (Story 9.26): the CLI's `jj util snapshot`
    /// (`cli/src/commands/util/snapshot.rs` @ v0.44.0).
    ///
    /// Exactly the precondition every other snapshotting verb runs first, with nothing after
    /// it — for the GUI's "sync now" or a future working-tree trigger; the UI decides when to
    /// call it (FR-JJ-17), nothing in Zanshin calls it on its own. A clean tree
    /// with unchanged refs writes no operation and reports `was_snapshot_taken = false`.
    ///
    /// # Errors
    ///
    /// Any [`crate::PreconditionError`]; the partial report stays available through
    /// [`Repo::take_precondition`].
    pub fn snapshot(&mut self) -> Result<crate::Precondition, crate::PreconditionError> {
        self.with_verb(|repo, _ctx| Ok(repo.take_precondition().unwrap_or_default()))
    }

    /// Takes the report the last precondition left behind (Story 9.26), leaving `None`.
    ///
    /// Every verb that runs the precondition leaves one — on success AND on failure (then
    /// partial: every fact up to the failing step). Verbs that do not snapshot
    /// ([`Repo::workspace_root`], [`Repo::resolve_workspace_root`], [`Repo::log_defaults`],
    /// [`Repo::commit_contents`]) leave none. The FFI layer attaches it to every envelope it builds for such a verb.
    #[must_use]
    pub fn take_precondition(&mut self) -> Option<crate::Precondition> {
        self.pending_precondition.take()
    }

    /// Takes the warnings the last precondition-running verb left (Story 9.32), leaving the list
    /// empty.
    ///
    /// The jj CLI's `ui.warning_*` output for that call, as coded facts in its print order: the
    /// start-up secure-config fix-up's (Story 9.37), the config-load warnings, the pre-verb
    /// snapshot's and imports', the verb body's, and the transaction finish's. The list is reset
    /// ONLY where a verb runs the precondition: such a verb starts a fresh list and leaves it
    /// behind — on success AND on failure (then everything up to the failure). Verbs that do not
    /// snapshot ([`Repo::workspace_root`], [`Repo::resolve_workspace_root`],
    /// [`Repo::log_defaults`], [`Repo::commit_contents`]) neither reset nor add to it, so
    /// a take after one of them returns whatever an earlier verb left untaken. A caller takes
    /// the list after each precondition-running verb, as the FFI layer does for every envelope
    /// it builds for one.
    #[must_use]
    pub fn take_warnings(&mut self) -> Vec<crate::Warning> {
        self.pending_warnings.take()
    }

    /// Returns the working-copy status: files changed between `@` and `@-`.
    ///
    /// Runs the pre-verb snapshot first (Story 9.26), exactly like `jj status`, so on-disk
    /// edits made outside Zanshin are part of `@`. Re-resolves to head on every call
    /// (ADR-0002).
    ///
    /// # Errors
    ///
    /// Returns [`crate::StatusError::NoWorkingCopy`] if the workspace has no
    /// working-copy commit, [`crate::StatusError::Precondition`] if the pre-verb snapshot
    /// failed, or [`crate::StatusError::Backend`] on jj-lib failure.
    pub fn status(&mut self) -> Result<crate::Status, crate::StatusError> {
        self.with_verb(|repo, _ctx| crate::status::working_copy_status(&repo.workspace))
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
    pub fn get_change(&mut self, id: &crate::ChangeId) -> Result<crate::Change, crate::ChangeError> {
        self.with_verb(|repo, _ctx| crate::change::get_change(&repo.workspace, id))
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
    pub fn op_log(&mut self, limit: Option<usize>) -> Result<Vec<crate::Operation>, crate::OpLogError> {
        self.with_verb(|repo, _ctx| crate::op_log::op_log(repo.workspace(), limit))
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
    pub fn list_bookmarks(&mut self) -> Result<Vec<crate::Bookmark>, crate::BookmarkError> {
        self.with_verb(|repo, _ctx| crate::bookmarks::list_bookmarks(repo.workspace()))
    }

    /// Lists local + tracked-remote tags, sorted by name then kind (ADR-0003 §5).
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj tag list` (AR-AP-1). A conflicted target resolves to the first added commit's
    /// change id (listing scope only). Unlike the CLI's `jj tag list`, a tracked remote tag
    /// whose target equals the local one is NOT hidden — that filter is a display default and
    /// belongs to [`crate::CommitMeta::tags`], exactly as for [`Repo::list_bookmarks`].
    ///
    /// # Errors
    ///
    /// - [`crate::ViewError::Backend`] — `load_at_head` or a store read failed; the jj-lib
    ///   reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_tags(&mut self) -> Result<Vec<crate::Tag>, crate::ViewError> {
        self.with_verb(|repo, _ctx| crate::view::list_tags(repo.workspace()))
    }

    /// Lists the repo's visible head commits, sorted by hex commit id (ADR-0003 §5).
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only. jj-lib's
    /// `View::heads()` is an unordered set, so the sort is Zanshin's and is the determinism
    /// guarantee. Heads are COMMIT ids: two divergent commits of one change can both be heads,
    /// so a change-id form would fabricate duplicates.
    ///
    /// # Errors
    ///
    /// - [`crate::ViewError::Backend`] — `load_at_head` failed; the jj-lib reason is forwarded
    ///   as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_heads(&mut self) -> Result<Vec<crate::CommitId>, crate::ViewError> {
        self.with_verb(|repo, _ctx| crate::view::list_heads(repo.workspace()))
    }

    /// Lists every workspace of this repo with its working-copy commit id (ADR-0003 §5).
    ///
    /// The view half of `jj workspace list`, in jj-lib's own lexicographic-by-name order.
    /// Re-resolves to the head operation per call (ADR-0002). Read-only. No workspace *path*
    /// is reported — that lives in the `WorkspaceStore`, not the `View`.
    ///
    /// # Errors
    ///
    /// - [`crate::ViewError::Backend`] — `load_at_head` failed; the jj-lib reason is forwarded
    ///   as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_working_copies(&mut self) -> Result<Vec<crate::WorkingCopy>, crate::ViewError> {
        self.with_verb(|repo, _ctx| crate::view::list_working_copies(repo.workspace()))
    }

    /// Lists configured git remotes with their fetch/push URLs, sorted by name (FR-JJ-9).
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never
    /// shells to `jj git remote list` (AR-AP-1). A non-git (native) backend, or a
    /// git-backed repo with no remotes, yields `Ok(vec![])`.
    ///
    /// [`crate::Remote::push_url`] is present only when it DIFFERS from the fetch URL —
    /// the same question `jj git remote list` answers with its `(push: …)` suffix.
    ///
    /// # Errors
    ///
    /// - [`crate::RemoteError::Backend`] — `load_at_head` failed; the jj-lib
    ///   reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_remotes(&mut self) -> Result<Vec<crate::Remote>, crate::RemoteError> {
        self.with_verb(|repo, _ctx| crate::remotes::list_remotes(repo.workspace()))
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

    /// Lists the entries of a revision's tree (Story 9.4) — the CLI's `jj file list`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Never shells to `jj file list`
    /// (AR-AP-1). Like the CLI's `workspace_helper`, the pre-verb snapshot runs first (Story
    /// 9.26) and is the only thing that may write an operation; the listing itself is a read.
    ///
    /// `revision = None` is the CLI's own `-r` default, `@` — the working-copy commit the
    /// snapshot has just brought up to date. `paths`
    /// entries are repo-relative paths interpreted as PREFIXES (an empty list means all
    /// paths); an empty-STRING entry is the repository root, which prefixes everything, so
    /// `paths = [""]` matches all paths just as `paths = []` does. The fileset DSL is
    /// terminal input language and is not parsed here.
    ///
    /// Entries come in jj-lib's own `entries_matching` (tree) order. Like the CLI, this verb
    /// has NO refusals for the paths themselves: a path matching nothing simply contributes
    /// no entry and warns `jj.paths_unmatched` (Story 9.32). Subtrees are visited recursively
    /// and never yielded — except a subtree that CONFLICTS with a non-tree, which is emitted
    /// as one [`crate::FileType::Conflict`] entry and not descended into.
    ///
    /// # Errors
    ///
    /// - [`crate::FileError::ChangeNotFound`] — `revision` is malformed, carried by no
    ///   VISIBLE commit (unknown or only-hidden), or divergent (the CLI's `-r` refuses an
    ///   ambiguous revision too). An ABSENT `revision` is not an error: it is what applies
    ///   the CLI's `-r` default `@`.
    /// - [`crate::FileError::InvalidInput`] — a `paths` entry is not a valid repo path.
    /// - [`crate::FileError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: owned `ChangeId` is the house currency for a single-revision parameter
    // (epics.md Story 6.1 / AC-1); the implementation only needs to borrow it.
    #[allow(clippy::needless_pass_by_value)]
    pub fn file_list(
        &mut self,
        revision: Option<crate::ChangeId>,
        paths: &[String],
    ) -> Result<Vec<crate::FileEntry>, crate::FileError> {
        self.with_verb(|repo, ctx| {
            crate::file::file_list(repo.workspace(), &mut ctx.warnings, revision.as_ref(), paths)
        })
    }

    /// Reads the contents of the files selected by `paths` in a revision (Story 9.4) — the
    /// CLI's `jj file show`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj file show` (AR-AP-1); only its pre-verb snapshot (Story 9.26) may write an operation.
    ///
    /// `revision` and `paths` behave exactly as for [`Repo::file_list`], with one
    /// difference the CLI also makes: `paths` may not be EMPTY (its FILESETS argument is
    /// `required`). A directory is visited recursively.
    ///
    /// With exactly ONE path the CLI takes a fast path that refuses an absent path
    /// ([`crate::FileError::PathNotFound`]); with several, a path that is absent simply
    /// contributes nothing. That asymmetry is the CLI's, reproduced deliberately.
    ///
    /// A conflicted file's content is the MATERIALIZED merge, with markers in the style the
    /// repo's effective `ui.conflict-marker-style` selects — re-read per call and never
    /// cached, so the user's own jj config decides how a conflict renders. Paths that exist
    /// but are not renderable as file content (a symlink, a Git submodule, a blob whose
    /// access is denied) land in [`crate::FileContents::skipped`] instead of failing the
    /// call — carrying the CLI's own wording for the three cases it warns about, and
    /// Zanshin's own for the two it `panic!`s on rather than reports. A blob that
    /// materializes but then fails to READ still fails the whole call, as it does in the CLI.
    ///
    /// Whole files are held in memory (jj-lib's `read_all` has no size cap) where the CLI
    /// streams to stdout — a resource divergence, not a behavioral one.
    ///
    /// # Errors
    ///
    /// - [`crate::FileError::InvalidInput`] — `paths` is empty, or an entry is not a valid
    ///   repo path.
    /// - [`crate::FileError::ChangeNotFound`] — `revision` does not resolve.
    /// - [`crate::FileError::PathNotFound`] — exactly one path was given and it is absent
    ///   from the revision's tree.
    /// - [`crate::FileError::Config`] — the repo's effective jj config is unreadable or
    ///   malformed, so the `ui.conflict-marker-style` to materialize a conflict with cannot
    ///   be determined. `file_show` is the only one of the four verbs that reads config, and
    ///   the only one that can return this variant.
    /// - [`crate::FileError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: see `file_list`.
    #[allow(clippy::needless_pass_by_value)]
    pub fn file_show(
        &mut self,
        revision: Option<crate::ChangeId>,
        paths: &[String],
    ) -> Result<crate::FileContents, crate::FileError> {
        self.with_verb(|repo, ctx| crate::file::file_show(repo, &mut ctx.warnings, revision.as_ref(), paths))
    }

    /// Annotates one file line by line (Story 9.4) — the CLI's `jj file annotate`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj file annotate` (AR-AP-1); only its pre-verb snapshot (Story 9.26) may write an operation.
    ///
    /// `path` is a PLAIN repo-relative path, not a fileset — it is `parse_file_path` in the
    /// CLI too, and prefix semantics would be meaningless for a single annotated file.
    /// `revision = None` is `@`, as for [`Repo::file_list`].
    ///
    /// The search domain is `all()`, hardcoded exactly as the CLI hardcodes it (it carries
    /// an upstream TODO about exposing one, and jj-lib silently under-reports for a
    /// non-contiguous domain — an option that can only produce wrong answers is not
    /// offered).
    ///
    /// One entry per line of the file, in file order, so a line's own 1-based number is its
    /// index in the returned `Vec` + 1 — which is why
    /// [`crate::AnnotationLine`] carries only `original_line_number`, the line's number in
    /// the ORIGINATING commit. Where the CLI collapses "the search stopped outside the
    /// domain" to the root commit for display, [`crate::AnnotationLine::origin_found`]
    /// keeps the distinction.
    ///
    /// # Errors
    ///
    /// - [`crate::FileError::ChangeNotFound`] — `revision` does not resolve.
    /// - [`crate::FileError::InvalidInput`] — `path` is not a valid repo path.
    /// - [`crate::FileError::PathNotFound`] — `path` is absent from the revision's tree.
    /// - [`crate::FileError::NotAFile`] — `path` exists but is not a regular file (a
    ///   directory, a symlink, a submodule, or a conflict with a non-file side).
    /// - [`crate::FileError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: see `file_list`.
    #[allow(clippy::needless_pass_by_value)]
    pub fn file_annotate(
        &mut self,
        revision: Option<crate::ChangeId>,
        path: &str,
    ) -> Result<Vec<crate::AnnotationLine>, crate::FileError> {
        self.with_verb(|repo, _ctx| crate::file::file_annotate(repo.workspace(), revision.as_ref(), path))
    }

    /// Searches the files of a revision for `pattern` (Story 9.4) — the CLI's
    /// `jj file search`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj file search` (AR-AP-1); only its pre-verb snapshot (Story 9.26) may write an operation.
    ///
    /// `pattern` is jj's own `kind:pattern` string-pattern syntax passed through verbatim
    /// (FR-JJ-17); a bare pattern defaults to kind `regex`, and the FIRST `:` is the
    /// separator. `revision` and `paths` behave as for [`Repo::file_list`].
    ///
    /// `name_only` is carried through because it changes the WORK done — a file's scan stops
    /// at its first match — not the rendering; the result shape is unchanged, so each
    /// matching file still contributes its first matching line, a superset of what the CLI
    /// prints. The CLI's `--line-number` has no counterpart: the result always carries
    /// [`crate::SearchMatch::line_number`], so there is nothing left for the flag to switch.
    ///
    /// A conflicted path is searched side by side, with `conflict_side` set and line numbers
    /// restarting at each side (the CLI's own choice — there is no meaningful unified
    /// numbering across sides). Symlinks, Git submodules and non-file conflicts are SILENTLY
    /// not searched, as the CLI skips them; a path whose blob cannot be READ is reported in
    /// [`crate::FileSearch::skipped`] with the CLI's own warning sentence — the only case
    /// `jj file search` warns about, and a different set (and wording) from what
    /// [`Repo::file_show`] skips.
    ///
    /// # Errors
    ///
    /// - [`crate::FileError::ChangeNotFound`] — `revision` does not resolve.
    /// - [`crate::FileError::InvalidInput`] — `pattern` names an unknown kind or does not
    ///   parse, or a `paths` entry is not a valid repo path.
    /// - [`crate::FileError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: see `file_list`.
    #[allow(clippy::needless_pass_by_value)]
    pub fn file_search(
        &mut self,
        revision: Option<crate::ChangeId>,
        pattern: &str,
        paths: &[String],
        name_only: bool,
    ) -> Result<crate::FileSearch, crate::FileError> {
        self.with_verb(|repo, ctx| {
            crate::file::file_search(
                repo.workspace(),
                &mut ctx.warnings,
                revision.as_ref(),
                pattern,
                paths,
                name_only,
            )
        })
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
        &mut self,
        revset: &str,
        prioritize: &str,
        short_prefixes: &str,
        visit: impl FnMut(crate::GraphNode) -> ControlFlow<()>,
    ) -> Result<ControlFlow<()>, crate::RevsetError> {
        self.with_verb(|repo, ctx| {
            crate::graph::walk_graph(repo, &mut ctx.warnings, revset, prioritize, short_prefixes, visit)
        })
    }

    /// Returns the index-only topology of `revset` — every node in `jj log` order with its
    /// commit id, jj's edges verbatim (targets resolved to node indices) and the view half of
    /// its `jj log` metadata — plus `|all()|`, the node indices each anchor selects, and the
    /// operation it was read at (Story 4.10).
    ///
    /// The CLI's one `jj log`, split: the same parse order, diagnostics and `TopoGroupedGraph` +
    /// `prioritize_branch` pipeline as [`Repo::walk_graph`], and the pre-verb precondition
    /// exactly once (Story 9.26), but nothing per node that needs the commit object — the
    /// object half is [`Repo::commit_contents`] at the returned
    /// [`crate::GraphTopology::operation_id`], which is the head this call's own load saw
    /// (after its snapshot, if that wrote one). Edges keep repeated targets; a Missing edge has
    /// no target; no synthetic "(elided revisions)" node is spliced.
    ///
    /// Every argument is a caller pass-through (FR-JJ-17) — Rust applies no default:
    /// `revset`, `prioritize` and `short_prefixes` as in [`Repo::walk_graph`]; `anchors`, an
    /// ordered list of revsets, each intersected with `revset` as a user expression and
    /// evaluated once (an empty list is valid); `with_timestamps`, which loads each non-root
    /// commit for its committer timestamp (the one per-node load, per call, never cached).
    /// Re-resolves to head per call (ADR-0002); nothing is retained across calls.
    ///
    /// # Errors
    ///
    /// - [`crate::RevsetError::Precondition`] — the pre-verb snapshot failed.
    /// - [`crate::RevsetError::ParseError`] — any expression, an anchor included, is
    ///   syntactically invalid; raised before the repo is loaded.
    /// - [`crate::RevsetError::ResolutionError`] — a symbol in `revset`, `prioritize` or an
    ///   anchor cannot be resolved. An unresolvable `short_prefixes` only warns and degrades.
    /// - [`crate::RevsetError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable.
    /// - [`crate::RevsetError::DanglingEdge`] — an edge names a target outside the node set
    ///   (jj-lib's stream contract rules it out).
    /// - [`crate::RevsetError::JjLibError`] — `load_at_head`, evaluation, a per-node index
    ///   lookup, a stream item, or (with `with_timestamps`) a commit load failed.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn graph_topology(
        &mut self,
        revset: &str,
        prioritize: &str,
        short_prefixes: &str,
        anchors: &[String],
        with_timestamps: bool,
    ) -> Result<crate::GraphTopology, crate::RevsetError> {
        self.with_verb(|repo, ctx| {
            crate::topology::graph_topology(
                repo,
                &mut ctx.warnings,
                revset,
                prioritize,
                short_prefixes,
                anchors,
                with_timestamps,
            )
        })
    }

    /// Returns the object half of each commit in `commit_ids` — author, committer timestamp,
    /// full description, conflict, empty — in request order, read at the PINNED `operation_id`
    /// (Story 4.10).
    ///
    /// The continuation of [`Repo::graph_topology`]'s `jj log`: the CLI's per-row commit load.
    /// It takes `&self`, so it runs no precondition, snapshot, import, config load or fix-up;
    /// it loads the repo with `load_operation` + `load_at` (never `load_at_head`), so it writes
    /// no operation and no op head (a load may write missing index files); and it leaves
    /// [`Repo::take_precondition`] / [`Repo::take_warnings`] untouched. The values are
    /// commit-intrinsic, so a head that moved since the topology call changes nothing
    /// (ADR-0002 Addendum 2026-09-30). Ids are full hex only — no prefix resolution. An empty
    /// list is `Ok(vec![])`.
    ///
    /// # Errors
    ///
    /// In check order:
    /// - [`crate::CommitContentError::InvalidInput`] — `operation_id` is empty, not hex, or not
    ///   a full operation id.
    /// - [`crate::CommitContentError::OperationNotFound`] — the operation is not in the
    ///   operation store (the CLI's `No operation ID matching "<id>"`).
    /// - [`crate::CommitContentError::InvalidInput`] — a commit id is empty, not hex, or not a
    ///   full commit id (every id is checked before any load).
    /// - [`crate::CommitContentError::CommitNotFound`] — a commit id is not in the pinned
    ///   operation's index.
    /// - [`crate::CommitContentError::Backend`] — any jj-lib load failure, including an indexed
    ///   commit (or, for `empty`, its parent) whose object is gone.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn commit_contents(
        &self,
        operation_id: &crate::OperationId,
        commit_ids: &[crate::CommitId],
    ) -> Result<Vec<crate::CommitContent>, crate::CommitContentError> {
        crate::commit_content::commit_contents(&self.workspace, operation_id, commit_ids)
    }

    /// Streams the commits `revset` denotes through `visit`, one [`crate::Change`] per commit
    /// (ADR-0003 §5's generic read primitive).
    ///
    /// `revset` is a caller pass-through (FR-JJ-17); [`crate::DEFAULT_LOG_REVSET`] is the CLI's
    /// default and the repo's *effective* value is [`Repo::log_defaults`]. Aliases resolve from
    /// the repo's effective jj config, builtin defaults included, so a user's
    /// `[revset-aliases]` override of `trunk()` changes the denoted set exactly as it does in
    /// their CLI. The config is re-read per call and never cached; the repo is re-resolved to
    /// the head operation per call (ADR-0002).
    ///
    /// The walk is LAZY and the set is never materialized: `visit` returning
    /// [`ControlFlow::Break`] stops it and the result is `Ok(Break)`, while `Ok(Continue)` means
    /// the stream was exhausted. `Break` IS the limit — there is no `limit`/`start`/`count`
    /// parameter. Exactly one [`crate::Change`] is built per visited row; commit *loads* are
    /// pipelined a constant number ahead, so a `Break` may leave a few already dispatched —
    /// bounded by the backend's concurrency, never by the size of the set.
    ///
    /// One row per COMMIT, not per change: unlike [`crate::resolve_revset`], nothing is
    /// deduplicated, so a divergent change contributes one row per visible commit — each with the
    /// same [`crate::Change::id`] and `divergent` set. A caller keying rows by change id must
    /// handle that.
    ///
    /// Order is the RAW revset order — jj-lib's `Revset::stream()` contract, topological with
    /// children before parents. It is deliberately NOT `jj log`'s printed order: the
    /// topo-grouping and `revsets.log-graph-prioritize` handling that produce that order live in
    /// [`Repo::walk_graph`], and this primitive is the unopinionated one. Read-only; never
    /// shells to the `jj` CLI (AR-AP-1). Changes already handed to `visit` before an `Err` are
    /// not retracted — discard partial output on `Err`. No internal locking: callers serialize
    /// access (single worker isolate, AD-2).
    ///
    /// # Errors
    ///
    /// - [`crate::RevsetError::ParseError`] — `revset` is syntactically invalid or names an
    ///   unknown function; raised before any repo I/O.
    /// - [`crate::RevsetError::ResolutionError`] — a symbol cannot be resolved (unknown
    ///   bookmark/tag, no working-copy commit for `@`, unmatched/ambiguous id).
    /// - [`crate::RevsetError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable. A single bad `[revset-aliases]` entry is NOT an error: like the CLI, it
    ///   warns and is skipped.
    /// - [`crate::RevsetError::JjLibError`] — `load_at_head`, evaluation, or a per-item
    ///   stream/store failure; the jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn eval_revset(
        &mut self,
        revset: &str,
        visit: impl FnMut(crate::Change) -> ControlFlow<()>,
    ) -> Result<ControlFlow<()>, crate::RevsetError> {
        self.with_verb(|repo, ctx| crate::revset::eval_revset(repo, &mut ctx.warnings, revset, visit))
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
    /// - [`crate::MutateError::Immutable`] — `change_id` resolves to a non-root commit
    ///   inside the repo's effective immutable set.
    /// - [`crate::MutateError::Config`] — the `revset-aliases."immutable_heads()"` alias does not
    ///   resolve against the repo.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including a jj config or `immutable_heads()` alias that does not read or parse.
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
        self.with_verb(|repo, ctx| crate::mutate::describe(repo.workspace_mut(), ctx, &change_id, description))
    }

    /// Creates a new, empty change on top of `parents` (FR-JJ-10a) — a merge commit
    /// when `parents.len() > 1` — and switches the working copy to it.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `parents` is empty.
    /// - [`crate::MutateError::ChangeNotFound`] — a parent id is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including an effective jj config that changed and no longer reads (see
    ///   [`Repo::open`]); refused before the verb itself runs.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn new_change(&mut self, parents: &[crate::ChangeId]) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::mutate::new_change(repo.workspace_mut(), ctx, parents))
    }

    /// Switches the working copy to `change_id` without creating a new commit
    /// (FR-JJ-10a).
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::ChangeNotFound`] — `change_id` is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::Immutable`] — `change_id` resolves to a commit inside the
    ///   repo's effective immutable set (the root commit included — see
    ///   [`crate::MutateError::Immutable`]).
    /// - [`crate::MutateError::Config`] — the `revset-aliases."immutable_heads()"` alias does not
    ///   resolve against the repo.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including a jj config or `immutable_heads()` alias that does not read or parse.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: signature (owned `ChangeId`) is fixed by epics.md Story 6.1 / AC-1; the
    // implementation only needs to borrow it, but the public API takes ownership.
    #[allow(clippy::needless_pass_by_value)]
    pub fn edit(&mut self, change_id: crate::ChangeId) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::mutate::edit(repo.workspace_mut(), ctx, &change_id))
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
    /// - [`crate::MutateError::Immutable`] — a target resolves to a non-root commit inside
    ///   the repo's effective immutable set.
    /// - [`crate::MutateError::Config`] — the `revset-aliases."immutable_heads()"` alias does not
    ///   resolve against the repo.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including a jj config or `immutable_heads()` alias that does not read or parse.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn abandon(&mut self, change_ids: &[crate::ChangeId]) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::mutate::abandon(repo.workspace_mut(), ctx, change_ids))
    }

    /// Undoes the last operation — the CLI's `jj undo` @ v0.46.0, undo stack included
    /// (FR-JJ-14a, Story 9.39): a repeated `undo` goes further back into the past instead of
    /// redoing the previous one, and an undo stack the CLI started is continued here (and vice
    /// versa).
    ///
    /// Restores the undone operation's parent's repo state + local bookmarks/tags +
    /// remote-tracking bookmarks (leaving `git_refs`/`git_heads` untouched) onto a
    /// freshly-committed op. `allow_cross_workspace` is the CLI's `--allow-cross-workspace`
    /// (default `false`): without it, an operation performed in another workspace is not undone.
    /// Undoing a push or a workspace removal warns (`jj.undo_push_operation`,
    /// `jj.undo_workspace_removal`). See `op_log::undo` for the step.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::UndoCrossWorkspace`] — the operation to undo was performed in
    ///   another workspace and `allow_cross_workspace` is `false`.
    /// - [`crate::MutateError::NothingToUndo`] — the operation to undo IS the op-store root
    ///   (no parent to restore to).
    /// - [`crate::MutateError::InvalidInput`] — the operation to undo has more than one
    ///   parent (a divergent-write merge op) — undoing a merge operation is refused.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including an effective jj config that changed and no longer reads (see
    ///   [`Repo::open`]); refused before the verb itself runs.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn undo(&mut self, allow_cross_workspace: bool) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::op_log::undo(repo.workspace_mut(), ctx, allow_cross_workspace))
    }

    /// Fetches all branches and tags from `remote_name` and imports them (FR-JJ-13).
    ///
    /// Always fetches ALL branches and tags — there is no branch/tag filter
    /// parameter (unlike the CLI's `jj git fetch -b`/`--branch`). Mirrors
    /// [`Repo::clone`]'s own fetch step, but forwards real progress via `progress`
    /// instead of discarding it. It finishes like the CLI's `tx.finish` (Story 9.26): a
    /// colocated workspace exports the fetched refs to Git, and the working copy is checked
    /// out at the new operation. A fresh operation is committed even when nothing changed —
    /// NOT CLI parity: the CLI's `WorkspaceCommandTransaction::finish` writes none when
    /// `!has_changes()` (`cli_util.rs:2790-2795` @ v0.44.0); the known, tracked divergence
    /// (deferred-work.md, "`Repo::git_fetch` and `Repo::describe` write an operation when
    /// nothing changed").
    ///
    /// `git.abandon-unreachable-commits`, `git.record-synthetic-predecessors` and the
    /// per-remote `remotes.<name>.auto-track-bookmarks` are read from the repo's EFFECTIVE
    /// config per call and never cached (FR-JJ-17), exactly as
    /// `cli/src/commands/git/fetch.rs:235` @ v0.44.0 takes them off config.
    ///
    /// The result's `abandoned_change_ids` carries the commits jj-lib itself abandoned
    /// during the import because they became unreachable in git — the effect
    /// `git.abandon-unreachable-commits` governs — read from the import's own stats. This
    /// is the one verb where that field is not a caller echo; see
    /// [`crate::MutationResult::abandoned_change_ids`]. `new_change_ids` is always empty.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::RemoteNotFound`] — `remote_name` has no configured git
    ///   remote.
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend at all.
    /// - [`crate::MutateError::Config`] — the `revset-aliases."immutable_heads()"` alias does
    ///   not resolve against the repo, or — in a NON-colocated workspace, where the verb reads
    ///   them — a `git.*` / `remotes.<name>.auto-track-bookmarks` key above is malformed.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including a jj config or alias that does not read or parse, and — in a COLOCATED
    ///   workspace, whose pre-verb refs import reads them first — a malformed key above.
    /// - [`crate::MutateError::NetworkError`] — the underlying `git` subprocess
    ///   failed.
    /// - [`crate::MutateError::Backend`] — any other underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_fetch(
        &mut self,
        remote_name: &str,
        progress: &crate::ProgressFn,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        // WHY the two fields rather than the accessors: disjoint field borrows, so the
        // workspace can be borrowed mutably next to the settings.
        self.with_verb(|repo, ctx| {
            crate::remotes::git_fetch(&mut repo.workspace, &repo.settings, remote_name, ctx, progress)
        })
    }

    /// Reloads the workspace from disk so a freshly-written git config is visible.
    ///
    /// jj-lib's four remote mutators call `save_git_config()`, which writes the git config
    /// file immediately but does NOT update the already-loaded `GitBackend`'s in-memory gix
    /// config cache. Without this reload, `git_remote_add(…)` followed by `list_remotes()`
    /// on the SAME handle would return the pre-call list. This is exactly step 3 of
    /// [`Repo::clone_into`], which drops its throwaway transaction and reloads for the same
    /// reason.
    fn reload_workspace(&mut self) -> Result<(), crate::MutateError> {
        let root = self.workspace.workspace_root().to_owned();
        self.workspace = Workspace::load(
            &self.settings,
            &root,
            &default_backend_factories(),
            &default_working_copy_factories(),
        )
        .map_err(crate::mutate::be)?;
        Ok(())
    }

    /// Runs [`Repo::reload_workspace`] after a verb that MAY have rewritten the git config,
    /// on BOTH the success and the failure path — `remove_remote`/`rename_remote` write the
    /// config BEFORE the git-ref edits that can still fail, so a mid-verb failure would
    /// otherwise leave a stale cache behind. Some failures reach here having written nothing
    /// at all (a repo-level jj config that could not be read refuses before the transaction
    /// opens); reloading then is merely redundant, never wrong.
    ///
    /// A reload failure is surfaced only when the verb itself succeeded: an already-failing
    /// call must keep its own error, which is the one that explains what the user did. That
    /// swallowing is why the reload failure is ALWAYS traced first — otherwise a stale
    /// config cache would silently outlive the call for the rest of the session, which is
    /// exactly the condition this helper exists to prevent.
    ///
    /// Neither ordering makes an `Err` mean "nothing happened" — see the four facades' docs.
    fn reload_after_config_write(
        &mut self,
        result: Result<crate::MutationResult, crate::MutateError>,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        let reload = self.reload_workspace().inspect_err(|e| {
            tracing::warn!(error = %e, "git config was rewritten but the workspace could not be reloaded");
        });
        let value = result?;
        reload.map(|()| value)
    }

    /// Imports the backing git repo's refs into jj's view (Story 9.5) — the CLI's
    /// `jj git import`.
    ///
    /// In a colocated workspace the CLI skips this verb, because its per-command snapshot has
    /// already imported the refs. Zanshin runs the same pre-verb snapshot (Story 9.26), then
    /// returns the no-op result before opening any transaction — the CLI's early return ("No
    /// import needed in colocated workspaces.", `cli/src/commands/git/import.rs` @ v0.44.0) —
    /// and writes no operation of its own.
    ///
    /// `git.abandon-unreachable-commits`, `git.record-synthetic-predecessors` and the
    /// per-remote `remotes.<name>.auto-track-bookmarks` are read from the repo's EFFECTIVE
    /// config per call and never cached (FR-JJ-17).
    ///
    /// If nothing needed importing, NO operation is written and
    /// `GitImportResult::mutation.new_op_id` is the pre-call op-log head. A ref that could
    /// not be imported is reported in `failed_ref_names` and never fails the call — the CLI
    /// warns and exits 0.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Config`] — the `revset-aliases."immutable_heads()"` alias does
    ///   not resolve against the repo, or — in a NON-colocated workspace, where the verb reads
    ///   them — a `git.*` / `remotes.<name>.auto-track-bookmarks` key above is malformed.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including a jj config or alias that does not read or parse, and — in a COLOCATED
    ///   workspace, whose pre-verb refs import reads them first — a malformed key above.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_import(&mut self) -> Result<crate::GitImportResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::git::git_import(repo.workspace_mut(), ctx))
    }

    /// Writes jj's bookmarks and tags back to the backing git repo (Story 9.5) — the CLI's
    /// `jj git export`.
    ///
    /// In a colocated workspace every finished transaction has already exported the refs, so
    /// — as with [`Repo::git_import`] — the verb returns the no-op result before opening any
    /// transaction, after the pre-verb snapshot: the CLI's early return ("No export needed in
    /// colocated workspaces.", `cli/src/commands/git/export.rs` @ v0.44.0). Export rewrites no
    /// commit, so it needs no descendant pass, and it never moves `@`.
    ///
    /// If git already matched, NO operation is written and
    /// `GitExportResult::mutation.new_op_id` is the pre-call op-log head. Refs that could
    /// not be written are reported in `failed_bookmarks` / `failed_tags` and never fail the
    /// call — the CLI warns and exits 0. The classic case is two bookmarks named `foo` and
    /// `foo/bar`, which git cannot both hold.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including an effective jj config that changed and no longer reads (see
    ///   [`Repo::open`]); refused before the verb itself runs.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_export(&mut self) -> Result<crate::GitExportResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::git::git_export(repo.workspace_mut(), ctx))
    }

    /// Registers a new git remote (Story 9.5) — the CLI's `jj git remote add`.
    ///
    /// `url` and `push_url` are passed through VERBATIM (FR-JJ-17); unlike the CLI, a
    /// relative local path is NOT resolved against a process CWD a GUI backend has no
    /// business consulting. The workspace is reloaded before returning, so
    /// [`Repo::list_remotes`] on this SAME handle sees the new remote immediately.
    ///
    /// Adding a remote WITH a push URL is worth one warning: jj-lib writes a `pushurl` key,
    /// and its own `remove_remote` then refuses that remote as
    /// [`crate::MutateError::RemoteNonstandardConfig`].
    ///
    /// **An `Err` does NOT mean "nothing happened."** jj-lib writes the git config file
    /// BEFORE the git-ref edits, and both happen before the transaction commits, so a
    /// refusal raised late can leave the config already rewritten; and a reload failure is
    /// reported only AFTER the operation has committed, discarding an otherwise-successful
    /// [`crate::MutationResult`]. Re-read [`Repo::list_remotes`] to learn the actual state
    /// rather than assuming the pre-call one.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::RemoteExists`] — `name` is already taken.
    /// - [`crate::MutateError::InvalidInput`] — `name` is the reserved `git`, contains a
    ///   slash, or is not a valid gix remote name.
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including an effective jj config that changed and no longer reads (see
    ///   [`Repo::open`]); refused before the verb itself runs.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_remote_add(
        &mut self,
        name: &str,
        url: &str,
        push_url: Option<&str>,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        let result =
            self.with_verb(|repo, ctx| crate::git::git_remote_add(repo.workspace_mut(), ctx, name, url, push_url));
        self.reload_after_config_write(result)
    }

    /// Removes a git remote and forgets its bookmarks (Story 9.5) — the CLI's
    /// `jj git remote remove`.
    ///
    /// The workspace is reloaded before returning (see [`Repo::git_remote_add`]).
    /// Removing the reserved remote `git` succeeds and updates the git config and refs, but
    /// changes no jj view state, so NO operation is written and the returned `new_op_id` is
    /// the pre-call op-log head — the CLI behaves identically.
    ///
    /// The repo-level jj config file is rewritten as well, exactly as the CLI does: the
    /// `[remotes.<name>]` section is dropped, and a `revset-aliases.'trunk()'` that is a
    /// plain remote symbol naming this remote is DELETED — so the REPO layer stops defining
    /// `trunk()` and whatever the rest of the stack resolves to applies instead, which is
    /// the builtin unless the workspace or user layer defines a `trunk()` of its own. Both
    /// edits key on the remote name alone, and only the repo layer is touched. The file is
    /// the one this repo's config layer actually reads
    /// (`<config_dir>/jj/repos/<config-id>/config.toml`, or the legacy
    /// `.jj/repo/config.toml`); if no such file exists, nothing is written and NONE is
    /// created.
    ///
    /// **An `Err` does NOT mean "nothing happened."** The repo-level jj config is read
    /// before the transaction opens, so a read-side config fault refuses with nothing
    /// mutated at all; but jj-lib writes the git config file BEFORE the git-ref edits, and
    /// both happen before the transaction commits, so a refusal raised late — including a
    /// failed repo-config WRITE, which drops the transaction — can leave the git config
    /// already rewritten; and a reload failure is reported only AFTER the operation has
    /// committed, discarding an otherwise-successful [`crate::MutationResult`]. Re-read
    /// [`Repo::list_remotes`] to learn the actual state rather than assuming the pre-call
    /// one.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::Config`] — the repo-level jj config could not be READ (a
    ///   malformed `.jj/repo/config-id`, an unreadable file, invalid TOML), refused before
    ///   anything is mutated; or it could not be WRITTEN back, which aborts the transaction
    ///   after jj-lib's git-config edit has landed.
    /// - [`crate::MutateError::RemoteNotFound`] — no such remote.
    /// - [`crate::MutateError::RemoteNonstandardConfig`] — jj refuses to rewrite this
    ///   remote's git config (a remote added with a push URL is exactly this case).
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_remote_remove(&mut self, name: &str) -> Result<crate::MutationResult, crate::MutateError> {
        let result = self.with_verb(|repo, ctx| crate::git::git_remote_remove(repo.workspace_mut(), ctx, name));
        self.reload_after_config_write(result)
    }

    /// Renames a git remote (Story 9.5) — the CLI's `jj git remote rename`.
    ///
    /// The workspace is reloaded before returning (see [`Repo::git_remote_add`]). Renaming
    /// FROM the reserved remote `git` writes no operation, for the same reason removing it
    /// does not.
    ///
    /// The repo-level jj config file is rewritten as well — see [`Repo::git_remote_remove`]
    /// for which file that is and when nothing is written. Here `[remotes.<old_name>]`
    /// becomes `[remotes.<new_name>]` with its value untouched, and a plain-remote-symbol
    /// `trunk()` naming `old_name` is re-pointed at `new_name`, keeping its bookmark.
    ///
    /// jj-lib validates `new_name` BEFORE it reports that `old_name` is missing, so
    /// `git_remote_rename("nonexistent", "git")` reports the reserved-name refusal. That
    /// ordering is jj-lib's own and is reproduced, not corrected.
    ///
    /// **An `Err` does NOT mean "nothing happened."** The repo-level jj config is read
    /// before the transaction opens, so a read-side config fault refuses with nothing
    /// mutated at all; but jj-lib writes the git config file BEFORE the git-ref edits, and
    /// both happen before the transaction commits, so a refusal raised late — including a
    /// failed repo-config WRITE, which drops the transaction — can leave the git config
    /// already rewritten; and a reload failure is reported only AFTER the operation has
    /// committed, discarding an otherwise-successful [`crate::MutationResult`]. Re-read
    /// [`Repo::list_remotes`] to learn the actual state rather than assuming the pre-call
    /// one.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::Config`] — the repo-level jj config could not be READ (a
    ///   malformed `.jj/repo/config-id`, an unreadable file, invalid TOML), refused before
    ///   anything is mutated; or it could not be WRITTEN back, which aborts the transaction
    ///   after jj-lib's git-config edit has landed.
    /// - [`crate::MutateError::InvalidInput`] — `new_name` is the reserved `git`, contains
    ///   a slash, or is not a valid gix remote name.
    /// - [`crate::MutateError::RemoteNotFound`] — `old_name` has no configured remote.
    /// - [`crate::MutateError::RemoteExists`] — `new_name` is already taken.
    /// - [`crate::MutateError::RemoteNonstandardConfig`] — `old_name`'s git config is not
    ///   the plain single-fetch-refspec shape jj knows how to rewrite.
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_remote_rename(
        &mut self,
        old_name: &str,
        new_name: &str,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        let result =
            self.with_verb(|repo, ctx| crate::git::git_remote_rename(repo.workspace_mut(), ctx, old_name, new_name));
        self.reload_after_config_write(result)
    }

    /// Re-points a git remote's fetch and/or push URL (Story 9.5) — the CLI's
    /// `jj git remote set-url`.
    ///
    /// NO operation is ever written: jj-lib's `set_remote_urls` takes a `&Store`, and the
    /// CLI opens no transaction either — so the returned `new_op_id` is always the pre-call
    /// op-log head. The workspace is still reloaded, so [`Repo::list_remotes`] on this same
    /// handle reports the new URL.
    ///
    /// A `None` URL leaves that side unchanged (jj-lib cannot REMOVE a URL). With BOTH
    /// `None` the call succeeds and does nothing — even for a remote that does not exist,
    /// because jj-lib returns early before its own existence check. That is mirrored
    /// deliberately.
    ///
    /// **An `Err` does NOT mean "nothing happened."** jj-lib writes the git config file
    /// BEFORE the git-ref edits, and both happen before the transaction commits, so a
    /// refusal raised late can leave the config already rewritten; and a reload failure is
    /// reported only AFTER the operation has committed, discarding an otherwise-successful
    /// [`crate::MutationResult`]. Re-read [`Repo::list_remotes`] to learn the actual state
    /// rather than assuming the pre-call one.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::RemoteNotFound`] — at least one URL was supplied and `name`
    ///   has no configured remote.
    /// - [`crate::MutateError::InvalidInput`] — `name` is the reserved `git`, contains a
    ///   slash, or is not a valid gix remote name.
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including an effective jj config that changed and no longer reads (see
    ///   [`Repo::open`]); refused before the verb itself runs.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_remote_set_url(
        &mut self,
        name: &str,
        url: Option<&str>,
        push_url: Option<&str>,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        let result =
            self.with_verb(|repo, _ctx| crate::git::git_remote_set_url(repo.workspace_mut(), name, url, push_url));
        self.reload_after_config_write(result)
    }

    /// Shows each revision `revset` denotes with what it changed (Story 9.6) — the CLI's
    /// `jj show`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj show` (AR-AP-1). The verb itself never writes an operation, not even on a refusal;
    /// only its pre-verb snapshot (Story 9.26) may.
    ///
    /// `revset` is a caller pass-through EXPRESSION, not a change id (FR-JJ-17): the CLI takes
    /// `Vec<RevisionArg>` and unions them, so entries are per COMMIT — a revset naming two
    /// commits of ONE divergent change yields two entries carrying the same
    /// [`crate::Change::id`], both with `divergent` set. A BARE divergent change-id symbol does
    /// NOT get that far: jj-lib's own `SymbolResolver` refuses it
    /// (`RevsetResolutionError::DivergentChangeId`, `revset.rs:2827` @ 0.44.0), exactly as
    /// `jj show <divergent-id>` fails in the CLI, and it arrives here as
    /// [`crate::CommitViewError::RevsetResolutionError`]. Address both commits by unioning their
    /// COMMIT hexes, which are ordinary revset symbols. That is still a real, observable
    /// difference from [`Repo::interdiff`], which refuses the same change as
    /// [`crate::CommitViewError::ChangeNotFound`] from its own single-revision resolver.
    /// `None` applies the CLI's own default `@` — the working-copy commit the pre-verb snapshot
    /// has just brought up to date (Story 9.26).
    /// Aliases come from the repo's effective jj config, re-read per call and never cached.
    ///
    /// Entries come in RAW revset order (topological, children before parents); the CLI's
    /// `--reversed` is rendering and is not ported. Each entry's
    /// [`crate::ShowEntry::file_changes`] is the diff of the commit's MERGED parent tree
    /// against its own tree — for a merge commit, only what the merge itself changed; for the
    /// root commit, empty. Copy records are accumulated over EVERY parent, as the CLI's
    /// `show_patch` does, so a rename surfaces as one [`crate::ChangeKind::Renamed`] entry on a
    /// git-backed repo (the native backend reports no copies and degrades to an
    /// `Added`+`Removed` pair).
    ///
    /// There is no path argument and no textual patch: the CLI hardcodes `EverythingMatcher`,
    /// and line/word-level diffing is Epic 5's (`zanshin-diff`).
    ///
    /// `limit` is a ZANSHIN-SIDE addition — the CLI has no such flag here, because `jj show`
    /// streams to a pager where this materialises one owned list, each entry paying a
    /// merged-parent tree diff plus a per-parent copy-record stream. It is `take(limit)` applied
    /// in RAW REVSET order, the same order the unbounded call returns, and BEFORE that per-entry
    /// work, so nothing past the limit is computed. `Some(0)` is an empty result, not an error,
    /// and `None` is the CLI-parity default: unbounded, byte-identical to the pre-`limit` output.
    /// Not computing those entries also means not FAILING on them: a revset whose later commits
    /// are unreadable succeeds under a limit that stops short of them and errors without one —
    /// the price of the early stop, and the same property [`Repo::evolog`]'s limit has always had.
    ///
    /// # Errors
    ///
    /// - [`crate::CommitViewError::RevsetParseError`] — `revset` is syntactically invalid or
    ///   names an unknown function; raised before any repo read.
    /// - [`crate::CommitViewError::RevsetResolutionError`] — a symbol cannot be resolved.
    /// - [`crate::CommitViewError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable.
    /// - [`crate::CommitViewError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn show(
        &mut self,
        revset: Option<&str>,
        limit: Option<usize>,
    ) -> Result<Vec<crate::ShowEntry>, crate::CommitViewError> {
        self.with_verb(|repo, ctx| crate::commit_views::show(repo, &mut ctx.warnings, revset, limit))
    }

    /// Walks the evolution of the changes `revset` denotes (Story 9.6) — the CLI's `jj evolog`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj evolog` (AR-AP-1). The verb itself never writes an operation, not even on a refusal;
    /// only its pre-verb snapshot (Story 9.26) may.
    ///
    /// `revset` behaves exactly as for [`Repo::show`] (a pass-through expression, `None` = `@`).
    /// `limit` is the CLI's `-n/--limit`, applied as `take(limit)` in WALK order: the CLI limits
    /// before reversing, and both the reversal and the `TopoGroupedGraph` re-ordering its graph
    /// mode applies are rendering the GUI does itself. `Some(0)` is an empty result, not an
    /// error.
    ///
    /// Rows carry COMMIT ids, not change ids: every predecessor shares the change's id, and
    /// predecessors are hidden by construction. [`crate::EvologEntry::operation_id`] is `None`
    /// exactly for the entries the walk flushes when it reaches an operation that stores no
    /// predecessors — the only signal that an evolution may be TRUNCATED, which the CLI leaves
    /// silent.
    ///
    /// The CLI's `-p/--patch` has no counterpart: it *is* an interdiff of each entry's
    /// predecessors — so a caller composes the two verbs, feeding a
    /// [`crate::EvologEntry::predecessor_commit_ids`] entry to [`Repo::interdiff`] as a
    /// [`crate::RevisionRef::CommitId`], the arm that reaches hidden commits.
    ///
    /// [`crate::EvologEntry::change`] carries two fields derived against the CURRENT view
    /// rather than this version's moment (`divergent`, `is_anonymous`); see its doc.
    ///
    /// # Errors
    ///
    /// - [`crate::CommitViewError::RevsetParseError`] — `revset` is syntactically invalid.
    /// - [`crate::CommitViewError::RevsetResolutionError`] — a symbol cannot be resolved.
    /// - [`crate::CommitViewError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable.
    /// - [`crate::CommitViewError::Backend`] — an underlying jj-lib failure, including jj-lib's
    ///   own predecessor-cycle detection.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn evolog(
        &mut self,
        revset: Option<&str>,
        limit: Option<usize>,
    ) -> Result<Vec<crate::EvologEntry>, crate::CommitViewError> {
        self.with_verb(|repo, ctx| crate::commit_views::evolog(repo, &mut ctx.warnings, revset, limit))
    }

    /// Compares what two revisions each CHANGE, with the parent difference factored out
    /// (Story 9.6) — the CLI's `jj interdiff`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj interdiff` (AR-AP-1). The verb itself never writes an operation, not even on a refusal;
    /// only its pre-verb snapshot (Story 9.26) may. Nothing is written by the rebase either:
    /// `rebase_to_dest_parent` merges in memory.
    ///
    /// Unlike [`Repo::show`], each side is a SINGLE revision, written in one of the two
    /// [`crate::RevisionRef`] currencies, and both inherit the CLI's `resolve_single_rev`
    /// REFUSAL — an ambiguous revision is rejected rather than guessed. A
    /// [`crate::RevisionRef::ChangeId`] is the house reverse-hex change-id prefix (Story 9.3,
    /// FR-JJ-17) and resolves only to the currently VISIBLE commit carrying it; a
    /// [`crate::RevisionRef::CommitId`] is a commit-id hex prefix resolved through jj-lib's
    /// index, which is visibility-blind and therefore reaches a HIDDEN commit. That second arm
    /// is what lets the predecessors [`Repo::evolog`] reports be fed back in, so the two verbs
    /// DO compose into a diff of one version of a change against the next. A revset expression
    /// (`main`, `@-`) is still unaddressable on either arm, where the CLI accepts one.
    /// An absent side defaults to `@` — but omitting BOTH is a refusal, mirroring the CLI's
    /// `ArgGroup … required(true)`: interdiffing `@` against itself is trivially empty and
    /// never what a caller meant.
    ///
    /// `paths` entries are repo-relative paths interpreted as PREFIXES (an empty list means all
    /// paths); an empty-STRING entry is the repository root, which prefixes everything, so
    /// `paths = [""]` matches all paths just as `paths = []` does. The fileset DSL is terminal
    /// input language and is not parsed here. A filter that matches nothing yields an empty
    /// list and warns `jj.paths_unmatched` (Story 9.32).
    ///
    /// NO `Renamed`/`Copied` entry is ever produced: the CLI's `show_inter_diff` passes
    /// `CopyRecords::default()`, and that asymmetry with [`Repo::show`] is reproduced
    /// deliberately, not corrected.
    ///
    /// [`crate::InterdiffView::base_has_conflicts`] reports whether the REBASED `from` tree —
    /// the left side of the diff, in memory only — is conflicted. That is a ZANSHIN-SIDE
    /// addition the CLI has no counterpart for: it renders conflict markers in the patch TEXT,
    /// which is Epic 5's surface here, so without the flag a caller sees a plausible change list
    /// derived from a conflicted rebase with no way to tell. It never turns the call into a
    /// refusal, and it describes the TREE, not the filtered result.
    ///
    /// # Errors
    ///
    /// - [`crate::CommitViewError::InvalidInput`] — both `from` and `to` are absent, a `paths`
    ///   entry is not a valid repo path, or a [`crate::RevisionRef::CommitId`] is empty or not
    ///   valid hex.
    /// - [`crate::CommitViewError::ChangeNotFound`] — a [`crate::RevisionRef::ChangeId`] is
    ///   malformed, carried by no VISIBLE commit (unknown or only-hidden), or divergent; or a
    ///   [`crate::RevisionRef::CommitId`] is valid hex that no indexed commit carries. An
    ///   ABSENT side is not an error: ONE absent side applies the CLI's `--from`/`--to` default
    ///   `@`, and omitting BOTH is the `InvalidInput` bullet above.
    /// - [`crate::CommitViewError::RevsetResolutionError`] — a [`crate::RevisionRef::CommitId`]
    ///   prefix is carried by two or more commits; refused, never resolved to one of them.
    /// - [`crate::CommitViewError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: an OWNED single-revision parameter is the house SHAPE (epics.md Story 6.1 / AC-1);
    // the implementation only needs to borrow it. What the parameter is owned OF is this verb's
    // one deliberate exception: `RevisionRef` widens the crate-wide `ChangeId` currency for
    // `interdiff` alone (Epic 9 follow-up I).
    #[allow(clippy::needless_pass_by_value)]
    pub fn interdiff(
        &mut self,
        from: Option<crate::RevisionRef>,
        to: Option<crate::RevisionRef>,
        paths: &[String],
    ) -> Result<crate::InterdiffView, crate::CommitViewError> {
        self.with_verb(|repo, ctx| {
            crate::commit_views::interdiff(repo.workspace(), &mut ctx.warnings, from.as_ref(), to.as_ref(), paths)
        })
    }

    /// Lists every workspace with its working-copy commit and root directory (Story 9.7) — the
    /// CLI's `jj workspace list`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj workspace list` (AR-AP-1); only its pre-verb snapshot (Story 9.26) may write an operation. Takes no argument: the CLI's
    /// only flag is `-T/--template`, which is rendering.
    ///
    /// This is [`Repo::list_working_copies`] plus the path half. The name/commit columns are
    /// literally that call's result — same values, same jj-lib `BTreeMap` order (lexicographic by
    /// workspace name) — and `root` is one `WorkspaceStore` lookup per row, the absolute recorded
    /// path. The CLI's `root.relative()` rendering is not ported.
    ///
    /// [`crate::WorkspaceEntry::root`] is the RECORDED path — reported even when the directory has
    /// moved or been deleted, as the CLI does since jj 0.46. A row whose path cannot be reported
    /// keeps its name and commit and reports `None`: workspaces created before jj 0.38.0 have no
    /// recorded path, and a store may be unreadable. Neither fails the listing; the CLI points at
    /// [`Repo::resolve_workspace_root`] for strict path diagnostics.
    ///
    /// # Errors
    ///
    /// - [`crate::WorkspaceError::Backend`] — `load_at_head` failed, i.e. the VIEW half could not
    ///   be read; the jj-lib reason is forwarded as a string. No path failure reaches this.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_workspaces(&mut self) -> Result<Vec<crate::WorkspaceEntry>, crate::WorkspaceError> {
        self.with_verb(|repo, _ctx| crate::workspace::list_workspaces(repo.workspace()))
    }

    /// Returns a workspace's root directory (Story 9.7) — the CLI's `jj workspace root [--name]`.
    ///
    /// Read-only; never shells to `jj workspace root` (AR-AP-1), and never writes an operation —
    /// not even on a refusal. `name` is the CLI's long-only `--name`, passed through rather than
    /// defaulted here (FR-JJ-17); `None` is its documented default, the CURRENT workspace.
    ///
    /// `resolve_workspace_root(None)` returns exactly what the infallible
    /// [`Repo::workspace_root`] accessor returns, and reads the loader alone — no repo load, no
    /// store read (`cli/src/commands/workspace/root.rs:75` @ v0.46.0). That is the ONLY overlap
    /// between the two: with a name — even the CURRENT workspace's own — the call goes through
    /// the `WorkspaceStore` and can REFUSE or WARN, because the CLI's named path never shortcuts
    /// to the loader. A named lookup runs the CLI's stages in ITS order (store load, view
    /// membership, recorded path) and returns the ABSOLUTE recorded path — not canonicalized, as
    /// in the CLI since jj 0.46; the CLI's CWD-relative rendering is the GUI's job. A recorded
    /// directory that does not exist is no refusal: the path comes back with a
    /// `jj.workspace_path_inaccessible` warning in [`crate::Warned::warnings`].
    ///
    /// An explicitly present EMPTY name is a VALUE, not an absence: no workspace is named `""`,
    /// so it refuses as [`crate::WorkspaceError::NotFound`].
    ///
    /// # Errors
    ///
    /// - [`crate::WorkspaceError::NotFound`] — no workspace of that name is in the head view.
    /// - [`crate::WorkspaceError::NoRecordedPath`] — the workspace exists but the store holds no
    ///   path for it (it predates jj 0.38.0, or its entry was wiped).
    /// - [`crate::WorkspaceError::Backend`] — the workspace store could not be loaded or read, or
    ///   `load_at_head` failed.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn resolve_workspace_root(&self, name: Option<&str>) -> Result<crate::Warned<PathBuf>, crate::WorkspaceError> {
        crate::workspace::resolve_root(self.workspace(), name)
    }

    /// Creates local bookmarks pointing at one revision (Story 9.8) — the CLI's
    /// `jj bookmark create`.
    ///
    /// `names` are DECODED bookmark names, not CLI argument text: the CLI validates each with
    /// `revset::parse_symbol`, so a name containing a space or an `@` has to be QUOTED on a
    /// terminal — and that quoting is exactly the terminal input syntax the GUI replaces
    /// (ADR-0003). Pass the name the user typed into the field. The one refusal kept from
    /// `parse_symbol` is the one no spelling can avoid: an EMPTY name.
    ///
    /// `revision` is the CLI's `-r/--revision`, whose clap `default_value` is the literal
    /// `"@"` — so `None` targets the working-copy commit, which the pre-verb snapshot has just
    /// brought up to date (Story 9.26). It is a change id, so it inherits `resolve_single_rev`'s
    /// ambiguity REFUSAL (a divergent id is rejected, never guessed) but not its address
    /// space: a commit hex, a revset expression and a hidden commit are unaddressable, the
    /// same trade [`Repo::file_list`] documents. ([`Repo::interdiff`] used to make it too;
    /// Epic 9 follow-up I gave that ONE verb a commit-id arm, and this one was deliberately
    /// left alone.)
    ///
    /// Both per-name preconditions run in ARGUMENT order and are FAIL-FAST, as the CLI's are:
    /// a run whose second name already exists creates NOTHING — not even the first name — and
    /// writes no operation.
    ///
    /// Unlike the CLI, a created bookmark is never AUTO-TRACKED: honouring
    /// `remotes.<r>.auto-track-bookmarks` needs `track_remote_bookmark`, the verb Story 9.11
    /// owns. Deliberately deferred.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `names` is empty, or a name is the empty
    ///   string.
    /// - [`crate::MutateError::ChangeNotFound`] — `revision` is malformed, carried by no
    ///   VISIBLE commit (unknown or only-hidden), or divergent. An ABSENT `revision` is not
    ///   an error: it is what applies the CLI's `-r` default `@`.
    /// - [`crate::MutateError::BookmarkExists`] — a name is already a local bookmark.
    /// - [`crate::MutateError::BookmarkTrackedRemoteExists`] — a name's local bookmark is
    ///   absent but it still has a tracked remote bookmark. On a GIT-backed repo a colocated
    ///   `name@git` does NOT count: the default-ignored remote is excluded, exactly as in the
    ///   CLI. That exclusion is git-specific — on any other backend no remote is ignored, so a
    ///   tracked `name@git` refuses there.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including an effective jj config that changed and no longer reads (see
    ///   [`Repo::open`]); refused before the verb itself runs.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_create(
        &mut self,
        names: &[String],
        revision: Option<&crate::ChangeId>,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::bookmark_ops::create(repo.workspace_mut(), ctx, names, revision))
    }

    /// Deletes the local bookmarks matching `patterns` (Story 9.8) — the CLI's
    /// `jj bookmark delete`.
    ///
    /// Each entry is jj's own string-pattern syntax, passed through VERBATIM (FR-JJ-17) and
    /// unioned across the list; `exact:`, `glob:`, `regex:`, `substring:` and the `~`/`&`/`|`
    /// operators all work. **A BARE pattern is a GLOB, not an exact name** — deleting a
    /// bookmark whose name contains `*`, `?` or `[` requires `exact:"…"`, and a bare `foo*`
    /// deletes both a bookmark literally named `foo*` and one named `foo1`.
    ///
    /// Matching NOTHING is a SUCCESS, not a refusal: no operation is written and the returned
    /// `new_op_id` is the PRE-CALL op-log head — the machine-readable form of the CLI's "No
    /// bookmarks to delete." A CONFLICTED local bookmark is deleted like any other.
    ///
    /// A TRACKED `name@remote` SURVIVES, by design: [`Repo::list_bookmarks`] keeps reporting
    /// it, which is jj's "deleted bookmark, propagates on the next push" state rather than a
    /// leak. `jj bookmark forget` — the verb that drops the remote rows too — is Story 9.11's.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `patterns` is empty, or a pattern does not
    ///   parse; jj-lib's reason is forwarded.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including an effective jj config that changed and no longer reads (see
    ///   [`Repo::open`]); refused before the verb itself runs.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_delete(&mut self, patterns: &[String]) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::bookmark_ops::delete(repo.workspace_mut(), ctx, patterns))
    }

    /// Gives the paths matching `paths` in one commit the content they have in another
    /// (Story 9.3) — the CLI's `jj restore`, whole-file only.
    ///
    /// Default resolution is the CLI's (`cli/src/commands/restore.rs:119-137` @ v0.44.0):
    /// if either `from` or `into` is given the omitted one is `@`; if NEITHER is given the
    /// destination is `changes_in` (or `@`) and the source is that commit's PARENT tree,
    /// which undoes its own diff while keeping its description. `changes_in` cannot be
    /// combined with `from`/`into` — the CLI's clap `conflicts_with_all`.
    ///
    /// `paths` entries are repo-relative paths interpreted as PREFIXES (an empty list means
    /// all paths); the fileset DSL is terminal input language and is not parsed here. An
    /// empty-STRING entry is the repository root, which prefixes everything, so `paths = [""]`
    /// matches all paths just as `paths = []` does — send an empty LIST to mean "no filter".
    /// `restore_descendants` reparents children (preserving their content) instead of
    /// rebasing them.
    ///
    /// A path that matches NOTHING in the two trees being compared warns `jj.paths_unmatched`,
    /// the CLI's `print_unmatched_explicit_paths` (Story 9.32); an unmatched filter also leaves
    /// the destination tree unchanged, which this call reports as the no-op described below.
    ///
    /// If the resulting tree already equals the destination's, NO operation is written and
    /// the returned `new_op_id` is the pre-call op-log head — the CLI's own
    /// "Nothing changed." path.
    ///
    /// The working copy is snapshotted first (Story 9.26), exactly like the CLI's
    /// `workspace_helper`, so `@` includes the on-disk edits; that snapshot's own operation, if
    /// any, is written even when the restore itself is a no-op.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `changes_in` combined with `from`/`into`,
    ///   or a `paths` entry is not a valid repo path.
    /// - [`crate::MutateError::ChangeNotFound`] — `from`, `into` or `changes_in` is
    ///   malformed, carried by no VISIBLE commit (unknown or only-hidden), or divergent. An
    ///   ABSENT one is not an error: it is what selects the CLI's
    ///   `--from`/`--into`/`--changes-in` defaults described above.
    /// - [`crate::MutateError::Immutable`] — the destination resolves to a commit inside the
    ///   repo's effective immutable set. Unlike `describe`/`abandon` this verb has no
    ///   separate root-commit guard, so the ROOT commit reports this code too — which is
    ///   what the CLI reports for it.
    /// - [`crate::MutateError::Config`] — the `revset-aliases."immutable_heads()"` alias does not
    ///   resolve against the repo.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including a jj config or `immutable_heads()` alias that does not read or parse.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: owned `ChangeId`s match the house currency for single-revision parameters
    // (epics.md Story 6.1 / AC-1); the implementation only needs to borrow them.
    #[allow(clippy::needless_pass_by_value)]
    pub fn restore(
        &mut self,
        from: Option<crate::ChangeId>,
        into: Option<crate::ChangeId>,
        changes_in: Option<crate::ChangeId>,
        paths: &[String],
        restore_descendants: bool,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| {
            crate::mutate::restore(
                repo.workspace_mut(),
                ctx,
                from.as_ref(),
                into.as_ref(),
                changes_in.as_ref(),
                paths,
                restore_descendants,
            )
        })
    }

    /// Moves each hunk of `from` into the closest commit in `destinations` where the
    /// corresponding lines were last modified (Story 9.3) — the CLI's `jj absorb`,
    /// non-interactive only.
    ///
    /// `from = None` is `@`. `destinations` is a revset EXPRESSION, not an id list: the CLI's
    /// `--into` is a set whose default is the dynamic `mutable()` alias, and materializing it
    /// into ids would destroy that meaning (FR-JJ-17). `None` applies the CLI's own clap
    /// default, `"mutable()"` — an ALIAS resolved through the repo's effective config, so a
    /// user's `[revset-aliases]` decides what it denotes.
    ///
    /// Parameter order follows the CLI's own reading ("absorb FROM … INTO …") and matches
    /// [`Repo::restore`], the `AbsorbRequest` wire table, and the Dart API.
    ///
    /// `paths` behaves exactly as for [`Repo::restore`], empty-string entry included. Hunks
    /// that cannot be attributed unambiguously stay in the source; paths jj-lib refuses to
    /// split are reported in [`crate::AbsorbResult::skipped_paths`] instead of failing the
    /// call, and each warns `jj.absorb_path_skipped` — the CLI prints one warning per entry. If
    /// nothing is absorbable, NO operation is written and `rewritten_change_ids` is empty.
    ///
    /// The skipped-path warnings are recorded BEFORE the rewritability guard — the CLI's own
    /// order (`absorb.rs:154-158` warns, then `:160-162` checks) — so a
    /// [`crate::MutateError::Immutable`] refusal still carries them through
    /// [`Repo::take_warnings`], as does an explicitly named path that matches nothing
    /// (`jj.paths_unmatched`, Story 9.32).
    ///
    /// The working copy is snapshotted first (Story 9.26) — see [`Repo::restore`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::RevsetParseError`] — `destinations` is syntactically invalid
    ///   or names an unknown function.
    /// - [`crate::MutateError::RevsetResolutionError`] — a symbol in `destinations` cannot
    ///   be resolved.
    /// - [`crate::MutateError::InvalidInput`] — a `paths` entry is not a valid repo path.
    /// - [`crate::MutateError::ChangeNotFound`] — `from` is malformed, carried by no VISIBLE
    ///   commit (unknown or only-hidden), or divergent. An ABSENT `from` is not an error: it
    ///   is what applies the CLI's `--from` default `@`.
    /// - [`crate::MutateError::Immutable`] — a commit the hunks would be absorbed into is
    ///   inside the repo's effective immutable set. Unreachable with the `mutable()`
    ///   default, which excludes that set by construction.
    /// - [`crate::MutateError::Config`] — the `revset-aliases."immutable_heads()"` alias does not
    ///   resolve against the repo.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including a jj config or `immutable_heads()` alias that does not read or parse.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: see `restore` — owned `ChangeId` is the house currency for a single revision.
    #[allow(clippy::needless_pass_by_value)]
    pub fn absorb(
        &mut self,
        from: Option<crate::ChangeId>,
        destinations: Option<&str>,
        paths: &[String],
    ) -> Result<crate::AbsorbResult, crate::MutateError> {
        self.with_verb(|repo, ctx| {
            // WHY the literal: it is the CLI's own clap default for `--into`
            // (`cli/src/commands/absorb.rs:64` @ v0.44.0), and it is an ALIAS — `config.rs`'s
            // builtin layer defines `'mutable()' = '~immutable()'`, which a user's config may
            // replace. The default is therefore a pre-filled, user-editable value that resolves
            // through the effective config layer, never a hardcoded commit set.
            let destinations =
                crate::revset::parse_revset(repo, destinations.unwrap_or("mutable()"), &mut ctx.warnings)
                    .map_err(crate::mutate::rev)?;
            crate::mutate::absorb(repo.workspace_mut(), ctx, from.as_ref(), &destinations, paths)
        })
    }

    /// Starts tracking the working-copy paths matching `paths` (Story 9.22) — the CLI's
    /// `jj file track [--include-ignored] <paths>`.
    ///
    /// `paths` are interpreted as PREFIXES, as for [`Repo::restore`], but parsed the way the CLI
    /// parses a bare path argument with the working directory at the WORKSPACE ROOT: a trailing
    /// `/`, `./` and `//` normalise, an absolute path inside the workspace is accepted, and a
    /// path escaping the workspace is refused. The fileset DSL is terminal input language and
    /// is not parsed. At least one is required (the CLI's `required = true`). `include_ignored`
    /// tracks matching files even when they are ignored or larger than
    /// `snapshot.max-new-file-size` — the CLI's `--include-ignored`.
    ///
    /// The working copy is locked and snapshotted with the effective `snapshot.*` config and
    /// the CLI's ignore chain; the operation `track paths` is written UNCONDITIONALLY, even when
    /// nothing matched, exactly as the CLI commits it.
    ///
    /// **`@` does not change (GH #8298).** Like the CLI, the verb discards the snapshot's tree:
    /// the newly tracked paths live in the working-copy STATE, and the NEXT snapshot moves them
    /// into `@` and rebases `@`'s descendants. For a CLI user that is the next `jj` command;
    /// for Zanshin it is the next verb's pre-verb snapshot (Story 9.26), which runs in front
    /// of every verb — so a second `file_track`, a `describe` or a `new_change` right after this
    /// one first moves the tracked path into `@`, exactly as the CLI would. So
    /// [`crate::TrackResult::num_rebased`] is `0`, and [`crate::TrackResult::snapshot_stats`]
    /// reports the files the track snapshot left untracked, merged with the pre-verb snapshot's
    /// reasons the way `print_track_snapshot_stats` merges them (a file too large for the
    /// auto-snapshot keeps that reason); jj-lib never reports IGNORED files there.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `paths` is empty, or an entry is the empty
    ///   string or escapes the workspace. Refused before the working copy is locked.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including an effective config that no longer reads or a wrong-typed `snapshot.*` knob.
    /// - [`crate::MutateError::NoWorkingCopy`] — this workspace has no `@` in the head view.
    /// - [`crate::MutateError::ConcurrentWorkingCopy`] — the working copy's recorded tree
    ///   differs from `@`'s (`@` rewritten without a checkout by a concurrent writer between the
    ///   pre-verb snapshot and this verb's lock); nothing is written.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure (lock, snapshot, an
    ///   unreadable ignore file, commit).
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn file_track(
        &mut self,
        paths: &[String],
        include_ignored: bool,
    ) -> Result<crate::TrackResult, crate::MutateError> {
        // `workspace_helper_with_stats`: only the MERGED stats warn (see `wc_ops::file_track`).
        self.with_verb_stats(false, |repo, ctx| {
            crate::wc_ops::file_track(repo.workspace_mut(), ctx, paths, include_ignored)
        })
    }

    /// Stops tracking the working-copy paths matching `paths` (Story 9.22) — the CLI's
    /// `jj file untrack <paths>`.
    ///
    /// `paths` behave as for [`Repo::file_track`] (at least one required). The matched entries
    /// are removed from `@` (a rewrite: same change id, descendants rebased), the working-copy
    /// state is `reset` to the new `@` WITHOUT touching a file — the files stay on disk — and
    /// the operation `untrack paths` is written unconditionally.
    ///
    /// Each matched path must already be IGNORED (a `.gitignore`, the git `info/exclude`, the
    /// global excludes file), or fall outside a sparse checkout; otherwise the next snapshot
    /// would add it straight back, so the verb refuses — see
    /// [`crate::MutateError::PathsNotIgnored`]. A concurrent edit to some OTHER file between the
    /// `reset` and the check is not mixed in: the state is reset again, as in the CLI.
    ///
    /// In a COLOCATED workspace the change is also exported to git in the same operation: the
    /// git index drops the paths' intent-to-add entries and jj's refs are exported (a
    /// bookmark on `@` follows the rewrite). Refs that could not be exported are reported in
    /// [`crate::UntrackResult::failed_bookmarks`] / `failed_tags`, never as an error.
    ///
    /// A path that matched nothing in `@` is reported in
    /// [`crate::UntrackResult::unmatched_paths`] and warns `jj.paths_unmatched` (the CLI's
    /// warning, Story 9.32), not refused.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `paths` is empty, or an entry is the empty
    ///   string or escapes the workspace. Refused before the working copy is locked.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including an effective config that no longer reads, a `snapshot.auto-track` that is
    ///   not a string or not a valid fileset, a `[fileset-aliases]` layer that is not a table,
    ///   or a wrong-typed `snapshot.max-new-file-size`.
    /// - [`crate::MutateError::NoWorkingCopy`] — this workspace has no `@` in the head view.
    /// - [`crate::MutateError::ConcurrentWorkingCopy`] — the working copy's recorded tree
    ///   differs from `@`'s (`@` rewritten without a checkout by a concurrent writer between the
    ///   pre-verb snapshot and this verb's lock); nothing is written.
    /// - [`crate::MutateError::PathsNotIgnored`] — matched paths are not ignored; every one is
    ///   named, no operation is written and the working-copy state is unchanged.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure (lock, snapshot, reset,
    ///   an unreadable ignore file, the git index update, commit).
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn file_untrack(&mut self, paths: &[String]) -> Result<crate::UntrackResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::wc_ops::file_untrack(repo.workspace_mut(), ctx, paths))
    }

    /// Opens an existing jj workspace rooted at `path`.
    ///
    /// # Errors
    ///
    /// Returns [`RepoError::PathNotFound`] if `path` cannot be resolved — it does not exist, or it
    /// exists but is unreachable (a parent component denies search, a symlink loop, a non-directory
    /// component) — [`RepoError::NotARepo`] if `.jj` is absent, [`RepoError::Config`] if the
    /// workspace's effective jj config stack cannot be read (a file that is unreadable or not
    /// valid TOML, a malformed `config-id`, a wrong-typed value — the path or key is named), or
    /// [`RepoError::Backend`] on jj-lib failure.
    ///
    /// The workspace is opened with the settings the CLI would use: Default → System → `EnvBase`
    /// → User → Repo → Workspace → `EnvOverrides`. An EMPTY identity is not an error — jj-lib
    /// defaults `user.name`/`user.email` to `""`, and each committed mutation warns
    /// `jj.identity_missing` through [`Repo::take_warnings`] (Story 9.32).
    ///
    /// [`Repo::open_with_report`] with its warnings DROPPED (each logged as a
    /// `tracing::warn!`): opening runs the CLI's start-up secure-config fix-up (Story 9.37), whose
    /// one-shot notices only [`Repo::open_with_report`] reports. Use [`Repo::open_with_report`]
    /// wherever they can reach a user.
    pub fn open(path: &Path) -> Result<Self, RepoError> {
        let outcome = Self::open_with_report(path);
        crate::warning::log_dropped("Repo::open", outcome.warnings);
        outcome.result
    }

    /// Opens an existing jj workspace rooted at `path`, as [`Repo::open`], and reports what the
    /// jj CLI would have printed on the way (Story 9.37).
    ///
    /// Opening plays a CLI command's start-up: right after the loader resolves the repo, the
    /// CLI's secure-config fix-up runs for the repo, then the workspace layer (jj-lib's
    /// `SecureConfig::maybe_load_config`, as `load_secure_config` calls it —
    /// `cli/src/config.rs:447-469` @ v0.44.0): a legacy `.jj/repo/config.toml` / `.jj/workspace-config.toml` is
    /// migrated into the secure config directory, a moved repo's metadata re-pointed, a copied
    /// repo's config forked, a missing secure directory regenerated. Each such notice is one of
    /// [`CreationOutcome::warnings`] — `jj.config_migrated`, `jj.config_copied`,
    /// `jj.config_regenerated` — on success AND on failure (a migrated file that then does not
    /// parse refuses naming the NEW file, and the migration is still reported). Opening runs no
    /// snapshot: [`CreationOutcome::precondition`] is always `None`.
    ///
    /// # Errors
    ///
    /// In [`CreationOutcome::result`]: as [`Repo::open`]; a failed fix-up (an unreadable or
    /// malformed id file, a secure directory that cannot be written) is [`RepoError::Config`].
    #[must_use = "the outcome carries the result and the warnings"]
    pub fn open_with_report(path: &Path) -> CreationOutcome {
        let mut warnings = Vec::new();
        let result = Self::open_reported(path, &mut warnings);
        CreationOutcome {
            result,
            precondition: None,
            warnings,
        }
    }

    /// [`Repo::open_with_report`]'s open, recording the fix-up's warnings into `warnings`.
    fn open_reported(path: &Path, warnings: &mut Vec<crate::Warning>) -> Result<Self, RepoError> {
        // WHY canonicalize instead of a bare `exists()` probe: the CLI canonicalizes its CWD and
        // its `-R` path before it builds the workspace loader (`cli/src/cli_util.rs:4636-4639`,
        // `:4703-4706` @ v0.46.0), so every path its loader hands jj-lib is canonical. It matters
        // for the workspace store: `DefaultWorkspaceLoader::new` takes a primary workspace's
        // `.jj/repo` exactly as spelled, the store's base is that path, and since jj 0.46 both
        // its write (`relative_path`) and its read (`normalize_path`) are purely LEXICAL
        // (`simple_workspace_store.rs:168`, `:236-238`). A raw symlinked base (macOS
        // `/var/folders/…`) still reads its own records, but a writer working off an OPENED repo
        // — Story 9.23's `workspace add`, whose `init_workspace_with_existing_repo` records the
        // CANONICAL new root against this base — would count its `..` segments from the raw
        // spelling, and a canonical base (a secondary workspace's loader canonicalizes its
        // `.jj/repo` file) would resolve them one level off. A canonical open keeps base and
        // records in one spelling.
        //
        // `std::fs::canonicalize`, never `dunce::` — see `workspace.rs`'s house rule.
        //
        // The REFUSAL set is unchanged for every case a caller can hit: `Path::exists()` is
        // `fs::metadata(..).is_ok()`, which follows symlinks, so it returned `false` for the same
        // ENOENT / ENOTDIR / EACCES / symlink-loop conditions that make `canonicalize` fail. The
        // two are not identical in the limit — `realpath(3)` can also fail with ENAMETOOLONG when
        // the RESOLVED path is the long one — and, like `exists()` before it, this collapses every
        // cause into one variant. Both error payloads keep the CALLER's spelling.
        let root = std::fs::canonicalize(path).map_err(|_| RepoError::PathNotFound { path: path.to_owned() })?;
        if !root.join(".jj").is_dir() {
            return Err(RepoError::NotARepo { path: path.to_owned() });
        }
        Self::load_effective(&root, RepoError::from, RepoError::Backend, warnings)
    }

    /// Initialises a new jj workspace at `path`.
    ///
    /// `backend = Some(Backend::Git)` creates a git-backed workspace;
    /// `backend = None` uses jj's native backend.
    ///
    /// The outcome never carries a warning or a snapshot report (Story 9.33): the CLI's
    /// empty-directory `jj git init` finishes no transaction, so nothing reaches a
    /// `ui.warning_*` — not even the identity check. The CLI's start-up environment
    /// (`for_workable_repo`: alias tables, `immutable_heads()`) is not ported to creation; its
    /// warnings belong to that port.
    ///
    /// # Errors
    ///
    /// In [`CreationOutcome::result`]:
    /// [`RepoError::InitFailed`] on jj-lib workspace initialisation failure, or when
    /// `path` cannot be resolved (it must already exist); `reason` then names it. Returns
    /// [`RepoError::Config`] if the jj config stack the workspace would be created with cannot
    /// be read — refused BEFORE anything is written. A fault of the user-level stack is checked
    /// first, as the CLI's start-up does, so it wins over an unresolvable `path`. Once created,
    /// the workspace is re-opened as by [`Repo::open`], so that call's errors apply too.
    ///
    /// The workspace is CREATED with the stack resolved for its own paths, as the CLI's
    /// `settings_for_new_workspace` does (no repo or workspace config file exists yet, but
    /// `--when.repositories` / `--when.workspaces` scopes already apply); the returned handle
    /// then carries the full stack — what the CLI's next invocation would use.
    ///
    /// `path` must already exist — this verb has never created it (jj-lib's `create_jj_dir` uses
    /// `create_dir`, which needs the parent). The CLI's `jj git init` DOES create its destination
    /// (`file_util::create_or_reuse_dir` @ v0.44.0); porting that parity is Story 9.20's.
    #[must_use = "the outcome carries the result"]
    pub fn init(path: &Path, backend: Option<Backend>) -> CreationOutcome {
        CreationOutcome {
            result: Self::init_workspace(path, backend),
            precondition: None,
            warnings: Vec::new(),
        }
    }

    /// [`Repo::init`]'s creation.
    fn init_workspace(path: &Path, backend: Option<Backend>) -> Result<Self, RepoError> {
        // The CLI's start-up config check runs before the command touches any path.
        crate::config::check_startup_stack()?;
        // WHY canonicalize BEFORE the init call: the CLI's `jj git init` canonicalizes its
        // destination before it creates anything (`cli/src/commands/git/init.rs:162-163` @
        // v0.46.0), and the settings below are resolved for that canonical root, as the CLI
        // resolves them. The workspace-store entry itself would be consistent either way: jj-lib's
        // `init_with_factories` canonicalizes both the store's base (`ReadonlyRepo::init`,
        // `repo.rs:228`) and the root it records (`Workspace::new`). The handle is then re-opened
        // through the canonical root — see `Repo::open` for why its base must be canonical.
        let root = std::fs::canonicalize(path).map_err(|e| RepoError::InitFailed {
            reason: format!("{}: {e}", path.display()),
        })?;
        let settings = crate::config::user_settings_for_new_workspace(&root)?;
        let (_workspace, _repo) = match backend {
            // WHY: `object_hash` is jj 0.44's new parameter. jj's CLI resolves it from the
            // `git.object-hash` config, whose builtin default is "sha1" — passing `Sha1` here
            // mirrors that default and reproduces pre-0.44 behaviour exactly.
            // TODO(FR-JJ-17, Epic 9 Story 9.20): resolve `object_hash` the way the CLI does
            // (`git.object-hash` config, caller-overridable) instead of hardcoding it here and in
            // `clone_into`; until then a user configuring "sha256" silently gets sha1.
            Some(Backend::Git) => {
                pollster::block_on(Workspace::init_internal_git(&settings, &root, gix::hash::Kind::Sha1))
                    .map_err(|e| creation_error(&e, |reason| RepoError::InitFailed { reason }))?
            }
            None => pollster::block_on(Workspace::init_simple(&settings, &root))
                .map_err(|e| creation_error(&e, |reason| RepoError::InitFailed { reason }))?,
        };
        Self::open(&root)
    }

    /// Clones a remote Git repository into a new jj workspace at `target_path`.
    ///
    /// Composes: `init_internal_git` → `add_remote("origin")` → `GitFetch::fetch` → `import_refs`,
    /// then points the working copy at the fetched default branch (a fresh `@` commit on its tip).
    ///
    /// On failure, the partial `.jj/` created under `target_path` is rolled back so a
    /// retry into the same path starts clean. A `.jj` that existed before the call (an existing
    /// jj workspace, a symlink) is never touched: creation refuses it and no rollback runs.
    /// `target_path` must already exist — clone never created it (`create_jj_dir` needs the
    /// parent), and a missing target is refused up front.
    /// The CLI's `jj git clone` instead creates its destination and refuses a non-empty one
    /// (`cli/src/commands/git/clone.rs` @ v0.44.0); that parity is Story 9.20's.
    ///
    /// # Warnings
    ///
    /// The outcome's warnings are the CLI's for the steps this port runs, in its order
    /// (Story 9.33): `jj.git_import_failed` for refs the fetch's import could not read, then
    /// — after the single `clone` operation is committed — `jj.checkout_files_skipped` for files
    /// the checkout left alone because an untracked file of the same name was in the way, then
    /// `jj.identity_missing` ONCE (the CLI warns once per finished transaction; Zanshin writes
    /// one operation where the CLI writes up to three). On failure the outcome keeps what was
    /// warned before it, and a rollback that cannot remove `.jj/` adds
    /// `jj.clone_cleanup_failed` last. There is never a snapshot report. The CLI's
    /// start-up-environment warnings (`for_workable_repo`: alias tables, `immutable_heads()`)
    /// are not ported to creation.
    ///
    /// # Errors
    ///
    /// In [`CreationOutcome::result`]:
    /// [`RepoError::CloneFailed`] if `target_path` cannot be resolved, or if init, remote
    /// registration, fetch, or import fails — the init refuses a target that already holds a
    /// `.jj` (jj-lib's "The destination repo (…) already exists"), which stays untouched.
    ///
    /// [`RepoError::Config`] when the effective jj config cannot be read — the stack
    /// the workspace is created with (refused BEFORE anything is written; a user-level fault
    /// is checked first, as the CLI's start-up does, and wins over an unresolvable
    /// `target_path`), or
    /// the new workspace's stack the clone's import options are built from, including a
    /// non-boolean `git.abandon-unreachable-commits` (FR-JJ-17). `reason` names the offending
    /// KEY for a wrong-typed value, the offending FILE PATH for a config file that is
    /// unreadable or not valid TOML. A config fault after the workspace was created rolls the
    /// `.jj/` back like any other clone failure.
    ///
    /// Like [`Repo::init`], the clone runs with the stack resolved for the new workspace's
    /// paths and the returned handle is re-opened as by [`Repo::open`] — that call's errors
    /// apply too.
    #[must_use = "the outcome carries the result and the warnings"]
    pub fn clone(url: &str, target_path: &Path) -> CreationOutcome {
        let mut sink = crate::warning::Warnings::default();
        let result = Self::clone_reported(url, target_path, &mut sink);
        CreationOutcome {
            result,
            precondition: None,
            warnings: sink.take(),
        }
    }

    /// [`Repo::clone`]'s creation, recording its warnings into `sink`.
    fn clone_reported(url: &str, target_path: &Path, sink: &mut crate::warning::Warnings) -> Result<Self, RepoError> {
        // The CLI's start-up config check runs before the command touches any path.
        crate::config::check_startup_stack()?;
        // WHY canonicalize: as in `Repo::init` — the CLI's `jj git clone` canonicalizes its
        // destination too (`cli/src/commands/git/clone.rs:219` @ v0.46.0), and the settings and
        // the re-opened handle use that root.
        let target_path = std::fs::canonicalize(target_path).map_err(|e| RepoError::CloneFailed {
            reason: format!("{}: {e}", target_path.display()),
        })?;
        let settings = crate::config::user_settings_for_new_workspace(&target_path)?;

        // Anything already at `.jj` (a workspace, a symlink — even a dangling one) is not this
        // call's: the init refuses it (`DestinationExists`; a non-directory already fails the
        // config read above) and the rollback must never remove it. Only a definite `NotFound`
        // counts as absent — an unreadable entry is treated as someone else's.
        let jj_preexisted = !matches!(
            target_path.join(".jj").symlink_metadata(),
            Err(e) if e.kind() == io::ErrorKind::NotFound
        );

        // The re-open runs INSIDE the rolled-back result: any failure after creation rolls `.jj/` back.
        // A missing target can no longer reach the rollback — `canonicalize` above refuses it.
        Self::clone_into(&settings, url, &target_path, sink)
            .and_then(|()| Self::open(&target_path))
            .inspect_err(|_| {
                if !jj_preexisted {
                    sink.extend(roll_back_clone(&target_path));
                }
            })
    }

    /// Composes the clone steps; [`Repo::clone`] re-opens the committed result.
    ///
    /// `target_path` is the CANONICAL target directory (`Repo::clone` resolves it), so the
    /// workspace-store entry `init_internal_git` writes and the `Workspace::load` base below
    /// agree on one spelling.
    ///
    /// Its warnings land in `sink` where the CLI prints them: the fetch's failed imports before
    /// the commit (`clone.rs:456`), the checkout's skipped files and the identity check after it
    /// (the finish, `cli_util.rs:3304`, `:2387`).
    fn clone_into(
        settings: &UserSettings,
        url: &str,
        target_path: &Path,
        sink: &mut crate::warning::Warnings,
    ) -> Result<(), RepoError> {
        // Step 1: Create git-backed jj workspace.
        // WHY: `gix::hash::Kind::Sha1` mirrors jj's own `git.object-hash` default (see
        // `Repo::init`); making it a caller parameter is Story 9.20's scope.
        let (workspace_init, repo) = pollster::block_on(Workspace::init_internal_git(
            settings,
            target_path,
            gix::hash::Kind::Sha1,
        ))
        .map_err(|e| creation_error(&e, |reason| RepoError::CloneFailed { reason }))?;

        let remote_name_buf: RemoteNameBuf = "origin".into();
        let remote_name: &RemoteName = &remote_name_buf;

        // Step 2: Write remote to disk via a throwaway transaction.
        // add_remote calls save_git_config() which writes to disk immediately but
        // does NOT update the gix::ThreadSafeRepository's in-memory config cache.
        // We therefore drop this transaction without committing — its only purpose
        // is the disk side-effect. Step 3 reloads from disk to pick it up.
        {
            // WHY: this transaction is dropped without committing, so its metadata is never
            // written and the workspace name is unobservable here. It goes through the
            // sanctioned opener anyway, for uniformity — that leaves the creep guard in
            // `op_support` with zero exceptions to encode, at the cost of one identifier.
            let mut tx = crate::op_support::start_repo_transaction(&repo, workspace_init.workspace_name());
            // WHY: jj 0.44 dropped `add_remote`'s trailing `fetch_tags` argument — tag selection
            // is now driven purely by the fetch refspec, and it is `fetch_expr.tag` below (not
            // `.bookmark`) that carries it: glob("*"), i.e. the same "all tags" behaviour the old
            // `Tags::All` requested.
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
        let subprocess_options = crate::environment::git_subprocess_options(settings)
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        // `git.abandon-unreachable-commits` comes from the freshly-initialised workspace's
        // EFFECTIVE config (FR-JJ-17); no Rust constant decides it. The workspace is the
        // Step-3 reload, which is why this needs `load_for_workspace` — there is no `Repo`
        // wrapping it yet.
        let config = crate::config::load_for_workspace(&workspace)?;
        let import_options = GitImportOptions {
            // WHY: CLI parity — `cli/src/commands/git/clone.rs:384-389` @ v0.44.0 pins this
            // to false REGARDLESS of config ("There may be a large number of new commits").
            // Only `abandon_unreachable_commits` is taken from config here, exactly as there.
            record_synthetic_predecessors: false,
            ..crate::config::git_import_options(&config)?
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
        let mut tx = crate::op_support::start_repo_transaction(&fresh_repo, &workspace_name);
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
        // `print_git_import_stats`, after the default branch is known (`clone.rs:406`, `:456`).
        sink.extend(crate::warning::git_import_failed(&import_stats));

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
            let stats = pollster::block_on(workspace.check_out(new_repo.op_id().clone(), None, wc_commit))
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            sink.extend(crate::warning::checkout_files_skipped(stats.skipped_files));
        }
        sink.extend(crate::warning::identity_missing(settings));

        Ok(())
    }
}

/// Rolls a failed clone back: removes the `.jj/` `init_internal_git` wrote under the CANONICAL
/// `target_path` — Zanshin's rollback scope, which never touches anything else there. Only called
/// when the clone created that `.jj/`: `Repo::clone` skips the rollback when anything already
/// existed at `.jj` (the init then refuses with `DestinationExists`), so a pre-existing workspace
/// is never deleted.
///
/// The CLI's `clean_up_dirs` (`clone.rs:262-284` @ v0.44.0) treats a directory that is already
/// gone as removed and warns about any other failure; so does this, returning that warning.
fn roll_back_clone(target_path: &Path) -> Option<crate::Warning> {
    match std::fs::remove_dir_all(target_path.join(".jj")) {
        Ok(()) => None,
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => Some(crate::warning::clone_cleanup_failed(target_path, &e)),
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

#[cfg(test)]
mod tests {
    use std::path::Path;

    use test_helpers::{extract_fixture, FixtureHandle};

    use super::{Repo, RepoError};
    use crate::MutateError;

    fn open_fixture() -> (FixtureHandle, Repo) {
        test_helpers::pin_test_env();
        let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
        let repo = Repo::open(&fx.path).expect("fixture opens");
        (fx, repo)
    }

    /// The legacy repo-level file (the fixture has no `config-id`), read as the repo layer.
    fn write_repo_config(root: &Path, body: &str) {
        std::fs::write(root.join(".jj").join("repo").join("config.toml"), body).expect("repo config written");
    }

    /// The story's point beyond identity: jj-lib's working-copy settings are the ones the
    /// workspace is LOADED with, so a repo-layer `fsmonitor.backend` / `snapshot.*` must reach
    /// `Workspace::settings()` — and a later change must reach it through the pre-verb refresh.
    #[test]
    fn a_repo_layer_working_copy_knob_reaches_the_workspace_settings() {
        test_helpers::pin_test_env();
        let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
        write_repo_config(
            &fx.path,
            "[fsmonitor]\nbackend = \"watchman\"\n\n[snapshot]\nmax-new-file-size = \"5MiB\"\n",
        );
        let mut repo = Repo::open(&fx.path).expect("fixture opens");
        let settings = repo.workspace().settings();
        assert_eq!(settings.get_string("fsmonitor.backend").unwrap(), "watchman");
        assert_eq!(settings.get_string("snapshot.max-new-file-size").unwrap(), "5MiB");

        repo.refresh_settings(&mut Vec::new())
            .expect("an unchanged stack refreshes as a no-op");
        write_repo_config(&fx.path, "[fsmonitor]\nbackend = \"none\"\n");
        repo.refresh_settings(&mut Vec::new())
            .expect("a changed stack re-derives");
        assert_eq!(
            repo.workspace().settings().get_string("fsmonitor.backend").unwrap(),
            "none"
        );
        assert_eq!(repo.settings.get_string("fsmonitor.backend").unwrap(), "none");
    }

    /// A stack that breaks under an open handle refuses the refresh as a CONFIG fault — both
    /// the file itself and a malformed `config-id` the fingerprint trips over.
    #[test]
    fn refresh_refuses_a_stack_broken_after_open() {
        let (fx, mut repo) = open_fixture();
        write_repo_config(&fx.path, "not = = toml\n");
        let err = repo
            .refresh_settings(&mut Vec::new())
            .expect_err("invalid TOML must refuse");
        assert!(matches!(err, MutateError::Config { .. }), "got {err:?}");

        std::fs::write(fx.path.join(".jj").join("repo").join("config-id"), "bad").unwrap();
        let err = repo
            .refresh_settings(&mut Vec::new())
            .expect_err("a malformed config-id must refuse");
        assert!(matches!(err, MutateError::Config { .. }), "got {err:?}");
    }

    /// Story 9.37: the start-up fix-up runs BEFORE the fingerprint, so after a migration — at
    /// open and at verb start — the stored fingerprint equals a fresh one and the next refresh
    /// reloads nothing. A reload would replace the handle and drop the sentinel report.
    #[test]
    fn a_fix_up_leaves_no_redundant_reload_behind() {
        test_helpers::pin_test_env();
        let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
        write_repo_config(&fx.path, "[test]\nmarker = \"legacy\"\n");
        let opened = Repo::open_with_report(&fx.path);
        let kinds: Vec<_> = opened.warnings.iter().map(|w| w.kind).collect();
        assert_eq!(kinds, [crate::WarningKind::ConfigMigrated]);
        let mut repo = opened.result.expect("fixture opens");
        let fresh = |repo: &Repo| {
            crate::config::stack_fingerprint(repo.workspace.repo_path(), repo.workspace.workspace_root())
                .expect("fingerprint")
        };
        assert_eq!(repo.stack_fingerprint, fresh(&repo), "post-fix-up at open");

        let assert_no_reload = |repo: &mut Repo| {
            repo.pending_precondition = Some(crate::Precondition::default());
            let mut warnings = Vec::new();
            repo.refresh_settings(&mut warnings).expect("refresh");
            assert!(warnings.is_empty(), "{warnings:?}");
            assert!(repo.pending_precondition.is_some(), "no reload replaced the handle");
        };
        assert_no_reload(&mut repo);

        std::fs::write(fx.path.join(".jj").join("workspace-config.toml"), "[test]\nws = true\n")
            .expect("legacy workspace config written");
        let mut warnings = Vec::new();
        repo.refresh_settings(&mut warnings)
            .expect("the verb-start fix-up migrates");
        let kinds: Vec<_> = warnings.iter().map(|w| w.kind).collect();
        assert_eq!(kinds, [crate::WarningKind::ConfigMigrated]);
        assert_eq!(repo.stack_fingerprint, fresh(&repo), "post-fix-up at verb start");
        assert_no_reload(&mut repo);
    }

    #[test]
    fn refresh_reports_a_workspace_that_no_longer_loads_as_backend() {
        let (fx, mut repo) = open_fixture();
        write_repo_config(&fx.path, "[user]\nname = \"Changed\"\n");
        std::fs::remove_file(fx.path.join(".jj").join("working_copy").join("type")).unwrap();
        let err = repo
            .refresh_settings(&mut Vec::new())
            .expect_err("an unloadable workspace must refuse");
        assert!(matches!(err, MutateError::Backend(_)), "got {err:?}");
    }

    /// Story 9.33: the clone rollback removes `.jj/`, treats an absent one as removed, and turns
    /// any other failure into the CLI's clean-up warning — naming the target and the I/O error.
    #[cfg(unix)]
    #[test]
    fn a_clone_rollback_that_cannot_remove_jj_warns_like_the_cli() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::tempdir().unwrap();
        let target = std::fs::canonicalize(tmp.path()).unwrap();
        let jj = target.join(".jj");
        std::fs::create_dir(&jj).unwrap();
        std::fs::write(jj.join("held"), "x").unwrap();
        std::fs::set_permissions(&jj, std::fs::Permissions::from_mode(0o555)).unwrap();

        let warning = super::roll_back_clone(&target);
        std::fs::set_permissions(&jj, std::fs::Permissions::from_mode(0o755)).unwrap();

        let warning = warning.expect("a `.jj/` whose entries cannot be removed must warn");
        assert_eq!(warning.kind, crate::WarningKind::CloneCleanupFailed);
        let prefix = format!("Failed to clean up {}: ", target.display());
        assert!(warning.message.starts_with(&prefix), "got {:?}", warning.message);
        assert!(jj.join("held").exists(), "a failed removal leaves the entry in place");

        assert_eq!(super::roll_back_clone(&target), None, "now removable: no warning");
        assert!(!jj.exists());
        assert_eq!(super::roll_back_clone(&target), None, "an absent `.jj/` is no failure");
    }

    /// A secondary workspace whose `.jj/repo` FILE points nowhere fails in the loader, before
    /// any config is read.
    #[test]
    fn open_reports_a_dangling_secondary_workspace_as_backend() {
        test_helpers::pin_test_env();
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join(".jj")).unwrap();
        std::fs::write(tmp.path().join(".jj").join("repo"), "../nowhere").unwrap();
        let err = Repo::open(tmp.path()).expect_err("a dangling indirection must refuse");
        assert!(matches!(err, RepoError::Backend(_)), "got {err:?}");
    }
}
