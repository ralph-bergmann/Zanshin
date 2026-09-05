// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.5's six `zanshin_git_*` wrappers (`zanshin_git_import`,
//! `_export`, `_remote_add`, `_remote_remove`, `_remote_rename`, `_remote_set_url`).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the
//! Verifier — a wrong-shape payload is a compile error, not a runtime assert. Every token is
//! freed via `zanshin_buffer_free_token` so the suite is leak-clean. Mirrors
//! `tests/repo_write_ffi.rs`'s scaffolding for the handle/envelope helpers.
//!
//! Each happy path asserts the verb's DISTINGUISHING data, not merely a well-formed
//! envelope: the imported ref's name/kind/tracked flag, the exported failure's flattened
//! reason, the remote list after a config write. The three error codes Story 9.5 adds to
//! `repo.rs::map_mutate_err` (`jj.remote_exists`, `jj.remote_nonstandard_config`,
//! `jj.not_a_git_repo`) all cross the FFI boundary here — that file is pinned at 100 %
//! coverage, so an unexercised arm fails the ratchet.

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use flatbuffers::root as fb_root;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::git::{
    zanshin_git_export, zanshin_git_import, zanshin_git_remote_add, zanshin_git_remote_remove,
    zanshin_git_remote_rename, zanshin_git_remote_set_url,
};
use zanshin_ffi::remotes::zanshin_remotes;
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_init};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, FFI_UTF8_ERROR, JJ_CONFIG_ERROR, JJ_INVALID_INPUT,
    JJ_NOT_A_GIT_REPO, JJ_REMOTE_EXISTS, JJ_REMOTE_NONSTANDARD_CONFIG, JJ_REMOTE_NOT_FOUND,
};
use zanshin_jj::Repo;

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

// ── Envelope helpers (mirrors tests/repo_write_ffi.rs) ────────────────────────

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

