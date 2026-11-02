// SPDX-License-Identifier: MIT

//! Story 5.6 — `Repo::diff`, one witness per row of the I/O matrix. Every repo is built in-test
//! with Zanshin's own verbs on a non-colocated internal-git repo.

use std::fs;
use std::path::{Path, PathBuf};

use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{
    Backend, ChangeId, ChangeKind, CommitId, DiffOptions, DiffRevisions, FileDiff, HunkLine, HunksOptions, MutateError,
    OperationId, Repo, RevisionDiff, SelectedTreeId, WarningKind, Whitespace,
};

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

/// `@`'s change id and commit id.
fn wc(root: &Path) -> (ChangeId, CommitId) {
    let repo = load_head(root);
    let id = repo
        .view()
        .get_wc_commit_id(WorkspaceName::new("default"))
        .expect("workspace has an @");
    let commit = repo.store().get_commit(id).expect("@ commit");
    (ChangeId(commit.change_id().reverse_hex()), CommitId(id.hex()))
}

fn write(root: &Path, path: &str, content: &str) {
    fs::write(root.join(path), content).expect("write");
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

/// Describes `@` (snapshotting the working copy) and returns its ids.
fn commit(fx: &mut Fx, message: &str) -> (ChangeId, CommitId) {
    let (change, _) = wc(&fx.root);
    fx.repo.describe(change, message).expect("describe");
    wc(&fx.root)
}

/// `A` adds `f.txt` and `g.txt`; `C` (`@`, on `A`) changes a line of each.
fn plain() -> (Fx, (ChangeId, CommitId), (ChangeId, CommitId)) {
    let mut fx = init();
    write(&fx.root, "f.txt", "a\nb\nc\n");
    write(&fx.root, "g.txt", "g\n");
    let a = commit(&mut fx, "A\n");
    fx.repo.new_change(std::slice::from_ref(&a.0), &[], &[]).expect("new");
    write(&fx.root, "f.txt", "a\nB\nc\n");
    write(&fx.root, "g.txt", "G\n");
    let c = commit(&mut fx, "C\n");
    let _ = fx.repo.take_warnings();
    (fx, a, c)
}

fn run(fx: &mut Fx, options: &DiffOptions) -> RevisionDiff {
    fx.repo.diff(options).expect("diff")
}

fn revision(id: &ChangeId) -> DiffOptions {
    revset(&id.0)
}

/// `-r <text>`: any revset text.
fn revset(text: &str) -> DiffOptions {
    DiffOptions {
        revisions: DiffRevisions::Revision(Some(text.to_owned())),
        ..DiffOptions::default()
    }
}

fn paths(files: &[FileDiff]) -> Vec<&str> {
    files.iter().map(|file| file.path.as_str()).collect()
}

/// A plain change diffs like `compute_hunks` over the trees `show` reports, pinned to the head
/// operation and the revision; the default is `@`; nothing enters the op log.
#[test]
fn a_revision_diffs_against_its_parent_and_is_pinned() {
    let (mut fx, _, (c, c_commit)) = plain();
    let head = head_op(&fx.root);
    let result = run(&mut fx, &revision(&c));
    assert_eq!(head_op(&fx.root), head, "no operation");
    assert_eq!(result.operation_id, OperationId(head));
    assert_eq!(result.commit_ids, [c_commit]);
    assert_eq!(result.from_commit_id, None);
    assert_eq!(paths(&result.files), ["f.txt", "g.txt"]);
    assert!(result.files.iter().all(|file| file.kind == ChangeKind::Modified));
    let f = &result.files[0];
    assert_eq!((f.removed, f.added), (1, 1));
    assert_eq!(f.fingerprint.len(), 128);
    assert_ne!(f.fingerprint, result.files[1].fingerprint);

    let mut entries = fx.repo.show(None, None).expect("show");
    let entry = entries.remove(0);
    let hunks = fx
        .repo
        .compute_hunks(&HunksOptions {
            from: SelectedTreeId {
                tree_ids: entry.parent_tree_ids,
                labels: entry.parent_tree_labels,
            },
            to: SelectedTreeId {
                tree_ids: entry.tree_ids,
                labels: entry.tree_labels,
            },
            ..HunksOptions::default()
        })
        .expect("compute_hunks");
    assert_eq!(result.files, hunks);
    assert_eq!(run(&mut fx, &DiffOptions::default()), result);
}

/// Summary mode keeps every field but the hunks.
#[test]
fn summary_mode_drops_only_the_hunks() {
    let (mut fx, _, (c, _)) = plain();
    let full = run(&mut fx, &revision(&c));
    let summary = run(
        &mut fx,
        &DiffOptions {
            summary: true,
            ..revision(&c)
        },
    );
    assert!(summary.files.iter().all(|file| file.hunks.is_empty()));
    assert!(full.files.iter().all(|file| !file.hunks.is_empty()));
    let stripped: Vec<FileDiff> = full
        .files
        .iter()
        .cloned()
        .map(|file| FileDiff {
            hunks: Vec::new(),
            ..file
        })
        .collect();
    assert_eq!(summary.files, stripped);
    assert_eq!(
        (summary.operation_id, summary.commit_ids),
        (full.operation_id, full.commit_ids)
    );
}

/// A merge diffs against its merged parents: only what it adds itself.
#[test]
fn a_merge_lists_only_its_own_change() {
    let mut fx = init();
    write(&fx.root, "a.txt", "a\n");
    let p1 = commit(&mut fx, "P1\n");
    let root = ChangeId("z".repeat(32));
    fx.repo
        .new_change(std::slice::from_ref(&root), &[], &[])
        .expect("new on root");
    write(&fx.root, "b.txt", "b\n");
    let p2 = commit(&mut fx, "P2\n");
    fx.repo.new_change(&[p1.0, p2.0], &[], &[]).expect("merge");
    write(&fx.root, "c.txt", "c\n");
    let m = commit(&mut fx, "M\n");
    let result = run(&mut fx, &revision(&m.0));
    assert_eq!(paths(&result.files), ["c.txt"]);
    assert_eq!(result.files[0].kind, ChangeKind::Added);
    assert_eq!((result.files[0].removed, result.files[0].added), (0, 1));

    // The root's diff is empty.
    assert!(run(&mut fx, &revision(&root)).files.is_empty());
}

/// A rename on the git backend is one file: kind `Renamed`, hunks old → new content, no sections.
#[test]
fn a_rename_is_one_file_with_its_source() {
    let mut fx = init();
    let lines = "line 0\nline 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\n";
    write(&fx.root, "old.txt", lines);
    let a = commit(&mut fx, "A\n");
    fx.repo.new_change(std::slice::from_ref(&a.0), &[], &[]).expect("new");
    fs::remove_file(fx.root.join("old.txt")).expect("rm");
    write(&fx.root, "new.txt", &lines.replace("line 5\n", "line five\n"));
    let c = commit(&mut fx, "C\n");
    let result = run(&mut fx, &revision(&c.0));
    assert_eq!(paths(&result.files), ["new.txt"]);
    let file = &result.files[0];
    assert_eq!(
        file.kind,
        ChangeKind::Renamed {
            from: PathBuf::from("old.txt")
        }
    );
    assert!(file.sections.is_empty());
    assert_eq!(file.hunks.len(), 1);
    assert_eq!((file.removed, file.added), (1, 1));
    // A path filter on the source alone drops the record (it filters on the target): the
    // deletion shows plain.
    let filtered = run(
        &mut fx,
        &DiffOptions {
            paths: vec!["old.txt".to_owned()],
            ..revision(&c.0)
        },
    );
    assert_eq!(paths(&filtered.files), ["old.txt"]);
    assert_eq!(filtered.files[0].kind, ChangeKind::Removed);
    // The left side is read at the source: only the edited line differs.
    let changed: Vec<_> = file.hunks[0]
        .lines
        .iter()
        .filter(|line| !matches!(line, HunkLine::Context(_)))
        .collect();
    assert_eq!(
        changed,
        [
            &HunkLine::Removed("line 5\n".to_owned()),
            &HunkLine::Added("line five\n".to_owned())
        ]
    );
    // A filter on the target keeps the record: still the one renamed file.
    let target_only = run(
        &mut fx,
        &DiffOptions {
            paths: vec!["new.txt".to_owned()],
            ..revision(&c.0)
        },
    );
    assert_eq!(target_only.files, result.files);
    // `--from A --to C` uses the records from A to C: the same single renamed file.
    let from_to = run(
        &mut fx,
        &DiffOptions {
            revisions: DiffRevisions::FromTo {
                from: Some(a.0 .0),
                to: Some(c.0 .0),
            },
            ..DiffOptions::default()
        },
    );
    assert_eq!(from_to.files, result.files);
}

/// A copy on the git backend (its source changed in the same commit, as git's copy detection
/// requires — jj-lib `git_backend.rs` `CopySource::FromSetOfModifiedFiles`) is kind `Copied` with
/// its source; the source itself stays `Modified`.
#[test]
fn a_copy_names_its_source_which_stays_modified() {
    let mut fx = init();
    let lines = "line 0\nline 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\n";
    write(&fx.root, "old.txt", lines);
    let a = commit(&mut fx, "A\n");
    fx.repo.new_change(std::slice::from_ref(&a.0), &[], &[]).expect("new");
    write(&fx.root, "old.txt", &lines.replace("line 5\n", "line five\n"));
    write(&fx.root, "new.txt", lines);
    let c = commit(&mut fx, "C\n");
    let result = run(&mut fx, &revision(&c.0));
    assert_eq!(paths(&result.files), ["new.txt", "old.txt"]);
    assert_eq!(
        result.files[0].kind,
        ChangeKind::Copied {
            from: PathBuf::from("old.txt")
        }
    );
    // The copy's left side is read at the source in the before tree: identical content.
    assert!(result.files[0].hunks.is_empty());
    assert_eq!((result.files[0].removed, result.files[0].added), (0, 0));
    let source = &result.files[1];
    assert_eq!(source.kind, ChangeKind::Modified);
    assert_eq!(source.hunks.len(), 1);
    assert_eq!((source.removed, source.added), (1, 1));
}

/// A dirty `@` is snapshotted first; the pin names the operation after that snapshot.
#[test]
fn the_operation_pin_is_the_post_snapshot_head() {
    let (mut fx, _, _) = plain();
    write(&fx.root, "dirty.txt", "d\n");
    let before = head_op(&fx.root);
    let result = run(&mut fx, &DiffOptions::default());
    let after = head_op(&fx.root);
    assert_ne!(after, before, "the pre-verb snapshot wrote an operation");
    assert_eq!(result.operation_id, OperationId(after));
    assert!(paths(&result.files).contains(&"dirty.txt"));
}

/// `--from` / `--to`: either tree against the other, `None` = `@`; equal sides are empty.
#[test]
fn from_to_diffs_two_revisions_and_pins_both() {
    let (mut fx, (a, a_commit), (c, c_commit)) = plain();
    let from_to = |from: Option<&ChangeId>, to: Option<&ChangeId>| DiffOptions {
        revisions: DiffRevisions::FromTo {
            from: from.map(|id| id.0.clone()),
            to: to.map(|id| id.0.clone()),
        },
        ..DiffOptions::default()
    };
    let result = run(&mut fx, &from_to(Some(&a), Some(&c)));
    assert_eq!(result.commit_ids, std::slice::from_ref(&c_commit));
    assert_eq!(result.from_commit_id, Some(a_commit.clone()));
    assert_eq!(result.files, run(&mut fx, &revision(&c)).files);
    assert_eq!(run(&mut fx, &from_to(Some(&a), None)), result);
    let reverse = run(&mut fx, &from_to(None, Some(&a)));
    assert_eq!(reverse.commit_ids, [a_commit]);
    assert_eq!(reverse.from_commit_id, Some(c_commit));
    assert_eq!(paths(&reverse.files), ["f.txt", "g.txt"]);
    assert!(run(&mut fx, &from_to(Some(&c), Some(&c))).files.is_empty());
}

/// Paths restrict the diff; an unmatched one warns; an invalid one is refused.
#[test]
fn paths_filter_warn_and_refuse() {
    let (mut fx, _, (c, _)) = plain();
    let with = |list: &[&str]| DiffOptions {
        paths: list.iter().map(|path| (*path).to_owned()).collect(),
        ..revision(&c)
    };
    assert_eq!(paths(&run(&mut fx, &with(&["f.txt"])).files), ["f.txt"]);
    assert!(fx.repo.take_warnings().is_empty());
    assert!(run(&mut fx, &with(&["nope"])).files.is_empty());
    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0].kind, WarningKind::PathsUnmatched);
    assert!(matches!(
        fx.repo.diff(&with(&["/x"])),
        Err(MutateError::InvalidInput { .. })
    ));
}

