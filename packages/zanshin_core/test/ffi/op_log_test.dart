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

  // ── Story 9.21: Operation's new fields and the three operation-verb payloads ──

  group('Story 9.21 decode contract', () {
    fbs.OpRefTargetObjectBuilder target(
      List<String> adds, {
      List<String> removes = const [],
      bool conflicted = false,
    }) => fbs.OpRefTargetObjectBuilder(adds: adds, removes: removes, conflicted: conflicted);

    fbs.OpDiffObjectBuilder diff({bool withCommits = true}) => fbs.OpDiffObjectBuilder(
      commits: withCommits
          ? fbs.OpCommitsDiffObjectBuilder(
              changes: [
                fbs.OpChangedCommitObjectBuilder(
                  commitId: 'c2',
                  abandoned: false,
                  addedCommitIds: const ['c2'],
                  removedCommitIds: const ['c1'],
                ),
              ],
              elidedNewlyVisible: fbs.RefDistanceObjectBuilder(lower: 3, upper: 0, hasUpper: false),
              elidedNewlyHidden: fbs.RefDistanceObjectBuilder(lower: 1, upper: 1, hasUpper: true),
            )
          : null,
      workingCopies: [fbs.OpWorkingCopyChangeObjectBuilder(workspace: 'default', to: 'w2')],
      localBookmarks: [
        fbs.OpRefChangeObjectBuilder(name: 'b', from: target(const []), to: target(const ['c2'])),
      ],
      localTags: [
        fbs.OpRefChangeObjectBuilder(
          name: 't',
          from: target(const ['a', 'b'], removes: const ['a'], conflicted: true),
          to: target(const []),
        ),
      ],
      remoteBookmarks: [
        fbs.OpRemoteRefChangeObjectBuilder(
          name: 'main',
          remote: 'origin',
          from: target(const []),
          fromTracked: false,
          to: target(const ['c2']),
          toTracked: true,
        ),
      ],
      remoteTags: const [],
    );

    test('an Operation carries its workspace name and tags; absent is null / empty', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpLog,
        data: fbs.OpLogObjectBuilder(
          operations: [
            fbs.OperationObjectBuilder(
              id: 'o1',
              parentIds: const ['o0'],
              workspaceName: 'second',
              tags: [fbs.OperationTagObjectBuilder(key: 'args', value: 'jj new')],
            ),
            _makeRootOp(),
          ],
        ),
      ).toBytes();

      final List<Operation> ops = decodeOpLogEnvelope(bytes);

      expect(ops.first.workspaceName, 'second');
      expect(ops.first.tags.single.key, 'args');
      expect(ops.first.tags.single.value, 'jj new');
      expect(ops.last.workspaceName, isNull);
      expect(ops.last.tags, isEmpty);
    });

    test('OpShow decodes every diff section', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpShow,
        data: fbs.OpShowObjectBuilder(operation: _makeNonRootOp(), diff: diff()),
        warnings: [fbs.WarningObjectBuilder(code: 'jj.revset_diagnostic', message: 'm')],
      ).toBytes();

      final OpShow show = decodeOpShowEnvelope(bytes);

      expect(show.operation.id, 'ddeeff334455');
      expect(show.warnings.single.code, 'jj.revset_diagnostic');
      final OpDiff d = show.diff!;
      final OpCommitsDiff commits = d.commits!;
      expect(commits.changes.single.commitId, 'c2');
      expect(commits.changes.single.abandoned, isFalse);
      expect(commits.changes.single.addedCommitIds, ['c2']);
      expect(commits.changes.single.removedCommitIds, ['c1']);
      expect(commits.elidedNewlyVisible.lower, 3);
      expect(commits.elidedNewlyVisible.upper, isNull, reason: 'has_upper false = unbounded');
      expect(commits.elidedNewlyHidden.upper, 1);
      expect(d.workingCopies.single.workspace, 'default');
      expect(d.workingCopies.single.from, isNull);
      expect(d.workingCopies.single.to, 'w2');
      expect(d.localBookmarks.single.from.isAbsent, isTrue);
      expect(d.localBookmarks.single.to.adds, ['c2']);
      final OpRefTarget conflicted = d.localTags.single.from;
      expect(conflicted.conflicted, isTrue);
      expect(conflicted.adds, ['a', 'b']);
      expect(conflicted.removes, ['a']);
      expect(conflicted.isAbsent, isFalse);
      final OpRemoteRefChange remote = d.remoteBookmarks.single;
      expect((remote.name, remote.remote, remote.fromTracked, remote.toTracked), ('main', 'origin', false, true));
      expect(d.remoteTags, isEmpty);
    });

    test('OpShow of a merge operation has no diff', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpShow,
        data: fbs.OpShowObjectBuilder(operation: _makeNonRootOp()),
      ).toBytes();

      expect(decodeOpShowEnvelope(bytes).diff, isNull);
    });

    test('OpDiffResult decodes from / to and an unresolved commit section as null', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpDiffResult,
        data: fbs.OpDiffResultObjectBuilder(
          from: [_makeRootOp()],
          to: _makeNonRootOp(),
          diff: diff(withCommits: false),
        ),
      ).toBytes();

      final OpDiffResult result = decodeOpDiffResultEnvelope(bytes);

      expect(result.from.single.rootOp, isTrue);
      expect(result.to.id, 'ddeeff334455');
      expect(result.diff.commits, isNull);
      expect(result.diff.workingCopies, hasLength(1));
    });

    test('OpAbandonResult decodes its counts and heads', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpAbandonResult,
        data: fbs.OpAbandonResultObjectBuilder(
          abandonedCount: 4,
          reparentedCount: 1,
          nothingChanged: false,
          headOpIds: const ['h'],
        ),
      ).toBytes();

      final OpAbandonResult result = decodeOpAbandonResultEnvelope(bytes);

      expect((result.abandonedCount, result.reparentedCount, result.nothingChanged), (4, 1, false));
      expect(result.headOpIds, ['h']);
    });

    test('each decoder throws on an error envelope and on a foreign payload', () {
      final Uint8List error = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.operation_not_found', context: 'No operation ID matching "ff"'),
      ).toBytes();
      final Uint8List foreign = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();
      for (final Object Function(Uint8List) decode in [
        decodeOpShowEnvelope,
        decodeOpDiffResultEnvelope,
        decodeOpAbandonResultEnvelope,
      ]) {
        expect(
          () => decode(error),
          throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.operation_not_found')),
        );
        expect(() => decode(foreign), throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')));
      }
    });

    test('a payload missing a required table throws ffi.unknown, not a TypeError', () {
      Matcher unknown(String context) => throwsA(
        isA<ZanshinFfiException>()
            .having((e) => e.code, 'code', 'ffi.unknown')
            .having((e) => e.context, 'context', context),
      );
      final Uint8List noOperation = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpShow,
        data: fbs.OpShowObjectBuilder(),
      ).toBytes();
      final Uint8List noTo = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpDiffResult,
        data: fbs.OpDiffResultObjectBuilder(diff: diff()),
      ).toBytes();
      final Uint8List noDiff = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.OpDiffResult,
        data: fbs.OpDiffResultObjectBuilder(to: _makeNonRootOp()),
      ).toBytes();

      expect(() => decodeOpShowEnvelope(noOperation), unknown('OpShow payload is missing its operation'));
      expect(() => decodeOpDiffResultEnvelope(noTo), unknown('OpDiffResult payload is missing its to'));
      expect(() => decodeOpDiffResultEnvelope(noDiff), unknown('OpDiffResult payload is missing its diff'));
    });
  });

  // ── Adapter guards (no cdylib call; mirrors mutate_test.dart) ──────────────

  group('op_log.dart adapters reject an interior NUL', () {
    const nul = 'a\u0000b';

    test('zanshinOpShow_rejects_interior_nul_in_every_string', () {
      expect(() => zanshinOpShow(0, operation: nul), throwsArgumentError);
      expect(() => zanshinOpShow(0, showChangesIn: nul), throwsArgumentError);
    });

    test('zanshinOpDiff_rejects_interior_nul_in_every_string', () {
      expect(() => zanshinOpDiff(0, operation: nul), throwsArgumentError);
      expect(() => zanshinOpDiff(0, from: nul), throwsArgumentError);
      expect(() => zanshinOpDiff(0, to: nul), throwsArgumentError);
      expect(() => zanshinOpDiff(0, showChangesIn: nul), throwsArgumentError);
    });

    test('zanshinOpAbandon_rejects_interior_nul_in_operation', () {
      expect(() => zanshinOpAbandon(0, nul), throwsArgumentError);
    });
  });
}
