// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

void main() {
  test('the module provides the store it was built with', () async {
    final Directory dir = await Directory.systemTemp.createTemp('zanshin_settings_module_test');
    addTearDown(() => dir.delete(recursive: true));
    final SettingsStore store = await SettingsStore.load(File('${dir.path}/settings.json'));

    expect(SettingsModule(store: store).settingsStore(), same(store));
  });
}
