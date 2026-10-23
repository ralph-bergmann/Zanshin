// SPDX-License-Identifier: MIT

//! `zanshin_metaedit` / `zanshin_duplicate` / `zanshin_fix` — the CLI's `jj metaedit`, `jj
//! duplicate` and `jj fix` (Story 9.9).
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises its result into a
//! `FlatBuffers` `Envelope`: the shared `MutationResult` for metaedit and duplicate, a
//! `FixResult` for fix. The arguments cross as request BUFFERS (ADR-0001 composite-input
//! pattern): `MetaeditRequest`, `DuplicateRequest` and `FixRequest`. The handle is borrowed, never
//! consumed. Every call runs the pre-verb snapshot (Story 9.26) unless clap's rules refuse it first,
//! so the envelope carries the precondition report and the call's warnings.

use flatbuffers::{ForwardsUOffset, Vector, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ChangeId, DuplicateOptions, FixOptions, MetaeditOptions};

use crate::envelope::{
    catch, expect_request_kind, invalid_request, ok_fix_result, ok_mutation_result, precondition_envelope,
    reject_null_request, session_from_handle, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

// ── Request-buffer readers ───────────────────────────────────────────────────
//
// Same discipline as `rebase.rs`'s readers: `data`/`len` describe a caller-owned buffer Dart builds
// and frees itself; Rust borrows it for the call only, and each reader returns OWNED values.

/// A string vector as change ids; ABSENT is empty — the flag not given.
fn change_ids(v: Option<Vector<'_, ForwardsUOffset<&str>>>) -> Vec<ChangeId> {
    v.map(|v| v.iter().map(|s| ChangeId(s.to_owned())).collect())
        .unwrap_or_default()
}

/// A string vector as owned strings; ABSENT is empty.
fn strings(v: Option<Vector<'_, ForwardsUOffset<&str>>>) -> Vec<String> {
    v.map(|v| v.iter().map(str::to_owned).collect()).unwrap_or_default()
}

/// The verified root of a caller-owned request buffer.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `T` buffer.
fn root<'a, T>(data: *const u8, len: usize) -> Result<T::Inner, FfiErrorObj>
where
    T: flatbuffers::Follow<'a> + flatbuffers::Verifiable + 'a,
{
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    flatbuffers::root_with_opts::<T>(&VerifierOptions::default(), bytes).map_err(|e| invalid_request(&e))
}

/// Parse a `MetaeditRequest` buffer into owned [`MetaeditOptions`]: an ABSENT `revisions` is
/// empty, an ABSENT `message` / `author` / `author_timestamp` is not given.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `MetaeditRequest` buffer, or its `kind`
///   is not `Metaedit`.
fn read_metaedit_request(data: *const u8, len: usize) -> Result<MetaeditOptions, FfiErrorObj> {
    let req = root::<fbs::MetaeditRequest>(data, len)?;
    expect_request_kind(req.kind(), fbs::RequestKind::Metaedit)?;
    Ok(MetaeditOptions {
        revisions: change_ids(req.revisions()),
        update_change_id: req.update_change_id(),
        message: req.message().map(|m| m.iter().map(str::to_owned).collect()),
        update_author_timestamp: req.update_author_timestamp(),
        update_author: req.update_author(),
        author: req.author().map(str::to_owned),
        author_timestamp: req.author_timestamp().map(str::to_owned),
        force_rewrite: req.force_rewrite(),
    })
}

/// Parse a `DuplicateRequest` buffer into owned [`DuplicateOptions`]; an ABSENT vector is empty.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `DuplicateRequest` buffer, or its `kind`
///   is not `Duplicate`.
fn read_duplicate_request(data: *const u8, len: usize) -> Result<DuplicateOptions, FfiErrorObj> {
    let req = root::<fbs::DuplicateRequest>(data, len)?;
    expect_request_kind(req.kind(), fbs::RequestKind::Duplicate)?;
    Ok(DuplicateOptions {
        revisions: change_ids(req.revisions()),
        onto: change_ids(req.onto()),
        insert_after: change_ids(req.insert_after()),
        insert_before: change_ids(req.insert_before()),
    })
}

/// Parse a `FixRequest` buffer into owned [`FixOptions`]; an ABSENT vector is empty.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FixRequest` buffer, or its `kind` is
///   not `Fix`.
fn read_fix_request(data: *const u8, len: usize) -> Result<FixOptions, FfiErrorObj> {
    let req = root::<fbs::FixRequest>(data, len)?;
    expect_request_kind(req.kind(), fbs::RequestKind::Fix)?;
    Ok(FixOptions {
        source: change_ids(req.source()),
        paths: strings(req.paths()),
        include_unchanged_files: req.include_unchanged_files(),
        all_lines: req.all_lines(),
    })
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// Modify revisions' metadata without changing their content, in the repo identified by
/// `handle` — the CLI's `jj metaedit` (Story 9.9).
///
/// The arguments cross as a `MetaeditRequest` `FlatBuffers` request buffer, one field per CLI
/// flag: `revisions` (ABSENT or EMPTY = `@`), `message` (the `-m` paragraphs; ABSENT = no `-m`),
/// `author` (`Name <email>`) or `update_author`, `author_timestamp` (RFC 2822 / RFC 3339) or
/// `update_author_timestamp`, `update_change_id`, `force_rewrite`. A revision is rewritten only
/// when one of its metadata changes (or `force_rewrite`); its descendants are reparented. A call
/// that rewrites nothing writes NO operation and `MutationResult.new_op_id` carries the PRE-CALL
/// head; otherwise the operation is the CLI's `edit commit metadata for commit <hex>` or `… <hex>
/// and <n> more`. The working copy is snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success: the change
/// ids `update_change_id` minted in `new_change_ids`.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `MetaeditRequest` buffer, or its `kind`
///   is not `Metaedit`.
/// - `jj.invalid_input` — clap's refusals, before the snapshot (nothing written, no
///   `precondition`): a malformed `author` or `author_timestamp` (``invalid value '<v>' for
///   '--author <AUTHOR>': Invalid author string``, ``… for '--author-timestamp
///   <AUTHOR_TIMESTAMP>': <reason>``), `author` with `update_author`, `author_timestamp` with
///   `update_author_timestamp`; detail in `context`.
/// - `jj.change_not_found` — an id is malformed, carried by no VISIBLE commit, or divergent; the id
///   in `context`.
/// - `jj.revset_resolution_error` — the default `@` in a workspace with no working-copy commit.
/// - `jj.immutable` — a revision is immutable (the root commit among them); its hex commit id in
///   `context`.
/// - `jj.config_error` — the config or its `immutable_heads()` alias does not read or resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.MetaeditRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration
/// of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_metaedit(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_metaedit", handle);
    let buf = catch(|| {
        let options = read_metaedit_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.metaedit(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Create new changes with the same content as existing ones, in the repo identified by `handle`
/// — the CLI's `jj duplicate` (Story 9.9).
///
/// The arguments cross as a `DuplicateRequest` `FlatBuffers` request buffer: `revisions` (ABSENT
/// or EMPTY = `@`) and the location — `onto` (`-o`) or `insert_after` / `insert_before` (`-A` /
/// `-B`); none = each duplicate onto its original's parents. A duplicate that lands among its
/// original's descendants or ancestors warns `jj.duplicate_as_own_descendant` /
/// `jj.duplicate_as_own_ancestor`. Each duplicate is described with `templates.duplicate_description`
/// rendered on its original. The operation is the CLI's `duplicate <n> commit(s)`. The working copy
/// is snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `MutationResult` payload on success: the
/// duplicates' change ids in `new_change_ids`, in jj-lib's duplication order.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `DuplicateRequest` buffer, or its `kind`
///   is not `Duplicate`.
/// - `jj.invalid_input` — `onto` with `insert_after`/`insert_before` (clap's refusal: before the
///   snapshot, nothing written, no `precondition`); "Cannot duplicate the root commit"; a location
///   that would create a loop or resolves no parent; a merge with the root commit as a parent in a
///   Git repo; detail in `context`.
/// - `jj.change_not_found` — an id is malformed, carried by no VISIBLE commit, or divergent; the id
///   in `context`.
/// - `jj.revset_resolution_error` — the default `@` in a workspace with no working-copy commit.
/// - `jj.immutable` — a child `insert_after`/`insert_before` would rewrite is immutable.
/// - `jj.config_error` — the duplicate-description template setting is not a string or does not
///   parse, or the config or its `immutable_heads()` alias does not read or resolve.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.DuplicateRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_duplicate(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_duplicate", handle);
    let buf = catch(|| {
        let options = read_duplicate_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.duplicate(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_mutation_result)
    });
    vec_into_token(buf)
}

/// Update files with formatting fixes or other changes, in the repo identified by `handle` — the
/// CLI's `jj fix` (Story 9.9).
///
/// The arguments cross as a `FixRequest` `FlatBuffers` request buffer: `source` (`-s`; ABSENT or
/// EMPTY = the `revsets.fix` setting, jj's default `reachable(@, mutable())`), `paths` (PREFIXES;
/// ABSENT or EMPTY = every path), `include_unchanged_files`, `all_lines`. The files of the sources
/// and their descendants run through the `fix.tools` that match them; a tool that cannot start or
/// exits non-zero is skipped and warns (`jj.fix_tool_start_failed`, `jj.fix_tool_failed`). A
/// deprecated `fix.tools.<name>.line-range-arg` is migrated and warns `jj.config_deprecated`. A
/// call that fixes nothing writes NO operation and `FixResult.mutation.new_op_id` carries the
/// PRE-CALL head; otherwise the operation is the CLI's `fixed <n> commits`. The working copy is
/// snapshotted first (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `FixResult` payload on success: the nested
/// `MutationResult`, the fixed and checked commit counts, and what the tools wrote to stderr.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FixRequest` buffer, or its `kind` is not
///   `Fix`.
/// - `jj.config_error` — no fix tool is configured, none is enabled, one sets
///   `run-tool-if-zero-line-ranges` without `line-range-args`, a tool entry or the fix revset
///   setting has the wrong type, or the config or its `immutable_heads()` alias does not read or
///   resolve.
/// - `jj.invalid_input` — a pattern does not parse ("Failed to parse fileset: <kind>" with the CLI's
///   `Caused by:` lines in `context`, its hint in `hints`), or a path is not a valid repo path.
/// - `jj.change_not_found` — a source id is malformed, carried by no VISIBLE commit, or divergent;
///   the id in `context`.
/// - `jj.revset_parse_error` / `jj.revset_resolution_error` — the fix revset setting (the default
///   sources) does not parse or resolve.
/// - `jj.immutable` — a source is immutable; its hex commit id in `context`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.FixRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration of
/// the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_fix(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_fix", handle);
    let buf = catch(|| {
        let options = read_fix_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.fix(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_fix_result)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use zanshin_jj::ChangeId;

    use super::{read_duplicate_request, read_fix_request, read_metaedit_request};
    use crate::envelope::{FFI_INVALID_ARGUMENT, FFI_NULL_POINTER};
    use crate::fbs;

    fn id(s: &str) -> ChangeId {
        ChangeId(s.to_owned())
    }

    fn metaedit_request(full: bool) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let args = if full {
            let r = b.create_string("r");
            let revisions = Some(b.create_vector(&[r]));
            let (p1, p2) = (b.create_string("one"), b.create_string("two"));
            let message = Some(b.create_vector(&[p1, p2]));
            fbs::MetaeditRequestArgs {
                kind: fbs::RequestKind::Metaedit,
                revisions,
                update_change_id: true,
                message,
                update_author_timestamp: true,
                update_author: true,
                author: Some(b.create_string("Foo <foo@bar>")),
                author_timestamp: Some(b.create_string("2000-01-23T01:23:45-08:00")),
                force_rewrite: true,
            }
        } else {
            fbs::MetaeditRequestArgs {
                kind: fbs::RequestKind::Metaedit,
                ..fbs::MetaeditRequestArgs::default()
            }
        };
        let req = fbs::MetaeditRequest::create(&mut b, &args);
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    /// Absent fields are "not given"; present ones cross unchanged, field for field — an empty
    /// `message` vector is `Some(vec![])`, not `None`.
    #[test]
    fn the_metaedit_reader_carries_every_field() {
        let bytes = metaedit_request(true);
        let options = read_metaedit_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert_eq!(options.revisions, [id("r")]);
        assert_eq!(options.message, Some(vec!["one".to_owned(), "two".to_owned()]));
        assert_eq!(options.author.as_deref(), Some("Foo <foo@bar>"));
        assert_eq!(options.author_timestamp.as_deref(), Some("2000-01-23T01:23:45-08:00"));
        assert!(
            options.update_change_id
                && options.update_author_timestamp
                && options.update_author
                && options.force_rewrite
        );

        let bytes = metaedit_request(false);
        let options = read_metaedit_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert_eq!(options, zanshin_jj::MetaeditOptions::default());

        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
        let message = Some(b.create_vector::<flatbuffers::WIPOffset<&str>>(&[]));
        let req = fbs::MetaeditRequest::create(
            &mut b,
            &fbs::MetaeditRequestArgs {
                kind: fbs::RequestKind::Metaedit,
                message,
                ..fbs::MetaeditRequestArgs::default()
            },
        );
        b.finish(req, None);
        let bytes = b.finished_data().to_vec();
        let options = read_metaedit_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert_eq!(options.message, Some(Vec::new()), "present but empty is `-m` given");
    }

    #[test]
    fn the_duplicate_and_fix_readers_carry_every_field() {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let mut one = |s: &str| {
            let s = b.create_string(s);
            b.create_vector(&[s])
        };
        let (revisions, onto, after, before) = (one("r"), one("o"), one("a"), one("b"));
        let req = fbs::DuplicateRequest::create(
            &mut b,
            &fbs::DuplicateRequestArgs {
                kind: fbs::RequestKind::Duplicate,
                revisions: Some(revisions),
                onto: Some(onto),
                insert_after: Some(after),
                insert_before: Some(before),
            },
        );
        b.finish(req, None);
        let bytes = b.finished_data().to_vec();
        let options = read_duplicate_request(bytes.as_ptr(), bytes.len()).expect("valid");
        assert_eq!(
            (
                options.revisions,
                options.onto,
                options.insert_after,
                options.insert_before
            ),
            (vec![id("r")], vec![id("o")], vec![id("a")], vec![id("b")])
        );

        for flags in [[true, false], [false, true]] {
            let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
            let mut one = |s: &str| {
                let s = b.create_string(s);
                b.create_vector(&[s])
            };
            let (source, paths) = (one("s"), one("p/"));
            let req = fbs::FixRequest::create(
                &mut b,
                &fbs::FixRequestArgs {
                    kind: fbs::RequestKind::Fix,
                    source: Some(source),
                    paths: Some(paths),
                    include_unchanged_files: flags[0],
                    all_lines: flags[1],
                },
            );
            b.finish(req, None);
            let bytes = b.finished_data().to_vec();
            let options = read_fix_request(bytes.as_ptr(), bytes.len()).expect("valid");
            assert_eq!(options.source, [id("s")]);
            assert_eq!(options.paths, ["p/"]);
            assert_eq!([options.include_unchanged_files, options.all_lines], flags);
        }
    }

    /// A buffer built for another wrapper, a buffer that does not verify, and a null pointer are
    /// refused before anything else is read.
    #[test]
    fn the_readers_refuse_a_wrong_tag_garbage_and_null() {
        let metaedit = metaedit_request(false);
        let err = read_duplicate_request(metaedit.as_ptr(), metaedit.len()).expect_err("metaedit buffer");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
        let err = read_fix_request(metaedit.as_ptr(), metaedit.len()).expect_err("metaedit buffer");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
        let req = fbs::FixRequest::create(
            &mut b,
            &fbs::FixRequestArgs {
                kind: fbs::RequestKind::Fix,
                ..fbs::FixRequestArgs::default()
            },
        );
        b.finish(req, None);
        let fix = b.finished_data().to_vec();
        let err = read_metaedit_request(fix.as_ptr(), fix.len()).expect_err("fix buffer");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);

        let garbage = [0xff_u8; 3];
        for err in [
            read_metaedit_request(garbage.as_ptr(), garbage.len()).expect_err("garbage"),
            read_duplicate_request(garbage.as_ptr(), garbage.len()).expect_err("garbage"),
            read_fix_request(garbage.as_ptr(), garbage.len()).expect_err("garbage"),
        ] {
            assert_eq!(err.code, FFI_INVALID_ARGUMENT);
        }
        let err = read_fix_request(std::ptr::null(), 0).expect_err("null");
        assert_eq!(err.code, FFI_NULL_POINTER);
    }
}
