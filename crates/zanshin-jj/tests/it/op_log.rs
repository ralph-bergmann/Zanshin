// SPDX-License-Identifier: MIT

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use futures::StreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId;
use jj_lib::op_store::RefTarget;
use jj_lib::op_walk;
use jj_lib::ref_name::GitRefName;
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{ChangeError, ChangeId, MutateError, OpLogError, Repo, WarningKind};

/// Open the fixture as a raw jj-lib `Workspace` for oracle reads.
fn oracle_workspace(root: &Path) -> (Workspace, UserSettings) {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    (workspace, settings)
}

/// `tiny-3-commits`' change ids the undo tests need to target — trimmed copy of
/// `tests/it/mutate.rs`'s `Layout`/`oracle_layout` pattern (see that file for the full
/// fixture-shape comment: root has two unrelated children, `@` and a
/// `Commit 1 -> Commit 2 -> Commit 3` chain). Discovered dynamically (by description,
/// walking every head's ancestry to root) rather than hardcoded.
struct Layout {
    wc_change_id: String,
    commit1_change_id: String,
    commit1_commit_hex: String,
    commit3_change_id: String,
    commit3_commit_hex: String,
}

fn oracle_layout(workspace_root: &Path) -> Layout {
    let (workspace, _settings) = oracle_workspace(workspace_root);
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head");
    let store = repo.store();
    let view = repo.view();

    let wc_id = view
        .get_wc_commit_id(workspace.workspace_name())
        .expect("fixture has a working-copy commit")
        .clone();
    let wc_commit = store.get_commit(&wc_id).unwrap();

    // Map "Commit N" description -> (change id, commit hex) by walking every head's
    // ancestry to root.
    let mut by_desc: HashMap<String, (String, String)> = HashMap::new();
    for head in view.heads() {
        let mut cur = store.get_commit(head).unwrap();
        loop {
            by_desc.insert(
                cur.description().to_owned(),
                (cur.change_id().reverse_hex(), cur.id().hex()),
            );
            let Some(parent_id) = cur.parent_ids().first() else {
                break;
            };
            if parent_id == store.root_commit_id() {
                break;
            }
            cur = store.get_commit(parent_id).unwrap();
        }
    }

    let (commit1_change_id, commit1_commit_hex) = by_desc.get("Commit 1").expect("fixture has Commit 1").clone();
    let (commit3_change_id, commit3_commit_hex) = by_desc.get("Commit 3").expect("fixture has Commit 3").clone();

    Layout {
        wc_change_id: wc_commit.change_id().reverse_hex(),
        commit1_change_id,
        commit1_commit_hex,
        commit3_change_id,
        commit3_commit_hex,
    }
}

// ── AC-3, AC-6: head op first, root op last ──────────────────────────────────

#[test]
fn op_log_on_tiny_returns_history_with_root_op_last() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(None).unwrap();

    assert!(!ops.is_empty(), "op log must be non-empty for any repo");

    let root = ops.last().expect("root op must be last");
    assert!(root.root_op, "last op must be the root (root_op == true)");
    assert!(root.parent_ids.is_empty(), "root op must have empty parent_ids");

    // Head op is first (most recent); root op is last.
    // The head op is not the root op (tiny-3-commits has real commits above it).
    let head = &ops[0];
    assert!(!head.root_op, "head op must not be the root op");
}

// ── AC-4: limit ───────────────────────────────────────────────────────────────

#[test]
fn op_log_with_limit_one_returns_most_recent() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(Some(1)).unwrap();

    assert_eq!(ops.len(), 1, "limit 1 must return exactly one op");
    // The single op returned is the head (most recent), so it must NOT be the root.
    assert!(!ops[0].root_op, "limit-1 result must be the head op, not the root");
}

#[test]
fn op_log_with_limit_zero_returns_empty() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(Some(0)).unwrap();
    assert!(ops.is_empty(), "limit 0 must return empty Vec");
}

#[test]
fn op_log_with_limit_over_count_equals_full_history() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let all = repo.op_log(None).unwrap();
    // A limit larger than the op count must terminate via stream exhaustion
    // (the `out.len() >= n` break never trips), returning the full history.
    let over = repo.op_log(Some(all.len() + 100)).unwrap();

    assert_eq!(
        over.len(),
        all.len(),
        "an over-large limit must return the full history"
    );
    assert_eq!(
        over.iter().map(|o| o.id.0.clone()).collect::<Vec<_>>(),
        all.iter().map(|o| o.id.0.clone()).collect::<Vec<_>>(),
        "an over-large limit must equal op_log(None) op-for-op",
    );
}

