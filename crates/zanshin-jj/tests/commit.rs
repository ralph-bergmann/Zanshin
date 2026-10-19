// SPDX-License-Identifier: MIT

//! Story 9.49 — `Repo::commit`, one witness per row of the I/O matrix, read back through
//! jj-lib.
//!
//! Every repo is built in-test with Zanshin's own verbs on a non-colocated internal-git repo:
//! `A (a.txt) → B (b.txt) → C (c.txt) = @`, descriptions `A\n`, `B\n`, `C\n`. The CLI comparison
//! of the same rows lives in the parity oracle (`crates/zanshin-parity`).

use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};
use std::{env, fs};

use jj_lib::commit::Commit;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::{RefName, WorkspaceName};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{Backend, ChangeId, CommitOptions, MutateError, MutationResult, Repo, WarningKind};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: every test calls `pin_env()` FIRST; the `LazyLock` blocks them all until this
    // initialiser returns, so no test body has read the environment yet.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", test_helpers::leaked_xdg_config_home());
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// The base history and the handles a test needs.
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    repo: Repo,
    b: ChangeId,
    c: ChangeId,
}

fn load(root: &Path) -> (Workspace, Arc<ReadonlyRepo>) {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load workspace");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load head");
    (workspace, repo)
}

/// `@` of the default workspace.
fn wc(root: &Path) -> Commit {
    wc_of(root, "default")
}

fn wc_of(root: &Path, name: &str) -> Commit {
    let (_workspace, repo) = load(root);
    let id = repo
        .view()
        .get_wc_commit_id(WorkspaceName::new(name))
        .expect("workspace has an @")
        .clone();
    repo.store().get_commit(&id).expect("@ commit")
}

fn change_id(commit: &Commit) -> ChangeId {
    ChangeId(commit.change_id().reverse_hex())
}

/// The ONE visible commit of `id`.
fn commit(root: &Path, id: &ChangeId) -> Commit {
    let (_workspace, repo) = load(root);
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0).expect("reverse hex");
    let targets = pollster::block_on(repo.resolve_change_id(&jj_id))
        .expect("index")
        .expect("known change");
    let visible = targets.into_visible().expect("visible");
    let [commit_id] = visible.as_slice() else {
        panic!("divergent {id:?}");
    };
    repo.store().get_commit(commit_id).expect("commit")
}

/// The repo paths a commit's tree holds, sorted.
fn files(commit: &Commit) -> Vec<String> {
    let mut paths: Vec<String> = commit
        .tree()
        .entries()
        .map(|(path, _)| path.as_internal_file_string().to_owned())
        .collect();
    paths.sort();
    paths
}

fn parents(root: &Path, commit: &Commit) -> Vec<ChangeId> {
    let (_workspace, repo) = load(root);
    commit
        .parent_ids()
        .iter()
        .map(|id| change_id(&repo.store().get_commit(id).expect("parent")))
        .collect()
}

fn head_op(root: &Path) -> (String, String) {
    let (_workspace, repo) = load(root);
    (repo.op_id().hex(), repo.operation().metadata().description.clone())
}

fn bookmark(root: &Path, name: &str) -> Option<ChangeId> {
    let (_workspace, repo) = load(root);
    let target = repo.view().get_local_bookmark(RefName::new(name)).as_normal()?.clone();
    Some(change_id(&repo.store().get_commit(&target).expect("bookmark target")))
}

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|&v| v.to_owned()).collect()
}

fn options(paths: &[&str], message: &[&str]) -> CommitOptions {
    CommitOptions {
        paths: strings(paths),
        message: strings(message),
    }
}

/// `A (a.txt) → B (b.txt) → C (c.txt) = @`, with `repo_config` as the legacy repo config
/// (migrated by the start-up fix-up).
fn base_with(repo_config: &str) -> Fx {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let main = tmp.path().join("main");
    fs::create_dir(&main).expect("main dir");
    let root = Repo::init(&main, Some(Backend::Git))
        .result
        .expect("init")
        .workspace_root()
        .to_owned();
    fs::write(root.join(".jj").join("repo").join("config.toml"), repo_config).expect("repo config");
    let mut repo = Repo::open(&root).expect("open");
    let step = |repo: &mut Repo, path: &str, description: &str| -> ChangeId {
        fs::write(root.join(path), format!("{path}\n")).expect("write");
        let at = change_id(&wc(&root));
        repo.describe(at.clone(), description).expect("describe");
        at
    };
    let a = step(&mut repo, "a.txt", "A\n");
    repo.new_change(std::slice::from_ref(&a)).expect("new");
    let b = step(&mut repo, "b.txt", "B\n");
    repo.new_change(std::slice::from_ref(&b)).expect("new");
    let c = step(&mut repo, "c.txt", "C\n");
    let _ = repo.take_warnings();
    Fx {
        _tmp: tmp,
        root,
        repo,
        b,
        c,
    }
}

