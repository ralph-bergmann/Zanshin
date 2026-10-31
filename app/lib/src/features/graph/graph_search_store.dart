// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:zanshin_settings/zanshin_settings.dart';

import 'graph_search_model.dart';

/// Where one repository's graph search state persists (Story 10.21 items 1 and 6): what the graph shows and Recent.
abstract interface class GraphSearchStore {
  /// The stored view; the default search when none.
  GraphShownView loadView();

  /// The stored Recent entries, newest first.
  List<GraphRecent> loadRecent();

  /// Stores [view]; a failed write keeps it for the session.
  void saveView(GraphShownView view);

  /// Stores [recent]; a failed write keeps it for the session.
  void saveRecent(List<GraphRecent> recent);
}

/// The search state on the [ProjectEntry] at [path] (`graphView`, `recentSearches`), as 10.17's stack toggles: a path
/// not in the registry keeps it in memory for the session; a failed write is swallowed.
class ProjectSearchStore implements GraphSearchStore {
  /// The search state of the repository at [path] in [_store].
  ProjectSearchStore(this._store, this.path);

  final SettingsStore _store;

  /// The repository's root, the registry key.
  final String path;

  final _memory = MemoryGraphSearchStore();

  ProjectEntry? get _entry => _store.value.projects.projects.where((p) => p.path == path).firstOrNull;

  @override
  GraphShownView loadView() => switch (_entry) {
    final ProjectEntry entry => GraphShownView.decode(entry.graphView),
    null => _memory.loadView(),
  };

  @override
  List<GraphRecent> loadRecent() => switch (_entry) {
    final ProjectEntry entry => <GraphRecent>[
      for (final String text in entry.recentSearches) ?GraphRecent.decode(text),
    ],
    null => _memory.loadRecent(),
  };

  @override
  void saveView(GraphShownView view) {
    if (_entry == null) {
      _memory.saveView(view);
      return;
    }
    _write((p) => p.copyWith(graphView: view.encode()));
  }

  @override
  void saveRecent(List<GraphRecent> recent) {
    if (_entry == null) {
      _memory.saveRecent(recent);
      return;
    }
    _write((p) => p.copyWith(recentSearches: <String>[for (final GraphRecent r in recent) r.encode()]));
  }

  void _write(ProjectEntry Function(ProjectEntry entry) change) => unawaited(
    _store
        .update(
          (s) => s.copyWith(
            projects: s.projects.copyWith(
              projects: <ProjectEntry>[
                for (final ProjectEntry p in s.projects.projects)
                  if (p.path == path) change(p) else p,
              ],
            ),
          ),
        )
        .onError<FileSystemException>((_, _) {}),
  );
}

/// A [GraphSearchStore] in memory (tests, the catalogue, a repository outside the registry).
class MemoryGraphSearchStore implements GraphSearchStore {
  /// A store holding a view and [recent].
  MemoryGraphSearchStore({this._view = GraphShownView.defaultSearch, List<GraphRecent>? recent})
    : _recent = recent ?? <GraphRecent>[];

  GraphShownView _view;
  List<GraphRecent> _recent;

  @override
  GraphShownView loadView() => _view;

  @override
  List<GraphRecent> loadRecent() => List<GraphRecent>.of(_recent);

  @override
  void saveView(GraphShownView view) => _view = view;

  @override
  void saveRecent(List<GraphRecent> recent) => _recent = List<GraphRecent>.of(recent);
}
