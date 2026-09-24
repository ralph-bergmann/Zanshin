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
//! Both port `do_init`'s `GitInitMode::External` arm (`cli/src/commands/git/init.rs:244-272`
//! @ v0.44.0), so a repo Zanshin converts is on-disk indistinguishable from one `jj git init`
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
//! moved, no working-tree file is written or deleted, and the rollback below never deletes or
//! rewrites `.git/`.
//!
//! One deliberate departure, documented at its site: a failed conversion rolls back further
//! than the CLI does, which never undoes a partial `jj git init`.
//!
//! ## What both verbs report (Story 9.33)
//!
//! Both return a [`CreationOutcome`]. Its warnings are every `ui.warning_*` the CLI reaches on
//! the steps above, in the CLI's print order:
//!
//! 1. `jj.git_import_failed` — refs the `import git refs` step could not read (`init.rs:304`),
//!    reported even when the step then writes no operation;
//! 2. colocated only: `jj.git_export_failed` — refs that step's export could not write
//!    (`init.rs:311-312`);
//! 3. the config-load warnings (alias tables, builtin redefinitions, `immutable_heads()`
//!    diagnostics) the CLI prints while building the workspace command (`cli_util.rs:936-966`);
//! 4. the implicit snapshot's own warnings, as every verb's precondition reports them — its
//!    colocated refs import reports an unreadable ref a SECOND time, as the CLI does;
//! 5. on the snapshot's success: `jj.snapshot_files_refused` / `jj.snapshot_paths_not_utf8`
//!    (`cli_util.rs:1340`);
//! 6. non-colocated only: the `import git head` finish — `jj.working_copy_immutable` (the new
//!    `@` became immutable), `jj.checkout_files_skipped` and `jj.identity_missing`.
//!
//! The raw commits (`import git refs`, the colocated `import git head`, `snapshot working copy`)
//! run no identity check, exactly as in the CLI; only a finish does. The snapshot's report is
//! [`CreationOutcome::precondition`], `Some` iff the snapshot started. A failure keeps
//! everything reported before it — when the failure came before the re-open, even though the
//! rollback then removes the state it describes; a failed re-open (or, in the FFI, a failed
//! watcher arming) leaves `.jj/` in place.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::config::StackedConfig;
use jj_lib::git::{import_refs, GitImportOptions, GitRefKind};
use jj_lib::ref_name::{GitRefName, RemoteName, WorkspaceName};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;

use crate::op_support::start_repo_transaction;
use crate::repo::{creation_error, CreationOutcome};
use crate::warning::{self, Warnings};
use crate::wc_ops::is_colocated_git_workspace;
use crate::{config, detect_repo, mutate, snapshot, Repo, RepoError, RepoKind};

/// What a conversion reports beside its result (Story 9.33), filled as the steps run so a
/// failure keeps what came before it.
#[derive(Default)]
struct ConversionReport {
    /// `maybe_snapshot`'s report — `Some` from the moment it starts.
    precondition: Option<crate::Precondition>,
    /// The conversion's warnings, in the CLI's print order.
    warnings: Warnings,
}

