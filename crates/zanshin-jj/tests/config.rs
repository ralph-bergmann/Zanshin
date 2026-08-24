// SPDX-License-Identifier: MIT

//! Fixture tests for the effective-config reads of Story 4.9: `Repo::log_defaults()` and
//! the repo/workspace config layers.
//!
//! Every row here works through the LEGACY secure-config files (`.jj/repo/config.toml`,
//! `.jj/workspace-config.toml`) written into an extracted fixture, so no test touches the
//! process-global `JJ_CONFIG` — that variable is pinned to `""` here and is repointed by
//! exactly one test, in its own binary (`tests/config_user_layer.rs`).
//!
//! The `config-id` indirection itself (id → `<config_dir>/jj/{repos,workspaces}/<id>/`)
//! is pinned by the inline unit tests of `src/config.rs`, which take the directories as
//! explicit arguments; here only its ERROR propagation is asserted.

use std::env;
use std::path::Path;
use std::sync::LazyLock;

use test_helpers::extract_fixture;
use zanshin_jj::{ConfigError, Repo, DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: empty string pins jj-lib/git off the developer's globals. For Story 4.9 this is
    // no longer defence in depth — it is the only thing keeping the developer's real
    // ~/.config/jj/config.toml out of the layer stack. `""` is SET, not unset, which is
    // exactly the CLI's documented way to disable user-config discovery.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// Writes `.jj/repo/config.toml` — the repo layer of an extracted fixture (which carries
/// no `config-id`, so the legacy path IS the repo layer).
fn write_repo_config(workspace_root: &Path, toml: &str) {
    std::fs::write(workspace_root.join(".jj").join("repo").join("config.toml"), toml).unwrap();
}

/// Writes `.jj/workspace-config.toml` — the workspace layer, which sits ABOVE the repo
/// layer at the pin (`ConfigSource::Workspace > ConfigSource::Repo`).
fn write_workspace_config(workspace_root: &Path, toml: &str) {
    std::fs::write(workspace_root.join(".jj").join("workspace-config.toml"), toml).unwrap();
}

// ── CAP-2: the four effective values ─────────────────────────────────────────

/// With no user/repo/workspace config, the four values are exactly the builtin defaults
/// Story 4.8 ships as Rust constants — the anti-drift check between the constants and the
/// builtin TOML layer, asserted end to end.
#[test]
fn log_defaults_without_overrides_returns_the_builtin_values() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let defaults = repo.log_defaults().unwrap();
    assert_eq!(defaults.log, DEFAULT_LOG_REVSET);
    assert_eq!(defaults.log_graph_prioritize, DEFAULT_GRAPH_PRIORITIZE);
    assert_eq!(
        defaults.short_prefixes, DEFAULT_LOG_REVSET,
        "revsets.short-prefixes is unset, so it falls back to revsets.log (CLI parity)"
    );
    assert!(defaults.synthetic_elided);
}

/// A repo-config override of `revsets.log` is returned — and `short_prefixes` follows it,
/// because the fallback reads the EFFECTIVE `revsets.log`, not the builtin one.
#[test]
fn a_revsets_log_override_is_returned_and_short_prefixes_follows_it() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    write_repo_config(
        &fx.path,
        "[revsets]\nlog = \"@\"\nlog-graph-prioritize = \"none()\"\n\n[ui]\nlog-synthetic-elided-nodes = false\n",
    );

    let defaults = repo.log_defaults().unwrap();
    assert_eq!(defaults.log, "@");
    assert_eq!(defaults.log_graph_prioritize, "none()");
    assert_eq!(defaults.short_prefixes, "@", "the fallback follows the OVERRIDDEN log");
    assert!(!defaults.synthetic_elided);
}

/// An explicit `revsets.short-prefixes` is returned verbatim — including the EMPTY string,
/// which means "disambiguation disabled" and must NOT be replaced by the `revsets.log`
/// fallback (the fallback triggers on ABSENCE only, `cli/src/cli_util.rs:991-995`).
#[test]
fn an_explicit_short_prefixes_is_returned_verbatim_including_empty() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    write_repo_config(&fx.path, "[revsets]\nshort-prefixes = \"trunk()\"\n");
    assert_eq!(repo.log_defaults().unwrap().short_prefixes, "trunk()");

    write_repo_config(&fx.path, "[revsets]\nshort-prefixes = \"\"\n");
    assert_eq!(
        repo.log_defaults().unwrap().short_prefixes,
        "",
        "an explicit empty value means DISABLED and must survive the fallback"
    );
}

/// The config stack is re-read per operation: the SAME handle sees an externally edited
/// config file on its next call.
#[test]
fn log_defaults_is_re_read_on_every_call() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    write_repo_config(&fx.path, "[revsets]\nlog = \"first\"\n");
    assert_eq!(repo.log_defaults().unwrap().log, "first");

    write_repo_config(&fx.path, "[revsets]\nlog = \"second\"\n");
    assert_eq!(repo.log_defaults().unwrap().log, "second");
}

// ── Layer precedence ─────────────────────────────────────────────────────────

