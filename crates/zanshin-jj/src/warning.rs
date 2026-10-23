// SPDX-License-Identifier: MIT

//! `warning.rs` — the warning channel (Story 9.32): the jj CLI's `ui.warning_*` output as coded
//! facts.
//!
//! Where the CLI succeeds (or partially succeeds) WITH a warning, Zanshin reports a [`Warning`]:
//! one registered [`WarningKind`] per remedy, plus the CLI's own text block for log/tooltip use.
//! Nothing parses the message; a UI switches on the kind. Structured data that already rides a
//! typed result stays there — the warning says THAT there is something, the payload says WHAT.
//!
//! Every call collects its warnings in ONE per-call [`Warnings`] collector, in the CLI's print
//! order. Config-load warnings (alias entries, alias redefinitions, `immutable_heads()` parse
//! diagnostics) are recorded ONCE per call: the CLI loads those tables once per command, while
//! Zanshin may re-load the same table within one call.

use std::collections::BTreeSet;
use std::error::Error;
use std::path::Path;

use jj_lib::backend::{BackendError, MergedTreeValue, TreeValue};
use jj_lib::commit::Commit;
use jj_lib::merged_tree::MergedTree;
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use jj_lib::settings::{HumanByteSize, UserSettings};
use jj_lib::ui_path::RepoPathUiConverter;
use jj_lib::working_copy::{self, UntrackedReason};

