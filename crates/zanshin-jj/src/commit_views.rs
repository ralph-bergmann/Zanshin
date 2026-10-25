// SPDX-License-Identifier: MIT

//! `commit_views.rs` — the three commit READ views of ADR-0003: `show`, `evolog` and
//! `interdiff` (Story 9.6, Epic 9 Tier A).
//!
//! All three are READS: they resolve to the head operation per call (ADR-0002), read
//! committed trees and the operation log, and return `jj_lib`-type-free owned data. None of
//! them opens a transaction, so the view itself writes no operation — not even on a refusal.
//! Like the CLI's `workspace_helper`, [`crate::Repo`] snapshots the working copy FIRST (Story
//! 9.26), and that snapshot is what may write one; an omitted revision is the up-to-date `@`.
//!
//! CLI parity is at tag **v0.44.0** (`cli/src/commands/{show,evolog,interdiff}.rs` plus
//! `cli/src/diff_util.rs::{show_patch,show_inter_diff,diff_status_inner}`) for the observable
//! behavior — argument arity, defaults, refusals, copy-record handling and walk order — never
//! for its terminal UX (NFR-R-2, ADR-0003). Deliberate divergences:
//!
//! - **No textual diff.** The CLI renders hunks through `DiffRenderer` in a format the user
//!   picks (`--git`, `--color-words`, `--stat`, `--summary`). Line- and word-level diffing is
//!   Epic 5 (`zanshin-diff`); the two mechanisms this story is built on —
//!   `Commit::parent_tree` and `MergedTree::diff_stream*` — produce `(path, before, after)`,
//!   which the CLI classifies into A/M/D/C/R. That per-path change list is what travels here,
//!   reusing the shipped [`crate::FileChange`] / [`crate::ChangeKind`] vocabulary so `status`,
//!   `show` and `interdiff` speak one language.
//! - **No terminal UX**: no templates, `-T`, pager, colors, graph glyphs or `--reversed`, and
//!   none of the `TopoGroupedGraph` re-ordering `evolog`'s graph mode applies — the GUI draws
//!   its own graph, so the returned order is the RAW walk order (the CLI's `--no-graph` order).
//! - **No `evolog --patch`**: the CLI's `-p` *is* an interdiff of each entry's predecessors
//!   (`cli/src/commands/evolog.rs`), so a caller composes [`evolog`] with [`interdiff`].
//! - **No path filter on `show`**: the CLI hardcodes `EverythingMatcher`
//!   (`cli/src/commands/show.rs`), and this does too.
//!
//! Parameter currency splits by kind, exactly as Story 9.3 recorded it: a single revision is a
//! [`crate::ChangeId`], but a parameter whose CLI form is a *set* stays a revset STRING so
//! aliases and config resolution survive (FR-JJ-17). `jj show` and `jj evolog` both take
//! `Vec<RevisionArg>` and union them, so they take `Option<&str>`; `jj interdiff` takes two
//! `resolve_single_rev` arguments, so it takes two single revisions.
//!
//! [`interdiff`] is the ONE verb whose single-revision parameter is a [`RevisionRef`] UNION
//! rather than a bare change id. The change-id arm is the house currency unchanged — visible
//! commits only, divergence refused — and the commit-id arm resolves a commit-id hex prefix
//! through jj-lib's index, which is visibility-BLIND. That second arm exists because the CLI's
//! `--from`/`--to` accept a commit hex and therefore reach a HIDDEN commit, and because
//! [`EvologEntry::predecessor_commit_ids`] are hidden by construction: without it the two verbs
//! could not compose into a version-to-version diff. A revset EXPRESSION (`main`, `@-`) is
//! still unaddressable on either arm.

use std::path::PathBuf;
use std::sync::Arc;

use futures::{StreamExt as _, TryStreamExt as _};
use jj_lib::commit::Commit;
use jj_lib::copies::{CopyOperation, CopyRecords};
use jj_lib::id_prefix::IdPrefixContext;
use jj_lib::matchers::{EverythingMatcher, Matcher};
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId;
use jj_lib::repo::Repo as _;
use jj_lib::revset::RevsetStreamExt as _;
use jj_lib::store::Store;
use jj_lib::workspace::Workspace;

use crate::change::change_from_commit;
use crate::op_support::{
    build_matcher, resolve_commit, resolve_commit_id_prefix, resolve_or_wc, CommitPrefixError, ResolveError,
};
use crate::{Change, ChangeId, ChangeKind, CommitId, FileChange, OperationId};

