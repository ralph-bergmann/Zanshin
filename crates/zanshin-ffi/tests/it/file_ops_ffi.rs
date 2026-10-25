// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.22's two working-copy tracking wrappers
//! (`zanshin_file_track`, `zanshin_file_untrack`).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The jj-level BEHAVIOUR is pinned in
//! `crates/zanshin-jj/tests/it/file_track_untrack.rs`; what is tested here is the wire contract:
//! both readers, both result payloads (including BOTH `UntrackedReason` union arms), the
//! handle and buffer guards, `jj.path_not_ignored` with its `context`, and that a refusal writes
//! no operation — read back through `zanshin_op_log`, the surface a GUI would poll.
//!
//! Repos are built in-test through `zanshin_jj` (a regular dependency of this crate): the rows
//! need files on disk next to a working-copy state, which the committed fixtures do not model.

use std::ffi::CString;
use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use flatbuffers::root as fb_root;
use tempfile::TempDir;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::file_ops::{
    zanshin_file_chmod, zanshin_file_delete, zanshin_file_edit, zanshin_file_track, zanshin_file_untrack,
};
use zanshin_ffi::op_log::zanshin_op_log;
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CHANGE_NOT_FOUND, JJ_INVALID_INPUT,
    JJ_PATHS_UNMATCHED, JJ_PATH_NOT_IGNORED,
};
use zanshin_jj::{Backend, Repo};

// ── Env pin ───────────────────────────────────────────────────────────────────

// ── Envelope helpers ──────────────────────────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by one of the `zanshin_*` functions
/// and not yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// The request-buffer wrapper shape both verbs share.
type BufWrapper = unsafe extern "C" fn(u64, *const u8, usize) -> *mut ZanshinBuf;

fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

fn open_handle(path: &Path) -> u64 {
    let p = CString::new(path.to_str().expect("UTF-8 path")).expect("no NUL");
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let token = unsafe { zanshin_repo_open(p.as_ptr()) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "expected ok, error: {:?}", env.error().and_then(|e| e.code()));
    env.data_as_repo_handle().expect("RepoHandle payload").handle()
}

