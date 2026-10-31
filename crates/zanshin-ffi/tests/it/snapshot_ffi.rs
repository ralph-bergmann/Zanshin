// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.26's wire contract: `zanshin_snapshot` and the
//! `Envelope.precondition` table every envelope of a snapshotting symbol carries.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The jj-level BEHAVIOUR (the op-log
//! sequence, the colocated rows, the three stale causes) is pinned in
//! `crates/zanshin-jj/tests/snapshot_*.rs`; what is tested here is the envelope: the report on a
//! read, on a mutation, on `zanshin_snapshot` itself (ok with NO `data`), and on an ERROR
//! envelope — and its ABSENCE on the symbols that run no precondition (AC-3). Since Story 9.32
//! the same holds for `Envelope.warnings`: a precondition verb's warnings cross on the ok AND
//! the error arm.
//!
//! Repos are built in-test through `zanshin_jj` (a regular dependency of this crate): the rows
//! need files on disk, which the committed fixtures do not model.

use std::ffi::CString;
use std::fs;
use std::path::{Path, PathBuf};

use flatbuffers::root as fb_root;
use tempfile::TempDir;
use zanshin_ffi::bookmark_ops::zanshin_bookmark_create;
use zanshin_ffi::change::zanshin_change;
use zanshin_ffi::commit_contents::zanshin_commit_contents;
use zanshin_ffi::commit_views::{zanshin_evolog, zanshin_interdiff, zanshin_show};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::file::{zanshin_file_annotate, zanshin_file_list, zanshin_file_search, zanshin_file_show};
use zanshin_ffi::file_ops::zanshin_file_untrack;
use zanshin_ffi::git::{zanshin_git_export, zanshin_git_import};
use zanshin_ffi::graph::zanshin_graph_topology;
use zanshin_ffi::log_defaults::zanshin_log_defaults;
use zanshin_ffi::op_log::zanshin_op_log;
use zanshin_ffi::remotes::zanshin_remotes;
use zanshin_ffi::repo::{zanshin_absorb, zanshin_describe, zanshin_repo_close, zanshin_repo_detect, zanshin_repo_open};
use zanshin_ffi::snapshot::zanshin_snapshot;
use zanshin_ffi::status::zanshin_status;
use zanshin_ffi::workspace::{zanshin_workspace_add, zanshin_workspace_list, zanshin_workspace_root};
use zanshin_ffi::{
    FFI_INVALID_HANDLE, JJ_CHANGE_NOT_FOUND, JJ_CONFIG_ALIAS_INVALID, JJ_CONFIG_ERROR, JJ_GIT_EXPORT_FAILED,
    JJ_INVALID_INPUT, JJ_STALE_WORKING_COPY, JJ_WORKING_COPY_IMMUTABLE,
};
use zanshin_jj::{Backend, ChangeId, Repo};

// ── Env pin ───────────────────────────────────────────────────────────────────

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

