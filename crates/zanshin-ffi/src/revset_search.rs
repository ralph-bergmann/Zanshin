// SPDX-License-Identifier: MIT

//! `zanshin_revset_counts` / `zanshin_find_changes` — the op-pinned graph searches (Story 9.25).
//!
//! Call `zanshin_jj::Repo::revset_counts` / `zanshin_jj::Repo::find_changes` and serialise their
//! answers into `FlatBuffers` `Envelope<RevsetCounts>` / `Envelope<FoundChanges>`. Both are pinned
//! reads like `commit_contents.rs`: they run no pre-verb snapshot, write no operation and no op
//! head, and their envelopes carry NO `precondition` — but they do carry `warnings` (the parse
//! diagnostics), on both arms: a call-level fault keeps the warnings collected before it. A count
//! that fails carries its own `FfiError` (code, context, hints and the structured `revset`
//! detail); only call-level faults fail the envelope.
//!
//! The arguments cross as request buffers (ADR-0001 composite-input pattern). Same reader
//! discipline as `commit_contents.rs`: `data`/`len` describe a caller-owned buffer Dart builds and
//! frees itself; Rust borrows it for the call only, the reader returns an OWNED struct, and the
//! request is read BEFORE the handle is borrowed. Interior-NUL guards live Dart-side
//! (`docs/ffi-abi.md` § Interior NUL).

use flatbuffers::{FlatBufferBuilder, VerifierOptions};
use tracing::debug;
use zanshin_jj::{ConfigError, FoundChanges, OperationId, RevsetCounts, RevsetSearchError, Warned};

use crate::envelope::{
    build_ffi_error, catch, expect_request_kind, finish_envelope, invalid_request, missing_field, reject_null_request,
    session_from_handle, CallReport, FfiErrorObj, JJ_CONFIG_ERROR, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR,
    JJ_OPERATION_NOT_FOUND,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::graph::map_topology_err;

/// Maps a [`RevsetSearchError`] onto its AR-P-4 code. A vanished operation reuses
/// `jj.operation_not_found` with the CLI's text; `find_changes`' own revset error maps exactly as
/// the topology's (code, hints, `FfiError.revset`).
fn map_search_err(e: RevsetSearchError) -> FfiErrorObj {
    let (code, context) = match e {
        RevsetSearchError::InvalidInput(reason) => (JJ_INVALID_INPUT, reason),
        e @ RevsetSearchError::OperationNotFound(_) => (JJ_OPERATION_NOT_FOUND, e.to_string()),
        RevsetSearchError::Config(ConfigError::Load { reason }) => (JJ_CONFIG_ERROR, reason),
        RevsetSearchError::Backend(reason) => (JJ_JJ_LIB_ERROR, reason),
        RevsetSearchError::Revset(e) => return map_topology_err(e),
    };
    FfiErrorObj {
        report: None,
        hints: Vec::new(),
        code: code.to_owned(),
        context: Some(context),
    }
}

/// [`map_search_err`] with the warnings collected before the fault on the error envelope — the
/// CLI prints them before it fails (Story 9.32).
fn map_warned_err(w: Warned<RevsetSearchError>) -> FfiErrorObj {
    map_search_err(w.value).with_report(CallReport::warnings(w.warnings))
}

// ── Request-buffer readers ───────────────────────────────────────────────────

/// Owned Rust form of a `RevsetCountsRequest` buffer.
struct RevsetCountsRequestOwned {
    operation_id: OperationId,
    expressions: Vec<String>,
    cap: u64,
}

/// Parse a `RevsetCountsRequest` buffer into an owned [`RevsetCountsRequestOwned`]. An absent
/// `expressions` vector is the empty list.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `RevsetCountsRequest` buffer, or its
///   `kind` is not `RevsetCounts`.
/// - `jj.invalid_input` — `operation_id` is absent (`operation_id is required`).
fn read_revset_counts_request(data: *const u8, len: usize) -> Result<RevsetCountsRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::RevsetCountsRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::RevsetCounts)?;
    let operation_id = req.operation_id().ok_or_else(|| missing_field("operation_id"))?;
    Ok(RevsetCountsRequestOwned {
        operation_id: OperationId(operation_id.to_owned()),
        expressions: req.expressions().into_iter().flatten().map(str::to_owned).collect(),
        cap: req.cap(),
    })
}

