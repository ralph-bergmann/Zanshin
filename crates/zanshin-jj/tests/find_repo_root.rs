// SPDX-License-Identifier: MIT

use std::fs;
use std::path::Path;

use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{find_repo_root, DetectError, RepoKind, RepoRoot};

/// Run a git command in `dir`; panics on non-zero exit.
fn git(args: &[&str], dir: &Path) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

// AC-9 case 1: start IS the fixture root (direct-hit, Jj)
#[test]
fn find_repo_root_on_jj_root_returns_self() {
    let fixture = extract_fixture("tiny-3-commits").unwrap();
    let result = find_repo_root(&fixture.path).unwrap();
    assert_eq!(
        result,
        Some(RepoRoot {
            root: fixture.path.clone(),
            kind: RepoKind::Jj
        })
    );
}

// AC-9 case 2: start is a sub-directory of a jj workspace -> suggestion (root != start)
#[test]
fn find_repo_root_on_subdir_of_jj_returns_workspace_root() {
    let fixture = extract_fixture("tiny-3-commits").unwrap();
    let subdir = fixture.path.join("somedir");
    fs::create_dir(&subdir).unwrap();
    let result = find_repo_root(&subdir).unwrap();
    let root_result = result.unwrap();
    assert_eq!(root_result.kind, RepoKind::Jj);
    assert_eq!(root_result.root, fixture.path);
    // The consent-gated suggestion case: root != start.
    assert_ne!(root_result.root, subdir);
}

// AC-9 case 3: start is a sub-directory of a git-init dir (no .jj) -> Git suggestion
#[test]
fn find_repo_root_on_subdir_of_git_returns_git_root() {
    let dir = TempDir::new().unwrap();
    git(&["init"], dir.path());
    let subdir = dir.path().join("src");
    fs::create_dir(&subdir).unwrap();
    let result = find_repo_root(&subdir).unwrap();
    let root_result = result.unwrap();
    assert_eq!(root_result.kind, RepoKind::Git);
    assert_eq!(root_result.root, dir.path());
    assert_ne!(root_result.root, subdir);
}

// AC-9 case 4: deep nesting / nearest wins — inner jj inside outer git -> inner returned
#[test]
fn find_repo_root_nearest_inner_wins() {
    let outer = TempDir::new().unwrap();
    // outer is a git repo
    git(&["init"], outer.path());
    // inner is a jj workspace inside outer
    let inner = outer.path().join("inner");
    fs::create_dir(&inner).unwrap();
    fs::create_dir(inner.join(".jj")).unwrap();
    // Start even deeper inside inner
    let deep = inner.join("src").join("lib");
    fs::create_dir_all(&deep).unwrap();
    let result = find_repo_root(&deep).unwrap();
    assert_eq!(
        result,
        Some(RepoRoot {
            root: inner.clone(),
            kind: RepoKind::Jj
        })
    );
}

// AC-9 case 5: no repo at or above start -> Ok(None)
#[test]
fn find_repo_root_no_repo_returns_none() {
    let dir = TempDir::new().unwrap();
    // sub-tree with no markers; TempDir lives outside $HOME so no home ceiling fires.
    let subdir = dir.path().join("a").join("b");
    fs::create_dir_all(&subdir).unwrap();
    let result = find_repo_root(&subdir).unwrap();
    assert_eq!(result, None);
}

// AC-9 case 6: non-existent start whose lexical ancestors contain no repo -> Ok(None)
#[test]
fn find_repo_root_nonexistent_start_no_repo_above_returns_none() {
    let dir = TempDir::new().unwrap();
    // The start path does not exist, and neither does any ancestor within tmp.
    let nonexistent = dir.path().join("does_not_exist").join("child");
    let result = find_repo_root(&nonexistent).unwrap();
    assert_eq!(result, None);
}

// AC-9 case 7: colocated (.jj/ + .git/) nearest level -> kind is Jj
#[test]
fn find_repo_root_colocated_returns_jj() {
    let dir = TempDir::new().unwrap();
    fs::create_dir(dir.path().join(".jj")).unwrap();
    fs::create_dir(dir.path().join(".git")).unwrap();
    let result = find_repo_root(dir.path()).unwrap();
    assert_eq!(
        result,
        Some(RepoRoot {
            root: dir.path().to_owned(),
            kind: RepoKind::Jj
        })
    );
}

// AC-9 case 9: start is a path under a regular file -> ENOTDIR -> Err(DetectError::Io)
#[test]
fn find_repo_root_path_under_regular_file_returns_io_error() {
    let dir = TempDir::new().unwrap();
    let file = dir.path().join("a_file");
    fs::write(&file, b"x").unwrap();
    // `file/sub` has a non-directory component -> ENOTDIR
    let under_file = file.join("sub");
    let err = find_repo_root(&under_file).unwrap_err();
    assert!(matches!(err, DetectError::Io(_)), "expected Io, got {err:?}");
}
