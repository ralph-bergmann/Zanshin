// SPDX-License-Identifier: MIT

//! `wc_ops.rs` — the two working-copy tracking verbs, `file track` and `file untrack`
//! (Story 9.22), and the snapshot primitives they share with the pre-verb snapshot
//! ([`crate::snapshot`], Story 9.26). `file chmod` ([`file_chmod`], Story 9.13) lives here too:
//! it parses its paths as these two do — and so do `file edit` / `file delete` ([`file_edit`],
//! [`file_delete`], Story 9.44), which rewrite one revision's tree as `file chmod` does.
//!
//! Both verbs are step-for-step ports of `cmd_file_track` / `cmd_file_untrack`
//! (`cli/src/commands/file/{track,untrack}.rs` @ v0.46.0): lock the working copy through
//! [`mutate::commit_with_locked_wc`], snapshot (and, for untrack, `reset`), commit
//! `track paths` / `untrack paths` UNCONDITIONALLY, and finish the working copy at that
//! operation. The terminal output the CLI prints afterwards is not ported; every fact it
//! would have printed rides the typed result instead.
//!
//! The primitives — [`snapshot_options`] (the CLI's `snapshot_options_with_start_tracking_matcher`
//! over the EFFECTIVE `snapshot.*` config), [`base_ignores`], [`auto_tracking_matcher`],
//! [`project_stats`] and [`merge_track_stats`] — each have exactly one definition here.
//!
//! # `@` after `track` (GH #8298)
//!
//! The CLI DISCARDS the tree its `track` snapshot produces: the `track paths` operation leaves
//! the view untouched and only the working-copy STATE learns the new path. The next command's
//! own snapshot is what moves it into `@` (and rebases `@`'s children) — the CLI's own test
//! carries "TODO: fix GH #8298 so tracking is immediate". Rewriting `@` here would give the op
//! log different content than the CLI's and make its next snapshot a no-op, so a user could
//! tell which tool wrote the operation. Zanshin's next verb snapshots first too (Story 9.26), so
//! the newly tracked path lands in `@` exactly when it would for a CLI user.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_lib::backend::{MergedTreeValue, MergedTreeValueExt as _, TreeValue};
use jj_lib::commit::Commit;
use jj_lib::config::StackedConfig;
use jj_lib::fileset::{self, FilesetAliasesMap, FilesetDiagnostics, FilesetParseContext};
use jj_lib::fsmonitor::FsmonitorSettings;
use jj_lib::git;
use jj_lib::git_backend::GitRepoAtWorkdirError;
use jj_lib::gitignore::GitIgnoreFile;
use jj_lib::local_working_copy::{EolConversionMode, ExecChangeSetting, TreeState, TreeStateSettings};
use jj_lib::matchers::{EverythingMatcher, Matcher, NothingMatcher, PrefixMatcher};
use jj_lib::merged_tree::MergedTree;
use jj_lib::merged_tree_builder::MergedTreeBuilder;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use jj_lib::transaction::Transaction;
use jj_lib::ui_path::{parse_fs_path, RepoPathUiConverter};
use jj_lib::working_copy::{self, LockedWorkingCopy, SnapshotOptions};
use jj_lib::workspace::Workspace;

use crate::git::{map_export_err, project_failures, GitExportFailure};
use crate::mutate::{self, be, cfg, flatten_chain, MutateError, MutationResult};
use crate::op_support::start_repo_transaction;
use crate::snapshot::VerbContext;
use crate::warning::{self, Load, Warnings};

// ── Result types ─────────────────────────────────────────────────────────────────

/// Why a new file stayed untracked after a snapshot (Story 9.22) — jj-lib's `UntrackedReason`
/// (`working_copy.rs:243-255` @ 0.44.0).
// Member order mirrors the wire union in `schemas/envelope.fbs` — APPEND only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UntrackedReason {
    /// The file is larger than the effective `snapshot.max-new-file-size`.
    FileTooLarge {
        /// The file's size in bytes.
        size: u64,
        /// The limit it exceeded, in bytes.
        max_size: u64,
    },
    /// The file does not match the snapshot's start-tracking fileset (`snapshot.auto-track`, or
    /// the paths a `file track` named).
    FileNotAutoTracked,
}

/// One new file a snapshot left untracked, and why (Story 9.22).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UntrackedPath {
    /// Repo-relative path in jj's internal (`/`-separated) form.
    pub path: String,
    /// Why it stayed untracked.
    pub reason: UntrackedReason,
}

/// What a working-copy snapshot could NOT record (Story 9.22) — jj-lib's `SnapshotStats`, the
/// facts the CLI's `print_snapshot_stats` / `print_track_snapshot_stats` warn about.
///
/// One definition shared by both tracking verbs and by the pre-verb snapshot (Story 9.26).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SnapshotStats {
    /// New files that stayed untracked, in jj-lib's (path) order.
    pub untracked: Vec<UntrackedPath>,
    /// Files skipped because their NAME is not valid UTF-8, rendered as `"<dir>/<name>"`
    /// (the bare name at the repository root) with the name lossily decoded — such a path
    /// cannot be a jj repo path at all, which is why it is only reported.
    pub invalid_utf8_paths: Vec<String>,
}

/// Outcome of a successful [`crate::Repo::file_track`] (Story 9.22).
#[derive(Debug)]
pub struct TrackResult {
    /// The shared mutation contract. An operation is ALWAYS written (the CLI commits
    /// unconditionally); `@` is the pre-call one — see the module doc (GH #8298).
    pub mutation: MutationResult,
    /// Descendants the verb rebased — the CLI's "Rebased {n} descendant commits.". Always `0`
    /// today, since the track snapshot's tree is discarded and nothing is rewritten; it is
    /// computed exactly as the CLI computes it rather than hardcoded. Saturates at `u32::MAX`.
    pub num_rebased: u32,
    /// What the track snapshot left untracked, merged with the pre-verb snapshot's reasons the
    /// way `print_track_snapshot_stats` merges them.
    pub snapshot_stats: SnapshotStats,
}

