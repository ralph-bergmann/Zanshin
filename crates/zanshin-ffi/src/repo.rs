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
use std::sync::mpsc::Receiver;
use std::thread::{self, JoinHandle};

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{
    convert_colocated, detect_repo, find_repo_root, Backend, DetectError, Repo, RepoError, RepoKind, RepoRoot,
};

use crate::envelope::{
    catch, ok_empty, ok_repo_handle, FfiErrorObj, FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, JJ_ALREADY_JJ_REPO,
    JJ_CONVERT_FAILED, JJ_DETECT_FAILED, JJ_JJ_LIB_ERROR, JJ_NOT_A_GIT_REPO, JJ_PATH_NOT_FOUND, JJ_REPO_NOT_FOUND,
    WATCHER_IO_ERROR,
};
use crate::envelope_generated::zanshin::ffi as fbs;
use crate::events;
use crate::ffi_strings::{cstr_to_string, vec_into_token, ZanshinBuf};
use crate::handle::{handle_drop, handle_from_raw, handle_into_raw};
use crate::watcher::{Watcher, WatcherError, WatcherEvent};

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

// ── RepoSession: warm loader + watcher owner (ADR-0002:34) ───────────────────

/// Handle to an open jj repository plus its filesystem-watcher subsystem.
///
/// ADR-0002:34 defines the repo handle as a warm `Workspace` loader **and**
/// the owner of the repo's op-heads watcher; this struct makes that literal.
/// All four handle-producing wrappers (open/init/clone/convert) construct one
/// via [`arm_session`]; the five read wrappers (`status.rs`, `change.rs`,
/// `op_log.rs`, `bookmarks.rs`, `remotes.rs`) borrow `.repo`; `zanshin_repo_close`
/// tears it down via [`RepoSession::close`]. Wire handles stay `u64` — no ABI
/// change from this refactor.
pub(crate) struct RepoSession {
    pub(crate) repo: Repo,
    // `Option` so `close()` can `take()` each for teardown (AC 8). Both are
    // always `Some` for a session returned by `arm_session`.
    watcher: Option<Watcher>,
    dispatch: Option<JoinHandle<()>>,
}

impl RepoSession {
    /// Tear down the watcher and its dispatch thread, in that order (AC 8):
    /// `Watcher::stop()` joins the debouncer thread first (Story 3.5 chose
    /// `stop()` over bare drop precisely so this is synchronous), which drops
    /// the `SyncSender` and lets the dispatch thread's `recv()` loop see
    /// disconnect and exit; joining it then blocks until that happens. After
    /// this returns, no Rust thread for this repo can invoke the event sink.
    fn close(&mut self) {
        if let Some(watcher) = self.watcher.take() {
            watcher.stop();
        }
        if let Some(dispatch) = self.dispatch.take() {
            let _ = dispatch.join();
        }
    }
}

fn map_watcher_err(e: &WatcherError) -> FfiErrorObj {
    FfiErrorObj {
        code: WATCHER_IO_ERROR.to_owned(),
        context: Some(e.to_string()),
    }
}

/// Spawn the per-session dispatch thread (AC 7).
///
/// Blocking `recv()` loop: each [`WatcherEvent`] is serialised to a
/// `FlatBuffers` `Envelope` tagged with `repo_handle` and forwarded to the
/// process-global event sink. Exits on `RecvError` (the channel disconnected
/// because the `Watcher` was stopped/dropped). Panic-proof: no
/// `unwrap`/`expect` in the loop body, so nothing can unwind toward the
/// `extern "C"` boundary.
fn spawn_dispatch_thread(repo_handle: u64, rx: Receiver<WatcherEvent>) -> std::io::Result<JoinHandle<()>> {
    // WHY thread::Builder instead of thread::spawn: bare `spawn` PANICS on OS
    // spawn failure — a panic source on an FFI-reachable path (forbidden); the
    // Builder returns the error so arm_session can map it to watcher.io_error
    // and reclaim the session instead of leaking it into catch_unwind.
    thread::Builder::new()
        .name("zanshin-event-dispatch".to_owned())
        .spawn(move || {
            while let Ok(event) = rx.recv() {
                events::dispatch(events::watcher_event_to_envelope(repo_handle, &event));
            }
        })
}

/// Construct a [`RepoSession`] for `repo`, arm its filesystem watcher, and
/// spawn the per-session dispatch thread — all before returning (AR-G-5:
/// "watcher must start before the wrapper returns").
///
/// Returns the session's opaque `u64` handle on success. On watcher-arming
/// failure the already-opened `repo` (and the just-allocated session box) are
/// dropped — no leak — and the caller returns a `watcher.io_error` envelope
/// with NO handle (OQ-1 strict-fail: a repo we can't watch does not open).
fn arm_session(repo: Repo) -> Result<u64, FfiErrorObj> {
    arm_session_with(repo, spawn_dispatch_thread)
}