fn base() -> Fx {
    base_with("")
}

/// The committed `@` (`fx.c`) and the new `@`, checked for the shape every commit has: the new
/// `@` is a child of the committed one, holds the old `@`'s full tree, is undescribed, and is
/// the one minted change.
fn assert_committed(fx: &Fx, result: &MutationResult, old_tree: &Commit) -> (Commit, Commit) {
    let committed = commit(&fx.root, &fx.c);
    let at = wc(&fx.root);
    assert_eq!(
        parents(&fx.root, &at),
        std::slice::from_ref(&fx.c),
        "the new @ sits on the committed @"
    );
    assert_eq!(
        at.tree().tree_ids(),
        old_tree.tree().tree_ids(),
        "the new @ holds the old @'s tree"
    );
    assert_eq!(at.description(), "");
    assert_eq!(result.new_change_ids, [change_id(&at)]);
    assert!(result.abandoned_change_ids.is_empty());
    assert_eq!(result.working_copy_change_id, change_id(&at));
    (committed, at)
}

#[test]
fn commit_everything_describes_at_and_puts_a_new_empty_at_on_it() {
    let mut fx = base();
    let old = wc(&fx.root);

    let result = fx.repo.commit(&options(&[], &["first"])).expect("commit");

    let (committed, at) = assert_committed(&fx, &result, &old);
    assert_eq!(committed.description(), "first\n");
    assert_eq!(
        committed.tree().tree_ids(),
        old.tree().tree_ids(),
        "everything is selected"
    );
    assert_eq!(parents(&fx.root, &committed), std::slice::from_ref(&fx.b));
    assert_eq!(at.tree().tree_ids(), committed.tree().tree_ids(), "the new @ is empty");
    let (op_id, description) = head_op(&fx.root);
    assert_eq!(description, format!("commit {}", old.id().hex()));
    assert_eq!(result.new_op_id.0, op_id);
    assert!(fx.repo.take_warnings().is_empty());
}

/// The spec's golden example: the selection starts from `@`'s PARENT tree.
#[test]
fn commit_of_two_paths_keeps_them_and_moves_the_rest_to_the_new_at() {
    let mut fx = base();
    for name in ["x.txt", "y.txt", "z.txt"] {
        fs::write(fx.root.join(name), format!("{name}\n")).expect("write");
    }

    let result = fx
        .repo
        .commit(&options(&["x.txt", "y.txt"], &["first"]))
        .expect("commit");

    let old = wc(&fx.root);
    let (committed, at) = assert_committed(&fx, &result, &old);
    assert_eq!(
        files(&committed),
        ["a.txt", "b.txt", "x.txt", "y.txt"],
        "c.txt was not selected"
    );
    assert_eq!(files(&at), ["a.txt", "b.txt", "c.txt", "x.txt", "y.txt", "z.txt"]);
    assert_eq!(committed.description(), "first\n");
    assert!(fx.repo.take_warnings().is_empty());
}

#[test]
fn commit_of_a_directory_prefix_selects_everything_under_it() {
    let mut fx = base();
    fs::create_dir(fx.root.join("dir")).expect("dir");
    fs::write(fx.root.join("dir").join("d.txt"), "d\n").expect("write");

    let result = fx.repo.commit(&options(&["dir"], &["dir only"])).expect("commit");

    let old = wc(&fx.root);
    let (committed, _) = assert_committed(&fx, &result, &old);
    assert_eq!(files(&committed), ["a.txt", "b.txt", "dir/d.txt"]);
}

