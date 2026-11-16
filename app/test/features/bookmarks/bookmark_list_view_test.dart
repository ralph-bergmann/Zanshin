// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/bookmarks/bookmark_list_model.dart';
import 'package:zanshin/src/features/bookmarks/bookmark_list_view.dart';
import 'package:zanshin/src/features/bookmarks/ref_delete.dart';
import 'package:zanshin/src/features/graph/graph_card_menu.dart' show GraphNameSheet;
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

/// The I/O matrix's tree: two folders, a local row on top level and a remote row in a folder.
List<Bookmark> _treeRows() => <Bookmark>[
  localRow('feature/auth-flow', 'k2'),
  remoteRow('feature/auth-flow', 'origin', 'k2'),
  localRow('main', 'k1'),
  localRow('onboarding/step-1', 'k0'),
  remoteRow('onboarding/step-2', 'origin', 'k0', tracked: false, synced: false),
  localRow('wip', 'k0'),
  remoteRow('wip', 'origin', 'k0', tracked: false, synced: false),
];

Finder _button(String identifier) => find.byWidgetPredicate((w) => w is ZsButton && w.identifier == identifier);

Finder _iconButton(String identifier) => find.byWidgetPredicate((w) => w is ZsIconButton && w.identifier == identifier);

Finder _row(int index, {String kind = 'bookmark'}) =>
    find.byWidgetPredicate((w) => w is Semantics && w.properties.identifier == '$kind-row-$index');

Finder _text(String text) => find.text(text, findRichText: true);

/// The `Text.rich` whose plain text is [text].
Text _textOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.ancestor(of: _text(text), matching: find.byType(Text)).first);

double _opacityOf(WidgetTester tester, String text) =>
    tester.widget<Opacity>(find.ancestor(of: _text(text), matching: find.byType(Opacity)).first).opacity;

/// The state mark of the row showing [text] (`--fs-xs` mono).
String? _stateOf(WidgetTester tester, String text) => tester
    .widget<Text>(
      find.descendant(
        of: _tileOf(text),
        matching: find.byWidgetPredicate((w) => w is Text && w.style?.fontSize == ZsType.fsXs),
      ),
    )
    .data;

/// The leaf of [text]'s box: the row's decoration.
Finder _tileOf(String text) => find.ancestor(of: _text(text), matching: find.byType(DecoratedBox)).first;

ZsTooltip _tooltipOf(WidgetTester tester, Finder button) =>
    tester.widget<ZsTooltip>(find.ancestor(of: button, matching: find.byType(ZsTooltip)).first);

