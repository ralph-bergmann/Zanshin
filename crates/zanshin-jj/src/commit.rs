// SPDX-License-Identifier: MIT

//! `commit.rs` — `jj commit` (Story 9.49), ported step for step from `cmd_commit`
//! (`cli/src/commands/commit.rs:83-196` @ v0.46.0) with the advance-bookmarks helpers of
//! `cli/src/cli_util.rs` @ v0.46.0 (`load_advance_bookmarks_matcher` `:921-940`,
//! `get_advanceable_bookmarks` `:2678-2701`, `advance_bookmarks` `:2880-2898`). Terminal text is
//! not ported; the one `ui.warning_default` line becomes the call's warning. The four advance
//! items are `pub(crate)`: `jj new` with one parent shares them ([`crate::mutate::new_change`],
//! Story 9.49 closing run), as the CLI's `cmd_new` shares the `cli_util` helpers.
//!
//! `@` is rewritten in place with the selected changes and the `-m` description, a new `@` is
//! created on top of it with the old `@`'s full tree, and the bookmarks
//! `experimental-advance-branches` selects move from `@`'s parents to the committed `@`. The
//! selection is by PATHS — each entry is a repo-relative PREFIX through
//! [`crate::op_support::build_matcher`] (an empty list is everything, `""` the root), exactly as
//! for `restore`; the fileset DSL is terminal input language (ADR-0003) — or, in place of the
//! CLI's `--interactive`/`--tool`, a tree the GUI selected ([`crate::Repo::select_tree`], Story
//! 9.50), refused as stale when `@`'s parent tree is no longer its `left`.
//!
//! Divergences, all deliberate:
//!
//! - no `--interactive`, no `--tool`: their diff editor is the GUI's, whose result arrives as the
//!   tree arm; paths together with a tree refuse;
//! - no editor arm and no `--editor`: `-m` is required (the GUI always passes it), so there is no
//!   "editor saved unchanged" case and no empty-message hint; a non-empty `-m` gets
//!   `templates.commit_trailers` (Story 9.51, [`crate::template`]);
//! - no hints.

use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::merge::Diff;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::RefTarget;
use jj_lib::ref_name::RefNameBuf;
use jj_lib::repo::{MutableRepo, Repo as _};
use jj_lib::str_util::StringMatcher;
use jj_lib::view::View;
use jj_lib::workspace::Workspace;

use crate::bookmark_ops::union_expression;
use crate::mutate::{be, build_matcher, cfg, finish_verb, mutation_result, MutateError, MutationResult};
use crate::op_support::{join_message_paragraphs, start_repo_transaction, SelectedTree};
use crate::select_tree::{check_left, check_tree_selection, PATHS_WITH_TREE};
use crate::snapshot::VerbContext;
use crate::template::Templates;
use crate::warning::WarningKind;
use crate::ChangeId;

/// [`crate::Repo::commit`]'s arguments — the CLI's `jj commit` flags this verb ports, one field
/// each (Story 9.49).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CommitOptions {
    /// The paths whose changes stay in the committed `@` — repo-relative PREFIXES; empty is
    /// every path (the CLI's "describe + new").
    pub paths: Vec<String>,
    /// `-m`, repeatable: the paragraphs of the committed `@`'s description, joined like the CLI
    /// joins them. Required — an empty list is `-m ""`.
    pub message: Vec<String>,
    /// The tree arm (Story 9.50): the tree the committed `@` gets, selected in the GUI against
    /// `@`'s parent tree — the CLI's `--interactive`/`--tool` result. Conflicts with `paths`.
    pub tree: Option<crate::TreeSelection>,
}

/// What `jj commit` refuses before the snapshot (Story 9.50): `paths` together with a selected
/// tree, or a tree arm of the wrong shape — as the CLI parses its arguments before it snapshots.
///
/// # Errors
///
/// [`MutateError::InvalidInput`].
pub(crate) fn check_commit_args(options: &CommitOptions) -> Result<(), MutateError> {
    let Some(selection) = &options.tree else {
        return Ok(());
    };
    if !options.paths.is_empty() {
        return Err(MutateError::invalid(PATHS_WITH_TREE.to_owned()));
    }
    check_tree_selection(selection)
}