/// Outcome of a successful [`crate::Repo::file_untrack`] (Story 9.22).
#[derive(Debug)]
pub struct UntrackResult {
    /// The shared mutation contract. An operation is ALWAYS written; `@` is the rewritten
    /// working-copy commit (same change id, the matched entries removed).
    pub mutation: MutationResult,
    /// Descendants of `@` rebased onto the rewritten `@`. Saturates at `u32::MAX`.
    pub num_rebased: u32,
    /// The requested paths that matched no entry of the pre-call `@` tree, in request order —
    /// the CLI's "No matching entries for paths: …" warning (`print_unmatched_explicit_paths`).
    pub unmatched_paths: Vec<String>,
    /// What the post-`reset` snapshot left untracked — the CLI's `print_snapshot_stats(&stats)`.
    pub snapshot_stats: SnapshotStats,
    /// Bookmarks the colocated git export could not write; always empty outside a colocated
    /// workspace, where no export runs.
    pub failed_bookmarks: Vec<GitExportFailure>,
    /// Tags the colocated git export could not write (only `@git` tags — git has no remote
    /// tags); always empty outside a colocated workspace.
    pub failed_tags: Vec<GitExportFailure>,
}

// ── Snapshot primitives ──────────────────────────────────────────────────────────

/// Projects jj-lib's snapshot stats into the owned, `jj_lib`-free [`SnapshotStats`].
pub(crate) fn project_stats(stats: &working_copy::SnapshotStats) -> SnapshotStats {
    SnapshotStats {
        untracked: stats
            .untracked_paths
            .iter()
            .map(|(path, reason)| UntrackedPath {
                path: path.as_internal_file_string().to_owned(),
                reason: match reason {
                    working_copy::UntrackedReason::FileTooLarge { size, max_size } => UntrackedReason::FileTooLarge {
                        size: *size,
                        max_size: *max_size,
                    },
                    working_copy::UntrackedReason::FileNotAutoTracked => UntrackedReason::FileNotAutoTracked,
                },
            })
            .collect(),
        invalid_utf8_paths: stats
            .invalid_utf8_paths
            .iter()
            .map(|(dir, name)| {
                let name = name.to_string_lossy();
                if dir.is_root() {
                    name.into_owned()
                } else {
                    format!("{}/{name}", dir.as_internal_file_string())
                }
            })
            .collect(),
    }
}

/// Merges the pre-verb auto-snapshot's stats into `file track`'s own — the loop of
/// `print_track_snapshot_stats` (`cli/src/commands/file/track.rs` @ v0.46.0).
///
/// The track snapshot marks every new file it was not asked to track `FileNotAutoTracked`; for
/// a path the preceding auto-snapshot already refused, that snapshot's reason (e.g. the file
/// is too large) is the one worth reporting. Every other entry — and the invalid-UTF-8 list —
/// is the track snapshot's own.
pub(crate) fn merge_track_stats(
    mut auto: working_copy::SnapshotStats,
    track: working_copy::SnapshotStats,
) -> working_copy::SnapshotStats {
    let mut untracked_paths = track.untracked_paths;
    for (path, reason) in &mut untracked_paths {
        if !matches!(reason, working_copy::UntrackedReason::FileNotAutoTracked) {
            continue;
        }
        if let Some(old_reason) = auto.untracked_paths.remove(path) {
            *reason = old_reason;
        }
    }
    working_copy::SnapshotStats {
        untracked_paths,
        invalid_utf8_paths: track.invalid_utf8_paths,
    }
}

/// Parses the effective `snapshot.auto-track` into a matcher — the CLI's `auto_tracking_matcher`
/// (`cli/src/cli_util.rs:1635-1642` @ v0.46.0).
///
/// The value is a FILESET expression (`fileset::parse`, not the bare-path form), parsed the way
/// the CLI parses a CONFIG value (`fileset_parse_context_for_config`, `:1037-1046`): with the
/// effective `[fileset-aliases]` and a ROOT path converter, so a relative path in it means
/// "relative to the workspace root", never to some process CWD.
///
/// The `[fileset-aliases]` load's warnings are recorded once per call into `sink` (Story 9.32).
///
/// # Errors
///
/// - [`MutateError::Config`] — the key is not a string, a `[fileset-aliases]` layer is not a
///   table, or the expression does not parse (the reason names `snapshot.auto-track`).
pub(crate) fn auto_tracking_matcher(
    config: &StackedConfig,
    sink: &mut Warnings,
) -> Result<Box<dyn Matcher>, MutateError> {
    let pattern = crate::config::snapshot_auto_track(config).map_err(cfg)?;
    let (aliases_map, warnings): (FilesetAliasesMap, _) =
        crate::revset::build_aliases_map(config, "fileset-aliases").map_err(cfg)?;
    sink.record_load(Load::FilesetAliases, warnings);
    let path_converter = RepoPathUiConverter::Fs {
        cwd: PathBuf::new(),
        base: PathBuf::new(),
    };
    let context = FilesetParseContext {
        aliases_map: &aliases_map,
        path_converter: &path_converter,
    };
    let expression =
        fileset::parse(&mut FilesetDiagnostics::new(), &pattern, &context).map_err(|e| MutateError::Config {
            reason: format!("Invalid `snapshot.auto-track`: {}", flatten_chain(&e)),
        })?;
    Ok(expression.to_matcher())
}

/// The `$XDG_CONFIG_HOME` the CLI's `base_ignores` falls back to: the variable when set and
/// non-empty, else `<home>/.config` (`cli/src/cli_util.rs:1692-1699` @ v0.46.0). Both variables
/// are read through `crate::environment` (Story 9.36) — the variable, as in the CLI, only as
/// UTF-8; `<home>` is a non-empty `$HOME` (what `etcetera::home_dir()` reads in the CLI's own
/// environment), else `etcetera::home_dir()` itself.
fn xdg_config_home() -> Option<PathBuf> {
    if let Some(x) = crate::environment::var_os("XDG_CONFIG_HOME")
        .and_then(|x| x.into_string().ok())
        .filter(|x| !x.is_empty())
    {
        return Some(PathBuf::from(x));
    }
    crate::environment::var_os("HOME")
        .filter(|home| !home.is_empty())
        .map(PathBuf::from)
        .or_else(|| etcetera::home_dir().ok())
        .map(|home| home.join(".config"))
}

