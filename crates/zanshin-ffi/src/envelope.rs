// SPDX-License-Identifier: MIT
//! `FlatBuffers` `Envelope` builders, AR-P-4 error-code emission, and the `catch_unwind` panic backstop.
//!
//! Every pub function returns a finished, owned `Vec<u8>`. Conversion to the FFI
//! `(*mut u8, len)` token happens at the `extern "C"` call site (Story 3.4a) via
//! `ffi_strings::vec_into_ffi_buf` / `vec_into_token`. This module owns nothing beyond
//! the build step.

use crate::envelope_generated::zanshin::ffi as fbs;
use flatbuffers::FlatBufferBuilder;
use std::any::Any;
use std::panic::{catch_unwind, UnwindSafe};

/// AR-P-4 single-emission-point: the canonical `catch_unwind` panic error code.
pub const INTERNAL_PANIC: &str = "internal.panic";

/// AR-P-4: emitted by `handle::validate_handle` when a Dart-supplied handle pointer is null.
pub const FFI_INVALID_HANDLE: &str = "ffi.invalid_handle";
/// AR-P-4: emitted by `ffi_strings::cstr_to_string` when a required `*const c_char` is null.
pub const FFI_NULL_POINTER: &str = "ffi.null_pointer";
/// AR-P-4: emitted by `ffi_strings::cstr_to_string` when a `*const c_char` contains invalid UTF-8.
pub const FFI_UTF8_ERROR: &str = "ffi.utf8_error";

/// Pre-serialised, input-free `internal.panic` `Envelope` buffer.
///
/// Last-resort backstop for [`catch`]: returned only if building a normal error `Envelope`
/// *itself* panics (essentially unreachable — `err` builds a small in-memory buffer — but a
/// panic backstop must never unwind across the C ABI). These bytes are exactly
/// `err(INTERNAL_PANIC, None)`; the `panic_fallback_const_matches_builder` test keeps them in sync.
const PANIC_FALLBACK_ENVELOPE: &[u8] = &[
    12, 0, 0, 0, 8, 0, 10, 0, 0, 0, 4, 0, 8, 0, 0, 0, 12, 0, 0, 0, 0, 0, 6, 0, 8, 0, 4, 0, 6, 0, 0, 0, 4, 0, 0, 0, 14,
    0, 0, 0, 105, 110, 116, 101, 114, 110, 97, 108, 46, 112, 97, 110, 105, 99, 0, 0,
];

/// Rust-side mirror of the `FlatBuffers` `FfiError` table (`schemas/envelope.fbs`).
///
/// `code` — dotted `<domain>.<reason>` string (see `docs/rust-error-codes.md`).
/// `context` — optional human-readable detail; user data goes here, never in `code`.
#[derive(Debug, Clone)]
pub struct FfiErrorObj {
    pub code: String,
    pub context: Option<String>,
}

