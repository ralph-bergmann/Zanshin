// SPDX-License-Identifier: MIT

//! Story 9.19 — `Repo::bookmark_move`, `Repo::bookmark_advance` and `Repo::bookmark_rename`
//! against jj-lib state: every row of the spec's move / advance / rename matrix, I1 (a conflicted
//! bookmark moved to a descendant of one side becomes NORMAL), and the agreement witness — the
//! verb writes, no-ops or refuses exactly as `drop_actions`' bookmark row said.
//!
//! The fixture is a non-colocated Git-backed repo built in-test with Zanshin's own verbs:
//! `root → A → B → C`, `D` a second child of `B`, and `@` = `C`. Bookmarks are set in-test
//! through `test_helpers::{set_local_bookmark, set_remote_bookmark}`; every refusal and no-op
//! also asserts the head operation is unchanged and `new_op_id` is the pre-call head.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::commit::Commit;
use jj_lib::object_id::ObjectId;
use jj_lib::op_store::RefTarget;
use jj_lib::ref_name::{RefName, RemoteName, WorkspaceName};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::{set_local_bookmark, set_remote_bookmark};
use zanshin_jj::{
    ActionStatus, Backend, BookmarkMoveOptions, ChangeId, ConfigScope, ConfigTarget, DropLocation, DropSource,
    DropVerb, MutateError, MutationResult, Repo, WarningKind,
};

pub(crate) struct Fx {
    _tmp: TempDir,
    pub(crate) root: PathBuf,
    pub(crate) repo: Repo,
    pub(crate) a: ChangeId,
    pub(crate) b: ChangeId,
    pub(crate) c: ChangeId,
    pub(crate) d: ChangeId,
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

pub(crate) fn wc(root: &Path) -> ChangeId {
    let repo = load(root);
    let id = repo
        .view()
        .get_wc_commit_id(WorkspaceName::new("default"))
        .expect("@")
        .clone();
    change_id(&repo.store().get_commit(&id).expect("@ commit"))
}

/// The full hex commit id of `id`'s one visible commit.
pub(crate) fn hex(root: &Path, id: &ChangeId) -> String {
    let repo = load(root);
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0).expect("reverse hex");
    let targets = pollster::block_on(repo.resolve_change_id(&jj_id))
        .expect("index")
        .expect("known change");
    targets.into_visible().expect("visible")[0].hex()
}

pub(crate) fn commit_id(root: &Path, id: &ChangeId) -> jj_lib::backend::CommitId {
    jj_lib::backend::CommitId::try_from_hex(hex(root, id)).expect("commit hex")
}

/// The head operation's `(id, description)`.
pub(crate) fn head_op(root: &Path) -> (String, String) {
    let repo = load(root);
    (repo.op_id().hex(), repo.operation().metadata().description.clone())
}

/// The local target of `name`.
pub(crate) fn local(root: &Path, name: &str) -> RefTarget {
    load(root).view().get_local_bookmark(RefName::new(name)).clone()
}

/// The remote ref of `name@remote`: `(present target hex, tracked)`.
pub(crate) fn remote(root: &Path, name: &str, remote: &str) -> (Option<String>, bool) {
    let repo = load(root);
    let remote_ref = repo
        .view()
        .get_remote_bookmark(RefName::new(name).to_remote_symbol(RemoteName::new(remote)))
        .clone();
    (
        remote_ref.target.as_normal().map(ObjectId::hex),
        remote_ref.is_tracked(),
    )
}

/// `root → A → B → C` and `D` a second child of `B`, `@` = `C`, all described.
pub(crate) fn base() -> Fx {
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
    let mut repo = Repo::open(&root).expect("open");
    let step = |repo: &mut Repo, path: &str, description: &str| -> ChangeId {
        fs::write(root.join(path), format!("{path}\n")).expect("write");
        let at = wc(&root);
        repo.describe(at.clone(), description).expect("describe");
        at
    };
    let a = step(&mut repo, "a.txt", "A\n");
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    let b = step(&mut repo, "b.txt", "B\n");
    repo.new_change(std::slice::from_ref(&b), &[], &[]).expect("new");
    let d = step(&mut repo, "d.txt", "D\n");
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
        d,
    }
}

