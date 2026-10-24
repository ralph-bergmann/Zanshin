// SPDX-License-Identifier: MIT

//! Integration tests for `zanshin_op_log` FFI wrapper (Story 3.4b, `op_log` slice).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the
//! Verifier. Every token is freed via `zanshin_buffer_free_token` so the suite is
//! leak-clean.
//!
//! No null-pointer or UTF-8 tests for `zanshin_op_log` — it has no `CString` arg; this
//! asymmetry vs. `change` is deliberate. Story 9.21's four operation verbs (`zanshin_redo`,
//! `zanshin_op_show`, `zanshin_op_diff`, `zanshin_op_abandon`) follow at the end: their readers,
//! a payload of each on the wire and their refusal envelopes — then Story 9.12's three
//! (`zanshin_op_restore`, `zanshin_op_revert`, `zanshin_op_integrate`) the same way.

use std::ffi::CString;

use flatbuffers::root as fb_root;
use test_helpers::extract_fixture;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    op_log::{
        zanshin_op_abandon, zanshin_op_diff, zanshin_op_integrate, zanshin_op_log, zanshin_op_restore,
        zanshin_op_revert, zanshin_op_show,
    },
    repo::{zanshin_redo, zanshin_repo_close, zanshin_repo_open, zanshin_undo},
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_INVALID_INPUT, JJ_NOTHING_TO_REDO,
    JJ_OPERATION_NOT_FOUND,
};

// ── Env pin ───────────────────────────────────────────────────────────────────

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by a `zanshin_*`
/// function and not yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    // SAFETY: token is valid; freed exactly once here after the copy above.
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// Parse bytes into a verified `fbs::Envelope`.
fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("test string must not contain NUL bytes")
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// Valid round-trip: open tiny fixture, call `zanshin_op_log(-1)` (all ops),
/// assert ok + `OpLog` payload + at least 1 op + last op is root + close.
#[test]
fn op_log_valid_round_trip_returns_ok_oplog() {
    test_helpers::pin_test_env();

    // Keep `fixture` alive for the duration — its TempDir owns the repo on disk.
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path_cstr = cstr(fixture.path.to_str().expect("fixture path must be valid UTF-8"));

    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    let token = unsafe { zanshin_op_log(handle, -1) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "zanshin_op_log must succeed");
    assert_eq!(env.data_type(), fbs::Payload::OpLog, "data_type must be OpLog");

    let payload = env.data_as_op_log().expect("data_as_op_log must succeed");
    let ops = payload.operations().expect("operations must be present");

    assert!(!ops.is_empty(), "op log must be non-empty");

    // Last element must be the root op.
    let root = ops.get(ops.len() - 1);
    assert!(root.root_op(), "last op must have root_op == true");
    let root_pids: Vec<_> = root.parent_ids().map(|v| v.iter().collect()).unwrap_or_default();
    assert!(root_pids.is_empty(), "root op parent_ids must be empty");

    // Head op (first) must not be the root.
    let head = ops.get(0);
    assert!(!head.root_op(), "head op must not be the root");

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");

    drop(fixture); // explicit: keep fixture alive until after all FFI calls
}

/// Limit round-trip: `zanshin_op_log(handle, 1)` returns exactly 1 operation.
#[test]
fn op_log_limit_one_returns_exactly_one_op() {
    test_helpers::pin_test_env();

    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path_cstr = cstr(fixture.path.to_str().expect("fixture path must be valid UTF-8"));

    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    let token = unsafe { zanshin_op_log(handle, 1) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "zanshin_op_log with limit 1 must succeed");
    let payload = env.data_as_op_log().expect("data_as_op_log must succeed");
    let ops = payload.operations().expect("operations must be present");
    assert_eq!(ops.len(), 1, "limit 1 must return exactly one op");

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");

    drop(fixture);
}

