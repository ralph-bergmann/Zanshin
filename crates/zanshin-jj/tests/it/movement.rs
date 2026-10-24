// SPDX-License-Identifier: MIT

//! Story 9.10 — `Repo::move_working_copy` (`jj next` / `jj prev`) and `Repo::movement_targets`,
//! one witness per row of the I/O matrix, read back through jj-lib.
//!
//! The history is `rebase.rs`'s: `A (a.txt) → B (b.txt, bookmark b-mark) → C (c.txt) = @`. The
//! CLI comparison of the same rows lives in the parity oracle (`crates/zanshin-parity`).

use std::fs;

use jj_lib::ref_name::WorkspaceName;
use zanshin_jj::{ChangeId, CommitId, Direction, MovementOptions, MovementTargets, MutateError, Repo};

use crate::rebase::{
    add, assert_op, base, change_id, head_op, hex, immutable, load, no_op, parents, reconfigure, refused, wc, Fx,
};

fn next() -> MovementOptions {
    MovementOptions::default()
}

fn prev() -> MovementOptions {
    MovementOptions {
        direction: Direction::Prev,
        ..MovementOptions::default()
    }
}

fn edit(options: MovementOptions) -> MovementOptions {
    MovementOptions { edit: true, ..options }
}

fn offset(options: MovementOptions, offset: u64) -> MovementOptions {
    MovementOptions {
        offset: Some(offset),
        ..options
    }
}

fn conflict(options: MovementOptions) -> MovementOptions {
    MovementOptions {
        conflict: true,
        ..options
    }
}

fn short(root: &std::path::Path, id: &ChangeId) -> String {
    hex(root, id)[..12].to_owned()
}

/// The `InvalidInput` refusal's reason and hints.
fn invalid(err: &MutateError) -> (String, Vec<String>) {
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    (err.to_string().replacen("invalid input: ", "", 1), err.hints())
}

/// A sibling `X` (x.txt) of B on A; `@` ends on X.
fn with_sibling(fx: &mut Fx) -> ChangeId {
    let a = fx.a.clone();
    add(fx, &[a], &[("x.txt", "x\n")], "X")
}

/// An empty `@` on `parent`.
fn new_on(fx: &mut Fx, parent: &ChangeId) -> ChangeId {
    fx.repo.new_change(std::slice::from_ref(parent), &[], &[]).expect("new");
    change_id(&wc(&fx.root))
}

#[test]
fn next_creates_a_new_working_copy_on_the_child() {
    let mut fx = base();
    let b = fx.b.clone();
    let at = new_on(&mut fx, &b);
    let at_short = short(&fx.root, &at);
    let result = fx.repo.move_working_copy(&next()).expect("next");
    assert_op(&fx, &result, &format!("next: {at_short} -> {}", short(&fx.root, &fx.c)));
    assert_eq!(parents(&fx.root, &change_id(&wc(&fx.root))), [fx.c.clone()]);
    assert_eq!(result.working_copy_change_id, Some(change_id(&wc(&fx.root))));
}

#[test]
fn next_edit_edits_the_child() {
    let mut fx = base();
    fx.repo.edit(fx.b.clone()).expect("edit B");
    let result = fx.repo.move_working_copy(&edit(next())).expect("next --edit");
    assert_op(
        &fx,
        &result,
        &format!("next: {} -> editing {}", short(&fx.root, &fx.b), short(&fx.root, &fx.c)),
    );
    assert_eq!(change_id(&wc(&fx.root)), fx.c);
}

#[test]
fn next_two_moves_two_generations() {
    let mut fx = base();
    let a = fx.a.clone();
    new_on(&mut fx, &a);
    fx.repo.move_working_copy(&offset(next(), 2)).expect("next 2");
    assert_eq!(parents(&fx.root, &change_id(&wc(&fx.root))), [fx.c.clone()]);

    fx.repo.edit(fx.a.clone()).expect("edit A");
    fx.repo
        .move_working_copy(&edit(offset(next(), 2)))
        .expect("next --edit 2");
    assert_eq!(change_id(&wc(&fx.root)), fx.c);
}

#[test]
fn prev_creates_a_new_working_copy_on_the_parent() {
    let mut fx = base();
    let result = fx.repo.move_working_copy(&prev()).expect("prev");
    assert_op(
        &fx,
        &result,
        &format!("prev: {} -> {}", short(&fx.root, &fx.c), short(&fx.root, &fx.a)),
    );
    // Non-edit `prev` counts from `@`'s parents: one back from B is A.
    assert_eq!(parents(&fx.root, &change_id(&wc(&fx.root))), [fx.a.clone()]);
}

