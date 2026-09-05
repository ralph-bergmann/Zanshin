// SPDX-License-Identifier: MIT

//! `zanshin_git_*` — the six `jj git` sync + remote-config wrappers (Story 9.5):
//! `import`, `export`, and `remote add`/`remove`/`rename`/`set-url`.
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the result into a
//! `FlatBuffers` `Envelope`. The handle is borrowed (not consumed). Mirrors the noun-module
//! split `file.rs` established: the two payload builders unique to this noun live here, the
//! shared `MutationResult` builder stays in `envelope.rs`, and the whole `MutateError`
//! taxonomy is mapped by `repo.rs::map_mutate_err` — a second mapper would be a second,
//! desyncable spelling of one mapping.
//!
//! Transport follows ADR-0001 per verb, not per module: `import`/`export` take no arguments
//! at all (the CLI's own arg surface is empty for both), `remote remove`/`rename` take only
//! required lone strings and therefore cross as `CString`s, and `remote add`/`set-url` are
//! composites with a distinguishably-ABSENT `push_url` (and, for set-url, `url`) and cross
//! as request BUFFERS.

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{GitExportFailure, GitExportResult, GitImportResult, GitRefUpdate, GitRefUpdateKind};

use crate::envelope::{
    build_mutation_result, catch, finish_envelope, invalid_request, missing_field, ok_mutation_result,
    reject_null_request, session_from_handle, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{cstr_to_string, vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

// ── Request-buffer readers ───────────────────────────────────────────────────
//
// Same discipline as `repo.rs`'s and `file.rs`'s readers: `data`/`len` describe a
// caller-owned buffer Dart builds and frees itself; Rust borrows it for the call only. Each
// reader builds its OWN byte slice in its own scope and returns an OWNED struct, so the
// unbounded lifetime `std::slice::from_raw_parts` produces provably cannot outlive the call.

/// Owned Rust form of a `GitRemoteAddRequest` buffer. `name`/`url` are REQUIRED (the CLI's
/// two positionals); `push_url` is `Option` because ABSENT means "push to the fetch URL",
/// which is git's own behaviour and the CLI's `--push-url` default.
struct GitRemoteAddRequestOwned {
    name: String,
    url: String,
    push_url: Option<String>,
}

/// Owned Rust form of a `GitRemoteSetUrlRequest` buffer. BOTH URLs are `Option`: absence
/// means "leave that side unchanged", and jj-lib cannot REMOVE a URL from a remote.
struct GitRemoteSetUrlRequestOwned {
    name: String,
    url: Option<String>,
    push_url: Option<String>,
}

/// Parse a `GitRemoteAddRequest` buffer into an owned [`GitRemoteAddRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `GitRemoteAddRequest` buffer.
/// - `jj.invalid_input` — `name` or `url` is ABSENT from the buffer.
fn read_git_remote_add_request(data: *const u8, len: usize) -> Result<GitRemoteAddRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::GitRemoteAddRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    Ok(GitRemoteAddRequestOwned {
        name: req.name().ok_or_else(|| missing_field("name"))?.to_owned(),
        url: req.url().ok_or_else(|| missing_field("url"))?.to_owned(),
        push_url: req.push_url().map(ToOwned::to_owned),
    })
}

/// Parse a `GitRemoteSetUrlRequest` buffer into an owned [`GitRemoteSetUrlRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `GitRemoteSetUrlRequest` buffer.
/// - `jj.invalid_input` — `name` is ABSENT from the buffer.
fn read_git_remote_set_url_request(data: *const u8, len: usize) -> Result<GitRemoteSetUrlRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::GitRemoteSetUrlRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    Ok(GitRemoteSetUrlRequestOwned {
        name: req.name().ok_or_else(|| missing_field("name"))?.to_owned(),
        url: req.url().map(ToOwned::to_owned),
        push_url: req.push_url().map(ToOwned::to_owned),
    })
}

// ── Payload builders ─────────────────────────────────────────────────────────

