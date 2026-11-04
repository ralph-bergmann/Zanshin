// SPDX-License-Identifier: MIT

//! `resolve.rs` — `jj resolve` (Story 9.17), ported step for step from `cmd_resolve`
//! (`cli/src/commands/resolve.rs` @ v0.46.0) with the merge-tool checks of
//! `cli/src/merge_tools/mod.rs` @ v0.46.0 (`ConflictResolveError` `:87-110`, `MergeToolFile`
//! `:328-369`, `pick_conflict_side` `:473-496`).
//!
//! The CLI resolves with a merge editor; Zanshin replaces the editor (ADR-0003). `resolve_list` is
//! `--list` plus what a GUI merge editor needs per conflict — its sides and base, hunk by hunk
//! (`jj_lib::files::merge_hunks`) — and whether `resolve` can take it. `resolve` takes the
//! builtin tools `:ours` / `:theirs`, or the GUI merge editor's output per file, written as the
//! builtin merge editor writes a file (`apply_merge_builtin`, `cli/src/merge_tools/builtin.rs:
//! 734-760` @ v0.46.0): always resolved, the markers in the content are never re-parsed.
//!
//! Divergences, all deliberate:
//!
//! - no external merge tools, `ui.merge-editor` or `--tool <name>` other than `:ours` /
//!   `:theirs`: the editor is the GUI's, whose result arrives as [`ResolveTool::Files`] — so
//!   neither the external tools' partial-resolution error nor their "unchanged or empty" check;
//! - with [`ResolveTool::Files`] the files ARE the paths: a listed file that is not a conflict at
//!   the revision refuses as stale (the CLI only matches the conflicts its paths cover).

use std::collections::HashSet;

use jj_lib::backend::{CopyId, MergedTreeValue, MergedTreeValueExt as _, TreeValue};
use jj_lib::conflicts::{try_materialize_file_conflict_value, MaterializedFileConflictValue};
use jj_lib::files::{merge_hunks, MergeResult};
use jj_lib::matchers::{FilesMatcher, Matcher};
use jj_lib::merge::Merge;
use jj_lib::merged_tree::MergedTree;
use jj_lib::merged_tree_builder::MergedTreeBuilder;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use jj_lib::workspace::Workspace;

use crate::mutate::{
    be, build_matcher, finish_verb, guard_rewritable, mutation_result, res, resolve_or_wc, warn_unmatched, MutateError,
    MutationResult,
};
use crate::op_support::start_repo_transaction;
use crate::snapshot::VerbContext;
use crate::template::Templates;
use crate::warning::Warnings;
use crate::ChangeId;

/// [`crate::Repo::resolve_list`]'s arguments (Story 9.17) — `jj resolve --list`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ResolveListOptions {
    /// `-r`: the revision. `None` is `@`.
    pub revision: Option<ChangeId>,
    /// The paths to list conflicts in — repo-relative PREFIXES, as for [`crate::Repo::restore`];
    /// empty is every path.
    pub paths: Vec<String>,
}

/// What [`crate::Repo::resolve_list`] found (Story 9.17): the revision's matching conflicts, in
/// tree order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ResolveList {
    /// One entry per conflicted path.
    pub files: Vec<ConflictedFile>,
}

/// One conflicted path (Story 9.17).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConflictedFile {
    /// The repo-relative path, in jj's internal `/`-separated form.
    pub path: String,
    /// The CLI's `--list` description of the simplified conflict, e.g. `2-sided conflict` or
    /// `2-sided conflict including an executable`.
    pub description: String,
    /// The simplified conflict's number of sides.
    pub num_sides: u32,
    /// Why [`crate::Repo::resolve`] would refuse this conflict
    /// ([`MutateError::ConflictNotResolvable`]'s text); `None` = it can take it.
    pub unresolvable: Option<String>,
    /// The simplified conflict labels of a file conflict, one per term (empty = unlabeled, and
    /// for a conflict that is not a file conflict).
    pub labels: Vec<String>,
    /// A file conflict's content cut into merge hunks — `jj_lib::files::merge_hunks` over the
    /// simplified sides; empty for a conflict that is not a file conflict.
    pub hunks: Vec<ConflictHunk>,
    /// A file conflict's simplified file ids, one per term in `Merge` order (as `labels` and a
    /// conflicting hunk's `terms`), hex; `None` = no file on that term (an absent or deleted
    /// side). Empty for a conflict that is not a file conflict. [`ResolvedFile::term_ids`] sends
    /// them back as the staleness token.
    pub term_ids: Vec<Option<String>>,
}

