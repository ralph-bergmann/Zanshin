// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.6's three commit READ views: `Repo::show`, `Repo::evolog`
//! and `Repo::interdiff`.
//!
//! Integration level is right: all three entry points are public `Repo` methods and every row
//! needs a real repo with real trees, a real operation log, or both.
//!
//! The committed fixtures give every commit exactly one plain file (`xtask`'s `gen_fixture.rs`
//! builds each tree from an empty base with only `commit-<n>.txt`) and contain NO rewritten,
//! divergent or multi-parent-with-shared-content commit — and regenerating fixtures is
//! forbidden (it would shift the revset oracles). Every scenario is therefore built on purpose
//! with `test_helpers`; the fixture supplies only the workspace, its `@`, and its op log. The
//! rename row additionally needs a GIT-backed repo and a real working-copy snapshot (the native
//! backend reports no copy records at all), so it is built with `Repo::init` +
//! `snapshot_working_copy`, mirroring `tests/it/status.rs`.
//!
//! Two assertions repeat throughout: the result compared against a RAW jj-lib oracle (never a
//! second call to the code under test), and — for every verb, on both a success and a refusal —
//! that the op-log head is byte-identical afterwards. A read must never write an operation.

use std::fs;
use std::path::Path;
use std::sync::Arc;

use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::gitignore::GitIgnoreFile;
use jj_lib::matchers::EverythingMatcher;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::working_copy::SnapshotOptions;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::{
    add_commit_off_root, add_commit_with_files, add_conflicted_merge_off_root, add_divergent_twin, describe_commit,
    extract_fixture, rewrite_commit_files, FixtureHandle,
};
use zanshin_jj::{Backend, ChangeId, ChangeKind, CommitId, CommitViewError, Repo, RevisionRef};

// ── Harness ───────────────────────────────────────────────────────────────────────

/// The head-resolved jj-lib repo — the oracle these tests read trees and commits from.
fn jj_repo(workspace_root: &Path) -> Arc<ReadonlyRepo> {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head")
}

fn change_id_of(workspace_root: &Path, commit_hex: &str) -> ChangeId {
    let repo = jj_repo(workspace_root);
    let id = JjCommitId::try_from_hex(commit_hex).expect("hex commit id");
    ChangeId(repo.store().get_commit(&id).expect("commit").change_id().reverse_hex())
}

/// Every path in `commit_hex`'s tree, read straight off jj-lib.
fn oracle_paths(workspace_root: &Path, commit_hex: &str) -> Vec<String> {
    let repo = jj_repo(workspace_root);
    let id = JjCommitId::try_from_hex(commit_hex).expect("hex commit id");
    repo.store()
        .get_commit(&id)
        .expect("commit")
        .tree()
        .entries()
        .map(|(path, _)| path.as_internal_file_string().to_owned())
        .collect()
}

/// The head operation's id, so a test can assert that a READ wrote nothing.
fn head_op_id(repo: &mut Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).id.0
}

fn write_repo_config(workspace_root: &Path, toml: &str) {
    fs::write(workspace_root.join(".jj").join("repo").join("config.toml"), toml).expect("repo config must be writable");
}

fn open(fx: &FixtureHandle) -> Repo {
    Repo::open(&fx.path).expect("fixture opens")
}

/// `(path, kind-label)` pairs, so an assertion reads like the CLI's `--summary` output.
fn summary(changes: &[zanshin_jj::FileChange]) -> Vec<(String, &'static str)> {
    changes
        .iter()
        .map(|c| {
            let label = match c.kind {
                ChangeKind::Added => "A",
                ChangeKind::Modified => "M",
                ChangeKind::Removed => "D",
                ChangeKind::Renamed { .. } => "R",
                ChangeKind::Copied { .. } => "C",
            };
            (c.path.to_string_lossy().into_owned(), label)
        })
        .collect()
}

/// `interdiff`'s change-id arm — the house currency, and what every row wrote before the union.
fn chg(id: &ChangeId) -> RevisionRef {
    RevisionRef::ChangeId(id.clone())
}

/// `interdiff`'s commit-id arm — a commit-id HEX prefix, resolved through the index and
/// therefore reaching hidden commits.
fn cmt(hex: &str) -> RevisionRef {
    RevisionRef::CommitId(CommitId(hex.to_owned()))
}

/// Two commits with DIFFERENT parents whose parent trees also differ — the shape that makes
/// `interdiff` observably different from a plain tree diff.
///
/// `from` adds `x.txt` on top of `p1`; `to` adds `x.txt` AND `b.txt` on top of `p2`, which
/// already carries `extra.txt`. A plain diff of the two trees would report `extra.txt` too;
/// `interdiff` factors it out because it belongs to the PARENTS, not to either change.
struct InterdiffPair {
    fx: FixtureHandle,
    from: ChangeId,
    to: ChangeId,
}

fn interdiff_pair() -> InterdiffPair {
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let p1 = add_commit_with_files(&fx.path, &[], &[("a.txt", "alpha\n")], "p1");
    let p2 = add_commit_with_files(&fx.path, &[], &[("a.txt", "alpha\n"), ("extra.txt", "e\n")], "p2");
    let from = add_commit_with_files(&fx.path, &[&p1], &[("a.txt", "alpha\n"), ("x.txt", "x\n")], "from");
    let to = add_commit_with_files(
        &fx.path,
        &[&p2],
        &[
            ("a.txt", "alpha\n"),
            ("extra.txt", "e\n"),
            ("x.txt", "x\n"),
            ("b.txt", "b\n"),
        ],
        "to",
    );
    let from = change_id_of(&fx.path, &from);
    let to = change_id_of(&fx.path, &to);
    InterdiffPair { fx, from, to }
}

/// A git-backed workspace in a fresh `TempDir`.
///
/// Copy records exist ONLY on the git backend — the native `SimpleBackend` yields an empty
/// stream and every rename degrades to an `Added`+`Removed` pair (`status.rs:121-122`) — and no
/// committed fixture is git-backed. Hand-built trees on top of this are the only way to
/// construct a multi-parent rename or a copy, neither of which the snapshot harness below can
/// express.
fn git_workspace() -> TempDir {
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("git-backed init");
    tmp
}

/// Four lines, so gix's 50 % similarity threshold has something to measure. An exact copy of
/// this body scores 100 % against the pre-edit version of the file it was copied from.
const COPY_BODY: &str = "line one\nline two\nline three\nline four\n";

