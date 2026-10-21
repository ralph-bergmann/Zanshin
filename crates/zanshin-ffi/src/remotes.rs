// SPDX-License-Identifier: MIT

//! `zanshin_remotes` — remote-list read FFI wrapper (Story 3.4b, remotes slice) — and
//! `zanshin_git_push_remotes` / `zanshin_git_fetch_remotes`, the default push and fetch remotes
//! (Stories 9.54, 9.30).
//!
//! `zanshin_remotes` calls `zanshin_jj::Repo::list_remotes()` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying a `Remotes` payload. The handle is borrowed
//! (not consumed). Both `url` and `push_url` cross the wire verbatim (no credential
//! scrubbing); `push_url` is ABSENT when the remote pushes to its fetch URL.
//! `zanshin_git_push_remotes` calls `zanshin_jj::Repo::git_push_remotes()` into a
//! `GitPushRemotes` payload, and `zanshin_git_fetch_remotes` (Story 9.30)
//! `zanshin_jj::Repo::git_fetch_remotes()` into a `GitFetchRemotes` payload.
//! `zanshin_git_remote_changes` (Story 9.24) calls `zanshin_jj::Repo::remote_changes()` — the
//! `git ls-remote` poll — into a `RemoteChanges` payload.

use flatbuffers::FlatBufferBuilder;
use std::ffi::c_char;
use tracing::debug;

use zanshin_jj::{Remote, RemoteError, RemoteRefChange, RemoteRefChangeKind, RemoteRefKind};

use crate::envelope::{
    catch, finish_envelope, map_precondition_err, precondition_envelope, session_from_handle, FfiErrorObj,
    JJ_JJ_LIB_ERROR,
};
use crate::fbs;
use crate::ffi_strings::{cstr_to_string, vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

fn map_remotes_err(e: RemoteError) -> FfiErrorObj {
    match e {
        RemoteError::Precondition(e) => map_precondition_err(e),
        RemoteError::Backend(reason) => FfiErrorObj {
            report: None,
            hints: Vec::new(),
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

/// Serialise `&[Remote]` into a finished `Envelope<Remotes>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): for each `Remote`, its
/// strings are built before its table; the `remotes` vector and `Remotes` table
/// come after the loop. No kind match — a `Remote` is just plain strings, one of
/// which (`push_url`) is null-for-absence and stays ABSENT rather than `""`.
fn remotes_to_envelope(remotes: &[Remote], report: &crate::envelope::CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mut offsets = Vec::with_capacity(remotes.len());
    for r in remotes {
        let name_off = b.create_string(&r.name);
        let url_off = b.create_string(&r.url);
        let push_off = r.push_url.as_deref().map(|s| b.create_string(s));
        let r_off = fbs::Remote::create(
            &mut b,
            &fbs::RemoteArgs {
                name: Some(name_off),
                url: Some(url_off),
                push_url: push_off,
            },
        );
        offsets.push(r_off);
    }
    let vec = b.create_vector(&offsets);
    let rems_off = fbs::Remotes::create(&mut b, &fbs::RemotesArgs { remotes: Some(vec) });
    finish_envelope(b, fbs::Payload::Remotes, Some(rems_off.as_union_value()), report)
}

/// List the configured git remotes of the repo identified by `handle`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `Remotes` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` or the borrow yields `None`.
/// - `jj.config_error` — the pre-verb snapshot (Story 9.26) found the effective jj config
///   unreadable or a knob it reads wrongly typed (the key in `context`). Operations the snapshot
///   committed before the fault stay, as in the CLI (colocated: `import git head`); the partial
///   `precondition` says which.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
/// - `jj.jj_lib_error` — an unclassified jj-lib error; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, or `zanshin_repo_clone` that has not been closed.
/// `0` is detected and returned as `ffi.invalid_handle`.
/// A stale non-zero handle is undefined behaviour; the Dart worker's Model-A
/// handle table (Story 3.9) makes a stale handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_remotes(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_remotes", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let rems = session.repo.list_remotes();
        precondition_envelope(&mut session.repo, rems, map_remotes_err, |v, p| {
            remotes_to_envelope(v, p)
        })
    });
    vec_into_token(buf)
}

/// Serialise the default push remotes into a finished `Envelope<GitPushRemotes>` buffer.
fn push_remotes_to_envelope(names: &[String], report: &crate::envelope::CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let offsets: Vec<_> = names.iter().map(|name| b.create_string(name)).collect();
    let names = b.create_vector(&offsets);
    let payload = fbs::GitPushRemotes::create(&mut b, &fbs::GitPushRemotesArgs { names: Some(names) });
    finish_envelope(b, fbs::Payload::GitPushRemotes, Some(payload.as_union_value()), report)
}

/// The remotes `jj git push` without `--remote` would push to, in the repo identified by `handle`
/// (Story 9.54) — the CLI's default-remote resolution, shared with `zanshin_git_push`: the remotes
/// `git.push` names (a name, a list or a pattern), else the single remote, else `origin`, each
/// only when it exists, in remote-name order.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `GitPushRemotes` payload on success — EMPTY when
/// none matches (the push itself refuses then) and on a non-Git backend. An exact name no remote
/// carries — a `git.push` name, or the implicit `origin` — warns `jj.push_remotes_unmatched`, as
/// the push does. Writes NO operation of its own, only the pre-verb snapshot's.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` or the borrow yields `None`.
/// - `jj.config_error` — the git.push setting is neither a string nor a list of strings, or the
///   pre-verb snapshot (Story 9.26) found the effective jj config unreadable; the key in
///   `context`.
/// - `jj.invalid_input` — a git.push pattern does not parse; detail in `context`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an unclassified jj-lib error; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, or `zanshin_repo_clone` that has not been closed.
/// `0` is detected and returned as `ffi.invalid_handle`.
/// A stale non-zero handle is undefined behaviour; the Dart worker's Model-A
/// handle table (Story 3.9) makes a stale handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_git_push_remotes(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_push_remotes", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let names = session.repo.git_push_remotes();
        precondition_envelope(&mut session.repo, names, map_mutate_err, |v, p| {
            push_remotes_to_envelope(v, p)
        })
    });
    vec_into_token(buf)
}

