// SPDX-License-Identifier: MIT

//! Integration tests for the `zanshin_graph_slice` FFI wrapper (Story 4.6).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the
//! Verifier — a wrong-shape payload is a compile error, not a runtime assert. The rows
//! are mapped back to `zanshin_graph::Row` and compared against a `collect_lanes` oracle
//! on a `zanshin_jj::Repo::open` of the same fixture. Every token is freed via
//! `zanshin_buffer_free_token` and every handle is closed, so the suite is leak-clean.

use std::collections::BTreeSet;
use std::env;
use std::ffi::CString;
use std::sync::LazyLock;

use flatbuffers::root as fb_root;
use test_helpers::{add_commit_off_root, describe_commit, extract_fixture, FixtureHandle};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    graph::zanshin_graph_slice,
    repo::{zanshin_repo_close, zanshin_repo_open},
    FFI_INVALID_HANDLE, FFI_NULL_POINTER, FFI_UTF8_ERROR, JJ_CONFIG_ERROR, JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR,
    JJ_REVSET_RESOLUTION_ERROR,
};
use zanshin_graph::{collect_lanes, ActiveLane, EdgeKind, Row, RowEdge};
use zanshin_jj::{CommitMeta, CommitRef, Repo, Timestamp, DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET};

/// The CLI's `revsets.short-prefixes` default (it falls back to `revsets.log`).
const SHORT: &str = DEFAULT_LOG_REVSET;

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: mirrors tests/change_ffi.rs — empty string makes jj-lib find no
    // config at that path; GIT_CONFIG_GLOBAL="" isolates the gix git backend.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
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

/// Call `zanshin_graph_slice` with the CLI-default `short_prefixes` and elided rows OFF —
/// the pre-4.8 stream shape the topology round-trips below compare against.
unsafe fn slice_bytes(handle: u64, revset: &str, prioritize: &str) -> Vec<u8> {
    unsafe { slice_bytes_with(handle, revset, prioritize, false, SHORT) }
}

