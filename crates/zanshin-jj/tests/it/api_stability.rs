// SPDX-License-Identifier: MIT

//! API surface stability test (AC-8 / FR-JJ-16).
//!
//! Names every public item by its `zanshin_jj::` path so the test ONLY compiles
//! when the full re-export surface (AC-1) resolves. No `jj_lib` import — a future
//! `jj_lib` type leaking into a public position would be detectable here.
//!
//! The test also asserts the leak-free invariant structurally: error variants are
//! constructed as `Backend(String)` / `JjLibError(String)`, never as a `jj_lib` type.

// --- Type-path aliases: one alias per public type (102 types; the AC-1 table's 30 plus the
// --- types later stories added — CommitMeta/CommitRef (4.8), ConfigError/LogDefaults (4.9),
// --- MutationResult/MutateError (6.1), ProgressEvent (6.4a), Tag/TagKind/WorkingCopy/
// --- ViewError (9.2), AbsorbResult/SkippedPath (9.3), FileEntry/FileType/ShownFile/
// --- FileContents/AnnotationLine/SearchMatch/FileError (9.4), GitImportResult/GitRefUpdate/
// --- GitRefUpdateKind/GitExportResult/GitExportFailure (9.5), ShowEntry/EvologEntry/
// --- InterdiffView/CommitViewError (9.6), WorkspaceEntry/WorkspaceError (9.7), 82 by then).
// --- Story 9.8 adds NO public type — both bookmark mutations reuse MutationResult/MutateError —
// --- so the count moved only when follow-up F turned `interdiff`'s bare Vec into InterdiffView.
// --- Later stories name their types in their own section below, the last being
// --- BookmarkMoveOptions/BookmarkListOptions/BookmarkSortKey (9.19) -----------------------

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
type _RefDistance = zanshin_jj::RefDistance;
type _BookmarkListOptions = zanshin_jj::BookmarkListOptions;
type _BookmarkSortKey = zanshin_jj::BookmarkSortKey;
type _BookmarkMoveOptions = zanshin_jj::BookmarkMoveOptions;

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

// remotes: git_fetch args and outcome (Story 9.30)
type _GitFetchArgs = zanshin_jj::GitFetchArgs;
type _FetchRemotes = zanshin_jj::FetchRemotes;
type _FetchRefs = zanshin_jj::FetchRefs;
type _GitFetchOutcome = zanshin_jj::GitFetchOutcome;

// file reads (Story 9.4)
type _FileEntry = zanshin_jj::FileEntry;
type _FileType = zanshin_jj::FileType;
type _ShownFile = zanshin_jj::ShownFile;
type _FileContents = zanshin_jj::FileContents;
type _AnnotationLine = zanshin_jj::AnnotationLine;
type _SearchMatch = zanshin_jj::SearchMatch;
type _FileSearch = zanshin_jj::FileSearch;
type _FileError = zanshin_jj::FileError;

// git sync + remote config (Story 9.5)
type _GitImportResult = zanshin_jj::GitImportResult;
type _GitRefUpdate = zanshin_jj::GitRefUpdate;
type _GitRefUpdateKind = zanshin_jj::GitRefUpdateKind;
type _GitExportResult = zanshin_jj::GitExportResult;
type _GitExportFailure = zanshin_jj::GitExportFailure;

// commit views (Story 9.6)
type _ShowEntry = zanshin_jj::ShowEntry;
type _EvologEntry = zanshin_jj::EvologEntry;
type _InterdiffView = zanshin_jj::InterdiffView;
type _CommitViewError = zanshin_jj::CommitViewError;
// Epic 9 follow-up I: `interdiff`'s single-revision currency
type _RevisionRef = zanshin_jj::RevisionRef;

// view (Story 9.2)
type _Tag = zanshin_jj::Tag;
type _TagKind = zanshin_jj::TagKind;
type _WorkingCopy = zanshin_jj::WorkingCopy;
type _ViewError = zanshin_jj::ViewError;

// workspace (Story 9.7)
type _WorkspaceEntry = zanshin_jj::WorkspaceEntry;
type _WorkspaceError = zanshin_jj::WorkspaceError;

// graph topology + op-pinned content (Story 4.10)
type _GraphTopology = zanshin_jj::GraphTopology;
type _TopologyNode = zanshin_jj::TopologyNode;
type _TopologyEdge = zanshin_jj::TopologyEdge;
type _TopologyMeta = zanshin_jj::TopologyMeta;
type _CommitContent = zanshin_jj::CommitContent;
type _CommitContentError = zanshin_jj::CommitContentError;

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
        working_copy_change_id: Some(zanshin_jj::ChangeId(String::new())),
        finish: Some(sample_finish_facts()),
    }
}

