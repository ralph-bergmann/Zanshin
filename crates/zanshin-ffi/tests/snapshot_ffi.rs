// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.26's wire contract: `zanshin_snapshot` and the
//! `Envelope.precondition` table every envelope of a snapshotting symbol carries.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The jj-level BEHAVIOUR (the op-log
//! sequence, the colocated rows, the three stale causes) is pinned in
//! `crates/zanshin-jj/tests/snapshot_*.rs`; what is tested here is the envelope: the report on a
//! read, on a mutation, on `zanshin_snapshot` itself (ok with NO `data`), and on an ERROR
//! envelope — and its ABSENCE on the symbols that run no precondition (AC-3).
//!
//! Repos are built in-test through `zanshin_jj` (a regular dependency of this crate): the rows
//! need files on disk, which the committed fixtures do not model.

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use flatbuffers::root as fb_root;
use tempfile::TempDir;
use zanshin_ffi::bookmark_ops::zanshin_bookmark_create;
use zanshin_ffi::bookmarks::zanshin_bookmarks;
use zanshin_ffi::change::zanshin_change;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::log_defaults::zanshin_log_defaults;
use zanshin_ffi::op_log::zanshin_op_log;
use zanshin_ffi::remotes::zanshin_remotes;
use zanshin_ffi::repo::{zanshin_describe, zanshin_repo_close, zanshin_repo_detect, zanshin_repo_open};
use zanshin_ffi::snapshot::zanshin_snapshot;
use zanshin_ffi::status::zanshin_status;
use zanshin_ffi::workspace::zanshin_workspace_root;
use zanshin_ffi::{FFI_INVALID_HANDLE, JJ_CHANGE_NOT_FOUND, JJ_CONFIG_ERROR, JJ_STALE_WORKING_COPY};
use zanshin_jj::{Backend, ChangeId, Repo};

// ── Env pin ───────────────────────────────────────────────────────────────────

/// The shared test env plus a leaked `$XDG_CONFIG_HOME`: the snapshot's global-excludes
/// fallback is `$XDG_CONFIG_HOME/git/ignore`, and the developer's real one must not decide
/// which test file gets snapshotted.
static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    let xdg = TempDir::new().expect("xdg tempdir").keep();
    // SAFETY: every test calls `pin_env()` first; the `LazyLock` blocks them all until this
    // initialiser returns, so no test body has read the environment yet.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", &xdg);
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

// ── Envelope helpers ──────────────────────────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by one of the `zanshin_*` functions
/// and not yet freed.
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

fn c_path(path: &Path) -> CString {
    CString::new(path.to_str().expect("UTF-8 path")).expect("no NUL")
}

fn open_handle(path: &Path) -> u64 {
    let p = c_path(path);
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let token = unsafe { zanshin_repo_open(p.as_ptr()) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "expected ok, error: {:?}", env.error().and_then(|e| e.code()));
    assert!(env.precondition().is_none(), "open runs no precondition");
    env.data_as_repo_handle().expect("RepoHandle payload").handle()
}

fn close_handle(handle: u64) {
    // SAFETY: handle originated from open_handle and has not been closed.
    let token = unsafe { zanshin_repo_close(handle) };
    // SAFETY: fresh, non-null token.
    let bytes = unsafe { read_and_free(token) };
    assert!(parse_envelope(&bytes).ok(), "repo close must succeed");
}

/// A fresh git-backed (not colocated) repo with a clean working copy.
fn fresh_repo() -> (TempDir, PathBuf) {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let root = Repo::init(tmp.path(), Some(Backend::Git))
        .expect("init")
        .workspace_root()
        .to_owned();
    (tmp, root)
}

/// Runs `zanshin_snapshot` and returns the envelope bytes.
fn snapshot(handle: u64) -> Vec<u8> {
    // SAFETY: handle is live (or 0, which the wrapper refuses).
    let token = unsafe { zanshin_snapshot(handle) };
    // SAFETY: fresh, non-null token.
    unsafe { read_and_free(token) }
}

// ── zanshin_snapshot ──────────────────────────────────────────────────────────

