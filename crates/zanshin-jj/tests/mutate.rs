// SPDX-License-Identifier: MIT

use std::collections::HashMap;
use std::path::Path;
use std::sync::LazyLock;
use std::{env, fs};

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{Repo as _, StoreFactories};
use jj_lib::settings::UserSettings;
use jj_lib::workspace::{default_working_copy_factories, Workspace};
use test_helpers::extract_fixture;
use zanshin_jj::{ChangeId, MutateError, Repo};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

fn make_test_settings() -> UserSettings {
    let mut config = StackedConfig::with_defaults();
    config.add_layer(
        ConfigLayer::parse(
            ConfigSource::User,
            r#"
                [user]
                name = "Zanshin"
                email = "zanshin@localhost"
                [operation]
                username = "zanshin"
                hostname = "localhost"
            "#,
        )
        .expect("valid config literal"),
    );
    UserSettings::from_config(config).expect("valid settings")
}

/// `tiny-3-commits`' shape: root has two UNRELATED children — `@` (empty, no
/// description) and a `Commit 1 -> Commit 2 -> Commit 3` linear chain, where `Commit 3`
/// is the chain's head. Discovered dynamically (by description, walking every head's
/// ancestry to root) rather than hardcoded, so a future fixture regen doesn't silently
/// break these tests.
struct Layout {
    wc_change_id: String,
    wc_commit_hex: String,
    commit1_change_id: String,
    commit1_commit_hex: String,
    commit2_change_id: String,
    commit3_change_id: String,
    commit3_commit_hex: String,
    root_change_id: String,
}

fn oracle_layout(workspace_root: &Path) -> Layout {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head");
    let store = repo.store();
    let view = repo.view();

    let wc_id = view
        .get_wc_commit_id(workspace.workspace_name())
        .expect("fixture has a working-copy commit")
        .clone();
    let wc_commit = store.get_commit(&wc_id).unwrap();

    // Map "Commit N" description -> (change id, commit hex) by walking every head's
    // ancestry back to root.
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
    let (commit2_change_id, _) = by_desc.get("Commit 2").expect("fixture has Commit 2").clone();
    let (commit3_change_id, commit3_commit_hex) = by_desc.get("Commit 3").expect("fixture has Commit 3").clone();

    Layout {
        wc_change_id: wc_commit.change_id().reverse_hex(),
        wc_commit_hex: wc_commit.id().hex(),
        commit1_change_id,
        commit1_commit_hex,
        commit2_change_id,
        commit3_change_id,
        commit3_commit_hex,
        root_change_id: store.root_commit().change_id().reverse_hex(),
    }
}

fn checkout_state_path(workspace_root: &Path) -> std::path::PathBuf {
    workspace_root.join(".jj").join("working_copy").join("checkout")
}

// ── describe ──────────────────────────────────────────────────────────────────────

#[test]
fn describe_happy_path_rewrites_description_and_records_op_log() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo
        .describe(ChangeId(layout.commit1_change_id.clone()), "New description")
        .unwrap();

    assert!(result.new_change_ids.is_empty());
    assert!(result.abandoned_change_ids.is_empty());
    // Commit 1 is unrelated to `@` (a separate branch off root) — describing it must
    // not move the working copy.
    assert_eq!(result.working_copy_change_id.0, layout.wc_change_id);

    let change = repo.get_change(&ChangeId(layout.commit1_change_id)).unwrap();
    assert_eq!(change.description, "New description");

    let ops = repo.op_log(Some(1)).unwrap();
    assert_eq!(
        ops[0].description,
        format!("describe commit {}", layout.commit1_commit_hex)
    );
    assert_eq!(
        result.new_op_id, ops[0].id,
        "MutationResult.new_op_id must match the op-log head"
    );
}

#[test]
fn describe_empty_string_makes_change_anonymous() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    repo.describe(ChangeId(layout.commit1_change_id.clone()), "").unwrap();

    let change = repo.get_change(&ChangeId(layout.commit1_change_id)).unwrap();
    assert_eq!(change.description, "");
    assert!(change.is_anonymous, "empty description + no bookmark must be anonymous");
}

#[test]
fn describe_non_wc_change_does_not_touch_on_disk_working_copy() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let checkout_path = checkout_state_path(&fx.path);
    let before = fs::read(&checkout_path).unwrap();

    let mut repo = Repo::open(&fx.path).unwrap();
    repo.describe(ChangeId(layout.commit1_change_id), "unrelated change")
        .unwrap();

    let after = fs::read(&checkout_path).unwrap();
    assert_eq!(
        before, after,
        "a mutation that doesn't move `@` must never call workspace.check_out"
    );
}

