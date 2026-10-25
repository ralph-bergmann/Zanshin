// SPDX-License-Identifier: MIT

//! Integration tests for the `zanshin_revset_counts` / `zanshin_find_changes` FFI wrappers
//! (Story 9.25).
//!
//! Every buffer is read via the `FlatBuffers` generated typed accessors and the Verifier; every
//! token is freed via `zanshin_buffer_free_token`. Neither wrapper runs a pre-verb snapshot, so no
//! envelope carries a `precondition`.

use std::ffi::CString;
use std::path::Path;

use flatbuffers::root as fb_root;
use test_helpers::{extract_fixture, FixtureHandle};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::revset_search::{zanshin_find_changes, zanshin_revset_counts};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_INVALID_INPUT, JJ_OPERATION_NOT_FOUND,
    JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
};

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by a `zanshin_*` function and not yet
/// freed.
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

/// The file names in `.jj/repo/<dir>`, sorted.
fn listing(root: &Path, dir: &[&str]) -> Vec<String> {
    let mut path = root.join(".jj").join("repo");
    for part in dir {
        path = path.join(part);
    }
    let mut names: Vec<String> = std::fs::read_dir(path)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// The single current op head, read off disk (no snapshot).
fn head(root: &Path) -> String {
    let heads = listing(root, &["op_heads", "heads"]);
    assert_eq!(heads.len(), 1);
    heads[0].clone()
}

/// A `RevsetCountsRequest` buffer; a `None` operation id is left ABSENT.
fn counts_request(operation_id: Option<&str>, expressions: &[&str], cap: u64) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let op = operation_id.map(|s| b.create_string(s));
    let exprs: Vec<_> = expressions.iter().map(|s| b.create_string(s)).collect();
    let exprs = b.create_vector(&exprs);
    let req = fbs::RevsetCountsRequest::create(
        &mut b,
        &fbs::RevsetCountsRequestArgs {
            kind: fbs::RequestKind::RevsetCounts,
            operation_id: op,
            expressions: Some(exprs),
            cap,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `FindChangesRequest` buffer; a `None` field is left ABSENT.
fn find_request(
    operation_id: Option<&str>,
    expression: Option<&str>,
    limit: u64,
    short_prefixes: Option<&str>,
) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let op = operation_id.map(|s| b.create_string(s));
    let expression = expression.map(|s| b.create_string(s));
    let short_prefixes = short_prefixes.map(|s| b.create_string(s));
    let req = fbs::FindChangesRequest::create(
        &mut b,
        &fbs::FindChangesRequestArgs {
            kind: fbs::RequestKind::FindChanges,
            operation_id: op,
            expression,
            limit,
            short_prefixes,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn counts(handle: u64, request: &[u8]) -> Vec<u8> {
    // SAFETY: the handle is live or the documented null handle; `request` outlives the call.
    unsafe { read_and_free(zanshin_revset_counts(handle, request.as_ptr(), request.len())) }
}

fn find(handle: u64, request: &[u8]) -> Vec<u8> {
    // SAFETY: the handle is live or the documented null handle; `request` outlives the call.
    unsafe { read_and_free(zanshin_find_changes(handle, request.as_ptr(), request.len())) }
}

/// Asserts a refusal: its code and that it carries no precondition.
fn assert_refused(bytes: &[u8], code: &str, what: &str) {
    let env = parse_envelope(bytes);
    assert!(!env.ok(), "{what}: must be refused");
    assert_eq!(env.error().and_then(|e| e.code()), Some(code), "{what}: code");
    assert!(env.precondition().is_none(), "{what}: no precondition");
}

// ── Request ladder ─────────────────────────────────────────────────────────────

#[test]
fn both_wrappers_refuse_a_bad_request_before_the_handle() {
    test_helpers::pin_test_env();
    let (fixture, handle) = open_fixture("tiny-3-commits");
    let op = head(&fixture.path);
    let wrong_kind = {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
        let req = fbs::ChangeIdList::create(
            &mut b,
            &fbs::ChangeIdListArgs {
                kind: fbs::RequestKind::CommitContents,
                ..Default::default()
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    };

    for (name, wrapper) in [
        (
            "counts",
            zanshin_revset_counts as unsafe extern "C" fn(u64, *const u8, usize) -> *mut ZanshinBuf,
        ),
        ("find", zanshin_find_changes),
    ] {
        // SAFETY: a null request is the documented refusal; the handle is live.
        let null = unsafe { read_and_free(wrapper(handle, std::ptr::null(), 0)) };
        assert_refused(&null, FFI_NULL_POINTER, name);
        // SAFETY: as above; `wrong_kind` outlives the call.
        let kind = unsafe { read_and_free(wrapper(handle, wrong_kind.as_ptr(), wrong_kind.len())) };
        assert_refused(&kind, FFI_INVALID_ARGUMENT, name);
        // The request is read BEFORE the handle: a null handle still refuses the request first.
        // SAFETY: the null handle is the documented refusal; nothing is dereferenced.
        let null = unsafe { read_and_free(wrapper(0, std::ptr::null(), 0)) };
        assert_refused(&null, FFI_NULL_POINTER, name);
        // SAFETY: as above; `wrong_kind` outlives the call.
        let kind = unsafe { read_and_free(wrapper(0, wrong_kind.as_ptr(), wrong_kind.len())) };
        assert_refused(&kind, FFI_INVALID_ARGUMENT, name);
    }
    assert_refused(&counts(handle, &counts_request(None, &[], 1)), JJ_INVALID_INPUT, "op");
    assert_refused(
        &counts(0, &counts_request(Some(&op), &[], 1)),
        FFI_INVALID_HANDLE,
        "handle",
    );
    for request in [
        find_request(None, Some("all()"), 1, Some("")),
        find_request(Some(&op), None, 1, Some("")),
        find_request(Some(&op), Some("all()"), 1, None),
    ] {
        assert_refused(&find(handle, &request), JJ_INVALID_INPUT, "missing field");
    }
    assert_refused(
        &find(0, &find_request(Some(&op), Some("all()"), 1, Some(""))),
        FFI_INVALID_HANDLE,
        "handle",
    );
    // Rust does not re-check for an interior NUL (Dart guards it): the id is simply not hex.
    assert_refused(
        &counts(handle, &counts_request(Some("ab\0c"), &[], 1)),
        JJ_INVALID_INPUT,
        "NUL",
    );
    let unknown = "f".repeat(op.len());
    let bytes = counts(handle, &counts_request(Some(&unknown), &[], 1));
    assert_refused(&bytes, JJ_OPERATION_NOT_FOUND, "unknown op");
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.context()),
        Some(format!(r#"No operation ID matching "{unknown}""#).as_str())
    );
    assert_refused(
        &find(handle, &find_request(Some(&unknown), Some("all()"), 1, Some(""))),
        JJ_OPERATION_NOT_FOUND,
        "unknown op",
    );
    close(handle);
}

// ── revset_counts ──────────────────────────────────────────────────────────────

#[test]
fn counts_answer_per_entry_without_precondition_and_write_nothing() {
    test_helpers::pin_test_env();
    let (fixture, handle) = open_fixture("tiny-3-commits");
    let op = head(&fixture.path);
    std::fs::write(fixture.path.join("edited.txt"), "not yet snapshotted").unwrap();
    let operations = listing(&fixture.path, &["op_store", "operations"]);

    let bytes = counts(
        handle,
        &counts_request(
            Some(&op),
            &["all()", "nonexistent_bookmark", "fooo()", r#"diff_contains("x")"#],
            2,
        ),
    );

    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert!(env.precondition().is_none(), "the pinned read runs no precondition");
    assert_eq!(env.warnings().map(|w| w.len()), Some(1), "the diff_contains diagnostic");
    let entries = env.data_as_revset_counts().expect("payload").counts().expect("counts");
    assert_eq!(entries.len(), 4);
    assert_eq!((entries.get(0).n(), entries.get(0).capped()), (2, true));
    assert!(entries.get(0).error().is_none());
    let resolution = entries.get(1).error().expect("own error");
    assert_eq!(resolution.code(), Some(JJ_REVSET_RESOLUTION_ERROR));
    assert_eq!(
        resolution.revset().map(|r| r.kind()),
        Some(fbs::RevsetErrorKind::NoSuchRevision)
    );
    let parse = entries.get(2).error().expect("own error");
    assert_eq!(parse.code(), Some(JJ_REVSET_PARSE_ERROR));
    let revset = parse.revset().expect("detail");
    assert_eq!(revset.kind(), fbs::RevsetErrorKind::NoSuchFunction);
    assert_eq!(revset.symbol(), Some("fooo"));
    assert!(entries.get(3).error().is_none());

    assert_eq!(head(&fixture.path), op, "no op head moved");
    assert_eq!(listing(&fixture.path, &["op_store", "operations"]), operations);
    close(handle);
}

// ── find_changes ───────────────────────────────────────────────────────────────

#[test]
fn find_answers_in_order_truncates_and_refuses_its_own_revset_errors() {
    test_helpers::pin_test_env();
    let (fixture, handle) = open_fixture("medium-1k-commits");
    let op = head(&fixture.path);

    let bytes = find(handle, &find_request(Some(&op), Some("all()"), 3, Some("")));
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert!(env.precondition().is_none() && env.warnings().is_none());
    let found = env.data_as_found_changes().expect("payload");
    assert!(found.truncated());
    let entries = found.entries().expect("entries");
    assert_eq!(entries.len(), 3);
    for entry in entries {
        assert_eq!(entry.commit_id().map(str::len), Some(40));
        assert!(entry.change_id().is_some_and(|c| c.len() == 32));
        assert!(entry.commit_prefix_len() > 0 && entry.change_prefix_len() > 0);
    }

    let bytes = find(handle, &find_request(Some(&op), Some("change_id(k)"), 3, Some("")));
    assert_refused(&bytes, JJ_REVSET_RESOLUTION_ERROR, "ambiguous");
    let error = parse_envelope(&bytes).error().expect("error");
    assert_eq!(error.context(), Some("Change ID prefix `k` is ambiguous"));
    let revset = error.revset().expect("detail");
    assert_eq!(revset.kind(), fbs::RevsetErrorKind::AmbiguousChangeIdPrefix);
    assert_eq!(revset.symbol(), Some("k"));
    assert!(revset.span().is_none());

    let bytes = find(handle, &find_request(Some(&op), Some(r#"description("x"#), 3, Some("")));
    assert_refused(&bytes, JJ_REVSET_PARSE_ERROR, "unclosed quote");
    let error = parse_envelope(&bytes).error().expect("error");
    assert!(error.hints().is_some_and(|h| h.len() == 1), "the CLI's syntax hint");
    let span = error.revset().and_then(|r| r.span()).expect("span");
    assert_eq!(
        (span.offset(), span.length().map(fbs::RevsetSpanLength::value)),
        (14, Some(0))
    );

    let bytes = find(
        handle,
        &find_request(
            Some(&op),
            Some("commit_id(0123456789abcdef0123456789abcdef)"),
            3,
            Some(""),
        ),
    );
    let found = parse_envelope(&bytes).data_as_found_changes().expect("payload");
    assert_eq!(found.entries().map(|e| e.len()), Some(0));
    assert!(!found.truncated());
    close(handle);
}
