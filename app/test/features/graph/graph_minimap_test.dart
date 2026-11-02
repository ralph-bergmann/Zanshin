// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/day_axis.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_minimap.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/minimap_raster.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

const _dayMs = 86400000;
final _noon = DateTime.utc(2026, 10, 30, 12);
final int _today = DateTime.utc(2026, 10, 30).millisecondsSinceEpoch;

/// A compact chain of [rows] commits, one a day back from today, spread over six columns, @ at `r100`.
RecordedGraphLayout _chain(int rows) {
  final nodes = <(String, int, int)>[for (int row = rows - 1; row >= 0; row--) ('r$row', row, row % 6)];
  return handLayout(
    nodes,
    edges: <(int, int)>[for (var i = 0; i + 1 < nodes.length; i++) (i, i + 1)],
    workingCopy: nodes.indexWhere((node) => node.$1 == 'r100'),
    timestamps: <int?>[for (final (_, int row, _) in nodes) _today + 10 * 3600000 - (rows - 1 - row) * _dayMs],
  );
}

class _Recorder extends ShellController {
  final reported = <double>[];

  @override
  void reportUserScroll(double amount) {
    reported.add(amount);
    super.reportUserScroll(amount);
  }
}

void main() {
  setUpIconRegistry();

  group('labels and the day lookup', () {
    final AppLocalizations strings = platformStrings();
    String day(int ms) => graphDayLabel(strings, ms, nowMs: _noon.millisecondsSinceEpoch, utcOffsetMinutes: 0);

    test('Free: one label per day bucket at its label y; the pill day changes where a label passes the centre', () {
      final GraphLayout layout = handLayout(
        <(String, int, int)>[('a', 32, 0), ('b', 16, 0), ('c', 0, 0)],
        edges: <(int, int)>[(0, 1), (1, 2)],
        unit: 16,
        buckets: <(int, int, int)>[(_today - 5 * _dayMs, 0, 0), (_today - _dayMs, 16, 16), (_today, 32, 32)],
      );
      final rows = UniformRows(layout, GraphMetrics());
      final axis = GraphDayAxis.of(layout, rows);
      final MinimapLabels labels = minimapLabels(
        layout,
        rows,
        strings: strings,
        nowMs: _noon.millisecondsSinceEpoch,
      );
      expect(labels.free, isTrue);
      expect(labels.texts, <String>[strings.dayToday, strings.dayYesterday, day(_today - 5 * _dayMs)]);
      expect(labels.ys, <double>[axis.labelYs[2], axis.labelYs[1], axis.labelYs[0]]);

      final double yesterday = labels.ys[1];
      expect(minimapDayAt(labels, labels.ys[0] - 100), strings.dayToday);
      expect(minimapDayAt(labels, yesterday + 1), strings.dayYesterday);
      expect(minimapDayAt(labels, yesterday + 1.01), day(_today - 5 * _dayMs));
      expect(minimapDayAt(labels, labels.ys[2] + 500), day(_today - 5 * _dayMs), reason: 'below the last: the last');
    });

    test('Compact: a label only where a row is older than the last label; the root and a ts-less node give none', () {
      final int ten = _today + 10 * 3600000;
      final GraphLayout layout = handLayout(
        <(String, int, int)>[('a', 4, 0), ('b', 3, 0), ('c', 3, 1), ('d', 2, 0), ('e', 1, 0), ('root', 0, 0)],
        edges: <(int, int)>[(0, 1), (0, 2), (1, 3), (2, 3), (3, 4), (4, 5)],
        root: 5,
        timestamps: <int?>[ten, ten - _dayMs, ten, null, ten - _dayMs, ten - 3 * _dayMs],
      );
      final metrics = GraphMetrics();
      final rows = UniformRows(layout, metrics);
      final MinimapLabels labels = minimapLabels(
        layout,
        rows,
        strings: strings,
        nowMs: _noon.millisecondsSinceEpoch,
      );
      expect(labels.free, isFalse);
      expect(labels.texts, <String>[strings.dayToday, strings.dayYesterday]);
      expect(labels.ys, <double>[rows.topOfRow(4) + metrics.cardHeight / 2, rows.topOfRow(1) + metrics.cardHeight / 2]);

      expect(minimapDayAt(labels, labels.ys[0] - 50), strings.dayToday, reason: 'above the first: the first');
      expect(minimapDayAt(labels, labels.ys[1] - 1.01), strings.dayToday);
      expect(minimapDayAt(labels, labels.ys[1] - 1), strings.dayYesterday);
      expect(minimapDayAt(MinimapLabels.empty, 0), isNull);
    });
  });

  group('GraphMinimap in the shell', () {
    late ScriptedGraphSource source;
    late GraphViewModel model;
    late _Recorder shell;
    var runs = 0;
    var hold = false;
    final held = <(MinimapRasterInput, Completer<Uint8List>)>[];

    Future<Uint8List> runner(MinimapRasterInput input) async {
      runs++;
      if (hold) {
        final completer = Completer<Uint8List>();
        held.add((input, completer));
        return completer.future;
      }
      return rasterMinimap(input);
    }

    Widget host({bool graph = true}) => shellHost(
      ListenableBuilder(
        listenable: model,
        builder: (context, _) => FloatingShell(
          controller: shell,
          graph: graph ? GraphView(model: model) : null,
          minimap: GraphMinimap(model: model, runRaster: runner),
        ),
      ),
    );

    Future<void> pump(WidgetTester tester) async {
      runs = 0;
      held.clear();
      useShellWindow(tester);
      source = ScriptedGraphSource(respond: (_) => _chain(200));
      model = GraphViewModel()..init(source, clock: () => _noon);
      shell = _Recorder();
      await tester.pumpWidget(host());
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      // The calm timers of the reports.
      await tester.pump(const Duration(seconds: 2));
      model.dispose();
      shell.dispose();
    }

    Rect strip(WidgetTester tester) => minimapStripInset.deflateRect(tester.getRect(find.byType(GraphMinimap)));

    /// The vertical offset a press at strip y [sy] jumps to (graph-view.jsx:505-508).
    double jumpTarget(WidgetTester tester, double sy) {
      final GraphMinimapFrame frame = model.minimapSource.frame!;
      final EdgeInsets insets = frame.insets;
      final double k = strip(tester).height / (frame.rows.contentHeight + insets.top + insets.bottom);
      final ScrollPosition position = frame.vertical.position;
      return (sy / k - (insets.top + (position.viewportDimension - insets.top - insets.bottom) / 2)).clamp(
        0,
        position.maxScrollExtent,
      );
    }

    testWidgets(
      'the card sits at right 12 from the chrome top to 12 above the bottom; the canvas publishes its frame',
      (
        tester,
      ) async {
        await pump(tester);
        final Rect card = tester.getRect(find.byType(GraphMinimap));
        const ZsMetrics metrics = ZsMetrics.standard;
        expect(card, Rect.fromLTRB(1440 - 12 - 134, metrics.chromeTop, 1440 - 12, 900 - 12));
        expect(strip(tester).width, minimapStripWidth);
        final GraphMinimapFrame frame = model.minimapSource.frame!;
        expect(frame.layout, same(model.layout));
        expect(frame.geometry, isNotNull);
        expect(runs, 1);
        await finish(tester);
      },
    );

    testWidgets('a press and a drag jump vertically only, select nothing and feed calm scrolling', (tester) async {
      await pump(tester);
      final GraphMinimapFrame frame = model.minimapSource.frame!;
      final double horizontal = frame.horizontal.offset;
      final String? selected = model.selected;
      final Rect s = strip(tester);

      final TestGesture gesture = await tester.startGesture(
        s.topLeft + const Offset(80, 120),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(frame.vertical.offset, closeTo(jumpTarget(tester, 120), 1e-6));
      expect(shell.reported, <double>[40]);
      await gesture.moveTo(s.topLeft + const Offset(80, 500));
      await tester.pump();
      expect(frame.vertical.offset, closeTo(jumpTarget(tester, 500), 1e-6));
      expect(shell.reported, <double>[40, 40]);
      await gesture.moveTo(s.topLeft + const Offset(80, 100000));
      await tester.pump();
      expect(frame.vertical.offset, frame.vertical.position.maxScrollExtent, reason: 'clamped');
      await gesture.up();
      await tester.pump();
      expect(frame.horizontal.offset, horizontal);
      expect(model.selected, selected);
      await finish(tester);
    });

    testWidgets('the wheel over the strip scrolls both axes by its delta and reports it', (tester) async {
      await pump(tester);
      final GraphMinimapFrame frame = model.minimapSource.frame!;
      frame.horizontal.jumpTo(0);
      final v0 = Offset(frame.horizontal.offset, frame.vertical.offset);
      final pointer = TestPointer(9, PointerDeviceKind.mouse, 9);
      await tester.sendEventToBinding(pointer.hover(strip(tester).center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(30, 50)));
      await tester.pump();
      expect(Offset(frame.horizontal.offset, frame.vertical.offset), v0 + const Offset(30, 50));
      expect(shell.reported.last, 80);
      await tester.sendEventToBinding(pointer.removePointer());
      await finish(tester);
    });

    testWidgets('scrolling and a selection change never re-raster; a strip resize re-rasters once', (tester) async {
      await pump(tester);
      final GraphMinimapFrame frame = model.minimapSource.frame!;
      expect(runs, 1);
      for (var i = 0; i < 240; i++) {
        frame.vertical.jumpTo(frame.vertical.offset + 3);
        await tester.pump();
      }
      expect(runs, 1, reason: 'a 240-frame scroll rasters nothing');

      model.select('r120');
      await tester.pump();
      await tester.pump();
      expect(runs, 1, reason: 'the selection is overlay only');

      tester.view.physicalSize = const Size(1440, 800);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(runs, 2);
      await finish(tester);
    });

    testWidgets('a key change while a raster runs: the stale result is dropped, the latest key rasters once after it', (
      tester,
    ) async {
      hold = true;
      addTearDown(() => hold = false);
      await pump(tester);
      expect(held, hasLength(1));
      final int first = held.single.$1.height;

      tester.view.physicalSize = const Size(1440, 800);
      await tester.pump();
      tester.view.physicalSize = const Size(1440, 700);
      await tester.pump();
      expect(runs, 1, reason: 'one raster in flight');

      held.single.$2.complete(rasterMinimap(held.single.$1));
      await tester.pump();
      expect(runs, 2, reason: 'the two resizes coalesce into one raster');
      expect(held.last.$1.height, lessThan(first));
      expect(held.last.$1.height, (strip(tester).height * tester.view.devicePixelRatio).round(), reason: 'the latest');

      tester.view.physicalSize = const Size(1440, 600);
      await tester.pump();
      expect(runs, 2);
      held.last.$2.completeError(StateError('boom'));
      await tester.pump();
      expect(tester.takeException(), isA<StateError>(), reason: 'a failed raster is reported');
      expect(runs, 3, reason: 'a key requested while the failed raster ran still rasters');
      held.last.$2.completeError(StateError('boom again'));
      await tester.pump();
      expect(tester.takeException(), isA<StateError>());
      expect(runs, 3, reason: 'a failed key is not retried');
      await finish(tester);
    });

    testWidgets('the canvas going away retracts its frame; the minimap shows an empty card', (tester) async {
      await pump(tester);
      expect(model.minimapSource.frame, isNotNull);
      await tester.pumpWidget(host(graph: false));
      await tester.pump();
      expect(model.minimapSource.frame, isNull);
      expect(find.byType(GraphMinimap), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('the overlay paints the band, the selection and @ dots and the connector at the mapped places', (
      tester,
    ) async {
      await pump(tester);
      model.select('r120');
      final GraphMinimapFrame frame = model.minimapSource.frame!;
      frame.vertical.jumpTo(frame.vertical.position.maxScrollExtent / 3);
      await tester.pump();

      final Rect s = strip(tester);
      final EdgeInsets insets = frame.insets;
      final double k = s.height / (frame.rows.contentHeight + insets.top + insets.bottom);
      final GraphLayout layout = frame.layout;
      final GraphMetrics metrics = frame.metrics;
      double cx(int node) => metrics.x(layout.colOf(node)) + metrics.cardWidth / 2;
      final xs = <double>[for (var n = 0; n < layout.nodeCount; n++) cx(n)];
      final double x0 = xs.reduce(math.min);
      final double x1 = xs.reduce(math.max);
      final double kx = math.min(48 / (x1 - x0), 0.04);
      Offset at(String key) {
        final int node = layout.indexOfKey(key)!;
        return Offset(114 - (x1 - cx(node)) * kx, (frame.rows.top(node) + metrics.cardHeight / 2 + insets.top) * k);
      }

      final ScrollPosition position = frame.vertical.position;
      final double vTop = (position.pixels + insets.top) * k;
      final double vBot = (position.pixels + position.viewportDimension - insets.bottom) * k;
      final ZsColors colors = ZsColors.of(tester.element(find.byType(GraphMinimap)));
      final RenderObject paint = tester.renderObject(
        find.descendant(of: find.byType(GraphMinimap), matching: find.byType(CustomPaint)).first,
      );
      expect(
        paint,
        paints
          ..rrect(
            rrect: RRect.fromRectAndRadius(Rect.fromLTWH(60, vTop, 62, vBot - vTop), const Radius.circular(4)),
            color: colors.flHover,
          )
          ..circle(x: at('r120').dx, y: at('r120').dy, radius: 3.2, color: colors.accentLine)
          ..circle(x: at('r100').dx, y: at('r100').dy, radius: 3.2, color: colors.co)
          ..line(p1: Offset(minimapSplit, (vTop + vBot) / 2), p2: Offset(minimapStripWidth, (vTop + vBot) / 2)),
      );
      await finish(tester);
    });

    testWidgets('the glass fades only through ZsFade, with no Opacity or FadeTransition above it', (tester) async {
      await pump(tester);
      final Finder glass = find.descendant(of: find.byType(GraphMinimap), matching: find.byType(ZsGlass));
      expect(glass, findsOneWidget);
      expect(find.ancestor(of: glass, matching: find.byType(ZsFade)), findsWidgets);
      expect(find.ancestor(of: glass, matching: find.byType(Opacity)), findsNothing);
      expect(find.ancestor(of: glass, matching: find.byType(FadeTransition)), findsNothing);
      await finish(tester);
    });

    testWidgets('VoiceOver reads one node "Minimap"', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pump(tester);
      expect(find.bySemanticsLabel('Minimap'), findsOneWidget);
      await finish(tester);
      semantics.dispose();
    });

    testWidgets('a minimap without a canvas shows an empty card and rasters nothing', (tester) async {
      useShellWindow(tester);
      final empty = GraphViewModel();
      addTearDown(empty.dispose);
      runs = 0;
      await tester.pumpWidget(shellHost(GraphView.minimap(empty)));
      await tester.pump();
      expect(find.byType(GraphMinimap), findsOneWidget);
      expect(runs, 0);
      expect(empty.minimapSource.frame, isNull);
    });
  });
}
