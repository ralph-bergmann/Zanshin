// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_card_render.dart';
import 'package:zanshin/src/features/graph/graph_content.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_peek.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart' show ZsMotion;

import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

/// A chain of [rows] commits `r0` … `r<rows−1>` (column `row % 6`), @ at [at], commit ids `c-<key>`, computed at
/// [operationId]; [contents] inline per node when given.
RecordedGraphLayout _chain(
  int rows, {
  String at = 'r100',
  String operationId = 'op-1',
  String commitPrefix = 'c-',
  int? root,
  List<int?>? timestamps,
  List<GraphCommitContent?>? contents,
}) {
  final nodes = <(String, int, int)>[for (int row = rows - 1; row >= 0; row--) ('r$row', row, row % 6)];
  return handLayout(
    nodes,
    edges: <(int, int)>[for (var i = 0; i + 1 < nodes.length; i++) (i, i + 1)],
    workingCopy: nodes.indexWhere((node) => node.$1 == at),
    root: root,
    commitIds: <String>[for (final (String key, _, _) in nodes) '$commitPrefix$key'],
    operationId: operationId,
    timestamps: timestamps,
    contents: contents,
  );
}

RenderGraphViewport _viewportOf(WidgetTester tester) => tester.allRenderObjects.whereType<RenderGraphViewport>().single;

Set<RenderGraphCard> _cards(WidgetTester tester) => tester.allRenderObjects.whereType<RenderGraphCard>().toSet();

Finder _cardOf(String key) =>
    find.byWidgetPredicate((w) => w is GraphCard && w.layout.keyOf(w.node) == key, skipOffstage: false);

/// The commit ids of the window + buffer: the plane window the viewport shows, one viewport height above and below,
/// [graphContentBufferX] beside, every card counted as the viewport mounts it.
Set<String> _windowIds(WidgetTester tester) {
  final RenderGraphViewport render = _viewportOf(tester);
  final Rect visible =
      (Offset(render.horizontalOffset.pixels, render.verticalOffset.pixels) - render.insets.topLeft) & render.size;
  final window = Rect.fromLTRB(
    visible.left - graphContentBufferX,
    visible.top - visible.height,
    visible.right + graphContentBufferX,
    visible.bottom + visible.height,
  );
  return <String>{
    for (final int node in render.vertical.visibleNodes(window, graphCardOverhang)) render.graphLayout.commitIdOf(node),
  };
}

