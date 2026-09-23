// SPDX-License-Identifier: MIT

//! Integration tests for `Repo::file_track` / `Repo::file_untrack` (Story 9.22) — one witness
//! per row of the story's I/O matrix, the `cli/tests/test_file_track_untrack_commands.rs`
//! sequences @ v0.44.0, and the `base_ignores` chain.
//!
//! Every repo is built in-test (`Repo::init`, or `git init` + `convert_colocated` for the
//! colocated rows) because the rows need files ON DISK next to a working-copy state, which the
//! committed fixtures do not model. Repo-level knobs go into the LEGACY `.jj/repo/config.toml`,
//! which is the repo layer of a workspace without a `config-id`.

use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use futures::TryStreamExt as _;
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::gitignore::GitIgnoreFile;
use jj_lib::matchers::{EverythingMatcher, Matcher, NothingMatcher};
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::working_copy::SnapshotOptions;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{
    convert_colocated, Backend, ChangeId, MutateError, PreconditionError, Repo, SnapshotStats, StaleCause,
    UntrackedPath, UntrackedReason,
};

/// Env pin + two leaked process-lifetime dirs (the `tests/convert.rs` pattern):
/// `$XDG_CONFIG_HOME` (so `base_ignores`' `$XDG_CONFIG_HOME/git/ignore` fallback and any repo
/// config file land in a tempdir, never the developer's `~/.config`) and `$HOME` (so the
/// `core.excludesFile = "~/…"` expansion reads a tempdir).
///
/// SAFETY of the `set_var`s: every test calls `pin_env()` FIRST, and the `LazyLock` blocks all
/// of them until this initialiser returns, so no test body has read the environment yet.
static ENV_GUARD: LazyLock<(PathBuf, PathBuf)> = LazyLock::new(|| {
    let xdg = TempDir::new().expect("xdg tempdir").keep();
    let home = TempDir::new().expect("home tempdir").keep();
    // The global excludes file every git repo WITHOUT a `core.excludesFile` reads. Its one
    // pattern is unique to the test that relies on it, so it cannot disturb any other.
    fs::create_dir_all(xdg.join("git")).expect("xdg git dir");
    fs::write(xdg.join("git").join("ignore"), "*.xdgignored\n").expect("xdg git ignore");
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", &xdg);
        env::set_var("HOME", &home);
    }
    (xdg, home)
});

/// Pins the environment; returns the pinned `$HOME`.
fn pin_env() -> &'static Path {
    &ENV_GUARD.1
}

// ── Fixture plumbing ─────────────────────────────────────────────────────────────

/// A fresh workspace in its own tempdir; `root` is the canonical workspace root.
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
}

fn init(backend: Option<Backend>, repo_config: &str) -> Fx {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let root = Repo::init(tmp.path(), backend)
        .expect("init")
        .workspace_root()
        .to_owned();
    assert!(
        !root.join(".jj").join("repo").join("config-id").exists(),
        "a fresh repo must have no config-id, so the legacy file IS the repo layer"
    );
    fs::write(root.join(".jj").join("repo").join("config.toml"), repo_config).expect("repo config");
    Fx { _tmp: tmp, root }
}

/// An internal-git workspace with `repo_config` as its repo layer.
fn git_fx(repo_config: &str) -> Fx {
    init(Some(Backend::Git), repo_config)
}

/// Runs `git` in `dir`, panicking on failure; returns trimmed stdout.
fn git(args: &[&str], dir: &Path) -> String {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git spawns");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("utf-8").trim().to_owned()
}

/// A COLOCATED workspace: `git init` + one commit, converted in place.
fn colocated_fx() -> Fx {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    git(&["init", "--initial-branch=main"], tmp.path());
    git(&["config", "user.email", "test@zanshin.test"], tmp.path());
    git(&["config", "user.name", "Fixture"], tmp.path());
    fs::write(tmp.path().join("README.md"), "hello").expect("write README");
    git(&["add", "."], tmp.path());
    git(&["commit", "-m", "initial"], tmp.path());
    convert_colocated(tmp.path()).expect("convert");
    let root = Repo::open(tmp.path()).expect("open").workspace_root().to_owned();
    Fx { _tmp: tmp, root }
}

fn write(root: &Path, rel: &str, content: &str) {
    let path = root.join(rel);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("parent dir");
    }
    fs::write(path, content).expect("write file");
}

fn load(root: &Path) -> (Workspace, std::sync::Arc<ReadonlyRepo>) {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("load workspace");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load head");
    (workspace, repo)
}

/// A snapshot the way the CLI's NEXT command would take one — TEST SETUP ONLY, since production
/// code only snapshots inside the two verbs under test. `force_all` also tracks ignored files
/// (the fixture's way of getting an ignored file into `@`); otherwise only already-tracked
/// files are re-recorded and nothing new starts being tracked.
fn snapshot(root: &Path, force_all: bool) {
    let (mut workspace, repo) = load(root);
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .expect("@")
        .clone();
    let wc_commit = repo.store().get_commit(&wc_id).expect("@ commit");
    let matcher: &dyn Matcher = if force_all { &EverythingMatcher } else { &NothingMatcher };
    let mut locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("lock");
    let options = SnapshotOptions {
        base_ignores: GitIgnoreFile::empty(),
        progress: None,
        start_tracking_matcher: matcher,
        force_tracking_matcher: matcher,
        max_new_file_size: u64::MAX,
    };
    let (tree, _stats) = pollster::block_on(locked.locked_wc().snapshot(&options)).expect("snapshot");
    let mut tx = repo.start_transaction();
    pollster::block_on(tx.repo_mut().rewrite_commit(&wc_commit).set_tree(tree).write()).expect("rewrite @");
    pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
    let new_repo = pollster::block_on(tx.commit("test: snapshot")).expect("commit");
    pollster::block_on(locked.finish(new_repo.op_id().clone())).expect("finish");
}

