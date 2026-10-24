// SPDX-License-Identifier: MIT

//! Story 9.23 — `Repo::workspace_add`, one witness per `workspace add` row of the I/O matrix.
//!
//! Every repo is built in-test: a NON-colocated internal-git repo through `Repo::init`, a
//! colocated one through `git init` + `convert_colocated`, a native one through
//! `Repo::init(_, None)`. The main workspace lives at `<tmp>/main`, so the CLI's usual
//! `../ws2` lands next to it. State is read back through jj-lib and `git` directly.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{Backend, ChangeId, MutateError, Repo, SparseInheritance, WarningKind};

/// A temp dir holding the main workspace at `<tmp>/main`.
struct Fx {
    tmp: TempDir,
    root: PathBuf,
}

impl Fx {
    /// `<tmp>/<rel>` — where `../<rel>` from the main workspace lands.
    fn sibling(&self, rel: &str) -> PathBuf {
        fs::canonicalize(self.tmp.path()).expect("canonical tmp").join(rel)
    }
}

fn main_dir() -> (TempDir, PathBuf) {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let main = tmp.path().join("main");
    fs::create_dir(&main).expect("main dir");
    (tmp, main)
}

/// A non-colocated repo (`backend` `Some(Git)`: internal git; `None`: native), legacy repo
/// config `config`.
fn init(backend: Option<Backend>, config: &str) -> Fx {
    let (tmp, main) = main_dir();
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&main),
        backend,
        colocate: backend.map(|_| false),
        ..Default::default()
    })
    .result
    .expect("init")
    .workspace_root()
    .to_owned();
    fs::write(root.join(".jj").join("repo").join("config.toml"), config).expect("repo config");
    Fx { tmp, root }
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

/// A colocated repo: `git init` with one commit on `main`, converted in place.
fn colocated(config: &str) -> Fx {
    let (tmp, main) = main_dir();
    git(&["init", "--initial-branch=main"], &main);
    git(&["config", "user.email", "test@zanshin.test"], &main);
    git(&["config", "user.name", "Fixture"], &main);
    fs::write(main.join("README.md"), "hello").expect("write README");
    git(&["add", "."], &main);
    git(&["commit", "-m", "initial"], &main);
    let root = zanshin_jj::convert_colocated(&main)
        .result
        .expect("convert")
        .workspace_root()
        .to_owned();
    fs::write(root.join(".jj").join("repo").join("config.toml"), config).expect("repo config");
    Fx { tmp, root }
}

fn load(root: &Path) -> (Workspace, Arc<ReadonlyRepo>) {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load workspace");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load head");
    (workspace, repo)
}

fn descriptions(root: &Path) -> Vec<String> {
    let (_workspace, head) = load(root);
    let ops: Vec<jj_lib::operation::Operation> =
        pollster::block_on(jj_lib::op_walk::walk_ancestors(std::slice::from_ref(head.operation())).try_collect())
            .expect("op walk");
    ops.iter().map(|op| op.metadata().description.clone()).collect()
}

/// `name`'s `@` in the head view.
fn wc_of(root: &Path, name: &str) -> jj_lib::commit::Commit {
    let (_workspace, repo) = load(root);
    let id = repo
        .view()
        .get_wc_commit_id(WorkspaceName::new(name))
        .expect("workspace has an @")
        .clone();
    repo.store().get_commit(&id).expect("@ commit")
}

fn change_id(commit: &jj_lib::commit::Commit) -> ChangeId {
    ChangeId(commit.change_id().reverse_hex())
}

fn sparse_of(root: &Path) -> Vec<RepoPathBuf> {
    let (workspace, _repo) = load(root);
    workspace.working_copy().sparse_patterns().expect("sparse").to_vec()
}

fn add(repo: &mut Repo, destination: &str) -> Result<zanshin_jj::WorkspaceAddResult, MutateError> {
    repo.workspace_add(destination, None, &[], &[], None, SparseInheritance::Copy)
}

