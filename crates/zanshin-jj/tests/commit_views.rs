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
//! `snapshot_working_copy`, mirroring `tests/status.rs`.
//!
//! Two assertions repeat throughout: the result compared against a RAW jj-lib oracle (never a
//! second call to the code under test), and — for every verb, on both a success and a refusal —
//! that the op-log head is byte-identical afterwards. A read must never write an operation.

use std::path::Path;
use std::sync::{Arc, LazyLock};
use std::{env, fs};

use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::gitignore::GitIgnoreFile;
use jj_lib::matchers::EverythingMatcher;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::settings::UserSettings;
use jj_lib::working_copy::SnapshotOptions;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::{
    add_commit_off_root, add_commit_with_files, add_conflicted_merge_off_root, add_divergent_twin, describe_commit,
    extract_fixture, FixtureHandle,
};
use zanshin_jj::{Backend, ChangeId, ChangeKind, CommitViewError, Repo};

// ── Harness ───────────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    // Same env pin as `tests/file_reads.rs`: the config layer must see the fixture's own
    // config, not the developer's `~/.jjconfig.toml`.
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

fn make_test_settings() -> UserSettings {
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
    UserSettings::from_config(config).expect("valid settings")
}

/// The head-resolved jj-lib repo — the oracle these tests read trees and commits from.
fn jj_repo(workspace_root: &Path) -> Arc<ReadonlyRepo> {
    let settings = make_test_settings();
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
fn head_op_id(repo: &Repo) -> String {
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
    Repo::init(tmp.path(), Some(Backend::Git)).expect("git-backed init");
    tmp
}

/// Four lines, so gix's 50 % similarity threshold has something to measure. An exact copy of
/// this body scores 100 % against the pre-edit version of the file it was copied from.
const COPY_BODY: &str = "line one\nline two\nline three\nline four\n";

// ── Git-backed working-copy harness (rename detection) ────────────────────────────
//
// The `@`-relative rows additionally need a real snapshot chain rather than a hand-built tree,
// because `@` itself must carry the rename. Both helpers are TEST SETUP ONLY: production code
// never snapshots (D2). Mirrors `tests/status.rs`.

fn snapshot_working_copy(workspace_root: &Path) {
    let settings = make_test_settings();
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
    let settings = make_test_settings();
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
    Repo::init(tmp.path(), Some(Backend::Git)).expect("git-backed init");

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
    pin_env();
    let (_tmp, repo) = renamed_on_git_backend();
    let before = head_op_id(&repo);

    let entries = repo.show(None).expect("show succeeds");
    assert_eq!(entries.len(), 1, "`@` is one commit");

    // The metadata half must be BYTE-IDENTICAL to what `get_change` reports for the same
    // commit — proving `show` goes through the crate's single `Change` construction site
    // rather than a second projection. `Change` has no `PartialEq`, so the Debug rendering
    // (which names every field) is the equality witness.
    let wc = repo.status().expect("status").working_copy_change_id;
    let oracle = repo.get_change(&wc).expect("get_change");
    assert_eq!(
        format!("{:?}", entries[0].change),
        format!("{oracle:?}"),
        "show's `change` must be the same projection get_change produces"
    );

    assert_eq!(head_op_id(&repo), before, "a read must not write an operation");
}

#[test]
fn show_reports_a_rename_with_its_source_path_on_the_git_backend() {
    pin_env();
    let (_tmp, repo) = renamed_on_git_backend();

    let entries = repo.show(None).expect("show succeeds");
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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let repo = open(&fx);
    let before = head_op_id(&repo);

    let entries = repo.show(Some("root()")).expect("show succeeds");

    assert_eq!(entries.len(), 1);
    assert!(
        entries[0].file_changes.is_empty(),
        "the root commit's tree equals its own parent tree"
    );
    assert!(entries[0].change.parents.is_empty(), "the root change has no parents");
    assert_eq!(head_op_id(&repo), before);
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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let parent = add_commit_with_files(&fx.path, &[], &[("a.txt", "alpha\n")], "adds a");
    let child = add_commit_with_files(
        &fx.path,
        &[&parent],
        &[("a.txt", "alpha\n"), ("b.txt", "beta\n")],
        "adds b",
    );
    let repo = open(&fx);
    let before = head_op_id(&repo);

    let entries = repo.show(Some(&format!("{parent}::{child}"))).expect("show succeeds");

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
    assert_eq!(head_op_id(&repo), before);
}

/// An ordinary EDIT — the single most common thing a GUI renders, and the one `ChangeKind` no
/// other scenario in this suite produces (every other row is an add, a removal or a rename).
#[test]
fn show_reports_an_edited_file_as_modified() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let base = add_commit_with_files(&fx.path, &[], &[("a.txt", "alpha\n")], "base");
    let edited = add_commit_with_files(&fx.path, &[&base], &[("a.txt", "alpha\nbeta\n")], "edit a.txt");
    let change = change_id_of(&fx.path, &edited);
    let repo = open(&fx);

    let entries = repo.show(Some(&change.0)).expect("show succeeds");

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
    pin_env();
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
    let repo = Repo::open(tmp.path()).expect("repo opens");

    let entries = repo.show(Some(&change.0)).expect("show succeeds");

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
    pin_env();
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
    let repo = Repo::open(tmp.path()).expect("repo opens");

    let entries = repo.show(Some(&change.0)).expect("show succeeds");

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let merge_hex = add_conflicted_merge_off_root(&fx.path);
    let merge = change_id_of(&fx.path, &merge_hex);
    let repo = open(&fx);

    let entries = repo.show(Some(&merge.0)).expect("show succeeds");
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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let original = add_commit_off_root(&fx.path, "original");
    let twin = add_divergent_twin(&fx.path, &original, "twin");
    let change = change_id_of(&fx.path, &original);
    let repo = open(&fx);
    let before = head_op_id(&repo);

    let err = repo
        .show(Some(&change.0))
        .expect_err("a bare divergent change-id symbol does not resolve");
    assert!(
        matches!(&err, CommitViewError::RevsetResolutionError { reason } if reason.contains("divergent")),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&repo), before, "a refusal must not write an operation");

    let entries = repo
        .show(Some(&format!("{original} | {twin}")))
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

