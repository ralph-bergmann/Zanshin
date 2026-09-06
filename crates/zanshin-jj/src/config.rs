// SPDX-License-Identifier: MIT

//! The repo's effective jj config — the one layer stack every revset parse and the
//! `jj log` defaults are read from (Story 4.9).
//!
//! [`load`] rebuilds, per operation, the `StackedConfig` the jj CLI would have at v0.42.0
//! for this workspace: Zanshin's builtin default layer ([`BUILTIN_CONFIG_TOML`]), then the
//! user config (`JJ_CONFIG` or platform discovery), then the repo layer, then the workspace
//! layer, finally flattened through `jj_lib::config::resolve`. Nothing is cached — config
//! files change externally and the op-heads watcher does not cover them, so ADR-0002's
//! re-resolve-per-operation rule extends to config.
//!
//! # Reading never writes; exactly two verbs write
//!
//! Every READ path here is side-effect-free: no directory is created, no file is written,
//! no `config-id` is generated, nothing is migrated. That stance is unchanged.
//!
//! What changed (Epic 9 follow-up J) is that this module now also holds the crate's only
//! config WRITERS, [`remove_remote_from_repo_config`] and [`rename_remote_in_repo_config`],
//! called by [`crate::Repo::git_remote_remove`] / [`crate::Repo::git_remote_rename`] — the
//! two verbs whose CLI counterparts rewrite the repo-level file
//! (`cli/src/commands/git/mod.rs:195-262` @ v0.44.0). They make exactly the CLI's two edits
//! and NEVER create a file: the path is resolved by the same [`secure_config_path`] the read
//! side uses and filtered by existence ([`existing_repo_config_path`]), so read and write
//! address the same file by construction. No general config-write API exists, and none of
//! the other verbs — `git remote add`/`set-url` included — writes config at all.
//!
//! # WHY: by hand instead of `jj_lib::secure_config::SecureConfig`
//!
//! The CLI reaches the repo/workspace layer through `SecureConfig`, whose
//! `maybe_load_config` WRITES: it creates directories, writes `metadata.binpb`, can
//! generate a fresh `config-id`, copies configs when it detects a moved/copied repo, and on
//! Unix replaces the legacy file with a symlink — and it needs a `&mut ChaCha20Rng`. A GUI
//! backend must not rewrite the user's repo layout while drawing a graph, so the
//! `config-id` → path indirection is resolved here by reading the id and joining the path.
//! For a repo the CLI has already seen, that yields identical config CONTENT; what is given
//! up is the CLI's migration and its terminal warning, and Zanshin has no terminal (it
//! replaces the CLI's UX — NFR-R-2).
//!
//! One documented exception: `handle_metadata_path` (`secure_config.rs:187-252`) re-points
//! or COPIES the config when it detects that the repo was moved or copied. Zanshin never
//! performs that fix-up, so between a repo copy and the next `jj` invocation that repairs
//! it, the CLI and Zanshin can read different files. Rewriting the user's config store
//! from a read path is the worse trade — a GUI drawing a graph must not mutate layout.
//!
//! # Deliberately absent layers
//!
//! No `--config`/`--config-file` command-line layer (Zanshin has no CLI args) and no
//! `ConfigSource::EnvBase` / `EnvOverrides` layers: at the pin those can only set
//! `operation.*`, `user.*`, `debug.*`, `ui.color`, `ui.editor` and `ui.pager`
//! (`cli/src/config.rs` @ v0.42.0), never `[revset-aliases]`, `revsets.*` or
//! `ui.log-synthetic-elided-nodes`, so their absence is unobservable here. `migrate` is
//! skipped too — its rule list is empty at the pin.
//!
//! Consequence worth recording: `resolve` runs with `command: None` and `hostname: ""`
//! (both states the CLI itself produces), so `--when.commands` and `--when.hostnames`
//! scopes never match in Zanshin.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

use jj_lib::config::{
    resolve, ConfigFile, ConfigGetError, ConfigGetResultExt as _, ConfigLayer, ConfigLoadError,
    ConfigResolutionContext, ConfigSource, StackedConfig,
};
use jj_lib::ref_name::RemoteRefSymbolBuf;
use jj_lib::workspace::Workspace;

use crate::Repo;

/// Zanshin's builtin default config layer — the lowest layer of the stack, and the one a
/// user's `[revset-aliases]` or `[revsets]` entry overrides.
///
/// The `[revsets] log` / `log-graph-prioritize` values and the whole `[revset-aliases]`
/// table are verbatim from `cli/src/config/revsets.toml` at v0.44.0;
/// `ui.log-synthetic-elided-nodes` is verbatim from `cli/src/config/misc.toml:44` and
/// `ui.conflict-marker-style` from `cli/src/config/misc.toml:45` (Story 9.4 — the style
/// `file show` materializes a conflicted file with).
///
/// # WHY: a config layer, not a Rust table
///
/// The CLI has no special path for its builtins — they are simply the lowest config layer,
/// and its alias loader walks every layer lowest-first (`cli/src/config.rs:930-981`), so an
/// override works by (name, arity): a user's `trunk()` REPLACES the builtin `trunk()`, while
/// a user's `trunk(x)` ADDS an overload and leaves `trunk()` alone. Reproducing that needs
/// one insertion path over layered config; a hardcoded array plus a config pass would get
/// the arity semantics wrong.
///
/// The CLI's other `[revsets]` keys (`arrange`, `fix`, `sign`, `op-diff-changes-in`,
/// `simplify-parents`, `bookmark-advance-*`) are deliberately NOT copied — no Zanshin verb
/// consumes them, and an unread default is a lie about what we honour.
const BUILTIN_CONFIG_TOML: &str = r#"
[revsets]
log = "present(@) | ancestors(immutable_heads().., 2) | trunk()"
log-graph-prioritize = "present(@)"

[ui]
log-synthetic-elided-nodes = true
conflict-marker-style = "diff"

[revset-aliases]
# trunk() can be overridden as '<bookmark>@<remote>'.
'trunk()' = '''
latest(
  remote_bookmarks(exact:"main", exact:"origin") |
  remote_bookmarks(exact:"master", exact:"origin") |
  remote_bookmarks(exact:"trunk", exact:"origin") |
  remote_bookmarks(exact:"main", exact:"upstream") |
  remote_bookmarks(exact:"master", exact:"upstream") |
  remote_bookmarks(exact:"trunk", exact:"upstream") |
  root()
)
'''

