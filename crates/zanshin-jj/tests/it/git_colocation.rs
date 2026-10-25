// SPDX-License-Identifier: MIT

//! Story 9.45 — `Repo::git_colocation_status`, `git_colocation_enable` and
//! `git_colocation_disable`, one witness per row of the I/O matrix, read back from disk (the
//! `.git` kind, `store/git_target`, `core.bare`, `.jj/.gitignore`), through `git` and through a
//! fresh `Repo::open`. Every repo is built in-test under `<tmp>/main` (a child workspace at
//! `<tmp>/ws2`). The CLI comparison lives in the parity oracle (`crates/zanshin-parity`).

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::Repo as _;
use tempfile::TempDir;
use zanshin_jj::{Backend, CommitOptions, GitColocationStatus, MutateError, Repo, SparseInheritance, WarningKind};

use crate::workspace_update_stale::{descriptions, head_op, load};

const ENABLE_HINT: &str = "To enable colocation, run: `jj git colocation enable`";
const DISABLE_HINT: &str = "To disable colocation, run: `jj git colocation disable`";
const EXTERNAL_HINT: &str =
    "Colocation cannot be enabled because the workspace is backed by an external Git repository.";

struct Fx {
    tmp: TempDir,
    root: PathBuf,
}

impl Fx {
    fn ws2(&self) -> PathBuf {
        fs::canonicalize(self.tmp.path()).expect("canonical tmp").join("ws2")
    }
}

fn git(args: &[&str], dir: &Path) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("spawn git");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("utf-8").trim().to_owned()
}

/// A git-backed repo at `<tmp>/main` (`colocate` as `--colocate` / `--no-colocate`), `commit`ted
/// once (`f.txt`, "c1") when asked.
fn repo(colocate: bool, commit: bool) -> (Fx, Repo) {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let main = tmp.path().join("main");
    fs::create_dir(&main).expect("main dir");
    let mut repo = Repo::init(&zanshin_jj::InitOptions {
        path: main,
        backend: Some(Backend::Git),
        colocate: Some(colocate),
        ..Default::default()
    })
    .result
    .expect("init");
    let root = repo.workspace_root().to_owned();
    if commit {
        fs::write(root.join("f.txt"), "f").expect("write");
        repo.commit(&CommitOptions {
            message: vec!["c1".to_owned()],
            ..CommitOptions::default()
        })
        .expect("commit");
    }
    (Fx { tmp, root }, repo)
}

/// [`repo`] with one commit plus a workspace `ws2` (`colocate` as its `--colocate` flag),
/// returned as a handle at ws2.
fn child(colocate: bool) -> (Fx, Repo) {
    let (fx, mut main) = repo(colocate, true);
    let ws2 = main
        .workspace_add("../ws2", None, &[], &[], Some(colocate), SparseInheritance::Copy)
        .expect("add ws2")
        .workspace_root;
    assert_eq!(ws2, fx.ws2());
    drop(main);
    let handle = Repo::open(&ws2).expect("open ws2");
    (fx, handle)
}

fn store(root: &Path) -> PathBuf {
    root.join(".jj").join("repo").join("store")
}

fn git_target(root: &Path) -> String {
    fs::read_to_string(store(root).join("git_target")).expect("git_target")
}

/// The `bare = …` line of the Git config in `git_dir`.
fn core_bare(git_dir: &Path) -> String {
    fs::read_to_string(git_dir.join("config"))
        .expect("git config")
        .lines()
        .find(|line| line.trim_start().starts_with("bare"))
        .expect("core.bare")
        .trim()
        .to_owned()
}

fn gitignore(root: &Path) -> Option<String> {
    fs::read_to_string(root.join(".jj").join(".gitignore")).ok()
}

/// `name`'s `@-` commit id (hex), read through jj-lib from the workspace at `root`.
fn wc_parent(root: &Path, name: &str) -> String {
    let (_workspace, repo) = load(root);
    let id = repo.view().get_wc_commit_id(WorkspaceName::new(name)).expect("@");
    let commit = repo.store().get_commit(id).expect("@ commit");
    commit.parent_ids()[0].hex()
}

/// The view's Git HEAD of `name`, as a status would report it (hex of a normal target).
fn view_git_head(root: &Path, name: &str) -> Option<String> {
    let (_workspace, repo) = load(root);
    repo.view()
        .git_head(WorkspaceName::new(name))
        .as_normal()
        .map(jj_lib::object_id::ObjectId::hex)
}

