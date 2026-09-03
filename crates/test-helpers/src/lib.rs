// SPDX-License-Identifier: MIT

use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::backend::{CommitId, CopyId, TreeValue};
use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_working_copy_factories, default_working_copy_factory};
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::{RefTarget, RemoteRef, RemoteRefState};
use jj_lib::ref_name::{RefNameBuf, RemoteRefSymbol, WorkspaceNameBuf};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::settings::UserSettings;
use jj_lib::store::Store;
use jj_lib::tree_builder::TreeBuilder;
use jj_lib::workspace::Workspace;
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
    let (_workspace, repo) = load(workspace_root);
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

// ── Shared plumbing ───────────────────────────────────────────────────────────

/// Loads the workspace at `workspace_root` and its head repo.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
fn load(workspace_root: &Path) -> (Workspace, Arc<ReadonlyRepo>) {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    (workspace, repo)
}

/// Writes a single-file tree holding `content` at `path`.
fn one_file_tree(store: &Arc<Store>, path: &str, content: &str) -> MergedTree {
    multi_file_tree(store, &[(path, content)])
}

/// Writes a tree built from an EMPTY base holding exactly `files` (repo-relative internal
/// path → content).
fn multi_file_tree(store: &Arc<Store>, files: &[(&str, &str)]) -> MergedTree {
    let mut builder = TreeBuilder::new(store.clone(), store.empty_tree_id().clone());
    for (path, content) in files {
        let path = RepoPathBuf::from_internal_string(*path).unwrap();
        let mut reader = content.as_bytes();
        let file_id = pollster::block_on(store.write_file(&path, &mut reader)).unwrap();
        builder.set(
            path,
            TreeValue::File {
                id: file_id,
                executable: false,
                copy_id: CopyId::placeholder(),
            },
        );
    }
    let tree_id = pollster::block_on(builder.write_tree()).unwrap();
    MergedTree::resolved(store.clone(), tree_id)
}

/// Adds a visible commit on top of `parents` (hex commit ids; an EMPTY slice parents it on
/// the root commit) whose tree holds exactly `files`, and returns its hex commit id.
///
/// The committed fixtures give every commit a single unique file (`xtask`'s
/// `gen_fixture.rs` builds each commit's tree from an empty base with only
/// `commit-<n>.txt`), so no fixture path survives across commits. That makes
/// "an ancestor introduced this line" — `absorb`'s precondition, and any multi-file
/// `restore` — unconstructible from a fixture alone, and regenerating fixtures is
/// forbidden (it would shift the revset oracles).
///
/// # Panics
/// Panics on any jj-lib failure (workspace load, transaction, commit write) — this is a
/// test helper; a failure here is a broken fixture, not a condition to recover from.
#[must_use = "the new commit id is what the assertions compare against"]
pub fn add_commit_with_files(
    workspace_root: &Path,
    parents: &[&str],
    files: &[(&str, &str)],
    description: &str,
) -> String {
    let (_workspace, repo) = load(workspace_root);
    let store = repo.store().clone();
    let parent_ids: Vec<CommitId> = if parents.is_empty() {
        vec![store.root_commit_id().clone()]
    } else {
        parents.iter().map(|hex| commit_id(hex)).collect()
    };
    let tree = multi_file_tree(&store, files);

    let mut tx = repo.start_transaction();
    let commit = pollster::block_on(
        tx.repo_mut()
            .new_commit(parent_ids, tree)
            .set_description(description)
            .write(),
    )
    .unwrap();
    pollster::block_on(tx.repo_mut().add_head(&commit)).unwrap();
    pollster::block_on(tx.commit("test: add commit with files")).unwrap();
    commit.id().hex()
}

/// Parses a hex commit id.
fn commit_id(hex: &str) -> CommitId {
    CommitId::try_from_hex(hex).unwrap()
}

// ── Write helpers for Story 4.8's edge-state tests ────────────────────────────

