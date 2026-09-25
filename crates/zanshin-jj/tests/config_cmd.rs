// SPDX-License-Identifier: MIT

//! Story 9.28 witness: the `jj config` surface at repo and workspace scope, through the public
//! API only (user-scope rows live in `config_cmd_user.rs`, which repoints `JJ_CONFIG`).
//!
//! Oracles: the files on disk, and the head operation read with jj-lib directly — every config
//! write must leave `jj op log` unchanged (only `set`'s identity snapshot may add one, exactly
//! as the CLI's `check_wc_author` does).
//!
//! `JJ_USER`/`JJ_EMAIL` are REMOVED here (not pinned like the rest of the suite): a repo-scope
//! `user.name` must be able to take effect, and the `EnvOverrides` identity would shadow it.

use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{
    config_file_read, config_file_write, config_gc_delete, config_gc_list, config_get, config_list, config_path,
    config_set, config_unset, resolve_revset, Backend, ConfigCmdError, ConfigListQuery, ConfigScope, ConfigValueSource,
    Repo, RepoError, WarningKind,
};

/// The process-lifetime `$XDG_CONFIG_HOME` — LEAKED so it outlives every test (see
/// `tests/git_remotes.rs`); without it the secure repo config would land in the developer's
/// real `~/.config/jj`.
static ENV_GUARD: LazyLock<PathBuf> = LazyLock::new(|| {
    let xdg = TempDir::new().expect("xdg tempdir").keep();
    // SAFETY: set once, before any test body runs, and never changed afterwards.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::remove_var("JJ_USER");
        env::remove_var("JJ_EMAIL");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
        env::set_var("XDG_CONFIG_HOME", &xdg);
    }
    xdg
});

fn xdg() -> &'static Path {
    &ENV_GUARD
}

/// A fresh workspace; returns `(tempdir, canonical root)`.
fn workspace(backend: Option<Backend>) -> (TempDir, PathBuf) {
    xdg();
    let tmp = TempDir::new().unwrap();
    let root = tmp.path().join("ws");
    fs::create_dir(&root).unwrap();
    Repo::init(&root, backend).result.expect("init");
    let root = fs::canonicalize(&root).unwrap();
    (tmp, root)
}

/// `(head op id, @'s author name)` straight from the store.
fn head(root: &Path) -> (String, String) {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle load");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("head");
    let wc = repo.view().get_wc_commit_id(workspace.workspace_name()).expect("@");
    let author = repo.store().get_commit(wc).expect("commit").author().name.clone();
    (repo.op_id().hex(), author)
}

fn scoped(scope: ConfigScope) -> ConfigListQuery {
    ConfigListQuery {
        scope: Some(scope),
        ..ConfigListQuery::default()
    }
}

#[test]
fn repo_scope_round_trip_writes_the_secure_file_and_no_operation() {
    let (_tmp, root) = workspace(Some(Backend::Git));
    let op = head(&root).0;

    let path = config_path(Some(&root), ConfigScope::Repo).result.expect("path");
    assert!(path[0].starts_with(xdg().join("jj").join("repos")), "{path:?}");
    assert!(root.join(".jj").join("repo").join("config-id").exists());

    let set = config_set(Some(&root), ConfigScope::Repo, "revsets.log", "@", None);
    assert!(set.precondition.is_none());
    let written = set.result.expect("set");
    assert_eq!(std::slice::from_ref(&written.path), path.as_slice());
    assert_eq!(config_get(Some(&root), "revsets.log").result.unwrap(), "@");
    assert_eq!(
        Repo::open(&root).unwrap().log_defaults().unwrap().log,
        "@",
        "the read side sees the same file"
    );

    let listed = config_list(Some(&root), &scoped(ConfigScope::Repo));
    assert!(listed.warnings.is_empty(), "{:?}", listed.warnings);
    let rows = listed.result.unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(
        (rows[0].name.as_str(), rows[0].value.as_str(), rows[0].source),
        ("revsets.log", "\"@\"", ConfigValueSource::Repo)
    );
    assert_eq!(rows[0].path.as_deref(), Some(written.path.as_path()));

    assert_eq!(
        config_unset(Some(&root), ConfigScope::Repo, "revsets.log", None)
            .result
            .unwrap(),
        written.path
    );
    let empty = config_list(Some(&root), &scoped(ConfigScope::Repo));
    assert!(empty.result.unwrap().is_empty());
    // Story 9.32: the CLI's stderr note explaining the empty output.
    assert_eq!(empty.warnings.len(), 1, "{:?}", empty.warnings);
    assert_eq!(empty.warnings[0].kind, WarningKind::ConfigNothingListed);
    assert_eq!(empty.warnings[0].message, "No config to list.");
    assert!(matches!(
        config_unset(Some(&root), ConfigScope::Repo, "nope", None).result,
        Err(ConfigCmdError::NotFound { .. })
    ));
    assert_eq!(head(&root).0, op, "config writes are not repo state: no operation");
}

