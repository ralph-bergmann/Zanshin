// SPDX-License-Identifier: MIT

//! `zanshin_environment_adopt` — the app's start-up adoption of the login shell's environment
//! (Story 9.36).
//!
//! Calls `zanshin_jj::adopt_login_shell_environment` and answers with an ok `Envelope` carrying
//! no payload, only the call's warnings (none, or one `env.login_shell_unresolved`). HANDLE-LESS:
//! it runs before any repo is opened, so the ladder is null → verify → kind — no handle rung, and
//! no field of the request is required (`shell` absent = `$SHELL`, `timeout_ms` a scalar).

use std::ffi::OsString;
use std::time::Duration;

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;

use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, reject_null_request, CallReport, FfiErrorObj,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};

struct AdoptReq {
    shell: Option<OsString>,
    timeout: Duration,
}

/// Same discipline as every other noun module's reader: `data`/`len` describe a caller-owned
/// buffer Dart builds and frees itself; the byte slice is built in this scope and an OWNED struct
/// is returned, so the unbounded lifetime `from_raw_parts` produces cannot escape.
///
/// # Errors
/// - `ffi.null_pointer` / `ffi.invalid_argument` — null, unverifiable or mis-tagged buffer.
fn read_adopt_request(data: *const u8, len: usize) -> Result<AdoptReq, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::EnvironmentAdoptRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::EnvironmentAdopt)?;
    Ok(AdoptReq {
        shell: req.shell().map(OsString::from),
        timeout: Duration::from_millis(u64::from(req.timeout_ms())),
    })
}

/// The ok `Envelope`: NO `data` (there is no `Payload` member for it), the warnings only.
fn adopted_to_envelope(report: &CallReport) -> Vec<u8> {
    finish_envelope(FlatBufferBuilder::with_capacity(256), fbs::Payload::NONE, None, report)
}

/// Adopt the login shell's environment for every jj environment read (Story 9.36): runs
/// `<shell> -l -i -c` once (`shell` absent: the process's `$SHELL`), reads its `env -0` dump
/// within `timeout_ms`, and from then on the jj config stack and the `git` subprocess of a fetch
/// or clone see that environment — the terminal `jj`'s — instead of the one the app was started
/// with. Meant for app start-up, before any repo is opened; a second call after a successful one
/// is a no-op. The arguments cross as an `EnvironmentAdoptRequest` buffer.
///
/// Returns an ok `Envelope` with NO `data`. Its `warnings` are empty on success and carry exactly
/// one `env.login_shell_unresolved` when the environment could not be read — the shell could not
/// start, exited without printing it, or timed out; nothing is adopted then and the environment
/// the app was started with stays in effect.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as an `EnvironmentAdoptRequest`, or its
///   `kind` is not `EnvironmentAdopt`.
///
/// # Safety
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart; Rust only borrows it for the call. The returned token must be freed exactly once via
/// `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_environment_adopt(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_environment_adopt");
    vec_into_token(catch(|| {
        let req = read_adopt_request(data, len)?;
        let warnings = zanshin_jj::adopt_login_shell_environment(req.shell.as_deref(), req.timeout);
        Ok(adopted_to_envelope(&CallReport::warnings(warnings)))
    }))
}
