// SPDX-License-Identifier: MIT

//! The commit-summary hints against the pinned CLI (Story 9.56 closing run): the immutable
//! refusal's "Could not modify commit: …", push's "Rejected commit: …" and (Story 9.10) `jj next`'s
//! not-found "Working copy parent: …" render `templates.commit_summary`. Each witness refuses
//! through Zanshin and through the pinned `jj` on the SAME repo (a refusal writes no operation, so
//! both see one state) and compares Zanshin's hint with the CLI's `Hint: ` stderr line verbatim.
//! The name-pattern witnesses (Story 9.59 closing run) compare the whole error text too. The
//! config-file witnesses (Story 9.60 closing run) compare the whole `Config error:` /
//! `Internal error:` text without its label and the "Check the config file" hint. The push
//! commit-check witness compares an unresolvable `immutable_heads()`'s whole resolution error and
//! its hints.

use std::ops::ControlFlow;
use std::path::Path;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::op_store::OperationId;
use zanshin_jj::{ChangeId, GitPushArgs, MovementOptions, Repo};

use crate::driver::{fresh_repo, git, jj, Step};
use crate::scenarios::BASE;

/// `immutable_heads()` = `b-mark`: B and A are immutable.
const B_IMMUTABLE: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "revset-aliases.'immutable_heads()'",
    "b-mark",
])];

/// A custom `templates.commit_summary`.
const CUSTOM_SUMMARY: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "templates.commit_summary",
    "'commit_id.short() ++ \" custom\"'",
])];

/// A bare remote `origin` beside the repo and an undescribed `@` on C.
const UNDESCRIBED_AT_WITH_REMOTE: &[Step] = &[
    Step::Git(&["init", "-q", "--bare", "../remote.git"]),
    Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
    Step::Jj(&["new"]),
];

/// A local bookmark `here` on that `@`.
const BOOKMARKED_AT: &[Step] = &[Step::Jj(&["bookmark", "create", "here", "-r", "@"])];

/// The CLI's `Hint: ` line that starts with `prefix`, without the `Hint: ` label.
#[track_caller]
fn cli_hint(args: &[&str], root: &Path, prefix: &str) -> String {
    let run = jj(root, args);
    assert!(!run.success, "the CLI refuses {args:?}");
    run.stderr
        .lines()
        .find_map(|line| line.strip_prefix("Hint: ").filter(|hint| hint.starts_with(prefix)))
        .unwrap_or_else(|| panic!("no {prefix:?} hint in:\n{}", run.stderr))
        .to_owned()
}

/// The change id `revset` resolves to (one commit).
fn change(repo: &mut Repo, revset: &str) -> ChangeId {
    let mut found = None;
    let _ = repo
        .eval_revset(revset, |change| {
            found = Some(change.id);
            ControlFlow::Break(())
        })
        .expect("revset");
    found.expect("one commit")
}

/// Zanshin's `describe` of B and the CLI's `jj describe b-mark -m x` refuse with the same first
/// hint, which is returned.
fn assert_immutable_hint(setup: &[&[Step]]) -> String {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], setup);
    let cli = cli_hint(&["describe", "b-mark", "-m", "x"], &root, "Could not modify commit: ");
    let mut repo = Repo::open(&root).expect("open");
    let b = change(&mut repo, "b-mark");
    let err = repo.describe(b, "x\n").expect_err("B is immutable");
    assert_eq!(err.hints().first(), Some(&cli), "{err:?}");
    cli
}

/// Zanshin's `git push -c @` and the CLI's on an undescribed `@` refuse with the same first hint,
/// which is returned.
fn assert_rejected_commit_hint(setup: &[&[Step]]) -> String {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], setup);
    let cli = cli_hint(&["git", "push", "-c", "@"], &root, "Rejected commit: ");
    let mut repo = Repo::open(&root).expect("open");
    let err = repo
        .git_push(
            &GitPushArgs {
                changes: vec!["@".to_owned()],
                ..GitPushArgs::default()
            },
            &|_| {},
            None,
        )
        .expect_err("an undescribed @ is rejected");
    assert_eq!(err.hints().first(), Some(&cli), "{err:?}");
    cli
}

