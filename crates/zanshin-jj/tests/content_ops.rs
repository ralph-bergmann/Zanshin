// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.3's content ops: `Repo::restore` and `Repo::absorb`.
//!
//! Integration level is right: both entry points are public `Repo` methods and every row
//! needs a real repo with real trees.
//!
//! The committed fixtures give every commit exactly one unique file (`xtask`'s
//! `gen_fixture.rs` builds each tree from an empty base with only `commit-<n>.txt`), so no
//! fixture path survives across commits — which makes absorb's "an ancestor introduced this
//! line" precondition, and any multi-file restore, unconstructible from a fixture alone.
//! Every scenario is therefore built on purpose with `test_helpers::add_commit_with_files`;
//! the fixture supplies only the workspace, its `@`, and its op log.
//!
//! Two assertions repeat throughout, because they are what NFR-R-2 pins:
//! the op-log head DESCRIPTION after a success (byte-identical to the CLI's), and that a
//! refusal — or a legitimate NO-OP — leaves the head op id untouched.

use std::path::Path;
use std::sync::{Arc, LazyLock};
use std::{env, fs};

use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use test_helpers::{
    add_commit_with_files, add_conflicted_merge_off_root, add_conflicted_merge_with_extra_files, extract_fixture,
    set_tag, tree_hex, FixtureHandle,
};
use zanshin_jj::{AbsorbResult, ChangeId, MutateError, MutationResult, Repo};

// ── Harness ───────────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    // Same env pin as `tests/mutate.rs`: the immutability guard must see the fixture's own
    // config, not the developer's `~/.jjconfig.toml`.
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
    env::set_var("JJ_USER", "Zanshin");
    env::set_var("JJ_EMAIL", "zanshin@localhost");
    env::set_var("JJ_OP_HOSTNAME", "localhost");
    env::set_var("JJ_OP_USERNAME", "zanshin");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// The head-resolved jj-lib repo — the oracle these tests read trees and change ids from.
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

/// The reverse-hex change id of the commit named by `commit_hex`.
fn change_id_of(workspace_root: &Path, commit_hex: &str) -> ChangeId {
    let repo = jj_repo(workspace_root);
    let id = JjCommitId::try_from_hex(commit_hex).expect("hex commit id");
    ChangeId(repo.store().get_commit(&id).expect("commit").change_id().reverse_hex())
}

/// The hex tree id a change currently points at.
///
/// Trees are content-addressed, so comparing tree hexes is how these tests assert file
/// CONTENT without reading blobs: a purpose-built commit holding the expected files has the
/// same tree id as the restored/absorbed result.
fn tree_hex_of_change(workspace_root: &Path, change: &ChangeId) -> String {
    let mut repo = Repo::open(workspace_root).expect("fixture opens");
    let commit_hex = repo.get_change(change).expect("change resolves").commit_id.0;
    let jj = jj_repo(workspace_root);
    let id = JjCommitId::try_from_hex(&commit_hex).expect("hex commit id");
    jj.store()
        .get_commit(&id)
        .expect("commit")
        .tree_ids()
        .as_resolved()
        .expect("these fixtures' trees are conflict-free")
        .hex()
}

/// The head operation's id, so a test can assert that a refusal — or a no-op — wrote nothing.
fn head_op_id(repo: &mut Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).id.0
}

fn head_op_description(repo: &mut Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).description.clone()
}

fn write_repo_config(workspace_root: &Path, toml: &str) {
    fs::write(workspace_root.join(".jj").join("repo").join("config.toml"), toml).expect("repo config must be writable");
}

/// `A(a=A) -> B(a=B) -> C(a=B, b=C)` off root, plus the fixture's own unrelated `@`.
///
/// `C` deliberately touches a DIFFERENT file than `B` does, so a rebase of `C` after `B` is
/// rewritten stays conflict-free — which is what makes the reparent-vs-rebase distinction
/// observable as a plain tree-id comparison.
struct RestoreChain {
    fx: FixtureHandle,
    a: ChangeId,
    b: ChangeId,
    c: ChangeId,
    /// `B`'s ORIGINAL tree — the "unchanged" oracle for a no-op.
    b_tree_before: String,
    /// `C`'s ORIGINAL tree — preserved by `restore_descendants`, changed by a rebase.
    c_tree_before: String,
    /// The tree `{a: "A", b: "C"}` a plain (rebasing) restore leaves on `C`.
    c_tree_rebased: String,
}

