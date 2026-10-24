// SPDX-License-Identifier: MIT

//! Story 9.50 — `Repo::select_tree` and the tree arms of `commit`, `split` and `squash`, one
//! witness per row of the I/O matrix, read back through jj-lib.
//!
//! Every repo is built in-test with Zanshin's own verbs on a non-colocated internal-git repo:
//! `A` holds the left side of every kind of change, `@` (on `A`) the right side —
//! `f.txt` with three changed sections, a binary change, a mode change, an added and a deleted
//! file, and an unchanged file. The CLI comparison (the stock CLI's `--tool` making the same
//! choice) lives in the parity oracle (`crates/zanshin-parity`).

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures::AsyncReadExt as _;
use jj_lib::backend::TreeId;
use jj_lib::backend::TreeValue;
use jj_lib::backend::{MergedTreeValue, MergedTreeValueExt as _};
use jj_lib::commit::Commit;
use jj_lib::conflict_labels::ConflictLabels;
use jj_lib::diff::{ContentDiff, DiffHunkKind};
use jj_lib::merge::Merge;
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{
    Backend, ChangeId, CommitOptions, FileChoice, FileSelection, HunkKey, MutateError, Repo, SelectTreeOptions,
    SelectedTreeId, SourceTree, SplitOptions, SquashOptions, TreeSelection, WarningKind,
};

const F_LEFT: &str = "a\nb\nc\nd\ne\n";
const F_RIGHT: &str = "A\nb\nC\nd\nE\n";
const F_ONE_AND_THREE: &str = "A\nb\nc\nd\nE\n";

/// The three sections of `f.txt`.
const S1: HunkKey = key(0, 1, 0, 1);
const S2: HunkKey = key(2, 1, 2, 1);
const S3: HunkKey = key(4, 1, 4, 1);

const fn key(old_start: u32, old_count: u32, new_start: u32, new_count: u32) -> HunkKey {
    HunkKey {
        old_start,
        old_count,
        new_start,
        new_count,
    }
}

struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    repo: Repo,
    a: ChangeId,
    at: ChangeId,
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

fn head_op(root: &Path) -> String {
    let (_workspace, repo) = load(root);
    repo.op_id().hex()
}

fn ids(tree: &MergedTree) -> SelectedTreeId {
    SelectedTreeId {
        tree_ids: tree.tree_ids().iter().map(jj_lib::object_id::ObjectId::hex).collect(),
        labels: tree.labels().as_slice().to_vec(),
    }
}

/// The tree a [`SelectedTreeId`] names.
fn tree_of(root: &Path, selected: &SelectedTreeId) -> MergedTree {
    let (_workspace, repo) = load(root);
    let tree_ids: Vec<TreeId> = selected
        .tree_ids
        .iter()
        .map(|hex| TreeId::try_from_hex(hex).expect("hex"))
        .collect();
    MergedTree::new(
        repo.store().clone(),
        Merge::from_vec(tree_ids),
        ConflictLabels::from_vec(selected.labels.clone()),
    )
}

/// `path`'s content and executable bit in `tree`; `None` when absent.
fn file(tree: &MergedTree, path: &str) -> Option<(String, bool)> {
    let path = RepoPathBuf::from_internal_string(path).expect("path");
    let value = pollster::block_on(tree.path_value(&path)).expect("path value");
    let TreeValue::File { id, executable, .. } = value.into_resolved().expect("resolved")? else {
        panic!("not a file");
    };
    let mut content = Vec::new();
    pollster::block_on(async {
        tree.store()
            .read_file(&path, &id)
            .await
            .expect("read")
            .read_to_end(&mut content)
            .await
            .expect("read to end")
    });
    Some((String::from_utf8_lossy(&content).into_owned(), executable))
}

fn text(tree: &MergedTree, path: &str) -> Option<String> {
    file(tree, path).map(|(content, _)| content)
}

fn write(root: &Path, path: &str, content: &[u8]) {
    fs::write(root.join(path), content).expect("write");
}

fn set_executable(root: &Path, path: &str, executable: bool) {
    let mode = if executable { 0o755 } else { 0o644 };
    fs::set_permissions(root.join(path), fs::Permissions::from_mode(mode)).expect("chmod");
}

/// `A` = the left side of every change, `@` on `A` = the right side.
fn base() -> Fx {
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
    write(&root, "f.txt", F_LEFT.as_bytes());
    write(&root, "bin.dat", b"x\0y");
    write(&root, "mode.sh", b"m\n");
    set_executable(&root, "mode.sh", false);
    write(&root, "gone.txt", b"g\n");
    write(&root, "same.txt", b"s\n");
    let a = change_id(&wc(&root));
    repo.describe(a.clone(), "A\n").expect("describe A");
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    write(&root, "f.txt", F_RIGHT.as_bytes());
    write(&root, "bin.dat", b"x\0z");
    set_executable(&root, "mode.sh", true);
    fs::remove_file(root.join("gone.txt")).expect("rm");
    write(&root, "new.txt", b"n\n");
    let at = change_id(&wc(&root));
    repo.describe(at.clone(), "B\n").expect("describe @");
    let _ = repo.take_warnings();
    Fx {
        _tmp: tmp,
        root,
        repo,
        a,
        at,
    }
}

/// `revision`'s `left` as `show` reports it.
fn left_of(repo: &mut Repo, revision: &ChangeId) -> Vec<String> {
    let entries = repo.show(Some(&revision.0), None).expect("show");
    entries[0].parent_tree_ids.clone()
}

