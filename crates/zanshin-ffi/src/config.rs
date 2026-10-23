// SPDX-License-Identifier: MIT

//! `zanshin_config_*` — the nine config-surface wrappers (Story 9.28): the CLI's `jj config
//! list` / `get` / `path` / `set` / `unset` / `edit` (two halves) / `gc` (two halves).
//!
//! Each calls the matching `zanshin_jj::config_*` free function and serialises the result into a
//! `FlatBuffers` `Envelope`. HANDLE-LESS on purpose: the workspace root travels in the request
//! table (absent = no workspace, the CLI's missing `-R`), because a stack only the workspace
//! LOAD refuses must not block the verbs that repair it. Every wrapper therefore has the
//! two-parameter request-buffer shape `(data, len)` and the ladder null → verify → kind →
//! required fields → the verb's own codes (no handle rung).
//!
//! Only `zanshin_config_set` can carry `Envelope.precondition` — iff its `user.name` /
//! `user.email` working-copy check ran the snapshot (the CLI's `check_wc_author`). Every wrapper
//! but the `gc` pair starts, when the request names a workspace root, with the jj CLI's start-up
//! secure-config fix-up (Story 9.37) and carries its notices (`jj.config_migrated`,
//! `jj.config_copied`, `jj.config_regenerated`) as its first `Envelope.warnings`, on the ok AND
//! the error envelope. Every wrapper but the two editor halves then carries its start-up's
//! `jj.config_deprecated` (Story 9.9), on either envelope. After them (Story 9.32):
//! `zanshin_config_set` carries its snapshot's warnings, then `jj.config_working_copy_author`;
//! `zanshin_config_list` `jj.config_nothing_listed`; and `zanshin_config_gc_delete`
//! `jj.config_gc_delete_failed`.

use std::path::PathBuf;

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ConfigCmdError, ConfigListQuery, ConfigScope, ConfigTarget, ConfigValueSource};

use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, missing_field, reject_null_request, CallReport,
    FfiErrorObj, JJ_CONFIG_ERROR, JJ_CONFIG_NOT_FOUND, JJ_CONFIG_PARSE_ERROR, JJ_CONFIG_PATH_NOT_FOUND,
    JJ_CONFIG_UNRECOGNIZED_FILE, JJ_CONFIG_WOULD_DELETE_TABLE, JJ_CONFIG_WOULD_OVERWRITE, JJ_INVALID_INPUT,
    JJ_PATH_NOT_FOUND, JJ_REPO_NOT_FOUND,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};

// ── Request-buffer readers ───────────────────────────────────────────────────
//
// Same discipline as every other noun module's readers: `data`/`len` describe a caller-owned
// buffer Dart builds and frees itself; each reader builds its OWN byte slice in its own scope and
// returns an OWNED struct, so the unbounded lifetime `from_raw_parts` produces cannot escape.

/// A required `ConfigScope`: `Unspecified` (the absent-field default) is a missing field.
fn required_scope(scope: fbs::ConfigScope) -> Result<ConfigScope, FfiErrorObj> {
    match scope {
        fbs::ConfigScope::User => Ok(ConfigScope::User),
        fbs::ConfigScope::Repo => Ok(ConfigScope::Repo),
        fbs::ConfigScope::Workspace => Ok(ConfigScope::Workspace),
        _ => Err(missing_field("scope")),
    }
}

/// The CLI's one-of `--user | --repo | --workspace | --file PATH` (jj 0.45): a present `path` is
/// the `--file` target and excludes a scope (clap's group conflict, `jj.invalid_input`); without
/// it the scope is required.
fn read_target(scope: fbs::ConfigScope, path: Option<&str>) -> Result<ConfigTarget, FfiErrorObj> {
    match (scope, path) {
        (fbs::ConfigScope::Unspecified, Some(path)) => Ok(ConfigTarget::File(path.into())),
        (scope, None) => required_scope(scope).map(ConfigTarget::Scope),
        (_, Some(_)) => Err(FfiErrorObj {
            report: None,
            hints: Vec::new(),
            code: JJ_INVALID_INPUT.to_owned(),
            context: Some("a scope cannot be used with a path".to_owned()),
        }),
    }
}

fn required(value: Option<&str>, field: &str) -> Result<String, FfiErrorObj> {
    value.map(ToOwned::to_owned).ok_or_else(|| missing_field(field))
}

fn opt_path(value: Option<&str>) -> Option<PathBuf> {
    value.map(PathBuf::from)
}

struct ListReq {
    root: Option<PathBuf>,
    query: ConfigListQuery,
}