fn paths_of(tree: &MergedTree) -> Vec<String> {
    tree.entries()
        .map(|(path, _)| path.as_internal_file_string().to_owned())
        .collect()
}

/// The paths of `@`'s tree in the head VIEW.
fn at_paths(root: &Path) -> Vec<String> {
    let (workspace, repo) = load(root);
    let wc_id = repo.view().get_wc_commit_id(workspace.workspace_name()).expect("@");
    paths_of(&repo.store().get_commit(wc_id).expect("@ commit").tree())
}

/// The paths of the working-copy STATE — what the next snapshot starts from.
fn wc_state_paths(root: &Path) -> Vec<String> {
    let (workspace, _repo) = load(root);
    paths_of(workspace.working_copy().tree().expect("wc tree"))
}

/// `@`'s commit id hex in the head view.
fn at_hex(root: &Path) -> String {
    let (workspace, repo) = load(root);
    repo.view()
        .get_wc_commit_id(workspace.workspace_name())
        .expect("@")
        .hex()
}

/// Whether the commit `hex` is a visible head.
fn is_head(root: &Path, hex: &str) -> bool {
    let (_workspace, repo) = load(root);
    repo.view().heads().iter().any(|id| id.hex() == hex)
}

/// The op log read through jj-lib, newest first — WITHOUT the pre-verb snapshot every
/// `Repo::op_log` call takes since Story 9.26, so a test measures exactly what the verb under
/// test wrote rather than what a snapshot taken by the measurement itself adds.
fn raw_ops(repo: &Repo) -> Vec<jj_lib::operation::Operation> {
    let (_workspace, head) = load(repo.workspace_root());
    pollster::block_on(jj_lib::op_walk::walk_ancestors(std::slice::from_ref(head.operation())).try_collect())
        .expect("op walk")
}

fn op_count(repo: &mut Repo) -> usize {
    raw_ops(repo).len()
}

fn head_op_description(repo: &mut Repo) -> String {
    raw_ops(repo)[0].metadata().description.clone()
}

fn head_op_id(repo: &mut Repo) -> String {
    raw_ops(repo)[0].id().hex()
}

fn tree_state_bytes(root: &Path) -> Vec<u8> {
    fs::read(root.join(".jj").join("working_copy").join("tree_state")).expect("tree_state")
}

fn strings(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_owned()).collect()
}

fn untracked(path: &str, reason: UntrackedReason) -> UntrackedPath {
    UntrackedPath {
        path: path.to_owned(),
        reason,
    }
}

const NO_AUTO_TRACK: &str = "snapshot.auto-track = \"none()\"\n";

// ── file track: the matrix ───────────────────────────────────────────────────────

#[test]
fn track_untracked_file_writes_one_track_op_and_records_it_in_the_wc_state() {
    let fx = git_fx(NO_AUTO_TRACK);
    write(&fx.root, "a.txt", "under the limit");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = op_count(&mut repo);

    let result = repo.file_track(&strings(&["a.txt"]), false).expect("track");

    assert_eq!(op_count(&mut repo), before + 1, "exactly one new operation");
    assert_eq!(head_op_description(&mut repo), "track paths");
    assert_eq!(result.mutation.new_op_id.0, head_op_id(&mut repo));
    assert_eq!(result.num_rebased, 0);
    assert_eq!(result.snapshot_stats, SnapshotStats::default());
    assert!(result.mutation.new_change_ids.is_empty());
    assert!(
        result.mutation.identity_missing.is_none(),
        "the pinned identity is complete"
    );
    // GH #8298: the view's `@` is untouched; only the working-copy state learned the path.
    assert!(at_paths(&fx.root).is_empty(), "@ keeps its pre-call tree");
    assert_eq!(wc_state_paths(&fx.root), strings(&["a.txt"]));
}

#[test]
fn track_file_over_the_limit_writes_the_op_but_leaves_it_untracked() {
    let fx = git_fx("snapshot.max-new-file-size = 10\n");
    write(&fx.root, "a.bin", &"a".repeat(20));
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = op_count(&mut repo);

    let result = repo.file_track(&strings(&["a.bin"]), false).expect("track");

    assert_eq!(op_count(&mut repo), before + 1, "the CLI commits unconditionally");
    assert_eq!(head_op_description(&mut repo), "track paths");
    assert!(wc_state_paths(&fx.root).is_empty(), "a too-large file stays untracked");
    assert_eq!(
        result.snapshot_stats.untracked,
        vec![untracked(
            "a.bin",
            UntrackedReason::FileTooLarge { size: 20, max_size: 10 }
        )]
    );
}