fn hunks(path: &str, keys: &[HunkKey]) -> FileSelection {
    FileSelection {
        path: path.to_owned(),
        choice: FileChoice::Hunks(keys.to_vec()),
    }
}

fn mode_and_hunks(path: &str, keys: &[HunkKey]) -> FileSelection {
    FileSelection {
        path: path.to_owned(),
        choice: FileChoice::ModeAndHunks(keys.to_vec()),
    }
}

fn whole(path: &str) -> FileSelection {
    FileSelection {
        path: path.to_owned(),
        choice: FileChoice::Whole,
    }
}

fn select(fx: &mut Fx, files: Vec<FileSelection>) -> Result<SelectedTreeId, MutateError> {
    let left = left_of(&mut fx.repo, &fx.at.clone());
    fx.repo.select_tree(&SelectTreeOptions {
        revision: None,
        left,
        files,
    })
}

fn is_stale(err: &MutateError) -> bool {
    matches!(err, MutateError::StaleSelection { .. })
}

fn is_invalid(err: &MutateError) -> bool {
    matches!(err, MutateError::InvalidInput { .. })
}

// ── select_tree ──────────────────────────────────────────────────────────────────

/// Sections 1 and 3 of `f.txt`: the file is the right side in them, the left side in section 2;
/// every other changed file stays at the left side. Nothing enters the op log.
#[test]
fn sections_one_and_three_keep_section_two_and_every_other_file_on_the_left() {
    let mut fx = base();
    let left_before = left_of(&mut fx.repo, &fx.at.clone());
    let head = head_op(&fx.root);
    let selected = select(&mut fx, vec![hunks("f.txt", &[S1, S3])]).expect("select");
    assert_eq!(head_op(&fx.root), head, "select_tree writes no operation");

    let tree = tree_of(&fx.root, &selected);
    assert_eq!(text(&tree, "f.txt").as_deref(), Some(F_ONE_AND_THREE));
    assert_eq!(text(&tree, "bin.dat").as_deref(), Some("x\0y"));
    assert_eq!(file(&tree, "mode.sh"), Some(("m\n".to_owned(), false)));
    assert_eq!(text(&tree, "gone.txt").as_deref(), Some("g\n"));
    assert_eq!(text(&tree, "new.txt"), None);
    assert_eq!(text(&tree, "same.txt").as_deref(), Some("s\n"));
    assert!(selected.labels.is_empty());
    assert_eq!(left_of(&mut fx.repo, &fx.at.clone()), left_before);

    let all = select(&mut fx, vec![hunks("f.txt", &[S1, S2, S3])]).expect("select all");
    assert_eq!(text(&tree_of(&fx.root, &all), "f.txt").as_deref(), Some(F_RIGHT));
}

/// Whole files give the same tree the paths arm's `from_paths` gives: `commit` with those paths.
#[test]
fn whole_files_give_the_tree_the_paths_arm_gives() {
    let mut fx = base();
    let selected = select(&mut fx, vec![whole("f.txt"), whole("new.txt")]).expect("select");
    fx.repo
        .commit(&CommitOptions {
            paths: vec!["f.txt".to_owned(), "new.txt".to_owned()],
            message: vec!["c".to_owned()],
            tree: None,
        })
        .expect("commit by paths");
    let committed = commit(&fx.root, &fx.at);
    assert_eq!(ids(&committed.tree()), selected);
}

/// Nothing selected is the left tree.
#[test]
fn nothing_selected_is_the_left_tree() {
    let mut fx = base();
    let left = left_of(&mut fx.repo, &fx.at.clone());
    let selected = select(&mut fx, Vec::new()).expect("select");
    assert_eq!(selected.tree_ids, left);
    let empty_hunks = select(&mut fx, vec![hunks("f.txt", &[])]).expect("select");
    assert_eq!(empty_hunks.tree_ids, left);
}

/// Keys on a whole-only change — binary, addition, deletion — or on an unchanged path are stale;
/// so is a key on a mode change whose texts are equal (it has no sections).
#[test]
fn keys_on_a_whole_only_or_unchanged_path_are_stale() {
    let mut fx = base();
    let err = select(&mut fx, vec![hunks("mode.sh", &[S1])]).expect_err("mode.sh");
    assert!(is_stale(&err), "{err:?}");
    assert!(err.to_string().contains("is not a current section of mode.sh"), "{err}");
    for path in ["bin.dat", "new.txt", "gone.txt"] {
        let err = select(&mut fx, vec![hunks(path, &[S1])]).expect_err(path);
        assert!(is_stale(&err), "{path}: {err:?}");
        assert!(
            err.to_string().contains(&format!("{path} can only be selected whole")),
            "{path}: {err}"
        );
    }
    let err = select(&mut fx, vec![hunks("same.txt", &[S1])]).expect_err("unchanged");
    assert!(is_stale(&err), "{err:?}");
    assert!(err.to_string().contains("same.txt has no changes"), "{err}");
}

/// The same changes selected whole are the right side's value.
#[test]
fn whole_only_changes_selected_whole_are_the_right_value() {
    let mut fx = base();
    let selected = select(
        &mut fx,
        vec![
            whole("bin.dat"),
            whole("mode.sh"),
            whole("new.txt"),
            whole("gone.txt"),
            whole("same.txt"),
        ],
    )
    .expect("select");
    let tree = tree_of(&fx.root, &selected);
    assert_eq!(text(&tree, "bin.dat").as_deref(), Some("x\0z"));
    assert_eq!(file(&tree, "mode.sh"), Some(("m\n".to_owned(), true)));
    assert_eq!(text(&tree, "new.txt").as_deref(), Some("n\n"));
    assert_eq!(text(&tree, "gone.txt"), None);
    assert_eq!(text(&tree, "f.txt").as_deref(), Some(F_LEFT));
}