fn reason(err: &MutateError) -> String {
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    err.to_string()
        .strip_prefix("invalid input: ")
        .expect("prefix")
        .to_owned()
}

fn status_of(root: &Path) -> GitColocationStatus {
    Repo::open(root).expect("open").git_colocation_status().expect("status")
}

// ── status ───────────────────────────────────────────────────────────────────────

#[test]
fn status_of_a_non_colocated_default_workspace() {
    let (fx, mut repo) = repo(false, false);
    let before = head_op(&fx.root);
    let status = repo.git_colocation_status().expect("status");
    assert!(!status.colocated);
    assert_eq!(status.workspace_name, "default");
    assert!(status.git_head.adds.is_empty() && !status.git_head.conflicted);
    assert!(!status.external_git_repo);
    assert_eq!(status.hints, [ENABLE_HINT]);
    assert_eq!(status.git_repo_path, store(&fx.root).join("git"));
    assert_eq!(head_op(&fx.root), before);
}

#[test]
fn status_of_a_colocated_workspace_reports_the_git_head() {
    let (fx, mut repo) = repo(true, true);
    let status = repo.git_colocation_status().expect("status");
    assert!(status.colocated);
    assert_eq!(status.hints, [DISABLE_HINT]);
    assert_eq!(status.git_head.adds.len(), 1);
    assert_eq!(status.git_head.adds[0].0, wc_parent(&fx.root, "default"));
    assert!(!status.external_git_repo);
}

/// A workspace on an external Git repository (`jj git init --git-repo=<ext>`).
fn external() -> (TempDir, PathBuf) {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let ext = tmp.path().join("ext");
    fs::create_dir(&ext).expect("ext dir");
    git(&["init", "--initial-branch=main"], &ext);
    git(&["config", "user.email", "test@zanshin.test"], &ext);
    git(&["config", "user.name", "Fixture"], &ext);
    fs::write(ext.join("README.md"), "hello").expect("write README");
    git(&["add", "."], &ext);
    git(&["commit", "-m", "initial"], &ext);
    let root = zanshin_jj::convert_import(&ext, &tmp.path().join("main"))
        .result
        .expect("convert")
        .workspace_root()
        .to_owned();
    (tmp, root)
}

#[test]
fn status_of_an_external_git_repo_says_colocation_cannot_be_enabled() {
    let (_tmp, root) = external();
    let status = status_of(&root);
    assert!(!status.colocated);
    assert!(status.external_git_repo);
    assert_eq!(status.hints, [EXTERNAL_HINT]);
}

// ── enable ───────────────────────────────────────────────────────────────────────

#[test]
fn enable_moves_the_git_repo_into_the_workspace_root() {
    let (fx, mut repo) = repo(false, true);
    let result = repo.git_colocation_enable().expect("enable");
    assert!(result.converted);
    assert!(!result.git_worktree_removed);
    assert!(fx.root.join(".git").is_dir());
    assert!(!store(&fx.root).join("git").exists());
    assert_eq!(git_target(&fx.root), "../../../.git");
    assert_eq!(core_bare(&fx.root.join(".git")), "bare = false");
    assert_eq!(gitignore(&fx.root).as_deref(), Some("/*\n"));
    let parent = wc_parent(&fx.root, "default");
    assert_eq!(git(&["rev-parse", "HEAD"], &fx.root), parent);
    assert_eq!(view_git_head(&fx.root, "default"), Some(parent));
    assert_eq!(descriptions(&fx.root)[0], "set git head to working copy parent");
    assert_eq!(result.mutation.new_op_id.0, head_op(&fx.root));
    assert!(result.mutation.working_copy_change_id.is_some());
    // The handle runs on the reloaded workspace, a fresh open agrees.
    assert!(repo.git_colocation_status().expect("status").colocated);
    assert!(status_of(&fx.root).colocated);
}

#[test]
fn enable_on_an_empty_repo_converts_without_an_operation() {
    let (fx, mut repo) = repo(false, false);
    let before = head_op(&fx.root);
    let result = repo.git_colocation_enable().expect("enable");
    assert!(result.converted);
    assert!(fx.root.join(".git").is_dir());
    assert_eq!(git_target(&fx.root), "../../../.git");
    assert_eq!(core_bare(&fx.root.join(".git")), "bare = false");
    assert_eq!(gitignore(&fx.root).as_deref(), Some("/*\n"));
    assert_eq!(head_op(&fx.root), before);
    assert_eq!(result.mutation.new_op_id.0, before);
    assert!(status_of(&fx.root).colocated);
}

