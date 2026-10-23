// SPDX-License-Identifier: MIT

//! `jj git init` and `jj git clone` at v0.46.0, step for step (Story 9.20) — the bodies of
//! [`crate::Repo::init`] and [`crate::Repo::clone`].
//!
//! Ported anchors (`cli/src/commands/git/` @ v0.46.0): `init.rs:146-288` (`cmd_git_init`,
//! `do_init`), `clone.rs:170-460` (`cmd_git_clone`, `init_workspace`, `configure_remote`,
//! `fetch_new_remote`) and `mod.rs:110-193` (`maybe_add_gitignore`, `write_repo_presets`). What the
//! CLI does on disk and in the op log is reproduced; its terminal output is not (the status lines,
//! the progress bar) — progress reaches the caller's [`ProgressFn`] instead.
//!
//! Divergences, all deliberate:
//! - no `--git-repo` arm (the `convert_*` verbs own the external flows), no `--at-op`,
//!   `--ignore-working-copy` or `--no-integrate-operation` (no Zanshin counterpart);
//! - the clone destination is never guessed from the source (the caller passes it) and the
//!   source URL is passed to git as given (`absolute_git_url` is terminal-cwd UX).

use std::io;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::config::StackedConfig;
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::file_util;
use jj_lib::git::{
    expand_fetch_refspecs, GitFetch, GitFetchError, GitFetchRefExpression, GitImportOptions, GitRemoteManagementError,
};
use jj_lib::ref_name::{RefName, RefNameBuf, RemoteName, RemoteNameBuf};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::rewrite::RebaseOptions;
use jj_lib::settings::UserSettings;
use jj_lib::str_util::StringExpression;
use jj_lib::transaction::Transaction;
use jj_lib::workspace::{Workspace, WorkspaceInitError};

use crate::cancel::CancelGuard;
use crate::op_support::start_repo_transaction;
use crate::remotes::ProgressCallback;
use crate::repo::{creation_error, CreationOutcome};
use crate::warning::{self, WarningKind, Warnings};
use crate::{config, mutate, snapshot, Backend, MutateError, ProgressFn, Repo, RepoError};

/// The object hash of a new Git repository — the CLI's `--object-hash`, whose default is the
/// `git.object-hash` config (Story 9.20).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ObjectHash {
    /// SHA-1, Git's classic format (the builtin `git.object-hash`).
    Sha1,
    /// SHA-256.
    Sha256,
}

/// `jj git init`'s parameters (Story 9.20) — every CLI flag Zanshin has a counterpart for,
/// passed through (FR-JJ-17).
#[derive(Debug, Clone, Default)]
pub struct InitOptions {
    /// The destination — the CLI's `DESTINATION`. It is created when missing (one level, the
    /// CLI's `create_or_reuse_dir`); a relative path resolves against the process's current
    /// directory, as the CLI's `cwd.join` does.
    pub path: PathBuf,
    /// `Some(Backend::Git)` is `jj git init`; `None` creates a workspace on jj's native backend
    /// (Zanshin-only, unchanged: the destination must exist and no Git flag applies).
    pub backend: Option<Backend>,
    /// The CLI's `--colocate` (`Some(true)`) / `--no-colocate` (`Some(false)`); `None` = neither,
    /// the `git.colocate` config decides.
    pub colocate: Option<bool>,
    /// The CLI's `--object-hash`; `None` = the `git.object-hash` config.
    pub object_hash: Option<ObjectHash>,
}

/// `jj git clone`'s parameters (Story 9.20) — every CLI flag Zanshin has a counterpart for,
/// passed through (FR-JJ-17).
#[derive(Debug, Clone, Default)]
pub struct CloneOptions {
    /// The URL or path of the Git repository to clone — the CLI's `SOURCE`, handed to `git`
    /// as given.
    pub source: String,
    /// The destination — the CLI's `DESTINATION` (never guessed from the source here). It must
    /// be missing or an empty directory; a missing one is created with its parents.
    pub destination: PathBuf,
    /// The CLI's `--remote`; `None` = `origin`.
    pub remote_name: Option<String>,
    /// The CLI's `--colocate` (`Some(true)`) / `--no-colocate` (`Some(false)`); `None` = neither,
    /// the `git.colocate` config decides.
    pub colocate: Option<bool>,
    /// The CLI's `--depth` (a shallow clone); `None` = the whole history.
    pub depth: Option<NonZeroU32>,
    /// The CLI's repeatable `-b/--branch` name patterns; `None` = the flag not given.
    pub branches: Option<Vec<String>>,
    /// The CLI's repeatable `-t/--tag` name patterns; `None` = the flag not given.
    pub tags: Option<Vec<String>>,
    /// The CLI's `--object-hash`; `None` = the `git.object-hash` config.
    pub object_hash: Option<ObjectHash>,
}

/// The object hash as jj-lib takes it.
fn gix_kind(hash: ObjectHash) -> gix::hash::Kind {
    match hash {
        ObjectHash::Sha1 => gix::hash::Kind::Sha1,
        ObjectHash::Sha256 => gix::hash::Kind::Sha256,
    }
}

