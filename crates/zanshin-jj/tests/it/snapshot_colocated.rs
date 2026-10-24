// SPDX-License-Identifier: MIT

//! Story 9.26 — the implicit pre-verb snapshot in a COLOCATED workspace: the matrix's colocated
//! rows (AC-1, op-log parity), the colocated mutation finish (AC-2), the conversion's own
//! snapshot (AC-6), and the `git_import_export.lock` rows.
//!
//! Every repo is a real `git` repository converted in place, and every "outside" change is made
//! with the `git` CLI — exactly what an IDE or a terminal next to Zanshin does. The op log is
//! read through jj-lib ([`descriptions`]) so the measurement never snapshots itself; Git's own
//! state is read back with `git rev-parse`.
//!
//! The expected sequences are derived from `cli/src/cli_util.rs` @ v0.44.0: `snapshot_impl`
//! (`:1298-1326`) runs `import git head` (written only when HEAD moved), `snapshot working copy`
//! (only when the tree changed) and `import git refs` (only when refs changed), each as its own
//! operation.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};
use std::{fs, thread};

use futures::TryStreamExt as _;
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{convert_colocated, ChangeId, PreconditionError, Repo, WarningKind};

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

fn write(root: &Path, rel: &str, content: &str) {
    fs::write(root.join(rel), content).expect("write file");
}

/// A git repository with one commit on `main`, identity configured, NOT yet converted.
fn git_repo(tmp: &TempDir) -> PathBuf {
    test_helpers::pin_test_env();
    let root = tmp.path().canonicalize().expect("canonical root");
    git(&["init", "--initial-branch=main"], &root);
    git(&["config", "user.email", "test@zanshin.test"], &root);
    git(&["config", "user.name", "Fixture"], &root);
    write(&root, "README.md", "hello\n");
    git(&["add", "."], &root);
    git(&["commit", "-m", "initial"], &root);
    root
}

/// The colocated workspace: [`git_repo`] converted in place, opened.
fn colocated(tmp: &TempDir) -> (PathBuf, Repo) {
    let root = git_repo(tmp);
    let repo = convert_colocated(&root).result.expect("convert");
    (root, repo)
}

fn load(root: &Path) -> (Workspace, Arc<ReadonlyRepo>) {
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

/// The op log's descriptions through jj-lib, newest first, with each operation's
/// `is_snapshot` flag — no snapshot of its own.
fn ops(root: &Path) -> Vec<(String, bool)> {
    let (_workspace, head) = load(root);
    let ops: Vec<jj_lib::operation::Operation> =
        pollster::block_on(jj_lib::op_walk::walk_ancestors(std::slice::from_ref(head.operation())).try_collect())
            .expect("op walk");
    ops.iter()
        .map(|op| (op.metadata().description.clone(), op.metadata().is_snapshot))
        .collect()
}

fn descriptions(root: &Path) -> Vec<String> {
    ops(root).into_iter().map(|(d, _)| d).collect()
}

/// The descriptions written since `before` operations existed, oldest FIRST.
fn new_descriptions(root: &Path, before: usize) -> Vec<String> {
    let all = descriptions(root);
    let mut added = all[..all.len() - before].to_vec();
    added.reverse();
    added
}

/// `@`'s commit and its (single) parent's hex in the head view.
fn at(root: &Path) -> (jj_lib::commit::Commit, String) {
    let (workspace, repo) = load(root);
    let id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .expect("@")
        .clone();
    let commit = repo.store().get_commit(&id).expect("@ commit");
    let parent = commit.parent_ids()[0].hex();
    (commit, parent)
}

fn local_bookmark_target(root: &Path, name: &str) -> Option<String> {
    let (_workspace, repo) = load(root);
    repo.view()
        .get_local_bookmark(jj_lib::ref_name::RefName::new(name))
        .as_normal()
        .map(jj_lib::object_id::ObjectId::hex)
}

// ── AC-1: the colocated matrix rows ──────────────────────────────────────────────

/// "`git commit` outside": HEAD moved, tree unchanged → `import git head` (a new empty `@` on
/// the new HEAD, the discardable old `@` abandoned, "Reset the working copy parent…"), then
/// `import git refs` (the branch moved). No snapshot operation: the tree on disk IS the commit.
#[test]
fn a_git_commit_outside_imports_head_then_refs() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    let before = descriptions(&root).len();
    write(&root, "b.txt", "committed with git\n");
    git(&["add", "b.txt"], &root);
    git(&["commit", "-m", "outside"], &root);
    let head = git(&["rev-parse", "HEAD"], &root);

    let status = repo.status().expect("status");

    assert_eq!(new_descriptions(&root, before), ["import git head", "import git refs"]);
    assert!(
        ops(&root).iter().all(|(_, is_snapshot)| !is_snapshot),
        "no operation here is a snapshot"
    );
    let report = repo.take_precondition().expect("report");
    assert!(report.was_snapshot_taken);
    assert!(report.git_head_imported);
    assert!(report.git_head_reset, "a previous Git HEAD existed");
    let refs = report.git_refs.expect("the refs import ran");
    assert!(
        refs.changed_bookmarks
            .iter()
            .any(|u| u.name == "main" && u.remote == "git" && u.kind == zanshin_jj::GitRefUpdateKind::Updated),
        "the moved Git branch is imported as `main@git`: {:?}",
        refs.changed_bookmarks
    );
    let (at_commit, at_parent) = at(&root);
    assert_eq!(at_parent, head, "@ sits on the new Git HEAD");
    assert!(pollster::block_on(at_commit.is_empty(repo_for(&root).as_ref())).expect("emptiness"));
    assert_eq!(git(&["rev-parse", "HEAD"], &root), head, "Git HEAD is untouched");
    assert_eq!(
        local_bookmark_target(&root, "main"),
        Some(head),
        "the branch move imported"
    );
    assert!(
        status.files.is_empty(),
        "the committed file is not a working-copy change"
    );

    // Loop-free: the refresh a watcher triggers after those operations writes nothing.
    let settled = descriptions(&root).len();
    repo.status().expect("refresh");
    repo.snapshot().expect("refresh snapshot");
    assert_eq!(descriptions(&root).len(), settled, "zero further operations");
}

