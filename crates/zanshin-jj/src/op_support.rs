// SPDX-License-Identifier: MIT

//! `op_support.rs` — the orchestration every thick jj verb needs that lives in jj-cli's
//! `cli_util`, not in jj-lib (Story 9.1).
//!
//! Ported at jj-cli **v0.44.0** parity — same preconditions, same refusals, same op-log
//! effect (NFR-R-2) — but never its terminal UX (ADR-0003): no `$EDITOR` buffer, no
//! `DiffEditor`/`MergeEditor` subprocess, no `Ui` prompt. Interactive selection arrives as
//! a GUI-supplied tree id instead.
//!
//! Five sections are `cli_util` ports, each named by the CLI item it reproduces. The sixth,
//! §5, is not a port: it is internal resolution plumbing shared by two verb families, with no
//! CLI counterpart.
//!
//! - **§1 Rewritability guard** — `cli_util.rs:2002` `check_rewritable` /
//!   `:2011` `check_rewritable_expr` / `:1118` `resolve_immutable_expression`.
//! - **§2 Insert-location resolution** — `cli_util.rs:3644` `compute_commit_location` /
//!   `:3734` `ensure_no_commit_loop` @ v0.46.0.
//! - **§3 Descriptions** — `description_util.rs:356` `try_combine_messages`, `:374`
//!   `combine_messages_for_editing`, `:164` `cleanup_description_lines`, `:421`
//!   `join_message_paragraphs` and `:449` `add_trailers_with_template` @ v0.46.0.
//! - **§4 Selected-tree plumbing** — `cli_util.rs:3494` `DiffSelector`, whose
//!   `NonInteractive` arm is jj-lib's `restore_tree`.
//! - **§6 Transaction opening** — `cli_util.rs:2883` `start_repo_transaction`, the CLI's single
//!   door onto `ReadonlyRepo::start_transaction`. Not rewrite orchestration like the four
//!   above, but the same kind of port: `cli_util` code jj-lib does not expose.
//!
//! Every item is `pub(crate)`: no `jj_lib` type may appear in a public position
//! (`lib.rs`, FR-JJ-16). §1 is wired into `describe`/`edit`/`abandon` and both
//! Story 9.3 content ops; §4's [`SelectedTree::from_paths`] is `restore`'s primitive; §6 is
//! wired into every transaction this crate opens, so every Zanshin operation records
//! `op_metadata.workspace_name` the way a CLI-written one does (Epic 9 follow-up L). Story
//! 9.15 wired §2 (`split -o/-A/-B`), §3's description ports and §4's
//! [`SelectedTree::into_commit_selection`] into `squash`/`split`; Story 9.51 wired
//! [`apply_trailers`] through [`crate::template`]; Story 9.50 wired §4's GUI-selected-tree arm
//! [`SelectedTree::from_tree_id`] into the tree arms of `commit`/`split`/`squash`.
//!
//! The CLI's two `panic!`s in `compute_commit_location` become
//! [`MutateError::InvalidInput`]: a library must not abort the process on a caller-reachable
//! path.

use std::path::Path;
use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::commit::Commit;
use jj_lib::matchers::Matcher;
use jj_lib::merge::Diff;
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::ReadonlyRepo;
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use jj_lib::revset::{ResolvedRevsetExpression, RevsetExpression, UserRevsetExpression};
use jj_lib::rewrite::{restore_tree, CommitWithSelection};
use jj_lib::store::Store;
use jj_lib::trailer::{parse_description_trailers, Trailer};
use jj_lib::transaction::Transaction;
use jj_lib::ui_path::parse_fs_path;

use crate::mutate::{be, MutateError};
use crate::revset::resolve_expression;
use crate::template::Templates;

// ── §1 Rewritability guard ────────────────────────────────────────────────────────

/// Resolves the immutable expression's symbols against `repo`.
///
/// Mirrors `cli_util.rs:1118` `resolve_immutable_expression` minus `--ignore-immutable`
/// (no verb in this crate exposes that flag) and minus the id-prefix context the CLI
/// deliberately leaves empty there anyway.
///
/// Resolve against the transaction's BASE repo, not its mutable one: that is what
/// `rebase_mutable_descendants` (`cli_util.rs:2927`) does, because a `jj git fetch` can
/// update immutable commits and only the still-reachable ones should constrain the rebase.
///
/// # Errors
///
/// - [`MutateError::Config`] — a symbol in the immutable expression cannot be resolved
///   (e.g. the alias names a bookmark that does not exist). The CLI classifies this
///   failure the same way — `resolve_immutable_expression` maps its `resolve()` error to
///   ``Invalid `revset-aliases.immutable_heads()` `` (`cli_util.rs:1146-1167` @ v0.46.0) —
///   because the alias, not the caller's argument, is what is wrong. The reason is that text,
///   then `: ` and jj-lib's error (Story 9.58), for every caller.
pub(crate) fn resolve_immutable(
    repo: &dyn jj_lib::repo::Repo,
    expr: &Arc<UserRevsetExpression>,
) -> Result<Arc<ResolvedRevsetExpression>, MutateError> {
    resolve_expression(repo, expr).map_err(|e| MutateError::Config {
        reason: format!("Invalid `revset-aliases.immutable_heads()`: {e}"),
    })
}

/// Refuses the rewrite if any of `commit_ids` is inside the immutable set.
///
/// Ports `cli_util.rs:2011` `check_rewritable_expr`: intersect the immutable set with the
/// targets, stream the result, and refuse on the FIRST element. The CLI takes `try_next`,
/// never a list, so the refusal names one offender even when several are immutable. Since
/// Story 9.56 the refusal carries the CLI's hints for a non-root offender (`cli_util.rs:2049-2083`
/// @ v0.46.0), in its order: the offender's summary, why immutable commits exist, where to read
/// more, and how many immutable commits the rewrite would touch (`count_estimate` of the
/// immutable set within the targets' descendants, " or more" when inexact). Root gets none.
///
/// The root commit is reported as immutable by the CLI. `describe`/`abandon` guard it
/// explicitly BEFORE calling this — see `mutate.rs` — so root keeps refusing with
/// `InvalidInput` there, while `edit` (which needs no such guard) reports it here. Either
/// way the call refuses and no op-log entry is written, which is the observable behavior
/// NFR-R-2 pins.
///
/// The offender's summary is `templates.commit_summary` rendered over `repo` through `templates`
/// ([`Templates::commit_summary`]).
///
/// # Errors
///
/// - [`MutateError::Immutable`] — the first target found inside the immutable set.
/// - [`MutateError::Config`] — (refusing a non-root offender) `templates.commit_summary` is not a
///   string or does not parse.
/// - [`MutateError::Backend`] — an underlying jj-lib evaluation failure.
pub(crate) fn check_rewritable(
    repo: &dyn jj_lib::repo::Repo,
    immutable: &Arc<ResolvedRevsetExpression>,
    templates: &Templates<'_>,
    commit_ids: &[CommitId],
) -> Result<(), MutateError> {
    let to_rewrite = RevsetExpression::commits(commit_ids.to_vec());
    let set = immutable.intersection(&to_rewrite).evaluate(repo).map_err(be)?;
    let mut stream = set.stream();
    let Some(commit_id) = pollster::block_on(stream.try_next()).map_err(be)? else {
        return Ok(());
    };
    let hints = if commit_id == *repo.store().root_commit_id() {
        Vec::new()
    } else {
        immutable_hints(repo, immutable, templates, &to_rewrite, &commit_id)?
    };
    Err(MutateError::Immutable {
        commit_id: commit_id.hex(),
        hints,
    })
}

/// The CLI's hints for an immutable non-root offender (`cli_util.rs:2061-2083` @ v0.46.0).
fn immutable_hints(
    repo: &dyn jj_lib::repo::Repo,
    immutable: &Arc<ResolvedRevsetExpression>,
    templates: &Templates<'_>,
    to_rewrite: &Arc<ResolvedRevsetExpression>,
    commit_id: &CommitId,
) -> Result<Vec<String>, MutateError> {
    let commit = repo.store().get_commit(commit_id).map_err(be)?;
    let summary = templates.commit_summary(repo, &commit)?;
    let (lower, upper) = immutable
        .intersection(&to_rewrite.descendants())
        .evaluate(repo)
        .map_err(be)?
        .count_estimate()
        .map_err(be)?;
    let or_more = if upper == Some(lower) { "" } else { " or more" };
    Ok(vec![
        format!("Could not modify commit: {summary}"),
        "Immutable commits are used to protect shared history.".to_owned(),
        "For more information, see:\n      - https://docs.jj-vcs.dev/latest/config/#set-of-immutable-commits\n      - `jj help -k config`, \"Set of immutable commits\"".to_owned(),
        format!("This operation would rewrite {lower}{or_more} immutable commits."),
    ])
}

// ── §2 Insert-location resolution ─────────────────────────────────────────────────
//
// WHY the remaining `allow(dead_code)`s below: an item whose consumer has not landed yet is
// exercised only by this module's own `#[cfg(test)]` tests — which is also why
// `expect(dead_code)` would be wrong: in the test build the lint does not fire, and an
// unfulfilled expectation is itself a warning. Each attribute is dropped when its first real
// caller arrives (Story 9.15 dropped §2's, `try_combine_messages`' and
// `into_commit_selection`'s).

/// [`compute_commit_location`]'s refusal of `--onto` together with `-A`/`-B` — shared with
/// `drop_actions`' up-front location check (Story 9.31), which must refuse with the same text.
pub(crate) const ONTO_WITH_INSERT: &str = "--onto cannot be combined with -A/--insert-after or -B/--insert-before";

