// SPDX-License-Identifier: MIT

//! Story 9.27 witness: a `Repo` writes with the EFFECTIVE jj config stack — the CLI's own —
//! not a hardcoded identity. Commit authors and operation metadata are read back from the
//! store, the oracle `jj log` / `jj op log` read.
//!
//! # Why one test in its own binary
//!
//! Same rule as `tests/config_user_layer.rs`: `JJ_CONFIG`, `JJ_USER`, `JJ_EMAIL` and
//! `XDG_CONFIG_HOME` are process-global and this test CHANGES them, so it is the only
//! `#[test]` here and walks the whole I/O matrix in sequence — split into phase functions
//! only to keep each readable.
//!
//! # The rules this file must never break
//!
//! `JJ_CONFIG` may be repointed but is **never unset** (unset re-enables discovery of the
//! developer's real config, and — with `JJ_CONFIG` unset — the `/etc/jj` system layer), and
//! `XDG_CONFIG_HOME` points into a temp dir so the secure repo/workspace config root is ours.
//! The four identity variables the rest of the suite pins (`JJ_USER`, `JJ_EMAIL`,
//! `JJ_OP_HOSTNAME`, `JJ_OP_USERNAME`) are REMOVED: this is the one binary that observes the
//! `EnvBase` `whoami` values and a file-configured identity.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::{add_workspace, extract_fixture, FixtureHandle};
use zanshin_jj::{
    convert_colocated, convert_import, resolve_revset, Backend, ChangeId, MutateError, Repo, RepoError, WarningKind,
};

/// Sets (or, for `None`, removes) one process environment variable.
fn set_env(name: &str, value: Option<&str>) {
    // SAFETY: single-threaded — this binary contains exactly one #[test], and every change
    // happens between the verbs that read the environment.
    unsafe {
        match value {
            Some(v) => env::set_var(name, v),
            None => env::remove_var(name),
        }
    }
}

fn set_jj_config(path: &Path) {
    set_env("JJ_CONFIG", Some(path.to_str().expect("utf-8 temp path")));
}

/// Writes `body` to `<tmp>/<name>` and returns the path.
fn config_file(tmp: &Path, name: &str, body: &str) -> PathBuf {
    let path = tmp.join(name);
    fs::write(&path, body).unwrap();
    path
}

/// `(author name, author email)` of `@`, and `(username, hostname)` of the head operation —
/// read from the store with jj-lib directly (the settings used for READING are irrelevant).
fn head_facts(root: &Path) -> ((String, String), (String, String)) {
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
        .expect("the workspace has a working-copy commit");
    let author = repo.store().get_commit(wc_id).expect("wc commit").author().clone();
    let metadata = repo.operation().metadata().clone();
    ((author.name, author.email), (metadata.username, metadata.hostname))
}

/// Creates a NEW change on `@` — its author is exactly the settings' signature — and returns
/// what the call warned about the identity (Story 9.32).
fn new_change_on_wc(repo: &mut Repo) -> Vec<String> {
    let wc: Vec<ChangeId> = resolve_revset(repo, "@").expect("@ resolves");
    repo.new_change(&wc, &[], &[]).expect("new_change");
    identity_warnings(repo)
}

/// The messages of the `jj.identity_missing` warnings the last verb collected.
fn identity_warnings(repo: &mut Repo) -> Vec<String> {
    repo.take_warnings()
        .into_iter()
        .filter(|w| w.kind == WarningKind::IdentityMissing)
        .map(|w| w.message)
        .collect()
}

/// The CLI's identity warning for `not_configured` (`cli_util.rs:2397-2401` @ v0.44.0).
fn identity_message(not_configured: &str) -> String {
    format!(
        "{not_configured} Until configured, your commits will be created with the empty identity, and can't be \
         pushed to remotes."
    )
}

fn author(root: &Path) -> (String, String) {
    head_facts(root).0
}

fn pair(name: &str, email: &str) -> (String, String) {
    (name.to_owned(), email.to_owned())
}

