// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.15's two decoders (squash plan, split),
// using synthetic FlatBuffers buffers built via the generated
// `*ObjectBuilder`s. No real cdylib required — these tests exercise the
// Dart-side decode logic in isolation and mirror the Rust round-trips in
// crates/zanshin-ffi/src/envelope.rs (AR-P-7 parity). `zanshin_squash` answers
// the shared `MutationResult`, whose decoder test/ffi/mutate_test.dart owns.
//
// Also covers the three adapters' interior-NUL guards, which fire BEFORE any FFI
// call, so a raw handle of 0 never reaches the cdylib.
//
// Mirrors packages/zanshin_core/test/ffi/workspace_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/squash_split.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// An error envelope carrying [code].
Uint8List errorEnvelope(String code, String context) => fbs.EnvelopeObjectBuilder(
  ok: false,
  error: fbs.FfiErrorObjectBuilder(code: code, context: context),
).toBytes();

/// An ok envelope whose union variant is deliberately the WRONG one.
Uint8List wrongPayload() => fbs.EnvelopeObjectBuilder(
  ok: true,
  dataType: fbs.PayloadTypeId.RepoHandle,
  data: fbs.RepoHandleObjectBuilder(handle: 0),
).toBytes();

final Matcher _unknown = throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'));

void main() {
  group('decodeSquashPlanEnvelope decode contract', () {
    test('decodes the combined text and the warnings', () {
      final SquashPlan plan = decodeSquashPlanEnvelope(
        fbs.EnvelopeObjectBuilder(
          ok: true,
          dataType: fbs.PayloadTypeId.SquashPlan,
          data: fbs.SquashPlanObjectBuilder(combinedDescription: 'B\n\nC\n'),
          warnings: [fbs.WarningObjectBuilder(code: 'jj.paths_unmatched', message: 'm')],
        ).toBytes(),
      );

      expect(plan.combinedDescription, 'B\n\nC\n');
      expect(plan.warnings.single.code, ZanshinWarningCode.pathsUnmatched);
    });

    test('an absent text is null, never an empty string', () {
      final SquashPlan plan = decodeSquashPlanEnvelope(
        fbs.EnvelopeObjectBuilder(
          ok: true,
          dataType: fbs.PayloadTypeId.SquashPlan,
          data: fbs.SquashPlanObjectBuilder(),
        ).toBytes(),
      );

      expect(plan.combinedDescription, isNull);
      expect(plan.warnings, isEmpty);
    });

    test('throws ZanshinFfiException on an error envelope', () {
      expect(
        () => decodeSquashPlanEnvelope(errorEnvelope('jj.invalid_input', 'boom')),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'boom'),
        ),
      );
    });

    test('throws ffi.unknown on a non-SquashPlan payload', () {
      expect(() => decodeSquashPlanEnvelope(wrongPayload()), _unknown);
    });
  });

  group('decodeSplitResultEnvelope decode contract', () {
    Uint8List split({String? selected = 's', String? remaining = 'r'}) => fbs.EnvelopeObjectBuilder(
      ok: true,
      dataType: fbs.PayloadTypeId.SplitResult,
      data: fbs.SplitResultObjectBuilder(
        mutation: fbs.MutationResultObjectBuilder(
          newOpId: 'op',
          newChangeIds: const ['r'],
          abandonedChangeIds: const [],
          workingCopyChangeId: 'r',
        ),
        selectedChangeId: selected,
        remainingChangeId: remaining,
      ),
      warnings: [fbs.WarningObjectBuilder(code: 'jj.split_all_selected', message: 'm')],
    ).toBytes();

    test('decodes both parts, the nested mutation and the warnings', () {
      final SplitResult r = decodeSplitResultEnvelope(split());

      expect(r.selectedChangeId, 's');
      expect(r.remainingChangeId, 'r');
      expect(r.mutation.newOpId, 'op');
      expect(r.mutation.newChangeIds, ['r']);
      expect(r.mutation.workingCopyChangeId, 'r');
      expect(r.mutation.warnings, isEmpty, reason: 'the enclosing result carries them');
      expect(r.warnings.single.code, ZanshinWarningCode.splitAllSelected);
    });

    test('a missing change id is refused, not defaulted', () {
      expect(() => decodeSplitResultEnvelope(split(selected: null)), _unknown);
      expect(() => decodeSplitResultEnvelope(split(remaining: null)), _unknown);
    });

    test('throws ZanshinFfiException on an error envelope and ffi.unknown on a wrong payload', () {
      expect(
        () => decodeSplitResultEnvelope(errorEnvelope('jj.immutable', 'abc')),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.immutable')),
      );
      expect(() => decodeSplitResultEnvelope(wrongPayload()), _unknown);
    });
  });

  group('adapter interior-NUL guards', () {
    test('every string argument of the three adapters is checked before the FFI call', () {
      const nul = 'a\u0000b';
      expect(() => zanshinSquash(0, revision: nul), throwsArgumentError);
      expect(() => zanshinSquash(0, from: const [nul]), throwsArgumentError);
      expect(() => zanshinSquash(0, into: nul), throwsArgumentError);
      expect(() => zanshinSquashPlan(0, paths: const [nul]), throwsArgumentError);
      expect(() => zanshinSquashPlan(0, message: const [nul]), throwsArgumentError);
      expect(() => zanshinSplit(0, paths: const [nul]), throwsArgumentError);
      expect(() => zanshinSplit(0, paths: const ['p'], revision: nul), throwsArgumentError);
      expect(() => zanshinSplit(0, paths: const ['p'], message: const [nul]), throwsArgumentError);
      expect(() => zanshinSplit(0, paths: const ['p'], onto: const [nul]), throwsArgumentError);
      expect(() => zanshinSplit(0, paths: const ['p'], insertAfter: const [nul]), throwsArgumentError);
      expect(() => zanshinSplit(0, paths: const ['p'], insertBefore: const [nul]), throwsArgumentError);
      expect(() => zanshinSquash(0, editedDescription: nul), throwsArgumentError);
      expect(() => zanshinSplit(0, paths: const ['p'], editedSelectedDescription: nul), throwsArgumentError);
      expect(() => zanshinSplit(0, paths: const ['p'], editedRemainingDescription: nul), throwsArgumentError);
    });
  });
}
