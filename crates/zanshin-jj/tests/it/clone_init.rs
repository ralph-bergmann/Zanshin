// SPDX-License-Identifier: MIT

//! Story 9.20 witnesses for `Repo::clone` and `Repo::init` — `jj git clone` / `jj git init` at
//! v0.46.0: destination rules, colocation, the clone's three operations, the repo presets, the
//! clean-up scope, the init modes. Sources are local git repositories (`file://`), never the
//! network. The identity and warning ORDER rows live in `tests/it/creation_warnings.rs` (they need
//! an empty identity); the oracle (`crates/zanshin-parity`) compares the same flows with the CLI.
//!
//! The config-driven rows (a flag left `None` so the user config decides) need `JJ_CONFIG`
//! repointed and, for one row, the identity variables removed — process-global state that would
//! race the other tests of this binary. Each such test therefore re-runs ITSELF in a child
//! process ([`with_user_config`]) and changes the environment only there.

use std::env;
use std::fs;
use std::num::NonZeroU32;
use std::ops::ControlFlow;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};

use tempfile::TempDir;
use zanshin_jj::{
    Backend, BookmarkKind, CloneOptions, CreationOutcome, InitOptions, ObjectHash, ProgressEvent, Repo, RepoError,
    WarningKind,
};

/// Runs `git` in `dir`; panics on a non-zero exit. Fixture setup only. Pins the test
/// environment first, so no fixture git reads the developer's global config.
fn git(args: &[&str], dir: &Path) -> String {
    test_helpers::pin_test_env();
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git spawns");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A git repo at `dir`: `main` with two commits, a branch `feature` with one more, a tag `v1`.
fn source_repo(dir: &Path) {
    git(&["init", "--initial-branch=main"], dir);
    git(&["config", "user.email", "test@zanshin.test"], dir);
    git(&["config", "user.name", "Fixture"], dir);
    fs::write(dir.join("README.md"), "hello").unwrap();
    git(&["add", "."], dir);
    git(&["commit", "-m", "initial"], dir);
    git(&["tag", "v1"], dir);
    git(&["checkout", "-b", "feature"], dir);
    fs::write(dir.join("feature.txt"), "feature").unwrap();
    git(&["add", "."], dir);
    git(&["commit", "-m", "feature"], dir);
    git(&["checkout", "main"], dir);
    fs::write(dir.join("README.md"), "hello again").unwrap();
    git(&["add", "."], dir);
    git(&["commit", "-m", "second"], dir);
}

fn file_url(dir: &Path) -> String {
    format!("file://{}", dir.display())
}

fn clone(options: &CloneOptions) -> CreationOutcome {
    test_helpers::pin_test_env();
    Repo::clone(options, &|_: ProgressEvent| {}, None)
}

fn init(options: &InitOptions) -> CreationOutcome {
    test_helpers::pin_test_env();
    Repo::init(options)
}

/// The operation descriptions, newest first.
fn ops(repo: &mut Repo) -> Vec<String> {
    repo.op_log(None)
        .expect("op log")
        .into_iter()
        .map(|op| op.description)
        .collect()
}

/// The header jj-lib writes into a new config file (`ConfigFile::load_or_empty`).
const SCHEMA: &str = "#:schema https://docs.jj-vcs.dev/latest/config-schema.json\n\n";

/// The repo-level config file the presets go to, or `None` when none was written.
fn repo_config(root: &Path) -> Option<String> {
    let id = fs::read_to_string(root.join(".jj").join("repo").join("config-id")).ok()?;
    let xdg = PathBuf::from(std::env::var_os("XDG_CONFIG_HOME").expect("pinned"));
    fs::read_to_string(xdg.join("jj").join("repos").join(id.trim()).join("config.toml")).ok()
}

/// The descriptions of the commits `revset` evaluates to.
fn descriptions(repo: &mut Repo, revset: &str) -> Vec<String> {
    let mut out = Vec::new();
    let _ = repo
        .eval_revset(revset, |change| {
            out.push(change.description);
            ControlFlow::Continue(())
        })
        .expect("revset evaluates");
    out
}

/// Whether `name@remote` is a tracked remote bookmark.
fn tracked(repo: &mut Repo, name: &str, remote: &str) -> bool {
    repo.list_bookmarks().expect("bookmarks").iter().any(|b| {
        b.name == name
            && matches!(&b.kind, BookmarkKind::Remote { remote_name, tracked: true, .. } if remote_name == remote)
    })
}

// ── clone ─────────────────────────────────────────────────────────────────────────

/// The default clone into a missing nested destination: created with its parents, colocated
/// (`git.colocate`), the CLI's three operations, `main` tracked, `trunk()` preset, `.jj/.gitignore`.
#[test]
fn a_default_clone_creates_the_destination_and_writes_the_cli_operations() {
    let src = TempDir::new().unwrap();
    source_repo(src.path());
    let parent = TempDir::new().unwrap();
    let dst = parent.path().join("a").join("b");
    let events = Arc::new(Mutex::new(Vec::<ProgressEvent>::new()));
    let sink = Arc::clone(&events);
    test_helpers::pin_test_env();
    let outcome = Repo::clone(
        &CloneOptions {
            source: file_url(src.path()),
            destination: dst.clone(),
            ..Default::default()
        },
        &move |event| sink.lock().unwrap().push(event),
        None,
    );
    let mut repo = outcome.result.expect("clone succeeds");
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
    assert!(dst.join(".git").is_dir(), "colocated by default");
    assert_eq!(fs::read_to_string(dst.join(".jj").join(".gitignore")).unwrap(), "/*\n");
    assert_eq!(fs::read_to_string(dst.join("README.md")).unwrap(), "hello again");
    assert!(
        events.lock().unwrap().iter().all(|e| e.operation == "clone"),
        "every progress event is the clone's"
    );
    assert_eq!(
        ops(&mut repo)[..4],
        [
            "check out git remote's branch: main",
            "fetch from git remote into empty repo",
            "add git remote origin",
            "add workspace 'default'",
        ]
    );
    assert!(tracked(&mut repo, "main", "origin"), "the default branch is tracked");
    assert!(!tracked(&mut repo, "feature", "origin"));
    assert_eq!(
        repo_config(&dst).expect("presets written"),
        format!("{SCHEMA}[revset-aliases]\n\"trunk()\" = \"main@origin\"\n")
    );
    assert_eq!(descriptions(&mut repo, "trunk()"), ["second\n"]);
    assert_eq!(descriptions(&mut repo, "@-"), ["second\n"]);
}

/// `--no-colocate`, `--remote up`, `-b feature`, `-t v1`: an internal git repo, the remote named
/// `up`, `feature` the working branch (not the default, so not tracked and no `trunk()`), and the
/// fetch presets written.
#[test]
fn clone_options_are_passed_through() {
    let src = TempDir::new().unwrap();
    source_repo(src.path());
    let dst = TempDir::new().unwrap();
    let outcome = clone(&CloneOptions {
        source: file_url(src.path()),
        destination: dst.path().to_owned(),
        remote_name: Some("up".to_owned()),
        colocate: Some(false),
        branches: Some(vec!["feature".to_owned()]),
        tags: Some(vec!["v1".to_owned()]),
        ..Default::default()
    });
    let mut repo = outcome.result.expect("clone succeeds");
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
    assert!(!dst.path().join(".git").exists(), "not colocated");
    assert!(!dst.path().join(".jj").join(".gitignore").exists());
    assert_eq!(
        ops(&mut repo)[..3],
        [
            "check out git remote's branch: feature",
            "fetch from git remote into empty repo",
            "add git remote up",
        ]
    );
    assert!(
        !tracked(&mut repo, "feature", "up"),
        "only the DEFAULT branch is tracked"
    );
    assert_eq!(
        repo_config(dst.path()).expect("presets written"),
        format!("{SCHEMA}[remotes.up]\nfetch-bookmarks = \"feature\"\nfetch-tags = \"v1\"\n")
    );
    assert_eq!(descriptions(&mut repo, "@-"), ["feature\n"]);
}

/// `-b` alone presets the tags to `~*` (nothing); an exact `-b` the remote lacks warns the CLI's
/// "No matching branches found on remote", and the default branch is not checked out.
#[test]
fn an_unmatched_exact_branch_warns_and_an_empty_side_presets_nothing() {
    let src = TempDir::new().unwrap();
    source_repo(src.path());
    let dst = TempDir::new().unwrap();
    let outcome = clone(&CloneOptions {
        source: file_url(src.path()),
        destination: dst.path().to_owned(),
        colocate: Some(false),
        branches: Some(vec!["nope".to_owned(), "main".to_owned()]),
        ..Default::default()
    });
    let mut repo = outcome.result.expect("clone succeeds");
    let warnings: Vec<_> = outcome.warnings.iter().map(|w| (w.kind, w.message.as_str())).collect();
    assert_eq!(
        warnings,
        [(
            WarningKind::CloneBranchesUnmatched,
            "No matching branches found on remote: nope"
        )]
    );
    assert_eq!(
        repo_config(dst.path()).expect("presets written"),
        format!("{SCHEMA}[remotes.origin]\nfetch-bookmarks = \"nope | main\"\nfetch-tags = \"~*\"\n\n[revset-aliases]\n\"trunk()\" = \"main@origin\"\n")
    );
    assert!(repo.list_tags().expect("tags").is_empty(), "no tag fetched");
}

/// `--depth 1`: a shallow clone of the default branch's tip only.
#[test]
fn a_shallow_clone_fetches_one_commit() {
    let src = TempDir::new().unwrap();
    source_repo(src.path());
    let dst = TempDir::new().unwrap();
    let mut repo = clone(&CloneOptions {
        source: file_url(src.path()),
        destination: dst.path().to_owned(),
        colocate: Some(false),
        depth: NonZeroU32::new(1),
        branches: Some(vec!["main".to_owned()]),
        ..Default::default()
    })
    .result
    .expect("clone succeeds");
    assert_eq!(descriptions(&mut repo, "::main@origin ~ root()"), ["second\n"]);
}

/// A destination that is a file is refused before anything is created.
#[test]
fn a_file_destination_is_refused() {
    let dir = TempDir::new().unwrap();
    let file = dir.path().join("file");
    fs::write(&file, "x").unwrap();
    let outcome = clone(&CloneOptions {
        source: "file:///nowhere".to_owned(),
        destination: file.clone(),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::DestinationNotEmpty { ref path }) if *path == file),
        "{:?}",
        outcome.result
    );
}