#[test]
fn enable_on_a_colocated_workspace_converts_nothing() {
    let (fx, mut repo) = repo(true, true);
    let _ = repo.status().expect("settle");
    let before = head_op(&fx.root);
    let result = repo.git_colocation_enable().expect("enable");
    assert!(!result.converted);
    assert_eq!(result.mutation.new_op_id.0, before);
    assert_eq!(head_op(&fx.root), before);
}

#[test]
fn enable_with_an_existing_dot_git_refuses_and_leaves_the_store() {
    let (fx, mut repo) = repo(false, true);
    fs::create_dir(fx.root.join(".git")).expect("mkdir .git");
    fs::write(fx.root.join(".git").join("x"), "x").expect("fill .git");
    let _ = repo.status().expect("settle");
    let before = head_op(&fx.root);
    let err = repo.git_colocation_enable().expect_err("refused");
    assert_eq!(
        reason(&err),
        "A .git directory already exists in the workspace root. Cannot colocate."
    );
    assert!(store(&fx.root).join("git").is_dir());
    assert_eq!(git_target(&fx.root), "git");
    assert_eq!(head_op(&fx.root), before);
}

#[test]
fn enable_on_an_external_git_repo_refuses() {
    let (_tmp, root) = external();
    let mut repo = Repo::open(&root).expect("open");
    let path = repo.git_colocation_status().expect("status").git_repo_path;
    let err = repo.git_colocation_enable().expect_err("refused");
    assert_eq!(
        reason(&err),
        format!(
            "Cannot colocate a workspace backed by an external Git repository at {}",
            path.display()
        )
    );
}

// ── disable ──────────────────────────────────────────────────────────────────────

#[test]
fn disable_moves_the_git_repo_into_the_store() {
    let (fx, mut repo) = repo(true, true);
    assert_eq!(gitignore(&fx.root).as_deref(), Some("/*\n"));
    let result = repo.git_colocation_disable().expect("disable");
    assert!(result.converted);
    assert!(!result.git_worktree_removed);
    assert!(!fx.root.join(".git").exists());
    assert!(store(&fx.root).join("git").is_dir());
    assert_eq!(core_bare(&store(&fx.root).join("git")), "bare = true");
    assert_eq!(git_target(&fx.root), "git");
    assert_eq!(gitignore(&fx.root), None);
    assert_eq!(view_git_head(&fx.root, "default"), None);
    assert_eq!(descriptions(&fx.root)[0], "remove git head reference");
    assert_eq!(result.mutation.new_op_id.0, head_op(&fx.root));
    assert!(!repo.git_colocation_status().expect("status").colocated);
    assert!(!status_of(&fx.root).colocated);
}

#[test]
fn disable_on_a_non_colocated_workspace_converts_nothing() {
    let (fx, mut repo) = repo(false, true);
    let _ = repo.status().expect("settle");
    let before = head_op(&fx.root);
    let result = repo.git_colocation_disable().expect("disable");
    assert!(!result.converted);
    assert_eq!(result.mutation.new_op_id.0, before);
    assert_eq!(head_op(&fx.root), before);
}

#[test]
fn enable_then_disable_round_trips_the_layout() {
    let (fx, mut repo) = repo(false, true);
    let start = status_of(&fx.root);
    assert!(!start.colocated);
    assert!(repo.git_colocation_enable().expect("enable").converted);
    let enabled = status_of(&fx.root);
    assert!(enabled.colocated);
    assert_eq!(enabled.git_head.adds[0].0, wc_parent(&fx.root, "default"));
    assert!(repo.git_colocation_disable().expect("disable").converted);
    let disabled = status_of(&fx.root);
    assert_eq!(disabled, start);
    assert!(!fx.root.join(".git").exists());
    assert_eq!(git_target(&fx.root), "git");
    assert_eq!(core_bare(&store(&fx.root).join("git")), "bare = true");
    assert_eq!(gitignore(&fx.root), None);
}

// ── child workspaces ─────────────────────────────────────────────────────────────

