// SPDX-License-Identifier: MIT

//! Story 9.31 — `Repo::drop_actions` / `Repo::change_actions`: the I/O matrix of the spec, one
//! test per row, plus the agreement witnesses — for every row of a SHIPPED verb (squash, the merge
//! `new`, split and the seven card-menu rows), the verb run right after the query on the same
//! fixture answers exactly as the row said.
//!
//! The fixture is a non-colocated Git-backed repo built in-test with Zanshin's own verbs:
//! `root → A (a.txt) → B (b.txt, f) → C (c.txt)`, and `D (d.txt)` a second child of `A` (`@`),
//! descriptions `A\n` … `D\n`. `immutable_heads()` is set per test through the repo config.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::commit::Commit;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::RefTarget;
use jj_lib::ref_name::{RefName, WorkspaceName};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{
    ActionOutcome, ActionStatus, Backend, ChangeId, DropLocation, DropSource, DropVerb, MutateError, Repo,
    SplitOptions, SquashOptions,
};

const UNKNOWN: &str = "qpvuntsmwlqtpvuntsmwlqtpvuntsm";
const GIT_ROOT_MERGE: &str =
    "The Git backend does not support creating merge commits with the root commit as one of the parents.";
const SPLIT_NO_PATHS: &str =
    "split needs at least one path: the interactive selection the CLI opens without paths is not supported";

struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    repo: Repo,
    a: ChangeId,
    b: ChangeId,
    c: ChangeId,
    d: ChangeId,
    zero: ChangeId,
}

fn load(root: &Path) -> Arc<ReadonlyRepo> {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load workspace");
    pollster::block_on(workspace.repo_loader().load_at_head()).expect("load head")
}

fn change_id(commit: &Commit) -> ChangeId {
    ChangeId(commit.change_id().reverse_hex())
}

fn wc(root: &Path) -> ChangeId {
    let repo = load(root);
    let id = repo
        .view()
        .get_wc_commit_id(WorkspaceName::new("default"))
        .expect("@")
        .clone();
    change_id(&repo.store().get_commit(&id).expect("@ commit"))
}

/// The full hex commit id of `id`'s one visible commit.
fn hex(root: &Path, id: &ChangeId) -> String {
    let repo = load(root);
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0).expect("reverse hex");
    let targets = pollster::block_on(repo.resolve_change_id(&jj_id))
        .expect("index")
        .expect("known change");
    let visible = targets.into_visible().expect("visible");
    let [commit_id] = visible.as_slice() else {
        panic!("divergent {id:?}");
    };
    commit_id.hex()
}

fn head_op(root: &Path) -> String {
    load(root).op_id().hex()
}

/// The base history; `immutable` names the change `immutable_heads()` is set to, if any.
fn base(immutable: Option<fn(&Fx) -> &ChangeId>) -> Fx {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let main = tmp.path().join("main");
    fs::create_dir(&main).expect("main dir");
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: main,
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
    let step = |repo: &mut Repo, paths: &[&str], description: &str| -> ChangeId {
        for path in paths {
            fs::write(root.join(path), format!("{path}\n")).expect("write");
        }
        let at = wc(&root);
        repo.describe(at.clone(), description).expect("describe");
        at
    };
    let a = step(&mut repo, &["a.txt"], "A\n");
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    let b = step(&mut repo, &["b.txt", "f"], "B\n");
    repo.new_change(std::slice::from_ref(&b), &[], &[]).expect("new");
    let c = step(&mut repo, &["c.txt"], "C\n");
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    let d = step(&mut repo, &["d.txt"], "D\n");
    let zero = change_id(&load(&root).store().root_commit());
    let mut fx = Fx {
        _tmp: tmp,
        root,
        repo,
        a,
        b,
        c,
        d,
        zero,
    };
    if let Some(pick) = immutable {
        let config = format!("[revset-aliases]\n\"immutable_heads()\" = \"{}\"\n", pick(&fx).0);
        fs::write(fx.root.join(".jj").join("repo").join("config.toml"), config).expect("repo config");
        fx.repo = Repo::open(&fx.root).expect("reopen");
    }
    let _ = fx.repo.take_warnings();
    fx
}

fn onto(ids: &[&ChangeId]) -> DropLocation {
    DropLocation {
        onto: ids.iter().map(|id| (*id).clone()).collect(),
        ..DropLocation::default()
    }
}

fn after(ids: &[&ChangeId]) -> DropLocation {
    DropLocation {
        insert_after: ids.iter().map(|id| (*id).clone()).collect(),
        ..DropLocation::default()
    }
}

