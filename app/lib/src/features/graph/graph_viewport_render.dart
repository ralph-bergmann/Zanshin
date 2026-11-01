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

/// How far a card's child box reaches outside its card rect on every side (Story 10.3): the bookmark control at
/// top −11 and ••• at bottom −11, which covers the rings (4 px at most). Every card child is laid out at its card rect
/// inflated by it, so its affordances hit-test inside the child; the visible query inflates every card by it. The
/// drop glow may paint beyond it, unclipped.
const double graphCardOverhang = 11;

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

  /// No scroll while the whole card lies in the unobscured area, else [centre] (Story 10.6: a select under the
  /// chrome).
  covered,
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

/// One operation's landing (Story 10.20, FLIP): the viewport glides the cards it lays out from where they were on
/// screen in [from] to their rects in [to]. [born] (a change the operation created) grows out of [anchor]'s old rect;
/// the canvas flashes [flash] through 10.19's flash.
///
/// Consumed once, by identity, by the layout pass of [to]; a transition for another layout is ignored. Keep the
/// instance across builds.
@immutable
class GraphTransition {
  /// The landing of [to] after [from].
  // WHY: a transition is consumed by identity, like a GraphReveal.
  // ignore: prefer_const_constructors_in_immutables
  GraphTransition({required this.from, required this.to, this.anchor, this.born, this.flash = const <String>{}});

  /// The layout it leaves.
  final GraphLayout from;

  /// The layout it lands; the viewport must be laying it out.
  final GraphLayout to;

  /// The operation's anchor card (the runner's hint), the born card's origin.
  final String? anchor;

  /// The change the operation created.
  final String? born;

  /// The cards to flash.
  final Set<String> flash;
}

/// A card new in a transition (not the born one) waits this long, then fades in over [graphArrivalFade].
const graphArrivalDelay = Duration(milliseconds: 220);

/// A new card's fade (after [graphArrivalDelay]).
const graphArrivalFade = Duration(milliseconds: 240);

/// The born card's scale when it starts growing out of the anchor.
const graphBirthScale = .94;

/// The part of `--dur-birth` after which the born card is opaque.
const graphBirthOpaque = .3;

enum _FxKind { glide, birth, arrival }

/// One layout pass as it was on screen: what a transition glides from.
typedef _Pass = ({
  GraphLayout layout,
  VerticalLayout vertical,
  GraphMetrics metrics,
  EdgeInsets insets,
  Offset scroll,
  Size view,
  List<int> nodes,
});

/// The scroll primitives of a graph viewport (Story 10.1 item 8): reveal a key, jump or animate to an offset.
class GraphViewportController {
  RenderGraphViewport? _viewport;

  /// Whether a viewport uses this controller.
  bool get isAttached => _viewport != null;

  /// Scrolls [key] into the unobscured area; does nothing when the key is absent or no viewport is attached. An
  /// animated reveal jumps under reduce motion and beyond 3 viewports.
  void reveal(String key, {GraphRevealAlignment alignment = GraphRevealAlignment.centre, bool animate = false}) =>
      _viewport?._revealNow(key, alignment, animate: animate);

  /// [key]'s card rect in viewport coordinates at the current scroll (a folded stack member's: its stack's), or null
  /// when absent or detached.
  Rect? cardRectOf(String key) {
    final RenderGraphViewport? viewport = _viewport;
    final int? node = viewport?.graphLayout.placeOfKey(key);
    if (viewport == null || node == null || !viewport.hasSize) {
      return null;
    }
    return viewport.cardRect(node).shift(-viewport._scroll);
  }

  /// Makes [key] the anchor the next geometry change keeps at its current viewport position (a folded key at its
  /// stack's), as if the last layout had recorded it (Story 10.17: a stack toggle's anchor member, even when the new
  /// layout lands before another frame).
  void holdAnchor(String key) => _viewport?._holdAnchor(key);

  /// The part of the viewport the chrome leaves free, in viewport coordinates; null while detached.
  Rect? get unobscured {
    final RenderGraphViewport? viewport = _viewport;
    return viewport == null || !viewport.hasSize ? null : viewport._unobscured;
  }

  /// The nodes whose card (inflated by [graphCardOverhang], as mounted) meets the plane window the viewport shows at the
  /// current scroll, inflated by [dx] horizontally and [dy] vertically (Story 10.11's content page), in ascending top
  /// order; empty while detached.
  List<int> nodesNear(double dx, double dy) {
    final RenderGraphViewport? viewport = _viewport;
    if (viewport == null || !viewport.hasSize) {
      return const <int>[];
    }
    final Rect visible = (viewport._scroll - viewport._insets.topLeft) & viewport.size;
    // The overhang the viewport mounts cards with: every card mounted inside the window is in the page.
    return viewport.vertical.visibleNodes(
      Rect.fromLTRB(visible.left - dx, visible.top - dy, visible.right + dx, visible.bottom + dy),
      graphCardOverhang,
    );
  }

