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
//! TWO shapes, and which one runs is read from [`is_colocated`], never assumed:
//!
//! 1. **`import git refs`** ([`init_git_refs`]) — both shapes. One transaction running
//!    [`jj_lib::git::import_refs`]; NO operation is written when it changed nothing
//!    (`has_changes()`), and a colocated workspace also runs [`jj_lib::git::export_refs`]
//!    before the commit.
//! 2. **`.jj/.gitignore`** ([`maybe_add_gitignore`]) — the literal `/*\n`, COLOCATED only.
//! 3. **`import git head`** ([`import_git_head`]) — COLOCATED only, and again skipped
//!    entirely when [`jj_lib::git::import_head`] changed nothing.
//! 4. **`revset-aliases.'trunk()'`** ([`maybe_set_trunk_alias`]) — both shapes. Written into
//!    the REPO-level config file, which lives OUTSIDE `.jj/` (under
//!    `<config_dir>/jj/repos/`), when `refs/remotes/upstream/HEAD` or
//!    `refs/remotes/origin/HEAD` names a bookmark.
//! 5. **`import git head`, once more** — NON-colocated only, and written inline in
//!    [`import_into`] rather than through [`import_git_head`]: this is the CLI's own
//!    non-colocated tail, the same import paired with the `check_out` + materialisation that
//!    gives a fresh destination its files, so it cannot share the reset-free helper.
//!
//! Every operation either verb writes carries the converting workspace's name in its metadata,
//! as the CLI's do: all three transactions are opened through
//! [`crate::op_support::start_repo_transaction`] (Epic 9 follow-up L).
//!
//! The colocated shape is therefore steps 1-2-3-4 and the non-colocated one steps 1-4-5.
//! [`convert_import`] runs whichever its two paths select; [`convert_colocated`] always stops
//! after step 4, deliberately — see [`convert_into`].
//!
//! What `.git/` sees is step 1's colocated `export_refs` and nothing else: it writes back the
//! refs jj has just imported, so no user-visible ref and no HEAD is moved, and the rollback
//! below never deletes or rewrites `.git/`.
//!
//! Two deliberate departures, both documented at their site: the colocated head import omits
//! the working-copy reset the CLI pairs it with (Story 9.22 owns the locked-working-copy
//! lifecycle; project decision D2 — Zanshin never snapshots), and a failed conversion rolls
//! back further than the CLI does, which never undoes a partial `jj git init`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::git::{import_refs, GitImportOptions, GitRefKind};
use jj_lib::ref_name::{GitRefName, RemoteName, WorkspaceName};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;

use crate::op_support::start_repo_transaction;
use crate::repo::make_settings;
use crate::{config, detect_repo, Repo, RepoError, RepoKind};