#[test]
fn commit_with_an_empty_message_writes_an_empty_description() {
    for message in [&[""][..], &[][..]] {
        let mut fx = base();
        let result = fx.repo.commit(&options(&[], message)).expect("commit");
        let old_tree = commit(&fx.root, &fx.c);
        let (committed, _) = assert_committed(&fx, &result, &old_tree);
        assert_eq!(committed.description(), "", "{message:?}");
    }
}

#[test]
fn commit_joins_several_message_paragraphs_like_the_cli() {
    let mut fx = base();
    fx.repo.commit(&options(&[], &["subject", "body"])).expect("commit");
    assert_eq!(commit(&fx.root, &fx.c).description(), "subject\n\nbody\n");
}

/// `test_commit_with_empty_description_from_cli`: an empty, undescribed `@` is rewritten, not
/// abandoned, and a new empty `@` goes on top of it.
#[test]
fn commit_of_an_empty_undescribed_at_keeps_it() {
    let mut fx = base();
    fx.repo.new_change(std::slice::from_ref(&fx.c)).expect("new");
    let empty = change_id(&wc(&fx.root));

    let result = fx.repo.commit(&options(&[], &[""])).expect("commit");

    let kept = commit(&fx.root, &empty);
    assert_eq!(kept.description(), "");
    assert_eq!(parents(&fx.root, &kept), std::slice::from_ref(&fx.c));
    let at = wc(&fx.root);
    assert_eq!(parents(&fx.root, &at), [empty]);
    assert_eq!(result.new_change_ids, [change_id(&at)]);
}

#[test]
fn commit_of_an_unmatched_path_warns_and_commits_nothing() {
    let mut fx = base();
    let old = wc(&fx.root);

    let result = fx.repo.commit(&options(&["nope.txt"], &["first"])).expect("commit");

    let warnings = fx.repo.take_warnings();
    let kinds: Vec<WarningKind> = warnings.iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::CommitPathsUnmatched]);
    assert_eq!(warnings[0].message, "The given paths do not match any file: nope.txt");
    let (committed, at) = assert_committed(&fx, &result, &old);
    assert_eq!(files(&committed), ["a.txt", "b.txt"], "the committed @ is empty");
    assert_eq!(committed.description(), "first\n");
    assert_eq!(files(&at), ["a.txt", "b.txt", "c.txt"], "the new @ holds every change");
}

#[test]
fn commit_of_an_unchanged_existing_path_warns_naming_every_path() {
    let mut fx = base();
    let old = wc(&fx.root);
    let result = fx
        .repo
        .commit(&options(&["a.txt", "b.txt"], &["first"]))
        .expect("commit");

    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0].kind, WarningKind::CommitPathsUnmatched);
    assert_eq!(
        warnings[0].message,
        "The given paths do not match any file: a.txt b.txt"
    );
    let (committed, _) = assert_committed(&fx, &result, &old);
    assert_eq!(files(&committed), ["a.txt", "b.txt"], "the committed @ is empty");
}

#[test]
fn a_bookmark_on_at_stays_on_the_committed_commit() {
    let mut fx = base();
    let c = fx.c.clone();
    fx.repo.bookmark_create(&strings(&["m"]), Some(&c)).expect("bookmark");

    fx.repo.commit(&options(&[], &["first"])).expect("commit");

    assert_eq!(bookmark(&fx.root, "m"), Some(fx.c.clone()));
}

#[test]
fn bookmarks_on_the_parent_advance_only_when_enabled() {
    // The default: nothing advances.
    let mut fx = base();
    let b = fx.b.clone();
    fx.repo
        .bookmark_create(&strings(&["b-mark"]), Some(&b))
        .expect("bookmark");
    fx.repo.commit(&options(&[], &["first"])).expect("commit");
    assert_eq!(bookmark(&fx.root, "b-mark"), Some(fx.b.clone()));

    // Enabled for every name: `b-mark` moves to the committed `@`, never the new one.
    let mut fx = base_with("[experimental-advance-branches]\nenabled-branches = [\"*\"]\n");
    let b = fx.b.clone();
    fx.repo
        .bookmark_create(&strings(&["b-mark"]), Some(&b))
        .expect("bookmark");
    fx.repo.commit(&options(&[], &["first"])).expect("commit");
    assert_eq!(bookmark(&fx.root, "b-mark"), Some(fx.c.clone()));

    // Disabled for that name: it stays.
    let mut fx =
        base_with("[experimental-advance-branches]\nenabled-branches = [\"*\"]\ndisabled-branches = [\"b-mark\"]\n");
    let b = fx.b.clone();
    fx.repo
        .bookmark_create(&strings(&["b-mark"]), Some(&b))
        .expect("bookmark");
    fx.repo.commit(&options(&[], &["first"])).expect("commit");
    assert_eq!(bookmark(&fx.root, "b-mark"), Some(fx.b.clone()));
}

