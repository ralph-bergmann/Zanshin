// SPDX-License-Identifier: MIT

//! Story 9.16 — `Repo::parallelize` and `Repo::arrange`, one witness per row of the I/O matrix,
//! read back through jj-lib, on `rebase.rs`'s BASE: `A → B (bookmark b-mark) → C = @`.
//! Parallelize's CLI comparison lives in the parity oracle; arrange has none (the CLI's arrange
//! is TUI-only).

use zanshin_jj::{ArrangeAction, ArrangeOptions, ChangeId, MutateError, WarningKind};

use crate::rebase::{
    add, assert_op, base, bookmark, change_id, hex, immutable, no_op, parents, reconfigure, refused, visible_all, wc,
};

// ── parallelize ──────────────────────────────────────────────────────────────────

#[test]
fn parallelize_makes_siblings_and_their_child_a_merge() {
    let mut fx = base();
    let on = [fx.c.clone()];
    let d = add(&mut fx, &on, &[("d.txt", "d\n")], "D\n");
    let result = fx.repo.parallelize(&[fx.b.clone(), fx.c.clone()]).expect("parallelize");
    assert_op(&fx, &result, "parallelize 2 commits");
    assert_eq!(parents(&fx.root, &fx.b), [fx.a.clone()]);
    assert_eq!(parents(&fx.root, &fx.c), [fx.a.clone()]);
    // D descended from both: it keeps both as parents, B (C's in-set parent) first.
    assert_eq!(parents(&fx.root, &d), [fx.b.clone(), fx.c.clone()]);
    assert!(result.abandoned_change_ids.is_empty() && result.new_change_ids.is_empty());
    assert_eq!(result.working_copy_change_id, d);
}

#[test]
fn parallelize_one_or_no_revision_writes_no_operation() {
    let mut fx = base();
    let b = fx.b.clone();
    no_op(&mut fx, |repo| repo.parallelize(std::slice::from_ref(&b)));
    no_op(&mut fx, |repo| repo.parallelize(&[]));
}

#[test]
fn parallelize_allows_an_immutable_root_but_refuses_an_immutable_commit_that_moves() {
    // A immutable: `A B` moves only B.
    let mut fx = base();
    let config = immutable(&fx.a);
    reconfigure(&mut fx, &config);
    let result = fx.repo.parallelize(&[fx.a.clone(), fx.b.clone()]).expect("parallelize");
    assert_op(&fx, &result, "parallelize 2 commits");
    assert_eq!(parents(&fx.root, &fx.b), [fx.zero.clone()]);

    // B immutable (and A with it): `A B` would move B.
    let mut fx = base();
    let config = immutable(&fx.b);
    reconfigure(&mut fx, &config);
    let (a, b) = (fx.a.clone(), fx.b.clone());
    let err = refused(&mut fx, |repo| repo.parallelize(&[a, b]));
    assert!(
        matches!(&err, MutateError::Immutable { commit_id, .. } if *commit_id == hex(&fx.root, &fx.b)),
        "{err:?}"
    );
}

#[test]
fn parallelize_an_unknown_change_refuses() {
    let mut fx = base();
    let err = refused(&mut fx, |repo| repo.parallelize(&[ChangeId("y".repeat(32))]));
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");
}

// ── arrange ──────────────────────────────────────────────────────────────────────

fn arrange(revisions: &[&ChangeId], actions: Vec<ArrangeAction>) -> ArrangeOptions {
    ArrangeOptions {
        revisions: revisions.iter().map(|id| (*id).clone()).collect(),
        actions,
    }
}

#[test]
fn arrange_swap_down_and_up_trade_places() {
    for up in [false, true] {
        let mut fx = base();
        let action = if up {
            ArrangeAction::SwapUp(fx.b.clone())
        } else {
            ArrangeAction::SwapDown(fx.c.clone())
        };
        let result = fx
            .repo
            .arrange(&arrange(&[&fx.b, &fx.c], vec![action]))
            .expect("arrange");
        assert_op(&fx, &result, "arrange revisions");
        assert_eq!(parents(&fx.root, &fx.c), [fx.a.clone()], "up: {up}");
        assert_eq!(parents(&fx.root, &fx.b), [fx.c.clone()], "up: {up}");
        assert_eq!(result.working_copy_change_id, fx.c, "@ stays on C");
        assert_eq!(
            bookmark(&fx.root, "b-mark"),
            Some(fx.b.clone()),
            "the bookmark follows B"
        );
    }
}

#[test]
fn arrange_abandon_drops_the_commit_and_its_child_follows() {
    let mut fx = base();
    let result = fx
        .repo
        .arrange(&arrange(&[&fx.b, &fx.c], vec![ArrangeAction::Abandon(fx.b.clone())]))
        .expect("arrange");
    assert_op(&fx, &result, "arrange revisions");
    assert!(visible_all(&fx.root, &fx.b).is_empty());
    assert_eq!(parents(&fx.root, &fx.c), [fx.a.clone()]);
    assert_eq!(result.abandoned_change_ids, [fx.b.clone()]);
    assert!(result.new_change_ids.is_empty());
    assert_eq!(
        bookmark(&fx.root, "b-mark"),
        Some(fx.a.clone()),
        "B's bookmark moves to its parent, as jj-lib's abandon moves it"
    );
}

