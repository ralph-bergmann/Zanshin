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
//! Every verb runs after [`crate::Repo`]'s pre-verb snapshot (Story 9.26), so `@` already holds
//! the on-disk edits, exactly as after the CLI's `workspace_helper`. Every verb whose CLI
//! counterpart ends in `tx.finish` commits through [`finish_transaction`], the port of the CLI's
//! `finish_transaction`: the became-immutable new `@`, the colocated Git HEAD reset and ref
//! export under the Git import/export lock, the commit, the working-copy checkout and — since
//! Story 9.32 — the CLI's finish warnings, recorded into the call's [`Warnings`]. The
//! locked-working-copy lifecycle — [`lock_working_copy`] and [`commit_with_locked_wc`] (Story
//! 9.22) — is the raw-transaction shape `file track`/`file untrack` use instead.

use std::sync::Arc;

use jj_lib::absorb::{absorb_hunks, split_hunks_to_trees, AbsorbSource};
use jj_lib::commit::{conflict_label_for_commits, Commit};
use jj_lib::git;
use jj_lib::matchers::Matcher;
use jj_lib::merge::Diff;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{MutableRepo, ReadonlyRepo, Repo as _};
use jj_lib::revset::{ResolvedRevsetExpression, RevsetExpression, UserRevsetExpression};
use jj_lib::rewrite::{merge_commit_trees, RebaseOptions, RewriteRefsOptions};
use jj_lib::transaction::Transaction;
use jj_lib::working_copy::LockedWorkingCopy;
use jj_lib::workspace::{LockedWorkspace, Workspace};

use crate::git::{map_export_err, project_failures};
use crate::op_support::{check_rewritable, resolve_immutable, start_repo_transaction, ResolveError, SelectedTree};
use crate::revset::resolve_expression;
use crate::snapshot::{lock_git_import_export, FinishFacts, GitImportExportLock, VerbContext};
use crate::warning::{self, WarningKind, Warnings};
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
    /// The refs the colocated export could not write while the CLI's `finish_transaction`
    /// committed this call's operation (Story 9.26) — the data behind its
    /// `jj.git_export_failed` warnings. `None` when both lists are empty — always for a result
    /// that wrote no operation, and for [`crate::Repo::file_track`] /
    /// [`crate::Repo::file_untrack`], which never reach `finish_transaction`.
    ///
    /// The finish's other facts — a `@` that became immutable, a Git HEAD that could not be
    /// reset, an empty identity, skipped checkout files — are warnings only (Story 9.32): see
    /// [`crate::Repo::take_warnings`].
    pub finish: Option<FinishFacts>,
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
    /// A verb that must lock the working copy found no working-copy commit for this
    /// workspace in the head view (Story 9.22) — the CLI's "Nothing checked out in this
    /// workspace" (`cli/src/cli_util.rs:1486-1490` @ v0.44.0). Nothing is locked or written.
    #[error("nothing checked out in this workspace")]
    NoWorkingCopy,
    /// The working copy's recorded tree differs from `@`'s tree in the head view (Story 9.22):
    /// `@` was rewritten without a checkout between the pre-verb snapshot and the verb's own
    /// working-copy lock — a concurrent writer. The CLI's check behind "Concurrent working copy
    /// operation. Try again." (`cli_util.rs:1501-1505`). Nothing is written.
    #[error("concurrent working copy operation")]
    ConcurrentWorkingCopy,
    /// [`crate::Repo::file_untrack`] matched paths that are NOT ignored, so the next snapshot
    /// would add them straight back (Story 9.22) — the CLI's `'<path>' is not ignored.` /
    /// `'<path>' and N other files are not ignored.` (`untrack.rs:84-104`).
    ///
    /// Names EVERY offender, in jj-lib's tree order; the CLI's message names the first and
    /// counts the rest, which is `paths[0]` and `paths.len() - 1` here. No operation is written
    /// and the working-copy state is left exactly as it was.
    #[error("paths are not ignored: {}", paths.join(", "))]
    PathsNotIgnored {
        /// Repo-relative paths (jj's internal `/`-separated form) that would be re-added.
        paths: Vec<String>,
    },
    /// The pre-verb snapshot failed (Story 9.26) — the verb itself never ran. See
    /// [`crate::PreconditionError`]; the partial facts ride [`crate::Repo::take_precondition`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
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
        crate::RevsetError::Precondition(inner) => MutateError::Precondition(inner),
        // Only `Repo::graph_topology` raises it; no mutation walks a graph.
        e @ crate::RevsetError::DanglingEdge { .. } => MutateError::Backend(e.to_string()),
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