fn restore_chain() -> RestoreChain {
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let a = add_commit_with_files(&fx.path, &[], &[("a.txt", "A\n")], "content A");
    let b = add_commit_with_files(&fx.path, &[&a], &[("a.txt", "B\n")], "content B");
    let c = add_commit_with_files(&fx.path, &[&b], &[("a.txt", "B\n"), ("b.txt", "C\n")], "content C");
    // Expectation oracles: standalone commits whose trees are the ones the assertions want.
    // Content-addressing makes their tree ids equal to the expected results'.
    let c_rebased = add_commit_with_files(&fx.path, &[], &[("a.txt", "A\n"), ("b.txt", "C\n")], "oracle rebased C");

    let b_tree_before = tree_hex(&fx.path, &b);
    let c_tree_before = tree_hex(&fx.path, &c);
    let c_tree_rebased = tree_hex(&fx.path, &c_rebased);
    let (a, b, c) = (
        change_id_of(&fx.path, &a),
        change_id_of(&fx.path, &b),
        change_id_of(&fx.path, &c),
    );
    RestoreChain {
        fx,
        a,
        b,
        c,
        b_tree_before,
        c_tree_before,
        c_tree_rebased,
    }
}

/// Asserts a successful restore's op-log head and `new_op_id` (NFR-R-2's two mandatory
/// checks). `destination_hex_before` is the destination's PRE-rewrite commit hex: the CLI
/// formats its description from `to_commit.id()`, which it resolved before rewriting.
fn assert_restore_op(repo: &mut Repo, result: &MutationResult, destination_hex_before: &str) {
    assert_eq!(
        head_op_description(repo),
        format!("restore into commit {destination_hex_before}")
    );
    assert_eq!(
        result.new_op_id.0,
        head_op_id(repo),
        "new_op_id must match the op-log head"
    );
}

/// The commit hex a change currently points at.
fn commit_hex_of_change(workspace_root: &Path, change: &ChangeId) -> String {
    Repo::open(workspace_root)
        .expect("fixture opens")
        .get_change(change)
        .expect("change resolves")
        .commit_id
        .0
}

// ── restore ───────────────────────────────────────────────────────────────────────

#[test]
fn restore_both_sides_replaces_the_destination_tree_and_records_the_cli_op_description() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let a_tree = tree_hex_of_change(&chain.fx.path, &chain.a);
    let b_hex_before = commit_hex_of_change(&chain.fx.path, &chain.b);

    let result = repo
        .restore(Some(chain.a.clone()), Some(chain.b.clone()), None, &[], false)
        .expect("restore B from A");

    assert_eq!(
        tree_hex_of_change(&chain.fx.path, &chain.b),
        a_tree,
        "B's tree is now A's"
    );
    assert!(result.new_change_ids.is_empty(), "restore mints nothing");
    assert!(result.abandoned_change_ids.is_empty(), "restore abandons nothing");
    let mut repo = Repo::open(&chain.fx.path).expect("fixture reopens");
    assert_restore_op(&mut repo, &result, &b_hex_before);
}

#[test]
fn restore_with_only_from_uses_the_working_copy_as_destination() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    // Move `@` onto `B` so the omitted `--into` has something with content to restore into.
    let wc = repo.edit(chain.b.clone()).expect("edit B").working_copy_change_id;
    assert_eq!(wc.0, chain.b.0, "@ is now B");
    let a_tree = tree_hex_of_change(&chain.fx.path, &chain.a);

    let result = repo
        .restore(Some(chain.a.clone()), None, None, &[], false)
        .expect("restore @ from A");

    assert_eq!(tree_hex_of_change(&chain.fx.path, &chain.b), a_tree);
    assert_eq!(result.working_copy_change_id.0, chain.b.0, "@ stays on B");
}

