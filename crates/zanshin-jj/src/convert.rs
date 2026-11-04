// SPDX-License-Identifier: MIT

//! Git → jj conversion helpers (FR-JJ-18a / FR-JJ-18b).
//!
//! Two distinct conversion modes are provided:
//!
//! ## Colocated conversion — [`convert_colocated`] (FR-JJ-18a)
//!
//! Creates a jj workspace **in-place** inside an existing Git repo: a `.jj/` is
//! added alongside the existing `.git/`; the two share the **same directory** and
//! the same object store.  The Git CLI keeps working; `jj` leads on the snapshot
//! schedule.  Deleting `.jj/` fully restores the plain Git repo.
//!
//! Mirrors `jj git init --colocate` over an existing `.git/`.
//!
//! ## jj-native import — [`convert_import`] (FR-JJ-18b)
//!
//! Creates a **separate**, non-colocated jj workspace at a **user-chosen
//! destination directory**, backed by the object store of an existing Git repo.
//! The destination gets a `.jj/` and **no** `.git/`; jj leads exclusively.
//!
//! **This is NOT a clone.** The new workspace shares the source's Git object
//! store (`.jj/repo/store/git_target` → `<source>/.git`); the source repo must
//! continue to exist after the import — moving or deleting it corrupts the jj
//! workspace.  Use [`convert_colocated`] if you want everything in one directory,
//! or `Repo::clone` if you need a self-contained copy of the objects.
//!
//! Mirrors `jj git init --git-repo=<source> <destination>` (non-colocated).
//! A **bare** source repo is supported (unlike `convert_colocated`).
//!
//! ### jj 0.42 note
//!
//! In-place jj-native conversion of an existing `.git/` is impossible in jj
//! 0.42: `jj git init --no-colocate` over an existing `.git/` is a hard error.
//! A genuinely non-colocated result always requires a separate destination
//! directory, hence the two-parameter signature of `convert_import`.
//!
//! ## What both verbs write (Epic 9 follow-up K)
//!
//! Both port `do_init`'s `GitInitMode::External` arm (`cli/src/commands/git/init.rs:249-282`
//! @ v0.46.0), so a repo Zanshin converts is on-disk indistinguishable from one `jj git init`
//! converted — including the op log, which is state a user undoes with the CLI. That arm has
//! TWO shapes, and which one runs is read from [`crate::wc_ops::is_colocated_git_workspace`]
//! (the CLI's own check), never assumed:
//!
//! 1. **`import git refs`** ([`init_git_refs`]) — both shapes. One transaction running
//!    [`jj_lib::git::import_refs`] with the effective import options plus the CLI's two
//!    overrides; NO operation is written when it changed nothing (`has_changes()`), and a
//!    colocated workspace also runs [`jj_lib::git::export_refs`] before the commit.
//! 2. **`.jj/.gitignore`** ([`maybe_add_gitignore`]) — the literal `/*\n`, COLOCATED only.
//! 3. **`maybe_snapshot`** ([`maybe_snapshot`]) — both shapes: the same implicit snapshot every
//!    verb runs first (`crate::snapshot`, Story 9.26), under the Git import/export lock. In the
//!    colocated shape that is `import git head` (`@` checked out onto the Git HEAD and the
//!    working-copy STATE reset to it — no file is touched), then `snapshot working copy` (a
//!    dirty work tree lands in `@`), then `import git refs`; in the non-colocated shape the
//!    snapshot alone. Each operation is written only when it changed something.
//! 4. **`revset-aliases.'trunk()'`** ([`maybe_set_trunk_alias`]) — both shapes. Written into
//!    the REPO-level config file, which lives OUTSIDE `.jj/` (under
//!    `<config_dir>/jj/repos/`), when `refs/remotes/upstream/HEAD` or
//!    `refs/remotes/origin/HEAD` names a bookmark.
//! 5. **`import git head`, once more** — NON-colocated only ([`import_head_into_destination`]):
//!    the CLI's own non-colocated tail, `@` created on the imported HEAD and the destination's
//!    files materialised by the transaction's finish.
//!
//! Every operation either verb writes carries the converting workspace's name in its metadata,
//! the way a CLI-written one does: every transaction site opens through
//! [`crate::op_support::start_repo_transaction`] (Epic 9 follow-up L).
//!
//! What `.git/` sees is what the CLI's own sequence writes: the refs step's colocated
//! `export_refs` (it writes back exactly the refs jj has just imported), and the snapshot's
//! colocated export and index update for a dirty work tree. No user-visible ref and no HEAD is
//! moved, and no working-tree file is written or deleted.
//!
//! ## What a failure leaves (Story 9.57)
//!
//! Neither verb cleans anything up: convert never touches the working copy or `.git/`, and on
//! failure the disk is as `jj git init` leaves it — the CLI's `do_init` propagates every error
//! with `?` (`cli/src/commands/git/init.rs` @ v0.46.0), so the only cleanup is jj-lib's own `.jj`
//! removal inside `init_external_git`. A failed conversion names what it created and left in
//! [`CreationOutcome::left_behind`], so the UI can offer the decision; nothing is deleted. What
//! the call created is known from the creating calls' own results (Story 9.58): an import's
//! destination when its one-level `create_dir` succeeded, the `.jj` when `init_external_git`
//! returned `Ok` — a destination that existed, or a `.jj` the call did not create (one
//! `init_external_git` refused as existing), is never listed; the paths are canonical.
//! A failure after the `trunk()` alias step also leaves the secure-config directory
//! `<config_dir>/jj/repos/<config-id>/` it created, as the CLI does; that directory lives outside
//! the workspace and is not listed in `left_behind`.
//!
//! ## What both verbs report (Story 9.33)
//!
//! Both return a [`CreationOutcome`]. Its warnings are every `ui.warning_*` the CLI reaches on
//! the steps above, in the CLI's print order:
//!
//! 1. `jj.config_deprecated` — the start-up check's "Deprecated … config", one per deprecated
//!    key the CLI migrates (`cli_util.rs:4726-4741` @ v0.46.0; Story 9.9), before any path is
//!    touched — on a refusal too;
//! 2. `jj.git_import_failed` — refs the `import git refs` step could not read (`init.rs:314`),
//!    reported even when the step then writes no operation;
//! 3. colocated only: `jj.git_export_failed` — refs that step's export could not write
//!    (`init.rs:321-322`);
//! 4. the start-up environment's warnings (alias tables, builtin redefinitions,
//!    `immutable_heads()` diagnostics), loaded where the CLI's `for_workable_repo` builds the
//!    workspace command (`init.rs:257`, `cli_util.rs:961-991`): after the refs step, before
//!    `.jj/.gitignore` and the snapshot — which reads its snapshot knobs first, before the
//!    colocated `import git head` (`maybe_snapshot`, `cli_util.rs:1473` @ v0.47.0);
//! 5. the implicit snapshot's own warnings, as every verb's precondition reports them — its
//!    colocated refs import reports an unreadable ref a SECOND time, as the CLI does, and when it
//!    imports nothing its export reports a ref step 3 could not write a second time too
//!    (`import_export_git_refs`, `cli_util.rs:1586-1590` @ v0.47.0);
//! 6. on the snapshot's success: `jj.snapshot_files_refused` / `jj.snapshot_paths_not_utf8`
//!    (`cli_util.rs:1368`);
//! 7. non-colocated only: the `import git head` finish — `jj.working_copy_immutable` (the new
//!    `@` became immutable), `jj.checkout_files_skipped`, `jj.unresolved_conflicts` (the new `@`
//!    has conflicts) and `jj.identity_missing`.
//!
//! The raw commits (`import git refs`, the colocated `import git head`, `snapshot working copy`)
//! run no identity check, exactly as in the CLI; only a finish does. The snapshot's report is
//! [`CreationOutcome::precondition`], `Some` iff the snapshot started. A failure keeps
//! everything reported before it, and the state it describes stays on disk.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::config::StackedConfig;
use jj_lib::git::{import_refs, GitImportOptions, GitRefKind};
use jj_lib::ref_name::{GitRefName, RemoteName, WorkspaceName};
use jj_lib::repo::ReadonlyRepo;
use jj_lib::rewrite::RebaseOptions;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;

