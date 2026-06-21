// SPDX-License-Identifier: MIT

//! Integration tests for `zanshin_repo_open/init/clone/close` FFI wrappers (Story 3.4a).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the
//! `Verifier` — a wrong-shape payload is a compile error, not a runtime assert.
//! Every token is freed via `zanshin_buffer_free_token` so the suite is leak-clean.

use std::ffi::CString;
use std::sync::LazyLock;
use std::{env, fs};

use flatbuffers::root as fb_root;
use tempfile::TempDir;
use test_helpers::extract_fixture;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    repo::{zanshin_repo_clone, zanshin_repo_close, zanshin_repo_init, zanshin_repo_open},
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR, JJ_PATH_NOT_FOUND, JJ_REPO_NOT_FOUND,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: empty string avoids needing a tempdir just for an env pin; matches the
    // zanshin-jj test convention so CI and local runs produce identical results.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// Returns an owned `Vec<u8>` so callers can parse `fbs::Envelope` from it
/// without the Envelope borrowing from freed memory.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by one of the
/// `zanshin_repo_*` functions and not yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    // SAFETY: token is valid; we copy bytes before freeing.
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    // SAFETY: token is valid; freed exactly once here after the copy above.
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// Parse bytes into a verified `fbs::Envelope`.
///
/// Runs the `FlatBuffers` `Verifier` — panics on malformed input, which is the
/// correct test behaviour (a wrong-shape payload is a bug in the Rust layer).
fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("CString::new must not fail for a non-null string")
}

// ── zanshin_repo_open ─────────────────────────────────────────────────────────

#[test]
fn repo_open_with_tiny_fixture_returns_repo_handle() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path = cstr(fixture.path.to_str().expect("fixture path must be UTF-8"));

    let token = unsafe { zanshin_repo_open(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "expected ok, error: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::RepoHandle);
    let rh = env.data_as_repo_handle().expect("RepoHandle payload must be present");
    let handle = rh.handle();
    assert_ne!(handle, 0, "handle must be non-zero for a live repo");

    // Clean up: close the handle we just opened.
    let ct = unsafe { zanshin_repo_close(handle) };
    let cb = unsafe { read_and_free(ct) };
    assert!(parse_envelope(&cb).ok(), "close after open must succeed");
}

#[test]
fn repo_open_with_nonexistent_path_returns_path_not_found() {
    pin_env();
    let path = cstr("/nonexistent/zanshin-ffi-test-abc123");
    let token = unsafe { zanshin_repo_open(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_PATH_NOT_FOUND));
}

#[test]
fn repo_open_with_non_jj_directory_returns_repo_not_found() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));
    let token = unsafe { zanshin_repo_open(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_REPO_NOT_FOUND));
}

#[test]
fn repo_open_null_pointer_returns_null_pointer_error() {
    pin_env();
    let token = unsafe { zanshin_repo_open(std::ptr::null()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(zanshin_ffi::FFI_NULL_POINTER));
}

#[test]
fn repo_open_invalid_utf8_path_returns_utf8_error() {
    pin_env();
    // 0x80 is a lone continuation byte — a valid C string (no interior NUL) but invalid UTF-8,
    // so cstr_to_string must reject it before any repo access. Exercises the ffi.utf8_error path
    // each wrapper's docstring promises (open shares cstr_to_string with init/clone).
    let path = CString::new(vec![0x66u8, 0x80, 0x6f]).expect("no interior NUL");
    let token = unsafe { zanshin_repo_open(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(zanshin_ffi::FFI_UTF8_ERROR));
}

// ── zanshin_repo_init ─────────────────────────────────────────────────────────

#[test]
fn repo_init_native_backend_then_open_succeeds() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    // Init with native backend (0).
    let t = unsafe { zanshin_repo_init(path.as_ptr(), 0) };
    let b = unsafe { read_and_free(t) };
    let env = parse_envelope(&b);
    assert!(env.ok(), "init(native) must succeed");
    let handle = env.data_as_repo_handle().expect("RepoHandle must be present").handle();
    assert_ne!(handle, 0);

    // Close the init handle.
    let ct = unsafe { zanshin_repo_close(handle) };
    let cb = unsafe { read_and_free(ct) };
    assert!(parse_envelope(&cb).ok());

    // Re-open to prove round-trip.
    let ot = unsafe { zanshin_repo_open(path.as_ptr()) };
    let ob = unsafe { read_and_free(ot) };
    let open_env = parse_envelope(&ob);
    assert!(open_env.ok(), "open after native init must succeed");
    let h2 = open_env.data_as_repo_handle().expect("RepoHandle").handle();
    let ct2 = unsafe { zanshin_repo_close(h2) };
    let cb2 = unsafe { read_and_free(ct2) };
    assert!(parse_envelope(&cb2).ok());
}

#[test]
fn repo_init_git_backend_then_open_succeeds() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    let t = unsafe { zanshin_repo_init(path.as_ptr(), 1) };
    let b = unsafe { read_and_free(t) };
    let env = parse_envelope(&b);
    assert!(env.ok(), "init(git) must succeed");
    let handle = env.data_as_repo_handle().expect("RepoHandle").handle();
    assert_ne!(handle, 0);

    let ct = unsafe { zanshin_repo_close(handle) };
    let cb = unsafe { read_and_free(ct) };
    assert!(parse_envelope(&cb).ok());

    // Re-open to prove round-trip.
    let ot = unsafe { zanshin_repo_open(path.as_ptr()) };
    let ob = unsafe { read_and_free(ot) };
    let open_env = parse_envelope(&ob);
    assert!(open_env.ok(), "open after git init must succeed");
    let h2 = open_env.data_as_repo_handle().expect("RepoHandle").handle();
    let ct2 = unsafe { zanshin_repo_close(h2) };
    let cb2 = unsafe { read_and_free(ct2) };
    assert!(parse_envelope(&cb2).ok());
}

