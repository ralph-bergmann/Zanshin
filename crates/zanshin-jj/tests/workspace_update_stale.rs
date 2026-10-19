// SPDX-License-Identifier: MIT

//! Story 9.23 — `Repo::workspace_update_stale`, one witness per `update-stale` row of the I/O
//! matrix, plus the auto arm through a non-`snapshot` verb.
//!
//! A stale working copy is made the way a user makes one: a second workspace (created with
//! `Repo::workspace_add`) rewrites the default workspace's `@` TREE — a description-only rewrite
//! keeps the working copy `Fresh` (`WorkingCopyFreshness::check_stale` compares trees). The
//! sibling and missing-operation states are fabricated through jj-lib, as the CLI's own tests
//! fabricate them.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, LazyLock};
use std::{env, fs};

use futures::TryStreamExt as _;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::OperationId as JjOperationId;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{Backend, ChangeId, Repo, SparseInheritance, StaleRecoveryOutcome, WarningKind};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: every test calls `pin_env()` FIRST; the `LazyLock` blocks them all until this
    // initialiser returns, so no test body has read the environment yet.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", test_helpers::leaked_xdg_config_home());
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// The main workspace at `<tmp>/main`, a second one at `<tmp>/ws2`.
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    ws2: PathBuf,
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

/// A repo whose default workspace's `@` records `f.txt` and a second workspace `ws2` next to it,
/// opened as the default workspace's handle. `colocated` builds it through `git init` +
/// `convert_colocated`; otherwise an internal-git repo.
fn two_workspaces(colocated: bool, config: &str) -> (Fx, Repo) {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let main = fs::canonicalize(tmp.path()).expect("canonical").join("main");
    fs::create_dir(&main).expect("main dir");
    let root = if colocated {
        git(&["init", "--initial-branch=main"], &main);
        git(&["config", "user.email", "test@zanshin.test"], &main);
        git(&["config", "user.name", "Fixture"], &main);
        fs::write(main.join("README.md"), "hello").expect("write README");
        git(&["add", "."], &main);
        git(&["commit", "-m", "initial"], &main);
        zanshin_jj::convert_colocated(&main)
            .result
            .expect("convert")
            .workspace_root()
            .to_owned()
    } else {
        Repo::init(&main, Some(Backend::Git))
            .result
            .expect("init")
            .workspace_root()
            .to_owned()
    };
    fs::write(root.join(".jj").join("repo").join("config.toml"), config).expect("repo config");
    let mut repo = Repo::open(&root).expect("open");
    fs::write(root.join("f.txt"), "f").expect("write");
    let _ = repo.status().expect("record f.txt");
    let ws2 = repo
        .workspace_add("../ws2", None, &[], &[], None, SparseInheritance::Copy)
        .expect("add ws2")
        .workspace_root;
    (Fx { _tmp: tmp, root, ws2 }, repo)
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

fn head_op(root: &Path) -> String {
    load(root).1.op_id().hex()
}

fn descriptions(root: &Path) -> Vec<String> {
    let (_workspace, head) = load(root);
    let ops: Vec<jj_lib::operation::Operation> =
        pollster::block_on(jj_lib::op_walk::walk_ancestors(std::slice::from_ref(head.operation())).try_collect())
            .expect("op walk");
    ops.iter().map(|op| op.metadata().description.clone()).collect()
}

fn default_at(root: &Path) -> jj_lib::commit::Commit {
    let (_workspace, repo) = load(root);
    let id = repo.view().get_wc_commit_id(WorkspaceName::DEFAULT).expect("@").clone();
    repo.store().get_commit(&id).expect("@ commit")
}

/// The operation the default working copy is recorded at, read from disk.
fn wc_op(root: &Path) -> String {
    load(root).0.working_copy().operation_id().hex()
}

/// From `ws2`, restores ws2's `@` (which lacks `f.txt`) INTO the default `@`: its tree changes,
/// so the default working copy is stale.
fn make_default_stale(fx: &Fx) {
    let target = ChangeId(default_at(&fx.root).change_id().reverse_hex());
    let mut ws2 = Repo::open(&fx.ws2).expect("open ws2");
    ws2.restore(None, Some(target), None, &[], false)
        .expect("restore into default@");
}

/// Moves the default `@` onto a new parent off root (holding `other.txt`) without a checkout
/// there — `@`'s first parent changes, so a colocated recovery must reset Git HEAD. Returns the
/// new parent's hex id.
fn reparent_default_at(fx: &Fx) -> String {
    let new_parent = test_helpers::add_commit_with_files(&fx.root, &[], &[("other.txt", "o")], "new parent");
    {
        let (_workspace, head) = load(&fx.root);
        let at = default_at(&fx.root);
        let parent = head
            .store()
            .get_commit(&jj_lib::backend::CommitId::try_from_hex(&new_parent).expect("hex"))
            .expect("parent");
        let mut tx = head.start_transaction();
        pollster::block_on(
            tx.repo_mut()
                .rewrite_commit(&at)
                .set_parents(vec![parent.id().clone()])
                .set_tree(parent.tree())
                .write(),
        )
        .expect("reparent @");
        pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
        pollster::block_on(tx.commit("test: reparent default@")).expect("commit");
    }

    new_parent
}

#[test]
fn a_stale_clean_working_copy_is_checked_out_without_an_operation() {
    let (fx, mut repo) = two_workspaces(false, "");
    make_default_stale(&fx);
    let head = head_op(&fx.root);

    let recovery = repo.workspace_update_stale().expect("update-stale");

    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Updated);
    assert_eq!(recovery.commit_id.map(|c| c.0), Some(default_at(&fx.root).id().hex()));
    assert_eq!(recovery.checkout.map(|c| c.removed), Some(1));
    assert_eq!(recovery.git_head_reset_op_id, None);
    assert_eq!(head_op(&fx.root), head, "no operation of its own");
    assert_eq!(recovery.op_id.0, head);
    assert_eq!(wc_op(&fx.root), head, "the working copy records the head");
    assert!(!fx.root.join("f.txt").exists(), "the fresh @'s files are on disk");
    let report = repo.take_precondition().expect("the trailing snapshot's report");
    assert!(!report.was_snapshot_taken);
    assert_eq!(report.stale_recovery, None);
    repo.status().expect("fresh again");
}

