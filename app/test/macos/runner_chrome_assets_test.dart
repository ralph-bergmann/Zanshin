// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The runner's asset catalogue (`flutter test` runs in `app/`).
const _assets = 'macos/Runner/Assets.xcassets';

/// The any (aqua) and the dark (darkAqua) colour of the colour set [name].
({Color any, Color dark}) _colourSet(String name) {
  final json = jsonDecode(File('$_assets/$name.colorset/Contents.json').readAsStringSync()) as Map<String, Object?>;
  Color? any;
  Color? dark;
  for (final entry in json['colors']! as List<Object?>) {
    final map = entry! as Map<String, Object?>;
    final color = map['color']! as Map<String, Object?>;
    expect(color['color-space'], 'srgb', reason: name);
    final components = color['components']! as Map<String, Object?>;
    int channel(String key) => int.parse((components[key]! as String).substring(2), radix: 16);
    final value = Color.fromARGB(
      (double.parse(components['alpha']! as String) * 255).round(),
      channel('red'),
      channel('green'),
      channel('blue'),
    );
    if (map['appearances'] == null) {
      any = value;
    } else {
      expect(map['appearances'], <Object?>[
        <String, Object?>{'appearance': 'luminosity', 'value': 'dark'},
      ], reason: name);
      dark = value;
    }
  }
  return (any: any!, dark: dark!);
}

/// Matches [expected] channel by channel within 1/255.
Matcher _near(Color expected) => predicate<Color>(
  (actual) =>
      (actual.a - expected.a).abs() <= 1 / 255 &&
      (actual.r - expected.r).abs() <= 1 / 255 &&
      (actual.g - expected.g).abs() <= 1 / 255 &&
      (actual.b - expected.b).abs() <= 1 / 255,
  'within 1/255 of $expected',
);

void main() {
  final Map<String, Object> css = ZsColors.night.toCss();

  for (final (String name, Color any, Color dark) in <(String, Color, Color)>[
    ('AccentColor', css['--accent-native']! as Color, css['--accent-native-dark']! as Color),
    ('CanvasBase', ZsColors.paper.canvasBase, ZsColors.night.canvasBase),
    ('TrafficLightRing', ZsColors.paper.tlRing, ZsColors.night.tlRing),
    // The dialog windows' base under the window fill (Story 11.12): `--fl-bg-solid`.
    ('WindowFillBase', ZsColors.paper.flBgSolid, ZsColors.night.flBgSolid),
  ]) {
    test('the $name colour set holds the token in any (paper) and dark (night)', () {
      final ({Color any, Color dark}) colours = _colourSet(name);
      expect(colours.any, _near(any));
      expect(colours.dark, _near(dark));
    });
  }

  test('every colour MainWindowChrome.swift names has its colour set', () {
    final String swift = File('macos/Runner/MainWindowChrome.swift').readAsStringSync();
    final names = <String>{
      for (final RegExpMatch match in RegExp(r'NSColor\(named: "([^"]+)"\)').allMatches(swift)) match.group(1)!,
    };
    expect(names, containsAll(<String>['CanvasBase', 'TrafficLightRing', 'WindowFillBase']));
    for (final name in names) {
      expect(File('$_assets/$name.colorset/Contents.json').existsSync(), isTrue, reason: name);
    }
  });

  test('the Runner target names AccentColor as the app accent in Debug, Release and Profile', () {
    final String project = File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect('ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;'.allMatches(project), hasLength(3));
  });
}
