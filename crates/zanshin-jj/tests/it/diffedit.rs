// SPDX-License-Identifier: MIT

//! Story 9.17 — `Repo::diffedit` with a `select_tree` tree (and `select_tree`'s `from`), one
//! witness per row of the I/O matrix, read back through jj-lib.
//!
//! On `rebase.rs`' base (`A → B → C`): `L` writes `f.txt` = the left text, `M` adds `g.txt`, `R`
//! (= `@`) writes the right text — three changed sections. The CLI comparison (`jj diffedit
//! --tool` making the same choice) lives in the parity oracle (`crates/zanshin-parity`).

use std::fs;

use jj_lib::object_id::ObjectId;
use zanshin_jj::{
    ChangeId, DiffeditOptions, FileChoice, FileSelection, HunkKey, MutateError, SelectTreeOptions, TreeSelection,
};

use crate::rebase::{add, assert_op, base, commit, head_op, hex, immutable, no_op, parents, reconfigure, refused, Fx};
use crate::resolve::content;

const LEFT: &str = "a\nb\nc\nd\ne\n";
const RIGHT: &str = "A\nb\nC\nd\nE\n";
const ONE_AND_THREE: &str = "A\nb\nc\nd\nE\n";
const S1: HunkKey = HunkKey {
    old_start: 0,
    old_count: 1,
    new_start: 0,
    new_count: 1,
};
const S2: HunkKey = HunkKey {
    old_start: 2,
    old_count: 1,
    new_start: 2,
    new_count: 1,
};
const S3: HunkKey = HunkKey {
    old_start: 4,
    old_count: 1,
    new_start: 4,
    new_count: 1,
};

/// `L` (`f.txt` left) → `M` (`g.txt`) → `R` (`f.txt` right) = `@`; returns `(L, R)`.
fn history(fx: &mut Fx) -> (ChangeId, ChangeId) {
    let c = fx.c.clone();
    let l = add(fx, std::slice::from_ref(&c), &[("f.txt", LEFT)], "L\n");
    let m = add(fx, std::slice::from_ref(&l), &[("g.txt", "g\n")], "M\n");
    let r = add(fx, std::slice::from_ref(&m), &[("f.txt", RIGHT)], "R\n");
    (l, r)
}

fn hunks(path: &str, keys: &[HunkKey]) -> FileSelection {
    FileSelection {
        path: path.to_owned(),
        choice: FileChoice::Hunks(keys.to_vec()),
    }
}

/// `revision`'s `parent_tree_ids` and `tree_ids` as `show` reports them.
fn shown(fx: &mut Fx, revision: &ChangeId) -> (Vec<String>, Vec<String>) {
    let entries = fx.repo.show(Some(&revision.0), None).expect("show");
    (entries[0].parent_tree_ids.clone(), entries[0].tree_ids.clone())
}

/// `select_tree` of `files` in `revision`, against `from`'s own tree or the parent tree — and
/// `revision`'s own tree ids, `diffedit`'s `right` for that target.
fn select(
    fx: &mut Fx,
    revision: &ChangeId,
    from: Option<&ChangeId>,
    files: Vec<FileSelection>,
) -> (TreeSelection, Vec<String>) {
    let (parent_tree, right) = shown(fx, revision);
    let left = match from {
        Some(from) => shown(fx, from).1,
        None => parent_tree,
    };
    let tree = fx
        .repo
        .select_tree(&SelectTreeOptions {
            revision: Some(revision.clone()),
            from: from.cloned(),
            left: left.clone(),
            files,
        })
        .expect("select");
    (TreeSelection { tree, left }, right)
}

fn f_of(fx: &Fx, id: &ChangeId) -> String {
    content(&commit(&fx.root, id).tree(), "f.txt")
}

/// `show`'s `tree_ids` are the revision's own tree.
#[test]
fn show_reports_the_revisions_own_tree_ids() {
    let mut fx = base();
    let (l, r) = history(&mut fx);
    let own: Vec<String> = commit(&fx.root, &l).tree_ids().iter().map(ObjectId::hex).collect();
    assert_eq!(shown(&mut fx, &l).1, own);
    let (parent, own) = shown(&mut fx, &r);
    assert_ne!(parent, own);
}

