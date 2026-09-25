// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.36's `zanshin_environment_adopt` — the wire contract only: the
//! handle-less refusal ladder (null → verify → kind) and a failing shell answering ok with NO
//! payload and exactly one `env.login_shell_unresolved`. The adoption's behaviour is pinned in
//! `crates/zanshin-jj` (`src/environment.rs`, `tests/login_shell_environment.rs`); nothing here
//! ever adopts, so this binary's environment is never replaced. Every buffer is read through the
//! generated typed accessors and the Verifier.

use flatbuffers::{root as fb_root, FlatBufferBuilder};
use zanshin_ffi::environment::zanshin_environment_adopt;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::zanshin_buffer_free_token;
use zanshin_ffi::{ENV_LOGIN_SHELL_UNRESOLVED, FFI_INVALID_ARGUMENT, FFI_NULL_POINTER};

/// Calls the wrapper with `bytes` (or a null pointer for `None`) and returns the envelope bytes.
fn call(bytes: Option<&[u8]>) -> Vec<u8> {
    let (ptr, len) = bytes.map_or((std::ptr::null(), 0), |b| (b.as_ptr(), b.len()));
    // SAFETY: `ptr` is null or points to `len` live bytes for the call.
    let token = unsafe { zanshin_environment_adopt(ptr, len) };
    assert!(!token.is_null());
    // SAFETY: fresh, non-null token, freed exactly once.
    let out = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    // SAFETY: as above.
    unsafe { zanshin_buffer_free_token(token) };
    out
}

fn envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("a verified Envelope")
}

fn error_code(bytes: &[u8]) -> String {
    let env = envelope(bytes);
    assert!(!env.ok(), "expected an error envelope");
    env.error().and_then(|e| e.code()).unwrap_or_default().to_owned()
}

fn request(kind: fbs::RequestKind, shell: Option<&str>, timeout_ms: u32) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let shell = shell.map(|s| b.create_string(s));
    let r = fbs::EnvironmentAdoptRequest::create(
        &mut b,
        &fbs::EnvironmentAdoptRequestArgs {
            kind,
            shell,
            timeout_ms,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

#[test]
fn the_wrapper_refuses_null_garbage_and_a_mis_routed_buffer() {
    assert_eq!(error_code(&call(None)), FFI_NULL_POINTER);
    assert_eq!(error_code(&call(Some(&[1, 2, 3]))), FFI_INVALID_ARGUMENT);
    let wrong = request(fbs::RequestKind::ConfigGcList, Some("/nonexistent/zanshin-shell"), 1000);
    assert_eq!(error_code(&call(Some(&wrong))), FFI_INVALID_ARGUMENT);
    let untagged = request(fbs::RequestKind::Unspecified, None, 1000);
    assert_eq!(error_code(&call(Some(&untagged))), FFI_INVALID_ARGUMENT);
}

#[test]
fn a_shell_that_cannot_start_answers_ok_with_no_payload_and_one_warning() {
    let bytes = call(Some(&request(
        fbs::RequestKind::EnvironmentAdopt,
        Some("/nonexistent/zanshin-shell"),
        5000,
    )));
    let env = envelope(&bytes);
    assert!(
        env.ok(),
        "a failed read is not an error: {:?}",
        env.error().and_then(|e| e.code())
    );
    assert_eq!(env.data_type(), fbs::Payload::NONE);
    assert!(env.precondition().is_none());
    let warnings: Vec<(String, String)> = env
        .warnings()
        .into_iter()
        .flatten()
        .map(|w| {
            (
                w.code().unwrap_or_default().to_owned(),
                w.message().unwrap_or_default().to_owned(),
            )
        })
        .collect();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].0, ENV_LOGIN_SHELL_UNRESOLVED);
    assert!(
        warnings[0].1.starts_with(
            "Could not read the login-shell environment from /nonexistent/zanshin-shell: could not start it: "
        ),
        "{}",
        warnings[0].1
    );
}
