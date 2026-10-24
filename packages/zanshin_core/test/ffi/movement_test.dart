// SPDX-License-Identifier: MIT

// Calling-side contract tests for Story 9.10's two adapters (moveWorkingCopy,
// movementTargets): the guards that fire BEFORE any FFI call, so a raw handle
// of 0 never reaches the cdylib, and the `MovementTargets` decoder over
// synthetic envelopes. The move answers the shared `MutationResult`, whose
// decoder test/ffi/mutate_test.dart owns; the round trips through the real
// cdylib live in test/worker/movement_test.dart.
//
// Mirrors packages/zanshin_core/test/ffi/metaedit_duplicate_fix_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/movement.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('guards fire before the FFI call', () {
    test('zanshinMoveWorkingCopy refuses a NUL in target and a negative offset', () {
      expect(() => zanshinMoveWorkingCopy(0, target: 'a\u0000b'), throwsArgumentError);
      expect(() => zanshinMoveWorkingCopy(0, offset: -1), throwsArgumentError);
    });

    test('zanshinMovementTargets refuses a negative offset', () {
      expect(() => zanshinMovementTargets(0, offset: -1), throwsArgumentError);
    });
  });

  group('decodeMovementTargetsEnvelope', () {
    Uint8List targetsEnvelope(List<fbs.MovementTargetObjectBuilder>? targets) => fbs.EnvelopeObjectBuilder(
      ok: true,
      dataType: fbs.PayloadTypeId.MovementTargets,
      data: fbs.MovementTargetsObjectBuilder(edit: true, targets: targets),
      warnings: [fbs.WarningObjectBuilder(code: ZanshinWarningCode.configDeprecated, message: 'm')],
    ).toBytes();

    Matcher ffiCode(String code) => throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', code));

    test('decodes edit, the candidates in order and the warnings', () {
      final MovementTargets result = decodeMovementTargetsEnvelope(
        targetsEnvelope([
          fbs.MovementTargetObjectBuilder(commitId: 'c1', changeId: 'k1'),
          fbs.MovementTargetObjectBuilder(commitId: 'c2', changeId: 'k2'),
        ]),
      );
      expect(result.edit, isTrue);
      expect(result.targets.map((t) => (t.commitId, t.changeId)), [('c1', 'k1'), ('c2', 'k2')]);
      expect(result.warnings.map((w) => w.code), [ZanshinWarningCode.configDeprecated]);
    });

    test('an absent targets vector is empty', () {
      expect(decodeMovementTargetsEnvelope(targetsEnvelope(null)).targets, isEmpty);
    });

    test('a candidate without one of its ids is a malformed buffer', () {
      expect(
        () => decodeMovementTargetsEnvelope(targetsEnvelope([fbs.MovementTargetObjectBuilder(changeId: 'k')])),
        ffiCode('ffi.unknown'),
      );
      expect(
        () => decodeMovementTargetsEnvelope(targetsEnvelope([fbs.MovementTargetObjectBuilder(commitId: 'c')])),
        ffiCode('ffi.unknown'),
      );
    });

    test('an error envelope throws its code and hints; another payload is ffi.unknown', () {
      final Uint8List error = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'jj.invalid_input',
          context: 'The working copy must not have any children',
          hints: ['Create a new commit on top of this one or use `--edit`'],
        ),
      ).toBytes();
      expect(
        () => decodeMovementTargetsEnvelope(error),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input').having((e) => e.hints, 'hints', [
            'Create a new commit on top of this one or use `--edit`',
          ]),
        ),
      );
      final Uint8List other = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(newOpId: 'op'),
      ).toBytes();
      expect(() => decodeMovementTargetsEnvelope(other), ffiCode('ffi.unknown'));
    });
  });
}