/// [`compute_commit_location`]'s refusal of a location with none of the three flags — shared as
/// [`ONTO_WITH_INSERT`] is.
pub(crate) const NO_LOCATION: &str = "expected at least one of --onto, -A/--insert-after or -B/--insert-before";

/// The CLI's `-o`/`-A`/`-B` destination flags over change ids (`RebaseDestinationArgs` and its
/// siblings in `duplicate`/`new`/`split`) — an EMPTY slice is a flag that was not given, as clap
/// cannot pass a flag with no values (Story 9.31).
#[derive(Debug, Clone, Copy)]
pub(crate) struct LocationArgs<'a> {
    /// `-o/--onto`.
    pub(crate) onto: &'a [crate::ChangeId],
    /// `-A/--insert-after`.
    pub(crate) insert_after: &'a [crate::ChangeId],
    /// `-B/--insert-before`.
    pub(crate) insert_before: &'a [crate::ChangeId],
}

impl LocationArgs<'_> {
    /// Whether `-A` or `-B` is given — the case whose location rewrites children.
    pub(crate) fn inserts(&self) -> bool {
        !self.insert_after.is_empty() || !self.insert_before.is_empty()
    }
}

/// The CLI's `compute_commit_location` (`cli_util.rs:3644-3700` @ v0.46.0) WITH its revision
/// resolution: each list resolved in argument order with duplicates dropped ([`resolve_ordered`]),
/// `onto` first, then [`compute_commit_location`] against `tx.base_repo()` (Story 9.31).
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — an id is malformed, absent, only-hidden, or divergent.
/// - Anything [`compute_commit_location`] returns.
pub(crate) fn resolve_commit_location(
    tx: &Transaction,
    templates: &Templates<'_>,
    location: &LocationArgs<'_>,
    commit_type: &str,
) -> Result<(Vec<CommitId>, Vec<CommitId>), MutateError> {
    let given = crate::mutate::given;
    let onto = resolve_ordered(tx, given(location.onto))?;
    let after = resolve_ordered(tx, given(location.insert_after))?;
    let before = resolve_ordered(tx, given(location.insert_before))?;
    compute_commit_location(
        tx.base_repo().as_ref(),
        templates,
        onto.as_deref(),
        after.as_deref(),
        before.as_deref(),
        commit_type,
    )
}

/// Computes the `(new_parents, new_children)` a commit should be placed between.
///
/// Ports `cli_util.rs:3644` `compute_commit_location` @ v0.46.0 over ALREADY-RESOLVED commit ids:
/// callers own their own revset parsing (`RevisionArg` is a CLI concept), which keeps this
/// layer free of parse concerns and directly unit-testable. `destination` is the `--onto`
/// form and is mutually exclusive with `insert_after` (`-A`) / `insert_before` (`-B`).
///
/// `commit_type` is the noun the loop refusal names ("commit", "commits", "revision", …) —
/// passed through from the caller exactly as the CLI passes it (FR-JJ-17).
///
/// The immutable set is resolved from `templates.immutable()` only when the location has
/// children, right before [`check_rewritable`] — the CLI resolves it inside its
/// `check_rewritable` there, so a location without children never reads it (Story 9.18 closing
/// run). `templates` also renders the immutable refusal's summary hint.
///
/// # Input contract
///
/// The CLI gets these three slices from `resolve_revsets_ordered`, i.e. an `IndexSet` of
/// commits that exist; taking raw slices moves that guarantee onto the caller, and NONE of
/// it is re-checked here:
///
/// - Ids must be **resolved and existing**. An id no commit has is not an error: the `-A`
///   branch simply finds no children for it and it is returned verbatim as a parent, so a
///   caller that skips resolution gets a plausible-looking `Ok` with a bogus parent.
/// - Ids must be **deduplicated**. Duplicates are passed through to the caller as
///   duplicate parents/children (the `-B` PARENT computation dedups, because the CLI's
///   does; the target lists themselves never are).
/// - **Absence is `None`, never `Some(&[])`.** `Some(&[])` means "the flag was given with
///   no revisions" and is honoured as such — for `-A` alone that resolves no parents and
///   is refused with "No revisions found to use as parent", which is not the same thing as
///   the "expected at least one of …" refusal an all-`None` call gets.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `destination` combined with `insert_after`/
///   `insert_before`, none of the three given (both are `panic!`s in the CLI), a resulting
///   parent/child cycle, or an empty resolved parent set.
/// - [`MutateError::Immutable`] — a resulting child commit is immutable.
/// - [`MutateError::Config`] — (only with children) the `immutable_heads()` alias does not
///   resolve ([`resolve_immutable`]), or the immutable refusal's summary does not render.
/// - [`MutateError::Backend`] — an underlying jj-lib evaluation or backend failure.
pub(crate) fn compute_commit_location(
    repo: &dyn jj_lib::repo::Repo,
    templates: &Templates<'_>,
    destination: Option<&[CommitId]>,
    insert_after: Option<&[CommitId]>,
    insert_before: Option<&[CommitId]>,
    commit_type: &str,
) -> Result<(Vec<CommitId>, Vec<CommitId>), MutateError> {
    let (new_parent_ids, new_child_ids) = match (destination, insert_after, insert_before) {
        (Some(destination), None, None) => (destination.to_vec(), Vec::new()),
        // Both given: taken verbatim. The CLI evaluates no revset here either.
        (None, Some(after), Some(before)) => (after.to_vec(), before.to_vec()),
        (None, Some(after), None) => {
            let expr = RevsetExpression::commits(after.to_vec()).children();
            let set = expr.evaluate(repo).map_err(be)?;
            let children: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
            (after.to_vec(), children)
        }
        (None, None, Some(before)) => {
            // WHY: not `RevsetExpression::parents` — the CLI unions `parent_ids()` with a
            // dedup specifically "to persist the order of parents specified in
            // `before_commits`", which the revset form would lose.
            let mut parents: Vec<CommitId> = Vec::new();
            for id in before {
                let commit = repo.store().get_commit(id).map_err(be)?;
                for parent in commit.parent_ids() {
                    if !parents.contains(parent) {
                        parents.push(parent.clone());
                    }
                }
            }
            (parents, before.to_vec())
        }
        // WHY these two messages are NOT the CLI's: the CLI `panic!`s here, so its strings
        // are internal assertion text naming Rust parameters. A refusal a GUI may surface
        // names the user-facing flags instead. The CLI's genuinely user-facing refusals
        // below ("No revisions found to use as parent", "Refusing to create a loop: …")
        // stay verbatim.
        (Some(_), Some(_), _) | (Some(_), _, Some(_)) => return Err(MutateError::invalid(ONTO_WITH_INSERT.to_owned())),
        (None, None, None) => return Err(MutateError::invalid(NO_LOCATION.to_owned())),
    };

    if !new_child_ids.is_empty() {
        let immutable = resolve_immutable(repo, templates.immutable())?;
        check_rewritable(repo, &immutable, templates, &new_child_ids)?;
        ensure_no_commit_loop(
            repo,
            &RevsetExpression::commits(new_child_ids.clone()),
            &RevsetExpression::commits(new_parent_ids.clone()),
            commit_type,
        )?;
    }

    if new_parent_ids.is_empty() {
        return Err(MutateError::invalid("No revisions found to use as parent".to_owned()));
    }

    Ok((new_parent_ids, new_child_ids))
}

/// Refuses a location whose children would also be ancestors of its parents.
///
/// Ports `cli_util.rs:3734` `ensure_no_commit_loop` @ v0.46.0, message included (the
/// 12-hex-digit short form comes from jj-lib's `Display`, which pads/truncates the full hex).
fn ensure_no_commit_loop(
    repo: &dyn jj_lib::repo::Repo,
    children: &Arc<ResolvedRevsetExpression>,
    parents: &Arc<ResolvedRevsetExpression>,
    commit_type: &str,
) -> Result<(), MutateError> {
    let set = children.dag_range_to(parents).evaluate(repo).map_err(be)?;
    let mut stream = set.stream();
    if let Some(commit_id) = pollster::block_on(stream.try_next()).map_err(be)? {
        return Err(MutateError::invalid(format!(
            "Refusing to create a loop: commit {commit_id:.12} would be both an ancestor and a descendant \
                 of the {commit_type}"
        )));
    }
    Ok(())
}

// ── §3 Descriptions ───────────────────────────────────────────────────────────────

/// Combines the descriptions of the commits feeding a squash-like verb.
///
/// Ports `description_util.rs:356` `try_combine_messages` @ v0.46.0 over plain strings (the
/// CLI takes `Commit`s only to read `description()`): if at most one of
/// `sources ++ [destination]` is non-empty, that one wins; `None` means two or more are
/// non-empty.
///
/// `None` is a RESULT, not a gap. The CLI's fallback for the ambiguous case is
/// `combine_messages_for_editing` — a `JJ: `-commented `$EDITOR` buffer, precisely the
/// terminal UX ADR-0003 replaces. [`combined_editor_text`] is what that buffer becomes when the
/// editor saves it unchanged; `squash_plan` hands it to the GUI first (Story 9.15).
pub(crate) fn try_combine_messages(sources: &[&str], destination: &str) -> Option<String> {
    let mut non_empty = sources
        .iter()
        .copied()
        .chain(std::iter::once(destination))
        .filter(|d| !d.is_empty());
    match (non_empty.next(), non_empty.next()) {
        (None, _) => Some(String::new()),
        (Some(only), None) => Some(only.to_owned()),
        (Some(_), Some(_)) => None,
    }
}

