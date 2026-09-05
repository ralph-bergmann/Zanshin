// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.4's four file-read wrappers (`zanshin_file_list`,
//! `zanshin_file_show`, `zanshin_file_annotate`, `zanshin_file_search`).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the
//! Verifier — a wrong-shape payload is a compile error, not a runtime assert. Every token is
//! freed via `zanshin_buffer_free_token` so the suite is leak-clean.
//!
//! Mirrors `tests/repo_write_ffi.rs`'s scaffolding for the handle/envelope helpers and its
//! request-buffer builders. Each happy path asserts the verb's DISTINGUISHING data, not
//! merely a well-formed envelope, and `paths` / `name_only` / a non-default `revision` are
//! each carried through the buffer at least once, so a reader that hardcoded one would fail.

use std::ffi::CString;
use std::path::Path;
use std::sync::LazyLock;
use std::{env, fs};

use flatbuffers::root as fb_root;
use test_helpers::{add_commit_with_entries, extract_fixture, Entry};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::file::{zanshin_file_annotate, zanshin_file_list, zanshin_file_search, zanshin_file_show};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CHANGE_NOT_FOUND, JJ_CONFIG_ERROR, JJ_INVALID_INPUT,
    JJ_NOT_A_FILE, JJ_PATH_NOT_FOUND,
};
use zanshin_jj::{resolve_revset, Repo};

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: mirrors tests/repo_write_ffi.rs — an empty string makes jj-lib find no config at
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
/// `token` must be a valid, non-null `ZanshinBuf` produced by one of the `zanshin_*`
/// functions and not yet freed.
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

/// A `FileListRequest`/`FileShowRequest`-shaped buffer. A `None` revision is left ABSENT —
/// the wire form of "the user did not supply it", which selects the CLI's `@` default.
fn list_request_bytes(revision: Option<&str>, paths: &[&str], show: bool) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let revision_off = revision.map(|s| b.create_string(s));
    let path_offs: Vec<_> = paths.iter().map(|s| b.create_string(s)).collect();
    let paths_vec = b.create_vector(&path_offs);
    if show {
        let req = fbs::FileShowRequest::create(
            &mut b,
            &fbs::FileShowRequestArgs {
                revision: revision_off,
                paths: Some(paths_vec),
            },
        );
        b.finish(req, None);
    } else {
        let req = fbs::FileListRequest::create(
            &mut b,
            &fbs::FileListRequestArgs {
                revision: revision_off,
                paths: Some(paths_vec),
            },
        );
        b.finish(req, None);
    }
    b.finished_data().to_vec()
}

