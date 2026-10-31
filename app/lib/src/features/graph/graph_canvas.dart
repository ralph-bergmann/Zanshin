// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show RouteGeometry;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'day_axis.dart';
import 'graph_card.dart';
import 'graph_content.dart';
import 'graph_edges.dart';
import 'graph_focus.dart';
import 'graph_layout.dart';
import 'graph_metrics.dart';
import 'graph_peek.dart';
import 'graph_view_model.dart' show GraphDirection, GraphPulse;
import 'graph_viewport.dart';
import 'vertical_layout.dart';

const _dayMs = 86400000;

/// One go-to pulse (Story 10.6 item 12): 650 ms, three times.
const graphPulseCycle = Duration(milliseconds: 650);

/// How long the viewport rests before the canvas loads the content on screen (Story 10.11).
const graphContentSettle = Duration(milliseconds: 100);

/// The content page's horizontal buffer beside the visible window: the cache extent (Story 10.11). Vertically it is
/// one viewport height.
const double graphContentBufferX = 250;

/// A viewport over [layout] with commit cards (Story 10.3), router B's edges (Story 10.4) and Free's day axis (Story
/// 10.2): the composition the catalogue and `GraphView` share (Story 10.5). It owns its scroll controllers, its rows
/// (once per layout, remapped per metrics change), its day-axis painter (rebuilt when the rows, the theme or the local
/// day of [cards]' "now" change) and its edge painter; its [GraphRouteCache] runs the route's class stage once per
/// layout and its geometry once per card size (in `Isolate.run` above `routeSyncNodeLimit` nodes; edges appear when it
/// completes). @'s lineage is on, the selection is the anchor while it is on screen.
///
/// Story 10.6, all paint-only for the cards:
/// - **Focus path:** the hovered card, its ancestors and descendants stay; every other card paints at .4 and every
///   other edge dims, fading on `--dur-hover`. The set is computed once per hovered key.
/// - **Peek and tooltips:** a layer above the viewport opens the [GraphPeek] after `--delay-peek` of rest on a card
///   body, and an affordance's tooltip after `--delay-tooltip`; never while a card menu is open or a pan runs. The
///   peek's card stays pinned; entering the peek keeps the hover.
/// - **Reveals:** a user select reveals a covered card ([GraphRevealAlignment.covered]), the keyboard focus card is
///   revealed minimally.
/// - **Pulse:** each new [pulse] rings its card 3 × 650 ms ease-out in the accent role, growing 2 → 22 px (2 px held
///   under reduce motion) while fading 80 % → 0 %, painted in the overlay hook with the card raised and pinned.
/// - **@:** where @ lies outside the unobscured area deflated by 8 px goes to [onWorkingCopyDirection].
///
/// **Content (Story 10.11):** with a [content] cache, once the viewport has settled — no scroll change for
/// [graphContentSettle], no canvas pan held, no drag or fling on either axis — and after a new layout or card size, it
/// loads the content of the visible nodes plus a buffer (one viewport height, [graphContentBufferX] beside); cards and
/// the peek read the cache.
///
/// User scrolling it reports to [onUserScroll]: canvas mouse pans (|dx| + |dy| per move) and fling glides (per axis,
/// the updates without drag details that follow ones with them, until that axis's scroll end). Wheel and trackpad
/// pans are the shell's own; programmatic scrolls are never reported.
class GraphCanvas extends StatefulWidget {
  /// A canvas over [layout] whose cards read [cards].
  const GraphCanvas({
    required this.layout,
    required this.cards,
    this.options = const GraphViewOptions(),
    this.insets = EdgeInsets.zero,
    this.reveal,
    this.pulse,
    this.pendingKeys = const <String>{},
    this.anchorHint,
    this.content,
    this.onUserScroll,
    this.onWorkingCopyDirection,
    super.key,
  });

  /// The layout shown.
  final GraphLayout layout;

