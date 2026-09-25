// SPDX-License-Identifier: MIT

//! Story 9.37 witness: the jj CLI's start-up secure-config fix-up (`SecureConfig::
//! maybe_load_config`, run for the repo, then the workspace layer at the start of every command)
//! through the public API — `Repo::open_with_report`, a precondition-running verb, and the
//! root-taking config verbs. The mechanism's refusal order and its no-config-dir skip are
//! pinned inline in `src/config.rs`; the editor half under a broken user file lives in
//! `tests/secure_config_fixups_user.rs` (it repoints `JJ_CONFIG`).
//!
//! Oracles: the files on disk under the pinned `$XDG_CONFIG_HOME`, and the warnings' kinds and
//! jj-lib's texts verbatim.

use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use tempfile::TempDir;
use zanshin_jj::{
    config_get, config_list, config_path, config_set, ConfigCmdError, ConfigListQuery, ConfigScope, PreconditionError,
    Repo, RepoError, StatusError, Warning, WarningKind,
};

/// The process-lifetime `$XDG_CONFIG_HOME` — LEAKED so it outlives every test; every secure
/// config this binary migrates, forks or regenerates lands under it. No `JJ_RANDOMNESS_SEED`: a
/// seeded RNG would give a copy its original's id.
static ENV_GUARD: LazyLock<PathBuf> = LazyLock::new(|| {
    let xdg = test_helpers::leaked_xdg_config_home();
    // SAFETY: set once, before any test body runs, and never changed afterwards.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", &xdg);
    }
    xdg
});

fn xdg() -> &'static Path {
    &ENV_GUARD
}

const LEGACY: &str = "[test]\nmarker = \"legacy\"\n";

/// A fresh native-backend workspace (Zanshin's `init` writes no `config-id`); returns
/// `(tempdir, canonical root)`.
fn workspace() -> (TempDir, PathBuf) {
    xdg();
    let tmp = TempDir::new().unwrap();
    let root = tmp.path().join("ws");
    fs::create_dir(&root).unwrap();
    Repo::init(&root, None).result.expect("init");
    let root = fs::canonicalize(&root).unwrap();
    (tmp, root)
}

/// [`workspace`] plus a LEGACY `.jj/repo/config.toml`.
fn legacy_repo(body: &str) -> (TempDir, PathBuf) {
    let (tmp, root) = workspace();
    fs::write(repo_dir(&root).join("config.toml"), body).unwrap();
    (tmp, root)
}

fn repo_dir(root: &Path) -> PathBuf {
    root.join(".jj").join("repo")
}

fn repo_id(root: &Path) -> String {
    fs::read_to_string(repo_dir(root).join("config-id")).expect("config-id")
}

fn secure_file(kind: &str, id: &str) -> PathBuf {
    xdg().join("jj").join(kind).join(id).join("config.toml")
}

/// A repo's secure config directory, `<xdg>/jj/repos/<id>`.
fn secure_dir(id: &str) -> PathBuf {
    xdg().join("jj").join("repos").join(id)
}

fn kinds(warnings: &[Warning]) -> Vec<WarningKind> {
    warnings.iter().map(|w| w.kind).collect()
}

fn migrated_message(legacy: &Path, new: &Path) -> String {
    format!(
        "Your config file has been migrated from {} to {}. You can edit the new file with `jj config edit`",
        legacy.display(),
        new.display()
    )
}

/// A repo whose config lives in its secure directory already (`config set --repo`).
fn secure_repo(value: &str) -> (TempDir, PathBuf) {
    let (tmp, root) = workspace();
    config_set(Some(&root), ConfigScope::Repo, "test.marker", value, None)
        .result
        .expect("repo-scope set");
    (tmp, root)
}

/// "Migrate on open" + "No second run": the legacy file moves into `<xdg>/jj/repos/<id>/`, the
/// legacy path becomes a symlink, the read side lists it there — and the next verb finds nothing
/// left to do.
#[test]
fn open_migrates_a_legacy_repo_config_once() {
    let (_tmp, root) = legacy_repo(LEGACY);
    let opened = Repo::open_with_report(&root);
    assert!(opened.precondition.is_none(), "opening runs no snapshot");
    let mut repo = opened.result.expect("open");

    let id = repo_id(&root);
    assert!(id.len() == 20 && id.chars().all(|c| c.is_ascii_hexdigit()), "{id:?}");
    let new = secure_file("repos", &id);
    let legacy = repo_dir(&root).join("config.toml");
    assert_eq!(kinds(&opened.warnings), [WarningKind::ConfigMigrated]);
    assert_eq!(opened.warnings[0].message, migrated_message(&legacy, &new));
    assert_eq!(fs::read_to_string(&new).unwrap(), LEGACY);
    assert_eq!(
        fs::read_link(&legacy).unwrap(),
        new,
        "the legacy path is a symlink to it"
    );

    let query = ConfigListQuery {
        scope: Some(ConfigScope::Repo),
        ..ConfigListQuery::default()
    };
    let rows = config_list(Some(&root), &query).result.expect("list");
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(
        (rows[0].name.as_str(), rows[0].path.as_deref()),
        ("test.marker", Some(new.as_path()))
    );

    // No second run: the next verb's fix-up finds the migrated state.
    repo.status().expect("status");
    let warnings = repo.take_warnings();
    assert!(
        !warnings.iter().any(|w| matches!(
            w.kind,
            WarningKind::ConfigMigrated | WarningKind::ConfigCopied | WarningKind::ConfigRegenerated
        )),
        "{warnings:?}"
    );
    assert_eq!(repo_id(&root), id);
    assert_eq!(fs::read_to_string(&new).unwrap(), LEGACY);
}