fn repo_for(root: &Path) -> Arc<ReadonlyRepo> {
    load(root).1
}

/// "`git checkout other` outside": HEAD and the files changed → `import git head` only; the
/// working-copy STATE is reset without touching a file, so the snapshot finds no difference, and
/// no ref moved.
#[test]
fn a_git_checkout_outside_imports_head_and_nothing_else() {
    let tmp = TempDir::new().expect("tempdir");
    let root = git_repo(&tmp);
    git(&["checkout", "-q", "-b", "other"], &root);
    write(&root, "other.txt", "on other\n");
    git(&["add", "other.txt"], &root);
    git(&["commit", "-q", "-m", "other"], &root);
    git(&["checkout", "-q", "main"], &root);
    let mut repo = convert_colocated(&root).result.expect("convert");
    let before = descriptions(&root).len();

    git(&["checkout", "-q", "other"], &root);
    let other = git(&["rev-parse", "HEAD"], &root);
    repo.status().expect("status");

    assert_eq!(new_descriptions(&root, before), ["import git head"]);
    assert_eq!(at(&root).1, other);
    assert_eq!(
        fs::read_to_string(root.join("other.txt")).expect("read"),
        "on other\n",
        "the files git checked out are untouched"
    );
    let report = repo.take_precondition().expect("report");
    assert!(report.git_head_reset);
    assert!(report.git_refs.expect("refs ran").changed_bookmarks.is_empty());
}

/// "`git switch -c new` outside": HEAD becomes a new branch at the SAME commit → no head
/// import (same target), one `import git refs` creating the bookmark.
#[test]
fn a_git_switch_to_a_new_branch_imports_only_the_refs() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    let before = descriptions(&root).len();
    let head = git(&["rev-parse", "HEAD"], &root);

    git(&["switch", "-q", "-c", "feature"], &root);
    repo.status().expect("status");

    assert_eq!(new_descriptions(&root, before), ["import git refs"]);
    assert_eq!(local_bookmark_target(&root, "feature"), Some(head));
    assert!(!repo.take_precondition().expect("report").git_head_imported);
}

/// "`git fetch` outside (IDE)": only `refs/remotes/*` changed → one `import git refs`, the
/// remote bookmark imported.
#[test]
fn a_git_fetch_outside_imports_only_the_remote_refs() {
    let tmp = TempDir::new().expect("tempdir");
    let upstream_dir = TempDir::new().expect("upstream tempdir");
    let upstream = git_repo(&upstream_dir);
    let root = tmp.path().canonicalize().expect("canonical root");
    git(
        &[
            "clone",
            "-q",
            upstream.to_str().expect("utf-8"),
            root.to_str().expect("utf-8"),
        ],
        &root,
    );
    git(&["config", "user.email", "test@zanshin.test"], &root);
    git(&["config", "user.name", "Fixture"], &root);
    let mut repo = convert_colocated(&root).result.expect("convert");
    write(&upstream, "up.txt", "upstream\n");
    git(&["add", "up.txt"], &upstream);
    git(&["commit", "-q", "-m", "upstream"], &upstream);
    let upstream_head = git(&["rev-parse", "HEAD"], &upstream);
    let before = descriptions(&root).len();

    git(&["fetch", "-q", "origin"], &root);
    repo.status().expect("status");

    assert_eq!(new_descriptions(&root, before), ["import git refs"]);
    let refs = repo.take_precondition().expect("report").git_refs.expect("refs ran");
    assert!(
        refs.changed_bookmarks
            .iter()
            .any(|u| u.name == "main" && u.remote == "origin"),
        "{:?}",
        refs.changed_bookmarks
    );
    let (_workspace, head_repo) = load(&root);
    let target = head_repo
        .view()
        .get_remote_bookmark(
            jj_lib::ref_name::RefName::new("main").to_remote_symbol(jj_lib::ref_name::RemoteName::new("origin")),
        )
        .target
        .as_normal()
        .map(jj_lib::object_id::ObjectId::hex);
    assert_eq!(target, Some(upstream_head));
}

