// SPDX-License-Identifier: MIT

//! Integration tests for the process-global event sink (Story 3.6).
//!
//! A Rust-side test sink is registered via `zanshin_events_register` and driven
//! through the real `zanshin_repo_open`/`_close` wrappers, arming real Story-3.5
//! watchers against real `tiny-3-commits` fixtures — the full producer chain
//! (dispatch thread → `events::dispatch` → C callback) end to end.
//!
//! The sink + its `RECEIVED` buffer are process-global state, so each test here
//! runs alone in a child process of its own (`test_helpers::own_process!`): no
//! other test's sink registration or watcher events reach it. Every test still
//! holds `TEST_GUARD` for its duration (trap 11a).

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
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};

// ── Env pin ───────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: set once via LazyLock::force before any repo is opened, in a child
    // process that runs this one test (`own_process!`), before it reads the
    // environment.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

// ── Sink serialization (trap 11a) ─────────────────────────────────────────────

// Held by every test in this file: each registers/unregisters the ONE
// process-global sink and reads the ONE process-global `RECEIVED` buffer (each
// in a child process of its own, so the guard is never contended).
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

fn clear_received() {
    received_lock().clear();
}

fn drain_received() -> Vec<Vec<u8>> {
    std::mem::take(&mut received_lock())
}

// ── Envelope helpers (mirrors repo_ffi.rs) ────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` not yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    // SAFETY: token is valid; we copy bytes before freeing.
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    // SAFETY: token is valid; freed exactly once here after the copy above.
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("CString::new must not fail for a non-null string")
}

/// Open `path` and return `(handle, session_id)`: the raw close-handle plus
/// the process-unique session id events carry as their correlation id.
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
    // SAFETY: handle originated from open_handle above and has not been closed.
    let token = unsafe { zanshin_repo_close(handle) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_close just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "expected ok, error: {:?}", env.error().and_then(|e| e.code()));
}

