// SPDX-License-Identifier: MIT

//! Story 9.44 — `Repo::file_edit`, one witness per `file edit` row of the I/O matrix, read back
//! through jj-lib and `file_show`. The CLI comparison lives in the parity oracle
//! (`crates/zanshin-parity`).

use std::fs;

use jj_lib::object_id::ObjectId as _;
use zanshin_jj::{ChangeId, MutateError, Repo};

use crate::file_chmod::{at, executable, fx, head, merge_commit, merge_of, op_description};

/// `path`'s content in `revision` (`None` = `@`) and whether it is a materialized conflict.
fn show(repo: &mut Repo, revision: Option<&ChangeId>, path: &str) -> (Vec<u8>, bool) {
    let mut shown = repo
        .file_show(revision.cloned(), &[path.to_owned()])
        .expect("file show")
        .files;
    assert_eq!(shown.len(), 1, "{path} is shown");
    let file = shown.remove(0);
    (file.content, file.conflict)
}

fn assert_refused(err: &MutateError, expected: &str) {
    assert!(
        matches!(err, MutateError::InvalidInput { reason, .. } if reason == expected),
        "{err:?}"
    );
}

/// In `@`: the content changes in the revision AND on disk, one operation named after `@`'s
/// commit as the CLI names it.
#[test]
fn edit_in_at_rewrites_at_and_the_working_copy_follows() {
    let mut fx = fx();
    let before = at(&fx.root);
    let result = fx.repo.file_edit(None, false, "top.txt", b"new\n").expect("edit");
    assert!(fx.repo.take_warnings().is_empty());
    assert_eq!(
        op_description(&fx.root),
        format!("edit file top.txt in commit {}", before.id().hex())
    );
    assert_eq!(result.new_op_id.0, head(&fx.root).op_id().hex());
    let after = at(&fx.root);
    assert_eq!(after.change_id(), before.change_id());
    assert_eq!(show(&mut fx.repo, None, "top.txt"), (b"new\n".to_vec(), false));
    assert_eq!(fs::read(fx.root.join("top.txt")).expect("read"), b"new\n");
}

/// `-r b`: `b` takes the content, `@` (its child, inheriting the file) is rebased and shows it.
#[test]
fn edit_in_a_revision_rebases_its_descendants() {
    let mut fx = fx();
    let b = fx.b.clone();
    fx.repo.file_edit(Some(&b), false, "top.txt", b"new\n").expect("edit");
    assert_eq!(show(&mut fx.repo, Some(&b), "top.txt").0, b"new\n");
    assert_eq!(show(&mut fx.repo, None, "top.txt").0, b"new\n");
}

/// `--restore-descendants`: `b` changes, `@` keeps its content (reparented).
#[test]
fn restore_descendants_keeps_the_childrens_content() {
    let mut fx = fx();
    let b = fx.b.clone();
    fx.repo.file_edit(Some(&b), true, "top.txt", b"new\n").expect("edit");
    assert_eq!(show(&mut fx.repo, Some(&b), "top.txt").0, b"new\n");
    assert_eq!(show(&mut fx.repo, None, "top.txt").0, b"top.txt");
    let parent = pollster::block_on(at(&fx.root).parents()).expect("parents").remove(0);
    assert_eq!(parent.change_id().reverse_hex(), b.0, "@ still sits on b");
}

/// An absent path is created non-executable, also below directories the revision lacks.
#[test]
fn an_absent_path_is_created_with_its_missing_parents() {
    let mut fx = fx();
    fx.repo.file_edit(None, false, "new.txt", b"fresh\n").expect("edit");
    fx.repo
        .file_edit(None, false, "x/y/new.txt", b"deep\n")
        .expect("nested edit");
    assert_eq!(show(&mut fx.repo, None, "new.txt").0, b"fresh\n");
    assert_eq!(show(&mut fx.repo, None, "x/y/new.txt").0, b"deep\n");
    let at = at(&fx.root);
    assert!(!executable(&at, "new.txt"));
    assert!(!executable(&at, "x/y/new.txt"));
}

/// An executable file keeps its bit.
#[test]
fn an_executable_file_stays_executable() {
    let mut fx = fx();
    fx.repo.file_chmod(true, None, &["top.txt".to_owned()]).expect("chmod");
    fx.repo.file_edit(None, false, "top.txt", b"#!/bin/sh\n").expect("edit");
    let at = at(&fx.root);
    assert!(executable(&at, "top.txt"));
    assert_eq!(show(&mut fx.repo, None, "top.txt").0, b"#!/bin/sh\n");
}

/// The current bytes again: "Nothing changed." — no operation, the pre-call head returned.
#[test]
fn an_unchanged_buffer_writes_nothing() {
    let mut fx = fx();
    let before = head(&fx.root).op_id().hex();
    let result = fx.repo.file_edit(None, false, "top.txt", b"top.txt").expect("edit");
    assert_eq!(head(&fx.root).op_id().hex(), before);
    assert_eq!(result.new_op_id.0, before);
}

/// An empty buffer is an empty file.
#[test]
fn empty_content_is_an_empty_file() {
    let mut fx = fx();
    fx.repo.file_edit(None, false, "top.txt", b"").expect("edit");
    assert_eq!(show(&mut fx.repo, None, "top.txt"), (Vec::new(), false));
}

