// SPDX-License-Identifier: MIT

//! Story 9.14 — `Repo::simplify_parents`, one witness per row of the I/O matrix, read back
//! through jj-lib, on `rebase.rs`'s BASE: `A → B (bookmark b-mark) → C = @`. The CLI comparison
//! of the CLI tests' own graphs lives in the parity oracle.

use zanshin_jj::{ChangeId, MutateError, SimplifyParentsOptions, SimplifyParentsResult, WarningKind};

use crate::rebase::{add, assert_op, base, commit, hex, immutable, no_op, parents, reconfigure, refused, Fx};

fn revisions(ids: &[&ChangeId]) -> SimplifyParentsOptions {
    SimplifyParentsOptions {
        source: Vec::new(),
        revisions: ids.iter().map(|id| (*id).clone()).collect(),
    }
}

fn counts(result: &SimplifyParentsResult) -> (u32, u32, u32, u32) {
    (
        result.num_target_commits,
        result.num_simplified_commits,
        result.num_removed_edges,
        result.num_rebased_descendants,
    )
}

/// Runs simplify-parents and asserts it wrote no operation; returns the target count.
fn no_change(fx: &mut Fx, options: &SimplifyParentsOptions) -> u32 {
    let mut targets = None;
    no_op(fx, |repo| {
        let result = repo.simplify_parents(options)?;
        let (_, simplified, edges, rebased) = counts(&result);
        assert_eq!((simplified, edges, rebased), (0, 0, 0));
        targets = Some(result.num_target_commits);
        Ok(result.mutation)
    });
    targets.expect("ran")
}

/// `M = merge(A, B)` on the base — `@` ends on it.
fn with_redundant_merge(fx: &mut Fx) -> ChangeId {
    let merge_parents = [fx.a.clone(), fx.b.clone()];
    add(fx, &merge_parents, &[("m.txt", "m\n")], "M\n")
}

#[test]
fn simplify_parents_drops_the_redundant_parent_via_revisions_and_via_source() {
    // `-r M -r A -r B`: three targets, M keeps only B.
    let mut fx = base();
    let m = with_redundant_merge(&mut fx);
    let options = revisions(&[&m, &fx.a, &fx.b]);
    let result = fx.repo.simplify_parents(&options).expect("simplify");
    assert_op(&fx, &result.mutation, "simplify 3 commits");
    assert_eq!(parents(&fx.root, &m), [fx.b.clone()]);
    assert_eq!(counts(&result), (3, 1, 1, 0));
    assert!(result.mutation.new_change_ids.is_empty() && result.mutation.abandoned_change_ids.is_empty());
    assert_eq!(result.mutation.working_copy_change_id, Some(m));

    // `-s B`: B, C and M.
    let mut fx = base();
    let m = with_redundant_merge(&mut fx);
    let tree_before = commit(&fx.root, &m).tree_ids().clone();
    let options = SimplifyParentsOptions {
        source: vec![fx.b.clone()],
        revisions: Vec::new(),
    };
    let result = fx.repo.simplify_parents(&options).expect("simplify");
    assert_op(&fx, &result.mutation, "simplify 3 commits");
    assert_eq!(parents(&fx.root, &m), [fx.b.clone()]);
    assert_eq!(parents(&fx.root, &fx.c), [fx.b.clone()], "C is untouched");
    assert_eq!(counts(&result), (3, 1, 1, 0));
    assert_eq!(result.mutation.working_copy_change_id.as_ref(), Some(&m));
    assert_eq!(commit(&fx.root, &m).tree_ids(), &tree_before, "@'s contents stay");
}

#[test]
fn simplify_parents_leaves_a_redundant_merge_that_is_not_a_target() {
    // N = merge(M, B) — B is M's ancestor — descends from the target M but is not one: it is
    // rebased onto M' and keeps both parents.
    let mut fx = base();
    let m = with_redundant_merge(&mut fx);
    let n_parents = [m.clone(), fx.b.clone()];
    let n = add(&mut fx, &n_parents, &[("n.txt", "n\n")], "N\n");
    let result = fx.repo.simplify_parents(&revisions(&[&m])).expect("simplify");
    assert_op(&fx, &result.mutation, "simplify 1 commits");
    assert_eq!(counts(&result), (1, 1, 1, 1), "N counted as a rebased descendant");
    assert_eq!(parents(&fx.root, &m), [fx.b.clone()]);
    assert_eq!(parents(&fx.root, &n), [m, fx.b.clone()], "N stays a merge");
}

