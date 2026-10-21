// SPDX-License-Identifier: MIT

//! Story 9.15 — `Repo::squash`, `Repo::squash_plan` and `Repo::split`, one witness per row of
//! the I/O matrix, read back through jj-lib.
//!
//! Every repo is built in-test with Zanshin's own verbs on a non-colocated internal-git repo:
//! `A (a.txt) → B (b.txt) → C (c.txt, c2.txt) = @`, descriptions `A\n`, `B\n`, `C\n`. The CLI
//! comparison of the same rows lives in the parity oracle (`crates/zanshin-parity`).

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::commit::Commit;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::{RefName, WorkspaceName};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{Backend, ChangeId, MutateError, Repo, SplitOptions, SquashOptions, WarningKind};

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

/// The VISIBLE commit of `id`, or `None` when it is gone (abandoned).
fn visible(root: &Path, id: &ChangeId) -> Option<Commit> {
    let (_workspace, repo) = load(root);
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0).expect("reverse hex");
    let targets = pollster::block_on(repo.resolve_change_id(&jj_id)).expect("index")?;
    let visible = targets.into_visible()?;
    let [commit_id] = visible.as_slice() else {
        panic!("divergent {id:?}");
    };
    Some(repo.store().get_commit(commit_id).expect("commit"))
}

