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
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::Receiver;
use std::thread::{self, JoinHandle};

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{
    convert_colocated, detect_repo, find_repo_root, Backend, ChangeId, DetectError, MutateError, Repo, RepoError,
    RepoKind, RepoRoot,
};

use crate::envelope::{
    catch, invalid_request, ok_absorb_result, ok_empty, ok_mutation_result, ok_repo_handle, reject_null_request,
    session_from_handle, FfiErrorObj, FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, JJ_ALREADY_JJ_REPO, JJ_BOOKMARK_EXISTS,
    JJ_BOOKMARK_TRACKED_REMOTE_EXISTS, JJ_CHANGE_NOT_FOUND, JJ_CONFIG_ERROR, JJ_CONVERT_FAILED, JJ_DETECT_FAILED,
    JJ_IMMUTABLE, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_NETWORK_ERROR, JJ_NOTHING_TO_UNDO, JJ_NOT_A_GIT_REPO,
    JJ_PATH_NOT_FOUND, JJ_REMOTE_EXISTS, JJ_REMOTE_NONSTANDARD_CONFIG, JJ_REMOTE_NOT_FOUND, JJ_REPO_NOT_FOUND,
    JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR, WATCHER_IO_ERROR,
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

/// Map a [`MutateError`] (from the Story 6.1/6.2/6.4a mutation functions) to an
/// [`FfiErrorObj`]. `ChangeNotFound` reuses [`JJ_CHANGE_NOT_FOUND`] (same
/// not-found semantics as the read-side `change.rs`); `Backend` reuses
/// [`JJ_JJ_LIB_ERROR`] (same unclassified-jj-lib-failure semantics as every
/// other wrapper); `InvalidInput`/`NothingToUndo`/`RemoteNotFound`/`NetworkError`
/// are new codes introduced by Story 6.5, and `Immutable` (`jj.immutable`) by Story 9.1
/// (`docs/rust-error-codes.md`). `RevsetParseError`/`RevsetResolutionError` (Story 9.3,
/// raised by `zanshin_absorb`'s revset `into`) reuse [`JJ_REVSET_PARSE_ERROR`] /
/// [`JJ_REVSET_RESOLUTION_ERROR`] — the same two-stage taxonomy `graph.rs` already
/// reports under those codes. `Config` reuses [`JJ_CONFIG_ERROR`] — it is the same
/// malformed-config/bad-alias fault `log_defaults.rs` and `graph.rs` already report under
/// that code (Story 4.9), reached from the mutation side because the immutability guard
/// reads the repo's effective config. Story 9.5 adds three arms — `RemoteExists`
/// (`jj.remote_exists`) and `RemoteNonstandardConfig` (`jj.remote_nonstandard_config`) are
/// new codes, while `NotAGitRepo` reuses [`JJ_NOT_A_GIT_REPO`] with its meaning widened from
/// "this path" to "this workspace's backend" and therefore carries no `context`.
/// Story 9.8 adds two more new codes — `BookmarkExists` (`jj.bookmark_exists`) and
/// `BookmarkTrackedRemoteExists` (`jj.bookmark_tracked_remote_exists`) — kept apart for the
/// `jj.remote_exists` reason: the CLI prints a different hint for each because the remedies
/// differ, and collapsing them would throw that away.
///
/// `pub(crate)` since Story 9.5: `git.rs`'s six wrappers return the same [`MutateError`]
/// taxonomy, and a second mapper would be a second, desyncable spelling of one mapping.
/// `bookmark_ops.rs`'s two (Story 9.8) reuse it for the same reason.
pub(crate) fn map_mutate_err(e: MutateError) -> FfiErrorObj {
    match e {
        MutateError::ChangeNotFound { id } => FfiErrorObj {
            code: JJ_CHANGE_NOT_FOUND.to_owned(),
            context: Some(id),
        },
        MutateError::InvalidInput { reason } => FfiErrorObj {
            code: JJ_INVALID_INPUT.to_owned(),
            context: Some(reason),
        },
        MutateError::Immutable { commit_id } => FfiErrorObj {
            code: JJ_IMMUTABLE.to_owned(),
            context: Some(commit_id),
        },
        MutateError::Config { reason } => FfiErrorObj {
            code: JJ_CONFIG_ERROR.to_owned(),
            context: Some(reason),
        },
        MutateError::NothingToUndo => FfiErrorObj {
            code: JJ_NOTHING_TO_UNDO.to_owned(),
            context: None,
        },
        MutateError::RemoteNotFound { name } => FfiErrorObj {
            code: JJ_REMOTE_NOT_FOUND.to_owned(),
            context: Some(name),
        },
        MutateError::NetworkError { reason } => FfiErrorObj {
            code: JJ_NETWORK_ERROR.to_owned(),
            context: Some(reason),
        },
        MutateError::RemoteExists { name } => FfiErrorObj {
            code: JJ_REMOTE_EXISTS.to_owned(),
            context: Some(name),
        },
        MutateError::RemoteNonstandardConfig { name } => FfiErrorObj {
            code: JJ_REMOTE_NONSTANDARD_CONFIG.to_owned(),
            context: Some(name),
        },
        // No `context`: this variant names no path and no remote — the fault is the whole
        // workspace's backend, which the code already says.
        MutateError::NotAGitRepo => FfiErrorObj {
            code: JJ_NOT_A_GIT_REPO.to_owned(),
            context: None,
        },
        MutateError::RevsetParseError { reason } => FfiErrorObj {
            code: JJ_REVSET_PARSE_ERROR.to_owned(),
            context: Some(reason),
        },
        MutateError::RevsetResolutionError { reason } => FfiErrorObj {
            code: JJ_REVSET_RESOLUTION_ERROR.to_owned(),
            context: Some(reason),
        },
        MutateError::BookmarkExists { name } => FfiErrorObj {
            code: JJ_BOOKMARK_EXISTS.to_owned(),
            context: Some(name),
        },
        MutateError::BookmarkTrackedRemoteExists { name } => FfiErrorObj {
            code: JJ_BOOKMARK_TRACKED_REMOTE_EXISTS.to_owned(),
            context: Some(name),
        },
        MutateError::Backend(reason) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

// ── Request-buffer readers (ADR-0001 composite-input pattern) ────────────────
//
// `data`/`len` describe a caller-owned buffer Dart builds and owns/frees itself
// (`fbs.<Table>ObjectBuilder(...).toBytes()`); Rust only borrows it for the duration of
// the call — the same AR-P-5 inbound rule as `cstr_to_string`'s `CString`s, generalized
// to raw bytes.
//
// `flatbuffers::root_with_opts::<T>` works for any generated table `T`, not only
// `envelope.fbs`'s declared `root_type` — `root_as_envelope` is itself a thin wrapper
// over exactly this generic call (verified in `envelope_generated.rs`), so these
// request-only tables need no `root_type` change.
//
// WHY each reader builds its OWN byte slice and calls `root_with_opts` in its own scope
// instead of sharing a generic `read_request<T>() -> T::Inner` helper: a generated table
// is a BORROWING type, and `std::slice::from_raw_parts` produces an unbounded lifetime.
// A shared helper would have to name that lifetime as a free parameter, letting a caller
// infer `'static` and hold, say, a `RestoreRequest<'static>` after the Dart-owned buffer
// is freed. Keeping the slice a local binding and returning only OWNED structs makes that
// unrepresentable: the borrow provably cannot outlive the call. Only the null check and
// the two error shapes are shared — they live in `envelope.rs`, since `file.rs`'s readers
// need exactly the same two.

/// Parse a `ChangeIdList` request buffer into an owned `Vec<ChangeId>`.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ChangeIdList` buffer.
fn read_change_id_list(data: *const u8, len: usize) -> Result<Vec<ChangeId>, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let list = flatbuffers::root_with_opts::<fbs::ChangeIdList>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    Ok(list
        .change_ids()
        .into_iter()
        .flatten()
        .map(|s| ChangeId(s.to_owned()))
        .collect())
}

/// Owned Rust form of a `RestoreRequest` buffer (Story 9.3).
///
/// Every string is `Option`: ABSENT is the wire form of "the user did not supply it",
/// which is what lets `zanshin_jj::Repo::restore` apply the CLI's own `@` / parent-tree
/// defaults instead of a value this layer invented.
struct RestoreRequestOwned {
    from: Option<ChangeId>,
    into: Option<ChangeId>,
    changes_in: Option<ChangeId>,
    paths: Vec<String>,
    restore_descendants: bool,
}

/// Owned Rust form of an `AbsorbRequest` buffer (Story 9.3). `into` is a revset
/// EXPRESSION, not a change id — see the schema's own comment.
struct AbsorbRequestOwned {
    from: Option<ChangeId>,
    into: Option<String>,
    paths: Vec<String>,
}

/// Parse a `RestoreRequest` request buffer into an owned [`RestoreRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `RestoreRequest` buffer.
fn read_restore_request(data: *const u8, len: usize) -> Result<RestoreRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::RestoreRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    Ok(RestoreRequestOwned {
        from: req.from().map(|s| ChangeId(s.to_owned())),
        // WHY the fully-qualified inherent call: the generated accessor is named after
        // the schema field `into`, which collides with the blanket `Into::into`; a bare
        // `req.into()` is ambiguous.
        into: fbs::RestoreRequest::into(&req).map(|s| ChangeId(s.to_owned())),
        changes_in: req.changes_in().map(|s| ChangeId(s.to_owned())),
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
        restore_descendants: req.restore_descendants(),
    })
}

/// Parse an `AbsorbRequest` request buffer into an owned [`AbsorbRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `AbsorbRequest` buffer.
fn read_absorb_request(data: *const u8, len: usize) -> Result<AbsorbRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::AbsorbRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    Ok(AbsorbRequestOwned {
        from: req.from().map(|s| ChangeId(s.to_owned())),
        // WHY the fully-qualified inherent call: see `read_restore_request`.
        into: fbs::AbsorbRequest::into(&req).map(ToOwned::to_owned),
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
    })
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
/// via [`arm_session`]; the read wrappers borrow `.repo` — `status.rs`,
/// `change.rs`, `op_log.rs`, `bookmarks.rs`, `remotes.rs`, plus `file.rs`'s four
/// (Story 9.4), `commit_views.rs`'s three (Story 9.6) and `workspace.rs`'s two
/// (Story 9.7); the mutation wrappers borrow it mutably — `git.rs`'s six (Story 9.5) and
/// `bookmark_ops.rs`'s two (Story 9.8); `zanshin_repo_close`
/// tears it down via [`RepoSession::close`]. Wire handles stay `u64` — no ABI
/// change from this refactor.
pub(crate) struct RepoSession {
    pub(crate) repo: Repo,
    // `Option` so `close()` can `take()` each for teardown (AC 8). Both are
    // always `Some` for a session returned by `arm_session`.
    watcher: Option<Watcher>,
    dispatch: Option<JoinHandle<()>>,
    // The same process-unique, never-reused id returned to Dart as
    // `RepoHandle.session_id` (arm_session_with's NEXT_SESSION_ID counter).
    // Story 6.5's `zanshin_git_fetch` copies this out to correlate its
    // `Progress` events — the same mechanism `WatcherEvent` already uses.
    pub(crate) session_id: u64,
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
/// `FlatBuffers` `Envelope` tagged with the session's process-unique
/// `session_id` (the ABA-safe correlation id — never the raw handle) and
/// forwarded to the process-global event sink. Exits on `RecvError` (the
/// channel disconnected because the `Watcher` was stopped/dropped).
/// Panic-proof: no `unwrap`/`expect` in the loop body, so nothing can unwind
/// toward the `extern "C"` boundary.
fn spawn_dispatch_thread(session_id: u64, rx: Receiver<WatcherEvent>) -> std::io::Result<JoinHandle<()>> {
    // WHY thread::Builder instead of thread::spawn: bare `spawn` PANICS on OS
    // spawn failure — a panic source on an FFI-reachable path (forbidden); the
    // Builder returns the error so arm_session can map it to watcher.io_error
    // and reclaim the session instead of leaking it into catch_unwind.
    thread::Builder::new()
        .name("zanshin-event-dispatch".to_owned())
        .spawn(move || {
            while let Ok(event) = rx.recv() {
                events::dispatch(events::watcher_event_to_envelope(session_id, &event));
            }
        })
}

/// Construct a [`RepoSession`] for `repo`, arm its filesystem watcher, and
/// spawn the per-session dispatch thread — all before returning (AR-G-5:
/// "watcher must start before the wrapper returns").
///
/// Returns `(handle, session_id)` on success: the session's opaque `u64`
/// handle plus the process-unique session id that async events carry as
/// their correlation id (never reused — ABA-safe across close→reopen,
/// unlike the raw handle's allocation address). On watcher-arming failure
/// the already-opened `repo` (and the just-allocated session box) are
/// dropped — no leak — and the caller returns a `watcher.io_error` envelope
/// with NO handle (OQ-1 strict-fail: a repo we can't watch does not open).
fn arm_session(repo: Repo) -> Result<(u64, u64), FfiErrorObj> {
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
) -> Result<(u64, u64), FfiErrorObj> {
    // Process-unique event-correlation id (starts at 1; 0 is never issued).
    // WHY not the raw pointer: a close→reopen can reuse the freed session's
    // allocation ADDRESS, so a stale queued event could be misattributed to
    // the NEW session (rawToId ABA, 3-6 review; fixed 2026-07-04). A
    // monotonic counter can never collide with a later session.
    static NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);
    let session_id = NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed);

    let repo_path = repo.workspace_root().to_path_buf();
    let raw = handle_into_raw(RepoSession {
        repo,
        watcher: None,
        dispatch: None,
        session_id,
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
    let dispatch = match spawn(session_id, rx) {
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
    // dispatch thread captured only the process-unique `session_id` — never
    // the address — and no other code has seen the handle yet, so these
    // writes cannot race a read.
    unsafe {
        (*raw).watcher = Some(watcher);
        (*raw).dispatch = Some(dispatch);
    }
    Ok((raw as u64, session_id))
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
/// - `watcher.io_error` — the filesystem watcher could not be armed. Arming is strict-fail:
///   no handle is returned rather than one for an unwatched repo. `open` leaves no residue.
///   Detail in `context`.
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
        let (handle, session_id) = arm_session(repo)?;
        Ok(ok_repo_handle(handle, session_id))
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
/// - `watcher.io_error` — the filesystem watcher could not be armed. Arming is strict-fail:
///   no handle is returned rather than one for an unwatched repo. It runs AFTER the init
///   has succeeded, so the created `.jj/` persists and a retry sees an existing repo.
///   Detail in `context`.
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
        let (handle, session_id) = arm_session(repo)?;
        Ok(ok_repo_handle(handle, session_id))
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
/// - `jj.jj_lib_error` — clone failed; detail in `context`. This also covers a config
///   fault: the clone reads `git.abandon-unreachable-commits` from the effective config, so
///   an unreadable config or a non-boolean value fails the clone under this code. `context`
///   names the offending KEY for a wrong-typed value, and the offending FILE PATH for a
///   config file that is unreadable or not valid TOML.
/// - `watcher.io_error` — the filesystem watcher could not be armed. Arming is strict-fail:
///   no handle is returned rather than one for an unwatched repo. It runs AFTER the clone
///   has SUCCEEDED, so the rollback described above does not apply — the cloned workspace
///   persists and a retry sees an existing repo. Detail in `context`.
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
        let (handle, session_id) = arm_session(repo)?;
        Ok(ok_repo_handle(handle, session_id))
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
/// - `watcher.io_error` — the filesystem watcher could not be armed. Arming is strict-fail:
///   no handle is returned rather than one for an unwatched repo. It runs AFTER the
///   conversion has succeeded, so the written `.jj/` persists and a retry sees an existing
///   jj repo. Detail in `context`.
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
        let (handle, session_id) = arm_session(repo)?;
        Ok(ok_repo_handle(handle, session_id))
    });
    vec_into_token(buf)
}

// ── Mutation wrappers (Story 6.5) ────────────────────────────────────────────

/// Rewrite `change_id`'s description to `description` in the repo referenced by `handle`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `change_id` or `description` is a null pointer.
/// - `ffi.utf8_error` — `change_id` or `description` is not valid UTF-8.
/// - `jj.change_not_found` — `change_id` is malformed, absent, only-hidden, or divergent.
/// - `jj.invalid_input` — `change_id` resolves to the root commit.
/// - `jj.immutable` — `change_id` resolves to a non-root commit inside the repo's
///   effective immutable set; the offending hex commit id in `context`.
/// - `jj.config_error` — the repo's jj config, or its
///   `revset-aliases."immutable_heads()"`, could not be read/parsed/resolved, so the
///   immutable set is unknown; detail in `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not
/// been closed. `0` is detected and returned as `ffi.invalid_handle`. A stale
/// non-zero handle is undefined behaviour; the Dart worker's Model-A handle table
/// (Story 3.9) makes a stale handle unreachable.
/// `change_id` and `description` must each be a NUL-terminated UTF-8 C string owned
/// by the caller (Dart allocates via `toNativeUtf8()` and frees with `calloc.free()`
/// after this call returns — AR-P-5 inbound rule). Rust only borrows them for the
/// duration of the call; they are never freed on the Rust side.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_describe(
    handle: u64,
    change_id: *const c_char,
    description: *const c_char,
) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_describe", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        // SAFETY: both are caller-owned NUL-terminated C strings (Dart allocates + frees).
        let id = unsafe { cstr_to_string(change_id) }?;
        let desc = unsafe { cstr_to_string(description) }?;
        let result = session.repo.describe(ChangeId(id), &desc).map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