/// Call `zanshin_graph_slice` with every parameter explicit; return the envelope bytes.
unsafe fn slice_bytes_with(
    handle: u64,
    revset: &str,
    prioritize: &str,
    synthetic_elided: bool,
    short_prefixes: &str,
) -> Vec<u8> {
    let revset_cstr = cstr(revset);
    let prio_cstr = cstr(prioritize);
    let short_cstr = cstr(short_prefixes);
    let token = unsafe {
        zanshin_graph_slice(
            handle,
            revset_cstr.as_ptr(),
            prio_cstr.as_ptr(),
            synthetic_elided,
            short_cstr.as_ptr(),
        )
    };
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

/// Map one wire `GraphCommitRef` back to the domain type.
fn ref_from_wire(r: fbs::GraphCommitRef<'_>) -> CommitRef {
    CommitRef {
        name: r.name().expect("name must be present").to_owned(),
        remote: r.remote().map(ToOwned::to_owned),
        synced: r.synced(),
        conflicted: r.conflicted(),
    }
}

/// Map one wire `GraphRowMeta` back to the domain type (`has_change_offset` restores the
/// `Option`).
fn meta_from_wire(m: fbs::GraphRowMeta<'_>) -> CommitMeta {
    CommitMeta {
        change_id: m.change_id().expect("change_id must be present").to_owned(),
        change_id_prefix_len: m.change_id_prefix_len(),
        commit_id_prefix_len: m.commit_id_prefix_len(),
        change_offset: m.has_change_offset().then(|| m.change_offset()),
        author_name: m.author_name().expect("author_name must be present").to_owned(),
        author_email: m.author_email().expect("author_email must be present").to_owned(),
        committer_timestamp: Timestamp {
            millis_since_epoch: m.committer_timestamp_millis(),
            tz_offset_minutes: m.committer_tz_offset_minutes(),
        },
        bookmarks: m
            .bookmarks()
            .expect("bookmarks must be present")
            .iter()
            .map(ref_from_wire)
            .collect(),
        tags: m
            .tags()
            .expect("tags must be present")
            .iter()
            .map(ref_from_wire)
            .collect(),
        working_copies: m
            .working_copies()
            .expect("working_copies must be present")
            .iter()
            .map(ToOwned::to_owned)
            .collect(),
        working_copy: m.working_copy(),
        immutable: m.immutable(),
        conflict: m.conflict(),
        empty: m.empty(),
        hidden: m.hidden(),
        divergent: m.divergent(),
        root: m.root(),
        description_first_line: m
            .description_first_line()
            .expect("description_first_line must be present")
            .to_owned(),
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
            synthetic_elided: r.synthetic_elided(),
            active_lanes: r
                .active_lanes()
                .expect("active_lanes must be present")
                .iter()
                .map(|l| ActiveLane {
                    lane: l.lane(),
                    kind: kind_from_wire(l.kind()),
                })
                .collect(),
            meta: r.meta().map(meta_from_wire),
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
    let mut repo = Repo::open(&fixture.path).expect("oracle repo must open");
    collect_lanes(&mut repo, revset, prioritize, SHORT, false).expect("oracle collect_lanes must succeed")
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
    let short = cstr(SHORT);
    let token = unsafe { zanshin_graph_slice(handle, std::ptr::null(), prio.as_ptr(), true, short.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    assert_error(&bytes, FFI_NULL_POINTER);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_null_prioritize_returns_ffi_null_pointer() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let revset = cstr("all()");
    let short = cstr(SHORT);
    let token = unsafe { zanshin_graph_slice(handle, revset.as_ptr(), std::ptr::null(), true, short.as_ptr()) };
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
    let short = cstr(SHORT);
    let token = unsafe { zanshin_graph_slice(handle, bad_utf8.as_ptr(), prio.as_ptr(), true, short.as_ptr()) };
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
    let short = cstr(SHORT);
    let token = unsafe { zanshin_graph_slice(handle, revset.as_ptr(), bad_utf8.as_ptr(), true, short.as_ptr()) };
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
    // Not folded into `assert_error`: most codes it serves DO carry a context.
    // The borrow routes through `envelope::session_from_handle`, whose refusal
    // does not — pinned so this wrapper cannot start decorating it.
    assert!(
        parse_envelope(&bytes).error().and_then(|e| e.context()).is_none(),
        "the invalid-handle envelope carries no context"
    );
}

// ── Story 4.8: metadata, active lanes, elided rows across the wire ───────────

#[test]
fn graph_slice_carries_the_metadata_of_the_same_snapshot_and_matches_get_change() {
    pin_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let bytes = unsafe { slice_bytes_with(handle, "all()", DEFAULT_GRAPH_PRIORITIZE, true, SHORT) };
    let (rows, _) = ok_rows(&bytes);

    // The oracle reads the same repo through the typed API — one snapshot, same answers.
    let mut repo = Repo::open(&fx.path).expect("oracle repo must open");
    for row in &rows {
        let meta = row.meta.as_ref().expect("every commit row carries metadata");
        let change = repo
            .get_change(&zanshin_jj::ChangeId(meta.change_id.clone()))
            .expect("the change id the row reports must resolve");
        assert_eq!(change.commit_id.0, row.commit_id, "id pair agrees with get_change");
        assert_eq!(meta.author_email, change.author.email);
        assert_eq!(meta.committer_timestamp, change.timestamps.committed_at);
        assert_eq!(
            meta.description_first_line,
            change.description.lines().next().unwrap_or_default()
        );
        assert!(meta.commit_id_prefix_len >= 1);
        assert!(usize::try_from(meta.commit_id_prefix_len).unwrap() <= row.commit_id.len());
    }
    assert_eq!(rows.iter().filter(|r| r.meta.as_ref().unwrap().root).count(), 1);
    assert_eq!(rows.iter().filter(|r| r.meta.as_ref().unwrap().working_copy).count(), 1);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_accepts_the_cli_default_log_revset_and_its_short_prefixes() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    // Both expressions only parse because the CLI's builtin aliases are defined (CAP-4).
    let bytes = unsafe { slice_bytes_with(handle, DEFAULT_LOG_REVSET, DEFAULT_GRAPH_PRIORITIZE, true, SHORT) };
    let (rows, total) = ok_rows(&bytes);

    assert!(!rows.is_empty(), "the CLI default log revset selects rows");
    assert_eq!(usize::try_from(total).ok(), Some(rows.len()));

    unsafe { close(handle) };
}

#[test]
fn graph_slice_empty_short_prefixes_disables_disambiguation_instead_of_erroring() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("medium-1k-commits") };

    // "" = disabled (full-index lengths), NOT a parse error like a blank prioritize.
    let disabled = unsafe { slice_bytes_with(handle, "all()", DEFAULT_GRAPH_PRIORITIZE, false, "") };
    let narrow = unsafe { slice_bytes_with(handle, "all()", DEFAULT_GRAPH_PRIORITIZE, false, "@") };
    let (disabled_rows, _) = ok_rows(&disabled);
    let (narrow_rows, _) = ok_rows(&narrow);

    assert_eq!(disabled_rows.len(), narrow_rows.len());
    assert!(
        disabled_rows
            .iter()
            .zip(&narrow_rows)
            .all(|(off, on)| off.meta.as_ref().unwrap().commit_id_prefix_len
                >= on.meta.as_ref().unwrap().commit_id_prefix_len),
        "the full index can never give a SHORTER prefix than a narrowed set"
    );

    unsafe { close(handle) };
}

#[test]
fn graph_slice_bogus_short_prefixes_returns_jj_revset_parse_error() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let bytes = unsafe { slice_bytes_with(handle, "all()", DEFAULT_GRAPH_PRIORITIZE, true, "bogus_function()") };
    assert_error_with_context(&bytes, JJ_REVSET_PARSE_ERROR);

    unsafe { close(handle) };
}

/// An unresolvable `short_prefixes` is NOT an error at the FFI surface either: symbol
/// resolution happens while loading the disambiguation index, which the CLI degrades with a
/// warning (jj `cli/tests/test_log_command.rs::test_log_bad_short_prefixes` @ v0.42.0).
#[test]
fn graph_slice_unknown_bookmark_short_prefixes_degrades_to_full_index_prefixes() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let degraded_bytes = unsafe {
        slice_bytes_with(
            handle,
            "all()",
            DEFAULT_GRAPH_PRIORITIZE,
            true,
            "nonexistent-bookmark-xyz",
        )
    };
    let disabled_bytes = unsafe { slice_bytes_with(handle, "all()", DEFAULT_GRAPH_PRIORITIZE, true, "") };
    let (degraded, total) = ok_rows(&degraded_bytes);
    let (disabled, _) = ok_rows(&disabled_bytes);

    assert_eq!(degraded.len(), 5, "the call succeeds with the full row set");
    assert_eq!(usize::try_from(total).ok(), Some(degraded.len()));
    assert_eq!(
        degraded, disabled,
        "degrading falls back to exactly the full-index prefix lengths"
    );

    unsafe { close(handle) };
}

