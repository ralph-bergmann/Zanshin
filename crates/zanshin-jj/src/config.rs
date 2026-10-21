// SPDX-License-Identifier: MIT

//! The repo's effective jj config — the one layer stack every revset parse and the
//! `jj log` defaults are read from (Story 4.9).
//!
//! [`load`] rebuilds, per operation, the `StackedConfig` the jj CLI would have at v0.44.0
//! for this workspace, in the CLI's own order (`cli/src/config.rs:713-730`): jj-lib's
//! defaults, jj-cli's own default layers ([`CLI_DEFAULTS`], Story 9.54) and Zanshin's builtin
//! default layer ([`BUILTIN_CONFIG_TOML`]), the system
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
//! # Reads are side-effect-free — except the CLI's start-up fix-up (Story 9.37)
//!
//! Every READ path here — [`load`], [`load_for_workspace`], [`stack_fingerprint`],
//! [`user_settings_for`], the creation checks — is side-effect-free: no directory is created, no
//! file is written, no `config-id` is generated, nothing is migrated.
//!
//! The one exception is the secure-config fix-up the jj CLI runs at the start of EVERY command:
//! `load_secure_config` → jj-lib's `SecureConfig::maybe_load_config` for the repo layer, then the
//! workspace layer (`cli/src/config.rs:447-469`, `:585-593`, `:653-665` @ v0.44.0, called from
//! `cli_util.rs:4545-4549` / `:4592-4595` after the system and user layers loaded).
//! [`SecureLayer::fix_up`] calls that very function — never a re-implementation — so its on-disk
//! effects are the CLI's exactly: a legacy `.jj/repo/config.toml` / `.jj/workspace-config.toml`
//! is migrated into `<config_dir>/jj/{repos,workspaces}/<id>/` (on Unix the legacy file becomes a
//! symlink to the new one), a MOVED repo's `metadata.binpb` is re-pointed, a COPIED repo's config
//! is forked under a new id, a missing secure directory is regenerated. Each message jj-lib
//! returns — the CLI's `Warning:` line — becomes a [`crate::Warning`] whose kind is read off the
//! id file's state, never off the text. The fix-up runs only where Zanshin plays a CLI command's
//! start-up: [`crate::Repo::open_with_report`] (and so [`crate::Repo::open`]), the settings
//! refresh every precondition-running verb starts with, and the `config_*` verbs that take a
//! workspace root ([`fix_up_secure_config`] inside their start-up load; [`fix_up_layers`] for the
//! two `edit` halves, which load no stack). Not the creation checks ([`check_startup_stack`],
//! [`user_settings_for_new_workspace`]: the new workspace has no `.jj/` yet, so the CLI's call is
//! a no-op there), not `config gc`, not the `&self` reads outside the precondition.
//!
//! Apart from that fix-up, everything that writes belongs to ONE writer family, built from the
//! same helpers: [`load_config_file`] / [`save_config_file`] (`ConfigFile::load_or_empty` /
//! `save`, a `toml_edit` round trip that keeps comments and formatting) and one create-mode
//! secure resolver, [`SecureLayer::create_path`] (`SecureConfig::load_config`, which creates the
//! secure directory, `metadata.binpb` and an id file when none exists). Its members:
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
//! # WHY: by hand for READS, `SecureConfig` for the fix-up and the CREATES
//!
//! `SecureConfig::maybe_load_config` WRITES (see above) and needs a `&mut ChaCha20Rng`, so the
//! READ paths resolve the `config-id` → path indirection by hand ([`secure_config_path`]): read
//! the id, join the path. Once the start-up fix-up has run, that is exactly the file the CLI
//! reads. Between an external change (a repo copied, a secure directory deleted) and the next
//! fix-up — the next open, precondition-running verb or root-taking config verb — a read-only
//! accessor ([`crate::Repo::log_defaults`], …) sees the state before the fix-up, as a CLI
//! command that has not started yet would.
//!
//! [`SecureLayer::fix_up`] and [`SecureLayer::create_path`] are the only callers of
//! `SecureConfig`. The create calls `load_config` deliberately: it runs only from a WRITE the CLI
//! performs through the same create-forcing call (a conversion writing the repo into being, a
//! `config set`/`unset`/`edit`/`path` at repo or workspace scope), and calling jj-lib reproduces
//! that layout exactly — the `<root>/<id>/` directory, the `metadata.binpb`, and the atomic
//! `.jj/repo/config-id` write — without re-implementing `config-id` generation. Writing the
//! legacy `.jj/repo/config.toml` instead would be read correctly by both tools but would leave
//! the CLI to MIGRATE it on its next run (a new secure directory, a symlink where the file was,
//! a `Warning:` line), i.e. a different on-disk end state than `jj git init` produces.
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
//! Every environment value the stack reads — `HOME`, `XDG_CONFIG_HOME`, `JJ_CONFIG`, the two
//! env layers' variables, the `--when.env` context — comes from ONE snapshot taken through
//! `crate::environment` (Story 9.36): the login shell's environment once the app adopted it at
//! start-up, else the process's. A Zanshin launched from Finder therefore resolves the stack a
//! terminal `jj` would.
//!
//! Still absent: the `--config`/`--config-file` command-line layer (Zanshin has no CLI args),
//! and `jj_lib::config::migrate` — the CLI's `default_config_migrations()`
//! (`cli/src/config.rs:972-1052` @ v0.46.0) holds one rule, `fix.tools.<name>.line-range-arg` →
//! `line-range-args` (to be removed in jj 0.51), which only rewrites `fix.tools` — a table no
//! Zanshin verb reads — so it is not ported yet; whoever ports a `fix` verb ports it. Re-check it
//! at every pin bump, together with `maybe_migrate_legacy_config`'s TODO (jj 0.49 is to stop
//! migrating the legacy files automatically and only warn). `resolve` runs with `command: None`
//! (a state the CLI itself produces before a subcommand is known) for every verb except the
//! config verbs, which pass their CLI command name (`"config set"`, …) through
//! [`resolve_raw`], so `--when.commands` scopes match there as in the CLI; `--when.hostnames`
//! scopes match against `whoami::hostname()`, exactly as in the CLI.

use std::collections::{BTreeMap, HashMap};
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};
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
/// table are verbatim from `cli/src/config/revsets.toml` at v0.46.0;
/// `ui.log-synthetic-elided-nodes` is verbatim from `cli/src/config/misc.toml:44` and
/// `ui.conflict-marker-style` from `cli/src/config/misc.toml:45` (Story 9.4 — the style
/// `file show` materializes a conflicted file with); `snapshot.max-new-file-size` and
/// `snapshot.auto-track` are verbatim from `cli/src/config/misc.toml:60-61` (Story 9.22 — the
/// snapshot options `file track`/`file untrack` build; jj-lib's own `config/misc.toml` has
/// neither, so without them the keys would be missing, not defaulted); `git.colocate` is
/// verbatim from `cli/src/config/misc.toml:27-28` (Story 9.23 — `workspace add`'s default Git
/// worktree decision; jj-lib has no default for it either); `split.legacy-bookmark-behavior` is
/// verbatim from `cli/src/config/misc.toml:64-68` (Story 9.15 — where `split` leaves the target's
/// bookmarks; jj-lib has no default for it either); the `[experimental-advance-branches]` table
/// (`enabled-branches = []`, `disabled-branches = []`) is verbatim from
/// `cli/src/config/misc.toml:20-22` (Story 9.49 — the bookmarks `commit` advances; an empty
/// `enabled-branches` is the feature off, and jj-lib has no default for either key). Story 9.20
/// adds the rest of the CLI's `[git]` table — `object-hash`, `private-commits`, `sign-on-push`
/// and `track-default-bookmark-on-clone`, verbatim from `cli/src/config/misc.toml:29-32` (init
/// and clone's object hash, push's commit checks and signing, clone's tracked default bookmark)
/// — and `revsets.git-push` from `cli/src/config/revsets.toml:8` (push's default targets); jj-lib
/// has a default for none of them. The template defaults are NOT here: they are taken from jj-cli
/// itself ([`CLI_DEFAULTS`], Stories 9.51 and 9.54).
///
/// Since Story 9.54 every jj-cli default layer sits BELOW this one, so each key here repeats a
/// jj-cli default with the same value — except `revsets.log`, whose value here wins over the
/// CLI's `builtin_log()`. The layer stays as the record of which defaults Zanshin's verbs read.
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
/// The CLI's other `[revsets]` keys (`arrange`, `converge`, `fix`, `run`, `sign`,
/// `op-diff-changes-in`, `simplify-parents`, `bookmark-advance-*`) are not copied here — no Zanshin
/// verb consumes them; they reach the stack with the rest of jj-cli's defaults ([`CLI_DEFAULTS`]),
/// so `config get` / `config list --include-defaults` and a template's `config()` see them as the
/// CLI does (Ralph, 2026-10-20: the defaults the CLI shows are the defaults Zanshin shows).
const BUILTIN_CONFIG_TOML: &str = r#"
[revsets]
git-push = "remote_bookmarks(remote=exact:remote)..@"
log = "present(@) | ancestors(immutable_heads().., 2) | trunk()"
log-graph-prioritize = "present(@)"

[ui]
log-synthetic-elided-nodes = true
conflict-marker-style = "diff"

[snapshot]
max-new-file-size = "1MiB"
auto-track = "all()"
auto-update-stale = false

[git]
colocate = true
object-hash = "sha1"
private-commits = "none()"
sign-on-push = false
track-default-bookmark-on-clone = true

[experimental-advance-branches]
enabled-branches = []
disabled-branches = []

