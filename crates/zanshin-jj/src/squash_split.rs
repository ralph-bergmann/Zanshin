// SPDX-License-Identifier: MIT

//! `squash_split.rs` — `jj squash` and `jj split` (Story 9.15), ported step for step from
//! `cmd_squash` (`cli/src/commands/squash.rs:184-458` @ v0.46.0) and `cmd_split`
//! (`cli/src/commands/split.rs:201-598` @ v0.46.0), with the description rules of
//! `cli/src/description_util.rs` @ v0.46.0. Terminal text is not ported; the two
//! `ui.warning_default` lines of `split` become the call's warnings.
//!
//! Both verbs select by PATHS only: each entry is a repo-relative PREFIX through
//! [`crate::op_support::build_matcher`] (an empty list is everything, `""` the root), exactly as
//! for `restore` — the fileset DSL is terminal input language (ADR-0003).
//!
//! **No `-m` where the CLI opens its editor = the editor saved unchanged.** A squash whose
//! abandoned sources and destination carry two or more non-empty descriptions (and no
//! `-m`/`-u`) writes what the CLI's editor holds for the combined commit, saved unchanged: the
//! combined descriptions (with the CLI's "Trailers not found in the squashed commits" block)
//! rendered through `templates.draft_commit_description` and cleaned up
//! ([`crate::template::Templates::editor_text`], Story 9.51); a split without `-m` writes the same
//! for both commits. The GUI asks first: [`squash_plan`] returns the text from the SAME planning
//! and description step [`squash`] runs ([`plan_squash`], `squash_commits`,
//! [`squashed_description`]) on a transaction it drops, so plan and verb cannot disagree, and the
//! plan writes no operation.
//!
//! **An edited text = the CLI's `--editor` whose editor saved exactly that text** (Story 9.54).
//! The GUI sends the user's edit back as `SquashOptions::edited_description` (or split's two
//! edited texts), never as `-m` — which would add `templates.commit_trailers` again. The
//! description step runs as it does with the editor (trailers, the draft template, their refusals
//! and diagnostics), then the edited text is written cleaned up as the CLI cleans a saved buffer,
//! with no trailers added. `-m` together with an edited text refuses.
//!
//! Divergences, all deliberate:
//!
//! - no interactive/tree arm, no `--tool`, no `--editor` flag (the edited text above is the
//!   editor's result): the tree arm (a GUI-selected tree and its `left`) is Story 9.50's; a
//!   `split` with NO paths — the CLI's diff-editor default — refuses
//!   [`MutateError::InvalidInput`];
//! - no `squash -o`/`-A`/`-B` (experimental at v0.46.0: the squashed changes go into a NEW
//!   commit there);
//! - no hints, and not squash's "is being interpreted as a fileset expression" warning, which is
//!   about terminal argv parsing (`templates.commit_trailers` IS applied where the CLI applies it,
//!   Story 9.51);
//! - clap's argument conflicts become [`MutateError::InvalidInput`] naming the flags (clap's
//!   own text is terminal UX), checked before anything is resolved — as clap checks them;
//! - `-m` together with an edited text refuses, where the CLI accepts `-m --editor` (the editor
//!   opens on the `-m` text and the saved buffer wins): the edited text IS that saved buffer, so
//!   `-m` could change nothing (Story 9.54).

use std::collections::HashMap;

use futures::TryStreamExt as _;
use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::commit::Commit;
use jj_lib::commit_builder::DetachedCommitBuilder;
use jj_lib::merge::{Diff, Merge};
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{MutableRepo, Repo as _};
use jj_lib::revset::{ResolvedRevsetExpression, RevsetExpression};
use jj_lib::rewrite::{
    move_commits, squash_commits, CommitRewriter, CommitWithSelection, EmptyBehavior, MoveCommitsLocation,
    MoveCommitsTarget, RebaseOptions, RebasedCommit, RewriteRefsOptions, SquashedCommit,
};
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::mutate::{
    be, build_matcher, cfg, finish_verb, guard_rewritable, mutation_result, no_op_result, resolve_commit,
    resolve_or_wc, warn_unmatched, MutateError, MutationResult,
};
use crate::op_support::{
    cleanup_description_lines, combine_messages_for_editing, compute_commit_location, join_message_paragraphs,
    resolve_ordered, start_repo_transaction, try_combine_messages, SelectedTree,
};
use crate::snapshot::VerbContext;
use crate::template::{write_hidden, Templates};
use crate::warning::{WarningKind, Warnings};
use crate::ChangeId;

