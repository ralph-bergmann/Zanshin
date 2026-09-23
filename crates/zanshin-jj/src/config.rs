// SPDX-License-Identifier: MIT

//! The repo's effective jj config — the one layer stack every revset parse and the
//! `jj log` defaults are read from (Story 4.9).
//!
//! [`load`] rebuilds, per operation, the `StackedConfig` the jj CLI would have at v0.44.0
//! for this workspace, in the CLI's own order (`cli/src/config.rs:713-730`): jj-lib's
//! defaults plus Zanshin's builtin default layer ([`BUILTIN_CONFIG_TOML`]), the system
//! config (`/etc/jj`), the `EnvBase` layer, the user config (`JJ_CONFIG` or platform
//! discovery), the repo layer, the workspace layer, the `EnvOverrides` layer, finally flattened
//! through `jj_lib::config::resolve`. Nothing is cached — config files change externally and
//! the op-heads watcher does not cover them, so ADR-0002's re-resolve-per-operation rule
//! extends to config.
//!
//! The SAME stack is what a workspace is opened with (Story 9.27): [`user_settings_for`]
//! builds the `UserSettings` jj-lib signs commits and operations with from it, and
//! [`stack_fingerprint`] lets [`crate::Repo`] re-derive them when a file of the stack or
//! the environment changed — the CLI derives its settings per invocation.
//!
//! # Reading never writes; only the writer family does
//!
//! Every READ path here is side-effect-free: no directory is created, no file is written,
//! no `config-id` is generated, nothing is migrated. That stance is unchanged.
//!
//! Everything that DOES write belongs to ONE writer family, built from the same helpers:
//! [`load_config_file`] / [`save_config_file`] (`ConfigFile::load_or_empty` / `save`, a
//! `toml_edit` round trip that keeps comments and formatting) and one create-mode secure
//! resolver, [`SecureLayer::create_path`] (`SecureConfig::load_config` — the only path here that
//! creates a directory and writes `metadata.binpb` and an id file). Its members:
//!
//! - the general config surface of Story 9.28 (`config_cmd.rs`: `jj config set` / `unset` /
//!   `edit` / `path` for the user, repo and workspace scope), which selects its file with the
//!   CLI's `edit_config_file` rule — the existing files of the scope, else the CLI's new-file
//!   default ([`user_config_candidates`]' first entry, or the create-forced secure file).
//!   One exception to the shared save: `edit`'s write half (`config_file_write`) stores the
//!   validated text VERBATIM with `fs::write`, as the user's own editor does in the CLI — not
//!   through a [`save_config_file`] round trip, so a change to that helper does not reach it;
//! - [`remove_remote_from_repo_config`] and [`rename_remote_in_repo_config`], called by
//!   [`crate::Repo::git_remote_remove`] / [`crate::Repo::git_remote_rename`] — the two remote
//!   verbs whose CLI counterparts rewrite the repo-level file
//!   (`cli/src/commands/git/mod.rs:195-262` @ v0.44.0). They make exactly the CLI's two edits
//!   and NEVER create a file: the CLI resolves theirs through `existing_repo_config_file`, which
//!   yields nothing when no repo layer was loaded, so the path here is the READ side's
//!   [`SecureLayer::resolved_path`] filtered by existence ([`existing_repo_config_file`]) and
//!   read and write address the same file by construction. `git remote add`/`set-url` write
//!   no config at all;
//! - [`set_trunk_alias`], called by `convert.rs` for the `trunk()` alias `jj git init`'s
//!   External branch writes (`write_repo_presets`, `cli/src/commands/git/mod.rs:156-193` @
//!   v0.44.0). It MAY create the repo-level file, because its CLI counterpart resolves through
//!   the create-FORCING `repo_config_path` ([`new_repo_config_file`] here): `jj git init`
//!   legitimately brings the repo layer into being, whereas `jj git remote remove` on a repo
//!   that has no repo config must leave the user with no repo config.
//!
//! The remote writers take an ALREADY-LOADED [`ConfigFile`], never a path: the CLI's
//! `existing_repo_config_file` wraps a layer its process loaded at start-up, so a repo config
//! that cannot be read or parsed makes the CLI fail before it mutates anything. Loading here
//! too — in [`existing_repo_config_file`], before the caller opens its transaction — is what
//! reproduces that end state.
//!
//! # WHY: by hand for READS, `SecureConfig` for the CREATES
//!
//! The CLI reaches the repo/workspace layer through `SecureConfig`, whose
//! `maybe_load_config` WRITES: it creates directories, writes `metadata.binpb`, can
//! generate a fresh `config-id`, copies configs when it detects a moved/copied repo, and on
//! Unix replaces the legacy file with a symlink — and it needs a `&mut ChaCha20Rng`. A GUI
//! backend must not rewrite the user's repo layout while drawing a graph, so on every READ
//! path the `config-id` → path indirection is resolved here by reading the id and joining the
//! path. For a repo the CLI has already seen, that yields identical config CONTENT; what is
//! given up is the CLI's migration and its terminal warning, and Zanshin has no terminal (it
//! replaces the CLI's UX — NFR-R-2).
//!
//! [`SecureLayer::create_path`] is the one place that calls `SecureConfig::load_config`, and it
//! does so deliberately: it runs only from a WRITE the CLI performs through the same
//! create-forcing call (a conversion writing the repo into being, a `config set`/`unset`/`edit`/
//! `path` at repo or workspace scope), and calling jj-lib reproduces that layout exactly — the `<root>/<id>/` directory, the
//! `metadata.binpb`, and the atomic `.jj/repo/config-id` write — without re-implementing
//! `config-id` generation. Writing the legacy `.jj/repo/config.toml` instead would be read
//! correctly by both tools but would leave the CLI to MIGRATE it on its next run (a new
//! secure directory, a symlink where the file was, a status line), i.e. a different on-disk
//! end state than `jj git init` produces.
//!
//! One documented exception: `handle_metadata_path` (`secure_config.rs:187-252`) re-points
//! or COPIES the config when it detects that the repo was moved or copied. Zanshin never
//! performs that fix-up, so between a repo copy and the next `jj` invocation that repairs
//! it, the CLI and Zanshin can read different files. Rewriting the user's config store
//! from a read path is the worse trade — a GUI drawing a graph must not mutate layout.
//!
//! # The environment layers, and what is still absent
//!
//! The `EnvBase` and `EnvOverrides` layers are ported key for key from the CLI's
//! `env_base_layer` / `env_overrides_layer` (`cli/src/config.rs:736-819` @ v0.44.0):
//! `operation.hostname`/`operation.username` from `whoami` (the CLI's own crate, `$USER` as
//! the username fallback), `NO_COLOR` → `ui.color`, `VISUAL`/`EDITOR` → `ui.editor`, and the
//! `JJ_USER`, `JJ_EMAIL`, `JJ_TIMESTAMP`, `JJ_RANDOMNESS_SEED`, `JJ_OP_TIMESTAMP`,
//! `JJ_OP_HOSTNAME`, `JJ_OP_USERNAME`, `JJ_EDITOR` and `JJ_PAGER` overrides. The `ui.*` keys
//! have no consumer here; they are carried for layer parity, so the stack a future config
//! listing shows is the CLI's. jj reads identity from this stack ONLY — there is no
//! `.gitconfig` fallback to port.
//!
//! Still absent: the `--config`/`--config-file` command-line layer (Zanshin has no CLI args),
//! and `migrate` — its rule list is empty at the pin. `resolve` runs with `command: None`
//! (a state the CLI itself produces before a subcommand is known) for every verb except the
//! config verbs, which pass their CLI command name (`"config set"`, …) through
//! [`resolve_raw`], so `--when.commands` scopes match there as in the CLI; `--when.hostnames`
//! scopes match against `whoami::hostname()`, exactly as in the CLI.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use jj_lib::backend::{BackendInitError, BackendLoadError};
use jj_lib::config::{
    resolve, ConfigFile, ConfigGetError, ConfigGetResultExt as _, ConfigLayer, ConfigLoadError,
    ConfigResolutionContext, ConfigSource, ConfigValue, StackedConfig,
};
use jj_lib::git_backend::{GitBackendInitError, GitBackendLoadError};
use jj_lib::ref_name::RemoteRefSymbolBuf;
use jj_lib::repo::StoreLoadError;
use jj_lib::secure_config::{self, SecureConfig};
use jj_lib::settings::UserSettings;
use jj_lib::workspace::{Workspace, WorkspaceInitError, WorkspaceLoadError, WorkspaceLoader};
use rand_chacha::rand_core::SeedableRng as _;
use rand_chacha::ChaCha20Rng;

use crate::Repo;

/// Zanshin's builtin default config layer — the lowest layer of the stack, and the one a
/// user's `[revset-aliases]` or `[revsets]` entry overrides.
///
/// The `[revsets] log` / `log-graph-prioritize` values and the whole `[revset-aliases]`
/// table are verbatim from `cli/src/config/revsets.toml` at v0.44.0;
/// `ui.log-synthetic-elided-nodes` is verbatim from `cli/src/config/misc.toml:44` and
/// `ui.conflict-marker-style` from `cli/src/config/misc.toml:45` (Story 9.4 — the style
/// `file show` materializes a conflicted file with); `snapshot.max-new-file-size` and
/// `snapshot.auto-track` are verbatim from `cli/src/config/misc.toml:60-61` (Story 9.22 — the
/// snapshot options `file track`/`file untrack` build; jj-lib's own `config/misc.toml` has
/// neither, so without them the keys would be missing, not defaulted).
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

[snapshot]
max-new-file-size = "1MiB"
auto-track = "all()"
auto-update-stale = false

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

/// Errors from reading the repo's effective jj config — or, for the two repo-config
/// writers below, from writing the repo-level file back.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// A config file could not be read, parsed or written back, a `config-id` is malformed,
    /// or a config value has the wrong type. The offending file path or config key is in
    /// `reason`.
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
/// Split out so [`load_with`], the path-selection helpers and the config verbs
/// (`config_cmd.rs`, Story 9.28) are testable without touching the process environment.
pub(crate) struct ConfigEnv {
    /// The platform config dir (`<config_dir>`), e.g. `~/.config`.
    pub(crate) config_dir: Option<PathBuf>,
    /// Canonicalized `$HOME`.
    pub(crate) home_dir: Option<PathBuf>,
    /// `JJ_CONFIG` — `Some` even when empty, which is how the CLI disables discovery.
    pub(crate) jj_config: Option<OsString>,
    /// Environment snapshot for `--when.env` scope resolution and the two env layers.
    pub(crate) environment: HashMap<String, String>,
    /// The system config dir, `/etc` on Unix (`cli/src/config.rs:377-381`).
    pub(crate) system_config_dir: Option<PathBuf>,
    /// `whoami::hostname()` — the `EnvBase` `operation.hostname` and the `--when.hostnames`
    /// resolution context.
    pub(crate) hostname: Option<String>,
    /// `whoami::username()`, falling back to `$USER` — the `EnvBase` `operation.username`.
    pub(crate) username: Option<String>,
}

