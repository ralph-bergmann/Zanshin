// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// The Viewed key of [path] in [changeId] whose summary fingerprint is [fingerprint] (Story 10.24): ids and
/// fingerprints are hex, so the path goes last and may hold `:`.
String viewedKey(String changeId, String path, String fingerprint) => '$changeId:$fingerprint:$path';

/// Where the inspector keeps a repository's Viewed marks (Story 10.24); it notifies when they change, by anyone
/// (Story 10.37: the cleanup and Settings' reset write them too).
abstract interface class InspectorViewedStore implements Listenable {
  /// The stored keys ([viewedKey]), oldest first.
  Set<String> load();

  /// Replaces the stored keys with [keys] (in insertion order, oldest first; the store may keep only the newest).
  void save(Set<String> keys);
}

/// A repository's Viewed marks in its view state file (Story 10.24; Story 10.37): `viewedFiles` of
/// `SettingsStore.projectStates.of(path)`, the newest [limit], as `ProjectStackStore` keeps the stack toggles. A path
/// not in the registry keeps them in memory for the session; a failed write keeps the value (the state store logs it).
class ProjectViewedStore implements InspectorViewedStore {
  /// The marks of the repository at [path] in [_settings].
  ProjectViewedStore(this._settings, this.path);

  /// How many marks it keeps, the newest.
  static const limit = 2000;

  final SettingsStore _settings;

  /// The repository's root, the registry key.
  final String path;

  final _memory = ValueNotifier<Set<String>>(const <String>{});

  ProjectStateStore? get _state => _settings.projectStates.of(path);

  @override
  Set<String> load() {
    final ProjectState? state = _state?.value;
    return state == null ? {..._memory.value} : state.viewedFiles.toSet();
  }

  @override
  void save(Set<String> keys) {
    final List<String> kept = keys.skip(keys.length > limit ? keys.length - limit : 0).toList();
    final ProjectStateStore? state = _state;
    if (state == null) {
      _memory.value = kept.toSet();
      return;
    }
    unawaited(state.update((s) => s.copyWith(viewedFiles: kept)));
  }

  @override
  void addListener(VoidCallback listener) => (_state ?? _memory).addListener(listener);

  @override
  void removeListener(VoidCallback listener) {
    _state?.removeListener(listener);
    _memory.removeListener(listener);
  }
}