use crate::cli_command::GIT_INIT;
use crate::creation::{create_destination, failed_to_create_workspace, Created};
use crate::op_support::{resolve_immutable, start_repo_transaction};
use crate::repo::{creation_error, CreationOutcome};
use crate::warning::{self, WarningKind, Warnings};
use crate::wc_ops::is_colocated_git_workspace;
use crate::{config, detect_repo, mutate, snapshot, MutateError, Repo, RepoError, RepoKind};

/// What a conversion reports beside its result (Story 9.33), filled as the steps run so a
/// failure keeps what came before it.
#[derive(Default)]
struct ConversionReport {
    /// `maybe_snapshot`'s report — `Some` from the moment it starts.
    precondition: Option<crate::Precondition>,
    /// The conversion's warnings, in the CLI's print order.
    warnings: Warnings,
    /// What a failed conversion created and left on disk (Story 9.57), outermost first.
    left_behind: Vec<PathBuf>,
    /// What the call created (Story 9.58): the destination [`import_into`] created, and the
    /// `.jj/` once `init_external_git` returned `Ok` — the `.jj/` is the call's own only then; a
    /// `.jj` it refused as `DestinationExists` (the user's, or a concurrent process's) is not.
    created: Created,
    /// The External arm's trackable remote bookmarks (Story 11.22), set when the arm completes.
    trackable_remote_bookmarks: Vec<String>,
}

impl ConversionReport {
    /// The verb's outcome: `result` with everything reported on the way to it.
    fn into_outcome(mut self, result: Result<Repo, RepoError>) -> CreationOutcome {
        let trackable_remote_bookmarks = if result.is_ok() {
            self.trackable_remote_bookmarks
        } else {
            Vec::new()
        };
        CreationOutcome {
            result,
            precondition: self.precondition,
            warnings: self.warnings.take(),
            left_behind: self.left_behind,
            trackable_remote_bookmarks,
        }
    }
}

/// Converts the Git repository at `path` into a colocated jj workspace (FR-JJ-18a).
///
/// Additive and reversible: a `.jj/` is created alongside the existing,
/// non-destructively-reused `.git/`; the working-copy files are never
/// overwritten. The outcome's result is a warm [`Repo`] handle for the now-colocated workspace.
///
/// # What lands on disk
///
/// The CLI's `GitInitMode::External` sequence, unabridged (see the module doc): `import git
/// refs`, then the implicit snapshot — `import git head` (`@` re-parented onto HEAD),
/// `snapshot working copy` (a dirty work tree), `import git refs` — each operation written only
/// when it changed something; `.jj/.gitignore` containing `/*`; and — when
/// `refs/remotes/upstream/HEAD` or `refs/remotes/origin/HEAD` names a bookmark —
/// `revset-aliases.'trunk()'` in the repo-level config file, which lives **outside** `.jj/`,
/// under `<config_dir>/jj/repos/`.
///
/// What `.git/` sees is the CLI's own colocated bookkeeping (ref export, index update for a
/// dirty tree); no user-visible ref, no `HEAD` and no work-tree file is moved or written.
///
/// # What a failure leaves
///
/// Convert never touches the working copy or `.git/`; on failure the disk is as `jj git init`
/// leaves it — nothing is deleted beyond jj-lib's own `.jj` removal when `init_external_git`
/// itself fails. [`CreationOutcome::left_behind`] then names `<canonical root>/.jj` when the
/// call created it and it still exists (a failed re-open included); it is empty on success and
/// on every refusal that wrote nothing. A failure after the `trunk()` alias step also leaves the
/// secure-config directory `<config_dir>/jj/repos/<config-id>/`, as the CLI does; it is not
/// listed in `left_behind`.
///
/// # Warnings and the snapshot report
///
/// See the module doc's "What both verbs report": the outcome carries the conversion's
/// warnings in the CLI's order and — once the implicit snapshot started — its report, on
/// success AND on failure.
///
/// # Errors
///
/// In [`CreationOutcome::result`]:
/// - [`RepoError::AlreadyJjRepo`] — `path` is already a jj workspace.
/// - [`RepoError::NotAGitRepo`] — `path` is neither a Git repo nor exists, or it cannot be
///   resolved to an absolute path (the same answer the not-found case gives).
/// - [`RepoError::ConvertFailed`] — a jj-lib, config-write or `detect_repo` I/O error during
///   conversion; what was written up to the failure stays, as in the CLI.
/// - [`RepoError::Config`] — the jj config stack the workspace would be created with (resolved
///   for its own paths, as the CLI's `settings_for_new_workspace`) cannot be read; such a
///   user-level or new-workspace-stack fault refuses before anything is written. A fault of the
///   user-level stack is checked first, as the CLI's start-up does, so it wins over every other
///   error above. The later config faults — the start-up environment (a bad
///   `immutable_heads()`), the refs step's import options, the snapshot knobs — fail after
///   `init_external_git`, so they leave `.jj/` as the CLI does and name it in `left_behind`. The
///   converted workspace is then opened as by [`Repo::open`], whose errors apply too.
#[must_use = "the outcome carries the result, the snapshot report and the warnings"]
pub fn convert_colocated(path: &Path) -> CreationOutcome {
    let mut report = ConversionReport::default();
    let result = convert_colocated_steps(path, &mut report);
    report.into_outcome(result)
}

