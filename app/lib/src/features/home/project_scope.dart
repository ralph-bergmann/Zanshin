// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_core/zanshin_core.dart' show Bookmark;
import 'package:zanshin_settings/zanshin_settings.dart' show RemotePollSetting, SettingsStore;

import '../bookmarks/bookmark_list_model.dart';
import '../graph/active_graph.dart';
import '../graph/graph_inspector.dart';
import '../graph/graph_ports.dart';
import '../graph/graph_preferences.dart';
import '../graph/graph_search_controller.dart';
import '../graph/graph_search_store.dart';
import '../graph/graph_stack_store.dart';
import '../graph/graph_toasts.dart';
import '../graph/graph_view_model.dart';
import '../graph/immutable_reasons.dart';
import '../graph/inspector_viewed_store.dart';
import '../graph/view_state_cleanup.dart';
import '../projects/project_repos.dart' show ProjectRepo;
import '../projects/project_session.dart';
import '../projects/projects_environment.dart';
import '../settings/immutable_heads.dart';
import '../shell/shell_toast.dart';
import '../sync/remote_sync.dart';
import '../sync/sync_model.dart';
import '../undo_timeline/operation_changes.dart';
import '../undo_timeline/undo_timeline_model.dart';

/// Marks the open repository's root folder in the project graph.
const projectRoot = Qualifier(#projectRoot);

/// Opens the graph source of a repository. The app binds [RepoGraphSource]; tests bind a scripted source.
typedef GraphSourceOf = GraphSource Function(ProjectRepo repo);

/// Opens the remote sync of the repository at `root`. The app binds [repoRemoteSyncOf]; tests bind a fake.
typedef RemoteSyncOf = RemoteSync Function(ProjectRepo repo, String root);

/// The app's [RemoteSyncOf]: jj's Git verbs over the repository's handle, the config read through [environment].
RemoteSyncOf repoRemoteSyncOf(ProjectsEnvironment environment) =>
    (repo, root) => RepoRemoteSync(
      () => repo.handle,
      config: (name) async =>
          effectiveConfigEntry(await environment.configList(name: name, workspaceRoot: root))?.value,
    );

/// Provides the objects that exist once per open repository. Each is a `@singleton` of one [ProjectComponent], so a
/// project switch gets a new set.
@module
class ProjectModule {
  /// Provides the graph's view model, which [graphPreferences] starts.
  @provides
  @singleton
  GraphViewModel graphViewModel() => GraphViewModel();

  /// Provides what the graph reads from the repository.
  @provides
  @singleton
  GraphSource graphSource(GraphSourceOf sourceOf, ProjectRepo repo) => sourceOf(repo);

  /// Provides the graph search, its state stored per repository.
  @provides
  @singleton
  GraphSearchController graphSearch(
    GraphViewModel model,
    GraphSource source,
    ProjectRepo repo,
    ProjectsEnvironment environment,
    SettingsStore settings,
    @projectRoot String root,
  ) => GraphSearchController(
    model: model,
    source: RepoGraphSearchSource(
      repo,
      userEmail: () async => (await environment.identity(workspaceRoot: root)).email,
      content: source.content,
    ),
    store: ProjectSearchStore(settings, root),
    settings: settings,
  );

  /// Provides the repository's stack toggles, shared by the graph and the view state cleanup.
  @provides
  @singleton
  GraphStackStore stackStore(SettingsStore settings, @projectRoot String root) => ProjectStackStore(settings, root);

  /// Provides the repository's Viewed marks, shared by the inspector and the view state cleanup.
  @provides
  @singleton
  InspectorViewedStore viewedStore(SettingsStore settings, @projectRoot String root) =>
      ProjectViewedStore(settings, root);

  /// Provides the View preferences and starts [model]: its first request needs the stored layout and the search's
  /// revset.
  @provides
  @singleton
  GraphPreferences graphPreferences(
    GraphViewModel model,
    GraphSource source,
    GraphSearchController search,
    ProjectRepo repo,
    SettingsStore settings,
    GraphStackStore stacks,
  ) => GraphPreferences(settings)
    ..init(
      model,
      source,
      actions: RepoGraphActions(repo),
      drops: RepoGraphDrops(repo),
      stackStore: stacks,
      revset: search.revset,
    );

  /// Provides the inspector of the graph's selection.
  @provides
  @singleton
  InspectorViewModel inspector(
    GraphViewModel model,
    ProjectRepo repo,
    SettingsStore settings,
    InspectorViewedStore viewed,
    ProjectsEnvironment environment,
  ) => InspectorViewModel(
    graph: model,
    details: RepoGraphDetails(repo, environment),
    viewed: viewed,
    settings: settings,
  );

  /// Provides the pass that drops the view state of changes gone from the repository, once the first layout lands.
  @provides
  @singleton
  ViewStateCleanup viewStateCleanup(
    GraphViewModel model,
    GraphStackStore stacks,
    InspectorViewedStore viewed,
    ProjectRepo repo,
  ) => ViewStateCleanup(
    graph: model,
    stacks: stacks,
    viewed: viewed,
    find: (operationId, expression, {required limit, required shortPrefixes}) =>
        repo.handle.findChanges(operationId, expression, limit: limit, shortPrefixes: shortPrefixes),
  );

  /// Provides why a change is immutable, for the peek and the inspector.
  @provides
  @singleton
  ImmutableReasons immutableReasons(ProjectRepo repo, ProjectsEnvironment environment, @projectRoot String root) =>
      ImmutableReasons(
        readAlias: () async => tomlStringValue(
          effectiveConfigEntry(await environment.configList(name: immutableHeadsKey, workspaceRoot: root))?.value,
        ),
        counts: (operationId, expressions, {required cap}) =>
            repo.handle.revsetCounts(operationId, expressions, cap: cap),
      );

  /// Provides the graph's toasts in the window's queue.
  @provides
  @singleton
  GraphToasts graphToasts(GraphViewModel model, ShellToasts toasts) => GraphToasts(model, toasts);

  /// Provides Fetch, Push and the remote-change poll.
  @provides
  @singleton
  SyncModel syncModel(
    GraphViewModel model,
    RemoteSyncOf syncOf,
    ProjectRepo repo,
    ShellToasts toasts,
    ProjectSession session,
    @projectRoot String root,
  ) => SyncModel(
    sync: syncOf(repo, root),
    graph: model,
    toasts: toasts,
    pollSetting: () => session.current?.remotePoll ?? RemotePollSetting.fifteenMinutes,
    pollChanged: session,
    changeTarget: () => switch (model.actionTarget) {
      final String id => (id: id, rev: targetName(model, id)),
      null => null,
    },
    syncing: session.syncing,
  );

  /// Provides the rail's bookmark list, its picks going through [search].
  @provides
  @singleton
  BookmarkListModel bookmarkList(ProjectRepo repo, GraphSearchController search) =>
      BookmarkListModel(RepoBookmarkListSource(repo), search: search);

  /// Provides the rail's Undo Timeline.
  @provides
  @singleton
  UndoTimelineModel undoTimeline(ProjectRepo repo) => UndoTimelineModel(RepoUndoTimelineSource(repo));

  /// Provides what the Undo Timeline's Show changes reads.
  @provides
  OperationChangesSource operationChangesSource(ProjectRepo repo, ProjectsEnvironment environment) =>
      RepoOperationChangesSource(repo, environment: environment);

  /// Provides the view Show changes opens. A provider, because inject.dart finds a generated factory only from a
  /// provider's parameter or a component getter, not from an `@inject` constructor.
  @provides
  OperationChangesOf operationChanges(OperationChangesModelFactory factory) => factory.create;
}

/// The objects of one open repository. The project window's graph host gets one from a [ProjectComponent] per
/// repository and disposes it, because inject.dart disposes nothing.
@inject
@singleton
class ProjectScope {
  /// The scope over the repository's objects. [preferences] comes right after [model] because it starts the model.
  ProjectScope(
    this.model,
    this.preferences,
    this._cleanup,
    this.search,
    this.inspector,
    this.reasons,
    this._toasts,
    this.sync,
    this.bookmarks,
    this.undoTimeline,
    this.operationChanges,
    this._environment,
    this._repo,
  ) {
    // A config write in Settings changes the alias without an operation: the reasons are read again.
    _environment.configWrites.addListener(reasons.invalidate);
    // It may change `diff.color-words.*`: the open diff reads again.
    _environment.configWrites.addListener(inspector.configChanged);
    // Once each time Zanshin becomes the active app.
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(sync.poll()));
  }

  /// The graph's view model.
  final GraphViewModel model;

  /// The graph's View preferences.
  final GraphPreferences preferences;

  /// The graph search.
  final GraphSearchController search;

  /// The inspector of the graph's selection.
  final InspectorViewModel inspector;

  /// Why a change is immutable.
  final ImmutableReasons reasons;

  /// Fetch, Push and the remote-change poll.
  final SyncModel sync;

  /// The rail's bookmark list.
  final BookmarkListModel bookmarks;

  /// The rail's Undo Timeline.
  final UndoTimelineModel undoTimeline;

  /// Builds the Undo Timeline's Show changes view of one operation.
  final OperationChangesOf operationChanges;

  final ViewStateCleanup _cleanup;
  final GraphToasts _toasts;
  final ProjectsEnvironment _environment;
  final ProjectRepo _repo;
  late final AppLifecycleListener _lifecycle;

  /// The bookmark popover's `jj bookmark list --all-remotes`.
  Future<List<Bookmark>> remoteBookmarks() => _repo.handle.bookmarks(allRemotes: true);

  /// What the menu bar, Settings and jj log Configurations use of this graph.
  late final binding = GraphMenuBinding(
    model: model,
    preferences: preferences,
    search: search,
    focusSearch: search.focusField,
    squash: inspector.squash,
    sync: sync,
  );

  /// Disposes the objects, those that read the graph before the graph.
  void dispose() {
    _lifecycle.dispose();
    undoTimeline.dispose();
    bookmarks.dispose();
    sync.dispose();
    _environment.configWrites.removeListener(reasons.invalidate);
    _environment.configWrites.removeListener(inspector.configChanged);
    _toasts.dispose();
    _cleanup.dispose();
    inspector.dispose();
    search.dispose();
    preferences.dispose();
    model.dispose();
  }
}

/// The graph of one open repository: every `@singleton` in it exists once per [ProjectComponentFactory.create].
@Subcomponent([ProjectModule])
abstract class ProjectComponent {
  /// The repository's objects.
  ProjectScope get scope;
}

/// Creates the graph of one open repository.
@subcomponentFactory
abstract class ProjectComponentFactory {
  /// The graph of [repo], open at [root], its toasts in the project window's [toasts].
  ProjectComponent create(ProjectRepo repo, @projectRoot String root, ShellToasts toasts);
}