/// `Envelope.warnings` as `(code, message)` pairs — `[]` when the field is absent.
fn warnings_of(env: &fbs::Envelope<'_>) -> Vec<(String, String)> {
    env.warnings()
        .map(|v| {
            v.iter()
                .map(|w| (w.code().unwrap_or("").to_owned(), w.message().unwrap_or("").to_owned()))
                .collect()
        })
        .unwrap_or_default()
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
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
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
fn a_stale_working_copy_is_jj_stale_working_copy_with_the_four_line_context() {
    let (_tmp, root) = fresh_repo();
    let at = {
        let mut repo = Repo::open(&root).expect("open");
        let wc: ChangeId = repo.status().expect("status").working_copy_change_id.expect("@");
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
    assert_eq!(
        context.len(),
        4,
        "<cause>\\n<wc_op>\\n<repo_op>\\n<message>: {context:?}"
    );
    assert_eq!(context[0], "stale");
    assert_eq!(context[1].len(), 128, "the working copy's operation id");
    assert_eq!(context[2].len(), 128, "the repo's operation id");
    assert_eq!(
        context[3],
        format!(
            "The working copy is stale (not updated since operation {}).",
            &context[1][..12]
        ),
        "the CLI's message"
    );
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

/// Runs `git` in `dir`, panicking on failure. Fixture setup only.
fn git(args: &[&str], dir: &Path) {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git spawns");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// Story 9.34's outermost witness of the double fault "Git HEAD moved outside AND a wrong-typed
/// snapshot knob": the pre-verb snapshot reads the knob where the CLI does — after its colocated
/// `import git head` committed — so the error envelope's partial report names that operation.
#[test]
fn a_wrong_typed_knob_after_a_git_commit_outside_reports_the_head_import_on_the_error_arm() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let root = tmp.path().canonicalize().expect("canonical root");
    git(&["init", "-q", "--initial-branch=main"], &root);
    git(&["config", "user.email", "test@zanshin.test"], &root);
    git(&["config", "user.name", "Fixture"], &root);
    git(&["commit", "-q", "--allow-empty", "-m", "initial"], &root);
    drop(zanshin_jj::convert_colocated(&root).result.expect("convert"));
    let handle = open_handle(&root);
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "snapshot.max-new-file-size = true\n",
    )
    .expect("config");
    git(&["commit", "-q", "--allow-empty", "-m", "outside"], &root);

    let bytes = snapshot(handle);

    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    let err = env.error().expect("error");
    assert_eq!(err.code(), Some(JJ_CONFIG_ERROR));
    assert!(
        err.context().is_some_and(|c| c.contains("snapshot.max-new-file-size")),
        "{:?}",
        err.context()
    );
    let p = env.precondition().expect("the partial report rides the error envelope");
    assert!(p.git_head_imported(), "the head import ran before the knob was read");
    assert!(p.was_snapshot_taken(), "an operation WAS written before the failure");
    assert!(p.git_refs().is_none(), "the refs step never ran");
    close_handle(handle);
}

/// `zanshin_snapshot` builds its own error arm; the warnings collected before the failure ride
/// it (Story 9.32): the bad `[fileset-aliases]` entry loads (and warns) before the wrong-typed
/// size knob refuses.
#[test]
fn a_snapshot_error_envelope_carries_the_warnings_collected_before_the_failure() {
    let (_tmp, root) = fresh_repo();
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "snapshot.max-new-file-size = true\n[fileset-aliases]\n'bad(' = 'x'\n",
    )
    .expect("config");
    let handle = open_handle(&root);

    let bytes = snapshot(handle);

    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CONFIG_ERROR));
    assert!(env.precondition().is_some(), "the partial report rides along");
    let warnings = warnings_of(&env);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].0, "jj.config_alias_invalid");
    assert!(
        warnings[0].1.starts_with("Failed to load `fileset-aliases.bad(`: "),
        "{}",
        warnings[0].1
    );
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
            ("bookmarks", read_and_free(crate::bookmarks_all_remotes(handle))),
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

