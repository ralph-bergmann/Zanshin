// SPDX-License-Identifier: MIT

//! `hunks.rs` — a diff between two trees as `jj diff`'s default output, the color-words format
//! (Story 5.10), with the builtin diff editor's sections each hunk shows.
//!
//! - **Files** are the paths of `from.diff_stream(to)` in jj-lib's order, each side materialized
//!   with its tree's conflict labels and read as jj-lib's `git_diff_part` reads it: a conflict as
//!   its markers (`ui.conflict-marker-style`), a symlink as its target. A side that cannot be
//!   read is an error. Equal texts (a mode-only change) and differing binary content (a NUL byte
//!   in either side's first 8000 bytes) get no hunks.
//! - **Lines** are the CLI's color-words walk (`show_color_words_diff_hunks` and below,
//!   `cli/src/diff_util.rs:822-1377` @ v0.47.0) as data: jj-lib's line diff (`diff_by_line`,
//!   with the whitespace mode), the context rule of `diff.color-words.context` (or the caller's
//!   `--context`), and per changed block jj-lib's word diff, inlined (`DiffLineIterator`) when no
//!   group of changed lines alternates between removed and added words more often than
//!   `diff.color-words.max-inline-alternation`, else split into the removed lines then the added
//!   lines (`unzip_diff_hunks_to_lines`). Zanshin draws colour, so it always takes the CLI's
//!   coloured path. A conflicted side follows `diff.color-words.conflict`: `materialize` diffs
//!   the marker text, `pair` diffs each pair of conflict terms under header lines.
//! - **Hunks** are the runs of lines between two skipped ranges (the CLI's `...` lines). A hunk
//!   after a skipped range carries that range's source-symbol line ([`crate::source_symbol`]).
//! - **Sections** are [`crate::select_tree::sections`] over the same texts. They are the keys
//!   [`crate::Repo::select_tree`] accepts when the diff is the one it makes (the revision's parent
//!   tree, or `from`'s tree, against the revision's own), with the labels `show` reports, under
//!   the same effective `ui.conflict-marker-style` (each call resolves config for its own CLI
//!   command, so a `--when.commands` scope can differ). A file has them when both sides are
//!   file-like (a regular file or a file conflict) and text; a hunk lists those one of its
//!   changed lines falls in.
//! - **Revisions** (Story 5.6, [`crate::Repo::diff`]): `jj diff -r` (a connected set diffed as
//!   one: its roots' merged parents → its merged heads) or `--from` / `--to`, each side one
//!   revision (`resolve_single_rev`), read through `diff_stream_with_copies` with the CLI's copy records —
//!   the left side at the copy source, the right at the target; a copy or rename has no
//!   sections. Each file carries its kind, its counts (the hunks' sums) and a fingerprint of its
//!   changed lines; summary mode drops only the hunks. [`crate::Repo::compute_hunks`] uses no
//!   copy records.

use std::iter;
use std::ops::Range;
use std::path::PathBuf;
use std::sync::Arc;

use futures::{StreamExt as _, TryStreamExt as _};
use jj_lib::backend::MergedTreeValue;
use jj_lib::commit::Commit;
use jj_lib::config::StackedConfig;
use jj_lib::conflict_labels::ConflictLabels;
use jj_lib::conflicts::{materialize_tree_value, ConflictMaterializeOptions, MaterializedTreeValue};
use jj_lib::content_hash::blake2b_hash;
use jj_lib::copies::{CopiesTreeDiffEntryPath, CopyOperation, CopyRecords};
use jj_lib::diff::{ContentDiff, DiffHunk, DiffHunkKind};
use jj_lib::diff_presentation::unified::git_diff_part;
use jj_lib::diff_presentation::{diff_by_line, unzip_diff_hunks_to_lines, DiffTokenType, LineCompareMode};
use jj_lib::files::{self, ConflictDiffHunk, DiffLineHunkSide, DiffLineIterator, DiffLineNumber, MergeOptions};
use jj_lib::hex_util::encode_hex;
use jj_lib::id_prefix::IdPrefixContext;
use jj_lib::matchers::{EverythingMatcher, Matcher};
use jj_lib::merge::{Diff, Merge};
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::revset::UserRevsetExpression;
use jj_lib::rewrite::merge_commit_trees;
use jj_lib::store::Store;
use jj_lib::workspace::Workspace;

use crate::config::{ColorWordsOptions, ConflictDiffMethod};
use crate::mutate::{be, cfg, res, MutateError};
use crate::op_support::SelectedTree;
use crate::select_tree::{is_text, sections, HunkKey, Piece, SelectedTreeId};
use crate::source_symbol::{source_symbol_from_line, SourceLanguage};
use crate::template::Templates;
use crate::warning::Warnings;
use crate::{ChangeKind, CommitId, OperationId};

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
    /// `diff.color-words.context` (3 in jj's defaults).
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
    /// The repo-relative path, in jj's internal `/`-separated form — a copy's or rename's TARGET.
    pub path: String,
    /// How the path changed (Story 5.6), classified as `jj diff --summary` does: a copy record's
    /// source first ([`ChangeKind::Renamed`] / [`ChangeKind::Copied`] with the source path), then
    /// presence. [`crate::Repo::compute_hunks`] uses no copy records, so its kinds are presence
    /// only.
    pub kind: ChangeKind,
    /// The contents differ and either side's is binary (a NUL byte in its first 8000 bytes): no
    /// hunks. A mode-only change of a binary file is not binary, as in the CLI.
    pub binary: bool,
    /// Both sides are file-like (a regular file or a file conflict) and differ in the executable
    /// bit — the builtin diff editor's mode toggle ([`crate::FileChoice::ModeAndHunks`]).
    pub mode_change: bool,
    /// The file's sections — every key [`crate::Repo::select_tree`] accepts for it (see the
    /// module doc for when); empty when it can only be selected whole — always for a copy or
    /// rename, which the builtin diff editor (no copy records) cannot select by section. They are
    /// cut exactly, so at `-w` / `-b` a file can keep sections no hunk shows.
    pub sections: Vec<HunkKey>,
    /// The hunks, in file order; none for equal texts and binary content, and none in
    /// [`DiffOptions::summary`] mode.
    pub hunks: Vec<Hunk>,
    /// The sum of its hunks' [`Hunk::removed`] (Story 5.6); 0 for binary and mode-only changes.
    pub removed: u32,
    /// The sum of its hunks' [`Hunk::added`] (Story 5.6); 0 for binary and mode-only changes.
    pub added: u32,
    /// A fingerprint of what changed (Story 5.6), stable across processes: the lowercase hex of
    /// jj-lib's `blake2b_hash` over the changed lines of jj-lib's line diff in order (per changed
    /// block its left lines prefixed `-`, then its right lines prefixed `+`; no line numbers, no
    /// context), then both sides' contents for a binary change and a
    /// marker for a mode change. Equal changes at shifted line numbers share it. It depends on the
    /// call's `whitespace` mode and the effective `ui.conflict-marker-style`, and covers content
    /// only — no path, no kind — so every content-less change (a pure rename, an empty file
    /// added) shares one value; a Viewed key combines it with the path.
    pub fingerprint: String,
}

/// [`crate::Repo::diff`]'s arguments (Story 5.6) — `jj diff`'s.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DiffOptions {
    /// Which revisions to diff (`-r` or `--from` / `--to`).
    pub revisions: DiffRevisions,
    /// Repo-relative path PREFIXES to restrict the diff to (the CLI's `[FILESETS]`, as plain
    /// prefixes); empty = every path, `""` = the root.
    pub paths: Vec<String>,
    /// Context lines around each change (`--context`); `None` is the effective
    /// `diff.color-words.context` (3 in jj's defaults).
    pub context: Option<usize>,
    /// How lines are compared.
    pub whitespace: Whitespace,
    /// Leave every file's [`FileDiff::hunks`] empty — kinds, flags, sections, counts and
    /// fingerprints are those of the full diff.
    pub summary: bool,
}

/// The two sides of a [`crate::Repo::diff`] (Story 5.6).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffRevisions {
    /// `-r`: revset text (`None` = `@`) whose set is diffed as one, as the CLI does — the merged
    /// parents of its roots against its merged heads; a set with gaps is refused, an empty one
    /// diffs empty trees. A change id, a commit id (hidden commits included), `@-`, a bookmark,
    /// `a::b`, `a | b`, …; its parse diagnostics land on the call's warnings. Several CLI `-r`
    /// arguments are one text, each argument parenthesized and joined with `|`: `(a) | (b)`.
    Revision(Option<String>),
    /// `--from` / `--to`: `from`'s tree against `to`'s; an absent side is `@`. Each side is
    /// revset text resolving to exactly one commit (`resolve_single_rev`), as in the CLI.
    FromTo {
        /// The left side (`None` = `@`).
        from: Option<String>,
        /// The right side (`None` = `@`).
        to: Option<String>,
    },
    /// `jj interdiff --from` / `--to` (Story 10.29): `from` rebased onto `to`'s parents in memory
    /// (`rebase_to_dest_parent`, nothing written) against `to`'s tree, without copy records — the
    /// per-commit diff `jj op show --patch` prints for a rewritten commit. Sides resolve as in
    /// [`DiffRevisions::FromTo`]; at least one must be present.
    Interdiff {
        /// The left side (`None` = `@`).
        from: Option<String>,
        /// The right side (`None` = `@`).
        to: Option<String>,
    },
    /// `show_inter_diff` with no predecessors (Story 10.29 closing run): the revision's parent
    /// tree against its tree, without copy records — the per-commit diff `jj op show --patch`
    /// prints for a created commit. The text resolves to exactly one commit
    /// (`resolve_single_rev`, hidden commit ids included).
    Created(String),
}

impl Default for DiffRevisions {
    /// `jj diff` without revision arguments: `-r @`.
    fn default() -> Self {
        Self::Revision(None)
    }
}

/// A [`crate::Repo::diff`] result, pinned to what it was computed at (Story 5.6).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionDiff {
    /// The operation the diff was read at (after the pre-verb snapshot), full hex.
    pub operation_id: OperationId,
    /// The right side's commits, full hex: the set's heads in revset order
    /// ([`DiffRevisions::Revision`]; `[@]` without text, empty for an empty set) or `[to]`
    /// ([`DiffRevisions::FromTo`], [`DiffRevisions::Interdiff`], [`DiffRevisions::Created`]).
    pub commit_ids: Vec<CommitId>,
    /// `from` for [`DiffRevisions::FromTo`] and [`DiffRevisions::Interdiff`]; `None` for
    /// [`DiffRevisions::Revision`] and [`DiffRevisions::Created`].
    pub from_commit_id: Option<CommitId>,
    /// The changed paths in jj-lib's order.
    pub files: Vec<FileDiff>,
    /// `show_inter_diff`'s description block (Story 10.29 closing run), for
    /// [`DiffRevisions::Interdiff`] (`from`'s description) and [`DiffRevisions::Created`] (`""`)
    /// against the commit's: a pseudo-file at `JJ-COMMIT-DESCRIPTION`, [`ChangeKind::Modified`],
    /// hunks under the call's `context` / `whitespace`, no sections, the generic language's source
    /// symbols (`show_diff_bytes`). `paths`
    /// never filters it and [`DiffOptions::summary`] keeps its hunks (it is not a file). `None`
    /// when the descriptions are equal (`show_diff_bytes` skips unchanged contents), and always
    /// for [`DiffRevisions::Revision`] / [`DiffRevisions::FromTo`] (`jj diff` has no such block).
    pub description: Option<FileDiff>,
}

