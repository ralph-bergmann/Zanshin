// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show RouteGeometry, ShowEntry;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'day_axis.dart';
import 'graph_card.dart';
import 'graph_content.dart';
import 'graph_drag.dart';
import 'graph_drop_menu.dart';
import 'graph_edges.dart';
import 'graph_focus.dart';
import 'graph_gap_callout.dart';
import 'graph_gaps.dart';
import 'graph_layout.dart';
import 'graph_metrics.dart';
import 'graph_minimap.dart' show GraphMinimapFrame, GraphMinimapSource;
import 'graph_peek.dart';
import 'graph_stack_card.dart';
import 'graph_stack_popover.dart';
import 'graph_view_model.dart' show GraphDirection, GraphFlash, GraphGapTarget, GraphPulse;
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

/// When the born card's edges start drawing in during a transition (Story 10.20).
const graphBornEdgeDelay = Duration(milliseconds: 140);

/// How long the born card's edges take to draw in.
const graphBornEdgeDraw = Duration(milliseconds: 520);

/// The drag's auto-scroll zone inside the unobscured area (Story 10.10).
const double graphAutoScrollZone = 56;

/// How far outside the unobscured area the auto-scroll still runs (Story 10.10).
const double graphAutoScrollOutside = 24;

/// One axis of the drag's auto-scroll per frame (Story 10.10): toward [lo] or [hi] when [v] lies within
/// [graphAutoScrollZone] inside that edge, or up to [graphAutoScrollOutside] outside it, `ceil((56 − d) / 4)` px; else 0.
double graphAutoScrollStep(double lo, double hi, double v) {
  final double toLo = v - lo;
  final double toHi = hi - v;
  if (toLo < graphAutoScrollZone && toLo >= -graphAutoScrollOutside) {
    return -((graphAutoScrollZone - toLo) / 4).ceilToDouble();
  }
  if (toHi < graphAutoScrollZone && toHi >= -graphAutoScrollOutside) {
    return ((graphAutoScrollZone - toHi) / 4).ceilToDouble();
  }
  return 0;
}