#[test]
fn graph_slice_null_short_prefixes_returns_ffi_null_pointer() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let revset = cstr("all()");
    let prio = cstr(DEFAULT_GRAPH_PRIORITIZE);
    let token = unsafe { zanshin_graph_slice(handle, revset.as_ptr(), prio.as_ptr(), true, std::ptr::null()) };
    let bytes = unsafe { read_and_free(token) };
    assert_error(&bytes, FFI_NULL_POINTER);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_invalid_utf8_short_prefixes_returns_ffi_utf8_error() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let revset = cstr("all()");
    let prio = cstr(DEFAULT_GRAPH_PRIORITIZE);
    let bad_utf8 = CString::new(vec![0x61u8, 0x80, 0x6c]).expect("no interior NUL");
    let token = unsafe { zanshin_graph_slice(handle, revset.as_ptr(), prio.as_ptr(), true, bad_utf8.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    assert_error(&bytes, FFI_UTF8_ERROR);

    unsafe { close(handle) };
}

#[test]
fn graph_slice_synthetic_elided_toggle_adds_rows_and_off_keeps_plain_indirect_edges() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    let eliding = "all() ~ description(\"Commit 2\")";

    let off_bytes = unsafe { slice_bytes_with(handle, eliding, DEFAULT_GRAPH_PRIORITIZE, false, SHORT) };
    let on_bytes = unsafe { slice_bytes_with(handle, eliding, DEFAULT_GRAPH_PRIORITIZE, true, SHORT) };
    let (off, off_total) = ok_rows(&off_bytes);
    let (on, on_total) = ok_rows(&on_bytes);

    assert_eq!(off.len(), 4);
    assert_eq!(usize::try_from(off_total).ok(), Some(off.len()));
    assert!(off.iter().any(|r| r.edges.iter().any(|e| e.kind == EdgeKind::Indirect)));
    assert!(
        off.iter().all(|r| !r.synthetic_elided && r.meta.is_some()),
        "toggle off = the pre-4.8 TOPOLOGY (plain Indirect edges, no synthetic rows); the row \
         STRUCT still grew active_lanes/synthetic_elided/meta, so this is not byte-identity"
    );

    assert_eq!(on.len(), 5, "one synthetic row is spliced in");
    assert_eq!(usize::try_from(on_total).ok(), Some(on.len()));
    let synthetic: Vec<&Row> = on.iter().filter(|r| r.synthetic_elided).collect();
    assert_eq!(synthetic.len(), 1);
    assert!(synthetic[0].meta.is_none(), "an elided row carries no metadata");
    assert_eq!(synthetic[0].edges.len(), 1);
    assert_eq!(synthetic[0].edges[0].kind, EdgeKind::Direct);
    assert!(
        on.iter().all(|r| r.edges.iter().all(|e| e.kind != EdgeKind::Indirect)),
        "with the toggle on no Indirect edge is left"
    );

    unsafe { close(handle) };
}

