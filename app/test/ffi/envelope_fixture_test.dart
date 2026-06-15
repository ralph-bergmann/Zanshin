// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/ffi/envelope_zanshin.ffi_generated.dart';

/// Cross-side wire-contract check (AC-5): a committed FlatBuffers buffer produced
/// by the `flatc` toolchain (`flatc --binary`, the same compiler that generates
/// the Dart accessors) is parsed through the generated typed accessors. This
/// proves the Rust/`flatc` wire output and the Dart reader agree on the
/// `Envelope` shape — the Dart half of the contract. The Rust half (build +
/// Verifier roundtrip) lives in `crates/zanshin-ffi/src/lib.rs` and
/// `ffi_strings.rs`.
///
/// A wrong-shape regression in the generated Dart accessors (e.g. a future
/// `flatc --dart` change) makes this fail to compile or read, instead of going
/// unnoticed until a later story wires up a real FFI producer.
///
/// Regenerate the fixture after an `envelope.fbs` change (deliberate step —
/// fixtures are committed, never rebuilt at test time):
///   flatc --binary -o test-fixtures/ffi schemas/envelope.fbs \
///       test-fixtures/ffi/envelope_error.json
void main() {
  group('Envelope wire-contract fixture', () {
    late Uint8List bytes;

    setUpAll(() {
      bytes = _readFixture('envelope_error.bin');
    });

    test('decodes an error envelope through the generated accessors', () {
      final env = Envelope(bytes);

      expect(env.ok, isFalse);

      final FfiError? error = env.error;
      expect(error, isNotNull);
      expect(error!.code, 'jj.repo_not_found');
      expect(error.context, '/no/such/path');

      // ok == false → no payload set (Payload::NONE / absent).
      expect(env.data, isNull);
      expect(env.dataType, anyOf(isNull, equals(PayloadTypeId.NONE)));
    });
  });
}

/// Locate a fixture under `test-fixtures/ffi/` whether the test runner's CWD is
/// the Flutter package (`app/`, the `cargo make test` path) or the repo root.
Uint8List _readFixture(String name) {
  const dirs = ['../test-fixtures/ffi', 'test-fixtures/ffi'];
  for (final dir in dirs) {
    final file = File('$dir/$name');
    if (file.existsSync()) {
      return file.readAsBytesSync();
    }
  }
  fail(
    'Fixture "$name" not found. Looked in: '
    '${dirs.map((d) => '$d/$name').join(', ')} '
    '(run from the Flutter package or the repo root).',
  );
}
