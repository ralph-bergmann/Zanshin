// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.4's four `jj file` READ verbs: `Repo::file_list`,
//! `file_show`, `file_annotate` and `file_search`.
//!
//! Integration level is right: all four entry points are public `Repo` methods and every row
//! needs a real repo with real trees.
//!
//! The committed fixtures give every commit exactly one plain, non-executable file
//! (`xtask`'s `gen_fixture.rs` builds each tree from an empty base with only
//! `commit-<n>.txt`), so an executable, a symlink, a multi-entry tree and a conflict are all
//! unconstructible from a fixture alone — and regenerating fixtures is forbidden (it would
//! shift the revset oracles). Every scenario is therefore built on purpose with
//! `test_helpers::add_commit_with_entries` / `add_conflicted_merge_*`; the fixture supplies
//! only the workspace, its `@`, and its op log.
//!
//! Two assertions repeat throughout: the result compared against a RAW jj-lib oracle (never
//! a second call to the code under test), and — for every verb, on both a success and a
//! refusal — that the op-log head is byte-identical afterwards. A read must never write an
//! operation, unlike the CLI, whose `workspace_helper` may snapshot first.

use std::path::Path;
use std::sync::{Arc, LazyLock};
use std::{env, fs};

use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;
use test_helpers::{
    add_commit_with_entries, add_commit_with_files, add_conflicted_merge_off_root,
    add_conflicted_merge_with_extra_files, add_divergent_twin, extract_fixture, Entry, FixtureHandle,
};
use zanshin_jj::{ChangeId, FileError, FileType, Repo};

// ── Harness ───────────────────────────────────────────────────────────────────────

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    // Same env pin as `tests/content_ops.rs`: the config layer must see the fixture's own
    // config, not the developer's `~/.jjconfig.toml`.
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

fn make_test_settings() -> UserSettings {
    let mut config = StackedConfig::with_defaults();
    config.add_layer(
        ConfigLayer::parse(
            ConfigSource::User,
            r#"
                [user]
                name = "Zanshin"
                email = "zanshin@localhost"
                [operation]
                username = "zanshin"
                hostname = "localhost"
            "#,
        )
        .expect("valid config literal"),
    );
    UserSettings::from_config(config).expect("valid settings")
}

/// The head-resolved jj-lib repo — the oracle these tests read trees from.
fn jj_repo(workspace_root: &Path) -> Arc<ReadonlyRepo> {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head")
}

fn change_id_of(workspace_root: &Path, commit_hex: &str) -> ChangeId {
    let repo = jj_repo(workspace_root);
    let id = JjCommitId::try_from_hex(commit_hex).expect("hex commit id");
    ChangeId(repo.store().get_commit(&id).expect("commit").change_id().reverse_hex())
}

/// Every path in `commit_hex`'s tree, read straight off jj-lib — the listing oracle.
fn oracle_paths(workspace_root: &Path, commit_hex: &str) -> Vec<String> {
    let repo = jj_repo(workspace_root);
    let id = JjCommitId::try_from_hex(commit_hex).expect("hex commit id");
    repo.store()
        .get_commit(&id)
        .expect("commit")
        .tree()
        .entries()
        .map(|(path, _)| path.as_internal_file_string().to_owned())
        .collect()
}

/// The simplified side count jj-lib itself reports for `path` in `commit_hex` — the
/// `conflict_side_count` oracle.
fn oracle_side_count(workspace_root: &Path, commit_hex: &str, path: &str) -> u32 {
    let repo = jj_repo(workspace_root);
    let id = JjCommitId::try_from_hex(commit_hex).expect("hex commit id");
    let tree = repo.store().get_commit(&id).expect("commit").tree();
    let repo_path = jj_lib::repo_path::RepoPathBuf::from_internal_string(path.to_owned()).expect("valid path");
    let value = pollster::block_on(tree.path_value(&repo_path)).expect("path value");
    u32::try_from(value.simplify().num_sides()).expect("a test tree has few sides")
}

/// The head operation's id, so a test can assert that a READ wrote nothing.
fn head_op_id(repo: &Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).id.0
}

fn write_repo_config(workspace_root: &Path, toml: &str) {
    fs::write(workspace_root.join(".jj").join("repo").join("config.toml"), toml).expect("repo config must be writable");
}

/// A tree with one plain file, one EXECUTABLE file, one symlink and a nested directory —
/// everything `file_list`'s `file_type`/`executable` fields and `file_show`'s skip rule need,
/// none of which any committed fixture contains.
struct MixedTree {
    fx: FixtureHandle,
    commit_hex: String,
    change: ChangeId,
}

