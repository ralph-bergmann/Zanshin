// SPDX-License-Identifier: MIT

//! Story 9.13 — `Repo::workspace_forget`, `workspace_rename` and `workspace_remove`, one witness
//! per row of the I/O matrix, read back through jj-lib: the view, the workspace store and the
//! disk. The CLI comparison lives in the parity oracle (`crates/zanshin-parity`).

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::Repo as _;
use jj_lib::workspace_store::WorkspaceStore;
use zanshin_jj::{
    ChangeId, CommitViewError, FileError, MutateError, PreconditionError, Repo, RevisionRef, SparseInheritance,
    WarningKind,
};

use crate::workspace_update_stale::{descriptions, head_op, load, two_workspaces};

const NO_WC: &str = "Workspace `default` doesn't have a working-copy commit";
const FORGET_HINT: &str = "Use `jj workspace forget` to stop tracking a workspace without deleting files.";

fn names(names: &[&str]) -> Vec<String> {
    names.iter().map(|&n| n.to_owned()).collect()
}

fn store(root: &Path) -> Box<dyn WorkspaceStore> {
    jj_lib::default_backend_factories::default_backend_factories()
        .load_workspace_store(
            &test_helpers::test_settings(),
            &root.join(".jj").join("repo").join("workspace_store"),
        )
        .expect("store")
}

fn recorded(root: &Path, name: &str) -> Option<PathBuf> {
    store(root).get_workspace_path(WorkspaceName::new(name)).expect("read")
}

fn in_view(root: &Path, name: &str) -> bool {
    load(root).1.view().get_wc_commit_id(WorkspaceName::new(name)).is_some()
}

/// A third workspace next to the fixture's two.
fn add_ws3(repo: &mut Repo) -> PathBuf {
    repo.workspace_add("../ws3", None, &[], &[], None, SparseInheritance::Copy)
        .expect("add ws3")
        .workspace_root
}

fn warning_kinds(repo: &mut Repo) -> Vec<WarningKind> {
    repo.take_warnings().into_iter().map(|w| w.kind).collect()
}

/// An `InvalidInput` refusal's reason and hints.
fn invalid(err: &MutateError) -> (String, Vec<String>) {
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    let reason = err
        .to_string()
        .strip_prefix("invalid input: ")
        .expect("prefix")
        .to_owned();
    (reason, err.hints())
}

// ── forget ───────────────────────────────────────────────────────────────────────

/// Another workspace: it leaves the view, its recorded path stays, its files stay.
#[test]
fn forget_another_workspace_keeps_its_path_and_files() {
    let (fx, mut repo) = two_workspaces(false, "");
    let result = repo.workspace_forget(&names(&["ws2"])).expect("forget");
    assert!(!in_view(&fx.root, "ws2"));
    assert_eq!(recorded(&fx.root, "ws2"), Some(fx.ws2.clone()));
    assert!(fx.ws2.join(".jj").is_dir());
    assert_eq!(descriptions(&fx.root)[0], "forget workspace ws2");
    assert_eq!(result.mutation.new_op_id.0, head_op(&fx.root));
    assert!(result.mutation.working_copy_change_id.is_some());
    assert!(result.git_worktrees_removed.is_empty());
    assert!(result.directories_removed.is_empty());
}

/// No name forgets THIS workspace: its working copy is untouched, the finish warns, and every
/// later call defaulting to `@` refuses with the CLI's text, never `jj.jj_lib_error` (I1).
#[test]
fn forget_the_current_workspace_then_at_defaults_refuse_with_the_clis_text() {
    let (fx, mut repo) = two_workspaces(false, "");
    let result = repo.workspace_forget(&[]).expect("forget");
    assert!(result.mutation.working_copy_change_id.is_none());
    assert!(!in_view(&fx.root, "default"));
    assert_eq!(recorded(&fx.root, "default"), Some(fx.root.clone()));
    assert_eq!(warning_kinds(&mut repo), [WarningKind::WorkspaceNoLongerExists]);
    assert_eq!(descriptions(&fx.root)[0], "forget workspace default");

    let err = repo.file_list(None, &[]).expect_err("no @");
    assert!(
        matches!(&err, FileError::InvalidInput { reason } if reason == NO_WC),
        "{err:?}"
    );
    let err = repo.restore(None, None, None, &[], false).expect_err("no @");
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, .. } if reason == NO_WC),
        "{err:?}"
    );
    let err = repo.file_chmod(true, None, &names(&["x"])).expect_err("no @");
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, .. } if reason == NO_WC),
        "{err:?}"
    );
    let root = RevisionRef::ChangeId(ChangeId("z".repeat(32)));
    let err = repo.interdiff(Some(root), None, &[]).expect_err("no @");
    assert!(
        matches!(&err, CommitViewError::RevsetResolutionError { reason, .. } if reason == NO_WC),
        "{err:?}"
    );
}

