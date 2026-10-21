// SPDX-License-Identifier: MIT

//! Witness suite for Epic 9 follow-up L: every operation a Zanshin verb writes records
//! `op_metadata.workspace_name`, the way a `jj`-written one does.
//!
//! The jj CLI opens every transaction through `cli/src/cli_util.rs:2883` `start_repo_transaction`,
//! which calls `Transaction::set_workspace_name`. The op log is on-disk state a user reads back
//! with `jj op log`/`jj op show` and that multi-workspace repos rely on, so the metadata is
//! required parity (NFR-R-2) — not decoration. Before this run every Zanshin operation carried
//! `workspace_name: None`.
//!
//! The assertion is deliberately made against jj-lib DIRECTLY rather than through
//! `Repo::op_log`: `crate::Operation` does not carry the field (exposing it is Story 9.21's
//! surface), and reading the store is the same oracle `jj op show` reads. Every row therefore
//! loads the workspace with `jj_lib::workspace::Workspace::load` and walks
//! `load_at_head().operation()`.
//!
//! ## Why one row per FAMILY and not per verb
//!
//! Only five modules open a transaction. `bookmark_ops.rs` (`bookmark_create`/`delete`) and
//! `git.rs` (`git_import`/`export`, `git_remote_add`/`remove`/`rename`/`set_url`) open none of
//! their own: all eleven of those verbs funnel through the one skeleton
//! `mutate::finish_or_no_op_at`. So `bookmark_create` and `git_import` below witness the same
//! single opener as `git_remote_add` does, and the verbs not listed here — `new_change`, `edit`,
//! `abandon`, `restore`, `absorb`, `git_export`, `bookmark_delete`, the three remaining remote
//! verbs — reach an opener some row already pins. The creep guard in `op_support.rs` is what
//! keeps that funnel argument true.
//!
//! Fixture setup shells out to plain `git` (AR-AP-1's allowed exception, as in
//! `tests/it/convert.rs` and `tests/it/remotes_write.rs`); nothing under test does. No row touches the
//! network — the only remote is a local bare clone.

use std::fs;
use std::path::{Path, PathBuf};

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::{add_workspace, extract_fixture};
use zanshin_jj::{convert_colocated, convert_import, resolve_revset, Backend, ChangeId, Repo};

// ── Harness ───────────────────────────────────────────────────────────────────────

/// The oracle: `workspace_name` on the newest operation of the workspace at `root`.
///
/// `None` is exactly the pre-fix state — an operation Zanshin opened without naming its
/// workspace — so every row asserts a `Some`.
fn head_op_workspace_name(root: &Path) -> Option<String> {
    recent_ops(root, 1).swap_remove(0).1
}

/// `(description, workspace_name)` for the newest `limit` operations, newest first, walking the
/// op log's FIRST parent — the rows a convert verb needs, which asserts more than one operation.
///
/// `limit` is a cap, not a search depth: the walk also stops at the root operation. A converted
/// repo's whole op log is four entries (head import, refs import, `add workspace 'default'`,
/// root), so the convert rows pass 4 and reach the root either way; the cap only keeps a row on
/// a larger repo from walking the entire history.
fn recent_ops(root: &Path, limit: usize) -> Vec<(String, Option<String>)> {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head");

    let mut op = repo.operation().clone();
    let mut rows = Vec::new();
    while rows.len() < limit {
        let metadata = op.metadata();
        rows.push((
            metadata.description.clone(),
            metadata.workspace_name.as_ref().map(|n| n.as_str().to_owned()),
        ));
        let Some(parent) = pollster::block_on(op.parents())
            .expect("op parents are readable")
            .into_iter()
            .next()
        else {
            break;
        };
        op = parent;
    }
    rows
}