#[test]
fn tables_refuse_set_and_unset_but_get_prints_them_inline() {
    let (_tmp, root) = workspace(None);
    config_set(Some(&root), ConfigScope::Repo, "revset-aliases.'x()'", "@", None)
        .result
        .expect("set a leaf");
    let file = config_path(Some(&root), ConfigScope::Repo).result.unwrap().remove(0);
    let before = fs::read_to_string(&file).unwrap();
    assert!(matches!(
        config_set(Some(&root), ConfigScope::Repo, "revset-aliases", "x", None).result,
        Err(ConfigCmdError::WouldOverwrite { .. })
    ));
    assert!(matches!(
        config_unset(Some(&root), ConfigScope::Repo, "revset-aliases", None).result,
        Err(ConfigCmdError::WouldDeleteTable { .. })
    ));
    assert_eq!(fs::read_to_string(&file).unwrap(), before, "nothing written");
    let table = config_get(Some(&root), "revset-aliases").result.unwrap();
    assert!(table.starts_with('{') && table.contains("\"x()\" = \"@\""), "{table}");
}

#[test]
fn workspace_scope_and_the_editor_halves() {
    let (_tmp, root) = workspace(None);
    let read = config_file_read(Some(&root), ConfigScope::Workspace, None)
        .result
        .expect("read");
    assert!(read.path.starts_with(xdg().join("jj").join("workspaces")));
    assert!(read.text.starts_with("#:schema "), "{:?}", read.text);

    let err = config_file_write(Some(&root), &read.path, "[user\nname = ")
        .result
        .unwrap_err();
    assert!(matches!(err, ConfigCmdError::Parse { span: Some(_), .. }), "{err}");
    assert_eq!(fs::read_to_string(&read.path).unwrap(), read.text, "untouched");

    config_file_write(Some(&root), &read.path, "[revsets]\nlog = 'root()'\n")
        .result
        .expect("write");
    let rows = config_list(Some(&root), &scoped(ConfigScope::Workspace))
        .result
        .unwrap();
    assert_eq!(rows[0].source, ConfigValueSource::Workspace);
    assert_eq!(config_get(Some(&root), "revsets.log").result.unwrap(), "root()");
    assert!(matches!(
        config_file_write(Some(&root), &root.join("x.toml"), "").result,
        Err(ConfigCmdError::AmbiguousFile { .. })
    ));
}

#[test]
fn a_bad_root_refuses_like_repo_open() {
    xdg();
    let tmp = TempDir::new().unwrap();
    assert!(matches!(
        config_list(Some(&tmp.path().join("nope")), &ConfigListQuery::default()).result,
        Err(ConfigCmdError::PathNotFound { .. })
    ));
    assert!(matches!(
        config_get(Some(tmp.path()), "user.name").result,
        Err(ConfigCmdError::NotARepo { .. })
    ));
    assert!(matches!(
        config_path(None, ConfigScope::Workspace).result,
        Err(ConfigCmdError::NoConfigPath { .. })
    ));
}