/// A file/file conflict: `file_show`'s text unchanged is a no-op, one side edited inside the
/// markers stays conflicted, a marker-free buffer resolves it.
#[test]
fn a_conflict_round_trips_through_its_materialized_text() {
    let mut fx = fx();
    let merge = merge_of(
        &fx.root,
        &[
            test_helpers::add_commit_with_files(&fx.root, &[], &[("k.txt", "left\n")], "left"),
            test_helpers::add_commit_with_files(&fx.root, &[], &[("k.txt", "right\n")], "right"),
        ],
    );
    let (text, conflict) = show(&mut fx.repo, Some(&merge), "k.txt");
    assert!(conflict);

    let before = head(&fx.root).op_id().hex();
    fx.repo
        .file_edit(Some(&merge), false, "k.txt", &text)
        .expect("unchanged");
    assert_eq!(head(&fx.root).op_id().hex(), before, "nothing changed");

    let text = String::from_utf8(text).expect("utf-8");
    let edited = text.replacen("\nright\n", "\nRIGHT\n", 1);
    assert_ne!(edited, text, "the right side is in the markers: {text}");
    fx.repo
        .file_edit(Some(&merge), false, "k.txt", edited.as_bytes())
        .expect("edit a side");
    let (content, conflict) = show(&mut fx.repo, Some(&merge), "k.txt");
    assert!(conflict, "still conflicted");
    assert!(String::from_utf8(content).expect("utf-8").contains("RIGHT"));

    fx.repo
        .file_edit(Some(&merge), false, "k.txt", b"resolved\n")
        .expect("resolve");
    assert_eq!(
        show(&mut fx.repo, Some(&merge), "k.txt"),
        (b"resolved\n".to_vec(), false)
    );
    assert_eq!(merge_commit(&fx.root).change_id().reverse_hex(), merge.0);
}

/// A directory, a symlink and a file/symlink conflict refuse with the CLI's texts; nothing is
/// written.
#[test]
fn non_files_are_refused_with_the_clis_texts() {
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
    let err = fx.repo.file_edit(None, false, "dir", b"x").expect_err("directory");
    assert_refused(&err, "Path is a directory: dir");
    let err = fx.repo.file_edit(None, false, "", b"x").expect_err("the root");
    assert_refused(&err, "Path is a directory: .");
    let err = fx.repo.file_edit(None, false, "link", b"x").expect_err("symlink");
    assert_refused(&err, "Path 'link' is not a regular file");
    let err = fx
        .repo
        .file_edit(Some(&merge), false, "k.txt", b"x")
        .expect_err("non-file conflict");
    assert_refused(&err, "Path 'k.txt' has a non-file conflict and cannot be edited");
    assert_eq!(head(&fx.root).op_id().hex(), before);
}

/// A path below a FILE refuses: writing it would replace the file with a directory.
#[test]
fn a_file_ancestor_is_refused() {
    let mut fx = fx();
    let before = head(&fx.root).op_id().hex();
    let err = fx
        .repo
        .file_edit(None, false, "dir/a.txt/x", b"x")
        .expect_err("ancestor is a file");
    assert_refused(&err, "Failed to edit file: 'dir/a.txt' is not a directory");
    assert_eq!(head(&fx.root).op_id().hex(), before);
    assert_eq!(show(&mut fx.repo, None, "dir/a.txt").0, b"dir/a.txt");
}

/// The root commit is immutable: refused before the path is even looked at, nothing written.
#[test]
fn an_immutable_revision_is_refused() {
    let mut fx = fx();
    let before = head(&fx.root).op_id().hex();
    let root = ChangeId("z".repeat(32));
    let err = fx.repo.file_edit(Some(&root), false, "", b"").expect_err("immutable");
    assert!(matches!(err, MutateError::Immutable { .. }), "{err:?}");
    assert_eq!(head(&fx.root).op_id().hex(), before);
}

/// The path parses as the CLI's `parse_file_path` from the workspace root: a trailing `/`, a
/// doubled `/` and an absolute path inside the workspace normalise.
#[test]
fn the_path_parses_as_the_clis_file_path() {
    let mut fx = fx();
    let err = fx.repo.file_edit(None, false, "dir/", b"x").expect_err("directory");
    assert_refused(&err, "Path is a directory: dir");
    fx.repo
        .file_edit(None, false, "dir//a.txt", b"one\n")
        .expect("doubled slash");
    assert_eq!(show(&mut fx.repo, None, "dir/a.txt").0, b"one\n");
    let absolute = fx.root.join("top.txt").to_string_lossy().into_owned();
    fx.repo
        .file_edit(None, false, &absolute, b"two\n")
        .expect("absolute path");
    assert_eq!(show(&mut fx.repo, None, "top.txt").0, b"two\n");
}

/// A `ui.conflict-marker-style` that is not one of jj's styles is the user's config being wrong:
/// refused naming the key, nothing written.
#[test]
fn an_invalid_conflict_marker_style_is_a_config_error() {
    let mut fx = fx();
    fs::write(
        fx.root.join(".jj").join("repo").join("config.toml"),
        "[ui]\nconflict-marker-style = \"nonsense\"\n",
    )
    .expect("repo config");
    let before = head(&fx.root).op_id().hex();
    let err = fx
        .repo
        .file_edit(None, false, "top.txt", b"x")
        .expect_err("an unknown marker style is refused");
    // The pre-verb start-up reads the key first (the CLI's command environment), as for
    // `file_show`.
    assert!(
        matches!(&err, MutateError::Precondition(zanshin_jj::PreconditionError::Config { reason }) if reason.contains("conflict-marker-style")),
        "{err:?}"
    );
    assert_eq!(head(&fx.root).op_id().hex(), before);
}