#[test]
fn enable_in_a_child_workspace_creates_a_git_worktree() {
    let (fx, mut ws2) = child(false);
    let root = fx.ws2();
    assert!(!root.join(".git").exists());
    let result = ws2.git_colocation_enable().expect("enable");
    assert!(result.converted);
    assert!(root.join(".git").is_file());
    assert_eq!(gitignore(&root).as_deref(), Some("/*\n"));
    let parent = wc_parent(&root, "ws2");
    assert_eq!(view_git_head(&root, "ws2"), Some(parent.clone()));
    assert_eq!(git(&["rev-parse", "HEAD"], &root), parent);
    // The default workspace stays as it was.
    assert!(store(&fx.root).join("git").is_dir());
    assert!(!fx.root.join(".git").exists());
    let status = ws2.git_colocation_status().expect("status");
    assert!(status.colocated);
    assert_eq!(status.workspace_name, "ws2");
    assert_same_git_repo_as_default(&fx, &status);
}

/// A child's `git_repo_path` is the MAIN repository's Git dir, not its own `.git` gitlink.
fn assert_same_git_repo_as_default(fx: &Fx, child: &GitColocationStatus) {
    let main = status_of(&fx.root).git_repo_path;
    assert_eq!(
        fs::canonicalize(&child.git_repo_path).expect("child git dir"),
        fs::canonicalize(main).expect("main git dir")
    );
}

#[test]
fn disable_in_a_child_workspace_removes_its_git_worktree() {
    let (fx, mut ws2) = child(true);
    let root = fx.ws2();
    assert!(root.join(".git").is_file());
    let result = ws2.git_colocation_disable().expect("disable");
    assert!(result.converted);
    assert!(result.git_worktree_removed);
    assert!(!root.join(".git").exists());
    assert_eq!(gitignore(&root), None);
    assert_eq!(view_git_head(&root, "ws2"), None);
    assert!(fx.root.join(".git").is_dir());
    // The main workspace is colocated (no `store/git`), yet a child is never "external".
    let status = ws2.git_colocation_status().expect("status");
    assert!(!status.colocated);
    assert!(!status.external_git_repo);
    assert_eq!(status.hints, [ENABLE_HINT]);
    assert_eq!(status.workspace_name, "ws2");
    assert_same_git_repo_as_default(&fx, &status);
}

#[test]
fn disable_in_a_child_workspace_warns_when_the_worktree_unlink_fails() {
    let (fx, mut ws2) = child(true);
    let root = fx.ws2();
    let _locked = crate::workspace_ops::ReadOnlyDir::new(&root);
    let result = ws2.git_colocation_disable().expect("disable");
    assert!(result.converted);
    assert!(!result.git_worktree_removed);
    let unlink_warnings = ws2
        .take_warnings()
        .into_iter()
        .filter(|w| w.kind == WarningKind::GitWorktreeUnlinkFailed)
        .count();
    assert_eq!(unlink_warnings, 1);
}

/// A child workspace forgotten from the default one has no working-copy commit.
#[test]
fn enable_in_a_forgotten_child_workspace_refuses_no_working_copy() {
    let (fx, mut ws2) = child(false);
    let mut main = Repo::open(&fx.root).expect("open main");
    main.workspace_forget(&["ws2".to_owned()]).expect("forget ws2");
    let before = head_op(&fx.root);
    let err = ws2.git_colocation_enable().expect_err("refused");
    assert!(matches!(err, MutateError::NoWorkingCopy), "{err:?}");
    assert_eq!(head_op(&fx.root), before);
    assert!(!fx.ws2().join(".git").exists());
}

/// A failure after the move (a read-only Git config: `core.bare` cannot be written) still leaves
/// the handle on the moved repository, so the next call on it works.
#[test]
fn a_failure_after_the_move_still_reloads_the_handle() {
    let (fx, mut repo) = repo(false, true);
    let config = store(&fx.root).join("git").join("config");
    fs::set_permissions(&config, fs::Permissions::from_mode(0o444)).expect("chmod");
    let err = repo.git_colocation_enable().expect_err("core.bare");
    assert!(
        reason(&err).starts_with("Failed to write to Git config file at "),
        "{err:?}"
    );
    assert!(fx.root.join(".git").is_dir());
    let status = repo.git_colocation_status().expect("status on the same handle");
    assert_eq!(
        fs::canonicalize(&status.git_repo_path).expect("git dir"),
        fs::canonicalize(fx.root.join(".git")).expect(".git")
    );
}