/// The global excludes file a git config names — the CLI's `get_excludes_file_path` closure.
///
/// A configured `core.excludesFile` is `~/`-expanded — against the config environment's
/// home, as the CLI's `config_env().home_dir()` (`cli/src/cli_util.rs:1680-1683` @ v0.46.0) —
/// and, when relative, joined onto the WORKSPACE root, where `git` would read it; without one
/// it is `$XDG_CONFIG_HOME/git/ignore`. A non-UTF-8 value yields no file, as in the CLI.
fn excludes_file_path(workspace: &Workspace, config: &gix::config::File) -> Option<PathBuf> {
    if let Some(value) = config.string("core.excludesFile") {
        let home_dir = crate::config::ConfigEnv::from_env().home_dir;
        let path = std::str::from_utf8(&value)
            .ok()
            .map(|value| jj_lib::file_util::expand_home_path(value, home_dir.as_deref()))?;
        Some(workspace.workspace_root().join(path))
    } else {
        xdg_config_home().map(|x| x.join("git").join("ignore"))
    }
}

/// The ignore patterns every snapshot starts from, BEFORE the working copy's own
/// `.gitignore`s — the port of `WorkspaceCommandHelper::base_ignores`
/// (`cli/src/cli_util.rs:1673-1717` @ v0.46.0).
///
/// On a git backend: the repo's git config's excludes file (see [`excludes_file_path`]), then
/// `<git dir>/info/exclude`. On any other backend: only the excludes file named by the GLOBAL
/// git config (`gix::config::File::from_globals`). A file that does not exist contributes
/// nothing — jj-lib's `chain_with_file` treats absence as "no patterns".
///
/// WHY a FRESH `gix` open rather than `git_backend.git_repo()`: the latter is a thread-local
/// copy of the repository the backend opened when the [`crate::Repo`] was LOADED, config
/// snapshot included, so a `core.excludesFile` set afterwards (in the repo's git config or
/// `~/.gitconfig`) would never reach a long-lived handle — while the CLI re-reads it per
/// command. The open uses jj-lib's own options (`git_backend.rs:570-586` @ 0.44.0, minus the
/// identity overrides, which only matter for writing reflogs).
///
/// # Errors
///
/// - [`MutateError::Backend`] — the git repository could not be re-opened, or an existing
///   ignore file could not be read.
pub(crate) fn base_ignores(workspace: &Workspace) -> Result<Arc<GitIgnoreFile>, MutateError> {
    let mut git_ignores = GitIgnoreFile::empty();
    if let Ok(git_backend) = git::get_git_backend(workspace.repo_loader().store()) {
        let git_repo = gix::open_opts(
            git_backend.git_repo_path(),
            gix::open::Options::default().open_path_as_is(true).strict_config(true),
        )
        .map_err(|e| MutateError::Backend(flatten_chain(&e)))?;
        if let Some(excludes_file) = excludes_file_path(workspace, &git_repo.config_snapshot()) {
            git_ignores = git_ignores
                .chain_with_file(RepoPath::root(), excludes_file)
                .map_err(be)?;
        }
        git_ignores = git_ignores
            .chain_with_file(
                RepoPath::root(),
                git_backend.git_repo_path().join("info").join("exclude"),
            )
            .map_err(be)?;
    } else if let Ok(git_config) = gix::config::File::from_globals() {
        if let Some(excludes_file) = excludes_file_path(workspace, &git_config) {
            git_ignores = git_ignores
                .chain_with_file(RepoPath::root(), excludes_file)
                .map_err(be)?;
        }
    }
    Ok(git_ignores)
}

/// Builds the options a snapshot runs with — the port of
/// `snapshot_options_with_start_tracking_matcher` (`cli/src/cli_util.rs:1644-1662` @ v0.46.0).
///
/// `base_ignores` from [`base_ignores`], `max_new_file_size` from the effective
/// `snapshot.max-new-file-size` (`0` = unlimited), no progress callback, and a
/// `force_tracking_matcher` that forces NOTHING — a caller that forces (`file track
/// --include-ignored`) overrides it afterwards, exactly as the CLI does.
///
/// # Errors
///
/// - [`MutateError::Backend`] — an ignore file could not be read.
/// - [`MutateError::Config`] — `snapshot.max-new-file-size` has the wrong type.
pub(crate) fn snapshot_options<'a>(
    workspace: &Workspace,
    config: &StackedConfig,
    start_tracking_matcher: &'a dyn Matcher,
) -> Result<SnapshotOptions<'a>, MutateError> {
    let base_ignores = base_ignores(workspace)?;
    let max_new_file_size = crate::config::snapshot_max_new_file_size(config).map_err(cfg)?;
    Ok(SnapshotOptions {
        base_ignores,
        progress: None,
        start_tracking_matcher,
        force_tracking_matcher: &NothingMatcher,
        max_new_file_size,
    })
}

/// Whether `workspace` shares its working copy with a git work tree — the port of
/// `is_colocated_git_workspace` (`cli/src/git_util.rs:67-77` @ v0.46.0).
///
/// Colocated when the git backend opens a repository AT the workspace root that shares the
/// backend's common dir: the main work tree, or — since jj 0.46 — a linked git worktree of a
/// child workspace. No repository there, an unrelated one, or a non-git backend is not
/// colocated.
///
/// # Errors
///
/// - [`GitRepoAtWorkdirError::Other`] — the repository at the root could not be opened for any
///   other reason; the CLI refuses the command with it.
pub(crate) fn is_colocated_git_workspace(workspace: &Workspace) -> Result<bool, GitRepoAtWorkdirError> {
    let Ok(git_backend) = git::get_git_backend(workspace.repo_loader().store()) else {
        return Ok(false);
    };
    match git_backend.open_git_repo_at_workdir(workspace.workspace_root()) {
        Ok(_) => Ok(true),
        Err(GitRepoAtWorkdirError::NotFound { .. } | GitRepoAtWorkdirError::Unrelated { .. }) => Ok(false),
        Err(err) => Err(err),
    }
}

