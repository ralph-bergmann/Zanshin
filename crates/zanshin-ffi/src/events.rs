// SPDX-License-Identifier: MIT

//! Process-global async event sink (FR-FFI-4, FR-RX-1, FR-FFI-8).
//!
//! Story 3.5's watcher subsystem and Story 6-4a's future progress producer
//! both dispatch through the same mechanism: ONE C callback, registered once
//! by the Dart worker isolate via [`zanshin_events_register`], invoked from
//! any per-repo dispatch thread with a `FlatBuffers` `Envelope` token whose
//! payload carries a `repo_handle` correlation id (ADR-0002:57) so the worker
//! can demux events back to the right `RepoHandle`.

use std::sync::Mutex;

use flatbuffers::FlatBufferBuilder;

use crate::envelope::finish_envelope;
use crate::envelope_generated::zanshin::ffi as fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::watcher::WatcherEvent;

/// C callback registered by the Dart worker isolate via [`zanshin_events_register`].
///
/// One pointer arg (like `NativeFinalizer` callbacks): the token is a
/// `FlatBuffers` `Envelope` buffer produced by [`watcher_event_to_envelope`] or
/// [`progress_to_envelope`]. Ownership transfers to Dart on invocation — this
/// side must not free it; Dart frees it via `FfiBuffer.fromToken`'s finalizer
/// path (`zanshin_buffer_free_token`).
pub type EventCallback = unsafe extern "C" fn(event: *mut ZanshinBuf);

// WHY: this Mutex guards process-global *registration state* — a single C
// function pointer set once by the worker isolate at startup — not a jj
// `Repo`/`RepoSession` handle, so it does not violate the no-locking-around-
// handles rule (AD-2). Synchronization is mandatory here: per-repo dispatch
// threads (readers, potentially several concurrently) race the worker
// isolate's register/unregister calls (writers), and there is exactly one
// such slot for the whole process.
static SINK: Mutex<Option<EventCallback>> = Mutex::new(None);

/// Register `callback` as the process-global event sink.
///
/// Overwrites any previously registered callback — a worker restart
/// re-registers, and the new callback simply replaces the old one. `None` is
/// a defensive no-op (Dart never passes null in practice).
///
/// Infallible and `catch_unwind`-wrapped so no panic crosses the C ABI.
/// Handle-free, so — like `zanshin_log` — it is exempt from the
/// single-consumer rule (AD-2) and may be called from any isolate/thread.
// WHY the parameter spells out `Option<unsafe extern "C" fn(...)>` instead of
// `Option<EventCallback>`: cbindgen 0.28 does not resolve the type alias at
// this position and emits an unusable opaque `Option_EventCallback` struct
// (ffigen then skips the whole function — verified empirically). Spelling the
// function-pointer type literally makes cbindgen apply its nullable-function-
// pointer special case and emit a plain `void (*callback)(ZanshinBuf*)`.
#[no_mangle]
pub extern "C" fn zanshin_events_register(callback: Option<unsafe extern "C" fn(event: *mut ZanshinBuf)>) {
    let _ = std::panic::catch_unwind(|| {
        let Some(cb) = callback else {
            tracing::warn!("zanshin_events_register called with a null callback");
            return;
        };
        // WHY unwrap_or_else(PoisonError::into_inner) instead of unwrap(): the
        // guarded critical section never panics, so poisoning cannot happen in
        // practice, but recovering it explicitly keeps this fn provably
        // panic-free (no clippy::missing_panics_doc, no reliance on the
        // catch_unwind backstop for something we can just not do).
        *SINK.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(cb);
    });
}

/// Clear the process-global event sink.
///
/// Unconditional and idempotent — there is no compare-and-clear against a
/// specific callback pointer, because production has exactly one worker per
/// process (documented in `docs/ffi-abi.md`). This lets the *main* isolate
/// call it on unexpected worker death without knowing the dead worker's
/// callback pointer.
///
/// Infallible and `catch_unwind`-wrapped; callable from any isolate/thread.
#[no_mangle]
pub extern "C" fn zanshin_events_unregister() {
    let _ = std::panic::catch_unwind(|| {
        *SINK.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    });
}

