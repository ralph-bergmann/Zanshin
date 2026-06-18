// SPDX-License-Identifier: Apache-2.0
//! Dart → Rust log forwarding (AR-P-5).
//!
//! Dart never owns a log sink. A thin Dart logging façade (`package:logging`)
//! forwards every record across the FFI boundary via [`zanshin_log`], which
//! re-emits it into the process-wide `tracing` subscriber installed by
//! [`crate::tracing_init`]. Rust stays the single log sink.
//!
//! **Level contract (mirrored in `app/lib/src/ffi/log_forwarder.dart`):** the
//! `level` argument is a small, stable integer — deliberately NOT
//! `package:logging`'s numeric levels (those are mapped on the Dart side):
//!
//! | `level` | `tracing` level |
//! |---------|-----------------|
//! | `1`     | `error`         |
//! | `2`     | `warn`          |
//! | `3`     | `info`          |
//! | `4`     | `debug`         |
//! | `5` / other | `trace`     |
//!
//! `debug`/`trace` are compiled out in release builds (`release_max_level_info`),
//! exactly as for Rust-origin logs.

use core::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::ffi_strings::cstr_to_string;

/// Static `tracing` target for every Dart-origin record. The originating
/// `package:logging` logger name is preserved as the `logger` field, so
/// `ZANSHIN_LOG=zanshin::dart=debug` can scope Dart logs independently.
const DART_TARGET: &str = "zanshin::dart";

const LEVEL_ERROR: i32 = 1;
const LEVEL_WARN: i32 = 2;
const LEVEL_INFO: i32 = 3;
const LEVEL_DEBUG: i32 = 4;
// 5 and any other value fall through to `trace`.

/// Forward a single log record from Dart into the Rust `tracing` sink (AR-P-5).
///
/// Infallible by contract: a null/invalid argument or an internal panic **drops
/// the record** rather than surfacing an error — logging must never break the
/// caller, and no panic may cross the C ABI.
///
/// `level` maps onto a `tracing` level (1=error … 5=trace; see the module table).
/// `target` is the originating logger name (recorded as the `logger` field) and
/// `message` is the formatted line. Both are borrowed for the duration of the
/// call only: **Dart owns and frees both C strings** (the reverse of the outbound
/// `zanshin_string_free` ownership rule).
///
/// Handle-free, so it is exempt from the single-consumer rule (AD-2) and may be
/// called from any isolate — `tracing`'s global subscriber is thread-safe.
///
/// # Safety
/// `target` and `message` must each be null or a valid NUL-terminated C string
/// that stays valid for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn zanshin_log(level: i32, target: *const c_char, message: *const c_char) {
    // Logging must neither unwind across the C ABI nor break the caller: a panic
    // (or a malformed argument) drops the record silently. AssertUnwindSafe is
    // sound here because the closure only reads the pointers and emits a log —
    // there is no observable broken invariant to leak on unwind.
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: forwarded from this function's contract — both pointers are
        // null or valid NUL-terminated C strings live for the call.
        let Ok(message) = (unsafe { cstr_to_string(message) }) else {
            return;
        };
        // SAFETY: same contract; a null/invalid target degrades to an empty
        // logger name rather than dropping the (valid) message.
        let logger = unsafe { cstr_to_string(target) }.unwrap_or_default();
        emit(level, &logger, &message);
    }));
}

/// Re-emit a forwarded record at the mapped `tracing` level. Split out from the
/// `extern "C"` shell so it is unit-testable against a scoped subscriber.
fn emit(level: i32, logger: &str, message: &str) {
    match level {
        LEVEL_ERROR => tracing::error!(target: DART_TARGET, logger, "{message}"),
        LEVEL_WARN => tracing::warn!(target: DART_TARGET, logger, "{message}"),
        LEVEL_INFO => tracing::info!(target: DART_TARGET, logger, "{message}"),
        LEVEL_DEBUG => tracing::debug!(target: DART_TARGET, logger, "{message}"),
        _ => tracing::trace!(target: DART_TARGET, logger, "{message}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::io;
    use std::sync::{Arc, Mutex};
    use tracing_subscriber::fmt::MakeWriter;
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::EnvFilter;

    #[derive(Clone, Default)]
    struct Recorder(Arc<Mutex<Vec<u8>>>);

    impl Recorder {
        fn contents(&self) -> String {
            String::from_utf8(self.0.lock().unwrap().clone()).unwrap()
        }
    }

    impl io::Write for Recorder {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl<'a> MakeWriter<'a> for Recorder {
        type Writer = Recorder;
        fn make_writer(&'a self) -> Self::Writer {
            self.clone()
        }
    }

    // Capture everything down to `trace` so level-mapping assertions are not
    // masked by a filter (debug/trace still compile in for `cargo test`, which
    // builds in debug — `release_max_level_info` only bites in release builds).
    fn run_scoped(body: impl FnOnce()) -> String {
        let rec = Recorder::default();
        let subscriber = tracing_subscriber::registry().with(EnvFilter::new("trace")).with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_writer(rec.clone()),
        );
        tracing::subscriber::with_default(subscriber, body);
        rec.contents()
    }

    #[test]
    fn emit_records_message_and_logger_field() {
        let out = run_scoped(|| emit(LEVEL_INFO, "my.logger", "hello dart"));
        assert!(out.contains("hello dart"));
        assert!(out.contains("logger"));
        assert!(out.contains("my.logger"));
        assert!(out.contains("INFO"));
    }

    #[test]
    fn emit_maps_levels_to_tracing_labels() {
        assert!(run_scoped(|| emit(LEVEL_ERROR, "l", "m")).contains("ERROR"));
        assert!(run_scoped(|| emit(LEVEL_WARN, "l", "m")).contains("WARN"));
        assert!(run_scoped(|| emit(LEVEL_INFO, "l", "m")).contains("INFO"));
        assert!(run_scoped(|| emit(LEVEL_DEBUG, "l", "m")).contains("DEBUG"));
        assert!(run_scoped(|| emit(5, "l", "m")).contains("TRACE"));
    }

    #[test]
    fn emit_unknown_level_falls_through_to_trace() {
        // Out-of-range levels must not panic; they degrade to `trace`.
        assert!(run_scoped(|| emit(999, "l", "m")).contains("TRACE"));
        assert!(run_scoped(|| emit(-1, "l", "m")).contains("TRACE"));
    }

    #[test]
    fn zanshin_log_null_pointers_are_a_silent_noop() {
        // A null message drops the record; a null target alone must never panic.
        // SAFETY: null is the documented no-op input.
        unsafe { zanshin_log(LEVEL_INFO, std::ptr::null(), std::ptr::null()) };
    }

    #[test]
    fn zanshin_log_valid_call_emits_through_global_subscriber() {
        let target = CString::new("dart.test").unwrap();
        let message = CString::new("forwarded line").unwrap();
        let out = run_scoped(|| {
            // SAFETY: both pointers are valid NUL-terminated C strings that
            // outlive the call.
            unsafe { zanshin_log(LEVEL_WARN, target.as_ptr(), message.as_ptr()) };
        });
        assert!(out.contains("forwarded line"));
        assert!(out.contains("dart.test"));
        assert!(out.contains("WARN"));
    }

    #[test]
    fn zanshin_log_null_target_keeps_valid_message() {
        let message = CString::new("msg without target").unwrap();
        let out = run_scoped(|| {
            // SAFETY: message is valid; target is the documented null no-op.
            unsafe { zanshin_log(LEVEL_INFO, std::ptr::null(), message.as_ptr()) };
        });
        assert!(out.contains("msg without target"));
    }
}