/// Build a success `Envelope` with no payload and return the finished buffer.
///
/// Sets `ok = true`, `error = None`, `data_type = Payload::NONE`. The first real
/// payload builder (`ok(payload)`) arrives in Story 3.4a; this covers the no-payload case.
#[must_use]
pub fn ok_empty() -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128);
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::NONE,
            data: None,
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// Build an error `Envelope` and return the finished buffer.
///
/// Sets `ok = false`, `data_type = Payload::NONE`, and populates `FfiError { code, context }`.
/// `code` must be a dotted `<domain>.<reason>` string (see `docs/rust-error-codes.md`).
/// User-visible detail belongs in `context`, never in `code`.
#[must_use]
pub fn err(code: &str, context: Option<&str>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let code_off = b.create_string(code);
    let ctx_off = context.map(|c| b.create_string(c));
    let error = fbs::FfiError::create(
        &mut b,
        &fbs::FfiErrorArgs {
            code: Some(code_off),
            context: ctx_off,
        },
    );
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: false,
            error: Some(error),
            data_type: fbs::Payload::NONE,
            data: None,
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// Wrap a fallible closure in `std::panic::catch_unwind` and return a finished `Envelope` buffer.
///
/// The closure `f` returns `Result<Vec<u8>, FfiErrorObj>` where `Ok(buf)` is an
/// already-finished `Envelope` buffer (e.g. from `ok_empty()`) and `Err(e)` is an
/// error to be converted via `err()`. Keeping `FlatBufferBuilder` inside the closure (which
/// produces a plain `Vec<u8>`, which is `UnwindSafe`) means only `f` itself must satisfy
/// `UnwindSafe` — no `AssertUnwindSafe` gymnastics needed here.
///
/// Outcome mapping:
/// - `Ok(Ok(buf))` — the success buffer the closure built is returned as-is.
/// - `Ok(Err(e))` — converted to an error `Envelope` via `err_never_unwind`.
/// - `Err(panic)` — converted to `err_never_unwind(INTERNAL_PANIC, <panic message>)`.
///
/// The error/panic arms build their `Envelope` via [`err_never_unwind`], so a (essentially
/// unreachable) panic *inside* `err` can never unwind out of this backstop and across the C
/// ABI. This relies on the crate being built with `panic = "unwind"` (the workspace default);
/// under `panic = "abort"`, `catch_unwind` cannot intercept at all.
#[must_use]
pub fn catch<F>(f: F) -> Vec<u8>
where
    F: FnOnce() -> Result<Vec<u8>, FfiErrorObj> + UnwindSafe,
{
    match catch_unwind(f) {
        Ok(Ok(buf)) => buf,
        Ok(Err(e)) => err_never_unwind(&e.code, e.context.as_deref()),
        Err(panic) => err_never_unwind(INTERNAL_PANIC, Some(&panic_message(panic.as_ref()))),
    }
}

/// Build an error `Envelope` without ever unwinding.
///
/// `err` builds a small in-memory `FlatBuffers` buffer, so a panic here is unreachable in
/// practice — but a panic backstop must give a hard guarantee, not a probabilistic one. If
/// `err` ever panics, fall back to the pre-serialised [`PANIC_FALLBACK_ENVELOPE`]. The only
/// remaining failure mode is allocation failure, which aborts the process rather than
/// unwinding — so no panic can cross the C ABI through this path.
fn err_never_unwind(code: &str, context: Option<&str>) -> Vec<u8> {
    catch_unwind(|| err(code, context)).unwrap_or_else(|_| PANIC_FALLBACK_ENVELOPE.to_vec())
}

fn panic_message(p: &(dyn Any + Send)) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        return (*s).to_owned();
    }
    if let Some(s) = p.downcast_ref::<String>() {
        return s.clone();
    }
    "<unknown panic payload>".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope_generated::zanshin::ffi as fbs;
    use flatbuffers::VerifierOptions;

    fn verified_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
        let opts = VerifierOptions::default();
        flatbuffers::root_with_opts::<fbs::Envelope>(&opts, bytes)
            .expect("FlatBuffers Verifier must pass for a well-formed Envelope buffer")
    }

    #[test]
    fn ok_empty_produces_success_envelope() {
        let buf = ok_empty();
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert!(env.error().is_none());
        assert_eq!(env.data_type(), fbs::Payload::NONE);
    }

    #[test]
    fn err_with_context_roundtrip() {
        let buf = err("jj.repo_not_found", Some("/no/such/path"));
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present when ok==false");
        assert_eq!(e.code(), Some("jj.repo_not_found"));
        assert_eq!(e.context(), Some("/no/such/path"));
    }

    #[test]
    fn err_without_context_has_none() {
        let buf = err("ffi.null_pointer", None);
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present");
        assert_eq!(e.code(), Some("ffi.null_pointer"));
        assert!(e.context().is_none());
    }

    #[test]
    fn catch_ok_closure_returns_success_envelope() {
        let buf = catch(|| Ok(ok_empty()));
        let env = verified_envelope(&buf);
        assert!(env.ok());
        assert!(env.error().is_none());
        assert_eq!(env.data_type(), fbs::Payload::NONE);
    }

    #[test]
    fn catch_err_closure_returns_error_envelope() {
        let buf = catch(|| {
            Err(FfiErrorObj {
                code: "ffi.invalid_handle".to_owned(),
                context: Some("handle was zero".to_owned()),
            })
        });
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present");
        assert_eq!(e.code(), Some("ffi.invalid_handle"));
        assert_eq!(e.context(), Some("handle was zero"));
    }

    #[test]
    fn catch_panic_macro_captures_str_message() {
        let buf = catch(|| -> Result<Vec<u8>, FfiErrorObj> { panic!("boom") });
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present after panic");
        assert_eq!(e.code(), Some(INTERNAL_PANIC));
        assert!(
            e.context().is_some_and(|c| c.contains("boom")),
            "panic message 'boom' must appear in context"
        );
    }

    #[test]
    fn catch_panic_string_payload_captures_message() {
        let buf = catch(|| -> Result<Vec<u8>, FfiErrorObj> { std::panic::panic_any(String::from("string payload")) });
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present");
        assert_eq!(e.code(), Some(INTERNAL_PANIC));
        assert_eq!(e.context(), Some("string payload"));
    }

    #[test]
    fn catch_panic_non_string_payload_yields_unknown() {
        let buf = catch(|| -> Result<Vec<u8>, FfiErrorObj> { std::panic::panic_any(42u8) });
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        let e = env.error().expect("error must be present");
        assert_eq!(e.code(), Some(INTERNAL_PANIC));
        assert_eq!(e.context(), Some("<unknown panic payload>"));
    }

    #[test]
    fn panic_fallback_const_matches_builder() {
        // Keeps PANIC_FALLBACK_ENVELOPE honest: it must be byte-identical to the builder's
        // output for the input-free internal.panic error, or err_never_unwind's last resort
        // would ship a stale buffer.
        assert_eq!(err(INTERNAL_PANIC, None).as_slice(), PANIC_FALLBACK_ENVELOPE);
    }

    #[test]
    fn panic_fallback_const_is_a_valid_error_envelope() {
        let env = verified_envelope(PANIC_FALLBACK_ENVELOPE);
        assert!(!env.ok());
        let e = env.error().expect("fallback must carry an error");
        assert_eq!(e.code(), Some(INTERNAL_PANIC));
        assert!(e.context().is_none());
    }

    #[test]
    fn err_never_unwind_matches_err_on_normal_input() {
        assert_eq!(
            err_never_unwind("jj.repo_not_found", Some("/x")),
            err("jj.repo_not_found", Some("/x"))
        );
    }
}
