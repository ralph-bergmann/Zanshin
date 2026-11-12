// SPDX-License-Identifier: MIT
//! jj-lib's word marks and difftastic's structural marks on the same hunk lines.
//!
//! - **jj marks** are what the inspector drew before E2 (Story 10.32): the `Different` tokens of
//!   jj-lib's `unified_diff_hunks` (context 3, `LineCompareMode::Exact`), merged into runs by the
//!   rule of `crates/zanshin-jj/src/hunks.rs`'s `hunk_line`.
//! - **E2 marks** are what the inspector draws since Story 5.9's build: the same hunks after
//!   `crates/zanshin-jj/src/line_pairs.rs`'s `pair_lines` (this crate compiles that file).
//! - **difft marks** come from `DFT_UNSTABLE=yes difft --display json`: each side's novel spans,
//!   moved onto jj's hunk lines by the mapping Story 5.9's report proposes: a `Removed` line takes
//!   the left side's spans on its line, an `Added` line the right side's, a `Context` line none.
//!   Two rules are kept: the first one (`raw_marks_for`) takes every span; the corrected one
//!   (`marks_for`) keeps jj's word marks inside a novel comment or string, because difft's JSON
//!   lists every word of such an atom, changed or not.

use std::collections::{BTreeMap, BTreeSet};
use std::ops::Range;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use jj_lib::diff_presentation::unified::{unified_diff_hunks, DiffLineType};
use jj_lib::diff_presentation::{DiffTokenType, LineCompareMode};
use jj_lib::merge::Diff;

/// What a hunk line is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Context,
    Removed,
    Added,
}

/// One line of a jj hunk, as the inspector shows it.
pub struct Line {
    pub kind: Kind,
    /// 0-based line number on the left side (`Context`, `Removed`).
    pub left: Option<usize>,
    /// 0-based line number on the right side (`Context`, `Added`).
    pub right: Option<usize>,
    /// The line's bytes, including its `\n`.
    pub text: Vec<u8>,
    /// jj-lib's changed runs, as byte ranges of `text`.
    pub jj: Vec<Range<usize>>,
    /// E2's changed runs (jj-lib's tokens per line pair), as byte ranges of `text`.
    pub e2: Vec<Range<usize>>,
}

/// jj's hunks for one file pair, and the time they took.
pub struct JjDiff {
    pub hunks: Vec<Vec<Line>>,
    /// jj-lib's hunks and today's marks.
    pub elapsed: Duration,
    /// E2's line pairing alone (`pair_lines`), on top of `elapsed`.
    pub e2_elapsed: Duration,
    /// E2's per-file budget (`MAX_PAIRING_WORK`) ran out, so some block kept jj's marks.
    pub e2_budget_ran_out: bool,
}

impl JjDiff {
    /// The removed and added lines of every hunk.
    pub fn changed_lines(&self) -> impl Iterator<Item = &Line> {
        self.hunks.iter().flatten().filter(|line| line.kind != Kind::Context)
    }

    /// The changed blocks with removed and added lines: the ones E2 pairs.
    pub fn paired_blocks(&self) -> usize {
        let mut blocks = 0;
        for hunk in &self.hunks {
            let mut at = 0;
            while at < hunk.len() {
                let removed = hunk[at..].iter().take_while(|line| line.kind == Kind::Removed).count();
                let added = hunk[at + removed..]
                    .iter()
                    .take_while(|line| line.kind == Kind::Added)
                    .count();
                if removed + added == 0 {
                    at += 1;
                    continue;
                }
                blocks += usize::from(removed > 0 && added > 0);
                at += removed + added;
            }
        }
        blocks
    }
}

