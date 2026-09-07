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
use jj_lib::matchers::Matcher;
use jj_lib::merge::Diff;
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{MutableRepo, ReadonlyRepo, Repo as _};
use jj_lib::revset::{ResolvedRevsetExpression, UserRevsetExpression};
use jj_lib::rewrite::{merge_commit_trees, RebaseOptions, RewriteRefsOptions};
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::op_support::{check_rewritable, resolve_immutable, start_repo_transaction, ResolveError, SelectedTree};
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
    /// [`crate::Repo::git_fetch`] and [`crate::Repo::git_import`] — jj-lib's
    /// `GitImportStats` has no minted-change concept, and a replacement `@` for an
    /// abandoned one is already reported through `working_copy_change_id`.
    pub new_change_ids: Vec<ChangeId>,
    /// The change ids [`abandon`]'s caller passed in, echoed verbatim. Always empty for
    /// `describe`/`new_change`/`edit` — jj-lib's own side effects (e.g. `edit()`'s
    /// implicit abandon of a discardable previous `@`) are never reflected here. Always
    /// empty for [`crate::op_log::undo`] too (it restores state, it doesn't abandon
    /// anything), and for [`crate::Repo::git_import`], whose own abandonments live in
    /// [`crate::GitImportResult::abandoned_change_ids`] instead. Also always empty for
    /// [`restore`] and [`absorb`]: neither takes an id list to echo, and absorb's own
    /// outcome — which ancestors absorbed hunks and whether the source survived — lives
    /// in [`AbsorbResult`]'s fields.
    ///
    /// [`crate::Repo::git_fetch`] is the ONE verb where this is not a caller echo: it has
    /// no second result struct, so it reports jj-lib's own abandonments here — the commits
    /// the import dropped because they became unreachable in git
    /// (`git.abandon-unreachable-commits`). Empty when that key is `false`, or when the
    /// fetch made nothing unreachable.
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
    /// configured git remote (FR-JJ-13).
    ///
    /// A workspace with no git backend at all is NOT this variant — it is
    /// [`MutateError::NotAGitRepo`], the same answer the six `crate::git` verbs give.
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
    /// [`crate::Repo::git_remote_add`] was called with a name that already has a
    /// configured git remote, or [`crate::Repo::git_remote_rename`] with a NEW name that
    /// does (Story 9.5).
    ///
    /// Distinct from [`MutateError::InvalidInput`] because the remedy is: the remote is
    /// already there — re-point it with `git_remote_set_url` instead of adding it again.
    #[error("git remote already exists: {name}")]
    RemoteExists {
        /// The remote name that is already taken.
        name: String,
    },
    /// jj refuses to rewrite this remote's git config because it carries a key outside
    /// `url`/`fetch`/`tagOpt`, or a `[branch]` section referencing it carries one outside
    /// `remote`/`merge`/`rebase` (Story 9.5).
    ///
    /// Not exotic: jj-lib's own `save_remote` writes a `pushurl` key, so ADDING a remote
    /// with a push URL and then REMOVING it hits this. The remedy is to edit the git config
    /// by hand — nothing this crate offers can unblock it, which is why it is not
    /// [`MutateError::InvalidInput`] and not the unclassified [`MutateError::Backend`].
    #[error("git remote has nonstandard configuration: {name}")]
    RemoteNonstandardConfig {
        /// The remote whose git config jj refuses to rewrite.
        name: String,
    },
    /// The open workspace has no git backend, so a git-only verb cannot run at all
    /// (Story 9.5) — jj-lib's `UnexpectedGitBackendError`.
    ///
    /// Produced by the six `crate::git` verbs and — since the Epic 9 git-sync follow-up —
    /// by [`crate::Repo::git_fetch`], which used to report the identical condition as
    /// [`MutateError::RemoteNotFound`]. One condition, one variant.
    ///
    /// Reuses the already-registered `jj.not_a_git_repo` code, whose meaning widens from
    /// "this PATH is not a git repo" to "this WORKSPACE has no git backend".
    #[error("not a git repository")]
    NotAGitRepo,
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
    /// [`crate::Repo::bookmark_create`] was called with a name that is already a LOCAL
    /// bookmark (Story 9.8) — the CLI's `Bookmark already exists: {name}`
    /// (`cli/src/commands/bookmark/create.rs:64-70` @ v0.44.0). Nothing is created, not
    /// even the names that precede this one: the CLI's per-name loop is fail-fast.
    ///
    /// Its own variant rather than [`MutateError::InvalidInput`] for the same reason
    /// [`MutateError::RemoteExists`] is: the remedy is specific — the bookmark is already
    /// there, so MOVE it (`bookmark set`, Story 9.11) instead of creating it again.
    #[error("bookmark already exists: {name}")]
    BookmarkExists {
        /// The bookmark name that is already taken.
        name: String,
    },
    /// [`crate::Repo::bookmark_create`] was called with a name whose LOCAL bookmark is
    /// absent but which still has at least one TRACKED remote bookmark (Story 9.8) — the
    /// deleted-but-not-yet-pushed state, and the CLI's `Tracked remote bookmarks exist for
    /// deleted bookmark: {name}` (`create.rs:71-83` @ v0.44.0).
    ///
    /// Kept DISTINCT from [`MutateError::BookmarkExists`] because the remedies differ, which
    /// is precisely what the CLI's two separate hints say: recreate the local bookmark with
    /// `bookmark set`, or disassociate the remote with `bookmark untrack` (both Story 9.11).
    /// On a GIT-backed repo the default-ignored remote `git` is excluded, so a colocated
    /// `name@git` never triggers it there. That exclusion is git-specific — on any other
    /// backend no remote is ignored, so a tracked `name@git` does trigger it.
    #[error("tracked remote bookmarks exist for deleted bookmark: {name}")]
    BookmarkTrackedRemoteExists {
        /// The bookmark name whose tracked remote bookmarks block the create.
        name: String,
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
    ///
    /// jj-lib counts in `usize`; this is `u32` because the wire form is (`envelope.fbs`'s
    /// `AbsorbResult.num_rebased`). A count above `u32::MAX` SATURATES at `u32::MAX` rather
    /// than wrapping or failing the call — a repo with four billion rebased descendants is
    /// not a case worth failing an otherwise-successful absorb over, and the value is a
    /// progress figure for the UI, never something a decision keys off.
    pub num_rebased: u32,
    /// Paths jj-lib refused to split, with its verbatim reason. The CLI prints one warning
    /// per entry; dropping them would leave a file silently unabsorbed with no way for a
    /// GUI to say so. The remaining paths still absorb normally.
    pub skipped_paths: Vec<SkippedPath>,
}

