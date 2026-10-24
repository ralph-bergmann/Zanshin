// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.31's two wrappers: `zanshin_drop_actions` and
//! `zanshin_change_actions`.
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier;
//! every token is freed via `zanshin_buffer_free_token`. The repo is built in-test with
//! `zanshin_jj`'s own verbs: `A (a.txt) → B (b.txt) → C (c.txt, c2.txt) = @`, descriptions
//! `A\n`, `B\n`, `C\n`.

use std::ffi::CString;
use std::fs;
use std::path::{Path, PathBuf};

use flatbuffers::root as fb_root;
use zanshin_ffi::drop_actions::{zanshin_change_actions, zanshin_drop_actions};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CHANGE_NOT_FOUND, JJ_IMMUTABLE, JJ_INVALID_INPUT,
};
use zanshin_jj::{Backend, Repo};

use fbs::ActionStatus as S;
use fbs::DropVerb as V;

const UNKNOWN: &str = "qpvuntsmwlqtpvuntsmwlqtpvuntsm";

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

fn error(bytes: &[u8]) -> (Option<String>, Option<String>) {
    let error = parse_envelope(bytes).error();
    (
        error.and_then(|e| e.code()).map(ToOwned::to_owned),
        error.and_then(|e| e.context()).map(ToOwned::to_owned),
    )
}

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
        path: main,
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
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
        let at = repo.status().expect("status").working_copy_change_id.expect("@");
        repo.describe(at.clone(), description).expect("describe");
        ids.push(at);
    }
    repo.bookmark_create(&["mark".to_owned()], Some(&ids[1]))
        .expect("bookmark");
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

fn head_op(root: &Path) -> String {
    Repo::open(root)
        .expect("open")
        .op_log(Some(1))
        .expect("op log")
        .swap_remove(0)
        .id
        .0
}

