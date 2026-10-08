// SPDX-License-Identifier: MIT

//! The CLI side: the crate's own `jj` binary (the stock CLI at the pin), run as a subprocess
//! with a hermetic environment.

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::process::Stdio;

/// One `jj` invocation: whether it succeeded, and what it printed.
pub struct CliRun {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
}

impl CliRun {
    /// The run, or a panic carrying the CLI's stderr when it failed (a setup step must not).
    #[track_caller]
    pub fn ok(self) -> Self {
        assert!(self.success, "jj failed:\n{}", self.stderr);
        self
    }
}

/// The pinned `jj` invocation in `cwd`.
///
/// The environment is passed explicitly, not merely inherited:
/// - every `test_helpers::TEST_ENV` pair (no user/system config, fixed identity), the same
///   values `zanshin-jj` reads in-process;
/// - the test binary's `XDG_CONFIG_HOME` (set by `pin_test_env`), so the CLI's secure
///   per-repo config lands in the test's temp dir, never in `~/.config/jj`;
/// - `LLVM_PROFILE_FILE=/dev/null`: under `cargo llvm-cov` this binary is instrumented too, and
///   every one of the oracle's hundreds of `jj` exits would otherwise merge a profile into
///   `target/`. Its coverage is not measured anyway (`crates/zanshin-parity/` is excluded).
pub fn command(cwd: &Path, args: &[&str]) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_jj"));
    command
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .envs(test_helpers::TEST_ENV)
        .env("LLVM_PROFILE_FILE", "/dev/null");
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
        command.env("XDG_CONFIG_HOME", xdg);
    }
    command
}

/// Runs the pinned `jj` in `cwd`.
pub fn jj(cwd: &Path, args: &[&str]) -> CliRun {
    let output = command(cwd, args).output().expect("spawn the pinned jj");
    CliRun {
        success: output.status.success(),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}

/// One fixture step, identical in both repos of a scenario.
pub enum Step {
    /// `jj <args>` in the repo root.
    Jj(&'static [&'static str]),
    /// `jj <args>` in a directory relative to the repo root (a second workspace beside it).
    JjAt(&'static str, &'static [&'static str]),
    /// Writes a file (relative to the repo root) without snapshotting it.
    Write(&'static str, &'static str),
}

/// A temp dir holding a repo at `<temp>/repo`, created by `jj <init>` and then `steps`.
///
/// WHY `<temp>/repo` and not the temp dir itself: a second workspace can live beside the repo
/// (`../ws2`) and still be removed with the temp dir.
pub fn fresh_repo(init: &[&str], steps: &[&[Step]]) -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::Builder::new()
        .prefix("zanshin-parity-")
        .tempdir()
        .expect("temp dir");
    let root = dir.path().join("repo");
    std::fs::create_dir(&root).expect("repo dir");
    jj(&root, init).ok();
    for step in steps.iter().copied().flatten() {
        match step {
            Step::Jj(args) => {
                jj(&root, args).ok();
            }
            Step::JjAt(relative, args) => {
                jj(&root.join(relative), args).ok();
            }
            Step::Write(path, text) => std::fs::write(root.join(path), text).expect("write a fixture file"),
        }
    }
    (dir, root)
}