/// `diffedit -r @` with sections 1 and 3: `@` gets that tree; the operation is the CLI's.
#[test]
fn diffedit_takes_the_selected_tree_of_the_revision() {
    let mut fx = base();
    let (_, r) = history(&mut fx);
    let r_hex = hex(&fx.root, &r);
    let (tree, right) = select(&mut fx, &r, None, vec![hunks("f.txt", &[S1, S3])]);
    let result = fx
        .repo
        .diffedit(&DiffeditOptions {
            tree,
            right,
            ..Default::default()
        })
        .expect("diffedit");
    assert_op(&fx, &result, &format!("edit commit {r_hex}"));
    assert_eq!(f_of(&fx, &r), ONE_AND_THREE);
    assert_eq!(content(&commit(&fx.root, &r).tree(), "g.txt"), "g\n");
    assert_eq!(result.working_copy_change_id, Some(r));
}

/// `--from L --to R`: the base is `L`'s own tree; a descendant is rebased, or keeps its content
/// with `restore_descendants`.
#[test]
fn diffedit_from_to_rebases_or_reparents_the_descendants() {
    for restore_descendants in [false, true] {
        let mut fx = base();
        let (l, r) = history(&mut fx);
        let d = add(&mut fx, std::slice::from_ref(&r), &[("h.txt", "h\n")], "D\n");
        let files = vec![
            hunks("f.txt", &[S1, S3]),
            FileSelection {
                path: "g.txt".to_owned(),
                choice: FileChoice::Whole,
            },
        ];
        let (tree, right) = select(&mut fx, &r, Some(&l), files);
        fx.repo
            .diffedit(&DiffeditOptions {
                from: Some(l.clone()),
                to: Some(r.clone()),
                tree,
                right,
                restore_descendants,
                ..Default::default()
            })
            .expect("diffedit");
        assert_eq!(f_of(&fx, &r), ONE_AND_THREE);
        let expected = if restore_descendants { RIGHT } else { ONE_AND_THREE };
        assert_eq!(f_of(&fx, &d), expected);
    }
}

/// With `from`, an unselected path takes `from`'s value — here `g.txt`, absent in `L`.
#[test]
fn select_tree_from_resets_unselected_paths_to_froms_tree() {
    let mut fx = base();
    let (l, r) = history(&mut fx);
    let (selection, right) = select(&mut fx, &r, Some(&l), vec![hunks("f.txt", &[S1])]);
    fx.repo
        .diffedit(&DiffeditOptions {
            from: Some(l),
            to: Some(r.clone()),
            tree: selection,
            right,
            ..Default::default()
        })
        .expect("diffedit");
    let tree = commit(&fx.root, &r).tree();
    assert_eq!(content(&tree, "g.txt"), "<absent>");
    assert_eq!(content(&tree, "f.txt"), "A\nb\nc\nd\ne\n");
}

/// `from` alone: the target is `@`, diffed against `from`'s own tree.
#[test]
fn from_alone_edits_at_against_froms_tree() {
    let mut fx = base();
    let (l, r) = history(&mut fx);
    let files = vec![
        hunks("f.txt", &[S1, S3]),
        FileSelection {
            path: "g.txt".to_owned(),
            choice: FileChoice::Whole,
        },
    ];
    let (tree, right) = select(&mut fx, &r, Some(&l), files);
    let result = fx
        .repo
        .diffedit(&DiffeditOptions {
            from: Some(l),
            tree,
            right,
            ..Default::default()
        })
        .expect("diffedit");
    assert_eq!(result.working_copy_change_id, Some(r.clone()));
    assert_eq!(f_of(&fx, &r), ONE_AND_THREE);
    assert_eq!(content(&commit(&fx.root, &r).tree(), "g.txt"), "g\n");
}

/// `to` alone: the target is `to`, diffed against `@`'s own tree — `select_tree` gets `from` =
/// `@`'s change id.
#[test]
fn to_alone_edits_to_against_ats_tree() {
    let mut fx = base();
    let (_, r) = history(&mut fx);
    let [m] = <[ChangeId; 1]>::try_from(parents(&fx.root, &r)).expect("one parent");
    // `M`'s `f.txt` is the left text, `@`'s the right one: section 1 takes `M`'s side there.
    let (tree, right) = select(&mut fx, &m, Some(&r), vec![hunks("f.txt", &[S1])]);
    fx.repo
        .diffedit(&DiffeditOptions {
            to: Some(m.clone()),
            tree,
            right,
            ..Default::default()
        })
        .expect("diffedit");
    assert_eq!(f_of(&fx, &m), "a\nb\nC\nd\nE\n");
    assert_eq!(f_of(&fx, &r), RIGHT, "@ is rebased and keeps its own change");
}

