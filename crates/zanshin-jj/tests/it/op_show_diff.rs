// SPDX-License-Identifier: MIT

//! `Repo::op_show` / `Repo::op_diff` — the CLI's `jj op show` / `jj op diff` @ v0.46.0 as typed
//! data (Story 9.21): operation resolution, the six diff sections, `show_changes_in` and its
//! failures, and `op diff`'s clap rule.

use std::fs;
use std::path::Path;

use test_helpers::extract_fixture;
use zanshin_jj::{
    ChangeId, CommitId, ConfigScope, ConfigTarget, MutateError, OpCommitsDiff, OpDiff, OpDiffOptions, OpRefChange,
    OpRefTarget, OpRemoteRefChange, OpWorkingCopyChange, RefDistance, Repo, WarningKind,
};

/// `(change id, commit id)` of the single commit `revset` names.
fn one(repo: &mut Repo, revset: &str) -> (ChangeId, CommitId) {
    let mut found = None;
    let _ = repo
        .eval_revset(revset, |change| {
            found = Some((change.id, change.commit_id));
            std::ops::ControlFlow::Break(())
        })
        .expect("the revset resolves");
    found.expect("the revset names a commit")
}

/// The head operation's id.
fn head_id(repo: &mut Repo) -> String {
    repo.op_log(Some(1)).unwrap().swap_remove(0).id.0
}

/// The commit section of `diff`, which must be there.
fn commits(diff: &OpDiff) -> &OpCommitsDiff {
    diff.commits.as_ref().expect("the commit section")
}

const NONE: RefDistance = RefDistance {
    lower: 0,
    upper: Some(0),
};

fn target(ids: &[&CommitId]) -> OpRefTarget {
    OpRefTarget {
        adds: ids.iter().map(|id| (*id).clone()).collect(),
        removes: Vec::new(),
        conflicted: false,
    }
}

/// `op show` of a describe: the head operation, and every rewritten commit with its predecessor —
/// the described commit and its two rebased descendants — in revset order, nothing elided.
#[test]
fn op_show_of_a_describe_lists_the_rewritten_commits_with_their_predecessors() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (change, old) = one(&mut repo, "description(exact:'Commit 1')");
    let (_, old3) = one(&mut repo, "description(exact:'Commit 3')");
    repo.describe(change.clone(), "described").unwrap();
    let new = repo.get_change(&change).unwrap().commit_id;
    let (_, new3) = one(&mut repo, "description(exact:'Commit 3')");
    let head = head_id(&mut repo);

    let show = repo.op_show("@", None).unwrap();

    assert_eq!(show.operation.id.0, head);
    assert_eq!(show.operation.workspace_name.as_deref(), Some("default"));
    let diff = show.diff.expect("a single-parent operation has a diff");
    let rows = &commits(&diff).changes;
    assert_eq!(rows.len(), 3, "{rows:?}");
    assert_eq!(rows[0].commit_id, new3, "children first, as the revset streams them");
    assert_eq!(rows[0].removed_commit_ids, [old3]);
    let described = rows.iter().find(|row| row.commit_id == new).expect("the described row");
    assert!(!described.abandoned);
    assert_eq!(described.added_commit_ids, std::slice::from_ref(&new));
    assert_eq!(described.removed_commit_ids, [old]);
    assert_eq!(commits(&diff).elided_newly_visible, NONE);
    assert_eq!(commits(&diff).elided_newly_hidden, NONE);
    assert!(diff.working_copies.is_empty() && diff.local_bookmarks.is_empty() && diff.local_tags.is_empty());
    assert!(diff.remote_bookmarks.is_empty() && diff.remote_tags.is_empty());
    assert!(repo.take_warnings().is_empty());
}

/// `new` creates a commit (no predecessor) and moves the working copy.
#[test]
fn op_show_of_new_records_the_new_commit_and_the_working_copy_move() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (wc, old_wc) = one(&mut repo, "@");
    repo.new_change(&[wc], &[], &[]).unwrap();
    let (_, new_wc) = one(&mut repo, "@");

    let diff = repo.op_show("@", None).unwrap().diff.unwrap();

    assert_eq!(commits(&diff).changes.len(), 1);
    let row = &commits(&diff).changes[0];
    assert_eq!(row.commit_id, new_wc);
    assert!(row.removed_commit_ids.is_empty(), "a new commit has no predecessor");
    assert_eq!(
        diff.working_copies,
        [OpWorkingCopyChange {
            workspace: "default".to_owned(),
            from: Some(old_wc),
            to: Some(new_wc),
        }]
    );
}

