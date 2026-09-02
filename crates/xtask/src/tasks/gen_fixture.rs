// SPDX-License-Identifier: MIT

use std::path::{Path, PathBuf};
use std::sync::Arc;

use clap::{ArgGroup, Args};
use jj_lib::backend::{CommitId, CopyId, MillisSinceEpoch, Signature, Timestamp, TreeValue};
use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::merged_tree::MergedTree;
use jj_lib::op_store::RefTarget;
use jj_lib::ref_name::RefNameBuf;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::settings::UserSettings;
use jj_lib::store::Store;
use jj_lib::transaction::Transaction;
use jj_lib::tree_builder::TreeBuilder;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;

type BoxError = Box<dyn std::error::Error + Send + Sync + 'static>;

const AUTHOR_NAME: &str = "Fixture";
const AUTHOR_EMAIL: &str = "fixture@zanshin.test";
// Fixed base timestamp: ~2001-09-09 01:46:40 UTC (Unix epoch + 1e12 ms)
const BASE_MILLIS: i64 = 1_000_000_000_000;

/// Arguments for the `gen-fixture` subcommand.
#[derive(Args, Clone, Copy)]
#[command(group(ArgGroup::new("mode").required(true)))]
pub struct GenFixtureArgs {
    /// Size of fixture to generate
    #[arg(long, value_enum, group = "mode")]
    size: Option<FixtureSize>,
    /// Generate the default fixture set (tiny + medium). `large` is opt-in via `--size large`
    /// (heavy, regenerated deliberately for perf work — see test-fixtures/repos/README.md).
    #[arg(long, group = "mode")]
    all: bool,
}

#[derive(clap::ValueEnum, Clone, Copy)]
enum FixtureSize {
    Tiny,
    Medium,
    Large,
}

pub fn run(args: GenFixtureArgs) -> Result<(), BoxError> {
    if args.all {
        generate(FixtureSize::Tiny)?;
        generate(FixtureSize::Medium)?;
    } else if let Some(size) = args.size {
        generate(size)?;
    } else {
        // The clap ArgGroup already guarantees exactly one of --size/--all is set; this arm
        // keeps that invariant local and fail-loud should the attribute ever be weakened.
        return Err("exactly one of --size or --all must be provided".into());
    }
    Ok(())
}

fn fixture_name(size: FixtureSize) -> &'static str {
    match size {
        FixtureSize::Tiny => "tiny-3-commits",
        FixtureSize::Medium => "medium-1k-commits",
        FixtureSize::Large => "large-10k-commits",
    }
}

fn generate(size: FixtureSize) -> Result<(), BoxError> {
    let name = fixture_name(size);
    println!("Generating {name}...");

    let temp = TempDir::new()?;
    let workspace_root = temp.path().to_path_buf();

    let settings = make_settings()?;
    // WHY: `gix::hash::Kind::Sha1` mirrors jj's own `git.object-hash` default, so regenerated
    // fixtures keep the same object hashes as the committed ones.
    let (_workspace, repo) = pollster::block_on(Workspace::init_internal_git(
        &settings,
        &workspace_root,
        gix::hash::Kind::Sha1,
    ))?;

    match size {
        FixtureSize::Tiny => build_tiny(&repo)?,
        FixtureSize::Medium => build_medium(&repo)?,
        FixtureSize::Large => build_large(&repo)?,
    }

    let out_dir = output_dir();
    std::fs::create_dir_all(&out_dir)?;
    let archive_path = out_dir.join(format!("{name}.tar.zst"));
    archive_workspace(&workspace_root, &archive_path)?;

    let size_bytes = std::fs::metadata(&archive_path)?.len();
    println!("  → {} ({size_bytes} bytes)", archive_path.display());
    Ok(())
}

// CARGO_MANIFEST_DIR is crates/xtask/; two parents up is the workspace root.
fn output_dir() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .expect("crates/xtask has a parent")
        .parent()
        .expect("crates has a parent (workspace root)")
        .join("test-fixtures")
        .join("repos")
}

fn make_settings() -> Result<UserSettings, BoxError> {
    let config_text = format!(
        r#"
        [user]
        name = "{AUTHOR_NAME}"
        email = "{AUTHOR_EMAIL}"
        [operation]
        username = "fixture"
        hostname = "zanshin.test"
        [debug]
        randomness-seed = 42
        "#
    );
    let mut config = StackedConfig::with_defaults();
    config.add_layer(ConfigLayer::parse(ConfigSource::User, &config_text)?);
    Ok(UserSettings::from_config(config)?)
}

