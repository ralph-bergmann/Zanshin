// SPDX-License-Identifier: MIT

//! `hunks.rs` — a diff between two trees as `jj diff --git`'s line-level hunks (Story 5.1), with
//! the builtin diff editor's sections each hunk shows.
//!
//! - **Files** are the paths of `from.diff_stream(to)` in jj-lib's order, each side materialized
//!   with its tree's conflict labels and read as `show_git_diff` reads it (`git_diff_part`,
//!   `cli/src/diff_util.rs:1876-1972` @ v0.46.0): a conflict as its markers
//!   (`ui.conflict-marker-style`), a symlink as its target. A side that cannot be read is an
//!   error, as in the CLI.
//! - **Hunks** are jj-lib's `unified_diff_hunks` over the two texts, with the caller's context
//!   (default `diff.git.context`) and whitespace mode — the CLI's `show_unified_diff_hunks`
//!   (`diff_util.rs:1767-1847`). Equal texts (a mode-only change) and differing binary content
//!   (a NUL byte in either side's first 8000 bytes) get none.
//! - **Source symbols** are the CLI's ([`crate::source_symbol`]): the new side's, unless the hunk
//!   adds no line, cut at 80 bytes.
//! - **Sections** are [`crate::select_tree::sections`] over the same texts. They are the keys
//!   [`crate::Repo::select_tree`] accepts when the diff is the one it makes (the revision's parent
//!   tree, or `from`'s tree, against the revision's own), with the labels `show` reports, under
//!   the same effective `ui.conflict-marker-style` (each call resolves config for its own CLI
//!   command, so a `--when.commands` scope can differ). A file has them when both sides are
//!   file-like (a regular file or a file conflict) and text; a hunk lists those one of its
//!   removed or added lines falls in.

use std::ops::Range;
use std::sync::Arc;

use futures::StreamExt as _;
use jj_lib::config::StackedConfig;
use jj_lib::conflicts::{materialize_tree_value, ConflictMaterializeOptions, MaterializedTreeValue};
use jj_lib::diff_presentation::unified::{git_diff_part, unified_diff_hunks, DiffLineType, UnifiedDiffHunk};
use jj_lib::diff_presentation::{DiffTokenType, LineCompareMode};
use jj_lib::matchers::EverythingMatcher;
use jj_lib::merge::Diff;
use jj_lib::merged_tree::MergedTree;
use jj_lib::repo_path::RepoPath;
use jj_lib::store::Store;

use crate::mutate::{be, cfg, MutateError};
use crate::op_support::SelectedTree;
use crate::select_tree::{is_text, sections, HunkKey, Piece, SelectedTreeId};
use crate::source_symbol::{trim_source_symbol, SourceLanguage, SourceSymbolScanner};

/// [`crate::Repo::compute_hunks`]'s arguments (Story 5.1).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HunksOptions {
    /// The diff's left tree — e.g. [`crate::ShowEntry::parent_tree_ids`] with
    /// [`crate::ShowEntry::parent_tree_labels`].
    pub from: SelectedTreeId,
    /// The diff's right tree — e.g. [`crate::ShowEntry::tree_ids`] with
    /// [`crate::ShowEntry::tree_labels`].
    pub to: SelectedTreeId,
    /// Context lines around each change (`--context`); `None` is the effective
    /// `diff.git.context` (3 in jj's defaults).
    pub context: Option<usize>,
    /// How lines are compared.
    pub whitespace: Whitespace,
}

/// How [`crate::Repo::compute_hunks`] compares lines (Story 5.1).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Whitespace {
    /// Literally.
    #[default]
    Exact,
    /// Ignoring every whitespace occurrence (`-w`, `--ignore-all-space`).
    IgnoreAllSpace,
    /// Ignoring changes in the amount of whitespace (`-b`, `--ignore-space-change`).
    IgnoreSpaceChange,
}

/// One changed path of a diff (Story 5.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileDiff {
    /// The repo-relative path, in jj's internal `/`-separated form.
    pub path: String,
    /// The contents differ and either side's is binary (a NUL byte in its first 8000 bytes): no
    /// hunks. A mode-only change of a binary file is not binary, as in the CLI.
    pub binary: bool,
    /// Both sides are file-like (a regular file or a file conflict) and differ in the executable
    /// bit — the builtin diff editor's mode toggle ([`crate::FileChoice::ModeAndHunks`]).
    pub mode_change: bool,
    /// The file's sections — every key [`crate::Repo::select_tree`] accepts for it (see the
    /// module doc for when); empty when it can only be selected whole. They are cut exactly, so at
    /// `-w` / `-b` a file can keep sections no hunk shows.
    pub sections: Vec<HunkKey>,
    /// The hunks, in file order; none for equal texts and binary content.
    pub hunks: Vec<Hunk>,
}