/// `abandon` hides a commit with no successor: an abandoned row keyed by the old commit.
#[test]
fn op_show_of_abandon_marks_the_commit_abandoned() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (change, commit) = one(&mut repo, "description(exact:'Commit 3')");
    repo.abandon(&[change]).unwrap();

    let diff = repo.op_show("@", None).unwrap().diff.unwrap();

    let row = commits(&diff)
        .changes
        .iter()
        .find(|row| row.commit_id == commit)
        .expect("the abandoned row");
    assert!(row.abandoned);
    assert!(row.added_commit_ids.is_empty());
    assert_eq!(row.removed_commit_ids, [commit]);
}

/// Bookmark create / move / delete, a tag, a conflicted bookmark and remote bookmarks: each in
/// its section, the `git` pseudo-remote left out of a Git-backed repo.
#[test]
fn op_show_reports_the_ref_sections() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (_, wc) = one(&mut repo, "@");
    let (_, c1) = one(&mut repo, "description(exact:'Commit 1')");
    let (_, c2) = one(&mut repo, "description(exact:'Commit 2')");
    let ref_change = |name: &str, from: OpRefTarget, to: OpRefTarget| OpRefChange {
        name: name.to_owned(),
        from,
        to,
    };

    repo.bookmark_create(&["feat".to_owned()], None).unwrap();
    let diff = repo.op_show("@", None).unwrap().diff.unwrap();
    assert_eq!(diff.local_bookmarks, [ref_change("feat", target(&[]), target(&[&wc]))]);

    test_helpers::set_local_bookmark(&fx.path, "feat", &[&c1.0]);
    let diff = repo.op_show("@", None).unwrap().diff.unwrap();
    assert_eq!(
        diff.local_bookmarks,
        [ref_change("feat", target(&[&wc]), target(&[&c1]))]
    );

    repo.bookmark_delete(&["feat".to_owned()]).unwrap();
    let diff = repo.op_show("@", None).unwrap().diff.unwrap();
    assert_eq!(diff.local_bookmarks, [ref_change("feat", target(&[&c1]), target(&[]))]);

    test_helpers::set_local_bookmark(&fx.path, "both", &[&c1.0, &c2.0]);
    let diff = repo.op_show("@", None).unwrap().diff.unwrap();
    let conflicted = OpRefTarget {
        adds: vec![c1.clone(), c2.clone()],
        removes: vec![c1.clone()],
        conflicted: true,
    };
    assert_eq!(diff.local_bookmarks, [ref_change("both", target(&[]), conflicted)]);

    test_helpers::set_tag(&fx.path, "v1", &[&c2.0]);
    let diff = repo.op_show("@", None).unwrap().diff.unwrap();
    assert_eq!(diff.local_tags, [ref_change("v1", target(&[]), target(&[&c2]))]);
    assert!(diff.local_bookmarks.is_empty());

    test_helpers::set_remote_bookmark(&fx.path, "main", "origin", &c1.0, true);
    let diff = repo.op_show("@", None).unwrap().diff.unwrap();
    assert_eq!(
        diff.remote_bookmarks,
        [OpRemoteRefChange {
            name: "main".to_owned(),
            remote: "origin".to_owned(),
            from: target(&[]),
            from_tracked: false,
            to: target(&[&c1]),
            to_tracked: true,
        }]
    );

    test_helpers::set_remote_tag(&fx.path, "v1", "origin", &c2.0, false);
    let diff = repo.op_show("@", None).unwrap().diff.unwrap();
    assert_eq!(diff.remote_tags.len(), 1);
    assert!(!diff.remote_tags[0].to_tracked);

    test_helpers::set_remote_bookmark(&fx.path, "hidden", "git", &c1.0, false);
    let diff = repo.op_show("@", None).unwrap().diff.unwrap();
    assert!(diff.remote_bookmarks.is_empty(), "the git pseudo-remote is left out");
}