// ── Git-backed working-copy harness (rename detection) ────────────────────────────
//
// The `@`-relative rows additionally need a real snapshot chain rather than a hand-built tree,
// because `@` itself must carry the rename. Both helpers are TEST SETUP ONLY: an out-of-band
// jj-lib snapshot staging `@` independently of the pre-verb snapshot (Story 9.26). Mirrors
// `tests/it/status.rs`.

fn snapshot_working_copy(workspace_root: &Path) {
    let settings = test_helpers::test_settings();
    let mut workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("workspace loads");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load_at_head");
    let workspace_name = workspace.workspace_name().to_owned();

    let wc_id = repo
        .view()
        .get_wc_commit_id(&workspace_name)
        .expect("workspace has a working-copy commit")
        .clone();
    let parents = repo
        .store()
        .get_commit(&wc_id)
        .expect("wc commit")
        .parent_ids()
        .to_vec();

    let mut locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("wc lock");
    let opts = SnapshotOptions {
        base_ignores: GitIgnoreFile::empty(),
        progress: None,
        start_tracking_matcher: &EverythingMatcher,
        force_tracking_matcher: &EverythingMatcher,
        max_new_file_size: u64::MAX,
    };
    let (new_tree, _stats) = pollster::block_on(locked.locked_wc().snapshot(&opts)).expect("snapshot");

    let mut tx = repo.start_transaction();
    let new_commit = pollster::block_on(tx.repo_mut().new_commit(parents, new_tree).write()).expect("write commit");
    tx.repo_mut()
        .set_wc_commit(workspace_name, new_commit.id().clone())
        .expect("set wc commit");
    let new_repo = pollster::block_on(tx.commit("test: snapshot")).expect("commit tx");
    pollster::block_on(locked.finish(new_repo.op_id().clone())).expect("finish wc");
}

fn jj_new(workspace_root: &Path) {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("workspace loads");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load_at_head");
    let workspace_name = workspace.workspace_name().to_owned();

    let wc_id = repo
        .view()
        .get_wc_commit_id(&workspace_name)
        .expect("workspace has a working-copy commit")
        .clone();
    let wc_tree = repo.store().get_commit(&wc_id).expect("wc commit").tree();

    let mut tx = repo.start_transaction();
    let new_commit = pollster::block_on(tx.repo_mut().new_commit(vec![wc_id], wc_tree).write()).expect("write commit");
    tx.repo_mut()
        .set_wc_commit(workspace_name, new_commit.id().clone())
        .expect("set wc commit");
    pollster::block_on(tx.commit("test: jj new")).expect("commit tx");
}

/// A git-backed repo whose `@` RENAMES `old_name.txt` to `new_name.txt`.
fn renamed_on_git_backend() -> (TempDir, Repo) {
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("git-backed init");

    fs::write(tmp.path().join("old_name.txt"), b"content to rename").expect("write");
    snapshot_working_copy(tmp.path());
    jj_new(tmp.path());

    fs::rename(tmp.path().join("old_name.txt"), tmp.path().join("new_name.txt")).expect("rename");
    snapshot_working_copy(tmp.path());

    let repo = Repo::open(tmp.path()).expect("repo opens");
    (tmp, repo)
}

// ── show ──────────────────────────────────────────────────────────────────────────

#[test]
fn show_defaults_to_the_working_copy_and_reuses_the_change_construction_site() {
    test_helpers::pin_test_env();
    let (_tmp, mut repo) = renamed_on_git_backend();
    let before = head_op_id(&mut repo);

    let entries = repo.show(None, None).expect("show succeeds");
    assert_eq!(entries.len(), 1, "`@` is one commit");

    // The metadata half must be BYTE-IDENTICAL to what `get_change` reports for the same
    // commit — proving `show` goes through the crate's single `Change` construction site
    // rather than a second projection. `Change` has no `PartialEq`, so the Debug rendering
    // (which names every field) is the equality witness.
    let wc = repo.status().expect("status").working_copy_change_id.expect("@");
    let oracle = repo.get_change(&wc).expect("get_change");
    assert_eq!(
        format!("{:?}", entries[0].change),
        format!("{oracle:?}"),
        "show's `change` must be the same projection get_change produces"
    );

    assert_eq!(head_op_id(&mut repo), before, "a read must not write an operation");
}

#[test]
fn show_reports_a_rename_with_its_source_path_on_the_git_backend() {
    test_helpers::pin_test_env();
    let (_tmp, mut repo) = renamed_on_git_backend();

    let entries = repo.show(None, None).expect("show succeeds");
    let changes = &entries[0].file_changes;

    // ONE rename entry, not an Added+Removed pair: `show` accumulates copy records over every
    // parent, exactly as the CLI's `show_patch` does.
    assert_eq!(
        summary(changes),
        vec![("new_name.txt".to_owned(), "R")],
        "expected a single Renamed entry, got {changes:?}"
    );
    assert!(
        matches!(&changes[0].kind, ChangeKind::Renamed { from } if from.to_str() == Some("old_name.txt")),
        "the source path must survive: {:?}",
        changes[0].kind
    );
}

#[test]
fn show_of_a_root_commit_reports_no_file_changes() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let entries = repo.show(Some("root()"), None).expect("show succeeds");

    assert_eq!(entries.len(), 1);
    assert!(
        entries[0].file_changes.is_empty(),
        "the root commit's tree equals its own parent tree"
    );
    assert!(entries[0].change.parents.is_empty(), "the root change has no parents");
    assert_eq!(head_op_id(&mut repo), before);
}

/// The payload's documented ORDER — "raw revset order, children before parents" — and the
/// per-commit parent resolution, in one scenario.
///
/// A parent→child DAG range is what makes the order observable: the two rows are not siblings,
/// so "children before parents" is a claim the assertion can actually falsify (appending
/// `out.reverse()` to `show` fails here). Their diffs differ too, so an entry diffed against the
/// wrong commit's parent would report the other's file.
#[test]
fn show_returns_children_before_parents_and_diffs_each_against_its_own_parent() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let parent = add_commit_with_files(&fx.path, &[], &[("a.txt", "alpha\n")], "adds a");
    let child = add_commit_with_files(
        &fx.path,
        &[&parent],
        &[("a.txt", "alpha\n"), ("b.txt", "beta\n")],
        "adds b",
    );
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let entries = repo
        .show(Some(&format!("{parent}::{child}")), None)
        .expect("show succeeds");

    assert_eq!(
        entries
            .iter()
            .map(|e| (e.change.commit_id.0.clone(), summary(&e.file_changes)))
            .collect::<Vec<_>>(),
        vec![
            (child.clone(), vec![("b.txt".to_owned(), "A")]),
            (parent.clone(), vec![("a.txt".to_owned(), "A")]),
        ],
        "raw revset order is children before parents, and each row is diffed against ITS OWN parent"
    );
    assert_eq!(head_op_id(&mut repo), before);
}

