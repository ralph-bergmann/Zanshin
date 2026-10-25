// SPDX-License-Identifier: MIT

//! Story 9.17 — `Repo::resolve_list` and `Repo::resolve`, one witness per row of the I/O matrix,
//! read back through jj-lib.
//!
//! The base history is `rebase.rs`' (`A → B → C = @`); each test builds its conflicts in-test by
//! merging siblings of `A` that write the same path differently. The CLI comparison lives in the
//! parity oracle (`crates/zanshin-parity`).

use std::fs;

use futures::AsyncReadExt as _;
use jj_lib::backend::TreeValue;
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo_path::RepoPathBuf;
use zanshin_jj::{
    ChangeId, MutateError, ResolveList, ResolveListOptions, ResolveOptions, ResolveTool, ResolvedFile, WarningKind,
};

use crate::rebase::{add, assert_op, base, change_id, commit, hex, immutable, parents, reconfigure, refused, wc, Fx};

/// `A` → `X` and `A` → `Y` writing `files_x` / `files_y`, merged into `M` = `@`. Returns `M`.
fn conflicted_merge(fx: &mut Fx, files_x: &[(&str, &str)], files_y: &[(&str, &str)]) -> ChangeId {
    let a = fx.a.clone();
    let x = add(fx, std::slice::from_ref(&a), files_x, "X\n");
    let y = add(fx, std::slice::from_ref(&a), files_y, "Y\n");
    add(fx, &[x, y], &[], "M\n")
}

/// `@` = a merge conflicted on `c.txt` (`c from C` / `c from D`, no base).
fn two_sided(fx: &mut Fx) -> ChangeId {
    conflicted_merge(fx, &[("c.txt", "c from C\n")], &[("c.txt", "c from D\n")])
}

fn list(fx: &mut Fx, revision: Option<&ChangeId>, paths: &[&str]) -> Result<ResolveList, MutateError> {
    fx.repo.resolve_list(&ResolveListOptions {
        revision: revision.cloned(),
        paths: paths.iter().map(|p| (*p).to_owned()).collect(),
    })
}

fn options(revision: Option<&ChangeId>, paths: &[&str], tool: ResolveTool) -> ResolveOptions {
    ResolveOptions {
        revision: revision.cloned(),
        paths: paths.iter().map(|p| (*p).to_owned()).collect(),
        tool,
    }
}

/// The GUI's files with a placeholder term-id token — for refusals that come before it is read.
fn files(files: &[(&str, &str)]) -> ResolveTool {
    with_ids(files, |_| vec![Some("00".to_owned())])
}

/// The GUI's files, each with the term ids `resolve_list` reports for its path at `revision` (a
/// path it does not list — no conflict there — gets a placeholder).
fn listed(fx: &mut Fx, revision: Option<&ChangeId>, entries: &[(&str, &str)]) -> ResolveTool {
    let conflicts = list(fx, revision, &[]).map(|listed| listed.files).unwrap_or_default();
    with_ids(entries, |path| {
        conflicts
            .iter()
            .find(|file| file.path == path)
            .map_or_else(|| vec![Some("00".to_owned())], |file| file.term_ids.clone())
    })
}

fn with_ids(files: &[(&str, &str)], ids: impl Fn(&str) -> Vec<Option<String>>) -> ResolveTool {
    ResolveTool::Files(
        files
            .iter()
            .map(|(path, content)| ResolvedFile {
                path: (*path).to_owned(),
                content: content.as_bytes().to_vec(),
                term_ids: ids(path),
            })
            .collect(),
    )
}

/// The hex file id of the resolved file `path` in `id`'s tree.
fn file_id(fx: &Fx, id: &ChangeId, path: &str) -> String {
    let path = RepoPathBuf::from_internal_string(path).expect("path");
    let value = pollster::block_on(commit(&fx.root, id).tree().path_value(&path)).expect("path value");
    let Ok(Some(TreeValue::File { id, .. })) = value.into_resolved() else {
        panic!("not a resolved file");
    };
    id.hex()
}

/// `path`'s resolved content in `tree`; `<absent>` when absent, `<conflict>` when conflicted.
pub(crate) fn content(tree: &MergedTree, path: &str) -> String {
    let path = RepoPathBuf::from_internal_string(path).expect("path");
    let value = pollster::block_on(tree.path_value(&path)).expect("path value");
    let Ok(value) = value.into_resolved() else {
        return "<conflict>".to_owned();
    };
    let Some(value) = value else {
        return "<absent>".to_owned();
    };
    let TreeValue::File { id, .. } = value else {
        panic!("not a file");
    };
    let mut text = Vec::new();
    pollster::block_on(async {
        tree.store()
            .read_file(&path, &id)
            .await
            .expect("read")
            .read_to_end(&mut text)
            .await
            .expect("read to end")
    });
    String::from_utf8(text).expect("utf-8")
}

