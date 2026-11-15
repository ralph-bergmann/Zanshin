// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.59's tag wrappers: the list `zanshin_tags` and the verbs
//! `zanshin_tag_set`, `_delete`, `_track` and `_untrack`.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier, and
//! every token is freed via `zanshin_buffer_free_token`. The jj-level behaviour is pinned in
//! `crates/zanshin-jj/tests/it/tag_ops.rs`; what is tested here is the wire contract: the readers
//! and their kind tags, the handle and buffer guards, the error codes and warnings as they come
//! back over the envelope, and the `Tags` payload.

use std::ffi::CString;
use std::fs;

use flatbuffers::root as fb_root;
use test_helpers::{extract_fixture, set_remote_tag, set_tag};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::op_log::zanshin_op_log;
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::tags::{zanshin_tag_delete, zanshin_tag_set, zanshin_tag_track, zanshin_tag_untrack, zanshin_tags};
use zanshin_ffi::{FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_INVALID_INPUT};

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` not yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// The request-buffer wrapper shape the four verbs share.
type BufWrapper = unsafe extern "C" fn(u64, *const u8, usize) -> *mut ZanshinBuf;

fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

/// Extract `tiny-3-commits` (a non-colocated Git-backed repo), open it, and return `(handle,
/// root)`. The `FixtureHandle` is leaked so its `TempDir` outlives the raw handle.
fn open_fixture() -> (u64, std::path::PathBuf) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let root = fs::canonicalize(&fixture.path).expect("fixture root exists");
    let p = CString::new(root.to_str().expect("UTF-8 path")).expect("no NUL");
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_repo_open(p.as_ptr())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "open: {:?}", env.error().and_then(|e| e.code()));
    let handle = env.data_as_repo_handle().expect("RepoHandle").handle();
    std::mem::forget(fixture);
    (handle, root)
}

fn close_handle(handle: u64) {
    // SAFETY: handle came from open_fixture and is not closed yet.
    let bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(parse_envelope(&bytes).ok(), "repo close must succeed");
}

/// Calls `wrapper` and returns the envelope bytes.
fn call(wrapper: BufWrapper, handle: u64, req: &[u8]) -> Vec<u8> {
    // SAFETY: the handle is live or the documented null handle; the buffer outlives the call.
    unsafe { read_and_free(wrapper(handle, req.as_ptr(), req.len())) }
}

/// The head operation's `(id, description)`, read back through the op-log wrapper.
fn head_op(handle: u64) -> (String, String) {
    // SAFETY: handle is live; -1 means "no limit".
    let bytes = unsafe { read_and_free(zanshin_op_log(handle, -1)) };
    let env = parse_envelope(&bytes);
    let head = env
        .data_as_op_log()
        .expect("OpLog")
        .operations()
        .expect("operations")
        .get(0);
    (
        head.id().expect("id").to_owned(),
        head.description().unwrap_or_default().to_owned(),
    )
}

/// The rows `zanshin_tags` lists, as `(name, kind, remote, target, tracked, synced)`.
type Row = (String, fbs::TagKind, Option<String>, Option<String>, bool, bool);

fn tag_rows(handle: u64) -> Vec<Row> {
    // SAFETY: handle is live.
    let bytes = unsafe { read_and_free(zanshin_tags(handle)) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "tags: {:?}", env.error().and_then(|e| e.context()));
    assert_eq!(env.data_type(), fbs::Payload::Tags);
    env.data_as_tags()
        .expect("Tags payload")
        .tags()
        .expect("tags vector")
        .iter()
        .map(|t| {
            (
                t.name().unwrap_or_default().to_owned(),
                t.kind(),
                t.remote_name().map(ToOwned::to_owned),
                t.target().map(ToOwned::to_owned),
                t.tracked(),
                t.synced(),
            )
        })
        .collect()
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
    assert_eq!(op, head_op(handle).0);
}

/// A string vector, or ABSENT for `None`.
fn strings<'a>(
    b: &mut flatbuffers::FlatBufferBuilder<'a>,
    list: Option<&[&str]>,
) -> Option<flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<&'a str>>>> {
    list.map(|items| {
        let offsets: Vec<_> = items.iter().map(|s| b.create_string(s)).collect();
        b.create_vector(&offsets)
    })
}

