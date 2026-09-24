// SPDX-License-Identifier: MIT

//! `CString` helpers for lone-string FFI returns and the `FlatBuffers` buffer
//! ownership contract.
//!
//! **Ownership rule (ADR-0001):**
//! - Lone strings cross the FFI boundary as `*mut c_char` (`CString`). Dart frees
//!   them with `zanshin_string_free`.
//! - Composite data crosses as a single `FlatBuffers` buffer. Two equivalent
//!   release paths exist, both reclaiming the exact same Rust allocation:
//!     - the direct `(*mut u8, usize)` form (`vec_into_ffi_buf` →
//!       `zanshin_buffer_free(ptr, len)`) for synchronous read-then-free call sites;
//!     - the `*mut ZanshinBuf` token form (`vec_into_token` →
//!       `zanshin_buffer_free_token(token)`), the single-arg shape Dart's
//!       `NativeFinalizer` requires (see `app/lib/src/ffi/ffi_buffer.dart`).
//! - Both allocate with the Rust allocator and free with the same — never mix
//!   `malloc`/`free` across runtimes.

use crate::envelope::{FfiErrorObj, FFI_NULL_POINTER, FFI_UTF8_ERROR};
use std::ffi::{c_char, CStr, CString};

/// Convert a Rust `String` into a heap-allocated null-terminated C string.
///
/// Returns `ptr::null_mut()` when the string contains an interior nul byte
/// (which `CString::new` rejects).  FFI wrappers must treat `null` as an
/// `internal.panic` condition.
///
/// The caller MUST free the returned pointer via `zanshin_string_free`.
#[must_use]
pub fn string_to_cstring(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Convert a NUL-terminated C string (input direction) into an owned Rust `String`.
///
/// # Safety
/// `ptr` must be null or a valid NUL-terminated C string that stays valid for this call.
///
/// # Errors
/// - Returns `Err(FFI_NULL_POINTER)` when `ptr` is null.
/// - Returns `Err(FFI_UTF8_ERROR)` when the byte sequence is not valid UTF-8.
pub unsafe fn cstr_to_string(ptr: *const c_char) -> Result<String, FfiErrorObj> {
    if ptr.is_null() {
        return Err(FfiErrorObj {
            report: None,
            code: FFI_NULL_POINTER.to_owned(),
            context: None,
        });
    }
    // SAFETY: caller guarantees ptr is a valid NUL-terminated C string for the call.
    let cstr = unsafe { CStr::from_ptr(ptr) };
    cstr.to_str().map(ToOwned::to_owned).map_err(|_| FfiErrorObj {
        report: None,
        code: FFI_UTF8_ERROR.to_owned(),
        context: None,
    })
}

/// Release a C string that was allocated by `string_to_cstring`.
///
/// Passing `ptr::null_mut()` is a no-op.  Passing any other pointer not
/// produced by `string_to_cstring` is undefined behaviour.
///
/// # Safety
/// `ptr` must be a pointer previously returned by `string_to_cstring`, or
/// `ptr::null_mut()`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: ptr was produced by CString::into_raw() in string_to_cstring,
        // so it is a valid, non-aliased, heap-allocated null-terminated string.
        drop(unsafe { CString::from_raw(ptr) });
    }
}

/// Consume a `FlatBuffers` `Vec<u8>` and return a `(ptr, len)` pair that can
/// cross the FFI boundary.
///
/// The returned buffer MUST be freed by the caller via
/// `zanshin_buffer_free(ptr, len)`.  Never call `free()` on the pointer
/// directly — it was allocated by the Rust allocator, not `malloc`.
#[must_use]
pub fn vec_into_ffi_buf(buf: Vec<u8>) -> (*mut u8, usize) {
    // Box<[u8]> guarantees len == capacity, which lets zanshin_buffer_free
    // reconstruct the exact original allocation with Box::from_raw.
    let boxed: Box<[u8]> = buf.into_boxed_slice();
    let len = boxed.len();
    let ptr = Box::into_raw(boxed).cast::<u8>();
    (ptr, len)
}

