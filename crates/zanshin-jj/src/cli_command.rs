// SPDX-License-Identifier: MIT

//! The jj CLI command each Zanshin call plays, for `--when.commands` config scopes (Story 9.41).
//!
//! The CLI names its command before its final start-up resolution
//! (`config_env.set_command_name(command_name(&matches))`, `cli/src/cli_util.rs:4701` @ v0.46.0):
//! the canonical clap subcommand chain joined by spaces (`command_name`, `:4358-4368`), so a
//! `[[--scope]]` with `--when.commands = ["git"]` applies to `jj git fetch` and not to `jj log`.
//! Every call start in [`crate::Repo`], every creation path and every config verb takes one entry
//! of this table; jj-lib matches it against the scopes (`config_resolver.rs::matches_command`:
//! a prefix by whole words; a scope with `--when.commands` never matches [`NO_COMMAND`]).
//!
//! The unit test below walks the pinned jj-cli's clap tree (`jj_cli::commands::default_app()`), so
//! a pin bump that renames a command fails here. Which entry each call site takes is witnessed
//! elsewhere: a new `Repo` verb adds its line to `repo.rs`'s `every_verb_resolves_for_its_cli_command`,
//! a new config verb to `tests/it/when_commands.rs`' `every_config_verb_resolves_for_its_cli_command`.

/// The CLI command a call resolves its config stack for — [`NO_COMMAND`] for a call no CLI
/// command corresponds to.
pub(crate) type CliCommand = Option<&'static str>;

/// No CLI command: the state the CLI resolves in before a subcommand is known — `Repo::open`
/// / `open_with_report`, `select_tree` without a verb, and the own pre-verb snapshot of
/// `drop_actions` / `change_actions` (each of their rows resolves for its own verb's command).
pub(crate) const NO_COMMAND: CliCommand = None;