// ── AC-5, AC-6: root op shape ─────────────────────────────────────────────────

#[test]
fn op_log_root_op_has_empty_parents_and_root_op_true() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(None).unwrap();
    let root = ops.last().expect("root must exist");

    assert!(root.root_op, "root_op must be true");
    assert!(root.parent_ids.is_empty(), "root parent_ids must be empty");
    assert_eq!(root.description, "", "root op description must be empty");
}

// ── AC-6: non-root op has parents and root_op == false ───────────────────────

#[test]
fn op_log_non_root_op_has_parents_and_root_op_false() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(None).unwrap();
    // The head op (index 0) is a regular operation — it has parents.
    let head = &ops[0];

    assert!(!head.root_op, "head op root_op must be false");
    assert!(!head.parent_ids.is_empty(), "head op must have at least one parent");
}

// ── AC-5: oracle equality for id / description / user / host ─────────────────

#[test]
fn op_log_head_op_matches_oracle() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(None).unwrap();
    let head = &ops[0];

    // Oracle: open the workspace independently with jj-lib and walk to the head op.
    let (oracle_ws, _settings) = oracle_workspace(&fx.path);
    let readonly = pollster::block_on(oracle_ws.repo_loader().load_at_head()).expect("oracle load_at_head");

    let oracle_head = readonly.operation();
    let oracle_md = oracle_head.metadata();

    assert_eq!(head.id.0, oracle_head.id().hex(), "head op id must equal oracle hex");
    assert_eq!(
        head.description, oracle_md.description,
        "head op description must equal oracle"
    );
    assert_eq!(head.user, oracle_md.username, "head op user must equal oracle");
    assert_eq!(head.host, oracle_md.hostname, "head op host must equal oracle");
}

// ── AC-3: reverse-chronological order (compare adjacent timestamps) ──────────

#[test]
fn op_log_is_reverse_chronological() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(None).unwrap();
    assert!(ops.len() >= 2, "need at least 2 ops for ordering check");

    for pair in ops.windows(2) {
        let newer = &pair[0];
        let older = &pair[1];
        assert!(
            newer.timestamp.millis_since_epoch >= older.timestamp.millis_since_epoch,
            "op log must be reverse-chronological: {} < {}",
            newer.timestamp.millis_since_epoch,
            older.timestamp.millis_since_epoch
        );
    }
}

// ── AC-4: limit honours the count across the oracle walk ─────────────────────

#[test]
fn op_log_limit_matches_oracle_head_sequence() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let all_ops = repo.op_log(None).unwrap();
    let total = all_ops.len();
    if total < 3 {
        return; // not enough ops to test limit
    }

    let limit = total - 1;
    let limited = repo.op_log(Some(limit)).unwrap();

    assert_eq!(limited.len(), limit, "limited result must have exactly {limit} ops");
    // The limited slice must be the first `limit` ops of the full log.
    for (i, op) in limited.iter().enumerate() {
        assert_eq!(op.id, all_ops[i].id, "limited op {i} id must match full log");
    }
}

// ── AC-9: oracle walk — all op ids in our log appear in the oracle walk ───────

#[test]
fn op_log_all_ids_match_oracle_walk() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(None).unwrap();

    // Walk the oracle stream and collect ids.
    let (oracle_ws, _settings) = oracle_workspace(&fx.path);
    let readonly = pollster::block_on(oracle_ws.repo_loader().load_at_head()).expect("oracle load_at_head");
    let head_op = readonly.operation().clone();

    let oracle_ids: Vec<String> = pollster::block_on(async {
        let mut stream = Box::pin(op_walk::walk_ancestors(std::slice::from_ref(&head_op)));
        let mut ids = Vec::new();
        while let Some(item) = stream.next().await {
            let op = item.expect("oracle op");
            ids.push(op.id().hex());
        }
        ids
    });

    assert_eq!(
        ops.iter().map(|o| o.id.0.clone()).collect::<Vec<_>>(),
        oracle_ids,
        "our op log ids must match the oracle walk ids in order"
    );
}

