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
//! - **§2 Insert-location resolution** — `cli_util.rs:3551` `compute_commit_location` /
//!   `:3641` `ensure_no_commit_loop`.
//! - **§3 Description combination and trailers** — `description_util.rs:299`
//!   `try_combine_messages` / `:392` `add_trailers_with_template`.
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
//! `op_metadata.workspace_name` the way a CLI-written one does (Epic 9 follow-up L). §2,
//! §3 and §4's GUI-selected-tree arm ship tested-but-unwired because their consumers
//! (squash/split/rebase/duplicate/revert) are Tier C verbs that land in later stories.
//!
//! The CLI's two `panic!`s in `compute_commit_location` become
//! [`MutateError::InvalidInput`]: a library must not abort the process on a caller-reachable
//! path.

use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::{CommitId, TreeId};
use jj_lib::commit::Commit;
use jj_lib::config::StackedConfig;
use jj_lib::conflict_labels::ConflictLabels;
use jj_lib::matchers::Matcher;
use jj_lib::merge::{Diff, Merge};
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::ReadonlyRepo;
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::revset::{ResolvedRevsetExpression, RevsetExpression, UserRevsetExpression};
use jj_lib::rewrite::{restore_tree, CommitWithSelection};
use jj_lib::store::Store;
use jj_lib::trailer::{parse_description_trailers, Trailer};
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::mutate::{be, cfg, MutateError};
use crate::revset::{immutable_expression, resolve_expression, revset_config};

// ── §1 Rewritability guard ────────────────────────────────────────────────────────

/// Builds the repo's effective immutable-set expression, `::(immutable_heads() | root())`.
///
/// The canonical per-operation idiom (`graph.rs`): load the effective config, build the
/// alias map from every layer, then construct the expression in code. A user's
/// `revset-aliases."immutable_heads()"` therefore REPLACES the builtin by (name, arity),
/// exactly as it does for the CLI — the guard reads the effective config, never a Rust
/// constant.
///
/// Built off an already-loaded stack for a bare [`Workspace`], so the pre-verb snapshot's
/// start-up environment ([`crate::snapshot::CommandEnv`], Stories 9.26 / 9.34) — and the
/// conversion verbs, which have no [`crate::Repo`] yet — read it from the one config load every
/// verb makes.
///
/// # Errors
///
/// - [`MutateError::Config`] — the repo's jj config is malformed or unreadable, or the
///   `immutable_heads()` alias does not parse. Both are the SAME fault the CLI reports as
///   ``Invalid `revset-aliases.immutable_heads()` `` (`cli_util.rs:1139`), and the same one
///   the read side surfaces as [`crate::RevsetError::Config`] — never the unclassified
///   backend bucket, and never a silent fall-back to the builtin set.
pub(crate) fn immutable_user_expression(
    workspace: &Workspace,
    config: &StackedConfig,
    sink: &mut crate::warning::Warnings,
) -> Result<Arc<UserRevsetExpression>, MutateError> {
    let parse_config = revset_config(config, sink).map_err(cfg)?;
    immutable_expression(workspace, &parse_config, sink).map_err(cfg)
}

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
///   ``Invalid `revset-aliases.immutable_heads()` `` — because the alias, not the caller's
///   argument, is what is wrong.
pub(crate) fn resolve_immutable(
    repo: &dyn jj_lib::repo::Repo,
    expr: &Arc<UserRevsetExpression>,
) -> Result<Arc<ResolvedRevsetExpression>, MutateError> {
    resolve_expression(repo, expr).map_err(cfg)
}

/// Refuses the rewrite if any of `commit_ids` is inside the immutable set.
///
/// Ports `cli_util.rs:2011` `check_rewritable_expr`: intersect the immutable set with the
/// targets, stream the result, and refuse on the FIRST element. The CLI takes `try_next`,
/// never a list, so the refusal names one offender even when several are immutable — the
/// GUI gets the same "here is what blocks you" signal, and the extra hints the CLI prints
/// (a commit summary, doc links, an estimated blast radius) are presentation, not behavior.
///
/// The root commit is reported as immutable by the CLI. `describe`/`abandon` guard it
/// explicitly BEFORE calling this — see `mutate.rs` — so root keeps refusing with
/// `InvalidInput` there, while `edit` (which needs no such guard) reports it here. Either
/// way the call refuses and no op-log entry is written, which is the observable behavior
/// NFR-R-2 pins.
///
/// # Errors
///
/// - [`MutateError::Immutable`] — the first target found inside the immutable set.
/// - [`MutateError::Backend`] — an underlying jj-lib evaluation failure.
pub(crate) fn check_rewritable(
    repo: &dyn jj_lib::repo::Repo,
    immutable: &Arc<ResolvedRevsetExpression>,
    commit_ids: &[CommitId],
) -> Result<(), MutateError> {
    let to_rewrite = RevsetExpression::commits(commit_ids.to_vec());
    let set = immutable.intersection(&to_rewrite).evaluate(repo).map_err(be)?;
    let mut stream = set.stream();
    match pollster::block_on(stream.try_next()).map_err(be)? {
        None => Ok(()),
        Some(commit_id) => Err(MutateError::Immutable {
            commit_id: commit_id.hex(),
        }),
    }
}

