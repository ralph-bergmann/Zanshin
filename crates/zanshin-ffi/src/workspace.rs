// SPDX-License-Identifier: MIT

//! `zanshin_workspace_list` / `zanshin_workspace_root` — the two workspace READ verbs
//! (Story 9.7).
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the result into a
//! `FlatBuffers` `Envelope`. The handle is borrowed (not consumed), and neither writes an
//! operation — not even on a refusal.
//!
//! The two verbs cross the boundary DIFFERENTLY, mirroring the CLI's own argument arity:
//! `zanshin_workspace_list` is handle-only, because `jj workspace list` takes no argument at all
//! (its lone `-T/--template` flag is rendering); `zanshin_workspace_root` takes a request BUFFER,
//! because its `--name` must be distinguishably ABSENT — that absence is what applies the CLI's
//! documented default, the current workspace.
//!
//! They are also asymmetric on an unusable recorded path, deliberately: a `WorkspaceEntry`'s
//! `root` degrades to absent while `zanshin_workspace_root` refuses with one of three codes. See
//! `zanshin_jj::workspace`'s module doc for why that is parity rather than an inconsistency.

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{WorkspaceEntry, WorkspaceError};

use crate::envelope::{
    catch, finish_envelope, invalid_request, reject_null_request, FfiErrorObj, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR,
    JJ_WORKSPACE_NOT_FOUND, JJ_WORKSPACE_NO_RECORDED_PATH, JJ_WORKSPACE_PATH_UNRESOLVED,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;
use crate::repo::RepoSession;

/// Maps a [`WorkspaceError`] onto its AR-P-4 code; user data always rides in `context`.
///
/// The three refusal variants get three codes rather than one, because their remedies differ —
/// the same test `jj.remote_exists` passed in Story 9.5. `PathUnresolved` carries BOTH the
/// workspace name and the I/O reason, since neither alone identifies the failure.
fn map_workspace_err(e: WorkspaceError) -> FfiErrorObj {
    let (code, context) = match e {
        WorkspaceError::NotFound { name } => (JJ_WORKSPACE_NOT_FOUND, name),
        WorkspaceError::NoRecordedPath { name } => (JJ_WORKSPACE_NO_RECORDED_PATH, name),
        WorkspaceError::PathUnresolved { name, reason } => (JJ_WORKSPACE_PATH_UNRESOLVED, format!("{name}: {reason}")),
        WorkspaceError::Backend(reason) => (JJ_JJ_LIB_ERROR, reason),
    };
    FfiErrorObj {
        code: code.to_owned(),
        context: Some(context),
    }
}

// ── Request-buffer reader ────────────────────────────────────────────────────
//
// Same discipline as `commit_views.rs`'s, `file.rs`'s and `git.rs`'s readers: `data`/`len`
// describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for the call
// only. The reader builds its OWN byte slice in its own scope and returns an OWNED struct, so
// the unbounded lifetime `std::slice::from_raw_parts` produces provably cannot outlive the call.

/// Owned Rust form of a `WorkspaceRootRequest` buffer. `name` is `Option<String>` — an ABSENT
/// field is the wire form of "the user did not supply `--name`", which selects the CURRENT
/// workspace; an explicitly EMPTY string is a VALUE and refuses as `jj.workspace_not_found`.
struct WorkspaceRootRequestOwned {
    name: Option<String>,
}

/// Parse a `WorkspaceRootRequest` buffer into an owned [`WorkspaceRootRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceRootRequest` buffer.
fn read_workspace_root_request(data: *const u8, len: usize) -> Result<WorkspaceRootRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::WorkspaceRootRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    Ok(WorkspaceRootRequestOwned {
        name: req.name().map(ToOwned::to_owned),
    })
}

// ── Payload builders ─────────────────────────────────────────────────────────