fn before(ids: &[&ChangeId]) -> DropLocation {
    DropLocation {
        insert_before: ids.iter().map(|id| (*id).clone()).collect(),
        ..DropLocation::default()
    }
}

/// An outcome in comparable form: status, the refusal's `Debug`, the two flags.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Row {
    status: ActionStatus,
    refusal: Option<String>,
    combined: bool,
    backwards: bool,
}

fn row(outcome: &ActionOutcome) -> Row {
    Row {
        status: outcome.status,
        refusal: outcome.refusal.as_ref().map(|e| format!("{e:?}")),
        combined: outcome.combined_description_needed,
        backwards: outcome.allow_backwards_needed,
    }
}

fn available() -> Row {
    Row {
        status: ActionStatus::Available,
        refusal: None,
        combined: false,
        backwards: false,
    }
}

fn combined() -> Row {
    Row {
        combined: true,
        ..available()
    }
}

fn backwards() -> Row {
    Row {
        backwards: true,
        ..available()
    }
}

fn no_op() -> Row {
    Row {
        status: ActionStatus::NoOp,
        ..available()
    }
}

fn refused(e: &MutateError) -> Row {
    Row {
        status: ActionStatus::Refused,
        refusal: Some(format!("{e:?}")),
        ..available()
    }
}

fn invalid(reason: impl Into<String>) -> MutateError {
    MutateError::InvalidInput { reason: reason.into() }
}

fn imm(fx: &Fx, id: &ChangeId) -> MutateError {
    MutateError::Immutable {
        commit_id: hex(&fx.root, id),
    }
}

fn not_found(id: &str) -> MutateError {
    MutateError::ChangeNotFound { id: id.to_owned() }
}

fn short(fx: &Fx, id: &ChangeId) -> String {
    hex(&fx.root, id)[..12].to_owned()
}

/// Runs the query, checks it wrote no operation and left no warning, and returns its rows.
fn query(fx: &mut Fx, source: &DropSource, locations: &[DropLocation]) -> Vec<(DropVerb, usize, Row)> {
    let before = head_op(&fx.root);
    let actions = fx.repo.drop_actions(source, locations).expect("drop_actions");
    assert_eq!(head_op(&fx.root), before, "the query writes no operation");
    assert!(fx.repo.take_warnings().is_empty(), "row warnings are discarded");
    actions
        .actions
        .iter()
        .map(|a| (a.verb, a.location, row(&a.outcome)))
        .collect()
}

fn change(id: &ChangeId) -> DropSource {
    DropSource::Change(id.clone())
}

#[test]
fn a_change_dropped_onto_its_parent() {
    let mut fx = base(None);
    let (a, b) = (fx.a.clone(), fx.b.clone());
    let rows = query(&mut fx, &change(&b), &[onto(&[&a])]);
    assert_eq!(
        rows,
        vec![
            (DropVerb::RebaseSource, 0, no_op()),
            (DropVerb::RebaseRevisions, 0, available()),
            (DropVerb::Squash, 0, combined()),
            (DropVerb::NewMerge, 0, available()),
            (DropVerb::Duplicate, 0, available()),
        ]
    );
}

/// `D` is a leaf on `A`: `-r` moves nothing either (no children to rebase), so both rebase rows
/// are no-ops.
#[test]
fn a_leaf_dropped_onto_its_parent_is_a_no_op_for_both_rebase_rows() {
    let mut fx = base(None);
    let (a, d) = (fx.a.clone(), fx.d.clone());
    let rows = query(&mut fx, &change(&d), &[onto(&[&a])]);
    assert_eq!(
        rows,
        vec![
            (DropVerb::RebaseSource, 0, no_op()),
            (DropVerb::RebaseRevisions, 0, no_op()),
            (DropVerb::Squash, 0, combined()),
            (DropVerb::NewMerge, 0, available()),
            (DropVerb::Duplicate, 0, available()),
        ]
    );
}

#[test]
fn a_change_dropped_onto_its_descendant() {
    let mut fx = base(None);
    let (b, c) = (fx.b.clone(), fx.c.clone());
    let descendant = invalid(format!(
        "Cannot rebase {} onto descendant {}",
        short(&fx, &b),
        short(&fx, &c)
    ));
    let rows = query(&mut fx, &change(&b), &[onto(&[&c])]);
    assert_eq!(
        rows,
        vec![
            (DropVerb::RebaseSource, 0, refused(&descendant)),
            (DropVerb::RebaseRevisions, 0, available()),
            (DropVerb::Squash, 0, combined()),
            (DropVerb::NewMerge, 0, available()),
            (DropVerb::Duplicate, 0, available()),
        ]
    );
}

