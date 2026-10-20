// SPDX-License-Identifier: MIT

//! Integration tests for `zanshin_change` FFI wrapper (Story 3.4b, change slice).
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
    change::zanshin_change,
    repo::{zanshin_repo_close, zanshin_repo_open},
    status::zanshin_status,
    FFI_INVALID_HANDLE, FFI_NULL_POINTER, FFI_UTF8_ERROR, JJ_CHANGE_NOT_FOUND,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by one of the
/// `zanshin_*` functions and not yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// Parse bytes into a verified `fbs::Envelope`.
fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

/// Create a NUL-terminated C string from a Rust `&str`.
fn cstr(s: &str) -> CString {
    CString::new(s).expect("test string must not contain NUL bytes")
}

/// Open the tiny fixture and return its raw handle + the working-copy change id.
///
/// The caller is responsible for closing the handle via `zanshin_repo_close`.
unsafe fn open_fixture_and_get_wc_change_id() -> (u64, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path_cstr = cstr(fixture.path.to_str().expect("fixture path must be valid UTF-8"));

    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    // Obtain the working-copy change id via zanshin_status so we don't hard-code a fixture id.
    let status_token = unsafe { zanshin_status(handle) };
    let status_bytes = unsafe { read_and_free(status_token) };
    let status_env = parse_envelope(&status_bytes);
    assert!(status_env.ok(), "status must succeed");
    let wc_change_id = status_env
        .data_as_status()
        .expect("data_as_status must succeed")
        .working_copy_change_id()
        .expect("working_copy_change_id must be present")
        .to_owned();

    // The fixture handle is leaked into the caller — they must close it.
    // We keep `fixture` alive by leaking it (its TempDir lives for the test).
    std::mem::forget(fixture);

    (handle, wc_change_id)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// Valid round-trip: open the tiny fixture, obtain a real change id from
/// `zanshin_status`, call `zanshin_change`, and assert a fully-formed
/// `Change` envelope. Then close the handle.
#[test]
fn change_valid_round_trip_returns_ok_change_envelope() {
    test_helpers::pin_test_env();

    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    let change_cstr = cstr(&wc_change_id);
    let change_token = unsafe { zanshin_change(handle, change_cstr.as_ptr()) };
    let change_bytes = unsafe { read_and_free(change_token) };
    let change_env = parse_envelope(&change_bytes);

    assert!(change_env.ok(), "zanshin_change must succeed for a valid id");
    assert_eq!(change_env.data_type(), fbs::Payload::Change, "data_type must be Change");

    let payload = change_env
        .data_as_change()
        .expect("data_as_change must succeed for Payload::Change");

    // The returned change id must match what we requested.
    assert_eq!(
        payload.id(),
        Some(wc_change_id.as_str()),
        "returned id must match the requested change id"
    );
    // Parents must be present (the WC has at least the root as parent).
    assert!(
        payload.parents().is_some(),
        "parents must be present in the Change payload"
    );
    // Description is always present (may be empty string).
    assert!(payload.description().is_some(), "description must be present");
    // Author and committer must be present.
    assert!(payload.author().is_some(), "author must be present");
    assert!(payload.committer().is_some(), "committer must be present");

    // Value-check the scalar fields on the real get_change → wire path (the tiny-fixture
    // WC commit is conflict-free, non-divergent, and unsigned). is_anonymous is left
    // unasserted: the tiny fixture's WC description is not guaranteed empty.
    assert_eq!(
        payload.conflict(),
        fbs::ConflictState::Clean,
        "fresh WC commit must be conflict-free on the wire"
    );
    assert!(!payload.divergent(), "fresh WC commit must not be divergent");
    assert!(!payload.is_signed(), "fixture commit is unsigned");

    // Close the handle.
    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    let close_env = parse_envelope(&close_bytes);
    assert!(close_env.ok(), "repo close must succeed");
}

/// Non-existent change id → `ok:false`, `error.code == "jj.change_not_found"`,
/// `context` contains the passed id.
#[test]
fn change_not_found_id_returns_jj_change_not_found() {
    test_helpers::pin_test_env();

    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let bad_id = "nonexistentchangeid";
    let bad_cstr = cstr(bad_id);
    let token = unsafe { zanshin_change(handle, bad_cstr.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "non-existent id must produce an error envelope");
    assert_eq!(
        env.error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "error.code must be jj.change_not_found"
    );
    assert_eq!(
        env.error().and_then(|e| e.context()),
        Some(bad_id),
        "context must contain the passed id"
    );

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");
}

/// Null `change_id` pointer → `ok:false`, `error.code == "ffi.null_pointer"`.
#[test]
fn change_null_change_id_returns_ffi_null_pointer() {
    test_helpers::pin_test_env();

    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let token = unsafe { zanshin_change(handle, std::ptr::null()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "null change_id must produce an error envelope");
    assert_eq!(
        env.error().and_then(|e| e.code()),
        Some(FFI_NULL_POINTER),
        "error.code must be ffi.null_pointer"
    );

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");
}

/// Invalid-UTF-8 `change_id` → `ok:false`, `error.code == "ffi.utf8_error"`.
///
/// The null-pointer arm of `cstr_to_string` is covered above; this pins the
/// other arm for `zanshin_change` specifically (cover ALL public error variants).
#[test]
fn change_invalid_utf8_change_id_returns_ffi_utf8_error() {
    test_helpers::pin_test_env();

    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    // A lone 0x80 continuation byte is not valid UTF-8 (mirrors tests/it/repo_ffi.rs).
    let bad_utf8 = CString::new(vec![0x66u8, 0x80, 0x6f]).expect("no interior NUL");
    let token = unsafe { zanshin_change(handle, bad_utf8.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "invalid-UTF-8 change_id must produce an error envelope");
    assert_eq!(
        env.error().and_then(|e| e.code()),
        Some(FFI_UTF8_ERROR),
        "error.code must be ffi.utf8_error"
    );

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");
}

/// Handle `0` → `ok:false`, `error.code == "ffi.invalid_handle"` — never a crash.
#[test]
fn change_zero_handle_returns_ffi_invalid_handle() {
    test_helpers::pin_test_env();

    let id_cstr = cstr("qpvuntsm");
    let token = unsafe { zanshin_change(0, id_cstr.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "handle == 0 must produce an error envelope");
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
