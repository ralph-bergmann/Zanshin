// SPDX-License-Identifier: MIT
//! Story 5.9's probe: jj-lib's word marks next to difftastic's structural marks on the same hunk
//! lines, plus the cost and fallback measurements the research report cites. See README.md.

mod history;
mod limits;
// E2's line pairing exactly as Zanshin builds it: the same file, compiled here.
#[path = "../../../crates/zanshin-jj/src/line_pairs.rs"]
mod line_pairs;
mod marks;
mod parse_check;
mod witness;

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::{Duration, Instant};

const USAGE: &str = "usage: structural-diff-probe <witness | history | limits | parse-check> [options]
  witness      [--inputs DIR]                              jj's, E2's and difft's marks on the witness cases
  history      [--repo DIR] [--rev REV] [--commits N] [--tsv FILE] [--jobs N]
                                                           the same over real diffs of the repository;
                                                           --jobs runs difft on N threads (its times are then not reported)
  limits                                                   inputs that trip difft's fallbacks and E2's cap: time, peak memory
  parse-check  [--repo DIR] [--rev REV]                    the 5.4 grammars and difft's over the repository's files
All modes need difft 0.72.0 on PATH.";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rest = args.get(1..).unwrap_or_default();
    let result = match args.first().map(String::as_str) {
        Some("witness") => witness::run(rest),
        Some("history") => history::run(rest),
        Some("limits") => limits::run(rest),
        Some("parse-check") => parse_check::run(rest),
        // Internal: jj's marks for two files in a process of their own, so `limits` can measure
        // jj's peak memory.
        Some("jj-marks") => limits::jj_marks_child(rest),
        _ => Err(USAGE.to_owned()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

/// This crate's directory: the default home of `inputs/` and `out/`.
fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// The Zanshin repository the probe sits in.
fn repo_root() -> PathBuf {
    let path = crate_dir().join("../..");
    std::fs::canonicalize(&path).unwrap_or(path)
}

/// The value after `name` in `args`.
fn option<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter()
        .position(|arg| arg == name)
        .and_then(|at| args.get(at + 1))
        .map(String::as_str)
}

/// The output directory `out/<name>`, created.
fn out_dir(name: &str) -> Result<PathBuf, String> {
    let dir = crate_dir().join("out").join(name);
    std::fs::create_dir_all(&dir).map_err(|error| format!("{}: {error}", dir.display()))?;
    Ok(dir)
}

/// `git -C repo <args>`'s stdout.
fn git(repo: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .map_err(|error| format!("git: {error}"))?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        Err(format!("git {args:?}: {}", String::from_utf8_lossy(&output.stderr)))
    }
}

/// A run under `/usr/bin/time -l`: stdout, wall time and peak memory.
struct Measured {
    stdout: Vec<u8>,
    wall: Duration,
    /// `maximum resident set size`, in bytes.
    peak_rss: u64,
}

/// Runs `command` `runs` times under `/usr/bin/time -l`: the stdout of the last run, the median
/// wall time and the median peak memory.
fn measure_median(command: &Command, runs: usize) -> Result<Measured, String> {
    let mut walls = Vec::with_capacity(runs);
    let mut peaks = Vec::with_capacity(runs);
    let mut stdout = Vec::new();
    for _ in 0..runs {
        let run = measure(command)?;
        walls.push(run.wall);
        peaks.push(run.peak_rss);
        stdout = run.stdout;
    }
    walls.sort();
    peaks.sort_unstable();
    Ok(Measured {
        stdout,
        wall: walls[runs / 2],
        peak_rss: peaks[runs / 2],
    })
}

/// Runs `command` under macOS's `/usr/bin/time -l`, which reports the peak resident set size.
fn measure(command: &Command) -> Result<Measured, String> {
    let mut timed = Command::new("/usr/bin/time");
    timed.arg("-l").arg(command.get_program()).args(command.get_args());
    for (key, value) in command.get_envs() {
        match value {
            Some(value) => timed.env(key, value),
            None => timed.env_remove(key),
        };
    }
    let start = Instant::now();
    let output = timed.output().map_err(|error| format!("/usr/bin/time: {error}"))?;
    let wall = start.elapsed();
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() {
        return Err(format!("{:?} failed: {stderr}", command.get_program()));
    }
    let peak_rss = stderr
        .lines()
        .find(|line| line.contains("maximum resident set size"))
        .and_then(|line| line.split_whitespace().next())
        .and_then(|number| number.parse().ok())
        .ok_or_else(|| format!("no peak memory in: {stderr}"))?;
    Ok(Measured {
        stdout: output.stdout,
        wall,
        peak_rss,
    })
}

/// Milliseconds with one decimal.
fn ms(duration: Duration) -> String {
    format!("{:.1}", duration.as_secs_f64() * 1000.0)
}

/// Megabytes with one decimal.
fn mb(bytes: u64) -> String {
    format!("{:.1}", bytes as f64 / 1_000_000.0)
}

/// Median, 90th and 99th percentile, maximum and sum of `times`.
fn stats(times: &mut [Duration]) -> [Duration; 5] {
    if times.is_empty() {
        return [Duration::ZERO; 5];
    }
    times.sort();
    let at = |fraction: f64| times[((times.len() - 1) as f64 * fraction).round() as usize];
    [at(0.5), at(0.9), at(0.99), times[times.len() - 1], times.iter().sum()]
}