// ── The two verbs ────────────────────────────────────────────────────────────────

/// Parses the requested paths the way the CLI parses a bare path argument, with the process
/// CWD replaced by the WORKSPACE ROOT (a GUI has no CWD): `RepoPathUiConverter::parse_file_path`
/// (jj-lib `ui_path.rs:99-103` @ 0.46.0, i.e. `ui_path::parse_fs_path(root, root, entry)`). That
/// normalises exactly as `jj file track nope/` does — a trailing `/`, `.` components and `//`
/// collapse, an absolute path INSIDE the workspace is accepted — and refuses a path that
/// escapes the workspace. Each result is a PREFIX (the Story 9.3/9.4 convention for the
/// CLI's bare-fileset form).
///
/// An EMPTY list is refused first, because the CLI marks `paths` `required = true` for both
/// verbs (and an empty prefix list would otherwise read as "nothing"). An EMPTY ENTRY is refused
/// too: `parse_fs_path` would read `""` as the repository ROOT (every path), while the CLI
/// refuses `jj file track ""` as a fileset syntax error.
///
/// Glob metacharacters (`*`, `?`, `[`) are taken LITERALLY, as part of the path: the CLI's
/// bare-glob form is fileset DSL, which ADR-0003 replaces rather than ports.
fn parse_paths(workspace: &Workspace, paths: &[String], verb: &str) -> Result<Vec<RepoPathBuf>, MutateError> {
    if paths.is_empty() {
        return Err(MutateError::invalid(format!("{verb} requires at least one path")));
    }
    let root = workspace.workspace_root();
    paths
        .iter()
        .map(|entry| {
            if entry.is_empty() {
                return Err(MutateError::invalid(
                    "invalid path: an empty path is not a path".to_owned(),
                ));
            }
            parse_fs_path(root, root, entry)
                .map_err(|e| MutateError::invalid(format!("invalid path: {}", flatten_chain(&e))))
        })
        .collect()
}

/// The prefix matcher over [`parse_paths`]' result.
fn prefix_matcher(paths: &[RepoPathBuf]) -> Box<dyn Matcher> {
    Box::new(PrefixMatcher::new(paths))
}

