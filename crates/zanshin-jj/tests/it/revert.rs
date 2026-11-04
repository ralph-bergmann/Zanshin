// SPDX-License-Identifier: MIT

//! Story 9.18 — `Repo::revert`, one witness per row of the I/O matrix, read back through jj-lib,
//! and the agreement of `drop_actions`' `revert` rows with the verb.
//!
//! The history is `rebase.rs`'s: `A (a.txt) → B (b.txt, bookmark b-mark) → C (c.txt) = @`. The
//! CLI comparison of the same rows lives in the parity oracle (`crates/zanshin-parity`).

use jj_lib::commit::Commit;
use zanshin_jj::{ActionStatus, ChangeId, DropLocation, DropSource, DropVerb, MutateError, RevertOptions};

use crate::rebase::{add, assert_op, base, commit, head_op, hex, immutable, parents, reconfigure, refused, Fx};

/// Reverts with `options`, asserts the CLI's operation, and returns the reverse commits' ids.
fn revert<const N: usize>(fx: &mut Fx, options: impl FnOnce(&Fx) -> RevertOptions) -> [ChangeId; N] {
    let options = options(fx);
    // The CLI's `to_revert[0]` is the newest revision; the tests name it first. Its hex is read
    // before the call: `-A`/`-B` may rebase it.
    let first = hex(&fx.root, options.revisions.first().expect("a revision"));
    let result = fx.repo.revert(&options).expect("revert");
    let op = match options.revisions.len() - 1 {
        0 => format!("revert commit {first}"),
        n => format!("revert commit {first} and {n} more"),
    };
    assert_op(fx, &result, &op);
    assert!(result.abandoned_change_ids.is_empty());
    <[ChangeId; N]>::try_from(result.new_change_ids).expect("one reverse per revision")
}

/// The repo paths `id`'s tree holds, sorted.
fn files(fx: &Fx, id: &ChangeId) -> Vec<String> {
    let mut paths: Vec<String> = futures::executor::block_on_stream(commit(&fx.root, id).tree().entries())
        .map(|(path, _)| path.as_internal_file_string().to_owned())
        .collect();
    paths.sort();
    paths
}

fn default_description(fx: &Fx, reverted: &ChangeId, first_line: &str) -> String {
    format!(
        "Revert \"{first_line}\"\n\nThis reverts commit {}.\n",
        hex(&fx.root, reverted)
    )
}

#[test]
fn a_revision_is_reverted_onto_the_working_copy() {
    let mut fx = base();
    let [b_rev] = revert(&mut fx, |fx| RevertOptions {
        revisions: vec![fx.b.clone()],
        onto: vec![fx.c.clone()],
        ..RevertOptions::default()
    });
    assert_eq!(parents(&fx.root, &b_rev), [fx.c.clone()]);
    assert_eq!(files(&fx, &b_rev), ["a.txt", "c.txt"], "C minus B's change");
    assert_eq!(
        commit(&fx.root, &b_rev).description(),
        default_description(&fx, &fx.b, "B")
    );
    assert_eq!(parents(&fx.root, &fx.c), [fx.b.clone()], "the reverted commit stays");
}

#[test]
fn two_revisions_are_reverted_newest_first_and_chained() {
    let mut fx = base();
    let [c_rev, b_rev] = revert(&mut fx, |fx| RevertOptions {
        revisions: vec![fx.c.clone(), fx.b.clone()],
        onto: vec![fx.c.clone()],
        ..RevertOptions::default()
    });
    assert_eq!(parents(&fx.root, &c_rev), [fx.c.clone()]);
    assert_eq!(parents(&fx.root, &b_rev), std::slice::from_ref(&c_rev));
    assert_eq!(files(&fx, &c_rev), ["a.txt", "b.txt"]);
    assert_eq!(files(&fx, &b_rev), ["a.txt"]);
    assert_eq!(
        commit(&fx.root, &c_rev).description(),
        default_description(&fx, &fx.c, "C")
    );
    assert_eq!(
        commit(&fx.root, &b_rev).description(),
        default_description(&fx, &fx.b, "B")
    );
}