/// [`convert_colocated`]'s steps, reporting into `report`.
fn convert_colocated_steps(path: &Path, report: &mut ConversionReport) -> Result<Repo, RepoError> {
    // The CLI's start-up config check runs before the command touches any path.
    config::check_startup_stack(GIT_INIT, &mut report.warnings)?;
    match detect_repo(path) {
        Ok(RepoKind::Jj) => return Err(RepoError::AlreadyJjRepo { path: path.to_owned() }),
        Ok(RepoKind::Git) => {}
        Ok(RepoKind::Neither | RepoKind::PathNotFound) => return Err(RepoError::NotAGitRepo { path: path.to_owned() }),
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }

    // WHY canonicalize: as in `Repo::init` — the CLI's `jj git init` canonicalizes its
    // destination (`cli/src/commands/git/init.rs:162-163` @ v0.46.0), and the settings and the
    // re-opened handle use that root (`Repo::open` explains why the store's base must be
    // canonical). The failure answer mirrors the `PathNotFound` arm above, keeping the caller's
    // spelling in the payload.
    let root = std::fs::canonicalize(path).map_err(|_| RepoError::NotAGitRepo { path: path.to_owned() })?;
    // Resolved for the new workspace's own paths — the CLI's `settings_for_new_workspace`.
    let settings = config::user_settings_for_new_workspace(&root, GIT_INIT)?;
    let result = convert_into(&settings, &root, report).and_then(|()| Repo::open(&root));
    if result.is_err() {
        report.left_behind = report.created.left_behind();
    }
    result
}

/// Creates a **jj-native** (non-colocated) workspace at `workspace_path` from the
/// existing Git repository at `git_repo_path` (FR-JJ-18b).
///
/// Mirrors `jj git init --git-repo=<git_repo_path> <workspace_path>`: jj leads,
/// the original repo stays a working Git repo, and the two **share the Git object
/// store**.
///
/// **This is NOT a clone** — the new workspace depends on `git_repo_path`
/// continuing to exist; deleting or moving the source corrupts it.  Unlike
/// [`convert_colocated`] (in-place, colocated), the jj workspace lives in a
/// **separate** directory and ends up with a `.jj/` and no `.git/`.  A **bare**
/// source repo is supported.
///
/// The source's user-visible refs (`refs/heads`, `refs/tags`) and `HEAD` are never
/// modified; jj only adds its own objects (commit objects, `refs/jj/keep/*`
/// GC-keep markers) to the shared store. `export_refs` — the single step that writes git
/// refs at all — runs only in the colocated shape below, and even there it writes back
/// exactly the refs it has just imported.
///
/// # What lands on disk
///
/// The same CLI sequence [`convert_colocated`] runs, taking the NON-colocated shape (see the
/// module doc): `import git refs`, the implicit snapshot of the destination, then `import git
/// head`, each operation written only when it changed something, with the working copy
/// materialised from the imported HEAD; NO `.jj/.gitignore` and no `export_refs`, both of
/// which are colocated-only; and, when `refs/remotes/upstream/HEAD` or
/// `refs/remotes/origin/HEAD` names a bookmark, `revset-aliases.'trunk()'` in the repo-level
/// config file, which lives **outside** the destination, under `<config_dir>/jj/repos/`.
///
/// Passing `workspace_path == git_repo_path` (D5) is a colocated request and takes the
/// colocated shape instead — including its `.jj/.gitignore` and its colocated snapshot.
///
/// # What a failure leaves
///
/// Convert never touches the working copy or the source; on failure the disk is as `jj git init
/// --git-repo` leaves it — nothing is deleted beyond jj-lib's own `.jj` removal when
/// `init_external_git` itself fails. `workspace_path` is created ONE level deep, as the CLI's
/// `create_or_reuse_dir` (a missing parent refuses "Failed to create workspace: …" and nothing
/// is created). [`CreationOutcome::left_behind`] then names, outermost first, the destination
/// when this call created it (an existing one is reused and never listed) and its `.jj` when the
/// call created it, each only when it still exists (a failed re-open included), canonical (the
/// directory actually created, also for a `..` spelling); it is empty on success and on every
/// refusal that wrote nothing. A failure after the `trunk()` alias step also leaves the
/// secure-config directory `<config_dir>/jj/repos/<config-id>/`, as the CLI does; it is not
/// listed in `left_behind`.
///
/// # Warnings and the snapshot report
///
/// As for [`convert_colocated`] (see the module doc's "What both verbs report"); the
/// non-colocated shape adds the head import's finish — `jj.working_copy_immutable` (the new `@`
/// became immutable), `jj.checkout_files_skipped`, `jj.unresolved_conflicts` and the ONE
/// `jj.identity_missing` a conversion with an empty identity reports.
///
/// # Errors
///
/// In [`CreationOutcome::result`]:
/// - [`RepoError::AlreadyJjRepo`] — `workspace_path` (or `git_repo_path`) is
///   already a jj workspace.
/// - [`RepoError::NotAGitRepo`] — `git_repo_path` is not a Git repo (normal or
///   bare) or does not exist.
/// - [`RepoError::ConvertFailed`] — a jj-lib, config-write or `detect_repo` I/O error, or
///   `workspace_path` cannot be created or resolved (the CLI's "Failed to create workspace: …",
///   e.g. a missing parent); what was written up to the failure stays, as in the CLI.
/// - [`RepoError::Config`] — as for [`convert_colocated`]: a user-level fault refuses first,
///   before the destination is created; a fault that needs the destination's own paths (a
///   scoped table) surfaces once the destination exists (the CLI's order), so a destination
///   created for the call stays, as in the CLI. Also the head import's finish when
///   `immutable_heads()` does not resolve (the CLI's `tx.finish`): `.jj/` exists by then.
#[must_use = "the outcome carries the result, the snapshot report and the warnings"]
pub fn convert_import(git_repo_path: &Path, workspace_path: &Path) -> CreationOutcome {
    let mut report = ConversionReport::default();
    let result = convert_import_steps(git_repo_path, workspace_path, &mut report);
    report.into_outcome(result)
}