// ── NativeFinalizer support ───────────────────────────────────────────────────
//
// Dart's NativeFinalizer requires a C callback taking a single `Pointer<Void>`.
// `zanshin_buffer_free(ptr, len)` takes two args and cannot be used directly.
// Solution: wrap ptr+len in a heap-allocated `ZanshinBuf` token (Rust-owned).
// Dart holds a `Pointer<ZanshinBuf>`, registers it with NativeFinalizer pointing
// at `zanshin_buffer_free_token`, and calls `zanshin_buffer_free_token(token)`
// in `dispose()`. The callback frees both the buffer and the token struct.

/// Opaque ownership token for a `FlatBuffers` buffer returned across the FFI
/// boundary.  Dart holds a `Pointer<ZanshinBuf>` and registers it with
/// `NativeFinalizer(zanshin_buffer_free_token)` so the GC can release the
/// buffer even if the Dart owner is collected without an explicit `dispose()`.
#[repr(C)]
pub struct ZanshinBuf {
    pub ptr: *mut u8,
    pub len: usize,
}

// SAFETY: the buffer pointed to by `ptr` is Rust-heap-allocated, uniquely
// owned by this `ZanshinBuf`, and accessed by only one thread at a time
// (the Dart worker isolate owns all FFI handles — AD-2).
unsafe impl Send for ZanshinBuf {}
unsafe impl Sync for ZanshinBuf {}

/// Consume a `FlatBuffers` `Vec<u8>` into a heap-allocated `ZanshinBuf` token.
/// The caller (an FFI function) returns the raw token pointer to Dart; Dart
/// registers it with `NativeFinalizer` using `zanshin_buffer_free_token`.
#[must_use]
pub fn vec_into_token(buf: Vec<u8>) -> *mut ZanshinBuf {
    let boxed_buf: Box<[u8]> = buf.into_boxed_slice();
    let len = boxed_buf.len();
    let ptr = Box::into_raw(boxed_buf).cast::<u8>();
    Box::into_raw(Box::new(ZanshinBuf { ptr, len }))
}

/// Free both the `FlatBuffers` buffer and the `ZanshinBuf` token struct.
///
/// This is the `NativeFinalizer` callback registered in Dart's `FfiBuffer`.
/// Also called directly by `FfiBuffer.dispose()` (which detaches the finalizer
/// first to prevent a double-free).
///
/// Passing `null` is a no-op.
///
/// # Safety
/// `token` must be a non-null pointer produced by `vec_into_token` that has
/// not been freed before.
#[no_mangle]
pub unsafe extern "C" fn zanshin_buffer_free_token(token: *mut ZanshinBuf) {
    if token.is_null() {
        return;
    }
    // SAFETY: token was produced by Box::into_raw(Box::new(ZanshinBuf{...}))
    // in vec_into_token; no other code frees it, and the caller guarantees
    // it is called at most once (NativeFinalizer detach + dispose pattern).
    let t = unsafe { Box::from_raw(token) };
    if !t.ptr.is_null() && t.len > 0 {
        // SAFETY: t.ptr+t.len were produced by Box::<[u8]>::into_raw in
        // vec_into_token; same allocator, matching capacity (boxed-slice).
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(t.ptr, t.len)) });
    }
}

