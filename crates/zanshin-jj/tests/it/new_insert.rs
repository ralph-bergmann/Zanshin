// SPDX-License-Identifier: MIT

//! Story 9.48 — `Repo::new_change` with `-A`/`--insert-after` and `-B`/`--insert-before`, and its
//! parents deduplicated (I1): one witness per row of the I/O matrix, read back through jj-lib.
//!
//! Every repo is built in-test with Zanshin's own verbs on a non-colocated internal-git repo:
//! `A (a.txt) → B (b.txt) → C (c.txt) = @`, descriptions `A\n`, `B\n`, `C\n`. The CLI comparison
//! of the same rows lives in the parity oracle (`crates/zanshin-parity`).

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::backend::CommitId;
use jj_lib::commit::Commit;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::{RefName, WorkspaceName};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{Backend, ChangeId, MutateError, MutationResult, Repo};

use crate::revert::{assert_config_class, UNRESOLVABLE_ALIAS};

const ADVANCE_ALL: &str = "[experimental-advance-branches]\nenabled-branches = [\"*\"]\n";
const IMMUTABLE_B_MARK: &str = "[revset-aliases]\n\"immutable_heads()\" = \"b-mark\"\n";
const BAD_PATTERN: &str = "[experimental-advance-branches]\nenabled-branches = [\"glob:[\"]\n";

/// The base history and the handles a test needs.
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    repo: Repo,
    a: ChangeId,
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
    let (_workspace, repo) = load(root);
    let id = repo
        .view()
        .get_wc_commit_id(WorkspaceName::new("default"))
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

fn commit_id(root: &Path, id: &ChangeId) -> CommitId {
    commit(root, id).id().clone()
}

/// The change ids of `id`'s parents, in order.
fn parents(root: &Path, id: &ChangeId) -> Vec<ChangeId> {
    let (_workspace, repo) = load(root);
    commit(root, id)
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

fn root_change(root: &Path) -> ChangeId {
    let (_workspace, repo) = load(root);
    change_id(&repo.store().root_commit())
}

fn root_hex(root: &Path) -> String {
    let (_workspace, repo) = load(root);
    repo.store().root_commit_id().hex()
}

/// `A (a.txt) → B (b.txt) → C (c.txt) = @` under an empty repo config.
fn base() -> Fx {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let main = tmp.path().join("main");
    fs::create_dir(&main).expect("main dir");
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&main),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init")
    .workspace_root()
    .to_owned();
    fs::write(root.join(".jj").join("repo").join("config.toml"), "").expect("repo config");
    let mut repo = Repo::open(&root).expect("open");
    let step = |repo: &mut Repo, path: &str, description: &str| -> ChangeId {
        fs::write(root.join(path), format!("{path}\n")).expect("write");
        let at = change_id(&wc(&root));
        repo.describe(at.clone(), description).expect("describe");
        at
    };
    let a = step(&mut repo, "a.txt", "A\n");
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    let b = step(&mut repo, "b.txt", "B\n");
    repo.new_change(std::slice::from_ref(&b), &[], &[]).expect("new");
    let c = step(&mut repo, "c.txt", "C\n");
    let _ = repo.take_warnings();
    Fx {
        _tmp: tmp,
        root,
        repo,
        a,
        b,
        c,
    }
}

/// Rewrites the repo config (through the legacy file's link) and reopens the handle.
fn set_repo_config(fx: &mut Fx, repo_config: &str) {
    fs::write(fx.root.join(".jj").join("repo").join("config.toml"), repo_config).expect("repo config");
    fx.repo = Repo::open(&fx.root).expect("reopen");
    let _ = fx.repo.take_warnings();
}

fn mark(fx: &mut Fx, name: &str, at: &ChangeId) {
    fx.repo.bookmark_create(&[name.to_owned()], Some(at)).expect("bookmark");
}

/// A new described change on `parent` — `@` afterwards.
fn described_child(fx: &mut Fx, parent: &ChangeId, description: &str) -> ChangeId {
    let id = fx
        .repo
        .new_change(std::slice::from_ref(parent), &[], &[])
        .expect("new")
        .new_change_ids[0]
        .clone();
    fx.repo.describe(id.clone(), description).expect("describe");
    id
}

/// The one minted change, checked for being the new `@` and the op being `new empty commit`.
fn assert_new(fx: &Fx, result: &MutationResult) -> ChangeId {
    let [n] = result.new_change_ids.as_slice() else {
        panic!("one minted change: {result:?}");
    };
    assert_eq!(result.working_copy_change_id.as_ref(), Some(n));
    assert_eq!(change_id(&wc(&fx.root)), *n, "@ is the new change");
    assert_eq!(head_op(&fx.root).1, "new empty commit");
    let new = commit(&fx.root, n);
    assert_eq!(new.description(), "");
    n.clone()
}

