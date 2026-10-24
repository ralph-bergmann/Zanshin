// SPDX-License-Identifier: MIT

//! `Repo::op_integrate` — the CLI's `jj op integrate` @ v0.46.0 (Story 9.12): an operation already
//! in the log changes nothing, an unpublished descendant of the head becomes the head, an
//! unpublished sibling is merged with the head in a `reconcile divergent operations` operation —
//! all without a pre-verb snapshot.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::{OperationId, RefTarget};
use jj_lib::ref_name::RefNameBuf;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;
use test_helpers::extract_fixture;
use zanshin_jj::{MutateError, Repo};

/// The op heads on disk, by id.
fn op_heads(root: &Path) -> BTreeSet<String> {
    fs::read_dir(root.join(".jj").join("repo").join("op_heads").join("heads"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

/// The head operation's id.
fn head(repo: &mut Repo) -> String {
    repo.op_log(Some(1)).unwrap().swap_remove(0).id.0
}

/// Writes an operation on top of the operation `parent` (hex) that sets the bookmark `name` to the
/// root commit, through jj-lib, and leaves it UNPUBLISHED (the CLI's `--no-integrate-operation`);
/// returns its id.
fn unpublished_op(root: &Path, parent: &str, name: &str) -> String {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let loader = workspace.repo_loader();
    let parent = OperationId::try_from_hex(parent).expect("hex");
    let parent = pollster::block_on(loader.load_operation(&parent)).expect("the parent operation");
    let repo = pollster::block_on(loader.load_at(&parent)).expect("the repo at it");
    let mut tx = repo.start_transaction();
    let root_commit = repo.store().root_commit_id().clone();
    let bookmark: RefNameBuf = name.into();
    tx.repo_mut()
        .set_local_bookmark_target(&bookmark, RefTarget::normal(root_commit));
    let unpublished = pollster::block_on(tx.write(format!("set bookmark {name}"))).expect("write the operation");
    unpublished.leave_unpublished().op_id().hex()
}

/// `op integrate @-`: already in the log — the head and the op heads stay, nothing is
/// reconciled, no pre-verb snapshot runs.
#[test]
fn op_integrate_of_an_operation_in_the_log_changes_nothing() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = head(&mut repo);
    let heads = op_heads(&fx.path);
    let _ = repo.take_precondition();

    let result = repo.op_integrate("@-").unwrap();

    assert_eq!(result.head_op_id.0, before);
    assert!(!result.reconciled);
    assert!(repo.take_precondition().is_none(), "no pre-verb snapshot");
    assert_eq!(op_heads(&fx.path), heads);
}

/// An unpublished operation on top of the head becomes the head; nothing is merged.
#[test]
fn op_integrate_of_an_unpublished_child_of_the_head_makes_it_the_head() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = head(&mut repo);
    let unpublished = unpublished_op(&fx.path, &before, "integrated");
    assert_eq!(head(&mut repo), before, "not in the log yet");

    let result = repo.op_integrate(&unpublished).unwrap();

    assert_eq!(result.head_op_id.0, unpublished);
    assert!(!result.reconciled);
    assert_eq!(op_heads(&fx.path), BTreeSet::from([unpublished.clone()]));
    assert_eq!(head(&mut repo), unpublished);
    let bookmarks = repo.list_bookmarks(&crate::all_remotes()).unwrap();
    assert!(bookmarks.iter().any(|b| b.name == "integrated"), "{bookmarks:?}");
}

/// An unpublished operation on an older operation diverges from the head: it is merged with it in
/// a `reconcile divergent operations` operation recorded in this workspace.
#[test]
fn op_integrate_of_an_unpublished_sibling_reconciles_it_with_the_head() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let older = head(&mut repo);
    repo.bookmark_create(&["later".to_owned()], None).unwrap();
    let current = head(&mut repo);
    let unpublished = unpublished_op(&fx.path, &older, "sibling");

    let result = repo.op_integrate(&unpublished[..12]).unwrap();

    assert!(result.reconciled);
    assert_eq!(op_heads(&fx.path), BTreeSet::from([result.head_op_id.0.clone()]));
    let merge = repo.op_log(Some(1)).unwrap().swap_remove(0);
    assert_eq!(merge.id, result.head_op_id);
    assert_eq!(merge.description, "reconcile divergent operations");
    assert_eq!(merge.workspace_name.as_deref(), Some("default"));
    assert!(merge.tags.is_empty(), "no `args` attribute");
    let parents: BTreeSet<String> = merge.parent_ids.iter().map(|id| id.0.clone()).collect();
    assert_eq!(parents, BTreeSet::from([current, unpublished]));
    let names: BTreeSet<String> = repo
        .list_bookmarks(&crate::all_remotes())
        .unwrap()
        .into_iter()
        .map(|b| b.name)
        .collect();
    assert!(names.contains("later") && names.contains("sibling"), "{names:?}");
}

/// Unknown or malformed operations refuse with the opset errors; the op heads stay.
#[test]
fn op_integrate_of_an_unknown_operation_refuses() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let heads = op_heads(&fx.path);

    let err = repo.op_integrate("ffffffffffff").expect_err("unknown");
    assert!(matches!(err, MutateError::OperationNotFound { .. }), "{err:?}");
    let err = repo.op_integrate("zz").expect_err("not hex");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    assert_eq!(op_heads(&fx.path), heads);
}

/// The CLI's `workspace_helper_no_snapshot` start-up runs first: an `immutable_heads()` alias that
/// does not parse refuses the call before anything is integrated, and no snapshot report is left.
#[test]
fn op_integrate_refuses_a_broken_immutable_heads_alias_at_start_up() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = head(&mut repo);
    let unpublished = unpublished_op(&fx.path, &before, "integrated");
    let heads = op_heads(&fx.path);
    fs::write(
        fx.path.join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'immutable_heads()' = 'bogus_function()'\n",
    )
    .unwrap();

    let err = repo.op_integrate(&unpublished).expect_err("the start-up refuses");

    assert!(
        matches!(
            err,
            MutateError::Precondition(zanshin_jj::PreconditionError::Config { .. })
        ),
        "{err:?}"
    );
    assert!(repo.take_precondition().is_none(), "no pre-verb snapshot");
    assert_eq!(op_heads(&fx.path), heads, "nothing integrated");
}