/// The `$EDITOR` buffer a squash-like verb opens for its combined description — ports
/// `description_util.rs:374-415` `combine_messages_for_editing` @ v0.46.0.
///
/// The destination's description under a `JJ: Description from the destination commit:`
/// header (when there is a destination), then every source's under its own `JJ: Description
/// from source commit:` header — EMPTY descriptions included, as the CLI includes them "so the
/// user doesn't have to wonder why they only see 2 descriptions when they combined 3 commits".
///
/// Then, when `missing_trailers` is non-empty, the CLI's `JJ: Trailers not found in the squashed
/// commits:` block, one `key: value` line each — the trailers `templates.commit_trailers` renders
/// that none of the squashed commits carries, which the caller renders
/// ([`crate::template::Templates::trailers_not_in`], Story 9.51).
pub(crate) fn combine_messages_for_editing(
    sources: &[&str],
    destination: Option<&str>,
    missing_trailers: &[Trailer],
) -> String {
    let mut combined = String::new();
    if let Some(destination) = destination {
        combined.push_str("JJ: Description from the destination commit:\n");
        combined.push_str(destination);
    }
    for source in sources {
        combined.push_str("\nJJ: Description from source commit:\n");
        combined.push_str(source);
    }
    if !missing_trailers.is_empty() {
        combined.push_str("\nJJ: Trailers not found in the squashed commits:\n");
        for trailer in missing_trailers {
            combined.push_str(&trailer.key);
            combined.push_str(": ");
            combined.push_str(&trailer.value);
            combined.push('\n');
        }
    }
    combined
}

/// What the CLI keeps of an edited description — ports `description_util.rs:164-183`
/// `cleanup_description_lines` @ v0.46.0.
///
/// Reading stops at the first line starting with `JJ: ignore-rest`; every other line starting
/// with `JJ:` is dropped; the rest is joined with `\n`, its leading and trailing newlines are
/// trimmed, and a non-empty result ends in exactly one `\n` (`text_util::complete_newline`).
pub(crate) fn cleanup_description_lines<I>(lines: I) -> String
where
    I: IntoIterator,
    I::Item: AsRef<str>,
{
    let mut description = String::new();
    for line in lines {
        let line = line.as_ref();
        if line.starts_with("JJ: ignore-rest") {
            break;
        }
        if !line.starts_with("JJ:") {
            description.push_str(line);
            description.push('\n');
        }
    }
    complete_newline(description.trim_matches('\n'))
}

/// A description from the CLI's repeatable `-m` — ports `description_util.rs:421-428`
/// `join_message_paragraphs` @ v0.46.0: each paragraph newline-terminated
/// (`complete_newline`), a blank line between two.
pub(crate) fn join_message_paragraphs(paragraphs: &[String]) -> String {
    paragraphs
        .iter()
        .map(|p| complete_newline(p.as_str()))
        .collect::<Vec<_>>()
        .join("\n")
}

/// `cli/src/text_util.rs:27-33` `complete_newline` @ v0.46.0: a non-empty text gets a final
/// `\n` when it has none.
pub(crate) fn complete_newline(text: &str) -> String {
    let mut text = text.to_owned();
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    text
}

/// Appends `new_trailers` to `description`'s last paragraph, skipping duplicates.
///
/// Ports `description_util.rs:449-476` `add_trailers_with_template` @ v0.46.0 minus the template
/// rendering, which [`crate::template::add_trailers_with`] does (Story 9.51): it hands over the
/// [`Trailer`]s `parse_trailers` read from the rendered `templates.commit_trailers`.
///
/// Two rules carried over verbatim:
///
/// - The paragraph break is inserted ONLY when the description has no trailer block yet AND
///   there is at least one new trailer. An empty description first gets a leading newline,
///   reserving its first line for a summary.
/// - Dedup is by full [`Trailer`] equality (key AND value) against
///   `parse_description_trailers` of the EXISTING description. That parser is the lenient
///   one — it reads a whole message and returns nothing when the last paragraph is not a
///   clean trailer block; its strict sibling `parse_trailers` is for trailer-only text.
///
/// # Input contract
///
/// The CLI's inputs are always normalized — its trailers come from `parse_trailers` of
/// rendered template text, its descriptions from jj itself. Taking a plain `&str` and
/// caller-built [`Trailer`]s moves that onto the caller, and this port deliberately adds
/// no validation (it would diverge from the verbatim behaviour NFR-R-2 pins). Three
/// consequences follow:
///
/// - **`description` should end in `\n` when it is non-empty.** Trailers are appended with
///   no separator beyond the paragraph rule above, so `"subject"` (no newline) plus one
///   trailer yields `"subject\n\nkey: value\n"` when a trailer block is opened — but if the
///   description ALREADY ends in a trailer block, the new line is glued straight onto
///   whatever the last line is.
/// - **A key or value containing `\n` corrupts the block silently.** The embedded newline
///   splits the trailer paragraph, so a later `parse_description_trailers` of the result
///   sees a non-trailer line and returns NO trailers at all — including the ones that were
///   already there.
/// - **`new_trailers` is not deduplicated against itself.** Dedup is only against the
///   EXISTING description, so the same trailer listed twice is written twice.
pub(crate) fn apply_trailers(description: &str, new_trailers: &[Trailer]) -> String {
    let existing = parse_description_trailers(description);
    let mut out = description.to_owned();
    if existing.is_empty() && !new_trailers.is_empty() {
        if out.is_empty() {
            // A first empty line, where the GUI will put the commit summary.
            out.push('\n');
        }
        out.push('\n');
    }
    for trailer in new_trailers {
        if !existing.contains(trailer) {
            out.push_str(&trailer.key);
            out.push_str(": ");
            out.push_str(&trailer.value);
            out.push('\n');
        }
    }
    out
}

// ── §4 Selected tree ──────────────────────────────────────────────────────────────

/// The tree a partial-commit verb (squash, split, …) should actually write.
///
/// Replaces the CLI's `DiffSelector` (`cli_util.rs:3494`). Its `NonInteractive` arm is
/// [`SelectedTree::from_paths`]; its `Interactive` arm — which spawns a diff editor — is
/// replaced by [`SelectedTree::from_tree_id`], where the GUI has already done the hunk
/// selection and hands back a written tree (ADR-0003).
#[derive(Debug)]
pub(crate) struct SelectedTree(MergedTree);

impl SelectedTree {
    /// Selects by path: restores everything matching `matcher` from `trees.after` onto
    /// `trees.before`.
    ///
    /// Argument order mirrors the CLI's `DiffSelector::select` call into jj-lib's
    /// `restore_tree` exactly (`after` is the source, `before` the destination), so a
    /// full-tree matcher yields `trees.after` and a matcher that matches nothing yields
    /// `trees.before`.
    ///
    /// # Errors
    ///
    /// - [`MutateError::Backend`] — a jj-lib backend failure while diffing or writing.
    pub(crate) fn from_paths(
        trees: Diff<&MergedTree>,
        tree_labels: Diff<String>,
        matcher: &dyn Matcher,
    ) -> Result<Self, MutateError> {
        let tree = pollster::block_on(restore_tree(
            trees.after,
            trees.before,
            tree_labels.after,
            tree_labels.before,
            matcher,
        ))
        .map_err(be)?;
        Ok(Self(tree))
    }

    /// Re-hydrates a tree [`crate::Repo::select_tree`] wrote (Story 9.50) — its tree ids and
    /// conflict labels, so a conflicted selection keeps its labels.
    ///
    /// Every id is verified against the store: `MergedTree::new` never touches the backend, so an
    /// unknown id would otherwise only surface much later, inside an unrelated call.
    ///
    /// # Errors
    ///
    /// - [`MutateError::InvalidInput`] — an even or zero id count, an id that is not hex, or a
    ///   label count that is neither zero nor the id count.
    /// - [`MutateError::Backend`] — no such tree in the store, or a backend read failure.
    pub(crate) fn from_tree_id(store: &Arc<Store>, tree: &crate::SelectedTreeId) -> Result<Self, MutateError> {
        let (tree_ids, labels) = tree.parse()?;
        for tree_id in &tree_ids {
            pollster::block_on(store.get_tree(RepoPathBuf::root(), tree_id)).map_err(be)?;
        }
        Ok(Self(MergedTree::new(store.clone(), tree_ids, labels)))
    }

    /// The selected tree.
    pub(crate) fn tree(&self) -> &MergedTree {
        &self.0
    }

    /// Assembles jj-lib's `CommitWithSelection`, the input of `rewrite::squash_commits`
    /// and friends.
    pub(crate) fn into_commit_selection(self, commit: Commit, parent_tree: MergedTree) -> CommitWithSelection {
        CommitWithSelection {
            commit,
            selected_tree: self.0,
            parent_tree,
        }
    }
}

// ── §5 Shared revision + path resolution ──────────────────────────────────────────
//
// Both families of verbs — the mutations in `mutate.rs` and the file reads in `file.rs` —
// resolve "which revision" and "which paths" by exactly the same rules, but flatten a
// failure into different public error types. The RULES therefore live here once and each
// family maps [`ResolveError`] into its own taxonomy; a second copy would drift from the
// mutation verbs' semantics the first time either rule is touched.