/// [`convert_import`]'s steps, reporting into `report`.
fn convert_import_steps(
    git_repo_path: &Path,
    workspace_path: &Path,
    report: &mut ConversionReport,
) -> Result<Repo, RepoError> {
    // The CLI's start-up config check runs before the command touches any path.
    config::check_startup_stack(GIT_INIT, &mut report.warnings)?;
    // Precondition 1: source must be a Git repo (normal OR bare) and not already jj.
    // Note: detect_repo returns Neither for a bare repo (no `.jj/` and no `.git/`
    // child). We check is_bare_git_dir() locally — do NOT extend detect_repo (D3).
    match detect_repo(git_repo_path) {
        Ok(RepoKind::Jj) => {
            return Err(RepoError::AlreadyJjRepo {
                path: git_repo_path.to_owned(),
            })
        }
        Ok(RepoKind::Git) => {}
        Ok(RepoKind::Neither | RepoKind::PathNotFound) => {
            if !is_bare_git_dir(git_repo_path) {
                return Err(RepoError::NotAGitRepo {
                    path: git_repo_path.to_owned(),
                });
            }
            // bare source — SUPPORTED (CLI parity, D9)
        }
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }
    // Precondition 2: destination must not already be a jj workspace.
    match detect_repo(workspace_path) {
        Ok(RepoKind::Jj) => {
            return Err(RepoError::AlreadyJjRepo {
                path: workspace_path.to_owned(),
            })
        }
        Ok(_) => {}
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }

    let result = import_into(git_repo_path, workspace_path, report).and_then(|()| Repo::open(workspace_path));
    if result.is_err() {
        report.left_behind = report.created.left_behind();
    }
    result
}

/// The `paths` that are present on disk, in their order — a dangling symlink counts.
pub(crate) fn still_present(paths: impl IntoIterator<Item = PathBuf>) -> Vec<PathBuf> {
    paths
        .into_iter()
        .filter(|path| path.symlink_metadata().is_ok())
        .collect()
}

/// Stat-only: is `path` itself a (bare) git directory?
///
/// Uses git's own gitdir heuristic: HEAD file + objects/ dir + refs/ dir.
/// `detect_repo` classifies a bare repo as `Neither` (correct for the file-picker;
/// bare repos have no `.jj/` and no `.git/` child), so the bare-source case is
/// recognised here locally — NOT by extending `detect_repo` (D3).
fn is_bare_git_dir(path: &Path) -> bool {
    path.join("HEAD").is_file() && path.join("objects").is_dir() && path.join("refs").is_dir()
}

/// Resolves the backing git dir exactly as `do_init` in the jj CLI:
/// append `.git` unless the path already ends with `.git`; fall back to the
/// path itself for a bare repo.
fn resolve_git_repo_path(arg: &Path) -> PathBuf {
    if arg.ends_with(".git") {
        return arg.to_owned();
    }
    let dot_git = arg.join(".git");
    if dot_git.exists() {
        dot_git
    } else {
        arg.to_owned()
    }
}

/// Ports `init_git_refs` (`cli/src/commands/git/init.rs:295-330` @ v0.46.0): one transaction
/// importing branches and tags, exporting them back when the workspace is colocated.
///
/// Returns the repo the following steps must build on — the NEW head when the operation was
/// written, and the one passed in when `import_refs` changed nothing, in which case NO
/// operation is written at all (the CLI's `if !tx.repo().has_changes() { return Ok(repo) }`).
/// That early return is what makes a conversion of a repo with no refs — a fresh `git init`
/// with no commits — leave the op log at `add workspace 'default'`.
///
/// The `GitImportOptions` are the effective config's ([`crate::config::git_import_options`],
/// `remotes.<name>.auto-track-bookmarks` included) with the CLI's two overrides for this flow:
/// `abandon_unreachable_commits` ("There should be no old refs to abandon, but enforce it")
/// and `record_synthetic_predecessors` ("There may be a large number of new commits") are
/// pinned to `false` regardless of the user's config.
///
/// Its warnings land in `sink` where the CLI prints them (Story 9.33): the refs the import could
/// not read (`print_git_import_stats_summary`, BEFORE the early return), then — colocated — the
/// refs the export could not write (`print_git_export_stats`). The commit is a raw
/// `tx.commit`, not a finish, so no identity check runs.
fn init_git_refs(
    repo: &Arc<ReadonlyRepo>,
    workspace_name: &WorkspaceName,
    colocated: bool,
    config: &StackedConfig,
    sink: &mut Warnings,
) -> Result<Arc<ReadonlyRepo>, RepoError> {
    let import_options = GitImportOptions {
        abandon_unreachable_commits: false,
        record_synthetic_predecessors: false,
        ..config::git_import_options(config)?
    };
    let mut tx = start_repo_transaction(repo, workspace_name);
    let stats = pollster::block_on(import_refs(tx.repo_mut(), &import_options))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    sink.extend(warning::git_import_failed(&stats));
    if !tx.repo().has_changes() {
        return Ok(Arc::clone(repo));
    }
    if colocated {
        let stats =
            jj_lib::git::export_refs(tx.repo_mut()).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        sink.extend(warning::git_export_failed(&stats));
    }
    pollster::block_on(tx.commit("import git refs")).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })
}

