// SPDX-License-Identifier: MIT

//! Story 9.26 — the matrix row "Watchman configured, daemon unavailable", in its own test binary
//! because it pins `WATCHMAN_SOCK` for the whole process.
//!
//! jj-lib is built with the CLI's `watchman` feature (the workspace `Cargo.toml`), so
//! `fsmonitor.backend = "watchman"` makes every snapshot QUERY Watchman; when the daemon cannot
//! be reached, jj-lib logs the failure and falls back to a full scan
//! (`local_working_copy.rs:1433-1440` @ 0.44.0) — the snapshot proceeds with exactly the result
//! it has without Watchman, as in the CLI. `WATCHMAN_SOCK` pointing at a socket that does not
//! exist makes that failure deterministic whether or not `watchman` is installed, and keeps the
//! client from ever spawning a daemon.
//!
//! The row's error column — a snapshot jj-lib DOES fail — is witnessed with an unreadable new
//! file: `jj.jj_lib_error` with jj-lib's own message, and no operation written.

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use tempfile::TempDir;
use zanshin_jj::{Backend, PreconditionError, Repo, SnapshotStats};

static ENV_GUARD: LazyLock<PathBuf> = LazyLock::new(|| {
    let dir = TempDir::new().expect("socket dir").keep();
    let socket = dir.join("no-watchman.sock");
    // SAFETY: every test calls `pin_env()` FIRST; the `LazyLock` blocks them all until this
    // initialiser returns, so no test body has read the environment yet.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("WATCHMAN_SOCK", &socket);
    }
    socket
});

fn pin_env() {
    assert!(!ENV_GUARD.exists(), "the pinned Watchman socket must not exist");
}

fn init(config: &str) -> (TempDir, PathBuf) {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let root = Repo::init(tmp.path(), Some(Backend::Git))
        .expect("init")
        .workspace_root()
        .to_owned();
    fs::write(root.join(".jj").join("repo").join("config.toml"), config).expect("repo config");
    (tmp, root)
}

/// One dirty snapshot's observable outcome: the new operations' descriptions and the stats.
fn dirty_snapshot(root: &Path) -> (Vec<String>, SnapshotStats, bool) {
    let mut repo = Repo::open(root).expect("open");
    let before = repo.op_log(None).expect("op log").len();
    fs::write(root.join("a.txt"), "dirty\n").expect("write");
    fs::write(root.join("big.bin"), "x".repeat(64)).expect("write");
    let report = repo.snapshot().expect("the snapshot proceeds");
    let ops = repo.op_log(None).expect("op log");
    let added = ops[..ops.len() - before]
        .iter()
        .map(|op| op.description.clone())
        .collect();
    (added, report.snapshot_stats, report.was_snapshot_taken)
}

#[test]
fn an_unreachable_watchman_falls_back_to_a_full_scan_with_the_same_result() {
    let (_plain_tmp, plain) = init("snapshot.max-new-file-size = 10\n");
    let (_watched_tmp, watched) = init("snapshot.max-new-file-size = 10\n[fsmonitor]\nbackend = \"watchman\"\n");

    let without = dirty_snapshot(&plain);
    let with = dirty_snapshot(&watched);

    assert_eq!(with, without, "identical operations and stats");
    assert_eq!(with.0, ["snapshot working copy"]);
}

#[test]
fn a_snapshot_jj_lib_fails_is_a_backend_error_with_its_message() {
    let (_tmp, root) = init("");
    let mut repo = Repo::open(&root).expect("open");
    let before = repo.op_log(None).expect("op log").len();
    let unreadable = root.join("secret.txt");
    fs::write(&unreadable, "no access\n").expect("write");
    fs::set_permissions(&unreadable, fs::Permissions::from_mode(0o000)).expect("chmod");

    let err = repo.snapshot().expect_err("an unreadable new file fails the snapshot");

    fs::set_permissions(&unreadable, fs::Permissions::from_mode(0o644)).expect("chmod back");
    assert!(
        matches!(&err, PreconditionError::Backend(reason) if reason.contains("secret.txt")),
        "jj-lib's message, naming the file: {err:?}"
    );
    fs::remove_file(&unreadable).expect("remove");
    assert_eq!(repo.op_log(None).expect("op log").len(), before, "no operation");
}