/// The effective colocation of the CLI's two flags: `git.colocate ? !no_colocate : colocate`
/// (`init.rs:166-170`, `clone.rs:198-202` @ v0.46.0).
fn effective_colocate(config: &StackedConfig, flag: Option<bool>) -> Result<bool, RepoError> {
    Ok(if config::git_colocate(config)? {
        flag != Some(false)
    } else {
        flag == Some(true)
    })
}

/// The object hash: the flag, else `git.object-hash` (`init.rs:172-175`, `clone.rs:212-215`).
fn effective_object_hash(config: &StackedConfig, flag: Option<ObjectHash>) -> Result<ObjectHash, RepoError> {
    flag.map_or_else(|| config::git_object_hash(config).map_err(RepoError::from), Ok)
}

/// A start-up environment failure during a creation: a config fault stays one, anything else is
/// `other`.
fn env_error(e: crate::PreconditionError, other: impl FnOnce(String) -> RepoError) -> RepoError {
    match e {
        crate::PreconditionError::Config { reason } => RepoError::Config { reason },
        e => other(e.to_string()),
    }
}

/// `for_workable_repo`'s start-up environment for a freshly created or reloaded workspace — its
/// warnings recorded on their own, so a second load (clone's reload) reports them a second
/// time, as the CLI's second `for_workable_repo` prints them again.
fn workable_env(
    workspace: &Workspace,
    sink: &mut Warnings,
    other: impl Fn(String) -> RepoError,
) -> Result<(StackedConfig, snapshot::CommandEnv), RepoError> {
    let config = config::load_for_workspace(workspace)?;
    let mut own = Warnings::default();
    let env = snapshot::CommandEnv::load(workspace, &config, &mut own);
    sink.extend(own.take());
    Ok((config, env.map_err(|e| env_error(e, other))?))
}

// ── init ──────────────────────────────────────────────────────────────────────────

/// [`crate::Repo::init`]'s body: the CLI's `cmd_git_init` + `do_init` for the Git backend, the
/// unchanged native creation otherwise.
pub(crate) fn init(options: &InitOptions) -> CreationOutcome {
    let mut sink = Warnings::default();
    let mut precondition = None;
    let mut created = Created::default();
    let result = init_steps(options, &mut sink, &mut precondition, &mut created);
    let left_behind = if result.is_err() {
        created.left_behind()
    } else {
        Vec::new()
    };
    CreationOutcome {
        result,
        precondition,
        warnings: sink.take(),
        left_behind,
    }
}

/// What a creation call itself created on the way (Story 9.58), known from the creating calls'
/// own results — never from a check before them, except the new colocated `.git` (below).
#[derive(Debug, Default)]
pub(crate) struct Created {
    /// The destination this call created ([`create_or_reuse_dir`] returned `true`): canonical,
    /// spelled as the caller passed it only when canonicalizing it failed.
    pub(crate) destination: Option<PathBuf>,
    /// `<canonical root>/.jj`, once this call's jj-lib creation returned `Ok`.
    pub(crate) jj_dir: Option<PathBuf>,
    /// `<canonical root>/.git` of a NEW colocated init: jj-lib's `init_colocated_git` creates it
    /// inside the call and its own failure cleanup removes only `.jj` (`init_with_factories`
    /// @ 0.46.0), so it may stay whether that call returns `Ok` or not. Recorded before the call
    /// — the arm runs only when `.git` is absent — and listed while it exists.
    pub(crate) git_dir: Option<PathBuf>,
}

impl Created {
    /// What a failed creation left: the created destination, then the `.jj`, then a new
    /// colocated `.git` — outermost first, each only when it is still on disk.
    pub(crate) fn left_behind(&self) -> Vec<PathBuf> {
        crate::convert::still_present(
            self.destination
                .iter()
                .chain(&self.jj_dir)
                .chain(&self.git_dir)
                .cloned(),
        )
    }
}

/// jj-lib's `file_util::create_or_reuse_dir` (`file_util.rs:70-76` @ 0.46.0) — ONE level, an
/// existing directory reused — answering whether THIS call created it: `true` iff `create_dir`
/// returned `Ok`.
pub(crate) fn create_or_reuse_dir(path: &Path) -> io::Result<bool> {
    match std::fs::create_dir(path) {
        Ok(()) => Ok(true),
        Err(_) if path.is_dir() => Ok(false),
        Err(e) => Err(e),
    }
}

/// The CLI's destination step (`init.rs:161-163` @ v0.46.0): [`create_or_reuse_dir`], then
/// canonicalize. A destination this call created is recorded in `created` — canonical, or as
/// spelled when only the canonicalize failed.
pub(crate) fn create_destination(path: &Path, created: &mut Created) -> io::Result<PathBuf> {
    let made = create_or_reuse_dir(path)?;
    let canonical = std::fs::canonicalize(path);
    if made {
        created.destination = Some(canonical.as_ref().map_or_else(|_| path.to_owned(), Clone::clone));
    }
    canonical
}