/// An ordinary EDIT — the single most common thing a GUI renders, and the one `ChangeKind` no
/// other scenario in this suite produces (every other row is an add, a removal or a rename).
#[test]
fn show_reports_an_edited_file_as_modified() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let base = add_commit_with_files(&fx.path, &[], &[("a.txt", "alpha\n")], "base");
    let edited = add_commit_with_files(&fx.path, &[&base], &[("a.txt", "alpha\nbeta\n")], "edit a.txt");
    let change = change_id_of(&fx.path, &edited);
    let mut repo = open(&fx);

    let entries = repo.show(Some(&change.0), None).expect("show succeeds");

    assert_eq!(
        summary(&entries[0].file_changes),
        vec![("a.txt".to_owned(), "M")],
        "a path present in both trees with different content is Modified, not Added+Removed"
    );
}

/// `show` accumulates copy records over EVERY parent (the CLI's `show_patch`), where
/// `status.rs` deliberately uses only the first (its documented D4 approximation).
///
/// The rename here is visible ONLY against the SECOND parent — `p1` never held `old.txt`, so
/// git finds no rewrite between `p1` and the merge. Restricting the loop to
/// `parent_ids().first()` therefore turns this one `R` entry into an `Added`+`Removed` pair.
#[test]
fn show_accumulates_copy_records_over_every_parent_not_just_the_first() {
    test_helpers::pin_test_env();
    let tmp = git_workspace();
    let p1 = add_commit_with_files(tmp.path(), &[], &[("a.txt", "alpha\n")], "p1");
    let p2 = add_commit_with_files(tmp.path(), &[], &[("old.txt", COPY_BODY)], "p2");
    let merge = add_commit_with_files(
        tmp.path(),
        &[&p1, &p2],
        &[("a.txt", "alpha\n"), ("new.txt", COPY_BODY)],
        "merge that renames old.txt",
    );
    let change = change_id_of(tmp.path(), &merge);
    let mut repo = Repo::open(tmp.path()).expect("repo opens");

    let entries = repo.show(Some(&change.0), None).expect("show succeeds");

    assert_eq!(
        summary(&entries[0].file_changes),
        vec![("new.txt".to_owned(), "R")],
        "the second parent's copy records must be consulted too, got {:?}",
        entries[0].file_changes
    );
    assert!(
        matches!(&entries[0].file_changes[0].kind, ChangeKind::Renamed { from } if from.to_str() == Some("old.txt")),
        "the source path must survive: {:?}",
        entries[0].file_changes[0].kind
    );
}

/// The `Copied` arm of the classifier.
///
/// gix only looks for a copy SOURCE among the files the diff already reports as modified
/// (`CopySource::FromSetOfModifiedFiles`, `git_backend.rs:1481-1486` @ 0.44.0), so a copy is
/// detectable only when the ORIGINAL is edited in the same commit. `copy.txt` is a byte-exact
/// copy of `a.txt`'s PRE-edit body, which scores 100 % against gix's 50 % threshold.
#[test]
fn show_reports_a_copy_whose_source_was_edited_in_the_same_commit() {
    test_helpers::pin_test_env();
    let tmp = git_workspace();
    let base = add_commit_with_files(tmp.path(), &[], &[("a.txt", COPY_BODY)], "base");
    let copied = add_commit_with_files(
        tmp.path(),
        &[&base],
        &[
            ("a.txt", "line zero\nline one\nline two\nline three\nline four\n"),
            ("copy.txt", COPY_BODY),
        ],
        "copy a.txt and edit the original",
    );
    let change = change_id_of(tmp.path(), &copied);
    let mut repo = Repo::open(tmp.path()).expect("repo opens");

    let entries = repo.show(Some(&change.0), None).expect("show succeeds");

    let mut labels = summary(&entries[0].file_changes);
    labels.sort();
    assert_eq!(
        labels,
        vec![("a.txt".to_owned(), "M"), ("copy.txt".to_owned(), "C")],
        "the original stays Modified and the duplicate is Copied, not Added: {:?}",
        entries[0].file_changes
    );
    let copy = entries[0]
        .file_changes
        .iter()
        .find(|c| c.path.to_str() == Some("copy.txt"))
        .expect("the copy entry");
    assert!(
        matches!(&copy.kind, ChangeKind::Copied { from } if from.to_str() == Some("a.txt")),
        "the source path must survive: {:?}",
        copy.kind
    );
}

#[test]
fn show_of_a_merge_diffs_against_the_merged_parent_tree() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let merge_hex = add_conflicted_merge_off_root(&fx.path);
    let merge = change_id_of(&fx.path, &merge_hex);
    let mut repo = open(&fx);

    let entries = repo.show(Some(&merge.0), None).expect("show succeeds");
    assert_eq!(entries.len(), 1);

    // `Commit::parent_tree` merges ALL parents, so the diff is only what the MERGE itself
    // changed — never the union of the two sides' own contents. The merge's tree holds the
    // conflicted path (jj-lib's oracle), yet the diff against the merged parent tree is empty
    // because the merge introduced nothing of its own.
    assert!(
        oracle_paths(&fx.path, &merge_hex).contains(&"conflicted.txt".to_owned()),
        "the fixture's merge really does carry the conflicted path"
    );
    assert!(
        entries[0].file_changes.is_empty(),
        "a merge that changes nothing itself has an empty diff against its merged parent tree, \
         got {:?}",
        summary(&entries[0].file_changes)
    );
    assert_eq!(entries[0].change.parents.len(), 2, "the merge really has two parents");
}

