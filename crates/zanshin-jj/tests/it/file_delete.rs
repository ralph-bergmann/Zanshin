// SPDX-License-Identifier: MIT

//! Story 9.44 — `Repo::file_delete`, one witness per `file delete` row of the I/O matrix, read
//! back through jj-lib. The CLI comparison lives in the parity oracle (`crates/zanshin-parity`).

use std::fs;

use jj_lib::object_id::ObjectId as _;
use jj_lib::repo_path::RepoPathBuf;
use zanshin_jj::{ChangeId, MutateError, WarningKind};

use crate::file_chmod::{at, fx, head, merge_commit, merge_of, op_description};

/// Whether `commit`'s tree has an entry at `path`.
fn has(commit: &jj_lib::commit::Commit, path: &str) -> bool {
    let value = pollster::block_on(
        commit
            .tree()
            .path_value(&RepoPathBuf::from_internal_string(path).expect("path")),
    )
    .expect("read");
    !value.is_absent()
}

/// A directory prefix in `@`: every entry under it goes, one operation named as the CLI names
/// it; the working copy follows.
#[test]
fn delete_in_at_removes_every_entry_under_the_prefix() {
    let mut fx = fx();
    let before = at(&fx.root);
    let result = fx.repo.file_delete(None, false, &["dir".to_owned()]).expect("delete");
    assert!(fx.repo.take_warnings().is_empty());
    assert_eq!(
        op_description(&fx.root),
        format!("delete paths in commit {}", before.id().hex())
    );
    assert_eq!(result.new_op_id.0, head(&fx.root).op_id().hex());
    let after = at(&fx.root);
    assert_eq!(after.change_id(), before.change_id());
    assert!(!has(&after, "dir/a.txt"));
    assert!(!has(&after, "dir/b.txt"));
    assert!(has(&after, "top.txt"));
    assert!(!fx.root.join("dir/a.txt").exists());
    assert!(fs::read(fx.root.join("top.txt")).is_ok());
}

/// `-r b`: `b` loses the file, `@` is rebased and loses it too; with `restore_descendants` `@`
/// keeps it.
#[test]
fn delete_in_a_revision_rebases_or_reparents_its_descendants() {
    let mut fx = fx();
    let b = fx.b.clone();
    fx.repo
        .file_delete(Some(&b), false, &["top.txt".to_owned()])
        .expect("delete");
    let at_commit = at(&fx.root);
    let parent = pollster::block_on(at_commit.parents()).expect("parents").remove(0);
    assert!(!has(&parent, "top.txt"));
    assert!(!has(&at_commit, "top.txt"), "@ was rebased");

    fx.repo
        .file_delete(Some(&b), true, &["dir/a.txt".to_owned()])
        .expect("delete, restoring descendants");
    let at_commit = at(&fx.root);
    let parent = pollster::block_on(at_commit.parents()).expect("parents").remove(0);
    assert_eq!(parent.change_id().reverse_hex(), b.0);
    assert!(!has(&parent, "dir/a.txt"));
    assert!(has(&at_commit, "dir/a.txt"), "@ kept its content");
}

/// A conflicted entry is removed like any other.
#[test]
fn a_conflict_is_deleted() {
    let mut fx = fx();
    let merge = merge_of(
        &fx.root,
        &[
            test_helpers::add_commit_with_files(&fx.root, &[], &[("k.txt", "left\n")], "left"),
            test_helpers::add_commit_with_files(&fx.root, &[], &[("k.txt", "right\n")], "right"),
        ],
    );
    fx.repo
        .file_delete(Some(&merge), false, &["k.txt".to_owned()])
        .expect("delete");
    assert!(!has(&merge_commit(&fx.root), "k.txt"));
}

/// A path that matches nothing warns, and since the tree is unchanged nothing is written.
#[test]
fn an_unmatched_path_warns_and_writes_nothing() {
    let mut fx = fx();
    let before = head(&fx.root).op_id().hex();
    let result = fx.repo.file_delete(None, false, &["nope".to_owned()]).expect("delete");
    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0].kind, WarningKind::PathsUnmatched);
    assert_eq!(warnings[0].message, "No matching entries for paths: nope");
    assert_eq!(head(&fx.root).op_id().hex(), before);
    assert_eq!(result.new_op_id.0, before);
}

/// No path is clap's refusal: before the pre-verb snapshot, so no precondition is reported and
/// the edit on disk is not snapshotted.
#[test]
fn no_path_is_refused_before_the_snapshot() {
    let mut fx = fx();
    fs::write(fx.root.join("top.txt"), "edited").expect("edit");
    let before = head(&fx.root).op_id().hex();
    let err = fx.repo.file_delete(None, false, &[]).expect_err("no paths");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "file delete requires at least one path"),
        "{err:?}"
    );
    assert!(fx.repo.take_precondition().is_none());
    assert_eq!(head(&fx.root).op_id().hex(), before);
}

/// The root commit is immutable: refused even though nothing would change, nothing written.
#[test]
fn an_immutable_revision_is_refused() {
    let mut fx = fx();
    let before = head(&fx.root).op_id().hex();
    let root = ChangeId("z".repeat(32));
    let err = fx
        .repo
        .file_delete(Some(&root), false, &["nope".to_owned()])
        .expect_err("immutable");
    assert!(matches!(err, MutateError::Immutable { .. }), "{err:?}");
    assert_eq!(head(&fx.root).op_id().hex(), before);
}