// ── AC-7 / Backend error ─────────────────────────────────────────────────────

#[test]
fn op_log_on_corrupt_repo_returns_backend_error() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();

    // Corrupt AFTER open: op_log() re-resolves to head on every call (ADR-0002),
    // so removing op_heads makes load_at_head() fail → OpLogError::Backend.
    let op_heads = tmp.path().join(".jj").join("repo").join("op_heads");
    fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.op_log(None);

    assert!(
        matches!(result, Err(OpLogError::Precondition(zanshin_jj::PreconditionError::Backend(_)))),
        "the pre-verb snapshot fails first (Story 9.26, as the CLI would): corrupt repo must yield Backend error, got: {result:?}"
    );
}

#[test]
fn undo_reverts_a_describe_and_records_op_log_entry() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let target = ChangeId(layout.commit1_change_id.clone());
    let original_description = repo.get_change(&target).unwrap().description;
    let pre_undo_ops = repo.op_log(Some(1)).unwrap();
    let parent_hex = pre_undo_ops[0].id.0.clone();
    let op_count_before_mutation = repo.op_log(None).unwrap().len();

    repo.describe(target.clone(), "New description").unwrap();
    assert_eq!(repo.get_change(&target).unwrap().description, "New description");

    let undo_result = repo.undo(false).unwrap();
    assert!(undo_result.new_change_ids.is_empty());
    assert!(undo_result.abandoned_change_ids.is_empty());

    assert_eq!(
        repo.get_change(&target).unwrap().description,
        original_description,
        "description must revert to its pre-mutation value"
    );

    let ops = repo.op_log(None).unwrap();
    assert_eq!(
        ops.len(),
        op_count_before_mutation + 2,
        "op-log must have grown by exactly 2 new ops: the mutation + the undo (epics.md AC)"
    );
    assert_eq!(ops[0].description, format!("undo: restore to operation {parent_hex}"));
    assert_eq!(
        undo_result.new_op_id, ops[0].id,
        "MutationResult.new_op_id must match the op-log head"
    );
}

#[test]
fn undo_reverts_a_new_change_and_moves_wc_back() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let new_result = repo
        .new_change(&[ChangeId(layout.wc_change_id.clone())], &[], &[])
        .unwrap();
    let new_change_id = new_result.new_change_ids[0].clone();
    assert_eq!(new_result.working_copy_change_id, new_change_id);
    assert!(repo.get_change(&new_change_id).is_ok());

    let undo_result = repo.undo(false).unwrap();
    assert!(undo_result.new_change_ids.is_empty());
    assert!(undo_result.abandoned_change_ids.is_empty());
    assert_eq!(
        undo_result.working_copy_change_id.0, layout.wc_change_id,
        "@ must return to the prior change id"
    );

    assert!(
        matches!(repo.get_change(&new_change_id), Err(ChangeError::NotFound { .. })),
        "the new change must no longer be visible after undo"
    );
}

/// The undo STACK (Story 9.39): a second `undo` goes further back instead of redoing the first —
/// the CLI's own op-log example (`cli/src/commands/undo.rs:79-104` @ v0.46.0): operations A, B,
/// C; undo (restores B); E; undo (restores B again, NOT the first undo); undo (restores A).
#[test]
fn undo_twice_in_a_row_goes_further_back() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = ChangeId(layout.commit1_change_id.clone());
    let head = |repo: &mut Repo| repo.op_log(Some(1)).unwrap().swap_remove(0);
    let description = |repo: &mut Repo| repo.get_change(&target).unwrap().description;

    repo.describe(target.clone(), "A").unwrap();
    let op_a = head(&mut repo).id.0;
    repo.describe(target.clone(), "B").unwrap();
    let op_b = head(&mut repo).id.0;
    repo.describe(target.clone(), "C").unwrap();

    repo.undo(false).unwrap();
    assert_eq!(description(&mut repo), "B", "the 1st undo restores B");
    assert_eq!(
        head(&mut repo).description,
        format!("undo: restore to operation {op_b}")
    );

    repo.describe(target.clone(), "E").unwrap();
    repo.undo(false).unwrap();
    assert_eq!(description(&mut repo), "B", "undoing E restores B again");
    assert_eq!(
        head(&mut repo).description,
        format!("undo: restore to operation {op_b}"),
        "E's parent is an undo, so the restore jumps to the operation IT restored — never a chain of undos"
    );

    repo.undo(false).unwrap();
    assert_eq!(description(&mut repo), "A", "undoing an undo goes one further back");
    assert_eq!(
        head(&mut repo).description,
        format!("undo: restore to operation {op_a}")
    );
}