/// Which currency ONE side of [`interdiff`] is written in — the only union in the crate's
/// single-revision vocabulary.
///
/// [`RevisionRef::ChangeId`] is the house currency (Story 9.3, FR-JJ-17): a reverse-hex
/// change-id PREFIX resolved to the one VISIBLE commit carrying it, with an unknown, malformed,
/// only-hidden or DIVERGENT prefix refused rather than guessed.
///
/// [`RevisionRef::CommitId`] is a commit-id HEX prefix resolved through jj-lib's index, which is
/// visibility-BLIND — so a HIDDEN commit resolves, [`EvologEntry::predecessor_commit_ids`]
/// entries included. That arm is what lets [`evolog`] and [`interdiff`] compose into a
/// version-to-version diff, the stand-in for the CLI's unported `evolog --patch`. It is a
/// CURRENCY, not a symbol resolver: no bookmark, tag or change-id fallback.
///
/// [`interdiff`] is the ONLY consumer — every other verb keeps its own parameter currency.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RevisionRef {
    /// A reverse-hex change-id prefix; resolves to the one VISIBLE commit carrying it.
    ChangeId(ChangeId),
    /// A commit-id hex prefix; resolves through the index and therefore reaches hidden commits.
    CommitId(CommitId),
}

/// One revision as `jj show` presents it: its metadata plus what it changed relative to its
/// parents (Story 9.6).
///
/// `change` is built by the crate's single [`Change`] construction site, so it is byte-identical
/// to what [`crate::Repo::get_change`] reports for the same commit. `file_changes` is the diff of
/// `Commit::parent_tree` (all parents merged) against the commit's own tree, classified exactly
/// as the CLI's `diff_status_inner` does — for a MERGE that is only what the merge itself
/// changed.
#[derive(Debug)]
pub struct ShowEntry {
    /// Full metadata for the revision.
    pub change: Change,
    /// Per-path changes relative to the merged parent tree, in jj-lib's own diff order.
    pub file_changes: Vec<FileChange>,
    /// The tree `file_changes` diff against — `Commit::parent_tree`, what `split`, `squash` and
    /// `commit` diff against too — as hex tree ids in `Merge` order (one for a resolved tree, an
    /// odd number for a conflicted merge of parents). It is the `left` a hunk selection is made
    /// against ([`crate::Repo::select_tree`], Story 9.50). jj-lib returns the commit's OWN tree
    /// for a commit its index knows to be empty — the same tree, so the same `left` the verbs see.
    pub parent_tree_ids: Vec<String>,
    /// The revision's OWN tree as hex tree ids in `Merge` order (Story 9.17) — the `left` of a
    /// selection made against this revision as the `from` of another one
    /// ([`crate::SelectTreeOptions::from`], `diffedit --from`).
    pub tree_ids: Vec<String>,
}

/// What `jj interdiff` reports: the per-path change list, plus whether the tree it diffed FROM
/// was conflicted (Story 9.6).
///
/// `file_changes` is the whole CLI-parity payload. `base_has_conflicts` is a ZANSHIN-SIDE
/// addition the CLI has no counterpart for — it renders conflict markers in the patch TEXT,
/// which is Epic 5's surface here — so without it a caller sees a plausible change list derived
/// from a conflicted rebase with no way to tell.
#[derive(Debug)]
pub struct InterdiffView {
    /// Per-path changes `to` makes that `from` does not, in jj-lib's own diff order. NEVER a
    /// [`ChangeKind::Renamed`]/[`ChangeKind::Copied`] entry — see [`interdiff`].
    pub file_changes: Vec<FileChange>,
    /// Whether the REBASED `from` tree — the LEFT side of the diff, which exists only in memory
    /// — is conflicted. Derived by `MergedTree::has_conflict()`, the same
    /// `!…is_resolved()` predicate [`Change::conflict`] is built on, so the two payloads agree.
    ///
    /// True whatever the cause: `rebase_to_dest_parent`'s 3-way merge left the conflict, OR its
    /// fast path (the two revisions already share parents) returned `from`'s own
    /// already-conflicted tree. `to`'s own conflict state is NOT reported here — that is
    /// [`Change::conflict`]'s job, reachable through [`show`] and [`crate::Repo::get_change`].
    /// It describes the TREE, not the filtered result: a `paths` filter matching nothing still
    /// leaves it set.
    pub base_has_conflicts: bool,
}

/// One step of a change's evolution as `jj evolog` walks it (Story 9.6).
///
/// Rows are keyed by COMMIT id rather than change id: every predecessor of a change shares its
/// change id, so a list of [`Change`] rows would differ only in `commit_id` — and predecessors
/// are HIDDEN by construction, which the crate's single-revision resolver refuses.
#[derive(Debug)]
pub struct EvologEntry {
    /// Full metadata for this version of the change.
    ///
    /// Two of its fields are derived against the CURRENT view rather than against the moment
    /// this version existed, because they come from the single [`Change`] construction site
    /// (`change.rs::change_from_commit`) that every other verb uses: `divergent` reports
    /// whether the change has several VISIBLE commits right now — the same answer on every
    /// row of one evolution, and never a statement about this historical version — and
    /// `is_anonymous` reads today's local bookmarks. Everything else (`commit_id`, `parents`,
    /// `description`, signatures, timestamps, `conflict`) is this version's own.
    pub change: Change,
    /// The commit ids this version was rewritten FROM, as the recording operation stored them.
    /// Empty when `operation_id` is `None`, and for a commit that was never rewritten.
    pub predecessor_commit_ids: Vec<CommitId>,
    /// The operation that created or rewrote this commit, or `None` for an entry the walk
    /// emitted from its flush tail — it reached an operation that stores no predecessors and
    /// could go no further. `None` is therefore the only signal a caller has that an evolution
    /// may be TRUNCATED; the CLI truncates silently.
    pub operation_id: Option<OperationId>,
}