/// [`crate::Repo::squash`]'s and [`crate::Repo::squash_plan`]'s arguments — the CLI's
/// `jj squash` flags, one field each (Story 9.15).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SquashOptions {
    /// `-r/--revision`: the revision to squash into its PARENT. `None` (with `from`/`into`
    /// unset too) is `@`. Conflicts with `from`/`into`.
    pub revision: Option<ChangeId>,
    /// `--from`, repeatable: the revisions to squash from. Empty (with `into` set) is `@`. The
    /// destination is silently dropped from this set, as in the CLI.
    pub from: Vec<ChangeId>,
    /// `--into`/`--to`: the revision to squash into. `None` (with `from` set) is `@`.
    pub into: Option<ChangeId>,
    /// The paths whose changes move — repo-relative PREFIXES; empty is every path.
    pub paths: Vec<String>,
    /// `-m`, repeatable: the paragraphs of the squashed revision's description, joined like the
    /// CLI joins them. `None` is no `-m`. Conflicts with `use_destination_message`.
    pub message: Option<Vec<String>>,
    /// `-u/--use-destination-message`: keep the destination's description, discard the
    /// sources'.
    pub use_destination_message: bool,
    /// `-k/--keep-emptied`: a source whose changes all moved is kept (empty), not abandoned.
    pub keep_emptied: bool,
    /// The text the user edited the squashed description to — the CLI's `--editor` with an
    /// editor that saves exactly this text (Story 9.54). Given (and something is squashed), the
    /// description step runs as it does with the editor (trailers added, the draft template
    /// rendered, its refusals and diagnostics), then this text — cleaned up as the CLI cleans a
    /// saved buffer — is written, with NO trailers added. `None` is no editor. Conflicts with
    /// `message`; allowed with `use_destination_message` (the CLI allows `-u --editor`).
    /// [`crate::Repo::squash_plan`] refuses it with `message` too, and otherwise ignores it.
    pub edited_description: Option<String>,
}

/// What [`crate::Repo::squash`] would write as the squashed revision's description when it
/// cannot decide alone (Story 9.15).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SquashPlan {
    /// The combined description — the text the CLI's editor holds, saved unchanged — when the
    /// squash would abandon sources and the abandoned sources and the destination carry two or
    /// more non-empty descriptions, with no `message` and no `use_destination_message`: exactly
    /// the case the CLI opens its editor for. `None` otherwise (nothing to ask: the one
    /// non-empty description, the `-m` text or the destination's is written, or nothing would
    /// be squashed at all).
    pub combined_description: Option<String>,
}

/// [`crate::Repo::split`]'s arguments — the CLI's `jj split` flags, one field each
/// (Story 9.15).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SplitOptions {
    /// `-r/--revision`: the revision to split. `None` is `@` (the CLI's `default_value`).
    pub revision: Option<ChangeId>,
    /// The paths whose changes go into the SELECTED commit — repo-relative PREFIXES. At least
    /// one: the CLI's no-paths default is its interactive diff editor.
    pub paths: Vec<String>,
    /// `-m`, repeatable: the SELECTED commit's description; the other keeps the original one.
    /// `None` is no `-m`: both get what the CLI's editor holds saved unchanged — their description
    /// with `templates.commit_trailers` added, rendered through `templates.draft_commit_description`
    /// (`template-aliases.default_commit_description` for an undescribed target; Story 9.51).
    pub message: Option<Vec<String>>,
    /// `-p/--parallel`: the two commits become siblings instead of parent and child.
    /// Conflicts with `onto`/`insert_after`/`insert_before`.
    pub parallel: bool,
    /// `-o/--onto`, repeatable: put the selected changes into a NEW commit on these parents.
    /// `None` is the flag not given; `Some(vec![])` is given with no revision (refused, as the
    /// CLI refuses it: no parent).
    pub onto: Option<Vec<ChangeId>>,
    /// `-A/--insert-after`, repeatable: put the selected changes into a NEW commit inserted after
    /// these revisions. `None` / `Some(vec![])` as for `onto`.
    pub insert_after: Option<Vec<ChangeId>>,
    /// `-B/--insert-before`, repeatable: put the selected changes into a NEW commit inserted
    /// before these revisions. `None` / `Some(vec![])` as for `onto`.
    pub insert_before: Option<Vec<ChangeId>>,
    /// The text the user edited the SELECTED commit's description to — the CLI's bulk editor
    /// saving exactly this section (Story 9.54). Given together with
    /// `edited_remaining_description`, the editor path runs as it does without `-m` (trailers
    /// added, the draft template rendered on both, its refusals and diagnostics), then each commit
    /// gets its edited text, cleaned up as the CLI cleans a saved section, with NO trailers added.
    /// Both or neither; conflicts with `message`.
    pub edited_selected_description: Option<String>,
    /// The text the user edited the REMAINING commit's description to — see
    /// `edited_selected_description`.
    pub edited_remaining_description: Option<String>,
}

/// What [`crate::Repo::split`] did (Story 9.15).
#[derive(Debug)]
pub struct SplitResult {
    /// The shared mutation contract. `new_change_ids` holds the one commit that got a NEW change
    /// id: the remaining commit for a plain or parallel split, the selected one for
    /// `onto`/`insert_after`/`insert_before`.
    pub mutation: MutationResult,
    /// Change id of the commit holding the SELECTED changes — the target's own for a plain or
    /// parallel split, a new one at the requested location otherwise.
    pub selected_change_id: ChangeId,
    /// Change id of the commit holding the REMAINING changes — new for a plain or parallel split,
    /// the target's own otherwise. `@` ends on this commit when the target was `@`.
    pub remaining_change_id: ChangeId,
}

