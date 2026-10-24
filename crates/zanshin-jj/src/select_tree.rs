// SPDX-License-Identifier: MIT

//! `select_tree.rs` — the GUI diff-editor contract (Story 9.50): a hunk selection becomes the
//! tree the CLI's builtin diff editor writes for the same choice, and the tree arms of `commit`,
//! `split` and `squash` take that tree back.
//!
//! The CLI's interactive verbs run a diff editor over `Diff(left, right)` — `left` the revision's
//! PARENT tree, `right` its own tree (`split.rs:567`, `squash.rs:495`, `commit.rs:103` @ v0.46.0).
//! Zanshin replaces the editor (ADR-0003): the GUI shows the diff, the user picks whole files or
//! sections, [`select_tree`] writes the tree that choice yields and the verb takes it.
//!
//! - **Sections** are the builtin editor's (`make_diff_sections`, `cli/src/merge_tools/builtin.rs:
//!   225-271`): `ContentDiff::by_line([left, right])`, one section per `Different` hunk. A
//!   section's [`HunkKey`] is where it sits on each side, in lines (`split_inclusive('\n')`, so a
//!   last line without `\n` counts).
//! - **Sectionable** is a file both sides of which are a resolved regular file with the same
//!   executable bit and UTF-8 text without a NUL byte. Everything else in the diff — an added or
//!   deleted file, a mode change, binary content, a symlink, a submodule, a conflict on either
//!   side — is selected whole only; a key for it is stale.
//! - **Build** is `apply_diff_builtin` (`builtin.rs:405-465`): start from the right tree, set every
//!   path of `left.diff_stream(right)` to its left value, then apply each selected file — whole:
//!   the right value; sections: the matching text, the right side of the selected sections and the
//!   left side of the others, written as a new file that keeps the left value's copy id.
//! - **Stale** is a selection whose `left` is no longer the revision's parent tree (a rebase, a
//!   rewritten parent), or a key that is not one of the file's current sections. A change to the
//!   revision's OWN content is not stale: every verb snapshots first (9.26), the selected tree is
//!   absolute, and the rest stays in the revision. Refused as [`MutateError::StaleSelection`].
//!
//! Divergences, all deliberate:
//!
//! - the CLI's "Empty diff - won't run diff editor." warning is not ported — it reports the
//!   terminal editor not being launched, and the GUI shows the diff itself;
//! - a mode change is whole only: the builtin editor offers it as a separate `FileMode` toggle
//!   next to the content sections (`builtin.rs:296-301` @ v0.46.0), Zanshin selects such a file
//!   whole (epics.md Story 9.50);
//! - a conflicted file is whole only: the builtin editor sections its materialized conflict
//!   markers and writes the result back through `conflicts::update_from_content`
//!   (`builtin.rs:423-445`), Zanshin selects such a file whole (epics.md Story 9.50, Claude's
//!   proposal);
//! - an added or deleted text file is whole only: the builtin editor gives it one line section
//!   (`builtin.rs:326-345`), Zanshin selects such a file whole (Story 9.50's sectionable rule);
//! - a section is selected whole: the builtin editor can check single lines inside it
//!   (`SectionChangedLine::is_checked`, `builtin.rs:211-222`), lines are a non-goal here.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use futures::{AsyncReadExt as _, StreamExt as _};
use jj_lib::backend::{FileId, MergedTreeValue, TreeId, TreeValue};
use jj_lib::conflict_labels::ConflictLabels;
use jj_lib::diff::{ContentDiff, DiffHunkKind};
use jj_lib::matchers::EverythingMatcher;
use jj_lib::merge::{Diff, Merge};
use jj_lib::merged_tree::MergedTree;
use jj_lib::merged_tree_builder::MergedTreeBuilder;
use jj_lib::object_id::ObjectId;
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use jj_lib::store::Store;
use jj_lib::workspace::Workspace;

use crate::mutate::{be, res, MutateError};
use crate::ChangeId;