void main() {
  setUpIconRegistry();
  final AppLocalizations strings = platformStrings();

  /// Pumps the pinned panel of a rig over [rows] (the delete sheet's host around it), runs [body], then tears it down
  /// before the binding checks its timers.
  Future<void> withPanel(
    WidgetTester tester,
    List<Bookmark> rows,
    Future<void> Function(BookmarkRig rig) body, {
    ZsAppearance appearance = const ZsAppearance(),
    RefKind kind = RefKind.bookmark,
  }) async {
    useShellWindow(tester);
    final rig = BookmarkRig(FakeBookmarkListSource(rows), kind: kind);
    await tester.pumpWidget(
      shellHost(
        appearance: appearance,
        RefDeleteHost(
          flow: rig.deletes,
          child: Center(
            child: SizedBox(
              width: 340,
              height: 600,
              child: ListenableBuilder(
                listenable: rig.model,
                builder: (context, _) => PinnedPanel(
                  item: kind == RefKind.tag
                      ? tagsRailItem(strings, rig.model as TagListModel)
                      : bookmarksRailItem(strings, rig.model),
                  onClose: () {},
                ),
              ),
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
    Future<void> Function(BookmarkRig rig, ShellController shell) body, {
    RefKind kind = RefKind.bookmark,
  }) async {
    useShellWindow(tester);
    final rig = BookmarkRig(FakeBookmarkListSource(_rows(extra: 2)), kind: kind);
    final shell = ShellController();
    await tester.pumpWidget(
      shellHost(
        ListenableBuilder(
          listenable: rig.model,
          builder: (context, _) => FloatingShell(
            controller: shell,
            railItems: <ShellRailItem>[
              if (kind == RefKind.tag)
                tagsRailItem(strings, rig.model as TagListModel)
              else
                bookmarksRailItem(strings, rig.model),
            ],
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

  testWidgets('the tree: folders first, then the leaves in list order; name mono 12, "id · subject", the state', (
    tester,
  ) async {
    await withPanel(tester, _rows(), (rig) async {
      final names = <String>[
        for (final Text t in tester.widgetList<Text>(find.byType(Text)))
          if (t.style?.fontSize == ZsType.fsMd) t.textSpan?.toPlainText() ?? t.data!,
      ];
      expect(names, <String>['1.5.x@origin', 'feat', 'feat@origin', 'main', 'main@origin']);
      expect(_text('release/'), findsOneWidget, reason: 'the folder row with its trailing /');
      expect(_textOf(tester, 'main').style?.fontFamily, ZsType.monoFamily);
      expect(find.text('↑1'), findsOneWidget);
      expect(find.text('↓1'), findsOneWidget);
      expect(find.text('✓'), findsNWidgets(2));
      expect(tester.widget<Text>(find.text('↑1')).style?.color, ZsColors.night.add);
      // An untracked remote row is marked by its dim text alone.
      expect(_stateOf(tester, '1.5.x@origin'), '');
      // Outside the layout (.55) and untracked (.6).
      expect(_opacityOf(tester, '1.5.x@origin'), closeTo(.55 * .6, 1e-9));
      expect(_opacityOf(tester, 'main'), 1);
      expect(find.text('k1 · about ck1', findRichText: true), findsNWidgets(2));
      expect(find.text('hid · about chid', findRichText: true), findsOneWidget);
      // The row's long state is its VoiceOver label; the full name its tooltip.
      expect(tester.getSemantics(_row(4)).label, 'release/1.5.x@origin — remote only, not tracked');
      expect(tester.getSemantics(_row(0)).label, 'feat — ahead of origin by 1');
      expect(
        tester.widget<ZsTooltip>(find.ancestor(of: _text('1.5.x@origin'), matching: find.byType(ZsTooltip))).message,
        'release/1.5.x@origin',
      );
      // No leading glyph in the panel; leaves sit 20 deeper than their folder.
      expect(find.byWidgetPredicate((w) => w is ZanshinIcon && w.name == ZI.bookmarkFilled), findsNothing);
      expect(
        tester.getTopLeft(_text('1.5.x@origin')).dx - tester.getTopLeft(_text('main')).dx,
        14,
        reason: 'one folder deeper',
      );
    });
  });

  testWidgets('a folder toggles on click, ↩ and Space; its leaves hide while it is folded', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await withPanel(tester, _rows(), (rig) async {
      expect(tester.getSemantics(find.bySemanticsIdentifier('ref-folder-release/')), isSemantics(isExpanded: true));
      await tester.tap(_text('release/'));
      await tester.pump();
      expect(rig.model.collapsed, <String>{'release/'});
      expect(_text('1.5.x@origin'), findsNothing);
      expect(find.byWidgetPredicate((w) => w is ZanshinIcon && w.name == ZI.folder), findsOneWidget);
      tester
          .widget<Focus>(
            find.ancestor(
              of: _text('release/'),
              matching: find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'ref folder'),
            ),
          )
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(_text('1.5.x@origin'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(_text('1.5.x@origin'), findsNothing);
    });
    handle.dispose();
  });

  testWidgets('the filter keeps the matching leaves and their folders, open; the match is highlighted; no hit', (
    tester,
  ) async {
    await withPanel(tester, _treeRows(), (rig) async {
      expect(find.byType(ZsSearchField), findsOneWidget);
      expect(tester.widget<ZsSearchField>(find.byType(ZsSearchField)).placeholder, 'Filter bookmarks');
      expect(_stateOf(tester, 'main'), '', reason: 'a local-only bookmark shows no state');
      // A folded folder opens while the filter keeps it.
      rig.model.toggleFolder('onboarding/');
      await tester.pump();
      await tester.enterText(find.byType(EditableText), 'onb');
      await tester.pump();
      expect(rig.model.filter, 'onb');
      expect(_text('onboarding/'), findsOneWidget);
      expect(_text('step-1'), findsOneWidget);
      expect(_text('step-2@origin'), findsOneWidget);
      expect(_text('main'), findsNothing);
      expect(_text('feature/'), findsNothing);
      final folder = _textOf(tester, 'onboarding/').textSpan! as TextSpan;
      final hit = folder.children!.first as TextSpan;
      expect(hit.text, 'onb');
      expect(hit.style?.decoration, TextDecoration.underline);
      expect(hit.style?.color, ZsColors.night.accent);

      await tester.enterText(find.byType(EditableText), 'nothing');
      await tester.pump();
      expect(find.text('No bookmark matches “nothing”.'), findsOneWidget);
    });
  });

  testWidgets('Story 10.10: a local row drags its bookmark (no pick); a remote row does not drag', (tester) async {
    await withPanel(tester, _rows(), (rig) async {
      Future<void> drag(String text) async {
        final TestGesture mouse = await tester.startGesture(
          tester.getCenter(_text(text)),
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
      await drag('1.5.x@origin');
      expect(rig.graph.drag.payload, isNull);
      await tester.pump();
    });
  });

  testWidgets('a pick in the pinned panel selects the visible target, and a hidden one goes to all()', (tester) async {
    await withPanel(tester, _rows(), (rig) async {
      await tester.tap(_text('main'));
      await tester.pump();
      expect(rig.graph.selected, 'k1');
      await tester.tap(_text('1.5.x@origin'));
      await tester.pump();
      await tester.pump();
      expect(rig.graphSource.requests.last.revset, 'all()');
      expect(rig.search.view, isA<GraphAllView>());
      expect(rig.graph.selected, 'hid');
      expect(_opacityOf(tester, '1.5.x@origin'), closeTo(.6, 1e-9), reason: 'all() shows it now; still untracked');
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

      await tester.tap(find.descendant(of: find.byType(RailPreview), matching: _text('main')));
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

      await tester.tap(find.descendant(of: find.byType(PinnedPanel), matching: _text('feat')));
      await tester.pump();
      expect(rig.graph.selected, 'k2');
      expect(shell.pinnedId, 'bookmarks', reason: 'the panel stays pinned after a pick');
    });
  });

  testWidgets('Story 10.44: the Tags item previews 5 tags with the tag glyph, "+N more" pins the Tags view', (
    tester,
  ) async {
    await withShell(kind: RefKind.tag, tester, (rig, shell) async {
      expect(find.bySemanticsIdentifier('rail-tags'), findsOneWidget);
      shell.railEnter('tags');
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<RailPreview>(find.byType(RailPreview)).item.label, 'Tags');
      expect(
        find.descendant(
          of: find.byType(RailPreview),
          matching: find.byWidgetPredicate((w) => w is ZanshinIcon && w.name == ZI.tag),
        ),
        findsWidgets,
      );
      await tester.tap(find.text('+2 more'));
      await tester.pump();
      expect(shell.pinnedId, 'tags');
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<ZsSearchField>(find.byType(ZsSearchField)).placeholder, 'Filter tags');
    });
  });

  testWidgets('no bookmarks: the DS empty sentence; no tags: the tag one', (tester) async {
    await withPanel(tester, const <Bookmark>[], (rig) async {
      expect(find.text('No bookmarks yet. Create one with `jj bookmark create <name>`.'), findsOneWidget);
    });
    await withPanel(tester, const <Bookmark>[], kind: RefKind.tag, (rig) async {
      expect(find.text('No tags yet. Create one with `jj tag set <name>`.'), findsOneWidget);
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
      expect(_text('main'), findsOneWidget);
    });
  });

  testWidgets('stale: "Working copy is stale" above the kept rows; a hidden pick and the buttons are disabled', (
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
      expect(_text('main'), findsOneWidget);

      final int requests = rig.graphSource.requests.length;
      await tester.tap(_text('1.5.x@origin'));
      await tester.pump();
      expect(rig.graphSource.requests, hasLength(requests), reason: 'a hidden pick needs all(): disabled');
      expect(tester.getSemantics(_row(4)).label, endsWith(', ${strings.staleTitle}'));
      await tester.tap(_text('main'));
      await tester.pump();
      expect(rig.graph.selected, 'k1', reason: 'a visible pick still works');
      final TestGesture mouse = await tester.startGesture(
        tester.getCenter(_text('main')),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(30, 0));
      await tester.pump();
      await mouse.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(rig.graph.drag.payload, isNull, reason: 'nothing drags while stale');
      await mouse.up();
      await mouse.removePointer();
      await tester.pump();

      await hover(tester, _text('1.5.x@origin'));
      final ZsButton track = tester.widget<ZsButton>(_button('bookmark-track-4'));
      expect(track.onPressed, isNull);
      expect(track.disabledReason, strings.staleTitle);
      await hover(tester, _text('main'));
      expect(tester.widget<ZsIconButton>(_iconButton('bookmark-row-new-2')).disabledReason, strings.staleTitle);
    });
  });

  testWidgets('hover: the buttons replace the state, the height stays; local New + Delete, tracked Untrack + New, '
      'untracked Track + New', (tester) async {
    await withPanel(tester, _rows(), (rig) async {
      expect(_button('bookmark-track-4'), findsNothing, reason: 'shown only on hover or focus');
      final double height = tester.getSize(_tileOf('1.5.x@origin')).height;
      expect(height, greaterThanOrEqualTo(40));

      await hover(tester, _text('1.5.x@origin'));
      expect(tester.getSize(_tileOf('1.5.x@origin')).height, height);
      expect(
        find.descendant(
          of: _tileOf('1.5.x@origin'),
          matching: find.byWidgetPredicate((w) => w is Text && w.style?.fontSize == ZsType.fsXs),
        ),
        findsNothing,
        reason: 'the buttons take the state\'s place',
      );
      expect(tester.widget<ZsButton>(_button('bookmark-track-4')).label, 'Track');
      expect(_tooltipOf(tester, _button('bookmark-track-4')).cmd, 'jj bookmark track release/1.5.x@origin');
      // The shown command is the one that runs: jj new on the target's change id.
      expect(_tooltipOf(tester, _iconButton('bookmark-row-new-4')).cmd, 'jj new hid');
      expect(_iconButton('bookmark-row-delete-4'), findsNothing);
      await tester.tap(_button('bookmark-track-4'));
      await tester.pump();
      expect(rig.actions.ran.single, isA<GraphBookmarkTrack>());
      expect(rig.actions.ran.single.command, 'jj bookmark track release/1.5.x@origin');

      await hover(tester, _text('main@origin'));
      expect(tester.widget<ZsButton>(_button('bookmark-track-3')).label, 'Untrack');
      expect(_tooltipOf(tester, _iconButton('bookmark-row-new-3')).cmd, 'jj new k1');

      await hover(tester, _text('main'));
      expect(_button('bookmark-track-2'), findsNothing);
      expect(_tooltipOf(tester, _iconButton('bookmark-row-new-2')).cmd, 'jj new k1');
      expect(_tooltipOf(tester, _iconButton('bookmark-row-delete-2')).cmd, 'jj bookmark delete main');
      await tester.tap(_iconButton('bookmark-row-new-2'));
      await tester.pump();
      expect(rig.actions.ran.last, isA<GraphNew>().having((a) => a.parents, 'parents', <String>['k1']));
    });
  });

  testWidgets('keyboard: a focused row shows its buttons and a focus ring; Enter and Space pick', (tester) async {
    await withPanel(tester, _rows(), (rig) async {
      // The test host has no WidgetsApp traversal shortcuts: focus the node Tab lands on directly.
      FocusNode rowOf(String name) => tester
          .widget<Focus>(
            find.ancestor(
              of: _text(name),
              matching: find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'bookmark row'),
            ),
          )
          .focusNode!;
      final FocusNode row = rowOf('1.5.x@origin');
      expect((row.canRequestFocus, row.skipTraversal), (true, false));
      row.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(_button('bookmark-track-4'), findsOneWidget, reason: 'focus shows the row actions');
      final Iterable<BoxBorder?> borders = <BoxBorder?>[
        for (final DecoratedBox box in tester.widgetList<DecoratedBox>(
          find.ancestor(of: _text('1.5.x@origin'), matching: find.byType(DecoratedBox)),
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

  testWidgets('Delete… without a tracked remote deletes at once (an untracked remote copy does not ask)', (
    tester,
  ) async {
    await withPanel(tester, _treeRows(), (rig) async {
      await hover(tester, _text('wip'));
      await tester.tap(_iconButton('bookmark-row-delete-5'));
      await tester.pump();
      expect(find.bySemanticsIdentifier('ref-delete-sheet'), findsNothing);
      expect(rig.actions.ran.single.command, 'jj bookmark delete wip');
    });
  });

  testWidgets('Delete… with a tracked remote asks; each choice runs exactly its shown commands', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await withPanel(tester, _treeRows(), (rig) async {
      Future<void> open() async {
        await hover(tester, _text('auth-flow'));
        await tester.tap(_iconButton('bookmark-row-delete-0'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      Future<void> confirm() async {
        await tester.tap(find.widgetWithText(ZsButton, 'Delete'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      await open();
      expect(find.text('Delete feature/auth-flow?'), findsOneWidget);
      expect(find.text('The bookmark is also on origin. Where should it go?'), findsOneWidget);
      expect(find.text('jj bookmark forget feature/auth-flow'), findsOneWidget);
      expect(find.text('jj bookmark delete feature/auth-flow'), findsOneWidget);
      expect(
        find.text('jj bookmark delete feature/auth-flow\njj git push --remote origin --bookmark feature/auth-flow'),
        findsOneWidget,
      );
      expect(find.text('Undo works. origin keeps it; it stays here as an untracked remote bookmark.'), findsOneWidget);
      // The default is the middle choice.
      await confirm();
      expect(rig.actions.ran.map((a) => a.command), <String>['jj bookmark delete feature/auth-flow']);
      expect(rig.pushes, isEmpty);

      rig.actions.ran.clear();
      await open();
      await tester.tap(find.text('Only here — keep it on origin', findRichText: true));
      await tester.pump();
      await confirm();
      expect(rig.actions.ran.map((a) => a.command), <String>['jj bookmark forget feature/auth-flow']);

      rig.actions.ran.clear();
      await open();
      await tester.tap(find.text('Here and on origin now', findRichText: true));
      await tester.pump();
      await confirm();
      expect(rig.actions.ran.map((a) => a.command), <String>['jj bookmark delete feature/auth-flow']);
      expect(rig.pushes.single.command, 'jj git push --remote origin --bookmark feature/auth-flow');

      rig.actions.ran.clear();
      await open();
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(rig.actions.ran, isEmpty);
      expect(find.bySemanticsIdentifier('ref-delete-sheet'), findsNothing);
    });
    handle.dispose();
  });

  testWidgets('the right-click menu: the row actions, Rename… (local bookmarks), Copy name', (tester) async {
    await withPanel(tester, _rows(), (rig) async {
      final TestGesture right = await tester.startGesture(
        tester.getCenter(_text('main')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('New change here'), findsWidgets);
      expect(find.text('Delete…'), findsOneWidget);
      expect(find.text('Rename…'), findsOneWidget);
      expect(find.text('Copy name'), findsOneWidget);
      await tester.tap(find.text('Rename…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Rename main'), findsOneWidget);
      await tester.enterText(
        find.descendant(of: find.byType(GraphNameSheet), matching: find.byType(EditableText)),
        'trunk',
      );
      await tester.pump();
      expect(find.text('jj bookmark rename main trunk'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(rig.actions.ran.single.command, 'jj bookmark rename main trunk');
    });
  });

  testWidgets('Copy name copies the full name: name@remote for a remote row', (tester) async {
    final copied = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map<Object?, Object?>)['text'] as String?);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await withPanel(tester, _rows(), (rig) async {
      final TestGesture right = await tester.startGesture(
        tester.getCenter(_text('1.5.x@origin')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Rename…'), findsNothing, reason: 'a remote row has no rename');
      await tester.tap(find.text('Copy name'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(copied, <String>['release/1.5.x@origin']);
    });
  });

  testWidgets('Story 10.44: a tag leaf does not drag; its Delete runs the tag commands', (tester) async {
    await withPanel(
      tester,
      <Bookmark>[
        localRow('v1.5.0', 'k1'),
        remoteRow('v1.5.0', 'origin', 'k1'),
        remoteRow('v1.5.0', 'upstream', 'k1'),
        localRow('v1.4', 'k2'),
        remoteRow('nightly', 'origin', 'k0', tracked: false, synced: false),
      ],
      kind: RefKind.tag,
      (rig) async {
        expect(_stateOf(tester, 'v1.4'), '', reason: 'a local-only tag shows no state');
        expect(_stateOf(tester, 'nightly@origin'), '', reason: 'an untracked remote tag shows no mark');
        final TestGesture mouse = await tester.startGesture(
          tester.getCenter(_text('v1.5.0')),
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(const Offset(30, 0));
        await tester.pump();
        await mouse.moveBy(const Offset(30, 0));
        await tester.pump();
        expect(rig.graph.drag.payload, isNull, reason: 'tags never drag');
        await mouse.up();
        await mouse.removePointer();
        await tester.pump();

        await hover(tester, _text('v1.5.0@origin'));
        expect(tester.widget<ZsButton>(_button('tag-track-1')).label, 'Untrack');
        expect(_tooltipOf(tester, _button('tag-track-1')).cmd, 'jj tag untrack v1.5.0@origin');
        await hover(tester, _text('nightly@origin'));
        expect(tester.widget<ZsButton>(_button('tag-track-4')).label, 'Track');
        expect(_tooltipOf(tester, _button('tag-track-4')).cmd, 'jj tag track nightly@origin');

        await hover(tester, _text('v1.5.0'));
        expect(_tooltipOf(tester, _iconButton('tag-row-delete-0')).cmd, 'jj tag delete v1.5.0');
        await tester.tap(_iconButton('tag-row-delete-0'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('The tag is also on origin, upstream. Where should it go?'), findsOneWidget);
        await tester.tap(find.text('Only here — keep it on origin, upstream', findRichText: true));
        await tester.pump();
        await tester.tap(find.widgetWithText(ZsButton, 'Delete'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(rig.actions.ran.map((a) => a.command), <String>[
          'jj tag untrack v1.5.0@origin',
          'jj tag untrack v1.5.0@upstream',
          'jj tag delete v1.5.0',
        ]);
      },
    );
  });

  testWidgets('inactive window: no hover paint', (tester) async {
    await withPanel(tester, _rows(), appearance: const ZsAppearance(inactive: true), (rig) async {
      await hover(tester, _text('main'));
      final Iterable<Color?> painted = <Color?>[
        for (final DecoratedBox box in tester.widgetList<DecoratedBox>(
          find.ancestor(of: _text('main'), matching: find.byType(DecoratedBox)),
        ))
          if (box.decoration case BoxDecoration(:final color)) color,
      ];
      expect(painted, isNot(contains(ZsColors.night.flHover)));
    });
  });
}
