// SPDX-License-Identifier: MIT

use std::sync::LazyLock;
use std::{env, fs};

use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{convert_colocated, RepoError, RepoKind};

/// Env-var pin: same rationale as tests/repo.rs — defence-in-depth against
/// local `JJ_CONFIG` / `GIT_CONFIG_GLOBAL` interfering with jj-lib init calls.
static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// Run a git command in `dir`; panics on non-zero exit.
fn git(args: &[&str], dir: &std::path::Path) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// Run a git command and return captured stdout (trimmed).
fn git_stdout(args: &[&str], dir: &std::path::Path) -> String {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git command failed to spawn");
    assert!(out.status.success(), "git {args:?} failed in {}", dir.display());
    String::from_utf8(out.stdout)
        .expect("git output is not UTF-8")
        .trim()
        .to_owned()
}

/// Build a plain Git repo at `path` with one commit on `main`.
fn init_git_repo_with_commit(path: &std::path::Path) {
    git(&["init", "--initial-branch=main"], path);
    git(&["config", "user.email", "test@zanshin.test"], path);
    git(&["config", "user.name", "Fixture"], path);
    fs::write(path.join("README.md"), "hello").expect("write README");
    git(&["add", "."], path);
    git(&["commit", "-m", "initial"], path);
}

// ── AC-9 case 1: happy path ───────────────────────────────────────────────────

#[test]
fn convert_git_repo_with_commit_returns_jj() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());

    let result = convert_colocated(tmp.path());
    assert!(result.is_ok(), "expected Ok, got: {result:?}");

    // detect_repo must see Jj after conversion.
    let kind = zanshin_jj::detect_repo(tmp.path()).expect("detect after convert");
    assert_eq!(kind, RepoKind::Jj, "detect_repo must return Jj after convert");

    // .jj/ must be present.
    assert!(tmp.path().join(".jj").is_dir(), ".jj/ must exist after convert");

    // Repo::open must succeed.
    let repo = zanshin_jj::Repo::open(tmp.path()).expect("Repo::open after convert");

    // The imported `main` bookmark must be present (AC-9 case 1: HEAD commit reachable via bookmark).
    let bookmarks = repo.list_bookmarks().expect("list_bookmarks");
    let has_main = bookmarks.iter().any(|b| b.name == "main");
    assert!(
        has_main,
        "bookmark 'main' must be present after convert; got: {bookmarks:?}"
    );
}

// ── AC-9 case 2: .git/ untouched ─────────────────────────────────────────────

#[test]
fn convert_git_repo_does_not_modify_git_dir() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());

    let head_before = git_stdout(&["rev-parse", "HEAD"], tmp.path());
    // Only compare user-visible refs (heads + tags). jj adds `refs/jj/keep/*`
    // internally — those are additive GC-keep markers, not modifications to
    // existing branches or tags (AC-5: "the Git HEAD SHA and set of refs are
    // unchanged" refers to the user-facing ref namespace).
    let refs_before = git_stdout(
        &[
            "for-each-ref",
            "--format=%(refname) %(objectname)",
            "refs/heads",
            "refs/tags",
        ],
        tmp.path(),
    );

    convert_colocated(tmp.path()).expect("convert");

    let head_after = git_stdout(&["rev-parse", "HEAD"], tmp.path());
    let refs_after = git_stdout(
        &[
            "for-each-ref",
            "--format=%(refname) %(objectname)",
            "refs/heads",
            "refs/tags",
        ],
        tmp.path(),
    );

    assert_eq!(head_before, head_after, "git HEAD SHA must be unchanged");
    assert_eq!(
        refs_before, refs_after,
        "git user-visible refs (heads/tags) must be unchanged"
    );
}

// ── AC-9 case 3: AlreadyJjRepo ────────────────────────────────────────────────

#[test]
fn convert_already_jj_repo_returns_already_jj_repo() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let result = convert_colocated(&fixture.path);
    assert!(
        matches!(result, Err(RepoError::AlreadyJjRepo { .. })),
        "expected AlreadyJjRepo, got: {result:?}"
    );
}

// ── AC-9 case 4a: NotAGitRepo — empty dir ────────────────────────────────────

#[test]
fn convert_empty_dir_returns_not_a_git_repo() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let result = convert_colocated(tmp.path());
    assert!(
        matches!(result, Err(RepoError::NotAGitRepo { .. })),
        "expected NotAGitRepo for empty dir, got: {result:?}"
    );
}

// ── AC-9 case 4b: NotAGitRepo — nonexistent path ─────────────────────────────

#[test]
fn convert_nonexistent_path_returns_not_a_git_repo() {
    pin_env();
    let result = convert_colocated(std::path::Path::new("/nonexistent/zanshin-convert-test-abc123"));
    assert!(
        matches!(result, Err(RepoError::NotAGitRepo { .. })),
        "expected NotAGitRepo for nonexistent path, got: {result:?}"
    );
}

// ── AC-9 case 5: unborn branch (no commits) ──────────────────────────────────

