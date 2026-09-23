// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.8's two bookmark mutations (`Repo::bookmark_create`,
//! `Repo::bookmark_delete`).
//!
//! Two oracles, deliberately: the shipped READ (`Repo::list_bookmarks`), because that is what
//! a GUI re-reads after a mutation, and a raw jj-lib view for the facts the read deliberately
//! drops (an UNTRACKED remote bookmark). Every refusal additionally asserts the head operation
//! id is UNCHANGED — "it refused" and "it refused without writing an operation" are different
//! claims, and only the second is what NFR-R-2 pins.
//!
//! Bookmark state is always constructed IN-TEST via `test_helpers::{set_local_bookmark,
//! set_remote_bookmark}`: `tiny-3-commits` has zero bookmarks and fixture regeneration is
//! forbidden.

use std::env;
use std::path::Path;
use std::sync::LazyLock;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::RemoteRefState;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::{add_commit_off_root, add_divergent_twin, extract_fixture, set_local_bookmark, set_remote_bookmark};
use zanshin_jj::{BookmarkKind, ChangeId, MutateError, MutationResult, Repo};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
    env::set_var("JJ_USER", "Zanshin");
    env::set_var("JJ_EMAIL", "zanshin@localhost");
    env::set_var("JJ_OP_HOSTNAME", "localhost");
    env::set_var("JJ_OP_USERNAME", "zanshin");
});

/// A syntactically valid reverse-hex change id (the alphabet is `k`-`z`) that no commit in the
/// fixture carries. NOT a run of `z`s: reverse-hex `z` is `0`, so `zzz…` is a prefix of the
/// ROOT commit's all-zero change id and resolves.
const ABSENT_CHANGE_ID: &str = "pqrstuvwxyzklmnopqrstuvwxyzklmno";

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// Open the fixture as a raw jj-lib `Workspace` for oracle reads.
fn oracle_workspace(root: &Path) -> Workspace {
    Workspace::load(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load")
}

/// The fixture's working-copy commit hex, its change id, and the root commit's change id.
struct Layout {
    wc_commit_hex: String,
    root_change_id: ChangeId,
}

fn layout(root: &Path) -> Layout {
    let ws = oracle_workspace(root);
    let repo = pollster::block_on(ws.repo_loader().load_at_head()).expect("oracle load_at_head");
    let wc_id = repo
        .view()
        .get_wc_commit_id(ws.workspace_name())
        .expect("fixture has a working-copy commit")
        .clone();
    let root_commit = repo
        .store()
        .get_commit(repo.store().root_commit_id())
        .expect("root commit is readable");
    Layout {
        wc_commit_hex: wc_id.hex(),
        root_change_id: ChangeId(root_commit.change_id().reverse_hex()),
    }
}

/// Reverse-hex change id of the commit with the given hex id.
fn change_id_of(root: &Path, commit_hex: &str) -> ChangeId {
    let ws = oracle_workspace(root);
    let repo = pollster::block_on(ws.repo_loader().load_at_head()).expect("oracle load_at_head");
    let id = jj_lib::backend::CommitId::try_from_hex(commit_hex).expect("valid commit hex");
    let commit = repo.store().get_commit(&id).expect("commit is readable");
    ChangeId(commit.change_id().reverse_hex())
}

/// Local bookmark names in the head view, in jj-lib's lexicographic order — the raw oracle,
/// used where `list_bookmarks`' local/tracked-remote projection would hide the fact.
fn local_bookmark_names(root: &Path) -> Vec<String> {
    let ws = oracle_workspace(root);
    let repo = pollster::block_on(ws.repo_loader().load_at_head()).expect("oracle load_at_head");
    repo.view()
        .local_bookmarks()
        .map(|(name, _)| name.as_str().to_owned())
        .collect()
}

/// The commit hex a local bookmark points at, or `None` when it is absent.
fn local_bookmark_target(root: &Path, name: &str) -> Option<String> {
    let ws = oracle_workspace(root);
    let repo = pollster::block_on(ws.repo_loader().load_at_head()).expect("oracle load_at_head");
    let hex = repo
        .view()
        .get_local_bookmark(name.as_ref())
        .added_ids()
        .next()
        .map(jj_lib::object_id::ObjectId::hex);
    hex
}

/// The head operation's `(id, description)`.
fn head_op(repo: &Repo) -> (String, String) {
    let ops = repo.op_log(Some(1)).expect("op log is readable");
    let head = ops.first().expect("a repo always has a head operation");
    (head.id.0.clone(), head.description.clone())
}

/// Both bookmark verbs mint and abandon nothing, and never move `@` — asserted on every path
/// because `new_op_id` is the only [`MutationResult`] field the rest of this suite reads, so a
/// regression in the other three would ship green.
///
/// The expectation is structural rather than incidental: both verbs go through
/// `finish_or_no_op_at`, whose two exits (the committed one and `no_op_result`) each build this
/// same shape — which is exactly the kind of claim that is true by construction today and
/// silently false after a refactor.
fn assert_no_change_churn(result: &MutationResult, expected_wc: &ChangeId) {
    assert!(result.new_change_ids.is_empty(), "a bookmark verb mints no change");
    assert!(
        result.abandoned_change_ids.is_empty(),
        "a bookmark verb abandons no change"
    );
    assert_eq!(&result.working_copy_change_id, expected_wc, "`@` does not move");
}

// ── create: the happy paths ───────────────────────────────────────────────────

/// The default revision is the CLI's clap `default_value = "@"`, and the op-log description
/// is asserted VERBATIM — a Zanshin-created bookmark must be indistinguishable from a
/// CLI-created one (NFR-R-2).
#[test]
fn create_with_the_default_revision_targets_at_and_writes_the_cli_description() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    let wc_change_id = change_id_of(&fx.path, &lay.wc_commit_hex);
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before, _) = head_op(&repo);

    let result = repo.bookmark_create(&["feature".to_owned()], None).unwrap();

    assert_ne!(result.new_op_id.0, before, "a create always writes an operation");
    assert_no_change_churn(&result, &wc_change_id);
    let (after, description) = head_op(&repo);
    assert_eq!(result.new_op_id.0, after);
    assert_eq!(
        description,
        format!("create bookmark feature pointing to commit {}", lay.wc_commit_hex)
    );
    assert_eq!(local_bookmark_target(&fx.path, "feature"), Some(lay.wc_commit_hex));
    let listed = repo.list_bookmarks().unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].name, "feature");
    assert_eq!(listed[0].kind, BookmarkKind::Local);
}

