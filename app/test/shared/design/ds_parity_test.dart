// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart' as vgc;
import 'package:zanshin/src/shared/design/zs_appearance.dart';
import 'package:zanshin/src/shared/design/zs_colors.dart';
import 'package:zanshin/src/shared/design/zs_elevation.dart';
import 'package:zanshin/src/shared/design/zs_metrics.dart';
import 'package:zanshin/src/shared/design/zs_motion.dart';
import 'package:zanshin/src/shared/design/zs_type.dart';
import 'package:zanshin/src/shared/widgets/zanshin_icon.dart';

import 'css_token_reader.dart';

/// Every appearance the parity test resolves: 2 themes × 9 families × the contrast, transparency and inactive deltas,
/// and the theme-independent groups under reduce motion and full screen as well.
final _appearances = <ZsAppearance>[
  for (final ZsTheme theme in ZsTheme.values)
    for (final ZsAccentFamily family in ZsAccentFamily.values)
      for (final increasedContrast in const <bool>[false, true])
        for (final reduceTransparency in const <bool>[false, true])
          for (final inactive in const <bool>[false, true])
            for (final reduceMotion in const <bool>[false, true])
              for (final fullScreen in const <bool>[false, true])
                ZsAppearance(
                  theme: theme,
                  family: family,
                  increasedContrast: increasedContrast,
                  reduceTransparency: reduceTransparency,
                  inactive: inactive,
                  reduceMotion: reduceMotion,
                  fullScreen: fullScreen,
                ),
];

/// The token layer's view of [appearance]: every group's `toCss()`.
Map<String, Object?> _appTokens(ZsAppearance appearance) => <String, Object?>{
  ...ZsColors.resolve(appearance).toCss(),
  ...ZsElevation.resolve(appearance).toCss(),
  ...ZsMetrics.resolve(appearance).toCss(),
  ...(appearance.reduceMotion ? ZsMotion.reduced : ZsMotion.full).toCss(),
  ...ZsType.toCss(),
};

/// Every mismatch between [sheet] and the token layer over [appearances].
List<String> _mismatches(CssTokenSheet sheet, Iterable<ZsAppearance> appearances) => <String>[
  for (final ZsAppearance appearance in appearances)
    ...compareTokens(sheet.resolve(appearance), _appTokens(appearance), appearanceLabel(appearance)),
];

/// [files] with [from] replaced by [to] in [file]; the replacement must hit.
Map<String, String> _edited(Map<String, String> files, String file, String from, String to) {
  final String text = files[file]!;
  expect(text, contains(from), reason: 'the fixture edit must find its text in $file');
  return <String, String>{...files, file: text.replaceFirst(from, to)};
}

// ---- icons ----------------------------------------------------------------------------------------------------------

const _dsIcons = '$dsRoot/assets/icons';
const _appIcons = 'assets/icons/svg';

/// The one glyph the set check tolerates by name: no DS file, kept until 11.10 removes its mock users.
const _leftover = 'workstream';

/// The copy step of item 11: the C2PA download stamp removed, every other byte kept.
List<int> _stripStamp(List<int> bytes) => latin1.encode(
  latin1
      .decode(bytes)
      .replaceAll(RegExp('<metadata>.*?</metadata>', dotAll: true), '')
      .replaceAll(' xmlns:c2pa="http://c2pa.org/manifest"', ''),
);

Map<String, List<int>> _svgFiles(String directory) => <String, List<int>>{
  for (final FileSystemEntity entity in Directory(directory).listSync())
    if (entity is File && entity.path.endsWith('.svg'))
      entity.uri.pathSegments.last.replaceAll('.svg', ''): entity.readAsBytesSync(),
};

