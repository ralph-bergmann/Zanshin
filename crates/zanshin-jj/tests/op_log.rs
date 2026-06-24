// SPDX-License-Identifier: MIT

use std::fs;
use std::sync::LazyLock;
use std::{env, path::Path};

use futures::StreamExt as _;
use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_walk;
use jj_lib::repo::StoreFactories;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::{default_working_copy_factories, Workspace};
use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{OpLogError, Repo};

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

/// Open the fixture as a raw jj-lib `Workspace` for oracle reads.
fn oracle_workspace(root: &Path) -> (Workspace, UserSettings) {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        root,
        &StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    (workspace, settings)
}

// ── AC-3, AC-6: head op first, root op last ──────────────────────────────────

#[test]
fn op_log_on_tiny_returns_history_with_root_op_last() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(Some(1)).unwrap();

    assert_eq!(ops.len(), 1, "limit 1 must return exactly one op");
    // The single op returned is the head (most recent), so it must NOT be the root.
    assert!(!ops[0].root_op, "limit-1 result must be the head op, not the root");
}

#[test]
fn op_log_with_limit_zero_returns_empty() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(Some(0)).unwrap();
    assert!(ops.is_empty(), "limit 0 must return empty Vec");
}

#[test]
fn op_log_with_limit_over_count_equals_full_history() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(None).unwrap();
    let root = ops.last().expect("root must exist");

    assert!(root.root_op, "root_op must be true");
    assert!(root.parent_ids.is_empty(), "root parent_ids must be empty");
    assert_eq!(root.description, "", "root op description must be empty");
}

// ── AC-6: non-root op has parents and root_op == false ───────────────────────

#[test]
fn op_log_non_root_op_has_parents_and_root_op_false() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let ops = repo.op_log(None).unwrap();
    // The head op (index 0) is a regular operation — it has parents.
    let head = &ops[0];

    assert!(!head.root_op, "head op root_op must be false");
    assert!(!head.parent_ids.is_empty(), "head op must have at least one parent");
}

// ── AC-5: oracle equality for id / description / user / host ─────────────────

#[test]
fn op_log_head_op_matches_oracle() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();

    let repo = Repo::open(tmp.path()).unwrap();

    // Corrupt AFTER open: op_log() re-resolves to head on every call (ADR-0002),
    // so removing op_heads makes load_at_head() fail → OpLogError::Backend.
    let op_heads = tmp.path().join(".jj").join("repo").join("op_heads");
    fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.op_log(None);

    assert!(
        matches!(result, Err(OpLogError::Backend(_))),
        "corrupt repo must yield Backend error, got: {result:?}"
    );
}