/// `show` rows are per COMMIT, not per change — and a bare divergent change-id SYMBOL is a
/// revset-resolution refusal, exactly as it is in the CLI.
///
/// The story spec expected a bare divergent change id to yield both commits. It does not at
/// v0.44.0: jj-lib's `SymbolResolver` raises `DivergentChangeId` for the bare symbol
/// (`revset.rs:2827`), and the CLI surfaces that same error for `jj show <divergent-id>`. CLI
/// parity therefore means REFUSING it here too — and it is a different refusal from
/// `interdiff`'s, which reports `ChangeNotFound` from its own single-revision resolver. Both
/// commits remain addressable, because `revset` is a pass-through expression: their commit
/// hexes are ordinary revset symbols and can be unioned, which is what proves that one row is
/// emitted per commit rather than per change.
#[test]
fn show_is_per_commit_and_refuses_a_bare_divergent_change_id() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let original = add_commit_off_root(&fx.path, "original");
    let twin = add_divergent_twin(&fx.path, &original, "twin");
    let change = change_id_of(&fx.path, &original);
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let err = repo
        .show(Some(&change.0), None)
        .expect_err("a bare divergent change-id symbol does not resolve");
    assert!(
        matches!(&err, CommitViewError::RevsetResolutionError { reason, .. } if reason.contains("divergent")),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before, "a refusal must not write an operation");

    let entries = repo
        .show(Some(&format!("{original} | {twin}")), None)
        .expect("commit hexes are ordinary revset symbols");
    assert_eq!(entries.len(), 2, "one entry per COMMIT, not per change");
    let commit_ids: Vec<_> = entries.iter().map(|e| e.change.commit_id.0.clone()).collect();
    assert!(
        commit_ids.contains(&original),
        "the original commit is present: {commit_ids:?}"
    );
    assert!(
        commit_ids.contains(&twin),
        "the divergent twin is present: {commit_ids:?}"
    );
    assert!(
        entries.iter().all(|e| e.change.id == change && e.change.divergent),
        "both rows carry the SAME change id and are flagged divergent"
    );
}

/// The Zanshin-side `limit`: honoured in RAW REVSET order, and ABSENT means unbounded.
///
/// The parent→child range is what makes "the FIRST n of the unbounded result" falsifiable —
/// the two rows are not siblings, so a limit applied after a reversal, or to the wrong end of
/// the walk, would take `parent` instead of `child`. The unbounded call is compared against
/// itself as the oracle, so nothing here re-derives the expected order.
#[test]
fn show_applies_the_limit_in_raw_revset_order_and_is_unbounded_when_absent() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let parent = add_commit_with_files(&fx.path, &[], &[("a.txt", "alpha\n")], "adds a");
    let child = add_commit_with_files(
        &fx.path,
        &[&parent],
        &[("a.txt", "alpha\n"), ("b.txt", "beta\n")],
        "adds b",
    );
    let range = format!("{parent}::{child}");
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let unbounded = repo.show(Some(&range), None).expect("show succeeds");
    assert_eq!(unbounded.len(), 2, "the range denotes both commits");

    // BELOW the set size: exactly n entries, and they are the FIRST n of the unbounded result.
    let limited = repo.show(Some(&range), Some(1)).expect("show succeeds");
    assert_eq!(
        limited.iter().map(|e| e.change.commit_id.0.clone()).collect::<Vec<_>>(),
        vec![unbounded[0].change.commit_id.0.clone()],
        "the limit takes the FIRST n of the raw revset order"
    );
    assert_eq!(limited[0].change.commit_id.0, child, "which is the CHILD");

    // ABOVE the set size is not an error, and it is byte-for-byte the unbounded answer.
    let over = repo
        .show(Some(&range), Some(5))
        .expect("a limit above the set size is fine");
    assert_eq!(
        over.iter().map(|e| format!("{e:?}")).collect::<Vec<_>>(),
        unbounded.iter().map(|e| format!("{e:?}")).collect::<Vec<_>>(),
        "a limit larger than the set changes nothing"
    );

    // `0` is a MEANINGFUL value — an empty result and a SUCCESS, exactly as `evolog(_, Some(0))`.
    assert!(repo.show(None, Some(0)).expect("limit 0 is not an error").is_empty());

    // A limit on an empty revset is still an empty success.
    assert!(repo
        .show(Some("none()"), Some(3))
        .expect("an empty revset with a limit is not an error")
        .is_empty());

    assert_eq!(head_op_id(&mut repo), before, "a read must not write an operation");
}

#[test]
fn show_of_an_empty_revset_is_an_empty_success() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let mut repo = open(&fx);

    let entries = repo
        .show(Some("none()"), None)
        .expect("an empty revset is not an error");
    assert!(entries.is_empty());
}

#[test]
fn show_refuses_a_malformed_or_unresolvable_revset_without_writing_an_operation() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let err = repo.show(Some("::("), None).expect_err("a syntax error is refused");
    assert!(
        matches!(&err, CommitViewError::RevsetParseError { reason, .. } if !reason.is_empty()),
        "unexpected error: {err:?}"
    );
    // The CLI's revset hints ride along (Story 9.25 closing run).
    let err = repo.show(Some("descripton(x)"), None).expect_err("an unknown function");
    assert!(
        matches!(&err, CommitViewError::RevsetParseError { hints, .. }
            if hints.iter().any(|h| h.starts_with("Did you mean") && h.contains("description"))),
        "unexpected error: {err:?}"
    );

    let err = repo
        .show(Some("nosuchbookmark"), None)
        .expect_err("an unknown symbol is refused");
    assert!(
        matches!(&err, CommitViewError::RevsetResolutionError { reason, .. } if !reason.is_empty()),
        "unexpected error: {err:?}"
    );

    // An explicitly PRESENT empty string is a VALUE, not an absence: it must reach the parser
    // rather than silently becoming the `@` default that `None` applies. Without this row,
    // normalizing `""` to `None` anywhere along the wire would pass the whole suite while
    // turning a cleared revset box into a silent answer about the working copy.
    let err = repo
        .show(Some(""), None)
        .expect_err("an empty revset is a VALUE, not an absence");
    assert!(
        matches!(&err, CommitViewError::RevsetParseError { reason, .. } if !reason.is_empty()),
        "unexpected error: {err:?}"
    );

    assert_eq!(
        head_op_id(&mut repo),
        before,
        "a refusal must not write an operation either"
    );
}

#[test]
fn show_reports_a_malformed_repo_config_as_a_config_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);
    // TABLE level, not entry level: a `revset-aliases` that is not a table at all is a hard
    // error in the CLI too — never a silent fall-back to the builtin aliases.
    write_repo_config(&fx.path, "revset-aliases = 42\n");

    let err = repo
        .show(None, None)
        .expect_err("a non-table revset-aliases is refused");
    assert!(
        matches!(&err, CommitViewError::Precondition(zanshin_jj::PreconditionError::Config { reason }) if reason.contains("revset-aliases")),
        "unexpected error: {err:?}"
    );
    // Every verb refuses while the stack is broken, so it is repaired before the read-back.
    write_repo_config(&fx.path, "");
    assert_eq!(head_op_id(&mut repo), before);
}

// ── evolog ────────────────────────────────────────────────────────────────────────

