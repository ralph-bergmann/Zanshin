// SPDX-License-Identifier: MIT

//! The differential parity oracle (Story 9.47): the same operation through `zanshin-jj`
//! (repo A) and through the stock jj CLI at the pin (repo B), compared by meaning.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::path::Path;

mod driver;

#[test]
fn pinned_jj_builds_a_repo_zanshin_opens() {
    test_helpers::pin_test_env();
    let (_dir, root) = driver::fresh_repo(&["git", "init"], &[]);
    zanshin_jj::Repo::open(&root).expect("Zanshin opens a repo the pinned jj created");
}

#[test]
fn pinned_jj_keeps_its_secure_config_in_the_test_xdg_dir() {
    test_helpers::pin_test_env();
    // WHY the config write: a plain `jj git init` without a remote writes no repo config, so it
    // creates no secure config entry at all; the first `config set --repo` does.
    let (_dir, root) = driver::fresh_repo(
        &["git", "init"],
        &[&[driver::Step::Jj(&[
            "config",
            "set",
            "--repo",
            "ui.conflict-marker-style",
            "git",
        ])]],
    );
    let id = std::fs::read_to_string(root.join(".jj/repo/config-id")).expect("config-id");
    let xdg = std::env::var_os("XDG_CONFIG_HOME").expect("pinned by pin_test_env");
    assert!(
        Path::new(&xdg).join("jj/repos").join(id.trim()).is_dir(),
        "the CLI's secure per-repo config must land in the test's XDG_CONFIG_HOME"
    );
}

#[test]
fn pinned_jj_command_carries_the_hermetic_env() {
    test_helpers::pin_test_env();
    let command = driver::command(Path::new("/"), &["log"]);
    let envs: BTreeMap<_, _> = command.get_envs().collect();
    let get = |name: &str| envs.get(OsStr::new(name)).copied().flatten();
    assert_eq!(get("LLVM_PROFILE_FILE"), Some(OsStr::new("/dev/null")));
    assert_eq!(get("XDG_CONFIG_HOME"), std::env::var_os("XDG_CONFIG_HOME").as_deref());
    for (name, value) in test_helpers::TEST_ENV {
        assert_eq!(get(name), Some(OsStr::new(value)), "{name}");
    }
}