/// Errors returned by [`crate::Repo::show`], [`crate::Repo::evolog`] and
/// [`crate::Repo::interdiff`].
///
/// Named `CommitViewError` because `ViewError` is already taken by `view.rs`. Every variant maps
/// onto an error code the registry already carries — this story mints none.
#[derive(Debug, thiserror::Error)]
pub enum CommitViewError {
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
    /// A single-revision argument (`interdiff`'s `from`/`to`) is malformed, carried by no VISIBLE
    /// commit (unknown or only-hidden), or DIVERGENT — the same refusal every other
    /// single-revision parameter makes, because the CLI resolves both sides with
    /// `resolve_single_rev`. Not to be confused with an ABSENT side, which is not an error at
    /// all: it applies the CLI's `--from`/`--to` default `@` (omitting BOTH is `InvalidInput`).
    #[error("change not found: {id}")]
    ChangeNotFound {
        /// The reverse-hex change id that could not be resolved.
        id: String,
    },
    /// The caller's arguments are structurally invalid: `interdiff` was given NEITHER `from` nor
    /// `to` (the CLI's `ArgGroup … required(true)`), or a `paths` entry is not a valid repo path.
    #[error("invalid input: {reason}")]
    InvalidInput {
        /// Human-readable reason the input was rejected.
        reason: String,
    },
    /// A revset expression is syntactically invalid or names an unknown function.
    #[error("invalid revset: {reason}")]
    RevsetParseError {
        /// Human-readable parse failure from jj-lib.
        reason: String,
        /// The CLI's hint lines for the error, verbatim and in the CLI's order.
        hints: Vec<String>,
    },
    /// A revset expression is well-formed but a symbol could not be resolved (unknown
    /// bookmark/tag, missing `@`, unmatched id).
    #[error("cannot resolve revset: {reason}")]
    RevsetResolutionError {
        /// Human-readable resolution failure from jj-lib.
        reason: String,
        /// The CLI's hint lines for the error, verbatim and in the CLI's order; empty for the
        /// change/commit-id resolutions and the missing working copy
        /// (`ResolveError::NoWorkingCopy`), which have none.
        hints: Vec<String>,
    },
    /// The repo's effective jj config is unreadable or malformed, so the revset aliases
    /// [`show`]/[`evolog`] parse against could not be built. Reported separately from
    /// [`CommitViewError::Backend`] because it is the user's own config that is wrong, not the
    /// repository — the distinction every other config-reading verb makes.
    #[error("config error: {reason}")]
    Config {
        /// Human-readable reason the effective config could not be used.
        reason: String,
    },
    /// An underlying jj-lib failure, opaque-string-wrapped so no `jj_lib` type escapes the
    /// public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`CommitViewError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> CommitViewError {
    CommitViewError::Backend(e.to_string())
}

/// Converts a read-side [`crate::RevsetError`] to the matching variant, preserving the
/// three-stage taxonomy rather than collapsing it — the same mapping `mutate.rs::rev` makes for
/// the mutation side.
fn rev(e: crate::RevsetError) -> CommitViewError {
    match e {
        crate::RevsetError::ParseError { reason, detail } => CommitViewError::RevsetParseError {
            reason,
            hints: detail.hints,
        },
        crate::RevsetError::ResolutionError { reason, detail } => CommitViewError::RevsetResolutionError {
            reason,
            hints: detail.hints,
        },
        crate::RevsetError::Config(inner) => CommitViewError::Config {
            reason: inner.to_string(),
        },
        crate::RevsetError::JjLibError(reason) => CommitViewError::Backend(reason),
        crate::RevsetError::Precondition(inner) => CommitViewError::Precondition(inner),
        // Only `Repo::graph_topology` raises it; no commit view walks a graph.
        e @ crate::RevsetError::DanglingEdge { .. } => CommitViewError::Backend(e.to_string()),
    }
}

/// Converts a shared [`ResolveError`] to this module's taxonomy, preserving the
/// `ChangeNotFound { id }` / `Backend` split (`file.rs::res` is the template).
fn res(e: ResolveError, id: Option<&ChangeId>) -> CommitViewError {
    match e {
        ResolveError::NotFound => CommitViewError::ChangeNotFound {
            id: id.map(|i| i.0.clone()).unwrap_or_default(),
        },
        ResolveError::NoWorkingCopy(reason) => CommitViewError::RevsetResolutionError {
            reason,
            hints: Vec::new(),
        },
        ResolveError::Backend(reason) => CommitViewError::Backend(reason),
    }
}