void main() {
  group('GraphContent', () {
    late List<({String? operationId, List<String> commitIds})> calls;
    late List<Completer<Map<String, GraphCommitContent>>> held;
    late GraphContent content;

    setUp(() {
      calls = <({String? operationId, List<String> commitIds})>[];
      held = <Completer<Map<String, GraphCommitContent>>>[];
      content = GraphContent((operationId, ids) {
        calls.add((operationId: operationId, commitIds: ids));
        final completer = Completer<Map<String, GraphCommitContent>>();
        held.add(completer);
        return completer.future;
      });
      addTearDown(content.dispose);
    });

    Map<String, GraphCommitContent> page(List<String> ids) => <String, GraphCommitContent>{
      for (final String id in ids) id: GraphCommitContent(subject: 'about $id'),
    };

    test(
      "a load asks for the missing ids at the layout's operation; a reload of the same commits asks nothing",
      () async {
        final RecordedGraphLayout first = _chain(10);
        content.load(first, <int>[0, 1, 2]);
        expect(calls.single.operationId, 'op-1');
        expect(calls.single.commitIds, <String>['c-r9', 'c-r8', 'c-r7']);
        held.single.complete(page(calls.single.commitIds));
        await pumpEventQueue();
        expect(content['c-r8']?.subject, 'about c-r8');

        // A new layout object over the same commits, at another operation: everything is cached.
        final RecordedGraphLayout second = _chain(10, operationId: 'op-2');
        content.load(second, <int>[0, 1, 2]);
        await pumpEventQueue();
        expect(calls, hasLength(1));
        expect(content.of(second, 1)?.subject, 'about c-r8');
      },
    );

    test('a page superseded by a queued load is dropped; the queued load asks for its own ids', () async {
      final RecordedGraphLayout layout = _chain(10);
      content
        ..load(layout, <int>[0, 1])
        ..load(layout, <int>[5])
        ..load(layout, <int>[6, 7]);
      expect(calls, hasLength(1), reason: 'one page in flight');
      held.first.complete(page(calls.first.commitIds));
      await pumpEventQueue();
      expect(content['c-r9'], isNull, reason: 'the superseded page is not cached');
      expect(calls, hasLength(2));
      expect(calls.last.commitIds, <String>['c-r3', 'c-r2'], reason: 'only the last queued load, computed now');
      held.last.complete(page(calls.last.commitIds));
      await pumpEventQueue();
      expect(content['c-r3'], isNotNull);
    });

    test('a failed page logs a warning, caches nothing and is asked again by the next load', () async {
      final records = <LogRecord>[];
      final StreamSubscription<LogRecord> logs = Logger.root.onRecord.listen(records.add);
      addTearDown(logs.cancel);
      final RecordedGraphLayout layout = _chain(10);
      content.load(layout, <int>[0]);
      held.single.completeError(const ZanshinFfiException('jj.io_error'));
      await pumpEventQueue();
      expect(content['c-r9'], isNull);
      expect(
        records.where(
          (r) => r.loggerName == 'zanshin.graph' && r.level == Level.WARNING && r.message.contains('jj.io_error'),
        ),
        hasLength(1),
      );
      content.load(layout, <int>[0]);
      expect(calls, hasLength(2));
      expect(calls.last.commitIds, <String>['c-r9']);
    });

    test('a fetch that throws another error logs it severe and the queued load still asks', () async {
      final records = <LogRecord>[];
      final StreamSubscription<LogRecord> logs = Logger.root.onRecord.listen(records.add);
      addTearDown(logs.cancel);
      final RecordedGraphLayout layout = _chain(10);
      content
        ..load(layout, <int>[0])
        ..load(layout, <int>[4]);
      held.single.completeError(StateError('boom'));
      await pumpEventQueue();
      expect(
        records.where((r) => r.loggerName == 'zanshin.graph' && r.level == Level.SEVERE && r.error is StateError),
        hasLength(1),
      );
      expect(calls, hasLength(2));
      expect(calls.last.commitIds, <String>['c-r5']);
    });

    test('the root is never requested', () {
      final RecordedGraphLayout layout = _chain(3, at: 'r2', root: 2);
      content.load(layout, <int>[0, 1, 2]);
      expect(calls.single.commitIds, <String>['c-r2', 'c-r1']);
    });

    test('a node with inline content is never requested; nothing missing asks nothing', () async {
      final RecordedGraphLayout layout = _chain(
        3,
        at: 'r2',
        contents: const <GraphCommitContent?>[
          GraphCommitContent(subject: 'inline'),
          null,
          null,
        ],
      );
      content.load(layout, <int>[0, 1]);
      expect(calls.single.commitIds, <String>['c-r1']);
      expect(content.of(layout, 0)?.subject, 'inline');
      held.single.complete(page(<String>['c-r1']));
      await pumpEventQueue();
      content.load(layout, <int>[0, 1]);
      await pumpEventQueue();
      expect(calls, hasLength(1));
    });

    test("the card date is the layout's timestamp, else the content's", () async {
      const ts = 1700000000000;
      final RecordedGraphLayout layout = _chain(2, at: 'r1', timestamps: <int?>[null, 5]);
      content.load(layout, <int>[0, 1]);
      held.single.complete(<String, GraphCommitContent>{
        'c-r1': const GraphCommitContent(subject: 's', timestampMs: ts),
        'c-r0': const GraphCommitContent(subject: 's', timestampMs: ts),
      });
      await pumpEventQueue();
      expect(GraphCardData.of(layout, 0, content: content).timestampMs, ts);
      expect(GraphCardData.of(layout, 1, content: content).timestampMs, 5, reason: 'geometry wins');
    });
  });

  group('GraphView pages content', () {
    setUpIconRegistry();
    late ScriptedGraphSource source;
    late GraphViewModel model;
    final noon = DateTime.utc(2026, 10, 30, 12);

    setUp(() {
      source = ScriptedGraphSource(respond: (_) => _chain(200));
    });

    Future<void> pump(
      WidgetTester tester, {
      GraphViewOptions options = const GraphViewOptions(),
      GraphMode mode = GraphMode.free,
    }) async {
      model = GraphViewModel()
        ..init(source, clock: () => noon)
        ..setMode(mode);
      tester.view
        ..physicalSize = surface
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(shellHost(GraphView(model: model, options: options)));
      await tester.pump();
    }

    /// Rests the pointer on [key]'s card body until its peek opens.
    Future<void> peekAt(WidgetTester tester, String key) async {
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(_cardOf(key)));
      await tester.pump();
      await tester.pump(ZsMotion.full.delayPeek);
      await tester.pump();
    }

    GraphCommitContent? peekContent(WidgetTester tester) =>
        tester.widget<GraphPeek>(find.byType(GraphPeek)).data.content;

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(graphContentSettle);
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    }

    testWidgets("after a jump and a rest: one page with exactly the window + buffer's ids at the layout's operation", (
      tester,
    ) async {
      await pump(tester);
      expect(source.contentRequests, isEmpty, reason: 'not before the viewport rested');
      await settle(tester);
      expect(source.contentRequests, hasLength(1));
      expect(source.contentRequests.single.operationId, 'op-1');
      expect(source.contentRequests.single.commitIds.toSet(), _windowIds(tester));
      expect(source.contentRequests.single.commitIds, hasLength(_windowIds(tester).length));

      model.goTo('r5');
      await tester.pump();
      await tester.pump();
      await settle(tester);
      expect(source.contentRequests, hasLength(2));
      final Set<String> window = _windowIds(tester);
      expect(window, contains('c-r5'));
      expect(
        source.contentRequests.last.commitIds.toSet(),
        window.difference(source.contentRequests.first.commitIds.toSet()),
      );
      await finish(tester);
    });

    testWidgets('no page while a canvas pan is held, one after the release and a rest', (tester) async {
      await pump(tester);
      await settle(tester);
      source.contentRequests.clear();
      final RenderGraphViewport render = _viewportOf(tester);
      final Offset spot = <Offset>[
        for (double y = 120; y < 560; y += 7)
          for (double x = 120; x < 620; x += 7) Offset(x, y),
      ].firstWhere((p) => !render.isOnCard(p));
      final TestGesture mouse = await tester.startGesture(spot, kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 10; i++) {
        await mouse.moveBy(const Offset(0, 120));
        await tester.pump();
      }
      for (var i = 0; i < 6; i++) {
        await tester.pump(graphContentSettle);
      }
      expect(source.contentRequests, isEmpty, reason: 'the pan is still held');
      await mouse.up();
      await settle(tester);
      await tester.pump(graphContentSettle);
      expect(source.contentRequests, hasLength(1));
      await finish(tester);
    });

    testWidgets('no page while a fling glides', (tester) async {
      await pump(tester);
      await settle(tester);
      source.contentRequests.clear();
      await tester.flingFrom(const Offset(400, 300), const Offset(0, 300), 2000);
      final RenderGraphViewport render = _viewportOf(tester);
      var frames = 0;
      while (render.verticalOffset is ScrollPosition &&
          (render.verticalOffset as ScrollPosition).isScrollingNotifier.value &&
          frames < 300) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
        expect(source.contentRequests, isEmpty, reason: 'frame $frames of the glide');
      }
      await settle(tester);
      expect(source.contentRequests, hasLength(1));
      await finish(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a reload whose layout has the same commits asks for nothing', (tester) async {
      await pump(tester);
      await settle(tester);
      final GraphLayout before = model.layout!;
      source.emit(const OpHeadsChangedEvent(0, <String>[]));
      await tester.pump();
      await tester.pump();
      expect(model.layout, isNot(same(before)));
      await settle(tester);
      expect(source.contentRequests, hasLength(1));
      await finish(tester);
    });

    testWidgets('a failed page is asked again once a new layout lands (I10: a reload, no timer)', (tester) async {
      source.contentRespond = (_, _) => throw const ZanshinFfiException('jj.operation_not_found', 'gone');
      await pump(tester);
      await settle(tester);
      expect(source.contentRequests, hasLength(1));
      // Nothing asks again on its own.
      for (var i = 0; i < 4; i++) {
        await tester.pump(graphContentSettle);
      }
      expect(source.contentRequests, hasLength(1));
      source
        ..contentRespond = ((_, ids) => <String, GraphCommitContent>{
          for (final String id in ids) id: GraphCommitContent(subject: 'about $id'),
        })
        ..emit(const OpHeadsChangedEvent(0, <String>[]));
      await tester.pump();
      await tester.pump();
      await settle(tester);
      expect(source.contentRequests, hasLength(2));
      expect(source.contentRequests.last.commitIds.toSet(), source.contentRequests.first.commitIds.toSet());
      expect(model.content['c-r100']?.subject, 'about c-r100');
      await finish(tester);
    });

    testWidgets('a reload with new commits on screen asks for exactly those ids', (tester) async {
      await pump(tester);
      await settle(tester);
      source
        ..respond = ((_) => _chain(200, commitPrefix: 'd-'))
        ..emit(const OpHeadsChangedEvent(0, <String>[]));
      await tester.pump();
      await tester.pump();
      await settle(tester);
      expect(source.contentRequests, hasLength(2));
      final Set<String> window = _windowIds(tester);
      expect(window.every((id) => id.startsWith('d-')), isTrue);
      expect(source.contentRequests.last.commitIds.toSet(), window);
      expect(source.contentRequests.last.commitIds, hasLength(window.length));
      await finish(tester);
    });

    testWidgets('a taller viewport, no scroll change: one page with the newly visible ids', (tester) async {
      await pump(tester);
      await settle(tester);
      final Set<String> first = source.contentRequests.single.commitIds.toSet();
      tester.view.physicalSize = Size(surface.width, surface.height * 2);
      await tester.pump();
      await tester.pump();
      await settle(tester);
      expect(source.contentRequests, hasLength(2));
      final Set<String> fresh = _windowIds(tester).difference(first);
      expect(fresh, isNotEmpty);
      expect(source.contentRequests.last.commitIds.toSet(), fresh);
      await finish(tester);
    });

    testWidgets('the peek shows the cached subject', (tester) async {
      await pump(tester);
      await settle(tester);
      await peekAt(tester, 'r100');
      expect(peekContent(tester)?.subject, 'about c-r100');
      await finish(tester);
    });

    testWidgets('a peek opened while the page is held updates when it lands', (tester) async {
      source.holdContent = true;
      await pump(tester);
      await settle(tester);
      await peekAt(tester, 'r100');
      expect(peekContent(tester), isNull);
      source.heldContent.single.complete(<String, GraphCommitContent>{
        for (final String id in source.contentRequests.single.commitIds) id: GraphCommitContent(subject: 'about $id'),
      });
      await tester.pump();
      await tester.pump();
      expect(peekContent(tester)?.subject, 'about c-r100');
      await finish(tester);
    });

    testWidgets('a waiting compact card paints the skeleton bar in its subject slot', (tester) async {
      source.holdContent = true;
      await pump(tester, options: const GraphViewOptions(detailedCards: false));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      final RenderGraphCard r100 = _cards(tester).singleWhere((card) => card.data.key == 'r100');
      expect(r100.cardRect.height, 40, reason: 'a compact card');
      expect(r100.debugSkeletonBar, isNotNull);
      await finish(tester);
    });

    testWidgets('content after 150 ms: a skeleton first, then the subject; no card moves', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      source.holdContent = true;
      await pump(tester);
      await settle(tester);
      expect(source.heldContent, hasLength(1));
      await tester.pump(const Duration(milliseconds: 200));
      final RenderGraphCard r100 = _cards(tester).singleWhere((card) => card.data.key == 'r100');
      final Rect? bar = r100.debugSkeletonBar;
      expect(bar, isNotNull);
      expect(r100, paints..something((method, args) => method == #drawRRect && (args[0] as RRect).outerRect == bar));
      expect(find.bySemanticsLabel(RegExp('about c-r100')), findsNothing);
      final rects = <String, Rect>{
        for (final RenderGraphCard card in _cards(tester)) card.data.key: card.localToGlobal(Offset.zero) & card.size,
      };

      source.heldContent.single.complete(<String, GraphCommitContent>{
        for (final String id in source.contentRequests.single.commitIds) id: GraphCommitContent(subject: 'about $id'),
      });
      await tester.pump();
      await tester.pump();
      expect(r100.debugSkeletonBar, isNull);
      expect(find.bySemanticsLabel(RegExp('about c-r100')), findsOneWidget);
      for (final RenderGraphCard card in _cards(tester)) {
        expect(card.localToGlobal(Offset.zero) & card.size, rects[card.data.key], reason: card.data.key);
      }
      semantics.dispose();
      await finish(tester);
    });

    testWidgets('content within 150 ms: no card ever paints the skeleton', (tester) async {
      await pump(tester);
      for (var t = 0; t < 600; t += 10) {
        await tester.pump(const Duration(milliseconds: 10));
        expect(_cards(tester).where((card) => card.debugSkeletonBar != null), isEmpty, reason: 'at ${t + 10} ms');
      }
      expect(source.contentRequests, hasLength(1));
      await finish(tester);
    });

    testWidgets('a switch to Free while a page is held lands its layout and builds its cards at once', (tester) async {
      source.holdContent = true;
      await pump(tester, mode: GraphMode.compact);
      await settle(tester);
      expect(model.request?.mode, GraphMode.compact);
      expect(source.heldContent, hasLength(1));
      final GraphLayout before = model.layout!;
      model.setMode(GraphMode.free);
      await tester.pump();
      await tester.pump();
      expect(model.layout, isNot(same(before)));
      expect(model.request?.mode, GraphMode.free);
      final GraphCanvas canvas = tester.widget<GraphCanvas>(find.byType(GraphCanvas));
      expect(canvas.layout, same(model.layout));
      expect(_cardOf('r100'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is GraphCard && identical(w.layout, model.layout), skipOffstage: false),
        findsWidgets,
      );
      await finish(tester);
    });
  });
}