/// The CLI's text for a destination that cannot be created or canonicalized —
/// `user_error_with_message("Failed to create workspace", e)` (`init.rs:162-164`).
pub(crate) fn failed_to_create_workspace(e: impl std::fmt::Display) -> String {
    format!("Failed to create workspace: {e}")
}

/// The failure of a create-or-canonicalize step of the destination, as `init`'s error.
fn init_failed(e: impl std::fmt::Display) -> RepoError {
    RepoError::InitFailed {
        reason: failed_to_create_workspace(e),
    }
}

/// A jj-lib creation failure of `init`: an existing workspace is jj-lib's `DestinationExists`
/// (`AlreadyJjRepo`), a config fault stays one, anything else is `InitFailed`.
fn init_creation_error(e: &WorkspaceInitError, root: &Path) -> RepoError {
    if matches!(e, WorkspaceInitError::DestinationExists(_)) {
        return RepoError::AlreadyJjRepo { path: root.to_owned() };
    }
    creation_error(e, |reason| RepoError::InitFailed { reason })
}

fn init_steps(
    options: &InitOptions,
    sink: &mut Warnings,
    precondition: &mut Option<crate::Precondition>,
    created: &mut Created,
) -> Result<Repo, RepoError> {
    // The CLI's start-up config check runs before the command touches any path, and its
    // `command.settings()` is what `git.colocate` / `git.object-hash` are read from.
    let startup = config::check_startup_stack(sink)?;
    let Some(Backend::Git) = options.backend else {
        return init_native(options, created);
    };
    let root = create_destination(&options.path, created).map_err(init_failed)?;
    let colocate = effective_colocate(&startup, options.colocate)?;
    let hash = gix_kind(effective_object_hash(&startup, options.object_hash)?);

    let git_dir = root.join(".git");
    if !colocate && git_dir.exists() {
        return Err(RepoError::GitRepoExists { path: root });
    }
    let settings = config::user_settings_for_new_workspace(&root)?;
    if colocate && git_dir.exists() {
        // `GitInitMode::External(.git)`: the convert-colocated steps (`init.rs:249-282`), which
        // report into the outcome — and, like `jj git init`, clean up nothing beyond jj-lib's own
        // `.jj` removal.
        // `symlink_metadata`, not `exists`: a dangling `.jj` symlink is taken too (jj-lib's
        // `create_dir` refuses it as `DestinationExists`).
        if root.join(".jj").symlink_metadata().is_ok() {
            return Err(RepoError::AlreadyJjRepo { path: root });
        }
        let external = crate::convert::init_over_git_dir(&settings, &root);
        *precondition = external.precondition;
        sink.extend(external.warnings);
        created.jj_dir = external.jj_dir;
        external.result?;
    } else if colocate {
        created.git_dir = Some(git_dir);
        let (workspace, _repo) = pollster::block_on(Workspace::init_colocated_git(&settings, &root, hash))
            .map_err(|e| init_creation_error(&e, &root))?;
        created.jj_dir = Some(root.join(".jj"));
        workable_env(&workspace, sink, |reason| RepoError::InitFailed { reason })?;
        add_gitignore(&workspace, |reason| RepoError::InitFailed { reason })?;
    } else {
        pollster::block_on(Workspace::init_internal_git(&settings, &root, hash))
            .map_err(|e| init_creation_error(&e, &root))?;
        created.jj_dir = Some(root.join(".jj"));
    }
    Repo::open(&root)
}

/// The native-backend creation, unchanged by Story 9.20: the destination must exist and the
/// Git-only flags are refused.
fn init_native(options: &InitOptions, created: &mut Created) -> Result<Repo, RepoError> {
    if options.colocate.is_some() || options.object_hash.is_some() {
        return Err(RepoError::InvalidInput {
            reason: "colocation and the object hash apply only to the Git backend".to_owned(),
        });
    }
    let root = std::fs::canonicalize(&options.path).map_err(|e| RepoError::InitFailed {
        reason: format!("{}: {e}", options.path.display()),
    })?;
    let settings = config::user_settings_for_new_workspace(&root)?;
    pollster::block_on(Workspace::init_simple(&settings, &root)).map_err(|e| init_creation_error(&e, &root))?;
    created.jj_dir = Some(root.join(".jj"));
    Repo::open(&root)
}

/// The CLI's `maybe_add_gitignore` (`mod.rs:110-123`) for a workspace: `.jj/.gitignore` = `/*`
/// when the working copy is shared with Git.
fn add_gitignore(workspace: &Workspace, other: impl Fn(String) -> RepoError) -> Result<(), RepoError> {
    let colocated = crate::wc_ops::is_colocated_git_workspace(workspace).map_err(|e| other(e.to_string()))?;
    crate::convert::maybe_add_gitignore(workspace.workspace_root(), colocated)
        .map_err(|e| other(format!("Failed to write .jj/.gitignore file: {e}")))
}

