// SPDX-License-Identifier: MIT

//! Integration tests for the Story 6.5 mutation wrappers (`zanshin_describe`,
//! `zanshin_new_change`, `zanshin_edit`, `zanshin_abandon`, `zanshin_undo`,
//! `zanshin_git_fetch`).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the
//! Verifier — a wrong-shape payload is a compile error, not a runtime assert.
//! Every token is freed via `zanshin_buffer_free_token` so the suite is leak-clean.
//!
//! Mirrors `tests/change_ffi.rs`'s scaffolding for the handle/envelope helpers and
//! `zanshin-jj/tests/remotes_write.rs`'s local bare-git fixture for the `git_fetch`
//! rows. The `git_fetch` happy-path test additionally mirrors `tests/events_ffi.rs`'s
//! process-global event-sink registration to observe dispatched `Progress` envelopes.

use std::ffi::CString;
use std::path::Path;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};
use std::{env, fs};

use flatbuffers::root as fb_root;
use test_helpers::extract_fixture;
use zanshin_ffi::events::{zanshin_events_register, zanshin_events_unregister};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{
    zanshin_abandon, zanshin_describe, zanshin_edit, zanshin_git_fetch, zanshin_new_change, zanshin_repo_close,
    zanshin_repo_init, zanshin_repo_open, zanshin_undo,
};
use zanshin_ffi::status::zanshin_status;
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CHANGE_NOT_FOUND, JJ_INVALID_INPUT,
    JJ_NOTHING_TO_UNDO,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: mirrors tests/change_ffi.rs / tests/events_ffi.rs — empty string makes
    // jj-lib find no config at that path; GIT_CONFIG_GLOBAL="" isolates gix.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

// ── Envelope helpers (mirrors tests/change_ffi.rs) ────────────────────────────

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

/// Build a `ChangeIdList` request buffer via `fbs::ChangeIdListArgs` (the ADR-0001
/// composite-input pattern).
fn change_id_list_bytes(ids: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let offs: Vec<_> = ids.iter().map(|s| b.create_string(s)).collect();
    let vec = b.create_vector(&offs);
    let list = fbs::ChangeIdList::create(&mut b, &fbs::ChangeIdListArgs { change_ids: Some(vec) });
    b.finish(list, None);
    b.finished_data().to_vec()
}

/// Open `path` and return `(handle, session_id)`.
fn open_handle(path: &Path) -> (u64, u64) {
    let p = cstr(path.to_str().expect("fixture path must be UTF-8"));
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let token = unsafe { zanshin_repo_open(p.as_ptr()) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_open just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "expected ok, error: {:?}", env.error().and_then(|e| e.code()));
    let rh = env.data_as_repo_handle().expect("RepoHandle payload must be present");
    (rh.handle(), rh.session_id())
}

fn close_handle(handle: u64) {
    // SAFETY: handle originated from open_handle/init above and has not been closed.
    let token = unsafe { zanshin_repo_close(handle) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_close just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "expected ok, error: {:?}", env.error().and_then(|e| e.code()));
}

/// Open the tiny fixture and return its raw handle + the working-copy change id.
///
/// The caller is responsible for closing the handle via `zanshin_repo_close`.
unsafe fn open_fixture_and_get_wc_change_id() -> (u64, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path_cstr = cstr(fixture.path.to_str().expect("fixture path must be valid UTF-8"));

    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    let status_token = unsafe { zanshin_status(handle) };
    let status_bytes = unsafe { read_and_free(status_token) };
    let status_env = parse_envelope(&status_bytes);
    assert!(status_env.ok(), "status must succeed");
    let wc_change_id = status_env
        .data_as_status()
        .expect("data_as_status must succeed")
        .working_copy_change_id()
        .expect("working_copy_change_id must be present")
        .to_owned();

    // The fixture handle is leaked into the caller — they must close it. Keep
    // `fixture` alive by leaking it (its TempDir lives for the test).
    std::mem::forget(fixture);

    (handle, wc_change_id)
}

// ── describe ──────────────────────────────────────────────────────────────────