/// "`@` immutable" (colocated): the new commit on top of `@` and Git HEAD reset to the old `@`.
#[test]
fn an_immutable_at_gets_a_new_commit_and_git_head_follows() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'immutable_heads()' = '@'\n",
    )
    .expect("repo config");
    let (old_at, _) = at(&root);
    write(&root, "edit.txt", "edited\n");

    repo.snapshot().expect("snapshot");

    let kinds: Vec<WarningKind> = repo.take_warnings().into_iter().map(|w| w.kind).collect();
    // First the verb's start-up fix-up migrating the legacy repo config written after the open
    // (Story 9.37), then no HEAD-reset failure: the HEAD reset itself succeeded.
    assert_eq!(
        kinds,
        [WarningKind::ConfigMigrated, WarningKind::WorkingCopyImmutable],
        "the HEAD reset itself succeeded"
    );
    let (_new_at, new_parent) = at(&root);
    assert_eq!(new_parent, old_at.id().hex(), "the new @ is on top of the old one");
    assert_eq!(
        git(&["rev-parse", "HEAD"], &root),
        old_at.id().hex(),
        "Git HEAD is reset to the new @'s parent"
    );
}

/// "`.jjconflict` files present": the warning is recorded and the snapshot proceeds.
#[test]
fn a_jjconflict_entry_is_reported_and_the_snapshot_proceeds() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    write(&root, ".jjconflict-base-0", "left behind by a plain git checkout\n");

    let report = repo.snapshot().expect("snapshot proceeds");

    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::JjconflictFilesPresent);
    assert_eq!(
        warnings[0].message,
        "The working copy contains '.jjconflict' files. These files are used by `jj` internally and should not \
         be present in the working copy."
    );
    assert!(report.was_snapshot_taken);
}

/// The pre-verb `import git refs` step warns about a Git ref it cannot read (Story 9.32): a ref
/// under the reserved `refs/remotes/git/` namespace — the `git_sync.rs` recipe — makes a plain
/// READ carry `jj.git_import_failed`, the CLI's `print_git_import_stats` block, and nothing else.
#[test]
fn the_pre_verb_refs_import_warns_about_a_ref_it_cannot_import() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    let head = git(&["rev-parse", "HEAD"], &root);
    git(&["update-ref", "refs/remotes/git/stolen", &head], &root);

    repo.status().expect("a failed ref is not an error");

    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::GitImportFailed);
    assert_eq!(
        warnings[0].message,
        "Failed to import some Git refs:\n  refs/remotes/git/stolen"
    );
}

/// A dirty edit in a colocated workspace: `snapshot working copy`, and the change is exported
/// (intent-to-add) in the same operation.
#[test]
fn an_edit_outside_zanshin_is_snapshotted_and_exported() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    let before = descriptions(&root).len();
    write(&root, "new.txt", "new\n");

    repo.status().expect("status");

    assert_eq!(new_descriptions(&root, before), ["snapshot working copy"]);
    assert!(ops(&root)[0].1, "flagged is_snapshot");
    assert!(
        git(&["ls-files"], &root).lines().any(|l| l == "new.txt"),
        "the new file is intent-to-add in the Git index"
    );
}

// ── The Git import/export lock ───────────────────────────────────────────────────

fn lock_path(root: &Path) -> PathBuf {
    root.join(".jj").join("repo").join("git_import_export.lock")
}

/// "Concurrent CLI holds the lock": the verb WAITS for it, then proceeds.
#[test]
fn a_held_git_import_export_lock_is_waited_for() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    write(&root, "a.txt", "dirty\n");
    let cli_lock = jj_lib::lock::FileLock::lock(lock_path(&root)).expect("hold the CLI's lock");
    let hold = Duration::from_millis(400);
    let releaser = thread::spawn(move || {
        thread::sleep(hold);
        drop(cli_lock);
    });

    let started = Instant::now();
    let report = repo.snapshot().expect("proceeds once the lock is free");

    assert!(started.elapsed() >= hold, "the verb waited for the lock");
    assert!(report.was_snapshot_taken);
    releaser.join().expect("releaser");
}