#[test]
fn a_repo_writes_with_the_effective_config_stack() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    fs::create_dir_all(&xdg).unwrap();
    set_env("XDG_CONFIG_HOME", Some(xdg.to_str().unwrap()));
    set_env("GIT_CONFIG_GLOBAL", Some(""));
    for name in ["JJ_USER", "JJ_EMAIL", "JJ_OP_HOSTNAME", "JJ_OP_USERNAME"] {
        set_env(name, None);
    }
    let user_file = config_file(
        tmp.path(),
        "user.toml",
        "[user]\nname = \"Ada\"\nemail = \"ada@example.com\"\n",
    );
    set_jj_config(&user_file);

    let (fx, repo) = identity_follows_the_user_stack(tmp.path(), &user_file);
    let (other, other_repo) = repo_and_workspace_layers(&fx, repo);
    op_metadata_overrides_reach_the_store();
    mine_follows_the_stack(tmp.path(), &user_file);
    secure_config_ids_select_the_repo_and_workspace_layers(&xdg);
    every_mutating_verb_refreshes_first(tmp.path(), &user_file);
    scopes_and_faults(tmp.path(), &other, other_repo);
    creation_paths(tmp.path(), &user_file);
}

/// `JJ_OP_USERNAME` / `JJ_OP_HOSTNAME` (`EnvOverrides`) set AFTER open beat the whoami values
/// in the NEXT committed operation's stored metadata.
fn op_metadata_overrides_reach_the_store() {
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).expect("open");
    set_env("JJ_OP_USERNAME", Some("op-override-user"));
    set_env("JJ_OP_HOSTNAME", Some("op-override-host"));
    new_change_on_wc(&mut repo);
    assert_eq!(head_facts(&fx.path).1, pair("op-override-user", "op-override-host"));
    set_env("JJ_OP_USERNAME", None);
    set_env("JJ_OP_HOSTNAME", None);
}

/// `mine()` reads `user.email` from the per-call stack: changing it WITHOUT a mutation changes
/// what `mine()` denotes on the same handle.
fn mine_follows_the_stack(tmp: &Path, user_file: &Path) {
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).expect("open");
    new_change_on_wc(&mut repo);
    assert_eq!(author(&fx.path).1, "bea@example.com");
    let mine_commit = resolve_revset(&repo, "@").expect("@ resolves").swap_remove(0);
    assert!(
        resolve_revset(&repo, "mine()")
            .expect("mine() resolves")
            .contains(&mine_commit),
        "the commit authored with the configured email is mine()"
    );
    set_jj_config(&config_file(
        tmp,
        "someone-else.toml",
        "[user]\nname = \"Else\"\nemail = \"someone-else@example.com\"\n",
    ));
    assert!(
        resolve_revset(&repo, "mine()").expect("mine() resolves").is_empty(),
        "no commit is authored with the new email, so mine() is empty"
    );
    set_jj_config(user_file);
}

/// The secure layers: `.jj/repo/config-id` → `<config_dir>/jj/repos/<id>/config.toml` and
/// `.jj/workspace-config-id` → `<config_dir>/jj/workspaces/<id>/config.toml`, read back from
/// a commit's author; a repo without the ids is unaffected.
fn secure_config_ids_select_the_repo_and_workspace_layers(xdg: &Path) {
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (repo_id, ws_id) = ("aaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbb");
    for (kind, id, body) in [
        ("repos", repo_id, "[user]\nemail = \"secure-repo@example.com\"\n"),
        ("workspaces", ws_id, "[user]\nname = \"Secure Workspace\"\n"),
    ] {
        let dir = xdg.join("jj").join(kind).join(id);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("config.toml"), body).unwrap();
    }
    fs::write(fx.path.join(".jj").join("repo").join("config-id"), repo_id).unwrap();
    fs::write(fx.path.join(".jj").join("workspace-config-id"), ws_id).unwrap();

    let mut repo = Repo::open(&fx.path).expect("open through the config ids");
    new_change_on_wc(&mut repo);
    assert_eq!(author(&fx.path), pair("Secure Workspace", "secure-repo@example.com"));

    let other = extract_fixture("tiny-3-commits").unwrap();
    let mut other_repo = Repo::open(&other.path).expect("open a repo without ids");
    new_change_on_wc(&mut other_repo);
    assert_eq!(
        author(&other.path),
        pair("Bea Longer", "bea@example.com"),
        "a repo without config ids is unaffected"
    );
}

