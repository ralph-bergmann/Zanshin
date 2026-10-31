// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/l10n/app_localizations_en.dart';
import 'package:zanshin/src/features/projects/projects_tree_model.dart';
import 'package:zanshin/src/features/projects/tree_drop.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// Work › (Mobile › myapp, design-kit), api · top: the floating export's shape (design/data.js:305-338), mixed orders.
const _registry = ProjectsSettings(
  groups: <ProjectGroup>[
    ProjectGroup(id: 'g1', name: 'Work'),
    ProjectGroup(id: 'g2', name: 'Mobile', parent: 'g1'),
    ProjectGroup(id: 'g3', name: 'Empty', order: 2),
  ],
  projects: <ProjectEntry>[
    ProjectEntry(path: '/Users/me/code/work/mobile/myapp', name: 'MyApp', group: 'g2'),
    ProjectEntry(path: '/Users/me/code/work/mobile/design-kit', name: 'design-kit', group: 'g2', order: 1),
    ProjectEntry(path: '/Users/me/code/work/api-server', name: 'api-server', group: 'g1', order: 1),
    ProjectEntry(path: '/Users/me/code/top', name: 'top', order: 1),
  ],
);

/// The visible rows as `<depth>:<name>`.
List<String> _shown(List<TreeSliverNode<ProjectsItem>> roots) => <String>[
  for (final ProjectsRow row in visibleRows(roots)) '${row.depth}:${row.node.content.name}',
];

TreeSliverNode<ProjectsItem> _node(List<TreeSliverNode<ProjectsItem>> roots, String name) =>
    visibleRows(roots).firstWhere((row) => row.node.content.name == name).node;

void main() {
  group('projectsTree', () {
    test('every parent in registry order, groups before projects on a tie, groups expanded by default', () {
      expect(_shown(projectsTree(_registry)), <String>[
        '0:Work',
        '1:Mobile',
        '2:MyApp',
        '2:design-kit',
        '1:api-server',
        '0:top',
        '0:Empty',
      ]);
    });

    test('a collapsed group hides what it holds', () {
      expect(_shown(projectsTree(_registry, collapsed: <String>{'g2'})), <String>[
        '0:Work',
        '1:Mobile',
        '1:api-server',
        '0:top',
        '0:Empty',
      ]);
    });

    test('the count: its own projects, then " · 1 group" / " · M groups" only when it holds groups', () {
      final groups = <ProjectsGroupItem>[
        for (final ProjectsRow row in visibleRows(projectsTree(_registry)))
          if (row.node.content case final ProjectsGroupItem group) group,
      ];
      expect(
        <String>[for (final group in groups) '${group.name} ${group.countIn(AppLocalizationsEn())}'],
        <String>[
          'Work 1 · 1 group',
          'Mobile 2',
          'Empty 0',
        ],
      );
      expect(
        const ProjectsGroupItem(ProjectGroup(id: 'g', name: 'G'), projects: 3, groups: 2).countIn(AppLocalizationsEn()),
        '3 · 2 groups',
      );
    });

    test('a search keeps matching rows by name and path, their groups expanded even when collapsed', () {
      expect(_shown(projectsTree(_registry, query: '  DESIGN ', collapsed: <String>{'g1', 'g2'})), <String>[
        '0:Work',
        '1:Mobile',
        '2:design-kit',
      ]);
      expect(_shown(projectsTree(_registry, query: 'work/api')), <String>['0:Work', '1:api-server']);
    });

    test('a group that matches keeps its whole subtree; no match leaves no row', () {
      expect(_shown(projectsTree(_registry, query: 'mobile')), <String>[
        '0:Work',
        '1:Mobile',
        '2:MyApp',
        '2:design-kit',
      ]);
      expect(projectsTree(_registry, query: 'nothing'), isEmpty);
    });

    test('the new group field sits last in its parent, which expands', () {
      expect(
        _shown(projectsTree(_registry, collapsed: <String>{'g1'}, newGroup: const ProjectsNewGroupItem('g1'))),
        <String>['0:Work', '1:Mobile', '2:MyApp', '2:design-kit', '1:api-server', '1:', '0:top', '0:Empty'],
      );
      expect(_shown(projectsTree(_registry, newGroup: const ProjectsNewGroupItem(null))).last, '0:');
    });

    test('a member whose parent is unknown shows at the top level', () {
      const registry = ProjectsSettings(
        projects: <ProjectEntry>[ProjectEntry(path: '/r/orphan', name: 'orphan', group: 'gone')],
      );
      expect(_shown(projectsTree(registry)), <String>['0:orphan']);
    });
  });

  group('registryPlacement', () {
    final List<TreeSliverNode<ProjectsItem>> roots = projectsTree(_registry);

    ProjectsPlacement placed(String target, TreeDropPlacement placement, {String? moving}) => registryPlacement(
      treeInsertionPoint(roots, _node(roots, target), placement),
      roots,
      _registry,
      moving: moving == null ? null : _node(roots, moving).content,
    );

    test('before and after a row map to its parent and its index among the registry members', () {
      expect(placed('design-kit', TreeDropPlacement.before), (group: 'g2', index: 1));
      expect(placed('design-kit', TreeDropPlacement.after), (group: 'g2', index: 2));
      expect(placed('top', TreeDropPlacement.before), (group: null, index: 1));
    });

    test('inside a group is its end; after an expanded group with children is its start', () {
      expect(placed('Empty', TreeDropPlacement.inside), (group: 'g3', index: 0));
      expect(placed('Mobile', TreeDropPlacement.inside), (group: 'g2', index: 2));
      expect(placed('Mobile', TreeDropPlacement.after), (group: 'g2', index: 0));
    });

    test('the moving member is left out of the index', () {
      expect(placed('top', TreeDropPlacement.after, moving: 'MyApp'), (group: null, index: 2));
      expect(placed('design-kit', TreeDropPlacement.after, moving: 'MyApp'), (group: 'g2', index: 1));
    });

    test('in a filtered tree the index follows the shown siblings', () {
      final List<TreeSliverNode<ProjectsItem>> filtered = projectsTree(_registry, query: 'design');
      final ProjectsPlacement after = registryPlacement(
        treeInsertionPoint(filtered, _node(filtered, 'design-kit'), TreeDropPlacement.after),
        filtered,
        _registry,
      );
      expect(after, (group: 'g2', index: 2));
    });
  });

  test('registryMembers orders a parent like the registry: groups first on a tie', () {
    expect(registryMembers(_registry, null), <String>['group:g1', 'project:/Users/me/code/top', 'group:g3']);
    expect(registryMembers(_registry, 'g1'), <String>['group:g2', 'project:/Users/me/code/work/api-server']);
  });

  test('cloneDestinationFor follows the CLI: no .git, no trailing slash, after the last / \\ or :', () {
    expect(cloneDestinationFor('https://github.com/jj-vcs/jj.git'), 'jj');
    expect(cloneDestinationFor('https://github.com/jj-vcs/jj/'), 'jj');
    expect(cloneDestinationFor('git@github.com:jj-vcs.git'), 'jj-vcs');
    expect(cloneDestinationFor(r'C:\repos\api'), 'api');
    expect(cloneDestinationFor('repo.git/'), isNull);
    expect(cloneDestinationFor('plain'), isNull);
  });

  test('shellQuote wraps in single quotes and escapes a single quote', () {
    expect(shellQuote('/Users/me/code/api'), "'/Users/me/code/api'");
    expect(shellQuote("/Users/me/it's"), r"'/Users/me/it'\''s'");
  });
}