#[test]
fn immutable_hint_renders_the_default_summary_with_refs() {
    let hint = assert_immutable_hint(&[BASE, B_IMMUTABLE]);
    assert!(hint.ends_with(" b-mark | B"), "{hint}");
}

#[test]
fn immutable_hint_renders_a_custom_summary() {
    let hint = assert_immutable_hint(&[BASE, B_IMMUTABLE, CUSTOM_SUMMARY]);
    assert!(hint.ends_with(" custom"), "{hint}");
}

#[test]
fn rejected_commit_hint_renders_the_default_summary() {
    assert_rejected_commit_hint(&[BASE, UNDESCRIBED_AT_WITH_REMOTE]);
}

#[test]
fn rejected_commit_hint_renders_a_custom_summary() {
    assert_rejected_commit_hint(&[BASE, UNDESCRIBED_AT_WITH_REMOTE, CUSTOM_SUMMARY]);
}

#[test]
fn rejected_commit_hint_renders_the_refs_of_a_bookmarked_commit() {
    let hint = assert_rejected_commit_hint(&[BASE, UNDESCRIBED_AT_WITH_REMOTE, BOOKMARKED_AT]);
    assert!(hint.contains(" here | "), "{hint}");
}

/// An `immutable_heads()` that does not resolve refuses `jj git push` at its commit check, which
/// every push builds per remote: the CLI's bare `.resolve()?` gives its `Error:` text and its
/// "Did you mean" hint (`b-mar` is next to `b-mark`), and Zanshin's resolution error the same.
#[test]
fn unresolvable_immutable_heads_at_the_push_commit_check_refuses_with_the_cli_error_and_hints() {
    test_helpers::pin_test_env();
    let (_dir, root) = pushed_repo();
    jj(
        &root,
        &["config", "set", "--repo", "revset-aliases.'immutable_heads()'", "b-mar"],
    )
    .ok();
    let cli = cli_error(&["git", "push"], &root);
    let mut repo = Repo::open(&root).expect("open");
    let err = repo
        .git_push(&GitPushArgs::default(), &|_| {}, None)
        .expect_err("immutable_heads() does not resolve");
    assert!(
        matches!(&err, zanshin_jj::MutateError::RevsetResolutionError { reason, hints }
            if (reason, hints) == (&cli.0, &cli.1)),
        "{err:?} vs {cli:?}"
    );
    assert!(!cli.1.is_empty(), "{cli:?}");
}

/// Story 9.10: `jj next` with nothing after `@` refuses with one hint per start commit — here
/// `@`'s one parent, B — and so does Zanshin's move, verbatim.
#[test]
fn next_not_found_hint_renders_the_working_copy_parent_summary() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let cli = cli_hint(&["next"], &root, "Working copy parent: ");
    let mut repo = Repo::open(&root).expect("open");
    let err = repo
        .move_working_copy(&MovementOptions::default())
        .expect_err("nothing after @");
    assert_eq!(err.hints(), std::slice::from_ref(&cli), "{err:?}");
    assert!(cli.ends_with(" b-mark | B"), "{cli}");
}

/// The CLI's refusal of `args`: its `Error:` text without the label (every line before the first
/// `Hint: ` line) and its `Hint: ` lines without the label.
#[track_caller]
fn cli_error(args: &[&str], root: &Path) -> (String, Vec<String>) {
    cli_error_labeled("Error: ", args, root)
}

/// The CLI's refusal of `args` under `label` (`Error: ` or `Config error: `): its text without
/// the label (every line before the first `Hint: ` line) and its `Hint: ` lines without the label.
/// A config error's closing "For help, see …" line is no hint and no error line.
#[track_caller]
fn cli_error_labeled(label: &str, args: &[&str], root: &Path) -> (String, Vec<String>) {
    let run = jj(root, args);
    assert!(!run.success, "the CLI refuses {args:?}");
    let lines: Vec<&str> = run
        .stderr
        .lines()
        .skip_while(|line| !line.starts_with(label))
        .take_while(|line| !line.starts_with("For help, see "))
        .collect();
    let error = lines
        .iter()
        .take_while(|line| !line.starts_with("Hint: "))
        .copied()
        .collect::<Vec<_>>()
        .join("\n");
    let error = error
        .strip_prefix(label)
        .unwrap_or_else(|| panic!("no {label:?} line in:\n{}", run.stderr));
    let hints = lines
        .iter()
        .filter_map(|line| line.strip_prefix("Hint: "))
        .map(ToOwned::to_owned)
        .collect();
    (error.to_owned(), hints)
}