#[test]
fn snapshot_of_a_dirty_tree_is_ok_with_no_data_and_the_report_as_precondition() {
    let (_tmp, root) = fresh_repo();
    let handle = open_handle(&root);
    fs::write(root.join("dirty.txt"), "dirty\n").expect("write");

    let bytes = snapshot(handle);

    let env = parse_envelope(&bytes);
    assert!(env.ok());
    assert_eq!(env.data_type(), fbs::Payload::NONE, "no payload member for the report");
    let p = env.precondition().expect("the report rides Envelope.precondition");
    assert!(p.was_snapshot_taken());
    let stats = p.snapshot_stats().expect("snapshot_stats is always written");
    assert_eq!(stats.untracked().map_or(0, |u| u.len()), 0);
    assert!(p.git_refs().is_none(), "not colocated: the refs import never ran");
    assert!(
        p.finish().is_none(),
        "null for absence: every finish fact at its default"
    );
    assert!(!p.git_head_imported());

    // The next call finds nothing left to snapshot.
    let again = snapshot(handle);
    assert!(!parse_envelope(&again)
        .precondition()
        .expect("report")
        .was_snapshot_taken());
    close_handle(handle);
}

#[test]
fn snapshot_of_handle_zero_is_ffi_invalid_handle_without_a_report() {
    let bytes = snapshot(0);

    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_HANDLE));
    assert!(env.precondition().is_none(), "no repo was reached, so nothing ran");
}

#[test]
fn a_stale_working_copy_is_jj_stale_working_copy_with_the_three_line_context() {
    let (_tmp, root) = fresh_repo();
    let at = {
        let mut repo = Repo::open(&root).expect("open");
        let wc: ChangeId = repo.status().expect("status").working_copy_change_id;
        repo.get_change(&wc).expect("change").commit_id.0
    };
    let handle = open_handle(&root);
    // `@` rewritten by another writer that never checked it out.
    let _ = test_helpers::rewrite_commit_files(&root, &at, &[("elsewhere.txt", "x")]);

    let bytes = snapshot(handle);

    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    let err = env.error().expect("error");
    assert_eq!(err.code(), Some(JJ_STALE_WORKING_COPY));
    let context: Vec<&str> = err.context().expect("context").split('\n').collect();
    assert_eq!(context.len(), 3, "<cause>\\n<wc_op>\\n<repo_op>: {context:?}");
    assert_eq!(context[0], "stale");
    assert_eq!(context[1].len(), 128, "the working copy's operation id");
    assert_eq!(context[2].len(), 128, "the repo's operation id");
    let p = env.precondition().expect("the partial report rides the error envelope");
    assert!(!p.was_snapshot_taken());
    close_handle(handle);
}

#[test]
fn a_wrong_typed_knob_is_jj_config_error_with_a_partial_report() {
    let (_tmp, root) = fresh_repo();
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "snapshot.auto-track = 5\n",
    )
    .expect("config");
    let handle = open_handle(&root);

    let bytes = snapshot(handle);

    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    let err = env.error().expect("error");
    assert_eq!(err.code(), Some(JJ_CONFIG_ERROR));
    assert!(
        err.context().is_some_and(|c| c.contains("snapshot.auto-track")),
        "{:?}",
        err.context()
    );
    assert!(!env.precondition().expect("partial report").was_snapshot_taken());
    close_handle(handle);
}

// ── The report on other envelopes (AC-3) ──────────────────────────────────────

#[test]
fn a_read_envelope_carries_the_report_of_its_pre_verb_snapshot() {
    let (_tmp, root) = fresh_repo();
    let handle = open_handle(&root);
    fs::write(root.join("dirty.txt"), "dirty\n").expect("write");

    // SAFETY: handle is live.
    let bytes = unsafe { read_and_free(zanshin_status(handle)) };

    let env = parse_envelope(&bytes);
    assert!(env.ok());
    assert!(env.data_as_status().is_some());
    assert!(env.precondition().expect("report").was_snapshot_taken());
    close_handle(handle);
}