/// Owned Rust form of a `FindChangesRequest` buffer.
struct FindChangesRequestOwned {
    operation_id: OperationId,
    expression: String,
    limit: u64,
    short_prefixes: String,
}

/// Parse a `FindChangesRequest` buffer into an owned [`FindChangesRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FindChangesRequest` buffer, or its
///   `kind` is not `FindChanges`.
/// - `jj.invalid_input` — `operation_id`, `expression` or `short_prefixes` is absent
///   (`<field> is required`).
fn read_find_changes_request(data: *const u8, len: usize) -> Result<FindChangesRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::FindChangesRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::FindChanges)?;
    let operation_id = req.operation_id().ok_or_else(|| missing_field("operation_id"))?;
    let expression = req.expression().ok_or_else(|| missing_field("expression"))?;
    let short_prefixes = req.short_prefixes().ok_or_else(|| missing_field("short_prefixes"))?;
    Ok(FindChangesRequestOwned {
        operation_id: OperationId(operation_id.to_owned()),
        expression: expression.to_owned(),
        limit: req.limit(),
        short_prefixes: short_prefixes.to_owned(),
    })
}

// ── Payload builders ─────────────────────────────────────────────────────────

/// Serialise [`RevsetCounts`] into a finished `Envelope<RevsetCounts>` buffer: one entry per
/// expression, a failed one with its own `FfiError`; the warnings on the envelope.
fn revset_counts_to_envelope(answer: RevsetCounts) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128 + answer.counts.len() * 64);
    let offsets: Vec<_> = answer
        .counts
        .into_iter()
        .map(|count| match count {
            Ok(count) => fbs::RevsetCount::create(
                &mut b,
                &fbs::RevsetCountArgs {
                    n: count.n,
                    capped: count.capped,
                    error: None,
                },
            ),
            Err(e) => {
                let e = map_topology_err(e);
                let revset = e.report.as_ref().and_then(|r| r.revset.as_ref());
                let error = build_ffi_error(&mut b, &e.code, e.context.as_deref(), &e.hints, &[], revset);
                fbs::RevsetCount::create(
                    &mut b,
                    &fbs::RevsetCountArgs {
                        error: Some(error),
                        ..Default::default()
                    },
                )
            }
        })
        .collect();
    let counts = b.create_vector(&offsets);
    let table = fbs::RevsetCounts::create(&mut b, &fbs::RevsetCountsArgs { counts: Some(counts) });
    finish_envelope(
        b,
        fbs::Payload::RevsetCounts,
        Some(table.as_union_value()),
        &CallReport::warnings(answer.warnings),
    )
}

/// Serialise [`FoundChanges`] into a finished `Envelope<FoundChanges>` buffer, in the answer's
/// order; the warnings on the envelope.
fn found_changes_to_envelope(answer: FoundChanges) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128 + answer.entries.len() * 160);
    let offsets: Vec<_> = answer
        .entries
        .iter()
        .map(|entry| {
            let commit_id = b.create_string(&entry.commit_id.0);
            let change_id = b.create_string(&entry.change_id.0);
            fbs::FoundChange::create(
                &mut b,
                &fbs::FoundChangeArgs {
                    commit_id: Some(commit_id),
                    change_id: Some(change_id),
                    commit_prefix_len: entry.commit_prefix_len,
                    change_prefix_len: entry.change_prefix_len,
                },
            )
        })
        .collect();
    let entries = b.create_vector(&offsets);
    let table = fbs::FoundChanges::create(
        &mut b,
        &fbs::FoundChangesArgs {
            entries: Some(entries),
            truncated: answer.truncated,
        },
    );
    finish_envelope(
        b,
        fbs::Payload::FoundChanges,
        Some(table.as_union_value()),
        &CallReport::warnings(answer.warnings),
    )
}

