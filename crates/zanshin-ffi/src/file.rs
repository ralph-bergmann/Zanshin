// SPDX-License-Identifier: MIT

//! `zanshin_file_*` — the four `jj file` READ wrappers (Story 9.4): `list`, `show`,
//! `annotate`, `search`.
//!
//! Each calls the matching `zanshin_jj::Repo` method and serialises the result into a
//! `FlatBuffers` `Envelope`. The handle is borrowed (not consumed), and none of the four
//! writes an operation — not even on a refusal.
//!
//! All four take a request BUFFER rather than C strings: each is a composite whose
//! `revision` must be distinguishably ABSENT (that absence is what applies the CLI's own
//! `@` default), which is exactly the ADR-0001 composite-input case Story 9.3 established.

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{AnnotationLine, ChangeId, FileContents, FileEntry, FileError, FileSearch, FileType};

use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, missing_field, reject_null_request,
    session_from_handle, FfiErrorObj, JJ_CHANGE_NOT_FOUND, JJ_CONFIG_ERROR, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR,
    JJ_NOT_A_FILE, JJ_PATH_NOT_FOUND,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};

/// Maps a [`FileError`] onto its AR-P-4 code; user data always rides in `context`.
fn map_file_err(e: FileError) -> FfiErrorObj {
    let (code, context) = match e {
        FileError::ChangeNotFound { id } => (JJ_CHANGE_NOT_FOUND, id),
        FileError::PathNotFound { path } => (JJ_PATH_NOT_FOUND, path),
        FileError::NotAFile { path } => (JJ_NOT_A_FILE, path),
        FileError::InvalidInput { reason } => (JJ_INVALID_INPUT, reason),
        FileError::Config { reason } => (JJ_CONFIG_ERROR, reason),
        FileError::Backend(reason) => (JJ_JJ_LIB_ERROR, reason),
    };
    FfiErrorObj {
        code: code.to_owned(),
        context: Some(context),
    }
}

// ── Request-buffer readers ───────────────────────────────────────────────────
//
// Same discipline as `repo.rs`'s readers: `data`/`len` describe a caller-owned buffer Dart
// builds and frees itself; Rust borrows it for the call only. Each reader builds its OWN
// byte slice in its own scope and returns an OWNED struct, so the unbounded lifetime
// `std::slice::from_raw_parts` produces provably cannot outlive the call. The null check
// and the invalid-buffer error shape are shared with `repo.rs` via `envelope.rs`.

/// Owned Rust form of a `FileListRequest` or `FileShowRequest` buffer — the two are
/// shape-identical, and this is the shape, not either table. `revision` is `Option`: ABSENT
/// is the wire form of "the user did not supply it", which applies the CLI's own `@`
/// default.
struct RevisionAndPathsOwned {
    revision: Option<ChangeId>,
    paths: Vec<String>,
}

/// Owned Rust form of a `FileAnnotateRequest` buffer. `path` is a single PLAIN path and is
/// REQUIRED: an absent field is refused with `jj.invalid_input` before the call reaches
/// `Repo::file_annotate`.
struct FileAnnotateRequestOwned {
    revision: Option<ChangeId>,
    path: String,
}

/// Owned Rust form of a `FileSearchRequest` buffer.
struct FileSearchRequestOwned {
    revision: Option<ChangeId>,
    pattern: String,
    paths: Vec<String>,
    name_only: bool,
}

/// Parse a `FileListRequest` buffer into an owned [`RevisionAndPathsOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileListRequest` buffer, or its
///   `kind` is not `FileList`.
fn read_file_list_request(data: *const u8, len: usize) -> Result<RevisionAndPathsOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::FileListRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::FileList)?;
    Ok(RevisionAndPathsOwned {
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
    })
}

/// Parse a `FileShowRequest` buffer. Shape-identical to `FileListRequest`, but a SEPARATE
/// table (and a separate reader) so the two can diverge without a silent wire break.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileShowRequest` buffer, or its
///   `kind` is not `FileShow`.
fn read_file_show_request(data: *const u8, len: usize) -> Result<RevisionAndPathsOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::FileShowRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::FileShow)?;
    Ok(RevisionAndPathsOwned {
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
    })
}