/// The refusal of `message` together with an edited description (Story 9.54) — the CLI's
/// `--editor` does not conflict with `-m`, but an edited text is the saved buffer that replaces
/// whatever `-m` would have written.
const EDITED_WITH_MESSAGE: &str = "--message cannot be used with an edited description";

// ── squash ───────────────────────────────────────────────────────────────────────

/// How the squashed revision's description is decided — `SquashedDescription`
/// (`squash.rs:460-483` @ v0.46.0).
pub(crate) enum SquashedDescription {
    /// `-m`: this exact description.
    Exact(String),
    /// `-u`: the destination's.
    UseDestination,
    /// The sources' and the destination's, combined.
    Combine,
}

/// What [`plan_squash`] decided: the operation description, the destination and the
/// selections — and, unless nothing would move, the description and the abandoned sources.
pub(crate) struct PlannedSquash {
    /// `squash commits into <destination hex>`, computed BEFORE anything is rewritten
    /// (`squash.rs:256-267`).
    pub(crate) tx_description: String,
    /// The destination, as resolved.
    pub(crate) destination: Commit,
    /// Every source with its selected tree, oldest first.
    pub(crate) selections: Vec<CommitWithSelection>,
    /// `None` when no source contributes anything — the CLI's "Nothing changed." path.
    pub(crate) squashed: Option<SquashDecision>,
}

/// How the squashed destination's description is decided, fixed before anything is rewritten;
/// the text itself is finished on `squash_commits`' builder ([`squashed_description`]).
pub(crate) struct SquashDecision {
    /// `-m`, `-u` or the combination.
    pub(crate) mode: SquashedDescription,
    /// The sources jj-lib will abandon (every fully moved source, unless `keep_emptied`).
    pub(crate) abandoned: Vec<Commit>,
}

/// The read-only part `squash` and `squash_plan` share (Story 9.15): the clap conflicts, the
/// source/destination resolution, the merge refusal, the rewritability guard, the selection,
/// the unmatched-path warning, the abandoned set and the description mode — in the CLI's
/// order (`squash.rs:184-355` @ v0.46.0).
///
/// It rewrites NOTHING: the abandoned set is computed by `squash_commits`' own rule
/// (`rewrite.rs:1376-1385` @ jj-lib 0.46.0 — abandon a source when `!keep_emptied` and its
/// selection is full; skip one that is not abandoned and whose selection is empty), so the
/// description decision sees exactly the commits `squash_commits` will abandon. Only the
/// selected trees the path selection builds reach the store — content-addressed objects, never
/// a commit and never an operation.
///
/// # Errors
///
/// See [`crate::Repo::squash`].
pub(crate) fn plan_squash(
    tx: &Transaction,
    workspace: &Workspace,
    ctx: &mut VerbContext,
    options: &SquashOptions,
) -> Result<PlannedSquash, MutateError> {
    if options.revision.is_some() && (!options.from.is_empty() || options.into.is_some()) {
        return Err(MutateError::invalid(
            "--revision cannot be used with --from or --into".to_owned(),
        ));
    }
    if options.message.is_some() && options.use_destination_message {
        return Err(MutateError::invalid(
            "--message cannot be used with --use-destination-message".to_owned(),
        ));
    }
    if options.message.is_some() && options.edited_description.is_some() {
        return Err(MutateError::invalid(EDITED_WITH_MESSAGE.to_owned()));
    }

    let (sources, destination) = resolve_squash(tx, workspace, options)?;
    let mut ids: Vec<JjCommitId> = sources.iter().map(|c| c.id().clone()).collect();
    ids.push(destination.id().clone());
    guard_rewritable(tx, &ctx.immutable, &ids)?;
    let tx_description = format!("squash commits into {}", destination.id().hex());

    let matcher = build_matcher(&options.paths)?;
    let mode = if let Some(paragraphs) = &options.message {
        SquashedDescription::Exact(join_message_paragraphs(paragraphs))
    } else if options.use_destination_message {
        SquashedDescription::UseDestination
    } else {
        SquashedDescription::Combine
    };

    // `select_diff` (`squash.rs:485-533`): the left side is each source's PARENT tree.
    let mut selections: Vec<CommitWithSelection> = Vec::with_capacity(sources.len());
    for source in &sources {
        let parent_tree = pollster::block_on(source.parent_tree(tx.repo())).map_err(be)?;
        let source_tree = source.tree();
        let labels = Diff::new(
            pollster::block_on(source.parents_conflict_label()).map_err(be)?,
            source.conflict_label(),
        );
        let selected = SelectedTree::from_paths(Diff::new(&parent_tree, &source_tree), labels, matcher.as_ref())?;
        selections.push(selected.into_commit_selection(source.clone(), parent_tree));
    }
    let selected_trees: Vec<&MergedTree> = selections.iter().map(|s| &s.selected_tree).collect();
    warn_unmatched(workspace, &mut ctx.warnings, &options.paths, &selected_trees)?;

    // `squash_commits`' own rule (`rewrite.rs:1376-1385`), applied without rewriting anything.
    let mut contributing = 0_usize;
    let mut abandoned: Vec<Commit> = Vec::new();
    for selection in &selections {
        let abandon = !options.keep_emptied && selection.is_full_selection();
        if !abandon && selection.is_empty_selection() {
            continue;
        }
        contributing += 1;
        if abandon {
            abandoned.push(selection.commit.clone());
        }
    }
    let squashed = (contributing > 0).then_some(SquashDecision { mode, abandoned });
    Ok(PlannedSquash {
        tx_description,
        destination,
        selections,
        squashed,
    })
}

