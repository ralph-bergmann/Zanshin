// SPDX-License-Identifier: MIT

//! `git.rs` — the six `jj git` sync + remote-config verbs (Story 9.5): `git import`,
//! `git export`, and `git remote add`/`remove`/`rename`/`set-url`.
//!
//! Split from [`crate::remotes`], which keeps the FR-JJ-9 remote *list* and the FR-JJ-13
//! *fetch* that predate this story. The six verbs here are the family the CLI itself groups
//! under `cli/src/commands/git/`, so they share one error mapper rather than being
//! scattered across two modules. The transaction skeleton
//! ([`crate::mutate::finish_or_no_op`]) and the source-chain flattener
//! ([`crate::mutate::flatten_chain`]) started here and moved to `mutate.rs` once a second
//! verb family needed them.
//!
//! Every verb opens a jj-lib transaction, mutates via `tx.repo_mut()`, and commits with the
//! CLI's own op-log description (NFR-R-2) — jj-lib only, never shells to `jj` (AR-AP-1).
//! Re-resolves to the head operation per call (ADR-0002). Four of the six can legitimately
//! finish WITHOUT writing an operation, exactly as `WorkspaceCommandTransaction::finish`
//! (`cli/src/cli_util.rs:2790-2806` @ v0.44.0) refuses to write when
//! `!tx.repo().has_changes()`; `git_remote_set_url` never opens a transaction at all,
//! because jj-lib's `set_remote_urls` takes a `&Store` and the CLI opens none either
//! (`cli/src/commands/git/remote/set_url.rs:69-74`).
//!
//! # The jj repo-config rewrite (Epic 9 follow-up J)
//!
//! `remote remove`/`rename` additionally rewrite the REPO-LEVEL jj config, exactly as the
//! CLI does (`cli/src/commands/git/mod.rs:195-262` @ v0.44.0): `[remotes.<name>]` is dropped
//! (or moved to the new name), and a `revset-aliases.'trunk()'` that is a plain remote
//! symbol naming that remote is deleted (remove) or re-pointed (rename). The edits live in
//! [`crate::config`] — the crate's only config writers — and run INSIDE the transaction
//! closure, right after the jj-lib remote mutation and before the conditional commit, which
//! is where the CLI calls them; so the rewrite happens even when NO operation is written
//! (the reserved remote `git`), and a rewrite failure drops the transaction. No file is ever
//! created: with no repo-level config file the rewrite is a no-op. The CLI's two `ui.status`
//! lines announcing it are terminal UX and are NOT ported — the effect they announce is.
//!
//! The config file is RESOLVED AND LOADED before the transaction opens, and only the moved-in
//! `ConfigFile` is written inside the closure. That is the CLI's ordering, not a refinement of
//! it: its repo layer is parsed at process start, so a malformed `config-id`, an unreadable
//! file or unparseable TOML makes the CLI refuse before `git::remove_remote` touches the git
//! config. Here likewise — such a refusal leaves NOTHING mutated, git config included. Only a
//! `save()` failure can still abort the transaction after jj-lib's git-config edit has landed,
//! which is the asymmetry the CLI's own `?` produces.
//!
//! In a COLOCATED workspace the CLI skips `git import`/`git export` with an informational,
//! exit-0 message (`import.rs:46-50`, `export.rs:41-46`), because its per-command snapshot has
//! already imported the refs and its `finish_transaction` exports them. Zanshin runs the same
//! pre-verb snapshot and finish (Story 9.26), and both verbs then return the no-op result
//! before opening any transaction — the CLI's early return ("No import/export needed in
//! colocated workspaces."), after the pre-verb snapshot has already imported the refs.
//!
//! # Deliberate divergences from the CLI at v0.44.0
//!
//! - **No terminal UX.** No hints, no padded columns, no "Nothing changed." — the typed
//!   results below carry the structured fields those lines would have rendered.
//! - **No `--no-integrate-operation` refusal** (`export.rs:36-39`): Zanshin has no such
//!   global flag to refuse.
//! - **No duplicate-URL warning** on `remote add` (`add.rs:75-117`): it is a `ui.warning`
//!   with no effect on the operation, and [`crate::MutationResult`] has no warning channel.

use std::sync::Arc;

use jj_lib::git::{self, GitExportError, GitImportError, GitImportRefUpdate, GitRemoteManagementError};
use jj_lib::op_store::RemoteRefState;
use jj_lib::ref_name::RemoteNameBuf;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::rewrite::RebaseOptions;
use jj_lib::workspace::Workspace;

use crate::mutate::{self, flatten_chain, MutateError, MutationResult};
use crate::op_support::resolve_immutable;
use crate::snapshot::VerbContext;
use crate::ChangeId;