/// Release a `FlatBuffers` buffer allocated by a Rust FFI function, given the
/// raw `(ptr, len)` pair produced by `vec_into_ffi_buf`.
///
/// This is the direct release path for synchronous read-then-free call sites.
/// The GC-backed alternative is the token path (`vec_into_token` +
/// `zanshin_buffer_free_token`), which Dart's `FfiBuffer`/`NativeFinalizer`
/// uses; both reclaim the identical Rust allocation. Never call `free()` on the
/// pointer directly — it was allocated by the Rust allocator, not `malloc`.
///
/// Passing `ptr::null_mut()` or `len == 0` is a no-op.
///
/// # Safety
/// `ptr` and `len` must be the exact pair returned by a `zanshin_*` FFI
/// function.  The buffer must not have been freed before.
#[no_mangle]
pub unsafe extern "C" fn zanshin_buffer_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    // SAFETY: ptr+len came from Box::<[u8]>::into_raw in vec_into_ffi_buf.
    // Reconstructing as *mut [u8] and converting back to Box<[u8]> is the
    // exact inverse of the allocation path.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn string_to_cstring_roundtrip() {
        let ptr = string_to_cstring("hello".to_owned());
        assert!(!ptr.is_null());
        // SAFETY: ptr is a valid CString we just allocated.
        unsafe { zanshin_string_free(ptr) };
    }

    #[test]
    fn string_free_null_noop() {
        // SAFETY: null is explicitly documented as a no-op.
        unsafe { zanshin_string_free(std::ptr::null_mut()) };
    }

    #[test]
    fn string_to_cstring_interior_nul_returns_null() {
        let ptr = string_to_cstring("hel\0lo".to_owned());
        assert!(ptr.is_null());
    }

    #[test]
    fn buffer_roundtrip() {
        let original = vec![10u8, 20, 30, 40];
        let (ptr, len) = vec_into_ffi_buf(original);
        assert!(!ptr.is_null());
        assert_eq!(len, 4);
        // SAFETY: ptr+len are exactly what vec_into_ffi_buf returned.
        unsafe { zanshin_buffer_free(ptr, len) };
    }

    #[test]
    fn buffer_free_null_noop() {
        // SAFETY: null + 0 is explicitly documented as a no-op.
        unsafe { zanshin_buffer_free(std::ptr::null_mut(), 0) };
    }

    #[test]
    fn token_roundtrip() {
        let original = vec![42u8, 43, 44];
        let token = vec_into_token(original);
        assert!(!token.is_null());
        // SAFETY: token was produced by vec_into_token.
        let (ptr, len) = unsafe { ((*token).ptr, (*token).len) };
        assert!(!ptr.is_null());
        assert_eq!(len, 3);
        // SAFETY: token is valid; freeing it here is the dispose() path.
        unsafe { zanshin_buffer_free_token(token) };
    }

    #[test]
    fn token_free_null_noop() {
        // SAFETY: null is explicitly documented as a no-op.
        unsafe { zanshin_buffer_free_token(std::ptr::null_mut()) };
    }

    #[test]
    fn buffer_empty_vec() {
        // An empty Vec produces a dangling-but-aligned pointer and len == 0.
        // zanshin_buffer_free must handle this gracefully.
        let (ptr, len) = vec_into_ffi_buf(Vec::new());
        assert_eq!(len, 0);
        // SAFETY: len == 0 triggers the early return in zanshin_buffer_free.
        unsafe { zanshin_buffer_free(ptr, len) };
    }

    #[test]
    fn cstr_to_string_valid_returns_ok() {
        let c = CString::new("hello FFI").unwrap();
        // SAFETY: c.as_ptr() is a valid NUL-terminated C string that lives for this call.
        let result = unsafe { cstr_to_string(c.as_ptr()) };
        assert_eq!(result.unwrap(), "hello FFI");
    }

    #[test]
    fn cstr_to_string_null_returns_null_pointer_error() {
        // SAFETY: null is the documented null-return path.
        let result = unsafe { cstr_to_string(std::ptr::null()) };
        assert!(result.is_err());
        assert_eq!(result.unwrap_err().code, "ffi.null_pointer");
    }

    #[test]
    fn cstr_to_string_invalid_utf8_returns_utf8_error() {
        // 0xFF 0xFE are not valid UTF-8; 0x00 terminates the C string.
        let raw: [u8; 3] = [0xFF, 0xFE, 0x00];
        // SAFETY: raw is a valid NUL-terminated byte slice that lives for this call.
        let result = unsafe { cstr_to_string(raw.as_ptr().cast::<c_char>()) };
        assert!(result.is_err());
        assert_eq!(result.unwrap_err().code, "ffi.utf8_error");
    }

    #[test]
    fn token_empty_vec() {
        // An empty Vec yields a token whose inner buffer is dangling with
        // len == 0. zanshin_buffer_free_token must skip the (zero-size) inner
        // buffer free yet still free the ZanshinBuf token struct itself.
        let token = vec_into_token(Vec::new());
        assert!(!token.is_null());
        // SAFETY: token was produced by vec_into_token; len == 0 skips the
        // inner buffer free but the token box is always reclaimed.
        let len = unsafe { (*token).len };
        assert_eq!(len, 0);
        // SAFETY: token is valid and freed exactly once here.
        unsafe { zanshin_buffer_free_token(token) };
    }
}
