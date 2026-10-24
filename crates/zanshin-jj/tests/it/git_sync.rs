// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.5's two sync verbs: `Repo::git_import` and
//! `Repo::git_export`.
//!
//! Integration level is right: both entry points are public `Repo` methods, and every row
//! needs a real git-backed workspace whose BACKING git repo has refs jj has not seen (or
//! vice versa) — a state no fixture can carry.
//!
//! The backing git repo of a `Backend::Git` workspace lives at `.jj/repo/store/git`, and
//! every scenario is built by driving plain `git` against it in fixture setup only
//! (AR-AP-1's allowed exception, same as `tests/it/remotes_write.rs` and
//! `zanshin-ffi/tests/it/repo_write_ffi.rs`). Nothing under test shells out.
//!
//! Two assertions repeat throughout, because they are what NFR-R-2 pins: the op-log head
//! DESCRIPTION after a success (byte-identical to the CLI's), and that a refusal — or a
//! legitimate NO-OP — leaves the head op id untouched.

use std::fs;
use std::path::{Path, PathBuf};

use tempfile::TempDir;
use test_helpers::{add_commit_off_root, set_local_bookmark};
use zanshin_jj::{resolve_revset, Backend, ChangeId, GitRefUpdateKind, MutateError, Repo};

// ── Harness ───────────────────────────────────────────────────────────────────────

/// Run a git command in `dir`; panics on non-zero exit.
fn git_cmd(args: &[&str], dir: &Path) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// Run a git command and return `(success, trimmed stdout)`.
fn git_try(args: &[&str], dir: &Path) -> (bool, String) {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git command failed to spawn");
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    (out.status.success(), stdout)
}

/// The backing git repository of a `Backend::Git` workspace.
fn git_store(root: &Path) -> PathBuf {
    root.join(".jj").join("repo").join("store").join("git")
}

/// The head operation's id, so a test can assert that a refusal — or a no-op — wrote nothing.
fn head_op_id(repo: &mut Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).id.0
}

fn head_op_description(repo: &mut Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).description.clone()
}

/// The reverse-hex change id of `commit_hex`, via the crate's own revset resolver (a full
/// commit hex is a revset symbol) — no `jj_lib` import needed.
fn change_id_of(repo: &Repo, commit_hex: &str) -> ChangeId {
    let mut ids = resolve_revset(repo, commit_hex).expect("a commit hex resolves as a revset symbol");
    assert_eq!(ids.len(), 1, "a commit hex denotes exactly one change");
    ids.swap_remove(0)
}

fn write_repo_config(root: &Path, toml: &str) {
    fs::write(root.join(".jj").join("repo").join("config.toml"), toml).expect("repo config must be writable");
}

/// A git-backed workspace plus one commit `A` off root, with `A` NOT yet referenced by any
/// git ref. Returns the temp dir and `A`'s hex commit id.
fn git_repo_with_one_commit() -> (TempDir, String) {
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("git-backed init");
    let commit = add_commit_off_root(tmp.path(), "a commit only jj knows");
    (tmp, commit)
}

// ── git import ────────────────────────────────────────────────────────────────────