#[test]
fn a_stale_dirty_working_copy_is_snapshotted_into_a_divergent_commit_first() {
    let (fx, mut repo) = two_workspaces(false, "");
    make_default_stale(&fx);
    fs::write(fx.root.join("g.txt"), "dirty").expect("write");

    let recovery = repo.workspace_update_stale().expect("update-stale");

    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Updated);
    let (_workspace, head) = load(&fx.root);
    assert_eq!(
        head.operation().metadata().description,
        "reconcile divergent operations"
    );
    let merged: Vec<String> = pollster::block_on(head.operation().parents())
        .expect("parents")
        .iter()
        .map(|op| op.metadata().description.clone())
        .collect();
    assert!(merged.contains(&"snapshot working copy".to_owned()), "{merged:?}");
    // As in the CLI (`test_workspaces_conflicting_edits`): the dirty edit is kept in a
    // divergent commit, and the working copy holds the head's `@`.
    let kept = head.view().heads().iter().any(|id| {
        let commit = head.store().get_commit(id).expect("head commit");
        let path = jj_lib::repo_path::RepoPath::from_internal_string("g.txt").expect("path");
        pollster::block_on(commit.tree().path_value(path)).is_ok_and(|value| value.is_present())
    });
    assert!(kept, "no data loss: a visible head holds g.txt");
    assert!(!fx.root.join("g.txt").exists());
}

#[test]
fn a_fresh_working_copy_is_not_stale() {
    let (fx, mut repo) = two_workspaces(false, "");
    let head = head_op(&fx.root);

    let recovery = repo.workspace_update_stale().expect("update-stale");

    assert_eq!(recovery.outcome, StaleRecoveryOutcome::NotStale);
    assert_eq!(recovery.commit_id, None);
    assert_eq!(recovery.checkout, None);
    assert_eq!(head_op(&fx.root), head, "a clean, fresh working copy writes nothing");
}

#[test]
fn a_working_copy_at_a_sibling_operation_is_updated() {
    let (fx, mut repo) = two_workspaces(false, "");
    {
        let (mut workspace, repo) = load(&fx.root);
        let at = default_at(&fx.root);
        let mut tx = repo.start_transaction();
        pollster::block_on(tx.repo_mut().rewrite_commit(&at).set_description("unpublished").write()).expect("describe");
        pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
        let unpublished = pollster::block_on(tx.write("test: unpublished"))
            .expect("write")
            .leave_unpublished();
        let locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("lock");
        pollster::block_on(locked.finish(unpublished.op_id().clone())).expect("finish");
    }
    let _ = test_helpers::add_commit_off_root(&fx.root, "published sibling");

    let recovery = repo.workspace_update_stale().expect("update-stale");

    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Updated);
    assert_eq!(wc_op(&fx.root), head_op(&fx.root));
}

