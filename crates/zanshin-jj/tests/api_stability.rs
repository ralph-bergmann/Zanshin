// SPDX-License-Identifier: MIT

//! API surface stability test (AC-8 / FR-JJ-16).
//!
//! Names every public item by its `zanshin_jj::` path so the test ONLY compiles
//! when the full re-export surface (AC-1) resolves. No `jj_lib` import — a future
//! `jj_lib` type leaking into a public position would be detectable here.
//!
//! The test also asserts the leak-free invariant structurally: error variants are
//! constructed as `Backend(String)` / `JjLibError(String)`, never as a `jj_lib` type.

// --- Type-path aliases: one alias per public type (61 types; the AC-1 table's 30 plus the
// --- types later stories added — CommitMeta/CommitRef (4.8), ConfigError/LogDefaults (4.9),
// --- MutationResult/MutateError (6.1), ProgressEvent (6.4a), Tag/TagKind/WorkingCopy/
// --- ViewError (9.2), AbsorbResult/SkippedPath (9.3), FileEntry/FileType/ShownFile/
// --- FileContents/AnnotationLine/SearchMatch/FileError (9.4), GitImportResult/GitRefUpdate/
// --- GitRefUpdateKind/GitExportResult/GitExportFailure (9.5), ShowEntry/EvologEntry/
// --- InterdiffView/CommitViewError (9.6), WorkspaceEntry/WorkspaceError (9.7)). Story 9.8
// --- adds NO public type — both bookmark mutations reuse MutationResult/MutateError — so the
// --- count moved only when follow-up F turned `interdiff`'s bare Vec into InterdiffView
// --- ---------------------------------------------------------------------------

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
        identity_missing: Some(zanshin_jj::IdentityMissing {
            name: true,
            email: false,
        }),
        finish: Some(sample_finish_facts()),
    }
}

/// Names every `FinishFacts` field by its public path (Story 9.26).
fn sample_finish_facts() -> zanshin_jj::FinishFacts {
    zanshin_jj::FinishFacts {
        working_copy_became_immutable: false,
        git_head_update_failed: false,
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
    let unresolved = zanshin_jj::WorkspaceError::PathUnresolved {
        name: "moved".to_owned(),
        reason: "No such file or directory (os error 2)".to_owned(),
    };
    assert_eq!(
        unresolved.to_string(),
        "cannot resolve absolute workspace path for moved: No such file or directory (os error 2)"
    );
    assert_eq!(
        zanshin_jj::WorkspaceError::Backend("boom".to_owned()).to_string(),
        "jj-lib error: boom"
    );

    _ = sample_workspace_entry();

    _ = zanshin_jj::Repo::list_workspaces
        as fn(&mut zanshin_jj::Repo) -> Result<Vec<zanshin_jj::WorkspaceEntry>, zanshin_jj::WorkspaceError>;
    // `workspace root` is in the CLI's no-snapshot set, so both stay `&self` (Story 9.26).
    _ = zanshin_jj::Repo::resolve_workspace_root
        as fn(&zanshin_jj::Repo, Option<&str>) -> Result<std::path::PathBuf, zanshin_jj::WorkspaceError>;
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
        working_copy_immutable_new_commit: false,
        git_refs: Some(sample_git_import_result()),
        git_refs_rebased: 0,
        jjconflict_files_present: false,
        finish: Some(sample_finish_facts()),
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
        as fn(&mut zanshin_jj::Repo) -> Result<Vec<zanshin_jj::Bookmark>, zanshin_jj::BookmarkError>;
    _ = zanshin_jj::Repo::list_remotes
        as fn(&mut zanshin_jj::Repo) -> Result<Vec<zanshin_jj::Remote>, zanshin_jj::RemoteError>;
    // A config read with no CLI verb behind it: no snapshot, still `&self`.
    _ = zanshin_jj::Repo::log_defaults
        as fn(&zanshin_jj::Repo) -> Result<zanshin_jj::LogDefaults, zanshin_jj::ConfigError>;
}
