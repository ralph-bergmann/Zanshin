// SPDX-License-Identifier: MIT

//! `line_pairs.rs` — word marks per line pair.
//!
//! jj-lib's `unified_diff_hunks` word-diffs all removed lines of a changed block against all its
//! added lines as one text, so common words match across unrelated lines and the marks scatter:
//! two rewritten comments then mark almost every word. [`pair_lines`] keeps jj-lib's line-level
//! hunks and rewrites only the word tokens of each changed block (a run of removed lines, then a
//! run of added lines):
//!
//! - It pairs the block's removed and added lines by similarity and keeps their order. A group is
//!   one line against one line, one line against a run of consecutive lines (a call split over
//!   lines), or a run against one line (lines joined into one). Similarity counts jj-lib's word-diff
//!   tokens (see [`group_value`]).
//! - A group's lines take the tokens of jj-lib's own `ContentDiff::by_word` over the group's
//!   text, split into lines as jj-lib splits them.
//! - A line in no group gets one changed token for the whole line.
//! - The search of a file may read at most [`MAX_PAIRING_WORK`] bytes; a block it cannot pay for
//!   keeps jj-lib's block-wide tokens.
//!
//! The module imports only `jj_lib` and `std`, so the structural-diff probe
//! (`spikes/structural-diff-probe/`) compiles this same file and measures the real code.

use std::cmp::Ordering;
use std::ops::Range;

use jj_lib::diff::{find_line_ranges, find_nonword_ranges, find_word_ranges, ContentDiff, DiffHunkKind};
use jj_lib::diff_presentation::unified::{DiffLineType, UnifiedDiffHunk};
use jj_lib::diff_presentation::{unzip_diff_hunks_to_lines, DiffTokenType};
use jj_lib::merge::Diff;

/// A group pairs only when its similarity is above this share: then more of its tokens are shared
/// than marked. Below it the marks would cover most of the lines anyway, and unrelated lines
/// (two comments, two test names) would pair through a few common words.
pub(crate) const MIN_SIMILARITY_PERCENT: i64 = 50;

/// The longest run of consecutive lines one line may pair with on the other side. A call split
/// over more lines is rare, and every longer run adds two candidates to each cell of the search.
pub(crate) const MAX_RUN_LINES: usize = 8;

/// The bytes the search of one file may read. Each searched block first pays for its one-to-one
/// candidates (`added lines · removed bytes + removed lines · added bytes`): its table of shared
/// tokens reads them, and they bound the table's size even when every candidate is pruned. Then
/// each word diff that scores a candidate pays for its input. A block that cannot pay for its
/// one-to-one candidates is not searched, and a search that runs out stops; such blocks keep
/// jj-lib's block-wide tokens. So the pairing's time and memory per file stay bounded, whatever
/// its blocks. Measured with the structural-diff probe (its README, "Re-run after the follow-up
/// review").
pub(crate) const MAX_PAIRING_WORK: usize = 1 << 18;

/// One line's word tokens, as `unified_diff_hunks` keeps them.
type Tokens<'a> = Vec<(DiffTokenType, &'a [u8])>;

/// Replaces the word tokens of each changed block of `hunks` — `unified_diff_hunks` over `texts` —
/// with the tokens of its line pairs (see the module doc). Lines, kinds and ranges stay as they
/// are, and so does a block with only removed or only added lines: its lines are already one
/// changed token each. Returns whether a block kept jj-lib's tokens because [`MAX_PAIRING_WORK`]
/// could not pay for its search.
pub(crate) fn pair_lines<'a>(hunks: &mut [UnifiedDiffHunk<'a>], texts: Diff<&'a [u8]>) -> bool {
    pair_lines_within(hunks, texts, MAX_PAIRING_WORK)
}

