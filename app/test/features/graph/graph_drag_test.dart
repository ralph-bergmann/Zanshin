// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/l10n/app_localizations_en.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart'
    show GraphCanvas, graphAutoScrollStep, graphAutoScrollZone;
import 'package:zanshin/src/features/graph/graph_card.dart' show GraphCardController;
import 'package:zanshin/src/features/graph/graph_card_render.dart';
import 'package:zanshin/src/features/graph/graph_drag.dart';
import 'package:zanshin/src/features/graph/graph_drop_menu.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_stack_card.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/graph_viewport_render.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

final _en = AppLocalizationsEn();

const _available = ActionOutcome(
  status: ActionStatus.available,
  refusal: null,
  combinedDescriptionNeeded: false,
  allowBackwardsNeeded: false,
);
const _noOp = ActionOutcome(
  status: ActionStatus.noOp,
  refusal: null,
  combinedDescriptionNeeded: false,
  allowBackwardsNeeded: false,
);
const _backwards = ActionOutcome(
  status: ActionStatus.available,
  refusal: null,
  combinedDescriptionNeeded: false,
  allowBackwardsNeeded: true,
);
ActionOutcome _refused(String code, [String? context]) => ActionOutcome(
  status: ActionStatus.refused,
  refusal: ActionRefusal(code, context),
  combinedDescriptionNeeded: false,
  allowBackwardsNeeded: false,
);

/// Every verb Rust answers for a change at `-o` / `-A` / `-B`, in Rust's order, all [outcome].
DropActions _changeRows(ActionOutcome outcome, {Map<(DropVerb, int), ActionOutcome> except = const {}}) {
  ActionOutcome of(DropVerb verb, int location) => except[(verb, location)] ?? outcome;
  return DropActions(
    actions: <DropAction>[
      for (final DropVerb verb in <DropVerb>[
        DropVerb.rebaseSource,
        DropVerb.rebaseRevisions,
        DropVerb.squash,
        DropVerb.newMerge,
        DropVerb.duplicate,
        DropVerb.rebaseBranch,
        DropVerb.revert,
        DropVerb.restore,
        DropVerb.absorb,
        DropVerb.interdiff,
      ])
        DropAction(verb: verb, location: 0, outcome: of(verb, 0)),
      for (final int location in <int>[1, 2]) ...<DropAction>[
        DropAction(verb: DropVerb.rebaseRevisions, location: location, outcome: of(DropVerb.rebaseRevisions, location)),
        DropAction(verb: DropVerb.revert, location: location, outcome: of(DropVerb.revert, location)),
      ],
    ],
  );
}

DropActions _bookmarkRows(ActionOutcome outcome) => DropActions(
  actions: <DropAction>[DropAction(verb: DropVerb.bookmarkMove, location: 0, outcome: outcome)],
);

const _source = GraphChangeDrag(key: 'kmnvxoqpzz', changeId: 'kmnvxoqpzz', prefix: 2, short: 'kmnvxoqp');

/// A drop port whose answers a test scripts; each call waits on its own completer while [hold] is set.
class _Drops implements GraphDrops {
  final calls = <(DropSource, List<DropLocation>)>[];
  var hold = false;
  final held = <Completer<DropActions>>[];
  DropActions Function(DropSource source, String target) answer = (_, _) => _changeRows(_available);

  @override
  Future<DropActions> dropActions(DropSource source, List<DropLocation> locations) {
    calls.add((source, locations));
    if (hold) {
      final completer = Completer<DropActions>();
      held.add(completer);
      return completer.future;
    }
    return Future<DropActions>.value(answer(source, locations.first.onto.single));
  }
}

class _Ran {
  final ran = <(GraphAction, GraphDropOrigin?)>[];
  Completer<GraphActionResult>? gate;

  Future<GraphActionResult> call(GraphAction action, GraphDropOrigin? origin) {
    ran.add((action, origin));
    return gate?.future ?? Future<GraphActionResult>.value(const GraphActionDisabled(GraphDisabledReason.busy));
  }
}

