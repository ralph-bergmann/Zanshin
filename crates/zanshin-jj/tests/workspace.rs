// SPDX-License-Identifier: MIT

//! Fixture tests for Story 9.7's two workspace READ verbs — `Repo::list_workspaces` and
//! `Repo::resolve_workspace_root`.
//!
//! The committed `tiny-3-commits` fixture is a free witness for the interesting rows: its
//! `.jj/repo/workspace_store/index` records `default` → the GENERATOR's temp directory, which no
//! longer exists after extraction. So the fixture as shipped already exercises BOTH halves of the
//! CLI's asymmetry — `list` degrades to `root: None` while `resolve_root(Some("default"))`
//! refuses. Regenerating the fixture to "fix" that staleness is forbidden AND would destroy the
//! witness.
//!
//! Every path comparison canonicalizes BOTH sides: on macOS the system temp dir is
//! `/var/folders/…`, a symlink to `/private/var/folders/…`, and only one side of a naive
//! comparison goes through it (`tests/repo.rs:211-214` pins the same trap).

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::{add_workspace, extract_fixture};
use zanshin_jj::{Repo, WorkspaceError};

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

/// The `(workspace name, wc commit hex)` pairs jj-lib's `View::wc_commit_ids()` holds — the raw
/// oracle for the VIEW half, so a re-derivation instead of a reuse would show up here.
fn wc_pairs(workspace_root: &Path) -> Vec<(String, String)> {
    let workspace = oracle_workspace(workspace_root);
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    repo.view()
        .wc_commit_ids()
        .iter()
        .map(|(name, id)| (name.as_str().to_owned(), id.hex()))
        .collect()
}

/// The name/commit half of a `list_workspaces` result, in the same shape as [`wc_pairs`].
fn entry_pairs(entries: &[zanshin_jj::WorkspaceEntry]) -> Vec<(String, String)> {
    entries
        .iter()
        .map(|e| (e.name.clone(), e.wc_commit_id.0.clone()))
        .collect()
}

/// The `.jj/repo/workspace_store` directory of the workspace rooted at `workspace_root`.
fn store_dir(workspace_root: &Path) -> PathBuf {
    workspace_root.join(".jj").join("repo").join("workspace_store")
}

/// Removes the whole workspace store, so no path is recorded for any workspace. jj-lib's
/// `SimpleWorkspaceStore::load` then RE-CREATES the directory with an empty store — its own
/// legacy-repo path, which writes no operation.
fn remove_workspace_store(workspace_root: &Path) {
    fs::remove_dir_all(store_dir(workspace_root)).expect("the fixture has a workspace store");
}

/// Overwrites the store index with bytes that are not a valid protobuf, so `read_store` fails.
/// A missing or corrupt index is an `Err`, never a `None` — the two states are genuinely
/// different and the two verbs treat them differently.
fn corrupt_workspace_store(workspace_root: &Path) {
    fs::write(store_dir(workspace_root).join("index"), b"not a protobuf at all").expect("index must be writable");
}

/// Removes `op_heads` so the next head resolution fails — the `Backend` driver for the VIEW half.
fn corrupt_op_heads(workspace_root: &Path) {
    fs::remove_dir_all(workspace_root.join(".jj").join("repo").join("op_heads")).unwrap();
}

/// The head operation's id, so a test can assert that a READ wrote nothing.
fn head_op_id(repo: &Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).id.0
}

/// Adds a second workspace whose recorded path can actually be resolved back.
///
/// # WHY canonicalize first: `SimpleWorkspaceStore::add` records the new root RELATIVE to the
/// `repo_path` the store was loaded with, while every read joins it onto
/// `Workspace::repo_path()`, which jj-lib has canonicalized. On macOS the system temp dir is
/// `/var/folders/…` → `/private/var/folders/…`, so handing `add_workspace` the raw fixture path
/// records one `..` too few and NOTHING would ever resolve. The real CLI never hits this: its
/// workspace loader canonicalizes before either side runs.
fn add_resolvable_workspace(workspace_root: &Path, name: &str) -> (test_helpers::FixtureHandle, String) {
    let canonical = fs::canonicalize(workspace_root).expect("the fixture root exists");
    add_workspace(&canonical, name)
}