// ── Result types ─────────────────────────────────────────────────────────────────

/// How one remote ref changed during [`crate::Repo::git_import`] (Story 9.5).
///
/// Ports `cli/src/git_util.rs:418-425`'s own derivation from
/// `(old_remote_ref.target.is_absent(), new_target.is_absent())`.
// Member order mirrors the wire enum in `schemas/envelope.fbs` — APPEND only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitRefUpdateKind {
    /// jj had no such remote ref; the import created it.
    New,
    /// The remote ref existed and now points somewhere else.
    Updated,
    /// The remote ref existed and the import removed it.
    Deleted,
}

/// One remote bookmark or tag [`crate::Repo::git_import`] changed (Story 9.5).
///
/// The CLI renders exactly these four facts per line
/// (`git_util.rs:435-459`: `"{label}: {symbol} [{import_status}] {tracking_status}"`); the
/// padding and colouring are the terminal UX Zanshin replaces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitRefUpdate {
    /// Bookmark or tag name (UTF-8).
    pub name: String,
    /// The remote it belongs to, e.g. `"origin"`.
    pub remote: String,
    /// Whether the import created, updated, or deleted it.
    pub kind: GitRefUpdateKind,
    /// Whether the ref is TRACKED afterwards. Read from the POST-import view, not from
    /// `old_remote_ref` — the CLI reads it the same way (`git_util.rs:413-416`), because a
    /// freshly-imported ref's tracking state is decided during the import itself.
    pub tracked: bool,
}

/// Outcome of a successful [`crate::Repo::git_import`] (Story 9.5).
#[derive(Debug)]
pub struct GitImportResult {
    /// The shared mutation contract: op id (the PRE-CALL head when nothing was imported),
    /// and the working-copy change id afterwards. `new_change_ids` / `abandoned_change_ids`
    /// are always empty — an import's own abandonments live in
    /// [`GitImportResult::abandoned_change_ids`] below, which is a different fact from the
    /// caller-supplied id list [`crate::MutationResult::abandoned_change_ids`] echoes.
    pub mutation: MutationResult,
    /// Remote BOOKMARKS the import changed, in jj-lib's own `symbol` order.
    pub changed_bookmarks: Vec<GitRefUpdate>,
    /// Remote TAGS the import changed, in jj-lib's own `symbol` order.
    pub changed_tags: Vec<GitRefUpdate>,
    /// Change ids of the commits the import abandoned because they became unreachable in
    /// git (`git.abandon-unreachable-commits`). If `@` was among them, jj-lib gave the
    /// working copy a new empty commit, and `mutation.working_copy_change_id` is its id.
    pub abandoned_change_ids: Vec<ChangeId>,
    /// How many commits the import rewrote. A COUNT because a count is all the CLI reports
    /// (`git_util.rs:259-265`, `Updated {n} rewritten commits.`); resolving each rewritten
    /// commit id to a change id would be work no consumer asked for.
    ///
    /// jj-lib counts in `usize`; this is `u32` because the wire form is. A count above
    /// `u32::MAX` SATURATES rather than wrapping or failing the call — same rule as
    /// [`crate::AbsorbResult::num_rebased`].
    pub num_rewritten: u32,
    /// Git ref names the import could NOT read, sorted by name. A failed ref is never an
    /// error: the CLI warns and exits 0 (`git_util.rs:270-295`), and nothing in the
    /// repository state lets a caller re-derive this list afterwards.
    ///
    /// Lossy UTF-8 over jj-lib's `BString`s — a git ref name is not guaranteed UTF-8.
    /// A name under `refs/remotes/git/` is the reserved-namespace case the CLI hints about.
    pub failed_ref_names: Vec<String>,
}

/// One remote ref [`crate::Repo::git_export`] could not write to git (Story 9.5).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitExportFailure {
    /// Bookmark or tag name (UTF-8).
    pub name: String,
    /// The remote it belongs to — `"git"` for the local git repo's own refs.
    pub remote: String,
    /// jj-lib's reason, rendered as the flattened `source()` chain joined by `": "`,
    /// exactly as the CLI prints it (`git_util.rs:475-478`). The two interesting variants
    /// (`FailedToDelete`/`FailedToSet`) hide the real cause behind `#[source]`, so the
    /// top-level Display alone would say only "Failed to set".
    pub reason: String,
}

