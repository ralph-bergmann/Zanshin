// SPDX-License-Identifier: Apache-2.0

//! `zanshin-ffi` — single cdylib FFI boundary for the Zanshin Rust core.
//!
//! WIP scope (Story 1.5): only the `zanshin_ffi_version()` build-stamp symbol is
//! declared here, so `cargo make codegen` has at least one `extern "C"` function
//! to lift into `include/zanshin_ffi.h` and `app/lib/src/ffi/bindings.dart`. The
//! full FFI surface (envelope, handle helpers, panic-catch wrapper, repo/diff/
//! graph/watcher wrappers) lands in Epic 3. The full `zanshin_ffi_version()`
//! implementation with `build.rs` git-SHA injection and `CString` allocation
//! lands in Story 3.2.

use core::ffi::c_char;

// WHY: flatc-generated code is not subject to our lint bar; warnings there are
// noise from machine output, not actionable refactors.
#[allow(warnings)]
pub(crate) mod envelope_generated;

pub mod envelope;
pub use envelope::*;

pub mod ffi_strings;

/// Build-stamp version string. WIP-placeholder: returns a static C-string pointer
/// to the crate version. Story 3.2 replaces this with a heap-allocated
/// `<version> (<git-sha>)` string via `ffi_strings::string_to_cstring` and a
/// `build.rs` that injects `ZANSHIN_GIT_SHA` at compile time.
///
/// # Safety
/// The returned pointer is a `'static` literal — the caller MUST NOT free it.
/// Story 3.2's replacement returns a heap pointer and pairs with
/// `zanshin_string_free`; the placeholder does not.
#[no_mangle]
pub extern "C" fn zanshin_ffi_version() -> *const c_char {
    // WHY: c"" literal (stable Rust 1.77+) — null terminator guaranteed by the
    // compiler, no manual \0, no allocation, no build.rs. Replaced wholesale in 3.2.
    c"0.1.0".as_ptr()
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
}