/// A tree equal to the target's writes no operation.
#[test]
fn an_unchanged_tree_writes_no_operation() {
    let mut fx = base();
    let (_, r) = history(&mut fx);
    let (tree, right) = select(&mut fx, &r, None, vec![hunks("f.txt", &[S1, S2, S3])]);
    no_op(&mut fx, |repo| {
        repo.diffedit(&DiffeditOptions {
            revision: Some(r.clone()),
            tree,
            right,
            ..Default::default()
        })
    });
}

/// `@` edited on disk after `select_tree`: the snapshot folds the edit in, so the target's tree
/// is no longer `right` — refused stale, no operation beyond the snapshot's, the edit kept.
#[test]
fn a_target_edited_after_the_selection_is_stale_and_keeps_the_edit() {
    let mut fx = base();
    let (_, r) = history(&mut fx);
    let (tree, right) = select(&mut fx, &r, None, vec![hunks("f.txt", &[S1, S3])]);
    fs::write(fx.root.join("g.txt"), "edited\n").expect("edit @ on disk");
    let err = fx
        .repo
        .diffedit(&DiffeditOptions {
            tree,
            right,
            ..Default::default()
        })
        .expect_err("stale");
    assert!(
        matches!(&err, MutateError::StaleSelection { reason }
            if reason == "The target's tree changed since the selection was made: re-read it and select again"),
        "{err:?}"
    );
    assert_eq!(
        head_op(&fx.root).1,
        "snapshot working copy",
        "only the snapshot's operation"
    );
    assert_eq!(f_of(&fx, &r), RIGHT);
    assert_eq!(content(&commit(&fx.root, &r).tree(), "g.txt"), "edited\n");
}

/// An empty or malformed `right` refuses before the snapshot.
#[test]
fn a_missing_or_malformed_right_refuses_before_the_snapshot() {
    let mut fx = base();
    let (_, r) = history(&mut fx);
    let (tree, _) = select(&mut fx, &r, None, vec![hunks("f.txt", &[S1])]);
    fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("dirty @");
    for right in [
        Vec::new(),
        vec!["zz".to_owned()],
        vec!["00".to_owned(), "00".to_owned()],
    ] {
        let err = refused(&mut fx, |repo| {
            repo.diffedit(&DiffeditOptions {
                tree: tree.clone(),
                right,
                ..Default::default()
            })
        });
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("right")),
            "{err:?}"
        );
        assert!(fx.repo.take_precondition().is_none(), "no snapshot ran");
    }
}

/// A `left` that is not the base tree is stale — after the immutable check; `revision` with
/// `from` refuses before the snapshot.
#[test]
fn stale_left_immutable_target_and_bad_arguments_refuse() {
    let mut fx = base();
    let (l, r) = history(&mut fx);
    let (parent_selection, right) = select(&mut fx, &r, None, vec![hunks("f.txt", &[S1])]);
    let err = refused(&mut fx, |repo| {
        repo.diffedit(&DiffeditOptions {
            from: Some(l.clone()),
            to: Some(r.clone()),
            tree: parent_selection.clone(),
            right: right.clone(),
            ..Default::default()
        })
    });
    assert!(matches!(err, MutateError::StaleSelection { .. }), "{err:?}");
    let err = fx
        .repo
        .select_tree(&SelectTreeOptions {
            revision: Some(r.clone()),
            from: Some(l.clone()),
            left: parent_selection.left.clone(),
            files: Vec::new(),
        })
        .expect_err("stale");
    assert!(matches!(err, MutateError::StaleSelection { .. }), "{err:?}");

    fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("dirty @");
    let err = refused(&mut fx, |repo| {
        repo.diffedit(&DiffeditOptions {
            revision: Some(r.clone()),
            from: Some(l.clone()),
            tree: parent_selection.clone(),
            right: right.clone(),
            ..Default::default()
        })
    });
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    assert!(fx.repo.take_precondition().is_none(), "no snapshot ran");

    let c = fx.c.clone();
    add(&mut fx, std::slice::from_ref(&r), &[], "E\n");
    let config = immutable(&r);
    reconfigure(&mut fx, &config);
    let err = refused(&mut fx, |repo| {
        repo.diffedit(&DiffeditOptions {
            from: Some(c),
            to: Some(r.clone()),
            tree: parent_selection,
            right,
            ..Default::default()
        })
    });
    assert!(matches!(err, MutateError::Immutable { .. }), "{err:?}");
}