#[test]
fn arrange_abandoning_at_names_its_replacement() {
    let mut fx = base();
    let result = fx
        .repo
        .arrange(&arrange(&[&fx.c], vec![ArrangeAction::Abandon(fx.c.clone())]))
        .expect("arrange");
    let at = change_id(&wc(&fx.root));
    assert_eq!(result.abandoned_change_ids, [fx.c.clone()]);
    assert_eq!(result.new_change_ids, std::slice::from_ref(&at));
    assert_eq!(parents(&fx.root, &at), [fx.b.clone()]);
}

#[test]
fn arrange_without_a_change_writes_no_operation() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    no_op(&mut fx, |repo| repo.arrange(&arrange(&[&b, &c], vec![])));
    // B's parent A is outside the set: the TUI ignores the swap.
    no_op(&mut fx, |repo| {
        repo.arrange(&arrange(&[&b, &c], vec![ArrangeAction::SwapDown(b.clone())]))
    });
    // Abandon, then keep again.
    no_op(&mut fx, |repo| {
        repo.arrange(&arrange(
            &[&a, &b],
            vec![ArrangeAction::Abandon(a.clone()), ArrangeAction::Keep(a.clone())],
        ))
    });
}

#[test]
fn arrange_a_set_with_a_gap_refuses_with_the_missing_revision() {
    let mut fx = base();
    let b12 = hex(&fx.root, &fx.b)[..12].to_owned();
    let (a, c) = (fx.a.clone(), fx.c.clone());
    let err = refused(&mut fx, |repo| repo.arrange(&arrange(&[&a, &c], vec![])));
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "Cannot arrange revset with gaps in."),
        "{err:?}"
    );
    assert_eq!(err.hints(), [format!("Revision {b12} would need to be in the set.")]);
}

#[test]
fn arrange_an_action_outside_the_set_refuses() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    let err = refused(&mut fx, |repo| {
        repo.arrange(&arrange(&[&b, &c], vec![ArrangeAction::Abandon(a.clone())]))
    });
    let expected = format!("{} is not among the revisions to arrange", a.0);
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if *reason == expected),
        "{err:?}"
    );
    let err = refused(&mut fx, |repo| {
        repo.arrange(&arrange(&[&b], vec![ArrangeAction::Keep(ChangeId("y".repeat(32)))]))
    });
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");
}

#[test]
fn arrange_an_immutable_target_refuses() {
    let mut fx = base();
    let config = immutable(&fx.b);
    reconfigure(&mut fx, &config);
    let (b, c) = (fx.b.clone(), fx.c.clone());
    let b_hex = hex(&fx.root, &fx.b);
    let err = refused(&mut fx, |repo| repo.arrange(&arrange(&[&b, &c], vec![])));
    assert!(
        matches!(&err, MutateError::Immutable { commit_id, .. } if *commit_id == b_hex),
        "{err:?}"
    );
}

#[test]
fn arrange_defaults_to_revsets_arrange() {
    // jj's default `reachable(@, mutable())` is A, B and C: abandoning A moves B onto the root.
    let mut fx = base();
    let a = fx.a.clone();
    let result = fx
        .repo
        .arrange(&ArrangeOptions {
            revisions: vec![],
            actions: vec![ArrangeAction::Abandon(a.clone())],
        })
        .expect("arrange");
    assert_eq!(result.abandoned_change_ids, [a]);
    assert_eq!(parents(&fx.root, &fx.b), [fx.zero.clone()]);

    // A config override narrows it: `@` alone, so A is not a target any more.
    let mut fx = base();
    reconfigure(&mut fx, "[revsets]\narrange = \"@\"\n");
    let a = fx.a.clone();
    let err = refused(&mut fx, |repo| {
        repo.arrange(&ArrangeOptions {
            revisions: vec![],
            actions: vec![ArrangeAction::Abandon(a.clone())],
        })
    });
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");

    // An empty set: "No revisions to arrange."
    let mut fx = base();
    reconfigure(&mut fx, "[revsets]\narrange = \"none()\"\n");
    no_op(&mut fx, |repo| repo.arrange(&ArrangeOptions::default()));
}

#[test]
fn arrange_a_bad_revsets_arrange_refuses_and_its_diagnostics_warn() {
    let mut fx = base();
    reconfigure(&mut fx, "[revsets]\narrange = \"(\"\n");
    let err = refused(&mut fx, |repo| repo.arrange(&ArrangeOptions::default()));
    assert!(matches!(err, MutateError::RevsetParseError { .. }), "{err:?}");

    let mut fx = base();
    reconfigure(&mut fx, "[revsets]\narrange = 1\n");
    let err = refused(&mut fx, |repo| repo.arrange(&ArrangeOptions::default()));
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");

    // A deprecated function parses with a diagnostic: the call warns "In revset expression".
    let mut fx = base();
    reconfigure(&mut fx, "[revsets]\narrange = 'none() & diff_contains(\"x\")'\n");
    let before = crate::rebase::head_op(&fx.root);
    let result = fx.repo.arrange(&ArrangeOptions::default()).expect("arrange");
    assert_eq!(result.new_op_id.0, before.0, "an empty set");
    let warnings = fx.repo.take_warnings();
    assert!(
        warnings
            .iter()
            .any(|w| w.kind == WarningKind::RevsetDiagnostic && w.message.starts_with("In revset expression")),
        "{warnings:?}"
    );
}