#[test]
fn enable_in_a_child_workspace_with_an_existing_dot_git_refuses() {
    let (fx, mut ws2) = child(false);
    let root = fx.ws2();
    fs::create_dir(root.join(".git")).expect("mkdir .git");
    let err = ws2.git_colocation_enable().expect_err("refused");
    assert!(
        matches!(&err, MutateError::GitWorktree(reason)
            if reason.contains("A .git file or directory already exists in the Git worktree destination")),
        "{err:?}"
    );
    assert!(!store(&fx.root).join("git").join("worktrees").exists());
}

// ── sibling handles ──────────────────────────────────────────────────────────────
// Another handle's toggle changes `store/git_target` and moves the Git directory on disk, the
// same files `jj git colocation enable|disable` in a terminal changes.

fn same_dir(a: &Path, b: &Path) {
    assert_eq!(fs::canonicalize(a).expect("a"), fs::canonicalize(b).expect("b"));
}

/// Commits `name.txt` as `name` in the workspace of `repo`.
fn commit_file(repo: &mut Repo, name: &str) {
    fs::write(repo.workspace_root().join(format!("{name}.txt")), name).expect("write");
    repo.commit(&CommitOptions {
        message: vec![name.to_owned()],
        ..CommitOptions::default()
    })
    .expect("commit");
}

/// Whether the Git repository at `git_dir` holds the commit object `id`.
fn has_object(git_dir: &Path, id: &str) -> bool {
    Command::new("git")
        .args(["--git-dir", &git_dir.to_string_lossy(), "cat-file", "-e", id])
        .status()
        .expect("spawn git")
        .success()
}

#[test]
fn a_sibling_default_handle_follows_an_enable() {
    let (fx, mut a) = repo(false, true);
    let mut b = Repo::open(&fx.root).expect("open b");
    assert!(a.git_colocation_enable().expect("enable").converted);
    let status = b.git_colocation_status().expect("b's status");
    assert!(status.colocated);
    same_dir(&status.git_repo_path, &fx.root.join(".git"));
    assert_eq!(status, status_of(&fx.root));
    assert!(b.git_colocation_disable().expect("b disables").converted);
    assert!(!status_of(&fx.root).colocated);
    assert_eq!(git_target(&fx.root), "git");
}

#[test]
fn a_sibling_default_handle_follows_a_disable() {
    let (fx, mut a) = repo(true, true);
    let mut b = Repo::open(&fx.root).expect("open b");
    assert!(a.git_colocation_disable().expect("disable").converted);
    let status = b.git_colocation_status().expect("b's status");
    assert!(!status.colocated);
    assert_eq!(status.git_repo_path, store(&fx.root).join("git"));
    assert_eq!(status, status_of(&fx.root));
}

/// The toggling handle records the bytes its own toggle wrote, so a sibling toggling BACK
/// (restoring the bytes it was opened with) still reloads it.
#[test]
fn the_toggling_handle_follows_a_sibling_toggling_back() {
    let (fx, mut a) = repo(false, true);
    let mut b = Repo::open(&fx.root).expect("open b");
    assert!(a.git_colocation_enable().expect("a enables").converted);
    assert!(b.git_colocation_disable().expect("b disables").converted);
    let status = a.git_colocation_status().expect("a's status");
    assert!(!status.colocated);
    assert_eq!(status, status_of(&fx.root));
    commit_file(&mut a, "c2");
    assert!(has_object(
        &store(&fx.root).join("git"),
        &wc_parent(&fx.root, "default")
    ));
}

#[test]
fn a_child_handle_follows_the_default_workspace_enabling() {
    let (fx, mut ws2) = child(false);
    let mut main = Repo::open(&fx.root).expect("open main");
    assert!(main.git_colocation_enable().expect("enable").converted);
    let status = ws2.git_colocation_status().expect("ws2's status");
    same_dir(&status.git_repo_path, &fx.root.join(".git"));
    assert_eq!(status, status_of(&fx.ws2()));
    commit_file(&mut ws2, "c2");
    assert!(has_object(&fx.root.join(".git"), &wc_parent(&fx.ws2(), "ws2")));
}