/// A refused verb's `jj.invalid_input` reason and hints.
#[track_caller]
fn refusal<T: std::fmt::Debug>(result: Result<T, zanshin_jj::MutateError>) -> (String, Vec<String>) {
    let err = result.expect_err("Zanshin refuses");
    let reason = err.to_string();
    let reason = reason.strip_prefix("invalid input: ").expect("an InvalidInput refusal");
    (reason.to_owned(), err.hints())
}

/// A refusal's `jj.config_error` context and hints, from its Display `text`: the reason without
/// the error's own `config error: ` label, which no carrier puts on the wire.
#[track_caller]
fn config_refusal(text: &str, hints: Vec<String>) -> (String, Vec<String>) {
    let reason = text.strip_prefix("config error: ").expect("a Config refusal");
    (reason.to_owned(), hints)
}

/// `remotes.origin.<field> = <value>` in the repo config, set through the CLI.
fn remote_pattern(root: &Path, field: &str, value: &str) {
    let key = format!("remotes.origin.{field}");
    jj(root, &["config", "set", "--repo", &key, value]).ok();
}

/// A bare `origin` beside a BASE repo, with `b-mark` pushed.
fn pushed_repo() -> (tempfile::TempDir, std::path::PathBuf) {
    fresh_repo(&["git", "init"], &[BASE, crate::git_scenarios::PUSHED])
}

/// Story 9.60: a `remotes.origin.fetch-bookmarks` syntax error refuses the fetch with the CLI's
/// `Config error:` text — the first line and the parse error's `Caused by:` caret diagram — and
/// its revsets-syntax hint, verbatim (that neither writes anything: `fetch_bad_remote_pattern`).
#[test]
fn bad_fetch_bookmarks_pattern_refuses_with_the_cli_config_error_and_hint() {
    test_helpers::pin_test_env();
    let (_dir, root) = pushed_repo();
    remote_pattern(&root, "fetch-bookmarks", "glob:(");
    let cli = cli_error_labeled("Config error: ", &["git", "fetch"], &root);
    let mut repo = Repo::open(&root).expect("open");
    let err = repo
        .git_fetch(&zanshin_jj::GitFetchArgs::default(), &|_| {}, None)
        .expect_err("the pattern does not parse");
    assert_eq!(config_refusal(&err.to_string(), err.hints()), cli);
    assert!(
        cli.0
            .starts_with("Invalid `remotes.origin.fetch-bookmarks`: Syntax error\nCaused by:  --> 1:7\n"),
        "{}",
        cli.0
    );
    assert_eq!(cli.1.len(), 1, "{:?}", cli.1);
}

/// The same for a string-pattern kind error in `fetch-tags`: the numbered `Caused by:` list and the
/// "Try prefixing" hint.
#[test]
fn bad_fetch_tags_kind_refuses_with_the_cli_config_error_and_hint() {
    test_helpers::pin_test_env();
    let (_dir, root) = pushed_repo();
    remote_pattern(&root, "fetch-tags", "bogus:x");
    let cli = cli_error_labeled("Config error: ", &["git", "fetch"], &root);
    let mut repo = Repo::open(&root).expect("open");
    let err = repo
        .git_fetch(&zanshin_jj::GitFetchArgs::default(), &|_| {}, None)
        .expect_err("the pattern does not parse");
    assert_eq!(config_refusal(&err.to_string(), err.hints()), cli);
    assert!(
        cli.0
            .starts_with("Invalid `remotes.origin.fetch-tags`: Invalid string pattern\nCaused by:\n1: "),
        "{}",
        cli.0
    );
    assert!(
        cli.1
            .first()
            .is_some_and(|h| h.starts_with("Try prefixing with one of ")),
        "{:?}",
        cli.1
    );
}

