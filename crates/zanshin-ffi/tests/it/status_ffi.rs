// SPDX-License-Identifier: MIT

//! Integration tests for `zanshin_status` FFI wrapper (Story 3.4b, status slice).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the
//! Verifier — a wrong-shape payload is a compile error, not a runtime assert.
//! Every token is freed via `zanshin_buffer_free_token` so the suite is leak-clean.

use std::ffi::CString;

use flatbuffers::root as fb_root;
use test_helpers::extract_fixture;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    repo::{zanshin_repo_close, zanshin_repo_open},
    status::zanshin_status,
    FFI_INVALID_HANDLE,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// Returns an owned `Vec<u8>` so callers can parse `fbs::Envelope` from it
/// without the Envelope borrowing from freed memory.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by one of the
/// `zanshin_*` functions and not yet freed.
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

/// Create a NUL-terminated C string from a Rust `&str`.
fn cstr(s: &str) -> CString {
    CString::new(s).expect("test string must not contain NUL bytes")
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// Open the tiny fixture, call `zanshin_status`, assert an ok Status envelope
/// with empty `files` (the root commit has no parent diff) and non-empty change
/// ids, then close the handle.
#[test]
fn status_clean_round_trip_returns_ok_empty_files() {
    test_helpers::pin_test_env();

    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path_cstr = cstr(fixture.path.to_str().expect("fixture path must be valid UTF-8"));

    // Open the repo.
    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    // Call zanshin_status with the valid handle.
    let status_token = unsafe { zanshin_status(handle) };
    let status_bytes = unsafe { read_and_free(status_token) };
    let status_env = parse_envelope(&status_bytes);

    assert!(status_env.ok(), "status must succeed for a clean repo");
    assert_eq!(status_env.data_type(), fbs::Payload::Status, "data_type must be Status");

    let payload = status_env
        .data_as_status()
        .expect("data_as_status must succeed for Payload::Status");

    // tiny-3-commits @ is on the root commit — diff vs @- is empty.
    let file_count = payload.files().map_or(0, |f| f.len());
    assert_eq!(file_count, 0, "clean repo must have zero changed files");

    // Both change ids must be populated.
    assert!(
        payload.working_copy_change_id().is_some_and(|s| !s.is_empty()),
        "working_copy_change_id must be non-empty"
    );
    assert!(
        payload.parent_change_id().is_some_and(|s| !s.is_empty()),
        "parent_change_id must be non-empty"
    );

    // Close the handle.
    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    let close_env = parse_envelope(&close_bytes);
    assert!(close_env.ok(), "repo close must succeed");
}

/// A workspace without `@` (after `op restore` of the root operation) succeeds as the CLI's
/// `jj status` does ("No working copy."): an ok Status envelope, no files, both change ids ABSENT.
#[test]
fn status_without_a_working_copy_returns_ok_with_absent_ids() {
    test_helpers::pin_test_env();

    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    zanshin_jj::Repo::open(&fixture.path)
        .expect("open")
        .op_restore("000000000000", &[])
        .expect("restore the root operation");
    let path_cstr = cstr(fixture.path.to_str().expect("fixture path must be valid UTF-8"));
    let open_bytes = unsafe { read_and_free(zanshin_repo_open(path_cstr.as_ptr())) };
    let handle = parse_envelope(&open_bytes)
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    let status_bytes = unsafe { read_and_free(zanshin_status(handle)) };
    let status_env = parse_envelope(&status_bytes);

    assert!(status_env.ok(), "{:?}", status_env.error().and_then(|e| e.code()));
    let payload = status_env.data_as_status().expect("a Status payload");
    assert_eq!(payload.files().map(|f| f.len()), Some(0));
    assert_eq!(payload.working_copy_change_id(), None);
    assert_eq!(payload.parent_change_id(), None);

    let close_bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");
}

/// Calling `zanshin_status(0)` must return `ok:false` with
/// `error.code == "ffi.invalid_handle"` — never a crash, never NULL.
#[test]
fn status_zero_handle_returns_ffi_invalid_handle() {
    test_helpers::pin_test_env();

    let token = unsafe { zanshin_status(0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "status(0) must be an error");
    assert_eq!(
        env.error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE),
        "error.code must be ffi.invalid_handle"
    );
    // The borrow routes through `envelope::session_from_handle`, whose refusal
    // carries no context — pinned so a wrapper cannot start decorating it.
    assert!(
        env.error().and_then(|e| e.context()).is_none(),
        "the invalid-handle envelope carries no context"
    );
}