/// Converts a [`CommitPrefixError`] to this module's taxonomy.
///
/// Where [`res`] has two outcomes this has four, because the commit-id arm can distinguish them:
/// a non-hex value is a structurally invalid ARGUMENT ([`CommitViewError::InvalidInput`]), a
/// prefix carried by several commits is an ambiguity ([`CommitViewError::RevsetResolutionError`]
/// — the registry's ambiguity code, where a divergent change-id symbol lands for `show`/`evolog`
/// too), and valid-hex-with-no-match is the plain not-found the change-id arm also reports.
/// No new error code is minted for either.
fn res_commit(e: CommitPrefixError, id: &CommitId) -> CommitViewError {
    match e {
        CommitPrefixError::Malformed => CommitViewError::InvalidInput {
            reason: format!("`{}` is not a valid commit id prefix", id.0),
        },
        // jj-lib's OWN error value rather than a copy of its wording: the CLI raises exactly
        // `RevsetResolutionError::AmbiguousCommitIdPrefix` for this input, so the WORDING stays
        // jj-lib's even if it rephrases it. Only the wording — the CLI hands that variant its
        // NORMALIZED `prefix.hex()`, this hands it the caller's own spelling, so an upper-case
        // prefix is echoed back as the caller wrote it.
        CommitPrefixError::Ambiguous => CommitViewError::RevsetResolutionError {
            reason: jj_lib::revset::RevsetResolutionError::AmbiguousCommitIdPrefix(id.0.clone()).to_string(),
            hints: Vec::new(),
        },
        CommitPrefixError::NotFound => CommitViewError::ChangeNotFound { id: id.0.clone() },
        CommitPrefixError::Backend(reason) => CommitViewError::Backend(reason),
    }
}

/// Resolves ONE side of [`interdiff`] to its commit.
///
/// An ABSENT side is the CLI's `@` default (the working copy the pre-verb snapshot has just
/// recorded, Story 9.26); the two present arms dispatch to the two resolvers, each mapping its own
/// error taxonomy. Written once rather than inline twice so the `from` and `to` sides cannot
/// drift apart.
fn resolve_side(
    repo: &dyn jj_lib::repo::Repo,
    workspace_name: &jj_lib::ref_name::WorkspaceName,
    side: Option<&RevisionRef>,
) -> Result<Commit, CommitViewError> {
    match side {
        None => resolve_or_wc(repo, workspace_name, None).map_err(|e| res(e, None)),
        Some(RevisionRef::ChangeId(id)) => resolve_commit(repo, id).map_err(|e| res(e, Some(id))),
        Some(RevisionRef::CommitId(id)) => resolve_commit_id_prefix(repo, id).map_err(|e| res_commit(e, id)),
    }
}

/// `jj interdiff`'s plan, shared by [`interdiff`] and `drop_actions`' interdiff row (Story 9.31
/// follow-on): `from`, then `to`, resolved by [`resolve_side`]. The CLI refuses no pair — the root,
/// an immutable commit and `from == to` all diff — so the sides resolving is the whole plan.
///
/// # Errors
///
/// - [`CommitViewError::ChangeNotFound`] / [`CommitViewError::RevsetResolutionError`] /
///   [`CommitViewError::InvalidInput`] / [`CommitViewError::Backend`] — as [`resolve_side`] maps a
///   side's resolution failure (see [`interdiff`]).
pub(crate) fn plan_interdiff(
    repo: &dyn jj_lib::repo::Repo,
    workspace_name: &jj_lib::ref_name::WorkspaceName,
    from: Option<&RevisionRef>,
    to: Option<&RevisionRef>,
) -> Result<(Commit, Commit), CommitViewError> {
    Ok((
        resolve_side(repo, workspace_name, from)?,
        resolve_side(repo, workspace_name, to)?,
    ))
}

/// Converts a `RepoPath` to a `PathBuf`.
///
/// Infallible: jj-lib enforces UTF-8 on all repo paths (`RepoPathBuf` wraps `String`). A local
/// twin of `status.rs`'s identical two-liner rather than a lift: the shared VOCABULARY
/// ([`FileChange`], [`ChangeKind`]) is reused, the derivation stays with its verb.
fn repo_path_to_pathbuf(p: &jj_lib::repo_path::RepoPath) -> PathBuf {
    PathBuf::from(p.as_internal_file_string())
}

