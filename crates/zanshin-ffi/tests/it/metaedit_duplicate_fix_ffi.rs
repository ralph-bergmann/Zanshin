// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.9's three wrappers: `zanshin_metaedit`, `zanshin_duplicate` and
//! `zanshin_fix`.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The repo is built in-test with
//! `zanshin_jj`'s own verbs: `A (a.txt) → B (b.txt) → C (c.txt) = @`, each file holding `x`, with
//! a `fix.tools` entry upper-casing `*.txt`.

use std::ffi::CString;
use std::fs;
use std::path::{Path, PathBuf};

use flatbuffers::root as fb_root;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::metaedit_duplicate_fix::{zanshin_duplicate, zanshin_fix, zanshin_metaedit};
use zanshin_ffi::repo::{zanshin_network_cancel, zanshin_network_token, zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CANCELLED, JJ_DUPLICATE_AS_OWN_DESCENDANT,
    JJ_IMMUTABLE, JJ_INVALID_INPUT,
};
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
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "[fix.tools.upper]\ncommand = ['tr', 'a-z', 'A-Z']\npatterns = [\"glob:'*.txt'\"]\n",
    )
    .expect("repo config");
    let mut repo = Repo::open(&root).expect("open");
    let mut ids = Vec::new();
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

fn strings<'a>(
    b: &mut flatbuffers::FlatBufferBuilder<'a>,
    items: &[&str],
) -> Option<flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<&'a str>>>> {
    (!items.is_empty()).then(|| {
        let offsets: Vec<_> = items.iter().map(|s| b.create_string(s)).collect();
        b.create_vector(&offsets)
    })
}

