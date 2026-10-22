// SPDX-License-Identifier: MIT

use std::fs;
use std::path::{Path, PathBuf};

use jj_lib::backend::CommitId;
use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{convert_colocated, convert_import, Repo, RepoError, RepoKind};

/// Pins the process environment; returns the pinned `$XDG_CONFIG_HOME`.
fn pin_env() -> &'static Path {
    test_helpers::pin_test_env()
}

/// The commit ids the workspace's imported Git `HEAD` points at — the view's git head for the
/// workspace (kept per workspace since jj 0.45, and only for a COLOCATED one).
///
/// WHY: jj 0.44 removed the `git_head()` REVSET function (upstream deprecated it, suggesting
/// `first_parent(@)` as a colocated-repo approximation). Reading the view asserts exactly the
/// property these tests were written for — and does so more tightly than `first_parent(@)`
/// would: the latter is also satisfied by `check_out` alone, so it could not catch a dropped
/// `import_head`.
fn git_head_ids(workspace_root: &std::path::Path) -> Vec<CommitId> {
    let (workspace, repo) = oracle_repo(workspace_root);
    repo.view()
        .git_head(workspace.workspace_name())
        .present_adds()
        .cloned()
        .collect()
}

/// The parents of the workspace's `@` — where a NON-colocated conversion checks the imported
/// Git `HEAD` out. Since jj 0.45 that path records no git head in the view (`import_head_commit`,
/// as `jj git init` does), so the checkout is what witnesses the head import.
fn wc_parent_ids(workspace_root: &std::path::Path) -> Vec<CommitId> {
    let (workspace, repo) = oracle_repo(workspace_root);
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .expect("the workspace has an @");
    repo.store().get_commit(wc_id).expect("load @").parent_ids().to_vec()
}

/// Loads the workspace at `workspace_root` with a fixed identity, at its head operation.
fn oracle_repo(workspace_root: &std::path::Path) -> (Workspace, std::sync::Arc<jj_lib::repo::ReadonlyRepo>) {
    let mut config = StackedConfig::with_defaults();
    config.add_layer(
        ConfigLayer::parse(
            ConfigSource::User,
            r#"
                [user]
                name = "Zanshin"
                email = "zanshin@localhost"
                [operation]
                username = "zanshin"
                hostname = "localhost"
            "#,
        )
        .expect("valid config literal"),
    );
    let settings = UserSettings::from_config_and_home_dir(config, None).expect("valid settings");
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head");
    (workspace, repo)
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

    let result = convert_colocated(tmp.path()).result;
    assert!(result.is_ok(), "expected Ok, got: {result:?}");

    // detect_repo must see Jj after conversion.
    let kind = zanshin_jj::detect_repo(tmp.path()).expect("detect after convert");
    assert_eq!(kind, RepoKind::Jj, "detect_repo must return Jj after convert");

    // .jj/ must be present.
    assert!(tmp.path().join(".jj").is_dir(), ".jj/ must exist after convert");

    // Repo::open must succeed.
    let mut repo = zanshin_jj::Repo::open(tmp.path()).expect("Repo::open after convert");

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

    convert_colocated(tmp.path()).result.expect("convert");

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
    let result = convert_colocated(&fixture.path).result;
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
    let result = convert_colocated(tmp.path()).result;
    assert!(
        matches!(result, Err(RepoError::NotAGitRepo { .. })),
        "expected NotAGitRepo for empty dir, got: {result:?}"
    );
}

// ── AC-9 case 4b: NotAGitRepo — nonexistent path ─────────────────────────────

#[test]
fn convert_nonexistent_path_returns_not_a_git_repo() {
    pin_env();
    let result = convert_colocated(std::path::Path::new("/nonexistent/zanshin-convert-test-abc123")).result;
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

    let result = convert_colocated(tmp.path()).result;
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

    convert_colocated(tmp.path()).result.expect("convert");

    // The dirty contents must survive byte-identical (AC-6: no data loss).
    let contents = fs::read_to_string(tmp.path().join("README.md")).expect("read README after convert");
    assert_eq!(
        contents, "dirty",
        "dirty working-tree changes must be preserved verbatim"
    );
}

// ── AC-9 case 7: an early failure leaves what jj-lib leaves ──────────────────

/// Story 9.57: an empty `.git` directory is classified `Git`, but `init_external_git` fails (no
/// HEAD/objects) and jj-lib's own init cleanup (`init_with_factories`) removes the `.jj/` it just
/// created — the only cleanup `jj git init` has. Zanshin deletes nothing, so nothing is left
/// behind.
#[test]
fn convert_failure_in_init_external_git_leaves_no_jj() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    fs::create_dir(tmp.path().join(".git")).expect("create empty .git dir");

    let outcome = convert_colocated(tmp.path());
    assert!(
        matches!(outcome.result, Err(RepoError::ConvertFailed { .. })),
        "expected ConvertFailed for invalid .git, got: {:?}",
        outcome.result
    );
    assert!(!tmp.path().join(".jj").exists(), "jj-lib removed the .jj/ it created");
    assert!(outcome.left_behind.is_empty(), "{:?}", outcome.left_behind);
    assert!(tmp.path().join(".git").is_dir(), ".git/ is untouched");
}

