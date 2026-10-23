// SPDX-License-Identifier: MIT

//! Story 9.36 witness: once the login shell's environment is adopted, it is what the config stack,
//! jj-lib's `git` subprocess (fetch AND clone), the snapshot's global git ignore and the
//! repo-root walk-up see — through the real process-wide store and the public API. The store's
//! readers and the git-map filter are pinned inline in `src/environment.rs` (on local stores);
//! reading the login shell is `zanshin_core`'s (Dart) job, so no shell runs here.
//!
//! # Why one test in its own process
//!
//! The adoption is write-once and process-wide: after it, every environment read in this process
//! sees the adopted map. So each test here runs alone in a child process (`own_process!`); the
//! main one walks the rows in order — before, adopt, after, the second call. The adopted map is the process environment with the
//! edits a login shell's rc file could make: it UNSETS `JJ_CONFIG` (re-enabling user-config
//! discovery, which is what the XDG row needs), so it also points `XDG_CONFIG_HOME` and `HOME`
//! into the temp dir: no developer config is ever read.

use std::collections::HashMap;
use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;

use zanshin_jj::{
    adopt_environment, config_get, find_repo_root, Backend, ConfigCmdError, FixOptions, ProgressEvent, Repo,
    WarningKind,
};

/// Writes an executable `#!/bin/sh` script.
fn script(path: &Path, body: &str) {
    fs::write(path, format!("#!/bin/sh\n{body}\n")).expect("write the script");
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).expect("chmod the script");
}

fn user_name() -> String {
    config_get(None, "user.name").result.expect("user.name is set")
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

/// The login shell's environment as the app would read it: the process environment (which the
/// shell inherits) with an rc file's edits applied.
fn login_shell_environment(dir: &Path) -> HashMap<OsString, OsString> {
    let mut environment: HashMap<OsString, OsString> = std::env::vars_os().collect();
    environment.remove(&OsString::from("JJ_CONFIG"));
    let path = std::env::var_os("PATH").unwrap_or_default();
    let mut shell_path = dir.join("bin").into_os_string();
    shell_path.push(":");
    shell_path.push(path);
    for (name, value) in [
        ("JJ_USER", OsString::from("Shell User")),
        ("XDG_CONFIG_HOME", dir.join("xdg").into_os_string()),
        ("HOME", dir.join("home").into_os_string()),
        ("LC_ALL", OsString::from("de_DE.UTF-8")),
        ("LC_MESSAGES", OsString::from("de_DE.UTF-8")),
        ("ZANSHIN_SENTINEL", OsString::from("1")),
        ("PATH", shell_path),
    ] {
        environment.insert(OsString::from(name), value);
    }
    environment
}

#[test]
fn the_adopted_login_shell_environment_reaches_the_config_stack_and_git() {
    test_helpers::own_process!("the_adopted_login_shell_environment_reaches_the_config_stack_and_git");
    let tmp = tempfile::tempdir().expect("tempdir");
    let process_xdg = tmp.path().join("process-xdg");
    for (name, value) in test_helpers::TEST_ENV.into_iter().chain([
        ("JJ_USER", "Test User"),
        // NOT the adopted one: the global git ignore must come from the shell's.
        ("XDG_CONFIG_HOME", process_xdg.to_str().expect("utf-8 temp path")),
    ]) {
        // SAFETY: single-threaded — this test runs alone in its own process (`own_process!`), and nothing reads
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
    // A git-backed workspace with a remote, set up in the process environment.
    let ws = tmp.path().join("ws");
    fs::create_dir_all(&ws).expect("ws dir");
    let mut repo = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&ws),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init");
    repo.git_remote_add("origin", "file:///nonexistent-zanshin-remote", None)
        .expect("add the remote");
    let mut repo = Repo::open(&ws).expect("reopen with the remote");

    // Before: the process environment.
    assert_eq!(user_name(), "Test User");
    assert!(
        matches!(
            config_get(None, "test.marker").result,
            Err(ConfigCmdError::NotFound { .. })
        ),
        "JJ_CONFIG=\"\" disables user-config discovery"
    );

    adopt_environment(login_shell_environment(tmp.path()));

    // After: the login shell's — its identity, its XDG user config…
    assert_eq!(user_name(), "Shell User");
    assert_eq!(
        config_get(None, "test.marker").result.expect("the XDG user config"),
        "from-xdg"
    );
    // …its PATH picks the `git` a fetch and a clone run, with the shell's variables minus the
    // locale jj-lib pins. Both fail (the fake git exits 1); only the environment matters.
    let _ = repo.git_fetch(&zanshin_jj::GitFetchArgs::default(), &|_: ProgressEvent| {}, None);
    git_saw_the_shell_environment(&git_env, "git_fetch");
    fs::write(&git_env, "").expect("truncate the git log");
    let clone = tmp.path().join("clone");
    fs::create_dir_all(&clone).expect("clone dir");
    let _ = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from("file:///nonexistent-zanshin-remote"),
            destination: std::path::PathBuf::from(&clone),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    )
    .result;
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

    // A second adoption is a no-op: the first map stays.
    adopt_environment(HashMap::from([(
        OsString::from("JJ_USER"),
        OsString::from("Other User"),
    )]));
    assert_eq!(user_name(), "Shell User");
}

/// Story 9.9: a `jj fix` tool is looked up on the adopted `PATH` — a tool found nowhere else runs.
#[test]
fn a_fix_tool_is_found_on_the_adopted_path() {
    test_helpers::own_process!("a_fix_tool_is_found_on_the_adopted_path");
    let tmp = tempfile::tempdir().expect("tempdir");
    let process_xdg = tmp.path().join("process-xdg");
    for (name, value) in test_helpers::TEST_ENV
        .into_iter()
        .chain([("XDG_CONFIG_HOME", process_xdg.to_str().expect("utf-8 temp path"))])
    {
        // SAFETY: single-threaded — this test runs alone in its own process (`own_process!`), and
        // nothing reads the environment concurrently.
        unsafe { std::env::set_var(name, value) };
    }
    let bin = tmp.path().join("bin");
    fs::create_dir_all(&bin).expect("bin dir");
    script(&bin.join("zanshin-upper"), "tr a-z A-Z");

    let ws = tmp.path().join("ws");
    fs::create_dir_all(&ws).expect("ws dir");
    let mut repo = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&ws),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init");
    let root = repo.workspace_root().to_owned();
    fs::write(
        root.join(".jj").join("repo").join("config.toml"),
        "[fix.tools.upper]\ncommand = ['zanshin-upper']\npatterns = ['a.txt']\n",
    )
    .expect("repo config");
    fs::write(root.join("a.txt"), "a\n").expect("a.txt");

    let mut environment: HashMap<OsString, OsString> = std::env::vars_os().collect();
    let mut shell_path = bin.into_os_string();
    shell_path.push(":");
    shell_path.push(std::env::var_os("PATH").unwrap_or_default());
    environment.insert(OsString::from("PATH"), shell_path);
    adopt_environment(environment);

    let result = repo.fix(&FixOptions::default()).expect("fix");
    let warnings = repo.take_warnings();
    assert!(
        !warnings.iter().any(|w| w.kind == WarningKind::FixToolStartFailed),
        "{warnings:?}"
    );
    assert_eq!(result.num_fixed_commits, 1);
    assert_eq!(fs::read_to_string(root.join("a.txt")).expect("a.txt"), "A\n");
}