/// `M = merge(A, B) → D → E`, `F = merge(D, E)` — the CLI test's `multiple_redundant_parents`
/// graph on the base. Returns `(M, D, E, F)`.
fn two_redundant_merges(fx: &mut Fx) -> [ChangeId; 4] {
    let m = with_redundant_merge(fx);
    let d = add(fx, std::slice::from_ref(&m), &[("d.txt", "d\n")], "D\n");
    let e = add(fx, std::slice::from_ref(&d), &[("e.txt", "e\n")], "E\n");
    let f_parents = [d.clone(), e.clone()];
    let f = add(fx, &f_parents, &[("f.txt", "f\n")], "F\n");
    [m, d, e, f]
}

#[test]
fn simplify_parents_counts_simplified_commits_and_rebased_descendants() {
    let mut fx = base();
    let [m, d, e, f] = two_redundant_merges(&mut fx);
    let result = fx.repo.simplify_parents(&revisions(&[&m, &f])).expect("simplify");
    assert_op(&fx, &result.mutation, "simplify 2 commits");
    assert_eq!(counts(&result), (2, 2, 2, 2), "D and E rebased");
    assert_eq!(parents(&fx.root, &m), [fx.b.clone()]);
    assert_eq!(parents(&fx.root, &f), std::slice::from_ref(&e));
    assert_eq!(parents(&fx.root, &e), [d]);

    // The CLI test's `-s c`: M, D, E and F — "Removed 2 edges from 2 out of 4 commits. Rebased 2
    // descendant commits." (D and E are targets AND count as rebased).
    let mut fx = base();
    let [m, d, e, f] = two_redundant_merges(&mut fx);
    let source = SimplifyParentsOptions {
        source: vec![m.clone()],
        revisions: Vec::new(),
    };
    let result = fx.repo.simplify_parents(&source).expect("simplify");
    assert_op(&fx, &result.mutation, "simplify 4 commits");
    assert_eq!(counts(&result), (4, 2, 2, 2));
    assert_eq!(parents(&fx.root, &m), [fx.b.clone()]);
    assert_eq!(parents(&fx.root, &f), std::slice::from_ref(&e));
    assert_eq!(parents(&fx.root, &e), [d]);
}

#[test]
fn simplify_parents_unions_source_and_revisions() {
    // `-s D -r M`: D, E, F (D's descendants) and M.
    let mut fx = base();
    let [m, d, e, f] = two_redundant_merges(&mut fx);
    let options = SimplifyParentsOptions {
        source: vec![d.clone()],
        revisions: vec![m.clone()],
    };
    let result = fx.repo.simplify_parents(&options).expect("simplify");
    assert_op(&fx, &result.mutation, "simplify 4 commits");
    assert_eq!(counts(&result), (4, 2, 2, 2));
    assert_eq!(parents(&fx.root, &m), [fx.b.clone()]);
    assert_eq!(parents(&fx.root, &d), std::slice::from_ref(&m));
    assert_eq!(parents(&fx.root, &f), std::slice::from_ref(&e));
    assert_eq!(parents(&fx.root, &e), [d]);

    // An unknown id in both lists: the CLI parses `-s` first, so the `source` id is reported.
    let (bad_source, bad_revision) = (ChangeId("y".repeat(32)), ChangeId("x".repeat(32)));
    let err = refused(&mut fx, |repo| {
        repo.simplify_parents(&SimplifyParentsOptions {
            source: vec![bad_source.clone()],
            revisions: vec![bad_revision],
        })
        .map(|r| r.mutation)
    });
    assert!(
        matches!(&err, MutateError::ChangeNotFound { id } if *id == bad_source.0),
        "{err:?}"
    );
}

