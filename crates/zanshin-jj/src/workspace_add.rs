// SPDX-License-Identifier: MIT

//! `workspace_add.rs` — `jj workspace add` (Story 9.23): a second (third, …) workspace of the
//! repo, ported step for step from `cmd_workspace_add` (`cli/src/commands/workspace/add.rs:
//! 110-280` @ v0.46.0). Terminal text is not ported; its facts ride [`WorkspaceAddResult`] and
//! the one `ui.warning_default` the call's warnings.
//!
//! The steps, in the CLI's order — every refusal where the CLI refuses, so a refusal leaves
//! exactly what the CLI leaves:
//!
//! 1. the pre-verb snapshot of the CURRENT workspace ([`crate::Repo`]'s precondition);
//! 2. the destination — the current workspace root joined with `destination` — and the name
//!    (`--name`, else the destination's final component); an empty name and an existing name
//!    refuse;
//! 3. the destination directory is created, or must be an empty directory;
//! 4. the Git worktree, when colocation is asked for or defaulted (`git.colocate`, read only for
//!    a colocated current workspace);
//! 5. jj-lib's `Workspace::init_workspace_with_existing_repo` — the `.jj/repo` FILE, the working
//!    copy, the store entry and jj-lib's own `add workspace '<name>'` operation; the
//!    no-separator warning;
//! 6. a colocated NEW workspace's `.jj/.gitignore`; the sparse patterns (copied, full or empty);
//! 7. one transaction on the NEW workspace: the new `@` on the old `@`'s parents or on the
//!    `revisions`' union (evaluated in the OLD workspace's context), a non-empty `-m` with
//!    `templates.commit_trailers` added (rendered for the NEW workspace, Story 9.51 — a template
//!    fault refuses here, after steps 3-6, exactly where the CLI refuses), committed as `create initial
//!    working-copy commit in workspace <name>` through the CLI's `finish_transaction`, which
//!    checks the new `@` out into the destination and, colocated, resets its Git HEAD.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures::StreamExt as _;
use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::commit::Commit;
use jj_lib::default_backend_factories::default_working_copy_factory;
use jj_lib::file_util;
use jj_lib::git;
use jj_lib::ref_name::{WorkspaceName, WorkspaceNameBuf};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::rewrite::merge_commit_trees;
use jj_lib::workspace::Workspace;

use crate::mutate::{self, be, cfg, flatten_chain, rev, FinishCtx, MutateError, MutationResult};
use crate::op_support::{join_message_paragraphs, start_repo_transaction};
use crate::snapshot::{lock_git_import_export, VerbContext};
use crate::stale::CheckoutStats;
use crate::template::Templates;
use crate::warning::WarningKind;
use crate::{ChangeId, Repo};

/// How the new workspace's sparse patterns are set — the CLI's `--sparse-patterns`
/// (`cli/src/commands/workspace/add.rs:43-52` @ v0.46.0), whose default is [`Self::Copy`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum SparseInheritance {
    /// Copy the current workspace's sparse patterns.
    #[default]
    Copy,
    /// Include every file (the pattern `.`).
    Full,
    /// No file at all (the workspace starts empty).
    Empty,
}

/// What [`crate::Repo::workspace_add`] did (Story 9.23).
#[derive(Debug)]
pub struct WorkspaceAddResult {
    /// The mutation contract of the call's LAST operation, `create initial working-copy commit
    /// in workspace <name>`: its id, the new `@`'s change id (in `new_change_ids` and as
    /// `working_copy_change_id` — the NEW workspace's `@`) and the colocated finish's export
    /// failures.
    pub mutation: MutationResult,
    /// The new workspace's name.
    pub workspace_name: String,
    /// The new workspace's root directory, absolute and canonical.
    pub workspace_root: PathBuf,
    /// Whether a Git worktree was created for it (`--colocate`, or the colocated default).
    pub git_worktree_created: bool,
    /// What checking the new `@` out into the destination did.
    pub checkout: CheckoutStats,
}