# If immutable_heads() failed to evaluate, many jj commands wouldn't work. Use
# present(expr) if symbols in expr might not always exist.
'builtin_immutable_heads()' = 'trunk() | tags() | untracked_remote_bookmarks()'
'immutable_heads()' = 'builtin_immutable_heads()'
'immutable()' = '::(immutable_heads() | root())'
'mutable()' = '~immutable()'

'visible()' = '::visible_heads()'
'hidden()' = '~visible()'
"#;

/// Length of a `config-id` in ASCII hex characters (`jj_lib::secure_config`'s
/// `CONFIG_ID_BYTES * 2` at v0.42.0).
const CONFIG_ID_HEX_LEN: usize = 20;

/// The `trunk()` alias's config name path, verbatim from
/// `cli/src/commands/git/mod.rs:133` @ v0.44.0.
///
/// A `[&str; N]` array, never the dotted string `"revset-aliases.trunk()"`: the alias name
/// contains `(` and `)`, so the dotted spelling would be re-split in the wrong places.
const TRUNK_CONFIG_NAME: [&str; 2] = ["revset-aliases", "trunk()"];

/// Errors from reading the repo's effective jj config.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// A config file could not be read or parsed, a `config-id` is malformed, or a config
    /// value has the wrong type. The offending file path or config key is in `reason`.
    #[error("config error: {reason}")]
    Load {
        /// Human-readable failure, naming the file or the config key.
        reason: String,
    },
}

/// The effective `jj log` defaults of a repo — what the user's own CLI would apply.
///
/// Offered as pre-fills for [`Repo::walk_graph`]'s pass-through parameters (FR-JJ-17);
/// nothing in this crate applies them silently.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogDefaults {
    /// `revsets.log` — the revset `jj log` shows without `-r`.
    pub log: String,
    /// `revsets.log-graph-prioritize` — the branch emitted first.
    pub log_graph_prioritize: String,
    /// `revsets.short-prefixes` — the shortest-prefix disambiguation set. Falls back to
    /// [`LogDefaults::log`] when the key is ABSENT; an explicit empty string means
    /// "disambiguation disabled" and is returned verbatim.
    pub short_prefixes: String,
    /// `ui.log-synthetic-elided-nodes` — render elided ancestry as synthetic rows.
    pub synthetic_elided: bool,
}

/// Renders an error and its `source()` chain as `"outer: inner: …"`.
///
/// jj-lib's config errors keep the interesting detail (the TOML parse position, the io
/// reason, the serde type mismatch) in the source chain, so the top-level Display alone
/// would be useless in an `error.context`.
fn describe(err: &(dyn std::error::Error + 'static)) -> String {
    let mut out = err.to_string();
    let mut source = err.source();
    while let Some(e) = source {
        out.push_str(": ");
        out.push_str(&e.to_string());
        source = e.source();
    }
    out
}

/// A load/parse failure, prefixed with the file it came from.
fn file_error(path: &Path, err: &ConfigLoadError) -> ConfigError {
    ConfigError::Load {
        reason: format!("{}: {}", path.display(), describe(err)),
    }
}

/// A lookup failure. `ConfigGetError`'s Display already names the config key.
fn value_error(err: &ConfigGetError) -> ConfigError {
    ConfigError::Load { reason: describe(err) }
}

/// Process-level inputs of the layer stack, snapshotted once per [`load`].
///
/// Split out so [`load_with`] and the path-selection helpers are testable without
/// touching the process environment.
struct ConfigEnv {
    /// The platform config dir (`<config_dir>`), e.g. `~/.config`.
    config_dir: Option<PathBuf>,
    /// Canonicalized `$HOME`.
    home_dir: Option<PathBuf>,
    /// `JJ_CONFIG` — `Some` even when empty, which is how the CLI disables discovery.
    jj_config: Option<OsString>,
    /// Environment snapshot for `--when.env` scope resolution.
    environment: HashMap<String, String>,
}

impl ConfigEnv {
    /// Snapshots the environment the way `ConfigEnv::from_environment`
    /// (`cli/src/config.rs:351-396`) does.
    fn from_env() -> Self {
        let home_dir = std::env::var_os("HOME").map(PathBuf::from).map(|d| {
            // WHY: the CLI canonicalizes $HOME (dunce::canonicalize, == std::fs::canonicalize
            // on Unix) because it may be a symlink and `--when.repositories` compares paths.
            std::fs::canonicalize(&d).unwrap_or(d)
        });
        let xdg = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from);
        Self {
            config_dir: platform_config_dir(xdg.as_deref(), home_dir.as_deref()),
            jj_config: std::env::var_os("JJ_CONFIG"),
            // WHY: vars_os + filter_map, not vars() — vars() PANICS on a non-Unicode
            // variable, and nothing reachable from FFI may panic.
            environment: std::env::vars_os()
                .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
                .collect(),
            home_dir,
        }
    }

    /// `<config_dir>/jj` — the root the secure per-repo/per-workspace config dirs hang off.
    fn root_config_dir(&self) -> Option<PathBuf> {
        self.config_dir.as_ref().map(|d| d.join("jj"))
    }
}

/// The platform config dir on this macOS-only project.
///
/// # WHY: five lines instead of a dependency
///
/// The CLI uses `etcetera::choose_base_strategy()`, which maps macOS to the XDG strategy:
/// `$XDG_CONFIG_HOME` when it is an absolute path, otherwise `$HOME/.config`. Zanshin is
/// macOS-only (Windows/Linux are explicit non-goals), so the whole strategy collapses to
/// this rule and a new crate would buy nothing.
fn platform_config_dir(xdg_config_home: Option<&Path>, home_dir: Option<&Path>) -> Option<PathBuf> {
    match xdg_config_home {
        Some(dir) if dir.is_absolute() => Some(dir.to_owned()),
        _ => home_dir.map(|home| home.join(".config")),
    }
}