/// Create a new, empty change on top of `parents` in the repo referenced by `handle`
/// and switch the working copy to it — a merge commit when `parents` has more than
/// one entry.
///
/// `parents` crosses as a `ChangeIdList` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern), not `args_json` and not a raw C-string array.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ChangeIdList` buffer.
/// - `jj.invalid_input` — the parsed `parents` list is empty.
/// - `jj.change_not_found` — a parent id is malformed, absent, only-hidden, or divergent.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not
/// been closed. `0` is detected and returned as `ffi.invalid_handle`. A stale
/// non-zero handle is undefined behaviour; the Dart worker's Model-A handle table
/// (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and
/// owned/freed by Dart (`fbs.ChangeIdListObjectBuilder(...).toBytes()`); Rust only
/// borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_new_change(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_new_change", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let parents = read_change_id_list(data, len)?;
        let result = session.repo.new_change(&parents).map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

/// Switch the working copy to `change_id` without creating a new commit, in the repo
/// referenced by `handle`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `change_id` is a null pointer.
/// - `ffi.utf8_error` — `change_id` is not valid UTF-8.
/// - `jj.change_not_found` — `change_id` is malformed, absent, only-hidden, or divergent.
/// - `jj.immutable` — `change_id` resolves to a commit inside the repo's effective
///   immutable set; the offending hex commit id in `context`. Unlike `zanshin_describe`
///   and `zanshin_abandon`, this wrapper has no separate root-commit guard, so editing the
///   ROOT commit reports this code too (which is what the jj CLI reports for it).
/// - `jj.config_error` — the repo's jj config, or its
///   `revset-aliases."immutable_heads()"`, could not be read/parsed/resolved, so the
///   immutable set is unknown; detail in `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not
/// been closed. `0` is detected and returned as `ffi.invalid_handle`. A stale
/// non-zero handle is undefined behaviour; the Dart worker's Model-A handle table
/// (Story 3.9) makes a stale handle unreachable.
/// `change_id` must be a NUL-terminated UTF-8 C string owned by the caller (Dart
/// allocates via `toNativeUtf8()` and frees with `calloc.free()` after this call
/// returns — AR-P-5 inbound rule). Rust only borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_edit(handle: u64, change_id: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_edit", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        // SAFETY: change_id is a caller-owned NUL-terminated C string (Dart allocates + frees).
        let id = unsafe { cstr_to_string(change_id) }?;
        let result = session.repo.edit(ChangeId(id)).map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