#[test]
fn insert_after_and_before_rebase_the_children_onto_the_reverse() {
    let mut fx = base();
    let b_hex = hex(&fx.root, &fx.b);
    let [after] = revert(&mut fx, |fx| RevertOptions {
        revisions: vec![fx.b.clone()],
        insert_after: vec![fx.a.clone()],
        ..RevertOptions::default()
    });
    assert_eq!(parents(&fx.root, &after), [fx.a.clone()]);
    assert_eq!(
        commit(&fx.root, &after).description(),
        format!("Revert \"B\"\n\nThis reverts commit {b_hex}.\n"),
        "names B's commit as it was before the call rebased it"
    );
    assert_ne!(hex(&fx.root, &fx.b), b_hex, "B itself was rebased");
    assert_eq!(parents(&fx.root, &fx.b), [after], "A's child moves on top");

    let mut fx = base();
    let [before] = revert(&mut fx, |fx| RevertOptions {
        revisions: vec![fx.a.clone()],
        insert_before: vec![fx.c.clone()],
        ..RevertOptions::default()
    });
    assert_eq!(parents(&fx.root, &before), [fx.b.clone()]);
    assert_eq!(files(&fx, &before), ["b.txt"]);
    assert_eq!(parents(&fx.root, &fx.c), [before]);
    assert_eq!(files(&fx, &fx.c), ["b.txt", "c.txt"], "C rebased loses a.txt");
}

#[test]
fn a_reverse_a_later_change_overwrote_is_a_labelled_conflict() {
    let mut fx = base();
    let c = fx.c.clone();
    let d = add(&mut fx, &[c], &[("b.txt", "x\n")], "D\n");
    let [b_rev] = revert(&mut fx, |fx| RevertOptions {
        revisions: vec![fx.b.clone()],
        onto: vec![d.clone()],
        ..RevertOptions::default()
    });
    let reverse = commit(&fx.root, &b_rev);
    assert!(reverse.has_conflict());
    let label = |id: &ChangeId| -> String { Commit::conflict_label(&commit(&fx.root, id)) };
    assert_eq!(
        reverse.tree().labels().as_slice(),
        [
            format!("{} (revert destination)", label(&d)),
            format!("{} (reverted revision)", label(&fx.b)),
            format!("{} (parents of reverted revision)", label(&fx.a)),
        ]
    );
}

#[test]
fn templates_revert_description_describes_the_reverses() {
    let mut fx = base();
    reconfigure(
        &mut fx,
        "[templates]\nrevert_description = '\"undo \" ++ description.first_line()'\n",
    );
    let [b_rev] = revert(&mut fx, |fx| RevertOptions {
        revisions: vec![fx.b.clone()],
        onto: vec![fx.c.clone()],
        ..RevertOptions::default()
    });
    assert_eq!(
        commit(&fx.root, &b_rev).description(),
        "undo B",
        "rendered as is, never newline-completed"
    );

    reconfigure(&mut fx, "[templates]\nrevert_description = 'bogus_keyword'\n");
    let (b, c) = (fx.b.clone(), fx.c.clone());
    let err = refused(&mut fx, |repo| {
        repo.revert(&RevertOptions {
            revisions: vec![b],
            onto: vec![c],
            ..RevertOptions::default()
        })
    });
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.starts_with("Failed to parse template: ")),
        "{err:?}"
    );
}

/// An `immutable_heads()` alias no commit resolves. `revsets.short-prefixes` is emptied: its
/// default (`revsets.log`) names `immutable_heads()`, so a change-id argument would refuse loading
/// it first — the CLI's order too (`change_id_prefix.rs` pins that).
pub(crate) const UNRESOLVABLE_ALIAS: &str =
    "[revset-aliases]\n\"immutable_heads()\" = \"nonexistent_symbol_xyz\"\n[revsets]\nshort-prefixes = \"\"\n";

/// Asserts `err` is the template parse refusal (`template`) or the immutable-set one.
pub(crate) fn assert_config_class(err: &MutateError, template: bool, context: &str) {
    let prefix = if template {
        "Failed to parse template: "
    } else {
        "Invalid `revset-aliases.immutable_heads()`: "
    };
    assert!(
        matches!(err, MutateError::Config { reason } if reason.starts_with(prefix)),
        "{context}: {err:?}"
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
        &format!("{UNRESOLVABLE_ALIAS}[templates]\nrevert_description = '\"undo \" ++'\n"),
    );
    let at = |onto: &[ChangeId], after: &[ChangeId], before: &[ChangeId]| RevertOptions {
        revisions: vec![b.clone()],
        onto: onto.to_vec(),
        insert_after: after.to_vec(),
        insert_before: before.to_vec(),
    };
    for (options, template) in [
        (at(std::slice::from_ref(&c), &[], &[]), true),
        (at(&[], std::slice::from_ref(&c), &[]), true),
        (at(&[], std::slice::from_ref(&a), &[]), false),
        (at(&[], &[], std::slice::from_ref(&c)), false),
    ] {
        let err = refused(&mut fx, |repo| repo.revert(&options));
        assert_config_class(&err, template, &format!("{options:?}"));
    }

    reconfigure(&mut fx, UNRESOLVABLE_ALIAS);
    let options = at(std::slice::from_ref(&c), &[], &[]);
    let err = refused(&mut fx, |repo| repo.revert(&options));
    assert_config_class(&err, false, "only the alias broken");
}

