// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show Bookmark;
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;

import '../graph/graph_controls.dart';
import '../graph/graph_inspector.dart';
import '../graph/graph_ports.dart';
import '../graph/graph_preferences.dart';
import '../graph/graph_search_controller.dart';
import '../graph/graph_search_store.dart';
import '../graph/graph_stack_store.dart';
import '../graph/graph_toasts.dart';
import '../graph/graph_view.dart';
import '../graph/graph_view_model.dart';
import '../projects/project_repos.dart' show ProjectRepo;
import '../projects/project_session.dart';
import '../projects/projects_environment.dart';
import '../shell/app_menu.dart';
import '../shell/shell_toast.dart';

/// What the project window's shell shows of the graph (Story 10.12): the slot widgets, all null without an open
/// repository but [reload], which then shows disabled.
@immutable
class ProjectGraphSlots {
  const ProjectGraphSlots._({
    required this.reload,
    this.model,
    this.search,
    this.graph,
    this.view,
    this.newChange,
    this.inspector,
    this.atPill,
    this.staleNotice,
  });

  /// The graph's view model.
  final GraphViewModel? model;

  /// The graph search.
  final GraphSearchController? search;

  /// The graph itself.
  final Widget? graph;

  /// VIEW: the graph's controls.
  final Widget? view;

  /// ACTION's sync island: Reload.
  final Widget reload;

  /// ACTION: New change.
  final Widget? newChange;

  /// The inspector, while a change is selected.
  final Widget? inspector;

  /// The @ pill.
  final Widget? atPill;

  /// The stale notice, while the working copy is stale.
  final Widget? staleNotice;
}

/// The project window's graph (Story 10.12): one set of graph objects per open [ProjectRepo] of [session] — the
/// [GraphViewModel] over [sourceOf]'s source (the worker's layout and content), its [GraphPreferences] in [settings],
/// the search, the inspector and the toasts in [toasts] — recreated when the repository changes and disposed on
/// unmount. It publishes the graph to [appMenu] (View, Change, Go, Undo and Find) and clears that binding, if it is
/// still its own, before it disposes the model.
class ProjectGraphHost extends StatefulWidget {
  /// The graph of [session]'s open repository.
  const ProjectGraphHost({
    required this.session,
    required this.settings,
    required this.environment,
    required this.appMenu,
    required this.toasts,
    required this.builder,
    this.sourceOf = RepoGraphSource.new,
    super.key,
  });

  /// The open project.
  final ProjectSession session;

  /// Where the View preferences, the stack toggles and the search state persist.
  final SettingsStore settings;

  /// Reads the search's `user.email`.
  final ProjectsEnvironment environment;

  /// The menu bar the graph is published to.
  final AppMenuModel appMenu;

  /// The window's toast queue.
  final ShellToasts toasts;

  /// The graph's source of an open repository; tests pass a scripted one.
  @visibleForTesting
  final GraphSource Function(ProjectRepo repo) sourceOf;

  /// Builds the window around the graph's slots; it rebuilds when the model or the preferences change.
  final Widget Function(BuildContext context, ProjectGraphSlots slots) builder;

  @override
  State<ProjectGraphHost> createState() => _ProjectGraphHostState();
}

/// The graph objects of one repository.
class _Graph {
  _Graph(ProjectGraphHost host, ProjectRepo repo, String root) {
    final GraphSource source = host.sourceOf(repo);
    search = GraphSearchController(
      model: model,
      source: RepoGraphSearchSource(
        repo,
        userEmail: () async => (await host.environment.identity(workspaceRoot: root)).email,
        content: source.content,
      ),
      store: ProjectSearchStore(host.settings, root),
      settings: host.settings,
    );
    preferences = GraphPreferences(host.settings)
      ..init(
        model,
        source,
        actions: RepoGraphActions(repo),
        stackStore: ProjectStackStore(host.settings, root),
        revset: search.revset,
      );
    inspector = InspectorViewModel(graph: model, details: RepoGraphDetails(repo));
    bookmarks = () => repo.handle.bookmarks(allRemotes: true);
    toasts = GraphToasts(model, host.toasts);
    binding = GraphMenuBinding(
      model: model,
      preferences: preferences,
      search: search,
      focusSearch: () => search.focusField(),
    );
  }

  final model = GraphViewModel();
  late final GraphSearchController search;
  late final GraphPreferences preferences;
  late final InspectorViewModel inspector;

  /// The bookmark popover's `jj bookmark list --all-remotes`.
  late final Future<List<Bookmark>> Function() bookmarks;
  late final GraphToasts toasts;
  late final GraphMenuBinding binding;

  void dispose() {
    toasts.dispose();
    inspector.dispose();
    search.dispose();
    preferences.dispose();
    model.dispose();
  }
}

class _ProjectGraphHostState extends State<ProjectGraphHost> {
  ProjectRepo? _repo;
  String? _root;
  _Graph? _graph;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(ProjectGraphHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_sync);
      widget.session.addListener(_sync);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_sync);
    _drop();
    super.dispose();
  }

  void _sync() {
    final ProjectRepo? repo = widget.session.repo;
    final String? root = widget.session.current?.path;
    if (identical(repo, _repo) && root == _root) {
      return;
    }
    _drop();
    _repo = repo;
    _root = root;
    if (repo != null && root != null) {
      final _Graph graph = _graph = _Graph(widget, repo, root);
      widget.appMenu.graph.value = graph.binding;
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Unbinds the menu (only its own binding) before the model it names is disposed.
  void _drop() {
    final _Graph? graph = _graph;
    if (graph == null) {
      return;
    }
    if (identical(widget.appMenu.graph.value, graph.binding)) {
      widget.appMenu.graph.value = null;
    }
    graph.dispose();
    _graph = null;
  }

  void _reload() {
    widget.session.refresh();
    _graph?.model.reload();
  }

  @override
  Widget build(BuildContext context) {
    final _Graph? graph = _graph;
    // One ListenableBuilder either way, so nothing below remounts when a project opens or closes.
    if (graph == null) {
      return ListenableBuilder(
        listenable: Listenable.merge(const <Listenable>[]),
        builder: (context, _) =>
            widget.builder(context, const ProjectGraphSlots._(reload: GraphReloadIsland(onPressed: null))),
      );
    }
    final GraphViewModel model = graph.model;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[model, graph.preferences]),
      builder: (context, _) => widget.builder(
        context,
        ProjectGraphSlots._(
          model: model,
          search: graph.search,
          // Keyed by the graph set, so a project switch mounts fresh states (no old search text, selection or scroll).
          graph: GraphView(
            key: ObjectKey(graph),
            model: model,
            options: graph.preferences.options,
            inspectorModel: graph.inspector,
            bookmarks: graph.bookmarks,
            search: graph.search,
          ),
          view: GraphViewControls(
            key: ObjectKey(graph),
            model: model,
            preferences: graph.preferences,
            search: graph.search,
          ),
          reload: GraphReloadIsland(onPressed: _reload),
          newChange: NewChangeButton(model: model),
          inspector: GraphView.inspector(graph.inspector),
          atPill: GraphView.atPill(model),
          staleNotice: GraphView.staleNotice(model),
        ),
      ),
    );
  }
}