/// Outcome of a successful [`crate::Repo::git_export`] (Story 9.5).
#[derive(Debug)]
pub struct GitExportResult {
    /// The shared mutation contract: op id (the PRE-CALL head when nothing was exported),
    /// and the working-copy change id afterwards. Export never moves `@` and never mints or
    /// abandons a change, so the two id vectors are always empty.
    pub mutation: MutationResult,
    /// Bookmarks that could not be exported. Carried in the RESULT, never as an `Err`: the
    /// CLI warns and exits 0, and an export whose only outcome is a failure list must still
    /// be readable.
    pub failed_bookmarks: Vec<GitExportFailure>,
    /// Tags that could not be exported. Git has no remote tags, so this only ever contains
    /// `@git` tags (jj-lib's own note on `GitExportStats::failed_tags`).
    pub failed_tags: Vec<GitExportFailure>,
}

// ── Error mapping ────────────────────────────────────────────────────────────────

/// Maps a [`GitRemoteManagementError`] onto this crate's taxonomy.
///
/// WHY no caller-supplied `name` parameter: every name-carrying variant carries the
/// OFFENDING name itself, and for `rename` that is the only correct choice — `NoSuchRemote`
/// names the OLD remote while `RemoteAlreadyExists` names the NEW one, so a single
/// caller-supplied name would be wrong for one of them.
///
/// The three [`jj_lib::git::GitRemoteNameError`] cases (reserved `git`, a slash, a
/// gix-invalid name) all become [`MutateError::InvalidInput`] carrying jj-lib's own reason
/// verbatim — they are one fault class ("that name is not usable") with one remedy.
///
/// Matched EXHAUSTIVELY, like the two mappers below: none of jj-lib's three git error enums
/// is `#[non_exhaustive]` at the 0.44.0 pin, so a variant added by a future bump should fail
/// to compile here — and be classified deliberately — rather than land silently in the
/// unclassified [`MutateError::Backend`] bucket.
fn map_remote_mgmt_err(e: GitRemoteManagementError) -> MutateError {
    match e {
        GitRemoteManagementError::NoSuchRemote(name) => MutateError::RemoteNotFound {
            name: name.as_str().to_owned(),
        },
        GitRemoteManagementError::RemoteAlreadyExists(name) => MutateError::RemoteExists {
            name: name.as_str().to_owned(),
        },
        GitRemoteManagementError::RemoteName(inner) => MutateError::InvalidInput {
            reason: inner.to_string(),
        },
        GitRemoteManagementError::NonstandardConfiguration(name) => MutateError::RemoteNonstandardConfig {
            name: name.as_str().to_owned(),
        },
        GitRemoteManagementError::UnexpectedBackend(_) => MutateError::NotAGitRepo,
        other @ (GitRemoteManagementError::GitConfigSaveError(_)
        | GitRemoteManagementError::InternalGitError(_)
        | GitRemoteManagementError::RefExpansionError(_)) => MutateError::Backend(flatten_chain(&other)),
    }
}

/// Maps a [`GitImportError`] onto this crate's taxonomy: "no git backend" is its own
/// answerable refusal, everything else is an unclassified jj-lib failure. Exhaustive — see
/// [`map_remote_mgmt_err`].
fn map_import_err(e: GitImportError) -> MutateError {
    match e {
        GitImportError::UnexpectedBackend(_) => MutateError::NotAGitRepo,
        other @ (GitImportError::MissingHeadTarget { .. }
        | GitImportError::MissingRefAncestor { .. }
        | GitImportError::Backend(_)
        | GitImportError::Index(_)
        | GitImportError::RevsetEvaluation(_)
        | GitImportError::Git(_)) => MutateError::Backend(flatten_chain(&other)),
    }
}

/// Maps a [`GitExportError`] onto this crate's taxonomy — same split as
/// [`map_import_err`], and exhaustive for the same reason. A FAILED REF is not an error at
/// all; see [`GitExportResult`].
///
/// `pub(crate)` since Story 9.22: `file untrack`'s colocated export runs the same
/// `export_refs` and must classify its failures identically.
pub(crate) fn map_export_err(e: GitExportError) -> MutateError {
    match e {
        GitExportError::UnexpectedBackend(_) => MutateError::NotAGitRepo,
        other @ GitExportError::Git(_) => MutateError::Backend(flatten_chain(&other)),
    }
}

// ── git import ───────────────────────────────────────────────────────────────────

