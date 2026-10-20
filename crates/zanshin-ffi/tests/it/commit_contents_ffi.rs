// SPDX-License-Identifier: MIT

//! Integration tests for the `zanshin_commit_contents` FFI wrapper (Story 4.10).
//!
//! Every buffer is read via the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token` — leak-clean. The wrapper runs no
//! pre-verb snapshot and records no warning, so EVERY envelope it returns — ok, refusal or jj
//! error — must carry neither `precondition` nor `warnings`.

use std::ffi::CString;
use std::path::Path;

use flatbuffers::root as fb_root;
use test_helpers::{extract_fixture, FixtureHandle};
use zanshin_ffi::commit_contents::zanshin_commit_contents;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CHANGE_NOT_FOUND, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR,
    JJ_OPERATION_NOT_FOUND,
};
use zanshin_jj::{resolve_revset, CommitId, OperationId, Repo};

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

fn open_fixture(name: &str) -> (FixtureHandle, u64) {
    let fixture = extract_fixture(name).expect("fixture must extract");
    let path = CString::new(fixture.path.to_str().expect("UTF-8 path")).expect("no NUL");
    // SAFETY: `path` is a valid NUL-terminated C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "repo open must succeed for fixture '{name}'");
    let handle = env.data_as_repo_handle().expect("RepoHandle payload").handle();
    (fixture, handle)
}

fn close(handle: u64) {
    // SAFETY: handle came from a successful open and has not been closed.
    let bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(parse_envelope(&bytes).ok(), "repo close must succeed");
}

