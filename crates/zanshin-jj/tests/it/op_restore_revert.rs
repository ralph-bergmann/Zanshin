// SPDX-License-Identifier: MIT

//! `Repo::op_restore` / `Repo::op_revert` — the CLI's `jj op restore` / `jj op revert` @ v0.46.0
//! (Story 9.12): their `--what` portions, the no-change gate (Story 9.40), revert's three-way merge
//! with its descendant rebase, and the refusals, none of which touches the op heads.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::{RefTarget, RemoteRef, RemoteRefState, View};
use jj_lib::ref_name::{RefNameBuf, RemoteNameBuf, RemoteRefSymbol};
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;
use test_helpers::extract_fixture;
use zanshin_jj::{Change, MutateError, Repo, RestoreWhat, WarningKind};

/// The one change `revset` names.
fn one(repo: &mut Repo, revset: &str) -> Change {
    let mut found = None;
    let _ = repo
        .eval_revset(revset, |change| {
            found = Some(change.id);
            std::ops::ControlFlow::Break(())
        })
        .expect("the revset resolves");
    repo.get_change(&found.expect("the revset names a change")).unwrap()
}

/// The head operation's id and description.
fn head(repo: &mut Repo) -> (String, String) {
    let op = repo.op_log(Some(1)).unwrap().swap_remove(0);
    (op.id.0, op.description)
}

/// The op heads on disk, by id.
fn op_heads(root: &Path) -> BTreeSet<String> {
    fs::read_dir(root.join(".jj").join("repo").join("op_heads").join("heads"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

/// The view of the operation `op` (hex), read through jj-lib.
fn view_at(root: &Path, op: &str) -> View {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let id = jj_lib::op_store::OperationId::try_from_hex(op).expect("hex");
    let op = pollster::block_on(workspace.repo_loader().load_operation(&id)).expect("the operation");
    pollster::block_on(op.view()).expect("its view").store_view().clone()
}

/// Describes `Commit 1` as `A`, `B`, `C`; returns the three operations' ids, oldest first.
fn three_describes(repo: &mut Repo) -> [String; 3] {
    let target = one(repo, "description(exact:'Commit 1')").id;
    ["A", "B", "C"].map(|text| {
        repo.describe(target.clone(), text).unwrap();
        head(repo).0
    })
}

/// `op restore @--` after three describes: the view of the first describe is back, committed as
/// `restore to operation <that op>`; `git_refs` / `git_heads` stay at the current values.
#[test]
fn op_restore_to_an_earlier_operation_restores_its_view() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = one(&mut repo, "description(exact:'Commit 1')").id;
    let [a, _, c] = three_describes(&mut repo);

    let result = repo.op_restore("@--", &[]).unwrap();

    let (restore_op, description) = head(&mut repo);
    assert_eq!(result.new_op_id.0, restore_op);
    assert_eq!(description, format!("restore to operation {a}"));
    assert_eq!(repo.get_change(&target).unwrap().description, "A");
    let (restored, target, before) = (
        view_at(&fx.path, &restore_op),
        view_at(&fx.path, &a),
        view_at(&fx.path, &c),
    );
    assert_eq!(restored.head_ids, target.head_ids);
    assert_eq!(restored.wc_commit_ids, target.wc_commit_ids);
    assert_eq!(restored.git_refs, before.git_refs, "git refs stay current");
    assert_eq!(restored.git_heads, before.git_heads, "git heads stay current");
}

/// `op restore @`: the view is the current one, so — Story 9.40 — no operation and the pre-call
/// head.
#[test]
fn op_restore_of_the_current_operation_writes_nothing() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let [_, _, c] = three_describes(&mut repo);
    let before = repo.op_log(None).unwrap().len();

    let result = repo.op_restore("@", &[RestoreWhat::Repo]).unwrap();

    assert_eq!(result.new_op_id.0, c);
    assert_eq!(repo.op_log(None).unwrap().len(), before, "nothing written");
}

/// Every file of the working copy at `root` (`.jj` / `.git` left out), with its content.
fn working_copy_files(root: &Path) -> BTreeMap<String, Vec<u8>> {
    fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<String, Vec<u8>>) {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let name = path.strip_prefix(root).unwrap().to_string_lossy().into_owned();
            if name == ".jj" || name == ".git" {
                continue;
            }
            if path.is_dir() {
                walk(root, &path, out);
            } else {
                out.insert(name, fs::read(&path).unwrap());
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}

/// `op restore` of the root operation: its view — the root commit only, no working copy — is
/// committed and the files on disk are left untouched; a later verb that changes nothing reports
/// no `@`, one that writes does not warn again, and `undo` brings `@` back.
#[test]
fn op_restore_to_the_root_operation_writes_its_view() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let root = repo.op_log(None).unwrap().pop().unwrap().id.0;
    let files = working_copy_files(&fx.path);

    let result = repo.op_restore("000000000000", &[]).unwrap();
    let warnings = repo.take_warnings();
    assert_eq!(
        working_copy_files(&fx.path),
        files,
        "the working copy was left untouched"
    );

    let (restore_op, description) = head(&mut repo);
    assert_eq!(result.new_op_id.0, restore_op);
    assert_eq!(description, format!("restore to operation {root}"));
    assert_eq!(
        result.working_copy_change_id, None,
        "the root view records no working copy"
    );
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::WorkspaceNoLongerExists);
    assert_eq!(
        warnings[0].message,
        "The current workspace 'default' no longer exists after this operation. The working copy was left untouched."
    );
    let restored = view_at(&fx.path, &restore_op);
    assert_eq!(restored.head_ids, view_at(&fx.path, &root).head_ids);
    assert!(restored.wc_commit_ids.is_empty());

    let no_change = repo.bookmark_delete(&["nope".to_owned()]).expect("nothing to delete");
    assert_eq!(no_change.new_op_id.0, restore_op, "nothing written");
    assert_eq!(no_change.working_copy_change_id, None);

    // `@` is absent before AND after: the warning is the CLI's for a LOST `@` only.
    let root_change = one(&mut repo, "root()");
    let written = repo
        .bookmark_create(&["x".to_owned()], Some(&root_change.id))
        .expect("a verb that writes without `@`");
    assert_ne!(written.new_op_id.0, restore_op, "an operation was written");
    assert_eq!(written.working_copy_change_id, None);
    let warnings = repo.take_warnings();
    assert!(
        warnings.iter().all(|w| w.kind != WarningKind::WorkspaceNoLongerExists),
        "{warnings:?}"
    );

    let undone = repo.undo(false).expect("undo the bookmark");
    assert!(undone.working_copy_change_id.is_none(), "still the root view");
    let undone = repo.undo(false).expect("undo the restore");
    assert!(undone.working_copy_change_id.is_some(), "`@` is back");
}

