// SPDX-License-Identifier: MIT

//! `zanshin-ffi`'s integration tests: ONE test binary (Story 9.55). Every former `tests/<name>.rs`
//! binary is the module `<name>` here, so its tests are named `<name>::<test>`; a new
//! integration-test file is a new module below.
//!
//! All modules share one process environment, which therefore has exactly one writer:
//! `test_helpers::pin_test_env`, called first by every test that reads the environment through
//! jj. A test that needs a different environment — repoint or unset a variable, adopt a
//! login-shell environment — or that owns the FFI event sink starts with
//! `test_helpers::own_process!` and runs as the only test of a child process of this binary, so
//! the shared environment never changes after the pin. The one exception is `push_ffi`'s two
//! sink tests: they stay in this process under its `SINK_GUARD` and read only events of their
//! own session id.

mod bookmark_ops_ffi;
mod bookmarks_ffi;
mod change_ffi;
mod commit_contents_ffi;
mod commit_ffi;
mod commit_views_ffi;
mod config_ffi;
mod drop_actions_ffi;
mod environment_ffi;
mod events_ffi;
mod ffi_abi_doc_sync;
mod file_ffi;
mod file_ops_ffi;
mod git_ffi;
mod graph_ffi;
mod log_defaults_ffi;
mod op_log_ffi;
mod push_ffi;
mod push_remotes_ffi;
mod remote_changes_ffi;
mod remotes_ffi;
mod repo_config_ffi;
mod repo_ffi;
mod repo_write_ffi;
mod secure_config_ffi;
mod snapshot_ffi;
mod squash_split_ffi;
mod status_ffi;
mod watcher;
mod workspace_ffi;
