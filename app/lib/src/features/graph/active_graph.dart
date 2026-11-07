// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';

import 'graph_preferences.dart';
import 'graph_search_controller.dart';
import 'graph_view_model.dart';

/// What Change › Fetch and Push… and Settings' remote verbs use of the project window's sync (Story 11.8). It notifies
/// when [canFetch] or [canPush] may have changed.
abstract interface class GraphMenuSync implements Listenable {
  /// Whether Fetch may run.
  bool get canFetch;

  /// Whether Push may open its sheet.
  bool get canPush;

  /// `jj git fetch` with the default remotes.
  Future<void> fetch();

  /// Opens the Push sheet; nothing pushes before its Push.
  void openPush();

  /// Reads the remotes again (View › Reload, a Settings remote verb).
  Future<void> reloadRemotes();
}

/// What the project window publishes for the menu bar once its graph is mounted (10.12): the graph's view model, its
/// View preferences and the search's focus.
@immutable
class GraphMenuBinding {
  /// The binding of [model] and [preferences].
  const GraphMenuBinding({
    required this.model,
    required this.preferences,
    this.search,
    this.focusSearch,
    this.squash,
    this.sync,
  });

  /// The graph's view model: the Change, Go and Undo items act on it.
  final GraphViewModel model;

  /// The View items' setters.
  final GraphPreferences preferences;

  /// The graph search: the jj log Configurations window counts, shows and redraws through it (Story 10.22).
  final GraphSearchController? search;

  /// Focuses the graph search (Edit › Find); null while there is none.
  final VoidCallback? focusSearch;

  /// Change › Squash into Parent through the inspector (`InspectorViewModel.squash`, Story 10.25), which asks for the
  /// combined description; null runs `jj squash -r` directly.
  final ValueChanged<String>? squash;

  /// Change › Fetch and Push… (Story 11.8); null leaves them grey.
  final GraphMenuSync? sync;
}

/// The project window's graph (Story 11.24): its [GraphMenuBinding] while one is mounted, else null. The project
/// window's graph host publishes to it and clears only its own binding; the menu bar, Settings and jj log Configurations
/// read it.
@inject
@singleton
class ActiveGraph extends ValueNotifier<GraphMenuBinding?> {
  /// No graph yet.
  ActiveGraph() : super(null);
}