// ── clone ─────────────────────────────────────────────────────────────────────────

/// [`crate::Repo::clone`]'s body: the CLI's `cmd_git_clone`.
pub(crate) fn clone(options: &CloneOptions, progress: &ProgressFn, cancel: Option<&CancelGuard>) -> CreationOutcome {
    let mut sink = Warnings::default();
    let result = clone_steps(options, (progress, cancel), &mut sink);
    CreationOutcome {
        result,
        precondition: None,
        warnings: sink.take(),
        left_behind: Vec::new(),
    }
}

/// A clone failure.
fn clone_failed(reason: impl Into<String>) -> RepoError {
    RepoError::CloneFailed {
        reason: reason.into(),
        hints: Vec::new(),
    }
}

/// A failure of the clone's `git` subprocess (`git fetch`, `git remote show`) is a network error,
/// as in `git_fetch` — or the cancel, when it failed after `cancel`'s token was cancelled (Story
/// 9.52); any other fetch failure is a clone failure.
fn fetch_error(e: GitFetchError, cancel: Option<&CancelGuard>) -> RepoError {
    match e {
        GitFetchError::Subprocess(_) if crate::cancel::is_cancelled(cancel) => RepoError::Cancelled,
        GitFetchError::Subprocess(_) => RepoError::NetworkError {
            reason: mutate::flatten_chain(&e),
        },
        GitFetchError::RemoteName(_) => RepoError::CloneFailed {
            reason: e.to_string(),
            hints: vec![crate::remotes::REMOTE_RENAME_HINT.to_owned()],
        },
        other => clone_failed(other.to_string()),
    }
}

/// A remote name jj refuses (reserved `git`, a slash, a name Git rejects) is invalid input, as in
/// `git remote add`; any other `add_remote` failure is a clone failure.
fn add_remote_error(e: GitRemoteManagementError) -> RepoError {
    match e {
        GitRemoteManagementError::RemoteName(_) => RepoError::InvalidInput { reason: e.to_string() },
        other => clone_failed(other.to_string()),
    }
}

/// What the clone's own parameters resolved to before anything is created inside the destination.
struct ClonePlan<'a> {
    remote: RemoteNameBuf,
    colocate: bool,
    hash: gix::hash::Kind,
    bookmarks: Option<StringExpression>,
    tags: Option<StringExpression>,
    options: &'a CloneOptions,
    progress: &'a ProgressFn,
    cancel: Option<&'a CancelGuard>,
}

fn clone_steps(
    options: &CloneOptions,
    (progress, cancel): (&ProgressFn, Option<&CancelGuard>),
    sink: &mut Warnings,
) -> Result<Repo, RepoError> {
    let startup = config::check_startup_stack(sink)?;
    let remote: RemoteNameBuf = options.remote_name.as_deref().unwrap_or("origin").into();
    let destination = &options.destination;
    let dest_text = destination.display().to_string();

    // `clone.rs:187-196`: refuse a non-empty destination BEFORE anything is created, then create
    // it with its parents.
    let existed = destination.exists();
    if existed && !file_util::is_empty_dir(destination).map_err(|e| clone_failed(mutate::flatten_chain(&e)))? {
        return Err(RepoError::DestinationNotEmpty {
            path: destination.clone(),
        });
    }
    std::fs::create_dir_all(destination).map_err(|e| clone_failed(format!("Failed to create {dest_text}: {e}")))?;

    // What the CLI reads and parses after creating the destination (`clone.rs:198-215`); a fault
    // here leaves the created directory, as in the CLI.
    let colocate = effective_colocate(&startup, options.colocate)?;
    let is_specific = options.branches.is_some() || options.tags.is_some();
    let specific = |texts: &Option<Vec<String>>| -> Result<Option<StringExpression>, RepoError> {
        match texts {
            Some(texts) => crate::bookmark_ops::union_expression(texts)
                .map(Some)
                .map_err(|e| RepoError::InvalidInput { reason: e.to_string() }),
            None => Ok(is_specific.then(StringExpression::none)),
        }
    };
    let bookmarks = specific(&options.branches)?;
    let tags = specific(&options.tags)?;
    let hash = gix_kind(effective_object_hash(&startup, options.object_hash)?);
    let root =
        std::fs::canonicalize(destination).map_err(|e| clone_failed(format!("Failed to create {dest_text}: {e}")))?;

    let plan = ClonePlan {
        remote,
        colocate,
        hash,
        bookmarks,
        tags,
        options,
        progress,
        cancel,
    };
    let (mut cloned, working) = match clone_into_workspace(&plan, &root, sink) {
        Ok(done) => done,
        Err(e) => {
            if let Err(err) = clean_up(&root, colocate, existed) {
                sink.extend([warning::clone_cleanup_failed(&root, &err)]);
            }
            return Err(e);
        }
    };

    // After the clean-up scope: failures from here on keep the workspace (`clone.rs:287-320`).
    let trunk = working
        .as_ref()
        .filter(|(_, is_default)| *is_default)
        .map(|(name, _)| name.to_remote_symbol(&plan.remote).to_string());
    let empty: &[String] = &[];
    config::write_repo_presets(
        || config::new_repo_config_file(&cloned.workspace),
        config::RepoPresets {
            remote: plan.remote.as_str(),
            fetch_bookmarks: is_specific.then(|| options.branches.as_deref().unwrap_or(empty)),
            fetch_tags: is_specific.then(|| options.tags.as_deref().unwrap_or(empty)),
            trunk: trunk.as_deref(),
        },
    )?;
    if let Some((name, _)) = &working {
        check_out_working_branch(&mut cloned, &plan.remote, name, sink)?;
    }
    Repo::open(&root)
}

