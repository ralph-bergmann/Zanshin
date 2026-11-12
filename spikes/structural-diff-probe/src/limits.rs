// SPDX-License-Identifier: MIT
//! `limits`: inputs that trip each difft fallback, plus two that fill E2's per-file budget, with
//! wall time and peak memory for jj (with E2) and for difft. The inputs are generated into
//! `out/limits/<name>/`.

use std::fmt::Write as _;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use crate::marks::{self, Class, Kind};
use crate::{mb, measure, measure_median, ms, out_dir};

/// Runs per measurement; the tables show the median.
const RUNS: usize = 3;

/// One generated input and the extra difft runs it gets.
struct Input {
    name: &'static str,
    what: &'static str,
    extension: &'static str,
    before: String,
    after: String,
    /// Extra difft runs with other limits, as argument lists.
    extra_runs: &'static [&'static [&'static str]],
}

pub fn run(_args: &[String]) -> Result<(), String> {
    println!("difft: {}\n", marks::require_difft()?);
    let out = out_dir("limits")?;
    let probe = std::env::current_exe().map_err(|error| format!("current_exe: {error}"))?;
    println!("| input | bytes before / after | difft args | difft `language` | difft wall | difft peak RSS | jj changed lines | jj in-process | E2 in-process (more) | E2 budget ran out | jj + E2 process peak RSS |");
    println!("|---|---:|---|---|---:|---:|---:|---:|---:|---|---:|");
    let mut details = String::new();
    let (mut mismatches, mut cr_shifted) = (0, 0);
    for input in inputs() {
        let dir = out.join(input.name);
        let file_name = format!("{}.{}", input.name, input.extension);
        let paths = marks::write_pair(&dir, &file_name, input.before.as_bytes(), input.after.as_bytes())?;

        // jj in a process of its own, so its peak memory is its own; the medians of three runs.
        let mut jj_command = Command::new(&probe);
        jj_command.arg("jj-marks").arg(&paths[0]).arg(&paths[1]);
        let (mut jj_times, mut e2_times, mut jj_peaks, mut changed_lines, mut ran_out) =
            (Vec::new(), Vec::new(), Vec::new(), String::new(), String::new());
        for _ in 0..RUNS {
            let run = measure(&jj_command)?;
            let stdout = String::from_utf8_lossy(&run.stdout).into_owned();
            let mut fields = stdout.split_whitespace();
            changed_lines = fields.next().unwrap_or("?").to_owned();
            let mut micros = || Duration::from_micros(fields.next().and_then(|us| us.parse().ok()).unwrap_or(0));
            jj_times.push(micros());
            e2_times.push(micros());
            ran_out = fields.next().unwrap_or("?").to_owned();
            jj_peaks.push(run.peak_rss);
        }
        jj_times.sort();
        e2_times.sort();
        jj_peaks.sort_unstable();
        let (jj_time, e2_time, jj_peak) = (jj_times[RUNS / 2], e2_times[RUNS / 2], jj_peaks[RUNS / 2]);

        let runs: Vec<&[&str]> = std::iter::once(&[][..])
            .chain(input.extra_runs.iter().copied())
            .collect();
        for (index, extra) in runs.iter().enumerate() {
            let mut difft_command = marks::difft_command();
            difft_command.args(*extra).arg(&paths[0]).arg(&paths[1]);
            let difft_run = measure_median(&difft_command, RUNS)?;
            let difft = marks::parse_difft_json(
                &difft_run.stdout,
                input.before.as_bytes(),
                input.after.as_bytes(),
                difft_run.wall,
                difft_run.peak_rss,
            )?;
            mismatches += difft.content_mismatches;
            cr_shifted += difft.cr_shifted_spans;
            let jj_cells = if index == 0 {
                format!(
                    "{changed_lines} | {} ms | {} ms | {ran_out} | {} MB",
                    ms(jj_time),
                    ms(e2_time),
                    mb(jj_peak)
                )
            } else {
                " | | | | ".to_owned()
            };
            println!(
                "| {} | {} / {} | {} | `{}` | {} ms | {} MB | {jj_cells} |",
                if index == 0 { input.name } else { "" },
                input.before.len(),
                input.after.len(),
                if extra.is_empty() {
                    "defaults".to_owned()
                } else {
                    format!("`{}`", extra.join(" "))
                },
                difft.language,
                ms(difft_run.wall),
                mb(difft_run.peak_rss),
            );
            if index == 0 {
                write_details(&mut details, &input, &difft);
            }
        }
    }
    println!(
        "\nMedian of {RUNS} runs. Peak RSS is `/usr/bin/time -l`'s maximum resident set size; jj's is a process of its own that reads both files and computes today's marks and E2's. E2's time is its line pairing alone, on top of jj's; E2's per-file budget is {} bytes (`MAX_PAIRING_WORK`).\n",
        crate::line_pairs::MAX_PAIRING_WORK
    );
    println!(
        "Over all difft runs above: span content mismatches {mismatches}, spans moved by a carriage return {cr_shifted}.\n"
    );
    print!("{details}");
    Ok(())
}

/// The first changed lines of an input with jj's marks and the marks a build would draw.
fn write_details(details: &mut String, input: &Input, difft: &marks::DifftDiff) {
    let jj = marks::jj_diff(input.before.as_bytes(), input.after.as_bytes());
    let _ = writeln!(details, "#### {}\n\n{}\n\n```text", input.name, input.what);
    for line in jj.changed_lines().take(4) {
        let sign = if line.kind == Kind::Removed { '-' } else { '+' };
        let (build, class) = if difft.fell_back() {
            (line.jj.clone(), Class::Fallback)
        } else {
            let structural = difft.marks_for(line);
            let class = marks::classify(&line.text, &line.jj, &structural);
            (structural, class)
        };
        let _ = writeln!(
            details,
            "{sign} jj    |{}",
            marks::render(&line.text, &line.jj, line.kind)
        );
        let _ = writeln!(
            details,
            "{sign} build |{}   <- {}",
            marks::render(&line.text, &build, line.kind),
            class.label()
        );
        let _ = writeln!(
            details,
            "{sign} e2    |{}",
            marks::render(&line.text, &line.e2, line.kind)
        );
    }
    let _ = writeln!(details, "```\n");
}

/// `jj-marks <before> <after>`: prints the changed-line count, jj's in-process time and E2's in
/// µs, and whether E2's budget ran out.
pub fn jj_marks_child(args: &[String]) -> Result<(), String> {
    let [before, after] = args else {
        return Err("usage: structural-diff-probe jj-marks <before> <after>".to_owned());
    };
    let read = |path: &str| std::fs::read(Path::new(path)).map_err(|error| format!("{path}: {error}"));
    let (before, after) = (read(before)?, read(after)?);
    let jj = marks::jj_diff(&before, &after);
    println!(
        "{} {} {} {}",
        jj.changed_lines().count(),
        jj.elapsed.as_micros(),
        jj.e2_elapsed.as_micros(),
        if jj.e2_budget_ran_out { "yes" } else { "no" }
    );
    Ok(())
}

fn inputs() -> Vec<Input> {
    vec![
        Input {
            name: "byte-limit",
            what: "13,000 small Rust functions (a side over 1,000,000 bytes); one function in the middle changes.",
            extension: "rs",
            before: functions(13_000, |_| false),
            after: functions(13_000, |index| index == 6_500),
            extra_runs: &[&["--byte-limit", "100000000"]],
        },
        Input {
            name: "scattered-changes",
            what: "One Rust function of 20,000 statements (under the byte limit); every 10th statement changes. Does not trip the graph limit at its default.",
            extension: "rs",
            before: statements(20_000, |_| false),
            after: statements(20_000, |index| index % 10 == 0),
            extra_runs: &[&["--graph-limit", "300000"]],
        },
        Input {
            name: "graph-limit-statements",
            what: "The same function; every statement changes.",
            extension: "rs",
            before: statements(20_000, |_| false),
            after: statements(20_000, |_| true),
            extra_runs: &[&["--graph-limit", "300000"]],
        },
        Input {
            name: "graph-limit-array",
            what: "One Rust array literal of 60,000 small numbers, ten per line; every third number changes.",
            extension: "rs",
            before: array(60_000, |_| false),
            after: array(60_000, |index| index % 3 == 0),
            extra_runs: &[&["--graph-limit", "300000"], &["--graph-limit", "6000000"]],
        },
        Input {
            name: "e2-at-cap",
            what: "One changed block whose one-to-one candidates fill E2's per-file budget: copies of `values.push(first * second);` become copies of `values.push(second * first);`. Every line pair shares all its tokens, so no bound skips a pair.",
            extension: "rs",
            before: at_cap(E2_BEFORE),
            after: at_cap(E2_AFTER),
            extra_runs: &[],
        },
        Input {
            name: "e2-reformatted-calls",
            what: "20 changed blocks of 28 one-line calls `f(a0, a1, a2, a3, a4, a5);` each, reformatted to one argument per line (a reviewer's case): every call line shares all its tokens with every run of argument lines, so the runs are searched too.",
            extension: "rs",
            before: calls(20, 28, false),
            after: calls(20, 28, true),
            extra_runs: &[],
        },
        Input {
            name: "parse-error-rust",
            what: "A Rust syntax error on the right side (`let = total;`, an ERROR node).",
            extension: "rs",
            before: "fn main() {\n    let total = add(1, 2);\n    println!(\"{total}\");\n}\n".to_owned(),
            after: "fn main() {\n    let total = add(1, 3);\n    let = total;\n    println!(\"{total}\");\n}\n".to_owned(),
            extra_runs: &[],
        },
        Input {
            name: "parse-error-dart",
            what: "Newer Dart syntax difft's grammar lacks: a primary constructor (valid in the installed Dart 3.15 beta); an unrelated expression changes.",
            extension: "dart",
            before: "class Point(final int x, final int y);\n\nint area(Point p) => p.x * p.y;\n".to_owned(),
            after: "class Point(final int x, final int y);\n\nint area(Point p) => p.x * p.y * 2;\n".to_owned(),
            extra_runs: &[&["--parse-error-limit", "10"]],
        },
        Input {
            name: "missing-node-rust",
            what: "A Rust syntax error that tree-sitter repairs with a MISSING `)` (`f(b, a;`): difft counts no parse error.",
            extension: "rs",
            before: "fn main() {\n    f(a, b);\n}\n".to_owned(),
            after: "fn main() {\n    f(b, a;\n}\n".to_owned(),
            extra_runs: &[],
        },
        Input {
            name: "no-parser-markdown",
            what: "Markdown: difft has no parser for it (`--list-languages`).",
            extension: "md",
            before: "# Title\n\nSome text with a word.\n".to_owned(),
            after: "# Title\n\nSome text with another word.\n".to_owned(),
            extra_runs: &[],
        },
        Input {
            name: "conflict-jj-diff-style",
            what: "The right side holds a conflict in jj's default marker style (`diff`, as in jj's docs/conflicts.md @ v0.47.0), as Zanshin diffs a conflicted file.",
            extension: "rs",
            before: LIMITS_BEFORE.to_owned(),
            after: r#"fn limits() -> (u32, u32) {
<<<<<<< conflict 1 of 1
%%%%%%% diff from: vpxusssl 38d49363 "merge base"
\\\\\\\        to: rtsqusxu 2768b0b9 "commit A"
-    let width = 80;
+    let width = 100;
+++++++ ysrnknol 7a20f389 "commit B"
    let width = 120;
>>>>>>> conflict 1 of 1 ends
    let height = 24;
    (width, height)
}
"#
            .to_owned(),
            extra_runs: &[],
        },
        Input {
            name: "conflict-git-style",
            what: "The same conflict in jj's `git` marker style.",
            extension: "rs",
            before: LIMITS_BEFORE.to_owned(),
            after: r#"fn limits() -> (u32, u32) {
<<<<<<< rtsqusxu 2768b0b9 "commit A"
    let width = 100;
||||||| vpxusssl 38d49363 "merge base"
    let width = 80;
=======
    let width = 120;
>>>>>>> ysrnknol 7a20f389 "commit B"
    let height = 24;
    (width, height)
}
"#
            .to_owned(),
            extra_runs: &[],
        },
    ]
}