fn commit(root: &Path, id: &ChangeId) -> Commit {
    visible(root, id).unwrap_or_else(|| panic!("{id:?} is not visible"))
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

/// `A (a.txt) → B (b.txt) → C (c.txt, c2.txt) = @`, with `repo_config` as the legacy repo config
/// (migrated by the start-up fix-up).
fn base_with(repo_config: &str) -> Fx {
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
    fs::write(root.join(".jj").join("repo").join("config.toml"), repo_config).expect("repo config");
    let mut repo = Repo::open(&root).expect("open");
    let step = |repo: &mut Repo, files: &[(&str, &str)], description: &str| -> ChangeId {
        for (path, text) in files {
            fs::write(root.join(path), text).expect("write");
        }
        let at = change_id(&wc(&root));
        repo.describe(at.clone(), description).expect("describe");
        at
    };
    let a = step(&mut repo, &[("a.txt", "a\n")], "A\n");
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    let b = step(&mut repo, &[("b.txt", "b\n")], "B\n");
    repo.new_change(std::slice::from_ref(&b), &[], &[]).expect("new");
    let c = step(&mut repo, &[("c.txt", "c\n"), ("c2.txt", "c2\n")], "C\n");
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

fn base() -> Fx {
    base_with("")
}

fn assert_refused_without_an_operation(
    fx: &mut Fx,
    run: impl FnOnce(&mut Repo) -> Result<(), MutateError>,
) -> MutateError {
    let before = head_op(&fx.root);
    let err = run(&mut fx.repo).expect_err("refused");
    assert_eq!(head_op(&fx.root), before, "a refusal writes no operation");
    err
}

// ── squash ───────────────────────────────────────────────────────────────────────

#[test]
fn squash_at_into_its_parent_combines_both_descriptions_and_replaces_at() {
    let mut fx = base();
    let b_hex = commit(&fx.root, &fx.b).id().hex();

    let result = fx.repo.squash(&SquashOptions::default()).expect("squash");

    assert!(visible(&fx.root, &fx.c).is_none(), "the emptied source is abandoned");
    let b = commit(&fx.root, &fx.b);
    assert_eq!(b.description(), "B\n\nC\n", "the editor buffer, saved unchanged");
    assert_eq!(files(&b), ["a.txt", "b.txt", "c.txt", "c2.txt"]);
    let at = wc(&fx.root);
    assert_eq!(
        parents(&fx.root, &at),
        std::slice::from_ref(&fx.b),
        "a new, empty @ on the destination"
    );
    assert_eq!(at.description(), "");
    assert_eq!(result.new_change_ids, [change_id(&at)]);
    assert_eq!(result.abandoned_change_ids, std::slice::from_ref(&fx.c));
    assert_eq!(result.working_copy_change_id, change_id(&at));
    let (op_id, description) = head_op(&fx.root);
    assert_eq!(description, format!("squash commits into {b_hex}"));
    assert_eq!(result.new_op_id.0, op_id);
}

#[test]
fn squash_plan_names_the_text_squash_writes_and_writes_no_operation() {
    let mut fx = base();
    let before = head_op(&fx.root);

    let plan = fx.repo.squash_plan(&SquashOptions::default()).expect("plan");

    assert_eq!(plan.combined_description.as_deref(), Some("B\n\nC\n"));
    assert_eq!(head_op(&fx.root), before, "a clean working copy: not even a snapshot");
    assert!(visible(&fx.root, &fx.c).is_some(), "nothing was squashed");

    // The plan text passed back as `-m` writes exactly what the verb writes without one.
    let message = plan.combined_description.expect("combined");
    let options = SquashOptions {
        message: Some(vec![message.clone()]),
        ..SquashOptions::default()
    };
    fx.repo.squash(&options).expect("squash");
    assert_eq!(commit(&fx.root, &fx.b).description(), message);
}

#[test]
fn squash_plan_after_a_snapshot_writes_only_the_snapshot() {
    let mut fx = base();
    fs::write(fx.root.join("c.txt"), "c edited\n").expect("edit");

    let plan = fx.repo.squash_plan(&SquashOptions::default()).expect("plan");

    assert!(plan.combined_description.is_some());
    assert_eq!(head_op(&fx.root).1, "snapshot working copy");
}

#[test]
fn squash_plan_is_null_where_the_cli_opens_no_editor() {
    let mut fx = base();
    let with_message = SquashOptions {
        message: Some(vec!["m".to_owned()]),
        ..SquashOptions::default()
    };
    assert_eq!(
        fx.repo.squash_plan(&with_message).expect("plan").combined_description,
        None
    );
    let use_destination = SquashOptions {
        use_destination_message: true,
        ..SquashOptions::default()
    };
    assert_eq!(
        fx.repo
            .squash_plan(&use_destination)
            .expect("plan")
            .combined_description,
        None
    );
    // A partial squash keeps the source, so only the destination's description counts.
    let partial = SquashOptions {
        paths: vec!["c.txt".to_owned()],
        ..SquashOptions::default()
    };
    assert_eq!(fx.repo.squash_plan(&partial).expect("plan").combined_description, None);
    // `--into @` squashes nothing.
    let into_itself = SquashOptions {
        into: Some(fx.c.clone()),
        ..SquashOptions::default()
    };
    assert_eq!(
        fx.repo.squash_plan(&into_itself).expect("plan").combined_description,
        None
    );
    // One non-empty description: no question either.
    let c = fx.c.clone();
    fx.repo.describe(c, "").expect("describe");
    assert_eq!(
        fx.repo
            .squash_plan(&SquashOptions::default())
            .expect("plan")
            .combined_description,
        None
    );
    fx.repo.squash(&SquashOptions::default()).expect("squash");
    assert_eq!(commit(&fx.root, &fx.b).description(), "B\n");
}

#[test]
fn squash_revision_moves_into_its_parent() {
    let mut fx = base();
    let options = SquashOptions {
        revision: Some(fx.b.clone()),
        ..SquashOptions::default()
    };

    fx.repo.squash(&options).expect("squash");

    assert!(visible(&fx.root, &fx.b).is_none());
    let a = commit(&fx.root, &fx.a);
    assert_eq!(a.description(), "A\n\nB\n");
    assert_eq!(files(&a), ["a.txt", "b.txt"]);
    assert_eq!(
        parents(&fx.root, &commit(&fx.root, &fx.c)),
        std::slice::from_ref(&fx.a),
        "C rebased onto A"
    );
}

#[test]
fn squash_of_a_merge_or_the_root_commit_refuses() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    let merge = fx.repo.new_change(&[a, b], &[], &[]).expect("merge").new_change_ids[0].clone();
    for revision in [merge, ChangeId("z".repeat(32))] {
        let options = SquashOptions {
            revision: Some(revision),
            ..SquashOptions::default()
        };
        let err = assert_refused_without_an_operation(&mut fx, |repo| repo.squash(&options).map(drop));
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "Cannot squash merge commits without a specified destination"),
            "{err:?}"
        );
        // Story 9.56: `squash`'s hint (`squash.rs:243-244` @ v0.46.0).
        assert_eq!(err.hints(), ["Use `--into` to specify which parent to squash into"]);
        let err = assert_refused_without_an_operation(&mut fx, |repo| repo.squash_plan(&options).map(drop));
        assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    }
}