#[test]
fn a_child_handle_follows_the_default_workspace_disabling() {
    let (fx, mut ws2) = child(false);
    let mut main = Repo::open(&fx.root).expect("open main");
    assert!(main.git_colocation_enable().expect("enable").converted);
    ws2.git_colocation_status().expect("ws2 on the colocated layout");
    assert!(main.git_colocation_disable().expect("disable").converted);
    let status = ws2.git_colocation_status().expect("ws2's status");
    assert!(!status.colocated);
    same_dir(&status.git_repo_path, &store(&fx.root).join("git"));
    assert_eq!(status, status_of(&fx.ws2()));
    commit_file(&mut ws2, "c2");
    assert!(has_object(&store(&fx.root).join("git"), &wc_parent(&fx.ws2(), "ws2")));
}

/// An open handle's next mutation writes through the Git directory now on disk: its commit is
/// exported to the moved repository, HEAD included.
#[test]
fn an_open_handle_writes_through_a_git_repo_moved_behind_it() {
    let (fx, mut b) = repo(false, true);
    Repo::open(&fx.root)
        .expect("open a")
        .git_colocation_enable()
        .expect("enable");
    commit_file(&mut b, "c2");
    assert_eq!(git(&["rev-parse", "HEAD"], &fx.root), wc_parent(&fx.root, "default"));
}

/// The op-pinned reads follow the Git directory too: a commit written to the moved repository
/// after the toggle is readable through handles opened before it.
#[test]
fn op_pinned_reads_on_a_sibling_follow_a_toggle() {
    let (fx, mut a) = repo(false, true);
    let mut contents = Repo::open(&fx.root).expect("open");
    let mut counts = Repo::open(&fx.root).expect("open");
    let mut finds = Repo::open(&fx.root).expect("open");
    assert!(a.git_colocation_enable().expect("enable").converted);
    commit_file(&mut a, "c2");
    let op = zanshin_jj::OperationId(head_op(&fx.root));
    let c2 = wc_parent(&fx.root, "default");

    let read = contents
        .commit_contents(&op, &[zanshin_jj::CommitId(c2.clone())])
        .expect("commit_contents");
    assert_eq!(read[0].description, "c2\n");
    // `description()` loads every commit object, the moved one included.
    let counted = counts
        .revset_counts(&op, &[r#"description(substring:"c2")"#.to_owned()], 10)
        .expect("revset_counts");
    assert_eq!(counted.counts[0].as_ref().expect("count").n, 1);
    let found = finds
        .find_changes(&op, r#"description(substring:"c2")"#, 1, "")
        .expect("find_changes");
    assert_eq!(found.entries[0].commit_id.0, c2);
}

/// A `git_target` that no longer loads fails the op-pinned reads first — before the operation id
/// is checked — with the reload's jj-lib reason, prefixed once.
#[test]
fn op_pinned_reads_report_a_git_target_that_no_longer_loads() {
    let (fx, mut repo) = repo(false, true);
    fs::write(store(&fx.root).join("git_target"), "nope").expect("break git_target");
    let malformed = zanshin_jj::OperationId("zz".to_owned());
    let backend = |reason: &str| assert!(!reason.is_empty() && !reason.starts_with("jj-lib error"), "{reason}");

    match repo.commit_contents(&malformed, &[]) {
        Err(zanshin_jj::CommitContentError::Backend(reason)) => backend(&reason),
        other => panic!("{other:?}"),
    }
    let err = repo.revset_counts(&malformed, &[], 1).expect_err("revset_counts");
    assert!(err.warnings.is_empty());
    match err.value {
        zanshin_jj::RevsetSearchError::Backend(reason) => backend(&reason),
        other => panic!("{other:?}"),
    }
    let err = repo.find_changes(&malformed, "all()", 1, "").expect_err("find_changes");
    assert!(err.warnings.is_empty());
    match err.value {
        zanshin_jj::RevsetSearchError::Backend(reason) => backend(&reason),
        other => panic!("{other:?}"),
    }
}

// ── backends ─────────────────────────────────────────────────────────────────────

#[test]
fn a_non_git_backend_refuses_all_three() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let mut repo = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_owned(),
        ..Default::default()
    })
    .result
    .expect("init");
    assert!(matches!(repo.git_colocation_status(), Err(MutateError::NotAGitRepo)));
    assert!(matches!(repo.git_colocation_enable(), Err(MutateError::NotAGitRepo)));
    assert!(matches!(repo.git_colocation_disable(), Err(MutateError::NotAGitRepo)));
}
