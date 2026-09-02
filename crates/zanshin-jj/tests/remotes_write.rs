// SPDX-License-Identifier: MIT

//! Integration tests for `Repo::git_fetch` (Story 6.4a / FR-JJ-13).
//!
//! Uses a local bare-git remote (no network), built via plain `git` subprocess calls
//! in fixture setup only (AR-AP-1's allowed exception) — mirrors `tests/convert.rs`'s
//! `git`/`git_bare_clone` helpers (each `tests/*.rs` file is a separate compilation
//! unit, so this is a local copy, not an import) and `tests/remotes.rs`'s
//! add-remote-then-reload dance.

use std::env;
use std::fs;
use std::sync::{Arc, LazyLock, Mutex};

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::git;
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{Backend, MutateError, ProgressEvent, Repo};

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

/// Run a git command in `dir`; panics on non-zero exit.
fn git_cmd(args: &[&str], dir: &std::path::Path) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// Run a git command and return captured stdout (trimmed).
fn git_stdout(args: &[&str], dir: &std::path::Path) -> String {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git command failed to spawn");
    assert!(out.status.success(), "git {args:?} failed in {}", dir.display());
    String::from_utf8(out.stdout)
        .expect("git output is not UTF-8")
        .trim()
        .to_owned()
}

/// Build a plain Git repo at `path` with two commits on `main` and a tag (`v1`) on
/// the tip commit, so a fetch against it exercises both the bookmark and tag
/// refspecs (`git_fetch`'s `expand_fetch_refspecs` call covers both).
fn init_git_repo_with_commits(path: &std::path::Path) {
    git_cmd(&["init", "--initial-branch=main"], path);
    git_cmd(&["config", "user.email", "test@zanshin.test"], path);
    git_cmd(&["config", "user.name", "Fixture"], path);
    fs::write(path.join("README.md"), "hello").expect("write README");
    git_cmd(&["add", "."], path);
    git_cmd(&["commit", "-m", "initial"], path);
    fs::write(path.join("README.md"), "hello again").expect("rewrite README");
    git_cmd(&["add", "."], path);
    git_cmd(&["commit", "-m", "second"], path);
    git_cmd(&["tag", "v1"], path);
}

/// Opens a fresh `Workspace` at `root` and returns the commit-id hex of the tracked
/// remote bookmark `name@remote` in jj's OWN view — `None` if absent or untracked.
///
/// Reads via `jj_lib` directly (already imported for fixture setup elsewhere in this
/// file) rather than `zanshin_jj::Repo::list_bookmarks`, because a freshly-fetched
/// bookmark is UNTRACKED by default here (`git_fetch`'s `remote_auto_track_bookmarks`
/// is hardcoded empty, mirroring `clone_into` — see the story spec's `deferred`
/// findings), so `list_bookmarks()` would not surface it even though `git_fetch`
/// succeeded and imported it into jj's view as `name@remote`.
fn remote_bookmark_commit_hex(root: &std::path::Path, name: &str, remote: &str) -> Option<String> {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("load workspace to read view");
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load_at_head");
    let hex = readonly
        .view()
        .all_remote_bookmarks()
        .find(|(symbol, _)| symbol.name.as_str() == name && symbol.remote.as_str() == remote)
        .and_then(|(_, remote_ref)| remote_ref.target.as_normal())
        .map(jj_lib::object_id::ObjectId::hex);
    hex
}

/// Same as [`remote_bookmark_commit_hex`], but for a remote TAG. Unlike bookmarks,
/// jj-lib tracks remote tags by default regardless of `remote_auto_track_bookmarks`
/// (`jj-lib` `git.rs`'s `default_remote_ref_state_for`: `GitRefKind::Tag =>
/// RemoteRefState::Tracked`, unconditionally), so this proves `import_refs()` really
/// updated jj's own view — not just the raw git object database.
fn remote_tag_commit_hex(root: &std::path::Path, name: &str, remote: &str) -> Option<String> {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("load workspace to read view");
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load_at_head");
    let hex = readonly
        .view()
        .all_remote_tags()
        .find(|(symbol, _)| symbol.name.as_str() == name && symbol.remote.as_str() == remote)
        .and_then(|(_, remote_ref)| remote_ref.target.as_normal())
        .map(jj_lib::object_id::ObjectId::hex);
    hex
}

/// Clone a normal Git repo as a bare repo (returns the bare repo path inside
/// `parent`). Shells to `git clone --bare`, allowed in fixture setup.
fn git_bare_clone(src: &std::path::Path, parent: &std::path::Path) -> std::path::PathBuf {
    let bare = parent.join("bare.git");
    git_cmd(
        &["clone", "--bare", &src.to_string_lossy(), &bare.to_string_lossy()],
        parent,
    );
    bare
}