/// The sources (oldest first) and the destination — `squash.rs:197-248` @ v0.46.0.
///
/// With `from`/`into`: the `from` union (or `@`) in revset order, the destination (`into` or
/// `@`) dropped from it, then reversed. Otherwise `revision` (or `@`) and its ONE parent; a merge
/// or the root commit refuses.
fn resolve_squash(
    tx: &Transaction,
    workspace: &Workspace,
    options: &SquashOptions,
) -> Result<(Vec<Commit>, Commit), MutateError> {
    let workspace_name = workspace.workspace_name();
    if !options.from.is_empty() || options.into.is_some() {
        let mut sources = if options.from.is_empty() {
            vec![resolve_or_wc(tx.repo(), workspace_name, None)?]
        } else {
            let mut ids = Vec::with_capacity(options.from.len());
            for id in &options.from {
                ids.push(resolve_commit(tx.repo(), id)?.id().clone());
            }
            commits_in_revset_order(tx, ids)?
        };
        let destination = resolve_or_wc(tx.repo(), workspace_name, options.into.as_ref())?;
        sources.retain(|source| source.id() != destination.id());
        // The CLI applies the oldest first: "it avoids creating transient conflicts".
        sources.reverse();
        return Ok((sources, destination));
    }
    let source = resolve_or_wc(tx.repo(), workspace_name, options.revision.as_ref())?;
    let parents = pollster::block_on(source.parents()).map_err(be)?;
    let Ok([destination]) = <[Commit; 1]>::try_from(parents) else {
        return Err(MutateError::invalid_hinted(
            "Cannot squash merge commits without a specified destination",
            "Use `--into` to specify which parent to squash into",
        ));
    };
    Ok((vec![source], destination))
}

/// `ids` as the CLI's `evaluate_to_commits` yields the `--from` union: each commit once, in
/// revset (index) order, newest first.
fn commits_in_revset_order(tx: &Transaction, ids: Vec<JjCommitId>) -> Result<Vec<Commit>, MutateError> {
    let expression: std::sync::Arc<ResolvedRevsetExpression> = RevsetExpression::commits(ids);
    let set = expression.evaluate(tx.repo()).map_err(be)?;
    let ordered: Vec<JjCommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    ordered
        .iter()
        .map(|id| tx.repo().store().get_commit(id).map_err(be))
        .collect()
}

/// `jj squash` (Story 9.15) — see [`crate::Repo::squash`]: [`plan_squash`], then jj-lib's
/// `squash_commits` and the write of the squashed destination with the decided description.
///
/// # Errors
///
/// See [`crate::Repo::squash`].
pub(crate) fn squash(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &SquashOptions,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let old_wc_id = readonly.view().get_wc_commit_id(&workspace_name).cloned();

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let PlannedSquash {
        tx_description,
        destination,
        selections,
        squashed,
    } = plan_squash(&tx, workspace, ctx, options)?;
    let mut abandoned_change_ids = Vec::new();
    let mut wc_abandoned = false;
    // The plan applies `squash_commits`' own rule, so a planned squash always yields a builder.
    let rewritten = match squashed {
        Some(decision) => pollster::block_on(squash_commits(
            tx.repo_mut(),
            &selections,
            &destination,
            options.keep_emptied,
        ))
        .map_err(be)?
        .map(|SquashedCommit { commit_builder, .. }| (commit_builder.detach(), decision)),
        None => None,
    };
    if let Some((mut builder, decision)) = rewritten {
        let templates = Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, workspace);
        let (description, _) = squashed_description(
            &templates,
            tx.repo(),
            &mut builder,
            (&destination, &decision),
            options.edited_description.as_deref(),
            &mut ctx.warnings,
        )?;
        builder.set_description(description);
        pollster::block_on(builder.write(tx.repo_mut())).map_err(be)?;
        // `squash.rs:413`; also what clears the abandonments before `tx.commit`.
        pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
        wc_abandoned = old_wc_id
            .as_ref()
            .is_some_and(|id| decision.abandoned.iter().any(|c| c.id() == id));
        abandoned_change_ids = decision
            .abandoned
            .iter()
            .map(|c| ChangeId(c.change_id().reverse_hex()))
            .collect();
    }
    // `WorkspaceCommandTransaction::finish`'s "Nothing changed." guard (`cli_util.rs:2852`).
    if !tx.repo().has_changes() {
        drop(tx);
        return no_op_result(&workspace_name, &readonly);
    }
    let finish = finish_verb(workspace, tx, &tx_description, ctx)?;
    let new_change_ids = match (&finish.wc_commit, wc_abandoned) {
        (Some(new_wc_commit), true) => vec![ChangeId(new_wc_commit.change_id().reverse_hex())],
        _ => Vec::new(),
    };
    mutation_result(&finish, new_change_ids, abandoned_change_ids)
}