fn mixed_tree() -> MixedTree {
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let commit_hex = add_commit_with_entries(
        &fx.path,
        &[],
        &[
            ("a.txt", Entry::File("alpha\nneedle here\n")),
            ("dir/b.txt", Entry::File("beta\n")),
            ("dir/nested/c.txt", Entry::File("gamma needle\n")),
            ("run.sh", Entry::Executable("#!/bin/sh\n")),
            ("link", Entry::Symlink("a.txt needle")),
        ],
        "mixed tree",
    );
    let change = change_id_of(&fx.path, &commit_hex);
    MixedTree { fx, commit_hex, change }
}

fn open(fx: &FixtureHandle) -> Repo {
    Repo::open(&fx.path).expect("fixture opens")
}

// ── file_list ─────────────────────────────────────────────────────────────────────

#[test]
fn file_list_returns_every_entry_in_jj_lib_tree_order() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);
    let before = head_op_id(&repo);

    let entries = repo.file_list(Some(t.change.clone()), &[]).expect("list succeeds");

    let paths: Vec<String> = entries.iter().map(|e| e.path.clone()).collect();
    assert_eq!(
        paths,
        oracle_paths(&t.fx.path, &t.commit_hex),
        "entries must match jj-lib's own tree order"
    );
    assert_eq!(head_op_id(&repo), before, "a read must not write an operation");
}

#[test]
fn file_list_reports_file_type_and_the_executable_bit() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    let entries = repo.file_list(Some(t.change), &[]).expect("list succeeds");
    let by_path = |p: &str| {
        entries
            .iter()
            .find(|e| e.path == p)
            .unwrap_or_else(|| panic!("{p} must be listed"))
            .clone()
    };

    let plain = by_path("a.txt");
    assert_eq!(plain.file_type, FileType::File);
    assert!(!plain.executable, "a plain file is not executable");
    assert_eq!(plain.conflict_side_count, 1, "a resolved entry has one side");

    let exec = by_path("run.sh");
    assert_eq!(exec.file_type, FileType::File);
    assert!(exec.executable, "the executable bit must survive the projection");

    let link = by_path("link");
    assert_eq!(link.file_type, FileType::Symlink);
    assert!(
        !link.executable,
        "a symlink has no executable bit (CLI: unwrap_or_default)"
    );

    assert!(
        !entries.iter().any(|e| e.file_type == FileType::Tree),
        "entries_matching recurses into subtrees and never yields one"
    );
}

#[test]
fn file_list_filters_by_path_prefix() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    let entries = repo
        .file_list(Some(t.change), &["dir".to_owned()])
        .expect("list succeeds");

    let paths: Vec<String> = entries.iter().map(|e| e.path.clone()).collect();
    assert_eq!(paths, vec!["dir/b.txt".to_owned(), "dir/nested/c.txt".to_owned()]);
}

#[test]
fn file_list_treats_an_empty_string_path_as_the_repo_root() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    let all = repo
        .file_list(Some(t.change), &[String::new()])
        .expect("the empty string is a valid repo path");

    let paths: Vec<String> = all.iter().map(|e| e.path.clone()).collect();
    assert_eq!(
        paths,
        oracle_paths(&t.fx.path, &t.commit_hex),
        "the root prefixes every path, so [\"\"] matches everything"
    );
}

#[test]
fn file_list_without_a_revision_lists_the_working_copy_commit() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let commit_hex = add_commit_with_files(&fx.path, &[], &[("wc.txt", "in the working copy\n")], "wc content");
    let change = change_id_of(&fx.path, &commit_hex);

    // Move `@` onto that commit through a shipped verb, so "the default revision" is a real
    // working-copy commit rather than the fixture's empty root.
    let mut repo = open(&fx);
    repo.edit(change).expect("edit moves @");

    let entries = repo.file_list(None, &[]).expect("list succeeds");

    let paths: Vec<String> = entries.iter().map(|e| e.path.clone()).collect();
    assert_eq!(
        paths,
        oracle_paths(&fx.path, &commit_hex),
        "an omitted revision is the last-snapshotted @"
    );
}