/// jj's line hunks with today's word marks and E2's, as `hunks.rs` computes them.
pub fn jj_diff(left: &[u8], right: &[u8]) -> JjDiff {
    let texts = Diff::new(left, right);
    let start = Instant::now();
    let mut hunks = unified_diff_hunks(texts.map(Into::into), 3, LineCompareMode::Exact);
    let mut result = Vec::with_capacity(hunks.len());
    for hunk in &hunks {
        let mut left_line = hunk.left_line_range.start;
        let mut right_line = hunk.right_line_range.start;
        let mut lines = Vec::with_capacity(hunk.lines.len());
        for (line_type, tokens) in &hunk.lines {
            let (kind, left, right) = match line_type {
                DiffLineType::Context => (Kind::Context, Some(left_line), Some(right_line)),
                DiffLineType::Removed => (Kind::Removed, Some(left_line), None),
                DiffLineType::Added => (Kind::Added, None, Some(right_line)),
            };
            left_line += usize::from(left.is_some());
            right_line += usize::from(right.is_some());
            let mut text = Vec::new();
            for (_, token) in tokens {
                text.extend_from_slice(token);
            }
            lines.push(Line {
                kind,
                left,
                right,
                text,
                jj: changed_runs(kind, tokens),
                e2: Vec::new(),
            });
        }
        result.push(lines);
    }
    let elapsed = start.elapsed();
    let start = Instant::now();
    let e2_budget_ran_out = crate::line_pairs::pair_lines(&mut hunks, texts);
    let e2_elapsed = start.elapsed();
    for (lines, hunk) in result.iter_mut().zip(&hunks) {
        for (line, (_, tokens)) in lines.iter_mut().zip(&hunk.lines) {
            line.e2 = changed_runs(line.kind, tokens);
        }
    }
    JjDiff {
        hunks: result,
        elapsed,
        e2_elapsed,
        e2_budget_ran_out,
    }
}

/// `hunk_line`'s rule: a `Different` token is the line's change, except on a context line.
fn changed_runs(kind: Kind, tokens: &[(DiffTokenType, &[u8])]) -> Vec<Range<usize>> {
    let mut runs = Vec::new();
    let mut at = 0;
    for (token_type, token) in tokens {
        if *token_type == DiffTokenType::Different && kind != Kind::Context {
            push_range(&mut runs, at..at + token.len());
        }
        at += token.len();
    }
    runs
}

/// One novel span of difft's JSON.
pub struct Span {
    /// Byte range of the original line.
    pub range: Range<usize>,
    /// The span is part of a comment or a string (`highlight` `comment` / `string`).
    pub text_like: bool,
}

/// difft's result for one file pair.
pub struct DifftDiff {
    /// The `language` field: a language name, `Text` (no parser for the file) or `Text (<reason>)`
    /// (a fallback: byte limit, graph limit or parse errors).
    pub language: String,
    /// The `status` field: `changed`, `unchanged`, `created` or `deleted`.
    pub status: String,
    /// Novel spans per 0-based line, left side then right side, in line order.
    pub sides: [BTreeMap<usize, Vec<Span>>; 2],
    /// Wall time of the `difft` process.
    pub elapsed: Duration,
    /// Peak resident set size of the `difft` process in bytes (`/usr/bin/time -l`).
    pub peak_rss: u64,
    /// Spans whose `content` is not the text at their mapped range (expected: 0).
    pub content_mismatches: usize,
    /// Spans that a carriage return earlier on their line moved (difft strips every `\r` first).
    pub cr_shifted_spans: usize,
}

impl DifftDiff {
    /// difft used its line-oriented text diff: no parser for the file, or a fallback.
    pub fn fell_back(&self) -> bool {
        self.language.starts_with("Text")
    }

    fn spans_for(&self, line: &Line) -> &[Span] {
        let at = match line.kind {
            Kind::Context => None,
            Kind::Removed => line.left.map(|number| (0, number)),
            Kind::Added => line.right.map(|number| (1, number)),
        };
        at.and_then(|(side, number)| self.sides[side].get(&number))
            .map_or(&[], Vec::as_slice)
    }

    /// The first mapping rule (the report's starting hypothesis): every novel span on the line.
    pub fn raw_marks_for(&self, line: &Line) -> Vec<Range<usize>> {
        merged(self.spans_for(line).iter().map(|span| span.range.clone()))
    }

    /// The corrected mapping rule: difft's code spans, and inside a novel comment or string only
    /// what jj's word diff marks there.
    pub fn marks_for(&self, line: &Line) -> Vec<Range<usize>> {
        self.marks_with(line, &line.jj)
    }

    /// The corrected mapping rule against E2: inside a novel comment or string, E2's word marks.
    /// Each side is compared with difft on code tokens only, as the corrected rule does for today.
    pub fn e2_marks_for(&self, line: &Line) -> Vec<Range<usize>> {
        self.marks_with(line, &line.e2)
    }

