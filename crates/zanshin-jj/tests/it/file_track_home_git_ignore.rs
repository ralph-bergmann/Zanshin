// SPDX-License-Identifier: MIT

//! The `base_ignores` row that needs NO usable `$XDG_CONFIG_HOME`: the CLI then reads the
//! global git ignore from `<home>/.config/git/ignore` (`cli/src/cli_util.rs:1692-1699` @
//! v0.46.0) — the branch a Finder/Dock-launched Zanshin, which has no `XDG_CONFIG_HOME`, runs.
//!
//! # WHY its own process
//!
//! Every other suite pins `$XDG_CONFIG_HOME` to a tempdir, so the home fallback never runs there.
//! Its tests run in child processes of their own (`test_helpers::own_process!`); setting the
//! environment inside a `#[test]` that shares a process with those would be a data race on the
//! environment.

use std::path::Path;
use std::{env, fs};

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use tempfile::TempDir;
use zanshin_jj::{Backend, Repo};

fn write(root: &Path, rel: &str, content: &str) {
    let path = root.join(rel);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("parent dir");
    }
    fs::write(path, content).expect("write file");
}

/// The paths of the working-copy STATE — what `track` records.
fn wc_state_paths(root: &Path) -> Vec<String> {
    let workspace = test_helpers::load_workspace(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("load workspace");
    futures::executor::block_on_stream(workspace.working_copy().tree().expect("wc tree").entries())
        .map(|(path, _)| path.as_internal_file_string().to_owned())
        .collect()
}

/// An EMPTY `$XDG_CONFIG_HOME` counts as unset (the CLI's `.filter(|x| !x.is_empty())`), so
/// `base_ignores` falls back to `<home>/.config/git/ignore`: a file it names is not tracked,
/// while the control file next to it is.
#[test]
fn an_empty_xdg_config_home_falls_back_to_the_home_git_ignore() {
    test_helpers::own_process!("an_empty_xdg_config_home_falls_back_to_the_home_git_ignore");
    let home = TempDir::new().expect("home tempdir");
    write(home.path(), ".config/git/ignore", "*.homeignored\n");
    // SAFETY: this test runs alone in its own process (`own_process!`), so nothing else reads the environment.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", "");
        env::set_var("HOME", home.path());
    }

    let tmp = TempDir::new().expect("tempdir");
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init")
    .workspace_root()
    .to_owned();
    // `auto-track = none()`: only the track itself may start tracking, so the control file
    // proves the verb ran and the ignore file alone kept the other one out.
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "snapshot.auto-track = \"none()\"\n",
    )
    .expect("repo config");
    write(&root, "a.homeignored", "x");
    write(&root, "b.kept", "x");
    let mut repo = Repo::open(&root).expect("open");

    repo.file_track(&["a.homeignored".to_owned(), "b.kept".to_owned()], false)
        .expect("track");

    assert_eq!(wc_state_paths(&root), vec!["b.kept".to_owned()]);
}