/// The row this verb exists for: a git ref jj has not imported becomes a jj bookmark, the
/// per-ref update is reported with `kind = New`, and a CLI-parity operation is written.
#[test]
fn git_import_imports_a_new_git_ref_and_writes_the_cli_operation() {
    test_helpers::pin_test_env();
    let (tmp, commit) = git_repo_with_one_commit();
    git_cmd(&["update-ref", "refs/heads/feature", &commit], &git_store(tmp.path()));

    let mut repo = Repo::open(tmp.path()).expect("reopen so the backend sees the new ref");
    let before = head_op_id(&mut repo);

    let result = repo.git_import().expect("import must succeed");

    assert_ne!(result.mutation.new_op_id.0, before, "a real import writes an operation");
    assert_eq!(
        head_op_description(&mut repo),
        "import git refs",
        "the op-log description is the CLI's own, byte-identical (NFR-R-2)"
    );

    let update = result
        .changed_bookmarks
        .iter()
        .find(|u| u.name == "feature")
        .expect("the new ref must be reported");
    assert_eq!(
        update.remote, "git",
        "a local git ref rides the reserved `git` pseudo-remote"
    );
    assert_eq!(update.kind, GitRefUpdateKind::New);
    assert!(
        update.tracked,
        "jj-lib tracks the local git repo's own bookmarks unconditionally"
    );
    assert!(result.changed_tags.is_empty());
    assert!(result.failed_ref_names.is_empty());
    assert_eq!(result.num_rewritten, 0);

    // The import is real, not cosmetic: the bookmark is now in jj's own listing.
    let names: Vec<String> = repo
        .list_bookmarks(&crate::all_remotes())
        .expect("bookmarks")
        .into_iter()
        .map(|b| b.name)
        .collect();
    assert!(names.contains(&"feature".to_owned()), "got {names:?}");
}

/// Nothing to import: no operation is written and `new_op_id` is the PRE-CALL head — the
/// CLI's own `!tx.repo().has_changes()` guard, not a synthetic "no-op" flag.
#[test]
fn git_import_with_nothing_to_import_writes_no_operation() {
    test_helpers::pin_test_env();
    let (tmp, commit) = git_repo_with_one_commit();
    git_cmd(&["update-ref", "refs/heads/feature", &commit], &git_store(tmp.path()));

    let mut repo = Repo::open(tmp.path()).expect("reopen");
    repo.git_import().expect("first import");
    let before = head_op_id(&mut repo);

    let result = repo.git_import().expect("second import must succeed");

    assert_eq!(
        result.mutation.new_op_id.0, before,
        "a legitimate no-op reports the PRE-CALL head"
    );
    assert_eq!(head_op_id(&mut repo), before, "the op log is byte-identical");
    assert!(result.changed_bookmarks.is_empty());
    assert!(result.changed_tags.is_empty());
    assert!(result.abandoned_change_ids.is_empty());
    assert!(result.failed_ref_names.is_empty());
}

/// A ref jj cannot import is NOT an error: the call succeeds and names the ref. This is the
/// reserved-namespace case (`refs/remotes/git/…`), which the CLI hints about separately.
/// It is also the "failed ref ONLY" row: nothing else changed, so no operation is written
/// AND the failure list is still reported.
#[test]
fn git_import_reports_a_reserved_namespace_ref_as_failed_without_writing_an_operation() {
    test_helpers::pin_test_env();
    let (tmp, commit) = git_repo_with_one_commit();
    git_cmd(
        &["update-ref", "refs/remotes/git/stolen", &commit],
        &git_store(tmp.path()),
    );

    let mut repo = Repo::open(tmp.path()).expect("reopen");
    let before = head_op_id(&mut repo);

    let result = repo.git_import().expect("a failed ref is not an error");
    let warnings = repo.take_warnings();

    assert_eq!(
        result.failed_ref_names,
        vec!["refs/remotes/git/stolen".to_owned()],
        "the only record that a ref could not be synced must ride the payload"
    );
    // Story 9.32: `print_failed_git_import`'s block, even though nothing was written.
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, zanshin_jj::WarningKind::GitImportFailed);
    assert_eq!(
        warnings[0].message,
        "Failed to import some Git refs:\n  refs/remotes/git/stolen"
    );
    assert_eq!(
        result.mutation.new_op_id.0, before,
        "nothing else changed, so nothing was written"
    );
    assert_eq!(head_op_id(&mut repo), before);
}

