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
//! - `bookmarks_carry_the_tracking_facts_on_a_real_repo` — Story 9.29's facts over the real path
//!
//! - Story 9.19: the `BookmarkListRequest` reader (null, malformed, wrong kind, an `Unspecified`
//!   sort key), a filter that changes the row set, and clap's `--all-remotes` conflict.

use std::ffi::CString;

use flatbuffers::root as fb_root;
use test_helpers::{
    add_commit_off_root, add_commit_with_files, extract_fixture, set_local_bookmark, set_remote_bookmark,
};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    bookmarks::zanshin_bookmarks,
    repo::{zanshin_repo_close, zanshin_repo_open},
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_INVALID_INPUT,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

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
    test_helpers::pin_test_env();

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

    let bm_token = unsafe { crate::bookmarks_all_remotes(handle) };
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
    test_helpers::pin_test_env();

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

    let bm_token = unsafe { crate::bookmarks_all_remotes(handle) };
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
    test_helpers::pin_test_env();

    let token = unsafe { crate::bookmarks_all_remotes(0) };
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

/// Story 9.29: a local bookmark one commit behind its tracked `@origin`, plus an untracked
/// remote — every tracking fact crosses the real FFI path.
#[test]
fn bookmarks_carry_the_tracking_facts_on_a_real_repo() {
    test_helpers::pin_test_env();

    let fx = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let parent = add_commit_off_root(&fx.path, "parent");
    let child = add_commit_with_files(&fx.path, &[&parent], &[("child.txt", "child")], "child");
    set_local_bookmark(&fx.path, "f", &[&parent]);
    set_remote_bookmark(&fx.path, "f", "origin", &child, true);
    set_remote_bookmark(&fx.path, "u", "origin", &child, false);
    let path_cstr = cstr(fx.path.to_str().expect("fixture path must be valid UTF-8"));

    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let handle = parse_envelope(&open_bytes)
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    let bm_bytes = unsafe { read_and_free(crate::bookmarks_all_remotes(handle)) };
    let bm_env = parse_envelope(&bm_bytes);
    assert!(
        bm_env.ok(),
        "zanshin_bookmarks must succeed; error={:?}",
        bm_env.error()
    );
    let bms = bm_env
        .data_as_bookmarks()
        .and_then(|p| p.bookmarks())
        .expect("bookmarks list must be present");
    assert_eq!(bms.len(), 3, "f, f@origin, u@origin");

    let local = bms.get(0);
    assert_eq!((local.name(), local.kind()), (Some("f"), fbs::BookmarkKind::Local));
    assert!(local.target().is_some() && !local.synced() && !local.conflicted());

    let tracked = bms.get(1);
    assert_eq!(tracked.remote_name(), Some("origin"));
    assert!(tracked.tracked() && !tracked.synced());
    let ahead = tracked.ahead().expect("ahead computed");
    let behind = tracked.behind().expect("behind computed");
    assert_eq!((ahead.lower(), ahead.upper(), ahead.has_upper()), (1, 1, true));
    assert_eq!((behind.lower(), behind.upper(), behind.has_upper()), (0, 0, true));

    let untracked = bms.get(2);
    assert_eq!(
        (untracked.name(), untracked.kind()),
        (Some("u"), fbs::BookmarkKind::Remote)
    );
    assert!(!untracked.tracked() && !untracked.synced());
    assert!(untracked.ahead().is_none() && untracked.behind().is_none());

    let close_bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");
}

