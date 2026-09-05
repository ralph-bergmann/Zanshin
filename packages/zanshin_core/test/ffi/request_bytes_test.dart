// SPDX-License-Identifier: MIT

// Message-contract tests for [rejectInteriorNul], the single producer of the
// interior-NUL [ArgumentError] for every FFI adapter that takes a caller-supplied
// string (six request-buffer adapters plus mutate.dart's three C-string ones).
//
// Every OTHER NUL test in this package matches on the `throwsArgumentError` TYPE
// only, so before this file the literal message and the `name` argument were
// asserted nowhere: rewording the message or dropping a `name` would have kept the
// whole gate green. Since the 2026-09-05 dedupe there is exactly one place to
// reword, which makes that regression cheaper to cause and cheaper to pin.
//
// The NUL is always written as the `\u0000` escape rather than as a literal byte,
// so the test source stays greppable and diffable.
//
// No cdylib required — this is a pure argument guard.

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/request_bytes.dart';

void main() {
  group('rejectInteriorNul', () {
    const expectedMessage = 'must not contain an interior NUL (U+0000)';

    test('throws with the exact message, name and invalid value', () {
      expect(
        () => rejectInteriorNul('a\u0000b', 'changeId'),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.message, 'message', expectedMessage)
              .having((e) => e.name, 'name', 'changeId')
              .having((e) => e.invalidValue, 'invalidValue', 'a\u0000b'),
        ),
      );
    });

    test('carries through whatever name the call site passed', () {
      expect(
        () => rejectInteriorNul('\u0000', 'remoteName'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'remoteName')),
      );
    });

    test('rejects a NUL anywhere in the string, including at either end', () {
      for (final value in <String>['\u0000lead', 'trail\u0000', 'mid\u0000dle']) {
        expect(
          () => rejectInteriorNul(value, 'path'),
          throwsArgumentError,
          reason: value.codeUnits.toString(),
        );
      }
    });

    test('accepts a NUL-free string, empty included', () {
      expect(() => rejectInteriorNul('main', 'name'), returnsNormally);
      expect(() => rejectInteriorNul('', 'name'), returnsNormally);
    });

    // Null means ABSENT, not empty — the guard must pass it through so an optional
    // argument stays optional.
    test('accepts null', () {
      expect(() => rejectInteriorNul(null, 'revision'), returnsNormally);
    });
  });

  group('rejectInteriorNuls', () {
    const expectedMessage = 'must not contain an interior NUL (U+0000)';

    // The list form reports the OFFENDING ENTRY as `invalidValue` while keeping
    // the LIST's parameter name — the only place that pairing is asserted.
    test('reports the offending entry with the list parameter name', () {
      expect(
        () => rejectInteriorNuls(<String>['ok', 'a\u0000b', 'also-ok'], 'names'),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.message, 'message', expectedMessage)
              .having((e) => e.name, 'name', 'names')
              .having((e) => e.invalidValue, 'invalidValue', 'a\u0000b'),
        ),
      );
    });

    test('throws on the FIRST offending entry', () {
      expect(
        () => rejectInteriorNuls(<String>['first\u0000', 'second\u0000'], 'paths'),
        throwsA(isA<ArgumentError>().having((e) => e.invalidValue, 'invalidValue', 'first\u0000')),
      );
    });

    test('accepts an empty list', () {
      expect(() => rejectInteriorNuls(const <String>[], 'names'), returnsNormally);
    });

    test('accepts a NUL-free list, empty strings included', () {
      expect(() => rejectInteriorNuls(<String>['main', '', 'feature/x'], 'names'), returnsNormally);
    });
  });
}