/// # Errors
/// - `ffi.null_pointer` / `ffi.invalid_argument` — null, unverifiable or mis-tagged buffer.
/// - `jj.invalid_input` — a scope together with `include_defaults` (clap's conflict).
fn read_list_request(data: *const u8, len: usize) -> Result<ListReq, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ConfigListRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::ConfigList)?;
    // `Unspecified` is "no scope flag"; an out-of-range byte is refused like every other reader.
    let scope = match req.scope() {
        fbs::ConfigScope::Unspecified => None,
        other => Some(required_scope(other)?),
    };
    if scope.is_some() && req.include_defaults() {
        return Err(FfiErrorObj {
            report: None,
            hints: Vec::new(),
            code: JJ_INVALID_INPUT.to_owned(),
            context: Some("include_defaults cannot be used with a scope".to_owned()),
        });
    }
    Ok(ListReq {
        root: opt_path(req.workspace_root()),
        query: ConfigListQuery {
            name: req.name().map(ToOwned::to_owned),
            scope,
            include_defaults: req.include_defaults(),
            include_overridden: req.include_overridden(),
        },
    })
}

struct GetReq {
    root: Option<PathBuf>,
    name: String,
}

fn read_get_request(data: *const u8, len: usize) -> Result<GetReq, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ConfigGetRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::ConfigGet)?;
    Ok(GetReq {
        root: opt_path(req.workspace_root()),
        name: required(req.name(), "name")?,
    })
}

struct PathReq {
    root: Option<PathBuf>,
    scope: ConfigScope,
}

fn read_path_request(data: *const u8, len: usize) -> Result<PathReq, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ConfigPathRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::ConfigPath)?;
    Ok(PathReq {
        root: opt_path(req.workspace_root()),
        scope: required_scope(req.scope())?,
    })
}

struct SetReq {
    root: Option<PathBuf>,
    target: ConfigTarget,
    name: String,
    value: String,
}

fn read_set_request(data: *const u8, len: usize) -> Result<SetReq, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ConfigSetRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::ConfigSet)?;
    Ok(SetReq {
        root: opt_path(req.workspace_root()),
        target: read_target(req.scope(), req.path())?,
        name: required(req.name(), "name")?,
        value: required(req.value(), "value")?,
    })
}

struct UnsetReq {
    root: Option<PathBuf>,
    target: ConfigTarget,
    name: String,
}

fn read_unset_request(data: *const u8, len: usize) -> Result<UnsetReq, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ConfigUnsetRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::ConfigUnset)?;
    Ok(UnsetReq {
        root: opt_path(req.workspace_root()),
        target: read_target(req.scope(), req.path())?,
        name: required(req.name(), "name")?,
    })
}

struct FileReadReq {
    root: Option<PathBuf>,
    target: ConfigTarget,
}

fn read_file_read_request(data: *const u8, len: usize) -> Result<FileReadReq, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ConfigFileReadRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::ConfigFileRead)?;
    Ok(FileReadReq {
        root: opt_path(req.workspace_root()),
        target: read_target(req.scope(), req.path())?,
    })
}

struct FileWriteReq {
    root: Option<PathBuf>,
    path: PathBuf,
    text: String,
}

fn read_file_write_request(data: *const u8, len: usize) -> Result<FileWriteReq, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ConfigFileWriteRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::ConfigFileWrite)?;
    Ok(FileWriteReq {
        root: opt_path(req.workspace_root()),
        path: required(req.path(), "path")?.into(),
        text: required(req.text(), "text")?,
    })
}

fn read_gc_list_request(data: *const u8, len: usize) -> Result<(), FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ConfigGcListRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::ConfigGcList)
}

/// An ABSENT `config_dirs` vector is an empty request (nothing to delete).
fn read_gc_delete_request(data: *const u8, len: usize) -> Result<Vec<PathBuf>, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::ConfigGcDeleteRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::ConfigGcDelete)?;
    Ok(req.config_dirs().into_iter().flatten().map(PathBuf::from).collect())
}

// ── Error mapping ─────────────────────────────────────────────────────────────

/// Maps a [`ConfigCmdError`] onto the AR-P-4 taxonomy (Story 9.28).
pub(crate) fn map_config_cmd_err(e: ConfigCmdError) -> FfiErrorObj {
    let hints = e.hints();
    let (code, context) = match e {
        ConfigCmdError::Config { reason } => (JJ_CONFIG_ERROR, reason),
        ConfigCmdError::PathNotFound { path } => (JJ_PATH_NOT_FOUND, path.to_string_lossy().into_owned()),
        ConfigCmdError::NotARepo { path } => (JJ_REPO_NOT_FOUND, path.to_string_lossy().into_owned()),
        ConfigCmdError::NotFound { reason } => (JJ_CONFIG_NOT_FOUND, reason),
        ConfigCmdError::WouldOverwrite { reason } => (JJ_CONFIG_WOULD_OVERWRITE, reason),
        ConfigCmdError::WouldDeleteTable { reason } => (JJ_CONFIG_WOULD_DELETE_TABLE, reason),
        ConfigCmdError::UnrecognizedFile { path } => (JJ_CONFIG_UNRECOGNIZED_FILE, path.to_string_lossy().into_owned()),
        ConfigCmdError::Parse { message, span } => (
            JJ_CONFIG_PARSE_ERROR,
            span.map_or_else(|| message.clone(), |r| format!("{}..{}\n{message}", r.start, r.end)),
        ),
        ConfigCmdError::NoConfigPath { reason } => (JJ_CONFIG_PATH_NOT_FOUND, reason),
    };
    FfiErrorObj {
        report: None,
        hints,
        code: code.to_owned(),
        context: Some(context),
    }
}

