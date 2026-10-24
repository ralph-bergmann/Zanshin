// SPDX-License-Identifier: MIT

//! Story 9.16 — `Repo::rebase`, one witness per row of the I/O matrix, read back through jj-lib.
//!
//! Every repo is built in-test with Zanshin's own verbs on a non-colocated internal-git repo:
//! `A (a.txt) → B (b.txt, bookmark b-mark) → C (c.txt) = @`, descriptions `A\n`, `B\n`, `C\n`.
//! The CLI comparison of the same rows lives in the parity oracle (`crates/zanshin-parity`).
//! The harness is shared with `parallelize_arrange.rs`.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::commit::Commit;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::{RefName, WorkspaceName};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{
    ActionStatus, Backend, ChangeId, DropLocation, DropSource, DropVerb, MutateError, MutationResult, RebaseOptions,
    Repo,
};

/// The base history and the handles a test needs.
pub(crate) struct Fx {
    _tmp: TempDir,
    pub(crate) root: PathBuf,
    pub(crate) repo: Repo,
    pub(crate) a: ChangeId,
    pub(crate) b: ChangeId,
    pub(crate) c: ChangeId,
    /// The root commit's change id.
    pub(crate) zero: ChangeId,
}

pub(crate) fn load(root: &Path) -> Arc<ReadonlyRepo> {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load workspace");
    pollster::block_on(workspace.repo_loader().load_at_head()).expect("load head")
}

pub(crate) fn change_id(commit: &Commit) -> ChangeId {
    ChangeId(commit.change_id().reverse_hex())
}

/// `@` of the default workspace.
pub(crate) fn wc(root: &Path) -> Commit {
    let repo = load(root);
    let id = repo.view().get_wc_commit_id(WorkspaceName::DEFAULT).expect("@").clone();
    repo.store().get_commit(&id).expect("@ commit")
}

/// The VISIBLE commits of `id` — two or more when it is divergent, none when abandoned.
pub(crate) fn visible_all(root: &Path, id: &ChangeId) -> Vec<Commit> {
    let repo = load(root);
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0).expect("reverse hex");
    let Some(targets) = pollster::block_on(repo.resolve_change_id(&jj_id)).expect("index") else {
        return Vec::new();
    };
    targets
        .into_visible()
        .unwrap_or_default()
        .iter()
        .map(|commit_id| repo.store().get_commit(commit_id).expect("commit"))
        .collect()
}

/// The one VISIBLE commit of `id`.
pub(crate) fn commit(root: &Path, id: &ChangeId) -> Commit {
    let [commit] = <[Commit; 1]>::try_from(visible_all(root, id)).expect("exactly one visible commit");
    commit
}

/// `id`'s parents, by change id.
pub(crate) fn parents(root: &Path, id: &ChangeId) -> Vec<ChangeId> {
    let repo = load(root);
    commit(root, id)
        .parent_ids()
        .iter()
        .map(|parent| change_id(&repo.store().get_commit(parent).expect("parent")))
        .collect()
}

pub(crate) fn hex(root: &Path, id: &ChangeId) -> String {
    commit(root, id).id().hex()
}

/// The head operation: its id and description.
pub(crate) fn head_op(root: &Path) -> (String, String) {
    let repo = load(root);
    (repo.op_id().hex(), repo.operation().metadata().description.clone())
}

pub(crate) fn bookmark(root: &Path, name: &str) -> Option<ChangeId> {
    let repo = load(root);
    let target = repo.view().get_local_bookmark(RefName::new(name)).as_normal()?.clone();
    Some(change_id(&repo.store().get_commit(&target).expect("bookmark target")))
}