/// A key that is not a current section is stale.
#[test]
fn an_unknown_key_is_stale() {
    let mut fx = base();
    let err = select(&mut fx, vec![hunks("f.txt", &[S1, key(1, 1, 1, 1)])]).expect_err("unknown key");
    assert!(is_stale(&err), "{err:?}");
    assert!(err.to_string().contains("-1,1 +1,1"), "{err}");
}

/// A `left` the revision's parents no longer have is stale — for `select_tree` and for every
/// verb's tree arm — and nothing is written.
#[test]
fn a_rebased_left_is_stale_for_select_tree_and_every_tree_arm() {
    let mut fx = base();
    let old_left = left_of(&mut fx.repo, &fx.at.clone());
    let selected = select(&mut fx, vec![hunks("f.txt", &[S1, S3])]).expect("select");

    // Rebase @ onto a sibling of A with other content: @'s parent tree changes.
    fx.repo.new_change(&[fx.a.clone()], &[], &[]).expect("new sibling");
    write(&fx.root, "other.txt", b"o\n");
    let sibling = change_id(&wc(&fx.root));
    fx.repo.describe(sibling.clone(), "S\n").expect("describe sibling");
    fx.repo.edit(fx.at.clone()).expect("edit @ back");
    fx.repo
        .rebase(&zanshin_jj::RebaseOptions {
            revisions: vec![fx.at.clone()],
            onto: vec![sibling],
            ..Default::default()
        })
        .expect("rebase");
    assert_ne!(left_of(&mut fx.repo, &fx.at.clone()), old_left);

    let head = head_op(&fx.root);
    let err = fx
        .repo
        .select_tree(&SelectTreeOptions {
            revision: Some(fx.at.clone()),
            left: old_left.clone(),
            files: vec![hunks("f.txt", &[S1])],
        })
        .expect_err("stale left");
    assert!(is_stale(&err), "{err:?}");

    let stale = TreeSelection {
        tree: selected,
        left: old_left,
    };
    let err = fx
        .repo
        .commit(&CommitOptions {
            message: vec!["c".to_owned()],
            tree: Some(stale.clone()),
            ..Default::default()
        })
        .expect_err("commit");
    assert!(is_stale(&err), "{err:?}");
    let err = fx
        .repo
        .split(&SplitOptions {
            tree: Some(stale.clone()),
            message: Some(vec!["s".to_owned()]),
            ..Default::default()
        })
        .expect_err("split");
    assert!(is_stale(&err), "{err:?}");
    let err = fx
        .repo
        .squash(&SquashOptions {
            trees: vec![SourceTree {
                source: fx.at.clone(),
                tree: stale,
            }],
            message: Some(vec!["q".to_owned()]),
            ..Default::default()
        })
        .expect_err("squash");
    assert!(is_stale(&err), "{err:?}");
    assert_eq!(head_op(&fx.root), head, "a stale refusal writes no operation");
}

/// Malformed input refuses `jj.invalid_input` before the snapshot: with a dirty working copy no
/// precondition runs and no operation is written.
#[test]
fn malformed_input_refuses_before_the_snapshot() {
    let mut fx = base();
    let left = left_of(&mut fx.repo, &fx.at.clone());
    write(&fx.root, "dirty.txt", b"d\n");
    let head = head_op(&fx.root);
    let refuse = |repo: &mut Repo, left: Vec<String>, files: Vec<FileSelection>| {
        let err = repo
            .select_tree(&SelectTreeOptions {
                revision: None,
                left,
                files,
            })
            .expect_err("refused");
        assert!(repo.take_precondition().is_none(), "refused before the snapshot");
        err
    };
    for bad_left in [
        vec!["nothex".to_owned()],
        Vec::new(),
        vec![left[0].clone(), left[0].clone()],
    ] {
        let err = refuse(&mut fx.repo, bad_left.clone(), Vec::new());
        assert!(is_invalid(&err), "{bad_left:?}: {err:?}");
    }
    for files in [
        vec![whole("/abs")],
        vec![whole("dir/")],
        vec![whole("")],
        vec![whole("f.txt"), hunks("f.txt", &[S1])],
    ] {
        let err = refuse(&mut fx.repo, left.clone(), files.clone());
        assert!(is_invalid(&err), "{files:?}: {err:?}");
    }
    assert_eq!(head_op(&fx.root), head, "no operation, not even the snapshot's");
    let err = fx
        .repo
        .select_tree(&SelectTreeOptions {
            revision: Some(ChangeId("qpvuntsmwlqtpvuntsmwlqtpvuntsm".to_owned())),
            left,
            files: Vec::new(),
        })
        .expect_err("unknown revision");
    assert!(matches!(err, MutateError::ChangeNotFound { .. }), "{err:?}");
}

// ── the mode toggle and conflicted files (loop 9.9–9.12 second follow-on) ─────────

/// [`base`] with `f.txt` also made executable in `@`: a content AND a mode change.
fn base_with_executable_f() -> Fx {
    let fx = base();
    set_executable(&fx.root, "f.txt", true);
    fx
}

