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
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let cli = Cli::parse();
    match cli.command {
        Command::GenFixture(args) => tasks::gen_fixture::run(args),
        Command::LcovUnion(args) => tasks::lcov_union::run(&args),
    }
}
