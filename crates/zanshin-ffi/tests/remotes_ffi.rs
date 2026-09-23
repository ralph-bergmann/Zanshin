// SPDX-License-Identifier: MIT

//! Integration tests for `zanshin_remotes` FFI wrapper (Story 3.4b, remotes slice).
//!
//! Every buffer is read via the `FlatBuffers` generated typed accessors and the
//! Verifier. Every token is freed via `zanshin_buffer_free_token` — leak-clean.
//!
//! Tests:
//! - `remotes_tiny_returns_empty_list` — ok + Remotes payload, empty
//! - `remotes_medium_returns_empty_list` — ok + Remotes payload, empty
//! - `remotes_invalid_handle_returns_ffi_error` — handle 0 → `ffi.invalid_handle`
//!
//! No null/utf8 tests: `zanshin_remotes` is handle-only (no `CString` arg), so
//! there is no null-pointer or UTF-8-decoding failure path — a deliberate
//! asymmetry vs. `change_ffi.rs` (which carries a lone-string `change_id`).
//!
//! Note: the committed fixtures (tiny-3-commits, medium-1k-commits) have ZERO
//! configured remotes. Populated remotes are exercised piecewise: the zanshin-jj
//! integration test (tests/remotes.rs) + the `remotes_to_envelope` unit test +
//! the Dart synthetic decode-contract test.

use std::env;
use std::ffi::CString;
use std::sync::LazyLock;

use flatbuffers::root as fb_root;
use test_helpers::extract_fixture;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    remotes::zanshin_remotes,
    repo::{zanshin_repo_close, zanshin_repo_open},
    FFI_INVALID_HANDLE,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
    env::set_var("JJ_USER", "Zanshin");
    env::set_var("JJ_EMAIL", "zanshin@localhost");
    env::set_var("JJ_OP_HOSTNAME", "localhost");
    env::set_var("JJ_OP_USERNAME", "zanshin");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by a `zanshin_*`
/// function and not yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    // SAFETY: token is valid; freed exactly once here after the copy above.
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// Parse bytes into a verified `fbs::Envelope`.
fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("test string must not contain NUL bytes")
}

/// Open a fixture repo and return its raw handle (u64). Caller must close.
unsafe fn open_fixture(name: &str) -> (u64, test_helpers::FixtureHandle) {
    let fx = extract_fixture(name).expect("fixture must extract");
    let path_cstr = cstr(fx.path.to_str().expect("fixture path must be valid UTF-8"));
    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed for fixture '{name}'");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();
    (handle, fx)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// `tiny-3-commits` has no configured remotes → ok + Remotes payload, empty list.
#[test]
fn remotes_tiny_returns_empty_list() {
    pin_env();

    let (handle, _fx) = unsafe { open_fixture("tiny-3-commits") };

    let token = unsafe { zanshin_remotes(handle) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "zanshin_remotes must succeed; error={:?}", env.error());
    assert_eq!(env.data_type(), fbs::Payload::Remotes, "data_type must be Remotes");

    let payload = env.data_as_remotes().expect("data_as_remotes must succeed");
    let count = payload.remotes().map_or(0, |r| r.len());
    assert_eq!(count, 0, "tiny fixture must have 0 remotes, got {count}");

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");
}

/// `medium-1k-commits` has no configured remotes either → ok + empty Remotes payload.
#[test]
fn remotes_medium_returns_empty_list() {
    pin_env();

    let (handle, _fx) = unsafe { open_fixture("medium-1k-commits") };

    let token = unsafe { zanshin_remotes(handle) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "zanshin_remotes must succeed; error={:?}", env.error());
    assert_eq!(env.data_type(), fbs::Payload::Remotes);

    let payload = env.data_as_remotes().expect("data_as_remotes must succeed");
    let count = payload.remotes().map_or(0, |r| r.len());
    assert_eq!(count, 0, "medium fixture must have 0 remotes, got {count}");

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");
}

/// Handle `0` is never valid → `ffi.invalid_handle` error envelope.
#[test]
fn remotes_invalid_handle_returns_ffi_error() {
    pin_env();

    let token = unsafe { zanshin_remotes(0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "handle 0 must return an error envelope");
    let err = env.error().expect("error field must be present");
    assert_eq!(
        err.code(),
        Some(FFI_INVALID_HANDLE),
        "error code must be ffi.invalid_handle, got {:?}",
        err.code()
    );
    // The borrow routes through `envelope::session_from_handle`, whose refusal
    // carries no context — pinned so a wrapper cannot start decorating it.
    assert!(
        err.context().is_none(),
        "the invalid-handle envelope carries no context"
    );
}