// ── extern "C" wrappers ──────────────────────────────────────────────────────

/// Count the commits each expression denotes at the PINNED operation `operation_id`, each capped at
/// `cap` (Story 9.25) — the graph search's "N changes".
///
/// A pinned read like `zanshin_commit_contents`: `load_operation` + `load_at`, no pre-verb
/// snapshot, no operation, no op head; the envelope carries NO `precondition`. Each expression
/// parses as every Zanshin revset and resolves with the effective `revsets.short-prefixes`'
/// id-prefix context, as the CLI. With `cap > 0` at most `cap + 1` commits are read per
/// expression (`n` at most `cap`, `capped` when there were more); `cap == 0` parses and resolves
/// only. Every expression gets its own `RevsetCount` in request order; one that does not parse or
/// resolve carries its own `error` (`jj.revset_parse_error` / `jj.revset_resolution_error`, with
/// `hints` and `revset`) and fails nothing else. The parse diagnostics are the envelope's
/// `warnings`, in expression order — on a call-level failure too, as far as the call got.
///
/// The arguments cross as a `RevsetCountsRequest` `FlatBuffers` request buffer. Returns a
/// `FlatBuffers` `Envelope` carrying a `RevsetCounts` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `RevsetCountsRequest` buffer, or its
///   `kind` is not `RevsetCounts`.
/// - `jj.invalid_input` — `operation_id` is absent, empty, not hex or not a full id.
/// - `jj.operation_not_found` — the operation is not in the operation store; `context` is the
///   CLI's `No operation ID matching "<id>"`.
/// - `jj.config_error` — the effective config is malformed or unreadable, or its
///   `revsets.short-prefixes` is not a string or does not parse.
/// - `jj.jj_lib_error` — loading, evaluating or iterating failed; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.RevsetCountsRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call. The request is read BEFORE the handle is borrowed.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_revset_counts(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_revset_counts", handle);
    let buf = catch(|| {
        let req = read_revset_counts_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let answer = session
            .repo
            .revset_counts(&req.operation_id, &req.expressions, req.cap)
            .map_err(map_warned_err)?;
        Ok(revset_counts_to_envelope(answer))
    });
    vec_into_token(buf)
}