/// `A (a.txt) → B (b.txt, bookmark b-mark) → C (c.txt) = @`.
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
    fs::write(root.join(".jj").join("repo").join("config.toml"), "").expect("repo config");
    let mut repo = Repo::open(&root).expect("open");
    let step = |repo: &mut Repo, path: &str, description: &str| -> ChangeId {
        fs::write(root.join(path), format!("{}\n", &path[..1])).expect("write");
        let at = change_id(&wc(&root));
        repo.describe(at.clone(), description).expect("describe");
        at
    };
    let a = step(&mut repo, "a.txt", "A\n");
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    let b = step(&mut repo, "b.txt", "B\n");
    repo.bookmark_create(&["b-mark".to_owned()], Some(&b))
        .expect("bookmark");
    repo.new_change(std::slice::from_ref(&b), &[], &[]).expect("new");
    let c = step(&mut repo, "c.txt", "C\n");
    let _ = repo.take_warnings();
    let zero = change_id(&load(&root).store().root_commit());
    Fx {
        _tmp: tmp,
        root,
        repo,
        a,
        b,
        c,
        zero,
    }
}

/// Writes `config` as the repo config and reopens the repo.
pub(crate) fn reconfigure(fx: &mut Fx, config: &str) {
    fs::write(fx.root.join(".jj").join("repo").join("config.toml"), config).expect("repo config");
    fx.repo = Repo::open(&fx.root).expect("reopen");
    let _ = fx.repo.take_warnings();
}

/// `immutable_heads()` set to `id`.
pub(crate) fn immutable(id: &ChangeId) -> String {
    format!("[revset-aliases]\n\"immutable_heads()\" = \"{}\"\n", id.0)
}

/// A new commit on `parents`, described `description`, with `files` written — `@` ends on it.
pub(crate) fn add(fx: &mut Fx, parents: &[ChangeId], files: &[(&str, &str)], description: &str) -> ChangeId {
    fx.repo.new_change(parents, &[], &[]).expect("new");
    for (path, text) in files {
        fs::write(fx.root.join(path), text).expect("write");
    }
    let at = change_id(&wc(&fx.root));
    fx.repo.describe(at.clone(), description).expect("describe");
    let _ = fx.repo.take_warnings();
    at
}

/// Runs `run`, asserts it refused and wrote no operation, and returns the refusal.
pub(crate) fn refused(fx: &mut Fx, run: impl FnOnce(&mut Repo) -> Result<MutationResult, MutateError>) -> MutateError {
    let before = head_op(&fx.root);
    let err = run(&mut fx.repo).expect_err("refused");
    assert_eq!(head_op(&fx.root), before, "a refusal writes no operation");
    err
}

/// Runs `run`, asserts it wrote no operation, and that `new_op_id` is the pre-call head.
pub(crate) fn no_op(fx: &mut Fx, run: impl FnOnce(&mut Repo) -> Result<MutationResult, MutateError>) {
    let before = head_op(&fx.root);
    let result = run(&mut fx.repo).expect("no-op");
    assert_eq!(head_op(&fx.root), before, "no operation");
    assert_eq!(result.new_op_id.0, before.0, "new_op_id is the pre-call head");
    assert!(result.abandoned_change_ids.is_empty() && result.new_change_ids.is_empty());
}

/// Asserts `result` is the head and the head's description is `description`.
pub(crate) fn assert_op(fx: &Fx, result: &MutationResult, description: &str) {
    let (op_id, op_description) = head_op(&fx.root);
    assert_eq!(op_description, description);
    assert_eq!(result.new_op_id.0, op_id);
}

fn invalid(e: &MutateError) -> String {
    match e {
        MutateError::InvalidInput { reason, .. } => reason.clone(),
        other => format!("{other:?}"),
    }
}

// ── the four drop forms ──────────────────────────────────────────────────────────

#[test]
fn source_onto_moves_the_source_and_its_descendants() {
    let mut fx = base();
    let c_hex = hex(&fx.root, &fx.c);
    let options = RebaseOptions {
        source: vec![fx.c.clone()],
        onto: vec![fx.a.clone()],
        ..RebaseOptions::default()
    };
    let result = fx.repo.rebase(&options).expect("rebase");
    assert_op(&fx, &result, &format!("rebase commit {c_hex} and descendants"));
    assert_eq!(parents(&fx.root, &fx.c), [fx.a.clone()]);
    assert_eq!(parents(&fx.root, &fx.b), [fx.a.clone()]);
    assert_eq!(result.working_copy_change_id, Some(fx.c));
    assert!(result.abandoned_change_ids.is_empty() && result.new_change_ids.is_empty());
}

