// SPDX-License-Identifier: MIT

//! `Repo::redo` — the CLI's `jj redo` @ v0.46.0 (Story 9.21): its redo stack, its two refusals and
//! the no-change gate it shares with `undo` (Story 9.40).

use std::path::Path;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use test_helpers::extract_fixture;
use zanshin_jj::{ChangeId, MutateError, Repo};

/// The change id of the fixture's `Commit 1`.
fn commit1(repo: &mut Repo) -> ChangeId {
    let mut found = None;
    let _ = repo
        .eval_revset("description(exact:'Commit 1')", |change| {
            found = Some(change.id);
            std::ops::ControlFlow::Break(())
        })
        .expect("Commit 1 resolves");
    found.expect("the fixture has Commit 1")
}

/// The head operation's id and description.
fn head(repo: &mut Repo) -> (String, String) {
    let op = repo.op_log(Some(1)).unwrap().swap_remove(0);
    (op.id.0, op.description)
}

/// Commits an operation described `description` on top of the head — no view change and no
/// workspace recorded, the shape of an operation another tool (the CLI) wrote.
fn foreign_op(root: &Path, description: &str) -> String {
    let workspace = test_helpers::load_workspace(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let repo = pollster::block_on(workspace.load_at_head()).expect("oracle load_at_head");
    let repo = pollster::block_on(repo.start_transaction().commit(description)).expect("commit the foreign op");
    repo.op_id().hex()
}

/// `describe`, `undo`, `redo`: the undone describe is back, recorded as
/// `redo: restore to operation <the describe>`.
#[test]
fn redo_after_undo_restores_the_undone_operation() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = commit1(&mut repo);
    repo.describe(target.clone(), "described").unwrap();
    let (described, _) = head(&mut repo);
    repo.undo(false).unwrap();
    assert_eq!(repo.get_change(&target).unwrap().description, "Commit 1");

    let result = repo.redo(false).unwrap();

    let (redo_op, description) = head(&mut repo);
    assert_eq!(result.new_op_id.0, redo_op);
    assert_eq!(description, format!("redo: restore to operation {described}"));
    assert_eq!(repo.get_change(&target).unwrap().description, "described");
}

/// The CLI comment's example: `undo, undo, redo, redo` walks back two steps and forward two —
/// each redo one step; a third finds nothing left to redo.
#[test]
fn redo_twice_after_two_undos_goes_forward_one_step_each() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = commit1(&mut repo);
    let description = |repo: &mut Repo| repo.get_change(&target).unwrap().description;
    repo.describe(target.clone(), "A").unwrap();
    repo.describe(target.clone(), "B").unwrap();
    let (op_b, _) = head(&mut repo);
    repo.undo(false).unwrap();
    let (first_undo, _) = head(&mut repo);
    repo.undo(false).unwrap();
    assert_eq!(description(&mut repo), "Commit 1");

    repo.redo(false).unwrap();
    assert_eq!(description(&mut repo), "A", "the 1st redo undoes the 2nd undo");
    assert_eq!(head(&mut repo).1, format!("redo: restore to operation {first_undo}"));

    repo.redo(false).unwrap();
    assert_eq!(description(&mut repo), "B", "the 2nd redo undoes the 1st undo");
    assert_eq!(head(&mut repo).1, format!("redo: restore to operation {op_b}"));

    let before = repo.op_log(None).unwrap().len();
    assert!(matches!(repo.redo(false), Err(MutateError::NothingToRedo)));
    assert_eq!(repo.op_log(None).unwrap().len(), before, "a refusal writes nothing");
}

/// `undo, redo, undo, redo`: the second redo's parent is the first redo, so it restores that
/// redo's ORIGINAL operation — redos never form a linked list.
#[test]
fn redo_whose_parent_is_a_redo_restores_its_original_operation() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = commit1(&mut repo);
    repo.describe(target.clone(), "A").unwrap();
    let (op_a, _) = head(&mut repo);
    repo.undo(false).unwrap();
    repo.redo(false).unwrap();
    repo.undo(false).unwrap();

    repo.redo(false).unwrap();

    assert_eq!(head(&mut repo).1, format!("redo: restore to operation {op_a}"));
    assert_eq!(repo.get_change(&target).unwrap().description, "A");
}

/// A head that is no undo operation (nor a redo of one): the CLI's "Nothing to redo".
#[test]
fn redo_without_an_undo_is_nothing_to_redo() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = commit1(&mut repo);
    repo.describe(target, "described").unwrap();
    let before = repo.op_log(None).unwrap().len();

    let err = repo.redo(false).expect_err("nothing to redo");

    assert!(matches!(err, MutateError::NothingToRedo), "{err:?}");
    assert_eq!(err.to_string(), "Nothing to redo");
    assert!(err.hints().is_empty());
    assert_eq!(repo.op_log(None).unwrap().len(), before, "a refusal writes nothing");
}

