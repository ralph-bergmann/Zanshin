// SPDX-License-Identifier: MIT

//! Story 9.20: `zanshin_git_push` on the wire — the `GitPushRequest` reader (absent vs
//! present-empty, a malformed buffer, a wrong kind, null pointers), the zero handle, a refusal
//! envelope, a `GitPushResult` after a real push to a local bare remote — and
//! `zanshin_repo_clone`'s progress events carrying the new handle's session id. Story 9.52 adds
//! the cancel tokens: a clone whose token is its session id, a cancelled clone and a cancelled
//! push. No network: the remotes are local bare repositories.

use std::ffi::CString;
use std::fs;
use std::ops::ControlFlow;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use flatbuffers::FlatBufferBuilder;
use zanshin_ffi::events::{zanshin_events_register, zanshin_events_unregister};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::push::zanshin_git_push;
use zanshin_ffi::repo::{
    zanshin_network_cancel, zanshin_network_token, zanshin_repo_clone, zanshin_repo_close, zanshin_repo_open,
};
use zanshin_ffi::{FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CANCELLED, JJ_INVALID_INPUT};

/// Reads the envelope a token carries and frees it.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null());
    // SAFETY: a token every wrapper returns is a valid, live `ZanshinBuf`.
    let bytes = unsafe { std::slice::from_raw_parts((*token).ptr, (*token).len) }.to_vec();
    // SAFETY: freed exactly once, here.
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

fn envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fbs::root_as_envelope(bytes).expect("the envelope verifies")
}