fn sig(commit_index: u32) -> Signature {
    Signature {
        name: AUTHOR_NAME.to_owned(),
        email: AUTHOR_EMAIL.to_owned(),
        timestamp: Timestamp {
            timestamp: MillisSinceEpoch(BASE_MILLIS + i64::from(commit_index) * 60_000),
            tz_offset: 0,
        },
    }
}

fn make_tree(store: &Arc<Store>, commit_index: u32) -> Result<MergedTree, BoxError> {
    let mut builder = TreeBuilder::new(store.clone(), store.empty_tree_id().clone());
    let path = RepoPathBuf::from_internal_string(format!("commit-{commit_index}.txt"))?;
    let content = format!("commit {commit_index}\n");
    // WHY: &[u8] implements futures AsyncRead, which jj-lib 0.42's Store::write_file wants;
    // no Cursor / tokio wrapper needed (the tokio io-util dep was dropped with this change).
    let mut reader = content.as_bytes();
    let file_id = pollster::block_on(store.write_file(&path, &mut reader))?;
    builder.set(
        path,
        TreeValue::File {
            id: file_id,
            executable: false,
            copy_id: CopyId::placeholder(),
        },
    );
    let tree_id = pollster::block_on(builder.write_tree())?;
    Ok(MergedTree::resolved(store.clone(), tree_id))
}

fn write_commit(
    store: &Arc<Store>,
    tx: &mut Transaction,
    parents: Vec<CommitId>,
    commit_index: u32,
    description: impl Into<String>,
) -> Result<CommitId, BoxError> {
    let tree = make_tree(store, commit_index)?;
    let s = sig(commit_index);
    let commit = pollster::block_on(
        tx.repo_mut()
            .new_commit(parents, tree)
            .set_author(s.clone())
            .set_committer(s)
            .set_description(description)
            .write(),
    )?;
    Ok(commit.id().clone())
}

fn build_tiny(repo: &Arc<ReadonlyRepo>) -> Result<(), BoxError> {
    let store = repo.store().clone();
    let root_id = store.root_commit_id().clone();
    let mut tx = repo.start_transaction();
    let mut parent = root_id;

    for i in 0u32..3 {
        parent = write_commit(&store, &mut tx, vec![parent], i + 1, format!("Commit {}", i + 1))?;
    }

    pollster::block_on(tx.commit("gen-fixture: tiny-3-commits"))?;
    Ok(())
}

fn build_medium(repo: &Arc<ReadonlyRepo>) -> Result<(), BoxError> {
    let store = repo.store().clone();
    let root_id = store.root_commit_id().clone();
    let mut tx = repo.start_transaction();
    let mut idx: u32 = 0; // global commit counter (for tree file names + timestamps)
    let mut bookmarks: Vec<(String, CommitId)> = Vec::new();

    // ── Phase 1: 200 linear commits ──────────────────────────────────────────
    let mut head = root_id;
    for i in 0u32..200 {
        idx += 1;
        head = write_commit(&store, &mut tx, vec![head], idx, format!("Linear-{idx}"))?;
        if (i + 1) % 33 == 0 {
            bookmarks.push((format!("bookmark-{}", bookmarks.len() + 1), head.clone()));
        }
    }
    let branch_base = head.clone();

    // ── Branch A: 66 commits (parent = branch_base) ──────────────────────────
    let mut a = branch_base.clone();
    for i in 0u32..66 {
        idx += 1;
        a = write_commit(&store, &mut tx, vec![a], idx, format!("BranchA-{i}"))?;
    }
    let tip_a = a;
    bookmarks.push(("branch-a".to_owned(), tip_a.clone()));

    // ── Branch B: 66 commits ─────────────────────────────────────────────────
    let mut b = branch_base.clone();
    for i in 0u32..66 {
        idx += 1;
        b = write_commit(&store, &mut tx, vec![b], idx, format!("BranchB-{i}"))?;
    }
    let tip_b = b;
    bookmarks.push(("branch-b".to_owned(), tip_b.clone()));

    // ── Branch C: 66 commits ─────────────────────────────────────────────────
    let mut c = branch_base.clone();
    for i in 0u32..66 {
        idx += 1;
        c = write_commit(&store, &mut tx, vec![c], idx, format!("BranchC-{i}"))?;
    }
    let tip_c = c;
    bookmarks.push(("branch-c".to_owned(), tip_c.clone()));

    // ── Merge commit (parents: A, B, C) ──────────────────────────────────────
    idx += 1;
    head = write_commit(
        &store,
        &mut tx,
        vec![tip_a, tip_b, tip_c],
        idx,
        "Merge branches A, B, and C",
    )?;
    bookmarks.push(("merge".to_owned(), head.clone()));

    // ── Phase 2: 601 linear commits ──────────────────────────────────────────
    for _ in 0u32..601 {
        idx += 1;
        head = write_commit(&store, &mut tx, vec![head], idx, format!("Linear-{idx}"))?;
        if idx.is_multiple_of(33) {
            bookmarks.push((format!("bookmark-{}", bookmarks.len() + 1), head.clone()));
        }
    }
    bookmarks.push(("tip".to_owned(), head.clone()));

    // ── Apply bookmarks ───────────────────────────────────────────────────────
    {
        let mut_repo = tx.repo_mut();
        for (name, commit_id) in bookmarks {
            let ref_name: RefNameBuf = name.into();
            mut_repo.set_local_bookmark_target(&ref_name, RefTarget::normal(commit_id));
        }
    }

    pollster::block_on(tx.commit("gen-fixture: medium-1k-commits"))?;
    Ok(())
}

