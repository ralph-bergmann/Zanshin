// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.6's three commit-view wrappers (`zanshin_show`,
//! `zanshin_evolog`, `zanshin_interdiff`).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier —
//! a wrong-shape payload is a compile error, not a runtime assert. Every token is freed via
//! `zanshin_buffer_free_token` so the suite is leak-clean.
//!
//! Mirrors `tests/file_ffi.rs`'s scaffolding for the handle/envelope helpers and its
//! request-buffer builders. Each happy path asserts the verb's DISTINGUISHING data — the nested
//! `Change`, the predecessor edges, the per-path change list — not merely a well-formed
//! envelope, and every request field crosses the buffer at least once, so a reader that
//! hardcoded one would fail.

use std::ffi::CString;
use std::path::Path;
use std::sync::LazyLock;
use std::{env, fs};

use flatbuffers::root as fb_root;
use test_helpers::{
    add_commit_off_root, add_commit_with_files, describe_commit, extract_fixture, rewrite_commit_files,
};
use zanshin_ffi::commit_views::{zanshin_evolog, zanshin_interdiff, zanshin_show};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CHANGE_NOT_FOUND, JJ_INVALID_INPUT,
    JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
};
use zanshin_jj::{resolve_revset, Repo};

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: mirrors tests/file_ffi.rs — an empty string makes jj-lib find no config at that
    // path; GIT_CONFIG_GLOBAL="" isolates gix.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

// ── Envelope helpers ──────────────────────────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by one of the `zanshin_*` functions
/// and not yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// The shape all three commit-view wrappers share: `(handle, data, len) -> *mut ZanshinBuf`.
/// Naming it lets one table drive every verb, so a fourth view cannot skip the shared contract.
type Wrapper = unsafe extern "C" fn(u64, *const u8, usize) -> *mut ZanshinBuf;

fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("test string must not contain NUL bytes")
}

/// Open `path` and return its raw handle.
fn open_handle(path: &Path) -> u64 {
    let p = cstr(path.to_str().expect("fixture path must be UTF-8"));
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let token = unsafe { zanshin_repo_open(p.as_ptr()) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_open just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "expected ok, error: {:?}", env.error().and_then(|e| e.code()));
    env.data_as_repo_handle()
        .expect("RepoHandle payload must be present")
        .handle()
}