/// A `BookmarkListRequest` built by `fill` on top of the right kind.
fn list_request(
    fill: impl FnOnce(&mut flatbuffers::FlatBufferBuilder<'static>) -> fbs::BookmarkListRequestArgs<'static>,
) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let args = fill(&mut b);
    let req = fbs::BookmarkListRequest::create(&mut b, &args);
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `(name, remote_name)` row, or an error's `(code, context)`.
type Pair = (String, Option<String>);

/// `zanshin_bookmarks` over `req`, as `(name, remote_name)` rows or the error `(code, context)`.
fn list(handle: u64, req: &[u8]) -> Result<Vec<Pair>, Pair> {
    // SAFETY: handle is 0 or live; `req` outlives the call.
    let bytes = unsafe { read_and_free(zanshin_bookmarks(handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    if !env.ok() {
        let err = env.error().expect("error");
        return Err((
            err.code().unwrap_or_default().to_owned(),
            err.context().map(ToOwned::to_owned),
        ));
    }
    Ok(env
        .data_as_bookmarks()
        .and_then(|p| p.bookmarks())
        .map(|v| {
            v.iter()
                .map(|b| {
                    (
                        b.name().unwrap_or_default().to_owned(),
                        b.remote_name().map(ToOwned::to_owned),
                    )
                })
                .collect()
        })
        .unwrap_or_default())
}

/// Story 9.19: the reader refuses a null, malformed or mis-tagged buffer and an `Unspecified`
/// sort key with the `ffi.*` codes — before the handle rung, so a zero handle does not answer.
#[test]
fn bookmarks_reader_refuses_bad_buffers_before_the_handle() {
    test_helpers::pin_test_env();
    // SAFETY: a null buffer is the documented refusal.
    let bytes = unsafe { read_and_free(zanshin_bookmarks(0, std::ptr::null(), 0)) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_NULL_POINTER)
    );
    let garbage = [0xffu8; 3];
    assert_eq!(list(0, &garbage).expect_err("malformed").0, FFI_INVALID_ARGUMENT);
    let untagged = list_request(|_| fbs::BookmarkListRequestArgs::default());
    let (code, context) = list(0, &untagged).expect_err("untagged");
    assert_eq!(code, FFI_INVALID_ARGUMENT);
    assert!(context.unwrap_or_default().contains("BookmarkList"));
    let unspecified = list_request(|b| fbs::BookmarkListRequestArgs {
        kind: fbs::RequestKind::BookmarkList,
        sort: Some(b.create_vector(&[fbs::BookmarkSortKey::Unspecified])),
        ..Default::default()
    });
    let (code, context) = list(0, &unspecified).expect_err("unspecified key");
    assert_eq!(code, FFI_INVALID_ARGUMENT);
    assert!(context.unwrap_or_default().contains("sort key"));
    // A well-formed buffer reaches the handle rung.
    let ok = crate::bookmark_list_request(false);
    assert_eq!(list(0, &ok).expect_err("zero handle").0, FFI_INVALID_HANDLE);
}

/// Story 9.19: the default request is the CLI's default row set, a filter changes it, a sort key
/// reorders it, and `--all-remotes` with `--tracked` is clap's conflict.
#[test]
fn bookmarks_request_filters_and_sorts_the_rows() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let parent = add_commit_off_root(&fx.path, "parent");
    let child = add_commit_with_files(&fx.path, &[&parent], &[("child.txt", "child")], "child");
    set_local_bookmark(&fx.path, "f", &[&parent]);
    set_remote_bookmark(&fx.path, "f", "origin", &child, true);
    set_local_bookmark(&fx.path, "g", &[&child]);
    set_remote_bookmark(&fx.path, "u", "origin", &child, false);
    set_local_bookmark(&fx.path, "k", &[&parent, &child]);
    let path_cstr = cstr(fx.path.to_str().expect("fixture path must be valid UTF-8"));
    let open_bytes = unsafe { read_and_free(zanshin_repo_open(path_cstr.as_ptr())) };
    let handle = parse_envelope(&open_bytes)
        .data_as_repo_handle()
        .expect("repo handle")
        .handle();
    let row = |name: &str, remote: Option<&str>| (name.to_owned(), remote.map(ToOwned::to_owned));

    let default = crate::bookmark_list_request(false);
    assert_eq!(
        list(handle, &default).expect("default"),
        [row("f", None), row("f", Some("origin")), row("g", None), row("k", None)]
    );
    let all = crate::bookmark_list_request(true);
    assert_eq!(
        list(handle, &all).expect("all remotes"),
        [
            row("f", None),
            row("f", Some("origin")),
            row("g", None),
            row("k", None),
            row("u", Some("origin"))
        ]
    );
    let names = list_request(|b| {
        let g = b.create_string("g");
        fbs::BookmarkListRequestArgs {
            kind: fbs::RequestKind::BookmarkList,
            names: Some(b.create_vector(&[g])),
            ..Default::default()
        }
    });
    assert_eq!(list(handle, &names).expect("names"), [row("g", None)]);
    let desc = list_request(|b| fbs::BookmarkListRequestArgs {
        kind: fbs::RequestKind::BookmarkList,
        sort: Some(b.create_vector(&[fbs::BookmarkSortKey::NameDesc])),
        ..Default::default()
    });
    assert_eq!(
        list(handle, &desc).expect("name-"),
        [row("k", None), row("g", None), row("f", None), row("f", Some("origin"))]
    );
    // `revisions` (local targets in `child`: `g`, and `k` by its second add), `remotes` (the
    // untracked `u@origin` joins) and `conflicted` each change the row set.
    let revisions = list_request(|b| {
        let child = b.create_string(&child);
        fbs::BookmarkListRequestArgs {
            kind: fbs::RequestKind::BookmarkList,
            revisions: Some(b.create_vector(&[child])),
            ..Default::default()
        }
    });
    assert_eq!(
        list(handle, &revisions).expect("revisions"),
        [row("g", None), row("k", None)]
    );
    let remotes = list_request(|b| {
        let origin = b.create_string("origin");
        fbs::BookmarkListRequestArgs {
            kind: fbs::RequestKind::BookmarkList,
            remotes: Some(b.create_vector(&[origin])),
            ..Default::default()
        }
    });
    assert_eq!(
        list(handle, &remotes).expect("remotes"),
        [row("f", None), row("f", Some("origin")), row("u", Some("origin"))]
    );
    let conflicted = list_request(|_| fbs::BookmarkListRequestArgs {
        kind: fbs::RequestKind::BookmarkList,
        conflicted: true,
        ..Default::default()
    });
    assert_eq!(list(handle, &conflicted).expect("conflicted"), [row("k", None)]);
    let conflict = list_request(|_| fbs::BookmarkListRequestArgs {
        kind: fbs::RequestKind::BookmarkList,
        all_remotes: true,
        tracked: true,
        ..Default::default()
    });
    let (code, context) = list(handle, &conflict).expect_err("clap conflict");
    assert_eq!(code, JJ_INVALID_INPUT);
    assert_eq!(
        context.as_deref(),
        Some("the argument '--all-remotes' cannot be used with '--tracked'")
    );

    let close_bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");
}