/// Parse a `FileAnnotateRequest` buffer into an owned [`FileAnnotateRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileAnnotateRequest` buffer, or its
///   `kind` is not `FileAnnotate`.
/// - `jj.invalid_input` — `path` is ABSENT from the buffer (the CLI's positional `path` is
///   required); an explicitly empty string is a value and is passed through.
fn read_file_annotate_request(data: *const u8, len: usize) -> Result<FileAnnotateRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::FileAnnotateRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::FileAnnotate)?;
    Ok(FileAnnotateRequestOwned {
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        path: req.path().ok_or_else(|| missing_field("path"))?.to_owned(),
    })
}

/// Parse a `FileSearchRequest` buffer into an owned [`FileSearchRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileSearchRequest` buffer, or its
///   `kind` is not `FileSearch`.
/// - `jj.invalid_input` — `pattern` is ABSENT from the buffer (the CLI marks `-p/--pattern`
///   `required = true`); an explicitly empty string is a value and is passed through, where
///   it is the empty regex and matches every line.
fn read_file_search_request(data: *const u8, len: usize) -> Result<FileSearchRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::FileSearchRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::FileSearch)?;
    Ok(FileSearchRequestOwned {
        revision: req.revision().map(|s| ChangeId(s.to_owned())),
        pattern: req.pattern().ok_or_else(|| missing_field("pattern"))?.to_owned(),
        paths: req.paths().into_iter().flatten().map(ToOwned::to_owned).collect(),
        name_only: req.name_only(),
    })
}

// ── Payload builders ─────────────────────────────────────────────────────────

/// Map the crate's [`FileType`] onto the wire enum; order is pinned by the schema comment.
fn file_type_to_fbs(t: FileType) -> fbs::FileType {
    match t {
        FileType::File => fbs::FileType::File,
        FileType::Symlink => fbs::FileType::Symlink,
        FileType::Tree => fbs::FileType::Tree,
        FileType::GitSubmodule => fbs::FileType::GitSubmodule,
        FileType::Conflict => fbs::FileType::Conflict,
    }
}

/// Serialise `&[FileEntry]` into a finished `Envelope<FileList>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): each entry's string is built before
/// its table, and the vector and `FileList` table come after the loop.
fn file_list_to_envelope(entries: &[FileEntry]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let offsets: Vec<_> = entries
        .iter()
        .map(|e| {
            let path = b.create_string(&e.path);
            fbs::FileEntry::create(
                &mut b,
                &fbs::FileEntryArgs {
                    path: Some(path),
                    file_type: file_type_to_fbs(e.file_type),
                    executable: e.executable,
                    conflict_side_count: e.conflict_side_count,
                },
            )
        })
        .collect();
    let vec = b.create_vector(&offsets);
    let list = fbs::FileList::create(&mut b, &fbs::FileListArgs { entries: Some(vec) });
    finish_envelope(b, fbs::Payload::FileList, list.as_union_value())
}

/// Serialise a [`FileContents`] into a finished `Envelope<FileContents>` buffer.
fn file_contents_to_envelope(contents: &FileContents) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(2048);
    let file_offs: Vec<_> = contents
        .files
        .iter()
        .map(|f| {
            let path = b.create_string(&f.path);
            let content = b.create_vector(&f.content);
            fbs::ShownFile::create(
                &mut b,
                &fbs::ShownFileArgs {
                    path: Some(path),
                    content: Some(content),
                    conflict: f.conflict,
                },
            )
        })
        .collect();
    let files = b.create_vector(&file_offs);
    let skipped_offs: Vec<_> = contents
        .skipped
        .iter()
        .map(|s| {
            let path = b.create_string(&s.path);
            let reason = b.create_string(&s.reason);
            fbs::SkippedPath::create(
                &mut b,
                &fbs::SkippedPathArgs {
                    path: Some(path),
                    reason: Some(reason),
                },
            )
        })
        .collect();
    let skipped = b.create_vector(&skipped_offs);
    let table = fbs::FileContents::create(
        &mut b,
        &fbs::FileContentsArgs {
            files: Some(files),
            skipped: Some(skipped),
        },
    );
    finish_envelope(b, fbs::Payload::FileContents, table.as_union_value())
}