/// `@-`, a full id and a 12-digit prefix resolve as in the CLI.
#[test]
fn op_show_resolves_operation_expressions() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (change, _) = one(&mut repo, "description(exact:'Commit 1')");
    let parent = head_id(&mut repo);
    repo.describe(change, "described").unwrap();
    let head = head_id(&mut repo);

    assert_eq!(repo.op_show("@-", None).unwrap().operation.id.0, parent);
    assert_eq!(repo.op_show(&head, None).unwrap().operation.id.0, head);
    assert_eq!(repo.op_show(&head[..12], None).unwrap().operation.id.0, head);
}

/// The op-expression refusals: no match is `OperationNotFound`, everything else
/// `InvalidInput` with jj-lib's text; nothing is written.
#[test]
fn op_show_refuses_what_does_not_resolve_to_one_operation() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = repo.op_log(None).unwrap().len();

    let err = repo.op_show("ffffffffffff", None).expect_err("no such operation");
    assert!(
        matches!(&err, MutateError::OperationNotFound { reason } if reason == r#"No operation ID matching "ffffffffffff""#),
        "{err:?}"
    );
    let err = repo.op_show("zz", None).expect_err("not hex");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == r#"Operation ID "zz" is not a valid hexadecimal prefix"#),
        "{err:?}"
    );
    let err = repo.op_show("@+", None).expect_err("no child");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == r#"The "@+" expression resolved to no operations"#),
        "{err:?}"
    );
    assert_eq!(repo.op_log(None).unwrap().len(), before);
}

/// The root operation shows an empty diff against itself (its "parents" merge to the root).
#[test]
fn op_show_of_the_root_operation_has_an_empty_diff() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let root = repo.op_log(None).unwrap().pop().unwrap();

    let show = repo.op_show(&root.id.0, None).unwrap();

    assert!(show.operation.root_op);
    assert_eq!(show.operation.workspace_name, None);
    let diff = show.diff.unwrap();
    assert!(commits(&diff).changes.is_empty());
    assert!(diff.working_copies.is_empty());
}

/// Two op heads, merged by the next load into a "reconcile divergent operations" operation with
/// two parents: `op show` of it has no diff, as the CLI prints none.
#[test]
fn op_show_of_a_merge_operation_has_no_diff() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    diverge(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let show = repo.op_show("@", None).unwrap();

    assert_eq!(show.operation.parent_ids.len(), 2, "{:?}", show.operation);
    assert_eq!(show.diff, None);
}

/// Leaves the repo at `root` with two op heads: two describes from the same base operation.
pub(crate) fn diverge(root: &Path) {
    diverge_with(root, ("description(exact:'Commit 1')", "description(exact:'Commit 3')"));
}

/// [`diverge`] describing the commits `first` and `second` name, one per branch.
fn diverge_with(root: &Path, (first_revset, second_revset): (&str, &str)) {
    let heads_dir = root.join(".jj").join("repo").join("op_heads").join("heads");
    let mut repo = Repo::open(root).unwrap();
    let base = head_id(&mut repo);
    let (c1, _) = one(&mut repo, first_revset);
    let (c3, _) = one(&mut repo, second_revset);
    repo.describe(c1, "A").unwrap();
    let first = head_id(&mut repo);
    drop(repo);
    fs::remove_file(heads_dir.join(&first)).unwrap();
    fs::write(heads_dir.join(&base), "").unwrap();
    let mut repo = Repo::open(root).unwrap();
    repo.describe(c3, "B").unwrap();
    drop(repo);
    fs::write(heads_dir.join(&first), "").unwrap();
}

/// A `show_changes_in` that does not resolve warns and drops the commit section; the other
/// sections stay.
#[test]
fn op_show_with_an_unresolvable_show_changes_in_warns_and_has_no_commit_section() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (wc, _) = one(&mut repo, "@");
    repo.new_change(&[wc], &[], &[]).unwrap();
    let _ = repo.take_warnings();

    let diff = repo.op_show("@", Some("nonexistent_xyz")).unwrap().diff.unwrap();

    assert_eq!(diff.commits, None);
    assert_eq!(diff.working_copies.len(), 1);
    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::OpDiffChangesUnresolved);
    assert!(
        warnings[0]
            .message
            .starts_with("Could not resolve revset expression for elision: Revision `nonexistent_xyz` doesn't exist"),
        "{}",
        warnings[0].message
    );
    assert!(
        warnings[0]
            .message
            .ends_with("\n   (Use --show-changes-in=all() to see all changes)"),
        "the CLI's detail line: {}",
        warnings[0].message
    );
}