/// The CLI's `clean_up_dirs` (`clone.rs:262-275`): `.jj`, `.git` when colocated (an absent one
/// counts as removed), then the destination itself iff the clone created it.
fn clean_up(root: &Path, colocate: bool, existed: bool) -> io::Result<()> {
    let sub_dirs = [Some(".jj"), colocate.then_some(".git")];
    for name in sub_dirs.iter().flatten() {
        match std::fs::remove_dir_all(root.join(name)) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
    }
    if !existed {
        std::fs::remove_dir(root)?;
    }
    Ok(())
}

/// A workspace the clone is building, with the start-up environment and the repo the next step
/// builds on.
struct Cloned {
    workspace: Workspace,
    settings: UserSettings,
    env: snapshot::CommandEnv,
    colocated: bool,
    repo: Arc<ReadonlyRepo>,
}

/// The clone steps inside the clean-up scope (`clone.rs:222-260`): `init_workspace`, the fetch
/// expressions, `configure_remote`, `fetch_new_remote`. Returns the workspace and the working
/// branch with whether it is the remote's default branch.
fn clone_into_workspace(
    plan: &ClonePlan<'_>,
    root: &Path,
    sink: &mut Warnings,
) -> Result<(Cloned, Option<(RefNameBuf, bool)>), RepoError> {
    // `init_workspace` (`clone.rs:325-341`).
    let settings = config::user_settings_for_new_workspace(root)?;
    let (workspace, repo) = if plan.colocate {
        pollster::block_on(Workspace::init_colocated_git(&settings, root, plan.hash))
    } else {
        pollster::block_on(Workspace::init_internal_git(&settings, root, plan.hash))
    }
    .map_err(|e| creation_error(&e, clone_failed))?;
    let (config, env) = workable_env(&workspace, sink, clone_failed)?;
    add_gitignore(&workspace, clone_failed)?;

    // The fetch expressions (`clone.rs:231-246`): the flags, else the remote's presets, else all.
    let remote_settings = config::remote_settings(&config, plan.remote.as_str())?;
    let preset = |text: Option<&String>, field: &str| -> Result<Option<StringExpression>, RepoError> {
        text.map(|text| {
            jj_lib::revset::parse_string_expression(&mut jj_lib::revset::RevsetDiagnostics::new(), text).map_err(|e| {
                RepoError::Config {
                    reason: format!("Invalid `remotes.{}.{field}`: {}", plan.remote.as_symbol(), e.kind()),
                }
            })
        })
        .transpose()
    };
    let bookmark = match &plan.bookmarks {
        Some(expr) => expr.clone(),
        None => preset(
            remote_settings.as_ref().and_then(|s| s.fetch_bookmarks.as_ref()),
            "fetch-bookmarks",
        )?
        .unwrap_or_else(StringExpression::all),
    };
    let tag = match &plan.tags {
        Some(expr) => expr.clone(),
        None => preset(
            remote_settings.as_ref().and_then(|s| s.fetch_tags.as_ref()),
            "fetch-tags",
        )?
        .unwrap_or_else(StringExpression::all),
    };

    let colocated = crate::wc_ops::is_colocated_git_workspace(&workspace).map_err(|e| clone_failed(e.to_string()))?;
    let mut cloned = Cloned {
        workspace,
        settings,
        env,
        colocated,
        repo,
    };
    configure_remote(&mut cloned, &plan.remote, &plan.options.source, sink)?;
    let working = fetch_new_remote(
        &mut cloned,
        &plan.remote,
        GitFetchRefExpression { bookmark, tag },
        plan,
        sink,
    )?;
    Ok((cloned, working))
}

