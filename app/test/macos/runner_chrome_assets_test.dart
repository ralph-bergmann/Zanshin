// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The runner's asset catalogue (`flutter test` runs in `app/`).
const _assets = 'macos/Runner/Assets.xcassets';

/// The app icon's Icon Composer bundle and the DS bundle its layers come from.
const _appIcon = 'macos/Runner/NamiIndigo.icon';
const _dsAppIcon = '../_bmad-output/implementation-artifacts/design_system/assets/app-icon/Zanshin-NamiIndigo.icon';

/// [colour] as the `#rrggbb` an SVG stroke takes.
String _hex(Color colour) => '#${(colour.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';

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

  // Icon Composer paints a layer's solid fill over the region an open stroke path encloses (the waves turned into
  // crescents, Story 11.10), so each layer is the DS geometry stroked in its gold and takes no layer fill.
  test('the app icon holds the DS wave layers, stroked in --gold-200/400/600, with no layer fill', () {
    final json = jsonDecode(File('$_appIcon/icon.json').readAsStringSync()) as Map<String, Object?>;
    final List<Map<String, Object?>> groups = (json['groups']! as List<Object?>).cast<Map<String, Object?>>();
    final layers = <Map<String, Object?>>[
      for (final group in groups) ...(group['layers']! as List<Object?>).cast<Map<String, Object?>>(),
    ];
    final expected = <(String, Color)>[
      ('Wave-Top', css['--gold-200']! as Color),
      ('Wave-Mid', css['--gold-400']! as Color),
      ('Wave-Bottom', css['--gold-600']! as Color),
    ];
    expect(layers.map((layer) => layer['name']), expected.map(((String, Color) layer) => layer.$1));
    for (final (int i, (String name, Color stroke)) in expected.indexed) {
      final Map<String, Object?> layer = layers[i];
      expect(layer['image-name'], '$name.svg', reason: name);
      expect(layer['fill'], 'none', reason: name);
      final String ds = File('$_dsAppIcon/Assets/$name.svg').readAsStringSync();
      expect(ds, contains('stroke="#ffffff"'), reason: 'the DS layer $name is drawn white for its fill');
      expect(
        File('$_appIcon/Assets/$name.svg').readAsStringSync().trimRight(),
        ds.replaceFirst('stroke="#ffffff"', 'stroke="${_hex(stroke)}"').trimRight(),
        reason: '$name.svg is the DS layer with another stroke colour',
      );
    }
    final List<String> files = Directory(
      '$_appIcon/Assets',
    ).listSync().map((e) => e.uri.pathSegments.last).where((name) => !name.startsWith('.')).toList()..sort();
    expect(files, <String>['Wave-Bottom.svg', 'Wave-Mid.svg', 'Wave-Top.svg']);
  });
}
