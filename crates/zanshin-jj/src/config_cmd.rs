// SPDX-License-Identifier: MIT

//! The jj config surface (Story 9.28) — the CLI's `jj config` group @ v0.44.0
//! (`cli/src/commands/config/{list,get,path,set,unset,edit,gc}.rs`) as typed free functions.
//!
//! # Free functions, not `Repo` methods
//!
//! The CLI's config verbs never load the workspace (except `set`'s `check_wc_author`), so a
//! value only jj-lib's workspace load reads — a wrong-typed `git.*` key, say — does not block
//! them. A `Repo` handle cannot even be opened in that state, so every verb here takes the
//! workspace ROOT instead (the CLI's `-R`; `None` = run outside any workspace) and derives the
//! repo and workspace dirs through jj-lib's own workspace loader.
//!
//! # Per verb, the CLI's steps
//!
//! 1. **Start-up stack** — every verb except the two editor halves loads the raw stack, resolves
//!    it with the verb's CLI command name and builds `UserSettings` from it, exactly as the CLI's
//!    `run_internal` does BEFORE it dispatches: a TOML error in any layer or a wrong-typed
//!    start-up key (`user.*`, `operation.*`, `signing.*`, `debug.*`) refuses with
//!    [`ConfigCmdError::Config`]. With a workspace root, that load is the CLI's start-up load
//!    (Story 9.37): the secure-config fix-up (a legacy file migrated, a copied repo's config
//!    forked, a missing secure directory regenerated — `config.rs`' module doc) runs for the
//!    repo, then the workspace layer, each right before it loads, and its notices are the verb's
//!    first warnings ([`ConfigOutcome::warnings`]), on success AND on failure. Without a root
//!    nothing is fixed up, and `config gc` runs no fix-up either.
//! 2. **File selection** (`set`, `unset`, the editor halves) — the CLI's `edit_config_file` @
//!    v0.46.0 over a [`ConfigTarget`]: a scope's FIRST file, else the CLI's new-file default;
//!    `--file PATH` only when PATH is a location jj recognizes, else
//!    [`ConfigCmdError::UnrecognizedFile`].
//! 3. **Edit + save** through `config.rs`'s writer family — `toml_edit` keeps comments and
//!    formatting. The write itself writes no operation (config files are not repo state; only
//!    `set`'s identity-check snapshot may, as in the CLI). An open
//!    [`crate::Repo`] picks every write up on its next verb through its stack fingerprint.
//!
//! `jj config edit` becomes two halves because the GUI replaces `$EDITOR`:
//! [`config_file_read`] (creates the file as the CLI does before opening the editor) and
//! [`config_file_write`] (validates the text as TOML BEFORE writing — the CLI's re-edit loop,
//! with the UI holding the buffer). Neither loads the start-up stack: they are the stand-in for
//! the user's own editor, the CLI's repair path for a broken config. With a workspace root both
//! still start with the secure-config fix-up alone, loading no file.
//!
//! `jj config gc`'s yes/no prompt likewise becomes [`config_gc_list`] + [`config_gc_delete`].

use std::collections::BTreeSet;
use std::ops::Range;
use std::path::{Path, PathBuf};

use jj_lib::config::{ConfigLayer, ConfigLoadError, ConfigNamePathBuf, ConfigSource, ConfigValue, StackedConfig};
use jj_lib::repo::Repo as _;
use jj_lib::secure_config;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::{DefaultWorkspaceLoaderFactory, WorkspaceLoaderFactory as _};

use crate::config::{self, ConfigEnv, SecureLayer, WorkspacePaths};

// ── Public types ──────────────────────────────────────────────────────────────

/// A config level the CLI's `--user` / `--repo` / `--workspace` flags name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigScope {
    /// The user config: `JJ_CONFIG`, else `~/.jjconfig.toml` / `<config_dir>/jj/config.toml` /
    /// `<config_dir>/jj/conf.d`.
    User,
    /// The repo config: `<config_dir>/jj/repos/<config-id>/config.toml`.
    Repo,
    /// The workspace config: `<config_dir>/jj/workspaces/<workspace-config-id>/config.toml`.
    Workspace,
}

impl ConfigScope {
    fn source(self) -> ConfigSource {
        match self {
            Self::User => ConfigSource::User,
            Self::Repo => ConfigSource::Repo,
            Self::Workspace => ConfigSource::Workspace,
        }
    }

    /// The word the CLI's refusals use (`No repo config path found`).
    fn word(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Repo => "repo",
            Self::Workspace => "workspace",
        }
    }
}

/// The file `set`, `unset` and `edit` write — the CLI's `ConfigTargetArgs` @ v0.46.0
/// (`--user | --repo | --workspace | --file PATH`, exactly one).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigTarget {
    /// The scope's first file, else its new-file default.
    Scope(ConfigScope),
    /// One file, which must be a location jj recognizes as a config file: a loaded layer's file,
    /// the repo or workspace config file, a user config path, or a `*.toml` directly inside a
    /// user config directory. A relative path is taken relative to the workspace root — the GUI
    /// has no current directory to resolve it against.
    File(PathBuf),
}

/// Which layer of the stack a listed value comes from — jj-lib's `ConfigSource` minus the
/// command-line layer, which Zanshin has no counterpart of.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigValueSource {
    /// jj's (and Zanshin's builtin) defaults.
    Default,
    /// `/etc/jj/config.toml` or `/etc/jj/conf.d`.
    System,
    /// Environment values config files override (`operation.hostname`, `ui.editor`, …).
    EnvBase,
    /// A user config file.
    User,
    /// The repo config file.
    Repo,
    /// The workspace config file.
    Workspace,
    /// Environment values that override every file (`JJ_USER`, `JJ_EMAIL`, …).
    EnvOverrides,
}

impl From<ConfigSource> for ConfigValueSource {
    fn from(source: ConfigSource) -> Self {
        match source {
            ConfigSource::Default => Self::Default,
            ConfigSource::System => Self::System,
            ConfigSource::EnvBase => Self::EnvBase,
            ConfigSource::User => Self::User,
            ConfigSource::Repo => Self::Repo,
            ConfigSource::Workspace => Self::Workspace,
            // WHY one arm: Zanshin builds no `CommandArg` layer, so only `EnvOverrides` occurs.
            ConfigSource::EnvOverrides | ConfigSource::CommandArg => Self::EnvOverrides,
        }
    }
}

/// One row of [`config_list`] — the CLI's `AnnotatedValue`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigEntry {
    /// The dotted name (`user.name`, `revset-aliases."trunk()"`).
    pub name: String,
    /// The value as TOML text, surrounding whitespace trimmed (strings stay quoted).
    pub value: String,
    /// The layer it comes from.
    pub source: ConfigValueSource,
    /// The file it comes from; `None` for the default and environment layers.
    pub path: Option<PathBuf>,
    /// True if a higher-precedence layer shadows it.
    pub overridden: bool,
}

/// The filters of [`config_list`] — `jj config list [NAME] [--user|--repo|--workspace]
/// [--include-defaults] [--include-overridden]`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConfigListQuery {
    /// Only values under this dotted name prefix.
    pub name: Option<String>,
    /// Only values of this scope. The CLI refuses a scope together with `include_defaults`;
    /// here the scope wins.
    pub scope: Option<ConfigScope>,
    /// Include the default layer (only without a scope).
    pub include_defaults: bool,
    /// Include values shadowed by a higher layer.
    pub include_overridden: bool,
}

/// `@`'s author when a `user.name` / `user.email` write does not match it — the CLI's "This
/// setting will only impact future commits" warning, as a fact. Both CURRENT fields.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkingCopyAuthor {
    /// `@`'s author name.
    pub name: String,
    /// `@`'s author email.
    pub email: String,
}

/// A successful [`config_set`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigSetResult {
    /// The file written.
    pub path: PathBuf,
    /// Present iff `user.name`/`user.email` was set and `@`'s author differs from the new
    /// value (use `jj metaedit --update-author` to change `@`).
    pub working_copy_author: Option<WorkingCopyAuthor>,
}

/// [`config_set`]'s outcome: the result, and the report of the working-copy snapshot the
/// CLI's `check_wc_author` runs for `user.name`/`user.email` — `Some` iff that snapshot ran,
/// on success AND on failure (then possibly partial) — and the call's warnings (Story 9.32).
#[derive(Debug)]
pub struct ConfigSetOutcome {
    /// The verb's result.
    pub result: Result<ConfigSetResult, ConfigCmdError>,
    /// The snapshot report, when the snapshot ran.
    pub precondition: Option<crate::Precondition>,
    /// The call's warnings, on success AND on failure, in the CLI's order: the start-up
    /// secure-config fix-up's (Story 9.37), the snapshot's (config loads, snapshot, imports),
    /// then `jj.config_working_copy_author` when `@`'s author stays the old one.
    pub warnings: Vec<crate::Warning>,
}

/// What a config verb reports (Story 9.37) — [`config_list`], [`config_get`], [`config_path`],
/// [`config_unset`], [`config_file_read`] and [`config_file_write`]: the result, and the warnings
/// the jj CLI would have printed on the way, on success AND on failure. A verb with a workspace
/// root starts with the CLI's secure-config fix-up, whose one-shot notices
/// (`jj.config_migrated`, `jj.config_copied`, `jj.config_regenerated`) must survive a refusal —
/// a `config get` of an unset key right after a migration still reports the migration.
#[derive(Debug)]
pub struct ConfigOutcome<T> {
    /// The verb's result.
    pub result: Result<T, ConfigCmdError>,
    /// The call's warnings in the CLI's print order; empty when there were none.
    pub warnings: Vec<crate::Warning>,
}

/// Runs a verb body with a fresh warning list and wraps both into its [`ConfigOutcome`].
fn outcome<T>(body: impl FnOnce(&mut Vec<crate::Warning>) -> Result<T, ConfigCmdError>) -> ConfigOutcome<T> {
    let mut warnings = Vec::new();
    let result = body(&mut warnings);
    ConfigOutcome { result, warnings }
}

/// A config file's text, as [`config_file_read`] returns it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigFileText {
    /// The file.
    pub path: PathBuf,
    /// Its exact contents.
    pub text: String,
}

/// A repo config directory whose recorded repo no longer exists ([`config_gc_list`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MissingRepoConfig {
    /// `<config_dir>/jj/repos/<config-id>`.
    pub config_dir: PathBuf,
    /// The repo path its `metadata.binpb` records.
    pub repo_path: PathBuf,
}

/// A directory [`config_gc_delete`] did not delete, and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigGcFailure {
    /// The directory.
    pub config_dir: PathBuf,
    /// Why it was not deleted.
    pub reason: String,
}