/// Canonicalizes both sides before comparing — the macOS `/var` → `/private/var` trap.
fn assert_same_dir(actual: &Path, expected: &Path) {
    assert_eq!(
        fs::canonicalize(actual).expect("actual path must exist"),
        fs::canonicalize(expected).expect("expected path must exist"),
        "paths must match once both sides are canonicalized"
    );
}

// ── list: the view half is reused, the path half is added ────────────────────

/// The shipped fixture records a path that no longer exists, so its single row degrades: name and
/// commit are still reported, `root` is absent, and the call SUCCEEDS.
#[test]
fn list_on_the_fixture_reports_one_row_with_no_root() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&repo);

    let entries = repo.list_workspaces().unwrap();

    assert_eq!(entries.len(), 1, "the fixture has one workspace; got {entries:?}");
    assert_eq!(entries[0].name, "default");
    assert_eq!(
        entry_pairs(&entries),
        wc_pairs(&fx.path),
        "the name/commit half must equal View::wc_commit_ids() entry for entry"
    );
    assert_eq!(
        entries[0].root, None,
        "the fixture records the GENERATOR's temp dir, which no longer resolves"
    );
    assert_eq!(head_op_id(&repo), before, "a read must not write an operation");
}

/// A second workspace records a path that DOES resolve, so both halves of the row are exercised
/// at once: `default` still degrades while `second` reports its real directory.
#[test]
fn list_with_a_second_workspace_reports_its_resolvable_root() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    // `second` keeps the added workspace's directory alive for the duration of the test.
    let (second, second_wc) = add_resolvable_workspace(&fx.path, "second");

    let repo = Repo::open(&fx.path).unwrap();
    let entries = repo.list_workspaces().unwrap();

    assert_eq!(entries.len(), 2, "default + second; got {entries:?}");
    let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, ["default", "second"], "rows keep jj-lib's BTreeMap order");
    assert_eq!(
        entry_pairs(&entries),
        wc_pairs(&fx.path),
        "the name/commit half must equal View::wc_commit_ids() entry for entry"
    );
    assert_eq!(entries[1].wc_commit_id.0, second_wc);

    assert_eq!(entries[0].root, None, "default's recorded path is still stale");
    let root = entries[1].root.as_ref().expect("second's path resolves");
    assert_same_dir(root, &second.path);
}

/// No recorded path at all: the store directory is gone, jj-lib recreates it empty, and every row
/// degrades. Still `ok`.
#[test]
fn list_with_no_recorded_path_still_returns_the_row() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    remove_workspace_store(&fx.path);
    let repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&repo);

    let entries = repo.list_workspaces().unwrap();

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].name, "default");
    assert_eq!(entries[0].root, None);
    assert!(
        store_dir(&fx.path).is_dir(),
        "SimpleWorkspaceStore::load recreates the store dir for a legacy repo"
    );
    assert_eq!(
        head_op_id(&repo),
        before,
        "recreating the store writes no OPERATION, only files"
    );
}

/// An unreadable store is a path failure like any other: the listing still succeeds. This is the
/// one row where `list` is strictly more forgiving than the CLI's per-row template, which would
/// propagate the store-read error — the widening is deliberate, so a corrupt store cannot make a
/// GUI unable to enumerate its workspaces at all.
#[test]
fn list_with_an_unreadable_store_still_returns_the_rows() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    corrupt_workspace_store(&fx.path);
    let repo = Repo::open(&fx.path).unwrap();

    let entries = repo.list_workspaces().unwrap();

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].root, None, "a path failure NEVER fails the listing");
    assert_eq!(entry_pairs(&entries), wc_pairs(&fx.path));
}

/// The only failure `list` can report is the VIEW half's.
#[test]
fn list_on_a_corrupt_repo_returns_a_backend_error() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();
    let repo = Repo::open(tmp.path()).unwrap();

    corrupt_op_heads(tmp.path());

    let result = repo.list_workspaces();
    assert!(
        matches!(result, Err(WorkspaceError::Backend(_))),
        "corrupt op_heads must yield WorkspaceError::Backend, got: {result:?}"
    );
}

// ── root: the strict half ────────────────────────────────────────────────────

