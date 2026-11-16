// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_card_menu.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_move_sheet.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_bookmark_list.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

// T (the target) → Y → Z; W beside T on Y's parent Z.
const _t = 'tttttttttttttttttttttttt';
const _y = 'yyyyyyyyyyyyyyyyyyyyyyyy';
const _z = 'zzzzzzzzzzzzzzzzzzzzzzzz';
const _w = 'wwwwwwwwwwwwwwwwwwwwwwww';

final GraphLayout _layout = handLayout(
  <(String, int, int)>[(_t, 3, 0), (_y, 2, 0), (_w, 2, 1), (_z, 1, 0)],
  edges: const <(int, int)>[(0, 1), (1, 3), (2, 3)],
  prefixLengths: const <int>[2, 2, 2, 2],
  contents: <GraphCommitContent?>[
    for (final String key in <String>[_t, _y, _w, _z]) GraphCommitContent(subject: 'about ${key[0]}'),
  ],
);

ActionOutcome _outcome({ActionStatus status = ActionStatus.available, bool backwards = false, ActionRefusal? r}) =>
    ActionOutcome(status: status, refusal: r, combinedDescriptionNeeded: false, allowBackwardsNeeded: backwards);

/// Answers every bookmark move by [answer] for its name; records each call.
class _Drops implements GraphDrops {
  _Drops(this.answer);

  ActionOutcome? Function(String name) answer;
  final calls = <(DropSource, List<DropLocation>)>[];
  Completer<void>? gate;

  @override
  Future<DropActions> dropActions(DropSource source, List<DropLocation> locations) async {
    calls.add((source, locations));
    await gate?.future;
    final ActionOutcome? outcome = answer((source as BookmarkDropSource).name);
    if (outcome == null) {
      throw const ZanshinFfiException('jj.io_error', 'disk');
    }
    return DropActions(
      actions: <DropAction>[DropAction(verb: DropVerb.bookmarkMove, location: 0, outcome: outcome)],
    );
  }
}

