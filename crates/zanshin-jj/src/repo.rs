// SPDX-License-Identifier: MIT

use std::ops::ControlFlow;
use std::path::{Path, PathBuf};

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::settings::UserSettings;
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
    /// jj workspace clone failed (init, remote registration, a fetch failure other than the `git`
    /// subprocess's — e.g. rejected ref updates —, import, or checkout).
    #[error("clone failed: {reason}")]
    CloneFailed {
        /// Human-readable failure reason from jj-lib.
        reason: String,
        /// The CLI's hint lines for it (Story 9.56) — a remote name jj refuses, or a ref pattern
        /// that cannot become refspecs, carry the fetch's hints; empty otherwise.
        hints: Vec<String>,
    },
    /// [`Repo::clone`]'s `git` subprocess failed (Story 9.20 closing run) — the fetch or the
    /// default-branch query could not reach, authenticate against or talk to the source:
    /// network, authentication or transport, or `git` could not be run.
    #[error("network error: {reason}")]
    NetworkError {
        /// The git failure (jj-lib's message with its cause).
        reason: String,
    },
    /// [`Repo::clone`]'s cancel token was cancelled (Story 9.52): the clone refused at a
    /// checkpoint, or its `git` failed after the cancel killed it. Inside the clean-up scope, so
    /// what the clone created is removed.
    #[error("cancelled")]
    Cancelled,
    /// [`Repo::clone`]'s destination is a file or a non-empty directory (Story 9.20) — the CLI's
    /// "Destination path exists and is not an empty directory"; refused before anything is
    /// created.
    #[error("destination path exists and is not an empty directory: {path}")]
    DestinationNotEmpty {
        /// The destination, as the caller spelled it.
        path: PathBuf,
    },
    /// [`Repo::init`] with `--no-colocate` over a directory that holds `.git/` (Story 9.20) — the
    /// CLI's "Did not create a jj repo because there is an existing Git repo in this directory."
    #[error("did not create a jj repo because there is an existing Git repo in this directory: {path}")]
    GitRepoExists {
        /// The canonical destination.
        path: PathBuf,
    },
    /// The arguments are structurally invalid (Story 9.20): a clone pattern that does not
    /// parse, a clone remote name jj refuses, or a Git-only flag for the native backend.
    #[error("invalid input: {reason}")]
    InvalidInput {
        /// Human-readable reason, the CLI's text where it has one.
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
    /// A conversion failed; what it wrote up to the failure stays on disk, as the CLI leaves it,
    /// and [`CreationOutcome::left_behind`] names what it created.
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

impl RepoError {
    /// The jj CLI's hint lines for this refusal, verbatim and in the CLI's order (Story 9.56) —
    /// `init`'s existing-Git-repo hint (`cli/src/commands/git/init.rs:233-236` @ v0.46.0) and a
    /// clone's fetch hints; empty otherwise. `NotARepo` carries none: it does not tell a `.git`
    /// directory apart, so the CLI's "It looks like this is a git repo." hint is not ported.
    #[must_use]
    pub fn hints(&self) -> Vec<String> {
        match self {
            Self::GitRepoExists { .. } => vec![
                "To create a repo backed by the existing Git repo, run `jj git init --colocate` instead.".to_owned(),
            ],
            Self::CloneFailed { hints, .. } => hints.clone(),
            _ => Vec::new(),
        }
    }
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
    /// The state it describes stays on disk: no creation path rolls a conversion back.
    pub precondition: Option<crate::Precondition>,
    /// The call's warnings in the CLI's print order, including those recorded before a failure.
    pub warnings: Vec<crate::Warning>,
    /// What a FAILED [`Repo::init`] (Story 9.58) or conversion ([`crate::convert_colocated`],
    /// [`crate::convert_import`]; Story 9.57) created and left on disk, outermost first: the
    /// destination this call created (one level, the CLI's `create_or_reuse_dir`; an existing one
    /// is reused and never listed), then the workspace's `.jj/` (only when this call's jj-lib
    /// creation returned `Ok`) — each only when it still exists after the failure, known from the
    /// creating calls' own results, never from a check before them. A later entry may lie inside
    /// an earlier one (the created destination and its `.jj/`). The paths are canonical (the
    /// caller's spelling only when canonicalizing the just-created destination itself failed).
    /// Nothing is deleted; the UI may offer the decision. A failure after the `trunk()` alias
    /// step also leaves the secure-config directory `<config_dir>/jj/repos/<config-id>/`, as the
    /// CLI does — it is not listed here; nor is the `.git/` a failed NEW colocated init leaves.
    /// Empty on success, on every refusal that wrote nothing, and for [`Repo::clone`] (which
    /// removes what it created itself) and [`Repo::open_with_report`].
    pub left_behind: Vec<PathBuf>,
}

/// Selects the jj backend for a new workspace.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
    /// Whether the current call runs with `trunk()` = `root()` because the `trunk()` alias did not
    /// resolve at its start (Story 9.56, see [`Repo::start_call`]); [`crate::config::load`] then
    /// adds the overriding layer. Decided afresh at the start of every call that snapshots.
    trunk_fallback: bool,
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
            trunk_fallback: false,
        })
    }

    /// Whether the current call runs with the start-up `trunk()` fallback (Story 9.56).
    pub(crate) fn trunk_fallback(&self) -> bool {
        self.trunk_fallback
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
    /// (Story 9.26) — `cli/src/cli_util.rs:473-517` @ v0.46.0.
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
    ///    a stale working copy, under the lock (`cli_util.rs:500` @ v0.46.0); `true` recovers
    ///    the working copy right there and the verb continues (Story 9.23, see
    ///    [`crate::Precondition::stale_recovery`]).
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
        let (config, colocated, env) = self.start_call()?;
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
        let auto_stats = result?;
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

    /// The start of every call that snapshots — the pre-verb precondition and
    /// [`Repo::workspace_update_stale`] — and of [`Repo::op_integrate`] and the named
    /// [`Repo::resolve_workspace_root`]: [`Repo::start_command`], the colocation check, the
    /// start-up environment ([`crate::snapshot::CommandEnv`], built before any lock is taken),
    /// then the `trunk()` fallback ([`Repo::fall_back_on_trunk`]).
    ///
    /// # Errors
    ///
    /// Any [`crate::PreconditionError`] of those steps; the empty report stays behind.
    fn start_call(
        &mut self,
    ) -> Result<(jj_lib::config::StackedConfig, bool, crate::snapshot::CommandEnv), crate::PreconditionError> {
        let config = self.start_command()?;
        let colocated = crate::wc_ops::is_colocated_git_workspace(&self.workspace)
            .map_err(|e| crate::PreconditionError::Backend(crate::mutate::flatten_chain(&e)))?;
        let env = crate::snapshot::CommandEnv::load(&self.workspace, &config, &mut self.pending_warnings)?;
        let (config, env) = self.fall_back_on_trunk(config, env)?;
        Ok((config, colocated, env))
    }

    /// The part of the CLI's `run_internal` every command runs (`cli/src/cli_util.rs:4630-4750`
    /// @ v0.46.0): [`Repo::refresh_settings`] (the secure-config fix-up — its warnings the call's
    /// first, also when it fails — and the settings re-derived), a fresh report and warning
    /// collector, then the effective config with its migrations' "Deprecated … config" warnings
    /// right after the fix-up's (Story 9.9).
    ///
    /// # Errors
    ///
    /// Any [`crate::PreconditionError`] of those steps; the empty report stays behind.
    fn start_command(&mut self) -> Result<jj_lib::config::StackedConfig, crate::PreconditionError> {
        self.trunk_fallback = false;
        let mut fix_ups = Vec::new();
        let refreshed = self.refresh_settings(&mut fix_ups);
        self.pending_precondition = Some(crate::Precondition::default());
        self.pending_warnings = crate::warning::Warnings::default();
        self.pending_warnings.extend(fix_ups);
        refreshed?;
        let (config, deprecations) = crate::config::load_migrated(self)?;
        self.pending_warnings
            .extend(crate::config::deprecation_warnings(deprecations));
        Ok(config)
    }

    /// The CLI's `trunk()` fallback in `load_from_workspace` (`cli/src/cli_util.rs:540-562` @
    /// v0.46.0; Story 9.56): when the `trunk()` alias parses but does not resolve at the head, the
    /// call warns [`crate::WarningKind::TrunkAliasUnresolved`] ("Failed to resolve
    /// `revset-aliases.trunk()`: <error>" + "The `trunk()` alias is temporarily set to
    /// `root()`."; the CLI's hint line is dropped, as on every warning) and runs with `trunk()` =
    /// `root()` — the config re-read with the overriding layer and the start-up environment
    /// (immutable set, short-prefixes) re-parsed from it, the CLI's `reload_revset_expressions`.
    /// Every later [`crate::config::load`] of the call carries the layer, so the verb's own
    /// revsets (a graph walk's `builtin_log()`, a user's `trunk()`) see it too.
    ///
    /// Only a `trunk()` a non-default layer defines can fail; otherwise nothing is loaded.
    ///
    /// # Errors
    ///
    /// - [`crate::PreconditionError::Backend`] — the head could not be loaded (as the snapshot's
    ///   own head load reports it).
    /// - [`crate::PreconditionError::Config`] — the re-read config or environment fails.
    fn fall_back_on_trunk(
        &mut self,
        config: jj_lib::config::StackedConfig,
        env: crate::snapshot::CommandEnv,
    ) -> Result<(jj_lib::config::StackedConfig, crate::snapshot::CommandEnv), crate::PreconditionError> {
        if !crate::config::trunk_alias_redefined(&config) {
            return Ok((config, env));
        }
        let head = crate::snapshot::load_head(&self.workspace)?;
        // The alias tables' warnings are the environment's, already recorded once for the call.
        let revset = crate::revset::revset_config(&config, &mut crate::warning::Warnings::default())?;
        let Some(reason) = crate::revset::trunk_resolution_error(&self.workspace, &revset, head.as_ref()) else {
            return Ok((config, env));
        };
        self.pending_warnings.push(
            crate::WarningKind::TrunkAliasUnresolved,
            format!(
                "Failed to resolve `revset-aliases.trunk()`: {reason}\n\
                 The `trunk()` alias is temporarily set to `root()`."
            ),
        );
        self.trunk_fallback = true;
        let reloaded = crate::config::load(self)
            .map_err(crate::PreconditionError::from)
            .and_then(|config| {
                let env = crate::snapshot::CommandEnv::load(&self.workspace, &config, &mut self.pending_warnings)?;
                Ok((config, env))
            });
        if reloaded.is_err() {
            self.trunk_fallback = false;
        }
        reloaded
    }

    /// Runs the precondition, then `verb` with its context — and keeps the call's warnings for
    /// [`Repo::take_warnings`] on EVERY path: a failed precondition, a failed verb, a success.
    fn with_verb<T, E: From<crate::PreconditionError>>(
        &mut self,
        verb: impl FnOnce(&mut Self, &mut crate::snapshot::VerbContext) -> Result<T, E>,
    ) -> Result<T, E> {
        self.with_verb_stats(true, verb)
    }

    /// [`Repo::with_verb`] for a verb whose CLI counterpart refuses some argument combinations in
    /// clap: `args` (the verb's pure check) refuses where clap refuses — after the start-up
    /// secure-config fix-up (`reload_repo_config` runs before `parse_args`,
    /// `cli/src/cli_util.rs:4667`, `:4692` @ v0.46.0) and BEFORE the pre-verb snapshot, which only
    /// the command body runs. A refused call writes no operation and leaves no precondition
    /// report; its warnings are the fix-up's.
    fn with_checked_verb<T>(
        &mut self,
        args: Result<(), crate::MutateError>,
        verb: impl FnOnce(&mut Self, &mut crate::snapshot::VerbContext) -> Result<T, crate::MutateError>,
    ) -> Result<T, crate::MutateError> {
        let Err(refusal) = args else {
            return self.with_verb(verb);
        };
        self.refuse_before_snapshot()?;
        Err(refusal)
    }

    /// The part of a clap-level refusal that still runs: the start-up secure-config fix-up, its
    /// warnings the call's own, and no precondition report — see [`Repo::with_checked_verb`].
    ///
    /// # Errors
    ///
    /// What [`Repo::refresh_settings`] returns.
    fn refuse_before_snapshot(&mut self) -> Result<(), crate::MutateError> {
        let mut fix_ups = Vec::new();
        let refreshed = self.refresh_settings(&mut fix_ups);
        self.pending_precondition = None;
        self.pending_warnings = crate::warning::Warnings::default();
        self.pending_warnings.extend(fix_ups);
        refreshed
    }

    /// [`Repo::with_verb`] with the precondition's snapshot-stats warnings switched by
    /// `warn_stats` (see [`Repo::precondition`]).
    fn with_verb_stats<T, E: From<crate::PreconditionError>>(
        &mut self,
        warn_stats: bool,
        verb: impl FnOnce(&mut Self, &mut crate::snapshot::VerbContext) -> Result<T, E>,
    ) -> Result<T, E> {
        let result = match self.precondition(warn_stats) {
            Ok(mut ctx) => {
                let result = verb(self, &mut ctx);
                self.pending_warnings = std::mem::take(&mut ctx.warnings);
                result
            }
            Err(e) => Err(e.into()),
        };
        // The `trunk()` fallback is the call's alone (Story 9.56): a later load outside a call —
        // `log_defaults` — must not see its layer.
        self.trunk_fallback = false;
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
    /// ONLY where a verb runs the precondition or the command start-up without it
    /// ([`Repo::op_integrate`], [`Repo::resolve_workspace_root`]): such a verb starts a fresh
    /// list and leaves it behind — on success AND on failure (then everything up to the
    /// failure). Verbs that run neither ([`Repo::workspace_root`], [`Repo::log_defaults`],
    /// [`Repo::commit_contents`]) neither reset nor add to it, so a take after one of them
    /// returns whatever an earlier verb left untaken. A caller takes the list after each
    /// start-up-running verb, as the FFI layer does for every envelope it builds for one.
    #[must_use]
    pub fn take_warnings(&mut self) -> Vec<crate::Warning> {
        self.pending_warnings.take()
    }

    /// Returns the working-copy status: files changed between `@` and `@-`.
    ///
    /// Runs the pre-verb snapshot first (Story 9.26), exactly like `jj status`, so on-disk
    /// edits made outside Zanshin are part of `@`. Re-resolves to head on every call
    /// (ADR-0002). A workspace without a working-copy commit (a root restore, an undo to the
    /// root view) is no error, as the CLI's `jj status` prints "No working copy." and succeeds:
    /// the status then has no files and both change ids are `None`.
    ///
    /// # Errors
    ///
    /// Returns [`crate::StatusError::Precondition`] if the pre-verb snapshot failed, or
    /// [`crate::StatusError::Backend`] on jj-lib failure.
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
    /// - [`crate::OpLogError::Backend`] — the head load or the op-store walk failed; the
    ///   jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn op_log(&mut self, limit: Option<usize>) -> Result<Vec<crate::Operation>, crate::OpLogError> {
        self.with_verb(|repo, _ctx| crate::op_log::op_log(repo.workspace(), limit))
    }

    /// Lists the rows `jj bookmark list` prints for `options`, in the CLI's order (FR-JJ-8,
    /// Stories 9.29 and 9.19). `BookmarkListOptions::default()` is the CLI without arguments: the
    /// local bookmarks plus the tracked remote rows that differ from them; `all_remotes` is
    /// `--all-remotes`' row set — every local row (present, or deleted while still tracking a
    /// remote), every tracked remote row (synced or not, present or not created yet) and every
    /// untracked remote row.
    ///
    /// The filters are the CLI's: `names` (string PATTERNS, a bare one a glob) OR-ed with
    /// `revisions` (revsets matching LOCAL targets), `remotes` (remote-name patterns), `tracked`,
    /// `conflicted`. The rows come as the CLI prints them: each local row followed by its tracked
    /// remote rows, a name's untracked remote rows after that, in name order — then re-sorted by
    /// `sort` or, when it is empty, `ui.bookmark-list-sort-keys` (default `["name"]`). An exact
    /// name that matches no local or remote bookmark warns `jj.bookmark_names_unmatched`.
    ///
    /// Each row carries its target change id (`None` when absent; a conflicted target resolves
    /// to the first added commit's change id), `conflicted` and `synced`; a remote row also
    /// carries `tracked` and, when tracked with both targets present, the CLI's ahead/behind
    /// distances to the local target. Runs the pre-verb snapshot first (Story 9.26) and
    /// re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj bookmark list` (AR-AP-1).
    ///
    /// # Errors
    ///
    /// - [`crate::BookmarkError::InvalidInput`] — `all_remotes` with `remotes`, `tracked` or
    ///   `conflicted` (clap's conflict, refused before the snapshot), or a name or remote pattern
    ///   does not parse.
    /// - [`crate::BookmarkError::RevsetParseError`] / [`crate::BookmarkError::RevsetResolutionError`]
    ///   — a `revisions` text.
    /// - [`crate::BookmarkError::Config`] — `ui.bookmark-list-sort-keys` is not an array of the
    ///   CLI's key names, or the revset aliases do not load.
    /// - [`crate::BookmarkError::Precondition`] — the pre-verb snapshot failed.
    /// - [`crate::BookmarkError::Backend`] — the head load, a store read or a distance revset
    ///   failed; the jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_bookmarks(
        &mut self,
        options: &crate::BookmarkListOptions,
    ) -> Result<Vec<crate::Bookmark>, crate::BookmarkError> {
        if let Err(refusal) = crate::bookmarks::check_list_flags(options) {
            self.refuse_before_snapshot()
                .map_err(|e| crate::BookmarkError::Precondition(e.into()))?;
            return Err(refusal);
        }
        self.with_verb(|repo, ctx| {
            crate::bookmarks::list_bookmarks(repo.workspace(), &ctx.config, &mut ctx.warnings, options)
        })
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
    /// - [`crate::ViewError::Backend`] — the head load or a store read failed; the jj-lib
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
    /// - [`crate::ViewError::Backend`] — the head load failed; the jj-lib reason is forwarded
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
    /// - [`crate::ViewError::Backend`] — the head load failed; the jj-lib reason is forwarded
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
    /// - [`crate::RemoteError::Backend`] — the head load failed; the jj-lib
    ///   reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_remotes(&mut self) -> Result<Vec<crate::Remote>, crate::RemoteError> {
        self.with_verb(|repo, _ctx| crate::remotes::list_remotes(repo.workspace()))
    }

    /// The remotes `jj git push` WITHOUT `--remote` would push to (Story 9.54), in remote-name
    /// order — the CLI's default-remote resolution (`push.rs:294-323`, `get_default_push_remotes`
    /// `:1107-1130` @ v0.46.0), shared with [`Repo::git_push`]: the remotes `git.push` names (a
    /// name, a list or a pattern), else the single remote, else `origin` — each kept only when it
    /// exists. An exact name no remote carries warns `jj.push_remotes_unmatched`, as the push does
    /// — a `git.push` name, and the implicit `origin` too (so a repo with no remote, or several
    /// without `origin`, warns "No matching remotes for names: origin"). No match is `Ok(vec![])`
    /// (the push itself refuses "No git remotes to push to"), and so is a non-Git (native) backend.
    ///
    /// For the GUI's "ahead" rule: only a push target's missing remote bookmark makes a bookmark
    /// ahead. Writes NO operation of its own — only the pre-verb snapshot's, like every read.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::Config`] — `git.push` is neither a string nor a list of strings.
    /// - [`crate::MutateError::InvalidInput`] — a `git.push` pattern does not parse.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_push_remotes(&mut self) -> Result<Vec<String>, crate::MutateError> {
        self.with_verb(|repo, ctx| {
            crate::push::default_remote_names(
                repo.workspace(),
                &ctx.config,
                crate::push::PUSH_REMOTES,
                &mut ctx.warnings,
            )
        })
    }

    /// The remotes `jj git fetch` WITHOUT `--remote` would fetch from (Story 9.30), in
    /// remote-name order — the CLI's `get_default_fetch_remotes` (`fetch.rs:267-290` @ v0.46.0),
    /// shared with [`Repo::git_fetch`]'s [`crate::FetchRemotes::Default`]: the remotes `git.fetch`
    /// names (a name, a list or a pattern), else the single remote, else `origin` — each kept only
    /// when it exists. An exact name no remote carries warns `jj.fetch_remotes_unmatched`, as the
    /// fetch does — a `git.fetch` name, and the implicit `origin` too. No match is `Ok(vec![])`
    /// (the fetch itself refuses "No git remotes to fetch from"), and so is a non-Git (native)
    /// backend. The only-remote hint the fetch reports is dropped.
    ///
    /// The Fetch button's enable rule: enabled when this is not empty. Writes NO operation of its
    /// own — only the pre-verb snapshot's, like every read.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::Config`] — `git.fetch` is neither a string nor a list of strings.
    /// - [`crate::MutateError::InvalidInput`] — a `git.fetch` pattern does not parse.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_fetch_remotes(&mut self) -> Result<Vec<String>, crate::MutateError> {
        self.with_verb(|repo, ctx| {
            crate::push::default_remote_names(
                repo.workspace(),
                &ctx.config,
                crate::push::FETCH_REMOTES,
                &mut ctx.warnings,
            )
        })
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
    /// - [`crate::FileError::InvalidInput`] — a `paths` entry is not a valid repo path, or an
    ///   absent `revision`'s `@` in a workspace with no working-copy commit ("Workspace `<name>`
    ///   doesn't have a working-copy commit"; this holds for all four file reads).
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
    /// - [`crate::RevsetError::Precondition`] — the pre-verb snapshot failed, its start-up
    ///   environment included: a broken `[template-aliases]` table, or an effective
    ///   `revsets.short-prefixes` that is not a string or does not parse, refuses here.
    /// - [`crate::RevsetError::ParseError`] — any expression is syntactically invalid; for
    ///   `short_prefixes` only an override that differs from the effective text (the effective
    ///   one refuses earlier, at start-up).
    /// - [`crate::RevsetError::ResolutionError`] — a symbol in `revset` or `prioritize`
    ///   cannot be resolved. An unresolvable `short_prefixes` is NOT an error: like the
    ///   CLI, it warns and degrades to full-index prefix lengths.
    /// - [`crate::RevsetError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable. A single bad `[revset-aliases]` entry is NOT an error: like the CLI, it
    ///   warns and is skipped.
    /// - [`crate::RevsetError::JjLibError`] — the head load, evaluation, metadata
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
    /// - [`crate::RevsetError::Precondition`] — the pre-verb snapshot failed, its start-up
    ///   environment included: a broken `[template-aliases]` table, or an effective
    ///   `revsets.short-prefixes` that is not a string or does not parse, refuses here.
    /// - [`crate::RevsetError::ParseError`] — any expression, an anchor included, is
    ///   syntactically invalid; raised before the repo is loaded. For `short_prefixes` only an
    ///   override that differs from the effective text (the effective one refuses earlier, at
    ///   start-up).
    /// - [`crate::RevsetError::ResolutionError`] — a symbol in `revset`, `prioritize` or an
    ///   anchor cannot be resolved. An unresolvable `short_prefixes` only warns and degrades.
    /// - [`crate::RevsetError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable.
    /// - [`crate::RevsetError::DanglingEdge`] — an edge names a target outside the node set
    ///   (jj-lib's stream contract rules it out).
    /// - [`crate::RevsetError::JjLibError`] — the head load, evaluation, a per-node index
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
    /// - [`crate::RevsetError::JjLibError`] — the head load, evaluation, or a per-item
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
    /// (AR-AP-1). `description` may be empty (jj convention). A non-empty `description` gets
    /// `templates.commit_trailers` added, as `jj describe -m` does (Story 9.51); an empty one
    /// gets none. A `description` equal to the stored one (compared after the trailers, as the
    /// CLI) writes no operation — `jj describe`'s "Nothing changed." (Story 9.40) — and the
    /// result carries the pre-call head op id.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::ChangeNotFound`] — `change_id` is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::InvalidInput`] — `change_id` resolves to the root commit.
    /// - [`crate::MutateError::Immutable`] — `change_id` resolves to a non-root commit
    ///   inside the repo's effective immutable set.
    /// - [`crate::MutateError::Config`] — the `revset-aliases."immutable_heads()"` alias does not
    ///   resolve against the repo; or a template fault, before anything is written (Story 9.51):
    ///   a non-empty `templates.commit_trailers` (parsed whatever `description` is, as the CLI
    ///   does) that does not parse (`Failed to parse template: …`) or renders no valid trailer
    ///   block (`Trailers should be valid utf-8`, jj-lib's trailer-parse text), or a non-string
    ///   template key.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including a jj config, `immutable_heads()` alias, `[template-aliases]` table or
    ///   `revsets.short-prefixes` that does not read or parse (the start-up environment, as for
    ///   every verb).
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

    /// Creates a new, empty change and switches the working copy to it (FR-JJ-10a) — the CLI's
    /// `jj new <parents>`, `jj new -A <insert_after>` and `jj new -B <insert_before>` (Story 9.48).
    ///
    /// The three lists are the CLI's positional revisions, `--insert-after` and
    /// `--insert-before`; an EMPTY list means the flag was not given. Positional `parents` cannot
    /// be combined with either insert list, and at least one list must be non-empty (there is no
    /// `@` default — the caller passes `@` explicitly). Each list resolves in argument order with
    /// duplicates dropped, so `[c, c]` is ONE parent.
    ///
    /// - `parents`: the new change sits on them — a merge commit for two or more — and nothing
    ///   is rebased.
    /// - `insert_after` (`-A`): the new change sits on the targets and their children are
    ///   rebased onto it.
    /// - `insert_before` (`-B`): the new change sits on the targets' parents and the targets
    ///   are rebased onto it.
    /// - both: the new change sits on `insert_after` and `insert_before` is rebased onto it.
    ///
    /// A rebased child keeps every parent that is not one of the new change's parents, those
    /// are replaced by the new change, and the new change is appended once. Descendants follow.
    ///
    /// Only without `-A`/`-B` and with exactly one parent, the bookmarks
    /// `experimental-advance-branches` selects (enabled ∩ ¬disabled; the default
    /// `enabled-branches = []` selects none) move from that parent's parents to the parent, as the
    /// CLI's `jj new` does (Story 9.49 closing run). Any other shape never reads that config.
    ///
    /// There is no `-m`: the new change's description is `templates.new_description` rendered on
    /// it (default `''`: none), and a non-empty one gets `templates.commit_trailers` (Story 9.51).
    ///
    /// # Errors
    ///
    /// Every refusal happens before the first write; nothing is written.
    ///
    /// - [`crate::MutateError::InvalidInput`] — `parents` combined with an insert list, or all
    ///   three lists empty (both before the snapshot, as clap refuses the first); (Git backend)
    ///   two or more parents — positional, or computed by `-A`/`-B` —
    ///   including the root commit, with the Git backend's own text, "The Git backend does not
    ///   support creating merge commits with the root commit as one of the parents." (Story
    ///   9.31); (`-A`/`-B`) the location would create a loop (`Refusing to create a loop: commit
    ///   <12 hex> would be both an ancestor and a descendant of the new commit`); or (one
    ///   positional parent) an `experimental-advance-branches` pattern does not parse.
    /// - [`crate::MutateError::ChangeNotFound`] — an id is malformed, absent, only-hidden, or
    ///   divergent.
    /// - [`crate::MutateError::Immutable`] — (`-A`/`-B`) a commit to rebase is inside the repo's
    ///   effective immutable set; the first offender's hex.
    /// - [`crate::MutateError::Config`] — the `revset-aliases."immutable_heads()"` alias does not
    ///   resolve against the repo (with or without `-A`/`-B`: the CLI's `tx.finish` resolves it
    ///   for every write, Story 9.56); (one positional parent) an
    ///   `experimental-advance-branches` key is not a list of strings; or a template fault
    ///   (Story 9.51): a non-empty `templates.new_description` — or, for a non-empty description,
    ///   `templates.commit_trailers` — that does not parse or render (the CLI's texts, see
    ///   [`Repo::describe`]).
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including an effective jj config that changed and no longer reads (see
    ///   [`Repo::open`]); refused before the verb itself runs.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn new_change(
        &mut self,
        parents: &[crate::ChangeId],
        insert_after: &[crate::ChangeId],
        insert_before: &[crate::ChangeId],
    ) -> Result<crate::MutationResult, crate::MutateError> {
        let args = crate::mutate::check_new_args(parents, insert_after, insert_before);
        self.with_checked_verb(args, |repo, ctx| {
            crate::mutate::new_change(repo.workspace_mut(), ctx, parents, insert_after, insert_before)
        })
    }

    /// Switches the working copy to `change_id` without creating a new commit
    /// (FR-JJ-10a).
    ///
    /// Editing the commit that already is a non-discardable `@` changes nothing, so no operation
    /// is written and the result carries the pre-call head op id — the CLI's "Already editing that
    /// commit." (Story 9.40); a discardable current `@` remains Story 9.38's.
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
    /// freshly-committed op — unless the restored view equals the current one: then, as `jj undo`
    /// ("Nothing changed."; Story 9.40), no operation is written and the result carries the
    /// pre-call head op id. `allow_cross_workspace` is the CLI's `--allow-cross-workspace`
    /// (default `false`): without it, an operation performed in another workspace is not undone.
    /// Undoing a push or a workspace removal warns (`jj.undo_push_operation`,
    /// `jj.undo_workspace_removal`). A restored view without this workspace's working-copy commit
    /// (undo to the root view) leaves `working_copy_change_id` `None` and warns
    /// `jj.workspace_no_longer_exists` (Story 9.12). See `op_log::undo` for the step.
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

    /// Redoes the most recently undone operation — the CLI's `jj redo` @ v0.46.0 (Story 9.21),
    /// `undo`'s counterpart: repeated `undo` / `redo` calls act like a text editor's undo / redo,
    /// and a redo stack the CLI started is continued here (and vice versa) — the stack lives in
    /// the operation descriptions.
    ///
    /// Restores the view of the undone operation's parent (repo state + local bookmarks/tags +
    /// remote-tracking bookmarks, `git_refs`/`git_heads` untouched), committed as
    /// `redo: restore to operation <hex>` — or, when that view equals the current one, no
    /// operation and the pre-call head op id (Story 9.40). `allow_cross_workspace` is the CLI's
    /// `--allow-cross-workspace` (default `false`). A restored view without this workspace's
    /// working-copy commit leaves `working_copy_change_id` `None` and warns
    /// `jj.workspace_no_longer_exists` (Story 9.12). See `op_log::redo` for the step.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::NothingToRedo`] — the head is no undo operation (nor a redo of one).
    /// - [`crate::MutateError::RedoCrossWorkspace`] — the undo operation to redo was performed in
    ///   another workspace and `allow_cross_workspace` is `false`.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Config`] — the finish's immutable set does not resolve.
    /// - [`crate::MutateError::Backend`] — a redo/undo description names no valid operation, the
    ///   undo operation has more than one parent, or an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn redo(&mut self, allow_cross_workspace: bool) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::op_log::redo(repo.workspace_mut(), ctx, allow_cross_workspace))
    }

    /// Shows one operation and its repository changes against its parent — the CLI's
    /// `jj op show` @ v0.46.0 (Story 9.21), as typed data instead of templates.
    ///
    /// `operation` is the CLI's argument (`"@"` is its default): `@`, `@-`, `@+`, an id prefix,
    /// resolved at the head after the pre-verb snapshot. `show_changes_in` is
    /// `--show-changes-in`; `None` reads `revsets.op-diff-changes-in` (default
    /// `mutable() | immutable_heads()`). An operation with more than one parent has no diff, as
    /// in the CLI. Writes no operation beyond the pre-verb snapshot's (a merge op's parents are
    /// merged into an unpublished operation, as the CLI merges them).
    ///
    /// # Warnings
    ///
    /// Revset parse diagnostics (`jj.revset_diagnostic`, "In `--show-changes-in`" / "In
    /// `revsets.op-diff-changes-in`"), and `jj.op_diff_changes_unresolved` when the revset does not
    /// resolve against one of the two operations — then the diff has no commit section.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::OperationNotFound`] — no operation matches the id prefix.
    /// - [`crate::MutateError::InvalidInput`] — the expression is no valid prefix, is ambiguous,
    ///   or resolves to no or several operations (with the CLI's hint naming them).
    /// - [`crate::MutateError::Config`] — `revsets.op-diff-changes-in` is not a string or does
    ///   not parse.
    /// - [`crate::MutateError::RevsetParseError`] — `show_changes_in` does not parse.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn op_show(
        &mut self,
        operation: &str,
        show_changes_in: Option<&str>,
    ) -> Result<crate::OpShow, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::op_log::op_show(repo.workspace(), ctx, operation, show_changes_in))
    }

    /// Compares two operations — the CLI's `jj op diff` @ v0.46.0 (Story 9.21), as typed data.
    ///
    /// `options` are the CLI's flags (see [`crate::OpDiffOptions`]): `from` / `to` (a missing one
    /// `@`), or `operation` (default `@`) against its parents; `operation` together with `from` or
    /// `to` is clap's conflict, refused before the snapshot. Writes no operation beyond the
    /// pre-verb snapshot's (several from-operations — a merge op's parents — are merged into an
    /// unpublished operation, as the CLI merges them).
    ///
    /// # Warnings
    ///
    /// As [`Repo::op_show`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `operation` with `from` / `to` (no snapshot, no
    ///   precondition report), or an operation expression as in [`Repo::op_show`].
    /// - Every other error of [`Repo::op_show`].
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn op_diff(&mut self, options: &crate::OpDiffOptions) -> Result<crate::OpDiffResult, crate::MutateError> {
        self.with_checked_verb(crate::op_log::check_op_diff_flags(options), |repo, ctx| {
            crate::op_log::op_diff(repo.workspace(), ctx, options)
        })
    }

    /// Abandons operation history — the CLI's `jj op abandon` @ v0.46.0 (Story 9.21).
    ///
    /// `operation` is the CLI's argument: a range `a..b` (`..<op>` abandons `<op>` and all its
    /// ancestors, `<op>..@-` the recent ones) or one operation. The range's descendants are
    /// reparented onto `a`, the op heads replaced and this workspace's working copy remapped to
    /// the new head. Like the CLI it loads no repo and runs no pre-verb snapshot — only the
    /// start-up secure-config fix-up (so [`Repo::take_precondition`] is `None` afterwards); it
    /// writes no operation, it rewrites the history.
    ///
    /// # Warnings
    ///
    /// The fix-up's, then `jj.op_abandon_working_copy_not_updated` when the working copy is
    /// recorded at an operation that is not a current head.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — the range ends at a current head ("Cannot abandon
    ///   the current operation <id>"), the root operation, a merge operation, or an operation
    ///   expression that does not resolve to one operation. Nothing is written.
    /// - [`crate::MutateError::OperationNotFound`] — no operation matches an id prefix.
    /// - [`crate::MutateError::Config`] — the effective config stack no longer reads.
    /// - [`crate::MutateError::Backend`] — an op-store, op-heads or working-copy failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn op_abandon(&mut self, operation: &str) -> Result<crate::OpAbandonResult, crate::MutateError> {
        self.refuse_before_snapshot()?;
        let mut warnings = std::mem::take(&mut self.pending_warnings);
        let result = crate::op_log::op_abandon(&mut self.workspace, operation, &mut warnings);
        self.pending_warnings = warnings;
        result
    }

    /// Restores the repo to the state at an operation — the CLI's `jj op restore` @ v0.46.0
    /// (Story 9.12), "Restore to here" in an undo timeline.
    ///
    /// `operation` is the CLI's required argument (`@-`, an id prefix, …), resolved at the head
    /// after the pre-verb snapshot. `what` is `--what` (repeatable): [`crate::RestoreWhat::Repo`]
    /// restores heads, local bookmarks/tags and the working-copy commits,
    /// [`crate::RestoreWhat::RemoteTracking`] the remote-tracking bookmarks; an EMPTY list is the
    /// flag absent — both. `git_refs` / `git_heads` stay current. Committed as
    /// `restore to operation <hex>` — or, when the restored view equals the current one, no
    /// operation and the pre-call head op id (Story 9.40). See `op_log::op_restore` for the step.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::OperationNotFound`] — no operation matches the id prefix.
    /// - [`crate::MutateError::InvalidInput`] — the expression is no valid prefix, is ambiguous,
    ///   or resolves to no or several operations (with the CLI's hint naming them).
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Config`] — the finish's immutable set does not resolve.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn op_restore(
        &mut self,
        operation: &str,
        what: &[crate::RestoreWhat],
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::op_log::op_restore(repo.workspace_mut(), ctx, operation, what))
    }

    /// Reverts one operation by applying its inverse — the CLI's `jj op revert` @ v0.46.0
    /// (Story 9.12).
    ///
    /// `operation` is the CLI's argument; `"@"` is its default (pass it for the CLI without the
    /// argument). It resolves at the head after the pre-verb snapshot; its parent's state is
    /// merged in three-way against its own, so later work stays and descendants of rewritten
    /// commits are rebased. `what` is `--what` as in [`Repo::op_restore`] (empty = both).
    /// Committed as `revert operation <hex>` — or, when nothing changed (the operation is already
    /// reverted), no operation and the pre-call head op id (Story 9.40). A revert that drops this
    /// workspace's working-copy commit (of the `add workspace` operation) leaves
    /// `working_copy_change_id` `None` and warns `jj.workspace_no_longer_exists`. See
    /// `op_log::op_revert` for the step.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — "Cannot revert root operation", "Cannot revert a
    ///   merge operation" (nothing written by the verb), or an operation expression as in
    ///   [`Repo::op_restore`].
    /// - Every other error of [`Repo::op_restore`].
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn op_revert(
        &mut self,
        operation: &str,
        what: &[crate::RestoreWhat],
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::op_log::op_revert(repo.workspace_mut(), ctx, operation, what))
    }

    /// Makes an operation part of the operation log — the CLI's `jj op integrate` @ v0.46.0
    /// (Story 9.12): the remedy for an operation jj wrote but never published (an interrupted
    /// command, `--no-integrate-operation`).
    ///
    /// `operation` resolves at the head (an id prefix names an unpublished operation too). The
    /// op heads gain it in place of its parents; when it is a descendant of the head it simply
    /// becomes the head, when it diverges it is merged with the other heads into a
    /// `reconcile divergent operations` operation in this workspace (`reconciled`), and when it
    /// is already in the log nothing changes. Like the CLI's `workspace_helper_no_snapshot`
    /// (`cli/src/cli_util.rs:522-562` @ v0.46.0) it runs the start-up — the secure-config
    /// fix-up, the effective config and its deprecation warnings, the alias tables, the
    /// `immutable_heads()` / short-prefixes parse and the `trunk()` fallback — and the CLI's head
    /// load (which may reconcile divergent heads itself), but NO pre-verb snapshot and no Git
    /// import; [`Repo::take_precondition`] is `None` afterwards, [`Repo::take_warnings`] holds
    /// the start-up's warnings.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::OperationNotFound`] — no operation matches the id prefix; nothing
    ///   is written.
    /// - [`crate::MutateError::InvalidInput`] — the expression is no valid prefix, is ambiguous,
    ///   or resolves to no or several operations.
    /// - [`crate::MutateError::Precondition`] — the start-up failed (a config that no longer
    ///   reads, an alias table, `immutable_heads()` or short-prefixes revset that does not
    ///   parse), or the head could not be loaded; nothing is written.
    /// - [`crate::MutateError::Backend`] — an op-store or op-heads failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn op_integrate(&mut self, operation: &str) -> Result<crate::OpIntegrateResult, crate::MutateError> {
        let result = self
            .start_call()
            .map_err(crate::MutateError::from)
            .and_then(|_| crate::op_log::op_integrate(&self.workspace, operation));
        // No snapshot ran: no report. The `trunk()` fallback is the call's alone, as in
        // `with_verb_stats`.
        self.pending_precondition = None;
        self.trunk_fallback = false;
        result
    }

    /// Pushes bookmarks and tags to git remotes — the CLI's `jj git push` (Story 9.20,
    /// FR-JJ-13b), every `GitPushArgs` parameter passed through. See [`crate::GitPushArgs`] for
    /// the parameters and the `push` module doc for what is ported.
    ///
    /// Runs the pre-verb snapshot first, then ONE transaction: the remotes resolve (`--remote`
    /// patterns, else `git.push`, else the only remote — with the hint "Pushing to the only
    /// existing remote" — else `origin`), the `--change` / `--named` bookmarks are created in the
    /// transaction (each `--change` name rendered from `templates.git_push_bookmark`, Story 9.51 —
    /// the same name in the dry run and the push), the mode's targets are classified per remote — `--all` / `--tracked` /
    /// `--deleted` and the bare push (`revsets.git-push` with `remote` bound) / `-r` skip a refused
    /// ref or a rejected commit with a warning, explicitly named refs refuse the whole push — and
    /// the operation description is built. A dry run returns that plan and writes nothing beyond the
    /// pre-verb snapshot's operation. A real push then signs (`git.sign-on-push`), pushes remote by
    /// remote (progress as `"push"` [`crate::ProgressEvent`]s on `progress`; push progress arrives
    /// mostly as sideband text, so there are few or none), and records the operation when every
    /// ref succeeded or at least one was exported — the CLI's rule. A push whose plan is empty is
    /// [`GitPushOutcome::nothing_changed`](crate::GitPushOutcome::nothing_changed): nothing is
    /// created or written.
    ///
    /// Once the push loop has started, its outcome is data: a lease failure, a remote rejection,
    /// an unexported ref, a remote that could not be reached — per remote and per ref, with the
    /// CLI's failure text in [`crate::GitPushOutcome::failure`] — on `Ok`.
    ///
    /// A cancel of `cancel`'s token (Story 9.52) is data too: the push stops before the next
    /// remote's git push, or when a git push fails after the cancel killed it, and reports
    /// [`crate::PushFailureKind::Cancelled`] with nothing recorded; the per-remote data says
    /// which remotes already got their refs. Once every remote's git push has run, the push
    /// finishes normally.
    ///
    /// # Warnings
    ///
    /// The CLI's `Warning:` lines on this path, in its order: `jj.push_remotes_unmatched`,
    /// `jj.push_bookmarks_unmatched` / `jj.push_tags_unmatched`, revset diagnostics,
    /// `jj.push_revset_empty` / `jj.push_revisions_empty`, `jj.push_ref_skipped` /
    /// `jj.push_commit_skipped` for each skipped ref, `jj.push_signing_skipped_immutable`, the push
    /// stats (`jj.push_refs_moved_on_remote`, `jj.push_remote_rejected`,
    /// `jj.push_bookmarks_not_updated_locally`), and the finish's.
    ///
    /// # Errors
    ///
    /// Every refusal before the network:
    /// - [`crate::MutateError::InvalidInput`] — conflicting flags (before the snapshot, as clap
    ///   refuses them, so nothing is written), a pattern that does not parse,
    ///   "No git remotes to push to", a `--named` argument without `=` or with an empty side or an
    ///   unparsable name, an empty `--change` set.
    /// - [`crate::MutateError::BookmarkExists`] / [`crate::MutateError::BookmarkTrackedRemoteExists`]
    ///   — a `--change` / `--named` name that is taken.
    /// - [`crate::MutateError::PushRefRefused`] / [`crate::MutateError::PushCommitRejected`] — an
    ///   explicitly named ref is refused, or would push a commit that is not ready (a real push).
    /// - [`crate::MutateError::RevsetParseError`] / [`crate::MutateError::RevsetResolutionError`] — a
    ///   revision does not parse or resolve (a `--named` one to exactly one commit).
    /// - [`crate::MutateError::Config`] — a key the push reads is malformed, or `immutable_heads()`
    ///   does not resolve; or (`--change`, Story 9.51) `templates.git_push_bookmark` does not parse
    ///   (`Failed to parse template: …`) or renders a name that is not UTF-8 (`Invalid character in
    ///   bookmark name`) or is empty (`Empty bookmark name generated`).
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no Git backend.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed, including a broken
    ///   `[template-aliases]` table or `revsets.short-prefixes` (the start-up environment, as for
    ///   every verb).
    /// - [`crate::MutateError::Backend`] — any other jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_push(
        &mut self,
        args: &crate::GitPushArgs,
        progress: &crate::ProgressFn,
        cancel: Option<&crate::cancel::CancelGuard>,
    ) -> Result<crate::GitPushOutcome, crate::MutateError> {
        self.with_checked_verb(crate::push::check_flags(args), |repo, ctx| {
            crate::push::git_push(repo, ctx, args, progress, cancel)
        })
    }

    /// `jj git fetch` (FR-JJ-13, Story 9.30): fetches the remotes and refs `args` selects in ONE
    /// transaction and imports them — `cmd_git_fetch` (`cli/src/commands/git/fetch.rs` @ v0.46.0)
    /// minus its terminal output.
    ///
    /// - **Remotes** ([`crate::FetchRemotes`]): `Default` is [`Repo::git_fetch_remotes`]'s
    ///   resolution (`git.fetch`, else the only remote — with the CLI's "Fetching from the only
    ///   existing remote" hint in [`crate::GitFetchOutcome::hints`] unless it is `origin` — else
    ///   `origin`); `Named` the union of its name patterns (a bare word is a glob); `All` every
    ///   remote. An exact name no remote carries warns `jj.fetch_remotes_unmatched`.
    /// - **Refs per remote** ([`crate::FetchRefs`]): `Patterns` are the CLI's `--branch`/`--tag`
    ///   (an empty list fetches none of that kind); `Tracked` the remote's tracked bookmarks and
    ///   tags by exact name; `Default` the remote's `remotes.<name>.fetch-bookmarks`, else the
    ///   Git config's fetch refspecs (each refspec jj ignores warns `jj.fetch_refspec_ignored`),
    ///   and `remotes.<name>.fetch-tags`, else every tag.
    ///
    /// Then one `import_refs` (its failed refs warn `jj.git_import_failed` and land in
    /// [`crate::GitFetchOutcome::failed_ref_names`]; the remote bookmarks and tags it changed land
    /// in [`crate::GitFetchOutcome::changed_bookmarks`] / [`crate::GitFetchOutcome::changed_tags`]
    /// and the count of commits it rewrote in [`crate::GitFetchOutcome::num_rewritten`] — what the
    /// CLI's `print_imported_changes` prints, projected as [`Repo::git_import`] projects them);
    /// with `Patterns`, branch names no matched
    /// remote has warn `jj.fetch_branches_unmatched`. The operation is `fetch from git remote(s)
    /// <names joined by ",">`. It finishes like the CLI's `tx.finish` (Story 9.26): a colocated
    /// workspace exports the fetched refs to Git, and the working copy is checked out at the new
    /// operation. A fetch that changed nothing writes no operation, as the CLI's
    /// `WorkspaceCommandTransaction::finish` ("Nothing changed."; Story 9.40): the mutation's
    /// `new_op_id` is the pre-call head and nothing is exported or checked out.
    ///
    /// `git.abandon-unreachable-commits`, `git.record-synthetic-predecessors` and the
    /// per-remote `remotes.<name>.auto-track-bookmarks` are read from the repo's EFFECTIVE
    /// config per call and never cached (FR-JJ-17), exactly as `fetch.rs:235` takes them off
    /// config.
    ///
    /// The mutation's `abandoned_change_ids` carries the commits jj-lib itself abandoned
    /// during the import because they became unreachable in git — the effect
    /// `git.abandon-unreachable-commits` governs — read from the import's own stats. This
    /// is the one verb where that field is not a caller echo; see
    /// [`crate::MutationResult::abandoned_change_ids`]. `new_change_ids` is always empty.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — no remote matched ("No git remotes to fetch
    ///   from", the CLI's refusal; nothing is written), a name pattern does not parse (a
    ///   `--remote` one is parsed before the remotes are listed, so even without a Git backend), a
    ///   pattern cannot become a refspec (jj-lib's expansion error; an `Expression` one carries
    ///   the CLI's pattern hint), a matched remote's name is one jj cannot use (jj-lib's
    ///   `RemoteName`, e.g. a Git remote named `git`, with the CLI's ``Run `jj git remote rename`
    ///   to give a different name.`` hint), or Git rejected a ref update ("Failed to update refs:
    ///   …"). No operation is written. Hints ride [`crate::MutateError::hints`] (Story 9.56).
    /// - [`crate::MutateError::Config`] — `git.fetch` (read only without `--remote` /
    ///   `--all-remotes`, and before the remotes are listed — so even without a Git backend) is
    ///   neither a string nor a list of strings; a `remotes.<name>` entry or its
    ///   `fetch-bookmarks`/`fetch-tags` is malformed (the CLI's ``Invalid
    ///   `remotes.<name>.<field>`: …``); the `revset-aliases."immutable_heads()"` alias does not
    ///   resolve against the repo; or — in a NON-colocated workspace, where the verb reads them —
    ///   a `git.*` / `remotes.<name>.auto-track-bookmarks` key above is malformed.
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend at all.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26),
    ///   including a jj config or alias that does not read or parse, and — in a COLOCATED
    ///   workspace, whose pre-verb refs import reads them first — a malformed key above.
    /// - [`crate::MutateError::NetworkError`] — the underlying `git` subprocess failed.
    /// - [`crate::MutateError::Cancelled`] — `cancel`'s token was cancelled before a remote's git
    ///   work, after the last one but before the import, or git failed after the cancel (Story
    ///   9.52); no operation is committed. Without a token this never happens.
    /// - [`crate::MutateError::RemoteNotFound`] — a matched remote vanished between the match and
    ///   its fetch (jj-lib's `NoSuchRemote`); a name that matches nothing is `InvalidInput` above.
    /// - [`crate::MutateError::Backend`] — any other underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_fetch(
        &mut self,
        args: &crate::GitFetchArgs,
        progress: &crate::ProgressFn,
        cancel: Option<&crate::cancel::CancelGuard>,
    ) -> Result<crate::GitFetchOutcome, crate::MutateError> {
        // WHY the two fields rather than the accessors: disjoint field borrows, so the
        // workspace can be borrowed mutably next to the settings.
        self.with_verb(|repo, ctx| {
            crate::remotes::git_fetch(&mut repo.workspace, &repo.settings, args, ctx, progress, cancel)
        })
    }

    /// Asks `remote_name` what it has now and diffs that against the head view, without fetching
    /// (Story 9.24, FR-JJ-13c): the Fetch button's "something new upstream" poll.
    ///
    /// Runs `git ls-remote --heads --tags -- <remote>` the way jj-lib runs every git (the
    /// `git.executable-path` executable, the user's git auth, the adopted login-shell environment)
    /// and compares each advertised branch and tag with the view's `<name>@<remote>` target. An
    /// annotated tag is compared at the commit it peels to, as jj imports it. The result lists the
    /// refs that moved, are new or were deleted upstream — bookmarks before tags, each by name; an
    /// empty list means a fetch would bring nothing new. Tracked local bookmarks play no part.
    ///
    /// Only the refs a bare [`Repo::git_fetch`] of the remote would fetch take part (Story 9.30):
    /// `remotes.<name>.fetch-bookmarks`, else the Git config's fetch refspecs (the ones jj ignores
    /// are dropped silently — no warning, the poll is no CLI verb), and `remotes.<name>.fetch-tags`,
    /// else every tag. Both the advertised names and the view's are filtered before the diff.
    ///
    /// No pre-verb snapshot (a dirty working copy stays unsnapshotted), no transaction, no
    /// operation of its own, no object download: views, bookmarks, Git refs and files are left
    /// untouched. Loading the head the CLI's way may still reconcile divergent operation heads
    /// (`reconcile divergent operations`, as every jj command does). The call leaves no
    /// [`Repo::take_precondition`] report; [`Repo::take_warnings`] holds the start-up
    /// secure-config fix-up's warnings.
    ///
    /// It is a network call, so it takes Story 9.52's cancel token like [`Repo::git_fetch`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::Config`] — the start-up fix-up failed, the changed config stack no
    ///   longer reads, `git.executable-path` does not read, or a `remotes.<name>` entry or the
    ///   remote's `fetch-bookmarks`/`fetch-tags` is malformed.
    /// - [`crate::MutateError::InvalidInput`] — the remote's Git config does not read, or a
    ///   `fetch-bookmarks`/`fetch-tags` pattern cannot become a refspec (the fetch refuses it too).
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no Git backend; nothing runs.
    /// - [`crate::MutateError::RemoteNotFound`] — no configured git remote is named `remote_name`
    ///   exactly; git never runs.
    /// - [`crate::MutateError::NetworkError`] — git could not be spawned, or failed (network,
    ///   authentication, transport); jj-lib's texts, e.g. `External git program failed:\n<stderr>`.
    /// - [`crate::MutateError::Cancelled`] — `cancel`'s token was cancelled before or right after
    ///   the git work, or git failed after the cancel killed it. Never without a token.
    /// - [`crate::MutateError::Precondition`] — the head could not be loaded.
    /// - [`crate::MutateError::Backend`] — git's output is not a ref advertisement, or the
    ///   workspace could not be reloaded after a config change.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn remote_changes(
        &mut self,
        remote_name: &str,
        cancel: Option<&crate::cancel::CancelGuard>,
    ) -> Result<Vec<crate::RemoteRefChange>, crate::MutateError> {
        let mut fix_ups = Vec::new();
        let refreshed = self.refresh_settings(&mut fix_ups);
        // After the refresh: a reload replaces `*self`, collector included.
        self.pending_precondition = None;
        self.pending_warnings = crate::warning::Warnings::default();
        self.pending_warnings.extend(fix_ups);
        refreshed?;
        crate::remote_changes::remote_changes(&self.workspace, &self.settings, remote_name, cancel)
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
    ///   prefix is carried by two or more commits; refused, never resolved to one of them. Or an
    ///   absent side's `@` in a workspace with no working-copy commit ("Workspace `<name>`
    ///   doesn't have a working-copy commit").
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
    /// - [`crate::WorkspaceError::Backend`] — the head load failed, i.e. the VIEW half could not
    ///   be read; the jj-lib reason is forwarded as a string. No path failure reaches this.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_workspaces(&mut self) -> Result<Vec<crate::WorkspaceEntry>, crate::WorkspaceError> {
        self.with_verb(|repo, _ctx| crate::workspace::list_workspaces(repo.workspace()))
    }

    /// Returns a workspace's root directory (Story 9.7) — the CLI's `jj workspace root [--name]`.
    ///
    /// Read-only; never shells to `jj workspace root` (AR-AP-1), runs no pre-verb snapshot and
    /// writes no operation of its own. `name` is the CLI's long-only `--name`, passed through
    /// rather than defaulted here (FR-JJ-17); `None` is its documented default, the CURRENT
    /// workspace.
    ///
    /// Both forms first run the CLI's command start-up (`run_internal`, `cli/src/cli_util.rs:
    /// 4630-4750` @ v0.46.0): the secure-config fix-up, the effective config and its migrations'
    /// "Deprecated … config" warnings. The bare form stops there and returns exactly what the
    /// infallible [`Repo::workspace_root`] accessor returns — the loader's root, no repo load, no
    /// store read (`cli/src/commands/workspace/root.rs:75`). The named form — even with the
    /// CURRENT workspace's own name — runs the start-up of `workspace_helper_no_snapshot`
    /// (`root.rs:42`) on top, as [`Repo::op_integrate`]: the alias tables, the
    /// `immutable_heads()` / short-prefixes parse and the `trunk()` fallback, and its head load
    /// reconciles divergent heads in this workspace as the CLI's does. Then the CLI's stages run
    /// in ITS order (store load, view membership, recorded path), and the ABSOLUTE recorded path
    /// comes back — not canonicalized, as in the CLI since jj 0.46; the CLI's CWD-relative
    /// rendering is the GUI's job. A recorded directory that does not exist is no refusal: the
    /// path comes back with a `jj.workspace_path_inaccessible` warning, the call's last.
    ///
    /// The call resets the warning list: [`Repo::take_warnings`] afterwards holds the start-up's
    /// warnings and the call's own, on success AND on failure (then everything up to the
    /// refusal). [`Repo::take_precondition`] is `None` afterwards.
    ///
    /// An explicitly present EMPTY name is a VALUE, not an absence: no workspace is named `""`,
    /// so it refuses as [`crate::WorkspaceError::NotFound`].
    ///
    /// # Errors
    ///
    /// - [`crate::WorkspaceError::Precondition`] — the start-up failed: a config stack that does
    ///   not resolve (either form); with a name also an alias table, `immutable_heads()` or
    ///   short-prefixes revset that does not parse (all `Config`), or a jj-lib failure of the
    ///   colocation check, the start-up environment or the `trunk()` fallback's head load
    ///   (`Backend`).
    /// - [`crate::WorkspaceError::NotFound`] — no workspace of that name is in the head view.
    /// - [`crate::WorkspaceError::NoRecordedPath`] — the workspace exists but the store holds no
    ///   path for it (it predates jj 0.38.0, or its entry was wiped).
    /// - [`crate::WorkspaceError::Backend`] — the workspace store could not be loaded or read, or
    ///   the head load failed.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn resolve_workspace_root(&mut self, name: Option<&str>) -> Result<PathBuf, crate::WorkspaceError> {
        let result = match name {
            None => self
                .start_command()
                .map(|_| self.workspace.workspace_root().to_owned())
                .map_err(crate::WorkspaceError::from),
            Some(name) => self
                .start_call()
                .map_err(crate::WorkspaceError::from)
                .and_then(|_| crate::workspace::resolve_root(&self.workspace, name, &mut self.pending_warnings)),
        };
        // No snapshot ran: no report. The `trunk()` fallback is the call's alone, as in
        // `op_integrate`.
        self.pending_precondition = None;
        self.trunk_fallback = false;
        result
    }

    /// Brings a stale working copy up to date (Story 9.23) — the CLI's `jj workspace
    /// update-stale` (`cli/src/commands/workspace/update_stale.rs` @ v0.46.0, the body
    /// `recover_stale_working_copy_impl`, `cli/src/cli_util.rs:615-766`).
    ///
    /// The pre-verb precondition does NOT run — this is the recovery a stale working copy's
    /// `jj.stale_working_copy` refusal names. Under the Git import/export lock (colocated): the
    /// working copy is snapshotted at its OWN operation, the head is loaded (reconciling the
    /// divergent operations a dirty snapshot creates), and a stale working copy is checked out
    /// onto the head's `@` — after a `reset git head` operation in a colocated workspace, and
    /// WITHOUT an operation of its own. A working copy whose operation is gone gets jj-lib's
    /// `recovery commit` instead. Either way the full pre-verb snapshot runs last. A fresh
    /// working copy reports [`crate::StaleRecoveryOutcome::NotStale`] and writes nothing unless
    /// it was dirty.
    ///
    /// [`Repo::take_precondition`] hands out that LAST snapshot's report, its `snapshot_stats`
    /// the merged stats of both snapshots — which are also what the call's
    /// `jj.snapshot_files_refused` / `jj.snapshot_paths_not_utf8` warnings report
    /// (`print_snapshot_stats`). [`Repo::take_warnings`] has the call's warnings.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::Precondition`] wrapping
    ///   [`crate::PreconditionError::ConcurrentWorkingCopy`] — the working copy's recorded tree
    ///   is not the stale `@`'s ("Concurrent working copy operation. Try again.").
    /// - [`crate::MutateError::Precondition`] wrapping [`crate::PreconditionError::Config`] — the
    ///   config does not read, or a value a snapshot reads is wrong-typed.
    /// - [`crate::MutateError::Precondition`] wrapping
    ///   [`crate::PreconditionError::StaleWorkingCopy`] — another operation made the working copy
    ///   stale again before the trailing snapshot.
    /// - [`crate::MutateError::Precondition`] wrapping [`crate::PreconditionError::Backend`] —
    ///   the workspace has no `@`, or any underlying jj-lib failure.
    pub fn workspace_update_stale(&mut self) -> Result<crate::StaleRecovery, crate::MutateError> {
        let started = self.start_call();
        let result = started.map(|(config, colocated, env)| {
            let mut report = crate::Precondition::default();
            let result = crate::stale::run(
                &mut self.workspace,
                &config,
                &env,
                colocated,
                &mut report,
                &mut self.pending_warnings,
            );
            self.pending_precondition = Some(report);
            result
        });
        // The `trunk()` fallback is the call's alone (Story 9.56).
        self.trunk_fallback = false;
        let (recovery, stats) = result??;
        self.pending_warnings
            .extend(crate::warning::snapshot_stats(self.workspace.workspace_root(), &stats));
        Ok(recovery)
    }

    /// Adds a workspace of this repo (Story 9.23) — the CLI's `jj workspace add`
    /// (`cli/src/commands/workspace/add.rs:110-280` @ v0.46.0), every parameter passed through
    /// (FR-JJ-17).
    ///
    /// - `destination` — the CLI's positional `DESTINATION`, resolved against THIS workspace's
    ///   root as the working directory; an absolute path stays absolute. A missing directory is
    ///   created (its parent must exist); an existing one must be empty.
    /// - `name` — the CLI's `--name`; `None` names the workspace after the destination's final
    ///   component. An explicitly empty name is a value, and refused.
    /// - `revisions` — the CLI's repeatable `-r` REVSETS, evaluated in THIS workspace's context
    ///   (`@` is this workspace's `@`); their union, in argument order and deduplicated, becomes
    ///   the new `@`'s parents. Empty: the parents of this workspace's `@` (root when it has
    ///   none).
    /// - `message_paragraphs` — the CLI's repeatable `-m`, joined like the CLI joins them (each
    ///   paragraph newline-terminated, a blank line between). A non-empty text gets
    ///   `templates.commit_trailers`, rendered for the NEW workspace (Story 9.51).
    /// - `colocate` — `Some(true)`/`Some(false)` are the CLI's `--colocate`/`--no-colocate`;
    ///   `None` creates a Git worktree exactly when this workspace is colocated and `git.colocate`
    ///   (default `true`) is set — the key is read only in that case.
    /// - `sparse` — the CLI's `--sparse-patterns` (default [`crate::SparseInheritance::Copy`]).
    ///
    /// Runs the pre-verb precondition on THIS workspace first. Operations, in the CLI's order:
    /// jj-lib's `add workspace '<name>'`, then `create initial working-copy commit in workspace
    /// <name>`, whose finish checks the new `@` out into the destination (and, colocated, resets
    /// the new worktree's Git HEAD and index). A destination given without a path separator
    /// warns `jj.workspace_in_current_directory`. Right after the workspace is created, its own
    /// start-up environment is built as the CLI's `for_workable_repo` builds it (Story 9.54): its
    /// alias, `immutable_heads()` and short-prefixes warnings are reported a SECOND time, as the
    /// CLI prints them again, and the trailers and the finish use its immutable set, aliases and
    /// short-prefixes expression.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — the name is empty or the destination has no
    ///   final component (nothing created), or `revisions` resolve to no commit ("Empty revision
    ///   set" — the workspace and its `add workspace` operation exist by then, as in the CLI).
    /// - [`crate::MutateError::WorkspaceExists`] — a workspace of that name exists.
    /// - [`crate::MutateError::DestinationNotEmpty`] — the destination is a file or a non-empty
    ///   directory.
    /// - [`crate::MutateError::GitWorktree`] — the Git worktree could not be created (a non-Git
    ///   backend, or `git` failed); the created directory stays, as in the CLI.
    /// - [`crate::MutateError::RevsetParseError`] / [`crate::MutateError::RevsetResolutionError`]
    ///   — a `revisions` entry; the workspace exists by then.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed, or the new
    ///   workspace's start-up environment does not load (the workspace exists by then).
    /// - [`crate::MutateError::Config`] — `git.colocate` or `git.executable-path` is wrong-typed,
    ///   or the immutable set does not resolve; or (a non-empty `message_paragraphs`, Story 9.51)
    ///   a `templates.commit_trailers` that does not parse or render (the CLI's texts, see
    ///   [`Repo::describe`]) — the workspace and its `add workspace` operation exist by then, as
    ///   in the CLI.
    /// - [`crate::MutateError::NoWorkingCopy`] / [`crate::MutateError::ConcurrentWorkingCopy`] —
    ///   the new working copy could not be locked for its sparse patterns.
    /// - [`crate::MutateError::Backend`] — the directory could not be created, or any underlying
    ///   jj-lib failure.
    pub fn workspace_add(
        &mut self,
        destination: &str,
        name: Option<&str>,
        revisions: &[String],
        message_paragraphs: &[String],
        colocate: Option<bool>,
        sparse: crate::SparseInheritance,
    ) -> Result<crate::WorkspaceAddResult, crate::MutateError> {
        let args = crate::workspace_add::AddArgs {
            destination,
            name,
            revisions,
            message_paragraphs,
            colocate,
            sparse,
        };
        self.with_verb(|repo, ctx| crate::workspace_add::add(repo, ctx, &args))
    }

    /// Stops tracking workspaces' working-copy commits (Story 9.13) — the CLI's `jj workspace
    /// forget [names]` (`cli/src/commands/workspace/forget.rs:43-126` @ v0.46.0). Nothing on disk
    /// is touched but a workspace's Git worktree link.
    ///
    /// `names` empty forgets THIS workspace. A name the view does not have warns
    /// `jj.workspace_names_unmatched` and is skipped; with none left nothing is written. The rest
    /// leave the view in ONE operation, `forget workspace <name>` / `forget workspaces <a>, <b>`
    /// (a discardable `@` is abandoned with it). Their recorded paths STAY in the workspace store,
    /// so an `undo` can point a workspace back at its directory. Afterwards each forgotten
    /// workspace whose directory still resolves gets its Git worktree unlinked (the `.git` file
    /// removed, `git worktree prune`): listed in
    /// [`crate::WorkspaceRemoveResult::git_worktrees_removed`], a failure warns
    /// `jj.git_worktree_unlink_failed` and the call still succeeds.
    ///
    /// Forgetting THIS workspace leaves its working copy untouched and warns
    /// `jj.workspace_no_longer_exists`; `working_copy_change_id` is then `None`, and every later
    /// call that defaults to `@` refuses with the CLI's "Workspace `<name>` doesn't have a
    /// working-copy commit".
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed.
    /// - [`crate::MutateError::Config`] — the immutable set does not resolve (nothing written), or
    ///   `git.executable-path` does not read (the operation is written by then, as in the CLI).
    /// - [`crate::MutateError::Backend`] — the workspace store or any other jj-lib step failed.
    pub fn workspace_forget(&mut self, names: &[String]) -> Result<crate::WorkspaceRemoveResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::workspace_ops::forget(repo.workspace_mut(), ctx, names))
    }

    /// Renames THIS workspace (Story 9.13) — the CLI's `jj workspace rename <new_name>`
    /// (`cli/src/commands/workspace/rename.rs:30-83` @ v0.46.0).
    ///
    /// The view, the workspace store and the working copy are renamed together in one operation,
    /// `Renamed workspace '<old>' to '<new>'`, committed as the CLI commits it (no finish: no Git
    /// export, no identity warning). The handle then runs as the renamed workspace. The current
    /// name writes nothing.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `new_name` is empty ("New workspace name cannot be
    ///   empty"), refused before the pre-verb snapshot.
    /// - [`crate::MutateError::NoWorkingCopy`] — this workspace has no `@` in the view: the CLI's
    ///   refusal "The current workspace '<name>' is not tracked in the repo.", reported without
    ///   that text.
    /// - [`crate::MutateError::WorkspaceExists`] — another workspace has `new_name`; nothing is
    ///   written.
    /// - [`crate::MutateError::ConcurrentWorkingCopy`] — the working copy's recorded tree is not
    ///   `@`'s.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed.
    /// - [`crate::MutateError::Backend`] — the store, the commit, the working-copy finish or the
    ///   handle's reload failed.
    pub fn workspace_rename(&mut self, new_name: &str) -> Result<crate::MutationResult, crate::MutateError> {
        let args = if new_name.is_empty() {
            Err(crate::MutateError::invalid("New workspace name cannot be empty"))
        } else {
            Ok(())
        };
        let result = self.with_checked_verb(args, |repo, _ctx| {
            crate::workspace_ops::rename(repo.workspace_mut(), new_name)
        })?;
        // The working copy now names the new workspace; reload so later calls run under it.
        self.reload_workspace()?;
        Ok(result)
    }

    /// Removes workspaces and deletes their directories (Story 9.13) — the CLI's `jj workspace
    /// remove <names>` (`cli/src/commands/workspace/remove.rs:49-189` @ v0.46.0, new in jj 0.46).
    ///
    /// A name the view does not have warns `jj.workspace_names_unmatched` and is skipped; with
    /// none left nothing is written. Every remaining workspace must be removable, checked in
    /// order before anything is written: a recorded path that resolves, not containing this
    /// repository, holding a workspace of THIS repository. Then each is snapshotted in turn (its
    /// own operation when its files changed, so tracked edits survive as a commit; untracked and
    /// ignored files go with the directory), all leave the view in ONE operation, `remove
    /// workspace <name>` / `remove workspaces <a>, <b>`, their store entries are forgotten, their
    /// Git worktrees unlinked ([`crate::WorkspaceRemoveResult::git_worktrees_removed`], a failure
    /// warns `jj.git_worktree_unlink_failed`) and their directories deleted
    /// ([`crate::WorkspaceRemoveResult::directories_removed`], a failure warns
    /// `jj.workspace_directory_remove_failed`). Each target's start-up environment warns again, as
    /// the CLI prints it per workspace, and so does this workspace's before the removal.
    ///
    /// Removing THIS handle's own (secondary) workspace is allowed, as in the CLI: the result's
    /// `working_copy_change_id` is `None`, `jj.workspace_no_longer_exists` warns, and the handle is
    /// left on the removed workspace, as the CLI leaves the shell in the deleted directory.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `names` is empty (before the pre-verb snapshot);
    ///   a workspace has no recorded path ("Cannot remove unreachable workspace '<name>'"), its
    ///   directory does not resolve ("Cannot access workspace '<name>' directory: <cause>"), it
    ///   contains this repository ("… because it contains the repository", e.g. `default`), it
    ///   belongs to another repository, or no workspace loads there (the CLI's load-error text).
    ///   The first two and the other-repository refusal carry the hint "Use `jj workspace forget`
    ///   to stop tracking a workspace without deleting files."; the repository refusal carries
    ///   none, a load error the CLI's own (none, or its `jj git init` hint). Nothing is written.
    /// - [`crate::MutateError::Precondition`] — this workspace's pre-verb snapshot, a target's
    ///   snapshot (e.g. a stale target) or a start-up environment failed; earlier snapshots stay.
    /// - [`crate::MutateError::Config`] — the immutable set does not resolve, or
    ///   `git.executable-path` does not read (after the operation).
    /// - [`crate::MutateError::Backend`] — a workspace load failed internally, or any other
    ///   jj-lib step.
    pub fn workspace_remove(&mut self, names: &[String]) -> Result<crate::WorkspaceRemoveResult, crate::MutateError> {
        let args = if names.is_empty() {
            Err(crate::MutateError::invalid(
                "workspace remove requires at least one name",
            ))
        } else {
            Ok(())
        };
        self.with_checked_verb(args, |repo, ctx| {
            crate::workspace_ops::remove(repo.workspace_mut(), ctx, names)
        })
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
    /// A created name is AUTO-TRACKED as the CLI does it (Story 9.54's closing run): on every
    /// remote whose `remotes.<r>.auto-track-bookmarks` ∪ `auto-track-created-bookmarks` matches
    /// it and that already has a remote view (e.g. after `git remote add` or a fetch), the
    /// `name@remote` row becomes tracked — target-absent ("not created yet") when the remote has
    /// no such bookmark, otherwise jj-lib merges its target into the new local one. Such an
    /// existing row warns `jj.bookmark_auto_track_existing`; an empty, undescribed target warns
    /// `jj.bookmark_target_empty` before it. [`Repo::list_bookmarks`] shows the tracked rows.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `names` is empty, or a name is the empty
    ///   string.
    /// - [`crate::MutateError::ChangeNotFound`] — `revision` is malformed, carried by no
    ///   VISIBLE commit (unknown or only-hidden), or divergent. An ABSENT `revision` is not
    ///   an error: it is what applies the CLI's `-r` default `@` — refused as
    ///   [`crate::MutateError::RevsetResolutionError`] ("Workspace `<name>` doesn't have a
    ///   working-copy commit") in a workspace with no working-copy commit.
    /// - [`crate::MutateError::BookmarkExists`] — a name is already a local bookmark.
    /// - [`crate::MutateError::BookmarkTrackedRemoteExists`] — a name's local bookmark is
    ///   absent but it still has a tracked remote bookmark. On a GIT-backed repo a colocated
    ///   `name@git` does NOT count: the default-ignored remote is excluded, exactly as in the
    ///   CLI. That exclusion is git-specific — on any other backend no remote is ignored, so a
    ///   tracked `name@git` refuses there.
    /// - [`crate::MutateError::Config`] — a `remotes.<r>` entry is not a table of the known
    ///   keys, or an `auto-track-bookmarks` / `auto-track-created-bookmarks` value does not
    ///   parse (the CLI's ``Invalid `remotes.<r>.<field>`: …``), checked for every remote after
    ///   both guards; nothing is created and no operation written.
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
    /// leak. [`Repo::bookmark_forget`] (Story 9.11) is the verb that leaves no such state.
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

    /// Moves existing local bookmarks to one revision (Story 9.19) — the CLI's `jj bookmark move`.
    ///
    /// `options.names` are EXACT bookmark names (the CLI's `exact:"…"`, never its default glob);
    /// `options.from` are revset TEXTS (the CLI's `--from`, unioned) — at least one of the two is
    /// required. A local bookmark moves when its name is in `names` (any name when `names` is
    /// empty) AND, with `from`, one of its targets is in `from`. `options.to` is the CLI's `--to`,
    /// whose default `@` applies when it is `None`. Fast-forward is decided per bookmark exactly
    /// as [`Repo::drop_actions`]' bookmark row decides it.
    ///
    /// A bookmark already at the target is skipped; when none is left the call is a SUCCESS that
    /// writes NO operation (`new_op_id` is the pre-call head — the CLI's "No bookmarks to
    /// update."). A conflicted bookmark is resolved: every moved bookmark gets a NORMAL target.
    /// Names that match no local bookmark warn `jj.bookmark_names_unmatched`, an empty,
    /// undescribed target warns `jj.bookmark_target_empty`. The op-log description is the CLI's
    /// `point bookmark {names} to commit {hex}`.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — neither `names` nor `from` is given (clap's
    ///   refusal, before the pre-verb snapshot); or, without `allow_backwards`, the first bookmark in name
    ///   order that would move backwards or sideways ("Refusing to move bookmark backwards or
    ///   sideways: {name}", hint "Use --allow-backwards to allow it.").
    /// - [`crate::MutateError::ChangeNotFound`] — `to` is malformed, unknown, hidden or
    ///   divergent; [`crate::MutateError::RevsetResolutionError`] — no `@` for its default.
    /// - [`crate::MutateError::RevsetParseError`] / [`crate::MutateError::RevsetResolutionError`]
    ///   — a `from` text.
    /// - [`crate::MutateError::Config`] — the revset aliases do not load.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_move(
        &mut self,
        options: &crate::BookmarkMoveOptions,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::bookmark_ops::check_move_args(options), |repo, ctx| {
            crate::bookmark_ops::r#move(repo.workspace_mut(), ctx, options)
        })
    }

    /// Advances the closest bookmarks to a revision (Story 9.19) — the CLI's `jj bookmark
    /// advance`.
    ///
    /// `to` is the CLI's `--to`; `None` applies `revsets.bookmark-advance-to` (default `@`), a
    /// revset that must resolve to exactly one commit. `names` are EXACT bookmark names; empty
    /// means the CLI's default candidates — every local bookmark with a target in
    /// `revsets.bookmark-advance-from` (default `heads(::to & bookmarks())`, `to` bound to the
    /// target). Then as [`Repo::bookmark_move`] without `allow_backwards`: bookmarks already at
    /// the target are skipped (none left = no operation), a backwards one refuses, an empty
    /// target warns, every candidate gets a normal target. Op-log description: `point bookmark
    /// {names} to commit {hex}`.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — a backwards or sideways candidate ("Refusing to
    ///   advance bookmark backwards or sideways: {name}", no hint).
    /// - [`crate::MutateError::ChangeNotFound`] — `to` does not resolve.
    /// - [`crate::MutateError::RevsetParseError`] / [`crate::MutateError::RevsetResolutionError`]
    ///   — the default target does not parse or resolve to exactly one commit (its hints carry
    ///   the CLI's "`revsets.bookmark-advance-to` controls the default target. …"), or the from
    ///   revset does not parse or resolve.
    /// - [`crate::MutateError::Config`] — a `revsets.bookmark-advance-*` value is not a string,
    ///   or the revset aliases do not load.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_advance(
        &mut self,
        names: &[String],
        to: Option<&crate::ChangeId>,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::bookmark_ops::advance(repo.workspace_mut(), ctx, names, to))
    }

    /// Renames a local bookmark (Story 9.19) — the CLI's `jj bookmark rename`.
    ///
    /// `old` and `new` are DECODED names, as [`Repo::bookmark_create`]'s are. The new name points
    /// where the old one did, the old one is gone, and tracking moves with it: a tracked
    /// `old@remote` makes `new@remote` tracked — unless `new` already exists untracked on that
    /// remote, which warns `jj.bookmark_rename_remote_exists` and drops the tracking. The remote
    /// bookmarks themselves are NOT renamed: present tracked ones warn
    /// `jj.bookmark_remotes_not_renamed` (push the deletion and the new name to rename them
    /// there). `overwrite_existing` (the CLI's `--overwrite-existing`) lets `new` replace an
    /// existing bookmark: its tracked remotes are untracked first, and a present one the old name
    /// did not track warns `jj.bookmark_tracking_dropped`. Without it, present tracked remotes of
    /// `new` warn `jj.bookmark_tracked_remotes_exist`. On a Git-backed repo the remote `git` is
    /// left out, as in the CLI. Renaming a bookmark to its own name with `overwrite_existing`
    /// writes NO operation. Op-log description: `rename bookmark {old} to {new}`.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — a name is empty (clap's refusal, before the
    ///   pre-verb snapshot), or `old` is not a local bookmark
    ///   ("No such bookmark: {old}").
    /// - [`crate::MutateError::BookmarkExists`] — `new` is a local bookmark and
    ///   `overwrite_existing` is off (also when `old == new`, as in the CLI).
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_rename(
        &mut self,
        old: &str,
        new: &str,
        overwrite_existing: bool,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::bookmark_ops::check_rename_args(old, new), |repo, ctx| {
            crate::bookmark_ops::rename(repo.workspace_mut(), ctx, old, new, overwrite_existing)
        })
    }

    /// Creates or moves local bookmarks to one revision by name (Story 9.11) — the CLI's `jj
    /// bookmark set`.
    ///
    /// `names` are DECODED names, as [`Repo::bookmark_create`]'s are; `revision` is the CLI's
    /// `-r/--to`, whose default `@` applies when it is `None`; `allow_backwards` is its
    /// `--allow-backwards`. Per name in argument order, fail-fast: without `allow_backwards` a
    /// move that is not a fast-forward refuses, and nothing is set. A name with no local bookmark
    /// and no tracked remote bookmark is CREATED and auto-tracked as [`Repo::bookmark_create`]
    /// does it (`jj.bookmark_auto_track_existing`); one whose local bookmark is absent but which
    /// still tracks a remote is resurrected, without auto-tracking. Every name gets a NORMAL
    /// target, so a conflicted bookmark is resolved. An empty, undescribed target warns
    /// `jj.bookmark_target_empty`. Setting every name to where it already points writes NO
    /// operation. Op-log description: `point bookmark {names} to commit {hex}`, names in argument
    /// order.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `names` is empty or holds an empty name (clap's
    ///   refusal, before the pre-verb snapshot); or a backwards or sideways move without
    ///   `allow_backwards` ("Refusing to move bookmark backwards or sideways: {name}", hint "Use
    ///   --allow-backwards to allow it.").
    /// - [`crate::MutateError::ChangeNotFound`] — `revision` is malformed, unknown, hidden or
    ///   divergent; [`crate::MutateError::RevsetResolutionError`] — no `@` for its default.
    /// - [`crate::MutateError::Config`] — a `remotes.<r>` auto-track value does not parse.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_set(
        &mut self,
        names: &[String],
        revision: Option<&crate::ChangeId>,
        allow_backwards: bool,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::bookmark_ops::check_set_args(names), |repo, ctx| {
            crate::bookmark_ops::set(repo.workspace_mut(), ctx, names, revision, allow_backwards)
        })
    }

    /// Forgets bookmarks (Story 9.11) — the CLI's `jj bookmark forget`: the local bookmark goes
    /// WITHOUT becoming a deletion the next push propagates.
    ///
    /// `patterns` are string patterns passed through VERBATIM, as [`Repo::bookmark_delete`]'s are
    /// (a BARE pattern is a GLOB); they match bookmark names with a local OR a remote row, and an
    /// exact name with neither warns `jj.bookmark_names_unmatched`. Each matched local bookmark
    /// becomes absent and its remote bookmarks are untracked (the Git-tracking `git` remote is left
    /// alone); with `include_remotes` (the CLI's `--include-remotes`) the remote bookmarks are
    /// forgotten too, `git` included. Matching or changing nothing writes NO operation. Op-log
    /// description: `forget bookmark {names}`, view order.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `patterns` is empty (clap's refusal, before the
    ///   pre-verb snapshot), or a pattern does not parse.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_forget(
        &mut self,
        patterns: &[String],
        include_remotes: bool,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(
            crate::bookmark_ops::check_names_given("forget", patterns),
            |repo, ctx| crate::bookmark_ops::forget(repo.workspace_mut(), ctx, patterns, include_remotes),
        )
    }

    /// Starts tracking remote bookmarks (Story 9.11) — the CLI's `jj bookmark track`.
    ///
    /// `names` are the CLI's `BOOKMARK[@REMOTE]` texts, passed through: a `name@remote` symbol
    /// names one remote bookmark exactly (revset-quoted where needed, e.g. `"a b"@origin`), any
    /// other text is a string pattern (a BARE one a GLOB) matched on every remote of `remotes`.
    /// `remotes` are remote-name patterns (the CLI's `--remote`; empty = not given, i.e. every
    /// remote but `git` on a Git-backed repo). A local bookmark a remote does not have yet is
    /// trackable there too ("not created yet"). Already-tracked refs warn
    /// `jj.bookmark_already_tracked`, unmatched symbols `jj.remote_bookmarks_unmatched`, unmatched
    /// exact names `jj.bookmark_names_unmatched`, unmatched exact remotes
    /// `jj.bookmark_remotes_unmatched`. Tracking merges the remote target into the local bookmark.
    /// Nothing to track writes NO operation. Op-log description: `track remote bookmark
    /// {symbols}`.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `names` is empty (clap's refusal, before the
    ///   pre-verb snapshot); after it, a name or remote that does not parse, patterns mixed with
    ///   symbols, or `remotes` given with symbols.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_track(
        &mut self,
        names: &[String],
        remotes: &[String],
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::bookmark_ops::check_names_given("track", names), |repo, ctx| {
            crate::bookmark_ops::track_or_untrack(
                repo.workspace_mut(),
                ctx,
                names,
                remotes,
                crate::bookmark_ops::Tracking::Track,
            )
        })
    }

    /// Stops tracking remote bookmarks (Story 9.11) — the CLI's `jj bookmark untrack`.
    ///
    /// `names` and `remotes` as [`Repo::bookmark_track`]'s. Refs of the Git-tracking `git` remote
    /// warn `jj.bookmark_git_tracking_untrack`, untracked ones `jj.bookmark_not_tracked`; the
    /// other matched refs are untracked — the local bookmark stays. Nothing to untrack writes NO
    /// operation. Op-log description: `untrack remote bookmark {symbols}`.
    ///
    /// # Errors
    ///
    /// As [`Repo::bookmark_track`]'s.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_untrack(
        &mut self,
        names: &[String],
        remotes: &[String],
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::bookmark_ops::check_names_given("untrack", names), |repo, ctx| {
            crate::bookmark_ops::track_or_untrack(
                repo.workspace_mut(),
                ctx,
                names,
                remotes,
                crate::bookmark_ops::Tracking::Untrack,
            )
        })
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
    /// - [`crate::MutateError::InvalidInput`] — `changes_in` combined with `from`/`into` (before
    ///   the snapshot, as clap refuses it, so nothing is written), or a `paths` entry is not a
    ///   valid repo path.
    /// - [`crate::MutateError::ChangeNotFound`] — `from`, `into` or `changes_in` is
    ///   malformed, carried by no VISIBLE commit (unknown or only-hidden), or divergent. An
    ///   ABSENT one is not an error: it is what selects the CLI's
    ///   `--from`/`--into`/`--changes-in` defaults described above.
    /// - [`crate::MutateError::RevsetResolutionError`] — such an `@` default in a workspace with
    ///   no working-copy commit ("Workspace `<name>` doesn't have a working-copy commit").
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
        let args = crate::mutate::check_restore_args(from.as_ref(), into.as_ref(), changes_in.as_ref());
        self.with_checked_verb(args, |repo, ctx| {
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
    ///   is what applies the CLI's `--from` default `@` — refused as
    ///   [`crate::MutateError::RevsetResolutionError`] ("Workspace `<name>` doesn't have a
    ///   working-copy commit") in a workspace with no working-copy commit.
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

    /// Moves changes from one or more revisions into another (Story 9.15) — the CLI's
    /// `jj squash`.
    ///
    /// Source and destination resolve as in the CLI (`cli/src/commands/squash.rs` @ v0.46.0):
    ///
    /// - neither `from` nor `into` — `revision` (or `@`) into its ONE parent; a merge or the
    ///   root commit refuses ("Cannot squash merge commits without a specified destination");
    /// - `from` and/or `into` — the `from` revisions (empty: `@`) into `into` (`None`: `@`). The
    ///   destination is silently dropped from the sources, so squashing `@` into `@` changes
    ///   nothing and writes no operation (the CLI's "Nothing changed.").
    ///
    /// `paths` are repo-relative PREFIXES (an empty list moves everything; `""` is the root), as
    /// for [`Repo::restore`]; an explicit path no selected source tree holds warns
    /// `jj.paths_unmatched`. A source whose changes ALL moved is abandoned unless
    /// `keep_emptied`; an abandoned `@` gets a new, empty `@` on its own (rewritten) parents —
    /// the destination only when `@` is squashed into its parent (`-r`/the default)
    /// (`MutationResult::new_change_ids`), and the abandoned sources are reported in
    /// `MutationResult::abandoned_change_ids`.
    ///
    /// `trees` is the tree arm (Story 9.50), in place of the CLI's interactive editor, which runs
    /// once per source: per source, the tree selected in the GUI ([`Repo::select_tree`]) against
    /// that source's parent tree; a source without an entry moves everything (the editor saved
    /// unchanged). Non-empty `trees` conflicts with `paths`.
    ///
    /// The description: `message` (the CLI's `-m`, paragraphs joined like the CLI's), else the
    /// destination's (`use_destination_message`), else the one non-empty description of the
    /// abandoned sources and the destination. When two or more are non-empty the CLI opens its
    /// editor; WITHOUT `message` this verb writes what that editor holds when it is saved
    /// unchanged — the combined descriptions, with the trailers `templates.commit_trailers` adds
    /// that none of them carries, rendered through `templates.draft_commit_description` and
    /// cleaned of its `JJ:` lines (Story 9.51) — call [`Repo::squash_plan`] first to show it to
    /// the user, and pass the edited text back as `edited_description` (Story 9.54), NOT as
    /// `message`, which would add the trailers again. Any other non-empty description gets
    /// `templates.commit_trailers` added. The operation is `squash commits into <destination
    /// commit hex>`, the destination's id BEFORE the squash.
    ///
    /// `edited_description` is the CLI's `--editor` whose editor saves exactly that text: when
    /// something is squashed, the description step runs as with the editor (trailers added — in
    /// the single case even to an empty text — and `templates.draft_commit_description` rendered,
    /// with their refusals and warnings), then the edited text is written, cleaned of `JJ:` lines
    /// and blank edges like a saved buffer, with NO trailers added.
    ///
    /// The working copy is snapshotted first (Story 9.26) — see [`Repo::restore`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `revision` combined with `from`/`into`, `message`
    ///   combined with `use_destination_message`, `message` combined with `edited_description`
    ///   ("--message cannot be used with an edited description"), `paths` with `trees`, a tree of
    ///   the wrong shape — these before the snapshot, as clap refuses them, so nothing is written
    ///   — a merge or root `revision` without `from`/`into`, a `paths` entry that is not a valid
    ///   repo path, or a `trees` entry naming no source or a source another entry names.
    /// - [`crate::MutateError::StaleSelection`] — a source's parent tree is not its tree's
    ///   `left`.
    /// - [`crate::MutateError::ChangeNotFound`] — `revision`, a `from` entry or `into` is
    ///   malformed, carried by no VISIBLE commit, or divergent.
    /// - [`crate::MutateError::RevsetResolutionError`] — an omitted revision's `@` in a workspace
    ///   with no working-copy commit ("Workspace `<name>` doesn't have a working-copy commit").
    /// - [`crate::MutateError::Immutable`] — a source or the destination is inside the repo's
    ///   effective immutable set (the root commit included).
    /// - [`crate::MutateError::Config`] — the `immutable_heads()` alias does not resolve; or a
    ///   template fault before anything is written (Story 9.51): `templates.commit_trailers` or
    ///   (the editor case) `templates.draft_commit_description` does not parse or render (the
    ///   CLI's texts, see [`Repo::describe`]).
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::NotAGitRepo`] — the colocated finish found no Git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn squash(&mut self, options: &crate::SquashOptions) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::squash_split::check_squash_args(options), |repo, ctx| {
            crate::squash_split::squash(repo.workspace_mut(), ctx, options)
        })
    }

    /// The description [`Repo::squash`] would have to ask for (Story 9.15): the squash with the
    /// same `options`, run up to the point where the CLI opens its editor on a transaction that is
    /// then dropped (the hidden commits its templates render on reach the store, as the CLI's do;
    /// Story 9.51).
    ///
    /// `SquashPlan::combined_description` is the text the CLI's editor holds, saved unchanged —
    /// exactly what `squash` writes without `message` — when the abandoned sources and the
    /// destination carry two or more non-empty descriptions and neither `message` nor
    /// `use_destination_message` is set; `None` otherwise. Refuses exactly as `squash` refuses
    /// (`message` with `edited_description` included) and warns as it warns
    /// (`jj.paths_unmatched`); `edited_description` is otherwise ignored.
    ///
    /// Writes NO operation of its own — only the pre-verb snapshot's, like every read.
    ///
    /// # Errors
    ///
    /// As [`Repo::squash`] (its template faults included), minus the finish's
    /// [`crate::MutateError::NotAGitRepo`].
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn squash_plan(&mut self, options: &crate::SquashOptions) -> Result<crate::SquashPlan, crate::MutateError> {
        self.with_checked_verb(crate::squash_split::check_squash_args(options), |repo, ctx| {
            crate::squash_split::squash_plan(repo.workspace(), ctx, options)
        })
    }

    /// Which verbs `source` can run at each of `locations` — the drop-action capability query
    /// (Story 9.31). Every row is answered by the verb's own plan fn, the one the verb runs before
    /// its first write, so a refusal is exactly the [`crate::MutateError`] the verb returns.
    ///
    /// The rows per location, in this order (`S` the source, `T…` the location's ids):
    ///
    /// - [`crate::DropSource::Change`] at `onto`: [`crate::DropVerb::RebaseSource`] (`rebase -s S
    ///   -o T…`), [`crate::DropVerb::RebaseRevisions`] (`rebase -r S -o T…`),
    ///   [`crate::DropVerb::Squash`] (`squash --from S --into T`, only for exactly one `T`, with
    ///   `combined_description_needed`), [`crate::DropVerb::NewMerge`] (`new T… S`) and
    ///   [`crate::DropVerb::Duplicate`] (`duplicate S -o T…`); at `-A`/`-B`: `RebaseRevisions`
    ///   only.
    /// - [`crate::DropSource::Selection`] at `onto` with one id: `Squash` with the paths; at
    ///   `-A`/`-B`: [`crate::DropVerb::Split`] (`split -r S <paths> -A/-B …`).
    /// - [`crate::DropSource::Bookmark`] at `onto` with one id: [`crate::DropVerb::BookmarkMove`]
    ///   (`bookmark move N --to T`), with `allow_backwards_needed` when the move is not a
    ///   fast-forward; nothing else.
    ///
    /// [`crate::ActionStatus::NoOp`] means the verb would write no operation: a rebase whose
    /// planned move (jj-lib's, applied on a dropped transaction) changes nothing, a squash with
    /// nothing to squash, a bookmark move to where the bookmark already is or of a name no local
    /// bookmark has. An id that does not resolve refuses each row it affects with
    /// [`crate::MutateError::ChangeNotFound`].
    ///
    /// Each row plans on its own transaction from one head, which is then dropped; the query
    /// writes NO operation of its own — only the pre-verb snapshot's (Story 9.26). The call's
    /// warnings are the precondition's only: a row's plan warnings are discarded.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — a location gives `onto` together with
    ///   `insert_after`/`insert_before`, or none of the three; checked before anything resolves.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure, a row's included.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn drop_actions(
        &mut self,
        source: &crate::DropSource,
        locations: &[crate::DropLocation],
    ) -> Result<crate::DropActions, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::drop_actions::drop_actions(repo.workspace(), ctx, source, locations))
    }

    /// The card menu's verbs for `change` (Story 9.31): `new` onto it, `new -A` / `new -B` it,
    /// `edit`, `describe`, `squash -r` (into its parent, with `combined_description_needed`) and
    /// `abandon` — each answered by the verb's own plan fn, as in [`Repo::drop_actions`]. Only the
    /// squash reports [`crate::ActionStatus::NoOp`]. An id that does not resolve refuses every row
    /// with [`crate::MutateError::ChangeNotFound`].
    ///
    /// Writes NO operation of its own — only the pre-verb snapshot's; the call's warnings are the
    /// precondition's only.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure, a row's included.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn change_actions(&mut self, change: &crate::ChangeId) -> Result<crate::ChangeActions, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::drop_actions::change_actions(repo.workspace(), ctx, change))
    }

    /// Splits a revision in two (Story 9.15) — the CLI's `jj split`.
    ///
    /// `revision` (or `@`) is split into the changes to `paths` — repo-relative PREFIXES as for
    /// [`Repo::restore`] — or, the tree arm (Story 9.50) in place of the CLI's interactive diff
    /// editor (its no-paths default), into `tree`, selected in the GUI ([`Repo::select_tree`])
    /// against the target's parent tree; one of the two is required. The rest:
    ///
    /// - plain: the SELECTED commit keeps the target's change id and parents, the REMAINING
    ///   commit (a new change id) becomes its child;
    /// - `parallel`: both on the target's parents, and the target's children get both as
    ///   parents;
    /// - `onto` / `insert_after` / `insert_before` (the CLI's `-o`/`-A`/`-B`): the selected
    ///   changes become a NEW change at that location; the remaining commit keeps the target's
    ///   change id and place.
    ///
    /// Bookmarks on the target move to the remaining commit under the CLI's default
    /// `split.legacy-bookmark-behavior = true` and stay on the selected commit when it is
    /// `false` (with `-o`/`-A`/`-B` they follow the remaining commit). `@` — of every workspace
    /// whose `@` was the target — ends on the remaining commit. Descendants are rebased.
    ///
    /// `message` (the CLI's `-m`) describes the selected commit — with `templates.commit_trailers`
    /// added when non-empty (Story 9.51) — and the remaining one keeps the original description.
    /// WITHOUT `message` the CLI opens its editor on both; this verb writes what it holds when saved
    /// unchanged: each commit's description with the trailers added (the selected one's also when
    /// empty), rendered through `templates.draft_commit_description` and cleaned of its `JJ:`
    /// lines — by default the original description (with trailers) on both, or
    /// `template-aliases.default_commit_description` for an undescribed target.
    ///
    /// `edited_selected_description` and `edited_remaining_description` (Story 9.54, both or
    /// neither) are the CLI's bulk editor saving exactly those two sections: the editor path above
    /// runs unchanged (its refusals and warnings included), then each commit gets its edited text,
    /// cleaned of `JJ:` lines and blank edges like a saved section, with NO trailers added.
    ///
    /// Selecting every change warns `jj.split_all_selected`, selecting none
    /// `jj.split_none_selected` (after a `jj.paths_unmatched` when the paths match nothing);
    /// the split runs either way. The operation is `split commit <target commit hex>`.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `message` combined with an edited description
    ///   ("--message cannot be used with an edited description"), only one of the two edited
    ///   descriptions given ("an edited split needs both descriptions: the selected and the
    ///   remaining"), `parallel` combined with a location, `onto` with
    ///   `insert_after`/`insert_before`, `paths` with `tree`, a `tree` of the wrong shape — these
    ///   before the snapshot, as clap refuses them, so nothing is written — neither `paths` nor
    ///   `tree`, an invalid repo path, a location that resolves no parent, or one that would
    ///   create a loop.
    /// - [`crate::MutateError::StaleSelection`] — the target's parent tree is not `tree.left`.
    /// - [`crate::MutateError::ChangeNotFound`] — `revision` or a location entry is malformed,
    ///   carried by no VISIBLE commit, or divergent.
    /// - [`crate::MutateError::RevsetResolutionError`] — an omitted `revision`'s `@` in a
    ///   workspace with no working-copy commit ("Workspace `<name>` doesn't have a working-copy
    ///   commit").
    /// - [`crate::MutateError::Immutable`] — the target, or a child the location would
    ///   rewrite, is inside the repo's effective immutable set.
    /// - [`crate::MutateError::Config`] — `split.legacy-bookmark-behavior` is not a boolean, the
    ///   `immutable_heads()` alias does not resolve, or a template fault before anything is
    ///   written (Story 9.51): `templates.commit_trailers` or (without `message`)
    ///   `templates.draft_commit_description` does not parse or render (the CLI's texts, see
    ///   [`Repo::describe`]).
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::NotAGitRepo`] — the colocated finish found no Git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn split(&mut self, options: &crate::SplitOptions) -> Result<crate::SplitResult, crate::MutateError> {
        self.with_checked_verb(crate::squash_split::check_split_args(options), |repo, ctx| {
            crate::squash_split::split(repo.workspace_mut(), ctx, options)
        })
    }

    /// Moves revisions to a new place in the graph (Story 9.16) — the CLI's `jj rebase`.
    ///
    /// What moves — one of three forms, at most one given:
    ///
    /// - `revisions` (`-r`): only these commits; their descendants move onto their parents. A
    ///   revision may move onto its own descendant.
    /// - `source` (`-s`): these commits with all their descendants; each becomes a direct child of
    ///   the destination.
    /// - `branch` (`-b`): the roots of `destination..branch` with their descendants. All three
    ///   empty is the CLI's default `-b @`.
    ///
    /// Where — `onto` (`-o`, the new parents) or `insert_after` / `insert_before` (`-A` / `-B`,
    /// the new parents and the children that move on top), the location as `jj new` resolves it.
    /// `skip_emptied`, `keep_divergent` and `simplify_parents` are the CLI's flags: without
    /// `keep_divergent`, a divergent commit whose identical twin is already in the destination is
    /// abandoned. Bookmarks follow their commits; an abandoned commit's bookmarks are not deleted.
    ///
    /// A move with nothing to rebase (the CLI's "No revisions to rebase.", e.g. a branch already
    /// on the destination) or that changes nothing writes NO operation; `new_op_id` is then the
    /// pre-call head. Otherwise the operation is the CLI's: `rebase commit <hex>`, `rebase commit
    /// <hex> and <n> more`, `rebase <n> commits` (`-r`), `rebase commit <hex> and descendants` or
    /// `rebase <n> commits and their descendants` (`-s`/`-b`), full commit ids before the move.
    /// `abandoned_change_ids` names the commits the move abandoned (divergent twins, newly emptied
    /// commits); `new_change_ids` the replacement `@` when `@` was one of them.
    ///
    /// The working copy is snapshotted first (Story 9.26) — see [`Repo::restore`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — more than one of `branch`/`source`/`revisions`,
    ///   `onto` with `insert_after`/`insert_before`, or none of the three location lists (clap's
    ///   refusals: before the snapshot, so nothing is written); `Cannot rebase <12 hex> onto
    ///   itself` / `onto descendant <12 hex>`; a location that would create a loop or resolves no
    ///   parent; or the backend refusing a commit of the move (a merge with the root commit as a
    ///   parent, in a Git repo).
    /// - [`crate::MutateError::ChangeNotFound`] — an id is malformed, carried by no VISIBLE
    ///   commit, or divergent.
    /// - [`crate::MutateError::RevsetResolutionError`] — the default `-b @` in a workspace with
    ///   no working-copy commit ("Workspace `<name>` doesn't have a working-copy commit").
    /// - [`crate::MutateError::Immutable`] — a commit the move rewrites, or a child the location
    ///   would rewrite, is inside the repo's effective immutable set.
    /// - [`crate::MutateError::Config`] — the `immutable_heads()` alias does not resolve.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::NotAGitRepo`] — the colocated finish found no Git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn rebase(&mut self, options: &crate::RebaseOptions) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::rebase::check_rebase_args(options), |repo, ctx| {
            crate::rebase::rebase(repo.workspace_mut(), ctx, options)
        })
    }

    /// Makes revisions siblings (Story 9.16) — the CLI's `jj parallelize`.
    ///
    /// Each of `change_ids` keeps its parents outside the set, and in place of a parent inside the
    /// set inherits that parent's new parents; a commit outside the set keeps every target it
    /// descended from as an ancestor (a child of a target gets the target's in-set ancestors as
    /// direct parents too). Only the targets that move are checked rewritable, so an immutable
    /// root of the set is allowed. A set that changes nothing — one revision, none, or
    /// revisions already independent — writes NO operation (`new_op_id` is the pre-call head);
    /// otherwise the operation is `parallelize <n> commits`.
    ///
    /// The working copy is snapshotted first (Story 9.26) — see [`Repo::restore`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::ChangeNotFound`] — an id is malformed, carried by no VISIBLE
    ///   commit, or divergent.
    /// - [`crate::MutateError::Immutable`] — a target that would move is inside the repo's
    ///   effective immutable set.
    /// - [`crate::MutateError::Config`] — the `immutable_heads()` alias does not resolve.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::NotAGitRepo`] — the colocated finish found no Git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn parallelize(&mut self, change_ids: &[crate::ChangeId]) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::parallelize::parallelize(repo.workspace_mut(), ctx, change_ids))
    }

    /// Rearranges revisions (Story 9.16) — the CLI's `jj arrange` with its terminal UI replaced
    /// by the UI's own key actions.
    ///
    /// The target set is `options.revisions`, or — when empty — the `revsets.arrange` setting
    /// (jj's default `reachable(@, mutable())`), parsed like a user revset (its diagnostics are
    /// warnings "In revset expression"). It must be rewritable and have no gaps. Then
    /// `options.actions` are replayed in order, as the TUI applies its keys:
    /// [`crate::ArrangeAction::SwapDown`] / [`crate::ArrangeAction::SwapUp`] swap a commit with its
    /// one parent / child in the set (ignored otherwise, as the TUI ignores it),
    /// [`crate::ArrangeAction::Abandon`] / [`crate::ArrangeAction::Keep`] mark it. The result is
    /// written as the TUI's confirm writes it; descendants outside the set follow.
    ///
    /// An empty target set (the CLI's "No revisions to arrange.") or actions that change nothing
    /// write NO operation (`new_op_id` is the pre-call head); otherwise the operation is `arrange
    /// revisions`. `abandoned_change_ids` names the commits marked abandoned, `new_change_ids` the
    /// replacement `@` when `@` was one of them.
    ///
    /// The working copy is snapshotted first (Story 9.26) — see [`Repo::restore`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — the target set has a gap ("Cannot arrange revset
    ///   with gaps in.", hint "Revision <12 hex> would need to be in the set."), or an action names
    ///   a change outside the target set ("<change id> is not among the revisions to arrange").
    /// - [`crate::MutateError::ChangeNotFound`] — a revision or an action's change id is
    ///   malformed, carried by no VISIBLE commit, or divergent.
    /// - [`crate::MutateError::Immutable`] — a target is inside the repo's effective immutable
    ///   set.
    /// - [`crate::MutateError::RevsetParseError`] / [`crate::MutateError::RevsetResolutionError`]
    ///   — `revsets.arrange` does not parse or resolve.
    /// - [`crate::MutateError::Config`] — `revsets.arrange` is not a string, the alias tables do
    ///   not read, or the `immutable_heads()` alias does not resolve.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::NotAGitRepo`] — the colocated finish found no Git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn arrange(&mut self, options: &crate::ArrangeOptions) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::arrange::arrange(repo.workspace_mut(), ctx, options))
    }

    /// Modifies revisions' metadata without changing their content (Story 9.9) — the CLI's `jj
    /// metaedit`.
    ///
    /// The targets are `options.revisions`, or `@` when empty; each is checked rewritable. A
    /// target is rewritten when its metadata changes: `message` (the CLI's `-m` paragraphs,
    /// joined as it joins them) differs from its description, `author` (`"Name <email>"`) or
    /// `update_author` (the configured user) changes its author's name or email,
    /// `author_timestamp` (RFC 2822 or RFC 3339) or `update_author_timestamp` (now) changes its
    /// author timestamp, `update_change_id` gives it a new change id, or `force_rewrite` asks for
    /// it; a rewrite also renews the committer. Descendants are reparented — their content stays —
    /// and bookmarks follow.
    ///
    /// A call that rewrites nothing writes NO operation (`new_op_id` is the pre-call head);
    /// otherwise the operation is the CLI's `edit commit metadata for commit <hex>` or `… <hex>
    /// and <n> more`, full commit ids before the edit. `new_change_ids` names the change ids
    /// `update_change_id` minted, in the rewritten commits' order; it is empty otherwise.
    ///
    /// The working copy is snapshotted first (Story 9.26) — see [`Repo::restore`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — clap's refusals, before the snapshot (nothing is
    ///   written): `author` not `Name <email>` (``invalid value '<v>' for '--author <AUTHOR>':
    ///   Invalid author string``), `author_timestamp` neither RFC 2822 nor RFC 3339 (``invalid
    ///   value '<v>' for '--author-timestamp <AUTHOR_TIMESTAMP>': <reason>``), `author` with
    ///   `update_author`, `author_timestamp` with `update_author_timestamp`.
    /// - [`crate::MutateError::ChangeNotFound`] — an id is malformed, carried by no VISIBLE
    ///   commit, or divergent.
    /// - [`crate::MutateError::RevsetResolutionError`] — the default `@` in a workspace with no
    ///   working-copy commit.
    /// - [`crate::MutateError::Immutable`] — a target is inside the repo's effective immutable
    ///   set (the root commit among them).
    /// - [`crate::MutateError::Config`] — the `immutable_heads()` alias does not resolve.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::NotAGitRepo`] — the colocated finish found no Git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn metaedit(&mut self, options: &crate::MetaeditOptions) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::metaedit::check_metaedit_args(options), |repo, ctx| {
            crate::metaedit::metaedit(repo.workspace_mut(), ctx, options)
        })
    }

    /// Moves the working copy to a child or parent (Story 9.10) — the CLI's `jj next` / `jj prev`.
    ///
    /// `options.direction` picks the verb. Without `edit` — and unless `ui.movement.edit` is `true`
    /// without `no_edit` — a new empty `@` is created on the target (`jj new`); `@` must be a
    /// head, and `next` counts from `@`'s parents, skipping `@` itself. With it the target itself
    /// becomes `@` (`jj edit`) and must be rewritable. The target is the commit `offset`
    /// generations away (`None` = the CLI's `1`), or with `conflict` the nearest conflicted
    /// descendant (`next`, the revset's `roots`) or ancestor (`prev`, its `heads`).
    ///
    /// When the target revset yields several commits, the CLI prompts: here `options.target`
    /// chooses one of [`Repo::movement_targets`]' candidates. The choice is checked against the
    /// candidates this call computes.
    ///
    /// The operation is the CLI's `next: <@> -> <target>` or `next: <@> -> editing <target>`
    /// (`prev: …` likewise), 12-hex commit ids. A move that changes nothing (`prev 0 --edit`)
    /// writes NO operation (`new_op_id` is the pre-call head).
    ///
    /// The working copy is snapshotted first (Story 9.26) — see [`Repo::restore`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — clap's refusals, before the snapshot (nothing is
    ///   written): `edit` with `no_edit` ("the argument '--edit' cannot be used with
    ///   '--no-edit'"), an explicit `offset` with `conflict` ("the argument '--conflict' cannot be
    ///   used with '\[OFFSET\]'"). Then `@` has children and the move does not edit ("The working
    ///   copy must not have any children", with its hint); a generation beyond `u32::MAX` — an
    ///   offset that large, or `next` offset `0` without editing, which wraps as in the release
    ///   CLI (jj-lib's "Lower bound of generation (n) is too large"); no target (the CLI's eight
    ///   "No descendant found …" / "… have no ancestors with conflicts" texts, one "Working copy:
    ///   …" or "Working copy parent: …" hint per start commit, the commit's summary); several
    ///   targets and no `target` ("ambiguous next commit, choose one to target").
    /// - [`crate::MutateError::StaleSelection`] — `target` is not one of the current candidates.
    /// - [`crate::MutateError::NoWorkingCopy`] — the workspace has no working-copy commit.
    /// - [`crate::MutateError::Immutable`] — (editing) the target is inside the repo's effective
    ///   immutable set (the root commit included).
    /// - [`crate::MutateError::Config`] — `ui.movement.edit` is not a boolean (the key is named),
    ///   `templates.commit_summary` (the not-found hints) does not parse, or the
    ///   `immutable_heads()` alias does not resolve.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::NotAGitRepo`] — the colocated finish found no Git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn move_working_copy(
        &mut self,
        options: &crate::MovementOptions,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::movement::check_movement_args(options), |repo, ctx| {
            crate::movement::move_working_copy(repo.workspace_mut(), ctx, options)
        })
    }

    /// The targets [`Repo::move_working_copy`] chooses from (Story 9.10): the move with the same
    /// `options`, run up to the point where the CLI picks its target or prompts for one.
    /// `options.target` is ignored.
    ///
    /// `MovementTargets::targets` lists the candidates in the CLI's prompt order — more than one
    /// is the case the CLI prompts for, and each `commit_id` is what `options.target` takes;
    /// `MovementTargets::edit` says whether the move edits its target. Refuses exactly as the move
    /// refuses up to that point: no rewritability guard runs here, so (editing) an immutable
    /// candidate is listed and still refuses [`crate::MutateError::Immutable`] at the move.
    ///
    /// Writes NO operation of its own — only the pre-verb snapshot's, like every read.
    ///
    /// # Errors
    ///
    /// As [`Repo::move_working_copy`], minus the choice ([`crate::MutateError::StaleSelection`],
    /// the ambiguous refusal), the rewritability guard and the finish.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn movement_targets(
        &mut self,
        options: &crate::MovementOptions,
    ) -> Result<crate::MovementTargets, crate::MutateError> {
        self.with_checked_verb(crate::movement::check_movement_args(options), |repo, ctx| {
            crate::movement::movement_targets(repo.workspace(), ctx, options)
        })
    }

    /// Creates new changes with the same content as existing ones (Story 9.9) — the CLI's `jj
    /// duplicate`.
    ///
    /// The originals are `options.revisions`, or `@` when empty. Without a location each
    /// duplicate goes onto its original's parents — or onto the duplicate of a parent that is
    /// duplicated too. With `onto` (`-o`) the roots of the originals are duplicated onto those
    /// parents, the rest onto the new duplicates; `insert_after` / `insert_before` (`-A` / `-B`)
    /// also rebase the children the location names onto the duplicates' heads — the location as
    /// `jj new` resolves it, and as `drop_actions`' `duplicate` row previews it. A duplicate that
    /// lands among its original's descendants warns [`crate::WarningKind::DuplicateAsOwnDescendant`],
    /// one among its ancestors [`crate::WarningKind::DuplicateAsOwnAncestor`]; it is made anyway.
    /// Each duplicate's description is `templates.duplicate_description` rendered on its original
    /// (jj's default: the original's description).
    ///
    /// The operation is the CLI's `duplicate <n> commit(s)`; `new_change_ids` names the
    /// duplicates' change ids, in jj-lib's duplication order.
    ///
    /// The working copy is snapshotted first (Story 9.26) — see [`Repo::restore`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `onto` with `insert_after`/`insert_before` (clap's
    ///   refusal: before the snapshot, so nothing is written); "Cannot duplicate the root commit";
    ///   a location that would create a loop or resolves no parent; or (Git backend) a merge with
    ///   the root commit as a parent.
    /// - [`crate::MutateError::ChangeNotFound`] — an id is malformed, carried by no VISIBLE
    ///   commit, or divergent.
    /// - [`crate::MutateError::RevsetResolutionError`] — the default `@` in a workspace with no
    ///   working-copy commit.
    /// - [`crate::MutateError::Immutable`] — a child `insert_after`/`insert_before` would rewrite
    ///   is inside the repo's effective immutable set.
    /// - [`crate::MutateError::Config`] — `templates.duplicate_description` is not a string or does
    ///   not parse ("Failed to parse template: …"), or the `immutable_heads()` alias does not
    ///   resolve.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::NotAGitRepo`] — the colocated finish found no Git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn duplicate(
        &mut self,
        options: &crate::DuplicateOptions,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::duplicate::check_duplicate_args(options), |repo, ctx| {
            crate::duplicate::duplicate(repo.workspace_mut(), ctx, options)
        })
    }

    /// Updates files with formatting fixes or other changes (Story 9.9) — the CLI's `jj fix`.
    ///
    /// The `fix.tools` config is read first: each entry's `command` (a string, an array, or `{
    /// env, command }`), its `patterns` (filesets, relative to the workspace root), `enabled`
    /// (default `true`), `line-range-args` and `run-tool-if-zero-line-ranges`; a deprecated
    /// `line-range-arg` is migrated (and warned, [`crate::WarningKind::ConfigDeprecated`]) as
    /// the CLI migrates it. Then the sources — `options.source`, or the `revsets.fix` setting
    /// (jj's default `reachable(@, mutable())`, parsed like a user revset) — are checked
    /// rewritable, and the files of the sources and their descendants (only the changed ones,
    /// unless `include_unchanged_files`; only under `options.paths` when given) are passed through
    /// every matching tool in key order: stdin the content, stdout the new content, the
    /// workspace root the working directory, `$path` / `$root` interpolated. Unless `all_lines`,
    /// a tool with `line-range-args` gets the changed line ranges. A tool that cannot start
    /// ([`crate::WarningKind::FixToolStartFailed`]) or exits non-zero
    /// ([`crate::WarningKind::FixToolFailed`]) is skipped for that file. A tool run (one file)
    /// that overruns the Zanshin-only `fix.tools.<name>.timeout` — a non-negative integer of
    /// seconds or a string `<n>ms` / `<n>s` / `<n>m`; absent or `0` = none — has its process group
    /// killed and is skipped too ([`crate::WarningKind::FixToolTimedOut`]). Descendants keep the
    /// fixes; no new conflicts arise.
    ///
    /// `cancel` is the CLI's Ctrl-C: once its token is cancelled the call refuses at its next
    /// checkpoint — right after the snapshot, before each tool run, after the tools — and a
    /// running tool's process group is killed (SIGTERM, SIGKILL [`crate::cancel`]'s grace later);
    /// nothing is written. Without a token the call is not cancellable. A refusal — a cancel
    /// included — returns no [`crate::FixResult`], so the tools' stderr collected so far is not
    /// returned; their warnings are ([`Repo::take_warnings`]).
    ///
    /// A call that fixes nothing writes NO operation (`new_op_id` is the pre-call head);
    /// otherwise the operation is the CLI's `fixed <n> commits`. The result counts the fixed and
    /// the checked commits and carries what the tools wrote to stderr.
    ///
    /// The working copy is snapshotted first (Story 9.26) — see [`Repo::restore`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::Cancelled`] — `cancel`'s token was cancelled before or while the
    ///   tools ran; no operation. Never without a token.
    /// - [`crate::MutateError::Config`] — no `fix.tools` entry ("No `fix.tools` are configured"),
    ///   none enabled ("At least one entry of `fix.tools` must be enabled."), one sets
    ///   `run-tool-if-zero-line-ranges` without `line-range-args`, an entry (a malformed `timeout`
    ///   included) or `revsets.fix` has the wrong type, the alias tables do not read, or the
    ///   `immutable_heads()` alias does not resolve.
    /// - [`crate::MutateError::InvalidInput`] — a pattern does not parse ("Failed to parse
    ///   fileset: <kind>" with the CLI's `Caused by:` lines and hint), or a path is not a valid
    ///   repo path.
    /// - [`crate::MutateError::ChangeNotFound`] — a source id is malformed, carried by no VISIBLE
    ///   commit, or divergent.
    /// - [`crate::MutateError::RevsetParseError`] / [`crate::MutateError::RevsetResolutionError`]
    ///   — `revsets.fix` does not parse or resolve.
    /// - [`crate::MutateError::Immutable`] — a source is inside the repo's effective immutable set.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::NotAGitRepo`] — the colocated finish found no Git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn fix(
        &mut self,
        options: &crate::FixOptions,
        cancel: Option<&crate::cancel::CancelGuard>,
    ) -> Result<crate::FixResult, crate::MutateError> {
        self.with_verb(|repo, ctx| crate::fix::fix(repo.workspace_mut(), ctx, options, cancel))
    }

    /// Commits the working-copy commit (Story 9.49) — the CLI's `jj commit -m <message>
    /// [paths]`: `@` keeps the selected changes and gets the description, and a new `@` holds the
    /// rest.
    ///
    /// The selection starts from `@`'s PARENT tree: the changes `@` makes to `paths` —
    /// repo-relative PREFIXES as for [`Repo::restore`]; empty is every change (the CLI's
    /// "describe + new"), `""` the root. `@` is rewritten in place (same change id) with the
    /// selected tree and `message` — the CLI's `-m` paragraphs, joined as it joins them, with
    /// `templates.commit_trailers` added when non-empty (Story 9.51); an empty list is `-m ""` —
    /// so bookmarks on the old `@` follow it and its descendants are rebased
    /// onto it. A NEW commit on top of it gets the old `@`'s full tree, and every workspace whose
    /// `@` was the old `@` edits it.
    ///
    /// Local bookmarks on the old `@`'s parents that `experimental-advance-branches` selects
    /// (`enabled-branches` minus `disabled-branches`, name patterns; the default, an empty
    /// `enabled-branches`, selects none) move to the committed `@`; no other bookmark moves.
    ///
    /// When `paths` is non-empty and selects no change of `@`, the call warns
    /// `jj.commit_paths_unmatched` ("The given paths do not match any file: …") and still commits:
    /// the committed `@` is empty and the new `@` holds every change. There is no rewritability
    /// guard, as in the CLI. The operation is `commit <old @ commit hex>`; `new_change_ids` names
    /// the new `@`.
    ///
    /// `tree` is the tree arm (Story 9.50), in place of the CLI's `--interactive`/`--tool`: the
    /// committed `@` gets that tree, selected in the GUI ([`Repo::select_tree`]) against `@`'s
    /// parent tree, and the new `@` everything else — a change to `@` made after the selection
    /// included. It refuses `jj.stale_selection` when `@`'s parent tree is no longer its `left`.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::NoWorkingCopy`] — this workspace has no working-copy commit (the
    ///   CLI's "This command requires a working copy").
    /// - [`crate::MutateError::InvalidInput`] — `paths` together with `tree`, or a `tree` of the
    ///   wrong shape (malformed hex, an even or zero id count, a label count that is neither zero
    ///   nor the id count) — these before the snapshot, so nothing is written — a path is not a
    ///   valid repo path, or an `experimental-advance-branches` pattern does not parse.
    /// - [`crate::MutateError::StaleSelection`] — `@`'s parent tree is not `tree.left`.
    /// - [`crate::MutateError::Config`] — an `experimental-advance-branches` list is not a list
    ///   of strings, the config could not be read, the `immutable_heads()` alias does not
    ///   resolve (the finish rebases only mutable descendants, as the CLI's `tx.finish`), or (a
    ///   non-empty message, Story 9.51) `templates.commit_trailers` does not parse or render (the
    ///   CLI's texts, see [`Repo::describe`]) — refused before anything is written.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::NotAGitRepo`] — the colocated finish found no Git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn commit(&mut self, options: &crate::CommitOptions) -> Result<crate::MutationResult, crate::MutateError> {
        self.with_checked_verb(crate::commit::check_commit_args(options), |repo, ctx| {
            crate::commit::commit(repo.workspace_mut(), ctx, options)
        })
    }

    /// Writes the tree a hunk selection yields (Story 9.50) — the CLI's builtin diff editor
    /// applying the same choice (`cli/src/merge_tools/builtin.rs:405-545` @ v0.46.0), for the tree
    /// arms of [`Repo::commit`], [`Repo::split`] and [`Repo::squash`].
    ///
    /// The diff is `revision`'s (`None`: `@`) parent tree against its own tree — what those verbs
    /// diff against. `left` is that parent tree as the selection saw it
    /// ([`crate::ShowEntry::parent_tree_ids`]). Each file of `files` is selected
    /// [`crate::FileChoice::Whole`] (the revision's value, whatever the change), by
    /// [`crate::HunkKey`]s — the builtin editor's sections (`ContentDiff::by_line`), which a file
    /// has when both sides are a regular file or a file conflict (materialized with
    /// `ui.conflict-marker-style`) and UTF-8 text without NUL bytes — or by
    /// [`crate::FileChoice::ModeAndHunks`], the builtin editor's mode toggle plus sections, for a
    /// file whose two such sides differ in mode. A changed path not listed keeps its left value,
    /// as does every unselected section; `select_tree.rs`' module doc has the rules.
    ///
    /// Returns the tree's ids and conflict labels; pass them, with `left`, to a verb's tree arm.
    /// Writes NO operation — only the tree's objects reach the store — beyond the pre-verb
    /// snapshot's (Story 9.26). A change to the revision's own content after the selection is
    /// not stale: the verbs take the tree as it is, and the rest stays in the revision.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `left` is malformed hex or has an even or zero
    ///   count; a path is invalid, the root, or listed twice — before the snapshot, as the CLI
    ///   parses its arguments before it snapshots, so nothing is written.
    /// - [`crate::MutateError::ChangeNotFound`] — `revision` is malformed, carried by no VISIBLE
    ///   commit, or divergent.
    /// - [`crate::MutateError::RevsetResolutionError`] — an omitted `revision`'s `@` in a
    ///   workspace with no working-copy commit.
    /// - [`crate::MutateError::StaleSelection`] — the revision's parent tree is not `left`, a key
    ///   is not a current section of its file, keys name a path that can only be selected whole or
    ///   is unchanged, or the mode toggle names a path without a mode change.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed (Story 9.26).
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn select_tree(
        &mut self,
        options: &crate::SelectTreeOptions,
    ) -> Result<crate::SelectedTreeId, crate::MutateError> {
        self.with_checked_verb(crate::select_tree::check_select_tree_args(options), |repo, ctx| {
            crate::select_tree::select_tree(repo.workspace(), &ctx.config, options)
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

    /// Sets (`executable`) or clears the executable bit of the files matching `paths` in one
    /// revision (Story 9.13) — the CLI's `jj file chmod x|n <paths> [-r]`
    /// (`cli/src/commands/file/chmod.rs:60-138` @ v0.46.0).
    ///
    /// `revision` is the CLI's `-r`, a change id; `None` is its default `@`, which the pre-verb
    /// snapshot has just brought up to date. `paths` are parsed as [`Repo::file_track`]'s (at
    /// least one, PREFIXES, no fileset DSL); a path that matches nothing in the revision warns
    /// `jj.paths_unmatched`. Every matching entry must be a file, or a conflict whose every side
    /// is a file — then each file side takes the bit. The revision is rewritten (descendants
    /// rebased) as `make paths executable in commit <hex>` / `make paths non-executable in commit
    /// <hex>`; the rewrite is always recorded, so the operation is always written, as in the
    /// CLI.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `paths` is empty (before the pre-verb snapshot,
    ///   clap's `required`), an entry is empty or escapes the workspace, or a matching entry is
    ///   not a file ("Found neither a file nor a conflict at '<path>'.") or a conflict with a
    ///   non-file side ("Some of the sides of the conflict are not files at '<path>'.").
    /// - [`crate::MutateError::ChangeNotFound`] — `revision` is malformed, absent, only-hidden or
    ///   divergent; [`crate::MutateError::RevsetResolutionError`] — `None` in a workspace with no
    ///   working-copy commit ("Workspace `<name>` doesn't have a working-copy commit").
    /// - [`crate::MutateError::Immutable`] — the revision is immutable (the root included).
    /// - [`crate::MutateError::Config`] — the `immutable_heads()` alias does not resolve.
    /// - [`crate::MutateError::Precondition`] — the pre-verb snapshot failed.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn file_chmod(
        &mut self,
        executable: bool,
        revision: Option<&crate::ChangeId>,
        paths: &[String],
    ) -> Result<crate::MutationResult, crate::MutateError> {
        let args = if paths.is_empty() {
            Err(crate::MutateError::invalid("file chmod requires at least one path"))
        } else {
            Ok(())
        };
        self.with_checked_verb(args, |repo, ctx| {
            crate::wc_ops::file_chmod(repo.workspace_mut(), ctx, executable, revision, paths)
        })
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
            left_behind: Vec::new(),
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

    /// Creates a new jj workspace — the CLI's `jj git init` for `options.backend =
    /// Some(Backend::Git)` (Story 9.20, ported step for step at v0.46.0), or a workspace on jj's
    /// native backend for `None` (Zanshin-only: the destination must exist, no Git flag applies).
    ///
    /// The Git backend follows `cmd_git_init` / `do_init` (`cli/src/commands/git/init.rs:146-288`):
    ///
    /// 1. the CLI's start-up config check, before any path is touched (`git.colocate` and
    ///    `git.object-hash` are read from that start-up stack);
    /// 2. the destination is created when missing — ONE level, `create_or_reuse_dir` — and
    ///    canonicalized ("Failed to create workspace" otherwise);
    /// 3. colocation is `git.colocate ? colocate != Some(false) : colocate == Some(true)` and the
    ///    hash is `object_hash`, else `git.object-hash`;
    /// 4. over an existing `.git/`: colocated, the External flow — the steps
    ///    [`crate::convert_colocated`] runs (`import git refs`, the snapshot, `.jj/.gitignore`, the
    ///    `trunk()` alias; their report in [`CreationOutcome::precondition`] and the warnings);
    ///    not colocated, the CLI's refusal; otherwise a colocated workspace
    ///    (its start-up environment built, `.jj/.gitignore` = `/*`) or an internal one. No
    ///    operation beyond jj-lib's `add workspace` is written outside the External flow.
    ///
    /// Nothing is cleaned up on failure beyond what jj-lib's creation removes itself (`.jj`), as
    /// in the CLI. The created workspace is then opened as by [`Repo::open`], whose errors apply
    /// too; the handle carries the full config stack.
    ///
    /// # What a failure leaves
    ///
    /// [`CreationOutcome::left_behind`] names, outermost first, the canonical destination when
    /// this call created it, then `<root>/.jj` when this call's jj-lib creation
    /// (`init_external_git` over an existing `.git/`, `init_colocated_git`, `init_internal_git`,
    /// `init_simple`) returned `Ok`, then — for a NEW colocated init — the `<root>/.git`
    /// `init_colocated_git` created (jj-lib's own cleanup removes only `.jj`, so it can stay even
    /// when that call fails) — each only while it still exists (a failed re-open included). It
    /// is empty on success and on every refusal that wrote nothing (an existing `.jj/`,
    /// `--no-colocate` over `.git/`, a missing parent).
    ///
    /// # Warnings
    ///
    /// First the start-up check's `jj.config_deprecated` (one per deprecated key the CLI
    /// migrates, Story 9.9 — on a refusal too); then the colocated arm's start-up environment
    /// (alias tables, `immutable_heads()`), and the External flow's warnings
    /// ([`crate::convert_colocated`]'s); nothing more for the internal and native arms.
    ///
    /// # Errors
    ///
    /// In [`CreationOutcome::result`]:
    /// - [`RepoError::Config`] — the start-up stack or the new workspace's stack cannot be read,
    ///   or `git.colocate` / `git.object-hash` is malformed.
    /// - [`RepoError::InitFailed`] — the destination cannot be created ("Failed to create
    ///   workspace": a missing parent, a file) or the jj-lib creation failed; for the native
    ///   backend also a missing destination.
    /// - [`RepoError::GitRepoExists`] — `--no-colocate` over an existing `.git/` (the CLI's "Did
    ///   not create a jj repo because there is an existing Git repo in this directory.").
    /// - [`RepoError::AlreadyJjRepo`] — the destination is already a jj workspace.
    /// - [`RepoError::ConvertFailed`] — a step of the External flow failed.
    /// - [`RepoError::InvalidInput`] — the native backend with a colocation flag or a hash.
    #[must_use = "the outcome carries the result, the snapshot report and the warnings"]
    pub fn init(options: &crate::InitOptions) -> CreationOutcome {
        crate::creation::init(options)
    }

    /// Clones a Git repository into a new jj workspace — the CLI's `jj git clone` (Story 9.20,
    /// ported step for step at v0.46.0, `cli/src/commands/git/clone.rs:170-460`).
    ///
    /// 1. The CLI's start-up config check; then the destination: a non-empty directory or a file
    ///    is refused before anything is created, a missing one is created with its parents.
    /// 2. Colocation (`git.colocate` with the two flags), the `-b` / `-t` patterns and the object
    ///    hash resolve; a fault here leaves the created directory, as in the CLI.
    /// 3. Inside the clean-up scope: the workspace is created (colocated or internal) with its
    ///    start-up environment and `.jj/.gitignore`; the fetch expressions are the flags, else
    ///    `remotes.<remote>.fetch-bookmarks` / `fetch-tags`, else everything; `add git remote
    ///    <remote>` is finished and the workspace reloaded (a second start-up environment); the
    ///    fetch runs (progress as `"clone"` [`crate::ProgressEvent`]s on `progress`), the working
    ///    branch is chosen (the first exact `-b` the remote has, else its default branch), the
    ///    default bookmark tracked (`git.track-default-bookmark-on-clone`) and `fetch from git
    ///    remote into empty repo` finished — when it changed anything. A failure here removes
    ///    `.jj` (and `.git` when colocated), then the destination iff the call created it.
    /// 4. The repo presets (`remotes.<remote>.fetch-bookmarks` / `fetch-tags` for `-b` / `-t`,
    ///    `revset-aliases.'trunk()' = <branch>@<remote>` for a default working branch), then
    ///    `check out git remote's branch: <name>`. A failure from here keeps the workspace.
    ///
    /// Every operation is finished like the CLI's `tx.finish`, so each warns the identity check,
    /// the became-immutable check and — colocated — the export failures on its own. The handle is
    /// then opened as by [`Repo::open`], whose errors apply too.
    ///
    /// # Warnings
    ///
    /// In the CLI's order: the start-up check's `jj.config_deprecated` (Story 9.9), the start-up
    /// environment's (twice: before and after the reload), the first finish's, `jj.clone_branches_unmatched`, `jj.git_import_failed`, the fetch finish's,
    /// the checkout finish's (`jj.checkout_files_skipped`, `jj.unresolved_conflicts`,
    /// `jj.identity_missing`, …); on a failure inside the clean-up scope, `jj.clone_cleanup_failed`
    /// last when the clean-up failed.
    ///
    /// # Errors
    ///
    /// In [`CreationOutcome::result`]:
    /// - [`RepoError::DestinationNotEmpty`] — the destination is a file or a non-empty directory.
    /// - [`RepoError::InvalidInput`] — a `-b` / `-t` pattern does not parse, or the remote name is
    ///   refused (reserved `git`, a slash, or a name Git rejects) at `add git remote`.
    /// - [`RepoError::Config`] — the start-up or the new workspace's config cannot be read, or a
    ///   key the clone reads (`git.colocate`, `git.object-hash`, `git.*` import options,
    ///   `remotes.<name>.*`, `git.track-default-bookmark-on-clone`) is malformed; or the presets
    ///   could not be written; or `revset-aliases."immutable_heads()"` does not resolve — the
    ///   first finish with changes (`add git remote <name>`) resolves the immutable set as the
    ///   CLI's `tx.finish` does and refuses inside the clean-up scope, so what the clone created
    ///   is removed and no operation survives; a refusal at a finish outside that scope (the
    ///   checkout's `check out git remote's branch`) keeps the workspace, as the CLI's. The reason
    ///   names the unresolved symbol (Story 9.57 closing run).
    /// - [`RepoError::NetworkError`] — the fetch's or the default-branch query's `git` subprocess
    ///   failed (an unreachable source, an authentication failure, `git` not runnable); the reason
    ///   is the git failure (jj-lib's message with its cause).
    /// - [`RepoError::Cancelled`] — `cancel`'s token was cancelled before or after the fetch's git
    ///   work, or git failed after the cancel (Story 9.52); what the clone created is removed.
    /// - [`RepoError::CloneFailed`] — creating the destination, the jj-lib creation, registering
    ///   the remote (e.g. an unparseable source URL), another fetch failure (e.g. rejected ref
    ///   updates), the import or the checkout failed.
    #[must_use = "the outcome carries the result and the warnings"]
    pub fn clone(
        options: &crate::CloneOptions,
        progress: &crate::ProgressFn,
        cancel: Option<&crate::cancel::CancelGuard>,
    ) -> CreationOutcome {
        crate::creation::clone(options, progress, cancel)
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use test_helpers::{extract_fixture, FixtureHandle};

    use super::{Repo, RepoError};
    use crate::MutateError;

    /// Story 9.56: the `trunk()` fallback lasts one call — a verb that fell back leaves it off
    /// afterwards, so a later config load outside a call (`log_defaults`) sees no override.
    #[test]
    fn the_trunk_fallback_ends_with_its_call() {
        test_helpers::pin_test_env();
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let mut repo = Repo::init(&crate::InitOptions {
            path: tmp.path().to_path_buf(),
            backend: Some(crate::Backend::Git),
            colocate: Some(false),
            ..Default::default()
        })
        .result
        .expect("init");
        std::fs::write(
            repo.workspace_root().join(".jj").join("repo").join("config.toml"),
            "[revset-aliases]\n'trunk()' = 'main@origin'\n",
        )
        .expect("repo config");
        let _ = repo.take_warnings();

        let _ = repo
            .eval_revset("trunk()", |_| std::ops::ControlFlow::Continue(()))
            .expect("falls back");

        assert!(
            repo.take_warnings()
                .iter()
                .any(|w| w.kind == crate::WarningKind::TrunkAliasUnresolved),
            "the call fell back"
        );
        assert!(!repo.trunk_fallback(), "and the fallback ended with it");
        let _ = repo.workspace_update_stale();
        assert!(
            repo.take_warnings()
                .iter()
                .any(|w| w.kind == crate::WarningKind::TrunkAliasUnresolved),
            "workspace_update_stale fell back too"
        );
        assert!(!repo.trunk_fallback(), "and ended it");
        let root = repo.resolve_workspace_root(Some("default")).expect("the named root");
        assert_eq!(
            std::fs::canonicalize(root).expect("recorded root"),
            std::fs::canonicalize(repo.workspace_root()).expect("root")
        );
        assert!(
            repo.take_warnings()
                .iter()
                .any(|w| w.kind == crate::WarningKind::TrunkAliasUnresolved),
            "the named workspace root fell back too"
        );
        assert!(!repo.trunk_fallback(), "and ended it");
    }

    /// Story 9.56: `init`'s existing-Git-repo refusal carries the CLI's hint, a clone failure its
    /// own list, and the rest none.
    #[test]
    fn repo_error_hints_follow_the_variant() {
        assert_eq!(
            RepoError::GitRepoExists { path: "/x".into() }.hints(),
            ["To create a repo backed by the existing Git repo, run `jj git init --colocate` instead."]
        );
        assert_eq!(
            RepoError::CloneFailed {
                reason: String::new(),
                hints: vec!["h".to_owned()],
            }
            .hints(),
            ["h"]
        );
        assert!(RepoError::NotARepo { path: "/x".into() }.hints().is_empty());
    }

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
