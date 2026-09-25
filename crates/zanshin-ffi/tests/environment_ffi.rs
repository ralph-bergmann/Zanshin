// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.36's `zanshin_environment_adopt` — the wire contract: the
//! handle-less refusal ladder (null → verify → kind → fields) and one successful install
//! answering ok with NO payload and no warnings. How the store serves the adopted map is pinned
//! in `crates/zanshin-jj` (`src/environment.rs`, `tests/login_shell_environment.rs`). Every
//! buffer is read through the generated typed accessors and the Verifier.
//!
//! The install is write-once and process-wide, so exactly ONE test here installs (this binary
//! is its own process; the refusal tests read no environment), and it checks the result through
//! a public reader — the config stack.

use flatbuffers::{root as fb_root, FlatBufferBuilder};
use zanshin_ffi::environment::zanshin_environment_adopt;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::zanshin_buffer_free_token;
use zanshin_ffi::{FFI_INVALID_ARGUMENT, FFI_NULL_POINTER, JJ_INVALID_INPUT};

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

/// The error envelope's `(code, context)`.
fn error(bytes: &[u8]) -> (String, Option<String>) {
    let env = envelope(bytes);
    assert!(!env.ok(), "expected an error envelope");
    let error = env.error().expect("an error table");
    (
        error.code().unwrap_or_default().to_owned(),
        error.context().map(ToOwned::to_owned),
    )
}

/// One variable as it crosses: `name`/`value` absent for `None`.
type Variable<'a> = (Option<&'a [u8]>, Option<&'a [u8]>);

/// A request tagged `kind`; `variables: None` leaves the vector absent.
fn request(kind: fbs::RequestKind, variables: Option<&[Variable<'_>]>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let variables = variables.map(|variables| {
        let entries: Vec<_> = variables
            .iter()
            .map(|(name, value)| {
                let name = name.map(|name| b.create_vector(name));
                let value = value.map(|value| b.create_vector(value));
                fbs::EnvironmentVariable::create(&mut b, &fbs::EnvironmentVariableArgs { name, value })
            })
            .collect();
        b.create_vector(&entries)
    });
    let r = fbs::EnvironmentAdoptRequest::create(&mut b, &fbs::EnvironmentAdoptRequestArgs { kind, variables });
    b.finish(r, None);
    b.finished_data().to_vec()
}

const ONE: &[Variable<'static>] = &[(Some(b"JJ_USER".as_slice()), Some(b"x".as_slice()))];

#[test]
fn the_wrapper_refuses_null_garbage_and_a_mis_routed_buffer() {
    assert_eq!(error(&call(None)).0, FFI_NULL_POINTER);
    assert_eq!(error(&call(Some(&[1, 2, 3]))).0, FFI_INVALID_ARGUMENT);
    let wrong = request(fbs::RequestKind::ConfigGcList, Some(ONE));
    assert_eq!(error(&call(Some(&wrong))).0, FFI_INVALID_ARGUMENT);
    let untagged = request(fbs::RequestKind::Unspecified, Some(ONE));
    assert_eq!(error(&call(Some(&untagged))).0, FFI_INVALID_ARGUMENT);
}

#[test]
fn an_absent_or_empty_environment_and_a_nameless_variable_are_refused() {
    let kind = fbs::RequestKind::EnvironmentAdopt;
    let variables_required = (JJ_INVALID_INPUT.to_owned(), Some("variables is required".to_owned()));
    assert_eq!(error(&call(Some(&request(kind, None)))), variables_required);
    assert_eq!(error(&call(Some(&request(kind, Some(&[]))))), variables_required);

    let nameless: &[Variable<'_>] = &[
        (Some(b"JJ_USER".as_slice()), Some(b"x".as_slice())),
        (None, Some(b"y".as_slice())),
    ];
    assert_eq!(
        error(&call(Some(&request(kind, Some(nameless))))),
        (
            JJ_INVALID_INPUT.to_owned(),
            Some("variables[1].name is required".to_owned())
        )
    );
    let empty_name: &[Variable<'_>] = &[(Some(b"".as_slice()), Some(b"y".as_slice()))];
    assert_eq!(
        error(&call(Some(&request(kind, Some(empty_name))))),
        (
            JJ_INVALID_INPUT.to_owned(),
            Some("variables[0].name is required".to_owned())
        )
    );
}

#[test]
fn an_environment_is_installed_and_answered_with_no_payload_and_no_warnings() {
    let installed: &[Variable<'_>] = &[
        // No user config file at all, whatever the process environment says.
        (Some(b"JJ_CONFIG".as_slice()), Some(b"".as_slice())),
        (Some(b"JJ_USER".as_slice()), Some(b"FFI Shell User".as_slice())),
        // An absent value is the empty value.
        (Some(b"JJ_EMAIL".as_slice()), None),
        (Some(b"RAW".as_slice()), Some(b"x\xffy".as_slice())),
    ];
    let bytes = call(Some(&request(fbs::RequestKind::EnvironmentAdopt, Some(installed))));
    let env = envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.code()));
    assert_eq!(env.data_type(), fbs::Payload::NONE);
    assert!(env.precondition().is_none());
    assert!(env.warnings().is_none(), "no warnings vector");

    // The config stack now reads the installed map — and only it.
    assert_eq!(
        zanshin_jj::config_get(None, "user.name").result.expect("user.name"),
        "FFI Shell User"
    );
    assert_eq!(
        zanshin_jj::config_get(None, "user.email").result.expect("user.email"),
        ""
    );
}
