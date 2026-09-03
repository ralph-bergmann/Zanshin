// SPDX-License-Identifier: MIT

//! `mutate.rs` — the four P0 change mutations (describe, new, edit, abandon — FR-JJ-10a)
//! plus the two content ops (restore, absorb — Story 9.3).
//!
//! Every mutation opens a jj-lib transaction, mutates via `tx.repo_mut()`, and commits
//! with a CLI-parity op-log description (NFR-R-2) — jj-lib only, never shells to `jj`
//! (AR-AP-1). The transaction boundary stays entirely inside this function; no mutation
//! primitive crosses the crate's public API (ADR-0003).
//!
//! Two verbs can finish WITHOUT writing an operation — [`restore`] when the selected tree
//! already equals the destination's, [`absorb`] when nothing was absorbable. Both mirror
//! the CLI, which prints "Nothing changed." and commits nothing; the transaction is simply
//! dropped and [`MutationResult::new_op_id`] carries the PRE-CALL head op id.
//!
//! Neither verb snapshots the working copy (D2 — `status.rs:84`, `revset.rs:61-62`): both
//! read the last-snapshotted `@`, where the CLI's `workspace_helper` would have snapshotted
//! on-disk edits first. `LockedWorkingCopy::{snapshot,reset}` is Story 9.22's scope.

use std::sync::Arc;

use jj_lib::absorb::{absorb_hunks, split_hunks_to_trees, AbsorbSource};
use jj_lib::commit::{conflict_label_for_commits, Commit};
use jj_lib::matchers::{EverythingMatcher, Matcher, PrefixMatcher};
use jj_lib::merge::Diff;
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{MutableRepo, ReadonlyRepo, Repo as _};
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::revset::{ResolvedRevsetExpression, UserRevsetExpression};
use jj_lib::rewrite::{merge_commit_trees, RebaseOptions, RewriteRefsOptions};
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::op_support::{check_rewritable, resolve_immutable, SelectedTree};
use crate::revset::resolve_expression;
use crate::ChangeId;

/// Outcome of a successful mutation (FR-JJ-10a).
#[derive(Debug)]
pub struct MutationResult {
    /// Id of the operation this mutation committed — `jj op log`'s most-recent entry
    /// immediately afterward (NFR-R-2).
    ///
    /// For the two verbs that can legitimately write NOTHING ([`restore`] with an already
    /// identical tree, [`absorb`] with nothing absorbable) this is the head op id from
    /// BEFORE the call — the op log is unchanged, which is exactly the signal jj itself
    /// gives, and there is deliberately no separate `no_op` flag.
    pub new_op_id: crate::OperationId,
    /// Change ids of genuinely NEW changes minted by this mutation: [`new_change`]'s
    /// created commit, or the replacement `@` jj-lib auto-creates when [`abandon`]
    /// abandons `@` itself. A rewrite ([`describe`]) or a pointer move ([`edit`]) never
    /// mints a new change id, so this is empty for those. Empty for [`abandon`] unless
    /// `@` itself was among the abandoned ids. Always empty for [`crate::op_log::undo`]
    /// (it restores state, it doesn't mint anything) and for
    /// [`crate::Repo::git_fetch`] (it imports remote refs; it doesn't mint or
    /// abandon a change in the sense these fields track).
    pub new_change_ids: Vec<ChangeId>,
    /// The change ids [`abandon`]'s caller passed in, echoed verbatim. Always empty for
    /// `describe`/`new_change`/`edit` — jj-lib's own side effects (e.g. `edit()`'s
    /// implicit abandon of a discardable previous `@`) are never reflected here. Always
    /// empty for [`crate::op_log::undo`] too (it restores state, it doesn't abandon
    /// anything), and for [`crate::Repo::git_fetch`] (same reason as
    /// `new_change_ids` above). Also always empty for [`restore`] and [`absorb`]: neither
    /// takes an id list to echo, and absorb's own outcome — which ancestors absorbed
    /// hunks and whether the source survived — lives in [`AbsorbResult`]'s fields.
    pub abandoned_change_ids: Vec<ChangeId>,
    /// Change id of the working-copy commit (`@`) after this mutation — whether or not
    /// this mutation is what moved it.
    pub working_copy_change_id: ChangeId,
}

