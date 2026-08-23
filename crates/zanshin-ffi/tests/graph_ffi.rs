// SPDX-License-Identifier: MIT

//! Integration tests for the `zanshin_graph_slice` FFI wrapper (Story 4.6).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the
//! Verifier — a wrong-shape payload is a compile error, not a runtime assert. The rows
//! are mapped back to `zanshin_graph::Row` and compared against a `collect_lanes` oracle
//! on a `zanshin_jj::Repo::open` of the same fixture. Every token is freed via
//! `zanshin_buffer_free_token` and every handle is closed, so the suite is leak-clean.

use std::env;
use std::ffi::CString;
use std::sync::LazyLock;

use flatbuffers::root as fb_root;
use test_helpers::{add_commit_off_root, extract_fixture, FixtureHandle};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    graph::zanshin_graph_slice,
    repo::{zanshin_repo_close, zanshin_repo_open},
    FFI_INVALID_HANDLE, FFI_NULL_POINTER, FFI_UTF8_ERROR, JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR,
    JJ_REVSET_RESOLUTION_ERROR,
};
use zanshin_graph::{collect_lanes, EdgeKind, Row, RowEdge};
use zanshin_jj::{Repo, DEFAULT_GRAPH_PRIORITIZE};

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: mirrors tests/change_ffi.rs — empty string makes jj-lib find no
    // config at that path; GIT_CONFIG_GLOBAL="" isolates the gix git backend.
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

