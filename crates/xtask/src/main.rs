// SPDX-License-Identifier: Apache-2.0

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
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let cli = Cli::parse();
    match cli.command {
        Command::GenFixture(args) => tasks::gen_fixture::run(args),
    }
}