/// Story 9.34, the double fault "Git HEAD moved outside AND a wrong-typed snapshot knob": the CLI
/// reads the snapshot knobs inside `snapshot_working_copy` (`cli_util.rs:2065-2070` @ v0.44.0),
/// AFTER its lock and its `import git head` — so it writes that operation, then fails. Zanshin
/// leaves the same op log, and the partial report says so.
#[test]
fn a_wrong_typed_knob_fails_after_the_head_import_like_the_cli() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "snapshot.max-new-file-size = true\n",
    )
    .expect("repo config");
    let before = descriptions(&root).len();
    git(&["commit", "-q", "--allow-empty", "-m", "outside"], &root);

    let err = repo.snapshot().expect_err("the snapshot step refuses the knob");

    assert!(
        matches!(&err, PreconditionError::Config { reason } if reason.contains("snapshot.max-new-file-size")),
        "{err:?}"
    );
    assert_eq!(new_descriptions(&root, before), ["import git head"]);
    let report = repo.take_precondition().expect("partial report");
    assert!(report.git_head_imported);
    assert!(report.was_snapshot_taken, "an operation WAS written before the failure");
    assert!(report.git_refs.is_none(), "the refs step never ran");
}

/// Story 9.34: the snapshot knobs are read under the Git import/export lock, so a verb with a
/// wrong-typed knob WAITS for a concurrent holder like any other verb, and only then refuses.
#[test]
fn a_wrong_typed_knob_is_refused_only_once_the_held_lock_is_free() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "snapshot.max-new-file-size = true\n",
    )
    .expect("repo config");
    let before = descriptions(&root).len();
    let cli_lock = jj_lib::lock::FileLock::lock(lock_path(&root)).expect("hold the CLI's lock");
    let hold = Duration::from_millis(400);
    // Started BEFORE the releaser exists, so the lock is released no earlier than `hold` later.
    let started = Instant::now();
    let releaser = thread::spawn(move || {
        thread::sleep(hold);
        drop(cli_lock);
    });

    let err = repo.snapshot().expect_err("the knob refuses once the lock is free");

    assert!(started.elapsed() >= hold, "the verb waited for the lock");
    assert!(
        matches!(&err, PreconditionError::Config { reason } if reason.contains("snapshot.max-new-file-size")),
        "{err:?}"
    );
    releaser.join().expect("releaser");
    assert_eq!(
        descriptions(&root).len(),
        before,
        "Git HEAD did not move: nothing written"
    );
    let report = repo.take_precondition().expect("partial report");
    assert!(!report.git_head_imported, "Git HEAD did not move");
    assert!(!report.was_snapshot_taken, "nothing was written before the failure");
    let kinds: Vec<WarningKind> = repo.take_warnings().into_iter().map(|w| w.kind).collect();
    assert_eq!(
        kinds,
        [WarningKind::ConfigMigrated],
        "no warning before the refusal but the start-up fix-up's (Story 9.37: the legacy repo \
         config written after the open is migrated first)"
    );
}

/// Story 9.34: `snapshot.auto-track` is read with the other snapshot knobs, inside the snapshot
/// step (`cli_util.rs:2065-2067` @ v0.44.0) — AFTER `import git head`, so a wrong-typed value
/// leaves that operation in the op log, as in the CLI.
#[test]
fn a_wrong_typed_auto_track_fails_after_the_head_import_like_the_cli() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "snapshot.auto-track = 5\n",
    )
    .expect("repo config");
    let before = descriptions(&root).len();
    git(&["commit", "-q", "--allow-empty", "-m", "outside"], &root);

    let err = repo.snapshot().expect_err("the snapshot step refuses the knob");

    assert!(
        matches!(&err, PreconditionError::Config { reason } if reason.contains("snapshot.auto-track")),
        "{err:?}"
    );
    assert_eq!(new_descriptions(&root, before), ["import git head"]);
    let report = repo.take_precondition().expect("partial report");
    assert!(report.git_head_imported);
    assert!(report.was_snapshot_taken, "an operation WAS written before the failure");
}