/// The builtin editor's mode toggle alone: the left text with the right mode — of a file whose
/// content changed too, and of one whose content did not.
#[test]
fn the_mode_toggle_alone_keeps_the_left_text_with_the_right_mode() {
    let mut fx = base_with_executable_f();
    let selected = select(
        &mut fx,
        vec![mode_and_hunks("f.txt", &[]), mode_and_hunks("mode.sh", &[])],
    )
    .expect("select");
    let tree = tree_of(&fx.root, &selected);
    assert_eq!(file(&tree, "f.txt"), Some((F_LEFT.to_owned(), true)));
    assert_eq!(file(&tree, "mode.sh"), Some(("m\n".to_owned(), true)));
    assert_eq!(text(&tree, "bin.dat").as_deref(), Some("x\0y"), "the rest stays left");
}

/// Sections without the toggle keep the left mode; with it they take the right one.
#[test]
fn sections_keep_the_left_mode_unless_the_toggle_is_selected_too() {
    let mut fx = base_with_executable_f();
    let without = select(&mut fx, vec![hunks("f.txt", &[S1, S3])]).expect("without the mode");
    assert_eq!(
        file(&tree_of(&fx.root, &without), "f.txt"),
        Some((F_ONE_AND_THREE.to_owned(), false))
    );
    let with = select(&mut fx, vec![mode_and_hunks("f.txt", &[S1, S3])]).expect("with the mode");
    assert_eq!(
        file(&tree_of(&fx.root, &with), "f.txt"),
        Some((F_ONE_AND_THREE.to_owned(), true))
    );
}

/// The toggle on a file whose mode did not change, an unchanged file, an added and a deleted one
/// is stale.
#[test]
fn the_mode_toggle_without_a_mode_change_is_stale() {
    let mut fx = base();
    for path in ["f.txt", "same.txt", "new.txt", "gone.txt"] {
        let err = select(&mut fx, vec![mode_and_hunks(path, &[])]).expect_err(path);
        assert!(is_stale(&err), "{path}: {err:?}");
        assert!(
            err.to_string().contains(&format!("{path} has no mode change")),
            "{path}: {err}"
        );
    }
}

/// A binary file's mode can be taken alone — its left content with the right mode — but keys on
/// it stay stale.
#[test]
fn a_binary_files_mode_is_taken_alone_and_its_content_only_whole() {
    let mut fx = base();
    set_executable(&fx.root, "bin.dat", true);
    let selected = select(&mut fx, vec![mode_and_hunks("bin.dat", &[])]).expect("select");
    assert_eq!(
        file(&tree_of(&fx.root, &selected), "bin.dat"),
        Some(("x\0y".to_owned(), true))
    );
    let err = select(&mut fx, vec![mode_and_hunks("bin.dat", &[S1])]).expect_err("keys");
    assert!(is_stale(&err), "{err:?}");
    assert!(err.to_string().contains("bin.dat can only be selected whole"), "{err}");
}

/// `select_tree` of `revision` (`None`: `@`) against its parent tree as `show` reports it.
fn select_in(
    fx: &mut Fx,
    revision: Option<&ChangeId>,
    files: Vec<FileSelection>,
) -> Result<SelectedTreeId, MutateError> {
    let entries = fx.repo.show(revision.map(|r| r.0.as_str()), None).expect("show");
    fx.repo.select_tree(&SelectTreeOptions {
        revision: revision.cloned(),
        left: entries[0].parent_tree_ids.clone(),
        files,
    })
}

/// `path` of `revision` as `file show` prints it — a conflict materialized with markers.
fn shown(fx: &mut Fx, revision: &ChangeId, path: &str) -> Vec<u8> {
    let shown = fx
        .repo
        .file_show(Some(revision.clone()), &[path.to_owned()])
        .expect("file show");
    let _ = fx.repo.take_warnings();
    shown.files[0].content.clone()
}

/// `path`'s value in `tree`.
fn value_in(tree: &MergedTree, path: &str) -> MergedTreeValue {
    let path = RepoPathBuf::from_internal_string(path).expect("path");
    pollster::block_on(tree.path_value(&path)).expect("path value")
}

/// One piece of `left` → `right` as the builtin editor cuts it: a changed section's key, or
/// `None` for matching text, with the two sides' text.
type TestPiece = (Option<HunkKey>, Vec<u8>, Vec<u8>);

/// The builtin editor's sections of `left` → `right` (`ContentDiff::by_line`), keyed in lines.
fn pieces(left: &[u8], right: &[u8]) -> Vec<TestPiece> {
    let lines = |text: &[u8]| u32::try_from(text.split_inclusive(|&b| b == b'\n').count()).expect("lines");
    let (mut old, mut new) = (0, 0);
    let mut out = Vec::new();
    for hunk in ContentDiff::by_line([left, right]).hunks() {
        let (l, r): (&[u8], &[u8]) = (hunk.contents[0].as_ref(), hunk.contents[1].as_ref());
        let section = (hunk.kind == DiffHunkKind::Different).then(|| key(old, lines(l), new, lines(r)));
        old += lines(l);
        new += lines(r);
        out.push((section, l.to_vec(), r.to_vec()));
    }
    out
}

fn keys_of(pieces: &[TestPiece]) -> Vec<HunkKey> {
    pieces.iter().filter_map(|(key, _, _)| *key).collect()
}

/// Matching text, the right side of the `selected` sections and the left side of the others.
fn assemble(pieces: &[TestPiece], selected: &[HunkKey]) -> Vec<u8> {
    pieces
        .iter()
        .flat_map(|(key, l, r)| {
            if key.is_some_and(|k| selected.contains(&k)) {
                r
            } else {
                l
            }
            .clone()
        })
        .collect()
}

