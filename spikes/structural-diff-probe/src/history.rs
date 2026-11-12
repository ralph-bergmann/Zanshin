// SPDX-License-Identifier: MIT
//! `history`: jj's and difft's marks over real diffs — every `.rs` and `.dart` file modified in the
//! newest `--commits` non-merge commits of `--rev` that modify one, generated files excluded. Writes
//! one row per file to `out/history.tsv` and prints the summary tables.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::PathBuf;
use std::time::Duration;

use crate::marks::{self, Class, Kind};
use crate::{git, mb, ms, option, out_dir, repo_root, stats};

/// One changed line worth showing: a class's example.
struct Example {
    score: usize,
    location: String,
    jj: String,
    difft: String,
}

#[derive(Default)]
struct Totals {
    files: usize,
    lines: usize,
    /// Classes under the corrected mapping rule.
    classes: BTreeMap<Class, usize>,
    /// The same, as Story 10.32 draws the marks.
    drawn: BTreeMap<Class, usize>,
    /// Classes under the first mapping rule (every novel span).
    raw: BTreeMap<Class, usize>,
    jj_times: Vec<Duration>,
    difft_times: Vec<Duration>,
}

pub fn run(args: &[String]) -> Result<(), String> {
    let version = marks::require_difft()?;
    let repo = option(args, "--repo").map_or_else(repo_root, PathBuf::from);
    let rev = option(args, "--rev").unwrap_or("main");
    let commits = option(args, "--commits").unwrap_or("200");
    let out = out_dir("")?;
    let work = out_dir("work-history")?;
    let head = String::from_utf8_lossy(&git(&repo, &["rev-parse", rev])?)
        .trim()
        .to_owned();
    let list = git(
        &repo,
        &[
            "log",
            &head,
            "--no-merges",
            "-n",
            commits,
            "--format=%H %cs",
            "--",
            "*.rs",
            "*.dart",
        ],
    )?;
    let list = String::from_utf8_lossy(&list).into_owned();
    let commits: Vec<(&str, &str)> = list.lines().filter_map(|line| line.split_once(' ')).collect();
    let mut corpus = Vec::new();
    for (commit, _) in &commits {
        let changed = git(
            &repo,
            &[
                "diff-tree",
                "--no-commit-id",
                "-r",
                "--no-renames",
                "--name-status",
                commit,
                "--",
                "*.rs",
                "*.dart",
            ],
        )?;
        for line in String::from_utf8_lossy(&changed).lines() {
            if let Some(path) = line.strip_prefix("M\t") {
                corpus.push(((*commit).to_owned(), path.to_owned()));
            }
        }
    }

    let mut tsv = String::from(
        "commit\tpath\tbytes_before\tbytes_after\tjj_us\tdifft_us\tdifft_peak_rss_bytes\tdifft_language\tdifft_status\tchanged_lines\tsame\tfewer\tmore\tdifferent\tfallback\tdropped_on_context\tdropped_outside\tcr_shifted\tcontent_mismatches\n",
    );
    let mut by_language: BTreeMap<&str, Totals> = BTreeMap::new();
    let mut fallbacks: BTreeMap<String, usize> = BTreeMap::new();
    let mut examples: BTreeMap<Class, Vec<Example>> = BTreeMap::new();
    let (mut generated, mut binary, mut unchanged_files, mut files_with_visible_change) = (0, 0, 0, 0);
    let (mut dropped_context, mut dropped_outside, mut cr_shifted, mut mismatches) = (0, 0, 0, 0);
    // Changed lines one side marks and the other leaves without marks.
    let (mut only_jj_marks, mut only_difft_marks) = (0, 0);
    let mut slowest: Vec<(Duration, String, usize)> = Vec::new();
    // Per commit: jj's and difft's summed time over its diffed files. A side note only: the
    // inspector and the Undo Timeline read a summary, then the focused file's diff.
    let mut per_commit: BTreeMap<&str, [Duration; 2]> = BTreeMap::new();
    // The fallback files' right-side size, difft time and peak memory.
    let mut fallback_files: Vec<(usize, Duration, u64)> = Vec::new();
    let mut peaks: Vec<u64> = Vec::new();
    for (index, (commit, path)) in corpus.iter().enumerate() {
        let before = git(&repo, &["show", &format!("{commit}^:{path}")])?;
        let after = git(&repo, &["show", &format!("{commit}:{path}")])?;
        if is_generated(path, &before) || is_generated(path, &after) {
            generated += 1;
            continue;
        }
        if [&before, &after]
            .iter()
            .any(|text| text.iter().take(8000).any(|&byte| byte == 0))
        {
            binary += 1;
            continue;
        }
        let language = if path.ends_with(".rs") { "Rust" } else { "Dart" };
        let file_name = path.rsplit('/').next().unwrap_or(path);
        let jj = marks::jj_diff(&before, &after);
        let difft = marks::difft_diff(&work, file_name, &before, &after, &[])
            .map_err(|error| format!("{commit} {path}: {error}"))?;
        if difft.fell_back() {
            *fallbacks.entry(fallback_reason(&difft.language)).or_default() += 1;
            fallback_files.push((after.len(), difft.elapsed, difft.peak_rss));
        }
        peaks.push(difft.peak_rss);
        unchanged_files += usize::from(difft.status == "unchanged");
        // A fallback's text-diff spans are never used, so they are not counted as dropped.
        let dropped = if difft.fell_back() {
            marks::Dropped::default()
        } else {
            marks::dropped(&jj, &difft)
        };
        dropped_context += dropped.on_context;
        dropped_outside += dropped.outside;
        cr_shifted += difft.cr_shifted_spans;
        mismatches += difft.content_mismatches;

        let totals = by_language.entry(language).or_default();
        totals.files += 1;
        totals.jj_times.push(jj.elapsed);
        totals.difft_times.push(difft.elapsed);
        slowest.push((difft.elapsed, format!("{path}@{}", &commit[..8]), after.len()));
        let sums = per_commit.entry(commit.as_str()).or_default();
        sums[0] += jj.elapsed;
        sums[1] += difft.elapsed;
        let mut counts: BTreeMap<Class, usize> = BTreeMap::new();
        let mut visible_change = false;
        for (number, line) in jj.hunks.iter().flatten().enumerate() {
            if line.kind == Kind::Context {
                continue;
            }
            let structural = difft.marks_for(line);
            let class = if difft.fell_back() {
                Class::Fallback
            } else {
                marks::classify(&line.text, &line.jj, &structural)
            };
            let (drawn_class, raw_class) = if difft.fell_back() {
                (Class::Fallback, Class::Fallback)
            } else {
                let (jj_drawn, difft_drawn) = (
                    marks::drawn(&line.text, &line.jj),
                    marks::drawn(&line.text, &structural),
                );
                let raw = difft.raw_marks_for(line);
                (
                    marks::classify_drawn(&jj_drawn, &difft_drawn),
                    marks::classify(&line.text, &line.jj, &raw),
                )
            };
            visible_change |= !matches!(drawn_class, Class::Same | Class::Fallback);
            *counts.entry(class).or_default() += 1;
            *totals.classes.entry(class).or_default() += 1;
            *totals.drawn.entry(drawn_class).or_default() += 1;
            *totals.raw.entry(raw_class).or_default() += 1;
            totals.lines += 1;
            if matches!(class, Class::Fewer | Class::More | Class::Different) {
                let (jj_ink, difft_ink) = (marks::ink(&line.text, &line.jj), marks::ink(&line.text, &structural));
                only_jj_marks += usize::from(difft_ink.is_empty());
                only_difft_marks += usize::from(jj_ink.is_empty());
                let score = jj_ink.symmetric_difference(&difft_ink).count();
                let sign = if line.kind == Kind::Removed { '-' } else { '+' };
                let side_line = line.left.or(line.right).unwrap_or(number) + 1;
                examples.entry(class).or_default().push(Example {
                    score,
                    location: format!("{path}@{}:{sign}{side_line}", &commit[..8]),
                    jj: marks::render(&line.text, &line.jj, line.kind),
                    difft: marks::render(&line.text, &structural, line.kind),
                });
            }
        }
        files_with_visible_change += usize::from(visible_change);
        let count = |class| counts.get(&class).copied().unwrap_or(0);
        let _ = writeln!(
            tsv,
            "{commit}\t{path}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            before.len(),
            after.len(),
            jj.elapsed.as_micros(),
            difft.elapsed.as_micros(),
            difft.peak_rss,
            difft.language,
            difft.status,
            jj.changed_lines().count(),
            count(Class::Same),
            count(Class::Fewer),
            count(Class::More),
            count(Class::Different),
            count(Class::Fallback),
            dropped.on_context,
            dropped.outside,
            difft.cr_shifted_spans,
            difft.content_mismatches,
        );
        if (index + 1) % 250 == 0 {
            eprintln!("history: {} of {} files", index + 1, corpus.len());
        }
    }
    let tsv_path = option(args, "--tsv").map_or_else(|| out.join("history.tsv"), PathBuf::from);
    std::fs::write(&tsv_path, tsv).map_err(|error| format!("{}: {error}", tsv_path.display()))?;

    let files: usize = by_language.values().map(|totals| totals.files).sum();
    let (first_date, last_date) = (commits.last().map_or("", |c| c.1), commits.first().map_or("", |c| c.1));
    println!("difft: {version}\n");
    println!("#### Corpus\n");
    println!(
        "- Revision `{head}`; {} non-merge commits that modify a `.rs` or `.dart` file, {first_date} to {last_date}.",
        commits.len()
    );
    println!(
        "- Scope: files a commit modifies (status `M`, no rename detection); added, deleted and renamed files are not diffed."
    );
    println!(
        "- {} modified `.rs` / `.dart` files: {generated} generated and {binary} binary skipped, {files} diffed ({}).",
        corpus.len(),
        by_language
            .iter()
            .map(|(language, totals)| format!("{language} {}", totals.files))
            .collect::<Vec<_>>()
            .join(", ")
    );
    println!(
        "- difft fell back on {} files: {}. It reported `unchanged` (no syntactic change) on {unchanged_files} files.",
        fallbacks.values().sum::<usize>(),
        if fallbacks.is_empty() {
            "none".to_owned()
        } else {
            fallbacks
                .iter()
                .map(|(reason, count)| format!("{reason} {count}"))
                .collect::<Vec<_>>()
                .join(", ")
        }
    );
    println!(
        "- Rows per file: `{}`.\n",
        option(args, "--tsv").unwrap_or("out/history.tsv")
    );

    let all = |pick: fn(&Totals) -> &BTreeMap<Class, usize>, class: Class| -> usize {
        by_language
            .values()
            .map(|totals| pick(totals).get(&class).copied().unwrap_or(0))
            .sum()
    };
    let lines: usize = by_language.values().map(|totals| totals.lines).sum();
    for (title, pick) in [
        (
            "#### Changed lines by class (corrected mapping; marked non-whitespace bytes)",
            (|t: &Totals| &t.classes) as fn(&Totals) -> &BTreeMap<Class, usize>,
        ),
        (
            "#### As Story 10.32 draws them (drawn bytes, whitespace fills included; no strong marks on a line without visible unmarked text)",
            |t: &Totals| &t.drawn,
        ),
        (
            "#### The first mapping rule (every novel span, whole comments and strings included)",
            |t: &Totals| &t.raw,
        ),
    ] {
        println!("{title}\n");
        let languages: Vec<&&str> = by_language.keys().collect();
        println!(
            "| class | {} | all | share |",
            languages.iter().map(|l| l.to_string()).collect::<Vec<_>>().join(" | ")
        );
        println!("|---|{}---:|---:|", "---:|".repeat(languages.len()));
        for class in Class::ALL {
            let per_language: Vec<String> = by_language
                .values()
                .map(|totals| pick(totals).get(&class).copied().unwrap_or(0).to_string())
                .collect();
            let total = all(pick, class);
            println!(
                "| {} | {} | {total} | {} |",
                class.label(),
                per_language.join(" | "),
                percent(total, lines)
            );
        }
        let per_language: Vec<String> = by_language.values().map(|totals| totals.lines.to_string()).collect();
        println!("| changed lines | {} | {lines} | |\n", per_language.join(" | "));
    }
    println!(
        "Files where the drawn marks would change on at least one line: {files_with_visible_change} of {files}.\n"
    );
    println!(
        "Changed lines jj marks and difft leaves without marks (difft calls them unchanged): {only_jj_marks}; lines difft marks and jj leaves without marks: {only_difft_marks}.\n"
    );
    println!(
        "difft marks the mapping drops (files without a fallback): {dropped_context} on jj context lines, {dropped_outside} outside jj's hunks. Spans moved by a carriage return: {cr_shifted}. Content mismatches: {mismatches}.\n"
    );

    println!("#### Time per file\n");
    println!(
        "| | {} |",
        by_language
            .keys()
            .flat_map(|l| [format!("jj {l}"), format!("difft {l}")])
            .collect::<Vec<_>>()
            .join(" | ")
    );
    println!("|---|{}", "---:|".repeat(by_language.len() * 2));
    let table: Vec<[[Duration; 5]; 2]> = by_language
        .values_mut()
        .map(|totals| [stats(&mut totals.jj_times), stats(&mut totals.difft_times)])
        .collect();
    for (row, name) in ["median", "p90", "p99", "max", "sum"].iter().enumerate() {
        let cells: Vec<String> = table
            .iter()
            .flat_map(|pair| pair.iter().map(|times| format!("{} ms", ms(times[row]))))
            .collect();
        println!("| {name} | {} |", cells.join(" | "));
    }
    let over = |limit: u64| {
        slowest
            .iter()
            .filter(|(time, ..)| *time > Duration::from_millis(limit))
            .count()
    };
    println!(
        "\ndifft over 100 ms: {} files, over 250 ms: {}, over 1 s: {} (of {files}). jj times are in-process, inputs in memory; difft times are the whole process (start, file reads, JSON) under `/usr/bin/time -l`.\n",
        over(100),
        over(250),
        over(1000)
    );
    peaks.sort_unstable();
    let peak_at = |fraction: f64| {
        peaks
            .get(((peaks.len().max(1) - 1) as f64 * fraction).round() as usize)
            .copied()
            .unwrap_or(0)
    };
    println!(
        "difft peak memory per file (maximum resident set size): median {} MB, p90 {} MB, p99 {} MB, max {} MB.\n",
        mb(peak_at(0.5)),
        mb(peak_at(0.9)),
        mb(peak_at(0.99)),
        mb(peaks.last().copied().unwrap_or(0)),
    );
    let mut commit_jj: Vec<Duration> = per_commit.values().map(|sums| sums[0]).collect();
    let mut commit_difft: Vec<Duration> = per_commit.values().map(|sums| sums[1]).collect();
    let (commit_jj, commit_difft) = (stats(&mut commit_jj), stats(&mut commit_difft));
    println!(
        "Per commit ({} commits with a diffed file), summed over its files: jj median {} ms, p90 {} ms, max {} ms; difft median {} ms, p90 {} ms, max {} ms.\n",
        per_commit.len(),
        ms(commit_jj[0]),
        ms(commit_jj[1]),
        ms(commit_jj[3]),
        ms(commit_difft[0]),
        ms(commit_difft[1]),
        ms(commit_difft[3]),
    );
    slowest.sort_by(|a, b| b.0.cmp(&a.0));
    println!("Slowest difft files:\n");
    for (time, location, bytes) in slowest.iter().take(5) {
        println!("- `{location}` ({bytes} bytes): {} ms", ms(*time));
    }
    if !fallback_files.is_empty() {
        let bytes = fallback_files.iter().map(|(bytes, ..)| *bytes);
        let times = fallback_files.iter().map(|(_, time, _)| *time);
        let rss = fallback_files.iter().map(|(.., rss)| *rss);
        let slow = fallback_files
            .iter()
            .filter(|(_, time, _)| *time > Duration::from_secs(1))
            .count();
        println!(
            "\nFallback files: {}, of {} to {} bytes (right side); difft took {}–{} ms on each, {} ms together, and peaked at {}–{} MB; {slow} of the {} files over 1 s are among them.",
            fallback_files.len(),
            bytes.clone().min().unwrap_or(0),
            bytes.max().unwrap_or(0),
            ms(times.clone().min().unwrap_or_default()),
            ms(times.clone().max().unwrap_or_default()),
            ms(times.sum()),
            mb(rss.clone().min().unwrap_or(0)),
            mb(rss.max().unwrap_or(0)),
            slowest.iter().filter(|(time, ..)| *time > Duration::from_secs(1)).count(),
        );
    }

    println!("\n#### Examples (the lines where the two differ most)\n");
    for class in [Class::Fewer, Class::More, Class::Different] {
        let Some(list) = examples.get_mut(&class) else { continue };
        list.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.location.cmp(&b.location)));
        println!("##### {}\n\n```text", class.label());
        for example in list.iter().take(5) {
            println!(
                "{}\n  jj    |{}\n  difft |{}",
                example.location, example.jj, example.difft
            );
        }
        println!("```\n");
    }
    Ok(())
}

