// SPDX-License-Identifier: MIT

//! Story 9.9 — `Repo::metaedit`, one witness per row of the I/O matrix, read back through jj-lib.
//!
//! The history is `rebase.rs`'s: `A (a.txt) → B (b.txt, bookmark b-mark) → C (c.txt) = @`. The
//! CLI comparison of the same rows lives in the parity oracle (`crates/zanshin-parity`).

use jj_lib::object_id::ObjectId as _;
use zanshin_jj::{MetaeditOptions, MutateError};

use crate::rebase::{assert_op, base, bookmark, commit, hex, no_op, parents, reconfigure, refused, visible_all, wc};

fn message(text: &str) -> Vec<String> {
    vec![text.to_owned()]
}

#[test]
fn a_message_describes_the_revision_and_reparents_its_descendants() {
    let mut fx = base();
    let b_hex = hex(&fx.root, &fx.b);
    let c_tree = commit(&fx.root, &fx.c).tree_ids().clone();
    let result = fx
        .repo
        .metaedit(&MetaeditOptions {
            revisions: vec![fx.b.clone()],
            message: Some(message("X")),
            ..MetaeditOptions::default()
        })
        .expect("metaedit");
    assert_op(&fx, &result, &format!("edit commit metadata for commit {b_hex}"));
    assert_eq!(commit(&fx.root, &fx.b).description(), "X\n");
    assert_eq!(parents(&fx.root, &fx.c), [fx.b.clone()]);
    assert_eq!(
        commit(&fx.root, &fx.c).tree_ids(),
        &c_tree,
        "C is reparented: its content stays"
    );
    assert_eq!(commit(&fx.root, &fx.c).description(), "C\n");
    assert_eq!(bookmark(&fx.root, "b-mark"), Some(fx.b.clone()));
    assert!(result.new_change_ids.is_empty() && result.abandoned_change_ids.is_empty());
    assert_eq!(result.working_copy_change_id, fx.c);
}

#[test]
fn no_revision_is_the_working_copy_commit() {
    let mut fx = base();
    let c_hex = hex(&fx.root, &fx.c);
    let result = fx
        .repo
        .metaedit(&MetaeditOptions {
            message: Some(message("X")),
            ..MetaeditOptions::default()
        })
        .expect("metaedit");
    assert_op(&fx, &result, &format!("edit commit metadata for commit {c_hex}"));
    assert_eq!(wc(&fx.root).description(), "X\n");
    assert_eq!(commit(&fx.root, &fx.b).description(), "B\n");
}

#[test]
fn several_revisions_name_the_first_and_count_the_rest() {
    let mut fx = base();
    let c_hex = hex(&fx.root, &fx.c);
    let result = fx
        .repo
        .metaedit(&MetaeditOptions {
            revisions: vec![fx.a.clone(), fx.c.clone(), fx.b.clone()],
            message: Some(message("X")),
            ..MetaeditOptions::default()
        })
        .expect("metaedit");
    // The revset's own order: reverse topological, so C first.
    assert_op(
        &fx,
        &result,
        &format!("edit commit metadata for commit {c_hex} and 2 more"),
    );
    for id in [&fx.a, &fx.b, &fx.c] {
        assert_eq!(commit(&fx.root, id).description(), "X\n");
    }
}

#[test]
fn author_and_author_timestamp_are_set_as_the_cli_sets_them() {
    let mut fx = base();
    let before = commit(&fx.root, &fx.b).author().clone();
    fx.repo
        .metaedit(&MetaeditOptions {
            revisions: vec![fx.b.clone()],
            author: Some("Foo Bar <foo@bar>".to_owned()),
            ..MetaeditOptions::default()
        })
        .expect("--author");
    let author = commit(&fx.root, &fx.b).author().clone();
    assert_eq!((author.name.as_str(), author.email.as_str()), ("Foo Bar", "foo@bar"));
    assert_eq!(author.timestamp, before.timestamp, "--author keeps the timestamp");

    let stamp = "2000-01-23T01:23:45-08:00";
    fx.repo
        .metaedit(&MetaeditOptions {
            revisions: vec![fx.b.clone()],
            author_timestamp: Some(stamp.to_owned()),
            ..MetaeditOptions::default()
        })
        .expect("--author-timestamp");
    let author = commit(&fx.root, &fx.b).author().clone();
    assert_eq!(
        author.timestamp,
        jj_lib::time_util::parse_datetime(stamp).expect("stamp")
    );
    assert_eq!(author.name, "Foo Bar", "--author-timestamp keeps the author");

    fx.repo
        .metaedit(&MetaeditOptions {
            revisions: vec![fx.b.clone()],
            update_author: true,
            ..MetaeditOptions::default()
        })
        .expect("--update-author");
    let b = commit(&fx.root, &fx.b);
    assert_eq!(
        (b.author().name.as_str(), b.author().email.as_str()),
        (b.committer().name.as_str(), b.committer().email.as_str()),
        "the configured user"
    );
    assert_eq!(
        b.author().timestamp,
        author.timestamp,
        "--update-author keeps the timestamp"
    );

    fx.repo
        .metaedit(&MetaeditOptions {
            revisions: vec![fx.b.clone()],
            update_author_timestamp: true,
            ..MetaeditOptions::default()
        })
        .expect("--update-author-timestamp");
    let b = commit(&fx.root, &fx.b);
    assert_eq!(b.author().timestamp, b.committer().timestamp, "now");
    assert_ne!(b.author().timestamp, author.timestamp);
}

