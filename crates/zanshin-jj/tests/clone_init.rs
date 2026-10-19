// SPDX-License-Identifier: MIT

//! Story 9.20 witnesses for `Repo::clone` and `Repo::init` — `jj git clone` / `jj git init` at
//! v0.46.0: destination rules, colocation, the clone's three operations, the repo presets, the
//! clean-up scope, the init modes. Sources are local git repositories (`file://`), never the
//! network. The identity and warning ORDER rows live in `tests/creation_warnings.rs` (they need
//! an empty identity); the oracle (`crates/zanshin-parity`) compares the same flows with the CLI.

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

/// Runs `git` in `dir`; panics on a non-zero exit. Fixture setup only.
fn git(args: &[&str], dir: &Path) -> String {
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
    Repo::clone(options, &|_: ProgressEvent| {})
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

/// A failing fetch (no such source) removes `.jj` and `.git` and the destination the clone
/// created — and keeps a pre-existing (empty) destination.
#[test]
fn a_failing_fetch_cleans_up_what_the_clone_created() {
    let parent = TempDir::new().unwrap();
    let created = parent.path().join("created");
    let outcome = clone(&CloneOptions {
        source: format!("file://{}", parent.path().join("missing").display()),
        destination: created.clone(),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::CloneFailed { .. })),
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
        matches!(outcome.result, Err(RepoError::CloneFailed { .. })),
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

/// An invalid remote name fails inside the clean-up scope, at `add git remote`.
#[test]
fn an_invalid_remote_name_fails_and_cleans_up() {
    let src = TempDir::new().unwrap();
    source_repo(src.path());
    let parent = TempDir::new().unwrap();
    let dst = parent.path().join("dst");
    let outcome = clone(&CloneOptions {
        source: file_url(src.path()),
        destination: dst.clone(),
        remote_name: Some("git".to_owned()),
        ..Default::default()
    });
    assert!(
        matches!(outcome.result, Err(RepoError::CloneFailed { .. })),
        "{:?}",
        outcome.result
    );
    assert!(!dst.exists());
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