impl Fx {
    /// Points the local bookmark `name` at `targets` (several = conflicted) and reopens.
    pub(crate) fn set(&mut self, name: &str, targets: &[&ChangeId]) {
        let hexes: Vec<String> = targets.iter().map(|id| hex(&self.root, id)).collect();
        let refs: Vec<&str> = hexes.iter().map(String::as_str).collect();
        set_local_bookmark(&self.root, name, &refs);
        self.reopen();
    }

    /// Points `name@remote` at `target` and reopens.
    pub(crate) fn set_remote(&mut self, name: &str, remote: &str, target: &ChangeId, tracked: bool) {
        set_remote_bookmark(&self.root, name, remote, &hex(&self.root, target), tracked);
        self.reopen();
    }

    pub(crate) fn reopen(&mut self) {
        self.repo = Repo::open(&self.root).expect("reopen");
        let _ = self.repo.take_warnings();
    }

    pub(crate) fn normal(&self, name: &str) -> Option<String> {
        local(&self.root, name).as_normal().map(ObjectId::hex)
    }

    pub(crate) fn kinds(&mut self) -> Vec<(WarningKind, String)> {
        self.repo
            .take_warnings()
            .into_iter()
            .filter(|w| w.kind != WarningKind::IdentityMissing)
            .map(|w| (w.kind, w.message))
            .collect()
    }
}

pub(crate) fn names(list: &[&str]) -> Vec<String> {
    list.iter().map(|name| (*name).to_owned()).collect()
}

fn move_to(list: &[&str], to: &ChangeId) -> BookmarkMoveOptions {
    BookmarkMoveOptions {
        names: names(list),
        to: Some(to.clone()),
        ..Default::default()
    }
}

/// A call that wrote nothing: the head is unchanged and `new_op_id` is it.
pub(crate) fn assert_no_op(fx: &Fx, before: &(String, String), result: &MutationResult) {
    assert_eq!(&head_op(&fx.root), before, "no operation written");
    assert_eq!(result.new_op_id.0, before.0, "new_op_id is the pre-call head");
}

/// A refusal that wrote nothing.
pub(crate) fn assert_refused(fx: &Fx, before: &(String, String)) {
    assert_eq!(&head_op(&fx.root), before, "a refusal writes no operation");
}

pub(crate) fn invalid_reason(e: &MutateError) -> (&str, Vec<String>) {
    let MutateError::InvalidInput { reason, hints } = e else {
        panic!("expected InvalidInput, got {e:?}");
    };
    (reason, hints.clone())
}

// ── move ───────────────────────────────────────────────────────────────────────

#[test]
fn move_forward_points_the_bookmark_and_writes_the_cli_description() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    fx.set("b-mark", &[&b]);
    let result = fx.repo.bookmark_move(&move_to(&["b-mark"], &c)).expect("move");
    let c_hex = hex(&fx.root, &c);
    assert_eq!(fx.normal("b-mark"), Some(c_hex.clone()));
    let (id, description) = head_op(&fx.root);
    assert_eq!(result.new_op_id.0, id);
    assert_eq!(description, format!("point bookmark b-mark to commit {c_hex}"));
    assert!(result.new_change_ids.is_empty() && result.abandoned_change_ids.is_empty());
    assert!(fx.kinds().is_empty());
}

#[test]
fn move_backwards_is_refused_with_the_hint_unless_allowed() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    fx.set("b-mark", &[&b]);
    let before = head_op(&fx.root);
    let err = fx.repo.bookmark_move(&move_to(&["b-mark"], &a)).expect_err("backwards");
    let (reason, hints) = invalid_reason(&err);
    assert_eq!(reason, "Refusing to move bookmark backwards or sideways: b-mark");
    assert_eq!(hints, ["Use --allow-backwards to allow it."]);
    assert_eq!(err.hints(), ["Use --allow-backwards to allow it."]);
    assert_refused(&fx, &before);

    let allowed = BookmarkMoveOptions {
        allow_backwards: true,
        ..move_to(&["b-mark"], &a)
    };
    fx.repo.bookmark_move(&allowed).expect("allowed backwards");
    assert_eq!(fx.normal("b-mark"), Some(hex(&fx.root, &a)));
}