/// `squash`'s description without the squash (Story 9.15) — see [`crate::Repo::squash_plan`].
/// Runs [`plan_squash`], `squash_commits` and [`squashed_description`] exactly as [`squash`] does,
/// on a transaction it then drops: no operation is written (the hidden commits the description
/// step renders on reach the store, as the CLI's do).
///
/// # Errors
///
/// See [`crate::Repo::squash`].
pub(crate) fn squash_plan(
    workspace: &Workspace,
    ctx: &mut VerbContext,
    options: &SquashOptions,
) -> Result<SquashPlan, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let mut tx = start_repo_transaction(&readonly, workspace.workspace_name());
    let PlannedSquash {
        destination,
        selections,
        squashed,
        ..
    } = plan_squash(&tx, workspace, ctx, options)?;
    // The plan applies `squash_commits`' own rule, so a planned squash always yields a builder.
    let rewritten = match squashed {
        Some(decision) => pollster::block_on(squash_commits(
            tx.repo_mut(),
            &selections,
            &destination,
            options.keep_emptied,
        ))
        .map_err(be)?
        .map(|SquashedCommit { commit_builder, .. }| (commit_builder.detach(), decision)),
        None => None,
    };
    let Some((mut builder, decision)) = rewritten else {
        return Ok(SquashPlan {
            combined_description: None,
        });
    };
    let templates = Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, workspace);
    let (description, editor) = squashed_description(
        &templates,
        tx.repo(),
        &mut builder,
        (&destination, &decision),
        None,
        &mut ctx.warnings,
    )?;
    Ok(SquashPlan {
        combined_description: editor.then_some(description),
    })
}

/// The one description the squash writes without asking — `-m`'s, `-u`'s or the single non-empty
/// one among the abandoned sources and the destination — or `None` when two or more are non-empty
/// and the CLI opens its editor (`squash.rs:356-372` @ v0.46.0). The one rule
/// [`squashed_description`] and [`combined_description_needed`] share.
fn single_description(decision: &SquashDecision, destination: &Commit) -> Option<String> {
    match &decision.mode {
        SquashedDescription::Exact(description) => Some(description.clone()),
        SquashedDescription::UseDestination => Some(destination.description().to_owned()),
        // Only the ABANDONED sources' descriptions count — a source that keeps its commit keeps
        // its description.
        SquashedDescription::Combine => {
            let abandoned: Vec<&str> = decision.abandoned.iter().map(Commit::description).collect();
            try_combine_messages(&abandoned, destination.description())
        }
    }
}

/// Whether the planned squash needs a combined description — the case the CLI opens its editor
/// for and [`crate::Repo::squash_plan`] returns a text for: something is squashed, the description
/// is combined (no `-m`, no `-u`) and two or more of the abandoned sources and the destination
/// are non-empty (Story 9.31).
pub(crate) fn combined_description_needed(plan: &PlannedSquash) -> bool {
    plan.squashed.as_ref().is_some_and(|decision| {
        matches!(decision.mode, SquashedDescription::Combine)
            && single_description(decision, &plan.destination).is_none()
    })
}

/// The squashed destination's description (`squash.rs:356-400` @ v0.46.0), finished on `builder`
/// — `squash_commits`' detached builder — and whether it is the editor arm.
///
/// `-m`, `-u` or a single non-empty description among the abandoned sources and the destination:
/// that text, with `templates.commit_trailers` added unless it is empty. Two or more: the CLI's
/// editor arm — `combine_messages_for_editing` with its "Trailers not found in the squashed
/// commits" block set on `builder`, a hidden write, and the editor's text saved unchanged
/// ([`Templates::editor_text`]: `templates.draft_commit_description` rendered and cleaned up).
///
/// With `edited` (Story 9.54) it runs as the CLI's `--editor` runs: the single arm adds the
/// trailers even to an empty text, sets them, writes hidden and renders the draft; the combine arm
/// renders as above — and in both the rendered text is discarded for `edited`, cleaned up as the
/// CLI cleans the saved buffer (`edit_description`, `description_util.rs:193-204`), no trailers.
///
/// # Errors
///
/// - [`MutateError::Config`] — a template does not parse or render (see [`Templates`]).
/// - [`MutateError::Backend`] — a hidden write failed.
fn squashed_description(
    templates: &Templates<'_>,
    repo: &dyn jj_lib::repo::Repo,
    builder: &mut DetachedCommitBuilder,
    (destination, decision): (&Commit, &SquashDecision),
    edited: Option<&str>,
    sink: &mut Warnings,
) -> Result<(String, bool), MutateError> {
    let abandoned: Vec<&str> = decision.abandoned.iter().map(Commit::description).collect();
    if let Some(description) = single_description(decision, destination) {
        if description.is_empty() && edited.is_none() {
            return Ok((description, false));
        }
        builder.set_description(description);
        let with_trailers = templates.add_trailers(repo, builder, sink)?;
        let Some(edited) = edited else {
            return Ok((with_trailers, false));
        };
        builder.set_description(with_trailers);
        let temp = write_hidden(builder)?;
        templates.editor_text(repo, &temp, sink)?;
        return Ok((cleanup_description_lines(edited.lines()), false));
    }
    let mut squashed = abandoned.clone();
    squashed.push(destination.description());
    let missing = templates.trailers_not_in(repo, builder, &squashed, sink)?;
    // "It's weird that commit.description() contains "JJ: " lines, but works." (`squash.rs:390`)
    builder.set_description(combine_messages_for_editing(
        &abandoned,
        Some(destination.description()),
        &missing,
    ));
    let temp = write_hidden(builder)?;
    let saved_unchanged = templates.editor_text(repo, &temp, sink)?;
    let description = edited.map_or(saved_unchanged, |edited| cleanup_description_lines(edited.lines()));
    Ok((description, true))
}