/// Counts in `usize`, reported as `u32`: saturating, like every other rebased count.
fn saturate(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

/// Starts tracking the paths matching `paths` in the working copy (Story 9.22) — the port of
/// `cmd_file_track` @ v0.46.0. See [`crate::Repo::file_track`] for the contract.
///
/// Every refusal that needs no lock (paths, config, ignore files) happens BEFORE the lock. The
/// only warning is the MERGED stats' size refusals (`print_track_snapshot_stats` prints no
/// invalid-UTF-8 list), recorded after the commit where the CLI prints them (Story 9.32).
pub(crate) fn file_track(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    paths: &[String],
    include_ignored: bool,
) -> Result<TrackResult, MutateError> {
    let matcher = prefix_matcher(&parse_paths(workspace, paths, "file track")?);
    let mut options = snapshot_options(workspace, &ctx.config, matcher.as_ref())?;
    if include_ignored {
        options.force_tracking_matcher = matcher.as_ref();
    }
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let ((track_stats, num_rebased), mutation) =
        mutate::commit_with_locked_wc(workspace, &readonly, "track paths", |tx, locked_wc, _wc_commit| {
            // The snapshot TREE is discarded, as in the CLI: see the module doc (GH #8298).
            let (_tree, stats) = pollster::block_on(locked_wc.snapshot(&options)).map_err(be)?;
            let num_rebased = pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
            Ok((stats, num_rebased))
        })?;
    // The pre-verb snapshot's reasons win for paths the track snapshot merely did not ask for
    // (`print_track_snapshot_stats`).
    let stats = merge_track_stats(ctx.auto_stats.clone(), track_stats);
    ctx.warnings.extend(warning::snapshot_files_refused(
        workspace.workspace_root(),
        &stats.untracked_paths,
    ));
    Ok(TrackResult {
        mutation,
        num_rebased: saturate(num_rebased),
        snapshot_stats: project_stats(&stats),
    })
}

/// What `file untrack`'s transaction body hands back to the verb.
struct UntrackOutcome {
    num_rebased: usize,
    /// The explicit `paths` with no entry in the pre-call `@` tree — `print_unmatched_explicit_paths`
    /// (`cli/src/cli_util.rs:3382-3413` @ v0.46.0), in request order, duplicates kept, each in its
    /// NORMALISED repo-path form (the CLI formats the parsed path too, so `nope/` reports `nope`).
    unmatched_paths: Vec<RepoPathBuf>,
    stats: working_copy::SnapshotStats,
    export: Option<git::GitExportStats>,
}

/// The body of `cmd_file_untrack` between the lock and the commit (`untrack.rs:63-119` @ v0.46.0).
/// `colocated_root` is the workspace root — the git worktree the export writes to — when the
/// workspace is colocated, `None` otherwise.
fn untrack_in_tx(
    tx: &mut Transaction,
    locked_wc: &mut dyn LockedWorkingCopy,
    wc_commit: &Commit,
    matcher: &dyn Matcher,
    options: &SnapshotOptions<'_>,
    colocated_root: Option<&Path>,
    paths: &[RepoPathBuf],
) -> Result<UntrackOutcome, MutateError> {
    let wc_tree = wc_commit.tree();
    let mut tree_builder = MergedTreeBuilder::new(wc_tree.clone());
    for (path, _value) in futures::executor::block_on_stream(wc_tree.entries_matching(matcher)) {
        tree_builder.set_or_remove(path, None);
    }
    let new_tree = pollster::block_on(tree_builder.write_tree()).map_err(be)?;
    let new_commit =
        pollster::block_on(tx.repo_mut().rewrite_commit(wc_commit).set_tree(new_tree).write()).map_err(be)?;
    // Computed BEFORE the reset and the colocated export (the CLI prints it after `finish`,
    // from the same pre-call tree): a read failure here must not leave the git index and refs
    // rewritten with no operation written.
    let unmatched_paths = warning::unmatched_paths(paths, &[&wc_tree])
        .map_err(be)?
        .into_iter()
        .cloned()
        .collect();
    pollster::block_on(locked_wc.reset(&new_commit)).map_err(be)?;
    // Snapshot again so a matched path that is NOT ignored — and would therefore be re-added by
    // the next snapshot — is refused now rather than silently coming back.
    let (new_wc_tree, stats) = pollster::block_on(locked_wc.snapshot(options)).map_err(be)?;
    if new_wc_tree.tree_ids() != new_commit.tree_ids() {
        let added_back: Vec<String> = futures::executor::block_on_stream(new_wc_tree.entries_matching(matcher))
            .map(|(path, _value)| path.as_internal_file_string().to_owned())
            .collect();
        if !added_back.is_empty() {
            // Dropping the lock without `finish` (the caller's `?`) discards both the `reset`
            // and the snapshot: the CLI's `drop(locked_ws)`.
            return Err(MutateError::PathsNotIgnored { paths: added_back });
        }
        // A difference OUTSIDE the matcher is a concurrent working-copy edit; don't mix it in.
        pollster::block_on(locked_wc.reset(&new_commit)).map_err(be)?;
    }
    let num_rebased = pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    let export = if let Some(workspace_root) = colocated_root {
        // `export_working_copy_changes_to_git` (`cli/src/cli_util.rs:2705-2717` @ v0.46.0).
        let mut_repo = tx.repo_mut();
        pollster::block_on(git::update_intent_to_add(
            mut_repo.base_repo().as_ref(),
            workspace_root,
            &wc_tree,
            &new_commit.tree(),
        ))
        .map_err(|e| MutateError::Backend(flatten_chain(&e)))?;
        Some(git::export_refs(mut_repo).map_err(map_export_err)?)
    } else {
        None
    };
    Ok(UntrackOutcome {
        num_rebased,
        unmatched_paths,
        stats,
        export,
    })
}

/// Stops tracking the paths matching `paths` (Story 9.22) — the port of `cmd_file_untrack` @
/// v0.46.0. See [`crate::Repo::file_untrack`] for the contract.
///
/// Every refusal that needs no lock (paths, config, ignore files) happens BEFORE the lock.
/// Warnings in the CLI's order (Story 9.32): the colocated export's failures inside the
/// transaction, then — after the commit — the unmatched paths and the post-`reset` snapshot's
/// stats.
pub(crate) fn file_untrack(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    paths: &[String],
) -> Result<UntrackResult, MutateError> {
    let paths = parse_paths(workspace, paths, "file untrack")?;
    let matcher = prefix_matcher(&paths);
    let auto_tracking = auto_tracking_matcher(&ctx.config, &mut ctx.warnings)?;
    let options = snapshot_options(workspace, &ctx.config, auto_tracking.as_ref())?;
    let colocated_root = is_colocated_git_workspace(workspace)
        .map_err(|e| MutateError::Backend(flatten_chain(&e)))?
        .then(|| workspace.workspace_root().to_owned());
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let sink = &mut ctx.warnings;
    let (outcome, mutation) =
        mutate::commit_with_locked_wc(workspace, &readonly, "untrack paths", |tx, locked_wc, wc_commit| {
            let outcome = untrack_in_tx(
                tx,
                locked_wc,
                wc_commit,
                matcher.as_ref(),
                &options,
                colocated_root.as_deref(),
                &paths,
            )?;
            if let Some(export) = &outcome.export {
                sink.extend(warning::git_export_failed(export));
            }
            Ok(outcome)
        })?;
    let root = workspace.workspace_root();
    sink.extend(warning::paths_unmatched(
        root,
        &outcome.unmatched_paths.iter().collect::<Vec<_>>(),
    ));
    sink.extend(warning::snapshot_stats(root, &outcome.stats));
    let (failed_bookmarks, failed_tags) = outcome.export.map_or_else(Default::default, |stats| {
        (
            project_failures(&stats.failed_bookmarks),
            project_failures(&stats.failed_tags),
        )
    });
    Ok(UntrackResult {
        mutation,
        num_rebased: saturate(outcome.num_rebased),
        unmatched_paths: outcome
            .unmatched_paths
            .iter()
            .map(|path| path.as_internal_file_string().to_owned())
            .collect(),
        snapshot_stats: project_stats(&outcome.stats),
        failed_bookmarks,
        failed_tags,
    })
}

/// Why `file chmod` refuses `value` (`chmod.rs:94-106` @ v0.46.0): every present side must be a
/// file. `None` when it may be changed.
fn chmod_refusal(value: &MergedTreeValue) -> Option<&'static str> {
    if value.adds().flatten().all(|v| matches!(v, TreeValue::File { .. })) {
        None
    } else if value.is_resolved() {
        Some("Found neither a file nor a conflict")
    } else {
        Some("Some of the sides of the conflict are not files")
    }
}

