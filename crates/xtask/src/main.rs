// SPDX-License-Identifier: MIT

mod tasks;

use clap::{Parser, Subcommand};

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Generate test fixture repos (.tar.zst archives)
    GenFixture(tasks::gen_fixture::GenFixtureArgs),
    /// Union two or more LCOV tracefiles (max hit count per line) into one
    LcovUnion(tasks::lcov_union::LcovUnionArgs),
    /// Gate per-file Rust coverage against a committed ratchet baseline
    CoverageCheck(tasks::coverage_check::CoverageCheckArgs),
    /// Plan the `cargo make test` steps the changes since the last green run need
    GatePlan(tasks::gate_plan::GatePlanArgs),
    /// Record the tree a green `cargo make test` run verified
    GateStamp(tasks::gate_plan::GateStampArgs),
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let cli = Cli::parse();
    match cli.command {
        Command::GenFixture(args) => tasks::gen_fixture::run(args),
        Command::LcovUnion(args) => tasks::lcov_union::run(&args),
        Command::CoverageCheck(args) => tasks::coverage_check::run(&args),
        Command::GatePlan(args) => tasks::gate_plan::run_plan(&args),
        Command::GateStamp(args) => tasks::gate_plan::run_stamp(&args),
    }
}
