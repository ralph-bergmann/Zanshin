// SPDX-License-Identifier: MIT

//! The commit-summary hints against the pinned CLI (Story 9.56 closing run): the immutable
//! refusal's "Could not modify commit: …", push's "Rejected commit: …" and (Story 9.10) `jj next`'s
//! not-found "Working copy parent: …" render `templates.commit_summary`. Each witness refuses
//! through Zanshin and through the pinned `jj` on the SAME repo (a refusal writes no operation, so
//! both see one state) and compares Zanshin's hint with the CLI's `Hint: ` stderr line verbatim.

use std::ops::ControlFlow;
use std::path::Path;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::op_store::OperationId;
use zanshin_jj::{ChangeId, GitPushArgs, MovementOptions, Repo};

use crate::driver::{fresh_repo, git, jj, Step};
use crate::scenarios::BASE;

/// `immutable_heads()` = `b-mark`: B and A are immutable.
const B_IMMUTABLE: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "revset-aliases.'immutable_heads()'",
    "b-mark",
])];

/// A custom `templates.commit_summary`.
const CUSTOM_SUMMARY: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "templates.commit_summary",
    "'commit_id.short() ++ \" custom\"'",
])];

/// A bare remote `origin` beside the repo and an undescribed `@` on C.
const UNDESCRIBED_AT_WITH_REMOTE: &[Step] = &[
    Step::Git(&["init", "-q", "--bare", "../remote.git"]),
    Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
    Step::Jj(&["new"]),
];

/// A local bookmark `here` on that `@`.
const BOOKMARKED_AT: &[Step] = &[Step::Jj(&["bookmark", "create", "here", "-r", "@"])];

/// The CLI's `Hint: ` line that starts with `prefix`, without the `Hint: ` label.
#[track_caller]
fn cli_hint(args: &[&str], root: &Path, prefix: &str) -> String {
    let run = jj(root, args);
    assert!(!run.success, "the CLI refuses {args:?}");
    run.stderr
        .lines()
        .find_map(|line| line.strip_prefix("Hint: ").filter(|hint| hint.starts_with(prefix)))
        .unwrap_or_else(|| panic!("no {prefix:?} hint in:\n{}", run.stderr))
        .to_owned()
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

/// Zanshin's `describe` of B and the CLI's `jj describe b-mark -m x` refuse with the same first
/// hint, which is returned.
fn assert_immutable_hint(setup: &[&[Step]]) -> String {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], setup);
    let cli = cli_hint(&["describe", "b-mark", "-m", "x"], &root, "Could not modify commit: ");
    let mut repo = Repo::open(&root).expect("open");
    let b = change(&mut repo, "b-mark");
    let err = repo.describe(b, "x\n").expect_err("B is immutable");
    assert_eq!(err.hints().first(), Some(&cli), "{err:?}");
    cli
}

/// Zanshin's `git push -c @` and the CLI's on an undescribed `@` refuse with the same first hint,
/// which is returned.
fn assert_rejected_commit_hint(setup: &[&[Step]]) -> String {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], setup);
    let cli = cli_hint(&["git", "push", "-c", "@"], &root, "Rejected commit: ");
    let mut repo = Repo::open(&root).expect("open");
    let err = repo
        .git_push(
            &GitPushArgs {
                changes: vec!["@".to_owned()],
                ..GitPushArgs::default()
            },
            &|_| {},
            None,
        )
        .expect_err("an undescribed @ is rejected");
    assert_eq!(err.hints().first(), Some(&cli), "{err:?}");
    cli
}

#[test]
fn immutable_hint_renders_the_default_summary_with_refs() {
    let hint = assert_immutable_hint(&[BASE, B_IMMUTABLE]);
    assert!(hint.ends_with(" b-mark | B"), "{hint}");
}

#[test]
fn immutable_hint_renders_a_custom_summary() {
    let hint = assert_immutable_hint(&[BASE, B_IMMUTABLE, CUSTOM_SUMMARY]);
    assert!(hint.ends_with(" custom"), "{hint}");
}

#[test]
fn rejected_commit_hint_renders_the_default_summary() {
    assert_rejected_commit_hint(&[BASE, UNDESCRIBED_AT_WITH_REMOTE]);
}

#[test]
fn rejected_commit_hint_renders_a_custom_summary() {
    assert_rejected_commit_hint(&[BASE, UNDESCRIBED_AT_WITH_REMOTE, CUSTOM_SUMMARY]);
}

#[test]
fn rejected_commit_hint_renders_the_refs_of_a_bookmarked_commit() {
    let hint = assert_rejected_commit_hint(&[BASE, UNDESCRIBED_AT_WITH_REMOTE, BOOKMARKED_AT]);
    assert!(hint.contains(" here | "), "{hint}");
}

/// Story 9.10: `jj next` with nothing after `@` refuses with one hint per start commit — here
/// `@`'s one parent, B — and so does Zanshin's move, verbatim.
#[test]
fn next_not_found_hint_renders_the_working_copy_parent_summary() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let cli = cli_hint(&["next"], &root, "Working copy parent: ");
    let mut repo = Repo::open(&root).expect("open");
    let err = repo
        .move_working_copy(&MovementOptions::default())
        .expect_err("nothing after @");
    assert_eq!(err.hints(), std::slice::from_ref(&cli), "{err:?}");
    assert!(cli.ends_with(" b-mark | B"), "{cli}");
}