#[test]
fn graph_slice_medium_active_lanes_cross_every_row_their_edge_spans() {
    pin_env();
    let (_fx, handle) = unsafe { open_fixture("medium-1k-commits") };

    let bytes = unsafe { slice_bytes_with(handle, "all()", DEFAULT_GRAPH_PRIORITIZE, true, SHORT) };
    let (rows, _) = ok_rows(&bytes);

    // CAP-2 on the wire form, as a set EQUALITY: a row's active_lanes is exactly the set of
    // lanes carrying a routed edge across it — nothing missing, nothing spurious. (The
    // domain-side twin lives in crates/zanshin-graph/tests/common/mod.rs; test helpers are
    // duplicated per test crate by repo convention.)
    let mut crossing: Vec<BTreeSet<u32>> = vec![BTreeSet::new(); rows.len()];
    for (index, row) in rows.iter().enumerate() {
        for edge in &row.edges {
            let Some(lane) = edge.target_lane else { continue };
            let landing = landing_row(&rows, index, &edge.target);
            for crossed in &mut crossing[index + 1..landing] {
                crossed.insert(lane);
            }
        }
    }
    for (row, expected) in rows.iter().zip(&crossing) {
        assert!(
            !row.active_lanes.iter().any(|l| l.lane == row.lane),
            "a row never lists its own lane as a pass-through"
        );
        assert_eq!(
            row.active_lanes.iter().map(|l| l.lane).collect::<Vec<u32>>(),
            expected.iter().copied().collect::<Vec<u32>>(),
            "{}: active_lanes must equal the crossing set, ascending",
            row.commit_id
        );
    }
    assert!(rows.iter().any(|r| !r.active_lanes.is_empty()));

    unsafe { close(handle) };
}