/// Projects jj-lib's `GitImportRefUpdate`s into the owned [`GitRefUpdate`] shape.
///
/// `repo` MUST be the POST-import view: the tracking flag is read from it, exactly as
/// `cli/src/git_util.rs:412-433` does. Callers are responsible for not calling this with a
/// pre-transaction repo — see `git_import`'s no-op branch.
fn project_updates(repo: &Arc<ReadonlyRepo>, updates: &[GitImportRefUpdate], tags: bool) -> Vec<GitRefUpdate> {
    updates
        .iter()
        .map(|update| {
            let symbol = update.symbol.as_ref();
            let remote_ref = if tags {
                repo.view().get_remote_tag(symbol)
            } else {
                repo.view().get_remote_bookmark(symbol)
            };
            let kind = match (update.old_remote_ref.target.is_absent(), update.new_target.is_absent()) {
                (true, false) => GitRefUpdateKind::New,
                (false, true) => GitRefUpdateKind::Deleted,
                _ => GitRefUpdateKind::Updated,
            };
            GitRefUpdate {
                // `.as_str()`, never `.as_symbol()`: the latter renders QUOTED revset
                // syntax, which is a rendering, not a name.
                name: update.symbol.name.as_str().to_owned(),
                remote: update.symbol.remote.as_str().to_owned(),
                kind,
                tracked: remote_ref.state == RemoteRefState::Tracked,
            }
        })
        .collect()
}

/// Projects jj-lib's `GitImportStats.abandoned_commits` into owned [`ChangeId`]s.
///
/// `pub(crate)` and shared: `git_import` and [`crate::Repo::git_fetch`] both run
/// `GitFetch`/`import_refs` and both report the SAME fact — the commits jj-lib itself
/// abandoned because they became unreachable in git (`git.abandon-unreachable-commits`).
/// One helper so the two verbs cannot drift in how they read those stats.
pub(crate) fn project_abandoned(stats: &jj_lib::git::GitImportStats) -> Vec<ChangeId> {
    stats
        .abandoned_commits
        .iter()
        .map(|c| ChangeId(c.change_id().reverse_hex()))
        .collect()
}

/// Imports the backing git repo's refs into jj's view (Story 9.5) — the CLI's
/// `jj git import`.
///
/// Order mirrors `cli/src/commands/git/import.rs:58-59` exactly: `import_head` FIRST, then
/// `import_refs`. A descendant pass then runs BEFORE the commit, because `import_refs` calls
/// `record_abandoned_commit` (`jj-lib git.rs:796`), which populates `parent_mapping`, and
/// `Transaction::write` panics while rewrites are outstanding — the CLI handles this
/// centrally in `tx.finish` → `rebase_mutable_descendants` (`cli_util.rs:2927-2945`),
/// resolving the immutable set against `tx.base_repo()`, which is what happens here too.
///
/// `options` comes from the repo's EFFECTIVE config
/// ([`crate::config::git_import_options`]), so a user's
/// `git.abandon-unreachable-commits = false` is honoured (FR-JJ-17).
///
/// The stats are projected AFTER the commit, from the resulting view. They are returned on
/// the NO-OP path too: a run where every pending ref failed changes nothing yet must still
/// report `failed_ref_names` — and warn `jj.git_import_failed`, right after the import and
/// before the finish, where the CLI prints it (`import.rs:60`, Story 9.32).
///
/// In a COLOCATED workspace it returns before any transaction, as the CLI does ("No import
/// needed in colocated workspaces.", `cli/src/commands/git/import.rs:46-50` @ v0.44.0): the
/// pre-verb snapshot already imported the refs, so the result is the no-op at the head.
///
/// # Errors
///
/// - [`MutateError::NotAGitRepo`] — the workspace has no git backend.
/// - [`MutateError::Config`] — a `git.*` / `remotes.<name>.auto-track-bookmarks` import option
///   is malformed, or the immutable-set expression could not be resolved.
/// - [`MutateError::Backend`] — any other underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn git_import(workspace: &mut Workspace, ctx: &mut VerbContext) -> Result<GitImportResult, MutateError> {
    if ctx.colocated {
        return Ok(GitImportResult {
            changed_bookmarks: Vec::new(),
            changed_tags: Vec::new(),
            abandoned_change_ids: Vec::new(),
            num_rewritten: 0,
            failed_ref_names: Vec::new(),
            mutation: colocated_no_op(workspace)?,
        });
    }
    let import_options = crate::config::git_import_options(&ctx.config).map_err(mutate::cfg)?;
    let immutable = Arc::clone(&ctx.immutable);
    let finished = mutate::finish_or_no_op(workspace, "import git refs", ctx, |tx, sink| {
        pollster::block_on(git::import_head(tx.repo_mut())).map_err(map_import_err)?;
        let stats = pollster::block_on(git::import_refs(tx.repo_mut(), &import_options)).map_err(map_import_err)?;
        sink.extend(crate::warning::git_import_failed(&stats));
        // Resolve first so the shared borrow of `tx` ends before `repo_mut()`.
        let resolved = resolve_immutable(tx.base_repo().as_ref(), &immutable)?;
        pollster::block_on(tx.repo_mut().rebase_descendants_with_options(
            &resolved,
            &RebaseOptions::default(),
            |_, _| {},
        ))
        .map_err(mutate::be)?;
        Ok(stats)
    })?;
    Ok(project_import(
        &finished.value,
        &finished.repo,
        finished.committed,
        finished.mutation,
    ))
}