/// The CLI's `DUMMY_DESCRIPTION_PATH` (`show_inter_diff`, `cli/src/diff_util.rs` @ v0.46.0): the
/// path of [`RevisionDiff::description`].
const DESCRIPTION_PATH: &str = "JJ-COMMIT-DESCRIPTION";

/// One hunk of a [`FileDiff`] — the color-words lines between two skipped ranges (Story 5.10).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hunk {
    /// Its lines on the left side, 0-based: from the left line counter at its first line to past
    /// its largest left number.
    pub before_range: Range<u32>,
    /// Its lines on the right side, 0-based, counted like `before_range`.
    pub after_range: Range<u32>,
    /// The source-symbol line of the skipped range before it, as the CLI prints it after
    /// `    ...    ` (the raw line without its line break); `None` for a first hunk without a
    /// skipped range before it and for a plain `...`.
    pub symbol: Option<String>,
    /// The file's sections one of its changed lines falls in (a left number in a section's old
    /// range or a right number in its new range). At `-w` / `-b` this can be a whole section the
    /// hunk shows only part of, or empty (a hunk whose lines lie in no exact section). Always
    /// empty under `diff.color-words.conflict = "pair"` on a conflicted side: its numbers count
    /// conflict-term lines, not the materialized text the file's sections cut.
    pub sections: Vec<HunkKey>,
    /// The number of distinct left numbers on its changed lines (every kind but
    /// [`HunkLineKind::Context`] and [`HunkLineKind::ConflictHeader`]): one old line spread over
    /// several inlined lines counts once.
    pub removed: u32,
    /// The number of distinct right numbers on its changed lines, counted like `removed`.
    pub added: u32,
    /// Its lines in order.
    pub lines: Vec<HunkLine>,
}

/// A run of a [`HunkLine`]'s text with one kind: the CLI's colour labels as data.
///
/// A token on both sides is [`SegmentKind::Equal`], a left-side token [`SegmentKind::Removed`], a
/// right-side token [`SegmentKind::Added`] (swapped under a `-------` conflict term). Words are
/// jj-lib's (`ContentDiff::by_word`): runs of `A-Z a-z 0-9 _` and non-ASCII bytes; every other
/// byte is a token of its own. A line's segments concatenate to its text, none is empty, and
/// adjacent segments differ in kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Segment {
    /// The run's text.
    pub text: String,
    /// Whether the run changed, and on which side.
    pub kind: SegmentKind,
}

/// What a [`Segment`] is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SegmentKind {
    /// Unchanged: on both sides.
    Equal,
    /// Only on the right side.
    Added,
    /// Only on the left side.
    Removed,
}

/// One line of a [`Hunk`], as the CLI prints it in color-words (Story 5.10).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HunkLine {
    /// What the line is.
    pub kind: HunkLineKind,
    /// Its 1-based left line number; `None` when it holds no left content (and on a header line).
    /// One old line spread over several lines repeats its number.
    pub left: Option<u32>,
    /// Its 1-based right line number, like `left`.
    pub right: Option<u32>,
    /// Its text in runs, decoded lossily as UTF-8. The text includes its `\n`; a last line
    /// without one keeps that state.
    pub segments: Vec<Segment>,
}

impl HunkLine {
    /// The line's text: its segments joined.
    #[must_use]
    pub fn text(&self) -> String {
        self.segments.iter().map(|segment| segment.text.as_str()).collect()
    }
}

/// What a [`HunkLine`] is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HunkLineKind {
    /// An unchanged line with both numbers. At `-w` / `-b` a context line whose sides differ in
    /// whitespace keeps this kind with the numbers and segments of the CLI's changed-block path.
    Context,
    /// A line with left content only (right content only under a `-------` conflict term).
    Removed,
    /// A line with right content only (left content only under a `-------` conflict term).
    Added,
    /// An inlined line holding content of both sides.
    Changed,
    /// A conflict header line of `diff.color-words.conflict = "pair"`: `<<<<<<< …`, a
    /// `+++++++` / `-------` term line or `>>>>>>> Conflict ends`. No numbers, one equal segment.
    ConflictHeader,
}

/// `jj diff` between two trees as data (Story 5.1) — see [`crate::Repo::compute_hunks`].
///
/// # Errors
///
/// See [`crate::Repo::compute_hunks`].
pub(crate) fn compute_hunks(
    store: &Arc<Store>,
    config: &StackedConfig,
    options: &HunksOptions,
) -> Result<Vec<FileDiff>, MutateError> {
    let reader = DiffReader::new(store, config, options.context, options.whitespace)?;
    let from = SelectedTree::from_tree_id(store, &options.from)?;
    let to = SelectedTree::from_tree_id(store, &options.to)?;
    pollster::block_on(reader.files(
        Diff::new(from.tree(), to.tree()),
        &EverythingMatcher,
        &CopyRecords::default(),
    ))
}

/// `jj diff` between two revisions as data (Story 5.6) — see [`crate::Repo::diff`].
///
/// # Errors
///
/// See [`crate::Repo::diff`].
pub(crate) fn diff(
    workspace: &Workspace,
    config: &StackedConfig,
    sink: &mut Warnings,
    templates: &Templates<'_>,
    options: &DiffOptions,
) -> Result<RevisionDiff, MutateError> {
    let matcher = crate::mutate::build_matcher(&options.paths)?;
    let store = workspace.repo_loader().store();
    let reader = DiffReader::new(store, config, options.context, options.whitespace)?;
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let repo: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let prefixes = templates.prefixes();
    // `-r` text is a set diffed as one (the range form below); each `--from` / `--to` side
    // resolves to exactly one commit as `resolve_single_rev` (`cli/src/cli_util.rs` @ v0.46.0)
    // does, hidden commit ids included. `None` keeps the `@` path with its no-working-copy
    // refusal. The alias config is read once per call, as the CLI reads it once per command (its
    // warnings once).
    let texts = match &options.revisions {
        DiffRevisions::Revision(revision) => revision.is_some(),
        DiffRevisions::FromTo { from, to } | DiffRevisions::Interdiff { from, to } => from.is_some() || to.is_some(),
        DiffRevisions::Created(_) => true,
    };
    let parse_config = if texts {
        Some(crate::revset::revset_config(config, sink).map_err(cfg)?)
    } else {
        None
    };
    let parse = |text: &str, parse_config: &crate::revset::RevsetConfig, sink: &mut Warnings| {
        crate::revset::parse_diagnosed(
            workspace,
            parse_config,
            (text, crate::revset::IN_REVSET_EXPRESSION),
            sink,
        )
        .map_err(crate::mutate::rev)
    };
    let resolve = |revision: Option<&String>, sink: &mut Warnings| -> Result<Commit, MutateError> {
        let (Some(text), Some(parse_config)) = (revision, parse_config.as_ref()) else {
            return crate::op_support::resolve_or_wc(repo, workspace.workspace_name(), prefixes, None)
                .map_err(|e| res(e, None));
        };
        crate::push::single_commit(&readonly, &parse(text, parse_config, sink)?, text, templates)
    };
    pollster::block_on(async {
        // `cmd_diff` (`cli/src/commands/diff.rs:121-191` @ v0.46.0).
        let mut records = CopyRecords::default();
        // `cmd_interdiff` also checks both parent trees for unmatched paths (`interdiff.rs:99-111`).
        let mut unmatched_trees = Vec::new();
        // `show_inter_diff`'s (from, to) descriptions; `None` for `jj diff`'s forms.
        let mut descriptions: Option<(String, String)> = None;
        let (from_tree, to_tree, commit_ids, from_commit_id) = match (&options.revisions, parse_config.as_ref()) {
            (DiffRevisions::Revision(Some(text)), Some(parse_config)) => {
                let expression = parse(text, parse_config, sink)?;
                let (from_tree, to_tree, heads) =
                    range_trees(&readonly, &expression, prefixes, matcher.as_ref(), &mut records).await?;
                (from_tree, to_tree, heads, None)
            }
            (DiffRevisions::Revision(_), _) => {
                let commit = resolve(None, sink)?;
                let parents = commit.parents().await.map_err(be)?;
                for parent in &parents {
                    add_copy_records(repo.store(), parent, &commit, matcher.as_ref(), &mut records).await?;
                }
                let from_tree = merge_commit_trees(repo, &parents).await.map_err(be)?;
                (from_tree, commit.tree(), vec![commit_id(&commit)], None)
            }
            (DiffRevisions::FromTo { from, to }, _) => {
                let from = resolve(from.as_ref(), sink)?;
                let to = resolve(to.as_ref(), sink)?;
                add_copy_records(repo.store(), &from, &to, matcher.as_ref(), &mut records).await?;
                (from.tree(), to.tree(), vec![commit_id(&to)], Some(commit_id(&from)))
            }
            (DiffRevisions::Interdiff { from, to }, _) => {
                // `cmd_interdiff` → `show_inter_diff` (`cli/src/diff_util.rs` @ v0.46.0): no copy records.
                let from = resolve(from.as_ref(), sink)?;
                let to = resolve(to.as_ref(), sink)?;
                if !options.paths.is_empty() {
                    unmatched_trees.push(from.parent_tree(repo.index()).await.map_err(be)?);
                    unmatched_trees.push(from.tree());
                    unmatched_trees.push(to.parent_tree(repo.index()).await.map_err(be)?);
                }
                let from_tree = jj_lib::rewrite::rebase_to_dest_parent(repo.index(), std::slice::from_ref(&from), &to)
                    .await
                    .map_err(be)?;
                descriptions = Some((from.description().to_owned(), to.description().to_owned()));
                (from_tree, to.tree(), vec![commit_id(&to)], Some(commit_id(&from)))
            }
            (DiffRevisions::Created(text), _) => {
                // `show_change_diff` → `show_inter_diff(&[], commit)`: no predecessors, no copy records.
                let commit = resolve(Some(text), sink)?;
                descriptions = Some((String::new(), commit.description().to_owned()));
                let from_tree = commit.parent_tree(repo.index()).await.map_err(be)?;
                (from_tree, commit.tree(), vec![commit_id(&commit)], None)
            }
        };
        let mut files = reader
            .files(Diff::new(&from_tree, &to_tree), matcher.as_ref(), &records)
            .await?;
        let description = reader.description(descriptions);
        let mut trees: Vec<&MergedTree> = unmatched_trees.iter().collect();
        trees.extend([&from_tree, &to_tree]);
        crate::mutate::warn_unmatched(workspace, sink, &options.paths, &trees)?;
        if options.summary {
            for file in &mut files {
                file.hunks.clear();
            }
        }
        Ok(RevisionDiff {
            operation_id: OperationId(readonly.op_id().hex()),
            commit_ids,
            from_commit_id,
            files,
            description,
        })
    })
}

