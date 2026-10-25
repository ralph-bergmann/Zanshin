// SPDX-License-Identifier: MIT

#![deny(missing_docs)]

//! `zanshin-jj` — anti-corruption layer over `jj-lib` (FR-JJ-16).
//!
//! # Invariant
//!
//! This crate is the **sole** importer of `jj_lib` among Zanshin's
//! production/library crates — `zanshin-ffi` and `zanshin-mcp` consume its typed
//! API, never `jj_lib` directly (the `xtask` fixture generator also uses
//! `jj_lib`, but only as a build-time tool).
//! Its public API is **stable**: when `jj-lib` changes its internal types or
//! APIs, the diff is absorbed inside this crate and the public surface of
//! `zanshin-jj` remains unchanged.
//!
//! # No `jj_lib` types in public positions
//!
//! The public API is **fully `jj_lib`-type-free**: every `jj_lib` failure is
//! flattened to an opaque `Backend(String)` or `JjLibError(String)` error
//! variant.  No `jj_lib` type appears in any public signature, struct field,
//! or error variant.  There is no exception to this rule.
//!
//! **Adding `pub use jj_lib::…` is forbidden** — doing so would leak an
//! internal type into the public API and break the invariant (FR-JJ-16).
//! The `test-jj-adapter-hygiene` gate in `Makefile.toml` enforces this
//! mechanically; `crates/zanshin-jj/tests/it/api_stability.rs` asserts the
//! complete surface structurally.

pub(crate) mod arrange;
pub(crate) mod bookmark_ops;
pub(crate) mod bookmarks;
pub mod cancel;
pub(crate) mod change;
pub(crate) mod cli_command;
pub(crate) mod colocation;
pub(crate) mod commit;
pub(crate) mod commit_content;
pub(crate) mod commit_meta;
pub(crate) mod commit_views;
pub(crate) mod config;
pub(crate) mod config_cmd;
pub(crate) mod convert;
pub(crate) mod creation;
pub(crate) mod detect;
pub(crate) mod diffedit;
pub(crate) mod drop_actions;
pub(crate) mod duplicate;
pub(crate) mod environment;
pub(crate) mod file;
pub(crate) mod fix;
pub(crate) mod git;
pub(crate) mod graph;
pub(crate) mod metaedit;
pub(crate) mod movement;
pub(crate) mod mutate;
pub(crate) mod op_diff;
pub(crate) mod op_log;
pub(crate) mod op_support;
pub(crate) mod parallelize;
pub(crate) mod push;
pub(crate) mod rebase;
pub(crate) mod remote_changes;
pub(crate) mod remotes;
mod repo;
pub(crate) mod resolve;
pub(crate) mod revert;
pub(crate) mod revset;
pub(crate) mod revset_search;
pub(crate) mod select_tree;
pub(crate) mod simplify_parents;
pub(crate) mod snapshot;
pub(crate) mod squash_split;
pub(crate) mod stale;
pub(crate) mod status;
pub(crate) mod template;
pub(crate) mod topology;
pub(crate) mod version;
pub(crate) mod view;
pub(crate) mod warning;
pub(crate) mod wc_ops;
pub(crate) mod workspace;
pub(crate) mod workspace_add;
pub(crate) mod workspace_ops;