/// Converts the Git repository at `path` into a colocated jj workspace (FR-JJ-18a).
///
/// Additive and reversible: a `.jj/` is created alongside the existing,
/// non-destructively-reused `.git/`; the working-copy files are never
/// overwritten. Returns a warm [`Repo`] handle for the now-colocated workspace.
///
/// # What lands on disk
///
/// The CLI's `GitInitMode::External` sequence, unabridged (see the module doc): up to two
/// operations, `import git refs` then `import git head`, each written only when its import
/// changed something; `.jj/.gitignore` containing `/*`; and — when `refs/remotes/upstream/HEAD`
/// or `refs/remotes/origin/HEAD` names a bookmark — `revset-aliases.'trunk()'` in the
/// repo-level config file, which lives **outside** `.jj/`, under `<config_dir>/jj/repos/`.
///
/// The one thing written into `.git/` is the refs operation's colocated `export_refs`, the
/// CLI's own step: it writes back exactly the refs jj has just imported, so no user-visible
/// ref and no `HEAD` is moved.
///
/// Two deliberate departures from the CLI:
///
/// - The head import omits the working-copy `reset` the CLI pairs with it (Story 9.22 /
///   decision D2), so `@` is not re-parented onto the imported HEAD; it settles there on the
///   first colocated snapshot (D3a).
/// - A failure rolls back further than the CLI, which leaves a partially converted repo in
///   place. Rollback removes `.jj/` only — it never deletes or rewrites `.git/` — so a
///   conversion that fails *after* the alias step can orphan the secure-config directory it
///   created.
///
/// # Errors
///
/// - [`RepoError::AlreadyJjRepo`] — `path` is already a jj workspace.
/// - [`RepoError::NotAGitRepo`] — `path` is neither a Git repo nor exists, or it cannot be
///   resolved to an absolute path (the same answer the not-found case gives).
/// - [`RepoError::ConvertFailed`] — a jj-lib, config-write or `detect_repo` I/O error during
///   conversion; the partially-created `.jj/` is rolled back.
pub fn convert_colocated(path: &Path) -> Result<Repo, RepoError> {
    match detect_repo(path) {
        Ok(RepoKind::Jj) => return Err(RepoError::AlreadyJjRepo { path: path.to_owned() }),
        Ok(RepoKind::Git) => {}
        Ok(RepoKind::Neither | RepoKind::PathNotFound) => return Err(RepoError::NotAGitRepo { path: path.to_owned() }),
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }

    let settings = make_settings()?;
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
    match convert_into(&settings, &root) {
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
/// module doc): up to two operations, `import git refs` then `import git head`, each written
/// only when its import changed something, with the working copy materialised from the
/// imported HEAD; NO `.jj/.gitignore` and no `export_refs`, both of which are colocated-only;
/// and, when `refs/remotes/upstream/HEAD` or `refs/remotes/origin/HEAD` names a bookmark,
/// `revset-aliases.'trunk()'` in the repo-level config file, which lives **outside** the
/// destination, under `<config_dir>/jj/repos/`.
///
/// Passing `workspace_path == git_repo_path` (D5) is a colocated request and takes the
/// colocated shape instead — including its `.jj/.gitignore`, and its head import without the
/// CLI's paired working-copy reset (Story 9.22 / decision D2).
///
/// A failure rolls back further than the CLI, which leaves a partially initialised repo in
/// place: the destination (or just its `.jj/`, when the directory already existed) is
/// removed, the source is never touched, and a failure *after* the alias step can orphan the
/// secure-config directory it created.
///
/// # Errors
///
/// - [`RepoError::AlreadyJjRepo`] — `workspace_path` (or `git_repo_path`) is
///   already a jj workspace.
/// - [`RepoError::NotAGitRepo`] — `git_repo_path` is not a Git repo (normal or
///   bare) or does not exist.
/// - [`RepoError::ConvertFailed`] — a jj-lib, config-write or `detect_repo` I/O error, or
///   `workspace_path` cannot be created or resolved; the partially-created destination is
///   rolled back.
pub fn convert_import(git_repo_path: &Path, workspace_path: &Path) -> Result<Repo, RepoError> {
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

    let settings = make_settings()?;
    let created_dir = !workspace_path.exists();
    match import_into(&settings, git_repo_path, workspace_path) {
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

/// Port of `cli/src/git_util.rs::is_colocated_git_workspace` (@ v0.42.0).
///
/// Guards the working-copy materialisation step: we only create a jj-native `@`
/// when the workspace is NOT colocated (i.e. when `workspace_root ≠ git workdir`).
/// For the intended two-path use this is always false, but if a caller passes
/// `workspace_path == git_repo_path` jj silently creates a colocated result (D5).
///
/// Pass a **canonicalized** `workspace_root` (e.g. `Workspace::workspace_root()`).
/// `git_backend.git_workdir()` is already canonicalized by gix, so comparing it
/// against a raw caller path would spuriously differ on macOS (`/var` →
/// `/private/var`) and miss the colocated case.
fn is_colocated(repo: &impl jj_lib::repo::Repo, workspace_root: &Path) -> bool {
    let Ok(git_backend) = jj_lib::git::get_git_backend(repo.store()) else {
        return false;
    };
    let Some(git_workdir) = git_backend.git_workdir() else {
        return false; // bare backing repo → not colocated
    };
    git_workdir == workspace_root
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
/// The `GitImportOptions` are the CLI's own overrides for this flow, hardcoded rather than
/// read from config: at this point in `do_init` the CLI pins `abandon_unreachable_commits`
/// ("There should be no old refs to abandon, but enforce it") and
/// `record_synthetic_predecessors` ("There may be a large number of new commits") to `false`
/// regardless of the user's config, and only `remote_auto_track_bookmarks` comes off config.
/// Leaving that map EMPTY is the one remaining gap, and it is a SEPARATE, crate-wide ledger
/// item — `Repo::git_fetch` and `clone_into` leave it empty too (see
/// [`crate::config::git_import_options`]).
fn init_git_refs(
    repo: &Arc<ReadonlyRepo>,
    workspace_name: &WorkspaceName,
    colocated: bool,
) -> Result<Arc<ReadonlyRepo>, RepoError> {
    let import_options = GitImportOptions {
        abandon_unreachable_commits: false,
        record_synthetic_predecessors: false,
        remote_auto_track_bookmarks: HashMap::new(),
    };
    let mut tx = start_repo_transaction(repo, workspace_name);
    pollster::block_on(import_refs(tx.repo_mut(), &import_options))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    if !tx.repo().has_changes() {
        return Ok(Arc::clone(repo));
    }
    if colocated {
        jj_lib::git::export_refs(tx.repo_mut()).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
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

/// The `import git head` operation, without the working-copy half.
///
/// Ports three of the four things `cli_util.rs::import_git_head` (`:1352-1416` @ v0.44.0)
/// does — [`jj_lib::git::import_head`], the early return that writes NO operation when it
/// changed nothing, and the `import git head` commit. The fourth, `check_out` +
/// `locked_wc().reset(&wc_commit)`, is deliberately left out: it needs
/// `start_working_copy_mutation`, the locked-working-copy lifecycle **Story 9.22** owns, and
/// reversing project decision D2 (Zanshin never snapshots) is not this port's call.
///
/// Consequence, restated in both verbs' rustdoc: after a colocated conversion the op log
/// matches the CLI's, but `@` has not been re-parented onto the imported HEAD — it settles
/// there on the first snapshot, exactly as 2.12's D3a already documented.
fn import_git_head(repo: &Arc<ReadonlyRepo>, workspace_name: &WorkspaceName) -> Result<Arc<ReadonlyRepo>, RepoError> {
    let mut tx = start_repo_transaction(repo, workspace_name);
    pollster::block_on(jj_lib::git::import_head(tx.repo_mut()))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    if !tx.repo().has_changes() {
        return Ok(Arc::clone(repo));
    }
    pollster::block_on(tx.commit("import git head")).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })
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

/// Runs the colocated external-git init and then `do_init`'s External sequence. On `Err`,
/// the caller rolls back `.jj/`.
fn convert_into(settings: &UserSettings, path: &Path) -> Result<(), RepoError> {
    // 1. Open the EXISTING `.git` as the backing store (gix::open — strictly
    //    non-destructive). Because `.git` is inside `path`, the workspace is
    //    colocated. This is what `jj git init --colocate` does for an existing
    //    repo (cli/src/commands/git/init.rs @ v0.44.0 -> GitInitMode::External).
    let git_repo_path = path.join(".git");
    let (workspace, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
        settings,
        path,
        &git_repo_path,
    ))
    .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    // 2. The CLI's four External-arm steps, in its order. NO working-copy writes anywhere
    //    (no check_out, no snapshot, no `@`-reparent — D3/D3a): `@` settles onto HEAD on the
    //    next colocated snapshot. `is_colocated` is normally true here (`.git` lives inside
    //    `path`); it is read rather than assumed because a linked git worktree — where `.git`
    //    is a gitdir POINTER file and the git workdir is the main repo — is classified `Git`
    //    by `detect_repo` and reaches this far, and in that shape `export_refs` and the
    //    `.gitignore` would both be wrong.
    let colocated = is_colocated(repo.as_ref(), workspace.workspace_root());
    let repo = init_git_refs(&repo, workspace.workspace_name(), colocated)?;
    maybe_add_gitignore(workspace.workspace_root(), colocated)?;
    let repo = import_git_head(&repo, workspace.workspace_name())?;
    maybe_set_trunk_alias(&workspace, repo.as_ref())
}

/// Ports `do_init`'s `GitInitMode::External` branch (jj CLI @ v0.44.0), non-colocated in the
/// intended two-path use. Creates and populates the jj workspace at `workspace_path`. On
/// `Err`, the caller rolls back the destination.
fn import_into(settings: &UserSettings, git_repo_path: &Path, workspace_path: &Path) -> Result<(), RepoError> {
    std::fs::create_dir_all(workspace_path).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    // WHY here and not at the entry point: the destination may legitimately not exist yet, so the
    // canonicalize has to follow the directory creation. It has to happen at all because
    // `init_external_git` records the workspace root in the store RELATIVE to this path while
    // every read joins onto the canonical `Workspace::repo_path()` — see `Repo::open`.
    let workspace_path =
        std::fs::canonicalize(workspace_path).map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    let resolved = resolve_git_repo_path(git_repo_path);

    // 1. Open the existing repo as the backing store (gix::open — non-destructive).
    //    Keep `workspace`: we materialise the working copy into the dest below.
    let (mut workspace, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
        settings,
        &workspace_path,
        &resolved,
    ))
    .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    let workspace_name = workspace.workspace_name().to_owned();

    // 2. The CLI's External-arm steps, in its order: refs op, `.jj/.gitignore`, the colocated
    //    head op, the `trunk()` alias, and only then the non-colocated head op below.
    //    `is_colocated` is false for the intended two-path use and true when a caller passes
    //    `workspace_path == git_repo_path` (D5), which is a colocated request jj honours.
    let colocated = is_colocated(repo.as_ref(), workspace.workspace_root());
    let repo = init_git_refs(&repo, &workspace_name, colocated)?;
    maybe_add_gitignore(workspace.workspace_root(), colocated)?;
    let repo = if colocated {
        import_git_head(&repo, &workspace_name)?
    } else {
        repo
    };
    maybe_set_trunk_alias(&workspace, repo.as_ref())?;
    if colocated {
        return Ok(());
    }

    // 3. The CLI's non-colocated head import (`init.rs:262-270`): import HEAD, create `@` on
    //    top of the imported commit, and write the operation only when something changed.
    //    Skipped when HEAD is unborn (`git_head().as_normal() == None` — e.g. a fresh
    //    `git init` with no commits), in which case `import_head` also changed nothing and no
    //    operation is written. This mirrors `clone_into` (repo.rs:~1650–1700).
    let mut tx = start_repo_transaction(&repo, &workspace_name);
    pollster::block_on(jj_lib::git::import_head(tx.repo_mut()))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    let new_wc_commit = if let Some(git_head_id) = tx.repo().view().git_head().as_normal().cloned() {
        let mut_repo = tx.repo_mut();
        let commit = mut_repo
            .store()
            .get_commit(&git_head_id)
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        let wc = pollster::block_on(mut_repo.check_out(workspace_name.clone(), &commit))
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        pollster::block_on(mut_repo.rebase_descendants())
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        Some(wc)
    } else {
        None
    };
    // The CLI writes the operation only when something changed (its `if tx.repo().has_changes()`
    // around `tx.finish`); with an unborn HEAD the import was a no-op, no `@` was created, and
    // the transaction is dropped uncommitted.
    let new_repo = if tx.repo().has_changes() {
        let committed = pollster::block_on(tx.commit("import git head"))
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        Some(committed)
    } else {
        None
    };

    // 4. Materialise HEAD's tree into the (empty) destination directory.
    if let (Some(new_repo), Some(wc_commit)) = (&new_repo, &new_wc_commit) {
        pollster::block_on(workspace.check_out(new_repo.op_id().clone(), None, wc_commit))
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repo::make_settings;

    #[test]
    fn is_colocated_with_simple_backend_returns_false() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let settings = make_settings().expect("settings");
        let (_ws, repo) =
            pollster::block_on(jj_lib::workspace::Workspace::init_simple(&settings, tmp.path())).expect("init_simple");
        assert!(!is_colocated(repo.as_ref(), tmp.path()));
    }

    /// The alias reader needs a GIT backend; on anything else `get_git_repo` refuses and the
    /// refusal is forwarded rather than swallowed. Unreachable from either verb (both go
    /// through `init_external_git`), so it is pinned here on the same `init_simple`
    /// workspace its sibling above uses.
    #[test]
    fn maybe_set_trunk_alias_with_simple_backend_is_a_convert_failure() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let settings = make_settings().expect("settings");
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
        let settings = make_settings().expect("settings");
        std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(&root)
            .env("GIT_CONFIG_GLOBAL", "")
            .status()
            .expect("git init");
        let git_dir = root.join(".git");
        let (_ws, repo) = pollster::block_on(jj_lib::workspace::Workspace::init_external_git(
            &settings, &root, &git_dir,
        ))
        .expect("init_external_git");
        assert!(is_colocated(repo.as_ref(), &root));
    }
}
