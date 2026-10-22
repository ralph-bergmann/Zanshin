// SPDX-License-Identifier: MIT

//! The one convert row that needs a BROKEN `$XDG_CONFIG_HOME`: a `trunk()` alias the
//! repo-level config file cannot be created for must fail the conversion and leave it as the CLI
//! leaves it (Story 9.57).
//!
//! # WHY its own process
//!
//! `config.rs` reads `$XDG_CONFIG_HOME` from the process environment on every call, and the rest of
//! `tests/it/convert.rs` needs that variable pointing at a WRITABLE directory — several of its rows
//! assert the alias file that lands there. Its test runs in a child process of its own
//! (`test_helpers::own_process!`), which is what makes the broken environment hermetic; setting it
//! inside a `#[test]` that shares a process with the others would be a data race on the environment
//! and would break them.

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

/// A conversion whose alias step cannot create `<config_dir>/jj/repos/` fails, and — as the
/// CLI's `do_init`, which propagates the error with `?` and cleans up nothing
/// (`cli/src/commands/git/init.rs` @ v0.46.0) — the `.jj/` written up to the failure stays,
/// `.git/` is untouched, and `left_behind` names the `.jj/`.
///
/// The alias step comes after a fully successful jj-side conversion — every failure fixture in
/// `tests/it/convert.rs` that fails inside `init_external_git` self-cleans.
#[test]
fn an_uncreatable_repo_config_fails_the_conversion_and_leaves_its_jj() {
    test_helpers::own_process!("an_uncreatable_repo_config_fails_the_conversion_and_leaves_its_jj");
    let xdg = TempDir::new().expect("xdg tempdir");
    // `<xdg>/jj` as a regular FILE: `SecureConfig::load_config` then cannot create
    // `<xdg>/jj/repos/<config-id>/`, which is the only failure the alias step can raise
    // without touching the developer's real config directory.
    fs::write(xdg.path().join("jj"), "not a directory").expect("write blocker");
    // SAFETY: this test runs alone in its own process (`own_process!`), so nothing else reads the environment.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
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

    let outcome = convert_colocated(&work);
    assert!(
        matches!(outcome.result, Err(RepoError::ConvertFailed { .. })),
        "an uncreatable repo config must fail the conversion, got: {:?}",
        outcome.result
    );
    assert!(
        work.join(".jj").is_dir(),
        "the failed conversion leaves its .jj/, as the CLI"
    );
    assert!(work.join(".git").is_dir(), ".git/ is never touched");
    let root = work.canonicalize().expect("canonical root");
    assert_eq!(outcome.left_behind, [root.join(".jj")]);
}
