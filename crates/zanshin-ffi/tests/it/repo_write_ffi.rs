// SPDX-License-Identifier: MIT

//! Integration tests for the Story 6.5 mutation wrappers (`zanshin_describe`,
//! `zanshin_new_change`, `zanshin_edit`, `zanshin_abandon`, `zanshin_undo`,
//! `zanshin_git_fetch`) and Story 9.3's content ops (`zanshin_restore`,
//! `zanshin_absorb`).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the
//! Verifier — a wrong-shape payload is a compile error, not a runtime assert.
//! Every token is freed via `zanshin_buffer_free_token` so the suite is leak-clean.
//!
//! Mirrors `tests/it/change_ffi.rs`'s scaffolding for the handle/envelope helpers and
//! `zanshin-jj/tests/it/remotes_write.rs`'s local bare-git fixture for the `git_fetch`
//! rows. The `git_fetch` happy-path test additionally mirrors `tests/it/events_ffi.rs`'s
//! process-global event-sink registration to observe dispatched `Progress` envelopes.

use std::ffi::CString;
use std::fs;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use flatbuffers::root as fb_root;
use test_helpers::extract_fixture;
use zanshin_ffi::events::{zanshin_events_register, zanshin_events_unregister};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{
    zanshin_abandon, zanshin_absorb, zanshin_describe, zanshin_edit, zanshin_git_fetch, zanshin_network_cancel,
    zanshin_network_token, zanshin_new_change, zanshin_repo_close, zanshin_repo_open, zanshin_restore, zanshin_undo,
};
use zanshin_ffi::status::zanshin_status;
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CANCELLED, JJ_CHANGE_NOT_FOUND, JJ_CONFIG_ERROR,
    JJ_IMMUTABLE, JJ_INVALID_INPUT, JJ_NOTHING_TO_UNDO, JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
    JJ_UNDO_CROSS_WORKSPACE,
};
use zanshin_jj::{resolve_revset, ChangeId, Repo};

// ── Env pin ───────────────────────────────────────────────────────────────────

// ── Envelope helpers (mirrors tests/it/change_ffi.rs) ────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by one of the
/// `zanshin_*` functions and not yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// Parse bytes into a verified `fbs::Envelope`.
fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

/// Create a NUL-terminated C string from a Rust `&str`.
fn cstr(s: &str) -> CString {
    CString::new(s).expect("test string must not contain NUL bytes")
}

/// Build a `ChangeIdList` request buffer via `fbs::ChangeIdListArgs` (the ADR-0001
/// composite-input pattern).
///
/// `kind` is a PARAMETER because this one table is read by two wrappers: `NewChange` for
/// `zanshin_new_change`, `Abandon` for `zanshin_abandon`. Passing `Unspecified` builds an
/// UNTAGGED buffer — `FlatBuffers` writes nothing for a default-valued field, so those bytes
/// are identical to a pre-tag buffer's.
fn change_id_list_bytes(kind: fbs::RequestKind, ids: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let offs: Vec<_> = ids.iter().map(|s| b.create_string(s)).collect();
    let vec = b.create_vector(&offs);
    let list = fbs::ChangeIdList::create(
        &mut b,
        &fbs::ChangeIdListArgs {
            kind,
            change_ids: Some(vec),
            ..Default::default()
        },
    );
    b.finish(list, None);
    b.finished_data().to_vec()
}