/// Asserts that `description` appears among `rows` and carries `expected` as its workspace name.
fn assert_op_named(rows: &[(String, Option<String>)], description: &str, expected: &str) {
    let row = rows
        .iter()
        .find(|(desc, _)| desc == description)
        .unwrap_or_else(|| panic!("no `{description}` operation among {rows:?}"));
    assert_eq!(
        row.1.as_deref(),
        Some(expected),
        "`{description}` must record the workspace name, as the CLI's does"
    );
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

/// The backing git repository of a `Backend::Git` workspace.
fn git_store(root: &Path) -> PathBuf {
    root.join(".jj").join("repo").join("store").join("git")
}

/// A plain Git repo at `path` with one commit on `main`.
fn init_git_repo_with_commit(path: &Path) {
    git_cmd(&["init", "--initial-branch=main"], path);
    git_cmd(&["config", "user.email", "test@zanshin.test"], path);
    git_cmd(&["config", "user.name", "Fixture"], path);
    fs::write(path.join("README.md"), "hello").expect("write README");
    git_cmd(&["add", "."], path);
    git_cmd(&["commit", "-m", "initial"], path);
}

/// The change id of `@` in the workspace at `root`, via the crate's own revset resolver.
fn working_copy_change(repo: &Repo) -> ChangeId {
    let mut ids = resolve_revset(repo, "@").expect("`@` resolves");
    assert_eq!(ids.len(), 1, "`@` denotes exactly one change");
    ids.swap_remove(0)
}

/// An empty git-backed workspace — `Repo::init` only, so its op log is `add workspace 'default'`
/// over the root op and `@` is the initial empty change.
fn git_workspace() -> TempDir {
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("git-backed init");
    tmp
}

// ── Mutate family ─────────────────────────────────────────────────────────────────

#[test]
fn describe_names_the_workspace() {
    test_helpers::pin_test_env();
    let tmp = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    let change = working_copy_change(&repo);

    repo.describe(change, "a description").expect("describe succeeds");

    assert_eq!(head_op_workspace_name(tmp.path()).as_deref(), Some("default"));
}

// ── Bookmark family ───────────────────────────────────────────────────────────────

#[test]
fn bookmark_create_names_the_workspace() {
    test_helpers::pin_test_env();
    let tmp = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");

    repo.bookmark_create(&["feature".to_owned()], None)
        .expect("bookmark_create succeeds");

    assert_eq!(head_op_workspace_name(tmp.path()).as_deref(), Some("default"));
}

// ── Git sync family ───────────────────────────────────────────────────────────────

#[test]
fn git_import_names_the_workspace() {
    test_helpers::pin_test_env();
    let tmp = git_workspace();
    let commit = test_helpers::add_commit_off_root(tmp.path(), "a commit only jj knows");
    git_cmd(&["update-ref", "refs/heads/feature", &commit], &git_store(tmp.path()));

    let mut repo = Repo::open(tmp.path()).expect("reopen so the backend sees the new ref");
    repo.git_import().expect("import succeeds");

    let rows = recent_ops(tmp.path(), 1);
    assert_op_named(&rows, "import git refs", "default");
}

// ── Remote-config family ──────────────────────────────────────────────────────────

#[test]
fn git_remote_add_names_the_workspace() {
    test_helpers::pin_test_env();
    let tmp = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");

    repo.git_remote_add("origin", "file:///nowhere/bare.git", None)
        .expect("git_remote_add succeeds");

    assert_eq!(head_op_workspace_name(tmp.path()).as_deref(), Some("default"));
}

// ── Fetch (remotes.rs) ────────────────────────────────────────────────────────────

#[test]
fn git_fetch_names_the_workspace() {
    test_helpers::pin_test_env();
    let src = TempDir::new().expect("src tempdir");
    init_git_repo_with_commit(src.path());

    let parent = TempDir::new().expect("bare parent tempdir");
    let bare = parent.path().join("bare.git");
    git_cmd(
        &[
            "clone",
            "--bare",
            &src.path().to_string_lossy(),
            &bare.to_string_lossy(),
        ],
        parent.path(),
    );

    let tmp = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &bare.to_string_lossy(), None)
        .expect("git_remote_add succeeds");

    let mut repo = Repo::open(tmp.path()).expect("reopen so the backend sees the remote");
    let noop = |_: zanshin_jj::ProgressEvent| {};
    repo.git_fetch(&zanshin_jj::GitFetchArgs::default(), &noop, None)
        .expect("git_fetch succeeds");

    let rows = recent_ops(tmp.path(), 1);
    assert_op_named(&rows, "fetch from git remote(s) origin", "default");
}

// ── Undo (op_log.rs) ──────────────────────────────────────────────────────────────

#[test]
fn undo_names_the_workspace() {
    test_helpers::pin_test_env();
    let tmp = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    let change = working_copy_change(&repo);
    repo.describe(change, "a description").expect("describe succeeds");

    repo.undo(false).expect("undo succeeds");

    assert_eq!(head_op_workspace_name(tmp.path()).as_deref(), Some("default"));
}

// ── Clone (repo.rs) ───────────────────────────────────────────────────────────────

#[test]
fn clone_names_the_workspace() {
    test_helpers::pin_test_env();
    let src = TempDir::new().expect("src tempdir");
    init_git_repo_with_commit(src.path());

    let target = TempDir::new().expect("target tempdir");
    let url = format!("file://{}", src.path().display());
    Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from(&url),
            destination: std::path::PathBuf::from(target.path()),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result
    .expect("clone from local file://");

    assert_eq!(head_op_workspace_name(target.path()).as_deref(), Some("default"));
}

