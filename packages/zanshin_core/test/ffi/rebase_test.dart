// SPDX-License-Identifier: MIT

// Calling-side contract tests for Story 9.16's three adapters (rebase,
// parallelize, arrange) and Story 9.14's simplify-parents: the interior-NUL
// guards, which fire BEFORE any FFI call, so a raw handle of 0 never reaches
// the cdylib, the sealed `ArrangeAction` model, and the
// `SimplifyParentsResult` decoder. The other three answer the shared
// `MutationResult`, whose decoder test/ffi/mutate_test.dart owns; the round
// trips through the real cdylib live in test/worker/rebase_test.dart.
//
// Mirrors packages/zanshin_core/test/ffi/squash_split_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/rebase.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('interior-NUL guards fire before the FFI call', () {
    const nul = 'a\u0000b';

    test('zanshinRebase refuses a NUL in every id list', () {
      expect(() => zanshinRebase(0, branch: const [nul]), throwsArgumentError);
      expect(() => zanshinRebase(0, source: const [nul]), throwsArgumentError);
      expect(() => zanshinRebase(0, revisions: const [nul]), throwsArgumentError);
      expect(() => zanshinRebase(0, onto: const [nul]), throwsArgumentError);
      expect(() => zanshinRebase(0, insertAfter: const [nul]), throwsArgumentError);
      expect(() => zanshinRebase(0, insertBefore: const [nul]), throwsArgumentError);
    });

    test('zanshinParallelize refuses a NUL in a change id', () {
      expect(() => zanshinParallelize(0, const [nul]), throwsArgumentError);
    });

    test('zanshinArrange refuses a NUL in a revision or an action', () {
      expect(() => zanshinArrange(0, revisions: const [nul]), throwsArgumentError);
      expect(() => zanshinArrange(0, actions: const [AbandonAction(nul)]), throwsArgumentError);
    });

    test('zanshinSimplifyParents refuses a NUL in a source or a revision', () {
      expect(() => zanshinSimplifyParents(0, source: const [nul]), throwsArgumentError);
      expect(() => zanshinSimplifyParents(0, revisions: const [nul]), throwsArgumentError);
    });
  });

  group('decodeSimplifyParentsResultEnvelope', () {
    Matcher ffiCode(String code) => throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', code));

    test('decodes the nested mutation, the four counts and the warnings', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.SimplifyParentsResult,
        data: fbs.SimplifyParentsResultObjectBuilder(
          mutation: fbs.MutationResultObjectBuilder(newOpId: 'op', workingCopyChangeId: 'wc'),
          numTargetCommits: 6,
          numSimplifiedCommits: 2,
          numRemovedEdges: 3,
          numRebasedDescendants: 4,
        ),
        warnings: [fbs.WarningObjectBuilder(code: ZanshinWarningCode.revsetDiagnostic, message: 'm')],
      ).toBytes();
      final SimplifyParentsResult result = decodeSimplifyParentsResultEnvelope(bytes);
      expect(result.mutation.newOpId, 'op');
      expect(result.mutation.workingCopyChangeId, 'wc');
      expect(
        (result.numTargetCommits, result.numSimplifiedCommits, result.numRemovedEdges, result.numRebasedDescendants),
        (6, 2, 3, 4),
      );
      expect(result.warnings.map((w) => w.code), [ZanshinWarningCode.revsetDiagnostic]);
      expect(result.mutation.warnings, isEmpty, reason: 'the nested mutation carries none of its own');
    });

    test('an error envelope throws its code; another payload is ffi.unknown', () {
      final Uint8List error = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.immutable', context: '0000'),
      ).toBytes();
      expect(() => decodeSimplifyParentsResultEnvelope(error), ffiCode('jj.immutable'));
      final Uint8List other = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(newOpId: 'op'),
      ).toBytes();
      expect(() => decodeSimplifyParentsResultEnvelope(other), ffiCode('ffi.unknown'));
    });
  });

  test('every ArrangeAction carries its change id', () {
    const List<ArrangeAction> actions = [SwapDownAction('d'), SwapUpAction('u'), AbandonAction('a'), KeepAction('k')];
    expect(actions.map((a) => a.changeId), ['d', 'u', 'a', 'k']);
    expect(
      actions.map(
        (a) => switch (a) {
          SwapDownAction() => 'J',
          SwapUpAction() => 'K',
          AbandonAction() => 'a',
          KeepAction() => 'p',
        },
      ),
      ['J', 'K', 'a', 'p'],
    );
  });
}
