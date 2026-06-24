// SPDX-License-Identifier: MIT

//! `zanshin-ffi` — single cdylib FFI boundary for the Zanshin Rust core.
//!
//! Exposes the FFI surface to Dart via `extern "C"` symbols. Generated bindings
//! live in `crates/zanshin-ffi/include/zanshin_ffi.h` and
//! `app/lib/src/ffi/bindings.dart`; regenerate with `cargo make codegen`.
//!
//! `zanshin_ffi_version()` returns a heap-allocated `"<version> (<git-sha>)"`
//! build-stamp; the caller must free it via `zanshin_string_free`. The SHA is
//! injected by `build.rs` at compile time (`ZANSHIN_GIT_SHA`).

use core::ffi::c_char;

// WHY: flatc-generated code is not subject to our lint bar; warnings there are
// noise from machine output, not actionable refactors.
#[allow(warnings)]
pub(crate) mod envelope_generated;

/// Re-export of the flatc-generated `FlatBuffers` accessors for `schemas/envelope.fbs`.
///
/// Integration tests and Dart-side consumers that read `ZanshinBuf` buffers use these
/// generated typed accessors (`Envelope`, `Payload`, `RepoHandle`, …) and the
/// `flatbuffers::root` verifier to parse and validate FFI return values.
// WHY: pub(crate) on the module itself prevents cluttering the public API with the
// raw module path; this re-export provides a stable, doc-visible alias.
pub use envelope_generated::zanshin::ffi as fbs;

pub mod envelope;
pub use envelope::*;

pub mod change;
pub mod diagnostics;
pub mod ffi_strings;
pub mod handle;
pub mod logging;
pub mod op_log;
pub mod repo;
pub mod status;
pub mod tracing_init;

/// Build-stamp version string.
///
/// Returns a heap-allocated `"<crate version> (<git sha>)"` C string, e.g.
/// `"0.1.0 (5d7577e06a76)"`. The git SHA is injected at compile time by `build.rs`
/// via the `ZANSHIN_GIT_SHA` env var; source-tarball builds without a git checkout
/// stamp as `unknown`.
///
/// The caller **MUST** free the returned pointer via `zanshin_string_free`. The
/// pointer is heap-allocated (not a `'static` literal) and is not safe to use after
/// `zanshin_string_free` is called on it.
#[no_mangle]
pub extern "C" fn zanshin_ffi_version() -> *mut c_char {
    let version = format!("{} ({})", env!("CARGO_PKG_VERSION"), env!("ZANSHIN_GIT_SHA"));
    ffi_strings::string_to_cstring(version)
}

#[cfg(test)]
mod tests {
    use crate::envelope_generated::zanshin::ffi as fbs;
    use crate::ffi_strings::vec_into_ffi_buf;
    use flatbuffers::VerifierOptions;

    fn verified_root(bytes: &[u8]) -> fbs::Envelope<'_> {
        let opts = VerifierOptions::default();
        flatbuffers::root_with_opts::<fbs::Envelope>(&opts, bytes)
            .expect("FlatBuffers Verifier must pass for a well-formed Envelope buffer")
    }

    #[test]
    fn envelope_buffer_ffi_roundtrip() {
        // Push an Envelope buffer through the FFI ownership contract and read it back —
        // simulates the full Rust-produce / Dart-consume / zanshin_buffer_free path.
        let buf = crate::err(crate::INTERNAL_PANIC, None);

        let (ptr, len) = vec_into_ffi_buf(buf);
        assert!(!ptr.is_null());
        assert!(len > 0);

        // Reconstruct from raw pointer (as Dart would via a Uint8List view).
        // SAFETY: ptr+len are exactly what vec_into_ffi_buf returned, and we
        // have not yet freed the buffer.
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
        let env = verified_root(bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(crate::INTERNAL_PANIC));

        // Free — must not crash or double-free.
        // SAFETY: ptr+len are the exact pair from vec_into_ffi_buf; bytes borrow
        // ends before we free.
        unsafe { crate::ffi_strings::zanshin_buffer_free(ptr, len) };
    }

    #[test]
    fn ffi_version_has_version_and_sha_format() {
        let ptr = crate::zanshin_ffi_version();
        assert!(!ptr.is_null());
        // SAFETY: zanshin_ffi_version returns a valid heap-allocated NUL-terminated
        // C string; we read it before freeing.
        let version_str = unsafe { std::ffi::CStr::from_ptr(ptr).to_str().unwrap().to_owned() };
        // Must start with the crate version.
        assert!(
            version_str.starts_with(env!("CARGO_PKG_VERSION")),
            "version string '{version_str}' must start with CARGO_PKG_VERSION"
        );
        // Must match the "<version> (<sha>)" shape.
        assert!(
            version_str.contains(" (") && version_str.ends_with(')'),
            "version string '{version_str}' must match '<version> (<sha>)' shape"
        );
        // Free the heap pointer via the canonical free function.
        // SAFETY: ptr is the exact pointer from zanshin_ffi_version; freed exactly once.
        unsafe { crate::ffi_strings::zanshin_string_free(ptr) };
    }
}