void main() {
  setUpIconRegistry();

  group('graphBookmarkMoveCheck', () {
    Future<GraphMoveCheck?> check(ActionOutcome? outcome, {required String from, String to = _z}) =>
        graphBookmarkMoveCheck(_Drops((_) => outcome), _layout, name: 'b', from: from, to: to);

    test('one preview of jj bookmark move b --to <to>', () async {
      final drops = _Drops((_) => _outcome());
      await graphBookmarkMoveCheck(drops, _layout, name: 'b', from: _t, to: _z);
      final (DropSource source, List<DropLocation> locations) = drops.calls.single;
      expect((source as BookmarkDropSource).name, 'b');
      expect(locations.single.onto, <String>[_z]);
    });

    test(
      'a fast-forward is forward; a move needing --allow-backwards is backwards or sideways by the layout',
      () async {
        expect(await check(_outcome(), from: _t), (direction: GraphMoveDirection.forward, refusal: null));
        expect(
          await check(_outcome(backwards: true), from: _t),
          (direction: GraphMoveDirection.backwards, refusal: null),
          reason: 'Z is an ancestor of T',
        );
        expect(
          await check(_outcome(backwards: true), from: _t, to: _w),
          (direction: GraphMoveDirection.sideways, refusal: null),
        );
        expect(
          await check(_outcome(backwards: true), from: 'not-in-the-layout'),
          (direction: GraphMoveDirection.backwards, refusal: null),
          reason: "the flag's own word",
        );
      },
    );

    test('a refusal carries context ?? code; a failed preview is unknown', () async {
      expect(
        await check(
          _outcome(status: ActionStatus.refused, r: const ActionRefusal('jj.immutable', 'Commit z is immutable')),
          from: _t,
        ),
        (direction: GraphMoveDirection.forward, refusal: 'Commit z is immutable'),
      );
      expect(
        await check(
          _outcome(status: ActionStatus.refused, r: const ActionRefusal('jj.immutable', null)),
          from: _t,
        ),
        (direction: GraphMoveDirection.forward, refusal: 'jj.immutable'),
      );
      expect(await check(null, from: _t), isNull);
    });
  });

  group('GraphMoveSheet', () {
    late List<GraphAction> confirmed;
    late int cancelled;

    Future<void> pump(
      WidgetTester tester, {
      bool tag = false,
      Future<List<Bookmark>> Function()? read,
      GraphDrops? drops,
      String target = _z,
    }) async {
      confirmed = <GraphAction>[];
      cancelled = 0;
      await tester.pumpWidget(
        shellHost(
          GraphMoveSheet(
            key: UniqueKey(),
            tag: tag,
            targetKey: target,
            short: target.substring(0, 8),
            layout: _layout,
            drops: drops,
            read: read,
            onConfirm: confirmed.add,
            onCancel: () => cancelled++,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(ZsMotion.full.durPop);
    }

    Finder row(String name) => find.bySemanticsIdentifier('move-sheet-row-$name');
    String? text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey<String>(key))).data;
    ZsButton move(WidgetTester tester) =>
        tester.widget<ZsButton>(find.byWidgetPredicate((w) => w is ZsButton && w.identifier == 'move-sheet-confirm'));

    final bookmarks = <Bookmark>[
      localRow('feature/auth-flow', _t),
      localRow('feature/onboarding/pager', _w),
      localRow('main', _y),
      localRow('here', _z),
      localRow('deleted', null),
      remoteRow('main', 'origin', _y),
    ];

    testWidgets('"feat" lists the matching bookmarks with the match marked and their change; own and absent left out', (
      tester,
    ) async {
      await pump(tester, read: () async => bookmarks);
      expect(row('feature/auth-flow'), findsOneWidget);
      expect(row('main'), findsOneWidget);
      expect(row('here'), findsNothing, reason: 'already on this change');
      expect(row('deleted'), findsNothing, reason: 'no target');
      await tester.enterText(find.byType(EditableText), 'feat');
      await tester.pump();
      expect(row('main'), findsNothing);
      expect(row('feature/auth-flow'), findsOneWidget);
      expect(row('feature/onboarding/pager'), findsOneWidget);
      final RichText name = tester.widget<RichText>(
        find.descendant(
          of: row('feature/auth-flow'),
          matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'feature/auth-flow'),
        ),
      );
      TextSpan? feat;
      name.text.visitChildren((span) {
        if (span is TextSpan && span.text == 'feat') {
          feat = span;
        }
        return feat == null;
      });
      expect(feat?.style?.decoration, TextDecoration.underline, reason: 'the match is marked');
      expect(find.text('now on tttttttt about t'), findsOneWidget);
      await tester.enterText(find.byType(EditableText), 'zzz');
      await tester.pump();
      expect(text(tester, 'move-sheet-empty'), 'No bookmark matches “zzz”.');
      expect(text(tester, 'move-sheet-command'), ' ');
      expect(move(tester).onPressed, isNull);
    });

    testWidgets('reading, failed and nothing to move', (tester) async {
      final read = Completer<List<Bookmark>>();
      await pump(tester, read: () => read.future);
      expect(text(tester, 'move-sheet-empty'), 'Reading bookmarks…');
      read.completeError(const ZanshinFfiException('jj.io_error', 'disk'));
      await tester.pump();
      expect(text(tester, 'move-sheet-empty'), "Couldn't read the bookmarks");
      await pump(tester, tag: true, read: () async => <Bookmark>[localRow('v1', _z)]);
      expect(text(tester, 'move-sheet-empty'), 'No tag to move');
    });

    testWidgets('a backwards row blocks Move until the switch; then ↩ runs --allow-backwards on the key', (
      tester,
    ) async {
      final drops = _Drops((name) => _outcome(backwards: name == 'feature/auth-flow'));
      await pump(tester, read: () async => bookmarks, drops: drops);
      await tester.pump();
      expect(find.text('backwards'), findsOneWidget, reason: 'T is above Z');
      expect(move(tester).onPressed, isNull);
      expect(text(tester, 'move-sheet-reason'), 'This move goes backwards: turn on the switch to allow it.');
      expect(text(tester, 'move-sheet-command'), 'jj bookmark move feature/auth-flow --to zzzzzzzz');
      await tester.tap(find.bySemanticsIdentifier('move-sheet-allow'));
      await tester.pump();
      expect(move(tester).onPressed, isNotNull);
      // The visible label toggles the switch too.
      await tester.tap(find.byKey(const ValueKey<String>('move-sheet-allow-label')));
      await tester.pump();
      expect(move(tester).onPressed, isNull);
      await tester.tap(find.text('--allow-backwards'));
      await tester.pump();
      expect(move(tester).onPressed, isNotNull);
      expect(text(tester, 'move-sheet-command'), 'jj bookmark move feature/auth-flow --to zzzzzzzz --allow-backwards');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        confirmed.single,
        isA<GraphBookmarkMove>()
            .having((a) => a.names, 'names', <String>['feature/auth-flow'])
            .having((a) => a.to, 'to', _z)
            .having((a) => a.allowBackwards, 'allowBackwards', true),
      );
      expect(
        drops.calls.map((c) => (c.$1 as BookmarkDropSource).name).toSet(),
        <String>{'feature/auth-flow', 'feature/onboarding/pager', 'main'},
        reason: 'one check per built row',
      );
    });

    testWidgets('a sideways row says so; a pending check keeps Move off; a refused row shows the reason', (
      tester,
    ) async {
      final drops = _Drops(
        (name) => name == 'main'
            ? _outcome(status: ActionStatus.refused, r: const ActionRefusal('jj.immutable', 'Commit y is immutable'))
            : _outcome(backwards: name == 'feature/auth-flow'),
      )..gate = Completer<void>();
      await pump(tester, read: () async => bookmarks, drops: drops, target: _w);
      expect(move(tester).onPressed, isNull, reason: 'the check is pending');
      drops.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('sideways'), findsOneWidget, reason: 'T and W are on different branches');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(text(tester, 'move-sheet-reason'), 'Commit y is immutable');
      expect(move(tester).onPressed, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(confirmed, isEmpty);
    });

    testWidgets('↑ ↓ drive the rows, a click picks one; without drops no check runs', (tester) async {
      await pump(tester, read: () async => bookmarks);
      expect(text(tester, 'move-sheet-command'), 'jj bookmark move feature/auth-flow --to zzzzzzzz');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(text(tester, 'move-sheet-command'), 'jj bookmark move feature/onboarding/pager --to zzzzzzzz');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(text(tester, 'move-sheet-command'), 'jj bookmark move main --to zzzzzzzz', reason: 'wraps');
      await tester.tap(row('feature/onboarding/pager'));
      await tester.pump();
      expect(text(tester, 'move-sheet-command'), 'jj bookmark move feature/onboarding/pager --to zzzzzzzz');
      expect(confirmed, isEmpty, reason: 'a click only picks');
      await tester.tap(find.bySemanticsIdentifier('move-sheet-confirm'));
      await tester.pump();
      expect(confirmed.single.command, 'jj bookmark move feature/onboarding/pager --to $_z', reason: 'runs on the key');
    });

    testWidgets('Esc cancels', (tester) async {
      await pump(tester, read: () async => bookmarks);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(cancelled, greaterThan(0));
    });

    final tags = <Bookmark>[
      localRow('v1.5.0-rc1', _t),
      remoteRow('v1.5.0-rc1', 'git', _t),
      remoteRow('v1.5.0-rc1', 'origin', _t),
      localRow('v1.4', _y),
    ];

    testWidgets('a tag on origin warns; a local one gets the --allow-move note; Move runs jj tag set --allow-move', (
      tester,
    ) async {
      await pump(tester, tag: true, read: () async => tags);
      expect(find.byType(ZsSwitch), findsNothing);
      expect(
        text(tester, 'move-sheet-published'),
        startsWith('v1.5.0-rc1 is on origin — moving it changes a published'),
      );
      expect(text(tester, 'move-sheet-command'), 'jj tag set v1.5.0-rc1 -r zzzzzzzz --allow-move');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(text(tester, 'move-sheet-note'), 'A tag that already exists moves only with --allow-move.');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        confirmed.single,
        isA<GraphTagSet>()
            .having((a) => a.names, 'names', <String>['v1.5.0-rc1'])
            .having((a) => a.revision, 'revision', _z)
            .having((a) => a.allowMove, 'allowMove', true),
      );
    });
  });
}