/// Serialise `&[AnnotationLine]` into a finished `Envelope<FileAnnotation>` buffer.
fn file_annotation_to_envelope(lines: &[AnnotationLine]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(2048);
    let offsets: Vec<_> = lines
        .iter()
        .map(|l| {
            let commit_id = b.create_string(&l.commit_id.0);
            let change_id = b.create_string(&l.change_id.0);
            let content = b.create_vector(&l.content);
            fbs::AnnotationLine::create(
                &mut b,
                &fbs::AnnotationLineArgs {
                    commit_id: Some(commit_id),
                    change_id: Some(change_id),
                    original_line_number: l.original_line_number,
                    content: Some(content),
                    origin_found: l.origin_found,
                },
            )
        })
        .collect();
    let vec = b.create_vector(&offsets);
    let table = fbs::FileAnnotation::create(&mut b, &fbs::FileAnnotationArgs { lines: Some(vec) });
    finish_envelope(b, fbs::Payload::FileAnnotation, table.as_union_value())
}

/// Serialise a [`FileSearch`] into a finished `Envelope<FileSearch>` buffer.
///
/// `conflict_side` uses the established presence-flag pair (`has_conflict_side`): flatc
/// 25.12.19 rejects optional scalars for Dart, so absence is a separate bool.
///
/// The `skipped` loop is the same shape as `file_contents_to_envelope`'s, though the two
/// carry different reason sets (search reports only unreadable blobs).
fn file_search_to_envelope(search: &FileSearch) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(2048);
    let offsets: Vec<_> = search
        .matches
        .iter()
        .map(|m| {
            let path = b.create_string(&m.path);
            let content = b.create_vector(&m.content);
            fbs::SearchMatch::create(
                &mut b,
                &fbs::SearchMatchArgs {
                    path: Some(path),
                    line_number: m.line_number,
                    content: Some(content),
                    conflict_side: m.conflict_side.unwrap_or(0),
                    has_conflict_side: m.conflict_side.is_some(),
                },
            )
        })
        .collect();
    let vec = b.create_vector(&offsets);
    let skipped_offs: Vec<_> = search
        .skipped
        .iter()
        .map(|s| {
            let path = b.create_string(&s.path);
            let reason = b.create_string(&s.reason);
            fbs::SkippedPath::create(
                &mut b,
                &fbs::SkippedPathArgs {
                    path: Some(path),
                    reason: Some(reason),
                },
            )
        })
        .collect();
    let skipped = b.create_vector(&skipped_offs);
    let table = fbs::FileSearch::create(
        &mut b,
        &fbs::FileSearchArgs {
            matches: Some(vec),
            skipped: Some(skipped),
        },
    );
    finish_envelope(b, fbs::Payload::FileSearch, table.as_union_value())
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// List the entries of a revision's tree in the repo identified by `handle` — the CLI's
/// `jj file list`.
///
/// The arguments cross as a `FileListRequest` `FlatBuffers` request buffer (ADR-0001
/// composite-input pattern). An ABSENT `revision` is the wire form of "the user did not
/// supply it", which applies the CLI's own `-r` default `@` — here the LAST-SNAPSHOTTED
/// working-copy commit, because Zanshin never snapshots (D2). `paths` entries are
/// repo-relative PREFIXES; an empty list means all paths. This read writes NO operation.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `FileList` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileListRequest` buffer, or its `kind`
///   is not `FileList`, i.e. the buffer was built for a different wrapper.
/// - `jj.change_not_found` — `revision` is malformed, carried by no VISIBLE commit (unknown
///   or only-hidden), or divergent. An ABSENT `revision` is not an error — it is what applies
///   the CLI's `-r` default `@`.
/// - `jj.invalid_input` — a `paths` entry is not a valid repo path; detail in `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been
/// closed. `0` is detected and returned as `ffi.invalid_handle`. A stale non-zero handle is
/// undefined behaviour; the Dart worker's Model-A handle table (Story 3.9) makes a stale
/// handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and
/// owned/freed by Dart (`fbs.FileListRequestObjectBuilder(...).toBytes()`); Rust only
/// borrows it for the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_file_list(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_file_list", handle);
    let buf = catch(|| {
        let req = read_file_list_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let entries = session.repo.file_list(req.revision, &req.paths).map_err(map_file_err)?;
        Ok(file_list_to_envelope(&entries))
    });
    vec_into_token(buf)
}