/// Why a revision could not be resolved — the part of the rule that is shared, in a form
/// neither [`MutateError`] nor [`crate::FileError`] owns.
#[derive(Debug)]
pub(crate) enum ResolveError {
    /// The id is empty, is not valid reverse-hex, is absent from the index, points only
    /// at hidden/abandoned commits, or is DIVERGENT — all indistinguishable, and all a
    /// refusal rather than a guess.
    NotFound,
    /// The revision was omitted, so it is `@`, and the workspace has no working-copy commit —
    /// the CLI's user error `RevsetResolutionError::WorkspaceMissingWorkingCopy`, whose text
    /// ("Workspace `<name>` doesn't have a working-copy commit") this carries.
    NoWorkingCopy(String),
    /// An underlying jj-lib failure (index lookup or store read).
    Backend(String),
}

/// Resolves `id` to its visible jj-lib [`Commit`].
///
/// Same pattern as `change.rs::get_change` (empty/malformed reverse-hex, absent, or
/// only-hidden all collapse to [`ResolveError::NotFound`]), but against any `Repo` — a
/// `MutableRepo` mid-transaction or a head-resolved `ReadonlyRepo`; `resolve_change_id` and
/// `store()` are both on the `Repo` trait and work identically on either.
///
/// Unlike the read-only `get_change` (which reports divergence via `Change::divergent` and
/// silently picks the first visible target), a DIVERGENT id also collapses to `NotFound`
/// here: silently acting on an arbitrary one of several ambiguous commits would be unsafe,
/// and the real `jj` CLI likewise refuses an ambiguous revision argument (`-r` is
/// `resolve_single_rev`) rather than guessing.
///
/// # Errors
///
/// - [`ResolveError::NotFound`] — see the variant's doc.
/// - [`ResolveError::Backend`] — an index or store read failed.
pub(crate) fn resolve_commit(repo: &dyn jj_lib::repo::Repo, id: &crate::ChangeId) -> Result<Commit, ResolveError> {
    // WHY the explicit empty guard: `HexPrefix::from_id` on an empty id would reach
    // jj-lib's `panic!("complete change_id should be unambiguous")` path.
    if id.0.is_empty() {
        return Err(ResolveError::NotFound);
    }
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0).ok_or(ResolveError::NotFound)?;
    let targets = pollster::block_on(repo.resolve_change_id(&jj_id))
        .map_err(|e| ResolveError::Backend(e.to_string()))?
        .ok_or(ResolveError::NotFound)?;
    let visible = targets.into_visible().ok_or(ResolveError::NotFound)?;
    let [commit_id] = visible.as_slice() else {
        return Err(ResolveError::NotFound);
    };
    repo.store()
        .get_commit(commit_id)
        .map_err(|e| ResolveError::Backend(e.to_string()))
}

/// The CLI's `resolve_revsets_ordered` (`cli_util.rs:1845-1858` @ v0.46.0) over change ids:
/// each id resolved in argument order, duplicates dropped — the CLI's `IndexSet`. `None` stays
/// `None` (the flag was not given). Shared by `split -o/-A/-B` and `new [-A/-B]`, so the two
/// verbs cannot dedup differently.
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — an id is malformed, absent, only-hidden, or divergent
///   (the first such id, in argument order).
/// - [`MutateError::Backend`] — a store read failed.
pub(crate) fn resolve_ordered(
    tx: &Transaction,
    ids: Option<&[crate::ChangeId]>,
) -> Result<Option<Vec<CommitId>>, MutateError> {
    let Some(ids) = ids else {
        return Ok(None);
    };
    let mut resolved: Vec<CommitId> = Vec::with_capacity(ids.len());
    for id in ids {
        let commit_id = crate::mutate::resolve_commit(tx.repo(), id)?.id().clone();
        if !resolved.contains(&commit_id) {
            resolved.push(commit_id);
        }
    }
    Ok(Some(resolved))
}

/// Why a COMMIT-id prefix could not be resolved.
///
/// Three stages where [`ResolveError`] has one: the change-id resolver deliberately collapses
/// malformed/unknown/ambiguous into a single `NotFound`, because a reverse-hex change id that
/// resolves to several commits is *divergence*, which is a repo state rather than a typo. A
/// commit-id prefix has no such excuse — "you typed something that is not hex", "that prefix is
/// too short" and "no such commit" need three different remedies — so the split survives here
/// and each caller maps it onto its own taxonomy.
#[derive(Debug)]
pub(crate) enum CommitPrefixError {
    /// The prefix is EMPTY or is not valid hex — a structurally invalid argument, not a miss.
    Malformed,
    /// Two or more indexed commits carry the prefix; refused rather than guessed.
    Ambiguous,
    /// Valid hex, but no indexed commit carries it.
    NotFound,
    /// An underlying jj-lib failure (index lookup or store read).
    Backend(String),
}

/// Resolves a commit-id HEX prefix to its jj-lib [`Commit`] — VISIBLE OR NOT.
///
/// WHY the bare index lookup rather than a revset or the CLI's `IdPrefixContext`: the CLI
/// resolves a bare hex symbol through `CommitPrefixResolver`, which first consults the
/// `revsets.short-prefixes` disambiguation set and, on `NoMatch`, falls back to exactly this
/// call (`jj-lib-0.44.0 id_prefix.rs:161-189`). That fallback is a pure byte-prefix search over
/// every INDEXED commit with no visibility filter, which is the whole mechanism this resolver
/// exists for: a HIDDEN commit — an evolog predecessor among them — resolves here, where
/// [`resolve_commit`]'s `into_visible()` refuses it.
///
/// Adopting the context would buy one narrow case (a prefix ambiguous repo-wide but unique
/// inside `revsets.log`) at the price of a config read plus a revset parse+evaluate per call,
/// which would give the commit-view verbs `Config` and `RevsetParseError` failure modes they do
/// not have today. We refuse instead of guessing — the safe direction, and the same choice
/// [`resolve_commit`] makes (it calls `resolve_change_id` with no prefix context either). A
/// DELIBERATE divergence from the CLI, and the reason the default disambiguation set does not
/// help anyway: it holds only visible commits, so a hidden predecessor needs a repo-wide-unique
/// prefix in the CLI too.
///
/// This is the commit-id CURRENCY, not a symbol resolver: there is no bookmark, tag or
/// change-id fallback.
///
/// # Errors
///
/// - [`CommitPrefixError::Malformed`] — `id` is empty or is not valid hex.
/// - [`CommitPrefixError::Ambiguous`] — the prefix matches several commits.
/// - [`CommitPrefixError::NotFound`] — valid hex, no match.
/// - [`CommitPrefixError::Backend`] — an index or store read failed.
pub(crate) fn resolve_commit_id_prefix(
    repo: &dyn jj_lib::repo::Repo,
    id: &crate::CommitId,
) -> Result<Commit, CommitPrefixError> {
    // WHY the explicit empty guard: `try_from_hex("")` succeeds with an EMPTY prefix, which
    // every indexed commit matches — so an omitted value would report as ambiguous (or, in a
    // one-commit repo, silently resolve) instead of being named as the caller bug it is.
    if id.0.is_empty() {
        return Err(CommitPrefixError::Malformed);
    }
    let prefix = jj_lib::object_id::HexPrefix::try_from_hex(&id.0).ok_or(CommitPrefixError::Malformed)?;
    let resolution = pollster::block_on(repo.index().resolve_commit_id_prefix(&prefix))
        .map_err(|e| CommitPrefixError::Backend(e.to_string()))?;
    match resolution {
        jj_lib::object_id::PrefixResolution::SingleMatch(commit_id) => repo
            .store()
            .get_commit(&commit_id)
            .map_err(|e| CommitPrefixError::Backend(e.to_string())),
        jj_lib::object_id::PrefixResolution::AmbiguousMatch => Err(CommitPrefixError::Ambiguous),
        jj_lib::object_id::PrefixResolution::NoMatch => Err(CommitPrefixError::NotFound),
    }
}

/// Resolves `id`, or — when it is `None` — the workspace's working-copy commit, mirroring
/// the CLI's `RevisionArg::AT` (`@`) default for every omitted revision argument.
///
/// `@` is the working-copy commit the pre-verb snapshot has just recorded (Story 9.26).
///
/// # Errors
///
/// - [`ResolveError::NotFound`] — `id` is present but does not resolve (see
///   [`resolve_commit`]).
/// - [`ResolveError::NoWorkingCopy`] — `id` is `None` and the workspace has no working-copy
///   commit (a workspace forgotten from another one).
/// - [`ResolveError::Backend`] — a store read failed.
pub(crate) fn resolve_or_wc(
    repo: &dyn jj_lib::repo::Repo,
    workspace_name: &jj_lib::ref_name::WorkspaceName,
    id: Option<&crate::ChangeId>,
) -> Result<Commit, ResolveError> {
    if let Some(id) = id {
        return resolve_commit(repo, id);
    }
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace_name)
        .ok_or_else(|| {
            ResolveError::NoWorkingCopy(
                jj_lib::revset::RevsetResolutionError::WorkspaceMissingWorkingCopy {
                    name: workspace_name.to_owned(),
                }
                .to_string(),
            )
        })?
        .clone();
    repo.store()
        .get_commit(&wc_id)
        .map_err(|e| ResolveError::Backend(e.to_string()))
}

