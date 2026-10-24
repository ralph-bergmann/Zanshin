// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.8's two bookmark mutation wrappers
//! (`zanshin_bookmark_create`, `zanshin_bookmark_delete`), Story 9.19's three
//! (`zanshin_bookmark_move`, `zanshin_bookmark_advance`, `zanshin_bookmark_rename`) and Story
//! 9.11's four (`zanshin_bookmark_set`, `_forget`, `_track`, `_untrack`).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier —
//! a wrong-shape payload is a compile error, not a runtime assert. Every token is freed via
//! `zanshin_buffer_free_token` so the suite is leak-clean. Mirrors `tests/it/workspace_ffi.rs`'s
//! scaffolding; both verbs take a request BUFFER, so one fn-pointer alias covers the shared
//! guard table.
//!
//! The jj-level BEHAVIOUR is pinned in `crates/zanshin-jj/tests/it/bookmark_ops.rs`. What is
//! tested here is the wire contract: the two readers, the handle and buffer guards, each new
//! error code as it comes back over the envelope, and that a refusal writes no operation —
//! read back through `zanshin_op_log`, the same surface a GUI would poll.

use std::ffi::CString;
use std::fs;
use std::path::Path;

use flatbuffers::root as fb_root;
use test_helpers::{extract_fixture, set_local_bookmark, set_remote_bookmark};
use zanshin_ffi::bookmark_ops::{
    zanshin_bookmark_advance, zanshin_bookmark_create, zanshin_bookmark_delete, zanshin_bookmark_forget,
    zanshin_bookmark_move, zanshin_bookmark_rename, zanshin_bookmark_set, zanshin_bookmark_track,
    zanshin_bookmark_untrack,
};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::op_log::zanshin_op_log;
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_BOOKMARK_AUTO_TRACK_EXISTING, JJ_BOOKMARK_EXISTS,
    JJ_BOOKMARK_TRACKED_REMOTE_EXISTS, JJ_CHANGE_NOT_FOUND, JJ_INVALID_INPUT,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

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
            kind: fbs::RequestKind::BookmarkCreate,
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
    let req = fbs::BookmarkDeleteRequest::create(
        &mut b,
        &fbs::BookmarkDeleteRequestArgs {
            kind: fbs::RequestKind::BookmarkDelete,
            names: names_off,
        },
    );
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
    let id = env
        .data_as_status()
        .expect("Status payload")
        .working_copy_change_id()
        .expect("working-copy change id");
    // Guarding only `None` would let an empty string through, and every assertion built on this
    // oracle compares it against another decoded id — two empty strings compare equal.
    assert!(!id.is_empty(), "the working-copy change id is never empty");
    id.to_owned()
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
    let token = unsafe { crate::bookmarks_all_remotes(handle) };
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
    test_helpers::pin_test_env();
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
    test_helpers::pin_test_env();
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
    test_helpers::pin_test_env();
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
    test_helpers::pin_test_env();
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

/// Story 9.54's closing run: auto-tracking an UNTRACKED `feature@origin` that already exists
/// under `remotes.origin.auto-track-created-bookmarks` carries the CLI's warning across the wire
/// as `jj.bookmark_auto_track_existing`, with its text.
#[test]
fn create_auto_tracking_an_existing_remote_bookmark_warns_over_the_wire() {
    test_helpers::pin_test_env();
    let (handle, root) = open_fixture();
    let target = wc_commit_hex(handle);
    set_remote_bookmark(&root, "feature", "origin", &target, false);
    zanshin_jj::config_set(
        Some(&root),
        &zanshin_jj::ConfigTarget::Scope(zanshin_jj::ConfigScope::Repo),
        "remotes.origin.auto-track-created-bookmarks",
        "\"*\"",
    )
    .result
    .expect("config set --repo");

    let req = create_request_bytes(Some(&["feature"]), None);
    // SAFETY: handle is live; the buffer outlives the call.
    let token = unsafe { zanshin_bookmark_create(handle, req.as_ptr(), req.len()) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "create failed: {:?}", env.error().and_then(|e| e.context()));
    let auto_track: Vec<(&str, &str)> = env
        .warnings()
        .map(|w| {
            w.iter()
                .filter(|w| w.code() == Some(JJ_BOOKMARK_AUTO_TRACK_EXISTING))
                .map(|w| (w.code().unwrap_or_default(), w.message().unwrap_or_default()))
                .collect()
        })
        .unwrap_or_default();
    assert_eq!(
        auto_track,
        [(
            JJ_BOOKMARK_AUTO_TRACK_EXISTING,
            "Auto-tracking bookmark that exists on the remote: feature@origin"
        )]
    );

    close_handle(handle);
}