/// Every one of the 16 `&mut self` verbs runs the pre-verb refresh FIRST: with the stack
/// broken under an open handle each refuses as `Config` — before its own argument checks —
/// and the op-log head does not move.
fn every_mutating_verb_refreshes_first(tmp: &Path, user_file: &Path) {
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).expect("open");
    let head = |repo: &mut Repo| repo.op_log(Some(1)).expect("op log").swap_remove(0).id.0;
    let before = head(&mut repo);
    set_jj_config(&config_file(tmp, "broken-verbs.toml", "not = = toml\n"));

    let id = || ChangeId("zzzzzzzzzzzz".to_owned());
    let progress = |_: zanshin_jj::ProgressEvent| {};
    let names = ["x".to_owned()];
    let results: Vec<(&str, Result<(), MutateError>)> = vec![
        ("describe", repo.describe(id(), "d").map(drop)),
        ("new_change", repo.new_change(&[id()], &[], &[]).map(drop)),
        ("edit", repo.edit(id()).map(drop)),
        ("abandon", repo.abandon(&[id()]).map(drop)),
        ("undo", repo.undo(false).map(drop)),
        ("git_fetch", repo.git_fetch("origin", &progress, None).map(drop)),
        ("git_import", repo.git_import().map(drop)),
        ("git_export", repo.git_export().map(drop)),
        ("git_remote_add", repo.git_remote_add("x", "file:///x", None).map(drop)),
        ("git_remote_remove", repo.git_remote_remove("x").map(drop)),
        ("git_remote_rename", repo.git_remote_rename("x", "y").map(drop)),
        (
            "git_remote_set_url",
            repo.git_remote_set_url("x", Some("file:///y"), None).map(drop),
        ),
        ("bookmark_create", repo.bookmark_create(&names, None).map(drop)),
        ("bookmark_delete", repo.bookmark_delete(&names).map(drop)),
        ("restore", repo.restore(None, None, None, &[], false).map(drop)),
        ("absorb", repo.absorb(None, None, &[]).map(drop)),
    ];
    for (verb, result) in results {
        assert!(
            matches!(&result, Err(MutateError::Precondition(zanshin_jj::PreconditionError::Config { reason })) if reason.contains("broken-verbs.toml")),
            "{verb} must refuse in the pre-verb snapshot (Story 9.26), got: {result:?}"
        );
    }
    // Every verb refuses while the stack is broken, so it is repaired before the read-back.
    set_jj_config(user_file);
    assert_eq!(head(&mut repo), before, "no verb wrote an operation");
}

