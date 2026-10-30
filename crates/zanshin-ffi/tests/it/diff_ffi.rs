// SPDX-License-Identifier: MIT

//! Integration test for Story 5.5's `Diff` payload: `compute_hunks`' output on a real repo,
//! serialised by `zanshin_ffi::diff::diff_to_envelope` and read back through the generated
//! accessors and the Verifier, carries exactly its section keys, flags and lines (the wire half
//! of deferred items I1/I2). The repo is built in-test: `A` holds `f.txt` = `a b c d e`, `@` on
//! it `A b C d E` (three sections), an added `new.txt`, `run.sh` made executable (mode only) and
//! `bin.dat` changed binary content.

use std::fs;
use std::os::unix::fs::PermissionsExt as _;

use flatbuffers::root as fb_root;
use zanshin_ffi::diff::diff_to_envelope;
use zanshin_ffi::{fbs, CallReport};
use zanshin_jj::{Backend, FileDiff, HunkKey, HunkLine, HunksOptions, Repo, SelectedTreeId, Whitespace};

/// `compute_hunks` between `@`'s parent tree and its own tree, in a fresh temp repo.
fn computed_hunks() -> Vec<FileDiff> {
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
    let shown = repo.show(None, None).expect("show").swap_remove(0);
    repo.compute_hunks(&HunksOptions {
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
    .expect("compute_hunks")
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
fn the_wire_carries_compute_hunks_keys_flags_and_lines() {
    let files = computed_hunks();
    assert!(files.iter().any(|f| f.path == "f.txt" && f.sections.len() == 3));
    let file = |path: &str| files.iter().find(|f| f.path == path).expect("file present");
    let (run, bin) = (file("run.sh"), file("bin.dat"));
    assert!(run.mode_change && !run.binary && run.hunks.is_empty());
    assert!(bin.binary && !bin.mode_change && bin.hunks.is_empty());

    let bytes = diff_to_envelope(&files, &CallReport::default());
    let env = fb_root::<fbs::Envelope>(&bytes).expect("FlatBuffers Verifier must pass");
    assert!(env.ok());
    let wire = env
        .data_as_diff()
        .expect("Diff payload")
        .files()
        .expect("files present");
    assert_eq!(wire.len(), files.len());
    for (w, f) in wire.iter().zip(&files) {
        assert_eq!(w.path(), Some(f.path.as_str()));
        assert_eq!((w.binary(), w.mode_change()), (f.binary, f.mode_change));
        assert_eq!(keys(w.sections()), f.sections);
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