/// [`pair_lines`] with `budget` bytes for the word diffs that score the candidates of the file.
fn pair_lines_within<'a>(hunks: &mut [UnifiedDiffHunk<'a>], texts: Diff<&'a [u8]>, mut budget: usize) -> bool {
    let mut line_ranges = None;
    let mut ran_out = false;
    for hunk in hunks {
        let (mut left, mut right) = (hunk.left_line_range.start, hunk.right_line_range.start);
        let mut at = 0;
        while at < hunk.lines.len() {
            let removed = run_length(&hunk.lines[at..], DiffLineType::Removed);
            let added = run_length(&hunk.lines[at + removed..], DiffLineType::Added);
            if removed + added == 0 {
                // A context line: one line on each side.
                (left, right, at) = (left + 1, right + 1, at + 1);
                continue;
            }
            let lines = &mut hunk.lines[at..at + removed + added];
            if removed > 0 && added > 0 {
                let ranges: &Diff<Vec<Range<usize>>> = line_ranges.get_or_insert_with(|| texts.map(find_line_ranges));
                let sides = (
                    ranges.before.get(left..left + removed),
                    ranges.after.get(right..right + added),
                );
                if let (Some(before), Some(after)) = sides {
                    let block = Diff::new(
                        Side {
                            text: texts.before,
                            lines: before,
                        },
                        Side {
                            text: texts.after,
                            lines: after,
                        },
                    );
                    // The search pays for its table first, so blocks whose candidates are all
                    // pruned still spend the budget; a block that cannot pay is not searched.
                    let paired = budget.checked_sub(block_work(block)).and_then(|rest| {
                        budget = rest;
                        pair_block(block, &mut budget)
                    });
                    if let Some(paired) = paired {
                        debug_assert!(
                            lines
                                .iter()
                                .flat_map(|(_, tokens)| tokens)
                                .flat_map(|(_, bytes)| bytes.iter())
                                .eq(block.before.all().iter().chain(block.after.all())),
                            "the block's lines are its text"
                        );
                        for ((_, tokens), new) in lines.iter_mut().zip(paired.before.into_iter().chain(paired.after)) {
                            *tokens = new;
                        }
                    } else {
                        ran_out = true;
                    }
                }
            }
            (left, right, at) = (left + removed, right + added, at + removed + added);
        }
    }
    ran_out
}

/// How many of `lines` lead with `kind`.
fn run_length(lines: &[(DiffLineType, Tokens<'_>)], kind: DiffLineType) -> usize {
    lines.iter().take_while(|(line_kind, _)| *line_kind == kind).count()
}

/// One side of a changed block: its file's text and the block's lines in it.
#[derive(Clone, Copy)]
struct Side<'a, 'r> {
    text: &'a [u8],
    lines: &'r [Range<usize>],
}

impl<'a> Side<'a, '_> {
    /// The block's lines `lines` (nonempty) as one text.
    fn text(self, lines: Range<usize>) -> &'a [u8] {
        &self.text[self.lines[lines.start].start..self.lines[lines.end - 1].end]
    }

    /// All the block's lines (at least one) as one text.
    fn all(self) -> &'a [u8] {
        self.text(0..self.lines.len())
    }

    /// The token count of the block's first `k` lines, for every `k`.
    fn prefix_tokens(self) -> Vec<i64> {
        std::iter::once(0)
            .chain(self.lines.iter().scan(0, |sum, line| {
                *sum += token_count(&self.text[line.clone()]);
                Some(*sum)
            }))
            .collect()
    }

    /// Each line's tokens, sorted. Words never span a line break, so a run's tokens are its
    /// lines'.
    fn sorted_tokens(self) -> Vec<Vec<&'a [u8]>> {
        self.lines
            .iter()
            .map(|line| {
                let mut tokens: Vec<&[u8]> = tokens(&self.text[line.clone()]).collect();
                tokens.sort_unstable();
                tokens
            })
            .collect()
    }
}

/// The bytes the one-to-one candidates of `block` read: each added line reads every removed byte,
/// each removed line every added byte.
fn block_work(block: Diff<Side<'_, '_>>) -> usize {
    let (removed, added) = (block.before, block.after);
    added
        .lines
        .len()
        .saturating_mul(removed.all().len())
        .saturating_add(removed.lines.len().saturating_mul(added.all().len()))
}

