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
            // No pushUrl: the absent arm of the null-for-absence field.
            fbs.RemoteObjectBuilder(
              name: 'origin',
              url: 'https://github.com/user/repo.git',
            ),
            fbs.RemoteObjectBuilder(
              name: 'creds',
              url: 'https://user:token@example.com/r.git',
              pushUrl: 'ssh://user:s3cr3t@example.com/r.git',
            ),
          ],
        ),
      ).toBytes();

      final List<Remote> rems = decodeRemotesEnvelope(bytes);

      expect(rems.length, equals(2));

      expect(rems[0].name, equals('origin'), reason: 'name must round-trip');
      expect(rems[0].url, equals('https://github.com/user/repo.git'), reason: 'url must round-trip');
      expect(
        rems[0].pushUrl,
        isNull,
        reason:
            'an absent push url stays null — no `?? \'\'` coalesce, or the '
            'absent/present distinction would be destroyed',
      );

      expect(rems[1].name, equals('creds'), reason: 'name must round-trip');
      // credentials must NOT be scrubbed at the Dart decode layer
      expect(
        rems[1].url,
        equals('https://user:token@example.com/r.git'),
        reason: 'url with embedded credentials must round-trip verbatim',
      );
      expect(
        rems[1].pushUrl,
        equals('ssh://user:s3cr3t@example.com/r.git'),
        reason: 'a present push url round-trips verbatim, credentials included',
      );
    });
  });

  group('decodeGitPushRemotesEnvelope decode contract (Story 9.54)', () {
    Uint8List pushRemotes(List<String>? names) => fbs.EnvelopeObjectBuilder(
      ok: true,
      dataType: fbs.PayloadTypeId.GitPushRemotes,
      data: fbs.GitPushRemotesObjectBuilder(names: names),
    ).toBytes();

    test('decodes the names in order, an empty list included', () {
      expect(decodeGitPushRemotesEnvelope(pushRemotes(['origin', 'fork'])), ['origin', 'fork']);
      expect(decodeGitPushRemotesEnvelope(pushRemotes([])), isEmpty);
    });

    test('an absent names vector is refused, not defaulted', () {
      expect(
        () => decodeGitPushRemotesEnvelope(pushRemotes(null)),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('throws on an error envelope and ffi.unknown on a wrong payload', () {
      final Uint8List error = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.config_error', context: 'git.push'),
      ).toBytes();
      expect(
        () => decodeGitPushRemotesEnvelope(error),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.config_error')),
      );
      final Uint8List wrong = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();
      expect(
        () => decodeGitPushRemotesEnvelope(wrong),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });
  });

  group('decodeRemoteChangesEnvelope decode contract (Story 9.24)', () {
    test('decodes every kind and change; an absent new id stays null', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RemoteChanges,
        data: fbs.RemoteChangesObjectBuilder(
          changes: [
            fbs.RemoteRefChangeObjectBuilder(
              kind: fbs.RemoteRefKind.Bookmark,
              name: 'main',
              change: fbs.RemoteRefChangeKind.Moved,
              oldCommitIds: ['aa', 'bb'],
              newCommitId: 'cc',
            ),
            fbs.RemoteRefChangeObjectBuilder(
              kind: fbs.RemoteRefKind.Bookmark,
              name: 'x',
              change: fbs.RemoteRefChangeKind.Deleted,
              oldCommitIds: ['ee'],
            ),
            fbs.RemoteRefChangeObjectBuilder(
              kind: fbs.RemoteRefKind.Tag,
              name: 'v1',
              change: fbs.RemoteRefChangeKind.New,
              oldCommitIds: const [],
              newCommitId: 'dd',
            ),
          ],
        ),
      ).toBytes();

      final List<RemoteRefChange> changes = decodeRemoteChangesEnvelope(bytes);

      expect(changes.map((c) => (c.kind, c.name, c.change, c.oldCommitIds.join(','), c.newCommitId)).toList(), [
        (RemoteRefKind.bookmark, 'main', RemoteRefChangeKind.moved, 'aa,bb', 'cc'),
        (RemoteRefKind.bookmark, 'x', RemoteRefChangeKind.deleted, 'ee', null),
        (RemoteRefKind.tag, 'v1', RemoteRefChangeKind.created, '', 'dd'),
      ]);
      expect(changes.first.toString(), contains('main'));
    });

    test('an empty or absent changes vector is no change', () {
      for (final List<fbs.RemoteRefChangeObjectBuilder>? changes in [
        const <fbs.RemoteRefChangeObjectBuilder>[],
        null,
      ]) {
        final Uint8List bytes = fbs.EnvelopeObjectBuilder(
          ok: true,
          dataType: fbs.PayloadTypeId.RemoteChanges,
          data: fbs.RemoteChangesObjectBuilder(changes: changes),
        ).toBytes();
        expect(decodeRemoteChangesEnvelope(bytes), isEmpty);
      }
    });

    test('throws on an error envelope and ffi.unknown on a wrong payload', () {
      final Uint8List error = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.network_error', context: 'External git program failed:\n'),
      ).toBytes();
      expect(
        () => decodeRemoteChangesEnvelope(error),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.network_error')),
      );
      final Uint8List wrong = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();
      expect(
        () => decodeRemoteChangesEnvelope(wrong),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });
  });
}
