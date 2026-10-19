// SPDX-License-Identifier: MIT

use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};

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

/// The environment every test binary pins so no developer config leaks in: no user/system
/// config (`JJ_CONFIG=""`), no global git config, and a fixed identity + operation metadata
/// through jj's own `EnvOverrides` variables — the identity half of what jj's own test harness
/// pins. That harness also fixes `JJ_TIMESTAMP`, `JJ_OP_TIMESTAMP`, `JJ_RANDOMNESS_SEED`,
/// `JJ_TZ_OFFSET_MINS`, `HOME`, `GIT_CONFIG_SYSTEM=/dev/null` and a hermetic
/// `GIT_CONFIG_COUNT` set (`cli/tests/common/test_environment.rs:130-177` @ v0.44.0), which
/// this suite leaves to the process environment — so the system git config is NOT excluded.
pub const TEST_ENV: [(&str, &str); 6] = [
    ("JJ_CONFIG", ""),
    ("GIT_CONFIG_GLOBAL", ""),
    ("JJ_USER", "Zanshin"),
    ("JJ_EMAIL", "zanshin@localhost"),
    ("JJ_OP_HOSTNAME", "localhost"),
    ("JJ_OP_USERNAME", "zanshin"),
];

/// A fresh temp dir that stays on disk (`TempDir::keep` — never deleted, not even when the
/// process exits), for a test binary's `$XDG_CONFIG_HOME`
/// (Story 9.37): opening a repo and every precondition-running verb run the CLI's start-up
/// secure-config fix-up, which MIGRATES a legacy `.jj/repo/config.toml` /
/// `.jj/workspace-config.toml` into `$XDG_CONFIG_HOME/jj/{repos,workspaces}/<id>/` — without
/// the pin, a test writing such a file would populate the developer's real `~/.config/jj`.
///
/// # Panics
/// Panics if the temp dir cannot be created.
#[must_use]
pub fn leaked_xdg_config_home() -> PathBuf {
    TempDir::new().expect("xdg tempdir").keep()
}

/// Pins [`TEST_ENV`] into the process environment, once per test binary — plus a
/// [`leaked_xdg_config_home`] as `$XDG_CONFIG_HOME`, so the secure config store is the test's.
///
/// The one pin helper `zanshin-jj`'s INLINE test modules share, so the lib test binary never
/// reads the developer's real config; integration-test binaries keep their own `ENV_GUARD`s.
///
/// # Panics
/// Panics if the temp dir cannot be created.
pub fn pin_test_env() {
    static GUARD: LazyLock<()> = LazyLock::new(|| {
        let xdg = leaked_xdg_config_home();
        for (name, value) in TEST_ENV {
            // SAFETY: test-only; runs once, before this binary's tests read the environment
            // through jj (the same pattern every `ENV_GUARD` in the suite uses).
            unsafe { std::env::set_var(name, value) };
        }
        // SAFETY: as above.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", &xdg) };
    });
    LazyLock::force(&GUARD);
}