/// The no-op result the colocated `git import` / `git export` return: nothing written, the head
/// as it stands after the pre-verb snapshot.
fn colocated_no_op(workspace: &Workspace) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    mutate::no_op_result(workspace.workspace_name(), &readonly)
}

/// Projects an `import_refs` run into a [`GitImportResult`] — shared by [`git_import`] and the
/// pre-verb snapshot's `import git refs` step (Story 9.26), which report the same fact.
///
/// `repo` is the repo AFTER the call; `committed` says whether it is a post-import view. The
/// changed-ref lists are only projected from a post-import view — see the WHY below. The
/// abandoned commits, the rewrite count and the failed refs are facts of the import itself and
/// are reported either way: a run where every pending ref failed changes nothing yet must still
/// report `failed_ref_names`.
pub(crate) fn project_import(
    stats: &jj_lib::git::GitImportStats,
    repo: &Arc<ReadonlyRepo>,
    committed: bool,
    mutation: MutationResult,
) -> GitImportResult {
    // WHY the branch instead of projecting unconditionally: on the no-op path `repo` is the
    // PRE-transaction repo, so `project_updates`' post-import tracking-flag read would be
    // answered by a stale view. It cannot currently produce a wrong value — jj-lib reports no
    // changed refs exactly when nothing was written — but that is a coupling between two
    // independent jj-lib facts, so it is asserted rather than relied on.
    let (changed_bookmarks, changed_tags) = if committed {
        (
            project_updates(repo, &stats.changed_remote_bookmarks, false),
            project_updates(repo, &stats.changed_remote_tags, true),
        )
    } else {
        debug_assert!(
            stats.changed_remote_bookmarks.is_empty() && stats.changed_remote_tags.is_empty(),
            "an import that wrote no operation cannot have changed a remote ref"
        );
        (Vec::new(), Vec::new())
    };
    GitImportResult {
        changed_bookmarks,
        changed_tags,
        abandoned_change_ids: project_abandoned(stats),
        // Saturating, not wrapping or fallible — see `GitImportResult::num_rewritten`.
        num_rewritten: u32::try_from(stats.rewritten_commit_ids.len()).unwrap_or(u32::MAX),
        failed_ref_names: stats
            .failed_ref_names
            .iter()
            .map(|n| String::from_utf8_lossy(n).into_owned())
            .collect(),
        mutation,
    }
}

// ── git export ───────────────────────────────────────────────────────────────────

/// Projects jj-lib's `(symbol, reason)` export failures into the owned shape. `pub(crate)`
/// since Story 9.22, whose `file untrack` reports its colocated export's failures the same way.
pub(crate) fn project_failures(
    failures: &[(jj_lib::ref_name::RemoteRefSymbolBuf, jj_lib::git::FailedRefExportReason)],
) -> Vec<GitExportFailure> {
    failures
        .iter()
        .map(|(symbol, reason)| GitExportFailure {
            name: symbol.name.as_str().to_owned(),
            remote: symbol.remote.as_str().to_owned(),
            reason: flatten_chain(reason),
        })
        .collect()
}

/// Writes jj's bookmarks and tags back to the backing git repo (Story 9.5) — the CLI's
/// `jj git export`.
///
/// `jj_lib::git::export_refs` is SYNCHRONOUS (unlike the import pair), and it rewrites no
/// commit, so this verb needs neither a descendant pass nor the immutable expression —
/// it takes the plain [`crate::mutate::finish_or_no_op`] shape.
///
/// Refs that could not be written are carried in [`GitExportResult::failed_bookmarks`] /
/// `failed_tags`, never as an `Err`: the CLI warns and exits 0 (`git_util.rs:468-506`) — AFTER
/// the finish (`export.rs:50-51`), which is where `jj.git_export_failed` is recorded
/// (Story 9.32).
///
/// In a COLOCATED workspace it returns before any transaction, as the CLI does ("No export
/// needed in colocated workspaces.", `cli/src/commands/git/export.rs:41-46` @ v0.44.0) — even
/// when jj holds refs that were never exported.
///
/// # Errors
///
/// - [`MutateError::NotAGitRepo`] — the workspace has no git backend.
/// - [`MutateError::Backend`] — any other underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn git_export(workspace: &mut Workspace, ctx: &mut VerbContext) -> Result<GitExportResult, MutateError> {
    if ctx.colocated {
        return Ok(GitExportResult {
            failed_bookmarks: Vec::new(),
            failed_tags: Vec::new(),
            mutation: colocated_no_op(workspace)?,
        });
    }
    let finished = mutate::finish_or_no_op(workspace, "export git refs", ctx, |tx, _sink| {
        git::export_refs(tx.repo_mut()).map_err(map_export_err)
    })?;
    let stats = finished.value;
    ctx.warnings.extend(crate::warning::git_export_failed(&stats));
    Ok(GitExportResult {
        failed_bookmarks: project_failures(&stats.failed_bookmarks),
        failed_tags: project_failures(&stats.failed_tags),
        mutation: finished.mutation,
    })
}

