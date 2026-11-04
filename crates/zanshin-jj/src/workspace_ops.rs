// SPDX-License-Identifier: MIT

//! `workspace_ops.rs` — `jj workspace forget`, `rename` and `remove` (Story 9.13), ported step
//! for step from `cmd_workspace_{forget,rename,remove}` (`cli/src/commands/workspace/
//! {forget.rs:43-126, rename.rs:30-83}` @ v0.46.0, `remove.rs:53-249` @ v0.47.0).
//!
//! What each leaves in the workspace STORE (the recorded paths) is the CLI's: `forget` keeps the
//! path (so `undo` can point the workspace back at its directory, jj #9991), `remove` forgets it,
//! `rename` renames it. The store is loaded afresh per call ([`crate::workspace::load_store`]), as
//! every CLI command's start-up loads it.
//!
//! Deliberate divergences:
//!
//! - **Status lines as typed facts**: "Nothing changed." is a result whose `new_op_id` is the
//!   pre-call head; "Removed Git worktree for …" and "Removed workspace directory …" are
//!   [`WorkspaceRemoveResult::git_worktrees_removed`] / [`WorkspaceRemoveResult::directories_removed`].
//! - **`std::fs::canonicalize`** stands in for the CLI's `dunce::canonicalize` — identical on
//!   macOS, the only platform Zanshin ships on.
//! - `remove`'s `check_working_copy_writable` is not ported: it refuses only `--at-op`,
//!   `--ignore-working-copy` and `--no-integrate-operation`, none of which a GUI call has.

use std::path::PathBuf;

use jj_lib::commit::Commit;
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::git;
use jj_lib::ref_name::{WorkspaceName, WorkspaceNameBuf};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::store::Store;
use jj_lib::view::RenameWorkspaceError;
use jj_lib::workspace::{DefaultWorkspaceLoaderFactory, Workspace, WorkspaceLoadError, WorkspaceLoaderFactory as _};

use crate::mutate::{self, be, cfg, flatten_chain, MutateError, MutationResult};
use crate::op_support::start_repo_transaction;
use crate::snapshot::{self, CommandEnv, VerbContext};
use crate::warning::{self, WarningKind, Warnings};

/// `remove`'s hint (`remove.rs:38-39` @ v0.47.0).
const USE_WORKSPACE_FORGET_HINT: &str =
    "Use `jj workspace forget` to stop tracking a workspace without deleting files.";

/// What [`crate::Repo::workspace_forget`] and [`crate::Repo::workspace_remove`] did (Story 9.13)
/// — the CLI's status lines as facts.
#[derive(Debug)]
pub struct WorkspaceRemoveResult {
    /// The call's operation, `forget workspace(s) …` / `remove workspace(s) …` — or, when no
    /// name named a workspace, the pre-call head. `working_copy_change_id` is `None` when this
    /// workspace itself was forgotten or removed. For `remove`, `new_change_ids` holds the
    /// "SNAPSHOT OF REMOVED WORKSPACE" commits, in name order — one per target whose files had
    /// changed.
    pub mutation: MutationResult,
    /// The workspace directories (canonical) whose Git worktree was unlinked — the CLI's
    /// `Removed Git worktree for "<path>".`, in name order.
    pub git_worktrees_removed: Vec<PathBuf>,
    /// The workspace directories (canonical) `remove` deleted — the CLI's `Removed workspace
    /// directory "<path>".`, in name order. Always empty for `forget`.
    pub directories_removed: Vec<PathBuf>,
}

/// The names of `names` the view has a working-copy commit for, in order (duplicates kept, as
/// the CLI keeps them); every other name warns `No such workspace: <name>`.
fn known_names(repo: &ReadonlyRepo, names: &[WorkspaceNameBuf], sink: &mut Warnings) -> Vec<WorkspaceNameBuf> {
    let mut known = Vec::new();
    for name in names {
        if repo.view().get_wc_commit_id(name).is_some() {
            known.push(name.clone());
        } else {
            sink.push(
                WarningKind::WorkspaceNamesUnmatched,
                format!("No such workspace: {}", name.as_symbol()),
            );
        }
    }
    known
}

/// `<verb> workspace <a>` / `<verb> workspaces <a>, <b>` — both verbs' op description.
fn description(verb: &str, names: &[WorkspaceNameBuf]) -> String {
    let symbols = names
        .iter()
        .map(|n| n.as_symbol().to_string())
        .collect::<Vec<_>>()
        .join(", ");
    if names.len() == 1 {
        format!("{verb} workspace {symbols}")
    } else {
        format!("{verb} workspaces {symbols}")
    }
}