/// Serialise the default fetch remotes into a finished `Envelope<GitFetchRemotes>` buffer.
fn fetch_remotes_to_envelope(names: &[String], report: &crate::envelope::CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let offsets: Vec<_> = names.iter().map(|name| b.create_string(name)).collect();
    let names = b.create_vector(&offsets);
    let payload = fbs::GitFetchRemotes::create(&mut b, &fbs::GitFetchRemotesArgs { names: Some(names) });
    finish_envelope(b, fbs::Payload::GitFetchRemotes, Some(payload.as_union_value()), report)
}

/// The remotes `jj git fetch` without `--remote` would fetch from, in the repo identified by
/// `handle` (Story 9.30) — the CLI's default-remote resolution, shared with `zanshin_git_fetch`:
/// the remotes `git.fetch` names (a name, a list or a pattern), else the single remote, else
/// `origin`, each only when it exists, in remote-name order. The Fetch button's enable rule:
/// enabled when this is not empty.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `GitFetchRemotes` payload on success — EMPTY when
/// none matches (the fetch itself refuses then) and on a non-Git backend. An exact name no remote
/// carries — a `git.fetch` name, or the implicit `origin` — warns `jj.fetch_remotes_unmatched`, as
/// the fetch does. The fetch's only-remote hint is not reported. Writes NO operation of its own,
/// only the pre-verb snapshot's.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` or the borrow yields `None`.
/// - `jj.config_error` — the git.fetch setting is neither a string nor a list of strings, or the
///   pre-verb snapshot (Story 9.26) found the effective jj config unreadable; the key in
///   `context`.
/// - `jj.invalid_input` — a git.fetch pattern does not parse; detail in `context`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an unclassified jj-lib error; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, or `zanshin_repo_clone` that has not been closed.
/// `0` is detected and returned as `ffi.invalid_handle`.
/// A stale non-zero handle is undefined behaviour; the Dart worker's Model-A
/// handle table (Story 3.9) makes a stale handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_git_fetch_remotes(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_fetch_remotes", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let names = session.repo.git_fetch_remotes();
        precondition_envelope(&mut session.repo, names, map_mutate_err, |v, p| {
            fetch_remotes_to_envelope(v, p)
        })
    });
    vec_into_token(buf)
}

/// Serialise the remote-change poll's answer into a finished `Envelope<RemoteChanges>` buffer.
/// `new_commit_id` stays ABSENT for a deleted ref, never `""`.
fn remote_changes_to_envelope(changes: &[RemoteRefChange], report: &crate::envelope::CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mut offsets = Vec::with_capacity(changes.len());
    for c in changes {
        let name = b.create_string(&c.name);
        let old: Vec<_> = c.old_commit_ids.iter().map(|id| b.create_string(&id.0)).collect();
        let old = b.create_vector(&old);
        let new = c.new_commit_id.as_ref().map(|id| b.create_string(&id.0));
        offsets.push(fbs::RemoteRefChange::create(
            &mut b,
            &fbs::RemoteRefChangeArgs {
                kind: match c.kind {
                    RemoteRefKind::Bookmark => fbs::RemoteRefKind::Bookmark,
                    RemoteRefKind::Tag => fbs::RemoteRefKind::Tag,
                },
                name: Some(name),
                change: match c.change {
                    RemoteRefChangeKind::Moved => fbs::RemoteRefChangeKind::Moved,
                    RemoteRefChangeKind::New => fbs::RemoteRefChangeKind::New,
                    RemoteRefChangeKind::Deleted => fbs::RemoteRefChangeKind::Deleted,
                },
                old_commit_ids: Some(old),
                new_commit_id: new,
            },
        ));
    }
    let changes = b.create_vector(&offsets);
    let payload = fbs::RemoteChanges::create(&mut b, &fbs::RemoteChangesArgs { changes: Some(changes) });
    finish_envelope(b, fbs::Payload::RemoteChanges, Some(payload.as_union_value()), report)
}

