// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.49's `commit`, using synthetic FlatBuffers
// buffers built via the generated `*ObjectBuilder`s. No real cdylib required.
// `zanshin_commit` answers the shared `MutationResult`, decoded through
// `mutate.dart`'s one decoder (whose own contract test/ffi/mutate_test.dart
// owns): these tests pin that a commit envelope — the new `@`, the
// `jj.commit_paths_unmatched` warning, a refusal — decodes through it.
//
// Also covers the adapter's interior-NUL guards, which fire BEFORE any FFI
// call, so a raw handle of 0 never reaches the cdylib.
//
// Mirrors packages/zanshin_core/test/ffi/squash_split_test.dart.

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/commit.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/mutate.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('a commit envelope decodes as the shared MutationResult', () {
    test('the new @ and the unmatched-paths warning', () {
      final MutationResult r = decodeMutationResultEnvelope(
        fbs.EnvelopeObjectBuilder(
          ok: true,
          dataType: fbs.PayloadTypeId.MutationResult,
          data: fbs.MutationResultObjectBuilder(
            newOpId: 'op',
            newChangeIds: const ['n'],
            abandonedChangeIds: const [],
            workingCopyChangeId: 'n',
          ),
          warnings: [
            fbs.WarningObjectBuilder(
              code: 'jj.commit_paths_unmatched',
              message: 'The given paths do not match any file: nope.txt',
            ),
          ],
        ).toBytes(),
      );

      expect(r.newOpId, 'op');
      expect(r.newChangeIds, ['n']);
      expect(r.workingCopyChangeId, 'n');
      expect(r.warnings.single.code, ZanshinWarningCode.commitPathsUnmatched);
      expect(r.warnings.single.message, 'The given paths do not match any file: nope.txt');
    });

    test('a refusal throws ZanshinFfiException with its code', () {
      expect(
        () => decodeMutationResultEnvelope(
          fbs.EnvelopeObjectBuilder(ok: false, error: fbs.FfiErrorObjectBuilder(code: 'jj.no_working_copy')).toBytes(),
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.no_working_copy')),
      );
    });
  });

  group('adapter interior-NUL guards', () {
    test('every string argument is checked before the FFI call', () {
      const nul = 'a\u0000b';
      expect(() => zanshinCommit(0, message: const [nul]), throwsArgumentError);
      expect(() => zanshinCommit(0, message: const ['m'], paths: const [nul]), throwsArgumentError);
    });
  });
}
