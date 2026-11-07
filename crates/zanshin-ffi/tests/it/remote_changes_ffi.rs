// SPDX-License-Identifier: MIT

//! Story 9.24 witnesses for `zanshin_git_remote_changes`, the `git ls-remote` poll: every
//! buffer is read through the generated typed accessors and the Verifier, every token freed.
//! The workspace is a non-colocated clone of a local bare remote; upstream changes are pushed
//! from the source repo, so the workspace's view keeps the targets of its clone.

use std::ffi::CString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use flatbuffers::root as fb_root;
use tempfile::TempDir;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::remotes::zanshin_git_remote_changes;
use zanshin_ffi::repo::{zanshin_network_cancel, zanshin_network_token, zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CANCELLED, JJ_NOT_A_GIT_REPO, JJ_REMOTE_NOT_FOUND};
use zanshin_jj::{CloneOptions, InitOptions, ProgressEvent, Repo};

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

fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("test string must not contain NUL bytes")
}

/// Runs `git` in `dir`; panics on a non-zero exit.
fn git(args: &[&str], dir: &Path) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git spawns");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn open_handle(path: &Path) -> u64 {
    let p = cstr(path.to_str().expect("UTF-8 path"));
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_repo_open(p.as_ptr())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "open: {:?}", env.error().and_then(|e| e.code()));
    env.data_as_repo_handle().expect("RepoHandle").handle()
}

fn close_handle(handle: u64) {
    // SAFETY: handle came from open_handle and has not been closed.
    let bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(parse_envelope(&bytes).ok());
}

/// Calls `zanshin_git_remote_changes` and returns the envelope bytes.
fn poll(handle: u64, remote: Option<&str>, token: u64) -> Vec<u8> {
    let remote = remote.map(cstr);
    let ptr = remote.as_ref().map_or(std::ptr::null(), |r| r.as_ptr());
    // SAFETY: `ptr` is null or a NUL-terminated C string alive for the call.
    unsafe { read_and_free(zanshin_git_remote_changes(handle, ptr, token)) }
}

fn error_code(bytes: &[u8]) -> (Option<String>, Option<String>) {
    let env = parse_envelope(bytes);
    assert!(!env.ok(), "expected an error envelope");
    let error = env.error().expect("error");
    (
        error.code().map(ToOwned::to_owned),
        error.context().map(ToOwned::to_owned),
    )
}

/// A non-colocated clone of a bare remote with `main` and `x`, plus the source repo that pushes
/// to that remote as its `origin`.
struct World {
    _dirs: Vec<TempDir>,
    src: PathBuf,
    bare: PathBuf,
    root: PathBuf,
}