/// Abandon `change_ids` in the repo referenced by `handle`, rebasing descendants onto
/// their parents and deleting any bookmarks that pointed only at the abandoned commits.
///
/// `change_ids` crosses as a `ChangeIdList` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern), not `args_json` and not a raw C-string array.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
/// If `@` itself is among `change_ids`, jj-lib creates a fresh empty commit at the
/// (merged) parent(s) and repoints the working copy at it automatically — its change
/// id is reported in `MutationResult.new_change_ids`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ChangeIdList` buffer.
/// - `jj.invalid_input` — the parsed `change_ids` list is empty, or resolves the root commit.
/// - `jj.change_not_found` — a target id is malformed, absent, only-hidden, or divergent.
/// - `jj.immutable` — a target resolves to a non-root commit inside the repo's effective
///   immutable set; the hex commit id of the FIRST such target in `context`.
/// - `jj.config_error` — the repo's jj config, or its
///   `revset-aliases."immutable_heads()"`, could not be read/parsed/resolved, so the
///   immutable set is unknown; detail in `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not
/// been closed. `0` is detected and returned as `ffi.invalid_handle`. A stale
/// non-zero handle is undefined behaviour; the Dart worker's Model-A handle table
/// (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and
/// owned/freed by Dart (`fbs.ChangeIdListObjectBuilder(...).toBytes()`); Rust only
/// borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_abandon(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_abandon", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let change_ids = read_change_id_list(data, len)?;
        let result = session.repo.abandon(&change_ids).map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