/// Diffs two trees into the shipped per-path change vocabulary.
///
/// The classification is the CLI's `diff_status_inner` (`cli/src/diff_util.rs` @ v0.44.0): a
/// copy SOURCE decides first (`Rename`/`Copy`), otherwise absent-before is `Added`,
/// absent-after is `Removed`, and anything else is `Modified`. `TreeDiffEntry.values` is a
/// PER-PATH `BackendResult`; like the CLI this aborts on the first error rather than inventing
/// a per-path skip channel.
///
/// An EMPTY `CopyRecords` makes `diff_stream_with_copies` behave exactly like the plain
/// `diff_stream`, which is why one helper serves both the copy-aware [`show`] and the
/// deliberately copy-blind [`interdiff`].
async fn tree_file_changes(
    before: &MergedTree,
    after: &MergedTree,
    matcher: &dyn Matcher,
    records: &CopyRecords,
) -> Result<Vec<FileChange>, CommitViewError> {
    let mut stream = before.diff_stream_with_copies(after, matcher, records);
    let mut out = Vec::new();
    while let Some(entry) = stream.next().await {
        let d = entry.values.map_err(be)?;
        let kind = if let Some((src, op)) = entry.path.source {
            match op {
                CopyOperation::Rename => ChangeKind::Renamed {
                    from: repo_path_to_pathbuf(&src),
                },
                CopyOperation::Copy => ChangeKind::Copied {
                    from: repo_path_to_pathbuf(&src),
                },
            }
        } else if d.before.is_absent() && d.after.is_present() {
            ChangeKind::Added
        } else if d.before.is_present() && d.after.is_absent() {
            ChangeKind::Removed
        } else {
            ChangeKind::Modified
        };
        out.push(FileChange {
            path: repo_path_to_pathbuf(&entry.path.target),
            kind,
        });
    }
    Ok(out)
}

/// Accumulates copy records over EVERY parent of `commit`, as the CLI's `show_patch` does.
///
/// On the native (`SimpleBackend`) store the stream is empty, so renames degrade gracefully to
/// an `Added`+`Removed` pair — the same degradation `status.rs` documents.
async fn copy_records_over_all_parents(store: &Arc<Store>, commit: &Commit) -> Result<CopyRecords, CommitViewError> {
    let mut records = CopyRecords::default();
    for parent_id in commit.parent_ids() {
        let mut stream = store.get_copy_records(None, parent_id, commit.id()).map_err(be)?;
        while let Some(record) = stream.next().await {
            records.add_records([record.map_err(be)?]);
        }
    }
    Ok(records)
}

/// Shows each revision `revset` denotes with what it changed (Story 9.6) — `jj show`.
///
/// Ports `cli/src/commands/show.rs::cmd_show` @ v0.44.0: the CLI UNIONS its `Vec<RevisionArg>`
/// and defaults to `@` when none is given, so `revset` is a pass-through expression whose
/// absence means `"@"`. The revset is parsed against the repo's effective config per call
/// (never cached), then evaluated against ONE head-resolved snapshot, so a commit's metadata and
/// its diff can never come from different operations.
///
/// `limit` is a ZANSHIN-SIDE addition: `jj show` has no `-n/--limit` and streams to a pager,
/// where this builds ONE owned list whose every entry pays a merged-parent tree diff plus a
/// per-parent copy-record stream. `None` is therefore the CLI-parity default — unbounded, and
/// byte-identical to the pre-`limit` output. It is `take(n)` applied in RAW REVSET order (the
/// same order the unbounded call returns) BEFORE the per-entry work, so nothing beyond the limit
/// is computed; `Some(0)` is an empty result, not an error. Not computing them also means not
/// FAILING on them: a revset whose later commits are unreadable succeeds under a limit that stops
/// short of them and errors without one. That is the price of the early stop, and [`evolog`]'s
/// `take` has carried the same property since Story 9.6.
///
/// `revset`'s symbols resolve through `prefixes`, the call's start-up id-prefix context.
///
/// # Errors
///
/// - [`CommitViewError::RevsetParseError`] — `revset` is syntactically invalid; raised before
///   any repo read.
/// - [`CommitViewError::RevsetResolutionError`] — a symbol in `revset` cannot be resolved.
/// - [`CommitViewError::Config`] — the repo's effective jj config is unreadable or malformed.
/// - [`CommitViewError::Backend`] — the head load, evaluation, or a tree/store read failed.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn show(
    repo: &crate::Repo,
    sink: &mut crate::warning::Warnings,
    revset: Option<&str>,
    limit: Option<usize>,
    prefixes: &IdPrefixContext,
) -> Result<Vec<ShowEntry>, CommitViewError> {
    // Parse first: a syntax error costs no head-load I/O (the `eval_revset` ordering).
    let parsed = crate::revset::parse_revset(repo, revset.unwrap_or("@"), sink).map_err(rev)?;

    // Re-resolve to head ONCE (ADR-0002); every read below is taken from this snapshot.
    let readonly = crate::snapshot::reload_head(repo.workspace()).map_err(be)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let store = readonly.store();
    let set = crate::revset::evaluate_revset(repo_dyn, &parsed, Some(prefixes)).map_err(rev)?;

    let mut out = Vec::new();
    pollster::block_on(async {
        // RAW revset order (topological, children before parents) — the CLI's own order
        // without `--reversed`, which is rendering and is not ported. `take` sits on the STREAM,
        // before the loop body, so everything expensive below is skipped past `limit`.
        let mut stream = std::pin::pin!(set.stream().commits(store).take(limit.unwrap_or(usize::MAX)));
        while let Some(item) = stream.next().await {
            let commit = item.map_err(be)?;
            let change = change_from_commit(repo_dyn, &commit).map_err(CommitViewError::Backend)?;
            let after = commit.tree();
            // Merges ALL parents (root-safe): for a merge commit this is what the merge
            // itself changed. It short-circuits to the commit's own tree for an index-empty
            // commit (`commit.rs:134-143`), so it is surfaced as the `left` the verbs diff
            // against (Story 9.50), never as the parents' own tree.
            let before = commit.parent_tree(repo_dyn).await.map_err(be)?;
            let parent_tree_ids = before.tree_ids().iter().map(ObjectId::hex).collect();
            let tree_ids = after.tree_ids().iter().map(ObjectId::hex).collect();
            let records = copy_records_over_all_parents(store, &commit).await?;
            // `EverythingMatcher`: `jj show` has NO path argument (`show.rs:109`).
            let file_changes = tree_file_changes(&before, &after, &EverythingMatcher, &records).await?;
            out.push(ShowEntry {
                change,
                file_changes,
                parent_tree_ids,
                tree_ids,
            });
        }
        Ok::<(), CommitViewError>(())
    })?;
    Ok(out)
}

