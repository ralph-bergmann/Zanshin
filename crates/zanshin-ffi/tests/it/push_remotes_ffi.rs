// SPDX-License-Identifier: MIT

//! Integration tests for `zanshin_git_push_remotes` (Story 9.54) and `zanshin_git_fetch_remotes`
//! (Story 9.30): the remotes `jj git push` / `jj git fetch` without `--remote` would use.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. Remotes are added in-test with fake
//! local URLs — the committed fixtures have none, and nothing is fetched or pushed.

use std::ffi::CString;
use std::path::PathBuf;

use flatbuffers::root as fb_root;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::remotes::{zanshin_git_fetch_remotes, zanshin_git_push_remotes};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{FFI_INVALID_HANDLE, JJ_CONFIG_ERROR, JJ_FETCH_REMOTES_UNMATCHED, JJ_NOT_A_GIT_REPO};
use zanshin_jj::{Backend, ConfigScope, ConfigTarget, Repo};

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by a `zanshin_*` function and not
/// yet freed.
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

/// A Git-backed repo with `remotes` added, open through the FFI.
struct Fx {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    handle: u64,
}

impl Drop for Fx {
    fn drop(&mut self) {
        // SAFETY: the handle came from `zanshin_repo_open` below and is closed exactly once.
        let bytes = unsafe { read_and_free(zanshin_repo_close(self.handle)) };
        assert!(parse_envelope(&bytes).ok());
    }
}

fn repo_with(remotes: &[&str]) -> Fx {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().expect("tempdir");
    let mut repo = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_path_buf(),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init");
    for name in remotes {
        let url = tmp.path().join(format!("{name}.git"));
        repo.git_remote_add(name, &url.to_string_lossy(), None)
            .expect("add remote");
    }
    open(tmp, repo.workspace_root().to_owned())
}

/// A native-backend repo, open through the FFI.
fn native_repo() -> Fx {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().expect("tempdir");
    let repo = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_path_buf(),
        ..Default::default()
    })
    .result
    .expect("init");
    open(tmp, repo.workspace_root().to_owned())
}

fn open(tmp: tempfile::TempDir, root: PathBuf) -> Fx {
    let path = CString::new(root.to_str().expect("UTF-8 path")).expect("no NUL");
    // SAFETY: `path` is a valid NUL-terminated C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let handle = parse_envelope(&bytes)
        .data_as_repo_handle()
        .expect("RepoHandle payload")
        .handle();
    Fx {
        _tmp: tmp,
        root,
        handle,
    }
}

fn names(fx: &Fx) -> Vec<String> {
    // SAFETY: `fx.handle` is open.
    let bytes = unsafe { read_and_free(zanshin_git_push_remotes(fx.handle)) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::GitPushRemotes);
    env.data_as_git_push_remotes()
        .expect("GitPushRemotes payload")
        .names()
        .map(|v| v.iter().map(ToOwned::to_owned).collect())
        .unwrap_or_default()
}

/// `origin` among several remotes; no remote at all is an empty list.
#[test]
fn the_default_push_remotes_cross_the_wire() {
    assert_eq!(names(&repo_with(&["origin", "upstream"])), ["origin"]);
    assert!(names(&repo_with(&[])).is_empty());
}

/// A wrong-typed `git.push` refuses with `jj.config_error`.
#[test]
fn a_wrong_typed_git_push_is_a_config_error() {
    let fx = repo_with(&["origin"]);
    zanshin_jj::config_set(Some(&fx.root), &ConfigTarget::Scope(ConfigScope::Repo), "git.push", "1")
        .result
        .expect("config set");
    // SAFETY: `fx.handle` is open.
    let bytes = unsafe { read_and_free(zanshin_git_push_remotes(fx.handle)) };
    let env = parse_envelope(&bytes);
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CONFIG_ERROR));
}

/// A native backend is refused with `jj.not_a_git_repo` by both queries, as the push and the
/// fetch refuse it.
#[test]
fn a_native_backend_is_not_a_git_repo() {
    let fx = native_repo();
    for query in [zanshin_git_push_remotes, zanshin_git_fetch_remotes] {
        // SAFETY: `fx.handle` is open.
        let bytes = unsafe { read_and_free(query(fx.handle)) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok());
        assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_NOT_A_GIT_REPO));
    }
}

/// Handle `0` is never valid.
#[test]
fn an_invalid_handle_is_refused() {
    test_helpers::pin_test_env();
    // SAFETY: `0` is detected and refused.
    let bytes = unsafe { read_and_free(zanshin_git_push_remotes(0)) };
    let env = parse_envelope(&bytes);
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_HANDLE));
}

/// Story 9.30: `zanshin_git_fetch_remotes` answers the fetch's default resolution — the Fetch
/// button's enable rule. `origin` among several; the only remote; with several and no `origin`
/// nothing, with `jj.fetch_remotes_unmatched` for the implicit `origin`.
#[test]
fn the_default_fetch_remotes_cross_the_wire() {
    let fetch_names = |fx: &Fx| -> (Vec<String>, Vec<(String, String)>) {
        // SAFETY: `fx.handle` is open.
        let bytes = unsafe { read_and_free(zanshin_git_fetch_remotes(fx.handle)) };
        let env = parse_envelope(&bytes);
        assert!(env.ok(), "{:?}", env.error().and_then(|e| e.code()));
        assert_eq!(env.data_type(), fbs::Payload::GitFetchRemotes);
        let names = env
            .data_as_git_fetch_remotes()
            .expect("GitFetchRemotes payload")
            .names()
            .map(|v| v.iter().map(ToOwned::to_owned).collect())
            .unwrap_or_default();
        let warnings = env
            .warnings()
            .map(|v| {
                v.iter()
                    .map(|w| {
                        (
                            w.code().unwrap_or_default().to_owned(),
                            w.message().unwrap_or_default().to_owned(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        (names, warnings)
    };
    assert_eq!(
        fetch_names(&repo_with(&["origin", "upstream"])),
        (vec!["origin".to_owned()], vec![])
    );
    assert_eq!(fetch_names(&repo_with(&["fork"])), (vec!["fork".to_owned()], vec![]));
    let (names, warnings) = fetch_names(&repo_with(&["a", "b"]));
    assert!(names.is_empty());
    assert_eq!(
        warnings,
        [(
            JJ_FETCH_REMOTES_UNMATCHED.to_owned(),
            "No matching remotes for names: origin".to_owned()
        )]
    );
    // SAFETY: handle 0 is detected and refused.
    let bytes = unsafe { read_and_free(zanshin_git_fetch_remotes(0)) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE)
    );
}
