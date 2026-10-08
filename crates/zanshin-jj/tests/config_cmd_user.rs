// SPDX-License-Identifier: MIT

//! Story 9.28 witness: the `jj config` surface at USER scope.
//!
//! # Why one test in its own binary
//!
//! Same rule as `tests/config_user_layer.rs`: `JJ_CONFIG` is process-global and this test
//! repoints it, so it is the only `#[test]` here and walks the user-scope matrix in sequence.
//! `JJ_CONFIG` may be repointed but is **never unset** (unset re-enables discovery of the
//! developer's real config), and `XDG_CONFIG_HOME` points into a temp dir.

use std::path::{Path, PathBuf};
use std::{env, fs};

use zanshin_jj::{
    config_file_read, config_file_write, config_get, config_list, config_path, config_set, config_unset, Backend,
    ConfigCmdError, ConfigListQuery, ConfigScope, ConfigTarget, ConfigValueSource, Repo,
};

const USER: ConfigTarget = ConfigTarget::Scope(ConfigScope::User);

fn file(path: &Path) -> ConfigTarget {
    ConfigTarget::File(path.to_owned())
}

fn set_env(name: &str, value: impl AsRef<std::ffi::OsStr>) {
    // SAFETY: single-threaded — this binary contains exactly one #[test].
    unsafe { env::set_var(name, value) };
}

/// `JJ_CONFIG` as a `:`-separated list of entries.
fn set_jj_config(paths: &[&Path]) {
    set_env("JJ_CONFIG", env::join_paths(paths).expect("joinable paths"));
}

fn user_rows(root: Option<&Path>) -> Vec<(String, String, Option<PathBuf>)> {
    let query = ConfigListQuery {
        scope: Some(ConfigScope::User),
        ..ConfigListQuery::default()
    };
    config_list(root, &query)
        .result
        .expect("list")
        .into_iter()
        .inspect(|e| assert_eq!(e.source, ConfigValueSource::User))
        .map(|e| (e.name, e.value, e.path))
        .collect()
}

#[test]
fn user_scope_matrix() {
    let tmp = tempfile::tempdir().unwrap();
    // SAFETY: see `set_env`.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        // Removed, not pinned: the `EnvOverrides` identity would shadow the user file's.
        env::remove_var("JJ_USER");
        env::remove_var("JJ_EMAIL");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
    }
    set_env("XDG_CONFIG_HOME", tmp.path().join("xdg"));

    // `JJ_CONFIG=""`: no user path at all.
    assert!(matches!(
        config_path(None, ConfigScope::User).result,
        Err(ConfigCmdError::NoConfigPath { reason }) if reason == "No user config path found"
    ));

    // ── set with no file yet: created at the first candidate, parent included ──
    let first = tmp.path().join("new").join("dir").join("config.toml");
    let dir = tmp.path().join("conf.d");
    set_jj_config(&[&first, &dir]);
    assert_eq!(
        config_path(None, ConfigScope::User).result.unwrap(),
        [first.clone(), dir.clone()]
    );
    let set = config_set(None, &USER, "user.name", "Ralph Bergmann");
    assert_eq!(set.result.expect("set").path, first);
    assert!(fs::read_to_string(&first)
        .unwrap()
        .ends_with("[user]\nname = \"Ralph Bergmann\"\n"));

    // ── round trip: a Zanshin write is what the read path and the listing see ──
    assert_eq!(config_get(None, "user.name").result.unwrap(), "Ralph Bergmann");
    assert_eq!(
        user_rows(None),
        [(
            "user.name".to_owned(),
            "\"Ralph Bergmann\"".to_owned(),
            Some(first.clone())
        )]
    );

    // ── two files: the user scope writes the FIRST (jj 0.45); `--file` names any other ──
    fs::create_dir_all(&dir).unwrap();
    let hand = dir.join("hand.toml");
    fs::write(&hand, "# written by hand\nui.color = 'never'   # keep me\n").unwrap();
    assert!(user_rows(None).contains(&("ui.color".to_owned(), "'never'".to_owned(), Some(hand.clone()))));
    let before = (fs::read_to_string(&first).unwrap(), fs::read_to_string(&hand).unwrap());
    let stray = tmp.path().join("stray.toml");
    assert!(matches!(
        config_set(None, &file(&stray), "user.email", "r@example.com").result,
        Err(ConfigCmdError::UnrecognizedFile { path }) if path == stray
    ));
    assert_eq!(
        (fs::read_to_string(&first).unwrap(), fs::read_to_string(&hand).unwrap()),
        before,
        "nothing written"
    );
    let set = config_set(None, &USER, "user.email", "first@example.com");
    assert_eq!(set.result.expect("the first file").path, first);
    assert_eq!(fs::read_to_string(&hand).unwrap(), before.1, "only the first file");
    config_unset(None, &USER, "user.email").result.expect("unset");

    config_set(None, &file(&hand), "user.email", "r@example.com")
        .result
        .expect("the chosen file");
    assert_eq!(fs::read_to_string(&first).unwrap(), before.0, "only the chosen file");
    assert_eq!(
        fs::read_to_string(&hand).unwrap(),
        "# written by hand\nui.color = 'never'   # keep me\n\n[user]\nemail = \"r@example.com\"\n",
        "comments and formatting survive"
    );
    config_unset(None, &file(&hand), "user.email").result.expect("unset");
    assert_eq!(
        fs::read_to_string(&hand).unwrap(),
        "# written by hand\nui.color = 'never'   # keep me\n\n[user]\n",
        "unset removes only the value (jj-lib keeps the emptied table, as the CLI does)"
    );

    reads_and_repair(tmp.path(), &first, &hand);
}

/// A user value reaches an open repo's reads; a broken user file makes the stack verbs refuse
/// while the editor halves repair it.
fn reads_and_repair(tmp: &Path, first: &Path, hand: &Path) {
    let ws = tmp.join("ws");
    fs::create_dir(&ws).unwrap();
    let repo = Repo::init(&ws, Some(Backend::Git)).result.expect("init");
    config_set(None, &file(first), "revsets.log", "root()")
        .result
        .expect("set");
    assert_eq!(repo.log_defaults().unwrap().log, "root()");
    assert!(user_rows(Some(&ws)).iter().any(|(name, _, _)| name == "revsets.log"));

    // ── a broken user file: the stack verbs refuse, the editor halves repair ──
    fs::write(hand, "[ui\ncolor = ").unwrap();
    for err in [
        config_list(None, &ConfigListQuery::default())
            .result
            .map(|_| ())
            .unwrap_err(),
        config_get(None, "user.name").result.map(|_| ()).unwrap_err(),
        config_path(None, ConfigScope::User).result.map(|_| ()).unwrap_err(),
        config_set(None, &file(first), "a", "1").result.map(|_| ()).unwrap_err(),
    ] {
        assert!(
            matches!(&err, ConfigCmdError::Config { reason } if reason.contains("conf.d")),
            "{err}"
        );
    }
    let read = config_file_read(None, &file(hand))
        .result
        .expect("read the broken file");
    assert_eq!(read.text, "[ui\ncolor = ");
    assert!(matches!(
        config_file_write(None, hand, "[ui\ncolor = ").result,
        Err(ConfigCmdError::Parse { .. })
    ));
    config_file_write(None, hand, "ui.color = 'always'\n")
        .result
        .expect("repair");
    assert_eq!(config_get(None, "ui.color").result.unwrap(), "always");
}
