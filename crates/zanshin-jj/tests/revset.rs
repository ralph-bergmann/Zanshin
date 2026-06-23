// SPDX-License-Identifier: MIT

use std::collections::HashSet;
use std::env;
use std::path::Path;
use std::sync::LazyLock;

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::{default_working_copy_factories, Workspace};
use test_helpers::extract_fixture;
use zanshin_jj::{resolve_revset, Repo, RevsetError};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: empty string pins jj-lib/git off the developer's globals for reproducibility.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
    }
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

/// Returns `(working_copy_change_id, parent_change_id)` in reverse-hex form,
/// computed directly via jj-lib — an independent oracle for AC-2.
fn wc_and_parent_change_ids(workspace_root: &Path) -> (String, String) {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::repo::StoreFactories::default(),
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
    let wc_change = wc_commit.change_id().reverse_hex();
    let parent_change = if let Some(pid) = wc_commit.parent_ids().first() {
        repo.store().get_commit(pid).unwrap().change_id().reverse_hex()
    } else {
        let root_id = repo.store().root_commit_id().clone();
        repo.store().get_commit(&root_id).unwrap().change_id().reverse_hex()
    };
    (wc_change, parent_change)
}

/// Returns the set of distinct change ids (reverse-hex) reachable from local
/// bookmark targets — an independent oracle for AC-4.
fn local_bookmark_change_ids(workspace_root: &Path) -> HashSet<String> {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::repo::StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let mut out = HashSet::new();
    for (_name, target) in repo.view().local_bookmarks() {
        for commit_id in target.added_ids() {
            let commit = repo.store().get_commit(commit_id).unwrap();
            out.insert(commit.change_id().reverse_hex());
        }
    }
    out
}

// ── AC-2: `@` resolves to working-copy change id ────────────────────────────

#[test]
fn revset_on_at_returns_working_copy_change() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "@").unwrap();
    let (expected_wc, _) = wc_and_parent_change_ids(&fx.path);
    assert_eq!(result.len(), 1, "@ must resolve to exactly one change id");
    assert_eq!(
        result[0].0, expected_wc,
        "@ change id must equal working-copy change id"
    );
}

// ── AC-2: `@-` resolves to parent change id ─────────────────────────────────

#[test]
fn revset_on_at_minus_returns_parent_change() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "@-").unwrap();
    let (_, expected_parent) = wc_and_parent_change_ids(&fx.path);
    assert_eq!(result.len(), 1, "@- must resolve to exactly one change id");
    assert_eq!(result[0].0, expected_parent, "@- change id must equal parent change id");
}

// ── AC-3: `all()` on tiny includes root + fixture commits + working copy ────

#[test]
fn revset_on_all_tiny_includes_root_commits_and_wc() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "all()").unwrap();
    // 3 fixture commits + the virtual root commit + the working-copy `@` = 5.
    // AC-3 says "do not hard-pin to a single number", so allow a +/-1 band (4..=5)
    // tolerant of jj-lib counting the root differently across patch releases.
    assert!(
        (4..=5).contains(&result.len()),
        "all() on tiny-3-commits expected 4-5 (root + 3 commits + @), got {}",
        result.len()
    );
}

// ── AC-4: `bookmarks()` on medium equals oracle ──────────────────────────────

#[test]
fn revset_on_bookmarks_medium_equals_oracle() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "bookmarks()").unwrap();
    assert!(!result.is_empty(), "medium-1k-commits must have bookmarks");
    let result_set: HashSet<String> = result.iter().map(|id| id.0.clone()).collect();
    let oracle = local_bookmark_change_ids(&fx.path);
    assert_eq!(
        result_set, oracle,
        "bookmarks() change ids must match local bookmark targets"
    );
}

// ── AC-11: `heads(all())` is non-empty ──────────────────────────────────────

#[test]
fn revset_on_heads_all_is_non_empty() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "heads(all())").unwrap();
    assert!(!result.is_empty(), "heads(all()) must be non-empty");
}

// ── AC-11: `trunk()..@` resolves (trunk() alias present) ────────────────────

#[test]
fn revset_on_trunk_range_resolves_ok() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    // The fixture has no remote bookmarks → trunk() → root(), so trunk()..@ is valid.
    let result = resolve_revset(&repo, "trunk()..@");
    assert!(result.is_ok(), "trunk()..@ must resolve without error, got: {result:?}");
}

// ── AC-6: `none()` returns empty Vec ────────────────────────────────────────

#[test]
fn revset_on_none_returns_empty_vec() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "none()").unwrap();
    assert!(result.is_empty(), "none() must return empty Vec");
}

// ── AC-6: `~all()` also returns empty Vec ───────────────────────────────────

#[test]
fn revset_on_complement_all_returns_empty_vec() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "~all()").unwrap();
    assert!(result.is_empty(), "~all() must return empty Vec");
}

// ── AC-10: complex revset returns deduplicated Vec ───────────────────────────

#[test]
fn revset_complex_expression_returns_deduplicated() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "(trunk()..@) | (visible_heads() & ~::trunk())").unwrap();
    let ids: Vec<&str> = result.iter().map(|id| id.0.as_str()).collect();
    let unique: HashSet<&str> = ids.iter().copied().collect();
    assert_eq!(
        ids.len(),
        unique.len(),
        "complex revset result must contain no duplicate change ids"
    );
}

// ── AC-5: invalid expression → ParseError, no panic ─────────────────────────

#[test]
fn revset_bogus_function_returns_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "bogus_function()");
    assert!(
        matches!(result, Err(RevsetError::ParseError { .. })),
        "bogus_function() must return ParseError, got: {result:?}"
    );
}