/// What a warning is about — one variant per remedy, each the port of one jj CLI
/// `ui.warning_*` site @ v0.44.0 (Story 9.32). The FFI turns each into its registered `jj.*`
/// warning code (`docs/rust-error-codes.md`, "Warning Codes").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WarningKind {
    /// `user.name` and/or `user.email` is empty and an operation was committed with that
    /// identity — `finish_transaction`'s "Name and email not configured" (`cli_util.rs:2387-2415`).
    IdentityMissing,
    /// `@` was inside the immutable set, so a new `@` was created on top of it — the snapshot's
    /// "is immutable" (`cli_util.rs:2123-2127`) or the finish's "became immutable" (`:2338-2342`).
    WorkingCopyImmutable,
    /// A colocated snapshot found top-level `.jjconflict*` entries (`cli_util.rs:2206-2210`).
    JjconflictFilesPresent,
    /// Git HEAD could not be moved to `@`'s parent (`try_reset_git_head`, `cli_util.rs:2689`).
    GitHeadUpdateFailed,
    /// Bookmarks or tags the Git export could not write (`git_util.rs:468-492`).
    GitExportFailed,
    /// Git refs the import could not read (`git_util.rs:270-279`).
    GitImportFailed,
    /// New files larger than `snapshot.max-new-file-size` stayed untracked
    /// (`print_untracked_files`, `cli_util.rs:3183-3203`).
    SnapshotFilesRefused,
    /// Paths skipped because their names are not valid UTF-8 (`cli_util.rs:3207-3228`).
    SnapshotPathsNotUtf8,
    /// Working-copy updates skipped because of conflicting on-disk changes
    /// (`print_checkout_stats`, `cli_util.rs:3303-3309`).
    CheckoutFilesSkipped,
    /// A checkout moved `@` onto a commit with conflicts: the CLI lists each conflicted path with
    /// a description of its conflict (`print_updated_working_copy_stats`,
    /// `cli_util.rs:2297-2331` @ v0.46.0, lines from `print_conflicted_paths` `:3129-3219`; Story
    /// 9.53). Every finish that checks out a new `@` and the stale-working-copy recovery warn it,
    /// right after [`WarningKind::CheckoutFilesSkipped`]; a finish that leaves `@` where it was
    /// does not.
    UnresolvedConflicts,
    /// Explicitly named paths that match no entry (`print_unmatched_explicit_paths`,
    /// `cli_util.rs:3323-3347`).
    PathsUnmatched,
    /// A `[revset-aliases]` / `[fileset-aliases]` entry that does not load
    /// (`load_aliases_map`, `config.rs:1026-1031`).
    ConfigAliasInvalid,
    /// A config layer redefines `mutable()`, `immutable()` or `builtin_immutable_heads()`
    /// (`warn_user_redefined_builtin`, `revset_util.rs:154-180`).
    ConfigAliasRedefined,
    /// A revset parsed with a diagnostic (`print_parse_diagnostics`, `command_error.rs:1105-1119`).
    RevsetDiagnostic,
    /// The short-prefixes disambiguation index could not be loaded (`commit_templater.rs:2208-2215`).
    ShortPrefixesFailed,
    /// Another remote already uses the URL just added (`git/remote/add.rs:103-108`).
    RemoteUrlDuplicate,
    /// A bookmark was created on an empty, undescribed revision (`bookmark/create.rs:84-86`).
    BookmarkTargetEmpty,
    /// Exact names given to `bookmark delete`, `move` or `advance` that match no local bookmark
    /// (`warn_unmatched_local_bookmarks`, `bookmark/mod.rs:185-203`), or to `bookmark list` that
    /// match no local or remote bookmark (`warn_unmatched_local_or_remote_bookmarks`,
    /// `bookmark/mod.rs:205-226` @ v0.46.0; Story 9.19).
    BookmarkNamesUnmatched,
    /// `bookmark create` auto-tracked a remote bookmark that already exists on that remote — the
    /// created name matches `remotes.<r>.auto-track-bookmarks` / `auto-track-created-bookmarks`
    /// and the remote's view already holds it (`bookmark/create.rs:104-108` @ v0.46.0).
    BookmarkAutoTrackExisting,
    /// `bookmark rename` kept a tracked remote of the old name, but the new name already exists,
    /// untracked, on that remote, so its tracking state was dropped — "The renamed bookmark
    /// already exists on the remote '{remote}', tracking state was dropped."
    /// (`bookmark/rename.rs:111-123` @ v0.46.0; Story 9.19).
    BookmarkRenameRemoteExists,
    /// `bookmark rename --overwrite-existing` untracked a present remote of the overwritten name
    /// that the old name did not track — "Tracking of remote bookmark {new}@{remote} was
    /// dropped." (`bookmark/rename.rs:130-154` @ v0.46.0; Story 9.19).
    BookmarkTrackingDropped,
    /// `bookmark rename` of a bookmark with present tracked remotes: those stay under the old
    /// name — "Tracked remote bookmarks for bookmark {old} were not renamed."
    /// (`bookmark/rename.rs:167-182` @ v0.46.0; Story 9.19). Recorded after the finish.
    BookmarkRemotesNotRenamed,
    /// `bookmark rename` without `--overwrite-existing` onto a name that has present tracked
    /// remotes — "Tracked remote bookmarks for bookmark {new} exist."
    /// (`bookmark/rename.rs:183-201` @ v0.46.0; Story 9.19). Recorded after the finish.
    BookmarkTrackedRemotesExist,
    /// A path `absorb` could not split (`absorb.rs:155-158`).
    AbsorbPathSkipped,
    /// A path whose content could not be read (`file/show.rs:164-170`, `file/search.rs:109-115`).
    PathAccessDenied,
    /// A path that exists but is not a file (`file/show.rs:191-197`).
    PathNotAFile,
    /// `user.name`/`user.email` was set but `@`'s author stays the old one (`config/set.rs:120-127`).
    ConfigWorkingCopyAuthor,
    /// A missing repo config directory could not be deleted (`config/gc.rs:80-84`).
    ConfigGcDeleteFailed,
    /// `config list` found nothing to list (`config/list.rs:116-123`).
    ConfigNothingListed,
    /// A failed clone could not remove what it had created (`git/clone.rs:276-284`, Story 9.33).
    CloneCleanupFailed,
    /// A legacy `.jj/repo/config.toml` / `.jj/workspace-config.toml` was migrated into the secure
    /// config directory at command start (jj-lib `secure_config.rs:346-351`
    /// `maybe_migrate_legacy_config`, printed by `load_secure_config`, `cli/src/config.rs:462-464`;
    /// Story 9.37).
    ConfigMigrated,
    /// The repo/workspace was COPIED, so its secure config was forked under a new id
    /// (`secure_config.rs:273-278` `handle_metadata_path`, printed at `cli/src/config.rs:462-464`;
    /// Story 9.37).
    ConfigCopied,
    /// The secure config directory its id points at was missing and was regenerated empty
    /// (`secure_config.rs:48-50` `CONFIG_NOT_FOUND`, `maybe_load_config` `:384-391`, printed at
    /// `cli/src/config.rs:462-464`; Story 9.37).
    ConfigRegenerated,
    /// `undo` undid a `jj git push` operation, which often leaves conflicted bookmarks
    /// (`cli/src/commands/undo.rs:134-141` @ v0.46.0; Story 9.39).
    UndoPushOperation,
    /// `undo` undid a workspace removal: the workspace is back in the view, its directory is not
    /// (`cli/src/commands/undo.rs:142-156` @ v0.46.0; Story 9.39).
    UndoWorkspaceRemoval,
    /// A colocating conversion created the repo inside a LINKED git worktree, where a workspace
    /// of the main repository was probably meant (`cli/src/commands/git/init.rs:272-281` @
    /// v0.46.0, which warns since jj 0.45 instead of refusing).
    ColocatedInGitWorktree,
    /// `workspace root` with a name whose recorded directory does not exist (moved or deleted):
    /// the path is still returned (`cli/src/commands/workspace/root.rs:60-66` @ v0.46.0).
    WorkspacePathInaccessible,
    /// `workspace add` with a destination that holds no path separator: the workspace was
    /// created INSIDE the current one, perhaps where only a name was meant
    /// (`cli/src/commands/workspace/add.rs:184-191` @ v0.46.0; Story 9.23).
    WorkspaceInCurrentDirectory,
    /// `split` selected EVERY change of the target, so the remaining commit will be empty
    /// (`cli/src/commands/split.rs:585-589` @ v0.46.0; Story 9.15). The split still runs.
    SplitAllSelected,
    /// `split` selected NO change of the target, so the selected commit will be empty
    /// (`cli/src/commands/split.rs:590-594` @ v0.46.0; Story 9.15). The split still runs; when
    /// the target itself is empty both hold and only [`WarningKind::SplitAllSelected`] warns.
    SplitNoneSelected,
    /// `commit` with paths that select NO change of `@` — the selected tree is `@`'s parent tree
    /// (`cli/src/commands/commit.rs:128-134` @ v0.46.0; Story 9.49). The commit still runs: the
    /// committed `@` is empty and the new `@` holds every change.
    CommitPathsUnmatched,
    /// `git push --remote` (or `git.push`) with exact names that match no git remote
    /// (`cli/src/commands/git/push.rs:313-318` @ v0.46.0; Story 9.20). The push goes on with the
    /// remotes that did match; [`crate::Repo::git_push_remotes`] warns it for `git.push` as the
    /// push does (Story 9.54).
    PushRemotesUnmatched,
    /// `git push -b` with exact names that match no bookmark to push (`push.rs:1383-1388`).
    PushBookmarksUnmatched,
    /// `git push -t` with exact names that match no tag to push (`push.rs:1417-1422`).
    PushTagsUnmatched,
    /// The bare `git push` found no bookmark or tag in `revsets.git-push` for a remote
    /// (`push.rs:1450-1456`).
    PushRevsetEmpty,
    /// `git push -r` with a revision no bookmark or tag points to (`push.rs:1474-1479`).
    PushRevisionsEmpty,
    /// A ref the push's mode refused and skipped — conflicted, untracked on the remote, new or
    /// deleted without the flag that allows it (`push.rs:1139-1146`, refusal texts
    /// `:1157-1254`). The rest is pushed.
    PushRefSkipped,
    /// A ref skipped because a commit it would push is not ready — no description, no
    /// author/committer, conflicts, private (`push.rs:744-750`). The rest is pushed.
    PushCommitSkipped,
    /// Refs the remote had moved since the last fetch, so the lease failed
    /// (`cli/src/git_util.rs:508-526` @ v0.46.0).
    PushRefsMovedOnRemote,
    /// Updates the remote rejected (`git_util.rs:528-547`).
    PushRemoteRejected,
    /// Pushed bookmarks whose remote-tracking ref could not be updated locally
    /// (`git_util.rs:548-561`).
    PushBookmarksNotUpdatedLocally,
    /// Sign-on-push met commits to sign that are immutable and left them unsigned
    /// (`push.rs:940-956`).
    PushSigningSkippedImmutable,
    /// `git clone -b` with exact names the remote does not have (`clone.rs:435-444` @ v0.46.0;
    /// Story 9.20).
    CloneBranchesUnmatched,
    /// A template a verb renders (`templates.commit_trailers`, `draft_commit_description`,
    /// `new_description`, `git_push_bookmark`) parsed with a diagnostic — the CLI's
    /// `print_parse_diagnostics(ui, "In template expression", …)` after `template_builder::parse`
    /// (`cli/src/cli_util.rs:1180-1195` @ v0.46.0; Story 9.51). The template still renders.
    TemplateDiagnostic,
    /// `git fetch --remote` (or `git.fetch`, or the implicit `origin`) with exact names that match
    /// no git remote (`cli/src/commands/git/fetch.rs:162-168` @ v0.46.0; Story 9.30). The fetch
    /// goes on with the remotes that did match; [`crate::Repo::git_fetch_remotes`] warns it as the
    /// fetch does.
    FetchRemotesUnmatched,
    /// A fetch refspec of the remote's Git config that jj ignores — not a forced
    /// `refs/heads/*` → `refs/remotes/<remote>/*` mapping (`warn_ignored_refspecs`,
    /// `fetch.rs:323-337` @ v0.46.0; Story 9.30). The fetch goes on without it.
    FetchRefspecIgnored,
    /// `git fetch -b` with exact names no matched remote has (`warn_if_branches_not_found`,
    /// `fetch.rs:292-321` @ v0.46.0; Story 9.30).
    FetchBranchesUnmatched,
    /// The `revset-aliases."trunk()"` alias parses but does not resolve at the head (e.g. it names
    /// a remote bookmark that does not exist yet), so the call runs with `trunk()` = `root()` —
    /// the start-up fallback of the CLI's `load_from_workspace` (`cli/src/cli_util.rs:540-562` @
    /// v0.46.0; Story 9.56).
    TrunkAliasUnresolved,
    /// `jj duplicate` with a location: a duplicated commit is an ancestor of one of the new
    /// parents, so its duplicate lands among its own descendants — "Duplicating commit <12 hex> as
    /// a descendant of itself." (`cli/src/commands/duplicate.rs:149-162` @ v0.46.0; Story 9.9).
    /// One per such commit, in the duplicates' order; the duplicate is still made.
    DuplicateAsOwnDescendant,
    /// `jj duplicate -A`/`-B`: one of the new children is an ancestor of a duplicated commit, so
    /// the duplicate lands among its own ancestors — "Duplicating commit <12 hex> as an ancestor of
    /// itself." (`duplicate.rs:164-176` @ v0.46.0; Story 9.9), after every
    /// [`WarningKind::DuplicateAsOwnDescendant`].
    DuplicateAsOwnAncestor,
    /// `jj fix` could not start a configured tool — "Failed to start `<name>`."
    /// (`cli/src/commands/fix.rs` `run_tool` @ v0.46.0; Story 9.9). The tool is skipped for that
    /// file, as if it had changed nothing.
    FixToolStartFailed,
    /// A `jj fix` tool exited with a non-zero status — "Fix tool `<name>` exited with non-zero
    /// exit code for `<path>`" (`run_tool` @ v0.46.0; Story 9.9). Its output is discarded; what it
    /// wrote to stderr rides [`crate::FixResult::tool_stderr`].
    FixToolFailed,
    /// A `fix.tools.<name>.patterns` fileset parsed with a diagnostic — the CLI's
    /// `print_parse_diagnostics(ui, "In `fix.tools.<name>`", …)` (`get_tools_config` @ v0.46.0;
    /// Story 9.9). The pattern still applies.
    FilesetDiagnostic,
    /// A config layer used a deprecated key the CLI migrates at start-up — "Deprecated <source>
    /// config: <description>" (`cli/src/cli_util.rs:4726-4741` @ v0.46.0; today only
    /// `fix.tools.<name>.line-range-arg`; Story 9.9). The call runs with the migrated key; the
    /// file is not rewritten.
    ConfigDeprecated,
    /// `op show` / `op diff` could not resolve `--show-changes-in` (or
    /// `revsets.op-diff-changes-in`) against one of the two operations — "Could not resolve revset
    /// expression for elision: <error>" (`cli/src/commands/operation/diff.rs:286-305` @ v0.46.0;
    /// Story 9.21). The diff goes on without its commit section.
    OpDiffChangesUnresolved,
    /// `op abandon` rewrote the op heads, but this workspace's working copy is recorded at an
    /// operation that is not one of them, so it was left as it is — "The working copy operation
    /// <id> is not updated because it differs from the repo <ids>."
    /// (`cli/src/commands/operation/abandon.rs:136-154` @ v0.46.0; Story 9.21).
    OpAbandonWorkingCopyNotUpdated,
}

