// SPDX-License-Identifier: MIT

use std::fs;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::git;
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{Backend, RemoteError, Repo};

fn oracle_workspace(root: &std::path::Path) -> (Workspace, UserSettings) {
    let settings = test_helpers::test_settings();
    let workspace = test_helpers::load_workspace(
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
        let base = pollster::block_on(ws.load_at_head()).expect("load_at_head");
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
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let remotes = repo.list_remotes().unwrap();
    assert!(remotes.is_empty(), "tiny fixture has no remotes; got {remotes:?}");
}

// ── An external git config edit reaches the open handle ───────────────────────

/// A `[remote]` section appended to `<git dir>/config` behind the handle's back (a terminal's
/// `git remote add`) is listed by the handle's next call, as by the next CLI command.
#[test]
fn remotes_sees_an_external_git_config_edit_on_the_open_handle() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    assert!(repo.list_remotes().unwrap().is_empty());

    let store = fx.path.join(".jj").join("repo").join("store");
    let target = fs::read(store.join("git_target")).expect("a git-backed fixture");
    let config = store
        .join(jj_lib::file_util::path_from_bytes(&target).expect("a path"))
        .join("config");
    let text = fs::read_to_string(&config).expect("git config");
    fs::write(
        &config,
        format!("{text}[remote \"ext\"]\n\turl = https://example.invalid/ext.git\n"),
    )
    .expect("edit");

    let names: Vec<String> = repo.list_remotes().unwrap().into_iter().map(|r| r.name).collect();
    assert_eq!(names, ["ext"]);
}

// ── Refused on a native backend ───────────────────────────────────────────────

#[test]
fn remotes_on_native_backend_is_refused_as_not_a_git_repo() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    // `Repo::init(.., None)` uses jj's native backend (`init_simple`). `jj git remote
    // list` starts with `get_git_repo(..)?`, so it refuses there (FR-JJ-9 native-backend AC).
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    let err = repo.list_remotes().expect_err("a native backend has no git repo");
    assert!(matches!(err, RemoteError::NotAGitRepo), "got {err:?}");
    assert_eq!(err.to_string(), "not a git repository");
}

// ── Lists remotes sorted by name ──────────────────────────────────────────────

#[test]
fn remotes_lists_configured_remotes_sorted_by_name() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();

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
    assert_eq!(remotes[1].url.as_deref(), Some("https://github.com/origin/repo.git"));
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
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    repo.git_remote_add(
        "origin",
        "https://github.com/origin/repo.git",
        Some("ssh://git@github.com/origin/repo.git"),
    )
    .unwrap();

    let remotes = repo.list_remotes().unwrap();
    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    assert_eq!(remotes[0].url.as_deref(), Some("https://github.com/origin/repo.git"));
    assert_eq!(
        remotes[0].push_url.as_deref(),
        Some("ssh://git@github.com/origin/repo.git")
    );
}

#[test]
fn remotes_without_a_push_url_report_none() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();

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
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();

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
    let rows: Vec<(&str, Option<&str>, Option<&str>)> = remotes
        .iter()
        .map(|r| (r.name.as_str(), r.url.as_deref(), r.push_url.as_deref()))
        .collect();
    assert_eq!(
        rows,
        [
            (
                "alpha",
                Some("https://github.com/alpha/repo.git"),
                Some("ssh://git@github.com/alpha/repo.git")
            ),
            ("mid", Some("https://github.com/mid/repo.git"), None),
            (
                "zulu",
                Some("https://github.com/zulu/repo.git"),
                Some("ssh://git@github.com/zulu/repo.git")
            ),
        ],
        "each row's push URL must belong to that row's own remote"
    );
}

#[test]
fn remotes_report_a_push_url_added_later() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    repo.git_remote_add("origin", "https://github.com/origin/repo.git", None)
        .unwrap();
    repo.git_remote_set_url("origin", None, Some("ssh://git@github.com/origin/repo.git"))
        .unwrap();

    let remotes = repo.list_remotes().unwrap();
    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    assert_eq!(
        remotes[0].url.as_deref(),
        Some("https://github.com/origin/repo.git"),
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
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();

    let url = "https://github.com/origin/repo.git";
    let mut repo = Repo::open(tmp.path()).unwrap();
    repo.git_remote_add("origin", url, Some(url)).unwrap();

    let remotes = repo.list_remotes().unwrap();
    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    assert_eq!(remotes[0].url.as_deref(), Some(url));
    assert_eq!(
        remotes[0].push_url, None,
        "a push URL equal to the fetch URL is not a DIFFERENCE, so it is absent"
    );
}