/// Records `print_unmatched_explicit_paths` over `trees` for the explicit `paths` (Story 9.32).
/// Runs after [`build_matcher`] validated them, so a parse failure cannot occur here.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — an entry is not a valid repo path.
/// - [`MutateError::Backend`] — a tree read failed.
fn warn_unmatched(
    workspace: &Workspace,
    sink: &mut Warnings,
    paths: &[String],
    trees: &[&jj_lib::merged_tree::MergedTree],
) -> Result<(), MutateError> {
    let explicit = crate::op_support::parse_prefixes(paths).map_err(|reason| MutateError::InvalidInput { reason })?;
    warning::warn_unmatched_paths(sink, workspace.workspace_root(), &explicit, trees).map_err(be)
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

// ── Finishing a transaction (Story 9.26) ─────────────────────────────────────────

/// What [`finish_transaction`] needs besides the transaction: the immutable set (for the
/// became-immutable check), whether the workspace is colocated, and the held Git
/// import/export lock the colocated HEAD reset and ref export run under.
pub(crate) struct FinishCtx<'a> {
    /// `::(immutable_heads() | root())` as the effective config defines it.
    pub(crate) immutable: &'a Arc<UserRevsetExpression>,
    /// Whether the working copy is shared with a Git work tree.
    pub(crate) colocated: bool,
    /// Proof that the Git import/export lock is held for the whole finish — never read, like the
    /// CLI's `_git_import_export_lock` parameter: requiring it is the point.
    pub(crate) _lock: &'a GitImportExportLock,
}

/// The outcome of [`finish_transaction`].
pub(crate) struct Finish {
    /// The just-committed repo.
    pub(crate) repo: Arc<ReadonlyRepo>,
    /// `@` after the finish — `None` only when the workspace is gone from the view.
    pub(crate) wc_commit: Option<Commit>,
    /// The refs the colocated export could not write.
    pub(crate) facts: FinishFacts,
}

/// Resets Git HEAD to `wc_commit`'s parent and the index to its tree — the CLI's
/// `try_reset_git_head` (`cli/src/cli_util.rs:2673-2695` @ v0.44.0). A failure to MOVE the HEAD
/// ref (a concurrent `git checkout`) is a warning there, so it is a `jj.git_head_update_failed`
/// warning here (Story 9.32); the next snapshot imports whatever HEAD actually is.
///
/// # Errors
///
/// - [`MutateError::Backend`] — any other reset failure.
pub(crate) fn try_reset_git_head(
    mut_repo: &mut MutableRepo,
    wc_commit: &Commit,
    sink: &mut Warnings,
) -> Result<(), MutateError> {
    match pollster::block_on(git::reset_head(mut_repo, wc_commit)) {
        Ok(()) => Ok(()),
        Err(e @ git::GitResetHeadError::UpdateHeadRef(_)) => {
            sink.extend([warning::git_head_update_failed(&e)]);
            Ok(())
        }
        Err(e) => Err(MutateError::Backend(flatten_chain(&e))),
    }
}

/// Exports jj's refs to Git and records the refs that could not be written — the CLI's
/// `export_refs` + `print_git_export_stats` pair inside `finish_transaction`: the failures as
/// data in `facts`, the CLI's two warnings in `sink` (Story 9.32).
///
/// # Errors
///
/// - [`MutateError::NotAGitRepo`] / [`MutateError::Backend`] — see
///   [`crate::git::map_export_err`].
pub(crate) fn export_refs_into(
    mut_repo: &mut MutableRepo,
    facts: &mut FinishFacts,
    sink: &mut Warnings,
) -> Result<(), MutateError> {
    let stats = git::export_refs(mut_repo).map_err(map_export_err)?;
    sink.extend(warning::git_export_failed(&stats));
    facts
        .export_failed_bookmarks
        .extend(project_failures(&stats.failed_bookmarks));
    facts.export_failed_tags.extend(project_failures(&stats.failed_tags));
    Ok(())
}