// ── AC-9 case 8: bare repo → NotAGitRepo (reconciled D7) ─────────────────────

#[test]
fn convert_bare_repo_returns_not_a_git_repo() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    git(&["init", "--bare"], tmp.path());

    let result = convert_colocated(tmp.path()).result;
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

    convert_colocated(tmp.path()).result.expect("convert");
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

    let mut repo = convert_colocated(tmp.path()).result.expect("convert detached HEAD");

    // No bookmark survives the branch deletion …
    let bookmarks = repo.list_bookmarks().expect("list_bookmarks");
    assert!(
        bookmarks.is_empty(),
        "no bookmark expected after branch deletion; got: {bookmarks:?}"
    );
    // … yet the HEAD commit is reachable via the imported git_head ref. If convert
    // dropped `import_head`, git_head would be empty and this fails.
    let head = git_head_ids(repo.workspace_root());
    assert_eq!(
        head.len(),
        1,
        "the detached HEAD commit must be reachable via git_head; got: {head:?}"
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
    let result = convert_colocated(&file.join("child")).result;
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

    let result = convert_import(src.path(), &dst).result;
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

    // Repo::open succeeds and `@` sits on the imported HEAD commit. Since jj 0.45 the
    // non-colocated path records no git head (the CLI's `jj git init` uses `import_head_commit`).
    zanshin_jj::Repo::open(&dst).expect("Repo::open");
    assert_eq!(
        git_head_ids(&dst),
        Vec::<CommitId>::new(),
        "a non-colocated workspace tracks no git head"
    );
    let src_head = git_stdout(&["rev-parse", "HEAD"], src.path());
    let parents: Vec<String> = wc_parent_ids(&dst).iter().map(CommitId::hex).collect();
    assert_eq!(
        parents,
        vec![src_head],
        "`@` must be checked out onto the source's HEAD commit"
    );
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
    convert_import(src.path(), &dst).result.expect("convert_import");

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

    let result = convert_import(&bare, &dst).result;
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

    let result = convert_import(src.path(), &dst_fixture.path).result;
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

    let result = convert_import(&src_fixture.path, &dst).result;
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

    let result = convert_import(src.path(), &dst).result;
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

    let result = convert_import(std::path::Path::new("/nonexistent/zanshin-import-test-abc123"), &dst).result;
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

    let result = convert_import(src.path(), &dst).result;
    assert!(result.is_ok(), "unborn branch source must succeed, got: {result:?}");
    assert_eq!(
        zanshin_jj::detect_repo(&dst).expect("detect"),
        RepoKind::Jj,
        "must detect as Jj even with unborn branch source"
    );
    // Empty history: an unborn source imports no HEAD commit (symmetric to Test 1) — `@`
    // stays on the root commit.
    let mut repo = zanshin_jj::Repo::open(&dst).expect("Repo::open");
    assert_eq!(
        zanshin_jj::resolve_revset(&repo, "@-").expect("resolve @-"),
        zanshin_jj::resolve_revset(&repo, "root()").expect("resolve root()"),
        "unborn source must import no HEAD commit"
    );
    // The NON-colocated head transaction carries its own `has_changes()` guard, separate
    // from the ones inside `init_git_refs` / `import_git_head` — and this is the only
    // `convert_import` row with an empty source. Without this assertion, dropping that guard
    // would ship a spurious `import git head` operation unnoticed.
    assert_eq!(
        op_descriptions(&mut repo),
        vec!["add workspace 'default'", ""],
        "an unborn source must write neither operation on the non-colocated path either"
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

    let result = convert_import(bare.path(), &dst).result;
    assert!(result.is_ok(), "bare unborn source must succeed, got: {result:?}");
    assert_eq!(
        zanshin_jj::detect_repo(&dst).expect("detect"),
        RepoKind::Jj,
        "must detect as Jj for bare unborn source"
    );
    let repo = zanshin_jj::Repo::open(&dst).expect("Repo::open");
    assert_eq!(
        zanshin_jj::resolve_revset(&repo, "@-").expect("resolve @-"),
        zanshin_jj::resolve_revset(&repo, "root()").expect("resolve root()"),
        "bare unborn source must import no HEAD commit"
    );
}

// ── Test 9: a failure leaves the created destination ─────────────────────────

/// Story 9.57: the CLI's `create_or_reuse_dir` leaves a destination it created when `do_init`
/// fails (`cli/src/commands/git/init.rs` @ v0.46.0 propagates with `?`); jj-lib removes only its
/// own `.jj/`. The destination is reported as left behind.
#[test]
fn convert_import_failure_leaves_the_created_destination() {
    pin_env();
    // Source: empty `.git` dir — detect_repo classifies as Git (child dir exists),
    // but Workspace::init_external_git fails (no HEAD/objects). Dest is fresh.
    let src = TempDir::new().expect("tempdir src");
    fs::create_dir(src.path().join(".git")).expect("create empty .git dir");

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let outcome = convert_import(src.path(), &dst);
    assert!(
        matches!(outcome.result, Err(RepoError::ConvertFailed { .. })),
        "expected ConvertFailed for invalid source, got: {:?}",
        outcome.result
    );
    assert!(dst.is_dir(), "the created destination stays, as in the CLI");
    assert!(!dst.join(".jj").exists(), "jj-lib removed the .jj/ it created");
    assert_eq!(outcome.left_behind, [dst.canonicalize().expect("canonicalize")]);
}

/// Story 9.58: the destination is created ONE level deep, as the CLI's `create_or_reuse_dir`
/// (`cli/src/commands/git/init.rs:161-163` @ v0.46.0): under a missing parent the import refuses
/// with the CLI's "Failed to create workspace: …", creates nothing and leaves nothing behind.
#[test]
fn convert_import_under_a_missing_parent_refuses_and_creates_nothing() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());

    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("missing").join("dest");

    let outcome = convert_import(src.path(), &dst);
    assert!(
        matches!(&outcome.result, Err(RepoError::ConvertFailed { reason })
            if reason.starts_with("Failed to create workspace: ")),
        "{:?}",
        outcome.result
    );
    assert!(!dst_parent.path().join("missing").exists(), "no parent is created");
    assert!(outcome.left_behind.is_empty(), "{:?}", outcome.left_behind);
}

