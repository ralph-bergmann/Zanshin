// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'commit_card.dart';
import 'graph_data.dart';
import 'graph_geometry.dart';

/// Commit graph that virtualizes in both axes. The owner provides (and
/// disposes) both controllers; they also drive the two scrollbars.
class CommitGraphView extends TwoDimensionalScrollView {
  CommitGraphView({
    required this.graph,
    required ValueChanged<int> onTap,
    required ScrollController verticalController,
    required ScrollController horizontalController,
    super.key,
    super.scrollCacheExtent,
  }) : super(
         verticalDetails: ScrollableDetails.vertical(controller: verticalController),
         horizontalDetails: ScrollableDetails.horizontal(controller: horizontalController),
         diagonalDragBehavior: DiagonalDragBehavior.free,
         delegate: TwoDimensionalChildBuilderDelegate(
           maxXIndex: graph.laneCount - 1,
           maxYIndex: graph.rows.length - 1,
           // addRepaintBoundaries (default true) gives every card its own layer;
           // stateless cards need no AutomaticKeepAlive wrappers.
           addAutomaticKeepAlives: false,
           builder: (context, v) => CommitCard(
             row: v.yIndex,
             color: laneColor(graph.rows[v.yIndex].colorIndex),
             onTap: onTap,
           ),
         ),
       );

  final CommitGraphData graph;

  // Both axes notify at depth 0, so each scrollbar must also filter by axis.
  static ScrollNotificationPredicate _on(Axis axis) =>
      (n) => n.depth == 0 && n.metrics.axis == axis;

  // TwoDimensionalScrollable builds no scrollbars at all (flutter#122348).
  @override
  Widget build(BuildContext context) => RawScrollbar(
    controller: verticalDetails.controller,
    thumbVisibility: true,
    notificationPredicate: _on(Axis.vertical),
    child: RawScrollbar(
      controller: horizontalDetails.controller,
      thumbVisibility: true,
      notificationPredicate: _on(Axis.horizontal),
      child: super.build(context),
    ),
  );

  @override
  Widget buildViewport(BuildContext context, ViewportOffset vertical, ViewportOffset horizontal) =>
      _CommitGraphViewport(
        graph: graph,
        verticalOffset: vertical,
        verticalAxisDirection: verticalDetails.direction,
        horizontalOffset: horizontal,
        horizontalAxisDirection: horizontalDetails.direction,
        delegate: delegate,
        mainAxis: mainAxis,
        scrollCacheExtent: scrollCacheExtent,
        clipBehavior: clipBehavior,
      );
}

class _CommitGraphViewport extends TwoDimensionalViewport {
  const _CommitGraphViewport({
    required this.graph,
    required super.verticalOffset,
    required super.verticalAxisDirection,
    required super.horizontalOffset,
    required super.horizontalAxisDirection,
    required super.delegate,
    required super.mainAxis,
    super.scrollCacheExtent,
    super.clipBehavior,
  });

  final CommitGraphData graph;

  @override
  RenderCommitGraphViewport createRenderObject(BuildContext context) => RenderCommitGraphViewport(
    graph: graph,
    horizontalOffset: horizontalOffset,
    horizontalAxisDirection: horizontalAxisDirection,
    verticalOffset: verticalOffset,
    verticalAxisDirection: verticalAxisDirection,
    delegate: delegate,
    mainAxis: mainAxis,
    childManager: context as TwoDimensionalChildManager,
    scrollCacheExtent: scrollCacheExtent,
    clipBehavior: clipBehavior,
  );

  @override
  void updateRenderObject(BuildContext context, RenderCommitGraphViewport renderObject) => renderObject
    ..graph = graph
    ..horizontalOffset = horizontalOffset
    ..horizontalAxisDirection = horizontalAxisDirection
    ..verticalOffset = verticalOffset
    ..verticalAxisDirection = verticalAxisDirection
    ..delegate = delegate
    ..mainAxis = mainAxis
    ..scrollCacheExtent = scrollCacheExtent
    ..clipBehavior = clipBehavior;
}

class RenderCommitGraphViewport extends RenderTwoDimensionalViewport {
  RenderCommitGraphViewport({
    required this._graph,
    required super.horizontalOffset,
    required super.horizontalAxisDirection,
    required super.verticalOffset,
    required super.verticalAxisDirection,
    required super.delegate,
    required super.mainAxis,
    required super.childManager,
    super.scrollCacheExtent,
    super.clipBehavior,
  });