/// Where one changed section of a file sits on each side, in lines (Story 9.50) — the key the
/// GUI selects a section by.
///
/// `old_start` / `new_start` are the 0-based index of the section's first line on the left / right
/// side (the number of lines before it); `old_count` / `new_count` its lines there. An insertion
/// has `old_count == 0`, a deletion `new_count == 0`. Lines are cut like `split_inclusive('\n')`:
/// a last line without `\n` counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct HunkKey {
    /// 0-based index of the section's first line on the left (parent) side.
    pub old_start: u32,
    /// The section's lines on the left side.
    pub old_count: u32,
    /// 0-based index of the section's first line on the right (revision) side.
    pub new_start: u32,
    /// The section's lines on the right side.
    pub new_count: u32,
}

/// What is selected of one file (Story 9.50).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileChoice {
    /// The whole file: the revision's value at that path, whatever kind of change it is.
    Whole,
    /// These sections of a sectionable file (see the module doc); the others keep the left side.
    /// An empty list selects nothing of the file.
    Hunks(Vec<HunkKey>),
}

/// One file of a selection (Story 9.50).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileSelection {
    /// The repo-relative path, in jj's internal `/`-separated form — the form `show`'s
    /// `file_changes` report.
    pub path: String,
    /// What is selected of it.
    pub choice: FileChoice,
}

/// [`crate::Repo::select_tree`]'s arguments (Story 9.50).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SelectTreeOptions {
    /// The revision the selection was made in. `None` is `@`.
    pub revision: Option<ChangeId>,
    /// The tree the selection was made against — the revision's parent tree as
    /// [`crate::ShowEntry::parent_tree_ids`] reports it (hex, in order).
    pub left: Vec<String>,
    /// The selected files; a file not listed keeps its left side. Each path at most once.
    pub files: Vec<FileSelection>,
}

/// A tree [`crate::Repo::select_tree`] wrote (Story 9.50): its tree ids (hex, in `Merge` order —
/// one for a resolved tree, an odd number for a conflicted one) and its conflict labels (empty =
/// unlabeled, else one per tree id), so a conflicted tree round-trips unchanged.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SelectedTreeId {
    /// The tree ids, hex.
    pub tree_ids: Vec<String>,
    /// The conflict labels; empty = unlabeled.
    pub labels: Vec<String>,
}

/// A tree arm's selection (Story 9.50): the tree [`crate::Repo::select_tree`] returned and the
/// `left` it was selected against.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TreeSelection {
    /// The selected tree.
    pub tree: SelectedTreeId,
    /// The `left` the selection was made against; the verb refuses
    /// [`MutateError::StaleSelection`] when the source's parent tree is no longer this.
    pub left: Vec<String>,
}

/// One squash source's selected tree (Story 9.50) — the CLI runs its editor once per source
/// (`squash.rs:484-533` @ v0.46.0).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceTree {
    /// The source the tree was selected in.
    pub source: ChangeId,
    /// Its selection.
    pub tree: TreeSelection,
}

/// The refusal of `paths` together with a selected tree, shared by the three tree arms.
pub(crate) const PATHS_WITH_TREE: &str =
    "paths cannot be combined with a selected tree: the tree already holds the selection";

/// The stale-`left` refusal's reason.
const STALE_LEFT: &str = "The selection was made against another parent tree: the revision's parents changed since";

impl SelectedTreeId {
    /// The ids and labels of `tree`.
    pub(crate) fn of(tree: &MergedTree) -> Self {
        Self {
            tree_ids: tree.tree_ids().iter().map(ObjectId::hex).collect(),
            labels: tree.labels().as_slice().to_vec(),
        }
    }

