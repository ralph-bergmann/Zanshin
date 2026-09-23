// SPDX-License-Identifier: MIT

//! `zanshin_log_defaults` — effective-`jj log`-defaults read FFI wrapper (Story 4.9).
//!
//! Calls `zanshin_jj::Repo::log_defaults()` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying a `LogDefaults` payload. The handle is borrowed
//! (not consumed). The config stack is re-read per call, never cached, so a config file
//! edited between two calls on the same handle is visible in the second.
//!
//! These values are OFFERS: `zanshin_graph_slice`'s `revset` / `prioritize` /
//! `short_prefixes` stay caller pass-throughs (FR-JJ-17). Nothing here is applied silently.

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{ConfigError, LogDefaults};

use crate::envelope::{catch, finish_envelope, session_from_handle, FfiErrorObj, JJ_CONFIG_ERROR};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};

fn map_config_err(e: ConfigError) -> FfiErrorObj {
    match e {
        ConfigError::Load { reason } => FfiErrorObj {
            precondition: None,
            code: JJ_CONFIG_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

/// Serialise a `LogDefaults` into a finished `Envelope<LogDefaults>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): the three strings are built
/// before the table. `synthetic_elided` is an inline scalar.
fn log_defaults_to_envelope(defaults: &LogDefaults) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(512);
    let log = b.create_string(&defaults.log);
    let prioritize = b.create_string(&defaults.log_graph_prioritize);
    let short_prefixes = b.create_string(&defaults.short_prefixes);
    let payload = fbs::LogDefaults::create(
        &mut b,
        &fbs::LogDefaultsArgs {
            log: Some(log),
            log_graph_prioritize: Some(prioritize),
            short_prefixes: Some(short_prefixes),
            synthetic_elided: defaults.synthetic_elided,
        },
    );
    finish_envelope(b, fbs::Payload::LogDefaults, Some(payload.as_union_value()), None)
}

/// Read the effective `jj log` defaults of the repo identified by `handle`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `LogDefaults` payload on success:
/// `revsets.log`, `revsets.log-graph-prioritize`, `revsets.short-prefixes` (falling back
/// to `revsets.log` when the key is absent from every layer — an explicit empty string
/// means disambiguation is disabled and is returned verbatim) and
/// `ui.log-synthetic-elided-nodes`, resolved through the repo's full jj config stack.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` or the borrow yields `None`.
/// - `jj.config_error` — a config file is unreadable or not valid TOML, a `config-id` is
///   malformed, or one of the four values has the wrong type; the offending file path or
///   config key in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been
/// closed. `0` is detected and returned as `ffi.invalid_handle`.
/// A stale non-zero handle is undefined behaviour; the Dart worker's Model-A
/// handle table (Story 3.9) makes a stale handle unreachable.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_log_defaults(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_log_defaults", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let defaults = session.repo.log_defaults().map_err(map_config_err)?;
        Ok(log_defaults_to_envelope(&defaults))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root;
    use zanshin_jj::{ConfigError, LogDefaults};

    use super::{log_defaults_to_envelope, map_config_err};
    use crate::envelope::JJ_CONFIG_ERROR;
    use crate::fbs;

    #[test]
    fn log_defaults_to_envelope_roundtrips_every_field() {
        let defaults = LogDefaults {
            log: "@ | trunk()".to_owned(),
            log_graph_prioritize: "none()".to_owned(),
            // Empty is the meaningful "disambiguation disabled" value, so it must survive
            // as an EMPTY string, not vanish into an absent field.
            short_prefixes: String::new(),
            synthetic_elided: false,
        };
        let buf = log_defaults_to_envelope(&defaults);
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::LogDefaults);
        let payload = env.data_as_log_defaults().expect("expected LogDefaults payload");
        assert_eq!(payload.log(), Some("@ | trunk()"));
        assert_eq!(payload.log_graph_prioritize(), Some("none()"));
        assert_eq!(payload.short_prefixes(), Some(""));
        assert!(!payload.synthetic_elided());
    }

    #[test]
    fn log_defaults_to_envelope_carries_the_builtin_defaults() {
        let defaults = LogDefaults {
            log: zanshin_jj::DEFAULT_LOG_REVSET.to_owned(),
            log_graph_prioritize: zanshin_jj::DEFAULT_GRAPH_PRIORITIZE.to_owned(),
            short_prefixes: zanshin_jj::DEFAULT_LOG_REVSET.to_owned(),
            synthetic_elided: true,
        };
        let buf = log_defaults_to_envelope(&defaults);
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        let payload = env.data_as_log_defaults().expect("expected LogDefaults payload");
        assert_eq!(payload.log(), Some(zanshin_jj::DEFAULT_LOG_REVSET));
        assert_eq!(
            payload.log_graph_prioritize(),
            Some(zanshin_jj::DEFAULT_GRAPH_PRIORITIZE)
        );
        assert_eq!(payload.short_prefixes(), Some(zanshin_jj::DEFAULT_LOG_REVSET));
        assert!(payload.synthetic_elided());
    }

    #[test]
    fn map_config_err_load_maps_to_jj_config_error() {
        let obj = map_config_err(ConfigError::Load {
            reason: "/r/.jj/repo/config.toml: bad TOML".to_owned(),
        });
        assert_eq!(obj.code, JJ_CONFIG_ERROR);
        assert_eq!(obj.context.as_deref(), Some("/r/.jj/repo/config.toml: bad TOML"));
    }
}