fn annotate_request_bytes(revision: Option<&str>, path: &str) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let revision_off = revision.map(|s| b.create_string(s));
    let path_off = b.create_string(path);
    let req = fbs::FileAnnotateRequest::create(
        &mut b,
        &fbs::FileAnnotateRequestArgs {
            revision: revision_off,
            path: Some(path_off),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `FileAnnotateRequest` whose `path` field is ABSENT from the buffer — the wire form of
/// "the caller omitted a required argument", which is NOT an explicitly empty string.
fn annotate_request_without_path() -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
    let req = fbs::FileAnnotateRequest::create(
        &mut b,
        &fbs::FileAnnotateRequestArgs {
            revision: None,
            path: None,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `FileSearchRequest` whose `pattern` field is ABSENT from the buffer.
fn search_request_without_pattern() -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
    let req = fbs::FileSearchRequest::create(
        &mut b,
        &fbs::FileSearchRequestArgs {
            revision: None,
            pattern: None,
            paths: None,
            name_only: false,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn search_request_bytes(revision: Option<&str>, pattern: &str, paths: &[&str], name_only: bool) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let revision_off = revision.map(|s| b.create_string(s));
    let pattern_off = b.create_string(pattern);
    let path_offs: Vec<_> = paths.iter().map(|s| b.create_string(s)).collect();
    let paths_vec = b.create_vector(&path_offs);
    let req = fbs::FileSearchRequest::create(
        &mut b,
        &fbs::FileSearchRequestArgs {
            revision: revision_off,
            pattern: Some(pattern_off),
            paths: Some(paths_vec),
            name_only,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

// ── Scenario ──────────────────────────────────────────────────────────────────

/// A fixture whose extra commit holds a plain file, a nested directory, an executable and a
/// symlink — the committed fixtures contain none of those, and regenerating them is
/// forbidden. Returns `(handle, change id of that commit)`; the caller must close the handle.
///
/// The `FixtureHandle` is leaked so its `TempDir` outlives the returned raw handle, exactly
/// as `repo_write_ffi.rs::open_fixture_and_get_wc_change_id` does.
fn open_scenario() -> (u64, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let commit_hex = add_commit_with_entries(
        &fixture.path,
        &[],
        &[
            ("a.txt", Entry::File("alpha\nneedle here\nneedle twice\n")),
            ("dir/b.txt", Entry::File("beta\n")),
            ("run.sh", Entry::Executable("#!/bin/sh\n")),
            ("link", Entry::Symlink("a.txt")),
        ],
        "ffi scenario",
    );
    let change_id = change_id_for_commit(&fixture.path, &commit_hex);
    let handle = open_handle(&fixture.path);
    std::mem::forget(fixture);
    (handle, change_id)
}

// ── zanshin_file_list ─────────────────────────────────────────────────────────

#[test]
fn file_list_round_trip_carries_type_and_executable_bit() {
    pin_env();
    let (handle, change_id) = open_scenario();

    // A NON-DEFAULT revision and a path filter both cross through the request buffer.
    let req = list_request_bytes(Some(&change_id), &["dir"], false);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_list(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "error: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::FileList);
    let entries = env
        .data_as_file_list()
        .expect("FileList payload")
        .entries()
        .expect("entries present");
    assert_eq!(entries.len(), 1, "the path filter must reach jj — 'dir' holds one file");
    assert_eq!(entries.get(0).path(), Some("dir/b.txt"));

    // Unfiltered: the executable bit and the symlink type must survive the wire.
    let req = list_request_bytes(Some(&change_id), &[], false);
    // SAFETY: see above.
    let token = unsafe { zanshin_file_list(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    let entries = env
        .data_as_file_list()
        .expect("FileList payload")
        .entries()
        .expect("entries present");
    let mut saw_exec = false;
    let mut saw_link = false;
    for i in 0..entries.len() {
        let e = entries.get(i);
        if e.path() == Some("run.sh") {
            saw_exec = e.executable() && e.file_type() == fbs::FileType::File;
        }
        if e.path() == Some("link") {
            saw_link = e.file_type() == fbs::FileType::Symlink && !e.executable();
        }
    }
    assert!(saw_exec, "the executable file must arrive with executable == true");
    assert!(saw_link, "the symlink must arrive with file_type == Symlink");

    close_handle(handle);
}

#[test]
fn file_list_rejects_a_null_request_a_garbage_request_and_a_zero_handle() {
    pin_env();
    let (handle, _) = open_scenario();

    // SAFETY: a null `data` is exactly the case under test; the wrapper checks before any
    // dereference.
    let token = unsafe { zanshin_file_list(handle, std::ptr::null(), 0) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    let garbage = [0xff_u8; 16];
    // SAFETY: garbage is a live buffer; verification is what is under test.
    let token = unsafe { zanshin_file_list(handle, garbage.as_ptr(), garbage.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));

    let req = list_request_bytes(None, &[], false);
    // SAFETY: handle 0 is the null-handle case the wrapper detects.
    let token = unsafe { zanshin_file_list(0, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_HANDLE));
    // The borrow routes through `envelope::session_from_handle`, whose refusal
    // carries no context — pinned so a wrapper cannot start decorating it.
    assert!(
        env.error().and_then(|e| e.context()).is_none(),
        "the invalid-handle envelope carries no context"
    );

    close_handle(handle);
}

#[test]
fn file_list_with_a_bogus_revision_returns_jj_change_not_found() {
    pin_env();
    let (handle, _) = open_scenario();

    let req = list_request_bytes(Some("not-reverse-hex!"), &[], false);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_list(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CHANGE_NOT_FOUND));
    close_handle(handle);
}

// ── zanshin_file_show ─────────────────────────────────────────────────────────

#[test]
fn file_show_round_trip_carries_bytes_and_skipped_paths() {
    pin_env();
    let (handle, change_id) = open_scenario();

    let req = list_request_bytes(Some(&change_id), &["a.txt", "link"], true);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_show(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "error: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::FileContents);
    let payload = env.data_as_file_contents().expect("FileContents payload");

    let files = payload.files().expect("files present");
    assert_eq!(files.len(), 1, "only a.txt is renderable content");
    assert_eq!(files.get(0).path(), Some("a.txt"));
    assert_eq!(
        files.get(0).content().map(|c| c.bytes().to_vec()),
        Some(b"alpha\nneedle here\nneedle twice\n".to_vec()),
        "the exact bytes must survive the wire"
    );

    let skipped = payload.skipped().expect("skipped present");
    assert_eq!(skipped.len(), 1, "the symlink is skipped, not a refusal");
    assert_eq!(skipped.get(0).path(), Some("link"));

    close_handle(handle);
}

#[test]
fn file_show_surfaces_path_not_found_and_invalid_input() {
    pin_env();
    let (handle, change_id) = open_scenario();

    let req = list_request_bytes(Some(&change_id), &["nope.txt"], true);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_show(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_PATH_NOT_FOUND));
    assert_eq!(
        env.error().and_then(|e| e.context()),
        Some("nope.txt"),
        "user data rides in context, never in code"
    );

    // Empty paths — the CLI marks FILESETS required.
    let req = list_request_bytes(Some(&change_id), &[], true);
    // SAFETY: see above.
    let token = unsafe { zanshin_file_show(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));

    close_handle(handle);
}

/// `file show` is the ONE file read that consults the repo's effective jj config, so it is
/// also the only one that can answer `jj.config_error`. Pinned at the FFI layer because
/// `map_file_err`'s `Config` arm has no other crossing: every other test in this file drives
/// a repo whose config is fine, and a code that never crosses the boundary in a test is a
/// code a GUI cannot rely on.
#[test]
fn file_show_surfaces_a_malformed_conflict_marker_style_as_jj_config_error() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let commit_hex = add_commit_with_entries(
        &fixture.path,
        &[],
        &[("a.txt", Entry::File("alpha\n"))],
        "config-error scenario",
    );
    let change_id = change_id_for_commit(&fixture.path, &commit_hex);
    // Not one of jj's four style names: the USER's config is wrong, not the repository.
    fs::write(
        fixture.path.join(".jj").join("repo").join("config.toml"),
        "[ui]\nconflict-marker-style = \"nonsense\"\n",
    )
    .expect("repo config must be writable");
    let handle = open_handle(&fixture.path);
    std::mem::forget(fixture);

    let req = list_request_bytes(Some(&change_id), &["a.txt"], true);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_show(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CONFIG_ERROR));

    close_handle(handle);
}

#[test]
fn file_show_rejects_a_null_request_a_garbage_request_and_a_zero_handle() {
    pin_env();
    let (handle, _) = open_scenario();

    // SAFETY: a null `data` is the case under test.
    let token = unsafe { zanshin_file_show(handle, std::ptr::null(), 0) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_NULL_POINTER)
    );

    let garbage = [0xff_u8; 16];
    // SAFETY: garbage is a live buffer; verification is under test.
    let token = unsafe { zanshin_file_show(handle, garbage.as_ptr(), garbage.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_ARGUMENT)
    );

    let req = list_request_bytes(None, &["a.txt"], true);
    // SAFETY: handle 0 is the null-handle case.
    let token = unsafe { zanshin_file_show(0, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );
    // The borrow routes through `envelope::session_from_handle`, whose refusal
    // carries no context — pinned so a wrapper cannot start decorating it.
    assert!(
        parse_envelope(&bytes).error().and_then(|e| e.context()).is_none(),
        "the invalid-handle envelope carries no context"
    );

    close_handle(handle);
}

// ── zanshin_file_annotate ─────────────────────────────────────────────────────

#[test]
fn file_annotate_round_trip_carries_ids_and_line_numbers() {
    pin_env();
    let (handle, change_id) = open_scenario();

    let req = annotate_request_bytes(Some(&change_id), "a.txt");
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_annotate(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "error: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::FileAnnotation);
    let lines = env
        .data_as_file_annotation()
        .expect("FileAnnotation payload")
        .lines()
        .expect("lines present");

    assert_eq!(lines.len(), 3, "one entry per line of a.txt");
    assert_eq!(
        lines.get(0).change_id(),
        Some(change_id.as_str()),
        "the file was introduced by this very commit"
    );
    assert!(
        lines.get(0).commit_id().is_some_and(|c| !c.is_empty()),
        "the commit id must be populated"
    );
    assert_eq!(lines.get(0).original_line_number(), 1, "line numbers are 1-based");
    assert_eq!(lines.get(2).original_line_number(), 3);
    assert_eq!(
        lines.get(1).content().map(|c| c.bytes().to_vec()),
        Some(b"needle here\n".to_vec())
    );

    close_handle(handle);
}

#[test]
fn file_annotate_surfaces_not_a_file_and_the_three_ffi_guards() {
    pin_env();
    let (handle, change_id) = open_scenario();

    let req = annotate_request_bytes(Some(&change_id), "dir");
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_annotate(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_NOT_A_FILE));
    assert_eq!(env.error().and_then(|e| e.context()), Some("dir"));

    let req = annotate_request_bytes(Some("not-reverse-hex!"), "a.txt");
    // SAFETY: see above.
    let token = unsafe { zanshin_file_annotate(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND)
    );

    // SAFETY: a null `data` is the case under test.
    let token = unsafe { zanshin_file_annotate(handle, std::ptr::null(), 0) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_NULL_POINTER)
    );

    let garbage = [0xff_u8; 16];
    // SAFETY: garbage is a live buffer; verification is under test.
    let token = unsafe { zanshin_file_annotate(handle, garbage.as_ptr(), garbage.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_ARGUMENT)
    );

    let req = annotate_request_bytes(None, "a.txt");
    // SAFETY: handle 0 is the null-handle case.
    let token = unsafe { zanshin_file_annotate(0, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );
    // The borrow routes through `envelope::session_from_handle`, whose refusal
    // carries no context — pinned so a wrapper cannot start decorating it.
    assert!(
        parse_envelope(&bytes).error().and_then(|e| e.context()).is_none(),
        "the invalid-handle envelope carries no context"
    );

    close_handle(handle);
}

#[test]
fn file_annotate_refuses_an_absent_path_field() {
    pin_env();
    let (handle, _) = open_scenario();

    // The CLI's positional `path` is required, and argument arity is observable behavior —
    // an omitted field must be NAMED, not silently defaulted to the empty string.
    let req = annotate_request_without_path();
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_annotate(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));
    assert_eq!(
        env.error().and_then(|e| e.context()),
        Some("path is required"),
        "the refusal must name the missing field"
    );

    close_handle(handle);
}

// ── zanshin_file_search ───────────────────────────────────────────────────────

#[test]
fn file_search_round_trip_carries_name_only_and_the_path_filter() {
    pin_env();
    let (handle, change_id) = open_scenario();

    // Two matching lines in a.txt, none anywhere else.
    let req = search_request_bytes(Some(&change_id), "needle", &[], false);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_search(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "error: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::FileSearch);
    let payload = env.data_as_file_search().expect("FileSearch payload");
    assert_eq!(
        payload.skipped().map_or(0, |s| s.len()),
        0,
        "nothing was unreadable, so `skipped` is present and EMPTY — that is what makes \
         \"no match\" distinguishable from \"blob unreadable\""
    );
    let matches = payload.matches().expect("matches present");
    assert_eq!(matches.len(), 2);
    assert_eq!(matches.get(0).path(), Some("a.txt"));
    assert_eq!(matches.get(0).line_number(), 2, "line numbers are 1-based");
    assert!(
        !matches.get(0).has_conflict_side(),
        "a resolved file carries no conflict side"
    );

    // name_only must reach jj — a reader that hardcoded `false` would still report 2.
    let req = search_request_bytes(Some(&change_id), "needle", &[], true);
    // SAFETY: see above.
    let token = unsafe { zanshin_file_search(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    let matches = env
        .data_as_file_search()
        .expect("FileSearch payload")
        .matches()
        .expect("matches present");
    assert_eq!(matches.len(), 1, "name_only stops the file at its first match");

    // A path filter that excludes the only matching file.
    let req = search_request_bytes(Some(&change_id), "needle", &["dir"], false);
    // SAFETY: see above.
    let token = unsafe { zanshin_file_search(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "an empty result is a success");
    assert_eq!(
        env.data_as_file_search()
            .expect("FileSearch payload")
            .matches()
            .map_or(0, |m| m.len()),
        0,
        "the path filter must reach jj"
    );

    close_handle(handle);
}

#[test]
fn file_search_surfaces_invalid_input_and_the_three_ffi_guards() {
    pin_env();
    let (handle, change_id) = open_scenario();

    let req = search_request_bytes(Some(&change_id), "(", &[], false);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_search(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));

    let req = search_request_bytes(Some("not-reverse-hex!"), "needle", &[], false);
    // SAFETY: see above.
    let token = unsafe { zanshin_file_search(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND)
    );

    // SAFETY: a null `data` is the case under test.
    let token = unsafe { zanshin_file_search(handle, std::ptr::null(), 0) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_NULL_POINTER)
    );

    let garbage = [0xff_u8; 16];
    // SAFETY: garbage is a live buffer; verification is under test.
    let token = unsafe { zanshin_file_search(handle, garbage.as_ptr(), garbage.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_ARGUMENT)
    );

    let req = search_request_bytes(None, "needle", &[], false);
    // SAFETY: handle 0 is the null-handle case.
    let token = unsafe { zanshin_file_search(0, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );
    // The borrow routes through `envelope::session_from_handle`, whose refusal
    // carries no context — pinned so a wrapper cannot start decorating it.
    assert!(
        parse_envelope(&bytes).error().and_then(|e| e.context()).is_none(),
        "the invalid-handle envelope carries no context"
    );

    close_handle(handle);
}

#[test]
fn file_search_refuses_an_absent_pattern_but_honours_an_explicitly_empty_one() {
    pin_env();
    let (handle, change_id) = open_scenario();

    // ABSENT: the CLI marks `-p/--pattern` `required = true`, so an omitted field is named.
    let req = search_request_without_pattern();
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_file_search(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));
    assert_eq!(
        env.error().and_then(|e| e.context()),
        Some("pattern is required"),
        "the refusal must name the missing field"
    );

    // PRESENT but empty: a VALUE, not an absence. `jj file search -p ""` is the empty regex,
    // which matches every line — the scenario's three files hold 3 + 1 + 1 lines, and the
    // symlink is never searched.
    let req = search_request_bytes(Some(&change_id), "", &[], false);
    // SAFETY: see above.
    let token = unsafe { zanshin_file_search(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "error: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(
        env.data_as_file_search()
            .expect("FileSearch payload")
            .matches()
            .map_or(0, |m| m.len()),
        5,
        "an empty regex matches every line of every searchable file"
    );

    close_handle(handle);
}

// ── Op-log invariant across the whole wrapper layer ───────────────────────────

#[test]
fn no_file_read_wrapper_writes_an_operation() {
    pin_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let commit_hex = add_commit_with_entries(
        &fixture.path,
        &[],
        &[("a.txt", Entry::File("needle\n")), ("link", Entry::Symlink("a.txt"))],
        "op-log invariant scenario",
    );
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
    for (req, call) in [
        (
            list_request_bytes(Some(&change_id), &[], false),
            zanshin_file_list as unsafe extern "C" fn(u64, *const u8, usize) -> *mut ZanshinBuf,
        ),
        (
            list_request_bytes(Some(&change_id), &["a.txt"], true),
            zanshin_file_show,
        ),
        (annotate_request_bytes(Some(&change_id), "a.txt"), zanshin_file_annotate),
        (
            search_request_bytes(Some(&change_id), "needle", &[], false),
            zanshin_file_search,
        ),
    ] {
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { call(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is the fresh, non-null token the call just returned.
        let bytes = unsafe { read_and_free(token) };
        assert!(parse_envelope(&bytes).ok(), "each verb must succeed");
    }
    // And once more on a REFUSAL: an absent path for show, a bogus revision for the rest.
    for (req, call) in [
        (
            list_request_bytes(Some("not-reverse-hex!"), &[], false),
            zanshin_file_list as unsafe extern "C" fn(u64, *const u8, usize) -> *mut ZanshinBuf,
        ),
        (
            list_request_bytes(Some(&change_id), &["nope.txt"], true),
            zanshin_file_show,
        ),
        (annotate_request_bytes(Some(&change_id), "link"), zanshin_file_annotate),
        (
            search_request_bytes(Some(&change_id), "(", &[], false),
            zanshin_file_search,
        ),
    ] {
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { call(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is the fresh, non-null token the call just returned.
        let bytes = unsafe { read_and_free(token) };
        assert!(!parse_envelope(&bytes).ok(), "each refusal must be an error envelope");
    }
    close_handle(handle);

    let mut after: Vec<String> = fs::read_dir(&op_heads)
        .expect("op heads dir")
        .map(|e| e.expect("dir entry").file_name().to_string_lossy().into_owned())
        .collect();
    after.sort();
    assert_eq!(before, after, "a read never writes an operation, success or refusal");
}