#[test]
fn prev_edit_and_prev_two() {
    let mut fx = base();
    let result = fx.repo.move_working_copy(&edit(prev())).expect("prev --edit");
    assert_op(
        &fx,
        &result,
        &format!("prev: {} -> editing {}", short(&fx.root, &fx.c), short(&fx.root, &fx.b)),
    );
    assert_eq!(change_id(&wc(&fx.root)), fx.b);

    let mut fx = base();
    fx.repo.move_working_copy(&offset(prev(), 2)).expect("prev 2");
    assert_eq!(parents(&fx.root, &change_id(&wc(&fx.root))), [fx.zero.clone()]);
}

#[test]
fn prev_offset_zero_edit_changes_nothing() {
    let mut fx = base();
    no_op(&mut fx, |repo| repo.move_working_copy(&edit(offset(prev(), 0))));
}

/// The release CLI's `offset - 1` wraps to `u64::MAX`, a generation jj-lib refuses to evaluate:
/// the CLI's user error with jj-lib's text. Any offset beyond `u32::MAX` is refused alike.
#[test]
fn an_offset_beyond_the_index_range_is_refused_with_jj_libs_text() {
    let mut fx = base();
    let err = refused(&mut fx, |repo| repo.move_working_copy(&offset(next(), 0)));
    assert_eq!(
        invalid(&err),
        (
            format!("Lower bound of generation ({}) is too large", u64::MAX),
            Vec::new()
        )
    );
    let err = refused(&mut fx, |repo| {
        repo.move_working_copy(&edit(offset(prev(), 5_000_000_000)))
    });
    assert_eq!(invalid(&err).0, "Lower bound of generation (5000000000) is too large");
}

/// `A → X (a.txt = x)`, `A → Y (a.txt = y)`, `M = X + Y` (conflicted), `N` (n.txt), `O` (o.txt),
/// then an empty `@` on O. Returns M, N.
fn conflicted_stack(fx: &mut Fx) -> (ChangeId, ChangeId) {
    let base = fx.a.clone();
    let side_x = add(fx, std::slice::from_ref(&base), &[("a.txt", "x\n")], "X");
    let side_y = add(fx, &[base], &[("a.txt", "y\n")], "Y");
    let merge = add(fx, &[side_x, side_y], &[], "M");
    let child = add(fx, std::slice::from_ref(&merge), &[("n.txt", "n\n")], "N");
    let grandchild = add(fx, std::slice::from_ref(&child), &[("o.txt", "o\n")], "O");
    new_on(fx, &grandchild);
    (merge, child)
}

#[test]
fn conflict_moves_to_the_nearest_conflicted_commit() {
    let mut fx = base();
    let (m, n) = conflicted_stack(&mut fx);
    fx.repo.move_working_copy(&conflict(prev())).expect("prev --conflict");
    assert_eq!(
        parents(&fx.root, &change_id(&wc(&fx.root))),
        [n],
        "heads: the nearest ancestor"
    );

    fx.repo.edit(fx.a.clone()).expect("edit A");
    fx.repo
        .move_working_copy(&edit(conflict(next())))
        .expect("next --edit --conflict");
    assert_eq!(change_id(&wc(&fx.root)), m, "roots: the nearest descendant");
}

#[test]
fn conflict_without_a_conflicted_commit_is_refused_with_its_text() {
    let mut fx = base();
    let err = refused(&mut fx, |repo| repo.move_working_copy(&conflict(prev())));
    let (reason, hints) = invalid(&err);
    assert_eq!(reason, "The working copy parent(s) have no ancestors with conflicts");
    assert_eq!(hints.len(), 1);
    assert!(
        hints[0].starts_with("Working copy parent: ") && hints[0].ends_with(" b-mark | B"),
        "{hints:?}"
    );

    let err = refused(&mut fx, |repo| repo.move_working_copy(&edit(conflict(next()))));
    let (reason, hints) = invalid(&err);
    assert_eq!(reason, "The working copy has no descendants with conflicts");
    assert!(
        hints[0].starts_with("Working copy: ") && hints[0].ends_with(" C"),
        "{hints:?}"
    );
}