/// Builds the file matcher every path-filtered verb — both content ops and all four file
/// reads — filters with.
///
/// An EMPTY `paths` means "all paths" (`EverythingMatcher`); otherwise each entry is a
/// repo-relative path interpreted as a PREFIX, parsed by [`parse_prefixes`].
///
/// WHY not the fileset DSL: the CLI parses `paths` with `fileset::parse_maybe_bare`, whose
/// *bare* form is exactly `prefix_path` — so `PrefixMatcher` reproduces the CLI's
/// observable behavior for the input a GUI actually produces (a file/directory selection).
/// The DSL itself is terminal *input language*, which ADR-0003 replaces rather than ports.
///
/// An EMPTY STRING entry is the repository ROOT (`RepoPathBuf::from_internal_string("")`
/// succeeds — jj's validity rule is only "no leading/trailing `/`, no `//`"), and the root
/// is a prefix of every path. So `paths = [""]` matches EVERYTHING, exactly as `paths = []`
/// does, and mixing `""` into a list widens that list to everything. That is a DECISION,
/// not an accident: it is what the CLI's own bare `prefix_path("")` does, and refusing it
/// here would invent a validation rule jj does not have. A GUI that means "no paths" should
/// send an empty LIST, not a list holding an empty string. Pinned by
/// `build_matcher_treats_an_empty_path_entry_as_the_repo_root` in `mutate.rs`.
///
/// `.` and `..` components resolve the way the CLI resolves a path typed at the workspace root
/// (Story 9.49 closing run): `./x` is `x`, `a/../b` is `b`, `.` and `a/..` are the root, and a
/// `..` that leaves the repository is refused — see [`parse_prefixes`].
///
/// # Errors
///
/// Returns the human-readable reason an entry is not a valid repo path (a leading or
/// trailing `/`, or a `//`), or leaves the repository through `..` (`invalid path: Path
/// "../x" is not in the repo "."`); each caller wraps it in its own "invalid input" variant.
pub(crate) fn build_matcher(paths: &[String]) -> Result<Box<dyn Matcher>, String> {
    if paths.is_empty() {
        return Ok(Box::new(jj_lib::matchers::EverythingMatcher));
    }
    Ok(Box::new(jj_lib::matchers::PrefixMatcher::new(parse_prefixes(paths)?)))
}

/// The entries of `paths` as repo paths — [`build_matcher`]'s prefixes, and the EXPLICIT paths
/// the CLI's `print_unmatched_explicit_paths` checks (Story 9.32), so its warnings name the
/// RESOLVED path, as the CLI's do. Empty for an empty list.
///
/// Each entry is first checked by `RepoPath::from_internal_string` (so `/x`, `x/` and `a//b`
/// stay refused and `""` stays the root — note the CLI accepts `x/` and `a//b`, normalising
/// them to `x` and `a/b`; refusing them is this module's older, deliberate contract, kept), then
/// resolved through jj-lib's
/// `ui_path::parse_fs_path` (`ui_path.rs:156-169` @ jj-lib 0.46.0) — the function the CLI's
/// `parse_file_path` and Story 9.22's `wc_ops::parse_paths` call — with a synthetic `"."` as
/// both the cwd and the workspace root. For the `.`/`..` components that is exact, not an
/// approximation: the entry is already repo-relative, and `parse_fs_path` is purely lexical (`file_util::normalize_path` +
/// `relative_path` + `RepoPathBuf::from_relative_path`), so `.` drops, `..` pops, and a `..`
/// with nothing left to pop is refused with jj-lib's own text — what the CLI prints when run
/// from the workspace root — with no workspace handle needed.
///
/// # Errors
///
/// As [`build_matcher`].
pub(crate) fn parse_prefixes(paths: &[String]) -> Result<Vec<RepoPathBuf>, String> {
    let root = Path::new(".");
    paths
        .iter()
        .map(|path| {
            RepoPath::from_internal_string(path).map_err(|e| format!("invalid path: {e}"))?;
            parse_fs_path(root, root, path).map_err(|e| format!("invalid path: {e}"))
        })
        .collect()
}

// ── §6 Transaction opening ────────────────────────────────────────────────────────

