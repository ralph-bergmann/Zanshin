// SPDX-License-Identifier: MIT

//! Fixture tests for Story 9.7's two workspace READ verbs — `Repo::list_workspaces` and
//! `Repo::resolve_workspace_root`.
//!
//! The committed `tiny-3-commits` fixture is a free witness for the interesting rows: its
//! `.jj/repo/workspace_store/index` records `default` → the GENERATOR's temp directory, which no
//! longer exists after extraction. So the fixture as shipped already exercises jj 0.46's handling
//! of an unreachable recorded path — `list` reports it, `resolve_root(Some("default"))` returns it
//! with a `jj.workspace_path_inaccessible` warning. Regenerating the fixture to "fix" that
//! staleness is forbidden AND would destroy the witness.
//!
//! Every path comparison canonicalizes BOTH sides: on macOS the system temp dir is
//! `/var/folders/…`, a symlink to `/private/var/folders/…`, and only one side of a naive
//! comparison goes through it (`tests/it/repo.rs:211-214` pins the same trap).

use std::fs;
use std::path::{Path, PathBuf};

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::{add_workspace, extract_fixture};
use zanshin_jj::{Repo, Warning, WarningKind, WorkspaceError};

/// Opens the fixture as a raw jj-lib `Workspace` for oracle reads.
fn oracle_workspace(root: &Path) -> Workspace {
    test_helpers::load_workspace(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load")
}

/// The `(workspace name, wc commit hex)` pairs jj-lib's `View::wc_commit_ids()` holds — the raw
/// oracle for the VIEW half, so a re-derivation instead of a reuse would show up here.
fn wc_pairs(workspace_root: &Path) -> Vec<(String, String)> {
    let workspace = oracle_workspace(workspace_root);
    let repo = pollster::block_on(workspace.load_at_head()).unwrap();
    repo.view()
        .wc_commit_ids()
        .iter()
        .map(|(name, id)| (name.as_str().to_owned(), id.hex()))
        .collect()
}

/// The name/commit half of a `list_workspaces` result, in the same shape as [`wc_pairs`].
fn entry_pairs(entries: &[zanshin_jj::WorkspaceEntry]) -> Vec<(String, String)> {
    entries
        .iter()
        .map(|e| (e.name.clone(), e.wc_commit_id.0.clone()))
        .collect()
}

/// The `.jj/repo/workspace_store` directory of the workspace rooted at `workspace_root`.
fn store_dir(workspace_root: &Path) -> PathBuf {
    workspace_root.join(".jj").join("repo").join("workspace_store")
}

/// Removes the whole workspace store, so no path is recorded for any workspace. jj-lib's
/// `SimpleWorkspaceStore::load` then RE-CREATES the directory with an empty store — its own
/// legacy-repo path, which writes no operation.
fn remove_workspace_store(workspace_root: &Path) {
    fs::remove_dir_all(store_dir(workspace_root)).expect("the fixture has a workspace store");
}

/// Overwrites the store index with bytes that are not a valid protobuf, so `read_store` fails.
/// A missing or corrupt index is an `Err`, never a `None` — the two states are genuinely
/// different and the two verbs treat them differently.
fn corrupt_workspace_store(workspace_root: &Path) {
    fs::write(store_dir(workspace_root).join("index"), b"not a protobuf at all").expect("index must be writable");
}

/// Makes loading the workspace store ITSELF fail, rather than a later read.
///
/// Loading never reads the index — it only creates what is absent — so a corrupt index exercises
/// `get_workspace_path`, not the load. A DANGLING SYMLINK in the store's place is the one
/// deterministic way to fail the load without touching permissions: nothing can be created
/// through it. Since jj 0.46 that load is part of opening the repo.
fn dangle_workspace_store(workspace_root: &Path) {
    let dir = store_dir(workspace_root);
    fs::remove_dir_all(&dir).expect("the fixture has a workspace store");
    std::os::unix::fs::symlink("nowhere-at-all", &dir).expect("symlink must be creatable");
}

/// Removes `op_heads` so the next head resolution fails — the `Backend` driver for the VIEW half.
fn corrupt_op_heads(workspace_root: &Path) {
    fs::remove_dir_all(workspace_root.join(".jj").join("repo").join("op_heads")).unwrap();
}

/// The head operation's id, so a test can assert that a READ wrote nothing.
fn head_op_id(repo: &mut Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).id.0
}

