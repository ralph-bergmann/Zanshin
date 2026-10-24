// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.50's wrapper `zanshin_select_tree` and the tree arms of
//! `zanshin_commit`, `zanshin_split` and `zanshin_squash`.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The repo is built in-test with
//! `zanshin_jj`'s own verbs: `A` holds `f.txt` = `a b c d e`, `@` on it `A b C d E` (three
//! sections) and an added `new.txt`.

use std::ffi::CString;
use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use flatbuffers::{root as fb_root, FlatBufferBuilder, WIPOffset};
use zanshin_ffi::commit::zanshin_commit;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::select_tree::zanshin_select_tree;
use zanshin_ffi::squash_split::{zanshin_split, zanshin_squash};
use zanshin_ffi::{FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_INVALID_INPUT, JJ_STALE_SELECTION};
use zanshin_jj::{Backend, ChangeId, Repo};

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by a `zanshin_*` function and not
/// yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

fn error_code(bytes: &[u8]) -> Option<String> {
    parse_envelope(bytes)
        .error()
        .and_then(|e| e.code())
        .map(ToOwned::to_owned)
}

struct Fx {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    handle: u64,
    at: String,
    left: Vec<String>,
}

impl Drop for Fx {
    fn drop(&mut self) {
        // SAFETY: the handle came from `zanshin_repo_open` below and is closed exactly once.
        let bytes = unsafe { read_and_free(zanshin_repo_close(self.handle)) };
        assert!(parse_envelope(&bytes).ok());
    }
}

fn base() -> Fx {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().expect("tempdir");
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
    fs::write(root.join("f.txt"), "a\nb\nc\nd\ne\n").expect("write");
    let a = repo.status().expect("status").working_copy_change_id.expect("@");
    repo.describe(a.clone(), "A\n").expect("describe");
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    fs::write(root.join("f.txt"), "A\nb\nC\nd\nE\n").expect("write");
    fs::write(root.join("new.txt"), "n\n").expect("write");
    let at = repo.status().expect("status").working_copy_change_id.expect("@");
    let left = repo.show(None, None).expect("show").swap_remove(0).parent_tree_ids;
    let path = CString::new(root.to_str().expect("UTF-8 path")).expect("no NUL");
    // SAFETY: `path` is a valid NUL-terminated C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let handle = parse_envelope(&bytes)
        .data_as_repo_handle()
        .expect("RepoHandle payload")
        .handle();
    Fx {
        _tmp: tmp,
        root,
        handle,
        at: at.0,
        left,
    }
}

fn head_op(root: &Path) -> String {
    Repo::open(root)
        .expect("open")
        .op_log(Some(1))
        .expect("op log")
        .swap_remove(0)
        .id
        .0
}

fn strings<'b>(
    b: &mut FlatBufferBuilder<'b>,
    values: &[String],
) -> WIPOffset<flatbuffers::Vector<'b, flatbuffers::ForwardsUOffset<&'b str>>> {
    let offsets: Vec<_> = values.iter().map(|v| b.create_string(v)).collect();
    b.create_vector(&offsets)
}

/// A `SelectTreeRequest` for `@`: `f.txt` by `hunks` (`(old_start, old_count, new_start,
/// new_count)`), or whole when `whole` is set.
fn select_request(kind: fbs::RequestKind, left: &[String], whole: bool, hunks: &[(u32, u32, u32, u32)]) -> Vec<u8> {
    select_request_with_mode(kind, left, whole, false, hunks)
}

