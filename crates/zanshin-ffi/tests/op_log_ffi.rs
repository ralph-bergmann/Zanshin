// SPDX-License-Identifier: MIT

//! Integration tests for `zanshin_op_log` FFI wrapper (Story 3.4b, `op_log` slice).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the
//! Verifier. Every token is freed via `zanshin_buffer_free_token` so the suite is
//! leak-clean.
//!
//! No null-pointer or UTF-8 tests — `zanshin_op_log` has no `CString` arg; this
//! asymmetry vs. `change` is deliberate.

use std::env;
use std::ffi::CString;
use std::sync::LazyLock;

use flatbuffers::root as fb_root;
use test_helpers::extract_fixture;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    op_log::zanshin_op_log,
    repo::{zanshin_repo_close, zanshin_repo_open},
    FFI_INVALID_HANDLE,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
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

/// Valid round-trip: open tiny fixture, call `zanshin_op_log(-1)` (all ops),
/// assert ok + `OpLog` payload + at least 1 op + last op is root + close.
#[test]
fn op_log_valid_round_trip_returns_ok_oplog() {
    pin_env();

    // Keep `fixture` alive for the duration — its TempDir owns the repo on disk.
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

    let token = unsafe { zanshin_op_log(handle, -1) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "zanshin_op_log must succeed");
    assert_eq!(env.data_type(), fbs::Payload::OpLog, "data_type must be OpLog");

    let payload = env.data_as_op_log().expect("data_as_op_log must succeed");
    let ops = payload.operations().expect("operations must be present");

    assert!(!ops.is_empty(), "op log must be non-empty");

    // Last element must be the root op.
    let root = ops.get(ops.len() - 1);
    assert!(root.root_op(), "last op must have root_op == true");
    let root_pids: Vec<_> = root.parent_ids().map(|v| v.iter().collect()).unwrap_or_default();
    assert!(root_pids.is_empty(), "root op parent_ids must be empty");

    // Head op (first) must not be the root.
    let head = ops.get(0);
    assert!(!head.root_op(), "head op must not be the root");

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");

    drop(fixture); // explicit: keep fixture alive until after all FFI calls
}

/// Limit round-trip: `zanshin_op_log(handle, 1)` returns exactly 1 operation.
#[test]
fn op_log_limit_one_returns_exactly_one_op() {
    pin_env();

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

    let token = unsafe { zanshin_op_log(handle, 1) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "zanshin_op_log with limit 1 must succeed");
    let payload = env.data_as_op_log().expect("data_as_op_log must succeed");
    let ops = payload.operations().expect("operations must be present");
    assert_eq!(ops.len(), 1, "limit 1 must return exactly one op");

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");

    drop(fixture);
}

/// Invalid handle: `zanshin_op_log(0, -1)` must return `ffi.invalid_handle`.
#[test]
fn op_log_zero_handle_returns_ffi_invalid_handle() {
    pin_env();

    let token = unsafe { zanshin_op_log(0, -1) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "zanshin_op_log(0) must be an error");
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

/// `i64::MAX` limit maps to `Some(huge)` via `usize::try_from(limit).ok()` and must
/// return the same op count as `-1` (all) — exercising the upper bound of the scalar.
#[test]
fn op_log_i64_max_limit_equals_all() {
    pin_env();

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

    let all_token = unsafe { zanshin_op_log(handle, -1) };
    let all_bytes = unsafe { read_and_free(all_token) };
    let all_env = parse_envelope(&all_bytes);
    let all_len = all_env
        .data_as_op_log()
        .expect("data_as_op_log must succeed")
        .operations()
        .map_or(0, |o| o.len());

    let max_token = unsafe { zanshin_op_log(handle, i64::MAX) };
    let max_bytes = unsafe { read_and_free(max_token) };
    let max_env = parse_envelope(&max_bytes);
    assert!(max_env.ok(), "i64::MAX limit must succeed");
    let max_len = max_env
        .data_as_op_log()
        .expect("data_as_op_log must succeed")
        .operations()
        .map_or(0, |o| o.len());

    assert_eq!(
        max_len, all_len,
        "i64::MAX limit must return the same op count as -1 (all)"
    );

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");

    drop(fixture);
}