/// Errors returned by [`crate::Repo::describe`], [`crate::Repo::new_change`],
/// [`crate::Repo::edit`], and [`crate::Repo::abandon`].
#[derive(Debug, thiserror::Error)]
pub enum MutateError {
    /// No change exists for a given id, or it cannot be resolved unambiguously — same
    /// not-found semantics as [`crate::ChangeError::NotFound`] (empty/malformed
    /// reverse-hex, absent, only-hidden, and DIVERGENT are all indistinguishable; a
    /// divergent id is refused rather than mutating an arbitrary one of its targets).
    #[error("change not found: {id}")]
    ChangeNotFound {
        /// The reverse-hex change id that could not be resolved.
        id: String,
    },
    /// The caller's arguments are structurally invalid for this mutation (e.g. an
    /// empty parent list for `new_change`, or an empty id list for `abandon`).
    #[error("invalid input: {reason}")]
    InvalidInput {
        /// Human-readable reason the input was rejected.
        reason: String,
    },
    /// The target is inside the repo's immutable set — `::(immutable_heads() | root())`,
    /// as the repo's EFFECTIVE config defines it — so jj refuses to rewrite it (CLI
    /// parity, NFR-R-2). No operation is committed.
    ///
    /// Names the FIRST offender only, like the CLI (`cli_util.rs:2011` takes `try_next`,
    /// never a list); more targets may also be immutable. There is deliberately no
    /// `--ignore-immutable` escape hatch on any verb's signature.
    ///
    /// The ROOT commit is a special case. [`crate::Repo::describe`] and
    /// [`crate::Repo::abandon`] guard it explicitly BEFORE this check — those guards
    /// pre-empt jj-lib's own internal `assert!` (a process crash, not an error) — so root
    /// keeps refusing as [`MutateError::InvalidInput`] there. [`crate::Repo::edit`] needs
    /// no such guard (jj-lib is graceful about it) and therefore reports root here, as the
    /// CLI does. Either way the call refuses and no op-log entry is written, which is the
    /// observable behaviour NFR-R-2 pins; only the code differs.
    #[error("commit is immutable: {commit_id}")]
    Immutable {
        /// Hex commit id of the first target found inside the immutable set.
        commit_id: String,
    },
    /// The repo's effective jj config could not be read, or its
    /// `revset-aliases."immutable_heads()"` does not parse or resolve — so the
    /// immutability guard could not determine what is protected (Story 9.1).
    ///
    /// Same fault class the read side reports as [`crate::ConfigError`] /
    /// [`crate::RevsetError::Config`], and the same one the CLI reports as
    /// ``Invalid `revset-aliases.immutable_heads()` `` (`cli_util.rs:1139`). Never a
    /// silent fall-back to the builtin immutable set: a config the user cannot see the
    /// effect of must not silently widen — or narrow — what a rewrite may touch.
    ///
    /// Only the three REWRITING verbs (`describe`/`edit`/`abandon`) can raise it;
    /// `new_change`, `undo` and `git_fetch` never read the config.
    #[error("config error: {reason}")]
    Config {
        /// Human-readable reason, naming the offending file or alias.
        reason: String,
    },
    /// [`crate::Repo::undo`] was called with the head operation at the op-store root —
    /// there is no parent operation to restore to. Currently unreachable through this
    /// crate's own public API alone: `Workspace::init_*` always commits an
    /// "add workspace" op on top of root, so a freshly opened repo's head always has at
    /// least one parent. It exists as a defensive CLI-parity guard mirroring the CLI's
    /// own `Cannot undo root operation` refusal, not a normally-reachable path — it only
    /// fires against a hand-crafted or externally-mutated op-store (see
    /// `tests/op_log.rs`'s `undo_at_root_operation_returns_nothing_to_undo`, which has to
    /// engineer that state via direct `op_heads` file manipulation).
    #[error("nothing to undo")]
    NothingToUndo,
    /// [`crate::Repo::git_fetch`] was called with a remote name that has no
    /// configured git remote — or the repo has no git backend at all, in which case
    /// no remote can exist categorically (FR-JJ-13).
    #[error("no such remote: {name}")]
    RemoteNotFound {
        /// The remote name that could not be resolved.
        name: String,
    },
    /// [`crate::Repo::git_fetch`]'s underlying `git` subprocess failed — a network,
    /// authentication, or transport error. No operation is committed (FR-JJ-13).
    #[error("network error: {reason}")]
    NetworkError {
        /// The underlying `git`/jj-lib failure message, forwarded verbatim.
        reason: String,
    },
    /// A caller-supplied revset expression is syntactically invalid or names an unknown
    /// function — [`crate::Repo::absorb`]'s `destinations` is the first mutation parameter
    /// that is a revset rather than a change id (Story 9.3).
    ///
    /// Kept DISTINCT from [`MutateError::RevsetResolutionError`] for the same reason the
    /// read side keeps [`crate::RevsetError::ParseError`] and
    /// [`crate::RevsetError::ResolutionError`] apart: "you mistyped the expression" and
    /// "the expression is fine but that symbol does not exist here" need different
    /// remedies, and the code registry already carries both.
    #[error("invalid revset: {reason}")]
    RevsetParseError {
        /// Human-readable parse failure from jj-lib.
        reason: String,
    },
    /// A caller-supplied revset expression is well-formed but a symbol in it cannot be
    /// resolved (unknown bookmark/tag, no working-copy commit for `@`, ambiguous id) —
    /// see [`MutateError::RevsetParseError`] for why the two stay separate (Story 9.3).
    #[error("cannot resolve revset: {reason}")]
    RevsetResolutionError {
        /// Human-readable resolution failure from jj-lib.
        reason: String,
    },
    /// An underlying jj-lib failure, opaque-string-wrapped so no `jj_lib` type escapes
    /// the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Outcome of a successful [`crate::Repo::absorb`] (Story 9.3).
///
/// [`MutationResult`] is NESTED rather than flattened so the op-id / working-copy contract
/// has exactly one definition; the remaining fields are the part of absorb's outcome
/// `MutationResult` cannot express — which ancestors absorbed hunks, whether the source
/// commit survived, and which paths jj-lib REFUSED to split.
#[derive(Debug)]
pub struct AbsorbResult {
    /// The shared mutation contract: op id (the PRE-CALL head when nothing was absorbed),
    /// and the working-copy change id afterwards. `new_change_ids` / `abandoned_change_ids`
    /// are always empty for absorb — see their docs on [`MutationResult`].
    pub mutation: MutationResult,
    /// Change ids of the destination commits the hunks were absorbed INTO, in jj-lib's
    /// forward topological order. EMPTY means nothing was absorbable — and then no
    /// operation was written either.
    pub rewritten_change_ids: Vec<ChangeId>,
    /// Change id of the source commit after the absorbed hunks were removed from it, or
    /// `None` when jj-lib abandoned the source (it became discardable — everything moved
    /// and it had no description) or when nothing moved at all. A rewrite preserves the
    /// change id, so `Some` always echoes the source's own id; the information is the
    /// `Some`/`None` distinction, not the value.
    pub source_change_id: Option<ChangeId>,
    /// Number of descendant commits jj-lib rebased. Excludes the destination commits
    /// themselves; INCLUDES the rewritten source (jj-lib's own `AbsorbStats::num_rebased`
    /// accounting).
    pub num_rebased: u32,
    /// Paths jj-lib refused to split, with its verbatim reason. The CLI prints one warning
    /// per entry; dropping them would leave a file silently unabsorbed with no way for a
    /// GUI to say so. The remaining paths still absorb normally.
    pub skipped_paths: Vec<SkippedPath>,
}

/// One path [`crate::Repo::absorb`] could not split, and jj-lib's reason (Story 9.3).
#[derive(Debug)]
pub struct SkippedPath {
    /// Repo-relative path in jj's internal (`/`-separated) form.
    pub path: String,
    /// jj-lib's verbatim reason — e.g. `Is a symlink`, `Is a conflict`,
    /// `Is a Git submodule`, `Access is denied: …`. Forwarded unchanged so the GUI shows
    /// what `jj absorb` would print.
    pub reason: String,
}

/// Converts any jj-lib error to [`MutateError::Backend`]. `pub(crate)` so
/// [`crate::op_log::undo`] can reuse it instead of duplicating an identical helper.
pub(crate) fn be<E: std::fmt::Display>(e: E) -> MutateError {
    MutateError::Backend(e.to_string())
}

/// Converts a config-or-alias failure to [`MutateError::Config`]. `pub(crate)` so
/// [`crate::op_support`] can classify the immutable expression's own failures without
/// them landing in the unclassified [`MutateError::Backend`] bucket.
pub(crate) fn cfg<E: std::fmt::Display>(e: E) -> MutateError {
    MutateError::Config { reason: e.to_string() }
}

/// Converts a read-side [`crate::RevsetError`] to the matching [`MutateError`] variant,
/// preserving the three-stage taxonomy rather than collapsing it (Story 9.2's rule).
/// `pub(crate)` so [`crate::Repo::absorb`]'s facade can classify its own `parse_revset`
/// failure the same way this module classifies `resolve_expression`'s.
pub(crate) fn rev(e: crate::RevsetError) -> MutateError {
    match e {
        crate::RevsetError::ParseError { reason } => MutateError::RevsetParseError { reason },
        crate::RevsetError::ResolutionError { reason } => MutateError::RevsetResolutionError { reason },
        crate::RevsetError::Config(inner) => cfg(inner),
        crate::RevsetError::JjLibError(reason) => MutateError::Backend(reason),
    }
}

/// Builds the file matcher both content ops filter with.
///
/// An EMPTY `paths` means "all paths" (`EverythingMatcher`); otherwise each entry is a
/// repo-relative path interpreted as a PREFIX.
///
/// WHY not the fileset DSL: the CLI parses `paths` with `fileset::parse_maybe_bare`, whose
/// *bare* form is exactly `prefix_path` — so `PrefixMatcher` reproduces the CLI's
/// observable behavior for the input a GUI actually produces (a file/directory selection).
/// The DSL itself is terminal *input language*, which ADR-0003 replaces rather than ports.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — an entry is not a valid repo path (leading or trailing
///   `/`, or an empty component).
fn build_matcher(paths: &[String]) -> Result<Box<dyn Matcher>, MutateError> {
    if paths.is_empty() {
        return Ok(Box::new(EverythingMatcher));
    }
    let mut prefixes = Vec::with_capacity(paths.len());
    for path in paths {
        prefixes.push(
            RepoPathBuf::from_internal_string(path.clone()).map_err(|e| MutateError::InvalidInput {
                reason: format!("invalid path: {e}"),
            })?,
        );
    }
    Ok(Box::new(PrefixMatcher::new(prefixes)))
}

/// Resolves `id`, or — when it is `None` — the workspace's working-copy commit, mirroring
/// the CLI's `RevisionArg::AT` (`@`) default for every omitted revision argument.
///
/// `@` is the LAST-SNAPSHOTTED working-copy commit: Zanshin never snapshots (D2).
fn resolve_or_wc(
    repo: &MutableRepo,
    workspace_name: &WorkspaceName,
    id: Option<&ChangeId>,
) -> Result<Commit, MutateError> {
    if let Some(id) = id {
        return resolve_commit(repo, id);
    }
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace_name)
        .ok_or_else(|| MutateError::Backend("workspace has no working-copy commit".to_owned()))?
        .clone();
    repo.store().get_commit(&wc_id).map_err(be)
}