/// `A` → `X` (`c.txt` = `x`) and `A` → `Y` (`c.txt` = `y`) merged into `M`, conflicted on `c.txt`;
/// `@` is a new change on `M`. Returns `M`.
fn conflicted_merge(fx: &mut Fx) -> ChangeId {
    let a = fx.a.clone();
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new x");
    write(&fx.root, "c.txt", b"x\n");
    let x = change_id(&wc(&fx.root));
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new y");
    write(&fx.root, "c.txt", b"y\n");
    let y = change_id(&wc(&fx.root));
    fx.repo.new_change(&[x, y], &[], &[]).expect("merge");
    let m = change_id(&wc(&fx.root));
    fx.repo
        .new_change(std::slice::from_ref(&m), &[], &[])
        .expect("new on the merge");
    m
}

/// A file conflicted on the left and resolved by the revision is sectioned over its materialized
/// markers: every key gives the revision's text; a subset is what `update_from_content` makes of
/// the assembled text, as the builtin writes it.
#[test]
fn a_conflicted_left_is_sectioned_over_its_markers_and_written_back_through_update_from_content() {
    let mut fx = base();
    let m = conflicted_merge(&mut fx);
    let left_text = shown(&mut fx, &m, "c.txt");
    write(&fx.root, "c.txt", b"x\ny\n");
    let pieces = pieces(&left_text, b"x\ny\n");
    let keys = keys_of(&pieces);
    assert!(keys.len() >= 2, "{keys:?}");

    let all = select_in(&mut fx, None, vec![hunks("c.txt", &keys)]).expect("every key");
    assert_eq!(text(&tree_of(&fx.root, &all), "c.txt").as_deref(), Some("x\ny\n"));

    let subset = &keys[..1];
    let assembled = assemble(&pieces, subset);
    let left_ids = value_in(&commit(&fx.root, &m).tree(), "c.txt")
        .to_file_merge()
        .expect("a file conflict");
    let (_workspace, repo) = load(&fx.root);
    let path = RepoPathBuf::from_internal_string("c.txt").expect("path");
    let expected = pollster::block_on(jj_lib::conflicts::update_from_content(
        &left_ids,
        repo.store(),
        &path,
        &assembled,
        jj_lib::conflicts::MIN_CONFLICT_MARKER_LEN,
    ))
    .expect("update_from_content");
    let some = select_in(&mut fx, None, vec![hunks("c.txt", subset)]).expect("a subset");
    let got = value_in(&tree_of(&fx.root, &some), "c.txt")
        .to_file_merge()
        .expect("files");
    assert_eq!(got.simplify(), expected.simplify());
}

/// A conflict edited inside one side, on both sides of the diff: taking the edit keeps the
/// conflict, with the revision's new file ids.
#[test]
fn a_conflict_edited_inside_a_side_keeps_the_conflict_with_new_file_ids() {
    let mut fx = base();
    let m = conflicted_merge(&mut fx);
    let left_text = shown(&mut fx, &m, "c.txt");
    let edited = String::from_utf8(left_text.clone())
        .expect("utf-8")
        .replace("\ny\n", "\nY\n");
    assert_ne!(edited.as_bytes(), left_text.as_slice(), "side y is edited");
    write(&fx.root, "c.txt", edited.as_bytes());
    let at = change_id(&wc(&fx.root));
    let right_text = shown(&mut fx, &at, "c.txt");
    let keys = keys_of(&pieces(&left_text, &right_text));
    assert!(!keys.is_empty());

    let selected = select_in(&mut fx, None, vec![hunks("c.txt", &keys)]).expect("select");
    let got = value_in(&tree_of(&fx.root, &selected), "c.txt");
    assert!(!got.is_resolved(), "still a conflict");
    let revision = value_in(&commit(&fx.root, &at).tree(), "c.txt");
    assert_eq!(
        got.to_file_merge().expect("files").simplify(),
        revision.to_file_merge().expect("files").simplify()
    );
}

/// A revision conflicted on a file its parent has resolved: the assembled text — conflict markers
/// included — becomes a resolved file, as the builtin writes it.
#[test]
fn a_resolved_left_takes_the_assembled_text_of_a_conflicted_right_markers_included() {
    let mut fx = base();
    let a = fx.a.clone();
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new x");
    write(&fx.root, "c.txt", b"x\n");
    let x = change_id(&wc(&fx.root));
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new y");
    write(&fx.root, "c.txt", b"y\n");
    let y = change_id(&wc(&fx.root));
    fx.repo
        .rebase(&zanshin_jj::RebaseOptions {
            revisions: vec![x.clone()],
            onto: vec![y],
            ..Default::default()
        })
        .expect("rebase x onto y");
    let right_text = shown(&mut fx, &x, "c.txt");
    let pieces = pieces(b"y\n", &right_text);
    let keys = keys_of(&pieces);
    let subset = &keys[..1];

    let selected = select_in(&mut fx, Some(&x), vec![hunks("c.txt", subset)]).expect("select");
    let tree = tree_of(&fx.root, &selected);
    assert_eq!(
        text(&tree, "c.txt").map(String::into_bytes),
        Some(assemble(&pieces, subset))
    );
}