// Same shape as `build_medium`, scaled 10×: 2000 linear → 3×660 branches → merge → 6019
// linear = 10 000 commits. Bookmarks every 200 commits plus the named branch/merge/tip refs.
fn build_large(repo: &Arc<ReadonlyRepo>) -> Result<(), BoxError> {
    let store = repo.store().clone();
    let root_id = store.root_commit_id().clone();
    let mut tx = repo.start_transaction();
    let mut idx: u32 = 0; // global commit counter (for tree file names + timestamps)
    let mut bookmarks: Vec<(String, CommitId)> = Vec::new();

    // ── Phase 1: 2000 linear commits ─────────────────────────────────────────
    let mut head = root_id;
    for _ in 0u32..2000 {
        idx += 1;
        head = write_commit(&store, &mut tx, vec![head], idx, format!("Linear-{idx}"))?;
        if idx.is_multiple_of(200) {
            bookmarks.push((format!("bookmark-{}", bookmarks.len() + 1), head.clone()));
        }
    }
    let branch_base = head.clone();

    // ── Branches A / B / C: 660 commits each (parent = branch_base) ───────────
    let mut tips: Vec<CommitId> = Vec::with_capacity(3);
    for (label, name) in [
        ("BranchA", "branch-a"),
        ("BranchB", "branch-b"),
        ("BranchC", "branch-c"),
    ] {
        let mut h = branch_base.clone();
        for i in 0u32..660 {
            idx += 1;
            h = write_commit(&store, &mut tx, vec![h], idx, format!("{label}-{i}"))?;
        }
        bookmarks.push((name.to_owned(), h.clone()));
        tips.push(h);
    }

    // ── Merge commit (parents: A, B, C) ──────────────────────────────────────
    idx += 1;
    head = write_commit(&store, &mut tx, tips, idx, "Merge branches A, B, and C")?;
    bookmarks.push(("merge".to_owned(), head.clone()));

    // ── Phase 2: 6019 linear commits ─────────────────────────────────────────
    for _ in 0u32..6019 {
        idx += 1;
        head = write_commit(&store, &mut tx, vec![head], idx, format!("Linear-{idx}"))?;
        if idx.is_multiple_of(200) {
            bookmarks.push((format!("bookmark-{}", bookmarks.len() + 1), head.clone()));
        }
    }
    bookmarks.push(("tip".to_owned(), head.clone()));

    // ── Apply bookmarks ───────────────────────────────────────────────────────
    {
        let mut_repo = tx.repo_mut();
        for (name, commit_id) in bookmarks {
            let ref_name: RefNameBuf = name.into();
            mut_repo.set_local_bookmark_target(&ref_name, RefTarget::normal(commit_id));
        }
    }

    pollster::block_on(tx.commit("gen-fixture: large-10k-commits"))?;
    Ok(())
}

fn archive_workspace(workspace_root: &Path, archive_path: &Path) -> Result<(), BoxError> {
    // Write to a sibling temp file and atomically rename into place, so an interrupted or
    // concurrent run can never leave a truncated `.tar.zst` behind (the output path is fixed
    // per fixture).
    let mut tmp_path = archive_path.as_os_str().to_owned();
    tmp_path.push(".tmp");
    let tmp_path = PathBuf::from(tmp_path);

    let out_file = std::fs::File::create(&tmp_path)?;
    let encoder = zstd::Encoder::new(out_file, 19)?;
    let mut builder = tar::Builder::new(encoder);
    builder.append_dir_all(".", workspace_root)?;
    let encoder = builder.into_inner()?;
    encoder.finish()?.sync_all()?;
    std::fs::rename(&tmp_path, archive_path)?;
    Ok(())
}