/// Two names: one operation naming both.
#[test]
fn forget_two_workspaces_in_one_operation() {
    let (fx, mut repo) = two_workspaces(false, "");
    add_ws3(&mut repo);
    repo.workspace_forget(&names(&["ws2", "ws3"])).expect("forget");
    assert!(!in_view(&fx.root, "ws2"));
    assert!(!in_view(&fx.root, "ws3"));
    assert_eq!(descriptions(&fx.root)[0], "forget workspaces ws2, ws3");
}

/// An unknown name warns and, with nothing left, nothing is written.
#[test]
fn forget_an_unknown_name_warns_and_writes_nothing() {
    let (fx, mut repo) = two_workspaces(false, "");
    let before = head_op(&fx.root);
    let result = repo.workspace_forget(&names(&["nope"])).expect("forget");
    assert_eq!(result.mutation.new_op_id.0, before);
    assert_eq!(head_op(&fx.root), before);
    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0].kind, WarningKind::WorkspaceNamesUnmatched);
    assert_eq!(warnings[0].message, "No such workspace: nope");
}

/// A colocated child's Git worktree is unlinked: its `.git` file goes, its other files stay.
#[test]
fn forget_a_colocated_child_unlinks_its_git_worktree() {
    let (fx, mut repo) = two_workspaces(true, "");
    assert!(fx.ws2.join(".git").is_file(), "ws2 is a Git worktree");
    let result = repo.workspace_forget(&names(&["ws2"])).expect("forget");
    assert!(!fx.ws2.join(".git").exists());
    assert!(fx.ws2.join("README.md").is_file());
    assert_eq!(result.git_worktrees_removed, std::slice::from_ref(&fx.ws2));
}

/// A worktree link that cannot be removed warns; the forget stands.
#[test]
fn a_failed_worktree_unlink_warns() {
    let (fx, mut repo) = two_workspaces(false, "");
    fs::write(fx.ws2.join(".git"), "gitdir: /nowhere\n").expect("gitlink");
    let _locked = ReadOnlyDir::new(&fx.ws2);
    let result = repo.workspace_forget(&names(&["ws2"])).expect("forget");
    assert!(result.git_worktrees_removed.is_empty());
    let warnings = repo.take_warnings();
    let warning = warnings
        .iter()
        .find(|w| w.kind == WarningKind::GitWorktreeUnlinkFailed)
        .expect("unlink warning");
    assert!(
        warning.message.starts_with(&format!(
            "Failed to remove Git worktree for \"{}\".\nCaused by",
            fx.ws2.display()
        )),
        "{}",
        warning.message
    );
    assert!(!in_view(&fx.root, "ws2"));
}

/// A directory made read-only for the test's duration; writable again on drop, so the tempdir
/// can be removed.
pub(crate) struct ReadOnlyDir(PathBuf);

impl ReadOnlyDir {
    pub(crate) fn new(dir: &Path) -> Self {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o555)).expect("chmod");
        Self(dir.to_owned())
    }
}

impl Drop for ReadOnlyDir {
    fn drop(&mut self) {
        let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o755));
    }
}

// ── rename ───────────────────────────────────────────────────────────────────────

/// The view, the store and the working copy are renamed in one plain commit; the handle runs as
/// the renamed workspace afterwards.
#[test]
fn rename_renames_view_store_and_working_copy() {
    let (fx, mut repo) = two_workspaces(false, "");
    let at = load(&fx.root)
        .1
        .view()
        .get_wc_commit_id(WorkspaceName::DEFAULT)
        .cloned();
    let result = repo.workspace_rename("new").expect("rename");
    assert!(!in_view(&fx.root, "default"));
    assert_eq!(
        load(&fx.root)
            .1
            .view()
            .get_wc_commit_id(WorkspaceName::new("new"))
            .cloned(),
        at
    );
    assert_eq!(recorded(&fx.root, "new"), Some(fx.root.clone()));
    assert_eq!(recorded(&fx.root, "default"), None);
    assert_eq!(load(&fx.root).0.workspace_name().as_str(), "new");
    assert_eq!(descriptions(&fx.root)[0], "Renamed workspace 'default' to 'new'");
    assert_eq!(result.new_op_id.0, head_op(&fx.root));
    assert!(result.working_copy_change_id.is_some());
    assert!(result.finish.is_none());
    assert!(repo.take_warnings().is_empty(), "no finish, no identity warning");

    // The next call runs as `new`: its `@` resolves.
    fs::write(fx.root.join("g.txt"), "g").expect("write");
    repo.file_chmod(true, None, &names(&["g.txt"])).expect("chmod as new");
}