void main() {
  group('graphDropRows', () {
    test('only the eight rows, only Available, in the fixed order; commands with short ids, actions with keys', () {
      final GraphDropPreview p = graphDropRows(
        _source,
        targetKey: 'vruxwmqvzz',
        targetShort: 'vruxwmqv',
        actions: _changeRows(_available),
      );
      expect(p.rows.map((r) => r.kind), GraphDropKind.values.where((k) => k != GraphDropKind.bookmark));
      expect(p.rows.map((r) => r.group).toSet(), <GraphDropGroup>{
        GraphDropGroup.move,
        GraphDropGroup.place,
        GraphDropGroup.combine,
        GraphDropGroup.copy,
      });
      expect(p.rows.first.command, 'jj rebase -s kmnvxoqp -o vruxwmqv');
      final first = p.rows.first.action as GraphRebase;
      expect(first.source, <String>['kmnvxoqpzz']);
      expect(first.onto, <String>['vruxwmqvzz']);
      expect((p.rows[5].action as GraphNew).parents, <String>['vruxwmqvzz', 'kmnvxoqpzz']);
      expect(p.refusal, isNull);
    });

    test('NoOp and Refused rows drop out; with none Available the first refusal is the words', () {
      final GraphDropPreview some = graphDropRows(
        _source,
        targetKey: 't',
        targetShort: 't',
        actions: _changeRows(
          _noOp,
          except: <(DropVerb, int), ActionOutcome>{(DropVerb.duplicate, 0): _available},
        ),
      );
      expect(some.rows.map((r) => r.kind), <GraphDropKind>[GraphDropKind.duplicate]);
      final GraphDropPreview none = graphDropRows(
        _source,
        targetKey: 't',
        targetShort: 't',
        actions: _changeRows(
          _refused('jj.immutable', 'Commit abc is immutable'),
          except: <(DropVerb, int), ActionOutcome>{(DropVerb.rebaseSource, 0): _noOp},
        ),
      );
      expect(none.rows, isEmpty);
      expect(none.refusal, 'Commit abc is immutable');
      final GraphDropPreview coded = graphDropRows(
        _source,
        targetKey: 't',
        targetShort: 't',
        actions: _changeRows(_refused('jj.immutable')),
      );
      expect(coded.refusal, 'jj.immutable');
    });

    test('⌥ makes Move only this change the default when it is there', () {
      final List<GraphDropRow> rows = graphDropRows(
        _source,
        targetKey: 't',
        targetShort: 't',
        actions: _changeRows(_available),
      ).rows;
      expect(graphDropDefault(rows, alt: false), 0);
      expect(rows[graphDropDefault(rows, alt: true)].command, 'jj rebase -r kmnvxoqp -o t');
      final List<GraphDropRow> without = rows.where((r) => r.kind != GraphDropKind.moveOnly).toList();
      expect(graphDropDefault(without, alt: true), 0);
    });

    test('a backwards bookmark row carries --allow-backwards and its note; a glob name is exact:', () {
      final GraphDropRow back = graphDropRows(
        const GraphBookmarkDrag('b-mark'),
        targetKey: 'tt',
        targetShort: 't',
        actions: _bookmarkRows(_backwards),
      ).rows.single;
      expect(back.backwards, isTrue);
      expect(back.command, 'jj bookmark move b-mark --to t --allow-backwards');
      expect(back.label(_en), 'Move b-mark here');
      expect((back.action as GraphBookmarkMove).to, 'tt');
      final GraphDropRow glob = graphDropRows(
        const GraphBookmarkDrag('feat*'),
        targetKey: 't',
        targetShort: 't',
        actions: _bookmarkRows(_available),
      ).rows.single;
      expect(glob.command, '''jj bookmark move 'exact:"feat*"' --to t''');
    });

    test('test-fixtures/commands/drop-menu.txt holds every command the drop menu shows', () {
      const target = 'vruxwmqv';
      final List<GraphDropRow> change = graphDropRows(
        _source,
        targetKey: target,
        targetShort: target,
        actions: _changeRows(_available),
      ).rows;
      GraphDropRow bookmark(String name, String to, ActionOutcome outcome) => graphDropRows(
        GraphBookmarkDrag(name),
        targetKey: to,
        targetShort: to,
        actions: _bookmarkRows(outcome),
      ).rows.single;
      final commands = <String>[
        for (final GraphDropRow row in change) row.command,
        bookmark('b-mark', 'kmnvxoqp', _available).command,
        bookmark('b-mark', target, _backwards).command,
        bookmark('feat{x}', 'kmnvxoqp', _available).command,
      ];
      expect(commands, File('../test-fixtures/commands/drop-menu.txt').readAsLinesSync());
    });

    test('bookmarks with @ or a remote never drag', () {
      expect(graphBookmarkDraggable('main'), isTrue);
      expect(graphBookmarkDraggable('main', remote: 'origin'), isFalse);
      expect(graphBookmarkDraggable('a@b'), isFalse);
    });
  });

  group('the drop menu geometry', () {
    final List<GraphDropRow> rows = graphDropRows(
      _source,
      targetKey: 't',
      targetShort: 't',
      actions: _changeRows(_available),
    ).rows;

    test('below: the footer first, then top-down with hairlines between groups; above: bottom-up, the footer last', () {
      final ({Size size, List<Rect> rows, Rect footer}) below = graphDropMenuGeometry(rows, above: false);
      expect(below.rows[0].top, lessThan(below.rows[1].top));
      expect(below.rows[2].top - below.rows[1].bottom, greaterThan(below.rows[1].top - below.rows[0].bottom));
      expect(below.footer.bottom, lessThanOrEqualTo(below.rows.first.top), reason: 'the footer on the card side');
      final ({Size size, List<Rect> rows, Rect footer}) above = graphDropMenuGeometry(rows, above: true);
      expect(above.rows[0].top, greaterThan(above.rows[1].top), reason: 'the default row nearest the card below');
      expect(above.footer.top, greaterThanOrEqualTo(above.rows.first.bottom), reason: 'the footer on the card side');
      expect(above.size, below.size);
    });

    test('12 px above the card when it fits under the area top, else below; centred and clamped', () {
      const area = Rect.fromLTWH(0, 60, 800, 600);
      const size = Size(graphDropMenuWidth, 200);
      final ({Offset topLeft, bool above}) up = graphDropMenuPlacement(
        const Rect.fromLTWH(300, 400, 240, 62),
        size,
        area,
      );
      expect(up.above, isTrue);
      expect(up.topLeft.dy, 400 - graphDropMenuGap - 200);
      expect(up.topLeft.dx, 420 - graphDropMenuWidth / 2);
      final ({Offset topLeft, bool above}) down = graphDropMenuPlacement(
        const Rect.fromLTWH(0, 100, 240, 62),
        size,
        area,
      );
      expect(down.above, isFalse);
      expect(down.topLeft.dy, 162 + graphDropMenuGap);
      expect(down.topLeft.dx, 0, reason: 'clamped into the area');
      // A tall menu below a card near the bottom stays inside the area, never above its top.
      final ({Offset topLeft, bool above}) low = graphDropMenuPlacement(
        const Rect.fromLTWH(0, 100, 240, 62),
        const Size(graphDropMenuWidth, 560),
        area,
      );
      expect(low.above, isFalse);
      expect(low.topLeft.dy, area.bottom - 560);
      final ({Offset topLeft, bool above}) huge = graphDropMenuPlacement(
        const Rect.fromLTWH(0, 100, 240, 62),
        const Size(graphDropMenuWidth, 700),
        area,
      );
      expect(huge.topLeft.dy, area.top);
    });
  });

  test('auto-scroll: ceil((56 − d) / 4) px per frame inside the zone, up to 24 px outside, else 0', () {
    expect(graphAutoScrollStep(0, 1000, 500), 0);
    expect(graphAutoScrollStep(0, 1000, 0), -14);
    expect(graphAutoScrollStep(0, 1000, 50), -2);
    expect(graphAutoScrollStep(0, 1000, -24), -20);
    expect(graphAutoScrollStep(0, 1000, -25), 0);
    expect(graphAutoScrollStep(0, 1000, 990), 12);
  });

  group('GraphDrag', () {
    setUpIconRegistry();
    late _Drops drops;
    late _Ran ran;
    late GraphDrag drag;
    var op = 'op1';

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      drops = _Drops();
      ran = _Ran();
      op = 'op1';
      drag = GraphDrag()
        ..drops = drops
        ..operationId = (() => op)
        ..run = ran.call;
    });
    tearDown(() => drag.dispose());

    test('debounced 60 ms after the target changes, one query in flight, cached per target and operation', () {
      fakeAsync((async) {
        drops.hold = true;
        drag
          ..start(_source, Offset.zero)
          ..hover('t1');
        async.elapse(const Duration(milliseconds: 59));
        expect(drops.calls, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(drops.calls, hasLength(1));
        expect(drops.calls.single.$2.map((l) => '${l.onto} ${l.insertAfter} ${l.insertBefore}'), <String>[
          '[t1] [] []',
          '[] [t1] []',
          '[] [] [t1]',
        ]);
        drag.hover('t2');
        async.elapse(const Duration(milliseconds: 100));
        expect(drops.calls, hasLength(1), reason: 'one in flight');
        drops.held.single.complete(_changeRows(_available));
        async.flushMicrotasks();
        expect(drops.calls, hasLength(2), reason: 't2 goes next');
        drops.held.last.complete(_changeRows(_available));
        async.flushMicrotasks();
        expect(drag.highlightedTarget, 't2');
        drag.hover('t1');
        expect(drag.highlightedTarget, 't1', reason: 'cached');
        async.elapse(const Duration(seconds: 1));
        expect(drops.calls, hasLength(2));
        op = 'op2';
        drag.hover('t2');
        expect(drag.rows, isNull, reason: 'a new operation clears the cache');
      });
    });

    test('a change released before the menu opens runs nothing; with the menu open the default row runs', () {
      fakeAsync((async) {
        drag
          ..start(_source, Offset.zero)
          ..hover('t');
        async.elapse(graphDropDebounce);
        expect(drag.highlightedTarget, 't');
        unawaited(drag.drop());
        async.flushMicrotasks();
        expect(ran.ran, isEmpty, reason: 'before the menu: cancelled');
        expect(drag.payload, isNull);
        drag
          ..start(_source, Offset.zero)
          ..hover('t');
        async.elapse(graphDropMenuDelay);
        expect(drag.menuOpen, isTrue);
        unawaited(drag.drop());
        async.flushMicrotasks();
        expect(ran.ran.single.$1.command, 'jj rebase -s kmnvxoqpzz -o t', reason: 'released on the card');
      });
    });

    test('the menu opens after 260 ms on a target with rows; a release on a row runs that row', () {
      fakeAsync((async) {
        drag
          ..start(_source, Offset.zero)
          ..hover('t');
        async.elapse(graphDropDebounce);
        expect(drag.highlightedRow?.kind, GraphDropKind.moveHere);
        async.elapse(const Duration(milliseconds: 259));
        expect(drag.menuOpen, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(drag.menuOpen, isTrue);
        drag.hover('t', menuRow: 3);
        expect(drag.highlight, 3);
        expect(drag.target, 't', reason: 'the pointer over the menu keeps the target');
        unawaited(drag.drop());
        async.flushMicrotasks();
        expect(ran.ran.single.$1.command, 'jj rebase -r kmnvxoqpzz -B t', reason: 'the action runs on the keys');
        expect(drag.holding, isFalse);
      });
    });

    test('a release without rows, on nothing or before they arrived cancels; nothing runs', () {
      fakeAsync((async) {
        drops.answer = (_, _) => _changeRows(_noOp);
        drag
          ..start(_source, Offset.zero)
          ..hover('t');
        async.elapse(graphDropDebounce);
        expect(drag.highlightedTarget, isNull);
        unawaited(drag.drop());
        async.flushMicrotasks();
        drag
          ..start(_source, Offset.zero)
          ..hover('t2');
        unawaited(drag.drop());
        async.flushMicrotasks();
        expect(ran.ran, isEmpty);
        expect(drag.payload, isNull);
      });
    });

    for (final (String name, ActionOutcome outcome, String command) in <(String, ActionOutcome, String)>[
      ('forward', _available, 'jj bookmark move b-mark --to t'),
      ('backwards', _backwards, 'jj bookmark move b-mark --to t --allow-backwards'),
    ]) {
      test('a bookmark drag never opens the menu; a $name release runs its row', () {
        fakeAsync((async) {
          drops.answer = (_, _) => _bookmarkRows(outcome);
          drag
            ..start(const GraphBookmarkDrag('b-mark'), Offset.zero)
            ..hover('t');
          async.elapse(graphDropDebounce + const Duration(seconds: 1));
          expect(drag.highlightedTarget, 't');
          expect(drag.menuOpen, isFalse);
          unawaited(drag.drop());
          async.flushMicrotasks();
          expect(ran.ran.single.$1.command, command);
          expect(drag.menuOpen, isFalse);
        });
      });
    }

    test('holding lasts until the verb finished; the ghost stays at the drop point meanwhile', () {
      fakeAsync((async) {
        ran.gate = Completer<GraphActionResult>();
        drag
          ..start(_source, const Offset(10, 10))
          ..hover('t');
        async.elapse(graphDropDebounce + graphDropMenuDelay);
        unawaited(drag.drop());
        async.flushMicrotasks();
        expect(drag.holding && drag.running, isTrue);
        expect(drag.ghost, _source);
        expect(drag.dropPoint, const Offset(10, 10));
        ran.gate!.complete(const GraphActionDisabled(GraphDisabledReason.busy));
        async.flushMicrotasks();
        expect(drag.holding, isFalse);
        expect(drag.ghost, isNull);
      });
    });

    test('a new drag whose first query found the old drag\'s in flight is queried when that one returns', () {
      fakeAsync((async) {
        drops.hold = true;
        drag
          ..start(_source, Offset.zero)
          ..hover('t1');
        async.elapse(graphDropDebounce);
        drag
          ..cancel()
          ..start(const GraphBookmarkDrag('b-mark'), Offset.zero)
          ..hover('t2');
        async.elapse(graphDropDebounce);
        expect(drops.calls, hasLength(1));
        drops.held.single.complete(_changeRows(_available));
        async.flushMicrotasks();
        expect(drops.calls, hasLength(2));
        expect(drops.calls.last.$1, isA<BookmarkDropSource>());
        drops.held.last.complete(_bookmarkRows(_available));
        async.flushMicrotasks();
        expect(drag.highlightedTarget, 't2');
      });
    });

    test('a preview answered for an older operation is not shown; the target is queried again', () {
      fakeAsync((async) {
        drops.hold = true;
        drag
          ..start(_source, Offset.zero)
          ..hover('t');
        async.elapse(graphDropDebounce);
        op = 'op2';
        drops.held.single.complete(_changeRows(_available));
        async.flushMicrotasks();
        expect(drag.rows, isNull);
        expect(drag.highlightedTarget, isNull);
        async.elapse(graphDropDebounce);
        expect(drops.calls, hasLength(2));
        drops.held.last.complete(_changeRows(_available));
        async.flushMicrotasks();
        expect(drag.highlightedTarget, 't');
      });
    });

    test('any error of the preview is a failed preview', () {
      fakeAsync((async) {
        drops.answer = (_, _) => throw StateError('boom');
        drag
          ..start(_source, Offset.zero)
          ..hover('t');
        async.elapse(graphDropDebounce);
        expect(drag.rows, isEmpty);
        expect(drag.highlightedTarget, isNull);
      });
    });

    test('a failed preview leaves the target un-highlighted', () {
      fakeAsync((async) {
        drops.answer = (_, _) => throw const ZanshinFfiException('jj.io_error');
        drag
          ..start(_source, Offset.zero)
          ..hover('t');
        async.elapse(graphDropDebounce);
        expect(drag.highlightedTarget, isNull);
        expect(drag.refusal, isNull);
      });
    });

    testWidgets('⌥ switches the default live; ↑/↓ move the highlight; Esc cancels', (tester) async {
      drag
        ..start(_source, Offset.zero)
        ..hover('t');
      await tester.pump(graphDropDebounce);
      await tester.pump();
      expect(drag.highlightedRow?.kind, GraphDropKind.moveHere);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      expect(drag.highlightedRow?.kind, GraphDropKind.moveOnly);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(drag.highlightedRow?.kind, GraphDropKind.moveHere);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(drag.highlightedRow?.kind, GraphDropKind.insertAfter);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(drag.payload, isNull);
      expect(ran.ran, isEmpty);
    });

    for (final altAtOpen in <bool>[false, true]) {
      testWidgets('the menu opened ${altAtOpen ? 'with' : 'without'} ⌥ keeps its row when ⌥ changes', (tester) async {
        if (altAtOpen) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        }
        drag
          ..start(_source, Offset.zero)
          ..hover('t');
        await tester.pump(graphDropDebounce);
        await tester.pump(graphDropMenuDelay);
        expect(drag.menuOpen, isTrue);
        final GraphDropKind opened = altAtOpen ? GraphDropKind.moveOnly : GraphDropKind.moveHere;
        expect(drag.highlightedRow?.kind, opened);
        if (altAtOpen) {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        } else {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        }
        expect(drag.alt, !altAtOpen);
        expect(drag.highlightedRow?.kind, opened);
        if (!altAtOpen) {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        }
        drag.cancel();
      });
    }

    testWidgets('the drop menu enters like the command menus: --dur-menu, glide, from scale .97', (tester) async {
      final List<GraphDropRow> rows = graphDropRows(
        _source,
        targetKey: 't',
        targetShort: 't',
        actions: _changeRows(_available),
      ).rows;
      await tester.pumpWidget(shellHost(Center(child: GraphDropMenu(rows: rows, highlight: 0, above: false))));
      double scale() => tester
          .widget<Transform>(find.descendant(of: find.byType(GraphDropMenu), matching: find.byType(Transform)).first)
          .transform
          .entry(0, 0);
      const ZsMotion motion = ZsMotion.full;
      final Duration half = motion.durMenu ~/ 2;
      await tester.pump(half);
      final double t = half.inMicroseconds / motion.durMenu.inMicroseconds;
      expect(scale(), closeTo(1 - .03 * (1 - motion.easeGlide.transform(t)), 1e-6));
      await tester.pump(motion.durMenu);
      expect(scale(), 1);
    });
  });

  test('the view model holds reloads while a drag runs and applies one after it', () {
    fakeAsync((async) {
      final source = ScriptedGraphSource();
      final model = GraphViewModel()..init(source, drops: _Drops());
      async.flushMicrotasks();
      expect(source.requests, hasLength(1));
      model.drag.start(_source, Offset.zero);
      for (var i = 0; i < 3; i++) {
        source.emit(const OpHeadsChangedEvent(0, <String>[]));
        async.flushMicrotasks();
      }
      expect(source.requests, hasLength(1));
      model.drag.cancel();
      async.flushMicrotasks();
      expect(source.requests, hasLength(2), reason: 'one held reload');
      model.dispose();
    });
  });

  test('an op-heads event during a drag makes the next hover query again, though the reload is held', () {
    fakeAsync((async) {
      final source = ScriptedGraphSource();
      final drops = _Drops();
      final model = GraphViewModel()..init(source, drops: drops);
      async.flushMicrotasks();
      model.drag
        ..start(_source, Offset.zero)
        ..hover('b');
      async.elapse(graphDropDebounce);
      model.drag.hover('c');
      async.elapse(graphDropDebounce);
      model.drag.hover('b');
      async.elapse(graphDropDebounce);
      expect(drops.calls, hasLength(2), reason: 'b came from the cache');
      source.emit(const OpHeadsChangedEvent(0, <String>[]));
      async.flushMicrotasks();
      model.drag.hover('c');
      async.elapse(graphDropDebounce);
      expect(drops.calls, hasLength(3), reason: 'a new operation: c is queried again');
      expect(source.requests, hasLength(1), reason: 'the reload is held');
      model.dispose();
    });
  });

  test('after a drop the held reload runs once, when the verb finished', () {
    fakeAsync((async) {
      final source = ScriptedGraphSource();
      final model = GraphViewModel()..init(source, actions: _Actions(), drops: _Drops());
      async.flushMicrotasks();
      model.drag
        ..start(_source, Offset.zero)
        ..hover('c');
      async.elapse(graphDropDebounce);
      source.emit(const OpHeadsChangedEvent(0, <String>[]));
      async.flushMicrotasks();
      unawaited(model.drag.drop());
      async
        ..flushMicrotasks()
        ..elapse(const Duration(seconds: 1));
      expect(source.requests, hasLength(2), reason: 'exactly one reload after the verb');
      model.dispose();
    });
  });

  test('a rebase anchors on T and flashes S, a duplicate reveals its born change; the selection stays', () {
    fakeAsync((async) {
      final source = ScriptedGraphSource();
      final actions = _Actions();
      final model = GraphViewModel()..init(source, actions: actions, drops: _Drops());
      async.flushMicrotasks();
      model.select('b');
      unawaited(model.run(const GraphRebase(source: <String>['a'], onto: <String>['c'])));
      async.flushMicrotasks();
      expect(model.outcome.value?.anchor, 'c');
      expect(model.outcome.value?.flash, <String>['a']);
      expect(model.selected, 'b');
      actions.born = const <String>['d'];
      source.respond = (_) => keysLayout(<String>['d', 'a', 'b', 'c'], at: 'a');
      unawaited(model.run(const GraphDuplicate(revisions: <String>['a'], onto: <String>['c'])));
      async.flushMicrotasks();
      expect(model.outcome.value?.anchor, 'c');
      expect(model.selected, 'b');
      expect(model.reveal?.key, 'd');
      model.dispose();
    });
  });

  group('in the graph', () {
    setUpIconRegistry();

    testWidgets('a card released on another with the menu open runs the default row; no command before it; no click', (
      tester,
    ) async {
      useShellWindow(tester);
      final source = ScriptedGraphSource(respond: (_) => _opLayout(<String>['a', 'b', 'c'], 'op1'));
      final drops = _Drops();
      final actions = _Actions();
      final model = GraphViewModel()..init(source, actions: actions, drops: drops);
      await tester.pumpWidget(shellHost(GraphView(model: model)));
      await tester.pumpAndSettle();
      // The verb's operation moves a below c.
      source.respond = (_) => _opLayout(<String>['b', 'c', 'a'], 'op2');

      Offset centre(String key) => _centre(tester, key);

      final Offset from = centre('a');
      final Offset to = centre('c');
      final TestGesture mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await mouse.moveBy(const Offset(3, 3));
      await tester.pump();
      expect(model.drag.active, isFalse, reason: 'within the 5 px threshold');
      await mouse.moveTo(Offset.lerp(from, to, .5)!);
      await tester.pump();
      expect(model.drag.active, isTrue);
      expect(find.text(_en.dragHintChange), findsOneWidget);
      await mouse.moveTo(to);
      await tester.pump(graphDropDebounce);
      await tester.pump();
      expect(_dropTarget(tester), 'c', reason: 'the target shows its drop look');
      expect(find.text('jj rebase -s a -o c'), findsNothing, reason: 'no command before the menu');
      expect(find.text(_en.dragHintChange), findsOneWidget);
      await tester.pump(graphDropMenuDelay);
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.drag.menuOpen, isTrue);
      final RenderGraphViewport viewport = tester.allRenderObjects.whereType<RenderGraphViewport>().single;
      final GraphLayout dragged = model.layout!;
      expect(viewport.opacityOf!(dragged.indexOfKey('a')!), graphDragSourceOpacity, reason: 'the source dims');
      expect(viewport.opacityOf!(dragged.indexOfKey('c')!), 1);
      expect(_cards(tester).hoverEnabled, isFalse, reason: 'no hover under a drag');
      await mouse.up();
      await tester.pumpAndSettle();
      expect(_dropTarget(tester), isNull);
      expect(
        viewport.opacityOf?.call(model.layout!.indexOfKey('a')!) ?? 1,
        1,
        reason: 'the source no longer dims after the drop',
      );
      expect(_cards(tester).hoverEnabled, isTrue);
      expect(actions.ran.single.command, 'jj rebase -s a -o c');
      expect(model.selected, isNull, reason: 'the drag swallowed the click');
      expect(find.byType(ZsDragGhost), findsNothing);
      expect(model.transition?.dropped?.key, 'a', reason: 'the landing glides a from the ghost');
      expect(model.transition?.dropped?.rect.isEmpty, isFalse);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });

    testWidgets('a rest opens the menu above a low card; a release on a row runs that row', (tester) async {
      useShellWindow(tester);
      final keys = <String>['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
      final source = ScriptedGraphSource(respond: (_) => keysLayout(keys, at: 'a'));
      final actions = _Actions();
      final model = GraphViewModel()..init(source, actions: actions, drops: _Drops());
      await tester.pumpWidget(shellHost(GraphView(model: model)));
      await tester.pumpAndSettle();
      final Offset from = _centre(tester, 'a');
      final Offset to = _centre(tester, 'h');
      final TestGesture mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await mouse.moveTo(Offset.lerp(from, to, .5)!);
      await tester.pump();
      await mouse.moveTo(to);
      await tester.pump(graphDropDebounce);
      await tester.pump(graphDropMenuDelay);
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.drag.menuOpen, isTrue);
      expect(
        find.descendant(of: find.byType(ZsDragGhost), matching: find.text('jj rebase -s a -o h')),
        findsNothing,
        reason: 'the ghost hides its words while the menu is open',
      );
      final Finder row = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.identifier == 'graph-drop-insertBefore',
      );
      expect(tester.getCenter(row).dy, lessThan(to.dy), reason: 'above the card');
      final RenderGraphCard h = _card(tester, 'h');
      await mouse.moveTo(h.localToGlobal(h.cardRect.topCenter) - const Offset(0, graphDropMenuGap / 2));
      await tester.pump();
      expect(model.drag.menuOpen, isTrue, reason: 'the gap between card and menu keeps the target');
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      expect(model.drag.highlightedRow?.kind, GraphDropKind.insertBefore);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(actions.ran.single.command, 'jj rebase -r a -B h');
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });

    testWidgets('the pill drags its local bookmark; a remote ref and the root do not drag', (tester) async {
      useShellWindow(tester);
      final RecordedGraphLayout layout = handLayout(
        <(String, int, int)>[('a', 3, 0), ('b', 2, 0), ('c', 1, 0), ('r', 0, 0)],
        edges: <(int, int)>[(0, 1), (1, 2), (2, 3)],
        workingCopy: 0,
        root: 3,
        refs: <List<GraphRef>>[
          <GraphRef>[const GraphRef('main')],
          <GraphRef>[const GraphRef('feat', remote: 'origin')],
          const <GraphRef>[],
          const <GraphRef>[],
        ],
      );
      final drops = _Drops()..answer = (_, _) => _bookmarkRows(_available);
      final source = ScriptedGraphSource(respond: (_) => layout);
      final actions = _Actions();
      final model = GraphViewModel()..init(source, actions: actions, drops: drops);
      await tester.pumpWidget(shellHost(GraphView(model: model)));
      await tester.pumpAndSettle();
      Offset pill(String key) {
        final RenderGraphCard card = _card(tester, key);
        final Rect legend = card.debugSlots.firstWhere((s) => s.kind == GraphCardSlot.legend).rect;
        return card.localToGlobal(legend.center);
      }

      Future<void> dragFrom(Offset from, Offset to) async {
        final TestGesture mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
        await mouse.moveTo(Offset.lerp(from, to, .5)!);
        await tester.pump();
        await mouse.moveTo(to);
        await tester.pump(graphDropDebounce);
        await tester.pump();
        await mouse.up();
        await tester.pumpAndSettle();
      }

      await dragFrom(pill('b'), _centre(tester, 'c'));
      expect(drops.calls, isEmpty, reason: 'a remote ref does not drag');
      await dragFrom(_centre(tester, 'r'), _centre(tester, 'c'));
      expect(drops.calls, isEmpty, reason: 'the root does not drag');
      await dragFrom(pill('a'), _centre(tester, 'c'));
      expect(drops.calls.single.$1, isA<BookmarkDropSource>());
      expect(actions.ran.single.command, 'jj bookmark move main --to c');
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });

    testWidgets('a stack card neither drags nor becomes a target (no preview query)', (tester) async {
      useShellWindow(tester);
      final RecordedGraphLayout layout = hugeStackLayout(3);
      final drops = _Drops();
      final source = ScriptedGraphSource(respond: (_) => layout);
      final model = GraphViewModel()..init(source, actions: _Actions(), drops: drops);
      await tester.pumpWidget(shellHost(GraphView(model: model)));
      await tester.pumpAndSettle();
      final Offset stack = tester.getCenter(find.byType(GraphStackCard));
      final TestGesture fromStack = await tester.startGesture(stack, kind: PointerDeviceKind.mouse);
      await fromStack.moveBy(const Offset(40, 40));
      await tester.pump();
      expect(model.drag.active, isFalse, reason: 'a stack does not drag');
      await fromStack.up();
      await tester.pumpAndSettle();
      final Offset head = _centre(tester, 'head');
      final TestGesture mouse = await tester.startGesture(head, kind: PointerDeviceKind.mouse);
      await mouse.moveTo(Offset.lerp(head, stack, .5)!);
      await tester.pump();
      await mouse.moveTo(stack);
      await tester.pump(graphDropDebounce);
      await tester.pump();
      expect(model.drag.target, isNull);
      expect(_dropTarget(tester), isNull);
      expect(drops.calls, isEmpty);
      await mouse.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });

    testWidgets('Esc cancels a card drag and nothing runs', (tester) async {
      useShellWindow(tester);
      final source = ScriptedGraphSource(respond: (_) => keysLayout(<String>['a', 'b'], at: 'a'));
      final actions = _Actions();
      final model = GraphViewModel()..init(source, actions: actions, drops: _Drops());
      await tester.pumpWidget(shellHost(GraphView(model: model)));
      await tester.pumpAndSettle();
      final RenderGraphCard a = tester.allRenderObjects.whereType<RenderGraphCard>().firstWhere(
        (c) => c.data.key == 'a',
      );
      final TestGesture mouse = await tester.startGesture(
        a.localToGlobal(a.cardRect.center),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(40, 40));
      await tester.pump();
      expect(model.drag.active, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(model.drag.payload, isNull);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(actions.ran, isEmpty);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });

    testWidgets('a target whose rows are all refused is not highlighted; the ghost says why', (tester) async {
      useShellWindow(tester);
      final source = ScriptedGraphSource(respond: (_) => keysLayout(<String>['a', 'b', 'c'], at: 'a'));
      final drops = _Drops()..answer = (_, _) => _changeRows(_refused('jj.immutable', 'c is immutable'));
      final actions = _Actions();
      final model = GraphViewModel()..init(source, actions: actions, drops: drops);
      await tester.pumpWidget(shellHost(GraphView(model: model)));
      await tester.pumpAndSettle();
      final Offset from = _centre(tester, 'a');
      final Offset to = _centre(tester, 'c');
      final TestGesture mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await mouse.moveTo(Offset.lerp(from, to, .5)!);
      await tester.pump();
      await mouse.moveTo(to);
      await tester.pump(graphDropDebounce);
      await tester.pump();
      expect(find.descendant(of: find.byType(ZsDragGhost), matching: find.text('c is immutable')), findsOneWidget);
      expect(_dropTarget(tester), isNull);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(actions.ran, isEmpty);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });

    testWidgets('a pointer resting on the open menu inside the auto-scroll zone does not scroll', (tester) async {
      useShellWindow(tester);
      final keys = <String>[for (var i = 0; i < 80; i++) 'k$i'];
      final source = ScriptedGraphSource(respond: (_) => keysLayout(keys, at: 'k0'));
      final model = GraphViewModel()..init(source, actions: _Actions(), drops: _Drops());
      await tester.pumpWidget(shellHost(GraphView(model: model)));
      await tester.pumpAndSettle();
      final RenderGraphViewport render = tester.allRenderObjects.whereType<RenderGraphViewport>().single;
      final Rect area = render.insets.deflateRect(Offset.zero & render.size);
      final Offset middle = render.localToGlobal(area.center);
      final String target = keys.firstWhere((k) => k != 'k0' && _centre(tester, k).dy > middle.dy);
      final Offset from = _centre(tester, 'k0');
      final TestGesture mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await mouse.moveTo(middle);
      await tester.pump(const Duration(milliseconds: 16));
      await mouse.moveTo(_centre(tester, target));
      await tester.pump(graphDropDebounce);
      await tester.pump(graphDropMenuDelay);
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.drag.menuOpen, isTrue);
      final Finder rows = find.byWidgetPredicate(
        (w) => w is Semantics && (w.properties.identifier?.startsWith('graph-drop-') ?? false),
      );
      Offset topRow() => rows
          .evaluate()
          .map((e) => tester.getCenter(find.byWidget(e.widget)))
          .reduce(
            (a, b) => a.dy < b.dy ? a : b,
          );
      // Scroll until the menu (still above its card) touches the top: its top row is then in the top zone.
      final double top = render.localToGlobal(area.topLeft).dy;
      final double menuTop = tester.getRect(find.byType(GraphDropMenu)).top;
      render.verticalOffset.jumpTo(render.verticalOffset.pixels + menuTop - (top + 1));
      await tester.pump();
      expect(topRow().dy - top, lessThan(graphAutoScrollZone));
      await mouse.moveTo(topRow());
      await tester.pump();
      expect(model.drag.overMenu, isTrue);
      final double y = render.verticalOffset.pixels;
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(render.verticalOffset.pixels, y, reason: 'the menu does not slide away under the pointer');
      expect(model.drag.menuOpen, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await mouse.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });

    testWidgets('no drag starts while the actions are disabled (a verb runs)', (tester) async {
      useShellWindow(tester);
      final source = ScriptedGraphSource(respond: (_) => keysLayout(<String>['a', 'b', 'c'], at: 'a'));
      final drops = _Drops();
      final actions = _Actions()..gate = Completer<void>();
      final model = GraphViewModel()..init(source, actions: actions, drops: drops);
      await tester.pumpWidget(shellHost(GraphView(model: model)));
      await tester.pumpAndSettle();
      unawaited(model.run(const GraphRebase(source: <String>['b'], onto: <String>['c'])));
      await tester.pump();
      expect(model.actionsEnabled, isFalse);
      final Offset from = _centre(tester, 'a');
      final Offset to = _centre(tester, 'c');
      final TestGesture mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await mouse.moveTo(Offset.lerp(from, to, .5)!);
      await tester.pump();
      await mouse.moveTo(to);
      await tester.pump(graphDropDebounce);
      expect(model.drag.payload, isNull);
      expect(drops.calls, isEmpty);
      await mouse.up();
      actions.gate!.complete();
      await tester.pumpAndSettle();
      expect(actions.ran, hasLength(1), reason: 'only the gated verb ran');
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });

    testWidgets('auto-scroll arms once well inside, then scrolls the vertical axis in the bottom zone', (tester) async {
      useShellWindow(tester);
      final keys = <String>[for (var i = 0; i < 60; i++) 'k$i'];
      final source = ScriptedGraphSource(respond: (_) => keysLayout(keys, at: 'k0'));
      final model = GraphViewModel()..init(source, actions: _Actions(), drops: _Drops());
      await tester.pumpWidget(shellHost(GraphView(model: model)));
      await tester.pumpAndSettle();
      final RenderGraphViewport render = tester.allRenderObjects.whereType<RenderGraphViewport>().single;
      final Rect area = render.insets.deflateRect(Offset.zero & render.size);
      final Offset bottom = render.localToGlobal(area.bottomCenter - const Offset(0, 8));
      final Offset middle = render.localToGlobal(area.center);
      final double x = render.horizontalOffset.pixels;
      final double y = render.verticalOffset.pixels;
      final Offset from = _centre(tester, 'k0');
      final TestGesture mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await mouse.moveBy(const Offset(0, 10));
      expect(model.drag.active, isTrue);
      await mouse.moveTo(bottom);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(render.verticalOffset.pixels, y, reason: 'not armed: the pointer was never well inside');
      await mouse.moveTo(middle);
      await tester.pump(const Duration(milliseconds: 16));
      await mouse.moveTo(bottom);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(render.verticalOffset.pixels, greaterThan(y));
      expect(render.horizontalOffset.pixels, x);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await mouse.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });

    for (final backwards in <bool>[true, false]) {
      testWidgets('a ${backwards ? 'backwards' : 'forward'} bookmark drag ${backwards ? 'warns' : 'does not warn'} in '
          'the ghost (announced once per target), never opens the menu and runs on release', (
        tester,
      ) async {
        useShellWindow(tester);
        final announced = <String>[];
        tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (
          message,
        ) async {
          final event = message! as Map<Object?, Object?>;
          if (event['type'] == 'announce') {
            announced.add((event['data']! as Map<Object?, Object?>)['message']! as String);
          }
          return null;
        });
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
            SystemChannels.accessibility,
            null,
          ),
        );
        final RecordedGraphLayout layout = handLayout(
          <(String, int, int)>[('a', 2, 0), ('b', 1, 0), ('c', 0, 0)],
          edges: <(int, int)>[(0, 1), (1, 2)],
          workingCopy: 0,
          refs: <List<GraphRef>>[
            <GraphRef>[const GraphRef('main')],
            const <GraphRef>[],
            const <GraphRef>[],
          ],
        );
        final drops = _Drops()..answer = (_, _) => _bookmarkRows(backwards ? _backwards : _available);
        final source = ScriptedGraphSource(respond: (_) => layout);
        final actions = _Actions();
        final model = GraphViewModel()..init(source, actions: actions, drops: drops);
        await tester.pumpWidget(shellHost(GraphView(model: model)));
        await tester.pumpAndSettle();
        final command = 'jj bookmark move main --to c${backwards ? ' --allow-backwards' : ''}';
        final RenderGraphCard a = _card(tester, 'a');
        final Rect legend = a.debugSlots.firstWhere((s) => s.kind == GraphCardSlot.legend).rect;
        final Offset from = a.localToGlobal(legend.center);
        final Offset to = _centre(tester, 'c');
        final TestGesture mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
        await mouse.moveTo(Offset.lerp(from, to, .5)!);
        await tester.pump();
        await mouse.moveTo(to);
        await tester.pump(graphDropDebounce);
        await tester.pump(graphDropMenuDelay + const Duration(milliseconds: 100));
        expect(model.drag.menuOpen, isFalse, reason: 'a bookmark drag never opens the menu');
        expect(find.byType(GraphDropMenu), findsNothing);
        expect(find.text(command), findsOneWidget, reason: 'the ghost names the command');
        final Finder warning = find.text(_en.dragBackwardsWarning);
        if (backwards) {
          expect(warning, findsOneWidget);
          expect(tester.widget<Text>(warning).style?.color, ZsColors.of(tester.element(warning)).warn);
        } else {
          expect(warning, findsNothing, reason: 'a fast-forward needs no warning');
        }
        await tester.pump(const Duration(milliseconds: 500));
        expect(announced, <String>[if (backwards) _en.dragBackwardsWarning], reason: 'staying adds none');
        await mouse.moveTo(_centre(tester, 'b'));
        await tester.pump(graphDropDebounce);
        await tester.pump();
        expect(announced, <String>[
          if (backwards) ...<String>[_en.dragBackwardsWarning, _en.dragBackwardsWarning],
        ]);
        await mouse.moveTo(to);
        await tester.pump(graphDropDebounce);
        expect(announced, <String>[
          if (backwards) ...List<String>.filled(3, _en.dragBackwardsWarning),
        ], reason: 'cached');
        await mouse.up();
        await tester.pumpAndSettle();
        expect(actions.ran.map((a) => a.command), <String>[command], reason: 'the release runs the row');
        expect(model.drag.payload, isNull);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      });
    }
  });
}