/// An explicit `-r` targets THAT commit, not `@`.
#[test]
fn create_with_an_explicit_revision_targets_that_commit() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let target_hex = add_commit_off_root(&fx.path, "target of v1");
    let target = change_id_of(&fx.path, &target_hex);
    let mut repo = Repo::open(&fx.path).unwrap();

    repo.bookmark_create(&["v1".to_owned()], Some(&target)).unwrap();

    assert_eq!(local_bookmark_target(&fx.path, "v1"), Some(target_hex.clone()));
    let (_, description) = head_op(&repo);
    assert_eq!(
        description,
        format!("create bookmark v1 pointing to commit {target_hex}")
    );
}

/// Several names land in ONE operation, and the description joins them in ARGUMENT order —
/// `b, a`, not the sorted `a, b` a view walk would produce.
#[test]
fn create_with_several_names_writes_one_operation_in_argument_order() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();
    let ops_before = repo.op_log(None).unwrap().len();

    repo.bookmark_create(&["b".to_owned(), "a".to_owned()], None).unwrap();

    assert_eq!(
        repo.op_log(None).unwrap().len(),
        ops_before + 1,
        "both names must be created in a single transaction"
    );
    let (_, description) = head_op(&repo);
    assert_eq!(
        description,
        format!("create bookmark b, a pointing to commit {}", lay.wc_commit_hex),
        "argument order, not view order"
    );
    assert_eq!(local_bookmark_names(&fx.path), vec!["a".to_owned(), "b".to_owned()]);
}

/// The CLI allows a bookmark on the root commit — only a later `git export` objects
/// (`cli/tests/test_bookmark_command.rs:122-141` @ v0.44.0).
#[test]
fn create_on_the_root_commit_succeeds() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    repo.bookmark_create(&["at-root".to_owned()], Some(&lay.root_change_id))
        .unwrap();

    assert_eq!(local_bookmark_names(&fx.path), vec!["at-root".to_owned()]);
}

/// A same-name remote bookmark that is NOT tracked does not block create: the CLI's guard is
/// `has_tracked_remote_bookmarks`, tracked only. Read through the raw view because
/// `list_bookmarks` filters untracked remotes out.
#[test]
fn create_is_not_blocked_by_an_untracked_remote_of_the_same_name() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    set_remote_bookmark(&fx.path, "foo", "origin", &lay.wc_commit_hex, false);
    let mut repo = Repo::open(&fx.path).unwrap();

    repo.bookmark_create(&["foo".to_owned()], None).unwrap();

    assert_eq!(local_bookmark_names(&fx.path), vec!["foo".to_owned()]);
}