/// Ports `maybe_add_gitignore` (`cli/src/commands/git/mod.rs:110-123` @ v0.46.0): the literal
/// `/*\n` into `<workspace_root>/.jj/.gitignore`, and ONLY when the working copy is shared
/// with git.
///
/// It does NOT touch the workspace's own `.gitignore` — the file it writes lives inside
/// `.jj/` and hides that directory from the colocated git repo. `jj workspace add` writes it
/// into a colocated NEW workspace too (Story 9.23); each caller maps the failure to its own
/// error.
pub(crate) fn maybe_add_gitignore(workspace_root: &Path, colocated: bool) -> std::io::Result<()> {
    if !colocated {
        return Ok(());
    }
    std::fs::write(workspace_root.join(".jj").join(".gitignore"), "/*\n")
}

/// `do_init`'s `workspace_command.maybe_snapshot(ui)` (`cli/src/cli_util.rs:1469-1480` @
/// v0.47.0): the snapshot config read first, BEFORE the lock (`:1473`), then the implicit
/// snapshot every verb runs ([`crate::snapshot::snapshot_locked`]) under the Git import/export
/// lock, on the repo the refs step left behind.
///
/// Its report is `report.precondition` — `Some` from the moment this starts, PARTIAL when a step
/// fails, `was_snapshot_taken` computed as the verb precondition computes it — and its warnings
/// land in `report.warnings`: the snapshot's own, then, on success only, the snapshot stats
/// (`print_snapshot_stats`, printed after `snapshot_impl`). A wrong-typed knob fails the
/// conversion before the snapshot writes anything, as in the CLI.
fn maybe_snapshot(
    workspace: &mut Workspace,
    repo: Arc<ReadonlyRepo>,
    (config, env): (&StackedConfig, &snapshot::CommandEnv),
    colocated: bool,
    report: &mut ConversionReport,
) -> Result<Arc<ReadonlyRepo>, RepoError> {
    let precondition = report.precondition.insert(crate::Precondition::default());
    let snapshot_config = snapshot::SnapshotConfig::load(workspace, config, colocated, &mut report.warnings)
        .map_err(precondition_error)?;
    let lock = snapshot::lock_git_import_export(workspace, colocated).map_err(convert_failed)?;
    let ctx = snapshot::StepCtx {
        snapshot: &snapshot_config,
        env,
        colocated,
        lock: &lock,
    };
    let (repo, stats) = snapshot::snapshot_locked(workspace, repo, &ctx, precondition, &mut report.warnings)
        .map_err(precondition_error)?;
    report
        .warnings
        .extend(warning::snapshot_stats(workspace.workspace_root(), &stats));
    Ok(repo)
}

/// A pre-verb-snapshot failure during a conversion: a config fault stays one, everything else
/// fails the conversion.
fn precondition_error(e: crate::PreconditionError) -> RepoError {
    match e {
        crate::PreconditionError::Config { reason } => RepoError::Config { reason },
        other => RepoError::ConvertFailed {
            reason: other.to_string(),
        },
    }
}

/// Any other failure during a conversion.
fn convert_failed(e: impl std::fmt::Display) -> RepoError {
    RepoError::ConvertFailed { reason: e.to_string() }
}

/// Ports `maybe_set_repository_level_trunk_alias` (`cli/src/commands/git/init.rs:334-374` @
/// v0.46.0): `revset-aliases.'trunk()' = '<bookmark>@<remote>'` in the REPO-level config.
///
/// `upstream` is tried first, then `origin`, and the loop stops at the first remote that HAS
/// a `refs/remotes/<remote>/HEAD` reference **whether or not it parses** — the CLI's own
/// comment is that it makes no sense to fall back to `origin` once `upstream` is known to
/// exist. The alias is written only when that reference's symbolic target parses as a
/// [`GitRefKind::Bookmark`]; a direct (non-symbolic) `HEAD` has no symbolic target, so it
/// yields no alias and no config file.
///
/// At v0.46.0 there is NO `get_single_remote` guard on this — a repo with several remotes
/// still gets the alias, as long as `upstream` or `origin` has a HEAD reference.
///
/// The file this writes lives OUTSIDE `.jj/`, under `<config_dir>/jj/repos/<config-id>/`
/// (see [`crate::config::new_repo_config_file`]); `.jj/repo/config-id` is created alongside
/// it. When no `<config_dir>` can be determined, the whole step is skipped silently — the
/// CLI's own "we couldn't find the user's home directory" branch.
fn maybe_set_trunk_alias(workspace: &Workspace, repo: &impl jj_lib::repo::Repo) -> Result<(), RepoError> {
    let git_repo =
        jj_lib::git::get_git_repo(repo.store()).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    for remote in ["upstream", "origin"] {
        let ref_name = format!("refs/remotes/{remote}/HEAD");
        let found = git_repo
            .try_find_reference(ref_name.as_str())
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        let Some(reference) = found else { continue };
        // Found — the CLI returns after this remote whether or not the reference parses, so
        // a later remote is never consulted. A direct (non-symbolic) HEAD has no symbolic
        // target, and a symbolic one that resolves to anything but a bookmark (a tag, say)
        // is not a trunk either; both simply yield no alias.
        // Bound, not chained: `try_name` borrows from the `TargetRef`, which would otherwise
        // be a temporary dropped before the symbol it lends its bytes to is read.
        let head_target = reference.target();
        let bookmark = head_target
            .try_name()
            .and_then(|target| std::str::from_utf8(target.as_bstr()).ok())
            .and_then(|name| jj_lib::git::parse_git_ref(GitRefName::new(name)))
            .and_then(|(kind, symbol)| matches!(kind, GitRefKind::Bookmark).then_some(symbol));
        if let Some(symbol) = bookmark {
            // TODO(upstream): the CLI assumes the symbolic target names the same remote.
            let alias = symbol.name.to_remote_symbol(RemoteName::new(remote)).to_string();
            let file = config::new_repo_config_file(workspace)
                .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
            config::set_trunk_alias(file, &alias).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        }
        return Ok(());
    }
    Ok(())
}