/// One location: `onto`, `insert_after`, `insert_before` (empty = not given).
type Loc<'a> = (&'a [&'a str], &'a [&'a str], &'a [&'a str]);

/// The request's source, as the wire spells it.
enum Source<'a> {
    Change(&'a str),
    Selection(&'a str, &'a [&'a str]),
    Bookmark(&'a str),
    /// Only a kind: the field it needs is absent.
    Bare(fbs::DropSourceKind),
}

fn strings<'a>(
    b: &mut flatbuffers::FlatBufferBuilder<'a>,
    items: &[&str],
) -> flatbuffers::WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<&'a str>>> {
    let offsets: Vec<_> = items.iter().map(|s| b.create_string(s)).collect();
    b.create_vector(&offsets)
}

fn request(kind: fbs::RequestKind, source: &Source<'_>, locations: &[Loc<'_>]) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let location_offsets: Vec<_> = locations
        .iter()
        .map(|(onto, after, before)| {
            let onto = strings(&mut b, onto);
            let insert_after = strings(&mut b, after);
            let insert_before = strings(&mut b, before);
            fbs::DropLocation::create(
                &mut b,
                &fbs::DropLocationArgs {
                    onto: Some(onto),
                    insert_after: Some(insert_after),
                    insert_before: Some(insert_before),
                },
            )
        })
        .collect();
    let locations = b.create_vector(&location_offsets);
    let (source_kind, change_id, paths, bookmark) = match source {
        Source::Change(id) => (fbs::DropSourceKind::Change, Some(b.create_string(id)), None, None),
        Source::Selection(id, paths) => {
            let id = b.create_string(id);
            let paths = strings(&mut b, paths);
            (fbs::DropSourceKind::Selection, Some(id), Some(paths), None)
        }
        Source::Bookmark(name) => (fbs::DropSourceKind::Bookmark, None, None, Some(b.create_string(name))),
        Source::Bare(kind) => (*kind, None, None, None),
    };
    let req = fbs::DropActionsRequest::create(
        &mut b,
        &fbs::DropActionsRequestArgs {
            kind,
            source_kind,
            change_id,
            paths,
            bookmark,
            locations: Some(locations),
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn call(handle: u64, req: &[u8]) -> Vec<u8> {
    // SAFETY: `req` is a live buffer for the call; a stale handle is never passed.
    unsafe { read_and_free(zanshin_drop_actions(handle, req.as_ptr(), req.len())) }
}

/// A decoded row: verb, location, status, refusal code and context, the two flags.
type Row = (
    fbs::DropVerb,
    u32,
    fbs::ActionStatus,
    Option<String>,
    Option<String>,
    bool,
    bool,
);

/// A decoded outcome: status, refusal code and context, the two flags.
type Outcome = (fbs::ActionStatus, Option<String>, Option<String>, bool, bool);

fn outcome_parts(o: &fbs::ActionOutcome<'_>) -> Outcome {
    (
        o.status(),
        o.refusal().and_then(|e| e.code()).map(ToOwned::to_owned),
        o.refusal().and_then(|e| e.context()).map(ToOwned::to_owned),
        o.combined_description_needed(),
        o.allow_backwards_needed(),
    )
}

fn rows(bytes: &[u8]) -> Vec<Row> {
    let env = parse_envelope(bytes);
    assert!(env.ok(), "{:?}", error(bytes));
    let actions = env.data_as_drop_actions().expect("DropActions payload");
    actions
        .actions()
        .expect("actions")
        .iter()
        .map(|a| {
            let (status, code, context, combined, backwards) = outcome_parts(&a.outcome().expect("outcome"));
            (a.verb(), a.location(), status, code, context, combined, backwards)
        })
        .collect()
}

fn ok(verb: fbs::DropVerb, location: u32, status: fbs::ActionStatus) -> Row {
    (verb, location, status, None, None, false, false)
}

#[test]
fn drop_actions_round_trips_every_row_and_writes_nothing() {
    let fx = base();
    let before = head_op(&fx.root);
    let c_onto_c = Repo::open(&fx.root)
        .expect("open")
        .get_change(&zanshin_jj::ChangeId(fx.c.clone()))
        .expect("C")
        .commit_id
        .0[..12]
        .to_owned();

    let req = request(
        fbs::RequestKind::DropActions,
        &Source::Change(&fx.c),
        &[(&[&fx.b], &[], &[]), (&[&fx.c], &[], &[]), (&[], &[&fx.a], &[])],
    );
    let rows = rows(&call(fx.handle, &req));
    let itself = Some(format!("Cannot rebase {c_onto_c} onto itself"));
    assert_eq!(
        rows,
        vec![
            ok(V::RebaseSource, 0, S::NoOp),
            ok(V::RebaseRevisions, 0, S::NoOp),
            (V::Squash, 0, S::Available, None, None, true, false),
            ok(V::NewMerge, 0, S::Available),
            ok(V::Duplicate, 0, S::Available),
            // The Story 9.31 follow-on's rows: C already sits on B; it only adds files.
            ok(V::RebaseBranch, 0, S::NoOp),
            ok(V::Revert, 0, S::Available),
            ok(V::Restore, 0, S::Available),
            ok(V::Absorb, 0, S::NoOp),
            ok(V::Interdiff, 0, S::Available),
            (
                V::RebaseSource,
                1,
                S::Refused,
                Some(JJ_INVALID_INPUT.to_owned()),
                itself.clone(),
                false,
                false
            ),
            (
                V::RebaseRevisions,
                1,
                S::Refused,
                Some(JJ_INVALID_INPUT.to_owned()),
                itself,
                false,
                false
            ),
            ok(V::Squash, 1, S::NoOp),
            ok(V::NewMerge, 1, S::Available),
            ok(V::Duplicate, 1, S::Available),
            ok(V::RebaseBranch, 1, S::NoOp),
            ok(V::Revert, 1, S::Available),
            ok(V::Restore, 1, S::NoOp),
            ok(V::Absorb, 1, S::NoOp),
            ok(V::Interdiff, 1, S::Available),
            ok(V::RebaseRevisions, 2, S::Available),
            ok(V::Revert, 2, S::Available),
        ]
    );
    assert_eq!(head_op(&fx.root), before, "the query writes no operation");
}

#[test]
fn selection_and_bookmark_sources_round_trip() {
    let fx = base();
    let req = request(
        fbs::RequestKind::DropActions,
        &Source::Selection(&fx.c, &["c.txt"]),
        &[(&[&fx.b], &[], &[]), (&[], &[&fx.a], &[])],
    );
    assert_eq!(
        rows(&call(fx.handle, &req)),
        vec![ok(V::Squash, 0, S::Available), ok(V::Split, 1, S::Available)]
    );
    let req = request(
        fbs::RequestKind::DropActions,
        &Source::Bookmark("mark"),
        &[(&[&fx.c], &[], &[]), (&[&fx.a], &[], &[]), (&[&fx.b], &[], &[])],
    );
    assert_eq!(
        rows(&call(fx.handle, &req)),
        vec![
            ok(V::BookmarkMove, 0, S::Available),
            (V::BookmarkMove, 1, S::Available, None, None, false, true),
            ok(V::BookmarkMove, 2, S::NoOp),
        ]
    );
    // `-A root` is a gap above the root; `-B root` would rebase the immutable root: the two
    // lists answer differently, so a reader that swapped them fails here.
    let root = "z".repeat(32);
    let req = request(
        fbs::RequestKind::DropActions,
        &Source::Change(&fx.c),
        &[(&[], &[&root], &[]), (&[], &[], &[&root])],
    );
    let statuses: Vec<_> = rows(&call(fx.handle, &req))
        .into_iter()
        .map(|(verb, location, status, code, ..)| (verb, location, status, code))
        .collect();
    assert_eq!(
        statuses,
        vec![
            (V::RebaseRevisions, 0, S::Available, None),
            (V::Revert, 0, S::Available, None),
            (V::RebaseRevisions, 1, S::Refused, Some(JJ_IMMUTABLE.to_owned())),
            (V::Revert, 1, S::Refused, Some(JJ_IMMUTABLE.to_owned())),
        ]
    );
    let req = request(
        fbs::RequestKind::DropActions,
        &Source::Change(UNKNOWN),
        &[(&[], &[&fx.a], &[])],
    );
    let not_found = |verb| {
        (
            verb,
            0,
            S::Refused,
            Some(JJ_CHANGE_NOT_FOUND.to_owned()),
            Some(UNKNOWN.to_owned()),
            false,
            false,
        )
    };
    assert_eq!(
        rows(&call(fx.handle, &req)),
        vec![not_found(V::RebaseRevisions), not_found(V::Revert)]
    );
    // The interdiff row's refusal (a `CommitViewError` in the verb) crosses as the same code and
    // context as every other row's.
    let req = request(
        fbs::RequestKind::DropActions,
        &Source::Change(UNKNOWN),
        &[(&[&fx.a], &[], &[])],
    );
    let interdiff: Vec<_> = rows(&call(fx.handle, &req))
        .into_iter()
        .filter(|row| row.0 == V::Interdiff)
        .collect();
    assert_eq!(interdiff, vec![not_found(V::Interdiff)]);
}

#[test]
fn drop_actions_refuses_malformed_requests_before_the_handle() {
    let fx = base();
    let good = request(
        fbs::RequestKind::DropActions,
        &Source::Change(&fx.c),
        &[(&[&fx.b], &[], &[])],
    );

    // SAFETY: a null buffer is detected before any dereference.
    let bytes = unsafe { read_and_free(zanshin_drop_actions(fx.handle, std::ptr::null(), 0)) };
    assert_eq!(error(&bytes).0.as_deref(), Some(FFI_NULL_POINTER));

    let wrong_kind = request(
        fbs::RequestKind::Squash,
        &Source::Change(&fx.c),
        &[(&[&fx.b], &[], &[])],
    );
    assert_eq!(
        error(&call(fx.handle, &wrong_kind)).0.as_deref(),
        Some(FFI_INVALID_ARGUMENT)
    );
    let garbage = [1_u8, 2, 3];
    assert_eq!(
        error(&call(fx.handle, &garbage)).0.as_deref(),
        Some(FFI_INVALID_ARGUMENT)
    );
    let unknown_kind = request(
        fbs::RequestKind::DropActions,
        &Source::Bare(fbs::DropSourceKind(9)),
        &[],
    );
    assert_eq!(
        error(&call(fx.handle, &unknown_kind)).0.as_deref(),
        Some(FFI_INVALID_ARGUMENT)
    );
    for (kind, field) in [
        (fbs::DropSourceKind::Change, "change_id"),
        (fbs::DropSourceKind::Selection, "change_id"),
        (fbs::DropSourceKind::Bookmark, "bookmark"),
    ] {
        let bare = request(fbs::RequestKind::DropActions, &Source::Bare(kind), &[]);
        assert_eq!(
            error(&call(fx.handle, &bare)),
            (Some(JJ_INVALID_INPUT.to_owned()), Some(format!("{field} is required")))
        );
    }

    assert_eq!(error(&call(0, &good)).0.as_deref(), Some(FFI_INVALID_HANDLE));
}

#[test]
fn a_malformed_location_fails_the_whole_call() {
    let fx = base();
    let req = request(
        fbs::RequestKind::DropActions,
        &Source::Change(&fx.c),
        &[(&[&fx.b], &[], &[]), (&[&fx.b], &[&fx.a], &[])],
    );
    assert_eq!(
        error(&call(fx.handle, &req)),
        (
            Some(JJ_INVALID_INPUT.to_owned()),
            Some("--onto cannot be combined with -A/--insert-after or -B/--insert-before".to_owned())
        )
    );
}

fn card(handle: u64, id: &str) -> Vec<u8> {
    let id = CString::new(id).expect("no NUL");
    // SAFETY: `id` is a valid NUL-terminated C string alive for the call.
    unsafe { read_and_free(zanshin_change_actions(handle, id.as_ptr())) }
}

fn card_rows(bytes: &[u8]) -> Vec<Outcome> {
    let env = parse_envelope(bytes);
    assert!(env.ok(), "{:?}", error(bytes));
    let actions = env.data_as_change_actions().expect("ChangeActions payload");
    [
        actions.new_onto(),
        actions.new_insert_after(),
        actions.new_insert_before(),
        actions.edit(),
        actions.describe(),
        actions.squash_into_parent(),
        actions.abandon(),
    ]
    .into_iter()
    .map(|o| outcome_parts(&o.expect("every outcome is present")))
    .collect()
}

#[test]
fn change_actions_round_trips_the_seven_rows() {
    let fx = base();
    let before = head_op(&fx.root);
    let available = (S::Available, None, None, false, false);
    assert_eq!(
        card_rows(&card(fx.handle, &fx.b)),
        vec![
            available.clone(),
            available.clone(),
            available.clone(),
            available.clone(),
            available.clone(),
            (S::Available, None, None, true, false),
            available,
        ]
    );
    let root = "z".repeat(32);
    let rows = card_rows(&card(fx.handle, &root));
    assert_eq!(rows[3].0, S::Refused);
    assert_eq!(rows[3].1.as_deref(), Some(JJ_IMMUTABLE));
    for row in card_rows(&card(fx.handle, UNKNOWN)) {
        assert_eq!(
            row,
            (
                S::Refused,
                Some(JJ_CHANGE_NOT_FOUND.to_owned()),
                Some(UNKNOWN.to_owned()),
                false,
                false
            )
        );
    }
    assert_eq!(head_op(&fx.root), before, "the query writes no operation");
}

#[test]
fn change_actions_refuses_a_null_id_and_a_null_handle() {
    let fx = base();
    // SAFETY: a null id is detected before any dereference.
    let bytes = unsafe { read_and_free(zanshin_change_actions(fx.handle, std::ptr::null())) };
    assert_eq!(error(&bytes).0.as_deref(), Some(FFI_NULL_POINTER));
    assert_eq!(error(&card(0, &fx.b)).0.as_deref(), Some(FFI_INVALID_HANDLE));
}