// ── git remote add / remove / rename / set-url ────────────────────────────────────

/// Registers a new git remote (Story 9.5) — the CLI's `jj git remote add`.
///
/// `url` and `push_url` are passed to jj-lib VERBATIM. The CLI additionally resolves a
/// local path to absolute form (`absolute_git_url`); that is terminal-input convenience
/// (it depends on the process CWD, which a GUI backend has no business consulting), so a
/// caller supplies the URL it means.
///
/// Description: `"add git remote {name}"` (`add.rs:63`).
///
/// Every OTHER remote whose fetch or push URL equals the new fetch or push URL (a missing push
/// URL meaning the fetch URL, as in Git) warns `jj.remote_url_duplicate` — exact string
/// equality only, and never the URL itself, which may carry credentials
/// (`warn_if_remote_url_matches`, `add.rs:75-119`, Story 9.32).
///
/// # Errors
///
/// - [`MutateError::RemoteExists`] — `name` already has a configured remote.
/// - [`MutateError::InvalidInput`] — `name` is the reserved `git`, contains a slash, or is
///   not a valid gix remote name; jj-lib's reason verbatim.
/// - [`MutateError::NotAGitRepo`] — the workspace has no git backend.
/// - [`MutateError::Backend`] — any other underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn git_remote_add(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    name: &str,
    url: &str,
    push_url: Option<&str>,
) -> Result<MutationResult, MutateError> {
    let remote: RemoteNameBuf = name.into();
    let finished = mutate::finish_or_no_op(workspace, &format!("add git remote {name}"), ctx, |tx, sink| {
        git::add_remote(tx.repo_mut(), &remote, url, push_url).map_err(map_remote_mgmt_err)?;
        warn_if_remote_url_matches(tx.repo(), &remote, url, push_url, sink)
    })?;
    Ok(finished.mutation)
}

/// The CLI's `warn_if_remote_url_matches` (`cli/src/commands/git/remote/add.rs:75-119` @
/// v0.44.0): one `jj.remote_url_duplicate` per other remote already using the new fetch or push
/// URL. Remotes that do not load are ignored, as there.
///
/// # Errors
///
/// - [`MutateError::NotAGitRepo`] — the workspace has no git backend.
fn warn_if_remote_url_matches(
    repo: &dyn jj_lib::repo::Repo,
    new_remote: &jj_lib::ref_name::RemoteName,
    new_fetch_url: &str,
    new_push_url: Option<&str>,
    sink: &mut crate::warning::Warnings,
) -> Result<(), MutateError> {
    let git_repo = git::get_git_repo(repo.store()).map_err(|_| MutateError::NotAGitRepo)?;
    // Git uses the fetch URL for push when no push URL is configured.
    let new_push_url = new_push_url.unwrap_or(new_fetch_url);
    for remote_name in git_repo.remote_names() {
        if remote_name.as_ref() == new_remote.as_str() {
            continue;
        }
        let Some(Ok(remote)) = git_repo.try_find_remote_without_url_rewrite(&*remote_name) else {
            continue;
        };
        let fetch = remote.url(gix::remote::Direction::Fetch).map(gix::Url::to_bstring);
        let push = remote.url(gix::remote::Direction::Push).map(gix::Url::to_bstring);
        if [fetch, push]
            .iter()
            .flatten()
            .any(|remote_url| remote_url == new_fetch_url || remote_url == new_push_url)
        {
            sink.push(
                crate::warning::WarningKind::RemoteUrlDuplicate,
                format!("Remote {remote_name} already uses the same URL."),
            );
        }
    }
    Ok(())
}