/// A change rewritten twice, plus the commit hexes of all three versions (newest first).
fn evolution_chain() -> (FixtureHandle, ChangeId, [String; 3]) {
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let v1 = add_commit_off_root(&fx.path, "v1");
    let v2 = describe_commit(&fx.path, &v1, "v2");
    let v3 = describe_commit(&fx.path, &v2, "v3");
    let change = change_id_of(&fx.path, &v3);
    (fx, change, [v3, v2, v1])
}

#[test]
fn evolog_walks_every_version_newest_first_with_its_predecessors() {
    test_helpers::pin_test_env();
    let (fx, change, [v3, v2, v1]) = evolution_chain();
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let entries = repo.evolog(Some(&change.0), None).expect("evolog succeeds");

    assert_eq!(
        entries.iter().map(|e| e.change.commit_id.0.clone()).collect::<Vec<_>>(),
        vec![v3.clone(), v2.clone(), v1.clone()],
        "raw walk order is newest-first"
    );
    // Every version shares ONE change id — which is exactly why the edges travel as COMMIT ids.
    assert!(entries.iter().all(|e| e.change.id == change));
    assert_eq!(
        entries[0]
            .predecessor_commit_ids
            .iter()
            .map(|c| c.0.clone())
            .collect::<Vec<_>>(),
        vec![v2]
    );
    assert_eq!(
        entries[1]
            .predecessor_commit_ids
            .iter()
            .map(|c| c.0.clone())
            .collect::<Vec<_>>(),
        vec![v1]
    );
    assert!(
        entries[2].predecessor_commit_ids.is_empty(),
        "the oldest version was created, not rewritten — it has no predecessor"
    );

    // Every operation the walk names must be a real op-log entry: the id is what a caller
    // would look up to explain WHEN a version was created.
    let op_ids: Vec<_> = repo.op_log(None).expect("op log").into_iter().map(|o| o.id.0).collect();
    for (i, entry) in entries.iter().enumerate() {
        let op = entry
            .operation_id
            .as_ref()
            .unwrap_or_else(|| panic!("entry {i} was emitted by a recording operation"));
        assert!(
            op_ids.contains(&op.0),
            "entry {i}'s operation is a real op-log entry: {op:?}"
        );
    }

    assert_eq!(head_op_id(&mut repo), before, "a read must not write an operation");
}

/// The FLUSH TAIL — the one state in which `operation_id` is `None`.
///
/// `walk_predecessors` emits an entry with no operation when it exhausts the op log (or reaches
/// an operation that stores no predecessors) with commits still unvisited. The root commit is
/// the deterministic instance: no operation ever created it, so the walk can find nothing and
/// flushes it. That `None` is the ONLY signal a caller has that an evolution may be truncated;
/// the CLI truncates silently.
#[test]
fn evolog_of_the_root_commit_is_emitted_from_the_flush_tail() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let mut repo = open(&fx);

    let entries = repo.evolog(Some("root()"), None).expect("evolog succeeds");

    assert_eq!(entries.len(), 1);
    assert!(
        entries[0].operation_id.is_none(),
        "no operation created the root commit, so the walk flushes it"
    );
    assert!(
        entries[0].predecessor_commit_ids.is_empty(),
        "an entry with no operation can carry no predecessors (jj-lib returns `&[]`)"
    );
}

#[test]
fn evolog_applies_the_limit_in_walk_order() {
    test_helpers::pin_test_env();
    let (fx, change, [v3, v2, _v1]) = evolution_chain();
    let mut repo = open(&fx);

    let two = repo.evolog(Some(&change.0), Some(2)).expect("evolog succeeds");
    assert_eq!(
        two.iter().map(|e| e.change.commit_id.0.clone()).collect::<Vec<_>>(),
        vec![v3, v2],
        "the limit takes the FIRST n of the walk order (the CLI limits before reversing)"
    );

    // `0` is a meaningful value — an empty result, not an error and not "no limit".
    let none = repo.evolog(Some(&change.0), Some(0)).expect("limit 0 is not an error");
    assert!(none.is_empty());
}

#[test]
fn evolog_of_a_never_rewritten_commit_is_a_single_entry_and_defaults_to_the_working_copy() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let fresh = add_commit_off_root(&fx.path, "never rewritten");
    let fresh_change = change_id_of(&fx.path, &fresh);
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let entries = repo.evolog(Some(&fresh_change.0), None).expect("evolog succeeds");
    assert_eq!(entries.len(), 1, "a commit that was never rewritten has one version");
    assert_eq!(entries[0].change.commit_id.0, fresh);

    // `None` applies the CLI's own `@` default, which the fixture never rewrote either.
    let default = repo.evolog(None, None).expect("evolog succeeds");
    let wc = repo.status().expect("status").working_copy_change_id.expect("@");
    assert_eq!(default.len(), 1);
    assert_eq!(default[0].change.id, wc, "an omitted revset is `@`");

    assert_eq!(head_op_id(&mut repo), before);
}

#[test]
fn evolog_refuses_a_malformed_revset_without_writing_an_operation() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let err = repo.evolog(Some("::("), None).expect_err("a syntax error is refused");
    assert!(
        matches!(&err, CommitViewError::RevsetParseError { reason, .. } if !reason.is_empty()),
        "unexpected error: {err:?}"
    );
    let err = repo
        .evolog(Some("descripton(x)"), None)
        .expect_err("an unknown function");
    assert!(
        matches!(&err, CommitViewError::RevsetParseError { hints, .. }
            if hints.iter().any(|h| h.starts_with("Did you mean") && h.contains("description"))),
        "unexpected error: {err:?}"
    );

    let err = repo
        .evolog(Some("nosuchbookmark"), None)
        .expect_err("an unknown symbol is refused");
    assert!(
        matches!(&err, CommitViewError::RevsetResolutionError { .. }),
        "unexpected error: {err:?}"
    );

    assert_eq!(head_op_id(&mut repo), before);
}

/// `docs/rust-error-codes.md` registers `jj.config_error` for `evolog` as well as `show`, and
/// `evolog` reaches it through its own `parse_revset` call, not `show`'s — so the registry's
/// claim needs its own witness.
#[test]
fn evolog_reports_a_malformed_repo_config_as_a_config_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);
    write_repo_config(&fx.path, "revset-aliases = 42\n");

    let err = repo
        .evolog(None, None)
        .expect_err("a non-table revset-aliases is refused");
    assert!(
        matches!(&err, CommitViewError::Precondition(zanshin_jj::PreconditionError::Config { reason }) if reason.contains("revset-aliases")),
        "unexpected error: {err:?}"
    );
    // Every verb refuses while the stack is broken, so it is repaired before the read-back.
    write_repo_config(&fx.path, "");
    assert_eq!(head_op_id(&mut repo), before);
}