    /// difft's code spans, and inside a novel comment or string the `words` marks there.
    fn marks_with(&self, line: &Line, words: &[Range<usize>]) -> Vec<Range<usize>> {
        let spans = self.spans_for(line);
        let code = spans
            .iter()
            .filter(|span| !span.text_like)
            .map(|span| span.range.clone());
        let text = spans.iter().filter(|span| span.text_like).flat_map(|span| {
            words.iter().filter_map(move |word| {
                let range = word.start.max(span.range.start)..word.end.min(span.range.end);
                (range.start < range.end).then_some(range)
            })
        });
        merged(code.chain(text))
    }

    /// The merged novel ranges per line of one side.
    pub fn marked_lines(&self, side: usize) -> impl Iterator<Item = (usize, Vec<Range<usize>>)> + '_ {
        self.sides[side]
            .iter()
            .map(|(number, spans)| (*number, merged(spans.iter().map(|span| span.range.clone()))))
    }
}

/// `ranges` sorted and joined where they touch or overlap.
fn merged(ranges: impl Iterator<Item = Range<usize>>) -> Vec<Range<usize>> {
    let mut ranges: Vec<Range<usize>> = ranges.collect();
    ranges.sort_by_key(|range| range.start);
    let mut result = Vec::with_capacity(ranges.len());
    for range in ranges {
        push_range(&mut result, range);
    }
    result
}

/// The only difft the probe trusts: its JSON is unstable, and the report's numbers are 0.72.0's.
const DIFFT_VERSION: &str = "Difftastic 0.72.0";