/// Story 9.58: a `..` destination names the directory the call actually created — canonical,
/// read from the creation's own result.
#[test]
fn convert_import_failure_reports_a_dot_dot_destination_canonically() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    fs::create_dir(src.path().join(".git")).expect("create empty .git dir");

    let dst_parent = TempDir::new().expect("tempdir dst");
    fs::create_dir(dst_parent.path().join("x")).expect("mkdir x");
    let dst = dst_parent.path().join("x").join("..").join("y");

    let outcome = convert_import(src.path(), &dst);
    assert!(outcome.result.is_err(), "{:?}", outcome.result);
    let canonical_parent = dst_parent.path().canonicalize().expect("canonicalize");
    assert_eq!(outcome.left_behind, [canonical_parent.join("y")]);
}

/// Story 9.58: a destination that existed before the call is reused and never listed, even
/// when the call's own `.jj/` is left behind — here by a snapshot that cannot read a file.
#[test]
fn convert_import_failure_into_an_existing_destination_lists_only_its_jj() {
    use std::os::unix::fs::PermissionsExt as _;

    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());
    let dst = TempDir::new().expect("tempdir dst");
    let locked = dst.path().join("locked.txt");
    fs::write(&locked, "unreadable").expect("write");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).expect("chmod");

    let outcome = convert_import(src.path(), dst.path());
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o644)).expect("chmod back");

    assert!(
        matches!(outcome.result, Err(RepoError::ConvertFailed { .. })),
        "{:?}",
        outcome.result
    );
    let root = dst.path().canonicalize().expect("canonicalize");
    assert_eq!(outcome.left_behind, [root.join(".jj")]);
}

/// Story 9.58: a failed `Repo::init` over an existing `.git/` (the External flow) leaves the
/// `.jj/` it created, as `jj git init` does, and names it — canonical — in `left_behind`; the
/// destination existed, so it is not listed.
#[test]
fn init_over_a_git_repo_failing_late_reports_its_jj() {
    use std::os::unix::fs::PermissionsExt as _;

    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());
    let locked = tmp.path().join("locked.txt");
    fs::write(&locked, "unreadable").expect("write");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).expect("chmod");

    let outcome = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_path_buf(),
        backend: Some(zanshin_jj::Backend::Git),
        colocate: Some(true),
        ..Default::default()
    });
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o644)).expect("chmod back");

    assert!(
        matches!(outcome.result, Err(RepoError::ConvertFailed { .. })),
        "{:?}",
        outcome.result
    );
    assert!(tmp.path().join(".jj").is_dir(), "the .jj/ stays, as the CLI leaves it");
    let root = tmp.path().canonicalize().expect("canonicalize");
    assert_eq!(outcome.left_behind, [root.join(".jj")]);
}