/// The clean left side of the two conflict inputs.
const LIMITS_BEFORE: &str =
    "fn limits() -> (u32, u32) {\n    let width = 80;\n    let height = 24;\n    (width, height)\n}\n";

/// `count` small top-level Rust functions; `changed` picks the ones whose body differs.
fn functions(count: usize, changed: impl Fn(usize) -> bool) -> String {
    let mut text = String::new();
    for index in 0..count {
        let shift = if changed(index) { 5 } else { 3 };
        let _ = writeln!(
            text,
            "pub fn step_{index}(value: u32) -> u32 {{\n    value.wrapping_mul({index}).rotate_left({shift})\n}}\n"
        );
    }
    text
}

/// One Rust function of `count` statements; `changed` picks the ones that differ.
fn statements(count: usize, changed: impl Fn(usize) -> bool) -> String {
    let mut text = String::from("pub fn table() -> Vec<u32> {\n    let mut values = Vec::new();\n");
    for index in 0..count {
        let factor = if changed(index) { 4 } else { 3 };
        let _ = writeln!(text, "    values.push({index} * {factor});");
    }
    text.push_str("    values\n}\n");
    text
}

/// The two lines of the `e2-at-cap` input; both have the same length and the same tokens.
const E2_BEFORE: &str = "    values.push(first * second);\n";
const E2_AFTER: &str = "    values.push(second * first);\n";