#[test]
fn describe_valid_round_trip_returns_ok_mutation_result() {
    pin_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    let change_cstr = cstr(&wc_change_id);
    let desc_cstr = cstr("a new description");
    let token = unsafe { zanshin_describe(handle, change_cstr.as_ptr(), desc_cstr.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "describe must succeed for a valid id");
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    assert!(mr.new_op_id().is_some_and(|s| !s.is_empty()), "new_op_id must be set");
    assert!(
        mr.new_change_ids().is_none_or(|v| v.is_empty()),
        "describe never mints a new change"
    );
    assert!(
        mr.abandoned_change_ids().is_none_or(|v| v.is_empty()),
        "describe never abandons a change"
    );

    close_handle(handle);
}

// ── new_change ────────────────────────────────────────────────────────────────

#[test]
fn new_change_valid_round_trip_returns_one_new_change_id() {
    pin_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    let req = change_id_list_bytes(&[&wc_change_id]);
    let token = unsafe { zanshin_new_change(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "new_change must succeed for a valid parent");
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    let new_ids = mr.new_change_ids().expect("new_change_ids must be present");
    assert_eq!(new_ids.len(), 1, "new_change mints exactly one new change");
    assert_eq!(
        mr.working_copy_change_id(),
        Some(new_ids.get(0)),
        "the new change becomes @"
    );

    close_handle(handle);
}

#[test]
fn new_change_empty_parents_returns_jj_invalid_input() {
    pin_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let req = change_id_list_bytes(&[]);
    let token = unsafe { zanshin_new_change(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "empty parents must produce an error envelope");
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));

    close_handle(handle);
}

// ── edit ──────────────────────────────────────────────────────────────────────

#[test]
fn edit_valid_round_trip_moves_working_copy() {
    pin_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    // Mint a genuine ANCESTOR relationship to edit back across: new_change(A) creates
    // B on top of the original @ (A) and switches @ to B; editing back to A is then a
    // real "switch to a different, already-existing change" — unlike editing @ to
    // itself, which hits jj-lib's implicit-abandon-of-a-discardable-previous-@ side
    // effect (see mutate::edit's doc comment) and mints a replacement instead.
    let req = change_id_list_bytes(&[&wc_change_id]);
    let new_change_token = unsafe { zanshin_new_change(handle, req.as_ptr(), req.len()) };
    let new_change_bytes = unsafe { read_and_free(new_change_token) };
    assert!(parse_envelope(&new_change_bytes).ok(), "new_change must succeed");

    let change_cstr = cstr(&wc_change_id);
    let token = unsafe { zanshin_edit(handle, change_cstr.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(
        env.ok(),
        "edit must succeed for a valid id, error={:?}/{:?}",
        env.error().and_then(|e| e.code()),
        env.error().and_then(|e| e.context())
    );
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    assert_eq!(
        mr.working_copy_change_id(),
        Some(wc_change_id.as_str()),
        "@ now names the edited change"
    );
    assert!(mr.new_change_ids().is_none_or(|v| v.is_empty()), "edit mints nothing");

    close_handle(handle);
}

// ── abandon ───────────────────────────────────────────────────────────────────

#[test]
fn abandon_wc_included_returns_replacement_new_change_id() {
    pin_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    let req = change_id_list_bytes(&[&wc_change_id]);
    let token = unsafe { zanshin_abandon(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "abandon must succeed for a valid id");
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    let new_ids = mr.new_change_ids().expect("new_change_ids must be present");
    assert_eq!(new_ids.len(), 1, "abandoning @ mints its replacement");
    let abandoned = mr.abandoned_change_ids().expect("abandoned_change_ids must be present");
    assert_eq!(abandoned.iter().collect::<Vec<_>>(), vec![wc_change_id.as_str()]);

    close_handle(handle);
}

#[test]
fn abandon_empty_change_ids_returns_jj_invalid_input() {
    pin_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let req = change_id_list_bytes(&[]);
    let token = unsafe { zanshin_abandon(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "empty change_ids must produce an error envelope");
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));

    close_handle(handle);
}

// ── undo ──────────────────────────────────────────────────────────────────────

#[test]
fn undo_valid_round_trip_restores_previous_op() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let path_cstr = cstr(tmp.path().to_str().unwrap());

    let init_token = unsafe { zanshin_repo_init(path_cstr.as_ptr(), 0) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "init must succeed");
    let handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();

    // Perform a mutation so there is something to undo.
    let status_token = unsafe { zanshin_status(handle) };
    let status_bytes = unsafe { read_and_free(status_token) };
    let status_env = parse_envelope(&status_bytes);
    assert!(status_env.ok(), "status must succeed");
    let wc_id = status_env
        .data_as_status()
        .expect("data_as_status must succeed")
        .working_copy_change_id()
        .expect("working_copy_change_id must be present")
        .to_owned();
    let desc_cstr = cstr("about to be undone");
    let change_cstr = cstr(&wc_id);
    let describe_token = unsafe { zanshin_describe(handle, change_cstr.as_ptr(), desc_cstr.as_ptr()) };
    let describe_bytes = unsafe { read_and_free(describe_token) };
    assert!(parse_envelope(&describe_bytes).ok(), "describe must succeed");

    let token = unsafe { zanshin_undo(handle) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "undo must succeed");
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    assert!(mr.new_op_id().is_some_and(|s| !s.is_empty()));

    close_handle(handle);
}

/// Head-is-root `NothingToUndo` (mirrors `zanshin-jj`'s own
/// `undo_at_root_operation_returns_nothing_to_undo`): a fresh workspace's head
/// always has >=1 parent, so engineer the unreachable state directly by rewriting
/// `op_heads/heads/` so the ONLY marker is the root op itself.
#[test]
fn undo_root_op_returns_jj_nothing_to_undo() {
    pin_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let path_cstr = cstr(tmp.path().to_str().unwrap());

    let init_token = unsafe { zanshin_repo_init(path_cstr.as_ptr(), 0) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "init must succeed");
    let handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();

    let op_log_token = unsafe { zanshin_ffi::op_log::zanshin_op_log(handle, -1) };
    let op_log_bytes = unsafe { read_and_free(op_log_token) };
    let op_log_env = parse_envelope(&op_log_bytes);
    assert!(op_log_env.ok(), "op_log must succeed");
    let ops = op_log_env.data_as_op_log().expect("OpLog must be present");
    let operations = ops.operations().expect("operations must be present");
    let head_hex = operations.get(0).id().expect("head id").to_owned();
    let root_hex = operations
        .iter()
        .find(fbs::Operation::root_op)
        .expect("root op must be present")
        .id()
        .expect("root id")
        .to_owned();

    close_handle(handle);

    let heads_dir = tmp.path().join(".jj").join("repo").join("op_heads").join("heads");
    fs::remove_file(heads_dir.join(&head_hex)).unwrap();
    fs::write(heads_dir.join(&root_hex), "").unwrap();

    let (fresh_handle, _) = open_handle(tmp.path());
    let token = unsafe { zanshin_undo(fresh_handle) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "undo at the root operation must produce an error envelope");
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_NOTHING_TO_UNDO));

    close_handle(fresh_handle);
}