// ── interdiff ─────────────────────────────────────────────────────────────────────

#[test]
fn interdiff_factors_out_the_parent_difference() {
    test_helpers::pin_test_env();
    let p = interdiff_pair();
    let mut repo = open(&p.fx);
    let before = head_op_id(&mut repo);

    let view = repo
        .interdiff(Some(chg(&p.from)), Some(chg(&p.to)), &[])
        .expect("interdiff succeeds");

    // A plain `diff --from from --to to` would ALSO report `extra.txt`, which the two
    // revisions' PARENTS differ by. `interdiff` rebases `from` onto `to`'s parents first, so
    // only what `to` changes and `from` does not survives.
    assert_eq!(
        summary(&view.file_changes),
        vec![("b.txt".to_owned(), "A")],
        "expected only the change `to` makes that `from` does not"
    );
    assert!(
        !view.base_has_conflicts,
        "disjoint edits rebase cleanly — the NEGATIVE pole of the flag"
    );
    assert_eq!(head_op_id(&mut repo), before, "the rebase is in-memory — no operation");
}

#[test]
fn interdiff_of_a_revision_against_itself_is_empty() {
    test_helpers::pin_test_env();
    let p = interdiff_pair();
    let mut repo = open(&p.fx);

    let view = repo
        .interdiff(Some(chg(&p.to)), Some(chg(&p.to)), &[])
        .expect("interdiff succeeds");
    assert!(
        view.file_changes.is_empty(),
        "identical trees produce no entries: {:?}",
        view.file_changes
    );
    assert!(
        !view.base_has_conflicts,
        "the fast path returns `from`'s own tree — here the same clean commit as `to`"
    );
}

#[test]
fn interdiff_filters_by_path_prefix() {
    test_helpers::pin_test_env();
    let p = interdiff_pair();
    let mut repo = open(&p.fx);

    let matching = repo
        .interdiff(Some(chg(&p.from)), Some(chg(&p.to)), &["b.txt".to_owned()])
        .expect("interdiff succeeds");
    assert_eq!(summary(&matching.file_changes), vec![("b.txt".to_owned(), "A")]);
    // `b.txt` exists only in `to`'s tree — present in ONE checked tree is a match (Story 9.32:
    // `jj.paths_unmatched` needs the path absent from every tree).
    assert!(repo.take_warnings().is_empty());

    // An unmatched filter is a CLI *warning*, not an error: the result is empty and the call
    // warns `jj.paths_unmatched`.
    let unmatched = repo
        .interdiff(Some(chg(&p.from)), Some(chg(&p.to)), &["nosuchdir".to_owned()])
        .expect("an unmatched path filter is not a refusal");
    assert!(unmatched.file_changes.is_empty());
    let warnings = repo.take_warnings();
    assert_eq!(
        warnings.iter().map(|w| w.kind).collect::<Vec<_>>(),
        [zanshin_jj::WarningKind::PathsUnmatched]
    );
}

#[test]
fn interdiff_refuses_when_both_revisions_are_absent() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let err = repo
        .interdiff(None, None, &[])
        .expect_err("the CLI's ArgGroup makes at least one side required");
    assert!(
        matches!(&err, CommitViewError::InvalidInput { reason } if reason.contains("from") && reason.contains("to")),
        "the refusal must name which arguments are meant: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before);
}

#[test]
fn interdiff_defaults_the_omitted_side_to_the_working_copy() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let other = add_commit_off_root(&fx.path, "other");
    let other_change = change_id_of(&fx.path, &other);
    let mut repo = open(&fx);
    let wc = repo.status().expect("status").working_copy_change_id.expect("@");

    // Supplying ONE side is enough; the other becomes `@`. Both spellings must agree.
    let defaulted = repo
        .interdiff(Some(chg(&other_change)), None, &[])
        .expect("one side is enough");
    let explicit = repo
        .interdiff(Some(chg(&other_change)), Some(chg(&wc)), &[])
        .expect("the explicit spelling succeeds");
    assert_eq!(
        summary(&defaulted.file_changes),
        summary(&explicit.file_changes),
        "an absent `to` is `@`"
    );
}

/// Every unresolvable spelling is refused on BOTH sides, with the OFFENDING id echoed.
///
/// Running each id through `from` and `to` is what makes the two symmetric `map_err` closures
/// distinguishable: with only the `from` rows, mistyping the second one as `res(e, from)` — a
/// one-token copy-paste slip between two adjacent lines — reports the side the caller got
/// RIGHT, and nothing fails.
#[test]
fn interdiff_refuses_an_unknown_divergent_or_empty_revision_on_either_side() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let original = add_commit_off_root(&fx.path, "original");
    _ = add_divergent_twin(&fx.path, &original, "twin");
    let divergent = change_id_of(&fx.path, &original);
    // A resolvable counterpart, so the OTHER side is never the reason for the refusal.
    let good = change_id_of(&fx.path, &add_commit_off_root(&fx.path, "resolvable"));
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    for (spelling, id) in [
        // NOT "zzzzzzzz" — that is a prefix of the ROOT commit's all-zero change id.
        ("unknown", ChangeId("nonexistentchangeid".to_owned())),
        // `resolve_single_rev` parity: two visible commits is ambiguous, and this verb refuses
        // rather than picking one — unlike `show`, which returns both.
        ("divergent", divergent),
        // An empty id would otherwise reach jj-lib's `panic!` on an empty hex prefix.
        ("empty", ChangeId(String::new())),
    ] {
        for side in ["from", "to"] {
            let (from, to) = if side == "from" {
                (Some(chg(&id)), Some(chg(&good)))
            } else {
                (Some(chg(&good)), Some(chg(&id)))
            };
            let err = match repo.interdiff(from, to, &[]) {
                Ok(view) => panic!("the {spelling} id must be refused as `{side}`, got {view:?}"),
                Err(e) => e,
            };
            assert!(
                matches!(&err, CommitViewError::ChangeNotFound { id: echoed } if *echoed == id.0),
                "the {spelling} id given as `{side}` must echo ITS OWN id, got: {err:?}"
            );
        }
    }

    assert_eq!(head_op_id(&mut repo), before);
}