/// `difft --version`'s first line, or an error unless it is 0.72.0.
pub fn require_difft() -> Result<String, String> {
    let output = Command::new("difft")
        .arg("--version")
        .output()
        .map_err(|error| format!("difft: {error}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let version = stdout.lines().next().unwrap_or_default().trim().to_owned();
    if output.status.success() && version == DIFFT_VERSION {
        Ok(version)
    } else {
        Err(format!("the probe needs {DIFFT_VERSION} on PATH, found `{version}`"))
    }
}

/// A `difft` command that ignores the caller's `DFT_*` settings.
pub fn difft() -> Command {
    let mut command = Command::new("difft");
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("DFT_") {
            command.env_remove(key);
        }
    }
    command
}

/// A `difft` command that prints JSON and ignores the caller's `DFT_*` settings.
pub fn difft_command() -> Command {
    let mut command = difft();
    command
        .env("DFT_UNSTABLE", "yes")
        .args(["--display", "json", "--color", "never"]);
    command
}

/// Runs difft on `left` → `right`, written to `work/lhs/<file_name>` and `work/rhs/<file_name>`
/// (difft picks the language by file name), with `extra_args` before the paths.
pub fn difft_diff(
    work: &Path,
    file_name: &str,
    left: &[u8],
    right: &[u8],
    extra_args: &[&str],
) -> Result<DifftDiff, String> {
    let paths = write_pair(work, file_name, left, right)?;
    let mut command = difft_command();
    command.args(extra_args).arg(&paths[0]).arg(&paths[1]);
    let run = crate::measure(&command).map_err(|error| format!("{file_name}: {error}"))?;
    parse_difft_json(&run.stdout, left, right, run.wall, run.peak_rss)
}

/// Writes the two sides for difft; returns their paths.
pub fn write_pair(work: &Path, file_name: &str, left: &[u8], right: &[u8]) -> Result<[std::path::PathBuf; 2], String> {
    let paths = [work.join("lhs").join(file_name), work.join("rhs").join(file_name)];
    for (path, bytes) in paths.iter().zip([left, right]) {
        let parent = path.parent().expect("a joined path has a parent");
        std::fs::create_dir_all(parent).map_err(|error| format!("{}: {error}", parent.display()))?;
        std::fs::write(path, bytes).map_err(|error| format!("{}: {error}", path.display()))?;
    }
    Ok(paths)
}

/// Reads difft's JSON for one file pair (difftastic 0.72.0, `src/display/json.rs`).
pub fn parse_difft_json(
    stdout: &[u8],
    left: &[u8],
    right: &[u8],
    elapsed: Duration,
    peak_rss: u64,
) -> Result<DifftDiff, String> {
    let json: serde_json::Value = serde_json::from_slice(stdout).map_err(|error| format!("difft JSON: {error}"))?;
    let field = |name: &str| json[name].as_str().unwrap_or_default().to_owned();
    let lines = [split_lines(left), split_lines(right)];
    let mut result = DifftDiff {
        language: field("language"),
        status: field("status"),
        sides: [BTreeMap::new(), BTreeMap::new()],
        elapsed,
        peak_rss,
        content_mismatches: 0,
        cr_shifted_spans: 0,
    };
    let entries = json["chunks"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|chunk| chunk.as_array())
        .flatten();
    for entry in entries {
        for (side, key) in [(0, "lhs"), (1, "rhs")] {
            let Some(line_side) = entry.get(key) else { continue };
            let number = usize::try_from(line_side["line_number"].as_u64().unwrap_or(u64::MAX)).unwrap_or(usize::MAX);
            let Some(line) = lines[side].get(number) else {
                result.content_mismatches += 1;
                continue;
            };
            // difft strips every `\r` before it parses (`--strip-cr on`), so its columns are byte
            // offsets of the line without them.
            let kept: Vec<usize> = (0..line.len()).filter(|&at| line[at] != b'\r').collect();
            for change in line_side["changes"].as_array().into_iter().flatten() {
                let column = |name: &str| usize::try_from(change[name].as_u64().unwrap_or(0)).unwrap_or(0);
                let (start, end) = (column("start"), column("end"));
                // A novel multi-line atom (comment, string) ends each line with an empty span.
                if start == end {
                    continue;
                }
                if start > end || end > kept.len() {
                    result.content_mismatches += 1;
                    continue;
                }
                let range = kept[start]..kept[end - 1] + 1;
                if range != (start..end) {
                    result.cr_shifted_spans += 1;
                }
                let stripped: Vec<u8> = kept[start..end].iter().map(|&at| line[at]).collect();
                if change["content"].as_str().map(str::as_bytes) != Some(&stripped[..]) {
                    result.content_mismatches += 1;
                }
                let text_like = matches!(change["highlight"].as_str(), Some("comment" | "string"));
                result.sides[side]
                    .entry(number)
                    .or_default()
                    .push(Span { range, text_like });
            }
        }
    }
    for spans in result.sides.iter_mut().flat_map(BTreeMap::values_mut) {
        spans.sort_by_key(|span| span.range.start);
    }
    Ok(result)
}

/// The lines of `text` as jj and difft number them: split after each `\n`.
pub fn split_lines(text: &[u8]) -> Vec<&[u8]> {
    text.split_inclusive(|byte| *byte == b'\n').collect()
}

/// Appends `range`, joining it to the last range when they touch or overlap.
pub fn push_range(ranges: &mut Vec<Range<usize>>, range: Range<usize>) {
    match ranges.last_mut() {
        Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
        _ => ranges.push(range),
    }
}

/// The length of the text the inspector shows: the line without its `\n` and a `\r` before it.
pub fn shown_len(text: &[u8]) -> usize {
    let text = text.strip_suffix(b"\n").unwrap_or(text);
    text.strip_suffix(b"\r").unwrap_or(text).len()
}

/// The marked bytes of the shown text that are not whitespace — the "ink" two marks are compared by.
pub fn ink(text: &[u8], marks: &[Range<usize>]) -> BTreeSet<usize> {
    let shown = shown_len(text);
    marks
        .iter()
        .flat_map(|range| range.start..range.end.min(shown))
        .filter(|&at| !text[at].is_ascii_whitespace())
        .collect()
}

/// The marks Story 10.32 draws (`diffWordMarks`, `app/lib/src/features/graph/inspector_diff.dart`):
/// none when the unmarked text holds no visible character (Dart's `trim()`, so Unicode whitespace
/// does not count), else every mark cut at the shown text's end, spaces included.
pub fn drawn(text: &[u8], marks: &[Range<usize>]) -> Vec<Range<usize>> {
    let shown = shown_len(text);
    let clipped: Vec<Range<usize>> = marks
        .iter()
        .filter(|range| range.start < shown)
        .map(|range| range.start..range.end.min(shown))
        .collect();
    let mut at = 0;
    let mut visible = false;
    for range in clipped.iter().chain(std::iter::once(&(shown..shown))) {
        visible |= String::from_utf8_lossy(&text[at..range.start])
            .chars()
            .any(|character| !character.is_whitespace());
        at = range.end;
    }
    if visible {
        clipped
    } else {
        Vec::new()
    }
}

/// The class of one changed line as 10.32 draws it: the drawn bytes, whitespace included.
pub fn classify_drawn(jj: &[Range<usize>], difft: &[Range<usize>]) -> Class {
    let bytes = |ranges: &[Range<usize>]| ranges.iter().flat_map(Clone::clone).collect::<BTreeSet<usize>>();
    compare(&bytes(jj), &bytes(difft))
}

/// How difft's marks on one changed line compare with jj's: by their non-whitespace bytes
/// (`classify`) or by the bytes 10.32 draws, whitespace included (`classify_drawn`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Class {
    /// The same bytes are marked.
    Same,
    /// difft marks a strict subset of jj's bytes.
    Fewer,
    /// difft marks a strict superset of jj's bytes.
    More,
    /// Each marks bytes the other does not.
    Different,
    /// difft fell back to its text diff; a build keeps jj's marks.
    Fallback,
}