fn commit_id(commit: &Commit) -> CommitId {
    CommitId(commit.id().hex())
}

/// `-r`'s range form over `expression` ([`range_commits`]): its parents' merged tree, its heads'
/// merged tree and the heads' ids, with the copy records of every (parent, head) pair added to
/// `records`.
async fn range_trees(
    repo: &ReadonlyRepo,
    expression: &Arc<UserRevsetExpression>,
    prefixes: &IdPrefixContext,
    matcher: &dyn Matcher,
    records: &mut CopyRecords,
) -> Result<(MergedTree, MergedTree, Vec<CommitId>), MutateError> {
    let (parents, heads) = range_commits(repo, expression, prefixes).await?;
    for parent in &parents {
        for head in &heads {
            add_copy_records(repo.store(), parent, head, matcher, records).await?;
        }
    }
    let from_tree = merge_commit_trees(repo, &parents).await.map_err(be)?;
    let to_tree = merge_commit_trees(repo, &heads).await.map_err(be)?;
    Ok((from_tree, to_tree, heads.iter().map(commit_id).collect()))
}

/// `cmd_diff`'s range form (`cli/src/commands/diff.rs:149-180` @ v0.46.0) over `expression`: a
/// set with gaps (`roots(T)::heads(T) ~ T`) is refused; otherwise the parents of its roots (in
/// order, duplicates dropped) and its heads, in revset order.
async fn range_commits(
    repo: &ReadonlyRepo,
    expression: &Arc<UserRevsetExpression>,
    prefixes: &IdPrefixContext,
) -> Result<(Vec<Commit>, Vec<Commit>), MutateError> {
    let ids = |expression: &Arc<UserRevsetExpression>| crate::push::collect_ids(repo, expression, prefixes);
    let gaps = ids(&expression.roots().range(&expression.heads()).minus(expression))?;
    if let Some(gap) = gaps.first() {
        return Err(MutateError::invalid_hinted(
            "Cannot diff revsets with gaps in.",
            format!("Revision {} would need to be in the set.", &gap.hex()[..12]),
        ));
    }
    let commits = |expression: &Arc<UserRevsetExpression>| -> Result<Vec<Commit>, MutateError> {
        ids(expression)?
            .iter()
            .map(|id| repo.store().get_commit(id).map_err(be))
            .collect()
    };
    let heads = commits(&expression.heads())?;
    let mut parents: Vec<Commit> = Vec::new();
    for root in commits(&expression.roots())? {
        for parent in root.parents().await.map_err(be)? {
            if !parents.iter().any(|known| known.id() == parent.id()) {
                parents.push(parent);
            }
        }
    }
    Ok((parents, heads))
}

/// The CLI's `get_copy_records` (`cli/src/diff_util.rs:676-689` @ v0.46.0): the records from
/// `root` to `head` whose TARGET `matcher` matches, added to `records`.
async fn add_copy_records(
    store: &Store,
    root: &Commit,
    head: &Commit,
    matcher: &dyn Matcher,
    records: &mut CopyRecords,
) -> Result<(), MutateError> {
    let found: Vec<_> = store
        .get_copy_records(None, root.id(), head.id())
        .map_err(be)?
        .try_filter(|record| std::future::ready(matcher.matches(&record.target)))
        .try_collect()
        .await
        .map_err(be)?;
    records.add_records(found);
    Ok(())
}

/// What one call reads every file with.
struct DiffReader<'a> {
    store: &'a Store,
    materialize: ConflictMaterializeOptions,
    options: WalkOptions,
}

/// The color-words walk's options: the CLI's `ColorWordsDiffOptions` after `merge_args`.
#[derive(Clone, Copy, Debug)]
struct WalkOptions {
    words: ColorWordsOptions,
    mode: LineCompareMode,
}

impl<'a> DiffReader<'a> {
    /// The reader for `store` under the effective `diff.color-words.*` /
    /// `ui.conflict-marker-style`; a caller's `context` overrides the configured one, as
    /// `--context` does.
    fn new(
        store: &'a Store,
        config: &StackedConfig,
        context: Option<usize>,
        whitespace: Whitespace,
    ) -> Result<Self, MutateError> {
        let mut words = crate::config::diff_color_words(config).map_err(cfg)?;
        let marker_style = crate::config::conflict_marker_style(config).map_err(cfg)?;
        if let Some(context) = context {
            words.context = context;
        }
        Ok(Self {
            store,
            materialize: ConflictMaterializeOptions {
                marker_style,
                marker_len: None,
                merge: store.merge_options().clone(),
            },
            options: WalkOptions {
                words,
                mode: line_compare_mode(whitespace),
            },
        })
    }

    /// The per-entry reads over `diff_stream_with_copies` (an empty `records` behaves as the plain
    /// `diff_stream`).
    async fn files(
        &self,
        trees: Diff<&MergedTree>,
        matcher: &dyn Matcher,
        records: &CopyRecords,
    ) -> Result<Vec<FileDiff>, MutateError> {
        let labels = trees.map(MergedTree::labels);
        let mut stream = trees.before.diff_with_copies(trees.after, matcher, records);
        let mut files = Vec::new();
        while let Some(entry) = stream.next().await {
            let values = entry.values.map_err(be)?;
            let kind = change_kind(&entry.path, &values);
            let sides = Diff::new(
                materialize_tree_value(self.store, entry.path.source(), values.before, labels.before)
                    .await
                    .map_err(be)?,
                materialize_tree_value(self.store, entry.path.target(), values.after, labels.after)
                    .await
                    .map_err(be)?,
            );
            files.push(self.file(&entry.path, kind, sides).await?);
        }
        Ok(files)
    }

    /// [`RevisionDiff::description`] over the (from, to) descriptions: `show_diff_bytes`'
    /// color-words form, the generic language, no sections; `None` without descriptions or when
    /// they are equal.
    fn description(&self, descriptions: Option<(String, String)>) -> Option<FileDiff> {
        let (from, to) = descriptions.filter(|(from, to)| from != to)?;
        let texts = Diff::new(from.as_bytes(), to.as_bytes());
        let hunks = hunks_of(
            texts,
            Diff::new(None, None),
            Some(SourceLanguage::Generic),
            self.options,
            &self.materialize.merge,
            &[],
        );
        let (removed, added) = totals(&hunks);
        Some(FileDiff {
            path: DESCRIPTION_PATH.to_owned(),
            kind: ChangeKind::Modified,
            binary: false,
            mode_change: false,
            sections: Vec::new(),
            fingerprint: fingerprint(Some(texts), self.options.mode, None, false),
            hunks,
            removed,
            added,
        })
    }

    async fn file(
        &self,
        path: &CopiesTreeDiffEntryPath,
        kind: ChangeKind,
        sides: Diff<MaterializedTreeValue>,
    ) -> Result<FileDiff, MutateError> {
        let executable = sides.as_ref().map(file_like_executable);
        let conflicts = sides.as_ref().map(conflict_terms);
        let left = git_diff_part(path.source(), sides.before, &self.materialize)
            .await
            .map_err(be)?;
        let right = git_diff_part(path.target(), sides.after, &self.materialize)
            .await
            .map_err(be)?;
        let texts = Diff::new(&left.content.contents[..], &right.content.contents[..]);
        let file_like = executable.before.is_some() && executable.after.is_some();
        // A copy's source→target keys are none the builtin diff editor (no copy records) accepts.
        let file_sections =
            if path.copy_operation().is_none() && file_like && is_text(texts.before) && is_text(texts.after) {
                section_keys(texts)
            } else {
                Vec::new()
            };
        // The CLI skips equal contents before its binary check (`show_git_diff`).
        let binary = texts.before != texts.after && (left.content.is_binary || right.content.is_binary);
        let changed = !binary && texts.before != texts.after;
        let hunks = if changed {
            // `show_color_words_diff`: the target's language, the generic one as the fallback.
            let language = path
                .target()
                .components()
                .next_back()
                .and_then(|name| SourceLanguage::from_file_name(name.as_internal_str()))
                .or(Some(SourceLanguage::Generic));
            hunks_of(
                texts,
                conflicts.as_ref().map(Option::as_ref),
                language,
                self.options,
                &self.materialize.merge,
                &file_sections,
            )
        } else {
            Vec::new()
        };
        let mode_change = file_like && executable.before != executable.after;
        let (removed, added) = totals(&hunks);
        Ok(FileDiff {
            path: path.target().as_internal_file_string().to_owned(),
            kind,
            binary,
            mode_change,
            sections: file_sections,
            fingerprint: fingerprint(
                changed.then_some(texts),
                self.options.mode,
                binary.then_some(texts),
                mode_change,
            ),
            hunks,
            removed,
            added,
        })
    }
}

/// `tree_file_changes`' classification ([`crate::commit_views`]): a copy source first, then
/// presence.
fn change_kind(path: &CopiesTreeDiffEntryPath, values: &Diff<MergedTreeValue>) -> ChangeKind {
    let from = || PathBuf::from(path.source().as_internal_file_string());
    match path.copy_operation() {
        Some(CopyOperation::Rename) => ChangeKind::Renamed { from: from() },
        Some(CopyOperation::Copy) => ChangeKind::Copied { from: from() },
        None if values.before.is_absent() && values.after.is_present() => ChangeKind::Added,
        None if values.before.is_present() && values.after.is_absent() => ChangeKind::Removed,
        None => ChangeKind::Modified,
    }
}

/// The sums of the hunks' removed and added counts.
fn totals(hunks: &[Hunk]) -> (u32, u32) {
    hunks.iter().fold((0, 0), |(removed, added), hunk| {
        (removed.saturating_add(hunk.removed), added.saturating_add(hunk.added))
    })
}