/// A failing fetch (no such source) is a network error — the `git` subprocess could not reach the
/// source, the same class `git_fetch` reports — and removes `.jj` and `.git` and the destination
/// the clone created, while keeping a pre-existing (empty) destination (Story 9.20 closing run).
#[test]
fn a_failing_fetch_is_a_network_error_and_cleans_up_what_the_clone_created() {
    let parent = TempDir::new().unwrap();
    let created = parent.path().join("created");
    let outcome = clone(&CloneOptions {
        source: format!("file://{}", parent.path().join("missing").display()),
        destination: created.clone(),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::NetworkError { ref reason }) if !reason.is_empty()),
        "{:?}",
        outcome.result
    );
    assert!(!created.exists(), "the destination the clone created is removed");

    let existing = TempDir::new().unwrap();
    let outcome = clone(&CloneOptions {
        source: format!("file://{}", parent.path().join("missing").display()),
        destination: existing.path().to_owned(),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::NetworkError { .. })),
        "{:?}",
        outcome.result
    );
    assert!(existing.path().is_dir(), "a pre-existing destination stays");
    assert_eq!(
        fs::read_dir(existing.path()).unwrap().count(),
        0,
        ".jj and .git are removed"
    );
}

/// An empty `-b` list (tags not given) makes both fetch expressions `none()`, so jj-lib's `fetch`
/// returns without running git (no refspecs remain) and the default-branch query (`git remote
/// show`) is the first git call: its failure is a network error too, and the clean-up removes the
/// destination the clone created (Story 9.20 closing run).
#[test]
fn a_failing_default_branch_query_is_a_network_error_and_cleans_up() {
    let parent = TempDir::new().unwrap();
    let created = parent.path().join("created");
    let outcome = clone(&CloneOptions {
        source: format!("file://{}", parent.path().join("missing").display()),
        destination: created.clone(),
        branches: Some(vec![]),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::NetworkError { ref reason }) if !reason.is_empty()),
        "{:?}",
        outcome.result
    );
    assert!(!created.exists(), "the destination the clone created is removed");
}

