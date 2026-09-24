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

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::git;
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{resolve_revset, Backend, MutateError, ProgressEvent, Repo};

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

/// Build a plain Git repo at `path` with one commit on `main` and a second commit `B`
/// reachable ONLY through the branch `feature` — and no tags, unlike
/// [`init_git_repo_with_commits`], whose `v1` would keep the tip reachable after the
/// branch is deleted. Deleting `feature` therefore makes `B` genuinely unreachable, which
/// is the only state in which `git.abandon-unreachable-commits` is observable.
fn init_git_repo_with_a_branch_only_commit(path: &std::path::Path) {
    git_cmd(&["init", "--initial-branch=main"], path);
    git_cmd(&["config", "user.email", "test@zanshin.test"], path);
    git_cmd(&["config", "user.name", "Fixture"], path);
    fs::write(path.join("README.md"), "hello").expect("write README");
    git_cmd(&["add", "."], path);
    git_cmd(&["commit", "-m", "initial"], path);
    git_cmd(&["checkout", "-b", "feature"], path);
    fs::write(path.join("feature.txt"), "only on feature").expect("write feature file");
    git_cmd(&["add", "."], path);
    git_cmd(&["commit", "-m", "only on feature"], path);
    git_cmd(&["checkout", "main"], path);
}

/// Writes the repo-layer config (`.jj/repo/config.toml`) of the workspace at `root`.
/// Mirrors `tests/git_sync.rs`'s helper of the same name — each `tests/*.rs` file is its
/// own compilation unit, so this is a local copy, not an import.
fn write_repo_config(root: &std::path::Path, toml: &str) {
    fs::write(root.join(".jj").join("repo").join("config.toml"), toml).expect("repo config must be writable");
}

/// Opens a fresh `Workspace` at `root` and returns the commit-id hex of the tracked
/// remote bookmark `name@remote` in jj's OWN view — `None` if absent or untracked.
///
/// Reads via `jj_lib` directly (already imported for fixture setup elsewhere in this
/// file) rather than `zanshin_jj::Repo::list_bookmarks`, because a freshly-fetched
/// bookmark is UNTRACKED by default (no `remotes.<name>.auto-track-bookmarks` is set in
/// these tests' config), so `list_bookmarks()` would not surface it even though `git_fetch`
/// succeeded and imported it into jj's view as `name@remote`.
fn remote_bookmark_commit_hex(root: &std::path::Path, name: &str, remote: &str) -> Option<String> {
    let settings = test_helpers::test_settings();
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
    let settings = test_helpers::test_settings();
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
    let settings = test_helpers::test_settings();
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
    Repo::init(dst.path(), Some(Backend::Git)).result.unwrap();
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

/// `remotes.<name>.auto-track-bookmarks` is read from the effective config (Story 9.26, the
/// CLI's `parse_remote_auto_track_bookmarks_map`): a fetched bookmark the expression matches
/// is TRACKED, so a local bookmark is created for it; one it does not match stays untracked.
#[test]
fn git_fetch_honours_remote_auto_track_bookmarks() {
    pin_env();
    let src = TempDir::new().unwrap();
    init_git_repo_with_a_branch_only_commit(src.path());
    let main_hex = git_stdout(&["rev-parse", "main"], src.path());

    let parent = TempDir::new().unwrap();
    let bare = git_bare_clone(src.path(), parent.path());

    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), Some(Backend::Git)).result.unwrap();
    register_remote(dst.path(), "origin", &bare.to_string_lossy());
    write_repo_config(dst.path(), "[remotes.origin]\nauto-track-bookmarks = \"exact:main\"\n");

    let mut repo = Repo::open(dst.path()).unwrap();
    repo.git_fetch("origin", &|_| {}).expect("git_fetch should succeed");

    let bookmarks = repo.list_bookmarks().expect("list_bookmarks");
    let local = |name: &str| {
        bookmarks
            .iter()
            .any(|b| b.name == name && b.kind == zanshin_jj::BookmarkKind::Local)
    };
    assert!(local("main"), "main@origin matches, so it is tracked: {bookmarks:?}");
    assert!(!local("feature"), "feature@origin does not match: {bookmarks:?}");
    assert_eq!(
        remote_bookmark_commit_hex(dst.path(), "main", "origin").as_deref(),
        Some(main_hex.as_str()),
        "the tracked remote bookmark is at the source's main"
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
    Repo::init(dst.path(), Some(Backend::Git)).result.unwrap();
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
    Repo::init(dst.path(), Some(Backend::Git)).result.unwrap();

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

/// A native (`init_simple`) workspace has no git backend at all, so `git fetch` cannot run.
/// That is `NotAGitRepo` — the SAME variant the six `Repo::git_remote_*`/`git_import`/
/// `git_export` verbs already return for the identical condition — not `RemoteNotFound`,
/// which now means only "no remote of that name". The remap is exact: `GitFetch::new`'s
/// only failure mode is jj-lib's `UnexpectedGitBackendError`.
#[test]
fn git_fetch_on_native_backend_returns_not_a_git_repo() {
    pin_env();
    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), None).result.unwrap();

    let mut repo = Repo::open(dst.path()).unwrap();
    let no_op = |_: ProgressEvent| {};
    let err = repo
        .git_fetch("origin", &no_op)
        .expect_err("native backend has no git backend to fetch into");
    assert!(
        matches!(err, MutateError::NotAGitRepo),
        "expected NotAGitRepo, got {err:?}"
    );
}