/// The current name writes nothing; a taken name and an empty one refuse.
#[test]
fn rename_to_the_same_a_taken_or_an_empty_name() {
    let (fx, mut repo) = two_workspaces(false, "");
    let before = head_op(&fx.root);
    assert_eq!(repo.workspace_rename("default").expect("same").new_op_id.0, before);
    let err = repo.workspace_rename("ws2").expect_err("taken");
    assert!(
        matches!(&err, MutateError::WorkspaceExists { name } if name == "ws2"),
        "{err:?}"
    );
    assert_eq!(head_op(&fx.root), before);
    assert_eq!(load(&fx.root).0.workspace_name().as_str(), "default");
    let (reason, _) = invalid(&repo.workspace_rename("").expect_err("empty"));
    assert_eq!(reason, "New workspace name cannot be empty");
    assert!(repo.take_precondition().is_none(), "refused before the snapshot");
}

/// A workspace without `@` cannot be renamed.
#[test]
fn rename_without_a_working_copy_commit_refuses() {
    let (_fx, mut repo) = two_workspaces(false, "");
    repo.workspace_forget(&[]).expect("forget");
    let err = repo.workspace_rename("new").expect_err("no @");
    assert!(matches!(err, MutateError::NoWorkingCopy), "{err:?}");
}

// ── remove ───────────────────────────────────────────────────────────────────────

/// A dirty `ws2` is snapshotted (its own operation), then removed: the view and the store lose
/// it, its directory goes.
#[test]
fn remove_snapshots_then_removes_the_workspace_and_its_directory() {
    let (fx, mut repo) = two_workspaces(false, "");
    fs::write(fx.ws2.join("dirty.txt"), "d").expect("dirty");
    let result = repo.workspace_remove(&names(&["ws2"])).expect("remove");
    let ops = descriptions(&fx.root);
    assert_eq!(ops[0], "remove workspace ws2");
    assert_eq!(ops[1], "snapshot working copy");
    assert!(!in_view(&fx.root, "ws2"));
    assert_eq!(recorded(&fx.root, "ws2"), None);
    assert!(!fx.ws2.exists());
    assert_eq!(result.directories_removed, std::slice::from_ref(&fx.ws2));
    assert_eq!(result.mutation.new_op_id.0, head_op(&fx.root));
}

/// A target whose snapshot refuses (a stale `ws2`, no `snapshot.auto-update-stale`) stops the
/// call: `ws2` stays in the view, the store and on disk, and no removal is written.
#[test]
fn remove_stops_at_a_stale_target() {
    let (fx, mut repo) = two_workspaces(false, "");
    let ws2_at = {
        let (_, head) = load(&fx.root);
        let id = head
            .view()
            .get_wc_commit_id(WorkspaceName::new("ws2"))
            .expect("ws2@")
            .clone();
        ChangeId(head.store().get_commit(&id).expect("commit").change_id().reverse_hex())
    };
    // `@` (with `f.txt`) restored INTO ws2's `@`: its tree changes without a checkout there.
    repo.restore(None, Some(ws2_at), None, &[], false)
        .expect("restore into ws2@");
    let err = repo.workspace_remove(&names(&["ws2"])).expect_err("stale ws2");
    assert!(
        matches!(
            err,
            MutateError::Precondition(PreconditionError::StaleWorkingCopy { .. })
        ),
        "{err:?}"
    );
    assert!(in_view(&fx.root, "ws2"));
    assert_eq!(recorded(&fx.root, "ws2"), Some(fx.ws2.clone()));
    assert!(fx.ws2.join(".jj").is_dir());
    assert!(!descriptions(&fx.root).iter().any(|d| d.starts_with("remove workspace")));
}

/// From a `ws2` handle, removing `ws2` itself is allowed: its directory goes, the handle is left
/// without `@` and the finish warns.
#[test]
fn remove_the_handles_own_secondary_workspace() {
    let (fx, _default) = two_workspaces(false, "");
    let mut ws2 = Repo::open(&fx.ws2).expect("open ws2");
    let result = ws2.workspace_remove(&names(&["ws2"])).expect("remove");
    assert!(!fx.ws2.exists());
    assert!(result.mutation.working_copy_change_id.is_none());
    assert_eq!(result.directories_removed, std::slice::from_ref(&fx.ws2));
    assert!(warning_kinds(&mut ws2).contains(&WarningKind::WorkspaceNoLongerExists));
    assert!(!in_view(&fx.root, "ws2"));
}

/// Two names: one operation naming both, both directories gone.
#[test]
fn remove_two_workspaces() {
    let (fx, mut repo) = two_workspaces(false, "");
    let ws3 = add_ws3(&mut repo);
    let result = repo.workspace_remove(&names(&["ws2", "ws3"])).expect("remove");
    assert_eq!(descriptions(&fx.root)[0], "remove workspaces ws2, ws3");
    assert_eq!(result.directories_removed, [fx.ws2.clone(), ws3.clone()]);
    assert!(!ws3.exists());
}