/// A rename's hunk symbol comes from the target's language (`show_git_diff`).
#[test]
fn a_rename_takes_its_language_from_the_target() {
    let mut fx = init();
    let body = "fn main() {\n    a();\n    1;\n    2;\n    3;\n    4;\n    5;\n    6;\n}\n";
    write(&fx.root, "main.txt", body);
    let a = commit(&mut fx, "A\n");
    fx.repo.new_change(std::slice::from_ref(&a.0), &[], &[]).expect("new");
    fs::remove_file(fx.root.join("main.txt")).expect("rm");
    write(&fx.root, "main.rs", &body.replace("6;", "seven;"));
    let c = commit(&mut fx, "C\n");
    let result = run(
        &mut fx,
        &DiffOptions {
            context: Some(0),
            ..revision(&c.0)
        },
    );
    assert_eq!(paths(&result.files), ["main.rs"]);
    assert!(matches!(result.files[0].kind, ChangeKind::Renamed { .. }));
    assert_eq!(result.files[0].hunks[0].symbol.as_deref(), Some("fn main() {"));
}

/// `context` and `whitespace` reach the reader (`--context`, `-w`).
#[test]
fn context_and_whitespace_reach_the_reader() {
    let (mut fx, _, (c, _)) = plain();
    let has_context = |result: &RevisionDiff| {
        result.files[0].hunks[0]
            .lines
            .iter()
            .any(|line| matches!(line, HunkLine::Context(_)))
    };
    assert!(has_context(&run(&mut fx, &revision(&c))));
    let no_context = DiffOptions {
        context: Some(0),
        ..revision(&c)
    };
    assert!(!has_context(&run(&mut fx, &no_context)));

    fx.repo.new_change(std::slice::from_ref(&c), &[], &[]).expect("new");
    write(&fx.root, "f.txt", "a\nB \nc\n");
    let (d, _) = commit(&mut fx, "D\n");
    let exact = run(&mut fx, &revision(&d));
    let ignoring = run(
        &mut fx,
        &DiffOptions {
            whitespace: Whitespace::IgnoreAllSpace,
            ..revision(&d)
        },
    );
    assert_eq!(exact.files[0].hunks.len(), 1);
    assert!(ignoring.files[0].hunks.is_empty());
    assert_ne!(ignoring.files[0].fingerprint, exact.files[0].fingerprint);
}