#[test]
fn revisions_onto_moves_only_the_revision() {
    let mut fx = base();
    let b_hex = hex(&fx.root, &fx.b);
    let options = RebaseOptions {
        revisions: vec![fx.b.clone()],
        onto: vec![fx.zero.clone()],
        ..RebaseOptions::default()
    };
    let result = fx.repo.rebase(&options).expect("rebase");
    assert_op(&fx, &result, &format!("rebase commit {b_hex}"));
    assert_eq!(parents(&fx.root, &fx.b), [fx.zero.clone()]);
    assert_eq!(parents(&fx.root, &fx.c), [fx.a.clone()]);
    assert_eq!(
        bookmark(&fx.root, "b-mark"),
        Some(fx.b.clone()),
        "the bookmark follows B"
    );
}

#[test]
fn revisions_onto_their_own_descendant_is_allowed() {
    let mut fx = base();
    let options = RebaseOptions {
        revisions: vec![fx.b.clone()],
        onto: vec![fx.c.clone()],
        ..RebaseOptions::default()
    };
    fx.repo.rebase(&options).expect("rebase");
    assert_eq!(parents(&fx.root, &fx.c), [fx.a.clone()]);
    assert_eq!(parents(&fx.root, &fx.b), [fx.c.clone()]);
}

#[test]
fn revisions_insert_after_and_before_put_the_revision_between() {
    for insert_after in [true, false] {
        let mut fx = base();
        let options = RebaseOptions {
            revisions: vec![fx.c.clone()],
            insert_after: if insert_after { vec![fx.a.clone()] } else { vec![] },
            insert_before: if insert_after { vec![] } else { vec![fx.b.clone()] },
            ..RebaseOptions::default()
        };
        let c_hex = hex(&fx.root, &fx.c);
        let result = fx.repo.rebase(&options).expect("rebase");
        assert_op(&fx, &result, &format!("rebase commit {c_hex}"));
        assert_eq!(parents(&fx.root, &fx.c), [fx.a.clone()], "-A: {insert_after}");
        assert_eq!(parents(&fx.root, &fx.b), [fx.c.clone()], "-A: {insert_after}");
    }
}

#[test]
fn several_revisions_name_the_first_and_count_the_rest() {
    let mut fx = base();
    let on = [fx.a.clone()];
    let d = add(&mut fx, &on, &[("d.txt", "d\n")], "D\n");
    let options = RebaseOptions {
        revisions: vec![fx.c.clone(), d.clone()],
        onto: vec![fx.zero.clone()],
        ..RebaseOptions::default()
    };
    // The revset's order: the newest first.
    let first = hex(&fx.root, &d);
    let result = fx.repo.rebase(&options).expect("rebase");
    assert_op(&fx, &result, &format!("rebase commit {first} and 1 more"));
    assert_eq!(parents(&fx.root, &fx.c), [fx.zero.clone()]);
    assert_eq!(parents(&fx.root, &d), [fx.zero.clone()]);
}

#[test]
fn several_sources_count_the_roots() {
    let mut fx = base();
    let on = [fx.a.clone()];
    let d = add(&mut fx, &on, &[("d.txt", "d\n")], "D\n");
    let options = RebaseOptions {
        source: vec![fx.c.clone(), d.clone()],
        onto: vec![fx.zero.clone()],
        ..RebaseOptions::default()
    };
    let result = fx.repo.rebase(&options).expect("rebase");
    assert_op(&fx, &result, "rebase 2 commits and their descendants");
}

#[test]
fn no_target_flag_rebases_the_branch_of_at() {
    let mut fx = base();
    let on = [fx.zero.clone()];
    let x = add(&mut fx, &on, &[("x.txt", "x\n")], "X\n");
    fx.repo.edit(fx.c.clone()).expect("edit C");
    let a_hex = hex(&fx.root, &fx.a);
    let options = RebaseOptions {
        onto: vec![x.clone()],
        ..RebaseOptions::default()
    };
    let result = fx.repo.rebase(&options).expect("rebase");
    // roots(X..@) is A.
    assert_op(&fx, &result, &format!("rebase commit {a_hex} and descendants"));
    assert_eq!(parents(&fx.root, &fx.a), [x]);
    assert_eq!(parents(&fx.root, &fx.c), [fx.b.clone()]);
}