/// Sets or clears the executable bit of the files matching `paths` in `revision` (default `@`)
/// — the port of `cmd_file_chmod` (`cli/src/commands/file/chmod.rs:60-138` @ v0.46.0; Story
/// 9.13). See [`crate::Repo::file_chmod`] for the contract.
///
/// The CLI's order: the revision, its rewritability, the paths and their unmatched-paths
/// warning, then per matching entry the non-file refusal and the new bit on every file term;
/// the rewrite finishes through [`mutate::finish_verb`] (descendants rebased) as
/// `make paths executable|non-executable in commit <hex>`.
pub(crate) fn file_chmod(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    executable: bool,
    revision: Option<&crate::ChangeId>,
    paths: &[String],
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let mut tx = start_repo_transaction(&readonly, workspace.workspace_name());
    let templates = ctx.templates(workspace);
    let commit = mutate::resolve_or_wc(tx.repo(), workspace.workspace_name(), templates.prefixes(), revision)?;
    mutate::guard_rewritable(&tx, &templates, std::slice::from_ref(commit.id()))?;
    let paths = parse_paths(workspace, paths, "file chmod")?;
    let root = workspace.workspace_root();
    let tree = commit.tree();
    warning::warn_unmatched_paths(&mut ctx.warnings, root, &paths, &[&tree]).map_err(be)?;

    let matcher = prefix_matcher(&paths);
    let mut builder = MergedTreeBuilder::new(tree.clone());
    for (path, value) in futures::executor::block_on_stream(tree.entries_matching(matcher.as_ref())) {
        let value = value.map_err(be)?;
        if let Some(reason) = chmod_refusal(&value) {
            return Err(MutateError::invalid(format!(
                "{reason} at '{}'.",
                warning::ui_path(root, &path)
            )));
        }
        builder
            .set_or_remove_merge(path, crate::select_tree::with_executable(value, executable))
            .map_err(be)?;
    }
    let new_tree = pollster::block_on(builder.write_tree()).map_err(be)?;
    pollster::block_on(tx.repo_mut().rewrite_commit(&commit).set_tree(new_tree).write()).map_err(be)?;
    let mode = if executable { "executable" } else { "non-executable" };
    let finish = mutate::finish_verb(
        workspace,
        tx,
        &format!("make paths {mode} in commit {}", commit.id().hex()),
        ctx,
    )?;
    Ok(mutate::mutation_result(&finish, Vec::new(), Vec::new()))
}

/// The tail `cmd_file_edit` and `cmd_file_delete` share (`file/{edit,delete}.rs` @ v0.46.0): an
/// unchanged tree is "Nothing changed." — no operation, the pre-call head — else `commit` takes
/// `new_tree`, its descendants are rebased or, with `restore_descendants`, reparented
/// (`rebase_or_reparent_descendants`, `cli_util.rs:3418-3440`), and the operation is
/// `description`.
fn finish_tree_rewrite(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    mut tx: Transaction,
    commit: &Commit,
    new_tree: MergedTree,
    restore_descendants: bool,
    description: &str,
) -> Result<MutationResult, MutateError> {
    if new_tree.tree_ids() == commit.tree_ids() {
        let readonly = tx.base_repo().clone();
        drop(tx);
        return mutate::no_op_result(workspace.workspace_name(), &readonly);
    }
    pollster::block_on(tx.repo_mut().rewrite_commit(commit).set_tree(new_tree).write()).map_err(be)?;
    if restore_descendants {
        pollster::block_on(tx.repo_mut().reparent_descendants()).map_err(be)?;
    } else {
        pollster::block_on(tx.repo_mut().rebase_descendants()).map_err(be)?;
    }
    let finish = mutate::finish_verb(workspace, tx, description, ctx)?;
    Ok(mutate::mutation_result(&finish, Vec::new(), Vec::new()))
}

/// Why `file edit` refuses `value` (`edit.rs:89-108` @ v0.46.0), in the CLI's text: a directory,
/// a symlink or submodule, or a conflict with a side that is neither a file nor absent. `None`
/// when it may be edited — absent, a file, or a file conflict.
fn edit_refusal(value: MergedTreeValue, ui_path: &str) -> Option<String> {
    match value.into_resolved() {
        Ok(None | Some(TreeValue::File { .. })) => None,
        Ok(Some(TreeValue::Tree(_))) => Some(format!("Path is a directory: {ui_path}")),
        Ok(Some(TreeValue::Symlink(_) | TreeValue::GitSubmodule(_))) => {
            Some(format!("Path '{ui_path}' is not a regular file"))
        }
        Err(conflict) => conflict
            .to_file_merge()
            .is_none()
            .then(|| format!("Path '{ui_path}' has a non-file conflict and cannot be edited")),
    }
}

/// The first proper ancestor of `path` that `tree` holds as something other than a directory —
/// Zanshin's own refusal, a deliberate divergence (spec 9.44, Design Notes): the CLI's editor
/// either cannot save there (no change) or, creating the directory, makes jj-lib replace that
/// entry with a directory. Missing parents are created as a directory-creating editor would; an
/// existing entry is never replaced.
fn non_directory_ancestor(tree: &MergedTree, path: &RepoPath) -> Result<Option<RepoPathBuf>, MutateError> {
    for ancestor in path.ancestors().skip(1).filter(|p| !p.is_root()) {
        let value = pollster::block_on(tree.path_value(ancestor)).map_err(be)?;
        if value.adds().flatten().any(|v| !matches!(v, TreeValue::Tree(_))) {
            return Ok(Some(ancestor.to_owned()));
        }
    }
    Ok(None)
}