impl ConfigEnv {
    /// Snapshots the environment the way `ConfigEnv::from_environment`
    /// (`cli/src/config.rs:366-419` @ v0.44.0) does.
    pub(crate) fn from_env() -> Self {
        let home_dir = std::env::var_os("HOME").map(PathBuf::from).map(|d| {
            // WHY: the CLI canonicalizes $HOME (dunce::canonicalize, == std::fs::canonicalize
            // on Unix) because it may be a symlink and `--when.repositories` compares paths.
            std::fs::canonicalize(&d).unwrap_or(d)
        });
        let xdg = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from);
        // WHY: vars_os + filter_map, not vars() — vars() PANICS on a non-Unicode
        // variable, and nothing reachable from FFI may panic.
        let environment: HashMap<String, String> = std::env::vars_os()
            .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
            .collect();
        Self {
            config_dir: platform_config_dir(xdg.as_deref(), home_dir.as_deref()),
            // WHY `var`, not `var_os`: the CLI reads `env::var("JJ_CONFIG").ok()` (`cli/src/config.rs:386`
            // @ v0.44.0), so a non-UTF-8 value counts as UNSET there (system layer + discovery on).
            jj_config: std::env::var("JJ_CONFIG").ok().map(OsString::from),
            system_config_dir: Some(PathBuf::from("/etc")),
            hostname: whoami::hostname().ok(),
            // WHY the `$USER` fallback: the CLI's own (`env_base_layer`), for libcs whose
            // `getpwuid()` does not fully support nsswitch.
            username: whoami::username().ok().or_else(|| environment.get("USER").cloned()),
            environment,
            home_dir,
        }
    }

    /// `<config_dir>/jj` — the root the secure per-repo/per-workspace config dirs hang off.
    pub(crate) fn root_config_dir(&self) -> Option<PathBuf> {
        self.config_dir.as_ref().map(|d| d.join("jj"))
    }

    /// `JJ_RANDOMNESS_SEED` as the CLI's config-id RNG reads it: a `u64`, ignored when it
    /// does not parse (`cli/src/config.rs:411-417`).
    pub(crate) fn randomness_seed(&self) -> Option<u64> {
        self.environment.get("JJ_RANDOMNESS_SEED").and_then(|s| s.parse().ok())
    }

    /// One environment variable, as a config value.
    fn var(&self, name: &str) -> Option<ConfigValue> {
        self.environment.get(name).map(|v| ConfigValue::from(v.as_str()))
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

/// Candidate system-config paths, mirroring `UnresolvedConfigEnv::resolve_system`
/// (`cli/src/config.rs:334-345` @ v0.44.0): `<system>/jj/config.toml` then `<system>/jj/conf.d`
/// — and NOTHING when `JJ_CONFIG` is set, empty included, which is how the test suite (and a
/// user) opts out of every file outside the repo.
fn system_config_paths(system_config_dir: Option<&Path>, jj_config: Option<&OsStr>) -> Vec<PathBuf> {
    match (system_config_dir, jj_config) {
        (Some(dir), None) => vec![dir.join("jj").join("config.toml"), dir.join("jj").join("conf.d")],
        _ => Vec::new(),
    }
}

/// The user-config candidates of `env`, in ascending precedence.
fn env_user_config_paths(env: &ConfigEnv) -> Vec<PathBuf> {
    user_config_paths(
        env.jj_config.as_deref(),
        env.config_dir.as_deref(),
        env.home_dir.as_deref(),
    )
}

/// The user-config paths EXACTLY as the CLI lists them for `jj config path --user` and picks
/// the new-file default from — `UnresolvedConfigEnv::resolve_user` (`cli/src/config.rs:289-332`
/// @ v0.44.0), existence checks included (Story 9.28).
///
/// Differs from [`user_config_paths`] only for NON-existent discovery candidates: `~/.jjconfig.toml`
/// is listed only when it exists (or no `<config_dir>` is known), `<config_dir>/jj/config.toml`
/// always ("the default config created if there's no user config"), `conf.d` only when it
/// exists. `JJ_CONFIG` entries are listed as given, existing or not. For every EXISTING path
/// the two lists agree, so the read side is unaffected.
pub(crate) fn user_config_candidates(env: &ConfigEnv) -> Vec<PathBuf> {
    if env.jj_config.is_some() {
        return env_user_config_paths(env);
    }
    let home = env.home_dir.as_ref().map(|h| h.join(".jjconfig.toml"));
    let platform = env.config_dir.as_ref().map(|d| d.join("jj").join("config.toml"));
    let conf_d = env.config_dir.as_ref().map(|d| d.join("jj").join("conf.d"));
    let mut paths: Vec<PathBuf> = home.filter(|p| p.exists() || platform.is_none()).into_iter().collect();
    paths.extend(platform);
    paths.extend(conf_d.filter(|p| p.exists()));
    paths
}

/// The existing user config FILES, expanded exactly as [`add_path_layers`] loads them: an
/// existing file is itself, an existing directory its sorted `*.toml` files (Story 9.28).
///
/// This is the file list behind the CLI's `user_config_files` — one per raw `User` layer — but
/// enumerated WITHOUT parsing, so a broken file is still a candidate the GUI can open and
/// repair (`jj config edit`'s role). An unreadable directory contributes nothing here; the
/// stack load names it.
pub(crate) fn user_edit_candidates(env: &ConfigEnv) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for path in env_user_config_paths(env).into_iter().filter(|p| p.exists()) {
        if path.is_dir() {
            let mut entries: Vec<PathBuf> = std::fs::read_dir(&path)
                .into_iter()
                .flatten()
                .flatten()
                .map(|entry| entry.path())
                .filter(|p| p.is_file() && p.extension() == Some(OsStr::new("toml")))
                .collect();
            entries.sort_unstable();
            files.extend(entries);
        } else {
            files.push(path);
        }
    }
    files
}

/// `std::fs::create_dir_all`, but every directory it creates is `0700` — the CLI's own
/// `create_dir_all` (`cli/src/config.rs:262-273` @ v0.44.0), used for a new user config
/// file's parent.
pub(crate) fn create_private_dir_all(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt as _;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(path)
}

/// Adds the EXISTING candidates of `paths` as `source` layers, directories expanded like the
/// CLI's `reload_system_config` / `reload_user_config` (`cli/src/config.rs:428-438`,
/// `:516-526`).
fn add_path_layers(config: &mut StackedConfig, source: ConfigSource, paths: &[PathBuf]) -> Result<(), ConfigError> {
    for path in paths.iter().filter(|p| p.exists()) {
        if path.is_dir() {
            config.load_dir(source, path)
        } else {
            config.load_file(source, path)
        }
        .map_err(|e| file_error(path, &e))?;
    }
    Ok(())
}

const OP_HOSTNAME: &str = "operation.hostname";
const OP_USERNAME: &str = "operation.username";