/// `file track` merges the PRE-VERB snapshot's stats into its own (the CLI's
/// `print_track_snapshot_stats`, Story 9.26): `big.bin` is outside the track's own matcher, so
/// the track's snapshot alone would call it `FileNotAutoTracked`; the auto-tracking pre-verb
/// snapshot saw it first and knows the real reason — too large.
#[test]
fn track_reports_the_pre_verb_snapshots_reason_for_a_path_it_did_not_match() {
    let fx = git_fx("snapshot.max-new-file-size = 5\n");
    write(&fx.root, ".gitignore", "a.txt\n");
    write(&fx.root, "a.txt", "ignored");
    write(&fx.root, "big.bin", &"b".repeat(20));
    let mut repo = Repo::open(&fx.root).expect("open");

    let result = repo.file_track(&strings(&["a.txt"]), false).expect("track");

    let big: Vec<_> = result
        .snapshot_stats
        .untracked
        .iter()
        .filter(|u| u.path == "big.bin")
        .collect();
    assert_eq!(
        big,
        [&untracked(
            "big.bin",
            UntrackedReason::FileTooLarge { size: 20, max_size: 5 }
        )],
        "{:?}",
        result.snapshot_stats.untracked
    );
}

#[test]
fn track_file_over_the_limit_with_include_ignored_tracks_it() {
    let fx = git_fx("snapshot.max-new-file-size = 10\n");
    write(&fx.root, "a.bin", &"a".repeat(20));
    let mut repo = Repo::open(&fx.root).expect("open");

    let result = repo.file_track(&strings(&["a.bin"]), true).expect("track");

    assert_eq!(wc_state_paths(&fx.root), strings(&["a.bin"]));
    assert_eq!(result.snapshot_stats, SnapshotStats::default());
}

/// `0` is the CLI's "no limit": the same 20-byte file is tracked without forcing.
#[test]
fn track_with_max_new_file_size_zero_is_unlimited() {
    let fx = git_fx("snapshot.max-new-file-size = 0\n");
    write(&fx.root, "a.bin", &"a".repeat(20));
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.file_track(&strings(&["a.bin"]), false).expect("track");

    assert_eq!(wc_state_paths(&fx.root), strings(&["a.bin"]));
}

#[test]
fn track_ignored_path_writes_the_op_but_leaves_it_untracked() {
    let fx = git_fx(NO_AUTO_TRACK);
    write(&fx.root, ".gitignore", "b.txt\n");
    write(&fx.root, "b.txt", "ignored");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = op_count(&mut repo);

    let result = repo.file_track(&strings(&["b.txt"]), false).expect("track");

    assert_eq!(op_count(&mut repo), before + 1);
    assert!(wc_state_paths(&fx.root).is_empty(), "an ignored path is not tracked");
    // The pre-verb snapshot (auto-track `none()`) and the track snapshot both leave the other
    // new file untracked as not auto-tracked; the ignored one is not reported at all, as in
    // jj-lib.
    assert_eq!(
        result.snapshot_stats.untracked,
        vec![untracked(".gitignore", UntrackedReason::FileNotAutoTracked)]
    );
}

#[test]
fn track_ignored_path_with_include_ignored_tracks_it() {
    let fx = git_fx(NO_AUTO_TRACK);
    write(&fx.root, ".gitignore", "b.txt\n");
    write(&fx.root, "b.txt", "ignored");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.file_track(&strings(&["b.txt"]), true).expect("track");

    assert_eq!(wc_state_paths(&fx.root), strings(&["b.txt"]));
}

#[test]
fn track_matching_nothing_still_writes_the_op_and_changes_nothing() {
    let fx = git_fx(NO_AUTO_TRACK);
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = op_count(&mut repo);

    // The matrix row's `nope/`: parsed like the CLI's cwd-relative path (cwd = workspace root),
    // so the trailing `/` normalises away instead of being refused.
    let result = repo.file_track(&strings(&["nope/"]), false).expect("track");

    assert_eq!(op_count(&mut repo), before + 1);
    assert_eq!(head_op_description(&mut repo), "track paths");
    assert!(wc_state_paths(&fx.root).is_empty());
    assert!(at_paths(&fx.root).is_empty());
    assert_eq!(result.snapshot_stats, SnapshotStats::default());
}

/// `@`'s children are NOT rebased by `track` — the snapshot tree is discarded (GH #8298); the
/// NEXT verb's pre-verb snapshot (Story 9.26) is what rebases them, as the CLI's next command's.
#[test]
fn track_with_descendants_rebases_nothing_until_the_next_snapshot() {
    let fx = git_fx(NO_AUTO_TRACK);
    write(&fx.root, "f.txt", "base");
    snapshot(&fx.root, true);
    let at = at_hex(&fx.root);
    let child = test_helpers::add_commit_with_files(&fx.root, &[&at], &[("child.txt", "c")], "child");
    write(&fx.root, "a.txt", "new");
    let mut repo = Repo::open(&fx.root).expect("open");

    let result = repo.file_track(&strings(&["a.txt"]), false).expect("track");

    assert_eq!(result.num_rebased, 0);
    assert_eq!(at_hex(&fx.root), at, "@ is not rewritten");
    assert!(is_head(&fx.root, &child), "the child keeps its commit");
    // The next verb: its pre-verb snapshot moves `a.txt` into `@` and rebases the child.
    let precondition = repo.snapshot().expect("the next verb snapshots");
    assert!(precondition.was_snapshot_taken);
    assert_eq!(precondition.snapshot_rebased, 1, "the child is rebased onto the new @");
    assert_eq!(at_paths(&fx.root), strings(&["a.txt", "f.txt"]));
    assert!(!is_head(&fx.root, &child), "the next snapshot rebased the child");
}

