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
//! mechanically; `crates/zanshin-jj/tests/api_stability.rs` asserts the
//! complete surface structurally.

pub(crate) mod bookmarks;
pub(crate) mod change;
pub(crate) mod commit_meta;
pub(crate) mod config;
pub(crate) mod convert;
pub(crate) mod detect;
pub(crate) mod file;
pub(crate) mod git;
pub(crate) mod graph;
pub(crate) mod mutate;
pub(crate) mod op_log;
pub(crate) mod op_support;
pub(crate) mod remotes;
mod repo;
pub(crate) mod revset;
pub(crate) mod status;
pub(crate) mod view;

pub use bookmarks::{Bookmark, BookmarkError, BookmarkKind};
pub use change::{Change, ChangeError, CommitId, ConflictState, Signature, Timestamp, Timestamps};
pub use commit_meta::{CommitMeta, CommitRef};
pub use config::{ConfigError, LogDefaults};
pub use convert::{convert_colocated, convert_import};
pub use detect::{detect_repo, find_repo_root, DetectError, RepoKind, RepoRoot};
pub use file::{AnnotationLine, FileContents, FileEntry, FileError, FileType, SearchMatch, ShownFile};
pub use git::{GitExportFailure, GitExportResult, GitImportResult, GitRefUpdate, GitRefUpdateKind};
pub use graph::{GraphEdge, GraphEdgeKind, GraphNode, DEFAULT_GRAPH_PRIORITIZE};
pub use mutate::{AbsorbResult, MutateError, MutationResult, SkippedPath};
pub use op_log::{OpLogError, Operation, OperationId};
pub use remotes::{ProgressEvent, ProgressFn, Remote, RemoteError};
pub use repo::{Backend, Repo, RepoError};
pub use revset::{resolve_revset, RevsetError, DEFAULT_LOG_REVSET};
pub use status::{ChangeId, ChangeKind, FileChange, Status, StatusError};
pub use view::{Tag, TagKind, ViewError, WorkingCopy};