/// Read the contents of the files selected by the request in the repo identified by
/// `handle` — the CLI's `jj file show`.
///
/// The arguments cross as a `FileShowRequest` `FlatBuffers` request buffer. `revision` and
/// `paths` behave as for `zanshin_file_list`, except that `paths` may NOT be empty (the CLI
/// marks its FILESETS argument `required`). A directory is visited recursively.
///
/// With exactly ONE path an absent path is REFUSED (`jj.path_not_found`, the CLI's own fast
/// path); with several, an absent path simply contributes nothing. A conflicted file's
/// content is the MATERIALIZED merge, in the style the repo's effective
/// `ui.conflict-marker-style` selects. Paths that exist but are not renderable as file
/// content land in `FileContents.skipped` instead of failing the call. This read writes NO
/// operation.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `FileContents` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileShowRequest` buffer, or its `kind`
///   is not `FileShow`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `paths` is empty, or an entry is not a valid repo path.
/// - `jj.change_not_found` — `revision` does not resolve.
/// - `jj.path_not_found` — exactly one path was given and it is absent from the revision's
///   tree; the path in `context`.
/// - `jj.config_error` — the repo's effective jj config is unreadable or malformed, so the
///   `ui.conflict-marker-style` this verb materializes conflicts with cannot be read.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle and buffer contract as `zanshin_file_list`; `data` is a
/// `fbs.FileShowRequestObjectBuilder(...).toBytes()` buffer.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_file_show(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_file_show", handle);
    let buf = catch(|| {
        let req = read_file_show_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let contents = session.repo.file_show(req.revision, &req.paths).map_err(map_file_err)?;
        Ok(file_contents_to_envelope(&contents))
    });
    vec_into_token(buf)
}

/// Annotate one file line by line in the repo identified by `handle` — the CLI's
/// `jj file annotate`.
///
/// The arguments cross as a `FileAnnotateRequest` `FlatBuffers` request buffer. `path` is a
/// single PLAIN repo-relative path, not a prefix and not a fileset. The search domain is
/// `all()`, hardcoded exactly as the CLI hardcodes it. One entry per line, in file order —
/// a line's own 1-based number is its index in `FileAnnotation.lines` + 1, which is why the
/// payload carries only `original_line_number`. This read writes NO operation.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `FileAnnotation` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileAnnotateRequest` buffer, or its `kind`
///   is not `FileAnnotate`, i.e. the buffer was built for a different wrapper.
/// - `jj.change_not_found` — `revision` does not resolve.
/// - `jj.invalid_input` — `path` is absent from the request buffer, or is not a valid repo
///   path.
/// - `jj.path_not_found` — `path` is absent from the revision's tree; the path in `context`.
/// - `jj.not_a_file` — `path` exists but is not a regular file (a directory, a symlink, a
///   submodule, or a conflict with a non-file side); the path in `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle and buffer contract as `zanshin_file_list`; `data` is a
/// `fbs.FileAnnotateRequestObjectBuilder(...).toBytes()` buffer.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_file_annotate(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_file_annotate", handle);
    let buf = catch(|| {
        let req = read_file_annotate_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let lines = session
            .repo
            .file_annotate(req.revision, &req.path)
            .map_err(map_file_err)?;
        Ok(file_annotation_to_envelope(&lines))
    });
    vec_into_token(buf)
}

