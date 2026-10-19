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
    let t = unsafe { repo_init(&path, 0) };
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

    let t = unsafe { repo_init(&path, 1) };
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
fn repo_init_twice_at_same_location_returns_already_jj_repo() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));

    let t1 = unsafe { repo_init(&path, 0) };
    let b1 = unsafe { read_and_free(t1) };
    let e1 = parse_envelope(&b1);
    assert!(e1.ok(), "first init must succeed");
    let h = e1.data_as_repo_handle().expect("RepoHandle").handle();
    let ct = unsafe { zanshin_repo_close(h) };
    let cb = unsafe { read_and_free(ct) };
    assert!(parse_envelope(&cb).ok());

    // Second init at same path is jj-lib's `DestinationExists` — `jj.already_jj_repo` since
    // Story 9.20 (was the generic `jj.jj_lib_error`).
    let t2 = unsafe { repo_init(&path, 0) };
    let b2 = unsafe { read_and_free(t2) };
    let e2 = parse_envelope(&b2);
    assert!(!e2.ok(), "second init at same path must fail");
    assert_eq!(e2.error().and_then(|e| e.code()), Some(zanshin_ffi::JJ_ALREADY_JJ_REPO));
}

#[test]
fn repo_init_invalid_backend_returns_ffi_invalid_argument() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let path = cstr(tmp.path().to_str().expect("path must be UTF-8"));
    let token = unsafe { repo_init(&path, 99) };
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

    let token = unsafe { repo_clone(&url, &target) };
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
    let token = unsafe { repo_clone(&url, &target) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_JJ_LIB_ERROR));
}

