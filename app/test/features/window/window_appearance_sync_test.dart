// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin/src/features/window/window_appearance_sync.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import '../../helpers/recording_shell.dart';

void main() {
  late Directory dir;
  late RecordingShell shell;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('window_appearance_sync_test');
    ZanshinShellPlatform.instance = shell = RecordingShell();
  });

  tearDown(() async {
    await shell.close();
    await dir.delete(recursive: true);
  });

  Future<SettingsStore> storeWith(ThemeMode persisted) async {
    final file = File('${dir.path}/settings.json');
    await file.writeAsString('{"appearance": {"themeMode": "${persisted.name}"}}');
    return SettingsStore.load(file);
  }

  test('start mirrors the persisted theme onto the native chrome; a theme switch sends the new one once', () async {
    final SettingsStore store = await storeWith(ThemeMode.dark);
    final sync = WindowAppearanceSync(store);
    expect(shell.calls, isEmpty, reason: 'nothing before start');

    sync.start();
    expect(shell.calls, <String>['setWindowAppearance:dark']);

    await store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.light));
    expect(shell.calls, <String>['setWindowAppearance:dark', 'setWindowAppearance:light']);

    await store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.system));
    expect(shell.calls.last, 'setWindowAppearance:system');
  });

  test('a zoom or density change sends no appearance', () async {
    final SettingsStore store = await storeWith(ThemeMode.light);
    WindowAppearanceSync(store).start();
    shell.calls.clear();

    await store.update((s) => s.copyWith.appearance(zoom: 125));
    await store.update((s) => s.copyWith.appearance(density: DensitySetting.comfy));

    expect(shell.calls, isEmpty);
  });
}
