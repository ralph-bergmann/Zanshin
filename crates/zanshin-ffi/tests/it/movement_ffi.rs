// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.10's two wrappers: `zanshin_move_working_copy` and
//! `zanshin_movement_targets`.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The repo is built in-test with
//! `zanshin_jj`'s own verbs: `A (a.txt) → B (b.txt) → C (c.txt) = @`.

use std::ffi::CString;
use std::fs;
use std::path::{Path, PathBuf};

use flatbuffers::root as fb_root;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::movement::{zanshin_move_working_copy, zanshin_movement_targets};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_INVALID_INPUT, JJ_STALE_SELECTION};
use zanshin_jj::{Backend, ChangeId, Repo};

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

fn error_code(bytes: &[u8]) -> Option<String> {
    parse_envelope(bytes)
        .error()
        .and_then(|e| e.code())
        .map(ToOwned::to_owned)
}

/// The base repo, its open handle, and the three change ids.
struct Fx {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    handle: u64,
    a: String,
    b: String,
    c: String,
}

impl Drop for Fx {
    fn drop(&mut self) {
        // SAFETY: the handle came from `zanshin_repo_open` below and is closed exactly once.
        let bytes = unsafe { read_and_free(zanshin_repo_close(self.handle)) };
        assert!(parse_envelope(&bytes).ok());
    }
}

fn base() -> Fx {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().expect("tempdir");
    let main = tmp.path().join("main");
    fs::create_dir(&main).expect("main dir");
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: PathBuf::from(&main),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init")
    .workspace_root()
    .to_owned();
    let mut repo = Repo::open(&root).expect("open");
    let mut ids: Vec<ChangeId> = Vec::new();
    for (path, description) in [("a.txt", "A\n"), ("b.txt", "B\n"), ("c.txt", "C\n")] {
        if let Some(parent) = ids.last() {
            repo.new_change(std::slice::from_ref(parent), &[], &[]).expect("new");
        }
        fs::write(root.join(path), "x\n").expect("write");
        let at = repo.status().expect("status").working_copy_change_id.expect("@");
        repo.describe(at.clone(), description).expect("describe");
        ids.push(at);
    }
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
        a: ids[0].0.clone(),
        b: ids[1].0.clone(),
        c: ids[2].0.clone(),
    }
}

/// The head operation: its id and description.
fn head_op(root: &Path) -> (String, String) {
    let op = Repo::open(root)
        .expect("open")
        .op_log(Some(1))
        .expect("op log")
        .swap_remove(0);
    (op.id.0, op.description)
}

fn commit_hex(root: &Path, id: &str) -> String {
    Repo::open(root)
        .expect("open")
        .get_change(&ChangeId(id.to_owned()))
        .expect("change")
        .commit_id
        .0
}

/// `@`'s change id.
fn at(root: &Path) -> String {
    Repo::open(root)
        .expect("open")
        .status()
        .expect("status")
        .working_copy_change_id
        .expect("@")
        .0
}

/// A `MovementRequest`. `kind` lets a test mis-tag it.
#[derive(Default)]
struct Req<'a> {
    kind: Option<fbs::RequestKind>,
    direction: fbs::MovementDirection,
    offset: Option<u64>,
    edit: bool,
    no_edit: bool,
    conflict: bool,
    target: Option<&'a str>,
}

fn request(req: &Req<'_>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let target = req.target.map(|t| b.create_string(t));
    let offset = req.offset.map(fbs::MovementOffset::new);
    let built = fbs::MovementRequest::create(
        &mut b,
        &fbs::MovementRequestArgs {
            kind: req.kind.unwrap_or(fbs::RequestKind::Movement),
            direction: req.direction,
            offset: offset.as_ref(),
            edit: req.edit,
            no_edit: req.no_edit,
            conflict: req.conflict,
            target,
        },
    );
    b.finish(built, None);
    b.finished_data().to_vec()
}

fn move_wc(fx: &Fx, req: &Req<'_>) -> Vec<u8> {
    let req = request(req);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    unsafe { read_and_free(zanshin_move_working_copy(fx.handle, req.as_ptr(), req.len())) }
}

fn targets(fx: &Fx, req: &Req<'_>) -> Vec<u8> {
    let req = request(req);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    unsafe { read_and_free(zanshin_movement_targets(fx.handle, req.as_ptr(), req.len())) }
}

#[test]
fn prev_edit_moves_and_returns_a_mutation_result() {
    let fx = base();
    let (c_hex, b_hex) = (commit_hex(&fx.root, &fx.c), commit_hex(&fx.root, &fx.b));
    let bytes = move_wc(
        &fx,
        &Req {
            direction: fbs::MovementDirection::Prev,
            edit: true,
            ..Req::default()
        },
    );
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    assert!(env.precondition().is_some(), "the pre-verb snapshot ran");
    let mutation = env.data_as_mutation_result().expect("MutationResult");
    let (op_id, description) = head_op(&fx.root);
    assert_eq!(
        description,
        format!("prev: {} -> editing {}", &c_hex[..12], &b_hex[..12])
    );
    assert_eq!(mutation.new_op_id(), Some(op_id.as_str()));
    assert_eq!(mutation.working_copy_change_id(), Some(fx.b.as_str()));
}