// ── The two `git.*` import keys come from config, never from a Rust constant ──────

/// The pruning-fetch fixture, kept whole so its temp dirs outlive the test body.
struct PruneFixture {
    _src: TempDir,
    _parent: TempDir,
    /// The jj workspace that already fetched once and whose next fetch is the pruning one.
    dst: TempDir,
    /// The change id of the commit that the pruning fetch makes unreachable.
    b_change: zanshin_jj::ChangeId,
}

/// Builds the ONLY state in which `git.abandon-unreachable-commits` is observable: a bare
/// remote whose `feature` branch is the sole ref to commit `B`, a git-backed jj workspace with
/// `origin` pointing at it, and one completed fetch that imported `B`. `feature` is then
/// deleted upstream, so the CALLER's next fetch is the pruning one — the caller decides what
/// the repo config says (or says nothing, exercising the default) before making it.
fn prune_fixture() -> PruneFixture {
    let src = TempDir::new().unwrap();
    init_git_repo_with_a_branch_only_commit(src.path());
    let feature_head = git_stdout(&["rev-parse", "feature"], src.path());

    let parent = TempDir::new().unwrap();
    let bare = git_bare_clone(src.path(), parent.path());

    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), Some(Backend::Git)).result.unwrap();
    register_remote(dst.path(), "origin", &bare.to_string_lossy());

    let no_op = |_: ProgressEvent| {};
    let repo = {
        let mut repo = Repo::open(dst.path()).unwrap();
        repo.git_fetch("origin", &no_op).expect("first fetch imports feature");
        repo
    };

    // `B` is in jj's own view now — capture its change id while it is still resolvable.
    let mut ids = resolve_revset(&repo, &feature_head).expect("a commit hex is a revset symbol");
    assert_eq!(ids.len(), 1, "a commit hex denotes exactly one change");
    let b_change = ids.swap_remove(0);

    // Drop the only ref to `B` upstream, so the next fetch prunes `feature@origin` and
    // leaves `B` unreachable.
    git_cmd(&["update-ref", "-d", "refs/heads/feature"], &bare);

    PruneFixture {
        _src: src,
        _parent: parent,
        dst,
        b_change,
    }
}

/// `git.abandon-unreachable-commits = false` must actually be honoured by FETCH too — the
/// option is read from the repo's EFFECTIVE config per call, never hardcoded (FR-JJ-17,
/// CLI parity with `cli/src/commands/git/fetch.rs:235` @ v0.44.0).
///
/// The `feature@origin`-is-gone assertion is what keeps this from passing vacuously: if the
/// pruning ever stopped happening, `B` would stay visible for a reason that has nothing to do
/// with the flag. Its sibling
/// [`git_fetch_with_the_default_config_abandons_unreachable_commits`] walks the same fixture
/// with the other value, so the config value is a real witness rather than a setting whose
/// effect is never contrasted.
#[test]
fn git_fetch_honours_abandon_unreachable_commits_false() {
    pin_env();
    let fx = prune_fixture();

    write_repo_config(fx.dst.path(), "[git]\nabandon-unreachable-commits = false\n");
    let no_op = |_: ProgressEvent| {};
    let mut repo = Repo::open(fx.dst.path()).expect("reopen with the new repo config");
    let result = repo.git_fetch("origin", &no_op).expect("second, pruning fetch");

    assert_eq!(
        remote_bookmark_commit_hex(fx.dst.path(), "feature", "origin"),
        None,
        "the fetch must really have pruned feature@origin — otherwise the flag decides nothing"
    );
    let visible = resolve_revset(&repo, "all()").expect("all() resolves");
    assert!(
        visible.contains(&fx.b_change),
        "the user disabled abandoning, so the now-unreachable commit must stay visible; got {visible:?}"
    );
    // The negative control for the sibling's `abandoned_change_ids` assertion: the projection
    // reads jj-lib's OWN import stats, so turning the key off empties the list. A hardcoded
    // `Vec::new()` would pass here and fail there; a hardcoded echo would fail here.
    assert!(
        result.abandoned_change_ids.is_empty(),
        "nothing was abandoned, so the reported list must be empty; got {:?}",
        result.abandoned_change_ids
    );
}

