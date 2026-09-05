// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.8's two bookmark mutation wrappers
//! (`zanshin_bookmark_create`, `zanshin_bookmark_delete`).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier —
//! a wrong-shape payload is a compile error, not a runtime assert. Every token is freed via
//! `zanshin_buffer_free_token` so the suite is leak-clean. Mirrors `tests/workspace_ffi.rs`'s
//! scaffolding; both verbs take a request BUFFER, so one fn-pointer alias covers the shared
//! guard table.
//!
//! The jj-level BEHAVIOUR is pinned in `crates/zanshin-jj/tests/bookmark_ops.rs`. What is
//! tested here is the wire contract: the two readers, the handle and buffer guards, each new
//! error code as it comes back over the envelope, and that a refusal writes no operation —
//! read back through `zanshin_op_log`, the same surface a GUI would poll.

use std::ffi::CString;
use std::path::Path;
use std::sync::LazyLock;
use std::{env, fs};

use flatbuffers::root as fb_root;
use test_helpers::{extract_fixture, set_local_bookmark, set_remote_bookmark};
use zanshin_ffi::bookmark_ops::{zanshin_bookmark_create, zanshin_bookmark_delete};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::op_log::zanshin_op_log;
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_BOOKMARK_EXISTS, JJ_BOOKMARK_TRACKED_REMOTE_EXISTS,
    JJ_CHANGE_NOT_FOUND, JJ_INVALID_INPUT,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: mirrors tests/workspace_ffi.rs — an empty string makes jj-lib find no config at
    // that path; GIT_CONFIG_GLOBAL="" isolates gix.
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

/// The request-buffer wrapper shape both verbs share.
type BufWrapper = unsafe extern "C" fn(u64, *const u8, usize) -> *mut ZanshinBuf;

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

/// The head operation's id, read back through the shipped op-log wrapper.
fn head_op_id(handle: u64) -> String {
    // SAFETY: handle is live; -1 means "no limit".
    let token = unsafe { zanshin_op_log(handle, -1) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "op_log must succeed");
    env.data_as_op_log()
        .expect("OpLog payload")
        .operations()
        .expect("operations vector")
        .get(0)
        .id()
        .expect("head op id")
        .to_owned()
}

// ── Request-buffer builders ───────────────────────────────────────────────────

