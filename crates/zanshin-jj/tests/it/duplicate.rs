// SPDX-License-Identifier: MIT

//! Story 9.9 — `Repo::duplicate`, one witness per row of the I/O matrix, read back through
//! jj-lib, and the agreement of `drop_actions`' `duplicate` row with the verb.
//!
//! The history is `rebase.rs`'s: `A (a.txt) → B (b.txt, bookmark b-mark) → C (c.txt) = @`. The
//! CLI comparison of the same rows lives in the parity oracle (`crates/zanshin-parity`).

use zanshin_jj::{
    ActionStatus, ChangeId, DropLocation, DropSource, DropVerb, DuplicateOptions, MutateError, WarningKind,
};

use crate::rebase::{assert_op, base, commit, head_op, parents, reconfigure, refused, Fx};
use crate::revert::{assert_config_class, UNRESOLVABLE_ALIAS};

/// Duplicates with `options`, asserts the CLI's operation, and returns the duplicates' change ids.
fn duplicate(fx: &mut Fx, options: impl FnOnce(&Fx) -> DuplicateOptions, count: usize) -> Vec<ChangeId> {
    let options = options(fx);
    let result = fx.repo.duplicate(&options).expect("duplicate");
    assert_op(fx, &result, &format!("duplicate {count} commit(s)"));
    assert_eq!(result.new_change_ids.len(), count);
    assert!(result.abandoned_change_ids.is_empty());
    result.new_change_ids
}

fn one(fx: &mut Fx, options: impl FnOnce(&Fx) -> DuplicateOptions) -> ChangeId {
    let [id] = <[ChangeId; 1]>::try_from(duplicate(fx, options, 1)).expect("one duplicate");
    id
}

fn kinds(fx: &mut Fx) -> Vec<WarningKind> {
    fx.repo.take_warnings().iter().map(|w| w.kind).collect()
}

#[test]
fn a_revision_is_duplicated_onto_its_parents() {
    let mut fx = base();
    let b2 = one(&mut fx, |fx| DuplicateOptions {
        revisions: vec![fx.b.clone()],
        ..DuplicateOptions::default()
    });
    assert_ne!(b2, fx.b);
    assert_eq!(parents(&fx.root, &b2), [fx.a.clone()]);
    let (copy, original) = (commit(&fx.root, &b2), commit(&fx.root, &fx.b));
    assert_eq!(copy.description(), "B\n");
    assert_eq!(copy.tree_ids(), original.tree_ids());
    assert_eq!(parents(&fx.root, &fx.c), [fx.b.clone()], "the original stays");
    assert_eq!(kinds(&mut fx), []);
}

#[test]
fn no_revision_is_the_working_copy_commit() {
    let mut fx = base();
    let c2 = one(&mut fx, |_| DuplicateOptions::default());
    assert_eq!(parents(&fx.root, &c2), [fx.b.clone()]);
    assert_eq!(commit(&fx.root, &c2).description(), "C\n");
}

#[test]
fn several_revisions_are_duplicated_onto_each_others_duplicates() {
    let mut fx = base();
    let ids = duplicate(
        &mut fx,
        |fx| DuplicateOptions {
            revisions: vec![fx.b.clone(), fx.c.clone()],
            ..DuplicateOptions::default()
        },
        2,
    );
    let by_description = |fx: &Fx, d: &str| ids.iter().find(|id| commit(&fx.root, id).description() == d).cloned();
    let (b2, c2) = (
        by_description(&fx, "B\n").expect("B'"),
        by_description(&fx, "C\n").expect("C'"),
    );
    assert_eq!(
        ids,
        [b2.clone(), c2.clone()],
        "jj-lib's duplicated_commits order: parents first"
    );
    assert_eq!(parents(&fx.root, &b2), [fx.a.clone()]);
    assert_eq!(parents(&fx.root, &c2), [b2]);
}