/// [`crate::Repo::workspace_add`]'s parameters, one-to-one the CLI's arguments.
pub(crate) struct AddArgs<'a> {
    pub(crate) destination: &'a str,
    pub(crate) name: Option<&'a str>,
    pub(crate) revisions: &'a [String],
    pub(crate) message_paragraphs: &'a [String],
    pub(crate) colocate: Option<bool>,
    pub(crate) sparse: SparseInheritance,
}

/// The CLI's warning for a destination without a path separator (`add.rs:184-191` @ v0.46.0).
fn in_current_directory_warning(destination: &str, name: &WorkspaceName) -> String {
    format!(
        r#"Workspace created inside current directory. If this was unintentional, delete the "{destination}" directory and run `jj workspace forget {name}` to remove it."#,
        name = name.as_symbol()
    )
}

/// The destination and the new workspace's name — the CLI's `command.cwd().join(destination)`
/// with the current workspace root as the working directory, and `--name` or the destination's
/// final component. Refuses what the CLI refuses (an empty name) and what makes it PANIC (no
/// final component: `x/..`, `/`), before anything is written.
fn destination_and_name(workspace_root: &Path, args: &AddArgs<'_>) -> Result<(PathBuf, WorkspaceNameBuf), MutateError> {
    let destination = workspace_root.join(args.destination);
    let name = match args.name {
        Some(name) => name.to_owned(),
        None => destination
            .file_name()
            .ok_or_else(|| MutateError::InvalidInput {
                reason: format!("Destination path {:?} has no final component", args.destination),
            })?
            .to_str()
            .ok_or_else(|| MutateError::InvalidInput {
                reason: "Destination path is not valid UTF-8".to_owned(),
            })?
            .to_owned(),
    };
    if name.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "New workspace name cannot be empty".to_owned(),
        });
    }
    Ok((destination, WorkspaceNameBuf::from(name)))
}