#[test]
fn a_branch_or_source_already_in_place_writes_no_operation() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    no_op(&mut fx, |repo| {
        repo.rebase(&RebaseOptions {
            source: vec![b.clone()],
            onto: vec![a.clone()],
            ..RebaseOptions::default()
        })
    });
    // roots(B..A) is empty: "No revisions to rebase."
    no_op(&mut fx, |repo| {
        repo.rebase(&RebaseOptions {
            branch: vec![a.clone()],
            onto: vec![b.clone()],
            ..RebaseOptions::default()
        })
    });
}

#[test]
fn source_onto_its_descendant_or_itself_refuses() {
    let mut fx = base();
    let (a12, b12) = (
        hex(&fx.root, &fx.a)[..12].to_owned(),
        hex(&fx.root, &fx.b)[..12].to_owned(),
    );
    for (target, expected) in [
        (fx.b.clone(), format!("Cannot rebase {a12} onto descendant {b12}")),
        (fx.a.clone(), format!("Cannot rebase {a12} onto itself")),
    ] {
        let a = fx.a.clone();
        let err = refused(&mut fx, |repo| {
            repo.rebase(&RebaseOptions {
                source: vec![a],
                onto: vec![target],
                ..RebaseOptions::default()
            })
        });
        assert_eq!(invalid(&err), expected);
    }
}

#[test]
fn clap_conflicts_refuse_before_anything_resolves() {
    let mut fx = base();
    let nowhere = ChangeId("y".repeat(32));
    let cases = [
        RebaseOptions {
            revisions: vec![nowhere.clone()],
            source: vec![nowhere.clone()],
            onto: vec![nowhere.clone()],
            ..RebaseOptions::default()
        },
        RebaseOptions {
            revisions: vec![nowhere.clone()],
            ..RebaseOptions::default()
        },
        RebaseOptions {
            revisions: vec![nowhere.clone()],
            onto: vec![nowhere.clone()],
            insert_after: vec![nowhere.clone()],
            ..RebaseOptions::default()
        },
    ];
    let expected = [
        "only one of -b/--branch, -s/--source or -r/--revision can be given",
        "expected at least one of --onto, -A/--insert-after or -B/--insert-before",
        "--onto cannot be combined with -A/--insert-after or -B/--insert-before",
    ];
    for (options, expected) in cases.into_iter().zip(expected) {
        let err = refused(&mut fx, |repo| repo.rebase(&options));
        assert_eq!(invalid(&err), expected);
    }
    let err = refused(&mut fx, |repo| {
        repo.rebase(&RebaseOptions {
            revisions: vec![nowhere.clone()],
            onto: vec![nowhere.clone()],
            ..RebaseOptions::default()
        })
    });
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");
}

#[test]
fn an_immutable_target_or_rewritten_child_refuses() {
    let mut fx = base();
    let config = immutable(&fx.b);
    reconfigure(&mut fx, &config);
    let (a, b, c, zero) = (fx.a.clone(), fx.b.clone(), fx.c.clone(), fx.zero.clone());
    let b_hex = hex(&fx.root, &fx.b);
    let err = refused(&mut fx, |repo| {
        repo.rebase(&RebaseOptions {
            revisions: vec![b.clone()],
            onto: vec![zero.clone()],
            ..RebaseOptions::default()
        })
    });
    assert!(
        matches!(&err, MutateError::Immutable { commit_id, .. } if *commit_id == b_hex),
        "{err:?}"
    );
    // C inserted after A rewrites A's child B.
    let err = refused(&mut fx, |repo| {
        repo.rebase(&RebaseOptions {
            revisions: vec![c.clone()],
            insert_after: vec![a.clone()],
            ..RebaseOptions::default()
        })
    });
    assert!(
        matches!(&err, MutateError::Immutable { commit_id, .. } if *commit_id == b_hex),
        "{err:?}"
    );
}