    /// The tree ids as a `Merge` and the labels — the shape [`crate::op_support::SelectedTree`]
    /// rebuilds the tree from.
    ///
    /// # Errors
    ///
    /// [`MutateError::InvalidInput`] — an even or zero id count, a malformed id, or a label count
    /// that is neither zero nor the id count.
    pub(crate) fn parse(&self) -> Result<(Merge<TreeId>, ConflictLabels), MutateError> {
        let ids = parse_tree_ids(&self.tree_ids, "the selected tree")?;
        if !self.labels.is_empty() && self.labels.len() != self.tree_ids.len() {
            return Err(MutateError::invalid(format!(
                "the selected tree has {} labels for {} tree ids",
                self.labels.len(),
                self.tree_ids.len()
            )));
        }
        Ok((ids, ConflictLabels::from_vec(self.labels.clone())))
    }
}

/// `ids` as a `Merge` of tree ids — `what` names the field in the refusal.
///
/// # Errors
///
/// [`MutateError::InvalidInput`] — an even (or zero) count, or an id that is not hex.
pub(crate) fn parse_tree_ids(ids: &[String], what: &str) -> Result<Merge<TreeId>, MutateError> {
    if ids.len().is_multiple_of(2) {
        return Err(MutateError::invalid(format!(
            "{what} needs an odd number of tree ids, got {}",
            ids.len()
        )));
    }
    let parsed = ids
        .iter()
        .map(|hex| {
            TreeId::try_from_hex(hex).ok_or_else(|| MutateError::invalid(format!("malformed tree id in {what}: {hex}")))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Merge::from_vec(parsed))
}

/// A tree arm's shape — what the verbs' argument checks refuse before the snapshot, as the CLI
/// parses its arguments before it snapshots.
///
/// # Errors
///
/// [`MutateError::InvalidInput`] — see [`parse_tree_ids`] and [`SelectedTreeId::parse`].
pub(crate) fn check_tree_selection(selection: &TreeSelection) -> Result<(), MutateError> {
    parse_tree_ids(&selection.left, "left")?;
    selection.tree.parse()?;
    Ok(())
}

/// Refuses a selection made against another parent tree — the staleness check the tree arms run
/// where the CLI runs `diff_selector.select`, and [`select_tree`] runs too.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `left` does not parse ([`parse_tree_ids`]).
/// - [`MutateError::StaleSelection`] — `parent_tree`'s ids are not `left`.
pub(crate) fn check_left(parent_tree: &MergedTree, left: &[String]) -> Result<(), MutateError> {
    if *parent_tree.tree_ids() != parse_tree_ids(left, "left")? {
        return Err(MutateError::StaleSelection {
            reason: STALE_LEFT.to_owned(),
        });
    }
    Ok(())
}

/// What [`crate::Repo::select_tree`] refuses before the snapshot, as the CLI parses its arguments
/// before it snapshots: a malformed `left`, an invalid, root or duplicate path.
///
/// # Errors
///
/// [`MutateError::InvalidInput`].
pub(crate) fn check_select_tree_args(options: &SelectTreeOptions) -> Result<(), MutateError> {
    parse_tree_ids(&options.left, "left")?;
    parse_files(&options.files)?;
    Ok(())
}

/// `jj`'s builtin diff editor applying the GUI's choice (Story 9.50) — see
/// [`crate::Repo::select_tree`]. The arguments were checked by [`check_select_tree_args`].
///
/// # Errors
///
/// See [`crate::Repo::select_tree`].
pub(crate) fn select_tree(workspace: &Workspace, options: &SelectTreeOptions) -> Result<SelectedTreeId, MutateError> {
    let files = parse_files(&options.files)?;
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let repo: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let revision = crate::op_support::resolve_or_wc(repo, workspace.workspace_name(), options.revision.as_ref())
        .map_err(|e| res(e, options.revision.as_ref()))?;
    let parent_tree = pollster::block_on(revision.parent_tree(repo)).map_err(be)?;
    check_left(&parent_tree, &options.left)?;
    let tree = pollster::block_on(build(repo.store(), &parent_tree, &revision.tree(), &files))?;
    Ok(SelectedTreeId::of(&tree))
}

/// The selection's paths, parsed — each a file path (not the root) given at most once.
fn parse_files(files: &[FileSelection]) -> Result<Vec<(RepoPathBuf, &FileChoice)>, MutateError> {
    let mut seen = HashSet::new();
    let mut parsed = Vec::with_capacity(files.len());
    for file in files {
        let path = RepoPathBuf::from_internal_string(file.path.as_str())
            .map_err(|e| MutateError::invalid(format!("invalid path {:?}: {e}", file.path)))?;
        if path.is_root() {
            return Err(MutateError::invalid(
                "a selected file needs a path, not the root".to_owned(),
            ));
        }
        if !seen.insert(path.clone()) {
            return Err(MutateError::invalid(format!("path selected twice: {}", file.path)));
        }
        parsed.push((path, &file.choice));
    }
    Ok(parsed)
}

/// `apply_diff_builtin` (`builtin.rs:405-465` @ v0.46.0) over the GUI's choice.
async fn build(
    store: &Arc<Store>,
    left: &MergedTree,
    right: &MergedTree,
    files: &[(RepoPathBuf, &FileChoice)],
) -> Result<MergedTree, MutateError> {
    let mut builder = MergedTreeBuilder::new(right.clone());
    let mut changed: HashMap<RepoPathBuf, Diff<MergedTreeValue>> = HashMap::new();
    let mut stream = left.diff_stream(right, &EverythingMatcher);
    while let Some(entry) = stream.next().await {
        let values = entry.values.map_err(be)?;
        builder.set_or_remove(entry.path.clone(), values.before.clone());
        changed.insert(entry.path, values);
    }
    for (path, choice) in files {
        let keys = match choice {
            FileChoice::Whole => {
                // An unchanged path already holds the right (= left) value.
                if let Some(values) = changed.get(path) {
                    builder.set_or_remove(path.clone(), values.after.clone());
                }
                continue;
            }
            FileChoice::Hunks(keys) if keys.is_empty() => continue,
            FileChoice::Hunks(keys) => keys,
        };
        let Some(values) = changed.get(path) else {
            return Err(stale(format!(
                "{} has no changes, so it has no sections",
                path.as_internal_file_string()
            )));
        };
        let value = select_sections(store, path, values, keys).await?;
        builder.set_or_remove(path.clone(), value);
    }
    builder.write_tree().await.map_err(be)
}

/// The file `keys` select of a changed path — refused as stale unless the path is sectionable and
/// every key is one of its current sections.
async fn select_sections(
    store: &Store,
    path: &RepoPath,
    values: &Diff<MergedTreeValue>,
    keys: &[HunkKey],
) -> Result<MergedTreeValue, MutateError> {
    let (
        Some(Some(TreeValue::File {
            id: left_id,
            executable,
            copy_id,
        })),
        Some(Some(TreeValue::File {
            id: right_id,
            executable: right_executable,
            ..
        })),
    ) = (values.before.as_resolved(), values.after.as_resolved())
    else {
        return Err(whole_only(path));
    };
    if executable != right_executable {
        return Err(whole_only(path));
    }
    let left = read_file(store, path, left_id).await?;
    let right = read_file(store, path, right_id).await?;
    if !is_text(&left) || !is_text(&right) {
        return Err(whole_only(path));
    }
    let pieces = sections(&left, &right);
    let current: HashSet<HunkKey> = pieces
        .iter()
        .filter_map(|piece| match piece {
            Piece::Changed(section) => Some(section.key),
            Piece::Same(_) => None,
        })
        .collect();
    if let Some(key) = keys.iter().find(|key| !current.contains(key)) {
        return Err(stale_key(path, key));
    }
    let selected: HashSet<HunkKey> = keys.iter().copied().collect();
    let content = assemble(&pieces, &selected);
    let id = store.write_file(path, &mut content.as_slice()).await.map_err(be)?;
    Ok(Merge::normal(TreeValue::File {
        id,
        executable: *executable,
        // `resolve_file_copy_id` (`builtin.rs:395-403`) of the resolved left file.
        copy_id: copy_id.clone(),
    }))
}

/// A [`MutateError::StaleSelection`] for `reason`.
fn stale(reason: String) -> MutateError {
    MutateError::StaleSelection { reason }
}

/// Keys on a changed path that has no sections — an added or deleted file, a mode change, binary
/// content, a symlink, a submodule or a conflict.
fn whole_only(path: &RepoPath) -> MutateError {
    stale(format!("{} can only be selected whole", path.as_internal_file_string()))
}

/// A key that is not one of `path`'s current sections.
fn stale_key(path: &RepoPath, key: &HunkKey) -> MutateError {
    stale(format!(
        "The selected hunk -{},{} +{},{} is not a current section of {}",
        key.old_start,
        key.old_count,
        key.new_start,
        key.new_count,
        path.as_internal_file_string()
    ))
}

/// A file's content.
async fn read_file(store: &Store, path: &RepoPath, id: &FileId) -> Result<Vec<u8>, MutateError> {
    let mut content = Vec::new();
    store
        .read_file(path, id)
        .await
        .map_err(be)?
        .read_to_end(&mut content)
        .await
        .map_err(be)?;
    Ok(content)
}

/// The builtin editor's text test (`buf_to_file_contents`, `builtin.rs:107-122`): no NUL byte and
/// valid UTF-8.
fn is_text(content: &[u8]) -> bool {
    !content.contains(&0) && std::str::from_utf8(content).is_ok()
}

/// One changed section: its key and its text on each side.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Section<'a> {
    /// Where it sits.
    pub(crate) key: HunkKey,
    /// Its left-side text.
    pub(crate) left: &'a [u8],
    /// Its right-side text.
    pub(crate) right: &'a [u8],
}