/// A remote-tracking bookmark set after the target: `--what repo` keeps it (only the repo
/// portion is restored), `--what remote-tracking` drops it and keeps the later describe.
#[test]
fn op_restore_what_restores_only_the_chosen_portion() {
    test_helpers::pin_test_env();
    for what in [RestoreWhat::Repo, RestoreWhat::RemoteTracking] {
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let mut repo = Repo::open(&fx.path).unwrap();
        let (target_op, _) = head(&mut repo);
        let c1 = one(&mut repo, "description(exact:'Commit 1')");
        repo.describe(c1.id.clone(), "later").unwrap();
        test_helpers::set_remote_bookmark(&fx.path, "main", "origin", &c1.commit_id.0, true);
        let (current, _) = head(&mut repo);

        repo.op_restore(&target_op, &[what]).unwrap();

        let (restore_op, _) = head(&mut repo);
        let (restored, target, before) = (
            view_at(&fx.path, &restore_op),
            view_at(&fx.path, &target_op),
            view_at(&fx.path, &current),
        );
        let (repo_source, remote_source) = match what {
            RestoreWhat::Repo => (&target, &before),
            RestoreWhat::RemoteTracking => (&before, &target),
        };
        assert_eq!(restored.head_ids, repo_source.head_ids, "{what:?}");
        assert_eq!(restored.local_bookmarks, repo_source.local_bookmarks, "{what:?}");
        assert_eq!(restored.remote_views, remote_source.remote_views, "{what:?}");
        assert_ne!(
            target.remote_views, before.remote_views,
            "the fixture differs in the remote portion"
        );
    }
}