// ── AC-7: non-existent bookmark → ResolutionError ───────────────────────────

#[test]
fn revset_nonexistent_branch_returns_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "nonexistent-branch");
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "nonexistent-branch must return ResolutionError, got: {result:?}"
    );
}

// ── AC-13: malformed change-id literal → ResolutionError ────────────────────

#[test]
fn revset_malformed_change_id_returns_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "xyz123notarealid");
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "xyz123notarealid must return ResolutionError, got: {result:?}"
    );
}

// ── AC-12: large fixture benchmark (soft target, #[ignore]) ─────────────────

#[test]
#[ignore = "soft performance target (< 200 ms); requires large-10k-commits fixture; run with --ignored --nocapture"]
fn revset_large_fixture_fully_materialized() {
    pin_env();
    let fx = extract_fixture("large-10k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let t = std::time::Instant::now();
    let result = resolve_revset(&repo, "all()").unwrap();
    let elapsed = t.elapsed();
    eprintln!(
        "[bench] all() on large-10k-commits: {} change ids in {:?}",
        result.len(),
        elapsed
    );
    assert!(!result.is_empty(), "large fixture must produce results");
}

// ── AC-10 helper: construct a genuine divergent change ──────────────────────

/// Creates a genuine divergent change in the repo at `workspace_root`: writes two
/// distinct visible commits that share one change id (via `set_change_id`), then
/// returns that change id in reverse-hex form. Divergence is the only state in which
/// `commit_change_ids()` yields the same change id twice, so this is what makes
/// `resolve_revset`'s dedup branch actually do work (AC-10).
fn make_divergent_change(workspace_root: &Path) -> String {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::repo::StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();

    let root_commit = repo.store().root_commit();
    let root_id = root_commit.id().clone();

    let mut tx = repo.start_transaction();
    // First commit off root; capture its randomly generated change id.
    let commit_a = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![root_id.clone()], root_commit.tree())
            .set_description("divergent a")
            .write(),
    )
    .unwrap();
    let shared_change = commit_a.change_id().clone();
    // Second commit off root forced onto the SAME change id (different description =>
    // different commit id) => the change id now belongs to two distinct commits.
    let commit_b = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![root_id], root_commit.tree())
            .set_change_id(shared_change)
            .set_description("divergent b")
            .write(),
    )
    .unwrap();
    assert_ne!(
        commit_a.id(),
        commit_b.id(),
        "the two commits must have distinct commit ids"
    );
    assert_eq!(
        commit_a.change_id(),
        commit_b.change_id(),
        "both commits must share one change id (divergence)"
    );
    // Make both visible heads so `all()` returns both.
    pollster::block_on(tx.repo_mut().add_head(&commit_a)).unwrap();
    pollster::block_on(tx.repo_mut().add_head(&commit_b)).unwrap();
    pollster::block_on(tx.commit("create divergent change for AC-10 dedup test")).unwrap();

    commit_a.change_id().reverse_hex()
}

/// Removes the working-copy commit, leaving the workspace with no `@`.
///
/// TEST SETUP ONLY — drives the `@`-with-no-working-copy resolution path.
fn remove_working_copy(workspace_root: &Path) {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::repo::StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let workspace_name = workspace.workspace_name().to_owned();

    let mut tx = repo.start_transaction();
    pollster::block_on(tx.repo_mut().remove_wc_commit(&workspace_name)).unwrap();
    // remove_wc_commit rewrites the abandoned @; jj requires descendants rebased
    // before the transaction can commit (mirrors tests/status.rs).
    pollster::block_on(tx.repo_mut().rebase_descendants()).unwrap();
    pollster::block_on(tx.commit("test: remove working-copy commit")).unwrap();
}

// ── AC-10: dedup is genuinely exercised against a real divergent change ──────

#[test]
fn revset_dedups_divergent_change_id() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    // One change id now belongs to two distinct visible commits.
    let div_change = make_divergent_change(&fx.path);

    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "all()").unwrap();

    // The divergent change id appears exactly once — this fails (count == 2) if
    // resolve_revset's `seen` HashSet dedup were removed.
    let occurrences = result.iter().filter(|id| id.0 == div_change).count();
    assert_eq!(
        occurrences, 1,
        "divergent change id {div_change} must be deduplicated to exactly one entry"
    );
    assert!(!result.is_empty(), "all() must be non-empty");

    // The whole result stays duplicate-free.
    let ids: Vec<&str> = result.iter().map(|id| id.0.as_str()).collect();
    let unique: HashSet<&str> = ids.iter().copied().collect();
    assert_eq!(ids.len(), unique.len(), "result must contain no duplicate change ids");
}

// ── AC-7: `@` with no working-copy commit → ResolutionError ──────────────────

#[test]
fn revset_on_at_without_working_copy_returns_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    remove_working_copy(&fx.path);

    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "@");
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "@ with no working-copy commit must return ResolutionError, got: {result:?}"
    );
}

// ── Internal jj-lib failure → JjLibError ─────────────────────────────────────

#[test]
fn revset_on_corrupt_repo_returns_jj_lib_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    // Corrupt AFTER open: resolve_revset re-resolves to head on every call (ADR-0002), so
    // removing op_heads makes load_at_head() fail → RevsetError::JjLibError (the internal
    // jj-lib-failure arm, distinct from the Parse/Resolution arms exercised above).
    let op_heads = fx.path.join(".jj").join("repo").join("op_heads");
    std::fs::remove_dir_all(&op_heads).unwrap();

    let result = resolve_revset(&repo, "all()");
    assert!(
        matches!(result, Err(RevsetError::JjLibError(_))),
        "corrupt op_heads must yield RevsetError::JjLibError, got: {result:?}"
    );
}
