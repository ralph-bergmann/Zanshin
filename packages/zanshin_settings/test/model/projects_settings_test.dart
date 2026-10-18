// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:freezed_annotation/freezed_annotation.dart' show CheckedFromJsonException;
import 'package:zanshin_settings/zanshin_settings.dart';

void main() {
  final opened = DateTime.utc(2026, 10, 18, 9, 30, 15, 250);
  final registry = ProjectsSettings(
    projects: <ProjectEntry>[
      ProjectEntry(
        path: '/r/a',
        name: 'a',
        group: 'g1',
        order: 1,
        lastOpened: opened,
        status: ProjectStatus.conflict,
        bookmark: 'main',
      ),
      const ProjectEntry(path: '/r/b', name: 'b'),
    ],
    groups: const <ProjectGroup>[
      ProjectGroup(id: 'g1', name: 'Work'),
      ProjectGroup(id: 'g2', name: 'Mobile', parent: 'g1', order: 2),
    ],
    openProject: '/r/a',
  );

  test('an empty registry by default: no projects, no groups, nothing open', () {
    expect(const AppSettings().projects, const ProjectsSettings());
    expect(const ProjectsSettings().projects, isEmpty);
    expect(const ProjectsSettings().groups, isEmpty);
    expect(const ProjectsSettings().openProject, isNull);
  });

  test('a registry survives a JSON round trip: the time in UTC, the status by name', () {
    final Map<String, Object?> json = AppSettings(projects: registry).toJson();
    final projects = json['projects']! as Map<String, Object?>;
    final first = (projects['projects']! as List<Object?>).first! as Map<String, Object?>;
    expect(first, <String, Object?>{
      'path': '/r/a',
      'name': 'a',
      'group': 'g1',
      'order': 1,
      'lastOpened': '2026-10-18T09:30:15.250Z',
      'status': 'conflict',
      'bookmark': 'main',
    });
    expect(projects['openProject'], '/r/a');
    final decoded = AppSettings.fromJson(json);
    expect(decoded.projects, registry);
    expect(decoded.projects.projects.first.lastOpened!.isUtc, isTrue);
  });

  test('a file written before the registry existed loads with an empty one', () {
    final settings = AppSettings.fromJson(<String, Object?>{
      'appearance': <String, Object?>{'themeMode': 'dark'},
      'general': <String, Object?>{'hideControls': false},
    });
    expect(settings.projects, const ProjectsSettings());
    expect(settings.general.hideControls, isFalse);
  });

  test('a status this version does not know reads as null; the rest of the entry and the file load', () {
    final settings = AppSettings.fromJson(<String, Object?>{
      'projects': <String, Object?>{
        'projects': <Object?>[
          <String, Object?>{'path': '/r/a', 'name': 'a', 'status': 'ahead', 'bookmark': 'main', 'order': 3},
          <String, Object?>{'path': '/r/b', 'name': 'b', 'status': 'dirty'},
        ],
        'openProject': '/r/b',
      },
    });
    expect(settings.projects.projects, const <ProjectEntry>[
      ProjectEntry(path: '/r/a', name: 'a', order: 3, bookmark: 'main'),
      ProjectEntry(path: '/r/b', name: 'b', status: ProjectStatus.dirty),
    ]);
    expect(settings.projects.openProject, '/r/b');
  });

  test('a wrongly typed or missing field throws CheckedFromJsonException', () {
    expect(
      () => ProjectEntry.fromJson(<String, Object?>{'path': 5, 'name': 'a'}),
      throwsA(isA<CheckedFromJsonException>()),
    );
    expect(() => ProjectEntry.fromJson(<String, Object?>{'path': '/r/a'}), throwsA(isA<CheckedFromJsonException>()));
    expect(
      () => ProjectEntry.fromJson(<String, Object?>{'path': '/r/a', 'name': 'a', 'lastOpened': 7}),
      throwsA(isA<CheckedFromJsonException>()),
    );
    expect(
      () => ProjectGroup.fromJson(<String, Object?>{'id': 'g1', 'name': 'G', 'order': 'x'}),
      throwsA(isA<CheckedFromJsonException>()),
    );
    expect(
      () => ProjectsSettings.fromJson(<String, Object?>{'projects': 'none'}),
      throwsA(isA<CheckedFromJsonException>()),
    );
    expect(() => AppSettings.fromJson(<String, Object?>{'projects': 5}), throwsA(isA<CheckedFromJsonException>()));
  });
}