/// A file/symlink conflict is no file conflict: no sections, no mode toggle — here a revision
/// adding a file rebased onto one adding a symlink there.
#[test]
fn a_non_file_conflict_has_no_sections_and_no_mode_toggle() {
    let mut fx = base();
    let a = fx.a.clone();
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new x");
    write(&fx.root, "c.txt", b"x\n");
    let x = change_id(&wc(&fx.root));
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new y");
    std::os::unix::fs::symlink("target", fx.root.join("c.txt")).expect("symlink");
    let y = change_id(&wc(&fx.root));
    fx.repo
        .rebase(&zanshin_jj::RebaseOptions {
            revisions: vec![x.clone()],
            onto: vec![y],
            ..Default::default()
        })
        .expect("rebase x onto y");
    let conflicted = commit(&fx.root, &x).tree();
    assert!(!value_in(&conflicted, "c.txt").is_resolved(), "x conflicts on c.txt");

    let err = select_in(&mut fx, Some(&x), vec![hunks("c.txt", &[key(0, 1, 0, 1)])]).expect_err("keys");
    assert!(is_stale(&err), "{err:?}");
    assert!(err.to_string().contains("c.txt can only be selected whole"), "{err}");
    let err = select_in(&mut fx, Some(&x), vec![mode_and_hunks("c.txt", &[])]).expect_err("the toggle");
    assert!(is_stale(&err), "{err:?}");
    assert!(err.to_string().contains("c.txt has no mode change"), "{err}");
    let selected = select_in(&mut fx, Some(&x), vec![whole("c.txt")]).expect("whole");
    assert_eq!(selected, ids(&conflicted));
}

/// A conflicted revision tree's labels round-trip: `select_tree` returns them, and the tree arm
/// of `commit` stores them on the committed `@`.
#[test]
fn a_conflicted_trees_labels_round_trip_through_select_tree_and_commit() {
    let mut fx = base();
    let a = fx.a.clone();
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new x");
    write(&fx.root, "c.txt", b"x\n");
    let x = change_id(&wc(&fx.root));
    fx.repo.describe(x.clone(), "X\n").expect("describe x");
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new y");
    write(&fx.root, "c.txt", b"y\n");
    let y = change_id(&wc(&fx.root));
    fx.repo.describe(y.clone(), "Y\n").expect("describe y");
    fx.repo.new_change(&[x, y], &[], &[]).expect("merge");
    write(&fx.root, "other.txt", b"o\n");
    let merge = change_id(&wc(&fx.root));
    let left = left_of(&mut fx.repo, &merge);
    let right = wc(&fx.root).tree();
    assert!(
        !right.labels().as_slice().is_empty(),
        "the merge's own tree is labelled"
    );

    let selected = fx
        .repo
        .select_tree(&SelectTreeOptions {
            revision: None,
            left: left.clone(),
            files: vec![whole("other.txt")],
        })
        .expect("select");
    assert_eq!(selected.labels, right.labels().as_slice());
    assert_eq!(selected.tree_ids.len(), right.tree_ids().num_sides() * 2 - 1);

    fx.repo
        .commit(&CommitOptions {
            message: vec!["c".to_owned()],
            tree: Some(TreeSelection {
                tree: selected.clone(),
                left,
            }),
            ..Default::default()
        })
        .expect("commit");
    let committed = commit(&fx.root, &merge).tree();
    assert_eq!(ids(&committed), selected);
    assert_eq!(committed.labels().as_slice(), right.labels().as_slice());
}

// ── commit ───────────────────────────────────────────────────────────────────────

/// The I1 case: `@` edited in another file after the selection is not stale — the committed `@`
/// is the selected tree, the new `@` holds the rest, the later edit included.
#[test]
fn commit_takes_the_tree_and_leaves_the_rest_and_a_later_edit_in_the_new_at() {
    let mut fx = base();
    let left = left_of(&mut fx.repo, &fx.at.clone());
    let selected = select(&mut fx, vec![hunks("f.txt", &[S1, S3])]).expect("select");
    write(&fx.root, "late.txt", b"late\n");

    fx.repo
        .commit(&CommitOptions {
            message: vec!["c".to_owned()],
            tree: Some(TreeSelection {
                tree: selected.clone(),
                left,
            }),
            ..Default::default()
        })
        .expect("commit");
    let committed = commit(&fx.root, &fx.at);
    assert_eq!(ids(&committed.tree()), selected);
    let at = wc(&fx.root);
    assert_eq!(at.parent_ids(), [committed.id().clone()]);
    assert_eq!(
        text(&at.tree(), "f.txt").as_deref(),
        Some(F_RIGHT),
        "section 2 stays in @"
    );
    assert_eq!(text(&at.tree(), "late.txt").as_deref(), Some("late\n"));
    assert_eq!(text(&at.tree(), "new.txt").as_deref(), Some("n\n"));
}