/// `jj workspace add` — see the module docs.
///
/// # Errors
///
/// See [`crate::Repo::workspace_add`].
pub(crate) fn add(
    repo: &mut Repo,
    ctx: &mut VerbContext,
    args: &AddArgs<'_>,
) -> Result<WorkspaceAddResult, MutateError> {
    let old_repo = crate::snapshot::load_head(repo.workspace()).map_err(MutateError::from)?;
    let old_name = repo.workspace().workspace_name().to_owned();
    let (destination, name) = destination_and_name(repo.workspace_root(), args)?;
    if old_repo.view().get_wc_commit_id(&name).is_some() {
        return Err(MutateError::WorkspaceExists {
            name: name.as_str().to_owned(),
        });
    }
    if !destination.exists() {
        std::fs::create_dir(&destination).map_err(|e| be(format!("{}: {e}", destination.display())))?;
    } else if !file_util::is_empty_dir(&destination).map_err(|e| be(flatten_chain(&e)))? {
        return Err(MutateError::DestinationNotEmpty);
    }

    let should_colocate = match args.colocate {
        Some(colocate) => colocate,
        None => ctx.colocated && crate::config::git_colocate(&ctx.config).map_err(cfg)?,
    };
    if should_colocate {
        let options = crate::environment::git_subprocess_options(repo.workspace().settings(), None).map_err(cfg)?;
        git::create_worktree(old_repo.store(), options, &destination)
            .map_err(|e| MutateError::GitWorktree(flatten_chain(&e)))?;
    }

    let (mut new_workspace, new_repo) = pollster::block_on(Workspace::init_workspace_with_existing_repo(
        &destination,
        repo.workspace().repo_path(),
        &old_repo,
        default_working_copy_factory().as_ref(),
        name.clone(),
    ))
    .map_err(|e| be(flatten_chain(&e)))?;
    if !args.destination.contains(std::path::is_separator) {
        ctx.warnings.push(
            WarningKind::WorkspaceInCurrentDirectory,
            in_current_directory_warning(args.destination, &name),
        );
    }

    let new_colocated = crate::wc_ops::is_colocated_git_workspace(&new_workspace).map_err(|e| be(flatten_chain(&e)))?;
    crate::convert::maybe_add_gitignore(new_workspace.workspace_root(), new_colocated)
        .map_err(|e| be(format!("Failed to write .jj/.gitignore file: {e}")))?;
    set_sparse_patterns(repo.workspace(), &mut new_workspace, &new_repo, args.sparse)?;

    let mut tx = start_repo_transaction(&new_repo, &name);
    let parents = if args.revisions.is_empty() {
        match tx.base_repo().view().get_wc_commit_id(&old_name) {
            Some(old_wc_id) => {
                let old_wc = tx.repo().store().get_commit(old_wc_id).map_err(be)?;
                pollster::block_on(old_wc.parents()).map_err(be)?
            }
            None => vec![tx.repo().store().root_commit()],
        }
    } else {
        resolve_some_revsets(repo, ctx, &old_repo, args.revisions)?
            .iter()
            .map(|id| tx.repo().store().get_commit(id).map_err(be))
            .collect::<Result<Vec<Commit>, _>>()?
    };
    let tree = pollster::block_on(merge_commit_trees(tx.repo(), &parents)).map_err(be)?;
    let parent_ids = parents.iter().map(|c| c.id().clone()).collect();
    let mut builder = tx.repo_mut().new_commit(parent_ids, tree).detach();
    builder.set_description(join_message_paragraphs(args.message_paragraphs));
    // `add.rs:257-265`: a non-empty `-m` gets the trailers, rendered for the NEW workspace.
    if !builder.description().is_empty() {
        let templates = Templates::at(&ctx.config, &ctx.immutable, &name, new_workspace.workspace_root());
        let description = templates.add_trailers(tx.repo(), &builder, &mut ctx.warnings)?;
        builder.set_description(description);
    }
    let new_wc_commit = pollster::block_on(builder.write(tx.repo_mut())).map_err(be)?;
    pollster::block_on(tx.repo_mut().edit(name.clone(), &new_wc_commit)).map_err(be)?;
    // `edit` abandons the discardable initial working-copy commit jj-lib created; `tx.finish`'s
    // `rebase_mutable_descendants` (`cli_util.rs:2855`) settles that rewrite before the commit.
    pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;

    let lock = lock_git_import_export(&new_workspace, new_colocated)?;
    let finish = mutate::finish_transaction(
        &mut new_workspace,
        tx,
        &format!("create initial working-copy commit in workspace {}", name.as_symbol()),
        &FinishCtx {
            immutable: &ctx.immutable,
            colocated: new_colocated,
            _lock: &lock,
        },
        &mut ctx.warnings,
    )?;
    let mutation = mutate::mutation_result(
        &finish,
        vec![ChangeId(new_wc_commit.change_id().reverse_hex())],
        Vec::new(),
    )?;
    Ok(WorkspaceAddResult {
        mutation,
        workspace_name: name.as_str().to_owned(),
        workspace_root: new_workspace.workspace_root().to_owned(),
        git_worktree_created: should_colocate,
        checkout: finish.checkout.unwrap_or_default(),
    })
}

/// The `--sparse-patterns` step (`add.rs:199-221` @ v0.46.0): `Copy` reads the CURRENT
/// workspace's patterns, `Full` leaves jj-lib's default (everything), `Empty` clears them — set
/// through the locked NEW working copy (`start_working_copy_mutation`) and recorded at its
/// unchanged operation.
fn set_sparse_patterns(
    old_workspace: &Workspace,
    new_workspace: &mut Workspace,
    new_repo: &Arc<ReadonlyRepo>,
    sparse: SparseInheritance,
) -> Result<(), MutateError> {
    let patterns = match sparse {
        SparseInheritance::Full => return Ok(()),
        SparseInheritance::Empty => Vec::new(),
        SparseInheritance::Copy => old_workspace.working_copy().sparse_patterns().map_err(be)?.to_vec(),
    };
    let (mut locked_ws, _wc_commit) = mutate::lock_working_copy(new_workspace, new_repo)?;
    pollster::block_on(locked_ws.locked_wc().set_sparse_patterns(patterns))
        .map_err(|e| be(format!("Failed to set sparse patterns: {}", flatten_chain(&e))))?;
    let operation_id = locked_ws.locked_wc().old_operation_id().clone();
    pollster::block_on(locked_ws.finish(operation_id)).map_err(be)
}