/// Each line's tokens for one block. An order-keeping search over (removed, added) prefixes
/// finds the groups whose summed [`group_value`] is highest; a line in no group is worth 0. Every
/// scoring word diff takes its input bytes from `budget`; `None` when the budget runs out.
fn pair_block<'a>(block: Diff<Side<'a, '_>>, budget: &mut usize) -> Option<Diff<Vec<Tokens<'a>>>> {
    let (removed, added) = (block.before, block.after);
    let count = block.map(Side::prefix_tokens);
    // `shared[i * columns + j]`: the tokens removed line `i` and added line `j` have in common.
    let sorted = block.map(Side::sorted_tokens);
    let columns = added.lines.len();
    let shared: Vec<i64> = sorted
        .before
        .iter()
        .flat_map(|left| sorted.after.iter().map(move |right| shared_tokens(left, right)))
        .collect();
    let shapes = group_shapes();
    let width = added.lines.len() + 1;
    let cells = (removed.lines.len() + 1) * width;
    // `best[i * width + j]` is the highest value for the first `i` removed and `j` added lines;
    // `step` holds how many lines of each side its last step takes: `[1, 0]` or `[0, 1]` leave
    // a line unpaired, anything else is a group.
    let mut best = vec![0_i64; cells];
    let mut step = vec![[0_usize; 2]; cells];
    for i in 0..=removed.lines.len() {
        for j in 0..=added.lines.len() {
            let cell = i * width + j;
            if cell == 0 {
                continue;
            }
            let (mut value, mut taken) = (i64::MIN, [0, 0]);
            if i > 0 {
                (value, taken) = (best[cell - width], [1, 0]);
            }
            if j > 0 && best[cell - 1] > value {
                (value, taken) = (best[cell - 1], [0, 1]);
            }
            for &[di, dj] in &shapes {
                if di > i || dj > j {
                    continue;
                }
                let start = best[cell - di * width - dj];
                let (left, right) = (
                    count.before[i] - count.before[i - di],
                    count.after[j] - count.after[j - dj],
                );
                // A group keeps at most the smaller side's tokens and the tokens its lines share
                // (one side is a single line, so at most the sum over its pairs): skip the diff
                // when even that cannot beat the cell's best. It is an upper bound, so skipping
                // never changes the result.
                let in_common: i64 = (i - di..i)
                    .flat_map(|a| (j - dj..j).map(move |b| a * columns + b))
                    .map(|pair| shared[pair])
                    .sum();
                let most = in_common.min(left).min(right);
                if start + group_value(most, left + right) <= value {
                    continue;
                }
                let texts = (removed.text(i - di..i), added.text(j - dj..j));
                // Out of budget: this block and every later one keep jj-lib's tokens.
                let Some(rest) = budget.checked_sub(texts.0.len() + texts.1.len()) else {
                    *budget = 0;
                    return None;
                };
                *budget = rest;
                let kept = kept_tokens(texts.0, texts.1);
                debug_assert!(kept <= most, "a word diff keeps no more than its lines share");
                let gain = group_value(kept, left + right);
                if start + gain > value {
                    (value, taken) = (start + gain, [di, dj]);
                }
            }
            best[cell] = value;
            step[cell] = taken;
        }
    }

    let mut tokens = Diff::new(
        vec![Tokens::new(); removed.lines.len()],
        vec![Tokens::new(); added.lines.len()],
    );
    let (mut i, mut j) = (removed.lines.len(), added.lines.len());
    while i > 0 || j > 0 {
        let [di, dj] = step[i * width + j];
        if dj == 0 {
            tokens.before[i - 1] = vec![(DiffTokenType::Different, removed.text(i - 1..i))];
        } else if di == 0 {
            tokens.after[j - 1] = vec![(DiffTokenType::Different, added.text(j - 1..j))];
        } else {
            let diff = ContentDiff::by_word([removed.text(i - di..i), added.text(j - dj..j)]);
            let lines = unzip_diff_hunks_to_lines(diff.hunks());
            for (slot, line) in tokens.before[i - di..i].iter_mut().zip(lines.before) {
                *slot = line;
            }
            for (slot, line) in tokens.after[j - dj..j].iter_mut().zip(lines.after) {
                *slot = line;
            }
        }
        (i, j) = (i - di, j - dj);
    }
    Some(tokens)
}

/// The group shapes as `[removed lines, added lines]`, shorter groups first so that a tie keeps
/// the shorter group: one to one, then one line against a run of `k` and a run of `k` against one.
fn group_shapes() -> Vec<[usize; 2]> {
    std::iter::once([1, 1])
        .chain((2..=MAX_RUN_LINES).flat_map(|k| [[1, k], [k, 1]]))
        .collect()
}

/// A group's worth: `(similarity − MIN_SIMILARITY_PERCENT) · total`, where `total` is the tokens
/// of both sides and similarity is `2 · kept / total` in percent. It is positive only above the
/// threshold, so the search takes a group only then, and a loosely related line absorbed into a
/// run lowers the run's worth.
///
/// Every token counts 1, whatever its length: a changed identifier is one change, so
/// `a.functionWizard_save,` → `a.functionWizard_next,` keeps 3 of 4 tokens a side (75 %) and pairs.
fn group_value(kept: i64, total: i64) -> i64 {
    2 * 100 * kept - MIN_SIMILARITY_PERCENT * total
}