/// A `show_changes_in` that resolves against only one of the two operations is unresolved too:
/// the CLI's `resolve_op_diff_changes_exprs` resolves it against the from- AND the to-repo
/// (`cli/src/commands/operation/diff.rs:227-246` @ v0.46.0) — a bookmark the operation created
/// (missing in the from-repo) and one it deleted (missing in the to-repo).
#[test]
fn op_show_with_a_show_changes_in_missing_on_one_side_warns_and_has_no_commit_section() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let name = "only_on_one_side".to_owned();

    repo.bookmark_create(std::slice::from_ref(&name), None).unwrap();
    let _ = repo.take_warnings();
    let created = repo.op_show("@", Some(&name)).unwrap().diff.unwrap();
    assert_eq!(created.commits, None, "missing in the from-operation");
    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::OpDiffChangesUnresolved);

    repo.bookmark_delete(std::slice::from_ref(&name)).unwrap();
    let _ = repo.take_warnings();
    let deleted = repo.op_show("@", Some(&name)).unwrap().diff.unwrap();
    assert_eq!(deleted.commits, None, "missing in the to-operation");
    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::OpDiffChangesUnresolved);
}

/// `show_changes_in = none()` elides every change; the counts say how many.
#[test]
fn op_show_elides_the_changes_outside_show_changes_in() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (change, _) = one(&mut repo, "description(exact:'Commit 1')");
    repo.describe(change, "described").unwrap();

    let diff = repo.op_show("@", Some("none()")).unwrap().diff.unwrap();

    let three = RefDistance {
        lower: 3,
        upper: Some(3),
    };
    assert!(commits(&diff).changes.is_empty());
    assert_eq!(commits(&diff).elided_newly_visible, three);
    assert_eq!(commits(&diff).elided_newly_hidden, three);
}

/// A caller text that does not parse is a revset parse error naming it; the config's is a
/// config error naming the key.
#[test]
fn op_show_reports_unparseable_show_changes_in_texts() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let err = repo.op_show("@", Some("(")).expect_err("caller text");
    assert!(
        matches!(&err, MutateError::RevsetParseError { reason, .. } if reason.starts_with("Invalid `--show-changes-in` expression: (: ")),
        "{err:?}"
    );

    zanshin_jj::config_set(
        Some(&fx.path),
        &ConfigTarget::Scope(ConfigScope::Repo),
        "revsets.op-diff-changes-in",
        "(",
    )
    .result
    .expect("set the repo config");
    let err = repo.op_show("@", None).expect_err("config text");
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.starts_with("Invalid `revsets.op-diff-changes-in`: ")),
        "{err:?}"
    );
}

/// `op diff` without arguments, with `--op @` and with `--from <parent>` all compare the head
/// with its parent — what `op show` shows.
#[test]
fn op_diff_forms_compare_the_head_with_its_parent() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (change, _) = one(&mut repo, "description(exact:'Commit 1')");
    let parent = head_id(&mut repo);
    repo.describe(change, "described").unwrap();
    let head = head_id(&mut repo);
    let shown = repo.op_show("@", None).unwrap().diff.unwrap();

    for options in [
        OpDiffOptions::default(),
        OpDiffOptions {
            operation: Some("@".to_owned()),
            ..Default::default()
        },
        OpDiffOptions {
            from: Some(parent.clone()),
            ..Default::default()
        },
        OpDiffOptions {
            from: Some("@-".to_owned()),
            to: Some(head.clone()),
            ..Default::default()
        },
    ] {
        let result = repo.op_diff(&options).unwrap();
        assert_eq!(
            result.from.iter().map(|op| op.id.0.as_str()).collect::<Vec<_>>(),
            [parent.as_str()],
            "{options:?}"
        );
        assert_eq!(result.to.id.0, head, "{options:?}");
        assert_eq!(result.diff, shown, "{options:?}");
    }

    // Backwards: the described commit is newly hidden and its predecessor visible again.
    let back = repo
        .op_diff(&OpDiffOptions {
            from: Some(head.clone()),
            to: Some(parent),
            ..Default::default()
        })
        .unwrap();
    assert_ne!(back.diff, shown);
    assert_eq!(commits(&back.diff).changes.len(), 3);
}