/// Walks the evolution of the changes `revset` denotes (Story 9.6) — `jj evolog`.
///
/// Ports `cli/src/commands/evolog.rs::cmd_evolog` @ v0.44.0 in its `--no-graph` shape: the
/// start set is the UNION of the CLI's `-r` revsets (default `@`) evaluated to commit ids, and
/// `limit` is `take(limit)` applied in walk order — the CLI limits BEFORE reversing, and the
/// reversal itself is rendering. `revset`'s symbols resolve through `prefixes`, as in [`show`].
///
/// # Errors
///
/// - [`CommitViewError::RevsetParseError`] — `revset` is syntactically invalid.
/// - [`CommitViewError::RevsetResolutionError`] — a symbol in `revset` cannot be resolved.
/// - [`CommitViewError::Config`] — the repo's effective jj config is unreadable or malformed.
/// - [`CommitViewError::Backend`] — the head load, evaluation, or an operation/store read
///   failed (including jj-lib's own predecessor-cycle detection).
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn evolog(
    repo: &crate::Repo,
    sink: &mut crate::warning::Warnings,
    revset: Option<&str>,
    limit: Option<usize>,
    prefixes: &IdPrefixContext,
) -> Result<Vec<EvologEntry>, CommitViewError> {
    let parsed = crate::revset::parse_revset(repo, revset.unwrap_or("@"), sink).map_err(rev)?;
    let readonly = crate::snapshot::reload_head(repo.workspace()).map_err(be)?;

    // Start set: commit ids, not change ids — `walk_predecessors` walks the operation log by
    // commit id, and a change's predecessors all share its change id anyway.
    let start_ids: Vec<jj_lib::backend::CommitId> = {
        let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
        let set = crate::revset::evaluate_revset(repo_dyn, &parsed, Some(prefixes)).map_err(rev)?;
        pollster::block_on(set.stream().try_collect()).map_err(be)?
    };

    let mut out = Vec::new();
    pollster::block_on(async {
        // `walk_predecessors` is a SYNC fn returning a Stream, and takes `&ReadonlyRepo`
        // (not `&dyn Repo`) — hence the `Arc` deref rather than the usual `repo_dyn`.
        let stream = jj_lib::evolution::walk_predecessors(&readonly, &start_ids);
        let mut stream = std::pin::pin!(stream.take(limit.unwrap_or(usize::MAX)));
        while let Some(item) = stream.next().await {
            let entry = item.map_err(be)?;
            let change = change_from_commit(readonly.as_ref(), &entry.commit).map_err(CommitViewError::Backend)?;
            out.push(EvologEntry {
                change,
                // `&[]` exactly when `operation` is `None` (`evolution.rs:55-60`).
                predecessor_commit_ids: entry.predecessor_ids().iter().map(|id| CommitId(id.hex())).collect(),
                operation_id: entry.operation.as_ref().map(|op| OperationId(op.id().hex())),
            });
        }
        Ok::<(), CommitViewError>(())
    })?;
    Ok(out)
}