/// Dispatch a pre-serialised `Envelope` buffer to the registered sink, if any.
///
/// If a sink is registered, the buffer is handed to it via [`vec_into_token`]
/// (ownership of the token transfers to Dart). If no sink is registered the
/// event is dropped with a `tracing::debug!` — checked *before* the token
/// allocation, so an unregistered sink costs nothing beyond the caller's own
/// serialisation work.
///
/// The `SINK` lock is held **across** the callback invocation, which makes
/// [`zanshin_events_unregister`] a true barrier: once `unregister` returns,
/// no dispatch thread can still be inside a callback it loaded earlier, so
/// the caller may then safely close the `NativeCallable` or kill its isolate.
pub(crate) fn dispatch(event_bytes: Vec<u8>) {
    // WHY the guard is held across the call (not dropped after the load): a
    // load-then-unlock would let unregister return while an in-flight dispatch
    // still invokes the (about-to-be-closed) callable — the exact UB window
    // the shutdown/death protocols must exclude. The callback itself is
    // non-blocking (`NativeCallable.listener` posts a message and returns,
    // api.dart.dev), so the critical section stays tiny.
    let guard = SINK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(cb) = *guard else {
        tracing::debug!("no event sink registered, dropping event");
        return;
    };
    let token = vec_into_token(event_bytes);
    // SAFETY: `cb` is a function pointer registered by the Dart worker via
    // zanshin_events_register (a `NativeCallable.listener`); such calls are
    // non-blocking and safe to invoke from any thread (api.dart.dev). `token`
    // transfers ownership to Dart — this thread must not free it afterwards.
    unsafe { cb(token) };
}

/// Serialise a [`WatcherEvent`] into a finished `Envelope<WatcherEvent>` buffer,
/// tagged with the session's process-unique `session_id` for Dart-side demux
/// (ADR-0002:57, refined 2026-07-04: session id instead of the ABA-unsafe raw
/// handle — a close→reopen can reuse the freed session's allocation address;
/// a monotonic session id can never be misattributed to a later session).
///
/// Always `ok == true` — a degraded watch (`WatchError`) is data, not a
/// failed call; the `watcher.io_error` error code is reserved exclusively for
/// the arming-failure error envelope returned by `zanshin_repo_open`/`_init`/
/// `_clone`/`_convert` (single-emission-point rule).
#[must_use]
pub(crate) fn watcher_event_to_envelope(session_id: u64, event: &WatcherEvent) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let (kind, paths_off, message_off) = match event {
        WatcherEvent::OpHeadsChanged { paths } => {
            let offs: Vec<_> = paths.iter().map(|p| b.create_string(&p.to_string_lossy())).collect();
            (
                fbs::WatcherEventKind::OpHeadsChanged,
                Some(b.create_vector(&offs)),
                None,
            )
        }
        WatcherEvent::WorkingCopyHeartbeat { paths } => {
            let offs: Vec<_> = paths.iter().map(|p| b.create_string(&p.to_string_lossy())).collect();
            (
                fbs::WatcherEventKind::WorkingCopyHeartbeat,
                Some(b.create_vector(&offs)),
                None,
            )
        }
        WatcherEvent::WatchError { message } => {
            (fbs::WatcherEventKind::WatchError, None, Some(b.create_string(message)))
        }
    };
    let watcher_event = fbs::WatcherEvent::create(
        &mut b,
        &fbs::WatcherEventArgs {
            session_id,
            kind,
            paths: paths_off,
            message: message_off,
        },
    );
    finish_envelope(
        b,
        fbs::Payload::WatcherEvent,
        Some(watcher_event.as_union_value()),
        None,
    )
}