/// Rewrites `commit_id_hex`'s description in a new operation, as an external `jj describe`
/// would; returns the rewritten commit's hex id.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
#[must_use = "the rewritten commit id is what the assertions compare against"]
pub fn describe_commit(workspace_root: &Path, commit_id_hex: &str, description: &str) -> String {
    let (_workspace, repo) = load(workspace_root);
    let commit = repo.store().get_commit(&commit_id(commit_id_hex)).unwrap();

    let mut tx = repo.start_transaction();
    let rewritten = pollster::block_on(
        tx.repo_mut()
            .rewrite_commit(&commit)
            .set_description(description)
            .write(),
    )
    .unwrap();
    pollster::block_on(tx.repo_mut().rebase_descendants()).unwrap();
    pollster::block_on(tx.commit("test: describe")).unwrap();
    rewritten.id().hex()
}

/// Adds a SECOND visible commit carrying `commit_id_hex`'s change id, making that change
/// divergent; returns the new commit's hex id.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
#[must_use = "the divergent twin's commit id is what the assertions compare against"]
pub fn add_divergent_twin(workspace_root: &Path, commit_id_hex: &str, description: &str) -> String {
    let (_workspace, repo) = load(workspace_root);
    let commit = repo.store().get_commit(&commit_id(commit_id_hex)).unwrap();

    let mut tx = repo.start_transaction();
    // A NEW commit (not a rewrite — that would hide the original) reusing the change id is
    // exactly what makes the change resolve to two visible commits.
    let twin = pollster::block_on(
        tx.repo_mut()
            .new_commit(commit.parent_ids().to_vec(), commit.tree())
            .set_change_id(commit.change_id().clone())
            .set_description(description)
            .write(),
    )
    .unwrap();
    pollster::block_on(tx.repo_mut().add_head(&twin)).unwrap();
    pollster::block_on(tx.commit("test: create divergent twin")).unwrap();
    twin.id().hex()
}

/// Abandons `commit_id_hex` so it becomes hidden (its change id no longer resolves to it).
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
pub fn abandon_commit(workspace_root: &Path, commit_id_hex: &str) {
    let (_workspace, repo) = load(workspace_root);
    let commit = repo.store().get_commit(&commit_id(commit_id_hex)).unwrap();

    let mut tx = repo.start_transaction();
    tx.repo_mut().record_abandoned_commit(&commit);
    pollster::block_on(tx.repo_mut().rebase_descendants()).unwrap();
    pollster::block_on(tx.commit("test: abandon")).unwrap();
}

/// Creates two siblings off root that write the same path differently, plus their merge —
/// whose tree therefore has an unresolved conflict. Returns the merge commit's hex id.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
#[must_use = "the conflicted merge's commit id is what the assertions compare against"]
pub fn add_conflicted_merge_off_root(workspace_root: &Path) -> String {
    let (_workspace, repo) = load(workspace_root);
    let store = repo.store().clone();
    let root_id = store.root_commit_id().clone();

    let mut tx = repo.start_transaction();
    let mut side = Vec::with_capacity(2);
    for content in ["left\n", "right\n"] {
        let tree = one_file_tree(&store, "conflicted.txt", content);
        let commit = pollster::block_on(
            tx.repo_mut()
                .new_commit(vec![root_id.clone()], tree)
                .set_description(format!("side {content}"))
                .write(),
        )
        .unwrap();
        side.push(commit);
    }
    let merged = pollster::block_on(jj_lib::rewrite::merge_commit_trees(tx.repo(), &side)).unwrap();
    let parents = side.iter().map(|c| c.id().clone()).collect();
    let merge = pollster::block_on(
        tx.repo_mut()
            .new_commit(parents, merged)
            .set_description("conflicted merge")
            .write(),
    )
    .unwrap();
    pollster::block_on(tx.repo_mut().add_head(&merge)).unwrap();
    pollster::block_on(tx.commit("test: conflicted merge")).unwrap();
    merge.id().hex()
}

/// Points the local bookmark `name` at `targets`. More than one target writes a CONFLICTED
/// bookmark; an empty slice deletes it.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
pub fn set_local_bookmark(workspace_root: &Path, name: &str, targets: &[&str]) {
    let (_workspace, repo) = load(workspace_root);
    let mut tx = repo.start_transaction();
    let ref_name: RefNameBuf = name.into();
    tx.repo_mut().set_local_bookmark_target(&ref_name, ref_target(targets));
    pollster::block_on(tx.commit("test: set local bookmark")).unwrap();
}