/// Builds one environment layer from `(name, value)` pairs, skipping the absent values.
///
/// `set_value` only fails when a middle node of `name` is a non-table, which a fresh layer
/// holding only these distinct dotted keys cannot contain — so the `?` below never fires. It
/// goes through [`write_error`] for the reason given there.
fn env_layer(
    source: ConfigSource,
    entries: Vec<(&'static str, Option<ConfigValue>)>,
) -> Result<ConfigLayer, ConfigError> {
    let mut layer = ConfigLayer::empty(source);
    for (name, value) in entries.into_iter().filter_map(|(name, value)| Some((name, value?))) {
        layer.set_value(name, value).map_err(write_error)?;
    }
    Ok(layer)
}

/// The CLI's `env_base_layer` (`cli/src/config.rs:736-765` @ v0.44.0): values config files
/// override.
///
/// `NO_COLOR` counts only when non-empty ("User-level configuration files … should override
/// `$NO_COLOR`", <https://no-color.org/>), `VISUAL` wins over `EDITOR`, and `$PAGER` is
/// deliberately NOT read — all three exactly as there.
fn env_base_layer(env: &ConfigEnv) -> Result<ConfigLayer, ConfigError> {
    let no_color = env.environment.get("NO_COLOR").filter(|v| !v.is_empty());
    env_layer(
        ConfigSource::EnvBase,
        vec![
            (OP_HOSTNAME, env.hostname.as_deref().map(ConfigValue::from)),
            (OP_USERNAME, env.username.as_deref().map(ConfigValue::from)),
            ("ui.color", no_color.map(|_| ConfigValue::from("never"))),
            ("ui.editor", env.var("VISUAL").or_else(|| env.var("EDITOR"))),
        ],
    )
}

/// The CLI's `env_overrides_layer` (`cli/src/config.rs:789-819` @ v0.44.0): values that
/// override every config file.
///
/// `JJ_RANDOMNESS_SEED` is written as an `i64` and dropped when it does not parse as one,
/// exactly as there.
fn env_overrides_layer(env: &ConfigEnv) -> Result<ConfigLayer, ConfigError> {
    let seed = env
        .environment
        .get("JJ_RANDOMNESS_SEED")
        .and_then(|s| s.parse::<i64>().ok());
    env_layer(
        ConfigSource::EnvOverrides,
        vec![
            ("user.name", env.var("JJ_USER")),
            ("user.email", env.var("JJ_EMAIL")),
            ("debug.commit-timestamp", env.var("JJ_TIMESTAMP")),
            ("debug.randomness-seed", seed.map(ConfigValue::from)),
            ("debug.operation-timestamp", env.var("JJ_OP_TIMESTAMP")),
            (OP_HOSTNAME, env.var("JJ_OP_HOSTNAME")),
            (OP_USERNAME, env.var("JJ_OP_USERNAME")),
            ("ui.editor", env.var("JJ_EDITOR")),
            ("ui.pager", env.var("JJ_PAGER")),
        ],
    )
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

/// The repo (`.jj/repo`, already resolved through a secondary workspace's FILE indirection)
/// and the workspace root a stack is built for.
#[derive(Clone, Copy)]
pub(crate) struct WorkspacePaths<'a> {
    pub(crate) repo_path: &'a Path,
    pub(crate) workspace_root: &'a Path,
}

/// One secure (repo or workspace) layer: where its id file lives and which
/// `<config_dir>/jj/<kind>` root the id is joined onto.
pub(crate) struct SecureLayer {
    pub(crate) source: ConfigSource,
    /// The directory holding the id file: `.jj/repo` for the repo, `.jj` for the workspace.
    dir: PathBuf,
    id_file_name: &'static str,
    legacy_file_name: &'static str,
    root_config_dir: Option<PathBuf>,
    /// `SecureConfig::new_repo` or `new_workspace` — the create-mode resolver's constructor.
    new_secure: fn(PathBuf) -> SecureConfig,
}

impl SecureLayer {
    /// The repo layer of the repo dir `repo_dir`, whose ids join onto `repos_root`
    /// (`<config_dir>/jj/repos`).
    fn repo_at(repo_dir: PathBuf, repos_root: Option<PathBuf>) -> Self {
        Self {
            source: ConfigSource::Repo,
            dir: repo_dir,
            id_file_name: "config-id",
            legacy_file_name: "config.toml",
            root_config_dir: repos_root,
            new_secure: SecureConfig::new_repo,
        }
    }

    /// True iff this layer's id file (`config-id` / `workspace-config-id`) exists — i.e. the
    /// secure file is selected, not the legacy fallback.
    pub(crate) fn has_id_file(&self) -> bool {
        self.dir.join(self.id_file_name).exists()
    }

    /// The file this layer READS, resolved side-effect-free ([`secure_config_path`]); it may
    /// not exist.
    ///
    /// # Errors
    ///
    /// - [`ConfigError::Load`] — the id file is unreadable or malformed.
    pub(crate) fn resolved_path(&self) -> Result<Option<PathBuf>, ConfigError> {
        secure_config_path(
            &self.dir,
            self.id_file_name,
            self.legacy_file_name,
            self.root_config_dir.as_deref(),
        )
    }

    /// True iff the secure directory of `config_file` records ANOTHER, still existing
    /// repo/workspace dir than this layer's — a COPIED repo, which shares its original's id file
    /// and whose config `SecureConfig`'s next load forks (`handle_metadata_path`). Compared on
    /// canonical paths, so the same dir reached through a symlink is not a copy; a recorded dir
    /// that is gone (a MOVED repo: same file after the re-point) or an unreadable record is
    /// `false`. Side-effect-free.
    pub(crate) fn records_another_dir(&self, config_file: &Path) -> bool {
        let recorded = config_file
            .parent()
            .and_then(|dir| secure_config::read_metadata(dir).ok())
            .and_then(|metadata| {
                secure_config::metadata_path(&metadata)
                    .ok()
                    .flatten()
                    .map(Path::to_owned)
            });
        match (recorded.map(std::fs::canonicalize), std::fs::canonicalize(&self.dir)) {
            (Some(Ok(recorded)), Ok(dir)) => recorded != dir,
            _ => false,
        }
    }

    /// The file this layer's WRITERS address, CREATING the secure directory, `metadata.binpb`
    /// and the id file when missing and migrating a legacy file — `SecureConfig::load_config`,
    /// the CLI's create-forcing `repo_config_path` / `workspace_config_path`
    /// (`cli/src/config.rs:545-549`, `:616-625` @ v0.44.0). The `config.toml` itself is NOT
    /// created. `Ok(None)` iff no `<config_dir>` is known — then nothing is written.
    ///
    /// `SecureConfig`'s `&mut ChaCha20Rng` is seeded as the CLI seeds it
    /// (`cli/src/config.rs:411-417`): from `randomness_seed` (`JJ_RANDOMNESS_SEED`) when set,
    /// else from the OS RNG — drawn here by hand, because `rand::make_rng()`, what the CLI
    /// passes, `expect`s on OS-RNG failure and nothing reachable from FFI may panic.
    ///
    /// # Errors
    ///
    /// - [`ConfigError::Load`] — the OS RNG failed, or the secure-config directory / id file
    ///   could not be read, created or written.
    pub(crate) fn create_path(&self, randomness_seed: Option<u64>) -> Result<Option<PathBuf>, ConfigError> {
        let Some(root) = self.root_config_dir.as_deref() else {
            return Ok(None);
        };
        let mut rng = if let Some(seed) = randomness_seed {
            ChaCha20Rng::seed_from_u64(seed)
        } else {
            let mut seed = [0_u8; 32];
            getrandom::fill(&mut seed).map_err(write_error)?;
            ChaCha20Rng::from_seed(seed)
        };
        let loaded = (self.new_secure)(self.dir.clone())
            .load_config(&mut rng, root)
            .map_err(write_error)?;
        Ok(loaded.config_file)
    }
}

/// The repo and workspace secure layers, in ascending precedence — the ONE description both
/// [`load_with`] and [`fingerprint_with`] walk, so the fingerprint can never miss a file the
/// stack reads — and the config verbs write (Story 9.28).
pub(crate) fn secure_layers(env: &ConfigEnv, paths: WorkspacePaths<'_>) -> [SecureLayer; 2] {
    let root = env.root_config_dir();
    [
        SecureLayer::repo_at(paths.repo_path.to_owned(), root.as_ref().map(|r| r.join("repos"))),
        SecureLayer {
            source: ConfigSource::Workspace,
            dir: paths.workspace_root.join(".jj"),
            id_file_name: "workspace-config-id",
            legacy_file_name: "workspace-config.toml",
            root_config_dir: root.as_ref().map(|r| r.join("workspaces")),
            new_secure: SecureConfig::new_workspace,
        },
    ]
}

/// Builds the resolved layer stack from an explicit environment, in the CLI's order
/// (`cli/src/config.rs:713-730` @ v0.44.0): Default → System → `EnvBase` → User → Repo →
/// Workspace → `EnvOverrides`.
///
/// `workspace` is `None` outside any workspace (a config verb run without a repo, Story
/// 9.28): the stack stops at the user level and resolves with no repo/workspace path — the
/// state the CLI is in without a workspace. A CREATION path passes the new workspace's paths
/// ([`user_settings_for_new_workspace`]).
fn load_with(env: &ConfigEnv, workspace: Option<WorkspacePaths<'_>>) -> Result<StackedConfig, ConfigError> {
    resolve_raw(env, workspace, &load_raw(env, workspace)?, None)
}

/// The UNRESOLVED ("raw") stack [`load_with`] resolves — one layer per file, `--when` /
/// `[[--scope]]` blocks still in place: the CLI's `RawConfig`. Side-effect-free.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a file is unreadable or not valid TOML, or a `config-id` is
///   malformed; the path is named.
pub(crate) fn load_raw(env: &ConfigEnv, workspace: Option<WorkspacePaths<'_>>) -> Result<StackedConfig, ConfigError> {
    let mut config = StackedConfig::with_defaults();
    let builtin = ConfigLayer::parse(ConfigSource::Default, BUILTIN_CONFIG_TOML)
        .map_err(|e| ConfigError::Load { reason: describe(&e) })?;
    config.add_layer(builtin);

    add_path_layers(
        &mut config,
        ConfigSource::System,
        &system_config_paths(env.system_config_dir.as_deref(), env.jj_config.as_deref()),
    )?;
    config.add_layer(env_base_layer(env)?);
    add_path_layers(&mut config, ConfigSource::User, &env_user_config_paths(env))?;
    for layer in workspace.map(|paths| secure_layers(env, paths)).into_iter().flatten() {
        add_secure_layer(
            &mut config,
            layer.source,
            &layer.dir,
            layer.id_file_name,
            layer.legacy_file_name,
            layer.root_config_dir.as_deref(),
        )?;
    }
    config.add_layer(env_overrides_layer(env)?);
    Ok(config)
}

/// Flattens `--when` / `[[--scope]]` blocks of a [`load_raw`] stack — the CLI's
/// `resolve_config` (`cli/src/config.rs:669-679` @ v0.44.0). Skipping this would leave scoped
/// tables unflattened (their values silently missing) and keep layers the CLI drops.
///
/// `command` is the CLI's command name (`"config set"`, …) for `--when.commands`; every verb
/// but the config verbs (Story 9.28) passes `None`, a state the CLI itself produces before a
/// subcommand is known.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a `--when` condition has the wrong type.
pub(crate) fn resolve_raw(
    env: &ConfigEnv,
    workspace: Option<WorkspacePaths<'_>>,
    raw: &StackedConfig,
    command: Option<&str>,
) -> Result<StackedConfig, ConfigError> {
    let context = ConfigResolutionContext {
        home_dir: env.home_dir.as_deref(),
        repo_path: workspace.map(|paths| paths.repo_path),
        workspace_path: workspace.map(|paths| paths.workspace_root),
        command,
        hostname: env.hostname.as_deref().unwrap_or(""),
        environment: &env.environment,
    };
    resolve(raw, &context).map_err(|e| value_error(&e))
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

/// Turns a resolved stack into the `UserSettings` jj-lib signs commits and operations with.
///
/// `UserSettings::from_config` reads `user.*`, `operation.*`, `debug.*` and `signing.*`
/// eagerly, so a wrong-typed value there refuses HERE — naming the key — exactly where the
/// CLI fails at start-up.
pub(crate) fn settings_from(config: StackedConfig) -> Result<UserSettings, ConfigError> {
    UserSettings::from_config(config).map_err(|e| value_error(&e))
}

/// The `UserSettings` an EXISTING workspace is opened with: its full effective stack.
///
/// Takes the loader, not a `Workspace`, because the settings must exist BEFORE the workspace
/// is loaded — this is `Workspace::load`'s own body split in two (`workspace.rs:410-419`), and
/// `loader.repo_path()` has already followed a secondary workspace's `.jj/repo` FILE.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a stack file is unreadable or not valid TOML, a `config-id` is
///   malformed, or a value has the wrong type; the path or key is named.
pub(crate) fn user_settings_for(loader: &dyn WorkspaceLoader) -> Result<UserSettings, ConfigError> {
    let paths = WorkspacePaths {
        repo_path: loader.repo_path(),
        workspace_root: loader.workspace_root(),
    };
    settings_from(load_with(&ConfigEnv::from_env(), Some(paths))?)
}

/// The `UserSettings` the workspace at `workspace_root` is CREATED with (`init`, `clone`,
/// conversions) — the CLI's `settings_for_new_workspace` (`cli/src/cli_util.rs:372-388` @
/// v0.44.0): the stack is built for the NEW workspace's paths (`<root>/.jj/repo`, `<root>`),
/// so `--when.repositories` / `--when.workspaces` scopes (a per-directory identity) already
/// apply to what the creation writes. No repo or workspace config file exists yet, so those
/// two layers find nothing — exactly as the CLI's reload finds nothing there.
///
/// # Errors
///
/// - [`ConfigError::Load`] — as [`user_settings_for`].
pub(crate) fn user_settings_for_new_workspace(workspace_root: &Path) -> Result<UserSettings, ConfigError> {
    let paths = WorkspacePaths {
        repo_path: &workspace_root.join(".jj").join("repo"),
        workspace_root,
    };
    settings_from(load_with(&ConfigEnv::from_env(), Some(paths))?)
}

/// The first `ConfigGetError` down `err`'s `source()` chain, as a [`ConfigError`].
///
/// jj-lib reads several keys itself from the settings a workspace is loaded or created with —
/// the working copy's `ui.conflict-marker-style`, `working-copy.*` and `fsmonitor.*`
/// (`TreeStateSettings::try_from_user_settings`) among them — and keeps a wrong-typed value's
/// `ConfigGetError` as a `#[source]` behind its own error.
fn config_get_error(err: &(dyn std::error::Error + 'static)) -> Option<ConfigError> {
    std::iter::successors(Some(err), |e| e.source())
        .find_map(|e| e.downcast_ref::<ConfigGetError>())
        .map(value_error)
}

/// The config fault behind a failed workspace LOAD, if that is what it was.
///
/// A wrong-typed value in any layer of the stack fails the load exactly where the CLI fails
/// too, because jj-lib reads it from the settings the workspace is loaded WITH. Most readers
/// keep the `ConfigGetError` in the source chain ([`config_get_error`]); the git backend
/// (`GitSettings::from_settings`: `git.abandon-unreachable-commits` and its siblings) wraps
/// it TRANSPARENTLY (`StoreLoadError::Backend` → `BackendLoadError` →
/// `GitBackendLoadError::Config`), which hides it from the chain, so that one is dug out by
/// type. Either way the result is the same `ConfigError` — naming the key — as a fault
/// [`settings_from`] catches.
pub(crate) fn load_config_fault(err: &WorkspaceLoadError) -> Option<ConfigError> {
    let git = match err {
        WorkspaceLoadError::StoreLoadError(StoreLoadError::Backend(BackendLoadError(inner))) => {
            match inner.downcast_ref::<GitBackendLoadError>() {
                Some(GitBackendLoadError::Config(e)) => Some(e),
                _ => None,
            }
        }
        _ => None,
    };
    git.map(value_error).or_else(|| config_get_error(err))
}

/// The config fault behind a failed workspace CREATION, if that is what it was — the
/// creation-side twin of [`load_config_fault`]: every `GitBackend::init_*` reads the same
/// `git.*` keys, transparently wrapped as `GitBackendInitError::Config`.
pub(crate) fn init_config_fault(err: &WorkspaceInitError) -> Option<ConfigError> {
    let git = match err {
        WorkspaceInitError::Backend(BackendInitError(inner)) => match inner.downcast_ref::<GitBackendInitError>() {
            Some(GitBackendInitError::Config(e)) => Some(e),
            _ => None,
        },
        _ => None,
    };
    git.map(value_error).or_else(|| config_get_error(err))
}

/// The effective `user.email` of a loaded stack — the `mine()` revset's input.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a string.
pub(crate) fn user_email(config: &StackedConfig) -> Result<String, ConfigError> {
    config.get("user.email").map_err(|e| value_error(&e))
}

// ── Stack fingerprint ─────────────────────────────────────────────────────────────

/// One file of the stack as the fingerprint sees it: its path, and — when it exists — its
/// modification time and length.
#[derive(Debug, Clone, PartialEq, Eq)]
struct FileStamp {
    path: PathBuf,
    meta: Option<(Option<SystemTime>, u64)>,
}

fn stamp(path: &Path) -> FileStamp {
    FileStamp {
        path: path.to_owned(),
        meta: std::fs::metadata(path).ok().map(|m| (m.modified().ok(), m.len())),
    }
}

/// Stamps one system/user candidate: the path itself, plus — for a directory — every `*.toml`
/// entry `load_dir` would read. A directory's own mtime changes when an entry is added or
/// removed, but NOT when an entry is edited, so the entries are stamped individually.
fn stamp_candidate(path: &Path, out: &mut Vec<FileStamp>) {
    out.push(stamp(path));
    let mut entries: Vec<PathBuf> = std::fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|p| p.extension() == Some(OsStr::new("toml")))
        .collect();
    entries.sort_unstable();
    out.extend(entries.iter().map(|p| stamp(p)));
}

/// What the effective stack of one workspace was derived from.
///
/// Equal fingerprints mean the stack cannot have changed: every file it reads or could read
/// (existing or not) with its mtime and length, the id files that select the secure layers,
/// and the environment inputs — the whole environment (it feeds both env layers and
/// `--when.environments` scopes) plus the `whoami` values. Cheap: a handful of `stat`s.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StackFingerprint {
    files: Vec<FileStamp>,
    environment: HashMap<String, String>,
    hostname: Option<String>,
    username: Option<String>,
}

/// [`stack_fingerprint`] over an explicit environment.
fn fingerprint_with(env: &ConfigEnv, paths: WorkspacePaths<'_>) -> Result<StackFingerprint, ConfigError> {
    let mut files = Vec::new();
    let system = system_config_paths(env.system_config_dir.as_deref(), env.jj_config.as_deref());
    for path in system.iter().chain(&env_user_config_paths(env)) {
        stamp_candidate(path, &mut files);
    }
    for layer in secure_layers(env, paths) {
        files.push(stamp(&layer.dir.join(layer.id_file_name)));
        let resolved = secure_config_path(
            &layer.dir,
            layer.id_file_name,
            layer.legacy_file_name,
            layer.root_config_dir.as_deref(),
        )?;
        files.extend(resolved.as_deref().map(stamp));
    }
    Ok(StackFingerprint {
        files,
        environment: env.environment.clone(),
        hostname: env.hostname.clone(),
        username: env.username.clone(),
    })
}

/// Fingerprints the effective stack of the workspace at `workspace_root` (whose repo lives at
/// `repo_path`) — [`crate::Repo`]'s trigger to re-derive its settings.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a `config-id` is malformed or unreadable, the same fault the
///   stack itself would refuse with.
pub(crate) fn stack_fingerprint(repo_path: &Path, workspace_root: &Path) -> Result<StackFingerprint, ConfigError> {
    fingerprint_with(
        &ConfigEnv::from_env(),
        WorkspacePaths {
            repo_path,
            workspace_root,
        },
    )
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
    let paths = WorkspacePaths {
        repo_path: workspace.repo_path(),
        workspace_root: workspace.workspace_root(),
    };
    load_with(&ConfigEnv::from_env(), Some(paths))
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
/// The CLI builds those two from `jj_lib::git::GitSettings::from_settings` (jj-lib
/// `git.rs:107-115` @ 0.44.0), which also type-checks `git.executable-path` (a path) and
/// `git.write-change-id-header` (a boolean); both are read here too, their values discarded,
/// so a wrong-typed one fails every import site exactly as it fails the CLI's. Both have
/// jj-lib `config/misc.toml` defaults, so an unset key reads fine.
///
/// `remote_auto_track_bookmarks` is the CLI's `parse_remote_auto_track_bookmarks_map`
/// (`cli/src/revset_util.rs:378-391,457-470` @ v0.44.0): one string-expression matcher per
/// `remotes.<name>.auto-track-bookmarks` (Story 9.26), so every import site — fetch, import,
/// clone, convert and the pre-verb snapshot — auto-tracks exactly what the user's CLI does.
///
/// Returns a `jj_lib` type, which is why it is `pub(crate)` (FR-JJ-16).
///
/// # Errors
///
/// - [`ConfigError::Load`] — any of the four `git.*` keys above is present with a value of the
///   wrong type, or is missing from every layer (impossible while jj-lib's own defaults layer
///   is present); a `remotes.<name>` entry is not a table of the known string keys; or an
///   `auto-track-bookmarks` value does not parse (the CLI's
///   ``Invalid `remotes.<name>.auto-track-bookmarks`: …``).
pub(crate) fn git_import_options(config: &StackedConfig) -> Result<jj_lib::git::GitImportOptions, ConfigError> {
    // WHY read and discard: `GitSettings::from_settings` (jj-lib `git.rs:107-115` @ 0.44.0)
    // reads all four `git.*` keys before the CLI builds its import options, so a wrong-typed
    // `executable-path` / `write-change-id-header` fails the CLI's import too.
    let _executable_path: std::path::PathBuf = config.get("git.executable-path").map_err(|e| value_error(&e))?;
    let _write_change_id_header: bool = config.get("git.write-change-id-header").map_err(|e| value_error(&e))?;
    Ok(jj_lib::git::GitImportOptions {
        abandon_unreachable_commits: config
            .get("git.abandon-unreachable-commits")
            .map_err(|e| value_error(&e))?,
        record_synthetic_predecessors: config
            .get("git.record-synthetic-predecessors")
            .map_err(|e| value_error(&e))?,
        remote_auto_track_bookmarks: remote_auto_track_bookmarks(config)?,
    })
}

/// The CLI's `parse_remote_auto_track_bookmarks_map` over the effective `[remotes]` table —
/// jj-lib's `RemoteSettings::table_from_settings` read off the stack directly, then each
/// `auto-track-bookmarks` parsed as a string expression and turned into its matcher.
fn remote_auto_track_bookmarks(
    config: &StackedConfig,
) -> Result<HashMap<jj_lib::ref_name::RemoteNameBuf, jj_lib::str_util::StringMatcher>, ConfigError> {
    let mut matchers = HashMap::new();
    let names: Vec<String> = config.table_keys("remotes").map(str::to_owned).collect();
    for name in names {
        let settings: jj_lib::settings::RemoteSettings =
            config.get(["remotes", name.as_str()]).map_err(|e| value_error(&e))?;
        let Some(text) = settings.auto_track_bookmarks else {
            continue;
        };
        let remote: jj_lib::ref_name::RemoteNameBuf = name.as_str().into();
        let expression = jj_lib::revset::parse_string_expression(&mut jj_lib::revset::RevsetDiagnostics::new(), &text)
            .map_err(|e| ConfigError::Load {
                reason: format!(
                    "Invalid `remotes.{}.auto-track-bookmarks`: {}",
                    remote.as_symbol(),
                    e.kind()
                ),
            })?;
        matchers.insert(remote, expression.to_matcher());
    }
    Ok(matchers)
}

/// Reads the effective `snapshot.auto-update-stale` (Story 9.26) — the CLI's
/// `settings().get_bool("snapshot.auto-update-stale")` (`cli/src/cli_util.rs:499` @ v0.44.0),
/// whose default `false` is [`BUILTIN_CONFIG_TOML`]'s (the CLI's `config/misc.toml`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a boolean (the key is named), or is missing from
///   every layer (impossible while the builtin layer is present).
pub(crate) fn snapshot_auto_update_stale(config: &StackedConfig) -> Result<bool, ConfigError> {
    config.get("snapshot.auto-update-stale").map_err(|e| value_error(&e))
}

/// Reads the effective `snapshot.max-new-file-size` out of a loaded stack (Story 9.22).
///
/// Mirrors `snapshot_options_with_start_tracking_matcher` (`cli/src/cli_util.rs:1618-1623` @
/// v0.44.0): the value is a `HumanByteSize` — a plain integer or a `"<number><unit>"` string —
/// and `0` means UNLIMITED (`u64::MAX`), which is how a user switches the size gate off.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is neither a non-negative integer nor a parseable size
///   string (the key is named), or is missing from every layer (impossible while the builtin
///   layer is present).
pub(crate) fn snapshot_max_new_file_size(config: &StackedConfig) -> Result<u64, ConfigError> {
    let jj_lib::settings::HumanByteSize(size) = config
        .get_value_with("snapshot.max-new-file-size", jj_lib::settings::HumanByteSize::try_from)
        .map_err(|e| value_error(&e))?;
    Ok(if size == 0 { u64::MAX } else { size })
}

/// Reads the effective `snapshot.auto-track` fileset TEXT out of a loaded stack (Story 9.22) —
/// the CLI's `settings().get_string("snapshot.auto-track")` (`cli/src/cli_util.rs:1606`).
/// Parsing it is the caller's job; a parse failure is a config fault there too.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a string (the key is named), or is missing from
///   every layer (impossible while the builtin layer is present).
pub(crate) fn snapshot_auto_track(config: &StackedConfig) -> Result<String, ConfigError> {
    config.get("snapshot.auto-track").map_err(|e| value_error(&e))
}

// ── The three repo-config WRITERS ─────────────────────────────────────────────────
//
// `remove_remote_from_repo_config` / `rename_remote_in_repo_config` are ported verbatim from
// `cli/src/commands/git/mod.rs:195-262` @ v0.44.0 and `set_trunk_alias` from that file's
// `write_repo_presets` (`:156-193`), each minus its `ui.status` line (terminal UX — Zanshin
// replaces it; NFR-R-2). The effect those lines announce IS ported: Ralph's rule
// (2026-09-06) is that every on-disk, repo-side effect the CLI produces is required parity.
//
// The two remote writers resolve their file through `existing_repo_config_file` and can
// never create one; `set_trunk_alias` is paired with `new_repo_config_file`, which CREATES.
// See the module doc for why that asymmetry is the CLI's, not an oversight.

/// A failure while WRITING the repo config, rendered through its `source()` chain.
///
/// One generic function rather than a closure per call site. Two of the instantiations are
/// unreachable by construction — `set_value`/`delete_value` only fail when the target is a
/// non-inline TABLE, which the two remote writers have already ruled out with `as_str()`,
/// and `getrandom::fill` only fails when the OS RNG is unavailable — so a per-call-site
/// closure would add lines no test can execute. Sharing one body means the reachable
/// instantiations ([`jj_lib::config::ConfigFileSaveError`] via the unwritable-file tests,
/// [`jj_lib::secure_config::SecureConfigError`] via the uncreatable-root test) cover the
/// same lines the unreachable ones would.
fn write_error<E: std::error::Error + 'static>(err: E) -> ConfigError {
    ConfigError::Load { reason: describe(&err) }
}

/// Loads the config file at `path` for editing — `ConfigFile::load_or_empty`: an absent file is
/// an empty document (jj-lib's schema header), never an error. The ONE load every writer of the
/// family uses (the three below and the Story 9.28 config verbs).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the file exists but could not be read or is not valid TOML; the
///   path is named.
pub(crate) fn load_config_file(source: ConfigSource, path: &Path) -> Result<ConfigFile, ConfigError> {
    ConfigFile::load_or_empty(source, path).map_err(|e| file_error(path, &e))
}

/// Writes `file` back — `ConfigFile::save`, a `toml_edit` round trip that keeps comments and
/// formatting. The ONE save every writer of the family uses.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the file could not be written; the io reason names it.
pub(crate) fn save_config_file(file: &ConfigFile) -> Result<(), ConfigError> {
    file.save().map_err(write_error)
}

/// Loads the repo-level config file at `path`, iff `path` is `Some` AND exists on disk.
///
/// The `.exists()` filter and the load are ONE step on purpose. `ConfigFile::load_or_empty`
/// answers a missing file with an empty document, and both writers below `save()`
/// unconditionally — so resolving a path and only loading it later, at save time, would
/// turn a file that vanished in between into a file this crate CREATED, which is exactly
/// what the ported helpers must never do.
///
/// Split from [`existing_repo_config_file`] so the writers can be unit-tested against a
/// tempfile path without standing up a [`Workspace`].
///
/// # Errors
///
/// - [`ConfigError::Load`] — the file exists but could not be read or is not valid TOML.
fn load_repo_config_file(path: Option<&Path>) -> Result<Option<ConfigFile>, ConfigError> {
    let Some(path) = path.filter(|p| p.exists()) else {
        return Ok(None);
    };
    Ok(Some(load_config_file(ConfigSource::Repo, path)?))
}

/// The repo-level config file this workspace READS, loaded, if it exists on disk.
///
/// Resolution is [`secure_config_path`] — the very same call [`add_secure_layer`] makes for
/// `ConfigSource::Repo` — so a writer built on this file can never rewrite a file the
/// session does not read. That includes the `Ok(None)` case where no `<config_dir>` can be
/// determined at all (no `$HOME`, no absolute `$XDG_CONFIG_HOME`): the whole rewrite then
/// vanishes silently — and it must, because [`add_secure_layer`] skips the repo LAYER under
/// exactly the same condition, so read and write stay consistent by construction.
///
/// This mirrors the CLI's `existing_repo_config_file` (`cli/src/config.rs:682-691`), which
/// wraps an ALREADY-LOADED repo layer and yields nothing when no file was loaded. Loading
/// here rather than inside the writer is what reproduces the CLI's ORDERING: its layer was
/// parsed at process start, so an unreadable or unparseable repo config makes it fail before
/// `git::remove_remote` writes anything. Callers therefore call this BEFORE they open their
/// transaction, and only a `save()` failure can still abort one.
///
/// # Errors
///
/// - [`ConfigError::Load`] — `.jj/repo/config-id` exists but is not exactly 20 ASCII hex
///   characters or could not be read; or the config file itself is unreadable or not valid
///   TOML.
pub(crate) fn existing_repo_config_file(workspace: &Workspace) -> Result<Option<ConfigFile>, ConfigError> {
    let root = ConfigEnv::from_env().root_config_dir();
    // `repo_path()` is jj-lib's already-resolved `.jj/repo` — see `load_for_workspace`.
    let path = SecureLayer::repo_at(workspace.repo_path().to_owned(), root.map(|r| r.join("repos"))).resolved_path()?;
    load_repo_config_file(path.as_deref())
}

/// The repo-level config file, CREATING it (and its `config-id`) when none exists yet.
///
/// The create-mode counterpart of [`load_repo_config_file`], resolved through the family's one
/// create-mode resolver, [`SecureLayer::create_path`] — which the Story 9.28 config verbs use
/// for the repo AND the workspace layer. `repo_dir` is `.jj/repo`; `root_config_dir` is
/// `<config_dir>/jj/repos`, the very directory [`secure_config_path`] joins the id onto, so
/// the file this creates is the file every later READ resolves. `None` for the root — no
/// `$HOME` and no absolute `$XDG_CONFIG_HOME` — yields `Ok(None)` and writes nothing at all,
/// which is both the CLI's "we couldn't find the user's home directory, so we skip this step"
/// branch in `write_repo_presets` and the condition under which [`add_secure_layer`] skips
/// the repo layer. Read and write therefore stay consistent even on such a machine.
///
/// `SecureConfig::load_config` does the whole CLI-side layout: it generates the id, creates
/// `<root>/<id>/`, writes `metadata.binpb`, and writes `.jj/repo/config-id` atomically; the RNG
/// is seeded as [`SecureLayer::create_path`] describes.
///
/// Split from [`new_repo_config_file`] so it can be unit-tested against plain temp dirs
/// without standing up a [`Workspace`], exactly as [`load_repo_config_file`] is.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the OS RNG failed, the secure-config directory could not be
///   created or written, or an already-present config file is unreadable / not valid TOML.
fn create_repo_config_file(
    repo_dir: &Path,
    root_config_dir: Option<&Path>,
    randomness_seed: Option<u64>,
) -> Result<Option<ConfigFile>, ConfigError> {
    // `load_config` generates the file when none exists, so the path is `Some` whenever a root
    // is known. Mapping rather than matching — the shape the CLI's own `new_repo_config_file`
    // uses — keeps the impossible `None` from becoming a branch no test could execute.
    SecureLayer::repo_at(repo_dir.to_owned(), root_config_dir.map(Path::to_owned))
        .create_path(randomness_seed)?
        .map(|path| load_config_file(ConfigSource::Repo, &path))
        .transpose()
}

/// The repo-level config file of `workspace`, created if it does not exist.
///
/// The create-mode sibling of [`existing_repo_config_file`], resolving through the same
/// `<config_dir>/jj/repos` root. Mirrors the CLI's `new_repo_config_file`
/// (`cli/src/config.rs:573-579` @ v0.44.0), which likewise pairs the create-forcing
/// `repo_config_path` with `ConfigFile::load_or_empty`.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the secure-config directory could not be created or written, or
///   an already-present config file is unreadable or not valid TOML.
pub(crate) fn new_repo_config_file(workspace: &Workspace) -> Result<Option<ConfigFile>, ConfigError> {
    let env = ConfigEnv::from_env();
    let root = env.root_config_dir();
    create_repo_config_file(
        // `repo_path()` is jj-lib's already-resolved `.jj/repo` — see `load_for_workspace`.
        workspace.repo_path(),
        root.as_ref().map(|r| r.join("repos")).as_deref(),
        env.randomness_seed(),
    )
}

/// Writes `revset-aliases.'trunk()' = <symbol>` — the one preset `jj git init` sets.
///
/// The `trunk` half of the CLI's `write_repo_presets`; its `fetch-bookmarks` / `fetch-tags`
/// halves belong to `jj git clone` (Story 9.20) and are deliberately absent, as is its
/// `is_default()` early return, which only matters when all three presets are `None` — a
/// state this single-preset entry point cannot be in.
///
/// `file` is [`new_repo_config_file`]'s answer: `None` means no `<config_dir>` could be
/// determined, and then this is a no-op that creates nothing.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the file could not be written back.
pub(crate) fn set_trunk_alias(file: Option<ConfigFile>, symbol: &str) -> Result<(), ConfigError> {
    let Some(mut file) = file else {
        return Ok(());
    };
    file.set_value(TRUNK_CONFIG_NAME, symbol).map_err(write_error)?;
    save_config_file(&file)
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
/// is DELETED when it is a plain remote symbol naming `remote`. Both are keyed on the
/// REMOTE name alone — the alias's bookmark half is never compared, because the alias
/// becomes meaningless the moment its remote is gone, whatever bookmark it named.
///
/// Deleting the alias makes the REPO layer stop defining `trunk()`; what then applies is
/// whatever the remaining stack resolves to — the builtin, unless the workspace or user
/// layer defines a `trunk()` of its own, which still wins. Only the repo layer is written,
/// exactly as in the CLI.
///
/// `file` is [`existing_repo_config_file`]'s answer: `None` means no repo-level config file
/// exists, and then this is a no-op that creates nothing.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the file could not be written back.
pub(crate) fn remove_remote_from_repo_config(file: Option<ConfigFile>, remote: &str) -> Result<(), ConfigError> {
    let Some(mut file) = file else {
        return Ok(());
    };

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
    save_config_file(&file)
}

/// Re-points `old`'s repo-config presets at `new` — the CLI's
/// `rename_remote_in_repo_config`.
///
/// The mirror image of [`remove_remote_from_repo_config`]: `[remotes.<old>]` is re-inserted
/// as `[remotes.<new>]` (value untouched), and a plain-remote-symbol `trunk()` naming `old`
/// is REWRITTEN to name `new`, keeping its bookmark. Same remote-name-only keying, same
/// hands-off treatment of any richer expression, same repo-layer-only reach.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the file could not be written back.
pub(crate) fn rename_remote_in_repo_config(file: Option<ConfigFile>, old: &str, new: &str) -> Result<(), ConfigError> {
    let Some(mut file) = file else {
        return Ok(());
    };

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

    save_config_file(&file)
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use super::{
        add_secure_layer, create_repo_config_file, env_base_layer, env_overrides_layer, fingerprint_with,
        git_import_options, is_valid_config_id, load_repo_config_file, load_with, platform_config_dir,
        remove_remote_from_repo_config, rename_remote_in_repo_config, secure_config_path, set_trunk_alias,
        settings_from, snapshot_auto_track, snapshot_max_new_file_size, stamp, system_config_paths, user_config_paths,
        user_email, ConfigEnv, SecureLayer, WorkspacePaths, BUILTIN_CONFIG_TOML,
    };
    use jj_lib::config::{ConfigFile, ConfigLayer, ConfigSource, StackedConfig};
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};

    /// A snapshot with NOTHING in it: no config dir, no home, `JJ_CONFIG=""` (user discovery
    /// and the system layer both off — exactly as the suite pins it), an empty environment and
    /// no `whoami` values. Tests switch on only what they exercise.
    fn bare_env() -> ConfigEnv {
        ConfigEnv {
            config_dir: None,
            home_dir: None,
            jj_config: Some(OsString::new()),
            environment: HashMap::new(),
            system_config_dir: None,
            hostname: None,
            username: None,
        }
    }

    fn env_with(vars: &[(&str, &str)]) -> ConfigEnv {
        ConfigEnv {
            environment: vars.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
            ..bare_env()
        }
    }

    fn paths<'a>(repo_path: &'a Path, workspace_root: &'a Path) -> WorkspacePaths<'a> {
        WorkspacePaths {
            repo_path,
            workspace_root,
        }
    }

    /// The string value of `name` in a single layer, if any.
    fn layer_str(layer: &ConfigLayer, name: &'static str) -> Option<String> {
        layer
            .look_up_item(name)
            .ok()
            .flatten()
            .and_then(|item| item.as_str().map(ToOwned::to_owned))
    }

    #[test]
    fn builtin_config_layer_is_valid_toml() {
        let layer = ConfigLayer::parse(ConfigSource::Default, BUILTIN_CONFIG_TOML);
        assert!(layer.is_ok(), "the builtin layer must parse: {layer:?}");
    }

    // ── snapshot.* readers (Story 9.22) ───────────────────────────────────────

    /// The builtin stack with `toml` layered on top as the user layer.
    fn stack_with(toml: &str) -> StackedConfig {
        let mut config = load_with(&bare_env(), None).expect("the bare stack loads");
        config.add_layer(ConfigLayer::parse(ConfigSource::User, toml).expect("valid test TOML"));
        config
    }

    #[test]
    fn snapshot_knobs_default_to_the_cli_builtins() {
        let config = load_with(&bare_env(), None).expect("the bare stack loads");
        assert_eq!(snapshot_max_new_file_size(&config).expect("builtin size"), 1024 * 1024);
        assert_eq!(snapshot_auto_track(&config).expect("builtin fileset"), "all()");
    }

    #[test]
    fn snapshot_max_new_file_size_reads_integers_and_unit_strings() {
        let plain = stack_with("snapshot.max-new-file-size = 10");
        assert_eq!(snapshot_max_new_file_size(&plain).expect("an integer"), 10);
        let unit = stack_with("snapshot.max-new-file-size = \"2KiB\"");
        assert_eq!(snapshot_max_new_file_size(&unit).expect("a unit string"), 2048);
    }

    /// `0` is the CLI's "no limit" (`cli_util.rs:1621-1623`), not "refuse every new file".
    #[test]
    fn snapshot_max_new_file_size_zero_means_unlimited() {
        let config = stack_with("snapshot.max-new-file-size = 0");
        assert_eq!(snapshot_max_new_file_size(&config).expect("zero"), u64::MAX);
    }

    #[test]
    fn wrong_typed_snapshot_knobs_refuse_naming_the_key() {
        let size = stack_with("snapshot.max-new-file-size = \"lots\"");
        let super::ConfigError::Load { reason } = snapshot_max_new_file_size(&size).expect_err("not a size");
        assert!(reason.contains("snapshot.max-new-file-size"), "{reason}");
        let track = stack_with("snapshot.auto-track = 1");
        let super::ConfigError::Load { reason } = snapshot_auto_track(&track).expect_err("not a string");
        assert!(reason.contains("snapshot.auto-track"), "{reason}");
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

    /// The CLI's `resolve_user` list (Story 9.28): `~/.jjconfig.toml` only when it exists or no
    /// config dir is known, the platform file always, `conf.d` only when it exists; `JJ_CONFIG`
    /// entries as given. The existing-file expansion follows `load_dir`'s rule.
    #[test]
    fn user_config_candidates_and_edit_candidates_follow_the_cli() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let cfg = tmp.path().join("cfg");
        let env = ConfigEnv {
            config_dir: Some(cfg.clone()),
            home_dir: Some(home.clone()),
            jj_config: None,
            ..bare_env()
        };
        let platform = cfg.join("jj").join("config.toml");
        assert_eq!(super::user_config_candidates(&env), std::slice::from_ref(&platform));
        assert!(super::user_edit_candidates(&env).is_empty());

        std::fs::create_dir_all(cfg.join("jj").join("conf.d").join("sub.toml")).unwrap();
        std::fs::write(cfg.join("jj").join("conf.d").join("b.toml"), "").unwrap();
        std::fs::write(cfg.join("jj").join("conf.d").join("a.toml"), "").unwrap();
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(home.join(".jjconfig.toml"), "").unwrap();
        let conf_d = cfg.join("jj").join("conf.d");
        assert_eq!(
            super::user_config_candidates(&env),
            [home.join(".jjconfig.toml"), platform, conf_d.clone()]
        );
        assert_eq!(
            super::user_edit_candidates(&env),
            [
                home.join(".jjconfig.toml"),
                conf_d.join("a.toml"),
                conf_d.join("b.toml")
            ],
            "a directory named *.toml is not a file"
        );

        let no_cfg = ConfigEnv {
            config_dir: None,
            home_dir: Some(tmp.path().join("nohome")),
            jj_config: None,
            ..bare_env()
        };
        assert_eq!(
            super::user_config_candidates(&no_cfg),
            [tmp.path().join("nohome").join(".jjconfig.toml")],
            "without a config dir the home file is listed even when absent"
        );
        let pinned = ConfigEnv {
            jj_config: Some(OsString::from("/a.toml:/b")),
            ..bare_env()
        };
        assert_eq!(
            super::user_config_candidates(&pinned),
            [PathBuf::from("/a.toml"), PathBuf::from("/b")]
        );
    }

    #[test]
    fn create_private_dir_all_creates_0700_dirs() {
        use std::os::unix::fs::PermissionsExt as _;
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("a").join("b");
        super::create_private_dir_all(&dir).unwrap();
        for d in [tmp.path().join("a"), dir] {
            assert_eq!(std::fs::metadata(d).unwrap().permissions().mode() & 0o777, 0o700);
        }
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

    /// A copied repo's layer sees ANOTHER existing dir recorded; its own dir, a moved (gone)
    /// original and a dir without metadata do not count.
    #[test]
    fn records_another_dir_spots_only_a_copy() {
        let tmp = tempfile::tempdir().unwrap();
        let (original, copy) = (tmp.path().join("a"), tmp.path().join("b"));
        std::fs::create_dir(&original).unwrap();
        std::fs::create_dir(&copy).unwrap();
        let root = tmp.path().join("repos");
        let layer = |dir: &Path| SecureLayer::repo_at(dir.to_owned(), Some(root.clone()));
        let file = layer(&original).create_path(Some(7)).unwrap().expect("created");

        assert!(!layer(&original).records_another_dir(&file), "its own record");
        assert!(
            layer(&copy).records_another_dir(&file),
            "a copy of an existing original"
        );
        assert!(
            !layer(&copy).records_another_dir(&tmp.path().join("nowhere").join("config.toml")),
            "no metadata"
        );
        std::fs::remove_dir_all(&original).unwrap();
        assert!(!layer(&copy).records_another_dir(&file), "a moved original");
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
            ..bare_env()
        };
        let config = load_with(&env, Some(paths(&repo_path, repo_root.path()))).expect("the stack must load");

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

    // ── System + environment layers (Story 9.27) ──────────────────────────────

    #[test]
    fn system_config_paths_are_the_clis_and_only_without_jj_config() {
        assert_eq!(
            system_config_paths(Some(Path::new("/etc")), None),
            vec![PathBuf::from("/etc/jj/config.toml"), PathBuf::from("/etc/jj/conf.d")]
        );
        assert!(
            system_config_paths(Some(Path::new("/etc")), Some(&OsString::new())).is_empty(),
            "JJ_CONFIG — even empty — turns the system layer off, as in the CLI"
        );
        assert!(system_config_paths(None, None).is_empty());
    }

    /// System file AND `conf.d` both load, and a user file overrides them — the System layer
    /// sits below User.
    #[test]
    fn load_with_reads_the_system_layer_below_the_user_layer() {
        let sys = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(sys.path().join("jj").join("conf.d")).unwrap();
        std::fs::write(sys.path().join("jj").join("config.toml"), "[user]\nname = \"system\"\n").unwrap();
        std::fs::write(
            sys.path().join("jj").join("conf.d").join("a.toml"),
            "[user]\nemail = \"system@example.com\"\n",
        )
        .unwrap();
        std::fs::write(home.path().join(".jjconfig.toml"), "[user]\nname = \"user\"\n").unwrap();

        let env = ConfigEnv {
            jj_config: None,
            home_dir: Some(home.path().to_owned()),
            system_config_dir: Some(sys.path().to_owned()),
            ..bare_env()
        };
        let config = load_with(&env, None).expect("the stack must load");
        assert_eq!(config.get::<String>("user.name").unwrap(), "user", "User beats System");
        assert_eq!(
            config.get::<String>("user.email").unwrap(),
            "system@example.com",
            "conf.d is read like the CLI's load_dir"
        );
    }

    #[test]
    fn a_broken_system_file_is_a_config_error_naming_it() {
        let sys = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(sys.path().join("jj")).unwrap();
        std::fs::write(sys.path().join("jj").join("config.toml"), "not = = toml\n").unwrap();
        let env = ConfigEnv {
            jj_config: None,
            system_config_dir: Some(sys.path().to_owned()),
            ..bare_env()
        };
        let err = load_with(&env, None).expect_err("invalid TOML must refuse");
        assert!(err.to_string().contains("config.toml"), "got: {err}");
    }

    #[test]
    fn env_base_layer_carries_whoami_no_color_and_visual_over_editor() {
        let env = ConfigEnv {
            hostname: Some("box".to_owned()),
            username: Some("alice".to_owned()),
            ..env_with(&[
                ("NO_COLOR", "1"),
                ("VISUAL", "vis"),
                ("EDITOR", "ed"),
                ("PAGER", "less"),
            ])
        };
        let layer = env_base_layer(&env).expect("the layer builds");
        assert_eq!(layer.source, ConfigSource::EnvBase);
        assert_eq!(layer_str(&layer, "operation.hostname").as_deref(), Some("box"));
        assert_eq!(layer_str(&layer, "operation.username").as_deref(), Some("alice"));
        assert_eq!(layer_str(&layer, "ui.color").as_deref(), Some("never"));
        assert_eq!(layer_str(&layer, "ui.editor").as_deref(), Some("vis"), "VISUAL wins");
        assert_eq!(layer_str(&layer, "ui.pager"), None, "$PAGER is deliberately not read");
    }

    #[test]
    fn env_base_layer_ignores_an_empty_no_color_and_falls_back_to_editor() {
        let layer = env_base_layer(&env_with(&[("NO_COLOR", ""), ("EDITOR", "ed")])).expect("the layer builds");
        assert_eq!(layer_str(&layer, "ui.color"), None);
        assert_eq!(layer_str(&layer, "ui.editor").as_deref(), Some("ed"));
        assert_eq!(layer_str(&layer, "operation.hostname"), None, "no whoami value, no key");
        assert!(env_base_layer(&bare_env()).expect("empty builds").is_empty());
    }

    #[test]
    fn env_overrides_layer_maps_every_jj_variable() {
        let env = env_with(&[
            ("JJ_USER", "Jo"),
            ("JJ_EMAIL", "jo@example.com"),
            ("JJ_TIMESTAMP", "2001-02-03T04:05:06+07:00"),
            ("JJ_RANDOMNESS_SEED", "42"),
            ("JJ_OP_TIMESTAMP", "2001-02-03T04:05:07+07:00"),
            ("JJ_OP_HOSTNAME", "host"),
            ("JJ_OP_USERNAME", "op-user"),
            ("JJ_EDITOR", "jj-ed"),
            ("JJ_PAGER", "jj-pager"),
        ]);
        let layer = env_overrides_layer(&env).expect("the layer builds");
        assert_eq!(layer.source, ConfigSource::EnvOverrides);
        for (name, want) in [
            ("user.name", "Jo"),
            ("user.email", "jo@example.com"),
            ("debug.commit-timestamp", "2001-02-03T04:05:06+07:00"),
            ("debug.operation-timestamp", "2001-02-03T04:05:07+07:00"),
            ("operation.hostname", "host"),
            ("operation.username", "op-user"),
            ("ui.editor", "jj-ed"),
            ("ui.pager", "jj-pager"),
        ] {
            assert_eq!(layer_str(&layer, name).as_deref(), Some(want), "{name}");
        }
        let seed = layer
            .look_up_item("debug.randomness-seed")
            .ok()
            .flatten()
            .and_then(jj_lib::config::ConfigItem::as_integer);
        assert_eq!(seed, Some(42), "the seed is an INTEGER, as the CLI writes it");
    }

    #[test]
    fn an_unparseable_randomness_seed_is_dropped_by_both_readers() {
        let env = env_with(&[("JJ_RANDOMNESS_SEED", "not-a-number")]);
        let layer = env_overrides_layer(&env).expect("the layer builds");
        assert!(layer.is_empty());
        assert_eq!(env.randomness_seed(), None);
        assert_eq!(env_with(&[("JJ_RANDOMNESS_SEED", "7")]).randomness_seed(), Some(7));
    }

    /// The whole precedence chain in one stack: `EnvBase` < User < Repo < `EnvOverrides`, and
    /// the repo layer only exists when a workspace is given.
    #[test]
    fn load_with_orders_env_layers_around_the_file_layers() {
        let repo_root = tempfile::tempdir().unwrap();
        let cfg = tempfile::tempdir().unwrap();
        let user_file = cfg.path().join("user.toml");
        let repo_path = repo_root.path().join(".jj").join("repo");
        std::fs::create_dir_all(&repo_path).unwrap();
        std::fs::write(&user_file, "[operation]\nhostname = \"from-user-file\"\n").unwrap();
        // Legacy repo file (no config-id): read through the `<config_dir>` fallback.
        std::fs::write(
            repo_path.join("config.toml"),
            "[user]\nemail = \"repo@example.com\"\nname = \"Repo\"\n",
        )
        .unwrap();

        let env = ConfigEnv {
            config_dir: Some(cfg.path().to_owned()),
            jj_config: Some(user_file.into_os_string()),
            hostname: Some("from-whoami".to_owned()),
            username: Some("whoami-user".to_owned()),
            ..env_with(&[("JJ_EMAIL", "env@example.com")])
        };
        let with_repo = load_with(&env, Some(paths(&repo_path, repo_root.path()))).expect("the stack must load");
        assert_eq!(
            with_repo.get::<String>("operation.hostname").unwrap(),
            "from-user-file",
            "User beats EnvBase"
        );
        assert_eq!(with_repo.get::<String>("operation.username").unwrap(), "whoami-user");
        assert_eq!(
            with_repo.get::<String>("user.name").unwrap(),
            "Repo",
            "the repo layer applies"
        );
        assert_eq!(
            with_repo.get::<String>("user.email").unwrap(),
            "env@example.com",
            "EnvOverrides beat the repo layer"
        );

        let without = load_with(&env, None).expect("the creation stack must load");
        assert_eq!(
            without.get::<String>("user.name").unwrap(),
            "",
            "no workspace, no repo layer"
        );
    }

    #[test]
    fn a_hostnames_scope_matches_the_whoami_hostname() {
        let cfg = tempfile::tempdir().unwrap();
        let user_file = cfg.path().join("user.toml");
        std::fs::write(
            &user_file,
            "[[--scope]]\n--when.hostnames = [\"box\"]\n[--scope.user]\nname = \"scoped\"\n",
        )
        .unwrap();
        let env = |hostname: Option<&str>| ConfigEnv {
            jj_config: Some(user_file.clone().into_os_string()),
            hostname: hostname.map(ToOwned::to_owned),
            ..bare_env()
        };
        let on_box = load_with(&env(Some("box")), None).expect("loads");
        assert_eq!(on_box.get::<String>("user.name").unwrap(), "scoped");
        let unknown = load_with(&env(None), None).expect("loads");
        assert_eq!(
            unknown.get::<String>("user.name").unwrap(),
            "",
            "no hostname resolves as \"\""
        );
    }

    #[test]
    fn a_wrong_typed_identity_refuses_the_settings_naming_the_key() {
        let mut config = StackedConfig::with_defaults();
        config.add_layer(ConfigLayer::parse(ConfigSource::User, "[user]\nname = 1\n").unwrap());
        let err = settings_from(config).expect_err("a non-string user.name must refuse");
        assert!(err.to_string().contains("user.name"), "got: {err}");

        let settings = settings_from(StackedConfig::with_defaults()).expect("jj-lib defaults are valid");
        assert_eq!(
            settings.user_name(),
            "",
            "the empty identity is jj-lib's default, not an error"
        );
    }

    /// Only the git backend's own config read is a config fault; every other load failure —
    /// another variant, another backend error — stays an ordinary load failure.
    #[test]
    fn load_config_fault_digs_out_only_the_git_backends_config_read() {
        use jj_lib::backend::BackendLoadError;
        use jj_lib::config::ConfigGetError;
        use jj_lib::git_backend::GitBackendLoadError;
        use jj_lib::repo::StoreLoadError;
        use jj_lib::working_copy::WorkingCopyStateError;
        use jj_lib::workspace::WorkspaceLoadError;

        let backend = |inner: Box<dyn std::error::Error + Send + Sync>| {
            WorkspaceLoadError::StoreLoadError(StoreLoadError::Backend(BackendLoadError(inner)))
        };
        let config = GitBackendLoadError::Config(ConfigGetError::NotFound {
            name: "git.abandon-unreachable-commits".to_owned(),
        });
        let fault = super::load_config_fault(&backend(Box::new(config))).expect("a config fault");
        assert!(
            fault.to_string().contains("git.abandon-unreachable-commits"),
            "got: {fault}"
        );

        assert!(super::load_config_fault(&backend(Box::new(std::io::Error::other("x")))).is_none());
        assert!(super::load_config_fault(&WorkspaceLoadError::NoWorkspaceHere(PathBuf::from("/x"))).is_none());

        // The working copy keeps its `ConfigGetError` as a `#[source]`: found down the chain.
        let wc = WorkspaceLoadError::WorkingCopyState(WorkingCopyStateError {
            message: "Failed to read the tree state settings".to_owned(),
            err: Box::new(ConfigGetError::NotFound {
                name: "ui.conflict-marker-style".to_owned(),
            }),
        });
        let fault = super::load_config_fault(&wc).expect("a config fault down the chain");
        assert!(fault.to_string().contains("ui.conflict-marker-style"), "got: {fault}");
    }

    #[test]
    fn init_config_fault_digs_out_the_git_backends_and_the_chains_config_reads() {
        use jj_lib::backend::BackendInitError;
        use jj_lib::config::ConfigGetError;
        use jj_lib::git_backend::GitBackendInitError;
        use jj_lib::working_copy::WorkingCopyStateError;
        use jj_lib::workspace::WorkspaceInitError;

        let not_found = |name: &str| ConfigGetError::NotFound { name: name.to_owned() };
        let backend =
            |inner: Box<dyn std::error::Error + Send + Sync>| WorkspaceInitError::Backend(BackendInitError(inner));
        let git = backend(Box::new(GitBackendInitError::Config(not_found("git.x"))));
        assert!(super::init_config_fault(&git)
            .expect("git fault")
            .to_string()
            .contains("git.x"));
        assert!(super::init_config_fault(&backend(Box::new(std::io::Error::other("x")))).is_none());
        assert!(super::init_config_fault(&WorkspaceInitError::DestinationExists(PathBuf::from("/x"))).is_none());

        let wc = WorkspaceInitError::WorkingCopyState(WorkingCopyStateError {
            message: "Failed to read the tree state settings".to_owned(),
            err: Box::new(not_found("working-copy.exec-bit-change")),
        });
        assert!(super::init_config_fault(&wc)
            .expect("a config fault down the chain")
            .to_string()
            .contains("working-copy.exec-bit-change"));
    }

    #[test]
    fn user_email_reads_the_stack_and_refuses_a_wrong_type() {
        assert_eq!(user_email(&StackedConfig::with_defaults()).unwrap(), "");
        let mut config = StackedConfig::with_defaults();
        config.add_layer(ConfigLayer::parse(ConfigSource::User, "[user]\nemail = 1\n").unwrap());
        let err = user_email(&config).expect_err("a non-string user.email must refuse");
        assert!(err.to_string().contains("user.email"), "got: {err}");
    }

    // ── Stack fingerprint ─────────────────────────────────────────────────────

    #[test]
    fn stamp_records_absence_and_presence() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("f.toml");
        assert_eq!(stamp(&path).meta, None);
        std::fs::write(&path, "x").unwrap();
        assert_eq!(stamp(&path).meta.map(|(_, len)| len), Some(1));
    }

    /// Every input the fingerprint is documented to cover changes it: a system `conf.d`
    /// entry edited in place, a user file, the resolved repo file, the id file, the
    /// environment and the `whoami` values. An untouched stack fingerprints equal.
    #[test]
    fn the_fingerprint_changes_with_every_input_of_the_stack() {
        let sys = tempfile::tempdir().unwrap();
        let cfg = tempfile::tempdir().unwrap();
        let repo_root = tempfile::tempdir().unwrap();
        let repo_path = repo_root.path().join(".jj").join("repo");
        std::fs::create_dir_all(&repo_path).unwrap();
        let conf_d = sys.path().join("jj").join("conf.d");
        std::fs::create_dir_all(&conf_d).unwrap();
        std::fs::write(conf_d.join("a.toml"), "").unwrap();
        std::fs::write(conf_d.join("ignored.txt"), "").unwrap();

        let env = ConfigEnv {
            config_dir: Some(cfg.path().to_owned()),
            jj_config: None,
            system_config_dir: Some(sys.path().to_owned()),
            ..bare_env()
        };
        let ws = paths(&repo_path, repo_root.path());
        let base = fingerprint_with(&env, ws).expect("fingerprints");
        assert_eq!(
            base,
            fingerprint_with(&env, ws).expect("fingerprints"),
            "stable when nothing changed"
        );

        let changed = |edit: &dyn Fn()| {
            let before = fingerprint_with(&env, ws).expect("fingerprints");
            edit();
            assert_ne!(before, fingerprint_with(&env, ws).expect("fingerprints"));
        };
        changed(&|| std::fs::write(conf_d.join("a.toml"), "[user]\nname = \"x\"\n").unwrap());
        changed(&|| std::fs::write(conf_d.join("b.toml"), "").unwrap());
        changed(&|| {
            std::fs::create_dir_all(cfg.path().join("jj")).unwrap();
            std::fs::write(cfg.path().join("jj").join("config.toml"), "").unwrap();
        });
        changed(&|| std::fs::write(repo_path.join("config.toml"), "").unwrap());
        changed(&|| std::fs::write(repo_path.join("config-id"), "0123456789abcdef0123").unwrap());

        assert_ne!(base, fingerprint_with(&env_with(&[("JJ_USER", "x")]), ws).unwrap());
        let whoami = ConfigEnv {
            hostname: Some("h".to_owned()),
            ..bare_env()
        };
        assert_ne!(
            fingerprint_with(&bare_env(), ws).unwrap(),
            fingerprint_with(&whoami, ws).unwrap()
        );
    }

    #[test]
    fn a_malformed_config_id_fails_the_fingerprint_like_the_stack() {
        let cfg = tempfile::tempdir().unwrap();
        let repo_root = tempfile::tempdir().unwrap();
        let repo_path = repo_root.path().join(".jj").join("repo");
        std::fs::create_dir_all(&repo_path).unwrap();
        std::fs::write(repo_path.join("config-id"), "nope").unwrap();
        let env = ConfigEnv {
            config_dir: Some(cfg.path().to_owned()),
            ..bare_env()
        };
        let err = fingerprint_with(&env, paths(&repo_path, repo_root.path())).expect_err("must refuse");
        assert!(err.to_string().contains("config-id"), "got: {err}");
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

    /// Loads `path` exactly as the two verbs do, so every writer row below exercises the
    /// real load-then-write pairing rather than a shortcut the production path never takes.
    fn load(path: &Path) -> Option<ConfigFile> {
        load_repo_config_file(Some(path)).expect("the repo config must load")
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
        remove_remote_from_repo_config(load(&path), "origin").expect("the rewrite must succeed");
        let after = read_back(&path);
        assert!(!after.contains("remotes.origin"), "the section must be gone: {after:?}");
        assert!(
            !after.contains("trunk()"),
            "the alias must be DELETED so the repo layer stops defining it: {after:?}"
        );
    }

    #[test]
    fn rename_moves_the_remotes_section_and_repoints_the_trunk_alias() {
        let (_tmp, path) = repo_config(PINNED);
        rename_remote_in_repo_config(load(&path), "origin", "upstream").expect("the rewrite must succeed");
        let after = read_back(&path);
        assert!(
            after.contains("[remotes.upstream]"),
            "the SECTION itself must move — a re-pointed alias alone is not enough: {after:?}"
        );
        assert!(
            !after.contains("remotes.origin"),
            "…and the old name must be gone: {after:?}"
        );
        assert!(
            after.contains("fetch-bookmarks = \"main\""),
            "the section's VALUE must survive the move: {after:?}"
        );
        // Pinned exactly, not `contains(a) || contains(b)`: `set_value` re-emits the value,
        // so the resulting spelling is a fact about the writer worth freezing.
        assert!(
            after.contains("'trunk()' = \"main@upstream\"\n"),
            "the alias must keep its bookmark and name the new remote: {after:?}"
        );
    }

    /// Both edits key on the REMOTE name alone, so a remote of another name is untouched —
    /// and so is an alias that names one.
    #[test]
    fn an_alias_and_a_section_naming_a_different_remote_survive_both_verbs() {
        let body = "[remotes.other]\nfetch-tags = \"none\"\n\n[revset-aliases]\n'trunk()' = 'main@other'\n";
        let (_tmp, remove_path) = repo_config(body);
        remove_remote_from_repo_config(load(&remove_path), "origin").expect("remove");
        assert!(read_back(&remove_path).contains("main@other"));
        assert!(read_back(&remove_path).contains("remotes.other"));

        let (_tmp2, rename_path) = repo_config(body);
        rename_remote_in_repo_config(load(&rename_path), "origin", "upstream").expect("rename");
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
            remove_remote_from_repo_config(load(&path), "origin").expect("remove");
            assert_eq!(read_back(&path), body, "remove must leave {value} alone");

            let (_tmp2, path2) = repo_config(&body);
            rename_remote_in_repo_config(load(&path2), "origin", "upstream").expect("rename");
            assert_eq!(read_back(&path2), body, "rename must leave {value} alone");
        }
    }

    /// A `revset-aliases` that is not a table at all: `look_up_item` reports the middle node,
    /// which is treated exactly like an absent alias.
    #[test]
    fn a_non_table_revset_aliases_key_is_left_alone() {
        let body = "revset-aliases = 42\n";
        let (_tmp, path) = repo_config(body);
        remove_remote_from_repo_config(load(&path), "origin").expect("remove");
        assert_eq!(read_back(&path), body);
    }

    /// `None` is the state the CLI's `existing_repo_config_file` returns when no repo layer
    /// was loaded: both writers succeed and, having no file at all, touch nothing. The
    /// loader must produce that `None` for a path that does not exist — and must NOT create
    /// the file by loading an empty document into it, which is what the unconditional
    /// `save()` would otherwise do. That [`existing_repo_config_file`] resolves such a path
    /// for a real workspace with no repo-level file is pinned by
    /// `tests/git_remotes.rs::without_a_repo_config_file_both_verbs_succeed_and_create_none`.
    #[test]
    fn an_absent_repo_config_is_a_no_op_for_both_writers() {
        let tmp = tempfile::tempdir().unwrap();
        let missing = tmp.path().join("config.toml");

        remove_remote_from_repo_config(load(&missing), "origin").expect("remove must succeed");
        rename_remote_in_repo_config(load(&missing), "origin", "upstream").expect("rename must succeed");
        assert!(!missing.exists(), "neither writer may bring the file into being");

        // The `path == None` arm (no `<config_dir>` at all) is the same no-op.
        assert!(load_repo_config_file(None).expect("no path is not an error").is_none());
        remove_remote_from_repo_config(None, "origin").expect("remove must succeed");
        rename_remote_in_repo_config(None, "origin", "upstream").expect("rename must succeed");
    }

    /// `toml_edit` round-trips the document, so everything the two edits do not touch —
    /// comments, key order, quoting, blank lines, unrelated tables — survives byte-for-byte.
    ///
    /// Asserted as the WHOLE expected file, not as fragments: re-indentation, a collapsed
    /// blank line or a reordered key would leave every `contains` row green while changing
    /// the file the user has to keep reading.
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
        remove_remote_from_repo_config(load(&path), "origin").expect("remove");
        assert_eq!(
            read_back(&path),
            "\
# a comment the user wrote
[revsets]
log = \"mine\"   # trailing comment

[remotes.keepme]
fetch-tags = \"none\"

[revset-aliases]
'wip()' = 'description(\"wip\")'
",
            "only the two edits may change the file"
        );
    }

    #[test]
    fn an_absent_or_non_table_remotes_key_is_not_an_error() {
        for body in ["[revsets]\nlog = \"mine\"\n", "remotes = 42\n"] {
            let (_tmp, path) = repo_config(body);
            remove_remote_from_repo_config(load(&path), "origin").expect("remove");
            assert_eq!(read_back(&path), body);

            let (_tmp2, path2) = repo_config(body);
            rename_remote_in_repo_config(load(&path2), "origin", "upstream").expect("rename");
            assert_eq!(read_back(&path2), body);
        }
    }

    /// `as_table_like_mut`, not `as_table_mut`: the inline spelling is edited too, exactly
    /// as the CLI does.
    #[test]
    fn an_inline_remotes_table_is_edited_too() {
        let (_tmp, path) = repo_config("remotes = { origin = { fetch-tags = \"none\" } }\n");
        rename_remote_in_repo_config(load(&path), "origin", "upstream").expect("rename");
        let after = read_back(&path);
        assert!(after.contains("upstream"), "the inline entry must move: {after:?}");
        assert!(!after.contains("origin"), "…and the old key must be gone: {after:?}");
    }

    /// Invalid TOML is refused by the LOADER, which the verbs run before they open a
    /// transaction — so this refusal costs no mutation at all.
    #[test]
    fn an_unparseable_repo_config_is_a_config_error_naming_the_file() {
        let (_tmp, path) = repo_config("not = = toml\n");
        let err = load_repo_config_file(Some(&path)).expect_err("invalid TOML must refuse");
        let reason = err.to_string();
        assert!(
            reason.contains("config.toml") && reason.contains("TOML"),
            "the file and the parse position must both be named, got: {reason}"
        );
    }

    /// The other half: an unwritable file LOADS fine, so only `save()` fails — the one
    /// failure the verbs cannot raise before mutating.
    #[test]
    fn an_unwritable_repo_config_is_a_config_error() {
        use std::os::unix::fs::PermissionsExt as _;

        let (_tmp, path) = repo_config(PINNED);
        let file = load(&path);
        // Set AFTER the load, so the load succeeds and only `save()` can fail.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o444)).unwrap();
        let err = rename_remote_in_repo_config(file, "origin", "upstream").expect_err("an unwritable file must refuse");
        let reason = err.to_string();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(
            reason.contains("config.toml"),
            "the io reason must name the file, got: {reason}"
        );
    }

    // ── The create-mode resolver + the trunk writer (Epic 9 follow-up K) ──────
    //
    // Pinned exactly, header included: `ConfigFile::load_or_empty` stamps a fresh document
    // with jj-lib's own schema line and re-emits the alias KEY double-quoted. Both are
    // jj-lib's spelling, so a `jj git init`-created file looks the same — freezing the whole
    // string is what would catch us hand-rolling the file instead.
    //
    // Unit rows only: every assertion here is about the FILE and the `config-id` indirection,
    // which plain temp dirs reproduce exactly. The rows that need a real conversion (which
    // remote wins, what `trunk()` then evaluates to, the rollback) live in
    // `tests/convert.rs` and `tests/convert_alias_write_failure.rs`.

    /// What `ConfigFile::load_or_empty` puts at the top of a file it had to invent.
    const FRESH_FILE_HEADER: &str = "#:schema https://docs.jj-vcs.dev/latest/config-schema.json\n\n";

    #[test]
    fn create_without_a_config_dir_writes_nothing_and_the_writer_is_a_no_op() {
        let repo_dir = tempfile::tempdir().unwrap();
        let file =
            create_repo_config_file(repo_dir.path(), None, None).expect("an unknown <config_dir> is not an error");
        assert!(file.is_none(), "no <config_dir> means no file to write");
        set_trunk_alias(file, "main@origin").expect("the writer must succeed with nothing to write");
        assert!(
            !repo_dir.path().join("config-id").exists(),
            "the skip must be total — not even a config-id may be generated"
        );
    }

    /// The whole create path in one row: a fresh `config-id` in the repo dir, the file under
    /// `<root>/<id>/config.toml`, and the alias line the CLI's `write_repo_presets` emits.
    #[test]
    fn create_then_set_trunk_alias_writes_the_alias_under_the_generated_config_id() {
        let repo_dir = tempfile::tempdir().unwrap();
        let root = tempfile::tempdir().unwrap();

        let file = create_repo_config_file(repo_dir.path(), Some(root.path()), None).expect("the create must succeed");
        let path = file.as_ref().expect("a config file must be created").path().to_owned();

        let id = std::fs::read_to_string(repo_dir.path().join("config-id")).expect("config-id must be written");
        assert!(
            is_valid_config_id(&id),
            "the generated id must satisfy jj-lib's own validity rule, got: {id:?}"
        );
        assert_eq!(
            path,
            root.path().join(&id).join("config.toml"),
            "the file must land where `secure_config_path` will later look for it"
        );

        set_trunk_alias(file, "main@origin").expect("the alias write must succeed");
        assert_eq!(
            read_back(&path),
            format!("{FRESH_FILE_HEADER}[revset-aliases]\n\"trunk()\" = \"main@origin\"\n"),
            "the alias must be the file's only content"
        );
    }

    /// `JJ_RANDOMNESS_SEED` makes the generated `config-id` deterministic, as it does in the
    /// CLI: two repos created with the same seed get the same id.
    #[test]
    fn a_randomness_seed_makes_the_config_id_deterministic() {
        let ids: Vec<String> = (0..2)
            .map(|_| {
                let repo_dir = tempfile::tempdir().unwrap();
                let root = tempfile::tempdir().unwrap();
                create_repo_config_file(repo_dir.path(), Some(root.path()), Some(42)).expect("the create must succeed");
                std::fs::read_to_string(repo_dir.path().join("config-id")).expect("config-id")
            })
            .collect();
        assert!(is_valid_config_id(&ids[0]));
        assert_eq!(ids[0], ids[1]);
    }

    /// A second call re-uses the id the first one wrote and EDITS the existing file rather
    /// than replacing it — the same `load_or_empty` guarantee the CLI relies on.
    #[test]
    fn create_reuses_an_existing_config_id_and_preserves_the_file() {
        let repo_dir = tempfile::tempdir().unwrap();
        let root = tempfile::tempdir().unwrap();
        let first = create_repo_config_file(repo_dir.path(), Some(root.path()), None).expect("first create");
        let path = first.as_ref().expect("file").path().to_owned();
        set_trunk_alias(first, "main@origin").expect("first write");
        let id = std::fs::read_to_string(repo_dir.path().join("config-id")).expect("config-id");

        let second = create_repo_config_file(repo_dir.path(), Some(root.path()), None).expect("second create");
        assert_eq!(second.as_ref().expect("file").path(), path, "the id must be re-used");
        set_trunk_alias(second, "master@upstream").expect("second write");

        assert_eq!(
            std::fs::read_to_string(repo_dir.path().join("config-id")).unwrap(),
            id,
            "a second create must not mint a new id"
        );
        assert_eq!(
            read_back(&path),
            format!("{FRESH_FILE_HEADER}[revset-aliases]\n\"trunk()\" = \"master@upstream\"\n")
        );
    }

    #[test]
    fn a_secure_config_root_that_cannot_be_created_is_a_config_error() {
        let repo_dir = tempfile::tempdir().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let blocker = tmp.path().join("not-a-dir");
        std::fs::write(&blocker, "regular file").unwrap();

        let err = create_repo_config_file(repo_dir.path(), Some(&blocker.join("repos")), None)
            .expect_err("an uncreatable secure-config root must refuse");
        assert!(
            err.to_string().contains("repos"),
            "the offending path must be named, got: {err}"
        );
        assert!(
            !repo_dir.path().join("config-id").exists(),
            "a failed create must not leave a config-id pointing at nothing"
        );
    }

    /// The other half: the directory is fine but the file already there is not TOML — the
    /// `load_or_empty` step refuses, exactly as it does on the read side.
    #[test]
    fn an_unparseable_existing_repo_config_refuses_the_create() {
        let repo_dir = tempfile::tempdir().unwrap();
        let root = tempfile::tempdir().unwrap();
        let id = "0123456789abcdef0123";
        std::fs::write(repo_dir.path().join("config-id"), id).unwrap();
        std::fs::create_dir_all(root.path().join(id)).unwrap();
        std::fs::write(root.path().join(id).join("config.toml"), "not = = toml\n").unwrap();

        let err = create_repo_config_file(repo_dir.path(), Some(root.path()), None)
            .expect_err("invalid TOML must refuse before anything is written");
        let reason = err.to_string();
        assert!(
            reason.contains("config.toml") && reason.contains("TOML"),
            "the file and the parse position must both be named, got: {reason}"
        );
    }

    /// The alias is SET, not appended: a repo config that already defines `trunk()` ends up
    /// with the new symbol and keeps everything else byte-for-byte.
    #[test]
    fn set_trunk_alias_overwrites_an_existing_alias_and_leaves_the_rest_alone() {
        let (_tmp, path) = repo_config(PINNED);
        set_trunk_alias(load(&path), "master@upstream").expect("the alias write must succeed");
        assert_eq!(
            read_back(&path),
            "\
[remotes.origin]
fetch-bookmarks = \"main\"

[revset-aliases]
'trunk()' = \"master@upstream\"
",
            "only the alias value may change"
        );
    }

    #[test]
    fn an_unwritable_file_makes_the_trunk_writer_refuse() {
        use std::os::unix::fs::PermissionsExt as _;

        let (_tmp, path) = repo_config(PINNED);
        let file = load(&path);
        // Set AFTER the load, so the load succeeds and only `save()` can fail.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o444)).unwrap();
        let err = set_trunk_alias(file, "main@origin").expect_err("an unwritable file must refuse");
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

    /// The remote writers' own refusal of a malformed `config-id`. Through [`crate::Repo`] the
    /// pre-verb snapshot (Story 9.26) reads the same stack first and refuses before them, so the
    /// function is called directly.
    #[test]
    fn existing_repo_config_file_refuses_a_malformed_config_id() {
        test_helpers::pin_test_env();
        let tmp = tempfile::tempdir().unwrap();
        let repo = crate::Repo::init(tmp.path(), None).expect("init");
        std::fs::write(repo.workspace().repo_path().join("config-id"), "not-hex").unwrap();
        let err = super::existing_repo_config_file(repo.workspace()).expect_err("a malformed config-id must refuse");
        assert!(err.to_string().contains("config-id"), "{err}");
    }

    /// Every key `GitSettings::from_settings` reads is type-checked by the import options, like
    /// the CLI's; unset, each falls back to jj-lib's own default and reads fine.
    #[test]
    fn git_import_options_type_check_every_git_settings_key() {
        let defaults = git_import_options(&load_with(&bare_env(), None).expect("the bare stack loads"))
            .expect("jj-lib's defaults read");
        assert!(defaults.abandon_unreachable_commits);
        for (toml, key) in [
            ("git.executable-path = 1\n", "git.executable-path"),
            ("git.write-change-id-header = \"yes\"\n", "git.write-change-id-header"),
        ] {
            let err = git_import_options(&stack_with(toml)).expect_err("a wrong-typed key refuses");
            assert!(err.to_string().contains(key), "{key}: {err}");
        }
    }
}