#[test]
fn a_change_dropped_onto_itself() {
    let mut fx = base(None);
    let b = fx.b.clone();
    let itself = invalid(format!("Cannot rebase {} onto itself", short(&fx, &b)));
    let rows = query(&mut fx, &change(&b), &[onto(&[&b])]);
    assert_eq!(
        rows,
        vec![
            (DropVerb::RebaseSource, 0, refused(&itself)),
            (DropVerb::RebaseRevisions, 0, refused(&itself)),
            (DropVerb::Squash, 0, no_op()),
            (DropVerb::NewMerge, 0, available()),
            (DropVerb::Duplicate, 0, available()),
        ]
    );
}

#[test]
fn a_change_dropped_onto_the_root() {
    let mut fx = base(None);
    let (b, zero) = (fx.b.clone(), fx.zero.clone());
    let root_imm = imm(&fx, &zero);
    let rows = query(&mut fx, &change(&b), &[onto(&[&zero])]);
    assert_eq!(
        rows,
        vec![
            (DropVerb::RebaseSource, 0, available()),
            (DropVerb::RebaseRevisions, 0, available()),
            (DropVerb::Squash, 0, refused(&root_imm)),
            (DropVerb::NewMerge, 0, refused(&invalid(GIT_ROOT_MERGE))),
            (DropVerb::Duplicate, 0, available()),
        ]
    );
}

#[test]
fn an_immutable_change_dropped_elsewhere() {
    let mut fx = base(Some(|fx| &fx.a));
    let (a, d) = (fx.a.clone(), fx.d.clone());
    let a_imm = imm(&fx, &a);
    let rows = query(&mut fx, &change(&a), &[onto(&[&d])]);
    assert_eq!(
        rows,
        vec![
            (DropVerb::RebaseSource, 0, refused(&a_imm)),
            (DropVerb::RebaseRevisions, 0, refused(&a_imm)),
            (DropVerb::Squash, 0, refused(&a_imm)),
            (DropVerb::NewMerge, 0, available()),
            (DropVerb::Duplicate, 0, available()),
        ]
    );
}

#[test]
fn the_root_dropped_onto_a_change() {
    let mut fx = base(None);
    let (a, zero) = (fx.a.clone(), fx.zero.clone());
    let root_imm = imm(&fx, &zero);
    let rows = query(&mut fx, &change(&zero), &[onto(&[&a])]);
    assert_eq!(
        rows,
        vec![
            (DropVerb::RebaseSource, 0, refused(&root_imm)),
            (DropVerb::RebaseRevisions, 0, refused(&root_imm)),
            (DropVerb::Squash, 0, refused(&root_imm)),
            (DropVerb::NewMerge, 0, refused(&invalid(GIT_ROOT_MERGE))),
            (
                DropVerb::Duplicate,
                0,
                refused(&invalid("Cannot duplicate the root commit"))
            ),
        ]
    );
}

/// A merge with the root among the new parents: the Git backend refuses the write, and every row
/// that would write it says so with the backend's text — the query itself succeeds.
#[test]
fn a_change_dropped_onto_the_root_and_another_change_refuses_the_root_merge() {
    let mut fx = base(None);
    let (b, d, zero) = (fx.b.clone(), fx.d.clone(), fx.zero.clone());
    let rows = query(&mut fx, &change(&b), &[onto(&[&zero, &d])]);
    let root_merge = refused(&invalid(GIT_ROOT_MERGE));
    assert_eq!(
        rows,
        vec![
            (DropVerb::RebaseSource, 0, root_merge.clone()),
            (DropVerb::RebaseRevisions, 0, root_merge.clone()),
            (DropVerb::NewMerge, 0, root_merge.clone()),
            (DropVerb::Duplicate, 0, root_merge),
        ]
    );
}

