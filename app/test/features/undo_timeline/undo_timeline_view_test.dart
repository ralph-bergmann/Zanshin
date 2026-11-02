// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/rail_preview.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/undo_timeline/operation_changes.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_model.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_view.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_undo_timeline.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

final _now = DateTime(2026, 11, 1, 12);

List<Operation> _log(int count) => <Operation>[for (var i = 0; i < count; i++) testOperation(i, now: _now)];

Finder _button(String identifier) => find.byWidgetPredicate((w) => w is ZsButton && w.identifier == identifier);

ZsButton _buttonOf(WidgetTester tester, String identifier) => tester.widget<ZsButton>(_button(identifier));

ZsTooltip _tooltipOf(WidgetTester tester, String identifier) =>
    tester.widget<ZsTooltip>(find.ancestor(of: _button(identifier), matching: find.byType(ZsTooltip)).first);

final Finder _rows = find.byWidgetPredicate((w) => w is Text && (w.data?.startsWith('operation ') ?? false));

void main() {
  setUpIconRegistry();
  final AppLocalizations strings = platformStrings();
  late Directory dir;
  late SettingsStore settings;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('zanshin_undo_timeline');
    settings = await SettingsStore.load(File('${dir.path}/settings.json'));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// Pumps [model]'s pinned panel (or its preview), runs [body], then tears the tree and the model down before the
  /// binding checks its timers.
  Future<void> withTimeline(
    WidgetTester tester,
    FakeTimelineSource source,
    Future<void> Function(UndoTimelineModel model) body, {
    UndoTimelineActions? actions,
    OperationChangesSource? changes,
    bool preview = false,
  }) async {
    useShellWindow(tester);
    final model = UndoTimelineModel(source, clock: () => _now);
    final ShellRailItem item = undoTimelineRailItem(
      strings,
      model,
      changes: changes ?? FakeOperationChangesSource(testOpShow(testOperation(0, now: _now), const [])),
      settings: settings,
      actions: actions,
    );
    await tester.pumpWidget(
      shellHost(
        Center(
          child: SizedBox(
            width: preview ? 290 : 300,
            height: 600,
            child: preview
                ? Align(
                    alignment: Alignment.topCenter,
                    child: RailPreview(item: item, closing: false),
                  )
                : PinnedPanel(item: item, onClose: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
    await body(model);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  }

  Future<void> hover(WidgetTester tester, Finder target) async {
    final TestGesture gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
  }

  testWidgets('the preview lists the 3 newest descriptions with their relative times, and no count', (tester) async {
    await withTimeline(tester, FakeTimelineSource(_log(5)), preview: true, (model) async {
      for (final (String text, String ago) in const <(String, String)>[
        ('operation 0', 'now'),
        ('operation 1', '1h ago'),
        ('operation 2', '2h ago'),
      ]) {
        expect(find.text(text), findsOneWidget);
        expect(find.text(ago), findsOneWidget);
      }
      expect(find.text('operation 3'), findsNothing);
      expect(tester.widget<RailPreview>(find.byType(RailPreview)).item.count, isNull);
    });
  });

  testWidgets('1,000 operations: scrolling to the end reads 50, 100, … 1000; rows off screen are not built', (
    tester,
  ) async {
    final source = FakeTimelineSource(_log(1000));
    await withTimeline(tester, source, (model) async {
      expect(source.limits, <int>[50]);
      expect(tester.widgetList(_rows).length, lessThan(40), reason: 'only the rows in view and the cache extent');
      for (var i = 0; i < 200 && find.text('operation 999').evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -4000));
        await tester.pump();
        await tester.pump();
      }
      expect(find.text('operation 999'), findsOneWidget);
      // A full page of 1000 cannot tell it was the last: one more read (1050) finds no more.
      expect(source.limits, <int>[for (var limit = 50; limit <= 1050; limit += 50) limit]);
      expect(find.text('operation 0'), findsNothing);
      expect(tester.widgetList(_rows).length, lessThan(40));
    });
  });

  testWidgets('the current operation\'s dot is accent-line, the others faint; snapshot rows are at .55', (
    tester,
  ) async {
    final source = FakeTimelineSource(<Operation>[
      testOperation(0, now: _now),
      testOperation(1, now: _now, description: 'snapshot working copy', snapshot: true),
      testOperation(2, now: _now),
    ]);
    await withTimeline(tester, source, (model) async {
      final dots = <Color?>[
        for (final DecoratedBox box in tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)))
          if (box.decoration case BoxDecoration(shape: BoxShape.circle, :final color)) color,
      ];
      expect(dots, <Color?>[ZsColors.night.accentLine, ZsColors.night.textFaint, ZsColors.night.textFaint]);
      Opacity opacityOf(String text) =>
          tester.widget<Opacity>(find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first);
      expect(opacityOf('snapshot working copy').opacity, .55);
      expect(opacityOf('operation 0').opacity, 1);
    });
  });

  testWidgets('the newest row is filled --accent-soft, the others not', (tester) async {
    await withTimeline(tester, FakeTimelineSource(_log(2)), (model) async {
      Color? fillOf(String text) => tester
          .widgetList<DecoratedBox>(find.ancestor(of: find.text(text), matching: find.byType(DecoratedBox)))
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.borderRadius == BorderRadius.circular(6))
          .color;
      expect(fillOf('operation 0'), ZsColors.night.accentSoft);
      expect(fillOf('operation 1'), isNull);
    });
  });

  testWidgets('the args tag shows in mono under the description, the workspace beside the time', (tester) async {
    final source = FakeTimelineSource(<Operation>[testOperation(0, now: _now, args: 'jj new main')]);
    await withTimeline(tester, source, (model) async {
      expect(tester.widget<Text>(find.text('jj new main')).style?.fontFamily, ZsType.monoFamily);
      expect(find.text('now · default'), findsOneWidget);
    });
  });

  testWidgets('Undo on the newest row calls undoOperation once with it; Redo runs redoLast while one is offered', (
    tester,
  ) async {
    final actions = FakeTimelineActions();
    final source = FakeTimelineSource(<Operation>[testOperation(0, now: _now, args: 'jj new'), ..._log(3).skip(1)]);
    await withTimeline(tester, source, actions: actions, (model) async {
      expect(_buttonOf(tester, 'undo-timeline-redo').onPressed, isNull);
      expect(_buttonOf(tester, 'undo-timeline-redo').disabledReason, strings.undoTimelineNothingToRedo);
      await tester.tap(_button('undo-timeline-undo'));
      await tester.pump();
      expect(actions.undone, hasLength(1));
      expect(actions.undone.single.$1, opId(0));
      expect(actions.undone.single.$2.command, 'jj new');

      actions
        ..redoable = const GraphOutcome(GraphUndo(GraphLoggedOperation('x', 'y')))
        ..notifyListeners();
      await tester.pump();
      await tester.tap(_button('undo-timeline-redo'));
      await tester.pump();
      expect(actions.redos, 1);

      actions
        ..enabled = false
        ..notifyListeners();
      await tester.pump();
      expect(_buttonOf(tester, 'undo-timeline-undo').disabledReason, strings.undoTimelineBusy);
      expect(actions.undone, hasLength(1));
    });
  });

  testWidgets("a CLI undo at the head: Undo names the undo's target, Redo is enabled and calls redoOperation", (
    tester,
  ) async {
    final actions = FakeTimelineActions();
    final source = FakeTimelineSource(<Operation>[
      testOperation(0, now: _now, description: 'undo: restore to operation ${opId(2)}', args: 'jj undo'),
      testOperation(1, now: _now, args: 'jj new main'),
      testOperation(2, now: _now, args: 'jj describe -m wip'),
    ]);
    await withTimeline(tester, source, actions: actions, (model) async {
      await tester.tap(_button('undo-timeline-undo'));
      await tester.pump();
      expect(actions.undone.single.$1, opId(0), reason: 'the head it expects');
      expect(actions.undone.single.$2.id, opId(2), reason: 'jj undo takes back what the undo restored to');

      expect(_buttonOf(tester, 'undo-timeline-redo').onPressed, isNotNull);
      await tester.tap(_button('undo-timeline-redo'));
      await tester.pump();
      expect(actions.redos, 0);
      expect(actions.redone.single.$1, opId(0));
      expect(actions.redone.single.$2.command, 'jj new main', reason: "redo restores the undo's parent");
    });
  });

  testWidgets('a failing source is read a bounded number of times however many frames pass', (tester) async {
    final source = FakeTimelineSource(_log(60));
    await withTimeline(tester, source, (model) async {
      await tester.drag(find.byType(ListView), const Offset(0, -4000));
      source.refuse = const ZanshinFfiException('jj.io_error', 'disk full');
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(source.limits.length, lessThanOrEqualTo(2));
      expect(find.text(strings.undoTimelineLoadFailed('disk full')), findsOneWidget, reason: 'the note after the rows');
      expect(find.text('operation 49'), findsOneWidget, reason: 'the rows stay');
    });
  });

  testWidgets('Restore to here shows on hover and restores the row by its 12-hex id', (tester) async {
    final actions = FakeTimelineActions();
    await withTimeline(tester, FakeTimelineSource(_log(3)), actions: actions, (model) async {
      expect(_button('undo-timeline-restore-1'), findsNothing);
      await hover(tester, find.text('operation 1'));
      await tester.tap(_button('undo-timeline-restore-1'));
      await tester.pump();
      expect(actions.restored, <String>[shortOperationId(opId(1))]);
    });
  });

  testWidgets('keyboard focus on a row shows its Restore to here and Show changes; losing it hides them', (
    tester,
  ) async {
    await withTimeline(tester, FakeTimelineSource(_log(3)), actions: FakeTimelineActions(), (model) async {
      expect(_button('undo-timeline-restore-1'), findsNothing);
      // The test host has no WidgetsApp traversal shortcuts: focus the node Tab lands on directly.
      final FocusNode row = Focus.of(tester.element(find.text('operation 1')));
      expect(row.canRequestFocus, isTrue, reason: 'Tab can land on the row');
      expect(row.skipTraversal, isFalse);
      row.requestFocus();
      await tester.pump(); // the focus change, then the row's rebuild
      await tester.pump();
      expect(_button('undo-timeline-restore-1'), findsOneWidget, reason: 'focus shows the row actions');
      expect(_button('undo-timeline-show-1'), findsOneWidget);
      row.unfocus();
      await tester.pump();
      await tester.pump();
      expect(_button('undo-timeline-restore-1'), findsNothing);
    });
  });

  testWidgets("when the head's parent is the root operation, Undo is disabled with a reason", (tester) async {
    final source = FakeTimelineSource(<Operation>[testOperation(0, now: _now, parent: rootOpId), testRoot()]);
    final SemanticsHandle handle = tester.ensureSemantics();
    await withTimeline(tester, source, actions: FakeTimelineActions(), (model) async {
      final ZsButton undo = _buttonOf(tester, 'undo-timeline-undo');
      expect(undo.onPressed, isNull);
      expect(undo.disabledReason, strings.undoTimelineRootParent);
      expect(_tooltipOf(tester, 'undo-timeline-undo').cmd, 'jj undo');

      await hover(tester, find.text('root()'));
      expect(_button('undo-timeline-show-1'), findsOneWidget, reason: 'the root row shows its actions on hover');
      expect(_button('undo-timeline-restore-1'), findsNothing, reason: 'no restore to the root');
      expect(
        tester.getSemantics(find.bySemanticsIdentifier('undo-timeline-row-1')),
        isSemantics(label: 'root()', customActions: const <CustomSemanticsAction>[]),
      );
    });
    handle.dispose();
  });

  testWidgets("a root head: Undo is disabled with jj's \"Cannot undo root operation\"; the row reads root()", (
    tester,
  ) async {
    await withTimeline(tester, FakeTimelineSource(<Operation>[testRoot()]), actions: FakeTimelineActions(), (
      model,
    ) async {
      expect(_buttonOf(tester, 'undo-timeline-undo').disabledReason, 'Cannot undo root operation');
      expect(find.text('root()'), findsOneWidget);
      expect(find.textContaining('ago'), findsNothing, reason: 'the root shows no time');
    });
  });

  testWidgets('without a runner every action is disabled, each tooltip naming its full jj command', (tester) async {
    await withTimeline(tester, FakeTimelineSource(_log(3)), (model) async {
      await hover(tester, find.text('operation 1'));
      final String id = shortOperationId(opId(1));
      for (final (String identifier, String command) in <(String, String)>[
        ('undo-timeline-undo', 'jj undo'),
        ('undo-timeline-redo', 'jj redo'),
        ('undo-timeline-restore-1', 'jj op restore $id'),
      ]) {
        expect(_buttonOf(tester, identifier).onPressed, isNull, reason: identifier);
        expect(_buttonOf(tester, identifier).disabledReason, isNotNull, reason: identifier);
        expect(_tooltipOf(tester, identifier).cmd, command, reason: identifier);
      }
      expect(_buttonOf(tester, 'undo-timeline-undo').disabledReason, strings.undoTimelineNoRunner);
      expect(_buttonOf(tester, 'undo-timeline-show-1').onPressed, isNotNull, reason: 'Show changes needs no runner');
      expect(_tooltipOf(tester, 'undo-timeline-show-1').message, 'jj op show $id');
    });
  });

  for (final preview in <bool>[false, true]) {
    testWidgets('a stale working copy reads "Working copy is stale" without a Retry (preview: $preview)', (
      tester,
    ) async {
      final source = FakeTimelineSource(_log(3))..refuse = const ZanshinFfiException('jj.stale_working_copy');
      await withTimeline(tester, source, preview: preview, (model) async {
        expect(find.text('Working copy is stale'), findsOneWidget);
        expect(find.text('operation 0'), findsNothing);
        expect(find.text('Retry'), findsNothing);
      });
    });
  }

  testWidgets('VoiceOver reads each row as one node: description, time and workspace', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final actions = FakeTimelineActions();
    await withTimeline(tester, FakeTimelineSource(_log(2)), actions: actions, (model) async {
      final SemanticsNode row = tester.getSemantics(find.bySemanticsIdentifier('undo-timeline-row-1'));
      const restore = CustomSemanticsAction(label: 'Restore to here');
      expect(
        row,
        isSemantics(label: 'operation 1, 1h ago, workspace default', customActions: <CustomSemanticsAction>[restore]),
      );
      row.owner!.performAction(row.id, SemanticsAction.customAction, CustomSemanticsAction.getIdentifier(restore));
      expect(actions.restored, <String>[shortOperationId(opId(1))], reason: "VoiceOver's path to the hidden button");
    });
    handle.dispose();
  });

  testWidgets('the pinned Undo Timeline takes the shared panel width: 240–440, the same as Bookmarks', (tester) async {
    useShellWindow(tester);
    final model = UndoTimelineModel(FakeTimelineSource(_log(3)), clock: () => _now);
    final controller = ShellController()..panelWidth = 350;
    Rect panel() => tester.getRect(find.descendant(of: find.byType(PinnedPanel), matching: find.byType(ZsIsland)));
    await tester.pumpWidget(
      shellHost(
        FloatingShell(
          controller: controller,
          railItems: <ShellRailItem>[
            demoRailItems.first,
            undoTimelineRailItem(
              strings,
              model,
              changes: FakeOperationChangesSource(testOpShow(testOperation(0, now: _now), const [])),
              settings: settings,
            ),
          ],
        ),
      ),
    );
    controller.activate('undo');
    await tester.pumpAndSettle();
    expect(panel().width, 350);
    final Finder edge = find.byWidgetPredicate((w) => w is ZsResizeEdge && w.identifier == 'panel-edge');
    final TestGesture drag = await tester.startGesture(tester.getCenter(edge), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(400, 0));
    await tester.pump();
    expect(panel().width, 440);
    await drag.moveBy(const Offset(-800, 0));
    await tester.pump();
    expect(panel().width, 240);
    await drag.up();
    await tester.pumpAndSettle();
    controller.activate('bookmarks');
    await tester.pumpAndSettle();
    expect(panel().width, 240, reason: 'one width for both panels');
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    controller.dispose();
  });
}