// ── Payload builders ─────────────────────────────────────────────────────────

fn wire_source(source: ConfigValueSource) -> fbs::ConfigValueSource {
    match source {
        ConfigValueSource::Default => fbs::ConfigValueSource::Default,
        ConfigValueSource::System => fbs::ConfigValueSource::System,
        ConfigValueSource::EnvBase => fbs::ConfigValueSource::EnvBase,
        ConfigValueSource::User => fbs::ConfigValueSource::User,
        ConfigValueSource::Repo => fbs::ConfigValueSource::Repo,
        ConfigValueSource::Workspace => fbs::ConfigValueSource::Workspace,
        ConfigValueSource::EnvOverrides => fbs::ConfigValueSource::EnvOverrides,
    }
}

/// `to_string_lossy` is the crate's path→wire rule (`repo.rs`).
fn path_str(path: &std::path::Path) -> std::borrow::Cow<'_, str> {
    path.to_string_lossy()
}

fn string_vector<'a>(
    b: &mut FlatBufferBuilder<'a>,
    items: impl Iterator<Item = String>,
) -> flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<&'a str>>> {
    let offsets: Vec<_> = items.map(|s| b.create_string(&s)).collect();
    b.create_vector(&offsets)
}

fn list_to_envelope(entries: &[zanshin_jj::ConfigEntry], report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let rows: Vec<_> = entries
        .iter()
        .map(|e| {
            let name = b.create_string(&e.name);
            let value = b.create_string(&e.value);
            let path = e.path.as_deref().map(|p| b.create_string(&path_str(p)));
            fbs::ConfigEntry::create(
                &mut b,
                &fbs::ConfigEntryArgs {
                    name: Some(name),
                    value: Some(value),
                    source: wire_source(e.source),
                    path,
                    overridden: e.overridden,
                },
            )
        })
        .collect();
    let rows = b.create_vector(&rows);
    let table = fbs::ConfigListResult::create(&mut b, &fbs::ConfigListResultArgs { entries: Some(rows) });
    finish_envelope(b, fbs::Payload::ConfigListResult, Some(table.as_union_value()), report)
}

fn get_to_envelope(value: &str, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128);
    let value = b.create_string(value);
    let table = fbs::ConfigGetResult::create(&mut b, &fbs::ConfigGetResultArgs { value: Some(value) });
    finish_envelope(b, fbs::Payload::ConfigGetResult, Some(table.as_union_value()), report)
}

fn path_to_envelope(paths: &[PathBuf], report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let paths = string_vector(&mut b, paths.iter().map(|p| path_str(p).into_owned()));
    let table = fbs::ConfigPathResult::create(&mut b, &fbs::ConfigPathResultArgs { paths: Some(paths) });
    finish_envelope(b, fbs::Payload::ConfigPathResult, Some(table.as_union_value()), report)
}

fn set_to_envelope(r: &zanshin_jj::ConfigSetResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let path = b.create_string(&path_str(&r.path));
    // Written iff `Some`: null for absence.
    let author = r.working_copy_author.as_ref().map(|a| {
        let name = b.create_string(&a.name);
        let email = b.create_string(&a.email);
        fbs::WorkingCopyAuthor::create(
            &mut b,
            &fbs::WorkingCopyAuthorArgs {
                name: Some(name),
                email: Some(email),
            },
        )
    });
    let table = fbs::ConfigSetResult::create(
        &mut b,
        &fbs::ConfigSetResultArgs {
            path: Some(path),
            working_copy_author: author,
        },
    );
    finish_envelope(b, fbs::Payload::ConfigSetResult, Some(table.as_union_value()), report)
}

fn unset_to_envelope(path: &std::path::Path, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128);
    let path = b.create_string(&path_str(path));
    let table = fbs::ConfigUnsetResult::create(&mut b, &fbs::ConfigUnsetResultArgs { path: Some(path) });
    finish_envelope(b, fbs::Payload::ConfigUnsetResult, Some(table.as_union_value()), report)
}