fn world() -> World {
    test_helpers::pin_test_env();
    let src_dir = TempDir::new().unwrap();
    let src = src_dir.path().to_owned();
    git(&["init", "--initial-branch=main"], &src);
    git(&["config", "user.email", "test@zanshin.test"], &src);
    git(&["config", "user.name", "Fixture"], &src);
    fs::write(src.join("README.md"), "hello").unwrap();
    git(&["add", "."], &src);
    git(&["commit", "-m", "initial"], &src);
    git(&["branch", "x"], &src);
    let parent = TempDir::new().unwrap();
    let bare = parent.path().join("remote.git");
    git(
        &["clone", "--bare", &src.to_string_lossy(), &bare.to_string_lossy()],
        parent.path(),
    );
    git(&["remote", "add", "origin", &bare.to_string_lossy()], &src);
    let ws = TempDir::new().unwrap();
    let root = ws.path().join("ws");
    Repo::clone(
        &CloneOptions {
            source: bare.to_string_lossy().into_owned(),
            destination: root.clone(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: ProgressEvent| {},
        None,
    )
    .result
    .expect("clone the remote");
    World {
        _dirs: vec![src_dir, parent, ws],
        src,
        bare,
        root,
    }
}

/// The operation heads on disk, read without a snapshotting call.
fn op_heads(root: &Path) -> Vec<String> {
    let dir = root.join(".jj").join("repo").join("op_heads").join("heads");
    let mut heads: Vec<String> = fs::read_dir(dir)
        .expect("op heads")
        .map(|entry| entry.expect("entry").file_name().to_string_lossy().into_owned())
        .collect();
    heads.sort();
    heads
}

/// Upstream `main` advanced, a tag added and `x` deleted: one `RemoteChanges` payload with all
/// three, bookmarks before tags, no `precondition` on the envelope, and no operation written.
#[test]
fn remote_changes_round_trip_reports_moved_new_and_deleted() {
    let w = world();
    let old_main = git(&["rev-parse", "main"], &w.bare);
    fs::write(w.src.join("second.txt"), "second").unwrap();
    git(&["add", "."], &w.src);
    git(&["commit", "-m", "second"], &w.src);
    let new_main = git(&["rev-parse", "HEAD"], &w.src);
    git(&["tag", "t1"], &w.src);
    git(&["push", "origin", "main", "--tags"], &w.src);
    git(&["push", "origin", "--delete", "x"], &w.src);

    let handle = open_handle(&w.root);
    let before = op_heads(&w.root);
    let bytes = poll(handle, Some("origin"), 0);
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert!(env.precondition().is_none(), "the poll runs no pre-verb snapshot");
    let changes = env
        .data_as_remote_changes()
        .expect("RemoteChanges payload")
        .changes()
        .expect("changes");
    let got: Vec<_> = changes
        .iter()
        .map(|c| {
            (
                c.kind(),
                c.name().map(ToOwned::to_owned),
                c.change(),
                c.old_commit_ids()
                    .map(|v| v.iter().map(ToOwned::to_owned).collect::<Vec<_>>()),
                c.new_commit_id().map(ToOwned::to_owned),
            )
        })
        .collect();
    assert_eq!(
        got,
        [
            (
                fbs::RemoteRefKind::Bookmark,
                Some("main".to_owned()),
                fbs::RemoteRefChangeKind::Moved,
                Some(vec![old_main.clone()]),
                Some(new_main.clone()),
            ),
            (
                fbs::RemoteRefKind::Bookmark,
                Some("x".to_owned()),
                fbs::RemoteRefChangeKind::Deleted,
                Some(vec![old_main]),
                None,
            ),
            (
                fbs::RemoteRefKind::Tag,
                Some("t1".to_owned()),
                fbs::RemoteRefChangeKind::New,
                Some(vec![]),
                Some(new_main),
            ),
        ]
    );
    assert_eq!(op_heads(&w.root), before, "no operation");
    close_handle(handle);
}

/// An unknown remote: `jj.remote_not_found` with the name and jj's message in `context`.
#[test]
fn remote_changes_unknown_remote_returns_jj_remote_not_found() {
    let w = world();
    let handle = open_handle(&w.root);
    let (code, context) = error_code(&poll(handle, Some("nope"), 0));
    assert_eq!(code.as_deref(), Some(JJ_REMOTE_NOT_FOUND));
    assert_eq!(context.as_deref(), Some("nope\nNo git remote named 'nope'"));
    close_handle(handle);
}

/// A native backend: `jj.not_a_git_repo`, no `context`.
#[test]
fn remote_changes_on_a_native_backend_returns_jj_not_a_git_repo() {
    test_helpers::pin_test_env();
    let native = TempDir::new().unwrap();
    Repo::init(&InitOptions {
        path: native.path().to_owned(),
        ..Default::default()
    })
    .result
    .expect("native init");
    let handle = open_handle(native.path());
    let (code, context) = error_code(&poll(handle, Some("origin"), 0));
    assert_eq!(code.as_deref(), Some(JJ_NOT_A_GIT_REPO));
    assert_eq!(context, None);
    close_handle(handle);
}

/// A null remote name: `ffi.null_pointer`.
#[test]
fn remote_changes_null_remote_returns_ffi_null_pointer() {
    let w = world();
    let handle = open_handle(&w.root);
    let (code, _) = error_code(&poll(handle, None, 0));
    assert_eq!(code.as_deref(), Some(FFI_NULL_POINTER));
    close_handle(handle);
}

/// A zero handle: `ffi.invalid_handle`.
#[test]
fn remote_changes_zero_handle_returns_ffi_invalid_handle() {
    let (code, _) = error_code(&poll(0, Some("origin"), 0));
    assert_eq!(code.as_deref(), Some(FFI_INVALID_HANDLE));
}

/// A token cancelled before the call: `jj.cancelled`, context "Cancelled".
#[test]
fn remote_changes_with_a_cancelled_token_returns_jj_cancelled() {
    let w = world();
    let handle = open_handle(&w.root);
    let token = zanshin_network_token();
    zanshin_network_cancel(token);
    let (code, context) = error_code(&poll(handle, Some("origin"), token));
    assert_eq!(code.as_deref(), Some(JJ_CANCELLED));
    assert_eq!(context.as_deref(), Some("Cancelled"));
    close_handle(handle);
}
