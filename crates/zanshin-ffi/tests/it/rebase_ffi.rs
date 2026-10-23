// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.16's three wrappers: `zanshin_rebase`, `zanshin_parallelize` and
//! `zanshin_arrange`.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The repo is built in-test with
//! `zanshin_jj`'s own verbs: `A (a.txt) → B (b.txt) → C (c.txt) = @`.

use std::ffi::CString;
use std::fs;
use std::path::{Path, PathBuf};

use flatbuffers::root as fb_root;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::rebase::{zanshin_arrange, zanshin_parallelize, zanshin_rebase};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CHANGE_NOT_FOUND, JJ_IMMUTABLE, JJ_INVALID_INPUT,
};
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

/// The base repo, its open handle, and the three change ids.
struct Fx {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    handle: u64,
    a: String,
    b: String,
    c: String,
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
        path: std::path::PathBuf::from(&main),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init")
    .workspace_root()
    .to_owned();
    let mut repo = Repo::open(&root).expect("open");
    let mut ids = Vec::new();
    for (path, description) in [("a.txt", "A\n"), ("b.txt", "B\n"), ("c.txt", "C\n")] {
        if let Some(parent) = ids.last() {
            repo.new_change(std::slice::from_ref(parent), &[], &[]).expect("new");
        }
        fs::write(root.join(path), "x\n").expect("write");
        let at = repo.status().expect("status").working_copy_change_id;
        repo.describe(at.clone(), description).expect("describe");
        ids.push(at);
    }
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
        a: ids[0].0.clone(),
        b: ids[1].0.clone(),
        c: ids[2].0.clone(),
    }
}

/// The head operation: its id and description.
fn head_op(root: &Path) -> (String, String) {
    let op = Repo::open(root)
        .expect("open")
        .op_log(Some(1))
        .expect("op log")
        .swap_remove(0);
    (op.id.0, op.description)
}

fn parent_ids(root: &Path, id: &str) -> Vec<String> {
    Repo::open(root)
        .expect("open")
        .get_change(&ChangeId(id.to_owned()))
        .expect("change")
        .parents
        .into_iter()
        .map(|parent| parent.0)
        .collect()
}

fn strings<'a>(
    b: &mut flatbuffers::FlatBufferBuilder<'a>,
    items: &[&str],
) -> Option<flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<&'a str>>>> {
    (!items.is_empty()).then(|| {
        let offsets: Vec<_> = items.iter().map(|s| b.create_string(s)).collect();
        b.create_vector(&offsets)
    })
}