// ── file untrack: the matrix ─────────────────────────────────────────────────────

/// `.gitignore` (`*.log`), `c.log` and `d.txt`, all three in `@` (the ignored one forced).
fn untrack_fx(repo_config: &str) -> Fx {
    let fx = git_fx(repo_config);
    write(&fx.root, ".gitignore", "*.log\n");
    write(&fx.root, "c.log", "log");
    write(&fx.root, "d.txt", "text");
    snapshot(&fx.root, true);
    fx
}

#[test]
fn untrack_ignored_tracked_path_removes_it_from_at_and_the_wc_state() {
    let fx = untrack_fx("");
    let at_before = at_hex(&fx.root);
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = op_count(&mut repo);

    let result = repo.file_untrack(&strings(&["c.log"])).expect("untrack");

    assert_eq!(op_count(&mut repo), before + 1);
    assert_eq!(head_op_description(&mut repo), "untrack paths");
    assert_eq!(result.mutation.new_op_id.0, head_op_id(&mut repo));
    assert_ne!(at_hex(&fx.root), at_before, "@ was rewritten");
    assert_eq!(at_paths(&fx.root), strings(&[".gitignore", "d.txt"]));
    assert_eq!(wc_state_paths(&fx.root), strings(&[".gitignore", "d.txt"]));
    assert!(fx.root.join("c.log").exists(), "the file stays on disk");
    assert_eq!(result.num_rebased, 0);
    assert!(result.unmatched_paths.is_empty());
    assert_eq!(result.snapshot_stats, SnapshotStats::default());
    assert!(result.failed_bookmarks.is_empty() && result.failed_tags.is_empty());
}

#[test]
fn untrack_not_ignored_path_refuses_and_writes_nothing() {
    let fx = untrack_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let op_before = head_op_id(&mut repo);
    let at_before = at_hex(&fx.root);
    let state_before = tree_state_bytes(&fx.root);

    let err = repo
        .file_untrack(&strings(&["d.txt"]))
        .expect_err("d.txt is not ignored");

    assert!(
        matches!(&err, MutateError::PathsNotIgnored { paths } if *paths == strings(&["d.txt"])),
        "{err:?}"
    );
    assert_eq!(head_op_id(&mut repo), op_before, "no operation");
    assert_eq!(at_hex(&fx.root), at_before);
    assert_eq!(
        tree_state_bytes(&fx.root),
        state_before,
        "the working-copy state is untouched"
    );
    // The lock was released: the next call can take it.
    repo.file_untrack(&strings(&["c.log"])).expect("the lock is free again");
}

#[test]
fn untrack_mixed_paths_names_only_the_unignored_ones() {
    let fx = untrack_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let op_before = head_op_id(&mut repo);

    let err = repo
        .file_untrack(&strings(&["c.log", "d.txt"]))
        .expect_err("d.txt is not ignored");

    assert!(
        matches!(&err, MutateError::PathsNotIgnored { paths } if *paths == strings(&["d.txt"])),
        "{err:?}"
    );
    assert_eq!(head_op_id(&mut repo), op_before);
    assert_eq!(wc_state_paths(&fx.root), strings(&[".gitignore", "c.log", "d.txt"]));
}

/// The CLI's `'target/file2' and 1 other files are not ignored.` — every offender, tree order.
#[test]
fn untrack_a_directory_of_unignored_files_names_every_offender() {
    let fx = git_fx("");
    write(&fx.root, "target/file2", "2");
    write(&fx.root, "target/file3", "3");
    snapshot(&fx.root, true);
    let mut repo = Repo::open(&fx.root).expect("open");

    let err = repo.file_untrack(&strings(&["target"])).expect_err("not ignored");

    assert!(
        matches!(&err, MutateError::PathsNotIgnored { paths }
            if *paths == strings(&["target/file2", "target/file3"])),
        "{err:?}"
    );
}

#[test]
fn untrack_matching_nothing_writes_the_op_and_reports_the_unmatched_path() {
    let fx = untrack_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = op_count(&mut repo);

    let result = repo.file_untrack(&strings(&["nope.txt"])).expect("untrack");

    assert_eq!(op_count(&mut repo), before + 1);
    assert_eq!(head_op_description(&mut repo), "untrack paths");
    assert_eq!(result.unmatched_paths, strings(&["nope.txt"]));
    assert_eq!(at_paths(&fx.root), strings(&[".gitignore", "c.log", "d.txt"]));
}

/// Paths are parsed like the CLI's cwd-relative path argument with cwd = the workspace root:
/// `./`, a trailing `/` and an absolute path inside the workspace normalise (and are reported
/// in that normalised form), while a path escaping the workspace is refused before the lock.
#[test]
fn paths_normalise_like_the_cli_and_escaping_paths_are_refused() {
    let fx = untrack_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let absolute = fx.root.join("abs.txt").to_str().expect("UTF-8 root").to_owned();

    let result = repo
        .file_untrack(&[String::from("./nope.txt"), String::from("dir/"), absolute])
        .expect("untrack");

    assert_eq!(result.unmatched_paths, strings(&["nope.txt", "dir", "abs.txt"]));
    let before = head_op_id(&mut repo);
    let err = repo
        .file_untrack(&strings(&["../outside.txt"]))
        .expect_err("escapes the workspace");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason } if reason.contains("invalid path")),
        "{err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before);
}