#[test]
fn squash_from_into_moves_changes_and_rebases_the_rest() {
    let mut fx = base();
    let a_hex = commit(&fx.root, &fx.a).id().hex();
    let options = SquashOptions {
        from: vec![fx.c.clone()],
        into: Some(fx.a.clone()),
        ..SquashOptions::default()
    };

    let result = fx.repo.squash(&options).expect("squash");

    let a = commit(&fx.root, &fx.a);
    assert_eq!(files(&a), ["a.txt", "c.txt", "c2.txt"]);
    assert_eq!(a.description(), "A\n\nC\n");
    assert_eq!(files(&commit(&fx.root, &fx.b)), ["a.txt", "b.txt", "c.txt", "c2.txt"]);
    assert_eq!(result.abandoned_change_ids, std::slice::from_ref(&fx.c));
    assert_eq!(head_op(&fx.root).1, format!("squash commits into {a_hex}"));
    // The abandoned `@`'s replacement sits on `@`'s own (rewritten) parent, not on the
    // destination.
    let at = wc(&fx.root);
    assert_eq!(parents(&fx.root, &at), vec![fx.b.clone()]);
    assert_eq!(result.new_change_ids, vec![change_id(&at)]);
}

/// Squashing into a DESCENDANT: jj-lib rebases the destination onto the rewritten source first,
/// so the moved changes are not lost.
#[test]
fn squash_into_a_descendant_keeps_the_moved_changes() {
    let mut fx = base();
    let options = SquashOptions {
        from: vec![fx.b.clone()],
        into: Some(fx.c.clone()),
        ..SquashOptions::default()
    };

    let result = fx.repo.squash(&options).expect("squash");

    assert!(visible(&fx.root, &fx.b).is_none());
    let c = commit(&fx.root, &fx.c);
    assert_eq!(files(&c), ["a.txt", "b.txt", "c.txt", "c2.txt"]);
    assert_eq!(
        c.description(),
        "C

B
"
    );
    assert_eq!(parents(&fx.root, &c), vec![fx.a.clone()]);
    assert_eq!(result.abandoned_change_ids, vec![fx.b.clone()]);
    assert!(result.new_change_ids.is_empty(), "@ was the destination, not abandoned");
}

/// `from` given oldest-first still squashes in the CLI's order (revset order, reversed).
#[test]
fn squash_from_in_any_order_combines_oldest_first() {
    let mut fx = base();
    let options = SquashOptions {
        from: vec![fx.b.clone(), fx.c.clone()],
        into: Some(fx.a.clone()),
        ..SquashOptions::default()
    };

    let plan = fx.repo.squash_plan(&options).expect("plan");
    fx.repo.squash(&options).expect("squash");

    assert_eq!(plan.combined_description.as_deref(), Some("A\n\nB\n\nC\n"));
    assert_eq!(commit(&fx.root, &fx.a).description(), "A\n\nB\n\nC\n");
}

