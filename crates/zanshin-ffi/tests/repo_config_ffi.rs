// SPDX-License-Identifier: MIT

//! Story 9.27 at the outermost surface: the effective jj config stack a repo is opened and
//! created with, seen through the `zanshin_*` envelopes.
//!
//! One `#[test]` in its own binary, for the reason `zanshin-jj/tests/config_identity.rs`
//! gives: it repoints the process-global `JJ_CONFIG` (never unsets it — unset would load the
//! developer's real config) and REMOVES the identity variables every other binary pins, so it
//! can observe an identity-less stack.

use std::ffi::CString;
use std::path::Path;
use std::{env, fs};

use flatbuffers::root as fb_root;
use test_helpers::extract_fixture;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_new_change, zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::status::zanshin_status;
use zanshin_ffi::JJ_CONFIG_ERROR;

/// Sets (or, for `None`, removes) one process environment variable.
fn set_env(name: &str, value: Option<&str>) {
    // SAFETY: single-threaded — this binary contains exactly one #[test].
    unsafe {
        match value {
            Some(v) => env::set_var(name, v),
            None => env::remove_var(name),
        }
    }
}

/// Copies the bytes out of a `ZanshinBuf` token and frees it.
///
/// # Safety
/// `token` must be a valid, non-null token a `zanshin_*` function returned and not yet freed.
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

fn cstr(path: &Path) -> CString {
    CString::new(path.to_str().expect("utf-8 temp path")).expect("no NUL bytes")
}

/// `(code, context)` of an error envelope.
fn error_of(bytes: &[u8]) -> (String, String) {
    let env = parse_envelope(bytes);
    assert!(!env.ok(), "expected an error envelope");
    let err = env.error().expect("an error envelope carries an error");
    (
        err.code().unwrap_or_default().to_owned(),
        err.context().unwrap_or_default().to_owned(),
    )
}

fn change_id_list_bytes(ids: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let offs: Vec<_> = ids.iter().map(|s| b.create_string(s)).collect();
    let vec = b.create_vector(&offs);
    let list = fbs::ChangeIdList::create(
        &mut b,
        &fbs::ChangeIdListArgs {
            kind: fbs::RequestKind::NewChange,
            change_ids: Some(vec),
            ..Default::default()
        },
    );
    b.finish(list, None);
    b.finished_data().to_vec()
}

#[test]
fn the_config_stack_reaches_the_ffi_envelopes() {
    let tmp = tempfile::tempdir().unwrap();
    set_env("XDG_CONFIG_HOME", tmp.path().to_str());
    set_env("GIT_CONFIG_GLOBAL", Some(""));
    for name in ["JJ_USER", "JJ_EMAIL", "JJ_OP_HOSTNAME", "JJ_OP_USERNAME"] {
        set_env(name, None);
    }
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");

    // ── A broken stack refuses the open and the init as `jj.config_error` ──────────────
    let broken = tmp.path().join("broken.toml");
    fs::write(&broken, "not = = toml\n").unwrap();
    set_env("JJ_CONFIG", broken.to_str());
    let path = cstr(&fx.path);
    // SAFETY: `path` is a valid NUL-terminated C string alive for the call; the token is
    // freed exactly once by `read_and_free`.
    let (code, context) = error_of(&unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) });
    assert_eq!(code, JJ_CONFIG_ERROR);
    assert!(
        context.contains("broken.toml"),
        "the path must be named, got: {context}"
    );

    let fresh = tmp.path().join("fresh");
    fs::create_dir_all(&fresh).unwrap();
    let fresh_path = cstr(&fresh);
    // SAFETY: as above.
    let (code, _) = error_of(&unsafe { read_and_free(repo_init(&fresh_path, 0)) });
    assert_eq!(code, JJ_CONFIG_ERROR);
    assert!(!fresh.join(".jj").exists(), "a refused init writes nothing");

    // ── An identity-less stack: the mutation succeeds and says so ──────────────────────
    let empty = tmp.path().join("empty.toml");
    fs::write(&empty, "").unwrap();
    set_env("JJ_CONFIG", empty.to_str());
    // SAFETY: as above.
    let open_bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "an empty identity is not an error");
    let handle = open_env.data_as_repo_handle().expect("RepoHandle").handle();

    // SAFETY: `handle` is the live handle opened above.
    let status_bytes = unsafe { read_and_free(zanshin_status(handle)) };
    let wc = parse_envelope(&status_bytes)
        .data_as_status()
        .expect("Status")
        .working_copy_change_id()
        .expect("@")
        .to_owned();
    let req = change_id_list_bytes(&[&wc]);
    // SAFETY: `req` outlives the call; `handle` is live.
    let bytes = unsafe { read_and_free(zanshin_new_change(handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "new_change must succeed with the empty identity");
    // Story 9.32: the fact rides `Envelope.warnings` as its registered code.
    let warnings: Vec<(String, String)> = env
        .warnings()
        .expect("a committed operation with no identity warns")
        .iter()
        .map(|w| (w.code().unwrap_or("").to_owned(), w.message().unwrap_or("").to_owned()))
        .collect();
    assert_eq!(
        warnings,
        [(
            zanshin_ffi::envelope::JJ_IDENTITY_MISSING.to_owned(),
            "Name and email not configured. Until configured, your commits will be created with the empty \
             identity, and can't be pushed to remotes."
                .to_owned()
        )]
    );

    // SAFETY: `handle` is live and closed exactly once.
    let close = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(parse_envelope(&close).ok());
}

/// `zanshin_repo_init` over a `RepoInitRequest` (Story 9.20): `backend` 0 = native, 1 = git — a git
/// one with `no_colocate`, the internal workspace these rows were written against.
unsafe fn repo_init(path: &std::ffi::CString, backend: i32) -> *mut zanshin_ffi::ffi_strings::ZanshinBuf {
    let mut b = flatbuffers::FlatBufferBuilder::new();
    let path = b.create_string(path.to_str().expect("UTF-8 path"));
    let req = zanshin_ffi::fbs::RepoInitRequest::create(
        &mut b,
        &zanshin_ffi::fbs::RepoInitRequestArgs {
            kind: zanshin_ffi::fbs::RequestKind::RepoInit,
            path: Some(path),
            backend: zanshin_ffi::fbs::InitBackend(u8::try_from(backend).expect("a backend byte")),
            colocate: false,
            no_colocate: backend == 1,
            object_hash: zanshin_ffi::fbs::ObjectHash::Unspecified,
        },
    );
    b.finish(req, None);
    let bytes = b.finished_data();
    // SAFETY: `bytes` is a live, caller-owned request buffer for the duration of the call.
    unsafe { zanshin_ffi::repo::zanshin_repo_init(bytes.as_ptr(), bytes.len()) }
}