/// `ConfigSource::Workspace` sits ABOVE `ConfigSource::Repo` at v0.42.0, so the workspace
/// file wins on a key both define.
#[test]
fn the_workspace_layer_wins_over_the_repo_layer() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    write_repo_config(&fx.path, "[revsets]\nlog = \"from-repo\"\n");
    assert_eq!(repo.log_defaults().unwrap().log, "from-repo");

    write_workspace_config(&fx.path, "[revsets]\nlog = \"from-workspace\"\n");
    assert_eq!(repo.log_defaults().unwrap().log, "from-workspace");
}

// ── Conditional scopes (`jj_lib::config::resolve`) ───────────────────────────

/// A `[[--scope]]` block whose `--when` matches must be FLATTENED into the layer.
///
/// This is the documented jj way to keep per-repo settings in one user config file, so
/// dropping the `resolve` call would silently ignore them — reproducing exactly the
/// CLI/Zanshin disagreement this story removes. Without `resolve`, the scoped value is
/// simply invisible and the builtin survives, so this test is what pins the call.
#[test]
fn a_matching_when_scope_is_flattened_into_the_layer() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    // The condition is a path PREFIX match against the workspace root, taken from the
    // repo itself so it matches whatever form jj-lib canonicalized it to.
    let root = repo.workspace_root().display().to_string();
    write_repo_config(
        &fx.path,
        &format!("[[--scope]]\n--when.workspaces = ['{root}']\n[--scope.revsets]\nlog = \"scoped\"\n"),
    );

    assert_eq!(
        repo.log_defaults().unwrap().log,
        "scoped",
        "a matching --when scope must be flattened into the layer"
    );
}

/// …and a `[[--scope]]` whose `--when` does NOT match is dropped, leaving the builtin.
#[test]
fn a_non_matching_when_scope_is_dropped() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    write_repo_config(
        &fx.path,
        "[[--scope]]\n--when.workspaces = ['/nonexistent/zanshin-scope-test']\n[--scope.revsets]\nlog = \"scoped\"\n",
    );

    assert_eq!(
        repo.log_defaults().unwrap().log,
        DEFAULT_LOG_REVSET,
        "a non-matching scope contributes nothing; the builtin survives"
    );
}

// ── Error rows ───────────────────────────────────────────────────────────────

/// A wrong-typed config value hard-errors, exactly as the CLI's `get_string` /
/// `get_bool` do — never a silent fall-back to the builtin value.
#[test]
fn a_wrong_typed_config_value_is_a_config_error_naming_the_key() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    write_repo_config(&fx.path, "[ui]\nlog-synthetic-elided-nodes = \"yes\"\n");
    let ConfigError::Load { reason } = repo.log_defaults().expect_err("a wrong-typed bool must hard-error");
    assert!(
        reason.contains("ui.log-synthetic-elided-nodes"),
        "the context must name the key, got: {reason}"
    );

    write_repo_config(&fx.path, "[revsets]\nlog = 42\n");
    let ConfigError::Load { reason } = repo.log_defaults().expect_err("a wrong-typed string must hard-error");
    assert!(
        reason.contains("revsets.log"),
        "the context must name the key, got: {reason}"
    );

    // `short-prefixes` is read through `.optional()`, which converts only NotFound to
    // `None` and RE-RAISES a type error — so the optional read must not swallow this.
    write_repo_config(&fx.path, "[revsets]\nshort-prefixes = 42\n");
    let ConfigError::Load { reason } = repo
        .log_defaults()
        .expect_err("a wrong-typed short-prefixes must hard-error, not fall back to revsets.log");
    assert!(
        reason.contains("revsets.short-prefixes"),
        "the context must name the key, got: {reason}"
    );
}

/// A malformed config file hard-errors with the file named — never a silent fall-back.
#[test]
fn a_malformed_config_file_is_a_config_error_naming_the_file() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    write_repo_config(&fx.path, "not = = toml");
    let ConfigError::Load { reason } = repo.log_defaults().expect_err("malformed TOML must hard-error");
    assert!(
        reason.contains("config.toml"),
        "the context must name the file, got: {reason}"
    );
}

/// A `config-id` that is not exactly 20 ASCII hex characters hard-errors, as jj-lib's own
/// `SecureConfig` does (`BadConfigIdError`) — reading on with the legacy file would use a
/// different config than the CLI.
#[test]
fn a_bad_config_id_is_a_config_error_naming_the_file() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    std::fs::write(fx.path.join(".jj").join("repo").join("config-id"), "not-twenty-hex").unwrap();
    let ConfigError::Load { reason } = repo.log_defaults().expect_err("a bad config-id must hard-error");
    assert!(
        reason.contains("config-id"),
        "the context must name the file, got: {reason}"
    );
}

/// The WORKSPACE secure config has the same id indirection (`.jj/workspace-config-id`), so
/// a malformed id there hard-errors too.
#[test]
fn a_bad_workspace_config_id_is_a_config_error_naming_the_file() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    std::fs::write(fx.path.join(".jj").join("workspace-config-id"), "not-twenty-hex").unwrap();
    let ConfigError::Load { reason } = repo
        .log_defaults()
        .expect_err("a bad workspace-config-id must hard-error");
    assert!(
        reason.contains("workspace-config-id"),
        "the context must name the file, got: {reason}"
    );
}
