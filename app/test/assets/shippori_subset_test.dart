// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Every code point the `cmap` table of the TrueType font [bytes] maps to a glyph, over its format 4 and format 12
/// subtables.
Set<int> _mappedCodePoints(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final int tables = data.getUint16(4);
  int? cmap;
  for (var i = 0; i < tables; i++) {
    final int record = 12 + i * 16;
    if (String.fromCharCodes(bytes.sublist(record, record + 4)) == 'cmap') {
      cmap = data.getUint32(record + 8);
    }
  }
  if (cmap == null) {
    throw const FormatException('no cmap table');
  }
  final codePoints = <int>{};
  final int subtables = data.getUint16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final int subtable = cmap + data.getUint32(cmap + 4 + i * 8 + 4);
    switch (data.getUint16(subtable)) {
      case 4:
        final int segments = data.getUint16(subtable + 6) ~/ 2;
        final int ends = subtable + 14;
        final int starts = ends + segments * 2 + 2;
        final int deltas = starts + segments * 2;
        final int rangeOffsets = deltas + segments * 2;
        for (var s = 0; s < segments; s++) {
          final int start = data.getUint16(starts + s * 2);
          final int end = data.getUint16(ends + s * 2);
          final int delta = data.getUint16(deltas + s * 2);
          final int rangeOffset = data.getUint16(rangeOffsets + s * 2);
          for (var c = start; c <= end && c != 0xFFFF; c++) {
            int glyph;
            if (rangeOffset == 0) {
              glyph = (c + delta) & 0xFFFF;
            } else {
              glyph = data.getUint16(rangeOffsets + s * 2 + rangeOffset + (c - start) * 2);
              if (glyph != 0) {
                glyph = (glyph + delta) & 0xFFFF;
              }
            }
            if (glyph != 0) {
              codePoints.add(c);
            }
          }
        }
      case 12:
        final int groups = data.getUint32(subtable + 12);
        for (var g = 0; g < groups; g++) {
          final int group = subtable + 16 + g * 12;
          final int start = data.getUint32(group);
          final int end = data.getUint32(group + 4);
          final int glyph = data.getUint32(group + 8);
          for (var c = start; c <= end; c++) {
            if (glyph + c - start != 0) {
              codePoints.add(c);
            }
          }
        }
    }
  }
  return codePoints;
}

void main() {
  for (final weight in const <String>['Medium', 'SemiBold']) {
    test('Shippori Mincho $weight maps exactly 残 and 心', () {
      final Uint8List bytes = File('assets/fonts/Shippori_Mincho/ShipporiMincho-$weight.ttf').readAsBytesSync();
      expect(_mappedCodePoints(bytes), <int>{0x6B8B, 0x5FC3});
    });
  }
}
