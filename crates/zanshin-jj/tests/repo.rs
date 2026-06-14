// SPDX-License-Identifier: Apache-2.0

use std::sync::LazyLock;
use std::{env, fs};

use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{Backend, Repo, RepoError};

/// Env-var pin applied to every test so no test reads `~/.jjconfig.toml` or
/// `~/.gitconfig`.  The explicit `StackedConfig` in `make_settings()` already
/// prevents jj-lib from reading user globals, but setting the vars here is
/// defence-in-depth and keeps CI and local runs consistent.
static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: empty string avoids needing a tempdir just for an env pin; neither
    // JJ_CONFIG="" nor GIT_CONFIG_GLOBAL="" causes jj-lib to fail, it simply
    // finds no config at that (non-existent) path.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

// ── AC-19/AC-6: open happy-path ──────────────────────────────────────────────

#[test]
fn repo_open_tiny_fixture_returns_ok() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let result = Repo::open(&fixture.path);
    assert!(result.is_ok(), "expected Ok, got: {result:?}");
}

#[test]
fn repo_open_medium_fixture_returns_ok() {
    pin_env();
    let fixture = extract_fixture("medium-1k-commits").expect("fixture must extract");
    let result = Repo::open(&fixture.path);
    assert!(result.is_ok(), "expected Ok, got: {result:?}");
}

// ── AC-21: relocatable load ───────────────────────────────────────────────────

#[test]
fn repo_open_from_relocated_path_returns_ok() {
    pin_env();
    // Extract to a *different* tempdir than where the fixture was generated —
    // verifies Workspace::load succeeds regardless of the original generation
    // path (upgrades Story 2.1 AC-25 to a real load assertion).
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let relocated = TempDir::new().expect("tempdir");
    copy_dir_all(&fixture.path, relocated.path()).expect("copy fixture to relocated dir");
    let result = Repo::open(relocated.path());
    assert!(result.is_ok(), "open from relocated path failed: {result:?}");
}

// ── AC-19: error paths ────────────────────────────────────────────────────────

#[test]
fn repo_open_with_nonexistent_path_returns_path_not_found() {
    pin_env();
    let result = Repo::open(std::path::Path::new("/nonexistent/zanshin-test-abc123"));
    assert!(
        matches!(result, Err(RepoError::PathNotFound { .. })),
        "expected PathNotFound, got: {result:?}"
    );
}

#[test]
fn repo_open_with_non_jj_directory_returns_not_a_repo() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let result = Repo::open(tmp.path());
    assert!(
        matches!(result, Err(RepoError::NotARepo { .. })),
        "expected NotARepo, got: {result:?}"
    );
}

// ── AC-5/AC-19: corrupt repo — no panic ───────────────────────────────────────

#[test]
fn repo_open_with_corrupt_op_heads_returns_err_no_panic() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    // Remove op_heads directory to corrupt the repository.
    let op_heads = fixture.path.join(".jj").join("repo").join("op_heads");
    assert!(
        op_heads.exists(),
        "fixture invariant: .jj/repo/op_heads must exist before corruption"
    );
    fs::remove_dir_all(&op_heads).expect("remove op_heads");
    let result = Repo::open(&fixture.path);
    // Must return Err (any variant) — must NOT panic.
    assert!(result.is_err(), "expected Err for corrupt repo, got Ok");
}

// ── AC-19: init + open round-trips ───────────────────────────────────────────

#[test]
fn repo_init_with_git_backend_then_open_returns_ok() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(tmp.path(), Some(Backend::Git)).expect("init git backend");
    let result = Repo::open(tmp.path());
    assert!(result.is_ok(), "open after git-backend init failed: {result:?}");
}

#[test]
fn repo_init_with_native_backend_then_open_returns_ok() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(tmp.path(), None).expect("init native backend");
    let result = Repo::open(tmp.path());
    assert!(result.is_ok(), "open after native-backend init failed: {result:?}");
}

// ── AC-22: @-on-root — do NOT assert @ == tip ────────────────────────────────
// (covered implicitly by repo_open_tiny_fixture_returns_ok — we never assert
//  on the working-copy commit identity, just that load succeeds)

