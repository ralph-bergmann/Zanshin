// SPDX-License-Identifier: MIT

//! Integration test for Story 5.5's `Diff` payload: `Repo::diff`'s output on a real repo (Story
//! 5.6), serialised by `zanshin_ffi::diff::diff_to_envelope` and read back through the generated
//! accessors and the Verifier, carries exactly its section keys, flags, lines, kinds, counts,
//! fingerprints and pins — and its keys are `compute_hunks`' for the same trees (the wire half of
//! deferred items I1/I2). The repo is built in-test: `A` holds `f.txt` = `a b c d e`, `@` on it
//! `A b C d E` (three sections), an added `new.txt`, `run.sh` made executable (mode only) and
//! `bin.dat` changed binary content.
//!
//! Story 5.8: `zanshin_diff` on a real handle carries exactly what `Repo::diff` returns for the
//! same options, every request field reaching its option, and refuses what the CLI refuses.

use std::ffi::CString;
use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::PathBuf;

use flatbuffers::root as fb_root;
use zanshin_ffi::diff::{diff_to_envelope, zanshin_diff};
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::{
    fbs, CallReport, FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_INVALID_INPUT, JJ_PATHS_UNMATCHED,
    JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
};
use zanshin_jj::{
    Backend, ChangeKind, DiffOptions, DiffRevisions, FileDiff, HunkKey, HunkLine, HunksOptions, Repo, RevisionDiff,
    SelectedTreeId, Whitespace,
};

/// `Repo::diff` of `@` and `compute_hunks` between `@`'s parent tree and its own tree, in a fresh
/// temp repo.
fn computed() -> (RevisionDiff, Vec<FileDiff>) {
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
    fs::write(root.join("f.txt"), "a\nb\nc\nd\ne\n").expect("write");
    fs::write(root.join("run.sh"), "echo\n").expect("write");
    fs::write(root.join("bin.dat"), b"a\0b").expect("write");
    let a = repo.status().expect("status").working_copy_change_id.expect("@");
    repo.describe(a.clone(), "A\n").expect("describe");
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    fs::write(root.join("f.txt"), "A\nb\nC\nd\nE\n").expect("write");
    fs::write(root.join("new.txt"), "n\n").expect("write");
    fs::set_permissions(root.join("run.sh"), fs::Permissions::from_mode(0o755)).expect("chmod");
    fs::write(root.join("bin.dat"), b"a\0c").expect("write");
    let diff = repo.diff(&DiffOptions::default()).expect("diff");
    let shown = repo.show(None, None).expect("show").swap_remove(0);
    let hunks = repo
        .compute_hunks(&HunksOptions {
            from: SelectedTreeId {
                tree_ids: shown.parent_tree_ids,
                labels: shown.parent_tree_labels,
            },
            to: SelectedTreeId {
                tree_ids: shown.tree_ids,
                labels: shown.tree_labels,
            },
            context: None,
            whitespace: Whitespace::Exact,
        })
        .expect("compute_hunks");
    (diff, hunks)
}

fn keys(wire: Option<flatbuffers::Vector<'_, flatbuffers::ForwardsUOffset<fbs::HunkKey<'_>>>>) -> Vec<HunkKey> {
    wire.expect("sections always present")
        .iter()
        .map(|k| HunkKey {
            old_start: k.old_start(),
            old_count: k.old_count(),
            new_start: k.new_start(),
            new_count: k.new_count(),
        })
        .collect()
}

fn kind_and_text(line: &HunkLine) -> (fbs::HunkLineKind, Option<&str>) {
    match line {
        HunkLine::Context(t) => (fbs::HunkLineKind::Context, Some(t)),
        HunkLine::Removed(t) => (fbs::HunkLineKind::Removed, Some(t)),
        HunkLine::Added(t) => (fbs::HunkLineKind::Added, Some(t)),
    }
}