/// `--from` picks the bookmarks on its revisions; with names too, both must match. The names in
/// the description are in view order, whatever the argument order.
#[test]
fn move_from_moves_the_bookmarks_on_its_revisions_in_view_order() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    fx.set("z-on-b", &[&b]);
    fx.set("a-on-b", &[&b]);
    fx.set("elsewhere", &[&a]);
    let from_b = BookmarkMoveOptions {
        from: vec![hex(&fx.root, &b)],
        to: Some(c.clone()),
        ..Default::default()
    };
    fx.repo.bookmark_move(&from_b).expect("move --from");
    let c_hex = hex(&fx.root, &c);
    assert_eq!(fx.normal("a-on-b"), Some(c_hex.clone()));
    assert_eq!(fx.normal("z-on-b"), Some(c_hex.clone()));
    assert_eq!(fx.normal("elsewhere"), Some(hex(&fx.root, &a)));
    assert_eq!(
        head_op(&fx.root).1,
        format!("point bookmark a-on-b, z-on-b to commit {c_hex}")
    );

    // Names AND from: only `elsewhere` is named, and it is not on `A`'s child.
    let both = BookmarkMoveOptions {
        names: names(&["elsewhere", "a-on-b"]),
        from: vec![hex(&fx.root, &a)],
        to: Some(b.clone()),
        allow_backwards: true,
    };
    fx.repo.bookmark_move(&both).expect("names and from");
    assert_eq!(fx.normal("elsewhere"), Some(hex(&fx.root, &b)));
    assert_eq!(fx.normal("a-on-b"), Some(c_hex), "named but not on --from");
}

/// A bookmark already at the target is skipped; nothing left is a success with no operation.
/// An unknown name also warns, before the no-op.
#[test]
fn move_noop_and_unknown_name_write_no_operation() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("b-mark", &[&b]);
    let before = head_op(&fx.root);
    let result = fx.repo.bookmark_move(&move_to(&["b-mark"], &b)).expect("no-op");
    assert_no_op(&fx, &before, &result);
    assert!(fx.kinds().is_empty());

    let result = fx
        .repo
        .bookmark_move(&move_to(&["nope", "b-mark"], &b))
        .expect("unknown");
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::BookmarkNamesUnmatched,
            "No matching bookmarks for names: nope".to_owned()
        )]
    );
}

/// Exact names: `b*` names only a bookmark literally called `b*`.
#[test]
fn move_names_are_exact_never_globs() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    fx.set("b-mark", &[&b]);
    let before = head_op(&fx.root);
    let result = fx.repo.bookmark_move(&move_to(&["b*"], &c)).expect("no glob");
    assert_no_op(&fx, &before, &result);
    assert_eq!(fx.normal("b-mark"), Some(hex(&fx.root, &b)));
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::BookmarkNamesUnmatched,
            "No matching bookmarks for names: \"b*\"".to_owned()
        )]
    );
}

#[test]
fn move_without_names_or_from_is_refused_before_resolving() {
    let mut fx = base();
    let before = head_op(&fx.root);
    let options = BookmarkMoveOptions {
        to: Some(ChangeId("not a change id".to_owned())),
        ..Default::default()
    };
    // A dirty working copy proves the refusal comes before the pre-verb snapshot.
    fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("write");
    let err = fx.repo.bookmark_move(&options).expect_err("clap's required group");
    let (reason, _) = invalid_reason(&err);
    assert_eq!(reason, "bookmark move requires at least one name or --from revision");
    assert_refused(&fx, &before);
    assert!(fx.repo.take_precondition().is_none(), "no snapshot ran");
}

