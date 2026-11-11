// SPDX-License-Identifier: MIT

//! Word-level segments of diff lines (Story 5.2, FR-DF-1): which words of a changed line changed.
//!
//! **Pairing — the default Delta-class behaviour.** A run of removed lines directly followed by a
//! run of added lines pairs in order: the i-th removed line with the i-th added line. Each pair is
//! word-diffed ([`compute_word_diff`]), unless one of its lines is longer than 131,072
//! characters. A line without a word diff is one segment of its own kind (`Removed` / `Added`),
//! and a context line is one `Equal` segment.
//!
//! **Word diff.** `imara-diff`'s Histogram algorithm over the line's Unicode word-bound tokens
//! (UAX #29): a run of spaces (`WSegSpace`) is one token, but each tab and each no-break space
//! (U+00A0, U+2007) is a token of its own, while a narrow no-break space (U+202F) joins the
//! letters or digits around it; a line ending (`\n` or `\r\n`) is one token; and an emoji or a
//! base character with its combining marks is one token.
//!
//! A line's segments concatenate exactly to its text, `\n` included. No segment is empty, and
//! adjacent tokens of one kind form one segment.

use imara_diff::{Algorithm, Diff, InternedInput, Token};
use unicode_segmentation::UnicodeSegmentation as _;
use zanshin_jj::HunkLine;

// shortcut: a line over 131,072 characters gets no word diff (in a pair) and no syntax classes
// (`highlight_line`), raise once both are time-bounded. Characters, not bytes, so a 100k-character
// line of any script is still diffed and highlighted.
pub(crate) const MAX_LINE_CHARS: usize = 128 * 1024;

/// A run of a line's text with one kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Segment {
    /// The run's text: whole tokens, never empty.
    pub text: String,
    /// Whether the run is on both lines of a pair, or only on one side.
    pub kind: SegmentKind,
}

/// What a [`Segment`] is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SegmentKind {
    /// On both lines of a pair, or a context line.
    Equal,
    /// Only on the added line.
    Added,
    /// Only on the removed line.
    Removed,
}

/// The word diff of a removed line against the added line it pairs with: the removed line's
/// segments (`Equal` and `Removed`) and the added line's (`Equal` and `Added`).
#[must_use]
pub fn compute_word_diff(removed_line: &str, added_line: &str) -> (Vec<Segment>, Vec<Segment>) {
    let mut input = InternedInput::default();
    input.update_before(removed_line.split_word_bounds());
    input.update_after(added_line.split_word_bounds());
    let mut diff = Diff::compute(Algorithm::Histogram, &input);
    diff.postprocess_no_heuristic(&input);
    let side = |tokens: &[Token], kind: SegmentKind, changed: fn(&Diff, u32) -> bool| {
        merge((0..).zip(tokens).map(|(index, &token)| {
            let kind = if changed(&diff, index) {
                kind
            } else {
                SegmentKind::Equal
            };
            (input.interner[token], kind)
        }))
    };
    (
        side(&input.before, SegmentKind::Removed, Diff::is_removed),
        side(&input.after, SegmentKind::Added, Diff::is_added),
    )
}

/// The segments of every line of one hunk, index-aligned with `lines`, under the pairing rule in
/// the module documentation. [`compute_word_diff`] runs on the pairs only.
#[must_use]
pub fn line_segments(lines: &[HunkLine]) -> Vec<Vec<Segment>> {
    let mut paired: Vec<Option<Vec<Segment>>> = vec![None; lines.len()];
    let mut start = 0;
    while start < lines.len() {
        let removed = run_of(&lines[start..], SegmentKind::Removed);
        let added = run_of(&lines[start + removed..], SegmentKind::Added);
        for offset in 0..removed.min(added) {
            let (removed_index, added_index) = (start + offset, start + removed + offset);
            let removed_text = kind_and_text(&lines[removed_index]).1;
            let added_text = kind_and_text(&lines[added_index]).1;
            if removed_text.chars().count().max(added_text.chars().count()) > MAX_LINE_CHARS {
                continue;
            }
            let (removed_segments, added_segments) = compute_word_diff(removed_text, added_text);
            paired[removed_index] = Some(removed_segments);
            paired[added_index] = Some(added_segments);
        }
        start += (removed + added).max(1);
    }
    lines
        .iter()
        .zip(paired)
        .map(|(line, segments)| {
            segments.unwrap_or_else(|| {
                let (kind, text) = kind_and_text(line);
                vec![Segment {
                    text: text.to_owned(),
                    kind,
                }]
            })
        })
        .collect()
}

/// `tokens` with their kinds as segments: adjacent tokens of one kind form one segment.
fn merge<'t>(tokens: impl Iterator<Item = (&'t str, SegmentKind)>) -> Vec<Segment> {
    let mut segments: Vec<Segment> = Vec::new();
    for (text, kind) in tokens {
        match segments.last_mut() {
            Some(last) if last.kind == kind => last.text.push_str(text),
            _ => segments.push(Segment {
                text: text.to_owned(),
                kind,
            }),
        }
    }
    segments
}

/// How many lines at the start of `lines` are of `kind`.
fn run_of(lines: &[HunkLine], kind: SegmentKind) -> usize {
    lines.iter().take_while(|line| kind_and_text(line).0 == kind).count()
}

/// A line's own segment kind and its text.
fn kind_and_text(line: &HunkLine) -> (SegmentKind, &str) {
    match line {
        HunkLine::Context(text) => (SegmentKind::Equal, text),
        HunkLine::Removed(text) => (SegmentKind::Removed, text),
        HunkLine::Added(text) => (SegmentKind::Added, text),
    }
}
