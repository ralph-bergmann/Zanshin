// SPDX-License-Identifier: MIT
//! `history`: jj's, E2's and difft's marks over real diffs — every `.rs` and `.dart` file modified
//! in the newest `--commits` non-merge commits of `--rev` that modify one, generated files
//! excluded. Writes one row per file to `out/history.tsv` and prints the summary tables.
//!
//! difft runs first, over every file; `--jobs N` runs it on N threads (its marks are the same, its
//! times are then not reported). jj's and E2's marks and times are computed afterwards,
//! in-process and one file at a time.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
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

/// One changed line where E2's marks and difft's differ.
struct E2Example {
    score: usize,
    location: String,
    jj: String,
    e2: String,
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
    /// E2's marks against difft's (corrected rule), word marks and drawn.
    e2_classes: BTreeMap<Class, usize>,
    e2_drawn: BTreeMap<Class, usize>,
    jj_times: Vec<Duration>,
    e2_times: Vec<Duration>,
    difft_times: Vec<Duration>,
}

/// One diffed file.
struct Input {
    commit: String,
    path: String,
    before: Vec<u8>,
    after: Vec<u8>,
}

/// Lines where today's or E2's marks differ from difft's (files without a difft fallback), word
/// marks then drawn.
#[derive(Default)]
struct Gap {
    today: [usize; 2],
    e2: [usize; 2],
    /// Today's marks differ from difft's, E2's do not.
    closed: [usize; 2],
    /// Today's marks equal difft's, E2's do not.
    opened: [usize; 2],
    /// Lines whose E2 word marks differ from difft's and cover the whole line (E2 left it
    /// unpaired, or its pair kept nothing of it).
    e2_whole: usize,
}

