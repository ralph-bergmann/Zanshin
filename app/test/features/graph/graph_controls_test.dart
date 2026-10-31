// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_controls.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_preferences.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

const ZsMotion _m = ZsMotion.full;

/// [shown] keys `k0` … newest first, @ at `k0` unless [at] is false; `|all()|` is [total].
GraphLayout _layout(int shown, {int? total, bool at = true}) => handLayout(
  <(String, int, int)>[for (var i = 0; i < shown; i++) ('k$i', shown - 1 - i, 0)],
  edges: <(int, int)>[for (var i = 0; i + 1 < shown; i++) (i, i + 1)],
  workingCopy: at ? 0 : null,
  totalCount: total,
);

/// Each run waits on [gate] while it is set, else writes one operation and gives birth to `born`.
class _Actions implements GraphActions {
  final ran = <GraphAction>[];
  Completer<MutationResult>? gate;

  @override
  Future<String> headOpId() async => 'op${ran.length}';

  @override
  Future<MutationResult> run(GraphAction action) async {
    ran.add(action);
    if (gate case final gate?) {
      return gate.future;
    }
    return MutationResult(
      newOpId: 'op${ran.length}',
      newChangeIds: const <String>['born'],
      abandonedChangeIds: const <String>[],
      workingCopyChangeId: null,
      finish: null,
    );
  }
}

/// The controls in a floating shell over a graph, on a store in a temp folder.
class _Rig {
  _Rig(this.store, {bool withActions = true, GraphLayout Function(GraphRequest)? respond}) {
    source.respond = respond ?? (_) => _layout(3, total: 3);
    preferences = GraphPreferences(store)
      ..init(model, source, actions: withActions ? actions : null, clock: () => DateTime.utc(2026, 10, 31));
    _rigs.add(this);
  }

  final SettingsStore store;
  final source = ScriptedGraphSource();
  final actions = _Actions();
  final model = GraphViewModel();
  final shell = ShellController();
  late final GraphPreferences preferences;
  var settings = 0;

  /// The Esc presses that reached the window root.
  var escapes = 0;

  Widget host({bool onSettings = false}) => shellHost(
    Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          escapes++;
        }
        return KeyEventResult.ignored;
      },
      child: _shell(onSettings: onSettings),
    ),
  );

  Widget _shell({required bool onSettings}) => FloatingShell(
    controller: shell,
    graph: ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => GraphView(model: model, options: preferences.options),
    ),
    view: GraphViewControls(
      model: model,
      preferences: preferences,
      onSettings: onSettings ? () => settings++ : null,
    ),
    newChange: NewChangeButton(model: model),
  );

  void dispose() {
    preferences.dispose();
    model.dispose();
    shell.dispose();
  }
}

/// A stack store holding one expanded and one collapsed toggle (Story 10.17).
class _Toggles implements GraphStackStore {
  @override
  GraphStackToggles load() => const GraphStackToggles(expanded: <String>{'up'}, collapsed: <String>{'down'});

  @override
  void save(GraphStackToggles toggles) {}
}

/// A store on a missing file in a fresh temp folder, holding [graph]. Loading a missing file reads nothing, and the
/// value changes synchronously; the writes run in the background, their outcome unobserved.
Future<SettingsStore> _store([GraphSettings? graph]) async {
  final Directory dir = Directory.systemTemp.createTempSync('zanshin_graph_controls');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  final SettingsStore store = await SettingsStore.load(File('${dir.path}/settings.json'));
  if (graph != null) {
    unawaited(store.update((s) => s.copyWith(graph: graph)).onError<FileSystemException>((_, _) {}));
  }
  return store;
}

Future<_Rig> _start(
  WidgetTester tester, {
  Size window = shellWindow,
  GraphSettings? stored,
  bool withActions = true,
  GraphLayout Function(GraphRequest)? respond,
  bool onSettings = false,
}) async {
  useShellWindow(tester, window);
  final rig = _Rig(await _store(stored), withActions: withActions, respond: respond);
  await tester.pumpWidget(rig.host(onSettings: onSettings));
  await tester.pump();
  return rig;
}

/// The rigs of the running test.
final _rigs = <_Rig>[];

/// A widget test that unmounts the tree and disposes its rigs at the end of its body: a model's minute timer must not
/// outlive the test.
void _testWidgets(String description, Future<void> Function(WidgetTester tester) body) =>
    testWidgets(description, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      for (final _Rig rig in _rigs) {
        rig.dispose();
      }
      _rigs.clear();
    });