/// `WorkspaceCommandTransaction::finish` (`cli_util.rs:2849-2866` @ v0.46.0): nothing when the
/// transaction changed nothing (the CLI's "Nothing changed."), else the mutable descendants
/// rebased, the Git import/export lock taken and the transaction finished. The new head becomes
/// `cloned.repo`.
fn finish(cloned: &mut Cloned, mut tx: Transaction, description: &str, sink: &mut Warnings) -> Result<(), RepoError> {
    if !tx.repo().has_changes() {
        return Ok(());
    }
    let immutable =
        crate::op_support::resolve_immutable(tx.base_repo().as_ref(), &cloned.env.immutable).map_err(finish_error)?;
    pollster::block_on(
        tx.repo_mut()
            .rebase_descendants_with_options(&immutable, &RebaseOptions::default(), |_, _| {}),
    )
    .map_err(|e| clone_failed(e.to_string()))?;
    let lock = snapshot::lock_git_import_export(&cloned.workspace, cloned.colocated)
        .map_err(|e| clone_failed(e.to_string()))?;
    let ctx = mutate::FinishCtx {
        immutable: &cloned.env.immutable,
        colocated: cloned.colocated,
        _lock: &lock,
    };
    let finish = mutate::finish_transaction(&mut cloned.workspace, tx, description, &ctx, sink)
        .map_err(|e| clone_failed(e.to_string()))?;
    cloned.repo = finish.repo;
    Ok(())
}

/// A failure resolving the clone finish's immutable set: an unresolvable `immutable_heads()` is
/// the CLI's config error (`rebase_mutable_descendants`, `cli_util.rs:2986-3002`, →
/// `resolve_immutable_expression`, `cli_util.rs:1146-1167` @ v0.46.0), everything else fails the
/// clone.
fn finish_error(e: MutateError) -> RepoError {
    match e {
        MutateError::Config { reason } => RepoError::Config { reason },
        other => clone_failed(other.to_string()),
    }
}