/// One path an operation could not process, and the reason (Story 9.3, reused by Story 9.4).
///
/// Three verbs report it today: [`crate::Repo::absorb`], for a path jj-lib refuses to
/// split; [`crate::Repo::file_show`], for a path that exists but is not renderable as file
/// content; and [`crate::Repo::file_search`], for a path whose blob could not be read. In
/// every case the operation SUCCEEDS for the remaining paths — dropping these entries would
/// leave a file silently missing with no way for a GUI to say why.
///
/// The two file verbs skip DIFFERENT sets with DIFFERENT wording, because their CLI
/// counterparts do: `jj file show` warns about symlinks/submodules, `jj file search` skips
/// those silently and warns only about an unreadable blob.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkippedPath {
    /// Repo-relative path in jj's internal (`/`-separated) form.
    pub path: String,
    /// The verbatim reason, forwarded so the GUI shows what the `jj` CLI would print —
    /// jj-lib's own message for `absorb` (`Is a symlink`, `Is a conflict`, `Is a Git
    /// submodule`, `Access is denied: …`), the CLI's own sentence for `file show`
    /// (`Path '…' exists but is not a file.`) and for `file search`
    /// (`Skipping '…' due to permission error: …`).
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

/// Maps a shared [`ResolveError`] into this module's taxonomy, preserving the exact
/// `ChangeNotFound { id }` / `Backend` split the mutation verbs have always reported.
/// `pub(crate)` so [`crate::bookmark_ops`] classifies its own `resolve_or_wc` failure
/// identically instead of growing a second, desyncable copy of the same split.
pub(crate) fn res(e: ResolveError, id: Option<&ChangeId>) -> MutateError {
    match e {
        ResolveError::NotFound => MutateError::ChangeNotFound {
            id: id.map(|i| i.0.clone()).unwrap_or_default(),
        },
        ResolveError::Backend(reason) => MutateError::Backend(reason),
    }
}

