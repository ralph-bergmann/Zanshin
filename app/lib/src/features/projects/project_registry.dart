// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// [path] as the project session registers it (Story 11.6, Claude's proposal): with its symlinks resolved and `.`,
/// `..` and a trailing `/` gone when it exists; otherwise normalised by its spelling alone — no empty, `.` or `..`
/// segment and no trailing `/` (a relative path stays relative).
String canonicalPath(String path) {
  if (path.isNotEmpty && FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      // Gone between the check and the resolution, or unreadable: its spelling is all there is.
    }
  }
  final bool absolute = path.startsWith('/');
  final segments = <String>[];
  for (final String segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..' && segments.isNotEmpty && segments.last != '..') {
      segments.removeLast();
    } else if (segment != '..' || !absolute) {
      segments.add(segment);
    }
  }
  final String joined = segments.join('/');
  return absolute ? '/$joined' : (joined.isEmpty ? '.' : joined);
}

/// The project registry over the settings store (Story 11.5 item 1; Story 11.6): reads and edits
/// `AppSettings.projects`.
///
/// Every edit is one `SettingsStore.update`, so listeners hear it at once and an edit that changes nothing writes
/// nothing. A failed write is logged by the store and swallowed here: the registry keeps the new value for the session
/// (as the shell's layout writes do, Story 11.3). Siblings — the groups and projects of one parent — share one order,
/// renumbered 0..n whenever one joins or leaves them; on a tie groups come first.
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

  /// The project registered at [path] or at another spelling of it — a trailing `/`, a symlink — compared by
  /// [canonicalPath], or null.
  ProjectEntry? registered(String path) {
    final ProjectEntry? exact = entry(path);
    if (exact != null) {
      return exact;
    }
    final String canonical = canonicalPath(path);
    for (final ProjectEntry project in value.projects) {
      if (project.path == canonical || canonicalPath(project.path) == canonical) {
        return project;
      }
    }
    return null;
  }

  /// The group [id], or null.
  ProjectGroup? group(String id) {
    for (final ProjectGroup group in value.groups) {
      if (group.id == id) {
        return group;
      }
    }
    return null;
  }

  /// Whether the group [group] is [ancestor] or lies inside it; the top level (null) lies inside none.
  bool isWithin(String? group, String ancestor) {
    final visited = <String>{};
    for (var current = group; current != null && visited.add(current); current = this.group(current)?.parent) {
      if (current == ancestor) {
        return true;
      }
    }
    return false;
  }

  /// Registers [path] in [group] (the top level when null) named [name] or else after the last segment of the path
  /// (Claude's proposal): at [index] among its new siblings, clamped to their range, with the siblings renumbered
  /// 0..n — or, without an index, last, one above the highest order there. A path already registered stays as it is.
  Future<void> add(String path, {String? name, String? group, int? index}) {
    if (entry(path) != null) {
      return Future<void>.value();
    }
    return _update((registry) {
      final ProjectsSettings added = registry.copyWith(
        projects: <ProjectEntry>[
          ...registry.projects,
          ProjectEntry(
            path: path,
            name: name ?? _lastSegment(path),
            group: group,
            order: _nextOrder(registry, group),
          ),
        ],
      );
      return index == null ? added : _place(added, _Member.project(path), from: group, into: group, index: index);
    });
  }

  /// Takes the project at [path] out of the registry — the folder on disk stays as it is — and renumbers its siblings
  /// 0..n; it is no longer the open project if it was.
  Future<void> remove(String path) {
    final ProjectEntry? removing = entry(path);
    if (removing == null) {
      return Future<void>.value();
    }
    return _update((registry) {
      final List<_Member> siblings = _siblings(registry, removing.group)..remove(_Member.project(path));
      final orders = <_Member, int>{for (final (int i, _Member member) in siblings.indexed) member: i};
      return registry.copyWith(
        projects: <ProjectEntry>[
          for (final ProjectEntry project in registry.projects)
            if (project.path != path) project.copyWith(order: orders[_Member.project(project.path)] ?? project.order),
        ],
        groups: <ProjectGroup>[
          for (final ProjectGroup g in registry.groups) g.copyWith(order: orders[_Member.group(g.id)] ?? g.order),
        ],
        openProject: registry.openProject == path ? null : registry.openProject,
      );
    });
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

  /// Renames the group [id] to [name]; an unknown id or the same name writes nothing (Story 11.15 item 9).
  Future<void> renameGroup(String id, String name) {
    if (group(id)?.name case final String old when old != name) {
      return _update(
        (registry) => registry.copyWith(
          groups: <ProjectGroup>[
            for (final ProjectGroup g in registry.groups)
              if (g.id == id) g.copyWith(name: name) else g,
          ],
        ),
      );
    }
    return Future<void>.value();
  }

  /// Deletes the group [id] alone (Story 11.15 item 5): its projects and groups take its place among its parent's
  /// members, in their order, and that parent's members are renumbered 0..n; an unknown id changes nothing.
  Future<void> deleteGroup(String id) {
    if (group(id) == null) {
      return Future<void>.value();
    }
    return _update((registry) {
      // Read inside the update: an edit just before this one may have moved or removed the group.
      final ProjectGroup? deleting = registry.groups.where((g) => g.id == id).firstOrNull;
      if (deleting == null) {
        return registry;
      }
      final String? parent = deleting.parent;
      final List<_Member> siblings = _siblings(registry, parent);
      final int at = siblings.indexOf(_Member.group(id));
      siblings.replaceRange(at, at + 1, _siblings(registry, id));
      final orders = <_Member, int>{for (final (int i, _Member member) in siblings.indexed) member: i};
      return registry.copyWith(
        projects: <ProjectEntry>[
          for (final ProjectEntry project in registry.projects)
            project.copyWith(
              group: project.group == id ? parent : project.group,
              order: orders[_Member.project(project.path)] ?? project.order,
            ),
        ],
        groups: <ProjectGroup>[
          for (final ProjectGroup g in registry.groups)
            if (g.id != id)
              g.copyWith(parent: g.parent == id ? parent : g.parent, order: orders[_Member.group(g.id)] ?? g.order),
        ],
      );
    });
  }

  /// Moves the project at [path] into [group] (the top level when null) at [index] among its new siblings, clamped
  /// to their range; the old and the new siblings are renumbered 0..n.
  Future<void> move(String path, {required int index, String? group}) {
    final ProjectEntry? moving = entry(path);
    if (moving == null) {
      return Future<void>.value();
    }
    return _update(
      (registry) => _place(registry, _Member.project(path), from: moving.group, into: group, index: index),
    );
  }

  /// Moves the group [id] with everything inside it into [parent] (the top level when null) at [index] among its new
  /// siblings, as [move] does; a move into the group itself or into a group inside it changes nothing.
  Future<void> moveGroup(String id, {required int index, String? parent}) {
    final ProjectGroup? moving = group(id);
    if (moving == null || isWithin(parent, id)) {
      return Future<void>.value();
    }
    return _update(
      (registry) => _place(registry, _Member.group(id), from: moving.parent, into: parent, index: index),
    );
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

  /// [registry] with [member] — a member of [from] — moved into [into] at [index] among its new siblings, clamped to
  /// their range; the old and the new siblings are renumbered 0..n.
  static ProjectsSettings _place(
    ProjectsSettings registry,
    _Member member, {
    required String? from,
    required String? into,
    required int index,
  }) {
    final orders = <_Member, int>{};
    final List<_Member> old = _siblings(registry, from)..remove(member);
    for (final (int i, _Member sibling) in old.indexed) {
      orders[sibling] = i;
    }
    final List<_Member> target = _siblings(registry, into)..remove(member);
    target.insert(index.clamp(0, target.length), member);
    for (final (int i, _Member sibling) in target.indexed) {
      orders[sibling] = i;
    }
    return registry.copyWith(
      projects: <ProjectEntry>[
        for (final ProjectEntry project in registry.projects)
          if (project.path == member.path)
            project.copyWith(group: into, order: orders[member]!)
          else
            project.copyWith(order: orders[_Member.project(project.path)] ?? project.order),
      ],
      groups: <ProjectGroup>[
        for (final ProjectGroup g in registry.groups)
          if (g.id == member.group)
            g.copyWith(parent: into, order: orders[member]!)
          else
            g.copyWith(order: orders[_Member.group(g.id)] ?? g.order),
      ],
    );
  }

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