/// `to` absent is `@`; an empty, undescribed target warns and still moves.
#[test]
fn move_to_an_empty_target_warns_and_moves() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    fx.set("b-mark", &[&b]);
    fx.repo.new_change(std::slice::from_ref(&c), &[], &[]).expect("new");
    let empty = wc(&fx.root);
    let _ = fx.repo.take_warnings();
    let options = BookmarkMoveOptions {
        names: names(&["b-mark"]),
        ..Default::default()
    };
    fx.repo.bookmark_move(&options).expect("move to @");
    assert_eq!(fx.normal("b-mark"), Some(hex(&fx.root, &empty)));
    assert_eq!(
        fx.kinds(),
        [(WarningKind::BookmarkTargetEmpty, "Target revision is empty.".to_owned())]
    );
}

/// A bad `--from` text is the revset taxonomy; a bad `to` is `ChangeNotFound`. Both write nothing.
#[test]
fn move_refuses_a_bad_from_or_to() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    fx.set("b-mark", &[&b]);
    let before = head_op(&fx.root);
    let parse = BookmarkMoveOptions {
        from: vec!["(".to_owned()],
        to: Some(c.clone()),
        ..Default::default()
    };
    let err = fx.repo.bookmark_move(&parse).expect_err("parse");
    assert!(matches!(err, MutateError::RevsetParseError { .. }), "{err:?}");
    let resolve = BookmarkMoveOptions {
        from: vec!["no-such-bookmark".to_owned()],
        ..parse
    };
    let err = fx.repo.bookmark_move(&resolve).expect_err("resolve");
    assert!(matches!(err, MutateError::RevsetResolutionError { .. }), "{err:?}");
    let err = fx
        .repo
        .bookmark_move(&move_to(
            &["b-mark"],
            &ChangeId("pqrstuvwxyzklmnopqrstuvwxyzklmno".to_owned()),
        ))
        .expect_err("unknown to");
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");
    assert_refused(&fx, &before);
}

/// I1 (deferred-work, Story 9.31): a CONFLICTED bookmark (adds `B`, `D`) moved to `C`, a child of
/// one side, is a fast-forward and becomes a NORMAL target at `C`.
#[test]
fn a_conflicted_bookmark_moved_to_a_descendant_of_one_side_becomes_normal() {
    let mut fx = base();
    let (b, c, d) = (fx.b.clone(), fx.c.clone(), fx.d.clone());
    fx.set("mark", &[&b, &d]);
    assert!(!local(&fx.root, "mark").is_resolved(), "mark is conflicted");
    fx.repo.bookmark_move(&move_to(&["mark"], &c)).expect("move");
    let target = local(&fx.root, "mark");
    assert_eq!(target, RefTarget::normal(commit_id(&fx.root, &c)));
}

/// The agreement witness: for each `drop_actions` bookmark row, the verb run with
/// `allow_backwards` exactly when the row needed it writes when the row said `Available`, writes
/// nothing when it said `NoOp`, and refuses with the backwards refusal when it needed
/// `allow_backwards` and runs without it.
#[test]
fn the_verb_agrees_with_every_drop_actions_bookmark_row() {
    let mut fx = base();
    let (b, d) = (fx.b.clone(), fx.d.clone());
    agree_on_every_target(&mut fx, &[&b]);
    // The any-side rule: a conflicted `mark` (adds `B`, `D`).
    agree_on_every_target(&mut fx, &[&b, &d]);
}