/// Candidate user-config paths in ascending precedence, mirroring
/// `UnresolvedConfigEnv::resolve` (`cli/src/config.rs:288-331`).
///
/// `jj_config` being `Some` — INCLUDING the empty string — replaces discovery entirely;
/// that is the CLI's documented way to disable the user's config, and it is what the test
/// suite pins. Non-existent candidates are dropped by [`add_user_layers`], exactly as the
/// CLI's `existing_user_config_paths` filter does.
fn user_config_paths(jj_config: Option<&OsStr>, config_dir: Option<&Path>, home_dir: Option<&Path>) -> Vec<PathBuf> {
    if let Some(paths) = jj_config {
        return std::env::split_paths(paths)
            .filter(|path| !path.as_os_str().is_empty())
            .collect();
    }
    let mut paths = Vec::new();
    if let Some(home) = home_dir {
        paths.push(home.join(".jjconfig.toml"));
    }
    if let Some(dir) = config_dir {
        paths.push(dir.join("jj").join("config.toml"));
        paths.push(dir.join("jj").join("conf.d"));
    }
    paths
}

/// True iff `id` is exactly [`CONFIG_ID_HEX_LEN`] ASCII hex characters — jj-lib's own
/// `config-id` validity rule (`secure_config.rs:340-344`, which does NOT trim whitespace,
/// so a trailing newline makes the id invalid).
fn is_valid_config_id(id: &str) -> bool {
    id.len() == CONFIG_ID_HEX_LEN && id.chars().all(|c| c.is_ascii_hexdigit())
}

