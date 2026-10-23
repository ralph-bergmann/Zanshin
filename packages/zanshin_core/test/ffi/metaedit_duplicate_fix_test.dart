// SPDX-License-Identifier: MIT

// Calling-side contract tests for Story 9.9's three adapters (metaedit,
// duplicate, fix): the interior-NUL guards, which fire BEFORE any FFI call, so
// a raw handle of 0 never reaches the cdylib, and the `FixResult` decoder over
// synthetic envelopes. `metaedit` and `duplicate` answer the shared
// `MutationResult`, whose decoder test/ffi/mutate_test.dart owns; the round
// trips through the real cdylib live in
// test/worker/metaedit_duplicate_fix_test.dart.
//
// Mirrors packages/zanshin_core/test/ffi/rebase_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/metaedit_duplicate_fix.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('interior-NUL guards fire before the FFI call', () {
    const nul = 'a\u0000b';

    test('zanshinMetaedit refuses a NUL in every string field', () {
      expect(() => zanshinMetaedit(0, revisions: const [nul]), throwsArgumentError);
      expect(() => zanshinMetaedit(0, message: const [nul]), throwsArgumentError);
      expect(() => zanshinMetaedit(0, author: nul), throwsArgumentError);
      expect(() => zanshinMetaedit(0, authorTimestamp: nul), throwsArgumentError);
    });

    test('zanshinDuplicate refuses a NUL in every id list', () {
      expect(() => zanshinDuplicate(0, revisions: const [nul]), throwsArgumentError);
      expect(() => zanshinDuplicate(0, onto: const [nul]), throwsArgumentError);
      expect(() => zanshinDuplicate(0, insertAfter: const [nul]), throwsArgumentError);
      expect(() => zanshinDuplicate(0, insertBefore: const [nul]), throwsArgumentError);
    });

    test('zanshinFix refuses a NUL in a source or a path', () {
      expect(() => zanshinFix(0, source: const [nul]), throwsArgumentError);
      expect(() => zanshinFix(0, paths: const [nul]), throwsArgumentError);
    });
  });

  group('decodeFixResultEnvelope', () {
    Uint8List fixEnvelope({List<fbs.FixToolStderrObjectBuilder>? stderr}) => fbs.EnvelopeObjectBuilder(
      ok: true,
      dataType: fbs.PayloadTypeId.FixResult,
      data: fbs.FixResultObjectBuilder(
        mutation: fbs.MutationResultObjectBuilder(newOpId: 'op', workingCopyChangeId: 'wc'),
        numFixedCommits: 2,
        numCheckedCommits: 3,
        toolStderr: stderr,
      ),
      warnings: [fbs.WarningObjectBuilder(code: ZanshinWarningCode.fixToolFailed, message: 'm')],
    ).toBytes();

    Matcher ffiCode(String code) => throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', code));

    test('decodes the nested mutation, both counts, the stderr and the warnings', () {
      final FixResult result = decodeFixResultEnvelope(
        fixEnvelope(
          stderr: [fbs.FixToolStderrObjectBuilder(path: 'a.txt', stderr: 'oops\n')],
        ),
      );
      expect(result.mutation.newOpId, 'op');
      expect(result.mutation.workingCopyChangeId, 'wc');
      expect((result.numFixedCommits, result.numCheckedCommits), (2, 3));
      expect(result.toolStderr.map((e) => (e.path, e.stderr)), [('a.txt', 'oops\n')]);
      expect(result.warnings.map((w) => w.code), [ZanshinWarningCode.fixToolFailed]);
      expect(result.mutation.warnings, isEmpty, reason: 'the nested mutation carries none of its own');
    });

    test('an absent stderr vector is empty', () {
      expect(decodeFixResultEnvelope(fixEnvelope()).toolStderr, isEmpty);
    });

    test('a stderr entry without its path or text is a malformed buffer', () {
      expect(
        () => decodeFixResultEnvelope(fixEnvelope(stderr: [fbs.FixToolStderrObjectBuilder(stderr: 'x')])),
        ffiCode('ffi.unknown'),
      );
      expect(
        () => decodeFixResultEnvelope(fixEnvelope(stderr: [fbs.FixToolStderrObjectBuilder(path: 'a.txt')])),
        ffiCode('ffi.unknown'),
      );
    });

    test('an error envelope throws its code; another payload is ffi.unknown', () {
      final Uint8List error = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.config_error', context: 'No `fix.tools` are configured'),
      ).toBytes();
      expect(() => decodeFixResultEnvelope(error), ffiCode('jj.config_error'));
      final Uint8List other = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(newOpId: 'op'),
      ).toBytes();
      expect(() => decodeFixResultEnvelope(other), ffiCode('ffi.unknown'));
    });
  });
}
