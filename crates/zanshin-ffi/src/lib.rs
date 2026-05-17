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
