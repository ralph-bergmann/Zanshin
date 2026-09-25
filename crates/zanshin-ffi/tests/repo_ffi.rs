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
    repo::{
        zanshin_repo_clone, zanshin_repo_close, zanshin_repo_convert, zanshin_repo_detect, zanshin_repo_init,
        zanshin_repo_open,
    },
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, JJ_ALREADY_JJ_REPO, JJ_DETECT_FAILED, JJ_JJ_LIB_ERROR, JJ_NOT_A_GIT_REPO,
    JJ_PATH_NOT_FOUND, JJ_REPO_NOT_FOUND,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: empty string avoids needing a tempdir just for an env pin; matches the
    // zanshin-jj test convention so CI and local runs produce identical results.
    //
    // `$XDG_CONFIG_HOME` needs a real directory instead, leaked for the process lifetime:
    // this binary calls `zanshin_repo_convert`, and a conversion writes the repo-level
    // `revset-aliases.'trunk()'` OUTSIDE the repo, into `$XDG_CONFIG_HOME/jj/repos/`. The
    // fixtures here happen to have no `refs/remotes/*/HEAD`, so nothing lands there today —
    // the pin is what keeps that an accident rather than a write into the developer's real
    // `~/.config`. Same pattern as `zanshin-jj/tests/convert.rs`.
    let xdg = TempDir::new().expect("xdg tempdir").keep();
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
        env::set_var("XDG_CONFIG_HOME", &xdg);
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

// ── zanshin_repo_detect ───────────────────────────────────────────────────────