/// Whether `wc_commit` is inside the immutable set as `tx.repo()` sees it. An immutable set that
/// does not RESOLVE counts as "not immutable": the CLI skips the step on that failure
/// (`if let Ok(immutable_expr) = …`, `cli_util.rs:2324-2329`).
fn wc_is_immutable(
    tx: &Transaction,
    immutable: &Arc<UserRevsetExpression>,
    wc_commit: &Commit,
) -> Result<bool, MutateError> {
    let Ok(resolved) = resolve_immutable(tx.repo(), immutable) else {
        return Ok(false);
    };
    let set = resolved
        .intersection(&RevsetExpression::commit(wc_commit.id().clone()))
        .evaluate(tx.repo())
        .map_err(be)?;
    Ok(!set.is_empty().map_err(be)?)
}

/// Port of the CLI's `finish_transaction` (`cli/src/cli_util.rs:2300-2417` @ v0.44.0) minus its
/// terminal output.
///
/// 1. If the transaction leaves `@` inside the immutable set, a new, empty `@` is created on top
///    of it ("The working-copy commit became immutable…").
/// 2. Colocated: Git HEAD is reset to `@`'s parent ([`try_reset_git_head`]) and jj's refs are
///    exported ([`export_refs_into`]), under `ctx.lock`.
/// 3. The transaction is committed as `description`. There is no `has_changes()` check here —
///    the CLI has none either; its callers skip the call when nothing changed.
/// 4. `@` is checked out ALWAYS when it exists, even if it did not move: the CLI's
///    `update_working_copy` calls `Workspace::check_out` unconditionally, which (re)records the
///    working copy at the new operation.
/// 5. The identity check: an empty `user.name`/`user.email` in the settings the operation was
///    written with warns (`cli_util.rs:2387-2415`) — only here, so every caller that commits
///    through this function warns and nothing else does.
///
/// Its warnings land in `sink` in the CLI's print order: became-immutable, the HEAD reset, the
/// export failures, the skipped checkout files, the identity (Story 9.32).
///
/// The old `@` whose tree `check_out` verifies the working copy against is read from
/// `tx.base_repo()`, as in the CLI.
///
/// # Errors
///
/// - [`MutateError::Backend`] — a store read, the Git reset, the commit or the checkout failed
///   ("Failed to check out commit …").
/// - [`MutateError::NotAGitRepo`] — the colocated export found no Git backend.
pub(crate) fn finish_transaction(
    workspace: &mut Workspace,
    mut tx: Transaction,
    description: &str,
    ctx: &FinishCtx<'_>,
    sink: &mut Warnings,
) -> Result<Finish, MutateError> {
    let workspace_name = workspace.workspace_name().to_owned();
    let get_wc_commit = |repo: &dyn jj_lib::repo::Repo| -> Result<Option<Commit>, MutateError> {
        repo.view()
            .get_wc_commit_id(&workspace_name)
            .map(|id| repo.store().get_commit(id))
            .transpose()
            .map_err(be)
    };
    let maybe_old_wc_commit = get_wc_commit(tx.base_repo().as_ref())?;
    let maybe_new_wc_commit = get_wc_commit(tx.repo())?;

    let mut facts = FinishFacts::default();
    let maybe_new_wc_commit = match maybe_new_wc_commit {
        Some(wc_commit) if wc_is_immutable(&tx, ctx.immutable, &wc_commit)? => {
            let new_wc_commit = pollster::block_on(
                tx.repo_mut()
                    .new_commit(vec![wc_commit.id().clone()], wc_commit.tree())
                    .write(),
            )
            .map_err(be)?;
            tx.repo_mut()
                .set_wc_commit(workspace_name.clone(), new_wc_commit.id().clone())
                .map_err(be)?;
            sink.push(WarningKind::WorkingCopyImmutable, warning::WC_BECAME_IMMUTABLE);
            Some(new_wc_commit)
        }
        other => other,
    };

    if ctx.colocated {
        if let Some(wc_commit) = &maybe_new_wc_commit {
            try_reset_git_head(tx.repo_mut(), wc_commit, sink)?;
        }
        export_refs_into(tx.repo_mut(), &mut facts, sink)?;
    }

    let new_repo = pollster::block_on(tx.commit(description.to_owned())).map_err(be)?;

    if let Some(new_wc_commit) = &maybe_new_wc_commit {
        let old_tree = maybe_old_wc_commit.as_ref().map(Commit::tree);
        let stats = pollster::block_on(workspace.check_out(new_repo.op_id().clone(), old_tree.as_ref(), new_wc_commit))
            .map_err(|e| {
                MutateError::Backend(format!(
                    "Failed to check out commit {}: {}",
                    new_wc_commit.id().hex(),
                    flatten_chain(&e)
                ))
            })?;
        sink.extend(warning::checkout_files_skipped(stats.skipped_files));
    }
    sink.extend(warning::identity_missing(new_repo.settings()));
    Ok(Finish {
        repo: new_repo,
        wc_commit: maybe_new_wc_commit,
        facts,
    })
}