/// For `mark` set to `mark_targets` before each run, every target of the base graph: the row's
/// status and `allow_backwards_needed` against what the verb does.
fn agree_on_every_target(fx: &mut Fx, mark_targets: &[&ChangeId]) {
    let targets = [fx.a.clone(), fx.b.clone(), fx.c.clone(), fx.d.clone()];
    for target in &targets {
        fx.set("mark", mark_targets);
        let source = DropSource::Bookmark("mark".to_owned());
        let location = DropLocation {
            onto: vec![target.clone()],
            ..DropLocation::default()
        };
        let actions = fx.repo.drop_actions(&source, &[location]).expect("drop_actions");
        let row = actions
            .actions
            .iter()
            .find(|action| action.verb == DropVerb::BookmarkMove)
            .expect("a bookmark row");
        assert_ne!(row.outcome.status, ActionStatus::Refused, "onto a visible change");
        let before = head_op(&fx.root);
        let options = BookmarkMoveOptions {
            allow_backwards: row.outcome.allow_backwards_needed,
            ..move_to(&["mark"], target)
        };
        let result = fx.repo.bookmark_move(&options).expect("the row's move");
        if row.outcome.status == ActionStatus::Available {
            assert_ne!(result.new_op_id.0, before.0, "Available writes ({target:?})");
            assert_eq!(local(&fx.root, "mark"), RefTarget::normal(commit_id(&fx.root, target)));
        } else {
            assert_no_op(fx, &before, &result);
        }
        if row.outcome.allow_backwards_needed {
            fx.set("mark", mark_targets);
            let before = head_op(&fx.root);
            let err = fx
                .repo
                .bookmark_move(&move_to(&["mark"], target))
                .expect_err("backwards");
            assert!(invalid_reason(&err)
                .0
                .starts_with("Refusing to move bookmark backwards"));
            assert_refused(fx, &before);
        }
    }
}

// ── advance ────────────────────────────────────────────────────────────────────

/// No names, no `to`: `revsets.bookmark-advance-to` = `@` = `C`, and the closest bookmark below
/// it (`heads(::to & bookmarks())`) advances; one further down does not.
#[test]
fn advance_default_moves_the_closest_bookmark_to_at() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    fx.set("a-mark", &[&a]);
    fx.set("b-mark", &[&b]);
    fx.repo.bookmark_advance(&[], None).expect("advance");
    let c_hex = hex(&fx.root, &c);
    assert_eq!(fx.normal("b-mark"), Some(c_hex.clone()));
    assert_eq!(
        fx.normal("a-mark"),
        Some(hex(&fx.root, &a)),
        "not a head of ::to & bookmarks()"
    );
    assert_eq!(head_op(&fx.root).1, format!("point bookmark b-mark to commit {c_hex}"));

    // Again: b-mark is now AT the target, so nothing is left.
    let before = head_op(&fx.root);
    let result = fx.repo.bookmark_advance(&[], None).expect("no-op");
    assert_no_op(&fx, &before, &result);
}

#[test]
fn advance_named_backwards_is_refused_without_a_hint() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    fx.set("b-mark", &[&b]);
    let before = head_op(&fx.root);
    let err = fx
        .repo
        .bookmark_advance(&names(&["b-mark"]), Some(&a))
        .expect_err("backwards");
    let (reason, hints) = invalid_reason(&err);
    assert_eq!(reason, "Refusing to advance bookmark backwards or sideways: b-mark");
    assert!(hints.is_empty());
    assert_refused(&fx, &before);

    // Named and forward, with an unknown name warned.
    let c = fx.c.clone();
    fx.repo
        .bookmark_advance(&names(&["b-mark", "nope"]), Some(&c))
        .expect("forward");
    assert_eq!(fx.normal("b-mark"), Some(hex(&fx.root, &c)));
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::BookmarkNamesUnmatched,
            "No matching bookmarks for names: nope".to_owned()
        )]
    );
}

pub(crate) fn set_repo_config(root: &Path, name: &str, value: &str) {
    zanshin_jj::config_set(Some(root), &ConfigTarget::Scope(ConfigScope::Repo), name, value)
        .result
        .expect("config set --repo");
}