/// Resolves the path of a secure (repo or workspace) config file WITHOUT writing anything.
///
/// `dir` is the directory holding the id file (`.jj/repo` for a repo, `.jj` for a
/// workspace), `root_config_dir` the `<config_dir>/jj/{repos,workspaces}` directory. Read
/// order mirrors `SecureConfig::maybe_load_config` minus its side effects: a valid
/// `config-id` selects `<root_config_dir>/<id>/config.toml`; an absent id file falls back
/// to the legacy file in `dir`. A `<config_dir>` that cannot be determined skips the layer
/// entirely, as `ConfigEnv::load_secure_config` does.
///
/// The returned path may not exist; the caller filters.
fn secure_config_path(
    dir: &Path,
    id_file_name: &str,
    legacy_file_name: &str,
    root_config_dir: Option<&Path>,
) -> Result<Option<PathBuf>, ConfigError> {
    let Some(root) = root_config_dir else {
        return Ok(None);
    };
    let id_path = dir.join(id_file_name);
    match std::fs::read_to_string(&id_path) {
        Ok(id) if is_valid_config_id(&id) => Ok(Some(root.join(id).join("config.toml"))),
        Ok(_) => Err(ConfigError::Load {
            reason: format!(
                "{}: invalid config ID (expected {CONFIG_ID_HEX_LEN} ASCII hex characters)",
                id_path.display()
            ),
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Some(dir.join(legacy_file_name))),
        Err(e) => Err(ConfigError::Load {
            reason: format!("{}: {e}", id_path.display()),
        }),
    }
}

/// Adds the existing user-config layers, directories expanded like the CLI's
/// `reload_user_config` (`cli/src/config.rs:471-481`).
fn add_user_layers(config: &mut StackedConfig, env: &ConfigEnv) -> Result<(), ConfigError> {
    let paths = user_config_paths(
        env.jj_config.as_deref(),
        env.config_dir.as_deref(),
        env.home_dir.as_deref(),
    );
    for path in paths.iter().filter(|p| p.exists()) {
        if path.is_dir() {
            config.load_dir(ConfigSource::User, path)
        } else {
            config.load_file(ConfigSource::User, path)
        }
        .map_err(|e| file_error(path, &e))?;
    }
    Ok(())
}

/// Adds one secure-config layer (repo or workspace) if its file exists.
fn add_secure_layer(
    config: &mut StackedConfig,
    source: ConfigSource,
    dir: &Path,
    id_file_name: &str,
    legacy_file_name: &str,
    root_config_dir: Option<&Path>,
) -> Result<(), ConfigError> {
    let Some(path) = secure_config_path(dir, id_file_name, legacy_file_name, root_config_dir)? else {
        return Ok(());
    };
    if path.exists() {
        config.load_file(source, &path).map_err(|e| file_error(&path, &e))?;
    }
    Ok(())
}

/// Builds the resolved layer stack for one workspace from an explicit environment.
fn load_with(env: &ConfigEnv, repo_path: &Path, workspace_root: &Path) -> Result<StackedConfig, ConfigError> {
    let mut config = StackedConfig::with_defaults();
    let builtin = ConfigLayer::parse(ConfigSource::Default, BUILTIN_CONFIG_TOML)
        .map_err(|e| ConfigError::Load { reason: describe(&e) })?;
    config.add_layer(builtin);

    add_user_layers(&mut config, env)?;

    let root = env.root_config_dir();
    add_secure_layer(
        &mut config,
        ConfigSource::Repo,
        repo_path,
        "config-id",
        "config.toml",
        root.as_ref().map(|r| r.join("repos")).as_deref(),
    )?;
    add_secure_layer(
        &mut config,
        ConfigSource::Workspace,
        &workspace_root.join(".jj"),
        "workspace-config-id",
        "workspace-config.toml",
        root.as_ref().map(|r| r.join("workspaces")).as_deref(),
    )?;

    // Flatten `--when` / `[[--scope]]` blocks. Skipping this would leave scoped tables
    // unflattened (their values silently missing) and keep layers the CLI drops.
    let context = ConfigResolutionContext {
        home_dir: env.home_dir.as_deref(),
        repo_path: Some(repo_path),
        workspace_path: Some(workspace_root),
        command: None,
        hostname: "",
        environment: &env.environment,
    };
    resolve(&config, &context).map_err(|e| value_error(&e))
}

/// Loads `repo`'s effective jj config stack. Re-read on every call — never cached.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a config file is unreadable or not valid TOML, a `config-id`
///   is malformed, or a `--when`/`[[--scope]]` condition has the wrong type.
pub(crate) fn load(repo: &Repo) -> Result<StackedConfig, ConfigError> {
    load_for_workspace(repo.workspace())
}

/// Loads `workspace`'s effective jj config stack, for a caller that has no [`Repo`] yet.
///
/// [`load`] is the usual entry point; this exists because `Repo::clone_into` must read the
/// effective config of the workspace it just initialised, several steps BEFORE that workspace
/// is wrapped in a [`Repo`].
///
/// # Errors
///
/// - [`ConfigError::Load`] — a config file is unreadable or not valid TOML, a `config-id`
///   is malformed, or a `--when`/`[[--scope]]` condition has the wrong type.
pub(crate) fn load_for_workspace(workspace: &Workspace) -> Result<StackedConfig, ConfigError> {
    // `repo_path()` is jj-lib's already-resolved `.jj/repo` — it follows the FILE
    // indirection a secondary workspace uses.
    load_with(
        &ConfigEnv::from_env(),
        workspace.repo_path(),
        workspace.workspace_root(),
    )
}

/// Reads the four effective `jj log` defaults out of a loaded stack.
///
/// Mirrors `cli/src/commands/log.rs:148/197` (hard type errors) and
/// `cli/src/cli_util.rs:987-1009` (the `revsets.short-prefixes` → `revsets.log` fallback,
/// which triggers on ABSENCE only — an explicit `""` means disabled and is returned as-is).
///
/// # Errors
///
/// - [`ConfigError::Load`] — a value has the wrong type, or is missing from every layer
///   (impossible while the builtin layer is present).
pub(crate) fn log_defaults(config: &StackedConfig) -> Result<LogDefaults, ConfigError> {
    let log: String = config.get("revsets.log").map_err(|e| value_error(&e))?;
    let log_graph_prioritize: String = config
        .get("revsets.log-graph-prioritize")
        .map_err(|e| value_error(&e))?;
    let short_prefixes = config
        .get::<String>("revsets.short-prefixes")
        .optional()
        .map_err(|e| value_error(&e))?
        .unwrap_or_else(|| log.clone());
    let synthetic_elided: bool = config
        .get("ui.log-synthetic-elided-nodes")
        .map_err(|e| value_error(&e))?;
    Ok(LogDefaults {
        log,
        log_graph_prioritize,
        short_prefixes,
        synthetic_elided,
    })
}

/// Reads the effective `ui.conflict-marker-style` out of a loaded stack (Story 9.4).
///
/// Mirrors `cli/src/cli_util.rs:962`/`:1074`, where the CLI reads exactly this key to build
/// `ConflictMaterializeOptions.marker_style` for `jj file show`. The value comes from the
/// user's own config through [`load`], with [`BUILTIN_CONFIG_TOML`]'s `"diff"` — the CLI's
/// own default (`cli/src/config/misc.toml:45`) — as the lowest layer, so a Rust constant
/// never decides how a conflict is rendered.
///
/// Returns a `jj_lib` type, which is why it is `pub(crate)`: no `jj_lib` type may appear in
/// a public position (FR-JJ-16).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not one of jj's four style names, or is missing
///   from every layer (impossible while the builtin layer is present).
pub(crate) fn conflict_marker_style(
    config: &StackedConfig,
) -> Result<jj_lib::conflicts::ConflictMarkerStyle, ConfigError> {
    config.get("ui.conflict-marker-style").map_err(|e| value_error(&e))
}

/// Reads the effective `git import` options out of a loaded stack (Story 9.5).
///
/// Mirrors `cli/src/git_util.rs::load_git_import_options` @ v0.44.0 for the two keys it
/// reads off config: `git.abandon-unreachable-commits` and
/// `git.record-synthetic-predecessors`. Both already resolve through
/// `StackedConfig::with_defaults()` — they are jj-lib's own `config/misc.toml` defaults
/// (`true`/`true`) — so no [`BUILTIN_CONFIG_TOML`] entry is added and no Rust constant
/// decides for a user who set `abandon-unreachable-commits = false` (FR-JJ-17).
///
/// `remote_auto_track_bookmarks` stays EMPTY, exactly as
/// [`crate::Repo::git_fetch`] and `clone_into` already leave it: porting the CLI's
/// `remotes.<name>.auto-track-bookmarks` string-expression parser would have to change all
/// three call sites at once, and that is not this story's scope.
///
/// Returns a `jj_lib` type, which is why it is `pub(crate)` (FR-JJ-16).
///
/// # Errors
///
/// - [`ConfigError::Load`] — either key is present with a non-boolean value, or is missing
///   from every layer (impossible while jj-lib's own defaults layer is present).
pub(crate) fn git_import_options(config: &StackedConfig) -> Result<jj_lib::git::GitImportOptions, ConfigError> {
    Ok(jj_lib::git::GitImportOptions {
        abandon_unreachable_commits: config
            .get("git.abandon-unreachable-commits")
            .map_err(|e| value_error(&e))?,
        record_synthetic_predecessors: config
            .get("git.record-synthetic-predecessors")
            .map_err(|e| value_error(&e))?,
        remote_auto_track_bookmarks: HashMap::new(),
    })
}

// ── The two repo-config WRITERS ───────────────────────────────────────────────────
//
// Ported verbatim from `cli/src/commands/git/mod.rs:195-262` @ v0.44.0, minus its two
// `ui.status` lines (terminal UX — Zanshin replaces it; NFR-R-2). The effect those lines
// announce IS ported: Ralph's rule (2026-09-06) is that every on-disk, repo-side effect the
// CLI produces is required parity.

/// A failure while WRITING the repo config, rendered through its `source()` chain.
///
/// One generic function rather than a closure per call site: `set_value`/`delete_value`
/// only fail when the target is a non-inline TABLE, which both call sites below have
/// already ruled out with `as_str()`, so a per-call-site closure would add lines no test
/// can execute. Sharing one body means the reachable instantiations
/// ([`jj_lib::config::ConfigFileSaveError`], via the unwritable-file test) cover the same
/// lines the unreachable one would.
fn write_error<E: std::error::Error + 'static>(err: E) -> ConfigError {
    ConfigError::Load { reason: describe(&err) }
}