/// One merge hunk of a file conflict (Story 9.17).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConflictHunk {
    /// The hunk's terms in jj's `Merge` order: side 1, base 1, side 2, … for a conflicting hunk;
    /// one term — the text every side shares — for a resolved one.
    pub terms: Vec<Vec<u8>>,
}

/// [`crate::Repo::resolve`]'s arguments (Story 9.17) — `jj resolve`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolveOptions {
    /// `-r`: the revision to resolve conflicts in. `None` is `@`.
    pub revision: Option<ChangeId>,
    /// The paths whose conflicts to resolve — repo-relative PREFIXES, as for
    /// [`crate::Repo::restore`]; empty is every conflict. Not with [`ResolveTool::Files`].
    pub paths: Vec<String>,
    /// What resolves them.
    pub tool: ResolveTool,
}

/// What [`crate::Repo::resolve`] resolves with (Story 9.17).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolveTool {
    /// `--tool :ours`: each conflict takes side 1.
    Ours,
    /// `--tool :theirs`: each conflict takes side 2.
    Theirs,
    /// The GUI merge editor's output: each file's resolved content. The files are the paths —
    /// each a conflict at the revision, each listed once.
    Files(Vec<ResolvedFile>),
}

/// One file the GUI merge editor resolved (Story 9.17).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedFile {
    /// The repo-relative path, in jj's internal `/`-separated form — the form
    /// [`ConflictedFile::path`] reports.
    pub path: String,
    /// Its resolved content, written as is.
    pub content: Vec<u8>,
    /// The conflict's [`ConflictedFile::term_ids`] the content was composed from. Required: the
    /// verb refuses [`MutateError::StaleSelection`] when the conflict at the path changed since.
    pub term_ids: Vec<Option<String>>,
}

/// What `jj resolve` refuses before the snapshot (Story 9.17): [`ResolveTool::Files`] together
/// with `paths`, or without files, or with an invalid, root or duplicate path, or a file without
/// its term ids.
///
/// # Errors
///
/// [`MutateError::InvalidInput`].
pub(crate) fn check_resolve_args(options: &ResolveOptions) -> Result<(), MutateError> {
    let ResolveTool::Files(files) = &options.tool else {
        return Ok(());
    };
    if !options.paths.is_empty() {
        return Err(MutateError::invalid(
            "paths cannot be combined with resolved files: the files are the paths".to_owned(),
        ));
    }
    if files.is_empty() {
        return Err(MutateError::invalid("resolved files need at least one file".to_owned()));
    }
    parse_files(files)?;
    if let Some(file) = files.iter().find(|file| file.term_ids.is_empty()) {
        return Err(MutateError::invalid(format!(
            "resolved file {} needs the term ids resolve_list reported",
            file.path
        )));
    }
    Ok(())
}

/// The resolved files' paths, parsed — each a file path (not the root) given at most once.
fn parse_files(files: &[ResolvedFile]) -> Result<Vec<RepoPathBuf>, MutateError> {
    let mut seen = HashSet::new();
    let mut parsed = Vec::with_capacity(files.len());
    for file in files {
        let path = RepoPathBuf::from_internal_string(file.path.as_str())
            .map_err(|e| MutateError::invalid(format!("invalid path {:?}: {e}", file.path)))?;
        if path.is_root() {
            return Err(MutateError::invalid(
                "a resolved file needs a path, not the root".to_owned(),
            ));
        }
        if !seen.insert(path.clone()) {
            return Err(MutateError::invalid(format!("path resolved twice: {}", file.path)));
        }
        parsed.push(path);
    }
    Ok(parsed)
}

/// The conflicts of `tree` that `matcher` covers, after the CLI's unmatched-paths warning over
/// `[&tree]` (`explicit`, its explicit paths) — refused [`MutateError::NoConflicts`] when there
/// are none (`resolve.rs:83-98` @ v0.46.0).
fn matched_conflicts(
    workspace: &Workspace,
    warnings: &mut Warnings,
    tree: &MergedTree,
    matcher: &dyn Matcher,
    explicit: &[String],
) -> Result<Vec<(RepoPathBuf, MergedTreeValue)>, MutateError> {
    let conflicts = futures::executor::block_on_stream(tree.conflicts_matching(matcher))
        .map(|(path, value)| value.map(|value| (path, value)))
        .collect::<Result<Vec<_>, _>>()
        .map_err(be)?;
    warn_unmatched(workspace, warnings, explicit, &[tree])?;
    if conflicts.is_empty() {
        let message = if explicit.is_empty() {
            "No conflicts found at this revision"
        } else {
            "No conflicts found at the given path(s)"
        };
        return Err(MutateError::NoConflicts {
            message: message.to_owned(),
        });
    }
    Ok(conflicts)
}

