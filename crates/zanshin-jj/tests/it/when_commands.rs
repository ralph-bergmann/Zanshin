// SPDX-License-Identifier: MIT

//! Story 9.41 witness: a `[[--scope]]` with `--when.commands` applies to the verbs that play that
//! CLI command and to no other — as the CLI names its command before its final start-up
//! resolution (`cli/src/cli_util.rs:4701` @ v0.46.0). What a verb wrote is read back from the store.
//!
//! Each test runs in its own process (`test_helpers::own_process!`): it repoints `JJ_CONFIG` at a
//! user file of its own (never unsets it), points `XDG_CONFIG_HOME` into a temp dir, and REMOVES
//! the identity overrides the suite pins (`JJ_USER`, `JJ_EMAIL`, `JJ_OP_HOSTNAME`,
//! `JJ_OP_USERNAME`) — they sit above every file layer and would hide the scoped values.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;
use zanshin_jj::{resolve_revset, Backend, ChangeId, InitOptions, MutateError, PreconditionError, Repo, RepoError};

/// Sets (or, for `None`, removes) one process environment variable.
fn set_env(name: &str, value: Option<&str>) {
    // SAFETY: single-threaded — each test runs alone in its own process (`own_process!`), and
    // every change happens between the verbs that read the environment.
    unsafe {
        match value {
            Some(v) => env::set_var(name, v),
            None => env::remove_var(name),
        }
    }
}

/// Isolates the process environment into `tmp` and returns the user config file `JJ_CONFIG`
/// points at.
fn isolate(tmp: &Path) -> PathBuf {
    let xdg = tmp.join("xdg");
    fs::create_dir_all(&xdg).unwrap();
    set_env("XDG_CONFIG_HOME", Some(xdg.to_str().unwrap()));
    set_env("GIT_CONFIG_GLOBAL", Some(""));
    for name in ["JJ_USER", "JJ_EMAIL", "JJ_OP_HOSTNAME", "JJ_OP_USERNAME"] {
        set_env(name, None);
    }
    let user_file = tmp.join("user.toml");
    fs::write(&user_file, "").unwrap();
    set_env("JJ_CONFIG", Some(user_file.to_str().unwrap()));
    user_file
}