// ── §2 Insert-location resolution ─────────────────────────────────────────────────
//
// WHY `allow(dead_code)` from here on: §2-§4 exist for the Tier C verbs (squash, split,
// rebase, duplicate, revert) that land in later stories, so nothing in the crate calls
// them yet. They are exercised by this module's own `#[cfg(test)]` tests — which is also
// why `expect(dead_code)` would be wrong: in the test build the lint does not fire, and an
// unfulfilled expectation is itself a warning. Drop each attribute when its first real
// caller arrives.

/// Computes the `(new_parents, new_children)` a commit should be placed between.
///
/// Ports `cli_util.rs:3551` `compute_commit_location` over ALREADY-RESOLVED commit ids:
/// callers own their own revset parsing (`RevisionArg` is a CLI concept), which keeps this
/// layer free of parse concerns and directly unit-testable. `destination` is the `--onto`
/// form and is mutually exclusive with `insert_after` (`-A`) / `insert_before` (`-B`).
///
/// `commit_type` is the noun the loop refusal names ("commit", "commits", "revision", …) —
/// passed through from the caller exactly as the CLI passes it (FR-JJ-17).
///
/// `immutable` is threaded in rather than resolved here so this function stays free of
/// config plumbing; the CLI reaches its equivalent through `WorkspaceCommandHelper`.
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
/// - [`MutateError::Backend`] — an underlying jj-lib evaluation or backend failure.
#[allow(dead_code)]
pub(crate) fn compute_commit_location(
    repo: &dyn jj_lib::repo::Repo,
    immutable: &Arc<ResolvedRevsetExpression>,
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
        (Some(_), Some(_), _) | (Some(_), _, Some(_)) => {
            return Err(MutateError::InvalidInput {
                reason: "--onto cannot be combined with -A/--insert-after or -B/--insert-before".to_owned(),
            })
        }
        (None, None, None) => {
            return Err(MutateError::InvalidInput {
                reason: "expected at least one of --onto, -A/--insert-after or -B/--insert-before".to_owned(),
            })
        }
    };

    if !new_child_ids.is_empty() {
        check_rewritable(repo, immutable, &new_child_ids)?;
        ensure_no_commit_loop(
            repo,
            &RevsetExpression::commits(new_child_ids.clone()),
            &RevsetExpression::commits(new_parent_ids.clone()),
            commit_type,
        )?;
    }

    if new_parent_ids.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "No revisions found to use as parent".to_owned(),
        });
    }

    Ok((new_parent_ids, new_child_ids))
}

/// Refuses a location whose children would also be ancestors of its parents.
///
/// Ports `cli_util.rs:3641` `ensure_no_commit_loop`, message included (the 12-hex-digit
/// short form comes from jj-lib's `Display`, which pads/truncates the full hex).
#[allow(dead_code)]
fn ensure_no_commit_loop(
    repo: &dyn jj_lib::repo::Repo,
    children: &Arc<ResolvedRevsetExpression>,
    parents: &Arc<ResolvedRevsetExpression>,
    commit_type: &str,
) -> Result<(), MutateError> {
    let set = children.dag_range_to(parents).evaluate(repo).map_err(be)?;
    let mut stream = set.stream();
    if let Some(commit_id) = pollster::block_on(stream.try_next()).map_err(be)? {
        return Err(MutateError::InvalidInput {
            reason: format!(
                "Refusing to create a loop: commit {commit_id:.12} would be both an ancestor and a descendant \
                 of the {commit_type}"
            ),
        });
    }
    Ok(())
}

// ── §3 Descriptions ───────────────────────────────────────────────────────────────