/// The `true` pole of `base_has_conflicts`: a rebase whose own 3-way merge cannot resolve.
///
/// `rebase_to_dest_parent` merges with `from.parent_tree()` as the BASE and
/// (`to.parent_tree()`, `from.tree()`) as the two sides (`jj-lib rewrite.rs:462-489`). So the
/// shape is four commits: two parents that already differ at one path, and one child of each
/// that edits that same path differently. Both sides then changed the base's `f.txt`, which is
/// the unresolvable case. The fast path (`rewrite.rs:456-460`) does not fire, because the two
/// children have DIFFERENT parents.
///
/// `add_conflicted_merge_off_root` cannot stand in for this: it builds a conflicted MERGE
/// COMMIT, i.e. a conflict that already lives in a committed tree, not one the rebase produces.
///
/// The call still SUCCEEDS — a conflicted base is a fact about the comparison, not a refusal —
/// and the flag describes the TREE, so a `paths` filter that empties the change list leaves it
/// set.
#[test]
fn interdiff_reports_a_conflicted_rebase_base_without_refusing() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let p1 = add_commit_with_files(&fx.path, &[], &[("f.txt", "base-left\n")], "p1");
    let p2 = add_commit_with_files(&fx.path, &[], &[("f.txt", "base-right\n")], "p2");
    let from_hex = add_commit_with_files(&fx.path, &[&p1], &[("f.txt", "from\n")], "from");
    let to_hex = add_commit_with_files(&fx.path, &[&p2], &[("f.txt", "to\n")], "to");
    let from = change_id_of(&fx.path, &from_hex);
    let to = change_id_of(&fx.path, &to_hex);
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let view = repo
        .interdiff(Some(chg(&from)), Some(chg(&to)), &[])
        .expect("a conflicted rebase base is not a refusal");
    assert!(
        view.base_has_conflicts,
        "the 3-way merge could not resolve f.txt, got {view:?}"
    );
    // The COMPARISON must survive too, not just the flag: a regression that reported the
    // conflict and threw the change list away would otherwise pass this test.
    assert_eq!(
        summary(&view.file_changes),
        vec![("f.txt".to_owned(), "M")],
        "the diff against `to`'s tree is still reported alongside the flag"
    );

    // The flag is about the TREE, not the filtered result: narrowing to a path that matches
    // nothing empties `file_changes` and must leave the flag alone.
    let filtered = repo
        .interdiff(Some(chg(&from)), Some(chg(&to)), &["nosuchdir".to_owned()])
        .expect("an unmatched path filter is not a refusal");
    assert!(filtered.file_changes.is_empty());
    assert!(
        filtered.base_has_conflicts,
        "the flag describes the rebased tree, not the filtered change list"
    );

    assert_eq!(head_op_id(&mut repo), before, "the rebase is in-memory — no operation");
}

/// The SECOND documented cause of `base_has_conflicts`: the rebase's FAST PATH.
///
/// `rebase_to_dest_parent` returns `source.tree()` verbatim when the single source already has
/// the destination's parents (`jj-lib rewrite.rs:456-460`), so no merge runs at all — the flag
/// then reports whether `from`'s OWN tree was already conflicted. Both `base_has_conflicts`
/// docs enumerate this arm beside the 3-way-merge one, and without this row a derivation that
/// only looked at merge results (say, computing the flag inside the non-fast-path branch) would
/// leave the whole class of same-parent comparisons silently unflagged while every other test
/// still passed.
///
/// A conflicted MERGE commit interdiffed against itself is the cheapest way there: identical
/// parents force the fast path, and identical trees make the change list empty — so the flag is
/// the ONLY thing distinguishing this from the clean self-comparison two tests above.
#[test]
fn interdiff_flags_a_conflicted_base_reached_through_the_rebase_fast_path() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let merge_hex = add_conflicted_merge_off_root(&fx.path);
    let merge = change_id_of(&fx.path, &merge_hex);
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let view = repo
        .interdiff(Some(chg(&merge)), Some(chg(&merge)), &[])
        .expect("a conflicted base is not a refusal on the fast path either");

    assert!(
        view.file_changes.is_empty(),
        "identical trees produce no entries: {:?}",
        view.file_changes
    );
    assert!(
        view.base_has_conflicts,
        "the fast path handed back `from`'s own CONFLICTED tree, got {view:?}"
    );
    assert_eq!(head_op_id(&mut repo), before, "the rebase is in-memory — no operation");
}

#[test]
fn interdiff_never_reports_a_rename_even_where_show_does() {
    test_helpers::pin_test_env();
    let (_tmp, mut repo) = renamed_on_git_backend();
    let status = repo.status().expect("status");

    // The SAME pair `show` reports as one Renamed entry.
    let shown = repo.show(None, None).expect("show succeeds");
    assert_eq!(summary(&shown[0].file_changes), vec![("new_name.txt".to_owned(), "R")]);

    // `interdiff` passes NO copy records (`show_inter_diff`'s own `CopyRecords::default()`),
    // so the rename decomposes into an Added+Removed pair. That asymmetry is the CLI's.
    let view = repo
        .interdiff(
            Some(chg(status.parent_change_id.as_ref().expect("@-"))),
            Some(chg(status.working_copy_change_id.as_ref().expect("@"))),
            &[],
        )
        .expect("interdiff succeeds");
    let mut labels = summary(&view.file_changes);
    labels.sort();
    assert_eq!(
        labels,
        vec![("new_name.txt".to_owned(), "A"), ("old_name.txt".to_owned(), "D")],
        "interdiff must never produce a Renamed/Copied entry"
    );
}

// ── interdiff: the commit-id arm ──────────────────────────────────────────────────

/// The motivating composition (Epic 9 follow-up I): `evolog` names a version by its HIDDEN
/// commit id, and `interdiff` diffs that version against the current one.
///
/// This is the stand-in for the CLI's unported `evolog --patch`, and it is only expressible
/// because the commit-id arm resolves through the INDEX, which does not filter by visibility.
/// The content rewrite matters: `describe_commit` (the other evolution helper) leaves every
/// version sharing one tree, so the same composition on a description-only chain is trivially
/// empty and would pass against a resolver that returned the wrong commit.
///
/// The second half is the tripwire that keeps the two arms apart: the SAME string, offered as a
/// `ChangeIdRef`, must still be refused byte-identically to before this arm existed — a commit
/// hex is not valid reverse-hex, and nothing about the union widened the change-id currency.
#[test]
fn interdiff_diffs_an_evolog_predecessor_against_the_current_version() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let v1 = add_commit_with_files(&fx.path, &[], &[("a.txt", "one\n")], "v1");
    let v2 = rewrite_commit_files(&fx.path, &v1, &[("a.txt", "two\n"), ("b.txt", "added\n")]);
    let change = change_id_of(&fx.path, &v2);
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let entries = repo.evolog(Some(&change.0), None).expect("evolog succeeds");
    let pred = entries[0]
        .predecessor_commit_ids
        .first()
        .expect("the rewritten version names its predecessor")
        .clone();
    assert_eq!(pred.0, v1, "the predecessor edge is the pre-rewrite COMMIT id");

    let view = repo
        .interdiff(Some(cmt(&pred.0)), Some(chg(&change)), &[])
        .expect("a hidden predecessor resolves through the commit-id arm");
    assert_eq!(
        summary(&view.file_changes),
        vec![("a.txt".to_owned(), "M"), ("b.txt".to_owned(), "A")],
        "the two VERSIONS of one change differ by the rewrite"
    );
    assert!(!view.base_has_conflicts);

    // The same hex through the change-id arm is refused exactly as it always was.
    let err = repo
        .interdiff(Some(chg(&ChangeId(pred.0.clone()))), Some(chg(&change)), &[])
        .expect_err("a commit hex is not a reverse-hex change id");
    assert!(
        matches!(&err, CommitViewError::ChangeNotFound { id } if *id == pred.0),
        "the change-id arm must keep refusing it, echoing the offending id: {err:?}"
    );

    assert_eq!(head_op_id(&mut repo), before, "neither call writes an operation");
}