fn refused(fx: &mut Fx, parents: &[ChangeId], after: &[ChangeId], before: &[ChangeId]) -> MutateError {
    let before_op = head_op(&fx.root);
    let err = fx.repo.new_change(parents, after, before).expect_err("refused");
    assert_eq!(head_op(&fx.root), before_op, "a refusal writes no operation");
    err
}

#[test]
fn insert_after_rebases_every_child_of_the_target() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    let s = described_child(&mut fx, &b, "S\n");

    let result = fx.repo.new_change(&[], std::slice::from_ref(&b), &[]).expect("new -A");

    let n = assert_new(&fx, &result);
    assert_eq!(parents(&fx.root, &n), [b]);
    assert_eq!(parents(&fx.root, &c), std::slice::from_ref(&n));
    assert_eq!(parents(&fx.root, &s), [n]);
}

/// A merge child whose parents are ALL new parents collapses onto the new change once.
#[test]
fn insert_after_collapses_a_merge_child_onto_the_new_change() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    let s = described_child(&mut fx, &a, "S\n");
    let merge = fx
        .repo
        .new_change(&[b.clone(), s.clone()], &[], &[])
        .expect("merge")
        .new_change_ids[0]
        .clone();
    fx.repo.describe(merge.clone(), "M\n").expect("describe");

    let result = fx
        .repo
        .new_change(&[], &[b.clone(), s.clone()], &[])
        .expect("new -A B -A S");

    let new = assert_new(&fx, &result);
    assert_eq!(parents(&fx.root, &new), [b, s]);
    assert_eq!(parents(&fx.root, &merge), std::slice::from_ref(&new));
    assert_eq!(parents(&fx.root, &c), [new]);
}

/// Descendants of a rebased child follow it.
#[test]
fn insert_after_rebases_the_descendants_of_a_child() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());

    let result = fx
        .repo
        .new_change(&[], std::slice::from_ref(&a), &[])
        .expect("new -A A");

    let n = assert_new(&fx, &result);
    assert_eq!(parents(&fx.root, &n), [a]);
    assert_eq!(parents(&fx.root, &b), [n]);
    assert_eq!(parents(&fx.root, &c), [b]);
}

#[test]
fn insert_before_puts_the_new_change_under_the_target() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());

    let result = fx.repo.new_change(&[], &[], std::slice::from_ref(&c)).expect("new -B");

    let n = assert_new(&fx, &result);
    assert_eq!(parents(&fx.root, &n), [b]);
    assert_eq!(parents(&fx.root, &c), [n]);
}

/// The help example (`new.rs:135-145`): `-A A -B D` on `A-B-C-D` makes D a merge of C and N.
#[test]
fn insert_after_and_before_keeps_the_other_parents_of_the_child() {
    let mut fx = base();
    let c = fx.c.clone();
    let d = described_child(&mut fx, &c, "D\n");
    let (b_id, c_id) = (commit_id(&fx.root, &fx.b), commit_id(&fx.root, &c));

    let result = fx
        .repo
        .new_change(&[], std::slice::from_ref(&fx.a), std::slice::from_ref(&d))
        .expect("new -A -B");

    let new = assert_new(&fx, &result);
    assert_eq!(parents(&fx.root, &new), std::slice::from_ref(&fx.a));
    assert_eq!(parents(&fx.root, &d), [c.clone(), new]);
    assert_eq!(commit_id(&fx.root, &fx.b), b_id, "B unchanged");
    assert_eq!(commit_id(&fx.root, &c), c_id, "C unchanged");
}

#[test]
fn insert_after_a_head_rebases_nothing() {
    let mut fx = base();
    let c = fx.c.clone();
    let c_id = commit_id(&fx.root, &c);

    let result = fx.repo.new_change(&[], std::slice::from_ref(&c), &[]).expect("new -A");

    let n = assert_new(&fx, &result);
    assert_eq!(parents(&fx.root, &n), std::slice::from_ref(&c));
    assert_eq!(commit_id(&fx.root, &c), c_id);
}

#[test]
fn insert_after_advances_no_bookmark() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    mark(&mut fx, "a-mark", &a);
    mark(&mut fx, "b-mark", &b);
    set_repo_config(&mut fx, ADVANCE_ALL);

    fx.repo.new_change(&[], std::slice::from_ref(&b), &[]).expect("new -A");

    assert_eq!(bookmark(&fx.root, "a-mark"), Some(a));
    assert_eq!(bookmark(&fx.root, "b-mark"), Some(b));
}