fn kinds(fx: &mut Fx) -> Vec<WarningKind> {
    fx.repo.take_warnings().into_iter().map(|w| w.kind).collect()
}

fn no_conflicts(err: &MutateError) -> String {
    let MutateError::NoConflicts { message } = err else {
        panic!("not NoConflicts: {err:?}");
    };
    message.clone()
}

// ── resolve_list ────────────────────────────────────────────────────────────────

/// A 2-sided file conflict: the CLI's description, two sides, resolvable, and one conflicting hunk
/// of three terms — side 1, the (absent) base, side 2.
#[test]
fn list_reports_a_two_sided_file_conflict_with_its_three_term_hunk() {
    let mut fx = base();
    let m = two_sided(&mut fx);
    let listed = list(&mut fx, None, &[]).expect("list");
    let [file] = listed.files.as_slice() else {
        panic!("one conflict: {listed:?}");
    };
    assert_eq!(file.path, "c.txt");
    assert_eq!(file.description, "2-sided conflict");
    assert_eq!(file.num_sides, 2);
    assert_eq!(file.unresolvable, None);
    assert_eq!(file.labels, merge_labels(&fx, &m));
    let terms: Vec<Vec<Vec<u8>>> = file.hunks.iter().map(|hunk| hunk.terms.clone()).collect();
    assert_eq!(
        terms,
        [vec![b"c from C\n".to_vec(), Vec::new(), b"c from D\n".to_vec()]]
    );
}

/// The term ids are the simplified file ids in `Merge` order: side 1, the absent base, side 2.
#[test]
fn list_reports_the_term_ids_with_an_absent_base() {
    let mut fx = base();
    let m = two_sided(&mut fx);
    let [x, y] = <[ChangeId; 2]>::try_from(parents(&fx.root, &m)).expect("two parents");
    let listed = list(&mut fx, None, &[]).expect("list");
    assert_eq!(
        listed.files[0].term_ids,
        [Some(file_id(&fx, &x, "c.txt")), None, Some(file_id(&fx, &y, "c.txt"))]
    );
}

/// An EMPTY file on a side is a file: its term id is present, unlike the absent base's.
#[test]
fn an_empty_file_side_has_a_term_id_and_an_absent_base_none() {
    let mut fx = base();
    let m = conflicted_merge(&mut fx, &[("c.txt", "x\n")], &[("c.txt", "")]);
    let [_, y] = <[ChangeId; 2]>::try_from(parents(&fx.root, &m)).expect("two parents");
    let listed = list(&mut fx, None, &[]).expect("list");
    let ids = &listed.files[0].term_ids;
    assert_eq!(ids[1], None, "the absent base");
    assert_eq!(ids[2], Some(file_id(&fx, &y, "c.txt")), "the empty side");
}

/// The conflict changes after `resolve_list` (a side's commit is rewritten, `@` rebased) but stays
/// a 2-sided file conflict: the old term ids refuse as stale, nothing written; the new ones
/// resolve.
#[test]
fn a_conflict_changed_since_the_list_is_stale() {
    let mut fx = base();
    let m = two_sided(&mut fx);
    let [x, _] = <[ChangeId; 2]>::try_from(parents(&fx.root, &m)).expect("two parents");
    let old = listed(&mut fx, None, &[("c.txt", "merged\n")]);
    fx.repo.edit(x).expect("edit X");
    fs::write(fx.root.join("c.txt"), "c from E\n").expect("rewrite X's side");
    fx.repo.edit(m.clone()).expect("back to M");
    let listed_now = list(&mut fx, None, &[]).expect("list");
    assert_eq!(listed_now.files[0].num_sides, 2, "still a 2-sided file conflict");
    let err = refused(&mut fx, |repo| repo.resolve(&options(None, &[], old)));
    assert!(
        matches!(&err, MutateError::StaleSelection { reason }
            if reason == "The conflict at \"c.txt\" changed since it was listed: re-read it and resolve again"),
        "{err:?}"
    );
    assert_eq!(content(&commit(&fx.root, &m).tree(), "c.txt"), "<conflict>");
    let fresh = listed(&mut fx, None, &[("c.txt", "merged\n")]);
    fx.repo.resolve(&options(None, &[], fresh)).expect("resolve");
    assert_eq!(content(&commit(&fx.root, &m).tree(), "c.txt"), "merged\n");
}