/// Map the crate's [`GitRefUpdateKind`] onto the wire enum; order is pinned by the schema.
fn ref_update_kind_to_fbs(k: GitRefUpdateKind) -> fbs::GitRefUpdateKind {
    match k {
        GitRefUpdateKind::New => fbs::GitRefUpdateKind::New,
        GitRefUpdateKind::Updated => fbs::GitRefUpdateKind::Updated,
        GitRefUpdateKind::Deleted => fbs::GitRefUpdateKind::Deleted,
    }
}

/// Build the `[GitRefUpdate]` vector into `b` and return its offset.
///
/// Children before parents (`FlatBuffers` requirement): each entry's two strings are built
/// before its table, and the vector comes after the loop.
fn build_ref_updates<'a>(
    b: &mut FlatBufferBuilder<'a>,
    updates: &[GitRefUpdate],
) -> flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<fbs::GitRefUpdate<'a>>>> {
    let offsets: Vec<_> = updates
        .iter()
        .map(|u| {
            let name = b.create_string(&u.name);
            let remote = b.create_string(&u.remote);
            fbs::GitRefUpdate::create(
                b,
                &fbs::GitRefUpdateArgs {
                    name: Some(name),
                    remote: Some(remote),
                    kind: ref_update_kind_to_fbs(u.kind),
                    tracked: u.tracked,
                },
            )
        })
        .collect();
    b.create_vector(&offsets)
}

/// Build the `[GitExportFailure]` vector into `b` and return its offset.
fn build_export_failures<'a>(
    b: &mut FlatBufferBuilder<'a>,
    failures: &[GitExportFailure],
) -> flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<fbs::GitExportFailure<'a>>>> {
    let offsets: Vec<_> = failures
        .iter()
        .map(|f| {
            let name = b.create_string(&f.name);
            let remote = b.create_string(&f.remote);
            let reason = b.create_string(&f.reason);
            fbs::GitExportFailure::create(
                b,
                &fbs::GitExportFailureArgs {
                    name: Some(name),
                    remote: Some(remote),
                    reason: Some(reason),
                },
            )
        })
        .collect();
    b.create_vector(&offsets)
}

/// Serialise a [`GitImportResult`] into a finished `Envelope<GitImportResult>` buffer.
fn git_import_result_to_envelope(r: &GitImportResult) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mutation = build_mutation_result(&mut b, &r.mutation);
    let bookmarks = build_ref_updates(&mut b, &r.changed_bookmarks);
    let tags = build_ref_updates(&mut b, &r.changed_tags);
    let abandoned_offs: Vec<_> = r.abandoned_change_ids.iter().map(|c| b.create_string(&c.0)).collect();
    let abandoned = b.create_vector(&abandoned_offs);
    let failed_offs: Vec<_> = r.failed_ref_names.iter().map(|n| b.create_string(n)).collect();
    let failed = b.create_vector(&failed_offs);
    let table = fbs::GitImportResult::create(
        &mut b,
        &fbs::GitImportResultArgs {
            mutation: Some(mutation),
            changed_bookmarks: Some(bookmarks),
            changed_tags: Some(tags),
            abandoned_change_ids: Some(abandoned),
            num_rewritten: r.num_rewritten,
            failed_ref_names: Some(failed),
        },
    );
    finish_envelope(b, fbs::Payload::GitImportResult, table.as_union_value())
}