/// A `MetaeditRequest`: `revisions`, an optional `-m`, `--author` and `--update-author`.
fn metaedit_request(revisions: &[&str], message: Option<&str>, author: Option<&str>, update_author: bool) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let revisions = strings(&mut b, revisions);
    let message = message.map(|m| {
        let m = b.create_string(m);
        b.create_vector(&[m])
    });
    let author = author.map(|a| b.create_string(a));
    let req = fbs::MetaeditRequest::create(
        &mut b,
        &fbs::MetaeditRequestArgs {
            kind: fbs::RequestKind::Metaedit,
            revisions,
            message,
            author,
            update_author,
            ..fbs::MetaeditRequestArgs::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `DuplicateRequest`: `revisions` and `-o onto` (empty = absent).
fn duplicate_request(revisions: &[&str], onto: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let revisions = strings(&mut b, revisions);
    let onto = strings(&mut b, onto);
    let req = fbs::DuplicateRequest::create(
        &mut b,
        &fbs::DuplicateRequestArgs {
            kind: fbs::RequestKind::Duplicate,
            revisions,
            onto,
            ..fbs::DuplicateRequestArgs::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `FixRequest`: `-s source` (empty = absent, the `revsets.fix` default).
fn fix_request(source: &[&str]) -> Vec<u8> {
    fix_request_with_token(source, 0)
}

/// [`fix_request`] carrying `cancel_token`.
fn fix_request_with_token(source: &[&str], cancel_token: u64) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let source = strings(&mut b, source);
    let req = fbs::FixRequest::create(
        &mut b,
        &fbs::FixRequestArgs {
            kind: fbs::RequestKind::Fix,
            source,
            cancel_token,
            ..fbs::FixRequestArgs::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Asserts `bytes` is ok and `new_op_id` is the head described `description`.
fn assert_written(fx: &Fx, bytes: &[u8], new_op_id: Option<&str>, description: &str) {
    let env = parse_envelope(bytes);
    assert!(env.ok(), "{:?}", error_code(bytes));
    let (op_id, op_description) = head_op(&fx.root);
    assert_eq!(op_description, description);
    assert_eq!(new_op_id, Some(op_id.as_str()));
}

#[test]
fn metaedit_describes_a_revision() {
    let fx = base();
    let b_hex = commit_hex(&fx.root, &fx.b);
    let req = metaedit_request(&[&fx.b], Some("X"), None, false);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_metaedit(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.precondition().is_some(), "the pre-verb snapshot ran");
    let new_op_id = env.data_as_mutation_result().and_then(|m| m.new_op_id());
    assert_written(
        &fx,
        &bytes,
        new_op_id,
        &format!("edit commit metadata for commit {b_hex}"),
    );
    let description = Repo::open(&fx.root)
        .expect("open")
        .get_change(&ChangeId(fx.b.clone()))
        .expect("change")
        .description;
    assert_eq!(description, "X\n");
}

#[test]
fn duplicate_copies_a_revision_and_its_warning_reaches_the_envelope() {
    let fx = base();
    let req = duplicate_request(&[&fx.a], &[&fx.c]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_duplicate(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    let mutation = env.data_as_mutation_result().expect("MutationResult");
    assert_written(&fx, &bytes, mutation.new_op_id(), "duplicate 1 commit(s)");
    assert_eq!(mutation.new_change_ids().map(|v| v.len()), Some(1));
    let codes: Vec<&str> = env
        .warnings()
        .expect("warnings")
        .iter()
        .filter_map(|w| w.code())
        .collect();
    assert_eq!(codes, [JJ_DUPLICATE_AS_OWN_DESCENDANT]);
}

#[test]
fn fix_runs_the_tools_and_a_second_run_writes_nothing() {
    let fx = base();
    let req = fix_request(&[]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_fix(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    let fix = env.data_as_fix_result().expect("FixResult");
    assert_written(
        &fx,
        &bytes,
        fix.mutation().and_then(|m| m.new_op_id()),
        "fixed 3 commits",
    );
    assert_eq!((fix.num_fixed_commits(), fix.num_checked_commits()), (3, 3));
    assert_eq!(fix.tool_stderr().map(|v| v.len()), Some(0));

    let before = head_op(&fx.root).0;
    let req = fix_request(&[&fx.c]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_fix(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let fix = env.data_as_fix_result().expect("FixResult");
    assert_eq!(fix.num_fixed_commits(), 0);
    assert_eq!(
        fix.mutation().and_then(|m| m.new_op_id()),
        Some(before.as_str()),
        "the pre-call head"
    );
    assert_eq!(head_op(&fx.root).0, before);
}

#[test]
fn a_fix_whose_token_was_cancelled_refuses_jj_cancelled_and_writes_nothing() {
    let fx = base();
    let before = head_op(&fx.root);
    let token = zanshin_network_token();
    zanshin_network_cancel(token);
    let req = fix_request_with_token(&[], token);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_fix(fx.handle, req.as_ptr(), req.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_CANCELLED));
    assert_eq!(head_op(&fx.root), before, "no operation");

    // An uncancelled token fixes as without one.
    let req = fix_request_with_token(&[], zanshin_network_token());
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_fix(fx.handle, req.as_ptr(), req.len())) };
    let fix = parse_envelope(&bytes).data_as_fix_result().expect("FixResult");
    assert_eq!(fix.num_fixed_commits(), 3);
}

#[test]
fn refusals_carry_their_code_and_write_nothing() {
    let fx = base();
    let before = head_op(&fx.root).0;
    let root_change = "z".repeat(32);

    // `--author` with `--update-author`: clap's conflict, before the snapshot.
    let conflicting = metaedit_request(&[], None, Some("Foo <foo@bar>"), true);
    // SAFETY: `fx.handle` is open; the buffers are live for each call.
    let bytes = unsafe { read_and_free(zanshin_metaedit(fx.handle, conflicting.as_ptr(), conflicting.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    assert!(parse_envelope(&bytes).precondition().is_none(), "no snapshot ran");

    let root_metaedit = metaedit_request(&[&root_change], Some("X"), None, false);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_metaedit(fx.handle, root_metaedit.as_ptr(), root_metaedit.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_IMMUTABLE));

    let root_duplicate = duplicate_request(&[&root_change], &[]);
    // SAFETY: as above.
    let bytes = unsafe {
        read_and_free(zanshin_duplicate(
            fx.handle,
            root_duplicate.as_ptr(),
            root_duplicate.len(),
        ))
    };
    let env = parse_envelope(&bytes);
    let error = env.error().expect("error");
    assert_eq!(error.code(), Some(JJ_INVALID_INPUT));
    assert_eq!(error.context(), Some("Cannot duplicate the root commit"));

    let root_fix = fix_request(&[&root_change]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_fix(fx.handle, root_fix.as_ptr(), root_fix.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_IMMUTABLE));

    assert_eq!(head_op(&fx.root).0, before, "no refusal wrote an operation");
}

#[test]
fn malformed_and_mis_tagged_buffers_refuse_before_the_handle() {
    test_helpers::pin_test_env();
    let garbage = [1_u8, 2, 3];
    let fix = fix_request(&[]);
    let metaedit = metaedit_request(&[], None, None, false);
    // SAFETY: zero is the documented invalid handle; the buffers are live for each call, and a
    // null `data` is the documented null-pointer case.
    let codes = unsafe {
        [
            error_code(&read_and_free(zanshin_metaedit(0, garbage.as_ptr(), garbage.len()))),
            error_code(&read_and_free(zanshin_duplicate(0, fix.as_ptr(), fix.len()))),
            error_code(&read_and_free(zanshin_fix(0, metaedit.as_ptr(), metaedit.len()))),
            error_code(&read_and_free(zanshin_metaedit(0, std::ptr::null(), 0))),
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
fn every_wrapper_refuses_a_zero_handle() {
    test_helpers::pin_test_env();
    let metaedit = metaedit_request(&[], None, None, false);
    let duplicate = duplicate_request(&[], &[]);
    let fix = fix_request(&[]);
    // SAFETY: zero is the documented invalid handle; the buffers are live for each call.
    let codes = unsafe {
        [
            error_code(&read_and_free(zanshin_metaedit(0, metaedit.as_ptr(), metaedit.len()))),
            error_code(&read_and_free(zanshin_duplicate(
                0,
                duplicate.as_ptr(),
                duplicate.len(),
            ))),
            error_code(&read_and_free(zanshin_fix(0, fix.as_ptr(), fix.len()))),
        ]
    };
    assert_eq!(codes.each_ref().map(Option::as_deref), [Some(FFI_INVALID_HANDLE); 3]);
}