/// The plans of a squash row (unmatched path) and a split row (everything selected) record
/// warnings; the query discards them, while the verbs with the same arguments report them.
#[test]
fn a_rows_plan_warnings_are_discarded_but_the_verb_reports_them() {
    let mut fx = base(None);
    let (a, b) = (fx.a.clone(), fx.b.clone());
    let unmatched = DropSource::Selection {
        change: b.clone(),
        paths: vec!["nope".to_owned()],
    };
    let everything = DropSource::Selection {
        change: b.clone(),
        paths: vec!["b.txt".to_owned(), "f".to_owned()],
    };
    // `query` asserts that the call's warnings are empty.
    assert_eq!(query(&mut fx, &unmatched, &[onto(&[&a])]).len(), 1);
    assert_eq!(query(&mut fx, &everything, &[after(&[&a])]).len(), 1);

    fx.repo.squash(&squash_into(&b, &a, &["nope"])).expect("squash");
    let kinds: Vec<_> = fx.repo.take_warnings().into_iter().map(|w| w.kind).collect();
    assert!(kinds.contains(&zanshin_jj::WarningKind::PathsUnmatched), "{kinds:?}");
    let options = SplitOptions {
        revision: Some(b),
        paths: vec!["b.txt".to_owned(), "f".to_owned()],
        insert_after: Some(vec![a]),
        ..SplitOptions::default()
    };
    fx.repo.split(&options).expect("split");
    let kinds: Vec<_> = fx.repo.take_warnings().into_iter().map(|w| w.kind).collect();
    assert!(kinds.contains(&zanshin_jj::WarningKind::SplitAllSelected), "{kinds:?}");
}

/// A bad revset-alias entry warns in the precondition; both queries return exactly that warning,
/// while the rows that resolve the immutable set again record nothing more.
#[test]
fn the_preconditions_warnings_are_the_queries_warnings() {
    let mut fx = base(None);
    fs::write(
        fx.root.join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'bad(' = 'x'\n",
    )
    .expect("repo config");
    fx.repo = Repo::open(&fx.root).expect("reopen");
    let _ = fx.repo.take_warnings();
    let kinds = |repo: &mut Repo| -> Vec<_> { repo.take_warnings().into_iter().map(|w| w.kind).collect() };
    let (a, b) = (fx.a.clone(), fx.b.clone());

    fx.repo.status().expect("status");
    let expected = kinds(&mut fx.repo);
    assert_eq!(expected, [zanshin_jj::WarningKind::ConfigAliasInvalid]);
    fx.repo
        .drop_actions(&change(&b), &[onto(&[&a]), after(&[&a])])
        .expect("drop_actions");
    assert_eq!(kinds(&mut fx.repo), expected);
    fx.repo.change_actions(&b).expect("change_actions");
    assert_eq!(kinds(&mut fx.repo), expected);
}

/// With a signer that always fails, a rebase row's dry run still answers: the query's head
/// drops signing, while the verbs themselves sign (and fail) as configured.
#[test]
fn the_rebase_dry_run_never_invokes_the_signer() {
    let mut fx = base(None);
    fs::write(
        fx.root.join(".jj").join("repo").join("config.toml"),
        "[signing]\nbehavior = \"force\"\nbackend = \"ssh\"\nkey = \"none\"\n\n[signing.backends.ssh]\nprogram = \"false\"\n",
    )
    .expect("repo config");
    fx.repo = Repo::open(&fx.root).expect("reopen");
    let _ = fx.repo.take_warnings();
    let (a, b, d) = (fx.a.clone(), fx.b.clone(), fx.d.clone());

    let rows = query(&mut fx, &change(&b), &[onto(&[&d]), onto(&[&a])]);
    assert_eq!(
        rows.iter()
            .filter(|(verb, _, _)| matches!(verb, DropVerb::RebaseSource | DropVerb::RebaseRevisions))
            .map(|(verb, index, row)| (*verb, *index, row.status))
            .collect::<Vec<_>>(),
        [
            (DropVerb::RebaseSource, 0, ActionStatus::Available),
            (DropVerb::RebaseRevisions, 0, ActionStatus::Available),
            (DropVerb::RebaseSource, 1, ActionStatus::NoOp),
            (DropVerb::RebaseRevisions, 1, ActionStatus::Available),
        ]
    );
    assert!(
        fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).is_err(),
        "the signing config is live: a verb's write fails"
    );
}

#[test]
fn a_change_dropped_onto_two_targets_has_no_squash_row() {
    let mut fx = base(None);
    let (b, c, d) = (fx.b.clone(), fx.c.clone(), fx.d.clone());
    let verbs: Vec<DropVerb> = query(&mut fx, &change(&c), &[onto(&[&b, &d])])
        .into_iter()
        .map(|(verb, _, _)| verb)
        .collect();
    assert_eq!(
        verbs,
        [
            DropVerb::RebaseSource,
            DropVerb::RebaseRevisions,
            DropVerb::NewMerge,
            DropVerb::Duplicate
        ]
    );
}

#[test]
fn insert_locations_answer_one_rebase_revisions_row_each() {
    let mut fx = base(None);
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    let both = DropLocation {
        insert_after: vec![a.clone()],
        insert_before: vec![b.clone()],
        ..DropLocation::default()
    };
    let rows = query(&mut fx, &change(&c), &[after(&[&a]), before(&[&b]), both]);
    assert_eq!(
        rows,
        vec![
            (DropVerb::RebaseRevisions, 0, available()),
            (DropVerb::RebaseRevisions, 1, available()),
            (DropVerb::RebaseRevisions, 2, available()),
        ]
    );
}