#[test]
fn squash_from_several_sources_combines_them_oldest_first() {
    let mut fx = base();
    let options = SquashOptions {
        from: vec![fx.c.clone(), fx.b.clone()],
        into: Some(fx.a.clone()),
        ..SquashOptions::default()
    };

    let plan = fx.repo.squash_plan(&options).expect("plan");
    fx.repo.squash(&options).expect("squash");

    assert_eq!(plan.combined_description.as_deref(), Some("A\n\nB\n\nC\n"));
    assert_eq!(commit(&fx.root, &fx.a).description(), "A\n\nB\n\nC\n");
}

#[test]
fn squash_into_itself_changes_nothing_and_writes_no_operation() {
    let mut fx = base();
    let (head, _) = head_op(&fx.root);
    let options = SquashOptions {
        into: Some(fx.c.clone()),
        ..SquashOptions::default()
    };

    let result = fx.repo.squash(&options).expect("a no-op, not a refusal");

    assert_eq!(result.new_op_id.0, head);
    assert_eq!(head_op(&fx.root).0, head);
    assert!(result.abandoned_change_ids.is_empty());
}

#[test]
fn squash_of_a_path_keeps_the_source_and_the_destination_description() {
    let mut fx = base();
    let options = SquashOptions {
        paths: vec!["c.txt".to_owned()],
        ..SquashOptions::default()
    };

    let result = fx.repo.squash(&options).expect("squash");

    let b = commit(&fx.root, &fx.b);
    assert_eq!(files(&b), ["a.txt", "b.txt", "c.txt"]);
    assert_eq!(b.description(), "B\n");
    let c = commit(&fx.root, &fx.c);
    assert_eq!(
        files(&c),
        ["a.txt", "b.txt", "c.txt", "c2.txt"],
        "c.txt now comes from B"
    );
    assert_eq!(c.description(), "C\n");
    assert_eq!(change_id(&wc(&fx.root)), fx.c);
    assert!(result.abandoned_change_ids.is_empty() && result.new_change_ids.is_empty());
    assert!(fx.repo.take_warnings().is_empty());
}

#[test]
fn squash_of_an_unmatched_path_warns_and_squashes_nothing() {
    let mut fx = base();
    let (head, _) = head_op(&fx.root);
    let options = SquashOptions {
        paths: vec!["nope.txt".to_owned()],
        ..SquashOptions::default()
    };

    let result = fx.repo.squash(&options).expect("squash");

    assert_eq!(result.new_op_id.0, head, "nothing selected: no operation");
    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0].kind, WarningKind::PathsUnmatched);
    assert_eq!(warnings[0].message, "No matching entries for paths: nope.txt");
}

#[test]
fn squash_flags_message_destination_message_and_keep_emptied() {
    let mut fx = base();
    let message = SquashOptions {
        revision: Some(fx.b.clone()),
        message: Some(vec!["T".to_owned(), "U".to_owned()]),
        ..SquashOptions::default()
    };
    fx.repo.squash(&message).expect("-m");
    assert_eq!(commit(&fx.root, &fx.a).description(), "T\n\nU\n");

    let use_destination = SquashOptions {
        use_destination_message: true,
        keep_emptied: true,
        ..SquashOptions::default()
    };
    let result = fx.repo.squash(&use_destination).expect("-u -k");
    assert_eq!(commit(&fx.root, &fx.a).description(), "T\n\nU\n");
    let c = commit(&fx.root, &fx.c);
    assert_eq!(c.description(), "C\n", "-k keeps the emptied source");
    assert_eq!(
        c.tree().tree_ids(),
        commit(&fx.root, &fx.a).tree().tree_ids(),
        "and empties it"
    );
    assert_eq!(change_id(&wc(&fx.root)), fx.c);
    assert!(result.abandoned_change_ids.is_empty());
}