/// A transition's length under [motion]: its longest part (Story 10.20; 720 ms, 540 ms under reduce motion).
Duration graphTransitionDuration(ZsMotion motion) => <Duration>[
  motion.durFlip + motion.durSlide,
  motion.durBirth,
  graphArrivalDelay + graphArrivalFade,
  if (motion.durFlip > Duration.zero) graphBornEdgeDelay + graphBornEdgeDraw,
].reduce((a, b) => a > b ? a : b);

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
/// **Operations (Story 10.20):** each new [transition] of the shown layout runs once on one ticker
/// ([graphTransitionDuration]): the viewport glides, grows and fades the cards, paint-only; the edge layer is hidden
/// for `--dur-flip` and fades back over `--dur-slide` on `--ease-state` while the born card's edges draw in from their
/// parent end ([graphBornEdgeDelay], [graphBornEdgeDraw]; under reduce motion they come with the layer); its flash
/// keys run 10.19's flash; the born card is revealed (covered, animated) after `--dur-flip`; the peek waits for the
/// end. A [GraphTransition.continued] one keeps the running transition going onto its layout; a layout without one
/// ends it at once and still reveals its covered born card, unless that layout brings a [reveal].
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
    this.minimapSource,
    this.inspectorOpen = false,
    this.entering,
    this.onExpandStack,
    this.onCollapseStack,
    this.flash,
    this.onShowGap,
    this.showChange,
    this.transition,
    this.drag,
    super.key,
  });

  /// The graph's drag-and-drop (Story 10.10): the canvas resolves its target, pins and dims its source, highlights
  /// its target, shows its menu and auto-scrolls; null drags nothing.
  final GraphDrag? drag;

  /// The operation's landing of [layout] (Story 10.20); each new instance runs once.
  final GraphTransition? transition;

  /// The gap reveals' flashes (Story 10.19); each new value runs once.
  final ValueListenable<GraphFlash?>? flash;

  /// A gap callout's "Show in `all()`" (Story 10.19); null disables it.
  final ValueChanged<GraphGapTarget>? onShowGap;

  /// `jj show` of a commit id: a Missing edge's hidden parents in the gap callout (Story 10.19).
  final Future<ShowEntry> Function(String commitId)? showChange;

  /// The keys that fade in once with [layout] (Story 10.17: an expand's members but its anchor); each new set runs
  /// once, by identity.
  final Set<String>? entering;

  /// Expands the stack of a key (a stack card's click, Enter or Space); null leaves stacks closed.
  final ValueChanged<String>? onExpandStack;

  /// Collapses the expanded run of a key (its bracket's button); null shows no button.
  final ValueChanged<String>? onCollapseStack;

  /// Whether the inspector covers the plane's right side (Story 10.8): when it opens, a selection it covers scrolls
  /// clear ([GraphRevealAlignment.covered], animated); a width change moves nothing.
  final bool inspectorOpen;

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

  /// Receives this canvas's geometry and scroll controllers after each build that changed them (Story 10.16).
  final GraphMinimapSource? minimapSource;

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
  GraphGaps? _gaps;

  // Story 10.19: the hovered gap target (paint-only), the callout's open gap and its target point (plane), the timers.
  final _gapHover = ValueNotifier<int?>(null);
  int? _gapOpen;
  Offset? _gapPoint;
  Offset? _gapPendingPoint;
  Timer? _gapTimer;
  Timer? _gapCloseTimer;
  var _inGapCallout = false;

  // Story 10.19: the gap reveal's flash.
  late final _flash = AnimationController(vsync: this)..addStatusListener(_flashStatus);
  GraphFlash? _lastFlash;
  var _flashKeys = const <String>{};

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

  // Story 10.17: the expand's fade-in (one ticker for every entering card) and the hovered bracket's run.
  late final _enter = AnimationController(vsync: this, value: 1);
  var _enterKeys = const <String>{};
  final _bracketRun = ValueNotifier<int?>(null);

  // Story 10.20: the running transition (one ticker), its born card's edges, the after-glide reveal.
  late final _transition = AnimationController(vsync: this)
    ..addListener(_transitionTicked)
    ..addStatusListener(_transitionStatus);
  GraphTransition? _moving;
  var _bornEdges = const <int>{};
  String? _bornReveal;

  // Story 10.10: the drag seen last, the auto-scroll's ticker and arming, the open menu's rect and placement.
  var _dragActive = false;
  Offset? _dragPointer;
  late final Ticker _autoScroll = createTicker(_autoScrollTick);
  var _autoScrollArmed = false;
  Rect? _menuRect;
  var _menuAbove = false;

  @override
  void initState() {
    super.initState();
    _listen(widget.cards);
    _attachDrag(widget.drag);
    widget.pulse?.addListener(_pulseChanged);
    widget.flash?.addListener(_flashChanged);
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

  static bool _laidOut(ScrollController controller) =>
      controller.hasClients && controller.position.hasViewportDimension && controller.position.hasPixels;

  void _loadContent() {
    _settle = null;
    final GraphContent? content = widget.content;
    if (!mounted || content == null || !_laidOut(_vertical)) {
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
    _enter.duration = _motion.durSlide;
    _flash.duration = _motion.durFlash;
    _transition.duration = graphTransitionDuration(_motion);
  }

  ZsMotion _motion = ZsMotion.full;

  @override
  void didUpdateWidget(GraphCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cards, widget.cards)) {
      _unlisten(oldWidget.cards);
      _listen(widget.cards);
    }
    if (!identical(oldWidget.drag, widget.drag)) {
      _detachDrag(oldWidget.drag);
      _attachDrag(widget.drag);
    }
    if (!identical(oldWidget.pulse, widget.pulse)) {
      oldWidget.pulse?.removeListener(_pulseChanged);
      widget.pulse?.addListener(_pulseChanged);
    }
    if (!identical(oldWidget.flash, widget.flash)) {
      oldWidget.flash?.removeListener(_flashChanged);
      widget.flash?.addListener(_flashChanged);
    }
    if (!identical(oldWidget.layout, widget.layout)) {
      // A gap index belongs to its layout.
      _closeGap();
      _updateFocus();
      if (_bracketRun.value != null) {
        _bracketRun.value = null;
      }
    }
    final Set<String>? entering = widget.entering;
    if (!identical(oldWidget.entering, entering) && entering != null && entering.isNotEmpty) {
      // Before this build lays the new layout's cards out: they read the set.
      _enterKeys = entering;
      _enter.forward(from: 0);
    } else if (!identical(oldWidget.layout, widget.layout)) {
      _enterKeys = const <String>{};
    }
    final GraphTransition? transition = widget.transition;
    final bool landed =
        !identical(oldWidget.transition, transition) && transition != null && identical(transition.to, widget.layout);
    if (landed && !transition.isContinued) {
      _startTransition(transition);
    } else if (landed && transition.continues(_moving)) {
      // A later layout of the running landing (a same-op reload): it keeps going onto that layout.
      _moving = transition;
      _bornEdges = _bornEdgesOf(transition);
      if (widget.reveal != null && !identical(oldWidget.reveal, widget.reveal)) {
        _bornReveal = null; // The layout's own reveal (a go-to, an expand) wins over the born card's.
      }
    } else if (!identical(oldWidget.layout, widget.layout) && _moving != null) {
      // A layout without a transition ends the running one; its covered born card is still revealed, unless the
      // layout brings a new reveal of its own.
      final String? born = _bornReveal;
      _moving = null;
      _bornEdges = const <int>{};
      _bornReveal = null;
      _transition.stop();
      _openWaitingPeek();
      if (born != null && (widget.reveal == null || identical(oldWidget.reveal, widget.reveal))) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted && _moving == null && widget.layout.placeOfKey(born) != null) {
            _viewport.reveal(born, alignment: GraphRevealAlignment.covered, animate: true);
          }
        });
      }
    }
    if (widget.inspectorOpen && !oldWidget.inspectorOpen) {
      // After the frame that hands the viewport the inspector's inset.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final String? key = widget.cards.selected.value;
        if (mounted && key != null) {
          _viewport.reveal(key, alignment: GraphRevealAlignment.covered, animate: true);
        }
      });
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
    cards
      ..onExpandStack = _expandStack
      ..onCollapseStack = _collapseStackOf;
  }

  void _unlisten(GraphCardController cards) {
    cards.now.removeListener(_nowChanged);
    cards.hovered.removeListener(_hoverChanged);
    cards.hoverArea.removeListener(_hoverChanged);
    cards.menuOpen.removeListener(_hoverChanged);
    cards.userSelections.removeListener(_userSelected);
    cards.focused.removeListener(_focusedChanged);
    if (cards.onExpandStack == _expandStack) {
      cards.onExpandStack = null;
    }
    if (cards.onCollapseStack == _collapseStackOf) {
      cards.onCollapseStack = null;
    }
  }

  // ---- drag-and-drop (Story 10.10) ----

  void _attachDrag(GraphDrag? drag) {
    drag
      ?..addListener(_dragChanged)
      ..toViewport = _toViewport;
  }

  void _detachDrag(GraphDrag? drag) {
    drag?.removeListener(_dragChanged);
    if (drag != null && drag.toViewport == _toViewport) {
      drag.toViewport = null;
    }
  }

  Rect? _toViewport(Rect global) {
    final Offset? at = _viewport.toLocal(global.topLeft);
    return at == null ? null : at & global.size;
  }

  void _dragChanged() {
    final GraphDrag drag = widget.drag!;
    final bool active = drag.active;
    if (active && !_dragActive) {
      // Drag start: no peek, no tooltip, no gap callout; the auto-scroll arms once the pointer is well inside.
      _closeGap();
      _peekTimer?.cancel();
      _tipTimer?.cancel();
      _peekTimer = _tipTimer = null;
      _peekTimerKey = null;
      _tipPending = null;
      _peekKey = null;
      _tip = null;
      _autoScrollArmed = false;
      if (!_autoScroll.isActive) {
        _autoScroll.start();
      }
    } else if (!active && _dragActive) {
      _autoScroll.stop();
      _dragPointer = null;
    }
    _dragActive = active;
    if (active && drag.pointer != _dragPointer) {
      _dragPointer = drag.pointer;
      _resolveDropTarget();
    }
    widget.cards.dropTarget.value = drag.menuOpen || active ? drag.highlightedTarget : null;
    if (!drag.menuOpen) {
      // A menu is hit-tested only once its layer was built for the current target.
      _menuRect = null;
    }
    // Only what the build reads rebuilds the canvas; a pointer move alone does not.
    final Object seen = (
      active,
      drag.afterDrop,
      drag.payload,
      drag.target,
      drag.menuOpen,
      drag.highlight,
      drag.rows,
    );
    if (mounted && seen != _dragSeen) {
      _dragSeen = seen;
      setState(() {});
    }
  }

  Object? _dragSeen;

  /// The drag's target from its pointer: the open menu's row, else the top-most card in the unobscured area that is
  /// neither the source nor a stack.
  void _resolveDropTarget() {
    final GraphDrag drag = widget.drag!;
    final Offset? local = _viewport.toLocal(drag.pointer);
    final Rect? area = _viewport.unobscured;
    final Rect? menu = drag.menuOpen ? _menuRect : null;
    if (local != null && menu != null && menu.contains(local)) {
      final List<GraphDropRow> rows = drag.rows ?? const <GraphDropRow>[];
      final List<Rect> rects = graphDropMenuGeometry(rows, above: _menuAbove).rows;
      final Offset inMenu = local - menu.topLeft;
      drag.hover(drag.target, menuRow: rects.indexWhere((r) => r.contains(inMenu)));
      return;
    }
    if (local != null && menu != null && menu.inflate(graphDropMenuGap).contains(local)) {
      // The gap between the card and its menu keeps the target, so the pointer can cross it.
      drag.hover(drag.target);
      return;
    }
    String? key = local != null && area != null && area.contains(local) ? _viewport.keyAt(drag.pointer) : null;
    final int? node = key == null ? null : widget.layout.indexOfKey(key);
    if (key == drag.payload?.key || (node != null && widget.layout.isStackNode(node))) {
      key = null;
    }
    drag.hover(key);
  }

  /// One frame of the auto-scroll: a 56 px zone inside the unobscured area, still active up to 24 px outside it,
  /// `ceil((56 − d) / 4)` px per frame per axis; armed once the pointer was more than 56 px inside on all sides.
  void _autoScrollTick(Duration _) {
    final GraphDrag? drag = widget.drag;
    final Offset? p = drag == null || !drag.active ? null : _viewport.toLocal(drag.pointer);
    final Rect? area = _viewport.unobscured;
    if (p == null || area == null || !_laidOut(_vertical) || !_laidOut(_horizontal)) {
      return;
    }
    if (!_autoScrollArmed) {
      _autoScrollArmed = area.deflate(graphAutoScrollZone).contains(p);
      return;
    }
    if (drag!.overMenu) {
      // A pointer resting on the open menu chooses a row; scrolling would slide the menu away under it.
      return;
    }
    final step = Offset(
      graphAutoScrollStep(area.left, area.right, p.dx),
      graphAutoScrollStep(area.top, area.bottom, p.dy),
    );
    if (step == Offset.zero) {
      return;
    }
    for (final (ScrollController c, double d) in <(ScrollController, double)>[
      (_horizontal, step.dx),
      (_vertical, step.dy),
    ]) {
      if (d != 0) {
        final ScrollPosition position = c.position;
        c.jumpTo(clampDouble(position.pixels + d, position.minScrollExtent, position.maxScrollExtent));
      }
    }
    // The cards moved under a resting pointer.
    _resolveDropTarget();
  }

  @override
  void dispose() {
    _detachDrag(widget.drag);
    _autoScroll.dispose();
    _unlisten(widget.cards);
    widget.minimapSource?.retract(_vertical);
    widget.pulse?.removeListener(_pulseChanged);
    widget.flash?.removeListener(_flashChanged);
    _peekTimer?.cancel();
    _tipTimer?.cancel();
    _gapTimer?.cancel();
    _gapCloseTimer?.cancel();
    _settle?.cancel();
    _transition.dispose();
    _dim.dispose();
    _pulse.dispose();
    _flash.dispose();
    _gapHover.dispose();
    _enter.dispose();
    _bracketRun.dispose();
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
    // A card menu suppresses the gap callout; a card under the pointer takes the hover from a gap.
    if (widget.cards.menuOpen.value != null) {
      _closeGap();
    } else if (widget.cards.hovered.value != null && _gapHover.value != null) {
      _setGapHover(null, null);
    }
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
        // A stack opens its member list instead of the peek, sooner (Story 10.17).
        final int? node = widget.layout.indexOfKey(key);
        final bool stack = node != null && widget.layout.isStackNode(node);
        _peekTimer = Timer(stack ? _motion.delayStackList : _motion.delayPeek, _openPeek);
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
    // A running transition holds the peek (its key stays pending) until it ends (Story 10.20).
    if (mounted && _moving != null && _transition.isAnimating) {
      return;
    }
    _peekTimerKey = null;
    if (!mounted || key == null || _viewport.isPanning || widget.cards.hovered.value != key) {
      return;
    }
    setState(() => _peekKey = _shownPeekKey = key);
  }

  // ---- stacks (Story 10.17) ----

  /// The run [key] is a member or the stack of, with the member a toggle keeps in place.
  ({int run, String anchor})? _runOfKey(String key) {
    final GraphLayout layout = widget.layout;
    final int? node = layout.indexOfKey(key);
    final int? run = node == null ? null : layout.runOf(node);
    return run == null ? null : (run: run, anchor: graphStackAnchorKey(layout, run));
  }

  /// A stack card asked to expand: its anchor member keeps the card's viewport rect, then the owner relays out.
  void _expandStack(String key) {
    final ValueChanged<String>? expand = widget.onExpandStack;
    final ({int run, String anchor})? run = _runOfKey(key);
    if (expand == null || run == null) {
      return;
    }
    _viewport.holdAnchor(run.anchor);
    expand(key);
  }

  /// A member's VoiceOver collapse action: as the bracket's button.
  void _collapseStackOf(String key) {
    final ({int run, String anchor})? run = _runOfKey(key);
    if (run != null && widget.layout.stackNodeOf(run.run) == null) {
      _collapseStack(run.run);
    }
  }

  /// A bracket's button: the stack takes the anchor member's viewport rect.
  void _collapseStack(int run) {
    final ValueChanged<String>? collapse = widget.onCollapseStack;
    if (collapse == null) {
      return;
    }
    final GraphLayout layout = widget.layout;
    _viewport.holdAnchor(graphStackAnchorKey(layout, run));
    _bracketRun.value = null;
    collapse(layout.keyOf(layout.runMembersOf(run).first));
  }

  /// The expanded run whose bracket is hot: a member hovered, or the bracket itself.
  int? _hotRun() {
    final String? hovered = widget.cards.hovered.value;
    final int? node = hovered == null ? null : widget.layout.indexOfKey(hovered);
    final int? run = node == null ? null : widget.layout.runOf(node);
    if (run != null && widget.layout.stackNodeOf(run) == null) {
      return run;
    }
    return _bracketRun.value;
  }

  /// The brackets of the expanded runs (plane coordinates): 7 px wide at the leftmost member's x − 16, from the newest
  /// member's top + 6 to the oldest member's bottom − 6.
  List<(int, Rect)> _brackets(VerticalLayout rows, GraphMetrics metrics) {
    final GraphLayout layout = widget.layout;
    return <(int, Rect)>[
      for (var run = 0; run < layout.runCount; run++)
        if (layout.stackNodeOf(run) == null) (run, _bracketOf(layout.runMembersOf(run), rows, metrics)),
    ];
  }

  Rect _bracketOf(List<int> members, VerticalLayout rows, GraphMetrics metrics) {
    double left = double.infinity;
    for (final member in members) {
      left = math.min(left, metrics.x(widget.layout.colOf(member)));
    }
    return Rect.fromLTRB(
      left - 16,
      rows.top(members.last) + 6,
      left - 9,
      rows.top(members.first) + metrics.cardHeight - 6,
    );
  }

  void _paintBrackets(Canvas canvas, Offset origin, Rect visible, List<(int, Rect)> brackets, GraphTheme theme) {
    if (brackets.isEmpty) {
      return;
    }
    final int? hot = _hotRun();
    for (final (int run, Rect rect) in brackets) {
      if (!rect.inflate(2).overlaps(visible)) {
        continue;
      }
      final Rect r = rect.shift(origin);
      final double radius = math.min(7, r.height / 2);
      canvas.drawPath(
        Path()
          ..moveTo(r.right, r.top)
          ..arcToPoint(Offset(r.left, r.top + radius), radius: Radius.circular(radius), clockwise: false)
          ..lineTo(r.left, r.bottom - radius)
          ..arcToPoint(Offset(r.right, r.bottom), radius: Radius.circular(radius), clockwise: false),
        Paint()
          ..color = run == hot ? theme.cardBorderHover : theme.cardBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  /// The brackets' hover strips (translucent: a press there still pans) and the hot run's collapse button (opaque).
  Widget _bracketLayer(List<(int, Rect)> brackets) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[_vertical, _horizontal, widget.cards.hovered, _bracketRun]),
    builder: (context, _) {
      // A position has clients before its viewport's first layout; it has no dimension or pixels until then.
      if (!_laidOut(_vertical) || !_laidOut(_horizontal)) {
        return const SizedBox.shrink();
      }
      final Offset shift = widget.insets.topLeft - Offset(_horizontal.offset, _vertical.offset);
      final size = Size(_horizontal.position.viewportDimension, _vertical.position.viewportDimension);
      final Rect view = Offset.zero & size;
      final int? hot = _hotRun();
      final GraphLayout layout = widget.layout;
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          for (final (int run, Rect rect) in brackets)
            if (Rect.fromLTRB(rect.left - 12, rect.top, rect.right + 8, rect.bottom).shift(shift) case final strip
                when strip.overlaps(view)) ...<Widget>[
              Positioned.fromRect(
                rect: strip,
                child: MouseRegion(
                  opaque: false,
                  hitTestBehavior: HitTestBehavior.translucent,
                  onEnter: (_) => _bracketRun.value = run,
                  onExit: (_) {
                    if (_bracketRun.value == run) {
                      _bracketRun.value = null;
                    }
                  },
                ),
              ),
              if (run == hot && widget.onCollapseStack != null)
                Positioned(
                  left: strip.left + 12 - 10,
                  // Centred on the strip's visible part: a run taller than the view keeps its button reachable.
                  top: strip.intersect(view).center.dy - 10,
                  width: 20,
                  height: 20,
                  child: _CollapseButton(
                    key: ValueKey<String>('graph-stack-collapse-${layout.keyOf(layout.runMembersOf(run).first)}'),
                    count: layout.runMembersOf(run).length,
                    onEnter: () => _bracketRun.value = run,
                    onPressed: () => _collapseStack(run),
                  ),
                ),
            ],
        ],
      );
    },
  );

  void _openTip() {
    final ({String key, GraphCardHoverArea area})? tip = _tipPending;
    _tipTimer = null;
    _tipPending = null;
    if (!mounted || tip == null || _viewport.isPanning) {
      return;
    }
    setState(() => _tip = tip);
  }

  // ---- gaps (Story 10.19) ----

  /// The placed gaps of the shown layout; null while a new layout is still being routed (the old placement's indices
  /// belong to the old layout).
  GraphGaps? get _currentGaps => identical(_gaps?.layout, widget.layout) ? _gaps : null;

  /// Where the plane's (0, 0) sits in the canvas's local coordinates.
  Offset get _planeShift => widget.insets.topLeft - Offset(_horizontal.offset, _vertical.offset);

  /// A hover over the canvas: the gap target under it (never over a card, while a menu is open or a pan runs).
  void _hoverAt(Offset local) {
    final GraphGaps? gaps = _currentGaps;
    final GraphEdgePainter? edges = identical(_edges?.layout, widget.layout) ? _edges : null;
    if (gaps == null || edges == null || !_vertical.hasClients || !_horizontal.hasClients) {
      return;
    }
    final GraphCardController cards = widget.cards;
    final Offset plane = local - _planeShift;
    final int? gap = cards.hovered.value != null || cards.menuOpen.value != null || _viewport.isPanning
        ? null
        : gaps.gapAt(plane, edges);
    _setGapHover(gap, plane);
  }

  void _setGapHover(int? gap, Offset? plane) {
    if (_gapHover.value != gap) {
      _gapHover.value = gap;
      _gapTimer?.cancel();
      _gapTimer = null;
      if (gap != null && gap != _gapOpen) {
        _gapPendingPoint = plane;
        _gapTimer = Timer(_motion.delayStackList, () => _openGap(gap));
      }
    }
    if (gap != null && gap == _gapOpen) {
      _gapCloseTimer?.cancel();
      _gapCloseTimer = null;
    } else if (_gapOpen != null && !_inGapCallout) {
      _scheduleGapClose();
    }
  }

  void _openGap(int gap) {
    _gapTimer = null;
    final GraphGaps? gaps = _currentGaps;
    if (!mounted || gaps == null || gap >= gaps.gaps.length || _viewport.isPanning || _gapHover.value != gap) {
      return;
    }
    final GraphGap g = gaps.gaps[gap];
    _gapCloseTimer?.cancel();
    _gapCloseTimer = null;
    setState(() {
      _gapOpen = gap;
      // A mark's point is its centre; a band's where the pointer rests.
      final Offset? at = _gapPendingPoint;
      _gapPoint = at == null || g.box.contains(at) ? g.point : at;
    });
  }

  void _scheduleGapClose() {
    _gapCloseTimer ??= Timer(const Duration(milliseconds: 180), () {
      _gapCloseTimer = null;
      if (mounted && !_inGapCallout && _gapHover.value != _gapOpen) {
        _closeGap();
      }
    });
  }

  /// Closes the callout and drops the pending one (a pan, a menu, a new layout).
  void _closeGap() {
    _gapTimer?.cancel();
    _gapCloseTimer?.cancel();
    _gapTimer = _gapCloseTimer = null;
    _inGapCallout = false;
    if (_gapHover.value != null) {
      _gapHover.value = null;
    }
    if (_gapOpen != null) {
      setState(() {
        _gapOpen = null;
        _gapPoint = null;
      });
    }
  }

  void _showGap(GraphGap gap) {
    final ValueChanged<GraphGapTarget>? show = widget.onShowGap;
    if (show == null) {
      return;
    }
    final GraphLayout layout = widget.layout;
    // Member keys, never a stack key: all() may fold a stack under another oldest member. An edge into a stack enters
    // its newest member.
    int entry(int node) => layout.isStackNode(node) ? layout.runMembersOf(layout.runOf(node)!).last : node;
    final int child = graphGapCommitNode(layout, gap.node);
    show(
      GraphGapTarget(
        child: layout.keyOf(child),
        commitId: layout.commitIdOf(child),
        targets: <String>[for (final int edge in gap.edges) layout.keyOf(entry(layout.parentOf(edge)))],
      ),
    );
  }

  Widget _gapLayer() {
    final int? open = _gapOpen;
    final GraphGaps? gaps = _currentGaps;
    final Offset? point = _gapPoint;
    final Rect? area = _viewport.unobscured;
    if (open == null || gaps == null || point == null || area == null || open >= gaps.gaps.length) {
      return const SizedBox.shrink();
    }
    final GraphGap gap = gaps.gaps[open];
    return CustomSingleChildLayout(
      delegate: _GapCalloutLayout(point: point + _planeShift, area: area),
      child: MouseRegion(
        onEnter: (_) {
          _inGapCallout = true;
          _gapCloseTimer?.cancel();
          _gapCloseTimer = null;
        },
        onExit: (_) {
          _inGapCallout = false;
          if (_gapHover.value != _gapOpen) {
            _scheduleGapClose();
          }
        },
        child: _GapFade(
          key: ValueKey<int>(open),
          child: GraphGapCallout(
            layout: widget.layout,
            gap: gap,
            content: widget.content,
            show: widget.showChange,
            onShow: widget.onShowGap == null
                ? null
                : () {
                    _showGap(gap);
                  },
          ),
        ),
      ),
    );
  }

  // ---- operations (Story 10.20) ----

  /// Runs [transition] from its start; a running one ends at once (the viewport starts from its landed rects).
  void _startTransition(GraphTransition transition) {
    _moving = transition;
    final String? key = transition.born;
    _bornEdges = _bornEdgesOf(transition);
    // After the glide, so the reveal scrolls from where the cards landed.
    _bornReveal = key;
    _transition.forward(from: 0);
    if (transition.flash.isNotEmpty) {
      _flashKeys = transition.flash;
      _flash.forward(from: 0);
    }
    if (key != null && _motion.durFlip == Duration.zero) {
      // No glide: after the frame that lays the new layout out.
      SchedulerBinding.instance.addPostFrameCallback((_) => _revealBorn(transition));
    }
  }

  /// The edges of [transition]'s born card in its `to`, when it grows (the viewport's rule: a key new in `from` grown
  /// out of an anchor `from` shows).
  static Set<int> _bornEdgesOf(GraphTransition transition) {
    final GraphLayout layout = transition.to;
    final String? key = transition.born;
    final bool grows =
        key != null &&
        transition.from.indexOfKey(key) == null &&
        transition.anchor != null &&
        transition.from.placeOfKey(transition.anchor!) != null;
    final int? born = grows ? layout.placeOfKey(key) : null;
    return born == null
        ? const <int>{}
        : <int>{
            for (int e = layout.parentEdges(born).start; e < layout.parentEdges(born).end; e++) e,
            for (int s = layout.childEdges(born).start; s < layout.childEdges(born).end; s++) layout.childEdgeAt(s),
          };
  }

  /// Reveals the born card of [transition] once, while it (or a continuation of it) still runs or just completed.
  void _revealBorn(GraphTransition transition) {
    final String? key = _bornReveal;
    if (!mounted || key == null || !transition.continues(_moving)) {
      return;
    }
    _bornReveal = null;
    if (widget.layout.placeOfKey(key) != null) {
      _viewport.reveal(key, alignment: GraphRevealAlignment.covered, animate: true);
    }
  }

  /// The transition's tick: the born reveal when the glide has landed.
  void _transitionTicked() {
    final GraphTransition? moving = _moving;
    if (moving != null &&
        _bornReveal != null &&
        _motion.durFlip > Duration.zero &&
        _transition.duration! * _transition.value >= _motion.durFlip) {
      _revealBorn(moving);
    }
  }

  void _transitionStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _moving = null);
      _openWaitingPeek();
    }
  }

  /// A peek that waited for the transition opens now.
  void _openWaitingPeek() {
    if (_peekTimerKey != null && _peekTimer == null) {
      _openPeek();
    }
  }

  /// How far the running transition is; null when none runs.
  Duration? get _transitionElapsed =>
      _moving != null && _transition.isAnimating ? _transition.duration! * _transition.value : null;

  // ---- the gap reveal's flash (Story 10.19) ----

  void _flashChanged() {
    final GraphFlash? flash = widget.flash?.value;
    if (flash == null || flash == _lastFlash) {
      return;
    }
    _lastFlash = flash;
    setState(() => _flashKeys = flash.keys);
    _flash.forward(from: 0);
  }

  void _flashStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _flashKeys = const <String>{});
    }
  }

  /// The flash (DS components/graph/graph.css:83-85): a 2 px `--accent-live-line` ring plus a 6 px
  /// `--accent-live-ring` one, held for 35 % of `--dur-flash`, then fading out; the rings shrink with the fade, held
  /// at their size under reduce motion. A collapsed stack with a flashed member flashes as one card.
  void _paintFlash(Canvas canvas, Offset origin, Rect visible, VerticalLayout rows, GraphMetrics metrics, ZsColors c) {
    if (_flashKeys.isEmpty || !_flash.isAnimating) {
      return;
    }
    final double t = _flash.value;
    final double fade = t <= .35 ? 1 : 1 - _motion.easeState.transform((t - .35) / .65);
    final double size = _motion.motion == 0 ? 1 : fade;
    final GraphLayout layout = widget.layout;
    final painted = <int>{};
    for (final String key in _flashKeys) {
      final int? node = layout.placeOfKey(key);
      if (node == null || !painted.add(node) || layout.rowOf(node) < 0) {
        continue;
      }
      final card = Rect.fromLTWH(
        metrics.x(layout.colOf(node)),
        rows.top(node),
        metrics.cardWidth,
        metrics.cardHeight,
      );
      if (!card.inflate(8).overlaps(visible)) {
        continue;
      }
      final Rect r = card.shift(origin);
      final radius = Radius.circular(metrics.radius);
      final inner = RRect.fromRectAndRadius(r, radius);
      final double ring = 6 * size;
      final double line = 2 * size;
      canvas
        ..drawDRRect(
          RRect.fromRectAndRadius(r.inflate(ring), Radius.circular(metrics.radius + ring)),
          inner,
          Paint()..color = c.accentLiveRing.withValues(alpha: c.accentLiveRing.a * fade),
        )
        ..drawDRRect(
          RRect.fromRectAndRadius(r.inflate(line), Radius.circular(metrics.radius + line)),
          inner,
          Paint()..color = c.accentLiveLine.withValues(alpha: c.accentLiveLine.a * fade),
        );
    }
  }

  /// A canvas pan: no peek, no tooltip, no gap callout.
  void _userPanned(double amount) {
    _closeGap();
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
    final int? node = key == null ? null : widget.layout.placeOfKey(key);
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
  Widget _card(BuildContext context, int node) {
    final GraphLayout layout = widget.layout;
    final Widget card = layout.isStackNode(node)
        ? GraphStackCard(layout: layout, node: node, controller: widget.cards, content: widget.content)
        : GraphCard(layout: layout, node: node, controller: widget.cards, content: widget.content);
    return _enterKeys.contains(layout.keyOf(node)) ? _Entering(animation: _enter, motion: _motion, child: card) : card;
  }

  /// The rows, built once per layout and remapped once per metrics change.
  VerticalLayout _rowsFor(GraphMetrics metrics) {
    final VerticalLayout? rows = _rows;
    if (rows != null && rows.layout == widget.layout) {
      return rows.metrics == metrics ? rows : _rows = rows.withMetrics(metrics);
    }
    // The end stub under the oldest row needs room (Story 10.19).
    return _rows = UniformRows(widget.layout, metrics, bottomExtra: graphGapsBottomExtraOf(widget.layout));
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
  /// geometry is being routed; with it the gaps placed on that geometry (Story 10.19, once per geometry and
  /// clearance), whose cuts the painter breaks its dashed lines with.
  GraphEdgePainter? _edgesFor(GraphMetrics metrics, GraphTheme theme, VerticalLayout rows) {
    final RouteGeometry? geometry = _routes.geometryFor(widget.layout, metrics);
    if (geometry == null) {
      return null;
    }
    GraphGaps? gaps = _gaps;
    if (gaps == null || !identical(gaps.geometry, geometry) || gaps.clearance != theme.gapClearance) {
      gaps = _gaps = GraphGaps.compute(
        layout: widget.layout,
        geometry: geometry,
        rows: rows,
        clearance: theme.gapClearance,
      );
    }
    final GraphEdgePainter? edges = _edges;
    if (edges != null &&
        identical(edges.geometry, geometry) &&
        edges.theme == theme &&
        identical(edges.gapCuts, gaps.cuts)) {
      return edges;
    }
    return _edges = GraphEdgePainter(layout: widget.layout, geometry: geometry, theme: theme, gapCuts: gaps.cuts);
  }

  @override
  Widget build(BuildContext context) {
    final metrics = GraphMetrics.fromOptions(widget.options);
    final VerticalLayout rows = _rowsFor(metrics);
    final GraphTheme theme = GraphTheme.of(context);
    final GraphDayAxisPainter axis = _axisFor(rows, theme);
    final GraphEdgePainter? edges = _edgesFor(metrics, theme, rows);
    final GraphGaps? gaps = edges == null ? null : _gaps;
    final elided = '~ ${context.l10n.gapElided}'; // l10n-ignore: jj's end-of-history mark
    final double leftInset = widget.insets.left;
    final ZsColors colors = ZsColors.of(context);
    final Color accent = colors.accent;
    final GraphCardController cards = widget.cards;
    final double disabledOpacity = ZsMetrics.of(context).disabledOpacity;
    final pending = <int>{
      // A pending folded member gives its stack card the pending look.
      for (final String key in widget.pendingKeys) ?widget.layout.placeOfKey(key),
    };
    final List<(int, Rect)> brackets = _brackets(rows, metrics);
    // Story 10.10: the dragged card paints at .35; it and the target stay laid out (pinned).
    final GraphDrag? drag = widget.drag;
    final String? dragSource = drag == null || !(drag.active || drag.afterDrop) ? null : drag.payload?.key;
    final int? sourceNode = dragSource == null ? null : widget.layout.placeOfKey(dragSource);
    final String? dragTarget = drag == null || !(drag.active || drag.afterDrop) ? null : drag.target;
    // After layout: the layout, the insets or the size may have moved @ in or out of view.
    SchedulerBinding.instance.addPostFrameCallback((_) => _measureDirection());
    final GraphMinimapSource? minimap = widget.minimapSource;
    if (minimap != null) {
      final frame = GraphMinimapFrame(
        layout: widget.layout,
        rows: rows,
        metrics: metrics,
        geometry: _routes.geometryFor(widget.layout, metrics),
        insets: widget.insets,
        vertical: _vertical,
        horizontal: _horizontal,
      );
      // After this frame: the minimap is a sibling slot, which must not rebuild while this one builds.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(widget.minimapSource, minimap)) {
          minimap.publish(frame);
        }
      });
    }
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
              listenable: Listenable.merge(<Listenable>[
                cards.selected,
                cards.hovered,
                cards.menuOpen,
                _dim,
                _pulse,
                _flash,
                _bracketRun,
                _gapHover,
                _transition,
              ]),
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
                final Duration? elapsed = _transitionElapsed;
                final double ms = (elapsed?.inMicroseconds ?? 0) / 1000;
                // The edge layer: hidden while the cards glide, then fading back (Story 10.20).
                final double layer = elapsed == null
                    ? 1
                    : elapsed < _motion.durFlip
                    ? 0
                    : _motion.easeState.transform(
                        clampDouble((ms - _motion.durFlip.inMilliseconds) / _motion.durSlide.inMilliseconds, 0, 1),
                      );
                // The born card's edges draw in on their own, except under reduce motion.
                final Set<int>? born = elapsed == null || _motion.durFlip == Duration.zero || _bornEdges.isEmpty
                    ? null
                    : _bornEdges;
                final double drawn = born == null
                    ? 1
                    : _motion.easeState.transform(
                        clampDouble(
                          (ms - graphBornEdgeDelay.inMilliseconds) / graphBornEdgeDraw.inMilliseconds,
                          0,
                          1,
                        ),
                      );
                void paintLayer(PaintingContext context, Offset origin, Rect visible) {
                  edges?.paint(context, origin, visible, highlight: highlight, except: born);
                  if (edges != null) {
                    gaps?.paint(
                      context.canvas,
                      origin,
                      visible,
                      edges: edges,
                      label: elided,
                      highlight: highlight,
                      hovered: _gapHover.value,
                    );
                  }
                  _paintBrackets(context.canvas, origin, visible, brackets, theme);
                }

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
                  pinnedKeys: <String>{?menu, ?_peekKey, ?_pulseKey, ?dragSource, ?dragTarget},
                  opacityOf: (focus == null || dim == 0) && pending.isEmpty && sourceNode == null
                      ? null
                      : (node) =>
                            (node == sourceNode ? graphDragSourceOpacity : 1) *
                            (pending.contains(node) ? disabledOpacity : 1) *
                            (focus == null || focus[node] != 0 ? 1 : 1 - .6 * dim),
                  anchorKey: widget.anchorHint ?? cards.selected.value,
                  reveal: widget.reveal,
                  onUserPan: _userPanned,
                  paintBackground: axis.paintGuides,
                  // The gap marks after the edges, the brackets after them, never dimmed (Stories 10.17, 10.19); the flash
                  // last — under the cards, like the DS's box-shadow, so it never crosses a card's legend pill.
                  paintEdges: edges == null && brackets.isEmpty && _flashKeys.isEmpty
                      ? null
                      : (context, origin, visible) {
                          if (layer >= 1) {
                            paintLayer(context, origin, visible);
                          } else if (layer > 0) {
                            context.pushOpacity(
                              Offset.zero,
                              Color.getAlphaFromOpacity(layer),
                              (context, _) => paintLayer(context, origin, visible),
                            );
                          }
                          if (born != null && drawn > 0) {
                            edges?.paint(context, origin, visible, highlight: highlight, only: born, drawn: drawn);
                          }
                          _paintFlash(context.canvas, origin, visible, rows, metrics, colors);
                        },
                  transition: elapsed == null ? null : _moving,
                  transitionElapsed: elapsed ?? Duration.zero,
                  paintOverlay: (context, origin, visible) {
                    axis.paintLabels(context, origin, visible, leftInset: leftInset);
                    _paintPulse(context.canvas, origin, rows, metrics, accent);
                  },
                );
              },
            ),
          ),
        ),
        // The gap targets (Story 10.19): a translucent sibling above the viewport that only hovers — it hits nothing,
        // so a press on a band still pans and the cards keep their own hover.
        Positioned.fill(
          child: MouseRegion(
            opaque: false,
            hitTestBehavior: HitTestBehavior.translucent,
            onHover: (event) => _hoverAt(event.localPosition),
            onExit: (_) => _setGapHover(null, null),
          ),
        ),
        if (brackets.isNotEmpty) _bracketLayer(brackets),
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
        if (_gapOpen != null)
          ListenableBuilder(
            listenable: Listenable.merge(<Listenable?>[_vertical, _horizontal, widget.content]),
            builder: (context, _) => _gapLayer(),
          ),
        if (drag != null && drag.menuOpen)
          ListenableBuilder(
            listenable: Listenable.merge(<Listenable>[_vertical, _horizontal, drag]),
            builder: (context, _) => _dropMenuLayer(drag),
          ),
      ],
    );
  }

  /// The drop menu over its target, re-placed on every scroll frame (it scrolls with its card).
  Widget _dropMenuLayer(GraphDrag drag) {
    final String? target = drag.target;
    final List<GraphDropRow>? rows = drag.rows;
    final Rect? card = target == null ? null : _viewport.cardRectOf(target);
    final Rect? area = _viewport.unobscured;
    if (!drag.menuOpen || rows == null || rows.isEmpty || card == null || area == null) {
      _menuRect = null;
      return const SizedBox.shrink();
    }
    final Size size = graphDropMenuGeometry(rows, above: false).size;
    final ({Offset topLeft, bool above}) place = graphDropMenuPlacement(card, size, area);
    _menuRect = place.topLeft & size;
    _menuAbove = place.above;
    final Widget menu = GraphDropMenu(
      key: ValueKey<String>('graph-drop-menu-$target'),
      rows: rows,
      highlight: drag.highlight,
      above: place.above,
      onChoose: drag.afterDrop ? (index) => unawaited(drag.choose(index)) : null,
      onPoint: drag.afterDrop ? drag.point : null,
    );
    return Positioned(
      left: place.topLeft.dx,
      top: place.topLeft.dy,
      child: drag.afterDrop ? TapRegion(onTapOutside: (_) => drag.cancel(), child: menu) : IgnorePointer(child: menu),
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
    if (widget.layout.isStackNode(node)) {
      return GraphStackPopover(
        layout: widget.layout,
        node: node,
        card: card,
        area: area,
        controller: cards,
        closing: closing,
        content: widget.content,
      );
    }
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
                operationId: widget.layout.operationId,
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

class _GapCalloutLayout extends SingleChildLayoutDelegate {
  _GapCalloutLayout({required this.point, required this.area});

  final Offset point;
  final Rect area;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => graphGapCalloutPosition(point, childSize, area);

  @override
  bool shouldRelayout(_GapCalloutLayout oldDelegate) => point != oldDelegate.point || area != oldDelegate.area;
}

/// The gap callout's entrance: a fade on `--dur-pop` (design/graph.css:315 `ggap-in`).
class _GapFade extends StatefulWidget {
  const _GapFade({required this.child, super.key});

  final Widget child;

  @override
  State<_GapFade> createState() => _GapFadeState();
}

class _GapFadeState extends State<_GapFade> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = ZsMotion.of(context).durPop;
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
  Widget build(BuildContext context) => FadeTransition(opacity: _controller, child: widget.child);
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

/// An expand's entering card (Story 10.17): opacity 0 → 1 on `--dur-slide`, a 6 px rise and scale .98 → 1, all on
/// `--ease-glide`, the distances × `--motion` — paint-only, on the canvas's one ticker.
class _Entering extends StatelessWidget {
  const _Entering({required this.animation, required this.motion, required this.child});

  final Animation<double> animation;
  final ZsMotion motion;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final double rest = 1 - motion.easeGlide.transform(animation.value);
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.translationValues(0, 6 * motion.motion * rest, 0)
          ..scaleByDouble(1 - .02 * motion.motion * rest, 1 - .02 * motion.motion * rest, 1, 1),
        child: Opacity(opacity: 1 - rest, child: child),
      );
    },
    child: child,
  );
}

/// An expanded run's collapse button (Story 10.17): a 20 px circle with the `stack-collapse` glyph on the bracket's
/// left edge, in the card affordances' look; opaque, so a press on it never pans.
class _CollapseButton extends StatefulWidget {
  const _CollapseButton({required this.count, required this.onEnter, required this.onPressed, super.key});

  final int count;
  final VoidCallback onEnter;
  final VoidCallback onPressed;

  @override
  State<_CollapseButton> createState() => _CollapseButtonState();
}

class _CollapseButtonState extends State<_CollapseButton> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final GraphTheme t = GraphTheme.of(context);
    final String label = context.l10n.stackCollapseTooltip(widget.count);
    return ZsTooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        onTap: widget.onPressed,
        child: MouseRegion(
          onEnter: (_) {
            widget.onEnter();
            setState(() => _hovered = true);
          },
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _hovered ? t.cardFillHover : t.cardFill,
                border: Border.all(color: _hovered ? t.cardBorderHover : t.cardBorder),
              ),
              child: Center(
                child: ZanshinIcon(
                  ZI.stackCollapse,
                  size: ZsIconSize.sm,
                  color: _hovered ? t.cardText : t.cardTextFaint,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
