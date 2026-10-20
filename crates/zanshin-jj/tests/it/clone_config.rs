// SPDX-License-Identifier: MIT

//! `Repo::clone` reads `git.abandon-unreachable-commits` from the USER config layer
//! (Epic 9 git-sync follow-up, FR-JJ-17) — the second of the two `JJ_CONFIG`-repointing
//! test modules in this crate.
//!
//! # Why one test in its own process
//!
//! `JJ_CONFIG` is process-global and `cargo test` threads a test binary, so a test that CHANGES it
//! would race every other test in the same binary. This file therefore holds exactly ONE `#[test]`,
//! run in a child process of its own (`test_helpers::own_process!`), which walks both clone rows in
//! sequence (a valid `false`, then a non-boolean value). Same construction, and the same
//! never-unset rule, as `tests/it/config_user_layer.rs` — read its header for the full rationale.
//!
//! A fresh clone target has no repo layer to pre-write, so the USER layer is the only way
//! to put a value in front of `clone_into` at all.
//!
//! # Why a TYPE error is the only witness
//!
//! `abandon_unreachable_commits` decides the fate of commits that BECOME unreachable. A
//! clone imports into an empty repo, so nothing can become unreachable and the flag has no
//! positive observable effect; `record_synthetic_predecessors` is pinned to `false`
//! regardless of config, mirroring `cli/src/commands/git/clone.rs:384-389` @ v0.44.0. What
//! CAN be observed is that the value is now READ at all: a non-boolean value fails the
//! clone where it was previously ignored, exactly as the CLI fails it
//! (`GitSettings::from_settings` propagates the type error). The valid-`false` phase is the
//! positive control that the new config read does not itself break a clone.

use std::env;
use std::sync::LazyLock;
use std::{fs, process};

use tempfile::TempDir;
use zanshin_jj::{Repo, RepoError};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: GIT_CONFIG_GLOBAL="" isolates the gix git backend. JJ_CONFIG starts pinned to
    // "" (discovery disabled) and is repointed inside the test — never unset.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
    }
});

/// Repoints `JJ_CONFIG` at a path owned by this test. Never called with an empty
/// or absent value that would re-enable platform discovery.
fn set_jj_config(path: &std::path::Path) {
    // SAFETY: single-threaded — this test runs alone in its own process (`own_process!`).
    unsafe { env::set_var("JJ_CONFIG", path) };
}

/// Run a git command in `dir`; panics on non-zero exit. Fixture setup only (AR-AP-1's
/// allowed exception).
fn git(args: &[&str], dir: &std::path::Path) {
    let status = process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// A plain local git repo with one commit, usable as a `file://` clone source.
fn init_git_source(path: &std::path::Path) {
    git(&["init", "--initial-branch=main"], path);
    git(&["config", "user.email", "test@zanshin.test"], path);
    git(&["config", "user.name", "Fixture"], path);
    fs::write(path.join("README.md"), "hello").expect("write README");
    git(&["add", "."], path);
    git(&["commit", "-m", "initial"], path);
}

#[test]
fn clone_reads_abandon_unreachable_commits_from_the_user_config_layer() {
    test_helpers::own_process!("clone_reads_abandon_unreachable_commits_from_the_user_config_layer");
    LazyLock::force(&ENV_GUARD);
    let tmp = TempDir::new().expect("tempdir");
    let src = TempDir::new().expect("src tempdir");
    init_git_source(src.path());
    let src_url = format!("file://{}", src.path().display());

    // ── A valid `false` must not disturb the clone (positive control) ─────────
    let good = tmp.path().join("good.toml");
    fs::write(&good, "[git]\nabandon-unreachable-commits = false\n").expect("write user config");
    set_jj_config(&good);

    let ok_target = TempDir::new().expect("target tempdir");
    let cloned = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from(&src_url),
            destination: std::path::PathBuf::from(ok_target.path()),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result;
    assert!(
        cloned.is_ok(),
        "a valid config value must not break the clone: {cloned:?}"
    );
    assert!(
        ok_target.path().join("README.md").exists(),
        "the working copy must still be materialised from the fetched default branch"
    );

    // ── A non-boolean value must FAIL the clone, naming the key ───────────────
    // The only observable proof the value is read: before this change the clone
    // hardcoded the flag and a malformed value was silently ignored.
    let broken = tmp.path().join("broken.toml");
    fs::write(&broken, "[git]\nabandon-unreachable-commits = \"yes\"\n").expect("write user config");
    set_jj_config(&broken);

    let bad_target = TempDir::new().expect("target tempdir");
    let result = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from(&src_url),
            destination: std::path::PathBuf::from(bad_target.path()),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result;
    // Since Story 9.27 the clone runs WITH this stack, so jj-lib's git backend already reads the
    // key while creating the workspace; either way a clone config fault has one code: `Config`.
    let Err(RepoError::Config { reason }) = result else {
        panic!("a non-boolean value must fail the clone as Config, got: {result:?}");
    };
    assert!(
        reason.contains("abandon-unreachable-commits"),
        "the reason must name the offending key, got: {reason}"
    );
    assert!(
        !bad_target.path().join(".jj").exists(),
        "a failed clone must roll back the partial .jj/ it created"
    );
}