/// The repo-level config file this workspace READS, if it exists on disk.
///
/// Resolution is [`secure_config_path`] — the very same call [`add_secure_layer`] makes for
/// `ConfigSource::Repo` — so a writer built on this path can never rewrite a file the
/// session does not read. The `.exists()` filter is the CLI's
/// `existing_repo_config_file` (`cli/src/config.rs:682-691`), which picks an ALREADY-LOADED
/// repo layer and therefore yields nothing when no file was loaded: mirroring it as
/// "resolve, then filter by existence" is what keeps both writers from CREATING a file.
///
/// # Errors
///
/// - [`ConfigError::Load`] — `.jj/repo/config-id` exists but is not exactly 20 ASCII hex
///   characters, or could not be read.
pub(crate) fn existing_repo_config_path(workspace: &Workspace) -> Result<Option<PathBuf>, ConfigError> {
    let env = ConfigEnv::from_env();
    let root = env.root_config_dir();
    let path = secure_config_path(
        // `repo_path()` is jj-lib's already-resolved `.jj/repo` — see `load_for_workspace`.
        workspace.repo_path(),
        "config-id",
        "config.toml",
        root.as_ref().map(|r| r.join("repos")).as_deref(),
    )?;
    Ok(path.filter(|p| p.exists()))
}

/// The `trunk()` alias's value as `(bookmark, remote)`, iff it is a PLAIN remote symbol.
///
/// Mirrors the CLI's `get_trunk_symbol` (`mod.rs:264-274`): look the item up, require a
/// string, parse it as a revset program, and accept only [`jj_lib::revset::ExpressionKind`]
/// `::RemoteSymbol`. Everything else — a missing alias, a non-string value, a compound
/// expression such as `latest(main@origin)`, an unparseable one — yields `None`, so the
/// alias is left exactly as the user wrote it. Rewriting anything richer would mean editing
/// a revset the user composed by hand, which the CLI declines to do too.
fn trunk_symbol(layer: &ConfigLayer) -> Option<(String, String)> {
    let item = layer.look_up_item(TRUNK_CONFIG_NAME).ok().flatten()?;
    let node = jj_lib::revset::parse_program(item.as_str()?).ok()?;
    match node.kind {
        jj_lib::revset::ExpressionKind::RemoteSymbol(symbol) => {
            let RemoteRefSymbolBuf { name, remote } = symbol;
            Some((name.into_string(), remote.into_string()))
        }
        _ => None,
    }
}

/// Drops `remote`'s repo-config presets — the CLI's `remove_remote_from_repo_config`.
///
/// Two edits and no more: `[remotes.<remote>]` is removed, and `revset-aliases.'trunk()'`
/// is DELETED (so the builtin `trunk()` applies again) when it is a plain remote symbol
/// naming `remote`. Both are keyed on the REMOTE name alone — the alias's bookmark half is
/// never compared, because the alias becomes meaningless the moment its remote is gone,
/// whatever bookmark it named.
///
/// `path` is [`existing_repo_config_path`]'s answer: `None` means no repo-level config file
/// exists, and then this is a no-op that creates nothing.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the file could not be read, is not valid TOML, or could not be
///   written back.
pub(crate) fn remove_remote_from_repo_config(path: Option<&Path>, remote: &str) -> Result<(), ConfigError> {
    let Some(path) = path else {
        return Ok(());
    };
    let mut file = ConfigFile::load_or_empty(ConfigSource::Repo, path).map_err(|e| file_error(path, &e))?;

    // [remotes.<remote>]
    if let Some(remotes_item) = file.data_mut().as_table_mut().get_mut("remotes") {
        // `as_table_like_mut`, not `as_table_mut`: it also covers the inline spelling
        // `remotes = { origin = { … } }`, exactly as the CLI does.
        if let Some(remotes_table) = remotes_item.as_table_like_mut() {
            remotes_table.remove(remote);
        }
    }

    // trunk = <name>@<remote>
    if let Some((_, old_remote)) = trunk_symbol(file.layer()) {
        if old_remote == remote {
            file.delete_value(TRUNK_CONFIG_NAME).map_err(write_error)?;
        }
    }

    // Saved unconditionally, as the CLI does: `toml_edit` round-trips the document
    // byte-for-byte, so a no-edit save changes only the file's mtime, and auditing when a
    // save is "needed" would be more code for less parity.
    file.save().map_err(write_error)
}