/// Revert the last operation of the repo referenced by `handle`, one step back from
/// the current head. Calling this twice in a row redoes the first `undo`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.nothing_to_undo` — the head operation IS the op-store root (no parent to
///   restore to).
/// - `jj.invalid_input` — the head operation has more than one parent (a
///   divergent-write merge op).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not
/// been closed. `0` is detected and returned as `ffi.invalid_handle`. A stale
/// non-zero handle is undefined behaviour; the Dart worker's Model-A handle table
/// (Story 3.9) makes a stale handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_undo(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_undo", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.undo().map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

/// Fetch all branches and tags from `remote_name` and import them, in the repo
/// referenced by `handle`. Never moves `@` — fetch only updates remote-tracking refs.
///
/// Progress is dispatched over the SAME process-global event sink `WatcherEvent`
/// already uses (Story 3.6), tagged with the session's `session_id` — there is no
/// separate per-op registry; the caller correlates by `session_id`, exactly like a
/// `WatcherEvent`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
/// Its `abandoned_change_ids` carries the commits the import abandoned because they
/// became unreachable in git (what `git.abandon-unreachable-commits` governs) — jj-lib's
/// OWN abandonments, not a caller echo, and empty when that key is off or nothing became
/// unreachable. `new_change_ids` is always empty: a fetch mints nothing.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `remote_name` is a null pointer.
/// - `ffi.utf8_error` — `remote_name` is not valid UTF-8.
/// - `jj.remote_not_found` — `remote_name` has no configured git remote.
/// - `jj.not_a_git_repo` — the OPEN WORKSPACE has no git backend at all, so `git fetch`
///   cannot run. Carries NO `context` — there is no path to name. Identical to what the
///   six `zanshin_git_remote_*`/`_import`/`_export` wrappers report for that condition.
/// - `jj.config_error` — the repo's effective config could not be read, or
///   `git.abandon-unreachable-commits`/`git.record-synthetic-predecessors` has a
///   non-boolean value; both are read per call rather than hardcoded.
/// - `jj.network_error` — the underlying `git` subprocess failed; detail in `context`.
/// - `jj.jj_lib_error` — any other underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not
/// been closed. `0` is detected and returned as `ffi.invalid_handle`. A stale
/// non-zero handle is undefined behaviour; the Dart worker's Model-A handle table
/// (Story 3.9) makes a stale handle unreachable.
/// `remote_name` must be a NUL-terminated UTF-8 C string owned by the caller (Dart
/// allocates via `toNativeUtf8()` and frees with `calloc.free()` after this call
/// returns — AR-P-5 inbound rule). Rust only borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_git_fetch(handle: u64, remote_name: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_fetch", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        // SAFETY: remote_name is a caller-owned NUL-terminated C string (Dart allocates + frees).
        let remote_name = unsafe { cstr_to_string(remote_name) }?;
        // Copy the Copy `u64` out BEFORE building the closure — avoids a borrow
        // conflict with the subsequent `session.repo.git_fetch(&mut self, ...)`.
        let session_id = session.session_id;
        let progress = move |e: zanshin_jj::ProgressEvent| {
            events::dispatch(events::progress_to_envelope(
                session_id,
                &e.operation,
                e.progress,
                &e.message,
            ));
        };
        let result = session
            .repo
            .git_fetch(&remote_name, &progress)
            .map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