/// Writes `content` as `path`'s new bytes in `tree` and returns the resulting tree — the
/// mechanism of `cmd_file_edit` (`edit.rs:110-160` @ v0.46.0) with the GUI's buffer where the
/// editor would save: a temporary sparse working copy holding only `path`, checked out from
/// `tree` (a conflict materialized with `conflict_marker_style`), written, then snapshotted.
fn edit_in_sparse_copy(
    store: &Arc<jj_lib::store::Store>,
    tree: &MergedTree,
    path: &RepoPath,
    content: &[u8],
    conflict_marker_style: jj_lib::conflicts::ConflictMarkerStyle,
) -> Result<MergedTree, MutateError> {
    let temp_dir = tempfile::Builder::new().prefix("jj-file-edit-").tempdir().map_err(be)?;
    let wc_path = temp_dir.path().join("wc");
    let state_dir = temp_dir.path().join("state");
    std::fs::create_dir(&wc_path).map_err(be)?;
    std::fs::create_dir(&state_dir).map_err(be)?;
    let settings = TreeStateSettings {
        conflict_marker_style,
        eol_conversion_mode: EolConversionMode::None,
        exec_change_setting: ExecChangeSetting::Auto,
        fsmonitor_settings: FsmonitorSettings::None,
    };
    let mut tree_state = TreeState::init(store.clone(), wc_path, state_dir, &settings).map_err(be)?;
    pollster::block_on(tree_state.set_sparse_patterns(vec![path.to_owned()])).map_err(be)?;
    pollster::block_on(tree_state.check_out(tree)).map_err(be)?;
    let file_path = path
        .to_fs_path(tree_state.working_copy_path())
        .map_err(|e| MutateError::invalid(flatten_chain(&e)))?;
    let write = |file: &Path| -> std::io::Result<()> {
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(file, content)
    };
    write(&file_path).map_err(|e| MutateError::Backend(format!("Failed to edit file: {e}")))?;
    pollster::block_on(tree_state.snapshot(&SnapshotOptions {
        base_ignores: GitIgnoreFile::empty(),
        progress: None,
        start_tracking_matcher: &EverythingMatcher,
        force_tracking_matcher: &NothingMatcher,
        max_new_file_size: u64::MAX,
    }))
    .map_err(be)?;
    Ok(tree_state.current_tree().clone())
}

/// Replaces the content of `path` in `revision` (default `@`) with `content` — the port of
/// `cmd_file_edit` (`cli/src/commands/file/edit.rs` @ v0.46.0; Story 9.44) with the GUI's buffer
/// in place of the editor. See [`crate::Repo::file_edit`] for the contract.
pub(crate) fn file_edit(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    revision: Option<&crate::ChangeId>,
    restore_descendants: bool,
    path: &str,
    content: &[u8],
) -> Result<MutationResult, MutateError> {
    let conflict_marker_style = crate::config::conflict_marker_style(&ctx.config).map_err(cfg)?;
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let tx = start_repo_transaction(&readonly, workspace.workspace_name());
    let templates = ctx.templates(workspace);
    let commit = mutate::resolve_or_wc(tx.repo(), workspace.workspace_name(), templates.prefixes(), revision)?;
    mutate::guard_rewritable(&tx, &templates, std::slice::from_ref(commit.id()))?;
    let root = workspace.workspace_root();
    // `parse_file_path` from the workspace root, as `parse_paths` parses each entry — but `""`
    // stays the root (refused below as a directory), as in the CLI.
    let repo_path = parse_fs_path(root, root, path)
        .map_err(|e| MutateError::invalid(format!("invalid path: {}", flatten_chain(&e))))?;
    let tree = commit.tree();
    let value = pollster::block_on(tree.path_value(&repo_path)).map_err(be)?;
    if let Some(reason) = edit_refusal(value, &warning::ui_path(root, &repo_path)) {
        return Err(MutateError::invalid(reason));
    }
    if let Some(ancestor) = non_directory_ancestor(&tree, &repo_path)? {
        return Err(MutateError::invalid(format!(
            "Failed to edit file: '{}' is not a directory",
            warning::ui_path(root, &ancestor)
        )));
    }
    let new_tree = edit_in_sparse_copy(readonly.store(), &tree, &repo_path, content, conflict_marker_style)?;
    let description = format!(
        "edit file {} in commit {}",
        repo_path.as_internal_file_string(),
        commit.id().hex()
    );
    finish_tree_rewrite(workspace, ctx, tx, &commit, new_tree, restore_descendants, &description)
}