/// jj's conflict label of `id`: short change id, short commit id, quoted first description line.
fn label(fx: &Fx, id: &ChangeId) -> String {
    let commit = commit(&fx.root, id);
    let line = commit.description().lines().next().unwrap_or_default();
    format!("{} {} \"{line}\"", &id.0[..8], &hex(&fx.root, id)[..8])
}

/// The labels of `m`'s conflicts: side 1 (`X`), the base (`A`), side 2 (`Y`).
fn merge_labels(fx: &Fx, m: &ChangeId) -> Vec<String> {
    let [x, y] = <[ChangeId; 2]>::try_from(parents(&fx.root, m)).expect("two parents");
    vec![label(fx, &x), label(fx, &fx.a), label(fx, &y)]
}

/// Both sides modify `A`'s `a.txt`: the base term is `A`'s text.
#[test]
fn list_reports_the_base_of_a_conflict_over_an_existing_file() {
    let mut fx = base();
    let m = conflicted_merge(&mut fx, &[("a.txt", "x\n")], &[("a.txt", "y\n")]);
    let listed = list(&mut fx, None, &["a.txt"]).expect("list");
    let [file] = listed.files.as_slice() else {
        panic!("one conflict: {listed:?}");
    };
    assert_eq!(file.path, "a.txt");
    assert_eq!(file.labels, merge_labels(&fx, &m));
    let terms: Vec<Vec<Vec<u8>>> = file.hunks.iter().map(|hunk| hunk.terms.clone()).collect();
    assert_eq!(terms, [vec![b"x\n".to_vec(), b"a\n".to_vec(), b"y\n".to_vec()]]);
}

/// A file/symlink conflict has no hunks and the CLI's `NotNormalFiles` text; a 3-sided file
/// conflict has hunks and the CLI's `ConflictTooComplicated` text.
#[test]
fn list_marks_non_file_and_three_sided_conflicts_unresolvable() {
    let mut fx = base();
    let base_a = fx.a.clone();
    let on_a = std::slice::from_ref(&base_a);
    let side_x = add(&mut fx, on_a, &[("c.txt", "x\n")], "X\n");
    fx.repo.new_change(on_a, &[], &[]).expect("new y");
    std::os::unix::fs::symlink("target", fx.root.join("c.txt")).expect("symlink");
    let side_y = change_id(&wc(&fx.root));
    let side_z = add(&mut fx, on_a, &[("c.txt", "z\n")], "Z\n");
    add(&mut fx, &[side_x.clone(), side_y], &[], "M\n");
    let listed = list(&mut fx, None, &[]).expect("list");
    let [file] = listed.files.as_slice() else {
        panic!("one conflict: {listed:?}");
    };
    assert_eq!(file.description, "2-sided conflict including a symlink");
    assert!(file.hunks.is_empty() && file.labels.is_empty());
    let text = file.unresolvable.as_deref().expect("unresolvable");
    assert!(
        text.starts_with(
            "Only conflicts that involve normal files (not symlinks, etc.) are supported. Conflict summary for \"c.txt\":\n"
        ),
        "{text}"
    );
    assert!(file.term_ids.is_empty(), "a non-file conflict has no term ids");
    // A non-file conflict cannot go through `Files`: any token is stale.
    let stale = "The conflict at \"c.txt\" changed since it was listed: re-read it and resolve again";
    let err = refused(&mut fx, |repo| {
        repo.resolve(&options(None, &[], files(&[("c.txt", "x\n")])))
    });
    assert!(
        matches!(&err, MutateError::StaleSelection { reason } if reason == stale),
        "{err:?}"
    );

    let side_w = add(&mut fx, on_a, &[("c.txt", "w\n")], "W\n");
    add(&mut fx, &[side_x, side_z, side_w], &[], "N\n");
    let listed = list(&mut fx, None, &[]).expect("list");
    let [file] = listed.files.as_slice() else {
        panic!("one conflict: {listed:?}");
    };
    assert_eq!(file.description, "3-sided conflict");
    assert_eq!(file.num_sides, 3);
    assert_eq!(
        file.unresolvable.as_deref(),
        Some("The conflict at \"c.txt\" has 3 sides. At most 2 sides are supported.")
    );
    assert_eq!(file.hunks.iter().map(|hunk| hunk.terms.len()).collect::<Vec<_>>(), [5]);
    let listed_ids = file.term_ids.clone();

    let err = refused(&mut fx, |repo| repo.resolve(&options(None, &[], ResolveTool::Ours)));
    assert!(
        matches!(&err, MutateError::ConflictNotResolvable { message }
            if message == "The conflict at \"c.txt\" has 3 sides. At most 2 sides are supported."),
        "{err:?}"
    );

    // `Files`: the listed ids pass the staleness check and meet the resolvability refusal; a
    // changed id is stale first.
    let tool = with_ids(&[("c.txt", "x\n")], |_| listed_ids.clone());
    let err = refused(&mut fx, |repo| repo.resolve(&options(None, &[], tool)));
    assert!(
        matches!(&err, MutateError::ConflictNotResolvable { message } if message.contains("has 3 sides")),
        "{err:?}"
    );
    let mut changed = listed_ids.clone();
    changed[0] = Some("0".repeat(40));
    let tool = with_ids(&[("c.txt", "x\n")], |_| changed.clone());
    let err = refused(&mut fx, |repo| repo.resolve(&options(None, &[], tool)));
    assert!(
        matches!(&err, MutateError::StaleSelection { reason } if reason == stale),
        "{err:?}"
    );
}