/// Ask `remote_name` what it has now and diff that against the head view, without fetching, in
/// the repo referenced by `handle` (Story 9.24): `git ls-remote --heads --tags`, run the way
/// jj-lib runs every git, compared with the view's `<name>@<remote>` bookmarks and tags. An
/// annotated tag is compared at the commit it peels to. Only the refs a bare `zanshin_git_fetch`
/// of the remote would fetch take part (Story 9.30): its `remotes.<name>.fetch-bookmarks`, else
/// its Git fetch refspecs, and its `remotes.<name>.fetch-tags`, else every tag.
///
/// No pre-verb snapshot, no transaction, no operation of its own, no object download; loading
/// the head may reconcile divergent operation heads, as every jj command does. The envelope
/// carries the start-up secure-config fix-up's warnings and NO `precondition`.
///
/// `cancel_token` (Story 9.52) is `0` (not cancellable) or a token from `zanshin_network_token`;
/// `zanshin_network_cancel` cancels the poll (its git is killed), and the token ends with this
/// call.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `RemoteChanges` payload on success — the refs
/// that moved, are new or were deleted upstream, bookmarks before tags, each by name; EMPTY when
/// nothing is new.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `remote_name` is a null pointer.
/// - `ffi.utf8_error` — `remote_name` is not valid UTF-8.
/// - `jj.remote_not_found` — no configured git remote is named `remote_name` exactly; the name in
///   `context`. git never runs.
/// - `jj.not_a_git_repo` — the open workspace has no git backend; no `context`.
/// - `jj.config_error` — the start-up fix-up failed, the changed config stack no longer reads,
///   `git.executable-path` does not read, or a `remotes.<name>` entry or the remote's
///   `fetch-bookmarks`/`fetch-tags` is malformed; detail in `context`.
/// - `jj.invalid_input` — the remote's Git configuration does not read, or a
///   `fetch-bookmarks`/`fetch-tags` pattern cannot become a refspec (Story 9.30); detail in
///   `context`. git never runs.
/// - `jj.network_error` — git could not be spawned or failed (network, authentication,
///   transport); jj-lib's text in `context`, e.g. `External git program failed:` + git's stderr.
/// - `jj.cancelled` — `cancel_token` was cancelled before or right after the git work, or git
///   failed after the cancel killed it; `context` is "Cancelled". Never without a token.
/// - `jj.jj_lib_error` — git's output is not a ref advertisement, or any other jj-lib failure;
///   detail in `context`.
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
pub unsafe extern "C" fn zanshin_git_remote_changes(
    handle: u64,
    remote_name: *const c_char,
    cancel_token: u64,
) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_remote_changes", handle);
    let buf = catch(|| {
        // Attached first, so a refusal below still ends the token.
        let cancel = zanshin_jj::cancel::attach(cancel_token);
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        // SAFETY: remote_name is a caller-owned NUL-terminated C string (Dart allocates + frees).
        let remote_name = unsafe { cstr_to_string(remote_name) }?;
        let result = session.repo.remote_changes(&remote_name, cancel.as_ref());
        precondition_envelope(&mut session.repo, result, map_mutate_err, |v, p| {
            remote_changes_to_envelope(v, p)
        })
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root;
    use zanshin_jj::{Remote, RemoteError};

    use super::{map_remotes_err, push_remotes_to_envelope, remote_changes_to_envelope, remotes_to_envelope};
    use crate::envelope::JJ_JJ_LIB_ERROR;
    use crate::fbs;

    #[test]
    fn remotes_to_envelope_roundtrips_multiple_entries() {
        // ≥2 distinct entries; one with embedded credentials to assert no scrubbing.
        // Both `push_url` arms are exercised: absent on index 0, present on index 1.
        let remotes = vec![
            Remote {
                name: "origin".to_owned(),
                url: "https://github.com/user/repo.git".to_owned(),
                push_url: None,
            },
            Remote {
                name: "creds".to_owned(),
                url: "https://user:token@example.com/r.git".to_owned(),
                push_url: Some("ssh://user:s3cr3t@example.com/r.git".to_owned()),
            },
        ];
        let buf = remotes_to_envelope(&remotes, &crate::envelope::CallReport::default());
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::Remotes);
        let payload = env.data_as_remotes().expect("expected Remotes payload");
        let items = payload.remotes().expect("remotes vector");
        assert_eq!(items.len(), 2);
        // index 0: origin — remotes_to_envelope preserves insertion order (no sort here;
        // sorting lives upstream in zanshin-jj::list_remotes).
        assert_eq!(items.get(0).name(), Some("origin"));
        assert_eq!(items.get(0).url(), Some("https://github.com/user/repo.git"));
        assert_eq!(
            items.get(0).push_url(),
            None,
            "absence must stay ABSENT on the wire, never an empty string"
        );
        // index 1: creds with embedded credentials — must NOT be scrubbed
        assert_eq!(items.get(1).name(), Some("creds"));
        let creds_url = items.get(1).url().expect("url must be present");
        assert!(
            creds_url.contains("user:token"),
            "embedded credentials must survive verbatim, got: {creds_url}"
        );
        let push_url = items.get(1).push_url().expect("push_url must be present");
        assert_eq!(push_url, "ssh://user:s3cr3t@example.com/r.git");
        assert!(
            push_url.contains("user:s3cr3t"),
            "push-URL credentials must survive verbatim too, got: {push_url}"
        );
    }

    #[test]
    fn remotes_to_envelope_empty_roundtrips() {
        let buf = remotes_to_envelope(&[], &crate::envelope::CallReport::default());
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::Remotes);
        let payload = env.data_as_remotes().expect("expected Remotes payload");
        assert_eq!(payload.remotes().map_or(0, |r| r.len()), 0);
    }

    #[test]
    fn push_remotes_to_envelope_roundtrips_in_order() {
        let names = ["origin".to_owned(), "fork".to_owned()];
        let buf = push_remotes_to_envelope(&names, &crate::envelope::CallReport::default());
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        let payload = env.data_as_git_push_remotes().expect("expected GitPushRemotes payload");
        let got: Vec<&str> = payload.names().expect("names").iter().collect();
        assert_eq!(got, ["origin", "fork"]);
    }

    #[test]
    fn map_remotes_err_backend_maps_to_jj_lib_error() {
        let obj = map_remotes_err(RemoteError::Backend("boom".to_owned()));
        assert_eq!(obj.code, JJ_JJ_LIB_ERROR);
        assert_eq!(obj.context, Some("boom".to_owned()));
    }

    #[test]
    fn remote_changes_to_envelope_roundtrips_every_kind() {
        use zanshin_jj::{CommitId, RemoteRefChange, RemoteRefChangeKind, RemoteRefKind};
        let changes = [
            RemoteRefChange {
                kind: RemoteRefKind::Bookmark,
                name: "main".to_owned(),
                change: RemoteRefChangeKind::Moved,
                old_commit_ids: vec![CommitId("aa".to_owned()), CommitId("bb".to_owned())],
                new_commit_id: Some(CommitId("cc".to_owned())),
            },
            RemoteRefChange {
                kind: RemoteRefKind::Tag,
                name: "v1".to_owned(),
                change: RemoteRefChangeKind::New,
                old_commit_ids: Vec::new(),
                new_commit_id: Some(CommitId("dd".to_owned())),
            },
            RemoteRefChange {
                kind: RemoteRefKind::Bookmark,
                name: "x".to_owned(),
                change: RemoteRefChangeKind::Deleted,
                old_commit_ids: vec![CommitId("ee".to_owned())],
                new_commit_id: None,
            },
        ];
        let buf = remote_changes_to_envelope(&changes, &crate::envelope::CallReport::default());
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert!(env.precondition().is_none());
        let items = env
            .data_as_remote_changes()
            .expect("expected RemoteChanges payload")
            .changes()
            .expect("changes");
        let got: Vec<_> = items
            .iter()
            .map(|c| {
                (
                    c.kind(),
                    c.name(),
                    c.change(),
                    c.old_commit_ids().map(|v| v.iter().collect::<Vec<_>>()),
                    c.new_commit_id(),
                )
            })
            .collect();
        assert_eq!(
            got,
            [
                (
                    fbs::RemoteRefKind::Bookmark,
                    Some("main"),
                    fbs::RemoteRefChangeKind::Moved,
                    Some(vec!["aa", "bb"]),
                    Some("cc"),
                ),
                (
                    fbs::RemoteRefKind::Tag,
                    Some("v1"),
                    fbs::RemoteRefChangeKind::New,
                    Some(vec![]),
                    Some("dd")
                ),
                (
                    fbs::RemoteRefKind::Bookmark,
                    Some("x"),
                    fbs::RemoteRefChangeKind::Deleted,
                    Some(vec!["ee"]),
                    None,
                ),
            ]
        );
    }
}
