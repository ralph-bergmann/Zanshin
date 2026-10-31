// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_content.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_peek.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_stack_card.dart';
import 'package:zanshin/src/features/graph/graph_stack_popover.dart';
import 'package:zanshin/src/features/graph/graph_stack_store.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart' show ZanshinFfiException;
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../../widgetbook/graph/fake_content.dart';
import '../../../widgetbook/graph/graph_recordings.g.dart';
import '../../../widgetbook/graph/stack_recordings.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

/// The design sample's "now" (its input's `now_ms`).
final _now = (jsonDecode(graphRecordings['design-default free compact']!.$1) as Map<String, Object?>)['now_ms']! as int;

/// The fakes' answer: the stack recording matching the request, else the ungrouped one, with fake content inline.
GraphLayout _respond(GraphRequest request) {
  final String? name = stackRecordingFor('design-default', request);
  if (name != null) {
    return stackRecording(name);
  }
  final (String input, String output) = graphRecordings['design-default ${request.mode.name} compact']!;
  return RecordedGraphLayout.fromSpec(input, output, content: fakeContent);
}

/// A large window, so every card of the design sample is mounted.
const _window = Size(4000, 2800);

RenderGraphStackCard? _stackRender(WidgetTester tester, String key) =>
    tester.allRenderObjects.whereType<RenderGraphStackCard>().where((r) => r.data.key == key).firstOrNull;

/// [render]'s card rect in global coordinates.
Rect _globalCard(RenderBox render, Rect local) => MatrixUtils.transformRect(render.getTransformTo(null), local);

Finder _cardOf(String key) =>
    find.byWidgetPredicate((w) => w is GraphCard && w.layout.keyOf(w.node) == key, skipOffstage: false);

Rect _cardRect(WidgetTester tester, String key) => tester.getRect(_cardOf(key)).deflate(graphCardOverhang);