/// One warning a call produced (Story 9.32).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Warning {
    /// What the warning is about — the thing a UI switches on.
    pub kind: WarningKind,
    /// The CLI's text block for this warning, verbatim minus the `Warning: ` heading, hints and
    /// colour: the `ui.warning_*` line(s) plus the detail lines the same site writes right after
    /// it, joined by `\n`. Paths are rendered as the CLI renders them from the workspace root.
    /// For logs and tooltips only — nothing parses it.
    pub message: String,
}

/// A value and the warnings the call that produced it collected, in the CLI's print order —
/// the return shape of the handle-less verbs that can warn (Story 9.32).
#[derive(Debug)]
pub struct Warned<T> {
    /// The call's result.
    pub value: T,
    /// Its warnings; empty when the call had nothing to warn about.
    pub warnings: Vec<Warning>,
}

/// A config-derived load whose warnings are recorded once per call — the CLI performs each of
/// them once per command (`WorkspaceCommandEnvironment::new`, `cli_util.rs:934-966`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Load {
    /// The `[revset-aliases]` table (entry failures and builtin redefinitions).
    RevsetAliases,
    /// The `[fileset-aliases]` table.
    FilesetAliases,
    /// The `immutable_heads()` parse.
    ImmutableHeads,
    /// The `[template-aliases]` table (entry failures) — loaded by the start-up environment
    /// (Story 9.51).
    TemplateAliases,
    /// The `revsets.short-prefixes` parse (its diagnostics) — the start-up environment's, which
    /// the graph walk's parse of the same text repeats silently. `workspace add` reports it a
    /// second time for the new workspace, from that workspace's own start-up environment in a
    /// collector of its own (as the CLI's `for_workable_repo` prints it again; Story 9.54).
    ShortPrefixes,
}