#[test]
fn a_child_of_at_is_rebased_onto_the_committed_commit() {
    let mut fx = base();
    let child = fx
        .repo
        .new_change(std::slice::from_ref(&fx.c))
        .expect("new")
        .new_change_ids[0]
        .clone();
    // Not empty, so `edit` keeps it.
    fs::write(fx.root.join("d.txt"), "d\n").expect("write");
    fx.repo.edit(fx.c.clone()).expect("edit");
    fs::write(fx.root.join("x.txt"), "x\n").expect("write");

    let result = fx.repo.commit(&options(&["x.txt"], &["first"])).expect("commit");

    let committed = commit(&fx.root, &fx.c);
    let child = commit(&fx.root, &child);
    assert_eq!(parents(&fx.root, &child), std::slice::from_ref(&fx.c));
    // The rebase keeps the child's own diff (d.txt) over the committed commit, which lacks the
    // unselected c.txt.
    assert_eq!(files(&child), ["a.txt", "b.txt", "d.txt", "x.txt"]);
    assert_eq!(files(&committed), ["a.txt", "b.txt", "x.txt"]);
    let at = wc(&fx.root);
    assert_eq!(parents(&fx.root, &at), std::slice::from_ref(&fx.c));
    assert_eq!(result.working_copy_change_id, change_id(&at));
}

#[test]
fn every_workspace_on_at_edits_the_one_new_at() {
    let mut fx = base();
    let (second_fx, _) = test_helpers::add_workspace(&fx.root, "second");
    let mut second = Repo::open(&second_fx.path).expect("open second");
    second.edit(fx.c.clone()).expect("edit");
    let _ = fx.repo.take_warnings();

    let result = fx.repo.commit(&options(&[], &["first"])).expect("commit");

    assert_eq!(change_id(&wc(&fx.root)), result.new_change_ids[0]);
    assert_eq!(change_id(&wc_of(&fx.root, "second")), result.new_change_ids[0]);
}

fn assert_refused_without_an_operation(fx: &mut Fx, options: &CommitOptions) -> MutateError {
    let before = head_op(&fx.root);
    let err = fx.repo.commit(options).expect_err("refused");
    assert_eq!(head_op(&fx.root), before, "a refusal writes no operation");
    err
}

#[test]
fn a_workspace_without_at_is_refused() {
    let fx = base();
    {
        let (workspace, repo) = load(&fx.root);
        let mut tx = repo.start_transaction();
        pollster::block_on(tx.repo_mut().remove_workspace(workspace.workspace_name())).expect("remove @");
        pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
        pollster::block_on(tx.commit("test: remove working-copy commit")).expect("commit");
    }
    let mut fx = Fx {
        repo: Repo::open(&fx.root).expect("open"),
        ..fx
    };

    // The working-copy check comes before the path validation.
    let err = assert_refused_without_an_operation(&mut fx, &options(&["../x"], &["first"]));
    assert!(matches!(err, MutateError::NoWorkingCopy), "{err:?}");
}

#[test]
fn an_invalid_path_is_refused_before_the_transaction() {
    let mut fx = base();
    let err = assert_refused_without_an_operation(&mut fx, &options(&["/x"], &["first"]));
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
}

#[test]
fn a_bad_advance_pattern_or_value_is_refused() {
    let mut fx = base_with("[experimental-advance-branches]\nenabled-branches = [\"glob:[\"]\n");
    let err = assert_refused_without_an_operation(&mut fx, &options(&[], &["first"]));
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");

    let mut fx = base_with("[experimental-advance-branches]\nenabled-branches = \"*\"\n");
    let err = assert_refused_without_an_operation(&mut fx, &options(&[], &["first"]));
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.contains("enabled-branches")),
        "{err:?}"
    );

    // The path validation comes before the config read.
    let err = assert_refused_without_an_operation(&mut fx, &options(&["/x"], &["first"]));
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
}