/// The git object at `id` (a hex id) removed from the internal git store.
fn remove_object(root: &Path, id: &str) {
    let objects = root.join(".jj/repo/store/git/objects");
    fs::remove_file(objects.join(&id[..2]).join(&id[2..])).expect("remove loose object");
}

/// A store read failing mid-call (a parent commit, a tree for the copy records) is a backend
/// error, not a panic.
#[test]
fn a_missing_object_is_a_backend_error() {
    let (mut fx, _, (c, c_commit)) = plain();
    // `@` moves off C's tree so the pre-verb snapshot never reads it.
    fx.repo.new_change(std::slice::from_ref(&c), &[], &[]).expect("new");
    write(&fx.root, "h.txt", "h\n");
    let (d, _) = commit(&mut fx, "D\n");
    let c_tree = load_head(&fx.root)
        .store()
        .get_commit(&jj_lib::backend::CommitId::try_from_hex(&c_commit.0).expect("hex"))
        .expect("C")
        .tree_ids()
        .as_resolved()
        .expect("resolved tree")
        .hex();
    remove_object(&fx.root, &c_tree);
    let mut repo = Repo::open(&fx.root).expect("reopen");
    let from_to = DiffOptions {
        revisions: DiffRevisions::FromTo {
            from: Some(c.0.clone()),
            to: Some(d.0.clone()),
        },
        ..DiffOptions::default()
    };
    // Fails in `get_copy_records` (`read_tree_for_commit`), before any tree is diffed.
    assert!(matches!(repo.diff(&from_to), Err(MutateError::Backend(_))));
    // D's parent C is gone.
    remove_object(&fx.root, &c_commit.0);
    let mut repo = Repo::open(&fx.root).expect("reopen");
    assert!(matches!(repo.diff(&revision(&d)), Err(MutateError::Backend(_))));
}