/// `paths` together with a tree, or a tree of the wrong shape, refuses before the snapshot: no
/// operation, no precondition report.
#[test]
fn every_verb_refuses_paths_with_a_tree_or_a_malformed_tree_before_the_snapshot() {
    let mut fx = base();
    let left = left_of(&mut fx.repo, &fx.at.clone());
    let selected = select(&mut fx, vec![whole("f.txt")]).expect("select");
    let good = TreeSelection {
        tree: selected.clone(),
        left: left.clone(),
    };
    let bad_shapes = [
        TreeSelection {
            tree: SelectedTreeId {
                tree_ids: vec!["nothex".to_owned()],
                labels: Vec::new(),
            },
            left: left.clone(),
        },
        TreeSelection {
            tree: SelectedTreeId {
                tree_ids: selected.tree_ids.clone(),
                labels: vec!["a".to_owned(), "b".to_owned()],
            },
            left: left.clone(),
        },
        TreeSelection {
            tree: selected.clone(),
            left: Vec::new(),
        },
    ];
    // An unsnapshotted edit: a refusal before the snapshot leaves it unsnapshotted.
    write(&fx.root, "late.txt", b"late\n");
    let head = head_op(&fx.root);
    let paths = vec!["f.txt".to_owned()];
    let mut refusals: Vec<MutateError> = Vec::new();
    for (i, tree) in std::iter::once(&good).chain(&bad_shapes).enumerate() {
        let with_paths = if i == 0 { paths.clone() } else { Vec::new() };
        refusals.push(
            fx.repo
                .commit(&CommitOptions {
                    paths: with_paths.clone(),
                    message: vec!["c".to_owned()],
                    tree: Some(tree.clone()),
                })
                .expect_err("commit"),
        );
        refusals.push(
            fx.repo
                .split(&SplitOptions {
                    paths: with_paths.clone(),
                    tree: Some(tree.clone()),
                    ..Default::default()
                })
                .expect_err("split"),
        );
        refusals.push(
            fx.repo
                .squash(&SquashOptions {
                    paths: with_paths,
                    trees: vec![SourceTree {
                        source: fx.at.clone(),
                        tree: tree.clone(),
                    }],
                    ..Default::default()
                })
                .expect_err("squash"),
        );
        assert!(fx.repo.take_precondition().is_none(), "refused before the snapshot");
    }
    for err in &refusals {
        assert!(is_invalid(err), "{err:?}");
    }
    assert!(refusals[0]
        .to_string()
        .contains("paths cannot be combined with a selected tree"));
    assert_eq!(head_op(&fx.root), head, "no operation, not even the snapshot's");
}

/// An unknown tree id refuses as `from_tree_id` does: the backend has no such tree.
#[test]
fn an_unknown_tree_id_refuses_from_the_backend() {
    let mut fx = base();
    let left = left_of(&mut fx.repo, &fx.at.clone());
    let err = fx
        .repo
        .commit(&CommitOptions {
            message: vec!["c".to_owned()],
            tree: Some(TreeSelection {
                tree: SelectedTreeId {
                    tree_ids: vec!["ab".repeat(20)],
                    labels: Vec::new(),
                },
                left,
            }),
            ..Default::default()
        })
        .expect_err("unknown tree");
    assert!(matches!(err, MutateError::Backend(_)), "{err:?}");
}

// ── split ────────────────────────────────────────────────────────────────────────

/// `split` with a tree: the selected commit holds the tree, the remaining one the full target.
/// A tree selecting everything, or nothing, warns as the paths arm does.
#[test]
fn split_takes_the_tree_as_the_selected_commit() {
    let mut fx = base();
    let left = left_of(&mut fx.repo, &fx.at.clone());
    let full = wc(&fx.root).tree();
    let selected = select(&mut fx, vec![hunks("f.txt", &[S1, S3])]).expect("select");
    let result = fx
        .repo
        .split(&SplitOptions {
            message: Some(vec!["first".to_owned()]),
            tree: Some(TreeSelection {
                tree: selected.clone(),
                left: left.clone(),
            }),
            ..Default::default()
        })
        .expect("split");
    assert!(fx.repo.take_warnings().is_empty());
    assert_eq!(ids(&commit(&fx.root, &result.selected_change_id).tree()), selected);
    let remaining = commit(&fx.root, &result.remaining_change_id);
    assert_eq!(remaining.tree().tree_ids(), full.tree_ids());

    let mut fx = base();
    let left = left_of(&mut fx.repo, &fx.at.clone());
    let everything = SelectedTreeId {
        tree_ids: ids(&wc(&fx.root).tree()).tree_ids,
        labels: Vec::new(),
    };
    fx.repo
        .split(&SplitOptions {
            message: Some(vec!["first".to_owned()]),
            tree: Some(TreeSelection { tree: everything, left }),
            ..Default::default()
        })
        .expect("split");
    let kinds: Vec<WarningKind> = fx.repo.take_warnings().iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::SplitAllSelected]);

    let mut fx = base();
    let left = left_of(&mut fx.repo, &fx.at.clone());
    let nothing = select(&mut fx, Vec::new()).expect("select nothing");
    fx.repo
        .split(&SplitOptions {
            message: Some(vec!["first".to_owned()]),
            tree: Some(TreeSelection { tree: nothing, left }),
            ..Default::default()
        })
        .expect("split");
    let kinds: Vec<WarningKind> = fx.repo.take_warnings().iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::SplitNoneSelected]);
}

/// `split` with neither paths nor a tree refuses, naming the tree arm.
#[test]
fn split_with_neither_paths_nor_a_tree_refuses() {
    let mut fx = base();
    let err = fx.repo.split(&SplitOptions::default()).expect_err("refused");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("paths or a selected tree")),
        "{err:?}"
    );
}

// ── squash ───────────────────────────────────────────────────────────────────────

/// `B` = `@` of [`base`] plus `g.txt`, `C` on it changing `g.txt` in two sections; `@` is `C`.
fn base_with_c() -> (Fx, ChangeId) {
    let mut fx = base();
    write(&fx.root, "g.txt", b"1\n2\n3\n");
    fx.repo.new_change(&[fx.at.clone()], &[], &[]).expect("new c");
    write(&fx.root, "g.txt", b"one\n2\nthree\n");
    let c = change_id(&wc(&fx.root));
    fx.repo.describe(c.clone(), "C\n").expect("describe c");
    (fx, c)
}