  /// Whether a canvas pan is held.
  bool get isPanning => _viewport?.isPanning ?? false;

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
    required this.onUserPan,
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
    this._transition,
    this._transitionElapsed = Duration.zero,
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

  /// The key that keeps its viewport position across geometry changes while its card meets the viewport (Story 10.5
  /// design question (a): the selection); otherwise, or when null, the visible node nearest the viewport's centre.
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

  /// The operation's landing the viewport animates (Story 10.20); null animates nothing.
  GraphTransition? get transition => _transition;
  GraphTransition? _transition;
  set transition(GraphTransition? value) {
    if (identical(value, _transition)) {
      return;
    }
    _transition = value;
    markNeedsLayout();
  }

  /// How far [transition] has run; a change repaints only (and lays out once, when the glide-out cards land).
  Duration get transitionElapsed => _transitionElapsed;
  Duration _transitionElapsed;
  set transitionElapsed(Duration value) {
    if (value == _transitionElapsed) {
      return;
    }
    final bool landed = _glideOut.isNotEmpty && _transitionElapsed < motion.durFlip && value >= motion.durFlip;
    _transitionElapsed = value;
    if (landed) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  // Story 10.20: the last layout pass as it was on screen, the transition applied, its per-node effects (node indices
  // of its `to`) and the cards gliding out of the window.
  _Pass? _last;
  GraphTransition? _applied;
  var _effects = const <int, ({_FxKind kind, Offset delta})>{};
  var _glideOut = const <int>[];

  /// Called with |dx| + |dy| of each canvas pan move.
  ValueChanged<double>? onUserPan;

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
        final Offset distance = target - _scroll;
        final bool near = distance.dx.abs() <= 3 * view.width && distance.dy.abs() <= 3 * view.height;
        if (reveal.animate && near && motion.durMove > Duration.zero) {
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
    final size = Size(_metrics.cardWidth + 2 * graphCardOverhang, _metrics.cardHeight + 2 * graphCardOverhang);
    for (final node in nodes) {
      _layoutNode(node, size, scroll);
    }
    final Set<int> laidOut = nodes.toSet();
    if (_pinnedKeys.isNotEmpty) {
      // A pinned card stays laid out (off screen, unpainted) instead of entering the keep-alive bucket, whose
      // vicinity could be taken by another node after a reload.
      for (final String key in _pinnedKeys) {
        final int? node = _layout.placeOfKey(key);
        if (node != null && laidOut.add(node)) {
          _layoutNode(node, size, scroll);
        }
      }
    }
    _syncTransition(laidOut, scroll);
    if (_transitionElapsed < motion.durFlip) {
      // A card that glides out of the window stays laid out until it lands.
      for (final int node in _glideOut) {
        if (laidOut.add(node)) {
          _layoutNode(node, size, scroll);
        }
      }
    }
    _recordAnchor(nodes, scroll, view);
    _last = (
      layout: _layout,
      vertical: vertical,
      metrics: _metrics,
      insets: _insets,
      scroll: scroll,
      view: view,
      nodes: nodes,
    );
  }

  /// Applies a new [transition] of the layout being laid out, once: the screen-space deltas of the cards [laidOut]
  /// now and of the cards that were on screen in the last pass, from the last pass's rects (a running transition is
  /// finished by them, its landed rects).
  void _syncTransition(Set<int> laidOut, Offset scroll) {
    final GraphTransition? t = _transition;
    if (t == null || !identical(t.to, _layout)) {
      _applied = null;
      _effects = const <int, ({_FxKind kind, Offset delta})>{};
      _glideOut = const <int>[];
      return;
    }
    if (identical(t, _applied)) {
      return;
    }
    _applied = t;
    final effects = <int, ({_FxKind kind, Offset delta})>{};
    final glideOut = <int>[];
    _effects = effects;
    _glideOut = glideOut;
    final _Pass? last = _last;
    if (last == null || identical(last.layout, _layout)) {
      return;
    }
    final GraphLayout from = last.layout;
    final card = Size(last.metrics.cardWidth, last.metrics.cardHeight);
    Offset was(int node) =>
        Offset(last.insets.left + last.metrics.x(from.colOf(node)), last.insets.top + last.vertical.top(node)) -
        last.scroll;
    Offset now(int node) => cardRect(node).topLeft - scroll;

    final String? born = t.born;
    final int? bornNode = born == null || from.indexOfKey(born) != null ? null : _layout.placeOfKey(born);
    final int? anchorWas = t.anchor == null ? null : from.placeOfKey(t.anchor!);
    for (final node in laidOut) {
      if (node == bornNode && anchorWas != null) {
        // Centred on the anchor's old rect.
        final Offset centre = was(anchorWas) + card.center(Offset.zero);
        effects[node] = (kind: _FxKind.birth, delta: centre - (now(node) + cardRect(node).size.center(Offset.zero)));
        continue;
      }
      final int? old = from.placeOfKey(_layout.keyOf(node));
      if (old == null) {
        effects[node] = (kind: _FxKind.arrival, delta: Offset.zero);
      } else if (was(old) - now(node) case final delta when delta != Offset.zero) {
        effects[node] = (kind: _FxKind.glide, delta: delta);
      }
    }
    final Rect view = Offset.zero & last.view;
    for (final int old in last.nodes) {
      if (!(was(old) & card).overlaps(view)) {
        continue;
      }
      final int? node = _layout.placeOfKey(from.keyOf(old));
      if (node == null || laidOut.contains(node) || effects.containsKey(node)) {
        continue;
      }
      if (was(old) - now(node) case final delta when delta != Offset.zero) {
        effects[node] = (kind: _FxKind.glide, delta: delta);
        glideOut.add(node);
      }
    }
  }

  /// [node]'s transition effect now: its shift from its laid-out position, its scale about its centre and its opacity;
  /// null at rest.
  ({Offset shift, double scale, double alpha})? _fxOf(int node) {
    final ({_FxKind kind, Offset delta})? fx = _effects[node];
    if (fx == null) {
      return null;
    }
    final double ms = _transitionElapsed.inMicroseconds / 1000;
    double part(Duration length, [Duration delay = Duration.zero]) {
      final double t = ms - delay.inMicroseconds / 1000;
      final double l = length.inMicroseconds / 1000;
      return l <= 0 ? (t >= 0 ? 1 : 0) : clampDouble(t / l, 0, 1);
    }

    switch (fx.kind) {
      case _FxKind.glide:
        final double rest = 1 - motion.easeGlide.transform(part(motion.durFlip));
        return rest == 0 ? null : (shift: fx.delta * rest, scale: 1, alpha: 1);
      case _FxKind.birth:
        final double b = part(motion.durBirth);
        if (b >= 1) {
          return null;
        }
        // Reduce motion: no growth, the fade over the whole birth.
        if (motion.motion == 0) {
          return (shift: Offset.zero, scale: 1, alpha: b);
        }
        final double rest = 1 - motion.easeGlide.transform(b);
        return (
          shift: fx.delta * rest,
          scale: 1 - (1 - graphBirthScale) * rest,
          alpha: math.min(1, b / graphBirthOpaque),
        );
      case _FxKind.arrival:
        final double a = part(graphArrivalFade, graphArrivalDelay);
        return a >= 1 ? null : (shift: Offset.zero, scale: 1, alpha: motion.easeState.transform(a));
    }
  }

  /// [key]'s transition effect now (its place's), null at rest or when absent.
  @visibleForTesting
  ({Offset shift, double scale, double alpha})? transitionEffectOf(String key) {
    final int? node = _layout.placeOfKey(key);
    return node == null ? null : _fxOf(node);
  }

  /// [child]'s paint transform from the viewport's origin: its paint offset, shifted and scaled by its effect.
  Matrix4 _childTransform(RenderBox child, ({Offset shift, double scale, double alpha})? fx) {
    final Offset at = parentDataOf(child).paintOffset! + (fx?.shift ?? Offset.zero);
    final transform = Matrix4.translationValues(at.dx, at.dy, 0);
    if (fx != null && fx.scale != 1) {
      transform.multiply(_scaleAbout(child.size.center(Offset.zero), fx.scale));
    }
    return transform;
  }

  static Matrix4 _scaleAbout(Offset centre, double scale) => Matrix4.translationValues(centre.dx, centre.dy, 0)
    ..multiply(Matrix4.diagonal3Values(scale, scale, 1))
    ..multiply(Matrix4.translationValues(-centre.dx, -centre.dy, 0));

  void _layoutNode(int node, Size size, Offset scroll) {
    final RenderBox? child = buildOrObtainChildFor(ChildVicinity(xIndex: _layout.colOf(node), yIndex: node));
    if (child == null) {
      return;
    }
    child.layout(BoxConstraints.tight(size), parentUsesSize: true);
    final TwoDimensionalViewportParentData data = parentDataOf(child)
      ..layoutOffset = cardRect(node).topLeft - const Offset(graphCardOverhang, graphCardOverhang) - scroll
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
    // A folded anchor resolves to its stack, an expanded one to itself: a stack toggle keeps the anchor member's rect.
    final int? node = anchor == null ? null : _layout.placeOfKey(anchor.key);
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
    String? key = _anchorKey;
    int? node = key == null ? null : _layout.placeOfKey(key);
    // On screen means in the unobscured area: a card under the chrome gives way to the centre node.
    if (node != null && !cardRect(node).overlaps(_unobscured.shift(scroll))) {
      node = null;
    }
    if (node == null) {
      key = null;
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
    // The anchor key itself with its place's rect: a folded anchor member records its stack card's rect.
    _anchor = node == null ? null : (key: key ?? _layout.keyOf(node), position: cardRect(node).topLeft);
  }

  void _holdAnchor(String key) {
    final int? node = _layout.placeOfKey(key);
    if (node != null && hasSize) {
      _anchor = (key: key, position: cardRect(node).topLeft);
      _anchorInsets = _insets;
    }
  }

  /// The unobscured part of the viewport: inside the insets, or the whole viewport when they leave nothing.
  Rect get _unobscured {
    final Rect inside = _insets.deflateRect(Offset.zero & size);
    return inside.width > 0 && inside.height > 0 ? inside : Offset.zero & size;
  }

  Offset? _revealTarget(String key, GraphRevealAlignment alignment, double maxX, double maxY) {
    final int? node = _layout.placeOfKey(key);
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

    final Rect shown = card.shift(-scroll);
    final bool inside =
        shown.left >= area.left && shown.top >= area.top && shown.right <= area.right && shown.bottom <= area.bottom;
    final Offset target = switch (alignment) {
      GraphRevealAlignment.centre => card.center - area.center,
      GraphRevealAlignment.covered => inside ? scroll : card.center - area.center,
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
    // Decision (g): an animation over more than 3 viewports would build every card on the way, so it jumps.
    final Offset distance = target - _scroll;
    final bool near = distance.dx.abs() <= 3 * size.width && distance.dy.abs() <= 3 * size.height;
    if (animate && near && motion.durMove > Duration.zero) {
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
    final Rect view = Offset.zero & size;
    for (RenderBox? child = firstChild; child != null; child = childAfter(child)) {
      final TwoDimensionalViewportParentData data = parentDataOf(child);
      final int node = data.vicinity.yIndex;
      final ({Offset shift, double scale, double alpha})? fx = _fxOf(node);
      // A card in a transition shows where it paints, not where it is laid out.
      final bool visible = fx == null ? data.isVisible : ((data.paintOffset! + fx.shift) & child.size).overlaps(view);
      if (visible && _opacity(node) * (fx?.alpha ?? 1) > 0) {
        layers[_zOf(node)].add(child);
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
      final ({Offset shift, double scale, double alpha})? fx = _fxOf(data.vicinity.yIndex);
      final double opacity = _opacity(data.vicinity.yIndex) * (fx?.alpha ?? 1);
      final Offset at = offset + data.paintOffset! + (fx?.shift ?? Offset.zero);
      void draw(PaintingContext context, Offset offset) {
        if (fx == null || fx.scale == 1) {
          context.paintChild(child, offset);
        } else {
          context.pushTransform(
            needsCompositing,
            offset,
            _scaleAbout(child.size.center(Offset.zero), fx.scale),
            (context, offset) => context.paintChild(child, offset),
          );
        }
      }

      if (opacity >= 1) {
        draw(context, at);
      } else {
        context.pushOpacity(at, Color.getAlphaFromOpacity(opacity), draw);
      }
    }
    _paintOverlay?.call(context, origin, visible);
  }

  // ---- hit testing, semantics, input ----

  @override
  bool hitTestSelf(Offset position) => true;

  // Whether the last hit test landed on a child: a press there (a card, or an affordance in its overhang) never pans.
  var _childHit = false;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    _childHit = false;
    for (final RenderBox child in paintOrder.reversed) {
      final TwoDimensionalViewportParentData data = parentDataOf(child);
      final ({Offset shift, double scale, double alpha})? fx = _fxOf(data.vicinity.yIndex);
      // A card in a transition is hit where it paints.
      final bool hit = fx == null
          ? result.addWithPaintOffset(
              offset: data.paintOffset,
              position: position,
              hitTest: (result, transformed) => child.hitTest(result, position: transformed),
            )
          : result.addWithPaintTransform(
              transform: _childTransform(child, fx),
              position: position,
              hitTest: (result, transformed) => child.hitTest(result, position: transformed),
            );
      if (hit) {
        return _childHit = true;
      }
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_childTransform(child, _fxOf(parentDataOf(child).vicinity.yIndex)));

  @override
  Rect? describeSemanticsClip(RenderObject? child) {
    final double cacheX = _cacheFor(size.width);
    final double cacheY = _cacheFor(size.height);
    // Every mounted card keeps a (hidden) node: a card is mounted when its rect inflated by the overhang meets it.
    return Rect.fromLTRB(-cacheX, -cacheY, size.width + cacheX, size.height + cacheY).inflate(graphCardOverhang);
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
    } else if (event is PointerDownEvent && !_childHit) {
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
    onUserPan?.call(details.delta.dx.abs() + details.delta.dy.abs());
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
