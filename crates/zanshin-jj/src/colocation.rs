// SPDX-License-Identifier: MIT

//! `colocation.rs` — `jj git colocation status | enable | disable` (Story 9.45), ported step for
//! step from `cmd_git_colocation_{status,enable,disable}` (`cli/src/commands/git/colocation.rs`
//! @ v0.46.0): whether a workspace shares its working copy with Git, and the conversion of an
//! EXISTING workspace between colocated and non-colocated — the default workspace by moving the
//! Git repository between `.jj/repo/store/git` and `<root>/.git`, a child workspace by creating
//! or removing its Git worktree.
//!
//! All three run after the pre-verb snapshot ([`crate::Repo`]'s precondition, the CLI's
//! `workspace_helper`), whose colocation check is the one each verb reads (`ctx.colocated`).
//!
//! Deliberate divergences:
//!
//! - **Status lines as typed facts**: `status`'s two stdout lines are [`GitColocationStatus`]'s
//!   fields and its hint line its `hints`; "Workspace is already (not) colocated with Git." is
//!   [`GitColocationResult::converted`] `false` with the pre-call head; "Removed Git worktree for
//!   …" is [`GitColocationResult::git_worktree_removed`]; the "successfully converted" lines are
//!   `converted: true`.
//! - **No rollback**: a failure after the move leaves the disk as the CLI leaves it. The handle's
//!   workspace is replaced by the reloaded one right after the move — `GitBackend` caches the Git
//!   repository's path at load, as the CLI's `reload_workspace_helper` knows.

use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::git;
use jj_lib::op_store::{OperationId, RefTarget};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;

use crate::mutate::{self, be, cfg, flatten_chain, MutateError, MutationResult};
use crate::op_diff::{ref_target, OpRefTarget};
use crate::op_support::start_repo_transaction;
use crate::snapshot::{self, VerbContext};

/// `status`' hint for a colocated workspace (`colocation.rs:124-127` @ v0.46.0).
const DISABLE_HINT: &str = "To disable colocation, run: `jj git colocation disable`";
/// `status`' hint for a workspace backed by an external Git repository.
const EXTERNAL_HINT: &str =
    "Colocation cannot be enabled because the workspace is backed by an external Git repository.";
/// `status`' hint for every other non-colocated workspace.
const ENABLE_HINT: &str = "To enable colocation, run: `jj git colocation enable`";

/// What [`crate::Repo::git_colocation_status`] read (Story 9.45) — the CLI's status lines as facts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitColocationStatus {
    /// Whether the workspace shares its working copy with Git — "Workspace '<name>' is currently
    /// (not) colocated with Git."
    pub colocated: bool,
    /// The workspace's name.
    pub workspace_name: String,
    /// The view's Git HEAD of this workspace — "Last imported/exported Git HEAD: …"; absent
    /// (`adds` empty) in a non-colocated workspace.
    pub git_head: OpRefTarget,
    /// The backing Git repository's path (its `.git` directory, or the repository itself when
    /// bare) — in a child workspace the MAIN repository's, not the child's `.git` gitlink.
    pub git_repo_path: PathBuf,
    /// Whether the workspace is backed by an external Git repository (`jj git init
    /// --git-repo=…`): not colocated, not a child workspace, and no `.jj/repo/store/git`.
    /// Colocation cannot be enabled then.
    pub external_git_repo: bool,
    /// The CLI's one hint line, without `Hint: `.
    pub hints: Vec<String>,
}

/// What [`crate::Repo::git_colocation_enable`] / [`crate::Repo::git_colocation_disable`] did
/// (Story 9.45).
#[derive(Debug)]
pub struct GitColocationResult {
    /// The call's operation, `set git head to working copy parent` / `remove git head
    /// reference` — or the pre-call head when nothing changed or nothing was converted.
    pub mutation: MutationResult,
    /// Whether the workspace was converted; `false` is the CLI's "Workspace is already
    /// colocated with Git." / "Workspace is already not colocated with Git.".
    pub converted: bool,
    /// Whether `disable` removed a child workspace's Git worktree — the CLI's "Removed Git
    /// worktree for …". Always `false` for `enable` and for the default workspace.
    pub git_worktree_removed: bool,
}

