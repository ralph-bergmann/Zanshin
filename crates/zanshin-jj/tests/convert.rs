// SPDX-License-Identifier: MIT

use std::sync::LazyLock;
use std::{env, fs};

use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{convert_colocated, convert_import, RepoError, RepoKind};

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

// =============================================================================
// convert_import tests (Story 2.13, AC-2..AC-11)
// =============================================================================

/// Clone a normal Git repo as a bare repo (returns the bare repo path inside
/// `parent`). Shells to `git clone --bare` which is allowed in tests.
fn git_bare_clone(src: &std::path::Path, parent: &std::path::Path) -> std::path::PathBuf {
    let bare = parent.join("bare.git");
    git(
        &["clone", "--bare", &src.to_string_lossy(), &bare.to_string_lossy()],
        parent,
    );
    bare
}

// ── Test 1: happy path — normal source + fresh dest ──────────────────────────

#[test]
fn convert_import_git_repo_with_commit_returns_jj_native() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let result = convert_import(src.path(), &dst);
    assert!(result.is_ok(), "expected Ok, got: {result:?}");

    // jj-native: detect_repo sees Jj; .jj/ present; NO .git/ in dest.
    assert_eq!(
        zanshin_jj::detect_repo(&dst).expect("detect"),
        RepoKind::Jj,
        "detect_repo must return Jj"
    );
    assert!(dst.join(".jj").is_dir(), ".jj/ must exist");
    assert!(!dst.join(".git").exists(), "no .git/ in jj-native workspace");

    // Working-copy materialised: README.md from the source commit is present.
    assert_eq!(
        fs::read_to_string(dst.join("README.md")).expect("README in dest"),
        "hello",
        "working copy must be materialised with HEAD's tree"
    );

    // Repo::open succeeds and can resolve git_head().
    let repo = zanshin_jj::Repo::open(&dst).expect("Repo::open");
    let head = zanshin_jj::resolve_revset(&repo, "git_head()").expect("resolve git_head()");
    assert_eq!(head.len(), 1, "imported HEAD commit must be reachable via git_head()");
}

// ── Test 2: source refs/HEAD unchanged after import ──────────────────────────

#[test]
fn convert_import_does_not_modify_source_git() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());

    let head_before = git_stdout(&["rev-parse", "HEAD"], src.path());
    let refs_before = git_stdout(
        &[
            "for-each-ref",
            "--format=%(refname) %(objectname)",
            "refs/heads",
            "refs/tags",
        ],
        src.path(),
    );

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");
    convert_import(src.path(), &dst).expect("convert_import");

    let head_after = git_stdout(&["rev-parse", "HEAD"], src.path());
    let refs_after = git_stdout(
        &[
            "for-each-ref",
            "--format=%(refname) %(objectname)",
            "refs/heads",
            "refs/tags",
        ],
        src.path(),
    );

    assert_eq!(head_before, head_after, "git HEAD SHA must be unchanged");
    assert_eq!(
        refs_before, refs_after,
        "git user-visible refs (heads/tags) must be unchanged"
    );
}

// ── Test 3: bare source is supported (AC-4 / D9) ─────────────────────────────

#[test]
fn convert_import_bare_source_returns_jj_native() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());

    let bare_parent = TempDir::new().expect("tempdir bare parent");
    let bare = git_bare_clone(src.path(), bare_parent.path());

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let result = convert_import(&bare, &dst);
    assert!(result.is_ok(), "bare source must succeed, got: {result:?}");

    assert_eq!(
        zanshin_jj::detect_repo(&dst).expect("detect"),
        RepoKind::Jj,
        "detect_repo must return Jj after bare-source import"
    );
    assert!(
        !dst.join(".git").exists(),
        "no .git/ in jj-native workspace from bare source"
    );

    // Working copy materialised from bare source.
    assert_eq!(
        fs::read_to_string(dst.join("README.md")).expect("README from bare"),
        "hello",
        "working copy must be materialised from the bare source's HEAD tree"
    );
}

// ── Test 4: destination already a jj repo → AlreadyJjRepo ────────────────────

#[test]
fn convert_import_destination_already_jj_returns_already_jj_repo() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());

    // Destination is a pre-existing jj repo (from fixture).
    let dst_fixture = extract_fixture("tiny-3-commits").expect("fixture");

    let result = convert_import(src.path(), &dst_fixture.path);
    // AC-3 / Test-recipe row 4: the offending `path` is the DESTINATION.
    assert!(
        matches!(&result, Err(RepoError::AlreadyJjRepo { path }) if path == &dst_fixture.path),
        "expected AlreadyJjRepo with path==dest, got: {result:?}"
    );
}

// ── Test 5: source already a jj repo → AlreadyJjRepo ─────────────────────────