/// One hunk of a [`FileDiff`] — what `jj diff --git` prints under one `@@` header (Story 5.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hunk {
    /// Its lines on the left side, 0-based (`left_line_range`).
    pub before_range: Range<u32>,
    /// Its lines on the right side, 0-based (`right_line_range`).
    pub after_range: Range<u32>,
    /// The source symbol of its header, cut at 80 bytes; `None` when the file's language has no
    /// pattern or no symbol precedes the hunk.
    pub symbol: Option<String>,
    /// The file's sections one of its removed or added lines falls in. At `-w` / `-b` this can
    /// be a whole section the hunk shows only part of, or empty (a hunk whose lines lie in no
    /// exact section).
    pub sections: Vec<HunkKey>,
    /// Its [`HunkLine::Removed`] lines.
    pub removed: u32,
    /// Its [`HunkLine::Added`] lines.
    pub added: u32,
    /// Its lines in order.
    pub lines: Vec<HunkLine>,
}

/// One line of a [`Hunk`]: its text including `\n` (a last line without one keeps that state),
/// decoded lossily as UTF-8.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HunkLine {
    /// On both sides, as the right side's text (jj-lib's context lines take the new content), which
    /// at `-w` / `-b` can differ from the left side's.
    Context(String),
    /// On the left side only.
    Removed(String),
    /// On the right side only.
    Added(String),
}

/// `jj diff --git` between two trees as data (Story 5.1) — see [`crate::Repo::compute_hunks`].
///
/// # Errors
///
/// See [`crate::Repo::compute_hunks`].
pub(crate) fn compute_hunks(
    store: &Arc<Store>,
    config: &StackedConfig,
    options: &HunksOptions,
) -> Result<Vec<FileDiff>, MutateError> {
    let config_context = crate::config::diff_git_context(config).map_err(cfg)?;
    let marker_style = crate::config::conflict_marker_style(config).map_err(cfg)?;
    let from = SelectedTree::from_tree_id(store, &options.from)?;
    let to = SelectedTree::from_tree_id(store, &options.to)?;
    let reader = DiffReader {
        store,
        materialize: ConflictMaterializeOptions {
            marker_style,
            marker_len: None,
            merge: store.merge_options().clone(),
        },
        context: options.context.unwrap_or(config_context),
        mode: match options.whitespace {
            Whitespace::Exact => LineCompareMode::Exact,
            Whitespace::IgnoreAllSpace => LineCompareMode::IgnoreAllSpace,
            Whitespace::IgnoreSpaceChange => LineCompareMode::IgnoreSpaceChange,
        },
    };
    pollster::block_on(reader.files(Diff::new(from.tree(), to.tree())))
}

/// What one call reads every file with.
struct DiffReader<'a> {
    store: &'a Store,
    materialize: ConflictMaterializeOptions,
    context: usize,
    mode: LineCompareMode,
}