/// The working copy itself becomes unreachable in git and is abandoned; jj-lib mints a
/// replacement `@`, and the result names both facts. This is the case the CLI's own doc
/// calls out: "If a working-copy commit gets abandoned, it will be given a new, empty
/// commit."
#[test]
fn git_import_abandoning_the_working_copy_reports_it_and_moves_at() {
    test_helpers::pin_test_env();
    let (tmp, commit) = git_repo_with_one_commit();
    let store = git_store(tmp.path());
    git_cmd(&["update-ref", "refs/heads/feature", &commit], &store);

    let mut repo = Repo::open(tmp.path()).expect("reopen");
    repo.git_import().expect("import the ref so jj knows the commit");

    // Park `@` ON the commit the ref pins, then take the ref away.
    let change = change_id_of(&repo, &commit);
    repo.edit(change.clone()).expect("edit onto the imported commit");
    git_cmd(&["update-ref", "-d", "refs/heads/feature"], &store);

    let result = repo.git_import().expect("second import must succeed");

    // The ref went away, so this run also exercises the `(false, true) => Deleted` arm.
    let update = result
        .changed_bookmarks
        .iter()
        .find(|u| u.name == "feature")
        .expect("the vanished ref must be reported");
    assert_eq!(update.kind, GitRefUpdateKind::Deleted);
    assert_eq!(update.remote, "git");
    assert_eq!(
        result.abandoned_change_ids,
        vec![change.clone()],
        "the commit that lost its only git ref is abandoned"
    );
    assert_ne!(
        result.mutation.working_copy_change_id,
        Some(change),
        "an abandoned `@` is replaced by a fresh, empty commit"
    );
    // The on-disk working copy really moved, not just the view: a fresh handle agrees.
    let mut reopened = Repo::open(tmp.path()).expect("reopen");
    assert_eq!(
        Some(reopened.status().expect("status").working_copy_change_id),
        result.mutation.working_copy_change_id
    );
}

/// `git.abandon-unreachable-commits = false` must actually be honoured — the option is read
/// from the repo's EFFECTIVE config, never hardcoded (FR-JJ-17). Same scenario as the row
/// above, opposite outcome.
#[test]
fn git_import_honours_abandon_unreachable_commits_false() {
    test_helpers::pin_test_env();
    let (tmp, commit) = git_repo_with_one_commit();
    let store = git_store(tmp.path());
    git_cmd(&["update-ref", "refs/heads/feature", &commit], &store);

    let mut repo = Repo::open(tmp.path()).expect("reopen");
    repo.git_import().expect("import the ref");
    let change = change_id_of(&repo, &commit);
    repo.edit(change.clone()).expect("edit onto the imported commit");
    git_cmd(&["update-ref", "-d", "refs/heads/feature"], &store);

    write_repo_config(tmp.path(), "[git]\nabandon-unreachable-commits = false\n");
    let mut repo = Repo::open(tmp.path()).expect("reopen with the new repo config");

    let result = repo.git_import().expect("second import must succeed");

    assert!(
        result.abandoned_change_ids.is_empty(),
        "the user disabled abandoning; nothing may be abandoned"
    );
    assert_eq!(
        result.mutation.working_copy_change_id,
        Some(change),
        "`@` stays exactly where the user left it"
    );
}

/// A malformed value for a key this verb reads must arrive as `Config`, the same fault class
/// the read side reports — never the unclassified `Backend` bucket — and must write nothing.
///
/// Since Story 9.27 the stack is also what the workspace is LOADED with, and jj-lib's git
/// backend reads this key itself while loading — so the refusal comes from the pre-verb
/// settings refresh (the stack changed after open), and a fresh `Repo::open` refuses too,
/// exactly as every CLI command in such a repo fails at start-up.
#[test]
fn git_import_with_a_non_boolean_config_value_refuses_as_config() {
    test_helpers::pin_test_env();
    let (tmp, _commit) = git_repo_with_one_commit();
    let mut repo = Repo::open(tmp.path()).expect("open before the config breaks");
    let before = head_op_id(&mut repo);
    write_repo_config(tmp.path(), "[git]\nabandon-unreachable-commits = \"yes\"\n");

    let err = repo.git_import().expect_err("a wrong-typed value must refuse");

    assert!(
        matches!(&err, MutateError::Precondition(zanshin_jj::PreconditionError::Config { reason }) if reason.contains("abandon-unreachable-commits")),
        "unexpected error: {err:?}"
    );
    let reopen = Repo::open(tmp.path()).expect_err("a wrong-typed git key must refuse the open too");
    assert!(
        matches!(&reopen, zanshin_jj::RepoError::Config { reason } if reason.contains("abandon-unreachable-commits")),
        "unexpected error: {reopen:?}"
    );
    // Every verb refuses while the stack is broken, so it is repaired before the read-back.
    write_repo_config(tmp.path(), "");
    assert_eq!(head_op_id(&mut repo), before, "a refusal writes nothing");
}