/// `jj git init`'s External arm over an existing `<root>/.git` (`init.rs:222-224`, `:249-282` @
/// v0.46.0; Story 9.20): [`convert_into`]'s steps with their report — the snapshot report and the
/// warnings, and the `.jj` it created. Like the conversions, it cleans up nothing beyond jj-lib's
/// own `.jj` removal, as `jj git init` does. `root` is canonical and `settings` are the new
/// workspace's.
pub(crate) fn init_over_git_dir(settings: &UserSettings, root: &Path) -> OverGitDir {
    let mut report = ConversionReport::default();
    let result = convert_into(settings, root, &mut report);
    OverGitDir {
        result,
        precondition: report.precondition,
        warnings: report.warnings.take(),
        jj_dir: report.created.jj_dir,
        trackable_remote_bookmarks: report.trackable_remote_bookmarks,
    }
}

/// [`init_over_git_dir`]'s outcome, for `Repo::init` to report.
pub(crate) struct OverGitDir {
    /// The External flow's result.
    pub(crate) result: Result<(), RepoError>,
    /// `maybe_snapshot`'s report — `Some` from the moment it starts.
    pub(crate) precondition: Option<crate::Precondition>,
    /// The flow's warnings, in the CLI's print order.
    pub(crate) warnings: Vec<crate::Warning>,
    /// `<root>/.jj` once `init_external_git` returned `Ok` (Story 9.58).
    pub(crate) jj_dir: Option<PathBuf>,
    /// The flow's trackable remote bookmarks, set when it completes (Story 11.22).
    pub(crate) trackable_remote_bookmarks: Vec<String>,
}

/// Runs the colocated external-git init and then `do_init`'s External sequence, reporting into
/// `report`. On `Err`, what was written stays (`do_init` propagates with `?`).
fn convert_into(settings: &UserSettings, path: &Path, report: &mut ConversionReport) -> Result<(), RepoError> {
    // Open the EXISTING `.git` as the backing store (gix::open — strictly non-destructive).
    // Because `.git` is inside `path`, the workspace is colocated. This is what
    // `jj git init --colocate` does for an existing repo (cli/src/commands/git/init.rs @
    // v0.46.0 -> GitInitMode::External).
    let git_repo_path = path.join(".git");
    let (mut workspace, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
        settings,
        path,
        WorkspaceName::DEFAULT,
        &git_repo_path,
    ))
    .map_err(|e| creation_error(&e, |reason| RepoError::ConvertFailed { reason }))?;
    report.created.jj_dir = Some(path.join(".jj"));
    external_arm(&mut workspace, &repo, report)
}

/// Ports `do_init`'s `GitInitMode::External` branch (`init.rs:212-221`, `:249-282` @ v0.46.0),
/// non-colocated in the intended two-path use. Creates and populates the jj workspace at
/// `workspace_path`, reporting into `report`. On `Err`, what was written stays (`do_init` propagates with `?`).
fn import_into(git_repo_path: &Path, workspace_path: &Path, report: &mut ConversionReport) -> Result<(), RepoError> {
    // The CLI's destination step (`cli/src/commands/git/init.rs:161-163` @ v0.46.0): ONE level
    // created or reused, then canonicalized — here and not at the entry point, because the
    // destination may legitimately not exist yet. A destination this call created is recorded
    // from the creation's own result.
    let workspace_path =
        create_destination(workspace_path, &mut report.created).map_err(|e| RepoError::ConvertFailed {
            reason: failed_to_create_workspace(e),
        })?;
    // The settings are resolved for the canonical destination, AFTER it exists — the CLI's
    // order (start-up check → create the destination → canonicalize →
    // `settings_for_new_workspace`); only a fault that needs the destination's paths is left
    // for here, and the directory stays, as in the CLI.
    let settings = config::user_settings_for_new_workspace(&workspace_path, GIT_INIT)?;

    let resolved = resolve_git_repo_path(git_repo_path);

    // Open the existing repo as the backing store (gix::open — non-destructive).
    let (mut workspace, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
        &settings,
        &workspace_path,
        WorkspaceName::DEFAULT,
        &resolved,
    ))
    .map_err(|e| creation_error(&e, |reason| RepoError::ConvertFailed { reason }))?;
    report.created.jj_dir = Some(workspace_path.join(".jj"));
    external_arm(&mut workspace, &repo, report)
}