#[test]
fn an_error_envelope_carries_the_report_of_the_snapshot_that_ran_before_it() {
    let (_tmp, root) = fresh_repo();
    let handle = open_handle(&root);
    fs::write(root.join("dirty.txt"), "dirty\n").expect("write");
    let missing = CString::new("yyyyyyyyyyyy").expect("no NUL");

    // SAFETY: handle is live; `missing` is a valid C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_change(handle, missing.as_ptr())) };

    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CHANGE_NOT_FOUND));
    assert!(env.precondition().expect("report").was_snapshot_taken());
    close_handle(handle);
}

/// AC-3 on the ERROR arm of every read wrapper: a wrong-typed snapshot knob fails the pre-verb
/// snapshot, and each wrapper maps it through the shared precondition mapping onto
/// `jj.config_error` (the key in `context`) with the partial report attached.
#[test]
fn every_read_wrapper_maps_a_failed_pre_verb_snapshot_and_carries_the_partial_report() {
    let (_tmp, root) = fresh_repo();
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "snapshot.max-new-file-size = true\n",
    )
    .expect("config");
    let handle = open_handle(&root);
    let any_id = CString::new("zzzzzzzzzzzz").expect("no NUL");

    // SAFETY (every call): handle is live; `any_id` is a valid C string alive for the call.
    let envelopes = unsafe {
        [
            ("status", read_and_free(zanshin_status(handle))),
            ("change", read_and_free(zanshin_change(handle, any_id.as_ptr()))),
            ("op_log", read_and_free(zanshin_op_log(handle, -1))),
            ("bookmarks", read_and_free(zanshin_bookmarks(handle))),
            ("remotes", read_and_free(zanshin_remotes(handle))),
        ]
    };

    for (name, bytes) in &envelopes {
        let env = parse_envelope(bytes);
        assert!(!env.ok(), "{name}");
        let err = env.error().expect("error");
        assert_eq!(err.code(), Some(JJ_CONFIG_ERROR), "{name}");
        assert!(
            err.context().is_some_and(|c| c.contains("snapshot.max-new-file-size")),
            "{name}: {:?}",
            err.context()
        );
        assert!(
            !env.precondition()
                .unwrap_or_else(|| panic!("{name}: the partial report rides the error envelope"))
                .was_snapshot_taken(),
            "{name}"
        );
    }
    close_handle(handle);
}

/// `MutationResult.finish` present: a `describe` that moves `@` INTO the immutable set makes the
/// CLI's `finish_transaction` create a new `@` on top ("The working-copy commit became
/// immutable…"), which rides the wire as `finish.working_copy_became_immutable`.
#[test]
fn a_mutation_that_makes_at_immutable_reports_it_in_finish() {
    let (_tmp, root) = fresh_repo();
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'immutable_heads()' = 'description(glob:\"frozen*\")'\n",
    )
    .expect("config");
    let handle = open_handle(&root);
    let wc = {
        let mut repo = Repo::open(&root).expect("open");
        repo.status().expect("status").working_copy_change_id.0
    };
    let change_id = CString::new(wc.clone()).expect("no NUL");
    let description = CString::new("frozen").expect("no NUL");

    // SAFETY: handle is live; both C strings are alive for the call.
    let bytes = unsafe { read_and_free(zanshin_describe(handle, change_id.as_ptr(), description.as_ptr())) };

    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let m = env.data_as_mutation_result().expect("MutationResult payload");
    let finish = m.finish().expect("a non-default finish is written");
    assert!(finish.working_copy_became_immutable());
    assert!(!finish.git_head_update_failed());
    assert_eq!(finish.export_failed_bookmarks().map_or(0, |v| v.len()), 0);
    assert_eq!(finish.export_failed_tags().map_or(0, |v| v.len()), 0);
    assert_ne!(
        m.working_copy_change_id(),
        Some(wc.as_str()),
        "a new @ was created on top of the now-immutable one"
    );
    close_handle(handle);
}