/// Extract `name` and open it through the FFI; returns the live fixture + raw handle.
///
/// The caller closes the handle via `zanshin_repo_close`; dropping the `FixtureHandle`
/// deletes the extracted repo.
unsafe fn open_fixture(name: &str) -> (FixtureHandle, u64) {
    let fixture = extract_fixture(name).expect("fixture must extract");
    let path_cstr = cstr(fixture.path.to_str().expect("fixture path must be valid UTF-8"));

    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
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

/// Call `zanshin_graph_slice` with both strings and return the envelope bytes.
unsafe fn slice_bytes(handle: u64, revset: &str, prioritize: &str) -> Vec<u8> {
    let revset_cstr = cstr(revset);
    let prio_cstr = cstr(prioritize);
    let token = unsafe { zanshin_graph_slice(handle, revset_cstr.as_ptr(), prio_cstr.as_ptr()) };
    unsafe { read_and_free(token) }
}

fn kind_from_wire(kind: fbs::GraphEdgeKind) -> EdgeKind {
    match kind {
        fbs::GraphEdgeKind::Direct => EdgeKind::Direct,
        fbs::GraphEdgeKind::Indirect => EdgeKind::Indirect,
        fbs::GraphEdgeKind::Missing => EdgeKind::Missing,
        other => panic!("unexpected wire GraphEdgeKind {other:?}"),
    }
}

/// Map the wire payload back to the 4.1 domain type (`Missing` ⇒ `target_lane: None`).
fn rows_from_wire(slice: fbs::GraphSlice<'_>) -> Vec<Row> {
    slice
        .rows()
        .expect("rows must be present")
        .iter()
        .map(|r| Row {
            commit_id: r.commit_id().expect("commit_id must be present").to_owned(),
            lane: r.lane(),
            color_idx: r.color_idx(),
            edges: r
                .edges()
                .expect("edges must be present")
                .iter()
                .map(|e| {
                    let kind = kind_from_wire(e.kind());
                    RowEdge {
                        target: e.target().expect("target must be present").to_owned(),
                        target_lane: (kind != EdgeKind::Missing).then_some(e.target_lane()),
                        kind,
                    }
                })
                .collect(),
        })
        .collect()
}

/// Assert an `ok` `GraphSlice` envelope and return its rows + `total_rows`.
fn ok_rows(bytes: &[u8]) -> (Vec<Row>, u32) {
    let env = parse_envelope(bytes);
    assert!(
        env.ok(),
        "zanshin_graph_slice must succeed, got {:?}",
        env.error().and_then(|e| e.code())
    );
    assert_eq!(
        env.data_type(),
        fbs::Payload::GraphSlice,
        "data_type must be GraphSlice"
    );
    let slice = env.data_as_graph_slice().expect("data_as_graph_slice must succeed");
    (rows_from_wire(slice), slice.total_rows())
}

/// Assert an error envelope with the given code and no payload at the union level.
fn assert_error(bytes: &[u8], code: &str) {
    let env = parse_envelope(bytes);
    assert!(!env.ok(), "must produce an error envelope (expected {code})");
    assert_eq!(
        env.error().and_then(|e| e.code()),
        Some(code),
        "error.code must be {code}"
    );
    assert_eq!(
        env.data_type(),
        fbs::Payload::NONE,
        "an error envelope never carries partial rows (data_type must be NONE)"
    );
    assert!(
        env.data_as_graph_slice().is_none(),
        "an error envelope must carry no rows"
    );
}

/// [`assert_error`] plus a non-empty `error.context` — the ABI doc promises the
/// jj-lib reason in `context` for `jj.revset_parse_error` / `jj.revset_resolution_error`.
fn assert_error_with_context(bytes: &[u8], code: &str) {
    assert_error(bytes, code);
    assert!(
        parse_envelope(bytes)
            .error()
            .and_then(|e| e.context())
            .is_some_and(|c| !c.is_empty()),
        "context must carry jj-lib's reason for {code}"
    );
}

/// The oracle: `collect_lanes` through `zanshin_jj::Repo::open` on the same fixture path.
fn oracle(fixture: &FixtureHandle, revset: &str, prioritize: &str) -> Vec<Row> {
    let repo = Repo::open(&fixture.path).expect("oracle repo must open");
    collect_lanes(&repo, revset, prioritize).expect("oracle collect_lanes must succeed")
}

// ── Round-trips against the collect_lanes oracle ──────────────────────────────

#[test]
fn graph_slice_tiny_all_with_default_prioritize_equals_collect_lanes_oracle() {
    pin_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let bytes = unsafe { slice_bytes(handle, "all()", DEFAULT_GRAPH_PRIORITIZE) };
    let (rows, total_rows) = ok_rows(&bytes);

    assert_eq!(rows.len(), 5, "tiny all() = @ + c3 + c2 + c1 + root");
    assert_eq!(total_rows, 5, "total_rows == rows.len() (return-all)");
    assert_eq!(
        rows,
        oracle(&fx, "all()", DEFAULT_GRAPH_PRIORITIZE),
        "wire rows must equal collect_lanes on the same repo/arguments"
    );
    assert_eq!(rows[0].lane, 0, "the prioritised working copy leads on lane 0");
    assert!(rows[4].edges.is_empty(), "the last row (root) has no edges");

    unsafe { close(handle) };
}

#[test]
fn graph_slice_tiny_none_prioritize_equals_oracle_and_changes_the_first_row() {
    pin_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let default_bytes = unsafe { slice_bytes(handle, "all()", DEFAULT_GRAPH_PRIORITIZE) };
    let (default_rows, _) = ok_rows(&default_bytes);
    let none_bytes = unsafe { slice_bytes(handle, "all()", "none()") };
    let (none_rows, total_rows) = ok_rows(&none_bytes);

    assert_eq!(none_rows.len(), 5);
    assert_eq!(total_rows, 5);
    assert_eq!(none_rows, oracle(&fx, "all()", "none()"));
    assert_ne!(
        none_rows[0].commit_id, default_rows[0].commit_id,
        "prioritize is passed through: none() no longer forces @ first"
    );

    unsafe { close(handle) };
}

#[test]
fn graph_slice_medium_all_equals_collect_lanes_oracle() {
    pin_env();
    let (fx, handle) = unsafe { open_fixture("medium-1k-commits") };

    let bytes = unsafe { slice_bytes(handle, "all()", DEFAULT_GRAPH_PRIORITIZE) };
    let (rows, total_rows) = ok_rows(&bytes);

    assert_eq!(rows.len(), 1002, "root + @ + 1000 fixture commits");
    assert_eq!(total_rows, 1002);
    assert_eq!(rows, oracle(&fx, "all()", DEFAULT_GRAPH_PRIORITIZE));

    unsafe { close(handle) };
}

#[test]
fn graph_slice_empty_revset_returns_present_empty_rows_and_zero_total() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let bytes = unsafe { slice_bytes(handle, "none()", DEFAULT_GRAPH_PRIORITIZE) };
    let env = parse_envelope(&bytes);
    assert!(env.ok());
    let slice = env.data_as_graph_slice().expect("GraphSlice payload");
    assert_eq!(slice.rows().map(|v| v.len()), Some(0), "rows must be present and empty");
    assert_eq!(slice.total_rows(), 0);

    unsafe { close(handle) };
}

// ── Re-derive per call (ADR-0002): same handle sees an external operation ───