/// A default target that resolves to no commit, or does not parse, carries the CLI's hint; an
/// explicit `to` never does.
#[test]
fn advance_bad_default_target_carries_the_config_hint() {
    const HINT: &str =
        "`revsets.bookmark-advance-to` controls the default target. You can also specify a specific target with `--to`.";
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("b-mark", &[&b]);
    set_repo_config(&fx.root, "revsets.bookmark-advance-to", "\"none()\"");
    fx.reopen();
    let before = head_op(&fx.root);
    let err = fx.repo.bookmark_advance(&[], None).expect_err("none()");
    let MutateError::RevsetResolutionError { reason, hints } = &err else {
        panic!("{err:?}");
    };
    assert_eq!(reason, "Revset `none()` didn't resolve to any revisions");
    assert_eq!(hints, &[HINT]);
    assert_refused(&fx, &before);

    set_repo_config(&fx.root, "revsets.bookmark-advance-to", "\"(\"");
    fx.reopen();
    let err = fx.repo.bookmark_advance(&[], None).expect_err("parse");
    // The revset's own syntax hint first, then the command's (Story 9.25), as the CLI prints them.
    assert!(
        matches!(&err, MutateError::RevsetParseError { hints, .. }
            if hints.len() == 2 && hints[0].contains("revsets syntax") && hints[1] == HINT),
        "{err:?}"
    );

    set_repo_config(&fx.root, "revsets.bookmark-advance-to", "\"all()\"");
    fx.reopen();
    let err = fx.repo.bookmark_advance(&[], None).expect_err("several");
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, hints }
            if reason == "Revset `all()` resolved to more than one revision" && hints == &[HINT]),
        "{err:?}"
    );
    assert_refused(&fx, &before);
}

/// An explicit `to` that does not resolve is `ChangeNotFound`, without the default-target hint.
#[test]
fn advance_with_a_bad_explicit_to_has_no_hint() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("b-mark", &[&b]);
    let before = head_op(&fx.root);
    let unknown = ChangeId("pqrstuvwxyzklmnopqrstuvwxyzklmno".to_owned());
    let err = fx
        .repo
        .bookmark_advance(&names(&["b-mark"]), Some(&unknown))
        .expect_err("unknown to");
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");
    assert!(err.hints().is_empty());
    assert_refused(&fx, &before);
}

/// `revsets.bookmark-advance-from` sees the target as `to`: `::to & bookmarks()` makes `a-mark`
/// a candidate too, which the default `heads(…)` does not.
#[test]
fn advance_from_config_uses_the_injected_to() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    fx.set("a-mark", &[&a]);
    fx.set("b-mark", &[&b]);
    set_repo_config(&fx.root, "revsets.bookmark-advance-from", "\"::to & bookmarks()\"");
    fx.reopen();
    fx.repo.bookmark_advance(&[], None).expect("advance");
    let c_hex = hex(&fx.root, &c);
    assert_eq!(fx.normal("a-mark"), Some(c_hex.clone()));
    assert_eq!(fx.normal("b-mark"), Some(c_hex.clone()));
    assert_eq!(
        head_op(&fx.root).1,
        format!("point bookmark a-mark, b-mark to commit {c_hex}")
    );
}

/// Explicit names ignore the from revset, even one that does not parse.
#[test]
fn advance_with_names_ignores_a_broken_from_revset() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    fx.set("b-mark", &[&b]);
    set_repo_config(&fx.root, "revsets.bookmark-advance-from", "\"(\"");
    fx.reopen();
    fx.repo.bookmark_advance(&names(&["b-mark"]), None).expect("names only");
    assert_eq!(fx.normal("b-mark"), Some(hex(&fx.root, &c)));
    let err = fx.repo.bookmark_advance(&[], None).expect_err("the from revset");
    assert!(matches!(err, MutateError::RevsetParseError { .. }), "{err:?}");
}

/// A diagnostic in the from revset is recorded under the CLI's context line.
#[test]
fn advance_from_revset_diagnostics_warn_under_its_context_line() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("b-mark", &[&b]);
    set_repo_config(
        &fx.root,
        "revsets.bookmark-advance-from",
        "'heads(::to & bookmarks()) ~ diff_contains(\"zzz\")'",
    );
    fx.reopen();
    fx.repo.bookmark_advance(&[], None).expect("advance");
    let warnings = fx.kinds();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].0, WarningKind::RevsetDiagnostic);
    assert!(
        warnings[0].1.starts_with("In revsets.bookmark-advance-from\n")
            && warnings[0].1.contains("diff_contains() is deprecated"),
        "{}",
        warnings[0].1
    );
}

