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

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{
    convert_colocated, detect_repo, find_repo_root, Backend, DetectError, Repo, RepoError, RepoKind, RepoRoot,
};

use crate::envelope::{
    catch, ok_empty, ok_repo_handle, FfiErrorObj, FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, JJ_ALREADY_JJ_REPO,
    JJ_CONVERT_FAILED, JJ_DETECT_FAILED, JJ_JJ_LIB_ERROR, JJ_NOT_A_GIT_REPO, JJ_PATH_NOT_FOUND, JJ_REPO_NOT_FOUND,
};
use crate::envelope_generated::zanshin::ffi as fbs;
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
        RepoError::InitFailed { reason } | RepoError::CloneFailed { reason } | RepoError::Backend(reason) => {
            FfiErrorObj {
                code: JJ_JJ_LIB_ERROR.to_owned(),
                context: Some(reason),
            }
        }
        RepoError::ConvertFailed { reason } => FfiErrorObj {
            code: JJ_CONVERT_FAILED.to_owned(),
            context: Some(reason),
        },
        RepoError::AlreadyJjRepo { path } => FfiErrorObj {
            code: JJ_ALREADY_JJ_REPO.to_owned(),
            context: Some(path.display().to_string()),
        },
        RepoError::NotAGitRepo { path } => FfiErrorObj {
            code: JJ_NOT_A_GIT_REPO.to_owned(),
            context: Some(path.display().to_string()),
        },
    }
}

fn map_detect_err(e: &DetectError) -> FfiErrorObj {
    FfiErrorObj {
        code: JJ_DETECT_FAILED.to_owned(),
        context: Some(e.to_string()),
    }
}

fn repo_kind_to_fbs(k: RepoKind) -> fbs::RepoKind {
    match k {
        RepoKind::Jj => fbs::RepoKind::Jj,
        RepoKind::Git => fbs::RepoKind::Git,
        RepoKind::Neither => fbs::RepoKind::Neither,
        RepoKind::PathNotFound => fbs::RepoKind::PathNotFound,
    }
}

fn ok_repo_detect(kind: RepoKind, suggestion: Option<RepoRoot>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128);
    let (suggested_root_off, suggested_kind) = if let Some(root) = suggestion {
        let s = b.create_string(&root.root.to_string_lossy());
        (Some(s), repo_kind_to_fbs(root.kind))
    } else {
        (None, fbs::RepoKind::Jj)
    };
    let detect = fbs::RepoDetect::create(
        &mut b,
        &fbs::RepoDetectArgs {
            kind: repo_kind_to_fbs(kind),
            suggested_root: suggested_root_off,
            suggested_kind,
        },
    );
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::RepoDetect,
            data: Some(detect.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
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

/// Classify the repository kind at `path`.
///
/// This call is never an error for "no repo found" — `Neither` and `PathNotFound`
/// are **normal results** carried in the success payload. Only a genuine I/O failure
/// (e.g. `EACCES`, `ENOTDIR`) while stat-ing the path returns an error envelope.
///
/// When the result is `Neither` or `PathNotFound` and a parent jj or Git repo exists,
/// `RepoDetect.suggested_root` and `RepoDetect.suggested_kind` are set so the UI can
/// offer the user a consent-gated "this folder is inside a {jj|Git} repo at <root>"
/// suggestion. The backend never auto-opens — the user decides. The enclosing-repo
/// walk stops at the `$HOME` ceiling, so a repo at or above `$HOME` is intentionally
/// not surfaced as a suggestion.
///
/// # Errors
/// - `jj.detect_failed` — an I/O error (e.g. `EACCES`, `ENOTDIR`) prevented classification.
/// - `ffi.null_pointer` — `path` is a null pointer.
/// - `ffi.utf8_error` — `path` contains invalid UTF-8.
///
/// # Safety
/// `path` must be a valid, NUL-terminated C string or null. The returned `*mut ZanshinBuf`
/// is heap-allocated and must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_detect(path: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_repo_detect");
    // SAFETY: caller guarantees path is null or a valid NUL-terminated C string.
    let buf = catch(|| {
        let p = unsafe { cstr_to_string(path) }?;
        let kind = detect_repo(Path::new(&p)).map_err(|e| map_detect_err(&e))?;
        let suggestion = match kind {
            RepoKind::Neither | RepoKind::PathNotFound => {
                find_repo_root(Path::new(&p)).map_err(|e| map_detect_err(&e))?
            }
            RepoKind::Jj | RepoKind::Git => None,
        };
        Ok(ok_repo_detect(kind, suggestion))
    });
    vec_into_token(buf)
}

/// Convert a plain Git repository at `path` to a colocated jj workspace.
///
/// On success the repository is open and ready; the returned `RepoHandle` is
/// identical in semantics to the one returned by `zanshin_repo_open` / `_init` /
/// `_clone` and must be released via `zanshin_repo_close`.
///
/// The conversion only writes `.jj/` — `.git/` is never touched. If the operation
/// fails `.jj/` is rolled back, leaving the Git repo intact (no-data-loss invariant).
///
/// # Errors
/// - `jj.already_jj_repo` — the path already has a `.jj/` directory.
/// - `jj.not_a_git_repo` — the path has no `.git/` or does not exist.
/// - `jj.convert_failed` — a jj-lib failure during conversion; detail in `context`.
/// - `ffi.null_pointer` — `path` is a null pointer.
/// - `ffi.utf8_error` — `path` contains invalid UTF-8.
///
/// # Safety
/// `path` must be a valid, NUL-terminated C string or null. The returned `*mut ZanshinBuf`
/// is heap-allocated and must be freed exactly once via `zanshin_buffer_free_token`.
/// The handle inside the success payload is closed via `zanshin_repo_close` (no
/// `_convert`-specific destructor).
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_convert(path: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_repo_convert");
    // SAFETY: caller guarantees path is null or a valid NUL-terminated C string.
    let buf = catch(|| {
        let p = unsafe { cstr_to_string(path) }?;
        let repo = convert_colocated(Path::new(&p)).map_err(map_repo_err)?;
        Ok(ok_repo_handle(handle_into_raw(repo) as u64))
    });
    vec_into_token(buf)
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope_generated::zanshin::ffi as fbs;
    use crate::{
        FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, JJ_ALREADY_JJ_REPO, JJ_CONVERT_FAILED, JJ_JJ_LIB_ERROR,
        JJ_NOT_A_GIT_REPO, JJ_PATH_NOT_FOUND, JJ_REPO_NOT_FOUND,
    };
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
    fn map_repo_err_convert_failed_maps_to_jj_convert_failed() {
        let e = map_repo_err(RepoError::ConvertFailed {
            reason: "init failed".into(),
        });
        assert_eq!(e.code, JJ_CONVERT_FAILED);
        assert_eq!(e.context.unwrap(), "init failed");
    }

    #[test]
    fn map_repo_err_already_jj_repo_maps_to_jj_already_jj_repo() {
        let e = map_repo_err(RepoError::AlreadyJjRepo {
            path: "/some/path".into(),
        });
        assert_eq!(e.code, JJ_ALREADY_JJ_REPO);
        assert!(e.context.unwrap().contains("/some/path"));
    }

    #[test]
    fn map_repo_err_not_a_git_repo_maps_to_jj_not_a_git_repo() {
        let e = map_repo_err(RepoError::NotAGitRepo {
            path: "/no/git/here".into(),
        });
        assert_eq!(e.code, JJ_NOT_A_GIT_REPO);
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
