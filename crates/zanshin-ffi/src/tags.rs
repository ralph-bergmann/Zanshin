// SPDX-License-Identifier: MIT

//! `zanshin_tags` and `zanshin_tag_*` — the tag list read and the tag MUTATION wrappers `set`,
//! `delete`, `track` and `untrack` (Story 9.59).
//!
//! The list calls `zanshin_jj::Repo::list_tags` and serialises its rows into a `Tags` payload;
//! the verbs call the matching `Repo` method and return the shipped `MutationResult` payload,
//! their `MutateError` mapped by `repo.rs::map_mutate_err`. Each verb's arguments cross as a
//! request BUFFER (ADR-0001): lists of strings and a distinguishably-ABSENT revision. The handle
//! is borrowed (not consumed).

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ChangeId, ConfigError, Tag, TagKind, ViewError};

use crate::bookmark_ops::strings;
use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, map_precondition_err, ok_mutation_result,
    precondition_envelope, reject_null_request, session_from_handle, FfiErrorObj, JJ_CONFIG_ERROR, JJ_JJ_LIB_ERROR,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

// ── Request-buffer readers ───────────────────────────────────────────────────
//
// Same discipline as `bookmark_ops.rs`'s readers: `data`/`len` describe a caller-owned buffer
// Dart builds and frees itself; Rust borrows it for the call only and returns OWNED values.

/// Owned Rust form of a `TagSetRequest` buffer; absent `names` are empty (the jj layer refuses an
/// empty list with its one message).
struct TagSetRequestOwned {
    names: Vec<String>,
    revision: Option<ChangeId>,
    allow_move: bool,
}

/// Parse a `TagSetRequest` buffer into an owned [`TagSetRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `TagSetRequest` buffer, or its `kind` is
///   not `TagSet`.
fn read_tag_set_request(data: *const u8, len: usize) -> Result<TagSetRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::TagSetRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::TagSet)?;
    Ok(TagSetRequestOwned {
        names: strings(req.names()),
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        allow_move: req.allow_move(),
    })
}

/// Parse a `TagDeleteRequest` buffer into its pattern list; absent `names` are empty.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `TagDeleteRequest` buffer, or its `kind`
///   is not `TagDelete`.
fn read_tag_delete_request(data: *const u8, len: usize) -> Result<Vec<String>, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::TagDeleteRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::TagDelete)?;
    Ok(strings(req.names()))
}

/// Parse a `TagTrackRequest` buffer tagged `kind` (`TagTrack` or `TagUntrack`) into its `(names,
/// remotes)`; absent vectors are empty. The tag is what keeps a track buffer from untracking.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `TagTrackRequest` buffer, or its `kind`
///   is not `kind`.
fn read_tag_track_request(
    data: *const u8,
    len: usize,
    kind: fbs::RequestKind,
) -> Result<(Vec<String>, Vec<String>), FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::TagTrackRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), kind)?;
    Ok((strings(req.names()), strings(req.remotes())))
}

// ── The list ─────────────────────────────────────────────────────────────────

/// Maps a [`ViewError`] of the tag list onto its registered code, the reason in `context`; a failed
/// pre-verb snapshot goes through the shared [`map_precondition_err`].
fn map_view_err(e: ViewError) -> FfiErrorObj {
    let (code, reason, hints) = match e {
        ViewError::Precondition(e) => return map_precondition_err(e),
        ViewError::Config(ConfigError::Load { reason, hints }) => (JJ_CONFIG_ERROR, reason, hints),
        ViewError::Backend(reason) => (JJ_JJ_LIB_ERROR, reason, Vec::new()),
    };
    FfiErrorObj {
        report: None,
        hints,
        code: code.to_owned(),
        context: Some(reason),
    }
}

/// Serialise `&[Tag]` into a finished `Envelope<Tags>` buffer. `target` is absent when the row's
/// target is absent; `remote_name` and `tracked` are written only for `Remote` rows.
fn tags_to_envelope(tags: &[Tag], report: &crate::envelope::CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mut offsets = Vec::with_capacity(tags.len());
    for tag in tags {
        let name = b.create_string(&tag.name);
        let target = tag.target.as_ref().map(|target| b.create_string(&target.0));
        let mut args = fbs::TagArgs {
            name: Some(name),
            target,
            kind: fbs::TagKind::Local,
            remote_name: None,
            conflicted: tag.conflicted,
            synced: tag.synced,
            tracked: false,
        };
        if let TagKind::Remote { remote_name, tracked } = &tag.kind {
            args.kind = fbs::TagKind::Remote;
            args.remote_name = Some(b.create_string(remote_name));
            args.tracked = *tracked;
        }
        offsets.push(fbs::Tag::create(&mut b, &args));
    }
    let vec = b.create_vector(&offsets);
    let payload = fbs::Tags::create(&mut b, &fbs::TagsArgs { tags: Some(vec) });
    finish_envelope(b, fbs::Payload::Tags, Some(payload.as_union_value()), report)
}