#[test]
fn add_default_creates_a_sibling_workspace_on_ats_parents() {
    let fx = init(Some(Backend::Git), "");
    let mut repo = Repo::open(&fx.root).expect("open");
    fs::write(fx.root.join("p.txt"), "p").expect("write");
    let _ = repo.snapshot().expect("snapshot");
    let p = wc_of(&fx.root, "default");
    repo.new_change(&[change_id(&p)], &[], &[]).expect("new");

    let result = add(&mut repo, "../ws2").expect("add");

    let ws2 = fx.sibling("ws2");
    assert_eq!(
        &descriptions(&fx.root)[..2],
        [
            "create initial working-copy commit in workspace ws2",
            "add workspace 'ws2'"
        ]
    );
    let ws2_at = wc_of(&fx.root, "ws2");
    assert_eq!(ws2_at.parent_ids(), [p.id().clone()]);
    assert_eq!(ws2_at.description(), "");
    assert_eq!(fs::read_to_string(ws2.join("p.txt")).expect("checked out"), "p");
    assert!(ws2.join(".jj").join("repo").is_file(), "`.jj/repo` is a file");
    assert_eq!(sparse_of(&ws2), sparse_of(&fx.root), "sparse patterns copied");
    assert_eq!(result.workspace_name, "ws2");
    assert_eq!(result.workspace_root, ws2);
    assert!(!result.git_worktree_created);
    assert_eq!(result.checkout.added, 1);
    assert_eq!(result.mutation.working_copy_change_id, Some(change_id(&ws2_at)));
    assert_eq!(result.mutation.new_change_ids, [change_id(&ws2_at)]);
    assert_eq!(result.mutation.new_op_id.0, load(&fx.root).1.op_id().hex());
    assert!(repo
        .take_warnings()
        .iter()
        .all(|w| w.kind != WarningKind::WorkspaceInCurrentDirectory));
    let names: Vec<String> = repo
        .list_workspaces()
        .expect("list")
        .into_iter()
        .map(|w| w.name)
        .collect();
    assert!(names.contains(&"ws2".to_owned()), "{names:?}");
    // The workspace store records ws2's path relative to the repo: it resolves back to the
    // destination (the canonicalisation trap `test_helpers::add_workspace` documents).
    let recorded = repo.resolve_workspace_root(Some("ws2")).expect("ws2 root");
    assert_eq!(fs::canonicalize(recorded).expect("recorded root exists"), ws2);
}

/// Without an `@` in the current workspace (forgotten through jj-lib, as `status.rs`'s
/// `remove_working_copy`), the new `@` goes onto the root — the CLI's `else { vec![root_commit] }`
/// (`cli/src/commands/workspace/add.rs` @ v0.46.0).
#[test]
fn a_workspace_without_at_adds_on_the_root() {
    let fx = init(Some(Backend::Git), "");
    {
        let mut repo = Repo::open(&fx.root).expect("open");
        fs::write(fx.root.join("p.txt"), "p").expect("write");
        let _ = repo.snapshot().expect("snapshot");
        let p = wc_of(&fx.root, "default");
        repo.new_change(&[change_id(&p)], &[], &[]).expect("new");
    }
    let (workspace, head) = load(&fx.root);
    let mut tx = head.start_transaction();
    pollster::block_on(tx.repo_mut().remove_workspace(workspace.workspace_name())).expect("remove @");
    pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
    pollster::block_on(tx.commit("test: remove working-copy commit")).expect("commit");

    let mut repo = Repo::open(&fx.root).expect("reopen");
    add(&mut repo, "../ws2").expect("add");

    let (_workspace, head) = load(&fx.root);
    assert_eq!(
        wc_of(&fx.root, "ws2").parent_ids(),
        [head.store().root_commit_id().clone()]
    );
    assert!(!fx.sibling("ws2").join("p.txt").exists(), "p.txt absent in ws2");
    assert_eq!(
        &descriptions(&fx.root)[..3],
        [
            "create initial working-copy commit in workspace ws2",
            "add workspace 'ws2'",
            "test: remove working-copy commit"
        ]
    );
}

/// `revisions` are evaluated in the CURRENT workspace's context: `@` is this workspace's `@`.
#[test]
fn revisions_resolve_in_the_current_workspaces_context() {
    let fx = init(Some(Backend::Git), "");
    let mut repo = Repo::open(&fx.root).expect("open");
    fs::write(fx.root.join("a.txt"), "a").expect("write");

    repo.workspace_add("../ws2", None, &["@".to_owned()], &[], None, SparseInheritance::Copy)
        .expect("add");

    let default_at = wc_of(&fx.root, "default");
    assert_eq!(wc_of(&fx.root, "ws2").parent_ids(), [default_at.id().clone()]);
    assert!(fx.sibling("ws2").join("a.txt").is_file());
}