#[test]
fn an_insert_location_with_an_immutable_child_or_a_loop_refuses() {
    let mut fx = base(Some(|fx| &fx.b));
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    let b_imm = imm(&fx, &b);
    let rows = query(&mut fx, &change(&c), &[after(&[&a])]);
    assert_eq!(rows, vec![(DropVerb::RebaseRevisions, 0, refused(&b_imm))]);

    let mut fx = base(None);
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    let looping = DropLocation {
        insert_after: vec![b],
        insert_before: vec![a],
        ..DropLocation::default()
    };
    let rows = query(&mut fx, &change(&c), &[looping]);
    let [(DropVerb::RebaseRevisions, 0, Row { status, refusal, .. })] = rows.as_slice() else {
        panic!("one rebase row: {rows:?}");
    };
    assert_eq!(*status, ActionStatus::Refused);
    let refusal = refusal.as_deref().expect("refusal");
    assert!(
        refusal.contains("Refusing to create a loop: commit ")
            && refusal.contains(" would be both an ancestor and a descendant of the rebased commits"),
        "{refusal}"
    );
}

#[test]
fn an_unknown_change_refuses_every_row_as_not_found() {
    let mut fx = base(None);
    let a = fx.a.clone();
    let unknown = ChangeId(UNKNOWN.to_owned());
    let rows = query(&mut fx, &change(&unknown), &[onto(&[&a])]);
    assert_eq!(rows.len(), 5);
    for (verb, _, row) in rows {
        assert_eq!(row, refused(&not_found(UNKNOWN)), "{verb:?}");
    }
    let rows = query(&mut fx, &change(&a), &[after(&[&unknown])]);
    assert_eq!(rows, vec![(DropVerb::RebaseRevisions, 0, refused(&not_found(UNKNOWN)))]);
}

#[test]
fn a_malformed_location_fails_the_whole_query_before_resolving() {
    let mut fx = base(None);
    let a = fx.a.clone();
    let unknown = ChangeId(UNKNOWN.to_owned());
    let both = DropLocation {
        onto: vec![unknown.clone()],
        insert_after: vec![a.clone()],
        ..DropLocation::default()
    };
    let before_op = head_op(&fx.root);
    let err = fx
        .repo
        .drop_actions(&change(&unknown), &[onto(&[&a]), both])
        .expect_err("refused");
    assert_eq!(
        format!("{err:?}"),
        format!(
            "{:?}",
            invalid("--onto cannot be combined with -A/--insert-after or -B/--insert-before")
        )
    );
    let err = fx
        .repo
        .drop_actions(&change(&a), &[DropLocation::default()])
        .expect_err("refused");
    assert_eq!(
        format!("{err:?}"),
        format!(
            "{:?}",
            invalid("expected at least one of --onto, -A/--insert-after or -B/--insert-before")
        )
    );
    assert_eq!(head_op(&fx.root), before_op);
    let none = fx.repo.drop_actions(&change(&a), &[]).expect("no locations");
    assert!(none.actions.is_empty());
}

#[test]
fn a_selection_squashes_onto_one_target_and_splits_at_an_insert_location() {
    let mut fx = base(None);
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    let selection = DropSource::Selection {
        change: b.clone(),
        paths: vec!["f".to_owned()],
    };
    let rows = query(&mut fx, &selection, &[onto(&[&a]), after(&[&a]), onto(&[&a, &c])]);
    assert_eq!(
        rows,
        vec![(DropVerb::Squash, 0, available()), (DropVerb::Split, 1, available())]
    );
    let everything = DropSource::Selection {
        change: b,
        paths: Vec::new(),
    };
    let rows = query(&mut fx, &everything, &[after(&[&a]), onto(&[&a])]);
    assert_eq!(
        rows,
        vec![
            (DropVerb::Split, 0, refused(&invalid(SPLIT_NO_PATHS))),
            // No paths squashes every path, as `--from B --into A` without paths does.
            (DropVerb::Squash, 1, combined()),
        ]
    );
}