/// `MutationResult.finish` with a NON-EMPTY export failure list: in a colocated workspace Git
/// cannot hold `foo` and `foo/bar` at once, so the finish's ref export fails for `foo/bar` — a
/// warning in the CLI, a `finish.export_failed_bookmarks` row on the wire; the verb succeeds.
#[test]
fn a_colocated_export_failure_rides_finish_export_failed_bookmarks() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let root = tmp.path().canonicalize().expect("canonical root");
    for args in [
        &["init", "-q", "--initial-branch=main"][..],
        &["config", "user.email", "test@zanshin.test"],
        &["config", "user.name", "Fixture"],
        &["commit", "-q", "--allow-empty", "-m", "initial"],
    ] {
        let out = std::process::Command::new("git")
            .args(args)
            .current_dir(&root)
            .output()
            .expect("git spawns");
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    drop(zanshin_jj::convert_colocated(&root).expect("convert"));
    let handle = open_handle(&root);
    let request = {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
        let names: Vec<_> = ["foo", "foo/bar"].iter().map(|n| b.create_string(n)).collect();
        let names = b.create_vector(&names);
        let req = fbs::BookmarkCreateRequest::create(
            &mut b,
            &fbs::BookmarkCreateRequestArgs {
                kind: fbs::RequestKind::BookmarkCreate,
                names: Some(names),
                revision: None,
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    };

    // SAFETY: handle is live; `request` is a live, correctly-sized buffer for the call.
    let bytes = unsafe { read_and_free(zanshin_bookmark_create(handle, request.as_ptr(), request.len())) };

    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let m = env.data_as_mutation_result().expect("MutationResult payload");
    let failed = m
        .finish()
        .expect("a non-default finish is written")
        .export_failed_bookmarks()
        .expect("vector");
    assert!(
        failed.iter().any(|f| f.name() == Some("foo/bar")),
        "{:?}",
        failed.iter().map(|f| f.name()).collect::<Vec<_>>()
    );
    close_handle(handle);
}

#[test]
fn a_mutation_envelope_carries_the_report_and_an_absent_finish_outside_colocation() {
    let (_tmp, root) = fresh_repo();
    let handle = open_handle(&root);
    let wc = {
        let mut repo = Repo::open(&root).expect("open");
        repo.status().expect("status").working_copy_change_id.0
    };
    let change_id = CString::new(wc).expect("no NUL");
    let description = CString::new("described").expect("no NUL");

    // SAFETY: handle is live; both C strings are alive for the call.
    let bytes = unsafe { read_and_free(zanshin_describe(handle, change_id.as_ptr(), description.as_ptr())) };

    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.code()));
    assert!(!env.precondition().expect("report").was_snapshot_taken());
    let m = env.data_as_mutation_result().expect("MutationResult payload");
    assert!(m.finish().is_none(), "null for absence: nothing to reset or export");
    close_handle(handle);
}

#[test]
fn symbols_that_run_no_precondition_never_carry_the_field() {
    let (_tmp, root) = fresh_repo();
    let handle = open_handle(&root);
    fs::write(root.join("dirty.txt"), "dirty\n").expect("write");

    // SAFETY: handle is live.
    let log_defaults = unsafe { read_and_free(zanshin_log_defaults(handle)) };
    let request = {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
        let req = fbs::WorkspaceRootRequest::create(
            &mut b,
            &fbs::WorkspaceRootRequestArgs {
                kind: fbs::RequestKind::WorkspaceRoot,
                name: None,
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    };
    // SAFETY: handle is live; `request` is alive for the call.
    let workspace_root = unsafe { read_and_free(zanshin_workspace_root(handle, request.as_ptr(), request.len())) };
    let p = c_path(&root);
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let detect = unsafe { read_and_free(zanshin_repo_detect(p.as_ptr())) };

    for (name, bytes) in [
        ("log_defaults", &log_defaults),
        ("workspace_root", &workspace_root),
        ("repo_detect", &detect),
    ] {
        let env = parse_envelope(bytes);
        assert!(env.ok(), "{name}: {:?}", env.error().and_then(|e| e.code()));
        assert!(env.precondition().is_none(), "{name} runs no precondition");
    }
    // …and none of them snapshotted: the dirty file is still unrecorded.
    assert!(parse_envelope(&snapshot(handle))
        .precondition()
        .expect("report")
        .was_snapshot_taken());
    close_handle(handle);
}