fn file_text_to_envelope(t: &zanshin_jj::ConfigFileText, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256 + t.text.len());
    let path = b.create_string(&path_str(&t.path));
    let text = b.create_string(&t.text);
    let table = fbs::ConfigFileText::create(
        &mut b,
        &fbs::ConfigFileTextArgs {
            path: Some(path),
            text: Some(text),
        },
    );
    finish_envelope(b, fbs::Payload::ConfigFileText, Some(table.as_union_value()), report)
}

/// `zanshin_config_file_write`'s ok envelope: no payload, but the call's warnings (Story 9.37).
fn file_written_to_envelope(report: &CallReport) -> Vec<u8> {
    finish_envelope(FlatBufferBuilder::with_capacity(128), fbs::Payload::NONE, None, report)
}

/// A [`zanshin_jj::ConfigOutcome`] as its envelope (Story 9.37): `build` on success, the mapped
/// refusal otherwise — the outcome's warnings on EITHER.
fn outcome_to_envelope<T>(
    outcome: zanshin_jj::ConfigOutcome<T>,
    build: impl FnOnce(&T, &CallReport) -> Vec<u8>,
) -> Result<Vec<u8>, FfiErrorObj> {
    let report = CallReport::warnings(outcome.warnings);
    match outcome.result {
        Ok(value) => Ok(build(&value, &report)),
        Err(e) => Err(map_config_cmd_err(e).with_report(report)),
    }
}

fn gc_list_to_envelope(missing: &[zanshin_jj::MissingRepoConfig], report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let rows: Vec<_> = missing
        .iter()
        .map(|m| {
            let config_dir = b.create_string(&path_str(&m.config_dir));
            let repo_path = b.create_string(&path_str(&m.repo_path));
            fbs::MissingRepoConfig::create(
                &mut b,
                &fbs::MissingRepoConfigArgs {
                    config_dir: Some(config_dir),
                    repo_path: Some(repo_path),
                },
            )
        })
        .collect();
    let rows = b.create_vector(&rows);
    let table = fbs::ConfigGcList::create(&mut b, &fbs::ConfigGcListArgs { missing: Some(rows) });
    finish_envelope(b, fbs::Payload::ConfigGcList, Some(table.as_union_value()), report)
}

fn gc_result_to_envelope(r: &zanshin_jj::ConfigGcResult, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(256);
    let deleted = string_vector(&mut b, r.deleted.iter().map(|p| path_str(p).into_owned()));
    let failed: Vec<_> = r
        .failed
        .iter()
        .map(|f| {
            let config_dir = b.create_string(&path_str(&f.config_dir));
            let reason = b.create_string(&f.reason);
            fbs::ConfigGcFailure::create(
                &mut b,
                &fbs::ConfigGcFailureArgs {
                    config_dir: Some(config_dir),
                    reason: Some(reason),
                },
            )
        })
        .collect();
    let failed = b.create_vector(&failed);
    let table = fbs::ConfigGcResult::create(
        &mut b,
        &fbs::ConfigGcResultArgs {
            deleted: Some(deleted),
            failed: Some(failed),
        },
    );
    finish_envelope(b, fbs::Payload::ConfigGcResult, Some(table.as_union_value()), report)
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// List the values of the effective jj config stack with their sources — the CLI's `jj config
/// list [NAME] [--user|--repo|--workspace] [--include-defaults] [--include-overridden]`.
///
/// The arguments cross as a `ConfigListRequest` buffer; `workspace_root` absent = no workspace
/// (the CLI's `-R` otherwise, never walked up). Returns an `Envelope` carrying a
/// `ConfigListResult` (lowest layer first; empty is a result — and then warns
/// `jj.config_nothing_listed`, the CLI's stderr note). Writes nothing but the CLI's start-up
/// secure-config fix-up (with `workspace_root`; Story 9.37), whose notices are the first
/// `Envelope.warnings`, on the ok AND the error envelope.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ConfigListRequest`, or its `kind` is
///   not `ConfigList`.
/// - `jj.invalid_input` — a `scope` together with `include_defaults` (the CLI's flag conflict).
/// - `jj.path_not_found` — `workspace_root` does not resolve; the path in `context`.
/// - `jj.repo_not_found` — `workspace_root` is not a jj workspace; the path in `context`.
/// - `jj.config_error` — the stack does not load (a file unreadable or not TOML, a malformed id
///   file, a wrong-typed start-up key), or the start-up fix-up failed; the path or key in
///   `context`.
/// - `jj.config_parse_error` — `name` is not a TOML dotted key; span and message in `context`.
///
/// # Safety
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart; Rust only borrows it for the call. The returned token must be freed exactly once via
/// `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_config_list(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_config_list");
    vec_into_token(catch(|| {
        let req = read_list_request(data, len)?;
        outcome_to_envelope(
            zanshin_jj::config_list(req.root.as_deref(), &req.query),
            |entries, report| list_to_envelope(entries, report),
        )
    }))
}