/// The same pruning fetch on an UNCONFIGURED repo — no `[git]` key at all, so
/// `abandon-unreachable-commits` takes jj-lib's own default `true`.
///
/// This is the branch a real user hits, and the one the sibling test above deliberately steers
/// around: it is the value that makes `import_refs` record abandoned commits, so it is the only
/// value that needs `git_fetch`'s descendant pass. Without that pass jj-lib panics in
/// `Transaction::write` ("BUG: Descendants have not been rebased after the last rewrites"), and
/// across FFI a panic is `internal.panic`, not an error envelope — so "does not panic" is half
/// of what this test pins.
#[test]
fn git_fetch_with_the_default_config_abandons_unreachable_commits() {
    pin_env();
    let fx = prune_fixture();

    let no_op = |_: ProgressEvent| {};
    let mut repo = Repo::open(fx.dst.path()).expect("open with no repo config written");
    let result = repo
        .git_fetch("origin", &no_op)
        .expect("the pruning fetch must return, not panic");

    assert_eq!(
        remote_bookmark_commit_hex(fx.dst.path(), "feature", "origin"),
        None,
        "the fetch must really have pruned feature@origin — otherwise nothing became unreachable"
    );
    let visible = resolve_revset(&repo, "all()").expect("all() resolves");
    assert!(
        !visible.contains(&fx.b_change),
        "the default is jj-lib's own `true`, so the now-unreachable commit must be abandoned; got {visible:?}"
    );
    // The abandoning is REPORTED, not only observable through a second revset query: fetch
    // projects `import_refs`' own `GitImportStats` into `abandoned_change_ids`.
    // Asserted as the EXACT set, not with `contains`: this fixture makes exactly one commit
    // unreachable, so a projection that echoed every commit it saw would satisfy `contains`
    // while reporting nonsense.
    assert_eq!(
        result.abandoned_change_ids,
        vec![fx.b_change.clone()],
        "exactly the one now-unreachable change must be reported in the MutationResult"
    );
    assert!(
        result.new_change_ids.is_empty(),
        "a fetch mints nothing — GitImportStats has no minted-change concept; got {:?}",
        result.new_change_ids
    );
}

/// A malformed value for a key this verb reads must arrive as `Config` — the same fault
/// class the read side reports, never the unclassified `Backend` bucket — and must write
/// nothing.
///
/// The handle is opened and used BEFORE the bad config exists, which makes the first fetch two
/// things at once: the positive control that the fixture's remote really is reachable (so the
/// later refusal cannot be a broken fixture), and the proof that the value is re-read PER CALL
/// rather than snapshotted when the handle was opened — a per-handle cache would sail through
/// a test that writes the config first and only then opens the repo.
#[test]
fn git_fetch_with_a_non_boolean_config_value_refuses_as_config() {
    pin_env();
    let src = TempDir::new().unwrap();
    init_git_repo_with_commits(src.path());

    let parent = TempDir::new().unwrap();
    let bare = git_bare_clone(src.path(), parent.path());

    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), Some(Backend::Git)).result.unwrap();
    register_remote(dst.path(), "origin", &bare.to_string_lossy());

    let mut repo = Repo::open(dst.path()).unwrap();
    let no_op = |_: ProgressEvent| {};
    repo.git_fetch("origin", &no_op)
        .expect("the fixture's remote is real and reachable");

    let before = repo.op_log(None).unwrap();

    write_repo_config(dst.path(), "[git]\nabandon-unreachable-commits = \"yes\"\n");
    let err = repo
        .git_fetch("origin", &no_op)
        .expect_err("a wrong-typed value must refuse");

    assert!(
        matches!(&err, MutateError::Precondition(zanshin_jj::PreconditionError::Config { reason }) if reason.contains("abandon-unreachable-commits")),
        "expected Config naming the key, got {err:?}"
    );
    // Every verb refuses while the stack is broken, so it is repaired before the read-back.
    write_repo_config(dst.path(), "");
    let after = repo.op_log(None).unwrap();
    assert_eq!(after.len(), before.len(), "a refusal must write no operation");
    assert_eq!(after[0].id, before[0].id, "the op-log head is untouched");
}