/// Generated files: by name, or by a generator's header in the first lines.
fn is_generated(path: &str, text: &[u8]) -> bool {
    let name_rule = [
        "_generated.rs",
        "_generated.dart",
        ".g.dart",
        ".freezed.dart",
        ".inject.dart",
    ]
    .iter()
    .any(|suffix| path.ends_with(suffix));
    let head: String = String::from_utf8_lossy(&text[..text.len().min(400)]).to_lowercase();
    name_rule
        || [
            "@generated",
            "auto generated file",
            "generated code - do not modify",
            "automatically generated",
        ]
        .iter()
        .any(|marker| head.contains(marker))
}

/// The kind of a difft fallback, without the sizes and positions that vary per file.
fn fallback_reason(language: &str) -> String {
    match language {
        "Text" => "no parser".to_owned(),
        _ if language.contains("DFT_BYTE_LIMIT") => "byte limit".to_owned(),
        _ if language.contains("DFT_GRAPH_LIMIT") => "graph limit".to_owned(),
        _ if language.contains("DFT_PARSE_ERROR_LIMIT") => "parse errors".to_owned(),
        _ => language.to_owned(),
    }
}

fn percent(part: usize, whole: usize) -> String {
    if whole == 0 {
        return String::new();
    }
    format!("{:.1} %", part as f64 * 100.0 / whole as f64)
}