#[test]
fn convert_unborn_branch_succeeds_empty_history() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    git(&["init", "--initial-branch=main"], tmp.path());
    git(&["config", "user.email", "test@zanshin.test"], tmp.path());
    git(&["config", "user.name", "Fixture"], tmp.path());
    // No commits — unborn branch.

    let result = convert_colocated(tmp.path());
    assert!(
        result.is_ok(),
        "convert with unborn branch must succeed, got: {result:?}"
    );

    let kind = zanshin_jj::detect_repo(tmp.path()).expect("detect");
    assert_eq!(kind, RepoKind::Jj, "must detect as Jj after convert of unborn branch");
}

// ── AC-9 case 6: dirty working tree — no clobber ─────────────────────────────

#[test]
fn convert_dirty_tree_preserves_uncommitted_changes() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());

    // Dirty the working tree without committing.
    fs::write(tmp.path().join("README.md"), "dirty").expect("write dirty README");

    convert_colocated(tmp.path()).expect("convert");

    // The dirty contents must survive byte-identical (AC-6: no data loss).
    let contents = fs::read_to_string(tmp.path().join("README.md")).expect("read README after convert");
    assert_eq!(
        contents, "dirty",
        "dirty working-tree changes must be preserved verbatim"
    );
}

// ── AC-9 case 7: rollback on failure ─────────────────────────────────────────

#[test]
fn convert_failure_rolls_back_partial_jj() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    // An empty `.git` directory: detect_repo classifies it `Git` (dir exists),
    // but Workspace::init_external_git fails (no HEAD/objects). NOTE: in this EARLY
    // failure path jj-lib's own init cleanup (`init_with_factories` inspect_err)
    // removes the just-created `.jj/`, so this test pins the ConvertFailed *mapping*,
    // not convert's own rollback line. A mutation-sensitive test of that rollback line
    // would need a post-init failure, which jj-lib's graceful degradation on git
    // corruption makes non-deterministic without a fault-injection seam (see the
    // story's Review Findings).
    fs::create_dir(tmp.path().join(".git")).expect("create empty .git dir");

    let result = convert_colocated(tmp.path());
    assert!(
        matches!(result, Err(RepoError::ConvertFailed { .. })),
        "expected ConvertFailed for invalid .git, got: {result:?}"
    );
    assert!(
        !tmp.path().join(".jj").exists(),
        "failed convert must roll back — no partial .jj/ may remain"
    );
}

// ── AC-9 case 8: bare repo → NotAGitRepo (reconciled D7) ─────────────────────

#[test]
fn convert_bare_repo_returns_not_a_git_repo() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    git(&["init", "--bare"], tmp.path());

    let result = convert_colocated(tmp.path());
    assert!(
        matches!(result, Err(RepoError::NotAGitRepo { .. })),
        "expected NotAGitRepo for bare repo (detect_repo classifies as Neither), got: {result:?}"
    );
}

// ── reversibility: removing .jj/ restores plain Git ──────────────────────────

#[test]
fn convert_then_remove_jj_restores_git() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());

    convert_colocated(tmp.path()).expect("convert");
    assert_eq!(zanshin_jj::detect_repo(tmp.path()).expect("detect jj"), RepoKind::Jj);

    fs::remove_dir_all(tmp.path().join(".jj")).expect("remove .jj");
    assert_eq!(
        zanshin_jj::detect_repo(tmp.path()).expect("detect git after removal"),
        RepoKind::Git,
        "removing .jj/ must restore plain Git classification"
    );
}

// ── AC-2 / D3a: detached HEAD commit reachable via the imported git_head ──────

#[test]
fn convert_detached_head_imports_head_commit() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());
    // Detach HEAD and delete the branch, so NO local bookmark points at the commit —
    // reachability now depends solely on convert's `import_head` (object-import +
    // git_head ref). The happy-path test only checks the bookmark path; this exercises
    // the distinct detached-HEAD path that AC-2 / D3a explicitly claim.
    git(&["checkout", "--detach", "HEAD"], tmp.path());
    git(&["branch", "-D", "main"], tmp.path());

    let repo = convert_colocated(tmp.path()).expect("convert detached HEAD");

    // No bookmark survives the branch deletion …
    let bookmarks = repo.list_bookmarks().expect("list_bookmarks");
    assert!(
        bookmarks.is_empty(),
        "no bookmark expected after branch deletion; got: {bookmarks:?}"
    );
    // … yet the HEAD commit is reachable via the imported git_head ref. If convert
    // dropped `import_head`, `git_head()` would resolve to nothing and this fails.
    let head = zanshin_jj::resolve_revset(&repo, "git_head()").expect("resolve git_head()");
    assert_eq!(
        head.len(),
        1,
        "the detached HEAD commit must be reachable via git_head(); got: {head:?}"
    );
}

// ── AC-7: a detect_repo I/O error maps to ConvertFailed (not NotAGitRepo) ─────

#[test]
fn convert_path_under_regular_file_returns_convert_failed() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let file = tmp.path().join("not-a-dir");
    fs::write(&file, "regular file").expect("write regular file");
    // Stat'ing a path *under* a regular file yields ENOTDIR, so detect_repo returns
    // Err(DetectError) — a genuine I/O error, distinct from PathNotFound — which
    // convert maps to ConvertFailed (AC-7), not NotAGitRepo.
    let result = convert_colocated(&file.join("child"));
    assert!(
        matches!(result, Err(RepoError::ConvertFailed { .. })),
        "expected ConvertFailed for a detect_repo I/O error, got: {result:?}"
    );
}