/// Serialise `&[WorkspaceEntry]` into a finished `Envelope<WorkspaceList>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): each row's strings are built before its
/// table, and the outer vector and `WorkspaceList` table come after the loop. `root` is written
/// only when present — null-for-absence is the wire form of "this workspace's path cannot be
/// reported", which is never an error here.
fn workspace_list_to_envelope(entries: &[WorkspaceEntry]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let offsets: Vec<_> = entries
        .iter()
        .map(|e| {
            let name = b.create_string(&e.name);
            let wc = b.create_string(&e.wc_commit_id.0);
            // `to_string_lossy` is the crate's path→wire rule (`repo.rs:271`): a path is bytes,
            // the wire field is a UTF-8 string, and a lossy rendering beats refusing to answer.
            let root = e.root.as_ref().map(|p| b.create_string(&p.to_string_lossy()));
            fbs::WorkspaceEntry::create(
                &mut b,
                &fbs::WorkspaceEntryArgs {
                    name: Some(name),
                    wc_commit_id: Some(wc),
                    root,
                },
            )
        })
        .collect();
    let vec = b.create_vector(&offsets);
    let table = fbs::WorkspaceList::create(&mut b, &fbs::WorkspaceListArgs { entries: Some(vec) });
    finish_envelope(b, fbs::Payload::WorkspaceList, table.as_union_value())
}

/// Serialise one resolved workspace root into a finished `Envelope<WorkspaceRoot>` buffer.
///
/// Unlike a list row's `root`, this field is always present: the verb refuses rather than
/// reporting an absent path.
fn workspace_root_to_envelope(root: &std::path::Path) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let root_off = b.create_string(&root.to_string_lossy());
    let table = fbs::WorkspaceRoot::create(&mut b, &fbs::WorkspaceRootArgs { root: Some(root_off) });
    finish_envelope(b, fbs::Payload::WorkspaceRoot, table.as_union_value())
}

/// Borrow the [`RepoSession`] behind a raw handle, or produce `ffi.invalid_handle`.
///
/// # Safety
/// `handle` must be `0` or a live value returned by a successful handle-producing wrapper.
unsafe fn session_from_handle<'a>(handle: u64) -> Result<&'a mut RepoSession, FfiErrorObj> {
    // SAFETY: non-zero handle originated from arm_session's handle_into_raw
    // (Box<RepoSession>) in zanshin_repo_open/init/clone/convert; single-isolate model
    // (AD-2) guarantees no concurrent access.
    unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(|| FfiErrorObj {
        code: FFI_INVALID_HANDLE.to_owned(),
        context: None,
    })
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// List every workspace of the repo identified by `handle`, with its working-copy commit and
/// root directory — the CLI's `jj workspace list`.
///
/// Handle-only: the CLI verb takes no argument at all, and its `-T/--template` flag is rendering.
/// Rows come in jj-lib's own `BTreeMap` order (lexicographic by workspace name). A row's `root`
/// is ABSENT when the path cannot be reported — no recorded path (a workspace predating jj
/// 0.38.0), an unreadable store, or a recorded directory that moved or was deleted. None of those
/// fails the call: the CLI's own list template degrades the same way and points at
/// `zanshin_workspace_root` for strict diagnostics. This read writes NO operation.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `WorkspaceList` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.jj_lib_error` — `load_at_head` failed, i.e. the VIEW half could not be read; detail in
///   `context`. No path failure reaches this.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_workspace_list(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_workspace_list", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let entries = session.repo.list_workspaces().map_err(map_workspace_err)?;
        Ok(workspace_list_to_envelope(&entries))
    });
    vec_into_token(buf)
}