/// Commits an operation described `description` on top of the head — no view change and no
/// workspace recorded, the shape of an operation another tool wrote. Returns its id.
fn foreign_op(root: &Path, description: &str) -> String {
    let (workspace, _settings) = oracle_workspace(root);
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head");
    let repo = pollster::block_on(repo.start_transaction().commit(description)).expect("commit the foreign op");
    repo.op_id().hex()
}

/// The stack lives in the operation DESCRIPTIONS, so an undo stack another tool (the CLI) started
/// is continued here: a head `undo: restore to operation <A>` makes A the operation to undo.
#[test]
fn undo_continues_an_undo_stack_another_tool_started() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();
    let target = ChangeId(layout.commit1_change_id.clone());
    let before_a = repo.op_log(Some(1)).unwrap().swap_remove(0).id.0;
    repo.describe(target.clone(), "A").unwrap();
    let op_a = repo.op_log(Some(1)).unwrap().swap_remove(0).id.0;
    repo.describe(target.clone(), "B").unwrap();
    foreign_op(&fx.path, &format!("undo: restore to operation {op_a}"));

    repo.undo(false).unwrap();

    assert_eq!(
        repo.op_log(Some(1)).unwrap()[0].description,
        format!("undo: restore to operation {before_a}"),
        "the foreign undo restored A, so this undo undoes A itself"
    );
    assert_eq!(repo.get_change(&target).unwrap().description, "Commit 1");
}

/// A stack that resolves to the op-store ROOT is the CLI's "Cannot undo root operation".
#[test]
fn undo_whose_stack_reaches_the_root_operation_returns_nothing_to_undo() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let root = repo
        .op_log(None)
        .unwrap()
        .into_iter()
        .find(|op| op.root_op)
        .unwrap()
        .id
        .0;
    foreign_op(&fx.path, &format!("undo: restore to operation {root}"));
    let before = repo.op_log(None).unwrap().len();

    let result = repo.undo(false);

    assert!(matches!(result, Err(MutateError::NothingToUndo)), "got: {result:?}");
    assert_eq!(repo.op_log(None).unwrap().len(), before, "a refusal writes nothing");
}

/// An undo description whose id does not parse is the CLI's internal error — on the operation to
/// undo, and on the parent it would restore.
#[test]
fn undo_of_an_unparseable_undo_description_is_a_backend_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();
    foreign_op(&fx.path, "undo: restore to operation not-an-id");

    let result = repo.undo(false);
    assert!(
        matches!(result, Err(MutateError::Backend(ref reason)) if reason == "Failed to parse ID of target operation in undo-stack"),
        "got: {result:?}"
    );

    // A normal operation on top: now the broken undo is the PARENT to restore.
    repo.describe(ChangeId(layout.commit1_change_id.clone()), "on top")
        .unwrap();
    let result = repo.undo(false);
    assert!(
        matches!(result, Err(MutateError::Backend(ref reason)) if reason == "Failed to parse ID of target operation's parent in undo-stack"),
        "got: {result:?}"
    );
}

/// jj 0.46: an operation performed in ANOTHER workspace is not undone unless allowed — and is
/// undone, as before, when it is.
#[test]
fn undo_refuses_an_operation_of_another_workspace_unless_allowed() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let target = ChangeId(layout.commit1_change_id.clone());
    // The handle keeps the second workspace's directory alive for the test's duration.
    let (second, _second_wc) = test_helpers::add_workspace(&fx.path, "second");
    let mut from_second = Repo::open(&second.path).unwrap();
    from_second.describe(target.clone(), "described in second").unwrap();
    let op = from_second.op_log(Some(1)).unwrap().swap_remove(0).id.0;
    drop(from_second);

    let mut repo = Repo::open(&fx.path).unwrap();
    let before = repo.op_log(None).unwrap().len();
    match repo.undo(false) {
        Err(err @ MutateError::UndoCrossWorkspace { .. }) => {
            let MutateError::UndoCrossWorkspace { operation, workspace } = &err else {
                unreachable!()
            };
            assert_eq!(*operation, op[..12], "the CLI's 12-digit short id");
            assert_eq!(workspace, "second");
            // Story 9.56: `undo`'s hint (`undo.rs:129-132` @ v0.46.0).
            assert_eq!(
                err.hints(),
                ["Use `--allow-cross-workspace` to undo it anyway, or use `jj op revert` to revert a specific operation"]
            );
        }
        other => panic!("expected UndoCrossWorkspace, got: {other:?}"),
    }
    assert_eq!(repo.op_log(None).unwrap().len(), before, "a refusal writes nothing");
    assert_eq!(repo.get_change(&target).unwrap().description, "described in second");

    repo.undo(true)
        .expect("allowed, the other workspace's operation is undone");
    assert_eq!(repo.get_change(&target).unwrap().description, "Commit 1");
}