// ── `git.record-synthetic-predecessors` — the key whose default this verb FLIPPED ─────

/// The `change-id` header both upstream versions of the amended commit carry, in jj's
/// reverse-hex alphabet (`z` = 0 … `k` = 15); 32 characters = the git backend's 16-byte change
/// id.
const AMENDED_CHANGE_ID: &str = "zyxwvutsrqponmlkzyxwvutsrqponmlk";

/// Writes a raw commit object carrying a `change-id` extra header into the repo at `dir` and
/// returns its hex id.
///
/// Two commits written with the SAME header share a jj change id, which is the only state in
/// which `git.record-synthetic-predecessors` is observable: jj-lib deduces predecessors by
/// matching change ids across the ref move (`jj-lib git.rs::record_synthetic_predecessors`),
/// and it derives a HEADERLESS git commit's change id from its commit id
/// (`git_backend.rs::synthetic_change_id_from_git_commit_id`) — so a plain `git commit --amend`
/// upstream would produce an unrelated change and no predecessor could ever be deduced.
///
/// `git hash-object` is a fixture-setup subprocess call (AR-AP-1's allowed exception); it reads
/// a FILE, hence `scratch`.
fn write_commit_object(
    dir: &std::path::Path,
    scratch: &std::path::Path,
    tree: &str,
    message: &str,
    when: u64,
) -> String {
    let content = format!(
        "tree {tree}\n\
         author Fixture <test@zanshin.test> {when} +0000\n\
         committer Fixture <test@zanshin.test> {when} +0000\n\
         change-id {AMENDED_CHANGE_ID}\n\
         \n\
         {message}\n"
    );
    let path = scratch.join(format!("commit-object-{when}"));
    fs::write(&path, content).expect("commit object must be writable");
    git_stdout(&["hash-object", "-t", "commit", "-w", &path.to_string_lossy()], dir)
}

/// The force-push fixture, kept whole so its temp dirs outlive the test body.
struct AmendFixture {
    src: TempDir,
    _parent: TempDir,
    scratch: TempDir,
    bare: std::path::PathBuf,
    /// The jj workspace that already fetched the pre-amend commit.
    dst: TempDir,
    /// Hex id of the pre-amend commit — the predecessor jj-lib must deduce.
    old_commit: String,
}

/// Builds the state in which `git.record-synthetic-predecessors` is observable: a remote whose
/// `main` points at a commit carrying [`AMENDED_CHANGE_ID`], and a jj workspace that has
/// fetched it once. `amend_upstream` then force-moves `main` to a SECOND commit with the same
/// change id, which is the "remote ref moves to a NEW target" case the option keys off
/// (`any_new_referenced`) — not the prune case the two tests above cover.
fn amend_fixture() -> AmendFixture {
    let src = TempDir::new().unwrap();
    let scratch = TempDir::new().unwrap();
    git_cmd(&["init", "--initial-branch=main"], src.path());
    git_cmd(&["config", "user.email", "test@zanshin.test"], src.path());
    git_cmd(&["config", "user.name", "Fixture"], src.path());
    fs::write(src.path().join("f.txt"), "v1").expect("write f.txt");
    git_cmd(&["add", "f.txt"], src.path());
    let tree = git_stdout(&["write-tree"], src.path());
    let old_commit = write_commit_object(src.path(), scratch.path(), &tree, "amendable", 1_700_000_000);
    git_cmd(&["update-ref", "refs/heads/main", &old_commit], src.path());

    let parent = TempDir::new().unwrap();
    let bare = git_bare_clone(src.path(), parent.path());

    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), Some(Backend::Git)).result.unwrap();
    register_remote(dst.path(), "origin", &bare.to_string_lossy());

    let no_op = |_: ProgressEvent| {};
    let mut repo = Repo::open(dst.path()).unwrap();
    repo.git_fetch("origin", &no_op)
        .expect("first fetch imports the pre-amend commit");
    assert_eq!(
        remote_bookmark_commit_hex(dst.path(), "main", "origin").as_deref(),
        Some(old_commit.as_str()),
        "the first fetch must have imported main@origin at the pre-amend commit"
    );

    AmendFixture {
        src,
        _parent: parent,
        scratch,
        bare,
        dst,
        old_commit,
    }
}

