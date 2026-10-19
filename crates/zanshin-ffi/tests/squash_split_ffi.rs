// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.15's three wrappers: `zanshin_squash`, `zanshin_squash_plan`
//! and `zanshin_split`.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The repo is built in-test with
//! `zanshin_jj`'s own verbs: `A (a.txt) → B (b.txt) → C (c.txt, c2.txt) = @`, descriptions
//! `A\n`, `B\n`, `C\n`.

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use flatbuffers::root as fb_root;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::squash_split::{zanshin_split, zanshin_squash, zanshin_squash_plan};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CHANGE_NOT_FOUND, JJ_INVALID_INPUT,
    JJ_SPLIT_ALL_SELECTED,
};
use zanshin_jj::{Backend, ChangeId, Repo};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: every test calls `pin_env()` FIRST; the `LazyLock` blocks them all until this
    // initialiser returns, so no test body has read the environment yet.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", test_helpers::leaked_xdg_config_home());
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

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
    pin_env();
    let tmp = tempfile::TempDir::new().expect("tempdir");
    let main = tmp.path().join("main");
    fs::create_dir(&main).expect("main dir");
    let root = Repo::init(&main, Some(Backend::Git))
        .result
        .expect("init")
        .workspace_root()
        .to_owned();
    let mut repo = Repo::open(&root).expect("open");
    let mut ids = Vec::new();
    for (files, description) in [
        (&[("a.txt", "a\n")][..], "A\n"),
        (&[("b.txt", "b\n")][..], "B\n"),
        (&[("c.txt", "c\n"), ("c2.txt", "c2\n")][..], "C\n"),
    ] {
        if let Some(parent) = ids.last() {
            repo.new_change(std::slice::from_ref(parent), &[], &[]).expect("new");
        }
        for (path, text) in files {
            fs::write(root.join(path), text).expect("write");
        }
        let at = repo.status().expect("status").working_copy_change_id;
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
        b: ids[1].0.clone(),
        c: ids[2].0.clone(),
    }
}

fn head_op(root: &Path) -> String {
    Repo::open(root)
        .expect("open")
        .op_log(Some(1))
        .expect("op log")
        .swap_remove(0)
        .id
        .0
}

fn description_of(root: &Path, id: &str) -> String {
    Repo::open(root)
        .expect("open")
        .get_change(&ChangeId(id.to_owned()))
        .expect("change")
        .description
}

fn strings<'a>(
    b: &mut flatbuffers::FlatBufferBuilder<'a>,
    items: Option<&[&str]>,
) -> Option<flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<&'a str>>>> {
    items.map(|items| {
        let offsets: Vec<_> = items.iter().map(|s| b.create_string(s)).collect();
        b.create_vector(&offsets)
    })
}