/// The per-call warning collector (Story 9.32).
#[derive(Debug, Default)]
pub(crate) struct Warnings {
    list: Vec<Warning>,
    loaded: Vec<Load>,
}

impl Warnings {
    /// Records one warning.
    pub(crate) fn push(&mut self, kind: WarningKind, message: impl Into<String>) {
        self.list.push(Warning {
            kind,
            message: message.into(),
        });
    }

    /// Records several warnings, in order.
    pub(crate) fn extend(&mut self, warnings: impl IntoIterator<Item = Warning>) {
        self.list.extend(warnings);
    }

    /// Records the warnings of `load` — unless this call already recorded that load once.
    pub(crate) fn record_load(&mut self, load: Load, warnings: Vec<Warning>) {
        if !self.loaded.contains(&load) {
            self.loaded.push(load);
            self.list.extend(warnings);
        }
    }

    /// Hands the collected warnings out, leaving the list empty. The record-once state stays:
    /// it belongs to the call, not to the list.
    pub(crate) fn take(&mut self) -> Vec<Warning> {
        std::mem::take(&mut self.list)
    }
}

/// One warning built where it is not recorded straight into a collector — a config load's list
/// (which [`Warnings::record_load`] then records once) or a handle-less verb's result.
pub(crate) fn local(kind: WarningKind, message: impl Into<String>) -> Warning {
    Warning {
        kind,
        message: message.into(),
    }
}

/// Leaves a trace of the warnings a caller WITHOUT a warning channel collected and drops — one
/// `tracing::warn!` per warning (kind + message), as the pre-9.32 alias loader logged a skipped
/// entry. `site` names the dropping caller.
pub(crate) fn log_dropped(site: &str, warnings: Vec<Warning>) {
    for w in warnings {
        tracing::warn!(site, kind = ?w.kind, message = %w.message, "warning dropped: no warning channel");
    }
}

// ── Rendering ────────────────────────────────────────────────────────────────────

/// A repo path as the CLI renders it when run from the workspace root
/// (`RepoPathUiConverter::format_file_path` with the root as its cwd): repo-relative, `/`
/// separated, the root itself as `.`. Zanshin has no cwd, so the workspace root stands in.
pub(crate) fn ui_path(workspace_root: &Path, path: &RepoPath) -> String {
    RepoPathUiConverter::Fs {
        cwd: workspace_root.to_owned(),
        base: workspace_root.to_owned(),
    }
    .format_file_path(path)
}

