// SPDX-License-Identifier: MIT

use std::path::{Path, PathBuf};

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::{default_working_copy_factories, Workspace};
use tempfile::TempDir;

/// Handle returned by [`extract_fixture`]. Keeps the temp directory alive while the caller holds
/// this value; dropped automatically on `Drop`, which deletes the extracted files.
pub struct FixtureHandle {
    _temp: TempDir,
    /// Absolute path to the extracted workspace root (the directory containing `.jj/`).
    pub path: PathBuf,
}

/// Extracts the named fixture archive into a fresh temp directory and returns a handle.
///
/// `name` must match a file under `test-fixtures/repos/<name>.tar.zst` at the workspace root.
/// The archive is located via `CARGO_MANIFEST_DIR` so this works regardless of which crate's
/// integration tests call it.
///
/// # Panics
/// Panics if `CARGO_MANIFEST_DIR` is not at least two directory levels deep (invariant guaranteed
/// by Cargo for any crate inside `crates/*`).
///
/// # Errors
/// Returns an error if the archive cannot be opened, decompressed, or extracted.
pub fn extract_fixture(name: &str) -> Result<FixtureHandle, Box<dyn std::error::Error>> {
    // CARGO_MANIFEST_DIR is crates/test-helpers/ — two parents up is the workspace root.
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let workspace_root = manifest
        .parent()
        .expect("crates/test-helpers has a parent")
        .parent()
        .expect("crates has a parent (workspace root)");

    let archive_path = workspace_root
        .join("test-fixtures")
        .join("repos")
        .join(format!("{name}.tar.zst"));

    let archive_file = std::fs::File::open(&archive_path)
        .map_err(|e| format!("cannot open fixture archive {}: {e}", archive_path.display()))?;

    let decoder = zstd::Decoder::new(archive_file)?;
    let mut archive = tar::Archive::new(decoder);

    let temp = TempDir::new()?;
    archive.unpack(temp.path())?;

    let path = temp.path().to_path_buf();
    Ok(FixtureHandle { _temp: temp, path })
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

/// Adds a visible commit off root to the jj workspace at `workspace_root` via an external
/// jj-lib transaction (a new operation in `jj op log`), returning its hex commit id —
/// simulates an external `jj` process mutating the repo (ADR-0002 re-derive tests).
///
/// # Panics
/// Panics on any jj-lib failure (workspace load, transaction, commit write) — this is a
/// test helper; a failure here is a broken fixture, not a condition to recover from.
#[must_use = "the new commit id is what the re-derive assertions compare against"]
pub fn add_commit_off_root(workspace_root: &Path, description: &str) -> String {
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
    let commit = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![root_id], root_commit.tree())
            .set_description(description)
            .write(),
    )
    .unwrap();
    pollster::block_on(tx.repo_mut().add_head(&commit)).unwrap();
    pollster::block_on(tx.commit("test: add external commit")).unwrap();
    commit.id().hex()
}
