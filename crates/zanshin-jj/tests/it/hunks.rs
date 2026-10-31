// SPDX-License-Identifier: MIT

//! Story 5.1 — `Repo::compute_hunks`, one witness per row of the I/O matrix, plus the round trip
//! of its section keys through `Repo::select_tree`.
//!
//! Every repo is built in-test with Zanshin's own verbs on a non-colocated internal-git repo: `A`
//! holds the left side of every kind of change, `@` (on `A`) the right side.

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{
    Backend, ChangeId, ChangeKind, FileChoice, FileDiff, FileSelection, HunkKey, HunkLine, HunksOptions, MutateError,
    Repo, SelectTreeOptions, SelectedTreeId, Whitespace,
};

/// The three sections of `f.txt`.
const S1: HunkKey = key(0, 1, 0, 1);
const S2: HunkKey = key(2, 1, 2, 1);
const S3: HunkKey = key(4, 1, 4, 1);

const fn key(old_start: u32, old_count: u32, new_start: u32, new_count: u32) -> HunkKey {
    HunkKey {
        old_start,
        old_count,
        new_start,
        new_count,
    }
}

struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    repo: Repo,
}

fn load_head(root: &Path) -> std::sync::Arc<jj_lib::repo::ReadonlyRepo> {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load workspace");
    pollster::block_on(workspace.repo_loader().load_at_head()).expect("load head")
}

fn head_op(root: &Path) -> String {
    load_head(root).op_id().hex()
}

/// `@`'s change id.
fn wc(root: &Path) -> ChangeId {
    let repo = load_head(root);
    let id = repo
        .view()
        .get_wc_commit_id(WorkspaceName::new("default"))
        .expect("workspace has an @");
    ChangeId(repo.store().get_commit(id).expect("@ commit").change_id().reverse_hex())
}

fn write(root: &Path, path: &str, content: &[u8]) {
    fs::write(root.join(path), content).expect("write");
}

fn set_executable(root: &Path, path: &str, executable: bool) {
    let mode = if executable { 0o755 } else { 0o644 };
    fs::set_permissions(root.join(path), fs::Permissions::from_mode(mode)).expect("chmod");
}

fn init() -> Fx {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
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
    let repo = Repo::open(&root).expect("open");
    Fx { _tmp: tmp, root, repo }
}

/// `A` = the left side of every change, `@` on `A` = the right side.
fn base() -> Fx {
    let mut fx = init();
    let root = fx.root.clone();
    write(&root, "f.txt", b"a\nb\nc\nd\ne\n");
    write(&root, "bin.dat", b"x\0y");
    write(&root, "mode.sh", b"m\n");
    set_executable(&root, "mode.sh", false);
    write(&root, "binmode.dat", b"x\0y");
    set_executable(&root, "binmode.dat", false);
    write(&root, "both.sh", b"m\n");
    set_executable(&root, "both.sh", false);
    write(&root, "gone.txt", b"g\n");
    write(&root, "eof.txt", b"a\nb");
    write(&root, "lib.rs", b"fn main() {\n    a();\n}\n");
    write(&root, "main.dart", b"fn main() {\n    a();\n}\n");
    write(&root, "ws.txt", b"a b\nc\n");
    write(&root, "space.txt", b"a b\n");
    write(&root, "same.txt", b"s\n");
    let a = wc(&root);
    fx.repo.describe(a.clone(), "A\n").expect("describe A");
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    write(&root, "f.txt", b"A\nb\nC\nd\nE\n");
    write(&root, "bin.dat", b"x\0z");
    set_executable(&root, "mode.sh", true);
    set_executable(&root, "binmode.dat", true);
    write(&root, "both.sh", b"n\n");
    set_executable(&root, "both.sh", true);
    fs::remove_file(root.join("gone.txt")).expect("rm");
    write(&root, "new.txt", b"n\n");
    write(&root, "eof.txt", b"a\nc");
    write(&root, "lib.rs", b"fn main() {\n    b();\n}\n");
    write(&root, "main.dart", b"fn main() {\n    b();\n}\n");
    write(&root, "ws.txt", b"a  b\nc\n");
    write(&root, "space.txt", b"ab\n");
    fx.repo.describe(wc(&root), "B\n").expect("describe @");
    let _ = fx.repo.take_warnings();
    fx
}

