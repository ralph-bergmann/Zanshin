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

  group('Story 11.6', () {
    test('add places a new project at an index among its siblings and renumbers them', () async {
      final ProjectRegistry registry = await load();
      await registry.add('/r/a');
      await registry.add('/r/b');
      final String group = await registry.addGroup('G');
      await registry.add('/r/c', index: 1);
      expect(orders(registry.value, null), <String>['a:0', 'c:1', 'b:2', 'G:3']);
      await registry.add('/r/d', group: group, index: 5);
      await registry.add('/r/e', group: group, index: 0);
      expect(orders(registry.value, group), <String>['e:0', 'd:1']);
      await registry.add('/r/c', group: group, index: 0);
      expect(registry.entry('/r/c')!.group, isNull, reason: 'a registered path stays where it is');
    });

    test('remove takes only the entry out, renumbers its siblings and clears the open project', () async {
      final ProjectRegistry registry = await load();
      for (final name in <String>['a', 'b', 'c']) {
        await registry.add('${dir.path}/$name');
      }
      await Directory('${dir.path}/b').create();
      await registry.setOpen('${dir.path}/b');

      await registry.remove('${dir.path}/b');

      expect(orders(registry.value, null), <String>['a:0', 'c:1']);
      expect(registry.value.openProject, isNull);
      expect(Directory('${dir.path}/b').existsSync(), isTrue, reason: 'the folder on disk stays');
      await registry.setOpen('${dir.path}/a');
      await registry.remove('${dir.path}/c');
      expect(registry.value.openProject, '${dir.path}/a', reason: 'another project stays open');
      await registry.remove('/r/unknown');
      expect(orders(registry.value, null), <String>['a:0']);
    });

    test('moveGroup moves a group with what it holds; into itself or a group inside it changes nothing', () async {
      final ProjectRegistry registry = await load();
      final String work = await registry.addGroup('Work');
      final String mobile = await registry.addGroup('Mobile', parent: work);
      final String deep = await registry.addGroup('Deep', parent: mobile);
      await registry.add('/r/app', group: mobile);
      await registry.add('/r/top');
      expect(orders(registry.value, null), <String>['Work:0', 'top:1']);

      await registry.moveGroup(mobile, index: 0);
      expect(orders(registry.value, null), <String>['Mobile:0', 'Work:1', 'top:2']);
      expect(orders(registry.value, work), isEmpty);
      expect(registry.entry('/r/app')!.group, mobile, reason: 'its projects move with it');

      final ProjectsSettings before = registry.value;
      await registry.moveGroup(mobile, index: 0, parent: mobile);
      await registry.moveGroup(mobile, index: 0, parent: deep);
      await registry.moveGroup('g99', index: 0);
      expect(registry.value, before);

      await registry.moveGroup(work, index: 9, parent: mobile);
      expect(orders(registry.value, mobile), <String>['Deep:0', 'app:1', 'Work:2']);
      expect(registry.isWithin(work, mobile), isTrue);
      expect(registry.isWithin(mobile, work), isFalse);
      expect(registry.isWithin(null, work), isFalse);
    });

    test('registered finds an entry by another spelling of its path: a trailing slash, a symlink', () async {
      final ProjectRegistry registry = await load();
      final Directory real = await Directory('${dir.path}/real').create();
      final String canonical = real.resolveSymbolicLinksSync();
      await Link('${dir.path}/alias').create(canonical);
      await registry.add(canonical);

      expect(registry.registered('$canonical/')?.path, canonical);
      expect(registry.registered('${dir.path}/alias')?.path, canonical);
      expect(registry.registered('${dir.path}/./real/../real')?.path, canonical);
      expect(registry.registered('${dir.path}/other'), isNull);
    });
  });

  group('Story 11.15', () {
    test('renameGroup persists across a reload; an unknown id or the same name writes nothing', () async {
      final ProjectRegistry registry = await load();
      final String work = await registry.addGroup('Work');
      await registry.renameGroup(work, 'Clients');
      expect((await load()).group(work)!.name, 'Clients');

      var notifications = 0;
      registry.addListener(() => notifications++);
      await registry.renameGroup(work, 'Clients');
      await registry.renameGroup('g99', 'Other');
      expect(notifications, 0);
    });

    test('deleteGroup splices a project and a subgroup into its place, in order, keeping every project', () async {
      final ProjectRegistry registry = await load();
      final String work = await registry.addGroup('Work');
      final String mobile = await registry.addGroup('Mobile', parent: work);
      await registry.add('/r/app', group: mobile);
      await registry.add('/r/api', group: work);
      await registry.add('/r/top');
      await registry.add('/r/gone');
      final paths = <String>{for (final ProjectEntry p in registry.value.projects) p.path};

      await registry.deleteGroup(work);

      expect(registry.group(work), isNull);
      expect(orders(registry.value, null), <String>['Mobile:0', 'api:1', 'top:2', 'gone:3']);
      expect(registry.group(mobile)!.parent, isNull);
      expect(registry.entry('/r/app')!.group, mobile, reason: 'a subgroup keeps what it holds');
      expect(<String>{for (final ProjectEntry p in registry.value.projects) p.path}, paths);
      expect((await load()).value, registry.value);

      final ProjectsSettings before = registry.value;
      await registry.deleteGroup('g99');
      expect(registry.value, before);
    });

    test('deleteGroup inside a group splices among that group’s members', () async {
      final ProjectRegistry registry = await load();
      final String work = await registry.addGroup('Work');
      await registry.add('/r/a', group: work);
      final String mobile = await registry.addGroup('Mobile', parent: work);
      await registry.add('/r/b', group: work);
      await registry.add('/r/m1', group: mobile);
      await registry.add('/r/m2', group: mobile);
      await registry.deleteGroup(mobile);
      expect(orders(registry.value, work), <String>['a:0', 'm1:1', 'm2:2', 'b:3']);
    });
  });

  group('canonicalPath', () {
    test('an existing path resolves its symlinks and loses a trailing slash', () async {
      final Directory real = await Directory('${dir.path}/real').create();
      await Link('${dir.path}/alias').create(real.path);
      final String resolved = real.resolveSymbolicLinksSync();
      expect(canonicalPath('${dir.path}/alias/'), resolved);
      expect(canonicalPath('${real.path}/'), resolved);
    });

    test('a missing path is normalised by its spelling', () {
      expect(canonicalPath('/r/a/'), '/r/a');
      expect(canonicalPath('/r//a/./b/../c'), '/r/a/c');
      expect(canonicalPath('/../r'), '/r');
      expect(canonicalPath('/'), '/');
      expect(canonicalPath('r/../../s'), '../s');
      expect(canonicalPath(''), '.');
    });
  });
}
