// SPDX-License-Identifier: MIT

//! The one convert row that needs a BROKEN `$XDG_CONFIG_HOME`: a `trunk()` alias the
//! repo-level config file cannot be created for must fail the conversion and roll it back.
//!
//! # WHY its own test binary
//!
//! `config.rs` reads `$XDG_CONFIG_HOME` from the process environment on every call, and the
//! rest of `tests/convert.rs` needs that variable pointing at a WRITABLE directory — several
//! of its rows assert the alias file that lands there. Cargo gives each file in `tests/` its
//! own binary, so putting the broken environment in a file of its own is what makes it
//! hermetic; setting it inside a `#[test]` that shares a process with the others would be a
//! data race on the environment and would break them.

use std::path::Path;
use std::{env, fs};

use tempfile::TempDir;
use zanshin_jj::{convert_colocated, RepoError};

/// Run a git command in `dir`; panics on non-zero exit.
fn git(args: &[&str], dir: &Path) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// A conversion whose alias step cannot create `<config_dir>/jj/repos/` fails, and the
/// failure rolls back exactly what 2.12 promises: `.jj/` is gone, `.git/` is untouched.
///
/// The alias step is the LAST thing both verbs do, so this is also the only row that
/// exercises rollback after a fully successful jj-side conversion — every other failure
/// fixture in `tests/convert.rs` fails inside `init_external_git`, which self-cleans.
#[test]
fn an_uncreatable_repo_config_fails_the_conversion_and_rolls_it_back() {
    let xdg = TempDir::new().expect("xdg tempdir");
    // `<xdg>/jj` as a regular FILE: `SecureConfig::load_config` then cannot create
    // `<xdg>/jj/repos/<config-id>/`, which is the only failure the alias step can raise
    // without touching the developer's real config directory.
    fs::write(xdg.path().join("jj"), "not a directory").expect("write blocker");
    // SAFETY: this binary runs exactly one test, so nothing else reads the environment.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("XDG_CONFIG_HOME", xdg.path());
    }

    let src = TempDir::new().expect("tempdir src");
    git(&["init", "--initial-branch=main"], src.path());
    git(&["config", "user.email", "test@zanshin.test"], src.path());
    git(&["config", "user.name", "Fixture"], src.path());
    fs::write(src.path().join("README.md"), "hello").expect("write README");
    git(&["add", "."], src.path());
    git(&["commit", "-m", "initial"], src.path());

    // A clone is what gives the repo the symbolic `refs/remotes/origin/HEAD` the alias step
    // reads; without it the step is a no-op and there is nothing to fail.
    let parent = TempDir::new().expect("tempdir parent");
    let work = parent.path().join("work");
    git(
        &["clone", &src.path().to_string_lossy(), &work.to_string_lossy()],
        parent.path(),
    );

    let result = convert_colocated(&work);
    assert!(
        matches!(result, Err(RepoError::ConvertFailed { .. })),
        "an uncreatable repo config must fail the conversion, got: {result:?}"
    );
    assert!(
        !work.join(".jj").exists(),
        "the failed conversion must roll back — no partial .jj/ may remain"
    );
    assert!(work.join(".git").is_dir(), ".git/ must never be touched by a rollback");
}
