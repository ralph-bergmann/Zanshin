// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'graph_ports.dart';

/// A repository's stack toggles in its view state file (Story 10.17; Story 10.37): `expandedStacks` and
/// `collapsedStacks` of `SettingsStore.projectStates.of(path)`, the newest [limit] of each. A path not in the registry
/// keeps them in memory for the session; a failed write keeps the value (the state store logs it).
class ProjectStackStore implements GraphStackStore {
  /// The toggles of the repository at [path] in [_settings].
  ProjectStackStore(this._settings, this.path);

  /// How many toggles each list keeps, the newest.
  static const limit = 500;

  final SettingsStore _settings;

  /// The repository's root, the registry key.
  final String path;

  final _memory = ValueNotifier<GraphStackToggles>(const GraphStackToggles());

  ProjectStateStore? get _state => _settings.projectStates.of(path);

  @override
  GraphStackToggles load() {
    final ProjectState? state = _state?.value;
    if (state == null) {
      return _memory.value;
    }
    return GraphStackToggles(expanded: state.expandedStacks.toSet(), collapsed: state.collapsedStacks.toSet());
  }

  @override
  void save(GraphStackToggles toggles) {
    final List<String> expanded = _newest(toggles.expanded);
    final List<String> collapsed = _newest(toggles.collapsed);
    final ProjectStateStore? state = _state;
    if (state == null) {
      _memory.value = GraphStackToggles(expanded: expanded.toSet(), collapsed: collapsed.toSet());
      return;
    }
    unawaited(state.update((s) => s.copyWith(expandedStacks: expanded, collapsedStacks: collapsed)));
  }

  static List<String> _newest(Set<String> keys) => keys.skip(keys.length > limit ? keys.length - limit : 0).toList();

  @override
  void addListener(VoidCallback listener) => (_state ?? _memory).addListener(listener);

  @override
  void removeListener(VoidCallback listener) {
    _state?.removeListener(listener);
    _memory.removeListener(listener);
  }
}