/// Another tracked file edited on disk before the call: exactly like the CLI's `workspace_helper`,
/// the pre-verb snapshot (Story 9.26) records the edit into `@` FIRST — as its own `snapshot
/// working copy` operation — and the untrack then rewrites that up-to-date `@`, leaving the
/// working-copy state reset to it.
#[test]
fn untrack_after_an_unsnapshotted_edit_keeps_the_edit_in_at() {
    let fx = untrack_fx("");
    let d_before = path_value_hex(&fx.root, "d.txt");
    write(&fx.root, "d.txt", "an edit nobody snapshotted");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = op_count(&mut repo);

    repo.file_untrack(&strings(&["c.log"])).expect("untrack");

    let ops = raw_ops(&repo);
    assert_eq!(ops.len(), before + 2, "the snapshot's operation, then the untrack's");
    assert_eq!(ops[1].metadata().description, "snapshot working copy");
    assert!(ops[1].metadata().is_snapshot);
    assert_eq!(ops[0].metadata().description, "untrack paths");
    assert_eq!(at_paths(&fx.root), strings(&[".gitignore", "d.txt"]));
    assert_ne!(
        path_value_hex(&fx.root, "d.txt"),
        d_before,
        "@ holds the snapshotted edit"
    );
    let (workspace, repo_oracle) = load(&fx.root);
    let at = repo_oracle
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .expect("@");
    assert_eq!(
        workspace.working_copy().tree().expect("wc tree").tree_ids(),
        repo_oracle.store().get_commit(at).expect("@").tree_ids(),
        "the working-copy state was reset to the new @, not to the edit"
    );
}

/// The hex of the file blob at `rel` in `@`'s tree.
fn path_value_hex(root: &Path, rel: &str) -> String {
    let (workspace, repo) = load(root);
    let wc_id = repo.view().get_wc_commit_id(workspace.workspace_name()).expect("@");
    let tree = repo.store().get_commit(wc_id).expect("@").tree();
    let value = pollster::block_on(tree.path_value(&RepoPathBuf::from_internal_string(rel).expect("path")))
        .expect("path value");
    match value.into_resolved() {
        Ok(Some(jj_lib::backend::TreeValue::File { id, .. })) => id.hex(),
        other => panic!("{rel} is not a resolved file: {other:?}"),
    }
}

#[test]
fn untrack_rebases_descendants_of_at() {
    let fx = untrack_fx("");
    let at = at_hex(&fx.root);
    let child = test_helpers::add_commit_with_files(&fx.root, &[&at], &[("child.txt", "c")], "child");
    let mut repo = Repo::open(&fx.root).expect("open");

    let result = repo.file_untrack(&strings(&["c.log"])).expect("untrack");

    assert_eq!(result.num_rebased, 1, "the child is rebased onto the rewritten @");
    assert!(!is_head(&fx.root, &child));
}

/// A colocated workspace: the untrack also drops the git index's intent-to-add entry and
/// exports refs in the same operation, so a bookmark on `@` follows the rewrite into git.
#[test]
fn untrack_in_a_colocated_workspace_updates_the_git_index_and_exports_refs() {
    let fx = colocated_fx();
    write(&fx.root, ".gitignore", "*.log\n");
    write(&fx.root, "c.log", "log");
    snapshot(&fx.root, true);
    // What the CLI's own colocated snapshot would have left behind for the (forced) new file.
    git(&["add", "--force", "--intent-to-add", "c.log"], &fx.root);
    assert!(
        git(&["ls-files"], &fx.root).lines().any(|l| l == "c.log"),
        "intent-to-add entry set up"
    );
    test_helpers::set_local_bookmark(&fx.root, "feat", &[&at_hex(&fx.root)]);
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = op_count(&mut repo);

    let result = repo.file_untrack(&strings(&["c.log"])).expect("untrack");

    assert_eq!(op_count(&mut repo), before + 1, "export rides the same operation");
    assert_eq!(head_op_description(&mut repo), "untrack paths");
    assert!(
        !git(&["ls-files"], &fx.root).lines().any(|l| l == "c.log"),
        "the intent-to-add entry is gone"
    );
    assert_eq!(git(&["rev-parse", "refs/heads/feat"], &fx.root), at_hex(&fx.root));
    assert!(result.failed_bookmarks.is_empty() && result.failed_tags.is_empty());
}

/// A colocated export that cannot write one bookmark (git cannot hold both `foo` and
/// `foo/bar`) still untracks and writes the op; the failure lands in `failed_bookmarks`, never
/// in `failed_tags` — the `git_sync.rs` export-failure recipe.
#[test]
fn untrack_in_a_colocated_workspace_reports_a_failed_bookmark_export() {
    let fx = colocated_fx();
    write(&fx.root, ".gitignore", "*.log\n");
    write(&fx.root, "c.log", "log");
    snapshot(&fx.root, true);
    let at = at_hex(&fx.root);
    test_helpers::set_local_bookmark(&fx.root, "foo", &[&at]);
    test_helpers::set_local_bookmark(&fx.root, "foo/bar", &[&at]);
    let mut repo = Repo::open(&fx.root).expect("open");

    let result = repo
        .file_untrack(&strings(&["c.log"]))
        .expect("a failed ref is not an error");

    assert_eq!(head_op_description(&mut repo), "untrack paths");
    assert_eq!(result.failed_bookmarks.len(), 1, "{:?}", result.failed_bookmarks);
    assert_eq!(result.failed_bookmarks[0].name, "foo/bar");
    assert_eq!(result.failed_bookmarks[0].remote, "git");
    assert!(result.failed_tags.is_empty(), "{:?}", result.failed_tags);
}