/// An invalid remote name (the reserved `git`, a slash) is invalid input with jj-lib's reason,
/// refused inside the clean-up scope at `add git remote` (Story 9.20 closing run).
#[test]
fn an_invalid_remote_name_is_invalid_input_and_cleans_up() {
    let src = TempDir::new().unwrap();
    source_repo(src.path());
    let parent = TempDir::new().unwrap();
    for (name, expected) in [("git", "reserved"), ("a/b", "slashes")] {
        let dst = parent.path().join("dst");
        let outcome = clone(&CloneOptions {
            source: file_url(src.path()),
            destination: dst.clone(),
            remote_name: Some(name.to_owned()),
            ..Default::default()
        });
        assert!(
            matches!(outcome.result, Err(RepoError::InvalidInput { ref reason }) if reason.contains(expected)),
            "{name}: {:?}",
            outcome.result
        );
        assert!(!dst.exists(), "{name}: the destination the clone created is removed");
    }
}

/// A `-b` pattern that does not parse is refused (the destination was already created, as in the
/// CLI, and stays).
#[test]
fn an_unparsable_branch_pattern_is_refused() {
    let parent = TempDir::new().unwrap();
    let dst = parent.path().join("dst");
    let outcome = clone(&CloneOptions {
        source: "file:///nowhere".to_owned(),
        destination: dst.clone(),
        branches: Some(vec!["glob:[".to_owned()]),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::InvalidInput { .. })),
        "{:?}",
        outcome.result
    );
    assert!(dst.is_dir() && fs::read_dir(&dst).unwrap().count() == 0);
}