fn close_handle(handle: u64) {
    // SAFETY: handle originated from open_handle above and has not been closed.
    let token = unsafe { zanshin_repo_close(handle) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_close just returned.
    let bytes = unsafe { read_and_free(token) };
    assert!(parse_envelope(&bytes).ok(), "repo close must succeed");
}

/// The reverse-hex change id of `commit_hex`, via the crate's own revset resolver (a full
/// commit hex is a revset symbol) — no `jj_lib` import needed.
fn change_id_for_commit(path: &Path, commit_hex: &str) -> String {
    let repo = Repo::open(path).expect("fixture opens");
    let mut ids = resolve_revset(&repo, commit_hex).expect("a commit hex resolves as a revset symbol");
    assert_eq!(ids.len(), 1, "a commit hex denotes exactly one change");
    ids.swap_remove(0).0
}

// ── Request-buffer builders ───────────────────────────────────────────────────

/// A `ShowRequest` buffer with NO limit — the shape an older caller builds, and the one that
/// must read as "unbounded". A `None` revset is likewise left ABSENT: the wire form of "the user
/// did not supply it", which selects the CLI's `@` default.
fn show_request_bytes(revset: Option<&str>) -> Vec<u8> {
    show_request_bytes_with_limit(revset, None)
}

/// A `ShowRequest` buffer carrying the presence-flag pair, so `Some(0)` and `None` are DIFFERENT
/// requests — the reader must not collapse them.
fn show_request_bytes_with_limit(revset: Option<&str>, limit: Option<u32>) -> Vec<u8> {
    show_request_bytes_raw(revset, limit.unwrap_or(0), limit.is_some())
}

/// A `ShowRequest` buffer whose two limit fields are set INDEPENDENTLY, so a test can build the
/// one combination no honest caller produces: `has_limit == false` with a non-zero `limit`. That
/// is the case the schema's "0 / ignored when `has_limit` == false" comment exists for, and the
/// only way to prove the reader keys off the FLAG rather than off a zero sentinel.
fn show_request_bytes_raw(revset: Option<&str>, limit: u32, has_limit: bool) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let revset_off = revset.map(|s| b.create_string(s));
    let req = fbs::ShowRequest::create(
        &mut b,
        &fbs::ShowRequestArgs {
            kind: fbs::RequestKind::Show,
            revset: revset_off,
            limit,
            has_limit,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// An `EvologRequest` buffer. `limit` uses the schema's presence-flag pair, so `Some(0)` and
/// `None` are DIFFERENT requests — the reader must not collapse them.
fn evolog_request_bytes(revset: Option<&str>, limit: Option<u32>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let revset_off = revset.map(|s| b.create_string(s));
    let req = fbs::EvologRequest::create(
        &mut b,
        &fbs::EvologRequestArgs {
            kind: fbs::RequestKind::Evolog,
            revset: revset_off,
            limit: limit.unwrap_or(0),
            has_limit: limit.is_some(),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// One side of an `InterdiffRequest`, in the schema's `RevisionRef` union.
#[derive(Clone, Copy)]
enum Side<'a> {
    /// Neither vtable slot written — the ABSENT side, which the verb reads as `@`.
    Absent,
    /// A `ChangeIdRef`: the house reverse-hex change-id currency, visible commits only.
    Change(&'a str),
    /// A `CommitIdRef`: a commit-id hex prefix, resolved through the visibility-blind index.
    Commit(&'a str),
}

/// Write one union side: its discriminant plus the value table it selects.
fn build_side(
    b: &mut flatbuffers::FlatBufferBuilder<'_>,
    side: Side<'_>,
) -> (
    fbs::RevisionRef,
    Option<flatbuffers::WIPOffset<flatbuffers::UnionWIPOffset>>,
) {
    match side {
        Side::Absent => (fbs::RevisionRef::NONE, None),
        Side::Change(id) => {
            let id_off = b.create_string(id);
            let table = fbs::ChangeIdRef::create(b, &fbs::ChangeIdRefArgs { id: Some(id_off) });
            (fbs::RevisionRef::ChangeIdRef, Some(table.as_union_value()))
        }
        Side::Commit(id) => {
            let id_off = b.create_string(id);
            let table = fbs::CommitIdRef::create(b, &fbs::CommitIdRefArgs { id: Some(id_off) });
            (fbs::RevisionRef::CommitIdRef, Some(table.as_union_value()))
        }
    }
}

/// An `InterdiffRequest` buffer. BOTH revisions absent is a legal buffer that the verb itself
/// refuses (the CLI's `ArgGroup … required(true)`) — it is not a malformed request.
fn interdiff_request_bytes(from: Side<'_>, to: Side<'_>, paths: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let (from_type, from_off) = build_side(&mut b, from);
    let (to_type, to_off) = build_side(&mut b, to);
    let path_offs: Vec<_> = paths.iter().map(|s| b.create_string(s)).collect();
    let paths_vec = b.create_vector(&path_offs);
    let req = fbs::InterdiffRequest::create(
        &mut b,
        &fbs::InterdiffRequestArgs {
            kind: fbs::RequestKind::Interdiff,
            from_type,
            from: from_off,
            to_type,
            to: to_off,
            paths: Some(paths_vec),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// The three union shapes no honest builder produces, each isolating one rung.
#[derive(Clone, Copy)]
enum MalformedUnion {
    /// A `ChangeIdRef` value with the discriminant left at its default `NONE`. `FlatBuffers`
    /// never writes a default-valued scalar, so this is exactly the (value present,
    /// discriminant absent) pair `Verifier::visit_union` calls an INCONSISTENT union — refused
    /// at ladder rung 2, before the reader runs.
    ValueWithoutDiscriminant,
    /// A discriminant BYTE outside the union, with a value present. A union tag is
    /// range-checked no more than a plain enum is (the generated variant match ends in
    /// `_ => Ok(())`), so this verifies and the READER refuses it.
    OutOfRangeDiscriminant,
    /// A correctly tagged `ChangeIdRef` whose `id` field is ABSENT — the reader's own
    /// required-field guard, ladder rung 4.
    RefWithoutId,
}

/// Build an `InterdiffRequest` in which ONE side's union is written slot by slot.
///
/// `on_to` picks which side gets `shape`; the other is a valid `ChangeIdRef` carrying `good`, so
/// nothing but the malformed side can be the reason for a refusal. Both placements matter: the
/// reader lifts the two sides in sequence, so a `to` that never fails leaves its propagation arm
/// unexercised.
fn malformed_union_request_bytes(shape: MalformedUnion, on_to: bool, good: &str) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let bad = match shape {
        MalformedUnion::ValueWithoutDiscriminant => {
            let id_off = b.create_string("qpvuntsm");
            let table = fbs::ChangeIdRef::create(&mut b, &fbs::ChangeIdRefArgs { id: Some(id_off) });
            (fbs::RevisionRef::NONE, Some(table.as_union_value()))
        }
        MalformedUnion::OutOfRangeDiscriminant => {
            let id_off = b.create_string("qpvuntsm");
            let table = fbs::ChangeIdRef::create(&mut b, &fbs::ChangeIdRefArgs { id: Some(id_off) });
            (fbs::RevisionRef(200), Some(table.as_union_value()))
        }
        MalformedUnion::RefWithoutId => {
            let table = fbs::ChangeIdRef::create(&mut b, &fbs::ChangeIdRefArgs { id: None });
            (fbs::RevisionRef::ChangeIdRef, Some(table.as_union_value()))
        }
    };
    let ok = build_side(&mut b, Side::Change(good));
    let ((from_type, from_off), (to_type, to_off)) = if on_to { (ok, bad) } else { (bad, ok) };
    let req = fbs::InterdiffRequest::create(
        &mut b,
        &fbs::InterdiffRequestArgs {
            kind: fbs::RequestKind::Interdiff,
            from_type,
            from: from_off,
            to_type,
            to: to_off,
            paths: None,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

// ── Scenarios ─────────────────────────────────────────────────────────────────

/// A fixture with one purpose-built commit off root that adds `a.txt`.
///
/// The `FixtureHandle` is leaked so its `TempDir` outlives the returned raw handle, exactly as
/// `file_ffi.rs::open_scenario` does.
fn open_scenario() -> (u64, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let commit_hex = add_commit_with_files(&fixture.path, &[], &[("a.txt", "alpha\n")], "ffi scenario");
    let change_id = change_id_for_commit(&fixture.path, &commit_hex);
    let handle = open_handle(&fixture.path);
    std::mem::forget(fixture);
    (handle, change_id)
}

/// A fixture whose change was rewritten twice. Returns `(handle, change id, [newest .. oldest])`.
fn open_evolution_scenario() -> (u64, String, [String; 3]) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let v1 = add_commit_off_root(&fixture.path, "v1");
    let v2 = describe_commit(&fixture.path, &v1, "v2");
    let v3 = describe_commit(&fixture.path, &v2, "v3");
    let change_id = change_id_for_commit(&fixture.path, &v3);
    let handle = open_handle(&fixture.path);
    std::mem::forget(fixture);
    (handle, change_id, [v3, v2, v1])
}

/// Two commits with DIFFERENT parents whose parent trees also differ — the shape that makes
/// `interdiff` observably different from a plain tree diff. Returns `(handle, from, to)`.
fn open_interdiff_scenario() -> (u64, String, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let p1 = add_commit_with_files(&fixture.path, &[], &[("a.txt", "alpha\n")], "p1");
    let p2 = add_commit_with_files(&fixture.path, &[], &[("a.txt", "alpha\n"), ("extra.txt", "e\n")], "p2");
    let from = add_commit_with_files(&fixture.path, &[&p1], &[("a.txt", "alpha\n"), ("x.txt", "x\n")], "from");
    let to = add_commit_with_files(
        &fixture.path,
        &[&p2],
        &[
            ("a.txt", "alpha\n"),
            ("extra.txt", "e\n"),
            ("x.txt", "x\n"),
            ("b.txt", "b\n"),
        ],
        "to",
    );
    let from = change_id_for_commit(&fixture.path, &from);
    let to = change_id_for_commit(&fixture.path, &to);
    let handle = open_handle(&fixture.path);
    std::mem::forget(fixture);
    (handle, from, to)
}

/// A change rewritten with different CONTENT, so its two versions have different trees. Returns
/// `(handle, change id, the HIDDEN pre-rewrite commit hex)`.
///
/// `describe_commit` cannot stand in: a description-only rewrite leaves both versions sharing
/// one tree, so the interdiff between them is empty whichever commit the resolver picked.
fn open_rewritten_content_scenario() -> (u64, String, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let v1 = add_commit_with_files(&fixture.path, &[], &[("a.txt", "one\n")], "v1");
    let v2 = rewrite_commit_files(&fixture.path, &v1, &[("a.txt", "two\n"), ("b.txt", "added\n")]);
    let change_id = change_id_for_commit(&fixture.path, &v2);
    let handle = open_handle(&fixture.path);
    std::mem::forget(fixture);
    (handle, change_id, v1)
}

/// A fixture holding two commits whose ids share their first hex digit. Returns
/// `(handle, a resolvable change id, that one-character AMBIGUOUS prefix)`.
///
/// DETERMINISTIC, not probabilistic: a commit id is hex, so there are 16 possible first digits
/// and by pigeonhole 17 added commits must collide on one. Only the commits added here are
/// counted, so a collision with a fixture commit merely makes the answer ambiguous EARLIER.
fn open_ambiguous_prefix_scenario() -> (u64, String, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let mut seen = std::collections::HashSet::new();
    let mut ambiguous = None;
    for i in 0..17 {
        let hex = add_commit_off_root(&fixture.path, &format!("ambiguity seed {i}"));
        let first = hex.chars().next().expect("a commit hex is never empty");
        if !seen.insert(first) {
            ambiguous = Some(first.to_string());
            break;
        }
    }
    let ambiguous = ambiguous.expect("17 commits cannot avoid a collision over 16 hex digits");
    // A resolvable counterpart, so the OTHER side is never the reason for a refusal.
    let change_id = change_id_for_commit(&fixture.path, &add_commit_off_root(&fixture.path, "resolvable"));
    let handle = open_handle(&fixture.path);
    std::mem::forget(fixture);
    (handle, change_id, ambiguous)
}

/// A parent→child range, so the entry ORDER is observable across the buffer. Returns
/// `(handle, "<parent>::<child>" revset, child commit hex)`.
fn open_range_scenario() -> (u64, String, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let parent = add_commit_with_files(&fixture.path, &[], &[("a.txt", "alpha\n")], "adds a");
    let child = add_commit_with_files(
        &fixture.path,
        &[&parent],
        &[("a.txt", "alpha\n"), ("b.txt", "beta\n")],
        "adds b",
    );
    let handle = open_handle(&fixture.path);
    std::mem::forget(fixture);
    (handle, format!("{parent}::{child}"), child)
}

/// Two commits whose in-memory rebase CONFLICTS: both edit `f.txt` off parents that already
/// differ at it, so `rebase_to_dest_parent`'s 3-way merge cannot resolve. Returns
/// `(handle, from, to)` as change ids.
fn open_conflicting_interdiff_scenario() -> (u64, String, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let p1 = add_commit_with_files(&fixture.path, &[], &[("f.txt", "base-left\n")], "p1");
    let p2 = add_commit_with_files(&fixture.path, &[], &[("f.txt", "base-right\n")], "p2");
    let from = add_commit_with_files(&fixture.path, &[&p1], &[("f.txt", "from\n")], "from");
    let to = add_commit_with_files(&fixture.path, &[&p2], &[("f.txt", "to\n")], "to");
    let from = change_id_for_commit(&fixture.path, &from);
    let to = change_id_for_commit(&fixture.path, &to);
    let handle = open_handle(&fixture.path);
    std::mem::forget(fixture);
    (handle, from, to)
}

// ── zanshin_show ──────────────────────────────────────────────────────────────

#[test]
fn show_round_trip_nests_the_change_and_the_per_path_change_list() {
    pin_env();
    let (handle, change_id) = open_scenario();

    // A NON-DEFAULT revset crosses through the request buffer.
    let req = show_request_bytes(Some(&change_id));
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_show(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "error: {:?}", env.error().and_then(|e| e.code()));

    let entries = env
        .data_as_show_view()
        .expect("ShowView payload")
        .entries()
        .expect("entries present");
    assert_eq!(entries.len(), 1);
    let change = entries.get(0).change().expect("the nested Change table is present");
    assert_eq!(change.id(), Some(change_id.as_str()));
    assert_eq!(change.description(), Some("ffi scenario"));
    let files = entries.get(0).file_changes().expect("file_changes present");
    assert_eq!(files.len(), 1);
    assert_eq!(files.get(0).path(), Some("a.txt"));
    assert_eq!(files.get(0).kind(), fbs::ChangeKind::Added);

    close_handle(handle);
}

/// The presence pair on `ShowRequest`: an ABSENT limit is UNBOUNDED (what a buffer built before
/// the field existed carries), an explicit `0` is an empty success, and a limit takes the FIRST
/// n of the raw revset order.
#[test]
fn show_distinguishes_an_absent_limit_from_an_explicit_zero() {
    pin_env();
    let (handle, range, child) = open_range_scenario();

    for (limit, expected) in [(None, 2), (Some(1), 1), (Some(0), 0), (Some(9), 2)] {
        let req = show_request_bytes_with_limit(Some(&range), limit);
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { zanshin_show(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is the fresh, non-null token the call just returned.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(env.ok(), "limit {limit:?} must succeed");
        let entries = env.data_as_show_view().expect("ShowView payload").entries();
        assert_eq!(
            entries.map_or(0, |e| e.len()),
            expected,
            "the presence flag must keep `limit = 0` distinct from `no limit` ({limit:?})"
        );
        // The one entry a limit of 1 keeps is the FIRST of the raw revset order — the CHILD.
        if limit == Some(1) {
            assert_eq!(
                entries
                    .expect("entries present")
                    .get(0)
                    .change()
                    .and_then(|c| c.commit_id()),
                Some(child.as_str()),
                "the limit is applied in raw revset order, children before parents"
            );
        }
    }

    // The FLAG is what decides, not a zero sentinel: `has_limit = false` with a NON-ZERO
    // `limit` — the combination the schema's "0 / ignored when has_limit == false" comment
    // exists for — must read as unbounded, not as `limit = 1`.
    let req = show_request_bytes_raw(Some(&range), 1, false);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_show(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "an ignored limit field must not fail the call");
    assert_eq!(
        env.data_as_show_view()
            .expect("ShowView payload")
            .entries()
            .map_or(0, |e| e.len()),
        2,
        "a non-zero `limit` with `has_limit = false` is IGNORED, not applied"
    );

    close_handle(handle);
}

#[test]
fn show_reports_a_revset_parse_and_resolution_failure_under_their_own_codes() {
    pin_env();
    let (handle, _change_id) = open_scenario();

    for (revset, expected) in [
        ("::(", JJ_REVSET_PARSE_ERROR),
        ("nosuchbookmark", JJ_REVSET_RESOLUTION_ERROR),
    ] {
        let req = show_request_bytes(Some(revset));
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { zanshin_show(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is the fresh, non-null token the call just returned.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok(), "`{revset}` must be refused");
        assert_eq!(
            env.error().and_then(|e| e.code()),
            Some(expected),
            "the parse/resolution split must not collapse for `{revset}`"
        );
    }

    close_handle(handle);
}

// ── zanshin_evolog ────────────────────────────────────────────────────────────

#[test]
fn evolog_round_trip_carries_predecessors_and_the_recording_operation() {
    pin_env();
    let (handle, change_id, [v3, v2, v1]) = open_evolution_scenario();

    let req = evolog_request_bytes(Some(&change_id), None);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_evolog(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "error: {:?}", env.error().and_then(|e| e.code()));

    let entries = env
        .data_as_evolog_view()
        .expect("EvologView payload")
        .entries()
        .expect("entries present");
    assert_eq!(entries.len(), 3, "three versions, newest first");
    assert_eq!(
        (0..entries.len())
            .map(|i| entries.get(i).change().and_then(|c| c.commit_id()).unwrap_or_default())
            .collect::<Vec<_>>(),
        vec![v3.as_str(), v2.as_str(), v1.as_str()]
    );
    assert_eq!(
        entries
            .get(0)
            .predecessor_commit_ids()
            .map(|v| v.iter().collect::<Vec<_>>()),
        Some(vec![v2.as_str()]),
        "the edges travel as COMMIT ids — every version shares one change id"
    );
    assert!(
        entries.get(0).operation_id().is_some_and(|op| !op.is_empty()),
        "a rewritten version names the operation that recorded it"
    );

    close_handle(handle);
}

#[test]
fn evolog_distinguishes_an_absent_limit_from_an_explicit_zero() {
    pin_env();
    let (handle, change_id, _) = open_evolution_scenario();

    for (limit, expected) in [(None, 3), (Some(2), 2), (Some(0), 0)] {
        let req = evolog_request_bytes(Some(&change_id), limit);
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { zanshin_evolog(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is the fresh, non-null token the call just returned.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(env.ok(), "limit {limit:?} must succeed");
        assert_eq!(
            env.data_as_evolog_view()
                .expect("EvologView payload")
                .entries()
                .map_or(0, |e| e.len()),
            expected,
            "the presence flag must keep `limit = 0` distinct from `no limit` ({limit:?})"
        );
    }

    close_handle(handle);
}

// ── zanshin_interdiff ─────────────────────────────────────────────────────────

#[test]
fn interdiff_round_trip_factors_out_the_parent_difference_and_honours_paths() {
    pin_env();
    let (handle, from, to) = open_interdiff_scenario();

    let req = interdiff_request_bytes(Side::Change(&from), Side::Change(&to), &[]);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_interdiff(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "error: {:?}", env.error().and_then(|e| e.code()));
    let view = env.data_as_interdiff_view().expect("InterdiffView payload");
    let files = view.file_changes().expect("file_changes present");
    assert_eq!(files.len(), 1, "the parents' own difference is factored out");
    assert_eq!(files.get(0).path(), Some("b.txt"));
    assert_eq!(files.get(0).kind(), fbs::ChangeKind::Added);
    assert!(
        !view.base_has_conflicts(),
        "disjoint edits rebase cleanly — the negative pole of the flag"
    );

    // The `paths` field really crosses the buffer: an unmatched prefix empties the result
    // rather than being ignored (an unmatched filter is a CLI warning, never a refusal).
    let req = interdiff_request_bytes(Side::Change(&from), Side::Change(&to), &["nosuchdir"]);
    // SAFETY: see above.
    let token = unsafe { zanshin_interdiff(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "an unmatched path filter is not a refusal");
    assert_eq!(
        env.data_as_interdiff_view()
            .expect("InterdiffView payload")
            .file_changes()
            .map_or(1, |f| f.len()),
        0
    );

    close_handle(handle);
}

/// The `true` pole of `base_has_conflicts` across the wire: the call SUCCEEDS and the flag is
/// set, even when a `paths` filter empties the change list — it describes the rebased TREE.
#[test]
fn interdiff_round_trip_flags_a_conflicted_rebase_base() {
    pin_env();
    let (handle, from, to) = open_conflicting_interdiff_scenario();

    for paths in [&[][..], &["nosuchdir"][..]] {
        let req = interdiff_request_bytes(Side::Change(&from), Side::Change(&to), paths);
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { zanshin_interdiff(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is the fresh, non-null token the call just returned.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(env.ok(), "a conflicted rebase base is not a refusal ({paths:?})");
        let view = env.data_as_interdiff_view().expect("InterdiffView payload");
        assert!(
            view.base_has_conflicts(),
            "the 3-way merge could not resolve f.txt ({paths:?})"
        );
        if !paths.is_empty() {
            assert_eq!(
                view.file_changes().map_or(1, |f| f.len()),
                0,
                "an unmatched filter empties the change list but not the flag"
            );
        }
    }

    close_handle(handle);
}

#[test]
fn interdiff_refuses_both_revisions_absent_and_an_unresolvable_one() {
    pin_env();
    let (handle, _from, to) = open_interdiff_scenario();

    // A legal buffer the VERB refuses — the CLI's `ArgGroup … required(true)`.
    let req = interdiff_request_bytes(Side::Absent, Side::Absent, &[]);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_interdiff(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));
    assert!(
        env.error()
            .and_then(|e| e.context())
            .is_some_and(|c| c.contains("from") && c.contains("to")),
        "the refusal must name which arguments are meant"
    );

    // One side supplied is enough — the other defaults to `@`.
    let req = interdiff_request_bytes(Side::Absent, Side::Change(&to), &[]);
    // SAFETY: see above.
    let token = unsafe { zanshin_interdiff(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    assert!(parse_envelope(&bytes).ok(), "an absent `from` is `@`, not a refusal");

    // A single-revision argument that does not resolve is `jj.change_not_found`, with the id
    // echoed in `context` — never the revset codes `show`/`evolog` use.
    let req = interdiff_request_bytes(Side::Change("nonexistentchangeid"), Side::Absent, &[]);
    // SAFETY: see above.
    let token = unsafe { zanshin_interdiff(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CHANGE_NOT_FOUND));
    assert_eq!(env.error().and_then(|e| e.context()), Some("nonexistentchangeid"));

    close_handle(handle);
}

/// The motivating composition across the FFI: `zanshin_evolog` names a version by its HIDDEN
/// commit id and `zanshin_interdiff` diffs it against the current one, through the `CommitIdRef`
/// arm of the request buffer's `RevisionRef` union.
///
/// The rewrite changes CONTENT, not just the description, so the two versions have different
/// trees and the diff is non-empty — a description-only chain would pass against a resolver that
/// returned the wrong commit. The second half is the tripwire that keeps the two arms apart: the
/// same hex through `ChangeIdRef` is still `jj.change_not_found`, byte-identically to before the
/// union existed.
#[test]
fn interdiff_round_trip_diffs_an_evolog_predecessor_through_the_commit_id_arm() {
    pin_env();
    let (handle, change_id, predecessor) = open_rewritten_content_scenario();

    // The predecessor edge really comes out of `zanshin_evolog`, not out of the fixture builder.
    let req = evolog_request_bytes(Some(&change_id), None);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_evolog(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "error: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(
        env.data_as_evolog_view()
            .expect("EvologView payload")
            .entries()
            .expect("entries present")
            .get(0)
            .predecessor_commit_ids()
            .map(|v| v.iter().collect::<Vec<_>>()),
        Some(vec![predecessor.as_str()])
    );

    let req = interdiff_request_bytes(Side::Commit(&predecessor), Side::Change(&change_id), &[]);
    // SAFETY: see above.
    let token = unsafe { zanshin_interdiff(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(
        env.ok(),
        "a hidden predecessor must resolve: {:?}",
        env.error().and_then(|e| e.code())
    );
    let files = env
        .data_as_interdiff_view()
        .expect("InterdiffView payload")
        .file_changes()
        .expect("file_changes present");
    assert_eq!(
        (0..files.len())
            .map(|i| (files.get(i).path().unwrap_or_default(), files.get(i).kind()))
            .collect::<Vec<_>>(),
        vec![("a.txt", fbs::ChangeKind::Modified), ("b.txt", fbs::ChangeKind::Added)],
        "the two VERSIONS of one change differ by the rewrite"
    );

    // The same hex as a ChangeIdRef stays refused — the change-id arm did not widen.
    let req = interdiff_request_bytes(Side::Change(&predecessor), Side::Change(&change_id), &[]);
    // SAFETY: see above.
    let token = unsafe { zanshin_interdiff(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CHANGE_NOT_FOUND));
    assert_eq!(env.error().and_then(|e| e.context()), Some(predecessor.as_str()));

    close_handle(handle);
}

/// The `CommitIdRef` arm's three refusals, each under its OWN registered code across the wire.
///
/// Nothing new is minted: malformed is the same `jj.invalid_input` the both-absent refusal uses,
/// ambiguity is the registry's ambiguity code (`jj.revset_resolution_error`, where a divergent
/// change-id symbol lands for `show`/`evolog`), and no-match is the plain `jj.change_not_found`.
#[test]
fn interdiff_refuses_a_malformed_ambiguous_or_unknown_commit_id_ref() {
    pin_env();
    let (handle, change_id, ambiguous) = open_ambiguous_prefix_scenario();

    for (spelling, hex, expected) in [
        ("empty", String::new(), JJ_INVALID_INPUT),
        ("not hex", "nothex!".to_owned(), JJ_INVALID_INPUT),
        ("unknown", "deadbeefdeadbeef".to_owned(), JJ_CHANGE_NOT_FOUND),
        ("ambiguous", ambiguous.clone(), JJ_REVSET_RESOLUTION_ERROR),
    ] {
        let req = interdiff_request_bytes(Side::Commit(&hex), Side::Change(&change_id), &[]);
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { zanshin_interdiff(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is the fresh, non-null token the call just returned.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok(), "the {spelling} commit id must be refused");
        assert_eq!(
            env.error().and_then(|e| e.code()),
            Some(expected),
            "the {spelling} commit id must not collapse onto another code"
        );
        assert!(
            env.error().and_then(|e| e.context()).is_some_and(|c| c.contains(&hex)),
            "the {spelling} commit id must ride in `context`, never in the code"
        );
    }

    close_handle(handle);
}

/// The three union shapes no honest builder produces, each isolating one refusal rung.
///
/// The last row puts the fault on `to` instead of `from`: the reader lifts the two sides in
/// sequence and names the offending FIELD, so a suite that only ever malformed `from` would
/// leave the second lift — and its `to.id` message — unwitnessed.
#[test]
fn interdiff_refuses_every_malformed_revision_ref_union() {
    pin_env();
    let (handle, _from, to) = open_interdiff_scenario();

    for (shape, on_to, expected, needle) in [
        (
            // (value present, discriminant absent) — refused by the Verifier at rung 2.
            MalformedUnion::ValueWithoutDiscriminant,
            false,
            FFI_INVALID_ARGUMENT,
            "union",
        ),
        // Range-checked by nobody, so the READER refuses it and names the tag.
        (
            MalformedUnion::OutOfRangeDiscriminant,
            false,
            FFI_INVALID_ARGUMENT,
            "200",
        ),
        // The reader's own required-field guard, rung 4 — a jj-layer code, not an FFI one.
        (MalformedUnion::RefWithoutId, false, JJ_INVALID_INPUT, "from.id"),
        (MalformedUnion::RefWithoutId, true, JJ_INVALID_INPUT, "to.id"),
    ] {
        let req = malformed_union_request_bytes(shape, on_to, &to);
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { zanshin_interdiff(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is the fresh, non-null token the call just returned.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok(), "{needle}: a malformed union must be refused");
        assert_eq!(env.error().and_then(|e| e.code()), Some(expected), "{needle}: code");
        assert!(
            env.error()
                .and_then(|e| e.context())
                .is_some_and(|c| c.to_lowercase().contains(needle)),
            "{needle}: the context must say what was wrong, got {:?}",
            env.error().and_then(|e| e.context())
        );
    }

    close_handle(handle);
}

// ── Shared FFI contract: handles and request buffers ──────────────────────────

/// The three wrappers' shared entry-point contract, in one table so a new verb cannot be added
/// without one: a zero handle, a null request pointer, and a buffer that does not verify as the
/// expected request table.
#[test]
fn every_wrapper_guards_the_handle_and_the_request_buffer() {
    pin_env();
    let (handle, change_id) = open_scenario();

    let cases: [(&str, Wrapper, Vec<u8>); 3] = [
        ("zanshin_show", zanshin_show, show_request_bytes(Some(&change_id))),
        ("zanshin_evolog", zanshin_evolog, evolog_request_bytes(None, None)),
        (
            "zanshin_interdiff",
            zanshin_interdiff,
            interdiff_request_bytes(Side::Change(&change_id), Side::Absent, &[]),
        ),
    ];

    // Non-FlatBuffers bytes: the Verifier must reject them BEFORE any field is read. Long
    // enough that the root-offset read itself does not trip on the buffer's length.
    let garbage = [0xffu8; 64];

    for (name, call, req) in cases {
        // SAFETY: handle 0 is the null-handle case; req is a valid buffer alive for the call.
        let token = unsafe { call(0, req.as_ptr(), req.len()) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_INVALID_HANDLE),
            "{name} must reject a zero handle"
        );

        // SAFETY: a null `data` is exactly what `reject_null_request` guards.
        let token = unsafe { call(handle, std::ptr::null(), 0) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_NULL_POINTER),
            "{name} must reject a null request pointer"
        );

        // SAFETY: garbage is a live, readable buffer of the stated length.
        let token = unsafe { call(handle, garbage.as_ptr(), garbage.len()) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_INVALID_ARGUMENT),
            "{name} must reject a buffer that does not verify"
        );
    }

    close_handle(handle);
}

// ── Op-log invariant across the whole wrapper layer ───────────────────────────

#[test]
fn no_commit_view_wrapper_writes_an_operation() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let commit_hex = add_commit_with_files(&fixture.path, &[], &[("a.txt", "alpha\n")], "op-log invariant scenario");
    let change_id = change_id_for_commit(&fixture.path, &commit_hex);
    // The op-heads directory names the head operation, so its contents are a byte-level
    // witness that no operation was written — no jj_lib import needed.
    let op_heads = fixture.path.join(".jj").join("repo").join("op_heads").join("heads");
    // Sorted: `read_dir` order is unspecified, so an unsorted comparison would be a latent
    // flake the moment the store holds more than one head.
    let mut before: Vec<String> = fs::read_dir(&op_heads)
        .expect("op heads dir")
        .map(|e| e.expect("dir entry").file_name().to_string_lossy().into_owned())
        .collect();
    before.sort();

    let handle = open_handle(&fixture.path);
    // Each verb once on a SUCCESS and once on a REFUSAL: a read must write no operation
    // either way, unlike the CLI, whose `workspace_helper` may snapshot first.
    let cases: [(Wrapper, Vec<u8>, bool); 6] = [
        (zanshin_show, show_request_bytes(Some(&change_id)), true),
        (zanshin_show, show_request_bytes(Some("::(")), false),
        (zanshin_evolog, evolog_request_bytes(Some(&change_id), None), true),
        (zanshin_evolog, evolog_request_bytes(Some("::("), None), false),
        (
            zanshin_interdiff,
            interdiff_request_bytes(Side::Change(&change_id), Side::Absent, &[]),
            true,
        ),
        (
            zanshin_interdiff,
            interdiff_request_bytes(Side::Absent, Side::Absent, &[]),
            false,
        ),
    ];
    for (call, req, expect_ok) in cases {
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { call(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is the fresh, non-null token the call just returned.
        let bytes = unsafe { read_and_free(token) };
        assert_eq!(
            parse_envelope(&bytes).ok(),
            expect_ok,
            "unexpected outcome: {:?}",
            parse_envelope(&bytes).error().and_then(|e| e.code())
        );
    }
    close_handle(handle);

    let mut after: Vec<String> = fs::read_dir(&op_heads)
        .expect("op heads dir")
        .map(|e| e.expect("dir entry").file_name().to_string_lossy().into_owned())
        .collect();
    after.sort();
    assert_eq!(before, after, "no commit-view wrapper may write an operation");
}

// ── Request-kind tag ──────────────────────────────────────────────────────────

/// One row of the wrong-kind table: label, wrapper, buffer, expected kind, received kind, handle.
type KindCase<'a> = (&'a str, Wrapper, &'a [u8], &'a str, &'a str, u64);

/// Every wrapper in this file refuses a buffer built for a DIFFERENT verb, and refuses an
/// untagged one, naming both kinds in `context`.
///
/// The ledger named `ShowRequest`/`EvologRequest`/`InterdiffRequest`/`WorkspaceRootRequest` as a
/// FOUR-way collision — all four put one string in the slot after `kind`. That is now a
/// THREE-way one: Epic 9 follow-up I turned `InterdiffRequest`'s `from`/`to` into a `RevisionRef`
/// UNION, whose discriminant byte occupies the slot the string used to, so an interdiff buffer
/// and the other three no longer share a layout. The cross-feeds among the remaining three still
/// carry POPULATED buffers of the real tables, which is the ledger's own demonstration case.
/// (`WorkspaceRootRequest` is built here rather than imported: any test may construct any request
/// table, and a populated one-string table is what verifies as the other two.)
/// Anything involving `InterdiffRequest`'s layout is refused one rung EARLIER now, by the
/// Verifier — that divergence is pinned by
/// `an_interdiff_buffer_no_longer_shares_a_layout_with_the_one_string_tables`, and the minimal
/// tagged buffer is what isolates the kind rung for `zanshin_interdiff` here. Every wrapper also
/// gets a `handle == 0` row, which is what proves the kind rung runs BEFORE the handle lookup,
/// and an untagged row.
#[test]
fn every_wrapper_refuses_a_buffer_built_for_another_verb() {
    pin_env();
    let (handle, _change_id) = open_scenario();

    let show_req = show_request_bytes_raw(Some("@"), 3, true);
    let evolog_req = evolog_request_bytes(Some("@"), Some(3));
    let workspace_root_req = workspace_root_request_bytes("default");
    let minimal_show = tagged_request_bytes(fbs::RequestKind::Show);
    let minimal_workspace_root = tagged_request_bytes(fbs::RequestKind::WorkspaceRoot);
    let untagged = tagged_request_bytes(fbs::RequestKind::Unspecified);
    let out_of_range = tagged_request_bytes(fbs::RequestKind(200));

    let cases: [KindCase<'_>; 13] = [
        ("show", zanshin_show, &evolog_req, "Show", "Evolog", handle),
        ("evolog", zanshin_evolog, &show_req, "Evolog", "Show", handle),
        (
            "show/workspace_root",
            zanshin_show,
            &workspace_root_req,
            "Show",
            "WorkspaceRoot",
            handle,
        ),
        (
            "evolog/workspace_root",
            zanshin_evolog,
            &workspace_root_req,
            "Evolog",
            "WorkspaceRoot",
            handle,
        ),
        (
            "interdiff/workspace_root",
            zanshin_interdiff,
            &minimal_workspace_root,
            "Interdiff",
            "WorkspaceRoot",
            handle,
        ),
        (
            "interdiff",
            zanshin_interdiff,
            &minimal_show,
            "Interdiff",
            "Show",
            handle,
        ),
        ("show", zanshin_show, &untagged, "Show", "Unspecified", handle),
        ("evolog", zanshin_evolog, &untagged, "Evolog", "Unspecified", handle),
        (
            "interdiff",
            zanshin_interdiff,
            &untagged,
            "Interdiff",
            "Unspecified",
            handle,
        ),
        (
            "show/out-of-range",
            zanshin_show,
            &out_of_range,
            "Show",
            "<UNKNOWN 200>",
            handle,
        ),
        ("show/zero-handle", zanshin_show, &evolog_req, "Show", "Evolog", 0),
        ("evolog/zero-handle", zanshin_evolog, &show_req, "Evolog", "Show", 0),
        (
            "interdiff/zero-handle",
            zanshin_interdiff,
            &minimal_workspace_root,
            "Interdiff",
            "WorkspaceRoot",
            0,
        ),
    ];

    assert_kind_mismatches(&cases);
    close_handle(handle);
}

/// The layout divergence follow-up I introduced, pinned from both directions.
///
/// A POPULATED `InterdiffRequest` no longer verifies as one of the one-string tables, and a
/// populated one-string table no longer verifies as an `InterdiffRequest`: the union's
/// discriminant sits where the string offset used to, and its two vtable slots must be present
/// or absent TOGETHER. Both are still `ffi.invalid_argument` — the same code the kind rung
/// answers with — but they land at rung 2, so the message is the Verifier's rather than the
/// kind-mismatch one. Pinned because it is the ONE observable consequence of the schema change
/// on buffers that are not interdiff's own, and because the table above stopped covering it.
#[test]
fn an_interdiff_buffer_no_longer_shares_a_layout_with_the_one_string_tables() {
    pin_env();
    let (handle, _change_id) = open_scenario();

    let interdiff_req = interdiff_request_bytes(Side::Change("@"), Side::Change("@-"), &[]);
    let workspace_root_req = workspace_root_request_bytes("default");

    for (name, call, req) in [
        ("interdiff buffer into show", zanshin_show as Wrapper, &interdiff_req),
        (
            "one-string buffer into interdiff",
            zanshin_interdiff as Wrapper,
            &workspace_root_req,
        ),
    ] {
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { call(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok(), "{name} must be refused");
        assert_eq!(
            env.error().and_then(|e| e.code()),
            Some(FFI_INVALID_ARGUMENT),
            "{name}: still an invalid argument"
        );
        assert!(
            env.error()
                .and_then(|e| e.context())
                .is_some_and(|c| !c.starts_with("request kind mismatch")),
            "{name}: refused by the Verifier at rung 2, not by the kind rung"
        );
    }

    close_handle(handle);
}

/// Drive one wrong-kind table: every row must answer `ffi.invalid_argument` naming both kinds.
fn assert_kind_mismatches(cases: &[KindCase<'_>]) {
    for &(name, call, req, expected, got, h) in cases {
        // SAFETY: the handle is live or the documented null handle; the buffer outlives the call.
        let token = unsafe { call(h, req.as_ptr(), req.len()) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok(), "{name}: a wrong-kind buffer must be refused");
        assert_eq!(
            env.error().and_then(|e| e.code()),
            Some(FFI_INVALID_ARGUMENT),
            "{name}: a kind mismatch is an invalid argument, not an invalid handle"
        );
        assert_eq!(
            env.error().and_then(|e| e.context()),
            Some(format!("request kind mismatch: expected {expected}, got {got}").as_str()),
            "{name}: the context names both kinds"
        );
    }
}

/// A POPULATED `WorkspaceRootRequest` buffer — the fourth table of the ledger's collision.
///
/// It is built here, in the commit-views suite, because it is the one shape that verifies as all
/// four colliding tables: one string in the slot after `kind`, nothing else.
fn workspace_root_request_bytes(name: &str) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let name_off = b.create_string(name);
    let req = fbs::WorkspaceRootRequest::create(
        &mut b,
        &fbs::WorkspaceRootRequestArgs {
            kind: fbs::RequestKind::WorkspaceRoot,
            name: Some(name_off),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A minimal request buffer carrying `kind` and nothing else.
///
/// With every other field absent all fifteen request tables serialise to IDENTICAL bytes — the
/// interchangeability the tag exists to close — so this is at once a buffer built FOR `kind`'s
/// verb and a buffer that verifies as every other request table. That is what isolates the kind
/// rung: a structurally incompatible buffer is refused one rung earlier, by the Verifier.
/// `Unspecified` yields an UNTAGGED buffer, byte-identical to one built before the tag existed;
/// `RequestKind(200)` yields an out-of-range tag, which `FlatBuffers` does NOT range-check (an
/// enum verifies as its underlying `u8`), so it reaches the same rung and prints `<UNKNOWN 200>`.
fn tagged_request_bytes(kind: fbs::RequestKind) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
    let req = fbs::ChangeIdList::create(&mut b, &fbs::ChangeIdListArgs { kind, change_ids: None });
    b.finish(req, None);
    b.finished_data().to_vec()
}