#[test]
fn convert_import_source_already_jj_returns_already_jj_repo() {
    pin_env();
    let src_fixture = extract_fixture("tiny-3-commits").expect("fixture");

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let result = convert_import(&src_fixture.path, &dst);
    // AC-3 / Test-recipe row 5: the offending `path` is the SOURCE.
    assert!(
        matches!(&result, Err(RepoError::AlreadyJjRepo { path }) if path == &src_fixture.path),
        "expected AlreadyJjRepo with path==source, got: {result:?}"
    );
}

// ── Test 6: non-git source (empty dir) → NotAGitRepo ─────────────────────────

#[test]
fn convert_import_empty_source_returns_not_a_git_repo() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let result = convert_import(src.path(), &dst);
    assert!(
        matches!(result, Err(RepoError::NotAGitRepo { .. })),
        "expected NotAGitRepo for empty source, got: {result:?}"
    );
}

// ── Test 7: nonexistent source → NotAGitRepo ─────────────────────────────────

#[test]
fn convert_import_nonexistent_source_returns_not_a_git_repo() {
    pin_env();
    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let result = convert_import(std::path::Path::new("/nonexistent/zanshin-import-test-abc123"), &dst);
    assert!(
        matches!(result, Err(RepoError::NotAGitRepo { .. })),
        "expected NotAGitRepo for nonexistent source, got: {result:?}"
    );
}

// ── Test 8: unborn branch source → Ok (no check_out, no panic) ───────────────

#[test]
fn convert_import_unborn_branch_source_succeeds() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    git(&["init", "--initial-branch=main"], src.path());
    git(&["config", "user.email", "test@zanshin.test"], src.path());
    git(&["config", "user.name", "Fixture"], src.path());
    // No commits — unborn branch; git_head() will be None.

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let result = convert_import(src.path(), &dst);
    assert!(result.is_ok(), "unborn branch source must succeed, got: {result:?}");
    assert_eq!(
        zanshin_jj::detect_repo(&dst).expect("detect"),
        RepoKind::Jj,
        "must detect as Jj even with unborn branch source"
    );
    // Empty history: an unborn source imports no HEAD commit (symmetric to Test 1).
    let repo = zanshin_jj::Repo::open(&dst).expect("Repo::open");
    assert_eq!(
        zanshin_jj::resolve_revset(&repo, "git_head()")
            .expect("resolve git_head()")
            .len(),
        0,
        "unborn source must import no HEAD commit"
    );
}

// ── Test 8b: bare + unborn source → Ok, empty history (AC-10 bare-unborn arm) ─

#[test]
fn convert_import_bare_unborn_source_succeeds() {
    pin_env();
    // Bare repo with NO commits: HEAD (→ refs/heads/main, unborn) + objects/ + refs/
    // → is_bare_git_dir true, git_head None. The one AC-10 arm not otherwise tested
    // (Test 3 is bare-WITH-history; Test 8 is normal-unborn).
    let bare = TempDir::new().expect("tempdir bare");
    git(&["init", "--bare", "--initial-branch=main"], bare.path());

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let result = convert_import(bare.path(), &dst);
    assert!(result.is_ok(), "bare unborn source must succeed, got: {result:?}");
    assert_eq!(
        zanshin_jj::detect_repo(&dst).expect("detect"),
        RepoKind::Jj,
        "must detect as Jj for bare unborn source"
    );
    let repo = zanshin_jj::Repo::open(&dst).expect("Repo::open");
    assert_eq!(
        zanshin_jj::resolve_revset(&repo, "git_head()")
            .expect("resolve git_head()")
            .len(),
        0,
        "bare unborn source must import no HEAD commit"
    );
}

// ── Test 9: rollback on failure — created_dir removed ────────────────────────

#[test]
fn convert_import_failure_rolls_back() {
    pin_env();
    // Source: empty `.git` dir — detect_repo classifies as Git (child dir exists),
    // but Workspace::init_external_git fails (no HEAD/objects). Dest is fresh.
    let src = TempDir::new().expect("tempdir src");
    fs::create_dir(src.path().join(".git")).expect("create empty .git dir");

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let result = convert_import(src.path(), &dst);
    assert!(
        matches!(result, Err(RepoError::ConvertFailed { .. })),
        "expected ConvertFailed for invalid source, got: {result:?}"
    );
    assert!(
        !dst.exists(),
        "failed convert must roll back — created dest dir must be removed"
    );
}

// ── Test 10: detect_repo I/O error → ConvertFailed ───────────────────────────