pub fn run(args: &[String]) -> Result<(), String> {
    let version = marks::require_difft()?;
    let repo = option(args, "--repo").map_or_else(repo_root, PathBuf::from);
    let rev = option(args, "--rev").unwrap_or("main");
    let commits = option(args, "--commits").unwrap_or("200");
    let jobs: usize = option(args, "--jobs")
        .unwrap_or("1")
        .parse()
        .map_err(|error| format!("--jobs: {error}"))?;
    let jobs = jobs.max(1);
    let out = out_dir("")?;
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

    let (mut generated, mut binary) = (0, 0);
    let mut inputs = Vec::new();
    for (commit, path) in &corpus {
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
        inputs.push(Input {
            commit: commit.clone(),
            path: path.clone(),
            before,
            after,
        });
    }
    let diffts = difft_all(&inputs, jobs)?;

    let mut tsv = String::from(
        "commit\tpath\tbytes_before\tbytes_after\tjj_us\tdifft_us\tdifft_peak_rss_bytes\tdifft_language\tdifft_status\tchanged_lines\tsame\tfewer\tmore\tdifferent\tfallback\tdropped_on_context\tdropped_outside\tcr_shifted\tcontent_mismatches\te2_us\n",
    );
    let mut by_language: BTreeMap<&str, Totals> = BTreeMap::new();
    let mut fallbacks: BTreeMap<String, usize> = BTreeMap::new();
    let mut examples: BTreeMap<Class, Vec<Example>> = BTreeMap::new();
    // Lines where E2's marks differ from difft's and today's did not, by class; and lines E2
    // brings to difft's marks.
    let mut e2_examples: BTreeMap<Class, Vec<E2Example>> = BTreeMap::new();
    let mut closed_examples: Vec<E2Example> = Vec::new();
    let (mut unchanged_files, mut files_with_visible_change) = (0, 0);
    let (mut dropped_context, mut dropped_outside, mut cr_shifted, mut mismatches) = (0, 0, 0, 0);
    // Changed lines one side marks and the other leaves without marks.
    let (mut only_jj_marks, mut only_difft_marks) = (0, 0);
    let mut gap = Gap::default();
    // E2's marks against today's, on every changed line: word marks, then drawn.
    let mut e2_vs_today: [BTreeMap<Class, usize>; 2] = Default::default();
    // Changed blocks E2 pairs, and the files where E2's per-file budget left a block to jj.
    let (mut blocks, mut budget_files) = (0, Vec::new());
    let mut slowest: Vec<(Duration, String, usize)> = Vec::new();
    // Per commit: jj's and difft's summed time over its diffed files. A side note only: the
    // inspector and the Undo Timeline read a summary, then the focused file's diff.
    let mut per_commit: BTreeMap<&str, [Duration; 2]> = BTreeMap::new();
    // The fallback files' right-side size, difft time and peak memory.
    let mut fallback_files: Vec<(usize, Duration, u64)> = Vec::new();
    let mut peaks: Vec<u64> = Vec::new();
    for (index, (input, difft)) in inputs.iter().zip(&diffts).enumerate() {
        let Input {
            commit,
            path,
            before,
            after,
        } = input;
        let language = if path.ends_with(".rs") { "Rust" } else { "Dart" };
        let jj = marks::jj_diff(before, after);
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
            marks::dropped(&jj, difft)
        };
        dropped_context += dropped.on_context;
        dropped_outside += dropped.outside;
        cr_shifted += difft.cr_shifted_spans;
        mismatches += difft.content_mismatches;
        blocks += jj.paired_blocks();
        if jj.e2_budget_ran_out {
            budget_files.push(format!("{path}@{}", &commit[..8]));
        }

        let totals = by_language.entry(language).or_default();
        totals.files += 1;
        totals.jj_times.push(jj.elapsed);
        totals.e2_times.push(jj.e2_elapsed);
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
            let (jj_drawn, e2_drawn) = (marks::drawn(&line.text, &line.jj), marks::drawn(&line.text, &line.e2));
            *e2_vs_today[0]
                .entry(marks::classify(&line.text, &line.jj, &line.e2))
                .or_default() += 1;
            *e2_vs_today[1]
                .entry(marks::classify_drawn(&jj_drawn, &e2_drawn))
                .or_default() += 1;
            let structural = difft.marks_for(line);
            let class = if difft.fell_back() {
                Class::Fallback
            } else {
                marks::classify(&line.text, &line.jj, &structural)
            };
            // Against E2, difft's comments and strings take E2's word marks (see README).
            let e2_structural = difft.e2_marks_for(line);
            let (drawn_class, raw_class, e2_class, e2_drawn_class) = if difft.fell_back() {
                (Class::Fallback, Class::Fallback, Class::Fallback, Class::Fallback)
            } else {
                let raw = difft.raw_marks_for(line);
                (
                    marks::classify_drawn(&jj_drawn, &marks::drawn(&line.text, &structural)),
                    marks::classify(&line.text, &line.jj, &raw),
                    marks::classify(&line.text, &line.e2, &e2_structural),
                    marks::classify_drawn(&e2_drawn, &marks::drawn(&line.text, &e2_structural)),
                )
            };
            if !difft.fell_back() {
                for (view, (today, e2)) in [(class, e2_class), (drawn_class, e2_drawn_class)]
                    .into_iter()
                    .enumerate()
                {
                    let (today_differs, e2_differs) = (today != Class::Same, e2 != Class::Same);
                    gap.today[view] += usize::from(today_differs);
                    gap.e2[view] += usize::from(e2_differs);
                    gap.closed[view] += usize::from(today_differs && !e2_differs);
                    gap.opened[view] += usize::from(!today_differs && e2_differs);
                }
            }
            visible_change |= !matches!(drawn_class, Class::Same | Class::Fallback);
            *counts.entry(class).or_default() += 1;
            *totals.classes.entry(class).or_default() += 1;
            *totals.drawn.entry(drawn_class).or_default() += 1;
            *totals.raw.entry(raw_class).or_default() += 1;
            *totals.e2_classes.entry(e2_class).or_default() += 1;
            *totals.e2_drawn.entry(e2_drawn_class).or_default() += 1;
            totals.lines += 1;
            let sign = if line.kind == Kind::Removed { '-' } else { '+' };
            let side_line = line.left.or(line.right).unwrap_or(number) + 1;
            let location = || format!("{path}@{}:{sign}{side_line}", &commit[..8]);
            let difft_ink = marks::ink(&line.text, &structural);
            if matches!(class, Class::Fewer | Class::More | Class::Different) {
                let jj_ink = marks::ink(&line.text, &line.jj);
                only_jj_marks += usize::from(difft_ink.is_empty());
                only_difft_marks += usize::from(jj_ink.is_empty());
                examples.entry(class).or_default().push(Example {
                    score: jj_ink.symmetric_difference(&difft_ink).count(),
                    location: location(),
                    jj: marks::render(&line.text, &line.jj, line.kind),
                    difft: marks::render(&line.text, &structural, line.kind),
                });
            }
            let e2_differs = matches!(e2_class, Class::Fewer | Class::More | Class::Different);
            let example = |score| E2Example {
                score,
                location: location(),
                jj: marks::render(&line.text, &line.jj, line.kind),
                e2: marks::render(&line.text, &line.e2, line.kind),
                difft: marks::render(&line.text, &e2_structural, line.kind),
            };
            if e2_differs {
                let e2_ink = marks::ink(&line.text, &line.e2);
                gap.e2_whole += usize::from(e2_ink == marks::ink(&line.text, &[0..line.text.len()]));
                if class == Class::Same {
                    let score = e2_ink
                        .symmetric_difference(&marks::ink(&line.text, &e2_structural))
                        .count();
                    e2_examples.entry(e2_class).or_default().push(example(score));
                }
            } else if matches!(class, Class::Fewer | Class::More | Class::Different) {
                let jj_ink = marks::ink(&line.text, &line.jj);
                closed_examples.push(example(jj_ink.symmetric_difference(&difft_ink).count()));
            }
        }
        files_with_visible_change += usize::from(visible_change);
        let count = |class| counts.get(&class).copied().unwrap_or(0);
        let _ = writeln!(
            tsv,
            "{commit}\t{path}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
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
            jj.e2_elapsed.as_micros(),
        );
        if (index + 1) % 250 == 0 {
            eprintln!("history: jj and E2 on {} of {} files", index + 1, inputs.len());
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
        "- Rows per file: `{}`.",
        option(args, "--tsv").unwrap_or("out/history.tsv")
    );
    if jobs > 1 {
        println!("- difft ran on {jobs} threads, so its times are not reported; jj's and E2's ran in-process, one file at a time, after difft.");
    }
    println!();

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
        (
            "#### E2 against difft (E2's marks in jj's place, inside comments and strings too; marked non-whitespace bytes)",
            |t: &Totals| &t.e2_classes,
        ),
        (
            "#### E2 against difft, as Story 10.32 draws them",
            |t: &Totals| &t.e2_drawn,
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

    let compared = lines - all(|t: &Totals| &t.classes, Class::Fallback);
    println!("#### Today's gap to difft and E2's ({compared} changed lines without a difft fallback)\n");
    println!("| | word marks | drawn |");
    println!("|---|---:|---:|");
    let row = |name: &str, values: [usize; 2]| {
        println!(
            "| {name} | {} ({}) | {} ({}) |",
            values[0],
            percent(values[0], compared),
            values[1],
            percent(values[1], compared)
        );
    };
    row("today's marks differ from difft's", gap.today);
    row("E2's marks differ from difft's", gap.e2);
    row("today's differ, E2's match difft's", gap.closed);
    row("today's match difft's, E2's differ", gap.opened);
    // (today − E2) / today: lines E2 brings to difft's marks minus lines it takes away, so a net
    // change, not a share of lines closed.
    let net_change = |view: usize| {
        if gap.today[view] == 0 {
            String::new()
        } else {
            format!(
                "{:.1} %",
                (gap.today[view] as f64 - gap.e2[view] as f64) * 100.0 / gap.today[view] as f64
            )
        }
    };
    println!(
        "| net change of today's gap | {} | {} |\n",
        net_change(0),
        net_change(1)
    );
    println!(
        "Of the {} lines whose E2 word marks differ from difft's, E2 marks {} whole (unpaired, or their pair kept none of their ink).\n",
        gap.e2[0], gap.e2_whole
    );

    println!("#### E2 against today ({lines} changed lines; the class says what E2 marks compared with today)\n");
    println!("| class | word marks | share | drawn | share |");
    println!("|---|---:|---:|---:|---:|");
    for (class, label) in [
        (Class::Same, "same marks"),
        (Class::Fewer, "E2 marks fewer bytes"),
        (Class::More, "E2 marks more bytes"),
        (Class::Different, "different bytes"),
    ] {
        let [word, drawn] = [0, 1].map(|view| e2_vs_today[view].get(&class).copied().unwrap_or(0));
        println!(
            "| {label} | {word} | {} | {drawn} | {} |",
            percent(word, lines),
            percent(drawn, lines)
        );
    }
    println!(
        "\nChanged blocks with removed and added lines: {blocks}. Files where E2's per-file budget ({} bytes) could not pay for some block, so it keeps today's marks: {} of {}{}.\n",
        crate::line_pairs::MAX_PAIRING_WORK,
        budget_files.len(),
        files,
        if budget_files.is_empty() {
            String::new()
        } else {
            format!(" ({})", budget_files.join(", "))
        }
    );

    println!("#### Time per file\n");
    let mut columns: Vec<String> = Vec::new();
    for language in by_language.keys() {
        columns.push(format!("jj {language}"));
        columns.push(format!("E2 {language}"));
        if jobs == 1 {
            columns.push(format!("difft {language}"));
        }
    }
    println!("| | {} |", columns.join(" | "));
    println!("|---|{}", "---:|".repeat(columns.len()));
    let table: Vec<Vec<[Duration; 5]>> = by_language
        .values_mut()
        .map(|totals| {
            let mut times = vec![stats(&mut totals.jj_times), stats(&mut totals.e2_times)];
            if jobs == 1 {
                times.push(stats(&mut totals.difft_times));
            }
            times
        })
        .collect();
    for (row, name) in ["median", "p90", "p99", "max", "sum"].iter().enumerate() {
        let cells: Vec<String> = table
            .iter()
            .flat_map(|columns| columns.iter().map(|times| format!("{} ms", ms(times[row]))))
            .collect();
        println!("| {name} | {} |", cells.join(" | "));
    }
    println!(
        "\njj: jj-lib's hunks and today's marks; E2: its line pairing alone, on top of jj. Both in-process, inputs in memory, one file at a time.{}\n",
        if jobs == 1 {
            " difft times are the whole process (start, file reads, JSON) under `/usr/bin/time -l`."
        } else {
            ""
        }
    );
    if jobs == 1 {
        let over = |limit: u64| {
            slowest
                .iter()
                .filter(|(time, ..)| *time > Duration::from_millis(limit))
                .count()
        };
        println!(
            "difft over 100 ms: {} files, over 250 ms: {}, over 1 s: {} (of {files}).\n",
            over(100),
            over(250),
            over(1000)
        );
    }
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
    if jobs == 1 {
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
    }
    if !fallback_files.is_empty() {
        let bytes = fallback_files.iter().map(|(bytes, ..)| *bytes);
        let rss = fallback_files.iter().map(|(.., rss)| *rss);
        let size = format!(
            "Fallback files: {}, of {} to {} bytes (right side)",
            fallback_files.len(),
            bytes.clone().min().unwrap_or(0),
            bytes.max().unwrap_or(0),
        );
        let peak = format!(
            "peaked at {}–{} MB",
            mb(rss.clone().min().unwrap_or(0)),
            mb(rss.max().unwrap_or(0))
        );
        if jobs == 1 {
            let times = fallback_files.iter().map(|(_, time, _)| *time);
            let slow = fallback_files
                .iter()
                .filter(|(_, time, _)| *time > Duration::from_secs(1))
                .count();
            println!(
                "\n{size}; difft took {}–{} ms on each, {} ms together, and {peak}; {slow} of the {} files over 1 s are among them.",
                ms(times.clone().min().unwrap_or_default()),
                ms(times.clone().max().unwrap_or_default()),
                ms(times.sum()),
                slowest.iter().filter(|(time, ..)| *time > Duration::from_secs(1)).count(),
            );
        } else {
            println!("\n{size}; difft {peak}.");
        }
    }

    println!("\n#### Examples (the lines where today's marks and difft's differ most)\n");
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

    println!("#### E2 examples: where E2's marks differ from difft's and today's matched (most differing first)\n");
    println!("`difft` is difft's marks with E2's word marks inside comments and strings.\n");
    let print = |title: String, list: &mut Vec<E2Example>| {
        list.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.location.cmp(&b.location)));
        println!("##### {title}\n\n```text");
        for example in list.iter().take(5) {
            println!(
                "{}\n  jj    |{}\n  e2    |{}\n  difft |{}",
                example.location, example.jj, example.e2, example.difft
            );
        }
        println!("```\n");
    };
    for class in [Class::Fewer, Class::More, Class::Different] {
        if let Some(list) = e2_examples.get_mut(&class) {
            print(format!("{} (against E2)", class.label()), list);
        }
    }
    print(
        "Where today's marks differ from difft's and E2's match".to_owned(),
        &mut closed_examples,
    );
    Ok(())
}