/// Resolves `id` to its visible jj-lib [`Commit`] — same pattern as
/// `change.rs::get_change` (empty/malformed reverse-hex, absent, or only-hidden all
/// collapse to `ChangeNotFound`), but against `repo`, which may be a `MutableRepo`
/// mid-transaction — `resolve_change_id` works identically on both.
///
/// Unlike the read-only `get_change` (which reports divergence via `Change::divergent`
/// and silently picks the first visible target), a DIVERGENT id also collapses to
/// `ChangeNotFound` here: silently mutating an arbitrary one of several ambiguous
/// commits would be unsafe, and the real `jj` CLI likewise refuses an ambiguous
/// revision argument rather than guessing.
fn resolve_commit(repo: &MutableRepo, id: &ChangeId) -> Result<Commit, MutateError> {
    if id.0.is_empty() {
        return Err(MutateError::ChangeNotFound { id: id.0.clone() });
    }
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0)
        .ok_or_else(|| MutateError::ChangeNotFound { id: id.0.clone() })?;
    let targets = repo
        .resolve_change_id(&jj_id)
        .map_err(be)?
        .ok_or_else(|| MutateError::ChangeNotFound { id: id.0.clone() })?;
    let visible = targets
        .into_visible()
        .ok_or_else(|| MutateError::ChangeNotFound { id: id.0.clone() })?;
    let [commit_id] = visible.as_slice() else {
        return Err(MutateError::ChangeNotFound { id: id.0.clone() });
    };
    repo.store().get_commit(commit_id).map_err(be)
}

