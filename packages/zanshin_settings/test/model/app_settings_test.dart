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
      'layout': {'inspectorWidth': 460.0, 'panelWidth': 300.0},
      'general': {'hideControls': true},
      'projects': {'projects': <Object?>[], 'groups': <Object?>[], 'openProject': null},
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
      'layout': {'inspectorWidth': 460.0, 'panelWidth': 300.0},
      'general': {'hideControls': true},
      'projects': {'projects': <Object?>[], 'groups': <Object?>[], 'openProject': null},
    });
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('the layout widths default to 460 and 300, Hide controls to on', () {
    const settings = AppSettings();
    expect(settings.layout.inspectorWidth, 460);
    expect(settings.layout.panelWidth, 300);
    expect(settings.general.hideControls, isTrue);
  });

  test('a file without layout and general, or with them partial, takes the defaults for what is missing', () {
    expect(AppSettings.fromJson({'appearance': <String, Object?>{}}).layout, const LayoutSettings());
    expect(AppSettings.fromJson({'appearance': <String, Object?>{}}).general, const GeneralSettings());
    final partial = AppSettings.fromJson({
      'layout': {'panelWidth': 360},
      'general': <String, Object?>{},
    });
    expect(partial.layout, const LayoutSettings(panelWidth: 360));
    expect(partial.general.hideControls, isTrue);
  });

  test('changed widths and Hide controls off survive a JSON round trip', () {
    const settings = AppSettings(
      layout: LayoutSettings(inspectorWidth: 512, panelWidth: 255.5),
      general: GeneralSettings(hideControls: false),
    );
    expect(settings.toJson()['layout'], {'inspectorWidth': 512.0, 'panelWidth': 255.5});
    expect(settings.toJson()['general'], {'hideControls': false});
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('an out-of-range width is kept as stored; the shell clamps it where it uses it', () {
    expect(LayoutSettings.fromJson({'panelWidth': 900}).panelWidth, 900);
  });

  test('a wrongly typed width or flag throws CheckedFromJsonException', () {
    expect(() => LayoutSettings.fromJson({'panelWidth': 'wide'}), throwsA(isA<CheckedFromJsonException>()));
    expect(() => GeneralSettings.fromJson({'hideControls': 'yes'}), throwsA(isA<CheckedFromJsonException>()));
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
