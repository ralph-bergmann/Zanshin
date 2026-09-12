// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/bootstrap/splash_card.dart';

import '../../../tool/gen_grain_tile.dart' as generator;

/// Guards the one committed binary the splash card needs: without this, the
/// tile and its generator could drift apart unnoticed, and neither is
/// reviewable by reading the diff.
void main() {
  // Plain `test`, not `testWidgets`: reading the file needs real IO, which a
  // widget test's fake-async zone never completes.
  test('the committed tile is byte-for-byte what the generator writes', () async {
    // Seeded, so the same SDK writes the same bytes. If a Dart upgrade changes
    // `Random`'s sequence this fails: re-run `dart run tool/gen_grain_tile.dart`
    // and commit the tile it produces.
    final Uint8List committed = await File(splashGrainAsset).readAsBytes();

    expect(generator.grainTilePng(), committed);
  });

  testWidgets('the bundled tile decodes at the size the card tiles with', (tester) async {
    await tester.runAsync(() async {
      // Through `rootBundle`, so this also pins `splashGrainAsset` against the
      // asset entry in `pubspec.yaml` — a typo in either fails here.
      final ByteData data = await rootBundle.load(splashGrainAsset);
      final ui.Codec codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final ui.FrameInfo frame = await codec.getNextFrame();
      addTearDown(frame.image.dispose);
      codec.dispose();

      expect(frame.image.width, generator.tileSize);
      expect(frame.image.height, generator.tileSize);
    });
  });
}