// ── split ────────────────────────────────────────────────────────────────────────

/// What [`prepare_split`] resolved: the target with its selection, and the location of the new
/// commit when `onto`/`insert_after`/`insert_before` is given.
pub(crate) struct PreparedSplit {
    /// The target commit, its parent tree and the selected tree.
    pub(crate) target: CommitWithSelection,
    /// `(new_parents, new_children)` of the selected commit (`-o`/`-A`/`-B`), else `None`.
    pub(crate) location: Option<(Vec<JjCommitId>, Vec<JjCommitId>)>,
}

/// Everything before `split` rewrites anything (Story 9.15): the clap conflicts, the target,
/// the rewritability guard, the location (`compute_commit_location(…, "split-out commit")`),
/// the unmatched-path warning over `[parent_tree, tree]` and the selection with its two
/// warnings — `SplitArgs::resolve` and `select_diff` (`split.rs:201-257`, `:546-598` @ v0.46.0).
///
/// # Errors
///
/// See [`crate::Repo::split`].
pub(crate) fn prepare_split(
    tx: &Transaction,
    workspace: &Workspace,
    ctx: &mut VerbContext,
    options: &SplitOptions,
) -> Result<PreparedSplit, MutateError> {
    let edited = [
        &options.edited_selected_description,
        &options.edited_remaining_description,
    ];
    if options.message.is_some() && edited.iter().any(|text| text.is_some()) {
        return Err(MutateError::invalid(EDITED_WITH_MESSAGE.to_owned()));
    }
    if edited[0].is_some() != edited[1].is_some() {
        return Err(MutateError::invalid(
            "an edited split needs both descriptions: the selected and the remaining".to_owned(),
        ));
    }
    let use_move_flags = options.onto.is_some() || options.insert_after.is_some() || options.insert_before.is_some();
    if options.parallel && use_move_flags {
        return Err(MutateError::invalid(
            "--parallel cannot be used with --onto, --insert-after or --insert-before".to_owned(),
        ));
    }
    if options.onto.is_some() && (options.insert_after.is_some() || options.insert_before.is_some()) {
        return Err(MutateError::invalid(
            "--onto cannot be combined with -A/--insert-after or -B/--insert-before".to_owned(),
        ));
    }

    let target = resolve_or_wc(tx.repo(), workspace.workspace_name(), options.revision.as_ref())?;
    let immutable = guard_rewritable(tx, &ctx.immutable, std::slice::from_ref(target.id()))?;
    let matcher = build_matcher(&options.paths)?;
    let location = if use_move_flags {
        let onto = resolve_ordered(tx, options.onto.as_deref())?;
        let after = resolve_ordered(tx, options.insert_after.as_deref())?;
        let before = resolve_ordered(tx, options.insert_before.as_deref())?;
        Some(compute_commit_location(
            tx.base_repo().as_ref(),
            &immutable,
            onto.as_deref(),
            after.as_deref(),
            before.as_deref(),
            "split-out commit",
        )?)
    } else {
        None
    };

    // "We check the parent commit to account for deleted files." (`split.rs:237-247`)
    let parent_tree = pollster::block_on(target.parent_tree(tx.repo())).map_err(be)?;
    let target_tree = target.tree();
    warn_unmatched(
        workspace,
        &mut ctx.warnings,
        &options.paths,
        &[&parent_tree, &target_tree],
    )?;

    if options.paths.is_empty() {
        return Err(MutateError::invalid(
            "split needs at least one path: the interactive selection the CLI opens without paths is not \
                     supported"
                .to_owned(),
        ));
    }
    let labels = Diff::new(
        pollster::block_on(target.parents_conflict_label()).map_err(be)?,
        target.conflict_label(),
    );
    let selected = SelectedTree::from_paths(Diff::new(&parent_tree, &target_tree), labels, matcher.as_ref())?;
    let target = selected.into_commit_selection(target, parent_tree);
    if target.is_full_selection() {
        ctx.warnings.push(
            WarningKind::SplitAllSelected,
            "All changes have been selected, so the original revision will become empty.",
        );
    } else if target.is_empty_selection() {
        ctx.warnings.push(
            WarningKind::SplitNoneSelected,
            "No changes have been selected, so the new revision will be empty.",
        );
    }
    Ok(PreparedSplit { target, location })
}