/// Nor does a tracked remote on the DEFAULT-IGNORED remote `git` — the colocated case the
/// CLI's `default_ignored_remote_name` exists for. The fixtures are git-backed, so the
/// exclusion is live here.
#[test]
fn create_is_not_blocked_by_a_tracked_remote_on_the_reserved_git_remote() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    set_remote_bookmark(&fx.path, "colocated", "git", &lay.wc_commit_hex, true);
    let mut repo = Repo::open(&fx.path).unwrap();

    repo.bookmark_create(&["colocated".to_owned()], None).unwrap();

    assert_eq!(local_bookmark_names(&fx.path), vec!["colocated".to_owned()]);
}

/// The mirror of the test above, on a NATIVE backend — where the same seeded state REFUSES.
///
/// `has_tracked_remote_bookmarks` only excludes the reserved `git` remote when
/// `get_git_backend` succeeds; on any other backend the remote matcher is `StringMatcher::all()`,
/// which excludes nothing. So a tracked `colocated@git` — meaningless on a native repo, but
/// perfectly representable in the view — DOES block `create colocated` there. Every other test in
/// this file runs on the git-backed `tiny-3-commits` and so takes the `if` arm; the `else` arm was
/// reached only by the native-backend Dart worker tests, none of which assert the difference. This
/// test is what pins it.
#[test]
fn create_is_blocked_by_a_tracked_git_remote_on_a_native_backend() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    let mut repo = Repo::init(tmp.path(), None).unwrap();
    let lay = layout(tmp.path());
    set_remote_bookmark(tmp.path(), "colocated", "git", &lay.wc_commit_hex, true);
    let (before, _) = head_op(&repo);

    let err = repo.bookmark_create(&["colocated".to_owned()], None).unwrap_err();

    assert!(
        matches!(&err, MutateError::BookmarkTrackedRemoteExists { name } if name == "colocated"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op(&repo).0, before, "a refusal writes no operation");
}

// ── create: the refusals ──────────────────────────────────────────────────────

#[test]
fn create_refuses_a_name_that_already_exists_without_writing_an_operation() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    set_local_bookmark(&fx.path, "feature", &[&lay.wc_commit_hex]);
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before, _) = head_op(&repo);

    let err = repo.bookmark_create(&["feature".to_owned()], None).unwrap_err();

    assert!(
        matches!(&err, MutateError::BookmarkExists { name } if name == "feature"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op(&repo).0, before, "a refusal writes no operation");
}

/// The CLI's per-name loop is FAIL-FAST, not validate-what-you-can: a run whose SECOND name
/// already exists creates nothing at all. The intuitive "create what you can" behaviour would
/// also pass a suite that only checked the error code, so the view is asserted too.
#[test]
fn create_is_fail_fast_so_an_offending_second_name_creates_nothing() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    set_local_bookmark(&fx.path, "existing", &[&lay.wc_commit_hex]);
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before, _) = head_op(&repo);

    let err = repo
        .bookmark_create(&["fresh".to_owned(), "existing".to_owned()], None)
        .unwrap_err();

    assert!(
        matches!(&err, MutateError::BookmarkExists { name } if name == "existing"),
        "unexpected error: {err:?}"
    );
    assert_eq!(
        local_bookmark_names(&fx.path),
        vec!["existing".to_owned()],
        "`fresh` must NOT have been created"
    );
    assert_eq!(head_op(&repo).0, before);
}

/// The deleted-but-tracked state gets its OWN code, because the remedy differs from
/// already-exists: untrack the remote, or (Story 9.11) use `bookmark set`.
#[test]
fn create_refuses_a_name_whose_remote_is_tracked_with_its_own_code() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    set_remote_bookmark(&fx.path, "foo", "origin", &lay.wc_commit_hex, true);
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before, _) = head_op(&repo);

    let err = repo.bookmark_create(&["foo".to_owned()], None).unwrap_err();

    assert!(
        matches!(&err, MutateError::BookmarkTrackedRemoteExists { name } if name == "foo"),
        "unexpected error: {err:?}"
    );
    assert!(local_bookmark_names(&fx.path).is_empty());
    assert_eq!(head_op(&repo).0, before);
}

#[test]
fn create_refuses_an_empty_name_list_and_an_empty_name() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before, _) = head_op(&repo);

    for names in [vec![], vec![String::new()]] {
        let err = repo.bookmark_create(&names, None).unwrap_err();
        assert!(
            matches!(err, MutateError::InvalidInput { .. }),
            "unexpected error: {err:?}"
        );
    }
    assert_eq!(head_op(&repo).0, before);
}