#[test]
fn file_list_reports_a_conflicted_entry_with_jj_libs_own_side_count() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let merge_hex = add_conflicted_merge_off_root(&fx.path);
    let change = change_id_of(&fx.path, &merge_hex);
    let repo = open(&fx);

    let entries = repo.file_list(Some(change), &[]).expect("list succeeds");

    let conflicted = entries
        .iter()
        .find(|e| e.path == "conflicted.txt")
        .expect("the conflicted path must be listed");
    assert_eq!(conflicted.file_type, FileType::Conflict);
    assert_eq!(
        conflicted.conflict_side_count,
        oracle_side_count(&fx.path, &merge_hex, "conflicted.txt"),
        "the side count must be jj-lib's own simplified count"
    );
}

#[test]
fn file_list_refuses_a_malformed_revision_without_writing_an_operation() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);
    let before = head_op_id(&repo);

    let err = repo
        .file_list(Some(ChangeId("not-reverse-hex!".to_owned())), &[])
        .expect_err("a malformed change id is refused");

    assert!(
        matches!(&err, FileError::ChangeNotFound { id } if id == "not-reverse-hex!"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&repo), before, "a refusal must not write an operation");
}

#[test]
fn file_list_refuses_a_divergent_revision() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let original = add_commit_with_files(&fx.path, &[], &[("a.txt", "A\n")], "original");
    let change = change_id_of(&fx.path, &original);
    _ = add_divergent_twin(&fx.path, &original, "the twin");
    let repo = open(&fx);

    let err = repo
        .file_list(Some(change.clone()), &[])
        .expect_err("a divergent id is refused, not guessed");

    assert!(
        matches!(&err, FileError::ChangeNotFound { id } if *id == change.0),
        "unexpected error: {err:?}"
    );
}

#[test]
fn file_list_refuses_a_malformed_path() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    let err = repo
        .file_list(Some(t.change), &["/absolute.txt".to_owned()])
        .expect_err("a leading slash is not a repo path");

    assert!(
        matches!(&err, FileError::InvalidInput { reason } if reason.contains("invalid path")),
        "unexpected error: {err:?}"
    );
}

// ── file_show ─────────────────────────────────────────────────────────────────────

#[test]
fn file_show_returns_the_exact_bytes_of_a_single_file() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);
    let before = head_op_id(&repo);

    let out = repo
        .file_show(Some(t.change), &["a.txt".to_owned()])
        .expect("show succeeds");

    assert_eq!(out.files.len(), 1);
    assert_eq!(out.files[0].path, "a.txt");
    assert_eq!(out.files[0].content, b"alpha\nneedle here\n".to_vec());
    assert!(!out.files[0].conflict);
    assert!(out.skipped.is_empty(), "nothing was skipped");
    assert_eq!(head_op_id(&repo), before, "a read must not write an operation");
}

#[test]
fn file_show_visits_a_directory_recursively() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    let out = repo
        .file_show(Some(t.change), &["dir".to_owned()])
        .expect("show succeeds");

    let paths: Vec<String> = out.files.iter().map(|f| f.path.clone()).collect();
    assert_eq!(paths, vec!["dir/b.txt".to_owned(), "dir/nested/c.txt".to_owned()]);
}

#[test]
fn file_show_skips_a_symlink_with_the_clis_own_wording() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    let out = repo
        .file_show(Some(t.change), &["link".to_owned()])
        .expect("a symlink is skipped, not a refusal");

    assert!(out.files.is_empty(), "a symlink yields no content");
    assert_eq!(out.skipped.len(), 1);
    assert_eq!(out.skipped[0].path, "link");
    assert_eq!(out.skipped[0].reason, "Path 'link' exists but is not a file.");
}

#[test]
fn file_show_refuses_a_single_absent_path_but_not_one_among_many() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);
    let before = head_op_id(&repo);

    let err = repo
        .file_show(Some(t.change.clone()), &["nope.txt".to_owned()])
        .expect_err("the single-path fast path refuses an absent path");
    assert!(
        matches!(&err, FileError::PathNotFound { path } if path == "nope.txt"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&repo), before, "a refusal must not write an operation");

    // With more than one path the CLI only warns — the missing path is simply absent.
    let out = repo
        .file_show(Some(t.change), &["a.txt".to_owned(), "nope.txt".to_owned()])
        .expect("an absent path among many is not a refusal");
    let paths: Vec<String> = out.files.iter().map(|f| f.path.clone()).collect();
    assert_eq!(paths, vec!["a.txt".to_owned()]);
}