// ── new_change ───────────────────────────────────────────────────────────────────

#[test]
fn new_change_single_parent_creates_empty_child_and_switches_wc() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let checkout_path = checkout_state_path(&fx.path);
    let checkout_before = fs::read(&checkout_path).unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.new_change(&[ChangeId(layout.commit3_change_id.clone())]).unwrap();

    assert_eq!(result.new_change_ids.len(), 1);
    assert_eq!(result.working_copy_change_id, result.new_change_ids[0]);
    assert!(result.abandoned_change_ids.is_empty());

    let new_change = repo.get_change(&result.new_change_ids[0]).unwrap();
    assert_eq!(new_change.description, "");
    assert_eq!(new_change.parents, vec![ChangeId(layout.commit3_change_id)]);

    let ops = repo.op_log(Some(1)).unwrap();
    assert_eq!(ops[0].description, "new empty commit");
    assert_eq!(
        result.new_op_id, ops[0].id,
        "MutationResult.new_op_id must match the op-log head"
    );

    // Positive counterpart to `describe_non_wc_change_does_not_touch_on_disk_working_copy`:
    // moving `@` MUST update the on-disk working-copy state (workspace.check_out actually ran).
    let checkout_after = fs::read(&checkout_path).unwrap();
    assert_ne!(
        checkout_before, checkout_after,
        "a mutation that moves `@` must call workspace.check_out"
    );
}

#[test]
fn new_change_multiple_parents_creates_merge_commit() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo
        .new_change(&[
            ChangeId(layout.wc_change_id.clone()),
            ChangeId(layout.commit3_change_id.clone()),
        ])
        .unwrap();

    assert_eq!(result.new_change_ids.len(), 1);
    let new_change = repo.get_change(&result.new_change_ids[0]).unwrap();
    assert_eq!(new_change.parents.len(), 2);
    assert!(new_change.parents.contains(&ChangeId(layout.wc_change_id)));
    assert!(new_change.parents.contains(&ChangeId(layout.commit3_change_id)));
}

#[test]
fn new_change_empty_parents_returns_invalid_input() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.new_change(&[]);

    assert!(matches!(result, Err(MutateError::InvalidInput { .. })));
}

// ── edit ─────────────────────────────────────────────────────────────────────────

#[test]
fn edit_switches_wc_without_creating_a_new_commit() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.edit(ChangeId(layout.commit3_change_id.clone())).unwrap();

    assert_eq!(result.working_copy_change_id.0, layout.commit3_change_id);
    assert!(result.new_change_ids.is_empty());
    assert!(result.abandoned_change_ids.is_empty());

    // No new commit: Commit 3's commit id (not just its change id) is unchanged.
    let change = repo.get_change(&ChangeId(layout.commit3_change_id)).unwrap();
    assert_eq!(change.commit_id.0, layout.commit3_commit_hex);

    let ops = repo.op_log(Some(1)).unwrap();
    assert_eq!(ops[0].description, format!("edit commit {}", layout.commit3_commit_hex));
    assert_eq!(
        result.new_op_id, ops[0].id,
        "MutationResult.new_op_id must match the op-log head"
    );
}

// ── abandon ──────────────────────────────────────────────────────────────────────

#[test]
fn abandon_non_wc_change_rebases_descendants_and_echoes_input() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.abandon(&[ChangeId(layout.commit1_change_id.clone())]).unwrap();

    assert!(result.new_change_ids.is_empty());
    assert_eq!(
        result.abandoned_change_ids,
        vec![ChangeId(layout.commit1_change_id.clone())]
    );
    // Commit 1 is unrelated to `@` — abandoning it must not move the working copy.
    assert_eq!(result.working_copy_change_id.0, layout.wc_change_id);

    let not_found = repo.get_change(&ChangeId(layout.commit1_change_id));
    assert!(not_found.is_err(), "abandoned change must no longer resolve");

    // Commit 2 (Commit 1's child) is rebased onto root; Commit 3 still has Commit 2 as
    // its parent (rebase preserves change ids, only commit ids change).
    let commit3 = repo.get_change(&ChangeId(layout.commit3_change_id)).unwrap();
    assert_eq!(commit3.parents, vec![ChangeId(layout.commit2_change_id)]);

    let ops = repo.op_log(Some(1)).unwrap();
    assert_eq!(
        ops[0].description,
        format!("abandon commit {}", layout.commit1_commit_hex)
    );
    assert_eq!(
        result.new_op_id, ops[0].id,
        "MutationResult.new_op_id must match the op-log head"
    );
}