/// The icon set check (decision 16.33): the DS files, `glyphs.json`, the app files and the [ZI] values are one set
/// (minus [_leftover]), every app file equals its DS file after the strip, and no [ZI] value is a retired alias.
List<String> _iconMismatches({
  required Map<String, List<int>> ds,
  required Map<String, List<int>> app,
  required List<String> glyphs,
  required Map<String, String> aliases,
  required List<String> zi,
}) {
  final Set<String> appNames = app.keys.toSet()..remove(_leftover);
  final Set<String> ziNames = zi.toSet()..remove(_leftover);
  final Set<String> glyphNames = glyphs.toSet();
  return <String>[
    for (final String name in <String>{...ds.keys, ...glyphNames, ...appNames, ...ziNames}) ...<String>[
      if (!glyphNames.contains(name)) '$name: not in glyphs.json',
      if (!ds.containsKey(name)) '$name: no DS file',
      if (!appNames.contains(name)) '$name: no app file',
      if (!ziNames.contains(name)) '$name: no ZI constant',
      if (ds.containsKey(name) && appNames.contains(name) && !listEquals(_stripStamp(ds[name]!), app[name]))
        '$name: the app file differs from the DS file after the strip',
    ],
    for (final String alias in aliases.keys)
      if (zi.contains(alias)) 'ZI "$alias": a retired alias, use "${aliases[alias]}"',
  ];
}

/// The file rules of DS readme.md:352 that `vector_graphics_compiler` cannot check itself: it parses the file with
/// warnings as errors (asserts are on under `flutter test`, so an unsupported element throws), and the attributes it
/// would drop silently are checked here.
List<String> _lintSvg(String name, String xml) {
  final problems = <String>[];
  try {
    vgc.parseWithoutOptimizers(xml, key: name, warningsAsErrors: true);
  } on Object catch (error) {
    problems.add('$name: vector_graphics_compiler rejects it ($error)');
  }
  for (final RegExpMatch element in RegExp(r'<(\w+)([^>]*)>').allMatches(xml)) {
    final String tag = element.group(1)!;
    if (tag == 'style') {
      problems.add('$name: a <style> element');
    }
    final attributes = <String, String>{
      for (final RegExpMatch a in RegExp(r'([\w:-]+)="([^"]*)"').allMatches(element.group(2)!))
        a.group(1)!: a.group(2)!,
    };
    for (final MapEntry<String, String>(key: attribute, :value) in attributes.entries) {
      if (const <String>{'class', 'style', 'id', 'transform', 'filter'}.contains(attribute)) {
        problems.add('$name: <$tag $attribute>');
      }
      if (const <String>{'fill', 'stroke', 'color', 'stop-color'}.contains(attribute) &&
          value != 'currentColor' &&
          value != 'none') {
        problems.add('$name: <$tag $attribute="$value">, only currentColor or none');
      }
      if (!attribute.startsWith('xmlns') && RegExp(r'\d*\.\d{3,}').hasMatch(value)) {
        problems.add('$name: <$tag $attribute> has more than 2 decimals');
      }
    }
    if (tag == 'rect') {
      final double half =
          (double.tryParse(attributes['width'] ?? '') ?? 0) < (double.tryParse(attributes['height'] ?? '') ?? 0)
          ? (double.tryParse(attributes['width'] ?? '') ?? 0) / 2
          : (double.tryParse(attributes['height'] ?? '') ?? 0) / 2;
      for (final radius in const <String>['rx', 'ry']) {
        final double? value = double.tryParse(attributes[radius] ?? '');
        if (value != null && value > half) {
          problems.add('$name: <rect $radius="$value"> is more than half the shorter side ($half)');
        }
      }
    }
  }
  return problems;
}