/// Unknown or malformed operations are the opset errors; neither writes anything beyond the
/// snapshot — the op heads stay.
#[test]
fn op_restore_and_op_revert_of_an_unknown_operation_refuse() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    three_describes(&mut repo);
    let heads = op_heads(&fx.path);

    for result in [
        repo.op_restore("ffffffffffff", &[]),
        repo.op_revert("ffffffffffff", &[]),
    ] {
        let err = result.expect_err("unknown");
        assert!(
            matches!(&err, MutateError::OperationNotFound { reason } if reason == r#"No operation ID matching "ffffffffffff""#),
            "{err:?}"
        );
    }
    for result in [repo.op_restore("zz", &[]), repo.op_revert("zz", &[])] {
        let err = result.expect_err("not hex");
        assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    }
    assert_eq!(op_heads(&fx.path), heads);
}

/// `op revert @` after a describe: the describe is undone, committed as
/// `revert operation <the describe>`.
#[test]
fn op_revert_of_the_head_reverts_it() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = one(&mut repo, "description(exact:'Commit 1')").id;
    repo.describe(target.clone(), "described").unwrap();
    let (described, _) = head(&mut repo);

    let result = repo.op_revert("@", &[]).unwrap();

    let (revert_op, description) = head(&mut repo);
    assert_eq!(result.new_op_id.0, revert_op);
    assert_eq!(description, format!("revert operation {described}"));
    assert_eq!(repo.get_change(&target).unwrap().description, "Commit 1");
}

/// Reverting an earlier operation keeps the later work: describe `@`, `new` on it, revert the
/// describe — `@-` gets its old description back and the new `@` is rebased onto it.
#[test]
fn op_revert_of_an_earlier_operation_rebases_the_later_work() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = one(&mut repo, "@");
    repo.describe(wc.id.clone(), "described").unwrap();
    repo.new_change(std::slice::from_ref(&wc.id), &[], &[]).unwrap();
    let new_wc = one(&mut repo, "@");

    repo.op_revert("@-", &[]).unwrap();

    let parent = repo.get_change(&wc.id).unwrap();
    assert_eq!(parent.description, wc.description, "the describe is reverted");
    let child = one(&mut repo, "@");
    assert_eq!(child.id, new_wc.id, "the later `new` stays");
    assert_eq!(child.parents, [wc.id], "rebased onto the reverted commit");
    assert_eq!(one(&mut repo, "@-").commit_id, parent.commit_id);
}

/// Reverting an operation whose effect is already gone — a bookmark created, then deleted —
/// changes nothing: no operation, the pre-call head (Story 9.40).
#[test]
fn op_revert_of_an_operation_whose_effect_is_gone_writes_nothing() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    repo.bookmark_create(&["feature".to_owned()], None).unwrap();
    let (created, _) = head(&mut repo);
    repo.bookmark_delete(&["feature".to_owned()]).unwrap();
    let (deleted, _) = head(&mut repo);
    let before = repo.op_log(None).unwrap().len();

    let result = repo.op_revert(&created, &[]).unwrap();

    assert_eq!(result.new_op_id.0, deleted, "the pre-call head");
    assert_eq!(repo.op_log(None).unwrap().len(), before, "nothing written");
}

/// Reverting a describe twice: the second merge still records the rewrite of the described
/// commit into the original one, so — exactly as the CLI (oracle `op_revert_twice`) — it writes
/// an operation, with the description unchanged.
#[test]
fn op_revert_of_a_describe_twice_writes_a_second_operation_like_the_cli() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = one(&mut repo, "description(exact:'Commit 1')").id;
    repo.describe(target.clone(), "described").unwrap();
    let (described, _) = head(&mut repo);
    repo.op_revert(&described, &[]).unwrap();
    let (first_revert, _) = head(&mut repo);

    let result = repo.op_revert(&described, &[]).unwrap();

    assert_ne!(result.new_op_id.0, first_revert);
    assert_eq!(head(&mut repo).1, format!("revert operation {described}"));
    assert_eq!(repo.get_change(&target).unwrap().description, "Commit 1");
}

/// Commits ONE operation (through jj-lib, as another tool would) that points the local bookmark
/// `local` and the tracked remote bookmark `main@origin` at the root commit; returns its id.
fn local_and_remote_bookmark_op(root: &Path) -> String {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head");
    let target = RefTarget::normal(repo.store().root_commit_id().clone());
    let mut tx = repo.start_transaction();
    let local: RefNameBuf = "local".into();
    let main: RefNameBuf = "main".into();
    let origin: RemoteNameBuf = "origin".into();
    tx.repo_mut().set_local_bookmark_target(&local, target.clone());
    tx.repo_mut().set_remote_bookmark(
        RemoteRefSymbol {
            name: &main,
            remote: &origin,
        },
        RemoteRef {
            target,
            state: RemoteRefState::Tracked,
        },
    );
    let repo = pollster::block_on(tx.commit("set local and remote bookmarks")).expect("commit");
    repo.op_id().hex()
}