/// Serialise a [`GitExportResult`] into a finished `Envelope<GitExportResult>` buffer.
fn git_export_result_to_envelope(r: &GitExportResult) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let mutation = build_mutation_result(&mut b, &r.mutation);
    let bookmarks = build_export_failures(&mut b, &r.failed_bookmarks);
    let tags = build_export_failures(&mut b, &r.failed_tags);
    let table = fbs::GitExportResult::create(
        &mut b,
        &fbs::GitExportResultArgs {
            mutation: Some(mutation),
            failed_bookmarks: Some(bookmarks),
            failed_tags: Some(tags),
        },
    );
    finish_envelope(b, fbs::Payload::GitExportResult, table.as_union_value())
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// Import the backing git repo's refs into jj's view, in the repo referenced by `handle` —
/// the CLI's `jj git import`.
///
/// Takes no arguments: the CLI's own `GitImportArgs` is empty. Unlike the CLI this is NOT
/// skipped in a colocated workspace — that skip exists because the CLI imports refs during
/// its implicit per-command snapshot, which Zanshin never performs (D2).
///
/// If nothing needed importing, NO operation is written and the nested
/// `MutationResult.new_op_id` carries the PRE-CALL op-log head. A ref that could not be
/// imported lands in `GitImportResult.failed_ref_names` and does NOT fail the call — the
/// CLI warns and exits 0.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `GitImportResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.not_a_git_repo` — the open workspace has no git backend; no `context`.
/// - `jj.config_error` — the repo's effective jj config, its
///   `revset-aliases."immutable_heads()"`, or `git.abandon-unreachable-commits` /
///   `git.record-synthetic-predecessors` could not be read, parsed, or resolved.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been
/// closed. `0` is detected and returned as `ffi.invalid_handle`. A stale non-zero handle is
/// undefined behaviour; the Dart worker's Model-A handle table (Story 3.9) makes a stale
/// handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_git_import(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_import", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.git_import().map_err(map_mutate_err)?;
        Ok(git_import_result_to_envelope(&result))
    });
    vec_into_token(buf)
}

/// Write jj's bookmarks and tags back to the backing git repo, in the repo referenced by
/// `handle` — the CLI's `jj git export`.
///
/// Takes no arguments, and — like `zanshin_git_import` — is NOT skipped in a colocated
/// workspace. Export never moves `@` and rewrites no commit.
///
/// If git already matched, NO operation is written and the nested
/// `MutationResult.new_op_id` carries the PRE-CALL op-log head. Refs that could not be
/// written land in `GitExportResult.failed_bookmarks` / `failed_tags` and do NOT fail the
/// call; the classic case is two bookmarks named `foo` and `foo/bar`, which git cannot both
/// hold.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `GitExportResult` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.not_a_git_repo` — the open workspace has no git backend; no `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_git_import`.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_git_export(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_export", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.git_export().map_err(map_mutate_err)?;
        Ok(git_export_result_to_envelope(&result))
    });
    vec_into_token(buf)
}

/// Register a new git remote in the repo referenced by `handle` — the CLI's
/// `jj git remote add`.
///
/// The arguments cross as a `GitRemoteAddRequest` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern): `push_url` must be distinguishably ABSENT, which is what means
/// "push to the fetch URL". Both URLs are passed to jj-lib VERBATIM — unlike the CLI, a
/// relative local path is not resolved against a process CWD.
///
/// The workspace is reloaded before returning, so `zanshin_remotes` on this SAME handle
/// reports the new remote immediately (jj-lib writes the git config file but leaves the
/// loaded backend's gix config cache stale).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// An error envelope from this verb does NOT mean "nothing happened": jj-lib writes the
/// git config file BEFORE the git-ref edits, and both happen before the transaction
/// commits, so a late refusal can leave the config already rewritten — and a failed
/// workspace reload is reported after the operation has already committed. Re-read
/// `zanshin_remotes` rather than assuming the pre-call state.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `GitRemoteAddRequest` buffer.
/// - `jj.invalid_input` — `name` or `url` is absent from the buffer, or `name` is the
///   reserved `git`, contains a slash, or is not a valid gix remote name.
/// - `jj.remote_exists` — `name` already has a configured remote; the name in `context`.
/// - `jj.not_a_git_repo` — the open workspace has no git backend; no `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_git_import`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and
/// owned/freed by Dart (`fbs.GitRemoteAddRequestObjectBuilder(...).toBytes()`); Rust only
/// borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_git_remote_add(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_remote_add", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let req = read_git_remote_add_request(data, len)?;
        let result = session
            .repo
            .git_remote_add(&req.name, &req.url, req.push_url.as_deref())
            .map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