/// Build a `GitRemoteAddRequest` buffer. A `None` `push_url` is left ABSENT — the wire form
/// of "push to the fetch URL".
fn add_request_bytes(name: Option<&str>, url: Option<&str>, push_url: Option<&str>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let name_off = name.map(|s| b.create_string(s));
    let url_off = url.map(|s| b.create_string(s));
    let push_off = push_url.map(|s| b.create_string(s));
    let req = fbs::GitRemoteAddRequest::create(
        &mut b,
        &fbs::GitRemoteAddRequestArgs {
            name: name_off,
            url: url_off,
            push_url: push_off,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Build a `GitRemoteSetUrlRequest` buffer; both URLs are null-for-absence.
fn set_url_request_bytes(name: Option<&str>, url: Option<&str>, push_url: Option<&str>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let name_off = name.map(|s| b.create_string(s));
    let url_off = url.map(|s| b.create_string(s));
    let push_off = push_url.map(|s| b.create_string(s));
    let req = fbs::GitRemoteSetUrlRequest::create(
        &mut b,
        &fbs::GitRemoteSetUrlRequestArgs {
            name: name_off,
            url: url_off,
            push_url: push_off,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Initialise a workspace at `path` (`backend`: 0 = native, 1 = git) and return its handle.
fn init_handle(path: &Path, backend: i32) -> u64 {
    let p = cstr(path.to_str().expect("path must be UTF-8"));
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let token = unsafe { zanshin_repo_init(p.as_ptr(), backend) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_init just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "init failed: {:?}", env.error().and_then(|e| e.code()));
    env.data_as_repo_handle()
        .expect("RepoHandle payload must be present")
        .handle()
}

fn close_handle(handle: u64) {
    // SAFETY: handle originated from init_handle and has not been closed.
    let token = unsafe { zanshin_repo_close(handle) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_close just returned.
    let bytes = unsafe { read_and_free(token) };
    assert!(parse_envelope(&bytes).ok(), "close must succeed");
}

/// Remote names as `zanshin_remotes` reports them for `handle`.
fn remote_names(handle: u64) -> Vec<String> {
    // SAFETY: handle is live for the duration of the call.
    let token = unsafe { zanshin_remotes(handle) };
    // SAFETY: token is the fresh, non-null token zanshin_remotes just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "remotes failed: {:?}", env.error().and_then(|e| e.code()));
    let payload = env.data_as_remotes().expect("Remotes payload");
    payload
        .remotes()
        .map(|v| v.iter().map(|r| r.name().unwrap_or_default().to_owned()).collect())
        .unwrap_or_default()
}

/// The error code of an envelope that must be an error.
fn error_code(bytes: &[u8]) -> String {
    let env = parse_envelope(bytes);
    assert!(!env.ok(), "expected an error envelope");
    env.error()
        .and_then(|e| e.code())
        .expect("an error envelope must carry a code")
        .to_owned()
}

/// Run a git command in `dir`; panics on non-zero exit.
fn git_cmd(args: &[&str], dir: &Path) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

fn git_store(root: &Path) -> PathBuf {
    root.join(".jj").join("repo").join("store").join("git")
}

// ── zanshin_git_import ────────────────────────────────────────────────────────

#[test]
fn git_import_happy_path_carries_the_changed_ref_across_the_boundary() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);
    close_handle(handle);

    // A commit jj knows plus a git ref jj has never seen.
    let commit = test_helpers::add_commit_off_root(tmp.path(), "importable");
    git_cmd(&["update-ref", "refs/heads/feature", &commit], &git_store(tmp.path()));

    let handle = init_handle_by_open(tmp.path());
    // SAFETY: handle is live for the duration of the call.
    let token = unsafe { zanshin_git_import(handle) };
    // SAFETY: token is the fresh, non-null token zanshin_git_import just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "import failed: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::GitImportResult);
    let p = env.data_as_git_import_result().expect("GitImportResult payload");
    assert!(
        p.mutation().and_then(|m| m.new_op_id()).is_some_and(|s| !s.is_empty()),
        "the nested MutationResult must carry the new op id"
    );
    let bookmarks = p.changed_bookmarks().expect("changed_bookmarks present");
    assert_eq!(bookmarks.len(), 1, "exactly the one ref that was added");
    assert_eq!(bookmarks.get(0).name(), Some("feature"));
    assert_eq!(bookmarks.get(0).remote(), Some("git"));
    assert_eq!(bookmarks.get(0).kind(), fbs::GitRefUpdateKind::New);
    assert!(bookmarks.get(0).tracked());
    assert!(p.failed_ref_names().is_some_and(|v| v.is_empty()));

    close_handle(handle);
}

/// The distinguishing failure for both sync verbs: no git backend at all. Proves the NEW
/// `MutateError::NotAGitRepo` arm of `map_mutate_err` crosses the boundary, and that it
/// carries NO `context` (there is no path to name).
#[test]
fn git_import_and_export_on_a_native_backend_return_jj_not_a_git_repo() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 0);

    // SAFETY: handle is live for the duration of the call.
    let import_bytes = unsafe { read_and_free(zanshin_git_import(handle)) };
    let env = parse_envelope(&import_bytes);
    assert!(!env.ok());
    let error = env.error().expect("error must be present");
    assert_eq!(error.code(), Some(JJ_NOT_A_GIT_REPO));
    assert!(
        error.context().is_none(),
        "the workspace-backend form of this code names no path"
    );

    // SAFETY: handle is live for the duration of the call.
    let export_bytes = unsafe { read_and_free(zanshin_git_export(handle)) };
    assert_eq!(error_code(&export_bytes), JJ_NOT_A_GIT_REPO);

    close_handle(handle);
}

#[test]
fn git_import_and_export_with_a_zero_handle_return_ffi_invalid_handle() {
    pin_env();
    // SAFETY: 0 is the documented null handle; both wrappers detect it.
    let import_bytes = unsafe { read_and_free(zanshin_git_import(0)) };
    assert_eq!(error_code(&import_bytes), FFI_INVALID_HANDLE);
    // SAFETY: see above.
    let export_bytes = unsafe { read_and_free(zanshin_git_export(0)) };
    assert_eq!(error_code(&export_bytes), FFI_INVALID_HANDLE);
}

/// `zanshin_git_import` is the only one of the six that reads config, so it is the only one
/// that can surface `jj.config_error` — proving the arm is reachable from this noun too.
#[test]
fn git_import_with_a_non_boolean_config_value_returns_jj_config_error() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);
    close_handle(handle);
    fs::write(
        tmp.path().join(".jj").join("repo").join("config.toml"),
        "[git]\nabandon-unreachable-commits = \"yes\"\n",
    )
    .expect("repo config must be writable");

    let handle = init_handle_by_open(tmp.path());
    // SAFETY: handle is live for the duration of the call.
    let bytes = unsafe { read_and_free(zanshin_git_import(handle)) };

    assert_eq!(error_code(&bytes), JJ_CONFIG_ERROR);
    close_handle(handle);
}

// ── zanshin_git_export ────────────────────────────────────────────────────────

#[test]
fn git_export_happy_path_carries_the_failure_list_across_the_boundary() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);
    close_handle(handle);

    // `foo` and `foo/bar` cannot both be git refs — the CLI's own hint case.
    let commit = test_helpers::add_commit_off_root(tmp.path(), "exportable");
    test_helpers::set_local_bookmark(tmp.path(), "foo", &[&commit]);
    test_helpers::set_local_bookmark(tmp.path(), "foo/bar", &[&commit]);

    let handle = init_handle_by_open(tmp.path());
    // SAFETY: handle is live for the duration of the call.
    let bytes = unsafe { read_and_free(zanshin_git_export(handle)) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "a failed ref is not an error envelope");
    assert_eq!(env.data_type(), fbs::Payload::GitExportResult);
    let p = env.data_as_git_export_result().expect("GitExportResult payload");
    assert!(p.mutation().and_then(|m| m.new_op_id()).is_some_and(|s| !s.is_empty()));
    let failed = p.failed_bookmarks().expect("failed_bookmarks present");
    assert_eq!(failed.len(), 1, "exactly one of the two names can survive");
    assert_eq!(failed.get(0).name(), Some("foo/bar"));
    assert_eq!(failed.get(0).remote(), Some("git"));
    assert!(
        failed.get(0).reason().is_some_and(|r| r.contains(": ")),
        "the reason must be the FLATTENED source chain: {:?}",
        failed.get(0).reason()
    );

    close_handle(handle);
}