/// What [`config_gc_delete`] did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConfigGcResult {
    /// The directories deleted, in the sorted missing order.
    pub deleted: Vec<PathBuf>,
    /// The requested directories that were not deleted.
    pub failed: Vec<ConfigGcFailure>,
}

/// Errors of the config verbs — the CLI's refusal set.
#[derive(Debug, thiserror::Error)]
pub enum ConfigCmdError {
    /// The config stack does not load (a file unreadable or not TOML, a malformed id file, a
    /// wrong-typed start-up key), or the selected file could not be read or written.
    #[error("config error: {reason}")]
    Config {
        /// Human-readable failure, naming the file or key.
        reason: String,
    },
    /// The workspace root does not exist.
    #[error("path not found: {path}")]
    PathNotFound {
        /// The caller's path.
        path: PathBuf,
    },
    /// The workspace root is not a jj workspace.
    #[error("not a jj repository: {path}")]
    NotARepo {
        /// The caller's path.
        path: PathBuf,
    },
    /// `get` of a name with no value (`Value not found for <name>`), or `unset` of a name the
    /// file does not hold (`"<name>" doesn't exist`).
    #[error("{reason}")]
    NotFound {
        /// The CLI's message.
        reason: String,
    },
    /// `set` would overwrite a table, or a non-table parent value.
    #[error("{reason}")]
    WouldOverwrite {
        /// `Failed to set <name>: <jj-lib reason>`.
        reason: String,
    },
    /// `unset` names a whole table.
    #[error("{reason}")]
    WouldDeleteTable {
        /// `Failed to unset <name>: <jj-lib reason>`.
        reason: String,
    },
    /// [`ConfigTarget::File`] names a path jj does not recognize as a config file location; no
    /// config file was written (with a workspace root the repo and workspace secure directories
    /// may have been created first, as the CLI creates them while it checks).
    #[error("Configuration file '{}' is not a valid jj configuration file location", .path.display())]
    UnrecognizedFile {
        /// The path as resolved (a relative one joined onto the workspace root).
        path: PathBuf,
    },
    /// A name, value or file text is not valid TOML.
    #[error("{message}")]
    Parse {
        /// The TOML parser's message.
        message: String,
        /// The byte span it points at, when it reports one.
        span: Option<Range<usize>>,
    },
    /// No file of the scope can be determined (`No user config path found`, `No config
    /// directory found`, …).
    #[error("{reason}")]
    NoConfigPath {
        /// The CLI's message.
        reason: String,
    },
}

impl ConfigCmdError {
    /// The jj CLI's hint lines for this refusal, verbatim (Story 9.56): where config files may
    /// live, for an unrecognized `--file` (`cli/src/config.rs:737-741` @ v0.46.0); none otherwise.
    #[must_use]
    pub fn hints(&self) -> Vec<String> {
        match self {
            Self::UnrecognizedFile { .. } => vec![
                "Valid config locations include user configs (`~/.config/jj/config.toml` or `conf.d/*.toml`), \
                 repo/workspace configs, or files loaded with the global flag `--config-file <PATH>`."
                    .to_owned(),
            ],
            _ => Vec::new(),
        }
    }
}

impl From<crate::ConfigError> for ConfigCmdError {
    fn from(e: crate::ConfigError) -> Self {
        let crate::ConfigError::Load { reason } = e;
        Self::Config { reason }
    }
}

// ── Public verbs ──────────────────────────────────────────────────────────────

/// `jj config list` — every value of the effective stack with its source (the CLI's
/// `resolved_config_values`), lowest layer first, filtered as the CLI filters. An empty list is
/// a result, not an error — it warns `jj.config_nothing_listed` with the CLI's "No matching config
/// key for: …" / "No config to list." (`list.rs:116-123`, Story 9.32), after the start-up
/// fix-up's warnings (Story 9.37).
///
/// # Errors
///
/// In [`ConfigOutcome::result`]:
/// - [`ConfigCmdError::PathNotFound`] / [`ConfigCmdError::NotARepo`] — bad `workspace_root`.
/// - [`ConfigCmdError::Config`] — the stack does not load, or the start-up fix-up failed.
/// - [`ConfigCmdError::Parse`] — `query.name` is not a TOML dotted key.
#[must_use = "the outcome carries the result and the warnings"]
pub fn config_list(workspace_root: Option<&Path>, query: &ConfigListQuery) -> ConfigOutcome<Vec<ConfigEntry>> {
    outcome(|warnings| list_with(&ConfigEnv::from_env(), workspace_root, query, warnings))
}

/// `jj config get NAME` — a string unquoted, anything else (a table merged into an inline
/// table included) as TOML text.
///
/// # Errors
///
/// In [`ConfigOutcome::result`]:
/// - [`ConfigCmdError::PathNotFound`] / [`ConfigCmdError::NotARepo`] — bad `workspace_root`.
/// - [`ConfigCmdError::Config`] — the stack does not load, or the start-up fix-up failed.
/// - [`ConfigCmdError::Parse`] — `name` is not a TOML dotted key.
/// - [`ConfigCmdError::NotFound`] — no layer sets `name`.
#[must_use = "the outcome carries the result and the warnings"]
pub fn config_get(workspace_root: Option<&Path>, name: &str) -> ConfigOutcome<String> {
    outcome(|warnings| get_with(&ConfigEnv::from_env(), workspace_root, name, warnings))
}

/// `jj config path --user|--repo|--workspace` — user: every candidate in the CLI's order,
/// existing or not, creating nothing; repo / workspace: the secure file, CREATING its config
/// directory and id file when missing (the CLI's documented side effect; the `config.toml`
/// itself is not created).
///
/// # Errors
///
/// In [`ConfigOutcome::result`]:
/// - [`ConfigCmdError::PathNotFound`] / [`ConfigCmdError::NotARepo`] — bad `workspace_root`.
/// - [`ConfigCmdError::Config`] — the stack does not load, the start-up fix-up failed, or the
///   secure directory could not be created.
/// - [`ConfigCmdError::NoConfigPath`] — no path can be determined (no user candidate, or no
///   workspace / config directory for repo and workspace scope).
#[must_use = "the outcome carries the result and the warnings"]
pub fn config_path(workspace_root: Option<&Path>, scope: ConfigScope) -> ConfigOutcome<Vec<PathBuf>> {
    outcome(|warnings| path_with(&ConfigEnv::from_env(), workspace_root, scope, warnings))
}

/// `jj config set --user|--repo|--workspace|--file PATH NAME VALUE` — `value_text` is a TOML
/// expression, falling back to a bare string (the CLI's `parse_value_or_bare_string`); `target`
/// picks the file as the CLI does (see the module doc).
///
/// For `user.name`/`user.email` with a workspace, the working copy is snapshotted first (the
/// CLI's `check_wc_author`; a failure there is silently skipped) and `@`'s author compared.
/// The config write itself writes no operation; only that snapshot may (a dirty `@`), exactly
/// as the CLI's `check_wc_author`.
///
/// # Errors
///
/// In [`ConfigSetOutcome::result`]: bad `workspace_root`, [`ConfigCmdError::Config`],
/// [`ConfigCmdError::Parse`] (name or value), [`ConfigCmdError::NoConfigPath`],
/// [`ConfigCmdError::UnrecognizedFile`], [`ConfigCmdError::WouldOverwrite`].
#[must_use = "the outcome carries the result and the snapshot report"]
pub fn config_set(
    workspace_root: Option<&Path>,
    target: &ConfigTarget,
    name: &str,
    value_text: &str,
) -> ConfigSetOutcome {
    set_with(&ConfigEnv::from_env(), workspace_root, target, (name, value_text))
}

/// `jj config unset --user|--repo|--workspace|--file PATH NAME`; returns the file written.
///
/// # Errors
///
/// In [`ConfigOutcome::result`]: bad `workspace_root`, [`ConfigCmdError::Config`],
/// [`ConfigCmdError::Parse`], [`ConfigCmdError::NoConfigPath`],
/// [`ConfigCmdError::UnrecognizedFile`], [`ConfigCmdError::WouldDeleteTable`],
/// [`ConfigCmdError::NotFound`] (`"<name>" doesn't exist`). As in the CLI, repo/workspace scope
/// creates the secure directory even when it then refuses.
#[must_use = "the outcome carries the result and the warnings"]
pub fn config_unset(workspace_root: Option<&Path>, target: &ConfigTarget, name: &str) -> ConfigOutcome<PathBuf> {
    outcome(|warnings| unset_with(&ConfigEnv::from_env(), workspace_root, target, name, warnings))
}

/// `jj config edit`, editor half 1: the file the CLI would open, and its exact text. An absent
/// file is created first with jj-lib's empty document (its `#:schema` header), as the CLI saves
/// it before starting the editor. Loads no start-up stack, so a broken config can be repaired —
/// but with a workspace root it starts with the CLI's secure-config fix-up alone (Story 9.37),
/// whose notices are [`ConfigOutcome::warnings`].
///
/// # Errors
///
/// In [`ConfigOutcome::result`]: bad `workspace_root`, [`ConfigCmdError::NoConfigPath`],
/// [`ConfigCmdError::UnrecognizedFile`], [`ConfigCmdError::Config`] (the fix-up failed, or the
/// file could not be created or read, or is not UTF-8).
#[must_use = "the outcome carries the result and the warnings"]
pub fn config_file_read(workspace_root: Option<&Path>, target: &ConfigTarget) -> ConfigOutcome<ConfigFileText> {
    outcome(|warnings| file_read_with(&ConfigEnv::from_env(), workspace_root, target, warnings))
}

/// `jj config edit`, editor half 2: replaces the file at `path` with `text` — only a location
/// [`config_file_read`] accepts for this root (checked without creating anything; a relative
/// `path` joined onto the workspace root), and only after `text` parses as TOML (nothing is
/// written otherwise). Like half 1, it starts with the secure-config fix-up alone when there is
/// a workspace root (Story 9.37).
///
/// # Errors
///
/// In [`ConfigOutcome::result`]: bad `workspace_root`; [`ConfigCmdError::UnrecognizedFile`]
/// (`path` is not such a location); [`ConfigCmdError::Parse`] (with the span);
/// [`ConfigCmdError::Config`] (the fix-up or the write failed).
#[must_use = "the outcome carries the result and the warnings"]
pub fn config_file_write(workspace_root: Option<&Path>, path: &Path, text: &str) -> ConfigOutcome<()> {
    outcome(|warnings| file_write_with(&ConfigEnv::from_env(), workspace_root, path, text, warnings))
}

/// `jj config gc`, half 1: the repo config directories under `<config_dir>/jj/repos` whose
/// recorded repo no longer exists, sorted.
///
/// # Errors
///
/// - [`ConfigCmdError::Config`] — the stack does not load, or the root cannot be read.
/// - [`ConfigCmdError::NoConfigPath`] — `No config directory found`.
pub fn config_gc_list() -> Result<Vec<MissingRepoConfig>, ConfigCmdError> {
    gc_list_with(&ConfigEnv::from_env())
}