/// Removes every entry matching `paths` from `revision` (default `@`) — the port of
/// `cmd_file_delete` (`cli/src/commands/file/delete.rs` @ v0.46.0; Story 9.44). See
/// [`crate::Repo::file_delete`] for the contract.
pub(crate) fn file_delete(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    revision: Option<&crate::ChangeId>,
    restore_descendants: bool,
    paths: &[String],
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let tx = start_repo_transaction(&readonly, workspace.workspace_name());
    let templates = ctx.templates(workspace);
    let commit = mutate::resolve_or_wc(tx.repo(), workspace.workspace_name(), templates.prefixes(), revision)?;
    mutate::guard_rewritable(&tx, &templates, std::slice::from_ref(commit.id()))?;
    let paths = parse_paths(workspace, paths, "file delete")?;
    let tree = commit.tree();
    warning::warn_unmatched_paths(&mut ctx.warnings, workspace.workspace_root(), &paths, &[&tree]).map_err(be)?;

    let matcher = prefix_matcher(&paths);
    let mut builder = MergedTreeBuilder::new(tree.clone());
    for (path, _value) in futures::executor::block_on_stream(tree.entries_matching(matcher.as_ref())) {
        builder.set_or_remove(path, None);
    }
    let new_tree = pollster::block_on(builder.write_tree()).map_err(be)?;
    let description = format!("delete paths in commit {}", commit.id().hex());
    finish_tree_rewrite(workspace, ctx, tx, &commit, new_tree, restore_descendants, &description)
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};
    use std::ffi::OsString;

    use jj_lib::repo_path::RepoPathBuf;
    use jj_lib::working_copy::{SnapshotStats as JjStats, UntrackedReason as JjReason};

    use super::{merge_track_stats, project_stats, saturate, SnapshotStats, UntrackedPath, UntrackedReason};

    fn path(p: &str) -> RepoPathBuf {
        RepoPathBuf::from_internal_string(p).expect("valid repo path")
    }

    /// `print_track_snapshot_stats`: a `FileNotAutoTracked` entry takes the auto-snapshot's
    /// reason for the same path; any other reason, and a path the auto-snapshot never saw,
    /// keep the track snapshot's own.
    #[test]
    fn merge_track_stats_prefers_the_auto_snapshots_reason_for_not_auto_tracked_paths() {
        let too_large = JjReason::FileTooLarge { size: 20, max_size: 10 };
        let auto = JjStats {
            untracked_paths: BTreeMap::from([
                (path("big.bin"), too_large.clone()),
                (path("forced.bin"), JjReason::FileNotAutoTracked),
            ]),
            invalid_utf8_paths: BTreeSet::from([(path("auto-dir"), OsString::from("auto"))]),
        };
        let track = JjStats {
            untracked_paths: BTreeMap::from([
                (path("big.bin"), JjReason::FileNotAutoTracked),
                (path("forced.bin"), JjReason::FileTooLarge { size: 30, max_size: 10 }),
                (path("other.txt"), JjReason::FileNotAutoTracked),
            ]),
            invalid_utf8_paths: BTreeSet::from([(path("track-dir"), OsString::from("track"))]),
        };
        let merged = project_stats(&merge_track_stats(auto, track));
        assert_eq!(
            merged,
            SnapshotStats {
                untracked: vec![
                    UntrackedPath {
                        path: "big.bin".to_owned(),
                        reason: UntrackedReason::FileTooLarge { size: 20, max_size: 10 },
                    },
                    UntrackedPath {
                        path: "forced.bin".to_owned(),
                        reason: UntrackedReason::FileTooLarge { size: 30, max_size: 10 },
                    },
                    UntrackedPath {
                        path: "other.txt".to_owned(),
                        reason: UntrackedReason::FileNotAutoTracked,
                    },
                ],
                invalid_utf8_paths: vec!["track-dir/track".to_owned()],
            }
        );
    }

    /// An empty auto-snapshot (the pre-verb snapshot left nothing untracked) makes the merge the
    /// identity.
    #[test]
    fn merge_track_stats_with_empty_auto_stats_is_the_identity() {
        let track = JjStats {
            untracked_paths: BTreeMap::from([(path("a.txt"), JjReason::FileNotAutoTracked)]),
            invalid_utf8_paths: BTreeSet::new(),
        };
        let merged = merge_track_stats(JjStats::default(), track.clone());
        assert_eq!(project_stats(&merged), project_stats(&track));
    }

    /// Invalid-UTF-8 NAMES cannot be created on APFS, so the rendering is pinned here: the
    /// directory joined with the lossily-decoded name, the bare name at the root.
    #[cfg(unix)]
    #[test]
    fn invalid_utf8_paths_render_as_dir_slash_lossy_name() {
        use std::os::unix::ffi::OsStringExt as _;
        let bad = OsString::from_vec(vec![b'a', 0xff, b'b']);
        let stats = JjStats {
            untracked_paths: BTreeMap::new(),
            invalid_utf8_paths: BTreeSet::from([(RepoPathBuf::root(), bad.clone()), (path("sub/dir"), bad)]),
        };
        assert_eq!(
            project_stats(&stats).invalid_utf8_paths,
            vec!["a\u{fffd}b".to_owned(), "sub/dir/a\u{fffd}b".to_owned()]
        );
    }

    #[test]
    fn rebased_counts_saturate_instead_of_wrapping() {
        assert_eq!(saturate(7), 7);
        assert_eq!(saturate(usize::MAX), u32::MAX);
    }

    /// `file chmod`'s classifier (`chmod.rs:94-106` @ v0.46.0): a file, a file conflict and an
    /// absent side pass; a resolved non-file and a conflict with a non-file side refuse with the
    /// CLI's two texts.
    #[test]
    fn chmod_refuses_what_the_cli_refuses() {
        use jj_lib::backend::{CopyId, FileId, SymlinkId, TreeValue};
        use jj_lib::merge::Merge;

        use super::chmod_refusal;

        let file = || {
            Some(TreeValue::File {
                id: FileId::new(vec![1]),
                executable: false,
                copy_id: CopyId::placeholder(),
            })
        };
        let link = || Some(TreeValue::Symlink(SymlinkId::new(vec![2])));
        assert_eq!(chmod_refusal(&Merge::resolved(file())), None);
        assert_eq!(chmod_refusal(&Merge::from_vec(vec![file(), link(), None])), None);
        assert_eq!(
            chmod_refusal(&Merge::resolved(link())),
            Some("Found neither a file nor a conflict")
        );
        assert_eq!(
            chmod_refusal(&Merge::from_vec(vec![file(), None, link()])),
            Some("Some of the sides of the conflict are not files")
        );
    }

    /// `file edit`'s classifier (`edit.rs:89-108` @ v0.46.0): absent, a file and a file conflict
    /// pass; a directory, a symlink, a submodule and a conflict with a non-file side refuse with
    /// the CLI's texts.
    #[test]
    fn edit_refuses_what_the_cli_refuses() {
        use jj_lib::backend::{CommitId, CopyId, FileId, SymlinkId, TreeId, TreeValue};
        use jj_lib::merge::Merge;

        use super::edit_refusal;

        let file = || {
            Some(TreeValue::File {
                id: FileId::new(vec![1]),
                executable: false,
                copy_id: CopyId::placeholder(),
            })
        };
        let link = || Some(TreeValue::Symlink(SymlinkId::new(vec![2])));
        assert_eq!(edit_refusal(Merge::absent(), "p"), None);
        assert_eq!(edit_refusal(Merge::resolved(file()), "p"), None);
        assert_eq!(edit_refusal(Merge::from_vec(vec![file(), None, file()]), "p"), None);
        assert_eq!(
            edit_refusal(Merge::resolved(Some(TreeValue::Tree(TreeId::new(vec![3])))), "d"),
            Some("Path is a directory: d".to_owned())
        );
        let not_regular = Some("Path 'p' is not a regular file".to_owned());
        assert_eq!(edit_refusal(Merge::resolved(link()), "p"), not_regular);
        assert_eq!(
            edit_refusal(
                Merge::resolved(Some(TreeValue::GitSubmodule(CommitId::new(vec![4])))),
                "p"
            ),
            not_regular
        );
        assert_eq!(
            edit_refusal(Merge::from_vec(vec![file(), None, link()]), "p"),
            Some("Path 'p' has a non-file conflict and cannot be edited".to_owned())
        );
    }
}
