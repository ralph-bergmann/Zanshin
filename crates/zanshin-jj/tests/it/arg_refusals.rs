// SPDX-License-Identifier: MIT

//! Two CLI refusals the verbs share (the Story 9.16 review's two rejected parity findings, fixed
//! after the story loop 9.40/9.16):
//!
//! - A clap refusal comes BEFORE the pre-verb snapshot — the CLI parses its arguments before the
//!   command body snapshots — so a dirty working copy stays unsnapshotted and the call leaves no
//!   precondition report. The parity oracle's `*_clap_conflict_dirty_wc` scenarios compare the op
//!   log with the stock CLI; these tests pin the handle's side.
//! - An omitted revision's `@` in a workspace with no working-copy commit is the CLI's user error
//!   "Workspace `default` doesn't have a working-copy commit", not a backend failure.
//!
//! The history is `rebase.rs`'s: `A → B (bookmark b-mark) → C = @`.

use std::fs;

use jj_lib::ref_name::WorkspaceName;
use zanshin_jj::{
    ChangeId, CommitViewError, DuplicateOptions, FileError, GitPushArgs, MetaeditOptions, MutateError, ProgressEvent,
    RebaseOptions, Repo, RevisionRef, SplitOptions, SquashOptions,
};

use crate::rebase::{base, head_op, load, Fx};

/// The CLI's text for `@` in a workspace without a working-copy commit.
const NO_WC: &str = "Workspace `default` doesn't have a working-copy commit";

fn invalid_reason<T: std::fmt::Debug>(result: Result<T, MutateError>) -> String {
    match result {
        Err(MutateError::InvalidInput { reason, .. }) => reason,
        other => panic!("expected InvalidInput, got {other:?}"),
    }
}

/// Runs `run`, asserts its clap refusal `expected`, and that it snapshotted nothing: no
/// operation, no precondition report, no warnings.
fn assert_clap_refusal(fx: &mut Fx, verb: &str, expected: &str, run: impl FnOnce(&mut Repo) -> String) {
    let before = head_op(&fx.root);
    assert_eq!(run(&mut fx.repo), expected, "{verb}");
    assert_eq!(head_op(&fx.root), before, "{verb}: no snapshot, no operation");
    assert!(fx.repo.take_precondition().is_none(), "{verb}: no precondition ran");
    assert_eq!(fx.repo.take_warnings(), [], "{verb}: no warnings");
}

#[test]
fn a_clap_refusal_on_a_dirty_working_copy_snapshots_nothing() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    fs::write(fx.root.join("c.txt"), "c, edited before a clap refusal\n").expect("dirty c.txt");
    let before = head_op(&fx.root);
    let squash = SquashOptions {
        revision: Some(b.clone()),
        into: Some(a.clone()),
        ..SquashOptions::default()
    };
    assert_clap_refusal(
        &mut fx,
        "rebase",
        "only one of -b/--branch, -s/--source or -r/--revision can be given",
        |repo| {
            invalid_reason(repo.rebase(&RebaseOptions {
                revisions: vec![b.clone()],
                source: vec![b.clone()],
                onto: vec![a.clone()],
                ..RebaseOptions::default()
            }))
        },
    );
    let squash_conflict = "--revision cannot be used with --from or --into";
    assert_clap_refusal(&mut fx, "squash", squash_conflict, |repo| {
        invalid_reason(repo.squash(&squash))
    });
    assert_clap_refusal(&mut fx, "squash_plan", squash_conflict, |repo| {
        invalid_reason(repo.squash_plan(&squash))
    });
    assert_clap_refusal(
        &mut fx,
        "split",
        "--parallel cannot be used with --onto, --insert-after or --insert-before",
        |repo| {
            invalid_reason(repo.split(&SplitOptions {
                paths: vec!["c.txt".to_owned()],
                parallel: true,
                onto: Some(vec![a.clone()]),
                ..SplitOptions::default()
            }))
        },
    );
    assert_clap_refusal(
        &mut fx,
        "new",
        "parent revisions cannot be combined with --insert-after or --insert-before",
        |repo| invalid_reason(repo.new_change(std::slice::from_ref(&a), std::slice::from_ref(&b), &[])),
    );
    assert_clap_refusal(
        &mut fx,
        "restore",
        "`changes_in` cannot be combined with `from`/`into`",
        |repo| invalid_reason(repo.restore(Some(a.clone()), None, Some(b.clone()), &[], false)),
    );
    assert_clap_refusal(
        &mut fx,
        "git push",
        "the argument '--all' cannot be used with '--bookmark'",
        |repo| {
            let args = GitPushArgs {
                all: true,
                bookmarks: vec!["b-mark".to_owned()],
                ..GitPushArgs::default()
            };
            invalid_reason(repo.git_push(&args, &|_: ProgressEvent| {}, None))
        },
    );
    // The next valid call snapshots the edit, as the CLI's next command does.
    fx.repo.snapshot().expect("snapshot");
    assert_ne!(head_op(&fx.root), before);
}