/// Fix run 10.2–10.5: a second workspace whose `@`'s tree the default one rewrote is stale (a new
/// description alone keeps it fresh); Zanshin's snapshot there refuses with the CLI's `Error: `
/// line verbatim (without the label) and the CLI's hint.
#[test]
fn stale_working_copy_message_is_the_cli_error_line() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(
        &["git", "init"],
        &[
            BASE,
            &[
                Step::Jj(&["workspace", "add", "../ws2"]),
                Step::Write("stale.txt", "x\n"),
                Step::Jj(&["squash", "--into", "ws2@"]),
            ],
        ],
    );
    let ws2 = root.join("..").join("ws2");
    let run = jj(&ws2, &["status"]);
    assert!(!run.success, "the CLI refuses a stale working copy");
    let cli = run
        .stderr
        .lines()
        .find_map(|line| line.strip_prefix("Error: "))
        .unwrap_or_else(|| panic!("no Error line in:\n{}", run.stderr));
    let err = Repo::open(&ws2)
        .expect("open ws2")
        .snapshot()
        .expect_err("ws2 is stale");
    assert_eq!(err.message().as_deref(), Some(cli), "{err:?}");
    assert!(
        cli.starts_with("The working copy is stale (not updated since operation "),
        "{cli}"
    );
    let cli_hint = cli_hint(&["status"], &ws2, "Run `jj workspace update-stale`");
    assert_eq!(
        err.hints().first().and_then(|h| h.lines().next()),
        Some(cli_hint.as_str())
    );
}

/// Finishes the working copy at `root` at the operation `op_hex` — how jj's own tests and
/// zanshin-jj's `snapshot_precondition` reach the sibling and missing-operation causes, which no
/// CLI command leaves behind.
fn finish_working_copy_at(root: &Path, op_hex: &str) {
    let mut workspace = test_helpers::load_workspace(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("load workspace");
    let op = OperationId::try_from_hex(op_hex).expect("hex operation id");
    let locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("lock");
    pollster::block_on(locked.finish(op)).expect("finish");
}

/// The stale working copy at `root`: Zanshin's snapshot refuses with the CLI's error line (its
/// `Error: ` or `Internal error: ` label stripped) and its first hint line starting with
/// `hint_prefix`.
#[track_caller]
fn assert_stale_matches_cli(root: &Path, hint_prefix: &str) {
    let run = jj(root, &["status"]);
    assert!(!run.success, "the CLI refuses a stale working copy");
    let cli = run
        .stderr
        .lines()
        .find_map(|line| {
            line.strip_prefix("Error: ")
                .or_else(|| line.strip_prefix("Internal error: "))
        })
        .unwrap_or_else(|| panic!("no Error line in:\n{}", run.stderr));
    let err = Repo::open(root).expect("open").snapshot().expect_err("stale");
    assert_eq!(err.message().as_deref(), Some(cli), "{err:?}");
    let cli_hint = cli_hint(&["status"], root, hint_prefix);
    assert_eq!(
        err.hints().first().and_then(|h| h.lines().next()),
        Some(cli_hint.as_str())
    );
}

/// The SIBLING cause: the working copy sits at an unpublished operation while another
/// operation from the same parent was published.
#[test]
fn stale_working_copy_at_a_sibling_operation_matches_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let (op, _) = test_helpers::add_unpublished_op(&root, "unpublished");
    finish_working_copy_at(&root, &op);
    let _ = test_helpers::add_commit_off_root(&root, "published sibling");
    assert_stale_matches_cli(&root, "Run `jj op integrate");
}

/// The NOT-FOUND cause: the working copy names an operation that does not exist.
#[test]
fn stale_working_copy_at_a_missing_operation_matches_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    finish_working_copy_at(&root, &"ab".repeat(64));
    assert_stale_matches_cli(&root, "Run `jj workspace update-stale`");
}

/// Story 11.22: converting a Git clone — `main` plus the untracked `origin/main` and a second
/// remote branch with no local bookmark — reports the remote bookmarks the CLI's `jj git init
/// --colocate` lists under its "aren't associated with the existing local bookmarks" hint, in its
/// order.
#[test]
fn conversion_lists_the_cli_trackable_remote_bookmarks() {
    test_helpers::pin_test_env();
    let dir = tempfile::TempDir::new().expect("tempdir");
    let root = dir.path();
    git(root, &["init", "-q", "-b", "main", "src"]);
    std::fs::write(root.join("src/a.txt"), "a\n").expect("write");
    git(root, &["-C", "src", "add", "."]);
    git(root, &["-C", "src", "commit", "-q", "-m", "A"]);
    git(root, &["-C", "src", "branch", "other"]);
    git(root, &["clone", "-q", "src", "cli"]);
    git(root, &["clone", "-q", "src", "zanshin"]);

    let run = jj(&root.join("cli"), &["git", "init", "--colocate"]).ok();
    let cli: Vec<String> = run
        .stderr
        .lines()
        .skip_while(|line| !line.contains("aren't associated with the existing local bookmarks"))
        .skip(1)
        .map_while(|line| line.strip_prefix("  "))
        .map(ToOwned::to_owned)
        .collect();
    assert_eq!(cli, ["main@origin"], "{}", run.stderr);

    let outcome = zanshin_jj::convert_colocated(&root.join("zanshin"));
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(outcome.trackable_remote_bookmarks, cli);
}