/// A native (`init_simple`) workspace has no git backend at all, so both sync verbs refuse
/// with the answerable code rather than an opaque jj-lib string.
#[test]
fn git_import_and_export_refuse_a_native_backend() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .expect("native init");
    let mut repo = Repo::open(tmp.path()).expect("reopen");
    let before = head_op_id(&mut repo);

    assert!(
        matches!(
            repo.git_import().expect_err("a native repo has no git refs to import"),
            MutateError::NotAGitRepo
        ),
        "import must refuse"
    );
    assert!(
        matches!(
            repo.git_export().expect_err("a native repo has no git refs to export"),
            MutateError::NotAGitRepo
        ),
        "export must refuse"
    );
    assert_eq!(head_op_id(&mut repo), before, "neither refusal writes an operation");
}

// ── git export ────────────────────────────────────────────────────────────────────

/// The row this verb exists for: a jj local bookmark that git has never seen appears as
/// `refs/heads/<name>` in the backing repo, and a CLI-parity operation is written.
///
/// `export_refs` is called NOWHERE else in this crate, so without this verb a colocated
/// Zanshin workspace would never write its bookmarks back to git at all.
#[test]
fn git_export_writes_a_jj_bookmark_into_the_backing_git_repo() {
    test_helpers::pin_test_env();
    let (tmp, commit) = git_repo_with_one_commit();
    set_local_bookmark(tmp.path(), "shipped", &[&commit]);

    let mut repo = Repo::open(tmp.path()).expect("reopen");
    let before = head_op_id(&mut repo);

    let result = repo.git_export().expect("export must succeed");

    assert_ne!(result.mutation.new_op_id.0, before, "a real export writes an operation");
    assert_eq!(
        head_op_description(&mut repo),
        "export git refs",
        "the op-log description is the CLI's own, byte-identical (NFR-R-2)"
    );
    assert!(result.failed_bookmarks.is_empty());
    assert!(result.failed_tags.is_empty());

    let (ok, out) = git_try(&["show-ref", "refs/heads/shipped"], &git_store(tmp.path()));
    assert!(ok, "git must now hold refs/heads/shipped");
    assert!(
        out.starts_with(&commit),
        "the ref must point at the commit, got {out:?}"
    );
}

/// Nothing to export: no operation is written and `new_op_id` is the PRE-CALL head.
#[test]
fn git_export_with_nothing_to_export_writes_no_operation() {
    test_helpers::pin_test_env();
    let (tmp, commit) = git_repo_with_one_commit();
    set_local_bookmark(tmp.path(), "shipped", &[&commit]);

    let mut repo = Repo::open(tmp.path()).expect("reopen");
    repo.git_export().expect("first export");
    let before = head_op_id(&mut repo);

    let result = repo.git_export().expect("second export must succeed");

    assert_eq!(
        result.mutation.new_op_id.0, before,
        "a legitimate no-op reports the PRE-CALL head"
    );
    assert_eq!(head_op_id(&mut repo), before, "the op log is byte-identical");
}