/// Wraps [`crate::op_support::build_matcher`] in this module's error type. The rule —
/// empty list = everything, entries are PREFIXES, an empty-string entry is the root —
/// lives in `op_support` because the file reads apply it identically.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — an entry is not a valid repo path (a leading or
///   trailing `/`, or a `//`).
fn build_matcher(paths: &[String]) -> Result<Box<dyn Matcher>, MutateError> {
    crate::op_support::build_matcher(paths).map_err(|reason| MutateError::InvalidInput { reason })
}

/// Wraps [`crate::op_support::resolve_or_wc`] in this module's error type: `id`, or — when
/// it is `None` — the workspace's `@` (the CLI's `RevisionArg::AT` default).
fn resolve_or_wc(
    repo: &MutableRepo,
    workspace_name: &WorkspaceName,
    id: Option<&ChangeId>,
) -> Result<Commit, MutateError> {
    crate::op_support::resolve_or_wc(repo, workspace_name, id).map_err(|e| res(e, id))
}

/// Wraps [`crate::op_support::resolve_commit`] in this module's error type: a malformed,
/// absent, only-hidden or DIVERGENT id is a `ChangeNotFound` refusal, never a guess.
fn resolve_commit(repo: &MutableRepo, id: &ChangeId) -> Result<Commit, MutateError> {
    crate::op_support::resolve_commit(repo, id).map_err(|e| res(e, Some(id)))
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

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
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

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
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

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
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

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
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
///
/// `pub(crate)` so [`crate::git`]'s shared `finish_or_no_op` skeleton — and
/// `git_remote_set_url`, which never opens a transaction at all — build the same shape
/// instead of a second, desyncable copy (Story 9.5).
pub(crate) fn no_op_result(
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

/// Renders an error and its `source()` chain as `"outer: inner: …"`.
///
/// The exact projection `cli/src/git_util.rs:475-478` prints for a failed export ref
/// (`for err in iter::successors(Some(reason), |e| e.source()) { write!(": {err}") }`).
/// Started in `git.rs` (Story 9.5) for the unclassified jj-lib failures it flattens into
/// [`MutateError::Backend`]; moved here by Story 9.8, when `bookmark_ops` needed the same
/// rendering for a malformed string pattern. The reason is always the same: jj-lib keeps
/// the ACTIONABLE detail behind `#[source]`, so a top-level `Display` alone (`"Failed to
/// set"`, `"Invalid string pattern"`) tells a user nothing they can act on.
pub(crate) fn flatten_chain(err: &(dyn std::error::Error + 'static)) -> String {
    let mut out = err.to_string();
    let mut source = err.source();
    while let Some(e) = source {
        out.push_str(": ");
        out.push_str(&e.to_string());
        source = e.source();
    }
    out
}

// ── Shared transaction skeleton ──────────────────────────────────────────────────
//
// Moved here from `git.rs` by Story 9.8. It was never a git concern: it is the shape
// EVERY verb that may legitimately write nothing takes — load at head, capture `@`, run
// the work inside a transaction, drop it when `has_changes()` is false, otherwise commit
// and sync the working copy. The two bookmark verbs are exactly that shape too, and a
// second copy next to them would be a second, desyncable spelling of the no-op arm.

/// What [`finish_or_no_op`] hands back: the closure's own value, the shared mutation
/// contract, and the repo the caller must project any post-call stats from.
pub(crate) struct Finished<T> {
    /// Whatever the verb's closure computed inside the transaction.
    pub(crate) value: T,
    /// Op id + working-copy change id, in the shape every mutation reports.
    pub(crate) mutation: MutationResult,
    /// The repo AFTER the call — the just-committed one, or (on the no-op path) the same
    /// head-resolved one the dropped transaction started from. A verb that projects
    /// post-call facts out of the new view reads them here; a verb whose whole answer is
    /// [`Finished::mutation`] (the three `git remote` verbs, both bookmark verbs) ignores
    /// it. It is only a POST-verb view when [`Finished::committed`] is true.
    pub(crate) repo: Arc<ReadonlyRepo>,
    /// Whether an operation was actually written. `false` means [`Finished::repo`] is the
    /// PRE-transaction repo, so it is NOT a post-verb view. `git_import` is the caller that
    /// has to branch on this, because it reports each changed ref's tracking state.
    pub(crate) committed: bool,
}

/// Loads the head operation and hands it to [`finish_or_no_op_at`].
///
/// The right entry point for a verb whose `description` needs nothing out of the repo. A
/// verb that must READ the head first — to resolve a target commit, or to name the rows it
/// is about to touch — has to load once itself and call [`finish_or_no_op_at`] with that
/// same repo, so that its description and its writes describe ONE view.
pub(crate) fn finish_or_no_op<T, F>(
    workspace: &mut Workspace,
    description: &str,
    work: F,
) -> Result<Finished<T>, MutateError>
where
    F: FnOnce(&mut Transaction) -> Result<T, MutateError>,
{
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    finish_or_no_op_at(workspace, readonly, description, work)
}

/// Runs `work` in a transaction started from `readonly` and commits it as `description`,
/// or — when `work` changed nothing — drops the transaction and writes NO operation.
///
/// The no-op arm is `WorkspaceCommandTransaction::finish`'s own guard
/// (`cli/src/cli_util.rs:2792-2795`: `if !tx.repo().has_changes() { "Nothing changed."; return }`),
/// which is why `jj git remote add` needs no guard of its own while `remove`/`rename` write
/// one explicitly for the reserved remote `git`, and why `jj bookmark delete` can match
/// nothing and still succeed. All of those shapes collapse to this one here.
///
/// On the no-op path [`no_op_result`] returns the PRE-CALL op-log head, so a caller sees
/// byte-identical op-log state — the same signal jj itself gives.
///
/// WHY the head-resolved repo is a PARAMETER rather than something this function loads:
/// the CLI does exactly one load per invocation, and a verb whose description quotes the
/// repo (a target's commit hex, the names a pattern matched) has to read the head BEFORE
/// the transaction opens. Loading a second time here would put the description and the
/// writes on two different views — a window the CLI does not have, and one that matters
/// because an external `jj` CLI or MCP process may be mutating the same repo (FR-MCP-9):
/// the op-log description could then name commits or bookmarks the transaction never
/// touched, which is precisely the byte-level parity NFR-R-2 asks for.
pub(crate) fn finish_or_no_op_at<T, F>(
    workspace: &mut Workspace,
    readonly: Arc<ReadonlyRepo>,
    description: &str,
    work: F,
) -> Result<Finished<T>, MutateError>
where
    F: FnOnce(&mut Transaction) -> Result<T, MutateError>,
{
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let value = work(&mut tx)?;
    if !tx.repo().has_changes() {
        drop(tx);
        let mutation = no_op_result(
            workspace,
            &workspace_name,
            old_wc_id.as_ref(),
            old_tree.as_ref(),
            &readonly,
        )?;
        return Ok(Finished {
            value,
            mutation,
            repo: readonly,
            committed: false,
        });
    }

    let new_repo = pollster::block_on(tx.commit(description.to_owned())).map_err(be)?;
    let new_op_id = crate::OperationId(new_repo.op_id().hex());
    let new_wc_commit = sync_working_copy(
        workspace,
        &workspace_name,
        old_wc_id.as_ref(),
        old_tree.as_ref(),
        &new_repo,
    )?;
    Ok(Finished {
        value,
        mutation: MutationResult {
            new_op_id,
            new_change_ids: Vec::new(),
            abandoned_change_ids: Vec::new(),
            working_copy_change_id: ChangeId(new_wc_commit.change_id().reverse_hex()),
        },
        repo: new_repo,
        committed: true,
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
/// - [`MutateError::ChangeNotFound`] — `from`, `into` or `changes_in` is malformed, carried
///   by no VISIBLE commit (unknown or only-hidden), or divergent. Not to be confused with an
///   ABSENT one, which is not an error at all: it is what selects the CLI's
///   `--from`/`--into`/`--changes-in` defaults spelled out above.
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

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
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
/// Two CLI WARNINGS have no counterpart here, because an `Err` carries no payload:
/// `skipped_paths` is computed before the rewritability guard (as in the CLI, `absorb.rs:154-158`
/// vs `:160-162`) but is DISCARDED when that guard refuses, and an explicitly named path that
/// matches nothing is silently a no-op rather than a warning. See [`crate::Repo::absorb`].
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — a `paths` entry is not a valid repo path.
/// - [`MutateError::ChangeNotFound`] — `from` is malformed, carried by no VISIBLE commit
///   (unknown or only-hidden), or divergent. Not to be confused with an ABSENT `from`, which
///   is not an error at all: it applies the CLI's `--from` default `@`.
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
    from: Option<&ChangeId>,
    destinations: &Arc<UserRevsetExpression>,
    paths: &[String],
) -> Result<AbsorbResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let (old_wc_id, old_tree) = capture_old_wc(&readonly, &workspace_name)?;

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
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
        // WHY the three literals instead of reading `stats`: nothing was committed, so the
        // commits `stats` would name DO NOT EXIST in the repo the caller can now observe.
        // Reporting them would hand the GUI ids it cannot resolve. `stats` is necessarily
        // empty on this branch anyway (`has_changes()` is false exactly when `absorb_hunks`
        // rewrote nothing), so this is a statement of intent, not a divergence.
        // `skipped_paths` IS carried through: those are facts about the source's own trees,
        // independent of whether anything was written.
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
    // Saturating, not wrapping or fallible — see `AbsorbResult::num_rebased`'s doc.
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
    use jj_lib::repo_path::{RepoPath, RepoPathBuf};

    use super::{build_matcher, flatten_chain, res, rev, MutateError};
    use crate::config::ConfigError;
    use crate::op_support::ResolveError;
    use crate::{ChangeId, RevsetError};

    /// A `#[source]`-carrying error must render as the whole chain, joined by `": "` —
    /// the projection `cli/src/git_util.rs:475-478` prints. The top-level Display of
    /// jj-lib's `FailedRefExportReason::FailedToSet` is only "Failed to set", so dropping
    /// the chain would throw away the entire reason a ref could not be exported.
    #[test]
    fn flatten_chain_joins_the_whole_source_chain() {
        #[derive(Debug)]
        struct Inner;
        impl std::fmt::Display for Inner {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("reference already exists")
            }
        }
        impl std::error::Error for Inner {}

        #[derive(Debug)]
        struct Outer(Inner);
        impl std::fmt::Display for Outer {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("Failed to set")
            }
        }
        impl std::error::Error for Outer {
            fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
                Some(&self.0)
            }
        }

        assert_eq!(flatten_chain(&Outer(Inner)), "Failed to set: reference already exists");
        assert_eq!(
            flatten_chain(&Inner),
            "reference already exists",
            "a leaf has no suffix"
        );
    }

    /// The two shared-resolver outcomes must keep landing in the two DIFFERENT mutation
    /// variants they always have: "that revision does not resolve" is the caller's problem
    /// (`ChangeNotFound`, id echoed), an index/store failure is not (`Backend`). Pinned
    /// directly because the `Backend` arm needs a store failure mid-resolution, which no
    /// integration fixture can provoke deterministically.
    #[test]
    fn res_preserves_the_not_found_and_backend_split() {
        let id = ChangeId("zzzzzzzz".to_owned());
        assert!(matches!(
            res(ResolveError::NotFound, Some(&id)),
            MutateError::ChangeNotFound { id } if id == "zzzzzzzz"
        ));
        // `resolve_or_wc(None)` can only fail with `Backend`, so the `None` id is the
        // defensive arm: it must still produce a ChangeNotFound rather than panicking.
        assert!(matches!(
            res(ResolveError::NotFound, None),
            MutateError::ChangeNotFound { id } if id.is_empty()
        ));
        assert!(matches!(
            res(ResolveError::Backend("index read failed".to_owned()), Some(&id)),
            MutateError::Backend(reason) if reason == "index read failed"
        ));
    }

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

    /// An empty-string entry is the repo ROOT, which prefixes everything — so it widens the
    /// filter to "all paths" instead of narrowing it to none. Pinned so the behaviour is a
    /// decision rather than an accident (`build_matcher`'s doc explains why it is kept).
    #[test]
    fn build_matcher_treats_an_empty_path_entry_as_the_repo_root() {
        let root = RepoPathBuf::root();
        let matcher = build_matcher(&[String::new()]).expect("the empty string is a valid repo path");
        assert!(matcher.matches(&root), "the root itself matches");
        assert!(
            matcher.matches(RepoPath::from_internal_string("deep/nested/file.txt").expect("valid path")),
            "an empty entry is the root prefix, so every path matches"
        );

        // Contrast: a real prefix narrows.
        let narrow = build_matcher(&["a".to_owned()]).expect("a valid prefix");
        assert!(narrow.matches(RepoPath::from_internal_string("a/x.txt").expect("valid path")));
        assert!(!narrow.matches(RepoPath::from_internal_string("b/x.txt").expect("valid path")));
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
