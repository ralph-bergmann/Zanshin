// SPDX-License-Identifier: MIT

//! Story 9.36 witness: once the login shell's environment is adopted, it is what the config stack,
//! jj-lib's `git` subprocess (fetch AND clone), the snapshot's global git ignore and the
//! repo-root walk-up see — through the real process-wide store and the public API. The
//! mechanism's failure rows are pinned inline in `src/environment.rs` (on local stores).
//!
//! # Why one test in its own binary
//!
//! The adoption is write-once and process-wide: after it, every environment read in this binary
//! sees the adopted map. So this file holds exactly ONE `#[test]` that walks the matrix rows in
//! order — before, adopt, after, the second call. The fake login shell UNSETS `JJ_CONFIG`
//! (re-enabling user-config discovery, which is what the XDG row needs), so it also points
//! `XDG_CONFIG_HOME` and `HOME` into the temp dir: no developer config is ever read.

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;
use std::time::Duration;

use zanshin_jj::{
    adopt_login_shell_environment, config_get, find_repo_root, Backend, ConfigCmdError, ProgressEvent, Repo,
};

/// Writes an executable `#!/bin/sh` script.
fn script(path: &Path, body: &str) {
    fs::write(path, format!("#!/bin/sh\n{body}\n")).expect("write the script");
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).expect("chmod the script");
}

fn user_name() -> String {
    config_get(None, "user.name").expect("user.name is set")
}

/// The fake `git` ran with the shell's variables minus the locale jj-lib pins; `what` names the
/// verb that ran it.
fn git_saw_the_shell_environment(git_env: &Path, what: &str) {
    let seen = fs::read_to_string(git_env).unwrap_or_else(|e| panic!("the fake git ran for {what}: {e}"));
    let lines: Vec<&str> = seen.lines().collect();
    assert!(lines.contains(&"ZANSHIN_SENTINEL=1"), "{what}: {seen}");
    assert!(lines.contains(&"LC_MESSAGES=C"), "{what}: {seen}");
    assert!(!lines.iter().any(|l| l.starts_with("LC_ALL=")), "{what}: {seen}");
}

#[test]
fn the_adopted_login_shell_environment_reaches_the_config_stack_and_git() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let dir = tmp.path().display().to_string();
    let shell = tmp.path().join("login-shell");
    let process_xdg = tmp.path().join("process-xdg");
    for (name, value) in test_helpers::TEST_ENV.into_iter().chain([
        ("JJ_USER", "Test User"),
        // The adoption below passes no shell: this `$SHELL` is the one it runs.
        ("SHELL", shell.to_str().expect("utf-8 temp path")),
        // NOT the adopted one: the global git ignore must come from the shell's.
        ("XDG_CONFIG_HOME", process_xdg.to_str().expect("utf-8 temp path")),
    ]) {
        // SAFETY: single-threaded — this binary contains exactly one #[test], and nothing reads
        // the environment concurrently.
        unsafe { std::env::set_var(name, value) };
    }
    fs::create_dir_all(tmp.path().join("xdg").join("jj")).expect("xdg dir");
    fs::write(
        tmp.path().join("xdg").join("jj").join("config.toml"),
        "[test]\nmarker = \"from-xdg\"\n",
    )
    .expect("xdg config");
    fs::create_dir_all(tmp.path().join("bin")).expect("bin dir");
    let git_env = tmp.path().join("git-env.txt");
    script(
        &tmp.path().join("bin").join("git"),
        &format!("env >> '{}'\nexit 1", git_env.display()),
    );
    script(
        &shell,
        &format!(
            "unset JJ_CONFIG\nexport JJ_USER='Shell User' XDG_CONFIG_HOME='{dir}/xdg' HOME='{dir}/home' \
             LC_ALL=de_DE.UTF-8 LC_MESSAGES=de_DE.UTF-8 ZANSHIN_SENTINEL=1 PATH='{dir}/bin':\"$PATH\"\n\
             exec /bin/sh -c \"$4\""
        ),
    );
    // A git-backed workspace with a remote, set up in the process environment.
    let ws = tmp.path().join("ws");
    fs::create_dir_all(&ws).expect("ws dir");
    let mut repo = Repo::init(&ws, Some(Backend::Git)).result.expect("init");
    repo.git_remote_add("origin", "file:///nonexistent-zanshin-remote", None)
        .expect("add the remote");
    let mut repo = Repo::open(&ws).expect("reopen with the remote");

    // Before: the process environment.
    assert_eq!(user_name(), "Test User");
    assert!(
        matches!(config_get(None, "test.marker"), Err(ConfigCmdError::NotFound { .. })),
        "JJ_CONFIG=\"\" disables user-config discovery"
    );

    assert!(adopt_login_shell_environment(None, Duration::from_secs(5)).is_empty());

    // After: the login shell's — its identity, its XDG user config…
    assert_eq!(user_name(), "Shell User");
    assert_eq!(
        config_get(None, "test.marker").expect("the XDG user config"),
        "from-xdg"
    );
    // …its PATH picks the `git` a fetch and a clone run, with the shell's variables minus the
    // locale jj-lib pins. Both fail (the fake git exits 1); only the environment matters.
    let _ = repo.git_fetch("origin", &|_: ProgressEvent| {});
    git_saw_the_shell_environment(&git_env, "git_fetch");
    fs::write(&git_env, "").expect("truncate the git log");
    let clone = tmp.path().join("clone");
    fs::create_dir_all(&clone).expect("clone dir");
    let _ = Repo::clone("file:///nonexistent-zanshin-remote", &clone).result;
    git_saw_the_shell_environment(&git_env, "Repo::clone");

    // …its XDG_CONFIG_HOME names the global git ignore every snapshot starts from (the control
    // file proves the snapshot ran)…
    fs::create_dir_all(tmp.path().join("xdg").join("git")).expect("xdg git dir");
    fs::write(tmp.path().join("xdg").join("git").join("ignore"), "*.shellignored\n").expect("git ignore");
    fs::write(ws.join("leak.shellignored"), "secret").expect("ignored file");
    fs::write(ws.join("kept.txt"), "kept").expect("control file");
    let tracked: Vec<String> = repo
        .status()
        .expect("status snapshots")
        .files
        .into_iter()
        .map(|f| f.path.display().to_string())
        .collect();
    assert!(tracked.contains(&"kept.txt".to_owned()), "{tracked:?}");
    assert!(!tracked.contains(&"leak.shellignored".to_owned()), "{tracked:?}");

    // …and its HOME is the ceiling of the repo-root walk-up: the `.jj/` above it is not found.
    fs::create_dir_all(tmp.path().join("home").join("sub")).expect("home/sub");
    fs::create_dir_all(tmp.path().join(".jj")).expect(".jj above the adopted HOME");
    assert!(
        find_repo_root(&tmp.path().join("home").join("sub"))
            .expect("the walk-up reads")
            .is_none(),
        "the walk stops at the adopted HOME"
    );

    // A second call is a no-op: nothing spawned, no warning, the first map stays.
    assert!(adopt_login_shell_environment(Some("/nonexistent/shell".as_ref()), Duration::from_secs(5)).is_empty());
    assert_eq!(user_name(), "Shell User");
}
