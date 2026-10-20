// SPDX-License-Identifier: MIT

use std::fs;
use std::path::Path;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::gitignore::GitIgnoreFile;
use jj_lib::matchers::EverythingMatcher;
use jj_lib::repo::Repo as _;
use jj_lib::working_copy::SnapshotOptions;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{Backend, ChangeKind, Repo, StatusError};

/// Snapshots the on-disk working copy into a new `@` commit.
///
/// TEST SETUP ONLY — an out-of-band snapshot through jj-lib (with its own test options), so a
/// test can stage `@` independently of the pre-verb snapshot every `Repo` read runs (Story 9.26).
fn snapshot_working_copy(workspace_root: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let settings = test_helpers::test_settings();
    let mut workspace = Workspace::load(
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
    let parents = wc_commit.parent_ids().to_vec();

    let mut locked = pollster::block_on(workspace.start_working_copy_mutation())?;
    let opts = SnapshotOptions {
        base_ignores: GitIgnoreFile::empty(),
        progress: None,
        start_tracking_matcher: &EverythingMatcher,
        force_tracking_matcher: &EverythingMatcher,
        max_new_file_size: u64::MAX,
    };
    let (new_tree, _stats) = pollster::block_on(locked.locked_wc().snapshot(&opts))?;

    let mut tx = repo.start_transaction();
    let new_commit = pollster::block_on(tx.repo_mut().new_commit(parents, new_tree).write())?;
    tx.repo_mut().set_wc_commit(workspace_name, new_commit.id().clone())?;
    let new_repo = pollster::block_on(tx.commit("test: snapshot"))?;
    pollster::block_on(locked.finish(new_repo.op_id().clone()))?;

    Ok(())
}

/// Creates a new `@` commit with the current `@` as its parent (like `jj new`).
///
/// TEST SETUP ONLY — needed to advance the parent pointer so subsequent
/// snapshots produce Modified/Removed entries rather than re-stating Added.
fn jj_new(workspace_root: &Path) -> Result<(), Box<dyn std::error::Error>> {
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
    let new_commit = pollster::block_on(tx.repo_mut().new_commit(vec![wc_id], wc_tree).write())?;
    tx.repo_mut().set_wc_commit(workspace_name, new_commit.id().clone())?;
    pollster::block_on(tx.commit("test: jj new"))?;

    Ok(())
}

/// Removes the working-copy commit from `@`'s workspace (like `jj workspace forget`),
/// leaving the workspace with no `@`.
///
/// TEST SETUP ONLY — drives the `StatusError::NoWorkingCopy` path.
fn remove_working_copy(workspace_root: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )?;
    let repo = pollster::block_on(workspace.repo_loader().load_at_head())?;
    let workspace_name = workspace.workspace_name().to_owned();

    let mut tx = repo.start_transaction();
    pollster::block_on(tx.repo_mut().remove_workspace(&workspace_name))?;
    // remove_wc_commit rewrites the abandoned @; jj requires descendants rebased
    // before the transaction can commit (same discipline as repo.rs clone_into).
    pollster::block_on(tx.repo_mut().rebase_descendants())?;
    pollster::block_on(tx.commit("test: remove working-copy commit"))?;

    Ok(())
}

/// Returns `(working_copy, parent)` change ids of `@` as jj reverse-hex, computed
/// directly via jj-lib — an independent oracle for what `Repo::status()` reports.
fn wc_and_parent_change_ids(workspace_root: &Path) -> (String, String) {
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
    let wc_change = wc_commit.change_id().reverse_hex();
    let parent_change = if let Some(pid) = wc_commit.parent_ids().first() {
        repo.store().get_commit(pid).unwrap().change_id().reverse_hex()
    } else {
        let root_id = repo.store().root_commit_id().clone();
        repo.store().get_commit(&root_id).unwrap().change_id().reverse_hex()
    };
    (wc_change, parent_change)
}

// ── AC-3: clean working copy ─────────────────────────────────────────────────

#[test]
fn status_on_clean_fixture_returns_no_files() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fixture.path).unwrap();
    let status = repo.status().unwrap();
    assert!(status.files.is_empty());
    assert!(!status.working_copy_change_id.0.is_empty());
    assert!(!status.parent_change_id.0.is_empty());
}

// ── AC-4: Added ──────────────────────────────────────────────────────────────

#[test]
fn status_on_added_file_returns_added() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

    fs::write(tmp.path().join("new_file.txt"), b"hello").unwrap();
    snapshot_working_copy(tmp.path()).unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    let status = repo.status().unwrap();

    assert_eq!(status.files.len(), 1);
    assert_eq!(status.files[0].path.to_str().unwrap(), "new_file.txt");
    assert!(matches!(status.files[0].kind, ChangeKind::Added));
}

