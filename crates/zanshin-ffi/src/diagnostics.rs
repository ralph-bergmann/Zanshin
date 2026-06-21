// SPDX-License-Identifier: MIT

//! `zanshin_diagnostics` — infallible build-stamp + log-location FFI call.
//!
//! Handle-free: takes no arguments, dereferences no caller pointers.
//! Modelled after `zanshin_ffi_version` (no `unsafe`) but returns a
//! `FlatBuffers` `Envelope` instead of a lone C string (ADR-0001).

use crate::envelope::{catch, ok_diagnostics, FfiErrorObj};
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::tracing_init;

/// Return a `FlatBuffers` `Envelope` carrying build-stamp and log-location
/// diagnostics.
///
/// Returns a `FlatBuffers` `Envelope` with three diagnostic fields:
/// `app_version` (`CARGO_PKG_VERSION`), `git_sha` (`ZANSHIN_GIT_SHA` from
/// `build.rs`, `unknown` in a no-git build), and `log_path` (the absolute
/// log directory from `tracing_init::log_dir()`).
///
/// The function is infallible (two compile-time constants + one path resolution
/// with a temp fallback). The `envelope::catch` wrapper still provides the
/// `internal.panic` backstop.
///
/// The returned `*mut ZanshinBuf` **must** be freed exactly once via
/// `zanshin_buffer_free_token`.
#[no_mangle]
pub extern "C" fn zanshin_diagnostics() -> *mut ZanshinBuf {
    let buf = catch(|| {
        let log_path = tracing_init::log_dir();
        Ok::<_, FfiErrorObj>(ok_diagnostics(
            env!("CARGO_PKG_VERSION"),
            env!("ZANSHIN_GIT_SHA"),
            &log_path.to_string_lossy(),
        ))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope_generated::zanshin::ffi as fbs;
    use flatbuffers::VerifierOptions;

    fn verified_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
        let opts = VerifierOptions::default();
        flatbuffers::root_with_opts::<fbs::Envelope>(&opts, bytes).expect("FlatBuffers Verifier must pass")
    }

    #[test]
    fn diagnostics_envelope_has_version_sha_and_log_path() {
        let token = zanshin_diagnostics();
        assert!(!token.is_null(), "token must be non-null");

        // SAFETY: token is a valid ZanshinBuf produced by vec_into_token.
        let bytes = unsafe {
            let t = &*token;
            std::slice::from_raw_parts(t.ptr, t.len)
        };

        let env = verified_envelope(bytes);
        assert!(env.ok(), "ok must be true");
        assert_eq!(
            env.data_type(),
            fbs::Payload::Diagnostics,
            "data_type must be Diagnostics"
        );

        let diag = env.data_as_diagnostics().expect("data must be Diagnostics");
        assert_eq!(
            diag.app_version(),
            Some(env!("CARGO_PKG_VERSION")),
            "app_version must match CARGO_PKG_VERSION"
        );
        assert_eq!(
            diag.git_sha(),
            Some(env!("ZANSHIN_GIT_SHA")),
            "git_sha must match ZANSHIN_GIT_SHA"
        );
        assert_eq!(
            diag.log_path(),
            Some(tracing_init::log_dir().to_string_lossy().as_ref()),
            "log_path must match tracing_init::log_dir()"
        );

        // SAFETY: token was produced by vec_into_token; freed exactly once here.
        unsafe { crate::ffi_strings::zanshin_buffer_free_token(token) };
    }

    #[test]
    fn diagnostics_panic_backstop_returns_internal_panic() {
        let buf = catch(|| -> Result<Vec<u8>, FfiErrorObj> { panic!("backstop test") });
        let env = verified_envelope(&buf);
        assert!(!env.ok(), "ok must be false on panic");
        assert_eq!(
            env.error().and_then(|e| e.code()),
            Some(crate::INTERNAL_PANIC),
            "error code must be internal.panic"
        );
    }
}
