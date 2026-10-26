// SPDX-License-Identifier: MIT

//! `zanshin-jj`'s integration tests: ONE test binary (Story 9.55). Every former `tests/<name>.rs`
//! binary is the module `<name>` here, so its tests are named `<name>::<test>`; a new
//! integration-test file is a new module below.
//!
//! All modules share one process environment, which therefore has exactly one writer:
//! `test_helpers::pin_test_env`, called first by every test that reads the environment through
//! jj. A test that needs a different environment — repoint or unset a variable, adopt a
//! login-shell environment — starts with `test_helpers::own_process!` and runs as the only
//! test of a child process of this binary, so the shared environment never changes after the pin.

/// `jj bookmark list --all-remotes`' options — the row set the read returned before Story 9.19
/// gave it the CLI's filters, which the callers outside the list tests still want.
pub(crate) fn all_remotes() -> zanshin_jj::BookmarkListOptions {
    zanshin_jj::BookmarkListOptions {
        all_remotes: true,
        ..Default::default()
    }
}

mod api_stability;
mod arg_refusals;
mod bookmark_move;
mod bookmark_ops;
mod bookmark_tracking;
mod bookmarks;
mod change;
mod change_id_prefix;
mod clone_cancel;
mod clone_config;
mod clone_init;
mod commit;
mod commit_contents;
mod commit_views;
mod concurrent_writes;
mod config;
mod config_cmd;
mod config_cmd_user;
mod config_identity;
mod config_user_layer;
mod content_ops;
mod convert;
mod convert_alias_write_failure;
mod creation_warnings;
mod detect;
mod diffedit;
mod drop_actions;
mod duplicate;
mod file_chmod;
mod file_delete;
mod file_edit;
mod file_reads;
mod file_track_home_git_ignore;
mod file_track_untrack;
mod find_repo_root;
mod fix;
mod git_colocation;
mod git_fetch_parity;
mod git_remotes;
mod git_sync;
mod graph;
mod graph_topology;
mod id_prefix_context;
mod login_shell_environment;
mod metaedit;
mod movement;
mod mutate;
mod network_cancel;
mod new_insert;
mod op_abandon;
mod op_integrate;
mod op_log;
mod op_restore_revert;
mod op_show_diff;
mod op_support;
mod op_workspace_name;
mod parallelize_arrange;
mod push;
mod push_remotes;
mod rebase;
mod redo;
mod remote_changes;
mod remotes;
mod remotes_write;
mod repo;
mod resolve;
mod revert;
mod revset;
mod revset_search;
mod secure_config_fixups;
mod secure_config_fixups_user;
mod select_tree;
mod simplify_parents;
mod snapshot_colocated;
mod snapshot_precondition;
mod snapshot_watchman;
mod squash_split;
mod status;
mod templates;
mod view;
mod warnings;
mod when_commands;
mod workspace;
mod workspace_add;
mod workspace_ops;
mod workspace_update_stale;