/// A bookmark git cannot hold is NOT an error: the call succeeds and the failure rides the
/// payload with its whole flattened reason chain. Git stores refs as files, so `foo` and
/// `foo/bar` cannot both exist — the exact case the CLI prints a hint for.
#[test]
fn git_export_reports_a_conflicting_ref_name_as_a_failure_and_still_succeeds() {
    test_helpers::pin_test_env();
    let (tmp, commit) = git_repo_with_one_commit();
    set_local_bookmark(tmp.path(), "foo", &[&commit]);
    set_local_bookmark(tmp.path(), "foo/bar", &[&commit]);

    let mut repo = Repo::open(tmp.path()).expect("reopen");
    let before = head_op_id(&mut repo);
    let result = repo.git_export().expect("a failed ref is not an error");
    // Taken right away: the op-log reads below are verbs of their own and start a fresh list.
    let warnings = repo.take_warnings();

    // A PARTLY-failed export still exported something, so it must still write the CLI's own
    // operation — a failure list is not a refusal (module doc's second invariant).
    assert_ne!(result.mutation.new_op_id.0, before);
    assert_eq!(head_op_description(&mut repo), "export git refs");
    assert_eq!(
        result.failed_bookmarks.len(),
        1,
        "exactly one of the two names can survive, got {:?}",
        result.failed_bookmarks
    );
    let failure = &result.failed_bookmarks[0];
    assert_eq!(failure.name, "foo/bar", "jj-lib exports in symbol order, so `foo` wins");
    assert_eq!(failure.remote, "git");
    assert!(
        failure.reason.contains(": "),
        "the reason must be the FLATTENED source chain, not just the top-level Display: {:?}",
        failure.reason
    );

    // Story 9.32: the CLI's `print_git_export_stats` block for the same failure — the ONLY
    // warning, since the verb itself (not a colocated finish) ran the export.
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, zanshin_jj::WarningKind::GitExportFailed);
    assert_eq!(
        warnings[0].message,
        format!("Failed to export some bookmarks:\n  foo/bar@git: {}", failure.reason)
    );

    // The other bookmark still exported — a failure does not abort the run.
    let (ok, _) = git_try(&["show-ref", "refs/heads/foo"], &git_store(tmp.path()));
    assert!(ok, "the exportable bookmark must still have been written");
}

/// The `Updated` arm: an already-imported ref that moves to a different commit. Without
/// this row only `New` and `Deleted` are ever observed, so the `(false, false)` arm's
/// classification is unpinned.
#[test]
fn git_import_reports_a_moved_ref_as_updated() {
    test_helpers::pin_test_env();
    let (tmp, first) = git_repo_with_one_commit();
    let store = git_store(tmp.path());
    git_cmd(&["update-ref", "refs/heads/feature", &first], &store);

    let mut repo = Repo::open(tmp.path()).expect("reopen");
    repo.git_import().expect("first import establishes the old target");

    // A SECOND commit for the ref to move to, then re-import.
    let second = add_commit_off_root(tmp.path(), "the ref's new target");
    git_cmd(&["update-ref", "refs/heads/feature", &second], &store);
    let mut repo = Repo::open(tmp.path()).expect("reopen so the backend sees the moved ref");

    let result = repo.git_import().expect("second import must succeed");

    let update = result
        .changed_bookmarks
        .iter()
        .find(|u| u.name == "feature")
        .expect("the moved ref must be reported");
    assert_eq!(
        update.kind,
        GitRefUpdateKind::Updated,
        "old and new targets both present => Updated"
    );
    assert_eq!(update.remote, "git");
    assert!(update.tracked);
}

/// TAGS take a different branch of the projection than bookmarks — the tracking flag is
/// read from `get_remote_tag`, not `get_remote_bookmark`. Without a real imported tag that
/// branch is never executed, so swapping the two lookups would go unnoticed.
#[test]
fn git_import_projects_a_real_git_tag_through_the_tag_branch() {
    test_helpers::pin_test_env();
    let (tmp, commit) = git_repo_with_one_commit();
    git_cmd(&["update-ref", "refs/tags/v1", &commit], &git_store(tmp.path()));

    let mut repo = Repo::open(tmp.path()).expect("reopen");
    let result = repo.git_import().expect("import must succeed");

    assert_eq!(result.changed_tags.len(), 1, "got {:?}", result.changed_tags);
    let tag = &result.changed_tags[0];
    assert_eq!(tag.name, "v1");
    assert_eq!(tag.remote, "git");
    assert_eq!(tag.kind, GitRefUpdateKind::New);
    assert!(
        tag.tracked,
        "jj-lib tracks remote tags unconditionally (`default_remote_ref_state_for`), which is \
         what the tag branch of the projection must report"
    );
    assert!(
        result.changed_bookmarks.is_empty(),
        "a tag must not leak into the bookmark vector"
    );
}