#[test]
fn add_with_name_revisions_and_message() {
    let fx = init(Some(Backend::Git), "");
    let mut repo = Repo::open(&fx.root).expect("open");
    fs::write(fx.root.join("a.txt"), "a").expect("write");
    let _ = repo.snapshot().expect("snapshot");
    let a = wc_of(&fx.root, "default");
    repo.bookmark_create(&["a".to_owned()], Some(&change_id(&a)))
        .expect("bookmark a");
    let root_change = ChangeId("z".repeat(32));
    repo.new_change(&[root_change], &[], &[]).expect("new off root");
    fs::write(fx.root.join("b.txt"), "b").expect("write");
    let _ = repo.snapshot().expect("snapshot");
    let b = wc_of(&fx.root, "default");
    repo.bookmark_create(&["b".to_owned()], Some(&change_id(&b)))
        .expect("bookmark b");
    let (a, b) = (wc_of_bookmark(&fx.root, "a"), wc_of_bookmark(&fx.root, "b"));

    let result = repo
        .workspace_add(
            "../x-dir",
            Some("x"),
            &["a".to_owned(), "b|a".to_owned()],
            &["T".to_owned(), "U".to_owned()],
            None,
            SparseInheritance::Copy,
        )
        .expect("add");

    assert_eq!(result.workspace_name, "x");
    let x_at = wc_of(&fx.root, "x");
    assert_eq!(x_at.parent_ids(), [a, b], "argument order, deduplicated");
    assert_eq!(x_at.description(), "T\n\nU\n");
    assert_eq!(
        descriptions(&fx.root)[0],
        "create initial working-copy commit in workspace x"
    );
    let x_dir = fx.sibling("x-dir");
    assert!(x_dir.join("a.txt").is_file() && x_dir.join("b.txt").is_file());
}

fn wc_of_bookmark(root: &Path, name: &str) -> jj_lib::backend::CommitId {
    let (_workspace, repo) = load(root);
    repo.view()
        .get_local_bookmark(jj_lib::ref_name::RefName::new(name))
        .as_normal()
        .expect("bookmark")
        .clone()
}

#[test]
fn an_empty_revision_set_refuses_after_the_workspace_exists() {
    let fx = init(Some(Backend::Git), "");
    let mut repo = Repo::open(&fx.root).expect("open");

    let err = repo
        .workspace_add(
            "../ws2",
            None,
            &["none()".to_owned()],
            &[],
            None,
            SparseInheritance::Copy,
        )
        .expect_err("empty");

    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "Empty revision set"),
        "{err:?}"
    );
    assert!(
        fx.sibling("ws2").join(".jj").is_dir(),
        "the workspace exists (CLI order)"
    );
    assert_eq!(descriptions(&fx.root)[0], "add workspace 'ws2'", "no second operation");
}

#[test]
fn a_bad_revset_refuses_with_the_revset_code() {
    let fx = init(Some(Backend::Git), "");
    let mut repo = Repo::open(&fx.root).expect("open");

    let err = repo
        .workspace_add("../ws2", None, &["(".to_owned()], &[], None, SparseInheritance::Copy)
        .expect_err("parse");
    assert!(matches!(err, MutateError::RevsetParseError { .. }), "{err:?}");
    let err = repo
        .workspace_add(
            "../ws3",
            None,
            &["nosuch".to_owned()],
            &[],
            None,
            SparseInheritance::Copy,
        )
        .expect_err("resolve");
    assert!(matches!(err, MutateError::RevsetResolutionError { .. }), "{err:?}");
    // Resolved after the workspace exists (`add.rs:226-252` @ v0.46.0): it stays, as in the CLI.
    assert!(fx.sibling("ws3").join(".jj").is_dir(), "the workspace exists");
    assert_eq!(descriptions(&fx.root)[0], "add workspace 'ws3'");
}

#[test]
fn an_empty_name_or_a_destination_without_final_component_creates_nothing() {
    let fx = init(Some(Backend::Git), "");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = descriptions(&fx.root).len();

    let err = repo
        .workspace_add("../ws2", Some(""), &[], &[], None, SparseInheritance::Copy)
        .expect_err("empty name");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    assert!(!fx.sibling("ws2").exists());
    let err = add(&mut repo, "x/..").expect_err("no final component");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    assert!(!fx.root.join("x").exists());
    assert_eq!(descriptions(&fx.root).len(), before);
}