/// `MergeToolFile::from_tree_and_path`'s checks (`mod.rs:333-369` @ v0.46.0) on the conflict
/// `conflict` at `path` of `tree`: the materialized file conflict when there is one, and the
/// `ConflictResolveError` text a merge tool refuses it with (`None` = it can take it).
async fn check_conflict(
    tree: &MergedTree,
    path: &RepoPath,
    conflict: &MergedTreeValue,
) -> Result<(Option<MaterializedFileConflictValue>, Option<String>), MutateError> {
    let file = try_materialize_file_conflict_value(tree.store(), path, conflict, tree.labels())
        .await
        .map_err(be)?;
    let summary = || conflict.describe(tree.labels()).trim_end().to_owned();
    let refusal = match &file {
        None => Some(format!(
            "Only conflicts that involve normal files (not symlinks, etc.) are supported. Conflict summary for \
             {path:?}:\n{}",
            summary()
        )),
        Some(file) if file.ids.num_sides() > 2 => Some(format!(
            "The conflict at {path:?} has {} sides. At most 2 sides are supported.",
            file.ids.num_sides()
        )),
        Some(file) if file.executable.is_none() => {
            Some(format!("{path:?} has conflicts in executable bit\n{}", summary()))
        }
        Some(_) => None,
    };
    Ok((file, refusal))
}

/// A count as the payload's `u32`, saturating.
fn count(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

/// `jj resolve --list` (Story 9.17) — see [`crate::Repo::resolve_list`].
///
/// # Errors
///
/// See [`crate::Repo::resolve_list`].
pub(crate) fn resolve_list(
    workspace: &Workspace,
    warnings: &mut Warnings,
    prefixes: &jj_lib::id_prefix::IdPrefixContext,
    options: &ResolveListOptions,
) -> Result<ResolveList, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let repo: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let matcher = build_matcher(&options.paths)?;
    let commit =
        crate::op_support::resolve_or_wc(repo, workspace.workspace_name(), prefixes, options.revision.as_ref())
            .map_err(|e| res(e, options.revision.as_ref()))?;
    let tree = commit.tree();
    let conflicts = matched_conflicts(workspace, warnings, &tree, matcher.as_ref(), &options.paths)?;
    let merge_options = repo.store().merge_options();
    let mut files = Vec::with_capacity(conflicts.len());
    for (path, conflict) in conflicts {
        let (file, unresolvable) = pollster::block_on(check_conflict(&tree, &path, &conflict))?;
        let simplified = conflict.simplify();
        let (labels, hunks, term_ids) = match file {
            Some(file) => (
                file.labels.as_slice().to_vec(),
                conflict_hunks(merge_hunks(&file.contents, merge_options)),
                term_ids(&file),
            ),
            None => (Vec::new(), Vec::new(), Vec::new()),
        };
        files.push(ConflictedFile {
            path: path.as_internal_file_string().to_owned(),
            description: crate::warning::conflict_description(&simplified),
            num_sides: count(simplified.num_sides()),
            unresolvable,
            labels,
            hunks,
            term_ids,
        });
    }
    Ok(ResolveList { files })
}

/// A materialized file conflict's simplified file ids as hex, `None` = no file on that term.
fn term_ids(file: &MaterializedFileConflictValue) -> Vec<Option<String>> {
    file.ids
        .iter()
        .map(|id| id.as_ref().map(jj_lib::object_id::ObjectId::hex))
        .collect()
}

/// `merge_hunks`' result as hunks of terms in `Merge` order.
fn conflict_hunks(result: MergeResult) -> Vec<ConflictHunk> {
    match result {
        MergeResult::Resolved(content) => vec![ConflictHunk {
            terms: vec![content.into()],
        }],
        MergeResult::Conflict(hunks) => hunks
            .into_iter()
            .map(|hunk| ConflictHunk {
                terms: hunk.into_iter().map(Into::into).collect(),
            })
            .collect(),
    }
}