/// The tokens jj-lib's word diff keeps between `left` and `right`, counted once. It scores exactly
/// what the marks will show. The kept runs hold whole tokens, so counting their tokens is exact.
fn kept_tokens(left: &[u8], right: &[u8]) -> i64 {
    ContentDiff::by_word([left, right])
        .hunks()
        .filter(|hunk| hunk.kind == DiffHunkKind::Matching)
        .map(|hunk| token_count(hunk.contents[0]))
        .sum()
}

/// How many tokens `left` and `right` (both sorted) have in common, each occurrence matched once.
/// jj-lib's word diff keeps only whole equal words and equal single non-word bytes, each paired
/// once, so it can keep no more than this.
fn shared_tokens(left: &[&[u8]], right: &[&[u8]]) -> i64 {
    let (mut l, mut r, mut shared) = (0, 0, 0);
    while let (Some(&token), Some(&other)) = (left.get(l), right.get(r)) {
        match token.cmp(other) {
            Ordering::Less => l += 1,
            Ordering::Greater => r += 1,
            Ordering::Equal => (shared, l, r) = (shared + 1, l + 1, r + 1),
        }
    }
    shared
}

/// The tokens of `bytes` in jj-lib's word diff: its words, and its non-word bytes that are not
/// whitespace. Whitespace is left out so that shared indentation and spaces do not make unrelated
/// lines look alike.
fn tokens(bytes: &[u8]) -> impl Iterator<Item = &[u8]> {
    let symbols = find_nonword_ranges(bytes)
        .into_iter()
        .filter(|symbol| !bytes[symbol.start].is_ascii_whitespace());
    find_word_ranges(bytes)
        .into_iter()
        .chain(symbols)
        .map(move |range| &bytes[range])
}

/// How many [`tokens`] `bytes` has.
fn token_count(bytes: &[u8]) -> i64 {
    tokens(bytes).fold(0, |count, _| count + 1)
}

#[cfg(test)]
mod tests {
    use jj_lib::diff_presentation::unified::unified_diff_hunks;
    use jj_lib::diff_presentation::LineCompareMode;

    use super::*;