/// A malformed `revsets.bookmark-advance-from` / `-to` value is a config refusal.
#[test]
fn advance_with_a_wrong_typed_revset_key_is_a_config_refusal() {
    let mut fx = base();
    set_repo_config(&fx.root, "revsets.bookmark-advance-from", "1");
    fx.reopen();
    let err = fx.repo.bookmark_advance(&[], None).expect_err("not a string");
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.contains("revsets.bookmark-advance-from")),
        "{err:?}"
    );
    set_repo_config(&fx.root, "revsets.bookmark-advance-to", "1");
    fx.reopen();
    let err = fx.repo.bookmark_advance(&[], None).expect_err("not a string");
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.contains("revsets.bookmark-advance-to")),
        "{err:?}"
    );
}

// ── rename ─────────────────────────────────────────────────────────────────────

#[test]
fn rename_keeps_the_target_and_writes_the_cli_description() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("b-mark", &[&b]);
    fx.repo.bookmark_rename("b-mark", "renamed", false).expect("rename");
    assert_eq!(fx.normal("renamed"), Some(hex(&fx.root, &b)));
    assert!(local(&fx.root, "b-mark").is_absent());
    assert_eq!(head_op(&fx.root).1, "rename bookmark b-mark to renamed");
    assert!(fx.kinds().is_empty());
}

#[test]
fn rename_refusals_write_nothing() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    fx.set("b-mark", &[&b]);
    fx.set("c-mark", &[&c]);
    let before = head_op(&fx.root);

    let err = fx.repo.bookmark_rename("nope", "x", false).expect_err("missing");
    assert_eq!(invalid_reason(&err).0, "No such bookmark: nope");
    let err = fx.repo.bookmark_rename("b-mark", "c-mark", false).expect_err("exists");
    assert!(
        matches!(&err, MutateError::BookmarkExists { name, hints } if name == "c-mark" && hints.is_empty()),
        "{err:?}"
    );
    let err = fx
        .repo
        .bookmark_rename("b-mark", "b-mark", false)
        .expect_err("same, no overwrite");
    assert!(
        matches!(&err, MutateError::BookmarkExists { name, .. } if name == "b-mark"),
        "{err:?}"
    );
    let err = fx.repo.bookmark_rename("", "x", false).expect_err("empty");
    assert_eq!(invalid_reason(&err).0, "bookmark name must not be empty");
    assert_refused(&fx, &before);

    let result = fx
        .repo
        .bookmark_rename("b-mark", "b-mark", true)
        .expect("same, overwrite");
    assert_no_op(&fx, &before, &result);

    fx.repo.bookmark_rename("b-mark", "c-mark", true).expect("overwrite");
    assert_eq!(fx.normal("c-mark"), Some(hex(&fx.root, &b)));
    assert!(local(&fx.root, "b-mark").is_absent());
}

/// A tracked, present `feature@origin` moves its tracking to `renamed@origin` (absent there, so a
/// tracked "not created yet" ref) and warns that the remote bookmark itself was not renamed.
#[test]
fn rename_of_a_tracked_bookmark_transfers_tracking_and_warns() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("feature", &[&b]);
    fx.set_remote("feature", "origin", &b, true);
    fx.repo.bookmark_rename("feature", "renamed", false).expect("rename");
    assert_eq!(remote(&fx.root, "renamed", "origin"), (None, true));
    assert_eq!(remote(&fx.root, "feature", "origin"), (Some(hex(&fx.root, &b)), true));
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::BookmarkRemotesNotRenamed,
            "Tracked remote bookmarks for bookmark feature were not renamed.".to_owned()
        )]
    );
}