/// Poll `RECEIVED`, accumulating every event observed into `into`, until a
/// `WatcherEvent` matching `(session_id, kind)` is found or `timeout` elapses.
/// Returns whether it was found. Non-matching events are preserved in `into`
/// (not discarded), so callers can also assert on absence — e.g. "no event
/// carried a *different* session" — without a second, racy drain pass.
///
/// Generous timeout: this asserts *arrival*, never a tight latency bound (R7).
fn collect_until_watcher_event(
    into: &mut Vec<Vec<u8>>,
    session_id: u64,
    kind: fbs::WatcherEventKind,
    timeout: Duration,
) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        for bytes in drain_received() {
            let is_match = parse_envelope(&bytes)
                .data_as_watcher_event()
                .is_some_and(|p| p.session_id() == session_id && p.kind() == kind);
            into.push(bytes);
            if is_match {
                return true;
            }
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn heads_dir(repo_root: &Path) -> std::path::PathBuf {
    repo_root.join(".jj/repo/op_heads/heads")
}

// ── Tests ──────────────────────────────────────────────────────────────────────

#[test]
fn event_arrives_on_op_heads_change() {
    test_helpers::own_process!("event_arrives_on_op_heads_change");
    // WHY unwrap_or_else(PoisonError::into_inner): a poisoned guard must not turn
    // into a second failure — recovering is correct here since the guarded value
    // is just `()` (no invariant a panic could have broken).
    let _guard = TEST_GUARD.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    pin_env();
    clear_received();
    zanshin_events_register(Some(test_sink));

    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let (handle, session_id) = open_handle(&fixture.path);

    // AR-G-5 ordering evidence (AC 16): this touch happens IMMEDIATELY after
    // open_handle returns — no sleep between open-return and mutation. The
    // event arriving below therefore proves the watcher was armed before the
    // wrapper returned. No tighter race assertion is possible without
    // fault-injection inside jj-lib: we cannot pause `Repo::open` between
    // workspace load and watcher arming to slip a mutation into that gap, so
    // "mutate immediately after return → event arrives" is the strongest
    // observable evidence of the AR-G-5 ordering.
    fs::write(heads_dir(&fixture.path).join("test_event"), b"").unwrap();

    let mut events = Vec::new();
    let found = collect_until_watcher_event(
        &mut events,
        session_id,
        fbs::WatcherEventKind::OpHeadsChanged,
        Duration::from_secs(5),
    );
    assert!(found, "expected an OpHeadsChanged event for session {session_id}");

    close_handle(handle);
    zanshin_events_unregister();
}

#[test]
fn two_repos_open_touching_one_dispatches_only_its_handle() {
    test_helpers::own_process!("two_repos_open_touching_one_dispatches_only_its_handle");
    // WHY unwrap_or_else(PoisonError::into_inner): a poisoned guard must not turn
    // into a second failure — recovering is correct here since the guarded value
    // is just `()` (no invariant a panic could have broken).
    let _guard = TEST_GUARD.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    pin_env();
    clear_received();
    zanshin_events_register(Some(test_sink));

    let fixture_a = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let fixture_b = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let (handle_a, session_a) = open_handle(&fixture_a.path);
    let (handle_b, session_b) = open_handle(&fixture_b.path);

    fs::write(heads_dir(&fixture_a.path).join("test_event"), b"").unwrap();

    let mut events = Vec::new();
    let found = collect_until_watcher_event(
        &mut events,
        session_a,
        fbs::WatcherEventKind::OpHeadsChanged,
        Duration::from_secs(5),
    );
    assert!(found, "expected an OpHeadsChanged event for session_a ({session_a})");

    // Give any stray repo-B event a little extra time to (not) show up; a
    // deliberately-unreachable target session just extends the accumulation
    // window without waiting for the full timeout.
    collect_until_watcher_event(
        &mut events,
        u64::MAX,
        fbs::WatcherEventKind::OpHeadsChanged,
        Duration::from_millis(300),
    );

    assert!(
        !events.iter().any(|bytes| {
            parse_envelope(bytes)
                .data_as_watcher_event()
                .is_some_and(|p| p.session_id() == session_b)
        }),
        "repo B was never touched — no event should carry session_id == session_b ({session_b})"
    );

    close_handle(handle_a);
    close_handle(handle_b);
    zanshin_events_unregister();
}

#[test]
fn close_stops_further_dispatch() {
    test_helpers::own_process!("close_stops_further_dispatch");
    // WHY unwrap_or_else(PoisonError::into_inner): a poisoned guard must not turn
    // into a second failure — recovering is correct here since the guarded value
    // is just `()` (no invariant a panic could have broken).
    let _guard = TEST_GUARD.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    pin_env();
    clear_received();
    zanshin_events_register(Some(test_sink));

    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let (handle, session_id) = open_handle(&fixture.path);

    fs::write(heads_dir(&fixture.path).join("before_close"), b"").unwrap();
    let mut events = Vec::new();
    let found = collect_until_watcher_event(
        &mut events,
        session_id,
        fbs::WatcherEventKind::OpHeadsChanged,
        Duration::from_secs(5),
    );
    assert!(found, "expected the pre-close OpHeadsChanged to arrive");

    close_handle(handle);
    clear_received();

    // AC 8: no callback fires after zanshin_repo_close returns. Touching the
    // now-unwatched op_heads dir must produce silence within a bounded wait —
    // not a tight race assertion, just "nothing arrives eventually" (R7).
    fs::write(heads_dir(&fixture.path).join("after_close"), b"").unwrap();
    std::thread::sleep(Duration::from_millis(500));
    assert!(
        received_lock().is_empty(),
        "no event should be dispatched for session {session_id} after close() returns"
    );

    zanshin_events_unregister();
}

// Arming-failure coverage (AC 14's "watcher.io_error on arming failure" bullet)
// lives as an inline unit test in `repo.rs::tests::arm_session_returns_watcher_io_error_when_checkout_missing_after_open`:
// deleting `.jj/working_copy/checkout` BEFORE `zanshin_repo_open` fails inside
// jj-lib's `Workspace::load` itself (`jj.jj_lib_error`, verified empirically),
// never reaching `arm_session` — so the only way to exercise the *mapped code*
// (per AC 14's explicit fallback) is to sabotage AFTER a successful `Repo::open`
// and call `arm_session` directly, which requires `repo.rs`'s private items.