/// `-t` given with nothing (and an explicit object hash): no tag and no bookmark is fetched, and
/// both fetch presets read `~*` (`join_string_expressions`, `mod.rs:276-281` @ v0.46.0).
#[test]
fn a_tag_flag_with_nothing_fetches_nothing() {
    let src = TempDir::new().unwrap();
    source_repo(src.path());
    let dst = TempDir::new().unwrap();
    let mut repo = clone(&CloneOptions {
        source: file_url(src.path()),
        destination: dst.path().to_owned(),
        colocate: Some(false),
        object_hash: Some(ObjectHash::Sha1),
        tags: Some(Vec::new()),
        ..Default::default()
    })
    .result
    .expect("clone succeeds");
    assert!(
        repo.list_tags().expect("tags").is_empty(),
        "-t with nothing fetches no tag"
    );
    assert_eq!(
        repo_config(dst.path()).expect("presets written"),
        format!("{SCHEMA}[remotes.origin]\nfetch-bookmarks = \"~*\"\nfetch-tags = \"~*\"\n")
    );
}

// ── init ──────────────────────────────────────────────────────────────────────────

/// `jj git init` into a missing destination: created (one level), colocated by default, with
/// `.jj/.gitignore`; no operation beyond `add workspace`.
#[test]
fn a_default_git_init_creates_a_colocated_workspace() {
    let parent = TempDir::new().unwrap();
    let dst = parent.path().join("new");
    let outcome = init(&InitOptions {
        path: dst.clone(),
        backend: Some(Backend::Git),
        ..Default::default()
    });
    let mut repo = outcome.result.expect("init succeeds");
    assert!(outcome.warnings.is_empty() && outcome.precondition.is_none());
    assert!(dst.join(".git").is_dir());
    assert_eq!(fs::read_to_string(dst.join(".jj").join(".gitignore")).unwrap(), "/*\n");
    assert_eq!(ops(&mut repo)[0], "add workspace 'default'");
}

/// `--no-colocate`: an internal git repo, no `.git`, no `.jj/.gitignore`; an existing empty
/// directory is reused.
#[test]
fn a_no_colocate_init_reuses_an_empty_directory() {
    let dst = TempDir::new().unwrap();
    let outcome = init(&InitOptions {
        path: dst.path().to_owned(),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    });
    outcome.result.expect("init succeeds");
    assert!(!dst.path().join(".git").exists());
    assert!(!dst.path().join(".jj").join(".gitignore").exists());
}

/// `--object-hash sha256` reaches the new git repository.
#[test]
fn the_object_hash_is_passed_through() {
    let dst = TempDir::new().unwrap();
    init(&InitOptions {
        path: dst.path().to_owned(),
        backend: Some(Backend::Git),
        object_hash: Some(ObjectHash::Sha256),
        ..Default::default()
    })
    .result
    .expect("init succeeds");
    assert_eq!(git(&["rev-parse", "--show-object-format"], dst.path()), "sha256");
}