/// A `BookmarkCreateRequest` buffer. A `None` revision is left ABSENT — the wire form of "the
/// user did not supply `-r`", which selects the CLI's `@` default. A `None` `names` likewise
/// leaves the VECTOR genuinely absent, which is the create reader's own absent-vector path.
fn create_request_bytes(names: Option<&[&str]>, revision: Option<&str>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let names_off = names.map(|ns| {
        let offsets: Vec<_> = ns.iter().map(|n| b.create_string(n)).collect();
        b.create_vector(&offsets)
    });
    let revision_off = revision.map(|s| b.create_string(s));
    let req = fbs::BookmarkCreateRequest::create(
        &mut b,
        &fbs::BookmarkCreateRequestArgs {
            names: names_off,
            revision: revision_off,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `BookmarkDeleteRequest` buffer. Passing `None` leaves the `names` vector genuinely
/// ABSENT, which the reader turns into an empty `Vec` so the jj layer raises the one canonical
/// empty-list refusal.
fn delete_request_bytes(names: Option<&[&str]>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let names_off = names.map(|ns| {
        let offsets: Vec<_> = ns.iter().map(|n| b.create_string(n)).collect();
        b.create_vector(&offsets)
    });
    let req = fbs::BookmarkDeleteRequest::create(&mut b, &fbs::BookmarkDeleteRequestArgs { names: names_off });
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Extract `tiny-3-commits`, open it, and return `(handle, root)`. The `FixtureHandle` is
/// leaked so its `TempDir` outlives the raw handle, exactly as `workspace_ffi.rs` does.
fn open_fixture() -> (u64, std::path::PathBuf) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let root = fs::canonicalize(&fixture.path).expect("fixture root exists");
    let handle = open_handle(&root);
    std::mem::forget(fixture);
    (handle, root)
}

/// The working-copy change id `zanshin_status` reports — the oracle a `MutationResult`'s own
/// `working_copy_change_id` is checked against, and the first half of [`wc_commit_hex`].
fn wc_change_id(handle: u64) -> String {
    // SAFETY: handle is live and was produced by zanshin_repo_open.
    let token = unsafe { zanshin_ffi::status::zanshin_status(handle) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "status must succeed");
    env.data_as_status()
        .expect("Status payload")
        .working_copy_change_id()
        .expect("working-copy change id")
        .to_owned()
}

/// The fixture's working-copy commit hex — the seed target for in-test bookmark state.
fn wc_commit_hex(handle: u64) -> String {
    // `Status` carries change ids, not commit hexes; the change wrapper resolves the pair.
    let change_id = wc_change_id(handle);
    let id = cstr(&change_id);
    // SAFETY: handle is live; id is a valid NUL-terminated C string alive for the call.
    let token = unsafe { zanshin_ffi::change::zanshin_change(handle, id.as_ptr()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "change must succeed");
    env.data_as_change()
        .expect("Change payload")
        .commit_id()
        .expect("commit id")
        .to_owned()
}

/// Local bookmark names the shipped read wrapper reports.
fn listed_bookmark_names(handle: u64) -> Vec<String> {
    // SAFETY: handle is live and was produced by zanshin_repo_open.
    let token = unsafe { zanshin_ffi::bookmarks::zanshin_bookmarks(handle) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "bookmarks must succeed");
    env.data_as_bookmarks()
        .expect("Bookmarks payload")
        .bookmarks()
        .map(|v| {
            v.iter()
                .map(|b| b.name().unwrap_or_default().to_owned())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

/// The three `MutationResult` columns neither bookmark verb ever fills, asserted on the WIRE.
///
/// Both vectors are PRESENT-but-empty rather than absent: the builder always writes `Some(vec)`,
/// so `None` here would be a real change to the wire shape and not merely a missing value.
fn assert_no_change_churn(result: &fbs::MutationResult<'_>, expected_wc: &str) {
    let new_ids = result.new_change_ids().expect("new_change_ids is always present");
    assert_eq!(new_ids.len(), 0, "a bookmark verb mints no change");
    let abandoned = result
        .abandoned_change_ids()
        .expect("abandoned_change_ids is always present");
    assert_eq!(abandoned.len(), 0, "a bookmark verb abandons no change");
    assert_eq!(
        result.working_copy_change_id(),
        Some(expected_wc),
        "`@` is what `zanshin_status` reports"
    );
}

// ── Round trip ────────────────────────────────────────────────────────────────

/// Create then delete over the wire: both return the shipped `MutationResult` payload (no new
/// union member), the shipped read reflects each step, and the op-log head advances twice.
#[test]
fn create_then_delete_round_trips_through_mutation_result() {
    pin_env();
    let (handle, _root) = open_fixture();
    let before = head_op_id(handle);
    let expected_wc = wc_change_id(handle);

    let req = create_request_bytes(Some(&["feature"]), None);
    // SAFETY: handle is live; req is a live, correctly-sized buffer for the call.
    let token = unsafe { zanshin_bookmark_create(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "create failed: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    let created = env.data_as_mutation_result().expect("MutationResult payload");
    assert_ne!(created.new_op_id(), Some(before.as_str()), "create writes an operation");
    assert_eq!(created.new_op_id(), Some(head_op_id(handle).as_str()));
    assert_no_change_churn(&created, &expected_wc);
    assert_eq!(listed_bookmark_names(handle), vec!["feature".to_owned()]);

    let req = delete_request_bytes(Some(&["exact:feature"]));
    // SAFETY: handle is live; req is a live, correctly-sized buffer for the call.
    let token = unsafe { zanshin_bookmark_delete(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "delete failed: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    let deleted = env.data_as_mutation_result().expect("MutationResult payload");
    assert_no_change_churn(&deleted, &expected_wc);
    assert!(listed_bookmark_names(handle).is_empty());

    close_handle(handle);
}

/// An ABSENT `revision` is what applies the CLI's `-r` default; a PRESENT one that resolves
/// nothing refuses. A reader that dropped the field would make both calls behave alike.
#[test]
fn create_distinguishes_an_absent_revision_from_a_present_unresolvable_one() {
    pin_env();
    let (handle, _root) = open_fixture();

    let absent = create_request_bytes(Some(&["from-default"]), None);
    // SAFETY: handle is live; the buffer outlives the call.
    let token = unsafe { zanshin_bookmark_create(handle, absent.as_ptr(), absent.len()) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    assert!(parse_envelope(&bytes).ok(), "an absent revision means `@`");

    // Reverse-hex alphabet is k-z; this id belongs to no commit in the fixture.
    let present = create_request_bytes(Some(&["from-explicit"]), Some("pqrstuvwxyzklmnopqrstuvwxyzklmno"));
    // SAFETY: handle is live; the buffer outlives the call.
    let token = unsafe { zanshin_bookmark_create(handle, present.as_ptr(), present.len()) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CHANGE_NOT_FOUND));

    // The third state the schema, the header and the Dart docs all promise: an explicitly
    // PRESENT but EMPTY string is a VALUE, not an absence. It must refuse rather than fall
    // back to `@` — otherwise a GUI that binds an empty text field straight to the field
    // would silently create the bookmark somewhere the user never asked for.
    let empty = create_request_bytes(Some(&["from-empty"]), Some(""));
    // SAFETY: handle is live; the buffer outlives the call.
    let token = unsafe { zanshin_bookmark_create(handle, empty.as_ptr(), empty.len()) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok(), "an empty revision is a value, not the `@` default");
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CHANGE_NOT_FOUND));
    assert!(
        !listed_bookmark_names(handle).contains(&"from-empty".to_owned()),
        "the refused create must not have written the bookmark"
    );

    close_handle(handle);
}

// ── The two new error codes, over the wire ───────────────────────────────────

/// `jj.bookmark_exists` carries the offending NAME in `context`, and the refusal writes NO
/// operation — both halves of the contract, asserted through the wrapper itself.
#[test]
fn create_reports_bookmark_exists_and_writes_no_operation() {
    pin_env();
    let (handle, root) = open_fixture();
    let target = wc_commit_hex(handle);
    set_local_bookmark(&root, "feature", &[&target]);
    let before = head_op_id(handle);

    let req = create_request_bytes(Some(&["feature"]), None);
    // SAFETY: handle is live; the buffer outlives the call.
    let token = unsafe { zanshin_bookmark_create(handle, req.as_ptr(), req.len()) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    let error = env.error().expect("error detail");
    assert_eq!(error.code(), Some(JJ_BOOKMARK_EXISTS));
    assert_eq!(error.context(), Some("feature"));
    assert_eq!(head_op_id(handle), before, "a refusal writes no operation");

    close_handle(handle);
}

/// The deleted-but-tracked refusal gets its own code, distinct from the already-exists one.
#[test]
fn create_reports_bookmark_tracked_remote_exists() {
    pin_env();
    let (handle, root) = open_fixture();
    let target = wc_commit_hex(handle);
    set_remote_bookmark(&root, "foo", "origin", &target, true);
    let before = head_op_id(handle);

    let req = create_request_bytes(Some(&["foo"]), None);
    // SAFETY: handle is live; the buffer outlives the call.
    let token = unsafe { zanshin_bookmark_create(handle, req.as_ptr(), req.len()) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    let error = env.error().expect("error detail");
    assert_eq!(error.code(), Some(JJ_BOOKMARK_TRACKED_REMOTE_EXISTS));
    assert_eq!(error.context(), Some("foo"));
    assert_eq!(head_op_id(handle), before, "a refusal writes no operation");

    close_handle(handle);
}

/// A `delete` whose patterns match nothing SUCCEEDS and writes no operation — the wire form
/// of the CLI's "No bookmarks to delete."
#[test]
fn delete_matching_nothing_succeeds_with_the_pre_call_head() {
    pin_env();
    let (handle, _root) = open_fixture();
    let before = head_op_id(handle);

    let req = delete_request_bytes(Some(&["nosuch"]));
    // SAFETY: handle is live; the buffer outlives the call.
    let token = unsafe { zanshin_bookmark_delete(handle, req.as_ptr(), req.len()) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "matching nothing is never a refusal");
    assert_eq!(
        env.data_as_mutation_result()
            .expect("MutationResult payload")
            .new_op_id(),
        Some(before.as_str())
    );
    assert_eq!(head_op_id(handle), before);

    close_handle(handle);
}

/// An ABSENT `names` vector is the wire form of an empty one, so it reaches the jj layer's ONE
/// canonical refusal rather than a second reader-level spelling of it — for BOTH readers, since
/// each turns its own absent vector into an empty `Vec`. And like every refusal, it writes no
/// operation.
#[test]
fn an_absent_names_vector_refuses_as_invalid_input() {
    pin_env();
    let (handle, _root) = open_fixture();
    let before = head_op_id(handle);

    for (wrapper, req) in [
        (zanshin_bookmark_delete as BufWrapper, delete_request_bytes(None)),
        (zanshin_bookmark_create as BufWrapper, create_request_bytes(None, None)),
    ] {
        // SAFETY: handle is live; the buffer outlives the call.
        let token = unsafe { wrapper(handle, req.as_ptr(), req.len()) };
        // SAFETY: fresh, non-null token.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);

        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));
        assert_eq!(head_op_id(handle), before, "a refusal writes no operation");
    }

    close_handle(handle);
}

// ── Shared guards ─────────────────────────────────────────────────────────────

/// A zero handle is refused BEFORE the request buffer is even looked at, for both wrappers.
#[test]
fn a_zero_handle_is_refused_by_both_wrappers() {
    pin_env();
    let req = create_request_bytes(Some(&["feature"]), None);
    for wrapper in [
        zanshin_bookmark_create as BufWrapper,
        zanshin_bookmark_delete as BufWrapper,
    ] {
        // SAFETY: 0 is the documented null handle; the buffer outlives the call.
        let token = unsafe { wrapper(0, req.as_ptr(), req.len()) };
        // SAFETY: fresh, non-null token.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_HANDLE));
    }
}

/// A null buffer and a buffer that does not verify are distinct failures, for both wrappers.
#[test]
fn a_null_or_malformed_request_buffer_is_refused_by_both_wrappers() {
    pin_env();
    let (handle, _root) = open_fixture();
    let garbage: [u8; 8] = [0xff; 8];

    for wrapper in [
        zanshin_bookmark_create as BufWrapper,
        zanshin_bookmark_delete as BufWrapper,
    ] {
        // SAFETY: a null `data` is the documented null-pointer case.
        let token = unsafe { wrapper(handle, std::ptr::null(), 0) };
        // SAFETY: fresh, non-null token.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

        // SAFETY: handle is live; the array outlives the call.
        let token = unsafe { wrapper(handle, garbage.as_ptr(), garbage.len()) };
        // SAFETY: fresh, non-null token.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));
    }

    close_handle(handle);
}