#[test]
fn create_refuses_an_unknown_revision() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before, _) = head_op(&repo);

    let err = repo
        .bookmark_create(&["feature".to_owned()], Some(&ChangeId(ABSENT_CHANGE_ID.to_owned())))
        .unwrap_err();

    assert!(
        matches!(&err, MutateError::ChangeNotFound { id } if id == ABSENT_CHANGE_ID),
        "unexpected error: {err:?}"
    );
    assert!(local_bookmark_names(&fx.path).is_empty());
    assert_eq!(head_op(&repo).0, before);
}

/// A DIVERGENT change id is refused, never guessed — the shipped `resolve_commit` contract,
/// which is also what the CLI's `resolve_single_rev` does.
#[test]
fn create_refuses_a_divergent_revision() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let original_hex = add_commit_off_root(&fx.path, "divergent base");
    let divergent = change_id_of(&fx.path, &original_hex);
    let _twin = add_divergent_twin(&fx.path, &original_hex, "divergent twin");
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before, _) = head_op(&repo);

    let err = repo
        .bookmark_create(&["feature".to_owned()], Some(&divergent))
        .unwrap_err();

    assert!(
        matches!(err, MutateError::ChangeNotFound { .. }),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op(&repo).0, before);
}

// ── delete ────────────────────────────────────────────────────────────────────

#[test]
fn delete_removes_an_exactly_named_bookmark_with_the_cli_description() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    set_local_bookmark(&fx.path, "feature", &[&lay.wc_commit_hex]);
    let wc_change_id = change_id_of(&fx.path, &lay.wc_commit_hex);
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before, _) = head_op(&repo);

    let result = repo.bookmark_delete(&["exact:feature".to_owned()]).unwrap();

    assert_ne!(result.new_op_id.0, before);
    assert_no_change_churn(&result, &wc_change_id);
    let (after, description) = head_op(&repo);
    assert_eq!(result.new_op_id.0, after);
    assert_eq!(description, "delete bookmark feature");
    assert!(local_bookmark_names(&fx.path).is_empty());
    assert!(repo.list_bookmarks().unwrap().is_empty());
}

/// A glob deletes every match and leaves the rest; the description lists the MATCHED names in
/// VIEW (lexicographic) order, which is `local_bookmarks_matching`'s own ordering.
#[test]
fn delete_with_a_glob_removes_only_the_matches_and_names_them_in_view_order() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    for name in ["foo-2", "foo-1", "bar"] {
        set_local_bookmark(&fx.path, name, &[&lay.wc_commit_hex]);
    }
    let mut repo = Repo::open(&fx.path).unwrap();

    repo.bookmark_delete(&["glob:\"foo-*\"".to_owned()]).unwrap();

    assert_eq!(local_bookmark_names(&fx.path), vec!["bar".to_owned()]);
    let (_, description) = head_op(&repo);
    assert_eq!(
        description, "delete bookmark foo-1, foo-2",
        "view order, not seed order"
    );
}

/// The trap: a BARE pattern is a GLOB, so `foo*` also matches `foo1`, while `exact:"foo*"`
/// reaches only the literal. Both halves asserted against the same seeded state.
#[test]
fn delete_treats_a_bare_pattern_as_a_glob_and_exact_as_a_literal() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    for name in ["foo*", "foo1"] {
        set_local_bookmark(&fx.path, name, &[&lay.wc_commit_hex]);
    }
    let mut repo = Repo::open(&fx.path).unwrap();

    // exact: reaches only the literal `foo*`.
    repo.bookmark_delete(&["exact:\"foo*\"".to_owned()]).unwrap();
    assert_eq!(local_bookmark_names(&fx.path), vec!["foo1".to_owned()]);

    // Re-seed and delete with the genuinely BARE pattern — no quotes, which is the form a
    // caller reaches for when they mean an exact name: both names go.
    set_local_bookmark(&fx.path, "foo*", &[&lay.wc_commit_hex]);
    repo.bookmark_delete(&["foo*".to_owned()]).unwrap();
    assert!(
        local_bookmark_names(&fx.path).is_empty(),
        "a bare pattern is a GLOB, so it matches `foo1` too"
    );
}

/// Matching nothing is a SUCCESS with NO operation written — the machine-readable form of the
/// CLI's "No bookmarks to delete." Never a refusal.
#[test]
fn delete_matching_nothing_writes_no_operation_and_returns_the_pre_call_head() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    let wc_change_id = change_id_of(&fx.path, &lay.wc_commit_hex);
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before, before_description) = head_op(&repo);

    let result = repo.bookmark_delete(&["nosuch".to_owned()]).unwrap();

    assert_eq!(result.new_op_id.0, before, "no operation is written");
    assert_eq!(head_op(&repo), (before, before_description));
    // The no-op exit (`no_op_result`) is supposed to build the SAME shape as the committed
    // one, so the other three fields are asserted on this path too.
    assert_no_change_churn(&result, &wc_change_id);
}

