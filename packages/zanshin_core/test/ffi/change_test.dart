// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeChangeEnvelope] using synthetic FlatBuffers
// buffers built via the generated `*ObjectBuilder`s. No real cdylib required —
// these tests exercise the Dart-side decode logic in isolation.
//
// Mirrors app/test/ffi/status_test.dart (decode-contract section).

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/change.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/worker/responses.dart';

fbs.SignatureObjectBuilder _makeSignatureBuilder({
  String name = 'Alice',
  String email = 'alice@example.com',
  int timestampMillis = 1_700_000_000_000,
  int tzOffsetMinutes = 60,
}) => fbs.SignatureObjectBuilder(
  name: name,
  email: email,
  timestampMillis: timestampMillis,
  tzOffsetMinutes: tzOffsetMinutes,
);

fbs.ChangeObjectBuilder _makeChangeBuilder({
  String id = 'qpvuntsm',
  String commitId = 'aabbccdd1122',
  List<String> parents = const ['parent111', 'parent222'],
  String description = 'my feature',
  bool isSigned = true,
  fbs.ConflictState conflict = fbs.ConflictState.Clean,
  List<String>? conflictedPaths,
  bool isAnonymous = false,
  bool divergent = true,
}) => fbs.ChangeObjectBuilder(
  id: id,
  commitId: commitId,
  parents: parents,
  description: description,
  author: _makeSignatureBuilder(),
  committer: _makeSignatureBuilder(
    name: 'Bob',
    email: 'bob@example.com',
    timestampMillis: 1_700_001_000_000,
    tzOffsetMinutes: 0,
  ),
  isSigned: isSigned,
  conflict: conflict,
  conflictedPaths: conflictedPaths,
  isAnonymous: isAnonymous,
  divergent: divergent,
);

void main() {
  group('decodeChangeEnvelope decode contract', () {
    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'jj.change_not_found',
          context: 'abc123',
        ),
      ).toBytes();

      expect(
        () => decodeChangeEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.change_not_found')
              .having((e) => e.context, 'context', 'abc123'),
        ),
      );
    });

    test('throws ffi.unknown on ok envelope with non-Change payload', () {
      // ok == true but union variant is RepoHandle, not Change: the
      // discriminant guard must surface ZanshinFfiException('ffi.unknown').
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeChangeEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'),
        ),
      );
    });

    test('decodes fully-populated Change with Conflicted state', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Change,
        data: _makeChangeBuilder(
          conflict: fbs.ConflictState.Conflicted,
          conflictedPaths: ['src/lib.rs'],
        ),
      ).toBytes();

      final Change change = decodeChangeEnvelope(bytes);

      expect(change.id, equals('qpvuntsm'));
      expect(change.commitId, equals('aabbccdd1122'));
      expect(change.parents, equals(['parent111', 'parent222']));
      expect(change.description, equals('my feature'));
      expect(change.isSigned, isTrue);
      expect(change.divergent, isTrue);
      expect(change.isAnonymous, isFalse);

      expect(change.author.name, equals('Alice'));
      expect(change.author.email, equals('alice@example.com'));
      expect(change.author.timestampMillis, equals(1_700_000_000_000));
      expect(change.author.tzOffsetMinutes, equals(60));
      expect(change.authoredAt, equals(change.author.timestampMillis));

      expect(change.committer.name, equals('Bob'));
      expect(change.committer.email, equals('bob@example.com'));
      expect(change.committer.timestampMillis, equals(1_700_001_000_000));
      expect(change.committedAt, equals(change.committer.timestampMillis));

      expect(change.conflict, equals(ConflictState.conflicted));
      expect(change.conflictedPaths, equals(['src/lib.rs']));
    });

    test('decodes clean Change with divergent==false and isAnonymous==true', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Change,
        data: _makeChangeBuilder(
          description: '',
          divergent: false,
          isAnonymous: true,
          isSigned: false,
          parents: [],
        ),
      ).toBytes();

      final Change change = decodeChangeEnvelope(bytes);

      expect(change.description, equals(''));
      expect(change.conflict, equals(ConflictState.clean));
      expect(change.conflictedPaths, isEmpty);
      expect(change.divergent, isFalse);
      expect(change.isAnonymous, isTrue);
      expect(change.isSigned, isFalse);
      expect(change.parents, isEmpty);
    });
  });
}