/// The CLI's `unlink_git_worktree` (`cli/src/git_util.rs:572-595` @ v0.46.0) over `paths`: the
/// unlinked ones are returned, a failure warns and the call goes on.
///
/// # Errors
///
/// - [`MutateError::Config`] — `git.executable-path` does not read (the CLI's
///   `GitSubprocessOptions::from_settings` `?`).
pub(crate) fn unlink_worktrees(
    workspace: &Workspace,
    store: &Store,
    paths: &[PathBuf],
    sink: &mut Warnings,
) -> Result<Vec<PathBuf>, MutateError> {
    let options = crate::environment::git_subprocess_options(workspace.settings(), None).map_err(cfg)?;
    let mut unlinked = Vec::new();
    for path in paths {
        match git::unlink_worktree(store, options.clone(), path) {
            Ok(false) => {}
            Ok(true) => unlinked.push(path.clone()),
            Err(err) => {
                let mut lines = vec![format!(r#"Failed to remove Git worktree for "{}"."#, path.display())];
                lines.extend(warning::caused_by(Some(&err)));
                sink.push(WarningKind::GitWorktreeUnlinkFailed, lines.join("\n"));
            }
        }
    }
    Ok(unlinked)
}

/// `jj workspace forget` — see [`crate::Repo::workspace_forget`].
pub(crate) fn forget(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    names: &[String],
) -> Result<WorkspaceRemoveResult, MutateError> {
    let readonly = snapshot::reload_head(workspace).map_err(be)?;
    let names: Vec<WorkspaceNameBuf> = if names.is_empty() {
        vec![workspace.workspace_name().to_owned()]
    } else {
        names.iter().map(|n| WorkspaceNameBuf::from(n.as_str())).collect()
    };
    let forget = known_names(&readonly, &names, &mut ctx.warnings);
    if forget.is_empty() {
        return Ok(WorkspaceRemoveResult {
            mutation: mutate::no_op_result(workspace.workspace_name(), &readonly)?,
            git_worktrees_removed: Vec::new(),
            directories_removed: Vec::new(),
        });
    }
    // Unreachable paths are omitted, as in the CLI.
    let store = crate::workspace::load_store(workspace).map_err(be)?;
    let paths: Vec<PathBuf> = forget
        .iter()
        .filter_map(|n| store.get_workspace_path(n).ok().flatten())
        .filter_map(|p| std::fs::canonicalize(p).ok())
        .collect();

    let mut tx = start_repo_transaction(&readonly, workspace.workspace_name());
    for name in &forget {
        pollster::block_on(tx.repo_mut().remove_workspace(name)).map_err(be)?;
    }
    // The recorded path stays in the store (jj #9991): `undo` can point the workspace back at it.
    let finish = mutate::finish_verb(workspace, tx, &description("forget", &forget), ctx)?;
    let git_worktrees_removed = unlink_worktrees(workspace, finish.repo.store(), &paths, &mut ctx.warnings)?;
    Ok(WorkspaceRemoveResult {
        mutation: mutate::mutation_result(&finish, Vec::new(), Vec::new()),
        git_worktrees_removed,
        directories_removed: Vec::new(),
    })
}

/// `jj workspace rename` — see [`crate::Repo::workspace_rename`]. The empty-name refusal is the
/// facade's, before the snapshot.
pub(crate) fn rename(workspace: &mut Workspace, new_name: &str) -> Result<MutationResult, MutateError> {
    let readonly = snapshot::reload_head(workspace).map_err(be)?;
    let old_name = workspace.workspace_name().to_owned();
    let new_name = WorkspaceName::new(new_name);
    if *new_name == old_name {
        return mutate::no_op_result(&old_name, &readonly);
    }
    if readonly.view().get_wc_commit_id(&old_name).is_none() {
        return Err(MutateError::NoWorkingCopy);
    }
    let store = crate::workspace::load_store(workspace).map_err(be)?;

    let mut tx = start_repo_transaction(&readonly, &old_name);
    let (mut locked_ws, _wc_commit) = mutate::lock_working_copy(workspace, &readonly)?;
    locked_ws.locked_wc().rename_workspace(new_name.to_owned());
    tx.repo_mut()
        .rename_workspace(&old_name, new_name.to_owned())
        .map_err(|e| match e {
            RenameWorkspaceError::WorkspaceAlreadyExists { name } => MutateError::WorkspaceExists {
                name: name.as_str().to_owned(),
            },
            other @ RenameWorkspaceError::WorkspaceDoesNotExist { .. } => be(other),
        })?;
    store.rename(&old_name, new_name).map_err(be)?;
    let new_repo = pollster::block_on(tx.commit(format!(
        "Renamed workspace '{}' to '{}'",
        old_name.as_symbol(),
        new_name.as_symbol()
    )))
    .map_err(be)?;
    pollster::block_on(locked_ws.finish(new_repo.op_id().clone())).map_err(be)?;
    // The raw commit's result shape: the new op, `@` under the NEW name, no finish facts.
    mutate::no_op_result(new_name, &new_repo)
}

/// The CLI's `map_workspace_load_error` (`cli/src/cli_util.rs:2906-2940` @ v0.46.0) for a
/// workspace loaded at `path` (no user-given spelling): its user errors refuse
/// [`MutateError::InvalidInput`], its internal errors [`MutateError::Backend`].
fn workspace_load_error(err: WorkspaceLoadError) -> MutateError {
    use jj_lib::repo::StoreLoadError;
    match err {
        WorkspaceLoadError::NoWorkspaceHere(path) => {
            let message = format!(r#"There is no jj repo in "{}""#, path.display());
            if path.join(".git").is_dir() {
                MutateError::invalid_hinted(
                    message,
                    "It looks like this is a git repo. You can create a jj repo backed by it by running this:\njj git init",
                )
            } else {
                MutateError::invalid(message)
            }
        }
        WorkspaceLoadError::RepoDoesNotExist(dir) => MutateError::invalid(format!(
            "The repository directory at {} is missing. Was it moved?",
            dir.display()
        )),
        WorkspaceLoadError::StoreLoadError(err @ StoreLoadError::UnsupportedType { .. }) => be(format!(
            "This version of the jj binary doesn't support this type of repo: {}",
            flatten_chain(&err)
        )),
        WorkspaceLoadError::StoreLoadError(err @ (StoreLoadError::ReadError { .. } | StoreLoadError::Backend(_))) => {
            be(format!(
                "The repository appears broken or inaccessible: {}",
                flatten_chain(&err)
            ))
        }
        WorkspaceLoadError::StoreLoadError(StoreLoadError::Signing(err)) => MutateError::invalid(err.to_string()),
        WorkspaceLoadError::WorkingCopyState(err) => be(flatten_chain(&err)),
        err @ (WorkspaceLoadError::DecodeRepoPath(_) | WorkspaceLoadError::Path(_)) => {
            MutateError::invalid(err.to_string())
        }
    }
}

/// `remove`'s per-name checks (`remove.rs:91-130` @ v0.47.0), in order: the recorded path, its
/// canonical form, the repository inside it, the workspace loaded there and its repository.
fn removable(
    current: &Workspace,
    store: &dyn jj_lib::workspace_store::WorkspaceStore,
    name: &WorkspaceName,
) -> Result<(PathBuf, Workspace), MutateError> {
    let symbol = name.as_symbol();
    let path = store.get_workspace_path(name).map_err(be)?.ok_or_else(|| {
        MutateError::invalid_hinted(
            format!("Cannot remove unreachable workspace '{symbol}'"),
            USE_WORKSPACE_FORGET_HINT,
        )
    })?;
    let path = std::fs::canonicalize(&path).map_err(|e| {
        MutateError::invalid_hinted(
            format!("Cannot access workspace '{symbol}' directory: {e}"),
            USE_WORKSPACE_FORGET_HINT,
        )
    })?;
    // The repository lives under the main workspace; no forget hint, as in the CLI.
    if current.repo_path().starts_with(&path) {
        return Err(MutateError::invalid(format!(
            "Cannot remove workspace '{symbol}' because it contains the repository"
        )));
    }
    let loaded = DefaultWorkspaceLoaderFactory
        .create(&path)
        .and_then(|loader| {
            loader.load(
                current.settings(),
                &default_backend_factories(),
                &default_working_copy_factories(),
            )
        })
        .map_err(workspace_load_error)?;
    if loaded.repo_path() != current.repo_path() {
        return Err(MutateError::invalid_hinted(
            format!("Cannot remove workspace '{symbol}' because it belongs to another repository"),
            USE_WORKSPACE_FORGET_HINT,
        ));
    }
    Ok((path, loaded))
}

/// `remove`'s `snapshot_workspace` on a target workspace (`remove.rs:136-143,192-249` @ v0.47.0):
/// its own start-up environment (warnings repeated, as the CLI prints them again), then a snapshot
/// at the operation its working copy was last recorded at — not the head, so a stale target can
/// be removed too (jj #10276) — with no operation of its own and no Git import. A changed tree
/// becomes a HIDDEN commit on top of the target's `@`, described "SNAPSHOT OF REMOVED WORKSPACE
/// `<name>`", which [`remove`] makes a head; the working copy itself is never finished, its
/// directory is about to go.
///
/// The snapshot knobs are read before the working-copy lock, where the CLI reads them after it:
/// the lock and the operation load write nothing, so only which of two refusals wins differs.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — the snapshot left untracked or non-UTF-8 paths ("Cannot
///   remove workspace '<name>' with unsnapshotted changes"), after their warnings.
fn snapshot_target(target: &mut Workspace, ctx: &mut VerbContext) -> Result<Option<Commit>, MutateError> {
    workable_env(target, ctx)?;
    let name = target.workspace_name().to_owned();
    let root = target.workspace_root().to_owned();
    let matcher = crate::wc_ops::auto_tracking_matcher(&ctx.config, &mut ctx.warnings)?;
    let options = crate::wc_ops::snapshot_options(target, &ctx.config, matcher.as_ref())?;
    let loader = target.repo_loader().clone();
    let mut locked_ws = pollster::block_on(target.start_working_copy_mutation()).map_err(be)?;
    let op = pollster::block_on(loader.load_operation(locked_ws.locked_wc().old_operation_id())).map_err(be)?;
    let repo = pollster::block_on(loader.load_at(&op)).map_err(be)?;
    let Some(wc_commit_id) = repo.view().get_wc_commit_id(&name) else {
        return Ok(None);
    };
    let wc_commit = repo.store().get_commit(wc_commit_id).map_err(be)?;
    let (new_tree, stats) = pollster::block_on(locked_ws.locked_wc().snapshot(&options)).map_err(be)?;
    ctx.warnings.extend(warning::snapshot_stats(&root, &stats));
    if !stats.untracked_paths.is_empty() || !stats.invalid_utf8_paths.is_empty() {
        return Err(MutateError::invalid(format!(
            "Cannot remove workspace '{}' with unsnapshotted changes",
            name.as_symbol()
        )));
    }
    if new_tree.tree_ids_and_labels() == wc_commit.tree().tree_ids_and_labels() {
        return Ok(None);
    }
    // A new commit, not a rewrite of `@`: nothing is rebased while the workspace goes. The
    // transaction is never committed; only the hidden commit it writes is kept.
    let mut tx = start_repo_transaction(&repo, &name);
    let commit = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![wc_commit.id().clone()], new_tree)
            .detach()
            .set_description(format!("SNAPSHOT OF REMOVED WORKSPACE `{}`\n", name.as_symbol()))
            .write_hidden(),
    )
    .map_err(be)?;
    Ok(Some(commit))
}

/// `for_workable_repo`'s start-up environment for `workspace`, built with the call's config into a
/// collector of its own so its load warnings repeat (`workspace_add.rs`'s idiom).
fn workable_env(workspace: &Workspace, ctx: &mut VerbContext) -> Result<CommandEnv, MutateError> {
    let mut own = Warnings::default();
    let env = CommandEnv::load(workspace, &ctx.config, &mut own);
    ctx.warnings.extend(own.take());
    Ok(env?)
}

/// `jj workspace remove` — see [`crate::Repo::workspace_remove`]. The empty-list refusal is the
/// facade's, before the snapshot.
pub(crate) fn remove(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    names: &[String],
) -> Result<WorkspaceRemoveResult, MutateError> {
    let readonly = snapshot::reload_head(workspace).map_err(be)?;
    let names: Vec<WorkspaceNameBuf> = names.iter().map(|n| WorkspaceNameBuf::from(n.as_str())).collect();
    let remove = known_names(&readonly, &names, &mut ctx.warnings);
    if remove.is_empty() {
        return Ok(WorkspaceRemoveResult {
            mutation: mutate::no_op_result(workspace.workspace_name(), &readonly)?,
            git_worktrees_removed: Vec::new(),
            directories_removed: Vec::new(),
        });
    }
    let store = crate::workspace::load_store(workspace).map_err(be)?;
    let targets = remove
        .iter()
        .map(|name| removable(workspace, store.as_ref(), name))
        .collect::<Result<Vec<_>, _>>()?;

    // Each target is snapshotted before its directory goes, so its tracked changes survive.
    let mut paths = Vec::new();
    let mut snapshot_ids = Vec::new();
    for (path, mut target) in targets {
        if let Some(commit) = snapshot_target(&mut target, ctx)? {
            // Only the id: the target's store is not this workspace's.
            snapshot_ids.push(commit.id().clone());
        }
        paths.push(path);
    }

    // The removal builds on the head loaded above, as the CLI's on its start-up repo.
    let mut tx = start_repo_transaction(&readonly, workspace.workspace_name());
    let mut new_change_ids = Vec::new();
    for id in &snapshot_ids {
        let commit = tx.repo().store().get_commit(id).map_err(be)?;
        pollster::block_on(tx.repo_mut().add_head(&commit)).map_err(be)?;
        new_change_ids.push(crate::ChangeId(commit.change_id().reverse_hex()));
    }
    for name in &remove {
        pollster::block_on(tx.repo_mut().remove_workspace(name)).map_err(be)?;
    }
    let finish = mutate::finish_verb(workspace, tx, &description("remove", &remove), ctx)?;
    store
        .forget(&remove.iter().map(AsRef::as_ref).collect::<Vec<_>>())
        .map_err(be)?;
    let git_worktrees_removed = unlink_worktrees(workspace, finish.repo.store(), &paths, &mut ctx.warnings)?;
    let mut directories_removed = Vec::new();
    for path in paths {
        match std::fs::remove_dir_all(&path) {
            Ok(()) => directories_removed.push(path),
            Err(err) => {
                let mut lines = vec![format!(r#"Failed to remove workspace directory "{}"."#, path.display())];
                lines.extend(warning::caused_by(Some(&err)));
                ctx.warnings
                    .push(WarningKind::WorkspaceDirectoryRemoveFailed, lines.join("\n"));
            }
        }
    }
    Ok(WorkspaceRemoveResult {
        mutation: mutate::mutation_result(&finish, new_change_ids, Vec::new()),
        git_worktrees_removed,
        directories_removed,
    })
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use jj_lib::file_util::PathError;
    use jj_lib::ref_name::WorkspaceNameBuf;
    use jj_lib::repo::StoreLoadError;
    use jj_lib::working_copy::WorkingCopyStateError;
    use jj_lib::workspace::WorkspaceLoadError;

    use super::{description, workspace_load_error};

    /// The mapped error's `Display` (`invalid input: …` / `jj-lib error: …`) and hints.
    fn mapped(err: WorkspaceLoadError) -> (String, Vec<String>) {
        let mapped = workspace_load_error(err);
        (mapped.to_string(), mapped.hints())
    }

    /// `map_workspace_load_error`'s split (`cli_util.rs:2906-2940` @ v0.46.0): its user errors
    /// refuse as invalid input with the CLI's texts, its internal errors are backend failures.
    #[test]
    fn a_workspace_load_error_maps_like_the_clis() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().to_owned();
        assert_eq!(
            mapped(WorkspaceLoadError::NoWorkspaceHere(path.clone())),
            (
                format!(r#"invalid input: There is no jj repo in "{}""#, path.display()),
                vec![]
            )
        );
        std::fs::create_dir(path.join(".git")).expect("mkdir .git");
        assert_eq!(
            mapped(WorkspaceLoadError::NoWorkspaceHere(path.clone())).1,
            ["It looks like this is a git repo. You can create a jj repo backed by it by running this:\njj git init"]
        );
        assert_eq!(
            mapped(WorkspaceLoadError::RepoDoesNotExist(PathBuf::from("/gone/repo"))).0,
            "invalid input: The repository directory at /gone/repo is missing. Was it moved?"
        );
        let unsupported = mapped(WorkspaceLoadError::StoreLoadError(StoreLoadError::UnsupportedType {
            store: "commit",
            store_type: "x".to_owned(),
        }));
        assert!(unsupported
            .0
            .starts_with("jj-lib error: This version of the jj binary doesn't support this type of repo: "));
        let unreadable = mapped(WorkspaceLoadError::StoreLoadError(StoreLoadError::ReadError {
            store: "commit",
            source: PathError {
                path: path.clone(),
                source: std::io::Error::other("boom"),
            },
        }));
        assert!(unreadable
            .0
            .starts_with("jj-lib error: The repository appears broken or inaccessible: "));
        let state = mapped(WorkspaceLoadError::WorkingCopyState(WorkingCopyStateError {
            message: "bad state".to_owned(),
            err: "inner".into(),
        }));
        assert_eq!(state.0, "jj-lib error: bad state: inner");
        let path_error = mapped(WorkspaceLoadError::Path(PathError {
            path,
            source: std::io::Error::other("denied"),
        }));
        assert!(path_error.0.starts_with("invalid input: "));
    }

    #[test]
    fn the_description_names_one_or_several_workspaces() {
        let names = |n: &[&str]| n.iter().map(|s| WorkspaceNameBuf::from(*s)).collect::<Vec<_>>();
        assert_eq!(description("forget", &names(&["ws2"])), "forget workspace ws2");
        assert_eq!(
            description("remove", &names(&["ws2", "a b"])),
            "remove workspaces ws2, \"a b\""
        );
    }
}