/// Story 9.58: `Repo::init`'s refusals that write nothing — an existing workspace,
/// `--no-colocate` over `.git/`, a missing parent ("Failed to create workspace: …", nothing
/// created) — leave nothing behind.
#[test]
fn init_refusals_that_write_nothing_leave_nothing_behind() {
    pin_env();
    let git_options = |path: &Path, colocate: bool| zanshin_jj::InitOptions {
        path: path.to_path_buf(),
        backend: Some(zanshin_jj::Backend::Git),
        colocate: Some(colocate),
        ..Default::default()
    };

    let jj = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(jj.path());
    convert_colocated(jj.path()).result.expect("convert");
    let outcome = Repo::init(&git_options(jj.path(), true));
    assert!(
        matches!(outcome.result, Err(RepoError::AlreadyJjRepo { .. })),
        "{:?}",
        outcome.result
    );
    assert!(outcome.left_behind.is_empty(), "{:?}", outcome.left_behind);

    let git = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(git.path());
    let outcome = Repo::init(&git_options(git.path(), false));
    assert!(
        matches!(outcome.result, Err(RepoError::GitRepoExists { .. })),
        "{:?}",
        outcome.result
    );
    assert!(!git.path().join(".jj").exists(), "nothing written");
    assert!(outcome.left_behind.is_empty(), "{:?}", outcome.left_behind);

    let parent = TempDir::new().expect("tempdir");
    let outcome = Repo::init(&git_options(&parent.path().join("missing").join("dest"), false));
    assert!(
        matches!(&outcome.result, Err(RepoError::InitFailed { reason })
            if reason.starts_with("Failed to create workspace: ")),
        "{:?}",
        outcome.result
    );
    assert!(!parent.path().join("missing").exists(), "nothing created");
    assert!(outcome.left_behind.is_empty(), "{:?}", outcome.left_behind);
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
    let result = convert_import(&file.join("child"), &dst).result;
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

    convert_import(src.path(), &dst).result.expect("convert_import");
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
    let result = convert_import(src.path(), &file.join("child")).result;
    assert!(
        matches!(result, Err(RepoError::ConvertFailed { .. })),
        "expected ConvertFailed for I/O error on dest detect, got: {result:?}"
    );
}

// ── Test 14: failure with pre-existing dest → nothing left behind ────────────

/// Story 9.57: a destination that existed before the call is not the call's; jj-lib removed its
/// own `.jj/`, so nothing the call created is left.
#[test]
fn convert_import_failure_with_pre_existing_dest_leaves_nothing_behind() {
    pin_env();
    // Source: empty `.git` dir (init_external_git fails; no commits/objects).
    let src = TempDir::new().expect("tempdir src");
    fs::create_dir(src.path().join(".git")).expect("create empty .git dir");

    // Dest: pre-existing empty dir → created_dir = false.
    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");
    fs::create_dir(&dst).expect("create pre-existing dest");

    let outcome = convert_import(src.path(), &dst);
    assert!(
        matches!(outcome.result, Err(RepoError::ConvertFailed { .. })),
        "expected ConvertFailed for invalid source, got: {:?}",
        outcome.result
    );
    assert!(dst.exists(), "the pre-existing destination stays");
    assert!(!dst.join(".jj").exists(), "jj-lib removed the .jj/ it created");
    assert!(outcome.left_behind.is_empty(), "{:?}", outcome.left_behind);
}

/// Story 9.57: a dangling `.jj` symlink beside `.git/` is not a jj workspace to `detect_repo`,
/// but `init_external_git` refuses it as existing (`DestinationExists`) — that `.jj` is the
/// user's, not the call's, so it is untouched and never named in `left_behind`.
#[test]
fn convert_failure_over_a_pre_existing_jj_symlink_leaves_nothing_behind() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());
    std::os::unix::fs::symlink(tmp.path().join("nowhere"), tmp.path().join(".jj")).expect("symlink");

    let outcome = convert_colocated(tmp.path());
    assert!(
        matches!(outcome.result, Err(RepoError::ConvertFailed { .. })),
        "{:?}",
        outcome.result
    );
    let link = fs::read_link(tmp.path().join(".jj")).expect("the symlink is untouched");
    assert_eq!(link, tmp.path().join("nowhere"));
    assert!(outcome.left_behind.is_empty(), "{:?}", outcome.left_behind);
}