/// Read one value of the effective jj config stack — the CLI's `jj config get NAME`: a string
/// unquoted, any other value (a table merged into an inline table included) as TOML text.
///
/// The arguments cross as a `ConfigGetRequest` buffer. Returns an `Envelope` carrying a
/// `ConfigGetResult`. Writes nothing but the CLI's start-up secure-config fix-up (with
/// `workspace_root`; Story 9.37), whose notices ride the ok AND the error envelope.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ConfigGetRequest`, or its `kind` is not
///   `ConfigGet`.
/// - `jj.invalid_input` — `name` is absent.
/// - `jj.path_not_found` — `workspace_root` does not resolve; the path in `context`.
/// - `jj.repo_not_found` — `workspace_root` is not a jj workspace; the path in `context`.
/// - `jj.config_error` — the stack does not load, or the start-up fix-up failed; the path or key
///   in `context`.
/// - `jj.config_parse_error` — `name` is not a TOML dotted key; span and message in `context`.
/// - `jj.config_not_found` — no layer sets `name` ("Value not found for <name>").
///
/// # Safety
/// As `zanshin_config_list`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_config_get(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_config_get");
    vec_into_token(catch(|| {
        let req = read_get_request(data, len)?;
        outcome_to_envelope(
            zanshin_jj::config_get(req.root.as_deref(), &req.name),
            |value, report| get_to_envelope(value, report),
        )
    }))
}

/// The config file paths of a scope — the CLI's `jj config path --user|--repo|--workspace`.
///
/// User: every candidate in the CLI's order, existing or not, creating nothing. Repo /
/// workspace: the secure file, CREATING its config directory, `metadata.binpb` and id file when
/// missing (the CLI's documented side effect; the `config.toml` itself is not created). With
/// `workspace_root`, the CLI's start-up secure-config fix-up runs first (Story 9.37); its
/// notices ride the ok AND the error envelope. The arguments cross as a `ConfigPathRequest`
/// buffer; returns a `ConfigPathResult`.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ConfigPathRequest`, or its `kind` is
///   not `ConfigPath`.
/// - `jj.invalid_input` — `scope` is `Unspecified`.
/// - `jj.path_not_found` — `workspace_root` does not resolve; the path in `context`.
/// - `jj.repo_not_found` — `workspace_root` is not a jj workspace; the path in `context`.
/// - `jj.config_error` — the stack does not load, the start-up fix-up failed, or the secure
///   directory could not be created.
/// - `jj.config_path_not_found` — no path can be determined ("No user config path found", …).
///
/// # Safety
/// As `zanshin_config_list`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_config_path(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_config_path");
    vec_into_token(catch(|| {
        let req = read_path_request(data, len)?;
        outcome_to_envelope(
            zanshin_jj::config_path(req.root.as_deref(), req.scope),
            |paths, report| path_to_envelope(paths, report),
        )
    }))
}

/// Set a config value in one config file — the CLI's `jj config set
/// --user|--repo|--workspace|--file PATH NAME VALUE`.
///
/// `value` is TOML text, a bare string when it does not look like TOML. The file is the scope's
/// FIRST file (or the CLI's new-file default), or — with `path` instead of `scope`, the CLI's
/// `--file` — that file, which must be a location jj recognizes (a relative one is taken
/// against `workspace_root`). Comments and formatting survive; the config write itself writes no
/// operation. For `user.name`/`user.email` with a workspace the working copy is snapshotted
/// first (the CLI's `check_wc_author`) — that snapshot MAY commit an operation when `@` is
/// dirty, exactly as in the CLI; then the envelope — ok or error — carries `precondition` and
/// that snapshot's warnings, and `ConfigSetResult.working_copy_author` is present iff `@`'s
/// author differs from the new value (then warning `jj.config_working_copy_author` too). With
/// `workspace_root`, the CLI's start-up secure-config fix-up runs before everything else (Story
/// 9.37); its notices are the envelope's FIRST warnings, ok or error.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ConfigSetRequest`, or its `kind` is not
///   `ConfigSet`.
/// - `jj.invalid_input` — neither or both of `scope` and `path`, or `name` / `value` is absent.
/// - `jj.path_not_found` — `workspace_root` does not resolve; the path in `context`.
/// - `jj.repo_not_found` — `workspace_root` is not a jj workspace; the path in `context`.
/// - `jj.config_error` — the stack does not load, or the file could not be read or written.
/// - `jj.config_parse_error` — `name` or `value` is not valid TOML; span and message in `context`.
/// - `jj.config_path_not_found` — no file of the scope can be determined.
/// - `jj.config_unrecognized_file` — `path` is not a jj config file location; the resolved path
///   in `context`. Nothing written.
/// - `jj.config_would_overwrite` — the value would replace a whole table, or a non-table parent.
///
/// # Safety
/// As `zanshin_config_list`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_config_set(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_config_set");
    vec_into_token(catch(|| {
        let req = read_set_request(data, len)?;
        let outcome = zanshin_jj::config_set(req.root.as_deref(), &req.target, &req.name, &req.value);
        let report = CallReport {
            precondition: outcome.precondition,
            warnings: outcome.warnings,
            left_behind: Vec::new(),
        };
        match outcome.result {
            Ok(r) => Ok(set_to_envelope(&r, &report)),
            Err(e) => Err(map_config_cmd_err(e).with_report(report)),
        }
    }))
}