impl ConversionReport {
    /// The verb's outcome: `result` with everything reported on the way to it.
    fn into_outcome(mut self, result: Result<Repo, RepoError>) -> CreationOutcome {
        CreationOutcome {
            result,
            precondition: self.precondition,
            warnings: self.warnings.take(),
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
/// One deliberate departure from the CLI: a failure rolls back further than the CLI, which
/// leaves a partially converted repo in place. Rollback removes `.jj/` only — it never deletes
/// or rewrites `.git/` — so a conversion that fails *after* the alias step can orphan the
/// secure-config directory it created.
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
///   conversion; the partially-created `.jj/` is rolled back.
/// - [`RepoError::Config`] — the jj config stack the workspace would be created with (resolved
///   for its own paths, as the CLI's `settings_for_new_workspace`) cannot be read; refused
///   before anything is written. A fault of the user-level stack is checked first, as the
///   CLI's start-up does, so it wins over every other error above. The converted workspace is
///   then opened as by [`Repo::open`], whose errors apply too.
#[must_use = "the outcome carries the result, the snapshot report and the warnings"]
pub fn convert_colocated(path: &Path) -> CreationOutcome {
    let mut report = ConversionReport::default();
    let result = convert_colocated_steps(path, &mut report);
    report.into_outcome(result)
}

/// [`convert_colocated`]'s steps, reporting into `report`.
fn convert_colocated_steps(path: &Path, report: &mut ConversionReport) -> Result<Repo, RepoError> {
    // The CLI's start-up config check runs before the command touches any path.
    config::check_startup_stack()?;
    match detect_repo(path) {
        Ok(RepoKind::Jj) => return Err(RepoError::AlreadyJjRepo { path: path.to_owned() }),
        Ok(RepoKind::Git) => {}
        Ok(RepoKind::Neither | RepoKind::PathNotFound) => return Err(RepoError::NotAGitRepo { path: path.to_owned() }),
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }

    // WHY canonicalize: `convert_into` reaches jj-lib's `init_with_factories`, which records the
    // new workspace's root in the store RELATIVE to the RAW path it was handed. `relative_path`
    // counts those `..` segments lexically, while every read finishes its join with
    // `std::fs::canonicalize` — `realpath(3)`, which resolves the symlinked prefix BEFORE the
    // `..` — so a record written against a symlinked caller path (macOS `/var/folders/…`)
    // resolves from NO base at all and the converted workspace cannot report its own root. This
    // was already broken before the canonicalize; it is a fix, not the preservation of a working
    // case. The failure answer mirrors the `PathNotFound` arm above, keeping the caller's
    // spelling in the payload.
    let root = std::fs::canonicalize(path).map_err(|_| RepoError::NotAGitRepo { path: path.to_owned() })?;
    // Resolved for the new workspace's own paths — the CLI's `settings_for_new_workspace`.
    let settings = config::user_settings_for_new_workspace(&root)?;
    match convert_into(&settings, &root, report) {
        Ok(()) => Repo::open(&root),
        Err(e) => {
            // Roll back only what convert created: the `.jj/` dir. Never touch `.git/`.
            let _ = std::fs::remove_dir_all(root.join(".jj"));
            Err(e)
        }
    }
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
/// A failure rolls back further than the CLI, which leaves a partially initialised repo in
/// place: the destination (or just its `.jj/`, when the directory already existed) is
/// removed, the source is never touched, and a failure *after* the alias step can orphan the
/// secure-config directory it created.
///
/// # Warnings and the snapshot report
///
/// As for [`convert_colocated`] (see the module doc's "What both verbs report"); the
/// non-colocated shape adds the head import's finish — `jj.working_copy_immutable` (the new `@`
/// became immutable), `jj.checkout_files_skipped` and the ONE `jj.identity_missing` a conversion
/// with an empty identity reports.
///
/// # Errors
///
/// In [`CreationOutcome::result`]:
/// - [`RepoError::AlreadyJjRepo`] — `workspace_path` (or `git_repo_path`) is
///   already a jj workspace.
/// - [`RepoError::NotAGitRepo`] — `git_repo_path` is not a Git repo (normal or
///   bare) or does not exist.
/// - [`RepoError::ConvertFailed`] — a jj-lib, config-write or `detect_repo` I/O error, or
///   `workspace_path` cannot be created or resolved; the partially-created destination is
///   rolled back.
/// - [`RepoError::Config`] — as for [`convert_colocated`]: a user-level fault refuses first,
///   before the destination is created; a fault that needs the destination's own paths (a
///   scoped table) surfaces once the destination exists (the CLI's order), so a destination
///   created for the call is rolled back with it.
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
    config::check_startup_stack()?;
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

    let created_dir = !workspace_path.exists();
    match import_into(git_repo_path, workspace_path, report) {
        Ok(()) => Repo::open(workspace_path),
        Err(e) => {
            if created_dir {
                let _ = std::fs::remove_dir_all(workspace_path);
            } else {
                let _ = std::fs::remove_dir_all(workspace_path.join(".jj"));
            }
            Err(e)
        }
    }
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

/// Ports `init_git_refs` (`cli/src/commands/git/init.rs:285-320` @ v0.44.0): one transaction
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

/// Ports `maybe_add_gitignore` (`cli/src/commands/git/mod.rs:110-123` @ v0.44.0): the literal
/// `/*\n` into `<workspace_root>/.jj/.gitignore`, and ONLY when the working copy is shared
/// with git.
///
/// It does NOT touch the workspace's own `.gitignore` — the file it writes lives inside
/// `.jj/` and hides that directory from the colocated git repo.
fn maybe_add_gitignore(workspace_root: &Path, colocated: bool) -> Result<(), RepoError> {
    if !colocated {
        return Ok(());
    }
    std::fs::write(workspace_root.join(".jj").join(".gitignore"), "/*\n")
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })
}

/// `do_init`'s `workspace_command.maybe_snapshot(ui)` (`cli/src/cli_util.rs:1331-1342` @
/// v0.44.0): the implicit snapshot every verb runs first ([`crate::snapshot::snapshot_locked`]),
/// under the Git import/export lock, on the repo the refs step left behind.
///
/// Its report is `report.precondition` — `Some` from the moment this starts, PARTIAL when a step
/// fails, `was_snapshot_taken` computed as the verb precondition computes it — and its warnings
/// land in `report.warnings`: the snapshot's own, then, on success only, the snapshot stats
/// (`print_snapshot_stats`, printed after `snapshot_impl`).
fn maybe_snapshot(
    workspace: &mut Workspace,
    repo: Arc<ReadonlyRepo>,
    (config, knobs): (&StackedConfig, &snapshot::Knobs),
    colocated: bool,
    report: &mut ConversionReport,
) -> Result<Arc<ReadonlyRepo>, RepoError> {
    let precondition = report.precondition.insert(crate::Precondition::default());
    let lock = snapshot::lock_git_import_export(workspace, colocated).map_err(convert_failed)?;
    let ctx = snapshot::StepCtx {
        config,
        knobs,
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
/// fails the conversion (and rolls it back).
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

/// Ports `maybe_set_repository_level_trunk_alias` (`cli/src/commands/git/init.rs:324-364` @
/// v0.44.0): `revset-aliases.'trunk()' = '<bookmark>@<remote>'` in the REPO-level config.
///
/// `upstream` is tried first, then `origin`, and the loop stops at the first remote that HAS
/// a `refs/remotes/<remote>/HEAD` reference **whether or not it parses** — the CLI's own
/// comment is that it makes no sense to fall back to `origin` once `upstream` is known to
/// exist. The alias is written only when that reference's symbolic target parses as a
/// [`GitRefKind::Bookmark`]; a direct (non-symbolic) `HEAD` has no symbolic target, so it
/// yields no alias and no config file.
///
/// At v0.44.0 there is NO `get_single_remote` guard on this — a repo with several remotes
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

/// Runs the colocated external-git init and then `do_init`'s External sequence, reporting into
/// `report`. On `Err`, the caller rolls back `.jj/`.
fn convert_into(settings: &UserSettings, path: &Path, report: &mut ConversionReport) -> Result<(), RepoError> {
    // Open the EXISTING `.git` as the backing store (gix::open — strictly non-destructive).
    // Because `.git` is inside `path`, the workspace is colocated. This is what
    // `jj git init --colocate` does for an existing repo (cli/src/commands/git/init.rs @
    // v0.44.0 -> GitInitMode::External).
    let git_repo_path = path.join(".git");
    let (mut workspace, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
        settings,
        path,
        &git_repo_path,
    ))
    .map_err(|e| creation_error(&e, |reason| RepoError::ConvertFailed { reason }))?;
    external_arm(&mut workspace, &repo, report)
}

/// Ports `do_init`'s `GitInitMode::External` branch (jj CLI @ v0.44.0), non-colocated in the
/// intended two-path use. Creates and populates the jj workspace at `workspace_path`, reporting
/// into `report`. On `Err`, the caller rolls back the destination.
fn import_into(git_repo_path: &Path, workspace_path: &Path, report: &mut ConversionReport) -> Result<(), RepoError> {
    std::fs::create_dir_all(workspace_path).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    // WHY here and not at the entry point: the destination may legitimately not exist yet, so the
    // canonicalize has to follow the directory creation. It has to happen at all because
    // `init_external_git` records the workspace root in the store RELATIVE to this path while
    // every read joins onto the canonical `Workspace::repo_path()` — see `Repo::open`.
    let workspace_path =
        std::fs::canonicalize(workspace_path).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    // The settings are resolved for the canonical destination, AFTER it exists — the CLI's
    // order (start-up check → create the destination → canonicalize →
    // `settings_for_new_workspace`); only a fault that needs the destination's paths is left
    // for here, and it is rolled back with the directory. (The CLI's `create_or_reuse_dir`
    // creates ONE level; `create_dir_all` is the bridge's documented liberalization.)
    let settings = config::user_settings_for_new_workspace(&workspace_path)?;

    let resolved = resolve_git_repo_path(git_repo_path);

    // Open the existing repo as the backing store (gix::open — non-destructive).
    let (mut workspace, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
        &settings,
        &workspace_path,
        &resolved,
    ))
    .map_err(|e| creation_error(&e, |reason| RepoError::ConvertFailed { reason }))?;
    external_arm(&mut workspace, &repo, report)
}

/// The CLI's External-arm steps after `init_external_git`, in its order: refs op,
/// `.jj/.gitignore`, `maybe_snapshot`, the `trunk()` alias, and — non-colocated only — the head
/// op. Colocation is read with the CLI's own check rather than assumed: it is normally true for
/// [`convert_colocated`] and false for [`convert_import`], but a linked git worktree (`.git` a
/// gitdir POINTER file) reaches `convert_colocated` too, and `workspace_path == git_repo_path`
/// (D5) is a colocated request `convert_import` honours.
///
/// Every step reports into `report` as it runs (Story 9.33), so a failure keeps what came
/// before it: the refs step's warnings, the config-load warnings `Knobs::read` records where the
/// CLI's `for_workable_repo` prints them, `maybe_snapshot`'s report and warnings, and — non-
/// colocated only — the head import's finish.
fn external_arm(
    workspace: &mut Workspace,
    repo: &Arc<ReadonlyRepo>,
    report: &mut ConversionReport,
) -> Result<(), RepoError> {
    let colocated = is_colocated_git_workspace(workspace);
    let config = config::load_for_workspace(workspace)?;
    let repo = init_git_refs(
        repo,
        workspace.workspace_name(),
        colocated,
        &config,
        &mut report.warnings,
    )?;
    maybe_add_gitignore(workspace.workspace_root(), colocated)?;
    let knobs = snapshot::Knobs::read(workspace, &config, &mut report.warnings).map_err(precondition_error)?;
    let repo = maybe_snapshot(workspace, repo, (&config, &knobs), colocated, report)?;
    maybe_set_trunk_alias(workspace, repo.as_ref())?;
    if colocated {
        return Ok(());
    }
    import_head_into_destination(workspace, &repo, &knobs, &mut report.warnings)
}

/// The CLI's non-colocated head import (`init.rs:260-270`): import HEAD, check `@` out onto the
/// imported commit, and — only when something changed — finish the transaction like
/// `tx.finish(ui, "import git head")`, whose working-copy update materialises HEAD's tree in
/// the destination. Skipped when HEAD is unborn (a fresh `git init` with no commits): then
/// `import_head` changed nothing, no `@` is created, and no operation is written.
fn import_head_into_destination(
    workspace: &mut Workspace,
    repo: &Arc<ReadonlyRepo>,
    knobs: &snapshot::Knobs,
    sink: &mut Warnings,
) -> Result<(), RepoError> {
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(repo, &workspace_name);
    pollster::block_on(jj_lib::git::import_head(tx.repo_mut())).map_err(convert_failed)?;
    if let Some(git_head_id) = tx.repo().view().git_head().as_normal().cloned() {
        let mut_repo = tx.repo_mut();
        let commit = mut_repo.store().get_commit(&git_head_id).map_err(convert_failed)?;
        pollster::block_on(mut_repo.check_out(workspace_name, &commit)).map_err(convert_failed)?;
        pollster::block_on(mut_repo.rebase_descendants()).map_err(convert_failed)?;
    }
    if !tx.repo().has_changes() {
        return Ok(());
    }
    let lock = snapshot::lock_git_import_export(workspace, false).map_err(convert_failed)?;
    let ctx = mutate::FinishCtx {
        immutable: &knobs.immutable,
        colocated: false,
        _lock: &lock,
    };
    mutate::finish_transaction(workspace, tx, "import git head", &ctx, sink).map_err(convert_failed)?;
    Ok(())
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
        let (ws, _repo) =
            pollster::block_on(jj_lib::workspace::Workspace::init_simple(&settings, tmp.path())).expect("init_simple");
        assert!(!is_colocated_git_workspace(&ws));
    }

    /// The alias reader needs a GIT backend; on anything else `get_git_repo` refuses and the
    /// refusal is forwarded rather than swallowed. Unreachable from either verb (both go
    /// through `init_external_git`), so it is pinned here on the same `init_simple`
    /// workspace its sibling above uses.
    #[test]
    fn maybe_set_trunk_alias_with_simple_backend_is_a_convert_failure() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let settings = settings();
        let (ws, repo) =
            pollster::block_on(jj_lib::workspace::Workspace::init_simple(&settings, tmp.path())).expect("init_simple");
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
            &settings, &root, &git_dir,
        ))
        .expect("init_external_git");
        assert!(is_colocated_git_workspace(&ws));
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
}