/// `revision`'s tree selection of `files`.
fn selection(fx: &mut Fx, revision: &ChangeId, files: Vec<FileSelection>) -> TreeSelection {
    let left = left_of(&mut fx.repo, revision);
    let tree = fx
        .repo
        .select_tree(&SelectTreeOptions {
            revision: Some(revision.clone()),
            left: left.clone(),
            files,
        })
        .expect("select");
    TreeSelection { tree, left }
}

/// `squash` takes one tree per source.
#[test]
fn squash_takes_a_tree_per_source() {
    let (mut fx, c) = base_with_c();
    let b = fx.at.clone();
    let tree_b = selection(&mut fx, &b, vec![hunks("f.txt", &[S1, S3]), whole("g.txt")]);
    let tree_c = selection(&mut fx, &c, vec![hunks("g.txt", &[key(2, 1, 2, 1)])]);
    fx.repo
        .squash(&SquashOptions {
            from: vec![b.clone(), c.clone()],
            into: Some(fx.a.clone()),
            message: Some(vec!["A\n".to_owned()]),
            trees: vec![
                SourceTree {
                    source: c.clone(),
                    tree: tree_c,
                },
                SourceTree {
                    source: b.clone(),
                    tree: tree_b,
                },
            ],
            ..Default::default()
        })
        .expect("squash");
    let a = commit(&fx.root, &fx.a).tree();
    assert_eq!(text(&a, "f.txt").as_deref(), Some(F_ONE_AND_THREE));
    assert_eq!(text(&a, "g.txt").as_deref(), Some("1\n2\nthree\n"));
    assert_eq!(text(&a, "new.txt"), None, "unselected in B");
    assert_eq!(text(&commit(&fx.root, &b).tree(), "new.txt").as_deref(), Some("n\n"));
    assert_eq!(
        text(&commit(&fx.root, &c).tree(), "g.txt").as_deref(),
        Some("one\n2\nthree\n")
    );
}

/// A source without a tree moves everything — what the CLI's editor saved unchanged gives.
#[test]
fn squash_moves_everything_from_a_source_without_a_tree() {
    let (mut fx, c) = base_with_c();
    let b = fx.at.clone();
    let tree_b = selection(&mut fx, &b, vec![hunks("f.txt", &[S1, S3]), whole("g.txt")]);
    let result = fx
        .repo
        .squash(&SquashOptions {
            from: vec![b.clone(), c.clone()],
            into: Some(fx.a.clone()),
            message: Some(vec!["A\n".to_owned()]),
            trees: vec![SourceTree {
                source: b.clone(),
                tree: tree_b,
            }],
            ..Default::default()
        })
        .expect("squash");
    let a = commit(&fx.root, &fx.a).tree();
    assert_eq!(text(&a, "f.txt").as_deref(), Some(F_ONE_AND_THREE));
    assert_eq!(text(&a, "g.txt").as_deref(), Some("one\n2\nthree\n"));
    assert_eq!(result.abandoned_change_ids, [c], "the emptied source is abandoned");
}

/// `squash_plan` and `squash` agree on the tree arm: a partly selected source is not abandoned,
/// so only the destination's description counts and there is nothing to ask — where the
/// full-selection squash would combine both.
#[test]
fn squash_plan_and_squash_agree_on_a_partly_selected_source() {
    let mut fx = base();
    let left = left_of(&mut fx.repo, &fx.at.clone());
    let selected = select(&mut fx, vec![hunks("f.txt", &[S1, S3])]).expect("select");
    let full = fx.repo.squash_plan(&SquashOptions::default()).expect("full plan");
    assert_eq!(full.combined_description.as_deref(), Some("A\n\nB\n"));
    let options = SquashOptions {
        trees: vec![SourceTree {
            source: fx.at.clone(),
            tree: TreeSelection { tree: selected, left },
        }],
        ..Default::default()
    };
    let plan = fx.repo.squash_plan(&options).expect("tree plan");
    assert_eq!(plan.combined_description, None);

    let result = fx.repo.squash(&options).expect("squash");
    assert!(result.abandoned_change_ids.is_empty(), "the source keeps the rest");
    let a = commit(&fx.root, &fx.a);
    assert_eq!(a.description(), "A\n");
    assert_eq!(text(&a.tree(), "f.txt").as_deref(), Some(F_ONE_AND_THREE));
    assert_eq!(
        text(&commit(&fx.root, &fx.at).tree(), "f.txt").as_deref(),
        Some(F_RIGHT)
    );
}

/// A tree naming no source, or two naming one, refuses.
#[test]
fn squash_refuses_a_tree_for_a_non_source_or_two_for_one() {
    let mut fx = base();
    let left = left_of(&mut fx.repo, &fx.at.clone());
    let selected = select(&mut fx, vec![whole("f.txt")]).expect("select");
    let entry = |source: &ChangeId| SourceTree {
        source: source.clone(),
        tree: TreeSelection {
            tree: selected.clone(),
            left: left.clone(),
        },
    };
    let head = head_op(&fx.root);
    let err = fx
        .repo
        .squash(&SquashOptions {
            trees: vec![entry(&fx.a)],
            ..Default::default()
        })
        .expect_err("not a source");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("not a source")),
        "{err:?}"
    );
    let err = fx
        .repo
        .squash(&SquashOptions {
            trees: vec![entry(&fx.at), entry(&fx.at)],
            ..Default::default()
        })
        .expect_err("twice");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("same source")),
        "{err:?}"
    );
    assert_eq!(head_op(&fx.root), head);
}