/// Opens a transaction on `repo` on behalf of `workspace_name` — the ONLY sanctioned
/// transaction opener in `crates/zanshin-jj/src`.
///
/// That scope is the whole shipped surface: `zanshin-jj` is the sole production crate that
/// imports `jj_lib` (`lib.rs`), so no other crate CAN open a transaction. The direct openers in
/// `crates/test-helpers` and `crates/xtask` are outside it deliberately — a test fixture and a
/// build-time fixture generator, neither part of what ships, and both writing operations no user
/// undoes.
///
/// Ports `cli/src/cli_util.rs:2883-2894` `start_repo_transaction` @ v0.44.0, through which the
/// CLI funnels every transaction it opens. Two of its three statements are reproduced:
/// `ReadonlyRepo::start_transaction` and [`Transaction::set_workspace_name`], which is what puts
/// `workspace_name` into the operation's metadata. The op log is on-disk state a user reads with
/// `jj op log`/`jj op show` and that multi-workspace repos rely on, so recording it is parity
/// (NFR-R-2), not decoration.
///
/// The CLI's third statement — the `command_args_to_transaction_attribute` loop
/// (`cli_util.rs:2896`) — is deliberately NOT ported: it encodes the terminal command line that
/// ADR-0003 replaces with a GUI, so there is no argv to record. Nothing else is invented here:
/// `hostname`/`username`/`time` already come from jj-lib's own `create_op_metadata`
/// (`transaction.rs:176-198`) off the [`jj_lib::settings::UserSettings`], and `is_snapshot` is
/// not this helper's business in the CLI either.
///
/// `workspace_name` must be the name of the workspace the caller's `Workspace` handle was opened
/// for — `Workspace::workspace_name()`, exactly as the caller this port mirrors
/// (`cli_util.rs:2286-2298`) passes `self.workspace_name()`. Never a constant, and never derived
/// from a path: in a repo with several workspaces the two differ, and the operation must name the
/// one that ran it. `tests/it/op_workspace_name.rs` witnesses that from a SECOND workspace, which is
/// the only place a constant `default` would show.
///
/// The CLI has a second caller, the snapshot path (`cli_util.rs:2099`), which follows it with
/// `set_is_snapshot(true)`; Zanshin's port of it, `snapshot::commit_snapshot` (Story 9.26), does
/// exactly that on this helper's result — `is_snapshot` is not this helper's business in the CLI
/// either.
///
/// A guard test in this module's `tests` asserts that no other file under
/// `crates/zanshin-jj/src` calls `start_transaction` directly, so an operation cannot regain a
/// `workspace_name: None` by a new call site slipping in. An inline `#[cfg(test)]` test that
/// needs to fabricate repo state is bound by that guard too: open its transaction through this
/// helper, or build the state with `test-helpers`, whose own direct openers are out of scope.
pub(crate) fn start_repo_transaction(repo: &Arc<ReadonlyRepo>, workspace_name: &WorkspaceName) -> Transaction {
    let mut tx = repo.start_transaction();
    tx.set_workspace_name(workspace_name);
    tx
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::Arc;

    use jj_lib::backend::CommitId;
    use jj_lib::config::StackedConfig;
    use jj_lib::matchers::{EverythingMatcher, NothingMatcher};
    use jj_lib::merge::Diff;
    use jj_lib::merged_tree::MergedTree;
    use jj_lib::object_id::ObjectId as _;
    use jj_lib::repo::{ReadonlyRepo, Repo as _};
    use jj_lib::revset::{ResolvedRevsetExpression, RevsetExpression};
    use jj_lib::trailer::Trailer;
    use test_helpers::{extract_fixture, set_tag};

    use super::{
        apply_trailers, check_rewritable, cleanup_description_lines, combine_messages_for_editing,
        compute_commit_location, join_message_paragraphs, resolve_immutable, try_combine_messages, SelectedTree,
    };
    use crate::template::Templates;
    use crate::{MutateError, Repo};

    // The lib test binary's shared env pin: the guard must see the fixture's own config, not
    // the developer's `~/.jjconfig.toml` (which may override `immutable_heads()`).
    fn pin_env() {
        test_helpers::pin_test_env();
    }

    /// The fixture opened at head: its start-up environment and the immutable set resolved.
    struct AtHead {
        repo: Repo,
        config: StackedConfig,
        env: crate::snapshot::CommandEnv,
        readonly: Arc<ReadonlyRepo>,
        immutable: Arc<ResolvedRevsetExpression>,
    }

    impl AtHead {
        /// The head-resolved repo, its immutable set and the call's templates.
        fn parts(&self) -> (&Arc<ReadonlyRepo>, &Arc<ResolvedRevsetExpression>, Templates<'_>) {
            let templates = Templates::new(
                &self.config,
                &self.env.immutable,
                &self.env.template_startup,
                self.repo.workspace(),
            );
            (&self.readonly, &self.immutable, templates)
        }
    }

    /// Opens the fixture and returns the head-resolved repo plus its immutable set.
    fn immutable_at_head(path: &Path) -> AtHead {
        let repo = Repo::open(path).expect("fixture opens");
        let config = crate::config::load(&repo).expect("config loads");
        let env =
            crate::snapshot::CommandEnv::load(repo.workspace(), &config, &mut crate::warning::Warnings::default())
                .expect("builtin immutable_heads() parses");
        let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("load_at_head");
        let immutable = resolve_immutable(readonly.as_ref(), &env.immutable).expect("immutable set resolves");
        AtHead {
            repo,
            config,
            env,
            readonly,
            immutable,
        }
    }

    /// The fixture's `Commit 1 -> Commit 2 -> Commit 3` chain, by description.
    fn commit_by_description(readonly: &ReadonlyRepo, description: &str) -> CommitId {
        let store = readonly.store();
        for head in readonly.view().heads() {
            let mut cur = store.get_commit(head).expect("head commit");
            loop {
                if cur.description() == description {
                    return cur.id().clone();
                }
                let Some(parent_id) = cur.parent_ids().first() else {
                    break;
                };
                if parent_id == store.root_commit_id() {
                    break;
                }
                cur = store.get_commit(parent_id).expect("parent commit");
            }
        }
        panic!("fixture has no commit described {description:?}");
    }

    /// The fixture's `@` — an empty, undescribed commit off root, unrelated to the chain.
    fn working_copy_commit(readonly: &ReadonlyRepo) -> CommitId {
        readonly
            .view()
            .wc_commit_ids()
            .values()
            .next()
            .expect("fixture has a working-copy commit")
            .clone()
    }

    // ── §1 guard ──────────────────────────────────────────────────────────────

    #[test]
    fn check_rewritable_accepts_a_mutable_commit() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, immutable, templates) = at.parts();
        let target = commit_by_description(readonly, "Commit 1");

        check_rewritable(readonly.as_ref(), immutable, &templates, std::slice::from_ref(&target))
            .expect("an untagged, un-trunk'd commit is mutable");
    }

    #[test]
    fn check_rewritable_refuses_the_first_immutable_commit() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        // `tiny-3-commits` has no remote bookmarks and no tags, so `trunk()` degenerates to
        // `root()` and the immutable set is exactly `::root()`. `tags()` is a term of
        // `builtin_immutable_heads()`, so a tag is the lever that makes a non-root commit
        // immutable without touching the fixture on disk.
        let head = {
            let at = immutable_at_head(&fx.path);
            commit_by_description(&at.readonly, "Commit 2")
        };
        set_tag(&fx.path, "v1", &[&head.hex()]);

        let at = immutable_at_head(&fx.path);
        let (readonly, immutable, templates) = at.parts();
        let ancestor = commit_by_description(readonly, "Commit 1");
        let err = check_rewritable(
            readonly.as_ref(),
            immutable,
            &templates,
            std::slice::from_ref(&ancestor),
        )
        .expect_err("Commit 1 is an ancestor of the tagged Commit 2");
        assert!(
            matches!(&err, MutateError::Immutable { commit_id, .. } if *commit_id == ancestor.hex()),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn check_rewritable_accepts_an_empty_target_list() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, immutable, templates) = at.parts();

        check_rewritable(readonly.as_ref(), immutable, &templates, &[])
            .expect("nothing to rewrite is trivially rewritable");
    }

    // ── §2 location ───────────────────────────────────────────────────────────

    #[test]
    fn compute_commit_location_after_only_uses_direct_children() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, _, templates) = at.parts();
        let one = commit_by_description(readonly, "Commit 1");
        let two = commit_by_description(readonly, "Commit 2");

        let (parents, children) = compute_commit_location(
            readonly.as_ref(),
            &templates,
            None,
            Some(std::slice::from_ref(&one)),
            None,
            "commit",
        )
        .expect("-A resolves");

        assert_eq!(parents, vec![one]);
        assert_eq!(children, vec![two]);
    }

    #[test]
    fn compute_commit_location_before_only_keeps_parent_order_and_dedups() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, _, templates) = at.parts();
        let two = commit_by_description(readonly, "Commit 2");
        let three = commit_by_description(readonly, "Commit 3");
        let wc = working_copy_commit(readonly);
        let root = readonly.store().root_commit_id().clone();

        // `Commit 3`'s parent is `Commit 2`; `@`'s parent is the root commit. Target order
        // therefore puts `Commit 2` FIRST — the revset form (`RevsetExpression::parents`)
        // would yield index order instead, which is exactly why the CLI avoids it. The
        // repeated `Commit 3` proves the dedup.
        let (parents, children) = compute_commit_location(
            readonly.as_ref(),
            &templates,
            None,
            None,
            Some(&[three.clone(), wc.clone(), three.clone()]),
            "commit",
        )
        .expect("-B resolves");

        assert_eq!(parents, vec![two, root]);
        assert_eq!(children, vec![three.clone(), wc, three]);
    }

    #[test]
    fn compute_commit_location_after_and_before_are_taken_verbatim() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, _, templates) = at.parts();
        let one = commit_by_description(readonly, "Commit 1");
        let three = commit_by_description(readonly, "Commit 3");

        let (parents, children) = compute_commit_location(
            readonly.as_ref(),
            &templates,
            None,
            Some(std::slice::from_ref(&one)),
            Some(std::slice::from_ref(&three)),
            "commit",
        )
        .expect("-A + -B resolves");

        assert_eq!(parents, vec![one]);
        assert_eq!(children, vec![three]);
    }

    #[test]
    fn compute_commit_location_destination_yields_no_children() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, _, templates) = at.parts();
        let three = commit_by_description(readonly, "Commit 3");

        let (parents, children) = compute_commit_location(
            readonly.as_ref(),
            &templates,
            Some(std::slice::from_ref(&three)),
            None,
            None,
            "commit",
        )
        .expect("--onto resolves");

        assert_eq!(parents, vec![three]);
        assert!(children.is_empty());
    }

    #[test]
    fn compute_commit_location_refuses_destination_with_insert_after() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, _, templates) = at.parts();
        let one = commit_by_description(readonly, "Commit 1");

        let err = compute_commit_location(
            readonly.as_ref(),
            &templates,
            Some(std::slice::from_ref(&one)),
            Some(std::slice::from_ref(&one)),
            None,
            "commit",
        )
        .expect_err("the CLI panics here; a library must refuse");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("cannot be combined with")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn compute_commit_location_refuses_destination_with_insert_before() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, _, templates) = at.parts();
        let one = commit_by_description(readonly, "Commit 1");

        let err = compute_commit_location(
            readonly.as_ref(),
            &templates,
            Some(std::slice::from_ref(&one)),
            None,
            Some(std::slice::from_ref(&one)),
            "commit",
        )
        .expect_err("the CLI panics here; a library must refuse");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("cannot be combined with")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn compute_commit_location_refuses_an_empty_location() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, _, templates) = at.parts();

        let err = compute_commit_location(readonly.as_ref(), &templates, None, None, None, "commit")
            .expect_err("the CLI panics here; a library must refuse");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("at least one of")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn compute_commit_location_refuses_a_loop() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, _, templates) = at.parts();
        let one = commit_by_description(readonly, "Commit 1");
        let three = commit_by_description(readonly, "Commit 3");

        // Parent = the chain head, child = its own ancestor: inserting between them would
        // make `Commit 1` both an ancestor and a descendant.
        let err = compute_commit_location(
            readonly.as_ref(),
            &templates,
            None,
            Some(std::slice::from_ref(&three)),
            Some(std::slice::from_ref(&one)),
            "commit",
        )
        .expect_err("this location is a cycle");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("Refusing to create a loop")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn compute_commit_location_refuses_an_immutable_child() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let two = {
            let at = immutable_at_head(&fx.path);
            commit_by_description(&at.readonly, "Commit 2")
        };
        set_tag(&fx.path, "v1", &[&two.hex()]);

        let at = immutable_at_head(&fx.path);
        let (readonly, _, templates) = at.parts();
        let one = commit_by_description(readonly, "Commit 1");
        let err = compute_commit_location(
            readonly.as_ref(),
            &templates,
            None,
            Some(std::slice::from_ref(&one)),
            None,
            "commit",
        )
        .expect_err("the resolved child (Commit 2) is tagged, hence immutable");
        assert!(
            matches!(err, MutateError::Immutable { .. }),
            "unexpected error: {err:?}"
        );
    }

    /// The CLI resolves the immutable set only for a location with children (its
    /// `check_rewritable`): a leaf's `-A` never reads an unresolvable alias.
    #[test]
    fn compute_commit_location_resolves_the_immutable_set_only_for_children() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let unresolvable = RevsetExpression::symbol("nonexistent_symbol_xyz".to_owned());
        let templates = Templates::new(&at.config, &unresolvable, &at.env.template_startup, at.repo.workspace());
        let one = commit_by_description(&at.readonly, "Commit 1");
        let three = commit_by_description(&at.readonly, "Commit 3");

        let (parents, children) = compute_commit_location(
            at.readonly.as_ref(),
            &templates,
            None,
            Some(std::slice::from_ref(&three)),
            None,
            "commit",
        )
        .expect("a leaf has no children, so the set is never resolved");
        assert_eq!(parents, vec![three]);
        assert!(children.is_empty());

        let err = compute_commit_location(
            at.readonly.as_ref(),
            &templates,
            None,
            Some(std::slice::from_ref(&one)),
            None,
            "commit",
        )
        .expect_err("Commit 1 has a child, so the set is resolved");
        assert!(
            matches!(&err, MutateError::Config { reason } if reason.starts_with("Invalid `revset-aliases.immutable_heads()`: ")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn compute_commit_location_refuses_an_empty_parent_set() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let at = immutable_at_head(&fx.path);
        let (readonly, _, templates) = at.parts();

        // `-A` with no targets resolves no parents and no children.
        let err = compute_commit_location(readonly.as_ref(), &templates, None, Some(&[]), None, "commit")
            .expect_err("no parents is refused");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "No revisions found to use as parent"),
            "unexpected error: {err:?}"
        );
    }

    // ── §3 descriptions ───────────────────────────────────────────────────────

    #[test]
    fn try_combine_messages_picks_the_single_non_empty_description() {
        assert_eq!(try_combine_messages(&["", "x"], ""), Some("x".to_owned()));
        assert_eq!(try_combine_messages(&["", ""], "dest"), Some("dest".to_owned()));
    }

    #[test]
    fn try_combine_messages_returns_empty_when_none_is_set() {
        assert_eq!(try_combine_messages(&["", ""], ""), Some(String::new()));
        assert_eq!(try_combine_messages(&[], ""), Some(String::new()));
    }

    #[test]
    fn try_combine_messages_returns_none_when_ambiguous() {
        assert_eq!(try_combine_messages(&["a", "b"], ""), None);
        assert_eq!(try_combine_messages(&["a"], "dest"), None);
    }

    /// The CLI's editor buffer: the destination first, every source under its own header —
    /// an EMPTY source description included (`description_util.rs:374-385` @ v0.46.0).
    #[test]
    fn combine_messages_for_editing_lists_every_description_under_its_header() {
        assert_eq!(
            combine_messages_for_editing(&["C\n", ""], Some("B\n"), &[]),
            "JJ: Description from the destination commit:\nB\n\nJJ: Description from source commit:\nC\n\n\
             JJ: Description from source commit:\n"
        );
        assert_eq!(
            combine_messages_for_editing(&["C\n"], None, &[]),
            "\nJJ: Description from source commit:\nC\n"
        );
    }

    /// The CLI's trailer block (`description_util.rs:~396-403` @ v0.46.0), only when a trailer is
    /// missing.
    #[test]
    fn combine_messages_for_editing_appends_the_missing_trailers_block() {
        assert_eq!(
            combine_messages_for_editing(&["C\n"], Some("B\n"), &[trailer("Signed-off-by", "Z <z@l>")]),
            "JJ: Description from the destination commit:\nB\n\nJJ: Description from source commit:\nC\n\n\
             JJ: Trailers not found in the squashed commits:\nSigned-off-by: Z <z@l>\n"
        );
    }

    /// `JJ:` lines are dropped, `JJ: ignore-rest` ends the text, leading and trailing newlines
    /// are trimmed and a non-empty result ends in exactly one `\n`.
    #[test]
    fn cleanup_description_lines_follows_the_cli_rules() {
        let clean = |text: &str| cleanup_description_lines(text.lines());
        assert_eq!(clean("JJ: intro\n\nsubject\nJJ: Change ID: x\n\n\n"), "subject\n");
        assert_eq!(clean("a\nJJ: ignore-rest\nb\n"), "a\n");
        assert_eq!(clean("a\nJJ: ignore-rest trailing words\nb\n"), "a\n");
        assert_eq!(clean("\n\nbody\n\nmore"), "body\n\nmore\n");
        assert_eq!(clean("JJ: only comments\n"), "");
        assert_eq!(clean(""), "");
        assert_eq!(clean("not JJ: a comment\n"), "not JJ: a comment\n");
    }

    /// Spec example (Story 9.15): destination `"B\n"`, abandoned source `"C\n"` → `"B\n\nC\n"`
    /// once the buffer is cleaned up; an empty source adds nothing but its (dropped) header.
    #[test]
    fn the_combined_buffer_cleaned_up_keeps_the_descriptions() {
        let saved = |sources: &[&str], destination| {
            cleanup_description_lines(combine_messages_for_editing(sources, destination, &[]).lines())
        };
        assert_eq!(saved(&["C\n"], Some("B\n")), "B\n\nC\n");
        assert_eq!(saved(&["C\n", "", "D"], Some("B\n")), "B\n\nC\n\n\nD\n");
        // A description without its final newline runs straight into the next header.
        assert_eq!(saved(&["C", "D\n"], None), "C\nD\n");
    }

    #[test]
    fn join_message_paragraphs_matches_the_cli() {
        assert_eq!(join_message_paragraphs(&["T".to_owned(), "U\n".to_owned()]), "T\n\nU\n");
        assert_eq!(join_message_paragraphs(&[]), "");
        assert_eq!(join_message_paragraphs(&[String::new()]), "");
    }

    fn trailer(key: &str, value: &str) -> Trailer {
        Trailer {
            key: key.to_owned(),
            value: value.to_owned(),
        }
    }

    #[test]
    fn apply_trailers_opens_a_new_paragraph_after_prose() {
        let out = apply_trailers("subject\n", &[trailer("Reviewed-by", "Ada")]);
        assert_eq!(out, "subject\n\nReviewed-by: Ada\n");
    }

    #[test]
    fn apply_trailers_on_an_empty_description_reserves_a_summary_line() {
        let out = apply_trailers("", &[trailer("Reviewed-by", "Ada")]);
        assert_eq!(out, "\n\nReviewed-by: Ada\n");
    }

    #[test]
    fn apply_trailers_appends_directly_to_an_existing_trailer_block() {
        let out = apply_trailers("subject\n\nReviewed-by: Ada\n", &[trailer("Tested-by", "Bob")]);
        assert_eq!(out, "subject\n\nReviewed-by: Ada\nTested-by: Bob\n");
    }

    #[test]
    fn apply_trailers_skips_a_duplicate_and_keeps_a_differing_value() {
        let existing = "subject\n\nReviewed-by: Ada\n";
        assert_eq!(apply_trailers(existing, &[trailer("Reviewed-by", "Ada")]), existing);
        assert_eq!(
            apply_trailers(existing, &[trailer("Reviewed-by", "Bob")]),
            "subject\n\nReviewed-by: Ada\nReviewed-by: Bob\n"
        );
    }

    #[test]
    fn apply_trailers_without_new_trailers_is_the_identity() {
        assert_eq!(apply_trailers("subject\n", &[]), "subject\n");
        assert_eq!(apply_trailers("", &[]), "");
    }

    // ── §4 selected tree ──────────────────────────────────────────────────────

    /// `(before, after)` trees of the fixture's `Commit 1`: its parent's tree and its own.
    fn commit_trees(readonly: &ReadonlyRepo) -> (MergedTree, MergedTree) {
        let store = readonly.store();
        let id = commit_by_description(readonly, "Commit 1");
        let commit = store.get_commit(&id).expect("Commit 1");
        let parent = store
            .get_commit(commit.parent_ids().first().expect("Commit 1 has a parent"))
            .expect("parent commit");
        (parent.tree(), commit.tree())
    }

    fn labels() -> Diff<String> {
        Diff::new("before".to_owned(), "after".to_owned())
    }

    #[test]
    fn from_paths_with_everything_matcher_selects_the_whole_after_tree() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let readonly = immutable_at_head(&fx.path).readonly;
        let (before, after) = commit_trees(&readonly);

        let selected = SelectedTree::from_paths(Diff::new(&before, &after), labels(), &EverythingMatcher)
            .expect("restore_tree succeeds");
        assert_eq!(selected.tree().tree_ids(), after.tree_ids());
    }

    #[test]
    fn from_paths_with_nothing_matcher_selects_the_before_tree() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let readonly = immutable_at_head(&fx.path).readonly;
        let (before, after) = commit_trees(&readonly);

        let selected =
            SelectedTree::from_paths(Diff::new(&before, &after), labels(), &NothingMatcher).expect("restore_tree");
        assert_eq!(selected.tree().tree_ids(), before.tree_ids());
    }

    fn selected_tree(ids: &[&str], labels: &[&str]) -> crate::SelectedTreeId {
        crate::SelectedTreeId {
            tree_ids: ids.iter().map(|&id| id.to_owned()).collect(),
            labels: labels.iter().map(|&label| label.to_owned()).collect(),
        }
    }

    #[test]
    fn from_tree_id_rehydrates_a_known_tree_and_assembles_a_selection() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let readonly = immutable_at_head(&fx.path).readonly;
        let store = readonly.store();
        let (before, after) = commit_trees(&readonly);
        let hex = after
            .tree_ids()
            .as_resolved()
            .expect("fixture trees are conflict-free")
            .hex();

        let selected =
            SelectedTree::from_tree_id(store, &selected_tree(&[&hex], &[])).expect("a written tree id re-hydrates");
        assert_eq!(selected.tree().tree_ids(), after.tree_ids());

        let id = commit_by_description(&readonly, "Commit 1");
        let commit = store.get_commit(&id).expect("Commit 1");
        let selection = selected.into_commit_selection(commit, before);
        assert!(selection.is_full_selection());
        assert!(!selection.is_empty_selection());
    }

    #[test]
    fn from_tree_id_refuses_a_malformed_id() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let readonly = immutable_at_head(&fx.path).readonly;

        let err =
            SelectedTree::from_tree_id(readonly.store(), &selected_tree(&["nothex"], &[])).expect_err("not valid hex");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason.contains("malformed tree id")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn from_tree_id_refuses_an_unknown_id() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let readonly = immutable_at_head(&fx.path).readonly;

        let err = SelectedTree::from_tree_id(readonly.store(), &selected_tree(&[&"ab".repeat(20)], &[]))
            .expect_err("well-formed hex, but no such tree");
        assert!(matches!(err, MutateError::Backend(_)), "unexpected error: {err:?}");
    }

    /// An even id count, no id at all, or a label count that is neither zero nor the id count
    /// refuses before the store is read.
    #[test]
    fn from_tree_id_refuses_a_malformed_shape() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let readonly = immutable_at_head(&fx.path).readonly;
        let id = "ab".repeat(20);
        for (ids, labels) in [
            (vec![id.as_str(), id.as_str()], vec![]),
            (vec![], vec![]),
            (vec![id.as_str()], vec!["one", "two"]),
        ] {
            let err = SelectedTree::from_tree_id(readonly.store(), &selected_tree(&ids, &labels))
                .expect_err("malformed shape");
            assert!(
                matches!(err, MutateError::InvalidInput { .. }),
                "unexpected error: {err:?}"
            );
        }
    }

    /// A conflicted tree re-hydrates with its labels.
    #[test]
    fn from_tree_id_keeps_a_conflicted_trees_labels() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let readonly = immutable_at_head(&fx.path).readonly;
        let (before, after) = commit_trees(&readonly);
        let hex = |tree: &MergedTree| tree.tree_ids().as_resolved().expect("resolved").hex();
        let ids = [hex(&after), hex(&before), hex(&after)];
        let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
        let selected = SelectedTree::from_tree_id(readonly.store(), &selected_tree(&ids, &["a", "base", "b"]))
            .expect("three known trees");
        assert_eq!(selected.tree().tree_ids().num_sides(), 2);
        assert_eq!(selected.tree().labels().as_slice(), ["a", "base", "b"]);
    }

    // ── §6 transaction opening ────────────────────────────────────────────────

    /// Every non-comment line mentioning the bare identifier `start_transaction`, as
    /// `"<path>:<line>"`.
    ///
    /// A pure function over already-read `(path, contents)` pairs so the negative probes can
    /// feed it a synthetic violation instead of writing one into the tree. The needle is the
    /// BARE identifier, which is unambiguous precisely because the sanctioned opener is named
    /// `start_repo_transaction` — that name does not contain this substring, so a call to it
    /// never false-positives, while a method call, a UFCS
    /// `ReadonlyRepo::start_transaction(&repo)` and a plain mention all match.
    ///
    /// Line-leading comments are skipped, the same rule `Makefile.toml`'s
    /// `test-jj-adapter-hygiene` gate applies to its own source grep. A mention inside a
    /// TRAILING comment, a `/* … */` block or a string literal still counts as a hit. That
    /// over-flagging is deliberate and the safe direction: it costs a rephrased sentence and a
    /// loud, obvious test failure, where the opposite error would let a real opener through.
    fn direct_transaction_openers(sources: &[(String, String)]) -> Vec<String> {
        let mut hits = Vec::new();
        for (path, contents) in sources {
            for (index, line) in contents.lines().enumerate() {
                if line.trim_start().starts_with("//") {
                    continue;
                }
                if line.contains("start_transaction") {
                    hits.push(format!("{path}:{}", index + 1));
                }
            }
        }
        hits
    }

    /// Reads every `*.rs` file under `dir` (recursively) as a `(path, contents)` pair.
    ///
    /// `crates/zanshin-jj/src` is flat today; the recursion is what keeps the guard honest the
    /// day a module gains a subdirectory, so it is exercised deliberately by
    /// [`the_scan_descends_into_subdirectories`] rather than left to grow stale.
    fn read_rust_sources(dir: &Path) -> Vec<(String, String)> {
        let mut sources = Vec::new();
        for entry in std::fs::read_dir(dir).expect("crate src/ is readable") {
            let path = entry.expect("readable dir entry").path();
            if path.is_dir() {
                sources.extend(read_rust_sources(&path));
            } else if path.extension().is_some_and(|ext| ext == "rs") {
                let contents = std::fs::read_to_string(&path).expect("source file is UTF-8");
                sources.push((path.display().to_string(), contents));
            }
        }
        sources
    }

    /// The crate's own `src/`, minus `op_support.rs` — the one file allowed to open a
    /// transaction.
    ///
    /// Matched on the FILE NAME, not on a path suffix: `path.ends_with("op_support.rs")` would
    /// also exempt a future `git_op_support.rs`, silently, which is the one way this guard could
    /// go quiet without anyone noticing.
    fn crate_sources_outside_op_support() -> Vec<(String, String)> {
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        read_rust_sources(&src)
            .into_iter()
            .filter(|(path, _)| Path::new(path).file_name() != Some("op_support.rs".as_ref()))
            .collect()
    }

    /// The creep guard: an operation must never regain a `workspace_name: None` because a new
    /// call site opened its transaction directly instead of through
    /// [`super::start_repo_transaction`].
    #[test]
    fn no_source_file_outside_op_support_opens_a_transaction_directly() {
        let sources = crate_sources_outside_op_support();
        // A bare count would be satisfied by any directory holding a few `.rs` files. Naming two
        // modules that both open transactions proves the scan read THIS crate's `src/`.
        for expected in ["mutate.rs", "convert.rs"] {
            assert!(
                sources
                    .iter()
                    .any(|(path, _)| Path::new(path).file_name() == Some(expected.as_ref())),
                "the scan never saw {expected} — it is not reading this crate's src/"
            );
        }

        let hits = direct_transaction_openers(&sources);
        assert!(
            hits.is_empty(),
            "these call sites bypass op_support::start_repo_transaction, so their operations \
             record no workspace_name: {hits:?}"
        );
    }

    /// The guard must also fail if the helper itself is deleted or renamed — otherwise a
    /// refactor could satisfy "no direct openers" by having no openers at all.
    #[test]
    fn op_support_still_defines_the_sanctioned_opener() {
        let helper = Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join("op_support.rs");
        let contents = std::fs::read_to_string(&helper).expect("op_support.rs is readable");
        assert!(
            contents.contains("fn start_repo_transaction"),
            "the sanctioned transaction opener is gone; the creep guard now guards nothing"
        );
    }

    /// A nested module directory is scanned too, and non-`.rs` files are left alone — the
    /// guard must not go blind the first time this crate's `src/` stops being flat.
    #[test]
    fn the_scan_descends_into_subdirectories() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        std::fs::write(tmp.path().join("top.rs"), "fn top() {}\n").expect("write top.rs");
        std::fs::write(tmp.path().join("notes.txt"), "repo.start_transaction()\n").expect("write notes.txt");
        let nested = tmp.path().join("nested");
        std::fs::create_dir(&nested).expect("create nested dir");
        std::fs::write(nested.join("deep.rs"), "let mut tx = repo.start_transaction();\n").expect("write deep.rs");

        let sources = read_rust_sources(tmp.path());
        assert_eq!(sources.len(), 2, "both .rs files, and only those: {sources:?}");

        let hits = direct_transaction_openers(&sources);
        assert_eq!(hits.len(), 1, "the nested violation must be found: {hits:?}");
        assert!(hits[0].ends_with("deep.rs:1"), "got {}", hits[0]);
    }

    /// Negative probe: the scanner really does report a violation, at the right line.
    #[test]
    fn the_scanner_reports_a_synthetic_violation() {
        let sources = vec![(
            "fake.rs".to_owned(),
            "let mut tx = repo.start_transaction();".to_owned(),
        )];
        assert_eq!(direct_transaction_openers(&sources), vec!["fake.rs:1".to_owned()]);
    }

    /// A UFCS call is caught too — the reason the needle is the bare identifier rather than
    /// `.start_transaction(`.
    #[test]
    fn the_scanner_reports_a_ufcs_violation() {
        let sources = vec![(
            "fake.rs".to_owned(),
            "\nlet mut tx = ReadonlyRepo::start_transaction(&repo);".to_owned(),
        )];
        assert_eq!(direct_transaction_openers(&sources), vec!["fake.rs:2".to_owned()]);
    }

    /// Comment lines are data, not call sites — and a call to the sanctioned helper is not a
    /// violation, because its name does not contain the needle.
    #[test]
    fn the_scanner_ignores_comments_and_the_sanctioned_helper() {
        let sources = vec![(
            "fake.rs".to_owned(),
            concat!(
                "// never call repo.start_transaction() directly\n",
                "    /// see `start_transaction` in jj-lib\n",
                "let mut tx = start_repo_transaction(&repo, &workspace_name);\n",
            )
            .to_owned(),
        )];
        assert!(direct_transaction_openers(&sources).is_empty());
    }

    // ── parse_prefixes: `.`/`..` resolve like the CLI's paths (Story 9.49 closing run) ──

    fn prefixes(entries: &[&str]) -> Result<Vec<String>, String> {
        let paths: Vec<String> = entries.iter().map(|e| (*e).to_owned()).collect();
        super::parse_prefixes(&paths).map(|v| v.iter().map(|p| p.as_internal_file_string().to_owned()).collect())
    }

    #[test]
    fn parse_prefixes_resolves_dot_components_lexically() {
        assert_eq!(prefixes(&["."]), Ok(vec![String::new()]));
        assert_eq!(prefixes(&["./x"]), Ok(vec!["x".to_owned()]));
        assert_eq!(prefixes(&["a/../b"]), Ok(vec!["b".to_owned()]));
        assert_eq!(prefixes(&["a/.."]), Ok(vec![String::new()]));
        assert_eq!(prefixes(&["x/./y"]), Ok(vec!["x/y".to_owned()]));
        assert_eq!(prefixes(&["", "a/b"]), Ok(vec![String::new(), "a/b".to_owned()]));
        assert_eq!(prefixes(&[]), Ok(vec![]));
    }

    #[test]
    fn parse_prefixes_refuses_a_path_that_leaves_the_repo_with_the_cli_text() {
        for entry in ["..", "../x", "a/../../x"] {
            assert_eq!(
                prefixes(&["ok", entry]),
                Err(format!(r#"invalid path: Path "{entry}" is not in the repo ".""#)),
                "{entry}"
            );
        }
    }

    #[test]
    fn parse_prefixes_keeps_refusing_what_is_not_a_repo_path() {
        for entry in ["/x", "x/", "a//b"] {
            let reason = prefixes(&[entry]).expect_err(entry);
            assert!(reason.starts_with("invalid path: "), "{reason}");
            assert!(!reason.contains("is not in the repo"), "{reason}");
        }
    }
}