impl DiffReader<'_> {
    async fn files(&self, trees: Diff<&MergedTree>) -> Result<Vec<FileDiff>, MutateError> {
        let labels = trees.map(MergedTree::labels);
        let mut stream = trees.before.diff_stream(trees.after, &EverythingMatcher);
        let mut files = Vec::new();
        while let Some(entry) = stream.next().await {
            let values = entry.values.map_err(be)?;
            let sides = Diff::new(
                materialize_tree_value(self.store, &entry.path, values.before, labels.before)
                    .await
                    .map_err(be)?,
                materialize_tree_value(self.store, &entry.path, values.after, labels.after)
                    .await
                    .map_err(be)?,
            );
            files.push(self.file(&entry.path, sides).await?);
        }
        Ok(files)
    }

    async fn file(&self, path: &RepoPath, sides: Diff<MaterializedTreeValue>) -> Result<FileDiff, MutateError> {
        let executable = sides.as_ref().map(file_like_executable);
        let left = git_diff_part(path, sides.before, &self.materialize).await.map_err(be)?;
        let right = git_diff_part(path, sides.after, &self.materialize).await.map_err(be)?;
        let texts = Diff::new(&left.content.contents[..], &right.content.contents[..]);
        let file_like = executable.before.is_some() && executable.after.is_some();
        let file_sections = if file_like && is_text(texts.before) && is_text(texts.after) {
            section_keys(texts)
        } else {
            Vec::new()
        };
        // The CLI skips equal contents before its binary check (`show_git_diff`).
        let binary = texts.before != texts.after && (left.content.is_binary || right.content.is_binary);
        let hunks = if binary || texts.before == texts.after {
            Vec::new()
        } else {
            let language = path
                .components()
                .next_back()
                .and_then(|name| SourceLanguage::from_file_name(name.as_internal_str()));
            hunks_of(texts, language, self.context, self.mode, &file_sections)
        };
        Ok(FileDiff {
            path: path.as_internal_file_string().to_owned(),
            binary,
            mode_change: file_like && executable.before != executable.after,
            sections: file_sections,
            hunks,
        })
    }
}

/// A side's executable bit when it is file-like, as the builtin diff editor reads it
/// ([`crate::file::materialize_file_like`]) — `None` otherwise.
fn file_like_executable(value: &MaterializedTreeValue) -> Option<bool> {
    match value {
        MaterializedTreeValue::File(file) => Some(file.executable),
        MaterializedTreeValue::FileConflict(file) => Some(file.executable == Some(true)),
        _ => None,
    }
}

/// The keys of [`sections`] over `texts`.
fn section_keys(texts: Diff<&[u8]>) -> Vec<HunkKey> {
    sections(texts.before, texts.after)
        .into_iter()
        .filter_map(|piece| match piece {
            Piece::Changed(section) => Some(section.key),
            Piece::Same(_) => None,
        })
        .collect()
}

/// `show_unified_diff_hunks` (`cli/src/diff_util.rs:1767-1847` @ v0.46.0) as data, each hunk
/// listing the `file_sections` it shows.
fn hunks_of(
    texts: Diff<&[u8]>,
    language: Option<SourceLanguage>,
    context: usize,
    mode: LineCompareMode,
    file_sections: &[HunkKey],
) -> Vec<Hunk> {
    let scanners = texts.map(|text| language.map(|language| SourceSymbolScanner::new(language, text)));
    unified_diff_hunks(texts.map(Into::into), context, mode)
        .iter()
        .map(|hunk| {
            let lines: Vec<HunkLine> = hunk
                .lines
                .iter()
                .map(|(kind, tokens)| hunk_line(*kind, tokens))
                .collect();
            let removed = count(&lines, |line| matches!(line, HunkLine::Removed(_)));
            let added = count(&lines, |line| matches!(line, HunkLine::Added(_)));
            Hunk {
                before_range: to_u32(hunk.left_line_range.start)..to_u32(hunk.left_line_range.end),
                after_range: to_u32(hunk.right_line_range.start)..to_u32(hunk.right_line_range.end),
                symbol: symbol(scanners.as_ref().map(Option::as_ref), hunk, added > 0),
                sections: hunk_sections(hunk, &lines, file_sections),
                removed,
                added,
                lines,
            }
        })
        .collect()
}

/// One hunk line from its tokens.
fn hunk_line(kind: DiffLineType, tokens: &[(DiffTokenType, &[u8])]) -> HunkLine {
    let bytes: Vec<u8> = tokens.iter().flat_map(|(_, token)| token.iter().copied()).collect();
    let text = String::from_utf8_lossy(&bytes).into_owned();
    match kind {
        DiffLineType::Context => HunkLine::Context(text),
        DiffLineType::Removed => HunkLine::Removed(text),
        DiffLineType::Added => HunkLine::Added(text),
    }
}

/// The CLI's symbol choice: the new side, unless the hunk adds no line (context lines make the
/// new range nonempty, so the line kinds decide), the other side as the fallback.
fn symbol(
    scanners: Diff<Option<&SourceSymbolScanner<'_>>>,
    hunk: &UnifiedDiffHunk<'_>,
    has_added_lines: bool,
) -> Option<String> {
    let before = || scanners.before.and_then(|scanner| scanner.find(&hunk.left_line_range));
    let after = || scanners.after.and_then(|scanner| scanner.find(&hunk.right_line_range));
    let found = if has_added_lines {
        after().or_else(before)
    } else {
        before().or_else(after)
    };
    found.map(|symbol| String::from_utf8_lossy(trim_source_symbol(symbol)).into_owned())
}