#[test]
fn a_bookmark_moves_forward_backwards_or_nowhere() {
    let mut fx = base(None);
    let (a, b, c, d) = (fx.a.clone(), fx.b.clone(), fx.c.clone(), fx.d.clone());
    fx.repo
        .bookmark_create(&["mark".to_owned()], Some(&b))
        .expect("bookmark");
    let mark = DropSource::Bookmark("mark".to_owned());
    let rows = query(
        &mut fx,
        &mark,
        &[onto(&[&c]), onto(&[&d]), onto(&[&b]), after(&[&a]), onto(&[&c, &d])],
    );
    assert_eq!(
        rows,
        vec![
            (DropVerb::BookmarkMove, 0, available()),
            (DropVerb::BookmarkMove, 1, backwards()),
            (DropVerb::BookmarkMove, 2, no_op()),
        ]
    );
    let rows = query(&mut fx, &DropSource::Bookmark("nope".to_owned()), &[onto(&[&c])]);
    assert_eq!(rows, vec![(DropVerb::BookmarkMove, 0, no_op())]);
    let unknown = ChangeId(UNKNOWN.to_owned());
    let rows = query(&mut fx, &mark, &[onto(&[&unknown])]);
    assert_eq!(rows, vec![(DropVerb::BookmarkMove, 0, refused(&not_found(UNKNOWN)))]);
}

fn commit_id(fx: &Fx, change: &ChangeId) -> jj_lib::backend::CommitId {
    jj_lib::backend::CommitId::try_from_hex(hex(&fx.root, change)).expect("commit hex")
}

/// Sets `mark` to the conflicted `target` through jj-lib — no Zanshin verb creates a conflicted
/// bookmark — reopens `fx.repo` and checks that `mark` is conflicted with exactly `present_adds`.
fn conflict_mark(fx: &mut Fx, target: RefTarget, present_adds: &[&jj_lib::backend::CommitId]) {
    let mut tx = load(&fx.root).start_transaction();
    tx.repo_mut().set_local_bookmark_target(RefName::new("mark"), target);
    pollster::block_on(tx.commit("test: conflicted mark")).expect("commit");
    fx.repo = Repo::open(&fx.root).expect("reopen");
    let _ = fx.repo.take_warnings();
    let head = load(&fx.root);
    let target = head.view().get_local_bookmark(RefName::new("mark"));
    assert!(!target.is_resolved(), "mark is conflicted");
    assert_eq!(target.present_adds().collect::<Vec<_>>(), present_adds);
}

/// The CLI's `is_fast_forward` (`cli/src/commands/bookmark/mod.rs:165-182` @ v0.46.0) asks whether
/// ANY side of a conflicted bookmark is an ancestor of the new target, and `bookmark move`
/// (`cli/src/commands/bookmark/move.rs` @ v0.46.0) never skips a conflicted bookmark as already
/// there (`old.as_normal() != Some(target)`).
#[test]
fn a_conflicted_bookmark_moves_forward_when_any_side_is_an_ancestor() {
    let mut fx = base(None);
    let (a, c, d) = (fx.a.clone(), fx.c.clone(), fx.d.clone());
    let (a_id, b_id, d_id) = (commit_id(&fx, &a), commit_id(&fx, &fx.b), commit_id(&fx, &d));
    let target = RefTarget::from_legacy_form([a_id], [b_id.clone(), d_id.clone()]);
    conflict_mark(&mut fx, target, &[&b_id, &d_id]);
    let mark = DropSource::Bookmark("mark".to_owned());
    let rows = query(&mut fx, &mark, &[onto(&[&c]), onto(&[&d]), onto(&[&a])]);
    assert_eq!(
        rows,
        vec![
            // `B` is an ancestor of `C`, `D` is not — an "every side" rule would say backwards.
            (DropVerb::BookmarkMove, 0, available()),
            // `D` is one side itself — never a no-op while the target is conflicted.
            (DropVerb::BookmarkMove, 1, available()),
            // `A` is the parent of both sides — no side is an ancestor, so backwards.
            (DropVerb::BookmarkMove, 2, backwards()),
        ]
    );
}

/// A conflict with a deleted side (a concurrent delete vs. a move): only the present side counts,
/// an absent side makes no fast-forward.
#[test]
fn a_conflicted_bookmark_with_a_deleted_side_counts_only_the_present_side() {
    let mut fx = base(None);
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    let (a_id, b_id) = (commit_id(&fx, &a), commit_id(&fx, &b));
    let target = RefTarget::from_legacy_form([a_id], [b_id.clone()]);
    conflict_mark(&mut fx, target, &[&b_id]);
    let mark = DropSource::Bookmark("mark".to_owned());
    let rows = query(&mut fx, &mark, &[onto(&[&c]), onto(&[&b]), onto(&[&a])]);
    assert_eq!(
        rows,
        vec![
            (DropVerb::BookmarkMove, 0, available()),
            // `B` is the present side itself — never a no-op while the target is conflicted.
            (DropVerb::BookmarkMove, 1, available()),
            // The absent side is not an ancestor of anything — `A` stays backwards.
            (DropVerb::BookmarkMove, 2, backwards()),
        ]
    );
}

