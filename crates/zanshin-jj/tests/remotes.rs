// SPDX-License-Identifier: MIT

use std::env;
use std::fs;
use std::sync::LazyLock;

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::git;
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::repo::StoreFactories;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::{default_working_copy_factories, Workspace};
use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{Backend, RemoteError, Repo};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

fn make_test_settings() -> UserSettings {
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
        .expect("valid config literal"),
    );
    UserSettings::from_config(config).expect("valid settings")
}

fn oracle_workspace(root: &std::path::Path) -> (Workspace, UserSettings) {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        root,
        &StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    (workspace, settings)
}

/// Register `(name, url)` remotes, reloading the workspace between each add.
///
/// `git::add_remote` calls `save_git_config()` which writes from the gix
/// in-memory config to disk but does NOT accumulate across calls on the same
/// workspace instance. Reloading between adds ensures each call reads the
/// current disk state (including all previously added remotes).
fn add_remotes(root: &std::path::Path, remotes: &[(&str, &str)]) {
    for (name, url) in remotes {
        let (ws, _) = oracle_workspace(root);
        let base = pollster::block_on(ws.repo_loader().load_at_head()).expect("load_at_head");
        let mut tx = base.start_transaction();
        let remote_name_buf: RemoteNameBuf = (*name).into();
        let remote_name: &RemoteName = &remote_name_buf;
        git::add_remote(tx.repo_mut(), remote_name, url, None, gix::remote::fetch::Tags::All)
            .unwrap_or_else(|e| panic!("add_remote({name}) failed: {e}"));
        pollster::block_on(tx.commit(&format!("test: add remote {name}"))).expect("commit");
    }
}

// ── Empty on tiny ─────────────────────────────────────────────────────────────

#[test]
fn remotes_on_tiny_returns_empty() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let remotes = repo.list_remotes().unwrap();
    assert!(remotes.is_empty(), "tiny fixture has no remotes; got {remotes:?}");
}

// ── Empty on a healthy native backend ─────────────────────────────────────────

#[test]
fn remotes_on_native_backend_returns_empty() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    // `Repo::init(.., None)` uses jj's native backend (`init_simple`). A non-git
    // backend has no git remotes: `get_all_remote_names` yields
    // `UnexpectedGitBackendError`, which `unwrap_or_default` collapses to an empty
    // list — `Ok(vec![])`, not an error (FR-JJ-9 native-backend AC).
    Repo::init(tmp.path(), None).unwrap();

    let repo = Repo::open(tmp.path()).unwrap();
    let remotes = repo.list_remotes().unwrap();
    assert!(
        remotes.is_empty(),
        "native backend has no git remotes → empty list; got {remotes:?}"
    );
}

// ── Lists remotes sorted by name ──────────────────────────────────────────────

#[test]
fn remotes_lists_configured_remotes_sorted_by_name() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), Some(Backend::Git)).unwrap();

    // Added in reverse alphabetical order to verify sort is applied.
    add_remotes(
        tmp.path(),
        &[
            ("upstream", "ssh://git@github.com/upstream/repo.git"),
            ("origin", "https://github.com/origin/repo.git"),
            ("creds", "https://user:token@github.com/priv/repo.git"),
        ],
    );

    let repo = Repo::open(tmp.path()).unwrap();
    let remotes = repo.list_remotes().unwrap();

    let names: Vec<&str> = remotes.iter().map(|r| r.name.as_str()).collect();
    assert_eq!(
        names,
        ["creds", "origin", "upstream"],
        "remotes must be sorted by name; got {names:?}"
    );

    // AC-9 #18: origin's url matches the configured https URL verbatim.
    // Sorted order is [creds, origin, upstream] → origin is index 1.
    assert_eq!(remotes[1].url, "https://github.com/origin/repo.git");
}

// ── Embedded credentials are preserved verbatim ───────────────────────────────

#[test]
fn remotes_preserve_embedded_credentials() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), Some(Backend::Git)).unwrap();

    add_remotes(
        tmp.path(),
        &[("origin", "https://user:s3cr3t@github.com/priv/repo.git")],
    );

    let repo = Repo::open(tmp.path()).unwrap();
    let remotes = repo.list_remotes().unwrap();

    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    assert!(
        remotes[0].url.contains("s3cr3t"),
        "embedded password must be preserved verbatim (not 'redacted'), got: {}",
        remotes[0].url
    );
    assert!(
        remotes[0].url.contains("user:"),
        "embedded username must be preserved verbatim, got: {}",
        remotes[0].url
    );
}

// ── SSH URL form is not rewritten to HTTPS ────────────────────────────────────

#[test]
fn remotes_keep_ssh_form() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), Some(Backend::Git)).unwrap();

    // scp-like form (`git@host:path`) — the AC-named case (AC-6 #13 / AC-9 #18);
    // exercises gix's alternative-form serialisation branch (must stay ssh-ish,
    // never become https).
    add_remotes(tmp.path(), &[("origin", "git@github.com:user/repo.git")]);

    let repo = Repo::open(tmp.path()).unwrap();
    let remotes = repo.list_remotes().unwrap();

    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    assert!(
        !remotes[0].url.starts_with("https://"),
        "SSH URL must not be rewritten to HTTPS, got: {}",
        remotes[0].url
    );
    assert!(
        remotes[0].url.contains("github.com"),
        "host must be preserved, got: {}",
        remotes[0].url
    );
    assert!(
        remotes[0].url.contains("user/repo"),
        "path must be preserved, got: {}",
        remotes[0].url
    );
}

// ── Corrupt repo returns Backend error ────────────────────────────────────────

#[test]
fn remotes_on_corrupt_repo_returns_backend_error() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    // Native backend: list_remotes() still calls load_at_head() first, which will
    // fail when op_heads is removed → RemoteError::Backend.
    Repo::init(tmp.path(), None).unwrap();

    let repo = Repo::open(tmp.path()).unwrap();

    // Corrupt AFTER open: list_remotes() re-resolves to head per call (ADR-0002),
    // so removing op_heads makes load_at_head() fail → RemoteError::Backend.
    let op_heads = tmp.path().join(".jj").join("repo").join("op_heads");
    fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.list_remotes();
    assert!(
        matches!(result, Err(RemoteError::Backend(_))),
        "corrupt repo must yield Backend error, got: {result:?}"
    );
}