/// A colocated repo's start-up import reads `auto-track-bookmarks` before any verb: `jj git import`
/// and Zanshin's (through the pre-verb snapshot) refuse with the same text and hint.
#[test]
fn bad_auto_track_pattern_refuses_the_colocated_import_with_the_cli_config_error_and_hint() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init", "--colocate"], &[BASE]);
    remote_pattern(&root, "auto-track-bookmarks", "a b");
    let cli = cli_error_labeled("Config error: ", &["git", "import"], &root);
    let mut repo = Repo::open(&root).expect("open");
    let err = repo.git_import().expect_err("the pattern does not parse");
    assert!(
        matches!(
            err,
            zanshin_jj::MutateError::Precondition(zanshin_jj::PreconditionError::Config { .. })
        ),
        "{err:?}"
    );
    assert_eq!(config_refusal(&err.to_string(), err.hints()), cli);
    assert!(
        cli.0
            .starts_with("Invalid `remotes.origin.auto-track-bookmarks`: Syntax error\n"),
        "{}",
        cli.0
    );
    assert_eq!(cli.1.len(), 1, "{:?}", cli.1);
}

/// A clone's `fetch-tags` preset from the user config refuses with the same text and hint on both
/// sides. The user config changes the process environment, so this runs in a process of its own.
#[test]
fn bad_clone_fetch_tags_preset_refuses_with_the_cli_config_error_and_hint() {
    test_helpers::own_process!("bad_clone_fetch_tags_preset_refuses_with_the_cli_config_error_and_hint");
    test_helpers::pin_test_env();
    let dir = tempfile::TempDir::new().expect("tempdir");
    let root = dir.path().canonicalize().expect("canonical temp dir");
    let user = root.join("user.toml");
    std::fs::write(&user, "[remotes.origin]\nfetch-tags = \"bogus:x\"\n").expect("user config");
    // SAFETY: this test runs alone in a process of its own (`own_process!`), on one thread.
    unsafe { std::env::set_var("JJ_CONFIG", &user) };
    git(&root, &["init", "-q", "-b", "main", "src"]);
    std::fs::write(root.join("src/a.txt"), "a\n").expect("write");
    git(&root, &["-C", "src", "add", "."]);
    git(&root, &["-C", "src", "commit", "-q", "-m", "A"]);

    let cli = cli_error_labeled("Config error: ", &["git", "clone", "src", "cli"], &root);
    let outcome = zanshin_jj::Repo::clone(
        &zanshin_jj::CloneOptions {
            source: root.join("src").to_str().expect("UTF-8 temp dir").to_owned(),
            destination: root.join("zanshin"),
            ..Default::default()
        },
        &|_| {},
        None,
    );
    let err = outcome.result.expect_err("the preset does not parse");
    assert_eq!(config_refusal(&err.to_string(), err.hints()), cli);
    assert!(
        cli.0
            .starts_with("Invalid `remotes.origin.fetch-tags`: Invalid string pattern\n"),
        "{}",
        cli.0
    );
    assert_eq!(cli.1.len(), 1, "{:?}", cli.1);
    assert!(
        !root.join("cli").exists() && !root.join("zanshin").exists(),
        "both remove the destination"
    );
}

/// Story 9.59 closing run: a name pattern that does not parse refuses with the CLI's error text —
/// "Failed to parse name pattern: …" and the error's `Caused by:` lines — and its hint, verbatim.
#[test]
fn bad_name_pattern_refuses_with_the_cli_error_text_and_hint() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let cli = cli_error(&["tag", "delete", "bogus:x"], &root);
    let mut repo = Repo::open(&root).expect("open");
    assert_eq!(refusal(repo.tag_delete(&["bogus:x".to_owned()])), cli);
    assert!(
        cli.0
            .starts_with("Failed to parse name pattern: Invalid string pattern\n"),
        "{}",
        cli.0
    );
    assert!(
        cli.1
            .first()
            .is_some_and(|h| h.starts_with("Try prefixing with one of ")),
        "{:?}",
        cli.1
    );
}

/// The same for the tracking verbs' head, "name pattern or remote symbol", on a syntax error.
#[test]
fn bad_track_pattern_refuses_with_the_cli_error_text_and_hint() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let cli = cli_error(&["bookmark", "track", "a b"], &root);
    let mut repo = Repo::open(&root).expect("open");
    assert_eq!(refusal(repo.bookmark_track(&["a b".to_owned()], &[])), cli);
    assert!(
        cli.0
            .starts_with("Failed to parse name pattern or remote symbol: Syntax error\n"),
        "{}",
        cli.0
    );
    assert_eq!(cli.1.len(), 1, "{:?}", cli.1);
}