/// The seven card-menu rows in field order.
fn card(fx: &mut Fx, id: &ChangeId) -> [Row; 7] {
    let before = head_op(&fx.root);
    let actions = fx.repo.change_actions(id).expect("change_actions");
    assert_eq!(head_op(&fx.root), before, "the query writes no operation");
    assert!(fx.repo.take_warnings().is_empty(), "row warnings are discarded");
    [
        row(&actions.new_onto),
        row(&actions.new_insert_after),
        row(&actions.new_insert_before),
        row(&actions.edit),
        row(&actions.describe),
        row(&actions.squash_into_parent),
        row(&actions.abandon),
    ]
}

#[test]
fn change_actions_of_a_described_change_are_all_available() {
    let mut fx = base(None);
    let b = fx.b.clone();
    assert_eq!(
        card(&mut fx, &b),
        [
            available(),
            available(),
            available(),
            available(),
            available(),
            combined(),
            available()
        ]
    );
}

#[test]
fn change_actions_of_the_root_refuse_with_each_verbs_text() {
    let mut fx = base(None);
    let zero = fx.zero.clone();
    let root_imm = imm(&fx, &zero);
    assert_eq!(
        card(&mut fx, &zero),
        [
            available(),
            available(),
            refused(&root_imm),
            refused(&root_imm),
            refused(&invalid("cannot describe the root commit")),
            refused(&invalid("Cannot squash merge commits without a specified destination")),
            refused(&invalid("cannot abandon the root commit")),
        ]
    );
}

#[test]
fn change_actions_of_an_immutable_change_refuse_the_rewrites() {
    let mut fx = base(Some(|fx| &fx.b));
    let b = fx.b.clone();
    let b_imm = imm(&fx, &b);
    assert_eq!(
        card(&mut fx, &b),
        [
            available(),
            available(),
            refused(&b_imm),
            refused(&b_imm),
            refused(&b_imm),
            refused(&b_imm),
            refused(&b_imm),
        ]
    );
}

#[test]
fn change_actions_of_an_unknown_change_are_all_not_found() {
    let mut fx = base(None);
    let unknown = ChangeId(UNKNOWN.to_owned());
    for row in card(&mut fx, &unknown) {
        assert_eq!(row, refused(&not_found(UNKNOWN)));
    }
}

// ── Agreement: the shipped verb answers as its row said ─────────────────────────

/// Runs `verb` right after a query answered `expected`, on the same fixture: Available ⇒ Ok with
/// a new operation; `NoOp` ⇒ Ok with the head unchanged; `Refused` ⇒ the same error.
fn agree(fx: &mut Fx, expected: &Row, verb: impl FnOnce(&mut Repo) -> Result<(), MutateError>) {
    let before = head_op(&fx.root);
    let result = verb(&mut fx.repo);
    match expected.status {
        ActionStatus::Available => {
            result.expect("an Available row runs");
            assert_ne!(head_op(&fx.root), before, "an Available row writes an operation");
        }
        ActionStatus::NoOp => {
            result.expect("a NoOp row runs");
            assert_eq!(head_op(&fx.root), before, "a NoOp row writes no operation");
        }
        ActionStatus::Refused => {
            let err = result.expect_err("a Refused row refuses");
            assert_eq!(Some(format!("{err:?}")), expected.refusal);
            assert_eq!(head_op(&fx.root), before, "a refusal writes no operation");
        }
    }
}

/// The one row of `verb` a single-location query answers.
fn the_row(fx: &mut Fx, source: &DropSource, location: DropLocation, verb: DropVerb) -> Row {
    query(fx, source, &[location])
        .into_iter()
        .find_map(|(v, _, row)| (v == verb).then_some(row))
        .expect("the row")
}

fn squash_into(from: &ChangeId, into: &ChangeId, paths: &[&str]) -> SquashOptions {
    SquashOptions {
        from: vec![from.clone()],
        into: Some(into.clone()),
        paths: paths.iter().map(|p| (*p).to_owned()).collect(),
        ..SquashOptions::default()
    }
}