/// [`select_request`] with `f.txt`'s `mode` toggle.
fn select_request_with_mode(
    kind: fbs::RequestKind,
    left: &[String],
    whole: bool,
    mode: bool,
    hunks: &[(u32, u32, u32, u32)],
) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let keys: Vec<_> = hunks
        .iter()
        .map(|&(old_start, old_count, new_start, new_count)| {
            fbs::HunkKey::create(
                &mut b,
                &fbs::HunkKeyArgs {
                    old_start,
                    old_count,
                    new_start,
                    new_count,
                },
            )
        })
        .collect();
    let keys = b.create_vector(&keys);
    let path = b.create_string("f.txt");
    let file = fbs::FileSelection::create(
        &mut b,
        &fbs::FileSelectionArgs {
            path: Some(path),
            whole,
            hunks: Some(keys),
            mode,
        },
    );
    let files = b.create_vector(&[file]);
    let left = strings(&mut b, left);
    let req = fbs::SelectTreeRequest::create(
        &mut b,
        &fbs::SelectTreeRequestArgs {
            kind,
            revision: None,
            left: Some(left),
            files: Some(files),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Runs `zanshin_select_tree` for sections 1 and 3 of `f.txt` and returns the `SelectedTree`
/// payload's ids and labels.
fn select_one_and_three(fx: &Fx) -> (Vec<String>, Vec<String>) {
    let req = select_request(
        fbs::RequestKind::SelectTree,
        &fx.left,
        false,
        &[(0, 1, 0, 1), (4, 1, 4, 1)],
    );
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_select_tree(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    assert!(env.precondition().is_some(), "the pre-verb snapshot ran");
    let tree = env.data_as_selected_tree().expect("SelectedTree payload");
    let read = |v: Option<flatbuffers::Vector<'_, flatbuffers::ForwardsUOffset<&str>>>| -> Vec<String> {
        v.map(|v| v.iter().map(ToOwned::to_owned).collect()).unwrap_or_default()
    };
    (read(tree.tree_ids()), read(tree.labels()))
}

fn tree_selection<'b>(
    b: &mut FlatBufferBuilder<'b>,
    (tree_ids, labels): &(Vec<String>, Vec<String>),
    left: &[String],
) -> WIPOffset<fbs::TreeSelection<'b>> {
    let tree_ids = strings(b, tree_ids);
    let labels = strings(b, labels);
    let left = strings(b, left);
    fbs::TreeSelection::create(
        b,
        &fbs::TreeSelectionArgs {
            tree_ids: Some(tree_ids),
            labels: Some(labels),
            left: Some(left),
        },
    )
}

