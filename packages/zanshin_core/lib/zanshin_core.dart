// SPDX-License-Identifier: MIT

/// Public API of the Zanshin Rust↔Dart bridge.
///
/// The app (and any other consumer) imports `package:zanshin_core/zanshin_core.dart`
/// rather than reaching into `src/` directly. Internal files stay under `src/`.
library;

export 'src/environment/login_shell.dart' show LoginShellEnvironmentResult, adoptLoginShellEnvironment;
export 'src/ffi/bookmarks.dart'
    show Bookmark, BookmarkKind, BookmarkSortKey, LocalBookmark, RefDistance, RemoteBookmark;
export 'src/ffi/change.dart' show ConflictState;
export 'src/ffi/commit_views.dart' show ChangeIdRef, CommitIdRef, RevisionRef;
export 'src/ffi/config.dart'
    show
        ConfigEntry,
        ConfigFileTarget,
        ConfigFileText,
        ConfigFileWriteResult,
        ConfigGcFailure,
        ConfigGcResult,
        ConfigGetResult,
        ConfigScope,
        ConfigScopeTarget,
        ConfigSetResult,
        ConfigTarget,
        ConfigUnsetResult,
        ConfigValueSource,
        MissingRepoConfig,
        WorkingCopyAuthor;
export 'src/ffi/diagnostics.dart' show Diagnostics, GetDiagnostics, ZanshinDiagnosticsModule;
export 'src/ffi/drop_actions.dart'
    show
        ActionOutcome,
        ActionRefusal,
        ActionStatus,
        BookmarkDropSource,
        ChangeActions,
        ChangeDropSource,
        DropAction,
        DropActions,
        DropLocation,
        DropSource,
        DropVerb,
        SelectionDropSource;
export 'src/ffi/fetch.dart'
    show
        AllFetchRemotes,
        DefaultFetchRefs,
        DefaultFetchRemotes,
        FetchRefs,
        FetchRemotes,
        GitFetchResult,
        NamedFetchRemotes,
        PatternFetchRefs,
        TrackedFetchRefs;
export 'src/ffi/file_ops.dart' show FileNotAutoTracked, FileTooLarge, SnapshotStats, UntrackedPath, UntrackedReason;
export 'src/ffi/graph.dart' show GraphTopologyView, TopologyRef, TopologyRefKind;
export 'src/ffi/log_forwarder.dart' show forwardLogRecord, initLogForwarding;
export 'src/ffi/metaedit_duplicate_fix.dart' show FixResult, FixToolStderr;
export 'src/ffi/movement.dart' show MovementDirection, MovementTarget, MovementTargets;
export 'src/ffi/op_log.dart'
    show
        OpAbandonResult,
        OpChangedCommit,
        OpCommitsDiff,
        OpDiff,
        OpDiffResult,
        OpIntegrateResult,
        OpRefChange,
        OpRefTarget,
        OpRemoteRefChange,
        OpShow,
        OpWorkingCopyChange,
        Operation,
        OperationTag,
        RestoreWhat;
export 'src/ffi/precondition.dart' show Precondition;
export 'src/ffi/push.dart'
    show
        GitPushResult,
        PushCommitRejection,
        PushCreatedBookmark,
        PushFailure,
        PushFailureKind,
        PushPath,
        PushRef,
        PushRefKind,
        PushRefName,
        PushRefStatus,
        PushRefusal,
        PushRemote,
        PushSigning;
export 'src/ffi/rebase.dart' show AbandonAction, ArrangeAction, KeepAction, SwapDownAction, SwapUpAction;
export 'src/ffi/remotes.dart' show RemoteRefChange, RemoteRefChangeKind, RemoteRefKind;
export 'src/ffi/repo.dart' show ObjectHash;
export 'src/ffi/repo_detect.dart' show RepoDetectResult, RepoKind;
export 'src/ffi/select_tree.dart' show FileSelection, HunkKey, SelectedTree, SourceTree, TreeSelection;
export 'src/ffi/squash_split.dart' show SplitResult, SquashPlan;
export 'src/ffi/status.dart' show WorkingCopyStatus;
export 'src/ffi/warning.dart' show WarnedList, ZanshinWarning, ZanshinWarningCode;
export 'src/ffi/workspace.dart'
    show CheckoutStats, SparseInheritance, StaleRecovery, StaleRecoveryOutcome, WorkspaceAddResult, WorkspaceRootResult;
export 'src/ffi/zanshin_version.dart' show ZanshinFfiModule, ZanshinFfiVersion;
export 'src/worker/events.dart'
    show OpHeadsChangedEvent, ProgressEvent, RepoEvent, WatchErrorEvent, WorkingCopyHeartbeatEvent;
export 'src/worker/handle.dart' show CreatedRepoHandle, OpenedRepoHandle, RepoHandle;
export 'src/worker/isolate.dart' show ZanshinWorker;
export 'src/worker/network_operation.dart' show NetworkOperation;
export 'src/worker/responses.dart' show ZanshinFfiException;
export 'src/worker/worker_module.dart' show WorkerModule;