/// Resolves the immutable set and refuses the rewrite if any of `commit_ids` is inside it
/// (Story 9.1) — the CLI's `check_rewritable`, which every rewriting verb runs before it
/// touches the repo.
///
/// Resolution happens against `tx.base_repo()`, mirroring `cli_util.rs:2927`
/// `rebase_mutable_descendants`: a `jj git fetch` can update immutable commits, and only
/// the ones still reachable from the pre-transaction state should constrain a rebase. The
/// CLI runs the guard against its read-only repo before opening a transaction; running it
/// here — inside the transaction but before ANY mutation — sees identical content, and
/// dropping the transaction on refusal writes nothing, so no op-log entry appears either
/// way.
///
/// Returns the RESOLVED set so a caller that also feeds it to
/// `rebase_descendants_with_options` does not resolve twice.
fn guard_rewritable(
    tx: &Transaction,
    immutable: &Arc<UserRevsetExpression>,
    commit_ids: &[jj_lib::backend::CommitId],
) -> Result<Arc<ResolvedRevsetExpression>, MutateError> {
    let base: &ReadonlyRepo = tx.base_repo();
    let resolved = resolve_immutable(base, immutable)?;
    check_rewritable(base, &resolved, commit_ids)?;
    Ok(resolved)
}

/// Captures the working-copy commit's id and tree BEFORE a transaction starts, so the
/// post-commit sync step can tell whether this mutation moved `@`, and so
/// `workspace.check_out` gets the pre-mutation tree for jj-lib's own
/// concurrent-modification guard.
pub(crate) fn capture_old_wc(
    readonly: &ReadonlyRepo,
    workspace_name: &WorkspaceName,
) -> Result<(Option<jj_lib::backend::CommitId>, Option<MergedTree>), MutateError> {
    let old_wc_id = readonly.view().get_wc_commit_id(workspace_name).cloned();
    let old_tree = match &old_wc_id {
        Some(id) => Some(readonly.store().get_commit(id).map_err(be)?.tree()),
        None => None,
    };
    Ok((old_wc_id, old_tree))
}

/// Syncs the on-disk working copy to the just-committed transaction's `@`, but ONLY if
/// this mutation actually moved it (AC-3: no `workspace.check_out` call otherwise).
/// Returns the new `@` commit either way, so callers can read its change id.
pub(crate) fn sync_working_copy(
    workspace: &mut Workspace,
    workspace_name: &WorkspaceName,
    old_wc_id: Option<&jj_lib::backend::CommitId>,
    old_tree: Option<&MergedTree>,
    new_repo: &Arc<ReadonlyRepo>,
) -> Result<Commit, MutateError> {
    let new_wc_id = new_repo
        .view()
        .get_wc_commit_id(workspace_name)
        .cloned()
        .ok_or_else(|| MutateError::Backend("workspace has no working-copy commit".to_owned()))?;
    let new_wc_commit = new_repo.store().get_commit(&new_wc_id).map_err(be)?;
    if Some(&new_wc_id) != old_wc_id {
        pollster::block_on(workspace.check_out(new_repo.op_id().clone(), old_tree, &new_wc_commit)).map_err(be)?;
    }
    Ok(new_wc_commit)
}

/// Rewrites `change_id`'s description to `description` (FR-JJ-10a).
///
/// `immutable` is the repo's effective immutable-set expression
/// ([`crate::op_support::immutable_user_expression`]); the target is refused if it falls
/// inside it, mirroring the CLI's `check_rewritable` in `jj describe`
/// (`cli/src/commands/describe.rs:101` @ v0.44.0).
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — `change_id` is malformed, absent, only-hidden, or
///   divergent.
/// - [`MutateError::InvalidInput`] — `change_id` resolves to the root commit.
/// - [`MutateError::Immutable`] — `change_id` resolves to a non-root immutable commit.
/// - [`MutateError::Config`] — the repo's jj config or its `immutable_heads()` alias could
///   not be read, parsed, or resolved.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn describe(
    workspace: &mut Workspace,
    immutable: &Arc<UserRevsetExpression>,
    change_id: &ChangeId,
    description: &str,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = readonly.start_transaction();
    let commit = resolve_commit(tx.repo(), change_id)?;
    // jj-lib's `rewrite_commit` internally asserts the target isn't the root commit
    // (`assert_ne!`) rather than returning an error — guard explicitly so a caller gets
    // a normal `MutateError` instead of a process-crashing panic. Keep this BEFORE the
    // immutability guard: root would otherwise be reported as immutable (as the CLI does),
    // changing a shipped error code and making these lines unreachable.
    if commit.id() == tx.repo().store().root_commit_id() {
        return Err(MutateError::InvalidInput {
            reason: "cannot describe the root commit".to_owned(),
        });
    }
    guard_rewritable(&tx, immutable, std::slice::from_ref(commit.id()))?;
    pollster::block_on(
        tx.repo_mut()
            .rewrite_commit(&commit)
            .set_description(description)
            .write(),
    )
    .map_err(be)?;
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let new_repo = pollster::block_on(tx.commit(format!("describe commit {}", commit.id().hex()))).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());

    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    Ok(MutationResult {
        new_op_id,
        new_change_ids: Vec::new(),
        abandoned_change_ids: Vec::new(),
        working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
    })
}