/// Registers `name` -> `url` as a git remote on the jj workspace at `root`.
///
/// `jj_lib::git::add_remote` calls `save_git_config()`, which writes to disk
/// immediately but does NOT update the calling `Workspace`'s already-loaded
/// `GitBackend`/gix config cache — mirrors `clone_into`'s Step 2: the disk write is
/// the only needed side effect, so the transaction is dropped without committing.
/// Callers must `Repo::open` (not reuse an already-open `Repo`) afterward so the
/// fresh `GitBackend` reads the new remote from disk.
fn register_remote(root: &std::path::Path, name: &str, url: &str) {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("load workspace to add remote");
    let base = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load_at_head");
    let mut tx = base.start_transaction();
    let remote_name_buf: RemoteNameBuf = name.into();
    let remote_name: &RemoteName = &remote_name_buf;
    git::add_remote(tx.repo_mut(), remote_name, url, None).unwrap_or_else(|e| panic!("add_remote({name}) failed: {e}"));
    // tx is intentionally dropped without commit.
}

// ── Happy path: commits + bookmarks imported, progress observed ───────────────────

#[test]
fn git_fetch_happy_path_imports_commits_and_reports_progress() {
    pin_env();
    let src = TempDir::new().unwrap();
    init_git_repo_with_commits(src.path());
    let expected_head = git_stdout(&["rev-parse", "HEAD"], src.path());

    let parent = TempDir::new().unwrap();
    let bare = git_bare_clone(src.path(), parent.path());

    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), Some(Backend::Git)).unwrap();
    register_remote(dst.path(), "origin", &bare.to_string_lossy());

    let mut repo = Repo::open(dst.path()).unwrap();
    let before = repo.op_log(None).unwrap().len();

    // `ProgressFn` requires `Fn(..) + Send + Sync + 'static` (no borrowed captures),
    // so the collector is an `Arc<Mutex<_>>` moved into the closure, with a clone kept
    // behind for reading the events back out afterward.
    let progress_log = Arc::new(Mutex::new(Vec::<ProgressEvent>::new()));
    let progress_log_for_cb = Arc::clone(&progress_log);
    let cb = move |e: ProgressEvent| progress_log_for_cb.lock().expect("progress_log mutex").push(e);
    let result = repo.git_fetch("origin", &cb).expect("git_fetch should succeed");
    let events = progress_log.lock().expect("progress_log mutex").clone();

    assert!(!events.is_empty(), "expected at least one progress event");
    for event in &events {
        assert_eq!(event.operation, "fetch");
        assert!(
            (0.0..=1.0).contains(&event.progress),
            "progress {} out of range",
            event.progress
        );
    }

    let after = repo.op_log(None).unwrap();
    assert_eq!(after.len(), before + 1, "fetch must commit exactly one new op");
    assert_eq!(after[0].id, result.new_op_id);
    assert_eq!(after[0].description, "fetch from git remote(s) origin");

    let dst_git_dir = dst.path().join(".jj").join("repo").join("store").join("git");
    let imported = git_stdout(&["rev-parse", "refs/remotes/origin/main"], &dst_git_dir);
    assert_eq!(
        imported, expected_head,
        "origin/main must be imported at the source's HEAD commit"
    );

    // The check above only proves the raw git object database was updated by the
    // `fetch()` subprocess step. Proving `import_refs()` actually updated jj's OWN
    // view (the real point of calling it, and the thing a caller of `Repo::git_fetch`
    // actually cares about — e.g. via `Repo::list_bookmarks` or a revset) needs a
    // separate check: `main@origin` (tracked-or-not) and `v1@origin` (a tag, always
    // tracked) must both resolve to the source's HEAD commit in jj's view.
    assert_eq!(
        remote_bookmark_commit_hex(dst.path(), "main", "origin").as_deref(),
        Some(expected_head.as_str()),
        "main@origin must be visible in jj's own view, not just the raw git ODB"
    );
    assert_eq!(
        remote_tag_commit_hex(dst.path(), "v1", "origin").as_deref(),
        Some(expected_head.as_str()),
        "v1@origin (a tag) must be visible in jj's own view, not just the raw git ODB"
    );

    let status = repo.status().unwrap();
    assert_eq!(
        status.working_copy_change_id, result.working_copy_change_id,
        "git_fetch must never move @"
    );
}

// ── Fetch with nothing new still commits a fresh op; @ stays put ──────────────────

