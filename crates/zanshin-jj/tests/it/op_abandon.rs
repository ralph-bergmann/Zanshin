// SPDX-License-Identifier: MIT

//! `Repo::op_abandon` — the CLI's `jj op abandon` @ v0.46.0 (Story 9.21): the range forms, the
//! reparenting and its counts, the three refusals, and the working-copy remap with its warning.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use test_helpers::extract_fixture;
use zanshin_jj::{ChangeId, MutateError, Repo, WarningKind};

/// The op heads on disk, by id.
fn op_heads(root: &Path) -> BTreeSet<String> {
    fs::read_dir(root.join(".jj").join("repo").join("op_heads").join("heads"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

/// Describes the working-copy commit `n` times.
fn describe_times(repo: &mut Repo, n: usize) {
    let mut found = None;
    let _ = repo
        .eval_revset("@", |change| {
            found = Some(change.id);
            std::ops::ControlFlow::Break(())
        })
        .unwrap();
    let change: ChangeId = found.unwrap();
    for i in 0..n {
        repo.describe(change.clone(), &format!("described {i}")).unwrap();
    }
}

/// `..@-` abandons everything below the head: the head is reparented onto the root operation,
/// the counts are the CLI's, the working copy follows, and no operation is written or snapshotted.
#[test]
fn op_abandon_up_to_the_head_s_parent_reparents_the_head_onto_the_root() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    describe_times(&mut repo, 2);
    let before = repo.op_log(None).unwrap();
    let root = before.last().unwrap().id.clone();
    let _ = repo.take_precondition();

    let result = repo.op_abandon("..@-").unwrap();

    assert!(!result.nothing_changed);
    assert_eq!(result.reparented_count, 1, "the head");
    assert_eq!(
        result.abandoned_count,
        (before.len() - 2) as u64,
        "all but the head and the root"
    );
    assert!(repo.take_precondition().is_none(), "no pre-verb snapshot");
    assert!(repo.take_warnings().is_empty());
    let after = repo.op_log(None).unwrap();
    assert_eq!(after.len(), 2, "the rewritten head, then the root");
    assert_eq!(
        after[0].parent_ids,
        [root],
        "the newest entry's parent is the root operation"
    );
    assert_eq!(after[0].description, before[0].description);
    assert_eq!(result.head_op_ids, [after[0].id.clone()]);
    assert_eq!(op_heads(&fx.path), BTreeSet::from([after[0].id.0.clone()]));

    // The working copy was remapped to the new head: the next verb does not find it stale.
    describe_times(&mut repo, 1);
}

/// A range that is already empty changes nothing — the CLI's "Nothing changed.".
#[test]
fn op_abandon_of_an_empty_range_changes_nothing() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    describe_times(&mut repo, 1);
    repo.op_abandon("..@-").unwrap();
    let heads = op_heads(&fx.path);

    let result = repo.op_abandon("..@-").unwrap();

    assert!(result.nothing_changed);
    assert_eq!((result.abandoned_count, result.reparented_count), (0, 0));
    assert_eq!(result.head_op_ids.len(), 1);
    assert_eq!(op_heads(&fx.path), heads);
}

/// A single operation abandons just it: its child is reparented onto its parent.
#[test]
fn op_abandon_of_one_operation_reparents_its_descendants() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    describe_times(&mut repo, 2);
    let before = repo.op_log(None).unwrap();

    let result = repo.op_abandon(&before[1].id.0).unwrap();

    assert_eq!((result.abandoned_count, result.reparented_count), (1, 1));
    let after = repo.op_log(None).unwrap();
    assert_eq!(after.len(), before.len() - 1);
    assert_eq!(after[0].parent_ids, [before[2].id.clone()]);
}

/// The refusals, none of which touches the op heads: the current operation (alone, with the
/// CLI's hint), a range ending at it or open-ended (`X..` = the current heads), the root operation,
/// an unknown id.
#[test]
fn op_abandon_refusals_leave_the_op_heads_alone() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    describe_times(&mut repo, 1);
    let ops = repo.op_log(None).unwrap();
    let head = ops[0].id.0.clone();
    let root = ops.last().unwrap().id.0.clone();
    let heads = op_heads(&fx.path);

    for current in ["@", "..@", "@-..", &head[..]] {
        let err = repo.op_abandon(current).expect_err("the current operation");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, hints }
                if *reason == format!("Cannot abandon the current operation {}", &head[..12])
                    && hints == &["Run `jj undo` to revert the current operation, then use `jj op abandon`"]),
            "{current}: {err:?}"
        );
    }
    let err = repo.op_abandon(&root).expect_err("the root");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "Cannot abandon the root operation"),
        "{err:?}"
    );
    let err = repo.op_abandon("ffffffffffff").expect_err("unknown");
    assert!(matches!(err, MutateError::OperationNotFound { .. }), "{err:?}");
    let err = repo.op_abandon("..zz").expect_err("not hex");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    assert_eq!(op_heads(&fx.path), heads);
}