#[test]
fn skip_emptied_abandons_a_commit_the_move_empties() {
    // D on A adds B's change again; onto B it is empty.
    for skip in [false, true] {
        let mut fx = base();
        let on = [fx.a.clone()];
        let d = add(&mut fx, &on, &[("b.txt", "b\n")], "D\n");
        let options = RebaseOptions {
            revisions: vec![d.clone()],
            onto: vec![fx.b.clone()],
            skip_emptied: skip,
            ..RebaseOptions::default()
        };
        let result = fx.repo.rebase(&options).expect("rebase");
        if skip {
            assert!(visible_all(&fx.root, &d).is_empty(), "the emptied D is abandoned");
            assert_eq!(result.abandoned_change_ids, std::slice::from_ref(&d));
            let at = change_id(&wc(&fx.root));
            assert_eq!(
                result.new_change_ids,
                std::slice::from_ref(&at),
                "D was @: a new @ replaces it"
            );
            assert_eq!(parents(&fx.root, &at), [fx.b.clone()]);
        } else {
            assert_eq!(parents(&fx.root, &d), [fx.b.clone()], "kept, empty");
            assert!(result.abandoned_change_ids.is_empty() && result.new_change_ids.is_empty());
        }
    }
}

#[test]
fn simplify_parents_drops_a_rebased_merges_redundant_parent() {
    for simplify in [false, true] {
        let mut fx = base();
        let on = [fx.c.clone(), fx.b.clone()];
        let m = add(&mut fx, &on, &[], "M\n");
        let on = [fx.zero.clone()];
        let x = add(&mut fx, &on, &[("x.txt", "x\n")], "X\n");
        let options = RebaseOptions {
            source: vec![fx.a.clone()],
            onto: vec![x.clone()],
            simplify_parents: simplify,
            ..RebaseOptions::default()
        };
        fx.repo.rebase(&options).expect("rebase");
        let expected = if simplify {
            vec![fx.c.clone()]
        } else {
            vec![fx.c.clone(), fx.b.clone()]
        };
        assert_eq!(parents(&fx.root, &m), expected, "--simplify-parents: {simplify}");
        assert_eq!(parents(&fx.root, &fx.a), [x]);
    }
}

/// The CLI's `test_rebase_skip_duplicate_divergent` setup on BASE: B rebased onto C (`B'`), its
/// old commit `Bold` (on A) made visible again — B is divergent — and `D` on `Bold`. Returns `D`.
fn divergent_b(fx: &mut Fx) -> ChangeId {
    let old_b = commit(&fx.root, &fx.b);
    fx.repo
        .rebase(&RebaseOptions {
            revisions: vec![fx.b.clone()],
            onto: vec![fx.c.clone()],
            ..RebaseOptions::default()
        })
        .expect("rebase");
    let repo = load(&fx.root);
    let mut tx = repo.start_transaction();
    pollster::block_on(tx.repo_mut().add_head(&old_b)).expect("add head");
    let d = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![old_b.id().clone()], old_b.tree())
            .set_description("D\n")
            .write(),
    )
    .expect("D");
    pollster::block_on(tx.commit("make B divergent")).expect("commit");
    assert_eq!(visible_all(&fx.root, &fx.b).len(), 2, "B is divergent");
    change_id(&d)
}

#[test]
fn a_divergent_twin_already_in_the_destination_is_abandoned_unless_kept() {
    for keep in [false, true] {
        let mut fx = base();
        let d = divergent_b(&mut fx);
        let c_hex = hex(&fx.root, &fx.c);
        let result = fx
            .repo
            .rebase(&RebaseOptions {
                source: vec![fx.c.clone()],
                onto: vec![d.clone()],
                keep_divergent: keep,
                ..RebaseOptions::default()
            })
            .expect("rebase");
        assert_op(&fx, &result, &format!("rebase commit {c_hex} and descendants"));
        assert_eq!(parents(&fx.root, &fx.c), std::slice::from_ref(&d), "keep: {keep}");
        if keep {
            assert!(result.abandoned_change_ids.is_empty());
            assert_eq!(visible_all(&fx.root, &fx.b).len(), 2, "B' kept on C");
        } else {
            assert_eq!(result.abandoned_change_ids, [fx.b.clone()], "B' abandoned");
            assert_eq!(visible_all(&fx.root, &fx.b).len(), 1, "only Bold is left");
        }
    }
}