/// Fix run 10.2–10.5: a second workspace whose `@`'s tree the default one rewrote is stale (a new
/// description alone keeps it fresh); Zanshin's snapshot there refuses with the CLI's `Error: `
/// line verbatim (without the label) and the CLI's hint.
#[test]
fn stale_working_copy_message_is_the_cli_error_line() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(
        &["git", "init"],
        &[
            BASE,
            &[
                Step::Jj(&["workspace", "add", "../ws2"]),
                Step::Write("stale.txt", "x\n"),
                Step::Jj(&["squash", "--into", "ws2@"]),
            ],
        ],
    );
    let ws2 = root.join("..").join("ws2");
    let run = jj(&ws2, &["status"]);
    assert!(!run.success, "the CLI refuses a stale working copy");
    let cli = run
        .stderr
        .lines()
        .find_map(|line| line.strip_prefix("Error: "))
        .unwrap_or_else(|| panic!("no Error line in:\n{}", run.stderr));
    let err = Repo::open(&ws2)
        .expect("open ws2")
        .snapshot()
        .expect_err("ws2 is stale");
    assert_eq!(err.message().as_deref(), Some(cli), "{err:?}");
    assert!(
        cli.starts_with("The working copy is stale (not updated since operation "),
        "{cli}"
    );
    let cli_hint = cli_hint(&["status"], &ws2, "Run `jj workspace update-stale`");
    assert_eq!(
        err.hints().first().and_then(|h| h.lines().next()),
        Some(cli_hint.as_str())
    );
}

/// Finishes the working copy at `root` at the operation `op_hex` — how jj's own tests and
/// zanshin-jj's `snapshot_precondition` reach the sibling and missing-operation causes, which no
/// CLI command leaves behind.
fn finish_working_copy_at(root: &Path, op_hex: &str) {
    let mut workspace = test_helpers::load_workspace(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("load workspace");
    let op = OperationId::try_from_hex(op_hex).expect("hex operation id");
    let locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("lock");
    pollster::block_on(locked.finish(op)).expect("finish");
}

/// The stale working copy at `root`: Zanshin's snapshot refuses with the CLI's error line (its
/// `Error: ` or `Internal error: ` label stripped) and its first hint line starting with
/// `hint_prefix`.
#[track_caller]
fn assert_stale_matches_cli(root: &Path, hint_prefix: &str) {
    let run = jj(root, &["status"]);
    assert!(!run.success, "the CLI refuses a stale working copy");
    let cli = run
        .stderr
        .lines()
        .find_map(|line| {
            line.strip_prefix("Error: ")
                .or_else(|| line.strip_prefix("Internal error: "))
        })
        .unwrap_or_else(|| panic!("no Error line in:\n{}", run.stderr));
    let err = Repo::open(root).expect("open").snapshot().expect_err("stale");
    assert_eq!(err.message().as_deref(), Some(cli), "{err:?}");
    let cli_hint = cli_hint(&["status"], root, hint_prefix);
    assert_eq!(
        err.hints().first().and_then(|h| h.lines().next()),
        Some(cli_hint.as_str())
    );
}

/// The SIBLING cause: the working copy sits at an unpublished operation while another
/// operation from the same parent was published.
#[test]
fn stale_working_copy_at_a_sibling_operation_matches_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let (op, _) = test_helpers::add_unpublished_op(&root, "unpublished");
    finish_working_copy_at(&root, &op);
    let _ = test_helpers::add_commit_off_root(&root, "published sibling");
    assert_stale_matches_cli(&root, "Run `jj op integrate");
}

/// The NOT-FOUND cause: the working copy names an operation that does not exist.
#[test]
fn stale_working_copy_at_a_missing_operation_matches_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    finish_working_copy_at(&root, &"ab".repeat(64));
    assert_stale_matches_cli(&root, "Run `jj workspace update-stale`");
}