#[test]
fn show_of_an_empty_revset_is_an_empty_success() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let repo = open(&fx);

    let entries = repo.show(Some("none()")).expect("an empty revset is not an error");
    assert!(entries.is_empty());
}

#[test]
fn show_refuses_a_malformed_or_unresolvable_revset_without_writing_an_operation() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let repo = open(&fx);
    let before = head_op_id(&repo);

    let err = repo.show(Some("::(")).expect_err("a syntax error is refused");
    assert!(
        matches!(&err, CommitViewError::RevsetParseError { reason } if !reason.is_empty()),
        "unexpected error: {err:?}"
    );

    let err = repo
        .show(Some("nosuchbookmark"))
        .expect_err("an unknown symbol is refused");
    assert!(
        matches!(&err, CommitViewError::RevsetResolutionError { reason } if !reason.is_empty()),
        "unexpected error: {err:?}"
    );

    assert_eq!(
        head_op_id(&repo),
        before,
        "a refusal must not write an operation either"
    );
}

#[test]
fn show_reports_a_malformed_repo_config_as_a_config_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let repo = open(&fx);
    let before = head_op_id(&repo);
    // TABLE level, not entry level: a `revset-aliases` that is not a table at all is a hard
    // error in the CLI too — never a silent fall-back to the builtin aliases.
    write_repo_config(&fx.path, "revset-aliases = 42\n");

    let err = repo.show(None).expect_err("a non-table revset-aliases is refused");
    assert!(
        matches!(&err, CommitViewError::Config { reason } if reason.contains("revset-aliases")),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&repo), before);
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
    pin_env();
    let (fx, change, [v3, v2, v1]) = evolution_chain();
    let repo = open(&fx);
    let before = head_op_id(&repo);

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

    assert_eq!(head_op_id(&repo), before, "a read must not write an operation");
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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let repo = open(&fx);

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
    pin_env();
    let (fx, change, [v3, v2, _v1]) = evolution_chain();
    let repo = open(&fx);

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let fresh = add_commit_off_root(&fx.path, "never rewritten");
    let fresh_change = change_id_of(&fx.path, &fresh);
    let repo = open(&fx);
    let before = head_op_id(&repo);

    let entries = repo.evolog(Some(&fresh_change.0), None).expect("evolog succeeds");
    assert_eq!(entries.len(), 1, "a commit that was never rewritten has one version");
    assert_eq!(entries[0].change.commit_id.0, fresh);

    // `None` applies the CLI's own `@` default, which the fixture never rewrote either.
    let default = repo.evolog(None, None).expect("evolog succeeds");
    let wc = repo.status().expect("status").working_copy_change_id;
    assert_eq!(default.len(), 1);
    assert_eq!(default[0].change.id, wc, "an omitted revset is `@`");

    assert_eq!(head_op_id(&repo), before);
}

#[test]
fn evolog_refuses_a_malformed_revset_without_writing_an_operation() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let repo = open(&fx);
    let before = head_op_id(&repo);

    let err = repo.evolog(Some("::("), None).expect_err("a syntax error is refused");
    assert!(
        matches!(&err, CommitViewError::RevsetParseError { reason } if !reason.is_empty()),
        "unexpected error: {err:?}"
    );

    let err = repo
        .evolog(Some("nosuchbookmark"), None)
        .expect_err("an unknown symbol is refused");
    assert!(
        matches!(&err, CommitViewError::RevsetResolutionError { .. }),
        "unexpected error: {err:?}"
    );

    assert_eq!(head_op_id(&repo), before);
}

// ── interdiff ─────────────────────────────────────────────────────────────────────

#[test]
fn interdiff_factors_out_the_parent_difference() {
    pin_env();
    let p = interdiff_pair();
    let repo = open(&p.fx);
    let before = head_op_id(&repo);

    let changes = repo
        .interdiff(Some(p.from.clone()), Some(p.to.clone()), &[])
        .expect("interdiff succeeds");

    // A plain `diff --from from --to to` would ALSO report `extra.txt`, which the two
    // revisions' PARENTS differ by. `interdiff` rebases `from` onto `to`'s parents first, so
    // only what `to` changes and `from` does not survives.
    assert_eq!(
        summary(&changes),
        vec![("b.txt".to_owned(), "A")],
        "expected only the change `to` makes that `from` does not"
    );
    assert_eq!(head_op_id(&repo), before, "the rebase is in-memory — no operation");
}

