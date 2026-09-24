// SPDX-License-Identifier: MIT

use std::env;
use std::fs;
use std::sync::LazyLock;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::git;
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{Backend, RemoteError, Repo};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
    env::set_var("JJ_USER", "Zanshin");
    env::set_var("JJ_EMAIL", "zanshin@localhost");
    env::set_var("JJ_OP_HOSTNAME", "localhost");
    env::set_var("JJ_OP_USERNAME", "zanshin");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

fn oracle_workspace(root: &std::path::Path) -> (Workspace, UserSettings) {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        root,
        &default_backend_factories(),
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
        git::add_remote(tx.repo_mut(), remote_name, url, None)
            .unwrap_or_else(|e| panic!("add_remote({name}) failed: {e}"));
        pollster::block_on(tx.commit(&format!("test: add remote {name}"))).expect("commit");
    }
}

// ── Empty on tiny ─────────────────────────────────────────────────────────────

#[test]
fn remotes_on_tiny_returns_empty() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
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
    Repo::init(tmp.path(), None).result.unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
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
    Repo::init(tmp.path(), Some(Backend::Git)).result.unwrap();

    // Added in reverse alphabetical order to verify sort is applied.
    add_remotes(
        tmp.path(),
        &[
            ("upstream", "ssh://git@github.com/upstream/repo.git"),
            ("origin", "https://github.com/origin/repo.git"),
            ("creds", "https://user:token@github.com/priv/repo.git"),
        ],
    );

    let mut repo = Repo::open(tmp.path()).unwrap();
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
    assert!(
        remotes.iter().all(|r| r.push_url.is_none()),
        "none of these remotes was given a push URL; got {remotes:?}"
    );
}

// ── push_url is reported when it differs, absent when it does not ─────────────

/// `git_remote_add(.., Some(push))` is the SHIPPED way to configure a push URL, so it is
/// what seeds this row — no raw `git config` writer, and no raw `git config --get
/// remote.<n>.pushurl` reader either: `list_remotes` now answers that question itself.
#[test]
fn remotes_report_a_distinct_push_url() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), Some(Backend::Git)).result.unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    repo.git_remote_add(
        "origin",
        "https://github.com/origin/repo.git",
        Some("ssh://git@github.com/origin/repo.git"),
    )
    .unwrap();

    let remotes = repo.list_remotes().unwrap();
    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    assert_eq!(remotes[0].url, "https://github.com/origin/repo.git");
    assert_eq!(
        remotes[0].push_url.as_deref(),
        Some("ssh://git@github.com/origin/repo.git")
    );
}

#[test]
fn remotes_without_a_push_url_report_none() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), Some(Backend::Git)).result.unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    repo.git_remote_add("origin", "https://github.com/origin/repo.git", None)
        .unwrap();

    let remotes = repo.list_remotes().unwrap();
    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    assert_eq!(
        remotes[0].push_url, None,
        "null-for-absence: a remote that pushes to its fetch URL reports None, never Some(\"\")"
    );
}

/// Every other push-URL row holds exactly ONE remote, so none of them can catch a build
/// loop that paired remote *n*'s push URL with remote *n+1* — or that read the push URLs in
/// insertion order while the rows come out sorted. This row seeds three remotes whose sorted
/// order (`alpha`, `mid`, `zulu`) is the REVERSE of their insertion order, gives the outer
/// two a distinct push URL and the middle one none, and asserts each row against its own
/// name.
#[test]
fn remotes_pair_each_push_url_with_its_own_remote() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), Some(Backend::Git)).result.unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    repo.git_remote_add(
        "zulu",
        "https://github.com/zulu/repo.git",
        Some("ssh://git@github.com/zulu/repo.git"),
    )
    .unwrap();
    repo.git_remote_add("mid", "https://github.com/mid/repo.git", None)
        .unwrap();
    repo.git_remote_add(
        "alpha",
        "https://github.com/alpha/repo.git",
        Some("ssh://git@github.com/alpha/repo.git"),
    )
    .unwrap();

    let remotes = repo.list_remotes().unwrap();
    let rows: Vec<(&str, &str, Option<&str>)> = remotes
        .iter()
        .map(|r| (r.name.as_str(), r.url.as_str(), r.push_url.as_deref()))
        .collect();
    assert_eq!(
        rows,
        [
            (
                "alpha",
                "https://github.com/alpha/repo.git",
                Some("ssh://git@github.com/alpha/repo.git")
            ),
            ("mid", "https://github.com/mid/repo.git", None),
            (
                "zulu",
                "https://github.com/zulu/repo.git",
                Some("ssh://git@github.com/zulu/repo.git")
            ),
        ],
        "each row's push URL must belong to that row's own remote"
    );
}

