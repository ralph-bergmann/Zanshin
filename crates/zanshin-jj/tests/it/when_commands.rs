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
use zanshin_jj::{
    config_file_read, config_file_write, config_gc_delete, config_gc_list, config_get, config_list, config_path,
    config_set, config_unset, resolve_revset, ActionStatus, Backend, ChangeId, ConfigListQuery, ConfigScope,
    ConfigTarget, DropLocation, DropSource, DropVerb, InitOptions, MutateError, PreconditionError, Repo, RepoError,
    RevsetSearchError, SelectTreeOptions, SelectTreeVerb, UntrackedReason, Warning, WarningKind,
};

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
/// before them: a `["describe"]` scope does not reach `log_defaults` / `resolve_revset` /
/// `revset_counts` / `find_changes` after a `describe`, a `["log"]` scope does.
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
    let expressions = ["scoped_at()".to_owned()];

    // Before the describe, so `describe` is the last verb the reads follow; `@`'s change id stays.
    let op = repo.op_log(Some(1)).expect("op log").remove(0).id;
    fs::write(&user_file, scoped("describe")).unwrap();
    let at = wc(&repo);
    repo.describe(at, "x").expect("describe");
    assert_ne!(repo.log_defaults().expect("log defaults").log, "scoped");
    assert!(
        resolve_revset(&repo, "scoped_at()").is_err(),
        "the describe-scoped alias is not `log`'s"
    );
    let counts = repo.revset_counts(&op, &expressions, 10).expect("counts").counts;
    assert!(counts[0].is_err(), "not `revset_counts`' either: {counts:?}");
    let found = repo.find_changes(&op, "scoped_at()", 10, "").map_err(|w| w.value);
    assert!(
        matches!(found, Err(RevsetSearchError::Revset(_))),
        "nor `find_changes`': {found:?}"
    );

    fs::write(&user_file, scoped("log")).unwrap();
    assert_eq!(repo.log_defaults().expect("log defaults").log, "scoped");
    assert_eq!(
        resolve_revset(&repo, "scoped_at()").expect("the log-scoped alias"),
        [wc(&repo)]
    );
    let counts = repo.revset_counts(&op, &expressions, 10).expect("counts").counts;
    assert_eq!(counts[0].as_ref().expect("the log-scoped alias").n, 1);
    let found = repo
        .find_changes(&op, "scoped_at()", 10, "")
        .expect("the log-scoped alias");
    assert_eq!(
        found.entries.iter().map(|e| e.change_id.clone()).collect::<Vec<_>>(),
        [wc(&repo)]
    );
}

/// One config verb call, returning its warnings.
type ConfigCall<'a> = &'a dyn Fn() -> Vec<Warning>;