/// A `RebaseRequest`: `-r revisions`, `-s source`, `-o onto` (empty = absent).
fn rebase_request(revisions: &[&str], source: &[&str], onto: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let revisions = strings(&mut b, revisions);
    let source = strings(&mut b, source);
    let onto = strings(&mut b, onto);
    let req = fbs::RebaseRequest::create(
        &mut b,
        &fbs::RebaseRequestArgs {
            kind: fbs::RequestKind::Rebase,
            revisions,
            source,
            onto,
            ..fbs::RebaseRequestArgs::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `ChangeIdList` tagged `kind`.
fn change_id_list(kind: fbs::RequestKind, ids: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let change_ids = strings(&mut b, ids);
    let req = fbs::ChangeIdList::create(
        &mut b,
        &fbs::ChangeIdListArgs {
            kind,
            change_ids,
            ..fbs::ChangeIdListArgs::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// An `ArrangeRequest`: `revisions` and the `actions`.
fn arrange_request(revisions: &[&str], actions: &[(fbs::ArrangeActionKind, &str)]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let revisions = strings(&mut b, revisions);
    let offsets: Vec<_> = actions
        .iter()
        .map(|(kind, change)| {
            let change_id = Some(b.create_string(change));
            fbs::ArrangeAction::create(&mut b, &fbs::ArrangeActionArgs { kind: *kind, change_id })
        })
        .collect();
    let actions = b.create_vector(&offsets);
    let req = fbs::ArrangeRequest::create(
        &mut b,
        &fbs::ArrangeRequestArgs {
            kind: fbs::RequestKind::Arrange,
            revisions,
            actions: Some(actions),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Asserts `bytes` is an ok `MutationResult` whose `new_op_id` is the head described `description`.
fn assert_written(fx: &Fx, bytes: &[u8], description: &str) {
    let env = parse_envelope(bytes);
    assert!(env.ok(), "{:?}", error_code(bytes));
    let (op_id, op_description) = head_op(&fx.root);
    assert_eq!(op_description, description);
    assert_eq!(
        env.data_as_mutation_result().and_then(|m| m.new_op_id()),
        Some(op_id.as_str())
    );
}

#[test]
fn rebase_moves_a_source_onto_a_target() {
    let fx = base();
    let req = rebase_request(&[], &[&fx.c], &[&fx.a]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_rebase(fx.handle, req.as_ptr(), req.len())) };
    let description = head_op(&fx.root).1;
    assert!(description.starts_with("rebase commit ") && description.ends_with(" and descendants"));
    assert_written(&fx, &bytes, &description);
    assert_eq!(parent_ids(&fx.root, &fx.c), std::slice::from_ref(&fx.a));
}

#[test]
fn parallelize_makes_siblings() {
    let fx = base();
    let req = change_id_list(fbs::RequestKind::Parallelize, &[&fx.b, &fx.c]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_parallelize(fx.handle, req.as_ptr(), req.len())) };
    assert_written(&fx, &bytes, "parallelize 2 commits");
    assert_eq!(parent_ids(&fx.root, &fx.c), std::slice::from_ref(&fx.a));
}

#[test]
fn arrange_replays_the_actions() {
    let fx = base();
    let req = arrange_request(&[&fx.b, &fx.c], &[(fbs::ArrangeActionKind::Abandon, &fx.b)]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_arrange(fx.handle, req.as_ptr(), req.len())) };
    assert_written(&fx, &bytes, "arrange revisions");
    let env = parse_envelope(&bytes);
    assert_eq!(
        env.data_as_mutation_result()
            .and_then(|m| m.abandoned_change_ids())
            .map(|v| v.iter().collect::<Vec<_>>()),
        Some(vec![fx.b.as_str()])
    );
    assert_eq!(parent_ids(&fx.root, &fx.c), std::slice::from_ref(&fx.a));
}

#[test]
fn no_ops_answer_the_pre_call_head() {
    let fx = base();
    let before = head_op(&fx.root).0;
    let rebase = rebase_request(&[], &[&fx.b], &[&fx.a]);
    let parallelize = change_id_list(fbs::RequestKind::Parallelize, &[&fx.b]);
    let arrange = arrange_request(&[&fx.b, &fx.c], &[]);
    // SAFETY: `fx.handle` is open; the buffers are live for each call.
    let replies = unsafe {
        [
            read_and_free(zanshin_rebase(fx.handle, rebase.as_ptr(), rebase.len())),
            read_and_free(zanshin_parallelize(fx.handle, parallelize.as_ptr(), parallelize.len())),
            read_and_free(zanshin_arrange(fx.handle, arrange.as_ptr(), arrange.len())),
        ]
    };
    for bytes in &replies {
        let env = parse_envelope(bytes);
        assert!(env.ok(), "{:?}", error_code(bytes));
        assert_eq!(
            env.data_as_mutation_result().and_then(|m| m.new_op_id()),
            Some(before.as_str())
        );
    }
    assert_eq!(head_op(&fx.root).0, before);
}

#[test]
fn refusals_carry_their_code_and_hints_and_write_nothing() {
    let fx = base();
    let before = head_op(&fx.root).0;

    // `-r` and `-s` together: clap's conflict.
    let conflicting = rebase_request(&[&fx.b], &[&fx.c], &[&fx.a]);
    // SAFETY: `fx.handle` is open; the buffers are live for each call.
    let bytes = unsafe { read_and_free(zanshin_rebase(fx.handle, conflicting.as_ptr(), conflicting.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));

    // The root is immutable.
    let root_change = "z".repeat(32);
    let immutable = rebase_request(&[&root_change], &[], &[&fx.a]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_rebase(fx.handle, immutable.as_ptr(), immutable.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_IMMUTABLE));

    let unknown = change_id_list(fbs::RequestKind::Parallelize, &[&"k".repeat(32)]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_parallelize(fx.handle, unknown.as_ptr(), unknown.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_CHANGE_NOT_FOUND));

    // A gap: B is missing between A and C.
    let gap = arrange_request(&[&fx.a, &fx.c], &[]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_arrange(fx.handle, gap.as_ptr(), gap.len())) };
    let env = parse_envelope(&bytes);
    let error = env.error().expect("error");
    assert_eq!(error.code(), Some(JJ_INVALID_INPUT));
    assert_eq!(error.context(), Some("Cannot arrange revset with gaps in."));
    let hints: Vec<&str> = error.hints().expect("hints").iter().collect();
    assert_eq!(hints.len(), 1);
    assert!(hints[0].starts_with("Revision ") && hints[0].ends_with(" would need to be in the set."));

    assert_eq!(head_op(&fx.root).0, before, "no refusal wrote an operation");
}

#[test]
fn malformed_and_mis_tagged_buffers_refuse_before_the_handle() {
    test_helpers::pin_test_env();
    let garbage = [1_u8, 2, 3];
    let abandon = change_id_list(fbs::RequestKind::Abandon, &["x"]);
    let rebase = rebase_request(&[], &[], &["x"]);
    // SAFETY: zero is the documented invalid handle; the buffers are live for each call, and a
    // null `data` is the documented null-pointer case.
    let codes = unsafe {
        [
            error_code(&read_and_free(zanshin_rebase(0, garbage.as_ptr(), garbage.len()))),
            error_code(&read_and_free(zanshin_parallelize(0, abandon.as_ptr(), abandon.len()))),
            error_code(&read_and_free(zanshin_arrange(0, rebase.as_ptr(), rebase.len()))),
            error_code(&read_and_free(zanshin_rebase(0, std::ptr::null(), 0))),
        ]
    };
    assert_eq!(
        codes.each_ref().map(Option::as_deref),
        [
            Some(FFI_INVALID_ARGUMENT),
            Some(FFI_INVALID_ARGUMENT),
            Some(FFI_INVALID_ARGUMENT),
            Some(FFI_NULL_POINTER)
        ]
    );
}

#[test]
fn every_wrapper_refuses_a_zero_handle() {
    test_helpers::pin_test_env();
    let rebase = rebase_request(&[], &[], &["x"]);
    let parallelize = change_id_list(fbs::RequestKind::Parallelize, &[]);
    let arrange = arrange_request(&[], &[]);
    // SAFETY: zero is the documented invalid handle; the buffers are live for each call.
    let codes = unsafe {
        [
            error_code(&read_and_free(zanshin_rebase(0, rebase.as_ptr(), rebase.len()))),
            error_code(&read_and_free(zanshin_parallelize(
                0,
                parallelize.as_ptr(),
                parallelize.len(),
            ))),
            error_code(&read_and_free(zanshin_arrange(0, arrange.as_ptr(), arrange.len()))),
        ]
    };
    assert_eq!(codes.each_ref().map(Option::as_deref), [Some(FFI_INVALID_HANDLE); 3]);
}