  /// The cards' shared state, "now" included; its owner disposes it.
  final GraphCardController cards;

  /// The card width and detail (mode and lane order belong to the layout).
  final GraphViewOptions options;

  /// The plane's live margins: the visible rect is the viewport inside them.
  final EdgeInsets insets;

  /// The reveal the next relayout applies once, by identity.
  final GraphReveal? reveal;

  /// The go-to pulses; each new value runs once.
  final ValueListenable<GraphPulse?>? pulse;

  /// The cards of a running action (10.9): they paint at `--disabled-opacity`.
  final Set<String> pendingKeys;

  /// The anchor of a running action's reload (10.9); null anchors on the selection.
  final String? anchorHint;

  /// The card content cache it loads into (Story 10.11); null shows the layout's own content.
  final GraphContent? content;

  /// Receives user scrolling.
  final ValueChanged<double>? onUserScroll;

  /// Receives where @ lies off screen, on each change.
  final ValueChanged<GraphDirection?>? onWorkingCopyDirection;

  @override
  State<GraphCanvas> createState() => _GraphCanvasState();
}

class _GraphCanvasState extends State<GraphCanvas> with TickerProviderStateMixin {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _viewport = GraphViewportController();
  VerticalLayout? _rows;
  GraphDayAxisPainter? _axis;
  VerticalLayout? _axisRows;
  int? _axisDay;
  late final _routes = GraphRouteCache(onRouted: () => setState(() {}));
  GraphEdgePainter? _edges;

  // The axes whose drag has delivered an update since their last scroll end.
  final _dragged = <Axis>{};

  // The focus path: the set of the hovered key in this layout, kept while the dim fades out.
  late final _dim = AnimationController(vsync: this, duration: ZsMotion.full.durHover)..addStatusListener(_dimStatus);
  Uint8List? _focus;
  String? _focusKey;
  GraphLayout? _focusLayout;

  // The pulse.
  late final _pulse = AnimationController(vsync: this, duration: graphPulseCycle * 3)..addStatusListener(_pulseStatus);
  GraphPulse? _lastPulse;
  String? _pulseKey;

  // The peek: the open key, the one shown while it leaves, and the pending one.
  String? _peekKey;
  String? _shownPeekKey;
  Timer? _peekTimer;
  String? _peekTimerKey;

  // An affordance's tooltip: the open one and the pending one.
  ({String key, GraphCardHoverArea area})? _tip;
  Timer? _tipTimer;
  ({String key, GraphCardHoverArea area})? _tipPending;

  GraphDirection? _direction;
  var _directionReported = false;