/// Story 9.9's clap rules, as above: metaedit's value parsers and conflicts, duplicate's `-o`
/// with `-A`/`-B`.
#[test]
fn a_metaedit_or_duplicate_clap_refusal_on_a_dirty_working_copy_snapshots_nothing() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    fs::write(fx.root.join("c.txt"), "c, edited before a clap refusal\n").expect("dirty c.txt");
    let before = head_op(&fx.root);
    assert_clap_refusal(
        &mut fx,
        "metaedit",
        "--author cannot be used with --update-author",
        |repo| {
            invalid_reason(repo.metaedit(&MetaeditOptions {
                author: Some("Foo <foo@bar>".to_owned()),
                update_author: true,
                ..MetaeditOptions::default()
            }))
        },
    );
    assert_clap_refusal(
        &mut fx,
        "metaedit",
        "--author-timestamp cannot be used with --update-author-timestamp",
        |repo| {
            invalid_reason(repo.metaedit(&MetaeditOptions {
                author_timestamp: Some("2000-01-23T01:23:45-08:00".to_owned()),
                update_author_timestamp: true,
                ..MetaeditOptions::default()
            }))
        },
    );
    assert_clap_refusal(
        &mut fx,
        "metaedit",
        "invalid value 'Foo' for '--author <AUTHOR>': Invalid author string",
        |repo| {
            invalid_reason(repo.metaedit(&MetaeditOptions {
                author: Some("Foo".to_owned()),
                ..MetaeditOptions::default()
            }))
        },
    );
    assert_clap_refusal(
        &mut fx,
        "duplicate",
        "--onto cannot be combined with -A/--insert-after or -B/--insert-before",
        |repo| {
            invalid_reason(repo.duplicate(&DuplicateOptions {
                onto: vec![a.clone()],
                insert_before: vec![b.clone()],
                ..DuplicateOptions::default()
            }))
        },
    );
    fx.repo.snapshot().expect("snapshot");
    assert_ne!(head_op(&fx.root), before, "the next valid call snapshots the edit");
}

#[test]
fn a_config_that_no_longer_reads_refuses_before_a_clap_refusal() {
    // The CLI loads its config at start-up, before clap parses anything.
    let mut fx = base();
    fs::write(fx.root.join(".jj").join("repo").join("config.toml"), "not toml [").expect("break config");
    let err = fx
        .repo
        .rebase(&RebaseOptions::default())
        .expect_err("broken config refuses first");
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");
}

/// Forgets the default workspace's working-copy commit (as `jj workspace forget` from another
/// workspace would), then reopens the handle.
fn without_working_copy(fx: &mut Fx) {
    let repo = load(&fx.root);
    let mut tx = repo.start_transaction();
    pollster::block_on(tx.repo_mut().remove_workspace(WorkspaceName::DEFAULT)).expect("remove workspace");
    pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase descendants");
    pollster::block_on(tx.commit("test: forget the working-copy commit")).expect("commit");
    fx.repo = Repo::open(&fx.root).expect("reopen");
    let _ = fx.repo.take_warnings();
}

fn resolution_reason<T: std::fmt::Debug>(result: Result<T, MutateError>) -> String {
    match result {
        Err(MutateError::RevsetResolutionError { reason, .. }) => reason,
        other => panic!("expected RevsetResolutionError, got {other:?}"),
    }
}

#[test]
fn an_omitted_revision_without_a_working_copy_commit_is_the_clis_user_error() {
    let mut fx = base();
    let a = fx.a.clone();
    without_working_copy(&mut fx);
    let repo = &mut fx.repo;
    let rebase = RebaseOptions {
        onto: vec![a.clone()],
        ..RebaseOptions::default()
    };
    assert_eq!(resolution_reason(repo.rebase(&rebase)), NO_WC, "rebase's -b @ default");
    assert_eq!(
        resolution_reason(repo.squash(&SquashOptions::default())),
        NO_WC,
        "squash"
    );
    let split = SplitOptions {
        paths: vec!["c.txt".to_owned()],
        ..SplitOptions::default()
    };
    assert_eq!(resolution_reason(repo.split(&split)), NO_WC, "split");
    assert_eq!(
        resolution_reason(repo.restore(None, None, None, &[], false)),
        NO_WC,
        "restore"
    );
    assert_eq!(resolution_reason(repo.absorb(None, None, &[])), NO_WC, "absorb");
    assert_eq!(
        resolution_reason(repo.bookmark_create(&["x".to_owned()], None)),
        NO_WC,
        "bookmark create"
    );
    match repo.file_list(None, &[]) {
        Err(FileError::InvalidInput { reason }) => assert_eq!(reason, NO_WC, "file list"),
        other => panic!("file list: expected InvalidInput, got {other:?}"),
    }
    match repo.interdiff(Some(RevisionRef::ChangeId(ChangeId(a.0.clone()))), None, &[]) {
        Err(CommitViewError::RevsetResolutionError { reason }) => assert_eq!(reason, NO_WC, "interdiff"),
        other => panic!("interdiff: expected RevsetResolutionError, got {other:?}"),
    }
    let message = MetaeditOptions {
        message: Some(vec!["x".to_owned()]),
        ..MetaeditOptions::default()
    };
    assert_eq!(resolution_reason(repo.metaedit(&message)), NO_WC, "metaedit");
    assert_eq!(
        resolution_reason(repo.duplicate(&DuplicateOptions::default())),
        NO_WC,
        "duplicate"
    );
    // A named revision still resolves.
    repo.file_list(Some(a), &[]).expect("a named revision needs no @");
}
