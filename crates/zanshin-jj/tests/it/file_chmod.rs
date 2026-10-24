// SPDX-License-Identifier: MIT

//! Story 9.13 — `Repo::file_chmod`, one witness per `chmod` row of the I/O matrix, read back
//! through jj-lib. The CLI comparison lives in the parity oracle (`crates/zanshin-parity`).

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use jj_lib::backend::MergedTreeValueExt as _;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::Repo as _;
use jj_lib::repo_path::RepoPathBuf;
use tempfile::TempDir;
use zanshin_jj::{Backend, ChangeId, MutateError, Repo, WarningKind};

/// A repo whose `@-` (`b`) holds `dir/a.txt`, `dir/b.txt`, `top.txt` and the symlink `link`, with
/// an empty `@` on it.
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    repo: Repo,
    b: ChangeId,
}

fn fx() -> Fx {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_owned(),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init")
    .workspace_root()
    .to_owned();
    fs::create_dir(root.join("dir")).expect("mkdir");
    for path in ["dir/a.txt", "dir/b.txt", "top.txt"] {
        fs::write(root.join(path), path).expect("write");
    }
    std::os::unix::fs::symlink("top.txt", root.join("link")).expect("symlink");
    let mut repo = Repo::open(&root).expect("open");
    let _ = repo.status().expect("record the files");
    let b = ChangeId(at(&root).change_id().reverse_hex());
    repo.new_change(std::slice::from_ref(&b), &[], &[]).expect("new @ on b");
    Fx {
        _tmp: tmp,
        root,
        repo,
        b,
    }
}

fn head(root: &Path) -> std::sync::Arc<jj_lib::repo::ReadonlyRepo> {
    let workspace = jj_lib::workspace::Workspace::load(
        &test_helpers::test_settings(),
        root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load workspace");
    pollster::block_on(workspace.repo_loader().load_at_head()).expect("head")
}

fn at(root: &Path) -> jj_lib::commit::Commit {
    let repo = head(root);
    let id = repo.view().get_wc_commit_id(WorkspaceName::DEFAULT).expect("@").clone();
    repo.store().get_commit(&id).expect("@ commit")
}

/// The executable bit of `path` in `commit`'s tree.
fn executable(commit: &jj_lib::commit::Commit, path: &str) -> bool {
    let value = pollster::block_on(
        commit
            .tree()
            .path_value(&RepoPathBuf::from_internal_string(path).expect("path")),
    )
    .expect("read");
    value
        .to_executable_merge()
        .expect("a file")
        .into_resolved()
        .expect("resolved")
        .expect("present")
}

fn op_description(root: &Path) -> String {
    head(root).operation().metadata().description.clone()
}

/// `x` then `n` on `@`'s `top.txt`: the bit set and cleared, one operation each, named after
/// `@`'s commit as the CLI names it.
#[test]
fn chmod_sets_and_clears_the_bit_in_at() {
    let mut fx = fx();
    let before = at(&fx.root);
    let result = fx
        .repo
        .file_chmod(true, None, &["top.txt".to_owned()])
        .expect("chmod x");
    assert!(fx.repo.take_warnings().is_empty());
    let after = at(&fx.root);
    assert_eq!(after.change_id(), before.change_id());
    assert!(executable(&after, "top.txt"));
    assert!(!executable(&after, "dir/a.txt"));
    assert_eq!(
        op_description(&fx.root),
        format!("make paths executable in commit {}", before.id().hex())
    );
    assert_eq!(result.new_op_id.0, head(&fx.root).op_id().hex());
    assert_eq!(
        result.working_copy_change_id,
        Some(ChangeId(after.change_id().reverse_hex()))
    );
    // The working copy follows: the file is executable on disk.
    let mode = fs::metadata(fx.root.join("top.txt"))
        .expect("stat")
        .permissions()
        .mode();
    assert_ne!(mode & 0o111, 0);

    fx.repo
        .file_chmod(false, None, &["top.txt".to_owned()])
        .expect("chmod n");
    let cleared = at(&fx.root);
    assert!(!executable(&cleared, "top.txt"));
    assert_eq!(
        op_description(&fx.root),
        format!("make paths non-executable in commit {}", after.id().hex())
    );
}

/// `-r b` with a directory prefix: every file under it changes in `b`, `@` is rebased onto the
/// rewritten `b`.
#[test]
fn chmod_rewrites_the_revision_and_rebases_its_descendants() {
    let mut fx = fx();
    let b = fx.b.clone();
    fx.repo.file_chmod(true, Some(&b), &["dir".to_owned()]).expect("chmod");
    let parent = pollster::block_on(at(&fx.root).parents()).expect("parents").remove(0);
    assert_eq!(parent.change_id().reverse_hex(), b.0);
    assert!(executable(&parent, "dir/a.txt"));
    assert!(executable(&parent, "dir/b.txt"));
    assert!(!executable(&parent, "top.txt"));
    assert!(executable(&at(&fx.root), "dir/a.txt"), "@ was rebased onto the new b");
}

/// A path that matches nothing warns, and the call still writes its operation.
#[test]
fn an_unmatched_path_warns() {
    let mut fx = fx();
    let before = head(&fx.root).op_id().hex();
    fx.repo
        .file_chmod(true, None, &["nope".to_owned(), "top.txt".to_owned()])
        .expect("chmod");
    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0].kind, WarningKind::PathsUnmatched);
    assert_eq!(warnings[0].message, "No matching entries for paths: nope");
    assert_ne!(head(&fx.root).op_id().hex(), before);
}