#[test]
fn convert_import_detect_io_error_returns_convert_failed() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let file = tmp.path().join("not-a-dir");
    fs::write(&file, "regular file").expect("write");

    // Path under a regular file → ENOTDIR → detect_repo returns Err → ConvertFailed.
    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");
    let result = convert_import(&file.join("child"), &dst);
    assert!(
        matches!(result, Err(RepoError::ConvertFailed { .. })),
        "expected ConvertFailed for detect_repo I/O error, got: {result:?}"
    );
}

// ── Test 11: removing dest restores source as a standalone Git repo ───────────

#[test]
fn convert_import_then_remove_dest_restores_source() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    convert_import(src.path(), &dst).expect("convert_import");
    fs::remove_dir_all(&dst).expect("remove dest");

    // Source remains a healthy standalone Git repo.
    assert_eq!(
        zanshin_jj::detect_repo(src.path()).expect("detect source after removal"),
        RepoKind::Git,
        "source must remain a Git repo after dest is removed"
    );
    // git rev-parse HEAD must still work (AC-5 addendum).
    let _ = git_stdout(&["rev-parse", "HEAD"], src.path());
}

// ── Test 13: detect I/O error on dest → ConvertFailed (line 133) ─────────────

#[test]
fn convert_import_dest_detect_io_error_returns_convert_failed() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());

    let tmp = TempDir::new().expect("tempdir");
    let file = tmp.path().join("not-a-dir");
    fs::write(&file, "regular file").expect("write regular file");

    // workspace_path under a regular file → ENOTDIR → detect_repo Err → ConvertFailed.
    let result = convert_import(src.path(), &file.join("child"));
    assert!(
        matches!(result, Err(RepoError::ConvertFailed { .. })),
        "expected ConvertFailed for I/O error on dest detect, got: {result:?}"
    );
}

// ── Test 14: failure with pre-existing dest → only .jj/ rolled back ──────────

#[test]
fn convert_import_failure_with_pre_existing_dest_removes_jj_only() {
    pin_env();
    // Source: empty `.git` dir (init_external_git fails; no commits/objects).
    let src = TempDir::new().expect("tempdir src");
    fs::create_dir(src.path().join(".git")).expect("create empty .git dir");

    // Dest: pre-existing empty dir → created_dir = false.
    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");
    fs::create_dir(&dst).expect("create pre-existing dest");

    let result = convert_import(src.path(), &dst);
    assert!(
        matches!(result, Err(RepoError::ConvertFailed { .. })),
        "expected ConvertFailed for invalid source, got: {result:?}"
    );
    // Pre-existing dir survives; only .jj/ (if created) is removed.
    assert!(dst.exists(), "pre-existing dest dir must survive rollback");
    assert!(!dst.join(".jj").exists(), "no partial .jj/ after rollback");
}

// ── Test 15: git_repo_path ending in .git is accepted (resolve_git_repo_path) ─

#[test]
fn convert_import_dot_git_path_succeeds() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    // Passing src/.git directly: resolve_git_repo_path returns it as-is
    // (arg.ends_with(".git") is true).
    let dot_git = src.path().join(".git");
    let result = convert_import(&dot_git, &dst);
    assert!(
        result.is_ok(),
        "passing .git path directly must succeed, got: {result:?}"
    );
    assert_eq!(
        zanshin_jj::detect_repo(&dst).expect("detect"),
        RepoKind::Jj,
        "result must be a jj workspace"
    );
}

// ── Test 12: dest == source → colocated result (D5 default (b)) ──────────────

#[test]
fn convert_import_into_same_dir_is_colocated() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());

    // D5 default (b): passing the same directory as both source and dest lets jj
    // create a colocated workspace (is_colocated() returns true → check_out step
    // skipped). The path is passed RAW (not canonicalized) on purpose:
    // is_colocated() compares against `workspace.workspace_root()`, which jj-lib
    // canonicalizes, so the colocated detection must hold even for a non-canonical
    // caller path (macOS /var → /private/var). A prior version canonicalized the
    // input here, which MASKED the raw-path behaviour.
    let result = convert_import(src.path(), src.path());
    assert!(
        result.is_ok(),
        "same-dir must produce a colocated result, got: {result:?}"
    );
    // Colocated: both .jj/ and .git/ present.
    assert!(src.path().join(".jj").is_dir(), ".jj/ must exist");
    assert!(src.path().join(".git").exists(), ".git/ must still exist (colocated)");

    // The colocated skip must have fired: no jj-native `@` was created on top of
    // the imported HEAD. If is_colocated() had wrongly returned false (the raw-path
    // bug), check_out would have run and git_head() would gain a strict descendant.
    let repo = zanshin_jj::Repo::open(src.path()).expect("Repo::open");
    assert_eq!(
        zanshin_jj::resolve_revset(&repo, "descendants(git_head()) ~ git_head()")
            .expect("resolve revset")
            .len(),
        0,
        "colocated skip: imported HEAD must have no fresh jj-native child commit"
    );
}