/// The `file_sections` one of the hunk's removed lines (on the left) or added lines (on the
/// right) falls in — at `-w` / `-b` possibly a section the hunk shows only part of.
fn hunk_sections(hunk: &UnifiedDiffHunk<'_>, lines: &[HunkLine], file_sections: &[HunkKey]) -> Vec<HunkKey> {
    let (mut left, mut right) = (to_u32(hunk.left_line_range.start), to_u32(hunk.right_line_range.start));
    let (mut removed, mut added) = (Vec::new(), Vec::new());
    for line in lines {
        match line {
            HunkLine::Context(_) => {
                left = left.saturating_add(1);
                right = right.saturating_add(1);
            }
            HunkLine::Removed(_) => {
                removed.push(left);
                left = left.saturating_add(1);
            }
            HunkLine::Added(_) => {
                added.push(right);
                right = right.saturating_add(1);
            }
        }
    }
    let within = |start: u32, count: u32, line: u32| (start..start.saturating_add(count)).contains(&line);
    file_sections
        .iter()
        .filter(|key| {
            removed.iter().any(|&line| within(key.old_start, key.old_count, line))
                || added.iter().any(|&line| within(key.new_start, key.new_count, line))
        })
        .copied()
        .collect()
}

fn count(lines: &[HunkLine], kind: impl Fn(&HunkLine) -> bool) -> u32 {
    to_u32(lines.iter().filter(|line| kind(line)).count())
}

