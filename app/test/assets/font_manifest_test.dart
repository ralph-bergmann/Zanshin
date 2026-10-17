// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The app bundle's fonts by family: each family's (asset, weight) pairs, read from `FontManifest.json`.
Future<Map<String, List<(String, int?)>>> _bundledFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<Object?>;
  return <String, List<(String, int?)>>{
    for (final Map<String, Object?> entry in manifest.cast<Map<String, Object?>>())
      entry['family']! as String: <(String, int?)>[
        for (final Map<String, Object?> font in (entry['fonts']! as List<Object?>).cast<Map<String, Object?>>())
          (font['asset']! as String, font['weight'] as int?),
      ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Flutter registers a dependency's fonts as `packages/<package>/<family>`; only the app's bundle shows that name,
  // so this is where the ZsType constants meet the fonts zanshin_ui declares.
  test('every ZsType family is a font family the app bundles, with its files', () async {
    final Map<String, List<(String, int?)>> fonts = await _bundledFonts();
    for (final family in <String>[ZsType.sansFamily, ZsType.monoFamily, ZsType.kanjiFamily]) {
      expect(fonts[family], isNotEmpty, reason: '$family is not in FontManifest.json');
      for (final (String asset, _) in fonts[family]!) {
        expect((await rootBundle.load(asset)).lengthInBytes, greaterThan(0), reason: asset);
      }
    }
    expect(
      fonts[ZsType.kanjiFamily]!.map(((String, int?) font) => font.$2),
      <int>[500, 600],
      reason: 'the 残心 subset ships the two weights the splash uses',
    );
  });
}