#[test]
fn delete_refuses_a_malformed_pattern_and_an_empty_pattern_list() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let (before, _) = head_op(&repo);

    let malformed = repo.bookmark_delete(&["nosuchkind:foo".to_owned()]).unwrap_err();
    // jj-lib's OWN reason must survive to the caller, not just the wrapper prefix: every
    // bad pattern shares the kind "Invalid string pattern", and the part that says WHICH
    // construct is wrong lives behind `#[source]`. Asserting the whole string here is what
    // makes dropping the chain a test failure rather than a silent loss of the remedy.
    assert!(
        matches!(
            &malformed,
            MutateError::InvalidInput { reason }
                if reason == "failed to parse name pattern: Invalid string pattern: \
                              Invalid string pattern kind `nosuchkind:`"
        ),
        "unexpected error: {malformed:?}"
    );
    let empty = repo.bookmark_delete(&[]).unwrap_err();
    assert!(
        matches!(empty, MutateError::InvalidInput { .. }),
        "unexpected error: {empty:?}"
    );
    assert_eq!(head_op(&repo).0, before);
}

/// Deleting the local bookmark leaves a TRACKED `name@origin` in place — jj's
/// "deleted, propagates on the next push" state, which `list_bookmarks` keeps reporting.
/// `View::set_local_bookmark_target` prunes only remote rows that are themselves ABSENT.
#[test]
fn delete_leaves_a_tracked_remote_bookmark_in_place() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    set_local_bookmark(&fx.path, "feature", &[&lay.wc_commit_hex]);
    set_remote_bookmark(&fx.path, "feature", "origin", &lay.wc_commit_hex, true);
    let mut repo = Repo::open(&fx.path).unwrap();

    repo.bookmark_delete(&["exact:feature".to_owned()]).unwrap();

    assert!(local_bookmark_names(&fx.path).is_empty(), "the local row is gone");
    let listed = repo.list_bookmarks().unwrap();
    assert_eq!(listed.len(), 1, "the tracked remote row survives: {listed:?}");
    assert_eq!(
        listed[0].kind,
        BookmarkKind::Remote {
            remote_name: "origin".to_owned()
        }
    );

    // And the remote ref is still TRACKED, not silently downgraded.
    let ws = oracle_workspace(&fx.path);
    let head = pollster::block_on(ws.repo_loader().load_at_head()).unwrap();
    let states: Vec<RemoteRefState> = head
        .view()
        .all_remote_bookmarks()
        .map(|(_, remote_ref)| remote_ref.state)
        .collect();
    assert_eq!(states, vec![RemoteRefState::Tracked]);
}

/// A CONFLICTED local bookmark deletes like any other — `RefTarget::absent()` removes it
/// regardless of conflict state.
#[test]
fn delete_removes_a_conflicted_bookmark() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    let other_hex = add_commit_off_root(&fx.path, "second side of the conflict");
    set_local_bookmark(&fx.path, "conflicted", &[&lay.wc_commit_hex, &other_hex]);
    let mut repo = Repo::open(&fx.path).unwrap();
    assert_eq!(local_bookmark_names(&fx.path), vec!["conflicted".to_owned()]);

    repo.bookmark_delete(&["exact:conflicted".to_owned()]).unwrap();

    assert!(local_bookmark_names(&fx.path).is_empty());
}

// ── round trip ────────────────────────────────────────────────────────────────

/// The pair a GUI actually performs, with both op-log descriptions asserted verbatim in one
/// place: create then delete must be indistinguishable from the CLI having done it (NFR-R-2).
#[test]
fn create_then_delete_writes_both_cli_descriptions() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let lay = layout(&fx.path);
    let mut repo = Repo::open(&fx.path).unwrap();

    repo.bookmark_create(&["feature".to_owned()], None).unwrap();
    repo.bookmark_delete(&["exact:feature".to_owned()]).unwrap();

    let ops = repo.op_log(Some(2)).unwrap();
    assert_eq!(ops[0].description, "delete bookmark feature");
    assert_eq!(
        ops[1].description,
        format!("create bookmark feature pointing to commit {}", lay.wc_commit_hex)
    );
    assert!(repo.list_bookmarks().unwrap().is_empty());
}