/// A conflict in the executable bit: the CLI's `ExecutableConflict` text, in the list and as the
/// refusal.
#[test]
fn an_executable_bit_conflict_is_unresolvable() {
    use std::os::unix::fs::PermissionsExt as _;
    let mut fx = base();
    let a = fx.a.clone();
    let x = add(&mut fx, std::slice::from_ref(&a), &[("c.txt", "x\n")], "X\n");
    fs::set_permissions(fx.root.join("c.txt"), fs::Permissions::from_mode(0o755)).expect("chmod");
    let y = add(&mut fx, std::slice::from_ref(&a), &[("c.txt", "y\n")], "Y\n");
    add(&mut fx, &[x, y], &[], "M\n");
    let listed = list(&mut fx, None, &[]).expect("list");
    let [file] = listed.files.as_slice() else {
        panic!("one conflict: {listed:?}");
    };
    assert_eq!(file.description, "2-sided conflict including an executable");
    let text = file.unresolvable.clone().expect("unresolvable");
    assert!(
        text.starts_with("\"c.txt\" has conflicts in executable bit\n"),
        "{text}"
    );
    let err = refused(&mut fx, |repo| {
        repo.resolve(&options(None, &["c.txt"], ResolveTool::Ours))
    });
    assert!(
        matches!(&err, MutateError::ConflictNotResolvable { message } if *message == text),
        "{err:?}"
    );
}

/// A clean revision, and paths matching no conflict, refuse with the CLI's two texts; an absent
/// explicit path also warns.
#[test]
fn no_conflicts_refuse_with_the_clis_texts() {
    let mut fx = base();
    let c = fx.c.clone();
    let err = list(&mut fx, Some(&c), &[]).expect_err("clean");
    assert_eq!(no_conflicts(&err), "No conflicts found at this revision");
    let err = refused(&mut fx, |repo| repo.resolve(&options(Some(&c), &[], ResolveTool::Ours)));
    assert_eq!(no_conflicts(&err), "No conflicts found at this revision");

    two_sided(&mut fx);
    let _ = fx.repo.take_warnings();
    let err = list(&mut fx, None, &["a.txt"]).expect_err("no conflict at a.txt");
    assert_eq!(no_conflicts(&err), "No conflicts found at the given path(s)");
    assert_eq!(kinds(&mut fx), []);
    let err = list(&mut fx, None, &["nope.txt"]).expect_err("absent");
    assert_eq!(no_conflicts(&err), "No conflicts found at the given path(s)");
    assert_eq!(kinds(&mut fx), [WarningKind::PathsUnmatched]);
}

// ── resolve ─────────────────────────────────────────────────────────────────────

/// `:ours` takes side 1, `:theirs` side 2; the operation is the CLI's.
#[test]
fn ours_and_theirs_take_side_one_and_side_two() {
    for (tool, expected) in [(ResolveTool::Ours, "c from C\n"), (ResolveTool::Theirs, "c from D\n")] {
        let mut fx = base();
        let m = two_sided(&mut fx);
        let m_hex = hex(&fx.root, &m);
        let result = fx.repo.resolve(&options(None, &[], tool)).expect("resolve");
        assert_op(&fx, &result, &format!("Resolve conflicts in commit {m_hex}"));
        let tree = commit(&fx.root, &m).tree();
        assert_eq!(content(&tree, "c.txt"), expected);
        assert!(!tree.has_conflict());
        assert_eq!(result.working_copy_change_id, Some(m));
        assert_eq!(kinds(&mut fx), []);
    }
}