/// The `[fileset-aliases]` table is part of the start-up environment (`cli_util.rs:938` @
/// v0.44.0), loaded BEFORE the lock: a layer whose `fileset-aliases` is not a table refuses
/// WITHOUT waiting for a concurrent holder and writes nothing — not even the head import a Git
/// HEAD moved outside would otherwise cause.
#[test]
fn a_non_table_fileset_aliases_is_refused_before_the_lock() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, repo) = colocated(&tmp);
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "fileset-aliases = 42\n",
    )
    .expect("repo config");
    let before = descriptions(&root).len();
    git(&["commit", "-q", "--allow-empty", "-m", "outside"], &root);
    let held = jj_lib::lock::FileLock::lock(lock_path(&root)).expect("hold the lock");

    let (tx, rx) = mpsc::channel();
    let worker = thread::spawn(move || {
        let mut repo = repo;
        tx.send(repo.snapshot().map(drop)).expect("send");
    });
    let result = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("the start-up refusal must not wait for the lock");

    assert!(
        matches!(&result, Err(PreconditionError::Config { reason }) if reason.contains("fileset-aliases")),
        "{result:?}"
    );
    drop(held);
    worker.join().expect("worker");
    assert_eq!(descriptions(&root).len(), before, "no operation at all");
}

/// The start-up environment stays BEFORE the lock (`workspace_helper_with_stats` builds it
/// first, `cli_util.rs:477` @ v0.44.0): a bad `immutable_heads()` alias refuses WITHOUT waiting
/// for a concurrent holder and writes nothing — not even the head import a Git HEAD moved outside
/// would otherwise cause, exactly as the CLI leaves it.
#[test]
fn a_bad_immutable_heads_alias_is_refused_before_the_lock() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, repo) = colocated(&tmp);
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'immutable_heads()' = 'bogus_function()'\n",
    )
    .expect("repo config");
    let before = descriptions(&root).len();
    git(&["commit", "-q", "--allow-empty", "-m", "outside"], &root);
    let held = jj_lib::lock::FileLock::lock(lock_path(&root)).expect("hold the lock");

    let (tx, rx) = mpsc::channel();
    let worker = thread::spawn(move || {
        let mut repo = repo;
        tx.send(repo.snapshot().map(drop)).expect("send");
    });
    let result = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("the start-up refusal must not wait for the lock");

    assert!(
        matches!(
            &result,
            Err(PreconditionError::Config { reason })
                if reason.starts_with("Invalid `revset-aliases.immutable_heads()`: ")
                    && reason.contains("bogus_function")
        ),
        "{result:?}"
    );
    drop(held);
    worker.join().expect("worker");
    assert_eq!(descriptions(&root).len(), before, "no operation at all");
}

/// A malformed Git import option fails where the CLI reads it — at the START of the refs step
/// (`cli_util.rs:1434-1437` @ v0.44.0), AFTER `import git head` was committed: the op log keeps
/// that operation and the partial report says so.
#[test]
fn an_invalid_import_option_fails_after_the_head_import_like_the_cli() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "[remotes.origin]\nauto-track-bookmarks = \"glob:(\"\n",
    )
    .expect("repo config");
    let before = descriptions(&root).len();
    write(&root, "b.txt", "committed with git\n");
    git(&["add", "b.txt"], &root);
    git(&["commit", "-q", "-m", "outside"], &root);

    let err = repo.snapshot().expect_err("the refs step refuses the malformed option");

    assert!(
        matches!(&err, PreconditionError::Config { reason }
            if reason.contains("Invalid `remotes.origin.auto-track-bookmarks`")),
        "{err:?}"
    );
    assert_eq!(new_descriptions(&root, before), ["import git head"]);
    let report = repo.take_precondition().expect("partial report");
    assert!(report.git_head_imported);
    assert!(report.was_snapshot_taken, "an operation WAS written before the failure");
    assert!(report.git_refs.is_none(), "the refs step never imported");
}

/// `git.write-change-id-header` is one of the keys `GitSettings::from_settings` type-checks
/// before the CLI imports refs: a wrong-typed value refuses the colocated precondition as a
/// config fault naming the key. (The precondition's workspace reload — jj-lib's
/// `GitBackend::load` — type-checks the same key first; the import-options read itself is
/// witnessed by `config.rs`'s inline `git_import_options_type_check_every_git_settings_key`.)
#[test]
fn a_wrong_typed_git_write_change_id_header_is_a_config_error() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "git.write-change-id-header = \"yes\"\n",
    )
    .expect("repo config");

    let err = repo.snapshot().expect_err("a wrong-typed key refuses");

    assert!(
        matches!(&err, PreconditionError::Config { reason } if reason.contains("git.write-change-id-header")),
        "{err:?}"
    );
}

