// SPDX-License-Identifier: MIT

//! Integration tests for the `zanshin_log_defaults` FFI wrapper (Story 4.9).
//!
//! Every buffer is read via the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token` — leak-clean.
//!
//! `zanshin_log_defaults` is handle-only (no `CString` argument), so there is no
//! null-pointer or UTF-8 failure path — the same deliberate asymmetry as `remotes_ffi.rs`.
//!
//! Config overrides are written as the LEGACY repo-config file (`.jj/repo/config.toml`)
//! into an extracted fixture, so no test touches the process-global `JJ_CONFIG` (pinned
//! to `""` here, which disables user-config discovery).

use std::ffi::CString;
use std::path::Path;

use flatbuffers::root as fb_root;
use test_helpers::{extract_fixture, FixtureHandle};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    log_defaults::zanshin_log_defaults,
    repo::{zanshin_repo_close, zanshin_repo_open},
    FFI_INVALID_HANDLE, JJ_CONFIG_ERROR,
};
use zanshin_jj::{DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET};

// ── Env pin ───────────────────────────────────────────────────────────────────

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by a `zanshin_*` function and
/// not yet freed.
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

fn cstr(s: &str) -> CString {
    CString::new(s).expect("test string must not contain NUL bytes")
}

unsafe fn open_fixture(name: &str) -> (FixtureHandle, u64) {
    let fixture = extract_fixture(name).expect("fixture must extract");
    let path_cstr = cstr(fixture.path.to_str().expect("fixture path must be valid UTF-8"));
    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed for fixture '{name}'");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();
    (fixture, handle)
}

unsafe fn close(handle: u64) {
    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");
}

fn write_repo_config(workspace_root: &Path, toml: &str) {
    std::fs::write(workspace_root.join(".jj").join("repo").join("config.toml"), toml).unwrap();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// An extracted fixture carries no config, so the payload is the builtin default layer —
/// the same four values Story 4.8 ships as Rust/Dart constants.
#[test]
fn log_defaults_without_config_returns_the_builtin_values() {
    test_helpers::pin_test_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let token = unsafe { zanshin_log_defaults(handle) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "zanshin_log_defaults must succeed; error={:?}", env.error());
    assert_eq!(env.data_type(), fbs::Payload::LogDefaults);
    let payload = env.data_as_log_defaults().expect("data_as_log_defaults must succeed");
    assert_eq!(payload.log(), Some(DEFAULT_LOG_REVSET));
    assert_eq!(payload.log_graph_prioritize(), Some(DEFAULT_GRAPH_PRIORITIZE));
    assert_eq!(
        payload.short_prefixes(),
        Some(DEFAULT_LOG_REVSET),
        "unset revsets.short-prefixes falls back to revsets.log"
    );
    assert!(payload.synthetic_elided());

    unsafe { close(handle) };
}

/// Overrides reach the wire, and the second call on the SAME handle sees a config file
/// written after the first — config is re-read per call, never cached.
#[test]
fn log_defaults_reflects_a_repo_config_override_on_the_same_handle() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let first = unsafe { read_and_free(zanshin_log_defaults(handle)) };
    assert_eq!(
        parse_envelope(&first).data_as_log_defaults().expect("payload").log(),
        Some(DEFAULT_LOG_REVSET)
    );

    write_repo_config(
        &fx.path,
        "[revsets]\nlog = \"@\"\n\n[ui]\nlog-synthetic-elided-nodes = false\n",
    );

    let second = unsafe { read_and_free(zanshin_log_defaults(handle)) };
    let env = parse_envelope(&second);
    assert!(env.ok(), "error={:?}", env.error());
    let payload = env.data_as_log_defaults().expect("payload");
    assert_eq!(payload.log(), Some("@"));
    assert_eq!(payload.short_prefixes(), Some("@"), "the fallback follows the override");
    assert!(!payload.synthetic_elided());

    unsafe { close(handle) };
}

/// A malformed config file surfaces as `jj.config_error` with the file named — never a
/// silent fall-back to the builtin defaults.
#[test]
fn log_defaults_on_malformed_config_returns_jj_config_error() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    write_repo_config(&fx.path, "not = = toml");

    let bytes = unsafe { read_and_free(zanshin_log_defaults(handle)) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "a malformed config must return an error envelope");
    let err = env.error().expect("error field must be present");
    assert_eq!(err.code(), Some(JJ_CONFIG_ERROR));
    assert!(
        err.context().is_some_and(|c| c.contains("config.toml")),
        "the context must name the file, got {:?}",
        err.context()
    );

    unsafe { close(handle) };
}

/// Handle `0` is never valid → `ffi.invalid_handle`, empty `context`, no deref.
///
/// The post-`zanshin_repo_close` case is the worker's table lookup, not a Rust check (a
/// stale non-zero raw handle is UB by contract), so it is pinned Dart-side in
/// `packages/zanshin_core/test/worker/log_defaults_test.dart`.
#[test]
fn log_defaults_invalid_handle_returns_ffi_error() {
    test_helpers::pin_test_env();

    let bytes = unsafe { read_and_free(zanshin_log_defaults(0)) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "handle 0 must return an error envelope");
    let err = env.error().expect("error field must be present");
    assert_eq!(err.code(), Some(FFI_INVALID_HANDLE));
    assert!(
        err.context().is_none(),
        "the invalid-handle envelope carries no context"
    );
}