/// User file → commit author + whoami op metadata; a rewritten file and a repointed
/// `JJ_CONFIG` reach the SAME handle; the empty identity; `JJ_USER`/`JJ_EMAIL` win.
fn identity_follows_the_user_stack(tmp: &Path, user_file: &Path) -> (FixtureHandle, Repo) {
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).expect("open with the user identity");
    assert!(
        new_change_on_wc(&mut repo).is_empty(),
        "a configured identity reports nothing"
    );
    let (commit_author, (op_user, op_host)) = head_facts(&fx.path);
    assert_eq!(commit_author, pair("Ada", "ada@example.com"));
    assert_eq!(
        op_user,
        whoami::username().expect("whoami username"),
        "EnvBase username"
    );
    assert_eq!(
        op_host,
        whoami::hostname().expect("whoami hostname"),
        "EnvBase hostname"
    );

    // The same file rewritten under an open handle is picked up by the next verb…
    fs::write(
        user_file,
        "[user]\nname = \"Bea Longer\"\nemail = \"bea@example.com\"\n",
    )
    .unwrap();
    new_change_on_wc(&mut repo);
    assert_eq!(author(&fx.path), pair("Bea Longer", "bea@example.com"));

    // …and so is a repointed JJ_CONFIG.
    set_jj_config(&config_file(
        tmp,
        "other.toml",
        "[user]\nname = \"Cy\"\nemail = \"cy@example.com\"\n",
    ));
    new_change_on_wc(&mut repo);
    assert_eq!(author(&fx.path), pair("Cy", "cy@example.com"));

    // No identity anywhere: the commit is created with it, and the call warns — the CLI's three
    // variants (Story 9.32).
    set_jj_config(&config_file(tmp, "empty.toml", ""));
    let both_missing = vec![identity_message("Name and email not configured.")];
    assert_eq!(
        new_change_on_wc(&mut repo),
        both_missing,
        "a committed operation with the empty identity warns about both fields"
    );
    assert_eq!(author(&fx.path), pair("", ""), "never a placeholder");
    set_jj_config(&config_file(
        tmp,
        "email-only.toml",
        "[user]\nemail = \"e@example.com\"\n",
    ));
    assert_eq!(new_change_on_wc(&mut repo), [identity_message("Name not configured.")]);
    set_jj_config(&config_file(tmp, "name-only.toml", "[user]\nname = \"N\"\n"));
    assert_eq!(new_change_on_wc(&mut repo), [identity_message("Email not configured.")]);
    set_jj_config(&config_file(tmp, "empty.toml", ""));
    // The shared committed path (`finish_or_no_op_at`: bookmark + git verbs) and `describe`.
    repo.bookmark_create(&["empty-identity".to_owned()], None)
        .expect("bookmark_create commits");
    // The full list, in the CLI's print order: the verb body's note on the empty `@`, then the
    // finish's identity note — last, as `finish_transaction` prints it.
    let warnings = repo.take_warnings();
    assert_eq!(
        warnings
            .iter()
            .map(|w| (w.kind, w.message.as_str()))
            .collect::<Vec<_>>(),
        [
            (WarningKind::BookmarkTargetEmpty, "Target revision is empty."),
            (WarningKind::IdentityMissing, both_missing[0].as_str())
        ],
        "bookmark_create"
    );
    let wc = resolve_revset(&repo, "@").expect("@ resolves").swap_remove(0);
    repo.describe(wc, "described anonymously").expect("describe commits");
    assert_eq!(identity_warnings(&mut repo), both_missing, "describe");
    repo.bookmark_delete(&["exact:no-such-bookmark".to_owned()])
        .expect("matching nothing is a success");
    assert!(
        identity_warnings(&mut repo).is_empty(),
        "a call that commits nothing never reaches the finish, so it never warns"
    );
    // `file track` / `file untrack` ALWAYS commit, yet never warn about it: the CLI commits their
    // raw transaction and never reaches `finish_transaction`, where its warning lives (Story 9.22).
    let nothing = ["no-such-path".to_owned()];
    repo.file_track(&nothing, false).expect("file_track commits");
    assert!(identity_warnings(&mut repo).is_empty(), "file_track");
    repo.file_untrack(&nothing).expect("file_untrack commits");
    assert!(identity_warnings(&mut repo).is_empty(), "file_untrack");
    the_precondition_finish_warns_about_the_identity_too(tmp);

    // JJ_USER / JJ_EMAIL (EnvOverrides) beat every file.
    set_jj_config(user_file);
    set_env("JJ_USER", Some("Env User"));
    set_env("JJ_EMAIL", Some("env@example.com"));
    new_change_on_wc(&mut repo);
    assert_eq!(author(&fx.path), pair("Env User", "env@example.com"));
    set_env("JJ_USER", None);
    set_env("JJ_EMAIL", None);
    (fx, repo)
}