/// `--operation` with `--from` / `--to` is clap's conflict: refused before the snapshot, with no
/// precondition report and nothing written.
#[test]
fn op_diff_refuses_operation_with_from_or_to_before_the_snapshot() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = repo.op_log(None).unwrap().len();
    let _ = repo.take_precondition();
    fs::write(fx.path.join("dirty.txt"), "would be snapshotted\n").unwrap();

    for (options, flag) in [
        (
            OpDiffOptions {
                operation: Some("@".to_owned()),
                from: Some("@-".to_owned()),
                ..Default::default()
            },
            "--from",
        ),
        (
            OpDiffOptions {
                operation: Some("@".to_owned()),
                to: Some("@-".to_owned()),
                ..Default::default()
            },
            "--to",
        ),
    ] {
        let err = repo.op_diff(&options).expect_err("clap's conflict");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. }
                if *reason == format!("the argument '--operation' cannot be used with '{flag}'")),
            "{err:?}"
        );
        assert!(repo.take_precondition().is_none(), "no snapshot ran");
    }
    let mut fresh = Repo::open(&fx.path).unwrap();
    // The log read itself snapshots `dirty.txt`; count against the repo before that read.
    let after = fresh.op_log(None).unwrap();
    assert_eq!(after.len(), before + 1, "only the read's own snapshot");
    assert!(after[0].is_snapshot);
}

/// A revset parse diagnostic is recorded under the CLI's context line: the caller's text under
/// "In `--show-changes-in`", the config's under "In `revsets.op-diff-changes-in`".
#[test]
fn op_show_records_the_show_changes_in_diagnostics_under_their_context() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let diagnosed = r#"diff_contains("x")"#;
    let diagnostics = |repo: &mut Repo| -> Vec<String> {
        repo.take_warnings()
            .into_iter()
            .filter(|w| w.kind == WarningKind::RevsetDiagnostic)
            .map(|w| w.message)
            .collect()
    };

    repo.op_show("@", Some(diagnosed)).unwrap();
    let caller = diagnostics(&mut repo);
    assert_eq!(caller.len(), 1, "{caller:?}");
    assert!(caller[0].starts_with("In `--show-changes-in`\n"), "{caller:?}");

    zanshin_jj::config_set(
        Some(&fx.path),
        &ConfigTarget::Scope(ConfigScope::Repo),
        "revsets.op-diff-changes-in",
        diagnosed,
    )
    .result
    .expect("set the repo config");
    repo.op_show("@", None).unwrap();
    let config = diagnostics(&mut repo);
    assert_eq!(config.len(), 1, "{config:?}");
    assert!(config[0].starts_with("In `revsets.op-diff-changes-in`\n"), "{config:?}");
}

/// `op diff --op @` of a merge operation merges its two parents as the CLI does: both are `from`,
/// and since the merge op only reconciles them, no commit changed against their merge. The two
/// branches describe unrelated leaves, so the merge rebases nothing: with rebased descendants the
/// pinned CLI itself can fail here ("Internal error: Predecessors cycle detected", in
/// jj-lib's `accumulate_predecessors`), and Zanshin runs the same jj-lib code.
#[test]
fn op_diff_of_a_merge_operation_diffs_against_its_merged_parents() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    diverge_with(&fx.path, ("description(exact:'Commit 3')", "@"));
    let mut repo = Repo::open(&fx.path).unwrap();
    let merge = repo.op_show("@", None).unwrap().operation;
    assert_eq!(merge.parent_ids.len(), 2);

    let result = repo
        .op_diff(&OpDiffOptions {
            operation: Some("@".to_owned()),
            ..Default::default()
        })
        .unwrap();

    let mut from: Vec<String> = result.from.iter().map(|op| op.id.0.clone()).collect();
    let mut parents: Vec<String> = merge.parent_ids.iter().map(|id| id.0.clone()).collect();
    from.sort();
    parents.sort();
    assert_eq!(from, parents);
    assert_eq!(result.to.id, merge.id);
    assert!(commits(&result.diff).changes.is_empty(), "{:?}", result.diff);
}