/// Points the local tag `name` at `targets` (same conflict/delete semantics as
/// [`set_local_bookmark`]).
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
pub fn set_tag(workspace_root: &Path, name: &str, targets: &[&str]) {
    let (_workspace, repo) = load(workspace_root);
    let mut tx = repo.start_transaction();
    let ref_name: RefNameBuf = name.into();
    tx.repo_mut().set_local_tag_target(&ref_name, ref_target(targets));
    pollster::block_on(tx.commit("test: set tag")).unwrap();
}

/// Points the remote bookmark `name@remote` at `target`. `tracked` selects the remote-ref
/// state the CLI's synced/untracked rules key off.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
pub fn set_remote_bookmark(workspace_root: &Path, name: &str, remote: &str, target: &str, tracked: bool) {
    let (_workspace, repo) = load(workspace_root);
    let mut tx = repo.start_transaction();
    let ref_name: RefNameBuf = name.into();
    let remote_name: jj_lib::ref_name::RemoteNameBuf = remote.into();
    tx.repo_mut().set_remote_bookmark(
        RemoteRefSymbol {
            name: &ref_name,
            remote: &remote_name,
        },
        RemoteRef {
            target: ref_target(&[target]),
            state: if tracked {
                RemoteRefState::Tracked
            } else {
                RemoteRefState::New
            },
        },
    );
    pollster::block_on(tx.commit("test: set remote bookmark")).unwrap();
}

/// Points the remote tag `name@remote` at `target`. `tracked` selects the remote-ref state the
/// tag listing's tracked/untracked filter keys off.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
pub fn set_remote_tag(workspace_root: &Path, name: &str, remote: &str, target: &str, tracked: bool) {
    let (_workspace, repo) = load(workspace_root);
    let mut tx = repo.start_transaction();
    let ref_name: RefNameBuf = name.into();
    let remote_name: jj_lib::ref_name::RemoteNameBuf = remote.into();
    tx.repo_mut().set_remote_tag(
        RemoteRefSymbol {
            name: &ref_name,
            remote: &remote_name,
        },
        RemoteRef {
            target: ref_target(&[target]),
            state: if tracked {
                RemoteRefState::Tracked
            } else {
                RemoteRefState::New
            },
        },
    );
    pollster::block_on(tx.commit("test: set remote tag")).unwrap();
}

/// Builds a `RefTarget` from hex commit ids: none = absent, one = normal, more = conflicted.
fn ref_target(targets: &[&str]) -> RefTarget {
    match targets {
        [] => RefTarget::absent(),
        [single] => RefTarget::normal(commit_id(single)),
        adds => RefTarget::from_legacy_form(
            // A conflict needs (adds - 1) removes to stay a valid merge.
            std::iter::repeat_n(commit_id(adds[0]), adds.len() - 1),
            adds.iter().map(|hex| commit_id(hex)),
        ),
    }
}

/// Creates a SECOND workspace named `name` for the repo at `workspace_root`, in its own
/// temp directory, and returns a handle keeping that directory alive plus the new
/// workspace's working-copy commit hex id.
///
/// # WHY the extra `TempDir`: the tests run in parallel, so a fixed sibling path next to
/// the fixture (which itself lives directly under the system temp dir) would collide
/// between concurrently-running tests.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
#[must_use = "the handle keeps the second workspace alive; dropping it deletes the directory"]
pub fn add_workspace(workspace_root: &Path, name: &str) -> (FixtureHandle, String) {
    let (_workspace, repo) = load(workspace_root);
    let temp = TempDir::new().unwrap();
    let second_root = temp.path().join(name);
    std::fs::create_dir_all(&second_root).unwrap();
    let repo_path = workspace_root.join(".jj").join("repo");
    let (second, repo) = pollster::block_on(Workspace::init_workspace_with_existing_repo(
        &second_root,
        &repo_path,
        &repo,
        default_working_copy_factory().as_ref(),
        WorkspaceNameBuf::from(name.to_owned()),
    ))
    .unwrap();
    let wc = repo
        .view()
        .get_wc_commit_id(second.workspace_name())
        .expect("the new workspace has a working-copy commit")
        .hex();
    let path = second.workspace_root().to_owned();
    (FixtureHandle { _temp: temp, path }, wc)
}