// ── zanshin_git_remote_add ────────────────────────────────────────────────────

/// Carries BOTH a non-default url and a push url through the request buffer: a reader that
/// hardcoded either would fail here. Both are witnessed through the shipped read — the
/// `Remotes` payload now carries `push_url` — rather than a raw `git config` shell-out.
#[test]
fn git_remote_add_happy_path_carries_url_and_push_url_through_the_request_buffer() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let remote_dir = tempfile::TempDir::new().unwrap();
    let url = remote_dir.path().to_string_lossy().into_owned();
    let push = format!("{url}-push");
    let handle = init_handle(tmp.path(), 1);

    let req = add_request_bytes(Some("upstream"), Some(&url), Some(&push));
    // SAFETY: req outlives the call; Rust only borrows it.
    let bytes = unsafe { read_and_free(zanshin_git_remote_add(handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "add failed: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    assert_eq!(
        remote_names(handle),
        vec!["upstream".to_owned()],
        "the SAME handle must see the new remote — that is the reload this story adds"
    );

    let repo = Repo::open(tmp.path()).expect("reopen for the oracle");
    let listed = repo.list_remotes().expect("list_remotes");
    assert_eq!(listed.len(), 1);
    assert_eq!(
        listed[0].url, url,
        "the request buffer's url must reach jj-lib verbatim"
    );

    // SAFETY: handle is live for the duration of the call.
    let payload_bytes = unsafe { read_and_free(zanshin_remotes(handle)) };
    let env = parse_envelope(&payload_bytes);
    let remotes = env
        .data_as_remotes()
        .expect("Remotes payload")
        .remotes()
        .expect("remotes");
    assert_eq!(
        remotes.get(0).push_url(),
        Some(push.as_str()),
        "the request buffer's push_url must reach jj-lib too, and come back on the wire"
    );

    close_handle(handle);
}

/// The first of the three NEW `map_mutate_err` arms: a duplicate remote name.
#[test]
fn git_remote_add_duplicate_returns_jj_remote_exists() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);
    let req = add_request_bytes(Some("origin"), Some("/tmp/nowhere"), None);
    // SAFETY: req outlives the call.
    let first = unsafe { read_and_free(zanshin_git_remote_add(handle, req.as_ptr(), req.len())) };
    assert!(parse_envelope(&first).ok(), "the first add must succeed");

    // SAFETY: req outlives the call.
    let bytes = unsafe { read_and_free(zanshin_git_remote_add(handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_REMOTE_EXISTS));
    assert_eq!(
        env.error().and_then(|e| e.context()),
        Some("origin"),
        "user data rides `context`, never the code"
    );

    close_handle(handle);
}