#[test]
fn squash_refuses_conflicting_flags_before_anything_else() {
    let mut fx = base();
    let both = SquashOptions {
        message: Some(vec!["m".to_owned()]),
        use_destination_message: true,
        ..SquashOptions::default()
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.squash(&both).map(drop));
    assert!(matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("--use-destination-message")));
    let revision_and_into = SquashOptions {
        revision: Some(fx.c.clone()),
        into: Some(fx.a.clone()),
        ..SquashOptions::default()
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.squash(&revision_and_into).map(drop));
    assert!(matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("--revision")));
    let bad_path = SquashOptions {
        paths: vec!["/abs".to_owned()],
        ..SquashOptions::default()
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.squash(&bad_path).map(drop));
    assert!(matches!(err, MutateError::InvalidInput { .. }));
    let unknown = SquashOptions {
        from: vec![ChangeId("k".repeat(32))],
        ..SquashOptions::default()
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.squash(&unknown).map(drop));
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");
}

#[test]
fn squash_into_an_immutable_destination_refuses() {
    let mut fx = base();
    let b_hex = commit(&fx.root, &fx.b).id().hex();
    test_helpers::set_tag(&fx.root, "v1", &[&b_hex]);

    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.squash(&SquashOptions::default()).map(drop));

    assert!(
        matches!(&err, MutateError::Immutable { commit_id, .. } if *commit_id == b_hex),
        "{err:?}"
    );
}

// ── split ────────────────────────────────────────────────────────────────────────

fn split_c(paths: &[&str], message: Option<&str>) -> SplitOptions {
    SplitOptions {
        paths: paths.iter().map(|p| (*p).to_owned()).collect(),
        message: message.map(|m| vec![m.to_owned()]),
        ..SplitOptions::default()
    }
}

#[test]
fn split_by_path_keeps_the_selected_part_in_place_and_moves_at_and_bookmarks_on() {
    let mut fx = base();
    let c = fx.c.clone();
    fx.repo
        .bookmark_create(&["c-mark".to_owned()], Some(&c))
        .expect("bookmark");
    let c_hex = commit(&fx.root, &fx.c).id().hex();

    let result = fx.repo.split(&split_c(&["c.txt"], Some("first"))).expect("split");

    assert_eq!(result.selected_change_id, fx.c, "the selected part keeps the change id");
    let selected = commit(&fx.root, &fx.c);
    assert_eq!(selected.description(), "first\n");
    assert_eq!(files(&selected), ["a.txt", "b.txt", "c.txt"]);
    assert_eq!(parents(&fx.root, &selected), std::slice::from_ref(&fx.b));
    let remaining = commit(&fx.root, &result.remaining_change_id);
    assert_eq!(remaining.description(), "C\n");
    assert_eq!(files(&remaining), ["a.txt", "b.txt", "c.txt", "c2.txt"]);
    assert_eq!(parents(&fx.root, &remaining), std::slice::from_ref(&fx.c));
    assert_eq!(change_id(&wc(&fx.root)), result.remaining_change_id);
    assert_eq!(bookmark(&fx.root, "c-mark"), Some(result.remaining_change_id.clone()));
    assert_eq!(
        result.mutation.new_change_ids,
        std::slice::from_ref(&result.remaining_change_id)
    );
    assert_eq!(head_op(&fx.root).1, format!("split commit {c_hex}"));
    assert!(fx.repo.take_warnings().is_empty());
}

#[test]
fn split_without_a_message_keeps_the_description_on_both() {
    let mut fx = base();

    let result = fx.repo.split(&split_c(&["c.txt"], None)).expect("split");

    assert_eq!(commit(&fx.root, &result.selected_change_id).description(), "C\n");
    assert_eq!(commit(&fx.root, &result.remaining_change_id).description(), "C\n");
}

/// Without `-m` both parts keep the description as a saved editor buffer holds it: a missing
/// final newline is added, `JJ:` lines are dropped.
#[test]
fn split_without_a_message_cleans_the_description_like_a_saved_buffer() {
    for description in ["C", "C\nJJ: x\n"] {
        let mut fx = base();
        let c = fx.c.clone();
        fx.repo.describe(c, description).expect("describe");

        let result = fx.repo.split(&split_c(&["c.txt"], None)).expect("split");

        assert_eq!(commit(&fx.root, &result.selected_change_id).description(), "C\n");
        assert_eq!(commit(&fx.root, &result.remaining_change_id).description(), "C\n");
    }
}