/// `jj config gc`, half 2: deletes those of `dirs` that are still missing repo config
/// directories; every other request, and every per-directory failure, rides
/// [`ConfigGcResult::failed`]. A directory that could not be DELETED also warns
/// `jj.config_gc_delete_failed` (the CLI's "Failed to delete …", `gc.rs:80-84`, Story 9.32); a
/// request that is not a missing repo config directory has no CLI counterpart and is data only.
///
/// # Errors
///
/// As [`config_gc_list`].
pub fn config_gc_delete(dirs: &[PathBuf]) -> Result<crate::Warned<ConfigGcResult>, ConfigCmdError> {
    gc_delete_with(&ConfigEnv::from_env(), dirs)
}

// ── Shared steps ──────────────────────────────────────────────────────────────

/// The repo dir (`.jj/repo`, through a secondary workspace's indirection) and workspace root.
struct WorkspaceDirs {
    repo_path: PathBuf,
    workspace_root: PathBuf,
}

impl WorkspaceDirs {
    fn paths(&self) -> WorkspacePaths<'_> {
        WorkspacePaths {
            repo_path: &self.repo_path,
            workspace_root: &self.workspace_root,
        }
    }
}

/// The CLI's `-R`: canonicalize, then jj-lib's workspace loader (no walk-up).
fn resolve_workspace(root: Option<&Path>) -> Result<Option<WorkspaceDirs>, ConfigCmdError> {
    let Some(path) = root else {
        return Ok(None);
    };
    let canonical = std::fs::canonicalize(path).map_err(|_| ConfigCmdError::PathNotFound { path: path.to_owned() })?;
    let loader = DefaultWorkspaceLoaderFactory
        .create(&canonical)
        .map_err(|_| ConfigCmdError::NotARepo { path: path.to_owned() })?;
    Ok(Some(WorkspaceDirs {
        repo_path: loader.repo_path().to_owned(),
        workspace_root: loader.workspace_root().to_owned(),
    }))
}

/// The editor halves' start-up (Story 9.37): the CLI's secure-config fix-up ALONE, loading no
/// file, so it cannot refuse a stack the halves exist to repair; nothing without a workspace.
fn fix_up(
    env: &ConfigEnv,
    ws: Option<&WorkspaceDirs>,
    warnings: &mut Vec<crate::Warning>,
) -> Result<(), ConfigCmdError> {
    if let Some(ws) = ws {
        config::fix_up_layers(env, ws.paths(), warnings)?;
    }
    Ok(())
}

/// The CLI's start-up: raw stack → resolved with `command` (and migrated) → `UserSettings`. With
/// `fix_ups` (and a workspace) the raw load is the CLI's start-up load, secure-config fix-up
/// included (Story 9.37); its warnings land there, on success AND on failure, followed by the
/// migrations' "Deprecated … config" warnings (Story 9.9).
fn startup(
    env: &ConfigEnv,
    ws: Option<&WorkspaceDirs>,
    command: &str,
    mut fix_ups: Option<&mut Vec<crate::Warning>>,
) -> Result<UserSettings, ConfigCmdError> {
    let paths = ws.map(WorkspaceDirs::paths);
    let raw = config::load_raw(env, paths, fix_ups.as_deref_mut())?;
    let (resolved, deprecations) = config::resolve_raw(env, paths, &raw, Some(command))?;
    if let Some(sink) = fix_ups {
        sink.extend(config::deprecation_warnings(deprecations));
    }
    Ok(config::settings_from(env, resolved)?)
}

/// A TOML parse failure as [`ConfigCmdError::Parse`] (message + span). `toml_edit`'s error type
/// is not re-exported by jj-lib, so it arrives wrapped in the `ConfigLoadError::Parse` it is
/// jj-lib's source of.
fn toml_error(err: ConfigLoadError) -> ConfigCmdError {
    match err {
        ConfigLoadError::Parse { error, .. } => ConfigCmdError::Parse {
            message: error.message().trim_end().to_owned(),
            span: error.span(),
        },
        other @ ConfigLoadError::Read(_) => ConfigCmdError::Config {
            reason: other.to_string(),
        },
    }
}

fn parse_name(name: &str) -> Result<ConfigNamePathBuf, ConfigCmdError> {
    name.parse::<ConfigNamePathBuf>().map_err(|error| {
        toml_error(ConfigLoadError::Parse {
            error: Box::new(error),
            source_path: None,
        })
    })
}

/// The CLI's `parse_value_or_bare_string` (`cli/src/config.rs:64-70` @ v0.44.0): a TOML value
/// expression, else — when it does not look like one — the text as a bare string.
fn parse_value_or_bare_string(value_str: &str) -> Result<ConfigValue, ConfigCmdError> {
    match value_str.parse::<ConfigValue>() {
        Ok(value) => Ok(value),
        Err(_) if is_bare_string(value_str) => Ok(value_str.into()),
        Err(error) => Err(toml_error(ConfigLoadError::Parse {
            error: Box::new(error),
            source_path: None,
        })),
    }
}

/// The CLI's `is_bare_string` (`cli/src/config.rs:72-82`).
fn is_bare_string(value_str: &str) -> bool {
    // leading whitespace isn't ignored when parsing TOML value expression, but
    // "\n[]" doesn't look like a bare string.
    let trimmed = value_str.trim_ascii().as_bytes();
    if let (Some(&first), Some(&last)) = (trimmed.first(), trimmed.last()) {
        // string, array, or table constructs?
        !matches!(first, b'"' | b'\'' | b'[' | b'{') && !matches!(last, b'"' | b'\'' | b']' | b'}')
    } else {
        true // empty or whitespace only
    }
}

/// One value of the stack with its source — the CLI's `AnnotatedValue`.
struct AnnotatedValue {
    name: ConfigNamePathBuf,
    value: ConfigValue,
    source: ConfigSource,
    path: Option<PathBuf>,
    is_overridden: bool,
}

/// The CLI's `resolved_config_values` (`cli/src/config.rs:148-204` @ v0.44.0), verbatim: walks
/// the layers top-down, marks each value shadowed by a value or table in an upper layer, and
/// flattens tables (inline ones too, since their members can be overridden independently).
fn resolved_config_values(stacked_config: &StackedConfig, filter_prefix: &ConfigNamePathBuf) -> Vec<AnnotatedValue> {
    let mut config_vals = vec![];
    let mut upper_value_names = BTreeSet::new();
    for layer in stacked_config.layers().iter().rev() {
        let top_item = match layer.look_up_item(filter_prefix) {
            Ok(Some(item)) => item,
            Ok(None) => continue, // parent is a table, but no value found
            Err(_) => {
                // parent is not a table, shadows lower layers
                upper_value_names.insert(filter_prefix.clone());
                continue;
            }
        };
        let mut config_stack = vec![(filter_prefix.clone(), top_item, false)];
        while let Some((name, item, is_parent_overridden)) = config_stack.pop() {
            if let Some(table) = item.as_table_like() {
                // current table and children may be shadowed by value in upper layer
                let is_overridden = is_parent_overridden || upper_value_names.contains(&name);
                for (k, v) in table.iter() {
                    let mut sub_name = name.clone();
                    sub_name.push(k);
                    config_stack.push((sub_name, v, is_overridden)); // in reverse order
                }
            } else {
                // current value may be shadowed by value or table in upper layer
                let maybe_child = upper_value_names
                    .range(&name..)
                    .next()
                    .filter(|next| next.starts_with(&name));
                let is_overridden = is_parent_overridden || maybe_child.is_some();
                if maybe_child != Some(&name) {
                    upper_value_names.insert(name.clone());
                }
                // WHY `let … else`, not the CLI's `expect`: `Item::None` cannot occur in a
                // loaded table, and nothing reachable from FFI may panic.
                let Ok(value) = item.clone().into_value() else { continue };
                config_vals.push(AnnotatedValue {
                    name,
                    value,
                    source: layer.source,
                    path: layer.path.clone(),
                    is_overridden,
                });
            }
        }
    }
    config_vals.reverse();
    config_vals
}

/// The repo or workspace secure layer of `ws`.
fn secure_layer(env: &ConfigEnv, ws: &WorkspaceDirs, scope: ConfigScope) -> SecureLayer {
    let [repo, workspace] = config::secure_layers(env, ws.paths());
    if scope == ConfigScope::Workspace {
        workspace
    } else {
        repo
    }
}

/// The create-forced secure file of a repo/workspace scope; `None` without a workspace or a
/// `<config_dir>`.
fn secure_create(
    env: &ConfigEnv,
    ws: Option<&WorkspaceDirs>,
    scope: ConfigScope,
) -> Result<Option<PathBuf>, ConfigCmdError> {
    Ok(ws
        .map(|ws| secure_layer(env, ws, scope).create_path(env.randomness_seed()))
        .transpose()?
        .flatten())
}

/// The CLI's `ConfigTargetArgs::edit_config_file` (`cli/src/commands/config/mod.rs` @ v0.46.0):
/// a scope's FIRST file — the user scope's first existing file, else its new-file default; the
/// repo / workspace scope's create-forced secure file — or a [`ConfigTarget::File`] through
/// [`resolve_file_to_edit`]. Returns the file with the source it is written as.
fn select_file(
    env: &ConfigEnv,
    ws: Option<&WorkspaceDirs>,
    target: &ConfigTarget,
) -> Result<(PathBuf, ConfigSource), ConfigCmdError> {
    let scope = match target {
        ConfigTarget::Scope(scope) => *scope,
        ConfigTarget::File(path) => return resolve_file_to_edit(env, ws, path, true),
    };
    let first = if scope == ConfigScope::User {
        config::user_edit_candidates(env)
            .into_iter()
            .next()
            .or_else(|| new_user_config_file(env))
    } else {
        secure_create(env, ws, scope)?
    };
    first
        .map(|path| (path, scope.source()))
        .ok_or_else(|| ConfigCmdError::NoConfigPath {
            reason: format!("No {} config path found to edit", scope.word()),
        })
}