// ── git_fetch ─────────────────────────────────────────────────────────────────

// Serializes every test in this file that touches the process-global event sink
// (mirrors tests/events_ffi.rs's TEST_GUARD; this binary is a separate process
// from events_ffi.rs's, so the two files' sinks never collide).
static TEST_GUARD: Mutex<()> = Mutex::new(());
static RECEIVED: Mutex<Vec<Vec<u8>>> = Mutex::new(Vec::new());

unsafe extern "C" fn test_sink(token: *mut ZanshinBuf) {
    // SAFETY: forwarded from the `EventCallback` contract — `token` is a valid,
    // non-null token produced by `events::dispatch` via `vec_into_token`.
    let bytes = unsafe { read_and_free(token) };
    received_lock().push(bytes);
}

fn received_lock() -> std::sync::MutexGuard<'static, Vec<Vec<u8>>> {
    RECEIVED.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn drain_received() -> Vec<Vec<u8>> {
    std::mem::take(&mut received_lock())
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

/// Build a plain Git repo at `path` with one commit on `main`.
fn init_git_repo_with_commit(path: &Path) {
    git_cmd(&["init", "--initial-branch=main"], path);
    git_cmd(&["config", "user.email", "test@zanshin.test"], path);
    git_cmd(&["config", "user.name", "Fixture"], path);
    fs::write(path.join("README.md"), "hello").expect("write README");
    git_cmd(&["add", "."], path);
    git_cmd(&["commit", "-m", "initial"], path);
}

/// Clone a normal Git repo as a bare repo (returns the bare repo path inside `parent`).
fn git_bare_clone(src: &Path, parent: &Path) -> std::path::PathBuf {
    let bare = parent.join("bare.git");
    git_cmd(
        &["clone", "--bare", &src.to_string_lossy(), &bare.to_string_lossy()],
        parent,
    );
    bare
}

/// Register `name` -> `url` as a git remote on the jj Git-backend workspace at
/// `root`, by writing directly to the embedded git store's config (the same disk
/// effect as jj-lib's `git::add_remote`; `zanshin_jj::remotes::git_fetch` computes
/// its own bookmark/tag refspecs, so the remote-level `tagOpt` setting jj-lib would
/// additionally set doesn't matter here). A fresh `zanshin_repo_open` afterward is
/// required so the freshly-loaded `GitBackend` reads the new remote from disk
/// (mirrors `zanshin-jj/tests/remotes_write.rs::register_remote`'s own note).
fn register_remote(root: &Path, name: &str, url: &str) {
    let git_dir = root.join(".jj").join("repo").join("store").join("git");
    git_cmd(&["remote", "add", name, url], &git_dir);
}

#[test]
fn git_fetch_happy_path_reports_progress_and_returns_mutation_result() {
    pin_env();
    let _test_guard = TEST_GUARD.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    drain_received();

    let src = tempfile::TempDir::new().unwrap();
    init_git_repo_with_commit(src.path());

    let parent = tempfile::TempDir::new().unwrap();
    let bare = git_bare_clone(src.path(), parent.path());

    let dst = tempfile::TempDir::new().unwrap();
    let dst_cstr = cstr(dst.path().to_str().unwrap());
    let init_token = unsafe { zanshin_repo_init(dst_cstr.as_ptr(), 1) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "init (git backend) must succeed");
    let init_handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();
    close_handle(init_handle);

    register_remote(dst.path(), "origin", &bare.to_string_lossy());

    let (handle, session_id) = open_handle(dst.path());

    zanshin_events_register(Some(test_sink));

    let remote_cstr = cstr("origin");
    let token = unsafe { zanshin_git_fetch(handle, remote_cstr.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(
        env.ok(),
        "git_fetch must succeed, error: {:?}",
        env.error().and_then(|e| e.code())
    );
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    assert!(mr.new_op_id().is_some_and(|s| !s.is_empty()));

    // Poll briefly: dispatch happens on the calling thread synchronously inside
    // git_fetch's progress closure, but give a generous margin (R7) before failing.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut progress_envelopes = Vec::new();
    loop {
        for raw in drain_received() {
            let e = parse_envelope(&raw);
            if e.ok() && e.data_type() == fbs::Payload::Progress {
                progress_envelopes.push(raw);
            }
        }
        if !progress_envelopes.is_empty() || Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    assert!(
        !progress_envelopes.is_empty(),
        "expected at least one Progress envelope"
    );
    for raw in &progress_envelopes {
        let e = parse_envelope(raw);
        let progress = e.data_as_progress().expect("Progress payload must be present");
        assert_eq!(
            progress.session_id(),
            session_id,
            "session_id must match the handle's session"
        );
        assert_eq!(progress.operation(), Some("fetch"));
    }

    zanshin_events_unregister();
    close_handle(handle);
}

#[test]
fn git_fetch_nonexistent_remote_returns_jj_remote_not_found() {
    pin_env();
    let dst = tempfile::TempDir::new().unwrap();
    let dst_cstr = cstr(dst.path().to_str().unwrap());
    let init_token = unsafe { zanshin_repo_init(dst_cstr.as_ptr(), 1) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "init (git backend) must succeed");
    let handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();

    let remote_cstr = cstr("nonexistent");
    let token = unsafe { zanshin_git_fetch(handle, remote_cstr.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "unknown remote must produce an error envelope");
    assert_eq!(
        env.error().and_then(|e| e.code()),
        Some(zanshin_ffi::JJ_REMOTE_NOT_FOUND)
    );

    close_handle(handle);
}

// ── Cross-cutting edge cases ──────────────────────────────────────────────────

/// A nonexistent change id (mirrors `tests/change_ffi.rs`'s own `bad_id`).
/// NOT all-`z`: jj's reverse-hex root change id IS all-`z` (hex `0000…0000`), so
/// e.g. `"zzzzzzzz"` is a valid PREFIX of the (very much existing) root change —
/// it resolves and hits `jj.invalid_input` ("cannot describe/abandon the root
/// commit"), not `jj.change_not_found`. `jj.change_not_found` is documented on
/// `zanshin_describe`/`zanshin_new_change`/`zanshin_edit`/`zanshin_abandon`; this
/// table-style test exercises the mapping through each of the four real
/// `extern "C"` entry points (not just the standalone `map_mutate_err` unit test).
#[test]
fn every_wrapper_bogus_change_id_returns_jj_change_not_found() {
    pin_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };
    let bogus = "nonexistentchangeid";
    let bogus_cstr = cstr(bogus);
    let desc_cstr = cstr("desc");
    let req = change_id_list_bytes(&[bogus]);

    let describe_token = unsafe { zanshin_describe(handle, bogus_cstr.as_ptr(), desc_cstr.as_ptr()) };
    let describe_bytes = unsafe { read_and_free(describe_token) };
    assert_eq!(
        parse_envelope(&describe_bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "zanshin_describe with a bogus change id"
    );

    let new_change_token = unsafe { zanshin_new_change(handle, req.as_ptr(), req.len()) };
    let new_change_bytes = unsafe { read_and_free(new_change_token) };
    assert_eq!(
        parse_envelope(&new_change_bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "zanshin_new_change with a bogus parent id"
    );

    let edit_token = unsafe { zanshin_edit(handle, bogus_cstr.as_ptr()) };
    let edit_bytes = unsafe { read_and_free(edit_token) };
    assert_eq!(
        parse_envelope(&edit_bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "zanshin_edit with a bogus change id"
    );

    let abandon_token = unsafe { zanshin_abandon(handle, req.as_ptr(), req.len()) };
    let abandon_bytes = unsafe { read_and_free(abandon_token) };
    assert_eq!(
        parse_envelope(&abandon_bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "zanshin_abandon with a bogus change id"
    );

    close_handle(handle);
}

#[test]
fn describe_null_change_id_returns_ffi_null_pointer() {
    pin_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let desc_cstr = cstr("desc");
    let token = unsafe { zanshin_describe(handle, std::ptr::null(), desc_cstr.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn describe_null_description_returns_ffi_null_pointer() {
    pin_env();
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    let change_cstr = cstr(&wc_change_id);
    let token = unsafe { zanshin_describe(handle, change_cstr.as_ptr(), std::ptr::null()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn edit_null_change_id_returns_ffi_null_pointer() {
    pin_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let token = unsafe { zanshin_edit(handle, std::ptr::null()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn git_fetch_null_remote_name_returns_ffi_null_pointer() {
    pin_env();
    let dst = tempfile::TempDir::new().unwrap();
    let dst_cstr = cstr(dst.path().to_str().unwrap());
    let init_token = unsafe { zanshin_repo_init(dst_cstr.as_ptr(), 1) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok());
    let handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();

    let token = unsafe { zanshin_git_fetch(handle, std::ptr::null()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn new_change_null_request_buffer_returns_ffi_null_pointer() {
    pin_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let token = unsafe { zanshin_new_change(handle, std::ptr::null(), 0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn abandon_null_request_buffer_returns_ffi_null_pointer() {
    pin_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let token = unsafe { zanshin_abandon(handle, std::ptr::null(), 0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn new_change_garbage_bytes_returns_ffi_invalid_argument() {
    pin_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let garbage: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
    let token = unsafe { zanshin_new_change(handle, garbage.as_ptr(), garbage.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));

    close_handle(handle);
}

#[test]
fn abandon_garbage_bytes_returns_ffi_invalid_argument() {
    pin_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let garbage: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
    let token = unsafe { zanshin_abandon(handle, garbage.as_ptr(), garbage.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));

    close_handle(handle);
}

#[test]
fn every_wrapper_zero_handle_returns_ffi_invalid_handle() {
    pin_env();
    let id_cstr = cstr("qpvuntsm");
    let desc_cstr = cstr("desc");
    let req = change_id_list_bytes(&["qpvuntsm"]);
    let remote_cstr = cstr("origin");

    let describe_token = unsafe { zanshin_describe(0, id_cstr.as_ptr(), desc_cstr.as_ptr()) };
    let describe_bytes = unsafe { read_and_free(describe_token) };
    assert_eq!(
        parse_envelope(&describe_bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );

    let new_change_token = unsafe { zanshin_new_change(0, req.as_ptr(), req.len()) };
    let new_change_bytes = unsafe { read_and_free(new_change_token) };
    assert_eq!(
        parse_envelope(&new_change_bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );

    let edit_token = unsafe { zanshin_edit(0, id_cstr.as_ptr()) };
    let edit_bytes = unsafe { read_and_free(edit_token) };
    assert_eq!(
        parse_envelope(&edit_bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );

    let abandon_token = unsafe { zanshin_abandon(0, req.as_ptr(), req.len()) };
    let abandon_bytes = unsafe { read_and_free(abandon_token) };
    assert_eq!(
        parse_envelope(&abandon_bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );

    let undo_token = unsafe { zanshin_undo(0) };
    let undo_bytes = unsafe { read_and_free(undo_token) };
    assert_eq!(
        parse_envelope(&undo_bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );

    let git_fetch_token = unsafe { zanshin_git_fetch(0, remote_cstr.as_ptr()) };
    let git_fetch_bytes = unsafe { read_and_free(git_fetch_token) };
    assert_eq!(
        parse_envelope(&git_fetch_bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );
}
