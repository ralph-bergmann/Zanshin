// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'graph_layout.dart';
import 'graph_metrics.dart';
import 'vertical_layout.dart';

/// How far a card paints outside its rect (the widest ring, `--ring-wc-select` / `--ring-drop`, spreads 4 px); the
/// visible query inflates every card by it.
const double graphCardOverhang = 4;

/// Paints one layer of the plane: [origin] is where the plane's (0, 0) paints, [visibleRect] the part of the plane
/// the viewport shows (it may reach past the plane: the painted plane covers max(content, viewport)).
typedef GraphPaintHook = void Function(PaintingContext context, Offset origin, Rect visibleRect);

/// The paint-time opacity of `node` (10.6's dim predicate); 1 paints it as is, 0 skips it.
typedef GraphNodeOpacity = double Function(int node);

/// Where a reveal puts its node.
enum GraphRevealAlignment {
  /// In the centre of the unobscured area (the design's `scrollToNode`).
  centre,

  /// The least scroll that shows the whole card in the unobscured area.
  minimal,
}

/// A reveal carried by a relayout (Story 10.1 item 10): consumed once, by identity, in the layout it arrives with; an
/// absent [key] falls back to the anchor.
///
/// Keep the instance across builds: a new instance on every build reveals again on every build. For a reveal without
/// a relayout, use [GraphViewportController.reveal].
@immutable
class GraphReveal {
  /// Reveals [key].
  // WHY: a reveal is consumed by identity; a const constructor would canonicalize two equal requests into one
  // instance and silently skip the second.
  // ignore: prefer_const_constructors_in_immutables
  GraphReveal(this.key, {this.alignment = GraphRevealAlignment.centre, this.animate = false});

  /// The node key to reveal.
  final String key;

  /// Where it goes.
  final GraphRevealAlignment alignment;

  /// Whether the scroll animates (it jumps under reduce motion).
  final bool animate;
}

/// The scroll primitives of a graph viewport (Story 10.1 item 8): reveal a key, jump or animate to an offset.
class GraphViewportController {
  RenderGraphViewport? _viewport;

  /// Whether a viewport uses this controller.
  bool get isAttached => _viewport != null;

  /// Scrolls [key] into the unobscured area; does nothing when the key is absent or no viewport is attached. An
  /// animated reveal jumps under reduce motion.
  void reveal(String key, {GraphRevealAlignment alignment = GraphRevealAlignment.centre, bool animate = false}) =>
      _viewport?._revealNow(key, alignment, animate: animate);

  /// Jumps both axes to [offset] (horizontal, vertical).
  void jumpTo(Offset offset) {
    final RenderGraphViewport? viewport = _viewport;
    viewport?.horizontalOffset.jumpTo(offset.dx);
    viewport?.verticalOffset.jumpTo(offset.dy);
  }

  /// Animates both axes to [offset] (horizontal, vertical).
  Future<void> animateTo(Offset offset, {required Duration duration, required Curve curve}) async {
    final RenderGraphViewport? viewport = _viewport;
    if (viewport == null) {
      return;
    }
    await Future.wait(<Future<void>>[
      viewport.horizontalOffset.animateTo(offset.dx, duration: duration, curve: curve),
      viewport.verticalOffset.animateTo(offset.dy, duration: duration, curve: curve),
    ]);
  }
}