/// Creates a new, empty change on top of `parents` (FR-JJ-10a) — a merge commit when
/// `parents.len() > 1`, via jj-lib's `merge_commit_trees` — and switches the working
/// copy to it.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `parents` is empty.
/// - [`MutateError::ChangeNotFound`] — a parent id is malformed, absent, only-hidden, or
///   divergent.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn new_change(workspace: &mut Workspace, parents: &[ChangeId]) -> Result<MutationResult, MutateError> {
    if parents.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "new_change requires at least one parent".to_owned(),
        });
    }

    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = readonly.start_transaction();
    let mut parent_commits = Vec::with_capacity(parents.len());
    for change_id in parents {
        parent_commits.push(resolve_commit(tx.repo(), change_id)?);
    }
    let parent_ids: Vec<_> = parent_commits.iter().map(|c| c.id().clone()).collect();
    let merged_tree = pollster::block_on(merge_commit_trees(tx.repo(), &parent_commits)).map_err(be)?;
    let new_commit = pollster::block_on(tx.repo_mut().new_commit(parent_ids, merged_tree).write()).map_err(be)?;
    // Matches the CLI's `jj new`: a plain new_commit records no rewrite, so this is
    // usually a no-op — kept for parity with the CLI's own descendant-rebase step.
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    pollster::block_on(tx.repo_mut().edit(workspace_name.clone(), &new_commit)).map_err(be)?;
    // edit() may have just recorded the previous `@` as abandoned (if it was
    // discardable — empty description, no diff from its parent), which leaves an
    // un-rebased entry in the transaction that would trip tx.commit()'s
    // has_rewrites() assertion. The CLI clears it via an unconditional final
    // rebase_descendants() in finish_transaction; do the same here.
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let new_change_id = ChangeId(new_commit.change_id().reverse_hex());
    let new_repo = pollster::block_on(tx.commit("new empty commit")).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());

    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    Ok(MutationResult {
        new_op_id,
        new_change_ids: vec![new_change_id],
        abandoned_change_ids: Vec::new(),
        working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
    })
}

/// Switches the working copy to `change_id` without creating a new commit (FR-JJ-10a).
///
/// `immutable` is the repo's effective immutable-set expression
/// ([`crate::op_support::immutable_user_expression`]); the target is refused if it falls
/// inside it, mirroring the CLI's `check_rewritable` in `jj edit`
/// (`cli/src/commands/edit.rs:63` @ v0.44.0).
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — `change_id` is malformed, absent, only-hidden, or
///   divergent.
/// - [`MutateError::Immutable`] — `change_id` resolves to an immutable commit. Unlike
///   `describe`/`abandon`, `edit` has no explicit root-commit guard (jj-lib returns a
///   graceful error rather than asserting), so the ROOT commit is now caught by the
///   immutability guard too — which is exactly what the CLI reports for `jj edit root()`.
/// - [`MutateError::Config`] — the repo's jj config or its `immutable_heads()` alias could
///   not be read, parsed, or resolved.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn edit(
    workspace: &mut Workspace,
    immutable: &Arc<UserRevsetExpression>,
    change_id: &ChangeId,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = readonly.start_transaction();
    let commit = resolve_commit(tx.repo(), change_id)?;
    guard_rewritable(&tx, immutable, std::slice::from_ref(commit.id()))?;
    pollster::block_on(tx.repo_mut().edit(workspace_name.clone(), &commit)).map_err(be)?;
    // See new_change's comment: edit() may implicitly abandon a discardable previous
    // `@`, leaving an un-rebased rewrite that would trip tx.commit()'s assertion.
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let new_repo = pollster::block_on(tx.commit(format!("edit commit {}", commit.id().hex()))).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());

    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    Ok(MutationResult {
        new_op_id,
        new_change_ids: Vec::new(),
        abandoned_change_ids: Vec::new(),
        working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
    })
}