#[test]
fn insert_before_advances_no_bookmark() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    mark(&mut fx, "a-mark", &a);
    mark(&mut fx, "b-mark", &b);
    set_repo_config(&mut fx, ADVANCE_ALL);

    fx.repo.new_change(&[], &[], std::slice::from_ref(&c)).expect("new -B");

    assert_eq!(bookmark(&fx.root, "a-mark"), Some(a));
    assert_eq!(bookmark(&fx.root, "b-mark"), Some(b));
}

/// `-A`/`-B` never read `experimental-advance-branches`: a pattern that does not parse is ignored.
#[test]
fn insert_never_reads_the_advance_config() {
    let mut fx = base();
    let b = fx.b.clone();
    set_repo_config(&mut fx, BAD_PATTERN);

    let result = fx.repo.new_change(&[], std::slice::from_ref(&b), &[]).expect("new -A");

    let n = assert_new(&fx, &result);
    assert_eq!(parents(&fx.root, &n), [b]);
}

/// I1: duplicate parents collapse to one, so the one-parent advance runs.
#[test]
fn duplicate_parents_are_one_parent_and_advance() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    mark(&mut fx, "b-mark", &b);
    set_repo_config(&mut fx, ADVANCE_ALL);

    let result = fx.repo.new_change(&[c.clone(), c.clone()], &[], &[]).expect("new C C");

    let n = assert_new(&fx, &result);
    assert_eq!(parents(&fx.root, &n), std::slice::from_ref(&c));
    assert_eq!(bookmark(&fx.root, "b-mark"), Some(c));
}

#[test]
fn duplicate_insert_after_ids_are_one_target() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());

    let result = fx
        .repo
        .new_change(&[], &[b.clone(), b.clone()], &[])
        .expect("new -A B -A B");

    let n = assert_new(&fx, &result);
    assert_eq!(parents(&fx.root, &n), [b]);
    assert_eq!(parents(&fx.root, &c), [n]);
}

#[test]
fn insert_after_refuses_an_immutable_child() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    mark(&mut fx, "b-mark", &b);
    set_repo_config(&mut fx, IMMUTABLE_B_MARK);
    let b_hex = commit_id(&fx.root, &b).hex();

    let err = refused(&mut fx, &[], std::slice::from_ref(&a), &[]);

    assert!(
        matches!(&err, MutateError::Immutable { commit_id, .. } if *commit_id == b_hex),
        "{err:?}"
    );
}

/// Story 9.56: a plain `new` resolves the immutable set too — in the CLI's `tx.finish`
/// (`rebase_mutable_descendants`, `cli_util.rs:2855` @ v0.46.0) — so an unresolvable alias refuses
/// `-A` and a positional `new` alike, both with no operation (`refused` checks the op log).
#[test]
fn every_new_resolves_the_immutable_set() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    set_repo_config(&mut fx, "[revset-aliases]\n\"immutable_heads()\" = \"no-such-mark\"\n");

    let err = refused(&mut fx, &[], std::slice::from_ref(&b), &[]);
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");

    let err = refused(&mut fx, std::slice::from_ref(&c), &[], &[]);
    assert!(matches!(err, MutateError::Config { .. }), "plain new: {err:?}");
}

/// `-A` on a leaf (no child to rewrite) still refuses an unresolvable alias, as `jj new -A` does:
/// the CLI resolves the set again in `tx.finish` (`rebase_mutable_descendants`, `cli_util.rs:2855`
/// @ v0.46.0), so it refuses `Config` with no operation even where `compute_commit_location`
/// skips the rewritability check (closing run of the Story 9.31 matrix-rows run).
#[test]
fn insert_after_a_leaf_refuses_an_unresolvable_alias_like_the_cli() {
    let mut fx = base();
    let c = fx.c.clone();
    set_repo_config(&mut fx, "[revset-aliases]\n\"immutable_heads()\" = \"no-such-mark\"\n");

    let err = refused(&mut fx, &[], std::slice::from_ref(&c), &[]);
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");
}