/// Invalid handle: `zanshin_op_log(0, -1)` must return `ffi.invalid_handle`.
#[test]
fn op_log_zero_handle_returns_ffi_invalid_handle() {
    test_helpers::pin_test_env();

    let token = unsafe { zanshin_op_log(0, -1) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "zanshin_op_log(0) must be an error");
    assert_eq!(
        env.error().and_then(|e| e.code()),
        Some(FFI_INVALID_HANDLE),
        "error.code must be ffi.invalid_handle"
    );
    // The borrow routes through `envelope::session_from_handle`, whose refusal
    // carries no context — pinned so a wrapper cannot start decorating it.
    assert!(
        env.error().and_then(|e| e.context()).is_none(),
        "the invalid-handle envelope carries no context"
    );
}

/// `i64::MAX` limit maps to `Some(huge)` via `usize::try_from(limit).ok()` and must
/// return the same op count as `-1` (all) — exercising the upper bound of the scalar.
#[test]
fn op_log_i64_max_limit_equals_all() {
    test_helpers::pin_test_env();

    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let path_cstr = cstr(fixture.path.to_str().expect("fixture path must be valid UTF-8"));

    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    let all_token = unsafe { zanshin_op_log(handle, -1) };
    let all_bytes = unsafe { read_and_free(all_token) };
    let all_env = parse_envelope(&all_bytes);
    let all_len = all_env
        .data_as_op_log()
        .expect("data_as_op_log must succeed")
        .operations()
        .map_or(0, |o| o.len());

    let max_token = unsafe { zanshin_op_log(handle, i64::MAX) };
    let max_bytes = unsafe { read_and_free(max_token) };
    let max_env = parse_envelope(&max_bytes);
    assert!(max_env.ok(), "i64::MAX limit must succeed");
    let max_len = max_env
        .data_as_op_log()
        .expect("data_as_op_log must succeed")
        .operations()
        .map_or(0, |o| o.len());

    assert_eq!(
        max_len, all_len,
        "i64::MAX limit must return the same op count as -1 (all)"
    );

    let close_token = unsafe { zanshin_repo_close(handle) };
    let close_bytes = unsafe { read_and_free(close_token) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");

    drop(fixture);
}

// ── Story 9.21: redo / op show / op diff / op abandon ─────────────────────────

/// An open handle on a `tiny-3-commits` copy whose `Commit 1` was described once (through
/// `zanshin_jj`, before the handle opened). Closed on drop.
struct Fx {
    fixture: test_helpers::FixtureHandle,
    handle: u64,
}

impl Drop for Fx {
    fn drop(&mut self) {
        // SAFETY: the handle came from `zanshin_repo_open` and is closed exactly once.
        let bytes = unsafe { read_and_free(zanshin_repo_close(self.handle)) };
        assert!(parse_envelope(&bytes).ok(), "repo close must succeed");
    }
}

fn described() -> Fx {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let mut repo = zanshin_jj::Repo::open(&fixture.path).expect("open");
    let mut commit1 = None;
    let _ = repo.eval_revset("description(exact:'Commit 1')", |change| {
        commit1 = Some(change.id);
        std::ops::ControlFlow::Break(())
    });
    repo.describe(commit1.expect("Commit 1"), "described")
        .expect("describe");
    drop(repo);
    let path = cstr(fixture.path.to_str().expect("UTF-8 path"));
    let bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let handle = parse_envelope(&bytes).data_as_repo_handle().expect("handle").handle();
    Fx { fixture, handle }
}

/// The op heads on disk.
fn op_heads(fx: &Fx) -> Vec<String> {
    let mut heads: Vec<String> = std::fs::read_dir(fx.fixture.path.join(".jj/repo/op_heads/heads"))
        .expect("op heads")
        .map(|entry| entry.expect("entry").file_name().to_string_lossy().into_owned())
        .collect();
    heads.sort();
    heads
}

fn error_code(bytes: &[u8]) -> Option<String> {
    parse_envelope(bytes)
        .error()
        .and_then(|e| e.code())
        .map(ToOwned::to_owned)
}

fn show_request(kind: fbs::RequestKind, operation: Option<&str>, show_changes_in: Option<&str>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::new();
    let operation = operation.map(|s| b.create_string(s));
    let show_changes_in = show_changes_in.map(|s| b.create_string(s));
    let req = fbs::OpShowRequest::create(
        &mut b,
        &fbs::OpShowRequestArgs {
            kind,
            operation,
            show_changes_in,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn diff_request(operation: Option<&str>, from: Option<&str>, to: Option<&str>) -> Vec<u8> {
    diff_request_in(operation, from, to, None)
}

fn diff_request_in(
    operation: Option<&str>,
    from: Option<&str>,
    to: Option<&str>,
    show_changes_in: Option<&str>,
) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::new();
    let operation = operation.map(|s| b.create_string(s));
    let from = from.map(|s| b.create_string(s));
    let to = to.map(|s| b.create_string(s));
    let show_changes_in = show_changes_in.map(|s| b.create_string(s));
    let req = fbs::OpDiffRequest::create(
        &mut b,
        &fbs::OpDiffRequestArgs {
            kind: fbs::RequestKind::OpDiff,
            operation,
            from,
            to,
            show_changes_in,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// `zanshin_undo` then `zanshin_redo`: the redo op on the wire; a second redo finds nothing and
/// leaves the op heads alone.
#[test]
fn redo_after_undo_then_nothing_to_redo() {
    let fx = described();
    let bytes = unsafe { read_and_free(zanshin_undo(fx.handle, false)) };
    assert!(parse_envelope(&bytes).ok());

    let bytes = unsafe { read_and_free(zanshin_redo(fx.handle, false)) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let new_op = env
        .data_as_mutation_result()
        .expect("MutationResult")
        .new_op_id()
        .unwrap()
        .to_owned();
    assert!(env.precondition().is_some(), "redo runs the pre-verb snapshot");
    assert_eq!(op_heads(&fx), [new_op]);

    let bytes = unsafe { read_and_free(zanshin_redo(fx.handle, true)) };
    let env = parse_envelope(&bytes);
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_NOTHING_TO_REDO));
    assert_eq!(env.error().and_then(|e| e.context()), Some("Nothing to redo"));
    assert_eq!(op_heads(&fx).len(), 1);

    let bytes = unsafe { read_and_free(zanshin_redo(0, false)) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_HANDLE));
}

/// `zanshin_op_show`: an absent operation is `@`; the payload carries the operation (with its
/// workspace) and the diff; the reader's refusals.
#[test]
fn op_show_round_trip_and_refusals() {
    let fx = described();
    let req = show_request(fbs::RequestKind::OpShow, None, None);
    let bytes = unsafe { read_and_free(zanshin_op_show(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let show = env.data_as_op_show().expect("OpShow");
    let op = show.operation().expect("operation");
    assert_eq!(op.workspace_name(), Some("default"));
    assert!(
        op.description().unwrap().starts_with("describe commit"),
        "{:?}",
        op.description()
    );
    let commits = show.diff().expect("diff").commits().expect("commits");
    assert_eq!(
        commits.changes().expect("changes").len(),
        3,
        "Commit 1 and its two descendants"
    );

    let req = show_request(fbs::RequestKind::OpShow, Some("ffffffffffff"), None);
    let bytes = unsafe { read_and_free(zanshin_op_show(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_OPERATION_NOT_FOUND));
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.context()),
        Some(r#"No operation ID matching "ffffffffffff""#)
    );

    let req = show_request(fbs::RequestKind::OpDiff, None, None);
    let bytes = unsafe { read_and_free(zanshin_op_show(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_ARGUMENT), "wrong kind");
    let garbage = [1_u8, 2, 3];
    let bytes = unsafe { read_and_free(zanshin_op_show(fx.handle, garbage.as_ptr(), garbage.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_ARGUMENT), "malformed");
    let bytes = unsafe { read_and_free(zanshin_op_show(fx.handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_NULL_POINTER));
    let req = show_request(fbs::RequestKind::OpShow, Some("@"), Some("all()"));
    let bytes = unsafe { read_and_free(zanshin_op_show(0, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_HANDLE));
}

/// `zanshin_op_diff`: `from` alone diffs to `@`; `operation` with `from` is clap's conflict,
/// refused before the snapshot — no precondition on the envelope.
#[test]
fn op_diff_round_trip_and_the_flag_conflict() {
    let fx = described();
    let req = diff_request(None, Some("@-"), None);
    let bytes = unsafe { read_and_free(zanshin_op_diff(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let result = env.data_as_op_diff_result().expect("OpDiffResult");
    assert_eq!(result.from().expect("from").len(), 1);
    assert_eq!(result.to().and_then(|op| op.id()), Some(op_heads(&fx)[0].as_str()));
    assert!(result.diff().and_then(|diff| diff.commits()).is_some());

    let req = diff_request(Some("@"), Some("@-"), None);
    let bytes = unsafe { read_and_free(zanshin_op_diff(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert_eq!(
        env.error().and_then(|e| e.context()),
        Some("the argument '--operation' cannot be used with '--from'")
    );
    assert!(env.precondition().is_none(), "refused before the snapshot");

    let bytes = unsafe { read_and_free(zanshin_op_diff(fx.handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_NULL_POINTER));
    let req = show_request(fbs::RequestKind::OpShow, None, None);
    let bytes = unsafe { read_and_free(zanshin_op_diff(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_ARGUMENT), "wrong kind");
}

/// `zanshin_op_abandon`: the range on the wire (no precondition: it runs no snapshot); the
/// current-operation refusal with its hint leaves the op heads; a null or invalid argument.
#[test]
fn op_abandon_round_trip_and_refusals() {
    let fx = described();
    let current = cstr("@");
    let heads = op_heads(&fx);
    let bytes = unsafe { read_and_free(zanshin_op_abandon(fx.handle, current.as_ptr())) };
    let env = parse_envelope(&bytes);
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    let error = env.error().expect("error");
    assert_eq!(
        error.context(),
        Some(format!("Cannot abandon the current operation {}", &heads[0][..12]).as_str())
    );
    assert_eq!(
        error.hints().map(|hints| hints.iter().collect::<Vec<_>>()),
        Some(vec![
            "Run `jj undo` to revert the current operation, then use `jj op abandon`"
        ])
    );
    assert!(env.precondition().is_none());
    assert_eq!(op_heads(&fx), heads, "a refusal writes nothing");

    let range = cstr("..@-");
    let bytes = unsafe { read_and_free(zanshin_op_abandon(fx.handle, range.as_ptr())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert!(env.precondition().is_none(), "no pre-verb snapshot");
    let result = env.data_as_op_abandon_result().expect("OpAbandonResult");
    assert!(!result.nothing_changed());
    assert_eq!(result.reparented_count(), 1);
    assert!(result.abandoned_count() >= 1);
    let new_heads: Vec<&str> = result.head_op_ids().expect("heads").iter().collect();
    assert_eq!(new_heads, op_heads(&fx));

    let bytes = unsafe { read_and_free(zanshin_op_abandon(fx.handle, std::ptr::null())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_NULL_POINTER));
    let bytes = unsafe { read_and_free(zanshin_op_abandon(0, range.as_ptr())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_HANDLE));
}

/// `show_changes_in` crosses both requests: `none()` elides every changed commit (the describe
/// rewrote three), and a lone `to` (here `@-`) diffs from `@`, the missing `from`'s default.
#[test]
fn show_changes_in_and_a_lone_to_are_read_off_the_request() {
    let fx = described();
    let req = show_request(fbs::RequestKind::OpShow, None, Some("none()"));
    let bytes = unsafe { read_and_free(zanshin_op_show(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let commits = env.data_as_op_show().unwrap().diff().unwrap().commits().unwrap();
    assert_eq!(commits.changes().map(|c| c.len()), Some(0));
    assert!(commits.elided_newly_visible().unwrap().lower() > 0);

    let req = diff_request_in(None, Some("@-"), None, Some("none()"));
    let bytes = unsafe { read_and_free(zanshin_op_diff(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let commits = env.data_as_op_diff_result().unwrap().diff().unwrap().commits().unwrap();
    assert_eq!(commits.changes().map(|c| c.len()), Some(0));
    assert!(commits.elided_newly_visible().unwrap().lower() > 0);

    let req = diff_request(None, None, Some("@-"));
    let bytes = unsafe { read_and_free(zanshin_op_diff(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let result = env.data_as_op_diff_result().unwrap();
    let from = result.from().unwrap();
    assert_eq!(from.len(), 1);
    assert_eq!(
        from.get(0).id(),
        Some(op_heads(&fx)[0].as_str()),
        "a lone `to`: from is `@`"
    );
    assert_ne!(result.to().and_then(|op| op.id()), from.get(0).id(), "to is `@-`");
}

/// An `operation` that is not UTF-8 is refused before the handle is touched.
#[test]
fn op_abandon_refuses_an_operation_that_is_not_utf8() {
    let fx = described();
    let bytes_in: [u8; 2] = [0xff, 0x00];
    let bytes = unsafe { read_and_free(zanshin_op_abandon(fx.handle, bytes_in.as_ptr().cast())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(zanshin_ffi::FFI_UTF8_ERROR));
}

// ── Story 9.12: op restore / op revert / op integrate ────────────────────────

/// An `OpRestoreRequest` buffer tagged `kind`.
fn restore_request(kind: fbs::RequestKind, operation: Option<&str>, what: Option<&[fbs::RestoreWhat]>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::new();
    let operation = operation.map(|s| b.create_string(s));
    let what = what.map(|what| b.create_vector(what));
    let req = fbs::OpRestoreRequest::create(&mut b, &fbs::OpRestoreRequestArgs { kind, operation, what });
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// An `OpRevertRequest` buffer tagged `kind`.
fn revert_request(kind: fbs::RequestKind, operation: Option<&str>, what: Option<&[fbs::RestoreWhat]>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::new();
    let operation = operation.map(|s| b.create_string(s));
    let what = what.map(|what| b.create_vector(what));
    let req = fbs::OpRevertRequest::create(&mut b, &fbs::OpRevertRequestArgs { kind, operation, what });
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// [`restore_request`] / [`revert_request`] with their own kind.
fn edit_request(kind: fbs::RequestKind, operation: Option<&str>, what: Option<&[fbs::RestoreWhat]>) -> Vec<u8> {
    if kind == fbs::RequestKind::OpRestore {
        restore_request(kind, operation, what)
    } else {
        revert_request(kind, operation, what)
    }
}

/// `zanshin_op_restore` to `@-` (before the describe): a `MutationResult` with the restore op as
/// the only head; `@` stays; restoring the current state again writes nothing.
#[test]
fn op_restore_round_trip_and_no_change() {
    let fx = described();
    let req = edit_request(fbs::RequestKind::OpRestore, Some("@-"), Some(&[fbs::RestoreWhat::Repo]));
    let bytes = unsafe { read_and_free(zanshin_op_restore(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert!(env.precondition().is_some(), "restore runs the pre-verb snapshot");
    let mutation = env.data_as_mutation_result().expect("MutationResult");
    let new_op = mutation.new_op_id().expect("new op").to_owned();
    assert!(mutation.working_copy_change_id().is_some());
    assert_eq!(op_heads(&fx), std::slice::from_ref(&new_op));

    let req = edit_request(fbs::RequestKind::OpRestore, Some("@"), None);
    let bytes = unsafe { read_and_free(zanshin_op_restore(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok());
    assert_eq!(
        env.data_as_mutation_result().unwrap().new_op_id(),
        Some(new_op.as_str()),
        "no change"
    );
    assert_eq!(op_heads(&fx), [new_op]);
}

/// `zanshin_op_restore` of the root operation: the operation is written, `@` is ABSENT, and the
/// finish warns that the workspace no longer exists.
#[test]
fn op_restore_of_the_root_leaves_no_working_copy() {
    let fx = described();
    let req = edit_request(fbs::RequestKind::OpRestore, Some("000000000000"), None);
    let bytes = unsafe { read_and_free(zanshin_op_restore(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert_eq!(env.data_as_mutation_result().unwrap().working_copy_change_id(), None);
    let codes: Vec<&str> = env.warnings().unwrap().iter().filter_map(|w| w.code()).collect();
    assert_eq!(codes, [zanshin_ffi::JJ_WORKSPACE_NO_LONGER_EXISTS]);
}

/// The restore reader's refusals: an ABSENT operation, an `Unspecified` `what` member, the wrong
/// kind, a malformed or null buffer, a zero handle; the opset errors. None touches the op heads.
#[test]
fn op_restore_refusals_leave_the_op_heads() {
    let fx = described();
    let heads = op_heads(&fx);
    let call = |req: &[u8]| unsafe { read_and_free(zanshin_op_restore(fx.handle, req.as_ptr(), req.len())) };
    let cases: [(Vec<u8>, &str); 6] = [
        (
            edit_request(fbs::RequestKind::OpRestore, None, None),
            FFI_INVALID_ARGUMENT,
        ),
        (
            edit_request(
                fbs::RequestKind::OpRestore,
                Some("@-"),
                Some(&[fbs::RestoreWhat::Unspecified]),
            ),
            FFI_INVALID_ARGUMENT,
        ),
        (
            restore_request(fbs::RequestKind::OpRevert, Some("@-"), None),
            FFI_INVALID_ARGUMENT,
        ),
        (vec![1, 2, 3], FFI_INVALID_ARGUMENT),
        (
            edit_request(fbs::RequestKind::OpRestore, Some("ffffffffffff"), None),
            JJ_OPERATION_NOT_FOUND,
        ),
        (
            edit_request(fbs::RequestKind::OpRestore, Some("zz"), None),
            JJ_INVALID_INPUT,
        ),
    ];
    for (req, code) in &cases {
        assert_eq!(error_code(&call(req)).as_deref(), Some(*code));
    }
    let absent = call(&cases[0].0);
    assert_eq!(
        parse_envelope(&absent).error().and_then(|e| e.context()),
        Some("operation is required")
    );
    let bytes = unsafe { read_and_free(zanshin_op_restore(fx.handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_NULL_POINTER));
    let req = edit_request(fbs::RequestKind::OpRestore, Some("@-"), None);
    let bytes = unsafe { read_and_free(zanshin_op_restore(0, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_HANDLE));
    assert_eq!(op_heads(&fx), heads);
}

/// `zanshin_op_revert` with an ABSENT operation reverts `@` (the describe); then the root
/// operation is refused with the CLI's text, and the reader refuses like the restore reader.
#[test]
fn op_revert_round_trip_and_refusals() {
    let fx = described();
    let previous_head = op_heads(&fx).remove(0);
    let req = edit_request(
        fbs::RequestKind::OpRevert,
        None,
        Some(&[fbs::RestoreWhat::RemoteTracking, fbs::RestoreWhat::Repo]),
    );
    let bytes = unsafe { read_and_free(zanshin_op_revert(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let new_op = env.data_as_mutation_result().unwrap().new_op_id().unwrap().to_owned();
    assert_eq!(op_heads(&fx), [new_op]);
    let bytes = unsafe { read_and_free(zanshin_op_log(fx.handle, 1)) };
    let log = parse_envelope(&bytes).data_as_op_log().unwrap().operations().unwrap();
    assert_eq!(
        log.get(0).description(),
        Some(format!("revert operation {previous_head}").as_str()),
        "an ABSENT operation reverts `@`"
    );
    let heads = op_heads(&fx);

    let req = edit_request(fbs::RequestKind::OpRevert, Some("000000000000"), None);
    let bytes = unsafe { read_and_free(zanshin_op_revert(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.context()),
        Some("Cannot revert root operation")
    );
    for (req, code) in [
        (
            edit_request(fbs::RequestKind::OpRevert, None, Some(&[fbs::RestoreWhat::Unspecified])),
            FFI_INVALID_ARGUMENT,
        ),
        (
            revert_request(fbs::RequestKind::OpRestore, Some("@"), None),
            FFI_INVALID_ARGUMENT,
        ),
        (vec![1, 2, 3], FFI_INVALID_ARGUMENT),
        (
            edit_request(fbs::RequestKind::OpRevert, None, Some(&[fbs::RestoreWhat(7)])),
            FFI_INVALID_ARGUMENT,
        ),
        (
            edit_request(fbs::RequestKind::OpRevert, Some("ffffffffffff"), None),
            JJ_OPERATION_NOT_FOUND,
        ),
    ] {
        let bytes = unsafe { read_and_free(zanshin_op_revert(fx.handle, req.as_ptr(), req.len())) };
        assert_eq!(error_code(&bytes).as_deref(), Some(code));
    }
    let bytes = unsafe { read_and_free(zanshin_op_revert(fx.handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_NULL_POINTER));
    let req = edit_request(fbs::RequestKind::OpRevert, None, None);
    let bytes = unsafe { read_and_free(zanshin_op_revert(0, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_HANDLE));
    assert_eq!(op_heads(&fx), heads);
}

/// `zanshin_op_integrate @-`: in the log, so nothing changes — the head on the wire, not
/// reconciled, no precondition; an unknown id, a null, non-UTF-8 argument and a zero handle refuse.
#[test]
fn op_integrate_round_trip_and_refusals() {
    let fx = described();
    let heads = op_heads(&fx);
    let parent = cstr("@-");
    let bytes = unsafe { read_and_free(zanshin_op_integrate(fx.handle, parent.as_ptr())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert!(env.precondition().is_none(), "no pre-verb snapshot");
    let result = env.data_as_op_integrate_result().expect("OpIntegrateResult");
    assert_eq!(result.head_op_id(), Some(heads[0].as_str()));
    assert!(!result.reconciled());

    let unknown = cstr("ffffffffffff");
    let bytes = unsafe { read_and_free(zanshin_op_integrate(fx.handle, unknown.as_ptr())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_OPERATION_NOT_FOUND));
    let bytes = unsafe { read_and_free(zanshin_op_integrate(fx.handle, std::ptr::null())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_NULL_POINTER));
    let bytes_in: [u8; 2] = [0xff, 0x00];
    let bytes = unsafe { read_and_free(zanshin_op_integrate(fx.handle, bytes_in.as_ptr().cast())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(zanshin_ffi::FFI_UTF8_ERROR));
    let bytes = unsafe { read_and_free(zanshin_op_integrate(0, parent.as_ptr())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(FFI_INVALID_HANDLE));
    assert_eq!(op_heads(&fx), heads);
}

/// `RemoteTracking` crosses the wire as itself: a remote bookmark set after the target is dropped,
/// the describe before it is kept.
#[test]
fn op_restore_of_the_remote_tracking_portion_only() {
    let fx = described();
    let mut repo = zanshin_jj::Repo::open(&fx.fixture.path).expect("open");
    let mut commit1 = None;
    let _ = repo.eval_revset("description(exact:'described')", |change| {
        commit1 = Some(change.id);
        std::ops::ControlFlow::Break(())
    });
    let commit1 = repo
        .get_change(&commit1.expect("the described commit"))
        .expect("change");
    test_helpers::set_remote_bookmark(&fx.fixture.path, "main", "origin", &commit1.commit_id.0, true);

    let req = edit_request(
        fbs::RequestKind::OpRestore,
        Some("@--"),
        Some(&[fbs::RestoreWhat::RemoteTracking]),
    );
    let bytes = unsafe { read_and_free(zanshin_op_restore(fx.handle, req.as_ptr(), req.len())) };
    assert!(parse_envelope(&bytes).ok(), "{:?}", error_code(&bytes));

    let options = zanshin_jj::BookmarkListOptions {
        all_remotes: true,
        ..Default::default()
    };
    let bookmarks = repo.list_bookmarks(&options).expect("bookmarks");
    assert!(bookmarks.iter().all(|b| b.name != "main"), "{bookmarks:?}");
    assert_eq!(repo.get_change(&commit1.id).expect("change").description, "described");
}