void main() {
  setUpIconRegistry();

  group('the stack card (item 1)', () {
    testWidgets('design-default free default: count, range, newest subject, authors, dates and ⚠ from the members', (
      tester,
    ) async {
      useShellWindow(tester, _window);
      final RecordedGraphLayout layout = stackRecording('design-default free default');
      final cards = GraphCardController(now: _now);
      addTearDown(cards.dispose);
      // The widest card: the test font's glyphs are as wide as they are tall.
      await tester.pumpWidget(
        shellHost(GraphCanvas(layout: layout, cards: cards, options: const GraphViewOptions(cardWidth: 400))),
      );
      await tester.pump();
      expect(find.byType(GraphStackCard), findsNWidgets(layout.runCount));
      for (final GraphCard card in tester.widgetList<GraphCard>(find.byType(GraphCard, skipOffstage: false))) {
        expect(layout.isFolded(card.node), isFalse, reason: 'no folded member is built');
        expect(layout.isStackNode(card.node), isFalse);
      }
      final AppLocalizations strings = platformStrings();
      for (var run = 0; run < layout.runCount; run++) {
        final int stack = layout.stackNodeOf(run)!;
        final List<int> members = layout.runMembersOf(run);
        final RenderGraphStackCard render = _stackRender(tester, layout.keyOf(stack))!;
        final slots = <GraphStackSlot, String?>{
          for (final slot in render.debugSlots) slot.kind: slot.text,
        };
        String id(int node) {
          final String full = layout.changeIdOf(node);
          return full.substring(0, math.min(full.length, math.max(layout.changeIdPrefixLengthOf(node), 5)));
        }

        final GraphCommitContent newest = fakeContent(members.last, layout.keyOf(members.last));
        String? first(int node) {
          final GraphCommitContent c = fakeContent(node, layout.keyOf(node));
          final String name = c.authorName.trim().split(RegExp(r'\s+')).first;
          return name.isNotEmpty ? name : c.authorEmail.split('@').first;
        }

        String date(int node) =>
            graphRelativeDate(strings, layout.timestampOf(node)!, nowMs: _now, utcOffsetMinutes: 0);
        final String from = date(members.first);
        final String to = date(members.last);
        expect(slots[GraphStackSlot.badge], '${members.length}');
        expect(slots[GraphStackSlot.range], '${id(members.last)}‥${id(members.first)}');
        expect(slots[GraphStackSlot.subject], newest.subject.isEmpty ? '(no description set)' : newest.subject);
        expect(
          slots[GraphStackSlot.authors],
          <String>{for (final int m in members.reversed) ?first(m)}.join(', '),
        );
        expect(slots[GraphStackSlot.dates], from == to ? to : '$from – $to');
        expect(
          slots.containsKey(GraphStackSlot.conflict),
          members.any((m) => fakeContent(m, layout.keyOf(m)).conflict),
          reason: layout.keyOf(stack),
        );
      }
    });

    testWidgets('compact: badge, range, subject and ⚠ on one line', (tester) async {
      useShellWindow(tester, _window);
      final RecordedGraphLayout layout = stackRecording('design-default free default');
      final cards = GraphCardController(now: _now);
      addTearDown(cards.dispose);
      await tester.pumpWidget(
        shellHost(
          GraphCanvas(
            layout: layout,
            cards: cards,
            options: const GraphViewOptions(detailedCards: false),
          ),
        ),
      );
      final RenderGraphStackCard render = _stackRender(tester, layout.keyOf(layout.stackNodeOf(0)!))!;
      final List<({GraphStackSlot kind, Rect rect, String? text})> slots = render.debugSlots;
      expect(slots.map((s) => s.kind).take(3), <GraphStackSlot>[
        GraphStackSlot.badge,
        GraphStackSlot.range,
        GraphStackSlot.subject,
      ]);
      expect(slots.map((s) => s.rect.center.dy).toSet().length, 1, reason: 'one line');
      expect(slots.map((s) => s.kind), isNot(contains(GraphStackSlot.authors)));
    });

    testWidgets('semantics: one button, "N changes, subject, range", tap and expand expand', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      useShellWindow(tester, _window);
      final RecordedGraphLayout layout = stackRecording('design-default free default');
      final cards = GraphCardController(now: _now);
      addTearDown(cards.dispose);
      final expanded = <String>[];
      await tester.pumpWidget(shellHost(GraphCanvas(layout: layout, cards: cards, onExpandStack: expanded.add)));
      final int stack = layout.stackNodeOf(0)!;
      final List<int> members = layout.runMembersOf(0);
      final RenderGraphStackCard render = _stackRender(tester, layout.keyOf(stack))!;
      final SemanticsNode node = render.debugSemantics!;
      final SemanticsData data = node.getSemanticsData();
      final GraphCommitContent newest = fakeContent(members.last, layout.keyOf(members.last));
      expect(
        data.label,
        '${members.length} changes, ${newest.subject.isEmpty ? 'no description' : newest.subject}, '
        '${render.data.range}',
      );
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.identifier, 'graph-stack-${layout.keyOf(stack)}');
      node.owner!.performAction(node.id, SemanticsAction.tap);
      node.owner!.performAction(node.id, SemanticsAction.expand);
      expect(expanded, <String>[layout.keyOf(stack), layout.keyOf(stack)]);
      semantics.dispose();
    });
  });

  group('the view model (items 4–6)', () {
    late ScriptedGraphSource source;
    late GraphViewModel model;

    setUp(() => source = ScriptedGraphSource(respond: _respond));

    Future<void> create(WidgetTester tester, {GraphMode mode = GraphMode.free, GraphStackStore? store}) async {
      model = GraphViewModel()
        ..init(
          source,
          clock: () => DateTime.fromMillisecondsSinceEpoch(_now),
          mode: mode,
          stacks: true,
          stackStore: store,
        );
      await tester.pump();
    }

    testWidgets('expand: one request with the oldest key expanded, the anchor hinted, the members but it entering', (
      tester,
    ) async {
      await create(tester);
      final GraphLayout before = model.layout!;
      final List<int> members = before.runMembersOf(0);
      final String oldest = before.keyOf(members.first);
      final int requests = source.requests.length;
      model.expandStack(graphStackKey(oldest));
      expect(model.anchorHint, before.keyOf(members.last), reason: 'free anchors on the newest member');
      await tester.pump();
      expect(source.requests.length, requests + 1);
      expect(source.requests.last.expandedKeys, contains(oldest));
      expect(source.requests.last.collapsedKeys, isNot(contains(oldest)));
      expect(model.entering, <String>{for (final int m in members.take(members.length - 1)) before.keyOf(m)});
      final GraphLayout after = model.layout!;
      expect(after.isFolded(after.indexOfKey(oldest)!), isFalse);
      model.dispose();
    });

    testWidgets('collapse clears a selection inside the run; one request with the oldest key collapsed', (
      tester,
    ) async {
      await create(tester, mode: GraphMode.compact);
      final String oldest = model.layout!.keyOf(model.layout!.runMembersOf(0).first);
      model.expandStack(oldest);
      await tester.pump();
      final String member = model.layout!.keyOf(model.layout!.runMembersOf(0).last);
      model.select(member);
      final int requests = source.requests.length;
      model.collapseStack(member);
      expect(model.selected, isNull);
      expect(model.anchorHint, oldest, reason: 'compact anchors on the oldest member');
      await tester.pump();
      expect(source.requests.length, requests + 1);
      expect(source.requests.last.collapsedKeys, contains(oldest));
      expect(source.requests.last.expandedKeys, isNot(contains(oldest)));
      expect(source.requests.last.keepOpenKeys, isNot(contains(member)));
      expect(model.layout!.isFolded(model.layout!.indexOfKey(member)!), isTrue);
      expect(model.entering, isNull, reason: 'a collapse is instant');
      model.dispose();
    });

    testWidgets('a selection inside a run keeps it open when Group stacks turns on, and on a reload', (tester) async {
      model = GraphViewModel()..init(source, clock: () => DateTime.fromMillisecondsSinceEpoch(_now));
      await tester.pump();
      final GraphLayout grouped = stackRecording('design-default free default');
      final String member = grouped.keyOf(grouped.runMembersOf(1).last);
      model
        ..select(member)
        ..setStacks(true);
      await tester.pump();
      expect(source.requests.last.keepOpenKeys, contains(member));
      expect(model.layout!.isFolded(model.layout!.indexOfKey(member)!), isFalse);
      model.reload();
      await tester.pump();
      expect(model.layout!.isFolded(model.layout!.indexOfKey(member)!), isFalse);
      expect(model.selected, member);
      model.dispose();
    });

    testWidgets('go-to a folded member: a request keeping it open; on landing it is selected, revealed, pulsed', (
      tester,
    ) async {
      await create(tester);
      final String member = model.layout!.keyOf(model.layout!.runMembersOf(2).first);
      final int requests = source.requests.length;
      model.goTo(member);
      expect(model.pulse.value, isNull, reason: 'the pulse waits for the stack to open');
      await tester.pump();
      expect(source.requests.length, requests + 1);
      expect(source.requests.last.keepOpenKeys, contains(member));
      expect(model.selected, member);
      expect(model.reveal?.key, member);
      expect(model.pulse.value?.key, member);
      expect(model.layout!.isFolded(model.layout!.indexOfKey(member)!), isFalse);
      model.dispose();
    });

    testWidgets('go-to a folded member while a request is in flight queues one that keeps it open', (tester) async {
      await create(tester);
      final String member = model.layout!.keyOf(model.layout!.runMembersOf(2).first);
      source.hold = true;
      model.reload();
      await tester.pump();
      final int requests = source.requests.length;
      model.goTo(member);
      source.held.single.complete(GraphLoad(_respond(source.requests.last)));
      await tester.pump();
      expect(source.requests.length, requests + 1);
      expect(source.requests.last.keepOpenKeys, contains(member));
      source.held.last.complete(GraphLoad(_respond(source.requests.last)));
      await tester.pump();
      expect(model.layout!.isFolded(model.layout!.indexOfKey(member)!), isFalse);
      expect(model.reveal?.key, member);
      expect(model.pulse.value?.key, member);
      model.dispose();
    });

    testWidgets('a collapse while a request is in flight notifies at once: the inspector closes', (tester) async {
      await create(tester, mode: GraphMode.compact);
      final String oldest = model.layout!.keyOf(model.layout!.runMembersOf(0).first);
      model.expandStack(oldest);
      await tester.pump();
      final String member = model.layout!.keyOf(model.layout!.runMembersOf(0).last);
      model.select(member);
      source.hold = true;
      model.reload();
      await tester.pump();
      var notified = 0;
      model
        ..addListener(() => notified++)
        ..collapseStack(member);
      expect(model.selected, isNull);
      expect(notified, greaterThan(0), reason: 'before the held request lands');
      source.held.single.complete(GraphLoad(_respond(source.requests.last)));
      await tester.pump();
      source.held.last.complete(GraphLoad(_respond(source.requests.last)));
      await tester.pump();
      model.dispose();
    });

    testWidgets('a failed expand leaves no fade for a later layout', (tester) async {
      await create(tester);
      final String oldest = model.layout!.keyOf(model.layout!.runMembersOf(0).first);
      source.hold = true;
      model.expandStack(oldest);
      await tester.pump();
      source.held.single.completeError(const ZanshinFfiException('jj.io_error'));
      await tester.pump();
      source.hold = false;
      model.reload();
      await tester.pump();
      expect(model.entering, isNull);
      model.dispose();
    });

    testWidgets('the counter counts collapsed members as shown', (tester) async {
      await create(tester);
      final GraphLayout ungrouped = recording('design-default free compact');
      expect(model.layout!.runCount, greaterThan(0));
      expect(model.shown, ungrouped.nodeCount);
      model.dispose();
    });

    testWidgets('Group stacks off: no stack nodes', (tester) async {
      model = GraphViewModel()..init(source, clock: () => DateTime.fromMillisecondsSinceEpoch(_now));
      await tester.pump();
      expect(source.requests.last.stacks, isFalse);
      expect(model.layout!.runCount, 0);
      model.dispose();
    });

    group('persistence (item 5)', () {
      late Directory dir;
      late SettingsStore store;

      setUp(() async {
        dir = Directory.systemTemp.createTempSync('zanshin_stacks');
        final file = File('${dir.path}/settings.json')
          ..writeAsStringSync(
            jsonEncode(
              const AppSettings(
                projects: ProjectsSettings(
                  projects: <ProjectEntry>[
                    ProjectEntry(
                      path: '/r/a',
                      name: 'a',
                      expandedStacks: <String>['tqwmlnxz'],
                      collapsedStacks: <String>['gone0000'],
                    ),
                  ],
                ),
              ).toJson(),
            ),
          );
        store = await SettingsStore.load(file);
      });

      tearDown(() => dir.deleteSync(recursive: true));

      testWidgets("a model for A sends A's toggles first; one for B none; a toggle persists on A's entry", (
        tester,
      ) async {
        await create(tester, store: ProjectStackStore(store, '/r/a'));
        expect(source.requests.first.expandedKeys, <String>{'tqwmlnxz'});
        expect(source.requests.first.collapsedKeys, <String>{'gone0000'});
        final String oldest = model.layout!.keyOf(model.layout!.runMembersOf(1).first);
        model.expandStack(oldest);
        await tester.pump();
        expect(store.value.projects.projects.single.expandedStacks, (<String>['tqwmlnxz', oldest]..sort()));

        final other = ScriptedGraphSource(respond: _respond);
        final b = GraphViewModel()..init(other, stacks: true, stackStore: ProjectStackStore(store, '/r/b'));
        await tester.pump();
        expect(other.requests.first.expandedKeys, isEmpty);
        expect(other.requests.first.collapsedKeys, isEmpty);
        b.dispose();
        model.dispose();
      });

      test('a path outside the registry keeps its toggles in memory', () {
        final memory = ProjectStackStore(store, '/r/none');
        const toggles = GraphStackToggles(expanded: <String>{'x'});
        final AppSettings before = store.value;
        memory.save(toggles);
        expect(memory.load(), toggles);
        expect(store.value, before);
        expect(ProjectStackStore(store, '/r/none').load(), const GraphStackToggles());
      });

      test('a failed write keeps the toggles in memory and throws nothing', () async {
        final blocker = File('${dir.path}/blocker')..writeAsStringSync('');
        // The settings file's folder is a regular file: every write fails.
        final SettingsStore blocked = await SettingsStore.load(File('${blocker.path}/settings.json'));
        await blocked
            .update(
              (s) => s.copyWith(
                projects: const ProjectsSettings(
                  projects: <ProjectEntry>[ProjectEntry(path: '/r/a', name: 'a')],
                ),
              ),
            )
            .onError<FileSystemException>((_, _) {});
        final stacks = ProjectStackStore(blocked, '/r/a');
        const toggles = GraphStackToggles(expanded: <String>{'x'}, collapsed: <String>{'y'});
        stacks.save(toggles);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(stacks.load(), toggles);
      });

      testWidgets('a stored key that is no oldest member changes nothing: the run shows its default', (tester) async {
        await create(tester, store: ProjectStackStore(store, '/r/a'));
        final GraphLayout layout = model.layout!;
        final GraphLayout defaults = stackRecording('design-default free default');
        for (var run = 0; run < layout.runCount; run++) {
          final named = layout.keyOf(layout.runMembersOf(run).first) == 'tqwmlnxz';
          expect(layout.stackNodeOf(run) == null, named || defaults.stackNodeOf(run) == null);
        }
        model.dispose();
      });
    });

    test('the fakes pick the recording whose run states the engine would compute (item 8)', () {
      GraphRequest request({
        bool stacks = true,
        Set<String> expanded = const <String>{},
        Set<String> collapsed = const <String>{},
        Set<String> keepOpen = const <String>{},
      }) => GraphRequest(
        revset: 'L',
        prioritize: 'P',
        shortPrefixes: 'S',
        anchors: const <String>[],
        utcOffsetMin: 0,
        stacks: stacks,
        expandedKeys: expanded,
        collapsedKeys: collapsed,
        keepOpenKeys: keepOpen,
      );
      final GraphLayout defaults = stackRecording('design-default free default', inlineContent: false);
      final oldest = <String>[
        for (var r = 0; r < defaults.runCount; r++) defaults.keyOf(defaults.runMembersOf(r).first),
      ];
      expect(stackRecordingFor('design-default', request()), 'design-default free default');
      expect(stackRecordingFor('design-default', request(stacks: false)), isNull);
      expect(stackRecordingFor('medium-narrow', request()), isNull);
      expect(
        stackRecordingFor('design-default', request(expanded: <String>{oldest[1]})),
        'design-default free flip ${oldest[1]}',
      );
      expect(
        stackRecordingFor('design-default', request(keepOpen: <String>{defaults.keyOf(defaults.runMembersOf(2).last)})),
        'design-default free flip ${oldest[2]}',
      );
      expect(
        stackRecordingFor('design-default', request(expanded: <String>{oldest[0]}, collapsed: <String>{oldest[0]})),
        'design-default free flip ${oldest[0]}',
        reason: 'expanded wins over collapsed',
      );
      expect(stackRecordingFor('design-default', request(expanded: oldest.toSet())), 'design-default free expanded');
    });

    test('content: a stack node loads its members', () async {
      final RecordedGraphLayout layout = stackRecording('design-default free default', inlineContent: false);
      final asked = <String>[];
      final content = GraphContent((_, ids) async {
        asked.addAll(ids);
        return <String, GraphCommitContent>{};
      });
      addTearDown(content.dispose);
      final int stack = layout.stackNodeOf(0)!;
      content.load(layout, <int>[stack]);
      await Future<void>.delayed(Duration.zero);
      expect(asked, <String>[for (final int m in layout.runMembersOf(0)) layout.commitIdOf(m)]);
    });
  });

  group('the view (items 2–4)', () {
    late ScriptedGraphSource source;
    late GraphViewModel model;

    Future<void> pumpView(
      WidgetTester tester, {
      GraphMode mode = GraphMode.free,
      ZsAppearance appearance = const ZsAppearance(),
      Size window = const Size(1600, 1200),
    }) async {
      source = ScriptedGraphSource(respond: _respond);
      model = GraphViewModel()
        ..init(source, clock: () => DateTime.fromMillisecondsSinceEpoch(_now), mode: mode, stacks: true);
      useShellWindow(tester, window);
      await tester.pumpWidget(shellHost(GraphView(model: model), appearance: appearance));
      await tester.pump();
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    }

    ScrollPosition verticalOf(WidgetTester tester) =>
        tester.allRenderObjects.whereType<RenderGraphViewport>().single.verticalOffset as ScrollPosition;

    /// A stack card fully inside the window, preferring one near the centre.
    RenderGraphStackCard visibleStack(WidgetTester tester, Size window) {
      final Rect inside = (Offset.zero & window).deflate(80);
      final shown = <RenderGraphStackCard>[
        for (final RenderGraphStackCard r in tester.allRenderObjects.whereType<RenderGraphStackCard>())
          if (inside.contains(_globalCard(r, r.cardRect).topLeft) &&
              inside.contains(_globalCard(r, r.cardRect).bottomRight))
            r,
      ];
      expect(shown, isNotEmpty);
      final Offset centre = window.center(Offset.zero);
      shown.sort(
        (a, b) => (_globalCard(a, a.cardRect).center - centre).distance.compareTo(
          (_globalCard(b, b.cardRect).center - centre).distance,
        ),
      );
      return shown.first;
    }

    for (final GraphMode mode in GraphMode.values) {
      testWidgets('${mode.name}: a click expands with one request; the anchor member takes the stack card\'s rect; '
          'no visible node changes column', (tester) async {
        // A window lower than the plane, scrolled to the top: the anchor's correction has room.
        const window = Size(1600, 600);
        await pumpView(tester, mode: mode, window: window);
        verticalOf(tester).jumpTo(0);
        await tester.pump();
        final GraphLayout before = model.layout!;
        final RenderGraphStackCard stack = visibleStack(tester, window);
        final Rect was = _globalCard(stack, stack.cardRect);
        final int run = before.runOf(before.indexOfKey(stack.data.key)!)!;
        final String anchor = graphStackAnchorKey(before, run);
        final int requests = source.requests.length;
        await tester.tapAt(was.center);
        await tester.pump();
        await tester.pump();
        expect(source.requests.length, requests + 1);
        final GraphLayout after = model.layout!;
        expect(after.stackNodeOf(run), isNull);
        expect(_cardRect(tester, anchor), was);
        for (var i = 0; i < before.nodeCount; i++) {
          if (before.isFolded(i) || before.isStackNode(i)) {
            continue;
          }
          expect(after.colOf(after.indexOfKey(before.keyOf(i))!), before.colOf(i), reason: before.keyOf(i));
        }
        await tester.pumpAndSettle();
        await finish(tester);
      });
    }

    void focusGraph(WidgetTester tester) => tester
        .widget<Focus>(find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'graph'))
        .focusNode!
        .requestFocus();

    for (final pressed in <LogicalKeyboardKey>[LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
      testWidgets('${pressed.keyLabel} on a focused stack card expands it', (tester) async {
        await pumpView(tester);
        final GraphLayout layout = model.layout!;
        final String key = layout.keyOf(layout.stackNodeOf(0)!);
        focusGraph(tester);
        await tester.pump();
        tester.widget<GraphCanvas>(find.byType(GraphCanvas)).cards.focused.value = key;
        final int requests = source.requests.length;
        await tester.sendKeyEvent(pressed);
        await tester.pump();
        expect(source.requests.length, requests + 1);
        expect(source.requests.last.expandedKeys, contains(layout.keyOf(layout.runMembersOf(0).first)));
        expect(model.selected, isNull, reason: 'a stack is never selected');
        await tester.pumpAndSettle();
        await finish(tester);
      });
    }

    testWidgets('a collapse moves the keyboard focus from a folded member to its stack card', (tester) async {
      await pumpView(tester);
      final String oldest = model.layout!.keyOf(model.layout!.runMembersOf(0).first);
      model.expandStack(oldest);
      await tester.pump();
      await tester.pump();
      focusGraph(tester);
      await tester.pump();
      final GraphCardController cards = tester.widget<GraphCanvas>(find.byType(GraphCanvas)).cards;
      final String member = model.layout!.keyOf(model.layout!.runMembersOf(0).last);
      cards.focused.value = member;
      model.collapseStack(member);
      await tester.pump();
      await tester.pump();
      expect(cards.focused.value, graphStackKey(oldest));
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets("VoiceOver collapses an expanded run from a member's action", (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pumpView(tester);
      final RenderGraphStackCard stack = visibleStack(tester, const Size(1600, 1200));
      final GraphLayout grouped = model.layout!;
      final int run = grouped.runOf(grouped.indexOfKey(stack.data.key)!)!;
      final String oldest = grouped.keyOf(grouped.runMembersOf(run).first);
      model.expandStack(oldest);
      await tester.pump();
      await tester.pump();
      final String anchor = graphStackAnchorKey(model.layout!, run);
      final SemanticsNode node = tester.getSemantics(_cardOf(anchor));
      final String label = platformStrings().stackCollapseTooltip(grouped.runMembersOf(run).length);
      final int action = node.getSemanticsData().customSemanticsActionIds!.firstWhere(
        (id) => CustomSemanticsAction.getAction(id)!.label == label,
      );
      final int requests = source.requests.length;
      node.owner!.performAction(node.id, SemanticsAction.customAction, action);
      await tester.pump();
      await tester.pump();
      expect(source.requests.length, requests + 1);
      expect(source.requests.last.collapsedKeys, contains(oldest));
      expect(model.layout!.stackNodeOf(run), isNotNull);
      await tester.pumpAndSettle();
      await finish(tester);
      semantics.dispose();
    });

    testWidgets('the entering members fade in over 260 ms with a 6 px rise and .98 scale', (tester) async {
      await pumpView(tester);
      model.expandStack(visibleStack(tester, const Size(1600, 1200)).data.key);
      await tester.pump();
      await tester.pump();
      final String entering = model.entering!.firstWhere((key) => _cardOf(key).evaluate().isNotEmpty);
      Transform transform() =>
          tester.widget<Transform>(find.ancestor(of: _cardOf(entering), matching: find.byType(Transform)).first);
      Opacity opacity() =>
          tester.widget<Opacity>(find.ancestor(of: _cardOf(entering), matching: find.byType(Opacity)).first);
      expect(opacity().opacity, lessThan(.05));
      expect(transform().transform.getTranslation().y, closeTo(6, .3));
      expect(transform().transform.entry(0, 0), closeTo(.98, .002));
      expect(transform().transform.entry(1, 1), closeTo(.98, .002));
      await tester.pump(const Duration(milliseconds: 130));
      expect(opacity().opacity, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 131));
      expect(opacity().opacity, 1);
      expect(transform().transform.getTranslation().y, 0);
      await finish(tester);
    });

    testWidgets('under reduce motion the entering members fade with no rise and no scale', (tester) async {
      await pumpView(tester, appearance: const ZsAppearance(reduceMotion: true));
      model.expandStack(visibleStack(tester, const Size(1600, 1200)).data.key);
      await tester.pump();
      await tester.pump();
      final String entering = model.entering!.firstWhere((key) => _cardOf(key).evaluate().isNotEmpty);
      final Transform transform = tester.widget<Transform>(
        find.ancestor(of: _cardOf(entering), matching: find.byType(Transform)).first,
      );
      expect(transform.transform.getTranslation().y, 0);
      expect(transform.transform.entry(0, 0), 1);
      expect(
        tester.widget<Opacity>(find.ancestor(of: _cardOf(entering), matching: find.byType(Opacity)).first).opacity,
        lessThan(.05),
      );
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('a member hovered lights the bracket button; a press there starts no pan; a click collapses with '
        'one request and the stack card takes the anchor\'s rect', (tester) async {
      await pumpView(tester);
      final GraphLayout grouped = model.layout!;
      final RenderGraphStackCard stack = visibleStack(tester, const Size(1600, 1200));
      final int run = grouped.runOf(grouped.indexOfKey(stack.data.key)!)!;
      final String oldest = grouped.keyOf(grouped.runMembersOf(run).first);
      await tester.tapAt(_globalCard(stack, stack.cardRect).center);
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      final GraphLayout expanded = model.layout!;
      final String anchor = graphStackAnchorKey(expanded, run);
      final Rect anchorRect = _cardRect(tester, anchor);
      final Finder button = find.byKey(ValueKey<String>('graph-stack-collapse-$oldest'));
      expect(button, findsNothing);

      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: anchorRect.center);
      addTearDown(mouse.removePointer);
      await tester.pump();
      expect(button, findsOneWidget);
      // To the button: the card's hover intent passes, the bracket's strip keeps it hot.
      await mouse.moveTo(tester.getCenter(button));
      await tester.pump(graphHoverIntent * 2);
      expect(button, findsOneWidget);

      final ScrollPosition vertical = verticalOf(tester);
      final double offset = vertical.pixels;
      final TestGesture drag = await tester.startGesture(tester.getCenter(button), kind: PointerDeviceKind.mouse);
      await drag.moveBy(const Offset(0, -80));
      await tester.pump();
      await drag.up();
      await tester.pump();
      expect(vertical.pixels, offset, reason: 'a press on the button never pans');

      final int requests = source.requests.length;
      model.select(anchor);
      await tester.tapAt(tester.getCenter(button));
      await tester.pump();
      await tester.pump();
      expect(source.requests.length, requests + 1);
      expect(source.requests.last.collapsedKeys, contains(oldest));
      expect(model.selected, isNull);
      final GraphLayout collapsed = model.layout!;
      final RenderGraphStackCard back = _stackRender(tester, graphStackKey(oldest))!;
      expect(collapsed.stackNodeOf(run), isNotNull);
      expect(_globalCard(back, back.cardRect), anchorRect);
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('a run taller than the view shows its collapse button on the visible part of the bracket', (
      tester,
    ) async {
      await pumpView(tester, window: _window);
      final GraphLayout grouped = model.layout!;
      var run = 0;
      for (var r = 1; r < grouped.runCount; r++) {
        if (grouped.runMembersOf(r).length > grouped.runMembersOf(run).length) {
          run = r;
        }
      }
      final String oldest = grouped.keyOf(grouped.runMembersOf(run).first);
      model.expandStack(oldest);
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      final GraphLayout expanded = model.layout!;
      final members = <String>[for (final int m in expanded.runMembersOf(run)) expanded.keyOf(m)];
      final String top = members.reduce((a, b) => _cardRect(tester, a).top <= _cardRect(tester, b).top ? a : b);
      final String bottom = members.reduce(
        (a, b) => _cardRect(tester, a).bottom >= _cardRect(tester, b).bottom ? a : b,
      );
      final double span = _cardRect(tester, bottom).bottom - _cardRect(tester, top).top;
      // A view cut just below the run's top member: the bracket's centre lies outside it.
      final double height = _cardRect(tester, top).bottom + 4;
      useShellWindow(tester, Size(_window.width, height));
      await tester.pump();
      await tester.pump();
      final Rect first = _cardRect(tester, top);
      expect(first.top + span / 2, greaterThan(height), reason: 'precondition');
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: first.center);
      addTearDown(mouse.removePointer);
      await tester.pump();
      final Finder button = find.byKey(ValueKey<String>('graph-stack-collapse-$oldest'));
      expect(button, findsOneWidget);
      expect(tester.getCenter(button).dy, inInclusiveRange(first.top, height));
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('a rest on a stack opens its list after 380 ms below it; a row rest of 180 ms its callout; card → '
        'list → callout keeps them; leaving closes them; the peek never opens on a stack', (tester) async {
      await pumpView(tester);
      final RenderGraphStackCard stack = visibleStack(tester, const Size(1600, 1200));
      final Rect card = _globalCard(stack, stack.cardRect);
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: card.center);
      addTearDown(mouse.removePointer);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 370));
      expect(find.byType(GraphStackPopover), findsNothing);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(GraphStackPopover), findsOneWidget);
      expect(find.byType(GraphPeek), findsNothing, reason: 'no peek on a stack');
      final Rect list = tester.getRect(
        find.descendant(of: find.byType(GraphStackPopover), matching: find.byType(ZsMenuMaterial)).first,
      );
      expect(list.top, card.bottom + 12);
      expect(list.left, card.left);
      expect(list.width, card.width.clamp(280, 380));

      final List<int> members = model.layout!.runMembersOf(
        model.layout!.runOf(model.layout!.indexOfKey(stack.data.key)!)!,
      );
      final String newest = model.layout!.keyOf(members.last);
      final Finder row = find.byKey(ValueKey<String>('graph-stack-row-$newest'));
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump(const Duration(milliseconds: 170));
      expect(find.byType(GraphPeek), findsNothing);
      await tester.pump(const Duration(milliseconds: 20));
      final Finder callout = find.byKey(ValueKey<String>('graph-stack-callout-$newest'));
      expect(callout, findsOneWidget);
      await mouse.moveTo(tester.getCenter(callout));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(GraphStackPopover), findsOneWidget);
      expect(callout, findsOneWidget);

      await mouse.moveTo(const Offset(5, 1195));
      await tester.pump(graphHoverIntent);
      await tester.pumpAndSettle();
      expect(find.byType(GraphStackPopover), findsNothing);
      expect(find.byType(GraphPeek), findsNothing);
      await finish(tester);
    });
  });

  group('the list (item 2)', () {
    Future<GraphCardController> pumpList(WidgetTester tester, GraphLayout layout, Rect card, Rect area) async {
      final cards = GraphCardController(now: 1790000000000 + 600 * 60000);
      addTearDown(cards.dispose);
      useShellWindow(tester, const Size(1200, 900));
      await tester.pumpWidget(
        shellHost(
          GraphStackPopover(
            layout: layout,
            node: layout.stackNodeOf(0)!,
            card: card,
            area: area,
            controller: cards,
            closing: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return cards;
    }

    Rect listRect(WidgetTester tester) => tester.getRect(find.byType(ZsMenuMaterial).first);

    testWidgets('a 500-member stack: the height is capped at 8 rows, it scrolls, only visible rows are built', (
      tester,
    ) async {
      final RecordedGraphLayout layout = hugeStackLayout(500);
      await pumpList(tester, layout, const Rect.fromLTWH(100, 100, 240, 62), const Rect.fromLTWH(0, 0, 1200, 900));
      final Finder rows = find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('graph-stack-row-'),
      );
      expect(rows.evaluate().length, lessThan(20));
      final double height = tester.getSize(find.byType(ListView)).height;
      expect(height, graphStackMaxRows * graphStackRowHeight);
      expect(find.byKey(const ValueKey<String>('graph-stack-row-m499')), findsOneWidget, reason: 'newest first');
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('graph-stack-row-m499')), findsNothing);
      expect(rows.evaluate().length, lessThan(20));
      expect(find.text(platformStrings().stackExpandHint(500)), findsOneWidget);
    });

    testWidgets('above the card when it does not fit below the area; x and width clamped', (tester) async {
      final RecordedGraphLayout layout = hugeStackLayout(3);
      const area = Rect.fromLTWH(76, 60, 1000, 800);
      await pumpList(tester, layout, const Rect.fromLTWH(900, 760, 400, 62), area);
      final Rect list = listRect(tester);
      expect(list.bottom, 760 - 12);
      expect(list.width, 380);
      expect(list.right, area.right);
      await pumpList(tester, layout, const Rect.fromLTWH(30, 100, 160, 40), area);
      expect(listRect(tester).top, 140 + 12);
      expect(listRect(tester).left, area.left);
      expect(listRect(tester).width, 280);
    });
  });
}
