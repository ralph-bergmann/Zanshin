// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show ViewportOffset;
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'graph_child_delegate.dart';
import 'graph_layout.dart';
import 'graph_metrics.dart';
import 'graph_viewport_render.dart';
import 'vertical_layout.dart';

export 'graph_child_delegate.dart' show GraphCardBuilder, GraphChildDelegate;
export 'graph_viewport_render.dart'
    show
        GraphNodeOpacity,
        GraphPaintHook,
        GraphReveal,
        GraphRevealAlignment,
        GraphViewportController,
        RenderGraphViewport,
        graphCardOverhang;

/// The commit graph's two-axis virtualized viewport (Story 10.1): cards at positions from the data, several per row,
/// extents exact before any card is built, only the cards around the viewport mounted.
///
/// Scrolling: trackpad and touch drags through the framework (`DiagonalDragBehavior.weightedEvent`), a wheel event
/// with dx and dy on both axes, a primary-mouse drag on empty canvas pans both axes 1:1. No scrollbars (the minimap
/// is the scroll indicator). The owner provides and disposes both scroll controllers.
class GraphViewport extends TwoDimensionalScrollView {
  /// A viewport over [layout].
  GraphViewport({
    required this.layout,
    required this.metrics,
    required this.cardBuilder,
    required ScrollController verticalController,
    required ScrollController horizontalController,
    this.verticalLayout,
    this.insets = EdgeInsets.zero,
    this.pinnedKeys = const <String>{},
    this.selectedKey,
    this.hoveredKey,
    this.opacityOf,
    this.paintBackground,
    this.paintEdges,
    this.paintOverlay,
    this.anchorKey,
    this.reveal,
    this.controller,
    super.scrollCacheExtent = defaultScrollCacheExtent,
    super.clipBehavior,
    super.key,
  }) : super(
         verticalDetails: ScrollableDetails.vertical(controller: verticalController),
         horizontalDetails: ScrollableDetails.horizontal(controller: horizontalController),
         diagonalDragBehavior: DiagonalDragBehavior.weightedEvent,
         delegate: GraphChildDelegate(layout: layout, cardBuilder: cardBuilder, pinnedKeys: pinnedKeys),
       );

  /// The cache extent on both axes: 250 px.
  static const defaultScrollCacheExtent = ScrollCacheExtent.pixels(250);

  /// The layout shown.
  final GraphLayout layout;

  /// The pixels in x and the card size.
  final GraphMetrics metrics;

  /// Builds a node's card; must be stable across builds.
  final GraphCardBuilder cardBuilder;

  /// The pixels in y; null maps the rows with [UniformRows].
  final VerticalLayout? verticalLayout;

  /// The plane's live margins.
  final EdgeInsets insets;

  /// The keys kept alive while scrolled out, painted on top.
  final Set<String> pinnedKeys;

  /// The selected key, painted above `@`.
  final String? selectedKey;

  /// The hovered key, painted on top.
  final String? hoveredKey;

  /// The paint-time opacity per node.
  final GraphNodeOpacity? opacityOf;

  /// Paints below the edges.
  final GraphPaintHook? paintBackground;

  /// Paints below the cards.
  final GraphPaintHook? paintEdges;

  /// Paints above the cards.
  final GraphPaintHook? paintOverlay;

  /// The key that keeps its place across geometry changes; null takes the visible node nearest the centre.
  final String? anchorKey;

  /// The reveal the next relayout applies once.
  final GraphReveal? reveal;

  /// Reveal, jump and animate from outside.
  final GraphViewportController? controller;

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: super.build(context),
  );

  @override
  Widget buildViewport(BuildContext context, ViewportOffset verticalOffset, ViewportOffset horizontalOffset) =>
      _GraphViewportWidget(
        owner: this,
        motion: ZsMotion.of(context),
        verticalOffset: verticalOffset,
        verticalAxisDirection: verticalDetails.direction,
        horizontalOffset: horizontalOffset,
        horizontalAxisDirection: horizontalDetails.direction,
        delegate: delegate,
        mainAxis: mainAxis,
        scrollCacheExtent: scrollCacheExtent,
        clipBehavior: clipBehavior,
      );
}

class _GraphViewportWidget extends TwoDimensionalViewport {
  const _GraphViewportWidget({
    required this.owner,
    required this.motion,
    required super.verticalOffset,
    required super.verticalAxisDirection,
    required super.horizontalOffset,
    required super.horizontalAxisDirection,
    required super.delegate,
    required super.mainAxis,
    super.scrollCacheExtent,
    super.clipBehavior,
  });

  final GraphViewport owner;
  final ZsMotion motion;

  @override
  RenderGraphViewport createRenderObject(BuildContext context) => RenderGraphViewport(
    graphLayout: owner.layout,
    metrics: owner.metrics,
    verticalLayout: owner.verticalLayout,
    insets: owner.insets,
    pinnedKeys: owner.pinnedKeys,
    selectedKey: owner.selectedKey,
    hoveredKey: owner.hoveredKey,
    opacityOf: owner.opacityOf,
    paintBackground: owner.paintBackground,
    paintEdges: owner.paintEdges,
    paintOverlay: owner.paintOverlay,
    anchorKey: owner.anchorKey,
    reveal: owner.reveal,
    controller: owner.controller,
    motion: motion,
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
  void updateRenderObject(BuildContext context, RenderGraphViewport renderObject) => renderObject
    ..graphLayout = owner.layout
    ..metrics = owner.metrics
    ..verticalLayout = owner.verticalLayout
    ..insets = owner.insets
    ..pinnedKeys = owner.pinnedKeys
    ..selectedKey = owner.selectedKey
    ..hoveredKey = owner.hoveredKey
    ..opacityOf = owner.opacityOf
    ..paintBackground = owner.paintBackground
    ..paintEdges = owner.paintEdges
    ..paintOverlay = owner.paintOverlay
    ..anchorKey = owner.anchorKey
    ..reveal = owner.reveal
    ..controller = owner.controller
    ..motion = motion
    ..horizontalOffset = horizontalOffset
    ..horizontalAxisDirection = horizontalAxisDirection
    ..verticalOffset = verticalOffset
    ..verticalAxisDirection = verticalAxisDirection
    ..delegate = delegate
    ..mainAxis = mainAxis
    ..scrollCacheExtent = scrollCacheExtent
    ..clipBehavior = clipBehavior;
}
