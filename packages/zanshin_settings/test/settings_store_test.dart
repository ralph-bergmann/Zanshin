// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

const _dark = AppSettings(appearance: AppearanceSettings(themeMode: ThemeMode.dark));
const _light = AppSettings(appearance: AppearanceSettings(themeMode: ThemeMode.light));
const _darkJson =
    '{\n  "appearance": {\n    "themeMode": "dark",\n    "accentSource": "followMacOS",\n    "density": "compact",\n    "zoom": 100\n  },\n'
    '  "layout": {\n    "inspectorWidth": 460.0,\n    "panelWidth": 300.0\n  },\n'
    '  "general": {\n    "hideControls": true,\n    "diffLayout": "unified",\n    "diffWordMarks": true\n  },\n'
    '  "projects": {\n    "projects": [],\n    "groups": [],\n    "openProject": null\n  },\n'
    '  "graph": {\n    "layout": "free",\n    "detailedCards": true,\n    "groupStacks": true,\n'
    '    "cardWidth": 240.0,\n    "showMinimap": true,\n    "revsetConfigs": [],\n    "revsetDefault": "log"\n  }\n}\n';

/// Answers `getApplicationSupportPath` with a fixed directory.
final class FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  late Directory dir;
  late File file;
  final List<LogRecord> warnings = [];
  late StreamSubscription<LogRecord> logSubscription;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zanshin_settings_test');
    file = File('${dir.path}/settings.json');
    warnings.clear();
    logSubscription = Logger.root.onRecord.listen((record) {
      if (record.loggerName == 'zanshin.settings' && record.level == Level.WARNING) {
        warnings.add(record);
      }
    });
  });

  tearDown(() async {
    await logSubscription.cancel();
    await dir.delete(recursive: true);
  });

  group('load', () {
    test('a missing file yields defaults and creates nothing', () async {
      final SettingsStore store = await SettingsStore.load(file);

      expect(store.value, const AppSettings());
      expect(store.file, file);
      expect(file.existsSync(), isFalse);
      expect(warnings, isEmpty);
    });

    test('a valid file is parsed', () async {
      await file.writeAsString(_darkJson);

      final SettingsStore store = await SettingsStore.load(file);

      expect(store.value, _dark);
      expect(warnings, isEmpty);
    });

    test('a file with the old diffMarks key loads with the word marks on and a save drops the old key', () async {
      await file.writeAsString(_darkJson.replaceFirst('"diffWordMarks": true', '"diffMarks": "words"'));

      final SettingsStore store = await SettingsStore.load(file);

      expect(store.value, _dark);
      expect(store.value.general.diffWordMarks, isTrue);
      expect(warnings, isEmpty);
      expect(file.existsSync(), isTrue, reason: 'not moved aside as corrupt');
      await store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.light));
      await store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark));
      expect(file.readAsStringSync(), _darkJson);
    });

    for (final (String label, String content) in [
      ('invalid JSON', '{not json'),
      ('a top-level array', '[]'),
      ('a wrongly typed field', '{"appearance": 5}'),
      ('an unknown enum name', '{"appearance": {"themeMode": "purple"}}'),
    ]) {
      test('$label is moved aside and replaced by defaults', () async {
        await file.writeAsString(content);

        final SettingsStore store = await SettingsStore.load(file);

        expect(store.value, const AppSettings());
        expect(file.existsSync(), isFalse);
        expect(File('${file.path}.corrupt').readAsStringSync(), content);
        expect(warnings, hasLength(1));
        expect(warnings.single.message, isNot(contains(dir.path)));
      });
    }

    test('a corrupt file replaces an older backup', () async {
      await File('${file.path}.corrupt').writeAsString('old');
      await file.writeAsString('[]');

      await SettingsStore.load(file);

      expect(File('${file.path}.corrupt').readAsStringSync(), '[]');
    });
  });

  group('update', () {
    test('notifies synchronously and has written the file when it completes', () async {
      final SettingsStore store = await SettingsStore.load(file);
      final List<ThemeMode> seen = [];
      store.addListener(() => seen.add(store.value.appearance.themeMode));

      final Future<void> done = store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark));

      expect(seen, [ThemeMode.dark]);
      expect(store.value, _dark);
      await done;
      expect(file.readAsStringSync(), _darkJson);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('an unchanged value neither notifies nor writes', () async {
      final SettingsStore store = await SettingsStore.load(file);
      var notifications = 0;
      store.addListener(() => notifications++);

      await store.update((s) => s);

      expect(notifications, 0);
      expect(file.existsSync(), isFalse);
    });

    test('rapid updates persist in call order', () async {
      final SettingsStore store = await SettingsStore.load(file);

      await Future.wait([
        store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark)),
        store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.light)),
        store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark)),
      ]);

      expect(store.value, _dark);
      expect(file.readAsStringSync(), _darkJson);
    });

    test('a failed write reports the error, keeps the value and does not block later writes', () async {
      // A directory in the file's place makes the final rename fail.
      await Directory(file.path).create();
      final SettingsStore store = await SettingsStore.load(file);

      await expectLater(
        store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark)),
        throwsA(isA<FileSystemException>()),
      );

      expect(store.value, _dark);
      expect(warnings, hasLength(1));
      expect(warnings.single.message, isNot(contains(dir.path)));

      await Directory(file.path).delete();
      await store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.light));
      expect(jsonDecode(file.readAsStringSync()), _light.toJson());
    });

    test('settled completes after every queued write', () async {
      final SettingsStore store = await SettingsStore.load(file);

      unawaited(store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.light)));
      unawaited(store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark)));
      await store.settled;

      expect(file.readAsStringSync(), _darkJson);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('settled completes without the error when a queued write failed', () async {
      // A directory in the file's place makes the final rename fail.
      await Directory(file.path).create();
      final SettingsStore store = await SettingsStore.load(file);

      unawaited(
        store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark)).onError<FileSystemException>((_, _) {}),
      );

      await expectLater(store.settled, completes);
      expect(warnings, hasLength(1), reason: 'the failed write ran first');
    });
  });

  group('project states (Story 10.37)', () {
    const legacyJson =
        '{"projects": {"projects": [ '
        '{"path": "/r/a", "name": "a", "viewedFiles": ["kx:ab:a.txt"], "expandedStacks": ["kx"], '
        '"collapsedStacks": ["qm", "nq"]}, '
        '{"path": "/r/b", "name": "b", "viewedFiles": [], "expandedStacks": [], "collapsedStacks": []} '
        ']}}';
    const state = ProjectState(viewedFiles: ['kx:ab:a.txt'], expandedStacks: ['kx'], collapsedStacks: ['qm', 'nq']);

    Future<void> flushMicrotasks() => Future<void>.delayed(Duration.zero);

    test('an old settings.json moves the lists into the state file and is written once without them', () async {
      await file.writeAsString(legacyJson);

      final SettingsStore store = await SettingsStore.load(file);

      final String written = file.readAsStringSync();
      for (final key in ['viewedFiles', 'expandedStacks', 'collapsedStacks']) {
        expect(written, isNot(contains(key)));
      }
      final String id = store.value.projects.projects.first.stateId!;
      expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(store.value.projects.projects.last.stateId, isNull, reason: 'b had no view state');
      final stateFile = File('${dir.path}/projects/$id.json');
      expect(ProjectState.fromJson(jsonDecode(stateFile.readAsStringSync()) as Map<String, Object?>), state);
      expect(store.projectStates.of('/r/a')!.value, state);
      expect(warnings, isEmpty);
    });

    test('a failed state write keeps the lists in memory and the store falls back to them', () async {
      await file.writeAsString(legacyJson);
      // A file in the folder's place makes every state write fail.
      await File('${dir.path}/projects').writeAsString('');

      final SettingsStore store = await SettingsStore.load(file);

      expect(file.readAsStringSync(), isNot(contains('viewedFiles')));
      expect(store.projectStates.of('/r/a')!.value, state);
      expect(warnings, hasLength(1));
    });

    test('of: a path outside the registry has none; the first call gives the entry its state id', () async {
      final SettingsStore store = await SettingsStore.load(file);
      await store.update(
        (s) => s.copyWith(
          projects: const ProjectsSettings(
            projects: [ProjectEntry(path: '/r/a', name: 'a')],
          ),
        ),
      );
      var notified = 0;
      store.addListener(() => notified++);

      expect(store.projectStates.of('/r/none'), isNull);
      final ProjectStateStore? a = store.projectStates.of('/r/a');
      expect(a!.value, const ProjectState());
      expect(notified, 0, reason: 'the id is written in a microtask');
      expect(store.projectStates.of('/r/a'), same(a));

      await flushMicrotasks();
      await store.settled;
      final String id = store.value.projects.projects.single.stateId!;
      expect(a.file.path, '${store.projectStates.directory.path}/$id.json');
      expect(jsonDecode(file.readAsStringSync()), store.value.toJson());
      expect(store.projectStates.of('/r/a'), same(a));

      // Removed and added again: the entry gets a new id, and it is written.
      await store.projectStates.delete(id);
      await store.update(
        (s) => s.copyWith(
          projects: const ProjectsSettings(
            projects: [ProjectEntry(path: '/r/a', name: 'a')],
          ),
        ),
      );
      expect(store.projectStates.of('/r/a'), isNot(same(a)));
      await flushMicrotasks();
      await store.settled;
      expect(store.value.projects.projects.single.stateId, allOf(isNotNull, isNot(id)));
    });

    test('update notifies at once and writes the state file, never settings.json', () async {
      final SettingsStore store = await SettingsStore.load(file);
      await store.update(
        (s) => s.copyWith(
          projects: const ProjectsSettings(
            projects: [ProjectEntry(path: '/r/a', name: 'a', stateId: 'a1')],
          ),
        ),
      );
      final String before = file.readAsStringSync();
      final ProjectStateStore a = store.projectStates.of('/r/a')!;
      final List<ProjectState> seen = [];
      a.addListener(() => seen.add(a.value));

      final Future<void> done = a.update((s) => s.copyWith(expandedStacks: ['kx']));

      expect(seen, [
        const ProjectState(expandedStacks: ['kx']),
      ]);
      await done;
      expect(jsonDecode(File('${dir.path}/projects/a1.json').readAsStringSync()), {
        'viewedFiles': <Object?>[],
        'expandedStacks': ['kx'],
        'collapsedStacks': <Object?>[],
      });
      expect(file.readAsStringSync(), before);
      expect(File('${dir.path}/projects/a1.json.tmp').existsSync(), isFalse);

      await a.update((s) => s);
      expect(seen, hasLength(1), reason: 'an unchanged value neither notifies nor writes');
    });

    test('a failed write is logged and keeps the value', () async {
      final SettingsStore store = await SettingsStore.load(file);
      await store.update(
        (s) => s.copyWith(
          projects: const ProjectsSettings(
            projects: [ProjectEntry(path: '/r/a', name: 'a', stateId: 'a1')],
          ),
        ),
      );
      await Directory('${dir.path}/projects/a1.json').create(recursive: true);
      final ProjectStateStore a = store.projectStates.of('/r/a')!;

      await a.update((s) => s.copyWith(viewedFiles: ['k']));

      expect(a.value.viewedFiles, ['k']);
      expect(warnings, isNotEmpty);
      expect(warnings.last.message, isNot(contains(dir.path)));
    });

    test('an unreadable state file is logged and starts empty', () async {
      final SettingsStore store = await SettingsStore.load(file);
      await store.update(
        (s) => s.copyWith(
          projects: const ProjectsSettings(
            projects: [ProjectEntry(path: '/r/a', name: 'a', stateId: 'a1')],
          ),
        ),
      );
      await File('${dir.path}/projects/a1.json').create(recursive: true);
      await File('${dir.path}/projects/a1.json').writeAsString('{"viewedFiles": 5}');

      expect(store.projectStates.of('/r/a')!.value, const ProjectState());
      expect(warnings, hasLength(1));
    });

    test('delete removes the file after its pending writes, and the store writes nothing more', () async {
      final SettingsStore store = await SettingsStore.load(file);
      await store.update(
        (s) => s.copyWith(
          projects: const ProjectsSettings(
            projects: [ProjectEntry(path: '/r/a', name: 'a', stateId: 'a1')],
          ),
        ),
      );
      final ProjectStateStore a = store.projectStates.of('/r/a')!;
      final stateFile = File('${dir.path}/projects/a1.json');

      unawaited(a.update((s) => s.copyWith(viewedFiles: ['k'])));
      await store.projectStates.delete('a1');
      expect(stateFile.existsSync(), isFalse);

      await a.update((s) => s.copyWith(viewedFiles: ['j']));
      expect(stateFile.existsSync(), isFalse);

      await store.projectStates.delete('never-written');
      expect(warnings, isEmpty);
    });
  });

  test('open() loads from the application support directory', () async {
    PathProviderPlatform.instance = FakePathProvider(dir.path);
    await file.writeAsString(_darkJson);

    final SettingsStore store = await SettingsStore.open();

    expect(store.file.path, '${dir.path}/settings.json');
    expect(store.value, _dark);
  });
}