/// Compares what two revisions each CHANGE, with the parent difference factored out
/// (Story 9.6) — `jj interdiff`.
///
/// Ports `cli/src/commands/interdiff.rs::cmd_interdiff` @ v0.44.0: both sides default to `@`
/// individually, but omitting BOTH is a refusal (the CLI's `ArgGroup … required(true)`) —
/// interdiffing `@` against itself is trivially empty and never what a caller meant.
///
/// Each side is a SINGLE revision written in one of the two [`RevisionRef`] currencies, and
/// both inherit the CLI's `resolve_single_rev` REFUSAL — an ambiguous revision is rejected
/// rather than guessed. A [`RevisionRef::ChangeId`] is the house reverse-hex change-id prefix
/// and resolves only to the currently VISIBLE commit (divergence refused); a
/// [`RevisionRef::CommitId`] is a commit-id hex prefix resolved through the index, which is
/// visibility-blind, so it reaches a HIDDEN commit. Feeding an
/// [`EvologEntry::predecessor_commit_ids`] entry in as a [`RevisionRef::CommitId`] is therefore
/// how [`evolog`] and this verb compose into a diff of one version of a change against the
/// next — for as long as that predecessor is still INDEXED: a garbage-collected one is still
/// listed by [`evolog`] but resolves to nothing, and is refused as
/// [`CommitViewError::ChangeNotFound`]. What is still NOT addressable on either arm is a revset
/// EXPRESSION (`main`, `@-`), which the CLI does accept.
///
/// `from` is rebased onto `to`'s parents in memory (`rewrite::rebase_to_dest_parent` — no
/// transaction, nothing written) and the result is diffed against `to`'s tree. Copy records are
/// deliberately EMPTY, mirroring `show_inter_diff`'s own `CopyRecords::default()`: unlike
/// [`show`], `interdiff` never reports a `Renamed`/`Copied` entry. That asymmetry is the CLI's.
///
/// The 3-way merge behind the rebase can leave conflict states in the resulting tree, and the
/// fast path returns `from`'s own tree when the parents already match — so an interdiff between
/// a commit and itself is trivially empty. Either way [`InterdiffView::base_has_conflicts`]
/// reports whether that rebased tree is conflicted; the change list is still returned, because a
/// conflicted base is a fact about the comparison, not a refusal.
///
/// An explicitly named path absent from all four trees the CLI checks (both sides and both
/// parent trees, to account for deletions) warns `jj.paths_unmatched` before the diff
/// (`interdiff.rs:99-110`, Story 9.32).
///
/// # Errors
///
/// - [`CommitViewError::InvalidInput`] — BOTH `from` and `to` are absent, a `paths` entry is
///   not a valid repo path, or a [`RevisionRef::CommitId`] is empty or not valid hex.
/// - [`CommitViewError::ChangeNotFound`] — a [`RevisionRef::ChangeId`] is malformed, carried by
///   no VISIBLE commit (unknown or only-hidden), or divergent; or a [`RevisionRef::CommitId`] is
///   valid hex that no indexed commit carries. An ABSENT side is not an error: ONE absent side
///   applies the CLI's `--from`/`--to` default `@`, and omitting BOTH is the `InvalidInput`
///   bullet above.
/// - [`CommitViewError::RevsetResolutionError`] — a [`RevisionRef::CommitId`] prefix is carried
///   by two or more commits; refused, never resolved to one of them.
/// - [`CommitViewError::Backend`] — the head load, the in-memory rebase, or a tree read failed.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn interdiff(
    workspace: &Workspace,
    sink: &mut crate::warning::Warnings,
    from: Option<&RevisionRef>,
    to: Option<&RevisionRef>,
    paths: &[String],
) -> Result<InterdiffView, CommitViewError> {
    // The CLI's ArgGroup refusal, BEFORE any repo read.
    if from.is_none() && to.is_none() {
        return Err(CommitViewError::InvalidInput {
            reason: "at least one of `from` or `to` is required".to_owned(),
        });
    }
    let matcher = build_matcher(paths).map_err(|reason| CommitViewError::InvalidInput { reason })?;

    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let (from_commit, to_commit) = plan_interdiff(repo_dyn, workspace.workspace_name(), from, to)?;
    let explicit =
        crate::op_support::parse_prefixes(paths).map_err(|reason| CommitViewError::InvalidInput { reason })?;
    let parent_trees = pollster::block_on(async {
        Ok::<_, CommitViewError>((
            from_commit.parent_tree(repo_dyn).await.map_err(be)?,
            to_commit.parent_tree(repo_dyn).await.map_err(be)?,
        ))
    })?;
    crate::warning::warn_unmatched_paths(
        sink,
        workspace.workspace_root(),
        &explicit,
        &[&parent_trees.0, &from_commit.tree(), &parent_trees.1, &to_commit.tree()],
    )
    .map_err(be)?;

    pollster::block_on(async {
        let from_tree =
            jj_lib::rewrite::rebase_to_dest_parent(repo_dyn, std::slice::from_ref(&from_commit), &to_commit)
                .await
                .map_err(be)?;
        // `MergedTree::has_conflict()` is the same `!…is_resolved()` predicate
        // `Commit::has_conflict()` gives `Change.conflict` (`jj-lib-0.44.0 commit.rs:167-169`).
        // It takes NO matcher, so the flag is independent of `paths` by CONSTRUCTION — a filter
        // that empties the change list cannot empty it, whatever the read order. Read here
        // because this is where the tree it describes is in scope.
        let base_has_conflicts = from_tree.has_conflict();
        let to_tree = to_commit.tree();
        // `CopyRecords::default()` — `show_inter_diff` passes no copy records (diff_util.rs:650).
        let file_changes = tree_file_changes(&from_tree, &to_tree, matcher.as_ref(), &CopyRecords::default()).await?;
        Ok(InterdiffView {
            file_changes,
            base_has_conflicts,
        })
    })
}