/// The CLI's External-arm steps after `init_external_git`, in its order (`init.rs:249-282` @
/// v0.46.0): refs op, the start-up environment (`for_workable_repo`), `.jj/.gitignore`,
/// `maybe_snapshot`, the `trunk()` alias, — non-colocated only — the head op, and — colocated
/// in a LINKED git worktree only — the `jj.colocated_in_git_worktree` warning. Colocation is read
/// with the CLI's own check rather than assumed: it is normally true for [`convert_colocated`]
/// and false for [`convert_import`], but a linked git worktree (`.git` a gitdir POINTER file)
/// reaches `convert_colocated` too — since jj 0.45 the CLI creates the repo there and warns
/// instead of refusing — and `workspace_path == git_repo_path` (D5) is a colocated request
/// `convert_import` honours.
///
/// Every step reports into `report` as it runs (Story 9.33), so a failure keeps what came
/// before it: the refs step's warnings, the start-up environment's warnings (recorded where the
/// CLI's `for_workable_repo` prints them, `init.rs:257`), `maybe_snapshot`'s report and
/// warnings — PARTIAL when a later snapshot step fails after an earlier one committed — and —
/// non-colocated only — the head import's finish.
fn external_arm(
    workspace: &mut Workspace,
    repo: &Arc<ReadonlyRepo>,
    report: &mut ConversionReport,
) -> Result<(), RepoError> {
    let colocated = is_colocated_git_workspace(workspace).map_err(convert_failed)?;
    let config = config::load_for_workspace(workspace, GIT_INIT)?;
    let repo = init_git_refs(
        repo,
        workspace.workspace_name(),
        colocated,
        &config,
        &mut report.warnings,
    )?;
    let env = snapshot::CommandEnv::load(workspace, &config, &mut report.warnings).map_err(precondition_error)?;
    maybe_add_gitignore(workspace.workspace_root(), colocated)
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    let repo = maybe_snapshot(workspace, repo, (&config, &env), colocated, report)?;
    maybe_set_trunk_alias(workspace, repo.as_ref())?;
    // The head import below moves `@` only, never a bookmark or its tracking, so the list read
    // here is the one the CLI prints after it.
    let trackable = trackable_remote_bookmarks(repo.view());
    if colocated {
        let git_repo = jj_lib::git::get_git_repo(workspace.repo_loader().store()).map_err(convert_failed)?;
        if git_repo.kind() == gix::repository::Kind::LinkedWorkTree {
            report
                .warnings
                .push(WarningKind::ColocatedInGitWorktree, COLOCATED_IN_GIT_WORKTREE);
        }
    } else {
        import_head_into_destination(workspace, &repo, &env, &mut report.warnings)?;
    }
    report.trackable_remote_bookmarks = trackable;
    Ok(())
}

/// The CLI's `print_trackable_remote_bookmarks` list (`init.rs:391-421` @ v0.47.0, Story 11.22):
/// for every bookmark with a local target, its untracked remote refs, in the view's order, as
/// `<name>@<remote>` symbols.
fn trackable_remote_bookmarks(view: &jj_lib::view::View) -> Vec<String> {
    view.bookmarks()
        .filter(|(_, target)| target.local_target.is_present())
        .flat_map(|(name, target)| {
            target
                .remote_refs
                .into_iter()
                .filter(|&(_, remote_ref)| !remote_ref.is_tracked())
                .map(move |(remote, _)| name.to_remote_symbol(remote).to_string())
        })
        .collect()
}

/// The CLI's warning for a colocated repo created inside a linked git worktree (`init.rs:272-281`
/// @ v0.46.0), minus its hint.
const COLOCATED_IN_GIT_WORKTREE: &str = "Initialized a new colocated jj repo inside a Git worktree.";

/// The CLI's non-colocated head import (`init.rs:262-270` @ v0.46.0): import the HEAD commit,
/// check `@` out onto it, and — only when something changed — finish the transaction like
/// `tx.finish(ui, "import git head")` (`cli_util.rs:2849-2866`, `:2986-3002`): resolve the
/// immutable set against `tx.base_repo()` — an unresolvable `immutable_heads()` refuses as
/// [`RepoError::Config`] with no operation written — rebase the mutable descendants, then take the
/// Git import/export lock and finish; the finish's working-copy update materialises HEAD's tree
/// in the destination. Since jj 0.45 this records NO git head in the view (`import_head_commit`,
/// not `import_head`): a non-colocated workspace does not track Git HEAD. Skipped when HEAD is
/// unborn (a fresh `git init` with no commits): then nothing changed, no `@` is created, and
/// no operation is written.
fn import_head_into_destination(
    workspace: &mut Workspace,
    repo: &Arc<ReadonlyRepo>,
    env: &snapshot::CommandEnv,
    sink: &mut Warnings,
) -> Result<(), RepoError> {
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(repo, &workspace_name);
    if let Some(commit) = pollster::block_on(jj_lib::git::import_head_commit(tx.repo_mut())).map_err(convert_failed)? {
        pollster::block_on(tx.repo_mut().check_out(workspace_name, &commit)).map_err(convert_failed)?;
    }
    if !tx.repo().has_changes() {
        return Ok(());
    }
    let immutable = resolve_immutable(tx.base_repo().as_ref(), &env.immutable).map_err(finish_error)?;
    pollster::block_on(
        tx.repo_mut()
            .rebase_descendants_with_options(&immutable, &RebaseOptions::default(), |_, _| {}),
    )
    .map_err(convert_failed)?;
    let lock = snapshot::lock_git_import_export(workspace, false).map_err(convert_failed)?;
    let ctx = mutate::FinishCtx {
        immutable: &env.immutable,
        colocated: false,
        _lock: &lock,
    };
    mutate::finish_transaction(workspace, tx, "import git head", &ctx, sink).map_err(finish_error)?;
    Ok(())
}