/// Abandons `change_ids`, rebasing descendants onto their parents and deleting any
/// bookmarks that pointed only at the abandoned commits (FR-JJ-10a).
///
/// `immutable` is the repo's effective immutable-set expression
/// ([`crate::op_support::immutable_user_expression`]); a target inside it is refused,
/// mirroring the CLI's `check_rewritable` in `jj abandon`
/// (`cli/src/commands/abandon.rs:85` @ v0.44.0).
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `change_ids` is empty, or resolves the root commit.
/// - [`MutateError::ChangeNotFound`] — a target id is malformed, absent, only-hidden, or
///   divergent.
/// - [`MutateError::Immutable`] — a target resolves to a non-root immutable commit.
/// - [`MutateError::Config`] — the repo's jj config or its `immutable_heads()` alias could
///   not be read, parsed, or resolved.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn abandon(
    workspace: &mut Workspace,
    immutable: &Arc<UserRevsetExpression>,
    change_ids: &[ChangeId],
) -> Result<MutationResult, MutateError> {
    if change_ids.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "abandon requires at least one change id".to_owned(),
        });
    }

    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = readonly.start_transaction();
    let mut commits = Vec::with_capacity(change_ids.len());
    for change_id in change_ids {
        let commit = resolve_commit(tx.repo(), change_id)?;
        // jj-lib's `record_abandoned_commit` internally asserts the target isn't the
        // root commit rather than returning an error — guard explicitly so a caller
        // gets a normal `MutateError` instead of a process-crashing panic.
        if commit.id() == tx.repo().store().root_commit_id() {
            return Err(MutateError::InvalidInput {
                reason: "cannot abandon the root commit".to_owned(),
            });
        }
        commits.push(commit);
    }
    // CLI parity (`abandon.rs:85`): every target must be rewritable. Runs AFTER the
    // per-commit root guards above, so the root commit keeps its `InvalidInput` refusal.
    let target_ids: Vec<jj_lib::backend::CommitId> = commits.iter().map(|c| c.id().clone()).collect();
    // NOT shadowing `immutable`: the parameter is the UNRESOLVED user expression, this is
    // the set resolved against `tx.base_repo()`, and the distinction is what the
    // `rebase_descendants_with_options` call ~30 lines below depends on.
    let resolved_immutable = guard_rewritable(&tx, immutable, &target_ids)?;
    // Whether `@` itself is among the abandoned commits determines whether jj-lib's
    // own update_wc_commits() mints a genuinely NEW change to replace it (vs. `@`
    // merely being rebased because it descends from an abandoned ancestor, which
    // keeps its change id).
    let wc_was_abandoned = old_wc_id
        .as_ref()
        .is_some_and(|id| commits.iter().any(|c| c.id() == id));

    for commit in &commits {
        tx.repo_mut().record_abandoned_commit(commit);
    }
    let options = RebaseOptions {
        rewrite_refs: RewriteRefsOptions {
            delete_abandoned_bookmarks: true,
        },
        ..Default::default()
    };
    // WHY: jj 0.44 added the leading `immutable` argument; the CLI passes the resolved
    // immutable set (`cli_util.rs:2927` `rebase_mutable_descendants`), so we do too. Note
    // the algebra: immutability is ancestor-closed, so once `guard_rewritable` passed on
    // the targets none of their descendants can be immutable and this argument cannot
    // change the outcome here. It is passed for CLI parity and for the case the CLI's own
    // comment names — `jj git fetch` updating immutable commits between base and tip —
    // which is also why the set is resolved against `tx.base_repo()`, not `tx.repo()`.
    pollster::block_on(
        tx.repo_mut()
            .rebase_descendants_with_options(&resolved_immutable, &options, |_, _| {}),
    )
    .map_err(be)?;

    let description = if let [only] = commits.as_slice() {
        format!("abandon commit {}", only.id().hex())
    } else {
        format!(
            "abandon commit {} and {} more",
            commits[0].id().hex(),
            commits.len() - 1
        )
    };
    let new_repo = pollster::block_on(tx.commit(description)).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());

    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    let new_change_ids = if wc_was_abandoned {
        vec![ChangeId(new_wc_commit.change_id().reverse_hex())]
    } else {
        Vec::new()
    };
    Ok(MutationResult {
        new_op_id,
        new_change_ids,
        abandoned_change_ids: change_ids.to_vec(),
        working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
    })
}

/// Builds the result of a mutation that deliberately wrote NOTHING.
///
/// `readonly` is the SAME head-resolved repo the (now dropped) transaction started from, so
/// the op-log head is unchanged and `@` cannot have moved — `sync_working_copy` therefore
/// never reaches `workspace.check_out` here and is reused only to read the current `@`.
fn no_op_result(
    workspace: &mut Workspace,
    workspace_name: &WorkspaceName,
    old_wc_id: Option<&jj_lib::backend::CommitId>,
    old_tree: Option<&MergedTree>,
    readonly: &Arc<ReadonlyRepo>,
) -> Result<MutationResult, MutateError> {
    let wc = sync_working_copy(workspace, workspace_name, old_wc_id, old_tree, readonly)?;
    Ok(MutationResult {
        new_op_id: crate::OperationId(readonly.op_id().hex()),
        new_change_ids: Vec::new(),
        abandoned_change_ids: Vec::new(),
        working_copy_change_id: ChangeId(wc.change_id().reverse_hex()),
    })
}