#[test]
fn an_existing_name_creates_nothing() {
    let fx = init(Some(Backend::Git), "");
    let mut repo = Repo::open(&fx.root).expect("open");

    let err = repo
        .workspace_add("../ws2", Some("default"), &[], &[], None, SparseInheritance::Copy)
        .expect_err("exists");

    assert!(
        matches!(&err, MutateError::WorkspaceExists { name } if name == "default"),
        "{err:?}"
    );
    assert!(!fx.sibling("ws2").exists());
}

#[test]
fn a_busy_destination_is_refused() {
    let fx = init(Some(Backend::Git), "");
    let mut repo = Repo::open(&fx.root).expect("open");
    let busy = fx.sibling("busy");
    fs::create_dir(&busy).expect("dir");
    fs::write(busy.join("f"), "x").expect("file");
    fs::write(fx.sibling("file"), "x").expect("file");

    assert!(matches!(
        add(&mut repo, "../busy"),
        Err(MutateError::DestinationNotEmpty)
    ));
    assert!(matches!(
        add(&mut repo, "../file"),
        Err(MutateError::DestinationNotEmpty)
    ));
    assert!(!busy.join(".jj").exists());
    let empty = fx.sibling("empty");
    fs::create_dir(&empty).expect("dir");
    add(&mut repo, "../empty").expect("an existing EMPTY directory is fine");
}

#[test]
fn a_destination_without_separator_lands_inside_and_warns() {
    let fx = init(Some(Backend::Git), "");
    let mut repo = Repo::open(&fx.root).expect("open");

    let result = add(&mut repo, "ws2").expect("add");

    assert_eq!(result.workspace_root, fx.root.join("ws2"));
    let warnings = repo.take_warnings();
    let warning = warnings
        .iter()
        .find(|w| w.kind == WarningKind::WorkspaceInCurrentDirectory)
        .expect("warned");
    assert!(
        warning.message.contains("`jj workspace forget ws2`"),
        "{}",
        warning.message
    );
}