/// Takes the Git import/export lock and finishes `tx` — `WorkspaceCommandTransaction::finish`'s
/// tail (`cli/src/cli_util.rs:2800-2805` @ v0.44.0), which takes the lock right before
/// `finish_transaction` so the Git HEAD export is atomic with the commit.
///
/// # Errors
///
/// Anything [`lock_git_import_export`] or [`finish_transaction`] returns.
pub(crate) fn finish_verb(
    workspace: &mut Workspace,
    tx: Transaction,
    description: &str,
    ctx: &mut VerbContext,
) -> Result<Finish, MutateError> {
    let lock = lock_git_import_export(workspace, ctx.colocated)?;
    finish_transaction(
        workspace,
        tx,
        description,
        &FinishCtx {
            immutable: &ctx.immutable,
            colocated: ctx.colocated,
            _lock: &lock,
        },
        &mut ctx.warnings,
    )
}

/// The shared mutation contract out of a [`Finish`]: the committed op id, `@`'s change id and
/// the finish facts.
///
/// # Errors
///
/// - [`MutateError::Backend`] — the workspace has no working-copy commit after the finish.
pub(crate) fn mutation_result(
    finish: &Finish,
    new_change_ids: Vec<ChangeId>,
    abandoned_change_ids: Vec<ChangeId>,
) -> Result<MutationResult, MutateError> {
    let wc_commit = finish
        .wc_commit
        .as_ref()
        .ok_or_else(|| MutateError::Backend("workspace has no working-copy commit".to_owned()))?;
    Ok(MutationResult {
        new_op_id: crate::OperationId(finish.repo.op_id().hex()),
        new_change_ids,
        abandoned_change_ids,
        working_copy_change_id: ChangeId(wc_commit.change_id().reverse_hex()),
        finish: finish.facts.clone().into_option(),
    })
}

/// Rewrites `change_id`'s description to `description` (FR-JJ-10a).
///
/// `ctx.immutable` is the repo's effective immutable-set expression, parsed by the pre-verb
/// snapshot ([`crate::snapshot::CommandEnv`]); the target is refused if it falls
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
    ctx: &mut VerbContext,
    change_id: &ChangeId,
    description: &str,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();

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
    guard_rewritable(&tx, &ctx.immutable, std::slice::from_ref(commit.id()))?;
    pollster::block_on(
        tx.repo_mut()
            .rewrite_commit(&commit)
            .set_description(description)
            .write(),
    )
    .map_err(be)?;
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let finish = finish_verb(workspace, tx, &format!("describe commit {}", commit.id().hex()), ctx)?;
    mutation_result(&finish, Vec::new(), Vec::new())
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
pub(crate) fn new_change(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    parents: &[ChangeId],
) -> Result<MutationResult, MutateError> {
    if parents.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "new_change requires at least one parent".to_owned(),
        });
    }

    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();

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
    let finish = finish_verb(workspace, tx, "new empty commit", ctx)?;
    mutation_result(&finish, vec![new_change_id], Vec::new())
}

