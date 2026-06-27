// SPDX-License-Identifier: MIT

//! FFI wrappers for repository lifecycle operations.
//!
//! Each function is wrapped in `envelope::catch` so no panic crosses the C ABI.
//! All composite return values are `FlatBuffers` `Envelope` tokens (`*mut ZanshinBuf`).
//!
//! # Error codes
//! See `docs/rust-error-codes.md` for the full registry.

use core::ffi::c_char;
use std::path::Path;

use tracing::debug;
use zanshin_jj::{Backend, Repo, RepoError};

use crate::envelope::{
    catch, ok_empty, ok_repo_handle, FfiErrorObj, FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR,
    JJ_PATH_NOT_FOUND, JJ_REPO_NOT_FOUND,
};
use crate::ffi_strings::{cstr_to_string, vec_into_token, ZanshinBuf};
use crate::handle::handle_into_raw;

// ── Error mapping ─────────────────────────────────────────────────────────────

fn map_repo_err(e: RepoError) -> FfiErrorObj {
    match e {
        RepoError::PathNotFound { path } => FfiErrorObj {
            code: JJ_PATH_NOT_FOUND.to_owned(),
            context: Some(path.display().to_string()),
        },
        RepoError::NotARepo { path } => FfiErrorObj {
            code: JJ_REPO_NOT_FOUND.to_owned(),
            context: Some(path.display().to_string()),
        },
        RepoError::InitFailed { reason }
        | RepoError::CloneFailed { reason }
        | RepoError::ConvertFailed { reason }
        | RepoError::Backend(reason) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
        // AlreadyJjRepo + NotAGitRepo get dedicated codes in Story 3.4c (jj.already_jj_repo /
        // jj.not_a_git_repo). Until then they surface as JJ_JJ_LIB_ERROR with path context.
        RepoError::AlreadyJjRepo { path } | RepoError::NotAGitRepo { path } => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(path.display().to_string()),
        },
    }
}

// ── extern "C" functions ──────────────────────────────────────────────────────

/// Open an existing jj repository at `path`.
///
/// Returns a success `Envelope` whose payload is `RepoHandle { handle }` on success,
/// or an error `Envelope` on failure. The handle is an opaque integer the Dart caller
/// must pass back to `zanshin_repo_close` when done.
///
/// # Errors
/// - `jj.path_not_found` — `path` does not exist on disk.
/// - `jj.repo_not_found` — `path` exists but is not a jj repo.
/// - `ffi.null_pointer` — `path` is a null pointer.
/// - `ffi.utf8_error` — `path` contains invalid UTF-8.
///
/// # Safety
/// `path` must be a valid, NUL-terminated C string or null (null is detected and
/// returned as `ffi.null_pointer`). The returned `*mut ZanshinBuf` is heap-allocated
/// and must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_open(path: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_repo_open");
    // SAFETY: caller guarantees path is null or a valid NUL-terminated C string.
    let buf = catch(|| {
        let p = unsafe { cstr_to_string(path) }?;
        let repo = Repo::open(Path::new(&p)).map_err(map_repo_err)?;
        let handle = handle_into_raw(repo) as u64;
        Ok(ok_repo_handle(handle))
    });
    vec_into_token(buf)
}

/// Initialise a new jj repository at `path`.
///
/// `backend` selects the storage backend: `0` → native/simple, `1` → Git.
/// Any other value returns `ffi.invalid_argument`.
///
/// Returns a `RepoHandle` envelope on success.
///
/// # Errors
/// - `ffi.invalid_argument` — `backend` is not `0` or `1`.
/// - `ffi.null_pointer` / `ffi.utf8_error` — invalid `path` pointer.
/// - `jj.jj_lib_error` — init failed (e.g. repo already exists).
///
/// # Safety
/// `path` must be a valid, NUL-terminated C string or null. The returned token
/// must be freed via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_init(path: *const c_char, backend: i32) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_repo_init", backend);
    // SAFETY: caller guarantees path is null or a valid NUL-terminated C string.
    let buf = catch(|| {
        let p = unsafe { cstr_to_string(path) }?;
        let backend_opt = match backend {
            0 => None,
            1 => Some(Backend::Git),
            _ => {
                return Err(FfiErrorObj {
                    code: FFI_INVALID_ARGUMENT.to_owned(),
                    context: Some(format!("backend discriminant {backend} is not 0 (native) or 1 (git)")),
                })
            }
        };
        let repo = Repo::init(Path::new(&p), backend_opt).map_err(map_repo_err)?;
        let handle = handle_into_raw(repo) as u64;
        Ok(ok_repo_handle(handle))
    });
    vec_into_token(buf)
}

