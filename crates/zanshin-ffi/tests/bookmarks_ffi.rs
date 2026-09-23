// SPDX-License-Identifier: MIT

//! Integration tests for `zanshin_bookmarks` FFI wrapper (Story 3.4b).
//!
//! Every buffer is read via the `FlatBuffers` generated typed accessors and the
//! Verifier. Every token is freed via `zanshin_buffer_free_token` — leak-clean.
//!
//! Tests:
//! - `bookmarks_tiny_returns_empty_list` — ok + Bookmarks payload, empty
//! - `bookmarks_medium_returns_29_local_entries` — 29 entries, all Local, names sorted
//! - `bookmarks_invalid_handle_returns_ffi_error` — handle 0 → `ffi.invalid_handle`
//!
//! No null/utf8 tests: `zanshin_bookmarks` is handle-only (no `CString` arg), so
//! there is no null-pointer or UTF-8-decoding failure path — a deliberate
//! asymmetry vs. `change_ffi.rs` (which carries a lone-string `change_id`).

use std::env;
use std::ffi::CString;
use std::sync::LazyLock;

use flatbuffers::root as fb_root;
use test_helpers::extract_fixture;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    bookmarks::zanshin_bookmarks,
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

// ── Tests ─────────────────────────────────────────────────────────────────────

/// `tiny-3-commits` has no bookmarks → ok + Bookmarks payload, empty list.
#[test]
fn bookmarks_tiny_returns_empty_list() {
    pin_env();

    let fx = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path_cstr = cstr(fx.path.to_str().expect("fixture path must be valid UTF-8"));

    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    let bm_token = unsafe { zanshin_bookmarks(handle) };
    let bm_bytes = unsafe { read_and_free(bm_token) };
    let bm_env = parse_envelope(&bm_bytes);

    assert!(
        bm_env.ok(),
        "zanshin_bookmarks must succeed; error={:?}",
        bm_env.error()
    );
    assert_eq!(
        bm_env.data_type(),
        fbs::Payload::Bookmarks,
        "data_type must be Bookmarks"
    );

    let payload = bm_env.data_as_bookmarks().expect("data_as_bookmarks must succeed");
    let count = payload.bookmarks().map_or(0, |b| b.len());
    assert_eq!(count, 0, "tiny fixture must have 0 bookmarks, got {count}");

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    let close_env = parse_envelope(&close_bytes);
    assert!(close_env.ok(), "repo close must succeed");
}

/// `medium-1k-commits` has exactly 29 local bookmarks.
/// All entries must be `BookmarkKind::Local`, names sorted ascending.
#[test]
fn bookmarks_medium_returns_29_local_entries() {
    pin_env();

    let fx = extract_fixture("medium-1k-commits").expect("fixture must extract");
    let path_cstr = cstr(fx.path.to_str().expect("fixture path must be valid UTF-8"));

    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    let bm_token = unsafe { zanshin_bookmarks(handle) };
    let bm_bytes = unsafe { read_and_free(bm_token) };
    let bm_env = parse_envelope(&bm_bytes);

    assert!(
        bm_env.ok(),
        "zanshin_bookmarks must succeed; error={:?}",
        bm_env.error()
    );
    assert_eq!(bm_env.data_type(), fbs::Payload::Bookmarks);

    let payload = bm_env.data_as_bookmarks().expect("data_as_bookmarks must succeed");
    let bms = payload.bookmarks().expect("bookmarks list must be present");

    assert_eq!(
        bms.len(),
        29,
        "medium fixture must have exactly 29 bookmarks, got {}",
        bms.len()
    );

    // All entries must be Local (medium fixture has no remote bookmarks).
    for i in 0..bms.len() {
        let bm = bms.get(i);
        assert_eq!(
            bm.kind(),
            fbs::BookmarkKind::Local,
            "bookmark[{i}] '{}' must be Local",
            bm.name().unwrap_or("<none>")
        );
    }

    // Names must be sorted ascending (secondary sort by kind is trivially satisfied
    // for Local-only lists).
    for i in 1..bms.len() {
        let prev = bms.get(i - 1).name().unwrap_or("");
        let curr = bms.get(i).name().unwrap_or("");
        let prev_idx = i - 1;
        assert!(
            prev <= curr,
            "bookmarks must be sorted by name: [{prev_idx}] '{prev}' > [{i}] '{curr}'"
        );
    }

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    let close_env = parse_envelope(&close_bytes);
    assert!(close_env.ok(), "repo close must succeed");
}

/// Handle `0` is never valid → `ffi.invalid_handle` error envelope.
#[test]
fn bookmarks_invalid_handle_returns_ffi_error() {
    pin_env();

    let token = unsafe { zanshin_bookmarks(0) };
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
