// SPDX-License-Identifier: MIT

//! Story 9.37, the "Editor half, broken user file" row: `jj config edit`'s read half loads no
//! stack, so a broken user file does not stop it — but with a workspace root it still starts
//! with the CLI's secure-config fix-up, migrating a legacy repo config and reporting it.
//!
//! Its own binary with ONE test: it repoints the process-global `JJ_CONFIG` at an invalid file,
//! which every other `tests/secure_config_fixups.rs` row must not see.

use std::{env, fs};

use zanshin_jj::{config_file_read, ConfigScope, Repo, WarningKind};

#[test]
fn the_editor_half_migrates_a_legacy_repo_config_under_a_broken_user_file() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    // SAFETY: this binary runs exactly one test, so nothing else reads the environment.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", &xdg);
    }
    let root = tmp.path().join("ws");
    fs::create_dir(&root).unwrap();
    // Created while `JJ_CONFIG` is still `""`: `init` runs the start-up check first.
    Repo::init(&root, None).result.expect("init");
    let root = fs::canonicalize(&root).unwrap();
    let legacy = "[test]\nmarker = \"legacy\"\n";
    fs::write(root.join(".jj").join("repo").join("config.toml"), legacy).unwrap();
    let user = tmp.path().join("user.toml");
    fs::write(&user, "not toml [").unwrap();
    // SAFETY: as above.
    unsafe { env::set_var("JJ_CONFIG", &user) };

    let outcome = config_file_read(Some(&root), ConfigScope::Repo, None);

    let read = outcome.result.expect("the editor half ignores the broken user file");
    let kinds: Vec<WarningKind> = outcome.warnings.iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::ConfigMigrated]);
    let id = fs::read_to_string(root.join(".jj").join("repo").join("config-id")).expect("config-id");
    assert_eq!(read.path, xdg.join("jj").join("repos").join(id).join("config.toml"));
    assert_eq!(read.text, legacy, "the new file holds the legacy text");
}