/// Story 9.57: an import into an existing destination that holds a `.jj` regular FILE fails, and
/// that file — the user's — is untouched and never named in `left_behind`.
#[test]
fn convert_import_failure_over_a_pre_existing_jj_file_leaves_nothing_behind() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());
    let dst = TempDir::new().expect("tempdir dst");
    fs::write(dst.path().join(".jj"), "the user's file").expect("write .jj file");

    let outcome = convert_import(src.path(), dst.path());
    assert!(outcome.result.is_err(), "{:?}", outcome.result);
    assert_eq!(
        fs::read_to_string(dst.path().join(".jj")).expect("read .jj"),
        "the user's file"
    );
    assert!(outcome.left_behind.is_empty(), "{:?}", outcome.left_behind);
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
    let result = convert_import(&dot_git, &dst).result;
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
    // skipped). The path is passed RAW (not canonicalized) on purpose: the DEST is
    // canonicalized inside `import_into` (so the workspace store records a root that
    // resolves), but the SOURCE stays the caller's spelling all the way into
    // `resolve_git_repo_path`. is_colocated() compares `git_backend.git_workdir()`
    // against `workspace.workspace_root()` — both canonical, neither a raw caller
    // path — so the colocated detection must hold for a non-canonical argument
    // (macOS /var → /private/var). Canonicalizing in the TEST would mask that.
    let result = convert_import(src.path(), src.path()).result;
    assert!(
        result.is_ok(),
        "same-dir must produce a colocated result, got: {result:?}"
    );
    // Colocated: both .jj/ and .git/ present.
    assert!(src.path().join(".jj").is_dir(), ".jj/ must exist");
    assert!(src.path().join(".git").exists(), ".git/ must still exist (colocated)");

    // The colocated shape must have been taken: if is_colocated had wrongly returned false
    // (the raw-path bug), the non-colocated tail would have run too.
    let mut repo = zanshin_jj::Repo::open(src.path()).expect("Repo::open");

    // D5 takes the COLOCATED shape whole: the head import is the colocated snapshot's (so the
    // op log is the CLI's two operations, and the non-colocated tail's `if colocated
    // { return }` really did fire), and the `.gitignore` is seeded like any other colocated
    // conversion.
    assert_eq!(
        op_descriptions(&mut repo),
        vec!["import git head", "import git refs", "add workspace 'default'", ""],
        "the colocated shape writes the CLI's two operations here too"
    );
    assert_eq!(
        fs::read_to_string(src.path().join(".jj").join(".gitignore")).expect(".jj/.gitignore must exist"),
        "/*\n",
        "the colocated shape seeds `.jj/.gitignore`; only the two-path use skips it"
    );

    // The removed `git_head()` revset function is replaced by substituting the commit id
    // the view records, so the descendants/exclusion query itself is unchanged.
    let head_ids = git_head_ids(repo.workspace_root());
    let [head] = head_ids.as_slice() else {
        panic!("expected exactly one imported git_head commit; got: {head_ids:?}");
    };
    let head_hex = head.hex();
    // The colocated head import checks `@` out onto the imported HEAD (Story 9.26 — the CLI's
    // `maybe_snapshot`), so HEAD's only descendant is `@` itself: one child, created by the
    // head import, not by the non-colocated tail (which would have written a SECOND
    // `import git head` operation above).
    assert_eq!(
        zanshin_jj::resolve_revset(&repo, &format!("descendants({head_hex}) ~ {head_hex}")).expect("resolve revset"),
        zanshin_jj::resolve_revset(&repo, "@").expect("resolve @"),
        "the colocated head import re-parents `@` onto the imported HEAD"
    );
}

// ── a converted workspace must resolve its OWN root, symlinked caller path or not ─

/// Canonicalizes both sides before comparing — the macOS `/var` → `/private/var` trap.
///
/// A local copy of the identically-named helper in `tests/it/workspace.rs`. It cannot move to
/// `crates/test-helpers` with the rest of the shared fixture vocabulary: its sibling
/// `assert_own_root_resolves` takes a `zanshin_jj::Repo`, and `test-helpers` is a dev-dependency
/// OF `zanshin-jj`, so hosting them there would invert that edge.
fn assert_same_dir(actual: &std::path::Path, expected: &std::path::Path) {
    assert_eq!(
        fs::canonicalize(actual).expect("actual path must exist"),
        fs::canonicalize(expected).expect("expected path must exist"),
        "paths must match once both sides are canonicalized"
    );
}

/// Both workspace READ verbs report `expected` for the single `default` workspace of `repo`.
fn assert_own_root_resolves(repo: &mut zanshin_jj::Repo, expected: &std::path::Path) {
    let entries = repo.list_workspaces().expect("list_workspaces");
    assert_eq!(
        entries.len(),
        1,
        "a converted repo has exactly the default workspace; got {entries:?}"
    );
    assert_eq!(entries[0].name, "default");
    let root = entries[0]
        .root
        .as_ref()
        .expect("a just-created workspace records a path that resolves");
    assert_same_dir(root, expected);

    let named = repo
        .resolve_workspace_root(Some("default"))
        .expect("the workspace's own recorded path must resolve");
    assert!(named.warnings.is_empty(), "the recorded directory exists");
    assert_same_dir(&named.value, expected);
    assert_eq!(
        named.value,
        repo.resolve_workspace_root(None)
            .expect("the no-name default cannot fail")
            .value,
        "naming the current workspace must agree with the no-name default"
    );
}

