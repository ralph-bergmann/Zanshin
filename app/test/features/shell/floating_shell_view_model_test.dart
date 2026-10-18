// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/shell/floating_shell_view_model.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('floating_shell_view_model_test');
    file = File('${dir.path}/settings.json');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<SettingsStore> store(String json) async {
    await file.writeAsString(json);
    return SettingsStore.load(file);
  }

  /// Waits past the write debounce (a timer never fires early, so the margin only covers the clock's step).
  Future<void> pastDebounce() =>
      Future<void>.delayed(FloatingShellViewModel.writeDelay + const Duration(milliseconds: 50));

  /// Counts the store's changes: `update` notifies synchronously, before its file write, so the assertions never wait
  /// on the disk.
  int Function() countWrites(SettingsStore settings) {
    var writes = 0;
    void count() => writes++;
    settings.addListener(count);
    addTearDown(() => settings.removeListener(count));
    return () => writes;
  }

  /// Waits for every write the store has queued, so the test directory is not deleted under one: writes run in
  /// order, so awaiting one more (a change of its own) awaits them all.
  Future<void> drain(SettingsStore settings) =>
      settings.update((s) => s.copyWith.general(hideControls: !s.general.hideControls));

  test('the shell starts from the stored widths and Hide controls', () async {
    final vm = FloatingShellViewModel(
      await store('{"layout": {"inspectorWidth": 512, "panelWidth": 260}, "general": {"hideControls": false}}'),
    );
    addTearDown(vm.dispose);
    expect(vm.shell.panelWidth, 260);
    expect(vm.shell.inspectorWidth, 512);
    expect(vm.shell.hideControls, isFalse);
  });

  test('without layout and general the defaults 460 / 300 / on apply', () async {
    final vm = FloatingShellViewModel(await store('{}'));
    addTearDown(vm.dispose);
    expect(vm.shell.panelWidth, 300);
    expect(vm.shell.inspectorWidth, 460);
    expect(vm.shell.hideControls, isTrue);
  });

  test('switching Hide controls off in the store stops calm scrolling at once, without a restart', () async {
    final SettingsStore settings = await store('{}');
    final vm = FloatingShellViewModel(settings);
    addTearDown(vm.dispose);
    vm.shell.reportUserScroll(40);
    expect(vm.shell.calm.value.calm, isTrue);
    await settings.update((s) => s.copyWith.general(hideControls: false));
    expect(vm.shell.hideControls, isFalse);
    expect(vm.shell.calm.value.calm, isFalse);
    vm.shell.reportUserScroll(40);
    expect(vm.shell.calm.value.calm, isFalse);
  });

  test('a live drag writes nothing; commits write once, after the debounce, with both widths', () async {
    final SettingsStore settings = await store('{}');
    final int Function() writes = countWrites(settings);
    final vm = FloatingShellViewModel(settings);
    addTearDown(vm.dispose);
    vm.shell
      ..panelWidth = 320
      ..panelWidth = 340;
    await pastDebounce();
    expect(writes(), 0, reason: 'the drag itself is never written');
    vm.shell
      ..commitPanelWidth(350)
      ..commitPanelWidth(360)
      ..commitInspectorWidth(500);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(writes(), 0, reason: 'the write trails the last commit');
    await pastDebounce();
    expect(writes(), 1);
    expect(settings.value.layout, const LayoutSettings(inspectorWidth: 500, panelWidth: 360));
    await drain(settings);
  });

  test('an out-of-range stored width is used clamped and stays stored as it is until the user resizes', () async {
    final SettingsStore settings = await store('{"layout": {"panelWidth": 900}}');
    final int Function() writes = countWrites(settings);
    final vm = FloatingShellViewModel(settings);
    addTearDown(vm.dispose);
    expect(vm.shell.panelWidth, 900, reason: 'the shell clamps it to 440 where it lays out');
    await pastDebounce();
    expect(writes(), 0);
    expect(settings.value.layout.panelWidth, 900);
  });

  test('dispose flushes a pending write in a microtask, outside the unmount that disposes it', () async {
    final SettingsStore settings = await store('{}');
    FloatingShellViewModel(settings)
      ..shell.commitPanelWidth(280)
      ..dispose();
    expect(settings.value.layout.panelWidth, 300, reason: 'not while the tree unmounts');
    await Future<void>.delayed(Duration.zero);
    expect(settings.value.layout, const LayoutSettings(panelWidth: 280));
    await drain(settings);
  });
}