/// The free config verbs resolve their start-up for their own CLI command: a deprecated key in a
/// scope for that command warns `ConfigDeprecated` (the start-up's migration), one in a
/// `["describe"]` scope does not. The verb's own result does not matter.
#[test]
fn every_config_verb_resolves_for_its_cli_command() {
    test_helpers::own_process!("every_config_verb_resolves_for_its_cli_command");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    let scoped = |command: &str| {
        format!(
            "[[--scope]]\n--when.commands = [\"{command}\"]\n\
             [--scope.fix.tools.t]\nline-range-arg = \"--l\"\n"
        )
    };
    let user = ConfigTarget::Scope(ConfigScope::User);
    let rewrite = || fs::read_to_string(&user_file).unwrap();
    let verbs: [(&str, &str, ConfigCall); 9] = [
        ("config_list", "config list", &|| {
            config_list(None, &ConfigListQuery::default()).warnings
        }),
        ("config_get", "config get", &|| config_get(None, "nope").warnings),
        ("config_path", "config path", &|| {
            config_path(None, ConfigScope::User).warnings
        }),
        ("config_set", "config set", &|| {
            config_set(None, &user, "test.x", "1").warnings
        }),
        ("config_unset", "config unset", &|| {
            config_unset(None, &user, "nope").warnings
        }),
        ("config_file_read", "config edit", &|| {
            config_file_read(None, &user).warnings
        }),
        ("config_file_write", "config edit", &|| {
            config_file_write(None, &user_file, &rewrite()).warnings
        }),
        ("config_gc_list", "config gc", &|| config_gc_list().warnings),
        ("config_gc_delete", "config gc", &|| config_gc_delete(&[]).warnings),
    ];
    for (verb, command, call) in verbs {
        let deprecates = |scope: &str| {
            fs::write(&user_file, scoped(scope)).unwrap();
            call().iter().any(|w| w.kind == WarningKind::ConfigDeprecated)
        };
        assert!(deprecates(command), "`{verb}` must resolve for `{command}`");
        assert!(!deprecates("describe"), "`{verb}` must not resolve for `describe`");
    }
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

/// `config set user.name` snapshots for its working-copy author check inside `jj config set`, so a
/// `["config set"]`-scoped `snapshot.max-new-file-size` reaches that snapshot; a `["describe"]`
/// one does not.
#[test]
fn the_config_set_author_check_snapshots_for_config_set() {
    test_helpers::own_process!("the_config_set_author_check_snapshots_for_config_set");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    let repo = init_repo(tmp.path());
    let root = repo.workspace_root().to_owned();
    drop(repo);
    fs::write(root.join("big.txt"), "big\n").unwrap();
    let repo_target = ConfigTarget::Scope(ConfigScope::Repo);
    let too_large = |command: &str| {
        fs::write(
            &user_file,
            format!("[[--scope]]\n--when.commands = [\"{command}\"]\n[--scope.snapshot]\nmax-new-file-size = 1\n"),
        )
        .unwrap();
        let outcome = config_set(Some(&root), &repo_target, "user.name", "X");
        let report = outcome.precondition.expect("the author check snapshotted");
        report
            .snapshot_stats
            .untracked
            .iter()
            .any(|u| u.path == "big.txt" && matches!(u.reason, UntrackedReason::FileTooLarge { .. }))
    };
    assert!(too_large("config set"), "the `config set` scope reaches the snapshot");
    assert!(!too_large("describe"), "a `describe` scope does not");
}

/// A Git repository at `dir` with one commit.
fn git_repo(dir: &Path) {
    fs::create_dir_all(dir).unwrap();
    git(&["init", "--initial-branch=main"], dir);
    git(&["config", "user.email", "test@zanshin.test"], dir);
    git(&["config", "user.name", "Fixture"], dir);
    fs::write(dir.join("README.md"), "hello").unwrap();
    git(&["add", "."], dir);
    git(&["commit", "-m", "initial"], dir);
}

/// Both conversions play `jj git init` at every site that resolves the config: the start-up check
/// (it refuses a scoped fault before the path checks — a plain directory would otherwise refuse
/// "not a Git repo") and the new workspace's settings (a scoped operation user signs the
/// conversion). The refs step's site is the oracle's (`convert_*_when_commands_refs_fault`).
#[test]
fn the_conversions_resolve_for_git_init() {
    test_helpers::own_process!("the_conversions_resolve_for_git_init");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    let plain = tmp.path().join("plain");
    fs::create_dir_all(&plain).unwrap();
    for command in ["git init", "git clone"] {
        fs::write(
            &user_file,
            format!("[[--scope]]\n--when.commands = [\"{command}\"]\n[--scope.user]\nname = 1\n"),
        )
        .unwrap();
        let scoped = command == "git init";
        for (verb, err) in [
            ("convert_colocated", zanshin_jj::convert_colocated(&plain).result.err()),
            (
                "convert_import",
                zanshin_jj::convert_import(&plain, &tmp.path().join("dest"))
                    .result
                    .err(),
            ),
        ] {
            let err = err.unwrap_or_else(|| panic!("{verb} refuses"));
            assert_eq!(
                matches!(&err, RepoError::Config { reason } if reason.contains("user.name")),
                scoped,
                "`{verb}` under a `{command}` scope: {err:?}"
            );
        }
    }

    fs::write(
        &user_file,
        format!("{BASE_IDENTITY}[[--scope]]\n--when.commands = [\"git init\"]\n[--scope.operation]\nusername = \"converter\"\n"),
    )
    .unwrap();
    let colocated = tmp.path().join("colocated");
    git_repo(&colocated);
    let repo = zanshin_jj::convert_colocated(&colocated)
        .result
        .expect("convert_colocated");
    assert_eq!(head_facts(repo.workspace_root()).1, "converter", "convert_colocated");
    let src = tmp.path().join("src");
    git_repo(&src);
    let repo = zanshin_jj::convert_import(&src, &tmp.path().join("imported"))
        .result
        .expect("convert_import");
    assert_eq!(head_facts(repo.workspace_root()).1, "converter", "convert_import");
}

/// A scope whose `immutable_heads()` does not parse — it faults the start-up of the verbs it
/// reaches (`Invalid revset-aliases.immutable_heads()`).
fn broken_immutable_scope(command: &str) -> String {
    format!("[[--scope]]\n--when.commands = [\"{command}\"]\n[--scope.revset-aliases]\n\"immutable_heads()\" = \"(\"\n")
}

/// A scope making `revision` immutable for `command`.
fn immutable_scope(command: &str, revision: &ChangeId) -> String {
    format!(
        "[[--scope]]\n--when.commands = [\"{command}\"]\n[--scope.revset-aliases]\n\"immutable_heads()\" = \"{}\"\n",
        revision.0
    )
}

/// Two siblings off the root: `S` (described, not `@`) and `T` (`@`).
fn siblings(repo: &mut Repo) -> (ChangeId, ChangeId) {
    let s = wc(repo);
    repo.describe(s.clone(), "S").expect("describe S");
    let root = resolve_revset(repo, "root()").expect("root resolves").remove(0);
    repo.new_change(&[root], &[], &[]).expect("new T");
    (s, wc(repo))
}

/// `select_tree` resolves for the verb it names: a `["split"]` scope that faults the start-up
/// refuses `select_tree` for `split` only.
#[test]
fn a_split_scope_reaches_select_tree_for_split_only() {
    test_helpers::own_process!("a_split_scope_reaches_select_tree_for_split_only");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    let mut repo = init_repo(tmp.path());
    fs::write(&user_file, broken_immutable_scope("split")).unwrap();
    let left = repo.show(None, None).expect("show @").swap_remove(0).parent_tree_ids;
    let select = |verb| SelectTreeOptions {
        revision: None,
        from: None,
        left: left.clone(),
        files: Vec::new(),
        verb,
    };

    let err = repo
        .select_tree(&select(Some(SelectTreeVerb::Split)))
        .expect_err("the split scope faults split's start-up");
    assert!(
        matches!(&err, MutateError::Precondition(PreconditionError::Config { reason }) if reason.contains("immutable_heads()")),
        "{err:?}"
    );
    repo.select_tree(&select(None)).expect("no verb: no command, no scope");
    repo.select_tree(&select(Some(SelectTreeVerb::Commit)))
        .expect("commit: not split");
}

/// The statuses and refusals of a drop query's rows, by verb.
fn drop_rows(repo: &mut Repo, s: &ChangeId, t: &ChangeId) -> Vec<(DropVerb, ActionStatus, String)> {
    let location = DropLocation {
        onto: vec![t.clone()],
        ..DropLocation::default()
    };
    repo.drop_actions(&DropSource::Change(s.clone()), &[location])
        .expect("drop_actions")
        .actions
        .into_iter()
        .map(|row| (row.verb, row.outcome.status, format!("{:?}", row.outcome.refusal)))
        .collect()
}

/// A `["rebase"]` scope making `S` immutable refuses the three rebase rows of dropping `S` onto
/// `T`; every other row answers as without the scope.
#[test]
fn a_rebase_scope_reaches_the_drop_queries_rebase_rows_only() {
    test_helpers::own_process!("a_rebase_scope_reaches_the_drop_queries_rebase_rows_only");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    let mut repo = init_repo(tmp.path());
    let (s, t) = siblings(&mut repo);
    let unscoped = drop_rows(&mut repo, &s, &t);
    fs::write(&user_file, immutable_scope("rebase", &s)).unwrap();
    let scoped = drop_rows(&mut repo, &s, &t);

    assert_eq!(scoped.len(), unscoped.len());
    let rebase = [
        DropVerb::RebaseSource,
        DropVerb::RebaseRevisions,
        DropVerb::RebaseBranch,
    ];
    for (before, after) in unscoped.iter().zip(&scoped) {
        assert_eq!(before.0, after.0, "row order");
        if rebase.contains(&after.0) {
            assert_eq!(before.1, ActionStatus::Available, "{before:?}");
            assert_eq!(after.1, ActionStatus::Refused, "{after:?}");
            assert!(after.2.contains("Immutable"), "{after:?}");
        } else {
            assert_eq!(before, after, "a row the scope does not reach");
        }
    }
    for verb in [DropVerb::Squash, DropVerb::NewMerge, DropVerb::Duplicate] {
        let row = scoped.iter().find(|row| row.0 == verb).expect("the row");
        assert_eq!(row.1, ActionStatus::Available, "{row:?}");
    }
}

/// An `["abandon"]` scope making `X` immutable refuses the card's abandon row only.
#[test]
fn an_abandon_scope_reaches_the_cards_abandon_row_only() {
    test_helpers::own_process!("an_abandon_scope_reaches_the_cards_abandon_row_only");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    let mut repo = init_repo(tmp.path());
    let (x, _) = siblings(&mut repo);
    fs::write(&user_file, immutable_scope("abandon", &x)).unwrap();
    let card = repo.change_actions(&x).expect("change_actions");

    assert_eq!(card.abandon.status, ActionStatus::Refused, "{:?}", card.abandon);
    assert!(
        matches!(card.abandon.refusal, Some(MutateError::Immutable { .. })),
        "{:?}",
        card.abandon
    );
    for (name, row) in [
        ("describe", &card.describe),
        ("new", &card.new_onto),
        ("new -A", &card.new_insert_after),
        ("new -B", &card.new_insert_before),
        ("edit", &card.edit),
    ] {
        assert_eq!(row.status, ActionStatus::Available, "{name}: {row:?}");
    }
}

/// A `["describe"]` scope that faults the start-up refuses the card's describe row with the
/// verb's start-up error; the call and the other rows go on.
#[test]
fn a_faulting_describe_scope_refuses_the_describe_row_not_the_query() {
    test_helpers::own_process!("a_faulting_describe_scope_refuses_the_describe_row_not_the_query");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    let mut repo = init_repo(tmp.path());
    let (x, _) = siblings(&mut repo);
    fs::write(&user_file, broken_immutable_scope("describe")).unwrap();
    let card = repo.change_actions(&x).expect("a row's fault is not the query's");

    assert_eq!(card.describe.status, ActionStatus::Refused);
    assert!(
        matches!(&card.describe.refusal, Some(MutateError::Precondition(PreconditionError::Config { reason })) if reason.contains("immutable_heads()")),
        "{:?}",
        card.describe
    );
    let start_up = repo.describe(x.clone(), "x").expect_err("the verb refuses the same");
    assert_eq!(
        format!("{start_up:?}"),
        format!("{:?}", card.describe.refusal.expect("refusal"))
    );
    for (name, row) in [
        ("abandon", &card.abandon),
        ("new", &card.new_onto),
        ("edit", &card.edit),
    ] {
        assert_eq!(row.status, ActionStatus::Available, "{name}: {row:?}");
    }
}

/// Every action row by a label naming its CLI command, and whether it is refused with a start-up
/// config fault: `S` dropped onto `T`, `S`'s selection at `-A T`, bookmark `b` onto `T`, `S`'s card.
fn start_up_faults(repo: &mut Repo, s: &ChangeId, t: &ChangeId) -> Vec<(String, bool)> {
    let faulted = |outcome: &zanshin_jj::ActionOutcome| {
        matches!(
            outcome.refusal,
            Some(MutateError::Precondition(PreconditionError::Config { .. }))
        )
    };
    let label = |verb: DropVerb| {
        match verb {
            DropVerb::RebaseSource | DropVerb::RebaseRevisions | DropVerb::RebaseBranch => "rebase",
            DropVerb::Squash => "squash",
            DropVerb::NewMerge => "new",
            DropVerb::Duplicate => "duplicate",
            DropVerb::Split => "split",
            DropVerb::BookmarkMove => "bookmark move",
            DropVerb::Revert => "revert",
            DropVerb::Restore => "restore",
            DropVerb::Absorb => "absorb",
            DropVerb::Interdiff => "interdiff",
        }
        .to_owned()
    };
    let onto = DropLocation {
        onto: vec![t.clone()],
        ..DropLocation::default()
    };
    let after = DropLocation {
        insert_after: vec![t.clone()],
        ..DropLocation::default()
    };
    let mut rows = Vec::new();
    for (source, location) in [
        (DropSource::Change(s.clone()), onto.clone()),
        (
            DropSource::Selection {
                change: s.clone(),
                paths: vec!["f".to_owned()],
            },
            after,
        ),
        (DropSource::Bookmark("b".to_owned()), onto),
    ] {
        for row in repo.drop_actions(&source, &[location]).expect("drop_actions").actions {
            rows.push((label(row.verb), faulted(&row.outcome)));
        }
    }
    let card = repo.change_actions(s).expect("change_actions");
    for (command, outcome) in [
        ("new", &card.new_onto),
        ("new", &card.new_insert_after),
        ("new", &card.new_insert_before),
        ("edit", &card.edit),
        ("describe", &card.describe),
        ("squash", &card.squash_into_parent),
        ("abandon", &card.abandon),
    ] {
        rows.push((command.to_owned(), faulted(outcome)));
    }
    rows
}

/// Each row resolves for its own verb's command: a start-up-faulting scope for one command
/// refuses exactly the rows that play it, for every command a row plays.
#[test]
fn a_faulting_scope_refuses_exactly_the_rows_of_its_command() {
    test_helpers::own_process!("a_faulting_scope_refuses_exactly_the_rows_of_its_command");
    let tmp = tempfile::tempdir().unwrap();
    let user_file = isolate(tmp.path());
    let mut repo = init_repo(tmp.path());
    let (s, t) = siblings(&mut repo);
    repo.bookmark_create(&["b".to_owned()], Some(&s)).expect("bookmark b");
    let unscoped = start_up_faults(&mut repo, &s, &t);
    assert!(unscoped.iter().all(|(_, faulted)| !faulted), "{unscoped:?}");

    let mut commands: Vec<String> = unscoped.iter().map(|(command, _)| command.clone()).collect();
    commands.sort();
    commands.dedup();
    assert_eq!(commands.len(), 13, "every row command: {commands:?}");
    for command in &commands {
        fs::write(&user_file, broken_immutable_scope(command)).unwrap();
        for (row, faulted) in start_up_faults(&mut repo, &s, &t) {
            assert_eq!(faulted, &row == command, "scope {command}, row {row}");
        }
    }
}
