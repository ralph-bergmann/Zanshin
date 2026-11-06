// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_edges.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_minimap.dart';
import 'package:zanshin/src/features/graph/minimap_raster.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';
import 'package:zanshin_core/zanshin_core.dart' show RouteGeometry;

import 'graph_harness.dart';

const _faint = 0xFF808080;
const _text = 0xFFFFFFFF;
const _muted = 0xFFC0C0C0;
const _w = 20;
const _h = 40;

/// A pixel of [layer] (0 out, 1 in) as (r, g, b, a).
(int, int, int, int) _px(Uint8List bytes, int layer, int x, int y) {
  final int o = layer * _w * _h * 4 + 4 * (y * _w + x);
  return (bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]);
}

int _alpha(Uint8List bytes, int x, int y) => _px(bytes, 0, x, y).$4;

void main() {
  test('a hand-made raster: discs and a hollow ring at the mapped centres, edge dots on one 3 px grid, two layers', () {
    final input = MinimapRasterInput(
      nodeXs: Float64List.fromList(<double>[5, 5, 12]),
      nodeYs: Float64List.fromList(<double>[5, 20, 30]),
      nodeStacks: Uint8List.fromList(<int>[0, 0, 1]),
      // An edge straight down, and one with two bends that starts 1 px lower on the same x: where they run together
      // their dots must coincide (design sync #22).
      edgeStarts: Int32List.fromList(<int>[0, 2, 6]),
      edgePoints: Float64List.fromList(<double>[5, 7, 5, 18, 5, 8, 5, 26, 12, 26, 12, 28]),
      ax: 0,
      bx: 1,
      ay: 0,
      by: 1,
      dpr: 1,
      width: _w,
      height: _h,
      outNode: _faint,
      outEdge: _faint,
      inNode: _text,
      inEdge: _muted,
    );
    final Uint8List bytes = rasterMinimap(input);
    expect(bytes, hasLength(2 * _w * _h * 4));

    // A disc's centre: full coverage, the out layer in --text-faint, the in layer in --text.
    expect(_px(bytes, 0, 4, 4), (128, 128, 128, 255));
    expect(_px(bytes, 1, 4, 4), (255, 255, 255, 255));
    expect(_px(bytes, 0, 4, 19), (128, 128, 128, 255));
    expect(_alpha(bytes, 9, 4), 0, reason: 'nothing beside the disc');

    // The stack's ring: hollow at its centre, solid on its stroke.
    expect(_alpha(bytes, 11, 29), 0);
    expect(_alpha(bytes, 14, 29), 255);

    // Both lines dot at y 9, 12, 15 (the multiples of 3), so pixel rows 10 and 13 stay clear — a dot of the second
    // line at 8, 11, 14 would cover them.
    expect(_alpha(bytes, 4, 9), greaterThan(0));
    expect(_alpha(bytes, 4, 11), greaterThan(0));
    expect(_alpha(bytes, 4, 10), 0);
    expect(_alpha(bytes, 4, 13), 0);
    // The in layer draws edges in --text-muted.
    final (int r, _, _, int a) = _px(bytes, 1, 4, 9);
    expect(r / a, closeTo(0xC0 / 255, .01));

    // The horizontal stretch at y 26 dots at x 6, 9, 12: none at x 7.
    expect(_alpha(bytes, 5, 25), greaterThan(0));
    expect(_alpha(bytes, 7, 25), 0);
    expect(_alpha(bytes, 8, 25), greaterThan(0));
  });

  test('a raster window: nodes and edge dots off the raster are not stamped, those on it are (Story 10.31)', () {
    // One edge running from far above the raster to far below it, and two nodes outside it.
    final input = MinimapRasterInput(
      nodeXs: Float64List.fromList(<double>[5, 5, 12]),
      nodeYs: Float64List.fromList(<double>[-500, 20, 900]),
      nodeStacks: Uint8List.fromList(<int>[0, 0, 1]),
      edgeStarts: Int32List.fromList(<int>[0, 2]),
      edgePoints: Float64List.fromList(<double>[15, -100000, 15, 100000]),
      ax: 0,
      bx: 1,
      ay: 0,
      by: 1,
      dpr: 1,
      width: _w,
      height: _h,
      outNode: _faint,
      outEdge: _faint,
      inNode: _text,
      inEdge: _muted,
    );
    final Uint8List bytes = rasterMinimap(input);
    expect(_alpha(bytes, 4, 19), 255, reason: 'the node inside');
    expect(_alpha(bytes, 14, 0), greaterThan(0), reason: 'the edge dots at the top row');
    expect(_alpha(bytes, 14, _h - 1), greaterThan(0), reason: 'and at the bottom row');
    expect(_alpha(bytes, 14, 1), 0, reason: 'still on the shared 3 px grid');
  });

  test('a window\'s input maps the content window onto the raster: ay shifts by the window top', () {
    final GraphLayout layout = handLayout(<(String, int, int)>[('a', 1, 0), ('b', 0, 0)], edges: <(int, int)>[(0, 1)]);
    final metrics = GraphMetrics();
    final vertical = ScrollController();
    addTearDown(vertical.dispose);
    final frame = GraphMinimapFrame(
      layout: layout,
      rows: UniformRows(layout, metrics),
      metrics: metrics,
      geometry: null,
      insets: const EdgeInsets.only(top: 60),
      vertical: vertical,
      horizontal: vertical,
    );
    MinimapRasterInput input({double top = 0, double? height}) => minimapRasterInput(
      frame,
      100,
      2,
      faint: _faint,
      text: _text,
      muted: _muted,
      windowTop: top,
      windowHeight: height,
    );
    final MinimapRasterInput whole = input();
    final MinimapRasterInput window = input(top: 40, height: 250);
    expect(window.ay, whole.ay - 2 * 40);
    expect(window.by, whole.by);
    expect(window.height, 500);
    expect(whole.height, 200);
    expect(whole.width, (MinimapSize.of(0).strip * 2).round(), reason: 'one column: the narrowest strip');
  });

  test('an empty input rasters empty layers', () {
    final Uint8List bytes = rasterMinimap(
      MinimapRasterInput(
        nodeXs: Float64List(0),
        nodeYs: Float64List(0),
        nodeStacks: Uint8List(0),
        edgeStarts: Int32List(1),
        edgePoints: Float64List(0),
        ax: 0,
        bx: 1,
        ay: 0,
        by: 1,
        dpr: 2,
        width: 4,
        height: 4,
        outNode: _faint,
        outEdge: _faint,
        inNode: _text,
        inEdge: _muted,
      ),
    );
    expect(bytes, hasLength(2 * 4 * 4 * 4));
    expect(bytes.every((b) => b == 0), isTrue);
  });

  test('the same layout through UniformRows and equivalent PerNodeTops rasters byte-identical buffers', () {
    final GraphLayout layout = handLayout(
      <(String, int, int)>[('a', 3, 0), ('b', 2, 1), ('c', 1, 0), ('d', 0, 0)],
      edges: <(int, int)>[(0, 2), (1, 2), (2, 3)],
      indirect: const <int>{1},
    );
    final metrics = GraphMetrics();
    final uniform = UniformRows(layout, metrics);
    final perNode = PerNodeTops(
      layout,
      metrics,
      Float64List.fromList(<double>[for (var i = 0; i < layout.nodeCount; i++) uniform.top(i)]),
    );
    final geometry = routeGraph(layout, metrics) as RouteGeometry;
    final vertical = ScrollController();
    final horizontal = ScrollController();
    addTearDown(vertical.dispose);
    addTearDown(horizontal.dispose);
    Uint8List raster(VerticalLayout rows) => rasterMinimap(
      minimapRasterInput(
        GraphMinimapFrame(
          layout: layout,
          rows: rows,
          metrics: metrics,
          geometry: geometry,
          insets: const EdgeInsets.fromLTRB(76, 60, 158, 12),
          vertical: vertical,
          horizontal: horizontal,
        ),
        300,
        2,
        faint: _faint,
        text: _text,
        muted: _muted,
      ),
    );
    final Uint8List a = raster(uniform);
    expect(a.any((b) => b != 0), isTrue);
    expect(raster(perNode), a);
  });

  test('without route geometry the nodes raster alone', () {
    final GraphLayout layout = handLayout(<(String, int, int)>[('a', 1, 0), ('b', 0, 0)], edges: <(int, int)>[(0, 1)]);
    final metrics = GraphMetrics();
    final vertical = ScrollController();
    addTearDown(vertical.dispose);
    final MinimapRasterInput input = minimapRasterInput(
      GraphMinimapFrame(
        layout: layout,
        rows: UniformRows(layout, metrics),
        metrics: metrics,
        geometry: null,
        insets: EdgeInsets.zero,
        vertical: vertical,
        horizontal: vertical,
      ),
      100,
      1,
      faint: _faint,
      text: _text,
      muted: _muted,
    );
    expect(input.nodeXs, hasLength(2));
    expect(input.edgeStarts, <int>[0]);
    expect(rasterMinimap(input).any((b) => b != 0), isTrue);
  });

  test(
    'every edge runs on from the card edges to both cards\' centres, so a stretched strip shows no gap at a dot',
    () {
      final GraphLayout layout = handLayout(
        <(String, int, int)>[('a', 2, 0), ('b', 1, 1), ('c', 0, 0)],
        edges: <(int, int)>[(0, 2), (1, 2)],
      );
      final metrics = GraphMetrics();
      final vertical = ScrollController();
      addTearDown(vertical.dispose);
      final MinimapRasterInput input = minimapRasterInput(
        GraphMinimapFrame(
          layout: layout,
          rows: UniformRows(layout, metrics),
          metrics: metrics,
          geometry: routeGraph(layout, metrics) as RouteGeometry,
          insets: EdgeInsets.zero,
          vertical: vertical,
          horizontal: vertical,
        ),
        900,
        1,
        faint: _faint,
        text: _text,
        muted: _muted,
      );
      (double, double) centre(int node) => (input.nodeXs[node], input.nodeYs[node]);
      (double, double) point(int q) => (input.edgePoints[2 * q], input.edgePoints[2 * q + 1]);
      expect(input.edgeStarts, hasLength(layout.edgeCount + 1));
      for (var e = 0; e < layout.edgeCount; e++) {
        expect(
          point(input.edgeStarts[e]),
          centre(layout.parentOf(e)),
          reason: 'edge $e starts at its parent\'s centre',
        );
        expect(
          point(input.edgeStarts[e + 1] - 1),
          centre(layout.childOf(e)),
          reason: 'edge $e ends at its child\'s centre',
        );
      }
    },
  );
}
