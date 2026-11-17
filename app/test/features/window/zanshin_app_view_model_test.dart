// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:ui' show Brightness, Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin/src/features/window/code_font.dart';
import 'package:zanshin/src/features/window/zanshin_app_view_model.dart';
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

  late SettingsStore store;

  Future<ZanshinAppViewModel> viewModelWith(ThemeMode persisted) async {
    await file.writeAsString('{"appearance": {"themeMode": "${persisted.name}"}}');
    store = await SettingsStore.load(file);
    return ZanshinAppViewModel(store, _noFonts());
  }

  Future<void> setThemeMode(ThemeMode mode) => store.update((s) => s.copyWith.appearance(themeMode: mode));

  test('selectedMode reflects the persisted choice', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.dark);

    expect(vm.selectedMode, ThemeMode.dark);
    expect(vm.shellTheme, isNull);
    vm.dispose();
  });

  test('init applies the shell theme and leaves the window chrome to the appearance sync', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.dark);
    var notifications = 0;
    vm
      ..addListener(() => notifications++)
      ..init();
    expect(shell.calls, ['getTheme']);

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

  test('effectiveMode resolves system through the shell theme', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.system);
    expect(vm.effectiveMode, ThemeMode.system);

    vm.init();
    shell.theme.complete(_darkShell);
    await pumpEventQueue();
    expect(vm.effectiveMode, ThemeMode.dark);

    await setThemeMode(ThemeMode.light);
    expect(vm.effectiveMode, ThemeMode.light);
    vm.dispose();
  });

  test('an external store update notifies the view model', () async {
    final SettingsStore store = await SettingsStore.load(file);
    final vm = ZanshinAppViewModel(store, _noFonts());
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

    await setThemeMode(ThemeMode.dark);
    expect(vm.appearance.theme, ZsTheme.night);
    vm.dispose();
  });

  test('the Zanshin accent source shows moon whatever the shell reports', () async {
    await file.writeAsString('{"appearance": {"themeMode": "dark", "accentSource": "zanshin"}}');
    final vm = ZanshinAppViewModel(await SettingsStore.load(file), _noFonts())..init();
    shell.theme.complete(
      const ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF007AFF), appleAccentColor: 4),
    );
    await pumpEventQueue();
    expect(vm.appearance.family, ZsAccentFamily.multicolor);
    vm.dispose();
  });

  test('the code style follows the saved font and size and the installed list', () async {
    await file.writeAsString('{"general": {"codeFont": "Menlo", "codeSize": 14}}');
    final fonts = InstalledCodeFonts.withReader(() async => const ['Monaco']);
    final SettingsStore store = await SettingsStore.load(file);
    final vm = ZanshinAppViewModel(store, fonts);
    var notifications = 0;
    vm.addListener(() => notifications++);

    expect(vm.codeStyle.fontFamily, 'Menlo', reason: 'the list is unknown: the saved family as is');
    expect(vm.codeStyle.fontSize, 14);

    await fonts.refresh();
    expect(notifications, 1);
    expect(vm.codeStyle.fontFamily, ZsType.monoFamily, reason: 'Menlo is not installed');

    await store.update((s) => s.copyWith.general(codeFont: 'Monaco', codeSize: 12));
    expect(vm.codeStyle.fontFamily, 'Monaco');
    expect(vm.codeStyle.fontSize, 12);
    vm.dispose();
  });
}

InstalledCodeFonts _noFonts() => InstalledCodeFonts.withReader(() async => null);
