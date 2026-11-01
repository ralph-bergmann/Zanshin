// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_model.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../../helpers/fake_undo_timeline.dart';

void main() {
  final now = DateTime(2026, 11, 1, 12);
  List<Operation> log(int count) => <Operation>[for (var i = 0; i < count; i++) testOperation(i, now: now)];

  test('the first read asks for 50; loadMore re-reads from the head with 100, 150, … until every operation shows', () {
    fakeAsync((async) {
      final source = FakeTimelineSource(log(120));
      final model = UndoTimelineModel(source, clock: () => now);
      async.flushMicrotasks();
      expect(source.limits, <int>[50]);
      expect(model.operations, hasLength(50));
      expect(model.loading, isFalse);
      model
        ..loadMore()
        ..loadMore();
      async.flushMicrotasks();
      expect(source.limits, <int>[50, 100], reason: 'a larger page already asked for is not asked again');
      model.loadMore();
      async.flushMicrotasks();
      expect(source.limits, <int>[50, 100, 150]);
      expect(model.operations, hasLength(120));
      model.loadMore();
      async.flushMicrotasks();
      expect(source.limits, hasLength(3), reason: 'every operation shows');
      model.dispose();
    });
  });

  test('an op-heads event reloads once with the current limit; a heartbeat only while stale', () {
    fakeAsync((async) {
      final source = FakeTimelineSource(log(80));
      final model = UndoTimelineModel(source, clock: () => now);
      async.flushMicrotasks();
      model.loadMore();
      async.flushMicrotasks();
      expect(source.limits, <int>[50, 100]);
      source.emit(const OpHeadsChangedEvent(0, <String>[]));
      async.flushMicrotasks();
      expect(source.limits, <int>[50, 100, 100]);
      source.emit(const WorkingCopyHeartbeatEvent(0, <String>[]));
      async.flushMicrotasks();
      expect(source.limits, hasLength(3));

      source
        ..refuse = const ZanshinFfiException('jj.stale_working_copy')
        ..emit(const OpHeadsChangedEvent(0, <String>[]));
      async.flushMicrotasks();
      expect(model.stale, isTrue);
      expect(model.error, isNull);
      source
        ..refuse = null
        ..emit(const WorkingCopyHeartbeatEvent(0, <String>[]));
      async.flushMicrotasks();
      expect(source.limits, hasLength(5));
      expect(model.stale, isFalse);
      model.dispose();
    });
  });

  test('at most one read runs and one more is queued, however many events arrive meanwhile', () {
    fakeAsync((async) {
      final source = FakeTimelineSource(log(3))..gate = Completer<void>();
      final model = UndoTimelineModel(source, clock: () => now);
      for (var i = 0; i < 4; i++) {
        source.emit(const OpHeadsChangedEvent(0, <String>[]));
      }
      async.flushMicrotasks();
      expect(source.limits, hasLength(1));
      final Completer<void> gate = source.gate!;
      source.gate = null;
      gate.complete();
      async.flushMicrotasks();
      expect(source.limits, hasLength(2));
      expect(model.loading, isFalse);
      model.dispose();
    });
  });

  test('a failed page keeps the rows and can be asked again', () {
    fakeAsync((async) {
      final source = FakeTimelineSource(log(80));
      final model = UndoTimelineModel(source, clock: () => now);
      async.flushMicrotasks();
      source.refuse = const ZanshinFfiException('jj.io_error', 'disk full');
      model.loadMore();
      async.flushMicrotasks();
      expect(model.operations, hasLength(50));
      expect(model.error?.context, 'disk full');
      model.loadMore();
      async.flushMicrotasks();
      expect(source.limits, <int>[50, 100], reason: 'no page while the last read failed');
      source
        ..refuse = null
        ..emit(const OpHeadsChangedEvent(0, <String>[]));
      async.flushMicrotasks();
      expect(model.error, isNull, reason: 'the next event retried');
      model.loadMore();
      async.flushMicrotasks();
      expect(source.limits, <int>[50, 100, 50, 100]);
      expect(model.operations, hasLength(80));
      model.dispose();
    });
  });

  test('a failure that is not jj\'s refusal keeps the rows, clears loading and sets an error', () {
    fakeAsync((async) {
      final source = _ThrowingSource(log(3));
      final model = UndoTimelineModel(source, clock: () => now);
      async.flushMicrotasks();
      source
        ..fail = true
        ..emit(const OpHeadsChangedEvent(0, <String>[]));
      async.flushMicrotasks();
      expect(model.operations, hasLength(3));
      expect(model.loading, isFalse);
      expect(model.error?.code, 'ffi.unknown');
      model.dispose();
    });
  });

  test("undoTarget and redoTarget follow jj's undo and redo descriptions", () {
    fakeAsync((async) {
      final Operation undo = testOperation(0, now: now, description: 'undo: restore to operation ${opId(2)}');
      final Operation redo = testOperation(0, now: now, description: 'redo: restore to operation ${opId(1)}');
      final Operation undoBelow = testOperation(1, now: now, description: 'undo: restore to operation ${opId(3)}');
      final source = FakeTimelineSource(<Operation>[undo, ...log(4).skip(1)]);
      final model = UndoTimelineModel(source, clock: () => now);
      async.flushMicrotasks();
      expect(model.undoTarget(undo).id, opId(2));
      expect(model.redoTarget(undo)?.id, opId(1), reason: "the undo's parent");
      final Operation plain = model.operations[1];
      expect(model.undoTarget(plain), same(plain));
      expect(model.redoTarget(plain), isNull, reason: 'nothing to redo');

      source
        ..operations = <Operation>[redo, undoBelow, ...log(4).skip(2)]
        ..emit(const OpHeadsChangedEvent(0, <String>[]));
      async.flushMicrotasks();
      expect(model.redoTarget(redo)?.id, opId(2), reason: 'a redo is followed to the undo it restored to');
      final Operation unknown = testOperation(0, now: now, description: 'undo: restore to operation ${opId(99)}');
      expect(model.undoTarget(unknown), same(unknown), reason: 'a target not shown falls back to the head');
      model.dispose();
    });
  });

  test('headOnRoot: the head is the root, or its parent is', () {
    fakeAsync((async) {
      final source = FakeTimelineSource(<Operation>[testRoot()]);
      final model = UndoTimelineModel(source, clock: () => now);
      async.flushMicrotasks();
      expect(model.headOnRoot, isTrue);
      source
        ..operations = <Operation>[testOperation(0, now: now, parent: rootOpId), testRoot()]
        ..emit(const OpHeadsChangedEvent(0, <String>[]));
      async.flushMicrotasks();
      expect(model.headOnRoot, isTrue);
      source
        ..operations = <Operation>[
          testOperation(0, now: now),
          testOperation(1, now: now, parent: rootOpId),
          testRoot(),
        ]
        ..emit(const OpHeadsChangedEvent(0, <String>[]));
      async.flushMicrotasks();
      expect(model.headOnRoot, isFalse);
      model.dispose();
    });
  });

  test('now ticks each minute; dispose cancels the tick and the event subscription', () {
    fakeAsync((async) {
      var clock = now;
      final source = FakeTimelineSource(log(1));
      final model = UndoTimelineModel(source, clock: () => clock);
      async.flushMicrotasks();
      var notified = 0;
      model.addListener(() => notified++);
      clock = now.add(const Duration(minutes: 1));
      async.elapse(const Duration(minutes: 1));
      expect(model.now, clock);
      expect(notified, 1);
      model.dispose();
      expect(async.pendingTimers, isEmpty);
      expect(source.listened, isFalse);
    });
  });

  test('the short id is 12 hex digits; the args tag is read', () {
    expect(shortOperationId(opId(0)), '1a2b3c4d5e6f');
    expect(operationArgs(testOperation(0, now: now, args: 'jj new')), 'jj new');
    expect(operationArgs(testOperation(0, now: now)), isNull);
  });
}

/// [FakeTimelineSource] whose read throws a [StateError] (a closed handle) while [fail] is set.
class _ThrowingSource extends FakeTimelineSource {
  _ThrowingSource(super.operations);

  var fail = false;

  @override
  Future<List<Operation>> opLog({required int limit}) {
    if (fail) {
      throw StateError('RepoHandle is already closed');
    }
    return super.opLog(limit: limit);
  }
}