/// The workspace-store round trip for the COLOCATED-CONVERT seam.
///
/// `convert_into` reaches the same jj-lib `init_with_factories` that `Repo::init` does, so a caller
/// path still containing a symlink (on macOS every `/var/folders/…` temp dir points at
/// `/private/var/folders/…`) records a workspace root RELATIVE to a spelling no read ever joins
/// onto — and the converted workspace's own row goes absent while `root --name default` refuses.
/// Every other assertion in this file (file layout, imported bookmarks, op log, rollback) is blind
/// to the store, so without this test reverting `convert_colocated`'s canonicalize leaves the suite
/// green.
#[test]
fn convert_colocated_through_a_symlinked_path_resolves_its_own_root() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    assert_ne!(
        fs::canonicalize(tmp.path()).expect("temp dir exists").as_path(),
        tmp.path(),
        "this witness needs a temp path that really does go through a symlink; on macOS both \
         /tmp and /var/folders are symlinks, so a TMPDIR pointing at a real directory \
         disables it"
    );
    init_git_repo_with_commit(tmp.path());

    let mut converted = convert_colocated(tmp.path()).result.expect("convert_colocated");

    assert_own_root_resolves(&mut converted, tmp.path());
}

/// The same round trip for the IMPORT seam — where the canonicalize has to follow the
/// `create_dir_all`, because the destination may legitimately not exist yet.
///
/// The dest here is a not-yet-existing child of a symlinked temp dir, so it exercises that
/// ordering: `import_into` creates the directory and only then can resolve it.
#[test]
fn convert_import_through_a_symlinked_path_resolves_its_own_root() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());

    let dest_parent = TempDir::new().expect("tempdir dest");
    assert_ne!(
        fs::canonicalize(dest_parent.path()).expect("temp dir exists").as_path(),
        dest_parent.path(),
        "this witness needs a temp path that really does go through a symlink; on macOS both \
         /tmp and /var/folders are symlinks, so a TMPDIR pointing at a real directory \
         disables it"
    );
    let dest = dest_parent.path().join("workspace");
    assert!(!dest.exists(), "the dest must be created by import_into itself");

    let mut imported = convert_import(src.path(), &dest).result.expect("convert_import");

    assert_own_root_resolves(&mut imported, &dest);
}

// =============================================================================
// `jj git init` External-branch parity (Epic 9 follow-up K)
//
// The CLI's own on-disk effects: two operations with its descriptions, each skipped when its
// import changed nothing; `.jj/.gitignore` for a colocated workspace; and the repo-level
// `revset-aliases.'trunk()'`. Oracles are `git` and the file system, never a second call into
// the code under test.
// =============================================================================

/// What `ConfigFile::load_or_empty` puts at the top of a file it had to invent — jj-lib's
/// own schema line, so a `jj git init`-created file carries it too.
const FRESH_FILE_HEADER: &str = "#:schema https://docs.jj-vcs.dev/latest/config-schema.json\n\n";

/// Operation descriptions, newest-first — what `jj op log` would print, root op last.
fn op_descriptions(repo: &mut Repo) -> Vec<String> {
    repo.op_log(None)
        .expect("op log")
        .into_iter()
        .map(|op| op.description)
        .collect()
}

/// The repo-level config file `config.rs` resolves for `workspace_root`, iff a `config-id`
/// was written. Read straight off disk so it witnesses the `config-id` indirection rather
/// than trusting the crate's own resolver.
///
/// Only `NotFound` means "no alias was written". Any OTHER read error is a fault in the
/// fixture, not an answer — swallowing it would let the three `is_none()` rows below pass
/// vacuously.
fn repo_config_path(workspace_root: &Path, xdg: &Path) -> Option<PathBuf> {
    let id_path = workspace_root.join(".jj").join("repo").join("config-id");
    match fs::read_to_string(&id_path) {
        Ok(id) => Some(xdg.join("jj").join("repos").join(id).join("config.toml")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => panic!("reading {}: {e}", id_path.display()),
    }
}

/// `refs/heads` + `refs/tags` and the resolved HEAD, as `convert_git_repo_does_not_modify_git_dir`
/// reads them.
fn git_ref_snapshot(dir: &Path) -> (String, String) {
    (
        git_stdout(&["rev-parse", "HEAD"], dir),
        git_stdout(
            &[
                "for-each-ref",
                "--format=%(refname) %(objectname)",
                "refs/heads",
                "refs/tags",
            ],
            dir,
        ),
    )
}

/// A clone of `src` at `parent/work`, which is how a repo acquires a symbolic
/// `refs/remotes/origin/HEAD` — the input `maybe_set_repository_level_trunk_alias` reads.
fn git_clone(src: &Path, parent: &Path) -> PathBuf {
    let work = parent.join("work");
    git(&["clone", &src.to_string_lossy(), &work.to_string_lossy()], parent);
    git(&["config", "user.email", "test@zanshin.test"], &work);
    git(&["config", "user.name", "Fixture"], &work);
    work
}

#[test]
fn convert_colocated_writes_the_two_cli_operations() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());
    let before = git_ref_snapshot(tmp.path());

    let mut repo = convert_colocated(tmp.path()).result.expect("convert");

    assert_eq!(
        op_descriptions(&mut repo),
        vec!["import git head", "import git refs", "add workspace 'default'", ""],
        "the op log must be the CLI's, newest-first — one folded op would fail here"
    );
    // This pins the OUTCOME, not the branch: HEAD and the user-visible refs are where they
    // were. It would hold with the colocated `export_refs` removed, too — per the CLI's own
    // comment at `init.rs:308-310` that export only has anything to write once
    // `remotes.<name>.auto-track-bookmarks` has created local bookmarks for the imported
    // remote branches. That map is the effective config's (`config::git_import_options`), and
    // this row sets none, so the export writes nothing here; the branch itself is witnessed by
    // `tests/it/creation_warnings.rs::a_refs_step_export_failure_warns_first`. What this row is
    // for is to fail the moment it starts moving a ref.
    assert_eq!(
        git_ref_snapshot(tmp.path()),
        before,
        "the colocated export must not move HEAD or any user-visible ref"
    );
}