/// Rewrites the upstream commit — same change-id header, different tree and message — and
/// force-moves `main` onto it. Returns the new commit's hex id.
fn amend_upstream(fx: &AmendFixture) -> String {
    fs::write(fx.src.path().join("f.txt"), "v2").expect("rewrite f.txt");
    git_cmd(&["add", "f.txt"], fx.src.path());
    let tree = git_stdout(&["write-tree"], fx.src.path());
    let new_commit = write_commit_object(fx.src.path(), fx.scratch.path(), &tree, "amended", 1_700_000_100);
    git_cmd(&["update-ref", "refs/heads/main", &new_commit], fx.src.path());
    git_cmd(
        &["push", "--force", &fx.bare.to_string_lossy(), "main:main"],
        fx.src.path(),
    );
    new_commit
}

/// Collects every predecessor commit id `Repo::evolog` reports for [`AMENDED_CHANGE_ID`].
fn evolog_predecessor_hexes(repo: &mut Repo) -> Vec<String> {
    repo.evolog(Some(AMENDED_CHANGE_ID), None)
        .expect("the amended change resolves to its one visible commit")
        .iter()
        .flat_map(|entry| entry.predecessor_commit_ids.iter().map(|id| id.0.clone()))
        .collect()
}

/// With the config left alone, `git.record-synthetic-predecessors` takes jj-lib's own default
/// `true` — the default this verb FLIPPED, since the old Rust hardcode was `false`. A fetch that
/// sees a remote bookmark move to a new commit carrying an already-known change id must
/// therefore record the pre-amend commit as that change's predecessor.
#[test]
fn git_fetch_records_synthetic_predecessors_by_default() {
    pin_env();
    let fx = amend_fixture();
    let new_commit = amend_upstream(&fx);

    let no_op = |_: ProgressEvent| {};
    let mut repo = Repo::open(fx.dst.path()).expect("open with no repo config written");
    repo.git_fetch("origin", &no_op).expect("the force-push fetch");
    assert_eq!(
        remote_bookmark_commit_hex(fx.dst.path(), "main", "origin").as_deref(),
        Some(new_commit.as_str()),
        "the fetch must really have moved main@origin — otherwise nothing was rewritten"
    );

    let predecessors = evolog_predecessor_hexes(&mut repo);
    assert!(
        predecessors.contains(&fx.old_commit),
        "the default `true` must record the pre-amend commit as a predecessor; evolog reported {predecessors:?}"
    );
}

/// The same force-push against `git.record-synthetic-predecessors = false`: the option is read
/// from the repo's EFFECTIVE config per call, so the user's `false` must suppress the
/// predecessor the sibling test above observes. Together the two pin the VALUE, not merely that
/// the key is read.
#[test]
fn git_fetch_honours_record_synthetic_predecessors_false() {
    pin_env();
    let fx = amend_fixture();
    let new_commit = amend_upstream(&fx);

    write_repo_config(fx.dst.path(), "[git]\nrecord-synthetic-predecessors = false\n");
    let no_op = |_: ProgressEvent| {};
    let mut repo = Repo::open(fx.dst.path()).expect("reopen with the new repo config");
    repo.git_fetch("origin", &no_op).expect("the force-push fetch");
    assert_eq!(
        remote_bookmark_commit_hex(fx.dst.path(), "main", "origin").as_deref(),
        Some(new_commit.as_str()),
        "the fetch must really have moved main@origin — otherwise there was nothing to suppress"
    );

    let predecessors = evolog_predecessor_hexes(&mut repo);
    assert!(
        !predecessors.contains(&fx.old_commit),
        "the user turned recording off, so no predecessor may be recorded; evolog reported {predecessors:?}"
    );
}

// ── Reserved remote name falls through to the generic Backend mapping ─────────────

#[test]
fn git_fetch_reserved_remote_name_returns_backend_error() {
    pin_env();
    let dst = TempDir::new().unwrap();
    Repo::init(dst.path(), Some(Backend::Git)).result.unwrap();

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
    Repo::init(dst.path(), Some(Backend::Git)).result.unwrap();

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