/// [`FileDiff::fingerprint`]: the changed lines of `changed`'s line diff, then a binary change's
/// contents, then a mode change's marker.
fn fingerprint(
    changed: Option<Diff<&[u8]>>,
    mode: LineCompareMode,
    binary: Option<Diff<&[u8]>>,
    mode_change: bool,
) -> String {
    let mut parts: Vec<Vec<u8>> = Vec::new();
    if let Some(texts) = changed {
        let line_diff = diff_by_line(texts.into_array(), &mode);
        for hunk in line_diff.hunks() {
            if let (DiffHunkKind::Different, [left, right]) = (hunk.kind, &hunk.contents[..]) {
                for (tag, side) in [(b"-", left), (b"+", right)] {
                    for line in side.split_inclusive(|byte| *byte == b'\n') {
                        let text = String::from_utf8_lossy(line);
                        parts.push([&tag[..], text.as_bytes()].concat());
                    }
                }
            }
        }
    }
    if let Some(texts) = binary {
        parts.push([&b"<"[..], texts.before].concat());
        parts.push([&b">"[..], texts.after].concat());
    }
    if mode_change {
        parts.push(b"x".to_vec());
    }
    encode_hex(&blake2b_hash(&parts))
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

/// A conflicted side's terms and labels, read by `diff.color-words.conflict = "pair"`.
type ConflictTerms = (Merge<Vec<u8>>, ConflictLabels);

/// A side's [`ConflictTerms`] when it is a file conflict (the CLI's `diff_content_as_merge`) —
/// `None` otherwise.
fn conflict_terms(value: &MaterializedTreeValue) -> Option<ConflictTerms> {
    match value {
        MaterializedTreeValue::FileConflict(file) => {
            Some((file.contents.map(|term| term.to_vec()), file.labels.clone()))
        }
        _ => None,
    }
}

/// The CLI's `show_color_words_diff_hunks` (`cli/src/diff_util.rs:822-873` @ v0.47.0) as data:
/// the hunks of `texts` (the materialized sides), each listing the `file_sections` it shows.
/// Under `pair`, a side in `conflicts` is diffed by its terms, each merged with `merge` first.
fn hunks_of(
    texts: Diff<&[u8]>,
    conflicts: Diff<Option<&ConflictTerms>>,
    language: Option<SourceLanguage>,
    options: WalkOptions,
    merge: &MergeOptions,
    file_sections: &[HunkKey],
) -> Vec<Hunk> {
    let mut walk = Walk {
        options,
        hunks: Vec::new(),
        draft: Draft::default(),
    };
    let line_number = DiffLineNumber { left: 1, right: 1 };
    let conflicted = conflicts.before.is_some() || conflicts.after.is_some();
    if conflicted && options.words.conflict == ConflictDiffMethod::Pair {
        let unlabeled = ConflictLabels::unlabeled();
        let sides = texts.zip(conflicts).map(|(text, terms)| match terms {
            Some((terms, _)) => files::merge(terms, merge),
            None => files::merge(&Merge::resolved(text), merge),
        });
        let labels = conflicts.map(|terms| terms.map_or(&unlabeled, |(_, labels)| labels));
        walk.conflict_hunks(language, sides.as_ref(), labels, line_number);
        // Paired line numbers count conflict terms, not lines of the marker text the sections cut.
        walk.finish(&[])
    } else {
        walk.resolved_hunks(language, texts, line_number, ROLES);
        walk.finish(file_sections)
    }
}

/// The segment kind of each side's tokens: the CLI's `removed` / `added` labels, which a
/// `-------` conflict term inverts.
const ROLES: Diff<SegmentKind> = Diff {
    before: SegmentKind::Removed,
    after: SegmentKind::Added,
};

/// The color-words walk: the CLI's printing functions, writing [`HunkLine`]s instead of text.
struct Walk {
    options: WalkOptions,
    /// The finished hunks.
    hunks: Vec<Draft>,
    /// The hunk being written.
    draft: Draft,
}

/// A hunk being written.
#[derive(Default)]
struct Draft {
    symbol: Option<String>,
    /// The line counters at its first line.
    start: Option<DiffLineNumber>,
    lines: Vec<HunkLine>,
}

impl Walk {
    /// Writes one line; `at` holds the line counters at it.
    fn push(&mut self, at: DiffLineNumber, kind: HunkLineKind, numbers: Diff<Option<u32>>, segments: Vec<Segment>) {
        self.draft.start.get_or_insert(at);
        self.draft.lines.push(HunkLine {
            kind,
            left: numbers.before,
            right: numbers.after,
            segments,
        });
    }

    /// Writes a conflict header line.
    fn header(&mut self, at: DiffLineNumber, text: &str) {
        let segments = segments([(SegmentKind::Equal, text.as_bytes())]);
        self.push(at, HunkLineKind::ConflictHeader, Diff::new(None, None), segments);
    }

    /// A skipped range (the CLI's `...` line): closes the current hunk and opens the next with
    /// the range's `symbol`.
    fn skip(&mut self, symbol: Option<String>) {
        let next = Draft {
            symbol,
            ..Draft::default()
        };
        let done = std::mem::replace(&mut self.draft, next);
        if !done.lines.is_empty() {
            self.hunks.push(done);
        }
    }

    fn finish(mut self, file_sections: &[HunkKey]) -> Vec<Hunk> {
        self.skip(None);
        self.hunks
            .into_iter()
            .map(|draft| draft.into_hunk(file_sections))
            .collect()
    }

    /// `show_color_words_conflict_hunks` (`cli/src/diff_util.rs:875-952` @ v0.47.0).
    fn conflict_hunks<T: AsRef<[u8]>>(
        &mut self,
        language: Option<SourceLanguage>,
        contents: Diff<&Merge<T>>,
        labels: Diff<&ConflictLabels>,
        mut line_number: DiffLineNumber,
    ) -> DiffLineNumber {
        let num_lefts = contents.before.as_slice().len();
        let line_diff = diff_by_line(contents.before.iter().chain(contents.after.iter()), &self.options.mode);
        let context = self.options.words.context;
        // A resolvable hunk between two matching ones can make matching hunks follow each other.
        let mut matching: Vec<Diff<&[u8]>> = Vec::new();
        let mut emitted = false;
        for hunk in files::conflict_diff_hunks(line_diff.hunks(), num_lefts) {
            match hunk.kind {
                // A matching hunk may still hold conflicts; the CLI shows its first terms only.
                DiffHunkKind::Matching => {
                    matching.push(Diff::new(bytes(*hunk.lefts.first()), bytes(*hunk.rights.first())));
                }
                DiffHunkKind::Different => {
                    let num_leading = if emitted { context } else { 0 };
                    line_number = self.context_lines(language, &matching, line_number, ROLES, (num_leading, context));
                    matching.clear();
                    emitted = true;
                    line_number =
                        if let (Some(&left), Some(&right)) = (hunk.lefts.as_resolved(), hunk.rights.as_resolved()) {
                            self.diff_lines(Diff::new(bytes(left), bytes(right)), line_number, ROLES, false)
                        } else {
                            self.unresolved_hunk(language, &hunk, labels, line_number)
                        };
                }
            }
        }
        let num_leading = if emitted { context } else { 0 };
        // No source symbol at the end.
        self.context_lines(None, &matching, line_number, ROLES, (num_leading, 0))
    }

    /// `show_color_words_unresolved_hunk` (`cli/src/diff_util.rs:954-1017` @ v0.47.0).
    fn unresolved_hunk(
        &mut self,
        language: Option<SourceLanguage>,
        hunk: &ConflictDiffHunk<'_>,
        labels: Diff<&ConflictLabels>,
        line_number: DiffLineNumber,
    ) -> DiffLineNumber {
        let description = if hunk.lefts.is_resolved() {
            "Created conflict"
        } else if hunk.rights.is_resolved() {
            "Resolved conflict"
        } else {
            "Modified conflict"
        };
        self.header(line_number, &format!("<<<<<<< {description}\n"));
        // Pad with identical (negative, positive) terms; with conflicts of different sizes on both
        // sides the padding is arbitrary, as in the CLI.
        let num_terms = hunk.lefts.as_slice().len().max(hunk.rights.as_slice().len());
        let lefts = hunk
            .lefts
            .iter()
            .enumerate()
            .chain(iter::repeat((0, hunk.lefts.first())));
        let rights = hunk
            .rights
            .iter()
            .enumerate()
            .chain(iter::repeat((0, hunk.rights.first())));
        let mut max_line_number = line_number;
        for (i, ((left_index, left), (right_index, right))) in lefts.zip(rights).take(num_terms).enumerate() {
            let positive = i.is_multiple_of(2);
            let term_line = format!(
                "{sep} left{left_term} to right{right_term}\n",
                sep = if positive { "+++++++" } else { "-------" },
                left_term = describe_conflict_term(&hunk.lefts, labels.before, left_index),
                right_term = describe_conflict_term(&hunk.rights, labels.after, right_index),
            );
            self.header(line_number, &term_line);
            let roles = if positive { ROLES } else { ROLES.invert() };
            // Each pair may be largely the same, so it is diffed again.
            let next = self.resolved_hunks(language, Diff::new(bytes(*left), bytes(*right)), line_number, roles);
            // The largest counters give trailing hunks unique numbers; they cannot be real anyway
            // once a preceding conflict hunk is resolved.
            max_line_number.left = max_line_number.left.max(next.left);
            max_line_number.right = max_line_number.right.max(next.right);
        }
        self.header(line_number, ">>>>>>> Conflict ends\n");
        max_line_number
    }

    /// `show_color_words_resolved_hunks` (`cli/src/diff_util.rs:1044-1102` @ v0.47.0).
    fn resolved_hunks(
        &mut self,
        language: Option<SourceLanguage>,
        contents: Diff<&[u8]>,
        mut line_number: DiffLineNumber,
        roles: Diff<SegmentKind>,
    ) -> DiffLineNumber {
        let line_diff = diff_by_line(contents.into_array(), &self.options.mode);
        let context_size = self.options.words.context;
        // Matching hunks never follow each other in a diff of two inputs.
        let mut context: Option<Diff<&[u8]>> = None;
        let mut emitted = false;
        for hunk in line_diff.hunks() {
            // Two inputs always give two sides.
            if let &[left, right] = &hunk.contents[..] {
                let hunk_contents = Diff::new(bytes(left), bytes(right));
                match hunk.kind {
                    DiffHunkKind::Matching => context = Some(hunk_contents),
                    DiffHunkKind::Different => {
                        let num_leading = if emitted { context_size } else { 0 };
                        line_number = self.context_lines(
                            language,
                            context.as_slice(),
                            line_number,
                            roles,
                            (num_leading, context_size),
                        );
                        context = None;
                        emitted = true;
                        line_number = self.diff_lines(hunk_contents, line_number, roles, false);
                    }
                }
            }
        }
        let num_leading = if emitted { context_size } else { 0 };
        // No source symbol at the end.
        self.context_lines(None, context.as_slice(), line_number, roles, (num_leading, 0))
    }

    /// `show_color_words_context_lines` (`cli/src/diff_util.rs:1104-1209` @ v0.47.0):
    /// `num_leading` lines, a skipped range, `num_trailing` lines. A range exactly one line longer
    /// than the lines shown is shown whole; a skipped range carries the last source-symbol line in
    /// it unless a symbol line follows it right away.
    fn context_lines(
        &mut self,
        language: Option<SourceLanguage>,
        contexts: &[Diff<&[u8]>],
        mut line_number: DiffLineNumber,
        roles: Diff<SegmentKind>,
        (num_leading, num_trailing): (usize, usize),
    ) -> DiffLineNumber {
        let (left_leading, mut left_trailing, num_left_skipped) =
            context_extract(contexts, false, num_leading, num_trailing);
        let (right_leading, mut right_trailing, num_right_skipped) =
            context_extract(contexts, true, num_leading, num_trailing);
        line_number = self.show_context(Diff::new(&left_leading, &right_leading), line_number, roles);
        if num_left_skipped > 0 || num_right_skipped > 0 {
            let symbol = language.and_then(|language| symbol_line(language, contexts, num_leading, num_trailing));
            let symbol = symbol.map(|line| {
                let line = line.strip_suffix(b"\n").unwrap_or(line);
                String::from_utf8_lossy(line.strip_suffix(b"\r").unwrap_or(line)).into_owned()
            });
            self.skip(symbol);
            line_number.left += num_left_skipped;
            line_number.right += num_right_skipped;
            if left_trailing.len() > num_trailing {
                left_trailing.pop();
                line_number.left += 1;
            }
            if right_trailing.len() > num_trailing {
                right_trailing.pop();
                line_number.right += 1;
            }
        }
        left_trailing.reverse();
        right_trailing.reverse();
        self.show_context(Diff::new(&left_trailing, &right_trailing), line_number, roles)
    }

    /// `show_color_words_context_lines`' `show`: equal sides are context lines; sides that differ
    /// (at `-w` / `-b`) take the changed-block path, still context.
    fn show_context(
        &mut self,
        sides: Diff<&Vec<&[u8]>>,
        mut line_number: DiffLineNumber,
        roles: Diff<SegmentKind>,
    ) -> DiffLineNumber {
        if sides.before == sides.after {
            for line in sides.before {
                let numbers = Diff::new(Some(line_number.left), Some(line_number.right));
                let segments = segments([(SegmentKind::Equal, *line)]);
                self.push(line_number, HunkLineKind::Context, numbers, segments);
                line_number.left += 1;
                line_number.right += 1;
            }
            line_number
        } else {
            let left = sides.before.concat();
            let right = sides.after.concat();
            self.diff_lines(Diff::new(&left[..], &right[..]), line_number, roles, true)
        }
    }

    /// `show_color_words_diff_lines` (`cli/src/diff_util.rs:1211-1276` @ v0.47.0) on its coloured
    /// path. `context` keeps every line's kind [`HunkLineKind::Context`].
    fn diff_lines(
        &mut self,
        contents: Diff<&[u8]>,
        mut line_number: DiffLineNumber,
        roles: Diff<SegmentKind>,
        context: bool,
    ) -> DiffLineNumber {
        let word_hunks: Vec<DiffHunk<'_>> = ContentDiff::by_word(contents.into_array()).hunks().collect();
        let can_inline = match self.options.words.max_inline_alternation {
            None => true,
            Some(0) => false,
            Some(max) => {
                split_diff_hunks_by_matching_newline(&word_hunks)
                    .map(count_diff_alternation)
                    .max()
                    .unwrap_or(0)
                    <= max
            }
        };
        let side_kind = |role: SegmentKind| match role {
            _ if context => HunkLineKind::Context,
            SegmentKind::Removed => HunkLineKind::Removed,
            SegmentKind::Added => HunkLineKind::Added,
            SegmentKind::Equal => HunkLineKind::Changed,
        };
        if can_inline {
            let mut lines = DiffLineIterator::with_line_number(word_hunks.iter(), line_number);
            for line in lines.by_ref() {
                let numbers = Diff::new(
                    line.has_left_content().then_some(line.line_number.left),
                    line.has_right_content().then_some(line.line_number.right),
                );
                let kind = match (numbers.before, numbers.after) {
                    (Some(_), Some(_)) => side_kind(SegmentKind::Equal),
                    (Some(_), None) => side_kind(roles.before),
                    _ => side_kind(roles.after),
                };
                let segments = segments(line.hunks.iter().map(|&(side, text)| {
                    let kind = match side {
                        DiffLineHunkSide::Both => SegmentKind::Equal,
                        DiffLineHunkSide::Left => roles.before,
                        DiffLineHunkSide::Right => roles.after,
                    };
                    (kind, bytes(text))
                }));
                self.push(line.line_number, kind, numbers, segments);
            }
            line_number = lines.next_line_number();
        } else {
            let lines = unzip_diff_hunks_to_lines(&word_hunks);
            for tokens in &lines.before {
                let numbers = Diff::new(Some(line_number.left), None);
                self.push(
                    line_number,
                    side_kind(roles.before),
                    numbers,
                    token_segments(tokens, roles.before),
                );
                line_number.left += 1;
            }
            for tokens in &lines.after {
                let numbers = Diff::new(None, Some(line_number.right));
                self.push(
                    line_number,
                    side_kind(roles.after),
                    numbers,
                    token_segments(tokens, roles.after),
                );
                line_number.right += 1;
            }
        }
        line_number
    }
}

impl Draft {
    /// The finished hunk: ranges, counts and sections from its lines.
    fn into_hunk(self, file_sections: &[HunkKey]) -> Hunk {
        let start = self.start.unwrap_or(DiffLineNumber { left: 1, right: 1 });
        let changed = |side: fn(&HunkLine) -> Option<u32>| -> Vec<u32> {
            let mut numbers: Vec<u32> = self
                .lines
                .iter()
                .filter(|line| !matches!(line.kind, HunkLineKind::Context | HunkLineKind::ConflictHeader))
                .filter_map(side)
                .collect();
            numbers.sort_unstable();
            numbers.dedup();
            numbers
        };
        let lefts = changed(|line| line.left);
        let rights = changed(|line| line.right);
        let range = |start: u32, side: fn(&HunkLine) -> Option<u32>| {
            let start = start.saturating_sub(1);
            let end = self.lines.iter().filter_map(side).max().unwrap_or(0).max(start);
            start..end
        };
        // A key's ranges are 0-based; line numbers 1-based.
        let within = |start: u32, count: u32, number: u32| {
            (start..start.saturating_add(count)).contains(&number.saturating_sub(1))
        };
        let sections = file_sections
            .iter()
            .filter(|key| {
                lefts.iter().any(|&number| within(key.old_start, key.old_count, number))
                    || rights
                        .iter()
                        .any(|&number| within(key.new_start, key.new_count, number))
            })
            .copied()
            .collect();
        Hunk {
            before_range: range(start.left, |line| line.left),
            after_range: range(start.right, |line| line.right),
            symbol: self.symbol,
            sections,
            removed: to_u32(lefts.len()),
            added: to_u32(rights.len()),
            lines: self.lines,
        }
    }
}

/// `show_color_words_context_lines`' `extract` for one side: the `num_leading` first lines, the
/// `num_trailing + 1` last ones (last first) and the number of lines between.
fn context_extract<'a>(
    contexts: &[Diff<&'a [u8]>],
    after: bool,
    num_leading: usize,
    num_trailing: usize,
) -> (Vec<&'a [u8]>, Vec<&'a [u8]>, u32) {
    let mut lines = contexts
        .iter()
        .map(|contents| if after { contents.after } else { contents.before })
        .flat_map(|side| side.split_inclusive(|byte| *byte == b'\n'))
        .fuse();
    let leading = lines.by_ref().take(num_leading).collect();
    let trailing = lines.by_ref().rev().take(num_trailing + 1).collect();
    (leading, trailing, to_u32(lines.count()))
}

/// The source-symbol line of a skipped range (`show_color_words_context_lines`): the last symbol
/// line among the skipped right-side lines, unless the first line shown after the range is a
/// symbol line itself.
fn symbol_line<'a>(
    language: SourceLanguage,
    contexts: &[Diff<&'a [u8]>],
    num_leading: usize,
    num_trailing: usize,
) -> Option<&'a [u8]> {
    let mut lines = contexts
        .iter()
        .flat_map(|contents| contents.after.split_inclusive(|byte| *byte == b'\n'))
        .fuse();
    lines.by_ref().take(num_leading).for_each(drop);
    let next_line = lines.by_ref().rev().take(num_trailing).last();
    if next_line
        .and_then(|line| source_symbol_from_line(language, line))
        .is_some()
    {
        return None;
    }
    lines.rfind(|line| source_symbol_from_line(language, line).is_some())
}

