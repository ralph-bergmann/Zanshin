// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';

void main() {
  test('the defaults are the design tokens: W 240, H 62 / 40, gapX 56, gapY 48, pad 56, radius 10', () {
    final metrics = GraphMetrics();
    expect(metrics.cardWidth, 240);
    expect(metrics.cardHeight, 62);
    expect(GraphMetrics(detailedCards: false).cardHeight, 40);
    expect(metrics.gapX, 56);
    expect(metrics.gapY, 48);
    expect(metrics.pad, 56);
    expect(metrics.radius, 10);
  });

  test('the card width is clamped to 160–400', () {
    expect(GraphMetrics(cardWidth: 100).cardWidth, 160);
    expect(GraphMetrics(cardWidth: 999).cardWidth, 400);
    expect(GraphMetrics(cardWidth: 300).cardWidth, 300);
  });

  test('x = pad + col·(W + gapX) and the plane width is 2·pad + colCount·(W + gapX) − gapX, without a gutter', () {
    final metrics = GraphMetrics(cardWidth: 200);
    expect(metrics.x(0), 56);
    expect(metrics.x(3), 56 + 3 * 256);
    expect(metrics.planeWidth(4), 2 * 56 + 4 * 256 - 56);
    expect(metrics.planeWidth(0), 2 * 56);
  });

  test('fromOptions takes the card width and size; equal options give equal metrics', () {
    const options = GraphViewOptions(cardWidth: 320, detailedCards: false);
    final metrics = GraphMetrics.fromOptions(options);
    expect(metrics, GraphMetrics(cardWidth: 320, detailedCards: false));
    expect(metrics.hashCode, GraphMetrics(cardWidth: 320, detailedCards: false).hashCode);
    expect(metrics == GraphMetrics(), isFalse);
    expect(const GraphViewOptions().layout, GraphMode.free);
    expect(const GraphViewOptions().laneOrder, GraphLaneOrder.compact);
    expect(options.copyWith(cardWidth: 240, detailedCards: true), const GraphViewOptions());
  });
}