  // The content settle: restarted by every scroll change, a new layout or card size.
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    _listen(widget.cards);
    widget.pulse?.addListener(_pulseChanged);
    _vertical
      ..addListener(_measureDirection)
      ..addListener(_scheduleContent);
    _horizontal
      ..addListener(_measureDirection)
      ..addListener(_scheduleContent);
    _scheduleContent();
  }

  void _scheduleContent() {
    _settle?.cancel();
    _settle = widget.content == null ? null : Timer(graphContentSettle, _loadContent);
  }

  static bool _scrolling(ScrollController controller) =>
      controller.hasClients && controller.position.isScrollingNotifier.value;

  void _loadContent() {
    _settle = null;
    final GraphContent? content = widget.content;
    if (!mounted || content == null || !_vertical.hasClients) {
      return;
    }
    // A held pan or a drag without movement changes no offset: look again after another rest.
    if (_viewport.isPanning || _scrolling(_vertical) || _scrolling(_horizontal)) {
      _scheduleContent();
      return;
    }
    final List<int> nodes = _viewport.nodesNear(graphContentBufferX, _vertical.position.viewportDimension);
    // An empty window (no size yet) must not supersede the page in flight.
    if (nodes.isNotEmpty) {
      content.load(widget.layout, nodes);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = ZsMotion.of(context);
    _dim.duration = _motion.durHover;
  }

  ZsMotion _motion = ZsMotion.full;

  @override
  void didUpdateWidget(GraphCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cards, widget.cards)) {
      _unlisten(oldWidget.cards);
      _listen(widget.cards);
    }
    if (!identical(oldWidget.pulse, widget.pulse)) {
      oldWidget.pulse?.removeListener(_pulseChanged);
      widget.pulse?.addListener(_pulseChanged);
    }
    if (!identical(oldWidget.layout, widget.layout)) {
      _updateFocus();
    }
    // A reveal or an anchor jump corrects the offset without notifying its listeners.
    if (!identical(oldWidget.layout, widget.layout) ||
        !identical(oldWidget.reveal, widget.reveal) ||
        !identical(oldWidget.content, widget.content) ||
        oldWidget.options.cardWidth != widget.options.cardWidth ||
        oldWidget.options.detailedCards != widget.options.detailedCards ||
        oldWidget.insets != widget.insets) {
      _scheduleContent();
    }
  }

  void _listen(GraphCardController cards) {
    cards.now.addListener(_nowChanged);
    cards.hovered.addListener(_hoverChanged);
    cards.hoverArea.addListener(_hoverChanged);
    cards.menuOpen.addListener(_hoverChanged);
    cards.userSelections.addListener(_userSelected);
    cards.focused.addListener(_focusedChanged);
  }

  void _unlisten(GraphCardController cards) {
    cards.now.removeListener(_nowChanged);
    cards.hovered.removeListener(_hoverChanged);
    cards.hoverArea.removeListener(_hoverChanged);
    cards.menuOpen.removeListener(_hoverChanged);
    cards.userSelections.removeListener(_userSelected);
    cards.focused.removeListener(_focusedChanged);
  }

  @override
  void dispose() {
    _unlisten(widget.cards);
    widget.pulse?.removeListener(_pulseChanged);
    _peekTimer?.cancel();
    _tipTimer?.cancel();
    _settle?.cancel();
    _dim.dispose();
    _pulse.dispose();
    _routes.dispose();
    _axis?.dispose();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  /// The local day of [nowMs] at the layout's fixed offset.
  int _dayOf(int nowMs) => ((nowMs + widget.layout.utcOffsetMinutes * 60000) / _dayMs).floor();

  void _nowChanged() {
    if (_dayOf(widget.cards.now.value) != _axisDay) {
      setState(() {});
    }
  }

  // ---- hover: the focus path, the peek, the tooltips ----

  void _hoverChanged() {
    _updateFocus();
    _syncPeek();
  }

  /// The focus set of the hovered key in this layout (cached per key and layout), and the dim toward it.
  void _updateFocus() {
    final String? key = widget.cards.hovered.value;
    final int? node = key == null ? null : widget.layout.indexOfKey(key);
    if (node != null) {
      if (key != _focusKey || !identical(_focusLayout, widget.layout)) {
        _focus = graphFocusSet(widget.layout, node);
        _focusKey = key;
        _focusLayout = widget.layout;
      }
      _dim.forward();
    } else {
      _dim.reverse();
    }
  }

  void _dimStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      // The last fade frame painted the set at dim 0; dropping it ends the hovered edge tone too.
      setState(() {
        _focus = null;
        _focusKey = null;
      });
    }
  }

  void _syncPeek() {
    final GraphCardController cards = widget.cards;
    final String? key = cards.hovered.value;
    final GraphCardHoverArea? area = cards.hoverArea.value;
    final menu = cards.menuOpen.value != null;
    final bool body = key != null && !menu && area?.part == GraphCardHoverPart.body;

    if (_peekKey != null && (_peekKey != key || !body)) {
      setState(() => _peekKey = null);
    }
    if (_peekKey == null && body) {
      if (_peekTimerKey != key) {
        _peekTimer?.cancel();
        _peekTimerKey = key;
        _peekTimer = Timer(_motion.delayPeek, _openPeek);
      }
    } else if (!body || _peekKey != null) {
      _peekTimer?.cancel();
      _peekTimer = null;
      _peekTimerKey = null;
    }

    final String? tooltip = area?.tooltip;
    final ({String key, GraphCardHoverArea area})? wanted =
        key != null && !menu && area != null && area.part != GraphCardHoverPart.body && (tooltip?.isNotEmpty ?? false)
        ? (key: key, area: area)
        : null;
    if (_tip != null && _tip != wanted) {
      setState(() => _tip = null);
    }
    if (_tip == null && wanted != null) {
      if (_tipPending != wanted) {
        _tipTimer?.cancel();
        _tipPending = wanted;
        _tipTimer = Timer(_motion.delayTooltip, _openTip);
      }
    } else {
      _tipTimer?.cancel();
      _tipTimer = null;
      _tipPending = null;
    }
  }

  void _openPeek() {
    final String? key = _peekTimerKey;
    _peekTimer = null;
    _peekTimerKey = null;
    if (!mounted || key == null || _viewport.isPanning || widget.cards.hovered.value != key) {
      return;
    }
    setState(() => _peekKey = _shownPeekKey = key);
  }

  void _openTip() {
    final ({String key, GraphCardHoverArea area})? tip = _tipPending;
    _tipTimer = null;
    _tipPending = null;
    if (!mounted || tip == null || _viewport.isPanning) {
      return;
    }
    setState(() => _tip = tip);
  }

  /// A canvas pan: no peek, no tooltip.
  void _userPanned(double amount) {
    _peekTimer?.cancel();
    _tipTimer?.cancel();
    _peekTimer = _tipTimer = null;
    _peekTimerKey = null;
    _tipPending = null;
    if (_peekKey != null || _tip != null) {
      setState(() {
        _peekKey = null;
        _tip = null;
      });
    }
    widget.onUserScroll?.call(amount);
  }

  // ---- reveals, the pulse, @'s direction ----

  void _userSelected() {
    final String? key = widget.cards.selected.value;
    if (key != null) {
      _viewport.reveal(key, alignment: GraphRevealAlignment.covered, animate: true);
    }
  }

  void _focusedChanged() {
    final String? key = widget.cards.focused.value;
    // Only keyboard focus scrolls; a click that gives the graph focus must not jump to an old selection.
    if (key != null && FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
      _viewport.reveal(key, alignment: GraphRevealAlignment.minimal, animate: true);
    }
  }

  void _pulseChanged() {
    final GraphPulse? pulse = widget.pulse?.value;
    if (pulse == null || pulse == _lastPulse) {
      return;
    }
    _lastPulse = pulse;
    setState(() => _pulseKey = pulse.key);
    _pulse.forward(from: 0);
  }

  void _pulseStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _pulseKey = null);
    }
  }

  void _measureDirection() {
    final ValueChanged<GraphDirection?>? report = widget.onWorkingCopyDirection;
    if (report == null || !mounted) {
      return;
    }
    final int? at = widget.layout.workingCopyIndex;
    final Rect? card = at == null ? null : _viewport.cardRectOf(widget.layout.keyOf(at));
    final Rect? area = _viewport.unobscured?.deflate(8);
    GraphDirection? direction;
    if (card != null && area != null && !card.overlaps(area)) {
      direction = card.bottom <= area.top
          ? GraphDirection.up
          : card.top >= area.bottom
          ? GraphDirection.down
          : card.right <= area.left
          ? GraphDirection.left
          : GraphDirection.right;
    }
    // The first measurement always goes out: a new canvas must not leave the last one's direction standing.
    if (direction != _direction || !_directionReported) {
      _direction = direction;
      _directionReported = true;
      report(direction);
    }
  }

  void _paintPulse(Canvas canvas, Offset origin, VerticalLayout rows, GraphMetrics metrics, Color accent) {
    final String? key = _pulseKey;
    final int? node = key == null ? null : widget.layout.indexOfKey(key);
    if (node == null || !_pulse.isAnimating) {
      return;
    }
    final Rect card = Rect.fromLTWH(
      metrics.x(widget.layout.colOf(node)),
      rows.top(node),
      metrics.cardWidth,
      metrics.cardHeight,
    ).shift(origin);
    final double eased = Curves.easeOut.transform((_pulse.value * 3) % 1);
    final double spread = 2 + 20 * eased * _motion.motion;
    canvas.drawDRRect(
      RRect.fromRectAndRadius(card.inflate(spread), Radius.circular(metrics.radius + spread)),
      RRect.fromRectAndRadius(card, Radius.circular(metrics.radius)),
      Paint()..color = accent.withValues(alpha: accent.a * .8 * (1 - eased)),
    );
  }

  // ---- build ----

  // A viewport resize changes the window without changing an offset.
  bool _onMetrics(ScrollMetricsNotification notification) {
    _scheduleContent();
    return false;
  }

  bool _onScroll(ScrollNotification notification) {
    final Axis axis = notification.metrics.axis;
    if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails != null) {
        _dragged.add(axis);
      } else if (_dragged.contains(axis)) {
        widget.onUserScroll?.call((notification.scrollDelta ?? 0).abs());
      }
    } else if (notification is ScrollEndNotification) {
      _dragged.remove(axis);
    }
    return false;
  }

  // A tear-off of this state's method is equal across builds, so the delegate rebuilds no card.
  Widget _card(BuildContext context, int node) =>
      GraphCard(layout: widget.layout, node: node, controller: widget.cards, content: widget.content);

  /// The rows, built once per layout and remapped once per metrics change.
  VerticalLayout _rowsFor(GraphMetrics metrics) {
    final VerticalLayout? rows = _rows;
    if (rows != null && rows.layout == widget.layout) {
      return rows.metrics == metrics ? rows : _rows = rows.withMetrics(metrics);
    }
    return _rows = UniformRows(widget.layout, metrics);
  }

  /// The day-axis painter, recreated (the old one disposed) when the rows, the theme, the strings or the local day
  /// change.
  GraphDayAxisPainter _axisFor(VerticalLayout rows, GraphTheme theme) {
    final int nowMs = widget.cards.now.value;
    final int day = _dayOf(nowMs);
    final AppLocalizations strings = context.l10n;
    final GraphDayAxisPainter? axis = _axis;
    if (axis != null &&
        identical(_axisRows, rows) &&
        axis.theme == theme &&
        identical(axis.strings, strings) &&
        _axisDay == day) {
      return axis;
    }
    axis?.dispose();
    _axisRows = rows;
    _axisDay = day;
    return _axis = GraphDayAxisPainter(
      axis: GraphDayAxis.of(widget.layout, rows),
      theme: theme,
      strings: strings,
      nowMs: nowMs,
      utcOffsetMinutes: widget.layout.utcOffsetMinutes,
    );
  }

  /// The edge painter of the current layout, metrics and theme (recreated when one changes), or null while its
  /// geometry is being routed.
  GraphEdgePainter? _edgesFor(GraphMetrics metrics, GraphTheme theme) {
    final RouteGeometry? geometry = _routes.geometryFor(widget.layout, metrics);
    if (geometry == null) {
      return null;
    }
    final GraphEdgePainter? edges = _edges;
    if (edges != null && identical(edges.geometry, geometry) && edges.theme == theme) {
      return edges;
    }
    return _edges = GraphEdgePainter(layout: widget.layout, geometry: geometry, theme: theme);
  }

  @override
  Widget build(BuildContext context) {
    final metrics = GraphMetrics.fromOptions(widget.options);
    final VerticalLayout rows = _rowsFor(metrics);
    final GraphTheme theme = GraphTheme.of(context);
    final GraphDayAxisPainter axis = _axisFor(rows, theme);
    final GraphEdgePainter? edges = _edgesFor(metrics, theme);
    final double leftInset = widget.insets.left;
    final Color accent = ZsColors.of(context).accent;
    final GraphCardController cards = widget.cards;
    final double disabledOpacity = ZsMetrics.of(context).disabledOpacity;
    final pending = <int>{
      for (final String key in widget.pendingKeys) ?widget.layout.indexOfKey(key),
    };
    // After layout: the layout, the insets or the size may have moved @ in or out of view.
    SchedulerBinding.instance.addPostFrameCallback((_) => _measureDirection());
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        NotificationListener<ScrollMetricsNotification>(
          onNotification: _onMetrics,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            // The viewport's z-order, dim and pulse follow the card controller and the animations; rebuilding it builds
            // no card.
            child: ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[cards.selected, cards.hovered, cards.menuOpen, _dim, _pulse]),
              builder: (context, _) {
                final String? menu = cards.menuOpen.value;
                final String? hoveredKey = cards.hovered.value;
                // A set of another layout (a reload during the fade) is dropped.
                final Uint8List? focus = identical(_focusLayout, widget.layout) ? _focus : null;
                final double dim = _dim.value;
                final highlight = GraphEdgeHighlight(
                  hoveredNode: hoveredKey == null ? null : widget.layout.indexOfKey(hoveredKey),
                  focus: focus,
                  dim: dim,
                );
                return GraphViewport(
                  layout: widget.layout,
                  metrics: metrics,
                  verticalLayout: rows,
                  cardBuilder: _card,
                  verticalController: _vertical,
                  horizontalController: _horizontal,
                  controller: _viewport,
                  insets: widget.insets,
                  selectedKey: cards.selected.value,
                  hoveredKey: hoveredKey,
                  pinnedKeys: <String>{?menu, ?_peekKey, ?_pulseKey},
                  opacityOf: (focus == null || dim == 0) && pending.isEmpty
                      ? null
                      : (node) =>
                            (pending.contains(node) ? disabledOpacity : 1) *
                            (focus == null || focus[node] != 0 ? 1 : 1 - .6 * dim),
                  anchorKey: widget.anchorHint ?? cards.selected.value,
                  reveal: widget.reveal,
                  onUserPan: _userPanned,
                  paintBackground: axis.paintGuides,
                  paintEdges: edges == null
                      ? null
                      : (context, origin, visible) => edges.paint(context, origin, visible, highlight: highlight),
                  paintOverlay: (context, origin, visible) {
                    axis.paintLabels(context, origin, visible, leftInset: leftInset);
                    _paintPulse(context.canvas, origin, rows, metrics, accent);
                  },
                );
              },
            ),
          ),
        ),
        if (_shownPeekKey != null || _tip != null)
          ListenableBuilder(
            listenable: Listenable.merge(<Listenable?>[_vertical, _horizontal, widget.content]),
            builder: (context, _) => Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (_shownPeekKey case final String key)
                  ZsPresence(
                    key: ValueKey<String>(key),
                    open: _peekKey != null,
                    exit: _motion.durExitLg,
                    builder: (context, closing) => _peekLayer(key, closing),
                  ),
                if (_tip case final tip?) _tipLayer(tip.key, tip.area),
              ],
            ),
          ),
      ],
    );
  }

  Widget _peekLayer(String key, bool closing) {
    final int? node = widget.layout.indexOfKey(key);
    final Rect? card = _viewport.cardRectOf(key);
    final Rect? area = _viewport.unobscured;
    if (node == null || card == null || area == null) {
      return const SizedBox.shrink();
    }
    final GraphCardController cards = widget.cards;
    // Not announced (DS PeekCard.prompt.md:14): VoiceOver gets the facts from the card and the inspector.
    return ExcludeSemantics(
      child: CustomSingleChildLayout(
        delegate: _PeekLayout(card: card, area: area),
        child: IgnorePointer(
          ignoring: closing,
          child: MouseRegion(
            onEnter: (_) => cards.holdHover(),
            onExit: (_) => cards.leave(key),
            child: _PeekMotion(
              closing: closing,
              // The drift on leaving points back at the card.
              drift: card.right + 8 + graphPeekWidth > area.right ? 4 : -4,
              child: GraphPeek(
                data: GraphCardData.of(widget.layout, node, content: widget.content),
                nowMs: cards.now.value,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tipLayer(String key, GraphCardHoverArea hover) {
    final Rect? card = _viewport.cardRectOf(key);
    final Rect? area = _viewport.unobscured;
    if (card == null || area == null) {
      return const SizedBox.shrink();
    }
    final Rect target = hover.rect.shift(card.topLeft);
    return IgnorePointer(
      child: CustomSingleChildLayout(
        delegate: _TipLayout(target: target, area: area),
        // A new affordance's tooltip is a new bubble with its own fade-in.
        child: _TipBubble(key: ValueKey<(String, GraphCardHoverPart)>((key, hover.part)), message: hover.tooltip!),
      ),
    );
  }
}

class _PeekLayout extends SingleChildLayoutDelegate {
  _PeekLayout({required this.card, required this.area});

  final Rect card;
  final Rect area;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => graphPeekPosition(card, childSize, area).topLeft;

  @override
  bool shouldRelayout(_PeekLayout oldDelegate) => card != oldDelegate.card || area != oldDelegate.area;
}

class _TipLayout extends SingleChildLayoutDelegate {
  _TipLayout({required this.target, required this.area});

  final Rect target;
  final Rect area;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => graphTooltipPosition(target, childSize, area).topLeft;

  @override
  bool shouldRelayout(_TipLayout oldDelegate) => target != oldDelegate.target || area != oldDelegate.area;
}

/// The peek's motion (DS PeekCard.prompt.md:14; decisions 16.4, 16.40): it fades in on `--dur-hover`; it leaves with a
/// fade and a [drift] × `--motion` on `--dur-exit-lg` / `--ease-exit`.
class _PeekMotion extends StatefulWidget {
  const _PeekMotion({required this.closing, required this.drift, required this.child});

  final bool closing;
  final double drift;
  final Widget child;

  @override
  State<_PeekMotion> createState() => _PeekMotionState();
}

class _PeekMotionState extends State<_PeekMotion> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ZsMotion motion = ZsMotion.of(context);
    _controller
      ..duration = motion.durHover
      ..reverseDuration = motion.durExitLg;
    if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_PeekMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing != oldWidget.closing) {
      if (widget.closing) {
        _controller.reverse();
      } else {
        _controller.forward();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZsMotion motion = ZsMotion.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double v = _controller.value;
        final double opacity = widget.closing ? motion.easeExit.flipped.transform(v) : motion.easeState.transform(v);
        return Transform.translate(
          offset: Offset(widget.closing ? widget.drift * motion.motion * (1 - v) : 0, 0),
          child: Opacity(opacity: opacity.clamp(0, 1), child: child),
        );
      },
      child: widget.child,
    );
  }
}

/// An affordance's tooltip bubble, faded in on `--dur-hover`.
class _TipBubble extends StatefulWidget {
  const _TipBubble({required this.message, super.key});

  final String message;

  @override
  State<_TipBubble> createState() => _TipBubbleState();
}

class _TipBubbleState extends State<_TipBubble> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ZsMotion motion = ZsMotion.of(context);
    _controller.duration = motion.durHover;
    if (_controller.isDismissed) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ZsTooltipBubble(
    animation: _controller,
    message: widget.message,
    placement: ZsTooltipPlacement.above,
  );
}