/// Remove a git remote and forget its bookmarks, in the repo referenced by `handle` — the
/// CLI's `jj git remote remove`.
///
/// `name` is a required lone string, which ADR-0001 routes to a `CString`, not to
/// `FlatBuffers`. The workspace is reloaded before returning (see
/// `zanshin_git_remote_add`).
///
/// Removing the reserved remote `git` SUCCEEDS and updates the git config and refs, but
/// changes no jj view state — so NO operation is written and `MutationResult.new_op_id`
/// carries the PRE-CALL op-log head, exactly as in the CLI. Unlike the CLI,
/// `.jj/repo/config.toml` is not edited: a `[remotes.<name>]` section survives and a
/// `trunk()` alias pinned to this remote keeps naming it.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// An error envelope from this verb does NOT mean "nothing happened": jj-lib writes the
/// git config file BEFORE the git-ref edits, and both happen before the transaction
/// commits, so a late refusal can leave the config already rewritten — and a failed
/// workspace reload is reported after the operation has already committed. Re-read
/// `zanshin_remotes` rather than assuming the pre-call state.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `name` is a null pointer.
/// - `ffi.utf8_error` — `name` is not valid UTF-8.
/// - `jj.remote_not_found` — no such remote; the name in `context`.
/// - `jj.remote_nonstandard_config` — jj refuses to rewrite this remote's git config (a
///   remote ADDED with a push URL is exactly this case); the name in `context`.
/// - `jj.not_a_git_repo` — the open workspace has no git backend; no `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_git_import`.
/// `name` must be a NUL-terminated UTF-8 C string owned by the caller (Dart allocates via
/// `toNativeUtf8()` and frees with `calloc.free()` after this call returns — AR-P-5 inbound
/// rule). Rust only borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_git_remote_remove(handle: u64, name: *const core::ffi::c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_remote_remove", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        // SAFETY: name is a caller-owned NUL-terminated C string (Dart allocates + frees).
        let name = unsafe { cstr_to_string(name) }?;
        let result = session.repo.git_remote_remove(&name).map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

/// Rename a git remote in the repo referenced by `handle` — the CLI's
/// `jj git remote rename`.
///
/// Both names are required lone strings (ADR-0001 → `CString`). The workspace is reloaded
/// before returning (see `zanshin_git_remote_add`). Renaming FROM the reserved remote `git`
/// writes no operation, for the same reason removing it does not, and
/// `.jj/repo/config.toml` is not edited.
///
/// jj-lib validates `new_name` BEFORE it reports that `old_name` is missing, so renaming a
/// nonexistent remote to `git` reports the reserved-name refusal. That ordering is jj-lib's
/// own and is reproduced, not corrected.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// An error envelope from this verb does NOT mean "nothing happened": jj-lib writes the
/// git config file BEFORE the git-ref edits, and both happen before the transaction
/// commits, so a late refusal can leave the config already rewritten — and a failed
/// workspace reload is reported after the operation has already committed. Re-read
/// `zanshin_remotes` rather than assuming the pre-call state.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `old_name` or `new_name` is a null pointer.
/// - `ffi.utf8_error` — either name is not valid UTF-8.
/// - `jj.invalid_input` — `new_name` is the reserved `git`, contains a slash, or is not a
///   valid gix remote name.
/// - `jj.remote_not_found` — `old_name` has no configured remote; the name in `context`.
/// - `jj.remote_exists` — `new_name` is already taken; the name in `context`.
/// - `jj.remote_nonstandard_config` — `old_name`'s git config is not the plain
///   single-fetch-refspec shape jj knows how to rewrite; the name in `context`.
/// - `jj.not_a_git_repo` — the open workspace has no git backend; no `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_git_import`; both names follow the same caller-owned
/// C-string contract as `zanshin_git_remote_remove`'s `name`.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_git_remote_rename(
    handle: u64,
    old_name: *const core::ffi::c_char,
    new_name: *const core::ffi::c_char,
) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_remote_rename", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        // SAFETY: both are caller-owned NUL-terminated C strings (Dart allocates + frees).
        let old_name = unsafe { cstr_to_string(old_name) }?;
        // SAFETY: see above.
        let new_name = unsafe { cstr_to_string(new_name) }?;
        let result = session
            .repo
            .git_remote_rename(&old_name, &new_name)
            .map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