/// A local bookmark eligible to advance — the CLI's `AdvanceableBookmark`: its name and the
/// commit it moves away from. Shared by `commit` and `new`.
pub(crate) struct AdvanceableBookmark {
    name: RefNameBuf,
    old_commit_id: JjCommitId,
}

/// `load_advance_bookmarks_matcher` (`cli_util.rs:921-940` @ v0.46.0) over the two lists
/// [`crate::config::advance_branches`] read: both are parsed as unioned name patterns, and an
/// empty `enabled` is the feature off (`None`); otherwise the matcher is enabled ∩ ¬disabled.
/// Shared by `commit` and `new`.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — a pattern of either list does not parse.
pub(crate) fn advance_bookmarks_matcher(
    enabled: &[String],
    disabled: &[String],
) -> Result<Option<StringMatcher>, MutateError> {
    let enabled_expr = union_expression(enabled)?;
    let disabled_expr = union_expression(disabled)?;
    if enabled.is_empty() {
        return Ok(None);
    }
    Ok(Some(enabled_expr.intersection(disabled_expr.negated()).to_matcher()))
}

/// `get_advanceable_bookmarks` (`cli_util.rs:2678-2701` @ v0.46.0): the local bookmarks on the
/// `from` commits whose name `matcher` matches, in `from` order. Shared by `commit` and `new`.
pub(crate) fn advanceable_bookmarks(
    view: &View,
    matcher: Option<&StringMatcher>,
    from: &[JjCommitId],
) -> Vec<AdvanceableBookmark> {
    let Some(matcher) = matcher else {
        return Vec::new();
    };
    let mut bookmarks = Vec::new();
    for from_commit in from {
        for (name, _) in view.local_bookmarks_for_commit(from_commit) {
            if matcher.is_match(name.as_str()) {
                bookmarks.push(AdvanceableBookmark {
                    name: name.to_owned(),
                    old_commit_id: from_commit.clone(),
                });
            }
        }
    }
    bookmarks
}

/// `advance_bookmarks` (`cli_util.rs:2880-2898` @ v0.46.0): each bookmark's old commit is
/// replaced by `move_to` in its target — a conflicted bookmark stays conflicted. Shared by
/// `commit` and `new`.
///
/// # Errors
///
/// - [`MutateError::Backend`] — an index failure while merging a target.
pub(crate) fn advance_bookmarks(
    repo: &mut MutableRepo,
    bookmarks: Vec<AdvanceableBookmark>,
    move_to: &JjCommitId,
) -> Result<(), MutateError> {
    for bookmark in bookmarks {
        pollster::block_on(repo.merge_local_bookmark(
            &bookmark.name,
            &RefTarget::normal(bookmark.old_commit_id),
            &RefTarget::normal(move_to.clone()),
        ))
        .map_err(be)?;
    }
    Ok(())
}