/// A `delete` whose patterns match nothing SUCCEEDS and writes no operation — the wire form
/// of the CLI's "No bookmarks to delete."
#[test]
fn delete_matching_nothing_succeeds_with_the_pre_call_head() {
    test_helpers::pin_test_env();
    let (handle, _root) = open_fixture();
    let before = head_op_id(handle);
    // Read PRE-CALL: an oracle read after the mutation would move with a regression that moved
    // `@`, so both sides of the comparison would shift together and the assertion would hold.
    let expected_wc = wc_change_id(handle);

    let req = delete_request_bytes(Some(&["nosuch"]));
    // SAFETY: handle is live; the buffer outlives the call.
    let token = unsafe { zanshin_bookmark_delete(handle, req.as_ptr(), req.len()) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "matching nothing is never a refusal");
    let noop = env.data_as_mutation_result().expect("MutationResult payload");
    assert_eq!(noop.new_op_id(), Some(before.as_str()));
    // The no-op exit builds its payload through the SAME envelope builder as the committed one,
    // so the present-but-empty vectors are asserted on this path too — that property is only
    // representable here, at the FlatBuffers surface.
    assert_no_change_churn(&noop, &expected_wc);
    assert_eq!(head_op_id(handle), before);

    close_handle(handle);
}

/// An ABSENT `names` vector is the wire form of an empty one, so it reaches the jj layer's ONE
/// canonical refusal rather than a second reader-level spelling of it — for BOTH readers, since
/// each turns its own absent vector into an empty `Vec`. And like every refusal, it writes no
/// operation.
#[test]
fn an_absent_names_vector_refuses_as_invalid_input() {
    test_helpers::pin_test_env();
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

/// A zero handle is refused once the request buffer itself is above reproach, for both wrappers.
///
/// Each wrapper gets a buffer carrying its OWN `RequestKind`, so the null, verify and kind rungs
/// all pass and the handle rung — the fourth — is what answers. Feeding ONE create buffer to both
/// wrappers, which this test did before the tag landed, is now a kind mismatch and is asserted as
/// such in `a_buffer_built_for_the_other_wrapper_is_refused_as_a_kind_mismatch`.
#[test]
fn a_zero_handle_is_refused_by_both_wrappers() {
    test_helpers::pin_test_env();
    let create_req = create_request_bytes(Some(&["feature"]), None);
    let delete_req = delete_request_bytes(Some(&["feature"]));
    for (wrapper, req) in [
        (zanshin_bookmark_create as BufWrapper, &create_req),
        (zanshin_bookmark_delete as BufWrapper, &delete_req),
    ] {
        // SAFETY: 0 is the documented null handle; the buffer outlives the call.
        let token = unsafe { wrapper(0, req.as_ptr(), req.len()) };
        // SAFETY: fresh, non-null token.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_HANDLE));
        assert!(
            env.error().and_then(|e| e.context()).is_none(),
            "the invalid-handle envelope carries no context"
        );
    }
}

/// One row of the wrong-kind table: label, wrapper, buffer, expected kind, received kind, handle.
type KindCase<'a> = (&'a str, BufWrapper, &'a [u8], &'a str, &'a str, u64);

/// A buffer built for the OTHER bookmark verb is refused as a kind mismatch — in both
/// directions, and whether or not the caller also holds a live handle.
///
/// This is the ledger's own cited hazard: `BookmarkCreateRequest.names` are EXACT decoded names
/// while `BookmarkDeleteRequest.names` are GLOB-by-default patterns, and the two tables verify
/// interchangeably, so before the tag a create buffer fed to delete silently glob-deleted what
/// the caller meant literally. The zero-handle half of the table proves the kind rung runs
/// BEFORE the handle lookup: a mis-routed buffer is refused on its own merits.
#[test]
fn a_buffer_built_for_the_other_wrapper_is_refused_as_a_kind_mismatch() {
    test_helpers::pin_test_env();
    let (handle, root) = open_fixture();
    // Seed the bookmark the hazard would destroy: `create`'s `names` are EXACT, `delete`'s are
    // GLOB patterns, so a create buffer reaching the delete reader would match and remove this.
    let target = wc_commit_hex(handle);
    set_local_bookmark(&root, "feature", &[&target]);
    let create_req = create_request_bytes(Some(&["feature"]), None);
    let delete_req = delete_request_bytes(Some(&["feature"]));
    // An UNTAGGED buffer: `FlatBuffers` writes nothing for a field equal to its default, so
    // these bytes are identical to a pre-tag buffer's and must be refused as `Unspecified`.
    let untagged = untagged_request_bytes();

    let before = head_op_id(handle);
    let seeded = listed_bookmark_names(handle);
    assert!(
        seeded.iter().any(|n| n == "feature"),
        "the seed must be live, or the survival assertion below is vacuous"
    );

    let cases: [KindCase<'_>; 6] = [
        (
            "create/delete-buffer",
            zanshin_bookmark_create,
            &delete_req,
            "BookmarkCreate",
            "BookmarkDelete",
            handle,
        ),
        (
            "delete/create-buffer",
            zanshin_bookmark_delete,
            &create_req,
            "BookmarkDelete",
            "BookmarkCreate",
            handle,
        ),
        (
            "create/untagged",
            zanshin_bookmark_create,
            &untagged,
            "BookmarkCreate",
            "Unspecified",
            handle,
        ),
        (
            "delete/untagged",
            zanshin_bookmark_delete,
            &untagged,
            "BookmarkDelete",
            "Unspecified",
            handle,
        ),
        (
            "create/delete-buffer, zero handle",
            zanshin_bookmark_create,
            &delete_req,
            "BookmarkCreate",
            "BookmarkDelete",
            0,
        ),
        (
            "delete/create-buffer, zero handle",
            zanshin_bookmark_delete,
            &create_req,
            "BookmarkDelete",
            "BookmarkCreate",
            0,
        ),
    ];

    for (name, wrapper, req, expected, got, h) in cases {
        // SAFETY: the handle is live (or the documented null handle); the buffer outlives the call.
        let token = unsafe { wrapper(h, req.as_ptr(), req.len()) };
        // SAFETY: fresh, non-null token.
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

    // The hazard itself, asserted rather than asserted-about: a refusal writes no operation and
    // deletes nothing. Without the tag the create buffer fed to `zanshin_bookmark_delete` would
    // have glob-deleted, which shows up in both of these.
    assert_eq!(head_op_id(handle), before, "no kind refusal writes an operation");
    assert_eq!(
        listed_bookmark_names(handle),
        seeded,
        "no kind refusal touches a bookmark"
    );
    close_handle(handle);
}

/// A request buffer whose `kind` was never set.
///
/// Built as a `ChangeIdList` with the DEFAULT tag: `FlatBuffers` emits no bytes for a field
/// equal to its default, so this is byte-identical to a buffer built before the tag existed —
/// and, the tables being structurally interchangeable, it verifies as any request table.
fn untagged_request_bytes() -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
    let req = fbs::ChangeIdList::create(
        &mut b,
        &fbs::ChangeIdListArgs {
            kind: fbs::RequestKind::Unspecified,
            change_ids: None,
            ..Default::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A null buffer and a buffer that does not verify are distinct failures, for both wrappers.
#[test]
fn a_null_or_malformed_request_buffer_is_refused_by_both_wrappers() {
    test_helpers::pin_test_env();
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

// ── Story 9.19: move / advance / rename ───────────────────────────────────────

/// A `BookmarkMoveRequest`; `None` leaves the vector or `to` ABSENT.
fn move_request_bytes(
    names: Option<&[&str]>,
    from: Option<&[&str]>,
    to: Option<&str>,
    allow_backwards: bool,
) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let names = names.map(|ns| {
        let offsets: Vec<_> = ns.iter().map(|n| b.create_string(n)).collect();
        b.create_vector(&offsets)
    });
    let from = from.map(|ns| {
        let offsets: Vec<_> = ns.iter().map(|n| b.create_string(n)).collect();
        b.create_vector(&offsets)
    });
    let to = to.map(|s| b.create_string(s));
    let req = fbs::BookmarkMoveRequest::create(
        &mut b,
        &fbs::BookmarkMoveRequestArgs {
            kind: fbs::RequestKind::BookmarkMove,
            names,
            from,
            to,
            allow_backwards,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `BookmarkAdvanceRequest`; `None` leaves the field ABSENT.
fn advance_request_bytes(names: Option<&[&str]>, to: Option<&str>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let names = names.map(|ns| {
        let offsets: Vec<_> = ns.iter().map(|n| b.create_string(n)).collect();
        b.create_vector(&offsets)
    });
    let to = to.map(|s| b.create_string(s));
    let req = fbs::BookmarkAdvanceRequest::create(
        &mut b,
        &fbs::BookmarkAdvanceRequestArgs {
            kind: fbs::RequestKind::BookmarkAdvance,
            names,
            to,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `BookmarkRenameRequest`; `None` leaves the name ABSENT.
fn rename_request_bytes(old_name: Option<&str>, new_name: Option<&str>, overwrite_existing: bool) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let old_name = old_name.map(|s| b.create_string(s));
    let new_name = new_name.map(|s| b.create_string(s));
    let req = fbs::BookmarkRenameRequest::create(
        &mut b,
        &fbs::BookmarkRenameRequestArgs {
            kind: fbs::RequestKind::BookmarkRename,
            old_name,
            new_name,
            overwrite_existing,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Calls `wrapper` and returns the verified envelope bytes.
fn call(wrapper: BufWrapper, handle: u64, req: &[u8]) -> Vec<u8> {
    // SAFETY: the handle is live or the documented null handle; the buffer outlives the call.
    let token = unsafe { wrapper(handle, req.as_ptr(), req.len()) };
    // SAFETY: fresh, non-null token.
    unsafe { read_and_free(token) }
}

/// The head operation's description, read back through the op-log wrapper.
fn head_op_description(handle: u64) -> String {
    // SAFETY: handle is live; -1 means "no limit".
    let bytes = unsafe { read_and_free(zanshin_op_log(handle, -1)) };
    let env = parse_envelope(&bytes);
    env.data_as_op_log()
        .expect("OpLog payload")
        .operations()
        .expect("operations")
        .get(0)
        .description()
        .unwrap_or_default()
        .to_owned()
}

/// `(change id, commit hex)` of `@`'s first parent, through the change wrapper.
fn wc_parent(handle: u64) -> (String, String) {
    parent_of(handle, &wc_change_id(handle))
}

/// `(change id, commit hex)` of `change`'s first parent, through the change wrapper.
fn parent_of(handle: u64, change: &str) -> (String, String) {
    let read = |id: &str| -> (Vec<String>, String) {
        let id = cstr(id);
        // SAFETY: handle is live; id is a valid NUL-terminated C string alive for the call.
        let bytes = unsafe { read_and_free(zanshin_ffi::change::zanshin_change(handle, id.as_ptr())) };
        let env = parse_envelope(&bytes);
        let change = env.data_as_change().expect("Change payload");
        (
            change
                .parents()
                .expect("parents")
                .iter()
                .map(ToOwned::to_owned)
                .collect(),
            change.commit_id().expect("commit id").to_owned(),
        )
    };
    let (parents, _) = read(change);
    let parent = parents[0].clone();
    let (_, hex) = read(&parent);
    (parent, hex)
}

/// The change id of the commit `hex`: a probe bookmark set on it, read back, then deleted.
fn change_of_hex(handle: u64, root: &Path, hex: &str) -> String {
    set_local_bookmark(root, "probe", &[hex]);
    let change = local_target(handle, "probe").expect("probe target");
    set_local_bookmark(root, "probe", &[]);
    change
}

/// The local target (change id) of `name`, read back through `zanshin_bookmarks`.
fn local_target(handle: u64, name: &str) -> Option<String> {
    // SAFETY: handle is live and was produced by zanshin_repo_open.
    let bytes = unsafe { read_and_free(crate::bookmarks_all_remotes(handle)) };
    let env = parse_envelope(&bytes);
    let rows = env.data_as_bookmarks().and_then(|p| p.bookmarks())?;
    rows.iter()
        .find(|b| b.name() == Some(name) && b.kind() == fbs::BookmarkKind::Local)
        .and_then(|b| b.target().map(ToOwned::to_owned))
}

/// A zero handle answers last, after a well-formed buffer of each wrapper's own kind.
#[test]
fn a_zero_handle_is_refused_by_the_three_new_wrappers() {
    test_helpers::pin_test_env();
    for (wrapper, req) in [
        (
            zanshin_bookmark_move as BufWrapper,
            move_request_bytes(Some(&["a"]), None, None, false),
        ),
        (
            zanshin_bookmark_advance as BufWrapper,
            advance_request_bytes(None, None),
        ),
        (
            zanshin_bookmark_rename as BufWrapper,
            rename_request_bytes(Some("a"), Some("b"), false),
        ),
    ] {
        let bytes = call(wrapper, 0, &req);
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_INVALID_HANDLE)
        );
        // Null and malformed buffers, and another wrapper's buffer, are refused first.
        // SAFETY: a null `data` is the documented null-pointer case.
        let bytes = unsafe { read_and_free(wrapper(0, std::ptr::null(), 0)) };
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_NULL_POINTER)
        );
        let garbage = [0xffu8; 8];
        let bytes = call(wrapper, 0, &garbage);
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_INVALID_ARGUMENT)
        );
        let bytes = call(wrapper, 0, &delete_request_bytes(Some(&["a"])));
        let env = parse_envelope(&bytes);
        assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));
        assert!(env
            .error()
            .and_then(|e| e.context())
            .is_some_and(|c| c.starts_with("request kind mismatch")));
    }
}

/// The three verbs over the wire: an advance to the default `@`, a backwards move refused with
/// its hint in the envelope (no operation), then allowed, a default-candidate advance, and a
/// rename — each success a `MutationResult` whose `new_op_id` is the new head with the CLI's
/// description; and the reader's absent fields.
#[test]
fn move_advance_and_rename_round_trip_over_the_wire() {
    test_helpers::pin_test_env();
    let (handle, root) = open_fixture();
    let (parent_change, parent_hex) = wc_parent(handle);
    let wc_hex = wc_commit_hex(handle);
    set_local_bookmark(&root, "feature", &[&parent_hex]);

    let ok_op = |bytes: &[u8]| -> String {
        let env = parse_envelope(bytes);
        assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
        env.data_as_mutation_result()
            .expect("MutationResult payload")
            .new_op_id()
            .expect("op id")
            .to_owned()
    };

    // Advance by name, `to` absent: the default target `@`.
    let op = ok_op(&call(
        zanshin_bookmark_advance,
        handle,
        &advance_request_bytes(Some(&["feature"]), None),
    ));
    assert_eq!(op, head_op_id(handle));
    assert_eq!(
        head_op_description(handle),
        format!("point bookmark feature to commit {wc_hex}")
    );

    // Move back to the parent: refused, with the CLI's hint, and nothing written.
    let before = head_op_id(handle);
    let backwards = move_request_bytes(Some(&["feature"]), None, Some(&parent_change), false);
    let bytes = call(zanshin_bookmark_move, handle, &backwards);
    let env = parse_envelope(&bytes);
    let error = env.error().expect("refused");
    assert_eq!(error.code(), Some(JJ_INVALID_INPUT));
    assert_eq!(
        error.context(),
        Some("Refusing to move bookmark backwards or sideways: feature")
    );
    let hints: Vec<&str> = error.hints().expect("hints").iter().collect();
    assert_eq!(hints, ["Use --allow-backwards to allow it."]);
    assert_eq!(head_op_id(handle), before);

    let allowed = move_request_bytes(Some(&["feature"]), None, Some(&parent_change), true);
    ok_op(&call(zanshin_bookmark_move, handle, &allowed));
    assert_eq!(
        head_op_description(handle),
        format!("point bookmark feature to commit {parent_hex}")
    );

    // Advance without names and with `to` absent: `heads(::@ & bookmarks())` is the parent.
    ok_op(&call(
        zanshin_bookmark_advance,
        handle,
        &advance_request_bytes(None, None),
    ));
    assert_eq!(
        head_op_description(handle),
        format!("point bookmark feature to commit {wc_hex}")
    );

    // Move with neither names nor from (both absent) is the jj layer's one refusal.
    let bytes = call(
        zanshin_bookmark_move,
        handle,
        &move_request_bytes(None, None, None, false),
    );
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(JJ_INVALID_INPUT)
    );

    ok_op(&call(
        zanshin_bookmark_rename,
        handle,
        &rename_request_bytes(Some("feature"), Some("renamed"), false),
    ));
    assert_eq!(head_op_description(handle), "rename bookmark feature to renamed");
    assert_eq!(listed_bookmark_names(handle), ["renamed"]);

    // An absent old name is the empty name; a missing bookmark is "No such bookmark".
    for (req, context) in [
        (
            rename_request_bytes(None, Some("x"), false),
            "bookmark name must not be empty",
        ),
        (
            rename_request_bytes(Some("nope"), Some("x"), false),
            "No such bookmark: nope",
        ),
    ] {
        let bytes = call(zanshin_bookmark_rename, handle, &req);
        let error = parse_envelope(&bytes).error().expect("refused");
        assert_eq!((error.code(), error.context()), (Some(JJ_INVALID_INPUT), Some(context)));
    }
    set_local_bookmark(&root, "other", &[&wc_hex]);
    let before = head_op_id(handle);
    let bytes = call(
        zanshin_bookmark_rename,
        handle,
        &rename_request_bytes(Some("renamed"), Some("other"), false),
    );
    let error = parse_envelope(&bytes).error().expect("refused");
    assert_eq!(
        (error.code(), error.context()),
        (Some(JJ_BOOKMARK_EXISTS), Some("other"))
    );
    assert_eq!(head_op_id(handle), before, "the refusal writes no operation");
    close_handle(handle);
}

/// Every argument observably crosses the wire: `from` alone and with names, advance's `to` and
/// names, rename's `overwrite_existing`, and a rename warning in the envelope.
#[test]
fn every_move_advance_and_rename_argument_crosses_the_wire() {
    test_helpers::pin_test_env();
    let (handle, root) = open_fixture();
    // `G → P → C`, off root (the fixture's `@` sits on root).
    let g_hex = test_helpers::add_commit_off_root(&root, "g");
    let p_hex = test_helpers::add_commit_with_files(&root, &[&g_hex], &[("p.txt", "p")], "p");
    let c_hex = test_helpers::add_commit_with_files(&root, &[&p_hex], &[("c.txt", "c")], "c");
    let (p, c) = (
        change_of_hex(handle, &root, &p_hex),
        change_of_hex(handle, &root, &c_hex),
    );
    let ok = |bytes: &[u8]| {
        let env = parse_envelope(bytes);
        assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    };

    // `from` alone moves the bookmark on `G`; a names-only move of `two` would have moved `two`.
    set_local_bookmark(&root, "one", &[&g_hex]);
    set_local_bookmark(&root, "two", &[&p_hex]);
    ok(&call(
        zanshin_bookmark_move,
        handle,
        &move_request_bytes(None, Some(&[&g_hex]), Some(&c), false),
    ));
    assert_eq!(local_target(handle, "one").as_deref(), Some(c.as_str()));
    assert_eq!(local_target(handle, "two").as_deref(), Some(p.as_str()));

    // Names AND from: `one` is named but no longer on `P`, so only `two` moves.
    ok(&call(
        zanshin_bookmark_move,
        handle,
        &move_request_bytes(Some(&["one", "two"]), Some(&[&p_hex]), Some(&c), false),
    ));
    assert_eq!(local_target(handle, "two").as_deref(), Some(c.as_str()));
    assert_eq!(
        head_op_description(handle),
        format!("point bookmark two to commit {c_hex}")
    );

    // Advance with `to` = `P`.
    set_local_bookmark(&root, "three", &[&g_hex]);
    ok(&call(
        zanshin_bookmark_advance,
        handle,
        &advance_request_bytes(Some(&["three"]), Some(&p)),
    ));
    assert_eq!(local_target(handle, "three").as_deref(), Some(p.as_str()));

    // Advance by name to `C`: `four` on `G` is no default candidate (`heads(::C & bookmarks())`
    // is `C`, where `one` and `two` already are), so only the name moves it.
    set_local_bookmark(&root, "four", &[&g_hex]);
    ok(&call(
        zanshin_bookmark_advance,
        handle,
        &advance_request_bytes(Some(&["four"]), Some(&c)),
    ));
    assert_eq!(local_target(handle, "four").as_deref(), Some(c.as_str()));

    // Overwrite onto an existing name succeeds.
    ok(&call(
        zanshin_bookmark_rename,
        handle,
        &rename_request_bytes(Some("three"), Some("one"), true),
    ));
    assert_eq!(local_target(handle, "one").as_deref(), Some(p.as_str()));
    assert_eq!(local_target(handle, "three"), None);

    // A rename warning code rides the envelope.
    set_remote_bookmark(&root, "two", "origin", &c_hex, true);
    let bytes = call(
        zanshin_bookmark_rename,
        handle,
        &rename_request_bytes(Some("two"), Some("deux"), false),
    );
    let env = parse_envelope(&bytes);
    assert!(env.ok());
    let codes: Vec<&str> = env
        .warnings()
        .map(|w| w.iter().filter_map(|w| w.code()).collect())
        .unwrap_or_default();
    assert!(codes.contains(&"jj.bookmark_remotes_not_renamed"), "{codes:?}");
    close_handle(handle);
}

// ── Story 9.11: set / forget / track / untrack ────────────────────────────────

/// A `BookmarkSetRequest`; `None` leaves the vector or `revision` ABSENT.
fn set_request_bytes(names: Option<&[&str]>, revision: Option<&str>, allow_backwards: bool) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let names = names.map(|ns| {
        let offsets: Vec<_> = ns.iter().map(|n| b.create_string(n)).collect();
        b.create_vector(&offsets)
    });
    let revision = revision.map(|s| b.create_string(s));
    let req = fbs::BookmarkSetRequest::create(
        &mut b,
        &fbs::BookmarkSetRequestArgs {
            kind: fbs::RequestKind::BookmarkSet,
            names,
            revision,
            allow_backwards,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `BookmarkForgetRequest`; `None` leaves the vector ABSENT.
fn forget_request_bytes(names: Option<&[&str]>, include_remotes: bool) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let names = names.map(|ns| {
        let offsets: Vec<_> = ns.iter().map(|n| b.create_string(n)).collect();
        b.create_vector(&offsets)
    });
    let req = fbs::BookmarkForgetRequest::create(
        &mut b,
        &fbs::BookmarkForgetRequestArgs {
            kind: fbs::RequestKind::BookmarkForget,
            names,
            include_remotes,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `BookmarkTrackRequest` tagged `kind`; `None` leaves a vector ABSENT.
fn track_request_bytes(kind: fbs::RequestKind, names: Option<&[&str]>, remotes: Option<&[&str]>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let names = names.map(|ns| {
        let offsets: Vec<_> = ns.iter().map(|n| b.create_string(n)).collect();
        b.create_vector(&offsets)
    });
    let remotes = remotes.map(|ns| {
        let offsets: Vec<_> = ns.iter().map(|n| b.create_string(n)).collect();
        b.create_vector(&offsets)
    });
    let req = fbs::BookmarkTrackRequest::create(&mut b, &fbs::BookmarkTrackRequestArgs { kind, names, remotes });
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// `Some(tracked)` of the remote row `name@remote` `zanshin_bookmarks` lists, `None` without one.
fn remote_tracked(handle: u64, name: &str, remote: &str) -> Option<bool> {
    // SAFETY: handle is live and was produced by zanshin_repo_open.
    let bytes = unsafe { read_and_free(crate::bookmarks_all_remotes(handle)) };
    let env = parse_envelope(&bytes);
    let rows = env.data_as_bookmarks().and_then(|p| p.bookmarks())?;
    rows.iter()
        .find(|b| b.name() == Some(name) && b.kind() == fbs::BookmarkKind::Remote && b.remote_name() == Some(remote))
        .map(|b| b.tracked())
}

/// The warning codes an envelope carries, in order.
fn warning_codes<'a>(env: &fbs::Envelope<'a>) -> Vec<&'a str> {
    env.warnings()
        .map(|w| w.iter().filter_map(|w| w.code()).collect())
        .unwrap_or_default()
}

/// Asserts `bytes` is an ok envelope whose `MutationResult.new_op_id` is the new head.
fn assert_ok_at_head(handle: u64, bytes: &[u8]) {
    let env = parse_envelope(bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let op = env
        .data_as_mutation_result()
        .expect("MutationResult payload")
        .new_op_id()
        .expect("op id");
    assert_eq!(op, head_op_id(handle));
}

/// The four wrappers' guards: a zero handle answers last, after null and malformed buffers and a
/// buffer of another kind — a track buffer included, which `untrack` refuses (and vice versa).
#[test]
fn a_zero_handle_and_bad_buffers_are_refused_by_the_four_tracking_wrappers() {
    test_helpers::pin_test_env();
    let track = track_request_bytes(fbs::RequestKind::BookmarkTrack, Some(&["a"]), None);
    let untrack = track_request_bytes(fbs::RequestKind::BookmarkUntrack, Some(&["a"]), None);
    for (wrapper, req, other) in [
        (
            zanshin_bookmark_set as BufWrapper,
            set_request_bytes(Some(&["a"]), None, false),
            delete_request_bytes(Some(&["a"])),
        ),
        (
            zanshin_bookmark_forget as BufWrapper,
            forget_request_bytes(Some(&["a"]), false),
            delete_request_bytes(Some(&["a"])),
        ),
        (zanshin_bookmark_track as BufWrapper, track.clone(), untrack.clone()),
        (zanshin_bookmark_untrack as BufWrapper, untrack, track),
    ] {
        let code = |bytes: &[u8]| {
            parse_envelope(bytes)
                .error()
                .and_then(|e| e.code())
                .map(ToOwned::to_owned)
        };
        assert_eq!(code(&call(wrapper, 0, &req)).as_deref(), Some(FFI_INVALID_HANDLE));
        // SAFETY: a null `data` is the documented null-pointer case.
        let bytes = unsafe { read_and_free(wrapper(0, std::ptr::null(), 0)) };
        assert_eq!(code(&bytes).as_deref(), Some(FFI_NULL_POINTER));
        assert_eq!(
            code(&call(wrapper, 0, &[0xffu8; 8])).as_deref(),
            Some(FFI_INVALID_ARGUMENT)
        );
        let bytes = call(wrapper, 0, &other);
        let env = parse_envelope(&bytes);
        assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));
        assert!(env
            .error()
            .and_then(|e| e.context())
            .is_some_and(|c| c.starts_with("request kind mismatch")));
    }
}

/// `set` over the wire: `revision` absent (`@`) and present, `allow_backwards` off (refused with
/// the hint, no operation) and on, and absent `names` (the jj layer's one refusal).
#[test]
fn set_round_trips_revision_and_allow_backwards_over_the_wire() {
    test_helpers::pin_test_env();
    let (handle, root) = open_fixture();
    let wc_hex = wc_commit_hex(handle);
    let g_hex = test_helpers::add_commit_off_root(&root, "g");
    let g = change_of_hex(handle, &root, &g_hex);

    assert_ok_at_head(
        handle,
        &call(
            zanshin_bookmark_set,
            handle,
            &set_request_bytes(Some(&["feature"]), None, false),
        ),
    );
    assert_eq!(
        head_op_description(handle),
        format!("point bookmark feature to commit {wc_hex}")
    );

    let before = head_op_id(handle);
    let bytes = call(
        zanshin_bookmark_set,
        handle,
        &set_request_bytes(Some(&["feature"]), Some(&g), false),
    );
    let error = parse_envelope(&bytes).error().expect("sideways");
    assert_eq!(
        (error.code(), error.context()),
        (
            Some(JJ_INVALID_INPUT),
            Some("Refusing to move bookmark backwards or sideways: feature")
        )
    );
    let hints: Vec<&str> = error.hints().expect("hints").iter().collect();
    assert_eq!(hints, ["Use --allow-backwards to allow it."]);
    assert_eq!(head_op_id(handle), before);

    assert_ok_at_head(
        handle,
        &call(
            zanshin_bookmark_set,
            handle,
            &set_request_bytes(Some(&["feature"]), Some(&g), true),
        ),
    );
    assert_eq!(local_target(handle, "feature").as_deref(), Some(g.as_str()));

    let bytes = call(zanshin_bookmark_set, handle, &set_request_bytes(None, None, false));
    let error = parse_envelope(&bytes).error().expect("no names");
    assert_eq!(
        (error.code(), error.context()),
        (Some(JJ_INVALID_INPUT), Some("bookmark set requires at least one name"))
    );
    close_handle(handle);
}

/// `forget` over the wire: without `include_remotes` the tracked remote row stays, untracked;
/// with it the row goes. An unmatched name rides the envelope as `jj.bookmark_names_unmatched`.
#[test]
fn forget_round_trips_include_remotes_and_a_warning_over_the_wire() {
    test_helpers::pin_test_env();
    let (handle, root) = open_fixture();
    let g_hex = test_helpers::add_commit_off_root(&root, "g");
    for name in ["kept", "gone"] {
        set_local_bookmark(&root, name, &[&g_hex]);
        set_remote_bookmark(&root, name, "origin", &g_hex, true);
    }

    assert_ok_at_head(
        handle,
        &call(
            zanshin_bookmark_forget,
            handle,
            &forget_request_bytes(Some(&["kept"]), false),
        ),
    );
    assert_eq!(head_op_description(handle), "forget bookmark kept");
    assert_eq!(local_target(handle, "kept"), None);
    assert_eq!(remote_tracked(handle, "kept", "origin"), Some(false));

    assert_ok_at_head(
        handle,
        &call(
            zanshin_bookmark_forget,
            handle,
            &forget_request_bytes(Some(&["gone"]), true),
        ),
    );
    assert_eq!(remote_tracked(handle, "gone", "origin"), None);

    let before = head_op_id(handle);
    let bytes = call(
        zanshin_bookmark_forget,
        handle,
        &forget_request_bytes(Some(&["nope"]), false),
    );
    let env = parse_envelope(&bytes);
    assert!(env.ok());
    assert_eq!(warning_codes(&env), ["jj.bookmark_names_unmatched"]);
    assert_eq!(
        env.data_as_mutation_result().and_then(|r| r.new_op_id()),
        Some(before.as_str()),
        "no operation"
    );
    close_handle(handle);
}

/// `track` / `untrack` over the wire: `remotes` limits the patterns to one remote; tracking an
/// already tracked symbol warns `jj.bookmark_already_tracked` and writes nothing; `untrack`
/// untracks; mixed syntax is refused.
#[test]
fn track_and_untrack_round_trip_remotes_and_warnings_over_the_wire() {
    test_helpers::pin_test_env();
    let (handle, root) = open_fixture();
    let g_hex = test_helpers::add_commit_off_root(&root, "g");
    set_local_bookmark(&root, "y", &[&g_hex]);
    for remote in ["origin", "upstream"] {
        set_remote_bookmark(&root, "y", remote, &g_hex, false);
    }

    let req = track_request_bytes(fbs::RequestKind::BookmarkTrack, Some(&["y"]), Some(&["origin"]));
    assert_ok_at_head(handle, &call(zanshin_bookmark_track, handle, &req));
    assert_eq!(head_op_description(handle), "track remote bookmark y@origin");
    assert_eq!(remote_tracked(handle, "y", "origin"), Some(true));
    assert_eq!(remote_tracked(handle, "y", "upstream"), Some(false));

    let before = head_op_id(handle);
    let req = track_request_bytes(fbs::RequestKind::BookmarkTrack, Some(&["y@origin"]), None);
    let bytes = call(zanshin_bookmark_track, handle, &req);
    let env = parse_envelope(&bytes);
    assert!(env.ok());
    assert_eq!(warning_codes(&env), ["jj.bookmark_already_tracked"]);
    assert_eq!(head_op_id(handle), before);

    let req = track_request_bytes(fbs::RequestKind::BookmarkUntrack, Some(&["y@origin"]), None);
    assert_ok_at_head(handle, &call(zanshin_bookmark_untrack, handle, &req));
    assert_eq!(head_op_description(handle), "untrack remote bookmark y@origin");
    assert_eq!(remote_tracked(handle, "y", "origin"), Some(false));

    let req = track_request_bytes(fbs::RequestKind::BookmarkUntrack, Some(&["y", "y@origin"]), None);
    let bytes = call(zanshin_bookmark_untrack, handle, &req);
    let error = parse_envelope(&bytes).error().expect("mixed");
    assert_eq!(
        (error.code(), error.context()),
        (
            Some(JJ_INVALID_INPUT),
            Some("Cannot specify both <bookmark> patterns and <bookmark>@<remote> symbols")
        )
    );
    close_handle(handle);
}