/// Gives the paths matching `paths` in the destination commit the content they have in the
/// source commit (Story 9.3) — the CLI's `jj restore`, whole-file only.
///
/// Default resolution mirrors `cli/src/commands/restore.rs:119-137` @ v0.44.0 exactly:
///
/// - If either `from` or `into` is given, the OMITTED one is `@`, and the source tree is
///   the source commit's own tree.
/// - If neither is given, the destination is `changes_in` (or `@`) and the source tree is
///   that commit's PARENT tree — which undoes the commit's own diff while keeping its
///   description, the CLI's `jj restore` / `jj restore --changes-in REV` behavior.
///
/// `restore_descendants` picks `reparent_descendants` (children keep their content) over
/// `rebase_descendants` (children keep their diff), matching `--restore-descendants`.
///
/// If the selected tree already EQUALS the destination's, no transaction is committed —
/// the op log is untouched and the returned `new_op_id` is the pre-call head
/// (`restore.rs:181`, which likewise never opens a transaction). That check cannot be
/// replaced by `has_changes()`: `rewrite_commit(...).set_tree(same_tree).write()` already
/// records a rewrite.
///
/// There is NO interactive/hunk selection (epics.md:5536 scopes this to whole files); the
/// working copy is never snapshotted, so `@` is the last-snapshotted one (D2).
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `changes_in` combined with `from`/`into`, or a `paths`
///   entry is not a valid repo path.
/// - [`MutateError::ChangeNotFound`] — `from`, `into` or `changes_in` is malformed, absent,
///   only-hidden, or divergent.
/// - [`MutateError::Immutable`] — the destination is inside the repo's effective immutable
///   set. The ROOT commit needs no separate guard: `check_rewritable` runs BEFORE any tree
///   work and `immutable_user_expression` unions `root()` unconditionally, so root always
///   refuses here — exactly as it does for the CLI, which has no root guard in `restore.rs`
///   either.
/// - [`MutateError::Config`] — the repo's jj config or its `immutable_heads()` alias could
///   not be read, parsed, or resolved.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn restore(
    workspace: &mut Workspace,
    immutable: &Arc<UserRevsetExpression>,
    from: Option<&ChangeId>,
    into: Option<&ChangeId>,
    changes_in: Option<&ChangeId>,
    paths: &[String],
    restore_descendants: bool,
) -> Result<MutationResult, MutateError> {
    // CLI parity: clap declares `--changes-in` with `conflicts_with_all = ["into", "from"]`
    // (`restore.rs:78`), so the combination never reaches the command body there. Refuse
    // before touching the repo, so no operation can be written either.
    if changes_in.is_some() && (from.is_some() || into.is_some()) {
        return Err(MutateError::InvalidInput {
            reason: "`changes_in` cannot be combined with `from`/`into`".to_owned(),
        });
    }

    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = readonly.start_transaction();
    let (to_commit, from_tree, from_commits) = if from.is_some() || into.is_some() {
        let to_commit = resolve_or_wc(tx.repo(), &workspace_name, into)?;
        let from_commit = resolve_or_wc(tx.repo(), &workspace_name, from)?;
        let from_tree = from_commit.tree();
        (to_commit, from_tree, vec![from_commit])
    } else {
        let to_commit = resolve_or_wc(tx.repo(), &workspace_name, changes_in)?;
        let from_tree = pollster::block_on(to_commit.parent_tree(tx.repo())).map_err(be)?;
        let from_commits = pollster::block_on(to_commit.parents()).map_err(be)?;
        (to_commit, from_tree, from_commits)
    };
    // CLI parity (`restore.rs:138`): the rewritability guard runs BEFORE any matcher or
    // tree work, so an immutable destination costs no diffing and writes no blobs.
    guard_rewritable(&tx, immutable, std::slice::from_ref(to_commit.id()))?;

    let matcher = build_matcher(paths)?;
    let to_tree = to_commit.tree();
    // `Diff::new(before, after)` with the DESTINATION first: `SelectedTree::from_paths`
    // owns the inversion into jj-lib's source-first `restore_tree` (Story 9.1). The two
    // conflict labels are load-bearing strings embedded into conflict markers, not
    // cosmetics.
    let selected = SelectedTree::from_paths(
        Diff::new(&to_tree, &from_tree),
        Diff::new(to_commit.conflict_label(), conflict_label_for_commits(&from_commits)),
        matcher.as_ref(),
    )?;
    if selected.tree().tree_ids() == to_commit.tree_ids() {
        drop(tx);
        return no_op_result(
            workspace,
            &workspace_name,
            old_wc_id.as_ref(),
            old_tree.as_ref(),
            &readonly,
        );
    }

    pollster::block_on(
        tx.repo_mut()
            .rewrite_commit(&to_commit)
            .set_tree(selected.tree().clone())
            .write(),
    )
    .map_err(be)?;
    // A descendant pass MUST precede the commit: `Transaction::write` panics while
    // `has_rewrites()` is still true, and Zanshin drives the transaction directly with none
    // of the CLI's `finish_transaction` safety net (see `new_change`'s comment).
    if restore_descendants {
        pollster::block_on(tx.repo_mut().reparent_descendants()).map_err(be)?;
    } else {
        pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    }
    let new_repo =
        pollster::block_on(tx.commit(format!("restore into commit {}", to_commit.id().hex()))).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());

    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    Ok(MutationResult {
        new_op_id,
        new_change_ids: Vec::new(),
        abandoned_change_ids: Vec::new(),
        working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
    })
}

