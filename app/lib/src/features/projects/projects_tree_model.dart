// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TreeSliverNode;
import 'package:zanshin_settings/zanshin_settings.dart';

import '../../l10n/strings.dart';
import 'tree_drop.dart';

/// One row of the Projects tree (Story 11.6): a group, a project, or the field naming a new group.
@immutable
sealed class ProjectsItem {
  const ProjectsItem();

  /// The row's key, unique in the tree: `group:<id>`, `project:<path>` or `new-group`.
  String get id;

  /// What typeahead matches and the row shows.
  String get name;
}

/// A group row: [group] with the count of its own projects and groups in the registry.
final class ProjectsGroupItem extends ProjectsItem {
  /// The row of [group], holding [projects] projects and [groups] groups, open when [expanded].
  const ProjectsGroupItem(this.group, {required this.projects, required this.groups, this.expanded = true});

  /// The group.
  final ProjectGroup group;

  /// How many projects it holds itself (DS ui_kits/desktop/dialogs.jsx:54).
  final int projects;

  /// How many groups it holds itself.
  final int groups;

  /// Whether the group is open — also when it holds nothing, which `TreeSliverNode.isExpanded` never reports
  /// (design/windows.jsx:386: an empty group opens too and shows that it is empty).
  final bool expanded;

  @override
  String get id => 'group:${group.id}';

  @override
  String get name => group.name;

  /// The count column in [strings]: "N", and " · 1 group" / " · M groups" when it holds any (DS
  /// components/content/ProjectRow.jsx:50).
  String countIn(AppLocalizations strings) => strings.groupCount(projects, groups);
}

/// A project row.
final class ProjectsProjectItem extends ProjectsItem {
  /// The row of [entry].
  const ProjectsProjectItem(this.entry);

  /// The registered project.
  final ProjectEntry entry;

  @override
  String get id => 'project:${entry.path}';

  @override
  String get name => entry.name;

  /// Whether its path is gone: it shows struck through and does not open.
  bool get missing => entry.status == ProjectStatus.missing;
}

/// The inline field that names a new group in [parent] (the top level when null).
final class ProjectsNewGroupItem extends ProjectsItem {
  /// The field for a new group in [parent]; Move to group › New group… (Story 11.15 item 6) names the row [moving]
  /// that goes into it.
  const ProjectsNewGroupItem(this.parent, {this.moving});

  /// The group the new one goes into, or null for the top level.
  final String? parent;

  /// The row that moves into the new group once it is created, or null for the header's New group.
  final ProjectsItem? moving;

  @override
  String get id => 'new-group';

  @override
  String get name => '';
}

/// Where a member goes in the registry: into `group` (the top level when null) at `index` among its members as the
/// registry orders them; a null index appends it.
typedef ProjectsPlacement = ({String? group, int? index});

/// A visible row of the tree with its depth and parent.
typedef ProjectsRow = ({TreeSliverNode<ProjectsItem> node, int depth, TreeSliverNode<ProjectsItem>? parent});

/// Whether [entry] matches the search [query] (DS ui_kits/desktop/dialogs.jsx:14-16): its name and path joined by a
/// space contain the trimmed query, ignoring case. An empty query matches everything.
bool projectMatches(ProjectEntry entry, String query) {
  final String q = query.trim().toLowerCase();
  return q.isEmpty || '${entry.name} ${entry.path}'.toLowerCase().contains(q);
}

/// Whether [group]'s name contains the trimmed [query], ignoring case.
bool groupMatches(ProjectGroup group, String query) {
  final String q = query.trim().toLowerCase();
  return q.isEmpty || group.name.toLowerCase().contains(q);
}