#[test]
fn interdiff_of_a_revision_against_itself_is_empty() {
    pin_env();
    let p = interdiff_pair();
    let repo = open(&p.fx);

    let changes = repo
        .interdiff(Some(p.to.clone()), Some(p.to.clone()), &[])
        .expect("interdiff succeeds");
    assert!(changes.is_empty(), "identical trees produce no entries: {changes:?}");
}

#[test]
fn interdiff_filters_by_path_prefix() {
    pin_env();
    let p = interdiff_pair();
    let repo = open(&p.fx);

    let matching = repo
        .interdiff(Some(p.from.clone()), Some(p.to.clone()), &["b.txt".to_owned()])
        .expect("interdiff succeeds");
    assert_eq!(summary(&matching), vec![("b.txt".to_owned(), "A")]);

    // An unmatched filter is a CLI *warning*, not an error — this API has no warning channel,
    // so it is simply an empty result.
    let unmatched = repo
        .interdiff(Some(p.from.clone()), Some(p.to.clone()), &["nosuchdir".to_owned()])
        .expect("an unmatched path filter is not a refusal");
    assert!(unmatched.is_empty());
}

#[test]
fn interdiff_refuses_when_both_revisions_are_absent() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let repo = open(&fx);
    let before = head_op_id(&repo);

    let err = repo
        .interdiff(None, None, &[])
        .expect_err("the CLI's ArgGroup makes at least one side required");
    assert!(
        matches!(&err, CommitViewError::InvalidInput { reason } if reason.contains("from") && reason.contains("to")),
        "the refusal must name which arguments are meant: {err:?}"
    );
    assert_eq!(head_op_id(&repo), before);
}

#[test]
fn interdiff_defaults_the_omitted_side_to_the_working_copy() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let other = add_commit_off_root(&fx.path, "other");
    let other_change = change_id_of(&fx.path, &other);
    let repo = open(&fx);
    let wc = repo.status().expect("status").working_copy_change_id;

    // Supplying ONE side is enough; the other becomes `@`. Both spellings must agree.
    let defaulted = repo
        .interdiff(Some(other_change.clone()), None, &[])
        .expect("one side is enough");
    let explicit = repo
        .interdiff(Some(other_change), Some(wc), &[])
        .expect("the explicit spelling succeeds");
    assert_eq!(summary(&defaulted), summary(&explicit), "an absent `to` is `@`");
}

#[test]
fn interdiff_refuses_an_unknown_divergent_or_empty_revision() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let original = add_commit_off_root(&fx.path, "original");
    _ = add_divergent_twin(&fx.path, &original, "twin");
    let divergent = change_id_of(&fx.path, &original);
    let repo = open(&fx);
    let before = head_op_id(&repo);

    for (side, id) in [
        // NOT "zzzzzzzz" — that is a prefix of the ROOT commit's all-zero change id.
        ("unknown", ChangeId("nonexistentchangeid".to_owned())),
        // `resolve_single_rev` parity: two visible commits is ambiguous, and this verb refuses
        // rather than picking one — unlike `show`, which returns both.
        ("divergent", divergent),
        // An empty id would otherwise reach jj-lib's `panic!` on an empty hex prefix.
        ("empty", ChangeId(String::new())),
    ] {
        let expected = id.0.clone();
        let err = match repo.interdiff(Some(id), None, &[]) {
            Ok(changes) => panic!("the {side} id must be refused, got {changes:?}"),
            Err(e) => e,
        };
        assert!(
            matches!(&err, CommitViewError::ChangeNotFound { id } if *id == expected),
            "the {side} id must be refused with its own id echoed, got: {err:?}"
        );
    }

    assert_eq!(head_op_id(&repo), before);
}

#[test]
fn interdiff_never_reports_a_rename_even_where_show_does() {
    pin_env();
    let (_tmp, repo) = renamed_on_git_backend();
    let status = repo.status().expect("status");

    // The SAME pair `show` reports as one Renamed entry.
    let shown = repo.show(None).expect("show succeeds");
    assert_eq!(summary(&shown[0].file_changes), vec![("new_name.txt".to_owned(), "R")]);

    // `interdiff` passes NO copy records (`show_inter_diff`'s own `CopyRecords::default()`),
    // so the rename decomposes into an Added+Removed pair. That asymmetry is the CLI's.
    let changes = repo
        .interdiff(Some(status.parent_change_id), Some(status.working_copy_change_id), &[])
        .expect("interdiff succeeds");
    let mut labels = summary(&changes);
    labels.sort();
    assert_eq!(
        labels,
        vec![("new_name.txt".to_owned(), "A"), ("old_name.txt".to_owned(), "D")],
        "interdiff must never produce a Renamed/Copied entry"
    );
}