/// The lines `print_error_sources` (`command_error.rs:1037-1053`) writes for `source`: one
/// `Caused by: …` line for a single cause, a numbered list below `Caused by:` for a chain.
pub(crate) fn caused_by(source: Option<&(dyn Error + 'static)>) -> Vec<String> {
    let Some(err) = source else {
        return Vec::new();
    };
    if err.source().is_none() {
        return vec![format!("Caused by: {err}")];
    }
    let mut lines = vec!["Caused by:".to_owned()];
    let mut next = Some(err);
    let mut i = 1;
    while let Some(e) = next {
        lines.push(format!("{i}: {e}"));
        next = e.source();
        i += 1;
    }
    lines
}

/// `err` and every `source()` below it, one per line — the body `print_parse_diagnostics`
/// (`command_error.rs:1112-1114`) writes after its context line.
pub(crate) fn error_chain_lines(err: &(dyn Error + 'static)) -> Vec<String> {
    let mut lines = Vec::new();
    let mut next = Some(err);
    while let Some(e) = next {
        lines.push(e.to_string());
        next = e.source();
    }
    lines
}

/// One `kind` warning per diagnostic, under the CLI's context line — a revset's
/// ([`WarningKind::RevsetDiagnostic`]: `"In revset expression"`,
/// `` "In `revset-aliases.immutable_heads()`" ``, …) or a template's
/// ([`WarningKind::TemplateDiagnostic`]: `"In template expression"`).
pub(crate) fn parse_diagnostics<T: Error + 'static>(
    kind: WarningKind,
    context: &str,
    diagnostics: &jj_lib::dsl_util::Diagnostics<T>,
) -> Vec<Warning> {
    diagnostics
        .iter()
        .map(|diag| {
            let mut lines = vec![context.to_owned()];
            lines.extend(error_chain_lines(diag));
            local(kind, lines.join("\n"))
        })
        .collect()
}

/// The finish's identity check (`cli_util.rs:2387-2401`): `None` when both `user.name` and
/// `user.email` are configured.
pub(crate) fn identity_missing(settings: &UserSettings) -> Option<Warning> {
    let not_configured = match (settings.user_name().is_empty(), settings.user_email().is_empty()) {
        (true, true) => "Name and email not configured.",
        (true, false) => "Name not configured.",
        (false, true) => "Email not configured.",
        (false, false) => return None,
    };
    Some(local(
        WarningKind::IdentityMissing,
        format!(
            "{not_configured} Until configured, your commits will be created with the empty identity, and can't be \
             pushed to remotes."
        ),
    ))
}

/// The snapshot's immutable-`@` warning (`cli_util.rs:2123-2127`).
pub(crate) const WC_IS_IMMUTABLE: &str =
    "The working-copy commit is immutable; a new commit has been created on top of it.";

/// The finish's became-immutable warning (`cli_util.rs:2338-2342`).
pub(crate) const WC_BECAME_IMMUTABLE: &str =
    "The working-copy commit became immutable; a new commit has been created on top of it.";

/// The colocated `.jjconflict` warning (`cli_util.rs:2206-2210`).
pub(crate) const JJCONFLICT_FILES: &str = "The working copy contains '.jjconflict' files. These files are used by \
                                           `jj` internally and should not be present in the working copy.";

/// `try_reset_git_head`'s warning (`cli_util.rs:2688-2691`): the error, then its sources.
pub(crate) fn git_head_update_failed(err: &(dyn Error + 'static)) -> Warning {
    let mut lines = vec![err.to_string()];
    lines.extend(caused_by(err.source()));
    local(WarningKind::GitHeadUpdateFailed, lines.join("\n"))
}

/// `print_git_export_stats`' two warnings (`git_util.rs:468-492`), bookmarks first: each
/// failed ref as `  {symbol}: {reason}: {source}…`.
pub(crate) fn git_export_failed(stats: &jj_lib::git::GitExportStats) -> Vec<Warning> {
    let block =
        |heading: &str, failures: &[(jj_lib::ref_name::RemoteRefSymbolBuf, jj_lib::git::FailedRefExportReason)]| {
            (!failures.is_empty()).then(|| {
                let mut lines = vec![heading.to_owned()];
                for (symbol, reason) in failures {
                    lines.push(format!("  {symbol}: {}", error_chain_lines(reason).join(": ")));
                }
                local(WarningKind::GitExportFailed, lines.join("\n"))
            })
        };
    [
        block("Failed to export some bookmarks:", &stats.failed_bookmarks),
        block("Failed to export some tags:", &stats.failed_tags),
    ]
    .into_iter()
    .flatten()
    .collect()
}

/// `print_failed_git_import`'s warning (`git_util.rs:270-279`): each failed ref name indented.
pub(crate) fn git_import_failed(stats: &jj_lib::git::GitImportStats) -> Option<Warning> {
    (!stats.failed_ref_names.is_empty()).then(|| {
        let mut lines = vec!["Failed to import some Git refs:".to_owned()];
        lines.extend(stats.failed_ref_names.iter().map(|name| format!("  {name}")));
        local(WarningKind::GitImportFailed, lines.join("\n"))
    })
}

/// `print_untracked_files` (`cli_util.rs:3183-3203`): only the paths refused for their SIZE —
/// a path that merely does not match `snapshot.auto-track` is never warned about
/// (`build_untracked_reason_message` → `None`).
pub(crate) fn snapshot_files_refused<'a>(
    workspace_root: &Path,
    untracked: impl IntoIterator<Item = (&'a RepoPathBuf, &'a UntrackedReason)>,
) -> Option<Warning> {
    let lines: Vec<String> = untracked
        .into_iter()
        .filter_map(|(path, reason)| match reason {
            UntrackedReason::FileTooLarge { size, max_size } => Some(format!(
                "  {}: {} ({size} bytes); the maximum size allowed is {} ({max_size} bytes)",
                ui_path(workspace_root, path),
                HumanByteSize(*size),
                HumanByteSize(*max_size),
            )),
            UntrackedReason::FileNotAutoTracked => None,
        })
        .collect();
    (!lines.is_empty()).then(|| {
        local(
            WarningKind::SnapshotFilesRefused,
            format!("Refused to snapshot some files:\n{}", lines.join("\n")),
        )
    })
}

/// `print_snapshot_stats` (`cli_util.rs:3230-3249`) minus its hint: the size refusals, then the
/// invalid-UTF-8 names (`print_invalid_utf8_paths`, `:3207-3228`).
// WHY: the CLI renders each invalid name with `{name:?}` — the quoting and `\xFF` escaping ARE
// the output (a non-UTF-8 name has no faithful `Display`), so `Debug` is the parity rendering.
#[allow(clippy::unnecessary_debug_formatting)]
pub(crate) fn snapshot_stats(workspace_root: &Path, stats: &working_copy::SnapshotStats) -> Vec<Warning> {
    let mut out: Vec<Warning> = snapshot_files_refused(workspace_root, &stats.untracked_paths)
        .into_iter()
        .collect();
    if !stats.invalid_utf8_paths.is_empty() {
        let mut lines = vec!["Skipped some paths because they are not valid UTF-8:".to_owned()];
        for (dir, name) in &stats.invalid_utf8_paths {
            lines.push(format!("  {}: {name:?}", ui_path(workspace_root, dir)));
        }
        out.push(local(WarningKind::SnapshotPathsNotUtf8, lines.join("\n")));
    }
    out
}

/// `print_checkout_stats`' warning (`cli_util.rs:3303-3309`).
pub(crate) fn checkout_files_skipped(skipped_files: u32) -> Option<Warning> {
    (skipped_files != 0).then(|| {
        local(
            WarningKind::CheckoutFilesSkipped,
            format!(
                "{skipped_files} of those updates were skipped because there were conflicting changes in the \
                 working copy."
            ),
        )
    })
}

/// `print_updated_working_copy_stats`' conflict warning (`cli_util.rs:2318-2329` @ v0.46.0,
/// Story 9.53) for the `@` a checkout just moved to: `None` when `new_wc_commit` has no conflict.
/// The caller applies the CLI's other guard — the new `@` differs from the old one.
///
/// # Errors
///
/// A conflicted path's value could not be read (the CLI's `conflict?` fails the command there).
pub(crate) fn unresolved_conflicts(
    workspace_root: &Path,
    new_wc_commit: &Commit,
) -> Result<Option<Warning>, BackendError> {
    if !new_wc_commit.has_conflict() {
        return Ok(None);
    }
    let mut conflicts = Vec::new();
    for (path, value) in new_wc_commit.tree().conflicts() {
        conflicts.push((ui_path(workspace_root, &path), value?));
    }
    Ok(Some(local(
        WarningKind::UnresolvedConflicts,
        conflicted_paths(&conflicts),
    )))
}

/// The heading plus `print_conflicted_paths`' lines (`cli_util.rs:3129-3219` @ v0.46.0): each
/// rendered path padded to the longest one (capped at 32 bytes) plus three, then a space and the
/// description of the simplified conflict.
fn conflicted_paths(conflicts: &[(String, MergedTreeValue)]) -> String {
    let max_path_len = conflicts.iter().map(|(p, _)| p.len()).max().unwrap_or(0);
    let width = max_path_len.min(32) + 3;
    let mut lines = vec!["There are unresolved conflicts at these paths:".to_owned()];
    for (path, conflict) in conflicts {
        lines.push(format!("{path:width$} {}", conflict_description(&conflict.simplify())));
    }
    lines.join("\n")
}

/// `{sides}-sided conflict`, plus ` including ` and the sorted deletions and special kinds among
/// the terms — a non-executable file adds nothing (`cli_util.rs:3150-3215` @ v0.46.0).
fn conflict_description(conflict: &MergedTreeValue) -> String {
    let sides = conflict.num_sides();
    let deletions = sides - conflict.adds().flatten().count();
    let mut seen = BTreeSet::new();
    if deletions > 0 {
        seen.insert(format!("{deletions} deletion{}", if deletions > 1 { "s" } else { "" }));
    }
    for term in conflict.removes().chain(conflict.adds()).flatten() {
        let kind = match term {
            TreeValue::File { executable: false, .. } => continue,
            TreeValue::File { executable: true, .. } => "an executable",
            TreeValue::Symlink(_) => "a symlink",
            TreeValue::Tree(_) => "a directory",
            TreeValue::GitSubmodule(_) => "a git submodule",
        };
        seen.insert(kind.to_owned());
    }
    let mut description = format!("{sides}-sided conflict");
    let seen: Vec<String> = seen.into_iter().collect();
    if let Some((last, rest)) = seen.split_last() {
        description.push_str(" including ");
        if !rest.is_empty() {
            description.push_str(&rest.join(", "));
            description.push_str(" and ");
        }
        description.push_str(last);
    }
    description
}

/// The failed clone's clean-up warning (`git/clone.rs:276-284`): the canonical target the clone
/// was rolled back in, then the I/O error of the removal.
pub(crate) fn clone_cleanup_failed(target: &Path, err: &std::io::Error) -> Warning {
    local(
        WarningKind::CloneCleanupFailed,
        format!("Failed to clean up {}: {err}", target.display()),
    )
}

/// `print_push_stats`' three blocks (`cli/src/git_util.rs:507-565` @ v0.46.0, Story 9.20), each
/// heading followed by one `  {ref}` line per entry — `(reason: {r})` appended where the remote gave
/// one; the unexported bookmarks with their error chain.
pub(crate) fn push_stats(stats: &jj_lib::git::GitPushStats) -> Vec<Warning> {
    let refs_block = |kind: WarningKind, heading: &str, refs: &[(jj_lib::ref_name::GitRefNameBuf, Option<String>)]| {
        (!refs.is_empty()).then(|| {
            let mut lines = vec![heading.to_owned()];
            for (reference, reason) in refs {
                lines.push(match reason {
                    Some(reason) => format!("  {} (reason: {reason})", reference.as_symbol()),
                    None => format!("  {}", reference.as_symbol()),
                });
            }
            local(kind, lines.join("\n"))
        })
    };
    let unexported = (!stats.unexported_bookmarks.is_empty()).then(|| {
        let mut lines = vec!["The following bookmarks couldn't be updated locally:".to_owned()];
        for (symbol, reason) in &stats.unexported_bookmarks {
            let mut line = format!("  {symbol}");
            for err in error_chain_lines(reason) {
                line.push_str(": ");
                line.push_str(&err);
            }
            lines.push(line);
        }
        local(WarningKind::PushBookmarksNotUpdatedLocally, lines.join("\n"))
    });
    [
        refs_block(
            WarningKind::PushRefsMovedOnRemote,
            "The following references unexpectedly moved on the remote:",
            &stats.rejected,
        ),
        refs_block(
            WarningKind::PushRemoteRejected,
            "The remote rejected the following updates:",
            &stats.remote_rejected,
        ),
        unexported,
    ]
    .into_iter()
    .flatten()
    .collect()
}

/// The explicit `paths` absent from EVERY tree in `trees`, in request order — the filter of
/// `print_unmatched_explicit_paths` (`cli_util.rs:3329-3333`).
///
/// # Errors
///
/// A tree read failed (the CLI unwraps there; Zanshin reports it).
pub(crate) fn unmatched_paths<'p>(
    paths: &'p [RepoPathBuf],
    trees: &[&MergedTree],
) -> Result<Vec<&'p RepoPathBuf>, jj_lib::backend::BackendError> {
    let mut unmatched: Vec<&RepoPathBuf> = paths.iter().collect();
    for tree in trees {
        let mut kept = Vec::with_capacity(unmatched.len());
        for path in unmatched {
            if pollster::block_on(tree.path_value(path))?.is_absent() {
                kept.push(path);
            }
        }
        unmatched = kept;
    }
    Ok(unmatched)
}