/// Moves each hunk of the source commit into the closest commit in `destinations` where the
/// corresponding lines were last modified (Story 9.3) — the CLI's `jj absorb`,
/// non-interactive only.
///
/// `destinations` is a caller-supplied revset EXPRESSION, not an id list: the CLI's `--into`
/// is a `Vec<RevisionArg>` unioned into a *set* whose default is the dynamic `mutable()`
/// alias, and materializing it into ids would destroy that meaning (FR-JJ-17). `from`
/// defaults to `@` — the last-snapshotted working-copy commit (D2), where the CLI would
/// have snapshotted on-disk edits first.
///
/// Ordering mirrors `cli/src/commands/absorb.rs` @ v0.44.0: resolve → split → collect the
/// skipped paths → `check_rewritable` on the split's TARGETS → absorb → descendant pass.
/// jj-lib's `absorb_hunks` appends the source id to each target's predecessors itself
/// (`absorb.rs:357-361`); predecessors are never touched here.
///
/// When nothing was absorbable the transaction is dropped and NO operation is written —
/// the CLI's own `tx.finish` refuses to write when `!tx.repo().has_changes()`
/// (`cli_util.rs:2792-2795`). `AbsorbResult::rewritten_change_ids` is then empty.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — a `paths` entry is not a valid repo path.
/// - [`MutateError::ChangeNotFound`] — `from` is malformed, absent, only-hidden, or
///   divergent.
/// - [`MutateError::RevsetResolutionError`] — a symbol in `destinations` cannot be resolved.
/// - [`MutateError::Immutable`] — a commit the hunks would be absorbed into is inside the
///   repo's effective immutable set. Unreachable with the `mutable()` default, which
///   excludes that set by construction; reachable when the caller widens `destinations`.
/// - [`MutateError::Config`] — the repo's jj config or its `immutable_heads()` alias could
///   not be read, parsed, or resolved.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn absorb(
    workspace: &mut Workspace,
    immutable: &Arc<UserRevsetExpression>,
    destinations: &Arc<UserRevsetExpression>,
    from: Option<&ChangeId>,
    paths: &[String],
) -> Result<AbsorbResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = readonly.start_transaction();
    let source_commit = resolve_or_wc(tx.repo(), &workspace_name, from)?;
    let resolved_destinations = resolve_expression(tx.repo(), destinations).map_err(rev)?;
    let matcher = build_matcher(paths)?;

    // The CLI splits BEFORE opening its transaction. Splitting inside a transaction that is
    // dropped on refusal is observably identical (nothing is committed either way); the
    // content blobs `split_hunks_to_trees` writes to the store are harmless orphans in both
    // designs.
    let source = pollster::block_on(AbsorbSource::from_commit(tx.repo(), source_commit)).map_err(be)?;
    let selected = pollster::block_on(split_hunks_to_trees(
        tx.repo(),
        &source,
        &resolved_destinations,
        matcher.as_ref(),
    ))
    .map_err(be)?;
    let skipped_paths: Vec<SkippedPath> = selected
        .skipped_paths
        .iter()
        .map(|(path, reason)| SkippedPath {
            path: path.as_internal_file_string().to_owned(),
            reason: reason.clone(),
        })
        .collect();
    // CLI parity (`absorb.rs:160-162`): the guard runs over the split's TARGETS, which are
    // discovered by annotation — not over anything the caller named. An empty target set is
    // trivially rewritable and falls through to the no-op path below.
    let target_ids: Vec<jj_lib::backend::CommitId> = selected.target_commits.keys().cloned().collect();
    guard_rewritable(&tx, immutable, &target_ids)?;

    let stats = pollster::block_on(absorb_hunks(tx.repo_mut(), &source, selected.target_commits)).map_err(be)?;
    // `absorb_hunks` transforms descendants but leaves `parent_mapping` populated, so this
    // pass is what clears it — without it `tx.commit` would panic on `has_rewrites()`.
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    if !tx.repo().has_changes() {
        drop(tx);
        return Ok(AbsorbResult {
            mutation: no_op_result(
                workspace,
                &workspace_name,
                old_wc_id.as_ref(),
                old_tree.as_ref(),
                &readonly,
            )?,
            rewritten_change_ids: Vec::new(),
            source_change_id: None,
            num_rebased: 0,
            skipped_paths,
        });
    }

    let rewritten_change_ids: Vec<ChangeId> = stats
        .rewritten_destinations
        .iter()
        .map(|c| ChangeId(c.change_id().reverse_hex()))
        .collect();
    let source_change_id = stats
        .rewritten_source
        .as_ref()
        .map(|c| ChangeId(c.change_id().reverse_hex()));
    let num_rebased = u32::try_from(stats.num_rebased).unwrap_or(u32::MAX);
    let description = format!("absorb changes into {} commits", stats.rewritten_destinations.len());
    let new_repo = pollster::block_on(tx.commit(description)).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());

    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    Ok(AbsorbResult {
        mutation: MutationResult {
            new_op_id,
            new_change_ids: Vec::new(),
            abandoned_change_ids: Vec::new(),
            working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
        },
        rewritten_change_ids,
        source_change_id,
        num_rebased,
        skipped_paths,
    })
}

#[cfg(test)]
mod tests {
    use super::{build_matcher, rev, MutateError};
    use crate::config::ConfigError;
    use crate::RevsetError;

    #[test]
    fn rev_preserves_the_three_stage_revset_taxonomy() {
        assert!(matches!(
            rev(RevsetError::ParseError { reason: "p".to_owned() }),
            MutateError::RevsetParseError { reason } if reason == "p"
        ));
        assert!(matches!(
            rev(RevsetError::ResolutionError { reason: "r".to_owned() }),
            MutateError::RevsetResolutionError { reason } if reason == "r"
        ));
        assert!(matches!(
            rev(RevsetError::Config(ConfigError::Load { reason: "c".to_owned() })),
            MutateError::Config { reason } if reason.contains('c')
        ));
        assert!(matches!(
            rev(RevsetError::JjLibError("b".to_owned())),
            MutateError::Backend(reason) if reason == "b"
        ));
    }

    #[test]
    fn build_matcher_refuses_a_malformed_path() {
        let err = build_matcher(&["/absolute.txt".to_owned()]).expect_err("a leading slash is not a repo path");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason } if reason.contains("invalid path")),
            "unexpected error: {err:?}"
        );
    }
}