pub use arrange::{ArrangeAction, ArrangeOptions};
pub use bookmark_ops::BookmarkMoveOptions;
pub use bookmarks::{Bookmark, BookmarkError, BookmarkKind, BookmarkListOptions, BookmarkSortKey, RefDistance};
pub use change::{Change, ChangeError, CommitId, ConflictState, Signature, Timestamp, Timestamps};
pub use colocation::{GitColocationResult, GitColocationStatus};
pub use commit::CommitOptions;
pub use commit_content::{CommitContent, CommitContentError};
pub use commit_meta::{CommitMeta, CommitRef};
pub use commit_views::{CommitViewError, EvologEntry, InterdiffView, RevisionRef, ShowEntry};
pub use config::{ConfigError, LogDefaults};
pub use config_cmd::{
    config_file_read, config_file_write, config_gc_delete, config_gc_list, config_get, config_list, config_path,
    config_set, config_unset, ConfigCmdError, ConfigEntry, ConfigFileText, ConfigGcFailure, ConfigGcResult,
    ConfigListQuery, ConfigOutcome, ConfigScope, ConfigSetOutcome, ConfigSetResult, ConfigTarget, ConfigValueSource,
    MissingRepoConfig, WorkingCopyAuthor,
};
pub use convert::{convert_colocated, convert_import};
pub use creation::{CloneOptions, InitOptions, ObjectHash};
pub use detect::{detect_repo, find_repo_root, DetectError, RepoKind, RepoRoot};
pub use diffedit::DiffeditOptions;
pub use drop_actions::{
    ActionOutcome, ActionStatus, ChangeActions, DropAction, DropActions, DropLocation, DropSource, DropVerb,
};
pub use duplicate::DuplicateOptions;
pub use environment::adopt_environment;
pub use file::{AnnotationLine, FileContents, FileEntry, FileError, FileSearch, FileType, SearchMatch, ShownFile};
pub use fix::{FixOptions, FixResult, FixToolStderr};
pub use git::{GitExportFailure, GitExportResult, GitImportResult, GitRefUpdate, GitRefUpdateKind};
pub use graph::{GraphEdge, GraphEdgeKind, GraphNode, DEFAULT_GRAPH_PRIORITIZE};
pub use metaedit::MetaeditOptions;
pub use movement::{Direction, MovementOptions, MovementTarget, MovementTargets};
pub use mutate::{AbsorbResult, MutateError, MutationResult, SkippedPath};
pub use op_diff::{
    OpChangedCommit, OpCommitsDiff, OpDiff, OpRefChange, OpRefTarget, OpRemoteRefChange, OpWorkingCopyChange,
};
pub use op_log::{
    OpAbandonResult, OpDiffOptions, OpDiffResult, OpIntegrateResult, OpLogError, OpShow, Operation, OperationId,
    OperationTag, RestoreWhat,
};
pub use push::{
    GitPushArgs, GitPushOutcome, PushCommitRejection, PushCreatedBookmark, PushFailure, PushFailureKind, PushPath,
    PushRef, PushRefKind, PushRefName, PushRefStatus, PushRefusal, PushRemote, PushSigning,
};
pub use rebase::RebaseOptions;
pub use remote_changes::{RemoteRefChange, RemoteRefChangeKind, RemoteRefKind};
pub use remotes::{
    FetchRefs, FetchRemotes, GitFetchArgs, GitFetchOutcome, ProgressEvent, ProgressFn, Remote, RemoteError,
};
pub use repo::{Backend, CreationOutcome, Repo, RepoError};
pub use resolve::{
    ConflictHunk, ConflictedFile, ResolveList, ResolveListOptions, ResolveOptions, ResolveTool, ResolvedFile,
};
pub use revert::RevertOptions;
pub use revset::{resolve_revset, RevsetError, RevsetErrorDetail, RevsetErrorKind, RevsetSpan, DEFAULT_LOG_REVSET};
pub use revset_search::{FoundChange, FoundChanges, RevsetCount, RevsetCounts, RevsetSearchError};
pub use select_tree::{
    FileChoice, FileSelection, HunkKey, SelectTreeOptions, SelectedTreeId, SourceTree, TreeSelection,
};
pub use simplify_parents::{SimplifyParentsOptions, SimplifyParentsResult};
pub use snapshot::{FinishFacts, Precondition, PreconditionError, StaleCause};
pub use squash_split::{SplitOptions, SplitResult, SquashOptions, SquashPlan};
pub use stale::{CheckoutStats, StaleRecovery, StaleRecoveryOutcome};
pub use status::{ChangeId, ChangeKind, FileChange, Status, StatusError};
pub use topology::{GraphTopology, TopologyEdge, TopologyMeta, TopologyNode};
pub use version::JJ_LIB_VERSION;
pub use view::{Tag, TagKind, ViewError, WorkingCopy};
pub use warning::{Warned, Warning, WarningKind};
pub use wc_ops::{SnapshotStats, TrackResult, UntrackResult, UntrackedPath, UntrackedReason};
pub use workspace::{WorkspaceEntry, WorkspaceError};
pub use workspace_add::{SparseInheritance, WorkspaceAddResult};
pub use workspace_ops::WorkspaceRemoveResult;

/// Fixtures shared by the inline `#[cfg(test)]` modules.
#[cfg(test)]
pub(crate) mod test_support {
    /// A fresh repo whose operation-log head no longer loads (`op_heads` removed after init).
    ///
    /// Through [`crate::Repo`] the pre-verb snapshot (Story 9.26) hits that failure FIRST, so a
    /// read module's own mapping of it is only reachable by calling the module function directly —
    /// which is what the inline tests using this do.
    pub(crate) fn repo_with_a_broken_head() -> (tempfile::TempDir, crate::Repo) {
        test_helpers::pin_test_env();
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let repo = crate::Repo::init(&crate::InitOptions {
            path: tmp.path().to_owned(),
            ..Default::default()
        })
        .result
        .expect("init");
        std::fs::remove_dir_all(repo.workspace().repo_path().join("op_heads")).expect("remove op_heads");
        (tmp, repo)
    }
}