fn commit_request(tree: &(Vec<String>, Vec<String>), left: &[String], paths: &[String]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let tree = tree_selection(&mut b, tree, left);
    let message = strings(&mut b, &["c".to_owned()]);
    let paths = strings(&mut b, paths);
    let req = fbs::CommitRequest::create(
        &mut b,
        &fbs::CommitRequestArgs {
            kind: fbs::RequestKind::Commit,
            paths: Some(paths),
            message: Some(message),
            tree: Some(tree),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn file_at(root: &Path, change: &str, path: &str) -> String {
    let mut repo = Repo::open(root).expect("open");
    let shown = repo
        .file_show(Some(ChangeId(change.to_owned())), &[path.to_owned()])
        .expect("file show")
        .files
        .swap_remove(0);
    String::from_utf8(shown.content).expect("utf-8")
}

/// Sections 1 and 3, committed through the tree arm: the committed `@` holds them, the new `@`
/// section 2 as well.
#[test]
fn select_tree_then_commit_leaves_section_two_in_the_new_at() {
    let fx = base();
    let head = head_op(&fx.root);
    let tree = select_one_and_three(&fx);
    assert_eq!(head_op(&fx.root), head, "select_tree writes no operation");
    assert_eq!(tree.0.len(), 1);
    assert!(tree.1.is_empty());

    let req = commit_request(&tree, &fx.left, &[]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_commit(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let new_at = env
        .data_as_mutation_result()
        .and_then(|m| m.working_copy_change_id())
        .expect("new @")
        .to_owned();
    assert_eq!(file_at(&fx.root, &fx.at, "f.txt"), "A\nb\nc\nd\nE\n");
    assert_eq!(file_at(&fx.root, &new_at, "f.txt"), "A\nb\nC\nd\nE\n");
}

/// A stale `left` refuses `jj.stale_selection`; `whole` with hunks and paths with a tree
/// `jj.invalid_input`; nothing is written.
#[test]
fn stale_and_malformed_selections_carry_their_codes() {
    let fx = base();
    let tree = select_one_and_three(&fx);
    let head = head_op(&fx.root);
    let stale_left = tree.0.clone();

    let req = select_request(fbs::RequestKind::SelectTree, &stale_left, false, &[(0, 1, 0, 1)]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_select_tree(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_STALE_SELECTION));

    let req = commit_request(&tree, &stale_left, &[]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_commit(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_STALE_SELECTION));

    let req = select_request(fbs::RequestKind::SelectTree, &fx.left, true, &[(0, 1, 0, 1)]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_select_tree(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert!(
        parse_envelope(&bytes).precondition().is_none(),
        "refused before the snapshot"
    );

    let req = commit_request(&tree, &fx.left, &["f.txt".to_owned()]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_commit(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert_eq!(head_op(&fx.root), head, "no refusal wrote an operation");
}

/// The mode toggle crosses the wire: on a file without a mode change it is stale, on one that
/// became executable it selects a tree other than the left one; with `whole` it is refused.
#[test]
fn the_mode_toggle_crosses_the_wire() {
    let fx = base();
    let req = select_request_with_mode(fbs::RequestKind::SelectTree, &fx.left, false, true, &[]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_select_tree(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_STALE_SELECTION));

    fs::set_permissions(fx.root.join("f.txt"), fs::Permissions::from_mode(0o755)).expect("chmod");
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_select_tree(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let tree_ids: Vec<String> = env
        .data_as_selected_tree()
        .expect("SelectedTree")
        .tree_ids()
        .expect("tree ids")
        .iter()
        .map(str::to_owned)
        .collect();
    assert_ne!(tree_ids, fx.left, "the right mode is taken");

    let req = select_request_with_mode(fbs::RequestKind::SelectTree, &fx.left, true, true, &[]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_select_tree(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
}

/// `split`'s and `squash`'s readers carry the tree arm through.
#[test]
fn split_and_squash_take_the_tree_arm() {
    let fx = base();
    let tree = select_one_and_three(&fx);
    let mut b = FlatBufferBuilder::with_capacity(256);
    let selection = tree_selection(&mut b, &tree, &fx.left);
    let message = strings(&mut b, &["first".to_owned()]);
    let req = fbs::SplitRequest::create(
        &mut b,
        &fbs::SplitRequestArgs {
            kind: fbs::RequestKind::Split,
            message: Some(message),
            tree: Some(selection),
            ..Default::default()
        },
    );
    b.finish(req, None);
    let req = b.finished_data().to_vec();
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_split(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let selected = env
        .data_as_split_result()
        .and_then(|r| r.selected_change_id())
        .expect("selected")
        .to_owned();
    assert_eq!(file_at(&fx.root, &selected, "f.txt"), "A\nb\nc\nd\nE\n");

    // `squash -r @` with the tree for its one source: sections 1 and 3 move into `A`.
    let fx = base();
    let tree = select_one_and_three(&fx);
    let mut b = FlatBufferBuilder::with_capacity(256);
    let selection = tree_selection(&mut b, &tree, &fx.left);
    let source = b.create_string(&fx.at);
    let entry = fbs::SourceTree::create(
        &mut b,
        &fbs::SourceTreeArgs {
            source: Some(source),
            tree: Some(selection),
        },
    );
    let trees = b.create_vector(&[entry]);
    let message = strings(&mut b, &["A\n".to_owned()]);
    let req = fbs::SquashRequest::create(
        &mut b,
        &fbs::SquashRequestArgs {
            kind: fbs::RequestKind::Squash,
            message: Some(message),
            trees: Some(trees),
            ..Default::default()
        },
    );
    b.finish(req, None);
    let req = b.finished_data().to_vec();
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_squash(fx.handle, req.as_ptr(), req.len())) };
    assert!(parse_envelope(&bytes).ok(), "{:?}", error_code(&bytes));
    let parent = Repo::open(&fx.root)
        .expect("open")
        .show(Some(&format!("{}-", fx.at)), None)
        .expect("show parent")
        .swap_remove(0)
        .change
        .id
        .0;
    assert_eq!(file_at(&fx.root, &parent, "f.txt"), "A\nb\nc\nd\nE\n");
    assert_eq!(file_at(&fx.root, &fx.at, "f.txt"), "A\nb\nC\nd\nE\n");
}

/// A `SelectTreeRequest` picking `path` whole in `revision` (`None` = `@`); returns the
/// `SelectedTree` payload's ids and labels.
fn select_whole(handle: u64, revision: Option<&str>, left: &[String], path: &str) -> (Vec<String>, Vec<String>) {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let path = b.create_string(path);
    let file = fbs::FileSelection::create(
        &mut b,
        &fbs::FileSelectionArgs {
            path: Some(path),
            whole: true,
            hunks: None,
            mode: false,
        },
    );
    let files = b.create_vector(&[file]);
    let left = strings(&mut b, left);
    let revision = revision.map(|r| b.create_string(r));
    let req = fbs::SelectTreeRequest::create(
        &mut b,
        &fbs::SelectTreeRequestArgs {
            kind: fbs::RequestKind::SelectTree,
            revision,
            left: Some(left),
            files: Some(files),
        },
    );
    b.finish(req, None);
    let req = b.finished_data().to_vec();
    // SAFETY: `handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_select_tree(handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let tree = env.data_as_selected_tree().expect("SelectedTree payload");
    let read = |v: Option<flatbuffers::Vector<'_, flatbuffers::ForwardsUOffset<&str>>>| -> Vec<String> {
        v.map(|v| v.iter().map(ToOwned::to_owned).collect()).unwrap_or_default()
    };
    (read(tree.tree_ids()), read(tree.labels()))
}

/// A conflicted tree's ids and labels cross the wire both ways: `zanshin_select_tree` returns
/// them for a merge `@` with a conflicted file, and `zanshin_commit`'s tree arm stores them on
/// the committed revision (read back with a second whole-file selection on it, whose result is
/// that revision's own tree).
#[test]
fn a_conflicted_trees_ids_and_labels_round_trip_through_the_wire() {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().expect("tempdir");
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
    let a = repo.status().expect("status").working_copy_change_id.expect("@");
    repo.describe(a.clone(), "A\n").expect("describe A");
    let mut side = |content: &str, message: &str| {
        repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
        fs::write(root.join("c.txt"), content).expect("write");
        let id = repo.status().expect("status").working_copy_change_id.expect("@");
        repo.describe(id.clone(), message).expect("describe");
        id
    };
    let x = side("x\n", "X\n");
    let y = side("y\n", "Y\n");
    repo.new_change(&[x, y], &[], &[]).expect("merge");
    fs::write(root.join("other.txt"), "o\n").expect("write");
    let merge = repo.status().expect("status").working_copy_change_id.expect("@");
    let left = repo.show(None, None).expect("show").swap_remove(0).parent_tree_ids;
    drop(repo);
    let path = CString::new(root.to_str().expect("UTF-8 path")).expect("no NUL");
    // SAFETY: `path` is a valid NUL-terminated C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let handle = parse_envelope(&bytes)
        .data_as_repo_handle()
        .expect("RepoHandle payload")
        .handle();

    let tree = select_whole(handle, None, &left, "other.txt");
    assert!(tree.0.len() > 1, "a conflicted tree travels as several ids");
    assert_eq!(tree.1.len(), tree.0.len(), "one label per id");
    assert!(tree.1.iter().any(|l| !l.is_empty()), "the labels are carried");

    let req = commit_request(&tree, &left, &[]);
    // SAFETY: `handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_commit(handle, req.as_ptr(), req.len())) };
    assert!(parse_envelope(&bytes).ok(), "{:?}", error_code(&bytes));

    let committed_left = Repo::open(&root)
        .expect("open")
        .show(Some(&merge.0), None)
        .expect("show")
        .swap_remove(0)
        .parent_tree_ids;
    assert_eq!(committed_left, left);
    assert_eq!(
        select_whole(handle, Some(&merge.0), &left, "other.txt"),
        tree,
        "the committed revision's tree keeps the selected ids and labels"
    );
    // SAFETY: the handle came from `zanshin_repo_open` above and is closed exactly once.
    let bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(parse_envelope(&bytes).ok());
}

#[test]
fn a_zero_handle_and_malformed_buffers_are_refused() {
    test_helpers::pin_test_env();
    let req = select_request(fbs::RequestKind::SelectTree, &["ab".repeat(20)], false, &[]);
    let wrong_kind = select_request(fbs::RequestKind::Commit, &["ab".repeat(20)], false, &[]);
    let junk = [0xffu8; 7];
    // SAFETY: zero is the documented invalid handle; the buffers are live for each call and a
    // null pointer is the documented refusal.
    unsafe {
        assert_eq!(
            error_code(&read_and_free(zanshin_select_tree(0, req.as_ptr(), req.len()))).as_deref(),
            Some(FFI_INVALID_HANDLE)
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_select_tree(0, std::ptr::null(), 0))).as_deref(),
            Some(FFI_NULL_POINTER)
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_select_tree(0, junk.as_ptr(), junk.len()))).as_deref(),
            Some(FFI_INVALID_ARGUMENT)
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_select_tree(
                0,
                wrong_kind.as_ptr(),
                wrong_kind.len()
            )))
            .as_deref(),
            Some(FFI_INVALID_ARGUMENT),
            "a buffer tagged for another wrapper"
        );
    }
}