Finder _popover() => find.byType(ZsPopover);
Finder _optionsButton() => find.byWidgetPredicate((w) => w is ZsIconButton && w.icon == ZI.viewOptions);
Finder _switch(String label) => find.byWidgetPredicate((w) => w is ZsSwitch && w.label == label);

Future<void> _openPopover(WidgetTester tester) async {
  await tester.tap(_optionsButton());
  await tester.pump();
  await tester.pump(_m.durPop + const Duration(milliseconds: 1));
}

Future<void> _settleClose(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(_m.durExit + const Duration(milliseconds: 1));
  await tester.pump();
}

String _countText(WidgetTester tester) => tester
    .widget<Text>(find.descendant(of: find.byType(GraphCount), matching: find.byType(Text)))
    .textSpan!
    .toPlainText();

Future<void> _wheel(WidgetTester tester, double dy) async {
  final pointer = TestPointer(9, PointerDeviceKind.mouse, 9);
  await tester.sendEventToBinding(pointer.addPointer(location: const Offset(700, 500)));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.sendEventToBinding(pointer.removePointer());
  await tester.pump();
}

void main() {
  setUpIconRegistry();
  tearDown(ZsTooltip.resetWarmWindow);

  group('the count', () {
    _testWidgets('filtered: "12 of 340", the number bold, the tooltip "12 of 340 changes shown"', (tester) async {
      await _start(tester, respond: (_) => _layout(12, total: 340));
      expect(_countText(tester), '12 of 340');
      final span =
          tester.widget<Text>(find.descendant(of: find.byType(GraphCount), matching: find.byType(Text))).textSpan!
              as TextSpan;
      final TextSpan number = span.children!.whereType<TextSpan>().firstWhere((s) => s.text == '12');
      expect(number.style?.fontWeight, FontWeight.w600);
      expect(
        find.descendant(
          of: find.byType(GraphViewControls),
          matching: find.byWidgetPredicate((w) => w is ZsTooltip && w.message == '12 of 340 changes shown'),
        ),
        findsOneWidget,
      );
    });

    _testWidgets('all shown: "340 changes"', (tester) async {
      await _start(tester, respond: (_) => _layout(340, total: 340));
      expect(_countText(tester), '340 changes');
    });

    _testWidgets('total unknown: "12 changes", no tooltip', (tester) async {
      await _start(tester, respond: (_) => _layout(12));
      expect(_countText(tester), '12 changes');
      expect(find.descendant(of: find.byType(GraphCount), matching: find.byType(ZsTooltip)), findsNothing);
    });

    _testWidgets('a total below the shown count reads as the shown count: "12 changes"', (tester) async {
      await _start(tester, respond: (_) => _layout(12, total: 5));
      expect(_countText(tester), '12 changes');
      expect(find.byWidgetPredicate((w) => w is ZsTooltip && w.message == '12 of 12 changes shown'), findsOneWidget);
    });

    _testWidgets('one change reads singular', (tester) async {
      await _start(tester, respond: (_) => _layout(1, total: 1));
      expect(_countText(tester), '1 change');
    });

    _testWidgets('no layout: nothing', (tester) async {
      useShellWindow(tester);
      final rig = _Rig(await _store());
      rig.source.hold = true;
      rig.model.reload();
      await tester.pumpWidget(rig.host());
      expect(find.descendant(of: find.byType(GraphCount), matching: find.byType(Text)), findsNothing);
    });

    _testWidgets('at 1040 px the count and its separator are not built; the button stays; at 1041 they are', (
      tester,
    ) async {
      await _start(tester, window: const Size(1040, 900));
      expect(find.byType(GraphCount), findsNothing);
      expect(
        find.descendant(of: find.byType(GraphViewControls), matching: find.byType(ZsIslandSeparator)),
        findsNothing,
      );
      expect(_optionsButton(), findsOneWidget);
      tester.view.physicalSize = const Size(1041, 900);
      await tester.pump();
      expect(find.byType(GraphCount), findsOneWidget);
      expect(
        find.descendant(of: find.byType(GraphViewControls), matching: find.byType(ZsIslandSeparator)),
        findsOneWidget,
      );
    });
  });

  group('the View options popover', () {
    _testWidgets('opens 14 below the button, its right edge 5 right of it; the button is active while open', (
      tester,
    ) async {
      await _start(tester);
      expect(tester.widget<ZsIconButton>(_optionsButton()).active, isFalse);
      await _openPopover(tester);
      expect(_popover(), findsOneWidget);
      expect(tester.widget<ZsIconButton>(_optionsButton()).active, isTrue);
      final Rect button = tester.getRect(_optionsButton());
      final Rect popover = tester.getRect(find.descendant(of: _popover(), matching: find.byType(ZsMenuMaterial)));
      expect(popover.width, 340);
      expect(popover.top, button.bottom + 14);
      expect(popover.right, button.right + 5);
      expect(find.text('GRAPH VIEW'), findsOneWidget);
      for (final label in <String>['Layout', 'Detailed cards', 'Group stacks', 'Card width']) {
        expect(find.descendant(of: _popover(), matching: find.text(label)), findsOneWidget);
      }
      expect(
        find.byWidgetPredicate(
          (w) => w is ZsTooltip && w.message == 'Collapse linear runs of changes into one stack card',
        ),
        findsOneWidget,
      );
      final ZsSlider slider = tester.widget<ZsSlider>(find.byType(ZsSlider));
      expect((slider.min, slider.max, slider.step, slider.unit, slider.width), (160, 400, 10, 'px', 120));

      await tester.tap(_optionsButton());
      await _settleClose(tester);
      expect(_popover(), findsNothing);
      expect(tester.widget<ZsIconButton>(_optionsButton()).active, isFalse);
    });

    _testWidgets('in a short window it stays 8 inside the bottom edge', (tester) async {
      await _start(tester, window: const Size(1440, 300));
      await _openPopover(tester);
      final Rect popover = tester.getRect(find.descendant(of: _popover(), matching: find.byType(ZsMenuMaterial)));
      expect(popover.bottom, lessThanOrEqualTo(300 - 8));
      expect(popover.top, greaterThanOrEqualTo(8));
    });

    _testWidgets('a press outside closes it', (tester) async {
      await _start(tester);
      await _openPopover(tester);
      await tester.tapAt(const Offset(700, 600));
      await _settleClose(tester);
      expect(_popover(), findsNothing);
    });

    _testWidgets('Esc closes it, is consumed, leaves the selection and returns focus to the button', (tester) async {
      final _Rig rig = await _start(tester);
      rig.model.select('k1');
      await tester.pump();
      await _openPopover(tester);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'View options popover', reason: 'focus moved in');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settleClose(tester);
      expect(_popover(), findsNothing);
      expect(rig.model.selected, 'k1');
      expect(rig.escapes, 0, reason: 'the popover consumed the Esc');
      expect(
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<ZsIconButton>()?.icon,
        ZI.viewOptions,
      );
    });

    _testWidgets('holds calm while open, its exit included; releases on close', (tester) async {
      final _Rig rig = await _start(tester);
      await _openPopover(tester);
      expect(rig.shell.calm.held, isTrue);
      await _wheel(tester, 100);
      await tester.pump(const Duration(milliseconds: 100));
      expect(rig.shell.calm.value.calm, isFalse, reason: 'the open popover holds calm');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(rig.shell.calm.held, isTrue, reason: 'still leaving');
      await _settleClose(tester);
      expect(rig.shell.calm.held, isFalse);
      await tester.pump(const Duration(seconds: 2));
    });

    _testWidgets('releases calm when unmounted while open', (tester) async {
      final _Rig rig = await _start(tester);
      await _openPopover(tester);
      expect(rig.shell.calm.held, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(rig.shell.calm.held, isFalse);
    });

    _testWidgets('Layout: one request, mode compact, re-centred on @, stored', (tester) async {
      final _Rig rig = await _start(tester);
      final int before = rig.source.requests.length;
      await _openPopover(tester);
      await tester.tap(find.descendant(of: _popover(), matching: find.text('Compact')));
      await tester.pump();
      expect(rig.source.requests, hasLength(before + 1));
      expect(rig.source.requests.last.mode, GraphMode.compact);
      expect(rig.model.reveal?.key, 'k0', reason: 're-centred on @');
      expect(rig.store.value.graph.layout, GraphLayoutSetting.compact);
      expect(rig.preferences.options.layout, GraphMode.compact);
    });

    _testWidgets('Group stacks: one request with stacks off, no re-centre, stored', (tester) async {
      final _Rig rig = await _start(tester);
      expect(rig.source.requests.single.stacks, isTrue, reason: 'on by default');
      await _openPopover(tester);
      await tester.tap(_switch('Group stacks'));
      await tester.pump();
      expect(rig.source.requests, hasLength(2));
      expect(rig.source.requests.last.stacks, isFalse);
      expect(rig.model.reveal, isNull, reason: 'the anchor holds');
      expect(rig.store.value.graph.groupStacks, isFalse);
    });

    _testWidgets('Detailed cards and Card width: no request, the view options change, stored', (tester) async {
      final _Rig rig = await _start(tester);
      await _openPopover(tester);
      await tester.tap(_switch('Detailed cards'));
      await tester.pump();
      tester.widget<ZsSlider>(find.byType(ZsSlider)).onChanged!(300);
      await tester.pump();
      expect(rig.source.requests, hasLength(1));
      final GraphViewOptions options = tester.widget<GraphCanvas>(find.byType(GraphCanvas)).options;
      expect(options.detailedCards, isFalse);
      expect(options.cardWidth, 300);
      expect(tester.widget<ZsSlider>(find.byType(ZsSlider)).value, 300);
      expect(rig.store.value.graph.detailedCards, isFalse);
      expect(rig.store.value.graph.cardWidth, 300);
    });

    _testWidgets('every control in the island and the popover is a Zs control; no material_ui widget is in the tree', (
      tester,
    ) async {
      await _start(tester);
      await _openPopover(tester);
      for (final type in <Type>[
        material.Material,
        material.Switch,
        material.Slider,
        material.SegmentedButton<Object>,
        material.Tooltip,
        material.IconButton,
        material.TextButton,
        material.FilledButton,
        material.ElevatedButton,
        material.InkWell,
      ]) {
        expect(find.byType(type), findsNothing, reason: '$type');
      }
      expect(find.byType(ZsSegmented<GraphMode>), findsOneWidget);
      expect(find.byType(ZsSwitch), findsNWidgets(2));
      expect(find.byType(ZsSlider), findsOneWidget);
      expect(find.byType(ZsOptionLink), findsOneWidget);
      expect(find.byType(ZsButton), findsWidgets);
    });

    _testWidgets('"Appearance, diffs and more" is disabled without onSettings', (tester) async {
      await _start(tester);
      await _openPopover(tester);
      final ZsOptionLink link = tester.widget<ZsOptionLink>(find.byType(ZsOptionLink));
      expect(link.onPressed, isNull);
      expect((link.label, link.action, link.shortcut), ('Appearance, diffs and more', 'Settings…', null));
    });

    _testWidgets('"Appearance, diffs and more" runs onSettings and closes the popover', (tester) async {
      final _Rig rig = await _start(tester, onSettings: true);
      await _openPopover(tester);
      await tester.tap(find.text('Appearance, diffs and more'));
      await _settleClose(tester);
      expect(rig.settings, 1);
      expect(_popover(), findsNothing);
    });
  });

  group('preferences', () {
    _testWidgets('restored compact / stacks off / 300 px go into the first request and the view options', (
      tester,
    ) async {
      final _Rig rig = await _start(
        tester,
        stored: const GraphSettings(layout: GraphLayoutSetting.compact, groupStacks: false, cardWidth: 300),
      );
      expect(rig.source.requests.first.mode, GraphMode.compact);
      expect(rig.source.requests.first.stacks, isFalse);
      expect(rig.preferences.options.cardWidth, 300);
      expect(tester.widget<GraphCanvas>(find.byType(GraphCanvas)).options.cardWidth, 300);
    });

    test('a non-finite width reads as 240', () {
      expect(GraphPreferences.snapCardWidth(double.infinity), 240);
      expect(GraphPreferences.snapCardWidth(double.negativeInfinity), 240);
      expect(GraphPreferences.snapCardWidth(double.nan), 240);
    });

    test('the card width is clamped to 160–400 and snapped to 10', () {
      expect(GraphPreferences.snapCardWidth(304), 300);
      expect(GraphPreferences.snapCardWidth(305), 310);
      expect(GraphPreferences.snapCardWidth(90), 160);
      expect(GraphPreferences.snapCardWidth(1000), 400);
    });

    test('a stored width out of range is clamped in the options', () async {
      final SettingsStore store = await _store(const GraphSettings(cardWidth: 900));
      final preferences = GraphPreferences(store);
      addTearDown(preferences.dispose);
      expect(preferences.options.cardWidth, 400);
    });

    test('another writer of the store reaches the bound model and notifies', () async {
      final SettingsStore store = await _store();
      final preferences = GraphPreferences(store);
      final source = ScriptedGraphSource();
      final model = GraphViewModel();
      preferences.init(model, source);
      addTearDown(() {
        preferences.dispose();
        model.dispose();
      });
      var notified = 0;
      preferences.addListener(() => notified++);
      await Future<void>.delayed(Duration.zero);
      unawaited(
        store
            .update((s) => s.copyWith.graph(layout: GraphLayoutSetting.compact, groupStacks: false))
            .onError<FileSystemException>((_, _) {}),
      );
      expect(notified, 1);
      expect(model.mode, GraphMode.compact);
      expect(model.stacks, isFalse);
    });

    test('init forwards the stack store: the first request carries its toggles (Story 10.17)', () async {
      final SettingsStore store = await _store();
      final preferences = GraphPreferences(store);
      final source = ScriptedGraphSource();
      final model = GraphViewModel();
      addTearDown(() {
        preferences.dispose();
        model.dispose();
      });
      preferences.init(model, source, stackStore: _Toggles());
      await Future<void>.delayed(Duration.zero);
      expect(source.requests.first.expandedKeys, <String>{'up'});
      expect(source.requests.first.collapsedKeys, <String>{'down'});
    });

    test('a failed write keeps the value in memory and throws nothing', () async {
      final Directory dir = Directory.systemTemp.createTempSync('zanshin_graph_controls');
      addTearDown(() => dir.deleteSync(recursive: true));
      final blocker = File('${dir.path}/blocker')..writeAsStringSync('');
      // The settings file's folder is a regular file: every write fails.
      final SettingsStore store = await SettingsStore.load(File('${blocker.path}/settings.json'));
      final preferences = GraphPreferences(store);
      addTearDown(preferences.dispose);
      preferences.setCardWidth(300);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(preferences.options.cardWidth, 300);
      expect(store.value.graph.cardWidth, 300);
    });
  });

  group('New change', () {
    _testWidgets('runs jj new on @ once; a selected @ moves to the born change', (tester) async {
      final _Rig rig = await _start(tester);
      rig.model.select('k0');
      // The reload after jj new shows the born change.
      rig.source.respond = (_) => keysLayout(<String>['born', 'k0', 'k1', 'k2'], at: 'born');
      await tester.pump();
      expect(find.text('New change'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is ZsTooltip && w.message == 'jj new — start a new change on top of @'),
        findsOneWidget,
      );
      final ZsButton button = tester.widget<ZsButton>(
        find.byWidgetPredicate((w) => w is ZsButton && w.icon == ZI.plus),
      );
      expect((button.variant, button.size, button.iconOnly), (ZsButtonVariant.primary, ZsButtonSize.lg, false));
      await tester.tap(find.text('New change'));
      await tester.pump();
      await tester.pump();
      expect(rig.actions.ran, hasLength(1));
      final action = rig.actions.ran.single as GraphNew;
      expect(action.parents, <String>['k0']);
      expect(action.command, 'jj new k0');
      expect(rig.model.selected, 'born');
    });

    ZsButton newChange(WidgetTester tester) =>
        tester.widget<ZsButton>(find.byWidgetPredicate((w) => w is ZsButton && w.icon == ZI.plus));

    _testWidgets('disabled while an action runs', (tester) async {
      final _Rig rig = await _start(tester);
      rig.actions.gate = Completer<MutationResult>();
      await tester.tap(find.text('New change'));
      await tester.pump();
      expect(newChange(tester).onPressed, isNull);
      rig.actions.gate!.complete(
        const MutationResult(
          newOpId: 'op1',
          newChangeIds: <String>[],
          abandonedChangeIds: <String>[],
          workingCopyChangeId: null,
          finish: null,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(newChange(tester).onPressed, isNotNull);
    });

    _testWidgets('disabled while the working copy is stale', (tester) async {
      final _Rig rig = await _start(tester);
      expect(newChange(tester).onPressed, isNotNull);
      rig.source.respond = (_) => throw staleError('stale');
      rig.model.reload();
      await tester.pump();
      await tester.pump();
      expect(rig.model.stale, isNotNull);
      expect(newChange(tester).onPressed, isNull);
    });

    _testWidgets('disabled without GraphActions', (tester) async {
      await _start(tester, withActions: false);
      expect(newChange(tester).onPressed, isNull);
    });

    _testWidgets('disabled without @ in the layout', (tester) async {
      await _start(tester, respond: (_) => _layout(3, total: 3, at: false));
      expect(newChange(tester).onPressed, isNull);
    });

    _testWidgets('at 920 px only its icon shows, the tooltip stays; at 921 the label shows', (tester) async {
      await _start(tester, window: const Size(920, 900));
      expect(newChange(tester).iconOnly, isTrue);
      expect(
        find.byWidgetPredicate((w) => w is ZsTooltip && w.message == 'jj new — start a new change on top of @'),
        findsOneWidget,
      );
      tester.view.physicalSize = const Size(921, 900);
      await tester.pump();
      expect(newChange(tester).iconOnly, isFalse);
    });
  });
}