/// The destination is created one level only, and a file cannot be one: "Failed to create
/// workspace".
#[test]
fn an_uncreatable_init_destination_is_refused() {
    let parent = TempDir::new().unwrap();
    for path in [parent.path().join("a").join("b"), {
        let file = parent.path().join("file");
        fs::write(&file, "x").unwrap();
        file
    }] {
        let outcome = init(&InitOptions {
            path: path.clone(),
            backend: Some(Backend::Git),
            ..Default::default()
        });
        assert!(
            matches!(&outcome.result, Err(RepoError::InitFailed { reason }) if reason.starts_with("Failed to create workspace: ")),
            "{path:?}: {:?}",
            outcome.result
        );
    }
}

/// Over an existing `.git`, a dangling `.jj` symlink is an existing workspace, as jj-lib's
/// `create_dir` refuses it (`DestinationExists`).
#[test]
fn a_dangling_jj_symlink_over_git_is_an_existing_workspace() {
    let dir = TempDir::new().unwrap();
    source_repo(dir.path());
    std::os::unix::fs::symlink(dir.path().join("nowhere"), dir.path().join(".jj")).unwrap();
    let outcome = init(&InitOptions {
        path: dir.path().to_owned(),
        backend: Some(Backend::Git),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::AlreadyJjRepo { .. })),
        "{:?}",
        outcome.result
    );
}

/// Over an existing `.git`: colocated, the External flow (`import git refs`, the snapshot, the
/// `trunk()` alias); `--no-colocate`, the CLI's refusal; over a `.jj`, already a jj repo.
#[test]
fn init_over_an_existing_repository_follows_the_cli_modes() {
    let dir = TempDir::new().unwrap();
    source_repo(dir.path());
    let outcome = init(&InitOptions {
        path: dir.path().to_owned(),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::GitRepoExists { .. })),
        "{:?}",
        outcome.result
    );
    assert!(!dir.path().join(".jj").exists());

    let outcome = init(&InitOptions {
        path: dir.path().to_owned(),
        backend: Some(Backend::Git),
        ..Default::default()
    });
    let mut repo = outcome.result.expect("the External flow succeeds");
    assert!(outcome.precondition.is_some(), "the External flow snapshots");
    assert!(ops(&mut repo).contains(&"import git refs".to_owned()));
    assert_eq!(
        fs::read_to_string(dir.path().join(".jj").join(".gitignore")).unwrap(),
        "/*\n"
    );

    let outcome = init(&InitOptions {
        path: dir.path().to_owned(),
        backend: Some(Backend::Git),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::AlreadyJjRepo { .. })),
        "{:?}",
        outcome.result
    );
    let empty = TempDir::new().unwrap();
    init(&InitOptions {
        path: empty.path().to_owned(),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init");
    let outcome = init(&InitOptions {
        path: empty.path().to_owned(),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::AlreadyJjRepo { .. })),
        "{:?}",
        outcome.result
    );
}

// ── config-driven defaults ────────────────────────────────────────────────────────

/// Set in a child process: the path of the user config file it runs with.
const CHILD_USER_CONFIG: &str = "ZANSHIN_CLONE_INIT_USER_CONFIG";