/// `@`'s parent tree and own tree, ids and labels, as `show` reports them.
fn trees(repo: &mut Repo) -> (SelectedTreeId, SelectedTreeId) {
    let mut entries = repo.show(None, None).expect("show");
    let entry = entries.remove(0);
    (
        SelectedTreeId {
            tree_ids: entry.parent_tree_ids,
            labels: entry.parent_tree_labels,
        },
        SelectedTreeId {
            tree_ids: entry.tree_ids,
            labels: entry.tree_labels,
        },
    )
}

fn diff(fx: &mut Fx, context: Option<usize>, whitespace: Whitespace) -> Vec<FileDiff> {
    let (from, to) = trees(&mut fx.repo);
    let diffs = fx
        .repo
        .compute_hunks(&HunksOptions {
            from,
            to,
            context,
            whitespace,
        })
        .expect("compute_hunks");
    assert_counts(&diffs);
    diffs
}

fn file<'a>(diffs: &'a [FileDiff], path: &str) -> &'a FileDiff {
    diffs
        .iter()
        .find(|file| file.path == path)
        .expect("the path is in the diff")
}

/// The file's only hunk.
fn only_hunk(file: &FileDiff) -> &zanshin_jj::Hunk {
    assert_eq!(file.hunks.len(), 1, "{file:?}");
    &file.hunks[0]
}

/// Every hunk's counts are its lines (the AC).
fn assert_counts(diffs: &[FileDiff]) {
    for hunk in diffs.iter().flat_map(|file| &file.hunks) {
        let removed = hunk
            .lines
            .iter()
            .filter(|line| matches!(line, HunkLine::Removed(_)))
            .count();
        let added = hunk
            .lines
            .iter()
            .filter(|line| matches!(line, HunkLine::Added(_)))
            .count();
        let context = hunk.lines.len() - removed - added;
        assert_eq!(hunk.removed as usize, removed, "{hunk:?}");
        assert_eq!(hunk.added as usize, added, "{hunk:?}");
        assert_eq!(hunk.before_range.len(), context + removed, "{hunk:?}");
        assert_eq!(hunk.after_range.len(), context + added, "{hunk:?}");
    }
}

/// Appends `toml` to the repo-level config.
fn add_repo_config(fx: &Fx, toml: &str) {
    let path = fx.root.join(".jj").join("repo").join("config.toml");
    let mut config = fs::read_to_string(&path).unwrap_or_default();
    config.push_str(toml);
    fs::write(path, config).expect("repo config");
}

/// Feeds every sectioned file's sections, and every mode toggle, to `select_tree` against `@`'s
/// parent tree; the selected tree must equal `@`'s tree at each of those files.
fn assert_sections_round_trip(fx: &mut Fx, diffs: &[FileDiff]) {
    let (from, to) = trees(&mut fx.repo);
    let files: Vec<FileSelection> = diffs
        .iter()
        .filter(|file| !file.sections.is_empty() || file.mode_change)
        .map(|file| FileSelection {
            path: file.path.clone(),
            choice: if file.mode_change {
                FileChoice::ModeAndHunks(file.sections.clone())
            } else {
                FileChoice::Hunks(file.sections.clone())
            },
        })
        .collect();
    assert!(!files.is_empty(), "nothing to round-trip");
    let selected = fx
        .repo
        .select_tree(&SelectTreeOptions {
            left: from.tree_ids,
            files: files.clone(),
            ..SelectTreeOptions::default()
        })
        .expect("select_tree takes every key compute_hunks shows");
    let rest = fx
        .repo
        .compute_hunks(&HunksOptions {
            from: selected,
            to,
            ..HunksOptions::default()
        })
        .expect("diff of the selection against @");
    for selection in &files {
        assert!(
            rest.iter().all(|file| file.path != selection.path),
            "{} differs from @ after selecting every section: {rest:?}",
            selection.path
        );
    }
}