  CommitGraphData get graph => _graph;
  CommitGraphData _graph;
  set graph(CommitGraphData value) {
    if (identical(value, _graph)) {
      return;
    }
    _graph = value;
    markNeedsLayout(withDelegateRebuild: true);
  }

  final _clipLayer = LayerHandle<ClipRectLayer>();
  final _edgePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;

  Offset get _scroll => Offset(horizontalOffset.pixels, verticalOffset.pixels);

  // ScrollCacheExtent's own pixel conversion is private.
  double _cacheFor(double extent) =>
      scrollCacheExtent.style == CacheExtentStyle.viewport ? scrollCacheExtent.value * extent : scrollCacheExtent.value;

  /// Rows intersecting [top, bottom) by index arithmetic — never a scan.
  (int, int) _rowRange(double top, double bottom) => (
    math.max(0, (top / rowHeight).floor()),
    math.min(graph.rows.length - 1, (bottom / rowHeight).ceil() - 1),
  );

  static void _applyExtent(ViewportOffset offset, double max) {
    // `false` means the position corrected its pixels; the second call settles.
    if (!offset.applyContentDimensions(0, max)) {
      offset.applyContentDimensions(0, max);
    }
  }

  @override
  void layoutChildSequence() {
    final Size view = viewportDimension;
    final Size content = contentSize(graph);
    // Extents depend on the data only, so they are applied before any child.
    _applyExtent(verticalOffset, math.max(0, content.height - view.height));
    _applyExtent(horizontalOffset, math.max(0, content.width - view.width));

    final Offset scroll = _scroll;
    final Rect cached = EdgeInsets.symmetric(
      horizontal: _cacheFor(view.width),
      vertical: _cacheFor(view.height),
    ).inflateRect(scroll & view);
    final (int first, int last) = _rowRange(cached.top, cached.bottom);
    for (var row = first; row <= last; row++) {
      final int lane = graph.rows[row].lane;
      final Rect rect = cardRect(row, lane);
      if (!rect.overlaps(cached)) {
        continue; // lane column is off-screen horizontally
      }
      final RenderBox? child = buildOrObtainChildFor(ChildVicinity(xIndex: lane, yIndex: row));
      if (child == null) {
        continue;
      }
      child.layout(BoxConstraints.tight(rect.size), parentUsesSize: true);
      parentDataOf(child).layoutOffset = rect.topLeft - scroll;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Base paint() bails out without children, clips only on "overflow" and
    // keeps _paintChildren private — so own the clip: edges first, then cards.
    _clipLayer.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      _paintContents,
      clipBehavior: clipBehavior,
      oldLayer: _clipLayer.layer,
    );
  }

  void _paintContents(PaintingContext context, Offset offset) {
    _paintEdges(context.canvas, offset - _scroll);
    for (RenderBox? child = firstChild; child != null; child = childAfter(child)) {
      final TwoDimensionalViewportParentData data = parentDataOf(child);
      if (data.isVisible) {
        context.paintChild(child, offset + data.paintOffset!);
      }
    }
  }

  /// Edges of the visible rows only, batched into one [Path] per color.
  void _paintEdges(Canvas canvas, Offset origin) {
    final paths = <int, Path>{};
    Path pathFor(int color) => paths.putIfAbsent(color % lanePalette.length, Path.new);
    double x(int lane) => origin.dx + laneCenterX(lane);
    final (int first, int last) = _rowRange(_scroll.dy, _scroll.dy + size.height);
    for (var row = first; row <= last; row++) {
      final GraphRow r = graph.rows[row];
      final double top = origin.dy + row * rowHeight;
      final double mid = top + rowHeight / 2;
      final double bottom = top + rowHeight;
      for (final int lane in r.passThrough) {
        pathFor(lane)
          ..moveTo(x(lane), top)
          ..lineTo(x(lane), bottom);
      }
      final Path path = pathFor(r.colorIndex);
      if (row > 0) {
        path
          ..moveTo(x(r.lane), top)
          ..lineTo(x(r.lane), mid);
      }
      for (final int target in r.parentLanes) {
        path
          ..moveTo(x(r.lane), mid)
          ..cubicTo(x(r.lane), bottom, x(target), mid, x(target), bottom);
      }
    }
    paths.forEach((c, p) => canvas.drawPath(p, _edgePaint..color = lanePalette[c]));
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    super.dispose();
  }
}