/// The graph's render viewport (Story 10.1 items 4–11).
///
/// Layout applies both extents from the data before building a child, re-applying the anchor or a reveal first, and
/// builds only the cards whose inflated rect meets the viewport ± the cache extent (plus the pinned ones). Paint owns
/// its clip and runs background → edges → visible cards in z-order → overlay; hit testing walks that order in reverse.
class RenderGraphViewport extends RenderTwoDimensionalViewport implements MouseTrackerAnnotation {
  /// Creates the viewport.
  RenderGraphViewport({
    required GraphLayout graphLayout,
    required this._metrics,
    required VerticalLayout? verticalLayout,
    required this._insets,
    required this._pinnedKeys,
    required this._selectedKey,
    required this._hoveredKey,
    required this._opacityOf,
    required this._paintBackground,
    required this._paintEdges,
    required this._paintOverlay,
    required this._anchorKey,
    required this._reveal,
    required GraphViewportController? controller,
    required this.motion,
    required super.horizontalOffset,
    required super.horizontalAxisDirection,
    required super.verticalOffset,
    required super.verticalAxisDirection,
    required super.delegate,
    required super.mainAxis,
    required super.childManager,
    super.scrollCacheExtent,
    super.clipBehavior,
  }) : assert(horizontalAxisDirection == AxisDirection.right && verticalAxisDirection == AxisDirection.down),
       _layout = graphLayout,
       _explicitVertical = verticalLayout {
    this.controller = controller;
  }

  final _clipLayer = LayerHandle<ClipRectLayer>();