/// An open handle picks a repo-scope `user.name` up on its very next mutation (Story 9.27's
/// fingerprint), and the identity check snapshots a dirty `@` exactly like the CLI.
#[test]
fn identity_writes_reload_the_handle_and_report_the_working_copy_author() {
    let (_tmp, root) = workspace(Some(Backend::Git));
    let mut repo = Repo::open(&root).expect("open");

    let set = config_set(Some(&root), ConfigScope::Repo, "user.name", "Reloaded", None);
    let fact = set
        .result
        .expect("set")
        .working_copy_author
        .expect("@ was authored by \"\"");
    assert_eq!((fact.name.as_str(), fact.email.as_str()), ("", ""));
    // Story 9.32: `warn_wc_author`'s three lines, verbatim.
    assert_eq!(set.warnings.len(), 1, "{:?}", set.warnings);
    assert_eq!(set.warnings[0].kind, WarningKind::ConfigWorkingCopyAuthor);
    assert_eq!(
        set.warnings[0].message,
        "This setting will only impact future commits.\nThe author of the working copy will stay \" <>\".\n\
         To change the working copy author, use \"jj metaedit --update-author\"."
    );
    let report = set.precondition.expect("the snapshot ran");
    assert!(!report.was_snapshot_taken, "a clean @: nothing to snapshot");

    let wc = resolve_revset(&repo, "@").unwrap();
    repo.new_change(&wc).expect("new change");
    assert_eq!(head(&root).1, "Reloaded", "the handle re-derived its settings");

    // A dirty @: the identity check writes the snapshot operation; another key does not.
    fs::write(root.join("dirty.txt"), "x").unwrap();
    let op = head(&root).0;
    let other = config_set(Some(&root), ConfigScope::Repo, "revsets.log", "@", None);
    assert!(other.precondition.is_none());
    assert_eq!(head(&root).0, op, "no snapshot for other keys");

    let set = config_set(Some(&root), ConfigScope::Repo, "user.name", "Reloaded", None);
    assert!(
        set.warnings
            .iter()
            .all(|w| w.kind != WarningKind::ConfigWorkingCopyAuthor),
        "same author: no warning"
    );
    assert!(set.result.expect("set").working_copy_author.is_none(), "same author");
    assert!(set.precondition.expect("ran").was_snapshot_taken);
    assert_ne!(head(&root).0, op, "the snapshot operation, as in the CLI");
}

/// The identity check's snapshot warnings are handed to the outcome BEFORE the author note —
/// the CLI's print order (Story 9.32): the snapshot's alias load warns first.
#[test]
fn identity_set_reports_the_snapshot_warnings_then_the_author_note() {
    let (_tmp, root) = workspace(Some(Backend::Git));
    config_set(Some(&root), ConfigScope::Repo, "revset-aliases.'bad('", "x", None)
        .result
        .expect("the CLI sets any leaf");

    let set = config_set(Some(&root), ConfigScope::Repo, "user.name", "Somebody", None);

    set.result.expect("set");
    assert_eq!(
        set.warnings.iter().map(|w| w.kind).collect::<Vec<_>>(),
        [WarningKind::ConfigAliasInvalid, WarningKind::ConfigWorkingCopyAuthor]
    );
}

/// The 9.27 carry-over: a wrong-typed key only the workspace LOAD reads makes `Repo::open`
/// refuse, but not the config verbs — which then repair it.
#[test]
fn a_wrong_typed_git_key_blocks_open_but_not_the_config_verbs() {
    let (_tmp, root) = workspace(Some(Backend::Git));
    config_set(
        Some(&root),
        ConfigScope::Repo,
        "git.abandon-unreachable-commits",
        "nope",
        None,
    )
    .result
    .expect("the CLI sets any key");
    assert!(matches!(Repo::open(&root), Err(RepoError::Config { .. })));

    let set = config_set(Some(&root), ConfigScope::Repo, "user.email", "a@b", None);
    assert!(
        set.result.expect("set").working_copy_author.is_none(),
        "open failed: skipped silently"
    );
    assert!(set.precondition.is_none());
    assert_eq!(
        config_get(Some(&root), "git.abandon-unreachable-commits")
            .result
            .unwrap(),
        "nope"
    );

    config_unset(Some(&root), ConfigScope::Repo, "git.abandon-unreachable-commits", None)
        .result
        .expect("unset");
    Repo::open(&root).expect("open works again");
}

/// A snapshot failure inside the identity check is skipped silently — its partial report kept.
#[test]
fn a_failing_identity_snapshot_is_skipped_but_reported() {
    let (_tmp, root) = workspace(None);
    config_set(Some(&root), ConfigScope::Repo, "snapshot.max-new-file-size", "[]", None)
        .result
        .expect("set");
    let set = config_set(Some(&root), ConfigScope::Repo, "user.name", "x", None);
    assert!(set.result.expect("set").working_copy_author.is_none());
    assert!(set.precondition.is_some(), "the partial report rides the outcome");
}