/// difft's result for every input, in input order, on `jobs` threads that each write their input
/// pairs to a work directory of their own.
fn difft_all(inputs: &[Input], jobs: usize) -> Result<Vec<marks::DifftDiff>, String> {
    let next = AtomicUsize::new(0);
    let results: Mutex<Vec<Option<Result<marks::DifftDiff, String>>>> =
        Mutex::new(std::iter::repeat_with(|| None).take(inputs.len()).collect());
    std::thread::scope(|scope| {
        for job in 0..jobs {
            let (next, results) = (&next, &results);
            scope.spawn(move || loop {
                let index = next.fetch_add(1, Ordering::Relaxed);
                let Some(input) = inputs.get(index) else { break };
                let file_name = input.path.rsplit('/').next().unwrap_or(&input.path);
                let result = out_dir(&format!("work-history/{job}"))
                    .and_then(|work| marks::difft_diff(&work, file_name, &input.before, &input.after, &[]))
                    .map_err(|error| format!("{} {}: {error}", input.commit, input.path));
                results.lock().expect("no thread panics holding the lock")[index] = Some(result);
                if (index + 1) % 250 == 0 {
                    eprintln!("history: difft on {} of {} files", index + 1, inputs.len());
                }
            });
        }
    });
    results
        .into_inner()
        .expect("no thread panicked holding the lock")
        .into_iter()
        .map(|result| result.unwrap_or_else(|| Err("difft did not run".to_owned())))
        .collect()
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
