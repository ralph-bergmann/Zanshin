// SPDX-License-Identifier: MIT

use std::path::Path;
use std::sync::{Arc, LazyLock};
use std::{env, fs};

use jj_lib::backend::{CopyId, TreeValue};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::rewrite::merge_commit_trees;
use jj_lib::store::Store;
use jj_lib::tree_builder::TreeBuilder;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{ChangeError, ChangeId, ConflictState, Repo};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: mirrors tests/status.rs — empty string makes jj-lib find no config at
    // that path (non-existent), while GIT_CONFIG_GLOBAL="" isolates the gix backend.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// Creates a described commit (`description`) as the new `@`.
///
/// TEST SETUP ONLY — drives the `is_anonymous == false` path.
fn jj_new_with_description(workspace_root: &Path, description: &str) -> Result<(), Box<dyn std::error::Error>> {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )?;
    let repo = pollster::block_on(workspace.repo_loader().load_at_head())?;
    let workspace_name = workspace.workspace_name().to_owned();

    let wc_id = repo
        .view()
        .get_wc_commit_id(&workspace_name)
        .ok_or("workspace has no working-copy commit")?
        .clone();
    let wc_commit = repo.store().get_commit(&wc_id)?;
    let wc_tree = wc_commit.tree();

    let mut tx = repo.start_transaction();
    let new_commit = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![wc_id], wc_tree)
            .set_description(description)
            .write(),
    )?;
    tx.repo_mut().set_wc_commit(workspace_name, new_commit.id().clone())?;
    pollster::block_on(tx.commit("test: jj new with description"))?;
    Ok(())
}

/// Creates a genuine divergent change: two visible commits sharing one change id.
///
/// TEST SETUP ONLY — drives the `divergent == true` path (AC-13).
fn make_divergent_change(workspace_root: &Path) -> String {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();

    let root_commit = repo.store().root_commit();
    let root_id = root_commit.id().clone();
    let root_tree = root_commit.tree();

    let mut tx = repo.start_transaction();
    let commit_a = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![root_id.clone()], root_tree.clone())
            .set_description("divergent a")
            .write(),
    )
    .unwrap();
    let shared_change = commit_a.change_id().clone();
    // Force commit_b onto the same change id → two visible commits, one change id.
    let commit_b = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![root_id], root_tree)
            .set_change_id(shared_change)
            .set_description("divergent b")
            .write(),
    )
    .unwrap();
    pollster::block_on(tx.repo_mut().add_head(&commit_a)).unwrap();
    pollster::block_on(tx.repo_mut().add_head(&commit_b)).unwrap();
    pollster::block_on(tx.commit("test: create divergent change")).unwrap();

    commit_a.change_id().reverse_hex()
}

/// Builds a single-file tree (`path` → `content`). TEST SETUP ONLY.
fn tree_with_file(store: &Arc<Store>, path: &RepoPathBuf, content: &[u8]) -> MergedTree {
    let mut builder = TreeBuilder::new(store.clone(), store.empty_tree_id().clone());
    // WHY: &[u8] implements futures AsyncRead directly (jj-lib 0.42 Store::write_file) — no Cursor.
    let mut reader = content;
    let file_id = pollster::block_on(store.write_file(path, &mut reader)).unwrap();
    builder.set(
        path.clone(),
        TreeValue::File {
            id: file_id,
            executable: false,
            copy_id: CopyId::placeholder(),
        },
    );
    let tree_id = pollster::block_on(builder.write_tree()).unwrap();
    MergedTree::resolved(store.clone(), tree_id)
}