fn to_u32(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use jj_lib::diff_presentation::LineCompareMode;
    use jj_lib::merge::Diff;

    use super::{hunks_of, section_keys, Hunk, HunkKey, HunkLine};
    use crate::source_symbol::SourceLanguage;

    fn key(old_start: u32, old_count: u32, new_start: u32, new_count: u32) -> HunkKey {
        HunkKey {
            old_start,
            old_count,
            new_start,
            new_count,
        }
    }

    fn diff(left: &str, right: &str, language: Option<SourceLanguage>, context: usize) -> Vec<Hunk> {
        diff_mode(left, right, language, context, LineCompareMode::Exact)
    }

    fn diff_mode(
        left: &str,
        right: &str,
        language: Option<SourceLanguage>,
        context: usize,
        mode: LineCompareMode,
    ) -> Vec<Hunk> {
        let texts = Diff::new(left.as_bytes(), right.as_bytes());
        hunks_of(texts, language, context, mode, &section_keys(texts))
    }

    const LEFT: &str = "a\nb\nc\nd\ne\n";
    const RIGHT: &str = "A\nb\nC\nd\nE\n";

    /// Context 3 joins the three sections into one hunk; its counts are its lines.
    #[test]
    fn context_three_joins_three_sections_into_one_hunk() {
        let hunks = diff(LEFT, RIGHT, None, 3);
        assert_eq!(hunks.len(), 1);
        let hunk = &hunks[0];
        assert_eq!((hunk.before_range.clone(), hunk.after_range.clone()), (0..5, 0..5));
        assert_eq!(hunk.sections, [key(0, 1, 0, 1), key(2, 1, 2, 1), key(4, 1, 4, 1)]);
        assert_eq!((hunk.removed, hunk.added), (3, 3));
        assert_eq!(hunk.lines.len(), 8);
        assert_eq!(hunk.lines[0], HunkLine::Removed("a\n".to_owned()));
        assert_eq!(hunk.lines[1], HunkLine::Added("A\n".to_owned()));
        assert_eq!(hunk.lines[2], HunkLine::Context("b\n".to_owned()));
        assert_eq!(hunk.symbol, None);
    }

    /// Context 0 gives one hunk per section.
    #[test]
    fn context_zero_gives_one_hunk_per_section() {
        let hunks = diff(LEFT, RIGHT, None, 0);
        let sections: Vec<_> = hunks.iter().map(|hunk| hunk.sections.clone()).collect();
        assert_eq!(sections, [[key(0, 1, 0, 1)], [key(2, 1, 2, 1)], [key(4, 1, 4, 1)]]);
        assert_eq!(hunks[1].before_range, 2..3);
        assert_eq!(hunks[1].after_range, 2..3);
    }

    /// A last line without `\n` keeps that state.
    #[test]
    fn a_last_line_without_a_newline_keeps_it() {
        let hunks = diff("a\nb", "a\nc", None, 3);
        let lines = &hunks[0].lines;
        assert_eq!(lines[0], HunkLine::Context("a\n".to_owned()));
        assert_eq!(lines[1], HunkLine::Removed("b".to_owned()));
        assert_eq!(lines[2], HunkLine::Added("c".to_owned()));
        assert_eq!(hunks[0].sections, [key(1, 1, 1, 1)]);
    }

    /// An insertion lists its section through its added lines, a deletion through its removed.
    #[test]
    fn insertions_and_deletions_list_their_sections() {
        let inserted = diff("a\nb\n", "a\nx\nb\n", None, 0);
        assert_eq!(inserted[0].sections, [key(1, 0, 1, 1)]);
        assert_eq!((inserted[0].removed, inserted[0].added), (0, 1));
        let deleted = diff("a\nx\nb\n", "a\nb\n", None, 0);
        assert_eq!(deleted[0].sections, [key(1, 1, 1, 0)]);
        assert_eq!((deleted[0].removed, deleted[0].added), (1, 0));
    }

    /// The new side's symbol, unless the hunk adds nothing; a symbol over 80 bytes is cut.
    #[test]
    fn the_symbol_prefers_the_new_side_unless_nothing_is_added() {
        let rust = Some(SourceLanguage::Rust);
        let changed = diff("fn main() {\n    a();\n}\n", "fn main() {\n    b();\n}\n", rust, 0);
        assert_eq!(changed[0].symbol.as_deref(), Some("fn main() {"));
        // Added lines: the new side's preceding symbol.
        let renamed = diff(
            "fn old() {\n    a();\n}\n",
            "fn new() {\n    a();\n    b();\n}\n",
            rust,
            0,
        );
        assert_eq!(
            renamed.last().and_then(|hunk| hunk.symbol.as_deref()),
            Some("fn new() {")
        );
        // Deletion only: the old side's.
        let deleted = diff(
            "fn old() {\n    a();\n    b();\n}\n",
            "fn new() {\n    a();\n}\n",
            rust,
            0,
        );
        assert_eq!(
            deleted.last().and_then(|hunk| hunk.symbol.as_deref()),
            Some("fn old() {")
        );
        // No symbol on the preferred side: the other side's.
        let fallback = diff("fn f() {\n}\nx\n", "y\n}\nx\n", rust, 0);
        assert_eq!(fallback[0].symbol.as_deref(), Some("fn f() {"));
        let long = format!("fn {}() {{\n    a();\n", "x".repeat(100));
        let cut = diff(&long, &long.replace("a()", "b()"), rust, 0);
        assert_eq!(cut[0].symbol.as_ref().map(String::len), Some(80));
        assert_eq!(diff("fn main() {\n a\n", "fn main() {\n b\n", None, 0)[0].symbol, None);
    }

    /// At `-w` a whitespace-only change has no hunk, though the file keeps its section.
    #[test]
    fn ignoring_whitespace_drops_a_whitespace_only_hunk() {
        let texts = Diff::new(&b"a b\nc\n"[..], &b"a  b\nc\n"[..]);
        assert_eq!(section_keys(texts), [key(0, 1, 0, 1)]);
        assert!(diff_mode("a b\nc\n", "a  b\nc\n", None, 3, LineCompareMode::IgnoreAllSpace).is_empty());
        assert!(diff_mode("a b\nc\n", "a  b\nc\n", None, 3, LineCompareMode::IgnoreSpaceChange).is_empty());
        assert_eq!(
            diff_mode("a b\n", "ab\n", None, 3, LineCompareMode::IgnoreSpaceChange).len(),
            1
        );
    }

    /// A hunk spanning 1000 lines has 1000 entries.
    #[test]
    fn an_added_thousand_line_text_is_one_hunk_of_a_thousand_lines() {
        let text = "x\n".repeat(1000);
        let hunks = diff("", &text, None, 3);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].after_range, 0..1000);
        assert_eq!(hunks[0].added, 1000);
        assert_eq!(hunks[0].lines.len(), 1000);
        assert!(hunks[0].lines.iter().all(|line| matches!(line, HunkLine::Added(_))));
    }
}