/// The CLI's `ConfigEnv::resolve_file_to_edit` (`cli/src/config.rs:682-742` @ v0.46.0), with a
/// relative `path` taken against the workspace root instead of the CWD (none without a root). In
/// the CLI's order: a loaded layer's file — system, user, repo, workspace, enumerated without
/// parsing so the editor halves still reach a broken file — then the repo, then the workspace
/// secure file, then a user config path or a `*.toml` directly inside a user config directory.
///
/// With `create` (`set`, `unset`, the read half) both secure files are create-forced while they
/// are checked, as the CLI's `repo_config_path` / `workspace_config_path` force them — even when
/// the match turns out to be a user file — and a matched new file's parent is created `0700`.
/// Without it (the write half) nothing is created.
fn resolve_file_to_edit(
    env: &ConfigEnv,
    ws: Option<&WorkspaceDirs>,
    path: &Path,
    create: bool,
) -> Result<(PathBuf, ConfigSource), ConfigCmdError> {
    let path = ws.map_or_else(|| path.to_owned(), |ws| ws.workspace_root.join(path));
    if path.is_relative() {
        return Err(ConfigCmdError::UnrecognizedFile { path });
    }
    let canonical = std::fs::canonicalize(&path).ok();
    let matches = |p: &Path| p == path || Some(p) == canonical.as_deref();
    let secure = match ws {
        Some(ws) => secure_files(env, ws)?,
        None => Vec::new(),
    };
    let loaded = config::system_edit_candidates(env)
        .into_iter()
        .map(|p| (p, ConfigSource::System))
        .chain(
            config::user_edit_candidates(env)
                .into_iter()
                .map(|p| (p, ConfigSource::User)),
        )
        .chain(secure.iter().filter(|(p, _)| p.exists()).cloned());
    if let Some(found) = loaded.into_iter().find(|(p, _)| matches(p)) {
        return Ok(found);
    }
    for scope in [ConfigScope::Repo, ConfigScope::Workspace] {
        // WHY `.ok()`: the CLI's `if let Ok(Some(..))` skips a failed creation the same way.
        let file = if create {
            secure_create(env, ws, scope).ok().flatten()
        } else {
            secure
                .iter()
                .find(|(_, s)| *s == scope.source())
                .map(|(p, _)| p.clone())
        };
        if file.is_some_and(|f| matches(&f)) {
            return Ok((with_parent(path, create), scope.source()));
        }
    }
    let user = config::user_config_candidates(env);
    if user.iter().any(|u| matches(u) || is_file_in_config_dir(&path, u)) {
        return Ok((with_parent(path, create), ConfigSource::User));
    }
    Err(ConfigCmdError::UnrecognizedFile { path })
}

/// `path`, its parent created `0700` first when `create` — errors ignored, as the CLI ignores
/// them (the save names them).
fn with_parent(path: PathBuf, create: bool) -> PathBuf {
    if let Some(dir) = path.parent().filter(|_| create) {
        config::create_private_dir_all(dir).ok();
    }
    path
}

/// The CLI's `is_file_in_config_dir` (`cli/src/config.rs:787-801` @ v0.46.0): `file` is a
/// `*.toml` directly inside `dir`, which is not a file.
fn is_file_in_config_dir(file: &Path, dir: &Path) -> bool {
    if file.extension() != Some(std::ffi::OsStr::new("toml")) || dir.is_file() {
        return false;
    }
    file.parent()
        .is_some_and(|parent| parent == dir || std::fs::canonicalize(parent).ok().as_deref() == Some(dir))
}

/// The CLI's `new_user_config_file`: the first candidate, its parent created `0700` (errors
/// ignored — the save names them later).
fn new_user_config_file(env: &ConfigEnv) -> Option<PathBuf> {
    let path = config::user_config_candidates(env).into_iter().next()?;
    if let Some(dir) = path.parent() {
        config::create_private_dir_all(dir).ok();
    }
    Some(path)
}

fn io_error(path: &Path, e: &dyn std::fmt::Display) -> ConfigCmdError {
    ConfigCmdError::Config {
        reason: format!("{}: {e}", path.display()),
    }
}

// ── Verb bodies over an explicit environment ────────────────────────────────

fn list_with(
    env: &ConfigEnv,
    root: Option<&Path>,
    query: &ConfigListQuery,
    warnings: &mut Vec<crate::Warning>,
) -> Result<Vec<ConfigEntry>, ConfigCmdError> {
    let ws = resolve_workspace(root)?;
    let settings = startup(env, ws.as_ref(), "config list", Some(warnings))?;
    let name = query.name.as_deref().map(parse_name).transpose()?;
    let prefix = name.clone().unwrap_or_else(ConfigNamePathBuf::root);
    let mut values = resolved_config_values(settings.config(), &prefix);
    // The default layer could be excluded beforehand, but not the scope filter: shadowing is
    // computed over every layer first (the CLI's own note).
    if let Some(scope) = query.scope {
        values.retain(|v| v.source == scope.source());
    } else if !query.include_defaults {
        values.retain(|v| v.source != ConfigSource::Default);
    }
    if !query.include_overridden {
        values.retain(|v| !v.is_overridden);
    }
    if values.is_empty() {
        // The CLI's note on stderr explaining why the output is empty (`list.rs:116-123`).
        let message = name.map_or_else(
            || "No config to list.".to_owned(),
            |name| format!("No matching config key for: {name}"),
        );
        warnings.push(crate::warning::local(crate::WarningKind::ConfigNothingListed, message));
    }
    Ok(values
        .into_iter()
        .map(|v| ConfigEntry {
            name: v.name.to_string(),
            value: v.value.decorated("", "").to_string(),
            source: v.source.into(),
            path: v.path,
            overridden: v.is_overridden,
        })
        .collect())
}

fn get_with(
    env: &ConfigEnv,
    root: Option<&Path>,
    name: &str,
    warnings: &mut Vec<crate::Warning>,
) -> Result<String, ConfigCmdError> {
    let ws = resolve_workspace(root)?;
    let settings = startup(env, ws.as_ref(), "config get", Some(warnings))?;
    let name = parse_name(name)?;
    // WHY every error is NotFound: `get_value`'s conversion is the identity, so `NotFound` is
    // the only `ConfigGetError` it can return.
    let value = settings
        .config()
        .get_value(&name)
        .map_err(|e| ConfigCmdError::NotFound { reason: e.to_string() })?;
    Ok(match value {
        // Remove extra formatting from a string value
        ConfigValue::String(v) => v.into_value(),
        // Print other values in TOML syntax (but whitespace trimmed)
        other => other.decorated("", "").to_string(),
    })
}

fn path_with(
    env: &ConfigEnv,
    root: Option<&Path>,
    scope: ConfigScope,
    warnings: &mut Vec<crate::Warning>,
) -> Result<Vec<PathBuf>, ConfigCmdError> {
    let ws = resolve_workspace(root)?;
    startup(env, ws.as_ref(), "config path", Some(warnings))?;
    let paths: Vec<PathBuf> = if scope == ConfigScope::User {
        config::user_config_candidates(env)
    } else {
        secure_create(env, ws.as_ref(), scope)?.into_iter().collect()
    };
    if paths.is_empty() {
        return Err(ConfigCmdError::NoConfigPath {
            reason: format!("No {} config path found", scope.word()),
        });
    }
    Ok(paths)
}

/// `set`'s body; `(name, value_text)` travel as one pair.
fn set_with(
    env: &ConfigEnv,
    root: Option<&Path>,
    target: &ConfigTarget,
    (name, value_text): (&str, &str),
) -> ConfigSetOutcome {
    let mut precondition = None;
    let mut warnings = Vec::new();
    let result = (|| -> Result<ConfigSetResult, ConfigCmdError> {
        let ws = resolve_workspace(root)?;
        startup(env, ws.as_ref(), "config set", Some(&mut warnings))?;
        let name = parse_name(name)?;
        let value = parse_value_or_bare_string(value_text)?;
        let (file_path, source) = select_file(env, ws.as_ref(), target)?;
        let working_copy_author = if let (Some(field), Some(ws)) = (author_field(&name), &ws) {
            check_wc_author(&ws.workspace_root, field, &value, (&mut precondition, &mut warnings))
        } else {
            None
        };
        if let Some(author) = &working_copy_author {
            // `warn_wc_author` (`cli/src/commands/config/set.rs:120-127` @ v0.44.0).
            warnings.push(crate::warning::local(
                crate::WarningKind::ConfigWorkingCopyAuthor,
                format!(
                    "This setting will only impact future commits.\nThe author of the working copy will stay \
                     \"{} <{}>\".\nTo change the working copy author, use \"jj metaedit --update-author\".",
                    author.name, author.email
                ),
            ));
        }
        let mut file = config::load_config_file(source, &file_path)?;
        file.set_value(&name, value)
            .map_err(|e| ConfigCmdError::WouldOverwrite {
                reason: format!("Failed to set {name}: {e}"),
            })?;
        config::save_config_file(&file)?;
        Ok(ConfigSetResult {
            path: file_path,
            working_copy_author,
        })
    })();
    ConfigSetOutcome {
        result,
        precondition,
        warnings,
    }
}

/// Which author field a `user.name` / `user.email` write changes.
#[derive(Clone, Copy)]
enum AuthorField {
    Name,
    Email,
}

fn author_field(name: &ConfigNamePathBuf) -> Option<AuthorField> {
    if *name == ConfigNamePathBuf::from_iter(["user", "name"]) {
        Some(AuthorField::Name)
    } else if *name == ConfigNamePathBuf::from_iter(["user", "email"]) {
        Some(AuthorField::Email)
    } else {
        None
    }
}

/// The CLI's `check_wc_author` (`cli/src/commands/config/set.rs:94-113` @ v0.44.0): load and
/// SNAPSHOT the workspace (its `workspace_helper`; any failure → skip silently), then compare
/// `@`'s author field with the new value — a non-string value always differs. The snapshot's
/// report and warnings land in `out`, on success AND on failure.
fn check_wc_author(
    workspace_root: &Path,
    field: AuthorField,
    value: &ConfigValue,
    (precondition, warnings): (&mut Option<crate::Precondition>, &mut Vec<crate::Warning>),
) -> Option<WorkingCopyAuthor> {
    let mut repo = crate::Repo::open(workspace_root).ok()?;
    let snapshot = repo.snapshot();
    warnings.extend(repo.take_warnings());
    let Ok(report) = snapshot else {
        *precondition = repo.take_precondition();
        return None;
    };
    *precondition = Some(report);
    let (name, email) = working_copy_author(&repo)?;
    let orig = match field {
        AuthorField::Name => &name,
        AuthorField::Email => &email,
    };
    let differs = value.as_str() != Some(orig.as_str());
    differs.then_some(WorkingCopyAuthor { name, email })
}

/// `@`'s `(author name, author email)` at the head operation.
fn working_copy_author(repo: &crate::Repo) -> Option<(String, String)> {
    let workspace = repo.workspace();
    let head = pollster::block_on(workspace.repo_loader().load_at_head()).ok()?;
    let id = head.view().get_wc_commit_id(workspace.workspace_name())?;
    let author = head.store().get_commit(id).ok()?.author().clone();
    Some((author.name, author.email))
}