/// Remove a config value from one config file — the CLI's `jj config unset
/// --user|--repo|--workspace|--file PATH NAME`. File selection as `zanshin_config_set`; returns
/// a `ConfigUnsetResult` naming the file. No operation is written. With `workspace_root`, the
/// CLI's start-up secure-config fix-up runs first (Story 9.37); its notices ride the ok AND the
/// error envelope.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ConfigUnsetRequest`, or its `kind` is
///   not `ConfigUnset`.
/// - `jj.invalid_input` — neither or both of `scope` and `path`, or `name` is absent.
/// - `jj.path_not_found` — `workspace_root` does not resolve; the path in `context`.
/// - `jj.repo_not_found` — `workspace_root` is not a jj workspace; the path in `context`.
/// - `jj.config_error` — the stack does not load, or the file could not be read or written.
/// - `jj.config_parse_error` — `name` is not a TOML dotted key.
/// - `jj.config_path_not_found` — no file of the scope can be determined.
/// - `jj.config_unrecognized_file` — `path` is not a jj config file location.
/// - `jj.config_would_delete_table` — `name` is a whole table.
/// - `jj.config_not_found` — the file does not hold `name` (`"<name>" doesn't exist`).
///
/// # Safety
/// As `zanshin_config_list`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_config_unset(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_config_unset");
    vec_into_token(catch(|| {
        let req = read_unset_request(data, len)?;
        outcome_to_envelope(
            zanshin_jj::config_unset(req.root.as_deref(), &req.target, &req.name),
            |path, report| unset_to_envelope(path, report),
        )
    }))
}

/// `jj config edit`, editor half 1: the file `zanshin_config_set` would write (the scope's first
/// file, or `path` — the CLI's `--file`) and its exact text, CREATING an absent
/// file first with jj-lib's empty document (as the CLI does before starting `$EDITOR`). Loads no
/// start-up stack, so a broken config can be read and repaired — but with `workspace_root` it
/// starts with the CLI's start-up secure-config fix-up alone (Story 9.37), whose notices ride
/// the ok AND the error envelope. The arguments cross as a `ConfigFileReadRequest` buffer;
/// returns a `ConfigFileText`.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ConfigFileReadRequest`, or its `kind`
///   is not `ConfigFileRead`.
/// - `jj.invalid_input` — neither or both of `scope` and `path`.
/// - `jj.path_not_found` — `workspace_root` does not resolve; the path in `context`.
/// - `jj.repo_not_found` — `workspace_root` is not a jj workspace; the path in `context`.
/// - `jj.config_error` — the start-up fix-up failed, or the file could not be created or read,
///   or is not UTF-8.
/// - `jj.config_path_not_found` — no file of the scope can be determined.
/// - `jj.config_unrecognized_file` — `path` is not a jj config file location.
///
/// # Safety
/// As `zanshin_config_list`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_config_file_read(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_config_file_read");
    vec_into_token(catch(|| {
        let req = read_file_read_request(data, len)?;
        outcome_to_envelope(
            zanshin_jj::config_file_read(req.root.as_deref(), &req.target),
            file_text_to_envelope,
        )
    }))
}