/// Context 3 joins `f.txt`'s three sections into one hunk; the file lists them too, and the keys
/// round-trip through `select_tree`. Nothing enters the op log.
#[test]
fn three_sections_at_context_three_are_one_hunk_and_round_trip() {
    let mut fx = base();
    let head = head_op(&fx.root);
    let diffs = diff(&mut fx, None, Whitespace::Exact);
    assert_eq!(head_op(&fx.root), head, "no operation");
    let f = file(&diffs, "f.txt");
    assert_eq!(f.sections, [S1, S2, S3]);
    assert!(!f.binary && !f.mode_change);
    let hunk = only_hunk(f);
    assert_eq!((hunk.before_range.clone(), hunk.after_range.clone()), (0..5, 0..5));
    assert_eq!(hunk.sections, [S1, S2, S3]);
    assert_eq!((hunk.removed, hunk.added), (3, 3));
    assert_eq!(hunk.lines[0], HunkLine::Removed("a\n".to_owned()));
    assert_eq!(hunk.lines[1], HunkLine::Added("A\n".to_owned()));
    assert_eq!(hunk.lines[2], HunkLine::Context("b\n".to_owned()));
    // jj-lib's diff order; the unchanged file is not listed.
    let paths: Vec<&str> = diffs.iter().map(|file| file.path.as_str()).collect();
    assert_eq!(
        paths,
        [
            "bin.dat",
            "binmode.dat",
            "both.sh",
            "eof.txt",
            "f.txt",
            "gone.txt",
            "lib.rs",
            "main.dart",
            "mode.sh",
            "new.txt",
            "space.txt",
            "ws.txt"
        ]
    );
    assert_sections_round_trip(&mut fx, &diffs);
}

/// Context 0 gives one hunk per section; the file's sections stay the same.
#[test]
fn context_zero_gives_one_hunk_per_section() {
    let mut fx = base();
    let diffs = diff(&mut fx, Some(0), Whitespace::Exact);
    let f = file(&diffs, "f.txt");
    assert_eq!(f.sections, [S1, S2, S3]);
    let sections: Vec<Vec<HunkKey>> = f.hunks.iter().map(|hunk| hunk.sections.clone()).collect();
    assert_eq!(sections, [vec![S1], vec![S2], vec![S3]]);
}

/// An added file is all added lines, a removed one all removed; neither has sections.
#[test]
fn added_and_removed_files_have_no_sections() {
    let mut fx = base();
    let diffs = diff(&mut fx, None, Whitespace::Exact);
    let new = file(&diffs, "new.txt");
    assert!(new.sections.is_empty() && !new.mode_change && !new.binary);
    let hunk = only_hunk(new);
    assert_eq!((hunk.before_range.clone(), hunk.after_range.clone()), (0..0, 0..1));
    assert_eq!(hunk.lines, [HunkLine::Added("n\n".to_owned())]);
    assert!(hunk.sections.is_empty());

    let gone = file(&diffs, "gone.txt");
    assert!(gone.sections.is_empty() && !gone.mode_change);
    let hunk = only_hunk(gone);
    assert_eq!((hunk.before_range.clone(), hunk.after_range.clone()), (0..1, 0..0));
    assert_eq!(hunk.lines, [HunkLine::Removed("g\n".to_owned())]);

    // Story 5.6: kinds from presence (no copy records), counts the hunks' sums.
    assert_eq!(new.kind, ChangeKind::Added);
    assert_eq!(gone.kind, ChangeKind::Removed);
    assert_eq!((new.removed, new.added, gone.removed, gone.added), (0, 1, 1, 0));
    let f = file(&diffs, "f.txt");
    assert_eq!((f.kind.clone(), f.removed, f.added), (ChangeKind::Modified, 3, 3));
}

