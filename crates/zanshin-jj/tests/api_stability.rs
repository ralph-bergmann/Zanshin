// SPDX-License-Identifier: MIT

//! API surface stability test (AC-8 / FR-JJ-16).
//!
//! Names every public item by its `zanshin_jj::` path so the test ONLY compiles
//! when the full re-export surface (AC-1) resolves. No `jj_lib` import — a future
//! `jj_lib` type leaking into a public position would be detectable here.
//!
//! The test also asserts the leak-free invariant structurally: error variants are
//! constructed as `Backend(String)` / `JjLibError(String)`, never as a `jj_lib` type.

// --- Type-path aliases: one alias per public type (32 types; the AC-1 table's 30 plus
// --- Story 4.8's CommitMeta/CommitRef) -----------------------------------------

// repo
type _Repo = zanshin_jj::Repo;
type _RepoError = zanshin_jj::RepoError;
type _Backend = zanshin_jj::Backend;

// status
type _Status = zanshin_jj::Status;
type _StatusError = zanshin_jj::StatusError;
type _FileChange = zanshin_jj::FileChange;
type _ChangeKind = zanshin_jj::ChangeKind;
type _ChangeId = zanshin_jj::ChangeId;

// change
type _Change = zanshin_jj::Change;
type _ChangeError = zanshin_jj::ChangeError;
type _CommitId = zanshin_jj::CommitId;
type _ConflictState = zanshin_jj::ConflictState;
type _Signature = zanshin_jj::Signature;
type _Timestamp = zanshin_jj::Timestamp;
type _Timestamps = zanshin_jj::Timestamps;

// revset (free fn handled below)
type _RevsetError = zanshin_jj::RevsetError;

// op_log
type _Operation = zanshin_jj::Operation;
type _OperationId = zanshin_jj::OperationId;
type _OpLogError = zanshin_jj::OpLogError;

// bookmarks
type _Bookmark = zanshin_jj::Bookmark;
type _BookmarkKind = zanshin_jj::BookmarkKind;
type _BookmarkError = zanshin_jj::BookmarkError;

// remotes
type _Remote = zanshin_jj::Remote;
type _RemoteError = zanshin_jj::RemoteError;

// detect
type _RepoKind = zanshin_jj::RepoKind;
type _DetectError = zanshin_jj::DetectError;
type _RepoRoot = zanshin_jj::RepoRoot;

// graph
type _GraphNode = zanshin_jj::GraphNode;
type _GraphEdge = zanshin_jj::GraphEdge;
type _GraphEdgeKind = zanshin_jj::GraphEdgeKind;

// commit_meta (Story 4.8)
type _CommitMeta = zanshin_jj::CommitMeta;
type _CommitRef = zanshin_jj::CommitRef;

// config (Story 4.9)
type _ConfigError = zanshin_jj::ConfigError;
type _LogDefaults = zanshin_jj::LogDefaults;

// --- Free-function binding: resolve_revset (AC-1, AC-8) -------------------------

/// Names every `CommitMeta` / `CommitRef` field by its public path, so a field rename or
/// type change in the log-row payload breaks this test at compile time.
fn sample_commit_meta() -> zanshin_jj::CommitMeta {
    zanshin_jj::CommitMeta {
        change_id: String::new(),
        change_id_prefix_len: 0,
        commit_id_prefix_len: 0,
        change_offset: None,
        author_name: String::new(),
        author_email: String::new(),
        committer_timestamp: zanshin_jj::Timestamp {
            millis_since_epoch: 0,
            tz_offset_minutes: 0,
        },
        bookmarks: vec![zanshin_jj::CommitRef {
            name: String::new(),
            remote: None,
            synced: false,
            conflicted: false,
        }],
        tags: vec![],
        working_copies: vec![],
        working_copy: false,
        immutable: false,
        conflict: false,
        empty: false,
        hidden: false,
        divergent: false,
        root: false,
        description_first_line: String::new(),
    }
}