/// Canonicalizes both sides before comparing — the macOS `/var` → `/private/var` trap.
fn assert_same_dir(actual: &Path, expected: &Path) {
    assert_eq!(
        fs::canonicalize(actual).expect("actual path must exist"),
        fs::canonicalize(expected).expect("expected path must exist"),
        "paths must match once both sides are canonicalized"
    );
}

// ── list: the view half is reused, the path half is added ────────────────────

/// The shipped fixture records a path that no longer exists. jj 0.46 lists the recorded path
/// as-is (no canonicalization), so the row still carries a `root` — one that does not exist — and
/// the call SUCCEEDS.
#[test]
fn list_on_the_fixture_reports_the_stale_recorded_root() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&mut repo);

    let entries = repo.list_workspaces().unwrap();

    assert_eq!(entries.len(), 1, "the fixture has one workspace; got {entries:?}");
    assert_eq!(entries[0].name, "default");
    assert_eq!(
        entry_pairs(&entries),
        wc_pairs(&fx.path),
        "the name/commit half must equal View::wc_commit_ids() entry for entry"
    );
    let root = entries[0].root.as_ref().expect("the fixture records a path");
    assert!(
        !root.exists(),
        "the fixture records the GENERATOR's temp dir, which no longer exists; got {root:?}"
    );
    assert_eq!(head_op_id(&mut repo), before, "a read must not write an operation");
}

/// Added workspaces record paths that DO exist, so both kinds of row are exercised at once:
/// `default` still reports its stale recorded path while the added ones report their real
/// directories.
///
/// The added names are chosen so the ordering assertion has teeth: `aaa` is created LAST but must
/// come FIRST, which only jj-lib's lexicographic `BTreeMap` order satisfies — creation order and
/// insertion order would both put it at the end.
#[test]
fn list_with_more_workspaces_reports_resolvable_roots_in_lexicographic_order() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    // The handles keep the added workspaces' directories alive for the duration of the test.
    let (second, second_wc) = add_workspace(&fx.path, "second");
    let (aaa, _aaa_wc) = add_workspace(&fx.path, "aaa");

    let mut repo = Repo::open(&fx.path).unwrap();
    let entries = repo.list_workspaces().unwrap();

    assert_eq!(entries.len(), 3, "default + second + aaa; got {entries:?}");
    let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(
        names,
        ["aaa", "default", "second"],
        "rows keep jj-lib's lexicographic BTreeMap order — `aaa` was added LAST"
    );
    assert_eq!(
        entry_pairs(&entries),
        wc_pairs(&fx.path),
        "the name/commit half must equal View::wc_commit_ids() entry for entry"
    );
    assert_eq!(entries[2].wc_commit_id.0, second_wc);

    assert!(
        !entries[1].root.as_ref().expect("default records a path").exists(),
        "default's recorded path is still stale"
    );
    assert_same_dir(entries[0].root.as_ref().expect("aaa's path resolves"), &aaa.path);
    assert_same_dir(entries[2].root.as_ref().expect("second's path resolves"), &second.path);
}

/// No recorded path at all: the store directory is gone, jj-lib recreates it empty, and every row
/// degrades. Still `ok`.
#[test]
fn list_with_no_recorded_path_still_returns_the_row() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    remove_workspace_store(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&mut repo);

    let entries = repo.list_workspaces().unwrap();

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].name, "default");
    assert_eq!(entries[0].root, None);
    assert!(
        store_dir(&fx.path).is_dir(),
        "SimpleWorkspaceStore::load recreates the store dir for a legacy repo"
    );
    assert_eq!(
        head_op_id(&mut repo),
        before,
        "recreating the store writes no OPERATION, only files"
    );
}

/// An unreadable store is a path failure like any other: the listing still succeeds. This is the
/// one row where `list` is strictly more forgiving than the CLI's per-row template, which would
/// propagate the store-read error — the widening is deliberate, so a corrupt store cannot make a
/// GUI unable to enumerate its workspaces at all.
#[test]
fn list_with_an_unreadable_store_still_returns_the_rows() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    corrupt_workspace_store(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let entries = repo.list_workspaces().unwrap();

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].root, None, "a path failure NEVER fails the listing");
    assert_eq!(entry_pairs(&entries), wc_pairs(&fx.path));
}