/// Undoing a push warns, as the CLI does; so does undoing a workspace removal. An operation that
/// records no workspace (both foreign ops here) never refuses.
#[test]
fn undo_of_a_push_or_a_workspace_removal_warns() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    for (description, kind, message) in [
        (
            "push bookmark main to origin",
            WarningKind::UndoPushOperation,
            "Undoing a push operation often leads to conflicted bookmarks.",
        ),
        (
            "remove workspace 'second'",
            WarningKind::UndoWorkspaceRemoval,
            "Undoing a workspace removal restores the workspace, but does not restore the workspace directory.",
        ),
    ] {
        foreign_op(&fx.path, description);
        repo.undo(false).expect("an operation with no workspace is undone");
        let warnings = repo.take_warnings();
        assert_eq!(
            warnings
                .iter()
                .map(|w| (w.kind, w.message.as_str()))
                .collect::<Vec<_>>(),
            [(kind, message)],
            "{description}"
        );
    }
}

#[test]
fn undo_at_root_operation_returns_nothing_to_undo() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

    let (head_hex, root_hex) = {
        let mut repo = Repo::open(tmp.path()).unwrap();
        let ops = repo.op_log(None).unwrap();
        let head_hex = ops[0].id.0.clone();
        let root_hex = ops.iter().find(|op| op.root_op).unwrap().id.0.clone();
        (head_hex, root_hex)
    };

    // Engineer the unreachable-via-Repo::init/open NothingToUndo state directly: a
    // fresh workspace's head always has >=1 parent (Workspace::init_* always commits
    // an "add workspace" op on top of root). Rewrite op_heads/heads/ so the ONLY marker
    // is the root op itself.
    let heads_dir = tmp.path().join(".jj").join("repo").join("op_heads").join("heads");
    fs::remove_file(heads_dir.join(&head_hex)).unwrap();
    fs::write(heads_dir.join(&root_hex), "").unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    let result = repo.undo(false);

    assert!(
        matches!(result, Err(MutateError::NothingToUndo)),
        "undo at the root operation must return NothingToUndo, got: {result:?}"
    );
}

/// Story 9.40: an undo whose restored view equals the current one writes no operation — `jj
/// undo` says "Nothing changed." Git HEAD made unborn behind jj's back makes the precondition
/// write `import git head`, which changes only `git_head`; undoing it restores the previous
/// operation's repo state while keeping the CURRENT `git_head`, i.e. an equal view.
#[test]
fn undo_restoring_an_equal_view_writes_no_operation() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(zanshin_jj::Backend::Git),
        colocate: Some(true),
        ..Default::default()
    })
    .result
    .unwrap();
    let mut repo = Repo::open(tmp.path()).unwrap();
    repo.commit(&zanshin_jj::CommitOptions {
        paths: Vec::new(),
        message: vec!["one".to_owned()],
    })
    .expect("commit");
    let out = std::process::Command::new("git")
        .args(["symbolic-ref", "HEAD", "refs/heads/nowhere"])
        .current_dir(tmp.path())
        .output()
        .expect("spawn git");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));

    let result = repo.undo(false).expect("undo of an equal view succeeds");

    let head = repo.op_log(Some(1)).unwrap().swap_remove(0);
    assert_eq!(
        head.description, "import git head",
        "the precondition's import stays the head"
    );
    assert_eq!(result.new_op_id, head.id, "no undo operation is written");
    assert!(result.finish.is_none());
}