#[test]
fn git_remote_add_rejects_a_null_buffer_garbage_and_a_missing_field() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);

    // SAFETY: a null `data` is the documented null-pointer case.
    let null_bytes = unsafe { read_and_free(zanshin_git_remote_add(handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&null_bytes), FFI_NULL_POINTER);

    let garbage = [0xff_u8; 16];
    // SAFETY: `garbage` outlives the call; it simply does not verify.
    let garbage_bytes = unsafe { read_and_free(zanshin_git_remote_add(handle, garbage.as_ptr(), garbage.len())) };
    assert_eq!(error_code(&garbage_bytes), FFI_INVALID_ARGUMENT);

    let no_url = add_request_bytes(Some("origin"), None, None);
    // SAFETY: no_url outlives the call.
    let missing_bytes = unsafe { read_and_free(zanshin_git_remote_add(handle, no_url.as_ptr(), no_url.len())) };
    assert_eq!(
        error_code(&missing_bytes),
        JJ_INVALID_INPUT,
        "an ABSENT required field is a caller bug, named as one"
    );

    // SAFETY: 0 is the documented null handle.
    let handle_bytes = unsafe { read_and_free(zanshin_git_remote_add(0, no_url.as_ptr(), no_url.len())) };
    assert_eq!(error_code(&handle_bytes), FFI_INVALID_HANDLE);

    close_handle(handle);
}

// ── zanshin_git_remote_remove ─────────────────────────────────────────────────

/// The happy path plus the second NEW arm: a remote added WITH a push url is refused by
/// jj-lib's own `remove_remote`, because `save_remote` wrote a `pushurl` key.
#[test]
fn git_remote_remove_happy_path_and_nonstandard_config_refusal() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);
    let plain = add_request_bytes(Some("plain"), Some("/tmp/nowhere"), None);
    // SAFETY: plain outlives the call.
    unsafe { read_and_free(zanshin_git_remote_add(handle, plain.as_ptr(), plain.len())) };
    let with_push = add_request_bytes(Some("pushy"), Some("/tmp/nowhere"), Some("/tmp/elsewhere"));
    // SAFETY: with_push outlives the call.
    unsafe { read_and_free(zanshin_git_remote_add(handle, with_push.as_ptr(), with_push.len())) };

    let plain_name = cstr("plain");
    // SAFETY: plain_name is a valid NUL-terminated C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_git_remote_remove(handle, plain_name.as_ptr())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "remove failed: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    assert_eq!(
        remote_names(handle),
        vec!["pushy".to_owned()],
        "the SAME handle must see the removal"
    );

    let pushy_name = cstr("pushy");
    // SAFETY: pushy_name is a valid NUL-terminated C string alive for the call.
    let refused = unsafe { read_and_free(zanshin_git_remote_remove(handle, pushy_name.as_ptr())) };
    let env = parse_envelope(&refused);
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_REMOTE_NONSTANDARD_CONFIG));
    assert_eq!(env.error().and_then(|e| e.context()), Some("pushy"));

    close_handle(handle);
}

#[test]
fn git_remote_remove_rejects_a_null_name_and_a_zero_handle() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);

    // SAFETY: a null `name` is the documented null-pointer case.
    let null_bytes = unsafe { read_and_free(zanshin_git_remote_remove(handle, std::ptr::null())) };
    assert_eq!(error_code(&null_bytes), FFI_NULL_POINTER);

    let name = cstr("nonexistent");
    // SAFETY: 0 is the documented null handle.
    let handle_bytes = unsafe { read_and_free(zanshin_git_remote_remove(0, name.as_ptr())) };
    assert_eq!(error_code(&handle_bytes), FFI_INVALID_HANDLE);

    // SAFETY: name is a valid NUL-terminated C string alive for the call.
    let missing_bytes = unsafe { read_and_free(zanshin_git_remote_remove(handle, name.as_ptr())) };
    assert_eq!(error_code(&missing_bytes), JJ_REMOTE_NOT_FOUND);

    close_handle(handle);
}

// ── zanshin_git_remote_rename ─────────────────────────────────────────────────