/// The only failure `list` can report is the VIEW half's.
#[test]
fn list_on_a_corrupt_repo_returns_a_backend_error() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();
    let mut repo = Repo::open(tmp.path()).unwrap();

    corrupt_op_heads(tmp.path());

    let result = repo.list_workspaces();
    assert!(
        matches!(result, Err(WorkspaceError::Precondition(zanshin_jj::PreconditionError::Backend(_)))),
        "the pre-verb snapshot fails first (Story 9.26, as the CLI would): corrupt op_heads must yield WorkspaceError::Backend, got: {result:?}"
    );
}

// ── root: the strict half ────────────────────────────────────────────────────

/// `None`, after the command start-up, reads the loader alone: on a clean stack it returns the
/// open workspace's own root and warns nothing — not even on the fixture, whose recorded path is
/// stale.
#[test]
fn root_without_a_name_is_the_open_workspace() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&mut repo);

    let root = repo.resolve_workspace_root(None).unwrap();
    let warnings = repo.take_warnings();

    assert!(warnings.is_empty(), "a clean stack and the loader root warn nothing");
    assert_same_dir(&root, repo.workspace_root());
    assert_same_dir(&root, &fx.path);
    // The no-name root is ABSOLUTE and canonical (a NAMED root is the store's recorded path,
    // not canonicalized since jj 0.46). Every other assertion here canonicalizes both sides, so
    // it would pass on a non-canonical one; this is the only place the guarantee itself is
    // checked. WHY it holds, twice over: the no-name path returns `Workspace::workspace_root()`
    // verbatim, which jj-lib canonicalized in `Workspace::new` (`jj-lib-0.46.0/src/workspace.rs:171`,
    // `dunce::canonicalize`), and `Repo::open` canonicalizes its own argument before handing it to
    // the workspace loader, as the CLI does. `resolve_root` itself does no path work at all on
    // this branch.
    assert_eq!(
        root,
        fs::canonicalize(&root).unwrap(),
        "the returned root must already be canonical"
    );
    assert_eq!(head_op_id(&mut repo), before, "a read must not write an operation");
}

/// The whole point of the verb, from the OTHER side: a secondary workspace resolves its siblings.
///
/// In a secondary workspace `.jj/repo` is a FILE pointing at the shared repo, and every store
/// lookup here works only because `Workspace::repo_path()` follows that indirection. Deriving the
/// join base locally (`workspace_root().join(".jj").join("repo")`) would leave every other test in
/// this file green while every root went absent from this side.
#[test]
fn secondary_workspace_sees_the_shared_store_through_the_repo_file() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (second, second_wc) = add_workspace(&fx.path, "second");
    assert!(
        second.path.join(".jj").join("repo").is_file(),
        "a secondary workspace's .jj/repo is a FILE pointing at the shared repo"
    );

    // Opened at the SECONDARY workspace, not the fixture root.
    let mut repo = Repo::open(&second.path).unwrap();

    // (a) the listing reaches the shared store and both rows come back.
    let entries = repo.list_workspaces().unwrap();
    assert_eq!(
        entries.len(),
        2,
        "the shared view holds both workspaces; got {entries:?}"
    );
    assert_eq!(entry_pairs(&entries), wc_pairs(&second.path));
    assert_eq!(entries[1].name, "second");
    assert_eq!(entries[1].wc_commit_id.0, second_wc);
    assert_same_dir(
        entries[1].root.as_ref().expect("second's own path resolves"),
        &second.path,
    );

    // (b) the no-name default is THIS workspace's root, not the primary's.
    let own = repo.resolve_workspace_root(None).unwrap();
    assert_same_dir(&own, &second.path);
    assert_ne!(
        fs::canonicalize(&own).unwrap(),
        fs::canonicalize(&fx.path).unwrap(),
        "the current workspace is the secondary one"
    );

    // (c) naming the PRIMARY reaches the shared store — and hits the fixture's stale entry, the
    // same warning the primary side reports for itself.
    let named = repo.resolve_workspace_root(Some("default")).unwrap();
    assert_eq!(
        named,
        entries[0].root.clone().expect("default records a path"),
        "root and list report the same recorded path"
    );
    assert_inaccessible_warning(&named, &repo.take_warnings());
}

/// A SIBLING workspace's path is visible from this one — the whole point of the verb.
#[test]
fn root_with_a_name_finds_a_sibling_workspace() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (second, _wc) = add_workspace(&fx.path, "second");
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&mut repo);

    let root = repo.resolve_workspace_root(Some("second")).unwrap();

    assert!(repo.take_warnings().is_empty(), "second's directory exists");
    assert_same_dir(&root, &second.path);
    assert_eq!(head_op_id(&mut repo), before, "a read must not write an operation");
}