/// The second key `config::git_import_options` reads. Mirrors the
/// `abandon-unreachable-commits` row: a wrong-typed value is the SAME fault class, so
/// leaving it untested would let a mis-keyed lookup ship silently.
#[test]
fn git_import_with_a_non_boolean_record_synthetic_predecessors_refuses_as_config() {
    test_helpers::pin_test_env();
    let (tmp, _commit) = git_repo_with_one_commit();
    let mut repo = Repo::open(tmp.path()).expect("open before the config breaks");
    let before = head_op_id(&mut repo);
    write_repo_config(tmp.path(), "[git]\nrecord-synthetic-predecessors = 3\n");

    let err = repo.git_import().expect_err("a wrong-typed value must refuse");

    assert!(
        matches!(&err, MutateError::Precondition(zanshin_jj::PreconditionError::Config { reason }) if reason.contains("record-synthetic-predecessors")),
        "unexpected error: {err:?}"
    );
    write_repo_config(tmp.path(), "");
    assert_eq!(head_op_id(&mut repo), before, "a refusal writes nothing");
}

// ── Colocated: the pre-verb snapshot did the work ────────────────────────────────

/// In a colocated workspace the CLI skips `jj git import`/`jj git export` (exit 0), because
/// its per-command snapshot has already imported the refs and every `finish_transaction`
/// exports them. Zanshin runs the same pre-verb snapshot and finish (Story 9.26), so both verbs
/// find NOTHING left to do — the CLI's observable end state — while the snapshot's own report
/// carries the import, and the finish of its `import git refs` operation carried the export.
#[test]
fn both_sync_verbs_find_nothing_left_in_a_colocated_workspace() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    // A real git repo with one commit on `main`, converted in place — `.git` and `.jj` now
    // share the same object store, which is what "colocated" means.
    git_cmd(&["init", "--initial-branch=main"], tmp.path());
    git_cmd(&["config", "user.email", "test@zanshin.test"], tmp.path());
    git_cmd(&["config", "user.name", "Fixture"], tmp.path());
    fs::write(tmp.path().join("README.md"), "hello").expect("write README");
    git_cmd(&["add", "."], tmp.path());
    git_cmd(&["commit", "-m", "initial"], tmp.path());
    zanshin_jj::convert_colocated(tmp.path())
        .result
        .expect("convert to colocated");

    let head = {
        let out = std::process::Command::new("git")
            .args(["rev-parse", "HEAD"])
            .current_dir(tmp.path())
            .output()
            .expect("git rev-parse");
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    };
    // A git ref the conversion did not import, and a jj bookmark git has never seen.
    git_cmd(&["update-ref", "refs/heads/colocated-only", &head], tmp.path());
    set_local_bookmark(tmp.path(), "from-jj", &[&head]);

    let mut repo = Repo::open(tmp.path()).expect("open the colocated workspace");

    let imported = repo.git_import().expect("import runs");
    assert!(
        imported.changed_bookmarks.is_empty(),
        "the pre-verb snapshot already imported everything; got {:?}",
        imported.changed_bookmarks
    );
    let precondition = repo.take_precondition().expect("git_import runs the precondition");
    let refs = precondition
        .git_refs
        .expect("a colocated precondition imports the refs");
    assert!(
        refs.changed_bookmarks.iter().any(|u| u.name == "colocated-only"),
        "the snapshot's `import git refs` step imported the git-only branch; got {:?}",
        refs.changed_bookmarks
    );
    assert_eq!(
        imported.mutation.new_op_id.0, refs.mutation.new_op_id.0,
        "git_import itself wrote no operation"
    );
    let (ok, _) = git_try(&["show-ref", "refs/heads/from-jj"], tmp.path());
    assert!(
        ok,
        "the jj-only bookmark was exported by the finish of the snapshot's refs operation"
    );

    let before_export = head_op_id(&mut repo);
    let exported = repo.git_export().expect("export runs");
    assert!(exported.failed_bookmarks.is_empty(), "got {exported:?}");
    assert_eq!(
        exported.mutation.new_op_id.0, before_export,
        "nothing was left to export, so no operation was written"
    );
}