/// [`arm_session`]'s body with the dispatch-thread spawner injected.
///
/// The seam exists solely so the spawn-failure arm is unit-testable (OS
/// thread exhaustion cannot be forced in a test); production always goes
/// through [`arm_session`] → [`spawn_dispatch_thread`].
fn arm_session_with(
    repo: Repo,
    spawn: impl FnOnce(u64, Receiver<WatcherEvent>) -> std::io::Result<JoinHandle<()>>,
) -> Result<u64, FfiErrorObj> {
    let repo_path = repo.workspace_root().to_path_buf();
    let raw = handle_into_raw(RepoSession {
        repo,
        watcher: None,
        dispatch: None,
    });
    let (watcher, rx) = match Watcher::new(&repo_path) {
        Ok(pair) => pair,
        Err(e) => {
            // SAFETY: raw is the exact pointer handle_into_raw produced above
            // and has not been shared with any other code; reclaiming it here
            // is the sole owner's drop, so the just-opened repo is not leaked.
            unsafe { handle_drop::<RepoSession>(raw) };
            return Err(map_watcher_err(&e));
        }
    };
    let dispatch = match spawn(raw as u64, rx) {
        Ok(handle) => handle,
        Err(e) => {
            // Synchronous close (joins the debouncer thread) before reclaiming
            // the session — mirrors RepoSession::close's teardown ordering.
            watcher.stop();
            // SAFETY: as above — sole-owner reclaim; the just-opened repo is
            // not leaked (the epic's leak would otherwise hide in catch_unwind).
            unsafe { handle_drop::<RepoSession>(raw) };
            return Err(map_watcher_err(&WatcherError::Io(e)));
        }
    };
    // SAFETY: `raw` was produced by handle_into_raw above and its POINTEE is
    // exclusively owned by this function until the handle is returned: the
    // dispatch thread only captured the address as a `u64` correlation id and
    // never dereferences it, and no other code has seen the handle yet, so
    // these writes cannot race a read.
    unsafe {
        (*raw).watcher = Some(watcher);
        (*raw).dispatch = Some(dispatch);
    }
    Ok(raw as u64)
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
        let handle = arm_session(repo)?;
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
        let handle = arm_session(repo)?;
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
        let handle = arm_session(repo)?;
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
        // SAFETY: handle is a non-zero value that originated from arm_session's
        // handle_into_raw in zanshin_repo_open/init/clone/convert (a Box<RepoSession>
        // leaked to Dart). The single-isolate model (AD-2) guarantees no concurrent
        // access. The Dart worker removes the handleId mapping on close (Model A,
        // Story 3.9), and the explicit close + Dart Finalizer backstop fire at most
        // once, so a freed handle is not re-passed. `close()` stops the watcher (joins
        // the debouncer thread) and joins the dispatch thread (AC 8) before the
        // reclaimed `Box<RepoSession>` — and the repo it owns — is dropped.
        if let Some(session) = unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) } {
            session.close();
        }
        unsafe { handle_drop::<RepoSession>(handle as *mut RepoSession) };
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
        Ok(ok_repo_handle(arm_session(repo)?))
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
    fn map_watcher_err_io_maps_to_watcher_io_error() {
        let e = map_watcher_err(&WatcherError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "missing",
        )));
        assert_eq!(e.code, crate::WATCHER_IO_ERROR);
        assert!(e.context.unwrap().contains("missing"));
    }

    #[test]
    fn map_watcher_err_notify_maps_to_watcher_io_error() {
        let e = map_watcher_err(&WatcherError::Notify(notify_debouncer_full::notify::Error::generic(
            "boom",
        )));
        assert_eq!(e.code, crate::WATCHER_IO_ERROR);
        assert!(e.context.unwrap().contains("boom"));
    }

    // Pin JJ_CONFIG / GIT_CONFIG_GLOBAL so this module's real Repo::open call is
    // hermetic (mirrors tests/repo_ffi.rs / tests/watcher.rs).
    static ENV_GUARD: std::sync::LazyLock<()> = std::sync::LazyLock::new(|| {
        // SAFETY: set once via LazyLock::force before any repo is opened; the
        // single-init-before-use ordering is what makes this sound under
        // cargo test's multi-threaded runner (mirrors tests/repo_ffi.rs).
        unsafe {
            std::env::set_var("JJ_CONFIG", "");
            std::env::set_var("GIT_CONFIG_GLOBAL", "");
        }
    });

    #[test]
    fn arm_session_returns_watcher_io_error_when_checkout_missing_after_open() {
        std::sync::LazyLock::force(&ENV_GUARD);
        // AC 14's arming-failure test: deleting `.jj/working_copy/checkout`
        // BEFORE zanshin_repo_open fails inside jj-lib's Workspace::load itself
        // (jj.jj_lib_error, verified empirically) — Repo::open never even
        // reaches arm_session. Per AC 14's explicit fallback ("if Repo::open
        // itself refuses that state, fall back to unit-testing the arm-helper's
        // error path directly"), sabotage AFTER a successful open instead: the
        // repo is already loaded, but arm_session's Watcher::new(&repo_path)
        // call still needs the checkout file to exist to arm the heartbeat watch.
        let fixture = test_helpers::extract_fixture("tiny-3-commits").expect("fixture must extract");
        let repo = Repo::open(&fixture.path).expect("Repo::open must succeed while checkout exists");
        std::fs::remove_file(fixture.path.join(".jj/working_copy/checkout"))
            .expect("checkout file must exist to sabotage");

        let err = arm_session(repo).expect_err("arm_session must fail when the checkout file is missing");
        assert_eq!(err.code, crate::WATCHER_IO_ERROR);
    }

    #[test]
    fn arm_session_with_failing_spawner_returns_watcher_io_error() {
        std::sync::LazyLock::force(&ENV_GUARD);
        // Covers the dispatch-thread spawn-failure arm (review patch,
        // 2026-07-03): OS thread exhaustion cannot be forced in a test, so the
        // failure is injected through arm_session_with's spawner seam. The
        // session box + repo are reclaimed (sole-owner drop) and the error
        // maps to watcher.io_error like every other arming failure.
        let fixture = test_helpers::extract_fixture("tiny-3-commits").expect("fixture must extract");
        let repo = Repo::open(&fixture.path).expect("Repo::open must succeed");

        let err = arm_session_with(repo, |_, _| Err(std::io::Error::other("injected: thread spawn failed")))
            .expect_err("arm_session_with must fail when the spawner fails");
        assert_eq!(err.code, crate::WATCHER_IO_ERROR);
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