/// `jj config edit`, editor half 2: replace a config file's text — only a location
/// `zanshin_config_file_read` accepts for this root (checked without creating anything; a
/// relative `path` taken against `workspace_root`), and only after `text`
/// parses as TOML (the CLI's re-edit loop, with the UI holding the buffer). Returns an ok
/// `Envelope` with no payload. Like half 1, with `workspace_root` it starts with the CLI's
/// start-up secure-config fix-up alone (Story 9.37), whose notices ride the ok AND the error
/// envelope.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ConfigFileWriteRequest`, or its `kind`
///   is not `ConfigFileWrite`.
/// - `jj.invalid_input` — `path` or `text` is absent.
/// - `jj.path_not_found` — `workspace_root` does not resolve; the path in `context`.
/// - `jj.repo_not_found` — `workspace_root` is not a jj workspace; the path in `context`.
/// - `jj.config_unrecognized_file` — `path` is not such a location; the resolved path in
///   `context`.
/// - `jj.config_parse_error` — `text` is not valid TOML; span and message in `context`, the file
///   untouched.
/// - `jj.config_error` — the start-up fix-up or the write failed.
///
/// # Safety
/// As `zanshin_config_list`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_config_file_write(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_config_file_write");
    vec_into_token(catch(|| {
        let req = read_file_write_request(data, len)?;
        outcome_to_envelope(
            zanshin_jj::config_file_write(req.root.as_deref(), &req.path, &req.text),
            |(), report| file_written_to_envelope(report),
        )
    }))
}

/// `jj config gc`, half 1: the repo config directories under `<config_dir>/jj/repos` whose
/// recorded repo no longer exists, sorted — the CLI's list before its yes/no prompt. The
/// request is a `ConfigGcListRequest` (the tag only); returns a `ConfigGcList`. Writes nothing.
/// Its start-up warns the stack's migrations (`jj.config_deprecated`), on the ok AND the error
/// envelope.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ConfigGcListRequest`, or its `kind` is
///   not `ConfigGcList`.
/// - `jj.config_error` — the stack does not load, or the root cannot be read.
/// - `jj.config_path_not_found` — "No config directory found".
///
/// # Safety
/// As `zanshin_config_list`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_config_gc_list(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_config_gc_list");
    vec_into_token(catch(|| {
        read_gc_list_request(data, len)?;
        outcome_to_envelope(zanshin_jj::config_gc_list(), |missing, report| {
            gc_list_to_envelope(missing, report)
        })
    }))
}

