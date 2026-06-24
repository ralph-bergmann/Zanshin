// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeOpLogEnvelope] using synthetic FlatBuffers
// buffers built via the generated `*ObjectBuilder`s. No real cdylib required —
// these tests exercise the Dart-side decode logic in isolation.
//
// Mirrors packages/zanshin_core/test/ffi/change_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/op_log.dart';
import 'package:zanshin_core/src/worker/responses.dart';

fbs.OperationObjectBuilder _makeRootOp({
  String id = 'aabbcc001122',
  int timestampMillis = 0,
  int tzOffsetMinutes = 0,
}) => fbs.OperationObjectBuilder(
  id: id,
  parentIds: const [],
  timestampMillis: timestampMillis,
  tzOffsetMinutes: tzOffsetMinutes,
  user: '',
  host: '',
  description: '',
  rootOp: true,
  isSnapshot: false,
);

fbs.OperationObjectBuilder _makeNonRootOp({
  String id = 'ddeeff334455',
  List<String> parentIds = const ['aabbcc001122'],
  int timestampMillis = 1_700_000_000_000,
  int tzOffsetMinutes = 60,
  String user = 'alice',
  String host = 'host.local',
  String description = 'new empty commit',
  bool isSnapshot = false,
}) => fbs.OperationObjectBuilder(
  id: id,
  parentIds: parentIds,
  timestampMillis: timestampMillis,
  tzOffsetMinutes: tzOffsetMinutes,
  user: user,
  host: host,
  description: description,
  rootOp: false,
  isSnapshot: isSnapshot,
);

void main() {
  group('decodeOpLogEnvelope decode contract', () {
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
        () => decodeOpLogEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.jj_lib_error')
              .having((e) => e.context, 'context', 'op store corrupted'),
        ),
      );
    });

    // ── Wrong payload type ────────────────────────────────────────────────────

    test('throws ffi.unknown on ok envelope with non-OpLog payload', () {
      // ok == true but union variant is RepoHandle, not OpLog: the
      // discriminant guard must surface ZanshinFfiException('ffi.unknown').
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeOpLogEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'),
        ),
      );
    });

    // ── Full round-trip field equality ────────────────────────────────────────

    test('decodes fully-populated OpLog: root op empty parentIds + rootOp true', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpLog,
        data: fbs.OpLogObjectBuilder(
          operations: [_makeNonRootOp(), _makeRootOp()],
        ),
      ).toBytes();

      final List<Operation> ops = decodeOpLogEnvelope(bytes);

      expect(ops.length, equals(2));

      // Head op (first): non-root
      final Operation head = ops.first;
      expect(head.id, equals('ddeeff334455'));
      expect(head.parentIds, equals(['aabbcc001122']));
      expect(head.timestampMillis, equals(1_700_000_000_000));
      expect(head.tzOffsetMinutes, equals(60));
      expect(head.user, equals('alice'));
      expect(head.host, equals('host.local'));
      expect(head.description, equals('new empty commit'));
      expect(head.rootOp, isFalse);
      expect(head.isSnapshot, isFalse);

      // Root op (last)
      final Operation root = ops.last;
      expect(root.id, equals('aabbcc001122'));
      expect(root.parentIds, isEmpty, reason: 'root op parentIds must be empty');
      expect(root.timestampMillis, equals(0));
      expect(root.tzOffsetMinutes, equals(0));
      expect(root.user, equals(''));
      expect(root.host, equals(''));
      expect(root.description, equals(''));
      expect(root.rootOp, isTrue, reason: 'root op must have rootOp == true');
      expect(root.isSnapshot, isFalse);
    });

    test('decodes OpLog with multi-parent op and snapshot flag', () {
      // A three-op log: multi-parent (head) → single-parent → root.
      final fbs.OperationObjectBuilder multiParent = _makeNonRootOp(
        id: '112233445566',
        parentIds: ['ddeeff334455', 'aabbcc001122'],
        timestampMillis: 1_700_000_001_000,
        tzOffsetMinutes: -120,
        user: 'bob',
        host: 'builder',
        description: 'snapshot working copy',
        isSnapshot: true,
      );

      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpLog,
        data: fbs.OpLogObjectBuilder(
          operations: [multiParent, _makeNonRootOp(), _makeRootOp()],
        ),
      ).toBytes();

      final List<Operation> ops = decodeOpLogEnvelope(bytes);

      expect(ops.length, equals(3));

      // multi-parent head
      final Operation mp = ops[0];
      expect(mp.id, equals('112233445566'));
      expect(mp.parentIds, equals(['ddeeff334455', 'aabbcc001122']));
      expect(mp.timestampMillis, equals(1_700_000_001_000));
      expect(mp.tzOffsetMinutes, equals(-120));
      expect(mp.user, equals('bob'));
      expect(mp.host, equals('builder'));
      expect(mp.description, equals('snapshot working copy'));
      expect(mp.rootOp, isFalse);
      expect(mp.isSnapshot, isTrue);

      // single-parent middle
      final Operation mid = ops[1];
      expect(mid.id, equals('ddeeff334455'));
      expect(mid.parentIds, equals(['aabbcc001122']));
      expect(mid.rootOp, isFalse);
      expect(mid.isSnapshot, isFalse);

      // root last
      final Operation root = ops[2];
      expect(root.parentIds, isEmpty);
      expect(root.rootOp, isTrue);
    });

    test('decodes empty OpLog operations list', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpLog,
        data: fbs.OpLogObjectBuilder(operations: const []),
      ).toBytes();

      final List<Operation> ops = decodeOpLogEnvelope(bytes);

      expect(ops, isEmpty);
    });
  });
}