/// Removes a git remote and forgets its bookmarks (Story 9.5) — the CLI's
/// `jj git remote remove`.
///
/// jj-lib does NOT validate the name here (`validate_remote_name` is applied by `add`,
/// `rename`'s NEW name and `set-url` only), which is how the reserved remote `git` can be
/// removed. That case changes no view state, so NO operation is written — the CLI's own
/// `if tx.repo().has_changes()` guard with the comment "Do not print \"Nothing changed.\"
/// for the remote named \"git\"" (`remove.rs:42-47`).
///
/// The repo-level jj config is rewritten too, inside the same transaction window — see the
/// module doc. That happens on the reserved-remote path as well, because the CLI's rewrite
/// sits BEFORE its `has_changes()` guard.
///
/// Description: `"remove git remote {name}"`.
///
/// # Errors
///
/// - [`MutateError::Config`] — the repo-level jj config could not be read (a malformed
///   `.jj/repo/config-id`, an unreadable file, invalid TOML), in which case NOTHING is
///   mutated; or it could not be written back, which aborts the transaction after jj-lib's
///   git-config edit has already landed.
/// - [`MutateError::RemoteNotFound`] — no such remote.
/// - [`MutateError::RemoteNonstandardConfig`] — the remote's `[remote "…"]` section carries
///   a key outside `url`/`fetch`/`tagOpt` (a remote added WITH a push URL is exactly this
///   case: jj-lib's own `save_remote` writes `pushurl`), or a `[branch]` section referencing
///   it carries one outside `remote`/`merge`/`rebase`.
/// - [`MutateError::NotAGitRepo`] — the workspace has no git backend.
/// - [`MutateError::Backend`] — any other underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn git_remote_remove(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    name: &str,
) -> Result<MutationResult, MutateError> {
    let remote: RemoteNameBuf = name.into();
    // Resolved AND LOADED before the transaction opens, so every read-side fault — a
    // malformed `config-id`, an unreadable file, invalid TOML — refuses before anything at
    // all is mutated, exactly as the CLI's start-up-parsed repo layer does.
    let config_file = crate::config::existing_repo_config_file(workspace).map_err(mutate::cfg)?;
    let finished = mutate::finish_or_no_op(
        workspace,
        &format!("remove git remote {name}"),
        ctx,
        move |tx, _sink| {
            git::remove_remote(tx.repo_mut(), &remote).map_err(map_remote_mgmt_err)?;
            crate::config::remove_remote_from_repo_config(config_file, name).map_err(mutate::cfg)
        },
    )?;
    Ok(finished.mutation)
}

/// Renames a git remote (Story 9.5) — the CLI's `jj git remote rename`.
///
/// jj-lib validates the NEW name BEFORE it reports that the OLD one is missing
/// (`jj-lib git.rs:2490-2496`), so `rename <missing> git` reports the reserved-name refusal,
/// not "no such remote". That ordering is jj-lib's and is reproduced, not corrected.
/// Renaming FROM the reserved `git` changes no view state and writes no operation, for the
/// same reason `remove` does not.
///
/// The repo-level jj config is rewritten too, inside the same transaction window — see the
/// module doc.
///
/// Description: `"rename git remote {old} to {new}"` (`rename.rs:48-52`).
///
/// # Errors
///
/// - [`MutateError::Config`] — the repo-level jj config could not be read (a malformed
///   `.jj/repo/config-id`, an unreadable file, invalid TOML), in which case NOTHING is
///   mutated; or it could not be written back, which aborts the transaction after jj-lib's
///   git-config edit has already landed.
/// - [`MutateError::InvalidInput`] — `new_name` is the reserved `git`, contains a slash, or
///   is not a valid gix remote name.
/// - [`MutateError::RemoteNotFound`] — `old_name` has no configured remote.
/// - [`MutateError::RemoteExists`] — `new_name` is already taken.
/// - [`MutateError::RemoteNonstandardConfig`] — `old_name`'s git config is not the plain
///   single-fetch-refspec shape jj knows how to rewrite.
/// - [`MutateError::NotAGitRepo`] — the workspace has no git backend.
/// - [`MutateError::Backend`] — any other underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn git_remote_rename(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    old_name: &str,
    new_name: &str,
) -> Result<MutationResult, MutateError> {
    let old: RemoteNameBuf = old_name.into();
    let new: RemoteNameBuf = new_name.into();
    let description = format!("rename git remote {old_name} to {new_name}");
    // Resolved AND LOADED before the transaction opens — see `git_remote_remove`.
    let config_file = crate::config::existing_repo_config_file(workspace).map_err(mutate::cfg)?;
    let finished = mutate::finish_or_no_op(workspace, &description, ctx, move |tx, _sink| {
        git::rename_remote(tx.repo_mut(), &old, &new).map_err(map_remote_mgmt_err)?;
        crate::config::rename_remote_in_repo_config(config_file, old_name, new_name).map_err(mutate::cfg)
    })?;
    Ok(finished.mutation)
}