#[test]
fn abandon_wc_itself_creates_new_empty_wc() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.abandon(&[ChangeId(layout.wc_change_id.clone())]).unwrap();

    assert_eq!(result.new_change_ids.len(), 1);
    assert_ne!(
        result.new_change_ids[0].0, layout.wc_change_id,
        "abandoning @ must mint a fresh change"
    );
    assert_eq!(result.working_copy_change_id, result.new_change_ids[0]);
    assert_eq!(result.abandoned_change_ids, vec![ChangeId(layout.wc_change_id)]);

    let ops = repo.op_log(Some(1)).unwrap();
    assert_eq!(ops[0].description, format!("abandon commit {}", layout.wc_commit_hex));
    assert_eq!(
        result.new_op_id, ops[0].id,
        "MutationResult.new_op_id must match the op-log head"
    );
}

#[test]
fn abandon_deletes_bookmarks_pointing_only_at_the_abandoned_commit() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    test_helpers::set_local_bookmark(&fx.path, "doomed", &[&layout.commit1_commit_hex]);
    let mut repo = Repo::open(&fx.path).unwrap();
    assert!(
        repo.list_bookmarks().unwrap().iter().any(|b| b.name == "doomed"),
        "fixture setup: bookmark must exist before abandon"
    );

    repo.abandon(&[ChangeId(layout.commit1_change_id)]).unwrap();

    assert!(
        !repo.list_bookmarks().unwrap().iter().any(|b| b.name == "doomed"),
        "abandon's delete_abandoned_bookmarks:true must remove a bookmark that pointed only at the abandoned commit"
    );
}

#[test]
fn abandon_empty_slice_returns_invalid_input() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.abandon(&[]);

    assert!(matches!(
        result,
        Err(MutateError::InvalidInput { reason }) if reason == "abandon requires at least one change id"
    ));
}

// ── shared ChangeNotFound behavior across all four mutations ────────────────────────

#[test]
fn every_mutation_returns_change_not_found_for_a_bogus_id() {
    pin_env();
    for bogus in [
        ChangeId(String::new()),
        ChangeId("qpvuntsmwlqtpvuntsmwlqtpvuntsm".to_owned()),
    ] {
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let mut repo = Repo::open(&fx.path).unwrap();

        assert!(matches!(
            repo.describe(bogus.clone(), "x"),
            Err(MutateError::ChangeNotFound { .. })
        ));
        assert!(matches!(
            repo.new_change(std::slice::from_ref(&bogus)),
            Err(MutateError::ChangeNotFound { .. })
        ));
        assert!(matches!(
            repo.edit(bogus.clone()),
            Err(MutateError::ChangeNotFound { .. })
        ));
        assert!(matches!(
            repo.abandon(std::slice::from_ref(&bogus)),
            Err(MutateError::ChangeNotFound { .. })
        ));
    }
}

// ── crash-safety guards (Review: Edge Case Hunter) ──────────────────────────────────

#[test]
fn describe_root_commit_returns_invalid_input_not_a_panic() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.describe(ChangeId(layout.root_change_id), "x");

    assert!(matches!(result, Err(MutateError::InvalidInput { .. })));
}

#[test]
fn abandon_root_commit_returns_invalid_input_not_a_panic() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.abandon(&[ChangeId(layout.root_change_id)]);

    assert!(matches!(result, Err(MutateError::InvalidInput { .. })));
}

#[test]
fn every_mutation_returns_change_not_found_for_a_divergent_change_id() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    let _twin_commit_hex = test_helpers::add_divergent_twin(&fx.path, &layout.commit1_commit_hex, "twin");
    let divergent = ChangeId(layout.commit1_change_id);
    let mut repo = Repo::open(&fx.path).unwrap();

    assert!(matches!(
        repo.describe(divergent.clone(), "x"),
        Err(MutateError::ChangeNotFound { .. })
    ));
    assert!(matches!(
        repo.new_change(std::slice::from_ref(&divergent)),
        Err(MutateError::ChangeNotFound { .. })
    ));
    assert!(matches!(
        repo.edit(divergent.clone()),
        Err(MutateError::ChangeNotFound { .. })
    ));
    assert!(matches!(
        repo.abandon(std::slice::from_ref(&divergent)),
        Err(MutateError::ChangeNotFound { .. })
    ));
}