/// Serialise a progress notification (FR-FFI-8) into a finished
/// `Envelope<Progress>` buffer, tagged with the session's `session_id` for
/// Dart-side demux (same ABA-safe correlation id as `WatcherEvent`).
///
/// The first real caller is `repo.rs::zanshin_git_fetch` (Story 6.5), which
/// wraps the Dart-supplied `NativeCallable.listener` into a `ProgressFn` and
/// forwards each `zanshin_jj::ProgressEvent` here, tagged with the session's
/// `session_id` so the worker can demux it back to the right `handleId`.
#[must_use]
pub(crate) fn progress_to_envelope(session_id: u64, operation: &str, progress: f32, message: &str) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let operation_off = b.create_string(operation);
    let message_off = b.create_string(message);
    let progress_table = fbs::Progress::create(
        &mut b,
        &fbs::ProgressArgs {
            session_id,
            operation: Some(operation_off),
            progress,
            message: Some(message_off),
        },
    );
    finish_envelope(b, fbs::Payload::Progress, Some(progress_table.as_union_value()), None)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Mutex, OnceLock};

    use flatbuffers::VerifierOptions;

    use super::{
        dispatch, progress_to_envelope, watcher_event_to_envelope, zanshin_events_register, zanshin_events_unregister,
        SINK,
    };
    use crate::envelope_generated::zanshin::ffi as fbs;
    use crate::watcher::WatcherEvent;

    // Trap 11a: cargo runs unit tests in parallel threads of one process, and
    // every test in this module touches the same process-global `SINK`. Serialize.
    fn test_guard() -> &'static Mutex<()> {
        static GUARD: OnceLock<Mutex<()>> = OnceLock::new();
        GUARD.get_or_init(|| Mutex::new(()))
    }

    static CALLS: AtomicUsize = AtomicUsize::new(0);

    unsafe extern "C" fn recording_callback(event: *mut crate::ffi_strings::ZanshinBuf) {
        CALLS.fetch_add(1, Ordering::SeqCst);
        // SAFETY: token was produced by vec_into_token inside dispatch(); free it
        // so the test doesn't leak (mirrors Dart's FfiBuffer.fromToken → dispose).
        unsafe { crate::ffi_strings::zanshin_buffer_free_token(event) };
    }

    fn verified_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
        let opts = VerifierOptions::default();
        flatbuffers::root_with_opts::<fbs::Envelope>(&opts, bytes).expect("FlatBuffers Verifier must pass")
    }

    fn heartbeat() -> WatcherEvent {
        WatcherEvent::WorkingCopyHeartbeat { paths: vec![] }
    }

    #[test]
    fn register_overwrite_unregister_semantics() {
        let _guard = test_guard().lock().unwrap();
        CALLS.store(0, Ordering::SeqCst);

        zanshin_events_register(Some(recording_callback));
        dispatch(watcher_event_to_envelope(1, &heartbeat()));
        assert_eq!(CALLS.load(Ordering::SeqCst), 1);

        // A second register overwrites — one process-global slot, not a stack.
        zanshin_events_register(Some(recording_callback));
        dispatch(watcher_event_to_envelope(1, &heartbeat()));
        assert_eq!(CALLS.load(Ordering::SeqCst), 2);

        zanshin_events_unregister();
        dispatch(watcher_event_to_envelope(1, &heartbeat()));
        assert_eq!(CALLS.load(Ordering::SeqCst), 2, "no callback after unregister");
    }

    #[test]
    fn register_none_is_a_no_op() {
        let _guard = test_guard().lock().unwrap();
        zanshin_events_unregister();
        zanshin_events_register(None);
        assert!(SINK.lock().unwrap().is_none());
    }

    #[test]
    fn unregister_is_idempotent() {
        let _guard = test_guard().lock().unwrap();
        zanshin_events_unregister();
        zanshin_events_unregister();
        assert!(SINK.lock().unwrap().is_none());
    }

    #[test]
    fn dispatch_with_no_sink_drops() {
        let _guard = test_guard().lock().unwrap();
        zanshin_events_unregister();
        CALLS.store(0, Ordering::SeqCst);
        dispatch(watcher_event_to_envelope(1, &heartbeat()));
        assert_eq!(CALLS.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn watcher_event_op_heads_changed_round_trips() {
        let bytes = watcher_event_to_envelope(
            42,
            &WatcherEvent::OpHeadsChanged {
                paths: vec![PathBuf::from("/r/.jj/repo/op_heads/heads/abc")],
            },
        );
        let env = verified_envelope(&bytes);
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::WatcherEvent);
        let payload = env.data_as_watcher_event().expect("data_as_watcher_event must succeed");
        assert_eq!(payload.session_id(), 42);
        assert_eq!(payload.kind(), fbs::WatcherEventKind::OpHeadsChanged);
        let paths: Vec<&str> = payload.paths().expect("paths must be set").iter().collect();
        assert_eq!(paths, vec!["/r/.jj/repo/op_heads/heads/abc"]);
        assert_eq!(payload.message(), None);
    }

    #[test]
    fn watcher_event_working_copy_heartbeat_round_trips() {
        let bytes = watcher_event_to_envelope(
            7,
            &WatcherEvent::WorkingCopyHeartbeat {
                paths: vec![PathBuf::from("/r/.jj/working_copy/checkout")],
            },
        );
        let env = verified_envelope(&bytes);
        let payload = env.data_as_watcher_event().expect("data_as_watcher_event must succeed");
        assert_eq!(payload.kind(), fbs::WatcherEventKind::WorkingCopyHeartbeat);
        let paths: Vec<&str> = payload.paths().expect("paths must be set").iter().collect();
        assert_eq!(paths, vec!["/r/.jj/working_copy/checkout"]);
    }

    #[test]
    fn watcher_event_watch_error_round_trips_with_no_paths() {
        let bytes = watcher_event_to_envelope(
            9,
            &WatcherEvent::WatchError {
                message: "boom".to_owned(),
            },
        );
        let env = verified_envelope(&bytes);
        let payload = env.data_as_watcher_event().expect("data_as_watcher_event must succeed");
        assert_eq!(payload.kind(), fbs::WatcherEventKind::WatchError);
        assert_eq!(payload.message(), Some("boom"));
        assert!(
            payload.paths().is_none(),
            "paths absent for WatchError (null-for-absence)"
        );
    }

    #[test]
    fn progress_round_trips() {
        let bytes = progress_to_envelope(5, "fetch", 0.5, "halfway");
        let env = verified_envelope(&bytes);
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::Progress);
        let payload = env.data_as_progress().expect("data_as_progress must succeed");
        assert_eq!(payload.session_id(), 5);
        assert_eq!(payload.operation(), Some("fetch"));
        assert!((payload.progress() - 0.5).abs() < f32::EPSILON);
        assert_eq!(payload.message(), Some("halfway"));
    }
}