/// The CLI's asymmetry, in one test: `None` answers the open workspace's root on the very repo where
/// naming the SAME workspace goes through the store — which here holds the generator's stale temp
/// dir. Since jj 0.46 the CLI reports that path anyway, with a warning, instead of refusing
/// (`cli/src/commands/workspace/root.rs:60-66` @ v0.46.0).
#[test]
fn root_named_current_workspace_warns_where_the_default_path_does_not() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&mut repo);

    let default = repo.resolve_workspace_root(None).unwrap();
    assert!(repo.take_warnings().is_empty());

    let named = repo.resolve_workspace_root(Some("default")).unwrap();
    assert_ne!(named, default, "the store holds the generator's path");
    assert!(!named.exists());
    assert_inaccessible_warning(&named, &repo.take_warnings());
    assert_eq!(head_op_id(&mut repo), before, "a read must not write an operation");
}

/// A named root whose directory is gone carries exactly the CLI's warning, path included.
fn assert_inaccessible_warning(named: &Path, warnings: &[Warning]) {
    assert_eq!(warnings.len(), 1, "got {warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::WorkspacePathInaccessible);
    assert_eq!(
        warnings[0].message,
        format!("Cannot access workspace path: {}", named.display())
    );
}

/// An unknown name, and an explicitly EMPTY one — an empty string is a VALUE, not an absence, and
/// no workspace is named `""`.
#[test]
fn root_with_an_unknown_or_empty_name_is_not_found() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = head_op_id(&mut repo);

    for name in ["nosuch", ""] {
        let result = repo.resolve_workspace_root(Some(name));
        match result {
            Err(WorkspaceError::NotFound { name: reported }) => assert_eq!(reported, name),
            other => panic!("{name:?} must be NotFound, got: {other:?}"),
        }
    }
    assert_eq!(
        head_op_id(&mut repo),
        before,
        "a REFUSAL must not write an operation either"
    );
}

/// The workspace exists but the store holds no path for it — the pre-jj-0.38.0 state. Unlike a
/// stale path, which is reported with a warning, there is no path to report, so it refuses.
#[test]
fn root_with_no_recorded_path_refuses_distinctly() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    remove_workspace_store(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.resolve_workspace_root(Some("default"));
    match result {
        Err(WorkspaceError::NoRecordedPath { name }) => assert_eq!(name, "default"),
        other => panic!("an absent store entry must be NoRecordedPath, got: {other:?}"),
    }
}

/// An unreadable store is an `Err` from jj-lib, never an "absent entry" — so it must NOT collapse
/// into `NoRecordedPath`.
#[test]
fn root_with_an_unreadable_store_is_a_backend_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    corrupt_workspace_store(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.resolve_workspace_root(Some("default"));
    assert!(
        matches!(result, Err(WorkspaceError::Backend(_))),
        "a corrupt store index must be Backend, not NoRecordedPath, got: {result:?}"
    );
}

/// A store that cannot be LOADED refuses the OPEN itself: since jj 0.46 jj-lib loads the
/// workspace store with the repo (`RepoLoader::workspace_store`), exactly as the CLI's start-up
/// does, so neither verb is ever reached — there is no store load of its own left in them.
#[test]
fn an_unloadable_store_refuses_the_open() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    dangle_workspace_store(&fx.path);

    let result = Repo::open(&fx.path);
    assert!(
        result.is_err(),
        "a store that cannot be loaded must refuse the open, got: {:?}",
        result.map(|_| ())
    );
}

/// A store that cannot be LOADED any more under an open handle is still just a path failure for
/// `list`: the per-call load (the CLI's per-command one) fails, and every row degrades. Line
/// coverage cannot tell this from the corrupt-index case — the `.ok()` executes either way — so
/// without this the branch ships unpinned.
#[test]
fn list_with_an_unloadable_store_still_returns_the_rows() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    // Read BEFORE the store breaks: the oracle opens the workspace itself, and that open now
    // loads the store too.
    let expected = wc_pairs(&fx.path);
    dangle_workspace_store(&fx.path);

    let entries = repo.list_workspaces().unwrap();

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].root, None, "a failed store LOAD never fails the listing");
    assert_eq!(entry_pairs(&entries), expected);
}