/// Re-points a git remote's fetch and/or push URL (Story 9.5) — the CLI's
/// `jj git remote set-url`.
///
/// Opens NO transaction and writes NO operation, ever: jj-lib's `set_remote_urls` takes a
/// `&Store` rather than a `&mut MutableRepo`, and the CLI opens none either
/// (`set_url.rs:69-74`). The returned [`MutationResult`] therefore always carries the
/// PRE-CALL op-log head.
///
/// A `None` URL leaves that side unchanged — jj-lib cannot REMOVE a URL. With BOTH `None`
/// it returns `Ok(())` in its very first line, *before* it checks that the remote exists
/// (`jj-lib git.rs:2606-2608`), so the call succeeds even for an absent remote. That is
/// mirrored deliberately: inventing a refusal there would be a divergence.
///
/// # Errors
///
/// - [`MutateError::RemoteNotFound`] — at least one URL was supplied and `name` has no
///   configured remote.
/// - [`MutateError::InvalidInput`] — `name` is the reserved `git`, contains a slash, or is
///   not a valid gix remote name.
/// - [`MutateError::NotAGitRepo`] — the workspace has no git backend.
/// - [`MutateError::Backend`] — any other underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn git_remote_set_url(
    workspace: &mut Workspace,
    name: &str,
    url: Option<&str>,
    push_url: Option<&str>,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let remote: RemoteNameBuf = name.into();
    git::set_remote_urls(readonly.store(), &remote, url, push_url).map_err(map_remote_mgmt_err)?;
    mutate::no_op_result(workspace.workspace_name(), &readonly)
}

#[cfg(test)]
mod tests {
    use super::{map_export_err, map_import_err, map_remote_mgmt_err};
    use crate::MutateError;

    /// Every `GitRemoteManagementError` arm must land in the variant whose remedy matches.
    /// Three of the seven cannot be provoked through a real repo deterministically
    /// (a git-config write failing with EIO, an internal gix failure, a refspec-expansion
    /// failure), so the mapper is pinned directly.
    #[test]
    fn map_remote_mgmt_err_covers_every_arm() {
        use jj_lib::git::{GitRemoteManagementError as E, GitRemoteNameError};
        use jj_lib::ref_name::RemoteNameBuf;

        let name: RemoteNameBuf = "origin".into();
        assert!(matches!(
            map_remote_mgmt_err(E::NoSuchRemote(name.clone())),
            MutateError::RemoteNotFound { name } if name == "origin"
        ));
        assert!(matches!(
            map_remote_mgmt_err(E::RemoteAlreadyExists(name.clone())),
            MutateError::RemoteExists { name } if name == "origin"
        ));
        assert!(matches!(
            map_remote_mgmt_err(E::NonstandardConfiguration(name.clone())),
            MutateError::RemoteNonstandardConfig { name } if name == "origin"
        ));
        assert!(
            matches!(
                map_remote_mgmt_err(E::RemoteName(GitRemoteNameError::ReservedForLocalGitRepo)),
                MutateError::InvalidInput { ref reason } if reason.contains("reserved")
            ),
            "jj-lib's own reason must be forwarded verbatim"
        );
        assert!(matches!(
            map_remote_mgmt_err(E::RemoteName(GitRemoteNameError::WithSlash(name))),
            MutateError::InvalidInput { .. }
        ));
        assert!(matches!(
            map_remote_mgmt_err(E::GitConfigSaveError(std::io::Error::other("disk full"))),
            MutateError::Backend(reason) if reason.contains("disk full")
        ));
        assert!(matches!(
            map_remote_mgmt_err(E::InternalGitError("boom".into())),
            MutateError::Backend(reason) if reason.contains("boom")
        ));
    }

    /// The import/export mappers keep "no git backend" answerable and flatten everything
    /// else. The `UnexpectedBackend` arms ARE reachable from an integration test (a native
    /// repo), but the `Backend` arms need a jj-lib internal failure that no fixture can
    /// provoke, so both mappers are pinned here.
    #[test]
    fn import_and_export_mappers_split_backend_from_everything_else() {
        use jj_lib::git::{GitExportError, GitImportError};

        assert!(matches!(
            map_import_err(GitImportError::Git("no such object".into())),
            MutateError::Backend(reason) if reason.contains("no such object")
        ));
        assert!(matches!(
            map_export_err(GitExportError::Git("ref lock failed".into())),
            MutateError::Backend(reason) if reason.contains("ref lock failed")
        ));
    }
}