/// A mode-only change has no hunks and no sections, but the mode toggle, which round-trips
/// through `select_tree` (`ModeAndHunks(vec![])`) to `@`'s `mode.sh`. A mode change with a
/// content change round-trips with its sections (`ModeAndHunks([..])`).
#[test]
fn a_mode_only_change_has_the_toggle_and_no_hunks() {
    let mut fx = base();
    let diffs = diff(&mut fx, None, Whitespace::Exact);
    let mode = file(&diffs, "mode.sh");
    assert!(mode.mode_change && !mode.binary);
    assert!(mode.hunks.is_empty() && mode.sections.is_empty());
    assert_eq!((mode.removed, mode.added), (0, 0));
    // Two mode-only changes share the mode marker's fingerprint.
    assert_eq!(mode.fingerprint, file(&diffs, "binmode.dat").fingerprint);
    let both = file(&diffs, "both.sh");
    assert!(both.mode_change && both.sections == [key(0, 1, 0, 1)]);
    assert_sections_round_trip(&mut fx, &[mode.clone(), both.clone()]);
}

/// A mode-only change of a binary file is not binary: the CLI skips equal contents first.
#[test]
fn a_mode_only_change_of_a_binary_file_is_not_binary() {
    let mut fx = base();
    let diffs = diff(&mut fx, None, Whitespace::Exact);
    let binmode = file(&diffs, "binmode.dat");
    assert!(!binmode.binary && binmode.mode_change);
    assert!(binmode.hunks.is_empty() && binmode.sections.is_empty());
}

/// Binary content is marked and has no hunks.
#[test]
fn binary_content_is_marked_and_has_no_hunks() {
    let mut fx = base();
    let diffs = diff(&mut fx, None, Whitespace::Exact);
    let bin = file(&diffs, "bin.dat");
    assert!(bin.binary && !bin.mode_change);
    assert!(bin.hunks.is_empty() && bin.sections.is_empty());
    assert_eq!((bin.removed, bin.added), (0, 0));
    assert_ne!(bin.fingerprint, file(&diffs, "binmode.dat").fingerprint);
}

/// A last line without `\n` keeps that state on both sides.
#[test]
fn a_last_line_without_a_newline_keeps_it() {
    let mut fx = base();
    let diffs = diff(&mut fx, None, Whitespace::Exact);
    let eof = file(&diffs, "eof.txt");
    let lines = &eof.hunks[0].lines;
    assert_eq!(lines.last(), Some(&HunkLine::Added("c".to_owned())));
    assert!(lines.contains(&HunkLine::Removed("b".to_owned())));
    assert_eq!(eof.sections, [key(1, 1, 1, 1)]);
}

/// The source symbol is the CLI's for Rust and absent for Dart.
#[test]
fn rust_has_a_source_symbol_and_dart_none() {
    let mut fx = base();
    let diffs = diff(&mut fx, None, Whitespace::Exact);
    assert_eq!(file(&diffs, "lib.rs").hunks[0].symbol.as_deref(), Some("fn main() {"));
    assert_eq!(file(&diffs, "main.dart").hunks[0].symbol, None);
}

/// At `-w` / `-b` a whitespace-only change shows no hunk, though the file keeps its section.
#[test]
fn ignoring_whitespace_drops_the_hunk_but_keeps_the_section() {
    let mut fx = base();
    let exact = diff(&mut fx, None, Whitespace::Exact);
    assert_eq!(file(&exact, "ws.txt").hunks.len(), 1);
    for whitespace in [Whitespace::IgnoreAllSpace, Whitespace::IgnoreSpaceChange] {
        let diffs = diff(&mut fx, None, whitespace);
        let ws = file(&diffs, "ws.txt");
        assert!(ws.hunks.is_empty(), "{whitespace:?}: {ws:?}");
        assert_eq!(ws.sections, [key(0, 1, 0, 1)]);
        assert_eq!(file(&diffs, "f.txt").hunks.len(), 1);
    }
    // `a b` → `ab` removes whitespace: a change at `-b`, none at `-w`.
    let all = diff(&mut fx, None, Whitespace::IgnoreAllSpace);
    assert!(file(&all, "space.txt").hunks.is_empty());
    let amount = diff(&mut fx, None, Whitespace::IgnoreSpaceChange);
    assert_eq!(file(&amount, "space.txt").hunks.len(), 1);
}