/// Re-point a git remote's fetch and/or push URL, in the repo referenced by `handle` — the
/// CLI's `jj git remote set-url`.
///
/// The arguments cross as a `GitRemoteSetUrlRequest` `FlatBuffers` request buffer: BOTH
/// URLs must be distinguishably ABSENT, and absence means "leave that side unchanged"
/// (jj-lib cannot REMOVE a URL). With both absent the call succeeds and does nothing, EVEN
/// for a remote that does not exist — jj-lib returns early before its own existence check,
/// and inventing a refusal there would be a divergence.
///
/// This verb NEVER writes an operation (jj-lib takes a `&Store`, and the CLI opens no
/// transaction either), so `MutationResult.new_op_id` is always the PRE-CALL op-log head.
/// The workspace is still reloaded, so `zanshin_remotes` on this same handle reports the new
/// URL.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// An error envelope from this verb does NOT mean "nothing happened": jj-lib writes the
/// git config file BEFORE the git-ref edits, and both happen before the transaction
/// commits, so a late refusal can leave the config already rewritten — and a failed
/// workspace reload is reported after the operation has already committed. Re-read
/// `zanshin_remotes` rather than assuming the pre-call state.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `GitRemoteSetUrlRequest` buffer.
/// - `jj.invalid_input` — `name` is absent from the buffer, or is the reserved `git`,
///   contains a slash, or is not a valid gix remote name.
/// - `jj.remote_not_found` — at least one URL was supplied and `name` has no configured
///   remote; the name in `context`.
/// - `jj.not_a_git_repo` — the open workspace has no git backend; no `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_git_import`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and
/// owned/freed by Dart (`fbs.GitRemoteSetUrlRequestObjectBuilder(...).toBytes()`); Rust only
/// borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_git_remote_set_url(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_remote_set_url", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let req = read_git_remote_set_url_request(data, len)?;
        let result = session
            .repo
            .git_remote_set_url(&req.name, req.url.as_deref(), req.push_url.as_deref())
            .map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use zanshin_jj::{
        ChangeId, GitExportFailure, GitExportResult, GitImportResult, GitRefUpdate, GitRefUpdateKind, MutationResult,
        OperationId,
    };

    use super::{git_export_result_to_envelope, git_import_result_to_envelope, ref_update_kind_to_fbs};
    use crate::fbs;

    fn verified(bytes: &[u8]) -> fbs::Envelope<'_> {
        fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass")
    }

    fn sample_mutation() -> MutationResult {
        MutationResult {
            new_op_id: OperationId("op99".to_owned()),
            new_change_ids: Vec::new(),
            abandoned_change_ids: Vec::new(),
            working_copy_change_id: ChangeId("qpvuntsm".to_owned()),
        }
    }

    #[test]
    fn git_import_result_to_envelope_carries_every_field() {
        let r = GitImportResult {
            mutation: sample_mutation(),
            changed_bookmarks: vec![GitRefUpdate {
                name: "main".to_owned(),
                remote: "origin".to_owned(),
                kind: GitRefUpdateKind::New,
                tracked: true,
            }],
            changed_tags: vec![GitRefUpdate {
                name: "v1".to_owned(),
                remote: "origin".to_owned(),
                kind: GitRefUpdateKind::Deleted,
                tracked: false,
            }],
            abandoned_change_ids: vec![ChangeId("rlvkpnrz".to_owned())],
            num_rewritten: 4,
            // Deliberately a reserved-namespace ref: that is the case the CLI hints about.
            failed_ref_names: vec!["refs/remotes/git/main".to_owned()],
        };

        let buf = git_import_result_to_envelope(&r);
        let env = verified(&buf);
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::GitImportResult);
        let p = env.data_as_git_import_result().expect("GitImportResult payload");
        let nested = p.mutation().expect("the nested MutationResult must be present");
        assert_eq!(nested.new_op_id(), Some("op99"));
        assert_eq!(nested.working_copy_change_id(), Some("qpvuntsm"));

        let bookmarks = p.changed_bookmarks().expect("changed_bookmarks present");
        assert_eq!(bookmarks.len(), 1);
        assert_eq!(bookmarks.get(0).name(), Some("main"));
        assert_eq!(bookmarks.get(0).remote(), Some("origin"));
        assert_eq!(bookmarks.get(0).kind(), fbs::GitRefUpdateKind::New);
        assert!(bookmarks.get(0).tracked());

        let tags = p.changed_tags().expect("changed_tags present");
        assert_eq!(tags.get(0).kind(), fbs::GitRefUpdateKind::Deleted);
        assert!(!tags.get(0).tracked());

        assert_eq!(
            p.abandoned_change_ids().map(|v| v.iter().collect::<Vec<_>>()),
            Some(vec!["rlvkpnrz"])
        );
        assert_eq!(p.num_rewritten(), 4);
        assert_eq!(
            p.failed_ref_names().map(|v| v.iter().collect::<Vec<_>>()),
            Some(vec!["refs/remotes/git/main"])
        );
    }

    /// `Updated` has no jj-side constructor these unit tests reach through a real import,
    /// so the mapper's third arm is pinned directly.
    #[test]
    fn ref_update_kind_to_fbs_maps_updated() {
        assert_eq!(
            ref_update_kind_to_fbs(GitRefUpdateKind::Updated),
            fbs::GitRefUpdateKind::Updated
        );
    }

    #[test]
    fn git_export_result_to_envelope_carries_the_flattened_reason() {
        let r = GitExportResult {
            mutation: sample_mutation(),
            failed_bookmarks: vec![GitExportFailure {
                name: "foo".to_owned(),
                remote: "git".to_owned(),
                reason: "Failed to set: reference already exists".to_owned(),
            }],
            failed_tags: Vec::new(),
        };

        let buf = git_export_result_to_envelope(&r);
        let env = verified(&buf);
        assert_eq!(env.data_type(), fbs::Payload::GitExportResult);
        let p = env.data_as_git_export_result().expect("GitExportResult payload");
        assert_eq!(
            p.mutation().and_then(|m| m.new_op_id()),
            Some("op99"),
            "the nested MutationResult must be present"
        );
        let failed = p.failed_bookmarks().expect("failed_bookmarks present");
        assert_eq!(failed.len(), 1);
        assert_eq!(failed.get(0).name(), Some("foo"));
        assert_eq!(failed.get(0).remote(), Some("git"));
        assert_eq!(
            failed.get(0).reason(),
            Some("Failed to set: reference already exists"),
            "the whole source chain rides the wire, not just 'Failed to set'"
        );
        assert!(p.failed_tags().is_some_and(|v| v.is_empty()));
    }

    #[test]
    fn empty_results_still_produce_ok_envelopes() {
        let import = GitImportResult {
            mutation: sample_mutation(),
            changed_bookmarks: Vec::new(),
            changed_tags: Vec::new(),
            abandoned_change_ids: Vec::new(),
            num_rewritten: 0,
            failed_ref_names: Vec::new(),
        };
        let import_buf = git_import_result_to_envelope(&import);
        let env = verified(&import_buf);
        assert!(env.ok(), "an empty import is a success, not an error");
        assert_eq!(env.data_type(), fbs::Payload::GitImportResult);

        let export = GitExportResult {
            mutation: sample_mutation(),
            failed_bookmarks: Vec::new(),
            failed_tags: Vec::new(),
        };
        let export_buf = git_export_result_to_envelope(&export);
        let env = verified(&export_buf);
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::GitExportResult);
    }
}