/// An unknown symbol is a resolution error, a `--from` resolving to several commits too
/// (`resolve_single_rev`, with the CLI's summary hint); a bad expression a parse error.
#[test]
fn an_unknown_several_or_malformed_revision_is_refused() {
    let (mut fx, _, _) = plain();
    let resolution = |result| {
        let Err(MutateError::RevsetResolutionError { reason, hints }) = result else {
            unreachable!("expected a resolution error, got {result:?}")
        };
        (reason, hints)
    };
    assert_eq!(
        resolution(fx.repo.diff(&revset("yyyyyyyy"))).0,
        "Revision `yyyyyyyy` doesn't exist"
    );
    let from_to = DiffOptions {
        revisions: DiffRevisions::FromTo {
            from: Some("all()".to_owned()),
            to: None,
        },
        ..DiffOptions::default()
    };
    let (reason, hints) = resolution(fx.repo.diff(&from_to));
    assert_eq!(reason, "Revset `all()` resolved to more than one revision");
    let [hint] = hints.as_slice() else {
        unreachable!("one hint: {hints:?}")
    };
    let lines: Vec<&str> = hint.lines().collect();
    assert_eq!(lines[0], "The revset `all()` resolved to these revisions:");
    assert_eq!(lines.len(), 4, "C, A and the root: {hint}");
    assert!(lines[1..].iter().all(|line| line.starts_with("  ") && line.len() > 2));
    assert!(lines[3].starts_with("  zzzzzzzz 00000000"), "the root last: {hint}");
    assert!(matches!(
        fx.repo.diff(&revset("bogus(")),
        Err(MutateError::RevsetParseError { .. })
    ));
}