#[test]
fn git_remote_rename_happy_path_and_reserved_new_name_refusal() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);
    let req = add_request_bytes(Some("origin"), Some("/tmp/nowhere"), None);
    // SAFETY: req outlives the call.
    unsafe { read_and_free(zanshin_git_remote_add(handle, req.as_ptr(), req.len())) };

    let old = cstr("origin");
    let new = cstr("upstream");
    // SAFETY: both are valid NUL-terminated C strings alive for the call.
    let bytes = unsafe { read_and_free(zanshin_git_remote_rename(handle, old.as_ptr(), new.as_ptr())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "rename failed: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    assert_eq!(
        remote_names(handle),
        vec!["upstream".to_owned()],
        "the SAME handle must see the rename"
    );

    // jj-lib validates the NEW name before the OLD one's existence, so this is
    // `jj.invalid_input`, not `jj.remote_not_found`.
    let missing = cstr("nonexistent");
    let reserved = cstr("git");
    // SAFETY: both are valid NUL-terminated C strings alive for the call.
    let refused = unsafe { read_and_free(zanshin_git_remote_rename(handle, missing.as_ptr(), reserved.as_ptr())) };
    assert_eq!(error_code(&refused), JJ_INVALID_INPUT);

    close_handle(handle);
}

#[test]
fn git_remote_rename_rejects_a_null_name_and_a_zero_handle() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);
    let name = cstr("origin");

    // SAFETY: a null OLD name is the documented null-pointer case.
    let null_old = unsafe { read_and_free(zanshin_git_remote_rename(handle, std::ptr::null(), name.as_ptr())) };
    assert_eq!(error_code(&null_old), FFI_NULL_POINTER);

    // SAFETY: a null NEW name is likewise refused, after the old one is read.
    let null_new = unsafe { read_and_free(zanshin_git_remote_rename(handle, name.as_ptr(), std::ptr::null())) };
    assert_eq!(error_code(&null_new), FFI_NULL_POINTER);

    // SAFETY: 0 is the documented null handle.
    let bad_handle = unsafe { read_and_free(zanshin_git_remote_rename(0, name.as_ptr(), name.as_ptr())) };
    assert_eq!(error_code(&bad_handle), FFI_INVALID_HANDLE);

    close_handle(handle);
}

// ── zanshin_git_remote_set_url ────────────────────────────────────────────────

#[test]
fn git_remote_set_url_happy_path_carries_the_new_url_through_the_request_buffer() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);
    let req = add_request_bytes(Some("origin"), Some("/tmp/nowhere"), None);
    // SAFETY: req outlives the call.
    unsafe { read_and_free(zanshin_git_remote_add(handle, req.as_ptr(), req.len())) };

    let set = set_url_request_bytes(Some("origin"), Some("/tmp/repointed"), None);
    // SAFETY: set outlives the call.
    let bytes = unsafe { read_and_free(zanshin_git_remote_set_url(handle, set.as_ptr(), set.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "set-url failed: {:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);

    // SAFETY: handle is live for the duration of the call.
    let listed = unsafe { read_and_free(zanshin_remotes(handle)) };
    let env = parse_envelope(&listed);
    let remotes = env
        .data_as_remotes()
        .expect("Remotes payload")
        .remotes()
        .expect("remotes");
    assert_eq!(remotes.len(), 1);
    assert_eq!(
        remotes.get(0).url(),
        Some("/tmp/repointed"),
        "the SAME handle must see the new url — the request buffer's url reached jj-lib"
    );

    close_handle(handle);
}

/// The `GitRemoteSetUrlRequest.push_url` field, which no other row carries: every other
/// buffer leaves it ABSENT, so a reader that hardcoded `None` would go unnoticed. Witnessed
/// through `zanshin_remotes`' own `Remotes` payload, which now carries `push_url` too.
#[test]
fn git_remote_set_url_carries_a_push_only_request_through_the_buffer() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);
    let add = add_request_bytes(Some("origin"), Some("/tmp/nowhere"), None);
    // SAFETY: add outlives the call.
    unsafe { read_and_free(zanshin_git_remote_add(handle, add.as_ptr(), add.len())) };

    let set = set_url_request_bytes(Some("origin"), None, Some("/tmp/pushed"));
    // SAFETY: set outlives the call.
    let bytes = unsafe { read_and_free(zanshin_git_remote_set_url(handle, set.as_ptr(), set.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "set-url failed: {:?}", env.error().and_then(|e| e.code()));

    // SAFETY: handle is live for the duration of the call.
    let listed = unsafe { read_and_free(zanshin_remotes(handle)) };
    let env = parse_envelope(&listed);
    let remotes = env
        .data_as_remotes()
        .expect("Remotes payload")
        .remotes()
        .expect("remotes");
    assert_eq!(
        remotes.get(0).url(),
        Some("/tmp/nowhere"),
        "an absent fetch url means LEAVE IT ALONE"
    );
    assert_eq!(
        remotes.get(0).push_url(),
        Some("/tmp/pushed"),
        "the request buffer's push_url must reach jj-lib and come back on the wire"
    );

    close_handle(handle);
}

/// The documented `ffi.utf8_error` on the two C-string wrappers. Without this row the code
/// is in their `# Errors` blocks and in the registry but unreachable in any test.
#[test]
fn git_remote_remove_and_rename_reject_an_invalid_utf8_name() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);
    // A lone 0xff byte is never valid UTF-8, and carries no interior NUL.
    let invalid = CString::new(vec![0xff_u8, 0xfe]).expect("no interior NUL");
    let valid = cstr("origin");

    // SAFETY: invalid is a valid NUL-terminated C string; only its CONTENT is not UTF-8.
    let removed = unsafe { read_and_free(zanshin_git_remote_remove(handle, invalid.as_ptr())) };
    assert_eq!(error_code(&removed), FFI_UTF8_ERROR);

    // SAFETY: see above.
    let renamed_old = unsafe { read_and_free(zanshin_git_remote_rename(handle, invalid.as_ptr(), valid.as_ptr())) };
    assert_eq!(error_code(&renamed_old), FFI_UTF8_ERROR);

    // SAFETY: see above.
    let renamed_new = unsafe { read_and_free(zanshin_git_remote_rename(handle, valid.as_ptr(), invalid.as_ptr())) };
    assert_eq!(error_code(&renamed_new), FFI_UTF8_ERROR);

    close_handle(handle);
}