#[test]
fn a_divergent_working_copy_is_the_default_revision() {
    let mut fx = base();
    let at = crate::metaedit::divergent_wc(&mut fx);
    let copy = one(&mut fx, |_| DuplicateOptions::default());
    let copy = commit(&fx.root, &copy);
    assert_eq!(
        copy.description(),
        "C2\n",
        "the duplicate is @'s commit, not its divergent twin"
    );
    assert_eq!(copy.parent_ids(), at.parent_ids());
}

#[test]
fn the_locations_place_the_duplicates_as_the_cli_does() {
    let mut fx = base();
    let onto_root = one(&mut fx, |fx| DuplicateOptions {
        revisions: vec![fx.b.clone()],
        onto: vec![fx.zero.clone()],
        ..DuplicateOptions::default()
    });
    assert_eq!(parents(&fx.root, &onto_root), [fx.zero.clone()]);

    let mut fx = base();
    let after = one(&mut fx, |fx| DuplicateOptions {
        revisions: vec![fx.c.clone()],
        insert_after: vec![fx.a.clone()],
        ..DuplicateOptions::default()
    });
    assert_eq!(parents(&fx.root, &after), [fx.a.clone()]);
    assert_eq!(parents(&fx.root, &fx.b), [after], "A's child moves on top");

    let mut fx = base();
    let before = one(&mut fx, |fx| DuplicateOptions {
        revisions: vec![fx.b.clone()],
        insert_before: vec![fx.c.clone()],
        ..DuplicateOptions::default()
    });
    assert_eq!(parents(&fx.root, &before), [fx.b.clone()]);
    assert_eq!(parents(&fx.root, &fx.c), [before]);
}

#[test]
fn a_duplicate_among_its_own_descendants_or_ancestors_warns() {
    let mut fx = base();
    let a2 = one(&mut fx, |fx| DuplicateOptions {
        revisions: vec![fx.a.clone()],
        onto: vec![fx.c.clone()],
        ..DuplicateOptions::default()
    });
    assert_eq!(parents(&fx.root, &a2), [fx.c.clone()]);
    let a_hex = crate::rebase::hex(&fx.root, &fx.a);
    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::DuplicateAsOwnDescendant);
    assert_eq!(
        warnings[0].message,
        format!("Duplicating commit {} as a descendant of itself.", &a_hex[..12])
    );

    let mut fx = base();
    let c_hex = crate::rebase::hex(&fx.root, &fx.c);
    let c2 = one(&mut fx, |fx| DuplicateOptions {
        revisions: vec![fx.c.clone()],
        insert_before: vec![fx.b.clone()],
        ..DuplicateOptions::default()
    });
    assert_eq!(parents(&fx.root, &fx.b), [c2]);
    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::DuplicateAsOwnAncestor);
    assert_eq!(
        warnings[0].message,
        format!("Duplicating commit {} as an ancestor of itself.", &c_hex[..12])
    );
}

#[test]
fn templates_duplicate_description_describes_the_duplicates() {
    let mut fx = base();
    reconfigure(
        &mut fx,
        "[templates]\nduplicate_description = '\"dup \" ++ description'\n",
    );
    let b2 = one(&mut fx, |fx| DuplicateOptions {
        revisions: vec![fx.b.clone()],
        ..DuplicateOptions::default()
    });
    assert_eq!(commit(&fx.root, &b2).description(), "dup B\n");

    reconfigure(&mut fx, "[templates]\nduplicate_description = 'bogus_keyword'\n");
    let b = fx.b.clone();
    let err = refused(&mut fx, |repo| {
        repo.duplicate(&DuplicateOptions {
            revisions: vec![b],
            ..DuplicateOptions::default()
        })
    });
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.starts_with("Failed to parse template: ")),
        "{err:?}"
    );
}