/// `describe_conflict_term` (`cli/src/diff_util.rs:1019-1042` @ v0.47.0): ` side #1 (<label>)`,
/// ` base #1`, or nothing for a resolved side.
fn describe_conflict_term<T>(terms: &Merge<T>, labels: &ConflictLabels, index: usize) -> String {
    if terms.is_resolved() {
        return String::new();
    }
    let is_add = index.is_multiple_of(2);
    let name = if is_add { "side" } else { "base" };
    let number = index / 2 + 1;
    let label = if is_add {
        labels.get_add(index / 2)
    } else {
        labels.get_remove(index / 2)
    };
    match label {
        Some(label) => format!(" {name} #{number} ({label})"),
        None => format!(" {name} #{number}"),
    }
}

/// `count_diff_alternation` (`cli/src/diff_util.rs:1343-1367` @ v0.47.0): how often the changed
/// words switch between the left and the right side, ignoring matching hunks.
fn count_diff_alternation(hunks: &[DiffHunk<'_>]) -> usize {
    let mut count = 0;
    let mut last_side = None;
    for hunk in hunks.iter().filter(|hunk| hunk.kind == DiffHunkKind::Different) {
        for (side, content) in hunk.contents.iter().enumerate() {
            if !content.is_empty() && last_side != Some(side) {
                count += 1;
                last_side = Some(side);
            }
        }
    }
    count
}

/// `split_diff_hunks_by_matching_newline` (`cli/src/diff_util.rs:1369-1377` @ v0.47.0): the
/// groups of contiguous changed lines.
fn split_diff_hunks_by_matching_newline<'a, 'b>(hunks: &'a [DiffHunk<'b>]) -> impl Iterator<Item = &'a [DiffHunk<'b>]> {
    hunks.split_inclusive(|hunk| match hunk.kind {
        DiffHunkKind::Matching => hunk.contents.iter().all(|content| content.contains(&b'\n')),
        DiffHunkKind::Different => false,
    })
}