/// `jj split` (Story 9.15) — see [`crate::Repo::split`].
///
/// # Errors
///
/// See [`crate::Repo::split`].
pub(crate) fn split(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &SplitOptions,
) -> Result<SplitResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let PreparedSplit { target, location } = prepare_split(&tx, workspace, ctx, options)?;
    let use_move_flags = location.is_some();

    let (mut first_builder, mut second_builder) = split_builders(tx.repo_mut(), &target, options, use_move_flags)?;
    let templates = Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, workspace);
    describe_split(
        &templates,
        tx.repo(),
        (&mut first_builder, &mut second_builder),
        &target,
        options,
        &mut ctx.warnings,
    )?;
    let first = pollster::block_on(first_builder.write(tx.repo_mut())).map_err(be)?;
    second_builder.set_parents(if options.parallel {
        target.commit.parent_ids().to_vec()
    } else {
        vec![first.id().clone()]
    });
    let second = pollster::block_on(second_builder.write(tx.repo_mut())).map_err(be)?;

    let (first, second) = if let Some((parents, children)) = location {
        move_first_commit(tx.repo_mut(), &target, first, second, parents, children)?
    } else {
        let legacy = crate::config::split_legacy_bookmark_behavior(&ctx.config).map_err(cfg)?;
        rewrite_descendants(&mut tx, &target, &first, &second, options.parallel, legacy)?;
        (first, second)
    };
    // `tx.finish`'s `rebase_mutable_descendants` (`cli_util.rs:2855`).
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let description = format!("split commit {}", target.commit.id().hex());
    let finish = finish_verb(workspace, tx, &description, ctx)?;
    let selected_change_id = ChangeId(first.change_id().reverse_hex());
    let remaining_change_id = ChangeId(second.change_id().reverse_hex());
    let minted = if use_move_flags {
        selected_change_id.clone()
    } else {
        remaining_change_id.clone()
    };
    Ok(SplitResult {
        mutation: mutation_result(&finish, vec![minted], Vec::new())?,
        selected_change_id,
        remaining_change_id,
    })
}

/// The two commit builders of `cmd_split` (`split.rs:293-347` @ v0.46.0): the FIRST holds the
/// selected tree (a new change id with `-o`/`-A`/`-B`) and the `-m` description, if any; the
/// SECOND the target's tree — or, in parallel, the target minus the inverted selection — with a
/// new change id otherwise. Both start with the target's description; [`describe_split`] finishes
/// them.
fn split_builders(
    repo: &mut MutableRepo,
    target: &CommitWithSelection,
    options: &SplitOptions,
    use_move_flags: bool,
) -> Result<(DetachedCommitBuilder, DetachedCommitBuilder), MutateError> {
    let mut first = repo.rewrite_commit(&target.commit).detach();
    first.set_tree(target.selected_tree.clone());
    if use_move_flags {
        // "Generate a new change id so that the commit being split doesn't become divergent."
        first.clear_rewrite_source();
        first.generate_new_change_id();
    }
    if let Some(paragraphs) = &options.message {
        first.set_description(join_message_paragraphs(paragraphs));
    }

    let target_tree = target.commit.tree();
    let second_tree = if options.parallel {
        let selected = pollster::block_on(target.diff_with_labels(
            "parents of split revision",
            "selected changes for split",
            "split revision",
        ))
        .map_err(be)?;
        pollster::block_on(MergedTree::merge(Merge::from_diffs(
            (
                target_tree,
                format!("split revision ({})", target.commit.conflict_label()),
            ),
            [selected.invert()],
        )))
        .map_err(be)?
    } else {
        target_tree
    };
    let mut second = repo.rewrite_commit(&target.commit).detach();
    second.set_tree(second_tree);
    if !use_move_flags {
        second.clear_rewrite_source();
        second.generate_new_change_id();
    }
    Ok((first, second))
}

/// The two descriptions of `cmd_split` (`split.rs:302-385` @ v0.46.0). The first commit's — the
/// `-m` text or the target's — gets `templates.commit_trailers` when non-empty; with `-m` the
/// second keeps the target's description, untouched.
///
/// Without `-m` the CLI opens its editor on both (`edit_multiple_descriptions`): the first gets the
/// trailers if still empty and is written hidden, the second is put on it (on the target's parents
/// in parallel), gets the trailers and is written hidden, and each then holds what the editor
/// keeps when saved unchanged — `templates.draft_commit_description` rendered on its temp commit
/// and cleaned up ([`Templates::editor_text`]). With the two edited texts (Story 9.54) that path
/// runs unchanged, then each commit gets its edited text cleaned up, no trailers.
///
/// # Errors
///
/// - [`MutateError::Config`] — a template does not parse or render (see [`Templates`]).
/// - [`MutateError::Backend`] — a hidden write failed.
fn describe_split(
    templates: &Templates<'_>,
    repo: &dyn jj_lib::repo::Repo,
    (first, second): (&mut DetachedCommitBuilder, &mut DetachedCommitBuilder),
    target: &CommitWithSelection,
    options: &SplitOptions,
    sink: &mut Warnings,
) -> Result<(), MutateError> {
    if !first.description().is_empty() {
        let description = templates.add_trailers(repo, first, sink)?;
        first.set_description(description);
    }
    if options.message.is_some() {
        return Ok(());
    }
    if first.description().is_empty() {
        let description = templates.add_trailers(repo, first, sink)?;
        first.set_description(description);
    }
    let first_temp = write_hidden(first)?;
    second.set_parents(if options.parallel {
        target.commit.parent_ids().to_vec()
    } else {
        vec![first_temp.id().clone()]
    });
    let description = templates.add_trailers(repo, second, sink)?;
    second.set_description(description);
    let second_temp = write_hidden(second)?;
    first.set_description(templates.editor_text(repo, &first_temp, sink)?);
    second.set_description(templates.editor_text(repo, &second_temp, sink)?);
    // Story 9.54: the bulk editor saved the user's two sections (`parse_bulk_edit_message`).
    if let (Some(selected), Some(remaining)) = (
        &options.edited_selected_description,
        &options.edited_remaining_description,
    ) {
        first.set_description(cleanup_description_lines(selected.lines()));
        second.set_description(cleanup_description_lines(remaining.lines()));
    }
    Ok(())
}