/// A finished `FlatBuffers` request buffer built by `build` — the table's own `create` + finish.
fn request(build: impl FnOnce(&mut flatbuffers::FlatBufferBuilder<'static>)) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    build(&mut b);
    b.finished_data().to_vec()
}

/// Calls the ok-arm row `name` against `handle`, after `file` was written into the working
/// copy (so its pre-verb snapshot has something to record). `wc` is `@`'s change id.
///
/// # Safety
/// `handle` must be live.
// WHY: one flat arm per wrapper keeps the table readable; splitting would only scatter it.
#[allow(clippy::too_many_lines)]
unsafe fn ok_row(name: &str, handle: u64, file: &str, wc: &CString) -> Vec<u8> {
    let buf = |bytes: &[u8]| (bytes.as_ptr(), bytes.len());
    // SAFETY (every arm): `handle` is live; each C string / request buffer is alive for its call.
    unsafe {
        match name {
            "change" => read_and_free(zanshin_change(handle, wc.as_ptr())),
            "op_log" => read_and_free(zanshin_op_log(handle, -1)),
            "bookmarks" => read_and_free(crate::bookmarks_all_remotes(handle)),
            "remotes" => read_and_free(zanshin_remotes(handle)),
            "graph_topology" => {
                let req = request(|b| {
                    let revset = b.create_string("all()");
                    let prioritize = b.create_string("none()");
                    let short_prefixes = b.create_string("all()");
                    let req = fbs::GraphTopologyRequest::create(
                        b,
                        &fbs::GraphTopologyRequestArgs {
                            kind: fbs::RequestKind::GraphTopology,
                            revset: Some(revset),
                            prioritize: Some(prioritize),
                            short_prefixes: Some(short_prefixes),
                            anchors: None,
                            with_timestamps: false,
                        },
                    );
                    b.finish(req, None);
                });
                let (ptr, len) = buf(&req);
                read_and_free(zanshin_graph_topology(handle, ptr, len))
            }
            "file_list" | "file_show" => {
                let show = name == "file_show";
                let req = request(|b| {
                    let path = b.create_string(file);
                    let paths = Some(b.create_vector(&[path]));
                    if show {
                        let req = fbs::FileShowRequest::create(
                            b,
                            &fbs::FileShowRequestArgs {
                                kind: fbs::RequestKind::FileShow,
                                revision: None,
                                paths,
                            },
                        );
                        b.finish(req, None);
                    } else {
                        let req = fbs::FileListRequest::create(
                            b,
                            &fbs::FileListRequestArgs {
                                kind: fbs::RequestKind::FileList,
                                revision: None,
                                paths,
                            },
                        );
                        b.finish(req, None);
                    }
                });
                let (ptr, len) = buf(&req);
                if show {
                    read_and_free(zanshin_file_show(handle, ptr, len))
                } else {
                    read_and_free(zanshin_file_list(handle, ptr, len))
                }
            }
            "file_annotate" => {
                let req = request(|b| {
                    let path = b.create_string(file);
                    let req = fbs::FileAnnotateRequest::create(
                        b,
                        &fbs::FileAnnotateRequestArgs {
                            kind: fbs::RequestKind::FileAnnotate,
                            revision: None,
                            path: Some(path),
                        },
                    );
                    b.finish(req, None);
                });
                let (ptr, len) = buf(&req);
                read_and_free(zanshin_file_annotate(handle, ptr, len))
            }
            "file_search" => {
                let req = request(|b| {
                    let pattern = b.create_string("dirty");
                    let req = fbs::FileSearchRequest::create(
                        b,
                        &fbs::FileSearchRequestArgs {
                            kind: fbs::RequestKind::FileSearch,
                            revision: None,
                            pattern: Some(pattern),
                            paths: None,
                            name_only: false,
                        },
                    );
                    b.finish(req, None);
                });
                let (ptr, len) = buf(&req);
                read_and_free(zanshin_file_search(handle, ptr, len))
            }
            "show" | "evolog" => {
                let evolog = name == "evolog";
                let req = request(|b| {
                    if evolog {
                        let req = fbs::EvologRequest::create(
                            b,
                            &fbs::EvologRequestArgs {
                                kind: fbs::RequestKind::Evolog,
                                ..Default::default()
                            },
                        );
                        b.finish(req, None);
                    } else {
                        let req = fbs::ShowRequest::create(
                            b,
                            &fbs::ShowRequestArgs {
                                kind: fbs::RequestKind::Show,
                                ..Default::default()
                            },
                        );
                        b.finish(req, None);
                    }
                });
                let (ptr, len) = buf(&req);
                if evolog {
                    read_and_free(zanshin_evolog(handle, ptr, len))
                } else {
                    read_and_free(zanshin_show(handle, ptr, len))
                }
            }
            "interdiff" => {
                let req = request(|b| {
                    // The CLI requires one side; `from` defaults to `@`.
                    let id = b.create_string(wc.to_str().expect("UTF-8"));
                    let to = fbs::ChangeIdRef::create(b, &fbs::ChangeIdRefArgs { id: Some(id) });
                    let req = fbs::InterdiffRequest::create(
                        b,
                        &fbs::InterdiffRequestArgs {
                            kind: fbs::RequestKind::Interdiff,
                            to_type: fbs::RevisionRef::ChangeIdRef,
                            to: Some(to.as_union_value()),
                            ..Default::default()
                        },
                    );
                    b.finish(req, None);
                });
                let (ptr, len) = buf(&req);
                read_and_free(zanshin_interdiff(handle, ptr, len))
            }
            "workspace_list" => read_and_free(zanshin_workspace_list(handle)),
            "git_import" => read_and_free(zanshin_git_import(handle)),
            "git_export" => read_and_free(zanshin_git_export(handle)),
            "absorb" => {
                let req = request(|b| {
                    let req = fbs::AbsorbRequest::create(
                        b,
                        &fbs::AbsorbRequestArgs {
                            kind: fbs::RequestKind::Absorb,
                            ..Default::default()
                        },
                    );
                    b.finish(req, None);
                });
                let (ptr, len) = buf(&req);
                read_and_free(zanshin_absorb(handle, ptr, len))
            }
            "file_untrack" => {
                let req = request(|b| {
                    let path = b.create_string("never-existed.txt");
                    let paths = b.create_vector(&[path]);
                    let req = fbs::FileUntrackRequest::create(
                        b,
                        &fbs::FileUntrackRequestArgs {
                            kind: fbs::RequestKind::FileUntrack,
                            paths: Some(paths),
                        },
                    );
                    b.finish(req, None);
                });
                let (ptr, len) = buf(&req);
                read_and_free(zanshin_file_untrack(handle, ptr, len))
            }
            "workspace_add" => {
                let req = request(|b| {
                    let destination = b.create_string("added-workspace");
                    let req = fbs::WorkspaceAddRequest::create(
                        b,
                        &fbs::WorkspaceAddRequestArgs {
                            kind: fbs::RequestKind::WorkspaceAdd,
                            destination: Some(destination),
                            ..fbs::WorkspaceAddRequestArgs::default()
                        },
                    );
                    b.finish(req, None);
                });
                let (ptr, len) = buf(&req);
                read_and_free(zanshin_workspace_add(handle, ptr, len))
            }
            other => panic!("unknown row {other}"),
        }
    }
}

/// AC-3 on the OK arm of every distinct envelope builder: each wrapper's success envelope
/// carries the report of the pre-verb snapshot that recorded the file written just before it.
#[test]
fn every_wrapper_carries_the_report_of_its_pre_verb_snapshot_on_the_ok_arm() {
    let (_tmp, root) = fresh_repo();
    let wc = {
        let mut repo = Repo::open(&root).expect("open");
        CString::new(repo.status().expect("status").working_copy_change_id.expect("@").0).expect("no NUL")
    };
    let handle = open_handle(&root);

    for name in [
        "change",
        "op_log",
        "bookmarks",
        "remotes",
        "graph_topology",
        "file_list",
        "file_show",
        "file_annotate",
        "file_search",
        "show",
        "evolog",
        "interdiff",
        "workspace_list",
        "git_import",
        "git_export",
        "absorb",
        "file_untrack",
        "workspace_add",
    ] {
        let file = format!("dirty-{name}.txt");
        fs::write(root.join(&file), "dirty\n").expect("write");

        // SAFETY: handle is live.
        let bytes = unsafe { ok_row(name, handle, &file, &wc) };

        let env = parse_envelope(&bytes);
        assert!(env.ok(), "{name}: {:?}", env.error().and_then(|e| e.context()));
        assert!(
            env.precondition()
                .unwrap_or_else(|| panic!("{name}: the report rides the ok envelope"))
                .was_snapshot_taken(),
            "{name}: its pre-verb snapshot recorded {file}"
        );
    }
    close_handle(handle);
}

/// A `describe` that moves `@` INTO the immutable set makes the CLI's `finish_transaction` create
/// a new `@` on top ("The working-copy commit became immutable…"), which rides the wire as a
/// `jj.working_copy_immutable` warning (Story 9.32) — `finish` stays absent: nothing to export.
#[test]
fn a_mutation_that_makes_at_immutable_warns_on_the_envelope() {
    let (_tmp, root) = fresh_repo();
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'immutable_heads()' = 'description(glob:\"frozen*\")'\n",
    )
    .expect("config");
    let handle = open_handle(&root);
    let wc = {
        let mut repo = Repo::open(&root).expect("open");
        repo.status().expect("status").working_copy_change_id.expect("@").0
    };
    let change_id = CString::new(wc.clone()).expect("no NUL");
    let description = CString::new("frozen").expect("no NUL");

    // SAFETY: handle is live; both C strings are alive for the call.
    let bytes = unsafe { read_and_free(zanshin_describe(handle, change_id.as_ptr(), description.as_ptr())) };

    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let m = env.data_as_mutation_result().expect("MutationResult payload");
    assert!(m.finish().is_none(), "no export ran outside colocation");
    assert_eq!(
        warnings_of(&env),
        [(
            JJ_WORKING_COPY_IMMUTABLE.to_owned(),
            "The working-copy commit became immutable; a new commit has been created on top of it.".to_owned()
        )]
    );
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
    test_helpers::pin_test_env();
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
    drop(zanshin_jj::convert_colocated(&root).result.expect("convert"));
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
    // Story 9.32: the same failure as the CLI's warning block, under its code — after the
    // verb body's own "Target revision is empty." (`@` is empty), the CLI's print order.
    let warnings = warnings_of(&env);
    let codes: Vec<&str> = warnings.iter().map(|(code, _)| code.as_str()).collect();
    assert_eq!(codes, ["jj.bookmark_target_empty", JJ_GIT_EXPORT_FAILED]);
    assert!(
        warnings[1]
            .1
            .starts_with("Failed to export some bookmarks:\n  foo/bar@git: "),
        "{}",
        warnings[1].1
    );
    close_handle(handle);
}