/// jj 0.45 replaced the CLI's refusal to colocate inside a LINKED git worktree with a warning
/// (`git/init.rs:272-281` @ v0.46.0): the conversion succeeds and warns last; the main
/// repository's own conversion does not warn.
#[test]
fn convert_colocated_inside_a_linked_git_worktree_warns() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let main = tmp.path().join("main");
    fs::create_dir(&main).expect("main dir");
    init_git_repo_with_commit(&main);
    let worktree = tmp.path().join("linked");
    git(
        &["worktree", "add", "-q", "-b", "side", worktree.to_str().unwrap()],
        &main,
    );

    let linked = convert_colocated(&worktree);
    linked
        .result
        .expect("the CLI creates the repo inside a linked worktree");
    let last = linked.warnings.last().expect("a warning");
    assert_eq!(
        (last.kind, last.message.as_str()),
        (
            zanshin_jj::WarningKind::ColocatedInGitWorktree,
            "Initialized a new colocated jj repo inside a Git worktree."
        )
    );

    let primary = convert_colocated(&main);
    primary.result.expect("convert the main repository");
    assert!(
        primary
            .warnings
            .iter()
            .all(|w| w.kind != zanshin_jj::WarningKind::ColocatedInGitWorktree),
        "the main repository is no linked worktree: {:?}",
        primary.warnings
    );
}

#[test]
fn convert_import_writes_the_two_cli_operations_and_materialises_head() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());
    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let mut repo = convert_import(src.path(), &dst).result.expect("convert_import");

    assert_eq!(
        op_descriptions(&mut repo),
        vec!["import git head", "import git refs", "add workspace 'default'", ""],
        "the non-colocated branch must write the same two operations, in the same order"
    );
    assert_eq!(
        fs::read_to_string(dst.join("README.md")).expect("README in dest"),
        "hello",
        "the working copy must still be materialised from the imported HEAD"
    );
}

/// The `has_changes()` guards: a source with nothing to import writes NEITHER operation, so
/// the op log is exactly what `Workspace::init_external_git` left behind.
#[test]
fn a_source_with_no_refs_writes_no_operation_at_all() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    git(&["init", "--initial-branch=main"], tmp.path());
    git(&["config", "user.email", "test@zanshin.test"], tmp.path());
    git(&["config", "user.name", "Fixture"], tmp.path());

    let mut repo = convert_colocated(tmp.path())
        .result
        .expect("convert of an unborn branch");
    assert_eq!(
        op_descriptions(&mut repo),
        vec!["add workspace 'default'", ""],
        "an unborn source must add neither `import git refs` nor `import git head`"
    );
}

/// Undo granularity is the whole point of splitting the operations: one `undo` must revert
/// the HEAD import alone, leaving the imported bookmarks in place.
#[test]
fn undo_after_convert_import_reverts_only_the_head_import() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());
    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    let mut repo = convert_import(src.path(), &dst).result.expect("convert_import");
    let head_ids = wc_parent_ids(&dst);
    let [head] = head_ids.as_slice() else {
        panic!("expected `@` on exactly one imported HEAD commit; got: {head_ids:?}");
    };
    let descendants = format!("descendants({0}) ~ {0}", head.hex());
    assert_eq!(
        zanshin_jj::resolve_revset(&repo, &descendants)
            .expect("resolve revset")
            .len(),
        1,
        "after the head import `@` sits on top of the imported HEAD"
    );

    repo.undo(false).expect("undo must succeed");

    let bookmarks = repo.list_bookmarks().expect("list_bookmarks");
    assert!(
        bookmarks.iter().any(|b| b.name == "main"),
        "undo must revert only the head import — the bookmark the refs operation imported \
         survives; got: {bookmarks:?}"
    );
    assert_eq!(
        zanshin_jj::resolve_revset(&repo, &descendants)
            .expect("resolve revset")
            .len(),
        0,
        "…while the working-copy commit reverts to the one that existed before the head import"
    );
}

#[test]
fn convert_colocated_seeds_the_jj_gitignore() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());

    convert_colocated(tmp.path()).result.expect("convert");

    assert_eq!(
        fs::read_to_string(tmp.path().join(".jj").join(".gitignore")).expect(".jj/.gitignore must exist"),
        "/*\n",
        "the literal the CLI's maybe_add_gitignore writes"
    );
}

