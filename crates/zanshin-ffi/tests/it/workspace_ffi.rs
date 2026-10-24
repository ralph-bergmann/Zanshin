// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.7's two workspace wrappers (`zanshin_workspace_list`,
//! `zanshin_workspace_root`) and Story 9.23's two (`zanshin_workspace_add`,
//! `zanshin_workspace_update_stale`).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier —
//! a wrong-shape payload is a compile error, not a runtime assert. Every token is freed via
//! `zanshin_buffer_free_token` so the suite is leak-clean.
//!
//! Mirrors `tests/it/commit_views_ffi.rs`'s scaffolding, with one difference the two verbs force:
//! `zanshin_workspace_list` is HANDLE-ONLY (the CLI verb takes no argument), so the shared
//! guard table needs a second fn-pointer alias rather than one shape for both.

use std::ffi::CString;
use std::fs;
use std::path::Path;

use flatbuffers::root as fb_root;
use test_helpers::{add_workspace, extract_fixture};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::workspace::{
    zanshin_workspace_add, zanshin_workspace_list, zanshin_workspace_root, zanshin_workspace_update_stale,
};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CONFIG_DEPRECATED, JJ_CONFIG_ERROR,
    JJ_DESTINATION_NOT_EMPTY, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_WORKSPACE_EXISTS,
    JJ_WORKSPACE_IN_CURRENT_DIRECTORY, JJ_WORKSPACE_NOT_FOUND, JJ_WORKSPACE_NO_RECORDED_PATH,
    JJ_WORKSPACE_PATH_INACCESSIBLE,
};

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

/// The request-buffer wrapper shape (`zanshin_workspace_root`).
type BufWrapper = unsafe extern "C" fn(u64, *const u8, usize) -> *mut ZanshinBuf;

/// The handle-only wrapper shape (`zanshin_workspace_list`) — its own alias, because the CLI's
/// `jj workspace list` takes no argument and the two therefore cannot share one table.
type HandleWrapper = unsafe extern "C" fn(u64) -> *mut ZanshinBuf;

fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("test string must not contain NUL bytes")
}

/// Open `path` and return its raw handle.
fn open_handle(path: &Path) -> u64 {
    let p = cstr(path.to_str().expect("fixture path must be UTF-8"));
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let token = unsafe { zanshin_repo_open(p.as_ptr()) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_open just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "expected ok, error: {:?}", env.error().and_then(|e| e.code()));
    env.data_as_repo_handle()
        .expect("RepoHandle payload must be present")
        .handle()
}