/// `UserSettings` for tests that load a workspace through jj-lib directly: jj-lib's defaults
/// with the pinned identity variables (`JJ_USER`, `JJ_EMAIL`, `JJ_OP_HOSTNAME`,
/// `JJ_OP_USERNAME`) layered on top when they are set — the same `EnvOverrides` values
/// `zanshin-jj` itself reads, so a test's own writes are signed like Zanshin's.
///
/// # Panics
/// Panics if the pinned values do not form valid settings (they always do).
#[must_use]
pub fn test_settings() -> UserSettings {
    let mut layer = ConfigLayer::empty(ConfigSource::EnvOverrides);
    for (var, name) in [
        ("JJ_USER", "user.name"),
        ("JJ_EMAIL", "user.email"),
        ("JJ_OP_HOSTNAME", "operation.hostname"),
        ("JJ_OP_USERNAME", "operation.username"),
    ] {
        if let Ok(value) = std::env::var(var) {
            layer
                .set_value(name, value)
                .expect("a fresh layer takes any dotted key");
        }
    }
    let mut config = StackedConfig::with_defaults();
    config.add_layer(layer);
    UserSettings::from_config_and_home_dir(config, None).expect("valid settings")
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

/// Builds jj's changed-path index for every commit at the head operation of the workspace at
/// `root` — the CLI's `jj debug index-changed-paths` (`cli/src/commands/debug/
/// index_changed_paths.rs` @ v0.44.0, jj-lib `DefaultIndexStore::build_changed_path_index_at_operation`).
///
/// With it, `Commit::is_empty` answers from the index instead of loading the parents and
/// merging their trees — the store kind Story 4.10's bench compares against. Writes index
/// files only; no operation.
///
/// # Panics
/// Panics on any jj-lib failure, or if the repo's index store is not jj's default one.
pub fn build_changed_path_index(root: &Path) {
    let (workspace, repo) = load(root);
    let index_store = workspace.repo_loader().index_store();
    let default_store = index_store
        .downcast_ref::<jj_lib::default_index::DefaultIndexStore>()
        .expect("the default index store");
    pollster::block_on(default_store.build_changed_path_index_at_operation(
        repo.op_id(),
        repo.store(),
        u32::MAX,
        |_| {},
    ))
    .unwrap();
}

// ── Shared plumbing ───────────────────────────────────────────────────────────

/// Loads the workspace at `workspace_root` and its head repo.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
fn load(workspace_root: &Path) -> (Workspace, Arc<ReadonlyRepo>) {
    let settings = test_settings();
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

/// What a tree entry should BE, for [`add_commit_with_entries`].
///
/// The committed fixtures hold only plain, non-executable files (`xtask`'s
/// `gen_fixture.rs` writes one `commit-<n>.txt` per commit) and regenerating them is
/// forbidden — it would shift the revset oracles. So an executable file, a symlink, and a
/// multi-entry tree are all unconstructible from a fixture alone, which is exactly what
/// `jj file list`'s `file_type`/`executable` fields and `jj file show`'s skip rules need.
#[derive(Clone, Copy, Debug)]
pub enum Entry<'a> {
    /// A regular, non-executable file with this content.
    File(&'a str),
    /// A regular file with this content and the executable bit SET.
    Executable(&'a str),
    /// A symbolic link pointing at this target.
    Symlink(&'a str),
}

/// Writes a tree built from an EMPTY base holding exactly `entries` (repo-relative internal
/// path → what the entry is).
fn entry_tree(store: &Arc<Store>, entries: &[(&str, Entry<'_>)]) -> MergedTree {
    let mut builder = TreeBuilder::new(store.clone(), store.empty_tree_id().clone());
    for (path, entry) in entries {
        let path = RepoPathBuf::from_internal_string(*path).unwrap();
        let value = match entry {
            Entry::File(content) | Entry::Executable(content) => {
                let mut reader = content.as_bytes();
                let id = pollster::block_on(store.write_file(&path, &mut reader)).unwrap();
                TreeValue::File {
                    id,
                    executable: matches!(entry, Entry::Executable(_)),
                    copy_id: CopyId::placeholder(),
                }
            }
            Entry::Symlink(target) => {
                TreeValue::Symlink(pollster::block_on(store.write_symlink(&path, target)).unwrap())
            }
        };
        builder.set(path, value);
    }
    let tree_id = pollster::block_on(builder.write_tree()).unwrap();
    MergedTree::resolved(store.clone(), tree_id)
}

/// Writes a tree built from an EMPTY base holding exactly `files` (repo-relative internal
/// path → content), all plain non-executable files.
fn multi_file_tree(store: &Arc<Store>, files: &[(&str, &str)]) -> MergedTree {
    let entries: Vec<(&str, Entry<'_>)> = files.iter().map(|(p, c)| (*p, Entry::File(c))).collect();
    entry_tree(store, &entries)
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

/// Like [`add_commit_with_files`], but each entry says what it IS — a plain file, an
/// EXECUTABLE file, or a SYMLINK — instead of only carrying content.
///
/// The one way to build a tree holding an executable or a symlink: the committed fixtures
/// contain neither, and regenerating them is forbidden. `jj file list`'s `file_type` and
/// `executable` fields, and `jj file show`'s "exists but is not a file" skip rule, are
/// otherwise unconstructible.
///
/// # Panics
/// Panics on any jj-lib failure (workspace load, transaction, commit write) — this is a
/// test helper; a failure here is a broken fixture, not a condition to recover from.
#[must_use = "the new commit id is what the assertions compare against"]
pub fn add_commit_with_entries(
    workspace_root: &Path,
    parents: &[&str],
    entries: &[(&str, Entry<'_>)],
    description: &str,
) -> String {
    let (_workspace, repo) = load(workspace_root);
    let store = repo.store().clone();
    let parent_ids: Vec<CommitId> = if parents.is_empty() {
        vec![store.root_commit_id().clone()]
    } else {
        parents.iter().map(|hex| commit_id(hex)).collect()
    };
    let tree = entry_tree(&store, entries);

    let mut tx = repo.start_transaction();
    let commit = pollster::block_on(
        tx.repo_mut()
            .new_commit(parent_ids, tree)
            .set_description(description)
            .write(),
    )
    .unwrap();
    pollster::block_on(tx.repo_mut().add_head(&commit)).unwrap();
    pollster::block_on(tx.commit("test: add commit with entries")).unwrap();
    commit.id().hex()
}

/// Parses a hex commit id.
fn commit_id(hex: &str) -> CommitId {
    CommitId::try_from_hex(hex).unwrap()
}

/// The hex tree id the commit `commit_id_hex` points at.
///
/// Trees are content-addressed, so comparing tree hexes is how a test asserts file CONTENT
/// without reading blobs: a purpose-built commit holding the expected files has the same
/// tree id as the expected result of a `restore`/`absorb`. Lives here rather than in one
/// test file because both `zanshin-jj` and `zanshin-ffi` integration tests need it, and
/// only this crate depends on `jj_lib` for test purposes.
///
/// # Panics
/// Panics on any jj-lib failure, or if the commit's tree is CONFLICTED (a conflicted tree
/// has no single id — a test that hits this wants a different assertion).
#[must_use = "the tree hex is what the assertions compare against"]
pub fn tree_hex(workspace_root: &Path, commit_id_hex: &str) -> String {
    let (_workspace, repo) = load(workspace_root);
    repo.store()
        .get_commit(&commit_id(commit_id_hex))
        .unwrap()
        .tree_ids()
        .as_resolved()
        .expect("the commit's tree must be conflict-free")
        .hex()
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

/// Rewrites `commit_id_hex` with a NEW TREE holding exactly `files`, as an external edit
/// followed by `jj commit` would; returns the rewritten commit's hex id.
///
/// The [`describe_commit`] twin for CONTENT. `describe_commit` changes only the description, so
/// every version of that change shares one tree and an interdiff between two of them is
/// trivially empty — which makes it useless as the input to "what differs between two versions
/// of this change". This helper is what gives an evolution chain a non-empty per-version diff,
/// so an `evolog` predecessor fed back into `interdiff` reports something.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
#[must_use = "the rewritten commit id is what the assertions compare against"]
pub fn rewrite_commit_files(workspace_root: &Path, commit_id_hex: &str, files: &[(&str, &str)]) -> String {
    let (_workspace, repo) = load(workspace_root);
    let store = repo.store().clone();
    let commit = repo.store().get_commit(&commit_id(commit_id_hex)).unwrap();
    let tree = multi_file_tree(&store, files);

    let mut tx = repo.start_transaction();
    let rewritten = pollster::block_on(tx.repo_mut().rewrite_commit(&commit).set_tree(tree).write()).unwrap();
    pollster::block_on(tx.repo_mut().rebase_descendants()).unwrap();
    pollster::block_on(tx.commit("test: rewrite commit files")).unwrap();
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
    conflicted_merge(workspace_root, &[])
}

/// Like [`add_conflicted_merge_off_root`], but the RIGHT side additionally introduces
/// `right_extra` (repo-relative internal path → content). The left side does not have those
/// paths, so the merge resolves them cleanly while still conflicting at `conflicted.txt`.
///
/// That combination is what an absorb test needs: one path jj-lib refuses to split and one
/// whose line annotates unambiguously to a single mutable ancestor.
///
/// # Panics
/// Panics on any jj-lib failure — a failure here is a broken fixture.
#[must_use = "the conflicted merge's commit id is what the assertions compare against"]
pub fn add_conflicted_merge_with_extra_files(workspace_root: &Path, right_extra: &[(&str, &str)]) -> String {
    conflicted_merge(workspace_root, right_extra)
}

/// Shared body of the two conflicted-merge helpers.
fn conflicted_merge(workspace_root: &Path, right_extra: &[(&str, &str)]) -> String {
    let (_workspace, repo) = load(workspace_root);
    let store = repo.store().clone();
    let root_id = store.root_commit_id().clone();

    let mut tx = repo.start_transaction();
    let mut side = Vec::with_capacity(2);
    for (content, extra) in [("left\n", &[][..]), ("right\n", right_extra)] {
        let mut files: Vec<(&str, &str)> = vec![("conflicted.txt", content)];
        files.extend_from_slice(extra);
        let tree = multi_file_tree(&store, &files);
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
    // WHY canonicalize first: since jj 0.46 the workspace store records the NEW workspace's root
    // RELATIVE to the LOADER's repo path and every read joins the record back onto the reading
    // loader's — which is canonical for `Repo::open` (and the CLI, whose cwd is canonical).
    // Loading through the RAW argument (on macOS a `/var/folders/…` temp path that is a symlink
    // to `/private/var/folders/…`) records one `..` too few and nothing ever resolves. The
    // production verb, `Repo::workspace_add` (Story 9.23), holds a `Repo` whose workspace is
    // canonical end to end and gets the same alignment for free; this helper stays for tests that
    // need a second workspace without running a verb.
    let workspace_root = std::fs::canonicalize(workspace_root).unwrap();
    let (workspace, repo) = load(&workspace_root);
    let temp = TempDir::new().unwrap();
    let second_root = temp.path().join(name);
    std::fs::create_dir_all(&second_root).unwrap();
    let repo_path = workspace.workspace_root().join(".jj").join("repo");
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