/// Return one workspace's root directory in the repo identified by `handle` — the CLI's
/// `jj workspace root [--name]`.
///
/// The argument crosses as a `WorkspaceRootRequest` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern), because the CLI's `--name` must be distinguishably ABSENT. An absent
/// `name` selects the CURRENT workspace and reads the workspace loader alone — no repo load, no
/// store read — which is the one path that cannot fail; it returns exactly what
/// `zanshin_jj::Repo::workspace_root` reports. A PRESENT name, even the current workspace's own,
/// goes through the `WorkspaceStore` and can refuse: the CLI's named path never shortcuts to the
/// loader, and that asymmetry is reproduced rather than smoothed over. An explicitly present
/// EMPTY name is a VALUE, not an absence, and refuses as `jj.workspace_not_found`.
/// The returned path is ABSOLUTE and canonicalized; CWD-relative shortening is the GUI's job.
/// This read writes NO operation — not even on a refusal.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `WorkspaceRoot` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `WorkspaceRootRequest` buffer.
/// - `jj.workspace_not_found` — no workspace of that name is in the head view; the name in
///   `context`.
/// - `jj.workspace_no_recorded_path` — the workspace exists but the store holds no path for it;
///   the name in `context`.
/// - `jj.workspace_path_unresolved` — a path IS recorded but does not resolve; `context` names
///   the workspace and the I/O reason.
/// - `jj.jj_lib_error` — the workspace store could not be loaded or read, or `load_at_head`
///   failed; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.WorkspaceRootRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_workspace_root(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_workspace_root", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let req = read_workspace_root_request(data, len)?;
        let root = session
            .repo
            .resolve_workspace_root(req.name.as_deref())
            .map_err(map_workspace_err)?;
        Ok(workspace_root_to_envelope(&root))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use flatbuffers::root;
    use zanshin_jj::{CommitId, WorkspaceEntry, WorkspaceError};

    use super::{map_workspace_err, workspace_list_to_envelope, workspace_root_to_envelope};
    use crate::envelope::{
        JJ_JJ_LIB_ERROR, JJ_WORKSPACE_NOT_FOUND, JJ_WORKSPACE_NO_RECORDED_PATH, JJ_WORKSPACE_PATH_UNRESOLVED,
    };
    use crate::fbs;

    fn entry(name: &str, root: Option<&str>) -> WorkspaceEntry {
        WorkspaceEntry {
            name: name.to_owned(),
            wc_commit_id: CommitId(format!("{name}-commit")),
            root: root.map(PathBuf::from),
        }
    }

    #[test]
    fn workspace_list_writes_present_and_absent_roots_in_order() {
        let buf = workspace_list_to_envelope(&[entry("default", Some("/tmp/ws")), entry("second", None)]);
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::WorkspaceList);
        let items = env
            .data_as_workspace_list()
            .expect("expected WorkspaceList payload")
            .entries()
            .expect("entries vector");
        assert_eq!(items.len(), 2);
        assert_eq!(items.get(0).name(), Some("default"));
        assert_eq!(items.get(0).wc_commit_id(), Some("default-commit"));
        assert_eq!(items.get(0).root(), Some("/tmp/ws"));
        // Null-for-absence: an unreportable path is an absent field, never an empty string.
        assert_eq!(items.get(1).name(), Some("second"));
        assert_eq!(items.get(1).root(), None);
    }

    #[test]
    fn workspace_list_empty_roundtrips() {
        let buf = workspace_list_to_envelope(&[]);
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        let payload = env.data_as_workspace_list().expect("expected WorkspaceList payload");
        assert_eq!(payload.entries().map_or(0, |e| e.len()), 0);
    }

    #[test]
    fn workspace_root_roundtrips() {
        let buf = workspace_root_to_envelope(&PathBuf::from("/tmp/ws/second"));
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::WorkspaceRoot);
        assert_eq!(
            env.data_as_workspace_root().expect("payload").root(),
            Some("/tmp/ws/second")
        );
    }

    #[test]
    fn every_workspace_error_variant_maps_to_its_own_code() {
        let not_found = map_workspace_err(WorkspaceError::NotFound {
            name: "nosuch".to_owned(),
        });
        assert_eq!(not_found.code, JJ_WORKSPACE_NOT_FOUND);
        assert_eq!(not_found.context, Some("nosuch".to_owned()));

        let no_path = map_workspace_err(WorkspaceError::NoRecordedPath {
            name: "legacy".to_owned(),
        });
        assert_eq!(no_path.code, JJ_WORKSPACE_NO_RECORDED_PATH);
        assert_eq!(no_path.context, Some("legacy".to_owned()));

        // Both halves ride in `context`: neither the name nor the I/O reason alone identifies
        // which workspace failed and why.
        let unresolved = map_workspace_err(WorkspaceError::PathUnresolved {
            name: "moved".to_owned(),
            reason: "No such file or directory (os error 2)".to_owned(),
        });
        assert_eq!(unresolved.code, JJ_WORKSPACE_PATH_UNRESOLVED);
        assert_eq!(
            unresolved.context,
            Some("moved: No such file or directory (os error 2)".to_owned())
        );

        let backend = map_workspace_err(WorkspaceError::Backend("boom".to_owned()));
        assert_eq!(backend.code, JJ_JJ_LIB_ERROR);
        assert_eq!(backend.context, Some("boom".to_owned()));
    }
}
