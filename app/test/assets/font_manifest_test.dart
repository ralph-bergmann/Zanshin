// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  // Story 11.10 (I9): Yaru's Ubuntu fonts came without their licence, and the old `Zanshin` icon font is retired.
  test('the app bundles no Yaru, Ubuntu or old Zanshin icon font', () async {
    final Map<String, List<(String, int?)>> fonts = await _bundledFonts();
    for (final String family in fonts.keys) {
      expect(family.startsWith('packages/yaru/'), isFalse, reason: '$family is a Yaru font');
      expect(family.contains('Ubuntu'), isFalse, reason: '$family is an Ubuntu font');
      expect(family, isNot('Zanshin'), reason: '$family is the retired icon font');
    }
  });

  // OFL §2: every bundled copy of a font carries its copyright and licence. zanshin_ui lists each font folder's
  // OFL.txt under `flutter: licenses:`; flutter_tools appends those files verbatim to the bundle's NOTICES.
  test('the NOTICES the app bundles contain the OFL.txt of every zanshin_ui font', () async {
    final Map<String, List<(String, int?)>> fonts = await _bundledFonts();
    final folders = <String>{
      for (final MapEntry<String, List<(String, int?)>> family in fonts.entries)
        if (family.key.startsWith('packages/zanshin_ui/'))
          for (final (String asset, _) in family.value) asset.substring(0, asset.lastIndexOf('/')),
    };
    expect(folders, isNotEmpty, reason: 'FontManifest.json lists no zanshin_ui font');
    final ByteData compressed = await rootBundle.load('NOTICES.Z');
    final String notices = utf8.decode(
      gzip.decode(compressed.buffer.asUint8List(compressed.offsetInBytes, compressed.lengthInBytes)),
    );
    for (final folder in folders) {
      final String licence = File('../$folder/OFL.txt').readAsStringSync();
      // WHY the hint: `flutter test` rewrites build/unit_test_assets only when the app's pubspec or an asset file
      // is newer, never for a dependency's licence change. The gate's test-flutter task deletes its
      // AssetManifest.bin, so the gate always rebuilds the bundle; a manual run after such a change reads a stale
      // NOTICES.Z.
      expect(
        notices.contains(licence),
        isTrue,
        reason:
            '$folder/OFL.txt is not in the NOTICES (the gate rebuilds the test bundle; for a manual `flutter test` '
            'after editing an OFL.txt or a `licenses:` entry, delete app/build/unit_test_assets first)',
      );
    }
  });
}