/// BOTH sides hidden — the shape only the commit-id arm can express at all.
///
/// The composition test above pairs a hidden `from` with the VISIBLE head, so the change-id arm
/// still reaches one end of it. Asking "what did the SECOND rewrite change?" reaches neither end:
/// both versions are hidden, one change id names only the third, and there is no other currency
/// for them. Three versions with three different trees make the answer specific to the pair
/// chosen — a resolver that silently landed on the visible head would report `a.txt` as `three`
/// and drop `b.txt` entirely.
#[test]
fn interdiff_diffs_two_hidden_versions_of_one_change() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let v1 = add_commit_with_files(&fx.path, &[], &[("a.txt", "one\n")], "v1");
    let v2 = rewrite_commit_files(&fx.path, &v1, &[("a.txt", "two\n"), ("b.txt", "added\n")]);
    let v3 = rewrite_commit_files(&fx.path, &v2, &[("a.txt", "three\n")]);
    let change = change_id_of(&fx.path, &v3);
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    let entries = repo.evolog(Some(&change.0), None).expect("evolog succeeds");
    let pred_of_v3 = entries[0]
        .predecessor_commit_ids
        .first()
        .expect("the head names the version it rewrote")
        .0
        .clone();
    let pred_of_v2 = entries[1]
        .predecessor_commit_ids
        .first()
        .expect("the middle version names the one it rewrote")
        .0
        .clone();
    assert_eq!((pred_of_v3.as_str(), pred_of_v2.as_str()), (v2.as_str(), v1.as_str()));

    let view = repo
        .interdiff(Some(cmt(&pred_of_v2)), Some(cmt(&pred_of_v3)), &[])
        .expect("two HIDDEN commits both resolve through the commit-id arm");
    assert_eq!(
        summary(&view.file_changes),
        vec![("a.txt".to_owned(), "M"), ("b.txt".to_owned(), "A")],
        "the first rewrite is what separates version 1 from version 2"
    );
    assert!(!view.base_has_conflicts);

    assert_eq!(head_op_id(&mut repo), before, "the read writes no operation");
}

/// A one-character commit-id prefix that at least two commits in `workspace_root` share.
///
/// DETERMINISTIC, not probabilistic: a commit id is hex, so there are 16 possible first digits
/// and by pigeonhole 17 added commits must collide on one. Only the commits this function adds
/// are counted, so a collision with a pre-existing fixture commit merely makes the answer
/// ambiguous EARLIER — it can never make the loop run longer than its bound.
fn ambiguous_one_char_commit_prefix(workspace_root: &Path) -> String {
    let mut seen = std::collections::HashSet::new();
    for i in 0..17 {
        let hex = add_commit_off_root(workspace_root, &format!("ambiguity seed {i}"));
        let first = hex.chars().next().expect("a commit hex is never empty");
        if !seen.insert(first) {
            return first.to_string();
        }
    }
    unreachable!("17 commits cannot avoid a collision over 16 hex digits");
}

/// The commit-id arm's three refusals, each on BOTH sides and each under its OWN code.
///
/// The three-way split is the whole point of the arm having its own resolver: "that is not hex",
/// "that prefix is too short" and "no such commit" need three different remedies, and collapsing
/// any two of them would leave a caller guessing. The ambiguous row also pins that the prefix is
/// never resolved to one of its candidates.
#[test]
fn interdiff_refuses_a_malformed_ambiguous_or_unknown_commit_id_on_either_side() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let ambiguous = ambiguous_one_char_commit_prefix(&fx.path);
    // A resolvable counterpart, so the OTHER side is never the reason for the refusal.
    let good = change_id_of(&fx.path, &add_commit_off_root(&fx.path, "resolvable"));
    let mut repo = open(&fx);
    let before = head_op_id(&mut repo);

    for (spelling, hex) in [
        ("empty", String::new()),
        ("not hex", "nothex!".to_owned()),
        // Valid hex, 16 digits, no commit: the fixtures are git-backed, so their commit ids are
        // 40-hex SHA-1s and nothing this short is a whole id either.
        ("unknown", "deadbeefdeadbeef".to_owned()),
        ("ambiguous", ambiguous.clone()),
    ] {
        for side in ["from", "to"] {
            let (from, to) = if side == "from" {
                (Some(cmt(&hex)), Some(chg(&good)))
            } else {
                (Some(chg(&good)), Some(cmt(&hex)))
            };
            let err = match repo.interdiff(from, to, &[]) {
                Ok(view) => panic!("the {spelling} commit id must be refused as `{side}`, got {view:?}"),
                Err(e) => e,
            };
            let ok = match (spelling, &err) {
                // An empty id has nothing to echo, so `contains(&hex)` would be vacuously true
                // here — pin `res_commit`'s own wording instead.
                ("empty", CommitViewError::InvalidInput { reason }) => {
                    reason.contains("is not a valid commit id prefix")
                }
                ("not hex", CommitViewError::InvalidInput { reason }) => reason.contains(&hex),
                ("unknown", CommitViewError::ChangeNotFound { id }) => *id == hex,
                ("ambiguous", CommitViewError::RevsetResolutionError { reason, .. }) => {
                    reason.contains(&hex) && reason.contains("ambiguous")
                }
                _ => false,
            };
            assert!(ok, "the {spelling} commit id given as `{side}` landed wrong: {err:?}");
        }
    }

    assert_eq!(head_op_id(&mut repo), before, "a refusal writes no operation either");
}