fn close_handle(handle: u64) {
    // SAFETY: handle originated from open_handle and has not been closed.
    let token = unsafe { zanshin_repo_close(handle) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    assert!(parse_envelope(&bytes).ok(), "repo close must succeed");
}

/// `(id, description)` of the head operation, read back through the shipped op-log wrapper.
fn head_op(handle: u64) -> (String, String) {
    // SAFETY: handle is live; -1 means "no limit".
    let token = unsafe { zanshin_op_log(handle, -1) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "op_log must succeed");
    let head = env
        .data_as_op_log()
        .expect("OpLog payload")
        .operations()
        .expect("operations vector")
        .get(0);
    (
        head.id().expect("head op id").to_owned(),
        head.description().unwrap_or_default().to_owned(),
    )
}

// ── Request-buffer builders ───────────────────────────────────────────────────

/// A `FileTrackRequest`; `None` leaves the `paths` vector genuinely ABSENT.
fn track_request_bytes(paths: Option<&[&str]>, include_ignored: bool) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let paths_off = paths.map(|ps| {
        let offsets: Vec<_> = ps.iter().map(|p| b.create_string(p)).collect();
        b.create_vector(&offsets)
    });
    let req = fbs::FileTrackRequest::create(
        &mut b,
        &fbs::FileTrackRequestArgs {
            kind: fbs::RequestKind::FileTrack,
            paths: paths_off,
            include_ignored,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `FileUntrackRequest`; `None` leaves the `paths` vector genuinely ABSENT.
fn untrack_request_bytes(paths: Option<&[&str]>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let paths_off = paths.map(|ps| {
        let offsets: Vec<_> = ps.iter().map(|p| b.create_string(p)).collect();
        b.create_vector(&offsets)
    });
    let req = fbs::FileUntrackRequest::create(
        &mut b,
        &fbs::FileUntrackRequestArgs {
            kind: fbs::RequestKind::FileUntrack,
            paths: paths_off,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Calls `wrapper` with `req` and returns the raw envelope bytes.
fn call(wrapper: BufWrapper, handle: u64, req: &[u8]) -> Vec<u8> {
    // SAFETY: the handle is live (or the documented null handle); the buffer outlives the call.
    let token = unsafe { wrapper(handle, req.as_ptr(), req.len()) };
    // SAFETY: fresh, non-null token.
    unsafe { read_and_free(token) }
}

// ── Fixtures ──────────────────────────────────────────────────────────────────

/// An internal-git workspace whose repo layer is `repo_config`; the `TempDir` is leaked so it
/// outlives the raw handle.
fn init_repo(repo_config: &str) -> PathBuf {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir").keep();
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&tmp),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init")
    .workspace_root()
    .to_owned();
    fs::write(root.join(".jj").join("repo").join("config.toml"), repo_config).expect("repo config");
    root
}

/// A workspace whose `@` holds `.gitignore` (`*.log`), `c.log` and `d.txt`, checked out on disk:
/// the commit is built off root and EDITED, which writes the files and the working-copy state.
fn untrack_fixture() -> PathBuf {
    let root = init_repo("");
    let hex = test_helpers::add_commit_with_files(
        &root,
        &[],
        &[(".gitignore", "*.log\n"), ("c.log", "log"), ("d.txt", "text")],
        "tracked files",
    );
    let mut repo = Repo::open(&root).expect("open");
    let change = zanshin_jj::resolve_revset(&repo, &hex).expect("resolve")[0].clone();
    repo.edit(change).expect("edit");
    root
}

// ── Round trips ───────────────────────────────────────────────────────────────

/// `track` over the wire: a `TrackResult` whose stats carry BOTH union arms, and one new
/// `track paths` operation.
#[test]
fn track_round_trips_through_track_result_with_both_reason_arms() {
    // `auto-track = none()`: otherwise the pre-verb snapshot (Story 9.26) would auto-track the
    // small `other.txt` itself, and only the too-large file would stay untracked.
    let root = init_repo("snapshot.max-new-file-size = 5\nsnapshot.auto-track = \"none()\"\n");
    fs::write(root.join("big.bin"), "0123456789").expect("big");
    fs::write(root.join("other.txt"), "o").expect("other");
    let handle = open_handle(&root);
    let (before, _) = head_op(handle);

    let bytes = call(
        zanshin_file_track,
        handle,
        &track_request_bytes(Some(&["big.bin"]), false),
    );
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let result = env.data_as_track_result().expect("TrackResult payload");
    let (head, description) = head_op(handle);
    assert_ne!(head, before, "an operation is always written");
    assert_eq!(description, "track paths");
    let mutation = result.mutation().expect("mutation");
    assert_eq!(mutation.new_op_id(), Some(head.as_str()));
    assert_eq!(result.num_rebased(), 0);
    let stats = result.snapshot_stats().expect("stats");
    assert_eq!(stats.invalid_utf8_paths().map(|v| v.len()), Some(0));
    let untracked = stats.untracked().expect("untracked");
    assert_eq!(untracked.len(), 2);
    let big = untracked.get(0);
    assert_eq!(big.path(), Some("big.bin"));
    assert_eq!(big.reason_type(), fbs::UntrackedReason::FileTooLarge);
    let too_large = big.reason_as_file_too_large().expect("FileTooLarge arm");
    assert_eq!((too_large.size(), too_large.max_size()), (10, 5));
    let other = untracked.get(1);
    assert_eq!(other.path(), Some("other.txt"));
    assert_eq!(other.reason_type(), fbs::UntrackedReason::FileNotAutoTracked);
    assert!(other.reason_as_file_not_auto_tracked().is_some());

    close_handle(handle);
}

/// `include_ignored = true` crosses the reader: the too-large file is FORCED into tracking, so it
/// is no longer reported as untracked.
#[test]
fn track_with_include_ignored_forces_the_too_large_file() {
    let root = init_repo("snapshot.max-new-file-size = 5\n");
    fs::write(root.join("big.bin"), "0123456789").expect("big");
    let handle = open_handle(&root);

    let bytes = call(
        zanshin_file_track,
        handle,
        &track_request_bytes(Some(&["big.bin"]), true),
    );
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let untracked = env
        .data_as_track_result()
        .expect("TrackResult payload")
        .snapshot_stats()
        .and_then(|s| s.untracked())
        .expect("untracked vector");
    assert!(
        untracked.iter().all(|u| u.path() != Some("big.bin")),
        "a forced file is tracked, not reported"
    );

    close_handle(handle);
}

/// `untrack` over the wire: an `UntrackResult` with an unmatched path, empty export failures,
/// and one new `untrack paths` operation.
#[test]
fn untrack_round_trips_through_untrack_result() {
    let root = untrack_fixture();
    let handle = open_handle(&root);

    let bytes = call(
        zanshin_file_untrack,
        handle,
        &untrack_request_bytes(Some(&["c.log", "nope.txt"])),
    );
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let result = env.data_as_untrack_result().expect("UntrackResult payload");
    let (head, description) = head_op(handle);
    assert_eq!(description, "untrack paths");
    assert_eq!(result.mutation().and_then(|m| m.new_op_id()), Some(head.as_str()));
    assert_eq!(result.num_rebased(), 0);
    let unmatched: Vec<_> = result.unmatched_paths().expect("unmatched").iter().collect();
    assert_eq!(unmatched, vec!["nope.txt"]);
    assert_eq!(
        result.snapshot_stats().and_then(|s| s.untracked()).map(|v| v.len()),
        Some(0)
    );
    assert_eq!(result.failed_bookmarks().map(|v| v.len()), Some(0));
    assert_eq!(result.failed_tags().map(|v| v.len()), Some(0));
    assert!(root.join("c.log").exists(), "the file stays on disk");

    close_handle(handle);
}

// ── Refusals ──────────────────────────────────────────────────────────────────

/// A non-ignored path is `jj.path_not_ignored` with every offender in `context`, and writes no
/// operation.
#[test]
fn untrack_of_unignored_paths_is_path_not_ignored_and_writes_nothing() {
    let root = untrack_fixture();
    let handle = open_handle(&root);
    let (before, _) = head_op(handle);

    // `c.log` is ignored and would be untracked; `d.txt` is the one offender named.
    let bytes = call(
        zanshin_file_untrack,
        handle,
        &untrack_request_bytes(Some(&["d.txt", "c.log"])),
    );
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_PATH_NOT_IGNORED));
    assert_eq!(env.error().and_then(|e| e.context()), Some("d.txt"));
    assert_eq!(head_op(handle).0, before, "a refusal writes no operation");
    close_handle(handle);
}

/// `context` joins EVERY offender with `\n`, in tree order.
#[test]
fn path_not_ignored_context_lists_every_offender() {
    let root = init_repo("");
    let hex = test_helpers::add_commit_with_files(&root, &[], &[("a.txt", "a"), ("b.txt", "b")], "two");
    let mut repo = Repo::open(&root).expect("open");
    let change = zanshin_jj::resolve_revset(&repo, &hex).expect("resolve")[0].clone();
    repo.edit(change).expect("edit");
    drop(repo);
    let handle = open_handle(&root);

    let bytes = call(
        zanshin_file_untrack,
        handle,
        &untrack_request_bytes(Some(&["b.txt", "a.txt"])),
    );
    let env = parse_envelope(&bytes);

    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_PATH_NOT_IGNORED));
    assert_eq!(env.error().and_then(|e| e.context()), Some("a.txt\nb.txt"));
    close_handle(handle);
}

/// An ABSENT `paths` vector reaches the jj layer as an empty list: `jj.invalid_input`, no op.
#[test]
fn an_absent_paths_vector_refuses_as_invalid_input() {
    let root = init_repo("");
    let handle = open_handle(&root);
    let (before, _) = head_op(handle);

    for (wrapper, req) in [
        (zanshin_file_track as BufWrapper, track_request_bytes(None, false)),
        (zanshin_file_untrack as BufWrapper, untrack_request_bytes(None)),
    ] {
        let bytes = call(wrapper, handle, &req);
        let env = parse_envelope(&bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));
        assert_eq!(head_op(handle).0, before, "a refusal writes no operation");
    }
    close_handle(handle);
}

