// SPDX-License-Identifier: MIT

//! API surface stability test (AC-8 / FR-JJ-16).
//!
//! Names every public item by its `zanshin_jj::` path so the test ONLY compiles
//! when the full re-export surface (AC-1) resolves. No `jj_lib` import — a future
//! `jj_lib` type leaking into a public position would be detectable here.
//!
//! The test also asserts the leak-free invariant structurally: error variants are
//! constructed as `Backend(String)` / `JjLibError(String)`, never as a `jj_lib` type.

// --- Type-path aliases: one alias per public type (43 types; the AC-1 table's 30 plus the
// --- types later stories added — CommitMeta/CommitRef (4.8), ConfigError/LogDefaults (4.9),
// --- MutationResult/MutateError (6.1), ProgressEvent (6.4a), Tag/TagKind/WorkingCopy/
// --- ViewError (9.2), AbsorbResult/SkippedPath (9.3)) ---------------------------

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

// mutate (Story 6.1)
type _MutationResult = zanshin_jj::MutationResult;
type _MutateError = zanshin_jj::MutateError;

// mutate: content ops (Story 9.3)
type _AbsorbResult = zanshin_jj::AbsorbResult;
type _SkippedPath = zanshin_jj::SkippedPath;

// remotes: git_fetch progress (Story 6.4a)
type _ProgressEvent = zanshin_jj::ProgressEvent;

// view (Story 9.2)
type _Tag = zanshin_jj::Tag;
type _TagKind = zanshin_jj::TagKind;
type _WorkingCopy = zanshin_jj::WorkingCopy;
type _ViewError = zanshin_jj::ViewError;

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

/// Names every `MutationResult` field by its public path (epics.md Story 6.1's AC), so a
/// field rename, reorder, or type change breaks this test at compile time.
fn sample_mutation_result() -> zanshin_jj::MutationResult {
    zanshin_jj::MutationResult {
        new_op_id: zanshin_jj::OperationId(String::new()),
        new_change_ids: vec![zanshin_jj::ChangeId(String::new())],
        abandoned_change_ids: vec![zanshin_jj::ChangeId(String::new())],
        working_copy_change_id: zanshin_jj::ChangeId(String::new()),
    }
}

/// Names every `AbsorbResult` / `SkippedPath` field by its public path (Story 9.3), so a field
/// rename, reorder, or type change in absorb's outcome breaks this test at compile time. The
/// nested `MutationResult` is deliberately reused rather than repeated — that nesting IS the
/// contract.
fn sample_absorb_result() -> zanshin_jj::AbsorbResult {
    zanshin_jj::AbsorbResult {
        mutation: sample_mutation_result(),
        rewritten_change_ids: vec![zanshin_jj::ChangeId(String::new())],
        source_change_id: Some(zanshin_jj::ChangeId(String::new())),
        num_rebased: 0,
        skipped_paths: vec![zanshin_jj::SkippedPath {
            path: String::new(),
            reason: String::new(),
        }],
    }
}

/// Names every `Tag` field by its public path (Story 9.2), so a field rename, reorder, or type
/// change in the tag listing breaks this test at compile time.
fn sample_tag() -> zanshin_jj::Tag {
    zanshin_jj::Tag {
        name: String::new(),
        target: zanshin_jj::ChangeId(String::new()),
        kind: zanshin_jj::TagKind::Remote {
            remote_name: String::new(),
        },
    }
}

/// Names every `WorkingCopy` field by its public path (Story 9.2).
fn sample_working_copy() -> zanshin_jj::WorkingCopy {
    zanshin_jj::WorkingCopy {
        workspace_name: String::new(),
        commit_id: zanshin_jj::CommitId(String::new()),
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
    // remotes: git_fetch progress callback (Story 6.4a) — pin the callback type and
    // the exact `Repo::git_fetch` signature.
    let _: &zanshin_jj::ProgressFn = &|_: zanshin_jj::ProgressEvent| {};
    _ = zanshin_jj::Repo::git_fetch
        as fn(
            &mut zanshin_jj::Repo,
            &str,
            &zanshin_jj::ProgressFn,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
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

    // mutate (Story 6.1)
    _ = zanshin_jj::MutateError::Backend(String::new());
    _ = sample_mutation_result();

    // op-log undo (Story 6.2)
    _ = zanshin_jj::MutateError::NothingToUndo;

    // git_fetch (Story 6.4a)
    _ = zanshin_jj::MutateError::RemoteNotFound { name: String::new() };
    _ = zanshin_jj::MutateError::NetworkError { reason: String::new() };

    // op_support immutable guard (Story 9.1)
    _ = zanshin_jj::MutateError::Immutable {
        commit_id: String::new(),
    };
    _ = zanshin_jj::MutateError::Config { reason: String::new() };

    // view + eval_revset (Story 9.2): 4 new types, all `Backend(String)`/plain — no jj_lib type.
    // The three `View` listings are `fn`-pointer-pinned; `Repo::eval_revset` is a method generic
    // over its visitor, so — exactly like `Repo::walk_graph` — it cannot be pinned that way and
    // is pinned by the fixture tests in `tests/revset.rs` instead.
    _ = zanshin_jj::ViewError::Backend(String::new());
    _ = zanshin_jj::TagKind::Local;
    _ = sample_tag();
    _ = sample_working_copy();
    _ = zanshin_jj::Repo::list_tags as fn(&zanshin_jj::Repo) -> Result<Vec<zanshin_jj::Tag>, zanshin_jj::ViewError>;
    _ = zanshin_jj::Repo::list_heads
        as fn(&zanshin_jj::Repo) -> Result<Vec<zanshin_jj::CommitId>, zanshin_jj::ViewError>;
    _ = zanshin_jj::Repo::list_working_copies
        as fn(&zanshin_jj::Repo) -> Result<Vec<zanshin_jj::WorkingCopy>, zanshin_jj::ViewError>;
}

/// Content ops (Story 9.3): 2 new types, 2 new `MutateError` variants, 2 new `Repo` methods.
///
/// A separate test rather than more lines in `api_surface_resolves`, which is already at
/// clippy's `too_many_lines` ceiling. Both methods ARE `fn`-pointer-pinnable (unlike
/// `walk_graph`/`eval_revset`, which are generic over a visitor), so their full signatures —
/// including which parameters are optional and which one is the revset pass-through — are
/// pinned structurally here.
#[test]
fn content_ops_surface_resolves() {
    _ = zanshin_jj::MutateError::RevsetParseError { reason: String::new() };
    _ = zanshin_jj::MutateError::RevsetResolutionError { reason: String::new() };
    _ = sample_absorb_result();
    _ = zanshin_jj::Repo::restore
        as fn(
            &mut zanshin_jj::Repo,
            Option<zanshin_jj::ChangeId>,
            Option<zanshin_jj::ChangeId>,
            Option<zanshin_jj::ChangeId>,
            &[String],
            bool,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::absorb
        as fn(
            &mut zanshin_jj::Repo,
            Option<zanshin_jj::ChangeId>,
            Option<&str>,
            &[String],
        ) -> Result<zanshin_jj::AbsorbResult, zanshin_jj::MutateError>;
}