/// Switches the working copy to `change_id` without creating a new commit (FR-JJ-10a).
///
/// `ctx.immutable` is the repo's effective immutable-set expression, parsed by the pre-verb
/// snapshot ([`crate::snapshot::CommandEnv`]); the target is refused if it falls
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
    ctx: &mut VerbContext,
    change_id: &ChangeId,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let commit = resolve_commit(tx.repo(), change_id)?;
    guard_rewritable(&tx, &ctx.immutable, std::slice::from_ref(commit.id()))?;
    pollster::block_on(tx.repo_mut().edit(workspace_name.clone(), &commit)).map_err(be)?;
    // See new_change's comment: edit() may implicitly abandon a discardable previous
    // `@`, leaving an un-rebased rewrite that would trip tx.commit()'s assertion.
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let finish = finish_verb(workspace, tx, &format!("edit commit {}", commit.id().hex()), ctx)?;
    mutation_result(&finish, Vec::new(), Vec::new())
}

/// Abandons `change_ids`, rebasing descendants onto their parents and deleting any
/// bookmarks that pointed only at the abandoned commits (FR-JJ-10a).
///
/// `ctx.immutable` is the repo's effective immutable-set expression, parsed by the pre-verb
/// snapshot ([`crate::snapshot::CommandEnv`]); a target inside it is refused,
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
    ctx: &mut VerbContext,
    change_ids: &[ChangeId],
) -> Result<MutationResult, MutateError> {
    if change_ids.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "abandon requires at least one change id".to_owned(),
        });
    }

    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let old_wc_id = readonly.view().get_wc_commit_id(&workspace_name).cloned();

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
    let resolved_immutable = guard_rewritable(&tx, &ctx.immutable, &target_ids)?;
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
    let finish = finish_verb(workspace, tx, &description, ctx)?;
    let new_change_ids = match (&finish.wc_commit, wc_was_abandoned) {
        (Some(new_wc_commit), true) => vec![ChangeId(new_wc_commit.change_id().reverse_hex())],
        _ => Vec::new(),
    };
    mutation_result(&finish, new_change_ids, change_ids.to_vec())
}