/// A native (non-git) backend: no git export is attempted and the op is written.
#[test]
fn untrack_on_a_native_backend_writes_the_op_without_git() {
    let fx = init(None, "");
    write(&fx.root, ".gitignore", "*.log\n");
    write(&fx.root, "c.log", "log");
    snapshot(&fx.root, true);
    let mut repo = Repo::open(&fx.root).expect("open");

    let result = repo.file_untrack(&strings(&["c.log"])).expect("untrack");

    assert_eq!(head_op_description(&mut repo), "untrack paths");
    assert_eq!(at_paths(&fx.root), strings(&[".gitignore"]));
    assert!(result.failed_bookmarks.is_empty() && result.failed_tags.is_empty());
}

/// `test_track_untrack_sparse`: a path outside the sparse patterns need not be ignored — the
/// next snapshot cannot see it — and tracking it again has no effect.
#[test]
fn untrack_outside_the_sparse_patterns_needs_no_ignore() {
    let fx = git_fx("");
    write(&fx.root, "file1", "contents");
    write(&fx.root, "file2", "contents");
    snapshot(&fx.root, true);
    {
        let (mut workspace, repo) = load(&fx.root);
        let mut locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("lock");
        pollster::block_on(
            locked
                .locked_wc()
                .set_sparse_patterns(vec![RepoPathBuf::from_internal_string("file1").expect("path")]),
        )
        .expect("sparse");
        pollster::block_on(locked.finish(repo.op_id().clone())).expect("finish");
    }
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.file_untrack(&strings(&["file2"])).expect("untrack outside sparse");
    assert_eq!(at_paths(&fx.root), strings(&["file1"]));

    repo.file_track(&strings(&["file2"]), false)
        .expect("track outside sparse");
    assert_eq!(
        wc_state_paths(&fx.root),
        strings(&["file1"]),
        "no effect outside sparse"
    );
}

// ── Refusals before the lock ─────────────────────────────────────────────────────

#[test]
fn an_empty_path_entry_is_refused_by_both_verbs() {
    // `""` would parse to the repo ROOT — every path; the CLI refuses `jj file track ""`.
    // `auto-track = none()` keeps the pre-verb snapshot from tracking `new.txt` on its own, so
    // only a (refused) forced track of the root could.
    let fx = untrack_fx(NO_AUTO_TRACK);
    write(&fx.root, "new.txt", "n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = head_op_id(&mut repo);

    let track = repo.file_track(&strings(&[""]), true).expect_err("empty entry");
    let untrack = repo.file_untrack(&strings(&[""])).expect_err("empty entry");

    for err in [&track, &untrack] {
        assert!(
            matches!(err, MutateError::InvalidInput { reason } if reason.starts_with("invalid path:")),
            "{err:?}"
        );
    }
    assert_eq!(head_op_id(&mut repo), before, "no operation");
    assert_eq!(at_paths(&fx.root), strings(&[".gitignore", "c.log", "d.txt"]));
}

#[test]
fn empty_paths_are_refused_by_both_verbs() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = head_op_id(&mut repo);

    let track = repo.file_track(&[], false).expect_err("empty");
    let untrack = repo.file_untrack(&[]).expect_err("empty");

    assert!(
        matches!(&track, MutateError::InvalidInput { reason } if reason.contains("file track")),
        "{track:?}"
    );
    assert!(
        matches!(&untrack, MutateError::InvalidInput { reason } if reason.contains("file untrack")),
        "{untrack:?}"
    );
    assert_eq!(head_op_id(&mut repo), before);
}

#[test]
fn a_malformed_path_is_refused() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");

    let err = repo.file_track(&strings(&["/abs"]), false).expect_err("leading slash");

    assert!(
        matches!(&err, MutateError::InvalidInput { reason } if reason.contains("invalid path")),
        "{err:?}"
    );
}

#[test]
fn a_wrong_typed_size_knob_is_a_config_error_for_both_verbs() {
    let fx = git_fx("snapshot.max-new-file-size = \"lots\"\n");
    write(&fx.root, "a.txt", "a");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = head_op_id(&mut repo);

    // The pre-verb snapshot reads the knob first (Story 9.26) — before its lock.
    for err in [
        repo.file_track(&strings(&["a.txt"]), false).expect_err("bad size"),
        repo.file_untrack(&strings(&["a.txt"])).expect_err("bad size"),
    ] {
        assert!(
            matches!(&err, MutateError::Precondition(PreconditionError::Config { reason })
                if reason.contains("snapshot.max-new-file-size")),
            "{err:?}"
        );
    }
    assert_eq!(head_op_id(&mut repo), before);
}