/// The CLI's identity warning lives in `finish_transaction`, so the pre-verb snapshot's own
/// finishes warn too: a Git ref moved outside a COLOCATED workspace makes the precondition's
/// `import git refs` commit — one warning — before the verb's own finish warns again.
fn the_precondition_finish_warns_about_the_identity_too(tmp: &Path) {
    let dir = tmp.join("colocated-identity");
    fs::create_dir_all(&dir).unwrap();
    let git = |args: &[&str]| {
        let status = Command::new("git")
            .args(["-c", "user.name=Git", "-c", "user.email=git@example.com"])
            .args(args)
            .current_dir(&dir)
            .status()
            .expect("git runs");
        assert!(status.success(), "git {args:?}");
    };
    git(&["init", "--initial-branch=main"]);
    fs::write(dir.join("README.md"), "hello").unwrap();
    git(&["add", "."]);
    git(&["commit", "-m", "initial"]);
    convert_colocated(&dir).result.expect("convert");
    let mut repo = Repo::open(&dir).expect("open");
    repo.status().expect("settle the colocated state");
    let _ = repo.take_warnings();

    let both = identity_message("Name and email not configured.");
    assert_eq!(
        new_change_on_wc(&mut repo),
        std::slice::from_ref(&both),
        "no ref moved: the verb's finish only"
    );
    git(&["branch", "moved-outside"]);
    assert_eq!(
        new_change_on_wc(&mut repo),
        [both.clone(), both],
        "`import git refs` finished first, then the verb"
    );
}

/// A repo-level override applies to THAT repo only; a secondary workspace reads the repo
/// layer through its `.jj/repo` FILE and adds its own workspace layer.
fn repo_and_workspace_layers(fx: &FixtureHandle, mut repo: Repo) -> (FixtureHandle, Repo) {
    fs::write(
        fx.path.join(".jj").join("repo").join("config.toml"),
        "[user]\nemail = \"repo-a@example.com\"\n",
    )
    .unwrap();
    new_change_on_wc(&mut repo);
    assert_eq!(author(&fx.path), pair("Bea Longer", "repo-a@example.com"));
    let other = extract_fixture("tiny-3-commits").unwrap();
    let mut other_repo = Repo::open(&other.path).expect("open the second repo");
    new_change_on_wc(&mut other_repo);
    assert_eq!(
        author(&other.path),
        pair("Bea Longer", "bea@example.com"),
        "repo B is unaffected"
    );

    let (second, _wc) = add_workspace(&fx.path, "second");
    assert!(second.path.join(".jj").join("repo").is_file(), "a secondary workspace");
    fs::write(
        second.path.join(".jj").join("workspace-config.toml"),
        "[user]\nname = \"Second Workspace\"\n",
    )
    .unwrap();
    let mut second_repo = Repo::open(&second.path).expect("open the secondary workspace");
    new_change_on_wc(&mut second_repo);
    assert_eq!(
        author(&second.path),
        pair("Second Workspace", "repo-a@example.com"),
        "workspace layer on top of the SHARED repo layer"
    );
    new_change_on_wc(&mut repo);
    assert_eq!(
        author(&fx.path),
        pair("Bea Longer", "repo-a@example.com"),
        "the default workspace does not see the secondary's layer"
    );
    (other, other_repo)
}