/// `path`'s executable bit in `tree` (a resolved file).
fn executable(tree: &MergedTree, path: &str) -> bool {
    let path = RepoPathBuf::from_internal_string(path).expect("path");
    let value = pollster::block_on(tree.path_value(&path)).expect("path value");
    let Ok(Some(TreeValue::File { executable, .. })) = value.into_resolved() else {
        panic!("not a resolved file");
    };
    executable
}

/// Both sides make `c.txt` executable: `:ours` and the GUI's content keep `+x`.
#[test]
fn a_resolution_keeps_the_executable_bit() {
    use std::os::unix::fs::PermissionsExt as _;
    for (gui_files, expected) in [(false, "x\n"), (true, "merged\n")] {
        let mut fx = base();
        let base_a = fx.a.clone();
        let on_a = std::slice::from_ref(&base_a);
        let chmod = |fx: &Fx| {
            fs::set_permissions(fx.root.join("c.txt"), fs::Permissions::from_mode(0o755)).expect("chmod");
        };
        let side_x = add(&mut fx, on_a, &[("c.txt", "x\n")], "X\n");
        chmod(&fx);
        let side_y = add(&mut fx, on_a, &[("c.txt", "y\n")], "Y\n");
        chmod(&fx);
        let m = add(&mut fx, &[side_x, side_y], &[], "M\n");
        let tool = if gui_files {
            listed(&mut fx, None, &[("c.txt", "merged\n")])
        } else {
            ResolveTool::Ours
        };
        fx.repo.resolve(&options(None, &[], tool)).expect("resolve");
        let tree = commit(&fx.root, &m).tree();
        assert_eq!(content(&tree, "c.txt"), expected);
        assert!(executable(&tree, "c.txt"));
    }
}

/// A modify/delete conflict on `A`'s `a.txt`: `:theirs` takes the deleting side and removes the
/// path; `:ours` keeps the modification.
#[test]
fn a_deleting_side_removes_the_path() {
    for (tool, expected) in [(ResolveTool::Theirs, "<absent>"), (ResolveTool::Ours, "x\n")] {
        let mut fx = base();
        let base_a = fx.a.clone();
        let side_x = add(&mut fx, std::slice::from_ref(&base_a), &[("a.txt", "x\n")], "X\n");
        fx.repo
            .new_change(std::slice::from_ref(&base_a), &[], &[])
            .expect("new y");
        fs::remove_file(fx.root.join("a.txt")).expect("rm");
        let side_y = change_id(&wc(&fx.root));
        let m = add(&mut fx, &[side_x.clone(), side_y], &[], "M\n");
        let listed = list(&mut fx, None, &[]).expect("list");
        assert_eq!(listed.files[0].description, "2-sided conflict including 1 deletion");
        // The deleting side's term has no file; the base and the modifying side have one.
        assert_eq!(
            listed.files[0].term_ids,
            [
                Some(file_id(&fx, &side_x, "a.txt")),
                Some(file_id(&fx, &base_a, "a.txt")),
                None
            ]
        );
        fx.repo.resolve(&options(None, &[], tool)).expect("resolve");
        assert_eq!(content(&commit(&fx.root, &m).tree(), "a.txt"), expected);
    }
}

/// The GUI's file content resolves exactly that file; the other conflict stays, and the finish's
/// checkout lists it for `@`.
#[test]
fn files_resolve_exactly_the_listed_files() {
    let mut fx = base();
    let m = conflicted_merge(
        &mut fx,
        &[("c.txt", "c1\n"), ("d.txt", "d1\n")],
        &[("c.txt", "c2\n"), ("d.txt", "d2\n")],
    );
    let tool = listed(&mut fx, None, &[("c.txt", "merged\n")]);
    fx.repo.resolve(&options(None, &[], tool)).expect("resolve");
    let tree = commit(&fx.root, &m).tree();
    assert_eq!(content(&tree, "c.txt"), "merged\n");
    assert_eq!(content(&tree, "d.txt"), "<conflict>");
    assert_eq!(kinds(&mut fx), [WarningKind::UnresolvedConflicts]);
}

