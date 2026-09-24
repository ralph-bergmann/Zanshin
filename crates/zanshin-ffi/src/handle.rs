// SPDX-License-Identifier: MIT
//! AD-2 opaque-handle helpers: Rust owns every handle as `Box<T>`; Dart holds the raw
//! `*mut c_void`. `zanshin_X_open` leaks a `Box` via [`handle_into_raw`]; `zanshin_X_close`
//! reclaims it via [`handle_drop`]. Single-threaded worker-isolate access (AD-2) — no locking.

use crate::envelope::{FfiErrorObj, FFI_INVALID_HANDLE};
use std::ffi::c_void;

/// Box `value` and return a raw pointer. The caller (the `zanshin_X_open` half of AD-2's
/// lifecycle pair) owns the heap allocation until it passes the pointer back to [`handle_drop`].
#[must_use]
pub fn handle_into_raw<T>(value: T) -> *mut T {
    Box::into_raw(Box::new(value))
}

/// Borrow a raw handle pointer as `&mut T`.
///
/// # Safety
/// `ptr` must be null or a pointer returned by [`handle_into_raw`] that is still live.
/// The caller must not hold two `&mut` to the same handle simultaneously (AD-2 guarantees
/// this: the single worker isolate serialises all handle access).
pub unsafe fn handle_from_raw<'a, T>(ptr: *mut T) -> Option<&'a mut T> {
    // SAFETY: null yields None; otherwise the caller's invariant makes the deref sound.
    unsafe { ptr.as_mut() }
}

/// Reclaim and drop a boxed handle.
///
/// # Safety
/// `ptr` must be null or a live pointer from [`handle_into_raw`]; it must not be dropped twice.
/// Double-drop is UB at the C ABI; Dart's `Finalizer` detach-then-close pattern (Story 3.9)
/// prevents accidental double-free from Dart.
pub unsafe fn handle_drop<T>(ptr: *mut T) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: ptr came from Box::into_raw(Box::new(_)) in handle_into_raw; reclaiming as
    // Box<T> is the exact inverse, and the caller guarantees a single drop.
    drop(unsafe { Box::from_raw(ptr) });
}

/// Null-check a Dart-supplied handle and return it typed.
///
/// Safe: casts only, never derefs. Typestate (which `T`) comes from the API surface, not
/// runtime. Use this at the `extern "C"` entry point; pass the resulting `*mut T` to
/// [`handle_from_raw`] where a `&mut` is needed.
///
/// # Errors
/// Returns `Err(FFI_INVALID_HANDLE)` when `ptr` is null.
pub fn validate_handle<T>(ptr: *mut c_void) -> Result<*mut T, FfiErrorObj> {
    if ptr.is_null() {
        return Err(FfiErrorObj {
            report: None,
            code: FFI_INVALID_HANDLE.to_owned(),
            context: None,
        });
    }
    Ok(ptr.cast::<T>())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr;

    struct Dummy {
        value: i32,
    }

    #[test]
    fn handle_roundtrip_mutate_and_drop() {
        let raw = handle_into_raw(Dummy { value: 42 });
        assert!(!raw.is_null());
        // SAFETY: raw was just returned by handle_into_raw and is still live.
        let reference = unsafe { handle_from_raw(raw) };
        assert!(reference.is_some());
        let r = reference.unwrap();
        r.value = 99;
        assert_eq!(r.value, 99);
        // SAFETY: raw is a live handle_into_raw pointer; dropped exactly once.
        unsafe { handle_drop(raw) };
    }

    #[test]
    fn handle_from_raw_null_returns_none() {
        // SAFETY: null is the documented no-op input.
        let result = unsafe { handle_from_raw::<Dummy>(ptr::null_mut()) };
        assert!(result.is_none());
    }

    #[test]
    fn validate_handle_null_returns_invalid_handle() {
        let result = validate_handle::<Dummy>(ptr::null_mut());
        assert!(result.is_err());
        assert_eq!(result.unwrap_err().code, "ffi.invalid_handle");
    }

    #[test]
    fn validate_handle_non_null_returns_ok_same_address() {
        let raw = handle_into_raw(Dummy { value: 7 });
        let void_ptr = raw.cast::<c_void>();
        let result = validate_handle::<Dummy>(void_ptr);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), raw);
        // SAFETY: raw is a live handle_into_raw pointer; dropped exactly once.
        unsafe { handle_drop(raw) };
    }
}