fn close_handle(handle: u64) {
    // SAFETY: handle originated from open_handle above and has not been closed.
    let token = unsafe { zanshin_repo_close(handle) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_close just returned.
    let bytes = unsafe { read_and_free(token) };
    assert!(parse_envelope(&bytes).ok(), "repo close must succeed");
}

// ── Request-buffer builder ────────────────────────────────────────────────────

/// A `WorkspaceRootRequest` buffer. A `None` name is left ABSENT — the wire form of "the user did
/// not supply `--name`", which selects the CLI's current-workspace default. `Some("")` is a
/// PRESENT empty string, a genuinely different request.
fn root_request_bytes(name: Option<&str>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let name_off = name.map(|s| b.create_string(s));
    let req = fbs::WorkspaceRootRequest::create(
        &mut b,
        &fbs::WorkspaceRootRequestArgs {
            kind: fbs::RequestKind::WorkspaceRoot,
            name: name_off,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

// ── Scenarios ─────────────────────────────────────────────────────────────────

/// A fixture with a SECOND workspace, so both an existing and a stale recorded root are on the
/// wire in one call. Returns `(handle, fixture root, second workspace root)`.
///
/// Both `FixtureHandle`s are leaked so their `TempDir`s outlive the returned raw handle, exactly
/// as `commit_views_ffi.rs::open_scenario` does.
fn open_two_workspace_scenario() -> (u64, std::path::PathBuf, std::path::PathBuf) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let root = fixture.path.clone();
    let (second, _wc) = add_workspace(&root, "second");
    let second_root = second.path.clone();
    let handle = open_handle(&root);
    std::mem::forget(fixture);
    std::mem::forget(second);
    (handle, root, second_root)
}

/// The plain fixture, whose single recorded path is the GENERATOR's temp dir and no longer
/// exists. Returns `(handle, fixture root)`.
fn open_stale_scenario() -> (u64, std::path::PathBuf) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let root = fixture.path.clone();
    let handle = open_handle(&root);
    std::mem::forget(fixture);
    (handle, root)
}

// ── zanshin_workspace_list ────────────────────────────────────────────────────

/// Both kinds of recorded root in one payload: `default`'s is stale (jj 0.46 reports it anyway) and
/// `second`'s is the directory it lives in. A stale path never fails the call.
#[test]
fn workspace_list_carries_stale_and_live_roots() {
    test_helpers::pin_test_env();
    let (handle, _root, second_root) = open_two_workspace_scenario();

    // SAFETY: handle is live and was produced by zanshin_repo_open.
    let token = unsafe { zanshin_workspace_list(handle) };
    // SAFETY: token is the fresh, non-null token the call just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "a stale path must not fail the listing");
    assert_eq!(env.data_type(), fbs::Payload::WorkspaceList);
    let entries = env
        .data_as_workspace_list()
        .expect("WorkspaceList payload")
        .entries()
        .expect("entries vector");

    assert_eq!(entries.len(), 2, "default + second");
    assert_eq!(entries.get(0).name(), Some("default"));
    assert!(
        !entries.get(0).wc_commit_id().unwrap_or_default().is_empty(),
        "the view half must be reported for a stale row too"
    );
    let stale = entries.get(0).root().expect("the fixture records a path");
    assert!(
        !Path::new(stale).exists(),
        "the fixture's recorded path no longer exists; got {stale:?}"
    );

    assert_eq!(entries.get(1).name(), Some("second"));
    let wire_root = entries.get(1).root().expect("second's path resolves");
    assert_eq!(
        fs::canonicalize(wire_root).expect("wire root exists"),
        fs::canonicalize(&second_root).expect("second root exists"),
        "the wire path must be the directory add_workspace created"
    );

    close_handle(handle);
}

// ── zanshin_workspace_root ────────────────────────────────────────────────────

/// The absent-name default reads the loader alone and returns the OPEN workspace's root; naming
/// the very same workspace goes through the store, returns its stale recorded path and warns. That
/// asymmetry is the CLI's own, and a reader that dropped the `name` field would make both calls
/// answer identically.
#[test]
fn workspace_root_absent_name_answers_quietly_where_the_named_current_workspace_warns() {
    test_helpers::pin_test_env();
    let (handle, root) = open_stale_scenario();

    let req = root_request_bytes(None);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_workspace_root(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "the loader-only path cannot fail");
    assert_eq!(env.data_type(), fbs::Payload::WorkspaceRoot);
    let wire_root = env
        .data_as_workspace_root()
        .expect("WorkspaceRoot payload")
        .root()
        .expect("root is always present on success");
    assert_eq!(
        fs::canonicalize(wire_root).expect("wire root exists"),
        fs::canonicalize(&root).expect("fixture root exists")
    );
    assert!(env.warnings().is_none(), "the open workspace's root never warns");

    let req = root_request_bytes(Some("default"));
    // SAFETY: see above.
    let token = unsafe { zanshin_workspace_root(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "a stale recorded path is reported, not refused");
    let stale = env
        .data_as_workspace_root()
        .expect("WorkspaceRoot payload")
        .root()
        .expect("root is always present on success");
    assert!(
        !Path::new(stale).exists(),
        "the named path never shortcuts to the loader"
    );
    let warnings: Vec<(&str, &str)> = env
        .warnings()
        .expect("the stale path rides with a warning")
        .iter()
        .map(|w| (w.code().unwrap(), w.message().unwrap()))
        .collect();
    assert_eq!(
        warnings,
        [(
            JJ_WORKSPACE_PATH_INACCESSIBLE,
            format!("Cannot access workspace path: {stale}").as_str()
        )]
    );

    close_handle(handle);
}

/// A named SIBLING workspace is reachable from this one — the point of the verb.
#[test]
fn workspace_root_finds_a_named_sibling_workspace() {
    test_helpers::pin_test_env();
    let (handle, _root, second_root) = open_two_workspace_scenario();

    let req = root_request_bytes(Some("second"));
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_workspace_root(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "error: {:?}", env.error().and_then(|e| e.code()));
    let wire_root = env
        .data_as_workspace_root()
        .expect("WorkspaceRoot payload")
        .root()
        .expect("root present");
    assert_eq!(
        fs::canonicalize(wire_root).expect("wire root exists"),
        fs::canonicalize(&second_root).expect("second root exists")
    );

    close_handle(handle);
}

/// The two named refusals, each with its own code. An explicitly EMPTY name is a VALUE, not an
/// absence: it must NOT fall back to the current workspace.
#[test]
fn workspace_root_refuses_with_one_code_per_cause() {
    test_helpers::pin_test_env();
    let (handle, root) = open_stale_scenario();

    for name in ["nosuch", ""] {
        let req = root_request_bytes(Some(name));
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { zanshin_workspace_root(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert_eq!(
            env.error().and_then(|e| e.code()),
            Some(JJ_WORKSPACE_NOT_FOUND),
            "{name:?} must be jj.workspace_not_found"
        );
        assert_eq!(env.error().and_then(|e| e.context()), Some(name));
    }
    close_handle(handle);

    // No recorded path at all refuses, where a stale one only warns: there is no path to report.
    fs::remove_dir_all(root.join(".jj").join("repo").join("workspace_store")).expect("store exists");
    let handle = open_handle(&root);
    let req = root_request_bytes(Some("default"));
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_workspace_root(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_WORKSPACE_NO_RECORDED_PATH));
    assert_eq!(env.error().and_then(|e| e.context()), Some("default"));
    close_handle(handle);
}

/// `jj.jj_lib_error` is documented on BOTH wrappers, so both need a witness that composes the
/// wrapper's own path — the jj-level `WorkspaceError::Backend` test and the inline mapper unit
/// test each cover only one half.
///
/// The handle is opened FIRST and `op_heads` destroyed afterwards, because ADR-0002 re-resolves
/// the head per call: an already-open session is exactly how a GUI meets a repo that broke under
/// it.
#[test]
fn both_wrappers_report_jj_lib_error_when_the_head_cannot_be_resolved() {
    test_helpers::pin_test_env();
    let (handle, root) = open_stale_scenario();
    fs::remove_dir_all(root.join(".jj").join("repo").join("op_heads")).expect("op heads dir exists");

    // SAFETY: handle is live.
    let token = unsafe { zanshin_workspace_list(handle) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert_eq!(
        parse_envelope(&bytes).error().and_then(|e| e.code()),
        Some(JJ_JJ_LIB_ERROR),
        "zanshin_workspace_list must report the VIEW half's failure"
    );

    // The NAMED path needs the head view for its membership check, so it fails the same way.
    let req = root_request_bytes(Some("default"));
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_workspace_root(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_JJ_LIB_ERROR));
    assert!(
        env.error().and_then(|e| e.context()).is_some_and(|c| !c.is_empty()),
        "jj-lib's reason must be forwarded in context"
    );

    // The no-name path reads the loader alone, so it still answers.
    let req = root_request_bytes(None);
    // SAFETY: see above.
    let token = unsafe { zanshin_workspace_root(handle, req.as_ptr(), req.len()) };
    // SAFETY: see above.
    let bytes = unsafe { read_and_free(token) };
    assert!(
        parse_envelope(&bytes).ok(),
        "the loader-only path never touches the op log"
    );

    close_handle(handle);
}

// ── Shared FFI contract: handles and request buffers ──────────────────────────

/// Both wrappers' shared entry-point contract: a zero handle for each, plus the null-pointer and
/// non-verifying-buffer guards for the one that takes a request buffer.
#[test]
fn both_wrappers_guard_the_handle_and_the_request_buffer() {
    test_helpers::pin_test_env();
    let (handle, _root) = open_stale_scenario();

    // Handle-only verbs still have to reject a zero handle — a second alias exists for exactly
    // this row, so a future handle-only verb cannot skip it.
    let handle_only: [(&str, HandleWrapper); 1] = [("zanshin_workspace_list", zanshin_workspace_list)];
    for (name, call) in handle_only {
        // SAFETY: handle 0 is the null-handle case.
        let token = unsafe { call(0) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_INVALID_HANDLE),
            "{name} must reject a zero handle"
        );
    }

    // Non-FlatBuffers bytes: the Verifier must reject them BEFORE any field is read. Long enough
    // that the root-offset read itself does not trip on the buffer's length.
    let garbage = [0xffu8; 64];
    let with_buffer: [(&str, BufWrapper, Vec<u8>); 1] = [(
        "zanshin_workspace_root",
        zanshin_workspace_root,
        root_request_bytes(None),
    )];
    for (name, call, req) in with_buffer {
        // SAFETY: handle 0 is the null-handle case; req is a valid buffer alive for the call.
        let token = unsafe { call(0, req.as_ptr(), req.len()) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_INVALID_HANDLE),
            "{name} must reject a zero handle"
        );

        // SAFETY: a null `data` is exactly what `reject_null_request` guards.
        let token = unsafe { call(handle, std::ptr::null(), 0) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_NULL_POINTER),
            "{name} must reject a null request pointer"
        );

        // SAFETY: garbage is a live, readable buffer of the stated length.
        let token = unsafe { call(handle, garbage.as_ptr(), garbage.len()) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.code()),
            Some(FFI_INVALID_ARGUMENT),
            "{name} must reject a buffer that does not verify"
        );
    }

    close_handle(handle);
}

