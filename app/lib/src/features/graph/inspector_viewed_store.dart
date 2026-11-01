// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:zanshin_settings/zanshin_settings.dart';

/// The Viewed key of [path] in [changeId] whose summary fingerprint is [fingerprint] (Story 10.24): ids and
/// fingerprints are hex, so the path goes last and may hold `:`.
String viewedKey(String changeId, String path, String fingerprint) => '$changeId:$fingerprint:$path';

/// Where the inspector keeps a repository's Viewed marks (Story 10.24).
abstract interface class InspectorViewedStore {
  /// The stored keys ([viewedKey]).
  Set<String> load();

  /// Replaces the stored keys with [keys] (in insertion order, oldest first).
  void save(Set<String> keys);
}

/// A repository's Viewed marks on its [ProjectEntry]: `viewedFiles` of the registry entry at [path], as
/// `ProjectStackStore` keeps the stack toggles. A path not in the registry keeps them in memory for the session; a
/// failed write is swallowed (the store keeps the value).
class ProjectViewedStore implements InspectorViewedStore {
  /// The marks of the repository at [path] in [_store].
  ProjectViewedStore(this._store, this.path);

  // shortcut: keep only the newest keys, upgrade to pruning by live change ids if it ever matters.
  static const _limit = 2000;

  final SettingsStore _store;

  /// The repository's root, the registry key.
  final String path;

  Set<String>? _memory;

  ProjectEntry? get _entry => _store.value.projects.projects.where((p) => p.path == path).firstOrNull;

  @override
  Set<String> load() {
    final ProjectEntry? entry = _entry;
    if (entry == null) {
      return {...?_memory};
    }
    return entry.viewedFiles.toSet();
  }

  @override
  void save(Set<String> keys) {
    final List<String> kept = keys.skip(keys.length > _limit ? keys.length - _limit : 0).toList();
    if (_entry == null) {
      _memory = kept.toSet();
      return;
    }
    unawaited(
      _store
          .update(
            (s) => s.copyWith(
              projects: s.projects.copyWith(
                projects: <ProjectEntry>[
                  for (final ProjectEntry p in s.projects.projects)
                    if (p.path == path) p.copyWith(viewedFiles: kept) else p,
                ],
              ),
            ),
          )
          .onError<FileSystemException>((_, _) {}),
    );
  }
}
