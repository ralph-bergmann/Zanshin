// SPDX-License-Identifier: MIT

/// Writes `assets/images/grain_128.png`, the splash card's grain tile.
///
/// The design's grain is an SVG `feTurbulence` field. Dart cannot compute that
/// per frame, so the card paints a committed tile instead, repeated over the
/// whole card and blended in soft-light at 16 %. The tile is *not* that field:
/// it is uniform per-pixel white noise, a deliberate simplification of the
/// design's band-limited fractal noise, which at `baseFrequency 0.9` is close
/// to per-pixel anyway and indistinguishable at 16 % soft-light.
///
/// The noise is seeded, so the same Dart SDK reproduces the same tile —
/// `dart:math`'s `Random` sequence is only stable within one SDK version.
///
/// Run from `app/`: `dart run tool/gen_grain_tile.dart`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Edge length of the tile in pixels.
const tileSize = 128;

/// Noise seed, so the committed tile is reproducible.
const noiseSeed = 0x5A414E; // "ZAN"

/// Where the tile is written, relative to the `app/` package root.
const outputPath = 'assets/images/grain_128.png';

Future<void> main() async {
  final file = File(outputPath);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(grainTilePng());
  stdout.writeln('wrote $outputPath (${await file.length()} bytes, ${tileSize}x$tileSize)');
}

/// The tile as PNG bytes: 8-bit greyscale, no interlacing, filter "none".
Uint8List grainTilePng() {
  final random = Random(noiseSeed);
  final pixels = Uint8List(tileSize * tileSize);
  for (var i = 0; i < pixels.length; i++) {
    pixels[i] = random.nextInt(256);
  }
  return _png(pixels);
}

Uint8List _png(Uint8List pixels) {
  final scanlines = BytesBuilder();
  for (var y = 0; y < tileSize; y++) {
    scanlines
      ..addByte(0) // filter type 0: no prediction
      ..add(Uint8List.sublistView(pixels, y * tileSize, (y + 1) * tileSize));
  }

  final out = BytesBuilder()..add(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  _chunk(out, 'IHDR', <int>[
    ..._be32(tileSize),
    ..._be32(tileSize),
    8, // bit depth
    0, // colour type: greyscale
    0, // compression: deflate
    0, // filter method: adaptive
    0, // interlace: none
  ]);
  _chunk(out, 'IDAT', ZLibCodec(level: 9).encode(scanlines.takeBytes()));
  _chunk(out, 'IEND', const <int>[]);
  return out.toBytes();
}

void _chunk(BytesBuilder out, String type, List<int> data) {
  final body = <int>[...ascii.encode(type), ...data];
  out
    ..add(_be32(data.length))
    ..add(body)
    ..add(_be32(_crc32(body)));
}

List<int> _be32(int value) => <int>[(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF];

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});