#[test]
fn remotes_preserve_embedded_credentials_in_the_push_url() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();

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
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();

    add_remotes(
        tmp.path(),
        &[("origin", "https://user:s3cr3t@github.com/priv/repo.git")],
    );

    let mut repo = Repo::open(tmp.path()).unwrap();
    let remotes = repo.list_remotes().unwrap();

    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    let url = remotes[0].url.as_deref().expect("fetch URL");
    assert!(
        url.contains("s3cr3t"),
        "embedded password must be preserved verbatim (not 'redacted'), got: {url}"
    );
    assert!(
        url.contains("user:"),
        "embedded username must be preserved verbatim, got: {url}"
    );
}

// ── SSH URL form is not rewritten to HTTPS ────────────────────────────────────

#[test]
fn remotes_keep_ssh_form() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();

    // scp-like form (`git@host:path`) — the AC-named case (AC-6 #13 / AC-9 #18);
    // exercises gix's alternative-form serialisation branch (must stay ssh-ish,
    // never become https).
    add_remotes(tmp.path(), &[("origin", "git@github.com:user/repo.git")]);

    let mut repo = Repo::open(tmp.path()).unwrap();
    let remotes = repo.list_remotes().unwrap();

    assert_eq!(remotes.len(), 1, "expected one remote; got {remotes:?}");
    let url = remotes[0].url.as_deref().expect("fetch URL");
    assert!(
        !url.starts_with("https://"),
        "SSH URL must not be rewritten to HTTPS, got: {url}"
    );
    assert!(url.contains("github.com"), "host must be preserved, got: {url}");
    assert!(url.contains("user/repo"), "path must be preserved, got: {url}");
}

// ── Corrupt repo returns Backend error ────────────────────────────────────────

#[test]
fn remotes_on_corrupt_repo_returns_backend_error() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    // Native backend: list_remotes() still loads the head first (snapshot::reload_head),
    // which will fail when op_heads is removed → RemoteError::Backend.
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();

    // Corrupt AFTER open: list_remotes() re-resolves to head per call (ADR-0002),
    // so removing op_heads makes the head load fail → RemoteError::Backend.
    let op_heads = tmp.path().join(".jj").join("repo").join("op_heads");
    fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.list_remotes();
    assert!(
        matches!(result, Err(RemoteError::Precondition(zanshin_jj::PreconditionError::Backend(_)))),
        "the pre-verb snapshot fails first (Story 9.26, as the CLI would): corrupt repo must yield Backend error, got: {result:?}"
    );
}

// ── Story 9.46: push-only remotes and remotes that fail to load ───────────────

/// A non-colocated Git-backed repo whose store's Git config gets `extra` appended.
fn git_repo_with_config(extra: &str) -> TempDir {
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();
    let config = tmp.path().join(".jj/repo/store/git/config");
    let mut text = fs::read_to_string(&config).unwrap();
    text.push_str(extra);
    fs::write(&config, text).unwrap();
    tmp
}

/// `jj git remote list` lists a remote with only a `pushurl` as `p <no URL> (push: <u>)`
/// (`cli/src/commands/git/remote/list.rs:45-59,64-69` @ v0.46.0): `url` absent, `push_url` set.
/// An empty `[remote "e"]` section is skipped, as the CLI skips it.
#[test]
fn a_push_only_remote_is_listed_without_a_fetch_url() {
    test_helpers::pin_test_env();
    let tmp = git_repo_with_config(
        "[remote \"p\"]\n\tpushurl = ssh://git@example.com/p.git\n[remote \"e\"]\n\
         [remote \"o\"]\n\turl = https://example.com/o.git\n",
    );
    let mut repo = Repo::open(tmp.path()).unwrap();
    let remotes = repo.list_remotes().unwrap();
    let rows: Vec<(&str, Option<&str>, Option<&str>)> = remotes
        .iter()
        .map(|r| (r.name.as_str(), r.url.as_deref(), r.push_url.as_deref()))
        .collect();
    assert_eq!(
        rows,
        [
            ("o", Some("https://example.com/o.git"), None),
            ("p", None, Some("ssh://git@example.com/p.git")),
        ]
    );
}

/// A remote gix cannot load refuses the whole list, as the CLI's
/// `try_find_active_remote(..)?` does (`list.rs:42-44` @ v0.46.0): `Backend` with jj-lib's
/// chain, nothing listed.
#[test]
fn a_remote_that_fails_to_load_refuses_the_list() {
    test_helpers::pin_test_env();
    let tmp = git_repo_with_config(
        "[remote \"bad\"]\n\turl = https://example.com/b.git\n\tfetch = a::b\n\
         [remote \"good\"]\n\turl = https://example.com/g.git\n",
    );
    let mut repo = Repo::open(tmp.path()).unwrap();
    let err = repo.list_remotes().expect_err("a remote that fails to load refuses");
    assert!(
        matches!(&err, RemoteError::Backend(chain)
            if chain.starts_with("Unexpected Git error when managing remotes: ")),
        "{err:?}"
    );
}