#[test]
fn file_show_refuses_an_empty_path_list() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    let err = repo
        .file_show(Some(t.change), &[])
        .expect_err("the CLI marks FILESETS required");

    assert!(
        matches!(&err, FileError::InvalidInput { reason } if reason.contains("at least one path")),
        "unexpected error: {err:?}"
    );
}

#[test]
fn file_show_refuses_a_malformed_path_on_both_parse_sites() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    // `file_show` is the only verb with TWO path-parse sites: the single-path fast path
    // parses with `parse_path`, the multi-path branch with `build_matcher`. Both must refuse.
    let err = repo
        .file_show(Some(t.change.clone()), &["/absolute.txt".to_owned()])
        .expect_err("the single-path fast path refuses a leading slash");
    assert!(
        matches!(&err, FileError::InvalidInput { reason } if reason.contains("invalid path")),
        "unexpected error from the fast path: {err:?}"
    );

    let err = repo
        .file_show(Some(t.change), &["a.txt".to_owned(), "dir/".to_owned()])
        .expect_err("the multi-path branch refuses a trailing slash");
    assert!(
        matches!(&err, FileError::InvalidInput { reason } if reason.contains("invalid path")),
        "unexpected error from the matcher branch: {err:?}"
    );
}

#[test]
fn file_show_reports_a_malformed_conflict_marker_style_as_a_config_error() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    // `file show` is the one file read that consults the effective config. A value that is
    // not one of jj's four style names is the USER's config being wrong, not the repository
    // — which is why it is `Config`, not `Backend`, exactly as every other config-reading
    // verb reports it.
    write_repo_config(&t.fx.path, "[ui]\nconflict-marker-style = \"nonsense\"\n");

    let err = repo
        .file_show(Some(t.change), &["a.txt".to_owned()])
        .expect_err("an unknown marker style is refused");

    assert!(
        matches!(&err, FileError::Config { reason } if reason.contains("conflict-marker-style")),
        "unexpected error: {err:?}"
    );
}

#[test]
fn file_show_materializes_a_conflict_in_the_style_the_repo_config_selects() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let merge_hex = add_conflicted_merge_off_root(&fx.path);
    let change = change_id_of(&fx.path, &merge_hex);

    // Default: the builtin layer's "diff", which is the CLI's own default.
    let repo = open(&fx);
    let diff_style = repo
        .file_show(Some(change.clone()), &["conflicted.txt".to_owned()])
        .expect("show succeeds");
    assert_eq!(diff_style.files.len(), 1);
    assert!(diff_style.files[0].conflict, "the path is conflicted");
    let diff_bytes = diff_style.files[0].content.clone();
    assert!(
        diff_bytes.windows(7).any(|w| w == b"<<<<<<<"),
        "a materialized conflict carries markers"
    );
    assert!(
        !diff_bytes.windows(7).any(|w| w == b"|||||||"),
        "the diff style does not use Git's ancestor marker"
    );

    // The user's own config decides the style — re-read per call, never cached, so the same
    // handle sees the change without reopening.
    write_repo_config(&fx.path, "[ui]\nconflict-marker-style = \"git\"\n");
    let git_style = repo
        .file_show(Some(change), &["conflicted.txt".to_owned()])
        .expect("show succeeds");
    let git_bytes = git_style.files[0].content.clone();
    assert!(
        git_bytes.windows(7).any(|w| w == b"|||||||"),
        "the git style uses the ancestor marker"
    );
    assert_ne!(diff_bytes, git_bytes, "the config-derived style must change the output");
}

// ── file_annotate ─────────────────────────────────────────────────────────────────

#[test]
fn file_annotate_attributes_each_line_to_its_originating_commit() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let a = add_commit_with_files(&fx.path, &[], &[("a.txt", "one\ntwo\n")], "introduce a.txt");
    let b = add_commit_with_files(&fx.path, &[&a], &[("a.txt", "one\nCHANGED\n")], "edit line 2");
    let (a_change, b_change) = (change_id_of(&fx.path, &a), change_id_of(&fx.path, &b));
    let repo = open(&fx);
    let before = head_op_id(&repo);

    let lines = repo
        .file_annotate(Some(b_change.clone()), "a.txt")
        .expect("annotate succeeds");

    assert_eq!(lines.len(), 2, "one entry per line of the file");
    assert_eq!(lines[0].content, b"one\n".to_vec());
    assert_eq!(lines[0].commit_id.0, a, "the untouched line still belongs to A");
    assert_eq!(lines[0].change_id, a_change);
    assert_eq!(lines[0].original_line_number, 1, "line numbers are 1-based");
    assert!(lines[0].origin_found, "A is inside the all() domain");

    assert_eq!(lines[1].content, b"CHANGED\n".to_vec());
    assert_eq!(lines[1].commit_id.0, b, "the edited line belongs to B");
    assert_eq!(lines[1].change_id, b_change);
    assert_eq!(lines[1].original_line_number, 2);
    assert!(lines[1].origin_found);

    assert_eq!(head_op_id(&repo), before, "a read must not write an operation");
}