/// Creates a genuinely conflicted merge commit: two children of root edit the same file
/// differently, then a merge of both auto-resolves to a conflict on that path. Returns its
/// reverse-hex change id.
///
/// TEST SETUP ONLY — drives the `commit.has_conflict()` true branch in `get_change` that
/// builds `ConflictState::Conflicted { paths }` (D7).
fn make_conflicted_change(workspace_root: &Path) -> String {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let store = repo.store().clone();
    let root_id = store.root_commit_id().clone();

    let path = RepoPathBuf::from_internal_string("conflicted.txt").unwrap();
    let tree_a = tree_with_file(&store, &path, b"side a\n");
    let tree_b = tree_with_file(&store, &path, b"side b\n");

    let mut tx = repo.start_transaction();
    let commit_a = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![root_id.clone()], tree_a)
            .set_description("side a")
            .write(),
    )
    .unwrap();
    let commit_b = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![root_id], tree_b)
            .set_description("side b")
            .write(),
    )
    .unwrap();

    // Auto-merge the two sides (common ancestor = root/empty) → a tree that conflicts on `path`.
    let merged = pollster::block_on(merge_commit_trees(tx.repo_mut(), &[commit_a.clone(), commit_b.clone()])).unwrap();
    let merge_commit = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![commit_a.id().clone(), commit_b.id().clone()], merged)
            .set_description("conflicting merge")
            .write(),
    )
    .unwrap();
    assert!(
        merge_commit.has_conflict(),
        "constructed merge commit must carry a conflict"
    );
    pollster::block_on(tx.repo_mut().add_head(&merge_commit)).unwrap();
    pollster::block_on(tx.commit("test: create conflicted merge commit")).unwrap();

    merge_commit.change_id().reverse_hex()
}

// ── AC-6: valid id → metadata equality ──────────────────────────────────────

/// Load the WC commit's fields directly via jj-lib (the oracle) for equality checks.
#[allow(clippy::type_complexity)]
fn wc_oracle_fields(workspace_root: &Path) -> (String, String, Vec<String>, String, String, String) {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .unwrap()
        .clone();
    let wc_commit = repo.store().get_commit(&wc_id).unwrap();

    let change_id = wc_commit.change_id().reverse_hex();
    let commit_id = wc_commit.id().hex();
    let parent_change_ids: Vec<String> = wc_commit
        .parent_ids()
        .iter()
        .map(|pid| repo.store().get_commit(pid).unwrap().change_id().reverse_hex())
        .collect();
    let description = wc_commit.description().to_owned();
    let author_name = wc_commit.author().name.clone();
    let author_email = wc_commit.author().email.clone();

    (
        change_id,
        commit_id,
        parent_change_ids,
        description,
        author_name,
        author_email,
    )
}

#[test]
fn change_on_known_id_returns_metadata() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();

    let (oracle_change_id, oracle_commit_id, oracle_parents, oracle_desc, oracle_author_name, oracle_author_email) =
        wc_oracle_fields(&fx.path);

    let mut repo = Repo::open(&fx.path).unwrap();
    let change = repo.get_change(&ChangeId(oracle_change_id.clone())).unwrap();

    assert_eq!(change.id.0, oracle_change_id, "change id must match oracle");
    assert_eq!(change.commit_id.0, oracle_commit_id, "commit id must match oracle");
    assert_eq!(
        change.parents.iter().map(|p| p.0.clone()).collect::<Vec<_>>(),
        oracle_parents,
        "parents must match oracle in order"
    );
    assert_eq!(change.description, oracle_desc, "description must match oracle");
    assert_eq!(change.author.name, oracle_author_name, "author.name must match oracle");
    assert_eq!(
        change.author.email, oracle_author_email,
        "author.email must match oracle"
    );
    // Timestamps are raw jj values — just assert they're plausible (> Unix epoch start).
    assert!(
        change.author.timestamp.millis_since_epoch > 0,
        "authored_at must be after epoch"
    );
    assert_eq!(
        change.timestamps.authored_at, change.author.timestamp,
        "timestamps.authored_at mirrors author.timestamp"
    );
    assert_eq!(
        change.timestamps.committed_at, change.committer.timestamp,
        "timestamps.committed_at mirrors committer.timestamp"
    );
    // Clean fixture changes are conflict-free.
    assert!(
        matches!(change.conflict, ConflictState::Clean),
        "clean fixture must have no conflict"
    );
    // is_signed is presence-only (D3): the unsigned fixture commit must report false (AC-9).
    assert!(
        !change.is_signed,
        "unsigned fixture commit must report is_signed == false"
    );
    // Non-divergent ordinary commit must report divergent == false (AC-13, negative clause).
    assert!(!change.divergent, "ordinary fixture commit must not be divergent");
}

// ── AC-6: working-copy change → parents include @- ──────────────────────────