/// A `--when.hostnames` scope matches the whoami hostname; a stack broken under an open
/// handle refuses the next mutation; broken TOML and a wrong-typed identity refuse the open.
fn scopes_and_faults(tmp: &Path, other: &FixtureHandle, mut other_repo: Repo) {
    set_jj_config(&config_file(
        tmp,
        "scoped.toml",
        &format!(
            "[user]\nname = \"Unscoped\"\nemail = \"s@example.com\"\n\n[[--scope]]\n--when.hostnames = [{:?}]\n[--scope.user]\nname = \"Scoped\"\n",
            whoami::hostname().expect("whoami hostname")
        ),
    ));
    new_change_on_wc(&mut other_repo);
    assert_eq!(author(&other.path), pair("Scoped", "s@example.com"));

    let wc = resolve_revset(&other_repo, "@").expect("@ resolves");
    set_jj_config(&config_file(tmp, "broken.toml", "not = = toml\n"));
    let err = other_repo
        .new_change(&wc, &[], &[])
        .expect_err("a broken stack must refuse");
    assert!(
        matches!(&err, MutateError::Precondition(zanshin_jj::PreconditionError::Config { reason })
            if reason.contains("broken.toml")),
        "unexpected error: {err:?}"
    );
    let err = Repo::open(&other.path).expect_err("invalid TOML must refuse the open");
    assert!(
        matches!(&err, RepoError::Config { reason } if reason.contains("broken.toml")),
        "unexpected error: {err:?}"
    );

    set_jj_config(&config_file(tmp, "wrong-type.toml", "[user]\nname = 1\n"));
    let err = Repo::open(&other.path).expect_err("a wrong-typed user.name must refuse the open");
    assert!(
        matches!(&err, RepoError::Config { reason } if reason.contains("user.name")),
        "unexpected error: {err:?}"
    );
}

/// A plain Git repo with one commit at `path` (fixture setup only — AR-AP-1's allowed git use).
fn git_repo_with_a_commit(path: &Path) {
    for args in [
        &["init", "-q", "--initial-branch=main"][..],
        &[
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.com",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "initial",
        ][..],
    ] {
        let status = Command::new("git")
            .args(args)
            .current_dir(path)
            .status()
            .expect("git spawns");
        assert!(status.success(), "git {args:?} failed");
    }
}

fn is_user_name_fault(err: &RepoError) -> bool {
    matches!(err, RepoError::Config { reason } if reason.contains("user.name"))
}

/// The CLI checks the user-level stack at START-UP, before the command touches any path
/// (`cli/src/cli_util.rs:4543-4627` @ v0.44.0): a user-level fault wins over a missing
/// destination or source, and a refused creation creates nothing — not even the missing
/// parent of an import destination. Expects `JJ_CONFIG` on a stack with `user.name = 1`.
fn user_level_faults_refuse_first(tmp: &Path) {
    let missing = tmp.join("missing");
    let err = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&missing),
        ..Default::default()
    })
    .result
    .expect_err("init must refuse");
    assert!(is_user_name_fault(&err), "init reported the path first: {err:?}");
    let err = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from("file:///nonexistent-zanshin-source"),
            destination: std::path::PathBuf::from(&missing),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result
    .expect_err("clone must refuse");
    assert!(is_user_name_fault(&err), "clone reported the path first: {err:?}");
    let err = convert_colocated(&missing).result.expect_err("convert must refuse");
    assert!(is_user_name_fault(&err), "convert reported the path first: {err:?}");
    let missing_parent = tmp.join("missing-parent");
    let err = convert_import(&missing, &missing_parent.join("dest"))
        .result
        .expect_err("import must refuse");
    assert!(is_user_name_fault(&err), "import reported the source first: {err:?}");
    let source = TempDir::new().unwrap();
    git_repo_with_a_commit(source.path());
    let err = convert_import(source.path(), &missing_parent.join("dest"))
        .result
        .expect_err("import must refuse");
    assert!(is_user_name_fault(&err), "unexpected error: {err:?}");
    assert!(!missing_parent.exists(), "a refused import creates nothing");
    assert!(!missing.exists(), "no refused creation creates its destination");
}