#[test]
fn detect_jj_fixture_returns_jj_kind() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path = cstr(fixture.path.to_str().expect("fixture path must be UTF-8"));

    let token = unsafe { zanshin_repo_detect(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(
        env.ok(),
        "detect on jj repo must succeed; error: {:?}",
        env.error().and_then(|e| e.code())
    );
    assert_eq!(env.data_type(), fbs::Payload::RepoDetect);
    let rd = env.data_as_repo_detect().expect("RepoDetect payload must be present");
    assert_eq!(rd.kind(), fbs::RepoKind::Jj);
    assert!(rd.suggested_root().is_none(), "jj repo must have no suggestion");
}

#[test]
fn detect_git_only_dir_returns_git_kind() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    git_with_commit(tmp.path());
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    let token = unsafe { zanshin_repo_detect(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok());
    let rd = env.data_as_repo_detect().expect("RepoDetect");
    assert_eq!(rd.kind(), fbs::RepoKind::Git);
    assert!(rd.suggested_root().is_none(), "git repo must have no suggestion");
}

#[test]
fn detect_empty_dir_returns_neither() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    let token = unsafe { zanshin_repo_detect(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok());
    let rd = env.data_as_repo_detect().expect("RepoDetect");
    assert_eq!(rd.kind(), fbs::RepoKind::Neither);
}

#[test]
fn detect_nonexistent_path_returns_path_not_found() {
    pin_env();
    let path = cstr("/nonexistent/zanshin-detect-abc999");

    let token = unsafe { zanshin_repo_detect(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "PathNotFound is a normal result, not an error");
    let rd = env.data_as_repo_detect().expect("RepoDetect");
    assert_eq!(rd.kind(), fbs::RepoKind::PathNotFound);
}

#[test]
fn detect_path_under_regular_file_returns_detect_failed_error() {
    pin_env();
    // Create a regular file, then ask to detect a sub-path under it.
    // The OS returns ENOTDIR when stat-ing the sub-component → jj.detect_failed.
    let tmp = TempDir::new().expect("tempdir");
    let file_path = tmp.path().join("regular_file");
    fs::write(&file_path, b"data").expect("write file");
    let sub = file_path.join("nonexistent_child");
    let path = cstr(sub.to_str().expect("path must be UTF-8"));

    let token = unsafe { zanshin_repo_detect(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "ENOTDIR must yield an error envelope");
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_DETECT_FAILED));
}

#[test]
fn detect_neither_subdir_inside_jj_repo_returns_suggestion() {
    pin_env();
    // Create a jj repo, then detect an empty subdir inside it.
    // detect_repo returns Neither; find_repo_root should return the jj root.
    let tmp = TempDir::new().expect("tempdir");
    let jj_path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    // Init a jj repo at tmp.
    let init_tok = unsafe { zanshin_repo_init(jj_path.as_ptr(), 0) };
    let init_bytes = unsafe { read_and_free(init_tok) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "jj init must succeed");
    let handle = init_env.data_as_repo_handle().expect("RepoHandle").handle();
    let close_tok = unsafe { zanshin_repo_close(handle) };
    unsafe { read_and_free(close_tok) };

    // Create an empty subdir inside the jj repo.
    let sub = tmp.path().join("inner");
    fs::create_dir(&sub).expect("create inner dir");
    let sub_path = cstr(sub.to_str().expect("path must be UTF-8"));

    let token = unsafe { zanshin_repo_detect(sub_path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok());
    let rd = env.data_as_repo_detect().expect("RepoDetect");
    assert_eq!(rd.kind(), fbs::RepoKind::Neither);
    let suggested_root = rd
        .suggested_root()
        .expect("suggestion must be present for subdir inside jj repo");
    assert!(!suggested_root.is_empty(), "suggested_root must not be empty");
    assert_eq!(rd.suggested_kind(), fbs::RepoKind::Jj, "suggestion must be Jj kind");
}

#[test]
fn detect_neither_subdir_inside_git_repo_returns_git_suggestion() {
    pin_env();
    // Empty subdir inside a Git repo: detect_repo returns Neither; find_repo_root
    // returns the enclosing Git root with a Git suggested_kind. Symmetric twin of
    // the jj-suggestion test — the only test that observes a `Git` value in the
    // suggested_kind slot crossing the wire (the decode-contract test deliberately
    // nulls it out, so this exercises repo_kind_to_fbs(Git) end-to-end).
    let tmp = TempDir::new().expect("tempdir");
    git_with_commit(tmp.path());

    let sub = tmp.path().join("inner");
    fs::create_dir(&sub).expect("create inner dir");
    let sub_path = cstr(sub.to_str().expect("path must be UTF-8"));

    let token = unsafe { zanshin_repo_detect(sub_path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok());
    let rd = env.data_as_repo_detect().expect("RepoDetect");
    assert_eq!(rd.kind(), fbs::RepoKind::Neither);
    let suggested_root = rd
        .suggested_root()
        .expect("suggestion must be present for subdir inside git repo");
    assert!(!suggested_root.is_empty(), "suggested_root must not be empty");
    assert_eq!(rd.suggested_kind(), fbs::RepoKind::Git, "suggestion must be Git kind");
}

#[test]
fn detect_path_not_found_inside_jj_repo_returns_jj_suggestion() {
    pin_env();
    // Nonexistent child path inside a jj repo: detect_repo returns PathNotFound;
    // find_repo_root still walks ancestors and finds the enclosing jj root. Covers
    // the PathNotFound half of the `Neither | PathNotFound => find_repo_root` arm.
    let tmp = TempDir::new().expect("tempdir");
    let jj_path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    let init_tok = unsafe { zanshin_repo_init(jj_path.as_ptr(), 0) };
    let init_bytes = unsafe { read_and_free(init_tok) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "jj init must succeed");
    let handle = init_env.data_as_repo_handle().expect("RepoHandle").handle();
    let close_tok = unsafe { zanshin_repo_close(handle) };
    unsafe { read_and_free(close_tok) };

    // A child path that does not exist on disk.
    let missing = tmp.path().join("does_not_exist_child");
    let missing_path = cstr(missing.to_str().expect("path must be UTF-8"));

    let token = unsafe { zanshin_repo_detect(missing_path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "PathNotFound is a normal result, not an error");
    let rd = env.data_as_repo_detect().expect("RepoDetect");
    assert_eq!(rd.kind(), fbs::RepoKind::PathNotFound);
    let suggested_root = rd
        .suggested_root()
        .expect("suggestion must be present for a missing child inside a jj repo");
    assert!(!suggested_root.is_empty(), "suggested_root must not be empty");
    assert_eq!(rd.suggested_kind(), fbs::RepoKind::Jj, "suggestion must be Jj kind");
}

// ── zanshin_repo_convert ──────────────────────────────────────────────────────

#[test]
fn convert_git_repo_returns_handle_then_detect_returns_jj() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    git_with_commit(tmp.path());
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    // Convert the Git repo to a colocated jj workspace.
    let conv_tok = unsafe { zanshin_repo_convert(path.as_ptr()) };
    let conv_bytes = unsafe { read_and_free(conv_tok) };
    let conv_env = parse_envelope(&conv_bytes);
    assert!(
        conv_env.ok(),
        "convert must succeed; error: {:?}",
        conv_env.error().and_then(|e| e.code())
    );
    assert_eq!(conv_env.data_type(), fbs::Payload::RepoHandle);
    let handle = conv_env.data_as_repo_handle().expect("RepoHandle").handle();
    assert_ne!(handle, 0, "handle must be non-zero");

    // Close the converted repo handle.
    let close_tok = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_tok) };
    assert!(parse_envelope(&close_bytes).ok());

    // Re-detect the same path — must now be Jj.
    let det_tok = unsafe { zanshin_repo_detect(path.as_ptr()) };
    let det_bytes = unsafe { read_and_free(det_tok) };
    let det_env = parse_envelope(&det_bytes);
    assert!(det_env.ok());
    let rd = det_env.data_as_repo_detect().expect("RepoDetect");
    assert_eq!(
        rd.kind(),
        fbs::RepoKind::Jj,
        "path must now be detected as Jj after conversion"
    );
}

#[test]
fn convert_already_jj_repo_returns_already_jj_repo_error() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path = cstr(fixture.path.to_str().expect("fixture path must be UTF-8"));

    let token = unsafe { zanshin_repo_convert(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_ALREADY_JJ_REPO));
}