/// The CLI's `is_child_workspace`: a secondary workspace's `.jj/repo` is a FILE.
fn is_child_workspace(workspace_root: &Path) -> bool {
    workspace_root.join(".jj").join("repo").is_file()
}

/// The workspace's Git backend, or [`MutateError::NotAGitRepo`] — the CLI's `get_git_backend`.
fn git_repo_path(repo: &ReadonlyRepo) -> Result<PathBuf, MutateError> {
    let backend = git::get_git_backend(repo.store()).map_err(|_| MutateError::NotAGitRepo)?;
    Ok(backend.git_repo_path().to_owned())
}

/// `jj git colocation status` — see [`crate::Repo::git_colocation_status`].
pub(crate) fn status(workspace: &Workspace, ctx: &VerbContext) -> Result<GitColocationStatus, MutateError> {
    let repo = snapshot::reload_head(workspace).map_err(be)?;
    let git_repo_path = git_repo_path(&repo)?;
    let name = workspace.workspace_name();
    let colocated = ctx.colocated;
    let external_git_repo = !colocated
        && !is_child_workspace(workspace.workspace_root())
        && !workspace.repo_path().join("store").join("git").exists();
    let hint = if colocated {
        DISABLE_HINT
    } else if external_git_repo {
        EXTERNAL_HINT
    } else {
        ENABLE_HINT
    };
    Ok(GitColocationStatus {
        colocated,
        workspace_name: name.as_str().to_owned(),
        git_head: ref_target(repo.view().git_head(name)),
        git_repo_path,
        external_git_repo,
        hints: vec![hint.to_owned()],
    })
}

/// The pre-call head as the result of a call that converts nothing.
fn not_converted(workspace: &Workspace, repo: &Arc<ReadonlyRepo>) -> Result<GitColocationResult, MutateError> {
    Ok(GitColocationResult {
        mutation: mutate::no_op_result(workspace.workspace_name(), repo)?,
        converted: false,
        git_worktree_removed: false,
    })
}

/// `enable`'s mapping of the failed move (`colocation.rs:186-200` @ v0.46.0).
fn enable_move_error(err: &std::io::Error, git_repo_path: &Path) -> MutateError {
    match err.kind() {
        ErrorKind::AlreadyExists | ErrorKind::DirectoryNotEmpty => {
            MutateError::invalid("A .git directory already exists in the workspace root. Cannot colocate.")
        }
        ErrorKind::NotFound => MutateError::invalid(format!(
            "Cannot colocate a workspace backed by an external Git repository at {}",
            git_repo_path.display()
        )),
        _ => MutateError::invalid(format!(
            "Failed to move Git repository from .jj/repo/store/git to workspace root directory.: {err}"
        )),
    }
}

/// The CLI's `set_git_repo_bare`: `core.bare` in the Git config file at `<git_dir>/config`.
fn set_git_repo_bare(git_dir: &Path, bare: bool) -> Result<(), MutateError> {
    let value = if bare { "true" } else { "false" };
    let config_path = git_dir.join("config");
    let mut config = gix::config::File::from_path_no_includes(config_path.clone(), gix::config::Source::Local)
        .map_err(|e| MutateError::invalid(format!("Failed to open Git config file.: {e}")))?;
    config
        .set_raw_value("core.bare", value)
        .map_err(|e| MutateError::invalid(format!("Failed to set core.bare to {value} in Git config.: {e}")))?;
    git::save_git_config(&config).map_err(|e| {
        MutateError::invalid(format!(
            "Failed to write to Git config file at {}.: {e}",
            config_path.display()
        ))
    })
}

/// Writes `store/git_target` (the CLI's `std::fs::write(…).context(path)`).
fn write_git_target(repo_path: &Path, content: &str) -> Result<(), MutateError> {
    let path = repo_path.join("store").join("git_target");
    std::fs::write(&path, content).map_err(|e| be(format!("{}: {e}", path.display())))
}