/// Story 9.56 / the 9.30 follow-up: `git import` of a same-change-id rewrite — the backing Git
/// ref moved to a copy of a jj commit that keeps its `change-id` header — counts it in
/// `num_rewritten` (jj-lib's `record_synthetic_predecessors`) and rebases `@`, a child of the
/// old commit, onto the rewrite.
#[test]
fn git_import_counts_a_same_change_id_rewrite_and_rebases_the_child() {
    test_helpers::pin_test_env();
    let (tmp, x) = git_repo_with_one_commit();
    let store = git_store(tmp.path());
    git_cmd(&["update-ref", "refs/heads/feat", &x], &store);
    let mut repo = Repo::open(tmp.path()).expect("reopen so the backend sees the new ref");
    assert_eq!(repo.git_import().expect("first import").num_rewritten, 0);
    let x_change = change_id_of(&repo, &x);
    repo.new_change(&[x_change], &[], &[]).expect("a child of X");

    let (ok, text) = git_try(&["cat-file", "commit", &x], &store);
    assert!(ok, "cat-file");
    let (headers, _) = text.split_once("\n\n").expect("a commit has a message");
    assert!(
        headers.contains("\nchange-id "),
        "a jj-written commit carries its change id: {headers}"
    );
    let mut hash = std::process::Command::new("git")
        .args(["hash-object", "-t", "commit", "-w", "--stdin"])
        .current_dir(&store)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("git spawns");
    std::io::Write::write_all(
        hash.stdin.as_mut().expect("stdin"),
        format!("{headers}\n\nX, rewritten\n").as_bytes(),
    )
    .expect("write the commit");
    let out = hash.wait_with_output().expect("git hash-object");
    assert!(out.status.success(), "hash-object");
    let rewritten = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    git_cmd(&["update-ref", "refs/heads/feat", &rewritten], &store);

    let mut repo = Repo::open(tmp.path()).expect("reopen so the backend sees the moved ref");
    let result = repo.git_import().expect("import");

    assert_eq!(result.num_rewritten, 1);
    let mut parents = Vec::new();
    let _ = repo
        .eval_revset("@-", |change| {
            parents.push(change.commit_id.0);
            std::ops::ControlFlow::Continue(())
        })
        .expect("eval");
    assert_eq!(parents, [rewritten], "@ sits on the rewrite");
}

/// Story 9.56: a `git import` with nothing to import says "Nothing changed." without resolving
/// the immutable set, as the CLI's `tx.finish` — an unresolvable `immutable_heads()` alias does
/// not refuse it — while an import that changes something refuses `Config`, writing nothing.
#[test]
fn git_import_resolves_the_immutable_set_only_when_it_changes_something() {
    test_helpers::pin_test_env();
    let (tmp, commit) = git_repo_with_one_commit();
    write_repo_config(
        tmp.path(),
        "[revset-aliases]\n\"immutable_heads()\" = \"nonexistent_symbol_xyz\"\n",
    );
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&mut repo);
    let idle = repo.git_import().expect("a no-op import succeeds");
    assert_eq!(idle.mutation.new_op_id.0, before, "and writes nothing");
    let idle = repo.git_export().expect("a no-op export succeeds");
    assert_eq!(idle.mutation.new_op_id.0, before, "and writes nothing");

    git_cmd(&["update-ref", "refs/heads/feature", &commit], &git_store(tmp.path()));
    let mut repo = Repo::open(tmp.path()).expect("reopen so the backend sees the new ref");
    let err = repo.git_import().expect_err("an import with changes resolves the set");
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");
    assert_eq!(head_op_id(&mut repo), before, "a refusal writes no operation");
}