/// Builds the result of a mutation that deliberately wrote NOTHING.
///
/// `readonly` is the SAME head-resolved repo the (now dropped) transaction started from, so
/// the op-log head is unchanged and `@` cannot have moved: nothing is checked out, `@` is only
/// read. `finish` is `None` — the CLI's `finish_transaction` never ran, so neither did its
/// warnings (the identity check included).
///
/// `pub(crate)` so [`crate::git`]'s verbs — and `git_remote_set_url`, which never opens a
/// transaction at all — and the precondition's refs import build the same shape instead of a
/// second, desyncable copy (Story 9.5).
///
/// # Errors
///
/// - [`MutateError::Backend`] — the workspace has no working-copy commit, or it could not be
///   read.
pub(crate) fn no_op_result(
    workspace_name: &WorkspaceName,
    readonly: &Arc<ReadonlyRepo>,
) -> Result<MutationResult, MutateError> {
    let wc_id = readonly
        .view()
        .get_wc_commit_id(workspace_name)
        .ok_or_else(|| MutateError::Backend("workspace has no working-copy commit".to_owned()))?;
    let wc = readonly.store().get_commit(wc_id).map_err(be)?;
    Ok(MutationResult {
        new_op_id: crate::OperationId(readonly.op_id().hex()),
        new_change_ids: Vec::new(),
        abandoned_change_ids: Vec::new(),
        working_copy_change_id: ChangeId(wc.change_id().reverse_hex()),
        finish: None,
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
    ctx: &mut VerbContext,
    work: F,
) -> Result<Finished<T>, MutateError>
where
    F: FnOnce(&mut Transaction, &mut Warnings) -> Result<T, MutateError>,
{
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    finish_or_no_op_at(workspace, readonly, description, ctx, work)
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
/// `work` records the warnings the CLI prints inside the transaction (before `tx.finish`) into
/// the call's collector it is handed (Story 9.32).
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
    ctx: &mut VerbContext,
    work: F,
) -> Result<Finished<T>, MutateError>
where
    F: FnOnce(&mut Transaction, &mut Warnings) -> Result<T, MutateError>,
{
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let value = work(&mut tx, &mut ctx.warnings)?;
    if !tx.repo().has_changes() {
        drop(tx);
        let mutation = no_op_result(&workspace_name, &readonly)?;
        return Ok(Finished {
            value,
            mutation,
            repo: readonly,
            committed: false,
        });
    }

    let finish = finish_verb(workspace, tx, description, ctx)?;
    let mutation = mutation_result(&finish, Vec::new(), Vec::new())?;
    Ok(Finished {
        value,
        mutation,
        repo: finish.repo,
        committed: true,
    })
}

// ── Locked working copy (Story 9.22) ─────────────────────────────────────────────
//
// The working-copy lifecycle the CLI runs whenever a verb reads or rewrites the ON-DISK state
// rather than only the view: lock → `snapshot`/`reset` → commit → `finish(op_id)`. Unlike
// `finish_transaction` (which goes through `Workspace::check_out` and rewrites FILES),
// `snapshot` and `reset` never touch a file: they update the recorded working-copy STATE, which
// `finish` persists together with the operation id it now corresponds to.

/// Locks the working copy of `workspace` and returns it with `@` as `repo` sees it — the port of
/// `WorkspaceCommandHelper::start_working_copy_mutation` (`cli/src/cli_util.rs:1482-1507` @
/// v0.44.0).
///
/// `repo` must be the head-resolved repo the caller's transaction starts from, so `@` and the
/// transaction describe one view. The concurrency check is the CLI's: if the tree the working
/// copy last recorded is not `@`'s tree, `@` was rewritten by an operation nobody checked out,
/// and snapshotting on top of it would mix two states.
///
/// Dropping the returned [`LockedWorkspace`] WITHOUT `finish` releases the lock and discards
/// every in-memory `snapshot`/`reset`, leaving the on-disk state byte-identical.
///
/// # Errors
///
/// - [`MutateError::NoWorkingCopy`] — `repo`'s view has no `@` for this workspace.
/// - [`MutateError::ConcurrentWorkingCopy`] — the recorded working-copy tree is not `@`'s.
/// - [`MutateError::Backend`] — the commit could not be read or the lock not taken.
pub(crate) fn lock_working_copy<'w>(
    workspace: &'w mut Workspace,
    repo: &ReadonlyRepo,
) -> Result<(LockedWorkspace<'w>, Commit), MutateError> {
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .ok_or(MutateError::NoWorkingCopy)?
        .clone();
    let wc_commit = repo.store().get_commit(&wc_id).map_err(be)?;
    let mut locked_ws = pollster::block_on(workspace.start_working_copy_mutation()).map_err(be)?;
    if wc_commit.tree().tree_ids_and_labels() != locked_ws.locked_wc().old_tree().tree_ids_and_labels() {
        return Err(MutateError::ConcurrentWorkingCopy);
    }
    Ok((locked_ws, wc_commit))
}

/// Runs `work` against a transaction AND the locked working copy, then commits `description`
/// UNCONDITIONALLY and finishes the working copy at the new operation (Story 9.22).
///
/// The shape of `cmd_file_track`/`cmd_file_untrack` @ v0.44.0: both commit the raw
/// `Transaction` (`start_transaction().into_inner()` … `tx.commit(..)`), which BYPASSES
/// `WorkspaceCommandTransaction::finish`'s "Nothing changed." guard — so, unlike
/// [`finish_or_no_op`], an operation is written even when the view did not change. Order is the
/// CLI's: the transaction opens FIRST (through [`start_repo_transaction`], so it records the
/// workspace name), then the lock; `work` runs; `tx.commit`; `locked_ws.finish(op_id)`.
///
/// On an `Err` from `work` the lock and the transaction are dropped WITHOUT `finish`: no
/// operation, and the working-copy state on disk is exactly what it was.
///
/// No `check_out` follows: `work` has already left the working-copy state where it belongs
/// (a snapshot records the files as they are; a `reset` points the state at the new `@`
/// without touching a file). That is the difference to [`finish_transaction`]. The returned
/// [`MutationResult`] reads `@` from the committed view; its id vectors are empty.
///
/// # Errors
///
/// - Anything [`lock_working_copy`] or `work` returns.
/// - [`MutateError::Backend`] — the commit or the working-copy `finish` failed.
pub(crate) fn commit_with_locked_wc<T, F>(
    workspace: &mut Workspace,
    readonly: &Arc<ReadonlyRepo>,
    description: &str,
    work: F,
) -> Result<(T, MutationResult), MutateError>
where
    F: FnOnce(&mut Transaction, &mut dyn LockedWorkingCopy, &Commit) -> Result<T, MutateError>,
{
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(readonly, &workspace_name);
    let (mut locked_ws, wc_commit) = lock_working_copy(workspace, readonly)?;
    let value = work(&mut tx, locked_ws.locked_wc(), &wc_commit)?;
    let new_repo = pollster::block_on(tx.commit(description.to_owned())).map_err(be)?;
    pollster::block_on(locked_ws.finish(new_repo.op_id().clone())).map_err(be)?;
    let new_wc_id = new_repo
        .view()
        .get_wc_commit_id(&workspace_name)
        .ok_or(MutateError::NoWorkingCopy)?;
    let new_wc = new_repo.store().get_commit(new_wc_id).map_err(be)?;
    Ok((
        value,
        MutationResult {
            new_op_id: crate::OperationId(new_repo.op_id().hex()),
            new_change_ids: Vec::new(),
            abandoned_change_ids: Vec::new(),
            working_copy_change_id: ChangeId(new_wc.change_id().reverse_hex()),
            // WHY `None`: `track`/`untrack` commit the raw transaction and never reach
            // `finish_transaction` — so they never warn about the identity either, the CLI's
            // "Name and email not configured" living there (`cli/src/cli_util.rs:2387-2415`).
            finish: None,
        },
    ))
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
/// There is NO interactive/hunk selection (epics.md:5536 scopes this to whole files); `@` is
/// the working-copy commit the pre-verb snapshot has just brought up to date (Story 9.26).
///
/// An explicitly named path that matches nothing in either tree warns
/// (`jj.paths_unmatched`, `restore.rs:174-179`) after the rewritability guard and before the
/// no-op check, where the CLI prints it (Story 9.32).
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
    ctx: &mut VerbContext,
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
    guard_rewritable(&tx, &ctx.immutable, std::slice::from_ref(to_commit.id()))?;

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
    warn_unmatched(workspace, &mut ctx.warnings, paths, &[&to_tree, &from_tree])?;
    if selected.tree().tree_ids() == to_commit.tree_ids() {
        drop(tx);
        return no_op_result(&workspace_name, &readonly);
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
    let finish = finish_verb(
        workspace,
        tx,
        &format!("restore into commit {}", to_commit.id().hex()),
        ctx,
    )?;
    mutation_result(&finish, Vec::new(), Vec::new())
}

/// Moves each hunk of the source commit into the closest commit in `destinations` where the
/// corresponding lines were last modified (Story 9.3) — the CLI's `jj absorb`,
/// non-interactive only.
///
/// `destinations` is a caller-supplied revset EXPRESSION, not an id list: the CLI's `--into`
/// is a `Vec<RevisionArg>` unioned into a *set* whose default is the dynamic `mutable()`
/// alias, and materializing it into ids would destroy that meaning (FR-JJ-17). `from`
/// defaults to `@`, which the pre-verb snapshot has just brought up to date with the on-disk
/// edits, exactly as the CLI's `workspace_helper` does (Story 9.26).
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
/// Warnings in the CLI's order (Story 9.32): an explicitly named path that matches nothing in
/// the source tree (`jj.paths_unmatched`, `absorb.rs:102-107`), then one `jj.absorb_path_skipped`
/// per path jj-lib refused to split (`:155-158`) — BEFORE the rewritability guard, so a refusal's
/// error envelope still carries them — then the finish's.
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
    ctx: &mut VerbContext,
    from: Option<&ChangeId>,
    destinations: &Arc<UserRevsetExpression>,
    paths: &[String],
) -> Result<AbsorbResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();

    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let source_commit = resolve_or_wc(tx.repo(), &workspace_name, from)?;
    let resolved_destinations = resolve_expression(tx.repo(), destinations).map_err(rev)?;
    let matcher = build_matcher(paths)?;
    warn_unmatched(workspace, &mut ctx.warnings, paths, &[&source_commit.tree()])?;

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
    for (path, reason) in &selected.skipped_paths {
        ctx.warnings.push(
            WarningKind::AbsorbPathSkipped,
            format!(
                "Skipping {}: {reason}",
                warning::ui_path(workspace.workspace_root(), path)
            ),
        );
    }
    // CLI parity (`absorb.rs:160-162`): the guard runs over the split's TARGETS, which are
    // discovered by annotation — not over anything the caller named. An empty target set is
    // trivially rewritable and falls through to the no-op path below.
    let target_ids: Vec<jj_lib::backend::CommitId> = selected.target_commits.keys().cloned().collect();
    guard_rewritable(&tx, &ctx.immutable, &target_ids)?;

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
            mutation: no_op_result(&workspace_name, &readonly)?,
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
    let finish = finish_verb(workspace, tx, &description, ctx)?;
    Ok(AbsorbResult {
        mutation: mutation_result(&finish, Vec::new(), Vec::new())?,
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
        // Story 9.26: a failed pre-verb snapshot keeps its own variant.
        assert!(matches!(
            rev(RevsetError::Precondition(crate::PreconditionError::Backend("p".to_owned()))),
            MutateError::Precondition(crate::PreconditionError::Backend(reason)) if reason == "p"
        ));
        // Story 4.10: a dangling topology edge is no revset stage of its own here.
        assert!(matches!(
            rev(RevsetError::DanglingEdge { target: "ab".to_owned() }),
            MutateError::Backend(reason) if reason.contains("ab")
        ));
    }

    /// A repo whose `@` was rewritten with a new tree WITHOUT the working copy being updated — the
    /// state a concurrent writer leaves between a verb's pre-verb snapshot (Story 9.26) and the
    /// verb's own working-copy work. Returns the head repo that sees the rewritten `@`.
    fn at_rewritten_without_checkout() -> (
        tempfile::TempDir,
        crate::Repo,
        std::sync::Arc<jj_lib::repo::ReadonlyRepo>,
    ) {
        use jj_lib::object_id::ObjectId as _;

        test_helpers::pin_test_env();
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let repo = crate::Repo::init(tmp.path(), None).result.expect("init");
        let load_head = |repo: &crate::Repo| {
            pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("load_at_head")
        };
        let at = load_head(&repo)
            .view()
            .get_wc_commit_id(repo.workspace().workspace_name())
            .expect("@")
            .hex();
        let _ = test_helpers::rewrite_commit_files(repo.workspace_root(), &at, &[("elsewhere.txt", "x")]);
        let head = load_head(&repo);
        (tmp, repo, head)
    }

    /// The working-copy lock refuses when the recorded tree no longer matches `@`'s — the CLI's
    /// "Concurrent working copy operation. Try again.". After the pre-verb snapshot only a
    /// concurrent writer can cause it, so the lock is exercised directly.
    #[test]
    fn locking_a_working_copy_behind_at_is_a_concurrent_working_copy_refusal() {
        let (_tmp, mut repo, head) = at_rewritten_without_checkout();
        let result = super::lock_working_copy(repo.workspace_mut(), &head);
        assert!(matches!(result.err(), Some(MutateError::ConcurrentWorkingCopy)));
    }

    /// `finish_transaction`'s unconditional checkout (the CLI's `update_working_copy`) fails when
    /// the working copy is not at the base repo's `@` — reported as the CLI's "Failed to check
    /// out commit …" with jj-lib's reason.
    #[test]
    fn a_checkout_over_a_working_copy_behind_at_fails_the_finish() {
        let (_tmp, mut repo, head) = at_rewritten_without_checkout();
        let config = crate::config::load(&repo).expect("config");
        let mut sink = crate::warning::Warnings::default();
        let immutable =
            crate::op_support::immutable_user_expression(repo.workspace(), &config, &mut sink).expect("immutable set");
        let lock = crate::snapshot::lock_git_import_export(repo.workspace(), false).expect("no lock needed");
        let workspace_name = repo.workspace().workspace_name().to_owned();
        let tx = crate::op_support::start_repo_transaction(&head, &workspace_name);
        let ctx = super::FinishCtx {
            immutable: &immutable,
            colocated: false,
            _lock: &lock,
        };

        let err = super::finish_transaction(repo.workspace_mut(), tx, "test", &ctx, &mut sink)
            .err()
            .expect("the checkout must fail");

        assert!(
            matches!(&err, MutateError::Backend(reason) if reason.starts_with("Failed to check out commit ")),
            "{err:?}"
        );
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