/// List the commits `expression` denotes at the PINNED operation `operation_id`, at most `limit`,
/// in the revset's iteration order (`jj log --no-graph`'s), each with its commit and change id and
/// both shortest-prefix lengths (Story 9.25) — the graph search's go-to beyond the view.
///
/// A pinned read like `zanshin_revset_counts`. `short_prefixes` is a caller pass-through: its
/// index disambiguates the expression's symbols AND gives the prefix lengths; empty disables
/// disambiguation (the full index), as in `zanshin_graph_topology`. At most `limit + 1` commits
/// are read; `truncated` says there were more. An ambiguous prefix is a resolution error; an
/// unmatched one finds nothing. The parse diagnostics are the envelope's `warnings` — on a failure
/// too, as far as the call got (a bad `expression` keeps `short_prefixes`' diagnostics).
///
/// The arguments cross as a `FindChangesRequest` `FlatBuffers` request buffer. Returns a
/// `FlatBuffers` `Envelope` carrying a `FoundChanges` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `FindChangesRequest` buffer, or its
///   `kind` is not `FindChanges`.
/// - `jj.invalid_input` — `operation_id`, `expression` or `short_prefixes` is absent, or
///   `operation_id` is empty, not hex or not a full id.
/// - `jj.operation_not_found` — the operation is not in the operation store; `context` is the
///   CLI's `No operation ID matching "<id>"`.
/// - `jj.revset_parse_error` — `short_prefixes` or `expression` does not parse; `hints` and
///   `revset` are set.
/// - `jj.revset_resolution_error` — a symbol in `expression` cannot be resolved; `hints` and
///   `revset` are set.
/// - `jj.config_error` — the effective config is malformed or unreadable.
/// - `jj.jj_lib_error` — loading, evaluating, iterating or a prefix lookup failed; detail in
///   `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.FindChangesRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call. The request is read BEFORE the handle is borrowed.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_find_changes(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_find_changes", handle);
    let buf = catch(|| {
        let req = read_find_changes_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let answer = session
            .repo
            .find_changes(&req.operation_id, &req.expression, req.limit, &req.short_prefixes)
            .map_err(map_warned_err)?;
        Ok(found_changes_to_envelope(answer))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root;
    use zanshin_jj::{
        ChangeId, CommitId, ConfigError, FoundChange, FoundChanges, RevsetCount, RevsetCounts, RevsetError,
        RevsetErrorDetail, RevsetErrorKind, RevsetSearchError, RevsetSpan, Warned, Warning, WarningKind,
    };

    use super::{found_changes_to_envelope, map_search_err, map_warned_err, revset_counts_to_envelope};
    use crate::envelope::{
        JJ_CONFIG_ERROR, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_OPERATION_NOT_FOUND, JJ_REVSET_PARSE_ERROR,
        JJ_REVSET_RESOLUTION_ERROR,
    };
    use crate::fbs;

    fn detail(kind: RevsetErrorKind) -> RevsetErrorDetail {
        RevsetErrorDetail {
            kind,
            span: Some(RevsetSpan {
                offset: 3,
                length: None,
            }),
            symbol: Some("fooo".to_owned()),
            candidates: vec!["foo".to_owned()],
            hints: vec!["Did you mean `foo`?".to_owned()],
        }
    }

    fn warning() -> Warning {
        Warning {
            kind: WarningKind::RevsetDiagnostic,
            message: "In revset expression\nx".to_owned(),
        }
    }

    #[test]
    fn counts_roundtrip_each_entry_and_a_failed_ones_own_error() {
        let buf = revset_counts_to_envelope(RevsetCounts {
            counts: vec![
                Ok(RevsetCount { n: 5, capped: true }),
                Err(RevsetError::ParseError {
                    reason: "bad".to_owned(),
                    detail: Box::new(detail(RevsetErrorKind::NoSuchFunction)),
                }),
                Err(RevsetError::ResolutionError {
                    reason: "gone".to_owned(),
                    detail: Box::new(RevsetErrorDetail {
                        span: None,
                        symbol: None,
                        candidates: Vec::new(),
                        hints: Vec::new(),
                        ..detail(RevsetErrorKind::NoSuchRevision)
                    }),
                }),
            ],
            warnings: vec![warning()],
        });
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok());
        assert!(env.precondition().is_none());
        assert_eq!(env.warnings().map(|w| w.len()), Some(1));
        let counts = env.data_as_revset_counts().expect("payload").counts().expect("counts");
        assert_eq!(counts.len(), 3);
        assert_eq!((counts.get(0).n(), counts.get(0).capped()), (5, true));
        assert!(counts.get(0).error().is_none());

        let parse = counts.get(1).error().expect("error");
        assert_eq!(parse.code(), Some(JJ_REVSET_PARSE_ERROR));
        assert_eq!(parse.context(), Some("bad"));
        assert_eq!(parse.hints().map(|h| h.get(0)), Some("Did you mean `foo`?"));
        let revset = parse.revset().expect("revset detail");
        assert_eq!(revset.kind(), fbs::RevsetErrorKind::NoSuchFunction);
        assert_eq!(revset.symbol(), Some("fooo"));
        assert_eq!(revset.candidates().map(|c| c.get(0)), Some("foo"));
        let span = revset.span().expect("span");
        assert_eq!(span.offset(), 3);
        assert!(span.length().is_none(), "a span across lines has no length");

        let resolution = counts.get(2).error().expect("error");
        assert_eq!(resolution.code(), Some(JJ_REVSET_RESOLUTION_ERROR));
        assert!(resolution.hints().is_none());
        let revset = resolution.revset().expect("revset detail");
        assert_eq!(revset.kind(), fbs::RevsetErrorKind::NoSuchRevision);
        assert!(revset.span().is_none() && revset.symbol().is_none() && revset.candidates().is_none());
    }

    #[test]
    fn found_changes_roundtrip_every_field_in_order() {
        let entry = |id: &str| FoundChange {
            commit_id: CommitId(id.to_owned()),
            change_id: ChangeId(format!("k{id}")),
            commit_prefix_len: 2,
            change_prefix_len: 3,
        };
        let buf = found_changes_to_envelope(FoundChanges {
            entries: vec![entry("bb"), entry("aa")],
            truncated: true,
            warnings: Vec::new(),
        });
        let env = root::<fbs::Envelope>(&buf).expect("Verifier failed");
        assert!(env.ok() && env.precondition().is_none() && env.warnings().is_none());
        let found = env.data_as_found_changes().expect("payload");
        assert!(found.truncated());
        let entries = found.entries().expect("entries");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries.get(0).commit_id(), Some("bb"));
        assert_eq!(entries.get(0).change_id(), Some("kbb"));
        assert_eq!(
            (entries.get(0).commit_prefix_len(), entries.get(0).change_prefix_len()),
            (2, 3)
        );
        assert_eq!(entries.get(1).commit_id(), Some("aa"));
    }

    #[test]
    fn every_search_error_maps_to_its_code() {
        for (error, code, context) in [
            (
                RevsetSearchError::InvalidInput("bad".to_owned()),
                JJ_INVALID_INPUT,
                "bad",
            ),
            (
                RevsetSearchError::OperationNotFound("ab".to_owned()),
                JJ_OPERATION_NOT_FOUND,
                r#"No operation ID matching "ab""#,
            ),
            (
                RevsetSearchError::Config(ConfigError::Load { reason: "c".to_owned() }),
                JJ_CONFIG_ERROR,
                "c",
            ),
            (RevsetSearchError::Backend("boom".to_owned()), JJ_JJ_LIB_ERROR, "boom"),
        ] {
            let mapped = map_search_err(error);
            assert_eq!((mapped.code.as_str(), mapped.context.as_deref()), (code, Some(context)));
            assert!(mapped.report.is_none() && mapped.hints.is_empty());
        }
        let revset = map_search_err(RevsetSearchError::Revset(RevsetError::ParseError {
            reason: "p".to_owned(),
            detail: Box::new(detail(RevsetErrorKind::SyntaxError)),
        }));
        assert_eq!(revset.code, JJ_REVSET_PARSE_ERROR);
        assert_eq!(revset.hints, ["Did you mean `foo`?"]);
        assert_eq!(
            revset.report.and_then(|r| r.revset),
            Some(detail(RevsetErrorKind::SyntaxError))
        );
    }

    /// A call-level fault keeps the warnings collected before it, and a revset fault its detail.
    #[test]
    fn a_warned_fault_carries_its_warnings_and_keeps_the_revset_detail() {
        let config = map_warned_err(Warned {
            value: RevsetSearchError::Config(ConfigError::Load { reason: "c".to_owned() }),
            warnings: vec![warning()],
        });
        assert_eq!(config.code, JJ_CONFIG_ERROR);
        assert_eq!(config.report.expect("report").warnings, [warning()]);
        let revset = map_warned_err(Warned {
            value: RevsetSearchError::Revset(RevsetError::ParseError {
                reason: "p".to_owned(),
                detail: Box::new(detail(RevsetErrorKind::SyntaxError)),
            }),
            warnings: vec![warning()],
        });
        assert_eq!(revset.code, JJ_REVSET_PARSE_ERROR);
        let report = revset.report.expect("report");
        assert_eq!(report.warnings, [warning()]);
        assert_eq!(report.revset, Some(detail(RevsetErrorKind::SyntaxError)));
    }
}
