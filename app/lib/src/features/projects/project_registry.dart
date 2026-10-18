// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// The project registry over the settings store (Story 11.5 item 1): reads and edits `AppSettings.projects`.
///
/// Every edit is one `SettingsStore.update`, so listeners hear it at once and an edit that changes nothing writes
/// nothing. A failed write is logged by the store and swallowed here: the registry keeps the new value for the session
/// (as the shell's layout writes do, Story 11.3). Siblings — the groups and projects of one parent — share one order,
/// renumbered 0..n whenever one joins or leaves them.
class ProjectRegistry implements ValueListenable<ProjectsSettings> {
  /// The registry stored in [_store].
  ProjectRegistry(this._store);

  final SettingsStore _store;

  /// How many projects the Project menu's Recent lists (DS components/menus/ProjectMenu.prompt.md:11; the floating
  /// export's settings.jsx:20).
  static const recentLimit = 5;

  static final _groupId = RegExp(r'^g(\d+)$');

  @override
  ProjectsSettings get value => _store.value.projects;

  /// Listens to the store: every settings change, the registry's included.
  @override
  void addListener(VoidCallback listener) => _store.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _store.removeListener(listener);

  /// The project registered at [path], or null.
  ProjectEntry? entry(String path) {
    for (final ProjectEntry project in value.projects) {
      if (project.path == path) {
        return project;
      }
    }
    return null;
  }

  /// Registers [path] last among the siblings in [group] (the top level when null) — one above the highest order
  /// there — named [name] or else after the last segment of the path (Claude's proposal). A path already registered
  /// stays as it is.
  Future<void> add(String path, {String? name, String? group}) {
    if (entry(path) != null) {
      return Future<void>.value();
    }
    return _update(
      (registry) => registry.copyWith(
        projects: <ProjectEntry>[
          ...registry.projects,
          ProjectEntry(
            path: path,
            name: name ?? _lastSegment(path),
            group: group,
            order: _nextOrder(registry, group),
          ),
        ],
      ),
    );
  }

  /// Adds a group named [name] last among the siblings in [parent] (the top level when null) — one above the highest
  /// order there — and returns its id, `g<n>` with n one above the highest such id (Claude's proposal); a stored id
  /// whose number does not fit an int is skipped.
  Future<String> addGroup(String name, {String? parent}) async {
    var highest = 0;
    for (final ProjectGroup group in value.groups) {
      final String? digits = _groupId.firstMatch(group.id)?.group(1);
      final int? n = digits == null ? null : int.tryParse(digits);
      if (n != null) {
        highest = math.max(highest, n);
      }
    }
    final id = 'g${highest + 1}';
    await _update(
      (registry) => registry.copyWith(
        groups: <ProjectGroup>[
          ...registry.groups,
          ProjectGroup(id: id, name: name, parent: parent, order: _nextOrder(registry, parent)),
        ],
      ),
    );
    return id;
  }

  /// Moves the project at [path] into [group] (the top level when null) at [index] among its new siblings, clamped
  /// to their range; the old and the new siblings are renumbered 0..n.
  Future<void> move(String path, {required int index, String? group}) {
    final ProjectEntry? moving = entry(path);
    if (moving == null) {
      return Future<void>.value();
    }
    final moved = _Member.project(path);
    return _update((registry) {
      final orders = <_Member, int>{};
      final List<_Member> old = _siblings(registry, moving.group)..remove(moved);
      for (var i = 0; i < old.length; i++) {
        orders[old[i]] = i;
      }
      final List<_Member> target = _siblings(registry, group)..remove(moved);
      target.insert(index.clamp(0, target.length), moved);
      for (var i = 0; i < target.length; i++) {
        orders[target[i]] = i;
      }
      return registry.copyWith(
        projects: <ProjectEntry>[
          for (final ProjectEntry project in registry.projects)
            if (project.path == path)
              project.copyWith(group: group, order: orders[moved]!)
            else
              project.copyWith(order: orders[_Member.project(project.path)] ?? project.order),
        ],
        groups: <ProjectGroup>[
          for (final ProjectGroup g in registry.groups) g.copyWith(order: orders[_Member.group(g.id)] ?? g.order),
        ],
      );
    });
  }

  /// Records that the project at [path] was opened [at] (stored in UTC).
  Future<void> recordOpened(String path, {required DateTime at}) =>
      _updateEntry(path, (project) => project.copyWith(lastOpened: at.toUtc()));

  /// Records the project's last known [status] and [bookmark] label (item 7).
  Future<void> recordState(String path, ProjectStatus? status, String? bookmark) =>
      _updateEntry(path, (project) => project.copyWith(status: status, bookmark: bookmark));

  /// Records the project the project window shows, or none.
  Future<void> setOpen(String? path) => _update((registry) => registry.copyWith(openProject: path));

  /// The Project menu's Recent (DS components/menus/ProjectMenu.prompt.md:11; the floating export's settings.jsx:20):
  /// the [open] project first, then the others by last opened, newest first, at most [limit] in all. Missing projects
  /// and projects never opened are left out.
  List<ProjectEntry> recent({String? open, int limit = recentLimit}) {
    final List<ProjectEntry> others =
        value.projects
            .where(
              (project) =>
                  project.path != open && project.status != ProjectStatus.missing && project.lastOpened != null,
            )
            .toList()
          ..sort((a, b) => b.lastOpened!.compareTo(a.lastOpened!));
    return <ProjectEntry>[if (open != null) ?entry(open), ...others].take(limit).toList();
  }

  Future<void> _updateEntry(String path, ProjectEntry Function(ProjectEntry project) change) => _update(
    (registry) => registry.copyWith(
      projects: <ProjectEntry>[
        for (final ProjectEntry project in registry.projects)
          if (project.path == path) change(project) else project,
      ],
    ),
  );

  Future<void> _update(ProjectsSettings Function(ProjectsSettings registry) change) => _store
      .update((settings) => settings.copyWith(projects: change(settings.projects)))
      // The store logs a failed write; the registry keeps the new value for this session.
      .onError<FileSystemException>((_, _) {});

  /// The members of [parent] (the top level when null) in their order: groups before projects on a tie.
  static List<_Member> _siblings(ProjectsSettings registry, String? parent) {
    final members = <(int, int, _Member)>[
      for (final ProjectGroup group in registry.groups)
        if (group.parent == parent) (group.order, 0, _Member.group(group.id)),
      for (final ProjectEntry project in registry.projects)
        if (project.group == parent) (project.order, 1, _Member.project(project.path)),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return <_Member>[for (final (_, _, _Member member) in members) member];
  }

  /// One above the highest order among the members of [parent], or 0 when it has none: a new member goes last even
  /// when the stored orders have gaps.
  static int _nextOrder(ProjectsSettings registry, String? parent) {
    var next = 0;
    for (final ProjectGroup group in registry.groups) {
      if (group.parent == parent) {
        next = math.max(next, group.order + 1);
      }
    }
    for (final ProjectEntry project in registry.projects) {
      if (project.group == parent) {
        next = math.max(next, project.order + 1);
      }
    }
    return next;
  }

  static String _lastSegment(String path) {
    final List<String> segments = path.split('/').where((segment) => segment.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }
}

/// A sibling: a group by its id or a project by its path.
@immutable
class _Member {
  const _Member.group(String this.group) : path = null;

  const _Member.project(String this.path) : group = null;

  final String? group;
  final String? path;

  @override
  bool operator ==(Object other) => other is _Member && other.group == group && other.path == path;

  @override
  int get hashCode => Object.hash(group, path);
}
