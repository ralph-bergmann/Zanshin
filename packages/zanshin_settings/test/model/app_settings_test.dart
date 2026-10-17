// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:freezed_annotation/freezed_annotation.dart' show CheckedFromJsonException;
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_settings/zanshin_settings.dart';

void main() {
  test('defaults follow the system theme', () {
    expect(const AppSettings().appearance.themeMode, ThemeMode.system);
  });

  test('a non-default value survives a JSON round trip', () {
    const settings = AppSettings(appearance: AppearanceSettings(themeMode: ThemeMode.dark));
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('toJson nests the sub-model as a map and encodes the enum by name', () {
    const settings = AppSettings(appearance: AppearanceSettings(themeMode: ThemeMode.dark));
    expect(settings.toJson(), {
      'appearance': {'themeMode': 'dark', 'accentSource': 'followMacOS'},
    });
  });

  test('a missing key takes its default', () {
    expect(AppearanceSettings.fromJson({}).themeMode, ThemeMode.system);
  });

  test('a settings file without accentSource follows the macOS accent', () {
    expect(AppearanceSettings.fromJson({'themeMode': 'dark'}).accentSource, AccentSource.followMacOS);
    expect(AppSettings.fromJson({'appearance': <String, Object?>{}}).appearance.accentSource, AccentSource.followMacOS);
  });

  test('the Zanshin accent source survives a JSON round trip', () {
    const settings = AppSettings(appearance: AppearanceSettings(accentSource: AccentSource.zanshin));
    expect(settings.toJson(), {
      'appearance': {'themeMode': 'system', 'accentSource': 'zanshin'},
    });
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('a missing sub-model takes its default', () {
    expect(AppSettings.fromJson({}), const AppSettings());
  });

  test('an unknown key is ignored', () {
    expect(AppSettings.fromJson({'unknown': 1}), const AppSettings());
  });

  test('a wrongly typed sub-model throws CheckedFromJsonException', () {
    expect(() => AppSettings.fromJson({'appearance': 5}), throwsA(isA<CheckedFromJsonException>()));
  });

  test('an unknown enum name throws CheckedFromJsonException', () {
    expect(
      () => AppearanceSettings.fromJson({'themeMode': 'purple'}),
      throwsA(isA<CheckedFromJsonException>()),
    );
  });
}