#[test]
fn restore_with_only_into_uses_the_working_copy_as_source() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    // `@` is the fixture's own empty commit off root, so restoring INTO `B` FROM `@` empties
    // `B` — the observable effect of the omitted `--from` defaulting to `@`.
    let wc_change = repo.status().expect("status").working_copy_change_id;
    let wc_tree = tree_hex_of_change(&chain.fx.path, &wc_change);

    repo.restore(None, Some(chain.b.clone()), None, &[], false)
        .expect("restore B from @");

    assert_eq!(
        tree_hex_of_change(&chain.fx.path, &chain.b),
        wc_tree,
        "B's tree is now @'s"
    );
}

#[test]
fn restore_with_neither_side_restores_the_working_copy_from_its_parent() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    repo.edit(chain.b.clone()).expect("edit B");
    let a_tree = tree_hex_of_change(&chain.fx.path, &chain.a);

    let result = repo.restore(None, None, None, &[], false).expect("restore @ from @-");

    assert_eq!(
        tree_hex_of_change(&chain.fx.path, &chain.b),
        a_tree,
        "@ is restored from its parent tree — its own diff is undone"
    );
    let mut repo = Repo::open(&chain.fx.path).expect("fixture reopens");
    assert_eq!(
        repo.get_change(&chain.b).expect("B resolves").description,
        "content B",
        "the description survives — this is `jj restore`, not `jj abandon`"
    );
    assert_eq!(result.working_copy_change_id.0, chain.b.0);
}

#[test]
fn restore_changes_in_undoes_that_commits_own_diff() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let a_tree = tree_hex_of_change(&chain.fx.path, &chain.a);

    repo.restore(None, None, Some(chain.b.clone()), &[], false)
        .expect("restore --changes-in B");

    assert_eq!(tree_hex_of_change(&chain.fx.path, &chain.b), a_tree);
}

#[test]
fn restore_with_a_path_filter_touches_only_the_matching_path() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let a = add_commit_with_files(&fx.path, &[], &[("a.txt", "A\n"), ("b.txt", "A-only\n")], "content A");
    let b = add_commit_with_files(&fx.path, &[&a], &[("a.txt", "B\n"), ("b.txt", "B-only\n")], "content B");
    // `{a: "A", b: "B-only"}` — a.txt takes A's content, b.txt keeps B's.
    let expected = add_commit_with_files(&fx.path, &[], &[("a.txt", "A\n"), ("b.txt", "B-only\n")], "oracle");
    let expected_tree = tree_hex(&fx.path, &expected);
    let (a, b) = (change_id_of(&fx.path, &a), change_id_of(&fx.path, &b));
    let mut repo = Repo::open(&fx.path).expect("fixture opens");

    repo.restore(Some(a), Some(b.clone()), None, &["a.txt".to_owned()], false)
        .expect("restore a.txt only");

    assert_eq!(tree_hex_of_change(&fx.path, &b), expected_tree);
}

#[test]
fn restore_of_identical_trees_writes_no_operation() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    // Source == destination: the selected tree is trivially the destination's own.
    let result = repo
        .restore(Some(chain.b.clone()), Some(chain.b.clone()), None, &[], false)
        .expect("a no-op restore is a success, not an error");

    assert_eq!(
        head_op_id(&mut repo),
        before_op,
        "no operation may be written when nothing changed"
    );
    assert_eq!(
        result.new_op_id.0, before_op,
        "new_op_id carries the PRE-CALL head on the no-op path"
    );
    assert_eq!(tree_hex_of_change(&chain.fx.path, &chain.b), chain.b_tree_before);
}

#[test]
fn restore_descendants_preserves_child_content_instead_of_rebasing_it() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");

    repo.restore(Some(chain.a.clone()), Some(chain.b.clone()), None, &[], true)
        .expect("restore with --restore-descendants");

    assert_eq!(
        tree_hex_of_change(&chain.fx.path, &chain.c),
        chain.c_tree_before,
        "a reparented child keeps its own tree verbatim"
    );
}