/// The CLI's order with both an unresolvable alias and a broken template (Story 9.18 closing
/// run): the template parse refuses first unless the location has children, whose
/// rewritability check resolves the immutable set; with only the alias broken, the finish refuses.
#[test]
fn a_broken_template_refuses_before_the_alias_unless_the_location_has_children() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    reconfigure(
        &mut fx,
        &format!("{UNRESOLVABLE_ALIAS}[templates]\nduplicate_description = '\"undo \" ++'\n"),
    );
    let at = |onto: &[ChangeId], after: &[ChangeId], before: &[ChangeId]| DuplicateOptions {
        revisions: vec![b.clone()],
        onto: onto.to_vec(),
        insert_after: after.to_vec(),
        insert_before: before.to_vec(),
    };
    for (options, template) in [
        (at(&[], &[], &[]), true),
        (at(std::slice::from_ref(&c), &[], &[]), true),
        (at(&[], std::slice::from_ref(&c), &[]), true),
        (at(&[], std::slice::from_ref(&a), &[]), false),
        (at(&[], &[], std::slice::from_ref(&c)), false),
    ] {
        let err = refused(&mut fx, |repo| repo.duplicate(&options));
        assert_config_class(&err, template, &format!("{options:?}"));
    }

    reconfigure(&mut fx, UNRESOLVABLE_ALIAS);
    let options = at(std::slice::from_ref(&c), &[], &[]);
    let err = refused(&mut fx, |repo| repo.duplicate(&options));
    assert_config_class(&err, false, "only the alias broken");
}

#[test]
fn the_root_commit_and_onto_with_an_insert_are_refused() {
    let mut fx = base();
    let zero = fx.zero.clone();
    let err = refused(&mut fx, |repo| {
        repo.duplicate(&DuplicateOptions {
            revisions: vec![zero],
            ..DuplicateOptions::default()
        })
    });
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "Cannot duplicate the root commit"),
        "{err:?}"
    );
    let (a, b) = (fx.a.clone(), fx.b.clone());
    let err = refused(&mut fx, |repo| {
        repo.duplicate(&DuplicateOptions {
            onto: vec![a],
            insert_after: vec![b],
            ..DuplicateOptions::default()
        })
    });
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. }
            if reason == "--onto cannot be combined with -A/--insert-after or -B/--insert-before"),
        "{err:?}"
    );
}

/// `drop_actions`' `duplicate` row (`jj duplicate S -o T`) and the verb on the same head: the
/// verb writes exactly when the row is Available, and refuses with the row's refusal otherwise.
#[test]
fn every_drop_actions_duplicate_row_agrees_with_the_verb() {
    let mut checked = [0_usize; 2];
    let mut fx = base();
    for source in 0..4 {
        for target in 0..4 {
            let ids = [&fx.zero, &fx.a, &fx.b, &fx.c].map(Clone::clone);
            let (source, target) = (ids[source].clone(), ids[target].clone());
            let location = DropLocation {
                onto: vec![target.clone()],
                ..DropLocation::default()
            };
            let rows = fx
                .repo
                .drop_actions(&DropSource::Change(source.clone()), std::slice::from_ref(&location))
                .expect("drop actions");
            let row = rows
                .actions
                .iter()
                .find(|row| row.verb == DropVerb::Duplicate)
                .expect("every -o location has a duplicate row");
            let context = format!("{source:?} -o {target:?}");
            let before = head_op(&fx.root);
            let result = fx.repo.duplicate(&DuplicateOptions {
                revisions: vec![source],
                onto: vec![target],
                ..DuplicateOptions::default()
            });
            let wrote = head_op(&fx.root) != before;
            if row.outcome.status == ActionStatus::Available {
                checked[0] += 1;
                assert!(result.is_ok() && wrote, "{context}: {result:?}");
                fx = base();
            } else {
                checked[1] += 1;
                assert_eq!(row.outcome.status, ActionStatus::Refused, "{context}");
                let err = result.expect_err(&context);
                assert!(!wrote, "{context}");
                assert_eq!(
                    format!("{:?}", Some(err)),
                    format!("{:?}", row.outcome.refusal),
                    "{context}"
                );
            }
            let _ = fx.repo.take_warnings();
        }
    }
    assert!(checked.iter().all(|n| *n > 0), "both statuses were seen: {checked:?}");
}