  late final _pan =
      PanGestureRecognizer(
          debugOwner: this,
          supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.mouse},
          allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
        )
        ..dragStartBehavior = DragStartBehavior.down
        ..onStart = _startPan
        ..onUpdate = _updatePan
        ..onEnd = _endPan
        ..onCancel = _cancelPan;

  var _panning = false;

  /// Whether a canvas pan is held.
  bool get isPanning => _panning;

  // The anchor of the last layout: a key and its content position then.
  ({String key, Offset position})? _anchor;
  EdgeInsets? _anchorInsets;
  var _geometryChanged = false;
  GraphReveal? _consumedReveal;
  UniformRows? _uniform;

  /// The layout shown (`layout` is [RenderObject.layout]).
  GraphLayout get graphLayout => _layout;
  GraphLayout _layout;
  set graphLayout(GraphLayout value) {
    if (identical(value, _layout)) {
      return;
    }
    _layout = value;
    _markGeometryChanged();
  }

  /// The pixels in x and the card size.
  GraphMetrics get metrics => _metrics;
  GraphMetrics _metrics;
  set metrics(GraphMetrics value) {
    if (value == _metrics) {
      return;
    }
    _metrics = value;
    _markGeometryChanged();
  }

  /// The pixels in y; null maps [layout]'s rows with [UniformRows].
  VerticalLayout? get verticalLayout => _explicitVertical;
  VerticalLayout? _explicitVertical;
  set verticalLayout(VerticalLayout? value) {
    if (identical(value, _explicitVertical)) {
      return;
    }
    _explicitVertical = value;
    _markGeometryChanged();
  }

  /// The plane's live margins (the floating chrome).
  EdgeInsets get insets => _insets;
  EdgeInsets _insets;
  set insets(EdgeInsets value) {
    if (value == _insets) {
      return;
    }
    _insets = value;
    _markGeometryChanged();
  }

  /// The keys laid out even when scrolled out, painted on top.
  Set<String> get pinnedKeys => _pinnedKeys;
  Set<String> _pinnedKeys;
  set pinnedKeys(Set<String> value) {
    if (setEquals(value, _pinnedKeys)) {
      return;
    }
    _pinnedKeys = value;
    markNeedsLayout();
  }

  /// The selected key, painted above `@`.
  String? get selectedKey => _selectedKey;
  String? _selectedKey;
  set selectedKey(String? value) {
    if (value == _selectedKey) {
      return;
    }
    _selectedKey = value;
    markNeedsPaint();
  }

  /// The hovered key, painted on top.
  String? get hoveredKey => _hoveredKey;
  String? _hoveredKey;
  set hoveredKey(String? value) {
    if (value == _hoveredKey) {
      return;
    }
    _hoveredKey = value;
    markNeedsPaint();
  }

  /// The paint-time opacity per node; null paints every card opaque.
  GraphNodeOpacity? get opacityOf => _opacityOf;
  GraphNodeOpacity? _opacityOf;
  set opacityOf(GraphNodeOpacity? value) {
    if (value == _opacityOf) {
      return;
    }
    _opacityOf = value;
    markNeedsPaint();
  }

  /// Paints below the edges (10.2's day guides).
  GraphPaintHook? get paintBackground => _paintBackground;
  GraphPaintHook? _paintBackground;
  set paintBackground(GraphPaintHook? value) {
    if (value == _paintBackground) {
      return;
    }
    _paintBackground = value;
    markNeedsPaint();
  }

  /// Paints below the cards (10.4's edges).
  GraphPaintHook? get paintEdges => _paintEdges;
  GraphPaintHook? _paintEdges;
  set paintEdges(GraphPaintHook? value) {
    if (value == _paintEdges) {
      return;
    }
    _paintEdges = value;
    markNeedsPaint();
  }

  /// Paints above the cards (10.2's day labels).
  GraphPaintHook? get paintOverlay => _paintOverlay;
  GraphPaintHook? _paintOverlay;
  set paintOverlay(GraphPaintHook? value) {
    if (value == _paintOverlay) {
      return;
    }
    _paintOverlay = value;
    markNeedsPaint();
  }

  /// The key that keeps its viewport position across geometry changes; null takes the visible node nearest the
  /// viewport's centre (the default rule until 10.5).
  String? get anchorKey => _anchorKey;
  String? _anchorKey;
  set anchorKey(String? value) {
    if (value == _anchorKey) {
      return;
    }
    _anchorKey = value;
    markNeedsLayout();
  }

  /// The reveal the next layout applies, once.
  GraphReveal? get reveal => _reveal;
  GraphReveal? _reveal;
  set reveal(GraphReveal? value) {
    if (identical(value, _reveal)) {
      return;
    }
    _reveal = value;
    markNeedsLayout();
  }

  /// The motion tokens; a reveal jumps when movement is reduced.
  ZsMotion motion;

  /// The controller whose primitives drive this viewport.
  GraphViewportController? get controller => _controller;
  GraphViewportController? _controller;
  set controller(GraphViewportController? value) {
    if (identical(_controller?._viewport, this)) {
      _controller?._viewport = null;
    }
    _controller = value?.._viewport = this;
  }

  void _markGeometryChanged() {
    _geometryChanged = true;
    markNeedsLayout();
  }

  /// The y mapping in use.
  VerticalLayout get vertical {
    final VerticalLayout? explicit = _explicitVertical;
    if (explicit != null) {
      assert(identical(explicit.layout, _layout) && explicit.metrics == _metrics, 'verticalLayout maps another layout');
      return explicit;
    }
    final UniformRows? cached = _uniform;
    if (cached != null && identical(cached.layout, _layout)) {
      return cached.metrics == _metrics ? cached : _uniform = cached.withMetrics(_metrics);
    }
    return _uniform = UniformRows(_layout, _metrics);
  }

  Offset get _scroll => Offset(horizontalOffset.pixels, verticalOffset.pixels);

  /// The content size: the plane plus the insets.
  Size get contentSize =>
      Size(_insets.horizontal + _metrics.planeWidth(_layout.colCount), _insets.vertical + vertical.contentHeight);

  /// [node]'s card rect in content coordinates (scroll coordinates: the insets included).
  Rect cardRect(int node) => Rect.fromLTWH(
    _insets.left + _metrics.x(_layout.colOf(node)),
    _insets.top + vertical.top(node),
    _metrics.cardWidth,
    _metrics.cardHeight,
  );

  // ScrollCacheExtent's own pixel conversion is private.
  double _cacheFor(double extent) =>
      scrollCacheExtent.style == CacheExtentStyle.viewport ? scrollCacheExtent.value * extent : scrollCacheExtent.value;

  static void _applyExtent(ViewportOffset offset, double max) {
    // `false` means the position corrected its pixels; the second call settles.
    if (!offset.applyContentDimensions(0, max)) {
      offset.applyContentDimensions(0, max);
    }
  }

  static void _correctTo(ViewportOffset offset, double target) {
    if (target != offset.pixels) {
      offset.correctBy(target - offset.pixels);
    }
  }

  @override
  void layoutChildSequence() {
    final VerticalLayout vertical = this.vertical;
    final Size view = viewportDimension;
    final Size content = contentSize;
    final double maxX = math.max(0, content.width - view.width);
    final double maxY = math.max(0, content.height - view.height);

    if (_geometryChanged) {
      _geometryChanged = false;
      _applyAnchor(maxX, maxY);
    }
    final GraphReveal? reveal = _reveal;
    if (reveal != null && !identical(reveal, _consumedReveal)) {
      _consumedReveal = reveal;
      final Offset? target = _revealTarget(reveal.key, reveal.alignment, maxX, maxY);
      if (target != null) {
        if (reveal.animate && motion.durMove > Duration.zero) {
          SchedulerBinding.instance.addPostFrameCallback(
            (_) => _revealNow(reveal.key, reveal.alignment, animate: true),
          );
        } else {
          _correctTo(horizontalOffset, target.dx);
          _correctTo(verticalOffset, target.dy);
        }
      }
    }
    // Extents come from the data alone, so they are applied before any child is built.
    _applyExtent(horizontalOffset, maxX);
    _applyExtent(verticalOffset, maxY);

    final Offset scroll = _scroll;
    final double cacheX = _cacheFor(view.width);
    final double cacheY = _cacheFor(view.height);
    final window = Rect.fromLTRB(
      scroll.dx - cacheX - _insets.left,
      scroll.dy - cacheY - _insets.top,
      scroll.dx + view.width + cacheX - _insets.left,
      scroll.dy + view.height + cacheY - _insets.top,
    );
    final List<int> nodes = vertical.visibleNodes(window, graphCardOverhang);
    final size = Size(_metrics.cardWidth, _metrics.cardHeight);
    for (final node in nodes) {
      _layoutNode(node, size, scroll);
    }
    if (_pinnedKeys.isNotEmpty) {
      // A pinned card stays laid out (off screen, unpainted) instead of entering the keep-alive bucket, whose
      // vicinity could be taken by another node after a reload.
      final Set<int> laidOut = nodes.toSet();
      for (final String key in _pinnedKeys) {
        final int? node = _layout.indexOfKey(key);
        if (node != null && !laidOut.contains(node)) {
          _layoutNode(node, size, scroll);
        }
      }
    }
    _recordAnchor(nodes, scroll, view);
  }

  void _layoutNode(int node, Size size, Offset scroll) {
    final RenderBox? child = buildOrObtainChildFor(ChildVicinity(xIndex: _layout.colOf(node), yIndex: node));
    if (child == null) {
      return;
    }
    child.layout(BoxConstraints.tight(size), parentUsesSize: true);
    final TwoDimensionalViewportParentData data = parentDataOf(child)
      ..layoutOffset = cardRect(node).topLeft - scroll
      // WHY: a pinned card is laid out in every pass instead of resting in the keep-alive bucket (whose vicinity
      // another node can take after a reload). The framework's `_moveChild` treats an off-screen child whose KeepAlive
      // flag is set as bucketed and loses it when a reload moves its vicinity, so a laid-out child carries no flag;
      // KeepAlive sets it again on its next build, and an unpinned card that is no longer laid out is dropped.
      ..keepAlive = false;
    assert(data.vicinity.yIndex == node);
  }

  /// Keeps the anchor's viewport position across a geometry change: its content position moved by the correction.
  void _applyAnchor(double maxX, double maxY) {
    final ({String key, Offset position})? anchor = _anchor;
    final int? node = anchor == null ? null : _layout.indexOfKey(anchor.key);
    // No anchor node (nothing laid out, or its key is gone): a left or top inset change alone still shifts the offset.
    final EdgeInsets before = _anchorInsets ?? _insets;
    final Offset correction = node == null
        ? Offset(_insets.left - before.left, _insets.top - before.top)
        : cardRect(node).topLeft - anchor!.position;
    if (correction.dx != 0) {
      _correctTo(horizontalOffset, clampDouble(horizontalOffset.pixels + correction.dx, 0, maxX));
    }
    if (correction.dy != 0) {
      _correctTo(verticalOffset, clampDouble(verticalOffset.pixels + correction.dy, 0, maxY));
    }
  }

  void _recordAnchor(List<int> nodes, Offset scroll, Size view) {
    _anchorInsets = _insets;
    int? node = _anchorKey == null ? null : _layout.indexOfKey(_anchorKey!);
    if (node == null) {
      final Offset centre = scroll + view.center(Offset.zero);
      double best = double.infinity;
      for (final candidate in nodes) {
        final double distance = (cardRect(candidate).center - centre).distanceSquared;
        if (distance < best) {
          best = distance;
          node = candidate;
        }
      }
    }
    _anchor = node == null ? null : (key: _layout.keyOf(node), position: cardRect(node).topLeft);
  }

  /// The unobscured part of the viewport: inside the insets, or the whole viewport when they leave nothing.
  Rect get _unobscured {
    final Rect inside = _insets.deflateRect(Offset.zero & size);
    return inside.width > 0 && inside.height > 0 ? inside : Offset.zero & size;
  }

  Offset? _revealTarget(String key, GraphRevealAlignment alignment, double maxX, double maxY) {
    final int? node = _layout.indexOfKey(key);
    if (node == null) {
      return null;
    }
    final Rect card = cardRect(node);
    final Rect area = _unobscured;
    final Offset scroll = _scroll;
    double minimal(double lo, double hi, double areaLo, double areaHi, double current) {
      if (lo - current < areaLo || hi - lo > areaHi - areaLo) {
        return lo - areaLo;
      }
      return hi - current > areaHi ? hi - areaHi : current;
    }

    final Offset target = switch (alignment) {
      GraphRevealAlignment.centre => card.center - area.center,
      GraphRevealAlignment.minimal => Offset(
        minimal(card.left, card.right, area.left, area.right, scroll.dx),
        minimal(card.top, card.bottom, area.top, area.bottom, scroll.dy),
      ),
    };
    return Offset(clampDouble(target.dx, 0, maxX), clampDouble(target.dy, 0, maxY));
  }

  void _revealNow(String key, GraphRevealAlignment alignment, {required bool animate}) {
    if (!attached || !hasSize) {
      return;
    }
    final Size content = contentSize;
    final Offset? target = _revealTarget(
      key,
      alignment,
      math.max(0, content.width - size.width),
      math.max(0, content.height - size.height),
    );
    if (target == null) {
      return;
    }
    if (animate && motion.durMove > Duration.zero) {
      horizontalOffset.animateTo(target.dx, duration: motion.durMove, curve: motion.easeGlide);
      verticalOffset.animateTo(target.dy, duration: motion.durMove, curve: motion.easeGlide);
    } else {
      horizontalOffset.jumpTo(target.dx);
      verticalOffset.jumpTo(target.dy);
    }
  }

  // ---- paint ----

  int _zOf(int node) {
    final String key = _layout.keyOf(node);
    if (key == _hoveredKey || _pinnedKeys.contains(key)) {
      return 3;
    }
    if (key == _selectedKey) {
      return 2;
    }
    return node == _layout.workingCopyIndex ? 1 : 0;
  }

  /// The visible cards in paint order: base, then `@`, then selected, then hovered or pinned (GC:73-77).
  List<RenderBox> get paintOrder {
    final layers = List<List<RenderBox>>.generate(4, (_) => <RenderBox>[]);
    for (RenderBox? child = firstChild; child != null; child = childAfter(child)) {
      final TwoDimensionalViewportParentData data = parentDataOf(child);
      if (data.isVisible && _opacity(data.vicinity.yIndex) > 0) {
        layers[_zOf(data.vicinity.yIndex)].add(child);
      }
    }
    return <RenderBox>[for (final List<RenderBox> layer in layers) ...layer];
  }

  double _opacity(int node) => _opacityOf?.call(node) ?? 1;

  @override
  void paint(PaintingContext context, Offset offset) {
    // The base paint returns early without children and keeps _paintChildren private, so own the clip.
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
    final Offset scroll = _scroll;
    final Offset origin = offset + _insets.topLeft - scroll;
    final Rect visible = (scroll - _insets.topLeft) & size;
    _paintBackground?.call(context, origin, visible);
    _paintEdges?.call(context, origin, visible);
    for (final RenderBox child in paintOrder) {
      final TwoDimensionalViewportParentData data = parentDataOf(child);
      final double opacity = _opacity(data.vicinity.yIndex);
      final Offset at = offset + data.paintOffset!;
      if (opacity >= 1) {
        context.paintChild(child, at);
      } else {
        context.pushOpacity(
          at,
          Color.getAlphaFromOpacity(opacity),
          (context, offset) => context.paintChild(child, offset),
        );
      }
    }
    _paintOverlay?.call(context, origin, visible);
  }

  // ---- hit testing, semantics, input ----

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final RenderBox child in paintOrder.reversed) {
      final Offset paintOffset = parentDataOf(child).paintOffset!;
      final bool hit = result.addWithPaintOffset(
        offset: paintOffset,
        position: position,
        hitTest: (result, transformed) => child.hitTest(result, position: transformed),
      );
      if (hit) {
        return true;
      }
    }
    return false;
  }

  @override
  Rect? describeSemanticsClip(RenderObject? child) {
    final double cacheX = _cacheFor(size.width);
    final double cacheY = _cacheFor(size.height);
    return Rect.fromLTRB(-cacheX, -cacheY, size.width + cacheX, size.height + cacheY);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) => clipBehavior == Clip.none ? null : Offset.zero & size;

  /// Whether [position] (local) lies on a card.
  bool isOnCard(Offset position) {
    final Offset plane = position + _scroll - _insets.topLeft;
    // A card dimmed to 0 is neither painted nor hit, so it is empty canvas.
    return vertical.visibleNodes(Rect.fromLTWH(plane.dx, plane.dy, 0, 0), 0).any((node) => _opacity(node) > 0);
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerScrollEvent && event.scrollDelta.dx != 0 && event.scrollDelta.dy != 0) {
      // The viewport sits below both inner Scrollables, so it registers first and wins: a single Scrollable would
      // drop the other axis.
      GestureBinding.instance.pointerSignalResolver.register(event, _scrollBoth);
    } else if (event is PointerDownEvent && !isOnCard(entry.localPosition)) {
      _pan.addPointer(event);
    }
  }

  void _scrollBoth(PointerSignalEvent event) {
    final Offset delta = (event as PointerScrollEvent).scrollDelta;
    (horizontalOffset as ScrollPosition).pointerScroll(delta.dx);
    (verticalOffset as ScrollPosition).pointerScroll(delta.dy);
  }

  void _startPan(DragStartDetails details) {
    _panning = true;
    // A frame refreshes the mouse cursor.
    markNeedsPaint();
  }

  void _updatePan(DragUpdateDetails details) {
    for (final (ViewportOffset offset, double delta) in <(ViewportOffset, double)>[
      (horizontalOffset, details.delta.dx),
      (verticalOffset, details.delta.dy),
    ]) {
      final position = offset as ScrollPosition;
      offset.jumpTo(clampDouble(offset.pixels - delta, position.minScrollExtent, position.maxScrollExtent));
    }
  }

  void _endPan(DragEndDetails details) => _cancelPan();

  void _cancelPan() {
    _panning = false;
    markNeedsPaint();
  }

  @override
  MouseCursor get cursor => _panning ? SystemMouseCursors.grabbing : SystemMouseCursors.basic;

  @override
  PointerEnterEventListener? get onEnter => null;

  @override
  PointerExitEventListener? get onExit => null;

  @override
  bool get validForMouseTracker => attached;

  @override
  void dispose() {
    _clipLayer.layer = null;
    _pan.dispose();
    if (identical(_controller?._viewport, this)) {
      _controller?._viewport = null;
    }
    super.dispose();
  }
}