/// An EMPTY target is both fully and not at all selected; only the full-selection warning fires.
#[test]
fn split_of_an_empty_commit_warns_only_that_everything_is_selected() {
    let mut fx = base();
    let c = fx.c.clone();
    fx.repo.new_change(&[c], &[], &[]).expect("new");
    let _ = fx.repo.take_warnings();

    fx.repo.split(&split_c(&["c.txt"], None)).expect("split");

    let kinds: Vec<WarningKind> = fx.repo.take_warnings().iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::SplitAllSelected]);
}

#[test]
fn split_with_legacy_bookmark_behavior_off_leaves_bookmarks_on_the_selected_part() {
    let mut fx = base_with("[split]\nlegacy-bookmark-behavior = false\n");
    let c = fx.c.clone();
    fx.repo
        .bookmark_create(&["c-mark".to_owned()], Some(&c))
        .expect("bookmark");

    let result = fx.repo.split(&split_c(&["c.txt"], None)).expect("split");

    assert_eq!(bookmark(&fx.root, "c-mark"), Some(result.selected_change_id.clone()));
    assert_eq!(change_id(&wc(&fx.root)), result.remaining_change_id);
}

#[test]
fn split_rebases_descendants_onto_the_remaining_part() {
    for legacy in ["", "[split]\nlegacy-bookmark-behavior = false\n"] {
        let mut fx = base_with(legacy);
        let c = fx.c.clone();
        let d = fx.repo.new_change(&[c], &[], &[]).expect("new").new_change_ids[0].clone();
        let options = SplitOptions {
            revision: Some(fx.c.clone()),
            ..split_c(&["c.txt"], None)
        };

        let result = fx.repo.split(&options).expect("split");

        assert_eq!(
            parents(&fx.root, &commit(&fx.root, &d)),
            std::slice::from_ref(&result.remaining_change_id)
        );
        assert_eq!(change_id(&wc(&fx.root)), d, "@ was not the target: it stays");
    }
}

#[test]
fn split_parallel_puts_both_parts_on_the_parents_and_merges_the_children() {
    for legacy in ["", "[split]\nlegacy-bookmark-behavior = false\n"] {
        let mut fx = base_with(legacy);
        let c = fx.c.clone();
        let d = fx.repo.new_change(&[c], &[], &[]).expect("new").new_change_ids[0].clone();
        let options = SplitOptions {
            revision: Some(fx.c.clone()),
            parallel: true,
            ..split_c(&["c.txt"], Some("first"))
        };

        let result = fx.repo.split(&options).expect("split");

        let selected = commit(&fx.root, &result.selected_change_id);
        let remaining = commit(&fx.root, &result.remaining_change_id);
        assert_eq!(parents(&fx.root, &selected), std::slice::from_ref(&fx.b));
        assert_eq!(parents(&fx.root, &remaining), std::slice::from_ref(&fx.b));
        assert_eq!(files(&selected), ["a.txt", "b.txt", "c.txt"]);
        assert_eq!(files(&remaining), ["a.txt", "b.txt", "c2.txt"]);
        assert_eq!(
            parents(&fx.root, &commit(&fx.root, &d)),
            [result.selected_change_id.clone(), result.remaining_change_id.clone()]
        );
    }
}

