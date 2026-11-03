// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/bookmarks/bookmark_list_view.dart';
import 'package:zanshin/src/features/graph/graph_drag.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_search_model.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/rail_preview.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_bookmark_list.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';

List<Bookmark> _rows({int extra = 0}) => <Bookmark>[
  localRow('feat', 'k2', synced: false),
  remoteRow(
    'feat',
    'origin',
    'k2',
    synced: false,
    ahead: const RefDistance(lower: 0, upper: 0),
    behind: const RefDistance(lower: 1, upper: 1),
  ),
  localRow('main', 'k1'),
  remoteRow('main', 'git', 'k1'),
  remoteRow('main', 'origin', 'k1'),
  remoteRow('release/1.5.x', 'origin', 'hid', tracked: false, synced: false),
  for (var i = 0; i < extra; i++) localRow('topic-$i', 'k0'),
];

Finder _button(String identifier) => find.byWidgetPredicate((w) => w is ZsButton && w.identifier == identifier);

Finder _row(int index) =>
    find.byWidgetPredicate((w) => w is Semantics && w.properties.identifier == 'bookmark-row-$index');

double _opacityOf(WidgetTester tester, String text) =>
    tester.widget<Opacity>(find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first).opacity;

void main() {
  setUpIconRegistry();
  final AppLocalizations strings = platformStrings();

  /// Pumps the pinned panel of a rig over [rows] (or the whole shell), runs [body], then tears it down before the
  /// binding checks its timers.
  Future<void> withPanel(
    WidgetTester tester,
    List<Bookmark> rows,
    Future<void> Function(BookmarkRig rig) body, {
    ZsAppearance appearance = const ZsAppearance(),
    void Function(BookmarkRig rig)? before,
  }) async {
    useShellWindow(tester);
    final rig = BookmarkRig(FakeBookmarkListSource(rows));
    before?.call(rig);
    await tester.pumpWidget(
      shellHost(
        appearance: appearance,
        Center(
          child: SizedBox(
            width: 300,
            height: 600,
            child: ListenableBuilder(
              listenable: rig.model,
              builder: (context, _) => PinnedPanel(item: bookmarksRailItem(strings, rig.model), onClose: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await body(rig);
    await tester.pumpWidget(const SizedBox.shrink());
    rig.dispose();
  }

  /// The whole shell with the Bookmarks item, for the preview and the pin.
  Future<void> withShell(
    WidgetTester tester,
    Future<void> Function(BookmarkRig rig, ShellController shell) body,
  ) async {
    useShellWindow(tester);
    final rig = BookmarkRig(FakeBookmarkListSource(_rows(extra: 2)));
    final shell = ShellController();
    await tester.pumpWidget(
      shellHost(
        ListenableBuilder(
          listenable: rig.model,
          builder: (context, _) => FloatingShell(
            controller: shell,
            railItems: <ShellRailItem>[bookmarksRailItem(strings, rig.model)],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await body(rig, shell);
    await tester.pumpWidget(const SizedBox.shrink());
    shell.dispose();
    rig.dispose();
  }

  TestGesture? mouse;

  /// Moves the one test mouse onto [target].
  Future<void> hover(WidgetTester tester, Finder target) async {
    if (mouse == null) {
      final TestGesture gesture = mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(() async {
        await gesture.removePointer();
        mouse = null;
      });
      await gesture.addPointer(location: Offset.zero);
    }
    await mouse!.moveTo(tester.getCenter(target));
    await tester.pump();
  }

  testWidgets('every non-git row in order; name mono 12, "id · subject", the state; outside the layout at .55', (
    tester,
  ) async {
    await withPanel(tester, _rows(), (rig) async {
      final names = <String>[
        for (final Text t in tester.widgetList<Text>(find.byType(Text)))
          if (t.style?.fontSize == ZsType.fsMd && t.data != null) t.data!,
      ];
      expect(names, <String>['feat', 'feat@origin', 'main', 'main@origin', 'release/1.5.x@origin']);
      expect(tester.widget<Text>(find.text('main')).style?.fontFamily, ZsType.monoFamily);
      expect(find.text('↑1'), findsOneWidget);
      expect(find.text('↓1'), findsOneWidget);
      expect(find.text('✓'), findsNWidgets(2));
      expect(find.text('remote'), findsOneWidget);
      expect(tester.widget<Text>(find.text('↑1')).style?.color, ZsColors.night.add);
      expect(tester.widget<Text>(find.text('remote')).style?.color, ZsColors.night.remote);
      expect(_opacityOf(tester, 'release/1.5.x@origin'), .55);
      expect(_opacityOf(tester, 'main'), 1);
      expect(find.text('k1 · about ck1', findRichText: true), findsNWidgets(2));
      expect(find.text('hid · about chid', findRichText: true), findsOneWidget);
      // The row's long state is its tooltip and VoiceOver label.
      expect(tester.getSemantics(_row(4)).label, 'release/1.5.x@origin — remote only, not tracked');
      expect(tester.getSemantics(_row(0)).label, 'feat — ahead of origin by 1');
    });
  });

  testWidgets('Story 10.10: a local row drags its bookmark (no pick); a remote row does not drag', (tester) async {
    await withPanel(tester, _rows(), (rig) async {
      Future<void> drag(String text) async {
        final TestGesture mouse = await tester.startGesture(
          tester.getCenter(find.text(text)),
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(const Offset(30, 0));
        await tester.pump();
        await mouse.moveBy(const Offset(30, 0));
        await tester.pump();
      }

      await drag('main');
      expect(rig.graph.drag.payload, isA<GraphBookmarkDrag>().having((p) => p.name, 'name', 'main'));
      rig.graph.drag.cancel();
      await tester.pump();
      expect(rig.graph.selected, isNull, reason: 'the drag swallowed the pick');
      await drag('release/1.5.x@origin');
      expect(rig.graph.drag.payload, isNull);
      await tester.pump();
    });
  });

  testWidgets('a pick in the pinned panel selects the visible target, and a hidden one goes to all()', (tester) async {
    await withPanel(tester, _rows(), (rig) async {
      await tester.tap(find.text('main'));
      await tester.pump();
      expect(rig.graph.selected, 'k1');
      await tester.tap(find.text('release/1.5.x@origin'));
      await tester.pump();
      await tester.pump();
      expect(rig.graphSource.requests.last.revset, 'all()');
      expect(rig.search.view, isA<GraphAllView>());
      expect(rig.graph.selected, 'hid');
      expect(_opacityOf(tester, 'release/1.5.x@origin'), 1, reason: 'all() shows it now');
    });
  });

  testWidgets('more than 5: the header shows the total, 5 rows, "+N more" pins; a row click closes and picks', (
    tester,
  ) async {
    await withShell(tester, (rig, shell) async {
      shell.railEnter('bookmarks');
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<RailPreview>(find.byType(RailPreview)).item.count, '7');
      final Finder inPreview = find.descendant(of: find.byType(RailPreview), matching: find.byType(BookmarkRowTile));
      expect(inPreview, findsNWidgets(5));
      expect(find.text('+2 more'), findsOneWidget);

      await tester.tap(find.descendant(of: find.byType(RailPreview), matching: find.text('main')));
      await tester.pump();
      expect(shell.previewId, isNull);
      expect(rig.graph.selected, 'k1');
      await tester.pump(const Duration(milliseconds: 500));

      shell.railEnter('bookmarks');
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('+2 more'));
      await tester.pump();
      expect(shell.pinnedId, 'bookmarks');
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.descendant(of: find.byType(PinnedPanel), matching: find.text('feat')));
      await tester.pump();
      expect(rig.graph.selected, 'k2');
      expect(shell.pinnedId, 'bookmarks', reason: 'the panel stays pinned after a pick');
    });
  });

  testWidgets('no bookmarks: the DS empty sentence', (tester) async {
    await withPanel(tester, const <Bookmark>[], (rig) async {
      expect(find.text('No bookmarks yet. Create one with `jj bookmark create <name>`.'), findsOneWidget);
    });
  });

  testWidgets('a failed read keeps the rows with a one-line note', (tester) async {
    await withPanel(tester, _rows(), (rig) async {
      rig.source.error = const ZanshinFfiException('jj.io_error', 'disk full');
      rig.graphSource.respond = (request) => bookmarkLayout(request, op: 'op2');
      rig.graph.reload();
      await tester.pump();
      await tester.pump();
      expect(find.text('The bookmarks could not be read: disk full'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
    });
  });

  testWidgets('stale: "Working copy is stale" above the kept rows; a hidden pick and Track are disabled', (
    tester,
  ) async {
    await withPanel(tester, _rows(), (rig) async {
      rig.source.error = staleError('stale');
      rig.graphSource.respond = (request) {
        if (request.revset == 'all()') {
          throw staleError('stale');
        }
        return bookmarkLayout(request, op: 'op2');
      };
      rig.graph.reload();
      await tester.pump();
      await tester.pump();
      expect(rig.model.stale, isTrue);
      // The graph turns stale too (its next request is refused).
      rig.graphSource.respond = (_) => throw staleError('stale');
      rig.graph.reload();
      await tester.pump();
      await tester.pump();
      expect(rig.graph.stale, isNotNull);
      expect(find.text(strings.staleTitle), findsOneWidget);
      expect(find.text('main'), findsOneWidget);

      final int requests = rig.graphSource.requests.length;
      await tester.tap(find.text('release/1.5.x@origin'));
      await tester.pump();
      expect(rig.graphSource.requests, hasLength(requests), reason: 'a hidden pick needs all(): disabled');
      expect(tester.getSemantics(_row(4)).label, endsWith(', ${strings.staleTitle}'));
      await tester.tap(find.text('main'));
      await tester.pump();
      expect(rig.graph.selected, 'k1', reason: 'a visible pick still works');

      await hover(tester, find.text('release/1.5.x@origin'));
      final ZsButton track = tester.widget<ZsButton>(_button('bookmark-track-4'));
      expect(track.onPressed, isNull);
      expect(track.disabledReason, strings.staleTitle);
    });
  });

  testWidgets(
    'Track on hover of an untracked remote row runs jj bookmark track; Untrack on a tracked one; none local',
    (
      tester,
    ) async {
      await withPanel(tester, _rows(), (rig) async {
        expect(_button('bookmark-track-4'), findsNothing, reason: 'shown only on hover or focus');
        await hover(tester, find.text('release/1.5.x@origin'));
        expect(tester.widget<ZsButton>(_button('bookmark-track-4')).label, 'Track');
        final ZsTooltip tooltip = tester.widget<ZsTooltip>(
          find.ancestor(of: _button('bookmark-track-4'), matching: find.byType(ZsTooltip)).first,
        );
        expect(tooltip.message, 'jj bookmark track release/1.5.x@origin');
        await tester.tap(_button('bookmark-track-4'));
        await tester.pump();
        expect(rig.actions.ran.single, isA<GraphBookmarkTrack>());
        expect(rig.actions.ran.single.command, 'jj bookmark track release/1.5.x@origin');

        await hover(tester, find.text('main@origin'));
        expect(tester.widget<ZsButton>(_button('bookmark-track-3')).label, 'Untrack');
        await hover(tester, find.text('main'));
        expect(_button('bookmark-track-2'), findsNothing);
      });
    },
  );

  testWidgets('keyboard: a focused row shows its button and a focus ring; Enter and Space pick', (tester) async {
    await withPanel(tester, _rows(), (rig) async {
      // The test host has no WidgetsApp traversal shortcuts: focus the node Tab lands on directly.
      FocusNode rowOf(String name) => tester
          .widget<Focus>(
            find.ancestor(
              of: find.text(name),
              matching: find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'bookmark row'),
            ),
          )
          .focusNode!;
      final FocusNode row = rowOf('release/1.5.x@origin');
      expect((row.canRequestFocus, row.skipTraversal), (true, false));
      row.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(_button('bookmark-track-4'), findsOneWidget, reason: 'focus shows the row action');
      final Iterable<BoxBorder?> borders = <BoxBorder?>[
        for (final DecoratedBox box in tester.widgetList<DecoratedBox>(
          find.ancestor(of: find.text('release/1.5.x@origin'), matching: find.byType(DecoratedBox)),
        ))
          if (box.decoration case BoxDecoration(:final border?)) border,
      ];
      expect(borders, isNotEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(rig.graphSource.requests.last.revset, 'all()');

      rowOf('main').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(rig.graph.selected, 'k1');
    });
  });

  testWidgets('inactive window: no hover paint', (tester) async {
    await withPanel(tester, _rows(), appearance: const ZsAppearance(inactive: true), (rig) async {
      await hover(tester, find.text('main'));
      final Iterable<Color?> painted = <Color?>[
        for (final DecoratedBox box in tester.widgetList<DecoratedBox>(
          find.ancestor(of: find.text('main'), matching: find.byType(DecoratedBox)),
        ))
          if (box.decoration case BoxDecoration(:final color)) color,
      ];
      expect(painted, isNot(contains(ZsColors.night.flHover)));
    });
  });
}