#[test]
fn clap_refusals_come_before_the_snapshot() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    for (options, reason) in [
        (
            RevertOptions {
                onto: vec![a.clone()],
                ..RevertOptions::default()
            },
            "revert requires at least one revision",
        ),
        (
            RevertOptions {
                revisions: vec![b.clone()],
                ..RevertOptions::default()
            },
            "expected at least one of --onto, -A/--insert-after or -B/--insert-before",
        ),
        (
            RevertOptions {
                revisions: vec![b.clone()],
                onto: vec![a.clone()],
                insert_after: vec![a.clone()],
                ..RevertOptions::default()
            },
            "--onto cannot be combined with -A/--insert-after or -B/--insert-before",
        ),
    ] {
        // A dirty working copy proves no snapshot ran.
        std::fs::write(fx.root.join("dirty.txt"), "d\n").expect("write");
        let err = refused(&mut fx, |repo| repo.revert(&options));
        assert!(
            matches!(&err, MutateError::InvalidInput { reason: r, .. } if r == reason),
            "{err:?}"
        );
    }
}

#[test]
fn unknown_and_immutable_locations_are_refused() {
    let mut fx = base();
    let (a, c) = (fx.a.clone(), fx.c.clone());
    // A change id no commit carries (all `z` would be the root's).
    let unknown = ChangeId("kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk".to_owned());
    let err = refused(&mut fx, |repo| {
        repo.revert(&RevertOptions {
            revisions: vec![unknown],
            onto: vec![c.clone()],
            ..RevertOptions::default()
        })
    });
    assert!(matches!(&err, MutateError::ChangeNotFound { .. }), "{err:?}");

    reconfigure(&mut fx, &immutable(&c));
    let err = refused(&mut fx, |repo| {
        repo.revert(&RevertOptions {
            revisions: vec![a],
            insert_before: vec![c],
            ..RevertOptions::default()
        })
    });
    assert!(matches!(&err, MutateError::Immutable { .. }), "{err:?}");
}

/// A root merge refuses only a broken template — alone or with the alias — naming the template;
/// with a valid one the Git backend drops the root from the merge (jj-lib 0.47, jj #8076).
#[test]
fn a_root_merge_refuses_only_a_broken_template() {
    let mut fx = base();
    let (b, c, zero) = (fx.b.clone(), fx.c.clone(), fx.zero.clone());
    let options = RevertOptions {
        revisions: vec![b],
        onto: vec![c, zero],
        ..RevertOptions::default()
    };
    let broken_template = "[templates]\nrevert_description = '\"x\" ++'\n";
    for config in [
        broken_template.to_owned(),
        format!("{UNRESOLVABLE_ALIAS}{broken_template}"),
    ] {
        reconfigure(&mut fx, &config);
        let err = refused(&mut fx, |repo| repo.revert(&options));
        assert_config_class(&err, true, &config);
    }
    reconfigure(
        &mut fx,
        "[templates]\nrevert_description = '\"undo \" ++ description'\n",
    );
    fx.repo.revert(&options).expect("a root merge is written");
}

/// `drop_actions`' `revert` rows (`jj revert -r S -o T` / `-B T`) and the verb on the same head:
/// the verb writes exactly when the row is Available, and refuses with the row's refusal
/// otherwise.
#[test]
fn every_drop_actions_revert_row_agrees_with_the_verb() {
    let mut checked = [0_usize; 2];
    let mut fx = base();
    for before in [false, true] {
        for source in 0..4 {
            for target in 0..4 {
                let ids = [&fx.zero, &fx.a, &fx.b, &fx.c].map(Clone::clone);
                let (source, target) = (ids[source].clone(), ids[target].clone());
                let location = if before {
                    DropLocation {
                        insert_before: vec![target.clone()],
                        ..DropLocation::default()
                    }
                } else {
                    DropLocation {
                        onto: vec![target.clone()],
                        ..DropLocation::default()
                    }
                };
                let rows = fx
                    .repo
                    .drop_actions(&DropSource::Change(source.clone()), std::slice::from_ref(&location))
                    .expect("drop actions");
                let row = rows
                    .actions
                    .iter()
                    .find(|row| row.verb == DropVerb::Revert)
                    .expect("every location has a revert row");
                let context = format!("{source:?} {location:?}");
                let head = head_op(&fx.root);
                let result = fx.repo.revert(&RevertOptions {
                    revisions: vec![source],
                    onto: location.onto,
                    insert_after: location.insert_after,
                    insert_before: location.insert_before,
                });
                let wrote = head_op(&fx.root) != head;
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
    }
    assert!(checked.iter().all(|n| *n > 0), "both statuses were seen: {checked:?}");
}