// ── Content ops (Story 9.3) ──────────────────────────────────────────────────

/// Give the paths selected by the request the content they have in another commit, in the
/// repo referenced by `handle` — the CLI's `jj restore`, whole-file only (no interactive
/// or hunk selection).
///
/// The arguments cross as a `RestoreRequest` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern). An ABSENT string is the wire form of "the user did not supply
/// it", which is what applies the CLI's own defaults: if exactly one of `from`/`into` is
/// supplied the other is `@`; if neither is, the destination (`changes_in`, else `@`) is
/// restored from its PARENT tree. `changes_in` may not be combined with `from`/`into`.
/// An empty `paths` means all paths; entries are repo-relative PREFIXES.
///
/// The working copy is NOT snapshotted first: `@` is the last-snapshotted working-copy
/// commit (D2). If the resulting tree already equals the destination's, NO operation is
/// written and `MutationResult.new_op_id` carries the PRE-CALL op-log head.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `RestoreRequest` buffer.
/// - `jj.invalid_input` — `changes_in` was combined with `from`/`into`, or a `paths` entry
///   is not a valid repo path; detail in `context`.
/// - `jj.change_not_found` — `from`, `into` or `changes_in` is malformed, carried by no
///   VISIBLE commit (unknown or only-hidden), or divergent. An ABSENT one is not an error —
///   it is exactly the "the user did not supply it" wire form described above, and it is what
///   applies the CLI's `--from`/`--into`/`--changes-in` defaults.
/// - `jj.immutable` — the destination resolves to a commit inside the repo's effective
///   immutable set; the offending hex commit id in `context`. This wrapper has no separate
///   root-commit guard, so restoring INTO the root commit reports this code too (which is
///   what the jj CLI reports for it).
/// - `jj.config_error` — the repo's jj config, or its
///   `revset-aliases."immutable_heads()"`, could not be read/parsed/resolved, so the
///   immutable set is unknown; detail in `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not
/// been closed. `0` is detected and returned as `ffi.invalid_handle`. A stale
/// non-zero handle is undefined behaviour; the Dart worker's Model-A handle table
/// (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and
/// owned/freed by Dart (`fbs.RestoreRequestObjectBuilder(...).toBytes()`); Rust only
/// borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_restore(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_restore", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let req = read_restore_request(data, len)?;
        let result = session
            .repo
            .restore(req.from, req.into, req.changes_in, &req.paths, req.restore_descendants)
            .map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