#[test]
fn squash_rows_agree_with_squash() {
    type Case = (
        Option<fn(&Fx) -> &ChangeId>,
        fn(&Fx) -> (DropSource, ChangeId, SquashOptions),
    );
    let cases: [Case; 5] = [
        (None, |fx| (change(&fx.b), fx.a.clone(), squash_into(&fx.b, &fx.a, &[]))),
        (None, |fx| (change(&fx.b), fx.b.clone(), squash_into(&fx.b, &fx.b, &[]))),
        (None, |fx| {
            (change(&fx.b), fx.zero.clone(), squash_into(&fx.b, &fx.zero, &[]))
        }),
        (Some(|fx| &fx.a), |fx| {
            (change(&fx.a), fx.d.clone(), squash_into(&fx.a, &fx.d, &[]))
        }),
        (None, |fx| {
            let selection = DropSource::Selection {
                change: fx.b.clone(),
                paths: vec!["f".to_owned()],
            };
            (selection, fx.a.clone(), squash_into(&fx.b, &fx.a, &["f"]))
        }),
    ];
    let mut statuses = Vec::new();
    for (immutable, case) in cases {
        let mut fx = base(immutable);
        let (source, target, options) = case(&fx);
        let expected = the_row(&mut fx, &source, onto(&[&target]), DropVerb::Squash);
        statuses.push(expected.status);
        agree(&mut fx, &expected, |repo| repo.squash(&options).map(drop));
    }
    assert_eq!(
        statuses,
        [
            ActionStatus::Available,
            ActionStatus::NoOp,
            ActionStatus::Refused,
            ActionStatus::Refused,
            ActionStatus::Available
        ]
    );
}

#[test]
fn new_merge_rows_agree_with_new_change() {
    type Case = fn(&Fx) -> (ChangeId, ChangeId);
    let cases: [Case; 3] = [
        |fx| (fx.b.clone(), fx.a.clone()),
        |fx| (fx.b.clone(), fx.zero.clone()),
        |fx| (ChangeId(UNKNOWN.to_owned()), fx.a.clone()),
    ];
    let mut statuses = Vec::new();
    for case in cases {
        let mut fx = base(None);
        let (source, target) = case(&fx);
        let expected = the_row(&mut fx, &change(&source), onto(&[&target]), DropVerb::NewMerge);
        statuses.push(expected.status);
        agree(&mut fx, &expected, |repo| {
            repo.new_change(&[target, source], &[], &[]).map(drop)
        });
    }
    assert_eq!(
        statuses,
        [ActionStatus::Available, ActionStatus::Refused, ActionStatus::Refused]
    );
}

#[test]
fn split_rows_agree_with_split() {
    for (paths, status) in [
        (vec!["f".to_owned()], ActionStatus::Available),
        (Vec::new(), ActionStatus::Refused),
    ] {
        let mut fx = base(None);
        let (a, b) = (fx.a.clone(), fx.b.clone());
        let selection = DropSource::Selection {
            change: b.clone(),
            paths: paths.clone(),
        };
        let expected = the_row(&mut fx, &selection, after(&[&a]), DropVerb::Split);
        assert_eq!(expected.status, status);
        let options = SplitOptions {
            revision: Some(b),
            paths,
            insert_after: Some(vec![a]),
            ..SplitOptions::default()
        };
        agree(&mut fx, &expected, |repo| repo.split(&options).map(drop));
    }
}

#[test]
fn change_actions_rows_agree_with_their_verbs() {
    type Verb = fn(&mut Repo, ChangeId) -> Result<(), MutateError>;
    let verbs: [Verb; 7] = [
        |repo, x| repo.new_change(&[x], &[], &[]).map(drop),
        |repo, x| repo.new_change(&[], &[x], &[]).map(drop),
        |repo, x| repo.new_change(&[], &[], &[x]).map(drop),
        |repo, x| repo.edit(x).map(drop),
        |repo, x| repo.describe(x, "described\n").map(drop),
        |repo, x| {
            repo.squash(&SquashOptions {
                revision: Some(x),
                ..SquashOptions::default()
            })
            .map(drop)
        },
        |repo, x| repo.abandon(&[x]).map(drop),
    ];
    let pick_b: fn(&Fx) -> ChangeId = |fx| fx.b.clone();
    let pick_root: fn(&Fx) -> ChangeId = |fx| fx.zero.clone();
    let pick_unknown: fn(&Fx) -> ChangeId = |_| ChangeId(UNKNOWN.to_owned());
    for pick in [pick_b, pick_root, pick_unknown] {
        for (index, verb) in verbs.iter().enumerate() {
            let mut fx = base(None);
            let x = pick(&fx);
            let expected = card(&mut fx, &x).into_iter().nth(index).expect("row");
            agree(&mut fx, &expected, |repo| verb(repo, x));
        }
    }
}