/// A file's diff in order: matching text and changed sections.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Piece<'a> {
    /// Text both sides share.
    Same(&'a [u8]),
    /// A changed section.
    Changed(Section<'a>),
}

/// `make_diff_sections` (`builtin.rs:225-271` @ v0.46.0) with each section's [`HunkKey`] — the ONE
/// place the keys are cut, for the selection here and for the diff read that shows them.
pub(crate) fn sections<'a>(left: &'a [u8], right: &'a [u8]) -> Vec<Piece<'a>> {
    let diff = ContentDiff::by_line([left, right]);
    let (mut old_line, mut new_line) = (0_u32, 0_u32);
    let mut pieces = Vec::new();
    for hunk in diff.hunks() {
        match hunk.kind {
            DiffHunkKind::Matching => {
                let text: &'a [u8] = hunk.contents[0].as_ref();
                let lines = line_count(text);
                old_line = old_line.saturating_add(lines);
                new_line = new_line.saturating_add(lines);
                pieces.push(Piece::Same(text));
            }
            DiffHunkKind::Different => {
                let left: &'a [u8] = hunk.contents[0].as_ref();
                let right: &'a [u8] = hunk.contents[1].as_ref();
                let key = HunkKey {
                    old_start: old_line,
                    old_count: line_count(left),
                    new_start: new_line,
                    new_count: line_count(right),
                };
                old_line = old_line.saturating_add(key.old_count);
                new_line = new_line.saturating_add(key.new_count);
                pieces.push(Piece::Changed(Section { key, left, right }));
            }
        }
    }
    pieces
}

/// The lines of `text` as `split_inclusive('\n')` cuts them.
fn line_count(text: &[u8]) -> u32 {
    u32::try_from(text.split_inclusive(|&b| b == b'\n').count()).unwrap_or(u32::MAX)
}

/// The file the choice yields: matching text, the right side of each selected section and the left
/// side of the others.
pub(crate) fn assemble(pieces: &[Piece<'_>], selected: &HashSet<HunkKey>) -> Vec<u8> {
    let mut content = Vec::new();
    for piece in pieces {
        match piece {
            Piece::Same(text) => content.extend_from_slice(text),
            Piece::Changed(section) if selected.contains(&section.key) => content.extend_from_slice(section.right),
            Piece::Changed(section) => content.extend_from_slice(section.left),
        }
    }
    content
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::{assemble, is_text, line_count, sections, HunkKey, Piece};

    fn key(old_start: u32, old_count: u32, new_start: u32, new_count: u32) -> HunkKey {
        HunkKey {
            old_start,
            old_count,
            new_start,
            new_count,
        }
    }

    fn keys(left: &str, right: &str) -> Vec<HunkKey> {
        sections(left.as_bytes(), right.as_bytes())
            .into_iter()
            .filter_map(|piece| match piece {
                Piece::Changed(section) => Some(section.key),
                Piece::Same(_) => None,
            })
            .collect()
    }

    fn choose(left: &str, right: &str, selected: &[HunkKey]) -> String {
        let pieces = sections(left.as_bytes(), right.as_bytes());
        let selected: HashSet<HunkKey> = selected.iter().copied().collect();
        String::from_utf8(assemble(&pieces, &selected)).expect("utf-8")
    }

    const LEFT: &str = "a\nb\nc\nd\ne\n";
    const RIGHT: &str = "A\nb\nC\nd\nE\n";

    /// The spec's example: three one-line sections, keyed by their line ranges.
    #[test]
    fn three_sections_are_keyed_by_their_line_ranges() {
        assert_eq!(keys(LEFT, RIGHT), [key(0, 1, 0, 1), key(2, 1, 2, 1), key(4, 1, 4, 1)]);
    }

    /// Selecting the first and the third section keeps the second's left side.
    #[test]
    fn selecting_sections_one_and_three_keeps_the_second_on_the_left() {
        assert_eq!(
            choose(LEFT, RIGHT, &[key(0, 1, 0, 1), key(4, 1, 4, 1)]),
            "A\nb\nc\nd\nE\n"
        );
        assert_eq!(choose(LEFT, RIGHT, &[]), LEFT);
        assert_eq!(
            choose(LEFT, RIGHT, &[key(0, 1, 0, 1), key(2, 1, 2, 1), key(4, 1, 4, 1)]),
            RIGHT
        );
    }

    /// An insertion has no left lines; its start is the number of lines before it.
    #[test]
    fn an_insertion_has_no_left_lines() {
        assert_eq!(keys("a\nb\n", "a\nx\ny\nb\n"), [key(1, 0, 1, 2)]);
        assert_eq!(choose("a\nb\n", "a\nx\ny\nb\n", &[key(1, 0, 1, 2)]), "a\nx\ny\nb\n");
        assert_eq!(choose("a\nb\n", "a\nx\ny\nb\n", &[]), "a\nb\n");
    }

    /// A deletion has no right lines.
    #[test]
    fn a_deletion_has_no_right_lines() {
        assert_eq!(keys("a\nx\nb\n", "a\nb\n"), [key(1, 1, 1, 0)]);
        assert_eq!(choose("a\nx\nb\n", "a\nb\n", &[key(1, 1, 1, 0)]), "a\nb\n");
    }

    /// A last line without `\n` counts as a line.
    #[test]
    fn a_last_line_without_a_newline_counts() {
        assert_eq!(keys("a\nb", "a\nc"), [key(1, 1, 1, 1)]);
        assert_eq!(keys("a", "a\n"), [key(0, 1, 0, 1)]);
        assert_eq!(line_count(b""), 0);
        assert_eq!(line_count(b"x"), 1);
        assert_eq!(line_count(b"x\ny\n"), 2);
        assert_eq!(line_count(b"x\ny"), 2);
    }

    /// Identical texts have no sections.
    #[test]
    fn identical_texts_have_no_sections() {
        assert!(keys("a\n", "a\n").is_empty());
        assert_eq!(sections(b"", b""), Vec::<Piece<'_>>::new());
    }

    /// The builtin editor's text test: UTF-8 without a NUL byte.
    #[test]
    fn text_is_utf8_without_a_nul_byte() {
        assert!(is_text(b"plain\n"));
        assert!(is_text(b""));
        assert!(!is_text(b"a\0b"));
        assert!(!is_text(&[0xff, 0xfe]));
    }
}
