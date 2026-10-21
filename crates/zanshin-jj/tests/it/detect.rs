// SPDX-License-Identifier: MIT

use std::fs;
use std::path::Path;

use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{detect_repo, DetectError, RepoKind};

/// Run a git command in `dir`; panics on non-zero exit.
fn git(args: &[&str], dir: &Path) {
    test_helpers::pin_test_env();
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

// --- AC-8: five baseline classifications ---

#[test]
fn detect_tiny_fixture_returns_jj() {
    let fixture = extract_fixture("tiny-3-commits").unwrap();
    assert_eq!(detect_repo(&fixture.path).unwrap(), RepoKind::Jj);
}

#[test]
fn detect_git_init_dir_returns_git() {
    let dir = TempDir::new().unwrap();
    git(&["init"], dir.path());
    assert_eq!(detect_repo(dir.path()).unwrap(), RepoKind::Git);
}

#[test]
fn detect_empty_tmpdir_returns_neither() {
    let dir = TempDir::new().unwrap();
    assert_eq!(detect_repo(dir.path()).unwrap(), RepoKind::Neither);
}

#[test]
fn detect_nonexistent_path_returns_path_not_found() {
    let dir = TempDir::new().unwrap();
    let nonexistent = dir.path().join("does_not_exist");
    assert_eq!(detect_repo(&nonexistent).unwrap(), RepoKind::PathNotFound);
}

#[test]
fn detect_colocated_dir_returns_jj() {
    let dir = TempDir::new().unwrap();
    fs::create_dir(dir.path().join(".jj")).unwrap();
    fs::create_dir(dir.path().join(".git")).unwrap();
    assert_eq!(detect_repo(dir.path()).unwrap(), RepoKind::Jj);
}

// --- AC-9: `.jj` as a regular file (corruption) ---

#[test]
fn detect_dot_jj_regular_file_alone_returns_neither() {
    let dir = TempDir::new().unwrap();
    fs::write(dir.path().join(".jj"), b"not a dir").unwrap();
    assert_eq!(detect_repo(dir.path()).unwrap(), RepoKind::Neither);
}

#[test]
fn detect_dot_jj_regular_file_with_git_dir_returns_git() {
    let dir = TempDir::new().unwrap();
    fs::write(dir.path().join(".jj"), b"not a dir").unwrap();
    fs::create_dir(dir.path().join(".git")).unwrap();
    assert_eq!(detect_repo(dir.path()).unwrap(), RepoKind::Git);
}

// --- AC-10: `.git` as a file with a `gitdir:` pointer ---

#[test]
fn detect_dot_git_pointer_file_returns_git() {
    let dir = TempDir::new().unwrap();
    fs::write(dir.path().join(".git"), b"gitdir: ../whatever/.git/worktrees/x\n").unwrap();
    assert_eq!(detect_repo(dir.path()).unwrap(), RepoKind::Git);
}

// --- AC-11: symlinked `.jj`/`.git` followed to target ---

#[test]
fn detect_symlinked_dot_jj_dir_returns_jj() {
    let dir = TempDir::new().unwrap();
    let real_dir = TempDir::new().unwrap();
    std::os::unix::fs::symlink(real_dir.path(), dir.path().join(".jj")).unwrap();
    assert_eq!(detect_repo(dir.path()).unwrap(), RepoKind::Jj);
}

#[test]
fn detect_symlinked_dot_git_returns_git() {
    let dir = TempDir::new().unwrap();
    let real_dir = TempDir::new().unwrap();
    std::os::unix::fs::symlink(real_dir.path(), dir.path().join(".git")).unwrap();
    assert_eq!(detect_repo(dir.path()).unwrap(), RepoKind::Git);
}

// --- OQ1: the path itself is a regular file (not a directory) -> Neither ---

#[test]
fn detect_regular_file_path_returns_neither() {
    let dir = TempDir::new().unwrap();
    let file = dir.path().join("a_file");
    fs::write(&file, b"x").unwrap();
    // The path exists but is not a directory and carries no repo markers.
    assert_eq!(detect_repo(&file).unwrap(), RepoKind::Neither);
}

// --- AC-11 (cont.): a dangling `.git` symlink classifies by its (missing) target -> Neither ---

#[test]
fn detect_dangling_dot_git_symlink_returns_neither() {
    let dir = TempDir::new().unwrap();
    let missing_target = dir.path().join("nonexistent_target");
    std::os::unix::fs::symlink(&missing_target, dir.path().join(".git")).unwrap();
    // exists() follows the link to a missing target -> false -> falls through to Neither.
    assert_eq!(detect_repo(dir.path()).unwrap(), RepoKind::Neither);
}

// --- Design B: a genuine stat I/O error (not "not found") surfaces as Err, not a RepoKind ---

#[test]
fn detect_path_under_a_regular_file_returns_io_error() {
    let dir = TempDir::new().unwrap();
    let file = dir.path().join("a_file");
    fs::write(&file, b"x").unwrap();
    // stat of `a_file/child` fails with ENOTDIR (a path component is not a dir) —
    // a genuine I/O error distinct from "not found", so it is Err, not PathNotFound.
    let under_file = file.join("child");
    let err = detect_repo(&under_file).unwrap_err();
    assert!(matches!(err, DetectError::Io(_)));
    // Exercise the Display impl and confirm it is the inspect-failure message.
    assert!(err.to_string().contains("failed to inspect path"));
}