/// "Both layers": the repo layer migrates first, then the workspace layer, each under its own
/// root (`repos` / `workspaces`).
#[test]
fn open_migrates_the_repo_then_the_workspace_layer() {
    let (_tmp, root) = legacy_repo(LEGACY);
    fs::write(root.join(".jj").join("workspace-config.toml"), "[ws]\nx = 1\n").unwrap();
    let opened = Repo::open_with_report(&root);
    opened.result.expect("open");

    let ws_id = fs::read_to_string(root.join(".jj").join("workspace-config-id")).expect("workspace id");
    assert_eq!(
        kinds(&opened.warnings),
        [WarningKind::ConfigMigrated, WarningKind::ConfigMigrated]
    );
    assert_eq!(
        opened.warnings[0].message,
        migrated_message(
            &repo_dir(&root).join("config.toml"),
            &secure_file("repos", &repo_id(&root))
        )
    );
    assert_eq!(
        opened.warnings[1].message,
        migrated_message(
            &root.join(".jj").join("workspace-config.toml"),
            &secure_file("workspaces", &ws_id)
        )
    );
}

/// "Copied repo": the copy forks its original's config under a new id and warns with jj-lib's
/// text; the original is untouched, and a second open of the copy warns nothing.
#[test]
fn opening_a_copied_repo_forks_its_config() {
    let (_tmp, a) = secure_repo("\"c\"");
    let id_a = repo_id(&a);
    let file_a = secure_file("repos", &id_a);
    let content = fs::read_to_string(&file_a).unwrap();
    let copy_tmp = TempDir::new().unwrap();
    copy_tree(&a, &copy_tmp.path().join("b"));
    let b = fs::canonicalize(copy_tmp.path().join("b")).unwrap();

    let opened = Repo::open_with_report(&b);
    opened.result.expect("open the copy");
    assert_eq!(kinds(&opened.warnings), [WarningKind::ConfigCopied]);
    assert_eq!(
        opened.warnings[0].message,
        format!(
            "Your repo appears to have been copied from {} to {}. The corresponding repo config file has also \
             been copied.",
            repo_dir(&a).display(),
            repo_dir(&b).display()
        )
    );
    let id_b = repo_id(&b);
    assert_ne!(id_b, id_a);
    assert_eq!(fs::read_to_string(secure_file("repos", &id_b)).unwrap(), content);
    assert_eq!(repo_id(&a), id_a, "the original's id is untouched");
    assert_eq!(fs::read_to_string(&file_a).unwrap(), content, "and so is its file");

    let again = Repo::open_with_report(&b);
    again.result.expect("open the copy again");
    assert!(again.warnings.is_empty(), "{:?}", again.warnings);
}

/// "Moved repo": no warning; the metadata re-points to the new place, the id stays.
#[test]
fn opening_a_moved_repo_repoints_its_metadata_silently() {
    let (_tmp, a) = secure_repo("\"m\"");
    let id = repo_id(&a);
    let c = a.with_file_name("moved");
    fs::rename(&a, &c).unwrap();

    let opened = Repo::open_with_report(&c);
    opened.result.expect("open the moved repo");
    assert!(opened.warnings.is_empty(), "{:?}", opened.warnings);
    assert_eq!(repo_id(&c), id);
    let metadata = jj_lib::secure_config::read_metadata(&secure_dir(&id)).expect("metadata.binpb");
    assert_eq!(
        jj_lib::secure_config::metadata_path(&metadata).expect("a path"),
        Some(repo_dir(&c).as_path())
    );
}

/// "Regenerated at verb start": the secure dir deleted under an open handle comes back at the
/// next verb's start, which warns first with jj-lib's `CONFIG_NOT_FOUND` text; the verb after it
/// warns nothing.
#[test]
fn a_deleted_secure_dir_is_regenerated_at_the_next_verb() {
    let (_tmp, root) = secure_repo("\"r\"");
    let mut repo = Repo::open(&root).expect("open");
    let dir = secure_dir(&repo_id(&root));
    fs::remove_dir_all(&dir).unwrap();

    repo.status().expect("status");
    let warnings = repo.take_warnings();
    assert_eq!(
        warnings.first().map(|w| w.kind),
        Some(WarningKind::ConfigRegenerated),
        "{warnings:?}"
    );
    assert_eq!(
        warnings[0].message,
        "Per-repo config not found. Generating an empty one.\nPer-repo config is stored in the same directory as \
         your user config for security reasons.\nIf you work across multiple computers, you may want to keep your \
         user config directory in sync."
    );
    assert!(dir.join("metadata.binpb").exists());

    repo.status().expect("status again");
    let warnings = repo.take_warnings();
    assert!(
        !warnings.iter().any(|w| w.kind == WarningKind::ConfigRegenerated),
        "{warnings:?}"
    );
}

