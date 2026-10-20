// SPDX-License-Identifier: MIT

use std::fs;

use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_jj::{Backend, Repo, RepoError};

// ── AC-19/AC-6: open happy-path ──────────────────────────────────────────────

#[test]
fn repo_open_tiny_fixture_returns_ok() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let result = Repo::open(&fixture.path);
    assert!(result.is_ok(), "expected Ok, got: {result:?}");
}

#[test]
fn repo_open_medium_fixture_returns_ok() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("medium-1k-commits").expect("fixture must extract");
    let result = Repo::open(&fixture.path);
    assert!(result.is_ok(), "expected Ok, got: {result:?}");
}

// ── AC-21: relocatable load ───────────────────────────────────────────────────

#[test]
fn repo_open_from_relocated_path_returns_ok() {
    test_helpers::pin_test_env();
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
    test_helpers::pin_test_env();
    let result = Repo::open(std::path::Path::new("/nonexistent/zanshin-test-abc123"));
    assert!(
        matches!(result, Err(RepoError::PathNotFound { .. })),
        "expected PathNotFound, got: {result:?}"
    );
}

/// `init` resolves its target before handing it to jj-lib (so the workspace store records a path
/// that resolves), which means a missing target is refused BEFORE the init instead of inside it.
/// The variant is unchanged — every init-step failure still travels as `InitFailed`.
///
/// The assertion matches the `"<path>: "` PREFIX our own `map_err` emits, not merely the path
/// somewhere in the string: jj-lib's `create_jj_dir` failure also names the path (`"Cannot access
/// <path>/.jj"`, `file_util.rs:40-45`), so a `contains` check would pass either way and would not
/// observe that the refusal moved ahead of the init.
#[test]
fn repo_init_with_nonexistent_path_returns_init_failed() {
    test_helpers::pin_test_env();
    let missing = std::path::Path::new("/nonexistent/zanshin-test-abc123");
    let result = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(missing),
        ..Default::default()
    })
    .result;
    match result {
        Err(RepoError::InitFailed { reason }) => assert!(
            reason.starts_with("/nonexistent/zanshin-test-abc123: "),
            "the reason must LEAD with the unresolvable path, got: {reason}"
        ),
        other => panic!("expected InitFailed, got: {other:?}"),
    }
}

/// `clone` creates a missing destination with its parents (`clone.rs:195` @ v0.46.0; Story 9.20),
/// so only a destination that cannot be created is refused — as the CLI's "Failed to create
/// <destination>", still `CloneFailed`.
#[test]
fn repo_clone_into_an_uncreatable_destination_returns_clone_failed() {
    test_helpers::pin_test_env();
    let missing = std::path::Path::new("/nonexistent/zanshin-test-abc123");
    let result = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from("file:///nowhere"),
            destination: std::path::PathBuf::from(missing),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result;
    match result {
        Err(RepoError::CloneFailed { reason }) => assert!(
            reason.starts_with("Failed to create /nonexistent/zanshin-test-abc123: "),
            "the reason must be the CLI's, naming the destination, got: {reason}"
        ),
        other => panic!("expected CloneFailed, got: {other:?}"),
    }
}

/// `open` canonicalizes before handing the path to jj-lib, but the REFUSAL must still quote the
/// caller. A macOS `TempDir` is the only refusal input where the two spellings differ
/// (`/var/folders/…` vs `/private/var/folders/…`), so this is where that boundary is observable.
#[test]
fn repo_open_with_non_jj_directory_returns_not_a_repo() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let result = Repo::open(tmp.path());
    match result {
        Err(RepoError::NotARepo { path }) => assert_eq!(
            path,
            tmp.path(),
            "the refusal must carry the caller's spelling, not the canonicalized one"
        ),
        other => panic!("expected NotARepo, got: {other:?}"),
    }
}

// ── AC-5/AC-19: corrupt repo — no panic ───────────────────────────────────────

#[test]
fn repo_open_with_corrupt_op_heads_returns_err_no_panic() {
    test_helpers::pin_test_env();
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
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init git backend");
    let result = Repo::open(tmp.path());
    assert!(result.is_ok(), "open after git-backend init failed: {result:?}");
}

#[test]
fn repo_init_with_native_backend_then_open_returns_ok() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .expect("init native backend");
    let result = Repo::open(tmp.path());
    assert!(result.is_ok(), "open after native-backend init failed: {result:?}");
}

// ── AC-22: @-on-root — do NOT assert @ == tip ────────────────────────────────
// (covered implicitly by repo_open_tiny_fixture_returns_ok — we never assert
//  on the working-copy commit identity, just that load succeeds)

// ── AC-13: clone error path (mandatory, no network) ──────────────────────────

/// An unknown URL scheme parses for gix (`add git remote` succeeds) and fails in the fetch's `git`
/// subprocess ("remote helper 'not-a-real-url' aborted session"), so it is a network error
/// (Story 9.20 closing run — observed, not assumed).
#[test]
fn repo_clone_with_unknown_url_scheme_returns_network_error() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let result = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from("not-a-real-url://nope"),
            destination: std::path::PathBuf::from(tmp.path()),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result;
    assert!(
        matches!(result, Err(RepoError::NetworkError { ref reason }) if reason.contains("not-a-real-url")),
        "expected NetworkError for an unknown URL scheme, got: {result:?}"
    );
}