/// The same tree twice is an empty diff.
#[test]
fn the_same_tree_twice_is_empty() {
    let mut fx = base();
    let (_, to) = trees(&mut fx.repo);
    let diffs = fx
        .repo
        .compute_hunks(&HunksOptions {
            from: to.clone(),
            to,
            ..HunksOptions::default()
        })
        .expect("compute_hunks");
    assert!(diffs.is_empty(), "{diffs:?}");
}

/// A merge of `X` / `Y` conflicted on `c.txt` and resolved in `@` (the merge itself): the
/// sections are cut over the merged parent tree's materialized markers — its labels included —
/// and feeding them to `select_tree` gives `@`'s `c.txt`, in the default and the `git` marker
/// style.
#[test]
fn a_conflicted_merge_parent_round_trips_through_select_tree() {
    conflicted_merge_round_trip(None);
    conflicted_merge_round_trip(Some("git"));
}

fn conflicted_merge_round_trip(marker_style: Option<&str>) {
    let mut fx = init();
    if let Some(style) = marker_style {
        add_repo_config(&fx, &format!("ui.conflict-marker-style = \"{style}\"\n"));
    }
    let root = fx.root.clone();
    write(&root, "c.txt", b"base\n");
    let a = wc(&root);
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new x");
    write(&root, "c.txt", b"x\n");
    let x = wc(&root);
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new y");
    write(&root, "c.txt", b"y\n");
    let y = wc(&root);
    fx.repo.new_change(&[x, y], &[], &[]).expect("merge");
    write(&root, "c.txt", b"x\ny\n");
    let _ = fx.repo.take_warnings();

    let (from, _) = trees(&mut fx.repo);
    assert_eq!(from.tree_ids.len(), 3, "a conflicted merged parent tree");
    assert_eq!(from.labels.len(), 3, "labelled per parent commit");
    let diffs = diff(&mut fx, None, Whitespace::Exact);
    let c = file(&diffs, "c.txt");
    assert!(!c.sections.is_empty(), "{c:?}");
    let removed: Vec<&str> = c
        .hunks
        .iter()
        .flat_map(|hunk| &hunk.lines)
        .filter_map(|line| match line {
            HunkLine::Removed(text) => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert!(
        removed.iter().any(|text| text.starts_with("<<<<<<<")),
        "the markers are the left text: {c:?}"
    );
    assert!(
        removed
            .iter()
            .any(|text| from.labels.iter().any(|label| text.contains(label.as_str()))),
        "a marker line names a parent's label: {removed:?} / {:?}",
        from.labels
    );
    assert_sections_round_trip(&mut fx, &diffs);
}

/// The X / Y merge left conflicted in `@`, with a line added above the markers: both sides carry
/// markers, the right ones with `@`'s own tree labels, and the keys still round-trip — in the
/// default and the `git` marker style.
#[test]
fn a_conflicted_revision_round_trips_through_select_tree() {
    conflicted_revision_round_trip(None);
    conflicted_revision_round_trip(Some("git"));
}

fn conflicted_revision_round_trip(marker_style: Option<&str>) {
    let mut fx = init();
    if let Some(style) = marker_style {
        add_repo_config(&fx, &format!("ui.conflict-marker-style = \"{style}\"\n"));
    }
    let root = fx.root.clone();
    write(&root, "c.txt", b"base\n");
    let a = wc(&root);
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new x");
    write(&root, "c.txt", b"x\n");
    let x = wc(&root);
    fx.repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new y");
    write(&root, "c.txt", b"y\n");
    let y = wc(&root);
    fx.repo.new_change(&[x, y], &[], &[]).expect("merge");
    let markers = fs::read(root.join("c.txt")).expect("the checked-out markers");
    write(&root, "c.txt", &[b"top\n".as_slice(), &markers].concat());
    let _ = fx.repo.take_warnings();

    let (_, to) = trees(&mut fx.repo);
    assert_eq!(to.tree_ids.len(), 3, "@'s own tree is still conflicted");
    assert_eq!(to.labels.len(), 3, "and labelled");
    let diffs = diff(&mut fx, None, Whitespace::Exact);
    let c = file(&diffs, "c.txt");
    assert!(!c.sections.is_empty(), "{c:?}");
    let lines: Vec<&str> = c
        .hunks
        .iter()
        .flat_map(|hunk| &hunk.lines)
        .filter_map(|line| match line {
            HunkLine::Context(text) | HunkLine::Added(text) => Some(text.as_str()),
            HunkLine::Removed(_) => None,
        })
        .collect();
    assert!(
        lines
            .iter()
            .any(|text| to.labels.iter().any(|label| text.contains(label.as_str()))),
        "a right-side marker line names one of @'s labels: {lines:?} / {:?}",
        to.labels
    );
    assert_sections_round_trip(&mut fx, &diffs);
}

/// A malformed tree is invalid input; an unknown one a backend error.
#[test]
fn bad_trees_are_refused() {
    let mut fx = base();
    let (_, to) = trees(&mut fx.repo);
    let call = |repo: &mut Repo, ids: Vec<String>| {
        repo.compute_hunks(&HunksOptions {
            from: SelectedTreeId {
                tree_ids: ids,
                labels: Vec::new(),
            },
            to: to.clone(),
            ..HunksOptions::default()
        })
        .expect_err("refused")
    };
    let even = call(&mut fx.repo, vec![to.tree_ids[0].clone(), to.tree_ids[0].clone()]);
    assert!(matches!(even, MutateError::InvalidInput { .. }), "{even:?}");
    let hex = call(&mut fx.repo, vec!["not hex".to_owned()]);
    assert!(matches!(hex, MutateError::InvalidInput { .. }), "{hex:?}");
    let unknown = call(
        &mut fx.repo,
        vec!["0123456789abcdef0123456789abcdef01234567".to_owned()],
    );
    assert!(matches!(unknown, MutateError::Backend(_)), "{unknown:?}");
    let none = call(&mut fx.repo, Vec::new());
    assert!(matches!(none, MutateError::InvalidInput { .. }), "{none:?}");
    let labels = fx
        .repo
        .compute_hunks(&HunksOptions {
            from: SelectedTreeId {
                tree_ids: to.tree_ids.clone(),
                labels: vec!["one".to_owned(), "two".to_owned()],
            },
            to: to.clone(),
            ..HunksOptions::default()
        })
        .expect_err("a label count that is neither zero nor the id count");
    assert!(matches!(labels, MutateError::InvalidInput { .. }), "{labels:?}");
}

/// A malformed `diff.git.context` or `diff.git.show-path-prefix` is a config error — also with an
/// explicit context, as the CLI reads both keys before `--context` overrides the first.
#[test]
fn a_malformed_context_is_a_config_error() {
    for name in ["diff.git.context", "diff.git.show-path-prefix"] {
        let mut fx = base();
        add_repo_config(&fx, &format!("{name} = \"x\"\n"));
        for context in [None, Some(3)] {
            let (from, to) = trees(&mut fx.repo);
            let err = fx
                .repo
                .compute_hunks(&HunksOptions {
                    from,
                    to,
                    context,
                    whitespace: Whitespace::Exact,
                })
                .expect_err("refused");
            assert!(
                matches!(&err, MutateError::Config { reason } if reason.contains(name)),
                "{name}: {err:?}"
            );
        }
    }
}

/// A configured `diff.git.context` is the default context.
#[test]
fn the_configured_context_is_the_default() {
    let mut fx = base();
    add_repo_config(&fx, "diff.git.context = 0\n");
    let diffs = diff(&mut fx, None, Whitespace::Exact);
    let sections: Vec<Vec<HunkKey>> = file(&diffs, "f.txt")
        .hunks
        .iter()
        .map(|hunk| hunk.sections.clone())
        .collect();
    assert_eq!(sections, [vec![S1], vec![S2], vec![S3]]);
}