/// A store that cannot be LOADED is the FIRST stage of the named path, and it maps to `Backend`
/// — the same code as an unreadable index, but reached through a different jj-lib call.
#[test]
fn root_with_an_unloadable_store_is_a_backend_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    dangle_workspace_store(&fx.path);

    let result = repo.resolve_workspace_root(Some("default"));
    assert!(
        matches!(result, Err(WorkspaceError::Backend(_))),
        "a store that cannot be loaded must be Backend, got: {result:?}"
    );
    // The loader-only path never touches the store, so it is unaffected.
    assert!(repo.resolve_workspace_root(None).is_ok());
}

/// A store DELETED under an open handle is recreated EMPTY by the next call's load — exactly as
/// by the next CLI command, which loads the store at start-up — so the named path refuses with
/// `NoRecordedPath`, never with a read error of a store the handle captured when it was opened.
#[test]
fn a_store_wiped_under_an_open_handle_is_recreated_like_the_next_cli_command() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    remove_workspace_store(&fx.path);

    match repo.resolve_workspace_root(Some("default")) {
        Err(WorkspaceError::NoRecordedPath { name }) => assert_eq!(name, "default"),
        other => panic!("a wiped store must read as NoRecordedPath, got: {other:?}"),
    }
    assert!(store_dir(&fx.path).is_dir(), "the load recreated the store");
}

/// The membership check runs against the head view, so a repo whose head cannot be resolved
/// refuses before it ever reaches the store lookup.
#[test]
fn root_with_a_name_on_a_corrupt_repo_is_a_backend_error() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();
    let mut repo = Repo::open(tmp.path()).unwrap();

    corrupt_op_heads(tmp.path());

    let result = repo.resolve_workspace_root(Some("default"));
    assert!(
        matches!(result, Err(WorkspaceError::Backend(_))),
        "an unresolvable head must yield Backend, got: {result:?}"
    );
    // The no-name path reads the loader alone, so it is unaffected by a broken op-heads dir.
    assert!(
        repo.resolve_workspace_root(None).is_ok(),
        "the bare form reads no head: a broken op-heads dir does not reach it"
    );
}

// ── a workspace must resolve its OWN root, symlinked caller path or not ──────

/// Both verbs report `expected` for the single `default` workspace of `repo`.
fn assert_own_root_resolves(repo: &mut Repo, expected: &Path) {
    let entries = repo.list_workspaces().unwrap();
    assert_eq!(
        entries.len(),
        1,
        "a fresh repo has exactly the default workspace; got {entries:?}"
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
    assert!(repo.take_warnings().is_empty(), "the recorded directory exists");
    assert_same_dir(&named, expected);
    assert_eq!(
        named,
        repo.resolve_workspace_root(None).unwrap(),
        "naming the current workspace must agree with the no-name default"
    );
}

/// A repo created through a path that CONTAINS a symlink still resolves its own root.
///
/// On macOS every `TempDir` is `/var/folders/…`, a symlink to `/private/var/folders/…`, which is
/// exactly the shape a caller-supplied path can have. `SimpleWorkspaceStore::add` records a
/// workspace's root RELATIVE to the `repo_path` the store was loaded with, and since jj 0.46 every
/// read joins it back LEXICALLY (`simple_workspace_store.rs:236-238` @ 0.46.0) — so the recorded
/// path has to name the workspace's own directory, raw or canonical, or the OWN row and
/// `root --name default` report a path that is not this workspace.
///
/// What this pins is the WRITE seam — `Repo::init`. The second half re-opens the same repo, which
/// asserts that `Repo::open` did not break what `init` recorded.
#[test]
fn a_repo_created_through_a_symlinked_path_resolves_its_own_root() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    let canonical = fs::canonicalize(tmp.path()).unwrap();
    assert_ne!(
        canonical.as_path(),
        tmp.path(),
        "this witness needs a temp path that really does go through a symlink; on macOS both \
         /tmp and /var/folders are symlinks, so a TMPDIR pointing at a real directory \
         disables it"
    );

    let mut created = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();
    assert_own_root_resolves(&mut created, tmp.path());

    let mut reopened = Repo::open(tmp.path()).unwrap();
    assert_own_root_resolves(&mut reopened, tmp.path());
}

// ── root: the CLI's command start-up ─────────────────────────────────────────