/// A Git branch deleted outside Zanshin makes the refs import abandon the commit it alone kept
/// visible (`git.abandon-unreachable-commits`, jj-lib's default `true`); that commit's MUTABLE
/// jj descendant is rebased off it — the CLI's "Rebased {n} descendant commits off of commits
/// rewritten from Git.".
#[test]
fn a_deleted_git_branch_reports_the_rebased_descendants() {
    let tmp = TempDir::new().expect("tempdir");
    let root = git_repo(&tmp);
    git(&["checkout", "-q", "-b", "feature"], &root);
    write(&root, "feature.txt", "on feature\n");
    git(&["add", "feature.txt"], &root);
    git(&["commit", "-q", "-m", "feature"], &root);
    let feature = git(&["rev-parse", "HEAD"], &root);
    git(&["checkout", "-q", "main"], &root);
    let mut repo = convert_colocated(&root).result.expect("convert");
    // A described (so non-discardable) jj-only child of `feature`, not `@` and unbookmarked.
    let feature_change = {
        let (_workspace, head) = load(&root);
        let parent = head
            .store()
            .get_commit(&jj_lib::backend::CommitId::try_from_hex(&feature).expect("hex"))
            .expect("feature commit");
        let mut tx = head.start_transaction();
        pollster::block_on(
            tx.repo_mut()
                .new_commit(vec![parent.id().clone()], parent.tree())
                .set_description("child of feature")
                .write(),
        )
        .expect("child");
        pollster::block_on(tx.commit("test: child of feature")).expect("commit");
        ChangeId(parent.change_id().reverse_hex())
    };

    git(&["branch", "-q", "-D", "feature"], &root);
    let report = repo.snapshot().expect("snapshot");

    assert!(report.git_refs_rebased >= 1, "{report:?}");
    let refs = report.git_refs.expect("the refs import ran");
    assert!(
        refs.abandoned_change_ids.contains(&feature_change),
        "the unreachable `feature` commit is abandoned: {:?}",
        refs.abandoned_change_ids
    );
}

// ── AC-2: the colocated mutation finish ──────────────────────────────────────────

/// `new_change` in a colocated workspace: Git HEAD equals `@-` afterwards — the CLI's
/// `finish_transaction` resets it (`try_reset_git_head`).
#[test]
fn new_change_moves_git_head_to_the_new_at_parent() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    let main = repo.get_change(&repo_main_change(&root)).expect("main");

    let result = repo
        .new_change(std::slice::from_ref(&main.id), &[], &[])
        .expect("new_change");

    assert!(result.finish.is_none(), "a clean finish reports nothing");
    let (_at, parent) = at(&root);
    assert_eq!(parent, main.commit_id.0);
    assert_eq!(git(&["rev-parse", "HEAD"], &root), parent, "Git HEAD equals @-");

    // A second new_change on top of `@` moves HEAD along.
    let at_change = result.working_copy_change_id.expect("@");
    repo.new_change(&[at_change], &[], &[]).expect("new_change on @");
    let (_at, parent) = at(&root);
    assert_eq!(git(&["rev-parse", "HEAD"], &root), parent, "Git HEAD follows @-");
}

fn repo_main_change(root: &Path) -> ChangeId {
    let (_workspace, repo) = load(root);
    let id = repo
        .view()
        .get_local_bookmark(jj_lib::ref_name::RefName::new("main"))
        .as_normal()
        .expect("main")
        .clone();
    ChangeId(
        repo.store()
            .get_commit(&id)
            .expect("main commit")
            .change_id()
            .reverse_hex(),
    )
}

/// `describe` of a bookmarked commit: the bookmark follows the rewrite, and the colocated
/// export moves the Git branch with it.
#[test]
fn describe_of_a_bookmarked_commit_exports_the_git_branch() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    let main = repo_main_change(&root);
    // A mutable `main`: by default `trunk()`-less repos only protect `root()` and tags.
    let result = repo.describe(main, "rewritten by zanshin").expect("describe");

    let target = local_bookmark_target(&root, "main").expect("main");
    assert_eq!(
        git(&["rev-parse", "refs/heads/main"], &root),
        target,
        "the Git branch follows"
    );
    assert_eq!(
        git(&["log", "-1", "--format=%s", "refs/heads/main"], &root),
        "rewritten by zanshin"
    );
    assert_eq!(git(&["rev-parse", "HEAD"], &root), target, "HEAD is the rewritten @-");
    assert!(result.finish.is_none());
}

// ── AC-6: the conversion snapshots like `jj git init --colocate` ─────────────────