/// `MergeToolFile::from_tree_and_path` (`mod.rs:333-369` @ v0.46.0) for a path `resolve` works
/// on: a path that is not a conflict is a stale selection (only [`ResolveTool::Files`] names one),
/// and so is a conflict whose term ids are no longer `expected` (the GUI's files send them; the
/// tools pass `None`); a conflict a merge tool cannot take [`MutateError::ConflictNotResolvable`].
async fn merge_tool_file(
    tree: &MergedTree,
    path: &RepoPath,
    expected: Option<&[Option<String>]>,
) -> Result<MaterializedFileConflictValue, MutateError> {
    let conflict = match tree.path_value(path).await.map_err(be)?.into_resolved() {
        Err(conflict) => conflict,
        Ok(Some(_)) => {
            return Err(MutateError::StaleSelection {
                reason: format!("Couldn't find any conflicts at {path:?} in this revision"),
            });
        }
        Ok(None) => {
            return Err(MutateError::StaleSelection {
                reason: format!("Couldn't find the path {path:?} in this revision"),
            });
        }
    };
    let checked = check_conflict(tree, path, &conflict).await?;
    if let Some(expected) = expected {
        if checked.0.as_ref().map(term_ids).as_deref() != Some(expected) {
            return Err(MutateError::StaleSelection {
                reason: format!("The conflict at {path:?} changed since it was listed: re-read it and resolve again"),
            });
        }
    }
    match checked {
        (Some(file), None) => Ok(file),
        (_, refusal) => Err(MutateError::ConflictNotResolvable {
            message: refusal.unwrap_or_default(),
        }),
    }
}

/// `jj resolve` (Story 9.17) — see [`crate::Repo::resolve`]. The arguments were checked by
/// [`check_resolve_args`].
///
/// # Errors
///
/// See [`crate::Repo::resolve`].
pub(crate) fn resolve(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &ResolveOptions,
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);

    // With resolved files the files are the paths, matched exactly.
    let (matcher, explicit): (Box<dyn Matcher>, Vec<String>) = match &options.tool {
        ResolveTool::Files(files) => (
            Box::new(FilesMatcher::new(parse_files(files)?)),
            files.iter().map(|file| file.path.clone()).collect(),
        ),
        ResolveTool::Ours | ResolveTool::Theirs => (build_matcher(&options.paths)?, options.paths.clone()),
    };
    // Built from the fields, not `ctx.templates`, so `ctx.warnings` stays borrowable meanwhile.
    let templates = Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, workspace);
    let commit = resolve_or_wc(
        tx.repo(),
        &workspace_name,
        templates.prefixes(),
        options.revision.as_ref(),
    )?;
    let tree = commit.tree();
    let conflicts = matched_conflicts(workspace, &mut ctx.warnings, &tree, matcher.as_ref(), &explicit)?;
    guard_rewritable(&tx, &templates, std::slice::from_ref(commit.id()))?;

    let new_tree = pollster::block_on(resolved_tree(&tree, &conflicts, &options.tool))?;
    let new_commit =
        pollster::block_on(tx.repo_mut().rewrite_commit(&commit).set_tree(new_tree).write()).map_err(be)?;
    // A descendant pass MUST precede the commit (see `restore`).
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let finish = finish_verb(
        workspace,
        tx,
        &format!("Resolve conflicts in commit {}", commit.id().hex()),
        ctx,
    )?;
    // `resolve.rs:126-140`: for `@` the finish's checkout lists the remaining conflicts.
    if finish.wc_commit.as_ref().map(jj_lib::commit::Commit::id) != Some(new_commit.id()) {
        ctx.warnings
            .extend(crate::warning::resolve_conflicts_remain(workspace.workspace_root(), &new_commit).map_err(be)?);
    }
    Ok(mutation_result(&finish, Vec::new(), Vec::new()))
}