#[test]
fn undo_on_corrupt_repo_returns_backend_error() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();

    // Corrupt AFTER open: undo() re-resolves to head on every call (ADR-0002), so
    // removing op_heads makes load_at_head() fail -> MutateError::Backend.
    let op_heads = tmp.path().join(".jj").join("repo").join("op_heads");
    fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.undo(false);

    assert!(
        matches!(result, Err(MutateError::Precondition(zanshin_jj::PreconditionError::Backend(_)))),
        "the pre-verb snapshot fails first (Story 9.26, as the CLI would): corrupt repo must yield Backend error, got: {result:?}"
    );
}

#[test]
fn undo_immediately_after_init_returns_backend_error_no_working_copy() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();
    let mut repo = Repo::open(tmp.path()).unwrap();

    // The head op right after Repo::init is "add workspace 'default'", whose single
    // parent IS the root op (Workspace::init_* always commits that op on top of root —
    // see the NothingToUndo test above). Undoing restores the root op's empty view,
    // which has no wc_commit_id entry for any workspace -- sync_working_copy's own
    // guard surfaces that as a Backend error rather than panicking.
    let result = repo.undo(false);

    assert!(
        matches!(result, Err(MutateError::Backend(ref msg)) if msg.contains("working-copy")),
        "undo to the root op's empty view must surface sync_working_copy's own guard, got: {result:?}"
    );
}

#[test]
fn undo_on_merge_op_returns_invalid_input() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let heads_dir = fx.path.join(".jj").join("repo").join("op_heads").join("heads");

    // Deterministic marker-file choreography for a real 2-parent op-heads state (see
    // spec-6-2-op-log-undo.md's Design Notes) — no threads, no flakiness.
    // 1. Handle A: note h0 = the current head hex.
    let mut repo_a = Repo::open(&fx.path).unwrap();
    let h0 = repo_a.op_log(Some(1)).unwrap()[0].id.0.clone();
    drop(repo_a);

    // 2. Handle A: describe Commit 1 -> new head h1.
    let mut repo_a = Repo::open(&fx.path).unwrap();
    repo_a
        .describe(ChangeId(layout.commit1_change_id.clone()), "A")
        .unwrap();
    let h1 = repo_a.op_log(Some(1)).unwrap()[0].id.0.clone();
    drop(repo_a);

    // 3. Rewind: op_heads/heads/ now has only h0 again, as if step 2 never happened.
    fs::remove_file(heads_dir.join(&h1)).unwrap();
    fs::write(heads_dir.join(&h0), "").unwrap();

    // 4. Fresh handle B (unaware of h1): describe Commit 3 -> new head h2, a genuine
    // sibling of h1 (both children of h0, divergent content).
    let mut repo_b = Repo::open(&fx.path).unwrap();
    repo_b
        .describe(ChangeId(layout.commit3_change_id.clone()), "B")
        .unwrap();
    // h2's marker is already left in place by jj-lib's own commit — nothing more to do
    // here; the assertion is step 6 observing both h1 and h2 as heads.
    drop(repo_b);

    // 5. Restore divergence: op_heads/heads/ now has BOTH h1 and h2.
    fs::write(heads_dir.join(&h1), "").unwrap();

    // 6. Fresh handle C: undo()'s internal load_at_head() observes 2 markers, jj-lib
    // synchronously persists a "reconcile divergent operations" merge op as the new
    // sole head, and undo()'s parent-count guard refuses it.
    let mut repo_c = Repo::open(&fx.path).unwrap();
    // Story 9.56: the CLI's casing and its hint (`cli/src/commands/undo.rs:161-163` @ v0.46.0).
    match repo_c.undo(false) {
        Err(MutateError::InvalidInput { reason, hints }) => {
            assert_eq!(reason, "Cannot undo a merge operation");
            assert_eq!(hints, ["Consider using `jj op restore` instead"]);
        }
        other => panic!("expected InvalidInput{{reason: \"Cannot undo a merge operation\"}}, got: {other:?}"),
    }
}