/// The remote `git` is left out on a Git-backed repo, as in the CLI: a tracked `feature@git`
/// neither moves its tracking to `renamed@git` nor warns.
#[test]
fn rename_leaves_the_git_remote_out() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("feature", &[&b]);
    fx.set_remote("feature", "git", &b, true);
    fx.repo.bookmark_rename("feature", "renamed", false).expect("rename");
    assert_eq!(remote(&fx.root, "renamed", "git"), (None, false));
    assert_eq!(remote(&fx.root, "feature", "git"), (Some(hex(&fx.root, &b)), true));
    assert!(fx.kinds().is_empty());
}

/// An empty name is clap's refusal: before the pre-verb snapshot, so a dirty working copy is not
/// snapshotted and no operation is written.
#[test]
fn rename_refuses_an_empty_name_before_the_snapshot() {
    let mut fx = base();
    let before = head_op(&fx.root);
    fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("write");
    let err = fx.repo.bookmark_rename("", "x", false).expect_err("empty");
    assert_eq!(invalid_reason(&err).0, "bookmark name must not be empty");
    assert_refused(&fx, &before);
    assert!(fx.repo.take_precondition().is_none(), "no snapshot ran");
}

/// The two in-transaction warnings and the second after-finish warning: `renamed` exists
/// untracked on `upstream` (tracking dropped), and with overwrite the present, tracked
/// `renamed@origin` the old name did not track is untracked (tracking dropped); without
/// overwrite the present tracked remotes of the new name warn.
#[test]
fn rename_warns_every_dropped_tracking() {
    let mut fx = base();
    // `D`, not `@`: an untracked remote bookmark makes its commit immutable.
    let (b, c, d) = (fx.b.clone(), fx.c.clone(), fx.d.clone());
    fx.set("feature", &[&b]);
    fx.set_remote("feature", "upstream", &b, true);
    fx.set_remote("renamed", "upstream", &d, false);
    fx.set("renamed", &[&d]);
    fx.set_remote("renamed", "origin", &d, true);
    // `both`: tracked on both names — untracked by the overwrite, so the transfer finds the new
    // name present and untracked there (the CLI checks the transaction's view), and the old
    // name's tracking means no "dropped" warning. `zz`: an untracked remote of the old name is
    // left alone.
    fx.set_remote("feature", "both", &b, true);
    fx.set_remote("renamed", "both", &d, true);
    fx.set_remote("feature", "zz", &b, false);
    fx.repo.bookmark_rename("feature", "renamed", true).expect("overwrite");
    assert_eq!(remote(&fx.root, "renamed", "both"), (Some(hex(&fx.root, &d)), false));
    assert_eq!(remote(&fx.root, "renamed", "zz"), (None, false));
    assert_eq!(remote(&fx.root, "renamed", "origin"), (Some(hex(&fx.root, &d)), false));
    assert_eq!(
        remote(&fx.root, "renamed", "upstream"),
        (Some(hex(&fx.root, &d)), false)
    );
    assert_eq!(
        fx.kinds(),
        [
            (
                WarningKind::BookmarkRenameRemoteExists,
                "The renamed bookmark already exists on the remote 'both', tracking state was dropped.".to_owned()
            ),
            (
                WarningKind::BookmarkRenameRemoteExists,
                "The renamed bookmark already exists on the remote 'upstream', tracking state was dropped.".to_owned()
            ),
            (
                WarningKind::BookmarkTrackingDropped,
                "Tracking of remote bookmark renamed@origin was dropped.".to_owned()
            ),
            (
                WarningKind::BookmarkRemotesNotRenamed,
                "Tracked remote bookmarks for bookmark feature were not renamed.".to_owned()
            ),
        ]
    );

    // Without overwrite: `other@origin` is present and tracked while `other` is deleted locally.
    fx.set("x", &[&b]);
    fx.set("other", &[&c]);
    fx.set_remote("other", "origin", &c, true);
    fx.set("other", &[]);
    fx.repo
        .bookmark_rename("x", "other", false)
        .expect("rename onto a deleted name");
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::BookmarkTrackedRemotesExist,
            "Tracked remote bookmarks for bookmark other exist.".to_owned()
        )]
    );
}