/// A colocated child: its worktree is unlinked before its directory goes.
#[test]
fn remove_a_colocated_child_unlinks_and_deletes() {
    let (fx, mut repo) = two_workspaces(true, "");
    let result = repo.workspace_remove(&names(&["ws2"])).expect("remove");
    assert_eq!(result.git_worktrees_removed, std::slice::from_ref(&fx.ws2));
    assert_eq!(result.directories_removed, std::slice::from_ref(&fx.ws2));
}

/// A directory that cannot be deleted warns; the workspace is removed all the same.
#[test]
fn a_failed_directory_removal_warns() {
    let (fx, mut repo) = two_workspaces(false, "");
    let _locked = ReadOnlyDir::new(&fx.ws2);
    let result = repo.workspace_remove(&names(&["ws2"])).expect("remove");
    assert!(result.directories_removed.is_empty());
    assert!(!in_view(&fx.root, "ws2"));
    let warnings = repo.take_warnings();
    let warning = warnings
        .iter()
        .find(|w| w.kind == WarningKind::WorkspaceDirectoryRemoveFailed)
        .expect("remove warning");
    assert!(
        warning.message.starts_with(&format!(
            "Failed to remove workspace directory \"{}\".\nCaused by",
            fx.ws2.display()
        )),
        "{}",
        warning.message
    );
}

/// No name is clap's refusal (before the snapshot); an unknown one warns and writes nothing.
#[test]
fn remove_no_or_an_unknown_name() {
    let (fx, mut repo) = two_workspaces(false, "");
    let before = head_op(&fx.root);
    invalid(&repo.workspace_remove(&[]).expect_err("no names"));
    assert!(repo.take_precondition().is_none());
    let result = repo.workspace_remove(&names(&["nope"])).expect("unknown");
    assert_eq!(result.mutation.new_op_id.0, before);
    assert_eq!(warning_kinds(&mut repo), [WarningKind::WorkspaceNamesUnmatched]);
}

/// Every per-name refusal, in the CLI's texts; nothing is written for any.
#[test]
fn remove_refusals_write_nothing() {
    let (fx, mut repo) = two_workspaces(false, "");
    let before = head_op(&fx.root);

    let (reason, hints) = invalid(&repo.workspace_remove(&names(&["default"])).expect_err("default"));
    assert_eq!(
        reason,
        "Cannot remove workspace 'default' because it contains the repository"
    );
    assert!(hints.is_empty());

    fs::remove_dir_all(fx.ws2.join(".jj")).expect("drop ws2/.jj");
    let (reason, hints) = invalid(&repo.workspace_remove(&names(&["ws2"])).expect_err("no repo"));
    assert_eq!(reason, format!(r#"There is no jj repo in "{}""#, fx.ws2.display()));
    assert!(hints.is_empty());

    other_repo_at(&fx.ws2);
    let (reason, hints) = invalid(&repo.workspace_remove(&names(&["ws2"])).expect_err("other repo"));
    assert_eq!(
        reason,
        "Cannot remove workspace 'ws2' because it belongs to another repository"
    );
    assert_eq!(hints, [FORGET_HINT]);

    fs::remove_dir_all(&fx.ws2).expect("drop ws2");
    let (reason, hints) = invalid(&repo.workspace_remove(&names(&["ws2"])).expect_err("gone"));
    assert!(
        reason.starts_with("Cannot access workspace 'ws2' directory: "),
        "{reason}"
    );
    assert_eq!(hints, [FORGET_HINT]);

    store(&fx.root)
        .forget(&[WorkspaceName::new("ws2")])
        .expect("forget path");
    let (reason, hints) = invalid(&repo.workspace_remove(&names(&["ws2"])).expect_err("unreachable"));
    assert_eq!(reason, "Cannot remove unreachable workspace 'ws2'");
    assert_eq!(hints, [FORGET_HINT]);

    assert!(in_view(&fx.root, "ws2"));
    // Each refused call ran its pre-verb snapshot on a clean working copy: nothing written.
    assert_eq!(head_op(&fx.root), before);
}

/// A fresh, unrelated repo's workspace at `dir` (which holds no `.jj` any more).
fn other_repo_at(dir: &Path) {
    let tmp = tempfile::TempDir::new().expect("tempdir");
    let other = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_owned(),
        backend: Some(zanshin_jj::Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init other")
    .workspace_root()
    .to_owned();
    // Move the other repo's `.jj` into `dir`: a workspace of ANOTHER repository there.
    fs::rename(other.join(".jj"), dir.join(".jj")).expect("move .jj");
}