/// Re-points `old`'s repo-config presets at `new` — the CLI's
/// `rename_remote_in_repo_config`.
///
/// The mirror image of [`remove_remote_from_repo_config`]: `[remotes.<old>]` is re-inserted
/// as `[remotes.<new>]` (value untouched), and a plain-remote-symbol `trunk()` naming `old`
/// is REWRITTEN to name `new`, keeping its bookmark. Same remote-name-only keying, same
/// hands-off treatment of any richer expression.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the file could not be read, is not valid TOML, or could not be
///   written back.
pub(crate) fn rename_remote_in_repo_config(path: Option<&Path>, old: &str, new: &str) -> Result<(), ConfigError> {
    let Some(path) = path else {
        return Ok(());
    };
    let mut file = ConfigFile::load_or_empty(ConfigSource::Repo, path).map_err(|e| file_error(path, &e))?;

    // [remotes.<old>] -> [remotes.<new>]
    if let Some(remotes_item) = file.data_mut().as_table_mut().get_mut("remotes") {
        if let Some(remotes_table) = remotes_item.as_table_like_mut() {
            if let Some(old_item) = remotes_table.remove(old) {
                remotes_table.insert(new, old_item);
            }
        }
    }

    // trunk = <name>@<old> -> <name>@<new>
    if let Some((bookmark, old_remote)) = trunk_symbol(file.layer()) {
        if old_remote == old {
            let new_symbol = RemoteRefSymbolBuf {
                name: bookmark.into(),
                remote: new.into(),
            };
            // `Display` quotes and escapes the way jj's own revset syntax needs.
            file.set_value(TRUNK_CONFIG_NAME, new_symbol.to_string())
                .map_err(write_error)?;
        }
    }

    file.save().map_err(write_error)
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use super::{
        add_secure_layer, is_valid_config_id, load_with, platform_config_dir, remove_remote_from_repo_config,
        rename_remote_in_repo_config, secure_config_path, user_config_paths, ConfigEnv, BUILTIN_CONFIG_TOML,
    };
    use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};

    #[test]
    fn builtin_config_layer_is_valid_toml() {
        let layer = ConfigLayer::parse(ConfigSource::Default, BUILTIN_CONFIG_TOML);
        assert!(layer.is_ok(), "the builtin layer must parse: {layer:?}");
    }

    // ── Platform config dir ───────────────────────────────────────────────────

    #[test]
    fn platform_config_dir_prefers_an_absolute_xdg_config_home() {
        let dir = platform_config_dir(Some(Path::new("/custom/cfg")), Some(Path::new("/home/u")));
        assert_eq!(dir, Some(PathBuf::from("/custom/cfg")));
    }

    #[test]
    fn platform_config_dir_ignores_a_relative_xdg_config_home() {
        let dir = platform_config_dir(Some(Path::new("relative/cfg")), Some(Path::new("/home/u")));
        assert_eq!(dir, Some(PathBuf::from("/home/u/.config")));
    }

    #[test]
    fn platform_config_dir_falls_back_to_home_dot_config() {
        assert_eq!(
            platform_config_dir(None, Some(Path::new("/home/u"))),
            Some(PathBuf::from("/home/u/.config"))
        );
    }

    #[test]
    fn platform_config_dir_without_home_is_unknown() {
        assert_eq!(platform_config_dir(None, None), None);
        assert_eq!(platform_config_dir(Some(Path::new("rel")), None), None);
    }

    // ── User-config discovery ─────────────────────────────────────────────────

    #[test]
    fn jj_config_replaces_discovery_and_keeps_entry_order() {
        let paths = user_config_paths(
            Some(&OsString::from("/a/one.toml:/b/two.toml")),
            Some(Path::new("/home/u/.config")),
            Some(Path::new("/home/u")),
        );
        assert_eq!(
            paths,
            vec![PathBuf::from("/a/one.toml"), PathBuf::from("/b/two.toml")],
            "JJ_CONFIG replaces discovery; the platform paths must not appear"
        );
    }

    #[test]
    fn empty_jj_config_disables_discovery_entirely() {
        let paths = user_config_paths(
            Some(&OsString::from("")),
            Some(Path::new("/home/u/.config")),
            Some(Path::new("/home/u")),
        );
        assert!(paths.is_empty(), "JJ_CONFIG=\"\" must yield zero user layers");
    }

    #[test]
    fn jj_config_drops_empty_path_components() {
        let paths = user_config_paths(Some(&OsString::from(":/a/one.toml::")), None, None);
        assert_eq!(paths, vec![PathBuf::from("/a/one.toml")]);
    }

    #[test]
    fn unset_jj_config_discovers_home_then_platform_file_then_conf_d() {
        let paths = user_config_paths(None, Some(Path::new("/home/u/.config")), Some(Path::new("/home/u")));
        assert_eq!(
            paths,
            vec![
                PathBuf::from("/home/u/.jjconfig.toml"),
                PathBuf::from("/home/u/.config/jj/config.toml"),
                PathBuf::from("/home/u/.config/jj/conf.d"),
            ],
            "ascending precedence: legacy home file, platform file, conf.d"
        );
    }

    #[test]
    fn unset_jj_config_without_a_config_dir_yields_only_the_home_file() {
        let paths = user_config_paths(None, None, Some(Path::new("/home/u")));
        assert_eq!(paths, vec![PathBuf::from("/home/u/.jjconfig.toml")]);
    }

    #[test]
    fn unset_jj_config_without_home_or_config_dir_yields_nothing() {
        assert!(user_config_paths(None, None, None).is_empty());
    }

    // ── config-id validity ────────────────────────────────────────────────────

    #[test]
    fn config_id_must_be_exactly_twenty_ascii_hex_chars() {
        assert!(is_valid_config_id("0123456789abcdef0123"));
        assert!(!is_valid_config_id("0123456789abcdef012"), "19 chars");
        assert!(!is_valid_config_id("0123456789abcdef01234"), "21 chars");
        assert!(!is_valid_config_id("0123456789abcdef012g"), "non-hex char");
        assert!(
            !is_valid_config_id("0123456789abcdef0123\n"),
            "jj-lib does not trim, so a trailing newline is invalid"
        );
    }

    // ── Secure-config path selection ──────────────────────────────────────────

    #[test]
    fn secure_config_path_without_a_config_dir_skips_the_layer() {
        let tmp = tempfile::tempdir().unwrap();
        let path = secure_config_path(tmp.path(), "config-id", "config.toml", None).unwrap();
        assert_eq!(
            path, None,
            "an unknown <config_dir> skips the secure layer (CLI parity)"
        );
    }

    #[test]
    fn secure_config_path_without_an_id_file_falls_back_to_the_legacy_file() {
        let tmp = tempfile::tempdir().unwrap();
        let path =
            secure_config_path(tmp.path(), "config-id", "config.toml", Some(Path::new("/cfg/jj/repos"))).unwrap();
        assert_eq!(path, Some(tmp.path().join("config.toml")));
    }

    #[test]
    fn secure_config_path_with_a_valid_id_points_into_the_config_dir() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("config-id"), "0123456789abcdef0123").unwrap();
        let path =
            secure_config_path(tmp.path(), "config-id", "config.toml", Some(Path::new("/cfg/jj/repos"))).unwrap();
        assert_eq!(
            path,
            Some(PathBuf::from("/cfg/jj/repos/0123456789abcdef0123/config.toml")),
            "the legacy file is neither read nor migrated"
        );
    }

    #[test]
    fn secure_config_path_with_a_malformed_id_is_an_error() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("config-id"), "not-hex").unwrap();
        let err = secure_config_path(tmp.path(), "config-id", "config.toml", Some(Path::new("/cfg/jj/repos")))
            .expect_err("a malformed config-id must hard-error like the CLI");
        let reason = err.to_string();
        assert!(
            reason.contains("config-id"),
            "the offending path must be named, got: {reason}"
        );
    }

    /// A machine with no determinable `<config_dir>` (no `$HOME`, no absolute
    /// `$XDG_CONFIG_HOME`) gets NO repo/workspace layer at all — the CLI behaves the same
    /// way, because its legacy fallback is only reachable through the migration path that
    /// needs a config dir to migrate INTO.
    #[test]
    fn add_secure_layer_without_a_config_dir_adds_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("config.toml"), "[revsets]\nlog = \"ignored\"\n").unwrap();
        let mut config = StackedConfig::empty();
        add_secure_layer(
            &mut config,
            ConfigSource::Repo,
            tmp.path(),
            "config-id",
            "config.toml",
            None,
        )
        .expect("an unknown <config_dir> is not an error, just no layer");
        assert!(
            config.layers().is_empty(),
            "the legacy file must NOT be read without a <config_dir>"
        );
    }

    /// The `config-id` indirection must actually LOAD the file it points at — composing
    /// the right path is only half of it. Fails if `<root>/<id>/config.toml` is misjoined,
    /// and pins that the legacy file is NOT read once an id file exists.
    #[test]
    fn add_secure_layer_loads_the_file_the_config_id_points_at() {
        let repo_dir = tempfile::tempdir().unwrap();
        let root = tempfile::tempdir().unwrap();
        let id = "0123456789abcdef0123";
        std::fs::write(repo_dir.path().join("config-id"), id).unwrap();
        std::fs::create_dir_all(root.path().join(id)).unwrap();
        std::fs::write(
            root.path().join(id).join("config.toml"),
            "[revsets]\nlog = \"from-config-id\"\n",
        )
        .unwrap();
        // Present on purpose: with a valid id file this must be ignored, not merged.
        std::fs::write(
            repo_dir.path().join("config.toml"),
            "[revsets]\nlog = \"from-legacy\"\n",
        )
        .unwrap();

        let mut config = StackedConfig::empty();
        add_secure_layer(
            &mut config,
            ConfigSource::Repo,
            repo_dir.path(),
            "config-id",
            "config.toml",
            Some(root.path()),
        )
        .expect("the id-addressed file must load");
        assert_eq!(
            config.get::<String>("revsets.log").unwrap(),
            "from-config-id",
            "the legacy file must be neither read nor merged"
        );
    }

    /// End-to-end over [`load_with`]: the repo layer must resolve through
    /// `<config_dir>/jj/repos/<id>/` and the workspace layer through
    /// `<config_dir>/jj/workspaces/<id>/`. Swapping or misspelling either sub-directory
    /// makes BOTH layers miss their file, so neither override survives and this fails.
    #[test]
    fn load_with_reads_repo_and_workspace_layers_through_their_own_config_dirs() {
        let repo_root = tempfile::tempdir().unwrap();
        let cfg = tempfile::tempdir().unwrap();
        let repo_path = repo_root.path().join(".jj").join("repo");
        let jj_dir = repo_root.path().join(".jj");
        std::fs::create_dir_all(&repo_path).unwrap();

        let write_secure = |kind: &str, id: &str, body: &str| {
            let dir = cfg.path().join("jj").join(kind).join(id);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("config.toml"), body).unwrap();
        };
        let repo_id = "aaaaaaaaaaaaaaaaaaaa";
        let ws_id = "bbbbbbbbbbbbbbbbbbbb";
        std::fs::write(repo_path.join("config-id"), repo_id).unwrap();
        std::fs::write(jj_dir.join("workspace-config-id"), ws_id).unwrap();
        write_secure(
            "repos",
            repo_id,
            "[revsets]\nlog = \"repo\"\nshort-prefixes = \"repo\"\n",
        );
        write_secure("workspaces", ws_id, "[revsets]\nlog = \"workspace\"\n");

        let env = ConfigEnv {
            config_dir: Some(cfg.path().to_owned()),
            home_dir: None,
            // Set-but-empty: user discovery disabled, exactly as the suite pins it.
            jj_config: Some(OsString::new()),
            environment: HashMap::new(),
        };
        let config = load_with(&env, &repo_path, repo_root.path()).expect("the stack must load");

        assert_eq!(
            config.get::<String>("revsets.log").unwrap(),
            "workspace",
            "the workspace layer sits above the repo layer"
        );
        assert_eq!(
            config.get::<String>("revsets.short-prefixes").unwrap(),
            "repo",
            "a key only the repo layer sets still comes through"
        );
    }

    // ── Repo-config writers (Epic 9 follow-up J) ──────────────────────────────
    //
    // Unit-tested directly against tempfile paths: every row here is about the FILE, and a
    // real workspace would add nothing but cost. The rows that need a repo (the transaction
    // ordering, the same-session read-back) live in `tests/git_remotes.rs`.

    /// Writes `body` to a fresh temp dir and returns `(dir, path)`.
    fn repo_config(body: &str) -> (tempfile::TempDir, PathBuf) {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("config.toml");
        std::fs::write(&path, body).unwrap();
        (tmp, path)
    }

    fn read_back(path: &Path) -> String {
        std::fs::read_to_string(path).expect("the config file must still be readable")
    }

    const PINNED: &str = "\
[remotes.origin]
fetch-bookmarks = \"main\"