/// The CLI's `configure_remote` (`clone.rs:343-366`): `add git remote <name>` finished, then the
/// workspace reloaded so the Git backend sees the new remote, at the operation just written, and
/// the start-up environment built a second time (`for_workable_repo`).
fn configure_remote(
    cloned: &mut Cloned,
    remote: &RemoteName,
    source: &str,
    sink: &mut Warnings,
) -> Result<(), RepoError> {
    let mut tx = start_repo_transaction(&cloned.repo, cloned.workspace.workspace_name());
    jj_lib::git::add_remote(tx.repo_mut(), remote, source, None).map_err(add_remote_error)?;
    finish(cloned, tx, &format!("add git remote {}", remote.as_symbol()), sink)?;

    let workspace = Workspace::load(
        &cloned.settings,
        cloned.workspace.workspace_root(),
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .map_err(|e| clone_failed(e.to_string()))?;
    let op = pollster::block_on(workspace.repo_loader().load_operation(cloned.repo.op_id()))
        .map_err(|e| clone_failed(e.to_string()))?;
    let repo = pollster::block_on(workspace.repo_loader().load_at(&op)).map_err(|e| clone_failed(e.to_string()))?;
    let (_config, env) = workable_env(&workspace, sink, clone_failed)?;
    cloned.workspace = workspace;
    cloned.repo = repo;
    cloned.env = env;
    Ok(())
}

/// The CLI's `fetch_new_remote` (`clone.rs:368-460`): fetch and import into one transaction,
/// pick the working branch (the first exact `-b` the remote has, else the default branch),
/// warn the missing exact branches, track the default bookmark (`git.track-default-bookmark-
/// on-clone`), report the import's failed refs, and finish `fetch from git remote into empty repo`.
fn fetch_new_remote(
    cloned: &mut Cloned,
    remote: &RemoteName,
    ref_expr: GitFetchRefExpression,
    plan: &ClonePlan<'_>,
    sink: &mut Warnings,
) -> Result<Option<(RefNameBuf, bool)>, RepoError> {
    let config = config::load_for_workspace(&cloned.workspace)?;
    let subprocess_options = crate::environment::git_subprocess_options(&cloned.settings, plan.cancel)
        .map_err(|e| RepoError::from(config::value_error(&e)))?;
    let import_options = GitImportOptions {
        // "There may be a large number of new commits": never record synthetic predecessors.
        record_synthetic_predecessors: false,
        ..config::git_import_options(&config)?
    };
    let should_track_default = config::git_track_default_bookmark_on_clone(&config)?;
    let bookmark_matcher = ref_expr.bookmark.to_matcher();
    let exact_bookmarks: Vec<RefNameBuf> = ref_expr
        .bookmark
        .exact_strings()
        .filter(|name| bookmark_matcher.is_match(name))
        .map(RefNameBuf::from)
        .collect();

    let mut tx = start_repo_transaction(&cloned.repo, cloned.workspace.workspace_name());
    let (default_branch, import_stats) = {
        crate::cancel::watch_store(plan.cancel, tx.repo().store());
        let mut fetcher = GitFetch::new(tx.repo_mut(), subprocess_options, &import_options)
            .map_err(|e| clone_failed(e.to_string()))?;
        let refspecs = expand_fetch_refspecs(remote, ref_expr).map_err(|e| RepoError::CloneFailed {
            reason: e.to_string(),
            hints: crate::remotes::expansion_hints(&e),
        })?;
        let mut callback = ProgressCallback {
            operation: "clone",
            progress: plan.progress,
        };
        // Story 9.52's checkpoints, before and after the git work: inside the clean-up scope, so a
        // cancelled clone removes what it created.
        crate::cancel::checkpoint(plan.cancel)?;
        fetcher
            .fetch(remote, refspecs, &mut callback, plan.options.depth)
            .map_err(|e| fetch_error(e, plan.cancel))?;
        let import_stats = pollster::block_on(fetcher.import_refs()).map_err(|e| clone_failed(e.to_string()))?;
        let default_branch = fetcher
            .get_default_branch(remote)
            .map_err(|e| fetch_error(e, plan.cancel))?;
        crate::cancel::checkpoint(plan.cancel)?;
        (default_branch, import_stats)
    };

    let mut missing: Vec<&RefName> = Vec::new();
    let mut working: Option<RefNameBuf> = None;
    for name in &exact_bookmarks {
        if tx
            .repo()
            .view()
            .get_remote_bookmark(name.to_remote_symbol(remote))
            .is_absent()
        {
            missing.push(name);
        } else if working.is_none() {
            working = Some(name.clone());
        }
    }
    if working.is_none() {
        working = default_branch.clone().filter(|name| {
            tx.repo()
                .view()
                .get_remote_bookmark(name.to_remote_symbol(remote))
                .is_present()
        });
    }
    if !missing.is_empty() {
        let names: Vec<String> = missing.iter().map(|name| name.as_symbol().to_string()).collect();
        sink.push(
            WarningKind::CloneBranchesUnmatched,
            format!("No matching branches found on remote: {}", names.join(", ")),
        );
    }
    let is_default = working.is_some() && working == default_branch;
    if let Some(name) = working.as_ref().filter(|_| is_default && should_track_default) {
        pollster::block_on(tx.repo_mut().track_remote_bookmark(name.to_remote_symbol(remote)))
            .map_err(|e| clone_failed(e.to_string()))?;
    }
    sink.extend(warning::git_import_failed(&import_stats));
    finish(cloned, tx, "fetch from git remote into empty repo", sink)?;
    Ok(working.map(|name| (name, is_default)))
}

/// The CLI's checkout of the working branch (`clone.rs:303-320`): `@` created on the branch's
/// commit, finished as `check out git remote's branch: <name>`.
fn check_out_working_branch(
    cloned: &mut Cloned,
    remote: &RemoteName,
    name: &RefName,
    sink: &mut Warnings,
) -> Result<(), RepoError> {
    let remote_ref = cloned.repo.view().get_remote_bookmark(name.to_remote_symbol(remote));
    let Some(commit_id) = remote_ref.target.as_normal().cloned() else {
        return Ok(());
    };
    let workspace_name = cloned.workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&cloned.repo, &workspace_name);
    if let Ok(commit) = tx.repo().store().get_commit(&commit_id) {
        pollster::block_on(tx.repo_mut().check_out(workspace_name, &commit))
            .map_err(|e| clone_failed(e.to_string()))?;
    }
    finish(
        cloned,
        tx,
        &format!("check out git remote's branch: {}", name.as_symbol()),
        sink,
    )
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{
        add_remote_error, clean_up, create_destination, create_or_reuse_dir, fetch_error, finish_error, Created,
    };
    use crate::{MutateError, RepoError};

    /// Story 9.58: jj-lib's `create_or_reuse_dir`, answering whether THIS call created the
    /// directory — a new one `true`, an existing one `false` (reused), a missing parent and an
    /// existing file are errors, and nothing is created on the way.
    #[test]
    fn create_or_reuse_dir_reports_whether_it_created_the_directory() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let root = tmp.path();
        assert!(create_or_reuse_dir(&root.join("new")).expect("creates"));
        assert!(root.join("new").is_dir());
        assert!(!create_or_reuse_dir(&root.join("new")).expect("reuses"));
        assert!(create_or_reuse_dir(&root.join("missing/dest")).is_err());
        assert!(!root.join("missing").exists(), "one level: no parent is created");
        std::fs::write(root.join("file"), "x").expect("write file");
        assert!(create_or_reuse_dir(&root.join("file")).is_err());
    }

    /// Story 9.58: the destination step records a destination it created, canonical (a `..`
    /// spelling names the directory actually created), and none it reused.
    #[test]
    fn create_destination_records_only_a_created_destination_canonically() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let root = tmp.path().canonicalize().expect("canonicalize");
        std::fs::create_dir(tmp.path().join("x")).expect("mkdir x");

        let mut created = Created::default();
        let dest = create_destination(&tmp.path().join("x/../y"), &mut created).expect("creates y");
        assert_eq!(dest, root.join("y"));
        assert_eq!(created.destination, Some(root.join("y")));
        assert_eq!(created.left_behind(), [root.join("y")]);

        let mut reused = Created::default();
        create_destination(&tmp.path().join("x"), &mut reused).expect("reuses x");
        assert_eq!(reused.destination, None);
        assert!(reused.left_behind().is_empty());
    }

    /// The CLI's `clean_up_dirs` (`clone.rs:262-284` @ v0.46.0): `.jj` and — colocated — `.git`
    /// removed (an absent one counts as removed), the destination removed iff the clone created
    /// it; any other failure is returned for the caller's `jj.clone_cleanup_failed` warning.
    #[cfg(unix)]
    #[test]
    fn clean_up_removes_what_the_clone_created_and_reports_a_failure() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(tmp.path()).unwrap();

        let created = root.join("created");
        std::fs::create_dir_all(created.join(".jj").join("repo")).unwrap();
        std::fs::create_dir_all(created.join(".git")).unwrap();
        clean_up(&created, true, false).expect("everything removable");
        assert!(!created.exists(), "a destination the clone created is removed");

        let existed = root.join("existed");
        std::fs::create_dir_all(existed.join(".jj")).unwrap();
        clean_up(&existed, false, true).expect("an absent .git is no failure");
        assert!(
            existed.is_dir() && !existed.join(".jj").exists(),
            "a pre-existing destination stays"
        );

        let held = root.join("held");
        let jj = held.join(".jj");
        std::fs::create_dir_all(&jj).unwrap();
        std::fs::write(jj.join("held"), "x").unwrap();
        std::fs::set_permissions(&jj, std::fs::Permissions::from_mode(0o555)).unwrap();
        let err = clean_up(&held, false, false);
        std::fs::set_permissions(&jj, std::fs::Permissions::from_mode(0o755)).unwrap();
        let err = err.expect_err("a .jj whose entries cannot be removed fails the clean-up");
        let warning = crate::warning::clone_cleanup_failed(&held, &err);
        assert_eq!(warning.kind, crate::WarningKind::CloneCleanupFailed);
        assert!(
            warning
                .message
                .starts_with(&format!("Failed to clean up {}: ", held.display())),
            "{}",
            warning.message
        );
        assert!(jj.join("held").exists(), "a failed removal leaves the entry in place");
        assert!(Path::new(&held).is_dir(), "and the destination with it");
    }

    /// Only the classes the closing run types leave `CloneFailed`: a refused remote name is
    /// `InvalidInput` and a `git` subprocess failure `NetworkError` (both witnessed through a real
    /// clone in `tests/it/clone_init.rs`); every other jj-lib failure stays a clone failure with
    /// jj-lib's message. `GitSubprocessError` is not nameable outside jj-lib, so the network arm
    /// has no unit test here.
    #[test]
    fn only_remote_names_and_git_subprocess_failures_leave_clone_failed() {
        use jj_lib::git::{GitFetchError, GitRemoteManagementError, GitRemoteNameError};

        assert!(matches!(
            add_remote_error(GitRemoteManagementError::RemoteName(GitRemoteNameError::ReservedForLocalGitRepo)),
            RepoError::InvalidInput { reason } if reason.contains("reserved")
        ));
        assert!(matches!(
            add_remote_error(GitRemoteManagementError::InternalGitError("boom".into())),
            RepoError::CloneFailed { reason, hints } if reason == "Unexpected Git error when managing remotes" && hints.is_empty()
        ));
        assert!(matches!(
            fetch_error(GitFetchError::NoSuchRemote("origin".into()), None),
            RepoError::CloneFailed { reason, hints } if reason == "No git remote named 'origin'" && hints.is_empty()
        ));
        let reserved = fetch_error(
            GitFetchError::RemoteName(GitRemoteNameError::ReservedForLocalGitRepo),
            None,
        );
        assert_eq!(
            reserved.hints(),
            ["Run `jj git remote rename` to give a different name."]
        );
        assert!(
            matches!(&reserved, RepoError::CloneFailed { reason, .. }
                if *reason == GitRemoteNameError::ReservedForLocalGitRepo.to_string()),
            "{reserved:?}"
        );
        // A cancel turns only a git failure into the cancel; any other failure passes through.
        let token = u64::MAX - 1;
        crate::cancel::register(token);
        let guard = crate::cancel::attach(token).expect("attaches");
        crate::cancel::cancel(token);
        assert!(matches!(
            fetch_error(GitFetchError::NoSuchRemote("origin".into()), Some(&guard)),
            RepoError::CloneFailed { .. }
        ));
    }

    /// Story 9.57 closing run: an unresolvable `immutable_heads()` at a clone finish is the CLI's
    /// config error (`cli_util.rs:2986-3002` → `:1146-1167` @ v0.46.0, propagated by
    /// `clone.rs:262-284` after its clean-up); any other failure stays a clone failure with its
    /// text.
    #[test]
    fn clone_finish_failures_map_onto_the_repo_error_taxonomy() {
        assert!(matches!(
            finish_error(MutateError::Config { reason: "alias".to_owned() }),
            RepoError::Config { reason } if reason == "alias"
        ));
        assert!(matches!(
            finish_error(MutateError::Backend("b".to_owned())),
            RepoError::CloneFailed { reason, hints } if reason.contains('b') && hints.is_empty()
        ));
    }
}