/// Index of the row an edge from `child_index` to `target` lands on.
///
/// `commit_id` alone is ambiguous once synthetic elided rows are spliced (a synthetic row
/// carries its TARGET's id). The CLI's splice rule disambiguates it exactly: a synthetic row
/// sits IMMEDIATELY after the child that elided to it.
fn landing_row(rows: &[Row], child_index: usize, target: &str) -> usize {
    let next = child_index + 1;
    if rows
        .get(next)
        .is_some_and(|r| r.synthetic_elided && r.commit_id == target)
    {
        return next;
    }
    let Some(offset) = rows[next..]
        .iter()
        .position(|r| !r.synthetic_elided && r.commit_id == target)
    else {
        panic!("{} -> {target} never lands on a real row", rows[child_index].commit_id);
    };
    next + offset
}

#[test]
fn graph_slice_rederives_metadata_so_an_external_describe_appears_on_the_next_call() {
    pin_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let before_bytes = unsafe { slice_bytes_with(handle, "all()", "none()", true, SHORT) };
    let (before, _) = ok_rows(&before_bytes);
    let target = before
        .iter()
        .find(|r| r.meta.as_ref().unwrap().description_first_line == "Commit 3")
        .expect("the fixture has a 'Commit 3' row")
        .commit_id
        .clone();

    let rewritten = describe_commit(&fx.path, &target, "Rewritten externally");

    // Same handle — no reopen, no cache.
    let after_bytes = unsafe { slice_bytes_with(handle, "all()", "none()", true, SHORT) };
    let (after, _) = ok_rows(&after_bytes);
    let row = after
        .iter()
        .find(|r| r.commit_id == rewritten)
        .expect("the rewritten commit is in the second slice");
    assert_eq!(
        row.meta.as_ref().unwrap().description_first_line,
        "Rewritten externally"
    );

    unsafe { close(handle) };
}

// ── Story 4.9: the config layer reaches the FFI surface ──────────────────────

/// Writes `.jj/repo/config.toml` — the repo config layer of an extracted fixture, which
/// carries no `config-id`, so this legacy path IS the repo layer.
fn write_repo_config(workspace_root: &std::path::Path, toml: &str) {
    std::fs::write(workspace_root.join(".jj").join("repo").join("config.toml"), toml).unwrap();
}

/// A `[revset-aliases]` override in the repo config is visible through
/// `zanshin_graph_slice` on the SAME handle — which also re-proves that the config is
/// re-read per call and never cached.
#[test]
fn graph_slice_resolves_repo_config_aliases_on_the_same_handle() {
    pin_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    // Before the override, `wip()` is an unknown function.
    let before = unsafe { slice_bytes(handle, "wip()", "none()") };
    assert_error(&before, JJ_REVSET_PARSE_ERROR);

    write_repo_config(&fx.path, "[revset-aliases]\n'wip()' = 'description(\"Commit 2\")'\n");

    let after = unsafe { slice_bytes_with(handle, "wip()", "none()", true, SHORT) };
    let (rows, total) = ok_rows(&after);
    assert_eq!(total, 1, "wip() selects exactly one row");
    assert_eq!(
        rows[0]
            .meta
            .as_ref()
            .expect("commit rows carry meta")
            .description_first_line,
        "Commit 2"
    );

    unsafe { close(handle) };
}

/// A malformed repo config fails the call with `jj.config_error` and the file in
/// `context` — never a silent fall-back to the builtin alias layer.
#[test]
fn graph_slice_on_malformed_repo_config_returns_jj_config_error() {
    pin_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    write_repo_config(&fx.path, "not = = toml");

    let bytes = unsafe { slice_bytes(handle, "all()", DEFAULT_GRAPH_PRIORITIZE) };
    assert_error_with_context(&bytes, JJ_CONFIG_ERROR);
    assert!(
        parse_envelope(&bytes)
            .error()
            .and_then(|e| e.context())
            .is_some_and(|c| c.contains("config.toml")),
        "the context must name the offending file"
    );

    unsafe { close(handle) };
}