/// With two op heads `@` is ambiguous (no repo is loaded, so nothing merges them): the CLI's
/// hint names both; a merge operation below the head is refused.
#[test]
fn op_abandon_with_divergent_heads_and_of_a_merge_operation() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    crate::op_show_diff::diverge(&fx.path);
    let heads = op_heads(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let err = repo.op_abandon("@").expect_err("two heads");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. }
            if reason == r#"The "@" expression resolved to more than one operation"#),
        "{err:?}"
    );
    let hints = err.hints();
    assert_eq!(hints.len(), 1);
    assert!(
        hints[0].starts_with("Try specifying one of the operations by ID: "),
        "{hints:?}"
    );
    for head in &heads {
        assert!(hints[0].contains(&head[..12]), "{hints:?}");
    }
    assert_eq!(op_heads(&fx.path), heads);
    // A range ending at one of two heads: refused, without the one-head hint.
    let first = heads.iter().next().unwrap();
    let err = repo.op_abandon(&format!("..{first}")).expect_err("a current head");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, hints }
            if *reason == format!("Cannot abandon the current operation {}", &first[..12]) && hints.is_empty()),
        "{err:?}"
    );
    assert_eq!(op_heads(&fx.path), heads);

    // A verb merges the heads into a two-parent operation, then writes on top of it.
    describe_times(&mut repo, 1);
    let ops = repo.op_log(None).unwrap();
    let merge = ops.iter().find(|op| op.parent_ids.len() == 2).expect("the merge op");
    let err = repo.op_abandon(&merge.id.0).expect_err("a merge op");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "Cannot abandon a merge operation"),
        "{err:?}"
    );
}

/// From a workspace whose working copy is recorded at an operation that is not a head, the heads
/// are rewritten and the working copy is left — the CLI's warning.
#[test]
fn op_abandon_warns_when_the_working_copy_operation_is_not_a_head() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (second, _second_wc) = test_helpers::add_workspace(&fx.path, "second");
    let mut repo = Repo::open(&fx.path).unwrap();
    describe_times(&mut repo, 2);
    let head = repo.op_log(Some(1)).unwrap().swap_remove(0).id.0;
    drop(repo);
    let mut from_second = Repo::open(&second.path).unwrap();

    let result = from_second.op_abandon("..@-").unwrap();

    assert!(!result.nothing_changed);
    let warnings = from_second.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::OpAbandonWorkingCopyNotUpdated);
    assert!(
        warnings[0].message.starts_with("The working copy operation ")
            && warnings[0].message.ends_with(&format!(
                " is not updated because it differs from the repo {}.",
                &head[..12]
            )),
        "{}",
        warnings[0].message
    );
}

/// A bounded range `<op>..@-`: the operations above `<op>` up to `@-` are abandoned, the head is
/// reparented onto `<op>`, and the working copy is recorded at the new head.
#[test]
fn op_abandon_of_a_bounded_range_reparents_the_head_onto_its_start() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    describe_times(&mut repo, 3);
    let before = repo.op_log(None).unwrap();
    let start = before[3].id.clone();

    let result = repo.op_abandon(&format!("{}..@-", start.0)).unwrap();

    assert_eq!((result.abandoned_count, result.reparented_count), (2, 1));
    let after = repo.op_log(None).unwrap();
    assert_eq!(after[0].parent_ids, [start]);
    assert_eq!(after.len(), before.len() - 2);
    assert_eq!(result.head_op_ids, [after[0].id.clone()]);
    assert_eq!(working_copy_op(&fx.path), result.head_op_ids[0].0);
}

/// The operation the workspace at `root` records its working copy at, as hex.
fn working_copy_op(root: &Path) -> String {
    let workspace = jj_lib::workspace::Workspace::load(
        &test_helpers::test_settings(),
        root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load the workspace");
    jj_lib::object_id::ObjectId::hex(workspace.working_copy().operation_id())
}

/// Two heads, the working copy at the one the range leaves alone: the CLI finds it among the
/// head pairs, unchanged or not, and records it there — no warning.
#[test]
fn op_abandon_keeps_quiet_when_the_working_copy_is_at_an_unchanged_head() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let heads_dir = fx.path.join(".jj").join("repo").join("op_heads").join("heads");
    let head = |repo: &mut Repo| repo.op_log(Some(1)).unwrap().swap_remove(0).id.0;
    let mut repo = Repo::open(&fx.path).unwrap();
    let base = head(&mut repo);
    let commit = |repo: &mut Repo, revset: &str| {
        let mut found = None;
        let _ = repo.eval_revset(revset, |change| {
            found = Some(change.id);
            std::ops::ControlFlow::Break(())
        });
        found.expect("the revset names a commit")
    };
    let c1 = commit(&mut repo, "description(exact:'Commit 1')");
    let c3 = commit(&mut repo, "description(exact:'Commit 3')");
    repo.describe(c1.clone(), "A1").unwrap();
    let a1 = head(&mut repo);
    repo.describe(c1, "A2").unwrap();
    let a2 = head(&mut repo);
    drop(repo);
    fs::remove_file(heads_dir.join(&a2)).unwrap();
    fs::write(heads_dir.join(&base), "").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    repo.describe(c3, "B").unwrap();
    let b = head(&mut repo);
    drop(repo);
    fs::write(heads_dir.join(&a2), "").unwrap();
    assert_eq!(
        working_copy_op(&fx.path),
        b,
        "the working copy is at the second branch's head"
    );
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.op_abandon(&a1).unwrap();

    assert!(!result.nothing_changed);
    assert!(
        result.head_op_ids.contains(&zanshin_jj::OperationId(b.clone())),
        "b is left alone"
    );
    assert!(repo.take_warnings().is_empty(), "the working copy is at a head");
    assert_eq!(working_copy_op(&fx.path), b);
}