void main() {
  late Map<String, String> files;
  late CssTokenSheet sheet;

  setUpAll(() {
    files = CssTokenSheet.readFiles();
    sheet = CssTokenSheet.parse(files);
  });

  group('DS tokens', () {
    test('every token group contributes distinct names', () {
      const appearance = ZsAppearance();
      final groups = <Map<String, Object?>>[
        ZsColors.resolve(appearance).toCss(),
        ZsElevation.resolve(appearance).toCss(),
        ZsMetrics.resolve(appearance).toCss(),
        ZsMotion.full.toCss(),
        ZsType.toCss(),
      ];
      expect(_appTokens(appearance).length, groups.fold<int>(0, (sum, group) => sum + group.length));
    });

    test('every custom property of every DS token file matches in every appearance', () {
      expect(_appearances, hasLength(576));
      final List<String> mismatches = _mismatches(sheet, _appearances);
      expect(mismatches.take(40).toList(), isEmpty, reason: '${mismatches.length} mismatches');
    });

    test('every @media copy equals its attribute twin', () {
      expect(sheet.mediaDrift(), isEmpty);
    });

    test('the night and paper constants are the resolutions without any delta', () {
      expect(ZsColors.night, ZsColors.resolve(const ZsAppearance()));
      expect(ZsColors.paper, ZsColors.resolve(const ZsAppearance(theme: ZsTheme.paper)));
      expect(ZsElevation.night, ZsElevation.resolve(const ZsAppearance()));
      expect(ZsElevation.paper, ZsElevation.resolve(const ZsAppearance(theme: ZsTheme.paper)));
    });

    test(':is() selectors are flattened: paper, inactive and increased contrast give --accent-line #26242c', () {
      // DS tokens/inactive.css:26-27 with the rules beneath them; a naive extractor that drops the :is() rule
      // keeps the night line #e7e9f2.
      final fixture = CssTokenSheet.parse(<String, String>{
        'tokens/colors.css': '''
:root,[data-theme="night"]{--accent-line:#aebcec}
[data-theme="paper"],[data-theme="light"]{--accent-line:#4757a1}
''',
        'tokens/inactive.css': '''
[data-window="inactive"]{--accent-line:#8189a5}
[data-window="inactive"][data-theme="paper"],[data-window="inactive"][data-theme="light"]{--accent-line:#867e75}
[data-window="inactive"][data-contrast="more"]{--accent-line:#e7e9f2}
[data-window="inactive"][data-contrast="more"]:is([data-theme="paper"],[data-theme="light"]),
:is([data-theme="paper"],[data-theme="light"]) [data-window="inactive"][data-contrast="more"]{--accent-line:#26242c}
''',
      });
      const appearance = ZsAppearance(theme: ZsTheme.paper, inactive: true, increasedContrast: true);
      expect(fixture.resolveRaw(appearance)['--accent-line'], '#26242c');
      expect(fixture.resolveRaw(appearance.copyWith(theme: ZsTheme.night))['--accent-line'], '#e7e9f2');
      expect(sheet.resolveRaw(appearance)['--accent-line'], '#26242c');
    });

    test('a changed token fails and names the token, both values and the appearance', () {
      final List<String> mismatches = _mismatches(
        CssTokenSheet.parse(_edited(files, 'tokens/colors.css', '--card-solid:#1a1f35;', '--card-solid:#1a1f36;')),
        const <ZsAppearance>[ZsAppearance()],
      );
      expect(mismatches, hasLength(greaterThanOrEqualTo(1)));
      expect(
        mismatches.where((m) => m.startsWith('--card-solid ')).single,
        allOf(contains('night'), contains('multicolor'), contains('the DS says #1a1f36'), contains('layer #1a1f35')),
      );
    });

    test('an added token fails and names the token', () {
      final List<String> mismatches = _mismatches(
        CssTokenSheet.parse(
          _edited(files, 'tokens/spacing.css', '--minimap-w:134px;', '--minimap-w:134px;--zs-added:1px;'),
        ),
        const <ZsAppearance>[ZsAppearance()],
      );
      expect(mismatches.single, startsWith('--zs-added [night, multicolor]: in the DS'));
    });

    test('a removed token fails and names the token', () {
      final List<String> mismatches = _mismatches(
        CssTokenSheet.parse(_edited(files, 'tokens/spacing.css', '--minimap-w:134px;', '')),
        const <ZsAppearance>[ZsAppearance()],
      );
      expect(mismatches.single, startsWith('--minimap-w [night, multicolor]: in the token layer'));
    });

    test('an @media copy that drifts from its attribute twin fails and names the token', () {
      final String transparency = files['tokens/transparency.css']!;
      final int media = transparency.indexOf('@media');
      final drifted = CssTokenSheet.parse(<String, String>{
        ...files,
        'tokens/transparency.css':
            transparency.substring(0, media) +
            transparency.substring(media).replaceFirst('--scrim:rgba(7,9,20,.62)', '--scrim:rgba(7,9,20,.63)'),
      });
      expect(drifted.mediaDrift().single, allOf(startsWith('--scrim '), contains('.63'), contains('.62')));
    });
  });

  group('DS icons', () {
    late Map<String, List<int>> ds;
    late Map<String, List<int>> app;
    late List<String> glyphs;
    late Map<String, String> aliases;

    setUpAll(() {
      ds = _svgFiles('$_dsIcons/ui');
      app = _svgFiles(_appIcons);
      final json = jsonDecode(File('$_dsIcons/glyphs.json').readAsStringSync()) as Map<String, Object?>;
      glyphs = (json['names']! as List<Object?>).cast<String>();
      aliases = (json['aliases']! as Map<String, Object?>).cast<String, String>();
    });

    test('the DS glyphs, the app files and the ZI constants are one set, byte for byte after the strip', () {
      expect(glyphs, hasLength(58));
      expect(_iconMismatches(ds: ds, app: app, glyphs: glyphs, aliases: aliases, zi: ZI.all), isEmpty);
    });

    test('every app glyph follows the DS file rules', () {
      expect(<String>[
        for (final MapEntry<String, List<int>>(:key, :value) in app.entries) ..._lintSvg(key, latin1.decode(value)),
      ], isEmpty);
    });

    test('a changed glyph fails and names it', () {
      expect(
        _iconMismatches(
          ds: <String, List<int>>{
            ...ds,
            'plus': <int>[...ds['plus']!, 0x20],
          },
          app: app,
          glyphs: glyphs,
          aliases: aliases,
          zi: ZI.all,
        ),
        <String>['plus: the app file differs from the DS file after the strip'],
      );
    });

    test('an added glyph fails and names it', () {
      expect(
        _iconMismatches(
          ds: <String, List<int>>{...ds, 'extra': ds['plus']!},
          app: app,
          glyphs: <String>[...glyphs, 'extra'],
          aliases: aliases,
          zi: ZI.all,
        ),
        <String>['extra: no app file', 'extra: no ZI constant'],
      );
    });

    test('a removed glyph fails and names it', () {
      expect(
        _iconMismatches(
          ds: <String, List<int>>{...ds}..remove('plus'),
          app: app,
          glyphs: <String>[...glyphs]..remove('plus'),
          aliases: aliases,
          zi: ZI.all,
        ),
        <String>['plus: not in glyphs.json', 'plus: no DS file'],
      );
    });

    test('a ZI value equal to a retired alias fails and names it', () {
      expect(
        _iconMismatches(ds: ds, app: app, glyphs: glyphs, aliases: aliases, zi: <String>[...ZI.all, 'download']),
        <String>[
          'download: not in glyphs.json',
          'download: no DS file',
          'download: no app file',
          'ZI "download": a retired alias, use "fetch"',
        ],
      );
    });

    test('a <style> element fails the lint and names the glyph', () {
      final String xml = <String>[
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">',
        '<style>path{stroke:red}</style>',
        '<g fill="none" stroke="currentColor" stroke-width="1.5"><path d="M2 2h12"></path></g></svg>',
      ].join();
      expect(_lintSvg('styled', xml), contains('styled: a <style> element'));
    });

    test('an rx larger than half the shorter side fails the lint and names the glyph', () {
      final String xml = <String>[
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">',
        '<g fill="none" stroke="currentColor" stroke-width="1.5">',
        '<rect x="5" y="1.75" width="6" height="2.5" rx="1.5"></rect></g></svg>',
      ].join();
      expect(_lintSvg('move-only', xml), <String>[
        'move-only: <rect rx="1.5"> is more than half the shorter side (1.25)',
      ]);
    });

    test('an rx of exactly half the shorter side passes the lint', () {
      expect(_lintSvg('move-only', latin1.decode(app['move-only']!)), isEmpty);
    });
  });
}
