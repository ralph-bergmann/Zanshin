// SPDX-License-Identifier: MIT

//! Fixture tests for the direct `View` reads of Story 9.2 — `Repo::list_tags`,
//! `Repo::list_heads` and `Repo::list_working_copies`.
//!
//! The fixtures carry no remote refs (regenerating them is forbidden), so the tracked/untracked
//! remote-tag rows are constructed in-test via `test_helpers::set_remote_tag`.

use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId;
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::{add_commit_off_root, add_workspace, extract_fixture, set_remote_tag, set_tag};
use zanshin_jj::{Repo, TagKind, ViewError};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    // WHY: empty string pins jj-lib/git off the developer's globals for reproducibility.
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

/// Opens the fixture as a raw jj-lib `Workspace` for oracle reads.
fn oracle_workspace(root: &Path) -> Workspace {
    Workspace::load(
        &make_test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load")
}

/// The change id (reverse-hex) of the commit whose hex commit id is `commit_hex` — an
/// independent jj-lib oracle for the tag rows' `target`.
fn change_id_of(workspace_root: &Path, commit_hex: &str) -> String {
    let workspace = oracle_workspace(workspace_root);
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let commit_id = jj_lib::backend::CommitId::try_from_hex(commit_hex).expect("valid commit hex");
    repo.store().get_commit(&commit_id).unwrap().change_id().reverse_hex()
}

/// The head commit ids jj-lib's `View::heads()` holds — an unordered oracle for `list_heads`.
fn head_hexes(workspace_root: &Path) -> HashSet<String> {
    let workspace = oracle_workspace(workspace_root);
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    repo.view().heads().iter().map(ObjectId::hex).collect()
}

/// The `(workspace name, wc commit hex)` pairs jj-lib's `View::wc_commit_ids()` holds.
fn wc_pairs(workspace_root: &Path) -> Vec<(String, String)> {
    let workspace = oracle_workspace(workspace_root);
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    repo.view()
        .wc_commit_ids()
        .iter()
        .map(|(name, id)| (name.as_str().to_owned(), id.hex()))
        .collect()
}

/// Removes `op_heads` so the next head resolution fails — the `ViewError::Backend` driver.
fn corrupt_op_heads(workspace_root: &Path) {
    fs::remove_dir_all(workspace_root.join(".jj").join("repo").join("op_heads")).unwrap();
}

// ── Tags: absence is an empty list, never an error ───────────────────────────

#[test]
fn tags_on_untouched_tiny_returns_empty() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let tags = repo.list_tags().unwrap();
    assert!(tags.is_empty(), "tiny fixture ships no tags; got {tags:?}");
}

// ── Tags: a local tag resolves to its target's CHANGE id ─────────────────────

#[test]
fn tags_local_resolves_to_the_targets_change_id() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let commit = add_commit_off_root(&fx.path, "9.2: tagged");
    set_tag(&fx.path, "v1", &[&commit]);
    let expected = change_id_of(&fx.path, &commit);

    let repo = Repo::open(&fx.path).unwrap();
    let tags = repo.list_tags().unwrap();

    assert_eq!(tags.len(), 1, "exactly one tag row; got {tags:?}");
    assert_eq!(tags[0].name, "v1");
    assert_eq!(tags[0].kind, TagKind::Local);
    assert_eq!(tags[0].target.0, expected, "target must be the commit's change id");
}

// ── Tags: a tracked remote tag is an ADDITIONAL row, listed unfiltered ───────

/// A tracked remote tag pointing at the SAME commit as the local one is deliberately NOT
/// hidden: the CLI's `jj tag list` drops it (`cli/src/commit_ref_list.rs` @ v0.44.0's
/// `include_synced_remotes`), but that is a display default — `list_tags` mirrors
/// `list_bookmarks` and offers the unfiltered view.
#[test]
fn tags_tracked_remote_adds_a_row_even_when_synced_with_the_local_one() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let commit = add_commit_off_root(&fx.path, "9.2: tagged");
    set_tag(&fx.path, "v1", &[&commit]);
    set_remote_tag(&fx.path, "v1", "origin", &commit, true);
    let expected = change_id_of(&fx.path, &commit);

    let repo = Repo::open(&fx.path).unwrap();
    let tags = repo.list_tags().unwrap();

    assert_eq!(tags.len(), 2, "local + tracked-remote = two rows; got {tags:?}");
    // Sorted by name then kind: Local before Remote.
    assert_eq!(tags[0].kind, TagKind::Local, "Local must precede Remote for one name");
    assert_eq!(
        tags[1].kind,
        TagKind::Remote {
            remote_name: "origin".to_owned()
        }
    );
    assert!(
        tags.iter().all(|t| t.name == "v1" && t.target.0 == expected),
        "both rows name the same tag and target; got {tags:?}"
    );
}

// ── Tags: an untracked remote tag is skipped ─────────────────────────────────

#[test]
fn tags_skip_untracked_remote() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let commit = add_commit_off_root(&fx.path, "9.2: tagged");
    set_remote_tag(&fx.path, "loose", "origin", &commit, false);

    let repo = Repo::open(&fx.path).unwrap();
    let tags = repo.list_tags().unwrap();

    assert!(
        tags.is_empty(),
        "a present-but-untracked remote tag must be skipped; got {tags:?}"
    );
}

// ── Tags: a conflicted target uses the FIRST added id (listing scope only) ────

#[test]
fn tags_conflicted_target_uses_first_added_change_id() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let first = add_commit_off_root(&fx.path, "9.2: conflict a");
    let second = add_commit_off_root(&fx.path, "9.2: conflict b");
    set_tag(&fx.path, "contested", &[&first, &second]);
    let expected = change_id_of(&fx.path, &first);

    let repo = Repo::open(&fx.path).unwrap();
    let tags = repo.list_tags().unwrap();

    assert_eq!(tags.len(), 1, "a conflicted tag is still ONE row; got {tags:?}");
    assert_eq!(
        tags[0].target.0, expected,
        "a conflicted tag must resolve to the FIRST added id's change id"
    );
}