#[test]
fn ui_movement_edit_selects_the_edit_form_and_no_edit_restores_it() {
    let mut fx = base();
    reconfigure(&mut fx, "[ui.movement]\nedit = true\n");
    let plan = fx.repo.movement_targets(&prev()).expect("targets");
    assert!(plan.edit);
    fx.repo.move_working_copy(&prev()).expect("prev, edit by config");
    assert_eq!(change_id(&wc(&fx.root)), fx.b);

    let no_edit = MovementOptions {
        no_edit: true,
        ..prev()
    };
    fx.repo.edit(fx.c.clone()).expect("edit C");
    assert!(!fx.repo.movement_targets(&no_edit).expect("targets").edit);
    fx.repo.move_working_copy(&no_edit).expect("prev --no-edit");
    assert_eq!(parents(&fx.root, &change_id(&wc(&fx.root))), [fx.a.clone()]);
}

#[test]
fn a_non_bool_ui_movement_edit_is_a_config_error_naming_the_key() {
    let mut fx = base();
    reconfigure(&mut fx, "[ui.movement]\nedit = \"yes\"\n");
    let err = refused(&mut fx, |repo| repo.move_working_copy(&prev()));
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.contains("ui.movement.edit")),
        "{err:?}"
    );
    // The CLI reads the key before it looks at `--edit`, so `--edit` is refused too.
    let err = refused(&mut fx, |repo| repo.move_working_copy(&edit(prev())));
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");
}

#[test]
fn a_working_copy_with_children_is_refused_without_edit() {
    let mut fx = base();
    fx.repo.edit(fx.b.clone()).expect("edit B");
    let err = refused(&mut fx, |repo| repo.move_working_copy(&next()));
    assert_eq!(
        invalid(&err),
        (
            "The working copy must not have any children".to_owned(),
            vec!["Create a new commit on top of this one or use `--edit`".to_owned()]
        )
    );
}

#[test]
fn nothing_there_is_refused_with_one_hint_per_start_commit() {
    let mut fx = base();
    let err = refused(&mut fx, |repo| repo.move_working_copy(&next()));
    let (reason, hints) = invalid(&err);
    assert_eq!(
        reason,
        "No other descendant found 1 commit(s) forward from the working copy parent(s)"
    );
    assert_eq!(hints.len(), 1);
    assert!(hints[0].starts_with("Working copy parent: "), "{hints:?}");

    let err = refused(&mut fx, |repo| repo.move_working_copy(&offset(prev(), 5)));
    assert_eq!(
        invalid(&err).0,
        "No ancestor found 5 commit(s) back from the working copy parents(s)"
    );
    let err = refused(&mut fx, |repo| repo.move_working_copy(&edit(next())));
    assert_eq!(
        invalid(&err).0,
        "No descendant found 1 commit(s) forward from the working copy"
    );
    let err = refused(&mut fx, |repo| repo.move_working_copy(&edit(offset(prev(), 5))));
    assert_eq!(
        invalid(&err).0,
        "No ancestor found 5 commit(s) back from the working copy"
    );

    // A merge `@` has two start commits, so two hints.
    let a = fx.a.clone();
    let x = add(&mut fx, &[a], &[("x.txt", "x\n")], "X");
    fx.repo.new_change(&[fx.c.clone(), x], &[], &[]).expect("merge @");
    let err = refused(&mut fx, |repo| repo.move_working_copy(&next()));
    assert_eq!(invalid(&err).1.len(), 2);
}

#[test]
fn editing_an_immutable_target_is_refused() {
    let mut fx = base();
    let err = refused(&mut fx, |repo| repo.move_working_copy(&edit(offset(prev(), 3))));
    assert!(matches!(err, MutateError::Immutable { .. }), "{err:?}");

    let b_immutable = immutable(&fx.b);
    reconfigure(&mut fx, &b_immutable);
    let err = refused(&mut fx, |repo| repo.move_working_copy(&edit(prev())));
    let b_hex = hex(&fx.root, &fx.b);
    assert!(
        matches!(&err, MutateError::Immutable { commit_id, hints } if *commit_id == b_hex && !hints.is_empty()),
        "{err:?}"
    );
}

