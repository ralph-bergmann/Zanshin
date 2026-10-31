// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../../helpers/scripted_graph_source.dart';

/// Story 10.5's view model on fake ports: the I/O matrix and the epic's witnesses.
void main() {
  late ScriptedGraphSource source;
  setUp(() => source = ScriptedGraphSource());

  final noon = DateTime.utc(2026, 10, 30, 12);

  /// A model on [source] at fake time (noon UTC plus the elapsed time unless [clock] says otherwise), settled.
  GraphViewModel start(FakeAsync async, {DateTime Function()? clock, GraphActions? actions}) {
    final model = GraphViewModel()..init(source, clock: clock ?? () => noon.add(async.elapsed), actions: actions);
    async.flushMicrotasks();
    return model;
  }

  void heads(FakeAsync async) {
    source.emit(const OpHeadsChangedEvent(0, <String>[]));
    async.flushMicrotasks();
  }

  test('first load: the pass-throughs come from logDefaults and zanshin_core, @ is centred without animation', () {
    fakeAsync((async) {
      final GraphViewModel model = start(async);
      expect(source.requests, hasLength(1));
      final GraphRequest request = source.requests.single;
      expect(request.revset, 'L');
      expect(request.prioritize, 'P');
      expect(request.shortPrefixes, 'S');
      expect(request.anchors, <String>['trunk()', 'present(@)']);
      expect(request.anchors, defaultGraphAnchors);
      expect(request.mode, GraphMode.free);
      expect(request.order, GraphLaneOrder.compact);
      expect(request.utcOffsetMin, 0);
      expect(model.revset, 'L');
      expect(model.layout, isNotNull);
      expect(model.loading, isFalse);
      expect(model.reveal?.key, 'a');
      expect(model.reveal?.animate, isFalse);
      expect(model.shown, 3);
      model.dispose();
    });
  });

  test('loading until the first layout lands', () {
    fakeAsync((async) {
      source.hold = true;
      final GraphViewModel model = start(async);
      expect(model.loading, isTrue);
      source.held.single.complete(GraphLoad(keysLayout(<String>['a'], at: 'a')));
      async.flushMicrotasks();
      expect(model.loading, isFalse);
      model.dispose();
    });
  });

  test('burst: three events during a load cause exactly one more request; the in-flight result is dropped', () {
    fakeAsync((async) {
      source.hold = true;
      final GraphViewModel model = start(async);
      for (var i = 0; i < 3; i++) {
        heads(async);
      }
      expect(source.requests, hasLength(1));
      final RecordedGraphLayout stale = keysLayout(<String>['old'], at: 'old');
      source.held[0].complete(GraphLoad(stale));
      async.flushMicrotasks();
      expect(model.layout, isNull, reason: 'superseded');
      expect(source.requests, hasLength(2));
      final RecordedGraphLayout fresh = keysLayout(<String>['new'], at: 'new');
      source.held[1].complete(GraphLoad(fresh));
      async.flushMicrotasks();
      expect(model.layout, same(fresh));
      expect(model.reveal?.key, 'new', reason: 'the re-centre of the first layout survived the dropped result');
      expect(source.requests, hasLength(2));
      model.dispose();
    });
  });

  test("the view's own snapshot converges: one event during the first layout call gives two requests, then quiet", () {
    fakeAsync((async) {
      var calls = 0;
      source.onLayout = (_) {
        if (calls++ == 0) {
          source.emit(const OpHeadsChangedEvent(0, <String>[]));
        }
      };
      final GraphViewModel model = start(async);
      async.elapse(const Duration(seconds: 5));
      expect(source.requests, hasLength(2));
      expect(model.layout, isNotNull);
      model.dispose();
    });
  });

  test('a revset error keeps the layout and sets revsetError, no retry state; the next success clears it', () {
    fakeAsync((async) {
      final GraphViewModel model = start(async);
      final GraphLayout? before = model.layout;
      source.respond = (_) => throw const ZanshinFfiException('jj.revset_parse_error', 'bad');
      model.setRevset('bad(');
      async.flushMicrotasks();
      expect(model.layout, same(before));
      expect(model.revsetError?.code, 'jj.revset_parse_error');
      expect(model.error, isNull);
      source.respond = (_) => keysLayout(<String>['a'], at: 'a');
      model.setRevset('all()');
      async.flushMicrotasks();
      expect(model.revsetError, isNull);
      expect(model.layout, isNot(same(before)));
      model.dispose();
    });
  });

  test('a revset resolution error is a revset error too', () {
    fakeAsync((async) {
      source.respond = (_) => throw const ZanshinFfiException('jj.revset_resolution_error', 'x');
      final GraphViewModel model = start(async);
      expect(model.revsetError?.code, 'jj.revset_resolution_error');
      expect(model.layout, isNull);
      model.dispose();
    });
  });

  test('an empty layout is the empty state, not an error', () {
    fakeAsync((async) {
      source.respond = (_) => keysLayout(const <String>[]);
      final GraphViewModel model = start(async);
      expect(model.empty, isTrue);
      expect(model.shown, 0);
      expect(model.error, isNull);
      expect(model.reveal, isNull, reason: 'no @ to centre');
      model.dispose();
    });
  });

  test('another error keeps the layout and sets error; retry requests once', () {
    fakeAsync((async) {
      final GraphViewModel model = start(async);
      final GraphLayout? before = model.layout;
      source.respond = (_) => throw const ZanshinFfiException('jj.io_error');
      heads(async);
      expect(model.error?.code, 'jj.io_error');
      expect(model.layout, same(before));
      expect(model.empty, isFalse);
      source.respond = (_) => keysLayout(<String>['a'], at: 'a');
      final int count = source.requests.length;
      model.retry();
      async.flushMicrotasks();
      expect(source.requests, hasLength(count + 1));
      expect(model.error, isNull);
      model.dispose();
    });
  });

  test('a failed logDefaults is an error, and retry reads them again', () {
    fakeAsync((async) {
      final LogDefaults realDefaults = source.defaults;
      var fail = true;
      final failing = _FailingDefaults(source, () => fail);
      final model = GraphViewModel()..init(failing, clock: () => noon);
      async.flushMicrotasks();
      expect(model.error?.code, 'jj.io_error');
      expect(source.requests, isEmpty);
      fail = false;
      model.retry();
      async.flushMicrotasks();
      expect(model.error, isNull);
      expect(source.requests.single.revset, realDefaults.log);
      model.dispose();
    });
  });

  group('stale', () {
    test('stale at open: no layout, the sibling cause with jj op integrate; a heartbeat reloads, success clears', () {
      fakeAsync((async) {
        source.respond = (_) => throw staleError('sibling_operation');
        final GraphViewModel model = start(async);
        expect(model.layout, isNull);
        expect(model.stale?.cause, GraphStaleCause.siblingOperation);
        expect(model.stale?.command, 'jj op integrate aaaaaaaaaaaa');
        expect(
          model.stale?.message,
          "The repo was loaded at operation bbbbbbbbbbbb, which seems to be a sibling of the working copy's "
          'operation aaaaaaaaaaaa',
        );
        expect(model.error, isNull, reason: 'no retry state');
        source
          ..respond = ((_) => keysLayout(<String>['a'], at: 'a'))
          ..emit(const WorkingCopyHeartbeatEvent(0, <String>[]));
        async.flushMicrotasks();
        expect(source.requests, hasLength(2));
        expect(model.stale, isNull);
        expect(model.layout, isNotNull);
        model.dispose();
      });
    });

    test('a heartbeat outside the stale state requests nothing', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async);
        source.emit(const WorkingCopyHeartbeatEvent(0, <String>[]));
        async.flushMicrotasks();
        expect(source.requests, hasLength(1));
        model.dispose();
      });
    });

    test('a stale working copy after a layout keeps it', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async);
        final GraphLayout? before = model.layout;
        source.respond = (_) => throw staleError('stale');
        heads(async);
        expect(model.layout, same(before));
        expect(model.stale?.command, 'jj workspace update-stale');
        expect(model.stale?.message, 'The working copy is stale (not updated since operation aaaaaaaaaaaa).');
        model.dispose();
      });
    });

    test('the refusal reads as the cause, Rust message and the hint command', () {
      expect(
        GraphStale.fromError(
          const ZanshinFfiException.withReport(
            'jj.stale_working_copy',
            'operation_not_found\nw\nr\nmessage from Rust',
            precondition: null,
            warnings: <ZanshinWarning>[],
            hints: <String>['Run `some command` to recover.\nSee `elsewhere`.', 'Run `second`.'],
          ),
        ),
        const GraphStale(
          cause: GraphStaleCause.operationNotFound,
          message: 'message from Rust',
          command: 'some command',
        ),
      );
      expect(GraphStale.fromError(staleError('sibling_operation')).cause, GraphStaleCause.siblingOperation);
      // An older or hand-built error: no fourth line, no hint.
      expect(
        GraphStale.fromError(const ZanshinFfiException('jj.stale_working_copy', 'stale\nabc\ndef')),
        const GraphStale(cause: GraphStaleCause.stale, message: null, command: ''),
      );
      expect(
        GraphStale.fromError(const ZanshinFfiException('jj.stale_working_copy')),
        const GraphStale(cause: GraphStaleCause.stale, message: null, command: ''),
      );
    });

    test('updateStale: busy, then the recovery and one reload; a failure keeps it stale, logged, no reload', () {
      fakeAsync((async) {
        source.respond = (_) => throw staleError('stale');
        final GraphViewModel model = start(async);
        final gate = Completer<StaleRecovery>();
        source.update = () => gate.future;
        unawaited(model.updateStale());
        async.flushMicrotasks();
        expect(model.staleUpdating, isTrue);
        source.respond = (_) => keysLayout(<String>['a'], at: 'a');
        gate.complete(
          const StaleRecovery(
            outcome: StaleRecoveryOutcome.updated,
            commitId: 'c',
            checkout: null,
            gitHeadResetOpId: null,
            snapshotStats: SnapshotStats(untracked: <UntrackedPath>[], invalidUtf8Paths: <String>[]),
            opId: 'o',
          ),
        );
        async.flushMicrotasks();
        expect(model.staleUpdating, isFalse);
        expect(model.lastStaleRecovery?.commitId, 'c');
        expect(source.requests, hasLength(2));
        expect(model.stale, isNull);

        source.respond = (_) => throw staleError('stale');
        heads(async);
        source.update = () async => throw const ZanshinFfiException('jj.io_error');
        unawaited(model.updateStale());
        async.flushMicrotasks();
        expect(model.staleUpdateError?.code, 'jj.io_error');
        expect(model.stale, isNotNull);
        expect(source.requests, hasLength(3), reason: 'no reload after a failed update');
        model.dispose();
      });
    });
  });

  group('scroll precedence', () {
    test(
      'a revset switch with a reveal lands the reveal, not @; an absent key still names it (the anchor falls back)',
      () {
        fakeAsync((async) {
          final GraphViewModel model = start(async);
          source.respond = (_) => keysLayout(<String>['a', 'k'], at: 'a');
          model.setRevset('all()', reveal: 'k');
          async.flushMicrotasks();
          expect(source.requests.last.revset, 'all()');
          expect(source.requests.last.keepOpenKeys, <String>{'k'});
          expect(model.reveal?.key, 'k');

          model.setRevset('L', reveal: 'gone');
          async.flushMicrotasks();
          expect(model.reveal?.key, 'gone');
          model.dispose();
        });
      },
    );

    test('a revset switch re-centres on @; an event-driven reload after it does not, even when @ moved', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async)..setRevset('all()');
        async.flushMicrotasks();
        expect(model.reveal?.key, 'a');
        source.respond = (_) => keysLayout(<String>['b', 'a'], at: 'b');
        heads(async);
        expect(model.reveal, isNull, reason: 'jj edit moved @: the anchor holds');
        model.dispose();
      });
    });

    test('a mode switch re-centres on @; with @ absent it keeps the anchor', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async)..setMode(GraphMode.compact);
        async.flushMicrotasks();
        expect(source.requests.last.mode, GraphMode.compact);
        expect(model.reveal?.key, 'a');
        source.respond = (_) => keysLayout(<String>['x', 'y']);
        model.setLaneOrder(GraphLaneOrder.greedy);
        async.flushMicrotasks();
        expect(source.requests.last.order, GraphLaneOrder.greedy);
        expect(model.reveal, isNull);
        final int count = source.requests.length;
        model.setMode(GraphMode.compact);
        async.flushMicrotasks();
        expect(source.requests, hasLength(count), reason: 'no switch, no request');
        model.dispose();
      });
    });

    test('a pending reveal survives a superseded request and is consumed once', () {
      fakeAsync((async) {
        source.hold = true;
        final GraphViewModel model = start(async)..setRevset('all()', reveal: 'k');
        source.held[0].complete(GraphLoad(keysLayout(<String>['a', 'k'], at: 'a')));
        async.flushMicrotasks();
        expect(model.layout, isNull);
        source.held[1].complete(GraphLoad(keysLayout(<String>['a', 'k'], at: 'a')));
        async.flushMicrotasks();
        expect(model.reveal?.key, 'k');
        source.hold = false;
        heads(async);
        expect(model.reveal, isNull);
        model.dispose();
      });
    });

    test('scroll targets apply at once without a pending request and leave the selection alone', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async)..scrollToSelection();
        expect(model.reveal?.key, 'a', reason: 'nothing without a selection: the first reveal stays');
        model
          ..select('c')
          ..scrollToWorkingCopy();
        expect(model.reveal?.key, 'a');
        expect(model.reveal?.animate, isTrue);
        model.scrollToSelection();
        expect(model.reveal?.key, 'c');
        expect(model.selected, 'c');
        model.revealKey('b');
        expect(model.reveal?.key, 'b');
        expect(source.requests, hasLength(1));
        model.dispose();
      });
    });

    test('a scroll target during a request lands with its layout', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async);
        source.hold = true;
        heads(async);
        model.scrollToWorkingCopy();
        source.held.single.complete(GraphLoad(keysLayout(<String>['b', 'a'], at: 'b')));
        async.flushMicrotasks();
        expect(model.reveal?.key, 'b');
        expect(model.reveal?.animate, isFalse);
        model.dispose();
      });
    });
  });

  test('the selection survives a reload that keeps its key and clears when a layout lacks it', () {
    fakeAsync((async) {
      final GraphViewModel model = start(async)..select('b');
      heads(async);
      expect(model.selected, 'b');
      expect(source.requests.last.keepOpenKeys, <String>{'b'});
      source.respond = (_) => keysLayout(<String>['a', 'c'], at: 'a');
      heads(async);
      expect(model.selected, isNull);
      model.dispose();
    });
  });

  test('a WatchErrorEvent sets degraded', () {
    fakeAsync((async) {
      final GraphViewModel model = start(async);
      source.emit(const WatchErrorEvent(0, 'x'));
      expect(model.degraded, 'x');
      model.dispose();
    });
  });

  test('configChanged re-reads logDefaults: one request, no reveal, the log revset follows; an explicit one stays', () {
    fakeAsync((async) {
      final GraphViewModel model = start(async);
      source.defaults = const LogDefaults(
        log: 'L2',
        logGraphPrioritize: 'P2',
        shortPrefixes: 'S2',
        syntheticElided: false,
      );
      model.configChanged();
      async.flushMicrotasks();
      expect(source.defaultsReads, 2);
      expect(source.requests, hasLength(2));
      expect(source.requests.last.revset, 'L2');
      expect(source.requests.last.prioritize, 'P2');
      expect(model.reveal, isNull);

      model.setRevset('all()');
      async.flushMicrotasks();
      source.defaults = const LogDefaults(
        log: 'L3',
        logGraphPrioritize: 'P',
        shortPrefixes: 'S',
        syntheticElided: false,
      );
      model.configChanged();
      async.flushMicrotasks();
      expect(source.requests.last.revset, 'all()');
      model.dispose();
    });
  });

  test('now: fresh on each layout and on refreshNow, ticked at each minute boundary, midnight on time', () {
    final start0 = DateTime(2026, 10, 30, 23, 59, 30);
    fakeAsync((async) {
      final GraphViewModel model = start(async, clock: () => start0.add(async.elapsed));
      expect(model.now.value, start0.millisecondsSinceEpoch);
      async.elapse(const Duration(seconds: 29));
      expect(model.now.value, start0.millisecondsSinceEpoch);
      async.elapse(const Duration(seconds: 1));
      expect(model.now.value, DateTime(2026, 10, 31).millisecondsSinceEpoch);
      async.elapse(const Duration(seconds: 10));
      model.refreshNow();
      expect(model.now.value, DateTime(2026, 10, 31, 0, 0, 10).millisecondsSinceEpoch);
      async.elapse(const Duration(seconds: 5));
      heads(async);
      expect(model.now.value, DateTime(2026, 10, 31, 0, 0, 15).millisecondsSinceEpoch);
      async.elapse(const Duration(seconds: 45));
      expect(model.now.value, DateTime(2026, 10, 31, 0, 1).millisecondsSinceEpoch);
      model.dispose();
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('the request carries the local UTC offset at issue time', () {
    fakeAsync((async) {
      final local = DateTime(2026, 10, 30, 12);
      final GraphViewModel model = start(async, clock: () => local);
      expect(source.requests.single.utcOffsetMin, local.timeZoneOffset.inMinutes);
      model.dispose();
    });
  });

  test('run reloads after a finished action, not after a refusal', () {
    fakeAsync((async) {
      final actions = _Actions();
      final GraphViewModel model = start(async, actions: actions);
      GraphActionResult? result;
      unawaited(model.run(const GraphAction('edit', ids: <String>['b'])).then((r) => result = r));
      async.flushMicrotasks();
      expect(result, isA<GraphActionDone>());
      expect(source.requests, hasLength(2));
      actions.refuse = true;
      unawaited(model.run(const GraphAction('abandon')).then((r) => result = r));
      async.flushMicrotasks();
      expect(result, isA<GraphActionRefused>());
      expect(source.requests, hasLength(2));
      expect(actions.ran.map((a) => a.verb), <String>['edit', 'abandon']);
      model.dispose();
    });
  });

  test('edit runs jj edit on the key and reloads; without an actions port it does nothing', () {
    fakeAsync((async) {
      final actions = _Actions();
      final GraphViewModel model = start(async, actions: actions);
      unawaited(model.edit('b'));
      async.flushMicrotasks();
      expect(actions.ran.single.verb, 'edit');
      expect(actions.ran.single.ids, <String>['b']);
      expect(source.requests, hasLength(2));
      expect(model.selected, isNull, reason: 'edit selects nothing');
      model.dispose();

      final GraphViewModel bare = start(async);
      GraphActionResult? result = const GraphActionDone();
      unawaited(bare.edit('b').then((r) => result = r));
      async.flushMicrotasks();
      expect(result, isNull);
      bare.dispose();
    });
  });

  test('goTo selects, reveals centred with animation and pulses; again restarts it; an absent key does nothing', () {
    fakeAsync((async) {
      final GraphViewModel model = start(async)..goTo('c');
      expect(model.selected, 'c');
      expect(model.reveal?.key, 'c');
      expect(model.reveal?.animate, isTrue);
      final GraphPulse? first = model.pulse.value;
      expect(first?.key, 'c');
      model.goTo('c');
      expect(model.pulse.value, isNot(first), reason: 'a repeat is a new pulse');
      final GraphPulse? second = model.pulse.value;
      model.goTo('zzz');
      expect(model.pulse.value, second);
      expect(model.selected, 'c');
      model.dispose();
    });
  });

  test('workingCopyDirection is what the view reports', () {
    fakeAsync((async) {
      final GraphViewModel model = start(async);
      expect(model.workingCopyDirection.value, isNull);
      model.setWorkingCopyDirection(GraphDirection.down);
      expect(model.workingCopyDirection.value, GraphDirection.down);
      model.dispose();
    });
  });

  test('disposed while logDefaults is pending: no request follows', () {
    fakeAsync((async) {
      final Completer<LogDefaults> gate = source.defaultsGate = Completer<LogDefaults>();
      start(async).dispose();
      gate.complete(source.defaults);
      async.flushMicrotasks();
      expect(source.defaultsReads, 1);
      expect(source.requests, isEmpty);
    });
  });

  test('after dispose no event requests anything and no timer is left', () {
    fakeAsync((async) {
      start(async).dispose();
      heads(async);
      expect(source.requests, hasLength(1));
      expect(async.pendingTimers, isEmpty);
    });
  });
}

class _Actions implements GraphActions {
  var refuse = false;
  final ran = <GraphAction>[];

  @override
  Future<GraphActionResult> run(GraphAction action) async {
    ran.add(action);
    return refuse ? const GraphActionRefused('immutable') : const GraphActionDone();
  }
}

/// [source] whose `logDefaults()` fails with `jj.io_error` while [failing] says so.
class _FailingDefaults implements GraphSource {
  _FailingDefaults(this.source, this.failing);

  final ScriptedGraphSource source;
  final bool Function() failing;

  @override
  Future<LogDefaults> logDefaults() async {
    if (failing()) {
      throw const ZanshinFfiException('jj.io_error');
    }
    return source.logDefaults();
  }

  @override
  Future<GraphLoad> layout(GraphRequest request) => source.layout(request);

  @override
  Stream<RepoEvent> get events => source.events;

  @override
  Future<StaleRecovery> updateStale() => source.updateStale();
}