#[test]
fn graph_slice_rederives_from_head_so_an_external_commit_appears_on_the_next_call() {
    pin_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let before_bytes = unsafe { slice_bytes(handle, "all()", DEFAULT_GRAPH_PRIORITIZE) };
    let (before, _) = ok_rows(&before_bytes);
    assert_eq!(before.len(), 5);

    let new_id = add_commit_off_root(&fx.path, "external op");

    // Same handle — no reopen, no cache.
    let after_bytes = unsafe { slice_bytes(handle, "all()", DEFAULT_GRAPH_PRIORITIZE) };
    let (after, total_rows) = ok_rows(&after_bytes);
    assert_eq!(after.len(), 6, "the external commit is a new row");
    assert_eq!(total_rows, 6);
    assert!(
        after.iter().any(|r| r.commit_id == new_id),
        "the new commit id is in the second slice"
    );
    assert!(
        before.iter().all(|r| r.commit_id != new_id),
        "it was not in the first slice"
    );

    unsafe { close(handle) };
}

// ── Errors: either parameter; no panic, no rows ─────────────────────────────

#[test]
fn graph_slice_bogus_revset_returns_jj_revset_parse_error() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let bytes = unsafe { slice_bytes(handle, "bogus_function()", DEFAULT_GRAPH_PRIORITIZE) };
    assert_error_with_context(&bytes, JJ_REVSET_PARSE_ERROR);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_bogus_prioritize_returns_jj_revset_parse_error() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let bytes = unsafe { slice_bytes(handle, "all()", "(") };
    assert_error_with_context(&bytes, JJ_REVSET_PARSE_ERROR);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_blank_prioritize_returns_jj_revset_parse_error() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    // `none()` is the canonical no-prioritization value; a blank expression is a parse error.
    let bytes = unsafe { slice_bytes(handle, "all()", "") };
    assert_error_with_context(&bytes, JJ_REVSET_PARSE_ERROR);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_unknown_bookmark_revset_returns_jj_revset_resolution_error() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let bytes = unsafe { slice_bytes(handle, "nonexistent-bookmark-xyz", DEFAULT_GRAPH_PRIORITIZE) };
    assert_error_with_context(&bytes, JJ_REVSET_RESOLUTION_ERROR);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_unknown_bookmark_prioritize_returns_jj_revset_resolution_error() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let bytes = unsafe { slice_bytes(handle, "all()", "nonexistent-bookmark-xyz") };
    assert_error_with_context(&bytes, JJ_REVSET_RESOLUTION_ERROR);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_null_revset_returns_ffi_null_pointer() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let prio = cstr(DEFAULT_GRAPH_PRIORITIZE);
    let token = unsafe { zanshin_graph_slice(handle, std::ptr::null(), prio.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    assert_error(&bytes, FFI_NULL_POINTER);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_null_prioritize_returns_ffi_null_pointer() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let revset = cstr("all()");
    let token = unsafe { zanshin_graph_slice(handle, revset.as_ptr(), std::ptr::null()) };
    let bytes = unsafe { read_and_free(token) };
    assert_error(&bytes, FFI_NULL_POINTER);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_invalid_utf8_revset_returns_ffi_utf8_error() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    // A lone 0x80 continuation byte is not valid UTF-8 (mirrors tests/change_ffi.rs).
    let bad_utf8 = CString::new(vec![0x61u8, 0x80, 0x6c]).expect("no interior NUL");
    let prio = cstr(DEFAULT_GRAPH_PRIORITIZE);
    let token = unsafe { zanshin_graph_slice(handle, bad_utf8.as_ptr(), prio.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    assert_error(&bytes, FFI_UTF8_ERROR);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_invalid_utf8_prioritize_returns_ffi_utf8_error() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let revset = cstr("all()");
    let bad_utf8 = CString::new(vec![0x61u8, 0x80, 0x6c]).expect("no interior NUL");
    let token = unsafe { zanshin_graph_slice(handle, revset.as_ptr(), bad_utf8.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    assert_error(&bytes, FFI_UTF8_ERROR);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_on_corrupt_op_heads_returns_jj_jj_lib_error() {
    pin_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    // Corrupt AFTER open, exactly as crates/zanshin-jj/tests/graph.rs does: the graph is
    // re-derived from head on every call (ADR-0002), so removing op_heads makes
    // load_at_head() fail → RevsetError::JjLibError → `jj.jj_lib_error` at the FFI surface.
    let op_heads = fx.path.join(".jj").join("repo").join("op_heads");
    std::fs::remove_dir_all(&op_heads).expect("op_heads must be removable");

    let bytes = unsafe { slice_bytes(handle, "all()", DEFAULT_GRAPH_PRIORITIZE) };
    assert_error(&bytes, JJ_JJ_LIB_ERROR);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_zero_handle_returns_ffi_invalid_handle() {
    pin_env();

    let bytes = unsafe { slice_bytes(0, "all()", DEFAULT_GRAPH_PRIORITIZE) };
    assert_error(&bytes, FFI_INVALID_HANDLE);
}