// ── I1: `-s`/`-b` with `-A`/`-B` whose target lies inside the moved set ──────────

/// Deferred-work item I1 (2026-09-21): jj-lib's `compute_move_commits` replaces each new parent
/// inside the moved set with that commit's external ancestors and each new child inside it with
/// that commit's external descendants (`rewrite.rs:734-837` @ jj-lib 0.46.0). On linear BASE every
/// such move lands where the commits already are, so the verb writes nothing — exactly what the
/// CLI does (the parity oracle's `rebase_i1_*` scenarios); there is no up-front refusal. The
/// relocating case is [`i1_an_inside_target_with_an_outside_parent_relocates_the_source`].
#[test]
fn i1_source_or_branch_inserted_inside_the_moved_set_changes_nothing() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    let cases = [
        // -s A -A B: the new parent B and the new child C are both inside A::.
        RebaseOptions {
            source: vec![a.clone()],
            insert_after: vec![b.clone()],
            ..RebaseOptions::default()
        },
        // -s A -B C.
        RebaseOptions {
            source: vec![a.clone()],
            insert_before: vec![c.clone()],
            ..RebaseOptions::default()
        },
        // -b C -A B: roots(B..C) is C, the new child C is the target itself.
        RebaseOptions {
            branch: vec![c.clone()],
            insert_after: vec![b.clone()],
            ..RebaseOptions::default()
        },
        // -b A -B C: roots(B..A) is empty — "No revisions to rebase."
        RebaseOptions {
            branch: vec![a.clone()],
            insert_before: vec![c.clone()],
            ..RebaseOptions::default()
        },
    ];
    let before: Vec<Vec<ChangeId>> = [&a, &b, &c].iter().map(|id| parents(&fx.root, id)).collect();
    for options in cases {
        no_op(&mut fx, |repo| repo.rebase(&options));
    }
    let after: Vec<Vec<ChangeId>> = [&a, &b, &c].iter().map(|id| parents(&fx.root, id)).collect();
    assert_eq!(after, before, "the graph is unchanged");
}

/// I1 where the move relocates: B's descendant M is a merge of C and X, X a child of A outside
/// `B::`. `-A M` / `-B M` put the new parents inside `B::` — jj-lib replaces M (`-A`) or M's parents
/// C and X (`-B`) by the external ancestors of EACH: C's is A, X stays X — so B lands on the merge
/// of A and X, and C and M follow. The oracle's `rebase_i1_source_insert_after_merge` matches the
/// CLI.
#[test]
fn i1_an_inside_target_with_an_outside_parent_relocates_the_source() {
    for insert_after in [true, false] {
        let mut fx = base();
        let on = [fx.a.clone()];
        let x = add(&mut fx, &on, &[("x.txt", "x\n")], "X\n");
        let on = [fx.c.clone(), x.clone()];
        let m = add(&mut fx, &on, &[], "M\n");
        let b_hex = hex(&fx.root, &fx.b);
        let options = RebaseOptions {
            source: vec![fx.b.clone()],
            insert_after: if insert_after { vec![m.clone()] } else { vec![] },
            insert_before: if insert_after { vec![] } else { vec![m.clone()] },
            ..RebaseOptions::default()
        };
        let result = fx.repo.rebase(&options).expect("rebase");
        assert_op(&fx, &result, &format!("rebase commit {b_hex} and descendants"));
        let context = format!("-A: {insert_after}");
        assert_eq!(parents(&fx.root, &fx.b), [fx.a.clone(), x.clone()], "{context}");
        assert_eq!(parents(&fx.root, &fx.c), std::slice::from_ref(&fx.b), "{context}");
        assert_eq!(parents(&fx.root, &m), [fx.c.clone(), x.clone()], "{context}");
    }
}

