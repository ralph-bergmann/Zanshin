// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.49's wrapper `zanshin_commit`.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The repo is built in-test with
//! `zanshin_jj`'s own verbs: `A (a.txt) → B (b.txt) → C (c.txt) = @`.

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use flatbuffers::root as fb_root;
use zanshin_ffi::commit::zanshin_commit;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_COMMIT_PATHS_UNMATCHED, JJ_INVALID_INPUT,
};
use zanshin_jj::{Backend, ChangeId, Repo};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: every test calls `pin_env()` FIRST; the `LazyLock` blocks them all until this
    // initialiser returns, so no test body has read the environment yet.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", test_helpers::leaked_xdg_config_home());
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

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

/// The base repo, its open handle, and `@`'s change id.
struct Fx {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    handle: u64,
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
    pin_env();
    let tmp = tempfile::TempDir::new().expect("tempdir");
    let main = tmp.path().join("main");
    fs::create_dir(&main).expect("main dir");
    let root = Repo::init(&main, Some(Backend::Git))
        .result
        .expect("init")
        .workspace_root()
        .to_owned();
    let mut repo = Repo::open(&root).expect("open");
    let mut ids: Vec<ChangeId> = Vec::new();
    for (path, description) in [("a.txt", "A\n"), ("b.txt", "B\n"), ("c.txt", "C\n")] {
        if let Some(parent) = ids.last() {
            repo.new_change(std::slice::from_ref(parent)).expect("new");
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
        c: ids[2].0.clone(),
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

/// A `CommitRequest`; `None` leaves a vector ABSENT.
fn commit_request(paths: Option<&[&str]>, message: Option<&[&str]>, kind: fbs::RequestKind) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let mut vector = |items: Option<&[&str]>| {
        items.map(|items| {
            let offsets: Vec<_> = items.iter().map(|s| b.create_string(s)).collect();
            b.create_vector(&offsets)
        })
    };
    let paths = vector(paths);
    let message = vector(message);
    let req = fbs::CommitRequest::create(&mut b, &fbs::CommitRequestArgs { kind, paths, message });
    b.finish(req, None);
    b.finished_data().to_vec()
}

#[test]
fn commit_everything_answers_the_new_at_and_describes_the_old_one() {
    let fx = base();
    let req = commit_request(None, Some(&["first"]), fbs::RequestKind::Commit);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_commit(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let mutation = env.data_as_mutation_result().expect("MutationResult payload");
    let new_at = mutation
        .new_change_ids()
        .map(|v| v.iter().collect::<Vec<_>>())
        .expect("new_change_ids");
    assert_eq!(new_at.len(), 1);
    assert_eq!(mutation.working_copy_change_id(), Some(new_at[0]));
    assert_ne!(new_at[0], fx.c, "a new change");
    assert_eq!(mutation.new_op_id(), Some(head_op(&fx.root).as_str()));
    assert!(env.warnings().is_none_or(|w| w.is_empty()));
    let description = Repo::open(&fx.root)
        .expect("open")
        .get_change(&ChangeId(fx.c.clone()))
        .expect("change")
        .description;
    assert_eq!(description, "first\n");
}

#[test]
fn an_unmatched_path_carries_its_warning_on_an_ok_envelope() {
    let fx = base();
    let req = commit_request(Some(&["nope.txt"]), Some(&["first"]), fbs::RequestKind::Commit);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_commit(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let codes: Vec<&str> = env
        .warnings()
        .map(|w| w.iter().filter_map(|w| w.code()).collect())
        .unwrap_or_default();
    assert_eq!(codes, [JJ_COMMIT_PATHS_UNMATCHED]);
}

#[test]
fn refusals_carry_their_code_and_write_nothing() {
    let fx = base();
    let before = head_op(&fx.root);
    let invalid = commit_request(Some(&["/x"]), Some(&["first"]), fbs::RequestKind::Commit);
    // SAFETY: `fx.handle` is open; `invalid` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_commit(fx.handle, invalid.as_ptr(), invalid.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert_eq!(head_op(&fx.root), before, "no refusal wrote an operation");
}

#[test]
fn a_zero_handle_is_refused() {
    pin_env();
    let req = commit_request(None, Some(&["first"]), fbs::RequestKind::Commit);
    // SAFETY: zero is the documented invalid handle; `req` is live for the call.
    let bytes = unsafe { read_and_free(zanshin_commit(0, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_HANDLE));
}

#[test]
fn malformed_null_and_mis_routed_buffers_are_refused_before_the_handle() {
    pin_env();
    let junk = [0xffu8; 7];
    let wrong_kind = commit_request(None, Some(&["first"]), fbs::RequestKind::Split);
    // SAFETY: zero handle — every refusal fires before the handle is borrowed; the buffers are
    // live for each call and a null pointer is the documented refusal.
    unsafe {
        assert_eq!(
            error_code(&read_and_free(zanshin_commit(0, std::ptr::null(), 0))).as_deref(),
            Some(FFI_NULL_POINTER)
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_commit(0, junk.as_ptr(), junk.len()))).as_deref(),
            Some(FFI_INVALID_ARGUMENT)
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_commit(0, wrong_kind.as_ptr(), wrong_kind.len()))).as_deref(),
            Some(FFI_INVALID_ARGUMENT),
            "a buffer tagged for another wrapper"
        );
    }
}
