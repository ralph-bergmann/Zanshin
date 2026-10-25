// SPDX-License-Identifier: MIT

//! The refusal order of `revert`, `duplicate` (Story 9.18 closing run) and `new` (its follow-up)
//! against the pinned CLI:
//! with both an unresolvable `immutable_heads()` alias and an unparsable description template,
//! the CLI parses the template before its `tx.finish` resolves the immutable set, unless the
//! location has children, whose rewritability check resolves it first. A merge with the root
//! (`new @ root()`, staleness run; `revert -r @- -o @ -o root()` and `duplicate @- -o @ -o
//! root()`, its follow-up) names the template too: the Git backend refuses it only at the first
//! commit write, after the template. Each witness refuses
//! through Zanshin and through the pinned `jj` on the SAME repo (a refusal writes no operation, so
//! both see one state) and compares the refusal's class.
//!
//! WHY symbolic CLI args (`@-`, `@`, `@--`): a change-id arg makes the CLI resolve it through its
//! short-prefixes index, which evaluates the broken alias and refuses before either step.

use std::ops::ControlFlow;
use std::path::Path;

use zanshin_jj::{ChangeId, DuplicateOptions, MutateError, Repo, RevertOptions};

use crate::driver::{fresh_repo, jj, Step};
use crate::scenarios::BASE;

/// `immutable_heads()` naming no revision, and every description template unparsable.
const BOTH_BROKEN: &[Step] = &[
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "revset-aliases.'immutable_heads()'",
        "nonexistent_symbol_xyz",
    ]),
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "templates.revert_description",
        "'\"undo \" ++'",
    ]),
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "templates.duplicate_description",
        "'\"undo \" ++'",
    ]),
    Step::Jj(&["config", "set", "--repo", "templates.new_description", "'\"undo \" ++'"]),
];

/// Which of the two settings a refusal names.
#[derive(Debug, PartialEq, Eq)]
enum Class {
    Template,
    ImmutableSet,
}

const TEMPLATE: &str = "Failed to parse template";
const IMMUTABLE_SET: &str = "Invalid `revset-aliases.immutable_heads()`";

fn class_of(text: &str) -> Class {
    match (text.contains(TEMPLATE), text.contains(IMMUTABLE_SET)) {
        (true, false) => Class::Template,
        (false, true) => Class::ImmutableSet,
        _ => panic!("not exactly one refusal class in:\n{text}"),
    }
}

/// The repo's operation heads — unchanged when nothing was written.
fn op_heads(root: &Path) -> Vec<String> {
    let mut heads: Vec<String> = std::fs::read_dir(root.join(".jj/repo/op_heads/heads"))
        .expect("op heads")
        .map(|entry| entry.expect("op head").file_name().to_string_lossy().into_owned())
        .collect();
    heads.sort();
    heads
}

/// The change id `revset` resolves to (one commit).
fn change(repo: &mut Repo, revset: &str) -> ChangeId {
    let mut found = None;
    let _ = repo
        .eval_revset(revset, |change| {
            found = Some(change.id);
            ControlFlow::Break(())
        })
        .expect("revset");
    found.expect("one commit")
}

/// `A`, `B`, `C` = `@--`, `@-`, `@`, and the root commit.
struct Ids {
    a: ChangeId,
    b: ChangeId,
    c: ChangeId,
    root: ChangeId,
}

/// Runs each case on one both-broken repo: the CLI's args and Zanshin's call refuse with the
/// same class, `expected`, and neither writes an operation.
fn assert_same_class(
    cases: &[(&[&str], Class)],
    zanshin: impl Fn(&mut Repo, &Ids, &[&str]) -> Result<zanshin_jj::MutationResult, MutateError>,
) {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE, BOTH_BROKEN]);
    let mut repo = Repo::open(&root).expect("open");
    let ids = Ids {
        a: change(&mut repo, "@--"),
        b: change(&mut repo, "@-"),
        c: change(&mut repo, "@"),
        root: change(&mut repo, "root()"),
    };
    for (args, expected) in cases {
        let before = op_heads(&root);
        let run = jj(&root, args);
        assert!(!run.success, "the CLI refuses {args:?}");
        assert_eq!(&class_of(&run.stderr), expected, "CLI {args:?}");
        assert_eq!(op_heads(&root), before, "the CLI writes nothing for {args:?}");

        let err = zanshin(&mut repo, &ids, args).expect_err("Zanshin refuses");
        let MutateError::Config { reason } = &err else {
            panic!("Zanshin {args:?}: {err:?}");
        };
        assert_eq!(&class_of(reason), expected, "Zanshin {args:?}");
        assert_eq!(op_heads(&root), before, "Zanshin writes nothing for {args:?}");
    }
}