#[test]
fn split_insert_before_extracts_the_selection_into_a_new_change_there() {
    let mut fx = base();
    let c = fx.c.clone();
    fx.repo
        .bookmark_create(&["c-mark".to_owned()], Some(&c))
        .expect("bookmark");
    let options = SplitOptions {
        insert_before: Some(vec![fx.b.clone()]),
        ..split_c(&["c.txt"], Some("first"))
    };

    let result = fx.repo.split(&options).expect("split");

    assert_eq!(
        result.remaining_change_id, fx.c,
        "the remaining part keeps the change id"
    );
    assert_eq!(
        result.mutation.new_change_ids,
        std::slice::from_ref(&result.selected_change_id)
    );
    let selected = commit(&fx.root, &result.selected_change_id);
    assert_eq!(selected.description(), "first\n");
    assert_eq!(files(&selected), ["a.txt", "c.txt"]);
    assert_eq!(parents(&fx.root, &selected), std::slice::from_ref(&fx.a));
    assert_eq!(
        parents(&fx.root, &commit(&fx.root, &fx.b)),
        std::slice::from_ref(&result.selected_change_id)
    );
    let remaining = commit(&fx.root, &fx.c);
    assert_eq!(remaining.description(), "C\n");
    assert_eq!(files(&remaining), ["a.txt", "b.txt", "c.txt", "c2.txt"]);
    assert_eq!(change_id(&wc(&fx.root)), fx.c);
    assert_eq!(bookmark(&fx.root, "c-mark"), Some(fx.c.clone()));
}

/// With a location, the target's descendants are rebased onto the remaining commit FIRST
/// (`move_first_commit`), and the location is mapped through those rewrites.
#[test]
fn split_insert_before_rebases_the_targets_descendants_first() {
    let mut fx = base();
    let c = fx.c.clone();
    let d = fx.repo.new_change(&[c], &[], &[]).expect("new").new_change_ids[0].clone();
    let options = SplitOptions {
        revision: Some(fx.c.clone()),
        insert_before: Some(vec![fx.b.clone()]),
        ..split_c(&["c.txt"], None)
    };

    let result = fx.repo.split(&options).expect("split");

    assert_eq!(result.remaining_change_id, fx.c);
    assert_eq!(parents(&fx.root, &commit(&fx.root, &d)), vec![fx.c.clone()]);
    assert_eq!(
        parents(&fx.root, &commit(&fx.root, &fx.b)),
        vec![result.selected_change_id.clone()]
    );
    assert_eq!(change_id(&wc(&fx.root)), d, "@ was not the target: it stays");
}

#[test]
fn split_insert_after_and_onto_place_the_new_change() {
    let mut fx = base();
    let after = SplitOptions {
        insert_after: Some(vec![fx.a.clone()]),
        ..split_c(&["c.txt"], None)
    };
    let result = fx.repo.split(&after).expect("-A");
    assert_eq!(
        parents(&fx.root, &commit(&fx.root, &result.selected_change_id)),
        std::slice::from_ref(&fx.a)
    );
    assert_eq!(
        parents(&fx.root, &commit(&fx.root, &fx.b)),
        std::slice::from_ref(&result.selected_change_id)
    );

    let mut fx = base();
    let onto = SplitOptions {
        onto: Some(vec![fx.a.clone()]),
        ..split_c(&["c.txt"], None)
    };
    let result = fx.repo.split(&onto).expect("-o");
    let selected = commit(&fx.root, &result.selected_change_id);
    assert_eq!(parents(&fx.root, &selected), std::slice::from_ref(&fx.a));
    assert_eq!(files(&selected), ["a.txt", "c.txt"]);
    assert_eq!(
        parents(&fx.root, &commit(&fx.root, &fx.b)),
        std::slice::from_ref(&fx.a),
        "-o inserts no child"
    );
}