#[test]
fn change_on_working_copy_includes_parent() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();

    let (_, _, oracle_parents, _, _, _) = wc_oracle_fields(&fx.path);

    let mut repo = Repo::open(&fx.path).unwrap();
    let status = repo.status().unwrap();
    let change = repo.get_change(&status.working_copy_change_id).unwrap();

    assert!(!change.parents.is_empty(), "WC change must have at least one parent");
    // The first parent must be the same as status's parent_change_id.
    assert_eq!(
        change.parents[0], status.parent_change_id,
        "first parent must match status.parent_change_id"
    );
    assert_eq!(
        change.parents.iter().map(|p| p.0.clone()).collect::<Vec<_>>(),
        oracle_parents,
        "parents must match oracle"
    );
}

// ── AC-7: not found ──────────────────────────────────────────────────────────

#[test]
fn change_on_nonexistent_id_returns_not_found() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    // A syntactically valid reverse-hex id that doesn't exist in this repo.
    let result = repo.get_change(&ChangeId("qpvuntsmwlqtpvuntsmwlqtpvuntsm".to_owned()));

    assert!(
        matches!(result, Err(ChangeError::NotFound { .. })),
        "absent id must yield NotFound, got: {result:?}"
    );
}

#[test]
fn change_on_malformed_id_returns_not_found() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    // Characters outside the reverse-hex alphabet (z-k: "a-z" rotated; `!` is invalid).
    let result = repo.get_change(&ChangeId("not-valid-reverse-hex!".to_owned()));

    assert!(
        matches!(result, Err(ChangeError::NotFound { .. })),
        "malformed id must yield NotFound, got: {result:?}"
    );
}

// ── AC-7: empty id → not found (must not panic) ──────────────────────────────

#[test]
fn change_on_empty_id_returns_not_found() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    // Empty string is even-length, so try_from_reverse_hex returns Some; without the
    // explicit empty guard this would reach resolve_change_id and panic (AmbiguousMatch).
    let result = repo.get_change(&ChangeId(String::new()));

    assert!(
        matches!(result, Err(ChangeError::NotFound { .. })),
        "empty id must yield NotFound (never panic), got: {result:?}"
    );
}

// ── AC-11: root change → empty parents ──────────────────────────────────────

#[test]
fn change_on_root_returns_empty_parents() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();

    // Oracle: get root commit's change id via jj-lib.
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        &fx.path,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo_jj = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let root_commit = repo_jj.store().root_commit();
    let root_change_id = ChangeId(root_commit.change_id().reverse_hex());

    let mut repo = Repo::open(&fx.path).unwrap();
    let change = repo.get_change(&root_change_id).unwrap();

    assert!(
        change.parents.is_empty(),
        "root change must have no parents, got: {:?}",
        change.parents
    );
}

// ── AC-10: anonymous change ──────────────────────────────────────────────────

#[test]
fn change_on_anonymous_commit_is_anonymous() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();

    // Fresh repo: initial WC commit has empty description and no local bookmark → anonymous.
    let mut repo = Repo::open(tmp.path()).unwrap();
    let status = repo.status().unwrap();
    let change = repo.get_change(&status.working_copy_change_id).unwrap();

    assert!(
        change.is_anonymous,
        "WC commit with empty description and no bookmark must be anonymous"
    );
    assert_eq!(change.description, "", "anonymous commit description must be empty");
}

#[test]
fn change_on_described_commit_is_not_anonymous() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();

    jj_new_with_description(tmp.path(), "my feature").unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    let status = repo.status().unwrap();
    let change = repo.get_change(&status.working_copy_change_id).unwrap();

    assert!(
        !change.is_anonymous,
        "commit with non-empty description must not be anonymous"
    );
    assert_eq!(change.description, "my feature");
}

// ── AC-11: merge change → all parents in order ───────────────────────────────

#[test]
fn change_on_merge_in_medium_fixture_has_three_parents() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();

    // Oracle: find the 3-parent merge commit via the "merge" bookmark.
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        &fx.path,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo_jj = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();

    let mut merge_change_id: Option<ChangeId> = None;
    let mut oracle_parent_change_ids: Vec<String> = Vec::new();
    'outer: for (name, target) in repo_jj.view().local_bookmarks() {
        if name == "merge" {
            for commit_id in target.added_ids() {
                let commit = repo_jj.store().get_commit(commit_id).unwrap();
                if commit.parent_ids().len() == 3 {
                    merge_change_id = Some(ChangeId(commit.change_id().reverse_hex()));
                    oracle_parent_change_ids = commit
                        .parent_ids()
                        .iter()
                        .map(|pid| repo_jj.store().get_commit(pid).unwrap().change_id().reverse_hex())
                        .collect();
                    break 'outer;
                }
            }
        }
    }

    let merge_change_id =
        merge_change_id.expect("medium-1k-commits must have a 3-parent merge commit with bookmark 'merge'");

    let mut repo = Repo::open(&fx.path).unwrap();
    let change = repo.get_change(&merge_change_id).unwrap();

    assert_eq!(change.parents.len(), 3, "merge commit must have 3 parents");
    let actual_parents: Vec<String> = change.parents.iter().map(|p| p.0.clone()).collect();
    assert_eq!(
        actual_parents, oracle_parent_change_ids,
        "parent change ids must match oracle in jj order"
    );
}