#[test]
fn the_wire_carries_the_diff_keys_flags_lines_and_pins() {
    let (diff, hunks) = computed();
    let files = &diff.files;
    assert_eq!(files, &hunks, "the revision diff is compute_hunks' for the same trees");
    assert!(files.iter().any(|f| f.path == "f.txt" && f.sections.len() == 3));
    let file = |path: &str| files.iter().find(|f| f.path == path).expect("file present");
    let (run, bin) = (file("run.sh"), file("bin.dat"));
    assert!(run.mode_change && !run.binary && run.hunks.is_empty());
    assert!(bin.binary && !bin.mode_change && bin.hunks.is_empty());
    assert_eq!(file("new.txt").kind, ChangeKind::Added);

    let bytes = diff_to_envelope(&diff, &CallReport::default());
    let env = fb_root::<fbs::Envelope>(&bytes).expect("FlatBuffers Verifier must pass");
    assert!(env.ok());
    assert_wire_is(env.data_as_diff().expect("Diff payload"), &diff);
}

/// The wire `payload` carries exactly `diff`'s pins and files (kinds Added / Modified only).
fn assert_wire_is(payload: fbs::Diff<'_>, diff: &RevisionDiff) {
    let files = &diff.files;
    assert_eq!(payload.operation_id(), Some(diff.operation_id.0.as_str()));
    let commit_ids: Vec<&str> = payload.commit_ids().expect("commit_ids present").iter().collect();
    let expected: Vec<&str> = diff.commit_ids.iter().map(|id| id.0.as_str()).collect();
    assert_eq!(commit_ids, expected);
    assert_eq!(
        payload.from_commit_id(),
        diff.from_commit_id.as_ref().map(|id| id.0.as_str())
    );
    let wire = payload.files().expect("files present");
    assert_eq!(wire.len(), files.len());
    for (w, f) in wire.iter().zip(files) {
        assert_eq!(w.path(), Some(f.path.as_str()));
        assert_eq!((w.binary(), w.mode_change()), (f.binary, f.mode_change));
        assert_eq!(keys(w.sections()), f.sections);
        let kind = if f.kind == ChangeKind::Added {
            fbs::ChangeKind::Added
        } else {
            fbs::ChangeKind::Modified
        };
        assert_eq!((w.kind(), w.from_path()), (kind, None));
        assert_eq!((w.removed(), w.added()), (f.removed, f.added));
        assert_eq!(w.fingerprint(), Some(f.fingerprint.as_str()));
        let hunks = w.hunks().expect("hunks present");
        assert_eq!(hunks.len(), f.hunks.len());
        for (wh, h) in hunks.iter().zip(&f.hunks) {
            assert_eq!(keys(wh.sections()), h.sections);
            assert_eq!(wh.symbol(), h.symbol.as_deref());
            assert_eq!((wh.removed(), wh.added()), (h.removed, h.added));
            assert_eq!(wh.before_start()..wh.before_end(), h.before_range);
            assert_eq!(wh.after_start()..wh.after_end(), h.after_range);
            let lines: Vec<_> = wh
                .lines()
                .expect("lines present")
                .iter()
                .map(|l| (l.kind(), l.text()))
                .collect();
            let expected: Vec<_> = h.lines.iter().map(kind_and_text).collect();
            assert_eq!(lines, expected);
        }
    }
}

// ── `zanshin_diff` (Story 5.8) ───────────────────────────────────────────────────

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

fn error_code(bytes: &[u8]) -> Option<&str> {
    parse_envelope(bytes).error().and_then(|e| e.code())
}

/// A repo whose `A` holds `f.txt` = `a b c d e` and `w.txt` = `x y`, `C` on it `A b C d E` and
/// `x  y` (whitespace only), and an empty `@` on `C`; an open handle on it.
struct Fx {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    handle: u64,
    a: String,
    c: String,
}

impl Drop for Fx {
    fn drop(&mut self) {
        // SAFETY: the handle came from `zanshin_repo_open` below and is closed exactly once.
        let bytes = unsafe { read_and_free(zanshin_repo_close(self.handle)) };
        assert!(parse_envelope(&bytes).ok());
    }
}

fn fixture() -> Fx {
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
    let mut commit = |f: &str, w: &str, message: &str| {
        fs::write(root.join("f.txt"), f).expect("write");
        fs::write(root.join("w.txt"), w).expect("write");
        let id = repo.status().expect("status").working_copy_change_id.expect("@");
        repo.describe(id.clone(), message).expect("describe");
        repo.new_change(std::slice::from_ref(&id), &[], &[]).expect("new");
        id.0
    };
    let a = commit("a\nb\nc\nd\ne\n", "x y\n", "A\n");
    let c = commit("A\nb\nC\nd\nE\n", "x  y\n", "C\n");
    repo.status().expect("status");
    drop(repo);
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
        a,
        c,
    }
}