// ── Tags: sorted by name, then kind ──────────────────────────────────────────

#[test]
fn tags_are_sorted_by_name_then_kind() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let commit = add_commit_off_root(&fx.path, "9.2: tagged");
    // Written out of order; the listing must still come back sorted.
    set_tag(&fx.path, "v2", &[&commit]);
    set_tag(&fx.path, "v1", &[&commit]);
    set_remote_tag(&fx.path, "v1", "origin", &commit, true);

    let repo = Repo::open(&fx.path).unwrap();
    let tags = repo.list_tags().unwrap();

    let seen: Vec<(&str, &TagKind)> = tags.iter().map(|t| (t.name.as_str(), &t.kind)).collect();
    assert_eq!(
        seen,
        vec![
            ("v1", &TagKind::Local),
            (
                "v1",
                &TagKind::Remote {
                    remote_name: "origin".to_owned()
                }
            ),
            ("v2", &TagKind::Local),
        ],
        "tags must be sorted by name then kind"
    );
}

// ── Tags: backend failure ────────────────────────────────────────────────────

#[test]
fn tags_on_corrupt_repo_returns_backend_error() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();
    let repo = Repo::open(tmp.path()).unwrap();

    // Corrupt AFTER open: every listing re-resolves to head per call (ADR-0002).
    corrupt_op_heads(tmp.path());

    let result = repo.list_tags();
    assert!(
        matches!(result, Err(ViewError::Backend(_))),
        "corrupt op_heads must yield ViewError::Backend, got: {result:?}"
    );
}

// ── Heads: the same set jj-lib holds, sorted by hex (our determinism guarantee) ─

#[test]
fn heads_equal_the_view_oracle_and_are_sorted_by_hex() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    // A second head off root, so the set is genuinely > 1 and the sort has work to do.
    _ = add_commit_off_root(&fx.path, "9.2: second head");

    let repo = Repo::open(&fx.path).unwrap();
    let heads = repo.list_heads().unwrap();

    let got: HashSet<String> = heads.iter().map(|id| id.0.clone()).collect();
    assert_eq!(got, head_hexes(&fx.path), "heads must equal View::heads()");
    assert!(heads.len() >= 2, "the fixture plus the new head give >=2 heads");

    let mut sorted = heads.iter().map(|id| id.0.clone()).collect::<Vec<_>>();
    sorted.sort();
    assert_eq!(
        heads.iter().map(|id| id.0.clone()).collect::<Vec<_>>(),
        sorted,
        "heads must be sorted by hex — View::heads() is an unordered HashSet"
    );
}

#[test]
fn heads_on_corrupt_repo_returns_backend_error() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();
    let repo = Repo::open(tmp.path()).unwrap();

    corrupt_op_heads(tmp.path());

    let result = repo.list_heads();
    assert!(
        matches!(result, Err(ViewError::Backend(_))),
        "corrupt op_heads must yield ViewError::Backend, got: {result:?}"
    );
}

// ── Working copies: one row per workspace, in BTreeMap order ─────────────────

#[test]
fn working_copies_on_a_single_workspace_repo_reports_one_row() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wcs = repo.list_working_copies().unwrap();

    let oracle = wc_pairs(&fx.path);
    assert_eq!(wcs.len(), 1, "the fixture has one workspace; got {wcs:?}");
    assert_eq!(
        wcs.iter()
            .map(|w| (w.workspace_name.clone(), w.commit_id.0.clone()))
            .collect::<Vec<_>>(),
        oracle,
        "the row must be View::wc_commit_ids()'s single entry"
    );
}

/// The view half of `jj workspace list`: name → commit id for EVERY workspace, in jj-lib's own
/// `BTreeMap` (lexicographic-by-name) order. No workspace *path* is reported — that lives in the
/// `WorkspaceStore` and is Story 9.7's scope.
#[test]
fn working_copies_multi_workspace_are_in_btreemap_order() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    // `_second` keeps the second workspace's directory alive for the duration of the test.
    let (_second, second_wc) = add_workspace(&fx.path, "second");

    let repo = Repo::open(&fx.path).unwrap();
    let wcs = repo.list_working_copies().unwrap();

    assert_eq!(wcs.len(), 2, "default + second = two workspaces; got {wcs:?}");
    let names: Vec<&str> = wcs.iter().map(|w| w.workspace_name.as_str()).collect();
    let mut sorted = names.clone();
    sorted.sort_unstable();
    assert_eq!(names, sorted, "rows keep jj-lib's lexicographic BTreeMap order");

    let second_row = wcs
        .iter()
        .find(|w| w.workspace_name == "second")
        .expect("the added workspace must be listed");
    assert_eq!(
        second_row.commit_id.0, second_wc,
        "the second workspace's row must carry ITS working-copy commit id"
    );
    assert_eq!(
        wcs.iter()
            .map(|w| (w.workspace_name.clone(), w.commit_id.0.clone()))
            .collect::<Vec<_>>(),
        wc_pairs(&fx.path),
        "the listing must equal View::wc_commit_ids() entry for entry"
    );
}

#[test]
fn working_copies_on_corrupt_repo_returns_backend_error() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();
    let repo = Repo::open(tmp.path()).unwrap();

    corrupt_op_heads(tmp.path());

    let result = repo.list_working_copies();
    assert!(
        matches!(result, Err(ViewError::Backend(_))),
        "corrupt op_heads must yield ViewError::Backend, got: {result:?}"
    );
}