/// Names every `FinishFacts` field by its public path (Story 9.26; the two flags moved to the
/// warning channel in Story 9.32).
fn sample_finish_facts() -> zanshin_jj::FinishFacts {
    zanshin_jj::FinishFacts {
        export_failed_bookmarks: vec![zanshin_jj::GitExportFailure {
            name: String::new(),
            remote: String::new(),
            reason: String::new(),
        }],
        export_failed_tags: vec![],
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

/// Names every `FileEntry` field by its public path (Story 9.4).
fn sample_file_entry() -> zanshin_jj::FileEntry {
    zanshin_jj::FileEntry {
        path: String::new(),
        file_type: zanshin_jj::FileType::File,
        executable: false,
        conflict_side_count: 0,
    }
}

/// Names every `FileContents` / `ShownFile` field by its public path (Story 9.4). `skipped`
/// deliberately reuses [`zanshin_jj::SkippedPath`] rather than a second type — that reuse IS
/// the contract Story 9.3 established.
fn sample_file_contents() -> zanshin_jj::FileContents {
    zanshin_jj::FileContents {
        files: vec![zanshin_jj::ShownFile {
            path: String::new(),
            content: Vec::new(),
            conflict: false,
        }],
        skipped: vec![zanshin_jj::SkippedPath {
            path: String::new(),
            reason: String::new(),
        }],
    }
}

/// Names every `AnnotationLine` field by its public path (Story 9.4).
fn sample_annotation_line() -> zanshin_jj::AnnotationLine {
    zanshin_jj::AnnotationLine {
        commit_id: zanshin_jj::CommitId(String::new()),
        change_id: zanshin_jj::ChangeId(String::new()),
        original_line_number: 0,
        content: Vec::new(),
        origin_found: false,
    }
}

/// Names every `SearchMatch` field by its public path (Story 9.4).
fn sample_search_match() -> zanshin_jj::SearchMatch {
    zanshin_jj::SearchMatch {
        path: String::new(),
        line_number: 0,
        content: Vec::new(),
        conflict_side: Some(0),
    }
}

/// Names every `Remote` field by its public path (FR-JJ-9). `push_url` is null-for-absence:
/// `Some` only when the remote's push URL DIFFERS from its fetch URL. The sample carries a
/// NON-empty string there because `Some("")` is the one shape the producer never emits —
/// this file is where a reader looks up the type's contract, so it must not model it wrong.
fn sample_remote() -> zanshin_jj::Remote {
    zanshin_jj::Remote {
        name: String::new(),
        url: String::new(),
        push_url: Some("ssh://example.invalid/push".to_owned()),
    }
}

/// Names every `FileSearch` field by its public path (Story 9.4). Like `FileContents`,
/// `skipped` deliberately reuses [`zanshin_jj::SkippedPath`] rather than minting a second
/// type — even though the two verbs report DIFFERENT reasons in it.
fn sample_file_search() -> zanshin_jj::FileSearch {
    zanshin_jj::FileSearch {
        matches: vec![sample_search_match()],
        skipped: vec![zanshin_jj::SkippedPath {
            path: String::new(),
            reason: String::new(),
        }],
    }
}

/// Names every `GitImportResult` / `GitRefUpdate` field by its public path (Story 9.5). The
/// nested `MutationResult` is deliberately reused rather than repeated — that nesting IS the
/// contract, as it is for `AbsorbResult`.
fn sample_git_import_result() -> zanshin_jj::GitImportResult {
    zanshin_jj::GitImportResult {
        mutation: sample_mutation_result(),
        changed_bookmarks: vec![zanshin_jj::GitRefUpdate {
            name: String::new(),
            remote: String::new(),
            kind: zanshin_jj::GitRefUpdateKind::New,
            tracked: false,
        }],
        changed_tags: vec![],
        abandoned_change_ids: vec![zanshin_jj::ChangeId(String::new())],
        num_rewritten: 0,
        failed_ref_names: vec![String::new()],
    }
}

/// Names every `GitExportResult` / `GitExportFailure` field by its public path (Story 9.5).
fn sample_git_export_result() -> zanshin_jj::GitExportResult {
    zanshin_jj::GitExportResult {
        mutation: sample_mutation_result(),
        failed_bookmarks: vec![zanshin_jj::GitExportFailure {
            name: String::new(),
            remote: String::new(),
            reason: String::new(),
        }],
        failed_tags: vec![],
    }
}

/// Names every `Change` field by its public path — the shape both Story 9.6 views nest.
fn sample_change() -> zanshin_jj::Change {
    let signature = zanshin_jj::Signature {
        name: String::new(),
        email: String::new(),
        timestamp: zanshin_jj::Timestamp {
            millis_since_epoch: 0,
            tz_offset_minutes: 0,
        },
    };
    zanshin_jj::Change {
        id: zanshin_jj::ChangeId(String::new()),
        commit_id: zanshin_jj::CommitId(String::new()),
        parents: vec![],
        description: String::new(),
        author: signature.clone(),
        committer: signature.clone(),
        timestamps: zanshin_jj::Timestamps {
            authored_at: signature.timestamp,
            committed_at: signature.timestamp,
        },
        is_signed: false,
        conflict: zanshin_jj::ConflictState::Clean,
        is_anonymous: false,
        divergent: false,
    }
}

/// Names every `ShowEntry` field by its public path (Story 9.6). The nested types are the
/// SHIPPED `Change` and `FileChange` — a second spelling of either would fail to compile here.
fn sample_show_entry() -> zanshin_jj::ShowEntry {
    zanshin_jj::ShowEntry {
        change: sample_change(),
        file_changes: vec![zanshin_jj::FileChange {
            path: std::path::PathBuf::new(),
            kind: zanshin_jj::ChangeKind::Added,
        }],
        parent_tree_ids: vec![String::new()],
    }
}

/// Names every `EvologEntry` field by its public path (Story 9.6). The edges are `CommitId`s,
/// not `ChangeId`s — every predecessor shares the change's own id.
fn sample_evolog_entry() -> zanshin_jj::EvologEntry {
    zanshin_jj::EvologEntry {
        change: sample_change(),
        predecessor_commit_ids: vec![zanshin_jj::CommitId(String::new())],
        operation_id: Some(zanshin_jj::OperationId(String::new())),
    }
}

/// Names every `InterdiffView` field by its public path (Story 9.6 / follow-up F). The change
/// list reuses the SHIPPED `FileChange`; `base_has_conflicts` is a plain `bool`, so no `jj_lib`
/// type leaks through the flag's derivation (`MergedTree::has_conflict()`).
fn sample_interdiff_view() -> zanshin_jj::InterdiffView {
    zanshin_jj::InterdiffView {
        file_changes: vec![zanshin_jj::FileChange {
            path: std::path::PathBuf::new(),
            kind: zanshin_jj::ChangeKind::Added,
        }],
        base_has_conflicts: false,
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

/// Names every `WorkspaceEntry` field by its public path (Story 9.7). `root` is an
/// `Option<PathBuf>` — the crate's path currency (`RepoRoot.root`'s precedent), and its
/// optionality IS the contract: a path that cannot be reported never fails the listing.
fn sample_workspace_entry() -> zanshin_jj::WorkspaceEntry {
    zanshin_jj::WorkspaceEntry {
        name: String::new(),
        wc_commit_id: zanshin_jj::CommitId(String::new()),
        root: Some(std::path::PathBuf::new()),
    }
}

#[test]
fn api_surface_resolves() {
    // fn-pointer: compiles only if the signature matches exactly.
    // `_ = expr` (anonymous discard) avoids the no_effect_underscore_binding lint
    // while still confirming the function resolves at compile time.
    // Stays `&Repo` and precondition-free: the test oracle, exported to neither FFI nor MCP
    // (Story 9.26).
    _ = zanshin_jj::resolve_revset
        as fn(&zanshin_jj::Repo, &str) -> Result<Vec<zanshin_jj::ChangeId>, zanshin_jj::RevsetError>;

    // Trivially-constructible values — exercises the variant paths without
    // needing a real repo (AC-8: "cheap value construction for trivially-constructible ones").
    _ = zanshin_jj::Backend::Git;

    // Error variants — each is Backend(String) / JjLibError(String): no jj_lib type.
    _ = zanshin_jj::RepoError::Backend(String::new());
    _ = zanshin_jj::RepoError::Config { reason: String::new() };
    _ = zanshin_jj::StatusError::Backend(String::new());
    _ = zanshin_jj::ChangeError::Backend(String::new());
    _ = zanshin_jj::OpLogError::Backend(String::new());
    _ = zanshin_jj::BookmarkError::Backend(String::new());
    _ = zanshin_jj::RemoteError::Backend(String::new());
    _ = sample_remote();
    _ = zanshin_jj::RevsetError::JjLibError(String::new());
    // remotes: git_fetch progress callback (Story 6.4a) — pin the callback type and
    // the exact `Repo::git_fetch` signature.
    let _: &zanshin_jj::ProgressFn = &|_: zanshin_jj::ProgressEvent| {};
    // Story 9.30: the args/outcome pair (the rest of the surface below).
    _ = zanshin_jj::Repo::git_fetch
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::GitFetchArgs,
            &zanshin_jj::ProgressFn,
            Option<&zanshin_jj::cancel::CancelGuard>,
        ) -> Result<zanshin_jj::GitFetchOutcome, zanshin_jj::MutateError>;
    // Story 4.9: the variant `zanshin-ffi::map_topology_err` matches on — pin its shape.
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
    // version (Story 11.6 closing run): jj-lib's version; its value is guarded against
    // `Cargo.lock` inline in `src/version.rs`.
    let _: &'static str = zanshin_jj::JJ_LIB_VERSION;

    // config (Story 4.9): the four effective log defaults + the config error.
    _ = zanshin_jj::ConfigError::Load { reason: String::new() };
    _ = zanshin_jj::LogDefaults {
        log: String::new(),
        log_graph_prioritize: String::new(),
        short_prefixes: String::new(),
        synthetic_elided: false,
    };

    // convert (free fns + RepoError variants); since Story 9.33 every creation returns a
    // `CreationOutcome` (pinned in `story_9_33_creation_outcome_resolves`)
    _ = zanshin_jj::convert_colocated as fn(&std::path::Path) -> zanshin_jj::CreationOutcome;
    _ = zanshin_jj::convert_import as fn(&std::path::Path, &std::path::Path) -> zanshin_jj::CreationOutcome;
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

    // op-log undo (Story 6.2); the undo stack + `--allow-cross-workspace` (Story 9.39, jj 0.46)
    _ = zanshin_jj::MutateError::NothingToUndo;
    _ = zanshin_jj::MutateError::UndoCrossWorkspace {
        operation: String::new(),
        workspace: String::new(),
    };
    _ = zanshin_jj::Repo::undo
        as fn(&mut zanshin_jj::Repo, bool) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;

    // git_fetch (Story 6.4a)
    _ = zanshin_jj::MutateError::RemoteNotFound { name: String::new() };
    _ = zanshin_jj::MutateError::NetworkError { reason: String::new() };

    // op_support immutable guard (Story 9.1)
    _ = zanshin_jj::MutateError::Immutable {
        commit_id: String::new(),
        hints: Vec::new(),
    };
    _ = zanshin_jj::MutateError::Config { reason: String::new() };

    // view + eval_revset (Story 9.2): 4 new types, all `Backend(String)`/plain — no jj_lib type.
    // The three `View` listings are `fn`-pointer-pinned; `Repo::eval_revset` is a method generic
    // over its visitor, so — exactly like `Repo::walk_graph` — it cannot be pinned that way and
    // is pinned by the fixture tests in `tests/it/revset.rs` instead.
    _ = zanshin_jj::ViewError::Backend(String::new());
    _ = zanshin_jj::TagKind::Local;
    _ = sample_tag();
    _ = sample_working_copy();
    _ = zanshin_jj::Repo::list_tags as fn(&mut zanshin_jj::Repo) -> Result<Vec<zanshin_jj::Tag>, zanshin_jj::ViewError>;
    _ = zanshin_jj::Repo::list_heads
        as fn(&mut zanshin_jj::Repo) -> Result<Vec<zanshin_jj::CommitId>, zanshin_jj::ViewError>;
    _ = zanshin_jj::Repo::list_working_copies
        as fn(&mut zanshin_jj::Repo) -> Result<Vec<zanshin_jj::WorkingCopy>, zanshin_jj::ViewError>;
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
    _ = zanshin_jj::MutateError::RevsetParseError {
        reason: String::new(),
        hints: Vec::new(),
    };
    _ = zanshin_jj::MutateError::RevsetResolutionError {
        reason: String::new(),
        hints: Vec::new(),
    };
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

/// Graph topology + op-pinned content (Story 4.10): 6 new types, 1 new `RevsetError` variant,
/// 2 new `Repo` methods. Every field is named by its public path and both methods are pinned as
/// `fn` pointers, so a rename, a type change or a changed pass-through breaks this at compile
/// time.
#[test]
fn graph_topology_surface_resolves() {
    let meta = zanshin_jj::TopologyMeta {
        change_id: String::new(),
        change_id_prefix_len: 0,
        commit_id_prefix_len: 0,
        change_offset: None,
        bookmarks: Vec::new(),
        tags: Vec::new(),
        working_copies: Vec::new(),
        working_copy: false,
        immutable: false,
        hidden: false,
        divergent: false,
        root: false,
        parent_count: 0,
    };
    let edge = zanshin_jj::TopologyEdge {
        target: Some(0usize),
        kind: zanshin_jj::GraphEdgeKind::Direct,
    };
    let node = zanshin_jj::TopologyNode {
        commit_id: zanshin_jj::CommitId(String::new()),
        edges: vec![edge],
        meta,
        committer_timestamp_ms: Some(0i64),
    };
    _ = zanshin_jj::GraphTopology {
        operation_id: zanshin_jj::OperationId(String::new()),
        nodes: vec![node],
        anchors: vec![vec![0usize]],
        all_count: 0usize,
    };
    _ = zanshin_jj::CommitContent {
        commit_id: zanshin_jj::CommitId(String::new()),
        author_name: String::new(),
        author_email: String::new(),
        committer_timestamp: zanshin_jj::Timestamp {
            millis_since_epoch: 0,
            tz_offset_minutes: 0,
        },
        description: String::new(),
        conflict: false,
        empty: false,
    };
    _ = zanshin_jj::CommitContentError::InvalidInput(String::new());
    _ = zanshin_jj::CommitContentError::OperationNotFound(String::new());
    _ = zanshin_jj::CommitContentError::CommitNotFound(String::new());
    _ = zanshin_jj::CommitContentError::Backend(String::new());
    _ = zanshin_jj::RevsetError::DanglingEdge { target: String::new() };
    _ = zanshin_jj::Repo::graph_topology
        as fn(
            &mut zanshin_jj::Repo,
            &str,
            &str,
            &str,
            &[String],
            bool,
        ) -> Result<zanshin_jj::GraphTopology, zanshin_jj::RevsetError>;
    _ = zanshin_jj::Repo::commit_contents
        as fn(
            &zanshin_jj::Repo,
            &zanshin_jj::OperationId,
            &[zanshin_jj::CommitId],
        ) -> Result<Vec<zanshin_jj::CommitContent>, zanshin_jj::CommitContentError>;
}

/// File reads (Story 9.4): 7 new types and 4 new `Repo` methods.
///
/// A separate test for the same reason `content_ops_surface_resolves` is one —
/// `api_surface_resolves` sits at clippy's `too_many_lines` ceiling. All four methods are
/// `fn`-pointer-pinnable (they take no visitor), so their full signatures — which parameter
/// is the optional revision, which is the prefix list, which is the pass-through pattern —
/// are pinned structurally here.
#[test]
fn file_reads_surface_resolves() {
    // Every `FileError` variant, each carrying only owned std types — no jj_lib type.
    _ = zanshin_jj::FileError::ChangeNotFound { id: String::new() };
    _ = zanshin_jj::FileError::PathNotFound { path: String::new() };
    _ = zanshin_jj::FileError::NotAFile { path: String::new() };
    _ = zanshin_jj::FileError::InvalidInput { reason: String::new() };
    _ = zanshin_jj::FileError::Config { reason: String::new() };
    _ = zanshin_jj::FileError::Backend(String::new());

    // Every `FileType` member — the wire discriminant order is pinned by the schema.
    _ = zanshin_jj::FileType::File;
    _ = zanshin_jj::FileType::Symlink;
    _ = zanshin_jj::FileType::Tree;
    _ = zanshin_jj::FileType::GitSubmodule;
    _ = zanshin_jj::FileType::Conflict;

    _ = sample_file_entry();
    _ = sample_file_contents();
    _ = sample_annotation_line();
    _ = sample_search_match();
    _ = sample_file_search();

    _ = zanshin_jj::Repo::file_list
        as fn(
            &mut zanshin_jj::Repo,
            Option<zanshin_jj::ChangeId>,
            &[String],
        ) -> Result<Vec<zanshin_jj::FileEntry>, zanshin_jj::FileError>;
    _ = zanshin_jj::Repo::file_show
        as fn(
            &mut zanshin_jj::Repo,
            Option<zanshin_jj::ChangeId>,
            &[String],
        ) -> Result<zanshin_jj::FileContents, zanshin_jj::FileError>;
    _ = zanshin_jj::Repo::file_annotate
        as fn(
            &mut zanshin_jj::Repo,
            Option<zanshin_jj::ChangeId>,
            &str,
        ) -> Result<Vec<zanshin_jj::AnnotationLine>, zanshin_jj::FileError>;
    _ = zanshin_jj::Repo::file_search
        as fn(
            &mut zanshin_jj::Repo,
            Option<zanshin_jj::ChangeId>,
            &str,
            &[String],
            bool,
        ) -> Result<zanshin_jj::FileSearch, zanshin_jj::FileError>;
}

/// Git sync + remote config (Story 9.5): 5 new types, 3 new `MutateError` variants, 6 new
/// `Repo` methods.
///
/// A separate test for the same reason `content_ops_surface_resolves` and
/// `file_reads_surface_resolves` are — `api_surface_resolves` sits at clippy's
/// `too_many_lines` ceiling. All six methods are `fn`-pointer-pinnable (none takes a
/// visitor), so their full signatures — which parameters are optional URLs, which verb takes
/// no arguments at all — are pinned structurally here.
///
/// Each new `MutateError` variant is constructed AND its `Display` asserted: an unexercised
/// `thiserror` arm is an uncovered line in `mutate.rs`, which the coverage ratchet pins.
#[test]
fn git_ops_surface_resolves() {
    let exists = zanshin_jj::MutateError::RemoteExists {
        name: "origin".to_owned(),
    };
    assert_eq!(exists.to_string(), "git remote already exists: origin");
    let nonstandard = zanshin_jj::MutateError::RemoteNonstandardConfig {
        name: "origin".to_owned(),
    };
    assert_eq!(
        nonstandard.to_string(),
        "git remote has nonstandard configuration: origin"
    );
    assert_eq!(zanshin_jj::MutateError::NotAGitRepo.to_string(), "not a git repository");

    // Every `GitRefUpdateKind` member — the wire discriminant order is pinned by the schema.
    _ = zanshin_jj::GitRefUpdateKind::New;
    _ = zanshin_jj::GitRefUpdateKind::Updated;
    _ = zanshin_jj::GitRefUpdateKind::Deleted;

    _ = sample_git_import_result();
    _ = sample_git_export_result();

    _ = zanshin_jj::Repo::git_import
        as fn(&mut zanshin_jj::Repo) -> Result<zanshin_jj::GitImportResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::git_export
        as fn(&mut zanshin_jj::Repo) -> Result<zanshin_jj::GitExportResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::git_remote_add
        as fn(
            &mut zanshin_jj::Repo,
            &str,
            &str,
            Option<&str>,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::git_remote_remove
        as fn(&mut zanshin_jj::Repo, &str) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::git_remote_rename
        as fn(&mut zanshin_jj::Repo, &str, &str) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::git_remote_set_url
        as fn(
            &mut zanshin_jj::Repo,
            &str,
            Option<&str>,
            Option<&str>,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
}

/// Commit views (Story 9.6): 4 new types and 3 new `Repo` methods.
///
/// A separate test for the same reason the three above are — `api_surface_resolves` sits at
/// clippy's `too_many_lines` ceiling. All three methods are `fn`-pointer-pinnable (none takes a
/// visitor), so the PARAMETER CURRENCY SPLIT is pinned structurally: `show`/`evolog` take a
/// revset `Option<&str>` because their CLI form is a SET whose aliases must survive (FR-JJ-17),
/// while `interdiff` takes two owned `Option<RevisionRef>` because the CLI resolves each side
/// with `resolve_single_rev`. Swapping either currency breaks this test at compile time.
///
/// `interdiff` is the ONE verb whose single revision is a UNION rather than a bare `ChangeId`
/// (Epic 9 follow-up I): its commit-id arm reaches HIDDEN commits, which is what makes `evolog`
/// and `interdiff` compose. Both arms are constructed below, so narrowing the parameter back to
/// a `ChangeId` — or dropping either variant — breaks this test at compile time too.
///
/// Each `CommitViewError` variant is constructed AND its `Display` asserted: an unexercised
/// `thiserror` arm is an uncovered line in `commit_views.rs`, which the coverage ratchet pins.
#[test]
fn commit_views_surface_resolves() {
    let not_found = zanshin_jj::CommitViewError::ChangeNotFound {
        id: "qpvuntsm".to_owned(),
    };
    assert_eq!(not_found.to_string(), "change not found: qpvuntsm");
    let invalid = zanshin_jj::CommitViewError::InvalidInput {
        reason: "at least one of `from` or `to` is required".to_owned(),
    };
    assert_eq!(
        invalid.to_string(),
        "invalid input: at least one of `from` or `to` is required"
    );
    let parse = zanshin_jj::CommitViewError::RevsetParseError {
        reason: "syntax error".to_owned(),
    };
    assert_eq!(parse.to_string(), "invalid revset: syntax error");
    let resolution = zanshin_jj::CommitViewError::RevsetResolutionError {
        reason: "no such bookmark".to_owned(),
    };
    assert_eq!(resolution.to_string(), "cannot resolve revset: no such bookmark");
    let config = zanshin_jj::CommitViewError::Config {
        reason: "not a table".to_owned(),
    };
    assert_eq!(config.to_string(), "config error: not a table");
    assert_eq!(
        zanshin_jj::CommitViewError::Backend("boom".to_owned()).to_string(),
        "jj-lib error: boom"
    );

    _ = sample_show_entry();
    _ = sample_evolog_entry();
    _ = sample_interdiff_view();

    // Both arms of the one union currency, named by their public paths.
    _ = zanshin_jj::RevisionRef::ChangeId(zanshin_jj::ChangeId(String::new()));
    _ = zanshin_jj::RevisionRef::CommitId(zanshin_jj::CommitId(String::new()));

    _ = zanshin_jj::Repo::show
        as fn(
            &mut zanshin_jj::Repo,
            Option<&str>,
            Option<usize>,
        ) -> Result<Vec<zanshin_jj::ShowEntry>, zanshin_jj::CommitViewError>;
    _ = zanshin_jj::Repo::evolog
        as fn(
            &mut zanshin_jj::Repo,
            Option<&str>,
            Option<usize>,
        ) -> Result<Vec<zanshin_jj::EvologEntry>, zanshin_jj::CommitViewError>;
    _ = zanshin_jj::Repo::interdiff
        as fn(
            &mut zanshin_jj::Repo,
            Option<zanshin_jj::RevisionRef>,
            Option<zanshin_jj::RevisionRef>,
            &[String],
        ) -> Result<zanshin_jj::InterdiffView, zanshin_jj::CommitViewError>;
}

/// Workspace reads (Story 9.7): 2 new types and 2 new `Repo` methods.
///
/// A separate test for the reason the blocks above are — `api_surface_resolves` sits at clippy's
/// `too_many_lines` ceiling. The two method signatures pin the ARGUMENT ARITY the CLI fixes:
/// `list_workspaces` takes nothing (`jj workspace list`'s only flag is rendering) while
/// `resolve_workspace_root` takes one `Option<&str>` (`--name`, defaulting to the current
/// workspace). It also pins that `resolve_workspace_root` is a SEPARATE method from the
/// infallible `workspace_root()` accessor, which keeps its `&Path` return.
///
/// Each `WorkspaceError` variant is constructed AND its `Display` asserted: an unexercised
/// `thiserror` arm is an uncovered line in `workspace.rs`, which the coverage ratchet pins.
#[test]
fn workspace_surface_resolves() {
    let not_found = zanshin_jj::WorkspaceError::NotFound {
        name: "nosuch".to_owned(),
    };
    assert_eq!(not_found.to_string(), "no such workspace: nosuch");
    let no_path = zanshin_jj::WorkspaceError::NoRecordedPath {
        name: "legacy".to_owned(),
    };
    assert_eq!(no_path.to_string(), "workspace has no recorded path: legacy");
    assert_eq!(
        zanshin_jj::WorkspaceError::Backend("boom".to_owned()).to_string(),
        "jj-lib error: boom"
    );

    _ = sample_workspace_entry();

    _ = zanshin_jj::Repo::list_workspaces
        as fn(&mut zanshin_jj::Repo) -> Result<Vec<zanshin_jj::WorkspaceEntry>, zanshin_jj::WorkspaceError>;
    // `workspace root` is in the CLI's no-snapshot set, but it runs the command start-up as
    // `op_integrate` does (the fix-up, the effective config; with a name the start-up
    // environment), so it takes `&mut self` and its warnings — `jj.workspace_path_inaccessible`
    // last — ride `take_warnings`.
    _ = zanshin_jj::Repo::resolve_workspace_root
        as fn(&mut zanshin_jj::Repo, Option<&str>) -> Result<std::path::PathBuf, zanshin_jj::WorkspaceError>;
    // The shipped infallible accessor keeps its name and its `&Path` return (Story 9.7 adds a
    // distinct verb rather than renaming it — `zanshin-ffi/src/repo.rs` arms the watcher with it).
    _ = zanshin_jj::Repo::workspace_root as fn(&zanshin_jj::Repo) -> &std::path::Path;
}

/// Bookmark mutations (Story 9.8): NO new public type — both verbs return the shipped
/// [`zanshin_jj::MutationResult`] and refuse through the shipped [`zanshin_jj::MutateError`],
/// which is why the header's type count stays 60.
///
/// The two method signatures pin the PARAMETER CURRENCY the story decided: `bookmark_create`
/// takes EXACT decoded names plus an `Option<&ChangeId>` revision (the CLI's `-r`, whose
/// default is the literal `@`), while `bookmark_delete` takes pass-through string PATTERNS —
/// a `&[String]` in both cases, so only the doc distinguishes them, and a future refactor
/// that swapped one for the other would be caught here.
///
/// Both new `MutateError` variants are constructed AND their `Display` asserted: an
/// unexercised `thiserror` arm is an uncovered line in `mutate.rs`, which the coverage ratchet
/// pins.
#[test]
fn bookmark_ops_surface_resolves() {
    let exists = zanshin_jj::MutateError::BookmarkExists {
        name: "feature".to_owned(),
        hints: Vec::new(),
    };
    assert_eq!(exists.to_string(), "bookmark already exists: feature");
    let tracked = zanshin_jj::MutateError::BookmarkTrackedRemoteExists { name: "foo".to_owned() };
    assert_eq!(
        tracked.to_string(),
        "tracked remote bookmarks exist for deleted bookmark: foo"
    );

    _ = zanshin_jj::Repo::bookmark_create
        as fn(
            &mut zanshin_jj::Repo,
            &[String],
            Option<&zanshin_jj::ChangeId>,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::bookmark_delete
        as fn(&mut zanshin_jj::Repo, &[String]) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
}

/// Story 9.19: `bookmark move` / `advance` / `rename` reuse `MutationResult`/`MutateError`; the
/// move takes its options struct (names EXACT, `from` revset texts, `to` a change id), advance
/// exact names and an optional change id, rename two decoded names and the overwrite flag. The
/// list's options and sort keys, every field and variant by its public path, and the four new
/// `BookmarkError` variants with their `Display`.
#[test]
fn bookmark_move_and_list_surface_resolves() {
    use zanshin_jj::BookmarkSortKey as K;
    let move_options = zanshin_jj::BookmarkMoveOptions {
        names: vec!["a".to_owned()],
        from: vec!["@-".to_owned()],
        to: Some(zanshin_jj::ChangeId(String::new())),
        allow_backwards: true,
    };
    assert_eq!(move_options, move_options.clone());
    _ = zanshin_jj::Repo::bookmark_move
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::BookmarkMoveOptions,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::bookmark_advance
        as fn(
            &mut zanshin_jj::Repo,
            &[String],
            Option<&zanshin_jj::ChangeId>,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::bookmark_rename
        as fn(&mut zanshin_jj::Repo, &str, &str, bool) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;

    let list = zanshin_jj::BookmarkListOptions {
        names: vec![],
        revisions: vec![],
        remotes: vec![],
        all_remotes: false,
        tracked: false,
        conflicted: false,
        sort: vec![
            K::Name,
            K::NameDesc,
            K::AuthorName,
            K::AuthorNameDesc,
            K::AuthorEmail,
            K::AuthorEmailDesc,
            K::AuthorDate,
            K::AuthorDateDesc,
            K::CommitterName,
            K::CommitterNameDesc,
            K::CommitterEmail,
            K::CommitterEmailDesc,
            K::CommitterDate,
            K::CommitterDateDesc,
        ],
    };
    assert_ne!(list, zanshin_jj::BookmarkListOptions::default());

    let errors = [
        zanshin_jj::BookmarkError::InvalidInput { reason: "i".to_owned() },
        zanshin_jj::BookmarkError::RevsetParseError { reason: "p".to_owned() },
        zanshin_jj::BookmarkError::RevsetResolutionError { reason: "r".to_owned() },
        zanshin_jj::BookmarkError::Config(zanshin_jj::ConfigError::Load { reason: "c".to_owned() }),
    ];
    let shown: Vec<String> = errors.iter().map(ToString::to_string).collect();
    assert_eq!(
        shown,
        [
            "invalid input: i",
            "invalid revset: p",
            "cannot resolve revset: r",
            &zanshin_jj::ConfigError::Load { reason: "c".to_owned() }.to_string(),
        ]
    );
}

/// Names every `SnapshotStats` / `UntrackedPath` field and BOTH `UntrackedReason` variants by
/// their public paths (Story 9.22) — the one stats shape `file track`, `file untrack` and Story
/// 9.26's per-verb snapshot share.
fn sample_snapshot_stats() -> zanshin_jj::SnapshotStats {
    zanshin_jj::SnapshotStats {
        untracked: vec![
            zanshin_jj::UntrackedPath {
                path: String::new(),
                reason: zanshin_jj::UntrackedReason::FileTooLarge { size: 0, max_size: 0 },
            },
            zanshin_jj::UntrackedPath {
                path: String::new(),
                reason: zanshin_jj::UntrackedReason::FileNotAutoTracked,
            },
        ],
        invalid_utf8_paths: vec![String::new()],
    }
}

/// Names every `TrackResult` field (Story 9.22); the nested `MutationResult` is the contract.
fn sample_track_result() -> zanshin_jj::TrackResult {
    zanshin_jj::TrackResult {
        mutation: sample_mutation_result(),
        num_rebased: 0,
        snapshot_stats: sample_snapshot_stats(),
    }
}

/// Names every `UntrackResult` field (Story 9.22), reusing the shipped `GitExportFailure`.
fn sample_untrack_result() -> zanshin_jj::UntrackResult {
    zanshin_jj::UntrackResult {
        mutation: sample_mutation_result(),
        num_rebased: 0,
        unmatched_paths: vec![String::new()],
        snapshot_stats: sample_snapshot_stats(),
        failed_bookmarks: vec![zanshin_jj::GitExportFailure {
            name: String::new(),
            remote: String::new(),
            reason: String::new(),
        }],
        failed_tags: vec![],
    }
}

/// The Story 9.22 surface: both verbs' exact signatures, both result shapes, and the three new
/// `MutateError` variants — constructed AND `Display`-asserted, since an unexercised `thiserror`
/// arm is an uncovered line in `mutate.rs`.
#[test]
fn file_track_surface_resolves() {
    _ = sample_track_result();
    _ = sample_untrack_result();
    assert_eq!(
        zanshin_jj::MutateError::NoWorkingCopy.to_string(),
        "nothing checked out in this workspace"
    );
    assert_eq!(
        zanshin_jj::MutateError::ConcurrentWorkingCopy.to_string(),
        "concurrent working copy operation"
    );
    let not_ignored = zanshin_jj::MutateError::PathsNotIgnored {
        paths: vec!["a.txt".to_owned(), "b.txt".to_owned()],
    };
    assert_eq!(not_ignored.to_string(), "paths are not ignored: a.txt, b.txt");

    _ = zanshin_jj::Repo::file_track
        as fn(&mut zanshin_jj::Repo, &[String], bool) -> Result<zanshin_jj::TrackResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::file_untrack
        as fn(&mut zanshin_jj::Repo, &[String]) -> Result<zanshin_jj::UntrackResult, zanshin_jj::MutateError>;
}

// workspace add / update-stale (Story 9.23)
type _CheckoutStats = zanshin_jj::CheckoutStats;
type _StaleRecovery = zanshin_jj::StaleRecovery;
type _StaleRecoveryOutcome = zanshin_jj::StaleRecoveryOutcome;
type _SparseInheritance = zanshin_jj::SparseInheritance;
type _WorkspaceAddResult = zanshin_jj::WorkspaceAddResult;

/// Names every `StaleRecovery` and `CheckoutStats` field by its public path (Story 9.23).
fn sample_stale_recovery() -> zanshin_jj::StaleRecovery {
    zanshin_jj::StaleRecovery {
        outcome: zanshin_jj::StaleRecoveryOutcome::Updated,
        commit_id: Some(zanshin_jj::CommitId("c".to_owned())),
        checkout: Some(zanshin_jj::CheckoutStats {
            added: 1,
            updated: 2,
            removed: 3,
            skipped: 4,
        }),
        git_head_reset_op_id: None,
        snapshot_stats: sample_snapshot_stats(),
        op_id: zanshin_jj::OperationId("o".to_owned()),
    }
}

/// The Story 9.23 surface: the two verbs' signatures (the CLI's argument arity — `workspace
/// add`'s six parameters, `update-stale`'s none), their result types named field by field, the
/// three new `MutateError` variants and `PreconditionError::ConcurrentWorkingCopy` constructed
/// AND `Display`-asserted (an unexercised `thiserror` arm is an uncovered line).
#[test]
fn workspace_add_update_stale_surface_resolves() {
    let recovery = sample_stale_recovery();
    assert_eq!(recovery.outcome, zanshin_jj::StaleRecoveryOutcome::Updated);
    _ = [
        zanshin_jj::StaleRecoveryOutcome::NotStale,
        zanshin_jj::StaleRecoveryOutcome::Recovered,
    ];
    assert_eq!(
        zanshin_jj::SparseInheritance::default(),
        zanshin_jj::SparseInheritance::Copy
    );
    _ = [
        zanshin_jj::SparseInheritance::Full,
        zanshin_jj::SparseInheritance::Empty,
    ];
    let result = zanshin_jj::WorkspaceAddResult {
        mutation: zanshin_jj::MutationResult {
            new_op_id: zanshin_jj::OperationId("o".to_owned()),
            new_change_ids: Vec::new(),
            abandoned_change_ids: Vec::new(),
            working_copy_change_id: Some(zanshin_jj::ChangeId("w".to_owned())),
            finish: None,
        },
        workspace_name: "ws2".to_owned(),
        workspace_root: std::path::PathBuf::from("/ws2"),
        git_worktree_created: false,
        checkout: zanshin_jj::CheckoutStats::default(),
    };
    assert_eq!(result.workspace_name, "ws2");

    assert_eq!(
        zanshin_jj::MutateError::WorkspaceExists { name: "x".to_owned() }.to_string(),
        "workspace already exists: x"
    );
    assert_eq!(
        zanshin_jj::MutateError::DestinationNotEmpty.to_string(),
        "destination path exists and is not an empty directory"
    );
    assert_eq!(
        zanshin_jj::MutateError::GitWorktree("g".to_owned()).to_string(),
        "git worktree failed: g"
    );
    assert_eq!(
        zanshin_jj::PreconditionError::ConcurrentWorkingCopy.to_string(),
        "concurrent working copy operation"
    );

    _ = zanshin_jj::Repo::workspace_update_stale
        as fn(&mut zanshin_jj::Repo) -> Result<zanshin_jj::StaleRecovery, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::workspace_add
        as fn(
            &mut zanshin_jj::Repo,
            &str,
            Option<&str>,
            &[String],
            &[String],
            Option<bool>,
            zanshin_jj::SparseInheritance,
        ) -> Result<zanshin_jj::WorkspaceAddResult, zanshin_jj::MutateError>;
}

// squash / split (Story 9.15)
type _SquashOptions = zanshin_jj::SquashOptions;
type _SquashPlan = zanshin_jj::SquashPlan;
type _SplitOptions = zanshin_jj::SplitOptions;
type _SplitResult = zanshin_jj::SplitResult;

/// The Story 9.15 surface: the four new types named field by field (the CLI's `jj squash` /
/// `jj split` flags, one field each) and the three `Repo` methods as `fn` pointers.
#[test]
fn squash_split_surface_resolves() {
    let id = |s: &str| zanshin_jj::ChangeId(s.to_owned());
    let squash = zanshin_jj::SquashOptions {
        revision: Some(id("r")),
        from: vec![id("f")],
        into: Some(id("i")),
        paths: vec!["p".to_owned()],
        message: Some(vec!["m".to_owned()]),
        use_destination_message: false,
        keep_emptied: true,
        edited_description: Some("e".to_owned()),
        trees: vec![zanshin_jj::SourceTree {
            source: id("f"),
            tree: sample_tree_selection(),
        }],
    };
    assert_eq!(squash.clone(), squash);
    assert_eq!(zanshin_jj::SquashOptions::default().message, None);
    let plan = zanshin_jj::SquashPlan {
        combined_description: Some("B\n\nC\n".to_owned()),
    };
    assert_eq!(plan.combined_description.as_deref(), Some("B\n\nC\n"));
    let split = zanshin_jj::SplitOptions {
        revision: None,
        paths: vec!["p".to_owned()],
        message: None,
        parallel: true,
        onto: None,
        insert_after: Some(Vec::new()),
        insert_before: Some(vec![id("b")]),
        edited_selected_description: Some("s".to_owned()),
        edited_remaining_description: Some("r".to_owned()),
        tree: Some(sample_tree_selection()),
    };
    assert_eq!(split.clone(), split);
    let result = zanshin_jj::SplitResult {
        mutation: zanshin_jj::MutationResult {
            new_op_id: zanshin_jj::OperationId("o".to_owned()),
            new_change_ids: vec![id("n")],
            abandoned_change_ids: Vec::new(),
            working_copy_change_id: Some(id("w")),
            finish: None,
        },
        selected_change_id: id("s"),
        remaining_change_id: id("n"),
    };
    assert_eq!(result.selected_change_id, id("s"));
    assert_eq!(result.remaining_change_id, result.mutation.new_change_ids[0]);

    _ = zanshin_jj::Repo::squash
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::SquashOptions,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::squash_plan
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::SquashOptions,
        ) -> Result<zanshin_jj::SquashPlan, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::split
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::SplitOptions,
        ) -> Result<zanshin_jj::SplitResult, zanshin_jj::MutateError>;
}

// rebase / parallelize / arrange (Story 9.16)
type _RebaseOptions = zanshin_jj::RebaseOptions;
type _ArrangeOptions = zanshin_jj::ArrangeOptions;
type _ArrangeAction = zanshin_jj::ArrangeAction;

/// The Story 9.16 surface: the three new types named field by field and variant by variant (the
/// CLI's `jj rebase` flags, `jj arrange`'s revisions and TUI keys), and the three `Repo` methods
/// as `fn` pointers — all three answer the shared `MutationResult`.
#[test]
fn rebase_parallelize_arrange_surface_resolves() {
    let id = |s: &str| zanshin_jj::ChangeId(s.to_owned());
    let rebase = zanshin_jj::RebaseOptions {
        branch: vec![id("b")],
        source: Vec::new(),
        revisions: Vec::new(),
        onto: vec![id("o")],
        insert_after: Vec::new(),
        insert_before: Vec::new(),
        skip_emptied: true,
        keep_divergent: false,
        simplify_parents: true,
    };
    assert_eq!(rebase.clone(), rebase);
    assert_eq!(zanshin_jj::RebaseOptions::default().branch, Vec::new());
    let actions = vec![
        zanshin_jj::ArrangeAction::SwapDown(id("d")),
        zanshin_jj::ArrangeAction::SwapUp(id("u")),
        zanshin_jj::ArrangeAction::Abandon(id("a")),
        zanshin_jj::ArrangeAction::Keep(id("k")),
    ];
    let arrange = zanshin_jj::ArrangeOptions {
        revisions: vec![id("r")],
        actions,
    };
    assert_eq!(arrange.clone(), arrange);
    assert_eq!(zanshin_jj::ArrangeOptions::default().actions, Vec::new());

    _ = zanshin_jj::Repo::rebase
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::RebaseOptions,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::parallelize
        as fn(
            &mut zanshin_jj::Repo,
            &[zanshin_jj::ChangeId],
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::arrange
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::ArrangeOptions,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
}

// metaedit / duplicate / fix (Story 9.9)
type _MetaeditOptions = zanshin_jj::MetaeditOptions;
type _DuplicateOptions = zanshin_jj::DuplicateOptions;
type _FixOptions = zanshin_jj::FixOptions;
type _FixResult = zanshin_jj::FixResult;
type _FixToolStderr = zanshin_jj::FixToolStderr;

/// The Story 9.9 surface: the five new types named field by field (the CLI's `jj metaedit`, `jj
/// duplicate` and `jj fix` flags, fix's outcome), and the three `Repo` methods as `fn` pointers.
#[test]
fn metaedit_duplicate_fix_surface_resolves() {
    let id = |s: &str| zanshin_jj::ChangeId(s.to_owned());
    let metaedit = zanshin_jj::MetaeditOptions {
        revisions: vec![id("r")],
        update_change_id: true,
        message: Some(vec!["m".to_owned()]),
        update_author_timestamp: false,
        update_author: true,
        author: None,
        author_timestamp: Some("2000-01-23T01:23:45-08:00".to_owned()),
        force_rewrite: false,
    };
    assert_eq!(metaedit.clone(), metaedit);
    assert_eq!(zanshin_jj::MetaeditOptions::default().message, None);
    let duplicate = zanshin_jj::DuplicateOptions {
        revisions: vec![id("r")],
        onto: Vec::new(),
        insert_after: vec![id("a")],
        insert_before: vec![id("b")],
    };
    assert_eq!(duplicate.clone(), duplicate);
    assert_eq!(zanshin_jj::DuplicateOptions::default().onto, Vec::new());
    let fix = zanshin_jj::FixOptions {
        source: vec![id("s")],
        paths: vec!["p".to_owned()],
        include_unchanged_files: true,
        all_lines: false,
    };
    assert_eq!(fix.clone(), fix);
    assert!(!zanshin_jj::FixOptions::default().all_lines);
    let stderr = zanshin_jj::FixToolStderr {
        path: "a.txt".to_owned(),
        stderr: "oops".to_owned(),
    };
    assert_eq!(stderr.clone(), stderr);
    let result = zanshin_jj::FixResult {
        mutation: zanshin_jj::MutationResult {
            new_op_id: zanshin_jj::OperationId(String::new()),
            new_change_ids: Vec::new(),
            abandoned_change_ids: Vec::new(),
            working_copy_change_id: Some(id("w")),
            finish: None,
        },
        num_fixed_commits: 1,
        num_checked_commits: 2,
        tool_stderr: vec![stderr],
    };
    assert_eq!(result.num_fixed_commits + result.num_checked_commits, 3);
    assert_eq!(result.tool_stderr.len(), 1);
    assert!(result.mutation.finish.is_none());

    _ = zanshin_jj::Repo::metaedit
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::MetaeditOptions,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::duplicate
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::DuplicateOptions,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::fix
        as fn(&mut zanshin_jj::Repo, &zanshin_jj::FixOptions) -> Result<zanshin_jj::FixResult, zanshin_jj::MutateError>;
}

// drop actions (Story 9.31)
type _DropSource = zanshin_jj::DropSource;
type _DropLocation = zanshin_jj::DropLocation;
type _DropVerb = zanshin_jj::DropVerb;
type _ActionStatus = zanshin_jj::ActionStatus;
type _ActionOutcome = zanshin_jj::ActionOutcome;
type _DropAction = zanshin_jj::DropAction;
type _DropActions = zanshin_jj::DropActions;
type _ChangeActions = zanshin_jj::ChangeActions;

/// The Story 9.31 surface: the eight new types named variant by variant and field by field, and
/// the two `Repo` queries as `fn` pointers.
#[test]
fn drop_actions_surface_resolves() {
    let id = |s: &str| zanshin_jj::ChangeId(s.to_owned());
    let sources = [
        zanshin_jj::DropSource::Change(id("s")),
        zanshin_jj::DropSource::Selection {
            change: id("s"),
            paths: vec!["p".to_owned()],
        },
        zanshin_jj::DropSource::Bookmark("main".to_owned()),
    ];
    assert_eq!(sources.clone(), sources);
    let location = zanshin_jj::DropLocation {
        onto: vec![id("t")],
        insert_after: Vec::new(),
        insert_before: Vec::new(),
    };
    assert_eq!(location.clone(), location);
    assert!(zanshin_jj::DropLocation::default().onto.is_empty());
    let verbs = [
        zanshin_jj::DropVerb::RebaseSource,
        zanshin_jj::DropVerb::RebaseRevisions,
        zanshin_jj::DropVerb::Squash,
        zanshin_jj::DropVerb::NewMerge,
        zanshin_jj::DropVerb::Duplicate,
        zanshin_jj::DropVerb::Split,
        zanshin_jj::DropVerb::BookmarkMove,
        // The Story 9.31 follow-on's rows, appended.
        zanshin_jj::DropVerb::RebaseBranch,
        zanshin_jj::DropVerb::Revert,
        zanshin_jj::DropVerb::Restore,
        zanshin_jj::DropVerb::Absorb,
        zanshin_jj::DropVerb::Interdiff,
    ];
    assert_eq!(verbs.len(), 12);
    let outcome = |status| zanshin_jj::ActionOutcome {
        status,
        refusal: None,
        combined_description_needed: false,
        allow_backwards_needed: false,
    };
    let refused = zanshin_jj::ActionOutcome {
        status: zanshin_jj::ActionStatus::Refused,
        refusal: Some(zanshin_jj::MutateError::ChangeNotFound { id: "x".to_owned() }),
        combined_description_needed: false,
        allow_backwards_needed: true,
    };
    let actions = zanshin_jj::DropActions {
        actions: vec![zanshin_jj::DropAction {
            verb: zanshin_jj::DropVerb::Squash,
            location: 0,
            outcome: refused,
        }],
    };
    assert_eq!(actions.actions[0].location, 0_usize);
    let card = zanshin_jj::ChangeActions {
        new_onto: outcome(zanshin_jj::ActionStatus::Available),
        new_insert_after: outcome(zanshin_jj::ActionStatus::Available),
        new_insert_before: outcome(zanshin_jj::ActionStatus::Available),
        edit: outcome(zanshin_jj::ActionStatus::Available),
        describe: outcome(zanshin_jj::ActionStatus::Available),
        squash_into_parent: outcome(zanshin_jj::ActionStatus::NoOp),
        abandon: outcome(zanshin_jj::ActionStatus::Available),
    };
    assert_eq!(card.squash_into_parent.status, zanshin_jj::ActionStatus::NoOp);

    _ = zanshin_jj::Repo::drop_actions
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::DropSource,
            &[zanshin_jj::DropLocation],
        ) -> Result<zanshin_jj::DropActions, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::change_actions
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::ChangeId,
        ) -> Result<zanshin_jj::ChangeActions, zanshin_jj::MutateError>;
}

// commit (Story 9.49)
type _CommitOptions = zanshin_jj::CommitOptions;

/// The Story 9.49 surface: `CommitOptions` named field by field (the CLI's `jj commit -m [paths]`)
/// and `Repo::commit` as a `fn` pointer.
#[test]
fn commit_surface_resolves() {
    let options = zanshin_jj::CommitOptions {
        paths: vec!["p".to_owned()],
        message: vec!["m".to_owned()],
        tree: Some(sample_tree_selection()),
    };
    assert_eq!(options.clone(), options);
    let default = zanshin_jj::CommitOptions::default();
    assert!(default.paths.is_empty() && default.message.is_empty() && default.tree.is_none());
    _ = zanshin_jj::Repo::commit
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::CommitOptions,
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
}

// select_tree (Story 9.50)
type _HunkKey = zanshin_jj::HunkKey;
type _FileChoice = zanshin_jj::FileChoice;
type _FileSelection = zanshin_jj::FileSelection;
type _SelectTreeOptions = zanshin_jj::SelectTreeOptions;
type _SelectedTreeId = zanshin_jj::SelectedTreeId;
type _TreeSelection = zanshin_jj::TreeSelection;
type _SourceTree = zanshin_jj::SourceTree;

/// Names every `TreeSelection` / `SelectedTreeId` field by its public path (Story 9.50).
fn sample_tree_selection() -> zanshin_jj::TreeSelection {
    zanshin_jj::TreeSelection {
        tree: zanshin_jj::SelectedTreeId {
            tree_ids: vec!["t".to_owned()],
            labels: Vec::new(),
        },
        left: vec!["l".to_owned()],
    }
}

/// The Story 9.50 surface: the selection types named field by field, the stale refusal and
/// `Repo::select_tree` as a `fn` pointer.
#[test]
fn select_tree_surface_resolves() {
    let key = zanshin_jj::HunkKey {
        old_start: 0,
        old_count: 1,
        new_start: 0,
        new_count: 2,
    };
    let options = zanshin_jj::SelectTreeOptions {
        revision: Some(zanshin_jj::ChangeId("r".to_owned())),
        left: vec!["l".to_owned()],
        files: vec![
            zanshin_jj::FileSelection {
                path: "a".to_owned(),
                choice: zanshin_jj::FileChoice::Whole,
            },
            zanshin_jj::FileSelection {
                path: "b".to_owned(),
                choice: zanshin_jj::FileChoice::Hunks(vec![key]),
            },
        ],
    };
    assert_eq!(options.clone(), options);
    assert_eq!(zanshin_jj::SelectTreeOptions::default().revision, None);
    assert_eq!(sample_tree_selection().clone(), sample_tree_selection());
    let stale = zanshin_jj::MutateError::StaleSelection { reason: "r".to_owned() };
    assert!(stale.hints().is_empty());
    _ = zanshin_jj::Repo::select_tree
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::SelectTreeOptions,
        ) -> Result<zanshin_jj::SelectedTreeId, zanshin_jj::MutateError>;
}

// operation-log surface (Story 9.21)
type _OpShow = zanshin_jj::OpShow;
type _OpDiffResult = zanshin_jj::OpDiffResult;
type _OpAbandonResult = zanshin_jj::OpAbandonResult;

/// Names every `OpDiff` section type field by field (Story 9.21).
fn sample_op_diff() -> zanshin_jj::OpDiff {
    let target = zanshin_jj::OpRefTarget {
        adds: vec![zanshin_jj::CommitId("c".to_owned())],
        removes: Vec::new(),
        conflicted: false,
    };
    zanshin_jj::OpDiff {
        commits: Some(zanshin_jj::OpCommitsDiff {
            changes: vec![zanshin_jj::OpChangedCommit {
                commit_id: zanshin_jj::CommitId("c".to_owned()),
                abandoned: false,
                added_commit_ids: Vec::new(),
                removed_commit_ids: Vec::new(),
            }],
            elided_newly_visible: zanshin_jj::RefDistance {
                lower: 0,
                upper: Some(0),
            },
            elided_newly_hidden: zanshin_jj::RefDistance { lower: 0, upper: None },
        }),
        working_copies: vec![zanshin_jj::OpWorkingCopyChange {
            workspace: "default".to_owned(),
            from: None,
            to: Some(zanshin_jj::CommitId("c".to_owned())),
        }],
        local_bookmarks: vec![zanshin_jj::OpRefChange {
            name: "b".to_owned(),
            from: target.clone(),
            to: target.clone(),
        }],
        local_tags: Vec::new(),
        remote_bookmarks: vec![zanshin_jj::OpRemoteRefChange {
            name: "b".to_owned(),
            remote: "origin".to_owned(),
            from: target.clone(),
            from_tracked: false,
            to: target,
            to_tracked: true,
        }],
        remote_tags: Vec::new(),
    }
}

/// The Story 9.21 surface: `Operation`'s two new fields, the op-show / op-diff / op-abandon
/// types named field by field, the three new refusals and the four verbs as `fn` pointers.
#[test]
fn story_9_21_operation_log_surface_resolves() {
    let tag = zanshin_jj::OperationTag {
        key: "args".to_owned(),
        value: "jj".to_owned(),
    };
    let operation = zanshin_jj::Operation {
        id: zanshin_jj::OperationId("o".to_owned()),
        parent_ids: Vec::new(),
        timestamp: zanshin_jj::Timestamp {
            millis_since_epoch: 0,
            tz_offset_minutes: 0,
        },
        user: String::new(),
        host: String::new(),
        description: String::new(),
        root_op: false,
        is_snapshot: false,
        workspace_name: Some("default".to_owned()),
        tags: vec![tag],
    };
    let diff = sample_op_diff();
    let show = zanshin_jj::OpShow {
        operation: operation.clone(),
        diff: Some(diff.clone()),
    };
    assert_eq!(show.clone(), show);
    let result = zanshin_jj::OpDiffResult {
        from: vec![operation.clone()],
        to: operation,
        diff,
    };
    assert_eq!(result.clone(), result);
    let options = zanshin_jj::OpDiffOptions {
        operation: None,
        from: Some("@-".to_owned()),
        to: None,
        show_changes_in: Some("all()".to_owned()),
    };
    assert_eq!(zanshin_jj::OpDiffOptions::default().operation, None);
    let abandoned = zanshin_jj::OpAbandonResult {
        abandoned_count: 1,
        reparented_count: 1,
        nothing_changed: false,
        head_op_ids: vec![zanshin_jj::OperationId("o".to_owned())],
    };
    assert_eq!(abandoned.clone(), abandoned);
    _ = (
        options,
        zanshin_jj::MutateError::NothingToRedo,
        zanshin_jj::MutateError::RedoCrossWorkspace {
            operation: String::new(),
            workspace: String::new(),
        },
        zanshin_jj::MutateError::OperationNotFound { reason: String::new() },
    );
    _ = zanshin_jj::Repo::redo
        as fn(&mut zanshin_jj::Repo, bool) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::op_show
        as fn(&mut zanshin_jj::Repo, &str, Option<&str>) -> Result<zanshin_jj::OpShow, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::op_diff
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::OpDiffOptions,
        ) -> Result<zanshin_jj::OpDiffResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::op_abandon
        as fn(&mut zanshin_jj::Repo, &str) -> Result<zanshin_jj::OpAbandonResult, zanshin_jj::MutateError>;
}

/// The Story 9.12 surface: `RestoreWhat`'s two members, `OpIntegrateResult` field by field, the
/// optional working-copy change id, and the three verbs as `fn` pointers.
#[test]
fn story_9_12_operation_edit_surface_resolves() {
    let what = [zanshin_jj::RestoreWhat::Repo, zanshin_jj::RestoreWhat::RemoteTracking];
    assert!(
        what[0] < what[1],
        "declaration order, as the CLI's `RevertWhatToRestore`"
    );
    let integrated = zanshin_jj::OpIntegrateResult {
        head_op_id: zanshin_jj::OperationId("o".to_owned()),
        reconciled: false,
    };
    assert_eq!(integrated.clone(), integrated);
    let no_working_copy: Option<zanshin_jj::ChangeId> = sample_mutation_result().working_copy_change_id;
    _ = (no_working_copy, zanshin_jj::WarningKind::WorkspaceNoLongerExists);
    // A status without `@` (the CLI's "No working copy.") has both change ids absent.
    let no_at = zanshin_jj::Status {
        files: Vec::new(),
        working_copy_change_id: None,
        parent_change_id: None,
    };
    let _: (Option<zanshin_jj::ChangeId>, Option<zanshin_jj::ChangeId>) =
        (no_at.working_copy_change_id, no_at.parent_change_id);
    _ = zanshin_jj::Repo::op_restore
        as fn(
            &mut zanshin_jj::Repo,
            &str,
            &[zanshin_jj::RestoreWhat],
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::op_revert
        as fn(
            &mut zanshin_jj::Repo,
            &str,
            &[zanshin_jj::RestoreWhat],
        ) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::op_integrate
        as fn(&mut zanshin_jj::Repo, &str) -> Result<zanshin_jj::OpIntegrateResult, zanshin_jj::MutateError>;
}

// snapshot precondition (Story 9.26)
type _Precondition = zanshin_jj::Precondition;
type _PreconditionError = zanshin_jj::PreconditionError;
type _StaleCause = zanshin_jj::StaleCause;
type _FinishFacts = zanshin_jj::FinishFacts;

/// Names every `Precondition` field by its public path (Story 9.26).
fn sample_precondition() -> zanshin_jj::Precondition {
    zanshin_jj::Precondition {
        was_snapshot_taken: false,
        snapshot_stats: sample_snapshot_stats(),
        git_head_imported: false,
        git_head_reset: false,
        git_head_rebased: 0,
        snapshot_rebased: 0,
        git_refs: Some(sample_git_import_result()),
        git_refs_rebased: 0,
        finish: Some(sample_finish_facts()),
        stale_recovery: Some(sample_stale_recovery()),
    }
}

/// The Story 9.26 surface: the precondition's types, the explicit `snapshot` verb and
/// `take_precondition`, the `&mut self` receivers every snapshotting read gained, and the
/// `Precondition` variant each error enum gained — constructed AND `Display`-asserted, since
/// the variant is `#[error(transparent)]`.
#[test]
fn snapshot_precondition_surface_resolves() {
    _ = sample_precondition();
    let stale = zanshin_jj::PreconditionError::StaleWorkingCopy {
        cause: zanshin_jj::StaleCause::SiblingOperation,
        working_copy_op_id: "a".to_owned(),
        repo_op_id: "b".to_owned(),
    };
    assert_eq!(
        stale.to_string(),
        "stale working copy (sibling_operation): working copy at operation a, repo at b"
    );
    let config = || zanshin_jj::PreconditionError::Config { reason: "k".to_owned() };
    assert_eq!(config().to_string(), "config error: k");
    assert_eq!(
        zanshin_jj::PreconditionError::Backend("b".to_owned()).to_string(),
        "jj-lib error: b"
    );
    assert_eq!(zanshin_jj::StaleCause::Stale.as_str(), "stale");
    assert_eq!(
        zanshin_jj::StaleCause::OperationNotFound.to_string(),
        "operation_not_found"
    );

    // Every error enum wraps the precondition failure transparently.
    assert_eq!(zanshin_jj::MutateError::from(config()).to_string(), "config error: k");
    assert_eq!(zanshin_jj::StatusError::from(config()).to_string(), "config error: k");
    assert_eq!(zanshin_jj::ChangeError::from(config()).to_string(), "config error: k");
    assert_eq!(zanshin_jj::OpLogError::from(config()).to_string(), "config error: k");
    assert_eq!(zanshin_jj::BookmarkError::from(config()).to_string(), "config error: k");
    assert_eq!(zanshin_jj::ViewError::from(config()).to_string(), "config error: k");
    assert_eq!(zanshin_jj::RemoteError::from(config()).to_string(), "config error: k");
    assert_eq!(zanshin_jj::FileError::from(config()).to_string(), "config error: k");
    assert_eq!(zanshin_jj::RevsetError::from(config()).to_string(), "config error: k");
    assert_eq!(
        zanshin_jj::CommitViewError::from(config()).to_string(),
        "config error: k"
    );
    assert_eq!(
        zanshin_jj::WorkspaceError::from(config()).to_string(),
        "config error: k"
    );

    _ = zanshin_jj::Repo::snapshot
        as fn(&mut zanshin_jj::Repo) -> Result<zanshin_jj::Precondition, zanshin_jj::PreconditionError>;
    _ = zanshin_jj::Repo::take_precondition as fn(&mut zanshin_jj::Repo) -> Option<zanshin_jj::Precondition>;
    _ = zanshin_jj::Repo::status as fn(&mut zanshin_jj::Repo) -> Result<zanshin_jj::Status, zanshin_jj::StatusError>;
    _ = zanshin_jj::Repo::get_change
        as fn(&mut zanshin_jj::Repo, &zanshin_jj::ChangeId) -> Result<zanshin_jj::Change, zanshin_jj::ChangeError>;
    _ = zanshin_jj::Repo::op_log
        as fn(&mut zanshin_jj::Repo, Option<usize>) -> Result<Vec<zanshin_jj::Operation>, zanshin_jj::OpLogError>;
    _ = zanshin_jj::Repo::list_bookmarks
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::BookmarkListOptions,
        ) -> Result<Vec<zanshin_jj::Bookmark>, zanshin_jj::BookmarkError>;
    _ = zanshin_jj::Repo::list_remotes
        as fn(&mut zanshin_jj::Repo) -> Result<Vec<zanshin_jj::Remote>, zanshin_jj::RemoteError>;
    // A config read with no CLI verb behind it: no snapshot, still `&self`.
    _ = zanshin_jj::Repo::log_defaults
        as fn(&zanshin_jj::Repo) -> Result<zanshin_jj::LogDefaults, zanshin_jj::ConfigError>;
}

/// Story 9.28: the config surface — nine free functions (no `Repo` handle), their types, and the
/// `Display` of every `ConfigCmdError` arm.
#[test]
fn story_9_28_surface_resolves() {
    use std::path::{Path, PathBuf};
    use zanshin_jj::{ConfigCmdError as E, ConfigScope, ConfigValueSource};

    // Story 9.37: the six verbs that can start with the secure-config fix-up report its warnings
    // on success AND failure — `ConfigOutcome`.
    use zanshin_jj::ConfigOutcome as O;
    // jj 0.45: `--user|--repo|--workspace|--file PATH` is one `ConfigTarget`.
    use zanshin_jj::ConfigTarget as T;
    _ = zanshin_jj::config_list as fn(Option<&Path>, &zanshin_jj::ConfigListQuery) -> O<Vec<zanshin_jj::ConfigEntry>>;
    _ = zanshin_jj::config_get as fn(Option<&Path>, &str) -> O<String>;
    _ = zanshin_jj::config_path as fn(Option<&Path>, ConfigScope) -> O<Vec<PathBuf>>;
    _ = zanshin_jj::config_set as fn(Option<&Path>, &T, &str, &str) -> zanshin_jj::ConfigSetOutcome;
    _ = zanshin_jj::config_unset as fn(Option<&Path>, &T, &str) -> O<PathBuf>;
    _ = zanshin_jj::config_file_read as fn(Option<&Path>, &T) -> O<zanshin_jj::ConfigFileText>;
    for target in [T::Scope(ConfigScope::User), T::File(PathBuf::new())] {
        match target {
            T::Scope(_) | T::File(_) => {}
        }
    }
    _ = zanshin_jj::config_file_write as fn(Option<&Path>, &Path, &str) -> O<()>;
    let outcome: O<()> = zanshin_jj::ConfigOutcome {
        result: Err(E::NotFound { reason: String::new() }),
        warnings: vec![zanshin_jj::Warning {
            kind: zanshin_jj::WarningKind::ConfigMigrated,
            message: String::new(),
        }],
    };
    assert!(outcome.result.is_err() && outcome.warnings.len() == 1);
    _ = zanshin_jj::config_gc_list as fn() -> O<Vec<zanshin_jj::MissingRepoConfig>>;
    _ = zanshin_jj::config_gc_delete as fn(&[PathBuf]) -> O<zanshin_jj::ConfigGcResult>;

    _ = zanshin_jj::ConfigEntry {
        name: String::new(),
        value: String::new(),
        source: ConfigValueSource::EnvOverrides,
        path: None,
        overridden: false,
    };
    _ = zanshin_jj::ConfigListQuery {
        name: None,
        scope: Some(ConfigScope::Workspace),
        include_defaults: false,
        include_overridden: true,
    };
    _ = zanshin_jj::ConfigSetOutcome {
        result: Ok(zanshin_jj::ConfigSetResult {
            path: PathBuf::new(),
            working_copy_author: Some(zanshin_jj::WorkingCopyAuthor {
                name: String::new(),
                email: String::new(),
            }),
        }),
        precondition: None,
        warnings: vec![],
    };
    _ = zanshin_jj::ConfigFileText {
        path: PathBuf::new(),
        text: String::new(),
    };
    _ = zanshin_jj::MissingRepoConfig {
        config_dir: PathBuf::new(),
        repo_path: PathBuf::new(),
    };
    _ = zanshin_jj::ConfigGcResult {
        deleted: Vec::new(),
        failed: vec![zanshin_jj::ConfigGcFailure {
            config_dir: PathBuf::new(),
            reason: String::new(),
        }],
    };
    for (err, text) in [
        (E::Config { reason: "r".into() }, "config error: r"),
        (E::PathNotFound { path: "/p".into() }, "path not found: /p"),
        (E::NotARepo { path: "/p".into() }, "not a jj repository: /p"),
        (E::NotFound { reason: "n".into() }, "n"),
        (E::WouldOverwrite { reason: "o".into() }, "o"),
        (E::WouldDeleteTable { reason: "d".into() }, "d"),
        (
            E::UnrecognizedFile { path: "/a".into() },
            "Configuration file '/a' is not a valid jj configuration file location",
        ),
        (
            E::Parse {
                message: "m".into(),
                span: Some(1..2),
            },
            "m",
        ),
        (E::NoConfigPath { reason: "x".into() }, "x"),
    ] {
        assert_eq!(err.to_string(), text);
    }
    assert_eq!(
        E::from(zanshin_jj::ConfigError::Load { reason: "c".into() }).to_string(),
        "config error: c"
    );
}

/// Every `WarningKind`, in registry order (Story 9.32; Story 9.20 adds the push and clone kinds;
/// Story 9.53 the unresolved conflicts; Story 9.51 the template diagnostic; Story 9.54's closing
/// run the bookmark auto-track warning; Story 9.19 the four rename warnings).
const EVERY_WARNING_KIND: [zanshin_jj::WarningKind; 67] = {
    use zanshin_jj::WarningKind as K;
    [
        K::IdentityMissing,
        K::WorkingCopyImmutable,
        K::JjconflictFilesPresent,
        K::GitHeadUpdateFailed,
        K::GitExportFailed,
        K::GitImportFailed,
        K::SnapshotFilesRefused,
        K::SnapshotPathsNotUtf8,
        K::CheckoutFilesSkipped,
        K::UnresolvedConflicts,
        K::PathsUnmatched,
        K::ConfigAliasInvalid,
        K::ConfigAliasRedefined,
        K::RevsetDiagnostic,
        K::ShortPrefixesFailed,
        K::RemoteUrlDuplicate,
        K::BookmarkTargetEmpty,
        K::BookmarkNamesUnmatched,
        K::BookmarkAutoTrackExisting,
        K::BookmarkRenameRemoteExists,
        K::BookmarkTrackingDropped,
        K::BookmarkRemotesNotRenamed,
        K::BookmarkTrackedRemotesExist,
        K::AbsorbPathSkipped,
        K::PathAccessDenied,
        K::PathNotAFile,
        K::ConfigWorkingCopyAuthor,
        K::ConfigGcDeleteFailed,
        K::ConfigNothingListed,
        K::CloneCleanupFailed,
        K::ConfigMigrated,
        K::ConfigCopied,
        K::ConfigRegenerated,
        K::UndoPushOperation,
        K::UndoWorkspaceRemoval,
        K::ColocatedInGitWorktree,
        K::WorkspacePathInaccessible,
        K::WorkspaceInCurrentDirectory,
        K::SplitAllSelected,
        K::SplitNoneSelected,
        K::CommitPathsUnmatched,
        K::PushRemotesUnmatched,
        K::PushBookmarksUnmatched,
        K::PushTagsUnmatched,
        K::PushRevsetEmpty,
        K::PushRevisionsEmpty,
        K::PushRefSkipped,
        K::PushCommitSkipped,
        K::PushRefsMovedOnRemote,
        K::PushRemoteRejected,
        K::PushBookmarksNotUpdatedLocally,
        K::PushSigningSkippedImmutable,
        K::CloneBranchesUnmatched,
        K::TemplateDiagnostic,
        K::FetchRemotesUnmatched,
        K::FetchRefspecIgnored,
        K::FetchBranchesUnmatched,
        K::TrunkAliasUnresolved,
        K::DuplicateAsOwnDescendant,
        K::DuplicateAsOwnAncestor,
        K::FixToolStartFailed,
        K::FixToolFailed,
        K::FilesetDiagnostic,
        K::ConfigDeprecated,
        K::OpDiffChangesUnresolved,
        K::OpAbandonWorkingCopyNotUpdated,
        K::WorkspaceNoLongerExists,
    ]
};

/// Story 9.30: `jj git fetch`'s args and outcome, and the default-remote query — every type and
/// field named by its public path, so a rename breaks this test at compile time.
#[test]
fn story_9_30_fetch_surface_resolves() {
    _ = zanshin_jj::Repo::git_fetch_remotes
        as fn(&mut zanshin_jj::Repo) -> Result<Vec<String>, zanshin_jj::MutateError>;
    let args = zanshin_jj::GitFetchArgs {
        remotes: zanshin_jj::FetchRemotes::Named(vec![String::new()]),
        refs: zanshin_jj::FetchRefs::Patterns {
            branches: Vec::new(),
            tags: Vec::new(),
        },
    };
    _ = (zanshin_jj::FetchRemotes::All, zanshin_jj::FetchRefs::Tracked, args);
    assert_eq!(
        zanshin_jj::GitFetchArgs::default(),
        zanshin_jj::GitFetchArgs {
            remotes: zanshin_jj::FetchRemotes::Default,
            refs: zanshin_jj::FetchRefs::Default,
        }
    );
    _ = |outcome: zanshin_jj::GitFetchOutcome| {
        let zanshin_jj::GitFetchOutcome {
            mutation,
            remotes,
            hints,
            failed_ref_names,
            changed_bookmarks,
            changed_tags,
            num_rewritten,
        } = outcome;
        let _: (Vec<zanshin_jj::GitRefUpdate>, Vec<zanshin_jj::GitRefUpdate>, u32) =
            (changed_bookmarks, changed_tags, num_rewritten);
        (mutation, remotes, hints, failed_ref_names)
    };
}

/// Story 9.32: the warning channel — `Warning`, every `WarningKind` (matched EXHAUSTIVELY, so a
/// variant added or removed breaks this test at compile time), `Warned`, and
/// `Repo::take_warnings`.
#[test]
fn story_9_32_warning_surface_resolves() {
    use zanshin_jj::WarningKind as K;

    let warning = zanshin_jj::Warning {
        kind: K::IdentityMissing,
        message: String::new(),
    };
    let warned = zanshin_jj::Warned {
        value: (),
        warnings: vec![warning.clone()],
    };
    assert_eq!(warned.warnings, [warning]);
    let every = EVERY_WARNING_KIND;
    for kind in every {
        match kind {
            K::IdentityMissing
            | K::WorkingCopyImmutable
            | K::JjconflictFilesPresent
            | K::GitHeadUpdateFailed
            | K::GitExportFailed
            | K::GitImportFailed
            | K::SnapshotFilesRefused
            | K::SnapshotPathsNotUtf8
            | K::CheckoutFilesSkipped
            | K::UnresolvedConflicts
            | K::PathsUnmatched
            | K::ConfigAliasInvalid
            | K::ConfigAliasRedefined
            | K::RevsetDiagnostic
            | K::ShortPrefixesFailed
            | K::RemoteUrlDuplicate
            | K::BookmarkTargetEmpty
            | K::BookmarkNamesUnmatched
            | K::BookmarkAutoTrackExisting
            | K::BookmarkRenameRemoteExists
            | K::BookmarkTrackingDropped
            | K::BookmarkRemotesNotRenamed
            | K::BookmarkTrackedRemotesExist
            | K::AbsorbPathSkipped
            | K::PathAccessDenied
            | K::PathNotAFile
            | K::ConfigWorkingCopyAuthor
            | K::ConfigGcDeleteFailed
            | K::ConfigNothingListed
            | K::CloneCleanupFailed
            | K::ConfigMigrated
            | K::ConfigCopied
            | K::ConfigRegenerated
            | K::UndoPushOperation
            | K::UndoWorkspaceRemoval
            | K::ColocatedInGitWorktree
            | K::WorkspacePathInaccessible
            | K::WorkspaceInCurrentDirectory
            | K::SplitAllSelected
            | K::SplitNoneSelected
            | K::CommitPathsUnmatched
            | K::PushRemotesUnmatched
            | K::PushBookmarksUnmatched
            | K::PushTagsUnmatched
            | K::PushRevsetEmpty
            | K::PushRevisionsEmpty
            | K::PushRefSkipped
            | K::PushCommitSkipped
            | K::PushRefsMovedOnRemote
            | K::PushRemoteRejected
            | K::PushBookmarksNotUpdatedLocally
            | K::PushSigningSkippedImmutable
            | K::CloneBranchesUnmatched
            | K::TemplateDiagnostic
            | K::FetchRemotesUnmatched
            | K::FetchRefspecIgnored
            | K::FetchBranchesUnmatched
            | K::TrunkAliasUnresolved
            | K::DuplicateAsOwnDescendant
            | K::DuplicateAsOwnAncestor
            | K::FixToolStartFailed
            | K::FixToolFailed
            | K::FilesetDiagnostic
            | K::ConfigDeprecated
            | K::OpDiffChangesUnresolved
            | K::OpAbandonWorkingCopyNotUpdated
            | K::WorkspaceNoLongerExists => {}
        }
    }
    assert_eq!(every.len(), 67);
    _ = zanshin_jj::Repo::take_warnings as fn(&mut zanshin_jj::Repo) -> Vec<zanshin_jj::Warning>;
}

/// Story 9.36: the start-up adoption of the login shell's environment — its signature named by
/// its public path, so a rename or a type change breaks this test at compile time.
#[test]
fn story_9_36_login_shell_adoption_resolves() {
    use std::collections::HashMap;
    use std::ffi::OsString;
    use std::hash::RandomState;

    _ = zanshin_jj::adopt_environment::<RandomState> as fn(HashMap<OsString, OsString>);
}

/// Story 9.33: the four creation functions return a `CreationOutcome` — every field named by its
/// public path, so a rename or a type change breaks this test at compile time.
#[test]
fn story_9_33_creation_outcome_resolves() {
    use std::path::Path;

    // Story 9.20: init and clone take their CLI parameters as option structs.
    _ = zanshin_jj::Repo::init as fn(&zanshin_jj::InitOptions) -> zanshin_jj::CreationOutcome;
    _ = zanshin_jj::Repo::clone
        as fn(
            &zanshin_jj::CloneOptions,
            &zanshin_jj::ProgressFn,
            Option<&zanshin_jj::cancel::CancelGuard>,
        ) -> zanshin_jj::CreationOutcome;
    _ = zanshin_jj::convert_colocated as fn(&Path) -> zanshin_jj::CreationOutcome;
    _ = zanshin_jj::convert_import as fn(&Path, &Path) -> zanshin_jj::CreationOutcome;
    // Story 9.37: open reports its start-up secure-config fix-up in the same shape.
    _ = zanshin_jj::Repo::open_with_report as fn(&Path) -> zanshin_jj::CreationOutcome;
    let outcome = zanshin_jj::CreationOutcome {
        result: Err(zanshin_jj::RepoError::CloneFailed {
            reason: String::new(),
            hints: Vec::new(),
        }),
        precondition: Some(zanshin_jj::Precondition::default()),
        warnings: vec![zanshin_jj::Warning {
            kind: zanshin_jj::WarningKind::CloneCleanupFailed,
            message: String::new(),
        }],
        // Story 9.57: what a failed conversion created and left on disk.
        left_behind: vec![std::path::PathBuf::new()],
    };
    assert!(outcome.result.is_err());
}

/// Story 9.20: `git push`, `git clone`, `git init` — every public type and field named by its
/// public path, so a rename or a type change breaks this test at compile time.
#[test]
fn story_9_20_push_clone_init_resolves() {
    use std::num::NonZeroU32;
    use std::path::PathBuf;

    let _ = zanshin_jj::InitOptions {
        path: PathBuf::new(),
        backend: Some(zanshin_jj::Backend::Git),
        colocate: Some(true),
        object_hash: Some(zanshin_jj::ObjectHash::Sha256),
    };
    let _ = zanshin_jj::CloneOptions {
        source: String::new(),
        destination: PathBuf::new(),
        remote_name: Some(String::new()),
        colocate: None,
        depth: NonZeroU32::new(1),
        branches: Some(Vec::new()),
        tags: None,
        object_hash: Some(zanshin_jj::ObjectHash::Sha1),
    };
    _ = zanshin_jj::RepoError::DestinationNotEmpty { path: PathBuf::new() };
    _ = zanshin_jj::RepoError::GitRepoExists { path: PathBuf::new() };
    _ = zanshin_jj::RepoError::InvalidInput { reason: String::new() };
    // Story 9.20 closing run: the clone's `git` subprocess failure is typed.
    _ = zanshin_jj::RepoError::NetworkError { reason: String::new() };
    _ = zanshin_jj::MutateError::PushRefRefused {
        message: String::new(),
        hints: Vec::new(),
    };
    _ = zanshin_jj::MutateError::PushCommitRejected {
        message: String::new(),
        hints: Vec::new(),
    };
    // Story 9.54: the default push remotes, for the GUI's "ahead" rule.
    _ = zanshin_jj::Repo::git_push_remotes as fn(&mut zanshin_jj::Repo) -> Result<Vec<String>, zanshin_jj::MutateError>;
    _ = zanshin_jj::Repo::git_push
        as fn(
            &mut zanshin_jj::Repo,
            &zanshin_jj::GitPushArgs,
            &zanshin_jj::ProgressFn,
            Option<&zanshin_jj::cancel::CancelGuard>,
        ) -> Result<zanshin_jj::GitPushOutcome, zanshin_jj::MutateError>;
    let _ = zanshin_jj::GitPushArgs {
        remotes: Some(Vec::new()),
        bookmarks: Vec::new(),
        tags: Vec::new(),
        all: false,
        tracked: false,
        deleted: false,
        allow_empty_description: false,
        allow_private: false,
        allow_conflicts: false,
        revisions: Vec::new(),
        changes: Vec::new(),
        named: Vec::new(),
        dry_run: true,
        options: Vec::new(),
    };
}

/// Story 9.20: the push outcome's types — every public type, field and variant named by its
/// public path.
#[test]
fn story_9_20_push_outcome_resolves() {
    let refusal = zanshin_jj::PushRefusal {
        message: String::new(),
        hint: None,
    };
    let row = zanshin_jj::PushRef {
        kind: zanshin_jj::PushRefKind::Tag,
        name: String::new(),
        before: None,
        after: None,
        action: None,
        path: zanshin_jj::PushPath::Skip,
        refusal: Some(refusal.clone()),
        explicit_refusal: Some(refusal),
        rejection: Some(zanshin_jj::PushCommitRejection {
            commit_id: String::new(),
            reasons: Vec::new(),
            message: String::new(),
            hints: Vec::new(),
        }),
        status: Some(zanshin_jj::PushRefStatus::Unexported),
        status_reason: None,
    };
    for path in [
        zanshin_jj::PushPath::Push,
        zanshin_jj::PushPath::Skip,
        zanshin_jj::PushPath::Abort,
    ] {
        match path {
            zanshin_jj::PushPath::Push | zanshin_jj::PushPath::Skip | zanshin_jj::PushPath::Abort => {}
        }
    }
    for status in [
        zanshin_jj::PushRefStatus::Pushed,
        zanshin_jj::PushRefStatus::LeaseRejected,
        zanshin_jj::PushRefStatus::RemoteRejected,
        zanshin_jj::PushRefStatus::Unexported,
    ] {
        match status {
            zanshin_jj::PushRefStatus::Pushed
            | zanshin_jj::PushRefStatus::LeaseRejected
            | zanshin_jj::PushRefStatus::RemoteRejected
            | zanshin_jj::PushRefStatus::Unexported => {}
        }
    }
    for kind in [
        zanshin_jj::PushFailureKind::RefRefused,
        zanshin_jj::PushFailureKind::CommitRejected,
        zanshin_jj::PushFailureKind::SomeRefsFailed,
        zanshin_jj::PushFailureKind::PushError,
        zanshin_jj::PushFailureKind::Cancelled,
    ] {
        match kind {
            zanshin_jj::PushFailureKind::RefRefused
            | zanshin_jj::PushFailureKind::CommitRejected
            | zanshin_jj::PushFailureKind::SomeRefsFailed
            | zanshin_jj::PushFailureKind::PushError
            | zanshin_jj::PushFailureKind::Cancelled => {}
        }
    }
    let _ = zanshin_jj::GitPushOutcome {
        remotes: vec![zanshin_jj::PushRemote {
            name: String::new(),
            refs: vec![row],
            already_matches: vec![zanshin_jj::PushRefName {
                kind: zanshin_jj::PushRefKind::Bookmark,
                name: String::new(),
            }],
            finished: false,
            error: None,
        }],
        created_bookmarks: vec![zanshin_jj::PushCreatedBookmark {
            name: String::new(),
            change_id: String::new(),
        }],
        hints: Vec::new(),
        signing: Some(zanshin_jj::PushSigning {
            updated_signatures: 0,
            rebased_descendants: 0,
        }),
        nothing_changed: false,
        dry_run: false,
        recorded: false,
        description: None,
        new_op_id: String::new(),
        failure: Some(zanshin_jj::PushFailure {
            kind: zanshin_jj::PushFailureKind::PushError,
            message: String::new(),
            hint: None,
        }),
    };
}

/// Story 9.52: the cancel tokens of the network verbs — every public item named by its path.
#[test]
fn story_9_52_cancel_tokens_resolve() {
    _ = zanshin_jj::cancel::register as fn(u64);
    _ = zanshin_jj::cancel::attach as fn(u64) -> Option<zanshin_jj::cancel::CancelGuard>;
    _ = zanshin_jj::cancel::cancel as fn(u64);
    _ = zanshin_jj::cancel::CancelGuard::is_cancelled as fn(&zanshin_jj::cancel::CancelGuard) -> bool;
    _ = zanshin_jj::cancel::CancelGuard::checkpoint
        as fn(&zanshin_jj::cancel::CancelGuard) -> Result<(), zanshin_jj::cancel::Cancelled>;
    _ = zanshin_jj::cancel::CancelGuard::env_pair
        as fn(&zanshin_jj::cancel::CancelGuard) -> (std::ffi::OsString, std::ffi::OsString);
    assert_eq!(zanshin_jj::cancel::CANCEL_TOKEN_VAR, "ZANSHIN_CANCEL_TOKEN");
    _ = zanshin_jj::MutateError::Cancelled;
    _ = zanshin_jj::RepoError::Cancelled;
    _ = zanshin_jj::PushFailureKind::Cancelled;
}

/// Story 9.24: the remote-change poll — its three types, every variant and field, and
/// `Repo::remote_changes`' full signature.
#[test]
fn remote_changes_surface_resolves() {
    type _RemoteRefChange = zanshin_jj::RemoteRefChange;
    type _RemoteRefKind = zanshin_jj::RemoteRefKind;
    type _RemoteRefChangeKind = zanshin_jj::RemoteRefChangeKind;

    _ = zanshin_jj::Repo::remote_changes
        as fn(
            &mut zanshin_jj::Repo,
            &str,
            Option<&zanshin_jj::cancel::CancelGuard>,
        ) -> Result<Vec<zanshin_jj::RemoteRefChange>, zanshin_jj::MutateError>;
    let change = zanshin_jj::RemoteRefChange {
        kind: zanshin_jj::RemoteRefKind::Bookmark,
        name: "main".to_owned(),
        change: zanshin_jj::RemoteRefChangeKind::Moved,
        old_commit_ids: vec![zanshin_jj::CommitId(String::new())],
        new_commit_id: None,
    };
    let zanshin_jj::RemoteRefChange {
        kind,
        name,
        change,
        old_commit_ids,
        new_commit_id,
    } = change;
    assert_eq!(
        (kind, name.as_str(), change),
        (
            zanshin_jj::RemoteRefKind::Bookmark,
            "main",
            zanshin_jj::RemoteRefChangeKind::Moved
        )
    );
    assert_eq!((old_commit_ids.len(), new_commit_id), (1, None));
    _ = zanshin_jj::RemoteRefKind::Tag;
    _ = zanshin_jj::RemoteRefChangeKind::New;
    _ = zanshin_jj::RemoteRefChangeKind::Deleted;
}