/// The CLI's `resolve_some_revsets` (`cli/src/cli_util.rs:1846-1873` @ v0.46.0): every revset
/// parsed in the CURRENT workspace's context and evaluated against `old_repo` in turn, the
/// commit ids collected in argument order without duplicates; an empty union refuses.
fn resolve_some_revsets(
    repo: &Repo,
    ctx: &mut VerbContext,
    old_repo: &Arc<ReadonlyRepo>,
    revisions: &[String],
) -> Result<Vec<JjCommitId>, MutateError> {
    let mut ids: Vec<JjCommitId> = Vec::new();
    for revision in revisions {
        let expression = crate::revset::parse_revset(repo, revision, &mut ctx.warnings).map_err(rev)?;
        let set = crate::revset::evaluate_revset(old_repo.as_ref(), &expression).map_err(rev)?;
        pollster::block_on(async {
            let mut stream = set.stream();
            while let Some(id) = stream.next().await {
                let id = id.map_err(be)?;
                if !ids.contains(&id) {
                    ids.push(id);
                }
            }
            Ok::<(), MutateError>(())
        })?;
    }
    if ids.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "Empty revision set".to_owned(),
        });
    }
    Ok(ids)
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{destination_and_name, in_current_directory_warning, AddArgs, SparseInheritance};
    use crate::MutateError;

    fn args<'a>(destination: &'a str, name: Option<&'a str>) -> AddArgs<'a> {
        AddArgs {
            destination,
            name,
            revisions: &[],
            message_paragraphs: &[],
            colocate: None,
            sparse: SparseInheritance::default(),
        }
    }

    #[test]
    fn the_name_defaults_to_the_final_component() {
        let (dest, name) = destination_and_name(Path::new("/r/ws"), &args("../ws2", None)).expect("ok");
        assert_eq!(dest, Path::new("/r/ws/../ws2"));
        assert_eq!(name.as_str(), "ws2");
        let (dest, name) = destination_and_name(Path::new("/r/ws"), &args("/abs/x", Some("y"))).expect("ok");
        assert_eq!(dest, Path::new("/abs/x"));
        assert_eq!(name.as_str(), "y");
    }

    #[test]
    fn an_empty_name_or_no_final_component_refuses() {
        assert!(matches!(
            destination_and_name(Path::new("/r"), &args("x", Some(""))),
            Err(MutateError::InvalidInput { reason }) if reason == "New workspace name cannot be empty"
        ));
        assert!(matches!(
            destination_and_name(Path::new("/r"), &args("x/..", None)),
            Err(MutateError::InvalidInput { .. })
        ));
    }

    /// The default name is the destination's final component, which must be UTF-8: an empty
    /// destination names the workspace after the current root's own last component.
    #[cfg(unix)]
    #[test]
    fn a_non_utf8_final_component_refuses() {
        use std::os::unix::ffi::OsStrExt as _;

        let root = Path::new(std::ffi::OsStr::from_bytes(b"/r/\xff"));
        assert!(matches!(
            destination_and_name(root, &args("", None)),
            Err(MutateError::InvalidInput { reason }) if reason == "Destination path is not valid UTF-8"
        ));
    }

    #[test]
    fn the_in_current_directory_warning_is_the_clis() {
        assert_eq!(
            in_current_directory_warning("ws2", jj_lib::ref_name::WorkspaceName::new("ws2")),
            "Workspace created inside current directory. If this was unintentional, delete the \"ws2\" directory and run `jj workspace forget ws2` to remove it."
        );
    }
}
