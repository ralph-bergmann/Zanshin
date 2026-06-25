// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeRemotesEnvelope] using synthetic FlatBuffers
// buffers built via the generated `*ObjectBuilder`s. No real cdylib required —
// these tests exercise the Dart-side decode logic in isolation.
//
// Populated remotes (including credential URL) are exercised here because
// committed fixtures have no configured remotes; the live cdylib path for the
// extern fn is covered by the worker round-trip test
// (test/worker/remotes_test.dart).

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/remotes.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('decodeRemotesEnvelope decode contract', () {
    // ── Error envelope ────────────────────────────────────────────────────────

    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'jj.jj_lib_error',
          context: 'git backend error',
        ),
      ).toBytes();

      expect(
        () => decodeRemotesEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.jj_lib_error')
              .having((e) => e.context, 'context', 'git backend error'),
        ),
      );
    });

    // ── Wrong payload type ────────────────────────────────────────────────────

    test('throws ffi.unknown on ok envelope with non-Remotes payload', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeRemotesEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'),
        ),
      );
    });

    // ── Empty remotes list ────────────────────────────────────────────────────

    test('decodes empty Remotes list to isEmpty', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Remotes,
        data: fbs.RemotesObjectBuilder(remotes: const []),
      ).toBytes();

      final List<Remote> rems = decodeRemotesEnvelope(bytes);

      expect(rems, isEmpty);
    });

    // ── Two-entry list: field equality incl. credential URL ───────────────────

    test('decodes two remotes: every field equals builder input incl. credential url', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Remotes,
        data: fbs.RemotesObjectBuilder(
          remotes: [
            fbs.RemoteObjectBuilder(
              name: 'origin',
              url: 'https://github.com/user/repo.git',
            ),
            fbs.RemoteObjectBuilder(
              name: 'creds',
              url: 'https://user:token@example.com/r.git',
            ),
          ],
        ),
      ).toBytes();

      final List<Remote> rems = decodeRemotesEnvelope(bytes);

      expect(rems.length, equals(2));

      expect(rems[0].name, equals('origin'), reason: 'name must round-trip');
      expect(rems[0].url, equals('https://github.com/user/repo.git'), reason: 'url must round-trip');

      expect(rems[1].name, equals('creds'), reason: 'name must round-trip');
      // credentials must NOT be scrubbed at the Dart decode layer
      expect(
        rems[1].url,
        equals('https://user:token@example.com/r.git'),
        reason: 'url with embedded credentials must round-trip verbatim',
      );
    });
  });
}