fn unset_with(
    env: &ConfigEnv,
    root: Option<&Path>,
    target: &ConfigTarget,
    name: &str,
    warnings: &mut Vec<crate::Warning>,
) -> Result<PathBuf, ConfigCmdError> {
    let ws = resolve_workspace(root)?;
    startup(env, ws.as_ref(), "config unset", Some(warnings))?;
    let name = parse_name(name)?;
    let (file_path, source) = select_file(env, ws.as_ref(), target)?;
    let mut file = config::load_config_file(source, &file_path)?;
    let old = file.delete_value(&name).map_err(|e| ConfigCmdError::WouldDeleteTable {
        reason: format!("Failed to unset {name}: {e}"),
    })?;
    if old.is_none() {
        return Err(ConfigCmdError::NotFound {
            reason: format!("\"{name}\" doesn't exist"),
        });
    }
    config::save_config_file(&file)?;
    Ok(file_path)
}

fn file_read_with(
    env: &ConfigEnv,
    root: Option<&Path>,
    target: &ConfigTarget,
    warnings: &mut Vec<crate::Warning>,
) -> Result<ConfigFileText, ConfigCmdError> {
    let ws = resolve_workspace(root)?;
    fix_up(env, ws.as_ref(), warnings)?;
    let (file_path, source) = select_file(env, ws.as_ref(), target)?;
    if !file_path.exists() {
        config::save_config_file(&config::load_config_file(source, &file_path)?)?;
    }
    let bytes = std::fs::read(&file_path).map_err(|e| io_error(&file_path, &e))?;
    let text = String::from_utf8(bytes).map_err(|e| io_error(&file_path, &e))?;
    Ok(ConfigFileText { path: file_path, text })
}

/// The repo and workspace SECURE files of `ws` with their source, resolved side-effect-free
/// (they may not exist): only when their id file exists (never the legacy fallback) and their
/// secure dir records this repo/workspace (never a COPIED repo's original). Every caller runs the
/// start-up fix-up first (Story 9.37), which migrates the legacy file and forks the copy, so these
/// two filters only matter for a layer that fix-up could not fix — e.g. a copy jj-lib could not
/// fork, such as a read-only one.
///
/// # Errors
///
/// - [`ConfigCmdError::Config`] — an id file is unreadable or malformed.
fn secure_files(env: &ConfigEnv, ws: &WorkspaceDirs) -> Result<Vec<(PathBuf, ConfigSource)>, ConfigCmdError> {
    let mut files = Vec::new();
    for layer in config::secure_layers(env, ws.paths()) {
        if layer.has_id_file() {
            let path = layer.resolved_path()?.filter(|p| !layer.records_another_dir(p));
            files.extend(path.map(|p| (p, layer.source)));
        }
    }
    Ok(files)
}

fn file_write_with(
    env: &ConfigEnv,
    root: Option<&Path>,
    path: &Path,
    text: &str,
    warnings: &mut Vec<crate::Warning>,
) -> Result<(), ConfigCmdError> {
    let ws = resolve_workspace(root)?;
    fix_up(env, ws.as_ref(), warnings)?;
    let (path, source) = resolve_file_to_edit(env, ws.as_ref(), path, false)?;
    ConfigLayer::parse(source, text).map_err(toml_error)?;
    if source == ConfigSource::User {
        // A new user file's parent, as `new_user_config_file` / the read half create it (errors
        // ignored — the write names them).
        if let Some(dir) = path.parent() {
            config::create_private_dir_all(dir).ok();
        }
    }
    std::fs::write(&path, text).map_err(|e| io_error(&path, &e))
}

/// `<config_dir>/jj/repos`, after the start-up stack (no workspace).
fn gc_root(env: &ConfigEnv) -> Result<PathBuf, ConfigCmdError> {
    startup(env, None, "config gc", None)?;
    env.root_config_dir()
        .map(|r| r.join("repos"))
        .ok_or_else(|| ConfigCmdError::NoConfigPath {
            reason: "No config directory found".to_owned(),
        })
}

/// The CLI's `find_missing_repo_configs` (`cli/src/commands/config/gc.rs:88-129` @ v0.44.0).
fn find_missing_repo_configs(root: &Path) -> Result<Vec<MissingRepoConfig>, ConfigCmdError> {
    let failed = |verb: &str, e: std::io::Error| ConfigCmdError::Config {
        reason: format!("Failed to {verb} {}: {e}", root.display()),
    };
    if !root.try_exists().map_err(|e| failed("check", e))? {
        return Ok(Vec::new());
    }
    let read_dir = std::fs::read_dir(root).map_err(|e| failed("read", e))?;
    let mut missing = Vec::new();
    for entry in read_dir {
        let config_dir = entry.map_err(|e| failed("read", e))?.path();
        if !config_dir.is_dir() {
            continue;
        }
        let Ok(metadata) = secure_config::read_metadata(&config_dir) else {
            continue;
        };
        let Ok(Some(repo_path)) = secure_config::metadata_path(&metadata) else {
            continue;
        };
        // Treat "exists" errors (e.g. permission denied) as "still exists" so we don't propose
        // deleting configs we can't actually verify.
        if !repo_path.try_exists().unwrap_or(true) {
            let repo_path = repo_path.to_owned();
            missing.push(MissingRepoConfig { config_dir, repo_path });
        }
    }
    missing.sort_by(|a, b| (&a.config_dir, &a.repo_path).cmp(&(&b.config_dir, &b.repo_path)));
    Ok(missing)
}

fn gc_list_with(env: &ConfigEnv) -> Result<Vec<MissingRepoConfig>, ConfigCmdError> {
    find_missing_repo_configs(&gc_root(env)?)
}