#[test]
fn an_unparseable_auto_track_fileset_is_a_config_error() {
    let fx = git_fx("snapshot.auto-track = \"all(\"\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    let err = repo.file_untrack(&strings(&["a.txt"])).expect_err("bad fileset");

    assert!(
        matches!(&err, MutateError::Precondition(PreconditionError::Config { reason })
            if reason.contains("snapshot.auto-track")),
        "{err:?}"
    );
}

/// `snapshot.auto-track` expands `[fileset-aliases]`: with auto-tracking limited to `*.rs`, an
/// UNIGNORED `d.txt` can be untracked — the next snapshot would not re-add it.
#[test]
fn auto_track_resolves_fileset_aliases() {
    let fx = untrack_fx("snapshot.auto-track = \"rust-files\"\n[fileset-aliases]\n'rust-files' = 'glob:*.rs'\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.file_untrack(&strings(&["d.txt"]))
        .expect("d.txt is not auto-tracked");

    assert_eq!(at_paths(&fx.root), strings(&[".gitignore", "c.log"]));
}

// ── Refusals at the lock ─────────────────────────────────────────────────────────

/// `@` rewritten in the op log without a checkout: the recorded working-copy tree is no longer
/// `@`'s. The pre-verb snapshot meets it first (Story 9.26) and refuses both verbs as the CLI's
/// stale working copy ("The working copy is stale"), writing nothing.
#[test]
fn a_rewritten_but_unchecked_out_at_is_a_stale_working_copy() {
    let fx = untrack_fx("");
    let _ = test_helpers::rewrite_commit_files(&fx.root, &at_hex(&fx.root), &[("elsewhere.txt", "x")]);
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = head_op_id(&mut repo);
    let state_before = tree_state_bytes(&fx.root);

    let track = repo.file_track(&strings(&["d.txt"]), false).expect_err("stale");
    let untrack = repo.file_untrack(&strings(&["c.log"])).expect_err("stale");

    for err in [&track, &untrack] {
        assert!(
            matches!(
                err,
                MutateError::Precondition(PreconditionError::StaleWorkingCopy {
                    cause: StaleCause::Stale,
                    ..
                })
            ),
            "{err:?}"
        );
    }
    assert_eq!(head_op_id(&mut repo), before);
    assert_eq!(tree_state_bytes(&fx.root), state_before);
}

/// AC-5 (Story 9.26): after a `track` the working-copy state leads `@` (GH #8298); the NEXT
/// verb's pre-verb snapshot moves the tracked path into `@` first, exactly as the CLI's next
/// command does — so a second `track`, a `describe` and a `new_change` all succeed, with no
/// concurrent or stale refusal.
#[test]
fn working_copy_verbs_after_track_snapshot_the_tracked_path_into_at_first() {
    let fx = git_fx(NO_AUTO_TRACK);
    write(&fx.root, "a.txt", "a");
    write(&fx.root, "b.txt", "b");
    let mut repo = Repo::open(&fx.root).expect("open");
    repo.file_track(&strings(&["a.txt"]), false).expect("first track");
    assert!(at_paths(&fx.root).is_empty(), "GH #8298: the track leaves @ alone");

    let second = repo
        .file_track(&strings(&["b.txt"]), false)
        .expect("the second track runs after the pre-verb snapshot");
    assert_eq!(
        at_paths(&fx.root),
        strings(&["a.txt"]),
        "the pre-verb snapshot moved the first tracked path into @"
    );
    assert_eq!(wc_state_paths(&fx.root), strings(&["a.txt", "b.txt"]));

    let described = repo
        .describe(second.mutation.working_copy_change_id.clone(), "tracked")
        .expect("describe after track");
    assert_eq!(
        at_paths(&fx.root),
        strings(&["a.txt", "b.txt"]),
        "describe's own pre-verb snapshot moved the second tracked path in"
    );
    repo.new_change(&[ChangeId(described.working_copy_change_id.0)])
        .expect("new_change after track");
    assert!(at_paths(&fx.root).contains(&"a.txt".to_owned()));
}

#[test]
fn a_workspace_without_at_is_refused() {
    let fx = git_fx("");
    {
        let (workspace, repo) = load(&fx.root);
        let mut tx = repo.start_transaction();
        pollster::block_on(tx.repo_mut().remove_wc_commit(workspace.workspace_name())).expect("remove @");
        pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
        pollster::block_on(tx.commit("test: remove working-copy commit")).expect("commit");
    }
    let mut repo = Repo::open(&fx.root).expect("open");

    let err = repo.file_track(&strings(&["a.txt"]), false).expect_err("no @");

    assert!(matches!(err, MutateError::NoWorkingCopy), "{err:?}");
}

// ── The CLI's own sequences ──────────────────────────────────────────────────────

/// `test_track_ignored` @ v0.44.0, step by step: `auto-track = none()`, a descendant of `@`,
/// two tracks each followed by the CLI's next-command snapshot, an untrack whose eviction is
/// immediate and rebases the descendant, and an ignored path that `track` does not take.
#[test]
fn cli_track_ignored_sequence() {
    let fx = git_fx(NO_AUTO_TRACK);
    write(&fx.root, ".gitignore", "*.bak\n");
    write(&fx.root, "file1", "initial");
    write(&fx.root, "file1.bak", "initial");
    let at = at_hex(&fx.root);
    let _child = test_helpers::add_commit_with_files(&fx.root, &[&at], &[], "child");
    let mut repo = Repo::open(&fx.root).expect("open");

    let before = op_count(&mut repo);
    let result = repo.file_track(&strings(&["file1"]), false).expect("track file1");
    assert_eq!(op_count(&mut repo), before + 1);
    assert_eq!(head_op_description(&mut repo), "track paths");
    assert_eq!(result.num_rebased, 0);
    assert!(
        at_paths(&fx.root).is_empty(),
        "GH #8298: @ is unchanged by the track op"
    );
    assert_eq!(wc_state_paths(&fx.root), strings(&["file1"]));
    snapshot(&fx.root, false);
    assert_eq!(at_paths(&fx.root), strings(&["file1"]));

    write(&fx.root, "file2", "initial");
    repo.file_track(&strings(&["file2"]), false).expect("track file2");
    snapshot(&fx.root, false);
    assert_eq!(at_paths(&fx.root), strings(&["file1", "file2"]));

    let before = op_count(&mut repo);
    let result = repo.file_untrack(&strings(&["file2"])).expect("untrack file2");
    assert_eq!(op_count(&mut repo), before + 1);
    assert_eq!(head_op_description(&mut repo), "untrack paths");
    assert_eq!(result.num_rebased, 1, "eviction is immediate and affects descendants");
    assert_eq!(at_paths(&fx.root), strings(&["file1"]));
    assert_eq!(wc_state_paths(&fx.root), strings(&["file1"]));
    assert!(fx.root.join("file2").exists());

    repo.file_track(&strings(&["file1.bak"]), false).expect("track ignored");
    assert_eq!(
        wc_state_paths(&fx.root),
        strings(&["file1"]),
        "an ignored path is not tracked"
    );
}

// ── base_ignores ─────────────────────────────────────────────────────────────────

/// Tracks `name` without forcing and reports whether the working-copy state now holds it.
fn tracked_after_track(root: &Path, name: &str) -> bool {
    write(root, name, "x");
    let mut repo = Repo::open(root).expect("open");
    repo.file_track(&strings(&[name]), false).expect("track");
    wc_state_paths(root).iter().any(|p| p == name)
}

#[test]
fn base_ignores_reads_the_git_info_exclude() {
    let fx = git_fx("");
    let git_dir = fx.root.join(".jj").join("repo").join("store").join("git");
    fs::create_dir_all(git_dir.join("info")).expect("info dir");
    fs::write(git_dir.join("info").join("exclude"), "*.excl\n").expect("exclude");

    assert!(!tracked_after_track(&fx.root, "x.excl"));
    assert!(
        tracked_after_track(&fx.root, "x.kept"),
        "control: an unexcluded file is tracked"
    );
}

#[test]
fn base_ignores_falls_back_to_the_xdg_git_ignore() {
    let fx = git_fx("");
    assert!(!tracked_after_track(&fx.root, "y.xdgignored"));
}

#[test]
fn base_ignores_reads_the_xdg_git_ignore_on_a_native_backend() {
    let fx = init(None, "");
    assert!(!tracked_after_track(&fx.root, "y.xdgignored"));
}

/// A `core.excludesFile` set AFTER the handle was opened is honoured by that SAME handle: the
/// git config is re-read per call, as the CLI re-reads it per command.
#[test]
fn base_ignores_sees_a_core_excludes_file_set_after_open() {
    // `auto-track = none()`: otherwise the pre-verb snapshot would auto-track the new
    // `late-excludes` file itself, which is not what this row is about.
    let fx = git_fx(NO_AUTO_TRACK);
    write(&fx.root, "late.lateex", "x");
    let mut repo = Repo::open(&fx.root).expect("open");
    let git_config = fx
        .root
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("config");
    git(
        &[
            "config",
            "--file",
            git_config.to_str().expect("utf-8 path"),
            "core.excludesFile",
            "late-excludes",
        ],
        &fx.root,
    );
    write(&fx.root, "late-excludes", "*.lateex\n");

    repo.file_track(&strings(&["late.lateex"]), false).expect("track");

    assert!(wc_state_paths(&fx.root).is_empty(), "the late excludes file ignores it");
}

/// A RELATIVE `core.excludesFile` is joined onto the workspace root, where `git` reads it.
#[test]
fn base_ignores_reads_a_relative_core_excludes_file() {
    let fx = git_fx("");
    let git_config = fx
        .root
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("config");
    let git_config = git_config.to_str().expect("utf-8 path");
    git(
        &["config", "--file", git_config, "core.excludesFile", "my-excludes"],
        &fx.root,
    );
    write(&fx.root, "my-excludes", "*.relex\n");

    assert!(!tracked_after_track(&fx.root, "z.relex"));
    // The configured file REPLACES the XDG fallback.
    assert!(tracked_after_track(&fx.root, "z.xdgignored"));
}

#[test]
fn base_ignores_expands_a_home_relative_core_excludes_file() {
    let home = pin_env();
    let fx = git_fx("");
    let git_config = fx
        .root
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("config");
    let git_config = git_config.to_str().expect("utf-8 path");
    git(
        &["config", "--file", git_config, "core.excludesFile", "~/home-excludes"],
        &fx.root,
    );
    fs::write(home.join("home-excludes"), "*.homeex\n").expect("home excludes");

    assert!(!tracked_after_track(&fx.root, "w.homeex"));
}