/// `op diff --op <root>`: the root has no parents, so `from` is empty (their merge is the root).
#[test]
fn op_diff_of_the_root_operation_has_no_from_operations() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let root = repo.op_log(None).unwrap().pop().unwrap();

    let result = repo
        .op_diff(&OpDiffOptions {
            operation: Some(root.id.0.clone()),
            ..Default::default()
        })
        .unwrap();

    assert!(result.from.is_empty());
    assert_eq!(result.to.id, root.id);
    assert!(commits(&result.diff).changes.is_empty());
}

/// A workspace added in the operation: its working-copy row has no `from`.
#[test]
fn op_show_of_a_workspace_add_has_a_working_copy_row_without_from() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (_second, second_wc) = test_helpers::add_workspace(&fx.path, "second");
    let mut repo = Repo::open(&fx.path).unwrap();

    let diff = repo.op_show("@", None).unwrap().diff.unwrap();

    assert!(
        diff.working_copies.contains(&OpWorkingCopyChange {
            workspace: "second".to_owned(),
            from: None,
            to: Some(CommitId(second_wc)),
        }),
        "{:?}",
        diff.working_copies
    );
}

/// When the merge op rebased descendants (both branches rewrote `Commit 1`'s line), the CLI's
/// `jj op diff --op @` fails in `accumulate_predecessors` — "Internal error: Predecessors cycle
/// detected around commit …" (checked against the pinned CLI); Zanshin reports the same failure.
///
/// The cycle needs `op diff`'s own merge of the two parents (`merge_operations`) to rebase the
/// second branch's commit to the very commit the head load's merge rebased it to: the Git backend
/// stores the committer timestamp in whole seconds, so with the wall clock the two merges agree
/// only within one second and the test flaked whenever a second boundary fell between them (the
/// pinned CLI alike: with the wall clock and a second between the two it prints the diff). The
/// commit timestamp is pinned (`debug.commit-timestamp`, the CLI's `JJ_TIMESTAMP`), so the two
/// rebases always agree.
#[test]
fn op_diff_of_a_rebasing_merge_operation_fails_like_the_cli() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    fs::write(
        fx.path.join(".jj").join("repo").join("config.toml"),
        "debug.commit-timestamp = \"2001-02-03T04:05:06+07:00\"\n",
    )
    .unwrap();
    diverge(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let err = repo
        .op_diff(&OpDiffOptions::default())
        .expect_err("the CLI's internal error");

    assert!(
        matches!(&err, MutateError::Backend(reason) if reason.starts_with("Predecessors cycle detected around commit ")),
        "{err:?}"
    );
}

/// `op show` whose diff cannot be computed: the described commit's Git object is gone, so the
/// `show_changes_in` filter (a description match reads each commit) fails to evaluate — a backend
/// error, as the CLI's `jj op show` fails.
#[test]
fn op_show_whose_diff_fails_reports_the_backend_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (change, _) = one(&mut repo, "description(exact:'Commit 1')");
    repo.describe(change.clone(), "described").unwrap();
    let described = repo.get_change(&change).unwrap().commit_id;
    drop(repo);
    let store = fx.path.join(".jj").join("repo").join("store");
    let git_target = fs::read_to_string(store.join("git_target")).unwrap();
    let hex = &described.0;
    let object = store
        .join(git_target.trim())
        .join("objects")
        .join(&hex[..2])
        .join(&hex[2..]);
    fs::remove_file(&object).unwrap_or_else(|e| panic!("{}: {e}", object.display()));
    let mut repo = Repo::open(&fx.path).unwrap();
    assert!(
        repo.op_show("@", None).unwrap().diff.is_some(),
        "the loads and the unfiltered diff read no commit object"
    );

    let err = repo
        .op_show("@", Some("description(glob:'*')"))
        .expect_err("the diff fails");

    assert!(matches!(err, MutateError::Backend(_)), "{err:?}");
}