/// The CLI's order with both an unresolvable alias and a broken `templates.new_description`
/// (Story 9.18 follow-up): the template parse refuses first unless the location has children,
/// whose rewritability check resolves the immutable set; with only the alias broken, the finish
/// refuses. `refused` checks that no operation is written.
#[test]
fn a_broken_template_refuses_before_the_alias_unless_the_location_has_children() {
    let mut fx = base();
    let (a, c) = (fx.a.clone(), fx.c.clone());
    set_repo_config(
        &mut fx,
        &format!("{UNRESOLVABLE_ALIAS}[templates]\nnew_description = '\"undo \" ++'\n"),
    );
    let one = |id: &ChangeId| vec![id.clone()];
    for (parents, after, before, template) in [
        (one(&c), vec![], vec![], true),
        (vec![], one(&c), vec![], true),
        (vec![], one(&a), vec![], false),
        (vec![], vec![], one(&c), false),
    ] {
        let err = refused(&mut fx, &parents, &after, &before);
        assert_config_class(&err, template, &format!("{parents:?} -A {after:?} -B {before:?}"));
    }

    set_repo_config(&mut fx, UNRESOLVABLE_ALIAS);
    let err = refused(&mut fx, std::slice::from_ref(&c), &[], &[]);
    assert_config_class(&err, false, "only the alias broken");
}

#[test]
fn insert_before_the_root_is_refused_as_immutable() {
    let mut fx = base();
    let (root, hex) = (root_change(&fx.root), root_hex(&fx.root));

    let err = refused(&mut fx, &[], &[], std::slice::from_ref(&root));

    assert!(
        matches!(&err, MutateError::Immutable { commit_id, .. } if *commit_id == hex),
        "{err:?}"
    );
}

/// Story 9.31: a merge with the root commit among its parents is refused up front on a Git-backed
/// repo, with the Git backend's own text — whichever position the root takes — and nothing is
/// written. A single root parent (`[root, root]` deduplicates to it) stays a plain `new`.
#[test]
fn a_merge_with_the_root_is_refused_with_the_git_backend_text() {
    let mut fx = base();
    let (b, root) = (fx.b.clone(), root_change(&fx.root));

    for parents in [[b.clone(), root.clone()], [root.clone(), b.clone()]] {
        let err = refused(&mut fx, &parents, &[], &[]);
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason
                == "The Git backend does not support creating merge commits with the root commit as one of the parents."),
            "{err:?}"
        );
    }

    let result = fx
        .repo
        .new_change(&[root.clone(), root.clone()], &[], &[])
        .expect("new on root");
    let n = assert_new(&fx, &result);
    assert_eq!(parents(&fx.root, &n), [root]);
}

/// Story 9.31: `-B` computes the parents of its targets — `-B A` (a child of the root) together with
/// `-B E` (a child of D, another lineage) gives `[root, D]`, no loop and no immutable child — and
/// that root merge is refused up front with the Git backend's text, nothing written.
#[test]
fn an_insert_location_yielding_a_root_merge_is_refused_with_the_git_backend_text() {
    let mut fx = base();
    let (a, root) = (fx.a.clone(), root_change(&fx.root));
    let d = described_child(&mut fx, &root, "D\n");
    let e = described_child(&mut fx, &d, "E\n");

    let err = refused(&mut fx, &[], &[], &[a, e]);

    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason
            == "The Git backend does not support creating merge commits with the root commit as one of the parents."),
        "{err:?}"
    );
}

/// The CLI names the FIRST commit of `children::parents` as jj-lib streams it — the head of the
/// range, C here (checked against the pinned `jj new -A C -B A`), not A.
#[test]
fn a_loop_is_refused_with_the_cli_text() {
    let mut fx = base();
    let (a, c) = (fx.a.clone(), fx.c.clone());
    let c_hex = commit_id(&fx.root, &c).hex();

    let err = refused(&mut fx, &[], std::slice::from_ref(&c), std::slice::from_ref(&a));

    let MutateError::InvalidInput { reason, .. } = &err else {
        panic!("{err:?}");
    };
    assert_eq!(
        reason,
        &format!(
            "Refusing to create a loop: commit {} would be both an ancestor and a descendant of the new commit",
            &c_hex[..12]
        )
    );
}

/// Positional parents conflict with `-A`/`-B` before anything resolves (clap refuses first).
#[test]
fn parents_with_an_insert_list_are_refused_before_resolution() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    let bogus = ChangeId("y".repeat(32));

    let err = refused(&mut fx, std::slice::from_ref(&c), std::slice::from_ref(&b), &[]);
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    let err = refused(&mut fx, std::slice::from_ref(&c), &[], std::slice::from_ref(&bogus));
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
}

#[test]
fn three_empty_lists_are_refused() {
    let mut fx = base();
    let err = refused(&mut fx, &[], &[], &[]);
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
}

#[test]
fn an_unknown_insert_id_is_not_found() {
    let mut fx = base();
    let bogus = ChangeId("y".repeat(32));

    let err = refused(&mut fx, &[], std::slice::from_ref(&bogus), &[]);
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");
    let err = refused(&mut fx, &[], &[], std::slice::from_ref(&bogus));
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");
}
