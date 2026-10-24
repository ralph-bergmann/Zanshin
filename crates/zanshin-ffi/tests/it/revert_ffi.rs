// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.18's `zanshin_revert`.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The repo is built in-test with
//! `zanshin_jj`'s own verbs: `A (a.txt) → B (b.txt) = @`.

use std::ffi::CString;
use std::fs;
use std::path::PathBuf;

use flatbuffers::{root as fb_root, FlatBufferBuilder};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::revert::zanshin_revert;
use zanshin_ffi::{FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_INVALID_INPUT};
use zanshin_jj::{Backend, Repo};

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
    _root: PathBuf,
    handle: u64,
    b: String,
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
    let at = |repo: &mut Repo| repo.status().expect("status").working_copy_change_id.expect("@");
    fs::write(root.join("a.txt"), "a\n").expect("write");
    let a = at(&mut repo);
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new b");
    fs::write(root.join("b.txt"), "b\n").expect("write");
    let b = at(&mut repo);
    let path = CString::new(root.to_str().expect("UTF-8 path")).expect("no NUL");
    // SAFETY: `path` is a valid NUL-terminated C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let handle = parse_envelope(&bytes)
        .data_as_repo_handle()
        .expect("RepoHandle payload")
        .handle();
    Fx {
        _tmp: tmp,
        _root: root,
        handle,
        b: b.0,
    }
}

fn request(kind: fbs::RequestKind, revisions: &[&str], onto: &[&str], after: &[&str]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128);
    let mut ids = |ids: &[&str]| {
        let ids: Vec<_> = ids.iter().map(|id| b.create_string(id)).collect();
        b.create_vector(&ids)
    };
    let (revisions, onto, after) = (ids(revisions), ids(onto), ids(after));
    let req = fbs::RevertRequest::create(
        &mut b,
        &fbs::RevertRequestArgs {
            kind,
            revisions: Some(revisions),
            onto: Some(onto),
            insert_after: Some(after),
            insert_before: None,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Reverting `@` onto itself answers one new change and the new operation, with the snapshot's
/// precondition report.
#[test]
fn revert_onto_the_working_copy_answers_the_reverse_change() {
    let fx = base();
    let req = request(fbs::RequestKind::Revert, &[&fx.b], &[&fx.b], &[]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_revert(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    assert!(env.precondition().is_some());
    let mutation = env.data_as_mutation_result().expect("MutationResult");
    let new = mutation.new_change_ids().expect("new change ids");
    assert_eq!(new.len(), 1);
    assert_ne!(new.get(0), fx.b);
    assert!(mutation.new_op_id().is_some_and(|id| !id.is_empty()));
}

/// `-o` with `-A` refuses before the snapshot; a wrong kind, a zero handle and a null buffer are
/// refused.
#[test]
fn bad_arguments_are_refused() {
    let fx = base();
    let req = request(fbs::RequestKind::Revert, &[&fx.b], &[&fx.b], &[&fx.b]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_revert(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert!(parse_envelope(&bytes).precondition().is_none());

    let req = request(fbs::RequestKind::Duplicate, &[&fx.b], &[&fx.b], &[]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_revert(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_ARGUMENT));

    let req = request(fbs::RequestKind::Revert, &[&fx.b], &[&fx.b], &[]);
    // SAFETY: a zero handle is detected; `req` is live.
    let bytes = unsafe { read_and_free(zanshin_revert(0, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_HANDLE));
    // SAFETY: a null buffer is detected before the handle is touched.
    let bytes = unsafe { read_and_free(zanshin_revert(fx.handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_NULL_POINTER));
}