/// The "Deprecated … config" warning of a user config holding the one key the CLI migrates.
const DEPRECATED: &str = "Deprecated user-level config: fix.tools.t.line-range-arg is updated to \
                          fix.tools.t.line-range-args = [\"--l\"]";

/// `(kind, message)` of each warning the last call left, in order.
fn taken(repo: &mut Repo) -> Vec<(WarningKind, String)> {
    repo.take_warnings().into_iter().map(|w| (w.kind, w.message)).collect()
}

/// Both forms of `jj workspace root` run the CLI's command start-up (`run_internal`), so a
/// deprecated user key warns on each — first, and kept on a refusal — and the named form's own
/// warning comes after it. No snapshot ran, so no precondition report is left behind.
#[test]
fn both_forms_of_root_warn_the_start_up_deprecations() {
    test_helpers::own_process!("both_forms_of_root_warn_the_start_up_deprecations");
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (second, _wc) = add_workspace(&fx.path, "second");
    let mut repo = Repo::open(&fx.path).unwrap();
    let user = TempDir::new().unwrap();
    let user_file = user.path().join("user.toml");
    fs::write(&user_file, "fix.tools.t.line-range-arg = \"--l\"\n").unwrap();
    // SAFETY: this test runs alone in its own process (`own_process!`).
    unsafe { std::env::set_var("JJ_CONFIG", &user_file) };
    let deprecated = (WarningKind::ConfigDeprecated, DEPRECATED.to_owned());
    let before = head_op_id(&mut repo);

    let bare = repo.resolve_workspace_root(None).unwrap();
    assert_eq!(bare, repo.workspace_root());
    assert_eq!(taken(&mut repo), std::slice::from_ref(&deprecated));
    assert!(repo.take_precondition().is_none(), "no snapshot ran");

    let named = repo.resolve_workspace_root(Some("second")).unwrap();
    assert_same_dir(&named, &second.path);
    assert_eq!(taken(&mut repo), std::slice::from_ref(&deprecated));
    assert!(repo.take_precondition().is_none(), "no snapshot ran");

    // The fixture's own recorded directory is gone: its warning comes last.
    let stale = repo.resolve_workspace_root(Some("default")).unwrap();
    assert_eq!(
        taken(&mut repo),
        [
            deprecated.clone(),
            (
                WarningKind::WorkspacePathInaccessible,
                format!("Cannot access workspace path: {}", stale.display())
            )
        ]
    );

    let refused = repo.resolve_workspace_root(Some("nosuch"));
    assert!(matches!(refused, Err(WorkspaceError::NotFound { .. })), "{refused:?}");
    assert_eq!(
        taken(&mut repo),
        [deprecated],
        "a refusal keeps the start-up's warnings"
    );
    assert!(repo.take_precondition().is_none());
    assert_eq!(head_op_id(&mut repo), before, "a read must not write an operation");
}

/// A config stack that no longer resolves refuses BOTH forms, as every CLI command refuses it at
/// start-up — the bare form included, although it reads nothing but the loader afterwards.
#[test]
fn a_broken_config_stack_refuses_both_forms_of_root() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();
    let mut repo = Repo::open(tmp.path()).unwrap();
    fs::write(
        tmp.path().join(".jj").join("repo").join("config.toml"),
        "[user\nname = ",
    )
    .unwrap();

    for name in [None, Some("default")] {
        let result = repo.resolve_workspace_root(name);
        assert!(
            matches!(
                result,
                Err(WorkspaceError::Precondition(
                    zanshin_jj::PreconditionError::Config { .. }
                ))
            ),
            "{name:?}: {result:?}"
        );
        assert!(repo.take_precondition().is_none(), "{name:?}: no snapshot ran");
    }
}

/// The named form also runs `workspace_helper_no_snapshot`'s start-up environment, so an
/// `immutable_heads()` that does not parse refuses it — the bare form never builds that
/// environment (`root.rs:75` @ v0.46.0) and still answers.
#[test]
fn only_the_named_root_parses_the_start_up_environment() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();
    let mut repo = Repo::open(tmp.path()).unwrap();
    fs::write(
        tmp.path().join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'immutable_heads()' = '('\n",
    )
    .unwrap();

    assert!(repo.resolve_workspace_root(None).is_ok());
    let named = repo.resolve_workspace_root(Some("default"));
    assert!(
        matches!(
            named,
            Err(WorkspaceError::Precondition(
                zanshin_jj::PreconditionError::Config { .. }
            ))
        ),
        "{named:?}"
    );
}