#[test]
fn convert_empty_dir_returns_not_a_git_repo_error() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    let token = unsafe { zanshin_repo_convert(path.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_NOT_A_GIT_REPO));
}

/// Create a git repo with a single commit so `convert_colocated` accepts it.
fn git_with_commit(dir: &std::path::Path) {
    git(&["init", "--initial-branch=main"], dir);
    git(&["config", "user.email", "test@zanshin.test"], dir);
    git(&["config", "user.name", "Fixture"], dir);
    fs::write(dir.join("README.md"), "hello").expect("write README");
    git(&["add", "."], dir);
    git(&["commit", "-m", "initial"], dir);
}

// ── Story 9.33: the creating call's report ────────────────────────────────────

/// The envelope's warnings as `(code, message)` pairs, in wire order; absent reads as empty.
fn wire_warnings(env: &fbs::Envelope<'_>) -> Vec<(String, String)> {
    env.warnings()
        .map(|v| {
            v.iter()
                .map(|w| (w.code().unwrap_or("").to_owned(), w.message().unwrap_or("").to_owned()))
                .collect()
        })
        .unwrap_or_default()
}

/// Closes `handle`, asserting the close succeeded.
fn close(handle: u64) {
    let bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(parse_envelope(&bytes).ok(), "close must succeed");
}

/// Init and open report nothing: both creation-report fields are ABSENT on the wire. (Open's
/// start-up secure-config fix-up finds nothing to fix in a fresh workspace — Story 9.37; its
/// notices are pinned in `tests/secure_config_ffi.rs`.)
#[test]
fn init_and_open_envelopes_carry_no_report() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    let init_bytes = unsafe { read_and_free(zanshin_repo_init(path.as_ptr(), 1)) };
    let init = parse_envelope(&init_bytes);
    assert!(init.ok());
    assert!(init.precondition().is_none(), "init runs no snapshot");
    assert!(init.warnings().is_none(), "init warns about nothing");
    close(init.data_as_repo_handle().expect("RepoHandle").handle());

    let open_bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let open = parse_envelope(&open_bytes);
    assert!(open.ok());
    assert!(open.precondition().is_none(), "open runs no snapshot");
    assert!(open.warnings().is_none(), "open warns about nothing");
    close(open.data_as_repo_handle().expect("RepoHandle").handle());
}

