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
    '{\n  "appearance": {\n    "themeMode": "dark",\n    "accentSource": "followMacOS"\n  },\n'
    '  "layout": {\n    "inspectorWidth": 460.0,\n    "panelWidth": 300.0\n  },\n'
    '  "general": {\n    "hideControls": true\n  }\n}\n';

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
  });

  test('open() loads from the application support directory', () async {
    PathProviderPlatform.instance = FakePathProvider(dir.path);
    await file.writeAsString(_darkJson);

    final SettingsStore store = await SettingsStore.open();

    expect(store.file.path, '${dir.path}/settings.json');
    expect(store.value, _dark);
  });
}