/// `print_unmatched_explicit_paths`' warning (`cli_util.rs:3335-3344`); `None` when every path
/// matched.
pub(crate) fn paths_unmatched(workspace_root: &Path, unmatched: &[&RepoPathBuf]) -> Option<Warning> {
    (!unmatched.is_empty()).then(|| {
        let paths: Vec<String> = unmatched.iter().map(|p| ui_path(workspace_root, p)).collect();
        local(
            WarningKind::PathsUnmatched,
            format!("No matching entries for paths: {}", paths.join(", ")),
        )
    })
}

/// [`unmatched_paths`] + [`paths_unmatched`], recorded into `sink` — the whole
/// `print_unmatched_explicit_paths` call.
///
/// # Errors
///
/// A tree read failed.
pub(crate) fn warn_unmatched_paths(
    sink: &mut Warnings,
    workspace_root: &Path,
    paths: &[RepoPathBuf],
    trees: &[&MergedTree],
) -> Result<(), jj_lib::backend::BackendError> {
    let unmatched = unmatched_paths(paths, trees)?;
    sink.extend(paths_unmatched(workspace_root, &unmatched));
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use jj_lib::repo_path::RepoPathBuf;

    use super::{
        caused_by, checkout_files_skipped, clone_cleanup_failed, git_head_update_failed, identity_missing, local,
        paths_unmatched, ui_path, Load, WarningKind, Warnings,
    };

    #[derive(Debug)]
    struct Leaf(&'static str);
    impl std::fmt::Display for Leaf {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str(self.0)
        }
    }
    impl std::error::Error for Leaf {}

    #[derive(Debug)]
    struct Wrap(&'static str, Box<dyn std::error::Error + 'static>);
    impl std::fmt::Display for Wrap {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str(self.0)
        }
    }
    impl std::error::Error for Wrap {
        fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
            Some(self.1.as_ref())
        }
    }

    /// A load recorded twice in one call records its warnings once; a different load still
    /// records, and ordinary pushes keep their order around both.
    #[test]
    fn a_load_is_recorded_once_per_call_and_order_is_kept() {
        let mut sink = Warnings::default();
        sink.push(WarningKind::PathsUnmatched, "first");
        sink.record_load(
            Load::RevsetAliases,
            vec![local(WarningKind::ConfigAliasInvalid, "alias")],
        );
        sink.record_load(
            Load::RevsetAliases,
            vec![local(WarningKind::ConfigAliasInvalid, "alias")],
        );
        sink.record_load(Load::ImmutableHeads, vec![local(WarningKind::RevsetDiagnostic, "diag")]);
        sink.push(WarningKind::IdentityMissing, "last");
        let messages: Vec<String> = sink.take().into_iter().map(|w| w.message).collect();
        assert_eq!(messages, ["first", "alias", "diag", "last"]);
        // The record-once state belongs to the call, not to the handed-out list.
        sink.record_load(
            Load::RevsetAliases,
            vec![local(WarningKind::ConfigAliasInvalid, "again")],
        );
        assert!(sink.take().is_empty());
    }

    /// The integration witness (`tests/it/snapshot_colocated.rs`, a held `.git/HEAD.lock`) can
    /// only produce the one error jj-lib raises there; this pins the message shapes it cannot
    /// vary — `print_error_sources`' single-cause and `Caused by:` chain forms.
    #[test]
    fn git_head_update_failed_renders_the_error_and_its_sources_like_the_cli() {
        let single = Wrap("Failed to update Git HEAD ref", Box::new(Leaf("lock held")));
        let w = git_head_update_failed(&single);
        assert_eq!(w.kind, WarningKind::GitHeadUpdateFailed);
        assert_eq!(w.message, "Failed to update Git HEAD ref\nCaused by: lock held");

        let chain = Wrap(
            "Failed to update Git HEAD ref",
            Box::new(Wrap("reference edit failed", Box::new(Leaf("lock held")))),
        );
        assert_eq!(
            git_head_update_failed(&chain).message,
            "Failed to update Git HEAD ref\nCaused by:\n1: reference edit failed\n2: lock held"
        );
        assert!(caused_by(None).is_empty());
        assert_eq!(git_head_update_failed(&Leaf("bare")).message, "bare");
    }

    /// Story 9.33: the CLI's `"Failed to clean up {path}: {err}"` — the target as displayed, then
    /// the removal's I/O error.
    #[test]
    fn a_failed_clone_clean_up_names_the_target_and_the_io_error() {
        let err = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "Permission denied");
        let w = clone_cleanup_failed(Path::new("/ws/target"), &err);
        assert_eq!(w.kind, WarningKind::CloneCleanupFailed);
        assert_eq!(w.message, "Failed to clean up /ws/target: Permission denied");
    }

    /// Story 9.53: `print_conflicted_paths`' descriptions — deletions first (a count sorts
    /// before the kinds), the special kinds of removes and adds, a plain file adding nothing.
    #[test]
    fn conflict_descriptions_name_deletions_and_special_kinds_like_the_cli() {
        use jj_lib::backend::{CopyId, FileId, SymlinkId, TreeId, TreeValue};
        use jj_lib::merge::Merge;

        let file = |byte: u8, executable: bool| {
            Some(TreeValue::File {
                id: FileId::new(vec![byte]),
                executable,
                copy_id: CopyId::placeholder(),
            })
        };
        let describe = |values: Vec<Option<TreeValue>>| super::conflict_description(&Merge::from_vec(values));

        assert_eq!(
            describe(vec![file(1, false), file(0, false), file(2, false)]),
            "2-sided conflict"
        );
        assert_eq!(
            describe(vec![None, file(0, false), file(2, true)]),
            "2-sided conflict including 1 deletion and an executable"
        );
        assert_eq!(
            describe(vec![
                file(1, false),
                file(0, false),
                Some(TreeValue::Symlink(SymlinkId::new(vec![3]))),
            ]),
            "2-sided conflict including a symlink"
        );
        assert_eq!(
            describe(vec![
                None,
                file(0, false),
                None,
                file(4, false),
                Some(TreeValue::Tree(TreeId::new(vec![5]))),
            ]),
            "3-sided conflict including 2 deletions and a directory"
        );
        assert_eq!(
            describe(vec![
                Some(TreeValue::GitSubmodule(jj_lib::backend::CommitId::new(vec![6]))),
                file(0, true),
                Some(TreeValue::Symlink(SymlinkId::new(vec![7]))),
            ]),
            "2-sided conflict including a git submodule, a symlink and an executable"
        );
    }

    /// Story 9.53: the heading, then each path padded to the longest (`min(len, 32) + 3`) and a
    /// space — the CLI's golden `c.txt    2-sided conflict`, and a cap at 35 for long paths.
    #[test]
    fn conflicted_paths_pad_to_the_longest_path_capped_at_32() {
        use jj_lib::backend::{CopyId, FileId, TreeValue};
        use jj_lib::merge::Merge;

        let file = |byte: u8| {
            Some(TreeValue::File {
                id: FileId::new(vec![byte]),
                executable: false,
                copy_id: CopyId::placeholder(),
            })
        };
        let two_sided = || Merge::from_vec(vec![file(1), file(0), file(2)]);
        assert_eq!(
            super::conflicted_paths(&[("c.txt".to_owned(), two_sided())]),
            "There are unresolved conflicts at these paths:\nc.txt    2-sided conflict"
        );
        let long = "d".repeat(40);
        let message = super::conflicted_paths(&[("a".to_owned(), two_sided()), (long.clone(), two_sided())]);
        assert_eq!(
            message,
            format!(
                "There are unresolved conflicts at these paths:\na{} 2-sided conflict\n{long} 2-sided conflict",
                " ".repeat(34)
            )
        );
    }

    #[test]
    fn checkout_skips_warn_only_when_something_was_skipped() {
        assert!(checkout_files_skipped(0).is_none());
        let w = checkout_files_skipped(2).expect("two skipped");
        assert_eq!(
            w.message,
            "2 of those updates were skipped because there were conflicting changes in the working copy."
        );
    }

    #[test]
    fn identity_warning_has_the_cli_three_variants() {
        let settings = |name: &str, email: &str| {
            let mut config = jj_lib::config::StackedConfig::with_defaults();
            let mut layer = jj_lib::config::ConfigLayer::empty(jj_lib::config::ConfigSource::User);
            layer.set_value("user.name", name).expect("name");
            layer.set_value("user.email", email).expect("email");
            config.add_layer(layer);
            jj_lib::settings::UserSettings::from_config_and_home_dir(config, None).expect("settings")
        };
        let tail = " Until configured, your commits will be created with the empty identity, and can't be pushed \
                    to remotes.";
        assert_eq!(
            identity_missing(&settings("", "")).expect("both").message,
            format!("Name and email not configured.{tail}")
        );
        assert_eq!(
            identity_missing(&settings("", "a@b")).expect("name").message,
            format!("Name not configured.{tail}")
        );
        assert_eq!(
            identity_missing(&settings("A", "")).expect("email").message,
            format!("Email not configured.{tail}")
        );
        assert!(identity_missing(&settings("A", "a@b")).is_none());
    }

    /// Invalid-UTF-8 NAMES cannot be created on APFS, so `print_invalid_utf8_paths`' block is
    /// pinned here: the directory as the CLI renders it (`.` for the root), the name `Debug`-quoted.
    #[cfg(unix)]
    #[test]
    fn invalid_utf8_names_render_like_the_cli_after_the_size_refusals() {
        use std::collections::{BTreeMap, BTreeSet};
        use std::ffi::OsString;
        use std::os::unix::ffi::OsStringExt as _;

        use jj_lib::working_copy::{SnapshotStats, UntrackedReason};

        let bad = OsString::from_vec(vec![b'a', 0xff]);
        let stats = SnapshotStats {
            untracked_paths: BTreeMap::from([
                (
                    RepoPathBuf::from_internal_string("big").expect("path"),
                    UntrackedReason::FileTooLarge {
                        size: 2048,
                        max_size: 1024,
                    },
                ),
                (
                    RepoPathBuf::from_internal_string("quiet").expect("path"),
                    UntrackedReason::FileNotAutoTracked,
                ),
            ]),
            invalid_utf8_paths: BTreeSet::from([
                (RepoPathBuf::root(), bad.clone()),
                (RepoPathBuf::from_internal_string("sub").expect("path"), bad),
            ]),
        };
        let warnings = super::snapshot_stats(Path::new("/ws"), &stats);
        assert_eq!(
            warnings.iter().map(|w| w.kind).collect::<Vec<_>>(),
            [WarningKind::SnapshotFilesRefused, WarningKind::SnapshotPathsNotUtf8]
        );
        assert_eq!(
            warnings[0].message,
            "Refused to snapshot some files:\n  big: 2.0KiB (2048 bytes); the maximum size allowed is 1.0KiB (1024 bytes)"
        );
        assert_eq!(
            warnings[1].message,
            "Skipped some paths because they are not valid UTF-8:\n  .: \"a\\xFF\"\n  sub: \"a\\xFF\""
        );
    }

    #[test]
    fn paths_render_from_the_workspace_root_and_join_with_commas() {
        let root = Path::new("/ws");
        let a = RepoPathBuf::from_internal_string("dir/a.txt").expect("path");
        let b = RepoPathBuf::from_internal_string("b").expect("path");
        assert_eq!(ui_path(root, jj_lib::repo_path::RepoPath::root()), ".");
        let w = paths_unmatched(root, &[&a, &b]).expect("two unmatched");
        assert_eq!(w.message, "No matching entries for paths: dir/a.txt, b");
        assert!(paths_unmatched(root, &[]).is_none());
    }

    #[test]
    fn push_stats_render_the_cli_blocks_with_and_without_a_reason() {
        use jj_lib::git::{FailedRefExportReason, GitPushStats};
        use jj_lib::ref_name::{GitRefNameBuf, RefNameBuf, RemoteNameBuf, RemoteRefSymbolBuf};

        assert!(super::push_stats(&GitPushStats::default()).is_empty());
        let stats = GitPushStats {
            pushed: vec![GitRefNameBuf::from("refs/heads/ok")],
            rejected: vec![(GitRefNameBuf::from("refs/heads/a"), None)],
            remote_rejected: vec![(GitRefNameBuf::from("refs/heads/b"), Some("hook declined".to_owned()))],
            unexported_bookmarks: vec![(
                RemoteRefSymbolBuf {
                    name: RefNameBuf::from("c"),
                    remote: RemoteNameBuf::from("origin"),
                },
                FailedRefExportReason::InvalidGitName,
            )],
        };
        let warnings = super::push_stats(&stats);
        let kinds: Vec<WarningKind> = warnings.iter().map(|w| w.kind).collect();
        assert_eq!(
            kinds,
            [
                WarningKind::PushRefsMovedOnRemote,
                WarningKind::PushRemoteRejected,
                WarningKind::PushBookmarksNotUpdatedLocally,
            ]
        );
        assert_eq!(
            warnings[0].message,
            "The following references unexpectedly moved on the remote:\n  refs/heads/a"
        );
        assert_eq!(
            warnings[1].message,
            "The remote rejected the following updates:\n  refs/heads/b (reason: hook declined)"
        );
        assert_eq!(
            warnings[2].message,
            "The following bookmarks couldn't be updated locally:\n  c@origin: Name is not allowed in Git"
        );
    }
}
