// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../bookmarks/bookmark_list_model.dart' show RefKind;
import '../bookmarks/ref_delete.dart';
import '../graph/active_graph.dart';
import '../graph/graph_controls.dart';
import '../graph/graph_view.dart';
import '../graph/graph_view_model.dart';
import '../graph/immutable_reasons.dart';
import '../projects/project_repos.dart' show ProjectRepo;
import '../projects/project_session.dart';
import '../shell/shell_toast.dart';
import '../sync/push_sheet.dart';
import '../sync/sync_island.dart';
import 'project_scope.dart';

/// What the project window's shell shows of the graph (Story 10.12): the slot widgets, all null without an open
/// repository but [sync], which then shows disabled.
@immutable
class ProjectGraphSlots {
  const ProjectGraphSlots._({
    required this.sync,
    this.scope,
    this.graph,
    this.view,
    this.newChange,
    this.inspector,
    this.minimap,
    this.atPill,
    this.staleNotice,
  });

  /// The open repository's objects.
  final ProjectScope? scope;

  /// The graph itself.
  final Widget? graph;

  /// VIEW: the graph's controls.
  final Widget? view;

  /// ACTION's sync island: Reload, Fetch and Push (Story 11.8).
  final Widget sync;

  /// ACTION: New change.
  final Widget? newChange;

  /// The inspector, while a change is selected.
  final Widget? inspector;

  /// The minimap, while the View › Show Minimap preference is on (Story 10.16).
  final Widget? minimap;

  /// The @ pill.
  final Widget? atPill;

  /// The stale notice, while the working copy is stale.
  final Widget? staleNotice;
}

/// The project window's graph (Story 10.12): one [ProjectScope] per open [ProjectRepo] of [session], its toasts in
/// [toasts], recreated when the repository changes and disposed on unmount. It publishes the graph to [activeGraph]
/// (the menu bar's View, Change, Go, Undo and Find) and clears that binding, if it is still its own, before it disposes
/// the scope.
class ProjectGraphHost extends StatefulWidget {
  /// The graph of [session]'s open repository.
  const ProjectGraphHost({
    required this.session,
    required this.scopes,
    required this.activeGraph,
    required this.toasts,
    required this.builder,
    super.key,
  });

  /// The open project.
  final ProjectSession session;

  /// Creates the graph of an open repository.
  final ProjectComponentFactory scopes;

  /// The project window's graph, which this host publishes to.
  final ActiveGraph activeGraph;

  /// The window's toast queue.
  final ShellToasts toasts;

  /// Builds the window around the graph's slots; it rebuilds when the model or the preferences change.
  final Widget Function(BuildContext context, ProjectGraphSlots slots) builder;

  @override
  State<ProjectGraphHost> createState() => _ProjectGraphHostState();
}

class _ProjectGraphHostState extends State<ProjectGraphHost> {
  ProjectRepo? _repo;
  String? _root;
  ProjectScope? _scope;

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
      final ProjectScope scope = _scope = widget.scopes.create(repo, root, widget.toasts).scope;
      widget.activeGraph.value = scope.binding;
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Unbinds the menu (only its own binding) before the model it names is disposed.
  void _drop() {
    final ProjectScope? scope = _scope;
    if (scope == null) {
      return;
    }
    if (identical(widget.activeGraph.value, scope.binding)) {
      widget.activeGraph.value = null;
    }
    scope.dispose();
    _scope = null;
  }

  void _reload() {
    widget.session.refresh();
    _scope?.model.reload();
    unawaited(_scope?.sync.reloadRemotes());
  }

  @override
  Widget build(BuildContext context) {
    final ProjectScope? scope = _scope;
    // One ListenableBuilder either way, so nothing below remounts when a project opens or closes.
    if (scope == null) {
      return ListenableBuilder(
        listenable: Listenable.merge(const <Listenable>[]),
        builder: (context, _) => ImmutableReasonScope(
          reasons: null,
          child: widget.builder(context, const ProjectGraphSlots._(sync: SyncIsland(onReload: null))),
        ),
      );
    }
    final GraphViewModel model = scope.model;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[model, scope.preferences]),
      builder: (context, _) => ImmutableReasonScope(
        reasons: scope.reasons,
        child: widget.builder(
          context,
          ProjectGraphSlots._(
            scope: scope,
            // Keyed by the scope, so a project switch mounts fresh states (no old search text, selection or scroll).
            // The Push sheet mounts from the graph slot: inside the shell's scope (it holds calm), outside any glass.
            graph: RefDeleteHost(
              flow: scope.refDelete,
              child: PushSheetHost(
                sync: scope.sync,
                child: GraphView(
                  key: ObjectKey(scope),
                  model: model,
                  options: scope.preferences.options,
                  inspectorModel: scope.inspector,
                  bookmarks: scope.remoteBookmarks,
                  deleteBookmark: (name, rows) =>
                      scope.refDelete.delete(RefDeleteRequest.of(RefKind.bookmark, name, rows)),
                  search: scope.search,
                ),
              ),
            ),
            view: GraphViewControls(
              key: ObjectKey(scope),
              model: model,
              preferences: scope.preferences,
              search: scope.search,
            ),
            sync: SyncIsland(onReload: _reload, sync: scope.sync),
            newChange: NewChangeButton(model: model),
            inspector: GraphView.inspector(scope.inspector),
            minimap: scope.preferences.showMinimap ? GraphView.minimap(model, key: ObjectKey(scope)) : null,
            atPill: GraphView.atPill(model),
            staleNotice: GraphView.staleNotice(model),
          ),
        ),
      ),
    );
  }
}