String? _dropTarget(WidgetTester tester) => _cards(tester).dropTarget.value;

GraphCardController _cards(WidgetTester tester) => tester.widget<GraphCanvas>(find.byType(GraphCanvas)).cards;

/// [keys] one per row, newest first, at operation [op]; @ is `a`.
RecordedGraphLayout _opLayout(List<String> keys, String op) => handLayout(
  <(String, int, int)>[for (var i = 0; i < keys.length; i++) (keys[i], keys.length - 1 - i, 0)],
  edges: <(int, int)>[for (var i = 0; i + 1 < keys.length; i++) (i, i + 1)],
  workingCopy: keys.indexOf('a'),
  operationId: op,
);

RenderGraphCard _card(WidgetTester tester, String key) =>
    tester.allRenderObjects.whereType<RenderGraphCard>().firstWhere((c) => c.data.key == key);

Offset _centre(WidgetTester tester, String key) {
  final RenderGraphCard card = _card(tester, key);
  return card.localToGlobal(card.cardRect.center);
}

class _Actions implements GraphActions {
  final ran = <GraphAction>[];
  var born = const <String>[];
  Completer<void>? gate;

  @override
  Future<String> headOpId() async => 'op${ran.length}';

  @override
  Future<MutationResult> run(GraphAction action) async {
    ran.add(action);
    await gate?.future;
    return MutationResult(
      newOpId: 'op${ran.length}',
      newChangeIds: born,
      abandonedChangeIds: <String>[],
      workingCopyChangeId: null,
      finish: null,
    );
  }
}