/// Story 11.22: converting a Git clone — `main` plus the untracked `origin/main` and a second
/// remote branch with no local bookmark — reports the remote bookmarks the CLI's `jj git init
/// --colocate` lists under its "aren't associated with the existing local bookmarks" hint, in its
/// order.
#[test]
fn conversion_lists_the_cli_trackable_remote_bookmarks() {
    test_helpers::pin_test_env();
    let dir = tempfile::TempDir::new().expect("tempdir");
    let root = dir.path();
    git(root, &["init", "-q", "-b", "main", "src"]);
    std::fs::write(root.join("src/a.txt"), "a\n").expect("write");
    git(root, &["-C", "src", "add", "."]);
    git(root, &["-C", "src", "commit", "-q", "-m", "A"]);
    git(root, &["-C", "src", "branch", "other"]);
    git(root, &["clone", "-q", "src", "cli"]);
    git(root, &["clone", "-q", "src", "zanshin"]);

    let run = jj(&root.join("cli"), &["git", "init", "--colocate"]).ok();
    let cli: Vec<String> = run
        .stderr
        .lines()
        .skip_while(|line| !line.contains("aren't associated with the existing local bookmarks"))
        .skip(1)
        .map_while(|line| line.strip_prefix("  "))
        .map(ToOwned::to_owned)
        .collect();
    assert_eq!(cli, ["main@origin"], "{}", run.stderr);

    let outcome = zanshin_jj::convert_colocated(&root.join("zanshin"));
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(outcome.trackable_remote_bookmarks, cli);
}

// ── Story 9.60 closing run: "Check the config file: <path>" ──────────────────