/// A clone into a target that already holds an untracked `README.md` the default branch also
/// has: the checkout leaves it alone, and the ok envelope says so. Reachable only because
/// Zanshin's clone accepts a non-empty target, which the CLI refuses (`git/clone.rs:188-192`) —
/// a Story 9.20 divergence; this witness flips to a refusal when 9.20 lands.
#[test]
fn clone_into_a_colliding_target_warns_that_a_checkout_was_skipped() {
    pin_env();
    let src = TempDir::new().expect("src tempdir");
    git_with_commit(src.path());
    let target = TempDir::new().expect("target tempdir");
    fs::write(target.path().join("README.md"), "local").expect("write the untracked file");
    let url = cstr(&format!("file://{}", src.path().display()));
    let target_c = cstr(target.path().to_str().expect("path must be UTF-8"));

    let bytes = unsafe { read_and_free(zanshin_repo_clone(url.as_ptr(), target_c.as_ptr())) };
    let env = parse_envelope(&bytes);
    assert!(
        env.ok(),
        "clone must succeed: {:?}",
        env.error().and_then(|e| e.context())
    );
    assert!(env.precondition().is_none(), "a clone runs no snapshot");
    assert_eq!(
        wire_warnings(&env),
        [(
            "jj.checkout_files_skipped".to_owned(),
            "1 of those updates were skipped because there were conflicting changes in the working copy.".to_owned()
        )]
    );
    assert_eq!(fs::read_to_string(target.path().join("README.md")).unwrap(), "local");
    close(env.data_as_repo_handle().expect("RepoHandle").handle());
}

/// A conversion whose work tree holds a new file over the builtin 1 MiB limit: the ok envelope
/// carries the conversion's snapshot report naming it, and the refusal warning.
#[test]
fn convert_with_a_big_new_file_reports_the_snapshot_and_the_refusal() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    git_with_commit(tmp.path());
    fs::write(tmp.path().join("big.bin"), vec![b'a'; 2 * 1024 * 1024]).expect("write the big file");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    let bytes = unsafe { read_and_free(zanshin_repo_convert(path.as_ptr())) };
    let env = parse_envelope(&bytes);
    assert!(
        env.ok(),
        "convert must succeed: {:?}",
        env.error().and_then(|e| e.context())
    );
    let precondition = env
        .precondition()
        .expect("the conversion's snapshot report rides the envelope");
    assert!(precondition.git_head_imported());
    let untracked = precondition
        .snapshot_stats()
        .and_then(|s| s.untracked())
        .expect("the refused file is reported");
    assert_eq!(untracked.len(), 1);
    assert_eq!(untracked.get(0).path(), Some("big.bin"));
    assert_eq!(
        wire_warnings(&env),
        [(
            "jj.snapshot_files_refused".to_owned(),
            "Refused to snapshot some files:\n  big.bin: 2.0MiB (2097152 bytes); the maximum size allowed is 1.0MiB \
             (1048576 bytes)"
                .to_owned()
        )]
    );
    close(env.data_as_repo_handle().expect("RepoHandle").handle());
}

/// A conversion whose own snapshot fails (a new file it cannot open, mode `0o000`): the ERROR
/// envelope carries the refs step's warning and the partial snapshot report on the wire.
#[test]
fn convert_whose_snapshot_fails_reports_on_the_error_envelope() {
    use std::os::unix::fs::PermissionsExt as _;

    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    git_with_commit(tmp.path());
    git(&["update-ref", "refs/remotes/git/stolen", "HEAD"], tmp.path());
    let locked = tmp.path().join("locked.txt");
    fs::write(&locked, "unreadable").expect("write the unreadable file");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).expect("make it unreadable");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    let bytes = unsafe { read_and_free(zanshin_repo_convert(path.as_ptr())) };
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o644)).expect("restore the mode");
    let env = parse_envelope(&bytes);
    assert!(!env.ok(), "the snapshot cannot open the file");
    assert_eq!(env.error().and_then(|e| e.code()), Some("jj.convert_failed"));
    assert_eq!(
        wire_warnings(&env),
        [(
            "jj.git_import_failed".to_owned(),
            "Failed to import some Git refs:\n  refs/remotes/git/stolen".to_owned()
        )]
    );
    let precondition = env
        .precondition()
        .expect("the partial snapshot report rides the error envelope");
    assert!(
        precondition.git_head_imported(),
        "the head import ran before the snapshot failed"
    );
}