/// The single current op head, read off disk (no snapshot).
fn head(root: &Path) -> String {
    let heads: Vec<String> = std::fs::read_dir(root.join(".jj").join("repo").join("op_heads").join("heads"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(heads.len(), 1);
    heads[0].clone()
}

/// Commit ids through an independent `zanshin_jj` handle (its own commit cache).
fn commit_id_of(root: &Path, revset: &str) -> String {
    let mut repo = Repo::open(root).unwrap();
    let ids = resolve_revset(&repo, revset).unwrap();
    repo.get_change(&ids[0]).unwrap().commit_id.0
}

/// A `CommitContentsRequest` buffer. A `None` operation id is left ABSENT.
fn request_bytes(operation_id: Option<&str>, commit_ids: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let op = operation_id.map(|s| b.create_string(s));
    let ids: Vec<_> = commit_ids.iter().map(|s| b.create_string(s)).collect();
    let ids = b.create_vector(&ids);
    let req = fbs::CommitContentsRequest::create(
        &mut b,
        &fbs::CommitContentsRequestArgs {
            kind: fbs::RequestKind::CommitContents,
            operation_id: op,
            commit_ids: Some(ids),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A minimal request buffer carrying `kind` and nothing else — it verifies as every request
/// table, which isolates the kind rung.
fn tagged_request_bytes(kind: fbs::RequestKind) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
    let req = fbs::ChangeIdList::create(
        &mut b,
        &fbs::ChangeIdListArgs {
            kind,
            change_ids: None,
            ..Default::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// `(case name, request buffer, the kind the buffer carries, handle)`.
type KindCase<'a> = (&'a str, &'a [u8], &'a str, u64);

/// Calls the wrapper and returns the raw envelope bytes.
fn call(handle: u64, request: &[u8]) -> Vec<u8> {
    // SAFETY: the handle is live or the documented null handle; `request` outlives the call.
    unsafe { read_and_free(zanshin_commit_contents(handle, request.as_ptr(), request.len())) }
}

/// Asserts a refusal: its code, optionally its context, and that it carries neither
/// `precondition` nor `warnings`.
fn assert_refused(bytes: &[u8], code: &str, context: Option<&str>, what: &str) {
    let env = parse_envelope(bytes);
    assert!(!env.ok(), "{what}: must be refused");
    assert_eq!(env.error().and_then(|e| e.code()), Some(code), "{what}: code");
    if let Some(context) = context {
        assert_eq!(env.error().and_then(|e| e.context()), Some(context), "{what}: context");
    }
    assert!(
        env.precondition().is_none(),
        "{what}: no precondition on an error envelope"
    );
    assert!(env.warnings().is_none(), "{what}: no warnings on an error envelope");
}

// ── Happy path ────────────────────────────────────────────────────────────────

#[test]
fn commit_contents_returns_every_field_in_request_order_without_precondition_or_warnings() {
    test_helpers::pin_test_env();
    let (fixture, handle) = open_fixture("tiny-3-commits");
    let c3 = commit_id_of(&fixture.path, "description(\"Commit 3\")");
    let root = commit_id_of(&fixture.path, "root()");
    let wc = commit_id_of(&fixture.path, "@");
    let op = head(&fixture.path);
    let oracle = Repo::open(&fixture.path)
        .unwrap()
        .commit_contents(
            &OperationId(op.clone()),
            &[CommitId(c3.clone()), CommitId(root.clone()), CommitId(wc.clone())],
        )
        .unwrap();

    let bytes = call(handle, &request_bytes(Some(&op), &[&c3, &root, &wc]));

    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert!(env.precondition().is_none(), "the pinned read runs no precondition");
    assert!(env.warnings().is_none(), "the pinned read records no warning");
    let items = env
        .data_as_commit_contents()
        .expect("CommitContents payload")
        .contents()
        .expect("contents vector");
    assert_eq!(items.len(), 3);
    for (i, expected) in oracle.iter().enumerate() {
        let item = items.get(i);
        assert_eq!(item.commit_id(), Some(expected.commit_id.0.as_str()), "request order");
        assert_eq!(item.author_name(), Some(expected.author_name.as_str()));
        assert_eq!(item.author_email(), Some(expected.author_email.as_str()));
        assert_eq!(
            item.committer_timestamp_millis(),
            expected.committer_timestamp.millis_since_epoch
        );
        assert_eq!(
            item.committer_tz_offset_minutes(),
            expected.committer_timestamp.tz_offset_minutes
        );
        assert_eq!(item.description(), Some(expected.description.as_str()));
        assert_eq!(item.conflict(), expected.conflict);
        assert_eq!(item.empty(), expected.empty);
    }
    assert_eq!(items.get(0).commit_id(), Some(c3.as_str()));
    assert_eq!(items.get(2).commit_id(), Some(wc.as_str()));
    close(handle);
}

/// The documented "absent `commit_ids` = an empty request": a request whose vector was never
/// written answers ok with an empty (but present) `contents` vector.
#[test]
fn commit_contents_treats_an_absent_commit_ids_vector_as_an_empty_request() {
    test_helpers::pin_test_env();
    let (fixture, handle) = open_fixture("tiny-3-commits");
    let op = head(&fixture.path);
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let op_off = b.create_string(&op);
    let req = fbs::CommitContentsRequest::create(
        &mut b,
        &fbs::CommitContentsRequestArgs {
            kind: fbs::RequestKind::CommitContents,
            operation_id: Some(op_off),
            commit_ids: None,
        },
    );
    b.finish(req, None);

    let bytes = call(handle, b.finished_data());

    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert!(env.precondition().is_none(), "the pinned read runs no precondition");
    assert!(env.warnings().is_none(), "the pinned read records no warning");
    assert_eq!(
        env.data_as_commit_contents()
            .and_then(|c| c.contents())
            .map(|c| c.len()),
        Some(0),
        "an empty, present contents vector"
    );
    close(handle);
}

// ── Refusal ladder ────────────────────────────────────────────────────────────

#[test]
fn commit_contents_guards_the_request_buffer_and_the_handle() {
    test_helpers::pin_test_env();
    let (fixture, handle) = open_fixture("tiny-3-commits");
    let valid = request_bytes(Some(&head(&fixture.path)), &[]);

    // SAFETY: a null `data` is exactly what `reject_null_request` guards.
    let null = unsafe { read_and_free(zanshin_commit_contents(handle, std::ptr::null(), 0)) };
    assert_refused(&null, FFI_NULL_POINTER, None, "null data");

    let garbage = [0xffu8; 64];
    assert_refused(
        &call(handle, &garbage),
        FFI_INVALID_ARGUMENT,
        None,
        "non-verifying buffer",
    );

    assert_refused(&call(0, &valid), FFI_INVALID_HANDLE, None, "zero handle, valid buffer");

    let absent_op = request_bytes(None, &[]);
    assert_refused(
        &call(handle, &absent_op),
        JJ_INVALID_INPUT,
        Some("operation_id is required"),
        "absent operation_id",
    );
    close(handle);
}

/// A buffer built for another verb, or an untagged one, is refused naming both kinds — and
/// BEFORE the handle is looked up (the zero-handle row).
#[test]
fn commit_contents_refuses_a_buffer_built_for_another_verb() {
    test_helpers::pin_test_env();
    let (_fixture, handle) = open_fixture("tiny-3-commits");
    let foreign = tagged_request_bytes(fbs::RequestKind::BookmarkDelete);
    let untagged = tagged_request_bytes(fbs::RequestKind::Unspecified);

    let cases: [KindCase<'_>; 3] = [
        ("live handle", &foreign, "BookmarkDelete", handle),
        ("untagged", &untagged, "Unspecified", handle),
        ("zero handle", &foreign, "BookmarkDelete", 0),
    ];
    for (name, request, got, h) in cases {
        let context = format!("request kind mismatch: expected CommitContents, got {got}");
        assert_refused(&call(h, request), FFI_INVALID_ARGUMENT, Some(&context), name);
    }
    close(handle);
}

#[test]
fn commit_contents_refuses_malformed_ids_including_an_interior_nul_as_invalid_input() {
    test_helpers::pin_test_env();
    let (fixture, handle) = open_fixture("tiny-3-commits");
    let op = head(&fixture.path);

    let cases: [(&str, Vec<u8>); 4] = [
        ("non-hex operation id", request_bytes(Some("xyz"), &[])),
        (
            "operation id with a NUL",
            request_bytes(Some(&format!("{}\0", &op[1..])), &[]),
        ),
        ("operation id prefix", request_bytes(Some(&op[..12]), &[])),
        ("commit id with a NUL", request_bytes(Some(&op), &["ab\0cd"])),
    ];
    for (name, request) in cases {
        assert_refused(&call(handle, &request), JJ_INVALID_INPUT, None, name);
    }
    assert_refused(
        &call(handle, &request_bytes(Some("xyz"), &[])),
        JJ_INVALID_INPUT,
        Some(r#"Operation ID "xyz" is not a valid hexadecimal prefix"#),
        "the CLI's text",
    );
    close(handle);
}

#[test]
fn commit_contents_reports_a_vanished_operation_and_an_unindexed_commit_with_their_ids() {
    test_helpers::pin_test_env();
    let (fixture, handle) = open_fixture("tiny-3-commits");
    let unknown_op = "ab".repeat(64);
    let absent = "0123456789abcdef0123456789abcdef01234567";

    assert_refused(
        &call(handle, &request_bytes(Some(&unknown_op), &[])),
        JJ_OPERATION_NOT_FOUND,
        Some(&format!(r#"No operation ID matching "{unknown_op}""#)),
        "vanished operation",
    );
    assert_refused(
        &call(handle, &request_bytes(Some(&head(&fixture.path)), &[absent])),
        JJ_CHANGE_NOT_FOUND,
        Some(absent),
        "unindexed commit",
    );
    close(handle);
}

#[test]
fn commit_contents_reports_an_unloadable_indexed_commit_as_a_jj_lib_error() {
    test_helpers::pin_test_env();
    let (fixture, handle) = open_fixture("tiny-3-commits");
    let c2 = commit_id_of(&fixture.path, "description(\"Commit 2\")");
    let objects = fixture
        .path
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("objects");
    std::fs::remove_file(objects.join(&c2[..2]).join(&c2[2..])).expect("c2 is a loose object");

    assert_refused(
        &call(handle, &request_bytes(Some(&head(&fixture.path)), &[&c2])),
        JJ_JJ_LIB_ERROR,
        None,
        "indexed but unloadable",
    );
    close(handle);
}