#[test]
fn ambiguous_targets_are_listed_in_cli_order_and_refused_without_a_choice() {
    let mut fx = base();
    let x = with_sibling(&mut fx);
    let a = fx.a.clone();
    new_on(&mut fx, &a);
    let before = head_op(&fx.root);
    let MovementTargets { edit, targets } = fx.repo.movement_targets(&next()).expect("targets");
    assert_eq!(
        head_op(&fx.root),
        before,
        "the targets call writes no operation on a clean wc"
    );
    assert!(!edit);
    // The revset's order: newest first, as the CLI's prompt lists them.
    let listed: Vec<ChangeId> = targets.iter().map(|target| target.change_id.clone()).collect();
    assert_eq!(listed, [x.clone(), fx.b.clone()]);
    assert_eq!(targets[1].commit_id, CommitId(hex(&fx.root, &fx.b)));

    let err = refused(&mut fx, |repo| repo.move_working_copy(&next()));
    assert_eq!(
        invalid(&err),
        ("ambiguous next commit, choose one to target".to_owned(), Vec::new())
    );

    let chosen = MovementOptions {
        target: Some(targets[1].commit_id.clone()),
        ..next()
    };
    fx.repo.move_working_copy(&chosen).expect("the chosen candidate");
    assert_eq!(parents(&fx.root, &change_id(&wc(&fx.root))), [fx.b.clone()]);
}

#[test]
fn a_target_that_is_not_a_candidate_is_stale() {
    let mut fx = base();
    with_sibling(&mut fx);
    let a = fx.a.clone();
    new_on(&mut fx, &a);
    let c = CommitId(hex(&fx.root, &fx.c));
    let options = MovementOptions {
        target: Some(c.clone()),
        ..next()
    };
    let err = refused(&mut fx, |repo| repo.move_working_copy(&options));
    assert!(matches!(err, MutateError::StaleSelection { .. }), "{err:?}");
    assert_eq!(
        err.to_string(),
        format!("stale selection: {} is not a next target", c.0)
    );
    // The targets call ignores the choice.
    assert_eq!(fx.repo.movement_targets(&options).expect("targets").targets.len(), 2);
}

#[test]
fn a_target_is_also_checked_with_a_single_candidate() {
    let mut fx = base();
    // Without `edit` the one candidate is A (`prev` counts from `@`'s parents), so B is stale.
    let options = MovementOptions {
        target: Some(CommitId(hex(&fx.root, &fx.b))),
        ..prev()
    };
    let err = refused(&mut fx, |repo| repo.move_working_copy(&options));
    assert!(matches!(err, MutateError::StaleSelection { .. }), "{err:?}");
    let options = MovementOptions {
        target: Some(CommitId(hex(&fx.root, &fx.b))),
        ..edit(prev())
    };
    fx.repo.move_working_copy(&options).expect("the one candidate, chosen");
    assert_eq!(change_id(&wc(&fx.root)), fx.b);
}

#[test]
fn clap_refusals_on_a_dirty_working_copy_snapshot_nothing() {
    let mut fx = base();
    fs::write(fx.root.join("c.txt"), "c, edited before a clap refusal\n").expect("dirty c.txt");
    let cases = [
        (
            MovementOptions {
                no_edit: true,
                ..edit(next())
            },
            "the argument '--edit' cannot be used with '--no-edit'",
        ),
        (
            conflict(offset(prev(), 1)),
            "the argument '--conflict' cannot be used with '[OFFSET]'",
        ),
    ];
    for (options, expected) in cases {
        let before = head_op(&fx.root);
        let err = fx.repo.move_working_copy(&options).expect_err("refused");
        assert_eq!(invalid(&err).0, expected);
        let err = fx.repo.movement_targets(&options).expect_err("refused");
        assert_eq!(invalid(&err).0, expected);
        assert_eq!(head_op(&fx.root), before, "no snapshot, no operation");
        assert!(fx.repo.take_precondition().is_none(), "no precondition ran");
        assert_eq!(fx.repo.take_warnings(), [], "no warnings");
    }
    // `conflict` with the default offset passes clap: the call snapshots the edit, then refuses.
    let before = head_op(&fx.root);
    let err = fx.repo.move_working_copy(&conflict(prev())).expect_err("no conflicts");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    assert_ne!(head_op(&fx.root), before, "the snapshot's operation");
}

#[test]
fn a_workspace_without_at_is_refused() {
    let mut fx = base();
    {
        let repo = load(&fx.root);
        let mut tx = repo.start_transaction();
        pollster::block_on(tx.repo_mut().remove_workspace(WorkspaceName::DEFAULT)).expect("remove @");
        pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
        pollster::block_on(tx.commit("test: remove working-copy commit")).expect("commit");
    }
    fx.repo = Repo::open(&fx.root).expect("open");
    for options in [prev(), edit(next())] {
        let err = refused(&mut fx, |repo| repo.move_working_copy(&options));
        assert!(matches!(err, MutateError::NoWorkingCopy), "{err:?}");
        let err = fx.repo.movement_targets(&options).expect_err("refused");
        assert!(matches!(err, MutateError::NoWorkingCopy), "{err:?}");
    }
}