#[test]
fn repo_clone_network_failure_leaves_no_partial_workspace() {
    test_helpers::pin_test_env();
    let target_tmp = TempDir::new().expect("target tempdir");
    let result = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from("not-a-real-url://nope"),
            destination: std::path::PathBuf::from(target_tmp.path()),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result;
    assert!(
        matches!(result, Err(RepoError::NetworkError { .. })),
        "expected NetworkError, got {result:?}"
    );
    // D1: a failed clone must roll back the partial `.jj/` it created, so a retry
    // into the same directory starts clean.
    assert!(
        !target_tmp.path().join(".jj").exists(),
        "failed clone left a partial .jj/ workspace behind"
    );
}

/// A clone into a directory that already holds a jj workspace is refused as a non-empty
/// destination before anything is created (Story 9.20, `clone.rs:187-192` @ v0.46.0) and must
/// leave that workspace alone (the data loss first surfaced by Story 3.4a). A sentinel inside the
/// existing `.jj/` proves it is the SAME directory afterwards, not a recreated one.
#[test]
fn a_clone_into_an_existing_jj_workspace_fails_and_keeps_it() {
    test_helpers::pin_test_env();
    let target_tmp = TempDir::new().expect("target tempdir");
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(target_tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("an existing jj workspace");
    let sentinel = target_tmp.path().join(".jj").join("sentinel");
    fs::write(&sentinel, "keep me").expect("write the sentinel");

    let outcome = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from("not-a-real-url://nope"),
            destination: std::path::PathBuf::from(target_tmp.path()),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    );

    assert!(
        matches!(&outcome.result, Err(RepoError::DestinationNotEmpty { .. })),
        "the clone must refuse the existing workspace: {:?}",
        outcome.result
    );
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
    assert_eq!(
        fs::read_to_string(&sentinel).expect("the existing .jj/ is untouched"),
        "keep me"
    );
    Repo::open(target_tmp.path()).expect("the existing workspace survives the failed clone");
}

/// A dangling `.jj` symlink is someone else's too: the destination is not empty, so the clone is
/// refused before anything is created and leaves the link (Story 9.20).
#[test]
fn a_clone_over_a_dangling_jj_symlink_fails_and_keeps_the_link() {
    test_helpers::pin_test_env();
    let target_tmp = TempDir::new().expect("target tempdir");
    let link = target_tmp.path().join(".jj");
    std::os::unix::fs::symlink(target_tmp.path().join("nowhere"), &link).expect("create the dangling link");

    let outcome = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from("not-a-real-url://nope"),
            destination: std::path::PathBuf::from(target_tmp.path()),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    );

    assert!(
        matches!(&outcome.result, Err(RepoError::DestinationNotEmpty { .. })),
        "the clone must refuse the existing link: {:?}",
        outcome.result
    );
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
    assert!(
        link.symlink_metadata().is_ok_and(|m| m.file_type().is_symlink()),
        "the dangling link is untouched"
    );
}

// ── AC-12: clone happy-path (file:// local git, no network) ──────────────────

#[test]
fn repo_clone_from_local_git_source_returns_ok() {
    test_helpers::pin_test_env();

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
    let result = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from(&src_url),
            destination: std::path::PathBuf::from(target_tmp.path()),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result;
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

// ── a cloned workspace must resolve its OWN root, symlinked caller path or not ─

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
fn assert_own_root_resolves(repo: &mut Repo, expected: &std::path::Path) {
    let entries = repo.list_workspaces().expect("list_workspaces");
    assert_eq!(
        entries.len(),
        1,
        "a freshly cloned repo has exactly the default workspace; got {entries:?}"
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

/// The workspace-store round trip for the CLONE seam.
///
/// `clone_into` reaches the same jj-lib `init_with_factories` that `Repo::init` does, so a target
/// path still containing a symlink (on macOS every `/var/folders/…` temp dir points at
/// `/private/var/folders/…`) records a workspace root RELATIVE to a spelling no read ever joins
/// onto — and the clone's own row goes absent while `root --name default` refuses. Nothing else in
/// this file observes the store: file layout, git refs and `Repo::open` all succeed either way, so
/// without this test reverting `Repo::clone`'s canonicalize leaves the suite green.
#[test]
fn a_repo_cloned_through_a_symlinked_path_resolves_its_own_root() {
    test_helpers::pin_test_env();

    let src_tmp = TempDir::new().expect("src tempdir");
    git(&["init", "--initial-branch=main"], src_tmp.path());
    git(&["config", "user.email", "test@zanshin.test"], src_tmp.path());
    git(&["config", "user.name", "Fixture"], src_tmp.path());
    fs::write(src_tmp.path().join("README.md"), "hello").expect("write README");
    git(&["add", "."], src_tmp.path());
    git(&["commit", "-m", "initial"], src_tmp.path());

    let target_tmp = TempDir::new().expect("target tempdir");
    assert_ne!(
        fs::canonicalize(target_tmp.path()).expect("temp dir exists").as_path(),
        target_tmp.path(),
        "this witness needs a temp path that really does go through a symlink; on macOS both \
         /tmp and /var/folders are symlinks, so a TMPDIR pointing at a real directory \
         disables it"
    );

    let src_url = format!("file://{}", src_tmp.path().display());
    let mut cloned = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from(&src_url),
            destination: std::path::PathBuf::from(target_tmp.path()),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result
    .expect("clone from local file://");

    assert_own_root_resolves(&mut cloned, target_tmp.path());
}

// ── AC-20: 100× open/drop loop — no fd leak ──────────────────────────────────

#[test]
fn repo_open_drop_loop_100_times_no_panic() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    for _ in 0..100 {
        let _repo = Repo::open(&fixture.path).expect("open in loop");
        // _repo is dropped here; 100 iterations verify no fd leak.
    }
}

// ── AC-1: workspace_root accessor ────────────────────────────────────────────

#[test]
fn repo_workspace_root_matches_open_path() {
    test_helpers::pin_test_env();
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