/// Creation (init, clone, both conversions) resolves the stack for the NEW workspace's
/// canonical paths — the CLI's `settings_for_new_workspace` — so `--when.repositories` /
/// `--when.workspaces` scopes (a per-directory identity) sign what it writes, and the
/// re-opened handle resolves the same scope. Leaves `JJ_CONFIG` on a scoped stack.
#[allow(clippy::too_many_lines)] // WHY: one scenario, step by step; Story 9.20's option structs made it longer
fn scoped_creation(tmp: &Path) {
    // A per-directory identity: the scope matches only the NEW workspace's own paths.
    let canonical_tmp = fs::canonicalize(tmp).unwrap();
    let scoped_root = canonical_tmp.join("scoped");
    let ws_scoped_root = canonical_tmp.join("ws-scoped");
    set_jj_config(&config_file(
        tmp,
        "scoped-repos.toml",
        &format!(
            "[user]\nname = \"Creator\"\nemail = \"unscoped@example.com\"\n\n[[--scope]]\n--when.repositories = [{:?}]\n[--scope.user]\nemail = \"scoped@example.com\"\n\n[[--scope]]\n--when.workspaces = [{:?}]\n[--scope.user]\nname = \"Workspace Scoped\"\n",
            scoped_root.to_str().expect("utf-8 temp path"),
            ws_scoped_root.to_str().expect("utf-8 temp path")
        ),
    ));
    let scoped_init = scoped_root.join("init");
    fs::create_dir_all(&scoped_init).unwrap();
    let mut scoped_handle = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&scoped_init),
        ..Default::default()
    })
    .result
    .expect("init with a scoped stack");
    assert_eq!(
        author(&scoped_init),
        pair("Creator", "scoped@example.com"),
        "init's working-copy commit is signed with the scope of its own path"
    );
    new_change_on_wc(&mut scoped_handle);
    assert_eq!(
        author(&scoped_init),
        pair("Creator", "scoped@example.com"),
        "the re-opened handle resolves the same scope as the creation"
    );
    let unscoped_init = canonical_tmp.join("unscoped-init");
    fs::create_dir_all(&unscoped_init).unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&unscoped_init),
        ..Default::default()
    })
    .result
    .expect("init outside the scope");
    assert_eq!(
        author(&unscoped_init),
        pair("Creator", "unscoped@example.com"),
        "a creation outside the scope keeps the unscoped identity"
    );
    let ws_scoped_init = ws_scoped_root.join("init");
    fs::create_dir_all(&ws_scoped_init).unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&ws_scoped_init),
        ..Default::default()
    })
    .result
    .expect("init with a workspace scope");
    assert_eq!(
        author(&ws_scoped_init),
        pair("Workspace Scoped", "unscoped@example.com"),
        "a --when.workspaces scope applies to the creation's own workspace path"
    );
    // A symlinked caller path: the scope names the CANONICAL root, so it matches only because
    // the stack is resolved for the canonicalized destination, as the CLI resolves it.
    let link = canonical_tmp.join("scoped-link");
    std::os::unix::fs::symlink(&scoped_root, &link).unwrap();
    let via_link = link.join("via-link");
    fs::create_dir_all(&via_link).unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&via_link),
        ..Default::default()
    })
    .result
    .expect("init through a symlinked path");
    assert_eq!(
        author(&via_link),
        pair("Creator", "scoped@example.com"),
        "the scope matches the canonical destination, not the caller's spelling"
    );
    let clone_source = TempDir::new().unwrap();
    git_repo_with_a_commit(clone_source.path());
    let scoped_clone = scoped_root.join("clone");
    fs::create_dir_all(&scoped_clone).unwrap();
    Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from(&format!("file://{}", clone_source.path().display())),
            destination: std::path::PathBuf::from(&scoped_clone),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result
    .expect("clone with a scoped stack");
    assert_eq!(
        author(&scoped_clone),
        pair("Creator", "scoped@example.com"),
        "the clone's working-copy commit is signed with the scope of its own path"
    );
    let import_source = TempDir::new().unwrap();
    git_repo_with_a_commit(import_source.path());
    let scoped_import = scoped_root.join("import");
    convert_import(import_source.path(), &scoped_import)
        .result
        .expect("import with a scoped stack");
    assert_eq!(
        author(&scoped_import),
        pair("Creator", "scoped@example.com"),
        "the import's working-copy commit is signed with the scope of its DESTINATION"
    );
    let scoped_git = scoped_root.join("git");
    fs::create_dir_all(&scoped_git).unwrap();
    let status = Command::new("git")
        .args(["init", "-q"])
        .current_dir(&scoped_git)
        .status()
        .expect("git init spawns");
    assert!(status.success());
    convert_colocated(&scoped_git)
        .result
        .expect("conversion with a scoped stack");
    assert_eq!(
        author(&scoped_git),
        pair("Creator", "scoped@example.com"),
        "the conversion's working-copy commit is signed with the scope of its own path"
    );
}