impl Class {
    pub const ALL: [Class; 5] = [
        Class::Same,
        Class::Fewer,
        Class::More,
        Class::Different,
        Class::Fallback,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Class::Same => "same marks",
            Class::Fewer => "difft marks fewer bytes",
            Class::More => "difft marks more bytes",
            Class::Different => "different bytes",
            Class::Fallback => "difft fell back",
        }
    }
}

/// The class of one changed line, comparing the marked non-whitespace bytes.
pub fn classify(text: &[u8], jj: &[Range<usize>], difft: &[Range<usize>]) -> Class {
    compare(&ink(text, jj), &ink(text, difft))
}

fn compare(jj: &BTreeSet<usize>, difft: &BTreeSet<usize>) -> Class {
    if jj == difft {
        Class::Same
    } else if difft.is_subset(jj) {
        Class::Fewer
    } else if difft.is_superset(jj) {
        Class::More
    } else {
        Class::Different
    }
}

/// The shown text with its marks in `[-…-]` (removed) or `{+…+}` (added) notation; tabs and
/// carriage returns are written as `\t` and `\r`.
pub fn render(text: &[u8], marks: &[Range<usize>], kind: Kind) -> String {
    let shown = shown_len(text);
    let (open, close) = if kind == Kind::Removed {
        ("[-", "-]")
    } else {
        ("{+", "+}")
    };
    let piece = |range: Range<usize>| {
        String::from_utf8_lossy(&text[range])
            .replace('\t', "\\t")
            .replace('\r', "\\r")
    };
    let mut out = String::new();
    let mut at = 0;
    for range in marks.iter().filter(|range| range.start < shown) {
        let end = range.end.min(shown);
        out.push_str(&piece(at..range.start));
        out.push_str(open);
        out.push_str(&piece(range.start..end));
        out.push_str(close);
        at = end;
    }
    out.push_str(&piece(at..shown));
    out
}

/// Where difft marked text that jj's hunks do not show as changed, counted in merged marks.
#[derive(Default)]
pub struct Dropped {
    /// Marks on lines jj shows as context: the mapping drops them.
    pub on_context: usize,
    /// Marks on lines outside every jj hunk.
    pub outside: usize,
}

/// Counts the difft marks the mapping drops.
pub fn dropped(jj: &JjDiff, difft: &DifftDiff) -> Dropped {
    let mut changed = [BTreeSet::new(), BTreeSet::new()];
    let mut context = [BTreeSet::new(), BTreeSet::new()];
    for line in jj.hunks.iter().flatten() {
        let target = if line.kind == Kind::Context {
            &mut context
        } else {
            &mut changed
        };
        if let Some(number) = line.left {
            target[0].insert(number);
        }
        if let Some(number) = line.right {
            target[1].insert(number);
        }
    }
    let mut result = Dropped::default();
    for side in 0..2 {
        for (number, ranges) in difft.marked_lines(side) {
            if changed[side].contains(&number) {
                continue;
            }
            if context[side].contains(&number) {
                result.on_context += ranges.len();
            } else {
                result.outside += ranges.len();
            }
        }
    }
    result
}
