// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('project_registry_test');
    file = File('${dir.path}/settings.json');
  });

  tearDown(() => dir.delete(recursive: true));

  Future<ProjectRegistry> load() async => ProjectRegistry(await SettingsStore.load(file));

  /// The orders of the members of [parent], as `name:order`, groups and projects alike, by order.
  List<String> orders(ProjectsSettings registry, String? parent) => (<(int, String)>[
    for (final ProjectGroup group in registry.groups)
      if (group.parent == parent) (group.order, '${group.name}:${group.order}'),
    for (final ProjectEntry project in registry.projects)
      if (project.group == parent) (project.order, '${project.name}:${project.order}'),
  ]..sort((a, b) => a.$1.compareTo(b.$1))).map((member) => member.$2).toList();

  test('add, group, move and reload: the value survives the file, every parent numbers its members 0..n', () async {
    final ProjectRegistry registry = await load();
    await registry.add('/r/a');
    await registry.add('/r/b');
    final String group = await registry.addGroup('G');
    expect(group, 'g1');
    expect(orders(registry.value, null), <String>['a:0', 'b:1', 'G:2']);

    await registry.move('/r/b', group: group, index: 0);
    expect(orders(registry.value, null), <String>['a:0', 'G:1']);
    expect(orders(registry.value, group), <String>['b:0']);

    await registry.move('/r/a', index: 1);
    expect(orders(registry.value, null), <String>['G:0', 'a:1']);

    final ProjectRegistry reloaded = await load();
    expect(reloaded.value, registry.value);
    expect(reloaded.entry('/r/b'), const ProjectEntry(path: '/r/b', name: 'b', group: 'g1'));
  });

  test('a move clamps its index and renumbers the old siblings', () async {
    final ProjectRegistry registry = await load();
    for (final name in <String>['a', 'b', 'c']) {
      await registry.add('/r/$name');
    }
    final String group = await registry.addGroup('G');
    await registry.add('/r/d', group: group);
    await registry.move('/r/b', group: group, index: 99);
    expect(orders(registry.value, null), <String>['a:0', 'c:1', 'G:2']);
    expect(orders(registry.value, group), <String>['d:0', 'b:1']);
    await registry.move('/r/c', group: group, index: -3);
    expect(orders(registry.value, group), <String>['c:0', 'd:1', 'b:2']);
    await registry.move('/r/unknown', index: 0);
    expect(orders(registry.value, null), <String>['a:0', 'G:1']);
  });

  test('a project is named after the last segment of its path; adding a path twice changes nothing', () async {
    final ProjectRegistry registry = await load();
    await registry.add('/Users/me/code/zanshin/');
    await registry.add('/Users/me/code/zanshin/', name: 'other');
    await registry.add('/r/x', name: 'Named');
    expect(registry.value.projects.map((project) => project.name), <String>['zanshin', 'Named']);
  });

  test(
    'a new project or group goes last even when the stored orders have gaps; an overlong group id is skipped',
    () async {
      final SettingsStore store = await SettingsStore.load(file);
      await store.update(
        (settings) => settings.copyWith(
          projects: const ProjectsSettings(
            projects: <ProjectEntry>[
              ProjectEntry(path: '/r/a', name: 'a'),
              ProjectEntry(path: '/r/b', name: 'b', order: 5),
            ],
            groups: <ProjectGroup>[
              ProjectGroup(id: 'g3', name: 'G', order: 7),
              ProjectGroup(id: 'g99999999999999999999999999', name: 'Overlong', parent: 'g3', order: 2),
            ],
          ),
        ),
      );
      final registry = ProjectRegistry(store);

      await registry.add('/r/c');
      expect(registry.entry('/r/c')!.order, 8);
      expect(await registry.addGroup('H'), 'g4');
      expect(registry.value.groups.last.order, 9);
      await registry.add('/r/d', group: 'g3');
      expect(registry.entry('/r/d')!.order, 3);
      await registry.add('/r/e', group: 'g4');
      expect(registry.entry('/r/e')!.order, 0, reason: 'an empty group starts at 0');
    },
  );

  test('a group id is g and one above the highest such id; groups nest', () async {
    final ProjectRegistry registry = await load();
    expect(await registry.addGroup('Work'), 'g1');
    expect(await registry.addGroup('Mobile', parent: 'g1'), 'g2');
    expect(registry.value.groups.last, const ProjectGroup(id: 'g2', name: 'Mobile', parent: 'g1'));
  });

  test('opened times are stored in UTC; state, the open project and an unchanged value that writes nothing', () async {
    final ProjectRegistry registry = await load();
    await registry.add('/r/a');
    await registry.recordOpened('/r/a', at: DateTime.utc(2026, 10, 18, 12).toLocal());
    await registry.recordState('/r/a', ProjectStatus.dirty, 'main');
    await registry.setOpen('/r/a');
    expect(registry.entry('/r/a')!.lastOpened, DateTime.utc(2026, 10, 18, 12));
    expect(registry.entry('/r/a')!.lastOpened!.isUtc, isTrue);
    expect(registry.entry('/r/a')!.status, ProjectStatus.dirty);
    expect(registry.entry('/r/a')!.bookmark, 'main');
    expect(registry.value.openProject, '/r/a');

    var notifications = 0;
    registry.addListener(() => notifications++);
    final DateTime written = file.lastModifiedSync();
    await registry.recordState('/r/a', ProjectStatus.dirty, 'main');
    await registry.setOpen('/r/a');
    expect(notifications, 0);
    expect(file.lastModifiedSync(), written);
    await registry.recordState('/r/missing', ProjectStatus.clean, null);
    expect(registry.entry('/r/missing'), isNull);
  });

  test('Recent: the open project first, then four by last opened; no missing, none never opened', () async {
    final ProjectRegistry registry = await load();
    final base = DateTime.utc(2026, 10);
    for (final (String name, int day) in <(String, int)>[
      ('open', 1),
      ('gone', 30),
      ('never', 0),
      ('p1', 2),
      ('p2', 9),
      ('p3', 5),
      ('p4', 7),
      ('p5', 3),
    ]) {
      await registry.add('/r/$name');
      if (day > 0) {
        await registry.recordOpened('/r/$name', at: base.add(Duration(days: day)));
      }
    }
    await registry.recordState('/r/gone', ProjectStatus.missing, null);

    expect(registry.recent(open: '/r/open').map((project) => project.name), <String>['open', 'p2', 'p4', 'p3', 'p5']);
    expect(registry.recent().map((project) => project.name), <String>['p2', 'p4', 'p3', 'p5', 'p1']);
    expect(registry.recent(open: '/r/open', limit: 2).map((project) => project.name), <String>['open', 'p2']);
  });

  test('a failed write is swallowed: the registry keeps the new value for the session', () async {
    // A directory in the file's place makes the store's final rename fail.
    await Directory(file.path).create();
    final ProjectRegistry registry = await load();
    await registry.add('/r/a');
    expect(registry.entry('/r/a'), isNotNull);
  });
}