/// Clone a jj repository from `url` into `target_path`.
///
/// Uses a `file://` local source in tests — no network access is needed or allowed.
/// On failure the partial workspace is already rolled back by `zanshin-jj::Repo::clone`.
///
/// Returns a `RepoHandle` envelope on success.
///
/// # Errors
/// - `ffi.null_pointer` / `ffi.utf8_error` — invalid pointer arguments.
/// - `jj.jj_lib_error` — clone failed; detail in `context`.
///
/// # Safety
/// `url` and `target_path` must each be a valid, NUL-terminated C string or null.
/// The returned token must be freed via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_clone(url: *const c_char, target_path: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_repo_clone");
    // SAFETY: caller guarantees url and target_path are null or valid NUL-terminated C strings.
    let buf = catch(|| {
        let u = unsafe { cstr_to_string(url) }?;
        let t = unsafe { cstr_to_string(target_path) }?;
        let repo = Repo::clone(&u, Path::new(&t)).map_err(map_repo_err)?;
        let handle = handle_into_raw(repo) as u64;
        Ok(ok_repo_handle(handle))
    });
    vec_into_token(buf)
}

/// Close an open repository and release its resources.
///
/// `handle` is the opaque integer returned by `zanshin_repo_open`, `zanshin_repo_init`,
/// or `zanshin_repo_clone`. After this call the handle is invalid; the Dart caller
/// must null its local copy.
///
/// Returns a no-payload success `Envelope` on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null).
///
/// # Safety
/// `handle` must be a value previously returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, or `zanshin_repo_clone` call that has not yet been closed.
/// Passing a freed non-zero handle is undefined behaviour; the Dart contract is to
/// null the local handle after `close`. There is no handle table in Rust (AD-2,
/// single-isolate), but the Dart worker's Model-A `handleId` table (Story 3.9) removes
/// the mapping on close, so a stale handle never reaches Rust. The repo handle is a warm
/// loader, not a state cache — reads re-resolve to head (ADR-0002).
/// The returned token must be freed via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_close(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_repo_close", handle);
    let buf = catch(|| {
        if handle == 0 {
            return Err(FfiErrorObj {
                code: FFI_INVALID_HANDLE.to_owned(),
                context: None,
            });
        }
        // SAFETY: handle is a non-zero value that originated from handle_into_raw in
        // zanshin_repo_open/init/clone (a Box<Repo> leaked to Dart). The single-isolate
        // model (AD-2) guarantees no concurrent access. The Dart worker removes the
        // handleId mapping on close (Model A, Story 3.9), and the explicit close + Dart
        // Finalizer backstop fire at most once, so a freed handle is not re-passed.
        unsafe { crate::handle::handle_drop::<Repo>(handle as *mut Repo) };
        Ok(ok_empty())
    });
    vec_into_token(buf)
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope_generated::zanshin::ffi as fbs;
    use crate::{FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR, JJ_PATH_NOT_FOUND, JJ_REPO_NOT_FOUND};
    use flatbuffers::VerifierOptions;

    fn verified_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
        let opts = VerifierOptions::default();
        flatbuffers::root_with_opts::<fbs::Envelope>(&opts, bytes).expect("FlatBuffers Verifier must pass")
    }

    #[test]
    fn map_repo_err_path_not_found() {
        let e = map_repo_err(RepoError::PathNotFound {
            path: "/no/such".into(),
        });
        assert_eq!(e.code, JJ_PATH_NOT_FOUND);
        assert!(e.context.unwrap().contains("/no/such"));
    }

    #[test]
    fn map_repo_err_not_a_repo() {
        let e = map_repo_err(RepoError::NotARepo { path: "/tmp/x".into() });
        assert_eq!(e.code, JJ_REPO_NOT_FOUND);
    }

    #[test]
    fn map_repo_err_init_failed_maps_to_jj_lib_error() {
        let e = map_repo_err(RepoError::InitFailed {
            reason: "already exists".into(),
        });
        assert_eq!(e.code, JJ_JJ_LIB_ERROR);
        assert_eq!(e.context.unwrap(), "already exists");
    }

    #[test]
    fn map_repo_err_clone_failed_maps_to_jj_lib_error() {
        let e = map_repo_err(RepoError::CloneFailed {
            reason: "bad url".into(),
        });
        assert_eq!(e.code, JJ_JJ_LIB_ERROR);
    }

    #[test]
    fn map_repo_err_backend_maps_to_jj_lib_error() {
        let e = map_repo_err(RepoError::Backend("underlying".into()));
        assert_eq!(e.code, JJ_JJ_LIB_ERROR);
    }

    #[test]
    fn map_repo_err_convert_failed_maps_to_jj_lib_error() {
        let e = map_repo_err(RepoError::ConvertFailed {
            reason: "init failed".into(),
        });
        assert_eq!(e.code, JJ_JJ_LIB_ERROR);
        assert_eq!(e.context.unwrap(), "init failed");
    }

    #[test]
    fn map_repo_err_already_jj_repo_maps_to_jj_lib_error() {
        let e = map_repo_err(RepoError::AlreadyJjRepo {
            path: "/some/path".into(),
        });
        assert_eq!(e.code, JJ_JJ_LIB_ERROR);
        assert!(e.context.unwrap().contains("/some/path"));
    }

    #[test]
    fn map_repo_err_not_a_git_repo_maps_to_jj_lib_error() {
        let e = map_repo_err(RepoError::NotAGitRepo {
            path: "/no/git/here".into(),
        });
        assert_eq!(e.code, JJ_JJ_LIB_ERROR);
        assert!(e.context.unwrap().contains("/no/git/here"));
    }

    #[test]
    fn repo_open_null_pointer_returns_ffi_null_pointer() {
        let token = unsafe { zanshin_repo_open(std::ptr::null()) };
        assert!(!token.is_null());
        // SAFETY: token is a valid ZanshinBuf we just received.
        let bytes = unsafe {
            let t = &*token;
            std::slice::from_raw_parts(t.ptr, t.len)
        };
        let env = verified_envelope(bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(crate::FFI_NULL_POINTER));
        unsafe { crate::ffi_strings::zanshin_buffer_free_token(token) };
    }

    #[test]
    fn repo_init_invalid_backend_returns_ffi_invalid_argument() {
        use std::ffi::CString;
        let tmp = tempfile::TempDir::new().unwrap();
        let path = CString::new(tmp.path().to_str().unwrap()).unwrap();
        let token = unsafe { zanshin_repo_init(path.as_ptr(), 99) };
        assert!(!token.is_null());
        let bytes = unsafe {
            let t = &*token;
            std::slice::from_raw_parts(t.ptr, t.len)
        };
        let env = verified_envelope(bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));
        unsafe { crate::ffi_strings::zanshin_buffer_free_token(token) };
    }

    #[test]
    fn repo_close_zero_handle_returns_ffi_invalid_handle() {
        let token = unsafe { zanshin_repo_close(0) };
        assert!(!token.is_null());
        let bytes = unsafe {
            let t = &*token;
            std::slice::from_raw_parts(t.ptr, t.len)
        };
        let env = verified_envelope(bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_HANDLE));
        unsafe { crate::ffi_strings::zanshin_buffer_free_token(token) };
    }

    #[test]
    fn catch_panic_in_repo_wrapper_returns_internal_panic() {
        // Proves the panic backstop fires without a real repo call.
        let buf = catch(|| -> Result<Vec<u8>, FfiErrorObj> { panic!("repo test panic") });
        let env = verified_envelope(&buf);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(crate::INTERNAL_PANIC));
    }
}