/// Combines the descriptions of the commits feeding a squash-like verb.
///
/// Ports `description_util.rs:299` `try_combine_messages` over plain strings (the CLI takes
/// `Commit`s only to read `description()`): if at most one of `sources ++ [destination]` is
/// non-empty, that one wins; `None` means two or more are non-empty.
///
/// `None` is a RESULT, not a gap. The CLI's fallback for the ambiguous case is
/// `combine_messages_for_editing` — a `JJ: `-commented `$EDITOR` buffer, precisely the
/// terminal UX ADR-0003 replaces. The backend classifies; the GUI decides.
#[allow(dead_code)]
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

/// Appends `new_trailers` to `description`'s last paragraph, skipping duplicates.
///
/// Ports `description_util.rs:392-417` `add_trailers_with_template` minus the template
/// rendering: jj's template engine is out of scope, so the caller hands over already
/// materialized [`Trailer`] values.
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
#[allow(dead_code)]
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

    /// Re-hydrates a tree the GUI selected and already wrote, named by its hex id.
    ///
    /// The id is verified against the store: `MergedTree::new` never touches the backend,
    /// so an unknown id would otherwise only surface much later, inside an unrelated call.
    ///
    /// # Errors
    ///
    /// - [`MutateError::InvalidInput`] — `tree_id_hex` is not valid hex.
    /// - [`MutateError::Backend`] — no such tree in the store, or a backend read failure.
    // WHY `allow(dead_code)`: Story 9.3 wired `from_paths` (restore) but NOT this arm —
    // its first caller is the GUI-supplied-tree side of squash/split (Story 9.15/9.17).
    // Only this item and `into_commit_selection` are still unused, so the attribute moved
    // here from the struct/impl rather than being deleted: a blanket allow that no longer
    // shields anything would let a genuinely dead item pass unnoticed. `expect(dead_code)`
    // would be wrong — the lint does not fire in the test build, where the module's own
    // `#[cfg(test)]` tests call it, and an unfulfilled expectation is itself a warning.
    #[allow(dead_code)]
    pub(crate) fn from_tree_id(store: &Arc<Store>, tree_id_hex: &str) -> Result<Self, MutateError> {
        let tree_id = TreeId::try_from_hex(tree_id_hex).ok_or_else(|| MutateError::InvalidInput {
            reason: format!("malformed tree id: {tree_id_hex}"),
        })?;
        pollster::block_on(store.get_tree(RepoPathBuf::root(), &tree_id)).map_err(be)?;
        Ok(Self(MergedTree::new(
            store.clone(),
            Merge::resolved(tree_id),
            ConflictLabels::unlabeled(),
        )))
    }

    /// The selected tree.
    pub(crate) fn tree(&self) -> &MergedTree {
        &self.0
    }

    /// Assembles jj-lib's `CommitWithSelection`, the input of `rewrite::squash_commits`
    /// and friends.
    // WHY `allow(dead_code)`: see `from_tree_id` — `squash_commits`' first caller is
    // Story 9.15/9.17, so nothing in the crate consumes a `CommitWithSelection` yet.
    #[allow(dead_code)]
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
/// - [`ResolveError::Backend`] — the workspace has no working-copy commit at all, or a
///   store read failed.
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
        .ok_or_else(|| ResolveError::Backend("workspace has no working-copy commit".to_owned()))?
        .clone();
    repo.store()
        .get_commit(&wc_id)
        .map_err(|e| ResolveError::Backend(e.to_string()))
}

/// Builds the file matcher every path-filtered verb — both content ops and all four file
/// reads — filters with.
///
/// An EMPTY `paths` means "all paths" (`EverythingMatcher`); otherwise each entry is a
/// repo-relative path interpreted as a PREFIX.
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
/// # Errors
///
/// Returns the human-readable reason an entry is not a valid repo path (a leading or
/// trailing `/`, or a `//`); each caller wraps it in its own "invalid input" variant.
pub(crate) fn build_matcher(paths: &[String]) -> Result<Box<dyn Matcher>, String> {
    if paths.is_empty() {
        return Ok(Box::new(jj_lib::matchers::EverythingMatcher));
    }
    Ok(Box::new(jj_lib::matchers::PrefixMatcher::new(parse_prefixes(paths)?)))
}