#[test]
fn git_remote_set_url_rejects_a_null_buffer_garbage_a_missing_field_and_a_missing_remote() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let handle = init_handle(tmp.path(), 1);

    // SAFETY: a null `data` is the documented null-pointer case.
    let null_bytes = unsafe { read_and_free(zanshin_git_remote_set_url(handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&null_bytes), FFI_NULL_POINTER);

    let garbage = [0xff_u8; 16];
    // SAFETY: `garbage` outlives the call; it simply does not verify.
    let garbage_bytes = unsafe { read_and_free(zanshin_git_remote_set_url(handle, garbage.as_ptr(), garbage.len())) };
    assert_eq!(error_code(&garbage_bytes), FFI_INVALID_ARGUMENT);

    let no_name = set_url_request_bytes(None, Some("/tmp/x"), None);
    // SAFETY: no_name outlives the call.
    let missing_field = unsafe { read_and_free(zanshin_git_remote_set_url(handle, no_name.as_ptr(), no_name.len())) };
    assert_eq!(error_code(&missing_field), JJ_INVALID_INPUT);

    let absent = set_url_request_bytes(Some("nonexistent"), Some("/tmp/x"), None);
    // SAFETY: absent outlives the call.
    let not_found = unsafe { read_and_free(zanshin_git_remote_set_url(handle, absent.as_ptr(), absent.len())) };
    assert_eq!(error_code(&not_found), JJ_REMOTE_NOT_FOUND);

    // SAFETY: 0 is the documented null handle.
    let bad_handle = unsafe { read_and_free(zanshin_git_remote_set_url(0, absent.as_ptr(), absent.len())) };
    assert_eq!(error_code(&bad_handle), FFI_INVALID_HANDLE);

    close_handle(handle);
}

// ── Shared open helper ────────────────────────────────────────────────────────

/// Open an existing workspace and return its handle.
///
/// Separate from [`init_handle`] because several rows must write to the backing git repo
/// BETWEEN init and open, so the freshly-loaded backend picks the change up from disk.
fn init_handle_by_open(path: &Path) -> u64 {
    let p = cstr(path.to_str().expect("path must be UTF-8"));
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let token = unsafe { zanshin_ffi::repo::zanshin_repo_open(p.as_ptr()) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_open just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "open failed: {:?}", env.error().and_then(|e| e.code()));
    env.data_as_repo_handle()
        .expect("RepoHandle payload must be present")
        .handle()
}
