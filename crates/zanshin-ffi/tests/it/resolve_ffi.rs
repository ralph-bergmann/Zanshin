// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.17's `zanshin_resolve_list` and `zanshin_resolve`.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The repo is built in-test with
//! `zanshin_jj`'s own verbs: `A`, then `X` and `Y` on it writing `c.txt` = `c from C` / `c from
//! D`, merged into `@` — a 2-sided conflict without a base.

use std::ffi::CString;
use std::fs;
use std::path::PathBuf;

use flatbuffers::{root as fb_root, FlatBufferBuilder};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::resolve::{zanshin_resolve, zanshin_resolve_list};
use zanshin_ffi::{FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_INVALID_INPUT, JJ_NO_CONFLICTS};
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
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new x");
    fs::write(root.join("c.txt"), "c from C\n").expect("write");
    let x = at(&mut repo);
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new y");
    fs::write(root.join("c.txt"), "c from D\n").expect("write");
    let y = at(&mut repo);
    repo.new_change(&[x, y], &[], &[]).expect("merge");
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
    }
}

fn list_request() -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(64);
    let req = fbs::ResolveListRequest::create(
        &mut b,
        &fbs::ResolveListRequestArgs {
            kind: fbs::RequestKind::ResolveList,
            ..Default::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn resolve_request(tool: fbs::ResolveTool, paths: &[&str]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(64);
    let paths: Vec<_> = paths.iter().map(|p| b.create_string(p)).collect();
    let paths = b.create_vector(&paths);
    let req = fbs::ResolveRequest::create(
        &mut b,
        &fbs::ResolveRequestArgs {
            kind: fbs::RequestKind::Resolve,
            paths: Some(paths),
            tool,
            ..Default::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// The list carries the conflict's description, sides and three-term hunk; `:theirs` resolves it
/// and the list then refuses `jj.no_conflicts`.
#[test]
fn list_then_resolve_then_no_conflicts() {
    let fx = base();
    let req = list_request();
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_resolve_list(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    assert!(env.precondition().is_some());
    let files = env.data_as_resolve_list().expect("ResolveList").files().expect("files");
    assert_eq!(files.len(), 1);
    let file = files.get(0);
    assert_eq!(file.path(), Some("c.txt"));
    assert_eq!(file.description(), Some("2-sided conflict"));
    assert_eq!(file.num_sides(), 2);
    assert!(file.unresolvable().is_none());
    let hunks = file.hunks().expect("hunks");
    assert_eq!(hunks.len(), 1);
    let terms: Vec<Vec<u8>> = hunks
        .get(0)
        .terms()
        .expect("terms")
        .iter()
        .map(|t| t.content().map(|c| c.bytes().to_vec()).unwrap_or_default())
        .collect();
    assert_eq!(terms, [b"c from C\n".to_vec(), Vec::new(), b"c from D\n".to_vec()]);

    let req = resolve_request(fbs::ResolveTool::Theirs, &[]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_resolve(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    assert!(env.data_as_mutation_result().is_some());

    let req = list_request();
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_resolve_list(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_NO_CONFLICTS));
    let context = parse_envelope(&bytes)
        .error()
        .and_then(|e| e.context())
        .map(ToOwned::to_owned);
    assert_eq!(context.as_deref(), Some("No conflicts found at this revision"));
}

/// `Files` with paths refuses before the snapshot; a zero handle and a null buffer are refused.
#[test]
fn bad_arguments_are_refused() {
    let fx = base();
    let req = resolve_request(fbs::ResolveTool::Files, &["c.txt"]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_resolve(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert!(parse_envelope(&bytes).precondition().is_none());

    let req = list_request();
    // SAFETY: a zero handle is detected; `req` is live.
    let bytes = unsafe { read_and_free(zanshin_resolve_list(0, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_HANDLE));
    // SAFETY: a null buffer is detected before the handle is touched.
    let bytes = unsafe { read_and_free(zanshin_resolve(fx.handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_NULL_POINTER));
}