/// Build a `NewChange`-tagged `ChangeIdList` with all three lists (Story 9.48): the positional
/// `parents`, `insert_after` (`-A`) and `insert_before` (`-B`).
fn new_change_request_bytes(parents: &[&str], insert_after: &[&str], insert_before: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let mut list = |ids: &[&str]| {
        let offs: Vec<_> = ids.iter().map(|s| b.create_string(s)).collect();
        b.create_vector(&offs)
    };
    let change_ids = list(parents);
    let after = list(insert_after);
    let before = list(insert_before);
    let req = fbs::ChangeIdList::create(
        &mut b,
        &fbs::ChangeIdListArgs {
            kind: fbs::RequestKind::NewChange,
            change_ids: Some(change_ids),
            insert_after: Some(after),
            insert_before: Some(before),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// The change ids `revset` denotes in the repo at `path`.
fn revset_ids(path: &Path, revset: &str) -> Vec<String> {
    let repo = Repo::open(path).expect("repo opens");
    resolve_revset(&repo, revset)
        .expect("revset resolves")
        .into_iter()
        .map(|id| id.0)
        .collect()
}

/// Build a `RestoreRequest` request buffer (Story 9.3). A `None` string is left ABSENT —
/// the wire form of "the user did not supply it", which is what selects the CLI's defaults.
fn restore_request_bytes(
    from: Option<&str>,
    into: Option<&str>,
    changes_in: Option<&str>,
    paths: &[&str],
    restore_descendants: bool,
) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let from_off = from.map(|s| b.create_string(s));
    let into_off = into.map(|s| b.create_string(s));
    let changes_in_off = changes_in.map(|s| b.create_string(s));
    let path_offs: Vec<_> = paths.iter().map(|s| b.create_string(s)).collect();
    let paths_vec = b.create_vector(&path_offs);
    let req = fbs::RestoreRequest::create(
        &mut b,
        &fbs::RestoreRequestArgs {
            kind: fbs::RequestKind::Restore,
            from: from_off,
            into: into_off,
            changes_in: changes_in_off,
            paths: Some(paths_vec),
            restore_descendants,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// Build an `AbsorbRequest` request buffer (Story 9.3). `into` is a revset EXPRESSION.
fn absorb_request_bytes(from: Option<&str>, into: Option<&str>, paths: &[&str]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let from_off = from.map(|s| b.create_string(s));
    let into_off = into.map(|s| b.create_string(s));
    let path_offs: Vec<_> = paths.iter().map(|s| b.create_string(s)).collect();
    let paths_vec = b.create_vector(&path_offs);
    let req = fbs::AbsorbRequest::create(
        &mut b,
        &fbs::AbsorbRequestArgs {
            kind: fbs::RequestKind::Absorb,
            from: from_off,
            into: into_off,
            paths: Some(paths_vec),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// The reverse-hex change id of the commit named by `commit_hex`, via the crate's own
/// revset resolver (a full commit hex is a revset symbol) — no `jj_lib` import needed.
fn change_id_for_commit(path: &Path, commit_hex: &str) -> String {
    let repo = Repo::open(path).expect("fixture opens");
    let mut ids = resolve_revset(&repo, commit_hex).expect("a commit hex resolves as a revset symbol");
    assert_eq!(ids.len(), 1, "a commit hex denotes exactly one change");
    ids.swap_remove(0).0
}

/// Open `path` and return `(handle, session_id)`.
fn open_handle(path: &Path) -> (u64, u64) {
    let p = cstr(path.to_str().expect("fixture path must be UTF-8"));
    // SAFETY: p is a valid NUL-terminated C string alive for the call.
    let token = unsafe { zanshin_repo_open(p.as_ptr()) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_open just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "expected ok, error: {:?}", env.error().and_then(|e| e.code()));
    let rh = env.data_as_repo_handle().expect("RepoHandle payload must be present");
    (rh.handle(), rh.session_id())
}

fn close_handle(handle: u64) {
    // SAFETY: handle originated from open_handle/init above and has not been closed.
    let token = unsafe { zanshin_repo_close(handle) };
    // SAFETY: token is the fresh, non-null token zanshin_repo_close just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "expected ok, error: {:?}", env.error().and_then(|e| e.code()));
}

/// Open the tiny fixture and return its raw handle + the working-copy change id.
///
/// The caller is responsible for closing the handle via `zanshin_repo_close`.
unsafe fn open_fixture_and_get_wc_change_id() -> (u64, String) {
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

    let status_token = unsafe { zanshin_status(handle) };
    let status_bytes = unsafe { read_and_free(status_token) };
    let status_env = parse_envelope(&status_bytes);
    assert!(status_env.ok(), "status must succeed");
    let wc_change_id = status_env
        .data_as_status()
        .expect("data_as_status must succeed")
        .working_copy_change_id()
        .expect("working_copy_change_id must be present")
        .to_owned();

    // The fixture handle is leaked into the caller — they must close it. Keep
    // `fixture` alive by leaking it (its TempDir lives for the test).
    std::mem::forget(fixture);

    (handle, wc_change_id)
}

// ── describe ──────────────────────────────────────────────────────────────────

#[test]
fn describe_valid_round_trip_returns_ok_mutation_result() {
    test_helpers::pin_test_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    let change_cstr = cstr(&wc_change_id);
    let desc_cstr = cstr("a new description");
    let token = unsafe { zanshin_describe(handle, change_cstr.as_ptr(), desc_cstr.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "describe must succeed for a valid id");
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    assert!(mr.new_op_id().is_some_and(|s| !s.is_empty()), "new_op_id must be set");
    assert!(
        mr.new_change_ids().is_none_or(|v| v.is_empty()),
        "describe never mints a new change"
    );
    assert!(
        mr.abandoned_change_ids().is_none_or(|v| v.is_empty()),
        "describe never abandons a change"
    );

    close_handle(handle);
}

// ── new_change ────────────────────────────────────────────────────────────────

#[test]
fn new_change_valid_round_trip_returns_one_new_change_id() {
    test_helpers::pin_test_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    let req = change_id_list_bytes(fbs::RequestKind::NewChange, &[&wc_change_id]);
    let token = unsafe { zanshin_new_change(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "new_change must succeed for a valid parent");
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    let new_ids = mr.new_change_ids().expect("new_change_ids must be present");
    assert_eq!(new_ids.len(), 1, "new_change mints exactly one new change");
    assert_eq!(
        mr.working_copy_change_id(),
        Some(new_ids.get(0)),
        "the new change becomes @"
    );

    close_handle(handle);
}

#[test]
fn new_change_empty_parents_returns_jj_invalid_input() {
    test_helpers::pin_test_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let req = change_id_list_bytes(fbs::RequestKind::NewChange, &[]);
    let token = unsafe { zanshin_new_change(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "empty parents must produce an error envelope");
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));

    close_handle(handle);
}

#[test]
fn new_change_insert_after_puts_the_new_change_between_target_and_child() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let (handle, _) = open_handle(&fixture.path);
    // The fixture is `root → Commit 1 → Commit 2 → Commit 3` plus an empty `@` on root.
    let [target] = revset_ids(&fixture.path, "description(substring:\"Commit 2\")")
        .try_into()
        .expect("one Commit 2");
    let [child] = revset_ids(&fixture.path, "description(substring:\"Commit 3\")")
        .try_into()
        .expect("one Commit 3");

    let req = new_change_request_bytes(&[], &[&target], &[]);
    // SAFETY: handle is open; req is a live buffer for the call.
    let token = unsafe { zanshin_new_change(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token zanshin_new_change just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(
        env.ok(),
        "new -A must succeed, error={:?}/{:?}",
        env.error().and_then(|e| e.code()),
        env.error().and_then(|e| e.context())
    );
    let mr = env.data_as_mutation_result().expect("MutationResult payload");
    let new_ids = mr.new_change_ids().expect("new_change_ids must be present");
    assert_eq!(new_ids.len(), 1, "new -A mints exactly one change");
    let new_id = new_ids.get(0).to_owned();
    assert_eq!(
        mr.working_copy_change_id(),
        Some(new_id.as_str()),
        "the new change is @"
    );
    close_handle(handle);

    assert_eq!(revset_ids(&fixture.path, &format!("{new_id}-")), [target]);
    assert_eq!(revset_ids(&fixture.path, &format!("{new_id}+")), [child]);
}

#[test]
fn new_change_insert_before_root_returns_jj_immutable() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let (handle, _) = open_handle(&fixture.path);
    let [root] = revset_ids(&fixture.path, "root()").try_into().expect("one root");

    let req = new_change_request_bytes(&[], &[], &[&root]);
    // SAFETY: handle is open; req is a live buffer for the call.
    let token = unsafe { zanshin_new_change(handle, req.as_ptr(), req.len()) };
    // SAFETY: token is the fresh, non-null token zanshin_new_change just returned.
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "new -B root must be refused");
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_IMMUTABLE));
    assert_eq!(
        env.error().and_then(|e| e.context()),
        Some("0".repeat(40).as_str()),
        "the root commit's full hex is in context"
    );
    close_handle(handle);
}

// ── edit ──────────────────────────────────────────────────────────────────────

#[test]
fn edit_valid_round_trip_moves_working_copy() {
    test_helpers::pin_test_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    // Mint a genuine ANCESTOR relationship to edit back across: new_change(A) creates
    // B on top of the original @ (A) and switches @ to B; editing back to A is then a
    // real "switch to a different, already-existing change" — editing @ to itself is a
    // no-op since Story 9.38 (the CLI's "Already editing that commit."), so the test
    // edits back to a different change.
    let req = change_id_list_bytes(fbs::RequestKind::NewChange, &[&wc_change_id]);
    let new_change_token = unsafe { zanshin_new_change(handle, req.as_ptr(), req.len()) };
    let new_change_bytes = unsafe { read_and_free(new_change_token) };
    assert!(parse_envelope(&new_change_bytes).ok(), "new_change must succeed");

    let change_cstr = cstr(&wc_change_id);
    let token = unsafe { zanshin_edit(handle, change_cstr.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(
        env.ok(),
        "edit must succeed for a valid id, error={:?}/{:?}",
        env.error().and_then(|e| e.code()),
        env.error().and_then(|e| e.context())
    );
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    assert_eq!(
        mr.working_copy_change_id(),
        Some(wc_change_id.as_str()),
        "@ now names the edited change"
    );
    assert!(mr.new_change_ids().is_none_or(|v| v.is_empty()), "edit mints nothing");

    close_handle(handle);
}

// ── abandon ───────────────────────────────────────────────────────────────────

#[test]
fn abandon_wc_included_returns_replacement_new_change_id() {
    test_helpers::pin_test_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    let req = change_id_list_bytes(fbs::RequestKind::Abandon, &[&wc_change_id]);
    let token = unsafe { zanshin_abandon(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "abandon must succeed for a valid id");
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    let new_ids = mr.new_change_ids().expect("new_change_ids must be present");
    assert_eq!(new_ids.len(), 1, "abandoning @ mints its replacement");
    let abandoned = mr.abandoned_change_ids().expect("abandoned_change_ids must be present");
    assert_eq!(abandoned.iter().collect::<Vec<_>>(), vec![wc_change_id.as_str()]);

    close_handle(handle);
}

#[test]
fn abandon_empty_change_ids_returns_jj_invalid_input() {
    test_helpers::pin_test_env();
    // SAFETY: valid fixture path; well-formed handle lifetime within this test.
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let req = change_id_list_bytes(fbs::RequestKind::Abandon, &[]);
    let token = unsafe { zanshin_abandon(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "empty change_ids must produce an error envelope");
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));

    close_handle(handle);
}

// ── the immutability guard, across the boundary (Story 9.1) ───────────────────

/// Extracts `tiny-3-commits` with `toml` written into its repo config layer, then opens it
/// through the FFI. Returns the fixture (the caller must keep it alive so the `TempDir`
/// outlives the handle), the handle, and the `@` change id.
///
/// `open_fixture_and_get_wc_change_id` leaks its fixture and so hands back no path; these
/// tests need one, because the repo config is how the immutable set is chosen without
/// having to plumb a commit hex through the FFI.
///
/// # Safety
/// The returned handle must be closed with `zanshin_repo_close` before the fixture drops.
unsafe fn open_fixture_with_repo_config(toml: &str) -> (test_helpers::FixtureHandle, u64, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    fs::write(fixture.path.join(".jj").join("repo").join("config.toml"), toml).expect("repo config must be writable");
    let path_cstr = cstr(fixture.path.to_str().expect("fixture path must be valid UTF-8"));

    let open_token = unsafe { zanshin_repo_open(path_cstr.as_ptr()) };
    let open_bytes = unsafe { read_and_free(open_token) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();

    let status_token = unsafe { zanshin_status(handle) };
    let status_bytes = unsafe { read_and_free(status_token) };
    let status_env = parse_envelope(&status_bytes);
    assert!(status_env.ok(), "status must succeed");
    let wc_change_id = status_env
        .data_as_status()
        .expect("data_as_status must succeed")
        .working_copy_change_id()
        .expect("working_copy_change_id must be present")
        .to_owned();

    (fixture, handle, wc_change_id)
}

/// `jj.immutable` must actually reach the Dart side. The inline mapper unit test only
/// proves `MutateError::Immutable` maps to the constant; this proves the whole envelope —
/// `ok = false`, that code, and the offending hex commit id in `context`, which is what a
/// GUI needs in order to explain the refusal and offer a way out.
#[test]
fn describe_on_an_immutable_commit_returns_jj_immutable_with_the_commit_in_context() {
    test_helpers::pin_test_env();
    // `immutable_heads() = all()` makes every commit immutable, so this needs no tag setup.
    // SAFETY: handle is closed below, before `fixture` drops at end of scope.
    let (fixture, handle, wc_change_id) =
        unsafe { open_fixture_with_repo_config("[revset-aliases]\n'immutable_heads()' = 'all()'\n") };

    let id = cstr(&wc_change_id);
    let desc = cstr("nope");
    let token = unsafe { zanshin_describe(handle, id.as_ptr(), desc.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "an immutable target must produce an error envelope");
    let error = env.error().expect("error must be present");
    assert_eq!(error.code(), Some(JJ_IMMUTABLE));
    let context = error.context().expect("the offending commit id must be in context");
    assert!(
        context.len() == 40 && context.chars().all(|c| c.is_ascii_hexdigit()),
        "context must be a hex commit id, got {context:?}"
    );

    // The refusal must be real, not cosmetic: the description is unchanged.
    let mut repo = Repo::open(&fixture.path).expect("fixture reopens");
    let change = repo
        .get_change(&ChangeId(wc_change_id))
        .expect("the working-copy change must still exist");
    assert_ne!(change.description, "nope", "a refused describe must not have written");

    close_handle(handle);
}

/// The guard's other new failure mode: it cannot determine what is protected. That must
/// arrive as the same `jj.config_error` the read side already reports (Story 4.9), not as
/// the unclassified `jj.jj_lib_error` bucket — otherwise a GUI that special-cases a broken
/// config stops recognising it the moment the fault comes from a mutation.
#[test]
fn describe_with_a_malformed_repo_config_returns_jj_config_error() {
    test_helpers::pin_test_env();
    // SAFETY: handle is closed below, before `fixture` drops at end of scope.
    let (fixture, handle, wc_change_id) = unsafe { open_fixture_with_repo_config("") };
    // Broken AFTER the open: since Story 9.27 a broken stack refuses `zanshin_repo_open` itself,
    // so an open handle is where the mutation-side refusal is met.
    fs::write(
        fixture.path.join(".jj").join("repo").join("config.toml"),
        "not = = toml\n",
    )
    .expect("repo config must be writable");

    let id = cstr(&wc_change_id);
    let desc = cstr("nope");
    let token = unsafe { zanshin_describe(handle, id.as_ptr(), desc.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "an unreadable config must produce an error envelope");
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CONFIG_ERROR));
    assert!(
        env.error()
            .and_then(|e| e.context())
            .is_some_and(|c| c.contains("config.toml")),
        "context must name the offending file, as the read side's rows do"
    );

    close_handle(handle);
}

// ── undo ──────────────────────────────────────────────────────────────────────

#[test]
fn undo_valid_round_trip_restores_previous_op() {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let path_cstr = cstr(tmp.path().to_str().unwrap());

    let init_token = unsafe { repo_init(&path_cstr, 0) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "init must succeed");
    let handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();

    // Perform a mutation so there is something to undo.
    let status_token = unsafe { zanshin_status(handle) };
    let status_bytes = unsafe { read_and_free(status_token) };
    let status_env = parse_envelope(&status_bytes);
    assert!(status_env.ok(), "status must succeed");
    let wc_id = status_env
        .data_as_status()
        .expect("data_as_status must succeed")
        .working_copy_change_id()
        .expect("working_copy_change_id must be present")
        .to_owned();
    let desc_cstr = cstr("about to be undone");
    let change_cstr = cstr(&wc_id);
    let describe_token = unsafe { zanshin_describe(handle, change_cstr.as_ptr(), desc_cstr.as_ptr()) };
    let describe_bytes = unsafe { read_and_free(describe_token) };
    assert!(parse_envelope(&describe_bytes).ok(), "describe must succeed");

    let token = unsafe { zanshin_undo(handle, false) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(env.ok(), "undo must succeed");
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    assert!(mr.new_op_id().is_some_and(|s| !s.is_empty()));

    close_handle(handle);
}

/// Head-is-root `NothingToUndo` (mirrors `zanshin-jj`'s own
/// `undo_at_root_operation_returns_nothing_to_undo`): a fresh workspace's head
/// always has >=1 parent, so engineer the unreachable state directly by rewriting
/// `op_heads/heads/` so the ONLY marker is the root op itself.
#[test]
fn undo_root_op_returns_jj_nothing_to_undo() {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().unwrap();
    let path_cstr = cstr(tmp.path().to_str().unwrap());

    let init_token = unsafe { repo_init(&path_cstr, 0) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "init must succeed");
    let handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();

    let op_log_token = unsafe { zanshin_ffi::op_log::zanshin_op_log(handle, -1) };
    let op_log_bytes = unsafe { read_and_free(op_log_token) };
    let op_log_env = parse_envelope(&op_log_bytes);
    assert!(op_log_env.ok(), "op_log must succeed");
    let ops = op_log_env.data_as_op_log().expect("OpLog must be present");
    let operations = ops.operations().expect("operations must be present");
    let head_hex = operations.get(0).id().expect("head id").to_owned();
    let root_hex = operations
        .iter()
        .find(fbs::Operation::root_op)
        .expect("root op must be present")
        .id()
        .expect("root id")
        .to_owned();

    close_handle(handle);

    let heads_dir = tmp.path().join(".jj").join("repo").join("op_heads").join("heads");
    fs::remove_file(heads_dir.join(&head_hex)).unwrap();
    fs::write(heads_dir.join(&root_hex), "").unwrap();

    let (fresh_handle, _) = open_handle(tmp.path());
    let token = unsafe { zanshin_undo(fresh_handle, false) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "undo at the root operation must produce an error envelope");
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_NOTHING_TO_UNDO));

    close_handle(fresh_handle);
}

/// jj 0.46 (Story 9.39): an operation performed in ANOTHER workspace is refused with
/// `jj.undo_cross_workspace` — `"<operation>\n<workspace>"` in `context` — unless
/// `allow_cross_workspace` is true, which undoes it.
#[test]
fn undo_cross_workspace_refuses_unless_allowed() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    // The handle keeps the second workspace's directory alive for the test's duration.
    let (second, second_wc) = test_helpers::add_workspace(&fixture.path, "second");

    let (second_handle, _) = open_handle(&second.path);
    let wc_change = {
        let repo = Repo::open(&second.path).expect("open second");
        let ids = resolve_revset(&repo, &second_wc).expect("resolve second's @");
        ids[0].0.clone()
    };
    let change_cstr = cstr(&wc_change);
    let desc_cstr = cstr("described in second");
    let describe_token = unsafe { zanshin_describe(second_handle, change_cstr.as_ptr(), desc_cstr.as_ptr()) };
    assert!(
        parse_envelope(&unsafe { read_and_free(describe_token) }).ok(),
        "describe in second"
    );
    close_handle(second_handle);

    let (handle, _) = open_handle(&fixture.path);
    let refused = unsafe { read_and_free(zanshin_undo(handle, false)) };
    let env = parse_envelope(&refused);
    assert!(!env.ok(), "an operation of another workspace is refused by default");
    let error = env.error().expect("error");
    assert_eq!(error.code(), Some(JJ_UNDO_CROSS_WORKSPACE));
    let context = error.context().expect("context").to_owned();
    let (operation, workspace) = context.split_once('\n').expect("two lines");
    assert_eq!(operation.len(), 12, "the CLI's short operation id");
    assert_eq!(workspace, "second");
    // Story 9.56: the CLI's hint rides `FfiError.hints`.
    let hints: Vec<&str> = error.hints().expect("hints").iter().collect();
    assert_eq!(
        hints,
        ["Use `--allow-cross-workspace` to undo it anyway, or use `jj op revert` to revert a specific operation"]
    );

    let allowed = unsafe { read_and_free(zanshin_undo(handle, true)) };
    assert!(parse_envelope(&allowed).ok(), "allowed, it is undone");
    close_handle(handle);
}

// ── git_fetch ─────────────────────────────────────────────────────────────────

// Serializes the tests in this file that touch the process-global event sink
// (mirrors tests/it/events_ffi.rs's TEST_GUARD); both run in a child process of
// their own (`test_helpers::own_process!`), so no other module's sink collides.
static TEST_GUARD: Mutex<()> = Mutex::new(());
static RECEIVED: Mutex<Vec<Vec<u8>>> = Mutex::new(Vec::new());

unsafe extern "C" fn test_sink(token: *mut ZanshinBuf) {
    // SAFETY: forwarded from the `EventCallback` contract — `token` is a valid,
    // non-null token produced by `events::dispatch` via `vec_into_token`.
    let bytes = unsafe { read_and_free(token) };
    received_lock().push(bytes);
}

fn received_lock() -> std::sync::MutexGuard<'static, Vec<Vec<u8>>> {
    RECEIVED.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn drain_received() -> Vec<Vec<u8>> {
    std::mem::take(&mut received_lock())
}

/// Run a git command in `dir`; panics on non-zero exit.
fn git_cmd(args: &[&str], dir: &Path) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// Build a plain Git repo at `path` with one commit on `main`.
fn init_git_repo_with_commit(path: &Path) {
    git_cmd(&["init", "--initial-branch=main"], path);
    git_cmd(&["config", "user.email", "test@zanshin.test"], path);
    git_cmd(&["config", "user.name", "Fixture"], path);
    fs::write(path.join("README.md"), "hello").expect("write README");
    git_cmd(&["add", "."], path);
    git_cmd(&["commit", "-m", "initial"], path);
}

/// Clone a normal Git repo as a bare repo (returns the bare repo path inside `parent`).
fn git_bare_clone(src: &Path, parent: &Path) -> std::path::PathBuf {
    let bare = parent.join("bare.git");
    git_cmd(
        &["clone", "--bare", &src.to_string_lossy(), &bare.to_string_lossy()],
        parent,
    );
    bare
}

/// Register `name` -> `url` as a git remote on the jj Git-backend workspace at
/// `root`, by writing directly to the embedded git store's config (the same disk
/// effect as jj-lib's `git::add_remote`; `zanshin_jj::remotes::git_fetch` computes
/// its own bookmark/tag refspecs, so the remote-level `tagOpt` setting jj-lib would
/// additionally set doesn't matter here). A fresh `zanshin_repo_open` afterward is
/// required so the freshly-loaded `GitBackend` reads the new remote from disk
/// (mirrors `zanshin-jj/tests/it/remotes_write.rs::register_remote`'s own note).
fn register_remote(root: &Path, name: &str, url: &str) {
    let git_dir = root.join(".jj").join("repo").join("store").join("git");
    git_cmd(&["remote", "add", name, url], &git_dir);
}

/// A `GitFetchRequest` (Story 9.30): `remotes` as `Named` patterns when given (else `Default`),
/// the default refs, and `cancel_token`.
fn fetch_request(remotes: Option<&[&str]>, cancel_token: u64) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(128);
    let names = remotes.map(|names| {
        let offsets: Vec<_> = names.iter().map(|name| b.create_string(name)).collect();
        b.create_vector(&offsets)
    });
    let req = fbs::GitFetchRequest::create(
        &mut b,
        &fbs::GitFetchRequestArgs {
            kind: fbs::RequestKind::GitFetch,
            remotes_mode: if remotes.is_some() {
                fbs::FetchRemotesMode::Named
            } else {
                fbs::FetchRemotesMode::Default
            },
            remotes: names,
            cancel_token,
            ..Default::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// `zanshin_git_fetch` with `request`, its envelope bytes.
fn git_fetch(handle: u64, request: &[u8]) -> Vec<u8> {
    unsafe { read_and_free(zanshin_git_fetch(handle, request.as_ptr(), request.len())) }
}

#[test]
fn git_fetch_happy_path_reports_progress_and_returns_mutation_result() {
    test_helpers::own_process!("git_fetch_happy_path_reports_progress_and_returns_mutation_result");
    test_helpers::pin_test_env();
    let _test_guard = TEST_GUARD.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    drain_received();

    let src = tempfile::TempDir::new().unwrap();
    init_git_repo_with_commit(src.path());

    let parent = tempfile::TempDir::new().unwrap();
    let bare = git_bare_clone(src.path(), parent.path());

    let dst = tempfile::TempDir::new().unwrap();
    let dst_cstr = cstr(dst.path().to_str().unwrap());
    let init_token = unsafe { repo_init(&dst_cstr, 1) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "init (git backend) must succeed");
    let init_handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();
    close_handle(init_handle);

    // The only remote, not `origin`: the default resolution picks it and reports the CLI's hint
    // (Story 9.30).
    register_remote(dst.path(), "up", &bare.to_string_lossy());

    let (handle, session_id) = open_handle(dst.path());

    zanshin_events_register(Some(test_sink));

    let bytes = git_fetch(handle, &fetch_request(None, 0));
    let env = parse_envelope(&bytes);

    assert!(
        env.ok(),
        "git_fetch must succeed, error: {:?}",
        env.error().and_then(|e| e.code())
    );
    let result = env
        .data_as_git_fetch_result()
        .expect("data_as_git_fetch_result must succeed");
    let list = |v: Option<flatbuffers::Vector<'_, flatbuffers::ForwardsUOffset<&str>>>| {
        v.expect("present").iter().map(ToOwned::to_owned).collect::<Vec<_>>()
    };
    let new_op_id = result
        .mutation()
        .and_then(|m| m.new_op_id())
        .expect("new_op_id")
        .to_owned();
    assert!(!new_op_id.is_empty());
    assert_eq!(list(result.remotes()), ["up"]);
    assert_eq!(list(result.hints()), ["Fetching from the only existing remote: up"]);
    assert!(list(result.failed_ref_names()).is_empty());
    let changed: Vec<_> = result
        .changed_bookmarks()
        .expect("changed_bookmarks")
        .iter()
        .map(|u| (u.name(), u.remote(), u.kind()))
        .collect();
    assert_eq!(changed, [(Some("main"), Some("up"), fbs::GitRefUpdateKind::New)]);
    assert!(result.changed_tags().expect("changed_tags").is_empty());
    assert_eq!(result.num_rewritten(), 0);
    let head = Repo::open(dst.path()).expect("open").op_log(Some(1)).expect("op log");
    assert_eq!(head[0].id.0, new_op_id);
    assert_eq!(head[0].description, "fetch from git remote(s) up");

    // Poll briefly: dispatch happens on the calling thread synchronously inside
    // git_fetch's progress closure, but give a generous margin (R7) before failing.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut progress_envelopes = Vec::new();
    loop {
        for raw in drain_received() {
            let e = parse_envelope(&raw);
            if e.ok() && e.data_type() == fbs::Payload::Progress {
                progress_envelopes.push(raw);
            }
        }
        if !progress_envelopes.is_empty() || Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    assert!(
        !progress_envelopes.is_empty(),
        "expected at least one Progress envelope"
    );
    for raw in &progress_envelopes {
        let e = parse_envelope(raw);
        let progress = e.data_as_progress().expect("Progress payload must be present");
        assert_eq!(
            progress.session_id(),
            session_id,
            "session_id must match the handle's session"
        );
        assert_eq!(progress.operation(), Some("fetch"));
    }

    zanshin_events_unregister();
    close_handle(handle);
}

/// Story 9.52: a fetch under a live token is a normal fetch; under a token cancelled before it
/// ran it refuses as `jj.cancelled` and writes no operation.
#[test]
fn git_fetch_with_a_cancel_token() {
    test_helpers::own_process!("git_fetch_with_a_cancel_token");
    test_helpers::pin_test_env();
    // The fetch dispatches progress to the process-global sink: serialized with the test that
    // registers one and asserts every event is its own.
    let _test_guard = TEST_GUARD.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let src = tempfile::TempDir::new().unwrap();
    init_git_repo_with_commit(src.path());
    let parent = tempfile::TempDir::new().unwrap();
    let bare = git_bare_clone(src.path(), parent.path());
    let dst = tempfile::TempDir::new().unwrap();
    let dst_cstr = cstr(dst.path().to_str().unwrap());
    let init_bytes = unsafe { read_and_free(repo_init(&dst_cstr, 1)) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "init (git backend) must succeed");
    close_handle(init_env.data_as_repo_handle().expect("RepoHandle").handle());
    register_remote(dst.path(), "origin", &bare.to_string_lossy());
    let (handle, _) = open_handle(dst.path());

    let live = zanshin_network_token();
    let bytes = git_fetch(handle, &fetch_request(None, live));
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    let head = env
        .data_as_git_fetch_result()
        .and_then(|r| r.mutation())
        .and_then(|m| m.new_op_id())
        .map(ToOwned::to_owned);

    let cancelled = zanshin_network_token();
    zanshin_network_cancel(cancelled);
    let bytes = git_fetch(handle, &fetch_request(None, cancelled));
    let env = parse_envelope(&bytes);
    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_CANCELLED));
    assert_eq!(env.error().and_then(|e| e.context()), Some("Cancelled"));
    let ops = Repo::open(dst.path()).expect("open").op_log(Some(1)).expect("op log");
    assert_eq!(
        Some(ops[0].id.0.clone()),
        head,
        "the cancelled fetch wrote no operation"
    );
    close_handle(handle);
}

/// Story 9.56: a fetch from a Git remote named `git` — reserved by jj — refuses `jj.invalid_input`
/// with jj-lib's reason alone in `context` and the CLI's rename hint in `FfiError.hints`
/// (`command_error.rs:586-588` @ v0.46.0).
#[test]
fn git_fetch_from_a_remote_named_git_carries_the_rename_hint() {
    test_helpers::pin_test_env();
    let src = tempfile::TempDir::new().unwrap();
    init_git_repo_with_commit(src.path());
    let parent = tempfile::TempDir::new().unwrap();
    let bare = git_bare_clone(src.path(), parent.path());
    let dst = tempfile::TempDir::new().unwrap();
    let dst_cstr = cstr(dst.path().to_str().unwrap());
    let init_bytes = unsafe { read_and_free(repo_init(&dst_cstr, 1)) };
    let init_handle = parse_envelope(&init_bytes)
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();
    close_handle(init_handle);
    register_remote(dst.path(), "git", &bare.to_string_lossy());
    let (handle, _) = open_handle(dst.path());

    let bytes = git_fetch(handle, &fetch_request(Some(&["git"]), 0));
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "a reserved remote name refuses");
    let error = env.error().expect("error");
    assert_eq!(error.code(), Some(JJ_INVALID_INPUT));
    assert_eq!(
        error.context(),
        Some("Git remote named 'git' is reserved for local Git repository"),
        "no in-band hint text"
    );
    let hints: Vec<&str> = error.hints().expect("hints").iter().collect();
    assert_eq!(hints, ["Run `jj git remote rename` to give a different name."]);

    close_handle(handle);
}

/// A `--remote` that names no remote is the CLI's warning plus its refusal (Story 9.30):
/// `jj.fetch_remotes_unmatched`, then `jj.invalid_input` "No git remotes to fetch from" — no
/// longer `jj.remote_not_found`.
#[test]
fn git_fetch_nonexistent_remote_warns_and_returns_jj_invalid_input() {
    test_helpers::pin_test_env();
    let dst = tempfile::TempDir::new().unwrap();
    let dst_cstr = cstr(dst.path().to_str().unwrap());
    let init_token = unsafe { repo_init(&dst_cstr, 1) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "init (git backend) must succeed");
    let handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();

    let bytes = git_fetch(handle, &fetch_request(Some(&["nonexistent"]), 0));
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "unknown remote must produce an error envelope");
    let error = env.error().expect("error");
    assert_eq!(error.code(), Some(JJ_INVALID_INPUT));
    assert_eq!(error.context(), Some("No git remotes to fetch from"));
    assert!(
        error.hints().is_none(),
        "a hint-less refusal writes no `hints` (Story 9.56)"
    );
    let warnings: Vec<(String, String)> = env
        .warnings()
        .expect("warnings")
        .iter()
        .map(|w| {
            (
                w.code().unwrap_or_default().to_owned(),
                w.message().unwrap_or_default().to_owned(),
            )
        })
        .collect();
    assert!(
        warnings.contains(&(
            zanshin_ffi::JJ_FETCH_REMOTES_UNMATCHED.to_owned(),
            "No matching remotes for names: nonexistent".to_owned()
        )),
        "{warnings:?}"
    );

    close_handle(handle);
}

/// The observable half of the Epic 9 git-sync follow-up: a NATIVE workspace (`backend = 0`)
/// has no git backend, and `zanshin_git_fetch` now reports that as `jj.not_a_git_repo` —
/// the code the six `zanshin_git_*` wrappers already use — where it used to report
/// `jj.remote_not_found`. Like every other producer of that code from a workspace (rather
/// than a path), it carries NO `context`: there is no path to name.
#[test]
fn git_fetch_on_native_backend_returns_jj_not_a_git_repo() {
    test_helpers::pin_test_env();
    let dst = tempfile::TempDir::new().unwrap();
    let dst_cstr = cstr(dst.path().to_str().unwrap());
    let init_token = unsafe { repo_init(&dst_cstr, 0) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok(), "init (native backend) must succeed");
    let handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();

    let bytes = git_fetch(handle, &fetch_request(None, 0));
    let env = parse_envelope(&bytes);

    assert!(!env.ok(), "a native backend must produce an error envelope");
    let error = env.error().expect("error must be present");
    assert_eq!(error.code(), Some(zanshin_ffi::JJ_NOT_A_GIT_REPO));
    assert_eq!(error.context(), None, "the variant names no path, so context is absent");

    close_handle(handle);
}

// ── restore / absorb (Story 9.3) ──────────────────────────────────────────────

/// `A(a.txt="A") -> B(a.txt="B")` off root, plus a source `S` whose one-line edit annotates
/// back to `A`. Purpose-built: the committed fixtures give every commit its own unique file,
/// so no fixture path survives across commits.
///
/// Returns the fixture (the caller must keep it alive so the `TempDir` outlives the handle),
/// the handle, and the change ids of `A`, `B` and `S`.
///
/// # Safety
/// The returned handle must be closed with `zanshin_repo_close` before the fixture drops.
unsafe fn open_content_fixture() -> (test_helpers::FixtureHandle, u64, String, String, String) {
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let a = test_helpers::add_commit_with_files(&fixture.path, &[], &[("a.txt", "one\ntwo\n")], "ancestor");
    let b = test_helpers::add_commit_with_files(&fixture.path, &[&a], &[("a.txt", "B\n")], "destination");
    let s = test_helpers::add_commit_with_files(&fixture.path, &[&a], &[("a.txt", "one\nCHANGED\n")], "source");
    let a_change = change_id_for_commit(&fixture.path, &a);
    let b_change = change_id_for_commit(&fixture.path, &b);
    let s_change = change_id_for_commit(&fixture.path, &s);
    let handle = open_handle(&fixture.path).0;

    (fixture, handle, a_change, b_change, s_change)
}

/// The hex tree id a change CURRENTLY points at — the FFI-side equivalent of
/// `zanshin-jj/tests/it/content_ops.rs::tree_hex_of_change`, resolving the change through the
/// crate's own read API and then reading the tree via `test_helpers`.
///
/// Trees are content-addressed, so comparing tree hexes asserts file CONTENT without
/// reading blobs: a purpose-built commit holding the expected files has the same tree id as
/// the expected result.
fn tree_hex_of_change(path: &Path, change: &str) -> String {
    let mut repo = Repo::open(path).expect("fixture opens");
    let commit_hex = repo
        .get_change(&ChangeId(change.to_owned()))
        .expect("change resolves")
        .commit_id
        .0;
    test_helpers::tree_hex(path, &commit_hex)
}

/// The happy path has to prove DATA MOVED, and in which DIRECTION. `ok` + a non-empty
/// `new_op_id` + an empty `new_change_ids` are all satisfied by the no-op path (which
/// returns the pre-call head op id) and by a `from`/`into` swap, so they prove nothing on
/// their own — hence the tree assertions.
#[test]
fn restore_valid_round_trip_moves_the_source_tree_into_the_destination() {
    test_helpers::pin_test_env();
    // SAFETY: handle is closed below, before `fixture` drops at end of scope.
    let (fixture, handle, a_change, b_change, _) = unsafe { open_content_fixture() };
    let a_tree_before = tree_hex_of_change(&fixture.path, &a_change);
    let b_tree_before = tree_hex_of_change(&fixture.path, &b_change);
    assert_ne!(
        a_tree_before, b_tree_before,
        "the two sides must differ, or the direction assertions below are vacuous"
    );

    let req = restore_request_bytes(Some(&a_change), Some(&b_change), None, &[], false);
    let token = unsafe { zanshin_restore(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(
        env.ok(),
        "restore must succeed, error={:?}/{:?}",
        env.error().and_then(|e| e.code()),
        env.error().and_then(|e| e.context())
    );
    assert_eq!(env.data_type(), fbs::Payload::MutationResult);
    let mr = env
        .data_as_mutation_result()
        .expect("data_as_mutation_result must succeed");
    assert!(mr.new_op_id().is_some_and(|s| !s.is_empty()), "new_op_id must be set");
    assert!(
        mr.new_change_ids().is_none_or(|v| v.is_empty()),
        "restore mints nothing"
    );

    assert_eq!(
        tree_hex_of_change(&fixture.path, &b_change),
        a_tree_before,
        "the DESTINATION took the source's content"
    );
    assert_eq!(
        tree_hex_of_change(&fixture.path, &a_change),
        a_tree_before,
        "the SOURCE is untouched — restore is one-directional"
    );

    close_handle(handle);
    drop(fixture);
}

/// `paths` must actually reach `zanshin_jj::Repo::restore`: with the field hardcoded to an
/// empty list in `read_restore_request`, `b.txt` would take the source's content too.
#[test]
fn restore_with_a_path_filter_moves_only_the_named_path() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let a =
        test_helpers::add_commit_with_files(&fixture.path, &[], &[("a.txt", "A\n"), ("b.txt", "A-b\n")], "ancestor");
    let d = test_helpers::add_commit_with_files(
        &fixture.path,
        &[&a],
        &[("a.txt", "D\n"), ("b.txt", "D-b\n")],
        "destination",
    );
    // Only a.txt moves, so the destination ends up `{a: "A", b: "D-b"}`.
    let oracle =
        test_helpers::add_commit_with_files(&fixture.path, &[], &[("a.txt", "A\n"), ("b.txt", "D-b\n")], "oracle");
    let expected_tree = test_helpers::tree_hex(&fixture.path, &oracle);
    let a_change = change_id_for_commit(&fixture.path, &a);
    let d_change = change_id_for_commit(&fixture.path, &d);
    let handle = open_handle(&fixture.path).0;

    let req = restore_request_bytes(Some(&a_change), Some(&d_change), None, &["a.txt"], false);
    let token = unsafe { zanshin_restore(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    assert!(parse_envelope(&bytes).ok(), "restore must succeed");

    assert_eq!(tree_hex_of_change(&fixture.path, &d_change), expected_tree);

    close_handle(handle);
    drop(fixture);
}

/// `restore_descendants` must actually reach `zanshin_jj::Repo::restore`: with the field
/// hardcoded to `false`, the descendant would be REBASED (its content re-derived) instead of
/// reparented (its content preserved verbatim).
#[test]
fn restore_with_restore_descendants_preserves_the_childs_own_tree() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let a = test_helpers::add_commit_with_files(&fixture.path, &[], &[("a.txt", "A\n")], "ancestor");
    let d = test_helpers::add_commit_with_files(&fixture.path, &[&a], &[("a.txt", "D\n")], "destination");
    // The child touches a DIFFERENT file, so a rebase would stay conflict-free and produce
    // `{a: "A", c: "C"}` — a tree distinguishable from the reparented one.
    let c = test_helpers::add_commit_with_files(&fixture.path, &[&d], &[("a.txt", "D\n"), ("c.txt", "C\n")], "child");
    let rebased_oracle = test_helpers::add_commit_with_files(
        &fixture.path,
        &[],
        &[("a.txt", "A\n"), ("c.txt", "C\n")],
        "oracle rebased child",
    );
    let c_tree_before = test_helpers::tree_hex(&fixture.path, &c);
    let c_tree_rebased = test_helpers::tree_hex(&fixture.path, &rebased_oracle);
    assert_ne!(
        c_tree_before, c_tree_rebased,
        "the two outcomes must differ, or this test proves nothing"
    );
    let a_change = change_id_for_commit(&fixture.path, &a);
    let d_change = change_id_for_commit(&fixture.path, &d);
    let c_change = change_id_for_commit(&fixture.path, &c);
    let handle = open_handle(&fixture.path).0;

    let req = restore_request_bytes(Some(&a_change), Some(&d_change), None, &[], true);
    let token = unsafe { zanshin_restore(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    assert!(parse_envelope(&bytes).ok(), "restore must succeed");

    assert_eq!(
        tree_hex_of_change(&fixture.path, &c_change),
        c_tree_before,
        "a reparented child keeps its own tree verbatim"
    );

    close_handle(handle);
    drop(fixture);
}

#[test]
fn restore_changes_in_combined_with_from_returns_jj_invalid_input() {
    test_helpers::pin_test_env();
    // SAFETY: handle is closed below, before `fixture` drops at end of scope.
    let (fixture, handle, a_change, b_change, _) = unsafe { open_content_fixture() };

    let req = restore_request_bytes(Some(&a_change), None, Some(&b_change), &[], false);
    let token = unsafe { zanshin_restore(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_INVALID_INPUT));

    close_handle(handle);
    drop(fixture);
}

#[test]
fn absorb_valid_round_trip_returns_ok_absorb_result() {
    test_helpers::pin_test_env();
    // SAFETY: handle is closed below, before `fixture` drops at end of scope.
    let (fixture, handle, a_change, _, s_change) = unsafe { open_content_fixture() };

    let req = absorb_request_bytes(Some(&s_change), None, &[]);
    let token = unsafe { zanshin_absorb(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(
        env.ok(),
        "absorb must succeed, error={:?}/{:?}",
        env.error().and_then(|e| e.code()),
        env.error().and_then(|e| e.context())
    );
    assert_eq!(env.data_type(), fbs::Payload::AbsorbResult);
    let ar = env.data_as_absorb_result().expect("data_as_absorb_result must succeed");
    let nested = ar.mutation().expect("the nested MutationResult must be present");
    assert!(nested.new_op_id().is_some_and(|s| !s.is_empty()));
    assert_eq!(
        ar.rewritten_change_ids().map(|v| v.iter().collect::<Vec<_>>()),
        Some(vec![a_change.as_str()]),
        "the hunk lands in the annotating ancestor"
    );
    assert!(ar.skipped_paths().is_some_and(|v| v.is_empty()));

    close_handle(handle);
    drop(fixture);
}

/// `paths` must actually reach `zanshin_jj::Repo::absorb`: with the field hardcoded to an
/// empty list, `b.txt`'s hunk would move into the ancestor too.
#[test]
fn absorb_with_a_path_filter_moves_only_the_matching_paths_hunks() {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let a =
        test_helpers::add_commit_with_files(&fixture.path, &[], &[("a.txt", "a1\n"), ("b.txt", "b1\n")], "ancestor");
    let s =
        test_helpers::add_commit_with_files(&fixture.path, &[&a], &[("a.txt", "a2\n"), ("b.txt", "b2\n")], "source");
    // Only a.txt's hunk moves, so the ancestor ends up `{a: "a2", b: "b1"}`.
    let oracle =
        test_helpers::add_commit_with_files(&fixture.path, &[], &[("a.txt", "a2\n"), ("b.txt", "b1\n")], "oracle");
    let expected_tree = test_helpers::tree_hex(&fixture.path, &oracle);
    let a_change = change_id_for_commit(&fixture.path, &a);
    let s_change = change_id_for_commit(&fixture.path, &s);
    let handle = open_handle(&fixture.path).0;

    let req = absorb_request_bytes(Some(&s_change), None, &["a.txt"]);
    let token = unsafe { zanshin_absorb(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);
    assert!(
        env.ok(),
        "absorb must succeed, error={:?}/{:?}",
        env.error().and_then(|e| e.code()),
        env.error().and_then(|e| e.context())
    );

    assert_eq!(tree_hex_of_change(&fixture.path, &a_change), expected_tree);

    close_handle(handle);
    drop(fixture);
}

#[test]
fn absorb_bogus_destination_revset_returns_jj_revset_parse_error() {
    test_helpers::pin_test_env();
    // SAFETY: handle is closed below, before `fixture` drops at end of scope.
    let (fixture, handle, _, _, s_change) = unsafe { open_content_fixture() };

    let req = absorb_request_bytes(Some(&s_change), Some("bogus_function()"), &[]);
    let token = unsafe { zanshin_absorb(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_REVSET_PARSE_ERROR));

    close_handle(handle);
    drop(fixture);
}

#[test]
fn absorb_unresolvable_destination_revset_returns_jj_revset_resolution_error() {
    test_helpers::pin_test_env();
    // SAFETY: handle is closed below, before `fixture` drops at end of scope.
    let (fixture, handle, _, _, s_change) = unsafe { open_content_fixture() };

    let req = absorb_request_bytes(Some(&s_change), Some("nonexistent-bookmark"), &[]);
    let token = unsafe { zanshin_absorb(handle, req.as_ptr(), req.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(JJ_REVSET_RESOLUTION_ERROR));

    close_handle(handle);
    drop(fixture);
}

#[test]
fn restore_null_request_buffer_returns_ffi_null_pointer() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let token = unsafe { zanshin_restore(handle, std::ptr::null(), 0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn absorb_null_request_buffer_returns_ffi_null_pointer() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let token = unsafe { zanshin_absorb(handle, std::ptr::null(), 0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn restore_garbage_bytes_returns_ffi_invalid_argument() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let garbage: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
    let token = unsafe { zanshin_restore(handle, garbage.as_ptr(), garbage.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));

    close_handle(handle);
}

#[test]
fn absorb_garbage_bytes_returns_ffi_invalid_argument() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let garbage: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
    let token = unsafe { zanshin_absorb(handle, garbage.as_ptr(), garbage.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));

    close_handle(handle);
}

// ── Cross-cutting edge cases ──────────────────────────────────────────────────

/// A nonexistent change id (mirrors `tests/it/change_ffi.rs`'s own `bad_id`).
/// NOT all-`z`: jj's reverse-hex root change id IS all-`z` (hex `0000…0000`), so
/// e.g. `"zzzzzzzz"` is a valid PREFIX of the (very much existing) root change —
/// it resolves and hits `jj.invalid_input` ("cannot describe/abandon the root
/// commit"), not `jj.change_not_found`. `jj.change_not_found` is documented on
/// `zanshin_describe`/`zanshin_new_change`/`zanshin_edit`/`zanshin_abandon`; this
/// table-style test exercises the mapping through each of the four real
/// `extern "C"` entry points (not just the standalone `map_mutate_err` unit test).
#[test]
fn every_wrapper_bogus_change_id_returns_jj_change_not_found() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };
    let bogus = "nonexistentchangeid";
    let bogus_cstr = cstr(bogus);
    let desc_cstr = cstr("desc");
    // Two buffers, not one: the shared `ChangeIdList` table carries a PER-WRAPPER tag, so the
    // same bytes can no longer serve both verbs.
    let new_change_req = change_id_list_bytes(fbs::RequestKind::NewChange, &[bogus]);
    let abandon_req = change_id_list_bytes(fbs::RequestKind::Abandon, &[bogus]);

    let describe_token = unsafe { zanshin_describe(handle, bogus_cstr.as_ptr(), desc_cstr.as_ptr()) };
    let describe_bytes = unsafe { read_and_free(describe_token) };
    assert_eq!(
        parse_envelope(&describe_bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "zanshin_describe with a bogus change id"
    );

    let new_change_token = unsafe { zanshin_new_change(handle, new_change_req.as_ptr(), new_change_req.len()) };
    let new_change_bytes = unsafe { read_and_free(new_change_token) };
    assert_eq!(
        parse_envelope(&new_change_bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "zanshin_new_change with a bogus parent id"
    );

    let edit_token = unsafe { zanshin_edit(handle, bogus_cstr.as_ptr()) };
    let edit_bytes = unsafe { read_and_free(edit_token) };
    assert_eq!(
        parse_envelope(&edit_bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "zanshin_edit with a bogus change id"
    );

    let abandon_token = unsafe { zanshin_abandon(handle, abandon_req.as_ptr(), abandon_req.len()) };
    let abandon_bytes = unsafe { read_and_free(abandon_token) };
    assert_eq!(
        parse_envelope(&abandon_bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "zanshin_abandon with a bogus change id"
    );

    let restore_req = restore_request_bytes(Some(bogus), None, None, &[], false);
    let restore_token = unsafe { zanshin_restore(handle, restore_req.as_ptr(), restore_req.len()) };
    let restore_bytes = unsafe { read_and_free(restore_token) };
    assert_eq!(
        parse_envelope(&restore_bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "zanshin_restore with a bogus source id"
    );

    let absorb_req = absorb_request_bytes(Some(bogus), None, &[]);
    let absorb_token = unsafe { zanshin_absorb(handle, absorb_req.as_ptr(), absorb_req.len()) };
    let absorb_bytes = unsafe { read_and_free(absorb_token) };
    assert_eq!(
        parse_envelope(&absorb_bytes).error().and_then(|e| e.code()),
        Some(JJ_CHANGE_NOT_FOUND),
        "zanshin_absorb with a bogus source id"
    );

    close_handle(handle);
}

#[test]
fn describe_null_change_id_returns_ffi_null_pointer() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let desc_cstr = cstr("desc");
    let token = unsafe { zanshin_describe(handle, std::ptr::null(), desc_cstr.as_ptr()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn describe_null_description_returns_ffi_null_pointer() {
    test_helpers::pin_test_env();
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    let change_cstr = cstr(&wc_change_id);
    let token = unsafe { zanshin_describe(handle, change_cstr.as_ptr(), std::ptr::null()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn edit_null_change_id_returns_ffi_null_pointer() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let token = unsafe { zanshin_edit(handle, std::ptr::null()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

/// A null request buffer is `ffi.null_pointer`; garbage and a buffer built for another verb are
/// `ffi.invalid_argument` (Story 9.30).
#[test]
fn git_fetch_null_or_invalid_request_buffer_is_refused() {
    test_helpers::pin_test_env();
    let dst = tempfile::TempDir::new().unwrap();
    let dst_cstr = cstr(dst.path().to_str().unwrap());
    let init_token = unsafe { repo_init(&dst_cstr, 1) };
    let init_bytes = unsafe { read_and_free(init_token) };
    let init_env = parse_envelope(&init_bytes);
    assert!(init_env.ok());
    let handle = init_env
        .data_as_repo_handle()
        .expect("RepoHandle must be present")
        .handle();

    let token = unsafe { zanshin_git_fetch(handle, std::ptr::null(), 0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    let garbage = git_fetch(handle, &[0xde, 0xad]);
    assert_eq!(
        parse_envelope(&garbage).error().and_then(|e| e.code()),
        Some(FFI_INVALID_ARGUMENT)
    );
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
    let other = fbs::GitFetchRequest::create(
        &mut b,
        &fbs::GitFetchRequestArgs {
            kind: fbs::RequestKind::GitPush,
            ..Default::default()
        },
    );
    b.finish(other, None);
    let wrong_kind = git_fetch(handle, b.finished_data());
    assert_eq!(
        parse_envelope(&wrong_kind).error().and_then(|e| e.code()),
        Some(FFI_INVALID_ARGUMENT)
    );

    close_handle(handle);
}

#[test]
fn new_change_null_request_buffer_returns_ffi_null_pointer() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let token = unsafe { zanshin_new_change(handle, std::ptr::null(), 0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn abandon_null_request_buffer_returns_ffi_null_pointer() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let token = unsafe { zanshin_abandon(handle, std::ptr::null(), 0) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_NULL_POINTER));

    close_handle(handle);
}

#[test]
fn new_change_garbage_bytes_returns_ffi_invalid_argument() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let garbage: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
    let token = unsafe { zanshin_new_change(handle, garbage.as_ptr(), garbage.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));

    close_handle(handle);
}

#[test]
fn abandon_garbage_bytes_returns_ffi_invalid_argument() {
    test_helpers::pin_test_env();
    let (handle, _) = unsafe { open_fixture_and_get_wc_change_id() };

    let garbage: [u8; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
    let token = unsafe { zanshin_abandon(handle, garbage.as_ptr(), garbage.len()) };
    let bytes = unsafe { read_and_free(token) };
    let env = parse_envelope(&bytes);

    assert!(!env.ok());
    assert_eq!(env.error().and_then(|e| e.code()), Some(FFI_INVALID_ARGUMENT));

    close_handle(handle);
}

/// Assert the whole `ffi.invalid_handle` refusal envelope: `ok:false`, the code,
/// and an ABSENT `context`.
///
/// The `context` half is what makes this a witness rather than a smoke check.
/// Since the 2026-09-05 closing dedupe all eight wrappers below borrow through
/// `envelope::session_from_handle`, whose refusal carries `context: None`; a
/// wrapper that started decorating that error would still satisfy a code-only
/// assertion.
fn assert_invalid_handle(bytes: &[u8]) {
    let env = parse_envelope(bytes);
    assert!(!env.ok(), "handle 0 must produce an error envelope");
    let err = env.error().expect("error field must be present");
    assert_eq!(err.code(), Some(FFI_INVALID_HANDLE));
    assert!(
        err.context().is_none(),
        "the invalid-handle envelope carries no context"
    );
}

#[test]
fn every_wrapper_zero_handle_returns_ffi_invalid_handle() {
    test_helpers::pin_test_env();
    let id_cstr = cstr("qpvuntsm");
    let desc_cstr = cstr("desc");
    // Each buffer carries its OWN wrapper's tag, so the kind rung passes and the handle rung —
    // now the FOURTH — is what refuses. A wrongly-tagged buffer would answer
    // `ffi.invalid_argument` here instead; that is asserted in
    // `every_wrapper_wrong_request_kind_is_refused_before_the_handle`.
    let new_change_req = change_id_list_bytes(fbs::RequestKind::NewChange, &["qpvuntsm"]);
    let abandon_req = change_id_list_bytes(fbs::RequestKind::Abandon, &["qpvuntsm"]);

    let describe_token = unsafe { zanshin_describe(0, id_cstr.as_ptr(), desc_cstr.as_ptr()) };
    let describe_bytes = unsafe { read_and_free(describe_token) };
    assert_invalid_handle(&describe_bytes);

    let new_change_token = unsafe { zanshin_new_change(0, new_change_req.as_ptr(), new_change_req.len()) };
    let new_change_bytes = unsafe { read_and_free(new_change_token) };
    assert_invalid_handle(&new_change_bytes);

    let edit_token = unsafe { zanshin_edit(0, id_cstr.as_ptr()) };
    let edit_bytes = unsafe { read_and_free(edit_token) };
    assert_invalid_handle(&edit_bytes);

    let abandon_token = unsafe { zanshin_abandon(0, abandon_req.as_ptr(), abandon_req.len()) };
    let abandon_bytes = unsafe { read_and_free(abandon_token) };
    assert_invalid_handle(&abandon_bytes);

    let undo_token = unsafe { zanshin_undo(0, false) };
    let undo_bytes = unsafe { read_and_free(undo_token) };
    assert_invalid_handle(&undo_bytes);

    let git_fetch_bytes = git_fetch(0, &fetch_request(None, 0));
    assert_invalid_handle(&git_fetch_bytes);

    let restore_req = restore_request_bytes(None, Some("qpvuntsm"), None, &[], false);
    let restore_token = unsafe { zanshin_restore(0, restore_req.as_ptr(), restore_req.len()) };
    let restore_bytes = unsafe { read_and_free(restore_token) };
    assert_invalid_handle(&restore_bytes);

    let absorb_req = absorb_request_bytes(None, None, &[]);
    let absorb_token = unsafe { zanshin_absorb(0, absorb_req.as_ptr(), absorb_req.len()) };
    let absorb_bytes = unsafe { read_and_free(absorb_token) };
    assert_invalid_handle(&absorb_bytes);
}

// ── Request-kind tag ──────────────────────────────────────────────────────────

/// The request-buffer wrapper shape, for the wrong-kind table below.
type BufWrapper = unsafe extern "C" fn(u64, *const u8, usize) -> *mut ZanshinBuf;

/// One row of the wrong-kind table: label, wrapper, buffer, expected kind, received kind, handle.
type KindCase<'a> = (&'a str, BufWrapper, &'a [u8], &'a str, &'a str, u64);

/// Every request-buffer wrapper in this file refuses a buffer built for a DIFFERENT verb, and
/// refuses an untagged one, naming both kinds in `context`.
///
/// The `NewChange` ↔ `Abandon` rows are the sharpest case the tag closes, and the only pair
/// that could not be closed by a per-TABLE tag: those two wrappers read the SAME `ChangeIdList`
/// table, as `parents` and as `change_ids`, so one shared variant would have left a mis-routed
/// buffer abandoning the commits the caller named as parents. They carry a full payload for
/// that reason. EVERY wrapper gets a `handle == 0` row, which is what proves the kind rung runs
/// BEFORE the handle lookup for that wrapper — a table witnessing the order for only some of
/// them would let the others silently regress.
#[test]
fn every_wrapper_refuses_a_buffer_built_for_another_verb() {
    test_helpers::pin_test_env();
    let (handle, wc_change_id) = unsafe { open_fixture_and_get_wc_change_id() };

    let new_change_req = change_id_list_bytes(fbs::RequestKind::NewChange, &[&wc_change_id]);
    let abandon_req = change_id_list_bytes(fbs::RequestKind::Abandon, &[&wc_change_id]);
    // Two untagged shapes: the `ChangeIdList` one carries a real payload (the two wrappers that
    // read that table accept its shape), the minimal one is what verifies as every table.
    let untagged_list = change_id_list_bytes(fbs::RequestKind::Unspecified, &[&wc_change_id]);
    let untagged = tagged_request_bytes(fbs::RequestKind::Unspecified);
    let restore_req = tagged_request_bytes(fbs::RequestKind::Restore);
    let absorb_req = tagged_request_bytes(fbs::RequestKind::Absorb);

    let cases: [KindCase<'_>; 12] = [
        (
            "new_change",
            zanshin_new_change,
            &abandon_req,
            "NewChange",
            "Abandon",
            handle,
        ),
        (
            "abandon",
            zanshin_abandon,
            &new_change_req,
            "Abandon",
            "NewChange",
            handle,
        ),
        ("restore", zanshin_restore, &absorb_req, "Restore", "Absorb", handle),
        ("absorb", zanshin_absorb, &restore_req, "Absorb", "Restore", handle),
        (
            "new_change",
            zanshin_new_change,
            &untagged_list,
            "NewChange",
            "Unspecified",
            handle,
        ),
        (
            "abandon",
            zanshin_abandon,
            &untagged_list,
            "Abandon",
            "Unspecified",
            handle,
        ),
        ("restore", zanshin_restore, &untagged, "Restore", "Unspecified", handle),
        ("absorb", zanshin_absorb, &untagged, "Absorb", "Unspecified", handle),
        (
            "new_change",
            zanshin_new_change,
            &abandon_req,
            "NewChange",
            "Abandon",
            0,
        ),
        ("abandon", zanshin_abandon, &new_change_req, "Abandon", "NewChange", 0),
        ("restore", zanshin_restore, &absorb_req, "Restore", "Absorb", 0),
        ("absorb", zanshin_absorb, &restore_req, "Absorb", "Restore", 0),
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

/// `zanshin_repo_init` over a `RepoInitRequest` (Story 9.20): `backend` 0 = native, 1 = git — a git
/// one with `no_colocate`, the internal workspace these rows were written against.
unsafe fn repo_init(path: &std::ffi::CString, backend: i32) -> *mut zanshin_ffi::ffi_strings::ZanshinBuf {
    let mut b = flatbuffers::FlatBufferBuilder::new();
    let path = b.create_string(path.to_str().expect("UTF-8 path"));
    let req = zanshin_ffi::fbs::RepoInitRequest::create(
        &mut b,
        &zanshin_ffi::fbs::RepoInitRequestArgs {
            kind: zanshin_ffi::fbs::RequestKind::RepoInit,
            path: Some(path),
            backend: zanshin_ffi::fbs::InitBackend(u8::try_from(backend).expect("a backend byte")),
            colocate: false,
            no_colocate: backend == 1,
            object_hash: zanshin_ffi::fbs::ObjectHash::Unspecified,
        },
    );
    b.finish(req, None);
    let bytes = b.finished_data();
    // SAFETY: `bytes` is a live, caller-owned request buffer for the duration of the call.
    unsafe { zanshin_ffi::repo::zanshin_repo_init(bytes.as_ptr(), bytes.len()) }
}