/// The registry as the Projects tree shows it (Story 11.6): every parent's groups and projects in their registry
/// order, groups before projects on a tie; groups expanded unless [collapsed] holds their id (Claude's proposal:
/// expanded by default).
///
/// With a [query] only matching rows remain, with every group above them expanded; a matching group keeps its whole
/// subtree. A group or project whose parent is not in the registry shows at the top level (Claude's proposal). The
/// [newGroup] field sits last in its parent, which is expanded.
List<TreeSliverNode<ProjectsItem>> projectsTree(
  ProjectsSettings registry, {
  Set<String> collapsed = const <String>{},
  String query = '',
  ProjectsNewGroupItem? newGroup,
}) {
  final known = <String>{for (final ProjectGroup group in registry.groups) group.id};
  String? parentOf(String? id) => id != null && known.contains(id) ? id : null;
  final members = <String?, List<(int, int, Object)>>{};
  for (final ProjectGroup group in registry.groups) {
    (members[parentOf(group.parent)] ??= <(int, int, Object)>[]).add((group.order, 0, group));
  }
  for (final ProjectEntry project in registry.projects) {
    (members[parentOf(project.group)] ??= <(int, int, Object)>[]).add((project.order, 1, project));
  }
  for (final List<(int, int, Object)> list in members.values) {
    list.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  }
  final bool searching = query.trim().isNotEmpty;
  final visited = <String>{};

  List<TreeSliverNode<ProjectsItem>> build(String? parent, {required bool all}) {
    final nodes = <TreeSliverNode<ProjectsItem>>[];
    for (final (_, _, Object member) in members[parent] ?? const <(int, int, Object)>[]) {
      switch (member) {
        case final ProjectGroup group when visited.add(group.id):
          final bool keepAll = all || (searching && groupMatches(group, query));
          final List<TreeSliverNode<ProjectsItem>> children = build(group.id, all: keepAll);
          final adding = newGroup?.parent == group.id;
          if (searching && !keepAll && children.isEmpty && !adding) {
            continue;
          }
          final int projects = members[group.id]?.where((m) => m.$3 is ProjectEntry).length ?? 0;
          final int groups = members[group.id]?.where((m) => m.$3 is ProjectGroup).length ?? 0;
          final bool expanded = searching || adding || !collapsed.contains(group.id);
          nodes.add(
            TreeSliverNode<ProjectsItem>(
              ProjectsGroupItem(group, projects: projects, groups: groups, expanded: expanded),
              children: <TreeSliverNode<ProjectsItem>>[...children, if (adding) TreeSliverNode(newGroup!)],
              expanded: expanded,
            ),
          );
        case final ProjectEntry project when all || !searching || projectMatches(project, query):
          nodes.add(TreeSliverNode<ProjectsItem>(ProjectsProjectItem(project)));
        default:
          break;
      }
    }
    return nodes;
  }

  return <TreeSliverNode<ProjectsItem>>[
    ...build(null, all: false),
    if (newGroup != null && newGroup.parent == null) TreeSliverNode<ProjectsItem>(newGroup),
  ];
}

/// The rows [roots] shows, top to bottom: every node whose ancestors are all expanded.
List<ProjectsRow> visibleRows(List<TreeSliverNode<ProjectsItem>> roots) {
  final rows = <ProjectsRow>[];
  void walk(List<TreeSliverNode<ProjectsItem>> nodes, int depth, TreeSliverNode<ProjectsItem>? parent) {
    for (final node in nodes) {
      rows.add((node: node, depth: depth, parent: parent));
      if (node.isExpanded) {
        walk(node.children, depth + 1, node);
      }
    }
  }

  walk(roots, 0, null);
  return rows;
}

/// The registry's members of [parent] (the top level when null) as row ids, in its order: groups before projects on a
/// tie (`ProjectRegistry`'s sibling order).
List<String> registryMembers(ProjectsSettings registry, String? parent) {
  final members = <(int, int, String)>[
    for (final ProjectGroup group in registry.groups)
      if (group.parent == parent) (group.order, 0, 'group:${group.id}'),
    for (final ProjectEntry project in registry.projects)
      if (project.group == parent) (project.order, 1, 'project:${project.path}'),
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return <String>[for (final (_, _, String id) in members) id];
}

/// Where [point] — an insertion point in [roots], from `tree_drop.dart` — puts a member in [registry] (design note
/// "Placement mapping"): the parent's group id and the index among that group's registry members, [moving] (the member
/// being moved) left out. The index is the place of the first shown sibling at or after the point, else one after the
/// last shown sibling before it, else the end — so a filtered tree places among the shown rows.
ProjectsPlacement registryPlacement(
  TreeInsertionPoint<ProjectsItem> point,
  List<TreeSliverNode<ProjectsItem>> roots,
  ProjectsSettings registry, {
  ProjectsItem? moving,
}) {
  final ProjectsItem? parent = point.parent?.content;
  final String? group = parent is ProjectsGroupItem ? parent.group.id : null;
  final List<String> members = registryMembers(registry, group)..remove(moving?.id);
  final List<TreeSliverNode<ProjectsItem>> siblings = point.parent?.children ?? roots;
  bool counts(TreeSliverNode<ProjectsItem> node) =>
      node.content is! ProjectsNewGroupItem && node.content.id != moving?.id && members.contains(node.content.id);
  for (int i = point.index; i < siblings.length; i++) {
    if (counts(siblings[i])) {
      return (group: group, index: members.indexOf(siblings[i].content.id));
    }
  }
  for (int i = point.index.clamp(0, siblings.length) - 1; i >= 0; i--) {
    if (counts(siblings[i])) {
      return (group: group, index: members.indexOf(siblings[i].content.id) + 1);
    }
  }
  return (group: group, index: members.length);
}

/// The jj CLI's destination for a clone of [source] (`clone_destination_for_source`, `clone.rs:162-168` @ v0.46.0):
/// the source without a trailing `.git` and `/`, after its last `/`, `\` or `:`; null when it has none.
String? cloneDestinationFor(String source) {
  String destination = source.endsWith('.git') ? source.substring(0, source.length - 4) : source;
  if (destination.endsWith('/')) {
    destination = destination.substring(0, destination.length - 1);
  }
  final int cut = <int>[
    destination.lastIndexOf('/'),
    destination.lastIndexOf(r'\'),
    destination.lastIndexOf(':'),
  ].reduce((a, b) => a > b ? a : b);
  return cut < 0 ? null : destination.substring(cut + 1);
}

/// [value] quoted for a POSIX shell: in single quotes, a single quote inside written `'\''`.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";