/// The CLI's `reload_workspace_helper`: the workspace reloaded from disk into the handle, its
/// repository loaded at `op_id` (the pre-move operation), and the colocation re-checked for the
/// finish.
fn reload(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    op_id: &OperationId,
) -> Result<Arc<ReadonlyRepo>, MutateError> {
    let settings = workspace.settings().clone();
    let root = workspace.workspace_root().to_owned();
    *workspace = Workspace::load(
        &settings,
        &root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .map_err(be)?;
    let loader = workspace.repo_loader();
    let op = pollster::block_on(loader.load_operation(op_id)).map_err(be)?;
    let repo = pollster::block_on(loader.load_at(&op)).map_err(be)?;
    ctx.colocated = crate::wc_ops::is_colocated_git_workspace(workspace).map_err(|e| be(flatten_chain(&e)))?;
    Ok(repo)
}

/// `steps`' error, after the handle was still reloaded onto the moved repository — the reload's
/// own result dropped (no rollback: the disk stays as the failed step left it, as in the CLI).
fn reload_on_error(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    op_id: &OperationId,
    steps: Result<(), MutateError>,
) -> Result<(), MutateError> {
    steps.inspect_err(|_| {
        let _ = reload(workspace, ctx, op_id);
    })
}

/// `jj git colocation enable` — see [`crate::Repo::git_colocation_enable`].
pub(crate) fn enable(workspace: &mut Workspace, ctx: &mut VerbContext) -> Result<GitColocationResult, MutateError> {
    let repo = snapshot::reload_head(workspace).map_err(be)?;
    let git_repo_path = git_repo_path(&repo)?;
    if ctx.colocated {
        return not_converted(workspace, &repo);
    }
    let name = workspace.workspace_name().to_owned();
    let wc_commit_id = repo
        .view()
        .get_wc_commit_id(&name)
        .ok_or(MutateError::NoWorkingCopy)?
        .clone();
    let root = workspace.workspace_root().to_owned();
    let op_id = repo.op_id().clone();

    if is_child_workspace(&root) {
        let options = crate::environment::git_subprocess_options(workspace.settings(), None).map_err(cfg)?;
        git::create_worktree(repo.store(), options, &root).map_err(|e| MutateError::GitWorktree(flatten_chain(&e)))?;
    } else {
        let repo_path = workspace.repo_path().to_owned();
        let dot_git = root.join(".git");
        std::fs::rename(repo_path.join("store").join("git"), &dot_git)
            .map_err(|e| enable_move_error(&e, &git_repo_path))?;
        let moved = write_git_target(&repo_path, "../../../.git").and_then(|()| set_git_repo_bare(&dot_git, false));
        reload_on_error(workspace, ctx, &op_id, moved)?;
    }

    let repo = reload(workspace, ctx, &op_id)?;
    crate::convert::maybe_add_gitignore(&root, ctx.colocated)
        .map_err(|e| MutateError::invalid(format!("Failed to write .jj/.gitignore file: {e}")))?;
    let wc_commit = repo.store().get_commit(&wc_commit_id).map_err(be)?;
    let mut tx = start_repo_transaction(&repo, &name);
    pollster::block_on(git::reset_head(tx.repo_mut(), &name, &root, &wc_commit))
        .map_err(|e| be(format!("Failed to reset Git HEAD state: {}", flatten_chain(&e))))?;
    let finish = mutate::finish_verb(workspace, tx, "set git head to working copy parent", ctx)?;
    Ok(GitColocationResult {
        mutation: mutate::mutation_result(&finish, Vec::new(), Vec::new()),
        converted: true,
        git_worktree_removed: false,
    })
}

/// `jj git colocation disable` — see [`crate::Repo::git_colocation_disable`].
pub(crate) fn disable(workspace: &mut Workspace, ctx: &mut VerbContext) -> Result<GitColocationResult, MutateError> {
    let repo = snapshot::reload_head(workspace).map_err(be)?;
    git_repo_path(&repo)?;
    if !ctx.colocated {
        return not_converted(workspace, &repo);
    }
    let name = workspace.workspace_name().to_owned();
    let root = workspace.workspace_root().to_owned();
    let op_id = repo.op_id().clone();

    let git_worktree_removed = if is_child_workspace(&root) {
        let unlinked = crate::workspace_ops::unlink_worktrees(
            workspace,
            repo.store(),
            std::slice::from_ref(&root),
            &mut ctx.warnings,
        )?;
        !unlinked.is_empty()
    } else {
        let repo_path = workspace.repo_path().to_owned();
        let store_git = repo_path.join("store").join("git");
        std::fs::rename(root.join(".git"), &store_git)
            .map_err(|e| MutateError::invalid(format!("Failed to move Git repository to .jj/repo/store/git: {e}")))?;
        let moved = set_git_repo_bare(&store_git, true).and_then(|()| write_git_target(&repo_path, "git"));
        reload_on_error(workspace, ctx, &op_id, moved)?;
        false
    };
    // Git no longer needs to ignore jj's directory; a missing file is fine, as in the CLI.
    std::fs::remove_file(root.join(".jj").join(".gitignore")).ok();

    let repo = reload(workspace, ctx, &op_id)?;
    let mut tx = start_repo_transaction(&repo, &name);
    tx.repo_mut().set_git_head_target(&name, RefTarget::absent());
    let finish = mutate::finish_verb(workspace, tx, "remove git head reference", ctx)?;
    Ok(GitColocationResult {
        mutation: mutate::mutation_result(&finish, Vec::new(), Vec::new()),
        converted: true,
        git_worktree_removed,
    })
}

#[cfg(test)]
mod tests {
    use std::io::{Error, ErrorKind};
    use std::os::unix::fs::PermissionsExt as _;
    use std::path::Path;

    use super::{enable_move_error, set_git_repo_bare};
    use crate::MutateError;

    fn reason(err: &MutateError) -> String {
        assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
        err.to_string()
            .strip_prefix("invalid input: ")
            .expect("prefix")
            .to_owned()
    }

    #[test]
    fn the_failed_move_maps_like_the_clis() {
        let path = Path::new("/ext/repo/.git");
        let exists = "A .git directory already exists in the workspace root. Cannot colocate.";
        assert_eq!(
            reason(&enable_move_error(&Error::from(ErrorKind::AlreadyExists), path)),
            exists
        );
        assert_eq!(
            reason(&enable_move_error(&Error::from(ErrorKind::DirectoryNotEmpty), path)),
            exists
        );
        assert_eq!(
            reason(&enable_move_error(&Error::from(ErrorKind::NotFound), path)),
            "Cannot colocate a workspace backed by an external Git repository at /ext/repo/.git"
        );
        assert_eq!(
            reason(&enable_move_error(&Error::other("boom"), path)),
            "Failed to move Git repository from .jj/repo/store/git to workspace root directory.: boom"
        );
    }

    #[test]
    fn core_bare_round_trips_through_the_git_config() {
        let dir = tempfile::tempdir().expect("tempdir");
        let config = dir.path().join("config");
        std::fs::write(&config, "[core]\n\tbare = true\n").expect("write config");
        set_git_repo_bare(dir.path(), false).expect("set false");
        assert!(std::fs::read_to_string(&config).expect("read").contains("bare = false"));
        set_git_repo_bare(dir.path(), true).expect("set true");
        assert!(std::fs::read_to_string(&config).expect("read").contains("bare = true"));
    }

    #[test]
    fn an_unreadable_or_unwritable_git_config_refuses_with_the_clis_messages() {
        let dir = tempfile::tempdir().expect("tempdir");
        let missing = set_git_repo_bare(&dir.path().join("nope"), true).expect_err("missing");
        assert!(
            reason(&missing).starts_with("Failed to open Git config file.: "),
            "{missing:?}"
        );

        let config = dir.path().join("config");
        std::fs::write(&config, "[core]\n\tbare = true\n").expect("write config");
        std::fs::set_permissions(&config, std::fs::Permissions::from_mode(0o444)).expect("chmod");
        let unwritable = set_git_repo_bare(dir.path(), false).expect_err("read-only");
        assert!(
            reason(&unwritable).starts_with(&format!(
                "Failed to write to Git config file at {}.: ",
                config.display()
            )),
            "{unwritable:?}"
        );
    }
}