/// `None` reads the loader alone: it returns the open workspace's own root and cannot fail — not
/// even on the fixture, whose recorded path is stale.
#[test]
fn root_without_a_name_is_the_open_workspace() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&repo);

    let root = repo.resolve_workspace_root(None).unwrap();

    assert_same_dir(&root, repo.workspace_root());
    assert_same_dir(&root, &fx.path);
    assert_eq!(head_op_id(&repo), before, "a read must not write an operation");
}

/// A SIBLING workspace's path is visible from this one — the whole point of the verb.
#[test]
fn root_with_a_name_finds_a_sibling_workspace() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (second, _wc) = add_resolvable_workspace(&fx.path, "second");
    let repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&repo);

    let root = repo.resolve_workspace_root(Some("second")).unwrap();

    assert_same_dir(&root, &second.path);
    assert_eq!(head_op_id(&repo), before, "a read must not write an operation");
}

/// The CLI's asymmetry, in one test: `None` succeeds on the very repo where naming the SAME
/// workspace refuses, because the named path always goes through the store — which here holds the
/// generator's stale temp dir.
#[test]
fn root_named_current_workspace_refuses_where_the_default_path_succeeds() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&repo);

    assert!(repo.resolve_workspace_root(None).is_ok());

    let result = repo.resolve_workspace_root(Some("default"));
    match result {
        Err(WorkspaceError::PathUnresolved { name, reason }) => {
            assert_eq!(name, "default");
            assert!(!reason.is_empty(), "the I/O reason must be forwarded");
        }
        other => panic!("a stale recorded path must be PathUnresolved, got: {other:?}"),
    }
    assert_eq!(
        head_op_id(&repo),
        before,
        "a REFUSAL must not write an operation either"
    );
}

/// An unknown name, and an explicitly EMPTY one — an empty string is a VALUE, not an absence, and
/// no workspace is named `""`.
#[test]
fn root_with_an_unknown_or_empty_name_is_not_found() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&repo);

    for name in ["nosuch", ""] {
        let result = repo.resolve_workspace_root(Some(name));
        match result {
            Err(WorkspaceError::NotFound { name: reported }) => assert_eq!(reported, name),
            other => panic!("{name:?} must be NotFound, got: {other:?}"),
        }
    }
    assert_eq!(
        head_op_id(&repo),
        before,
        "a REFUSAL must not write an operation either"
    );
}

/// The workspace exists but the store holds no path for it — the pre-jj-0.38.0 state, which is a
/// DIFFERENT refusal from a stale path because nothing can be repaired.
#[test]
fn root_with_no_recorded_path_refuses_distinctly() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    remove_workspace_store(&fx.path);
    let repo = Repo::open(&fx.path).unwrap();

    let result = repo.resolve_workspace_root(Some("default"));
    match result {
        Err(WorkspaceError::NoRecordedPath { name }) => assert_eq!(name, "default"),
        other => panic!("an absent store entry must be NoRecordedPath, got: {other:?}"),
    }
}

/// An unreadable store is an `Err` from jj-lib, never an "absent entry" — so it must NOT collapse
/// into `NoRecordedPath`.
#[test]
fn root_with_an_unreadable_store_is_a_backend_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    corrupt_workspace_store(&fx.path);
    let repo = Repo::open(&fx.path).unwrap();

    let result = repo.resolve_workspace_root(Some("default"));
    assert!(
        matches!(result, Err(WorkspaceError::Backend(_))),
        "a corrupt store index must be Backend, not NoRecordedPath, got: {result:?}"
    );
}

/// The membership check runs against the head view, so a repo whose head cannot be resolved
/// refuses before it ever reaches the store lookup.
#[test]
fn root_with_a_name_on_a_corrupt_repo_is_a_backend_error() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();
    let repo = Repo::open(tmp.path()).unwrap();

    corrupt_op_heads(tmp.path());

    let result = repo.resolve_workspace_root(Some("default"));
    assert!(
        matches!(result, Err(WorkspaceError::Backend(_))),
        "an unresolvable head must yield Backend, got: {result:?}"
    );
    // The no-name path reads the loader alone, so it is unaffected by a broken op-heads dir.
    assert!(
        repo.resolve_workspace_root(None).is_ok(),
        "the loader-only path cannot fail"
    );
}