/// A non-colocated Git-backed repo at `<tmp>/repo`.
fn init_repo(tmp: &Path) -> Repo {
    Repo::init(&InitOptions {
        path: tmp.join("repo"),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init")
}

/// `(committer email, author email)` of `@`, and the head operation's username — read from the
/// store with jj-lib directly.
fn head_facts(root: &Path) -> ((String, String), String) {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head");
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .expect("a working-copy commit");
    let commit = repo.store().get_commit(wc_id).expect("wc commit");
    let emails = (commit.committer().email.clone(), commit.author().email.clone());
    (emails, repo.operation().metadata().username.clone())
}

fn pair(committer: &str, author: &str) -> (String, String) {
    (committer.to_owned(), author.to_owned())
}

fn wc(repo: &Repo) -> ChangeId {
    resolve_revset(repo, "@").expect("@ resolves").remove(0)
}

const BASE_IDENTITY: &str = "[user]\nname = \"Base\"\nemail = \"base@example.com\"\n\
                             [operation]\nusername = \"base-op\"\n";

/// A `["describe"]` scope writes describe's committer and operation user; the `new` after it
/// writes the base identity again.
#[test]
fn a_describe_scope_reaches_describe_and_no_other_verb() {
    test_helpers::own_process!("a_describe_scope_reaches_describe_and_no_other_verb");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    fs::write(
        &user_file,
        format!(
            "{BASE_IDENTITY}[[--scope]]\n--when.commands = [\"describe\"]\n\
             [--scope.user]\nemail = \"scoped@example.com\"\n\
             [--scope.operation]\nusername = \"scoped-op\"\n"
        ),
    )
    .unwrap();
    let mut repo = init_repo(tmp.path());
    let root = repo.workspace_root().to_owned();
    assert_eq!(head_facts(&root).1, "base-op", "`git init` is not `describe`");

    let at = wc(&repo);
    repo.describe(at, "scoped").expect("describe");
    assert_eq!(
        head_facts(&root),
        (pair("scoped@example.com", "base@example.com"), "scoped-op".to_owned()),
        "describe rewrites @ with the scoped committer and operation user"
    );

    let at = wc(&repo);
    repo.new_change(&[at], &[], &[]).expect("new");
    assert_eq!(
        head_facts(&root),
        (pair("base@example.com", "base@example.com"), "base-op".to_owned()),
        "new writes the base identity"
    );
}

/// `--when.commands = ["git"]` is a whole-word prefix of `git fetch`, so it sets the remotes
/// `git_fetch_remotes` resolves; a `["git push"]` scope reaches `git_push_remotes` and not it.
#[test]
fn a_git_scope_reaches_git_fetch_remotes_and_a_git_push_scope_does_not() {
    test_helpers::own_process!("a_git_scope_reaches_git_fetch_remotes_and_a_git_push_scope_does_not");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    let mut repo = init_repo(tmp.path());
    for name in ["origin", "upstream"] {
        repo.git_remote_add(name, &format!("https://example.com/{name}.git"), None)
            .expect("remote added");
    }

    fs::write(
        &user_file,
        "[[--scope]]\n--when.commands = [\"git push\"]\n[--scope.git]\npush = \"upstream\"\nfetch = \"upstream\"\n",
    )
    .unwrap();
    assert_eq!(
        repo.git_push_remotes().expect("push remotes"),
        ["upstream"],
        "the `git push` scope reaches the push's remotes"
    );
    assert_eq!(
        repo.git_fetch_remotes().expect("fetch remotes"),
        ["origin"],
        "and not the fetch's"
    );

    fs::write(
        &user_file,
        "[[--scope]]\n--when.commands = [\"git\"]\n[--scope.git]\nfetch = \"upstream\"\n",
    )
    .unwrap();
    assert_eq!(repo.git_fetch_remotes().expect("fetch remotes"), ["upstream"]);
}

/// The `&self` reads that replace `jj log`'s output resolve for `log` — not for the verb that ran
/// before them: a `["describe"]` scope does not reach `log_defaults` / `resolve_revset` after a
/// `describe`, a `["log"]` scope does.
#[test]
fn the_log_reads_resolve_for_log_whatever_ran_before() {
    test_helpers::own_process!("the_log_reads_resolve_for_log_whatever_ran_before");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    let mut repo = init_repo(tmp.path());
    let scoped = |command: &str| {
        format!(
            "[[--scope]]\n--when.commands = [\"{command}\"]\n[--scope.revsets]\nlog = \"scoped\"\n\
             [--scope.revset-aliases]\n'scoped_at()' = '@'\n"
        )
    };

    fs::write(&user_file, scoped("describe")).unwrap();
    let at = wc(&repo);
    repo.describe(at, "x").expect("describe");
    assert_ne!(repo.log_defaults().expect("log defaults").log, "scoped");
    assert!(
        resolve_revset(&repo, "scoped_at()").is_err(),
        "the describe-scoped alias is not `log`'s"
    );

    fs::write(&user_file, scoped("log")).unwrap();
    assert_eq!(repo.log_defaults().expect("log defaults").log, "scoped");
    assert_eq!(
        resolve_revset(&repo, "scoped_at()").expect("the log-scoped alias"),
        [wc(&repo)]
    );
}

/// Run a git command in `dir`; panics on non-zero exit. Fixture setup only.
fn git(args: &[&str], dir: &Path) {
    let status = Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git spawns");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// A `["git clone"]` scope signs the clone's operations; an init with the same stack does not
/// see it.
#[test]
fn a_git_clone_scope_signs_the_clone_operations() {
    test_helpers::own_process!("a_git_clone_scope_signs_the_clone_operations");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    fs::write(
        &user_file,
        format!("{BASE_IDENTITY}[[--scope]]\n--when.commands = [\"git clone\"]\n[--scope.operation]\nusername = \"cloner\"\n"),
    )
    .unwrap();
    let src = tmp.path().join("src");
    fs::create_dir_all(&src).unwrap();
    git(&["init", "--initial-branch=main"], &src);
    git(&["config", "user.email", "test@zanshin.test"], &src);
    git(&["config", "user.name", "Fixture"], &src);
    fs::write(src.join("README.md"), "hello").unwrap();
    git(&["add", "."], &src);
    git(&["commit", "-m", "initial"], &src);

    let dest = tmp.path().join("clone");
    let cloned = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: format!("file://{}", src.display()),
            destination: dest.clone(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result
    .expect("clone");
    assert_eq!(head_facts(cloned.workspace_root()).1, "cloner");

    let repo = init_repo(tmp.path());
    assert_eq!(head_facts(repo.workspace_root()).1, "base-op");
}

/// A wrong-typed value in a `["describe"]` scope refuses `describe` at its start-up, as the
/// CLI's; the verbs around it run, and a `["git init"]` scope's fault refuses the init only.
#[test]
fn a_wrong_typed_scoped_value_refuses_only_its_verb() {
    test_helpers::own_process!("a_wrong_typed_scoped_value_refuses_only_its_verb");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    fs::write(
        &user_file,
        "[[--scope]]\n--when.commands = [\"describe\"]\n[--scope.user]\nname = 1\n",
    )
    .unwrap();
    let mut repo = init_repo(tmp.path());
    let at = wc(&repo);
    let err = repo.describe(at, "x").expect_err("describe refuses");
    assert!(
        matches!(&err, MutateError::Precondition(PreconditionError::Config { reason }) if reason.contains("user.name")),
        "got {err:?}"
    );
    repo.status().expect("status runs");
    let at = wc(&repo);
    repo.new_change(&[at], &[], &[]).expect("new runs");

    fs::write(
        &user_file,
        "[[--scope]]\n--when.commands = [\"git init\"]\n[--scope.user]\nname = 1\n",
    )
    .unwrap();
    let err = Repo::init(&InitOptions {
        path: tmp.path().join("other"),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect_err("init refuses");
    assert!(
        matches!(&err, RepoError::Config { reason } if reason.contains("user.name")),
        "got {err:?}"
    );
    repo.status().expect("an open repo's verbs still run");
}
