// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'settle_settings.dart';

void main() {
  testWidgets('the drain puts a write on disk that a finished write queued', (tester) async {
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('settle_settings_test')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/settings.json');
    final SettingsStore store = (await tester.runAsync(() => SettingsStore.load(file)))!;

    unawaited(
      store
          .update((s) => s.copyWith.appearance(zoom: 110))
          .then((_) => store.update((s) => s.copyWith.appearance(zoom: 125))),
    );
    await settleSettingsWrites(tester, store);

    final String json = (await tester.runAsync(file.readAsString))!;
    expect((jsonDecode(json) as Map<String, Object?>)['appearance'], containsPair('zoom', 125));
  });
}