#[test]
fn update_author_with_the_same_identity_writes_nothing() {
    let mut fx = base();
    let b = fx.b.clone();
    no_op(&mut fx, |repo| {
        repo.metaedit(&MetaeditOptions {
            revisions: vec![b],
            update_author: true,
            ..MetaeditOptions::default()
        })
    });
}

#[test]
fn update_change_id_mints_a_new_change_id_the_bookmark_follows() {
    let mut fx = base();
    let result = fx
        .repo
        .metaedit(&MetaeditOptions {
            revisions: vec![fx.b.clone()],
            update_change_id: true,
            ..MetaeditOptions::default()
        })
        .expect("metaedit");
    let [minted] = <[zanshin_jj::ChangeId; 1]>::try_from(result.new_change_ids).expect("one minted id");
    assert_ne!(minted, fx.b);
    assert!(visible_all(&fx.root, &fx.b).is_empty(), "the old change id is gone");
    assert_eq!(commit(&fx.root, &minted).description(), "B\n");
    assert_eq!(bookmark(&fx.root, "b-mark"), Some(minted.clone()));
    assert_eq!(parents(&fx.root, &fx.c), [minted]);
}

#[test]
fn an_unchanged_message_writes_nothing() {
    let mut fx = base();
    let b = fx.b.clone();
    no_op(&mut fx, |repo| {
        repo.metaedit(&MetaeditOptions {
            revisions: vec![b],
            message: Some(message("B")),
            ..MetaeditOptions::default()
        })
    });
}

#[test]
fn force_rewrite_rewrites_with_nothing_else_changed() {
    let mut fx = base();
    let old = commit(&fx.root, &fx.b);
    let result = fx
        .repo
        .metaedit(&MetaeditOptions {
            revisions: vec![fx.b.clone()],
            force_rewrite: true,
            ..MetaeditOptions::default()
        })
        .expect("metaedit");
    assert_op(
        &fx,
        &result,
        &format!("edit commit metadata for commit {}", old.id().hex()),
    );
    let new = commit(&fx.root, &fx.b);
    assert_ne!(new.id(), old.id(), "rewritten");
    assert_eq!(new.description(), old.description());
    assert_eq!(new.author(), old.author());
}

#[test]
fn an_immutable_revision_is_refused() {
    let mut fx = base();
    let zero = fx.zero.clone();
    let err = refused(&mut fx, |repo| {
        repo.metaedit(&MetaeditOptions {
            revisions: vec![zero],
            message: Some(message("X")),
            ..MetaeditOptions::default()
        })
    });
    assert!(matches!(err, MutateError::Immutable { .. }), "the root: {err:?}");

    let mut fx = base();
    let config = crate::rebase::immutable(&fx.b);
    reconfigure(&mut fx, &config);
    let a = fx.a.clone();
    let err = refused(&mut fx, |repo| {
        repo.metaedit(&MetaeditOptions {
            revisions: vec![a],
            message: Some(message("X")),
            ..MetaeditOptions::default()
        })
    });
    assert!(
        matches!(err, MutateError::Immutable { .. }),
        "below an immutable head: {err:?}"
    );
}

#[test]
fn a_malformed_author_or_timestamp_is_refused_before_anything() {
    let mut fx = base();
    let b = fx.b.clone();
    for options in [
        MetaeditOptions {
            revisions: vec![b.clone()],
            author: Some("Foo".to_owned()),
            ..MetaeditOptions::default()
        },
        MetaeditOptions {
            revisions: vec![b.clone()],
            author_timestamp: Some("yesterday".to_owned()),
            ..MetaeditOptions::default()
        },
    ] {
        let err = refused(&mut fx, |repo| repo.metaedit(&options));
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason.starts_with("invalid value ")),
            "{err:?}"
        );
    }
}