/// One `DiffRequest`'s fields.
#[derive(Clone, Copy)]
struct Req<'a> {
    kind: fbs::RequestKind,
    revision: Option<&'a str>,
    from: Option<&'a str>,
    to: Option<&'a str>,
    paths: &'a [&'a str],
    context: Option<u32>,
    whitespace: fbs::DiffWhitespace,
    summary: bool,
}

impl Default for Req<'_> {
    fn default() -> Self {
        Self {
            kind: fbs::RequestKind::Diff,
            revision: None,
            from: None,
            to: None,
            paths: &[],
            context: None,
            whitespace: fbs::DiffWhitespace::Exact,
            summary: false,
        }
    }
}

fn request(r: Req<'_>) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
    let paths: Vec<_> = r.paths.iter().map(|p| b.create_string(p)).collect();
    let paths = b.create_vector(&paths);
    let revision = r.revision.map(|s| b.create_string(s));
    let from = r.from.map(|s| b.create_string(s));
    let to = r.to.map(|s| b.create_string(s));
    let context = r.context.map(fbs::DiffContext::new);
    let req = fbs::DiffRequest::create(
        &mut b,
        &fbs::DiffRequestArgs {
            kind: r.kind,
            revision,
            from,
            to,
            paths: Some(paths),
            context: context.as_ref(),
            whitespace: r.whitespace,
            summary: r.summary,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

fn call(handle: u64, r: Req<'_>) -> Vec<u8> {
    let req = request(r);
    // SAFETY: `handle` is open or 0 (refused); `req` is a live buffer for the call.
    unsafe { read_and_free(zanshin_diff(handle, req.as_ptr(), req.len())) }
}

/// `zanshin_diff` of `r` succeeds with a precondition report and carries exactly what
/// `Repo::diff(options)` returns; returns that diff.
fn assert_matches_repo_diff(fx: &Fx, r: Req<'_>, options: &DiffOptions) -> RevisionDiff {
    let bytes = call(fx.handle, r);
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    assert!(env.precondition().is_some(), "the pre-verb snapshot ran");
    let expected = Repo::open(&fx.root).expect("open").diff(options).expect("diff");
    assert_wire_is(env.data_as_diff().expect("Diff payload"), &expected);
    expected
}

fn id(s: &str) -> String {
    s.to_owned()
}

#[test]
fn an_empty_request_diffs_the_working_copy() {
    let fx = fixture();
    let diff = assert_matches_repo_diff(&fx, Req::default(), &DiffOptions::default());
    assert!(diff.files.is_empty(), "@ is empty");
}

#[test]
fn a_revision_and_from_to_reach_the_diff() {
    let fx = fixture();
    let revision = assert_matches_repo_diff(
        &fx,
        Req {
            revision: Some(&fx.c),
            ..Req::default()
        },
        &DiffOptions {
            revisions: DiffRevisions::Revision(Some(id(&fx.c))),
            ..DiffOptions::default()
        },
    );
    let f = revision.files.iter().find(|f| f.path == "f.txt").expect("f.txt");
    assert_eq!(f.sections.len(), 3);
    assert!(revision.from_commit_id.is_none());

    let from_to = assert_matches_repo_diff(
        &fx,
        Req {
            from: Some(&fx.a),
            to: Some(&fx.c),
            ..Req::default()
        },
        &DiffOptions {
            revisions: DiffRevisions::FromTo {
                from: Some(id(&fx.a)),
                to: Some(id(&fx.c)),
            },
            ..DiffOptions::default()
        },
    );
    assert!(from_to.from_commit_id.is_some());
    assert_eq!(from_to.commit_ids, revision.commit_ids, "to = C");

    let to_only = assert_matches_repo_diff(
        &fx,
        Req {
            to: Some(&fx.c),
            ..Req::default()
        },
        &DiffOptions {
            revisions: DiffRevisions::FromTo {
                from: None,
                to: Some(id(&fx.c)),
            },
            ..DiffOptions::default()
        },
    );
    assert_ne!(to_only.from_commit_id, from_to.from_commit_id, "from = @, not A");
}

#[test]
fn paths_context_whitespace_and_summary_reach_the_diff() {
    let fx = fixture();
    let rev = |options: DiffOptions| DiffOptions {
        revisions: DiffRevisions::Revision(Some(id(&fx.c))),
        ..options
    };
    let base = Req {
        revision: Some(&fx.c),
        ..Req::default()
    };
    let only_f = assert_matches_repo_diff(
        &fx,
        Req {
            paths: &["f.txt"],
            context: Some(0),
            ..base
        },
        &rev(DiffOptions {
            paths: vec!["f.txt".into()],
            context: Some(0),
            ..DiffOptions::default()
        }),
    );
    assert_eq!(only_f.files.len(), 1);
    assert!(only_f.files[0]
        .hunks
        .iter()
        .flat_map(|h| &h.lines)
        .all(|l| !matches!(l, HunkLine::Context(_))));

    let ignore_space = assert_matches_repo_diff(
        &fx,
        Req {
            whitespace: fbs::DiffWhitespace::IgnoreAllSpace,
            ..base
        },
        &rev(DiffOptions {
            whitespace: Whitespace::IgnoreAllSpace,
            ..DiffOptions::default()
        }),
    );
    let w = |diff: &RevisionDiff| diff.files.iter().find(|f| f.path == "w.txt").map(|f| f.hunks.len());
    let exact = assert_matches_repo_diff(&fx, base, &rev(DiffOptions::default()));
    assert_eq!(w(&exact), Some(1), "Exact shows the whitespace-only change");
    assert_eq!(w(&ignore_space), Some(0), "-w hides it; the file stays listed");

    let summary = assert_matches_repo_diff(
        &fx,
        Req { summary: true, ..base },
        &rev(DiffOptions {
            summary: true,
            ..DiffOptions::default()
        }),
    );
    assert!(!summary.files.is_empty() && summary.files.iter().all(|f| f.hunks.is_empty()));
}

#[test]
fn an_unmatched_path_is_a_warning() {
    let fx = fixture();
    let bytes = call(
        fx.handle,
        Req {
            revision: Some(&fx.c),
            paths: &["nope"],
            ..Req::default()
        },
    );
    let env = parse_envelope(&bytes);
    assert!(env.ok(), "{:?}", error_code(&bytes));
    assert!(env.data_as_diff().and_then(|d| d.files()).expect("files").is_empty());
    let warnings: Vec<_> = env.warnings().expect("warnings").iter().map(|w| w.code()).collect();
    assert_eq!(warnings, [Some(JJ_PATHS_UNMATCHED)]);
}

#[test]
fn a_conflict_bad_input_and_an_unknown_revision_are_refused() {
    let fx = fixture();
    let bytes = call(
        fx.handle,
        Req {
            revision: Some(&fx.c),
            from: Some(&fx.a),
            ..Req::default()
        },
    );
    assert_eq!(error_code(&bytes), Some(JJ_INVALID_INPUT));
    assert!(
        parse_envelope(&bytes).precondition().is_none(),
        "refused before the snapshot"
    );

    // Not `z…`: the root's change id is all `z`.
    let unknown = "q".repeat(32);
    let bytes = call(
        fx.handle,
        Req {
            revision: Some(&unknown),
            ..Req::default()
        },
    );
    assert_eq!(error_code(&bytes), Some(JJ_REVSET_RESOLUTION_ERROR));
    let bytes = call(
        fx.handle,
        Req {
            revision: Some("bogus("),
            ..Req::default()
        },
    );
    assert_eq!(error_code(&bytes), Some(JJ_REVSET_PARSE_ERROR));

    assert_eq!(error_code(&call(0, Req::default())), Some(FFI_INVALID_HANDLE));
    let wrong_kind = call(
        fx.handle,
        Req {
            kind: fbs::RequestKind::SelectTree,
            ..Req::default()
        },
    );
    assert_eq!(error_code(&wrong_kind), Some(FFI_INVALID_ARGUMENT));
    let junk = [0xffu8; 7];
    // SAFETY: the buffer is live for the call; a null pointer is the documented refusal.
    unsafe {
        assert_eq!(
            error_code(&read_and_free(zanshin_diff(fx.handle, std::ptr::null(), 0))),
            Some(FFI_NULL_POINTER)
        );
        assert_eq!(
            error_code(&read_and_free(zanshin_diff(fx.handle, junk.as_ptr(), junk.len()))),
            Some(FFI_INVALID_ARGUMENT)
        );
    }
}