/// Story 9.32's outermost witness: a precondition verb's warning — a bad `[revset-aliases]`
/// entry, recorded while the pre-verb snapshot loads its knobs — crosses on the ok envelope AND,
/// next to the partial precondition, on the error envelope of a verb that then refuses.
#[test]
fn a_precondition_warning_crosses_on_the_ok_and_the_error_arm() {
    let (_tmp, root) = fresh_repo();
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'bad(' = 'x'\n",
    )
    .expect("config");
    let handle = open_handle(&root);
    let expect_alias_warning = |env: &fbs::Envelope<'_>, arm: &str| {
        let warnings = warnings_of(env);
        assert_eq!(warnings.len(), 1, "{arm}: {warnings:?}");
        assert_eq!(warnings[0].0, JJ_CONFIG_ALIAS_INVALID, "{arm}");
        assert!(
            warnings[0].1.starts_with("Failed to load `revset-aliases.bad(`: "),
            "{arm}: {}",
            warnings[0].1
        );
    };

    // SAFETY: handle is live.
    let ok = unsafe { read_and_free(zanshin_status(handle)) };
    let env = parse_envelope(&ok);
    assert!(env.ok());
    expect_alias_warning(&env, "ok arm");

    let root_change = {
        let repo = Repo::open(&root).expect("open");
        zanshin_jj::resolve_revset(&repo, "root()")
            .expect("root")
            .swap_remove(0)
            .0
    };
    let change_id = CString::new(root_change).expect("no NUL");
    let description = CString::new("x").expect("no NUL");
    // SAFETY: handle is live; both C strings are alive for the call.
    let err = unsafe { read_and_free(zanshin_describe(handle, change_id.as_ptr(), description.as_ptr())) };
    let env = parse_envelope(&err);
    assert!(!env.ok());
    assert_eq!(
        env.error().and_then(|e| e.code()),
        Some(JJ_INVALID_INPUT),
        "root refuses"
    );
    assert!(env.precondition().is_some(), "the report rides the error arm");
    expect_alias_warning(&env, "error arm");
    close_handle(handle);
}