/// Past five commits the multiple-revisions hint lists five, then `  ...`.
#[test]
fn the_multiple_revisions_hint_lists_five_then_elides() {
    let (mut fx, _, (c, _)) = plain();
    let mut tip = c;
    for n in 0..4 {
        fx.repo.new_change(std::slice::from_ref(&tip), &[], &[]).expect("new");
        tip = commit(&mut fx, &format!("N{n}\n")).0;
    }
    let from_to = DiffOptions {
        revisions: DiffRevisions::FromTo {
            from: Some("all()".to_owned()),
            to: None,
        },
        ..DiffOptions::default()
    };
    let Err(MutateError::RevsetResolutionError { hints, .. }) = fx.repo.diff(&from_to) else {
        unreachable!("several commits are refused")
    };
    let lines: Vec<&str> = hints[0].lines().collect();
    assert_eq!(lines.len(), 7, "heading, five summaries, the ellipsis: {lines:?}");
    assert_eq!(lines[6], "  ...");
    assert!(lines[1..6]
        .iter()
        .all(|line| line.starts_with("  ") && *line != "  ..."));
}

/// `A` adds `a.txt`, `B` (on `A`) `b.txt`, `C` (`@`, on `B`) `c.txt`.
fn linear() -> (Fx, [(ChangeId, CommitId); 3]) {
    let mut fx = init();
    write(&fx.root, "a.txt", "a\n");
    let a = commit(&mut fx, "A\n");
    fx.repo.new_change(std::slice::from_ref(&a.0), &[], &[]).expect("new");
    write(&fx.root, "b.txt", "b\n");
    let b = commit(&mut fx, "B\n");
    fx.repo.new_change(std::slice::from_ref(&b.0), &[], &[]).expect("new");
    write(&fx.root, "c.txt", "c\n");
    let c = commit(&mut fx, "C\n");
    let _ = fx.repo.take_warnings();
    (fx, [a, b, c])
}

/// `-r 'B::C'` diffs B's parent against C, as `--from A --to C` does; the heads pin it.
#[test]
fn a_range_diffs_its_roots_parents_against_its_heads() {
    let (mut fx, [(a, _), (b, _), (c, c_commit)]) = linear();
    let range = run(&mut fx, &revset(&format!("{}::{}", b.0, c.0)));
    assert_eq!(range.commit_ids, [c_commit]);
    assert_eq!(range.from_commit_id, None);
    assert_eq!(paths(&range.files), ["b.txt", "c.txt"]);
    let from_to = run(
        &mut fx,
        &DiffOptions {
            revisions: DiffRevisions::FromTo {
                from: Some(a.0),
                to: Some(c.0),
            },
            ..DiffOptions::default()
        },
    );
    assert_eq!(range.files, from_to.files);
}