/// Runs `body` with `config` as the USER config layer (`JJ_CONFIG`). The calling test `test` (its
/// exact libtest name, `clone_init::<fn>`) re-runs itself in a child process with
/// [`CHILD_USER_CONFIG`] set; only the child repoints `JJ_CONFIG` and runs `body`, so no other
/// test of this binary sees the change. The parent asserts that the child ran exactly that one
/// test and that it passed.
fn with_user_config(test: &str, config: &str, body: impl FnOnce()) {
    if let Some(path) = env::var_os(CHILD_USER_CONFIG) {
        test_helpers::pin_test_env();
        // SAFETY: the child runs this one test only (`--exact`), on one thread.
        unsafe { env::set_var("JJ_CONFIG", path) };
        body();
        return;
    }
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("config.toml");
    fs::write(&path, config).unwrap();
    let out = Command::new(env::current_exe().expect("test binary"))
        .args([test, "--exact", "--nocapture", "--test-threads=1"])
        .env(CHILD_USER_CONFIG, &path)
        .output()
        .expect("the test binary re-runs");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success() && stdout.contains("1 passed"),
        "child run of {test} failed:\n{stdout}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// Removes the identity variables [`test_helpers::pin_test_env`] sets — an empty identity. Only
/// inside a [`with_user_config`] body (the child process).
fn unset_identity() {
    // SAFETY: called only in the single-test child process of `with_user_config`.
    unsafe {
        env::remove_var("JJ_USER");
        env::remove_var("JJ_EMAIL");
    }
}

/// `git.track-default-bookmark-on-clone = false` (`clone.rs:390,447-455` @ v0.46.0): the default
/// branch is still the working branch (checked out, `trunk()` preset) but `main@origin` stays
/// untracked and no local `main` is created.
#[test]
fn track_default_bookmark_on_clone_false_leaves_the_default_branch_untracked() {
    with_user_config(
        "clone_init::track_default_bookmark_on_clone_false_leaves_the_default_branch_untracked",
        "[git]\ntrack-default-bookmark-on-clone = false\n",
        || {
            let src = TempDir::new().unwrap();
            source_repo(src.path());
            let dst = TempDir::new().unwrap();
            let outcome = clone(&CloneOptions {
                source: file_url(src.path()),
                destination: dst.path().to_owned(),
                ..Default::default()
            });
            let mut repo = outcome.result.expect("clone succeeds");
            assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
            let bookmarks = repo.list_bookmarks().expect("bookmarks");
            assert!(
                bookmarks.iter().any(|b| b.name == "main"
                    && matches!(&b.kind, BookmarkKind::Remote { remote_name, tracked: false, .. } if remote_name == "origin")),
                "main@origin is fetched, untracked: {bookmarks:?}"
            );
            assert!(
                !bookmarks
                    .iter()
                    .any(|b| b.name == "main" && matches!(b.kind, BookmarkKind::Local)),
                "no local main: {bookmarks:?}"
            );
            assert_eq!(ops(&mut repo)[0], "check out git remote's branch: main");
            assert_eq!(descriptions(&mut repo, "@-"), ["second\n"]);
            assert_eq!(descriptions(&mut repo, "trunk()"), ["second\n"]);
        },
    );
}

/// `remotes.origin.fetch-bookmarks = "feature"` with no `-b` (`clone.rs:231-238` @ v0.46.0): only
/// `feature` is fetched. The configured expression's exact name is the working branch
/// (`clone.rs:414-434`), so `feature` is checked out — but it is not the default branch, so it is
/// not tracked and no `trunk()` is preset; no `-b`/`-t` given, no fetch preset is written either.
#[test]
fn remote_fetch_bookmarks_config_limits_the_clone() {
    with_user_config(
        "clone_init::remote_fetch_bookmarks_config_limits_the_clone",
        "[remotes.origin]\nfetch-bookmarks = \"feature\"\n",
        || {
            let src = TempDir::new().unwrap();
            source_repo(src.path());
            let dst = TempDir::new().unwrap();
            let outcome = clone(&CloneOptions {
                source: file_url(src.path()),
                destination: dst.path().to_owned(),
                colocate: Some(false),
                ..Default::default()
            });
            let mut repo = outcome.result.expect("clone succeeds");
            assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
            let mut remote: Vec<String> = repo
                .list_bookmarks()
                .expect("bookmarks")
                .into_iter()
                .filter(|b| matches!(&b.kind, BookmarkKind::Remote { remote_name, .. } if remote_name == "origin"))
                .map(|b| b.name)
                .collect();
            remote.sort();
            assert_eq!(remote, ["feature"], "only the configured bookmark is fetched");
            assert!(!tracked(&mut repo, "feature", "origin"), "not the default branch");
            assert_eq!(
                ops(&mut repo)[..3],
                [
                    "check out git remote's branch: feature",
                    "fetch from git remote into empty repo",
                    "add git remote origin",
                ]
            );
            assert_eq!(descriptions(&mut repo, "@-"), ["feature\n"]);
            assert_eq!(repo_config(dst.path()), None, "nothing to preset");
        },
    );
}

/// `git.colocate = false` with no colocation flag (`init.rs:166-170`, `clone.rs:198-202` @
/// v0.46.0): both `jj git init` and `jj git clone` create an internal Git repo — no `.git` in the
/// workspace root, no `.jj/.gitignore`, the Git store under `.jj/repo/store/git`.
#[test]
fn git_colocate_false_makes_init_and_clone_internal() {
    with_user_config(
        "clone_init::git_colocate_false_makes_init_and_clone_internal",
        "[git]\ncolocate = false\n",
        || {
            let internal = |root: &Path| {
                assert!(!root.join(".git").exists(), "{root:?}: not colocated");
                assert!(!root.join(".jj").join(".gitignore").exists(), "{root:?}");
                assert!(
                    root.join(".jj").join("repo").join("store").join("git").is_dir(),
                    "{root:?}: the Git store is internal"
                );
            };

            let parent = TempDir::new().unwrap();
            let dst = parent.path().join("init");
            init(&InitOptions {
                path: dst.clone(),
                backend: Some(Backend::Git),
                ..Default::default()
            })
            .result
            .expect("init succeeds");
            internal(&dst);

            let src = TempDir::new().unwrap();
            source_repo(src.path());
            let dst = parent.path().join("clone");
            let mut repo = clone(&CloneOptions {
                source: file_url(src.path()),
                destination: dst.clone(),
                ..Default::default()
            })
            .result
            .expect("clone succeeds");
            internal(&dst);
            assert_eq!(descriptions(&mut repo, "@-"), ["second\n"]);
        },
    );
}

/// `git.object-hash = "sha256"` with no `--object-hash` (`init.rs:172-175`, `clone.rs:212-215` @
/// v0.46.0) reaches the new Git repository — for `jj git init`, and for a clone of a SHA-256
/// source (a SHA-1 source cannot be fetched into a SHA-256 repository).
#[test]
fn git_object_hash_config_reaches_the_new_repository() {
    with_user_config(
        "clone_init::git_object_hash_config_reaches_the_new_repository",
        "[git]\nobject-hash = \"sha256\"\n",
        || {
            let parent = TempDir::new().unwrap();
            let dst = parent.path().join("init");
            init(&InitOptions {
                path: dst.clone(),
                backend: Some(Backend::Git),
                ..Default::default()
            })
            .result
            .expect("init succeeds");
            assert_eq!(git(&["rev-parse", "--show-object-format"], &dst), "sha256");

            let src = TempDir::new().unwrap();
            git(&["init", "--object-format=sha256", "--initial-branch=main"], src.path());
            git(&["config", "user.email", "test@zanshin.test"], src.path());
            git(&["config", "user.name", "Fixture"], src.path());
            fs::write(src.path().join("README.md"), "hello").unwrap();
            git(&["add", "."], src.path());
            git(&["commit", "-m", "initial"], src.path());
            let dst = parent.path().join("clone");
            let mut repo = clone(&CloneOptions {
                source: file_url(src.path()),
                destination: dst.clone(),
                ..Default::default()
            })
            .result
            .expect("clone succeeds");
            assert_eq!(git(&["rev-parse", "--show-object-format"], &dst), "sha256");
            assert_eq!(descriptions(&mut repo, "@-"), ["initial\n"]);
        },
    );
}

/// A clone whose fetch fails (the source is no Git repository) with an EMPTY identity keeps the
/// identity warning of the `add git remote` operation finished before the fetch — the CLI prints
/// it from that finish (`cli_util.rs:2442-2456` @ v0.46.0) before the fetch error; the clean-up
/// still removes the destination the clone created.
#[test]
fn a_failing_fetch_keeps_the_identity_warning_of_the_finished_add_remote() {
    with_user_config(
        "clone_init::a_failing_fetch_keeps_the_identity_warning_of_the_finished_add_remote",
        "",
        || {
            unset_identity();
            let parent = TempDir::new().unwrap();
            let not_a_repo = parent.path().join("plain");
            fs::create_dir(&not_a_repo).unwrap();
            let dst = parent.path().join("dst");
            let outcome = clone(&CloneOptions {
                source: file_url(&not_a_repo),
                destination: dst.clone(),
                ..Default::default()
            });
            assert!(
                matches!(outcome.result, Err(RepoError::NetworkError { .. })),
                "{:?}",
                outcome.result
            );
            let kinds: Vec<_> = outcome.warnings.iter().map(|w| w.kind).collect();
            assert_eq!(kinds, [WarningKind::IdentityMissing], "{:?}", outcome.warnings);
            assert!(!dst.exists(), "the destination the clone created is removed");
        },
    );
}

/// The native backend is unchanged and refuses the Git-only flags.
#[test]
fn the_native_backend_refuses_git_flags() {
    let dst = TempDir::new().unwrap();
    for (colocate, object_hash) in [(Some(true), None), (None, Some(ObjectHash::Sha1))] {
        let outcome = init(&InitOptions {
            path: dst.path().to_owned(),
            backend: None,
            colocate,
            object_hash,
        });
        assert!(
            matches!(outcome.result, Err(RepoError::InvalidInput { .. })),
            "{:?}",
            outcome.result
        );
    }
    assert!(!dst.path().join(".jj").exists());
}