/// Files with paths, no files, a duplicate or an invalid path refuse before the snapshot.
#[test]
fn bad_files_refuse_before_the_snapshot() {
    let mut fx = base();
    two_sided(&mut fx);
    fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("dirty @");
    for (paths, tool) in [
        (&["c.txt"][..], files(&[("c.txt", "x\n")])),
        (&[][..], files(&[])),
        (&[][..], files(&[("c.txt", "x\n"), ("c.txt", "y\n")])),
        (&[][..], files(&[("/c.txt", "x\n")])),
        (&[][..], files(&[("", "x\n")])),
        (&[][..], with_ids(&[("c.txt", "x\n")], |_| Vec::new())),
    ] {
        let err = refused(&mut fx, |repo| repo.resolve(&options(None, paths, tool)));
        assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
        assert!(fx.repo.take_precondition().is_none(), "no snapshot ran");
    }
}

/// A listed file that is not a conflict refuses as stale with the CLI's text; when none is, no
/// conflicts wins.
#[test]
fn a_listed_file_that_is_no_conflict_is_stale() {
    let mut fx = base();
    two_sided(&mut fx);
    let tool = listed(&mut fx, None, &[("c.txt", "x\n"), ("a.txt", "y\n")]);
    let err = refused(&mut fx, |repo| repo.resolve(&options(None, &[], tool)));
    assert!(
        matches!(&err, MutateError::StaleSelection { reason }
            if reason == "Couldn't find any conflicts at \"a.txt\" in this revision"),
        "{err:?}"
    );
    let tool = listed(&mut fx, None, &[("c.txt", "x\n"), ("zz.txt", "y\n")]);
    let err = refused(&mut fx, |repo| repo.resolve(&options(None, &[], tool)));
    assert!(
        matches!(&err, MutateError::StaleSelection { reason }
            if reason == "Couldn't find the path \"zz.txt\" in this revision"),
        "{err:?}"
    );
    assert_eq!(kinds(&mut fx), [WarningKind::PathsUnmatched]);
    let err = refused(&mut fx, |repo| {
        repo.resolve(&options(None, &[], files(&[("a.txt", "y\n")])))
    });
    assert_eq!(no_conflicts(&err), "No conflicts found at the given path(s)");
}

/// Resolving part of a revision that is not `@`: it is rewritten, `@` rebased onto it, and the
/// remaining conflict warned.
#[test]
fn a_partial_resolve_of_another_revision_warns_the_remaining_conflicts() {
    let mut fx = base();
    let m = conflicted_merge(
        &mut fx,
        &[("a2.txt", "a1\n"), ("b2.txt", "b1\n")],
        &[("a2.txt", "a2\n"), ("b2.txt", "b2\n")],
    );
    let at = add(&mut fx, std::slice::from_ref(&m), &[("e.txt", "e\n")], "E\n");
    let tool = listed(&mut fx, Some(&m), &[("a2.txt", "a\n")]);
    let result = fx.repo.resolve(&options(Some(&m), &[], tool)).expect("resolve");
    assert_eq!(result.working_copy_change_id, Some(at.clone()));
    assert_eq!(parents(&fx.root, &at), std::slice::from_ref(&m));
    let tree = commit(&fx.root, &m).tree();
    assert_eq!(content(&tree, "a2.txt"), "a\n");
    assert_eq!(content(&commit(&fx.root, &at).tree(), "a2.txt"), "a\n");
    let warnings = fx.repo.take_warnings();
    let remain: Vec<_> = warnings
        .iter()
        .filter(|w| w.kind == WarningKind::ResolveConflictsRemain)
        .collect();
    let [warning] = remain.as_slice() else {
        panic!("one remain warning: {warnings:?}");
    };
    assert_eq!(
        warning.message,
        "After this operation, some files at this revision still have conflicts:\nb2.txt    2-sided conflict"
    );
}

/// An immutable revision refuses before anything else of the verb.
#[test]
fn an_immutable_revision_refuses() {
    let mut fx = base();
    let m = two_sided(&mut fx);
    add(&mut fx, std::slice::from_ref(&m), &[], "E\n");
    let config = immutable(&m);
    reconfigure(&mut fx, &config);
    let err = refused(&mut fx, |repo| {
        repo.resolve(&options(Some(&m), &[], ResolveTool::Theirs))
    });
    assert!(matches!(err, MutateError::Immutable { .. }), "{err:?}");
}