/// A set with a gap is refused with the CLI's message and the first missing commit.
#[test]
fn a_set_with_a_gap_is_refused() {
    let (mut fx, [(a, _), (_, b_commit), (c, _)]) = linear();
    let result = fx.repo.diff(&revset(&format!("{} | {}", a.0, c.0)));
    let Err(MutateError::InvalidInput { reason, hints }) = result else {
        unreachable!("a gap is refused: {result:?}")
    };
    assert_eq!(reason, "Cannot diff revsets with gaps in.");
    assert_eq!(
        hints,
        [format!("Revision {} would need to be in the set.", &b_commit.0[..12])]
    );
}

/// Two sibling heads diff their common parent against their merge; an empty set and the whole
/// repo diff from the empty tree.
#[test]
fn siblings_merge_and_empty_or_whole_sets_diff_from_nothing() {
    let mut fx = init();
    write(&fx.root, "a.txt", "a\n");
    let a = commit(&mut fx, "A\n");
    fx.repo.new_change(std::slice::from_ref(&a.0), &[], &[]).expect("new");
    write(&fx.root, "b.txt", "b\n");
    let b = commit(&mut fx, "B\n");
    fx.repo.new_change(std::slice::from_ref(&a.0), &[], &[]).expect("new");
    write(&fx.root, "c.txt", "c\n");
    let c = commit(&mut fx, "C\n");
    let siblings = run(&mut fx, &revset(&format!("{} | {}", b.0 .0, c.0 .0)));
    // Heads in revset (index) order: the newer C first.
    assert_eq!(siblings.commit_ids, [c.1.clone(), b.1.clone()]);
    assert_eq!(paths(&siblings.files), ["b.txt", "c.txt"]);
    assert!(siblings.files.iter().all(|file| file.kind == ChangeKind::Added));

    let empty = run(&mut fx, &revset("none()"));
    assert!(empty.commit_ids.is_empty());
    assert!(empty.files.is_empty());

    // `root()`, A and B: the root's (absent) parents against the one head B.
    let whole = run(&mut fx, &revset(&format!("all() ~ {}", c.0 .0)));
    assert_eq!(paths(&whole.files), ["a.txt", "b.txt"]);
    assert_eq!(whole.commit_ids, [b.1]);
}

/// A commit id reaches a hidden commit (a rewritten predecessor), as `jj diff -r` does.
#[test]
fn a_hidden_commit_id_diffs_that_commit() {
    let (mut fx, _, (_, c_commit)) = plain();
    let before = run(&mut fx, &revset(&c_commit.0));
    assert_eq!(before.commit_ids, std::slice::from_ref(&c_commit));
    write(&fx.root, "f.txt", "a\nB\nC\n");
    let (_, rewritten) = commit(&mut fx, "C2\n");
    assert_ne!(rewritten, c_commit, "C was rewritten, its old commit hidden");
    let hidden = run(&mut fx, &revset(&c_commit.0));
    assert_eq!(hidden.commit_ids, [c_commit]);
    assert_eq!(hidden.files, before.files);
    assert_ne!(run(&mut fx, &revset(&rewritten.0)).files, before.files);
}

/// Story 10.29: B is rebased (A rewritten) and then changed itself. The interdiff of its old
/// commit against the new one shows only B's own change, as `Repo::interdiff` lists it, while
/// `--from` / `--to` also shows A's; an absent `to` is `@`.
#[test]
fn an_interdiff_shows_only_the_rebased_commits_own_change() {
    let (mut fx, [(a, _), (b, b_old), _]) = linear();
    fx.repo.edit(a).expect("edit A");
    write(&fx.root, "a.txt", "A\n");
    commit(&mut fx, "A\n");
    fx.repo.edit(b.clone()).expect("edit B");
    write(&fx.root, "b.txt", "b2\n");
    let (_, b_new) = commit(&mut fx, "B\n");
    let sides = |interdiff: bool, to: Option<String>| {
        let (from, to) = (Some(b_old.0.clone()), to);
        DiffOptions {
            revisions: if interdiff {
                DiffRevisions::Interdiff { from, to }
            } else {
                DiffRevisions::FromTo { from, to }
            },
            ..DiffOptions::default()
        }
    };
    let inter = run(&mut fx, &sides(true, Some(b_new.0.clone())));
    assert_eq!(inter.commit_ids, std::slice::from_ref(&b_new));
    assert_eq!(inter.from_commit_id, Some(b_old.clone()));
    assert_eq!(paths(&inter.files), ["b.txt"]);
    assert_eq!(
        inter.files[0].hunks[0].lines,
        [HunkLine::Removed("b\n".into()), HunkLine::Added("b2\n".into())]
    );
    let view = fx
        .repo
        .interdiff(
            Some(zanshin_jj::RevisionRef::CommitId(b_old.clone())),
            Some(zanshin_jj::RevisionRef::CommitId(b_new.clone())),
            &[],
        )
        .expect("interdiff");
    let listed: Vec<_> = view
        .file_changes
        .iter()
        .map(|c| c.path.to_str().expect("utf-8"))
        .collect();
    assert_eq!(listed, paths(&inter.files));
    assert_eq!(
        paths(&run(&mut fx, &sides(false, Some(b_new.0.clone()))).files),
        ["a.txt", "b.txt"]
    );
    assert_eq!(run(&mut fx, &sides(true, None)), inter);
}

