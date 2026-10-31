// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:zanshin_settings/zanshin_settings.dart';

import 'graph_ports.dart';

/// A repository's stack toggles on its [ProjectEntry] (Story 10.17): `expandedStacks` and `collapsedStacks` of the
/// registry entry at [path]. A path not in the registry keeps them in memory for the session; a failed write is
/// swallowed (the store keeps the value), as the View options' are.
class ProjectStackStore implements GraphStackStore {
  /// The toggles of the repository at [path] in [_store].
  ProjectStackStore(this._store, this.path);

  final SettingsStore _store;

  /// The repository's root, the registry key.
  final String path;

  GraphStackToggles? _memory;

  ProjectEntry? get _entry => _store.value.projects.projects.where((p) => p.path == path).firstOrNull;

  @override
  GraphStackToggles load() {
    final ProjectEntry? entry = _entry;
    if (entry == null) {
      return _memory ?? const GraphStackToggles();
    }
    return GraphStackToggles(expanded: entry.expandedStacks.toSet(), collapsed: entry.collapsedStacks.toSet());
  }

  @override
  void save(GraphStackToggles toggles) {
    if (_entry == null) {
      _memory = toggles;
      return;
    }
    final List<String> expanded = toggles.expanded.toList()..sort();
    final List<String> collapsed = toggles.collapsed.toList()..sort();
    unawaited(
      _store
          .update(
            (s) => s.copyWith(
              projects: s.projects.copyWith(
                projects: <ProjectEntry>[
                  for (final ProjectEntry p in s.projects.projects)
                    if (p.path == path) p.copyWith(expandedStacks: expanded, collapsedStacks: collapsed) else p,
                ],
              ),
            ),
          )
          .onError<FileSystemException>((_, _) {}),
    );
  }
}