# TODO: https://github.com/jj-vcs/jj/issues/3419 - Remove when fully deprecated.
# The behavior when this flag is set to false is experimental and may be changed
# in the future.
[split]
legacy-bookmark-behavior = true

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
'builtin_immutable_heads()' = '''
trunk() | tags() | untracked_remote_bookmarks() | untracked_remote_tags()
'''
'immutable_heads()' = 'builtin_immutable_heads()'
'immutable()' = '::(immutable_heads() | root())'
'mutable()' = '~immutable()'

'visible()' = '::visible_heads()'
'hidden()' = '~visible()'
"#;

/// jj-cli's own default layers (`jj_cli::config::default_config_layers`, `cli/src/config.rs:860-879`
/// @ v0.46.0) — colors, hints, merge tools, misc, revsets, templates and the platform layer, each a
/// [`ConfigSource::Default`] layer, verbatim by construction so they move with the pin (Stories
/// 9.51, 9.54). [`load_raw`] puts them right after jj-lib's defaults and BELOW
/// [`BUILTIN_CONFIG_TOML`]: the template engine reads its aliases, `templates.*` keys and diff
/// options from them, and a template's `config("<name>")`, `config get` and `config list
/// --include-defaults` see every CLI default (`config("ui.color")` renders `auto`).
///
/// Built once per process: the result is static, and every config load would otherwise re-parse
/// all of jj-cli's default TOML.
static CLI_DEFAULTS: LazyLock<Vec<Arc<ConfigLayer>>> = LazyLock::new(|| {
    jj_cli::config::default_config_layers()
        .into_iter()
        .map(Arc::new)
        .collect()
});

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
pub(crate) fn value_error(err: &ConfigGetError) -> ConfigError {
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
    /// (`cli/src/config.rs:366-419` @ v0.44.0) does — from ONE snapshot of the environment the
    /// crate's reads see: the login shell's once adopted (Story 9.36), else the process's.
    pub(crate) fn from_env() -> Self {
        Self::from_vars(
            &crate::environment::snapshot(),
            whoami::hostname().ok(),
            whoami::username().ok(),
        )
    }

    /// [`ConfigEnv::from_env`] over an explicit environment and explicit `whoami` values.
    fn from_vars(vars: &crate::environment::EnvMap, hostname: Option<String>, username: Option<String>) -> Self {
        let var = |name: &str| vars.get(OsStr::new(name));
        let home_dir = var("HOME").map(PathBuf::from).map(|d| {
            // WHY: the CLI canonicalizes $HOME (dunce::canonicalize, == std::fs::canonicalize
            // on Unix) because it may be a symlink and `--when.repositories` compares paths.
            std::fs::canonicalize(&d).unwrap_or(d)
        });
        let xdg = var("XDG_CONFIG_HOME").map(PathBuf::from);
        // WHY: only the UTF-8 pairs — the CLI's own filter (`cli/src/config.rs:389-396` @
        // v0.44.0) silently drops a non-Unicode variable rather than panicking like `vars()`.
        let environment: HashMap<String, String> = vars
            .iter()
            .filter_map(|(k, v)| Some((k.to_str()?.to_owned(), v.to_str()?.to_owned())))
            .collect();
        Self {
            config_dir: platform_config_dir(xdg.as_deref(), home_dir.as_deref()),
            // WHY UTF-8-or-unset: the CLI reads `JJ_CONFIG` as a UTF-8 `var(..).ok()`
            // (`cli/src/config.rs:386` @ v0.44.0), so a non-UTF-8 value counts as UNSET there
            // (system layer + discovery on).
            jj_config: var("JJ_CONFIG").filter(|v| v.to_str().is_some()).cloned(),
            system_config_dir: Some(PathBuf::from("/etc")),
            hostname,
            // WHY the `$USER` fallback: the CLI's own (`env_base_layer`), for libcs whose
            // `getpwuid()` does not fully support nsswitch.
            username: username.or_else(|| environment.get("USER").cloned()),
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
        return crate::environment::split_paths(paths)
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
    existing_files(env_user_config_paths(env))
}

/// The existing system config FILES, expanded like [`user_edit_candidates`] — the paths of the
/// CLI's loaded `System` layers, which `jj config set --file` may target (jj 0.45).
pub(crate) fn system_edit_candidates(env: &ConfigEnv) -> Vec<PathBuf> {
    existing_files(system_config_paths(
        env.system_config_dir.as_deref(),
        env.jj_config.as_deref(),
    ))
}

/// `paths` expanded as [`add_path_layers`] loads them, without parsing.
fn existing_files(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for path in paths.into_iter().filter(|p| p.exists()) {
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
    /// created. `Ok(None)` iff no `<config_dir>` is known — then nothing is written. The RNG is
    /// [`secure_rng`]'s.
    ///
    /// # Errors
    ///
    /// - [`ConfigError::Load`] — the OS RNG failed, or the secure-config directory / id file
    ///   could not be read, created or written.
    pub(crate) fn create_path(&self, randomness_seed: Option<u64>) -> Result<Option<PathBuf>, ConfigError> {
        let Some(root) = self.root_config_dir.as_deref() else {
            return Ok(None);
        };
        let loaded = (self.new_secure)(self.dir.clone())
            .load_config(&mut secure_rng(randomness_seed)?, root)
            .map_err(write_error)?;
        Ok(loaded.config_file)
    }

    /// The CLI's start-up fix-up of this layer (Story 9.37): jj-lib's own
    /// `SecureConfig::maybe_load_config`, as `load_secure_config` calls it
    /// (`cli/src/config.rs:447-469` @ v0.44.0) — it migrates a legacy file, re-points a MOVED
    /// repo's metadata, forks a COPIED repo's config, regenerates a missing secure directory, or
    /// does nothing. Every message it returns lands in `sink` as a [`crate::Warning`], jj-lib's
    /// text verbatim. No `<config_dir>` known → nothing runs, as the CLI's `load_secure_config`
    /// then returns `None`.
    ///
    /// The kind is read off the id file's STATE, never off the message: no id file before →
    /// [`crate::WarningKind::ConfigMigrated`]; an id afterwards (the new `config.toml`'s directory
    /// name) that differs → [`crate::WarningKind::ConfigCopied`]; the same id →
    /// [`crate::WarningKind::ConfigRegenerated`].
    ///
    /// # Errors
    ///
    /// - [`ConfigError::Load`] — the id file is malformed or unreadable (the read side's
    ///   path-named refusal, checked BEFORE jj-lib runs, so nothing is written), or jj-lib failed:
    ///   the CLI's "Failed to determine the secure config for a repo: …".
    pub(crate) fn fix_up(&self, rng: &mut ChaCha20Rng, sink: &mut Vec<crate::Warning>) -> Result<(), ConfigError> {
        let Some(root) = self.root_config_dir.as_deref() else {
            return Ok(());
        };
        self.resolved_path()?;
        let old_id = std::fs::read_to_string(self.dir.join(self.id_file_name)).ok();
        let loaded = (self.new_secure)(self.dir.clone())
            .maybe_load_config(rng, root)
            .map_err(|e| ConfigError::Load {
                reason: format!("Failed to determine the secure config for a repo: {}", describe(&e)),
            })?;
        let new_id = loaded
            .config_file
            .as_deref()
            .and_then(Path::parent)
            .and_then(Path::file_name);
        for message in loaded.warnings {
            let kind = match old_id.as_deref() {
                None => crate::WarningKind::ConfigMigrated,
                Some(id) if Some(OsStr::new(id)) != new_id => crate::WarningKind::ConfigCopied,
                Some(_) => crate::WarningKind::ConfigRegenerated,
            };
            sink.push(crate::warning::local(kind, message));
        }
        Ok(())
    }
}

/// The `&mut ChaCha20Rng` `SecureConfig` draws new config ids from, seeded as the CLI seeds its
/// one `ConfigEnv.rng` (`cli/src/config.rs:411-417` @ v0.44.0): from `randomness_seed`
/// (`JJ_RANDOMNESS_SEED`) when set, else from the OS RNG — drawn here by hand, because
/// `rand::make_rng()`, what the CLI uses, `expect`s on OS-RNG failure and nothing reachable from
/// FFI may panic.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the OS RNG failed.
fn secure_rng(randomness_seed: Option<u64>) -> Result<ChaCha20Rng, ConfigError> {
    if let Some(seed) = randomness_seed {
        return Ok(ChaCha20Rng::seed_from_u64(seed));
    }
    let mut seed = [0_u8; 32];
    getrandom::fill(&mut seed).map_err(write_error)?;
    Ok(ChaCha20Rng::from_seed(seed))
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
/// `workspace` is `None` outside any workspace ([`check_startup_stack`]): the stack stops at
/// the user level and resolves with no repo/workspace path — the state the CLI starts up in
/// without a workspace. A CREATION path then passes the new workspace's paths
/// ([`user_settings_for_new_workspace`]).
fn load_with(env: &ConfigEnv, workspace: Option<WorkspacePaths<'_>>) -> Result<StackedConfig, ConfigError> {
    resolve_raw(env, workspace, &load_raw(env, workspace, None)?, None)
}

/// The UNRESOLVED ("raw") stack [`load_with`] resolves — one layer per file, `--when` /
/// `[[--scope]]` blocks still in place: the CLI's `RawConfig`.
///
/// Side-effect-free with `fix_ups: None`. With a sink (and a workspace) it is the CLI's start-up
/// load (Story 9.37): each secure layer is FIXED UP ([`SecureLayer::fix_up`], one RNG for both
/// layers — the repo draws first) right before it loads, after the system and user layers — so a
/// broken system/user file refuses before any fix-up, and a broken repo file refuses after the
/// repo fix-up but before the workspace's. The warnings recorded before a failure stay in the
/// sink.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a file is unreadable or not valid TOML, or a `config-id` is
///   malformed; the path is named. With a sink also: a fix-up failed.
pub(crate) fn load_raw(
    env: &ConfigEnv,
    workspace: Option<WorkspacePaths<'_>>,
    fix_ups: Option<&mut Vec<crate::Warning>>,
) -> Result<StackedConfig, ConfigError> {
    let mut config = StackedConfig::with_defaults();
    for layer in CLI_DEFAULTS.iter() {
        config.add_layer(Arc::clone(layer));
    }
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
    let mut fix_ups = match (fix_ups, workspace) {
        (Some(sink), Some(_)) => Some((secure_rng(env.randomness_seed())?, sink)),
        _ => None,
    };
    for layer in workspace.map(|paths| secure_layers(env, paths)).into_iter().flatten() {
        if let Some((rng, sink)) = fix_ups.as_mut() {
            layer.fix_up(rng, sink)?;
        }
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

/// The CLI's start-up secure-config fix-up for the workspace at `paths` (Story 9.37): the
/// start-up load of [`load_raw`] with a fix-up sink, the stack dropped — so it runs in the CLI's
/// order and refuses where the CLI's start-up does. [`crate::Repo`] runs it before it
/// fingerprints or derives its settings.
///
/// # Errors
///
/// - [`ConfigError::Load`] — as [`load_raw`] with a sink.
pub(crate) fn fix_up_secure_config(
    env: &ConfigEnv,
    paths: WorkspacePaths<'_>,
    sink: &mut Vec<crate::Warning>,
) -> Result<(), ConfigError> {
    load_raw(env, Some(paths), Some(sink)).map(drop)
}

/// The fix-up ALONE — both secure layers, repo first, one RNG — loading no config file: the two
/// `jj config edit` halves (`config_cmd.rs`), the CLI's repair path for a stack that does not
/// load, still start with it.
///
/// # Errors
///
/// - [`ConfigError::Load`] — as [`SecureLayer::fix_up`], or the OS RNG failed.
pub(crate) fn fix_up_layers(
    env: &ConfigEnv,
    paths: WorkspacePaths<'_>,
    sink: &mut Vec<crate::Warning>,
) -> Result<(), ConfigError> {
    let mut rng = secure_rng(env.randomness_seed())?;
    for layer in secure_layers(env, paths) {
        layer.fix_up(&mut rng, sink)?;
    }
    Ok(())
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
/// While the call runs with the start-up `trunk()` fallback (Story 9.56, see
/// [`crate::Repo`]'s precondition), the stack carries one more, topmost layer setting
/// `revset-aliases."trunk()"` to `root()` — the CLI's `revset_aliases_map.insert("trunk()",
/// "root()")` (`cli/src/cli_util.rs:558-561` @ v0.46.0), so every revset, immutable set and
/// template the call parses sees it.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a config file is unreadable or not valid TOML, a `config-id`
///   is malformed, or a `--when`/`[[--scope]]` condition has the wrong type.
pub(crate) fn load(repo: &Repo) -> Result<StackedConfig, ConfigError> {
    let mut config = load_for_workspace(repo.workspace())?;
    if repo.trunk_fallback() {
        config.add_layer(trunk_fallback_layer());
    }
    Ok(config)
}

/// The topmost layer of a call with the `trunk()` fallback: `trunk()` = `root()`.
fn trunk_fallback_layer() -> ConfigLayer {
    let mut layer = ConfigLayer::empty(ConfigSource::CommandArg);
    // WHY no error path: the name is a literal two-segment key and the value a plain string.
    let _ = layer.set_value(["revset-aliases", "trunk()"], "root()");
    layer
}

/// Whether a non-default layer of `config` defines `revset-aliases."trunk()"` — the only way the
/// alias can fail to resolve: the builtin one is a `latest(… | root())` of `remote_bookmarks()`,
/// which always resolves. Lets the precondition skip the `trunk()` check's head load otherwise.
pub(crate) fn trunk_alias_redefined(config: &StackedConfig) -> bool {
    config
        .layers()
        .iter()
        .filter(|layer| layer.source != ConfigSource::Default)
        .any(|layer| {
            layer
                .look_up_table("revset-aliases")
                .ok()
                .flatten()
                .is_some_and(|table| table.contains_key("trunk()"))
        })
}

/// Turns a resolved stack into the `UserSettings` jj-lib signs commits and operations with.
///
/// `UserSettings::from_config_and_home_dir` reads `user.*`, `operation.*`, `debug.*` and
/// `signing.*` eagerly, so a wrong-typed value there refuses HERE — naming the key — exactly
/// where the CLI fails at start-up. `env`'s canonicalized `$HOME` is what jj-lib expands a
/// `~/` config path against — the CLI passes its `ConfigEnv::home_dir()`
/// (`cli/src/cli_util.rs:4747-4750` @ v0.46.0).
pub(crate) fn settings_from(env: &ConfigEnv, config: StackedConfig) -> Result<UserSettings, ConfigError> {
    UserSettings::from_config_and_home_dir(config, env.home_dir.clone()).map_err(|e| value_error(&e))
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
    let env = ConfigEnv::from_env();
    settings_from(&env, load_with(&env, Some(paths))?)
}

/// The CLI's start-up config check, run FIRST by every creation path (`init`, `clone`,
/// conversions): before any command touches a path, the CLI loads and resolves the stack
/// outside a workspace and builds `UserSettings` from it (`CliRunner::run_internal`,
/// `cli/src/cli_util.rs:4543-4627` @ v0.44.0). A broken system/user file or a wrong-typed
/// `user.*` / `operation.*` value therefore refuses before a destination is created and wins
/// over every path or precondition error — only a fault that needs the new workspace's paths
/// (a scoped table) surfaces later, in [`user_settings_for_new_workspace`]. Returns the checked
/// stack: `jj git init` / `jj git clone` read `git.colocate` and `git.object-hash` from it
/// (Story 9.20), as the CLI reads them from its start-up `command.settings()`.
///
/// # Errors
///
/// - [`ConfigError::Load`] — as [`user_settings_for`].
pub(crate) fn check_startup_stack() -> Result<StackedConfig, ConfigError> {
    let env = ConfigEnv::from_env();
    let config = load_with(&env, None)?;
    settings_from(&env, config.clone())?;
    Ok(config)
}

/// The `UserSettings` the workspace at `workspace_root` is CREATED with (`init`, `clone`,
/// conversions) — the CLI's `settings_for_new_workspace` (`cli/src/cli_util.rs:372-388` @
/// v0.44.0): the stack is built for the NEW workspace's paths (`<root>/.jj/repo`, `<root>`),
/// so `--when.repositories` / `--when.workspaces` scopes (a per-directory identity) already
/// apply to what the creation writes. Normally no repo or workspace config file exists there
/// yet; whatever is there is read, exactly as the CLI's reload reads it.
///
/// Runs once the creation's root is known — after [`check_startup_stack`], as the CLI runs it
/// after its start-up.
///
/// # Errors
///
/// - [`ConfigError::Load`] — as [`user_settings_for`].
pub(crate) fn user_settings_for_new_workspace(workspace_root: &Path) -> Result<UserSettings, ConfigError> {
    let paths = WorkspacePaths {
        repo_path: &workspace_root.join(".jj").join("repo"),
        workspace_root,
    };
    let env = ConfigEnv::from_env();
    settings_from(&env, load_with(&env, Some(paths))?)
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
/// [`load`] is the usual entry point; this exists because `Repo::clone` must read the
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
    for (remote, settings) in every_remote_settings(config)? {
        let Some(text) = settings.auto_track_bookmarks else {
            continue;
        };
        let expression = parse_remote_string_expression(&remote, &text, "auto-track-bookmarks")?;
        matchers.insert(remote, expression.to_matcher());
    }
    Ok(matchers)
}

/// The CLI's `parse_remote_auto_track_bookmarks_map_for_new_bookmarks`
/// (`cli/src/revset_util.rs:444-476` @ v0.46.0), the matchers `jj bookmark create` auto-tracks
/// with: per remote, the UNION of `remotes.<name>.auto-track-bookmarks` and
/// `remotes.<name>.auto-track-created-bookmarks` (either alone suffices; a remote with neither
/// has no entry).
///
/// Name-ordered: the CLI's `HashMap` iterates in an unspecified order, so name order is the one
/// deterministic choice for the warnings the caller emits per remote. Returns `jj_lib` types,
/// which is why it is `pub(crate)` (FR-JJ-16).
///
/// # Errors
///
/// - [`ConfigError::Load`] — a `remotes.<name>` entry is not a table of the known string keys,
///   or either value does not parse (the CLI's ``Invalid `remotes.<name>.<field>`: …``). Every
///   remote is parsed, whether or not a caller's name would match it.
pub(crate) fn remote_auto_track_bookmarks_for_new_bookmarks(
    config: &StackedConfig,
) -> Result<BTreeMap<jj_lib::ref_name::RemoteNameBuf, jj_lib::str_util::StringMatcher>, ConfigError> {
    let mut matchers = BTreeMap::new();
    for (remote, settings) in every_remote_settings(config)? {
        let mut expressions = Vec::new();
        if let Some(text) = &settings.auto_track_bookmarks {
            expressions.push(parse_remote_string_expression(&remote, text, "auto-track-bookmarks")?);
        }
        if let Some(text) = &settings.auto_track_created_bookmarks {
            expressions.push(parse_remote_string_expression(
                &remote,
                text,
                "auto-track-created-bookmarks",
            )?);
        }
        if expressions.is_empty() {
            continue;
        }
        matchers.insert(
            remote,
            jj_lib::str_util::StringExpression::union_all(expressions).to_matcher(),
        );
    }
    Ok(matchers)
}

/// jj-lib's `RemoteSettings::table_from_settings` read off the stack directly, in the stack's
/// key order: one `(remote, settings)` per `remotes.<name>` entry. `pub(crate)` since Story 9.30,
/// whose fetch reads every entry right after its transaction starts, as the CLI's
/// `remote_settings()` does.
pub(crate) fn every_remote_settings(
    config: &StackedConfig,
) -> Result<Vec<(jj_lib::ref_name::RemoteNameBuf, jj_lib::settings::RemoteSettings)>, ConfigError> {
    let names: Vec<String> = config.table_keys("remotes").map(str::to_owned).collect();
    names
        .into_iter()
        .map(|name| {
            let settings: jj_lib::settings::RemoteSettings =
                config.get(["remotes", name.as_str()]).map_err(|e| value_error(&e))?;
            Ok((name.as_str().into(), settings))
        })
        .collect()
}

/// The CLI's `parse_remote_string_expression` (`cli/src/revset_util.rs:504-528` @ v0.46.0):
/// one `remotes.<remote>.<field>` value parsed as a string expression, refusing with the CLI's
/// ``Invalid `remotes.<remote>.<field>`: <kind>``. Its diagnostics sink is dropped — jj-lib 0.46
/// emits none for string patterns (as `bookmark_ops::union_expression` documents).
fn parse_remote_string_expression(
    remote: &jj_lib::ref_name::RemoteName,
    text: &str,
    field: &str,
) -> Result<jj_lib::str_util::StringExpression, ConfigError> {
    jj_lib::revset::parse_string_expression(&mut jj_lib::revset::RevsetDiagnostics::new(), text).map_err(|e| {
        ConfigError::Load {
            reason: format!("Invalid `remotes.{}.{field}`: {}", remote.as_symbol(), e.kind()),
        }
    })
}

/// Reads the effective `snapshot.auto-update-stale` (Story 9.26) — the CLI's
/// `settings().get_bool("snapshot.auto-update-stale")` (`cli/src/cli_util.rs:500` @ v0.46.0),
/// whose default `false` is [`BUILTIN_CONFIG_TOML`]'s (the CLI's `config/misc.toml`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a boolean (the key is named), or is missing from
///   every layer (impossible while the builtin layer is present).
pub(crate) fn snapshot_auto_update_stale(config: &StackedConfig) -> Result<bool, ConfigError> {
    config.get("snapshot.auto-update-stale").map_err(|e| value_error(&e))
}

/// Reads the effective `git.colocate` (Story 9.23) — the CLI's `settings().get_bool("git.colocate")`
/// in `jj workspace add` (`cli/src/commands/workspace/add.rs:150-151` @ v0.46.0), read only when
/// the current workspace is colocated and neither `--colocate` nor `--no-colocate` was given.
/// Its default `true` is [`BUILTIN_CONFIG_TOML`]'s (the CLI's `config/misc.toml:27-28`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a boolean (the key is named), or is missing from
///   every layer (impossible while the builtin layer is present).
pub(crate) fn git_colocate(config: &StackedConfig) -> Result<bool, ConfigError> {
    config.get("git.colocate").map_err(|e| value_error(&e))
}

/// Reads the effective `git.object-hash` (Story 9.20) — the CLI's
/// `settings().get::<ObjectHash>("git.object-hash")` in `jj git init` / `jj git clone`
/// (`cli/src/commands/git/init.rs:172-175`, `clone.rs:212-215` @ v0.46.0), read only when no
/// `--object-hash` was given. Its default `"sha1"` is [`BUILTIN_CONFIG_TOML`]'s (the CLI's
/// `config/misc.toml:29`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is neither `"sha1"` nor `"sha256"` (the key is named), or
///   is missing from every layer (impossible while the builtin layer is present).
pub(crate) fn git_object_hash(config: &StackedConfig) -> Result<crate::ObjectHash, ConfigError> {
    config
        .get_value_with("git.object-hash", |value| match value.as_str() {
            Some("sha1") => Ok(crate::ObjectHash::Sha1),
            Some("sha256") => Ok(crate::ObjectHash::Sha256),
            _ => Err(format!("unknown variant {value}, expected `sha1` or `sha256`")),
        })
        .map_err(|e| value_error(&e))
}

/// Reads the effective `git.track-default-bookmark-on-clone` (Story 9.20) — the CLI's
/// `settings.get_bool(..)` in `jj git clone`'s fetch (`cli/src/commands/git/clone.rs:390` @
/// v0.46.0). Its default `true` is [`BUILTIN_CONFIG_TOML`]'s (the CLI's `config/misc.toml:32`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a boolean (the key is named).
pub(crate) fn git_track_default_bookmark_on_clone(config: &StackedConfig) -> Result<bool, ConfigError> {
    config
        .get("git.track-default-bookmark-on-clone")
        .map_err(|e| value_error(&e))
}

/// Reads the effective `git.sign-on-push` (Story 9.20) — the CLI's `get_bool` in `jj git push`
/// (`cli/src/commands/git/push.rs:566` @ v0.46.0). Its default `false` is
/// [`BUILTIN_CONFIG_TOML`]'s (the CLI's `config/misc.toml:31`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a boolean (the key is named).
pub(crate) fn git_sign_on_push(config: &StackedConfig) -> Result<bool, ConfigError> {
    config.get("git.sign-on-push").map_err(|e| value_error(&e))
}

/// Reads the effective `git.private-commits` revset TEXT (Story 9.20) — the CLI's `get_string` in
/// `jj git push`'s commit checks (`push.rs:808` @ v0.46.0). Its default `"none()"` is
/// [`BUILTIN_CONFIG_TOML`]'s (the CLI's `config/misc.toml:30`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a string (the key is named).
pub(crate) fn git_private_commits(config: &StackedConfig) -> Result<String, ConfigError> {
    config.get("git.private-commits").map_err(|e| value_error(&e))
}

/// Reads the effective `revsets.git-push` revset TEXT (Story 9.20) — the CLI's `get_string` in
/// `jj git push` without explicit targets (`push.rs:420-422` @ v0.46.0). Its default
/// `remote_bookmarks(remote=exact:remote)..@` is [`BUILTIN_CONFIG_TOML`]'s (the CLI's
/// `config/revsets.toml:8`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a string (the key is named).
pub(crate) fn revsets_git_push(config: &StackedConfig) -> Result<String, ConfigError> {
    config.get("revsets.git-push").map_err(|e| value_error(&e))
}

/// Reads the effective `templates.git_push_bookmark` TEXT (Story 9.20) — the CLI's `get_string`
/// in `jj git push --change` (`push.rs:1323` @ v0.46.0). Its default is jj-cli's own
/// ([`CLI_DEFAULTS`], the CLI's `config/templates.toml:30`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a string (the key is named).
pub(crate) fn templates_git_push_bookmark(config: &StackedConfig) -> Result<String, ConfigError> {
    config.get("templates.git_push_bookmark").map_err(|e| value_error(&e))
}

/// Reads the effective `templates.commit_trailers` TEXT (Story 9.51) — the CLI's `get_string` in
/// `parse_trailers_template` (`description_util.rs:437` @ v0.46.0). Its default `''` (no trailers)
/// is jj-cli's own ([`CLI_DEFAULTS`]).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a string (the key is named).
pub(crate) fn templates_commit_trailers(config: &StackedConfig) -> Result<String, ConfigError> {
    config.get("templates.commit_trailers").map_err(|e| value_error(&e))
}

/// Reads the effective `templates.draft_commit_description` TEXT (Story 9.51) — the CLI's
/// `get_string` in `description_template` (`description_util.rs:502` @ v0.46.0). Its default
/// `builtin_draft_commit_description` is jj-cli's own ([`CLI_DEFAULTS`]).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a string (the key is named).
pub(crate) fn templates_draft_commit_description(config: &StackedConfig) -> Result<String, ConfigError> {
    config
        .get("templates.draft_commit_description")
        .map_err(|e| value_error(&e))
}

/// Reads the effective `templates.new_description` TEXT (Story 9.51) — the CLI's `get_string` in
/// `jj new` without `-m` (`new.rs:218` @ v0.46.0). Its default `''` (no description) is jj-cli's
/// own ([`CLI_DEFAULTS`]).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a string (the key is named).
pub(crate) fn templates_new_description(config: &StackedConfig) -> Result<String, ConfigError> {
    config.get("templates.new_description").map_err(|e| value_error(&e))
}

/// Reads the effective `revsets.short-prefixes` revset TEXT the way the CLI's
/// `load_short_prefixes_expression` does (`cli_util.rs:1115-1121` @ v0.46.0, Story 9.51): the key,
/// else — when it is ABSENT — `revsets.log`. An empty text is returned as is (disambiguation off).
///
/// # Errors
///
/// - [`ConfigError::Load`] — a value is not a string (the key is named).
pub(crate) fn revsets_short_prefixes(config: &StackedConfig) -> Result<String, ConfigError> {
    match config
        .get::<String>("revsets.short-prefixes")
        .optional()
        .map_err(|e| value_error(&e))?
    {
        Some(text) => Ok(text),
        None => config.get("revsets.log").map_err(|e| value_error(&e)),
    }
}

/// Reads the effective `git.push` (Story 9.20) the way the CLI's `get_default_push_remotes` does
/// (`push.rs:1111-1116` @ v0.46.0): a list of name patterns, else one pattern string, else
/// `None` (the key is unset; the CLI then falls back to the single remote, then `origin`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is neither a list of strings nor a string.
pub(crate) fn git_push_remotes(config: &StackedConfig) -> Result<Option<Vec<String>>, ConfigError> {
    remote_name_patterns(config, "git.push")
}

/// Reads the effective `git.fetch` (Story 9.30) the way the CLI's `get_default_fetch_remotes`
/// does (`cli/src/commands/git/fetch.rs:267-290` @ v0.46.0): a list of name patterns, else one
/// pattern string, else `None` (the key is unset; the CLI then falls back to the single remote,
/// then `origin`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is neither a list of strings nor a string.
pub(crate) fn git_fetch_remotes(config: &StackedConfig) -> Result<Option<Vec<String>>, ConfigError> {
    remote_name_patterns(config, "git.fetch")
}

/// `settings.get::<Vec<String>>(key)`, else `get_string(key).optional()` — the shared read of
/// `git.push` and `git.fetch`.
fn remote_name_patterns(config: &StackedConfig, key: &'static str) -> Result<Option<Vec<String>>, ConfigError> {
    if let Ok(list) = config.get::<Vec<String>>(key) {
        return Ok(Some(list));
    }
    match config.get::<String>(key) {
        Ok(text) => Ok(Some(vec![text])),
        Err(jj_lib::config::ConfigGetError::NotFound { .. }) => Ok(None),
        Err(e) => Err(value_error(&e)),
    }
}

/// Which per-remote fetch setting [`remote_fetch_expression`] reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FetchField {
    /// `remotes.<name>.fetch-bookmarks`.
    Bookmarks,
    /// `remotes.<name>.fetch-tags`.
    Tags,
}

/// The CLI's `parse_remote_fetch_bookmarks` / `parse_remote_fetch_tags`
/// (`cli/src/revset_util.rs:478-502` @ v0.46.0) over [`remote_settings`] (Story 9.30): `remote`'s
/// `fetch-bookmarks` or `fetch-tags` parsed as a string expression, `None` when it is unset.
///
/// Returns a `jj_lib` type, which is why it is `pub(crate)` (FR-JJ-16).
///
/// # Errors
///
/// - [`ConfigError::Load`] — a `remotes.<name>` entry is not a table of the known string keys, or
///   the value does not parse (the CLI's ``Invalid `remotes.<remote>.fetch-bookmarks`: …``).
pub(crate) fn remote_fetch_expression(
    config: &StackedConfig,
    remote: &jj_lib::ref_name::RemoteName,
    field: FetchField,
) -> Result<Option<jj_lib::str_util::StringExpression>, ConfigError> {
    let Some(settings) = remote_settings(config, remote.as_str())? else {
        return Ok(None);
    };
    let (text, name) = match field {
        FetchField::Bookmarks => (settings.fetch_bookmarks, "fetch-bookmarks"),
        FetchField::Tags => (settings.fetch_tags, "fetch-tags"),
    };
    text.map(|text| parse_remote_string_expression(remote, &text, name))
        .transpose()
}

/// The effective `remotes.<remote>` settings (Story 9.20) — jj-lib's
/// `RemoteSettings::table_from_settings` (which the CLI's `settings.remote_settings()` calls,
/// `clone.rs:231` @ v0.46.0) read off the stack directly: EVERY remote's entry is read, so a
/// malformed entry of any remote refuses, as in the CLI; then `remote`'s entry, `None` without
/// one.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a `remotes.<name>` entry is not a table of the known string keys.
pub(crate) fn remote_settings(
    config: &StackedConfig,
    remote: &str,
) -> Result<Option<jj_lib::settings::RemoteSettings>, ConfigError> {
    let mut found = None;
    let names: Vec<String> = config.table_keys("remotes").map(str::to_owned).collect();
    for name in names {
        let settings: jj_lib::settings::RemoteSettings =
            config.get(["remotes", name.as_str()]).map_err(|e| value_error(&e))?;
        if name == remote {
            found = Some(settings);
        }
    }
    Ok(found)
}

/// Reads the effective `split.legacy-bookmark-behavior` (Story 9.15) — the CLI's
/// `tx.settings().get_bool("split.legacy-bookmark-behavior")` in `jj split`
/// (`cli/src/commands/split.rs:502` @ v0.46.0), read only for a split WITHOUT `-o`/`-A`/`-B`.
/// Its default `true` is [`BUILTIN_CONFIG_TOML`]'s (the CLI's `config/misc.toml:67-68`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — the value is not a boolean (the key is named), or is missing from
///   every layer (impossible while the builtin layer is present).
pub(crate) fn split_legacy_bookmark_behavior(config: &StackedConfig) -> Result<bool, ConfigError> {
    config
        .get("split.legacy-bookmark-behavior")
        .map_err(|e| value_error(&e))
}

/// Reads the effective `experimental-advance-branches.enabled-branches` and `.disabled-branches`
/// (Story 9.49), in that order — the two `settings.get::<Vec<String>>` of the CLI's
/// `load_advance_bookmarks_matcher` (`cli/src/cli_util.rs:921-940` @ v0.46.0). Their defaults,
/// both empty, are [`BUILTIN_CONFIG_TOML`]'s (the CLI's `config/misc.toml:20-22`).
///
/// # Errors
///
/// - [`ConfigError::Load`] — a value is not a list of strings (the key is named), or is missing
///   from every layer (impossible while the builtin layer is present).
pub(crate) fn advance_branches(config: &StackedConfig) -> Result<(Vec<String>, Vec<String>), ConfigError> {
    let enabled = config
        .get("experimental-advance-branches.enabled-branches")
        .map_err(|e| value_error(&e))?;
    let disabled = config
        .get("experimental-advance-branches.disabled-branches")
        .map_err(|e| value_error(&e))?;
    Ok((enabled, disabled))
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

/// The repo-level presets `jj git clone` and `jj git init` write — the fields of the CLI's
/// `RepoPresets` (`cli/src/commands/git/mod.rs:135-153` @ v0.46.0).
#[derive(Debug, Clone, Copy)]
pub(crate) struct RepoPresets<'a> {
    /// The remote the fetch presets belong to.
    pub(crate) remote: &'a str,
    /// `remotes.<remote>.fetch-bookmarks` — clone's `-b` texts (`Some(&[])` when only `-t` was
    /// given); `None` writes nothing.
    pub(crate) fetch_bookmarks: Option<&'a [String]>,
    /// `remotes.<remote>.fetch-tags` — clone's `-t` texts, as above.
    pub(crate) fetch_tags: Option<&'a [String]>,
    /// `revset-aliases.'trunk()'` — the rendered `<bookmark>@<remote>` symbol.
    pub(crate) trunk: Option<&'a str>,
}

impl RepoPresets<'_> {
    /// Whether nothing is to be written — the CLI's `is_default` (`mod.rs:143-153`).
    fn is_default(self) -> bool {
        self.fetch_bookmarks.is_none() && self.fetch_tags.is_none() && self.trunk.is_none()
    }
}

/// The CLI's `join_string_expressions` (`cli/src/commands/git/mod.rs:276-281` @ v0.46.0): the
/// texts joined by `" | "` (no parentheses — `|` is the weakest operator), `"~*"` (no matches)
/// for an empty list.
fn join_string_expressions(exprs: &[String]) -> String {
    if exprs.is_empty() {
        "~*".to_owned()
    } else {
        exprs.join(" | ")
    }
}

/// Saves the presets to the repo-level config file — the CLI's `write_repo_presets`
/// (`cli/src/commands/git/mod.rs:155-193` @ v0.46.0) minus its `ui.status` line.
///
/// Default presets write nothing and do not even resolve the file — the CLI's "Don't initialize
/// config directory" early return — which is why the file comes from `file`, a loader called
/// only when something is to be written ([`new_repo_config_file`] in production). The loader's
/// `None` (no `<config_dir>` could be determined) is the CLI's "couldn't find the user's home
/// directory" skip: nothing is written.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the loader failed, or the file could not be written back.
pub(crate) fn write_repo_presets(
    file: impl FnOnce() -> Result<Option<ConfigFile>, ConfigError>,
    presets: RepoPresets<'_>,
) -> Result<(), ConfigError> {
    if presets.is_default() {
        return Ok(());
    }
    let Some(mut file) = file()? else {
        return Ok(());
    };
    if let Some(exprs) = presets.fetch_bookmarks {
        file.set_value(
            ["remotes", presets.remote, "fetch-bookmarks"],
            join_string_expressions(exprs),
        )
        .map_err(write_error)?;
    }
    if let Some(exprs) = presets.fetch_tags {
        file.set_value(
            ["remotes", presets.remote, "fetch-tags"],
            join_string_expressions(exprs),
        )
        .map_err(write_error)?;
    }
    if let Some(symbol) = presets.trunk {
        file.set_value(TRUNK_CONFIG_NAME, symbol).map_err(write_error)?;
    }
    save_config_file(&file)
}

/// Writes `revset-aliases.'trunk()' = <symbol>` — the one preset `jj git init`'s External flow
/// sets (`maybe_set_repository_level_trunk_alias`): [`write_repo_presets`] with the trunk alone.
///
/// `file` is [`new_repo_config_file`]'s answer: `None` means no `<config_dir>` could be
/// determined, and then this is a no-op that creates nothing.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the file could not be written back.
pub(crate) fn set_trunk_alias(file: Option<ConfigFile>, symbol: &str) -> Result<(), ConfigError> {
    write_repo_presets(
        || Ok(file),
        RepoPresets {
            remote: "",
            fetch_bookmarks: None,
            fetch_tags: None,
            trunk: Some(symbol),
        },
    )
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
        fix_up_layers, fix_up_secure_config, git_import_options, is_valid_config_id, load_repo_config_file, load_with,
        platform_config_dir, remove_remote_from_repo_config, rename_remote_in_repo_config, secure_config_path,
        set_trunk_alias, settings_from, snapshot_auto_track, snapshot_max_new_file_size,
        split_legacy_bookmark_behavior, stamp, system_config_paths, user_config_paths, user_email, ConfigEnv,
        SecureLayer, WorkspacePaths, BUILTIN_CONFIG_TOML, CLI_DEFAULTS,
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

    /// Stories 9.51 and 9.54: every jj-cli default layer is in the stack, below Zanshin's builtin
    /// layer — the template aliases (the draft template included), the `templates.*` keys, the
    /// diff options the engine reads and the keys no verb reads (`ui.color`), with jj-cli's
    /// values; `revsets.log` keeps Zanshin's.
    /// Story 9.54 review: the builtin layer sits ABOVE jj-cli's defaults, so a key there that
    /// drifted from jj-cli's value after a pin bump would silently override it. Every builtin key
    /// must equal jj-cli's default — except `revsets.log`, Zanshin's deliberate expansion.
    #[test]
    fn every_builtin_key_repeats_jj_clis_default_except_revsets_log() {
        fn leaves(table: &jj_lib::config::ConfigTableLike<'_>, path: &mut Vec<String>, out: &mut Vec<Vec<String>>) {
            for (key, item) in table.iter() {
                path.push(key.to_owned());
                match item.as_table_like() {
                    Some(sub) => leaves(sub, path, out),
                    None => out.push(path.clone()),
                }
                path.pop();
            }
        }
        fn normalized(value: &jj_lib::config::ConfigValue) -> String {
            value.as_str().map_or_else(
                || {
                    let mut value = value.clone();
                    value.decor_mut().clear();
                    value.to_string()
                },
                |text| format!("{text:?}"),
            )
        }
        let builtin = ConfigLayer::parse(ConfigSource::Default, BUILTIN_CONFIG_TOML).expect("parses");
        let mut cli = StackedConfig::empty();
        for layer in CLI_DEFAULTS.iter() {
            cli.add_layer(std::sync::Arc::clone(layer));
        }
        let mut paths = Vec::new();
        leaves(builtin.data.as_table(), &mut Vec::new(), &mut paths);
        assert!(paths.len() > 20, "{paths:?}");
        for path in paths {
            if path == ["revsets", "log"] {
                continue;
            }
            let keys: Vec<&str> = path.iter().map(String::as_str).collect();
            let ours = builtin
                .look_up_item(keys.as_slice())
                .expect("a value")
                .and_then(|item| item.as_value())
                .expect("present");
            let theirs = cli
                .get_value(keys.as_slice())
                .unwrap_or_else(|e| panic!("{path:?}: {e}"));
            assert_eq!(normalized(ours), normalized(&theirs), "{path:?}");
        }
    }

    #[test]
    fn every_jj_cli_default_layer_sits_below_the_builtin_layer() {
        assert_eq!(CLI_DEFAULTS.len(), jj_cli::config::default_config_layers().len());
        assert!(CLI_DEFAULTS.iter().all(|layer| layer.source == ConfigSource::Default));
        let config = load_with(&bare_env(), None).expect("loads");
        let layers = config.layers();
        let builtin = layers
            .iter()
            .position(|layer| {
                layer
                    .look_up_item(["revsets", "log"])
                    .ok()
                    .flatten()
                    .and_then(|i| i.as_str())
                    == Some("present(@) | ancestors(immutable_heads().., 2) | trunk()")
            })
            .expect("the builtin layer");
        let cli = layers
            .iter()
            .position(|layer| layer.look_up_table("template-aliases").ok().flatten().is_some())
            .expect("a jj-cli layer");
        assert!(cli < builtin, "jj-cli's defaults sit below Zanshin's builtin layer");

        let aliases = config.get_table("template-aliases").expect("a table");
        assert!(aliases.contains_key("builtin_draft_commit_description"));
        assert_eq!(
            aliases
                .get("default_commit_description")
                .and_then(jj_lib::config::ConfigItem::as_str),
            Some("\"\"")
        );
        assert!(aliases.contains_key("format_signed_off_by_trailer(commit)"));
        assert_eq!(config.get::<i64>("diff.git.context").expect("an integer"), 3);
        assert!(config.get::<i64>("diff.color-words.max-inline-alternation").is_ok());
        assert_eq!(config.get::<String>("ui.color").expect("a string"), "auto");
        assert_eq!(
            config
                .get::<String>("templates.duplicate_description")
                .expect("a string"),
            "description"
        );
        assert_eq!(
            config.get::<String>("revsets.log").expect("a string"),
            "present(@) | ancestors(immutable_heads().., 2) | trunk()"
        );
        assert_eq!(super::templates_commit_trailers(&config).expect("string"), "");
        assert_eq!(super::templates_new_description(&config).expect("string"), "");
        assert_eq!(
            super::templates_draft_commit_description(&config).expect("string"),
            "builtin_draft_commit_description"
        );
        assert_eq!(
            super::templates_git_push_bookmark(&config).expect("string"),
            r#""push-" ++ change_id.short()"#
        );
    }

    /// Story 9.51: `revsets.short-prefixes` falls back to `revsets.log` only when ABSENT.
    #[test]
    fn short_prefixes_falls_back_to_the_log_revset_only_when_absent() {
        let mut config = load_with(&bare_env(), None).expect("loads");
        assert_eq!(
            super::revsets_short_prefixes(&config).expect("string"),
            "present(@) | ancestors(immutable_heads().., 2) | trunk()"
        );
        let mut user = ConfigLayer::empty(ConfigSource::User);
        user.set_value("revsets.short-prefixes", "").expect("set");
        config.add_layer(user);
        assert_eq!(super::revsets_short_prefixes(&config).expect("string"), "");
        let mut bad = ConfigLayer::empty(ConfigSource::User);
        bad.set_value("revsets.short-prefixes", 1).expect("set");
        config.add_layer(bad);
        assert!(super::revsets_short_prefixes(&config).is_err());
    }

    /// Story 9.36: everything `from_env` derives comes from ONE environment snapshot — a
    /// non-UTF-8 value stays out of `environment`, a non-UTF-8 `JJ_CONFIG` counts as unset (the
    /// CLI's UTF-8 `var(..).ok()`), and `$USER` backs a missing `whoami` username.
    #[test]
    fn the_config_env_is_derived_from_one_environment_snapshot() {
        use std::os::unix::ffi::OsStringExt as _;

        let snapshot = |vars: &[(&str, OsString)]| -> crate::environment::EnvMap {
            vars.iter().map(|(k, v)| (OsString::from(k), v.clone())).collect()
        };
        let raw = OsString::from_vec(vec![b'x', 0xff]);
        let vars = snapshot(&[
            ("HOME", OsString::from("/nonexistent-zanshin-home")),
            ("XDG_CONFIG_HOME", OsString::from("/xdg")),
            ("USER", OsString::from("env-user")),
            ("JJ_CONFIG", raw.clone()),
            ("RAW", raw),
        ]);
        let env = ConfigEnv::from_vars(&vars, Some("host".to_owned()), None);
        assert_eq!(env.home_dir.as_deref(), Some(Path::new("/nonexistent-zanshin-home")));
        assert_eq!(env.config_dir.as_deref(), Some(Path::new("/xdg")));
        assert_eq!(env.jj_config, None, "a non-UTF-8 JJ_CONFIG counts as unset");
        assert_eq!(env.hostname.as_deref(), Some("host"));
        assert_eq!(env.username.as_deref(), Some("env-user"), "the $USER fallback");
        assert_eq!(env.environment.get("USER").map(String::as_str), Some("env-user"));
        assert!(
            !env.environment.contains_key("RAW") && !env.environment.contains_key("JJ_CONFIG"),
            "non-UTF-8 values are dropped: {:?}",
            env.environment
        );

        let pinned = snapshot(&[("JJ_CONFIG", OsString::new()), ("USER", OsString::from("env-user"))]);
        let env = ConfigEnv::from_vars(&pinned, None, Some("whoami-user".to_owned()));
        assert_eq!(env.jj_config, Some(OsString::new()), "an empty JJ_CONFIG is set");
        assert_eq!(env.username.as_deref(), Some("whoami-user"), "whoami wins over $USER");
        assert_eq!((env.home_dir, env.config_dir), (None, None));
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

    /// Story 9.15: `split.legacy-bookmark-behavior` defaults to the CLI's `true`, a user's
    /// `false` wins, and a wrong type refuses naming the key.
    #[test]
    fn split_legacy_bookmark_behavior_defaults_true_and_reads_the_user_layer() {
        let config = load_with(&bare_env(), None).expect("the bare stack loads");
        assert!(split_legacy_bookmark_behavior(&config).expect("builtin bool"));
        let off = stack_with("split.legacy-bookmark-behavior = false");
        assert!(!split_legacy_bookmark_behavior(&off).expect("user bool"));
        let wrong = stack_with("split.legacy-bookmark-behavior = \"yes\"");
        let super::ConfigError::Load { reason } = split_legacy_bookmark_behavior(&wrong).expect_err("not a bool");
        assert!(reason.contains("split.legacy-bookmark-behavior"), "{reason}");
    }

    /// Story 9.49: both advance lists default to the CLI's `[]`, a user's list wins, and a
    /// wrong type refuses naming the key.
    #[test]
    fn advance_branches_default_empty_and_read_the_user_layer() {
        let config = load_with(&bare_env(), None).expect("the bare stack loads");
        assert_eq!(
            super::advance_branches(&config).expect("builtin lists"),
            (vec![], vec![])
        );
        let set = stack_with("experimental-advance-branches.enabled-branches = [\"*\"]\nexperimental-advance-branches.disabled-branches = [\"main\"]");
        assert_eq!(
            super::advance_branches(&set).expect("user lists"),
            (vec!["*".to_owned()], vec!["main".to_owned()])
        );
        let wrong = stack_with("experimental-advance-branches.enabled-branches = \"*\"");
        let super::ConfigError::Load { reason } = super::advance_branches(&wrong).expect_err("not a list");
        assert!(
            reason.contains("experimental-advance-branches.enabled-branches"),
            "{reason}"
        );
        let wrong = stack_with("experimental-advance-branches.disabled-branches = 1");
        let super::ConfigError::Load { reason } = super::advance_branches(&wrong).expect_err("not a list");
        assert!(
            reason.contains("experimental-advance-branches.disabled-branches"),
            "{reason}"
        );
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

        let without = load_with(&env, None).expect("the start-up stack must load");
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
        let err = settings_from(&bare_env(), config).expect_err("a non-string user.name must refuse");
        assert!(err.to_string().contains("user.name"), "got: {err}");

        let settings = settings_from(&bare_env(), StackedConfig::with_defaults()).expect("jj-lib defaults are valid");
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
    // ordering, the same-session read-back) live in `tests/it/git_remotes.rs`.

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
    /// `tests/it/git_remotes.rs::without_a_repo_config_file_both_verbs_succeed_and_create_none`.
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
    // `tests/it/convert.rs` and `tests/it/convert_alias_write_failure.rs`.

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
        let repo = crate::Repo::init(&crate::InitOptions {
            path: std::path::PathBuf::from(tmp.path()),
            ..Default::default()
        })
        .result
        .expect("init");
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

    // ── The start-up secure-config fix-up (Story 9.37) ──────────────────────────
    //
    // The mechanism over explicit environments — no process env: order, refusals, the no-config-dir
    // skip and the state-based kinds. The public-API rows live in `tests/it/secure_config_fixups.rs`.

    /// A workspace at `<tmp>/<name>` whose `.jj/repo` holds `repo_body` as the LEGACY repo config
    /// (and `.jj` `ws_body` as the legacy workspace config, when given); the env's `<config_dir>` is
    /// `<tmp>/cfg`. Returns `(env, repo dir, workspace root)`.
    fn legacy_workspace(
        tmp: &Path,
        name: &str,
        repo_body: &str,
        ws_body: Option<&str>,
    ) -> (ConfigEnv, PathBuf, PathBuf) {
        let root = tmp.join(name);
        let repo = root.join(".jj").join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        std::fs::write(repo.join("config.toml"), repo_body).unwrap();
        if let Some(body) = ws_body {
            std::fs::write(root.join(".jj").join("workspace-config.toml"), body).unwrap();
        }
        let env = ConfigEnv {
            config_dir: Some(tmp.join("cfg")),
            ..bare_env()
        };
        (env, repo, root)
    }

    fn kinds(warnings: &[crate::Warning]) -> Vec<crate::WarningKind> {
        warnings.iter().map(|w| w.kind).collect()
    }

    /// Both legacy files migrate, repo FIRST: each gets its own id and secure file, keeps its
    /// bytes, and the legacy path becomes a symlink to the new file.
    #[test]
    fn the_fix_up_migrates_the_repo_then_the_workspace_layer() {
        let tmp = tempfile::tempdir().unwrap();
        let (env, repo, root) = legacy_workspace(tmp.path(), "ws", "[a]\nb = 1\n", Some("[c]\nd = 2\n"));
        let mut sink = Vec::new();
        fix_up_secure_config(&env, paths(&repo, &root), &mut sink).expect("the fix-up runs");

        assert_eq!(
            kinds(&sink),
            [crate::WarningKind::ConfigMigrated, crate::WarningKind::ConfigMigrated]
        );
        let repo_id = std::fs::read_to_string(repo.join("config-id")).expect("repo id");
        let ws_id = std::fs::read_to_string(root.join(".jj").join("workspace-config-id")).expect("ws id");
        let repo_file = tmp.path().join("cfg/jj/repos").join(&repo_id).join("config.toml");
        let ws_file = tmp.path().join("cfg/jj/workspaces").join(&ws_id).join("config.toml");
        assert_eq!(std::fs::read_to_string(&repo_file).unwrap(), "[a]\nb = 1\n");
        assert_eq!(std::fs::read_to_string(&ws_file).unwrap(), "[c]\nd = 2\n");
        assert_eq!(
            sink[0].message,
            format!(
                "Your config file has been migrated from {} to {}. You can edit the new file with `jj config edit`",
                repo.join("config.toml").display(),
                repo_file.display()
            )
        );
        assert!(sink[1].message.contains("workspace-config.toml"), "{}", sink[1].message);
        assert_eq!(std::fs::read_link(repo.join("config.toml")).unwrap(), repo_file);

        let mut again = Vec::new();
        fix_up_secure_config(&env, paths(&repo, &root), &mut again).expect("a second pass runs");
        assert!(again.is_empty(), "nothing left to fix: {again:?}");
    }

    /// The system and user layers load FIRST: a broken user file refuses before any fix-up.
    #[test]
    fn a_broken_user_file_refuses_before_any_fix_up() {
        let tmp = tempfile::tempdir().unwrap();
        let (env, repo, root) = legacy_workspace(tmp.path(), "ws", "[a]\nb = 1\n", None);
        let user = tmp.path().join("user.toml");
        std::fs::write(&user, "not toml [").unwrap();
        let env = ConfigEnv {
            jj_config: Some(user.into_os_string()),
            ..env
        };
        let mut sink = Vec::new();
        let err = fix_up_secure_config(&env, paths(&repo, &root), &mut sink).expect_err("the user file refuses");
        assert!(err.to_string().contains("user.toml"), "{err}");
        assert!(sink.is_empty());
        assert!(!repo.join("config-id").exists(), "nothing was migrated");
        assert!(std::fs::symlink_metadata(repo.join("config.toml")).unwrap().is_file());
    }

    /// A broken repo file refuses AFTER the repo fix-up (which already migrated it) and BEFORE the
    /// workspace's; the migration's warning stays in the sink.
    #[test]
    fn a_broken_repo_file_refuses_after_its_fix_up_and_before_the_workspace_one() {
        let tmp = tempfile::tempdir().unwrap();
        let (env, repo, root) = legacy_workspace(tmp.path(), "ws", "not toml [", Some("[c]\nd = 2\n"));
        let mut sink = Vec::new();
        let err = fix_up_secure_config(&env, paths(&repo, &root), &mut sink).expect_err("the repo file refuses");
        assert!(err.to_string().contains("cfg/jj/repos"), "the NEW file is named: {err}");
        assert_eq!(kinds(&sink), [crate::WarningKind::ConfigMigrated]);
        assert!(repo.join("config-id").exists());
        assert!(
            !root.join(".jj").join("workspace-config-id").exists(),
            "the workspace was not reached"
        );
    }

    /// A malformed id file keeps the read side's path-named refusal, and nothing is written.
    #[test]
    fn a_malformed_id_refuses_naming_the_id_file_and_writes_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let (env, repo, root) = legacy_workspace(tmp.path(), "ws", "", None);
        std::fs::write(repo.join("config-id"), "xyz").unwrap();
        let mut sink = Vec::new();
        let err = fix_up_layers(&env, paths(&repo, &root), &mut sink).expect_err("a malformed id refuses");
        let reason = err.to_string();
        assert!(
            reason.contains("config-id") && reason.contains("invalid config ID"),
            "{reason}"
        );
        assert!(sink.is_empty());
        assert!(!tmp.path().join("cfg").exists(), "nothing created under <config_dir>");
    }

    /// No `<config_dir>` known: nothing runs, as the CLI's `load_secure_config` returns `None`.
    #[test]
    fn without_a_config_dir_nothing_is_fixed_up() {
        let tmp = tempfile::tempdir().unwrap();
        let (env, repo, root) = legacy_workspace(tmp.path(), "ws", "[a]\nb = 1\n", Some(""));
        let env = ConfigEnv {
            config_dir: None,
            ..env
        };
        let mut sink = Vec::new();
        fix_up_secure_config(&env, paths(&repo, &root), &mut sink).expect("no fix-up is no error");
        fix_up_layers(&env, paths(&repo, &root), &mut sink).expect("no fix-up is no error");
        assert!(sink.is_empty());
        assert!(!repo.join("config-id").exists());
        assert!(!root.join(".jj").join("workspace-config-id").exists());
    }

    /// A jj-lib failure other than a bad id is the CLI's "Failed to determine the secure config
    /// for a repo" — here a `<config_dir>` that is a regular file, so nothing can be created in it.
    #[test]
    fn a_fix_up_that_cannot_write_is_the_clis_secure_config_error() {
        let tmp = tempfile::tempdir().unwrap();
        let (env, repo, root) = legacy_workspace(tmp.path(), "ws", "[a]\nb = 1\n", None);
        std::fs::write(tmp.path().join("cfg"), "a file, not a dir").unwrap();
        let mut sink = Vec::new();
        let err = fix_up_layers(&env, paths(&repo, &root), &mut sink).expect_err("an uncreatable dir refuses");
        assert!(
            err.to_string()
                .starts_with("config error: Failed to determine the secure config for a repo: "),
            "{err}"
        );
        assert!(sink.is_empty());
    }

    /// The kind comes from the id file's STATE: a copy forks under a NEW id (`ConfigCopied`), a
    /// move re-points the metadata silently, and a deleted secure dir comes back under the SAME
    /// id (`ConfigRegenerated`).
    #[test]
    fn copied_moved_and_regenerated_are_told_apart_by_the_id_file() {
        let tmp = tempfile::tempdir().unwrap();
        let (env, repo_a, root_a) = legacy_workspace(tmp.path(), "a", "[a]\nb = 1\n", None);
        fix_up_layers(&env, paths(&repo_a, &root_a), &mut Vec::new()).expect("A migrates");
        let id_a = std::fs::read_to_string(repo_a.join("config-id")).unwrap();
        let repos = tmp.path().join("cfg/jj/repos");

        // Copied: B carries A's id while A still exists.
        let root_b = tmp.path().join("b");
        let repo_b = root_b.join(".jj").join("repo");
        std::fs::create_dir_all(&repo_b).unwrap();
        std::fs::write(repo_b.join("config-id"), &id_a).unwrap();
        let mut sink = Vec::new();
        fix_up_layers(&env, paths(&repo_b, &root_b), &mut sink).expect("B forks");
        assert_eq!(kinds(&sink), [crate::WarningKind::ConfigCopied]);
        let id_b = std::fs::read_to_string(repo_b.join("config-id")).unwrap();
        assert_ne!(id_b, id_a);
        assert_eq!(
            std::fs::read_to_string(repos.join(&id_b).join("config.toml")).unwrap(),
            "[a]\nb = 1\n"
        );

        // Moved: A renamed to C — no warning, the metadata now records C, the id unchanged.
        let root_c = tmp.path().join("c");
        std::fs::rename(&root_a, &root_c).unwrap();
        let repo_c = root_c.join(".jj").join("repo");
        let mut sink = Vec::new();
        fix_up_layers(&env, paths(&repo_c, &root_c), &mut sink).expect("C re-points");
        assert!(sink.is_empty(), "{sink:?}");
        assert_eq!(std::fs::read_to_string(repo_c.join("config-id")).unwrap(), id_a);
        let metadata = jj_lib::secure_config::read_metadata(&repos.join(&id_a)).unwrap();
        assert_eq!(
            jj_lib::secure_config::metadata_path(&metadata).unwrap(),
            Some(repo_c.as_path())
        );

        // Regenerated: C's secure dir deleted — back under the same id, with jj-lib's notice.
        std::fs::remove_dir_all(repos.join(&id_a)).unwrap();
        let mut sink = Vec::new();
        fix_up_layers(&env, paths(&repo_c, &root_c), &mut sink).expect("C regenerates");
        assert_eq!(kinds(&sink), [crate::WarningKind::ConfigRegenerated]);
        assert!(sink[0]
            .message
            .starts_with("Per-repo config not found. Generating an empty one."));
        assert!(repos.join(&id_a).join("metadata.binpb").exists());
        assert_eq!(std::fs::read_to_string(repo_c.join("config-id")).unwrap(), id_a);
    }

    // ── Story 9.20 readers ───────────────────────────────────────────────────

    #[test]
    fn git_object_hash_reads_both_hashes_and_refuses_another() {
        let builtin = load_with(&bare_env(), None).expect("the bare stack loads");
        assert!(matches!(super::git_object_hash(&builtin), Ok(crate::ObjectHash::Sha1)));
        let sha256 = stack_with("git.object-hash = \"sha256\"\n");
        assert!(matches!(super::git_object_hash(&sha256), Ok(crate::ObjectHash::Sha256)));
        let md5 = stack_with("git.object-hash = \"md5\"\n");
        assert!(super::git_object_hash(&md5).is_err());
    }

    #[test]
    fn git_push_remotes_reads_a_list_a_string_or_nothing() {
        let unset = load_with(&bare_env(), None).expect("the bare stack loads");
        assert_eq!(super::git_push_remotes(&unset).unwrap(), None);
        let list = stack_with("git.push = [\"a\", \"b\"]\n");
        assert_eq!(
            super::git_push_remotes(&list).unwrap(),
            Some(vec!["a".to_owned(), "b".to_owned()])
        );
        let text = stack_with("git.push = \"up\"\n");
        assert_eq!(super::git_push_remotes(&text).unwrap(), Some(vec!["up".to_owned()]));
        let wrong = stack_with("git.push = 1\n");
        assert!(super::git_push_remotes(&wrong).is_err());
    }

    // ── Story 9.30 readers ───────────────────────────────────────────────────

    #[test]
    fn git_fetch_remotes_reads_a_list_a_string_or_nothing() {
        let unset = load_with(&bare_env(), None).expect("the bare stack loads");
        assert_eq!(super::git_fetch_remotes(&unset).unwrap(), None);
        let list = stack_with("git.fetch = [\"up\", \"origin\"]\n");
        assert_eq!(
            super::git_fetch_remotes(&list).unwrap(),
            Some(vec!["up".to_owned(), "origin".to_owned()])
        );
        let text = stack_with("git.fetch = \"up\"\n");
        assert_eq!(super::git_fetch_remotes(&text).unwrap(), Some(vec!["up".to_owned()]));
        let wrong = stack_with("git.fetch = 1\n");
        assert!(super::git_fetch_remotes(&wrong).is_err());
        assert_eq!(
            super::git_push_remotes(&text).unwrap(),
            None,
            "git.fetch is not git.push"
        );
    }

    #[test]
    fn remote_fetch_expression_parses_the_named_field_or_reports_none() {
        use super::{remote_fetch_expression, FetchField};
        use jj_lib::ref_name::RemoteName;

        let config = stack_with("[remotes.origin]\nfetch-bookmarks = \"main | feat*\"\nfetch-tags = \"v*\"\n");
        let origin = RemoteName::new("origin");
        let bookmarks = remote_fetch_expression(&config, origin, FetchField::Bookmarks)
            .unwrap()
            .expect("set")
            .to_matcher();
        assert!(bookmarks.is_match("main") && bookmarks.is_match("feat1") && !bookmarks.is_match("other"));
        let tags = remote_fetch_expression(&config, origin, FetchField::Tags)
            .unwrap()
            .expect("set")
            .to_matcher();
        assert!(tags.is_match("v1") && !tags.is_match("x1"));
        assert!(
            remote_fetch_expression(&config, RemoteName::new("up"), FetchField::Tags)
                .unwrap()
                .is_none()
        );
        let only_tags = stack_with("[remotes.origin]\nfetch-tags = \"v*\"\n");
        assert!(remote_fetch_expression(&only_tags, origin, FetchField::Bookmarks)
            .unwrap()
            .is_none());

        let broken = stack_with("[remotes.origin]\nfetch-bookmarks = \"glob:(\"\n");
        let result = remote_fetch_expression(&broken, origin, FetchField::Bookmarks);
        assert!(
            matches!(&result, Err(super::ConfigError::Load { reason })
                if reason.starts_with("Invalid `remotes.origin.fetch-bookmarks`: ")),
            "{result:?}"
        );
        assert!(
            remote_fetch_expression(&broken, origin, FetchField::Tags).is_ok(),
            "only the field asked for is parsed"
        );
    }

    #[test]
    fn remote_settings_reads_every_entry_and_returns_the_named_one() {
        let config = stack_with("[remotes.origin]\nfetch-bookmarks = \"main\"\n[remotes.up]\nfetch-tags = \"v*\"\n");
        let origin = super::remote_settings(&config, "origin")
            .unwrap()
            .expect("origin's entry");
        assert_eq!(origin.fetch_bookmarks.as_deref(), Some("main"));
        assert!(super::remote_settings(&config, "nope").unwrap().is_none());
        let broken = stack_with("[remotes]\nup = 1\n[remotes.origin]\nfetch-bookmarks = \"main\"\n");
        assert!(
            super::remote_settings(&broken, "origin").is_err(),
            "a malformed entry of any remote refuses"
        );
        assert!(
            git_import_options(&config).is_ok_and(|options| options.remote_auto_track_bookmarks.is_empty()),
            "an entry without auto-track-bookmarks tracks nothing"
        );
    }

    // ── Story 9.54 closing run: `bookmark create`'s auto-track matchers ──────

    #[test]
    fn new_bookmark_matchers_union_both_fields_per_remote_in_name_order() {
        let config = stack_with(concat!(
            "[remotes.zeta]\nauto-track-created-bookmarks = \"glob:z*\"\n",
            "[remotes.both]\nauto-track-bookmarks = \"glob:feat*\"\n",
            "auto-track-created-bookmarks = \"exact:other\"\n",
            "[remotes.plain]\nauto-track-bookmarks = \"glob:feat*\"\n",
            "[remotes.neither]\nfetch-tags = \"v*\"\n",
        ));
        let matchers = super::remote_auto_track_bookmarks_for_new_bookmarks(&config).unwrap();
        let names: Vec<&str> = matchers.keys().map(|name| name.as_str()).collect();
        assert_eq!(
            names,
            ["both", "plain", "zeta"],
            "name order; no entry without either field"
        );
        let both = &matchers[jj_lib::ref_name::RemoteName::new("both")];
        assert!(both.is_match("feature") && both.is_match("other") && !both.is_match("main"));
        let plain = &matchers[jj_lib::ref_name::RemoteName::new("plain")];
        assert!(plain.is_match("feature") && !plain.is_match("other"));
        let zeta = &matchers[jj_lib::ref_name::RemoteName::new("zeta")];
        assert!(zeta.is_match("zap") && !zeta.is_match("feature"));
        assert!(
            git_import_options(&config).is_ok_and(|options| options.remote_auto_track_bookmarks.len() == 2),
            "the import matchers still read `auto-track-bookmarks` alone"
        );
    }

    #[test]
    fn new_bookmark_matchers_refuse_a_broken_field_with_the_cli_text() {
        let created = stack_with("[remotes.origin]\nauto-track-created-bookmarks = \"(\"\n");
        let result = super::remote_auto_track_bookmarks_for_new_bookmarks(&created);
        assert!(
            matches!(&result, Err(crate::ConfigError::Load { reason })
                if reason.starts_with("Invalid `remotes.origin.auto-track-created-bookmarks`: ")),
            "a broken auto-track-created-bookmarks refuses: {result:?}"
        );
        assert!(
            git_import_options(&created).is_ok(),
            "the import options never read auto-track-created-bookmarks"
        );
        let plain = stack_with("[remotes.origin]\nauto-track-bookmarks = \"(\"\n");
        let result = super::remote_auto_track_bookmarks_for_new_bookmarks(&plain);
        assert!(
            matches!(&result, Err(crate::ConfigError::Load { reason })
                if reason.starts_with("Invalid `remotes.origin.auto-track-bookmarks`: ")),
            "a broken auto-track-bookmarks refuses: {result:?}"
        );
        let entry = stack_with("[remotes]\norigin = 1\n");
        assert!(super::remote_auto_track_bookmarks_for_new_bookmarks(&entry).is_err());
    }
}