/// An interdiff's unmatched-paths check covers the parent trees, as `cmd_interdiff` does: P adds
/// `x.txt`, F (on P) deletes it, T is off the root — `x.txt` is only in F's parent tree (not in F,
/// T or F rebased onto T's parent), so it does not warn; a path in no tree does.
#[test]
fn an_interdiff_checks_the_parent_trees_for_unmatched_paths() {
    let mut fx = init();
    write(&fx.root, "x.txt", "x\n");
    let (p, _) = commit(&mut fx, "P\n");
    fx.repo.new_change(std::slice::from_ref(&p), &[], &[]).expect("new");
    fs::remove_file(fx.root.join("x.txt")).expect("remove");
    let (_, f) = commit(&mut fx, "F\n");
    fx.repo
        .new_change(&[ChangeId("z".repeat(32))], &[], &[])
        .expect("new on root");
    write(&fx.root, "t.txt", "t\n");
    let (_, t) = commit(&mut fx, "T\n");
    let _ = fx.repo.take_warnings();
    let with = |path: &str| DiffOptions {
        revisions: DiffRevisions::Interdiff {
            from: Some(f.0.clone()),
            to: Some(t.0.clone()),
        },
        paths: vec![path.to_owned()],
        ..DiffOptions::default()
    };
    run(&mut fx, &with("x.txt"));
    assert!(fx.repo.take_warnings().is_empty(), "x.txt is in F's parent tree");
    run(&mut fx, &with("nowhere.txt"));
    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0].kind, WarningKind::PathsUnmatched);
}

/// An interdiff with neither side is refused with `Repo::interdiff`'s wording before the snapshot.
#[test]
fn an_interdiff_without_sides_is_refused_before_the_snapshot() {
    let (mut fx, _, _) = plain();
    let head = head_op(&fx.root);
    write(&fx.root, "f.txt", "dirty\n");
    let result = fx.repo.diff(&DiffOptions {
        revisions: DiffRevisions::Interdiff { from: None, to: None },
        ..DiffOptions::default()
    });
    let Err(MutateError::InvalidInput { reason, .. }) = result else {
        unreachable!("both sides absent is refused: {result:?}")
    };
    assert_eq!(reason, "at least one of `from` or `to` is required");
    assert_eq!(head_op(&fx.root), head, "no snapshot");
}

/// Revset texts resolve to the one commit each denotes: `-r @-`, `--from @-- --to @-`.
#[test]
fn revset_texts_resolve_to_their_commit() {
    let (mut fx, (a, a_commit), _) = plain();
    let parent = run(&mut fx, &revset("@-"));
    assert_eq!(parent.commit_ids, std::slice::from_ref(&a_commit));
    assert_eq!(parent, run(&mut fx, &revision(&a)));
    let from_to = run(
        &mut fx,
        &DiffOptions {
            revisions: DiffRevisions::FromTo {
                from: Some("@--".to_owned()),
                to: Some("@-".to_owned()),
            },
            ..DiffOptions::default()
        },
    );
    assert_eq!(from_to.commit_ids, [a_commit]);
    assert_eq!(from_to.from_commit_id, Some(CommitId("0".repeat(40))));
    assert_eq!(from_to.files, parent.files);
}