#[test]
fn split_location_refusals_come_from_compute_commit_location() {
    let mut fx = base();
    let root = ChangeId("z".repeat(32));
    let before_root = SplitOptions {
        insert_before: Some(vec![root]),
        ..split_c(&["c.txt"], None)
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.split(&before_root).map(drop));
    assert!(matches!(err, MutateError::Immutable { .. }), "{err:?}");

    let loop_ = SplitOptions {
        insert_after: Some(vec![fx.b.clone()]),
        insert_before: Some(vec![fx.a.clone()]),
        ..split_c(&["c.txt"], None)
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.split(&loop_).map(drop));
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("split-out commit")),
        "{err:?}"
    );

    let no_parent = SplitOptions {
        onto: Some(Vec::new()),
        ..split_c(&["c.txt"], None)
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.split(&no_parent).map(drop));
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "No revisions found to use as parent")
    );
}

#[test]
fn split_moves_every_workspace_whose_at_was_the_target() {
    let mut fx = base();
    let (second_fx, _) = test_helpers::add_workspace(&fx.root, "second");
    let mut second = Repo::open(&second_fx.path).expect("open second");
    second.edit(fx.c.clone()).expect("edit");
    let _ = fx.repo.take_warnings();

    let result = fx.repo.split(&split_c(&["c.txt"], None)).expect("split");

    assert_eq!(change_id(&wc(&fx.root)), result.remaining_change_id);
    assert_eq!(change_id(&wc_of(&fx.root, "second")), result.remaining_change_id);
}

#[test]
fn split_warns_when_everything_or_nothing_is_selected_and_still_splits() {
    let mut fx = base();
    let result = fx.repo.split(&split_c(&["c.txt", "c2.txt"], None)).expect("split");
    let kinds: Vec<WarningKind> = fx.repo.take_warnings().iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::SplitAllSelected]);
    assert_eq!(
        commit(&fx.root, &result.remaining_change_id).tree().tree_ids(),
        commit(&fx.root, &result.selected_change_id).tree().tree_ids(),
        "the remaining part is empty"
    );

    let mut fx = base();
    let result = fx.repo.split(&split_c(&["nope.txt"], None)).expect("split");
    let warnings = fx.repo.take_warnings();
    let kinds: Vec<WarningKind> = warnings.iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::PathsUnmatched, WarningKind::SplitNoneSelected]);
    assert_eq!(
        warnings[1].message,
        "No changes have been selected, so the new revision will be empty."
    );
    assert_eq!(files(&commit(&fx.root, &result.selected_change_id)), ["a.txt", "b.txt"]);
}

#[test]
fn split_refusals_write_nothing() {
    let mut fx = base();
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.split(&split_c(&[], None)).map(drop));
    assert!(matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("at least one path")));

    let parallel_and_location = SplitOptions {
        parallel: true,
        insert_before: Some(vec![fx.b.clone()]),
        ..split_c(&["c.txt"], None)
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.split(&parallel_and_location).map(drop));
    assert!(matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("--parallel")));

    let onto_and_after = SplitOptions {
        onto: Some(vec![fx.a.clone()]),
        insert_after: Some(vec![fx.a.clone()]),
        ..split_c(&["c.txt"], None)
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.split(&onto_and_after).map(drop));
    assert!(matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("--onto")));

    let b_hex = commit(&fx.root, &fx.b).id().hex();
    test_helpers::set_tag(&fx.root, "v1", &[&b_hex]);
    let immutable = SplitOptions {
        revision: Some(fx.b.clone()),
        ..split_c(&["b.txt"], None)
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.split(&immutable).map(drop));
    assert!(matches!(err, MutateError::Immutable { .. }), "{err:?}");

    let unknown = SplitOptions {
        revision: Some(ChangeId("k".repeat(32))),
        ..split_c(&["c.txt"], None)
    };
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.split(&unknown).map(drop));
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");
}

#[test]
fn split_refuses_a_wrong_typed_legacy_bookmark_behavior() {
    let mut fx = base_with("[split]\nlegacy-bookmark-behavior = \"yes\"\n");
    let err = assert_refused_without_an_operation(&mut fx, |repo| repo.split(&split_c(&["c.txt"], None)).map(drop));
    assert!(matches!(&err, MutateError::Config { reason } if reason.contains("split.legacy-bookmark-behavior")));
}
