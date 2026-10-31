// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart' show GraphRevealAlignment;
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

    test('a stacks switch issues one request and keeps the anchor; no switch, no request', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async);
        expect(source.requests.single.stacks, isFalse);
        expect(model.stacks, isFalse);
        model.setStacks(true);
        async.flushMicrotasks();
        expect(source.requests, hasLength(2));
        expect(source.requests.last.stacks, isTrue);
        expect(model.stacks, isTrue);
        expect(model.reveal, isNull, reason: 'no re-centre on @');
        model.setStacks(true);
        async.flushMicrotasks();
        expect(source.requests, hasLength(2));
        model.dispose();
      });
    });

    test('init sends the given mode and stacks with the first request', () {
      fakeAsync((async) {
        final model = GraphViewModel()..init(source, clock: () => noon, mode: GraphMode.compact, stacks: true);
        async.flushMicrotasks();
        expect(source.requests.single.mode, GraphMode.compact);
        expect(source.requests.single.stacks, isTrue);
        expect(model.mode, GraphMode.compact);
        expect(model.reveal?.key, 'a', reason: 'the first layout still re-centres on @');
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

  group('Story 10.9: the action runner', () {
    late _Actions actions;
    setUp(() => actions = _Actions());

    /// Runs [action] on [model] and settles; the result.
    GraphActionResult? run(FakeAsync async, GraphViewModel model, GraphAction action) {
      GraphActionResult? result;
      unawaited(model.run(action).then((r) => result = r));
      async.flushMicrotasks();
      return result;
    }

    test('edit: one port call, then exactly one layout request; no selection change, no anchor, no reveal', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        final anchors = <String?>[];
        model.addListener(() => anchors.add(model.anchorHint));
        final GraphActionResult? result = run(async, model, const GraphEdit('b'));
        expect(result, isA<GraphActionDone>());
        expect(actions.ran.single, isA<GraphEdit>().having((a) => a.id, 'id', 'b'));
        expect(source.requests, hasLength(2));
        expect(model.selected, isNull);
        expect(anchors, everyElement(isNull));
        expect(model.reveal, isNull);
        model.dispose();
      });
    });

    test(
      'new on the selected parent: anchored on it during the reload, the new change selected and revealed covered',
      () {
        fakeAsync((async) {
          final GraphViewModel model = start(async, actions: actions)..select('b');
          actions.born = <String>['n'];
          source.hold = true;
          run(async, model, const GraphNew(parents: <String>['b']));
          expect(model.anchorHint, 'b', reason: 'held while the reload runs');
          expect(model.selected, 'n');
          expect(source.requests.last.keepOpenKeys, contains('n'));
          source.held.single.complete(GraphLoad(keysLayout(<String>['n', 'a', 'b', 'c'], at: 'n')));
          async.flushMicrotasks();
          expect(model.anchorHint, isNull);
          expect(model.selected, 'n');
          expect(model.reveal?.key, 'n');
          expect(model.reveal?.alignment, GraphRevealAlignment.covered);
          expect(model.outcome.value?.born, <String>['n']);
          expect(model.outcome.value?.anchor, 'b');
          model.dispose();
        });
      },
    );

    test('new on a parent that is not selected: the selection stays, the new change is revealed covered', () {
      fakeAsync((async) {
        source.respond = (_) => keysLayout(<String>['n', 'a', 'b', 'c'], at: 'a');
        final GraphViewModel model = start(async, actions: actions)..select('c');
        actions.born = <String>['n'];
        run(async, model, const GraphNew(parents: <String>['b']));
        expect(model.selected, 'c');
        expect(model.reveal?.key, 'n');
        expect(model.reveal?.alignment, GraphRevealAlignment.covered);
        model.dispose();
      });
    });

    test("abandon: the selection clears, the reload is anchored on the change's first shown parent", () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions)..select('b');
        source.hold = true;
        run(async, model, const GraphAbandon(<String>['b']));
        expect(model.selected, isNull);
        expect(model.anchorHint, 'c');
        model.dispose();
      });
    });

    test('squash -r: the vanished source hands the selection to its parent, the destination is anchor and flash', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions)..select('b');
        actions.abandoned = <String>['b'];
        run(async, model, const GraphSquash(revision: 'b'));
        expect(model.selected, 'c');
        expect(model.outcome.value?.anchor, 'c');
        expect(model.outcome.value?.flash, <String>['c']);
        model.dispose();
      });
    });

    test('squash --from --into: the selection moves to the destination when the source vanished', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions)..select('b');
        actions.abandoned = <String>['b'];
        run(async, model, const GraphSquash(from: <String>['b'], into: 'a'));
        expect(model.selected, 'a');
        expect(model.outcome.value?.anchor, 'a');
        expect(model.outcome.value?.flash, <String>['a']);

        // A kept source keeps the selection.
        actions.abandoned = const <String>[];
        run(async, model, const GraphSquash(from: <String>['c'], into: 'b', keepEmptied: true));
        expect(model.selected, 'a');
        model.dispose();
      });
    });

    test('squash with the defaults: @ into its first parent, which takes the selection, the anchor and the flash', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions)..select('a');
        actions.abandoned = <String>['a'];
        run(async, model, const GraphSquash());
        expect(model.selected, 'b');
        expect(model.outcome.value?.anchor, 'b');
        expect(model.outcome.value?.flash, <String>['b']);
        model.dispose();
      });
    });

    test('squash --from without --into goes into @: @ is anchor and flash', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        run(async, model, const GraphSquash(from: <String>['b']));
        expect(model.outcome.value?.anchor, 'a');
        expect(model.outcome.value?.flash, <String>['a']);
        model.dispose();
      });
    });

    test('new -A after the selected change selects the new change', () {
      fakeAsync((async) {
        source.respond = (_) => keysLayout(<String>['a', 'n', 'b', 'c'], at: 'n');
        final GraphViewModel model = start(async, actions: actions)..select('b');
        actions.born = <String>['n'];
        run(async, model, const GraphNew(insertAfter: <String>['b']));
        expect(model.selected, 'n');
        model.dispose();
      });
    });

    test('a non-jj error from the port is rethrown and leaves the runner free', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        actions.crash = StateError('RepoHandle is already closed');
        Object? thrown;
        unawaited(model.run(const GraphEdit('b')).then<void>((_) {}, onError: (Object error) => thrown = error));
        async.flushMicrotasks();
        expect(thrown, isA<StateError>());
        expect(model.actionsEnabled, isTrue);
        expect(model.pendingKeys, isEmpty);
        expect(model.anchorHint, isNull);
        actions.crash = null;
        expect(run(async, model, const GraphEdit('b')), isA<GraphActionDone>());
        model.dispose();
      });
    });

    test('revert: anchored on the reverted change, the new change born and revealed covered, no selection change', () {
      fakeAsync((async) {
        source.respond = (_) => keysLayout(<String>['a', 'n', 'b', 'c'], at: 'a');
        final GraphViewModel model = start(async, actions: actions);
        actions.born = <String>['n'];
        run(async, model, const GraphRevert('b'));
        expect(actions.ran.single.command, 'jj revert -r b -B @');
        expect(model.outcome.value?.anchor, 'b');
        expect(model.outcome.value?.born, <String>['n']);
        expect(model.reveal?.key, 'n');
        expect(model.reveal?.alignment, GraphRevealAlignment.covered);
        expect(model.selected, isNull);
        model.dispose();
      });
    });

    test('revert with a selection (the inspector open) selects the born change (Story 10.8 I5)', () {
      fakeAsync((async) {
        source.respond = (_) => keysLayout(<String>['a', 'n', 'b', 'c'], at: 'a');
        final GraphViewModel model = start(async, actions: actions)..select('b');
        actions.born = <String>['n'];
        run(async, model, const GraphRevert('b'));
        expect(model.selected, 'n');
        model.dispose();
      });
    });

    test('a refusal is published verbatim and reloads nothing; a stale refusal reloads into the stale state', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        const refusal = ZanshinFfiException.withReport(
          'jj.immutable',
          'ctx',
          precondition: null,
          warnings: <ZanshinWarning>[ZanshinWarning(code: 'jj.identity_missing', message: 'w')],
          hints: <String>['hint'],
        );
        actions.refuse = refusal;
        final GraphActionResult? result = run(async, model, const GraphEdit('c'));
        expect(result, isA<GraphActionRefused>().having((r) => r.error, 'error', same(refusal)));
        expect(model.outcome.value?.error, same(refusal));
        expect(model.outcome.value?.warnings, refusal.warnings);
        expect(source.requests, hasLength(1));
        expect(model.actionsEnabled, isTrue);
        expect(model.anchorHint, isNull);

        actions.refuse = staleError('stale');
        source.respond = (_) => throw staleError('stale');
        run(async, model, const GraphEdit('c'));
        expect(source.requests, hasLength(2));
        expect(model.stale, isNotNull);
        expect(model.actionsEnabled, isFalse);
        model.dispose();
      });
    });

    test("a success's warnings are on the outcome", () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        actions.warnings = const <ZanshinWarning>[
          ZanshinWarning(code: ZanshinWarningCode.identityMissing, message: 'm'),
        ];
        run(async, model, const GraphNew(parents: <String>['a']));
        expect(model.outcome.value?.warnings.single.code, 'jj.identity_missing');
        model.dispose();
      });
    });

    test('pending: the action keys and no actions while the port runs; cleared after', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        final Completer<MutationResult> gate = actions.gate = Completer<MutationResult>();
        unawaited(model.run(const GraphAbandon(<String>['b', 'c'])));
        async.flushMicrotasks();
        expect(model.pendingKeys, <String>{'b', 'c'});
        expect(model.actionsEnabled, isFalse);
        gate.complete(_result('op1'));
        async.flushMicrotasks();
        expect(model.pendingKeys, isEmpty);
        expect(model.actionsEnabled, isTrue);
        model.dispose();
      });
    });

    test('a second double-click while edit runs calls nothing and reports busy (I2)', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        final Completer<MutationResult> gate = actions.gate = Completer<MutationResult>();
        unawaited(model.edit('b'));
        GraphActionResult? second;
        unawaited(model.edit('b').then((r) => second = r));
        async.flushMicrotasks();
        expect(actions.ran, hasLength(1));
        expect(second, isA<GraphActionDisabled>().having((r) => r.reason, 'reason', GraphDisabledReason.busy));
        gate.complete(_result('op1'));
        async.flushMicrotasks();
        expect(source.requests, hasLength(2));
        model.dispose();
      });
    });

    test('stale: run, undoLast and redoLast are disabled with the reason and touch no port', () {
      fakeAsync((async) {
        source.respond = (_) => throw staleError('stale');
        final GraphViewModel model = start(async, actions: actions);
        expect(model.actionsEnabled, isFalse);
        for (final trigger in <Future<GraphActionResult> Function()>[
          () => model.run(const GraphEdit('b')),
          model.undoLast,
          model.redoLast,
        ]) {
          GraphActionResult? result;
          unawaited(trigger().then((r) => result = r));
          async.flushMicrotasks();
          expect(result, isA<GraphActionDisabled>().having((r) => r.reason, 'reason', GraphDisabledReason.stale));
        }
        expect(actions.ran, isEmpty);
        expect(actions.headReads, 0);
        model.dispose();
      });
    });

    test('undo while the head is the own operation: jj undo of that action, then redo is offered', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        expect(model.undoable, isNull);
        GraphActionResult? result;
        unawaited(model.undoLast().then((r) => result = r));
        async.flushMicrotasks();
        expect(result, isA<GraphActionDisabled>().having((r) => r.reason, 'reason', GraphDisabledReason.nothingToUndo));

        run(async, model, const GraphEdit('b'));
        final GraphOutcome? own = model.undoable;
        expect(own?.action, isA<GraphEdit>());
        expect(own?.undoable, isTrue);
        unawaited(model.undoLast().then((r) => result = r));
        async.flushMicrotasks();
        expect(result, isA<GraphActionDone>());
        expect(actions.ran.last, isA<GraphUndo>().having((a) => a.of, 'of', same(own!.action)));
        expect(model.outcome.value?.action, isA<GraphUndo>());
        expect(model.undoable, isNull);
        expect(model.redoable?.action, isA<GraphUndo>());
        expect(source.requests, hasLength(3));

        unawaited(model.redoLast());
        async.flushMicrotasks();
        expect(actions.ran.last, isA<GraphRedo>().having((a) => a.of, 'of', same(own.action)));
        expect(model.redoable, isNull);
        expect(model.undoable?.action, isA<GraphRedo>());
        unawaited(model.undoLast());
        async.flushMicrotasks();
        expect(actions.ran.last, isA<GraphUndo>().having((a) => a.of, 'of', same(own.action)), reason: 'unwrapped');
        model.dispose();
      });
    });

    test('a foreign operation drops the undo: on the op-heads event, and on demand', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        run(async, model, const GraphEdit('b'));
        expect(model.undoable, isNotNull);
        actions.head = 'foreign';
        heads(async);
        expect(model.undoable, isNull);
        GraphActionResult? result;
        unawaited(model.undoLast().then((r) => result = r));
        async.flushMicrotasks();
        expect(result, isA<GraphActionDisabled>().having((r) => r.reason, 'reason', GraphDisabledReason.nothingToUndo));

        run(async, model, const GraphEdit('c'));
        expect(model.undoable, isNotNull);
        actions.head = 'foreign2';
        unawaited(model.undoLast().then((r) => result = r));
        async.flushMicrotasks();
        expect(
          result,
          isA<GraphActionDisabled>().having((r) => r.reason, 'reason', GraphDisabledReason.foreignOperation),
        );
        expect(model.undoable, isNull);
        expect(actions.ran.whereType<GraphUndo>(), isEmpty);
        model.dispose();
      });
    });

    test('an own operation still at the head survives its op-heads event', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        run(async, model, const GraphEdit('b'));
        heads(async);
        expect(model.undoable, isNotNull);
        model.dispose();
      });
    });

    test('a verb that wrote no operation is not undoable', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        actions.noOp = true;
        final GraphActionResult? result = run(async, model, const GraphEdit('a'));
        expect((result! as GraphActionDone).outcome.undoable, isFalse);
        expect(model.undoable, isNull);
        model.dispose();
      });
    });

    test('updateStale drops the undo', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        run(async, model, const GraphEdit('b'));
        unawaited(model.updateStale());
        async.flushMicrotasks();
        expect(model.undoable, isNull);
        model.dispose();
      });
    });

    test('the action target is the selection, else @', () {
      fakeAsync((async) {
        final GraphViewModel model = start(async, actions: actions);
        expect(model.actionTarget, 'a');
        model.select('c');
        expect(model.actionTarget, 'c');
        model.dispose();
      });
    });

    test('edit without an actions port does nothing', () {
      fakeAsync((async) {
        final GraphViewModel bare = start(async);
        GraphActionResult? result = const GraphActionDisabled(GraphDisabledReason.busy);
        unawaited(bare.edit('b').then((r) => result = r));
        async.flushMicrotasks();
        expect(result, isNull);
        bare.dispose();
      });
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

MutationResult _result(
  String op, {
  List<String> born = const <String>[],
  List<String> abandoned = const <String>[],
  List<ZanshinWarning> warnings = const <ZanshinWarning>[],
}) => MutationResult(
  newOpId: op,
  newChangeIds: born,
  abandonedChangeIds: abandoned,
  workingCopyChangeId: null,
  finish: null,
  warnings: warnings,
);

/// A fake port: each run writes operation `op<n>` (the head follows) with [born], [abandoned] and [warnings], or
/// nothing ([noOp]), or throws [refuse], or waits on [gate].
class _Actions implements GraphActions {
  final ran = <GraphAction>[];
  var head = 'op0';
  var headReads = 0;
  ZanshinFfiException? refuse;
  Object? crash;
  Completer<MutationResult>? gate;
  var noOp = false;
  var born = const <String>[];
  var abandoned = const <String>[];
  var warnings = const <ZanshinWarning>[];

  @override
  Future<String> headOpId() async {
    headReads++;
    return head;
  }

  @override
  Future<MutationResult> run(GraphAction action) async {
    ran.add(action);
    if (refuse case final error?) {
      throw error;
    }
    if (crash case final error?) {
      throw error;
    }
    if (gate case final gate?) {
      return gate.future;
    }
    if (!noOp) {
      head = 'op${ran.length}';
    }
    return _result(head, born: born, abandoned: abandoned, warnings: warnings);
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
  Future<Map<String, GraphCommitContent>> content(String? operationId, List<String> commitIds) =>
      source.content(operationId, commitIds);

  @override
  Stream<RepoEvent> get events => source.events;

  @override
  Future<StaleRecovery> updateStale() => source.updateStale();
}