/// An undo another tool wrote: the view of the operation `to`, committed as
/// `undo: restore to operation <to>`.
fn foreign_undo(root: &Path, to: &str) {
    let workspace = test_helpers::load_workspace(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let loader = workspace.repo_loader();
    let repo = pollster::block_on(loader.load_at_head(Some(workspace.workspace_name()))).expect("oracle load_at_head");
    let id = jj_lib::op_store::OperationId::try_from_hex(to).expect("hex");
    let op = pollster::block_on(loader.load_operation(&id)).expect("the operation");
    let view = pollster::block_on(op.view()).expect("its view");
    let mut tx = repo.start_transaction();
    tx.repo_mut().set_view(view.store_view().clone());
    pollster::block_on(tx.commit(format!("undo: restore to operation {to}"))).expect("commit the foreign undo");
}

/// The stack lives in the descriptions: an undo another tool (the CLI) wrote is redone here, and
/// after a redo that tool wrote there is nothing left to redo, as in the CLI.
#[test]
fn redo_continues_a_stack_another_tool_wrote() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = commit1(&mut repo);
    let (before_a, _) = head(&mut repo);
    repo.describe(target.clone(), "A").unwrap();
    let (op_a, _) = head(&mut repo);
    foreign_undo(&fx.path, &before_a);
    assert_eq!(repo.get_change(&target).unwrap().description, "Commit 1");

    repo.redo(false).unwrap();
    assert_eq!(repo.get_change(&target).unwrap().description, "A");
    assert_eq!(head(&mut repo).1, format!("redo: restore to operation {op_a}"));

    foreign_op(&fx.path, &format!("redo: restore to operation {op_a}"));
    assert!(matches!(repo.redo(false), Err(MutateError::NothingToRedo)));
}

/// A foreign undo whose parent's view equals the current one: the restored view is equal, so —
/// as `undo` (Story 9.40) — no operation is written and the result carries the pre-call head.
#[test]
fn redo_restoring_an_equal_view_writes_no_operation() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (head_before, _) = head(&mut repo);
    foreign_op(&fx.path, &format!("undo: restore to operation {head_before}"));
    let (foreign, _) = head(&mut repo);
    let before = repo.op_log(None).unwrap().len();

    let result = repo.redo(false).unwrap();

    assert_eq!(result.new_op_id.0, foreign, "the pre-call head");
    assert_eq!(repo.op_log(None).unwrap().len(), before, "nothing written");
}

/// An undo performed in another workspace is not redone unless allowed — and is redone when it
/// is.
#[test]
fn redo_refuses_an_undo_of_another_workspace_unless_allowed() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = commit1(&mut repo);
    let (second, _second_wc) = test_helpers::add_workspace(&fx.path, "second");
    let mut from_second = Repo::open(&second.path).unwrap();
    from_second.describe(target.clone(), "in second").unwrap();
    from_second.undo(false).unwrap();
    let (undo, _) = head(&mut from_second);
    drop(from_second);
    let before = repo.op_log(None).unwrap().len();

    let err = repo.redo(false).expect_err("another workspace's undo");

    assert!(
        matches!(&err, MutateError::RedoCrossWorkspace { operation, workspace }
            if *operation == undo[..12] && workspace == "second"),
        "{err:?}"
    );
    assert_eq!(
        err.hints(),
        ["Use `--allow-cross-workspace` to redo it anyway, or use `jj op revert` to revert a specific undo operation"]
    );
    assert_eq!(repo.op_log(None).unwrap().len(), before, "a refusal writes nothing");

    repo.redo(true).expect("allowed");
    assert_eq!(repo.get_change(&target).unwrap().description, "in second");
}

/// A redo or undo description whose id does not parse is the CLI's internal error.
#[test]
fn redo_of_an_unparseable_stack_description_is_a_backend_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    foreign_op(&fx.path, "redo: restore to operation not-an-id");
    let err = repo.redo(false).expect_err("unparseable");
    assert!(
        matches!(&err, MutateError::Backend(reason) if reason == "Failed to parse ID of target operation in redo-stack"),
        "{err:?}"
    );

    // An undo whose parent is that broken redo.
    let (broken, _) = head(&mut repo);
    foreign_op(&fx.path, &format!("undo: restore to operation {broken}"));
    let err = repo.redo(false).expect_err("unparseable parent");
    assert!(
        matches!(&err, MutateError::Backend(reason) if reason == "Failed to parse ID of target operation's parent in redo-stack"),
        "{err:?}"
    );
}

/// An undo operation with two parents is the CLI's internal error "Undo operation should have a
/// single parent" — built here by merging two divergent heads under an undo description.
#[test]
fn redo_of_an_undo_with_two_parents_is_a_backend_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    crate::op_show_diff::diverge(&fx.path);
    let workspace = test_helpers::load_workspace(
        &test_helpers::test_settings(),
        &fx.path,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let loader = workspace.repo_loader();
    let heads = pollster::block_on(jj_lib::op_walk::get_current_head_ops(
        loader.op_store(),
        loader.op_heads_store().as_ref(),
    ))
    .expect("the two heads");
    assert_eq!(heads.len(), 2);
    let old_ids: Vec<_> = heads.iter().map(|op| op.id().clone()).collect();
    let description = format!("undo: restore to operation {}", old_ids[0].hex());
    let (merged, _) = pollster::block_on(loader.merge_operations(heads, None, Some(&description), Vec::new()))
        .expect("merge the heads as an undo");
    pollster::block_on(loader.op_heads_store().update_op_heads(&old_ids, merged.op_id())).expect("publish it");
    let mut repo = Repo::open(&fx.path).unwrap();

    let err = repo.redo(false).expect_err("two parents");

    assert!(
        matches!(&err, MutateError::Backend(reason) if reason == "Undo operation should have a single parent"),
        "{err:?}"
    );
}