/// One operation that changed both portions: `--what repo` reverts its local bookmark and keeps
/// the remote-tracking one at the head's, `--what remote-tracking` the converse.
#[test]
fn op_revert_what_reverts_only_the_chosen_portion() {
    test_helpers::pin_test_env();
    for what in [RestoreWhat::Repo, RestoreWhat::RemoteTracking] {
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let mut repo = Repo::open(&fx.path).unwrap();
        let both = local_and_remote_bookmark_op(&fx.path);

        repo.op_revert(&both, &[what]).unwrap();

        let (revert_op, description) = head(&mut repo);
        assert_eq!(description, format!("revert operation {both}"));
        let (reverted, at_both) = (view_at(&fx.path, &revert_op), view_at(&fx.path, &both));
        let local_kept = reverted.local_bookmarks.contains_key(&RefNameBuf::from("local"));
        assert_eq!(
            local_kept,
            what == RestoreWhat::RemoteTracking,
            "{what:?}: local bookmark"
        );
        let remote_kept = reverted.remote_views == at_both.remote_views;
        assert_eq!(
            remote_kept,
            what == RestoreWhat::Repo,
            "{what:?}: remote-tracking bookmark"
        );
    }
}

/// Reverting the operation that added this workspace drops its `@` from the view: the revert is
/// written, the result has no `@`, and the finish warns that the workspace no longer exists.
#[test]
fn op_revert_of_the_add_workspace_operation_drops_the_working_copy_and_warns() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let ops = repo.op_log(None).unwrap();
    let add_workspace = ops[ops.len() - 2].clone();
    assert_eq!(add_workspace.description, "add workspace 'default'");

    let result = repo.op_revert(&add_workspace.id.0, &[]).unwrap();
    let warnings = repo.take_warnings();

    assert_eq!(result.working_copy_change_id, None);
    assert_eq!(
        warnings.iter().map(|w| w.kind).collect::<Vec<_>>(),
        [WarningKind::WorkspaceNoLongerExists]
    );
    assert_eq!(head(&mut repo).1, format!("revert operation {}", add_workspace.id.0));
}

/// The root operation and a merge operation cannot be reverted — the CLI's two refusals, the op
/// heads untouched.
#[test]
fn op_revert_of_the_root_or_a_merge_operation_refuses() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    crate::op_show_diff::diverge(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = one(&mut repo, "@").id;
    repo.describe(wc, "on the merge").unwrap();
    let ops = repo.op_log(None).unwrap();
    let merge = ops
        .iter()
        .find(|op| op.parent_ids.len() == 2)
        .expect("the merge op")
        .id
        .0
        .clone();
    let heads = op_heads(&fx.path);

    for (operation, reason) in [
        ("000000000000", "Cannot revert root operation"),
        (merge.as_str(), "Cannot revert a merge operation"),
    ] {
        let err = repo.op_revert(operation, &[]).expect_err("refused");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason: r, hints } if r == reason && hints.is_empty()),
            "{operation}: {err:?}"
        );
    }
    assert_eq!(op_heads(&fx.path), heads);
}

/// Restore and revert continue after an operation another tool (the CLI) wrote: the foreign
/// describe is reverted, then restoring to before it is an equal view — no operation.
#[test]
fn op_revert_and_op_restore_after_a_foreign_operation() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before_foreign, _) = head(&mut repo);
    let c1 = one(&mut repo, "description(exact:'Commit 1')");
    let _ = test_helpers::describe_commit(&fx.path, &c1.commit_id.0, "foreign");
    assert_eq!(one(&mut repo, "description(exact:'foreign')").id, c1.id);

    repo.op_revert("@", &[RestoreWhat::Repo, RestoreWhat::RemoteTracking])
        .unwrap();
    assert_eq!(repo.get_change(&c1.id).unwrap().description, "Commit 1");
    let (reverted, _) = head(&mut repo);

    let result = repo.op_restore(&before_foreign, &[]).unwrap();
    assert_eq!(
        result.new_op_id.0, reverted,
        "the restored view equals the reverted one"
    );
}