#[test]
fn simplify_parents_defaults_to_revsets_simplify_parents() {
    // jj's default `reachable(@, mutable())`: A, B, C, M, D, E and F.
    let mut fx = base();
    let [m, _, e, f] = two_redundant_merges(&mut fx);
    let result = fx
        .repo
        .simplify_parents(&SimplifyParentsOptions::default())
        .expect("simplify");
    assert_op(&fx, &result.mutation, "simplify 7 commits");
    assert_eq!(counts(&result), (7, 2, 2, 2));
    assert_eq!(parents(&fx.root, &m), [fx.b.clone()]);
    assert_eq!(parents(&fx.root, &f), [e]);

    // A custom setting narrows it to `D::`: only F is simplified.
    let mut fx = base();
    let [m, d, e, f] = two_redundant_merges(&mut fx);
    reconfigure(&mut fx, &format!("[revsets]\nsimplify-parents = \"{}::\"\n", d.0));
    let result = fx
        .repo
        .simplify_parents(&SimplifyParentsOptions::default())
        .expect("simplify");
    assert_op(&fx, &result.mutation, "simplify 3 commits");
    assert_eq!(counts(&result), (3, 1, 1, 0));
    assert_eq!(parents(&fx.root, &m), [fx.a.clone(), fx.b.clone()], "M stays a merge");
    assert_eq!(parents(&fx.root, &f), [e]);
}

#[test]
fn simplify_parents_with_nothing_to_simplify_writes_no_operation() {
    // Linear: `-s B` is B and C.
    let mut fx = base();
    let source = SimplifyParentsOptions {
        source: vec![fx.b.clone()],
        revisions: Vec::new(),
    };
    assert_eq!(no_change(&mut fx, &source), 2);

    // A diamond: `merge(B, X)` with X on A — no parent is an ancestor of the other.
    let on_a = [fx.a.clone()];
    let x = add(&mut fx, &on_a, &[("x.txt", "x\n")], "X\n");
    let merge_parents = [fx.b.clone(), x.clone()];
    let y = add(&mut fx, &merge_parents, &[("y.txt", "y\n")], "Y\n");
    let all = revisions(&[&fx.a.clone(), &fx.b.clone(), &fx.c.clone(), &x, &y]);
    assert_eq!(no_change(&mut fx, &all), 5);

    // An empty setting.
    reconfigure(&mut fx, "[revsets]\nsimplify-parents = \"none()\"\n");
    assert_eq!(no_change(&mut fx, &SimplifyParentsOptions::default()), 0);
}

#[test]
fn simplify_parents_an_immutable_target_refuses() {
    let mut fx = base();
    let zero = fx.zero.clone();
    let err = refused(&mut fx, |repo| {
        repo.simplify_parents(&revisions(&[&zero])).map(|r| r.mutation)
    });
    assert!(matches!(err, MutateError::Immutable { .. }), "{err:?}");

    let config = immutable(&fx.b);
    reconfigure(&mut fx, &config);
    let b = fx.b.clone();
    let b_hex = hex(&fx.root, &b);
    let err = refused(&mut fx, |repo| {
        repo.simplify_parents(&revisions(&[&b])).map(|r| r.mutation)
    });
    assert!(
        matches!(&err, MutateError::Immutable { commit_id, .. } if *commit_id == b_hex),
        "{err:?}"
    );
}

#[test]
fn simplify_parents_a_bad_id_or_setting_refuses() {
    let mut fx = base();
    let unknown = ChangeId("y".repeat(32));
    let err = refused(&mut fx, |repo| {
        repo.simplify_parents(&SimplifyParentsOptions {
            source: vec![unknown],
            revisions: Vec::new(),
        })
        .map(|r| r.mutation)
    });
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");

    reconfigure(&mut fx, "[revsets]\nsimplify-parents = \"(\"\n");
    let err = refused(&mut fx, |repo| {
        repo.simplify_parents(&SimplifyParentsOptions::default())
            .map(|r| r.mutation)
    });
    assert!(matches!(err, MutateError::RevsetParseError { .. }), "{err:?}");

    reconfigure(&mut fx, "[revsets]\nsimplify-parents = 1\n");
    let err = refused(&mut fx, |repo| {
        repo.simplify_parents(&SimplifyParentsOptions::default())
            .map(|r| r.mutation)
    });
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");

    // A deprecated function parses with a diagnostic: the call warns "In revset expression".
    reconfigure(
        &mut fx,
        "[revsets]\nsimplify-parents = 'none() & diff_contains(\"x\")'\n",
    );
    assert_eq!(no_change(&mut fx, &SimplifyParentsOptions::default()), 0);
    let warnings = fx.repo.take_warnings();
    assert!(
        warnings
            .iter()
            .any(|w| w.kind == WarningKind::RevsetDiagnostic && w.message.starts_with("In revset expression")),
        "{warnings:?}"
    );
}