/// `jj config gc`, half 2: delete the requested directories that are still missing repo config
/// directories; any other request, and every per-directory failure, rides
/// `ConfigGcResult.failed` (the CLI warns and continues — a directory that could not be deleted
/// also warns `jj.config_gc_delete_failed`, after the start-up's `jj.config_deprecated` as in
/// `zanshin_config_gc_list`). The arguments cross as a `ConfigGcDeleteRequest` buffer.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `ConfigGcDeleteRequest`, or its `kind`
///   is not `ConfigGcDelete`.
/// - `jj.config_error` — the stack does not load, or the root cannot be read.
/// - `jj.config_path_not_found` — "No config directory found".
///
/// # Safety
/// As `zanshin_config_list`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_config_gc_delete(data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_config_gc_delete");
    vec_into_token(catch(|| {
        let dirs = read_gc_delete_request(data, len)?;
        outcome_to_envelope(zanshin_jj::config_gc_delete(&dirs), gc_result_to_envelope)
    }))
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use zanshin_jj::{ConfigCmdError as E, ConfigValueSource};

    use super::{
        fbs, gc_list_to_envelope, gc_result_to_envelope, list_to_envelope, map_config_cmd_err, read_target,
        required_scope, set_to_envelope, wire_source,
    };

    fn envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
        flatbuffers::root::<fbs::Envelope>(bytes).expect("a verified envelope")
    }

    #[test]
    fn every_error_arm_maps_to_its_code_and_context() {
        for (err, code, context) in [
            (E::Config { reason: "r".into() }, "jj.config_error", "r"),
            (E::PathNotFound { path: "/p".into() }, "jj.path_not_found", "/p"),
            (E::NotARepo { path: "/p".into() }, "jj.repo_not_found", "/p"),
            (E::NotFound { reason: "n".into() }, "jj.config_not_found", "n"),
            (
                E::WouldOverwrite { reason: "o".into() },
                "jj.config_would_overwrite",
                "o",
            ),
            (
                E::WouldDeleteTable { reason: "d".into() },
                "jj.config_would_delete_table",
                "d",
            ),
            (
                E::UnrecognizedFile { path: "/a".into() },
                "jj.config_unrecognized_file",
                "/a",
            ),
            (
                E::Parse {
                    message: "m".into(),
                    span: Some(3..5),
                },
                "jj.config_parse_error",
                "3..5\nm",
            ),
            (
                E::Parse {
                    message: "m".into(),
                    span: None,
                },
                "jj.config_parse_error",
                "m",
            ),
            (E::NoConfigPath { reason: "x".into() }, "jj.config_path_not_found", "x"),
        ] {
            let obj = map_config_cmd_err(err);
            assert_eq!((obj.code.as_str(), obj.context.as_deref()), (code, Some(context)));
        }
    }

    /// Exactly one of `scope` and `path` — the CLI's `--user|--repo|--workspace|--file` group.
    #[test]
    fn a_target_is_a_scope_or_a_path_never_both() {
        use zanshin_jj::{ConfigScope, ConfigTarget};
        assert_eq!(
            read_target(fbs::ConfigScope::Repo, None).unwrap(),
            ConfigTarget::Scope(ConfigScope::Repo)
        );
        assert_eq!(
            read_target(fbs::ConfigScope::Unspecified, Some("/x.toml")).unwrap(),
            ConfigTarget::File("/x.toml".into())
        );
        for (scope, path) in [
            (fbs::ConfigScope::Unspecified, None),
            (fbs::ConfigScope::User, Some("/x.toml")),
        ] {
            assert_eq!(read_target(scope, path).unwrap_err().code, "jj.invalid_input");
        }
    }

    #[test]
    fn scopes_and_sources_map_one_to_one() {
        assert!(required_scope(fbs::ConfigScope::Unspecified).is_err());
        assert!(required_scope(fbs::ConfigScope(42)).is_err());
        for (source, wire) in [
            (ConfigValueSource::Default, fbs::ConfigValueSource::Default),
            (ConfigValueSource::System, fbs::ConfigValueSource::System),
            (ConfigValueSource::EnvBase, fbs::ConfigValueSource::EnvBase),
            (ConfigValueSource::User, fbs::ConfigValueSource::User),
            (ConfigValueSource::Repo, fbs::ConfigValueSource::Repo),
            (ConfigValueSource::Workspace, fbs::ConfigValueSource::Workspace),
            (ConfigValueSource::EnvOverrides, fbs::ConfigValueSource::EnvOverrides),
        ] {
            assert_eq!(wire_source(source), wire);
        }
    }

    #[test]
    fn builders_write_every_field_and_null_for_absence() {
        let list = list_to_envelope(
            &[zanshin_jj::ConfigEntry {
                name: "a.b".into(),
                value: "1".into(),
                source: ConfigValueSource::EnvBase,
                path: None,
                overridden: true,
            }],
            &crate::envelope::CallReport::default(),
        );
        let entry = envelope(&list)
            .data_as_config_list_result()
            .unwrap()
            .entries()
            .unwrap()
            .get(0);
        assert_eq!(
            (entry.name(), entry.value(), entry.path()),
            (Some("a.b"), Some("1"), None)
        );
        assert!(entry.overridden());
        assert_eq!(entry.source(), fbs::ConfigValueSource::EnvBase);

        let set = set_to_envelope(
            &zanshin_jj::ConfigSetResult {
                path: "/f".into(),
                working_copy_author: None,
            },
            &crate::envelope::CallReport::default(),
        );
        let env = envelope(&set);
        assert!(env.precondition().is_none());
        assert!(env.data_as_config_set_result().unwrap().working_copy_author().is_none());

        let gc = gc_list_to_envelope(
            &[zanshin_jj::MissingRepoConfig {
                config_dir: "/c".into(),
                repo_path: "/r".into(),
            }],
            &crate::envelope::CallReport::warnings(vec![zanshin_jj::Warning {
                kind: zanshin_jj::WarningKind::ConfigDeprecated,
                message: "Deprecated user-level config: d".into(),
            }]),
        );
        let gc_env = envelope(&gc);
        let row = gc_env.data_as_config_gc_list().unwrap().missing().unwrap().get(0);
        assert_eq!((row.config_dir(), row.repo_path()), (Some("/c"), Some("/r")));
        // Story 9.9 closing run: the gc list's start-up warnings ride its envelope.
        let warning = gc_env.warnings().expect("warnings present").get(0);
        assert_eq!(
            (warning.code(), warning.message()),
            (Some("jj.config_deprecated"), Some("Deprecated user-level config: d"))
        );

        let result = gc_result_to_envelope(
            &zanshin_jj::ConfigGcResult {
                deleted: vec![PathBuf::from("/d")],
                failed: vec![zanshin_jj::ConfigGcFailure {
                    config_dir: "/f".into(),
                    reason: "why".into(),
                }],
            },
            &crate::envelope::CallReport::warnings(vec![zanshin_jj::Warning {
                kind: zanshin_jj::WarningKind::ConfigGcDeleteFailed,
                message: "Failed to delete /f: why".into(),
            }]),
        );
        let env = envelope(&result);
        let r = env.data_as_config_gc_result().unwrap();
        assert_eq!(r.deleted().unwrap().get(0), "/d");
        assert_eq!(r.failed().unwrap().get(0).reason(), Some("why"));
        // Story 9.32: a handle-less verb's warnings ride the envelope — no precondition.
        assert!(env.precondition().is_none());
        let warning = env.warnings().expect("warnings present").get(0);
        assert_eq!(
            (warning.code(), warning.message()),
            (Some("jj.config_gc_delete_failed"), Some("Failed to delete /f: why"))
        );
    }
}
