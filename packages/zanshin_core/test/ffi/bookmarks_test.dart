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

    // ── Story 9.29: tracking facts ────────────────────────────────────────────

    test('decodes conflicted and synced on a Local row', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Bookmarks,
        data: fbs.BookmarksObjectBuilder(
          bookmarks: [
            fbs.BookmarkObjectBuilder(name: 'c', target: 'kkkk', kind: fbs.BookmarkKind.Local, conflicted: true),
            fbs.BookmarkObjectBuilder(name: 's', target: 'llll', kind: fbs.BookmarkKind.Local, synced: true),
          ],
        ),
      ).toBytes();

      final List<Bookmark> bms = decodeBookmarksEnvelope(bytes);

      expect((bms[0].conflicted, bms[0].synced), (true, false));
      expect((bms[1].conflicted, bms[1].synced), (false, true));
    });

    test('an absent target decodes to null, never to an empty string', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Bookmarks,
        data: fbs.BookmarksObjectBuilder(
          bookmarks: [fbs.BookmarkObjectBuilder(name: 'deleted', kind: fbs.BookmarkKind.Local)],
        ),
      ).toBytes();

      expect(decodeBookmarksEnvelope(bytes).single.target, isNull);
    });

    test('decodes tracked and both distances on a Remote row; has_upper=false is a null upper', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Bookmarks,
        data: fbs.BookmarksObjectBuilder(
          bookmarks: [
            fbs.BookmarkObjectBuilder(
              name: 'f',
              target: 'mmmm',
              kind: fbs.BookmarkKind.Remote,
              remoteName: 'origin',
              tracked: true,
              ahead: fbs.RefDistanceObjectBuilder(lower: 2, upper: 2, hasUpper: true),
              behind: fbs.RefDistanceObjectBuilder(lower: 10, upper: 0, hasUpper: false),
            ),
          ],
        ),
      ).toBytes();

      final Bookmark bm = decodeBookmarksEnvelope(bytes).single;
      final remote = bm.kind as RemoteBookmark;

      expect(remote.tracked, isTrue);
      expect((remote.ahead!.lower, remote.ahead!.upper), (2, 2));
      expect((remote.behind!.lower, remote.behind!.upper), (10, null));
    });

    test('an untracked Remote row decodes without distances', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Bookmarks,
        data: fbs.BookmarksObjectBuilder(bookmarks: [_makeRemoteBookmark()]),
      ).toBytes();

      final remote = decodeBookmarksEnvelope(bytes).single.kind as RemoteBookmark;

      expect(remote.tracked, isFalse);
      expect(remote.ahead, isNull);
      expect(remote.behind, isNull);
    });

    test('a Remote row without remote_name is rejected as ffi.unknown corruption', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Bookmarks,
        data: fbs.BookmarksObjectBuilder(
          bookmarks: [fbs.BookmarkObjectBuilder(name: 'x', target: 'nnnn', kind: fbs.BookmarkKind.Remote)],
        ),
      ).toBytes();

      expect(
        () => decodeBookmarksEnvelope(bytes),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });
  });

  group('BookmarkListRequest wire shape (Story 9.19)', () {
    test('an all-default request is the CLI without arguments', () {
      final req = fbs.BookmarkListRequest(
        fbs.BookmarkListRequestObjectBuilder(kind: fbs.RequestKind.BookmarkList).toBytes(),
      );
      expect(req.kind, fbs.RequestKind.BookmarkList);
      expect(req.names, isNull);
      expect(req.revisions, isNull);
      expect(req.remotes, isNull);
      expect((req.allRemotes, req.tracked, req.conflicted), (false, false, false));
      expect(req.sort, isNull);
    });

    test('every argument and every sort key crosses', () {
      final req = fbs.BookmarkListRequest(
        fbs.BookmarkListRequestObjectBuilder(
          kind: fbs.RequestKind.BookmarkList,
          names: ['glob:f*'],
          revisions: ['@-'],
          remotes: ['origin'],
          tracked: true,
          conflicted: true,
          sort: [for (final BookmarkSortKey key in BookmarkSortKey.values) key.wire],
        ).toBytes(),
      );
      expect(req.names, ['glob:f*']);
      expect(req.revisions, ['@-']);
      expect(req.remotes, ['origin']);
      expect((req.tracked, req.conflicted), (true, true));
      expect(req.sort, [for (final BookmarkSortKey key in BookmarkSortKey.values) key.wire]);
      expect(
        BookmarkSortKey.values.map((k) => k.wire),
        isNot(contains(fbs.BookmarkSortKey.Unspecified)),
        reason: 'the Dart enum cannot send the refused Unspecified',
      );
      expect(BookmarkSortKey.values.map((k) => k.wire).toSet(), hasLength(14));
    });

    test('every sort key maps to its own wire value', () {
      final Map<BookmarkSortKey, fbs.BookmarkSortKey> expected = {
        BookmarkSortKey.name: fbs.BookmarkSortKey.Name,
        BookmarkSortKey.nameDesc: fbs.BookmarkSortKey.NameDesc,
        BookmarkSortKey.authorName: fbs.BookmarkSortKey.AuthorName,
        BookmarkSortKey.authorNameDesc: fbs.BookmarkSortKey.AuthorNameDesc,
        BookmarkSortKey.authorEmail: fbs.BookmarkSortKey.AuthorEmail,
        BookmarkSortKey.authorEmailDesc: fbs.BookmarkSortKey.AuthorEmailDesc,
        BookmarkSortKey.authorDate: fbs.BookmarkSortKey.AuthorDate,
        BookmarkSortKey.authorDateDesc: fbs.BookmarkSortKey.AuthorDateDesc,
        BookmarkSortKey.committerName: fbs.BookmarkSortKey.CommitterName,
        BookmarkSortKey.committerNameDesc: fbs.BookmarkSortKey.CommitterNameDesc,
        BookmarkSortKey.committerEmail: fbs.BookmarkSortKey.CommitterEmail,
        BookmarkSortKey.committerEmailDesc: fbs.BookmarkSortKey.CommitterEmailDesc,
        BookmarkSortKey.committerDate: fbs.BookmarkSortKey.CommitterDate,
        BookmarkSortKey.committerDateDesc: fbs.BookmarkSortKey.CommitterDateDesc,
      };
      expect(expected.keys, unorderedEquals(BookmarkSortKey.values));
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(key.wire, value, reason: '$key');
      }
    });

    test('zanshinBookmarks rejects an interior NUL in names, revisions and remotes', () {
      final nul = String.fromCharCode(0);
      expect(
        () => zanshinBookmarks(0, names: ['a${nul}b']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
      expect(
        () => zanshinBookmarks(0, revisions: ['@$nul-']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'revisions')),
      );
      expect(
        () => zanshinBookmarks(0, remotes: ['o${nul}rigin']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'remotes')),
      );
    });
  });
}