// ── AC-13: clone error path (mandatory, no network) ──────────────────────────

#[test]
fn repo_clone_with_invalid_url_returns_clone_failed() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let result = Repo::clone("not-a-real-url://nope", tmp.path());
    assert!(
        matches!(result, Err(RepoError::CloneFailed { .. })),
        "expected CloneFailed for invalid URL, got: {result:?}"
    );
}

#[test]
fn repo_clone_failure_leaves_no_partial_workspace() {
    pin_env();
    let target_tmp = TempDir::new().expect("target tempdir");
    let result = Repo::clone("not-a-real-url://nope", target_tmp.path());
    assert!(
        matches!(result, Err(RepoError::CloneFailed { .. })),
        "expected CloneFailed, got {result:?}"
    );
    // D1: a failed clone must roll back the partial `.jj/` it created, so a retry
    // into the same directory starts clean.
    assert!(
        !target_tmp.path().join(".jj").exists(),
        "failed clone left a partial .jj/ workspace behind"
    );
}

// ── AC-12: clone happy-path (file:// local git, no network) ──────────────────

#[test]
fn repo_clone_from_local_git_source_returns_ok() {
    pin_env();

    // Build a plain git repo via the git CLI so no jj-lib types are needed in
    // the test (integration tests may not import the lib's regular deps).
    let src_tmp = TempDir::new().expect("src tempdir");

    git(&["init", "--initial-branch=main"], src_tmp.path());
    git(&["config", "user.email", "test@zanshin.test"], src_tmp.path());
    git(&["config", "user.name", "Fixture"], src_tmp.path());
    fs::write(src_tmp.path().join("README.md"), "hello").expect("write README");
    git(&["add", "."], src_tmp.path());
    git(&["commit", "-m", "initial"], src_tmp.path());

    let target_tmp = TempDir::new().expect("target tempdir");
    let src_url = format!("file://{}", src_tmp.path().display());
    let result = Repo::clone(&src_url, target_tmp.path());
    assert!(result.is_ok(), "clone from local file:// failed: {result:?}");

    // Verify the cloned workspace is openable.
    let open_result = Repo::open(target_tmp.path());
    assert!(open_result.is_ok(), "open after clone failed: {open_result:?}");

    // AC-12: the working copy points at the fetched default branch, so its files
    // are materialised on disk in the cloned workspace.
    let cloned_readme = target_tmp.path().join("README.md");
    assert!(
        cloned_readme.exists(),
        "cloned working copy is missing README.md from the default branch"
    );
    assert_eq!(fs::read_to_string(&cloned_readme).expect("read cloned README"), "hello");
}

// ── AC-20: 100× open/drop loop — no fd leak ──────────────────────────────────

#[test]
fn repo_open_drop_loop_100_times_no_panic() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    for _ in 0..100 {
        let _repo = Repo::open(&fixture.path).expect("open in loop");
        // _repo is dropped here; 100 iterations verify no fd leak.
    }
}

// ── AC-1: workspace_root accessor ────────────────────────────────────────────

#[test]
fn repo_workspace_root_matches_open_path() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let repo = Repo::open(&fixture.path).expect("open");
    // WHY: on macOS /var is a symlink to /private/var; workspace_root() returns
    // the canonical path while TempDir::path() may return the non-canonical form.
    assert_eq!(
        std::fs::canonicalize(repo.workspace_root()).expect("canonicalize workspace_root"),
        std::fs::canonicalize(&fixture.path).expect("canonicalize fixture path"),
    );
}

// ─── helpers ─────────────────────────────────────────────────────────────────

/// Run a git command in `dir`; panics on non-zero exit.
fn git(args: &[&str], dir: &std::path::Path) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// Recursively copy `src` into `dst`.
fn copy_dir_all(src: &std::path::Path, dst: &std::path::Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        if ty.is_dir() {
            copy_dir_all(&entry.path(), &dst.join(entry.file_name()))?;
        } else {
            fs::copy(entry.path(), dst.join(entry.file_name()))?;
        }
    }
    Ok(())
}