/// A BASE repo and its repo-level config file's path, as `jj config path --repo` prints it —
/// read before a test breaks the config, which can stop that command too.
fn repo_with_config_path() -> (tempfile::TempDir, std::path::PathBuf, String) {
    let (dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let path = jj(&root, &["config", "path", "--repo"])
        .ok()
        .stdout
        .trim_end()
        .to_owned();
    (dir, root, path)
}

/// The one hint both sides must give for a fault in the repo-level file.
fn check_file_hint(path: &str) -> Vec<String> {
    vec![format!("Check the config file: {path}")]
}

/// A wrong-typed snapshot knob: `jj status` and Zanshin's snapshot refuse with the same text —
/// the CLI's `Config error:` text without its label, no second label in the context — and hint.
#[test]
fn wrong_typed_snapshot_key_carries_the_cli_check_the_config_file_hint() {
    test_helpers::pin_test_env();
    let (_dir, root, path) = repo_with_config_path();
    jj(
        &root,
        &["config", "set", "--repo", "snapshot.max-new-file-size", "true"],
    )
    .ok();
    let cli = cli_error_labeled("Config error: ", &["status"], &root);
    let err = Repo::open(&root)
        .expect("open")
        .snapshot()
        .expect_err("the key has the wrong type");
    assert!(matches!(err, zanshin_jj::PreconditionError::Config { .. }), "{err:?}");
    assert_eq!(config_refusal(&err.to_string(), err.hints()), cli);
    assert_eq!(cli.1, check_file_hint(&path));
}

/// `Repo::open` at `root` refuses with a config error whose text and hints equal the CLI's
/// refusal of `jj status` under `label`; the CLI's (text, hints) are returned.
#[track_caller]
fn assert_open_refusal_is_the_clis(label: &str, root: &Path) -> (String, Vec<String>) {
    let cli = cli_error_labeled(label, &["status"], root);
    let err = Repo::open(root).map(|_| ()).expect_err("the open refuses");
    assert!(matches!(err, zanshin_jj::RepoError::Config { .. }), "{err:?}");
    assert_eq!(config_refusal(&err.to_string(), err.hints()), cli);
    cli
}

/// A repo-level file that is not TOML: `jj status` and `Repo::open` refuse with the same text —
/// the parse error and its caret diagram, no path — and the hint naming the file.
#[test]
fn toml_parse_error_carries_the_cli_check_the_config_file_hint() {
    test_helpers::pin_test_env();
    let (_dir, root, path) = repo_with_config_path();
    jj(&root, &["config", "set", "--repo", "a", "1"]).ok();
    std::fs::write(&path, "a = \n").expect("break the repo config");
    let (text, hints) = assert_open_refusal_is_the_clis("Config error: ", &root);
    assert!(
        text.starts_with("Configuration cannot be parsed as TOML document\nCaused by: TOML parse error"),
        "{text}"
    );
    assert_eq!(hints, check_file_hint(&path));
}

/// A repo-level "file" that is a directory: the CLI's read error names the path in its cause and
/// gives no hint, and so does `Repo::open`.
#[test]
fn unreadable_repo_config_is_the_cli_read_error_without_a_hint() {
    test_helpers::pin_test_env();
    let (_dir, root, path) = repo_with_config_path();
    jj(&root, &["config", "set", "--repo", "a", "1"]).ok();
    std::fs::remove_file(&path).expect("remove the repo config");
    std::fs::create_dir(&path).expect("a directory in its place");
    let (text, hints) = assert_open_refusal_is_the_clis("Config error: ", &root);
    assert_eq!(
        text,
        format!(
            "Failed to read configuration file\nCaused by:\n1: Cannot access {path}\n2: Is a directory (os error 21)"
        )
    );
    assert!(hints.is_empty(), "{hints:?}");
}

/// A failed `line-range-arg` migration: the same text — "Migration failed" and its numbered causes —
/// and the hint, not a reason line, names the file.
#[test]
fn failed_migration_carries_the_cli_check_the_config_file_hint() {
    test_helpers::pin_test_env();
    let (_dir, root, path) = repo_with_config_path();
    jj(&root, &["config", "set", "--repo", "fix.tools.t.line-range-arg", "1"]).ok();
    let (text, hints) = assert_open_refusal_is_the_clis("Config error: ", &root);
    assert!(
        text.starts_with("Migration failed\nCaused by:\n1: Invalid type or value for fix.tools.t.line-range-arg\n"),
        "{text}"
    );
    assert_eq!(hints, check_file_hint(&path));
}

/// A non-table `revset-aliases`: `jj log` and Zanshin's revset read refuse with the same text and
/// hint. The read's start-up environment builds the alias table, so the fault arrives as its
/// precondition's.
#[test]
fn non_table_revset_aliases_carries_the_cli_check_the_config_file_hint() {
    test_helpers::pin_test_env();
    let (_dir, root, path) = repo_with_config_path();
    jj(&root, &["config", "set", "--repo", "revset-aliases", "1"]).ok();
    let cli = cli_error_labeled("Config error: ", &["log"], &root);
    let mut repo = Repo::open(&root).expect("open");
    let err = repo
        .eval_revset("@", |_| ControlFlow::Break(()))
        .expect_err("the alias table is not a table");
    let zanshin_jj::RevsetError::Precondition(inner @ zanshin_jj::PreconditionError::Config { .. }) = &err else {
        panic!("a start-up config refusal: {err:?}");
    };
    assert_eq!(config_refusal(&inner.to_string(), inner.hints()), cli);
    assert_eq!(
        cli,
        (
            "Invalid type or value for revset-aliases\nCaused by: Expected a table, but is integer".to_owned(),
            check_file_hint(&path)
        )
    );
}

/// A key jj-lib reads while loading the working copy: the CLI reports its own load failure —
/// "Failed to read the tree state settings" and its causes — with no hint, and so does
/// Zanshin's `Repo::open`.
#[test]
fn workspace_load_fault_carries_no_hint_like_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root, _) = repo_with_config_path();
    jj(&root, &["config", "set", "--repo", "ui.conflict-marker-style", "1"]).ok();
    let (text, hints) = assert_open_refusal_is_the_clis("Internal error: ", &root);
    assert!(
        text.starts_with("Failed to read the tree state settings\nCaused by:\n1: "),
        "{text}"
    );
    assert!(hints.is_empty(), "{hints:?}");
}

/// A key the git backend reads while loading the store: the CLI's "The repository appears broken
/// or inaccessible" and its causes, with no hint, on both sides.
#[test]
fn git_backend_load_fault_is_the_cli_store_load_failure() {
    test_helpers::pin_test_env();
    let (_dir, root, _) = repo_with_config_path();
    jj(&root, &["config", "set", "--repo", "git.executable-path", "1"]).ok();
    let (text, hints) = assert_open_refusal_is_the_clis("Internal error: ", &root);
    assert!(
        text.starts_with(
            "The repository appears broken or inaccessible\nCaused by:\n1: Invalid type or value for git.executable-path\n"
        ),
        "{text}"
    );
    assert!(hints.is_empty(), "{hints:?}");
}