#[test]
fn file_annotate_refuses_an_absent_path_and_a_non_file() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);
    let before = head_op_id(&repo);

    let err = repo
        .file_annotate(Some(t.change.clone()), "nope.txt")
        .expect_err("an absent path is refused");
    assert!(
        matches!(&err, FileError::PathNotFound { path } if path == "nope.txt"),
        "unexpected error: {err:?}"
    );

    // A directory and a symlink are both "exists but is not a regular file".
    for path in ["dir", "link"] {
        let err = match repo.file_annotate(Some(t.change.clone()), path) {
            Ok(lines) => panic!("{path} must be refused, got Ok({lines:?})"),
            Err(e) => e,
        };
        assert!(
            matches!(&err, FileError::NotAFile { path: p } if p == path),
            "unexpected error for {path}: {err:?}"
        );
    }

    let err = repo
        .file_annotate(Some(t.change), "/absolute.txt")
        .expect_err("a leading slash is not a repo path");
    assert!(
        matches!(&err, FileError::InvalidInput { reason } if reason.contains("invalid path")),
        "unexpected error: {err:?}"
    );

    assert_eq!(head_op_id(&repo), before, "no refusal writes an operation");
}

#[test]
fn file_annotate_accepts_a_conflicted_file() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let merge_hex = add_conflicted_merge_off_root(&fx.path);
    let change = change_id_of(&fx.path, &merge_hex);
    let repo = open(&fx);

    // Every side is a file, so `to_file_merge()` is Some and the CLI accepts it too.
    let lines = repo
        .file_annotate(Some(change), "conflicted.txt")
        .expect("a file/file conflict annotates its materialized content");

    assert!(!lines.is_empty(), "the materialized conflict has lines");
    assert!(
        lines.iter().all(|l| l.original_line_number >= 1),
        "line numbers are 1-based"
    );
}

// ── file_search ───────────────────────────────────────────────────────────────────

#[test]
fn file_search_reports_one_match_per_matching_line() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);
    let before = head_op_id(&repo);

    let matches = repo
        .file_search(Some(t.change), "needle", &[], false)
        .expect("search succeeds");

    let found: Vec<(String, u32, Vec<u8>)> = matches
        .iter()
        .map(|m| (m.path.clone(), m.line_number, m.content.clone()))
        .collect();
    assert_eq!(
        found,
        vec![
            ("a.txt".to_owned(), 2, b"needle here\n".to_vec()),
            ("dir/nested/c.txt".to_owned(), 1, b"gamma needle\n".to_vec()),
        ],
        "a symlink whose TARGET contains the needle is never searched (CLI parity)"
    );
    assert!(matches.iter().all(|m| m.conflict_side.is_none()));
    assert_eq!(head_op_id(&repo), before, "a read must not write an operation");
}

#[test]
fn file_search_splits_the_pattern_kind_and_defaults_to_regex() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    let substring = repo
        .file_search(Some(t.change.clone()), "substring:ndl", &[], false)
        .expect("an explicit kind is honoured");
    assert!(substring.is_empty(), "'ndl' is not a substring of 'needle'");

    // The bare form is a REGEX, so a character class matches where a substring would not.
    let regex = repo
        .file_search(Some(t.change), "n[e]+dle", &[], false)
        .expect("a bare pattern is a regex");
    assert_eq!(regex.len(), 2, "the regex matches both files");
}

#[test]
fn file_search_refuses_an_unparseable_pattern() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);
    let before = head_op_id(&repo);

    let err = repo
        .file_search(Some(t.change), "(", &[], false)
        .expect_err("an unbalanced paren is not a valid regex");

    assert!(
        matches!(&err, FileError::InvalidInput { reason } if !reason.is_empty()),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&repo), before, "a refusal must not write an operation");
}