fn gc_delete_with(env: &ConfigEnv, dirs: &[PathBuf]) -> Result<crate::Warned<ConfigGcResult>, ConfigCmdError> {
    let missing = find_missing_repo_configs(&gc_root(env)?)?;
    let mut result = ConfigGcResult::default();
    let mut warnings = Vec::new();
    for m in missing.iter().filter(|m| dirs.contains(&m.config_dir)) {
        match secure_config::remove_repo_config_dir(&m.config_dir) {
            Ok(()) => result.deleted.push(m.config_dir.clone()),
            Err(e) => {
                warnings.push(crate::warning::local(
                    crate::WarningKind::ConfigGcDeleteFailed,
                    format!("Failed to delete {}: {e}", m.config_dir.display()),
                ));
                result.failed.push(ConfigGcFailure {
                    config_dir: m.config_dir.clone(),
                    reason: e.to_string(),
                });
            }
        }
    }
    for dir in dirs.iter().filter(|d| !missing.iter().any(|m| &m.config_dir == *d)) {
        result.failed.push(ConfigGcFailure {
            config_dir: dir.clone(),
            reason: "not a missing repo config directory".to_owned(),
        });
    }
    Ok(crate::Warned {
        value: result,
        warnings,
    })
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::ffi::OsString;
    use std::fs;
    use std::path::{Path, PathBuf};

    use jj_lib::config::{ConfigLayer, ConfigLoadError, ConfigNamePathBuf, ConfigSource, StackedConfig};

    use super::{
        gc_delete_with, gc_list_with, is_bare_string, parse_value_or_bare_string, resolve_workspace,
        resolved_config_values, set_with, toml_error, ConfigCmdError, ConfigEntry, ConfigListQuery, ConfigScope,
        ConfigTarget, ConfigValueSource, WorkspaceDirs,
    };
    use crate::config::{self, ConfigEnv};

    const HEADER: &str = "#:schema https://docs.jj-vcs.dev/latest/config-schema.json\n\n";

    /// Story 9.56: only an unrecognized `--file` carries a hint.
    #[test]
    fn only_an_unrecognized_file_carries_a_hint() {
        assert_eq!(ConfigCmdError::UnrecognizedFile { path: "x".into() }.hints().len(), 1);
        assert!(ConfigCmdError::Config { reason: String::new() }.hints().is_empty());
    }

    // The verb bodies take the call's warning sink (Story 9.37); these adapters keep the rows
    // below at the pre-sink shape — `list_with` hands its sink back as a `Warned`.

    fn list_with(
        env: &ConfigEnv,
        root: Option<&Path>,
        query: &ConfigListQuery,
    ) -> Result<crate::Warned<Vec<ConfigEntry>>, ConfigCmdError> {
        let mut warnings = Vec::new();
        super::list_with(env, root, query, &mut warnings).map(|value| crate::Warned { value, warnings })
    }

    fn get_with(env: &ConfigEnv, root: Option<&Path>, name: &str) -> Result<String, ConfigCmdError> {
        super::get_with(env, root, name, &mut Vec::new())
    }

    fn path_with(env: &ConfigEnv, root: Option<&Path>, scope: ConfigScope) -> Result<Vec<PathBuf>, ConfigCmdError> {
        super::path_with(env, root, scope, &mut Vec::new())
    }

    fn unset_with(
        env: &ConfigEnv,
        root: Option<&Path>,
        target: &ConfigTarget,
        name: &str,
    ) -> Result<PathBuf, ConfigCmdError> {
        super::unset_with(env, root, target, name, &mut Vec::new())
    }

    fn file_read_with(
        env: &ConfigEnv,
        root: Option<&Path>,
        target: &ConfigTarget,
    ) -> Result<super::ConfigFileText, ConfigCmdError> {
        super::file_read_with(env, root, target, &mut Vec::new())
    }

    fn file_write_with(env: &ConfigEnv, root: Option<&Path>, path: &Path, text: &str) -> Result<(), ConfigCmdError> {
        super::file_write_with(env, root, path, text, &mut Vec::new())
    }

    /// Discovery ON, everything inside `dir`: `<dir>/home` is `$HOME`, `<dir>/cfg` the config
    /// dir; no system layer, no environment.
    fn env_in(dir: &Path) -> ConfigEnv {
        ConfigEnv {
            config_dir: Some(dir.join("cfg")),
            home_dir: Some(dir.join("home")),
            jj_config: None,
            environment: HashMap::new(),
            system_config_dir: None,
            hostname: None,
            username: None,
        }
    }

    /// `JJ_CONFIG=""`: no user path at all, the config dir still known.
    fn env_without_user(dir: &Path) -> ConfigEnv {
        ConfigEnv {
            jj_config: Some(OsString::new()),
            ..env_in(dir)
        }
    }

    fn user_file(dir: &Path) -> PathBuf {
        dir.join("cfg").join("jj").join("config.toml")
    }

    fn write(path: &Path, body: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, body).unwrap();
    }

    /// A fresh native-backend workspace; returns `(tempdir, root)`.
    fn workspace() -> (tempfile::TempDir, PathBuf) {
        test_helpers::pin_test_env();
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("ws");
        fs::create_dir(&root).unwrap();
        crate::Repo::init(&crate::InitOptions {
            path: std::path::PathBuf::from(&root),
            ..Default::default()
        })
        .result
        .expect("init");
        (tmp, root)
    }

    fn query() -> ConfigListQuery {
        ConfigListQuery::default()
    }

    fn names(entries: &[ConfigEntry]) -> Vec<(&str, &str, ConfigValueSource, bool)> {
        entries
            .iter()
            .map(|e| (e.name.as_str(), e.value.as_str(), e.source, e.overridden))
            .collect()
    }

    // ── The two verbatim ports ──────────────────────────────────────────────

    /// The CLI's own oracle table (`cli/src/config.rs:1111-1145` @ v0.44.0).
    #[test]
    fn parse_value_or_bare_string_matches_the_cli_table() {
        let parse = |s: &str| parse_value_or_bare_string(s).expect(s);
        assert_eq!(parse("true").as_bool(), Some(true));
        assert_eq!(parse("42").as_integer(), Some(42));
        assert_eq!(parse("-1").as_integer(), Some(-1));
        assert_eq!(parse("'a'").as_str(), Some("a"));
        assert!(parse("[]").is_array());
        assert!(parse("{ a = 'b' }").is_inline_table());
        for bare in [
            "",
            "John Doe",
            "Doe, John",
            "It's okay",
            "<foo+bar@example.org>",
            "#ff00aa",
            "all()",
            "glob:*.*",
            "柔術",
        ] {
            assert_eq!(parse(bare).as_str(), Some(bare));
        }
        for bad in [
            "'foo",
            r#" bar" "#,
            "[0 1]",
            "{ x = y }",
            "\n { x",
            " x ] ",
            "[table]\nkey = 'value'",
        ] {
            assert!(
                matches!(parse_value_or_bare_string(bad), Err(ConfigCmdError::Parse { .. })),
                "{bad:?} must refuse"
            );
        }
        assert!(is_bare_string("   "));
    }

    fn layer(source: ConfigSource, body: &str) -> ConfigLayer {
        ConfigLayer::parse(source, body).unwrap()
    }

    /// The CLI's `test_resolved_config_values_single_key`: lowest layer first, a shadowed value
    /// flagged.
    #[test]
    fn resolved_config_values_marks_shadowed_values_lowest_layer_first() {
        let mut stack = StackedConfig::empty();
        stack.add_layer(layer(
            ConfigSource::EnvBase,
            "user.name = 'base-user-name'\nuser.email = 'base@user.email'\n",
        ));
        stack.add_layer(layer(ConfigSource::Repo, "user.email = 'repo@user.email'\n"));
        let rows: Vec<(String, bool)> = resolved_config_values(&stack, &ConfigNamePathBuf::root())
            .into_iter()
            .map(|v| (format!("{}={}", v.name, v.value.decorated("", "")), v.is_overridden))
            .collect();
        assert_eq!(
            rows,
            [
                ("user.name='base-user-name'".to_owned(), false),
                ("user.email='base@user.email'".to_owned(), true),
                ("user.email='repo@user.email'".to_owned(), false),
            ]
        );
        assert!(resolved_config_values(&StackedConfig::empty(), &ConfigNamePathBuf::root()).is_empty());
    }

    /// An upper VALUE where a lower layer has a TABLE shadows the whole table, and a prefix whose
    /// parent is not a table in an upper layer shadows the lower ones.
    #[test]
    fn resolved_config_values_shadows_tables_and_non_table_parents() {
        let mut stack = StackedConfig::empty();
        stack.add_layer(layer(ConfigSource::User, "[a]\nb = 1\nc = { d = 2 }\n"));
        stack.add_layer(layer(ConfigSource::Repo, "a = 3\n"));
        let root: Vec<(String, bool)> = resolved_config_values(&stack, &ConfigNamePathBuf::root())
            .into_iter()
            .map(|v| (v.name.to_string(), v.is_overridden))
            .collect();
        assert_eq!(
            root,
            [
                ("a.b".to_owned(), true),
                ("a.c.d".to_owned(), true),
                ("a".to_owned(), false)
            ]
        );
        let prefix: ConfigNamePathBuf = "a.b".parse().unwrap();
        let under: Vec<bool> = resolved_config_values(&stack, &prefix)
            .into_iter()
            .map(|v| v.is_overridden)
            .collect();
        assert_eq!(
            under,
            [true],
            "the repo's `a = 3` is a non-table parent that shadows `a.b`"
        );
    }

    #[test]
    fn a_read_failure_is_a_config_error_not_a_parse_error() {
        let err = toml_error(ConfigLoadError::Read(jj_lib::file_util::PathError {
            path: PathBuf::from("/x.toml"),
            source: std::io::Error::other("boom"),
        }));
        assert!(matches!(err, ConfigCmdError::Config { .. }), "{err}");
    }

    // ── Workspace root (`-R`) and the start-up stack ────────────────────────

    #[test]
    fn a_bad_workspace_root_refuses_like_repo_open() {
        let tmp = tempfile::tempdir().unwrap();
        let missing = tmp.path().join("nope");
        assert!(matches!(
            resolve_workspace(Some(&missing)),
            Err(ConfigCmdError::PathNotFound { path }) if path == missing
        ));
        assert!(matches!(
            resolve_workspace(Some(tmp.path())),
            Err(ConfigCmdError::NotARepo { .. })
        ));
        assert!(resolve_workspace(None).unwrap().is_none());
    }

    /// A broken user file fails every stack-reading verb at start-up — and the editor halves
    /// still read and repair it.
    #[test]
    fn a_broken_user_file_refuses_the_stack_verbs_but_not_the_editor_halves() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let file = user_file(tmp.path());
        write(&file, "[user\nname = ");
        for err in [
            list_with(&env, None, &query()).map(|_| ()).unwrap_err(),
            get_with(&env, None, "user.name").map(|_| ()).unwrap_err(),
            path_with(&env, None, ConfigScope::User).map(|_| ()).unwrap_err(),
            unset_with(&env, None, &ConfigTarget::Scope(ConfigScope::User), "user.name")
                .map(|_| ())
                .unwrap_err(),
            set_with(&env, None, &ConfigTarget::Scope(ConfigScope::User), ("user.name", "x"))
                .result
                .map(|_| ())
                .unwrap_err(),
            gc_list_with(&env).map(|_| ()).unwrap_err(),
            gc_delete_with(&env, &[]).map(|_| ()).unwrap_err(),
        ] {
            assert!(
                matches!(&err, ConfigCmdError::Config { reason } if reason.contains("config.toml")),
                "{err}"
            );
        }
        let read = file_read_with(&env, None, &ConfigTarget::Scope(ConfigScope::User)).expect("read");
        assert_eq!(
            (read.path.as_path(), read.text.as_str()),
            (file.as_path(), "[user\nname = ")
        );
        file_write_with(&env, None, &file, "[user]\nname = 'fixed'\n").expect("repair");
        assert_eq!(get_with(&env, None, "user.name").unwrap(), "fixed");
    }

    // ── list / get ──────────────────────────────────────────────────────────

    #[test]
    fn list_filters_like_the_cli() {
        let (tmp, root) = workspace();
        let env = ConfigEnv {
            environment: HashMap::from([
                ("EDITOR".to_owned(), "vi".to_owned()),
                ("JJ_USER".to_owned(), "x".to_owned()),
            ]),
            ..env_in(tmp.path())
        };
        write(
            &user_file(tmp.path()),
            "[user]\nemail = 'user@x'\n[revsets]\nlog = '@'\n",
        );
        set_with(
            &env,
            Some(&root),
            &ConfigTarget::Scope(ConfigScope::Repo),
            ("user.email", "repo@x"),
        )
        .result
        .expect("repo set");

        let rows = list_with(&env, Some(&root), &query()).unwrap().value;
        for (name, value, source) in [
            ("ui.editor", "\"vi\"", ConfigValueSource::EnvBase),
            ("user.name", "\"x\"", ConfigValueSource::EnvOverrides),
        ] {
            let row = rows.iter().find(|r| r.name == name && r.source == source).expect(name);
            assert_eq!((row.value.as_str(), row.path.as_deref()), (value, None), "{name}");
        }
        assert!(rows
            .iter()
            .all(|r| r.source != ConfigValueSource::Default && !r.overridden));
        assert!(names(&rows).contains(&("user.email", "\"repo@x\"", ConfigValueSource::Repo, false)));

        let with_overridden = ConfigListQuery {
            include_overridden: true,
            ..query()
        };
        let with_overridden = list_with(&env, Some(&root), &with_overridden).unwrap().value;
        assert!(names(&with_overridden).contains(&("user.email", "'user@x'", ConfigValueSource::User, true)));

        let defaults = ConfigListQuery {
            include_defaults: true,
            ..query()
        };
        let defaults = list_with(&env, Some(&root), &defaults).unwrap().value;
        assert!(defaults.iter().any(|r| r.source == ConfigValueSource::Default));

        let repo_only = ConfigListQuery {
            scope: Some(ConfigScope::Repo),
            include_defaults: true,
            ..query()
        };
        let repo_only = list_with(&env, Some(&root), &repo_only).unwrap().value;
        assert_eq!(
            names(&repo_only),
            [("user.email", "\"repo@x\"", ConfigValueSource::Repo, false)]
        );
        assert!(repo_only[0]
            .path
            .as_ref()
            .is_some_and(|p| p.starts_with(tmp.path().join("cfg"))));

        let prefixed = ConfigListQuery {
            name: Some("revsets".to_owned()),
            ..query()
        };
        let prefixed = list_with(&env, Some(&root), &prefixed).unwrap();
        assert!(prefixed.warnings.is_empty(), "{:?}", prefixed.warnings);
        assert_eq!(
            names(&prefixed.value),
            [("revsets.log", "'@'", ConfigValueSource::User, false)]
        );

        // Story 9.32: a prefix matching nothing warns with the CLI's note.
        let nothing = ConfigListQuery {
            name: Some("nope".to_owned()),
            ..query()
        };
        let nothing = list_with(&env, Some(&root), &nothing).unwrap();
        assert!(nothing.value.is_empty());
        assert_eq!(nothing.warnings.len(), 1, "{:?}", nothing.warnings);
        assert_eq!(nothing.warnings[0].kind, crate::WarningKind::ConfigNothingListed);
        assert_eq!(nothing.warnings[0].message, "No matching config key for: nope");

        let bad = ConfigListQuery {
            name: Some("a..b".to_owned()),
            ..query()
        };
        assert!(matches!(list_with(&env, None, &bad), Err(ConfigCmdError::Parse { .. })));
    }

    #[test]
    fn get_formats_like_the_cli() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        write(
            &user_file(tmp.path()),
            "[user]\nname = \"A B\"\n[foo]\nbar = 1\nbaz = \"x\"\n",
        );
        assert_eq!(get_with(&env, None, "user.name").unwrap(), "A B");
        assert_eq!(get_with(&env, None, "snapshot.max-new-file-size").unwrap(), "1MiB");
        assert_eq!(get_with(&env, None, "ui.log-synthetic-elided-nodes").unwrap(), "true");
        assert_eq!(get_with(&env, None, "foo").unwrap(), "{ bar = 1, baz = \"x\" }");
        assert!(matches!(
            get_with(&env, None, "nope.key"),
            Err(ConfigCmdError::NotFound { reason }) if reason == "Value not found for nope.key"
        ));
        assert!(matches!(get_with(&env, None, ""), Err(ConfigCmdError::Parse { .. })));
    }

    // ── path ────────────────────────────────────────────────────────────────

    #[test]
    fn path_lists_user_candidates_and_creates_the_secure_dirs() {
        let (tmp, root) = workspace();
        let env = env_in(tmp.path());
        assert_eq!(
            path_with(&env, None, ConfigScope::User).unwrap(),
            [user_file(tmp.path())],
            "no ~/.jjconfig.toml, no conf.d: only the platform file (the new-file default)"
        );
        assert!(!tmp.path().join("cfg").exists(), "the user path creates nothing");

        let repo = path_with(&env, Some(&root), ConfigScope::Repo).unwrap();
        let [repo_file] = repo.as_slice() else {
            panic!("one repo path")
        };
        assert!(repo_file.starts_with(tmp.path().join("cfg").join("jj").join("repos")));
        assert!(repo_file.parent().unwrap().join("metadata.binpb").exists());
        assert!(!repo_file.exists(), "the config.toml itself is not created");
        assert_eq!(path_with(&env, Some(&root), ConfigScope::Repo).unwrap(), repo, "stable");

        let ws = path_with(&env, Some(&root), ConfigScope::Workspace).unwrap();
        assert!(ws[0].starts_with(tmp.path().join("cfg").join("jj").join("workspaces")));
        assert!(root.join(".jj").join("workspace-config-id").exists());

        let no_dir = ConfigEnv {
            config_dir: None,
            ..env_in(tmp.path())
        };
        for (env, root, scope, reason) in [
            (
                env_without_user(tmp.path()),
                None,
                ConfigScope::User,
                "No user config path found",
            ),
            (env_in(tmp.path()), None, ConfigScope::Repo, "No repo config path found"),
            (
                no_dir,
                Some(root.as_path()),
                ConfigScope::Workspace,
                "No workspace config path found",
            ),
        ] {
            assert!(matches!(
                path_with(&env, root, scope),
                Err(ConfigCmdError::NoConfigPath { reason: r }) if r == reason
            ));
        }
    }

    // ── set / unset ─────────────────────────────────────────────────────────

    #[test]
    fn set_creates_the_default_user_file_with_a_private_parent() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let out = set_with(
            &env,
            None,
            &ConfigTarget::Scope(ConfigScope::User),
            ("user.name", "Ralph Bergmann"),
        );
        assert!(out.precondition.is_none());
        let file = user_file(tmp.path());
        assert_eq!(out.result.unwrap().path, file);
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            format!("{HEADER}[user]\nname = \"Ralph Bergmann\"\n")
        );
        let mode = fs::metadata(file.parent().unwrap()).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
    }

    /// jj 0.45: the user scope writes its FIRST file instead of prompting; `--file` writes any
    /// recognized location — a loaded file or a new `*.toml` in `conf.d` — and nothing else.
    #[test]
    fn set_with_two_user_files_writes_the_first_or_the_named_file() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let main = user_file(tmp.path());
        let conf_d = tmp.path().join("cfg").join("jj").join("conf.d");
        let extra = conf_d.join("x.toml");
        write(&main, "# mine\n");
        write(&extra, "");
        write(&extra.with_extension("txt"), "");
        let file = |path: &Path| ConfigTarget::File(path.to_owned());

        let out = set_with(&env, None, &ConfigTarget::Scope(ConfigScope::User), ("a.b", "1"));
        assert_eq!(out.result.unwrap().path, main, "the first loaded user file");
        assert_eq!(fs::read_to_string(&main).unwrap(), "[a]\nb = 1\n# mine\n");
        assert_eq!(fs::read_to_string(&extra).unwrap(), "", "only the first file");

        for stray in [tmp.path().join("elsewhere.toml"), extra.with_extension("txt")] {
            let out = set_with(&env, None, &file(&stray), ("a.b", "2"));
            assert!(
                matches!(out.result, Err(ConfigCmdError::UnrecognizedFile { ref path }) if *path == stray),
                "{stray:?}"
            );
        }
        assert!(!tmp.path().join("elsewhere.toml").exists(), "nothing written");

        let out = set_with(&env, None, &file(&extra), ("a.b", "2"));
        assert_eq!(out.result.unwrap().path, extra);
        assert_eq!(fs::read_to_string(&extra).unwrap(), "[a]\nb = 2\n");

        let new = conf_d.join("new.toml");
        let out = set_with(&env, None, &file(&new), ("a.b", "3"));
        assert_eq!(out.result.unwrap().path, new, "a new *.toml inside a user config dir");
        assert_eq!(fs::read_to_string(&new).unwrap(), format!("{HEADER}[a]\nb = 3\n"));

        let err = ConfigCmdError::UnrecognizedFile { path: "/x.toml".into() };
        assert_eq!(
            err.to_string(),
            "Configuration file '/x.toml' is not a valid jj configuration file location"
        );
    }

    #[test]
    fn set_parses_values_and_refuses_what_the_cli_refuses() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let file = user_file(tmp.path());
        write(&file, "[revset-aliases]\n'x()' = '@'\n");
        let set = |name: &str, value: &str| {
            set_with(&env, None, &ConfigTarget::Scope(ConfigScope::User), (name, value)).result
        };
        set("snapshot.auto-track", "'glob:**/*.rs'").unwrap();
        assert_eq!(get_with(&env, None, "snapshot.auto-track").unwrap(), "glob:**/*.rs");
        assert!(matches!(set("x", "'unterminated"), Err(ConfigCmdError::Parse { .. })));
        assert!(matches!(set("a..b", "1"), Err(ConfigCmdError::Parse { .. })));
        let before = fs::read_to_string(&file).unwrap();
        assert!(matches!(
            set("revset-aliases", "x"),
            Err(ConfigCmdError::WouldOverwrite { reason }) if reason.starts_with("Failed to set revset-aliases")
        ));
        assert!(matches!(
            set("snapshot.auto-track.y", "1"),
            Err(ConfigCmdError::WouldOverwrite { .. })
        ));
        assert_eq!(fs::read_to_string(&file).unwrap(), before, "nothing written");
    }

    #[test]
    fn set_without_any_path_refuses() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_without_user(tmp.path());
        for scope in [ConfigScope::User, ConfigScope::Repo, ConfigScope::Workspace] {
            let out = set_with(&env, None, &ConfigTarget::Scope(scope), ("a", "1"));
            assert!(matches!(
                out.result,
                Err(ConfigCmdError::NoConfigPath { ref reason }) if reason.ends_with("config path found to edit")
            ));
        }
    }

    /// `user.email` / `user.name` compare `@`'s author after a snapshot; any other key runs
    /// no snapshot.
    #[test]
    fn setting_the_identity_reports_a_differing_working_copy_author() {
        let (tmp, root) = workspace();
        let env = env_in(tmp.path());
        let set = |name: &str, value: &str| {
            set_with(
                &env,
                Some(&root),
                &ConfigTarget::Scope(ConfigScope::Repo),
                (name, value),
            )
        };

        let out = set("user.email", "other@example.com");
        assert!(out.precondition.is_some(), "the snapshot ran");
        let author = out.result.unwrap().working_copy_author.expect("differs");
        assert_eq!(
            (author.name.as_str(), author.email.as_str()),
            ("Zanshin", "zanshin@localhost")
        );

        let out = set("user.name", "Zanshin");
        assert!(out.result.unwrap().working_copy_author.is_none(), "same name: no fact");

        let out = set("revsets.log", "@");
        assert!(out.precondition.is_none(), "no snapshot for other keys");
        assert!(out.result.unwrap().working_copy_author.is_none());

        let out = set_with(&env, None, &ConfigTarget::Scope(ConfigScope::User), ("user.name", "x"));
        assert!(out.precondition.is_none(), "no workspace, no snapshot");

        let out = set("user.name", "42");
        assert!(
            out.result.unwrap().working_copy_author.is_some(),
            "a non-string always differs"
        );
        // …and, as in the CLI, a wrong-typed start-up key then fails every stack verb.
        assert!(matches!(
            get_with(&env, Some(&root), "user.name"),
            Err(ConfigCmdError::Config { reason }) if reason.contains("user.name")
        ));
    }

    #[test]
    fn unset_removes_and_refuses_like_the_cli() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let file = user_file(tmp.path());
        write(
            &file,
            "# keep\n[user]\nname = 'a' # me\nemail = 'e'\n[revset-aliases]\n'x()' = '@'\n",
        );
        let unset = |name: &str| unset_with(&env, None, &ConfigTarget::Scope(ConfigScope::User), name);
        assert_eq!(unset("user.name").unwrap(), file);
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "# keep\n[user]\nemail = 'e'\n[revset-aliases]\n'x()' = '@'\n"
        );
        assert!(matches!(
            unset("nope"),
            Err(ConfigCmdError::NotFound { reason }) if reason == "\"nope\" doesn't exist"
        ));
        assert!(matches!(
            unset("revset-aliases"),
            Err(ConfigCmdError::WouldDeleteTable { reason }) if reason.starts_with("Failed to unset")
        ));
        assert!(matches!(unset(""), Err(ConfigCmdError::Parse { .. })));
    }

    // ── The editor halves ───────────────────────────────────────────────────

    #[test]
    fn file_read_creates_an_absent_file_with_the_schema_header() {
        let (tmp, root) = workspace();
        let env = env_in(tmp.path());
        let read = file_read_with(&env, Some(&root), &ConfigTarget::Scope(ConfigScope::Workspace)).unwrap();
        assert_eq!(read.text, HEADER);
        assert_eq!(fs::read_to_string(&read.path).unwrap(), HEADER);
        assert!(read
            .path
            .starts_with(tmp.path().join("cfg").join("jj").join("workspaces")));
        let again = file_read_with(&env, Some(&root), &ConfigTarget::Scope(ConfigScope::Workspace)).unwrap();
        assert_eq!(again, read);

        write(&user_file(tmp.path()), "");
        fs::write(user_file(tmp.path()), [0xff, 0xfe]).unwrap();
        assert!(matches!(
            file_read_with(&env, None, &ConfigTarget::Scope(ConfigScope::User)),
            Err(ConfigCmdError::Config { .. })
        ));
    }

    #[test]
    fn file_write_validates_before_writing_and_only_writes_known_files() {
        let (tmp, root) = workspace();
        let env = env_in(tmp.path());
        let repo = file_read_with(&env, Some(&root), &ConfigTarget::Scope(ConfigScope::Repo)).unwrap();
        let err = file_write_with(&env, Some(&root), &repo.path, "[user\nname = ").unwrap_err();
        let ConfigCmdError::Parse { message, span } = err else {
            panic!("a parse refusal")
        };
        assert!(!message.is_empty() && span.is_some(), "{message} {span:?}");
        assert_eq!(fs::read_to_string(&repo.path).unwrap(), HEADER, "untouched");

        file_write_with(&env, Some(&root), &repo.path, "user.name = 'R'\n").unwrap();
        let repo_only = ConfigListQuery {
            scope: Some(ConfigScope::Repo),
            ..query()
        };
        let rows = list_with(&env, Some(&root), &repo_only).unwrap().value;
        assert_eq!(names(&rows), [("user.name", "'R'", ConfigValueSource::Repo, false)]);

        let default_user = user_file(tmp.path());
        file_write_with(&env, None, &default_user, "a = 1\n").expect("the user default is writable");
        assert_eq!(fs::read_to_string(&default_user).unwrap(), "a = 1\n");
        let stray = tmp.path().join("stray.toml");
        assert!(matches!(
            file_write_with(&env, Some(&root), &stray, ""),
            Err(ConfigCmdError::UnrecognizedFile { path }) if path == stray
        ));
        assert!(!stray.exists());
        // A relative path is taken against the workspace root; without one there is no base.
        let relative = Path::new("stray.toml");
        let joined = fs::canonicalize(&root).unwrap().join(relative);
        assert!(matches!(
            file_write_with(&env, Some(&root), relative, ""),
            Err(ConfigCmdError::UnrecognizedFile { path }) if path == joined
        ));
        assert!(matches!(
            file_write_with(&env, None, relative, ""),
            Err(ConfigCmdError::UnrecognizedFile { path }) if path == relative
        ));
    }

    /// `--file` naming the workspace config file `config path` reported (its id and secure dir
    /// exist, the file does not yet): the write half accepts it WITHOUT creating anything, and
    /// `set` creates it — after create-forcing the repo file first, as the CLI checks in that
    /// order.
    #[test]
    fn file_targets_reach_a_not_yet_written_secure_file() {
        let (tmp, root) = workspace();
        let env = env_in(tmp.path());
        let ws_file = path_with(&env, Some(&root), ConfigScope::Workspace).unwrap().remove(0);
        assert!(!ws_file.exists());

        file_write_with(&env, Some(&root), &ws_file, "a = 1\n").expect("a recognized location");
        assert_eq!(fs::read_to_string(&ws_file).unwrap(), "a = 1\n");
        fs::remove_file(&ws_file).unwrap();

        let target = ConfigTarget::File(ws_file.clone());
        let out = set_with(&env, Some(&root), &target, ("b", "2"));
        assert_eq!(out.result.unwrap().path, ws_file);
        assert_eq!(fs::read_to_string(&ws_file).unwrap(), format!("{HEADER}b = 2\n"));
        assert!(
            root.join(".jj").join("repo").join("config-id").exists(),
            "the repo file was forced too"
        );
    }

    /// A system config file is a loaded layer, so `--file` may target it.
    #[test]
    fn a_file_target_reaches_a_system_config_file() {
        let tmp = tempfile::tempdir().unwrap();
        let system = tmp.path().join("etc").join("jj").join("config.toml");
        write(&system, "");
        let env = ConfigEnv {
            system_config_dir: Some(tmp.path().join("etc")),
            ..env_in(tmp.path())
        };
        let out = set_with(&env, None, &ConfigTarget::File(system.clone()), ("a", "1"));
        assert_eq!(out.result.unwrap().path, system);
        assert_eq!(fs::read_to_string(&system).unwrap(), "a = 1\n");
    }

    // ── gc ──────────────────────────────────────────────────────────────────

    /// Creates a secure repo config for a (fake) repo dir under `base`, returns the config dir.
    fn repo_config_for(env: &ConfigEnv, base: &Path) -> PathBuf {
        let dirs = WorkspaceDirs {
            repo_path: base.join(".jj").join("repo"),
            workspace_root: base.to_owned(),
        };
        fs::create_dir_all(&dirs.repo_path).unwrap();
        let [repo, _] = config::secure_layers(env, dirs.paths());
        repo.create_path(None).unwrap().unwrap().parent().unwrap().to_owned()
    }

    #[test]
    fn gc_lists_and_deletes_only_missing_repo_configs() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_without_user(tmp.path());
        assert!(gc_list_with(&env).unwrap().is_empty(), "no root yet");

        let kept = repo_config_for(&env, &tmp.path().join("kept"));
        let gone = repo_config_for(&env, &tmp.path().join("gone"));
        let busy = repo_config_for(&env, &tmp.path().join("busy"));
        fs::remove_dir_all(tmp.path().join("gone")).unwrap();
        fs::remove_dir_all(tmp.path().join("busy")).unwrap();
        fs::write(busy.join("user-note.txt"), "keep me").unwrap();
        let repos = kept.parent().unwrap().to_owned();
        fs::write(repos.join("stray-file"), "").unwrap();
        fs::create_dir(repos.join("no-metadata")).unwrap();

        let missing = gc_list_with(&env).unwrap();
        let mut expected = vec![gone.clone(), busy.clone()];
        expected.sort();
        let dirs: Vec<PathBuf> = missing.iter().map(|m| m.config_dir.clone()).collect();
        assert_eq!(dirs, expected);
        assert!(missing.iter().all(|m| m.repo_path.ends_with(".jj/repo")));

        let crate::Warned {
            value: result,
            warnings,
        } = gc_delete_with(&env, &[kept.clone(), gone.clone(), busy.clone()]).unwrap();
        assert_eq!(result.deleted, std::slice::from_ref(&gone));
        let failed: Vec<&Path> = result.failed.iter().map(|f| f.config_dir.as_path()).collect();
        assert_eq!(failed, [busy.as_path(), kept.as_path()]);
        assert_eq!(result.failed[1].reason, "not a missing repo config directory");
        assert!(!gone.exists() && busy.exists() && kept.exists());
        // Story 9.32: only the REAL delete failure warns (the CLI's "Failed to delete …"); the
        // not-missing request has no CLI counterpart and stays data.
        assert_eq!(warnings.len(), 1, "{warnings:?}");
        assert_eq!(warnings[0].kind, crate::WarningKind::ConfigGcDeleteFailed);
        assert_eq!(
            warnings[0].message,
            format!("Failed to delete {}: {}", busy.display(), result.failed[0].reason)
        );
    }

    #[test]
    fn gc_refuses_without_a_config_dir_or_a_readable_root() {
        let tmp = tempfile::tempdir().unwrap();
        let no_dir = ConfigEnv {
            config_dir: None,
            ..env_without_user(tmp.path())
        };
        assert!(matches!(
            gc_list_with(&no_dir),
            Err(ConfigCmdError::NoConfigPath { reason }) if reason == "No config directory found"
        ));
        let env = env_without_user(tmp.path());
        write(&tmp.path().join("cfg").join("jj").join("repos"), "a file, not a dir");
        assert!(matches!(
            gc_list_with(&env),
            Err(ConfigCmdError::Config { reason }) if reason.starts_with("Failed to read")
        ));
    }

    #[test]
    fn gc_refuses_a_root_it_cannot_check() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::tempdir().unwrap();
        let env = env_without_user(tmp.path());
        let jj = tmp.path().join("cfg").join("jj");
        fs::create_dir_all(&jj).unwrap();
        fs::set_permissions(&jj, fs::Permissions::from_mode(0o000)).unwrap();
        let result = gc_list_with(&env);
        fs::set_permissions(&jj, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(matches!(
            result,
            Err(ConfigCmdError::Config { reason }) if reason.starts_with("Failed to check")
        ));
    }

    /// The config verbs resolve with their CLI command name, so a `--when.commands = ["config"]`
    /// scope applies and a `["log"]` one does not.
    #[test]
    fn config_verbs_resolve_when_commands_with_their_command_name() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        write(
            &user_file(tmp.path()),
            "[[--scope]]\n--when.commands = [\"config\"]\nfoo.bar = 1\n\n\
             [[--scope]]\n--when.commands = [\"log\"]\nfoo.baz = 2\n",
        );
        assert_eq!(get_with(&env, None, "foo.bar").unwrap(), "1");
        let rows = list_with(&env, None, &query()).unwrap().value;
        assert!(rows.iter().any(|r| r.name == "foo.bar"));
        assert!(rows.iter().all(|r| r.name != "foo.baz"));
    }

    /// (a) A user config path is a recognized location whether or not other user files exist —
    /// the new-file default stays writable next to `conf.d/a.toml` (jj 0.45 `--file`).
    #[test]
    fn file_write_accepts_a_user_config_path_next_to_other_user_files() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let default_user = user_file(tmp.path());
        file_write_with(&env, None, &default_user, "a = 1\n").expect("its missing parent is created");
        assert_eq!(fs::read_to_string(&default_user).unwrap(), "a = 1\n");

        let other = tempfile::tempdir().unwrap();
        let env = env_in(other.path());
        write(&other.path().join("cfg").join("jj").join("conf.d").join("a.toml"), "");
        file_write_with(&env, None, &user_file(other.path()), "b = 2\n").expect("still a user config path");
        assert_eq!(fs::read_to_string(user_file(other.path())).unwrap(), "b = 2\n");
    }

    /// (b) Without an id file the repo/workspace layer offers nothing — never the legacy file;
    /// (c) a malformed id file is a config error, not an unrecognized-file refusal.
    #[test]
    fn file_write_never_offers_the_legacy_file_and_names_a_bad_id() {
        let (tmp, root) = workspace();
        let env = env_in(tmp.path());
        let legacy = root.join(".jj").join("repo").join("config.toml");
        assert!(matches!(
            file_write_with(&env, Some(&root), &legacy, ""),
            Err(ConfigCmdError::UnrecognizedFile { .. })
        ));
        assert!(!legacy.exists());

        fs::write(root.join(".jj").join("repo").join("config-id"), "not-hex").unwrap();
        assert!(matches!(
            file_write_with(&env, Some(&root), &legacy, ""),
            Err(ConfigCmdError::Config { reason }) if reason.contains("config-id")
        ));
    }
}