fn set_request(names: Option<&[&str]>, revision: Option<&str>, allow_move: bool) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let names = strings(&mut b, names);
    let revision = revision.map(|s| b.create_string(s));
    let req = fbs::TagSetRequest::create(
        &mut b,
        &fbs::TagSetRequestArgs {
            kind: fbs::RequestKind::TagSet,
            names,
            revision,
            allow_move,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn delete_request(names: Option<&[&str]>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let names = strings(&mut b, names);
    let req = fbs::TagDeleteRequest::create(
        &mut b,
        &fbs::TagDeleteRequestArgs {
            kind: fbs::RequestKind::TagDelete,
            names,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn track_request(kind: fbs::RequestKind, names: Option<&[&str]>, remotes: Option<&[&str]>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let names = strings(&mut b, names);
    let remotes = strings(&mut b, remotes);
    let req = fbs::TagTrackRequest::create(&mut b, &fbs::TagTrackRequestArgs { kind, names, remotes });
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// The guards of the four verbs: a zero handle answers after null and malformed buffers and a
/// buffer of another kind — a track buffer included, which `untrack` refuses (and vice versa). The
/// list refuses a zero handle.
#[test]
fn a_zero_handle_and_bad_buffers_are_refused_by_every_tag_wrapper() {
    test_helpers::pin_test_env();
    let track = track_request(fbs::RequestKind::TagTrack, Some(&["a"]), None);
    let untrack = track_request(fbs::RequestKind::TagUntrack, Some(&["a"]), None);
    let code = |bytes: &[u8]| {
        parse_envelope(bytes)
            .error()
            .and_then(|e| e.code())
            .map(ToOwned::to_owned)
    };
    for (wrapper, req, other) in [
        (
            zanshin_tag_set as BufWrapper,
            set_request(Some(&["a"]), None, false),
            delete_request(Some(&["a"])),
        ),
        (
            zanshin_tag_delete as BufWrapper,
            delete_request(Some(&["a"])),
            set_request(Some(&["a"]), None, false),
        ),
        (zanshin_tag_track as BufWrapper, track.clone(), untrack.clone()),
        (zanshin_tag_untrack as BufWrapper, untrack, track),
    ] {
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
    // SAFETY: the zero handle is the documented invalid-handle case.
    let bytes = unsafe { read_and_free(zanshin_tags(0)) };
    assert_eq!(code(&bytes).as_deref(), Some(FFI_INVALID_HANDLE));
}

/// `set` over the wire: `revision` absent (`@`), a refused move with its hint and no operation,
/// `allow_move`, and absent `names` (the jj layer's one refusal). The list reads the result back.
#[test]
fn set_round_trips_revision_and_allow_move_over_the_wire() {
    test_helpers::pin_test_env();
    let (handle, root) = open_fixture();
    assert_ok_at_head(
        handle,
        &call(zanshin_tag_set, handle, &set_request(Some(&["v1"]), None, false)),
    );
    assert!(head_op(handle).1.starts_with("set tag v1 to commit "));
    let rows = tag_rows(handle);
    assert_eq!(rows.len(), 1);
    let at = rows[0].3.clone().expect("a target");

    let g_hex = test_helpers::add_commit_off_root(&root, "g");
    set_tag(&root, "probe", &[&g_hex]);
    let g = tag_rows(handle)
        .into_iter()
        .find(|r| r.0 == "probe")
        .and_then(|r| r.3)
        .expect("probe target");
    set_tag(&root, "probe", &[]);

    let before = head_op(handle).0;
    let bytes = call(zanshin_tag_set, handle, &set_request(Some(&["v1"]), Some(&g), false));
    let error = parse_envelope(&bytes).error().expect("existing tag");
    assert_eq!(
        (error.code(), error.context()),
        (Some(JJ_INVALID_INPUT), Some("Refusing to move tag: v1"))
    );
    let hints: Vec<&str> = error.hints().expect("hints").iter().collect();
    assert_eq!(hints, ["Use --allow-move to update existing tags."]);
    assert_eq!(head_op(handle).0, before);
    assert_eq!(tag_rows(handle)[0].3.as_deref(), Some(at.as_str()));

    assert_ok_at_head(
        handle,
        &call(zanshin_tag_set, handle, &set_request(Some(&["v1"]), Some(&g), true)),
    );
    assert_eq!(
        tag_rows(handle),
        [("v1".to_owned(), fbs::TagKind::Local, None, Some(g), false, true)]
    );

    let bytes = call(zanshin_tag_set, handle, &set_request(None, None, false));
    let error = parse_envelope(&bytes).error().expect("no names");
    assert_eq!(
        (error.code(), error.context()),
        (Some(JJ_INVALID_INPUT), Some("tag set requires at least one name"))
    );
    close_handle(handle);
}

/// `delete` over the wire: a glob deletes the matches; an unmatched name warns
/// `jj.tag_names_unmatched` and writes nothing; absent names are refused.
#[test]
fn delete_round_trips_patterns_and_a_warning_over_the_wire() {
    test_helpers::pin_test_env();
    let (handle, root) = open_fixture();
    let g_hex = test_helpers::add_commit_off_root(&root, "g");
    for name in ["v1.0", "v1.1", "v2"] {
        set_tag(&root, name, &[&g_hex]);
    }
    assert_ok_at_head(
        handle,
        &call(zanshin_tag_delete, handle, &delete_request(Some(&["v1.*"]))),
    );
    assert_eq!(head_op(handle).1, "delete tag v1.0, v1.1");
    let names: Vec<String> = tag_rows(handle).into_iter().map(|r| r.0).collect();
    assert_eq!(names, ["v2"]);

    let before = head_op(handle).0;
    let bytes = call(zanshin_tag_delete, handle, &delete_request(Some(&["nope"])));
    let env = parse_envelope(&bytes);
    assert!(env.ok());
    assert_eq!(warning_codes(&env), ["jj.tag_names_unmatched"]);
    assert_eq!(
        env.data_as_mutation_result().and_then(|r| r.new_op_id()),
        Some(before.as_str()),
        "no operation"
    );

    let bytes = call(zanshin_tag_delete, handle, &delete_request(None));
    let error = parse_envelope(&bytes).error().expect("no names");
    assert_eq!(
        (error.code(), error.context()),
        (Some(JJ_INVALID_INPUT), Some("tag delete requires at least one name"))
    );
    close_handle(handle);
}

/// `track` / `untrack` over the wire: `remotes` limits a pattern to one remote; an already tracked
/// symbol warns; `untrack` untracks; `@git` warns and stays; mixed syntax is refused. The list
/// shows tracked and untracked remote rows and no `@git` row.
#[test]
fn track_and_untrack_round_trip_remotes_and_warnings_over_the_wire() {
    test_helpers::pin_test_env();
    let (handle, root) = open_fixture();
    let g_hex = test_helpers::add_commit_off_root(&root, "g");
    for remote in ["origin", "upstream"] {
        set_remote_tag(&root, "y", remote, &g_hex, false);
    }
    set_remote_tag(&root, "y", "git", &g_hex, true);

    let req = track_request(fbs::RequestKind::TagTrack, Some(&["y"]), Some(&["origin"]));
    assert_ok_at_head(handle, &call(zanshin_tag_track, handle, &req));
    assert_eq!(head_op(handle).1, "track remote tag y@origin");
    let rows: Vec<(fbs::TagKind, Option<String>, bool)> =
        tag_rows(handle).into_iter().map(|r| (r.1, r.2, r.4)).collect();
    assert_eq!(
        rows,
        [
            (fbs::TagKind::Local, None, false),
            (fbs::TagKind::Remote, Some("origin".to_owned()), true),
            (fbs::TagKind::Remote, Some("upstream".to_owned()), false),
        ],
        "no `@git` row"
    );

    let before = head_op(handle).0;
    let req = track_request(fbs::RequestKind::TagTrack, Some(&["y@origin"]), None);
    let bytes = call(zanshin_tag_track, handle, &req);
    let env = parse_envelope(&bytes);
    assert!(env.ok());
    assert_eq!(warning_codes(&env), ["jj.tag_already_tracked"]);
    assert_eq!(head_op(handle).0, before);

    let req = track_request(fbs::RequestKind::TagUntrack, Some(&["y@origin"]), None);
    assert_ok_at_head(handle, &call(zanshin_tag_untrack, handle, &req));
    assert_eq!(head_op(handle).1, "untrack remote tag y@origin");

    let before = head_op(handle).0;
    let req = track_request(fbs::RequestKind::TagUntrack, Some(&["y@git"]), None);
    let bytes = call(zanshin_tag_untrack, handle, &req);
    let env = parse_envelope(&bytes);
    assert!(env.ok());
    assert_eq!(warning_codes(&env), ["jj.tag_git_tracking_untrack"]);
    assert_eq!(head_op(handle).0, before);

    let req = track_request(fbs::RequestKind::TagUntrack, Some(&["y", "y@origin"]), None);
    let bytes = call(zanshin_tag_untrack, handle, &req);
    let error = parse_envelope(&bytes).error().expect("mixed");
    assert_eq!(
        (error.code(), error.context()),
        (
            Some(JJ_INVALID_INPUT),
            Some("Cannot specify both <tag> patterns and <tag>@<remote> symbols")
        )
    );
    close_handle(handle);
}