#[test]
fn convert_import_writes_no_gitignore() {
    pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());
    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    convert_import(src.path(), &dst).result.expect("convert_import");

    assert!(
        !dst.join(".jj").join(".gitignore").exists(),
        ".jj/.gitignore is colocated-only — a jj-native workspace has no git to hide it from"
    );
}

#[test]
fn a_symbolic_origin_head_sets_the_repo_level_trunk_alias() {
    let xdg = pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());
    let parent = TempDir::new().expect("tempdir parent");
    let work = git_clone(src.path(), parent.path());

    let repo = convert_colocated(&work).result.expect("convert");

    let path = repo_config_path(&work, xdg).expect("a config-id must have been written");
    assert_eq!(
        fs::read_to_string(&path).expect("the repo config must exist"),
        format!("{FRESH_FILE_HEADER}[revset-aliases]\n\"trunk()\" = \"main@origin\"\n"),
        "the alias the CLI's write_repo_presets emits, and nothing else"
    );
    // …and it is the alias the repo's own config stack then resolves.
    assert_eq!(
        zanshin_jj::resolve_revset(&repo, "trunk()")
            .expect("trunk() must resolve")
            .len(),
        1,
        "the written alias must name a bookmark the repo actually has"
    );
}

/// The alias step is part of the NON-colocated shape too — step 4 of `import_into`, ahead of
/// its own head import — and it writes into the DESTINATION's config, not the source's.
///
/// The only row that covers `import_into`'s own `maybe_set_trunk_alias` call: every other
/// alias row drives `convert_colocated`, and every other `convert_import` row builds a source
/// with no `refs/remotes/*/HEAD`, so without this one that call could be deleted outright and
/// the suite would stay green.
#[test]
fn convert_import_sets_the_trunk_alias_on_the_destination() {
    let xdg = pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());
    let parent = TempDir::new().expect("tempdir parent");
    // A clone is what gives the SOURCE its symbolic `refs/remotes/origin/HEAD`; the alias
    // step reads it through the store the destination shares with it.
    let work = git_clone(src.path(), parent.path());
    let dst_parent = TempDir::new().expect("tempdir dst");
    let dst = dst_parent.path().join("workspace");

    convert_import(&work, &dst).result.expect("convert_import");

    let path = repo_config_path(&dst, xdg).expect("the destination must have its own config-id");
    assert_eq!(
        fs::read_to_string(&path).expect("the repo config must exist"),
        format!("{FRESH_FILE_HEADER}[revset-aliases]\n\"trunk()\" = \"main@origin\"\n"),
        "the non-colocated shape writes the same alias the colocated one does"
    );
}

#[test]
fn upstream_head_wins_over_origin_head() {
    let xdg = pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());
    let parent = TempDir::new().expect("tempdir parent");
    let work = git_clone(src.path(), parent.path());
    // A real remote-tracking ref for `upstream`, then the symbolic HEAD on top of it.
    git(&["remote", "add", "upstream", &src.path().to_string_lossy()], &work);
    git(&["fetch", "upstream"], &work);
    git(
        &[
            "symbolic-ref",
            "refs/remotes/upstream/HEAD",
            "refs/remotes/upstream/main",
        ],
        &work,
    );

    convert_colocated(&work).result.expect("convert");

    let path = repo_config_path(&work, xdg).expect("a config-id must have been written");
    assert_eq!(
        fs::read_to_string(&path).expect("the repo config must exist"),
        format!("{FRESH_FILE_HEADER}[revset-aliases]\n\"trunk()\" = \"main@upstream\"\n"),
        "`upstream` is tried first, so `origin` must not be consulted"
    );
}

/// A remote whose `HEAD` is a DIRECT ref has no symbolic target, so no alias is written —
/// and the loop stops there rather than falling through to `origin`, which does have one.
#[test]
fn an_unparseable_upstream_head_writes_no_alias_and_stops_the_loop() {
    let xdg = pin_env();
    let src = TempDir::new().expect("tempdir src");
    init_git_repo_with_commit(src.path());
    let parent = TempDir::new().expect("tempdir parent");
    let work = git_clone(src.path(), parent.path());
    let head_sha = git_stdout(&["rev-parse", "HEAD"], &work);
    git(&["update-ref", "refs/remotes/upstream/HEAD", &head_sha], &work);

    convert_colocated(&work).result.expect("convert");

    assert!(
        repo_config_path(&work, xdg).is_none(),
        "no alias means no config-id and no repo config file — origin/HEAD must not be reached"
    );
}

#[test]
fn a_source_without_any_remote_head_writes_no_alias() {
    let xdg = pin_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());

    convert_colocated(tmp.path()).result.expect("convert");

    assert!(
        repo_config_path(tmp.path(), xdg).is_none(),
        "a plain `git init` has no refs/remotes/*, so nothing may be created"
    );
}