/// A zero handle is refused once the buffer itself is above reproach, for both wrappers.
#[test]
fn a_zero_handle_is_refused_by_both_wrappers() {
    test_helpers::pin_test_env();
    for (wrapper, req) in [
        (
            zanshin_file_track as BufWrapper,
            track_request_bytes(Some(&["a"]), false),
        ),
        (zanshin_file_untrack as BufWrapper, untrack_request_bytes(Some(&["a"]))),
    ] {
        let bytes = call(wrapper, 0, &req);
        let env = parse_envelope(&bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_HANDLE));
    }
}

/// A buffer built for the OTHER verb is a kind mismatch in both directions — also with a zero
/// handle, proving the kind rung runs before the handle lookup.
#[test]
fn a_buffer_built_for_the_other_wrapper_is_refused_as_a_kind_mismatch() {
    let root = init_repo("");
    let handle = open_handle(&root);
    let (before, _) = head_op(handle);
    let track_req = track_request_bytes(Some(&["a"]), false);
    let untrack_req = untrack_request_bytes(Some(&["a"]));

    for h in [handle, 0] {
        for (wrapper, req, expected, got) in [
            (
                zanshin_file_track as BufWrapper,
                &untrack_req,
                "FileTrack",
                "FileUntrack",
            ),
            (
                zanshin_file_untrack as BufWrapper,
                &track_req,
                "FileUntrack",
                "FileTrack",
            ),
        ] {
            let bytes = call(wrapper, h, req);
            let env = parse_envelope(&bytes);
            assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));
            assert_eq!(
                env.error().and_then(|e| e.context()),
                Some(format!("request kind mismatch: expected {expected}, got {got}").as_str())
            );
        }
    }
    assert_eq!(head_op(handle).0, before);
    close_handle(handle);
}