#[test]
fn remotes_report_a_push_url_added_later() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), Some(Backend::Git)).result.unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    repo.git_remote_add("origin", "https://github.com/origin/repo.git", None)
        .unwrap();
    repo.git_remote_set_url("origin", None, Some("ssh://git@github.com/origin/repo.git"))
        .unwrap();

    let remotes = repo.list_remotes().unwrap();
    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    assert_eq!(
        remotes[0].url, "https://github.com/origin/repo.git",
        "setting only the push URL must leave the fetch URL alone"
    );
    assert_eq!(
        remotes[0].push_url.as_deref(),
        Some("ssh://git@github.com/origin/repo.git")
    );
}

/// CLI parity: `jj git remote list` prints its `(push: …)` suffix only when the two URLs
/// DIFFER, so a `pushurl` byte-identical to `url` is reported as absent. This is also the
/// only reading gix supports — its `url(Direction::Push)` falls back to the fetch URL, so
/// "no pushurl" and "pushurl == url" are indistinguishable through the API.
#[test]
fn remotes_report_none_when_the_push_url_equals_the_fetch_url() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), Some(Backend::Git)).result.unwrap();

    let url = "https://github.com/origin/repo.git";
    let mut repo = Repo::open(tmp.path()).unwrap();
    repo.git_remote_add("origin", url, Some(url)).unwrap();

    let remotes = repo.list_remotes().unwrap();
    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    assert_eq!(remotes[0].url, url);
    assert_eq!(
        remotes[0].push_url, None,
        "a push URL equal to the fetch URL is not a DIFFERENCE, so it is absent"
    );
}

#[test]
fn remotes_preserve_embedded_credentials_in_the_push_url() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), Some(Backend::Git)).result.unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    repo.git_remote_add(
        "origin",
        "https://github.com/origin/repo.git",
        Some("https://user:s3cr3t@github.com/priv/repo.git"),
    )
    .unwrap();

    let remotes = repo.list_remotes().unwrap();
    let push = remotes[0].push_url.as_deref().expect("push URL must be reported");
    assert!(
        push.contains("user:s3cr3t"),
        "the push URL is read with to_bstring(), so credentials survive verbatim \
         (Display would render 'redacted'); got: {push}"
    );
}

// ── Embedded credentials are preserved verbatim ───────────────────────────────

#[test]
fn remotes_preserve_embedded_credentials() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), Some(Backend::Git)).result.unwrap();

    add_remotes(
        tmp.path(),
        &[("origin", "https://user:s3cr3t@github.com/priv/repo.git")],
    );

    let mut repo = Repo::open(tmp.path()).unwrap();
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
    Repo::init(tmp.path(), Some(Backend::Git)).result.unwrap();

    // scp-like form (`git@host:path`) — the AC-named case (AC-6 #13 / AC-9 #18);
    // exercises gix's alternative-form serialisation branch (must stay ssh-ish,
    // never become https).
    add_remotes(tmp.path(), &[("origin", "git@github.com:user/repo.git")]);

    let mut repo = Repo::open(tmp.path()).unwrap();
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
    Repo::init(tmp.path(), None).result.unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();

    // Corrupt AFTER open: list_remotes() re-resolves to head per call (ADR-0002),
    // so removing op_heads makes load_at_head() fail → RemoteError::Backend.
    let op_heads = tmp.path().join(".jj").join("repo").join("op_heads");
    fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.list_remotes();
    assert!(
        matches!(result, Err(RemoteError::Precondition(zanshin_jj::PreconditionError::Backend(_)))),
        "the pre-verb snapshot fails first (Story 9.26, as the CLI would): corrupt repo must yield Backend error, got: {result:?}"
    );
}