macro_rules! cli_commands {
    ($($(#[$doc:meta])* $name:ident = $text:literal;)*) => {
        $($(#[$doc])* pub(crate) const $name: CliCommand = Some($text);)*

        /// Every name of the table, for the audit test.
        #[cfg(test)]
        const ALL: &[&str] = &[$($text),*];
    };
}

cli_commands! {
    /// `Repo::abandon`.
    ABANDON = "abandon";
    /// `Repo::absorb`.
    ABSORB = "absorb";
    /// `Repo::arrange`.
    ARRANGE = "arrange";
    /// `Repo::bookmark_advance`.
    BOOKMARK_ADVANCE = "bookmark advance";
    /// `Repo::bookmark_create`.
    BOOKMARK_CREATE = "bookmark create";
    /// `Repo::bookmark_delete`.
    BOOKMARK_DELETE = "bookmark delete";
    /// `Repo::bookmark_forget`.
    BOOKMARK_FORGET = "bookmark forget";
    /// `Repo::list_bookmarks`.
    BOOKMARK_LIST = "bookmark list";
    /// `Repo::bookmark_move`.
    BOOKMARK_MOVE = "bookmark move";
    /// `Repo::bookmark_rename`.
    BOOKMARK_RENAME = "bookmark rename";
    /// `Repo::bookmark_set`.
    BOOKMARK_SET = "bookmark set";
    /// `Repo::bookmark_track`.
    BOOKMARK_TRACK = "bookmark track";
    /// `Repo::bookmark_untrack`.
    BOOKMARK_UNTRACK = "bookmark untrack";
    /// `Repo::commit`.
    COMMIT = "commit";
    /// `config_file_read` / `config_file_write`, the two halves of `jj config edit`.
    CONFIG_EDIT = "config edit";
    /// `config_gc_list` / `config_gc_delete`.
    CONFIG_GC = "config gc";
    /// `config_get`.
    CONFIG_GET = "config get";
    /// `config_list`.
    CONFIG_LIST = "config list";
    /// `config_path`.
    CONFIG_PATH = "config path";
    /// `config_set`, and its working-copy author check's snapshot (`Repo::snapshot_as`).
    CONFIG_SET = "config set";
    /// `config_unset`.
    CONFIG_UNSET = "config unset";
    /// `Repo::describe`.
    DESCRIBE = "describe";
    /// `Repo::compute_hunks`.
    DIFF = "diff";
    /// `Repo::diffedit`.
    DIFFEDIT = "diffedit";
    /// `Repo::duplicate`.
    DUPLICATE = "duplicate";
    /// `Repo::edit`.
    EDIT = "edit";
    /// `Repo::evolog`.
    EVOLOG = "evolog";
    /// `Repo::file_annotate`.
    FILE_ANNOTATE = "file annotate";
    /// `Repo::file_chmod`.
    FILE_CHMOD = "file chmod";
    /// `Repo::file_delete`.
    FILE_DELETE = "file delete";
    /// `Repo::file_edit`.
    FILE_EDIT = "file edit";
    /// `Repo::file_list`.
    FILE_LIST = "file list";
    /// `Repo::file_search`.
    FILE_SEARCH = "file search";
    /// `Repo::file_show`.
    FILE_SHOW = "file show";
    /// `Repo::file_track`.
    FILE_TRACK = "file track";
    /// `Repo::file_untrack`.
    FILE_UNTRACK = "file untrack";
    /// `Repo::fix`.
    FIX = "fix";
    /// `Repo::clone` — every load of the creation.
    GIT_CLONE = "git clone";
    /// `Repo::git_colocation_disable`.
    GIT_COLOCATION_DISABLE = "git colocation disable";
    /// `Repo::git_colocation_enable`.
    GIT_COLOCATION_ENABLE = "git colocation enable";
    /// `Repo::git_colocation_status`.
    GIT_COLOCATION_STATUS = "git colocation status";
    /// `Repo::git_export`.
    GIT_EXPORT = "git export";
    /// `Repo::git_fetch`; `Repo::git_fetch_remotes` (the remotes it fetches by default) and
    /// `Repo::remote_changes` (the Fetch button's poll) replace parts of it.
    GIT_FETCH = "git fetch";
    /// `Repo::git_import`.
    GIT_IMPORT = "git import";
    /// `Repo::init`, `convert_colocated`, `convert_import` — `jj git init` with and without
    /// `--git-repo`, every load of the creation.
    GIT_INIT = "git init";
    /// `Repo::git_push`; `Repo::git_push_remotes` (the remotes it pushes to by default).
    GIT_PUSH = "git push";
    /// `Repo::git_remote_add`.
    GIT_REMOTE_ADD = "git remote add";
    /// `Repo::list_remotes`.
    GIT_REMOTE_LIST = "git remote list";
    /// `Repo::git_remote_remove`.
    GIT_REMOTE_REMOVE = "git remote remove";
    /// `Repo::git_remote_rename`.
    GIT_REMOTE_RENAME = "git remote rename";
    /// `Repo::git_remote_set_url`.
    GIT_REMOTE_SET_URL = "git remote set-url";
    /// `Repo::interdiff`.
    INTERDIFF = "interdiff";
    /// The reads replacing `jj log`'s output: `Repo::walk_graph`, `graph_topology`,
    /// `eval_revset`, `log_defaults`, `revset_counts`, `find_changes`, `list_heads`, and the
    /// `resolve_revset` oracle.
    LOG = "log";
    /// `Repo::metaedit`.
    METAEDIT = "metaedit";
    /// `Repo::new_change`.
    NEW = "new";
    /// `Repo::move_working_copy` / `movement_targets` towards the descendants.
    NEXT = "next";
    /// `Repo::op_abandon`.
    OPERATION_ABANDON = "operation abandon";
    /// `Repo::op_diff`.
    OPERATION_DIFF = "operation diff";
    /// `Repo::op_integrate`.
    OPERATION_INTEGRATE = "operation integrate";
    /// `Repo::op_log`.
    OPERATION_LOG = "operation log";
    /// `Repo::op_restore`.
    OPERATION_RESTORE = "operation restore";
    /// `Repo::op_revert`.
    OPERATION_REVERT = "operation revert";
    /// `Repo::op_show`.
    OPERATION_SHOW = "operation show";
    /// `Repo::parallelize`.
    PARALLELIZE = "parallelize";
    /// `Repo::move_working_copy` / `movement_targets` towards the ancestors.
    PREV = "prev";
    /// `Repo::rebase`.
    REBASE = "rebase";
    /// `Repo::redo`.
    REDO = "redo";
    /// `Repo::resolve`; `Repo::resolve_list` is `jj resolve --list`.
    RESOLVE = "resolve";
    /// `Repo::restore`.
    RESTORE = "restore";
    /// `Repo::revert`.
    REVERT = "revert";
    /// `Repo::show`; `Repo::get_change` reads one change's `jj show` facts.
    SHOW = "show";
    /// `Repo::simplify_parents`.
    SIMPLIFY_PARENTS = "simplify-parents";
    /// `Repo::split`.
    SPLIT = "split";
    /// `Repo::squash`; `Repo::squash_plan` is the squash run up to its plan.
    SQUASH = "squash";
    /// `Repo::status`.
    STATUS = "status";
    /// `Repo::list_tags`.
    TAG_LIST = "tag list";
    /// `Repo::undo`.
    UNDO = "undo";
    /// `Repo::snapshot` (not `config set`'s author check, which plays `config set`).
    UTIL_SNAPSHOT = "util snapshot";
    /// `Repo::workspace_add`.
    WORKSPACE_ADD = "workspace add";
    /// `Repo::workspace_forget`.
    WORKSPACE_FORGET = "workspace forget";
    /// `Repo::list_workspaces`; `Repo::list_working_copies` is its view half.
    WORKSPACE_LIST = "workspace list";
    /// `Repo::workspace_remove`.
    WORKSPACE_REMOVE = "workspace remove";
    /// `Repo::workspace_rename`.
    WORKSPACE_RENAME = "workspace rename";
    /// `Repo::resolve_workspace_root`.
    WORKSPACE_ROOT = "workspace root";
    /// `Repo::workspace_update_stale`.
    WORKSPACE_UPDATE_STALE = "workspace update-stale";
}

#[cfg(test)]
mod tests {
    use super::ALL;

    /// The audit: every name is a canonical subcommand path of the pinned jj-cli — each word the
    /// NAME of a subcommand (an alias such as `op` is not), as the CLI's `command_name` builds it.
    #[test]
    fn every_name_is_a_canonical_subcommand_path_of_the_pinned_cli() {
        let app = jj_cli::commands::default_app();
        let mut known = Vec::new();
        let mut stack = vec![(String::new(), &app)];
        while let Some((path, command)) = stack.pop() {
            for sub in command.get_subcommands() {
                let sub_path = if path.is_empty() {
                    sub.get_name().to_owned()
                } else {
                    format!("{path} {}", sub.get_name())
                };
                known.push(sub_path.clone());
                stack.push((sub_path, sub));
            }
        }
        let unknown: Vec<&&str> = ALL.iter().filter(|name| !known.iter().any(|k| k == **name)).collect();
        assert!(
            unknown.is_empty(),
            "not canonical subcommand paths of the pinned jj-cli: {unknown:?}"
        );
    }

    #[test]
    fn the_table_has_no_duplicate_names() {
        let mut names = ALL.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), ALL.len());
    }
}