/// List the tags of the repo identified by `handle` — the rows `jj tag list --all-remotes` prints,
/// in its order, minus the rows of the Git-tracking remote `git` on a Git-backed repo (Story 9.59).
///
/// Rows: each local row (present, or deleted while still tracking a remote), then its tracked
/// remote rows, then the name's untracked remote rows, in name order; then sorted by
/// `ui.tag-list-sort-keys`. Returns a `FlatBuffers` `Envelope` carrying a `Tags` payload on
/// success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` or the borrow yields `None`.
/// - `jj.config_error` — the pre-verb snapshot (Story 9.26) found the effective jj config
///   unreadable or a knob it reads wrongly typed (the key in `context`), or
///   `ui.tag-list-sort-keys` is not an array of the CLI's key names.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
/// - `jj.jj_lib_error` — an unclassified jj-lib error; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_tags(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_tags", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let tags = session.repo.list_tags();
        precondition_envelope(&mut session.repo, tags, map_view_err, |tags, p| {
            tags_to_envelope(tags, p)
        })
    });
    vec_into_token(buf)
}

// ── The verbs ────────────────────────────────────────────────────────────────

/// Create or move local tags, in the repo referenced by `handle` — the CLI's `jj tag set` (Story
/// 9.59).
///
/// The arguments cross as a `TagSetRequest` `FlatBuffers` request buffer: `names` are DECODED
/// names; `revision` ABSENT is the CLI's `-r` default `@`, present a jj reverse-hex CHANGE ID;
/// `allow_move` is `--allow-move`. Per name in argument order, fail-fast: a name that is a local tag
/// already refuses without `allow_move`, and nothing is written. Warning: `jj.tag_target_empty`.
/// Setting every name where it points writes no operation. Op-log description `set tag {names} to
/// commit {id}`. Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `TagSetRequest` buffer, or its `kind` is
///   not `TagSet`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — `names` is empty (or absent) or holds an empty name, before the snapshot;
///   or a present tag without `allow_move` ("Refusing to move tag: {name}", the hint "Use
///   --allow-move to update existing tags." in `hints`).
/// - `jj.change_not_found` — `revision` is malformed, unknown or hidden; the id in `context`.
/// - `jj.revset_resolution_error` — no `@` for `revision`'s default; `revision` is an ambiguous
///   change-id prefix or a divergent change (the CLI's hints in `hints`), or
///   `revsets.short-prefixes` fails to resolve.
/// - `jj.config_error` — the pre-verb refresh or snapshot faults as for `zanshin_bookmark_move`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_tags`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.TagSetRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration of
/// the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_tag_set(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_tag_set", handle);
    let buf = catch(|| {
        let req = read_tag_set_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.tag_set(&req.names, req.revision.as_ref(), req.allow_move);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Delete local tags, in the repo referenced by `handle` — the CLI's `jj tag delete` (Story 9.59).
///
/// The arguments cross as a `TagDeleteRequest` `FlatBuffers` request buffer: `names` are string
/// PATTERNS passed through verbatim (a BARE one is a GLOB), unioned. A tracked `name@remote` stays,
/// so the next push sends the deletion. Matching nothing writes no operation. Warning:
/// `jj.tag_names_unmatched`. Op-log description `delete tag {names}`. Returns a `FlatBuffers`
/// `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `TagDeleteRequest` buffer, or its `kind`
///   is not `TagDelete`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — `names` is empty (or absent), before the snapshot; or a pattern does not
///   parse, after it (jj-lib's reason in `context`).
/// - `jj.config_error` — the pre-verb refresh or snapshot faults as for `zanshin_bookmark_move`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_tags`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.TagDeleteRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_tag_delete(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_tag_delete", handle);
    let buf = catch(|| {
        let names = read_tag_delete_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.tag_delete(&names);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Start tracking remote tags, in the repo referenced by `handle` — the CLI's `jj tag track`
/// (Story 9.59).
///
/// The arguments cross as a `TagTrackRequest` `FlatBuffers` request buffer tagged `TagTrack`:
/// `names` are the CLI's `TAG[@REMOTE]` texts passed through — a `name@remote` symbol names one
/// remote tag exactly, any other text is a string pattern (a BARE one a GLOB) matched on the
/// `remotes` (remote-name PATTERNS, `--remote`; absent/empty = every remote but `git` on a
/// Git-backed repo). Tracking merges the remote target into the local tag. Nothing to track writes
/// no operation. Warnings: `jj.remote_tags_unmatched` or `jj.tag_names_unmatched` +
/// `jj.tag_remotes_unmatched`, then `jj.tag_already_tracked`. Op-log description `track remote tag
/// {symbols}`. Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `TagTrackRequest` buffer, or its `kind`
///   is not `TagTrack`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — `names` is empty (or absent), before the snapshot; after it, a name or
///   remote that does not parse, patterns mixed with symbols ("Cannot specify both <tag> patterns
///   and <tag>@<remote> symbols"), or `remotes` with symbols ("--remote cannot be used with
///   <tag>@<remote> symbols").
/// - `jj.config_error` — the pre-verb refresh or snapshot faults as for `zanshin_bookmark_move`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_tags`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.TagTrackRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_tag_track(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_tag_track", handle);
    let buf = catch(|| {
        let (names, remotes) = read_tag_track_request(data, len, fbs::RequestKind::TagTrack)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.tag_track(&names, &remotes);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Stop tracking remote tags, in the repo referenced by `handle` — the CLI's `jj tag untrack`
/// (Story 9.59).
///
/// The arguments cross as a `TagTrackRequest` `FlatBuffers` request buffer tagged `TagUntrack`;
/// `names` and `remotes` as `zanshin_tag_track`'s. The matched tracked refs are untracked — the
/// local tag stays; a `git` ref warns and stays tracked (the CLI's refusal). Nothing to untrack
/// writes no operation. Warnings: `jj.remote_tags_unmatched` or `jj.tag_names_unmatched` +
/// `jj.tag_remotes_unmatched`, then `jj.tag_git_tracking_untrack` and `jj.tag_not_tracked`. Op-log
/// description `untrack remote tag {symbols}`. Returns a `FlatBuffers` `Envelope` carrying a
/// `MutationResult` payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `TagTrackRequest` buffer, or its `kind`
///   is not `TagUntrack`.
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `jj.invalid_input` — as for `zanshin_tag_track`.
/// - `jj.config_error` — the pre-verb refresh or snapshot faults as for `zanshin_bookmark_move`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle contract as `zanshin_tags`.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.TagTrackRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_tag_untrack(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_tag_untrack", handle);
    let buf = catch(|| {
        let (names, remotes) = read_tag_track_request(data, len, fbs::RequestKind::TagUntrack)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.tag_untrack(&names, &remotes);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use zanshin_jj::{ChangeId, ConfigError, Tag, TagKind, ViewError};

    use super::{map_view_err, tags_to_envelope};
    use crate::fbs;
    use crate::{JJ_CONFIG_ERROR, JJ_JJ_LIB_ERROR};

    /// Both kinds round-trip through the typed accessors; a Local row writes no remote fields and
    /// an absent target stays absent.
    #[test]
    fn tags_to_envelope_roundtrips_both_kinds() {
        let local = Tag {
            name: "v1".to_owned(),
            target: None,
            conflicted: false,
            synced: true,
            kind: TagKind::Local,
        };
        let remote = Tag {
            name: "v2".to_owned(),
            target: Some(ChangeId("qpmxrolk".to_owned())),
            conflicted: true,
            synced: false,
            kind: TagKind::Remote {
                remote_name: "origin".to_owned(),
                tracked: true,
            },
        };
        let buf = tags_to_envelope(&[local, remote], &crate::envelope::CallReport::default());
        let env = fb_root::<fbs::Envelope>(&buf).expect("FlatBuffers Verifier must pass");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::Tags);
        let tags = env.data_as_tags().expect("Tags").tags().expect("tags present");
        assert_eq!(tags.len(), 2);
        let first = tags.get(0);
        assert_eq!(
            (first.name(), first.target(), first.kind(), first.remote_name()),
            (Some("v1"), None, fbs::TagKind::Local, None)
        );
        assert!(first.synced() && !first.conflicted() && !first.tracked());
        let second = tags.get(1);
        assert_eq!(
            (second.name(), second.target(), second.kind(), second.remote_name()),
            (Some("v2"), Some("qpmxrolk"), fbs::TagKind::Remote, Some("origin"))
        );
        assert!(!second.synced() && second.conflicted() && second.tracked());
    }

    #[test]
    fn map_view_err_maps_config_and_backend() {
        let config = map_view_err(ViewError::Config(ConfigError::Load {
            reason: "c".into(),
            hints: vec!["Check the config file: /r/config.toml".into()],
        }));
        assert_eq!(
            (config.code.as_str(), config.context.as_deref()),
            (JJ_CONFIG_ERROR, Some("c"))
        );
        assert_eq!(config.hints, ["Check the config file: /r/config.toml"]);
        let backend = map_view_err(ViewError::Backend("b".into()));
        assert_eq!(
            (backend.code.as_str(), backend.context.as_deref()),
            (JJ_JJ_LIB_ERROR, Some("b"))
        );
        let precondition = map_view_err(ViewError::Precondition(zanshin_jj::PreconditionError::Backend(
            "p".into(),
        )));
        assert_eq!(precondition.code, JJ_JJ_LIB_ERROR);
    }
}