#[test]
fn a_colocated_repo_gets_a_git_worktree_by_default() {
    let fx = colocated("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let parent = wc_of(&fx.root, "default").parent_ids()[0].hex();

    let result = add(&mut repo, "../ws2").expect("add");

    let ws2 = fx.sibling("ws2");
    assert!(result.git_worktree_created);
    assert!(ws2.join(".git").is_file(), "a worktree gitlink");
    assert_eq!(
        fs::read_to_string(ws2.join(".jj").join(".gitignore")).expect("gitignore"),
        "/*\n"
    );
    assert_eq!(git(&["rev-parse", "HEAD"], &ws2), parent, "HEAD = first parent of ws2@");
    assert_eq!(fs::read_to_string(ws2.join("README.md")).expect("checked out"), "hello");
}

#[test]
fn colocation_follows_the_flags_and_git_colocate() {
    let fx = colocated("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let result = repo
        .workspace_add("../no", None, &[], &[], Some(false), SparseInheritance::Copy)
        .expect("add");
    assert!(!result.git_worktree_created);
    assert!(!fx.sibling("no").join(".git").exists());
    assert!(!fx.sibling("no").join(".jj").join(".gitignore").exists());

    let fx = colocated("git.colocate = false\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    assert!(!add(&mut repo, "../ws2").expect("add").git_worktree_created);
    assert!(!fx.sibling("ws2").join(".git").exists());

    let fx = colocated("git.colocate = \"yes\"\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let err = add(&mut repo, "../ws2").expect_err("wrong type");
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.contains("git.colocate")),
        "{err:?}"
    );
    assert!(
        fx.sibling("ws2").is_dir(),
        "the directory is created first, as in the CLI"
    );

    let fx = init(Some(Backend::Git), "git.colocate = \"never read\"\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    // Not colocated: the CLI's short-circuit never reads `git.colocate`.
    let plain = add(&mut repo, "../plain").expect("git.colocate is not read");
    assert!(!plain.git_worktree_created);
    let result = repo
        .workspace_add("../ws2", None, &[], &[], Some(true), SparseInheritance::Copy)
        .expect("add");
    assert!(result.git_worktree_created, "--colocate on a non-colocated git repo");
    assert!(fx.sibling("ws2").join(".git").is_file());
}

#[test]
fn colocating_a_native_backend_fails_after_the_directory_exists() {
    let fx = init(None, "");
    let mut repo = Repo::open(&fx.root).expect("open");

    let err = repo
        .workspace_add("../ws2", None, &[], &[], Some(true), SparseInheritance::Copy)
        .expect_err("no git backend");

    assert!(matches!(err, MutateError::GitWorktree(_)), "{err:?}");
    assert!(fx.sibling("ws2").is_dir(), "created first, as in the CLI");
}

#[test]
fn sparse_patterns_are_copied_full_or_empty() {
    let fx = init(Some(Backend::Git), "");
    {
        let (mut workspace, _repo) = load(&fx.root);
        let mut locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("lock");
        let op = locked.locked_wc().old_operation_id().clone();
        pollster::block_on(
            locked
                .locked_wc()
                .set_sparse_patterns(vec![RepoPathBuf::from_internal_string("a").expect("path")]),
        )
        .expect("sparse");
        pollster::block_on(locked.finish(op)).expect("finish");
    }
    let mut repo = Repo::open(&fx.root).expect("open");

    add(&mut repo, "../copy").expect("copy");
    repo.workspace_add("../full", None, &[], &[], None, SparseInheritance::Full)
        .expect("full");
    repo.workspace_add("../empty", None, &[], &[], None, SparseInheritance::Empty)
        .expect("empty");

    assert_eq!(
        sparse_of(&fx.sibling("copy")),
        [RepoPathBuf::from_internal_string("a").expect("path")]
    );
    assert_eq!(sparse_of(&fx.sibling("full")), [RepoPathBuf::root()]);
    assert_eq!(sparse_of(&fx.sibling("empty")), Vec::<RepoPathBuf>::new());
}

/// A colocated new workspace whose `@` sits on root gets the unborn `refs/jj/root` HEAD jj
/// v0.46.0 leaves there (CLI `test_workspaces_add_colocated_unborn_head`): for a repo with no
/// commit at all, and for `-r root()` in a repo that has one.
#[test]
fn a_colocated_workspace_on_root_gets_an_unborn_head() {
    let (tmp, main) = main_dir();
    git(&["init", "--initial-branch=main"], &main);
    let root = zanshin_jj::convert_colocated(&main)
        .result
        .expect("convert")
        .workspace_root()
        .to_owned();
    let fx = Fx { tmp, root };
    let mut repo = Repo::open(&fx.root).expect("open");

    let result = add(&mut repo, "../secondary").expect("add on an empty repo");

    let secondary = fx.sibling("secondary");
    assert!(result.git_worktree_created);
    assert_eq!(git(&["symbolic-ref", "HEAD"], &secondary), "refs/jj/root");
    assert!(
        !Command::new("git")
            .args(["rev-parse", "-q", "--verify", "HEAD"])
            .current_dir(&secondary)
            .status()
            .expect("spawn git")
            .success(),
        "HEAD is unborn"
    );

    let fx = colocated("");
    let mut repo = Repo::open(&fx.root).expect("open");
    repo.workspace_add(
        "../tertiary",
        None,
        &["root()".to_owned()],
        &[],
        None,
        SparseInheritance::Copy,
    )
    .expect("add on root");
    let tertiary = fx.sibling("tertiary");
    assert_eq!(git(&["symbolic-ref", "HEAD"], &tertiary), "refs/jj/root");
    assert!(!tertiary.join("README.md").exists());
}

/// Story 9.56: the new workspace's finish resolves its immutable set, as the CLI's `tx.finish`
/// does (`rebase_mutable_descendants`, `cli/src/cli_util.rs:2986-3002` @ v0.46.0) — this pins that
/// an unresolvable `immutable_heads()` alias refuses `Config` AFTER jj-lib's "add workspace"
/// operation: the workspace exists on jj-lib's initial `@` and no second operation is written.
/// The CLI's resulting state was read from the v0.46.0 source and checked by hand against the
/// pinned `jj` when this was written; no oracle scenario covers it.
#[test]
fn an_unresolvable_alias_refuses_after_the_workspace_exists() {
    let fx = init(
        Some(Backend::Git),
        "[revset-aliases]\n\"immutable_heads()\" = \"nonexistent_symbol_xyz\"\n",
    );
    let mut repo = Repo::open(&fx.root).expect("open");

    let err = add(&mut repo, "../ws2").expect_err("unresolvable");

    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");
    assert!(
        fx.sibling("ws2").join(".jj").is_dir(),
        "the workspace exists (CLI order)"
    );
    assert_eq!(descriptions(&fx.root)[0], "add workspace 'ws2'", "no second operation");
    assert!(wc_of(&fx.root, "ws2").description().is_empty(), "jj-lib's initial @");
}