#[test]
fn api_surface_resolves() {
    // fn-pointer: compiles only if the signature matches exactly.
    // `_ = expr` (anonymous discard) avoids the no_effect_underscore_binding lint
    // while still confirming the function resolves at compile time.
    _ = zanshin_jj::resolve_revset
        as fn(&zanshin_jj::Repo, &str) -> Result<Vec<zanshin_jj::ChangeId>, zanshin_jj::RevsetError>;

    // Trivially-constructible values — exercises the variant paths without
    // needing a real repo (AC-8: "cheap value construction for trivially-constructible ones").
    _ = zanshin_jj::Backend::Git;

    // Error variants — each is Backend(String) / JjLibError(String): no jj_lib type.
    _ = zanshin_jj::RepoError::Backend(String::new());
    _ = zanshin_jj::StatusError::Backend(String::new());
    _ = zanshin_jj::ChangeError::Backend(String::new());
    _ = zanshin_jj::OpLogError::Backend(String::new());
    _ = zanshin_jj::BookmarkError::Backend(String::new());
    _ = zanshin_jj::RemoteError::Backend(String::new());
    _ = zanshin_jj::RevsetError::JjLibError(String::new());
    // Story 4.9: the variant `zanshin-ffi::map_lane_stream_err` matches on — pin its shape.
    _ = zanshin_jj::RevsetError::Config(zanshin_jj::ConfigError::Load { reason: String::new() });

    // Trivially-constructible tuple-struct wrappers.
    _ = zanshin_jj::ChangeId(String::new());
    _ = zanshin_jj::OperationId(String::new());
    _ = zanshin_jj::CommitId(String::new());

    // detect
    _ = zanshin_jj::detect_repo as fn(&std::path::Path) -> Result<zanshin_jj::RepoKind, zanshin_jj::DetectError>;
    _ = zanshin_jj::RepoKind::Jj;
    _ = zanshin_jj::DetectError::Io(String::new());
    _ = zanshin_jj::find_repo_root
        as fn(&std::path::Path) -> Result<Option<zanshin_jj::RepoRoot>, zanshin_jj::DetectError>;
    _ = zanshin_jj::RepoRoot {
        root: std::path::PathBuf::new(),
        kind: zanshin_jj::RepoKind::Jj,
    };

    // graph (Story 4.3): 3 new types + the CLI-default prioritize const; `Repo::walk_graph` is a
    // method (generic over its visitor), so it is pinned by the fixture tests, not a fn-pointer.
    _ = zanshin_jj::GraphEdgeKind::Direct;
    _ = zanshin_jj::GraphEdge {
        target: zanshin_jj::CommitId(String::new()),
        kind: zanshin_jj::GraphEdgeKind::Missing,
    };
    _ = zanshin_jj::GraphNode {
        id: zanshin_jj::CommitId(String::new()),
        parents: vec![],
        meta: sample_commit_meta(),
    };
    assert_eq!(
        zanshin_jj::DEFAULT_GRAPH_PRIORITIZE,
        "present(@)",
        "the CLI's revsets.log-graph-prioritize default (v0.42.0 cli/src/config/revsets.toml)"
    );
    assert_eq!(
        zanshin_jj::DEFAULT_LOG_REVSET,
        "present(@) | ancestors(immutable_heads().., 2) | trunk()",
        "the CLI's revsets.log default (v0.42.0 cli/src/config/revsets.toml)"
    );

    // config (Story 4.9): the four effective log defaults + the config error.
    _ = zanshin_jj::ConfigError::Load { reason: String::new() };
    _ = zanshin_jj::LogDefaults {
        log: String::new(),
        log_graph_prioritize: String::new(),
        short_prefixes: String::new(),
        synthetic_elided: false,
    };

    // convert (free fns + RepoError variants — no new *type* exported)
    _ = zanshin_jj::convert_colocated as fn(&std::path::Path) -> Result<zanshin_jj::Repo, zanshin_jj::RepoError>;
    _ = zanshin_jj::convert_import
        as fn(&std::path::Path, &std::path::Path) -> Result<zanshin_jj::Repo, zanshin_jj::RepoError>;
    _ = zanshin_jj::RepoError::AlreadyJjRepo {
        path: std::path::PathBuf::new(),
    };
    _ = zanshin_jj::RepoError::NotAGitRepo {
        path: std::path::PathBuf::new(),
    };
    _ = zanshin_jj::RepoError::ConvertFailed { reason: String::new() };
}
