// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:ui' show Brightness, Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin/src/features/app/zanshin_app_view_model.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/recording_shell.dart';

const _darkShell = ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFFBF5AF2));
const _lightShell = ShellTheme(brightness: Brightness.light, accentColor: Color(0xFF0A84FF));

void main() {
  late Directory dir;
  late File file;
  late RecordingShell shell;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zanshin_app_view_model_test');
    file = File('${dir.path}/settings.json');
    shell = RecordingShell();
    ZanshinShellPlatform.instance = shell;
  });

  tearDown(() async {
    await shell.close();
    await dir.delete(recursive: true);
  });

  Future<ZanshinAppViewModel> viewModelWith(ThemeMode persisted) async {
    await file.writeAsString('{"appearance": {"themeMode": "${persisted.name}"}}');
    return ZanshinAppViewModel(await SettingsStore.load(file));
  }

  test('selectedMode reflects the persisted choice', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.dark);

    expect(vm.selectedMode, ThemeMode.dark);
    expect(vm.shellTheme, isNull);
    vm.dispose();
  });

  test('init mirrors the persisted choice onto the window and applies the shell theme', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.dark);
    var notifications = 0;
    vm
      ..addListener(() => notifications++)
      ..init();
    expect(shell.calls, ['getTheme', 'setWindowAppearance:dark']);

    shell.theme.complete(_darkShell);
    await pumpEventQueue();
    expect(vm.shellTheme, _darkShell);
    expect(notifications, 1);

    shell.changes.add(_lightShell);
    await pumpEventQueue();
    expect(vm.shellTheme, _lightShell);
    expect(notifications, 2);
    vm.dispose();
  });

  test('setThemeMode persists, mirrors onto the window and notifies', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.dark);
    var notifications = 0;
    vm.addListener(() => notifications++);

    await vm.setThemeMode(ThemeMode.light);

    expect(vm.selectedMode, ThemeMode.light);
    expect(notifications, 1);
    expect(shell.calls, ['setWindowAppearance:light']);
    expect(file.readAsStringSync(), contains('"light"'));
    vm.dispose();
  });

  test('effectiveMode resolves system through the shell theme', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.system);
    expect(vm.effectiveMode, ThemeMode.system);

    vm.init();
    shell.theme.complete(_darkShell);
    await pumpEventQueue();
    expect(vm.effectiveMode, ThemeMode.dark);

    await vm.setThemeMode(ThemeMode.light);
    expect(vm.effectiveMode, ThemeMode.light);
    vm.dispose();
  });

  test('an external store update notifies the view model', () async {
    final SettingsStore store = await SettingsStore.load(file);
    final vm = ZanshinAppViewModel(store);
    var notifications = 0;
    vm.addListener(() => notifications++);

    await store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark));

    expect(notifications, 1);
    expect(vm.selectedMode, ThemeMode.dark);
    vm.dispose();
  });

  test('after dispose neither a shell event nor a late theme answer is applied', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.system);
    vm
      ..init()
      ..dispose();

    shell.changes.add(_darkShell);
    shell.theme.complete(_darkShell);
    await pumpEventQueue();

    // A disposed ChangeNotifier asserts on notifyListeners; reaching here
    // without an error and with no theme applied is the assertion.
    expect(vm.shellTheme, isNull);
  });

  test('before the shell answers the appearance is the default one', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.system);
    expect(vm.appearance, const ZsAppearance());
    vm.dispose();
  });

  test('the appearance follows the effective mode, the accent source and the shell flags', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.system);
    vm.init();
    shell.theme.complete(
      const ShellTheme(
        brightness: Brightness.light,
        accentColor: Color(0xFF007AFF),
        appleAccentColor: 4,
        reduceMotion: true,
        reduceTransparency: true,
        increaseContrast: true,
      ),
    );
    await pumpEventQueue();
    expect(
      vm.appearance,
      const ZsAppearance(
        theme: ZsTheme.paper,
        family: ZsAccentFamily.blue,
        increasedContrast: true,
        reduceMotion: true,
        reduceTransparency: true,
      ),
    );

    await vm.setThemeMode(ThemeMode.dark);
    expect(vm.appearance.theme, ZsTheme.night);
    vm.dispose();
  });

  test('the Zanshin accent source shows moon whatever the shell reports', () async {
    await file.writeAsString('{"appearance": {"themeMode": "dark", "accentSource": "zanshin"}}');
    final vm = ZanshinAppViewModel(await SettingsStore.load(file))..init();
    shell.theme.complete(
      const ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF007AFF), appleAccentColor: 4),
    );
    await pumpEventQueue();
    expect(vm.appearance.family, ZsAccentFamily.multicolor);
    vm.dispose();
  });
}