/// `convert_colocated` over a DIRTY work tree: `import git refs`, `import git head` (`@`
/// re-parented onto HEAD), `snapshot working copy`; no user file written or deleted.
#[test]
fn converting_a_dirty_work_tree_snapshots_it() {
    let tmp = TempDir::new().expect("tempdir");
    let root = git_repo(&tmp);
    write(&root, "README.md", "hello\ndirty edit\n");
    write(&root, "untracked.txt", "untracked\n");
    let head = git(&["rev-parse", "HEAD"], &root);

    let mut repo = convert_colocated(&root).result.expect("convert");

    assert_eq!(
        descriptions(&root),
        [
            "snapshot working copy",
            "import git head",
            "import git refs",
            "add workspace 'default'",
            ""
        ]
    );
    assert!(ops(&root)[0].1, "the snapshot operation is flagged");
    let (at_commit, at_parent) = at(&root);
    assert_eq!(at_parent, head, "@ is re-parented onto HEAD");
    let paths: Vec<String> = at_commit
        .tree()
        .entries()
        .map(|(path, _)| path.as_internal_file_string().to_owned())
        .collect();
    assert_eq!(paths, ["README.md", "untracked.txt"]);
    assert_eq!(
        fs::read_to_string(root.join("README.md")).expect("read"),
        "hello\ndirty edit\n"
    );
    assert_eq!(
        fs::read_to_string(root.join("untracked.txt")).expect("read"),
        "untracked\n"
    );
    assert_eq!(git(&["rev-parse", "HEAD"], &root), head, "HEAD is not moved");
    let settled = descriptions(&root).len();
    repo.status().expect("status");
    assert_eq!(descriptions(&root).len(), settled, "the converted repo is settled");
}

/// A clean conversion writes the CLI's two operations and re-parents `@` onto HEAD.
#[test]
fn converting_a_clean_work_tree_reparents_at_onto_head() {
    let tmp = TempDir::new().expect("tempdir");
    let root = git_repo(&tmp);
    let head = git(&["rev-parse", "HEAD"], &root);

    let _repo = convert_colocated(&root).result.expect("convert");

    assert_eq!(
        descriptions(&root),
        ["import git head", "import git refs", "add workspace 'default'", ""]
    );
    assert_eq!(at(&root).1, head);
}

// ── Review follow-ups: the less common arms ──────────────────────────────────────

/// A step that fails AFTER an earlier one committed still reports what was written: here
/// `import git head` lands (Git HEAD moved outside), then the snapshot fails on an unreadable
/// new file — the partial report says `git_head_imported` AND `was_snapshot_taken`.
#[test]
fn a_failure_after_the_head_import_still_reports_the_written_operation() {
    use std::os::unix::fs::PermissionsExt as _;

    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    let before = descriptions(&root).len();
    write(&root, "b.txt", "committed with git\n");
    git(&["add", "b.txt"], &root);
    git(&["commit", "-q", "-m", "outside"], &root);
    let unreadable = root.join("secret.txt");
    write(&root, "secret.txt", "no access\n");
    fs::set_permissions(&unreadable, fs::Permissions::from_mode(0o000)).expect("chmod");

    let err = repo.status().expect_err("the snapshot step fails");

    fs::set_permissions(&unreadable, fs::Permissions::from_mode(0o644)).expect("chmod back");
    assert!(
        matches!(
            &err,
            zanshin_jj::StatusError::Precondition(PreconditionError::Backend(_))
        ),
        "{err:?}"
    );
    assert_eq!(new_descriptions(&root, before), ["import git head"]);
    let report = repo.take_precondition().expect("partial report");
    assert!(report.git_head_imported);
    assert!(report.was_snapshot_taken, "an operation WAS written before the failure");
}

/// The absent-HEAD arm of `import git head`: an orphan checkout leaves Git HEAD unborn, so the
/// head import only rebases and finishes (no reset of `@`), and there was no "Reset the working
/// copy parent" fact.
#[test]
fn an_unborn_git_head_is_imported_without_moving_at() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    let before = descriptions(&root).len();
    let (old_at, _) = at(&root);

    git(&["checkout", "-q", "--orphan", "fresh"], &root);
    repo.status().expect("status");

    assert_eq!(new_descriptions(&root, before), ["import git head"]);
    let report = repo.take_precondition().expect("report");
    assert!(report.git_head_imported);
    assert!(!report.git_head_reset);
    assert_eq!(at(&root).0.id(), old_at.id(), "@ is not moved");
}

/// A colocated workspace whose `@` was forgotten elsewhere: the refs import still runs and
/// finishes (the CLI's does) and is reported — its `mutation` names no `@` — and no verb fails.
///
/// The view keeps the workspace's git head: since jj 0.45 `remove_workspace` drops it too, and
/// the head import would then check a NEW `@` out — so the git head is put back, the state a
/// workspace forgotten before 0.45 migrates into.
#[test]
fn a_workspace_without_at_still_imports_the_refs() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    {
        let (workspace, head) = load(&root);
        let git_head = head.view().git_head(workspace.workspace_name()).clone();
        let mut tx = head.start_transaction();
        pollster::block_on(tx.repo_mut().remove_workspace(workspace.workspace_name())).expect("remove @");
        tx.repo_mut().set_git_head_target(workspace.workspace_name(), git_head);
        pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
        pollster::block_on(tx.commit("test: forget @")).expect("commit");
    }
    let before = descriptions(&root).len();
    git(&["branch", "other"], &root);

    repo.op_log(None).expect("a refs import with changes and no @");
    assert_eq!(new_descriptions(&root, before), ["import git refs"]);
    let refs = repo
        .take_precondition()
        .expect("report")
        .git_refs
        .expect("the refs import ran");
    assert!(refs.mutation.working_copy_change_id.is_none());
    assert!(refs.changed_bookmarks.iter().any(|b| b.name == "other"), "{refs:?}");

    repo.op_log(None).expect("a refs import without changes and no @");
    let refs = repo
        .take_precondition()
        .expect("report")
        .git_refs
        .expect("the refs import ran");
    assert!(refs.mutation.working_copy_change_id.is_none());
    assert!(refs.changed_bookmarks.is_empty(), "{refs:?}");
    assert_eq!(new_descriptions(&root, before), ["import git refs"]);
}

