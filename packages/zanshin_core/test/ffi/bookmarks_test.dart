// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeBookmarksEnvelope] using synthetic FlatBuffers
// buffers built via the generated `*ObjectBuilder`s. No real cdylib required —
// these tests exercise the Dart-side decode logic in isolation.
//
// The `Remote`-arm decode is exercised here because committed fixtures have no
// remote bookmarks; the live cdylib path for the extern fn is covered by the
// worker round-trip test (test/worker/bookmarks_test.dart).

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bookmarks.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/worker/responses.dart';

fbs.BookmarkObjectBuilder _makeLocalBookmark({
  String name = 'main',
  String target = 'zxqpvutsrqponm',
}) => fbs.BookmarkObjectBuilder(
  name: name,
  target: target,
  kind: fbs.BookmarkKind.Local,
);

fbs.BookmarkObjectBuilder _makeRemoteBookmark({
  String name = 'main',
  String target = 'zxqpvutsrqponm',
  String remoteName = 'origin',
}) => fbs.BookmarkObjectBuilder(
  name: name,
  target: target,
  kind: fbs.BookmarkKind.Remote,
  remoteName: remoteName,
);

void main() {
  group('decodeBookmarksEnvelope decode contract', () {
    // ── Error envelope ────────────────────────────────────────────────────────

    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'jj.jj_lib_error',
          context: 'op store corrupted',
        ),
      ).toBytes();

      expect(
        () => decodeBookmarksEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.jj_lib_error')
              .having((e) => e.context, 'context', 'op store corrupted'),
        ),
      );
    });

    // ── Wrong payload type ────────────────────────────────────────────────────

    test('throws ffi.unknown on ok envelope with non-Bookmarks payload', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeBookmarksEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'),
        ),
      );
    });

    // ── Empty bookmarks list ──────────────────────────────────────────────────

    test('decodes empty Bookmarks list to isEmpty', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Bookmarks,
        data: fbs.BookmarksObjectBuilder(bookmarks: const []),
      ).toBytes();

      final List<Bookmark> bms = decodeBookmarksEnvelope(bytes);

      expect(bms, isEmpty);
    });

    // ── Local bookmark field equality ─────────────────────────────────────────

    test('decodes Local bookmark: every field equals builder input', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Bookmarks,
        data: fbs.BookmarksObjectBuilder(
          bookmarks: [
            _makeLocalBookmark(name: 'feature', target: 'nopqrstuv'),
          ],
        ),
      ).toBytes();

      final List<Bookmark> bms = decodeBookmarksEnvelope(bytes);

      expect(bms.length, equals(1));
      final Bookmark bm = bms.first;
      expect(bm.name, equals('feature'), reason: 'name must round-trip');
      expect(bm.target, equals('nopqrstuv'), reason: 'target must round-trip');
      expect(bm.kind, isA<LocalBookmark>(), reason: 'kind must be LocalBookmark');
    });

    // ── Remote bookmark field equality (the arm not covered by live fixtures) ─

    test('decodes Remote bookmark: every field equals builder input incl. remoteName', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Bookmarks,
        data: fbs.BookmarksObjectBuilder(
          bookmarks: [
            _makeRemoteBookmark(target: 'zxqpvuts', remoteName: 'upstream'),
          ],
        ),
      ).toBytes();

      final List<Bookmark> bms = decodeBookmarksEnvelope(bytes);

      expect(bms.length, equals(1));
      final Bookmark bm = bms.first;
      expect(bm.name, equals('main'), reason: 'name must round-trip');
      expect(bm.target, equals('zxqpvuts'), reason: 'target must round-trip');
      expect(bm.kind, isA<RemoteBookmark>(), reason: 'kind must be RemoteBookmark');
      final remote = bm.kind as RemoteBookmark;
      expect(remote.remoteName, equals('upstream'), reason: 'remoteName must round-trip');
    });

    // ── Mixed Local + Remote list ─────────────────────────────────────────────

    test('decodes mixed Local + Remote list: all fields equal builder input', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Bookmarks,
        data: fbs.BookmarksObjectBuilder(
          bookmarks: [
            _makeLocalBookmark(target: 'aaaabbbb'),
            _makeRemoteBookmark(target: 'aaaabbbb'),
            _makeLocalBookmark(name: 'release', target: 'ccccdddd'),
          ],
        ),
      ).toBytes();

      final List<Bookmark> bms = decodeBookmarksEnvelope(bytes);

      expect(bms.length, equals(3));

      // Local 'main'
      expect(bms[0].name, equals('main'));
      expect(bms[0].target, equals('aaaabbbb'));
      expect(bms[0].kind, isA<LocalBookmark>());

      // Remote 'main'
      expect(bms[1].name, equals('main'));
      expect(bms[1].target, equals('aaaabbbb'));
      expect(bms[1].kind, isA<RemoteBookmark>());
      expect((bms[1].kind as RemoteBookmark).remoteName, equals('origin'));

      // Local 'release'
      expect(bms[2].name, equals('release'));
      expect(bms[2].target, equals('ccccdddd'));
      expect(bms[2].kind, isA<LocalBookmark>());
    });
  });
}