/// A single-sided line's segments: its matching tokens equal, its other tokens `role`.
fn token_segments(tokens: &[(DiffTokenType, &[u8])], role: SegmentKind) -> Vec<Segment> {
    segments(tokens.iter().map(|&(token_type, token)| {
        let kind = match token_type {
            DiffTokenType::Matching => SegmentKind::Equal,
            DiffTokenType::Different => role,
        };
        (kind, token)
    }))
}

/// `runs` as segments: adjacent runs of one kind join, empty runs drop. A run boundary never
/// splits a UTF-8 sequence (jj-lib's words keep every non-ASCII byte), so decoding each run gives
/// the same text as decoding the line.
fn segments<'a>(runs: impl IntoIterator<Item = (SegmentKind, &'a [u8])>) -> Vec<Segment> {
    let mut joined: Vec<(SegmentKind, Vec<u8>)> = Vec::new();
    for (kind, run) in runs.into_iter().filter(|(_, run)| !run.is_empty()) {
        match joined.last_mut() {
            Some((last, bytes)) if *last == kind => bytes.extend_from_slice(run),
            _ => joined.push((kind, run.to_vec())),
        }
    }
    joined
        .into_iter()
        .map(|(kind, bytes)| Segment {
            text: String::from_utf8_lossy(&bytes).into_owned(),
            kind,
        })
        .collect()
}

/// `text`'s bytes, at the lifetime of the borrow.
fn bytes<T: AsRef<[u8]> + ?Sized>(text: &T) -> &[u8] {
    text.as_ref()
}

fn line_compare_mode(whitespace: Whitespace) -> LineCompareMode {
    match whitespace {
        Whitespace::Exact => LineCompareMode::Exact,
        Whitespace::IgnoreAllSpace => LineCompareMode::IgnoreAllSpace,
        Whitespace::IgnoreSpaceChange => LineCompareMode::IgnoreSpaceChange,
    }
}