// ── AC-4: Modified ───────────────────────────────────────────────────────────

#[test]
fn status_on_modified_file_returns_modified() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

    fs::write(tmp.path().join("file.txt"), b"original").unwrap();
    snapshot_working_copy(tmp.path()).unwrap();
    jj_new(tmp.path()).unwrap();

    fs::write(tmp.path().join("file.txt"), b"modified").unwrap();
    snapshot_working_copy(tmp.path()).unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    let status = repo.status().unwrap();

    assert_eq!(status.files.len(), 1);
    assert_eq!(status.files[0].path.to_str().unwrap(), "file.txt");
    assert!(matches!(status.files[0].kind, ChangeKind::Modified));
}

// ── AC-4: Removed ────────────────────────────────────────────────────────────

#[test]
fn status_on_removed_file_returns_removed() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

    fs::write(tmp.path().join("file.txt"), b"content").unwrap();
    snapshot_working_copy(tmp.path()).unwrap();
    jj_new(tmp.path()).unwrap();

    fs::remove_file(tmp.path().join("file.txt")).unwrap();
    snapshot_working_copy(tmp.path()).unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    let status = repo.status().unwrap();

    assert_eq!(status.files.len(), 1);
    assert_eq!(status.files[0].path.to_str().unwrap(), "file.txt");
    assert!(matches!(status.files[0].kind, ChangeKind::Removed));
}

// ── AC-6: Rename on git backend ───────────────────────────────────────────────

#[test]
fn status_on_renamed_file_on_git_backend_returns_renamed() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .unwrap();

    fs::write(tmp.path().join("old_name.txt"), b"content to rename").unwrap();
    snapshot_working_copy(tmp.path()).unwrap();
    jj_new(tmp.path()).unwrap();

    fs::rename(tmp.path().join("old_name.txt"), tmp.path().join("new_name.txt")).unwrap();
    snapshot_working_copy(tmp.path()).unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    let status = repo.status().unwrap();

    // One rename entry, NO separate Added+Removed pair (AC-11).
    assert_eq!(
        status.files.len(),
        1,
        "expected exactly one file entry (rename, not add+remove); got {:?}",
        status.files.iter().map(|f| (&f.path, &f.kind)).collect::<Vec<_>>()
    );
    assert_eq!(status.files[0].path.to_str().unwrap(), "new_name.txt");
    assert!(
        matches!(&status.files[0].kind, ChangeKind::Renamed { from } if from.to_str().unwrap() == "old_name.txt"),
        "expected Renamed {{ from: old_name.txt }}, got {:?}",
        status.files[0].kind
    );
}

// ── AC-3/4: change-id population ─────────────────────────────────────────────

#[test]
fn status_working_copy_change_id_reflects_current_wc_commit() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

    fs::write(tmp.path().join("file.txt"), b"content").unwrap();
    snapshot_working_copy(tmp.path()).unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    let status = repo.status().unwrap();

    // Assert the reported ids EQUAL the actual @ / @- change ids (computed
    // independently via jj-lib), not merely that they are non-empty (AC-4 item 8).
    let (expected_wc, expected_parent) = wc_and_parent_change_ids(tmp.path());
    assert_eq!(status.working_copy_change_id.0, expected_wc);
    assert_eq!(status.parent_change_id.0, expected_parent);
    assert!(!expected_wc.is_empty());
}

// ── AC-5: error paths (NoWorkingCopy / Backend) ──────────────────────────────

#[test]
fn status_on_workspace_without_wc_commit_returns_no_working_copy() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();
    remove_working_copy(tmp.path()).unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();
    let result = repo.status();

    assert!(
        matches!(result, Err(StatusError::NoWorkingCopy)),
        "expected NoWorkingCopy, got: {result:?}"
    );
}

#[test]
fn status_on_corrupt_repo_returns_backend_error() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();

    // Corrupt AFTER open: status() re-resolves to head on every call (ADR-0002),
    // so removing op_heads makes head re-resolution fail -> StatusError::Backend.
    let op_heads = tmp.path().join(".jj").join("repo").join("op_heads");
    fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.status();

    assert!(
        matches!(result, Err(StatusError::Precondition(zanshin_jj::PreconditionError::Backend(_)))),
        "the pre-verb snapshot fails first (Story 9.26, as the CLI would): expected Backend error on corrupt repo, got: {result:?}"
    );
}