/// The tree `tool` makes of `tree`'s `conflicts` — `pick_conflict_side` (`mod.rs:473-496` @
/// v0.46.0) for `:ours` / `:theirs`, `apply_merge_builtin`'s write (`builtin.rs:734-760`) for the
/// GUI's files.
async fn resolved_tree(
    tree: &MergedTree,
    conflicts: &[(RepoPathBuf, MergedTreeValue)],
    tool: &ResolveTool,
) -> Result<MergedTree, MutateError> {
    let paths = match tool {
        ResolveTool::Files(files) => parse_files(files)?,
        ResolveTool::Ours | ResolveTool::Theirs => conflicts.iter().map(|(path, _)| path.clone()).collect(),
    };
    // `edit_files` checks every file before the tool runs.
    let mut checked = Vec::with_capacity(paths.len());
    for (index, path) in paths.into_iter().enumerate() {
        let expected = match tool {
            ResolveTool::Files(files) => Some(files[index].term_ids.as_slice()),
            ResolveTool::Ours | ResolveTool::Theirs => None,
        };
        let file = merge_tool_file(tree, &path, expected).await?;
        checked.push((path, file));
    }
    let mut builder = MergedTreeBuilder::new(tree.clone());
    for (index, (path, file)) in checked.into_iter().enumerate() {
        // The check refused a conflict in the executable bit.
        let executable = file.executable.unwrap_or_default();
        let value = match tool {
            ResolveTool::Ours | ResolveTool::Theirs => {
                let add_index = usize::from(matches!(tool, ResolveTool::Theirs));
                let file_id = file.ids.get_add(add_index).cloned().flatten();
                Merge::resolved(file_id.map(|id| TreeValue::File {
                    id,
                    executable,
                    copy_id: CopyId::placeholder(),
                }))
            }
            ResolveTool::Files(files) => {
                let id = tree
                    .store()
                    .write_file(&path, &mut files[index].content.as_slice())
                    .await
                    .map_err(be)?;
                let value = tree.path_value(&path).await.map_err(be)?;
                let copy_id = crate::select_tree::resolve_file_copy_id(&value).unwrap_or_else(CopyId::placeholder);
                Merge::normal(TreeValue::File {
                    id,
                    executable,
                    copy_id,
                })
            }
        };
        builder.set_or_remove_merge(path, value).map_err(be)?;
    }
    builder.write_tree().await.map_err(be)
}

#[cfg(test)]
mod tests {
    use jj_lib::files::MergeResult;
    use jj_lib::merge::Merge;

    use super::{check_resolve_args, conflict_hunks, count, ResolveOptions, ResolveTool, ResolvedFile};
    use crate::MutateError;

    fn file(path: &str) -> ResolvedFile {
        ResolvedFile {
            path: path.to_owned(),
            content: b"x\n".to_vec(),
            term_ids: vec![Some("00".to_owned()), None, Some("01".to_owned())],
        }
    }

    fn files(files: Vec<ResolvedFile>, paths: &[&str]) -> ResolveOptions {
        ResolveOptions {
            revision: None,
            paths: paths.iter().map(|p| (*p).to_owned()).collect(),
            tool: ResolveTool::Files(files),
        }
    }

    fn refusal(options: &ResolveOptions) -> String {
        let err = check_resolve_args(options).expect_err("refused");
        assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
        err.to_string()
    }

    #[test]
    fn the_tools_take_any_paths_and_files_refuse_paths_empty_root_invalid_and_duplicates() {
        for tool in [ResolveTool::Ours, ResolveTool::Theirs] {
            let options = ResolveOptions {
                revision: None,
                paths: vec!["a".to_owned()],
                tool,
            };
            check_resolve_args(&options).expect("a tool takes paths");
        }
        check_resolve_args(&files(vec![file("a"), file("b/c")], &[])).expect("files");
        assert!(refusal(&files(vec![file("a")], &["a"])).contains("the files are the paths"));
        assert!(refusal(&files(vec![], &[])).contains("at least one file"));
        assert!(refusal(&files(vec![file("")], &[])).contains("not the root"));
        assert!(refusal(&files(vec![file("/a")], &[])).contains("invalid path"));
        assert!(refusal(&files(vec![file("a"), file("a")], &[])).contains("path resolved twice: a"));
        let no_ids = ResolvedFile {
            term_ids: Vec::new(),
            ..file("b")
        };
        assert!(refusal(&files(vec![file("a"), no_ids], &[]))
            .contains("resolved file b needs the term ids resolve_list reported"));
    }

    #[test]
    fn a_resolved_merge_is_one_hunk_of_one_term_and_a_conflict_keeps_merge_order() {
        assert_eq!(
            conflict_hunks(MergeResult::Resolved("same\n".into()))
                .into_iter()
                .map(|hunk| hunk.terms)
                .collect::<Vec<_>>(),
            [vec![b"same\n".to_vec()]]
        );
        let hunks = conflict_hunks(MergeResult::Conflict(vec![
            Merge::resolved("top\n".into()),
            Merge::from_vec(vec!["ours\n".into(), "base\n".into(), "theirs\n".into()]),
        ]));
        assert_eq!(
            hunks.into_iter().map(|hunk| hunk.terms).collect::<Vec<_>>(),
            [
                vec![b"top\n".to_vec()],
                vec![b"ours\n".to_vec(), b"base\n".to_vec(), b"theirs\n".to_vec()],
            ]
        );
    }

    #[test]
    fn count_saturates() {
        assert_eq!(count(3), 3);
        assert_eq!(count(usize::MAX), u32::MAX);
    }
}