[revset-aliases]
'trunk()' = 'main@origin'
";

    #[test]
    fn remove_drops_the_remotes_section_and_the_matching_trunk_alias() {
        let (_tmp, path) = repo_config(PINNED);
        remove_remote_from_repo_config(Some(&path), "origin").expect("the rewrite must succeed");
        let after = read_back(&path);
        assert!(!after.contains("remotes.origin"), "the section must be gone: {after:?}");
        assert!(
            !after.contains("trunk()"),
            "the alias must be DELETED so the builtin applies again: {after:?}"
        );
    }

    #[test]
    fn rename_moves_the_remotes_section_and_repoints_the_trunk_alias() {
        let (_tmp, path) = repo_config(PINNED);
        rename_remote_in_repo_config(Some(&path), "origin", "upstream").expect("the rewrite must succeed");
        let after = read_back(&path);
        assert!(after.contains("upstream"), "the section must move: {after:?}");
        assert!(!after.contains("remotes.origin"), "…and not be duplicated: {after:?}");
        assert!(
            after.contains("fetch-bookmarks = \"main\""),
            "the section's VALUE must survive the move: {after:?}"
        );
        assert!(
            after.contains("'trunk()' = \"main@upstream\"") || after.contains("'trunk()' = 'main@upstream'"),
            "the alias must keep its bookmark and name the new remote: {after:?}"
        );
    }

    /// Both edits key on the REMOTE name alone, so a remote of another name is untouched —
    /// and so is an alias that names one.
    #[test]
    fn an_alias_and_a_section_naming_a_different_remote_survive_both_verbs() {
        let body = "[remotes.other]\nfetch-tags = \"none\"\n\n[revset-aliases]\n'trunk()' = 'main@other'\n";
        let (_tmp, remove_path) = repo_config(body);
        remove_remote_from_repo_config(Some(&remove_path), "origin").expect("remove");
        assert!(read_back(&remove_path).contains("main@other"));
        assert!(read_back(&remove_path).contains("remotes.other"));

        let (_tmp2, rename_path) = repo_config(body);
        rename_remote_in_repo_config(Some(&rename_path), "origin", "upstream").expect("rename");
        assert!(read_back(&rename_path).contains("main@other"));
        assert!(read_back(&rename_path).contains("remotes.other"));
    }

    /// Anything that is not a PLAIN remote symbol is left exactly as the user wrote it — a
    /// compound expression, an unparseable one, and a non-string value alike.
    #[test]
    fn a_trunk_alias_that_is_not_a_plain_remote_symbol_survives_both_verbs() {
        for value in ["'latest(main@origin)'", "'('", "42"] {
            let body = format!("[revset-aliases]\n'trunk()' = {value}\n");
            let (_tmp, path) = repo_config(&body);
            remove_remote_from_repo_config(Some(&path), "origin").expect("remove");
            assert_eq!(read_back(&path), body, "remove must leave {value} alone");

            let (_tmp2, path2) = repo_config(&body);
            rename_remote_in_repo_config(Some(&path2), "origin", "upstream").expect("rename");
            assert_eq!(read_back(&path2), body, "rename must leave {value} alone");
        }
    }

    /// A `revset-aliases` that is not a table at all: `look_up_item` reports the middle node,
    /// which is treated exactly like an absent alias.
    #[test]
    fn a_non_table_revset_aliases_key_is_left_alone() {
        let body = "revset-aliases = 42\n";
        let (_tmp, path) = repo_config(body);
        remove_remote_from_repo_config(Some(&path), "origin").expect("remove");
        assert_eq!(read_back(&path), body);
    }

    /// `None` is the state the CLI's `existing_repo_config_file` returns when no repo layer
    /// was loaded: both writers succeed and, having no path at all, touch no file. That
    /// [`existing_repo_config_path`] really answers `None` for a workspace with no
    /// repo-level file — the other half of "creates nothing" — is pinned by
    /// `tests/git_remotes.rs::without_a_repo_config_file_both_verbs_succeed_and_create_none`.
    #[test]
    fn an_absent_repo_config_is_a_no_op_for_both_writers() {
        remove_remote_from_repo_config(None, "origin").expect("remove must succeed");
        rename_remote_in_repo_config(None, "origin", "upstream").expect("rename must succeed");
    }

    /// `toml_edit` round-trips the document, so everything the two edits do not touch —
    /// comments, key order, quoting, unrelated tables — survives byte-for-byte.
    #[test]
    fn comments_and_unrelated_keys_survive_the_rewrite() {
        let body = "\
# a comment the user wrote
[revsets]
log = \"mine\"   # trailing comment

[remotes.origin]
fetch-bookmarks = \"main\"

[remotes.keepme]
fetch-tags = \"none\"

[revset-aliases]
'trunk()' = 'main@origin'
'wip()' = 'description(\"wip\")'
";
        let (_tmp, path) = repo_config(body);
        remove_remote_from_repo_config(Some(&path), "origin").expect("remove");
        let after = read_back(&path);
        assert!(after.contains("# a comment the user wrote"));
        assert!(after.contains("log = \"mine\"   # trailing comment"));
        assert!(after.contains("[remotes.keepme]"));
        assert!(after.contains("'wip()' = 'description(\"wip\")'"));
        assert!(!after.contains("[remotes.origin]"));
        assert!(!after.contains("trunk()"));
    }

    #[test]
    fn an_absent_or_non_table_remotes_key_is_not_an_error() {
        for body in ["[revsets]\nlog = \"mine\"\n", "remotes = 42\n"] {
            let (_tmp, path) = repo_config(body);
            remove_remote_from_repo_config(Some(&path), "origin").expect("remove");
            assert_eq!(read_back(&path), body);

            let (_tmp2, path2) = repo_config(body);
            rename_remote_in_repo_config(Some(&path2), "origin", "upstream").expect("rename");
            assert_eq!(read_back(&path2), body);
        }
    }

    /// `as_table_like_mut`, not `as_table_mut`: the inline spelling is edited too, exactly
    /// as the CLI does.
    #[test]
    fn an_inline_remotes_table_is_edited_too() {
        let (_tmp, path) = repo_config("remotes = { origin = { fetch-tags = \"none\" } }\n");
        rename_remote_in_repo_config(Some(&path), "origin", "upstream").expect("rename");
        let after = read_back(&path);
        assert!(after.contains("upstream"), "the inline entry must move: {after:?}");
        assert!(!after.contains("origin"), "…and the old key must be gone: {after:?}");
    }

    #[test]
    fn an_unparseable_repo_config_is_a_config_error_naming_the_file() {
        let (_tmp, path) = repo_config("not = = toml\n");
        let err = remove_remote_from_repo_config(Some(&path), "origin").expect_err("invalid TOML must refuse");
        let reason = err.to_string();
        assert!(
            reason.contains("config.toml") && reason.contains("TOML"),
            "the file and the parse position must both be named, got: {reason}"
        );
    }

    #[test]
    fn an_unwritable_repo_config_is_a_config_error() {
        use std::os::unix::fs::PermissionsExt as _;

        let (_tmp, path) = repo_config(PINNED);
        // Readable, so the load succeeds and only `save()` can fail.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o444)).unwrap();
        let err = rename_remote_in_repo_config(Some(&path), "origin", "upstream")
            .expect_err("an unwritable file must refuse");
        let reason = err.to_string();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(
            reason.contains("config.toml"),
            "the io reason must name the file, got: {reason}"
        );
    }

    #[test]
    fn secure_config_path_propagates_an_unreadable_id_file() {
        let tmp = tempfile::tempdir().unwrap();
        // A DIRECTORY named `config-id`: read_to_string fails with something other than
        // NotFound, which must propagate rather than silently fall back to the legacy file.
        std::fs::create_dir(tmp.path().join("config-id")).unwrap();
        let err = secure_config_path(tmp.path(), "config-id", "config.toml", Some(Path::new("/cfg/jj/repos")))
            .expect_err("an unreadable config-id must propagate");
        assert!(err.to_string().contains("config-id"));
    }
}