fn git(args: &[&str], dir: &Path) {
    let status = Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git spawns");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// A git repo with `main` (one commit) and its bare clone; returns `(source, bare)`.
fn remote(parent: &Path) -> (PathBuf, PathBuf) {
    let src = parent.join("src");
    fs::create_dir_all(&src).unwrap();
    git(&["init", "--initial-branch=main"], &src);
    git(&["config", "user.email", "test@zanshin.test"], &src);
    git(&["config", "user.name", "Fixture"], &src);
    fs::write(src.join("README.md"), "hello").unwrap();
    git(&["add", "."], &src);
    git(&["commit", "-m", "initial"], &src);
    let bare = parent.join("remote.git");
    git(
        &["clone", "--bare", &src.to_string_lossy(), &bare.to_string_lossy()],
        parent,
    );
    (src, bare)
}

/// A `GitPushRequest` with `kind`, `dry_run`, and `remotes` / `bookmarks` / `all` as given.
fn push_request(kind: fbs::RequestKind, remotes: Option<&[&str]>, bookmarks: &[&str], all: bool) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let mut strings = |items: &[&str]| {
        let offsets: Vec<_> = items.iter().map(|item| b.create_string(item)).collect();
        b.create_vector(&offsets)
    };
    let remotes = remotes.map(&mut strings);
    let bookmarks = strings(bookmarks);
    let req = fbs::GitPushRequest::create(
        &mut b,
        &fbs::GitPushRequestArgs {
            kind,
            remotes,
            bookmarks: Some(bookmarks),
            all,
            ..Default::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn open(root: &Path) -> (u64, u64) {
    let path = CString::new(root.to_str().unwrap()).unwrap();
    let bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let env = envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let handle = env.data_as_repo_handle().expect("RepoHandle");
    (handle.handle(), handle.session_id())
}

fn close(handle: u64) {
    let bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(envelope(&bytes).ok());
}

fn push(handle: u64, request: &[u8]) -> Vec<u8> {
    unsafe { read_and_free(zanshin_git_push(handle, request.as_ptr(), request.len())) }
}

/// A non-colocated jj clone of `bare` at `<parent>/ws` whose `main` moved onto a new described
/// commit with `@` on top — ready for a bare push.
fn pushable(parent: &Path, bare: &Path) -> PathBuf {
    test_helpers::pin_test_env();
    let root = parent.join("ws");
    let mut repo = zanshin_jj::Repo::clone(
        &zanshin_jj::CloneOptions {
            source: bare.to_string_lossy().into_owned(),
            destination: root.clone(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result
    .expect("clone");
    let mut main = String::new();
    let _ = repo
        .eval_revset("main", |change| {
            main = change.commit_id.0;
            ControlFlow::Break(())
        })
        .expect("revset");
    let root = fs::canonicalize(root).unwrap();
    let next = test_helpers::add_commit_with_files(&root, &[&main], &[("next.txt", "next")], "next");
    test_helpers::set_local_bookmark(&root, "main", &[&next]);
    let mut repo = zanshin_jj::Repo::open(&root).expect("reopen");
    let mut change = None;
    let _ = repo
        .eval_revset(&next, |c| {
            change = Some(c.id);
            ControlFlow::Break(())
        })
        .expect("revset");
    repo.new_change(&[change.expect("next")], &[], &[]).expect("new @");
    root
}

#[test]
fn a_real_push_returns_its_result_on_the_wire() {
    let tmp = tempfile::TempDir::new().unwrap();
    let (_src, bare) = remote(tmp.path());
    let root = pushable(tmp.path(), &bare);
    let (handle, _) = open(&root);

    let bytes = push(handle, &push_request(fbs::RequestKind::GitPush, None, &[], false));
    let env = envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert!(env.precondition().is_some(), "the push runs the pre-verb snapshot");
    let result = env.data_as_git_push_result().expect("GitPushResult");
    assert!(result.recorded() && !result.dry_run() && result.failure().is_none());
    assert_eq!(result.description(), Some("push bookmark main to git remote origin"));
    let remote = result.remotes().expect("remotes").get(0);
    assert!(remote.finished());
    let row = remote.refs().expect("refs").get(0);
    assert_eq!(row.name(), Some("main"));
    assert_eq!(
        (row.path(), row.status()),
        (fbs::PushPath::Push, fbs::PushRefStatus::Pushed)
    );
    assert!(row.action().is_some_and(|a| a.starts_with("move forward from ")));
    close(handle);
}

/// `remotes` ABSENT is "`--remote` not given" (the default resolves `origin`); present-EMPTY is a
/// pattern list that matches nothing — the CLI's "No git remotes to push to". Conflicting flags
/// refuse on an error envelope that still carries the precondition.
#[test]
fn the_reader_keeps_absent_and_present_empty_apart() {
    let tmp = tempfile::TempDir::new().unwrap();
    let (_src, bare) = remote(tmp.path());
    let root = pushable(tmp.path(), &bare);
    let (handle, _) = open(&root);

    let request = {
        let mut b = FlatBufferBuilder::new();
        let req = fbs::GitPushRequest::create(
            &mut b,
            &fbs::GitPushRequestArgs {
                kind: fbs::RequestKind::GitPush,
                dry_run: true,
                ..Default::default()
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    };
    let bytes = push(handle, &request);
    let env = envelope(&bytes);
    let result = env.data_as_git_push_result().expect("a dry run plans");
    assert!(result.dry_run() && !result.recorded());
    assert_eq!(result.remotes().expect("remotes").get(0).name(), Some("origin"));

    let bytes = push(handle, &push_request(fbs::RequestKind::GitPush, Some(&[]), &[], false));
    let env = envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));
    assert_eq!(env.error().and_then(|e| e.context()), Some("No git remotes to push to"));

    let bytes = push(handle, &push_request(fbs::RequestKind::GitPush, None, &["main"], true));
    let env = envelope(&bytes);
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));
    assert!(
        env.precondition().is_some(),
        "the refusal envelope carries the snapshot report"
    );
    close(handle);
}

#[test]
fn malformed_requests_and_handles_are_refused() {
    let tmp = tempfile::TempDir::new().unwrap();
    let (_src, bare) = remote(tmp.path());
    let root = pushable(tmp.path(), &bare);
    let (handle, _) = open(&root);
    for (request, code) in [
        (
            push_request(fbs::RequestKind::Squash, None, &[], false),
            FFI_INVALID_ARGUMENT,
        ),
        (vec![0, 1, 2], FFI_INVALID_ARGUMENT),
    ] {
        let env_bytes = push(handle, &request);
        assert_eq!(envelope(&env_bytes).error().and_then(|e| e.code()), Some(code));
    }
    let bytes = unsafe { read_and_free(zanshin_git_push(handle, std::ptr::null(), 0)) };
    assert_eq!(envelope(&bytes).error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));
    let request = push_request(fbs::RequestKind::GitPush, None, &[], false);
    let bytes = push(0, &request);
    assert_eq!(
        envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );
    close(handle);
}

static RECEIVED: Mutex<Vec<Vec<u8>>> = Mutex::new(Vec::new());

/// Serializes the tests of this binary that register the process-global event sink — a second
/// registration would replace the first test's sink mid-run. Hold it from register to
/// unregister.
static SINK_GUARD: Mutex<()> = Mutex::new(());

fn received() -> MutexGuard<'static, Vec<Vec<u8>>> {
    RECEIVED.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

unsafe extern "C" fn sink(token: *mut ZanshinBuf) {
    // SAFETY: the `EventCallback` contract — a valid token from `events::dispatch`.
    let bytes = unsafe { read_and_free(token) };
    received().push(bytes);
}

/// A clone's progress events carry the session id its new handle gets — allocated before the
/// clone ran. The sink is process-global: the other tests' pushes dispatch their progress
/// through it too, so only this clone's session id is asserted on.
#[test]
fn clone_progress_carries_the_new_handles_session_id() {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let (src, _bare) = remote(tmp.path());
    let target = tmp.path().join("cloned");
    let request = {
        let mut b = FlatBufferBuilder::new();
        let source = b.create_string(&format!("file://{}", src.display()));
        let destination = b.create_string(target.to_str().unwrap());
        let req = fbs::RepoCloneRequest::create(
            &mut b,
            &fbs::RepoCloneRequestArgs {
                kind: fbs::RequestKind::RepoClone,
                source: Some(source),
                destination: Some(destination),
                no_colocate: true,
                ..Default::default()
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    };
    let _sink_guard = SINK_GUARD.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    received().clear();
    zanshin_events_register(Some(sink));
    let bytes = unsafe { read_and_free(zanshin_repo_clone(request.as_ptr(), request.len())) };
    let env = envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let handle = env.data_as_repo_handle().expect("RepoHandle");
    let (raw, session_id) = (handle.handle(), handle.session_id());

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut progress = Vec::new();
    while progress.is_empty() && Instant::now() < deadline {
        for raw in std::mem::take(&mut *received()) {
            let event = envelope(&raw);
            if event.data_as_progress().is_some_and(|p| p.session_id() == session_id) {
                progress.push(raw);
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    zanshin_events_unregister();
    assert!(
        !progress.is_empty(),
        "a local clone reports progress under its new handle's session id"
    );
    for raw in &progress {
        let event = envelope(raw).data_as_progress().expect("Progress");
        assert_eq!(event.operation(), Some("clone"));
    }
    close(raw);
}

/// A `RepoCloneRequest` of `src` into `target`, not colocated, under `cancel_token`.
fn clone_request(src: &Path, target: &Path, cancel_token: u64) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let source = b.create_string(&format!("file://{}", src.display()));
    let destination = b.create_string(target.to_str().unwrap());
    let req = fbs::RepoCloneRequest::create(
        &mut b,
        &fbs::RepoCloneRequestArgs {
            kind: fbs::RequestKind::RepoClone,
            source: Some(source),
            destination: Some(destination),
            no_colocate: true,
            cancel_token,
            ..Default::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Story 9.52: tokens are fresh non-zero ids; cancelling `0`, an unknown or a finished token is a
/// no-op.
#[test]
fn network_tokens_are_fresh_and_cancelling_an_unknown_one_is_a_no_op() {
    let first = zanshin_network_token();
    let second = zanshin_network_token();
    assert!(first != 0 && second > first);
    zanshin_network_cancel(0);
    zanshin_network_cancel(u64::MAX);
    zanshin_network_cancel(first);
    zanshin_network_cancel(first);
}

/// Story 9.52: a clone with a token uses it as the new session's id, so its progress events —
/// dispatched while the clone runs — carry the token.
#[test]
fn a_clone_with_a_token_uses_it_as_its_session_id() {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let (src, _bare) = remote(tmp.path());
    let token = zanshin_network_token();
    let request = clone_request(&src, &tmp.path().join("cloned"), token);
    let _sink_guard = SINK_GUARD.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    received().clear();
    zanshin_events_register(Some(sink));
    let bytes = unsafe { read_and_free(zanshin_repo_clone(request.as_ptr(), request.len())) };
    let env = envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let handle = env.data_as_repo_handle().expect("RepoHandle");
    assert_eq!(handle.session_id(), token);

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut progress = 0;
    while progress == 0 && Instant::now() < deadline {
        for raw in std::mem::take(&mut *received()) {
            if envelope(&raw)
                .data_as_progress()
                .is_some_and(|p| p.session_id() == token)
            {
                progress += 1;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    zanshin_events_unregister();
    assert!(progress > 0, "the clone's progress carries its token");
    close(handle.handle());
}

/// Story 9.52: a finished token is no live token, so a clone passing it again gets a fresh
/// session id instead of colliding with the session that already took it.
#[test]
fn a_clone_with_a_finished_token_gets_a_fresh_session_id() {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let (src, _bare) = remote(tmp.path());
    let token = zanshin_network_token();
    let mut session_ids = Vec::new();
    for target in ["first", "second"] {
        let request = clone_request(&src, &tmp.path().join(target), token);
        let bytes = unsafe { read_and_free(zanshin_repo_clone(request.as_ptr(), request.len())) };
        let env = envelope(&bytes);
        assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
        let handle = env.data_as_repo_handle().expect("RepoHandle");
        session_ids.push(handle.session_id());
        close(handle.handle());
    }
    assert_eq!(session_ids[0], token, "the live token is the first clone's session id");
    assert_ne!(session_ids[1], token, "the finished token is not reused");
    assert_ne!(session_ids[1], 0);
}

/// Story 9.52: a clone whose token was cancelled before it ran refuses as `jj.cancelled` and
/// removes the folder it created.
#[test]
fn a_cancelled_clone_refuses_as_cancelled() {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let (src, _bare) = remote(tmp.path());
    let target = tmp.path().join("cancelled");
    let token = zanshin_network_token();
    zanshin_network_cancel(token);
    let request = clone_request(&src, &target, token);
    let bytes = unsafe { read_and_free(zanshin_repo_clone(request.as_ptr(), request.len())) };
    let env = envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CANCELLED));
    assert_eq!(env.error().and_then(|e| e.context()), Some("Cancelled"));
    assert!(!target.exists(), "the clone's clean-up removed what it created");
}

/// Story 9.52: a push whose token was cancelled before it ran reports the cancel as data —
/// `failure.kind = Cancelled`, nothing recorded, no remote finished.
#[test]
fn a_cancelled_push_reports_the_cancel_as_data() {
    let tmp = tempfile::TempDir::new().unwrap();
    let (_src, bare) = remote(tmp.path());
    let root = pushable(tmp.path(), &bare);
    let (handle, _) = open(&root);
    let token = zanshin_network_token();
    zanshin_network_cancel(token);
    let request = {
        let mut b = FlatBufferBuilder::new();
        let req = fbs::GitPushRequest::create(
            &mut b,
            &fbs::GitPushRequestArgs {
                kind: fbs::RequestKind::GitPush,
                cancel_token: token,
                ..Default::default()
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    };
    let bytes = push(handle, &request);
    let env = envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let result = env.data_as_git_push_result().expect("GitPushResult");
    let failure = result.failure().expect("failed");
    assert_eq!(failure.kind(), fbs::PushFailureKind::Cancelled);
    assert_eq!(failure.message(), Some("Cancelled"));
    assert!(!result.recorded());
    assert!(!result.remotes().expect("remotes").get(0).finished());
    close(handle);
}