/// `blocks` blocks of `calls` calls `f(a0, a1, a2, a3, a4, a5);` each, split by a comment line;
/// `split` writes each call with one argument per line.
fn calls(blocks: usize, calls: usize, split: bool) -> String {
    let mut text = String::from("fn main() {\n");
    for block in 0..blocks {
        let _ = writeln!(text, "    // block {block}");
        for _ in 0..calls {
            if split {
                text.push_str("    f(\n");
                for argument in 0..6 {
                    let _ = writeln!(text, "        a{argument},");
                }
                text.push_str("    );\n");
            } else {
                text.push_str("    f(a0, a1, a2, a3, a4, a5);\n");
            }
        }
    }
    text.push_str("}\n");
    text
}

/// One function body of as many copies of `line` as one changed block of `n` lines against `n`
/// lines may hold within E2's per-file budget: the one-to-one candidates read
/// `2 · n · n · line length` bytes.
fn at_cap(line: &str) -> String {
    let fits = |count: usize| 2 * count * count * line.len() <= crate::line_pairs::MAX_PAIRING_WORK;
    let count = (1..).take_while(|&count| fits(count)).last().unwrap_or(1);
    format!(
        "pub fn table() {{\n    let mut values = Vec::new();\n{}    values\n}}\n",
        line.repeat(count)
    )
}

/// One Rust array literal of `count` small numbers, ten per line; `changed` picks the ones that differ.
fn array(count: usize, changed: impl Fn(usize) -> bool) -> String {
    let mut text = String::from("pub const DATA: &[u32] = &[\n");
    for index in 0..count {
        let value = (index + usize::from(changed(index))) % 7;
        let _ = write!(text, "{}{value},", if index % 10 == 0 { "    " } else { " " });
        if index % 10 == 9 {
            text.push('\n');
        }
    }
    text.push_str("\n];\n");
    text
}