/// `git export` in a colocated workspace returns before any transaction, as the CLI does ("No
/// export needed in colocated workspaces.") — even for a jj bookmark never exported to Git.
#[test]
fn git_export_writes_nothing_in_a_colocated_workspace() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    let head = git(&["rev-parse", "HEAD"], &root);
    {
        let (_workspace, repo_head) = load(&root);
        let mut tx = repo_head.start_transaction();
        let id = jj_lib::backend::CommitId::try_from_hex(&head).expect("hex");
        tx.repo_mut().set_local_bookmark_target(
            jj_lib::ref_name::RefName::new("unexported"),
            jj_lib::op_store::RefTarget::normal(id),
        );
        pollster::block_on(tx.commit("test: bookmark without export")).expect("commit");
    }
    let before = descriptions(&root).len();

    let result = repo.git_export().expect("git export");

    assert_eq!(descriptions(&root).len(), before, "no operation");
    assert!(result.failed_bookmarks.is_empty());
    let out = std::process::Command::new("git")
        .args(["rev-parse", "--verify", "-q", "refs/heads/unexported"])
        .current_dir(&root)
        .output()
        .expect("git spawns");
    assert!(!out.status.success(), "the bookmark stays unexported");
}

/// A finish whose Git HEAD reset cannot take `HEAD.lock` (a concurrent `git` holds it) is a
/// WARNING in the CLI (`try_reset_git_head`): the verb succeeds and warns
/// `jj.git_head_update_failed` (Story 9.32).
#[test]
fn a_held_head_lock_makes_the_head_reset_a_reported_warning() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    // A new change on top of `@` moves `@-`, so the finish must move Git HEAD.
    let at_change = repo.status().expect("status").working_copy_change_id.expect("@");
    let head_before = git(&["rev-parse", "HEAD"], &root);
    let head_lock = root.join(".git").join("HEAD.lock");
    fs::write(&head_lock, "").expect("hold HEAD.lock");

    let result = repo.new_change(&[at_change], &[], &[]);

    fs::remove_file(&head_lock).expect("release HEAD.lock");
    let result = result.expect("the verb succeeds");
    assert!(result.finish.is_none(), "no export failed: the finish carries no data");
    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::GitHeadUpdateFailed);
    assert!(
        warnings[0]
            .message
            .starts_with("Failed to update Git HEAD ref\nCaused by"),
        "the error, then `print_error_sources`: {}",
        warnings[0].message
    );
    assert_eq!(git(&["rev-parse", "HEAD"], &root), head_before, "HEAD was not moved");
}

/// A finish whose ref export fails for one bookmark (Git cannot hold `foo` and `foo/bar` at
/// once) reports it in `finish.export_failed_bookmarks`, exports the rest, and succeeds.
#[test]
fn a_failed_bookmark_export_is_reported_in_finish() {
    let tmp = TempDir::new().expect("tempdir");
    let (root, mut repo) = colocated(&tmp);
    let main = repo_main_change(&root);
    let target = git(&["rev-parse", "HEAD"], &root);

    let result = repo
        .bookmark_create(&["foo".to_owned(), "foo/bar".to_owned()], Some(&main))
        .expect("bookmark create");

    let finish = result.finish.expect("an export failure was reported");
    assert!(
        finish.export_failed_bookmarks.iter().any(|f| f.name == "foo/bar"),
        "{:?}",
        finish.export_failed_bookmarks
    );
    assert_eq!(git(&["rev-parse", "refs/heads/foo"], &root), target);
    // Story 9.32: `print_git_export_stats`' block — the data above, rendered as the CLI does.
    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::GitExportFailed);
    let failure = &finish.export_failed_bookmarks[0];
    assert_eq!(
        warnings[0].message,
        format!("Failed to export some bookmarks:\n  foo/bar@git: {}", failure.reason)
    );
}