#[test]
fn a_present_offset_and_target_are_read() {
    let fx = base();
    let a_hex = commit_hex(&fx.root, &fx.a);
    let bytes = move_wc(
        &fx,
        &Req {
            direction: fbs::MovementDirection::Prev,
            edit: true,
            offset: Some(2),
            target: Some(&a_hex),
            ..Req::default()
        },
    );
    assert!(parse_envelope(&bytes).ok(), "{:?}", error_code(&bytes));
    assert_eq!(at(&fx.root), fx.a, "two back, the chosen candidate");
}

#[test]
fn the_targets_envelope_lists_the_candidates() {
    let fx = base();
    let before = head_op(&fx.root);
    let bytes = targets(
        &fx,
        &Req {
            direction: fbs::MovementDirection::Prev,
            no_edit: true,
            ..Req::default()
        },
    );
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let movement = env.data_as_movement_targets().expect("MovementTargets");
    assert!(!movement.edit());
    let listed: Vec<(String, String)> = movement
        .targets()
        .expect("targets")
        .iter()
        .map(|t| {
            (
                t.commit_id().expect("commit").to_owned(),
                t.change_id().expect("change").to_owned(),
            )
        })
        .collect();
    assert_eq!(listed, [(commit_hex(&fx.root, &fx.a), fx.a.clone())]);
    assert_eq!(head_op(&fx.root), before, "no operation on a clean working copy");
}

#[test]
fn a_not_found_refusal_carries_its_hints_and_writes_nothing() {
    let fx = base();
    let before = head_op(&fx.root);
    let bytes = move_wc(&fx, &Req::default());
    let env = parse_envelope(&bytes);
    let error = env.error().expect("error");
    assert_eq!(error.code(), Some(JJ_INVALID_INPUT));
    assert_eq!(
        error.context(),
        Some("No other descendant found 1 commit(s) forward from the working copy parent(s)")
    );
    let hints: Vec<&str> = error.hints().expect("hints").iter().collect();
    assert_eq!(hints.len(), 1);
    assert!(
        hints[0].starts_with("Working copy parent: ") && hints[0].ends_with(" B"),
        "{hints:?}"
    );
    assert_eq!(head_op(&fx.root), before);
}

#[test]
fn a_non_candidate_target_is_stale_and_clap_refusals_skip_the_snapshot() {
    let fx = base();
    let before = head_op(&fx.root);
    let c_hex = commit_hex(&fx.root, &fx.c);
    let bytes = move_wc(
        &fx,
        &Req {
            direction: fbs::MovementDirection::Prev,
            target: Some(&c_hex),
            ..Req::default()
        },
    );
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_STALE_SELECTION));

    // A present offset with `conflict` is clap's refusal; an absent one is not.
    let clap = Req {
        direction: fbs::MovementDirection::Prev,
        offset: Some(1),
        conflict: true,
        ..Req::default()
    };
    for bytes in [move_wc(&fx, &clap), targets(&fx, &clap)] {
        assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
        assert!(parse_envelope(&bytes).precondition().is_none(), "no snapshot ran");
    }
    let past_clap = Req {
        direction: fbs::MovementDirection::Prev,
        conflict: true,
        ..Req::default()
    };
    let bytes = move_wc(&fx, &past_clap);
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert!(parse_envelope(&bytes).precondition().is_some(), "the snapshot ran");
    assert_eq!(head_op(&fx.root), before, "no refusal wrote an operation");
}

#[test]
fn malformed_and_mis_tagged_buffers_refuse_before_the_handle() {
    test_helpers::pin_test_env();
    let garbage = [1_u8, 2, 3];
    let mis_tagged = request(&Req {
        kind: Some(fbs::RequestKind::Metaedit),
        ..Req::default()
    });
    let mut b = flatbuffers::FlatBufferBuilder::new();
    let bad_direction = fbs::MovementRequest::create(
        &mut b,
        &fbs::MovementRequestArgs {
            kind: fbs::RequestKind::Movement,
            direction: fbs::MovementDirection(9),
            ..Default::default()
        },
    );
    b.finish(bad_direction, None);
    let bad_direction = b.finished_data().to_vec();
    // SAFETY: zero is the documented invalid handle; the buffers are live for each call, and a
    // null `data` is the documented null-pointer case.
    let codes = unsafe {
        [
            error_code(&read_and_free(zanshin_move_working_copy(
                0,
                garbage.as_ptr(),
                garbage.len(),
            ))),
            error_code(&read_and_free(zanshin_movement_targets(
                0,
                mis_tagged.as_ptr(),
                mis_tagged.len(),
            ))),
            error_code(&read_and_free(zanshin_move_working_copy(
                0,
                bad_direction.as_ptr(),
                bad_direction.len(),
            ))),
            error_code(&read_and_free(zanshin_movement_targets(0, std::ptr::null(), 0))),
        ]
    };
    assert_eq!(
        codes.each_ref().map(Option::as_deref),
        [
            Some(FFI_INVALID_ARGUMENT),
            Some(FFI_INVALID_ARGUMENT),
            Some(FFI_INVALID_ARGUMENT),
            Some(FFI_NULL_POINTER)
        ]
    );
}

#[test]
fn both_wrappers_refuse_a_zero_handle() {
    test_helpers::pin_test_env();
    let req = request(&Req::default());
    // SAFETY: zero is the documented invalid handle; the buffer is live for each call.
    let codes = unsafe {
        [
            error_code(&read_and_free(zanshin_move_working_copy(0, req.as_ptr(), req.len()))),
            error_code(&read_and_free(zanshin_movement_targets(0, req.as_ptr(), req.len()))),
        ]
    };
    assert_eq!(codes.each_ref().map(Option::as_deref), [Some(FFI_INVALID_HANDLE); 2]);
}