/// A `SquashRequest`: `revision`, `into`, `message` (absent = no `-m`), `paths`.
fn squash_request(revision: Option<&str>, into: Option<&str>, message: Option<&[&str]>, paths: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let revision = revision.map(|s| b.create_string(s));
    let into = into.map(|s| b.create_string(s));
    let message = strings(&mut b, message);
    let paths = strings(&mut b, Some(paths));
    let req = fbs::SquashRequest::create(
        &mut b,
        &fbs::SquashRequestArgs {
            kind: fbs::RequestKind::Squash,
            revision,
            into,
            message,
            paths,
            ..fbs::SquashRequestArgs::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A `SplitRequest` of `@`: `paths`, `-m first`, and an `onto` (absent = flag not given).
fn split_request(paths: &[&str], onto: Option<&[&str]>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let paths = strings(&mut b, Some(paths));
    let message = strings(&mut b, Some(&["first"]));
    let onto = strings(&mut b, onto);
    let req = fbs::SplitRequest::create(
        &mut b,
        &fbs::SplitRequestArgs {
            kind: fbs::RequestKind::Split,
            paths,
            message,
            onto,
            ..fbs::SplitRequestArgs::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

#[test]
fn the_plan_text_passed_back_as_message_squashes_c_into_b() {
    let fx = base();
    let before = head_op(&fx.root);

    let req = squash_request(None, None, None, &[]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_squash_plan(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let text = env
        .data_as_squash_plan()
        .expect("SquashPlan payload")
        .combined_description()
        .expect("the editor case")
        .to_owned();
    assert_eq!(text, "B\n\nC\n");
    assert_eq!(head_op(&fx.root), before, "the plan writes no operation");

    let req = squash_request(None, None, Some(&[&text]), &[]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_squash(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let mutation = env.data_as_mutation_result().expect("MutationResult payload");
    assert_eq!(
        mutation.abandoned_change_ids().map(|v| v.iter().collect::<Vec<_>>()),
        Some(vec![fx.c.as_str()])
    );
    assert_eq!(mutation.new_change_ids().map(|v| v.len()), Some(1), "a new @");
    assert_eq!(mutation.new_op_id(), Some(head_op(&fx.root).as_str()));
    assert_eq!(description_of(&fx.root, &fx.b), text);
}

#[test]
fn a_plan_with_a_message_has_nothing_to_ask() {
    let fx = base();
    let req = squash_request(None, None, Some(&["m"]), &[]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_squash_plan(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok());
    assert!(env
        .data_as_squash_plan()
        .expect("SquashPlan payload")
        .combined_description()
        .is_none());
}

#[test]
fn squashing_at_into_itself_answers_the_pre_call_head() {
    let fx = base();
    let before = head_op(&fx.root);
    let req = squash_request(None, Some(&fx.c), None, &[]);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_squash(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok());
    assert_eq!(
        env.data_as_mutation_result().and_then(|m| m.new_op_id()),
        Some(before.as_str())
    );
    assert_eq!(head_op(&fx.root), before);
}

#[test]
fn refusals_carry_their_code_and_write_nothing() {
    let fx = base();
    let before = head_op(&fx.root);

    let conflicting = squash_request(Some(&fx.c), Some(&fx.b), None, &[]);
    // SAFETY: `fx.handle` is open; the buffers are live for each call.
    let bytes = unsafe { read_and_free(zanshin_squash(fx.handle, conflicting.as_ptr(), conflicting.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_squash_plan(fx.handle, conflicting.as_ptr(), conflicting.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));

    let unknown = squash_request(Some(&"k".repeat(32)), None, None, &[]);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_squash(fx.handle, unknown.as_ptr(), unknown.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_CHANGE_NOT_FOUND));

    let no_paths = split_request(&[], None);
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_split(fx.handle, no_paths.as_ptr(), no_paths.len())) };
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_INVALID_INPUT));

    // A PRESENT empty location is a value — the flag given with no revision: no parent.
    let empty_onto = split_request(&["c.txt"], Some(&[]));
    // SAFETY: as above.
    let bytes = unsafe { read_and_free(zanshin_split(fx.handle, empty_onto.as_ptr(), empty_onto.len())) };
    let env = parse_envelope(&bytes);
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));
    assert_eq!(
        env.error().and_then(|e| e.context()),
        Some("No revisions found to use as parent")
    );

    assert_eq!(head_op(&fx.root), before, "no refusal wrote an operation");
}

#[test]
fn split_names_both_parts_and_carries_its_warning() {
    let fx = base();
    let req = split_request(&["c.txt", "c2.txt"], None);
    // SAFETY: `fx.handle` is open; `req` is a live buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_split(fx.handle, req.as_ptr(), req.len())) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    let split = env.data_as_split_result().expect("SplitResult payload");
    assert_eq!(split.selected_change_id(), Some(fx.c.as_str()));
    let remaining = split.remaining_change_id().expect("remaining").to_owned();
    assert_eq!(
        split
            .mutation()
            .and_then(|m| m.new_change_ids())
            .map(|v| v.iter().collect::<Vec<_>>()),
        Some(vec![remaining.as_str()])
    );
    assert_eq!(
        split.mutation().and_then(|m| m.working_copy_change_id()),
        Some(remaining.as_str())
    );
    let codes: Vec<&str> = env
        .warnings()
        .map(|w| w.iter().filter_map(|w| w.code()).collect())
        .unwrap_or_default();
    assert_eq!(codes, [JJ_SPLIT_ALL_SELECTED]);
    assert_eq!(description_of(&fx.root, &fx.c), "first\n");
}

#[test]
fn every_wrapper_refuses_a_zero_handle() {
    pin_env();
    let squash = squash_request(None, None, None, &[]);
    let split = split_request(&["c.txt"], None);
    // SAFETY: zero is the documented invalid handle; the buffers are live for each call.
    let codes = unsafe {
        [
            error_code(&read_and_free(zanshin_squash(0, squash.as_ptr(), squash.len()))),
            error_code(&read_and_free(zanshin_squash_plan(0, squash.as_ptr(), squash.len()))),
            error_code(&read_and_free(zanshin_split(0, split.as_ptr(), split.len()))),
        ]
    };
    for code in codes {
        assert_eq!(code.as_deref(), Some(FFI_INVALID_HANDLE));
    }
}

#[test]
fn malformed_null_and_mis_routed_buffers_are_refused_before_the_handle() {
    pin_env();
    let junk = [0xffu8; 7];
    let squash = squash_request(None, None, None, &[]);
    let split = split_request(&["c.txt"], None);
    // SAFETY: zero handle — every refusal fires before the handle is borrowed; the buffers are
    // live for each call and a null pointer is the documented refusal.
    unsafe {
        assert_eq!(
            error_code(&read_and_free(zanshin_squash(0, std::ptr::null(), 0))).as_deref(),
            Some(FFI_NULL_POINTER)
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_split(0, std::ptr::null(), 0))).as_deref(),
            Some(FFI_NULL_POINTER)
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_squash_plan(0, junk.as_ptr(), junk.len()))).as_deref(),
            Some(FFI_INVALID_ARGUMENT)
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_split(0, junk.as_ptr(), junk.len()))).as_deref(),
            Some(FFI_INVALID_ARGUMENT)
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_squash(0, split.as_ptr(), split.len()))).as_deref(),
            Some(FFI_INVALID_ARGUMENT),
            "a SplitRequest is not a SquashRequest"
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_split(0, squash.as_ptr(), squash.len()))).as_deref(),
            Some(FFI_INVALID_ARGUMENT),
            "and vice versa"
        );
    }
}
