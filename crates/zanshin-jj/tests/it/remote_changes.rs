// SPDX-License-Identifier: MIT

//! Story 9.24 witnesses: `Repo::remote_changes`, the `git ls-remote` poll, against a local bare
//! remote built with the `git` CLI. Upstream changes are made in the source repo and pushed to
//! the bare remote, so the workspace's view keeps the targets of its last fetch. The cancel rows
//! live in `tests/it/network_cancel.rs`; the parse and diff rules are inline unit tests.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;
use zanshin_jj::{
    CloneOptions, CommitId, InitOptions, MutateError, ProgressEvent, RemoteRefChange, RemoteRefChangeKind,
    RemoteRefKind, Repo,
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

/// A workspace cloned (not colocated) from a bare remote with branches `main` and `x`, and the
/// source repo that pushes upstream changes to that remote as its `origin`.
struct World {
    _dirs: Vec<TempDir>,
    src: PathBuf,
    bare: PathBuf,
    root: PathBuf,
    repo: Repo,
}

fn world() -> World {
    test_helpers::pin_test_env();
    let src_dir = TempDir::new().unwrap();
    let src = src_dir.path().to_owned();
    git(&["init", "--initial-branch=main"], &src);
    git(&["config", "user.email", "test@zanshin.test"], &src);
    git(&["config", "user.name", "Fixture"], &src);
    commit(&src, "README.md", "hello");
    git(&["branch", "x"], &src);
    let parent = TempDir::new().unwrap();
    let bare = parent.path().join("remote.git");
    git(
        &["clone", "--bare", &src.to_string_lossy(), &bare.to_string_lossy()],
        parent.path(),
    );
    git(&["remote", "add", "origin", &bare.to_string_lossy()], &src);
    let ws = TempDir::new().unwrap();
    let root = ws.path().join("ws");
    let repo = Repo::clone(
        &CloneOptions {
            source: bare.to_string_lossy().into_owned(),
            destination: root.clone(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: ProgressEvent| {},
        None,
    )
    .result
    .expect("clone the remote");
    World {
        _dirs: vec![src_dir, parent, ws],
        src,
        bare,
        root: fs::canonicalize(root).unwrap(),
        repo,
    }
}

/// Writes `file` in `dir` and commits it; returns the new commit's hex.
fn commit(dir: &Path, file: &str, text: &str) -> String {
    fs::write(dir.join(file), text).unwrap();
    git(&["add", "."], dir);
    git(&["commit", "-m", text], dir);
    git(&["rev-parse", "HEAD"], dir)
}

fn id(hex: &str) -> CommitId {
    CommitId(hex.to_owned())
}

fn change(
    kind: RemoteRefKind,
    name: &str,
    change: RemoteRefChangeKind,
    old: &[&str],
    new: Option<&str>,
) -> RemoteRefChange {
    RemoteRefChange {
        kind,
        name: name.to_owned(),
        change,
        old_commit_ids: old.iter().map(|hex| id(hex)).collect(),
        new_commit_id: new.map(id),
    }
}

impl World {
    fn upstream(&self, rev: &str) -> String {
        git(&["rev-parse", rev], &self.bare)
    }

    /// The operation heads on disk — read without `Repo::op_log`, whose pre-verb snapshot would
    /// itself write an operation for a dirty working copy.
    fn head_op(&self) -> Vec<String> {
        let dir = self.root.join(".jj").join("repo").join("op_heads").join("heads");
        let mut heads: Vec<String> = fs::read_dir(dir)
            .expect("op heads")
            .map(|entry| entry.expect("entry").file_name().to_string_lossy().into_owned())
            .collect();
        heads.sort();
        heads
    }

    fn poll(&mut self, remote: &str) -> Result<Vec<RemoteRefChange>, MutateError> {
        self.repo.remote_changes(remote, None)
    }

    /// Sets the repo's `git.executable-path` (repo-level config) and reopens the handle.
    fn set_git_executable(&mut self, path: &str) {
        let id = fs::read_to_string(self.root.join(".jj").join("repo").join("config-id")).expect("config-id");
        let xdg = PathBuf::from(std::env::var_os("XDG_CONFIG_HOME").expect("pinned"));
        let config = xdg.join("jj").join("repos").join(id.trim()).join("config.toml");
        let existing = fs::read_to_string(&config).unwrap_or_default();
        fs::write(&config, format!("{existing}\n[git]\nexecutable-path = '{path}'\n")).expect("write the repo config");
        self.repo = Repo::open(&self.root).expect("reopen");
    }
}

/// Right after the fetch nothing is new, and the poll writes no operation.
#[test]
fn a_freshly_fetched_clone_has_nothing_new() {
    let mut w = world();
    let before = w.head_op();
    assert_eq!(w.poll("origin").expect("poll"), []);
    assert_eq!(w.head_op(), before, "no operation");
    assert!(w.repo.take_precondition().is_none(), "no pre-verb snapshot");
}

/// Upstream `main` advanced: one moved bookmark, the view untouched — a second poll answers the
/// same, and only the fetch makes it go away.
#[test]
fn an_advanced_upstream_branch_is_moved_and_the_view_is_untouched() {
    let mut w = world();
    let old = w.upstream("main");
    let new = commit(&w.src, "second.txt", "second");
    git(&["push", "origin", "main"], &w.src);
    let before = w.head_op();
    let expected = [change(
        RemoteRefKind::Bookmark,
        "main",
        RemoteRefChangeKind::Moved,
        &[&old],
        Some(&new),
    )];
    assert_eq!(w.poll("origin").expect("poll"), expected);
    assert_eq!(w.head_op(), before, "no operation");
    assert_eq!(w.poll("origin").expect("poll again"), expected, "main@origin unchanged");

    w.repo
        .git_fetch(&zanshin_jj::GitFetchArgs::default(), &|_: ProgressEvent| {}, None)
        .expect("fetch");
    assert_eq!(w.poll("origin").expect("poll after the fetch"), []);
}

/// A new branch, a lightweight and an annotated tag are new; the annotated tag at the commit it
/// peels to, not at the tag object.
#[test]
fn new_branches_and_tags_are_new_and_an_annotated_tag_is_peeled() {
    let mut w = world();
    git(&["checkout", "-b", "feature"], &w.src);
    let feature = commit(&w.src, "feature.txt", "feature");
    git(&["tag", "t1"], &w.src);
    git(&["tag", "-a", "v1", "-m", "release"], &w.src);
    git(&["push", "origin", "feature", "--tags"], &w.src);
    let tag_object = w.upstream("v1");
    assert_ne!(tag_object, feature, "v1 is an annotated tag object");
    assert_eq!(
        w.poll("origin").expect("poll"),
        [
            change(
                RemoteRefKind::Bookmark,
                "feature",
                RemoteRefChangeKind::New,
                &[],
                Some(&feature)
            ),
            change(RemoteRefKind::Tag, "t1", RemoteRefChangeKind::New, &[], Some(&feature)),
            change(RemoteRefKind::Tag, "v1", RemoteRefChangeKind::New, &[], Some(&feature)),
        ]
    );
}

/// Fetched tags are compared as the view holds them — an annotated tag at its peeled commit: right
/// after the fetch nothing is new; a moved lightweight tag is moved, a removed annotated tag deleted.
#[test]
fn fetched_tags_are_compared_at_their_peeled_commits() {
    let mut w = world();
    let first = w.upstream("main");
    git(&["tag", "t1"], &w.src);
    git(&["tag", "-a", "v1", "-m", "release"], &w.src);
    git(&["push", "origin", "--tags"], &w.src);
    w.repo
        .git_fetch(&zanshin_jj::GitFetchArgs::default(), &|_: ProgressEvent| {}, None)
        .expect("fetch");
    assert_eq!(w.poll("origin").expect("poll after the fetch"), []);

    let second = commit(&w.src, "second.txt", "second");
    git(&["tag", "-f", "t1"], &w.src);
    git(&["push", "--force", "origin", "t1"], &w.src);
    git(&["push", "origin", "--delete", "v1"], &w.src);
    assert_eq!(
        w.poll("origin").expect("poll"),
        [
            change(
                RemoteRefKind::Tag,
                "t1",
                RemoteRefChangeKind::Moved,
                &[&first],
                Some(&second)
            ),
            change(RemoteRefKind::Tag, "v1", RemoteRefChangeKind::Deleted, &[&first], None),
        ]
    );

    w.repo
        .git_fetch(&zanshin_jj::GitFetchArgs::default(), &|_: ProgressEvent| {}, None)
        .expect("fetch");
    assert_eq!(
        w.poll("origin").expect("poll after the second fetch"),
        [],
        "the fetch prunes v1@origin"
    );
}

/// A branch removed upstream is deleted.
#[test]
fn a_branch_removed_upstream_is_deleted() {
    let mut w = world();
    let x = w.upstream("x");
    git(&["push", "origin", "--delete", "x"], &w.src);
    assert_eq!(
        w.poll("origin").expect("poll"),
        [change(
            RemoteRefKind::Bookmark,
            "x",
            RemoteRefChangeKind::Deleted,
            &[&x],
            None
        )]
    );

    w.repo
        .git_fetch(&zanshin_jj::GitFetchArgs::default(), &|_: ProgressEvent| {}, None)
        .expect("fetch");
    assert_eq!(
        w.poll("origin").expect("poll after the fetch"),
        [],
        "the fetch prunes x@origin"
    );
}

/// A remote that was never fetched: every advertised ref is new.
#[test]
fn a_never_fetched_remote_has_every_ref_new() {
    let mut w = world();
    let bare = w.bare.to_string_lossy().into_owned();
    w.repo.git_remote_add("upstream", &bare, None).expect("add a remote");
    let main = w.upstream("main");
    assert_eq!(
        w.poll("upstream").expect("poll"),
        [
            change(
                RemoteRefKind::Bookmark,
                "main",
                RemoteRefChangeKind::New,
                &[],
                Some(&main)
            ),
            change(RemoteRefKind::Bookmark, "x", RemoteRefChangeKind::New, &[], Some(&main)),
        ]
    );
}

/// A dirty working copy is not snapshotted: no `snapshot working copy` operation, so the
/// operation heads (and with them `@`) stay as they were.
#[test]
fn a_dirty_working_copy_is_not_snapshotted() {
    let mut w = world();
    let before = w.head_op();
    fs::write(w.root.join("dirty.txt"), "edited").unwrap();
    assert_eq!(w.poll("origin").expect("poll"), []);
    assert_eq!(w.head_op(), before, "no snapshot operation, `@` unchanged");
    assert!(w.root.join("dirty.txt").exists());
}

/// An unknown remote refuses before git runs: with a git that cannot be spawned the answer is
/// still `RemoteNotFound`, not a network error.
#[test]
fn an_unknown_remote_refuses_before_git_runs() {
    let mut w = world();
    w.set_git_executable("/nonexistent/zanshin-git");
    let result = w.poll("nope");
    assert!(
        matches!(&result, Err(MutateError::RemoteNotFound { name }) if name == "nope"),
        "{result:?}"
    );
    let spawn = w.poll("origin");
    assert!(matches!(spawn, Err(MutateError::NetworkError { .. })), "{spawn:?}");
}

/// A native backend has no remotes to ask.
#[test]
fn a_native_backend_is_not_a_git_repo() {
    test_helpers::pin_test_env();
    let native = TempDir::new().unwrap();
    let mut repo = Repo::init(&InitOptions {
        path: native.path().to_owned(),
        ..Default::default()
    })
    .result
    .expect("native init");
    let result = repo.remote_changes("origin", None);
    assert!(matches!(result, Err(MutateError::NotAGitRepo)), "{result:?}");
}

/// A remote whose URL points at a missing path: git fails, and its stderr is the reason.
#[test]
fn a_failing_git_is_a_network_error() {
    let mut w = world();
    w.repo
        .git_remote_add("broken", "/nonexistent/zanshin-remote.git", None)
        .expect("add a remote");
    match w.poll("broken") {
        Err(MutateError::NetworkError { reason }) => {
            assert!(reason.starts_with("External git program failed:"), "{reason}");
        }
        other => panic!("expected a network error, got {other:?}"),
    }
}
