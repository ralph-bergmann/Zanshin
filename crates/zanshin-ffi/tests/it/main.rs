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

/// A `BookmarkListRequest` buffer for `zanshin_bookmarks` (Story 9.19): every argument absent,
/// `all_remotes` as given — the row set the read returned before it took the CLI's filters.
pub(crate) fn bookmark_list_request(all_remotes: bool) -> Vec<u8> {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64);
    let req = zanshin_ffi::fbs::BookmarkListRequest::create(
        &mut b,
        &zanshin_ffi::fbs::BookmarkListRequestArgs {
            kind: zanshin_ffi::fbs::RequestKind::BookmarkList,
            all_remotes,
            ..Default::default()
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// `zanshin_bookmarks` with the `--all-remotes` request of [`bookmark_list_request`].
///
/// # Safety
/// `handle` follows `zanshin_bookmarks`' handle contract; the returned token is the caller's to
/// free exactly once.
pub(crate) unsafe fn bookmarks_all_remotes(handle: u64) -> *mut zanshin_ffi::ffi_strings::ZanshinBuf {
    let req = bookmark_list_request(true);
    // SAFETY: the caller upholds the handle contract; `req` outlives the call.
    unsafe { zanshin_ffi::bookmarks::zanshin_bookmarks(handle, req.as_ptr(), req.len()) }
}

mod bookmark_ops_ffi;
mod bookmarks_ffi;
mod change_ffi;
mod commit_contents_ffi;
mod commit_ffi;
mod commit_views_ffi;
mod config_ffi;
mod diff_ffi;
mod drop_actions_ffi;
mod environment_ffi;
mod events_ffi;
mod ffi_abi_doc_sync;
mod file_ffi;
mod file_ops_ffi;
mod git_ffi;
mod graph_ffi;
mod log_defaults_ffi;
mod metaedit_duplicate_fix_ffi;
mod movement_ffi;
mod op_log_ffi;
mod push_ffi;
mod push_remotes_ffi;
mod rebase_ffi;
mod remote_changes_ffi;
mod remotes_ffi;
mod repo_config_ffi;
mod repo_ffi;
mod repo_write_ffi;
mod resolve_ffi;
mod revert_ffi;
mod revset_search_ffi;
mod secure_config_ffi;
mod select_tree_ffi;
mod snapshot_ffi;
mod squash_split_ffi;
mod status_ffi;
mod watcher;
mod workspace_ffi;