#[test]
fn restore_without_restore_descendants_rebases_the_child() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");

    repo.restore(Some(chain.a.clone()), Some(chain.b.clone()), None, &[], false)
        .expect("restore, rebasing descendants");

    assert_eq!(
        tree_hex_of_change(&chain.fx.path, &chain.c),
        chain.c_tree_rebased,
        "a rebased child re-applies its own diff onto the new parent"
    );
    // Guard against the two oracles accidentally coinciding, which would make the
    // reparent test above vacuous.
    assert_ne!(chain.c_tree_rebased, chain.c_tree_before);
}

#[test]
fn restore_refuses_changes_in_combined_with_from_or_into() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    for (from, into) in [(Some(chain.a.clone()), None), (None, Some(chain.b.clone()))] {
        let err = repo
            .restore(from, into, Some(chain.c.clone()), &[], false)
            .expect_err("the CLI's clap refuses this combination");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason } if reason.contains("cannot be combined")),
            "unexpected error: {err:?}"
        );
    }
    assert_eq!(head_op_id(&mut repo), before_op, "a refusal writes no operation");
}

#[test]
fn restore_into_the_root_commit_is_refused_as_immutable() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let root_hex = jj_repo(&chain.fx.path).store().root_commit_id().hex();
    let root_change = change_id_of(&chain.fx.path, &root_hex);
    let before_op = head_op_id(&mut repo);

    let err = repo
        .restore(Some(chain.a.clone()), Some(root_change), None, &[], false)
        .expect_err("root is always inside `::(immutable_heads() | root())`");

    assert!(
        matches!(&err, MutateError::Immutable { commit_id } if *commit_id == root_hex),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn restore_into_an_immutable_commit_is_refused_and_writes_no_operation() {
    pin_env();
    let chain = restore_chain();
    // `tags()` is a term of `builtin_immutable_heads()`, so tagging `C` makes its whole
    // ancestry — `B` included — immutable without touching the config.
    let c_hex = Repo::open(&chain.fx.path)
        .expect("fixture opens")
        .get_change(&chain.c)
        .expect("C resolves")
        .commit_id
        .0;
    set_tag(&chain.fx.path, "v1", &[&c_hex]);
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let err = repo
        .restore(Some(chain.a.clone()), Some(chain.b.clone()), None, &[], false)
        .expect_err("B is an ancestor of the tagged C");

    assert!(
        matches!(err, MutateError::Immutable { .. }),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn restore_with_a_bogus_id_on_any_side_is_refused_and_writes_no_operation() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);
    let bogus = ChangeId("nonexistentchangeid".to_owned());

    let cases: [(Option<ChangeId>, Option<ChangeId>, Option<ChangeId>); 3] = [
        (Some(bogus.clone()), Some(chain.b.clone()), None),
        (Some(chain.a.clone()), Some(bogus.clone()), None),
        (None, None, Some(bogus.clone())),
    ];
    for (from, into, changes_in) in cases {
        let err = repo
            .restore(from, into, changes_in, &[], false)
            .expect_err("a bogus id must not resolve");
        assert!(
            matches!(&err, MutateError::ChangeNotFound { id } if id == &bogus.0),
            "unexpected error: {err:?}"
        );
    }
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn restore_with_a_malformed_path_is_refused_and_writes_no_operation() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let err = repo
        .restore(
            Some(chain.a.clone()),
            Some(chain.b.clone()),
            None,
            &["/absolute.txt".to_owned()],
            false,
        )
        .expect_err("a leading slash is not a repo path");

    assert!(
        matches!(&err, MutateError::InvalidInput { reason } if reason.contains("invalid path")),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn restore_reports_a_config_fault_rather_than_falling_back_to_the_builtin_immutable_set() {
    pin_env();
    let chain = restore_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);
    write_repo_config(
        &chain.fx.path,
        "[revset-aliases]\n'immutable_heads()' = 'bogus_function()'\n",
    );

    let err = repo
        .restore(Some(chain.a.clone()), Some(chain.b.clone()), None, &[], false)
        .expect_err("an unparseable immutable_heads() alias must not be ignored");

    // The pre-verb snapshot parses `immutable_heads()` first (Story 9.26), as the CLI does at
    // start-up; the op log is read back once the alias is repaired, since every verb refuses
    // while it is broken.
    assert!(
        matches!(
            err,
            MutateError::Precondition(zanshin_jj::PreconditionError::Config { .. })
        ),
        "unexpected error: {err:?}"
    );
    write_repo_config(&chain.fx.path, "");
    assert_eq!(head_op_id(&mut repo), before_op);
}

// ── absorb ────────────────────────────────────────────────────────────────────────

/// `A(a="one\ntwo\nthree\n") -> S(a="one\nCHANGED\nthree\n")`: `A` introduced every line, so
/// `S`'s edit annotates back to `A` and is absorbable into it.
struct AbsorbChain {
    fx: FixtureHandle,
    a: ChangeId,
    s: ChangeId,
    /// `A`'s tree once the hunk has moved into it.
    a_tree_absorbed: String,
}

fn absorb_chain() -> AbsorbChain {
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let a = add_commit_with_files(&fx.path, &[], &[("a.txt", "one\ntwo\nthree\n")], "ancestor");
    let s = add_commit_with_files(&fx.path, &[&a], &[("a.txt", "one\nCHANGED\nthree\n")], "source");
    let absorbed = add_commit_with_files(&fx.path, &[], &[("a.txt", "one\nCHANGED\nthree\n")], "oracle absorbed");
    let a_tree_absorbed = tree_hex(&fx.path, &absorbed);
    AbsorbChain {
        a: change_id_of(&fx.path, &a),
        s: change_id_of(&fx.path, &s),
        a_tree_absorbed,
        fx,
    }
}

/// Asserts a successful absorb's op-log head and `new_op_id`.
fn assert_absorb_op(repo: &mut Repo, result: &AbsorbResult, destinations: usize) {
    assert_eq!(
        head_op_description(repo),
        format!("absorb changes into {destinations} commits")
    );
    assert_eq!(
        result.mutation.new_op_id.0,
        head_op_id(repo),
        "new_op_id must match the op-log head"
    );
}

#[test]
fn absorb_moves_the_hunk_into_the_annotating_ancestor() {
    pin_env();
    let chain = absorb_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");

    let result = repo
        .absorb(Some(chain.s.clone()), None, &[])
        .expect("the edited line was introduced by A");

    assert_eq!(
        result
            .rewritten_change_ids
            .iter()
            .map(|c| c.0.clone())
            .collect::<Vec<_>>(),
        vec![chain.a.0.clone()],
        "the hunk lands in A"
    );
    assert_eq!(
        tree_hex_of_change(&chain.fx.path, &chain.a),
        chain.a_tree_absorbed,
        "A now holds the absorbed content"
    );
    assert!(result.skipped_paths.is_empty());
    assert!(result.mutation.new_change_ids.is_empty());
    assert!(result.mutation.abandoned_change_ids.is_empty());
    // jj-lib's `num_rebased` EXCLUDES the destination but INCLUDES the rewritten source, so
    // absorbing S's only hunk into A counts exactly one: S itself, reparented onto the new A.
    // Asserted here rather than only on the no-op branch, which returns a hardcoded 0.
    assert_eq!(result.num_rebased, 1);
    assert_eq!(
        result.source_change_id.as_ref().map(|c| c.0.clone()),
        Some(chain.s.0.clone()),
        "the source survives: it still carries a description, so it is not discardable"
    );
    let mut repo = Repo::open(&chain.fx.path).expect("fixture reopens");
    assert_absorb_op(&mut repo, &result, 1);
}

/// The `None` arm of `AbsorbResult::source_change_id` on a REAL absorb (the no-op branch
/// returns a hardcoded `None`, which proves nothing about it): a source whose whole diff
/// moves and which carries no description becomes discardable, and jj-lib abandons it.
#[test]
fn absorb_abandons_a_discardable_source_and_reports_no_source_change_id() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let a = add_commit_with_files(&fx.path, &[], &[("a.txt", "one\ntwo\nthree\n")], "ancestor");
    // EMPTY description: once its only hunk has been absorbed the source has neither a diff
    // nor a description left, which is jj-lib's definition of discardable.
    let s = add_commit_with_files(&fx.path, &[&a], &[("a.txt", "one\nCHANGED\nthree\n")], "");
    let (a, s) = (change_id_of(&fx.path, &a), change_id_of(&fx.path, &s));
    let mut repo = Repo::open(&fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let result = repo.absorb(Some(s), None, &[]).expect("the whole diff absorbs into A");

    assert_eq!(
        result
            .rewritten_change_ids
            .iter()
            .map(|c| c.0.clone())
            .collect::<Vec<_>>(),
        vec![a.0.clone()]
    );
    assert!(
        result.source_change_id.is_none(),
        "a discardable source is abandoned, not rewritten"
    );
    let mut repo = Repo::open(&fx.path).expect("fixture reopens");
    assert_ne!(head_op_id(&mut repo), before_op, "this absorb DID write an operation");
    assert_absorb_op(&mut repo, &result, 1);
}

#[test]
fn absorb_defaults_the_source_to_the_working_copy() {
    pin_env();
    let chain = absorb_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    repo.edit(chain.s.clone()).expect("edit S");

    let result = repo.absorb(None, None, &[]).expect("absorb from @");

    assert_eq!(
        result
            .rewritten_change_ids
            .iter()
            .map(|c| c.0.clone())
            .collect::<Vec<_>>(),
        vec![chain.a.0.clone()]
    );
}

#[test]
fn absorb_with_destinations_that_exclude_the_ancestor_absorbs_nothing_and_writes_no_operation() {
    pin_env();
    let chain = absorb_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    // `@` is the fixture's own commit off root — unrelated to S's ancestry, so the
    // annotation finds no destination inside the domain.
    let result = repo
        .absorb(Some(chain.s.clone()), Some("@"), &[])
        .expect("an empty destination set is a no-op, not an error");

    assert!(result.rewritten_change_ids.is_empty());
    assert_eq!(head_op_id(&mut repo), before_op, "no operation may be written");
    assert_eq!(result.mutation.new_op_id.0, before_op);
    assert!(result.source_change_id.is_none());
    assert_eq!(result.num_rebased, 0);
}

#[test]
fn absorb_with_a_path_filter_moves_only_the_matching_paths_hunks() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let a = add_commit_with_files(&fx.path, &[], &[("a.txt", "a1\n"), ("b.txt", "b1\n")], "ancestor");
    let s = add_commit_with_files(&fx.path, &[&a], &[("a.txt", "a2\n"), ("b.txt", "b2\n")], "source");
    // Only a.txt's hunk moves, so A ends up `{a: "a2", b: "b1"}`.
    let expected = add_commit_with_files(&fx.path, &[], &[("a.txt", "a2\n"), ("b.txt", "b1\n")], "oracle");
    let expected_tree = tree_hex(&fx.path, &expected);
    let (a, s) = (change_id_of(&fx.path, &a), change_id_of(&fx.path, &s));
    let mut repo = Repo::open(&fx.path).expect("fixture opens");

    let result = repo
        .absorb(Some(s.clone()), None, &["a.txt".to_owned()])
        .expect("absorb a.txt only");

    assert_eq!(tree_hex_of_change(&fx.path, &a), expected_tree);
    assert!(
        result.source_change_id.is_some(),
        "the source survives — b.txt's change is still in it"
    );
    assert_eq!(result.source_change_id.expect("source survived").0, s.0);
}

#[test]
fn absorb_of_a_newly_added_file_absorbs_nothing_and_writes_no_operation() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let a = add_commit_with_files(&fx.path, &[], &[("a.txt", "a1\n")], "ancestor");
    // The source only ADDS b.txt: there is no prior content to annotate, so jj-lib skips it.
    let s = add_commit_with_files(&fx.path, &[&a], &[("a.txt", "a1\n"), ("b.txt", "new\n")], "source");
    let s = change_id_of(&fx.path, &s);
    let mut repo = Repo::open(&fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let result = repo
        .absorb(Some(s), None, &[])
        .expect("nothing to absorb is not an error");

    assert!(result.rewritten_change_ids.is_empty());
    assert!(
        result.skipped_paths.is_empty(),
        "an added file is skipped silently, not warned about"
    );
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn absorb_reports_a_path_jj_lib_refuses_to_split_with_its_verbatim_reason() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    // The source's parent holds an unresolved CONFLICT at `conflicted.txt`, which jj-lib's
    // `to_file_value` refuses to split.
    let merge = add_conflicted_merge_off_root(&fx.path);
    let s = add_commit_with_files(&fx.path, &[&merge], &[("conflicted.txt", "resolved\n")], "source");
    let s = change_id_of(&fx.path, &s);
    let mut repo = Repo::open(&fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let result = repo
        .absorb(Some(s), None, &[])
        .expect("a skipped path is a warning in the CLI, not a failure");
    let warnings = repo.take_warnings();

    let skipped: Vec<(String, String)> = result
        .skipped_paths
        .iter()
        .map(|p| (p.path.clone(), p.reason.clone()))
        .collect();
    assert_eq!(
        skipped,
        vec![("conflicted.txt".to_owned(), "Is a conflict".to_owned())],
        "the (path, reason) pair is forwarded verbatim from jj-lib"
    );
    // Story 9.32: the CLI's one warning per skipped path (`absorb.rs:155-158`).
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, zanshin_jj::WarningKind::AbsorbPathSkipped);
    assert_eq!(warnings[0].message, "Skipping conflicted.txt: Is a conflict");
    assert!(result.rewritten_change_ids.is_empty());
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn absorb_keeps_absorbing_the_other_paths_when_one_is_skipped() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    // Only the RIGHT side introduces `clean.txt`, so the merge resolves it cleanly (and its
    // line annotates unambiguously to that side) while still conflicting at
    // `conflicted.txt`. That is the one state where a skip and a successful absorb meet in a
    // single call.
    let merge = add_conflicted_merge_with_extra_files(&fx.path, &[("clean.txt", "c1\n")]);
    let s = add_commit_with_files(
        &fx.path,
        &[&merge],
        &[("conflicted.txt", "resolved\n"), ("clean.txt", "c2\n")],
        "source",
    );
    let s = change_id_of(&fx.path, &s);
    let mut repo = Repo::open(&fx.path).expect("fixture opens");

    let result = repo
        .absorb(Some(s), None, &[])
        .expect("a skipped path is a warning in the CLI, not a failure");

    assert_eq!(
        result.skipped_paths.iter().map(|p| p.path.clone()).collect::<Vec<_>>(),
        vec!["conflicted.txt".to_owned()],
        "the conflicted path is the only one jj-lib refuses to split"
    );
    assert_eq!(
        result.rewritten_change_ids.len(),
        1,
        "the skip must not stop clean.txt's hunk from landing in the side that introduced it"
    );
    let mut repo = Repo::open(&fx.path).expect("fixture reopens");
    assert_absorb_op(&mut repo, &result, 1);
}

/// A skip and an `Immutable` refusal in ONE call (Story 9.32): the CLI prints its per-path
/// "Skipping …" warning before `check_rewritable` refuses the destinations, so the warning
/// survives the refusal — it rides the error arm through [`Repo::take_warnings`].
#[test]
fn absorb_keeps_its_skipped_path_warning_when_the_destination_is_immutable() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let merge = add_conflicted_merge_with_extra_files(&fx.path, &[("clean.txt", "c1\n")]);
    let s = add_commit_with_files(
        &fx.path,
        &[&merge],
        &[("conflicted.txt", "resolved\n"), ("clean.txt", "c2\n")],
        "source",
    );
    let s = change_id_of(&fx.path, &s);
    // Tagging the merge makes both sides immutable, so `clean.txt`'s destination — the side
    // that introduced it — is refused once `into` is widened past the `mutable()` default.
    set_tag(&fx.path, "v1", &[&merge]);
    let mut repo = Repo::open(&fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let err = repo
        .absorb(Some(s), Some("all()"), &[])
        .expect_err("the destination is immutable");
    let warnings = repo.take_warnings();

    assert!(
        matches!(err, MutateError::Immutable { .. }),
        "unexpected error: {err:?}"
    );
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, zanshin_jj::WarningKind::AbsorbPathSkipped);
    assert_eq!(warnings[0].message, "Skipping conflicted.txt: Is a conflict");
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn absorb_into_an_immutable_destination_is_refused_and_writes_no_operation() {
    pin_env();
    let chain = absorb_chain();
    // Tag A so it is immutable, then widen `into` past the `mutable()` default so the
    // annotation still targets it — the only way this refusal is reachable.
    let a_hex = Repo::open(&chain.fx.path)
        .expect("fixture opens")
        .get_change(&chain.a)
        .expect("A resolves")
        .commit_id
        .0;
    set_tag(&chain.fx.path, "v1", &[&a_hex]);
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let err = repo
        .absorb(Some(chain.s.clone()), Some("all()"), &[])
        .expect_err("A is tagged, hence immutable");

    assert!(
        matches!(&err, MutateError::Immutable { commit_id } if *commit_id == a_hex),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn absorb_with_a_syntactically_invalid_destination_revset_is_refused() {
    pin_env();
    let chain = absorb_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let err = repo
        .absorb(Some(chain.s.clone()), Some("bogus_function()"), &[])
        .expect_err("unknown revset function");

    assert!(
        matches!(err, MutateError::RevsetParseError { .. }),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn absorb_with_an_unresolvable_destination_symbol_is_refused() {
    pin_env();
    let chain = absorb_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let err = repo
        .absorb(Some(chain.s.clone()), Some("nonexistent-bookmark"), &[])
        .expect_err("no such bookmark");

    assert!(
        matches!(err, MutateError::RevsetResolutionError { .. }),
        "the parse/resolution split is preserved, not collapsed: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn absorb_with_a_bogus_source_is_refused_and_writes_no_operation() {
    pin_env();
    let chain = absorb_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let err = repo
        .absorb(Some(ChangeId("nonexistentchangeid".to_owned())), None, &[])
        .expect_err("a bogus source must not resolve");

    assert!(
        matches!(&err, MutateError::ChangeNotFound { id } if id == "nonexistentchangeid"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn absorb_with_a_malformed_path_is_refused_and_writes_no_operation() {
    pin_env();
    let chain = absorb_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);

    let err = repo
        .absorb(Some(chain.s.clone()), None, &["trailing/".to_owned()])
        .expect_err("a trailing slash is not a repo path");

    assert!(
        matches!(&err, MutateError::InvalidInput { reason } if reason.contains("invalid path")),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before_op);
}

#[test]
fn absorb_reports_a_config_fault_rather_than_falling_back_to_the_builtin_immutable_set() {
    pin_env();
    let chain = absorb_chain();
    let mut repo = Repo::open(&chain.fx.path).expect("fixture opens");
    let before_op = head_op_id(&mut repo);
    write_repo_config(
        &chain.fx.path,
        "[revset-aliases]\n'immutable_heads()' = 'bogus_function()'\n",
    );

    let err = repo
        .absorb(Some(chain.s.clone()), None, &[])
        .expect_err("an unparseable immutable_heads() alias must not be ignored");

    // The pre-verb snapshot parses `immutable_heads()` first (Story 9.26), as the CLI does at
    // start-up; the op log is read back once the alias is repaired, since every verb refuses
    // while it is broken.
    assert!(
        matches!(
            err,
            MutateError::Precondition(zanshin_jj::PreconditionError::Config { .. })
        ),
        "unexpected error: {err:?}"
    );
    write_repo_config(&chain.fx.path, "");
    assert_eq!(head_op_id(&mut repo), before_op);
}