/// "Failure keeps warning (config)": `config get` of an unset key right after the migration
/// refuses — and still reports the migration, which happened on disk.
#[test]
fn a_refused_config_verb_still_reports_the_migration() {
    let (_tmp, root) = legacy_repo(LEGACY);
    let outcome = config_get(Some(&root), "no.such");
    assert!(
        matches!(outcome.result, Err(ConfigCmdError::NotFound { .. })),
        "{:?}",
        outcome.result
    );
    assert_eq!(kinds(&outcome.warnings), [WarningKind::ConfigMigrated]);
    assert!(secure_file("repos", &repo_id(&root)).exists(), "migrated on disk");
}

/// "Failure keeps warning (open)": a legacy file that does not parse is migrated first, then
/// refuses naming the NEW file; `Repo::open` refuses the same way (warnings dropped).
#[test]
fn a_refused_open_still_reports_the_migration() {
    let (_tmp, root) = legacy_repo("not toml [");
    let opened = Repo::open_with_report(&root);
    let new = secure_file("repos", &repo_id(&root));
    match &opened.result {
        Err(RepoError::Config { reason }) => {
            assert!(reason.contains(&new.display().to_string()), "{reason}");
        }
        other => panic!("a config refusal: {other:?}"),
    }
    assert_eq!(kinds(&opened.warnings), [WarningKind::ConfigMigrated]);
    let again = Repo::open(&root).expect_err("the same refusal");
    assert_eq!(again.to_string(), opened.result.expect_err("refused").to_string());
}

/// A verb's OWN start-up fix-up migrates a broken legacy file that appeared after the open, then
/// the refresh refuses it — and the verb still reports the migration (the precondition keeps the
/// fix-up's warnings on a failed refresh).
#[test]
fn a_refused_verb_still_reports_its_own_migration() {
    let (_tmp, root) = workspace();
    let mut repo = Repo::open(&root).expect("open");
    fs::write(repo_dir(&root).join("config.toml"), "not toml [").unwrap();

    let err = repo.status().expect_err("the migrated file does not parse");
    assert!(
        matches!(err, StatusError::Precondition(PreconditionError::Config { .. })),
        "{err:?}"
    );
    assert_eq!(kinds(&repo.take_warnings()), [WarningKind::ConfigMigrated]);
}

/// A secure dir holding NO `config.toml` — deleting it changes no file the stack fingerprint
/// stamps, so only a fix-up that runs on EVERY verb (not just on a changed fingerprint)
/// regenerates it.
#[test]
fn a_deleted_secure_dir_without_a_config_file_is_regenerated_at_the_next_verb() {
    let (_tmp, root) = workspace();
    config_path(Some(&root), ConfigScope::Repo)
        .result
        .expect("creates the secure dir");
    let dir = secure_dir(&repo_id(&root));
    assert!(
        !dir.join("config.toml").exists(),
        "`config path` creates no config.toml"
    );
    let mut repo = Repo::open(&root).expect("open");
    fs::remove_dir_all(&dir).unwrap();

    repo.status().expect("status");
    let warnings = repo.take_warnings();
    assert_eq!(
        warnings.first().map(|w| w.kind),
        Some(WarningKind::ConfigRegenerated),
        "{warnings:?}"
    );
    assert!(dir.join("metadata.binpb").exists());
}

/// The config verbs' print order: the fix-up's notice FIRST — before `config list`'s "nothing to
/// list" note, and before `config set`'s working-copy-author note, which comes LAST.
#[test]
fn config_verbs_report_the_migration_before_their_own_warnings() {
    let (_tmp, root) = legacy_repo(LEGACY);
    let query = ConfigListQuery {
        name: Some("no.such".to_owned()),
        ..ConfigListQuery::default()
    };
    let listed = config_list(Some(&root), &query);
    assert!(listed.result.expect("list").is_empty());
    assert_eq!(
        kinds(&listed.warnings),
        [WarningKind::ConfigMigrated, WarningKind::ConfigNothingListed]
    );

    let (_tmp, root) = legacy_repo(LEGACY);
    let set = config_set(Some(&root), ConfigScope::Repo, "user.name", "Somebody Else", None);
    let written = set.result.expect("set");
    assert!(
        written.working_copy_author.is_some(),
        "@'s author is the pinned `Zanshin`"
    );
    let kinds = kinds(&set.warnings);
    assert_eq!(kinds.first(), Some(&WarningKind::ConfigMigrated), "{kinds:?}");
    assert_eq!(kinds.last(), Some(&WarningKind::ConfigWorkingCopyAuthor), "{kinds:?}");
}

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