    /// Every line of `hunks` with its changed tokens in `[-…-]` (removed) or `{+…+}` (added).
    fn render(hunks: &[UnifiedDiffHunk<'_>]) -> Vec<String> {
        hunks
            .iter()
            .flat_map(|hunk| &hunk.lines)
            .map(|(kind, tokens)| {
                let (sign, open, close) = match kind {
                    DiffLineType::Context => (' ', "", ""),
                    DiffLineType::Removed => ('-', "[-", "-]"),
                    DiffLineType::Added => ('+', "{+", "+}"),
                };
                let mut out = String::from(sign);
                let mut changed = false;
                for (token_type, bytes) in tokens {
                    let different = *token_type == DiffTokenType::Different;
                    if different != changed {
                        out.push_str(if different { open } else { close });
                        changed = different;
                    }
                    out.push_str(&String::from_utf8_lossy(bytes));
                }
                if changed {
                    out.push_str(close);
                }
                out
            })
            .collect()
    }

    /// `left` → `right` with jj-lib's tokens, then with the paired ones.
    fn both(left: &str, right: &str) -> (Vec<String>, Vec<String>) {
        let texts = Diff::new(left.as_bytes(), right.as_bytes());
        let mut hunks = unified_diff_hunks(texts.map(Into::into), 3, LineCompareMode::Exact);
        let before = render(&hunks);
        pair_lines(&mut hunks, texts);
        (before, render(&hunks))
    }

    fn paired(left: &str, right: &str) -> Vec<String> {
        both(left, right).1
    }

    /// `left` → `right` under `mode` with `budget`: the paired lines and whether the budget ran out.
    fn paired_with(left: &str, right: &str, mode: LineCompareMode, budget: usize) -> (Vec<String>, bool) {
        let texts = Diff::new(left.as_bytes(), right.as_bytes());
        let mut hunks = unified_diff_hunks(texts.map(Into::into), 3, mode);
        let ran_out = pair_lines_within(&mut hunks, texts, budget);
        (render(&hunks), ran_out)
    }

    /// A call split over the longest run (`f(`, six arguments, `)`) pairs as one group, and so does
    /// its mirror join: only line breaks, indentation and the trailing comma change.
    #[test]
    fn a_run_of_eight_lines_pairs() {
        let (one, eight) = (
            "f(a0, a1, a2, a3, a4, a5)\n",
            "f(\n  a0,\n  a1,\n  a2,\n  a3,\n  a4,\n  a5,\n)\n",
        );
        assert_eq!(
            paired(one, eight),
            [
                "-f(a0, a1, a2, a3, a4, a5)\n",
                "+f({+\n+}",
                "+{+  +}a0,{+\n+}",
                "+{+ +} a1,{+\n+}",
                "+{+ +} a2,{+\n+}",
                "+{+ +} a3,{+\n+}",
                "+{+ +} a4,{+\n+}",
                "+{+ +} a5{+,\n+}",
                "+)\n"
            ]
        );
        assert_eq!(
            paired(eight, one),
            [
                "-f([-\n-]",
                "-[-  -]a0,[-\n-]",
                "-[- -] a1,[-\n-]",
                "-[- -] a2,[-\n-]",
                "-[- -] a3,[-\n-]",
                "-[- -] a4,[-\n-]",
                "-[- -] a5[-,\n-]",
                "-)\n",
                "+f(a0, a1, a2, a3, a4, a5)\n"
            ]
        );
    }

    /// A split over nine lines is one line longer than a run may be: its last line stays unpaired.
    #[test]
    fn a_run_of_nine_lines_does_not_pair() {
        let marked = paired(
            "f(a0, a1, a2, a3, a4, a5, a6)\n",
            "f(\n  a0,\n  a1,\n  a2,\n  a3,\n  a4,\n  a5,\n  a6,\n)\n",
        );
        assert_eq!(marked.last().map(String::as_str), Some("+{+)\n+}"));
        assert_eq!(
            marked,
            [
                "-f(a0, a1, a2, a3, a4, a5, a6[-)-]\n",
                "+f({+\n+}",
                "+{+  +}a0,{+\n+}",
                "+{+ +} a1,{+\n+}",
                "+{+ +} a2,{+\n+}",
                "+{+ +} a3,{+\n+}",
                "+{+ +} a4,{+\n+}",
                "+{+ +} a5,{+\n+}",
                "+{+ +} a6{+,+}\n",
                "+{+)\n+}"
            ]
        );
    }

    /// A tie keeps the shorter group: `foo(a) zed` against `foo(a)` alone and against `foo(a)` plus
    /// `zed p q r` are both worth 350 (4 of 9 and 5 of 13 tokens kept).
    #[test]
    fn a_tie_keeps_the_shorter_group() {
        assert_eq!(kept_tokens(b"foo(a) zed\n", b"foo(a)\n"), 4);
        assert_eq!(kept_tokens(b"foo(a) zed\n", b"foo(a)\nzed p q r\n"), 5);
        assert_eq!(group_value(4, 9), group_value(5, 13));
        assert_eq!(
            paired("foo(a) zed\n", "foo(a)\nzed p q r\n"),
            ["-foo(a)[- zed-]\n", "+foo(a)\n", "+{+zed p q r\n+}"]
        );
    }

    /// One hunk that starts after line 0 and holds two blocks of unequal sizes keeps each block's
    /// own marks; at `-w` the line whose spaces changed becomes context and the blocks stay as they
    /// are.
    #[test]
    fn two_blocks_in_one_hunk_keep_their_own_marks() {
        let left = "l0\nl1\nl2\nl3\nl4\nsp a\nl6\nalpha(one);\nmid\nbeta(x, y);\ngamma(z);\ntail\n";
        let right = "l0\nl1\nl2\nl3\nl4\nsp  a\nl6\n// note\nalpha(two);\nmid\nbeta(x, w);\ntail\n";
        let exact = paired_with(left, right, LineCompareMode::Exact, MAX_PAIRING_WORK);
        let all_space = paired_with(left, right, LineCompareMode::IgnoreAllSpace, MAX_PAIRING_WORK);
        let blocks = [
            "-alpha([-one-]);\n",
            "+{+// note\n+}",
            "+alpha({+two+});\n",
            " mid\n",
            "-beta(x, [-y-]);\n",
            "-[-gamma(z);\n-]",
            "+beta(x, {+w+});\n",
            " tail\n",
        ];
        assert_eq!(
            exact.0,
            [
                &[" l2\n", " l3\n", " l4\n", "-sp a\n", "+sp {+ +}a\n", " l6\n"][..],
                &blocks
            ]
            .concat()
        );
        assert_eq!(all_space.0, [&[" l4\n", " sp  a\n", " l6\n"][..], &blocks].concat());
        assert!(!exact.1 && !all_space.1);
    }

    /// The budget is the file's, and a search pays for its block's one-to-one candidates before its
    /// word diffs. The first block's candidates cost 24 bytes and its word diffs 30 (a 1:1 diff of
    /// 12 bytes, a 1:2 run of 18). The second block runs no word diff (every candidate is pruned),
    /// but its candidates still cost 4. With less than 58 the second block keeps jj-lib's tokens;
    /// with less than 54 the first search runs out, and that block and every later one keep
    /// jj-lib's tokens; with less than 24 the first block is not searched, and the second one still
    /// pairs.
    #[test]
    fn a_spent_budget_leaves_later_blocks_to_jj_lib() {
        let (left, right) = ("a b c\nkeep\nx\n", "a b d\na b e\nkeep\ny\n");
        let jj = both(left, right).0;
        let run = |budget| paired_with(left, right, LineCompareMode::Exact, budget);
        let (full, ran_out) = run(58);
        assert!(!ran_out);
        assert_eq!(
            full,
            [
                "-a b [-c-]\n",
                "+a b {+d+}\n",
                "+{+a b e\n+}",
                " keep\n",
                "-[-x\n-]",
                "+{+y\n+}"
            ]
        );
        assert_eq!(run(57).0[..4], full[..4]);
        assert_eq!(run(57).0[4..], jj[4..]);
        assert_eq!(run(53), (jj.clone(), true));
        let (marked, ran_out) = run(23);
        assert_eq!((&marked[..4], &marked[4..]), (&jj[..4], &full[4..]));
        assert!(ran_out);
    }

    /// A block too big for the budget keeps jj-lib's block-wide tokens; within it the same lines
    /// would be unpaired whole lines.
    #[test]
    fn a_block_over_the_budget_keeps_jj_libs_tokens() {
        // Two-byte lines: the work is `n · 2n + n · 2n`.
        let lines = (MAX_PAIRING_WORK / 4).isqrt() + 1;
        let (jj, kept) = both(&"x\n".repeat(lines), &"y\n".repeat(lines));
        assert_eq!(kept, jj);
        assert_eq!(kept[0], "-[-x-]\n");
        assert_eq!(paired("x\n", "y\n"), ["-[-x\n-]", "+{+y\n+}"]);
    }

    /// Two removed lines joined into one added line pair as a run and keep precise marks.
    #[test]
    fn lines_joined_into_one_keep_precise_marks() {
        assert_eq!(
            paired("    total(first,\n        second);\n", "    total(first, second);\n"),
            [
                "-    total(first,[-\n-]",
                "-[-       -] second);\n",
                "+    total(first, second);\n"
            ]
        );
    }

    /// Exactly half of the tokens kept does not pair; more than half does.
    #[test]
    fn a_group_pairs_only_above_half() {
        assert_eq!(paired("a b\n", "a c\n"), ["-[-a b\n-]", "+{+a c\n+}"]);
        assert_eq!(paired("a b c\n", "a b d\n"), ["-a b [-c-]\n", "+a b {+d+}\n"]);
    }

    /// A line without a partner is one changed token; its neighbour still pairs.
    #[test]
    fn a_line_without_a_partner_is_one_changed_token() {
        assert_eq!(
            paired("keep(1);\n", "// An unrelated note.\nkeep(2);\n"),
            ["-keep([-1-]);\n", "+{+// An unrelated note.\n+}", "+keep({+2+});\n"]
        );
    }

    /// A loosely related line stays out of a run (`foo(a,c)` alone is worth 400: 5 of 6 tokens
    /// kept, 12 in all; with `bar(x)` 200: 5 kept of 16); a split line pairs with its whole run.
    #[test]
    fn a_run_is_taken_only_when_it_is_worth_more() {
        let tokens = ["foo(a,b)\n", "foo(a,c)\n", "bar(x)\n"].map(|line| token_count(line.as_bytes()));
        assert_eq!(tokens, [6, 6, 4]);
        assert_eq!(kept_tokens(b"foo(a,b)\n", b"foo(a,c)\n"), 5);
        assert_eq!(kept_tokens(b"foo(a,b)\n", b"foo(a,c)\nbar(x)\n"), 5);
        assert_eq!(
            paired("foo(a,b)\n", "foo(a,c)\nbar(x)\n"),
            ["-foo(a,[-b-])\n", "+foo(a,{+c+})\n", "+{+bar(x)\n+}"]
        );
        assert_eq!(
            paired("call(first, second)\n", "call(\n  first,\n  second)\n"),
            [
                "-call(first, second)\n",
                "+call({+\n+}",
                "+{+  +}first,{+\n+}",
                "+{+ +} second)\n"
            ]
        );
    }
}