// ── AC-13: divergent change ──────────────────────────────────────────────────

#[test]
fn change_on_divergent_id_returns_divergent_flag() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();

    let divergent_change_id_str = make_divergent_change(tmp.path());
    let divergent_id = ChangeId(divergent_change_id_str);

    let mut repo = Repo::open(tmp.path()).unwrap();
    let change = repo.get_change(&divergent_id).unwrap();

    assert!(
        change.divergent,
        "change with two visible commits must have divergent == true"
    );
    // get_change returns a visible target — it must carry the shared change id.
    assert_eq!(
        change.id, divergent_id,
        "returned change id must be the shared divergent id"
    );

    // Independent oracle (recipe 2-6:401): re-resolve via jj-lib and confirm the change id
    // genuinely maps to exactly two visible commits. We do NOT pin WHICH commit get_change
    // returns — jj-lib's visible-target order is a preference, not a guarantee (D4).
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        tmp.path(),
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo_jj = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&divergent_id.0).unwrap();
    let targets = repo_jj
        .resolve_change_id(&jj_id)
        .unwrap()
        .expect("divergent id must resolve");
    assert!(targets.is_divergent(), "oracle: change id must be divergent");
    assert_eq!(
        targets.into_visible().map_or(0, |v| v.len()),
        2,
        "oracle: divergent change must resolve to exactly two visible commits"
    );
}

// ── AC-12: clean change → ConflictState::Clean ──────────────────────────────

#[test]
fn change_on_clean_commit_returns_clean_conflict() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let status = repo.status().unwrap();
    let change = repo.get_change(&status.working_copy_change_id).unwrap();

    assert!(
        matches!(change.conflict, ConflictState::Clean),
        "clean WC commit must have ConflictState::Clean, got: {:?}",
        change.conflict
    );
}

#[test]
fn change_on_conflicted_commit_returns_conflicted_paths() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();

    // Construct a genuine add/add conflict on `conflicted.txt` via jj-lib (no jj CLI).
    let conflicted_change_id = ChangeId(make_conflicted_change(tmp.path()));

    let mut repo = Repo::open(tmp.path()).unwrap();
    let change = repo.get_change(&conflicted_change_id).unwrap();

    // D7: a commit jj reports as conflicted must surface ConflictState::Conflicted with the
    // conflicted file path(s) — the `commit.has_conflict()` true branch in get_change that
    // walks `commit.tree().conflicts()`. Only ConflictState::Clean was covered before.
    match &change.conflict {
        ConflictState::Conflicted { paths } => {
            assert!(
                !paths.is_empty(),
                "conflicted commit must list at least one conflicted path"
            );
            assert!(
                paths.iter().any(|p| p.ends_with("conflicted.txt")),
                "conflicted path list must include the file in conflict, got: {paths:?}"
            );
        }
        ConflictState::Clean => {
            panic!("conflicted merge commit must yield ConflictState::Conflicted, got Clean")
        }
    }
}

// ── AC-25 / Backend error variant ────────────────────────────────────────────

#[test]
fn change_on_corrupt_repo_returns_backend_error() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    let status = repo.status().unwrap();
    let change_id = status.working_copy_change_id.clone();

    // Corrupt AFTER open: get_change() re-resolves to head on every call (ADR-0002),
    // so removing op_heads makes load_at_head() fail → ChangeError::Backend.
    let op_heads = tmp.path().join(".jj").join("repo").join("op_heads");
    fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.get_change(&change_id);

    assert!(
        matches!(result, Err(ChangeError::Precondition(zanshin_jj::PreconditionError::Backend(_)))),
        "the pre-verb snapshot fails first (Story 9.26, as the CLI would): corrupt repo must yield Backend error, got: {result:?}"
    );
}
