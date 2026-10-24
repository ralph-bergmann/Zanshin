// SPDX-License-Identifier: MIT

//! `diffedit.rs` — `jj diffedit` (Story 9.17), ported step for step from `cmd_diffedit`
//! (`cli/src/commands/diffedit.rs` @ v0.46.0).
//!
//! The CLI runs a diff editor over `Diff(base, target)`; Zanshin replaces the editor (ADR-0003).
//! With the default `ui.diff-editor = ":builtin"` the editor IS `apply_diff_builtin(base, target,
//! choice)` — [`crate::Repo::select_tree`]'s build — so the verb takes the tree that call returned,
//! a [`TreeSelection`], and refuses it as stale when the base tree is no longer its `left`.
//!
//! Divergences, all deliberate:
//!
//! - no `--tool`, no `ui.diff-editor` and no editor instructions: the editor is the GUI's;
//! - no `paths`: the tree already holds the selection (Story 9.50's rule), so neither the
//!   matcher nor the unmatched-paths warning.

use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::rewrite::merge_commit_trees;
use jj_lib::workspace::Workspace;

use crate::mutate::{
    be, finish_verb, guard_rewritable, mutation_result, no_op_result, resolve_or_wc, MutateError, MutationResult,
};
use crate::op_support::{start_repo_transaction, SelectedTree};
use crate::select_tree::{check_left, check_tree_selection};
use crate::snapshot::VerbContext;
use crate::{ChangeId, TreeSelection};

/// [`crate::Repo::diffedit`]'s arguments (Story 9.17) — the CLI's `jj diffedit` flags this verb
/// ports. `revision` conflicts with `from` and `to`, as in the CLI.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DiffeditOptions {
    /// `-r`: the revision to touch up, diffed against its parents. `None` (with neither `from`
    /// nor `to`) is `@`.
    pub revision: Option<ChangeId>,
    /// `--from`: the revision whose tree is the diff's base. `None` with `to` given is `@`.
    pub from: Option<ChangeId>,
    /// `--to`: the revision to touch up, diffed against `from`. `None` with `from` given is `@`.
    pub to: Option<ChangeId>,
    /// The edited tree: what [`crate::Repo::select_tree`] returned for the target, and the `left`
    /// it was selected against. In the `from`/`to` form pass [`crate::SelectTreeOptions::from`] =
    /// `from` — or `@`'s change id when only `to` is given, since the base is then `@`'s tree.
    pub tree: TreeSelection,
    /// `--restore-descendants`: descendants keep their content, not their diff.
    pub restore_descendants: bool,
}

/// What `jj diffedit` refuses before the snapshot (Story 9.17): `revision` together with `from`
/// or `to` (clap's `conflicts_with`), or a tree of the wrong shape.
///
/// # Errors
///
/// [`MutateError::InvalidInput`].
pub(crate) fn check_diffedit_args(options: &DiffeditOptions) -> Result<(), MutateError> {
    if options.revision.is_some() && (options.from.is_some() || options.to.is_some()) {
        return Err(MutateError::invalid(
            "`revision` cannot be combined with `from`/`to`".to_owned(),
        ));
    }
    check_tree_selection(&options.tree)
}

/// `jj diffedit` (Story 9.17) — see [`crate::Repo::diffedit`]. The arguments were checked by
/// [`check_diffedit_args`].
///
/// # Errors
///
/// See [`crate::Repo::diffedit`].
pub(crate) fn diffedit(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &DiffeditOptions,
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);

    // `diffedit.rs:98-120`: `to` (or `@`) against `[from or @]`, else the revision against its
    // parents.
    let (target, base_commits) = if options.from.is_some() || options.to.is_some() {
        let target = resolve_or_wc(tx.repo(), &workspace_name, options.to.as_ref())?;
        let from = resolve_or_wc(tx.repo(), &workspace_name, options.from.as_ref())?;
        (target, vec![from])
    } else {
        let target = resolve_or_wc(tx.repo(), &workspace_name, options.revision.as_ref())?;
        let parents = pollster::block_on(target.parents()).map_err(be)?;
        (target, parents)
    };
    guard_rewritable(&tx, &ctx.templates(workspace), std::slice::from_ref(target.id()))?;

    let base_tree = pollster::block_on(merge_commit_trees(tx.repo(), &base_commits)).map_err(be)?;
    check_left(&base_tree, &options.tree.left)?;
    let edited = SelectedTree::from_tree_id(tx.repo().store(), &options.tree.tree)?;
    if edited.tree().tree_ids() == target.tree_ids() {
        // "Nothing changed."
        drop(tx);
        return no_op_result(&workspace_name, &readonly);
    }
    pollster::block_on(
        tx.repo_mut()
            .rewrite_commit(&target)
            .set_tree(edited.tree().clone())
            .write(),
    )
    .map_err(be)?;
    // `rebase_or_reparent_descendants` (`cli_util.rs:3418-3440`), before the finish.
    if options.restore_descendants {
        pollster::block_on(tx.repo_mut().reparent_descendants()).map_err(be)?;
    } else {
        pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    }
    let finish = finish_verb(workspace, tx, &format!("edit commit {}", target.id().hex()), ctx)?;
    Ok(mutation_result(&finish, Vec::new(), Vec::new()))
}

#[cfg(test)]
mod tests {
    use super::{check_diffedit_args, DiffeditOptions};
    use crate::{ChangeId, MutateError, SelectedTreeId, TreeSelection};

    fn tree() -> TreeSelection {
        TreeSelection {
            tree: SelectedTreeId {
                tree_ids: vec!["00".to_owned()],
                labels: Vec::new(),
            },
            left: vec!["00".to_owned()],
        }
    }

    fn is_invalid(options: &DiffeditOptions) -> bool {
        matches!(check_diffedit_args(options), Err(MutateError::InvalidInput { .. }))
    }

    #[test]
    fn revision_conflicts_with_from_and_to_and_the_tree_must_parse() {
        let id = || Some(ChangeId("k".to_owned()));
        let ok = DiffeditOptions {
            tree: tree(),
            ..Default::default()
        };
        check_diffedit_args(&ok).expect("a tree alone");
        check_diffedit_args(&DiffeditOptions {
            revision: id(),
            ..ok.clone()
        })
        .expect("revision");
        check_diffedit_args(&DiffeditOptions {
            from: id(),
            to: id(),
            ..ok.clone()
        })
        .expect("from and to");
        assert!(is_invalid(&DiffeditOptions {
            revision: id(),
            from: id(),
            ..ok.clone()
        }));
        assert!(is_invalid(&DiffeditOptions {
            revision: id(),
            to: id(),
            ..ok.clone()
        }));
        assert!(is_invalid(&DiffeditOptions::default()), "an empty tree");
    }
}