fn to_u32(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use jj_lib::conflict_labels::ConflictLabels;
    use jj_lib::diff_presentation::LineCompareMode;
    use jj_lib::files::{FileMergeHunkLevel, MergeOptions};
    use jj_lib::merge::{Diff, Merge, SameChange};

    use super::{
        fingerprint, hunks_of, section_keys, totals, ColorWordsOptions, ConflictDiffMethod, ConflictTerms, Hunk,
        HunkKey, HunkLine, HunkLineKind, SegmentKind, WalkOptions,
    };
    use crate::source_symbol::SourceLanguage;

    fn fingerprint_of(left: &str, right: &str) -> String {
        fingerprint(
            Some(Diff::new(left.as_bytes(), right.as_bytes())),
            LineCompareMode::Exact,
            None,
            false,
        )
    }

    /// The fingerprint keys the changed lines only: shifted line numbers keep it, a different
    /// changed line, a binary change's contents and a mode change alter it; it is the documented
    /// blake2b shape.
    #[test]
    fn the_fingerprint_keys_the_changed_lines_only() {
        let base = fingerprint_of("a\nfoo\n", "a\nbar\n");
        let shifted = fingerprint_of("x\ny\na\nfoo\n", "x\ny\na\nbar\n");
        let other = fingerprint_of("a\nfoo\n", "a\nbaz\n");
        assert_eq!(base, shifted);
        assert_ne!(base, other);
        let expected = jj_lib::hex_util::encode_hex(&jj_lib::content_hash::blake2b_hash(&vec![
            b"-foo\n".to_vec(),
            b"+bar\n".to_vec(),
        ]));
        assert_eq!(base, expected);
        // Two changed blocks: per block its left lines, then its right lines.
        let blocks = jj_lib::hex_util::encode_hex(&jj_lib::content_hash::blake2b_hash(&vec![
            b"-x\n".to_vec(),
            b"-y\n".to_vec(),
            b"+X\n".to_vec(),
            b"+Y\n".to_vec(),
            b"+W\n".to_vec(),
            b"-z\n".to_vec(),
            b"+Z\n".to_vec(),
        ]));
        assert_eq!(fingerprint_of("x\ny\nkeep\nz\n", "X\nY\nW\nkeep\nZ\n"), blocks);
        // Persisted by 10.24: a jj-lib bump that changes `ContentHash`'s encoding must fail here.
        assert_eq!(
            expected,
            "cb4845dbda6d5268db932dca5672c91110bd540e265f6777b4c1d532d0b8d8f5\
             a09406656c836d1a66f72e7758ee7eca63cce6c80a9fc9b2809ff821eef44b30"
        );
        assert_eq!(expected.len(), 128);
        let exact = LineCompareMode::Exact;
        let empty = fingerprint(None, exact, None, false);
        assert_ne!(fingerprint(None, exact, None, true), empty);
        let one = fingerprint(None, exact, Some(Diff::new(&b"\0a"[..], &b"\0b"[..])), false);
        let two = fingerprint(None, exact, Some(Diff::new(&b"\0a"[..], &b"\0c"[..])), false);
        assert_ne!(one, two);
        assert_ne!(one, empty);
        // A whitespace-only change keys nothing at `-w`.
        let ignored = fingerprint(
            Some(Diff::new(&b"a b\n"[..], &b"a  b\n"[..])),
            LineCompareMode::IgnoreAllSpace,
            None,
            false,
        );
        assert_eq!(ignored, empty);
    }

    /// A file's counts are its hunks' sums.
    #[test]
    fn totals_sum_the_hunk_counts() {
        let hunks = diff(LEFT, RIGHT, None, 0);
        assert_eq!(totals(&hunks), (3, 3));
        assert_eq!(totals(&diff("a\n", "a\nb\nc\n", None, 3)), (0, 2));
        assert_eq!(totals(&[]), (0, 0));
    }

    fn key(old_start: u32, old_count: u32, new_start: u32, new_count: u32) -> HunkKey {
        HunkKey {
            old_start,
            old_count,
            new_start,
            new_count,
        }
    }

    /// The walk's options: `context`, an inline limit of `max` (`None` = unlimited), `mode`.
    fn options(context: usize, max: Option<usize>, mode: LineCompareMode) -> WalkOptions {
        WalkOptions {
            words: ColorWordsOptions {
                context,
                max_inline_alternation: max,
                conflict: ConflictDiffMethod::Materialize,
            },
            mode,
        }
    }

    fn diff(left: &str, right: &str, language: Option<SourceLanguage>, context: usize) -> Vec<Hunk> {
        diff_with(left, right, language, options(context, Some(3), LineCompareMode::Exact))
    }

    fn diff_with(left: &str, right: &str, language: Option<SourceLanguage>, options: WalkOptions) -> Vec<Hunk> {
        let texts = Diff::new(left.as_bytes(), right.as_bytes());
        let merge = MergeOptions {
            hunk_level: FileMergeHunkLevel::Line,
            same_change: SameChange::Accept,
        };
        hunks_of(
            texts,
            Diff::new(None, None),
            language,
            options,
            &merge,
            &section_keys(texts),
        )
    }

    /// One line as `<kind><left> <right>|<body>`: kind ` ` context, `-` removed, `+` added, `~`
    /// changed, `#` header; numbers right-aligned in four columns; removed runs in `[-…-]`, added
    /// runs in `{+…+}`, the line's last `\n` dropped as the CLI prints it. Checks the segment
    /// invariants.
    fn line(line: &HunkLine) -> String {
        assert!(line.segments.iter().all(|segment| !segment.text.is_empty()), "{line:?}");
        assert!(
            line.segments.windows(2).all(|pair| pair[0].kind != pair[1].kind),
            "{line:?}"
        );
        let kind = match line.kind {
            HunkLineKind::Context => ' ',
            HunkLineKind::Removed => '-',
            HunkLineKind::Added => '+',
            HunkLineKind::Changed => '~',
            HunkLineKind::ConflictHeader => '#',
        };
        let number = |number: Option<u32>| number.map_or_else(|| "    ".to_owned(), |number| format!("{number:>4}"));
        let mut body = String::new();
        let count = line.segments.len();
        for (index, segment) in line.segments.iter().enumerate() {
            let text = if index + 1 == count {
                segment.text.strip_suffix('\n').unwrap_or(&segment.text)
            } else {
                &segment.text
            };
            match segment.kind {
                _ if text.is_empty() => {}
                SegmentKind::Equal => body.push_str(text),
                SegmentKind::Removed => body.extend(["[-", text, "-]"]),
                SegmentKind::Added => body.extend(["{+", text, "+}"]),
            }
        }
        format!("{kind}{} {}|{body}", number(line.left), number(line.right))
    }

    /// Every hunk as `@ <symbol>` (`@ -` for none), then its lines.
    fn render(hunks: &[Hunk]) -> Vec<String> {
        hunks
            .iter()
            .flat_map(|hunk| {
                let header = format!("@ {}", hunk.symbol.as_deref().unwrap_or("-"));
                std::iter::once(header).chain(hunk.lines.iter().map(line))
            })
            .collect()
    }

    const LEFT: &str = "a\nb\nc\nd\ne\n";
    const RIGHT: &str = "A\nb\nC\nd\nE\n";

    /// Context 3 joins the three sections into one hunk; a one-word change is one changed line.
    #[test]
    fn context_three_joins_three_sections_into_one_hunk() {
        let hunks = diff(LEFT, RIGHT, None, 3);
        assert_eq!(hunks.len(), 1);
        let hunk = &hunks[0];
        assert_eq!((hunk.before_range.clone(), hunk.after_range.clone()), (0..5, 0..5));
        assert_eq!(hunk.sections, [key(0, 1, 0, 1), key(2, 1, 2, 1), key(4, 1, 4, 1)]);
        assert_eq!((hunk.removed, hunk.added), (3, 3));
        assert_eq!(
            render(&hunks),
            [
                "@ -",
                "~   1    1|[-a-]{+A+}",
                "    2    2|b",
                "~   3    3|[-c-]{+C+}",
                "    4    4|d",
                "~   5    5|[-e-]{+E+}",
            ]
        );
        assert_eq!(hunk.lines[1].text(), "b\n");
    }

    /// Context 0 shows a one-line gap whole (it is one line longer than the context) and splits at
    /// a longer one: one hunk per section there.
    #[test]
    fn context_zero_splits_at_a_two_line_gap() {
        assert_eq!(diff(LEFT, RIGHT, None, 0).len(), 1);
        let hunks = diff("a\nx\ny\nc\n", "A\nx\ny\nC\n", None, 0);
        let sections: Vec<_> = hunks.iter().map(|hunk| hunk.sections.clone()).collect();
        assert_eq!(sections, [[key(0, 1, 0, 1)], [key(3, 1, 3, 1)]]);
        assert_eq!(hunks[1].before_range, 3..4);
        assert_eq!(hunks[1].after_range, 3..4);
    }

    /// A last line without `\n` keeps that state, and still counts in the hunk's ranges.
    #[test]
    fn a_last_line_without_a_newline_keeps_it() {
        let hunks = diff("a\nb", "a\nc", None, 3);
        let lines = &hunks[0].lines;
        assert_eq!(lines[0].text(), "a\n");
        assert_eq!(lines[1].text(), "bc");
        assert_eq!(render(&hunks), ["@ -", "    1    1|a", "~   2    2|[-b-]{+c+}"]);
        assert_eq!(hunks[0].sections, [key(1, 1, 1, 1)]);
        assert_eq!(
            (hunks[0].before_range.clone(), hunks[0].after_range.clone()),
            (0..2, 0..2)
        );
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

    /// A skipped range carries the last symbol line in it, raw (indentation kept, no line break),
    /// unless the first line shown after it is a symbol line; a range without one is a plain
    /// `...` (`None`); a first hunk without a skipped range before it has none either.
    #[test]
    fn a_skipped_range_carries_its_last_symbol_line() {
        let rust = Some(SourceLanguage::Rust);
        let left = "fn main() {\n    a();\n    b();\n    c();\n    d();\n    e();\n    f();\n}\n";
        let hunks = diff(left, &left.replace("f()", "g()"), rust, 1);
        assert_eq!(hunks[0].symbol.as_deref(), Some("fn main() {"));
        let indented = "  impl X {\n    a();\n    b();\n    c();\n    d();\n";
        let hunks = diff(indented, &indented.replace("d()", "e()"), rust, 1);
        assert_eq!(hunks[0].symbol.as_deref(), Some("  impl X {"));
        // A CRLF file's symbol line loses its `\r\n`.
        let crlf = left.replace('\n', "\r\n");
        let hunks = diff(&crlf, &crlf.replace("f()", "g()"), rust, 1);
        assert_eq!(hunks[0].symbol.as_deref(), Some("fn main() {"));
        // The line after the range is a symbol line itself: no symbol for the range.
        let next = "fn a() {}\nx\ny\nz\nfn b() {}\nw\n";
        let hunks = diff(next, &next.replace('w', "v"), rust, 1);
        assert_eq!(hunks[0].symbol, None);
        // No symbol line in the range, and no language.
        assert_eq!(diff(left, &left.replace("f()", "g()"), None, 1)[0].symbol, None);
        let near_top = diff("a\nb\n", "a\nc\n", rust, 3);
        assert_eq!(near_top[0].symbol, None);
        // The generic language: a line starting with an identifier, as for Dart.
        let dart = "class A {\n  a;\n  b;\n  c;\n  d;\n  e;\n}\n";
        let hunks = diff(dart, &dart.replace("e;", "f;"), Some(SourceLanguage::Generic), 1);
        assert_eq!(hunks[0].symbol.as_deref(), Some("class A {"));
    }

    /// Context 3 between two one-line changes: 7 unchanged lines are shown whole (the range is
    /// one line longer than the 3 + 3 shown), 8 split the diff into two hunks.
    #[test]
    fn a_range_one_line_longer_than_the_context_is_shown_whole() {
        let text = |gap: usize| {
            let mut lines = vec!["a".to_owned()];
            lines.extend((0..gap).map(|i| format!("x{i}")));
            lines.push("b".to_owned());
            lines.join("\n") + "\n"
        };
        for (gap, hunks) in [(7, 1), (8, 2)] {
            let left = text(gap);
            let right = left.replace("a\n", "A\n").replace("\nb\n", "\nB\n");
            let result = diff(&left, &right, None, 3);
            assert_eq!(result.len(), hunks, "{gap} apart: {:?}", render(&result));
            let shown: usize = result.iter().map(|hunk| hunk.lines.len()).sum();
            assert_eq!(shown, if hunks == 1 { 9 } else { 8 });
        }
    }

    /// At `-w` a whitespace-only change shows no line when its range is skipped, though the file
    /// keeps its section.
    #[test]
    fn ignoring_whitespace_skips_a_whitespace_only_change() {
        let texts = Diff::new(&b"a b\nc\n"[..], &b"a  b\nc\n"[..]);
        assert_eq!(section_keys(texts), [key(0, 1, 0, 1)]);
        for mode in [LineCompareMode::IgnoreAllSpace, LineCompareMode::IgnoreSpaceChange] {
            assert!(diff_with("a b\nc\n", "a  b\nc\n", None, options(3, Some(3), mode)).is_empty());
        }
    }

    /// At `-b` a context line whose indentation changed keeps kind Context, with the changed-block
    /// path's numbers and marks.
    #[test]
    fn ignoring_space_changes_marks_a_context_line_like_the_cli() {
        let hunks = diff_with(
            "fn f() {\n    let a = 1;\n  let b = 2;\n    let c = 3;\n}\n",
            "fn f() {\n    let a = 10;\n    let b = 2;\n    let c = 30;\n}\n",
            None,
            options(3, Some(3), LineCompareMode::IgnoreSpaceChange),
        );
        assert_eq!(
            render(&hunks),
            [
                "@ -",
                "    1    1|fn f() {",
                "~   2    2|    let a = [-1-]{+10+};",
                "    3    3|  {+  +}let b = 2;",
                "~   4    4|    let c = [-3-]{+30+};",
                "    5    5|}",
            ]
        );
        assert_eq!((hunks[0].removed, hunks[0].added), (2, 2));
    }

    /// An added 1000-line text is one hunk of 1000 added lines.
    #[test]
    fn an_added_thousand_line_text_is_one_hunk_of_a_thousand_lines() {
        let text = "x\n".repeat(1000);
        let hunks = diff("", &text, None, 3);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].after_range, 0..1000);
        assert_eq!(hunks[0].added, 1000);
        assert_eq!(hunks[0].lines.len(), 1000);
        assert!(hunks[0].lines.iter().all(|line| line.kind == HunkLineKind::Added));
    }

    /// Ralph's jj example (commit `671e4eaca`, `lib/src/git.rs` `write_locked_index`), padded so
    /// its line numbers are the file's: old lines 2441-2462, new 2441-2469.
    fn jj_example() -> (String, String) {
        let pad = "\n".repeat(2440);
        let head = [
            "/// Writes `index` to the lock file and atomically replaces the Git index with\n",
            "/// it.\n",
            "fn write_locked_index(\n",
            "    index: &gix::index::File,\n",
            "    lock: gix::lock::File,\n",
            ") -> Result<(), GitResetHeadError> {\n",
            "    debug_assert_eq!(lock.resource_path(), index.path());\n",
            "    let mut out = std::io::BufWriter::new(lock);\n",
            "    index\n",
            "        .write_to(&mut out, gix::index::write::Options::default())\n",
            "        .map_err(GitResetHeadError::from_git)?;\n",
            "    let lock = out\n",
            "        .into_inner()\n",
        ]
        .concat();
        let tail = [
            "    Ok(())\n",
            "}\n",
            "\n",
            "/// Reads the Git index from disk, or returns an empty index if there's none.\n",
            "///\n",
            "/// Unlike `gix::Repository::index_or_empty()`, this bypasses the index cache\n",
        ]
        .concat();
        let old = [
            "        .map_err(|err| GitResetHeadError::from_git(err.into_error()))?;\n",
            "    lock.commit()\n",
            "        .map_err(|err| GitResetHeadError::from_git(err.error))?;\n",
        ]
        .concat();
        let new = [
            "        .map_err(|err| {\n",
            "            let (source, out) = err.into_parts();\n",
            "            let path = out.get_ref().lock_path().to_owned();\n",
            "            PathError { path, source }\n",
            "        })\n",
            "        .map_err(GitResetHeadError::from_git)?;\n",
            "    lock.commit()\n",
            "        .map_err(|err| err.error)\n",
            "        .context(index.path())\n",
            "        .map_err(GitResetHeadError::from_git)?;\n",
        ]
        .concat();
        (format!("{pad}{head}{old}{tail}"), format!("{pad}{head}{new}{tail}"))
    }

    const JJ_SPLIT_CALL: [&str; 6] = [
        "~2454 2454|        .map_err(|err| {+{+}",
        "+     2455|{+            let (source, out) = err.into_parts();+}",
        "+     2456|{+            let path = out.get_ref().lock_path().to_owned();+}",
        "+     2457|{+            PathError { path, source }+}",
        "+     2458|{+        })+}",
        "~2454 2459|{+        .map_err(+}GitResetHeadError::from_git[-(err.into_error())-])?;",
    ];

    const JJ_CONTEXT_CALL: [&str; 4] = [
        " 2455 2460|    lock.commit()",
        "~2456 2461|        .map_err(|err| {+err.error)+}",
        "+     2462|{+        .context(index.path())+}",
        "~2456 2463|{+        .map_err(+}GitResetHeadError::from_git[-(err.error)-])?;",
    ];

    /// The jj example inlines: one old line spread over several lines repeats its left number.
    #[test]
    fn ralphs_jj_example_inlines_like_the_cli() {
        let (left, right) = jj_example();
        let hunks = diff(&left, &right, Some(SourceLanguage::Rust), 3);
        let mut expected = vec![
            "@ fn write_locked_index(",
            " 2451 2451|        .map_err(GitResetHeadError::from_git)?;",
            " 2452 2452|    let lock = out",
            " 2453 2453|        .into_inner()",
        ];
        expected.extend(JJ_SPLIT_CALL);
        expected.extend(JJ_CONTEXT_CALL);
        expected.extend([" 2457 2464|    Ok(())", " 2458 2465|}", " 2459 2466|"]);
        assert_eq!(render(&hunks), expected);
        let hunk = &hunks[0];
        assert_eq!((hunk.removed, hunk.added), (2, 9));
        assert_eq!(
            (hunk.before_range.clone(), hunk.after_range.clone()),
            (2450..2459, 2450..2466)
        );
        // `--context 1`.
        let narrow = diff(&left, &right, Some(SourceLanguage::Rust), 1);
        let mut expected = vec!["@ fn write_locked_index(", " 2453 2453|        .into_inner()"];
        expected.extend(JJ_SPLIT_CALL);
        expected.extend(JJ_CONTEXT_CALL);
        expected.push(" 2457 2464|    Ok(())");
        assert_eq!(render(&narrow), expected);
    }

    /// `max-inline-alternation = 0` never inlines: each block is its removed lines, then its added
    /// lines, with the block's word marks.
    #[test]
    fn a_limit_of_zero_never_inlines() {
        let (left, right) = jj_example();
        let hunks = diff_with(&left, &right, None, options(3, Some(0), LineCompareMode::Exact));
        let rendered = render(&hunks);
        assert_eq!(
            rendered[4..11],
            [
                "-2454     |        .map_err(|err| GitResetHeadError::from_git[-(err.into_error())-])?;",
                "+     2454|        .map_err(|err| {+{+}",
                "+     2455|{+            let (source, out) = err.into_parts();+}",
                "+     2456|{+            let path = out.get_ref().lock_path().to_owned();+}",
                "+     2457|{+            PathError { path, source }+}",
                "+     2458|{+        })+}",
                "+     2459|{+        .map_err(+}GitResetHeadError::from_git)?;",
            ]
        );
        let kinds = |kind| hunks[0].lines.iter().filter(|line| line.kind == kind).count();
        assert_eq!((kinds(HunkLineKind::Removed), kinds(HunkLineKind::Added)), (2, 9));
        assert_eq!(kinds(HunkLineKind::Changed), 0);
    }

    /// Ralph's widget-test block (5.9's decision note): 3 removed lines and 16 added ones
    /// alternate too often to inline at the default limit, so the block is its removed lines,
    /// then its added lines, with block-wide word marks.
    fn widget_test() -> (&'static str, &'static str) {
        let left = "void main() {\n  void prepare() {\n    run(() {\n    });\n  }\n\n  \
             // Tablet only: the wide test font overflows the compact app bar, which holds the buttons on a phone.\n  \
             // The phone layout is checked on a device.\n  \
             testWidgets('shows Funktion speichern instead of Weiter on the last step', (tester) async {\n    \
             await openWizard(tester, size: tablet);\n    await fillGeneralStep(tester);\n  });\n}\n";
        let right = "void main() {\n  void prepare() {\n    run(() {\n    });\n  }\n\n  \
             // The tablet shows the long label. The phone app bar has little room and shows the short one.\n  \
             testWidgets('shows Speichern instead of Weiter on the last step on a phone', (tester) async {\n    \
             await openWizard(tester, size: phone);\n    await fillGeneralStep(tester);\n\n    \
             for (var i = 0; i < 3; i++) {\n      \
             await tester.tap(withIdentifier(SemanticsIdentifiers.functionWizard_next));\n      \
             await tester.pumpAndSettle();\n    }\n\n    \
             expect(find.text('Speichern'), findsWidgets);\n    \
             expect(find.text('Funktion speichern'), findsNothing);\n    \
             expect(find.text('Weiter'), findsNothing);\n  });\n\n  \
             testWidgets('shows Funktion speichern instead of Weiter on the last step on a tablet', (tester) async {\n    \
             await openWizard(tester, size: tablet);\n    await fillGeneralStep(tester);\n  });\n}\n";
        (left, right)
    }

    #[test]
    fn a_block_over_the_limit_is_not_inlined() {
        let (left, right) = widget_test();
        let hunks = diff(left, right, Some(SourceLanguage::Generic), 3);
        assert_eq!(
            render(&hunks)[..10],
            [
                "@ void main() {",
                "    4    4|    });",
                "    5    5|  }",
                "    6    6|",
                "-   7     |  // [-Tablet-] [-only: the wide test font overflows-] [-the-] [-compact-] app bar[-,-] \
                 [-which-] [-holds-] [-the-] [-buttons-] on a phone[-.-]",
                "-   8     |  [-// The-] phone [-layout-] [-is-] [-checked-] on a [-device.-]",
                "-   9     |[-  testWidgets('shows Funktion speichern instead of Weiter on the last step-]', \
                 (tester) async {",
                "+        7|  // {+The+} {+tablet shows the long label.+} {+The+} {+phone+} app bar\
                 {+ has little room and shows the short one.+}",
                "+        8|{+  testWidgets('shows Speichern instead of Weiter+} {+on+} {+the+} {+last+} {+step+} \
                 on a phone{+', (tester) async {+}",
                "+        9|  {+  await openWizard(tester, size:+} phone{+);+}",
            ]
        );
        assert_eq!((hunks[0].removed, hunks[0].added), (3, 16));
        // Unlimited (`-1`) inlines it.
        let inlined = diff_with(left, right, None, options(3, None, LineCompareMode::Exact));
        assert!(inlined[0].lines.iter().any(|line| line.kind == HunkLineKind::Changed));
    }

    /// A conflict's terms (side, base, side) and labels.
    fn terms(terms: [&str; 3], labels: &[&str]) -> ConflictTerms {
        (
            Merge::from_vec(terms.map(|term| term.as_bytes().to_vec()).to_vec()),
            ConflictLabels::from_vec(labels.iter().map(ToString::to_string).collect()),
        )
    }

    /// `diff.color-words.conflict = "pair"` over two sides, each its text or its conflict terms.
    fn pair_diff(left: &(&str, Option<ConflictTerms>), right: &(&str, Option<ConflictTerms>)) -> Vec<String> {
        let texts = Diff::new(left.0.as_bytes(), right.0.as_bytes());
        let mut options = options(3, Some(3), LineCompareMode::Exact);
        options.words.conflict = ConflictDiffMethod::Pair;
        let merge = MergeOptions {
            hunk_level: FileMergeHunkLevel::Line,
            same_change: SameChange::Accept,
        };
        let conflicts = Diff::new(left.1.as_ref(), right.1.as_ref());
        // A section covering every line: paired hunks still name none, as their numbers count
        // conflict terms, not marker-text lines.
        let hunks = hunks_of(texts, conflicts, None, options, &merge, &[key(0, 100, 0, 100)]);
        assert!(hunks.iter().all(|hunk| hunk.sections.is_empty()), "{hunks:?}");
        render(&hunks)
    }

    /// Two conflicted sides: a resolved change diffs plainly, a conflict equal on both sides is
    /// context (its first terms), and a conflict that differs is a `Modified conflict` diffed
    /// term by term, labels where the side has them.
    #[test]
    fn pairing_two_conflicts_diffs_term_by_term() {
        let left = terms(
            ["a\nm\nX\nm\nP\n", "a\nm\nB\nm\nQ\n", "a\nm\nY\nm\nR\n"],
            &["l1", "lb", "l2"],
        );
        let right = terms(["c\nm\nX\nm\nP\n", "c\nm\nB\nm\nQ\n", "c\nm\nY\nm\nS\n"], &[]);
        assert_eq!(
            pair_diff(&("", Some(left)), &("", Some(right))),
            [
                "@ -",
                "~   1    1|[-a-]{+c+}",
                "    2    2|m",
                "    3    3|X",
                "    4    4|m",
                "#         |<<<<<<< Modified conflict",
                "#         |+++++++ left side #1 (l1) to right side #1",
                "    5    5|P",
                "#         |------- left base #1 (lb) to right base #1",
                "    5    5|Q",
                "#         |+++++++ left side #2 (l2) to right side #2",
                "~   5    5|[-R-]{+S+}",
                "#         |>>>>>>> Conflict ends",
            ]
        );
    }

    /// A conflicted left side against a resolved right one is a `Resolved conflict`; the resolved
    /// side pads the terms, and under the `-------` term the roles swap.
    #[test]
    fn pairing_a_conflict_with_a_resolution_swaps_roles_under_the_base() {
        let left = terms(["x\n", "b\n", "y\n"], &[]);
        assert_eq!(
            pair_diff(&("", Some(left)), &("z\n", None)),
            [
                "@ -",
                "#         |<<<<<<< Resolved conflict",
                "#         |+++++++ left side #1 to right",
                "~   1    1|[-x-]{+z+}",
                "#         |------- left base #1 to right",
                "~   1    1|{+b+}[-z-]",
                "#         |+++++++ left side #2 to right",
                "~   1    1|[-y-]{+z+}",
                "#         |>>>>>>> Conflict ends",
            ]
        );
    }

    /// Ralph's stepper.dart edits (10.32's demo data).
    const STEPPER: &str = "import 'package:flutter/widgets.dart';\n\n\
        class StepperButton extends StatelessWidget {\n  \
        const StepperButton({super.key, required this.isLastStep, required this.s});\n\n  \
        final bool isLastStep;\n  final Strings s;\n\n  @override\n  \
        Widget build(BuildContext context) => FilledButton(\n    \
        child: Text(isLastStep ? s.functionWizard_save : s.functionWizard_next),\n  );\n}\n\n\
        class StepperLine extends StatelessWidget {\n  \
        const StepperLine({super.key, required this.isFirst, required this.lineColor});\n\n  \
        final bool isFirst;\n  final Color lineColor;\n\n  @override\n  \
        Widget build(BuildContext context) => Row(children: [\n    \
        Expanded(child: _Line(color: isFirst ? null : lineColor)),\n    DecoratedBox(\n      \
        decoration: BoxDecoration(color: lineColor),\n      child: const SizedBox(width: 8, height: 8),\n    \
        ),\n  ]);\n}\n\nclass _Line extends StatelessWidget {\n  const _Line({required this.color});\n\n  \
        final Color? color;\n\n  @override\n  \
        Widget build(BuildContext context) => ColoredBox(color: color ?? const Color(0x00000000));\n}\n\n\
        Widget stepLabel(Widget label) => Padding(\n  padding: Spacing.spacing8,\n  child: label,\n);\n";

    /// The three stepper edits: one changed line with both words, a call split over three lines
    /// repeating its left number, and an inserted comment sharing its left number with the
    /// changed line below.
    #[test]
    fn the_stepper_edits_inline_like_the_cli() {
        let right = STEPPER
            .replace("s.functionWizard_save :", "saveLabel :")
            .replace(
                "Expanded(child: _Line(color: isFirst ? null : lineColor)),",
                "Expanded(\n      child: _Line(color: isFirst ? null : lineColor),\n    ),",
            )
            .replace(
                "  padding: Spacing.spacing8,",
                "  // Small side padding.\n  padding: Spacing.spacing2,",
            );
        let hunks = diff(STEPPER, &right, Some(SourceLanguage::Generic), 3);
        let rendered = render(&hunks);
        assert_eq!(rendered[0], "@ class StepperButton extends StatelessWidget {");
        assert!(rendered.contains(
            &"~  11   11|    child: Text(isLastStep ? [-s.functionWizard_save-]{+saveLabel+} : s.functionWizard_next),"
                .to_owned()
        ));
        let split = rendered
            .iter()
            .position(|line| line.starts_with("~  23   23"))
            .expect("the split call");
        assert_eq!(
            rendered[split..split + 3],
            [
                "~  23   23|    Expanded(",
                "~  23   24|{+      +}child: _Line(color: isFirst ? null : lineColor){+,+}",
                "~  23   25|{+    +}),",
            ]
        );
        assert_eq!(
            rendered[rendered.len() - 4..],
            [
                "~  41   43|  {+// Small side padding.+}",
                "~  41   44|{+  +}padding: Spacing.[-spacing8-]{+spacing2+},",
                "   42   45|  child: label,",
                "   43   46|);",
            ]
        );
        assert_eq!(hunks.len(), 3);
    }
}