/// Move each hunk of the source commit into the closest destination commit where the
/// corresponding lines were last modified, in the repo referenced by `handle` — the CLI's
/// `jj absorb`, non-interactive only.
///
/// The arguments cross as an `AbsorbRequest` `FlatBuffers` request buffer. An absent `from`
/// means `@`; an absent `into` applies the CLI's own `--into` default, the `mutable()`
/// ALIAS, resolved through the repo's effective config — so a user's `[revset-aliases]`
/// decides what it denotes. Unlike every other mutation argument, `into` is a revset
/// EXPRESSION rather than a change id (FR-JJ-17).
///
/// Returns a `FlatBuffers` `Envelope` carrying an `AbsorbResult` payload on success. Paths
/// jj-lib refuses to split are reported in `AbsorbResult.skipped_paths` (the CLI prints one
/// warning per entry) rather than failing the call. If nothing was absorbable, NO operation
/// is written, `rewritten_change_ids` is empty, and the nested `MutationResult.new_op_id`
/// carries the PRE-CALL op-log head. The working copy is NOT snapshotted first (D2).
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `AbsorbRequest` buffer.
/// - `jj.revset_parse_error` — `into` is syntactically invalid or names an unknown
///   function; jj-lib's reason in `context`.
/// - `jj.revset_resolution_error` — `into` is well-formed but a symbol in it cannot be
///   resolved; jj-lib's reason in `context`.
/// - `jj.invalid_input` — a `paths` entry is not a valid repo path; detail in `context`.
/// - `jj.change_not_found` — `from` is malformed, carried by no VISIBLE commit (unknown or
///   only-hidden), or divergent. An ABSENT `from` is not an error — it is what applies the
///   CLI's `--from` default `@`.
/// - `jj.immutable` — a commit the hunks would be absorbed into is inside the repo's
///   effective immutable set; the hex commit id of the FIRST such target in `context`.
///   Unreachable with the `mutable()` default, which excludes that set by construction.
/// - `jj.config_error` — the repo's jj config, or its
///   `revset-aliases."immutable_heads()"`, could not be read/parsed/resolved; detail in
///   `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not
/// been closed. `0` is detected and returned as `ffi.invalid_handle`. A stale
/// non-zero handle is undefined behaviour; the Dart worker's Model-A handle table
/// (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and
/// owned/freed by Dart (`fbs.AbsorbRequestObjectBuilder(...).toBytes()`); Rust only
/// borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_absorb(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_absorb", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let req = read_absorb_request(data, len)?;
        let result = session
            .repo
            .absorb(req.from, req.into.as_deref(), &req.paths)
            .map_err(map_mutate_err)?;
        Ok(ok_absorb_result(&result))
    });
    vec_into_token(buf)
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope_generated::zanshin::ffi as fbs;
    use crate::{
        FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, JJ_ALREADY_JJ_REPO, JJ_CHANGE_NOT_FOUND, JJ_CONVERT_FAILED,
        JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_NETWORK_ERROR, JJ_NOTHING_TO_UNDO, JJ_NOT_A_GIT_REPO, JJ_PATH_NOT_FOUND,
        JJ_REMOTE_NOT_FOUND, JJ_REPO_NOT_FOUND,
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
    fn map_mutate_err_change_not_found_maps_to_jj_change_not_found() {
        let e = map_mutate_err(MutateError::ChangeNotFound { id: "bogus".to_owned() });
        assert_eq!(e.code, JJ_CHANGE_NOT_FOUND);
        assert_eq!(e.context.unwrap(), "bogus");
    }

    #[test]
    fn map_mutate_err_invalid_input_maps_to_jj_invalid_input() {
        let e = map_mutate_err(MutateError::InvalidInput {
            reason: "empty list".to_owned(),
        });
        assert_eq!(e.code, JJ_INVALID_INPUT);
        assert_eq!(e.context.unwrap(), "empty list");
    }

    #[test]
    fn map_mutate_err_immutable_maps_to_jj_immutable() {
        let e = map_mutate_err(MutateError::Immutable {
            commit_id: "deadbeef".to_owned(),
        });
        assert_eq!(e.code, JJ_IMMUTABLE);
        assert_eq!(e.context.unwrap(), "deadbeef");
    }

    #[test]
    fn map_mutate_err_config_maps_to_jj_config_error() {
        let e = map_mutate_err(MutateError::Config {
            reason: "config.toml: invalid TOML".to_owned(),
        });
        assert_eq!(
            e.code, JJ_CONFIG_ERROR,
            "a bad immutable_heads() alias is the SAME fault the read side reports"
        );
        assert_eq!(e.context.unwrap(), "config.toml: invalid TOML");
    }

    #[test]
    fn map_mutate_err_nothing_to_undo_maps_to_jj_nothing_to_undo() {
        let e = map_mutate_err(MutateError::NothingToUndo);
        assert_eq!(e.code, JJ_NOTHING_TO_UNDO);
        assert!(e.context.is_none());
    }

    #[test]
    fn map_mutate_err_remote_not_found_maps_to_jj_remote_not_found() {
        let e = map_mutate_err(MutateError::RemoteNotFound {
            name: "origin".to_owned(),
        });
        assert_eq!(e.code, JJ_REMOTE_NOT_FOUND);
        assert_eq!(e.context.unwrap(), "origin");
    }

    #[test]
    fn map_mutate_err_network_error_maps_to_jj_network_error() {
        let e = map_mutate_err(MutateError::NetworkError {
            reason: "connection refused".to_owned(),
        });
        assert_eq!(e.code, JJ_NETWORK_ERROR);
        assert_eq!(e.context.unwrap(), "connection refused");
    }

    #[test]
    fn map_mutate_err_revset_parse_error_maps_to_jj_revset_parse_error() {
        let e = map_mutate_err(MutateError::RevsetParseError {
            reason: "unknown function".to_owned(),
        });
        assert_eq!(e.code, JJ_REVSET_PARSE_ERROR);
        assert_eq!(e.context.unwrap(), "unknown function");
    }

    #[test]
    fn map_mutate_err_revset_resolution_error_maps_to_jj_revset_resolution_error() {
        let e = map_mutate_err(MutateError::RevsetResolutionError {
            reason: "no such bookmark".to_owned(),
        });
        assert_eq!(e.code, JJ_REVSET_RESOLUTION_ERROR);
        assert_eq!(e.context.unwrap(), "no such bookmark");
    }

    #[test]
    fn map_mutate_err_backend_maps_to_jj_lib_error() {
        let e = map_mutate_err(MutateError::Backend("underlying".to_owned()));
        assert_eq!(e.code, JJ_JJ_LIB_ERROR);
        assert_eq!(e.context.unwrap(), "underlying");
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
