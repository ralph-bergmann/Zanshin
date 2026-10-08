// SPDX-License-Identifier: MIT

//! The stock jj CLI at the `jj-lib` pin — the CLI side of the parity oracle (Story 9.47).
//!
//! Upstream's own entry point (`cli/src/main.rs` @ v0.46.0), built from crates.io `jj-cli`,
//! minus the mimalloc global allocator and the build-time version string. The oracle
//! (`tests/oracle/`) runs it as a subprocess next to `zanshin-jj` on identical repos.
//!
//! WHY not the `jj` on `PATH`: whatever is installed is not necessarily the pinned version, and
//! the parity rule holds against the pinned tag. WHY not in-process: `CliRunner::init` installs a
//! global tracing subscriber and an `exit(1)` signal handler and reads the process argv/cwd.

fn main() -> std::process::ExitCode {
    jj_cli::cli_util::CliRunner::init().run().into()
}