/// `jj commit` (Story 9.49) — see [`crate::Repo::commit`].
///
/// # Errors
///
/// See [`crate::Repo::commit`].
pub(crate) fn commit(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &CommitOptions,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();

    // `commit.rs:90-98`: the working copy, the matcher, then the advanceable bookmarks — all
    // before the transaction.
    let wc_id = readonly
        .view()
        .get_wc_commit_id(&workspace_name)
        .ok_or(MutateError::NoWorkingCopy)?;
    let wc_commit = readonly.store().get_commit(wc_id).map_err(be)?;
    let matcher = build_matcher(&options.paths)?;
    let (enabled, disabled) = crate::config::advance_branches(&ctx.config).map_err(cfg)?;
    let advance_matcher = advance_bookmarks_matcher(&enabled, &disabled)?;
    let advanceable = advanceable_bookmarks(readonly.view(), advance_matcher.as_ref(), wc_commit.parent_ids());

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    // `commit.rs:103-134`: the selection starts from `@`'s PARENT tree.
    let base_tree = pollster::block_on(wc_commit.parent_tree(tx.repo())).map_err(be)?;
    let labels = Diff::new(
        pollster::block_on(wc_commit.parents_conflict_label()).map_err(be)?,
        wc_commit.conflict_label(),
    );
    let wc_tree = wc_commit.tree();
    let selected = if let Some(selection) = &options.tree {
        check_left(&base_tree, &selection.left)?;
        SelectedTree::from_tree_id(tx.repo().store(), &selection.tree)?
    } else {
        SelectedTree::from_paths(Diff::new(&base_tree, &wc_tree), labels, matcher.as_ref())?
    };
    let tree = selected.tree().clone();
    if !options.paths.is_empty() && tree.tree_ids() == base_tree.tree_ids() {
        ctx.warnings.push(
            WarningKind::CommitPathsUnmatched,
            format!("The given paths do not match any file: {}", options.paths.join(" ")),
        );
    }

    // `commit.rs:136-175`: `@` rewritten in place — same change id, the rewrite recorded.
    let mut builder = tx.repo_mut().rewrite_commit(&wc_commit).detach();
    builder.set_tree(tree);
    builder.set_description(join_message_paragraphs(&options.message));
    // `commit.rs:148-153`: a non-empty `-m` gets the trailers (`use_editor` is false).
    if !builder.description().is_empty() {
        let templates = Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, workspace);
        let description = templates.add_trailers(tx.repo(), &builder, &mut ctx.warnings)?;
        builder.set_description(description);
    }
    let committed = pollster::block_on(builder.write(tx.repo_mut())).map_err(be)?;

    // `commit.rs:177-192`. The CLI guards this block with "some workspace's `@` is the old
    // `@`"; this workspace's own `@` is it, so the list is never empty here.
    let workspace_names = tx.repo().view().workspaces_for_wc_commit_id(wc_commit.id());
    let new_wc_commit = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![committed.id().clone()], wc_commit.tree())
            .write(),
    )
    .map_err(be)?;
    advance_bookmarks(tx.repo_mut(), advanceable, committed.id())?;
    for name in workspace_names {
        pollster::block_on(tx.repo_mut().edit(name, &new_wc_commit)).map_err(be)?;
    }

    // The shared finish runs `tx.finish`'s `rebase_mutable_descendants` (`cli_util.rs:2855` @
    // v0.46.0): immutable descendants stay where they are. `commit` has no rewritability guard, so
    // an immutable `@` CAN have immutable descendants here (unlike the guarded verbs).
    let description = format!("commit {}", wc_commit.id().hex());
    let finish = finish_verb(workspace, tx, &description, ctx)?;
    mutation_result(
        &finish,
        vec![ChangeId(new_wc_commit.change_id().reverse_hex())],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests {
    use super::{advance_bookmarks_matcher, MutateError};

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|&v| v.to_owned()).collect()
    }

    /// An empty `enabled-branches` is the feature off, whatever `disabled-branches` holds.
    #[test]
    fn an_empty_enabled_list_advances_nothing() {
        assert!(advance_bookmarks_matcher(&[], &[]).expect("parses").is_none());
        assert!(advance_bookmarks_matcher(&[], &strings(&["main"]))
            .expect("parses")
            .is_none());
    }

    /// The matcher is enabled ∩ ¬disabled, bare words being globs.
    #[test]
    fn the_matcher_is_enabled_minus_disabled() {
        let matcher = advance_bookmarks_matcher(&strings(&["*"]), &strings(&["main", "release-*"]))
            .expect("parses")
            .expect("enabled");
        assert!(matcher.is_match("feature"));
        assert!(!matcher.is_match("main"));
        assert!(!matcher.is_match("release-1"));
        let exact = advance_bookmarks_matcher(&strings(&["exact:b-mark"]), &[])
            .expect("parses")
            .expect("enabled");
        assert!(exact.is_match("b-mark"));
        assert!(!exact.is_match("b-mark2"));
    }

    /// A bad pattern refuses in either list — the CLI parses both before it looks at
    /// `enabled`'s emptiness.
    #[test]
    fn a_bad_pattern_in_either_list_refuses() {
        let err = advance_bookmarks_matcher(&strings(&["glob:["]), &[]).expect_err("bad enabled");
        assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
        let err = advance_bookmarks_matcher(&[], &strings(&["bogus:x"])).expect_err("bad disabled");
        assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    }
}