#[cfg(test)]
mod tests {
    use super::{res, res_commit, rev, CommitViewError};
    use crate::op_support::{CommitPrefixError, ResolveError};
    use crate::{ChangeId, CommitId, ConfigError, RevsetError};

    /// The three-stage revset taxonomy must survive the mapping: a parse failure, a resolution
    /// failure and a config failure each land in their OWN variant rather than collapsing into
    /// `Backend`, which is what lets the FFI layer emit three different codes. Pinned directly,
    /// exactly as `mutate.rs` pins its own `rev`, because two of the four arms need failures no
    /// fixture provokes deterministically.
    #[test]
    fn rev_preserves_the_three_stage_revset_taxonomy() {
        let hinted = |kind| {
            Box::new(crate::revset::RevsetErrorDetail {
                hints: vec!["h".to_owned()],
                ..crate::revset::RevsetErrorDetail::bare(kind)
            })
        };
        assert!(matches!(
            rev(RevsetError::ParseError {
                reason: "bad".to_owned(),
                detail: hinted(crate::RevsetErrorKind::SyntaxError),
            }),
            CommitViewError::RevsetParseError { reason, hints } if reason == "bad" && hints == ["h"]
        ));
        assert!(matches!(
            rev(RevsetError::ResolutionError {
                reason: "no such bookmark".to_owned(),
                detail: hinted(crate::RevsetErrorKind::NoSuchRevision),
            }),
            CommitViewError::RevsetResolutionError { reason, hints } if reason == "no such bookmark" && hints == ["h"]
        ));
        assert!(matches!(
            rev(RevsetError::Config(ConfigError::Load {
                reason: "not a table".to_owned()
            })),
            CommitViewError::Config { reason } if reason.contains("not a table")
        ));
        assert!(matches!(
            rev(RevsetError::JjLibError("index read failed".to_owned())),
            CommitViewError::Backend(reason) if reason == "index read failed"
        ));
        // Story 9.26: a failed pre-verb snapshot keeps its own variant.
        assert!(matches!(
            rev(RevsetError::Precondition(crate::PreconditionError::Backend("b".to_owned()))),
            CommitViewError::Precondition(crate::PreconditionError::Backend(reason)) if reason == "b"
        ));
        // Story 4.10: a dangling topology edge is no revset stage of its own here.
        assert!(matches!(
            rev(RevsetError::DanglingEdge { target: "ab".to_owned() }),
            CommitViewError::Backend(reason) if reason.contains("ab")
        ));
    }

    /// The shared resolver's two outcomes keep landing in the two DIFFERENT variants: "that
    /// revision does not resolve" is the caller's problem (`ChangeNotFound`, id echoed), an
    /// index/store failure is not (`Backend`).
    #[test]
    fn res_preserves_the_not_found_and_backend_split() {
        let id = ChangeId("zzzzzzzz".to_owned());
        assert!(matches!(
            res(ResolveError::NotFound, Some(&id)),
            CommitViewError::ChangeNotFound { id } if id == "zzzzzzzz"
        ));
        // `interdiff` refuses when BOTH sides are absent, so a `None` id can only reach here
        // for a side that defaulted to `@` — where `resolve_or_wc` fails as `Backend`. The
        // `None` arm is therefore defensive and must still produce an EMPTY id, not a panic.
        assert!(matches!(
            res(ResolveError::NotFound, None),
            CommitViewError::ChangeNotFound { id } if id.is_empty()
        ));
        assert!(matches!(
            res(ResolveError::Backend("store read failed".to_owned()), Some(&id)),
            CommitViewError::Backend(reason) if reason == "store read failed"
        ));
    }

    /// The commit-arm resolver reports FOUR outcomes where the change arm reports two, and
    /// each lands on a DIFFERENT already-registered code: collapsing "not hex" into
    /// "not found", or ambiguity into either, would erase exactly the distinction that arm
    /// exists to make. Pinned directly — `Backend` needs an index/store failure no fixture
    /// provokes deterministically, and the ambiguity message is jj-lib's own.
    #[test]
    fn res_commit_preserves_the_four_stage_commit_prefix_taxonomy() {
        let id = CommitId("abc".to_owned());
        assert!(matches!(
            res_commit(CommitPrefixError::Malformed, &id),
            CommitViewError::InvalidInput { reason } if reason.contains("abc")
        ));
        assert!(matches!(
            res_commit(CommitPrefixError::Ambiguous, &id),
            CommitViewError::RevsetResolutionError { reason, hints }
                if reason.contains("abc") && reason.contains("ambiguous") && hints.is_empty()
        ));
        assert!(matches!(
            res_commit(CommitPrefixError::NotFound, &id),
            CommitViewError::ChangeNotFound { id } if id == "abc"
        ));
        assert!(matches!(
            res_commit(CommitPrefixError::Backend("index read failed".to_owned()), &id),
            CommitViewError::Backend(reason) if reason == "index read failed"
        ));
    }
}