/// `rewrite_descendants` (`split.rs:495-542` @ v0.46.0): with `legacy`
/// (`split.legacy-bookmark-behavior`) the target counts as rewritten to the SECOND commit, so its
/// bookmarks follow it; the target's descendants are re-parented per mode, and every workspace
/// whose `@` was the target edits the second commit.
fn rewrite_descendants(
    tx: &mut Transaction,
    target: &CommitWithSelection,
    first: &Commit,
    second: &Commit,
    parallel: bool,
    legacy: bool,
) -> Result<(), MutateError> {
    if legacy {
        tx.repo_mut()
            .set_rewritten_commit(target.commit.id().clone(), second.id().clone());
    }
    let (first_id, second_id) = (first.id(), second.id());
    pollster::block_on(tx.repo_mut().transform_descendants(
        vec![target.commit.id().clone()],
        async |mut rewriter: CommitRewriter<'_>| {
            if parallel && legacy {
                // The old parent is the second commit, through the rewrite recorded above.
                rewriter.replace_parent(second_id, [first_id, second_id]);
            } else if parallel {
                rewriter.replace_parent(first_id, [first_id, second_id]);
            } else {
                rewriter.replace_parent(first_id, [second_id]);
            }
            rewriter.rebase().await?.write().await?;
            Ok(())
        },
    ))
    .map_err(be)?;
    let base = tx.base_repo().clone();
    for (name, wc_commit_id) in base.view().wc_commit_ids() {
        if wc_commit_id == target.commit.id() {
            pollster::block_on(tx.repo_mut().edit(name.clone(), second)).map_err(be)?;
        }
    }
    Ok(())
}

/// `move_first_commit` (`split.rs:423-493` @ v0.46.0): the target's descendants are rebased onto
/// the SECOND commit (which kept the target's change id), the location is mapped through those
/// rewrites, and the FIRST commit is moved there — empties kept, abandoned bookmarks not deleted,
/// ancestor merges not simplified.
fn move_first_commit(
    repo: &mut MutableRepo,
    target: &CommitWithSelection,
    mut first: Commit,
    mut second: Commit,
    new_parent_ids: Vec<JjCommitId>,
    new_child_ids: Vec<JjCommitId>,
) -> Result<(Commit, Commit), MutateError> {
    let mut rewritten: HashMap<JjCommitId, JjCommitId> = HashMap::new();
    rewritten.insert(target.commit.id().clone(), second.id().clone());
    pollster::block_on(repo.transform_descendants(
        vec![target.commit.id().clone()],
        async |rewriter: CommitRewriter<'_>| {
            let old_commit_id = rewriter.old_commit().id().clone();
            let new_commit = rewriter.rebase().await?.write().await?;
            rewritten.insert(old_commit_id, new_commit.id().clone());
            Ok(())
        },
    ))
    .map_err(be)?;
    let mapped = |ids: Vec<JjCommitId>| -> Vec<JjCommitId> {
        ids.into_iter()
            .map(|id| rewritten.get(&id).cloned().unwrap_or(id))
            .collect()
    };
    let stats = pollster::block_on(move_commits(
        repo,
        &MoveCommitsLocation {
            new_parent_ids: mapped(new_parent_ids),
            new_child_ids: mapped(new_child_ids),
            target: MoveCommitsTarget::Commits(vec![first.id().clone()]),
        },
        &RebaseOptions {
            empty: EmptyBehavior::Keep,
            rewrite_refs: RewriteRefsOptions {
                delete_abandoned_bookmarks: false,
            },
            simplify_ancestor_merge: false,
        },
    ))
    .map_err(be)?;
    if let Some(RebasedCommit::Rewritten(commit)) = stats.rebased_commits.get(first.id()) {
        first = commit.clone();
    }
    if let Some(RebasedCommit::Rewritten(commit)) = stats.rebased_commits.get(second.id()) {
        second = commit.clone();
    }
    Ok((first, second))
}