/// The change id a symbolic CLI arg names.
fn id_of(ids: &Ids, arg: &str) -> ChangeId {
    match arg {
        "@--" => ids.a.clone(),
        "@-" => ids.b.clone(),
        "@" => ids.c.clone(),
        "root()" => ids.root.clone(),
        _ => panic!("unknown arg {arg}"),
    }
}

/// The `-o`/`-A`/`-B` lists of a CLI arg list's location flag, as Zanshin takes them.
fn location(ids: &Ids, args: &[&str]) -> [Vec<ChangeId>; 3] {
    let mut lists: [Vec<ChangeId>; 3] = Default::default();
    for pair in args.windows(2) {
        let slot = match pair[0] {
            "-o" => 0,
            "-A" => 1,
            "-B" => 2,
            _ => continue,
        };
        lists[slot].push(id_of(ids, pair[1]));
    }
    lists
}

#[test]
fn revert_parses_its_template_before_the_finish_resolves_the_immutable_set() {
    assert_same_class(
        &[
            (&["revert", "-r", "@-", "-o", "@"], Class::Template),
            (&["revert", "-r", "@-", "-A", "@"], Class::Template),
            (&["revert", "-r", "@-", "-A", "@--"], Class::ImmutableSet),
            (&["revert", "-r", "@-", "-B", "@"], Class::ImmutableSet),
            // A root merge: the Git backend refuses it at the first write, after the template.
            (&["revert", "-r", "@-", "-o", "@", "-o", "root()"], Class::Template),
        ],
        |repo, ids, args| {
            let [onto, insert_after, insert_before] = location(ids, args);
            repo.revert(&RevertOptions {
                revisions: vec![id_of(ids, args[2])],
                onto,
                insert_after,
                insert_before,
            })
        },
    );
}

#[test]
fn duplicate_parses_its_template_before_the_finish_resolves_the_immutable_set() {
    assert_same_class(
        &[
            (&["duplicate", "@-"], Class::Template),
            (&["duplicate", "@-", "-o", "@"], Class::Template),
            (&["duplicate", "@-", "-A", "@"], Class::Template),
            (&["duplicate", "@-", "-A", "@--"], Class::ImmutableSet),
            (&["duplicate", "@-", "-B", "@"], Class::ImmutableSet),
            // A root merge: the Git backend refuses it at the duplicates' write, after the template.
            (&["duplicate", "@-", "-o", "@", "-o", "root()"], Class::Template),
        ],
        |repo, ids, args| {
            let [onto, insert_after, insert_before] = location(ids, args);
            repo.duplicate(&DuplicateOptions {
                revisions: vec![id_of(ids, args[1])],
                onto,
                insert_after,
                insert_before,
            })
        },
    );
}

#[test]
fn new_parses_its_template_before_the_finish_resolves_the_immutable_set() {
    assert_same_class(
        &[
            (&["new", "@"], Class::Template),
            (&["new", "-o", "@"], Class::Template),
            (&["new", "-A", "@"], Class::Template),
            (&["new", "-A", "@--"], Class::ImmutableSet),
            (&["new", "-B", "@"], Class::ImmutableSet),
            // A root merge: the Git backend refuses it at the commit write, after the template.
            (&["new", "@", "root()"], Class::Template),
        ],
        |repo, ids, args| {
            let [mut parents, insert_after, insert_before] = location(ids, args);
            // `new @` / `new @ root()`: the positional revisions are the parents, as `-o @` is.
            if parents.is_empty() && insert_after.is_empty() && insert_before.is_empty() {
                parents.extend(args[1..].iter().map(|arg| id_of(ids, arg)));
            }
            repo.new_change(&parents, &insert_after, &insert_before)
        },
    );
}