#[test]
fn repo_init_twice_at_same_location_returns_jj_lib_error() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    let t1 = unsafe { zanshin_repo_init(path.as_ptr(), 0) };
    let b1 = unsafe { read_and_free(t1) };
    let e1 = parse_envelope(&b1);
    assert!(e1.ok(), "first init must succeed");
    let h = e1.data_as_repo_handle().expect("RepoHandle").handle();
    let ct = unsafe { zanshin_repo_close(h) };
    let cb = unsafe { read_and_free(ct) };
    assert!(parse_envelope(&cb).ok());

    // Second init at same path must fail with jj.jj_lib_error.
    let t2 = unsafe { zanshin_repo_init(path.as_ptr(), 0) };
    let b2 = unsafe { read_and_free(t2) };
    let e2 = parse_envelope(&b2);
    assert!(!e2.ok(), "second init at same path must fail");
    assert_eq!(e2.error().and_then(|e| e.code()), Some(JJ_JJ_LIB_ERROR));
}

#[test]
fn repo_init_invalid_backend_returns_ffi_invalid_argument() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));
    let token = unsafe { zanshin_repo_init(path.as_ptr(), 99) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));
}

#[test]
fn repo_init_null_pointer_returns_null_pointer_error() {
    pin_env();
    let token = unsafe { zanshin_repo_init(std::ptr::null(), 0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(zanshin_ffi::FFI_NULL_POINTER));
}

// ── zanshin_repo_clone ────────────────────────────────────────────────────────

#[test]
fn repo_clone_from_local_git_source_returns_repo_handle() {
    pin_env();

    let src_tmp = TempDir::new().expect("src tempdir");
    git(&["init", "--initial-branch=main"], src_tmp.path());
    git(&["config", "user.email", "test@zanshin.test"], src_tmp.path());
    git(&["config", "user.name", "Fixture"], src_tmp.path());
    fs::write(src_tmp.path().join("README.md"), "hello").expect("write README");
    git(&["add", "."], src_tmp.path());
    git(&["commit", "-m", "initial"], src_tmp.path());

    let target_tmp = TempDir::new().expect("target tempdir");
    let src_url = format!("file://{}", src_tmp.path().display());
    let url = cstr(&src_url);
    let target = cstr(target_tmp.path().to_str().expect("path must be UTF-8"));

    let token = unsafe { zanshin_repo_clone(url.as_ptr(), target.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "clone from local file:// must succeed");
    let rh = env.data_as_repo_handle().expect("RepoHandle must be present");
    let handle = rh.handle();
    assert_ne!(handle, 0);

    let ct = unsafe { zanshin_repo_close(handle) };
    let cb = unsafe { read_and_free(ct) };
    assert!(parse_envelope(&cb).ok());
}

#[test]
fn repo_clone_with_invalid_url_returns_jj_lib_error() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let url = cstr("not-a-real-url://nope");
    let target = cstr(tmp.path().to_str().expect("path must be UTF-8"));
    let token = unsafe { zanshin_repo_clone(url.as_ptr(), target.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_JJ_LIB_ERROR));
}

#[test]
fn repo_clone_null_url_returns_null_pointer_error() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let target = cstr(tmp.path().to_str().expect("path must be UTF-8"));
    let token = unsafe { zanshin_repo_clone(std::ptr::null(), target.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(zanshin_ffi::FFI_NULL_POINTER));
}

#[test]
fn repo_clone_null_target_returns_null_pointer_error() {
    pin_env();
    // url is read and validated before target_path, so a null target only surfaces
    // when url is a valid C string — this exercises the second, otherwise-unreached check.
    let url = cstr("file:///tmp/zanshin-ffi-clone-null-target");
    let token = unsafe { zanshin_repo_clone(url.as_ptr(), std::ptr::null()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(zanshin_ffi::FFI_NULL_POINTER));
}

// ── zanshin_repo_close ────────────────────────────────────────────────────────

#[test]
fn repo_close_valid_handle_from_open_returns_ok() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path = cstr(fixture.path.to_str().expect("path must be UTF-8"));

    let ot = unsafe { zanshin_repo_open(path.as_ptr()) };
    let ob = unsafe { read_and_free(ot) };
    let open_env = parse_envelope(&ob);
    assert!(open_env.ok());
    let handle = open_env.data_as_repo_handle().expect("RepoHandle").handle();

    let ct = unsafe { zanshin_repo_close(handle) };
    let cb = unsafe { read_and_free(ct) };
    let close_env = parse_envelope(&cb);
    assert!(close_env.ok(), "close must succeed for a valid handle");
    assert_eq!(close_env.data_type(), fbs::Payload::NONE, "close returns no payload");
}

#[test]
fn repo_close_zero_handle_returns_ffi_invalid_handle() {
    pin_env();
    let token = unsafe { zanshin_repo_close(0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_HANDLE));
}

// ── Panic backstop ────────────────────────────────────────────────────────────

#[test]
fn catch_panic_in_envelope_catch_returns_internal_panic() {
    use zanshin_ffi::envelope::{catch, FfiErrorObj, INTERNAL_PANIC};

    let buf = catch(|| -> Result<Vec<u8>, FfiErrorObj> { panic!("integration panic seam") });
    let env = fb_root::<fbs::Envelope>(&buf).expect("FlatBuffers Verifier must pass");
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(INTERNAL_PANIC));
    assert!(
        env.error()
            .and_then(|e| e.context())
            .is_some_and(|c| c.contains("integration panic seam")),
        "panic message must appear in context"
    );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn git(args: &[&str], dir: &std::path::Path) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}