#[test]
fn file_search_name_only_stops_a_file_at_its_first_match() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    let commit = add_commit_with_files(
        &fx.path,
        &[],
        &[("many.txt", "needle 1\nneedle 2\nneedle 3\n")],
        "three matching lines",
    );
    let change = change_id_of(&fx.path, &commit);
    let repo = open(&fx);

    let all = repo
        .file_search(Some(change.clone()), "needle", &[], false)
        .expect("search succeeds");
    assert_eq!(all.len(), 3, "without name_only every matching line is reported");

    let first_only = repo
        .file_search(Some(change), "needle", &[], true)
        .expect("search succeeds");
    assert_eq!(
        first_only.len(),
        1,
        "name_only stops the file's scan at the first match"
    );
    assert_eq!(first_only[0].line_number, 1);
}

#[test]
fn file_search_numbers_conflict_sides_independently() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    // The right side additionally carries a resolved file, so the same call proves the
    // conflicted and resolved paths are numbered differently.
    let merge_hex = add_conflicted_merge_with_extra_files(&fx.path, &[("extra.txt", "left\n")]);
    let change = change_id_of(&fx.path, &merge_hex);
    let repo = open(&fx);

    let matches = repo
        .file_search(Some(change), "substring:left", &[], false)
        .expect("search succeeds");

    let conflicted: Vec<_> = matches.iter().filter(|m| m.path == "conflicted.txt").collect();
    assert_eq!(conflicted.len(), 1, "only one side of the conflict says 'left'");
    assert!(
        conflicted[0].conflict_side.is_some(),
        "a conflicted path names its 0-based side"
    );
    assert_eq!(
        conflicted[0].line_number, 1,
        "line numbers restart at each conflict side"
    );

    let resolved: Vec<_> = matches.iter().filter(|m| m.path == "extra.txt").collect();
    assert_eq!(resolved.len(), 1);
    assert_eq!(resolved[0].conflict_side, None, "a resolved file has no side");
}

#[test]
fn file_search_with_no_match_is_an_empty_success() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    let matches = repo
        .file_search(Some(t.change), "substring:definitely-not-present", &[], false)
        .expect("search succeeds");

    assert!(matches.is_empty(), "no match is an empty result, not an error");
}

#[test]
fn file_search_name_only_stops_a_conflicted_file_at_its_first_side() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    // `conflicted.txt` is "left\n" on one side and "right\n" on the other, so the substring
    // "t" matches on BOTH — the only way to observe the per-side early exit.
    let merge_hex = add_conflicted_merge_off_root(&fx.path);
    let change = change_id_of(&fx.path, &merge_hex);
    let repo = open(&fx);

    let both: Vec<_> = repo
        .file_search(Some(change.clone()), "substring:t", &[], false)
        .expect("search succeeds")
        .into_iter()
        .filter(|m| m.path == "conflicted.txt")
        .collect();
    assert_eq!(both.len(), 2, "without name_only every matching side reports");
    assert_ne!(
        both[0].conflict_side, both[1].conflict_side,
        "the two matches come from different sides"
    );

    let first: Vec<_> = repo
        .file_search(Some(change), "substring:t", &[], true)
        .expect("search succeeds")
        .into_iter()
        .filter(|m| m.path == "conflicted.txt")
        .collect();
    assert_eq!(
        first.len(),
        1,
        "--name-only names a FILE: one hit on any side ends the whole file"
    );
}

#[test]
fn file_search_refuses_a_malformed_path_filter() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    let err = repo
        .file_search(Some(t.change), "needle", &["dir/".to_owned()], false)
        .expect_err("a trailing slash is not a repo path");

    assert!(
        matches!(&err, FileError::InvalidInput { reason } if reason.contains("invalid path")),
        "unexpected error: {err:?}"
    );
}

// ── Repository corruption is Backend, never ChangeNotFound ────────────────────────

#[test]
fn a_corrupt_op_log_is_a_backend_error_not_a_missing_change() {
    pin_env();
    let t = mixed_tree();
    let repo = open(&t.fx);

    // Corrupt AFTER open: every read re-resolves to head per call (ADR-0002). This is the
    // `FileError::Backend` driver (`tests/view.rs::corrupt_op_heads`'s idiom). Reporting it
    // as `ChangeNotFound` would tell a GUI the user mistyped a revision when the repository
    // is in fact unreadable.
    fs::remove_dir_all(t.fx.path.join(".jj").join("repo").join("op_heads")).expect("op_heads is removable");

    let err = repo
        .file_list(Some(t.change), &[])
        .expect_err("head resolution must fail on a corrupt op log");

    assert!(matches!(&err, FileError::Backend(_)), "unexpected error: {err:?}");
}