#[test]
fn git_fetch_twice_with_no_new_commits_still_commits_fresh_op_each_time() {
    pin_env();
    let src = TempDir::new().unwrap();
    init_git_repo_with_commits(src.path());

    let parent = TempDir::new().unwrap();
    let bare = git_bare_clone(src.path(), parent.path());

    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), Some(Backend::Git)).unwrap();
    register_remote(dst.path(), "origin", &bare.to_string_lossy());

    let mut repo = Repo::open(dst.path()).unwrap();
    let no_op = |_: ProgressEvent| {};

    let before = repo.op_log(None).unwrap().len();
    let first = repo.git_fetch("origin", &no_op).expect("first fetch");
    let after_first = repo.op_log(None).unwrap();
    assert_eq!(after_first.len(), before + 1);
    assert_eq!(after_first[0].description, "fetch from git remote(s) origin");

    // Nothing changed on the remote between the two fetches.
    let second = repo.git_fetch("origin", &no_op).expect("second fetch, nothing new");
    let after_second = repo.op_log(None).unwrap();
    assert_eq!(
        after_second.len(),
        before + 2,
        "fetch must commit a fresh op even when nothing changed (CLI parity)"
    );
    assert_eq!(after_second[0].description, "fetch from git remote(s) origin");
    assert_ne!(
        first.new_op_id, second.new_op_id,
        "each fetch commits a distinct operation"
    );
    assert_eq!(
        first.working_copy_change_id, second.working_copy_change_id,
        "git_fetch never moves @, so it must be identical across both calls"
    );
}

// ── Remote absent ──────────────────────────────────────────────────────────────

#[test]
fn git_fetch_nonexistent_remote_returns_remote_not_found() {
    pin_env();
    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), Some(Backend::Git)).unwrap();

    let mut repo = Repo::open(dst.path()).unwrap();
    let before = repo.op_log(None).unwrap().len();

    let no_op = |_: ProgressEvent| {};
    let err = repo.git_fetch("nonexistent", &no_op).expect_err("no such remote");
    assert!(
        matches!(err, MutateError::RemoteNotFound { ref name } if name == "nonexistent"),
        "expected RemoteNotFound{{name: \"nonexistent\"}}, got {err:?}"
    );

    let after = repo.op_log(None).unwrap().len();
    assert_eq!(after, before, "a failed fetch must not commit an operation");
}

// ── Native (non-git) backend ───────────────────────────────────────────────────

#[test]
fn git_fetch_on_native_backend_returns_remote_not_found() {
    pin_env();
    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), None).unwrap();

    let mut repo = Repo::open(dst.path()).unwrap();
    let no_op = |_: ProgressEvent| {};
    let err = repo
        .git_fetch("origin", &no_op)
        .expect_err("native backend has no remotes");
    assert!(
        matches!(err, MutateError::RemoteNotFound { ref name } if name == "origin"),
        "expected RemoteNotFound{{name: \"origin\"}}, got {err:?}"
    );
}

// ── Reserved remote name falls through to the generic Backend mapping ─────────────

#[test]
fn git_fetch_reserved_remote_name_returns_backend_error() {
    pin_env();
    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), Some(Backend::Git)).unwrap();

    let mut repo = Repo::open(dst.path()).unwrap();
    let no_op = |_: ProgressEvent| {};
    // "git" is jj-lib's reserved pseudo-remote name for the colocated local git repo
    // (`REMOTE_NAME_FOR_LOCAL_GIT_REPO`). `GitFetch::fetch`'s own `validate_remote_name`
    // rejects it before ever checking whether a remote by that name is configured,
    // producing `GitFetchError::RemoteName` — which falls through `git_fetch`'s error
    // mapping to the generic `MutateError::Backend` arm (not `RemoteNotFound`).
    let err = repo
        .git_fetch("git", &no_op)
        .expect_err("\"git\" is a reserved remote name");
    assert!(matches!(err, MutateError::Backend(_)), "expected Backend, got {err:?}");
}

// ── Subprocess / network failure ───────────────────────────────────────────────

#[test]
fn git_fetch_unreachable_remote_returns_network_error() {
    pin_env();
    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), Some(Backend::Git)).unwrap();

    let parent = TempDir::new().unwrap();
    let bogus_url = parent.path().join("does-not-exist.git");
    register_remote(dst.path(), "origin", &bogus_url.to_string_lossy());

    let mut repo = Repo::open(dst.path()).unwrap();
    let before = repo.op_log(None).unwrap().len();

    let no_op = |_: ProgressEvent| {};
    let err = repo
        .git_fetch("origin", &no_op)
        .expect_err("remote path does not exist");
    assert!(
        matches!(err, MutateError::NetworkError { .. }),
        "expected NetworkError, got {err:?}"
    );

    let after = repo.op_log(None).unwrap().len();
    assert_eq!(after, before, "a failed fetch must not commit an operation");
}