#[test]
fn a_working_copy_at_a_lost_operation_gets_a_recovery_commit() {
    let (fx, mut repo) = two_workspaces(false, "");
    {
        let (mut workspace, _repo) = load(&fx.root);
        let locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("lock");
        pollster::block_on(locked.finish(JjOperationId::new(vec![0xab; 64]))).expect("finish");
    }
    fs::write(fx.root.join("f.txt"), "edited").expect("write");

    let recovery = repo.workspace_update_stale().expect("update-stale");

    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Recovered);
    assert_eq!(
        &descriptions(&fx.root)[..2],
        ["snapshot working copy", "recovery commit"]
    );
    // The id is the recovery commit as jj-lib wrote it (the CLI's "Created and checked out
    // recovery commit …"); the trailing snapshot then rewrote it with the edited file.
    let at = default_at(&fx.root);
    let (_workspace, head) = load(&fx.root);
    let created = jj_lib::backend::CommitId::try_from_hex(recovery.commit_id.expect("id").0).expect("hex");
    let created = head.store().get_commit(&created).expect("recovery commit");
    assert_eq!(created.change_id(), at.change_id());
    assert!(at.description().starts_with(
        "RECOVERY COMMIT FROM `jj workspace update-stale`\n\nThis commit contains changes that were written"
    ));
    assert_eq!(fs::read_to_string(fx.root.join("f.txt")).expect("kept"), "edited");
}

#[test]
fn a_colocated_recovery_resets_git_head_before_the_checkout() {
    let (fx, mut repo) = two_workspaces(true, "");
    let new_parent = reparent_default_at(&fx);

    let recovery = repo.workspace_update_stale().expect("update-stale");

    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Updated);
    assert_eq!(descriptions(&fx.root)[0], "reset git head");
    assert_eq!(recovery.git_head_reset_op_id.map(|o| o.0), Some(head_op(&fx.root)));
    assert_eq!(git(&["rev-parse", "HEAD"], &fx.root), new_parent);
    assert_eq!(fs::read_to_string(fx.root.join("other.txt")).expect("checked out"), "o");
    assert!(
        git(&["status", "--porcelain", "--untracked-files=no"], &fx.root).is_empty(),
        "index reset"
    );
}

/// The auto arm through a verb other than `snapshot`: `status` recovers first and reports it.
#[test]
fn auto_update_stale_recovers_in_front_of_status() {
    let (fx, mut repo) = two_workspaces(false, "snapshot.auto-update-stale = true\n");
    make_default_stale(&fx);

    let status = repo.status().expect("status runs on the recovered state");

    let report = repo.take_precondition().expect("report");
    let recovery = report.stale_recovery.expect("recovered");
    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Updated);
    assert!(
        status.files.iter().all(|c| c.path != Path::new("f.txt")),
        "{:?}",
        status.files
    );
}

/// The auto arm in a COLOCATED workspace: the recovery runs under the lock the pre-verb snapshot
/// already holds (no second take, no hang) and resets Git HEAD to the new first parent.
#[test]
fn auto_update_stale_recovers_a_colocated_working_copy() {
    let (fx, mut repo) = two_workspaces(true, "snapshot.auto-update-stale = true\n");
    let new_parent = reparent_default_at(&fx);

    repo.status().expect("status completes on the recovered state");

    let recovery = repo
        .take_precondition()
        .expect("report")
        .stale_recovery
        .expect("recovered");
    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Updated);
    assert!(recovery.git_head_reset_op_id.is_some());
    assert_eq!(git(&["rev-parse", "HEAD"], &fx.root), new_parent);
}

/// The recovery's merged snapshot stats reach the result and the call's
/// `jj.snapshot_files_refused` warning (`print_snapshot_stats` in `cmd_workspace_update_stale`).
#[test]
fn update_stale_reports_the_files_its_snapshots_refused() {
    let (fx, mut repo) = two_workspaces(false, "snapshot.max-new-file-size = 10\n");
    fs::write(fx.root.join("big.bin"), "far more than ten bytes").expect("write");
    make_default_stale(&fx);

    let recovery = repo.workspace_update_stale().expect("update-stale");

    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Updated);
    let untracked: Vec<&str> = recovery
        .snapshot_stats
        .untracked
        .iter()
        .map(|u| u.path.as_str())
        .collect();
    assert_eq!(untracked, ["big.bin"]);
    assert!(
        repo.take_warnings()
            .iter()
            .any(|w| w.kind == WarningKind::SnapshotFilesRefused),
        "the merged stats warn"
    );
}
