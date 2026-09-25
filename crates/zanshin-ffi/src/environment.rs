// SPDX-License-Identifier: MIT

//! `zanshin_environment_adopt` — the app's start-up adoption of the login shell's environment
//! (Story 9.36).
//!
//! The app reads the login shell's environment itself (`zanshin_core`'s
//! `readLoginShellEnvironment`) and hands the map over here; `zanshin_jj::adopt_environment`
//! keeps it for every jj environment read. The answer is an ok `Envelope` carrying no payload
//! and no warnings — a login shell that could not be read never reaches this call. HANDLE-LESS:
//! it runs before any repo is opened, so the ladder is null → verify → kind → fields, with no
//! handle rung.

use std::collections::HashMap;
use std::ffi::OsString;
use std::os::unix::ffi::OsStringExt as _;

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;

use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, missing_field, reject_null_request, CallReport,
    FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};

/// Same discipline as every other noun module's reader: `data`/`len` describe a caller-owned
/// buffer Dart builds and frees itself; the byte slice is built in this scope and an OWNED map
/// is returned, so the unbounded lifetime `from_raw_parts` produces cannot escape. Names and
/// values are copied byte for byte — an environment is not guaranteed UTF-8.
///
/// # Errors
/// - `ffi.null_pointer` / `ffi.invalid_argument` — null, unverifiable or mis-tagged buffer.
/// - `jj.invalid_input` — `variables` absent or empty, or an entry without a `name` or with an
///   empty one.
fn read_adopt_request(data: *const u8, len: usize) -> Result<HashMap<OsString, OsString>, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::EnvironmentAdoptRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::EnvironmentAdopt)?;
    // An empty environment is never a login shell's: refused like an absent one.
    let variables = req
        .variables()
        .filter(|variables| !variables.is_empty())
        .ok_or_else(|| missing_field("variables"))?;
    variables
        .iter()
        .enumerate()
        .map(|(i, variable)| {
            let name = variable
                .name()
                .filter(|name| !name.is_empty())
                .ok_or_else(|| missing_field(&format!("variables[{i}].name")))?;
            // An absent value is the empty value.
            let value = variable.value().map(|value| value.bytes().to_vec()).unwrap_or_default();
            Ok((OsString::from_vec(name.bytes().to_vec()), OsString::from_vec(value)))
        })
        .collect()
}

/// The ok `Envelope`: NO `data` (there is no `Payload` member for it) and no warnings.
fn adopted_to_envelope() -> Vec<u8> {
    finish_envelope(
        FlatBufferBuilder::with_capacity(256),
        fbs::Payload::NONE,
        None,
        &CallReport::default(),
    )
}

/// The whole of [`zanshin_environment_adopt`], outside the `extern "C"` item so the cargo tests
/// that drive the wrapper credit its lines.
fn adopt(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_environment_adopt");
    vec_into_token(catch(|| {
        zanshin_jj::adopt_environment(read_adopt_request(data, len)?);
        Ok(adopted_to_envelope())
    }))
}

/// Adopt the login shell's environment for every jj environment read (Story 9.36): the app reads
/// it at start-up (`$SHELL -l -i -c`, an `env -0` dump) and passes every variable in an
/// `EnvironmentAdoptRequest` buffer — names and values as raw bytes. From then on the jj config
/// stack and the `git` subprocess of a fetch or clone see that environment — the terminal `jj`'s
/// — instead of the one the app was started with, which itself is never changed. Meant for app
/// start-up, before any repo is opened; a call after a successful one is a no-op (the first
/// environment stays).
///
/// Returns an ok `Envelope` with NO `data` and no warnings.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `EnvironmentAdoptRequest`, or its
///   `kind` is not `EnvironmentAdopt`.
/// - `jj.invalid_input` — `variables` is absent or empty, or one of its entries has no `name` or
///   an empty one; nothing is adopted.
///
/// # Safety
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart; Rust only borrows it for the call. The returned token must be freed exactly once via
/// `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_environment_adopt(data: *const u8, len: usize) -> *mut ZanshinBuf {
    adopt(data, len)
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt as _;

    use flatbuffers::FlatBufferBuilder;

    use super::read_adopt_request;
    use crate::fbs;

    /// A request carrying `variables` as (name, value) byte pairs; `None` leaves a value absent.
    fn request(variables: &[(&[u8], Option<&[u8]>)]) -> Vec<u8> {
        let mut b = FlatBufferBuilder::new();
        let entries: Vec<_> = variables
            .iter()
            .map(|(name, value)| {
                let name = Some(b.create_vector(name));
                let value = value.map(|value| b.create_vector(value));
                fbs::EnvironmentVariable::create(&mut b, &fbs::EnvironmentVariableArgs { name, value })
            })
            .collect();
        let variables = Some(b.create_vector(&entries));
        let r = fbs::EnvironmentAdoptRequest::create(
            &mut b,
            &fbs::EnvironmentAdoptRequestArgs {
                kind: fbs::RequestKind::EnvironmentAdopt,
                variables,
            },
        );
        b.finish(r, None);
        b.finished_data().to_vec()
    }

    #[test]
    fn names_and_values_cross_as_raw_bytes_and_an_absent_value_is_empty() {
        let bytes = request(&[
            (b"PATH".as_slice(), Some(b"/opt/bin".as_slice())),
            (b"RAW".as_slice(), Some(b"x\xffy".as_slice())),
            (b"ODD".as_slice(), Some(b"a=b\nc".as_slice())),
            (b"EMPTY".as_slice(), None),
        ]);
        let map = read_adopt_request(bytes.as_ptr(), bytes.len()).expect("a valid request");
        assert_eq!(map.len(), 4);
        assert_eq!(map[&OsString::from("PATH")], OsString::from("/opt/bin"));
        assert_eq!(map[&OsString::from("RAW")], OsString::from_vec(vec![b'x', 0xff, b'y']));
        assert_eq!(map[&OsString::from("ODD")], OsString::from("a=b\nc"));
        assert_eq!(map[&OsString::from("EMPTY")], OsString::new());
    }
}