/// The root commit is immutable: refused, nothing written.
#[test]
fn an_immutable_revision_is_refused() {
    let mut fx = fx();
    let before = head(&fx.root).op_id().hex();
    let root = ChangeId("z".repeat(32));
    let err = fx
        .repo
        .file_chmod(true, Some(&root), &["top.txt".to_owned()])
        .expect_err("immutable");
    assert!(matches!(err, MutateError::Immutable { .. }), "{err:?}");
    assert_eq!(head(&fx.root).op_id().hex(), before);
}

/// A symlink is neither a file nor a conflict: the CLI's text, nothing written.
#[test]
fn a_symlink_is_refused_with_the_clis_text() {
    let mut fx = fx();
    let before = head(&fx.root).op_id().hex();
    let err = fx
        .repo
        .file_chmod(true, None, &["link".to_owned()])
        .expect_err("symlink");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "Found neither a file nor a conflict at 'link'."),
        "{err:?}"
    );
    assert_eq!(head(&fx.root).op_id().hex(), before);
}

/// No path is clap's refusal: before the pre-verb snapshot, so no precondition is reported and
/// the edit on disk is not snapshotted.
#[test]
fn no_path_is_refused_before_the_snapshot() {
    let mut fx = fx();
    fs::write(fx.root.join("top.txt"), "edited").expect("edit");
    let before = head(&fx.root).op_id().hex();
    let err = fx.repo.file_chmod(true, None, &[]).expect_err("no paths");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    assert!(fx.repo.take_precondition().is_none());
    assert_eq!(head(&fx.root).op_id().hex(), before);
}

/// A merge of `parents` (hex commit ids) with jj-lib's merged tree, added as a head; returns its
/// change id.
fn merge_of(root: &Path, parents: &[String]) -> ChangeId {
    let repo = head(root);
    let commits: Vec<jj_lib::commit::Commit> = parents
        .iter()
        .map(|hex| {
            let id = jj_lib::backend::CommitId::try_from_hex(hex).expect("hex");
            repo.store().get_commit(&id).expect("parent")
        })
        .collect();
    let mut tx = repo.start_transaction();
    let tree = pollster::block_on(jj_lib::rewrite::merge_commit_trees(tx.repo(), &commits)).expect("merge");
    let ids = commits.iter().map(|c| c.id().clone()).collect();
    let merge =
        pollster::block_on(tx.repo_mut().new_commit(ids, tree).set_description("merge").write()).expect("write");
    pollster::block_on(tx.repo_mut().add_head(&merge)).expect("head");
    pollster::block_on(tx.commit("test: merge")).expect("commit");
    ChangeId(merge.change_id().reverse_hex())
}

/// The head commit described `merge` (the merge after its rewrite).
fn merge_commit(root: &Path) -> jj_lib::commit::Commit {
    let repo = head(root);
    repo.view()
        .heads()
        .iter()
        .map(|id| repo.store().get_commit(id).expect("head"))
        .find(|commit| commit.description() == "merge")
        .expect("the merge is a head")
}

/// A file/file conflict: every file side takes the bit, the conflict stays.
#[test]
fn chmod_sets_the_bit_on_every_side_of_a_file_conflict() {
    let mut fx = fx();
    let merge = merge_of(
        &fx.root,
        &[
            test_helpers::add_commit_with_files(&fx.root, &[], &[("k.txt", "left\n")], "left"),
            test_helpers::add_commit_with_files(&fx.root, &[], &[("k.txt", "right\n")], "right"),
        ],
    );
    fx.repo
        .file_chmod(true, Some(&merge), &["k.txt".to_owned()])
        .expect("chmod");
    let value = pollster::block_on(
        merge_commit(&fx.root)
            .tree()
            .path_value(&RepoPathBuf::from_internal_string("k.txt").expect("path")),
    )
    .expect("read");
    assert!(!value.is_resolved(), "still a conflict");
    let bits = value.to_executable_merge().expect("every side a file or absent");
    assert!(bits.iter().flatten().all(|bit| *bit), "{bits:?}");
    assert!(bits.iter().flatten().count() >= 2);
}

/// A file/symlink conflict refuses with the CLI's text and writes nothing.
#[test]
fn a_conflict_with_a_symlink_side_is_refused_with_the_clis_text() {
    let mut fx = fx();
    let merge = merge_of(
        &fx.root,
        &[
            test_helpers::add_commit_with_files(&fx.root, &[], &[("k.txt", "left\n")], "left"),
            test_helpers::add_commit_with_entries(
                &fx.root,
                &[],
                &[("k.txt", test_helpers::Entry::Symlink("elsewhere"))],
                "link",
            ),
        ],
    );
    let before = head(&fx.root).op_id().hex();
    let err = fx
        .repo
        .file_chmod(true, Some(&merge), &["k.txt".to_owned()])
        .expect_err("symlink side");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "Some of the sides of the conflict are not files at 'k.txt'."),
        "{err:?}"
    );
    assert_eq!(head(&fx.root).op_id().hex(), before);
}