#[test]
fn undo_preserves_current_git_head_and_git_refs_not_targets() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let commit1_id = CommitId::try_from_hex(&layout.commit1_commit_hex).expect("valid commit1 hex");
    let commit3_id = CommitId::try_from_hex(&layout.commit3_commit_hex).expect("valid commit3 hex");

    // git_refs/git_head have no mutation exposed through Repo's public API, and op B's
    // bookmark (below) must land in the SAME operation as its Git-ref move, so build the
    // two ops directly via raw jj-lib transactions: op A puts git_refs/git_head at Commit 1
    // (the TARGET undo() will restore toward); an intervening op B moves them to Commit 3 --
    // this becomes the CURRENT (pre-undo) state that undo()'s restored_view must leave
    // untouched.
    //
    // Op B also creates a local bookmark -- a repo portion undo() DOES restore from the
    // target. Without it, the restored view (op A's repo portion + the current git state)
    // would equal op B's view, the undo would write nothing (Story 9.40's no-change gate),
    // and the git assertions below would hold trivially on the unchanged view.
    let (workspace, _settings) = oracle_workspace(&fx.path);
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head");

    let mut tx = readonly.start_transaction();
    tx.repo_mut().set_git_ref_target(
        GitRefName::new("refs/heads/main"),
        RefTarget::normal(commit1_id.clone()),
    );
    tx.repo_mut()
        .set_git_head_target(workspace.workspace_name(), RefTarget::normal(commit1_id));
    let repo_a = pollster::block_on(tx.commit("op A: git state at Commit 1")).expect("commit op A");
    let op_a = repo_a.op_id().hex();

    let mut tx2 = repo_a.start_transaction();
    tx2.repo_mut().set_git_ref_target(
        GitRefName::new("refs/heads/main"),
        RefTarget::normal(commit3_id.clone()),
    );
    tx2.repo_mut()
        .set_git_head_target(workspace.workspace_name(), RefTarget::normal(commit3_id.clone()));
    tx2.repo_mut()
        .set_local_bookmark_target("undo-witness".as_ref(), RefTarget::normal(commit3_id));
    let repo_b = pollster::block_on(tx2.commit("op B: git state moved to Commit 3 + a bookmark")).expect("commit op B");
    let op_b = repo_b.op_id().hex();

    // undo() through the crate's public API: head (op B) -> its single parent (op A).
    let mut repo = Repo::open(&fx.path).unwrap();
    let result = repo.undo(false).unwrap();

    // The undo WROTE an operation: the view below is a written one, not op B's left as is.
    let head_op = repo.op_log(Some(1)).unwrap().swap_remove(0);
    assert_ne!(result.new_op_id.0, op_b, "the undo must write an operation");
    assert_eq!(
        result.new_op_id, head_op.id,
        "MutationResult.new_op_id must match the op-log head"
    );
    assert_eq!(head_op.description, format!("undo: restore to operation {op_a}"));

    // git_head must still point at Commit 3 (CURRENT/op B) -- NOT revert to Commit 1
    // (the target op's value). A regression that swapped restored_view's git_refs/
    // git_head source from `current` to `target` would flip this.
    //
    // WHY: read the `View` directly. jj 0.44 removed the `git_head()`/`git_refs()` REVSET
    // functions, but the view fields they exposed — and which `undo()` copies from `current`
    // — are unchanged, so this asserts the same property one level closer to the code. Since
    // jj 0.45 the git head is kept per workspace (`View::git_heads`).
    let (oracle, _settings) = oracle_workspace(&fx.path);
    let view_repo = pollster::block_on(oracle.repo_loader().load_at_head()).expect("oracle load_at_head");
    let view = view_repo.view();

    assert!(
        view.get_local_bookmark("undo-witness".as_ref()).is_absent(),
        "the local bookmark (repo portion) must be restored from the target op, where it is absent"
    );

    let head: Vec<String> = view
        .git_head(oracle.workspace_name())
        .present_adds()
        .map(ObjectId::hex)
        .collect();
    assert_eq!(
        head,
        vec![layout.commit3_commit_hex.clone()],
        "git_head must stay at the CURRENT (pre-undo) commit, not revert to the target op's"
    );

    let refs: Vec<String> = view
        .git_refs()
        .values()
        .flat_map(RefTarget::present_adds)
        .map(ObjectId::hex)
        .collect();
    assert!(
        refs.contains(&layout.commit3_commit_hex),
        "git_refs must still include the CURRENT (pre-undo) commit"
    );
    assert!(
        !refs.contains(&layout.commit1_commit_hex),
        "git_refs must not revert to the target op's commit"
    );
}