/// A failure of the head import's finish: an unresolvable `immutable_heads()` is the CLI's config
/// error, everything else fails the conversion.
fn finish_error(e: MutateError) -> RepoError {
    match e {
        MutateError::Config { reason } => RepoError::Config { reason },
        other => convert_failed(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shared test settings, with the suite's identity pinned first.
    fn settings() -> UserSettings {
        test_helpers::pin_test_env();
        test_helpers::test_settings()
    }

    #[test]
    fn is_colocated_with_simple_backend_returns_false() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let settings = settings();
        let (ws, _repo) = pollster::block_on(jj_lib::workspace::Workspace::init_simple(
            &settings,
            tmp.path(),
            WorkspaceName::DEFAULT,
        ))
        .expect("init_simple");
        assert!(!is_colocated_git_workspace(&ws).expect("open"));
    }

    /// The alias reader needs a GIT backend; on anything else `get_git_repo` refuses and the
    /// refusal is forwarded rather than swallowed. Unreachable from either verb (both go
    /// through `init_external_git`), so it is pinned here on the same `init_simple`
    /// workspace its sibling above uses.
    #[test]
    fn maybe_set_trunk_alias_with_simple_backend_is_a_convert_failure() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let settings = settings();
        let (ws, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_simple(
            &settings,
            tmp.path(),
            WorkspaceName::DEFAULT,
        ))
        .expect("init_simple");
        let result = maybe_set_trunk_alias(&ws, repo.as_ref());
        assert!(
            matches!(result, Err(RepoError::ConvertFailed { .. })),
            "a non-git backend must surface as ConvertFailed, got: {result:?}"
        );
    }

    #[test]
    fn is_colocated_with_colocated_workspace_returns_true() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        // Canonicalize so path comparison matches what gix reports for work_dir.
        let root = tmp.path().canonicalize().expect("canonicalize");
        let settings = settings();
        std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(&root)
            .env("GIT_CONFIG_GLOBAL", "")
            .status()
            .expect("git init");
        let git_dir = root.join(".git");
        let (ws, _repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
            &settings,
            &root,
            WorkspaceName::DEFAULT,
            &git_dir,
        ))
        .expect("init_external_git");
        assert!(is_colocated_git_workspace(&ws).expect("open"));
    }

    /// A config fault inside the conversion's snapshot stays a config fault; anything else fails
    /// the conversion.
    #[test]
    fn precondition_failures_map_onto_the_repo_error_taxonomy() {
        assert!(matches!(
            precondition_error(crate::PreconditionError::Config { reason: "k".to_owned() }),
            RepoError::Config { reason } if reason == "k"
        ));
        assert!(matches!(
            precondition_error(crate::PreconditionError::Backend("b".to_owned())),
            RepoError::ConvertFailed { reason } if reason.contains('b')
        ));
        // Every other failure inside the snapshot/head-import plumbing fails the conversion.
        assert!(matches!(
            convert_failed("lock"),
            RepoError::ConvertFailed { reason } if reason == "lock"
        ));
    }

    /// Story 9.57: the head import's finish refuses an unresolvable `immutable_heads()` as the
    /// CLI's config error; anything else fails the conversion.
    #[test]
    fn head_import_finish_failures_map_onto_the_repo_error_taxonomy() {
        assert!(matches!(
            finish_error(MutateError::Config { reason: "alias".to_owned() }),
            RepoError::Config { reason } if reason == "alias"
        ));
        assert!(matches!(
            finish_error(MutateError::Backend("b".to_owned())),
            RepoError::ConvertFailed { reason } if reason.contains('b')
        ));
    }

    /// Story 9.57: only what is still on disk is reported, in the given order; a dangling
    /// symlink is on disk.
    #[test]
    fn still_present_keeps_what_exists_in_order() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let root = tmp.path();
        std::fs::create_dir(root.join("dir")).expect("mkdir");
        std::os::unix::fs::symlink(root.join("nowhere"), root.join("dangling")).expect("symlink");
        let present = still_present([root.join("dir"), root.join("missing"), root.join("dangling")]);
        assert_eq!(present, [root.join("dir"), root.join("dangling")]);
    }

    /// The state [`external_arm`] starts from: a colocated `init_external_git` over a fresh
    /// `git init` in `root`, with `repo_config` as its repo-level config — the legacy
    /// `.jj/repo/config.toml`, which is read while no `config-id` exists.
    fn external_workspace(root: &Path, repo_config: &str) -> (Workspace, Arc<ReadonlyRepo>) {
        let settings = settings();
        let status = std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(root)
            .env("GIT_CONFIG_GLOBAL", "")
            .status()
            .expect("git spawns");
        assert!(status.success(), "git init");
        let fixture = pollster::block_on(Workspace::init_external_git(
            &settings,
            root,
            WorkspaceName::DEFAULT,
            &root.join(".git"),
        ))
        .expect("init_external_git");
        std::fs::write(root.join(".jj").join("repo").join("config.toml"), repo_config).expect("repo config");
        fixture
    }

    /// Story 9.34: the start-up environment is built where the CLI's `for_workable_repo` builds
    /// it, BEFORE `maybe_add_gitignore` (`git/init.rs:257-259` @ v0.46.0) — so a bad
    /// `immutable_heads()` alias refuses before `.jj/.gitignore` is written.
    #[test]
    fn a_start_up_refusal_comes_before_the_gitignore_write() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let root = tmp.path().canonicalize().expect("canonicalize");
        let (mut workspace, repo) =
            external_workspace(&root, "[revset-aliases]\n'immutable_heads()' = 'bogus_function()'\n");
        let mut report = ConversionReport::default();

        let result = external_arm(&mut workspace, &repo, &mut report);

        assert!(
            matches!(
                &result,
                Err(RepoError::Config { reason })
                    if reason.starts_with("Invalid `revset-aliases.immutable_heads()`: ")
                        && reason.contains("bogus_function")
            ),
            "{result:?}"
        );
        assert!(
            !root.join(".jj").join(".gitignore").exists(),
            "the start-up refusal comes before the .gitignore write"
        );
        assert!(report.precondition.is_none(), "the snapshot never started");
    }

    /// Story 9.34, the double fault "`.jj/.gitignore` cannot be written AND a `[revset-aliases]`
    /// entry is bad": the alias table loads first, as in the CLI, so the failed conversion still
    /// carries the alias warning the CLI prints before that failure.
    #[test]
    fn a_failed_gitignore_write_keeps_the_start_up_warnings() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let root = tmp.path().canonicalize().expect("canonicalize");
        let (mut workspace, repo) = external_workspace(&root, "[revset-aliases]\n'bad(' = 'x'\n");
        // A directory in its place makes the `.gitignore` write fail.
        std::fs::create_dir(root.join(".jj").join(".gitignore")).expect("block the .gitignore write");
        let mut report = ConversionReport::default();

        let result = external_arm(&mut workspace, &repo, &mut report);

        assert!(matches!(result, Err(RepoError::ConvertFailed { .. })), "{result:?}");
        let warnings = report.warnings.take();
        let kinds: Vec<crate::WarningKind> = warnings.iter().map(|w| w.kind).collect();
        assert_eq!(kinds, [crate::WarningKind::ConfigAliasInvalid]);
        let prefix = "Failed to load `revset-aliases.bad(`:";
        assert_eq!(warnings[0].message.get(..prefix.len()), Some(prefix));
        assert!(report.precondition.is_none(), "the snapshot never started");
    }
}