/// A null buffer and a buffer that does not verify are distinct failures, for both wrappers.
#[test]
fn a_null_or_malformed_request_buffer_is_refused_by_both_wrappers() {
    let root = init_repo("");
    let handle = open_handle(&root);
    let garbage: [u8; 8] = [0xff; 8];

    for wrapper in [zanshin_file_track as BufWrapper, zanshin_file_untrack as BufWrapper] {
        // SAFETY: a null `data` is the documented null-pointer case.
        let token = unsafe { wrapper(handle, std::ptr::null(), 0) };
        // SAFETY: fresh, non-null token.
        let bytes = unsafe { read_and_free(token) };
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_NULL_POINTER)
        );

        let bytes = call(wrapper, handle, &garbage);
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_INVALID_ARGUMENT)
        );
    }
    close_handle(handle);
}

// ── Story 9.13: file chmod ────────────────────────────────────────────────────

/// A `FileChmodRequest`; `None` leaves `revision` / `paths` genuinely ABSENT.
fn chmod_request_bytes(
    kind: fbs::RequestKind,
    executable: bool,
    revision: Option<&str>,
    paths: Option<&[&str]>,
) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let revision = revision.map(|r| b.create_string(r));
    let paths = paths.map(|paths| {
        let offsets: Vec<_> = paths.iter().map(|p| b.create_string(p)).collect();
        b.create_vector(&offsets)
    });
    let req = fbs::FileChmodRequest::create(
        &mut b,
        &fbs::FileChmodRequestArgs {
            kind,
            executable,
            revision,
            paths,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// `chmod` over the wire: every field crosses (the bit, the paths, an absent revision = `@`), the
/// unmatched path's warning rides the ok envelope, and the operation names `@`'s commit.
#[test]
fn chmod_round_trips_through_mutation_result() {
    let root = untrack_fixture();
    let handle = open_handle(&root);
    let req = chmod_request_bytes(fbs::RequestKind::FileChmod, true, None, Some(&["d.txt", "nope"]));
    let bytes = call(zanshin_file_chmod, handle, &req);
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    let result = env.data_as_mutation_result().expect("payload");
    let (head, description) = head_op(handle);
    assert_eq!(result.new_op_id(), Some(head.as_str()));
    assert!(
        description.starts_with("make paths executable in commit "),
        "{description}"
    );
    let warnings = env.warnings().expect("warnings");
    assert_eq!(warnings.get(0).code(), Some(JJ_PATHS_UNMATCHED));
    assert!(env.precondition().is_some());
    let mode = fs::metadata(root.join("d.txt")).expect("stat").permissions().mode();
    assert_ne!(mode & 0o111, 0, "the checkout made d.txt executable");
    close_handle(handle);
}

/// A malformed `revision` crosses and refuses; absent `paths`, a zero handle, a null buffer and a
/// buffer of another kind are refused before the verb.
#[test]
fn chmod_refusals_cross_the_wire() {
    let root = untrack_fixture();
    let handle = open_handle(&root);
    let (before, _) = head_op(handle);
    let code = |bytes: &[u8]| {
        parse_envelope(bytes)
            .error()
            .and_then(|e| e.code())
            .map(ToOwned::to_owned)
    };
    let req = chmod_request_bytes(
        fbs::RequestKind::FileChmod,
        false,
        Some("zzzz-not-hex"),
        Some(&["d.txt"]),
    );
    assert_eq!(
        code(&call(zanshin_file_chmod, handle, &req)).as_deref(),
        Some(JJ_CHANGE_NOT_FOUND)
    );
    let req = chmod_request_bytes(fbs::RequestKind::FileChmod, true, None, None);
    let bytes = call(zanshin_file_chmod, handle, &req);
    assert_eq!(code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert!(
        parse_envelope(&bytes).precondition().is_none(),
        "refused before the snapshot"
    );
    let req = chmod_request_bytes(fbs::RequestKind::FileTrack, true, None, Some(&["d.txt"]));
    assert_eq!(
        code(&call(zanshin_file_chmod, handle, &req)).as_deref(),
        Some(FFI_INVALID_ARGUMENT)
    );
    let req = chmod_request_bytes(fbs::RequestKind::FileChmod, true, None, Some(&["d.txt"]));
    assert_eq!(
        code(&call(zanshin_file_chmod, 0, &req)).as_deref(),
        Some(FFI_INVALID_HANDLE)
    );
    // SAFETY: a null request pointer is the case under test.
    let null = unsafe { read_and_free(zanshin_file_chmod(handle, std::ptr::null(), 0)) };
    assert_eq!(code(&null).as_deref(), Some(FFI_NULL_POINTER));
    assert_eq!(head_op(handle).0, before, "no refusal writes an operation");
    close_handle(handle);
}

// ── Story 9.44: file edit, file delete ────────────────────────────────────────

/// The error code of a refused envelope.
fn error_code(bytes: &[u8]) -> Option<String> {
    parse_envelope(bytes)
        .error()
        .and_then(|e| e.code())
        .map(ToOwned::to_owned)
}

/// A `FileEditRequest`; `None` leaves `revision` / `path` / `content` genuinely ABSENT.
fn edit_request_bytes(
    kind: fbs::RequestKind,
    revision: Option<&str>,
    restore_descendants: bool,
    path: Option<&str>,
    content: Option<&[u8]>,
) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let revision = revision.map(|r| b.create_string(r));
    let path = path.map(|p| b.create_string(p));
    let content = content.map(|c| b.create_vector(c));
    let req = fbs::FileEditRequest::create(
        &mut b,
        &fbs::FileEditRequestArgs {
            kind,
            revision,
            restore_descendants,
            path,
            content,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `FileDeleteRequest`; `None` leaves `revision` / `paths` genuinely ABSENT.
fn delete_request_bytes(
    kind: fbs::RequestKind,
    revision: Option<&str>,
    restore_descendants: bool,
    paths: Option<&[&str]>,
) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let revision = revision.map(|r| b.create_string(r));
    let paths = paths.map(|paths| {
        let offsets: Vec<_> = paths.iter().map(|p| b.create_string(p)).collect();
        b.create_vector(&offsets)
    });
    let req = fbs::FileDeleteRequest::create(
        &mut b,
        &fbs::FileDeleteRequestArgs {
            kind,
            revision,
            restore_descendants,
            paths,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// [`untrack_fixture`] with a new empty `@` on top: returns the root and the PARENT's change id
/// (the commit holding `d.txt`, which `@` inherits).
fn parent_with_child_fixture() -> (PathBuf, String) {
    let root = untrack_fixture();
    let mut repo = Repo::open(&root).expect("open");
    let parent = zanshin_jj::resolve_revset(&repo, "@").expect("resolve")[0].clone();
    repo.new_change(std::slice::from_ref(&parent), &[], &[]).expect("new @");
    (root, parent.0)
}

/// `d.txt` in `revision` (`None` = `@`), or `None` when the revision has no such file.
fn d_txt(root: &Path, revision: Option<&str>) -> Option<Vec<u8>> {
    let mut repo = Repo::open(root).expect("open");
    let revision = revision.map(|r| zanshin_jj::ChangeId(r.to_owned()));
    let path = ["d.txt".to_owned()];
    if repo.file_list(revision.clone(), &path).expect("file list").is_empty() {
        return None;
    }
    let shown = repo.file_show(revision, &path).expect("file show");
    shown.files.into_iter().next().map(|file| file.content)
}

/// `edit -r <parent> --restore-descendants` over the wire: the parent changes, the child keeps
/// its content (and so does the working copy).
#[test]
fn edit_with_restore_descendants_keeps_the_childs_content() {
    let (root, parent) = parent_with_child_fixture();
    let handle = open_handle(&root);
    let req = edit_request_bytes(
        fbs::RequestKind::FileEdit,
        Some(&parent),
        true,
        Some("d.txt"),
        Some(b"new\n"),
    );
    let bytes = call(zanshin_file_edit, handle, &req);
    assert!(
        parse_envelope(&bytes).ok(),
        "{:?}",
        parse_envelope(&bytes).error().and_then(|e| e.context())
    );
    close_handle(handle);
    assert_eq!(d_txt(&root, Some(&parent)).as_deref(), Some(&b"new\n"[..]));
    assert_eq!(
        d_txt(&root, None).as_deref(),
        Some(&b"text"[..]),
        "the child kept its content"
    );
    assert_eq!(fs::read(root.join("d.txt")).expect("read"), b"text");
}

/// `delete -r <parent> --restore-descendants` over the wire: the parent loses the file, the
/// child keeps it.
#[test]
fn delete_with_restore_descendants_keeps_the_childs_content() {
    let (root, parent) = parent_with_child_fixture();
    let handle = open_handle(&root);
    let req = delete_request_bytes(fbs::RequestKind::FileDelete, Some(&parent), true, Some(&["d.txt"]));
    let bytes = call(zanshin_file_delete, handle, &req);
    assert!(
        parse_envelope(&bytes).ok(),
        "{:?}",
        parse_envelope(&bytes).error().and_then(|e| e.context())
    );
    close_handle(handle);
    assert_eq!(d_txt(&root, Some(&parent)), None, "the parent lost d.txt");
    assert_eq!(
        d_txt(&root, None).as_deref(),
        Some(&b"text"[..]),
        "the child kept its content"
    );
    assert!(root.join("d.txt").exists());
}

/// `edit` over the wire: the path and the bytes cross (an absent revision = `@`), the operation
/// names `@`'s commit and the working copy follows.
#[test]
fn edit_round_trips_through_mutation_result() {
    let root = untrack_fixture();
    let handle = open_handle(&root);
    let req = edit_request_bytes(fbs::RequestKind::FileEdit, None, false, Some("d.txt"), Some(b"new\n"));
    let bytes = call(zanshin_file_edit, handle, &req);
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    let result = env.data_as_mutation_result().expect("payload");
    let (head, description) = head_op(handle);
    assert_eq!(result.new_op_id(), Some(head.as_str()));
    assert!(description.starts_with("edit file d.txt in commit "), "{description}");
    assert!(env.precondition().is_some());
    assert_eq!(fs::read(root.join("d.txt")).expect("read"), b"new\n");

    // An EMPTY content vector is an empty file, not an absent field.
    let req = edit_request_bytes(fbs::RequestKind::FileEdit, None, true, Some("d.txt"), Some(b""));
    let env_bytes = call(zanshin_file_edit, handle, &req);
    assert!(parse_envelope(&env_bytes).ok());
    assert_eq!(fs::read(root.join("d.txt")).expect("read"), b"");
    close_handle(handle);
}

/// Absent `path` / `content` refuse before the snapshot; a directory crosses as the CLI's
/// refusal; a malformed revision, a zero handle, a null buffer and a buffer of another kind are
/// refused. None writes an operation.
#[test]
fn edit_refusals_cross_the_wire() {
    let root = untrack_fixture();
    let handle = open_handle(&root);
    let (before, _) = head_op(handle);
    let edit = |revision, path, content: Option<&[u8]>| {
        edit_request_bytes(fbs::RequestKind::FileEdit, revision, false, path, content)
    };
    for req in [edit(None, None, Some(b"x")), edit(None, Some("d.txt"), None)] {
        let bytes = call(zanshin_file_edit, handle, &req);
        assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
        assert!(
            parse_envelope(&bytes).precondition().is_none(),
            "refused before the snapshot"
        );
    }
    let bytes = call(zanshin_file_edit, handle, &edit(None, Some(""), Some(b"x")));
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.context()),
        Some("Path is a directory: .")
    );
    let req = edit(Some("zzzz-not-hex"), Some("d.txt"), Some(b"x"));
    assert_eq!(
        error_code(&call(zanshin_file_edit, handle, &req)).as_deref(),
        Some(JJ_CHANGE_NOT_FOUND)
    );
    let req = edit_request_bytes(fbs::RequestKind::FileChmod, None, false, Some("d.txt"), Some(b"x"));
    assert_eq!(
        error_code(&call(zanshin_file_edit, handle, &req)).as_deref(),
        Some(FFI_INVALID_ARGUMENT)
    );
    assert_eq!(
        error_code(&call(zanshin_file_edit, 0, &edit(None, Some("d.txt"), Some(b"x")))).as_deref(),
        Some(FFI_INVALID_HANDLE)
    );
    // SAFETY: a null request pointer is the case under test.
    let null = unsafe { read_and_free(zanshin_file_edit(handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&null).as_deref(), Some(FFI_NULL_POINTER));
    assert_eq!(head_op(handle).0, before, "no refusal writes an operation");
    close_handle(handle);
}

/// `delete` over the wire: the paths cross (an absent revision = `@`), the unmatched path's
/// warning rides the ok envelope, the operation names `@`'s commit and the file leaves the disk.
#[test]
fn delete_round_trips_through_mutation_result() {
    let root = untrack_fixture();
    let handle = open_handle(&root);
    let req = delete_request_bytes(fbs::RequestKind::FileDelete, None, false, Some(&["d.txt", "nope"]));
    let bytes = call(zanshin_file_delete, handle, &req);
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    let result = env.data_as_mutation_result().expect("payload");
    let (head, description) = head_op(handle);
    assert_eq!(result.new_op_id(), Some(head.as_str()));
    assert!(description.starts_with("delete paths in commit "), "{description}");
    let warnings = env.warnings().expect("warnings");
    assert_eq!(warnings.get(0).code(), Some(JJ_PATHS_UNMATCHED));
    assert!(!root.join("d.txt").exists());
    close_handle(handle);
}

/// Absent and empty `paths` refuse before the snapshot; a malformed revision, a zero handle, a
/// null buffer and a buffer of another kind are refused. None writes an operation.
#[test]
fn delete_refusals_cross_the_wire() {
    let root = untrack_fixture();
    let handle = open_handle(&root);
    let (before, _) = head_op(handle);
    for paths in [None, Some(&[][..])] {
        let req = delete_request_bytes(fbs::RequestKind::FileDelete, None, false, paths);
        let bytes = call(zanshin_file_delete, handle, &req);
        assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
        assert!(
            parse_envelope(&bytes).precondition().is_none(),
            "refused before the snapshot"
        );
    }
    let req = delete_request_bytes(
        fbs::RequestKind::FileDelete,
        Some("zzzz-not-hex"),
        false,
        Some(&["d.txt"]),
    );
    assert_eq!(
        error_code(&call(zanshin_file_delete, handle, &req)).as_deref(),
        Some(JJ_CHANGE_NOT_FOUND)
    );
    let req = delete_request_bytes(fbs::RequestKind::FileEdit, None, false, Some(&["d.txt"]));
    assert_eq!(
        error_code(&call(zanshin_file_delete, handle, &req)).as_deref(),
        Some(FFI_INVALID_ARGUMENT)
    );
    let req = delete_request_bytes(fbs::RequestKind::FileDelete, None, false, Some(&["d.txt"]));
    assert_eq!(
        error_code(&call(zanshin_file_delete, 0, &req)).as_deref(),
        Some(FFI_INVALID_HANDLE)
    );
    // SAFETY: a null request pointer is the case under test.
    let null = unsafe { read_and_free(zanshin_file_delete(handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&null).as_deref(), Some(FFI_NULL_POINTER));
    assert_eq!(head_op(handle).0, before, "no refusal writes an operation");
    close_handle(handle);
}