/// Recursive copy of a directory tree (files and directories only — a fresh `.jj` holds no
/// symlinks), standing in for a user's `cp -R` of a repo.
fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).unwrap();
        }
    }
}

/// A COPIED repo shares its original's `config-id`. The CLI (`SecureConfig`'s copy detection)
/// and `config_file_read` fork the copy's config before editing it, so `config_file_write`
/// through the copy must never accept — and overwrite — the ORIGINAL repo's file.
#[test]
fn file_write_through_a_copied_repo_never_reaches_the_original_config() {
    let (_tmp, root) = workspace(None);
    let original = config_file_read(Some(&root), ConfigScope::Repo, None)
        .result
        .expect("read")
        .path;
    let copy_tmp = TempDir::new().unwrap();
    copy_tree(&root, &copy_tmp.path().join("copy"));
    let copy = fs::canonicalize(copy_tmp.path().join("copy")).unwrap();
    let before = fs::read_to_string(&original).unwrap();

    assert!(matches!(
        config_file_write(Some(&copy), &original, "a = 1\n").result,
        Err(ConfigCmdError::AmbiguousFile { .. })
    ));
    assert_eq!(
        fs::read_to_string(&original).unwrap(),
        before,
        "the original is untouched"
    );

    let forked = config_file_read(Some(&copy), ConfigScope::Repo, None)
        .result
        .expect("read")
        .path;
    assert_ne!(forked, original, "the copy got its own config, as in the CLI");
    config_file_write(Some(&copy), &forked, "a = 1\n")
        .result
        .expect("the copy's own file");
    config_file_write(Some(&root), &original, "b = 1\n")
        .result
        .expect("the original from its own root");
    assert_eq!(fs::read_to_string(&forked).unwrap(), "a = 1\n");
}

/// A secondary workspace (its `.jj/repo` is a FILE pointing at the repo) reaches the SAME repo
/// config as the primary, and its own workspace config.
#[test]
fn a_secondary_workspace_shares_the_repo_config() {
    let (_tmp, root) = workspace(None);
    let (second, _wc) = test_helpers::add_workspace(&root, "second");
    let second_root = fs::canonicalize(&second.path).unwrap();
    assert!(second_root.join(".jj").join("repo").is_file());

    let repo_file = config_path(Some(&second_root), ConfigScope::Repo).result.expect("path");
    assert_eq!(
        repo_file,
        config_path(Some(&root), ConfigScope::Repo).result.unwrap(),
        "one repo config"
    );
    assert!(root.join(".jj").join("repo").join("config-id").exists());
    assert_ne!(
        config_path(Some(&second_root), ConfigScope::Workspace).result.unwrap(),
        config_path(Some(&root), ConfigScope::Workspace).result.unwrap(),
        "each workspace has its own"
    );

    config_set(Some(&second_root), ConfigScope::Repo, "revsets.log", "@", None)
        .result
        .expect("set");
    assert_eq!(config_get(Some(&root), "revsets.log").result.unwrap(), "@");
    let read = config_file_read(Some(&second_root), ConfigScope::Repo, None)
        .result
        .expect("read");
    assert_eq!(read.path, repo_file[0]);
    config_file_write(Some(&second_root), &read.path, "[revsets]\nlog = 'root()'\n")
        .result
        .expect("write");
    assert_eq!(config_get(Some(&root), "revsets.log").result.unwrap(), "root()");
}

#[test]
fn gc_lists_and_deletes_the_config_of_a_deleted_repo() {
    let (tmp, root) = workspace(None);
    let file = config_path(Some(&root), ConfigScope::Repo).result.unwrap().remove(0);
    let dir = file.parent().unwrap().to_owned();
    fs::remove_dir_all(tmp.path().join("ws")).unwrap();

    let missing = config_gc_list().expect("list");
    let mine = missing.iter().find(|m| m.config_dir == dir).expect("listed");
    assert_eq!(mine.repo_path, root.join(".jj").join("repo"));

    let result = config_gc_delete(std::slice::from_ref(&dir)).expect("delete");
    assert_eq!(result.value.deleted, std::slice::from_ref(&dir));
    assert!(result.value.failed.is_empty());
    assert!(result.warnings.is_empty());
    assert!(!dir.exists());
}