/// The entries of `paths` as repo paths — [`build_matcher`]'s prefixes, and the EXPLICIT paths
/// the CLI's `print_unmatched_explicit_paths` checks (Story 9.32). Empty for an empty list.
///
/// # Errors
///
/// As [`build_matcher`].
pub(crate) fn parse_prefixes(paths: &[String]) -> Result<Vec<RepoPathBuf>, String> {
    paths
        .iter()
        .map(|path| RepoPathBuf::from_internal_string(path.clone()).map_err(|e| format!("invalid path: {e}")))
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
/// one that ran it. `tests/op_workspace_name.rs` witnesses that from a SECOND workspace, which is
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
    use jj_lib::matchers::{EverythingMatcher, NothingMatcher};
    use jj_lib::merge::Diff;
    use jj_lib::merged_tree::MergedTree;
    use jj_lib::object_id::ObjectId as _;
    use jj_lib::repo::{ReadonlyRepo, Repo as _};
    use jj_lib::revset::ResolvedRevsetExpression;
    use jj_lib::trailer::Trailer;
    use test_helpers::{extract_fixture, set_tag};

    use super::{
        apply_trailers, check_rewritable, compute_commit_location, immutable_user_expression, resolve_immutable,
        try_combine_messages, SelectedTree,
    };
    use crate::{MutateError, Repo};

    // The lib test binary's shared env pin: the guard must see the fixture's own config, not
    // the developer's `~/.jjconfig.toml` (which may override `immutable_heads()`).
    fn pin_env() {
        test_helpers::pin_test_env();
    }

    /// Opens the fixture and returns the head-resolved repo plus its immutable set.
    fn immutable_at_head(path: &Path) -> (Arc<ReadonlyRepo>, Arc<ResolvedRevsetExpression>) {
        let repo = Repo::open(path).expect("fixture opens");
        let config = crate::config::load(&repo).expect("config loads");
        let expr = immutable_user_expression(repo.workspace(), &config, &mut crate::warning::Warnings::default())
            .expect("builtin immutable_heads() parses");
        let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("load_at_head");
        let resolved = resolve_immutable(readonly.as_ref(), &expr).expect("immutable set resolves");
        (readonly, resolved)
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
        let (readonly, immutable) = immutable_at_head(&fx.path);
        let target = commit_by_description(&readonly, "Commit 1");

        check_rewritable(readonly.as_ref(), &immutable, std::slice::from_ref(&target))
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
            let (readonly, _) = immutable_at_head(&fx.path);
            commit_by_description(&readonly, "Commit 2")
        };
        set_tag(&fx.path, "v1", &[&head.hex()]);

        let (readonly, immutable) = immutable_at_head(&fx.path);
        let ancestor = commit_by_description(&readonly, "Commit 1");
        let err = check_rewritable(readonly.as_ref(), &immutable, std::slice::from_ref(&ancestor))
            .expect_err("Commit 1 is an ancestor of the tagged Commit 2");
        assert!(
            matches!(&err, MutateError::Immutable { commit_id } if *commit_id == ancestor.hex()),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn check_rewritable_accepts_an_empty_target_list() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let (readonly, immutable) = immutable_at_head(&fx.path);

        check_rewritable(readonly.as_ref(), &immutable, &[]).expect("nothing to rewrite is trivially rewritable");
    }

    // ── §2 location ───────────────────────────────────────────────────────────

    #[test]
    fn compute_commit_location_after_only_uses_direct_children() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let (readonly, immutable) = immutable_at_head(&fx.path);
        let one = commit_by_description(&readonly, "Commit 1");
        let two = commit_by_description(&readonly, "Commit 2");

        let (parents, children) = compute_commit_location(
            readonly.as_ref(),
            &immutable,
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
        let (readonly, immutable) = immutable_at_head(&fx.path);
        let two = commit_by_description(&readonly, "Commit 2");
        let three = commit_by_description(&readonly, "Commit 3");
        let wc = working_copy_commit(&readonly);
        let root = readonly.store().root_commit_id().clone();

        // `Commit 3`'s parent is `Commit 2`; `@`'s parent is the root commit. Target order
        // therefore puts `Commit 2` FIRST — the revset form (`RevsetExpression::parents`)
        // would yield index order instead, which is exactly why the CLI avoids it. The
        // repeated `Commit 3` proves the dedup.
        let (parents, children) = compute_commit_location(
            readonly.as_ref(),
            &immutable,
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
        let (readonly, immutable) = immutable_at_head(&fx.path);
        let one = commit_by_description(&readonly, "Commit 1");
        let three = commit_by_description(&readonly, "Commit 3");

        let (parents, children) = compute_commit_location(
            readonly.as_ref(),
            &immutable,
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
        let (readonly, immutable) = immutable_at_head(&fx.path);
        let three = commit_by_description(&readonly, "Commit 3");

        let (parents, children) = compute_commit_location(
            readonly.as_ref(),
            &immutable,
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
        let (readonly, immutable) = immutable_at_head(&fx.path);
        let one = commit_by_description(&readonly, "Commit 1");

        let err = compute_commit_location(
            readonly.as_ref(),
            &immutable,
            Some(std::slice::from_ref(&one)),
            Some(std::slice::from_ref(&one)),
            None,
            "commit",
        )
        .expect_err("the CLI panics here; a library must refuse");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason } if reason.contains("cannot be combined with")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn compute_commit_location_refuses_destination_with_insert_before() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let (readonly, immutable) = immutable_at_head(&fx.path);
        let one = commit_by_description(&readonly, "Commit 1");

        let err = compute_commit_location(
            readonly.as_ref(),
            &immutable,
            Some(std::slice::from_ref(&one)),
            None,
            Some(std::slice::from_ref(&one)),
            "commit",
        )
        .expect_err("the CLI panics here; a library must refuse");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason } if reason.contains("cannot be combined with")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn compute_commit_location_refuses_an_empty_location() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let (readonly, immutable) = immutable_at_head(&fx.path);

        let err = compute_commit_location(readonly.as_ref(), &immutable, None, None, None, "commit")
            .expect_err("the CLI panics here; a library must refuse");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason } if reason.contains("at least one of")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn compute_commit_location_refuses_a_loop() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let (readonly, immutable) = immutable_at_head(&fx.path);
        let one = commit_by_description(&readonly, "Commit 1");
        let three = commit_by_description(&readonly, "Commit 3");

        // Parent = the chain head, child = its own ancestor: inserting between them would
        // make `Commit 1` both an ancestor and a descendant.
        let err = compute_commit_location(
            readonly.as_ref(),
            &immutable,
            None,
            Some(std::slice::from_ref(&three)),
            Some(std::slice::from_ref(&one)),
            "commit",
        )
        .expect_err("this location is a cycle");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason } if reason.contains("Refusing to create a loop")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn compute_commit_location_refuses_an_immutable_child() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let two = {
            let (readonly, _) = immutable_at_head(&fx.path);
            commit_by_description(&readonly, "Commit 2")
        };
        set_tag(&fx.path, "v1", &[&two.hex()]);

        let (readonly, immutable) = immutable_at_head(&fx.path);
        let one = commit_by_description(&readonly, "Commit 1");
        let err = compute_commit_location(
            readonly.as_ref(),
            &immutable,
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

    #[test]
    fn compute_commit_location_refuses_an_empty_parent_set() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let (readonly, immutable) = immutable_at_head(&fx.path);

        // `-A` with no targets resolves no parents and no children.
        let err = compute_commit_location(readonly.as_ref(), &immutable, None, Some(&[]), None, "commit")
            .expect_err("no parents is refused");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason } if reason == "No revisions found to use as parent"),
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
        let (readonly, _) = immutable_at_head(&fx.path);
        let (before, after) = commit_trees(&readonly);

        let selected = SelectedTree::from_paths(Diff::new(&before, &after), labels(), &EverythingMatcher)
            .expect("restore_tree succeeds");
        assert_eq!(selected.tree().tree_ids(), after.tree_ids());
    }

    #[test]
    fn from_paths_with_nothing_matcher_selects_the_before_tree() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let (readonly, _) = immutable_at_head(&fx.path);
        let (before, after) = commit_trees(&readonly);

        let selected =
            SelectedTree::from_paths(Diff::new(&before, &after), labels(), &NothingMatcher).expect("restore_tree");
        assert_eq!(selected.tree().tree_ids(), before.tree_ids());
    }

    #[test]
    fn from_tree_id_rehydrates_a_known_tree_and_assembles_a_selection() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let (readonly, _) = immutable_at_head(&fx.path);
        let store = readonly.store();
        let (before, after) = commit_trees(&readonly);
        let hex = after
            .tree_ids()
            .as_resolved()
            .expect("fixture trees are conflict-free")
            .hex();

        let selected = SelectedTree::from_tree_id(store, &hex).expect("a written tree id re-hydrates");
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
        let (readonly, _) = immutable_at_head(&fx.path);

        let err = SelectedTree::from_tree_id(readonly.store(), "nothex").expect_err("not valid hex");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason } if reason.contains("malformed tree id")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn from_tree_id_refuses_an_unknown_id() {
        pin_env();
        let fx = extract_fixture("tiny-3-commits").unwrap();
        let (readonly, _) = immutable_at_head(&fx.path);

        let err = SelectedTree::from_tree_id(readonly.store(), &"ab".repeat(20))
            .expect_err("well-formed hex, but no such tree");
        assert!(matches!(err, MutateError::Backend(_)), "unexpected error: {err:?}");
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
}