// ── drop_actions agrees with the verb ──────────────────────────────────────────

/// The rebase options of a `drop_actions` rebase row.
fn row_options(verb: DropVerb, source: &ChangeId, location: &DropLocation) -> Option<RebaseOptions> {
    let one = vec![source.clone()];
    let mut options = RebaseOptions {
        onto: location.onto.clone(),
        insert_after: location.insert_after.clone(),
        insert_before: location.insert_before.clone(),
        ..RebaseOptions::default()
    };
    match verb {
        DropVerb::RebaseSource => options.source = one,
        DropVerb::RebaseRevisions => options.revisions = one,
        DropVerb::RebaseBranch => options.branch = one,
        _ => return None,
    }
    Some(options)
}

/// BASE's changes by index: root, A, B, C.
fn nth(fx: &Fx, index: usize) -> ChangeId {
    [&fx.zero, &fx.a, &fx.b, &fx.c][index].clone()
}

/// A one-target location: `onto` (0), `insert_after` (1) or `insert_before` (2).
fn location(kind: usize, target: ChangeId) -> DropLocation {
    let mut location = DropLocation::default();
    [
        &mut location.onto,
        &mut location.insert_after,
        &mut location.insert_before,
    ][kind]
        .push(target);
    location
}

/// For every source and one-target location on BASE: each rebase row `drop_actions` answers,
/// then the verb with the same form on the same state — it writes an operation exactly when the
/// row says Available, and refuses with the row's refusal when it says Refused. A row whose verb
/// wrote gets a fresh BASE for the next row (an undo would leave the rebased commits in the store,
/// and the next dry run would write them again under the pinned test timestamps).
#[test]
fn every_drop_actions_rebase_row_agrees_with_the_verb() {
    let query = |fx: &mut Fx, source: usize, kind: usize, target: usize| {
        let (source, location) = (nth(fx, source), location(kind, nth(fx, target)));
        let rows = fx
            .repo
            .drop_actions(&DropSource::Change(source.clone()), std::slice::from_ref(&location))
            .expect("drop actions");
        (source, location, rows.actions)
    };
    let mut checked = [0_usize; 3];
    let mut fx = base();
    for source in 1..4 {
        for kind in 0..3 {
            for target in 0..4 {
                let (mut source_id, mut at, mut rows) = query(&mut fx, source, kind, target);
                let verbs: Vec<DropVerb> = rows.iter().map(|row| row.verb).collect();
                for verb in verbs {
                    let Some(options) = row_options(verb, &source_id, &at) else {
                        continue;
                    };
                    let row = rows.iter().find(|row| row.verb == verb).expect("the row");
                    let context = format!("{verb:?} {source_id:?} {at:?}");
                    let before = head_op(&fx.root);
                    let result = fx.repo.rebase(&options);
                    let wrote = head_op(&fx.root) != before;
                    match row.outcome.status {
                        ActionStatus::Available => {
                            checked[0] += 1;
                            assert!(result.is_ok() && wrote, "{context}: {result:?}");
                            fx = base();
                            (source_id, at, rows) = query(&mut fx, source, kind, target);
                        }
                        ActionStatus::NoOp => {
                            checked[1] += 1;
                            let result = result.expect(&context);
                            assert!(!wrote, "{context}");
                            assert_eq!(result.new_op_id.0, before.0, "{context}");
                        }
                        ActionStatus::Refused => {
                            checked[2] += 1;
                            let err = result.expect_err(&context);
                            assert!(!wrote, "{context}");
                            assert_eq!(
                                format!("{:?}", Some(err)),
                                format!("{:?}", row.outcome.refusal),
                                "{context}"
                            );
                        }
                    }
                    let _ = fx.repo.take_warnings();
                }
            }
        }
    }
    assert!(checked.iter().all(|n| *n > 0), "every status was seen: {checked:?}");
}