// ── Convert (convert.rs) ──────────────────────────────────────────────────────────

/// The colocated conversion writes TWO operations and both must carry the name — the reason
/// `init_git_refs` and `import_git_head` each grew a `workspace_name` parameter.
#[test]
fn convert_colocated_names_the_workspace_on_both_operations() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    init_git_repo_with_commit(tmp.path());

    convert_colocated(tmp.path()).result.expect("conversion succeeds");

    let rows = recent_ops(tmp.path(), 4);
    assert_op_named(&rows, "import git refs", "default");
    assert_op_named(&rows, "import git head", "default");
}

#[test]
fn convert_import_names_the_workspace_on_both_operations() {
    test_helpers::pin_test_env();
    let src = TempDir::new().expect("src tempdir");
    init_git_repo_with_commit(src.path());

    let dest_parent = TempDir::new().expect("dest tempdir");
    let dest = dest_parent.path().join("imported");

    convert_import(src.path(), &dest).result.expect("import succeeds");

    let rows = recent_ops(&dest, 4);
    assert_op_named(&rows, "import git refs", "default");
    assert_op_named(&rows, "import git head", "default");
}

// ── Second workspace ──────────────────────────────────────────────────────────────

/// The row a hardcoded `"default"` — or a name read from the repo rather than from the
/// workspace handle the verb was invoked through — fails, and fails nowhere else.
#[test]
fn a_verb_run_in_a_second_workspace_records_that_workspace() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
    // The handle keeps the second workspace's directory alive for the test's duration.
    let (second, _second_wc) = add_workspace(&fx.path, "second");

    let mut repo = Repo::open(&second.path).expect("open at the SECOND workspace root");
    let change = working_copy_change(&repo);
    repo.describe(change, "described from the second workspace")
        .expect("describe succeeds");

    assert_eq!(
        head_op_workspace_name(&second.path).as_deref(),
        Some("second"),
        "the operation must name the workspace it ran in — a hardcoded `default`, or a name read \
         from anywhere but the workspace handle, shows up exactly here"
    );
}

/// The same anti-requirement at the three OTHER openers a wrong name could hide in, because
/// every row above runs in a workspace that is literally called `default` and so cannot tell a
/// sourced name from a constant one.
///
/// The three are `mutate::finish_or_no_op_at` (the skeleton all eleven bookmark and git verbs
/// funnel through), `op_log.rs`'s `undo`, and `remotes.rs`'s `git_fetch` — the one site that
/// passes `workspace.workspace_name()` inline rather than a name captured earlier. Substituting
/// `WorkspaceName::DEFAULT` at any of them compiles and leaves every `default`-named row green.
///
/// `convert.rs`'s three sites and `repo.rs`'s clone CREATE the workspace they name, so `default`
/// is the only answer they can give and no second-workspace row can exist for them.
#[test]
fn the_shared_funnel_undo_and_fetch_also_record_the_second_workspace() {
    test_helpers::pin_test_env();
    let src = TempDir::new().expect("src tempdir");
    init_git_repo_with_commit(src.path());
    let parent = TempDir::new().expect("bare parent tempdir");
    let bare = parent.path().join("bare.git");
    git_cmd(
        &[
            "clone",
            "--bare",
            &src.path().to_string_lossy(),
            &bare.to_string_lossy(),
        ],
        parent.path(),
    );

    let tmp = git_workspace();
    // The handle keeps the second workspace's directory alive for the test's duration.
    let (second, _second_wc) = add_workspace(tmp.path(), "second");

    // `mutate::finish_or_no_op_at`, reached here through `bookmark_ops::create`.
    let mut repo = Repo::open(&second.path).expect("open at the SECOND workspace root");
    repo.bookmark_create(&["feature".to_owned()], None)
        .expect("bookmark_create succeeds");
    assert_eq!(head_op_workspace_name(&second.path).as_deref(), Some("second"));

    // `op_log.rs::undo`.
    repo.undo(false).expect("undo succeeds");
    assert_eq!(head_op_workspace_name(&second.path).as_deref(), Some("second"));

    // `remotes.rs::git_fetch` — reopened first, so the backend reads the remote off disk.
    repo.git_remote_add("origin", &bare.to_string_lossy(), None)
        .expect("git_remote_add succeeds");
    let mut repo = Repo::open(&second.path).expect("reopen so the backend sees the remote");
    let noop = |_: zanshin_jj::ProgressEvent| {};
    repo.git_fetch(&zanshin_jj::GitFetchArgs::default(), &noop, None)
        .expect("git_fetch succeeds");
    assert_eq!(head_op_workspace_name(&second.path).as_deref(), Some("second"));
}