/// Creation refuses a broken stack BEFORE writing, a user-level fault ahead of every path
/// error; a wrong-typed `git.*` key the git backend reads while creating is a config fault too
/// (init AND both conversions); creation (init, clone, both conversions) resolves the stack
/// for the NEW workspace's canonical paths, so `--when.repositories` / `--when.workspaces`
/// scopes apply to what it writes (the CLI's `settings_for_new_workspace`); a created repo is
/// re-opened with its full stack. Leaves `JJ_CONFIG` on `user_file`.
fn creation_paths(tmp: &Path, user_file: &Path) {
    let fresh = tmp.join("fresh");
    fs::create_dir_all(&fresh).unwrap();
    set_jj_config(&config_file(tmp, "wrong-type-init.toml", "[user]\nname = 1\n"));
    let err = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&fresh),
        ..Default::default()
    })
    .result
    .expect_err("init must refuse a broken stack");
    assert!(
        matches!(&err, RepoError::Config { reason } if reason.contains("user.name")),
        "unexpected error: {err:?}"
    );
    assert!(!fresh.join(".jj").exists(), "a refused init writes nothing");
    user_level_faults_refuse_first(tmp);

    scoped_creation(tmp);

    set_jj_config(&config_file(
        tmp,
        "bad-git.toml",
        "[git]\nabandon-unreachable-commits = \"yes\"\n",
    ));
    let fresh_git = tmp.join("fresh-git");
    fs::create_dir_all(&fresh_git).unwrap();
    let err = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&fresh_git),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect_err("a wrong-typed git key must refuse");
    assert!(
        matches!(&err, RepoError::Config { reason } if reason.contains("abandon-unreachable-commits")),
        "unexpected error: {err:?}"
    );
    // Story 9.20 (deferral I3): jj-lib's own creation removes the `.jj` it started — the CLI's
    // `jj git init` cleans up nothing beyond that, and neither does `Repo::init`.
    assert!(
        !fresh_git.join(".jj").exists(),
        "a failing git backend leaves no .jj behind"
    );
    let git_repo = TempDir::new().unwrap();
    let status = Command::new("git")
        .args(["init", "-q"])
        .current_dir(git_repo.path())
        .status()
        .expect("git init spawns");
    assert!(status.success());
    let err = convert_colocated(git_repo.path())
        .result
        .expect_err("a wrong-typed git key must refuse");
    assert!(
        matches!(&err, RepoError::Config { reason } if reason.contains("abandon-unreachable-commits")),
        "unexpected error: {err:?}"
    );
    assert!(
        !git_repo.path().join(".jj").exists(),
        "the failed conversion rolled back"
    );
    let import_dest = tmp.join("import-dest");
    let err = convert_import(git_repo.path(), &import_dest)
        .result
        .expect_err("a wrong-typed git key must refuse the import");
    assert!(
        matches!(&err, RepoError::Config { reason } if reason.contains("abandon-unreachable-commits")),
        "unexpected error: {err:?}"
    );
    assert!(
        !import_dest.exists(),
        "the destination created for the import is rolled back"
    );

    set_jj_config(user_file);
    let mut created = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&fresh),
        ..Default::default()
    })
    .result
    .expect("init with a valid stack");
    fs::write(
        fresh.join(".jj").join("repo").join("config.toml"),
        "[user]\nname = \"Fresh Repo\"\n",
    )
    .unwrap();
    new_change_on_wc(&mut created);
    assert_eq!(author(&fresh), pair("Fresh Repo", "bea@example.com"));
}