/// Search the files of a revision for a pattern in the repo identified by `handle` — the
/// CLI's `jj file search`.
///
/// The arguments cross as a `FileSearchRequest` `FlatBuffers` request buffer. `pattern` is
/// jj's own `kind:pattern` string-pattern syntax passed through verbatim; a bare pattern
/// defaults to kind `regex`. `name_only` stops a file's scan at its FIRST match — it changes
/// the work done, not the result shape, so each matching file still contributes its first
/// matching line. A conflicted path is searched side by side, with `conflict_side` set and
/// line numbers restarting per side. Symlinks, submodules and non-file conflicts are
/// SILENTLY not searched (CLI parity); a path whose blob could not be READ lands in the
/// payload's `skipped` vector — the only case `jj file search` warns about — and does NOT
/// fail the call. This read writes NO operation.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `FileSearch` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FileSearchRequest` buffer, or its `kind`
///   is not `FileSearch`, i.e. the buffer was built for a different wrapper.
/// - `jj.change_not_found` — `revision` does not resolve.
/// - `jj.invalid_input` — `pattern` is absent from the request buffer, names an unknown kind
///   or does not parse, or a `paths` entry is not a valid repo path; detail in `context`.
/// - `jj.jj_lib_error` — an underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// Same handle and buffer contract as `zanshin_file_list`; `data` is a
/// `fbs.FileSearchRequestObjectBuilder(...).toBytes()` buffer.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_file_search(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_file_search", handle);
    let buf = catch(|| {
        let req = read_file_search_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let search = session
            .repo
            .file_search(req.revision, &req.pattern, &req.paths, req.name_only)
            .map_err(map_file_err)?;
        Ok(file_search_to_envelope(&search))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use zanshin_jj::{
        AnnotationLine, ChangeId, CommitId, FileContents, FileEntry, FileError, FileSearch, FileType, SearchMatch,
        ShownFile, SkippedPath,
    };

    use super::{
        file_annotation_to_envelope, file_contents_to_envelope, file_list_to_envelope, file_search_to_envelope,
        map_file_err,
    };
    use crate::fbs;
    use crate::{
        JJ_CHANGE_NOT_FOUND, JJ_CONFIG_ERROR, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_NOT_A_FILE, JJ_PATH_NOT_FOUND,
    };

    fn verified(bytes: &[u8]) -> fbs::Envelope<'_> {
        fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass")
    }

    #[test]
    fn map_file_err_covers_every_variant() {
        let cases = [
            (
                map_file_err(FileError::ChangeNotFound { id: "zzz".to_owned() }),
                JJ_CHANGE_NOT_FOUND,
                "zzz",
            ),
            (
                map_file_err(FileError::PathNotFound {
                    path: "nope.txt".to_owned(),
                }),
                JJ_PATH_NOT_FOUND,
                "nope.txt",
            ),
            (
                map_file_err(FileError::NotAFile { path: "dir".to_owned() }),
                JJ_NOT_A_FILE,
                "dir",
            ),
            (
                map_file_err(FileError::InvalidInput {
                    reason: "bad pattern".to_owned(),
                }),
                JJ_INVALID_INPUT,
                "bad pattern",
            ),
            (
                map_file_err(FileError::Config {
                    reason: "bad marker style".to_owned(),
                }),
                JJ_CONFIG_ERROR,
                "bad marker style",
            ),
            (
                map_file_err(FileError::Backend("boom".to_owned())),
                JJ_JJ_LIB_ERROR,
                "boom",
            ),
        ];
        for (obj, code, context) in cases {
            assert_eq!(obj.code, code, "code for {context}");
            assert_eq!(obj.context.as_deref(), Some(context), "context is never in the code");
        }
    }

    #[test]
    fn file_list_to_envelope_carries_every_entry_field() {
        let entries = vec![
            FileEntry {
                path: "a.txt".to_owned(),
                file_type: FileType::File,
                executable: true,
                conflict_side_count: 1,
            },
            FileEntry {
                path: "dir/link".to_owned(),
                file_type: FileType::Symlink,
                executable: false,
                conflict_side_count: 1,
            },
            FileEntry {
                // A MINIMAL conflict has TWO sides: `Merge::num_sides()` is
                // `values.len() / 2 + 1`, so a 3-term merge simplifies to 2.
                path: "c.txt".to_owned(),
                file_type: FileType::Conflict,
                executable: false,
                conflict_side_count: 2,
            },
        ];

        let buf = file_list_to_envelope(&entries);
        let env = verified(&buf);
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::FileList);
        let payload = env.data_as_file_list().expect("FileList payload");
        let fbs_entries = payload.entries().expect("entries present");
        assert_eq!(fbs_entries.len(), 3);

        assert_eq!(fbs_entries.get(0).path(), Some("a.txt"));
        assert_eq!(fbs_entries.get(0).file_type(), fbs::FileType::File);
        assert!(fbs_entries.get(0).executable());
        assert_eq!(fbs_entries.get(1).file_type(), fbs::FileType::Symlink);
        assert!(!fbs_entries.get(1).executable());
        assert_eq!(fbs_entries.get(2).file_type(), fbs::FileType::Conflict);
        assert_eq!(fbs_entries.get(2).conflict_side_count(), 2);
    }

    /// The two remaining `FileType` members have no jj-side constructor a unit test can
    /// reach through `entries_matching`, so the mapper is pinned directly.
    #[test]
    fn file_type_to_fbs_maps_tree_and_submodule() {
        assert_eq!(super::file_type_to_fbs(FileType::Tree), fbs::FileType::Tree);
        assert_eq!(
            super::file_type_to_fbs(FileType::GitSubmodule),
            fbs::FileType::GitSubmodule
        );
    }

    #[test]
    fn file_contents_to_envelope_carries_bytes_and_skipped_paths() {
        let contents = FileContents {
            files: vec![ShownFile {
                path: "bin.dat".to_owned(),
                // Deliberately NOT valid UTF-8: the field is [ubyte] for exactly this case.
                content: vec![0xff, 0x00, 0x41],
                conflict: true,
            }],
            skipped: vec![SkippedPath {
                path: "link".to_owned(),
                reason: "Path 'link' exists but is not a file.".to_owned(),
            }],
        };

        let buf = file_contents_to_envelope(&contents);
        let env = verified(&buf);
        assert_eq!(env.data_type(), fbs::Payload::FileContents);
        let payload = env.data_as_file_contents().expect("FileContents payload");
        let files = payload.files().expect("files present");
        assert_eq!(files.len(), 1);
        assert_eq!(files.get(0).path(), Some("bin.dat"));
        assert_eq!(
            files.get(0).content().map(|c| c.bytes().to_vec()),
            Some(vec![0xff, 0x00, 0x41])
        );
        assert!(files.get(0).conflict());
        let skipped = payload.skipped().expect("skipped present");
        assert_eq!(skipped.len(), 1);
        assert_eq!(skipped.get(0).path(), Some("link"));
        assert_eq!(skipped.get(0).reason(), Some("Path 'link' exists but is not a file."));
    }

    #[test]
    fn file_annotation_to_envelope_carries_both_origin_states() {
        let lines = vec![
            AnnotationLine {
                commit_id: CommitId("aa".to_owned()),
                change_id: ChangeId("zz".to_owned()),
                original_line_number: 1,
                content: b"first\n".to_vec(),
                origin_found: true,
            },
            AnnotationLine {
                commit_id: CommitId("bb".to_owned()),
                change_id: ChangeId("yy".to_owned()),
                original_line_number: 7,
                content: b"second".to_vec(),
                origin_found: false,
            },
        ];

        let buf = file_annotation_to_envelope(&lines);
        let env = verified(&buf);
        assert_eq!(env.data_type(), fbs::Payload::FileAnnotation);
        let payload = env.data_as_file_annotation().expect("FileAnnotation payload");
        let fbs_lines = payload.lines().expect("lines present");
        assert_eq!(fbs_lines.len(), 2);
        assert_eq!(fbs_lines.get(0).commit_id(), Some("aa"));
        assert_eq!(fbs_lines.get(0).change_id(), Some("zz"));
        assert_eq!(fbs_lines.get(0).original_line_number(), 1);
        assert!(fbs_lines.get(0).origin_found());
        assert_eq!(fbs_lines.get(1).original_line_number(), 7);
        assert!(!fbs_lines.get(1).origin_found());
        assert_eq!(
            fbs_lines.get(1).content().map(|c| c.bytes().to_vec()),
            Some(b"second".to_vec())
        );
    }

    #[test]
    fn file_search_to_envelope_uses_the_presence_flag_for_conflict_side() {
        let search = FileSearch {
            matches: vec![
                SearchMatch {
                    path: "a.txt".to_owned(),
                    line_number: 2,
                    content: b"needle\n".to_vec(),
                    conflict_side: None,
                },
                SearchMatch {
                    path: "c.txt".to_owned(),
                    line_number: 1,
                    content: b"needle two\n".to_vec(),
                    conflict_side: Some(1),
                },
            ],
            skipped: vec![],
        };

        let buf = file_search_to_envelope(&search);
        let env = verified(&buf);
        assert_eq!(env.data_type(), fbs::Payload::FileSearch);
        let payload = env.data_as_file_search().expect("FileSearch payload");
        let fbs_matches = payload.matches().expect("matches present");
        assert_eq!(fbs_matches.len(), 2);
        assert_eq!(fbs_matches.get(0).line_number(), 2);
        assert!(
            !fbs_matches.get(0).has_conflict_side(),
            "a resolved file has no conflict side"
        );
        assert_eq!(
            fbs_matches.get(0).conflict_side(),
            0,
            "the ignored value is written as 0"
        );
        assert!(fbs_matches.get(1).has_conflict_side());
        assert_eq!(fbs_matches.get(1).conflict_side(), 1);
        let fbs_skipped = payload
            .skipped()
            .expect("an empty skipped vector is still WRITTEN, as a present empty vector");
        assert_eq!(fbs_skipped.len(), 0, "nothing was skipped in this search");
    }

    /// The search payload's `skipped` channel — the mirror of
    /// `file_contents_to_envelope_carries_bytes_and_skipped_paths`, but with search's OWN
    /// wording: only an unreadable blob is reported here.
    #[test]
    fn file_search_to_envelope_carries_skipped_paths() {
        let search = FileSearch {
            matches: vec![SearchMatch {
                path: "a.txt".to_owned(),
                line_number: 1,
                content: b"needle\n".to_vec(),
                conflict_side: None,
            }],
            skipped: vec![SkippedPath {
                path: "secret.txt".to_owned(),
                reason: "Skipping 'secret.txt' due to permission error: Access denied".to_owned(),
            }],
        };

        let buf = file_search_to_envelope(&search);
        let env = verified(&buf);
        let payload = env.data_as_file_search().expect("FileSearch payload");
        assert_eq!(payload.matches().expect("matches present").len(), 1);
        let skipped = payload.skipped().expect("skipped present");
        assert_eq!(skipped.len(), 1);
        assert_eq!(skipped.get(0).path(), Some("secret.txt"));
        assert_eq!(
            skipped.get(0).reason(),
            Some("Skipping 'secret.txt' due to permission error: Access denied")
        );
    }

    #[test]
    fn empty_results_still_produce_ok_envelopes() {
        for (buf, expected) in [
            (file_list_to_envelope(&[]), fbs::Payload::FileList),
            (
                file_contents_to_envelope(&FileContents {
                    files: vec![],
                    skipped: vec![],
                }),
                fbs::Payload::FileContents,
            ),
            (file_annotation_to_envelope(&[]), fbs::Payload::FileAnnotation),
            (
                file_search_to_envelope(&FileSearch {
                    matches: vec![],
                    skipped: vec![],
                }),
                fbs::Payload::FileSearch,
            ),
        ] {
            let env = verified(&buf);
            assert!(env.ok(), "an empty result is a success, not an error");
            assert_eq!(env.data_type(), expected);
        }
    }
}
