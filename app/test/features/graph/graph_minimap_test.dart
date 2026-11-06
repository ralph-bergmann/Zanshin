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

/// A Free chain of 30 days, one card each two pitches apart (Story 10.31): Dec 20–29 2023, Jan 1–10 2024, a break,
/// then Jun 1–10 of [lastYear]. With [lastYear] 2026 and [oneYear] every day lies in 2026 (Mar 1–30) and there is no
/// break.
GraphLayout _history({int lastYear = 2025, bool oneYear = false}) {
  int dayOf(int k) => oneYear
      ? DateTime.utc(2026, 3, 1 + k).millisecondsSinceEpoch
      : k < 10
      ? DateTime.utc(2023, 12, 20 + k).millisecondsSinceEpoch
      : k < 20
      ? DateTime.utc(2024, 1, k - 9).millisecondsSinceEpoch
      : DateTime.utc(lastYear, 6, k - 19).millisecondsSinceEpoch;
  int rowOf(int k) => oneYear || k < 20 ? 32 * k : 32 * 19 + 24 + 32 * (k - 20);
  const n = 30;
  final RecordedGraphLayout inner = handLayout(
    <(String, int, int)>[for (int k = n - 1; k >= 0; k--) ('h$k', rowOf(k), k % 3)],
    edges: <(int, int)>[for (var i = 0; i + 1 < n; i++) (i, i + 1)],
    unit: 16,
    timestamps: <int?>[for (int k = n - 1; k >= 0; k--) dayOf(k) + 12 * 3600000],
    buckets: <(int, int, int)>[for (var k = 0; k < n; k++) (dayOf(k), rowOf(k), rowOf(k))],
  );
  return oneYear
      ? inner
      : BrokenLayout(inner, <GraphBreak>[
          GraphBreak(lowerRow: rowOf(19), upperRow: rowOf(20), t0: dayOf(19), t1: dayOf(20)),
        ]);
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

    test(
      'Free: the year boundaries top-down, the breaks\' centres; Compact: a boundary between two labels\' years',
      () {
        int at(int y, int m, int d) => DateTime.utc(y, m, d).millisecondsSinceEpoch;
        final GraphLayout free = BrokenLayout(
          handLayout(
            const <(String, int, int)>[('c', 64, 0), ('b', 40, 0), ('a', 16, 0)],
            unit: 16,
            timestamps: <int?>[at(2025, 5, 2), at(2023, 3, 1), at(2023, 2, 1)],
            buckets: <(int, int, int)>[(at(2023, 2, 1), 16, 16), (at(2023, 3, 1), 40, 40), (at(2025, 5, 2), 64, 64)],
          ),
          <GraphBreak>[GraphBreak(lowerRow: 40, upperRow: 64, t0: at(2023, 3, 1), t1: at(2025, 5, 2))],
        );
        final rows = UniformRows(free, GraphMetrics());
        final MinimapLabels labels = minimapLabels(free, rows, strings: strings, nowMs: _noon.millisecondsSinceEpoch);
        final axis = GraphDayAxis.of(free, rows);
        expect(labels.nowYear, 2026);
        expect(labels.years.map((y) => (y.year, y.below)), <(int, int?)>[(2025, 2023), (2023, null)]);
        expect(labels.years.first.y, lessThan(labels.years.last.y), reason: 'ascending y');
        expect(labels.breaks, <double>[axis.breaks.single.centre]);
        expect(labels.yearTexts, <int, String>{2025: '2025', 2023: '2023'});
        // May 2's divider lies in the break: never drawn, but the lookup still names it for its card right above.
        final int may2 = labels.texts.indexOf(day(at(2025, 5, 2)));
        expect(may2, isNonNegative);
        expect(labels.silent, <int>{may2});
        final double card = rows.top(free.indexOfKey('c')!) + GraphMetrics().cardHeight / 2;
        expect(minimapDayAt(labels, card), day(at(2025, 5, 2)));
        expect(minimapDayAt(labels, axis.breaks.single.bottom + 1), day(at(2023, 3, 1)), reason: 'below the break');

        final GraphLayout compact = handLayout(
          const <(String, int, int)>[('c', 2, 0), ('b', 1, 0), ('a', 0, 0)],
          edges: const <(int, int)>[(0, 1), (1, 2)],
          timestamps: <int?>[at(2024, 1, 2), at(2023, 12, 30), at(2023, 12, 29)],
        );
        final compactRows = UniformRows(compact, GraphMetrics());
        final MinimapLabels c = minimapLabels(
          compact,
          compactRows,
          strings: strings,
          nowMs: _noon.millisecondsSinceEpoch,
        );
        expect(c.years.map((y) => (y.year, y.below)), <(int, int?)>[(2024, 2023), (2023, null)]);
        expect(c.years.first.y, (c.ys[0] + c.ys[1]) / 2);
        expect(c.breaks, isEmpty);
      },
    );

    test('the source\'s card width follows a published frame and returns to 134 after a retract', () async {
      final GraphLayout layout = _chain(30);
      final metrics = GraphMetrics();
      final vertical = ScrollController();
      addTearDown(vertical.dispose);
      final source = GraphMinimapSource();
      addTearDown(source.dispose);
      expect(source.cardWidth.value, 134);
      source.publish(
        GraphMinimapFrame(
          layout: layout,
          rows: UniformRows(layout, metrics),
          metrics: metrics,
          geometry: null,
          insets: EdgeInsets.zero,
          vertical: vertical,
          horizontal: vertical,
        ),
      );
      final (double x0, double x1) = source.extent;
      expect(source.cardWidth.value, MinimapSize.of(x1 - x0).card);
      expect(source.cardWidth.value, greaterThan(134));
      source.retract(vertical);
      await Future<void>.delayed(Duration.zero);
      expect(source.frame, isNull);
      expect(source.cardWidth.value, 134);
    });

    test('the size: graph part clamp(span · 0.04 + 16, 60, 160), strip 58 + it, card + 16, kx at most 0.04', () {
      expect(MinimapSize.of(0).card, 134, reason: 'the token without a graph');
      expect(MinimapSize.of(0).kx, 0);
      final mid = MinimapSize.of(2000);
      expect(mid.graph, 96);
      expect(mid.strip, 154);
      expect(mid.card, 170);
      expect(mid.kx, .04);
      final wide = MinimapSize.of(10000);
      expect(wide.graph, 160);
      expect(wide.card, 234);
      expect(wide.kx, closeTo(144 / 10000, 1e-12), reason: 'squeezed once the graph part is full');
      expect(MinimapSize.of(100).graph, 60);
      expect(MinimapSize.of(100).kx, .04);
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

    MinimapRasterInput? lastInput;

    Future<Uint8List> runner(MinimapRasterInput input) async {
      runs++;
      lastInput = input;
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
          minimapWidth: model.minimapSource.cardWidth,
        ),
      ),
    );

    Future<void> pump(WidgetTester tester, {int rows = 200, GraphLayout Function()? layout}) async {
      runs = 0;
      held.clear();
      useShellWindow(tester);
      source = ScriptedGraphSource(respond: (_) => layout?.call() ?? _chain(rows));
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
      'the card sits at right 12 from the chrome top to 12 above the bottom, as wide as the columns ask; the canvas '
      'publishes its frame',
      (
        tester,
      ) async {
        await pump(tester);
        await tester.pumpAndSettle();
        final GraphMinimapFrame frame = model.minimapSource.frame!;
        final (double x0, double x1) = model.minimapSource.extent;
        final double card = MinimapSize.of(x1 - x0).card;
        expect(model.minimapSource.cardWidth.value, card);
        expect(card, greaterThan(134), reason: 'six columns widen the graph part');
        const ZsMetrics metrics = ZsMetrics.standard;
        final Rect rect = tester.getRect(find.byType(GraphMinimap));
        expect(rect.left, closeTo(1440 - 12 - card, 1e-9));
        expect(rect.right, 1440 - 12);
        expect(rect.top, metrics.chromeTop);
        expect(rect.bottom, 900 - 12);
        expect(strip(tester).width, closeTo(MinimapSize.of(x1 - x0).strip, 1e-9));
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
      final double gw = ((x1 - x0) * .04 + 16).clamp(60, 160);
      final double w = 58 + gw;
      final double kx = math.min(.04, (gw - 16) / (x1 - x0));
      Offset at(String key) {
        final int node = layout.indexOfKey(key)!;
        return Offset(w - 4 - (x1 - cx(node)) * kx, (frame.rows.top(node) + metrics.cardHeight / 2 + insets.top) * k);
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
            rrect: RRect.fromRectAndRadius(Rect.fromLTWH(60, vTop, w - 58 + 2, vBot - vTop), const Radius.circular(4)),
            color: colors.flHover,
          )
          ..circle(x: at('r120').dx, y: at('r120').dy, radius: 3.2, color: colors.accentLine)
          ..circle(x: at('r100').dx, y: at('r100').dy, radius: 3.2, color: colors.co)
          ..line(p1: Offset(minimapSplit, (vTop + vBot) / 2), p2: Offset(w, (vTop + vBot) / 2)),
      );
      await finish(tester);
    });

    testWidgets(
      'a history taller than the strip at 2 px a pitch: the minimap scrolls in proportion, the band stays inside, '
      'a press centres the band on it, a node sits at my(y) − ms, the raster covers a window (Story 10.31)',
      (tester) async {
        await pump(tester, rows: 2000);
        final GraphMinimapFrame frame = model.minimapSource.frame!;
        final Rect s = strip(tester);
        final mapping = MinimapMapping.of(frame, s.height, model.minimapSource.extent);
        final double pitch = frame.metrics.cardHeight + frame.metrics.gapY;
        expect(mapping.k, closeTo(minimapMinPitch / pitch, 1e-9), reason: 'the least density');
        expect(mapping.over, greaterThan(2 * s.height));
        expect(runs, 1);
        expect(lastInput!.height, (3 * s.height * tester.view.devicePixelRatio).round(), reason: 'three strip heights');

        final ScrollPosition position = frame.vertical.position;
        final EdgeInsets insets = frame.insets;
        for (final f in <double>[0, .5, 1]) {
          frame.vertical.jumpTo(position.maxScrollExtent * f);
          await tester.pump();
          await tester.pump();
          final double ms = mapping.msOf(position);
          expect(ms, closeTo(mapping.over * f, 1e-6));
          final double vTop = (position.pixels + insets.top) * mapping.k - ms;
          final double vBot = (position.pixels + position.viewportDimension - insets.bottom) * mapping.k - ms;
          expect(vTop, greaterThanOrEqualTo(-1e-6), reason: 'at $f');
          expect(vBot, lessThanOrEqualTo(s.height + 1e-6), reason: 'at $f');
        }
        expect(runs, greaterThan(1), reason: 'leaving the window re-rasters');

        // A press at strip y 300 lands the band's centre there.
        await tester.tapAt(s.topLeft + const Offset(80, 300), kind: PointerDeviceKind.mouse);
        await tester.pump();
        final double ms = mapping.msOf(position);
        final double c0 = insets.top + (position.viewportDimension - insets.top - insets.bottom) / 2;
        expect((position.pixels + c0) * mapping.k - ms, closeTo(300, 1e-6));
        expect(
          position.pixels,
          minimapJumpTarget(
            mapping,
            300,
            viewport: position.viewportDimension,
            maxScrollExtent: position.maxScrollExtent,
            insets: insets,
          ),
        );

        // @ (r100) paints at my(top + H/2) − ms.
        final GraphLayout layout = frame.layout;
        final int at = layout.indexOfKey('r100')!;
        frame.vertical.jumpTo(position.maxScrollExtent);
        await tester.pump();
        final double atY = mapping.my(frame.rows.top(at) + frame.metrics.cardHeight / 2) - mapping.over;
        final RenderObject paint = tester.renderObject(
          find.descendant(of: find.byType(GraphMinimap), matching: find.byType(CustomPaint)).first,
        );
        expect(paint, paints..circle(y: atY, radius: 3.2));
        await finish(tester);
      },
    );

    /// The draw calls of [finder]'s render object: (method, arguments).
    List<(Symbol, List<dynamic>)> calls(WidgetTester tester, Finder finder) {
      final out = <(Symbol, List<dynamic>)>[];
      expect(
        tester.renderObject(finder),
        paints..everything((method, arguments) {
          out.add((method, arguments));
          return true;
        }),
      );
      return out;
    }

    Finder overlay() => find.descendant(of: find.byType(GraphMinimap), matching: find.byType(CustomPaint)).first;

    testWidgets('the canvas paints a break\'s strip: its fill, then its two torn edges (Story 10.31)', (tester) async {
      await pump(tester, layout: _history);
      await tester.pumpAndSettle();
      final GraphMinimapFrame frame = model.minimapSource.frame!;
      final axis = GraphDayAxis.of(frame.layout, frame.rows);
      frame.vertical.jumpTo(math.max(0, axis.breaks.single.centre - 300));
      await tester.pump();
      final ZsColors colors = ZsColors.of(tester.element(find.byType(GraphView)));
      final paths = <(int, PaintingStyle)>[
        for (final (Symbol method, List<dynamic> args) in calls(tester, find.byType(GraphView)))
          if (method == #drawPath) ((args[1] as Paint).color.toARGB32(), (args[1] as Paint).style),
      ];
      final int fill = colors.flBgSolid.withValues(alpha: colors.flBgSolid.a * .92).toARGB32();
      final int at = paths.indexOf((fill, PaintingStyle.fill));
      expect(at, isNonNegative, reason: 'the strip\'s fill');
      expect(paths.sublist(at + 1, at + 3), <(int, PaintingStyle)>[
        (colors.borderStrong.toARGB32(), PaintingStyle.stroke),
        (colors.borderStrong.toARGB32(), PaintingStyle.stroke),
      ]);
      await finish(tester);
    });

    testWidgets(
      'the minimap over years and a break: the zigzag, the year heading its section, the sticky top year, no day '
      'label beside a year (Story 10.31)',
      (tester) async {
        await pump(tester, layout: _history);
        await tester.pumpAndSettle();
        final GraphMinimapFrame frame = model.minimapSource.frame!;
        final ZsColors colors = ZsColors.of(tester.element(find.byType(GraphMinimap)));
        final Rect s = strip(tester);
        final mapping = MinimapMapping.of(frame, s.height, model.minimapSource.extent);
        expect(mapping.over, 0);
        final MinimapLabels labels = minimapLabels(
          frame.layout,
          frame.rows,
          strings: platformStrings(),
          nowMs: _noon.millisecondsSinceEpoch,
        );
        double width(String text, TextStyle style) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: TextDirection.ltr,
          )..layout();
          addTearDown(painter.dispose);
          return painter.width;
        }

        final List<(Symbol, List<dynamic>)> drawn = calls(tester, overlay());
        final paragraphs = <Offset>[
          for (final (Symbol method, List<dynamic> args) in drawn)
            if (method == #drawParagraph) args[1] as Offset,
        ];
        expect(
          drawn.where(
            (c) => c.$1 == #drawPath && (c.$2[1] as Paint).color.toARGB32() == colors.textDim.toARGB32(),
          ),
          hasLength(1),
          reason: 'the break\'s zigzag',
        );
        // "2023" heads the section under the 2024 boundary: its text top 3 px below the boundary.
        final MinimapYear boundary = labels.years.firstWhere((y) => y.below == 2023);
        final double sy = mapping.my(boundary.y);
        final double w2023 = width('2023', graphYearStyle(colors));
        expect(paragraphs, contains(Offset(minimapSplit - 4 - w2023, sy + 3)));
        // The sticky header: the top section's year, 2025, not this year.
        final double w2025 = width('2025', graphYearStyle(colors));
        expect(paragraphs, contains(Offset(minimapSplit - 4 - w2025, 3)));
        expect(drawn.where((c) => c.$1 == #drawRect), hasLength(1), reason: 'the header\'s fade');
        // The day at the boundary (Jan 1) is not drawn beside the year.
        final TextStyle labelStyle = ZsType.id.copyWith(fontSize: ZsType.fsXs);
        final int jan1 = labels.texts.indexOf('Jan 1');
        final labelPainter = TextPainter(
          text: TextSpan(text: 'Jan 1', style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        addTearDown(labelPainter.dispose);
        final double ly = mapping.my(labels.ys[jan1]);
        expect((ly - sy).abs(), lessThan(16));
        expect(
          paragraphs,
          isNot(contains(Offset(minimapSplit - 4 - labelPainter.width, ly - labelPainter.height / 2))),
        );
        await finish(tester);
      },
    );

    testWidgets('a history that lies in this year alone gets no sticky header', (tester) async {
      await pump(tester, layout: () => _history(oneYear: true));
      await tester.pumpAndSettle();
      expect(calls(tester, overlay()).where((c) => c.$1 == #drawRect), isEmpty);
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