#[test]
fn repo_clone_null_request_returns_null_pointer_error() {
    pin_env();
    let token = unsafe { zanshin_repo_clone(std::ptr::null(), 0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(zanshin_ffi::FFI_NULL_POINTER));
}

/// Story 9.20: the request's required fields, its kind tag and a malformed buffer are refused
/// before anything is created; absent vs present-empty `branches` is read as the CLI's flag.
#[test]
fn repo_clone_request_is_validated_before_anything_is_created() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let target = tmp.path().join("dst");
    let build = |kind: fbs::RequestKind, source: Option<&str>, destination: Option<&str>| {
        let mut b = flatbuffers::FlatBufferBuilder::new();
        let source = source.map(|s| b.create_string(s));
        let destination = destination.map(|d| b.create_string(d));
        let req = fbs::RepoCloneRequest::create(
            &mut b,
            &fbs::RepoCloneRequestArgs {
                kind,
                source,
                destination,
                ..Default::default()
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    };
    let dst = target.to_str().expect("UTF-8");
    for (bytes, code) in [
        (
            build(fbs::RequestKind::RepoClone, None, Some(dst)),
            zanshin_ffi::JJ_INVALID_INPUT,
        ),
        (
            build(fbs::RequestKind::RepoClone, Some("file:///nowhere"), None),
            zanshin_ffi::JJ_INVALID_INPUT,
        ),
        (
            build(fbs::RequestKind::RepoInit, Some("file:///nowhere"), Some(dst)),
            FFI_INVALID_ARGUMENT,
        ),
        (vec![1, 2, 3], FFI_INVALID_ARGUMENT),
    ] {
        let token = unsafe { zanshin_repo_clone(bytes.as_ptr(), bytes.len()) };
        let out = unsafe { read_and_free(token) };
        let env = parse_envelope(&out);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(code));
    }
    assert!(!target.exists(), "a refused request creates nothing");
}

/// Story 9.20: a non-empty destination is `jj.destination_not_empty`, before anything is created.
#[test]
fn repo_clone_into_a_non_empty_destination_returns_destination_not_empty() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    fs::write(tmp.path().join("file"), "x").expect("write");
    let url = cstr("file:///nowhere");
    let target = cstr(tmp.path().to_str().expect("path must be UTF-8"));
    let token = unsafe { repo_clone(&url, &target) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(
        env.error().and_then(|e| e.code()),
        Some(zanshin_ffi::JJ_DESTINATION_NOT_EMPTY)
    );
    assert!(!tmp.path().join(".jj").exists());
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
    let init_tok = unsafe { repo_init(&jj_path, 0) };
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

    let init_tok = unsafe { repo_init(&jj_path, 0) };
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

    let init_bytes = unsafe { read_and_free(repo_init(&path, 1)) };
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
/// has. Story 9.33 witnessed `jj.checkout_files_skipped` here, reachable only through Zanshin's
/// old non-empty-target divergence; since Story 9.20 the clone refuses the target first, as the
/// CLI does (`git/clone.rs:186-196` @ v0.46.0), and leaves the file alone.
#[test]
fn clone_into_a_colliding_target_is_refused_and_keeps_the_file() {
    pin_env();
    let src = TempDir::new().expect("src tempdir");
    git_with_commit(src.path());
    let target = TempDir::new().expect("target tempdir");
    fs::write(target.path().join("README.md"), "local").expect("write the untracked file");
    let url = cstr(&format!("file://{}", src.path().display()));
    let target_c = cstr(target.path().to_str().expect("path must be UTF-8"));

    let bytes = unsafe { read_and_free(repo_clone(&url, &target_c)) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some("jj.destination_not_empty"));
    assert!(env.warnings().is_none(), "nothing ran, nothing warned");
    assert_eq!(fs::read_to_string(target.path().join("README.md")).unwrap(), "local");
    assert!(!target.path().join(".jj").exists());
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

/// `zanshin_repo_init` over a `RepoInitRequest` (Story 9.20): `backend` 0 = native, 1 = git — a git
/// one with `no_colocate`, the internal workspace these rows were written against.
unsafe fn repo_init(path: &std::ffi::CString, backend: i32) -> *mut zanshin_ffi::ffi_strings::ZanshinBuf {
    let mut b = flatbuffers::FlatBufferBuilder::new();
    let path = b.create_string(path.to_str().expect("UTF-8 path"));
    let req = zanshin_ffi::fbs::RepoInitRequest::create(
        &mut b,
        &zanshin_ffi::fbs::RepoInitRequestArgs {
            kind: zanshin_ffi::fbs::RequestKind::RepoInit,
            path: Some(path),
            backend: zanshin_ffi::fbs::InitBackend(u8::try_from(backend).expect("a backend byte")),
            colocate: false,
            no_colocate: backend == 1,
            object_hash: zanshin_ffi::fbs::ObjectHash::Unspecified,
        },
    );
    b.finish(req, None);
    let bytes = b.finished_data();
    // SAFETY: `bytes` is a live, caller-owned request buffer for the duration of the call.
    unsafe { zanshin_ffi::repo::zanshin_repo_init(bytes.as_ptr(), bytes.len()) }
}

/// `zanshin_repo_clone` over a `RepoCloneRequest` (Story 9.20), `no_colocate` — the internal
/// workspace these rows were written against.
unsafe fn repo_clone(url: &std::ffi::CString, target: &std::ffi::CString) -> *mut zanshin_ffi::ffi_strings::ZanshinBuf {
    let mut b = flatbuffers::FlatBufferBuilder::new();
    let source = b.create_string(url.to_str().expect("UTF-8 url"));
    let destination = b.create_string(target.to_str().expect("UTF-8 target"));
    let req = zanshin_ffi::fbs::RepoCloneRequest::create(
        &mut b,
        &zanshin_ffi::fbs::RepoCloneRequestArgs {
            kind: zanshin_ffi::fbs::RequestKind::RepoClone,
            source: Some(source),
            destination: Some(destination),
            no_colocate: true,
            ..Default::default()
        },
    );
    b.finish(req, None);
    let bytes = b.finished_data();
    // SAFETY: `bytes` is a live, caller-owned request buffer for the duration of the call.
    unsafe { zanshin_ffi::repo::zanshin_repo_clone(bytes.as_ptr(), bytes.len()) }
}