// ── Op-log invariant across the whole wrapper layer ───────────────────────────

/// Neither verb writes an operation, on success OR on a refusal — including the `workspace list`
/// call that makes jj-lib RE-CREATE the workspace-store directory, which touches files but never
/// the op log.
#[test]
fn no_workspace_wrapper_writes_an_operation() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    // The op-heads directory names the head operation, so its contents are a byte-level witness
    // that no operation was written — no jj_lib import needed.
    let op_heads = fixture.path.join(".jj").join("repo").join("op_heads").join("heads");
    // Sorted: `read_dir` order is unspecified, so an unsorted comparison would be a latent flake
    // the moment the store holds more than one head.
    let mut before: Vec<String> = fs::read_dir(&op_heads)
        .expect("op heads dir")
        .map(|e| e.expect("dir entry").file_name().to_string_lossy().into_owned())
        .collect();
    before.sort();

    // Also exercise the legacy-repo path: with no workspace_store dir, `SimpleWorkspaceStore::load`
    // creates one and writes an empty store. That is file I/O, not an operation.
    fs::remove_dir_all(fixture.path.join(".jj").join("repo").join("workspace_store")).expect("store exists");

    let handle = open_handle(&fixture.path);

    // SAFETY: handle is live.
    let token = unsafe { zanshin_workspace_list(handle) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    assert!(parse_envelope(&bytes).ok(), "list succeeds with no recorded paths");

    for (req, expect_ok) in [
        (root_request_bytes(None), true),
        (root_request_bytes(Some("default")), false),
    ] {
        // SAFETY: handle is live; req is a valid buffer alive for the call.
        let token = unsafe { zanshin_workspace_root(handle, req.as_ptr(), req.len()) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        assert_eq!(
            parse_envelope(&bytes).ok(),
            expect_ok,
            "unexpected outcome: {:?}",
            parse_envelope(&bytes).error().and_then(|e| e.code())
        );
    }
    close_handle(handle);

    let mut after: Vec<String> = fs::read_dir(&op_heads)
        .expect("op heads dir")
        .map(|e| e.expect("dir entry").file_name().to_string_lossy().into_owned())
        .collect();
    after.sort();
    assert_eq!(before, after, "neither verb may write an operation, refusals included");
}

// ── Request-kind tag ──────────────────────────────────────────────────────────

/// One row of the wrong-kind table: label, wrapper, buffer, expected kind, received kind, handle.
type KindCase<'a> = (&'a str, BufWrapper, &'a [u8], &'a str, &'a str, u64);

/// `zanshin_workspace_root` refuses a buffer built for a different verb, and refuses an
/// untagged one, naming both kinds in `context`.
///
/// The other verb has to come from another noun module — `zanshin_workspace_list` takes no
/// buffer at all — which is exactly the point: EVERY request table verifies as every other, so
/// a `BookmarkDeleteRequest` reached this reader intact before the `RequestKind` tag. The
/// `handle == 0` row proves the kind rung runs BEFORE the handle lookup.
#[test]
fn workspace_root_refuses_a_buffer_built_for_another_verb() {
    test_helpers::pin_test_env();
    let (handle, _root) = open_stale_scenario();

    let foreign = tagged_request_bytes(fbs::RequestKind::BookmarkDelete);
    let untagged = tagged_request_bytes(fbs::RequestKind::Unspecified);
    // A POPULATED `ShowRequest` — the ledger's own one-string collision (four-way until Epic 9
    // follow-up I dropped interdiff out of it, three-way since) names this table beside
    // `WorkspaceRootRequest`, and a real one carrying a revset verifies here as a `name`.
    let show_req = show_request_bytes("@");

    let cases: [KindCase<'_>; 4] = [
        (
            "live handle",
            zanshin_workspace_root,
            &foreign,
            "WorkspaceRoot",
            "BookmarkDelete",
            handle,
        ),
        (
            "populated ShowRequest",
            zanshin_workspace_root,
            &show_req,
            "WorkspaceRoot",
            "Show",
            handle,
        ),
        (
            "untagged",
            zanshin_workspace_root,
            &untagged,
            "WorkspaceRoot",
            "Unspecified",
            handle,
        ),
        (
            "zero handle",
            zanshin_workspace_root,
            &foreign,
            "WorkspaceRoot",
            "BookmarkDelete",
            0,
        ),
    ];

    for (name, call, req, expected, got, h) in cases {
        // SAFETY: the handle is live or the documented null handle; the buffer outlives the call.
        let token = unsafe { call(h, req.as_ptr(), req.len()) };
        // SAFETY: token is fresh and non-null.
        let bytes = unsafe { read_and_free(token) };
        let env = parse_envelope(&bytes);
        assert!(!env.ok(), "{name}: a wrong-kind buffer must be refused");
        assert_eq!(
            env.error().and_then(|e| e.code()),
            Some(FFI_INVALID_ARGUMENT),
            "{name}: a kind mismatch is an invalid argument, not an invalid handle"
        );
        assert_eq!(
            env.error().and_then(|e| e.context()),
            Some(format!("request kind mismatch: expected {expected}, got {got}").as_str()),
            "{name}: the context names both kinds"
        );
    }

    close_handle(handle);
}

/// A POPULATED `ShowRequest` buffer, built here so this suite can cross-feed one of the tables
/// the ledger names as the collision (`Show`/`Evolog`/`WorkspaceRoot`, which all put one string
/// in the slot after `kind`).
///
/// The ledger called that a FOUR-way collision, with `InterdiffRequest` as the fourth. It is a
/// three-way one since Epic 9 follow-up I turned interdiff's `from`/`to` into a `RevisionRef`
/// union, whose discriminant byte occupies the slot the string used to — so an interdiff buffer
/// and these three no longer verify as each other. This suite never fed one either way, so no
/// row here moved; `commit_views_ffi.rs` pins the divergence.
fn show_request_bytes(revset: &str) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let revset_off = b.create_string(revset);
    let req = fbs::ShowRequest::create(
        &mut b,
        &fbs::ShowRequestArgs {
            kind: fbs::RequestKind::Show,
            revset: Some(revset_off),
            limit: 0,
            has_limit: false,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// A minimal request buffer carrying `kind` and nothing else.
///
/// With every other field absent all fifteen request tables serialise to IDENTICAL bytes — the
/// interchangeability the tag exists to close — so this is at once a buffer built FOR `kind`'s
/// verb and a buffer that verifies as every other request table. That is what isolates the kind
/// rung: a structurally incompatible buffer is refused one rung earlier, by the Verifier.
/// `Unspecified` yields an UNTAGGED buffer, byte-identical to one built before the tag existed.
fn tagged_request_bytes(kind: fbs::RequestKind) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
    let req = fbs::ChangeIdList::create(
        &mut b,
        &fbs::ChangeIdListArgs {
            kind,
            change_ids: None,
            ..Default::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

// ── Story 9.23: workspace add / update-stale ──────────────────────────────────

/// The fields of a `WorkspaceAddRequest`, `None`/empty meaning absent.
#[derive(Default)]
struct AddReq<'a> {
    kind: Option<fbs::RequestKind>,
    destination: Option<&'a str>,
    name: Option<&'a str>,
    revisions: &'a [&'a str],
    message_paragraphs: &'a [&'a str],
    colocate: bool,
    no_colocate: bool,
    sparse: Option<fbs::SparseInheritance>,
}

fn add_request_bytes(r: &AddReq<'_>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let destination = r.destination.map(|s| b.create_string(s));
    let name = r.name.map(|s| b.create_string(s));
    let revisions: Vec<_> = r.revisions.iter().map(|s| b.create_string(s)).collect();
    let revisions = b.create_vector(&revisions);
    let paragraphs: Vec<_> = r.message_paragraphs.iter().map(|s| b.create_string(s)).collect();
    let paragraphs = b.create_vector(&paragraphs);
    let req = fbs::WorkspaceAddRequest::create(
        &mut b,
        &fbs::WorkspaceAddRequestArgs {
            kind: r.kind.unwrap_or(fbs::RequestKind::WorkspaceAdd),
            destination,
            name,
            revisions: Some(revisions),
            message_paragraphs: Some(paragraphs),
            colocate: r.colocate,
            no_colocate: r.no_colocate,
            sparse_patterns: r.sparse.unwrap_or(fbs::SparseInheritance::Copy),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn call_add(handle: u64, r: &AddReq<'_>) -> Vec<u8> {
    let bytes = add_request_bytes(r);
    // SAFETY: bytes is alive for the call; a stale handle is the caller's contract.
    unsafe { read_and_free(zanshin_workspace_add(handle, bytes.as_ptr(), bytes.len())) }
}

fn error_code(bytes: &[u8]) -> Option<String> {
    parse_envelope(bytes)
        .error()
        .and_then(|e| e.code())
        .map(ToOwned::to_owned)
}

/// The tiny fixture opened, and an empty temp dir to add workspaces into (absolute paths).
fn open_fixture_and_target() -> (u64, std::path::PathBuf, tempfile::TempDir) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let root = fixture.path.clone();
    let handle = open_handle(&root);
    std::mem::forget(fixture);
    (handle, root, tempfile::TempDir::new().expect("target tempdir"))
}

#[test]
fn workspace_add_round_trips_its_result() {
    test_helpers::pin_test_env();
    let (handle, _root, target) = open_fixture_and_target();
    let dest = target.path().join("ws2");
    let dest_str = dest.to_str().expect("utf-8").to_owned();

    let bytes = call_add(
        handle,
        &AddReq {
            destination: Some(&dest_str),
            name: Some("second"),
            message_paragraphs: &["T"],
            sparse: Some(fbs::SparseInheritance::Full),
            ..AddReq::default()
        },
    );

    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert_eq!(env.data_type(), fbs::Payload::WorkspaceAddResult);
    let result = env.data_as_workspace_add_result().expect("payload");
    assert_eq!(result.workspace_name(), Some("second"));
    assert_eq!(
        result.workspace_root().map(std::path::PathBuf::from),
        Some(fs::canonicalize(&dest).expect("created"))
    );
    assert!(!result.git_worktree_created());
    let mutation = result.mutation().expect("mutation");
    assert_eq!(mutation.new_change_ids().map(|v| v.len()), Some(1));
    // `message_paragraphs` crossed the wire: the new `@` carries the `-m` description.
    let new_at = mutation.working_copy_change_id().expect("new @").to_owned();
    let description = zanshin_jj::Repo::open(&dest)
        .expect("open the new workspace")
        .get_change(&zanshin_jj::ChangeId(new_at))
        .expect("new @")
        .description;
    assert_eq!(description, "T\n");
    assert!(result.checkout().is_some());
    assert!(
        env.precondition().is_some(),
        "the CURRENT workspace's pre-verb snapshot ran"
    );
    assert!(dest.join(".jj").join("repo").is_file());

    // The same name again refuses, naming it.
    let again = target.path().join("ws3");
    let again = again.to_str().expect("utf-8");
    let bytes = call_add(
        handle,
        &AddReq {
            destination: Some(again),
            name: Some("second"),
            ..AddReq::default()
        },
    );
    assert_eq!(error_code(&bytes).as_deref(), Some(JJ_WORKSPACE_EXISTS));
    assert_eq!(parse_envelope(&bytes).error().and_then(|e| e.context()), Some("second"));
    close_handle(handle);
}

#[test]
fn workspace_add_refuses_what_the_cli_refuses() {
    test_helpers::pin_test_env();
    let (handle, _root, target) = open_fixture_and_target();
    let busy = target.path().join("busy");
    fs::create_dir(&busy).expect("dir");
    fs::write(busy.join("f"), "x").expect("file");
    let busy = busy.to_str().expect("utf-8");

    let both = call_add(
        handle,
        &AddReq {
            destination: Some(busy),
            colocate: true,
            no_colocate: true,
            ..AddReq::default()
        },
    );
    assert_eq!(error_code(&both).as_deref(), Some(JJ_INVALID_INPUT));
    let missing = call_add(handle, &AddReq::default());
    assert_eq!(error_code(&missing).as_deref(), Some(JJ_INVALID_INPUT));
    let mismatched = call_add(
        handle,
        &AddReq {
            kind: Some(fbs::RequestKind::WorkspaceRoot),
            destination: Some(busy),
            ..AddReq::default()
        },
    );
    assert_eq!(error_code(&mismatched).as_deref(), Some(FFI_INVALID_ARGUMENT));
    let bad_sparse = call_add(
        handle,
        &AddReq {
            destination: Some(busy),
            sparse: Some(fbs::SparseInheritance(9)),
            ..AddReq::default()
        },
    );
    assert_eq!(error_code(&bad_sparse).as_deref(), Some(FFI_INVALID_ARGUMENT));
    let not_empty = call_add(
        handle,
        &AddReq {
            destination: Some(busy),
            ..AddReq::default()
        },
    );
    assert_eq!(error_code(&not_empty).as_deref(), Some(JJ_DESTINATION_NOT_EMPTY));
    assert!(
        parse_envelope(&not_empty).precondition().is_some(),
        "the snapshot ran first"
    );

    // SAFETY: a null request pointer is the case under test.
    let null = unsafe { read_and_free(zanshin_workspace_add(handle, std::ptr::null(), 0)) };
    assert_eq!(error_code(&null).as_deref(), Some(FFI_NULL_POINTER));
    let request = add_request_bytes(&AddReq {
        destination: Some(busy),
        ..AddReq::default()
    });
    // SAFETY: handle 0 is the case under test; request is alive for the call.
    let zero = unsafe { read_and_free(zanshin_workspace_add(0, request.as_ptr(), request.len())) };
    assert_eq!(error_code(&zero).as_deref(), Some(FFI_INVALID_HANDLE));
    close_handle(handle);
}

#[test]
fn workspace_add_without_separator_warns_on_the_envelope() {
    test_helpers::pin_test_env();
    let (handle, root, _target) = open_fixture_and_target();

    let bytes = call_add(
        handle,
        &AddReq {
            destination: Some("inside"),
            ..AddReq::default()
        },
    );

    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let codes: Vec<_> = env
        .warnings()
        .expect("warnings")
        .iter()
        .filter_map(|w| w.code())
        .collect();
    assert!(codes.contains(&JJ_WORKSPACE_IN_CURRENT_DIRECTORY), "{codes:?}");
    assert!(root.join("inside").join(".jj").is_dir());
    close_handle(handle);
}

#[test]
fn workspace_update_stale_round_trips_a_recovery() {
    test_helpers::pin_test_env();
    let (handle, root, _target) = open_fixture_and_target();

    // SAFETY: handle is live.
    let fresh = unsafe { read_and_free(zanshin_workspace_update_stale(handle)) };
    let env = parse_envelope(&fresh);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let recovery = env.data_as_stale_recovery().expect("payload");
    assert_eq!(recovery.outcome(), fbs::StaleRecoveryOutcome::NotStale);
    assert_eq!(recovery.commit_id(), None);
    assert!(recovery.checkout().is_none());
    assert!(env.precondition().is_some(), "the trailing snapshot's report");

    let at = zanshin_jj::Repo::open(&root)
        .expect("open")
        .list_workspaces()
        .expect("list")
        .into_iter()
        .find(|w| w.name == "default")
        .expect("default")
        .wc_commit_id
        .0;
    let rewritten = test_helpers::rewrite_commit_files(&root, &at, &[("elsewhere.txt", "x")]);
    // SAFETY: handle is live.
    let stale = unsafe { read_and_free(zanshin_workspace_update_stale(handle)) };
    let env = parse_envelope(&stale);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let recovery = env.data_as_stale_recovery().expect("payload");
    assert_eq!(recovery.outcome(), fbs::StaleRecoveryOutcome::Updated);
    assert_eq!(recovery.commit_id(), Some(rewritten.as_str()));
    assert!(recovery.checkout().is_some_and(|c| c.added() == 1));
    assert!(recovery.op_id().is_some());
    assert!(root.join("elsewhere.txt").is_file());

    // SAFETY: handle 0 is the case under test.
    let zero = unsafe { read_and_free(zanshin_workspace_update_stale(0)) };
    assert_eq!(error_code(&zero).as_deref(), Some(FFI_INVALID_HANDLE));
    close_handle(handle);
}

/// An explicitly EMPTY `name` is a value and refused (`jj.invalid_input`, nothing created); an
/// ABSENT one applies the CLI's default, the destination's final component (Story 9.23).
#[test]
fn workspace_add_refuses_an_empty_name_and_defaults_an_absent_one() {
    test_helpers::pin_test_env();
    let (handle, _root, target) = open_fixture_and_target();
    let dest = target.path().join("by-default");
    let dest = dest.to_str().expect("utf-8").to_owned();

    let empty = call_add(
        handle,
        &AddReq {
            destination: Some(&dest),
            name: Some(""),
            ..AddReq::default()
        },
    );
    assert_eq!(error_code(&empty).as_deref(), Some(JJ_INVALID_INPUT));
    assert!(!target.path().join("by-default").exists(), "nothing created");

    let absent = call_add(
        handle,
        &AddReq {
            destination: Some(&dest),
            ..AddReq::default()
        },
    );
    let env = parse_envelope(&absent);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    assert_eq!(
        env.data_as_workspace_add_result().and_then(|r| r.workspace_name()),
        Some("by-default")
    );
    close_handle(handle);
}

// ── zanshin_workspace_root: the CLI's command start-up ──────────────────────

/// One `zanshin_workspace_root` call: `(error code, warnings as (code, message))`.
fn call_root(handle: u64, name: Option<&str>) -> (Option<String>, Vec<(String, String)>) {
    let req = root_request_bytes(name);
    // SAFETY: handle is live; req is a valid buffer alive for the call.
    let token = unsafe { zanshin_workspace_root(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is fresh and non-null.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.precondition().is_none(), "no snapshot ran");
    let warnings = env
        .warnings()
        .iter()
        .flatten()
        .map(|w| (w.code().unwrap().to_owned(), w.message().unwrap().to_owned()))
        .collect();
    (env.error().and_then(|e| e.code()).map(str::to_owned), warnings)
}

/// Both forms run the CLI's command start-up, so a deprecated user key warns
/// `jj.config_deprecated` FIRST on the ok envelope and on the refusal alike.
#[test]
fn workspace_root_carries_the_start_up_deprecation_on_either_envelope() {
    test_helpers::own_process!("workspace_root_carries_the_start_up_deprecation_on_either_envelope");
    test_helpers::pin_test_env();
    let (handle, _root) = open_stale_scenario();
    let user = tempfile::TempDir::new().expect("tempdir");
    let user_file = user.path().join("user.toml");
    fs::write(&user_file, "fix.tools.t.line-range-arg = \"--l\"\n").expect("user config");
    // SAFETY: this test runs alone in its own process (`own_process!`).
    unsafe { std::env::set_var("JJ_CONFIG", &user_file) };
    let deprecated = (
        JJ_CONFIG_DEPRECATED.to_owned(),
        "Deprecated user-level config: fix.tools.t.line-range-arg is updated to \
         fix.tools.t.line-range-args = [\"--l\"]"
            .to_owned(),
    );

    assert_eq!(call_root(handle, None), (None, vec![deprecated.clone()]));
    let (error, warnings) = call_root(handle, Some("default"));
    assert_eq!(error, None);
    let codes: Vec<&str> = warnings.iter().map(|(code, _)| code.as_str()).collect();
    assert_eq!(codes, [JJ_CONFIG_DEPRECATED, JJ_WORKSPACE_PATH_INACCESSIBLE]);
    assert_eq!(warnings[0], deprecated);
    assert_eq!(
        call_root(handle, Some("nosuch")),
        (Some(JJ_WORKSPACE_NOT_FOUND.to_owned()), vec![deprecated])
    );
    close_handle(handle);
}

/// A config stack that no longer resolves refuses both forms as `jj.config_error`.
#[test]
fn workspace_root_refuses_a_broken_config_stack_on_both_forms() {
    test_helpers::pin_test_env();
    let (handle, root) = open_stale_scenario();
    fs::write(root.join(".jj").join("repo").join("config.toml"), "[user\nname = ").expect("repo config");

    for name in [None, Some("default")] {
        let (error, _warnings) = call_root(handle, name);
        assert_eq!(error.as_deref(), Some(JJ_CONFIG_ERROR), "{name:?}");
    }
    close_handle(handle);
}