#[test]
fn a_mutation_envelope_carries_the_report_and_an_absent_finish_outside_colocation() {
    let (_tmp, root) = fresh_repo();
    let handle = open_handle(&root);
    let wc = {
        let mut repo = Repo::open(&root).expect("open");
        repo.status().expect("status").working_copy_change_id.expect("@").0
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
    // Story 4.10: the op-pinned content read, at the head read off disk (no snapshot).
    let contents_request = {
        let heads = fs::read_dir(root.join(".jj").join("repo").join("op_heads").join("heads"))
            .expect("heads dir")
            .map(|e| e.expect("entry").file_name().to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let op = b.create_string(&heads[0]);
        let root_id = b.create_string(&"0".repeat(40));
        let ids = b.create_vector(&[root_id]);
        let req = fbs::CommitContentsRequest::create(
            &mut b,
            &fbs::CommitContentsRequestArgs {
                kind: fbs::RequestKind::CommitContents,
                operation_id: Some(op),
                commit_ids: Some(ids),
                extra_operation_ids: None,
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    };
    // SAFETY: handle is live; `contents_request` is alive for the call.
    let commit_contents = unsafe {
        read_and_free(zanshin_commit_contents(
            handle,
            contents_request.as_ptr(),
            contents_request.len(),
        ))
    };

    for (name, bytes) in [
        ("log_defaults", &log_defaults),
        ("workspace_root", &workspace_root),
        ("repo_detect", &detect),
        ("commit_contents", &commit_contents),
    ] {
        let env = parse_envelope(bytes);
        assert!(env.ok(), "{name}: {:?}", env.error().and_then(|e| e.code()));
        assert!(env.precondition().is_none(), "{name} runs no precondition");
        assert!(
            env.warnings().is_none(),
            "{name} warns about nothing: the field is absent"
        );
    }
    // …and none of them snapshotted: the dirty file is still unrecorded.
    assert!(parse_envelope(&snapshot(handle))
        .precondition()
        .expect("report")
        .was_snapshot_taken());
    close_handle(handle);
}
