// SPDX-License-Identifier: MIT

// Wire-shape, guard and decode-contract tests for the tag adapters (Story 9.59),
// using synthetic FlatBuffers buffers built via the generated `*ObjectBuilder`s.
// No real cdylib required — the live path is covered by
// test/worker/tags_test.dart. Mirrors crates/zanshin-ffi/src/tags.rs.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/tags.dart';
import 'package:zanshin_core/src/ffi/warning.dart' show WarnedList;
import 'package:zanshin_core/src/worker/responses.dart';

Uint8List _tagsEnvelope(List<fbs.TagObjectBuilder> tags, {List<fbs.WarningObjectBuilder>? warnings}) =>
    fbs.EnvelopeObjectBuilder(
      ok: true,
      dataType: fbs.PayloadTypeId.Tags,
      data: fbs.TagsObjectBuilder(tags: tags),
      warnings: warnings,
    ).toBytes();

void main() {
  group('request wire shapes', () {
    test('TagSetRequest: absent revision is `@`, names keep argument order', () {
      final req = fbs.TagSetRequest(
        fbs.TagSetRequestObjectBuilder(kind: fbs.RequestKind.TagSet, names: ['v2', 'v1']).toBytes(),
      );
      expect(req.kind, fbs.RequestKind.TagSet);
      expect(req.names, ['v2', 'v1']);
      expect(req.revision, isNull, reason: 'null-for-absence: absent means `@`');
      expect(req.allowMove, isFalse);

      final full = fbs.TagSetRequest(
        fbs.TagSetRequestObjectBuilder(
          kind: fbs.RequestKind.TagSet,
          names: ['v1'],
          revision: 'qpvuntsm',
          allowMove: true,
        ).toBytes(),
      );
      expect((full.revision, full.allowMove), ('qpvuntsm', true));
    });

    test('TagDeleteRequest carries the patterns verbatim', () {
      final req = fbs.TagDeleteRequest(
        fbs.TagDeleteRequestObjectBuilder(kind: fbs.RequestKind.TagDelete, names: ['v1.*', 'exact:v2']).toBytes(),
      );
      expect(req.kind, fbs.RequestKind.TagDelete);
      expect(req.names, ['v1.*', 'exact:v2']);
    });

    test('TagTrackRequest: one table, the kind tells track from untrack', () {
      for (final fbs.RequestKind kind in [fbs.RequestKind.TagTrack, fbs.RequestKind.TagUntrack]) {
        final req = fbs.TagTrackRequest(fbs.TagTrackRequestObjectBuilder(kind: kind, names: ['v1@origin']).toBytes());
        expect(req.kind, kind);
        expect(req.names, ['v1@origin']);
        expect(req.remotes, isNull, reason: 'absent = no --remote');
      }
      final withRemotes = fbs.TagTrackRequest(
        fbs.TagTrackRequestObjectBuilder(kind: fbs.RequestKind.TagTrack, names: ['v*'], remotes: ['origin']).toBytes(),
      );
      expect(withRemotes.remotes, ['origin']);
    });
  });

  group('adapter guards', () {
    final nul = String.fromCharCode(0);

    test('zanshinTagSet rejects an interior NUL in names and revision', () {
      expect(
        () => zanshinTagSet(0, ['v${nul}1']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
      expect(
        () => zanshinTagSet(0, ['v1'], revision: 'qpv${nul}untsm'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'revision')),
      );
    });

    test('zanshinTagDelete rejects an interior NUL in a pattern', () {
      expect(
        () => zanshinTagDelete(0, ['v${nul}1']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
    });

    test('zanshinTagTrack / Untrack reject an interior NUL in names and remotes', () {
      for (final Uint8List Function(int, List<String>, {List<String> remotes}) adapter in [
        zanshinTagTrack,
        zanshinTagUntrack,
      ]) {
        expect(
          () => adapter(0, ['v${nul}1']),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
        );
        expect(
          () => adapter(0, ['v1'], remotes: ['o${nul}rigin']),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'remotes')),
        );
      }
    });
  });

  group('decodeTagsEnvelope decode contract', () {
    test('decodes Local and Remote rows with their facts and the warnings', () {
      final Uint8List bytes = _tagsEnvelope(
        [
          fbs.TagObjectBuilder(name: 'v1', kind: fbs.TagKind.Local, synced: true),
          fbs.TagObjectBuilder(
            name: 'v1',
            target: 'qpvuntsm',
            kind: fbs.TagKind.Remote,
            remoteName: 'origin',
            conflicted: true,
            tracked: true,
          ),
        ],
        warnings: [fbs.WarningObjectBuilder(code: 'jj.config_alias_invalid', message: 'm')],
      );
      final WarnedList<Tag> tags = decodeTagsEnvelope(bytes);
      expect(tags, hasLength(2));
      expect(tags.warnings.map((w) => w.code), ['jj.config_alias_invalid']);

      final Tag local = tags[0];
      expect(local.target, isNull, reason: 'null-for-absence: a deleted local tag');
      expect((local.name, local.synced, local.conflicted), ('v1', true, false));
      expect(local.kind, isA<LocalTag>());

      final Tag remote = tags[1];
      expect((remote.target, remote.synced, remote.conflicted), ('qpvuntsm', false, true));
      expect(
        remote.kind,
        isA<RemoteTag>().having((k) => k.remoteName, 'remoteName', 'origin').having((k) => k.tracked, 'tracked', true),
      );
    });

    test('an absent tags vector decodes to an empty list', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Tags,
        data: fbs.TagsObjectBuilder(),
      ).toBytes();
      expect(decodeTagsEnvelope(bytes), isEmpty);
    });

    test('a Remote row without remote_name is corruption', () {
      final Uint8List bytes = _tagsEnvelope([fbs.TagObjectBuilder(name: 'v1', kind: fbs.TagKind.Remote)]);
      expect(
        () => decodeTagsEnvelope(bytes),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('a row without a name is corruption', () {
      final Uint8List bytes = _tagsEnvelope([fbs.TagObjectBuilder(kind: fbs.TagKind.Local)]);
      expect(
        () => decodeTagsEnvelope(bytes),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('an error envelope and a wrong payload throw', () {
      final Uint8List error = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.config_error', context: 'ui.tag-list-sort-keys'),
      ).toBytes();
      expect(
        () => decodeTagsEnvelope(error),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.config_error')),
      );
      final Uint8List wrong = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();
      expect(
        () => decodeTagsEnvelope(wrong),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });
  });
}
