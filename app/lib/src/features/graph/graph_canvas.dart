// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

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
import 'graph_stack_card.dart';
import 'graph_stack_popover.dart';
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
    this.inspectorOpen = false,
    this.entering,
    this.onExpandStack,
    this.onCollapseStack,
    super.key,
  });

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

  // Story 10.17: the expand's fade-in (one ticker for every entering card) and the hovered bracket's run.
  late final _enter = AnimationController(vsync: this, value: 1);
  var _enterKeys = const <String>{};
  final _bracketRun = ValueNotifier<int?>(null);

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
    _enter.duration = _motion.durSlide;
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

  @override
  void dispose() {
    _unlisten(widget.cards);
    widget.pulse?.removeListener(_pulseChanged);
    _peekTimer?.cancel();
    _tipTimer?.cancel();
    _settle?.cancel();
    _dim.dispose();
    _pulse.dispose();
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
      if (!_vertical.hasClients || !_horizontal.hasClients) {
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
                  top: strip.center.dy - 10,
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
      // A pending folded member gives its stack card the pending look.
      for (final String key in widget.pendingKeys) ?widget.layout.placeOfKey(key),
    };
    final List<(int, Rect)> brackets = _brackets(rows, metrics);
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
              listenable: Listenable.merge(<Listenable>[
                cards.selected,
                cards.hovered,
                cards.menuOpen,
                _dim,
                _pulse,
                _bracketRun,
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
                  // The brackets after the edges, never dimmed (Story 10.17).
                  paintEdges: edges == null && brackets.isEmpty
                      ? null
                      : (context, origin, visible) {
                          edges?.paint(context, origin, visible, highlight: highlight);
                          _paintBrackets(context.canvas, origin, visible, brackets, theme);
                        },
                  paintOverlay: (context, origin, visible) {
                    axis.paintLabels(context, origin, visible, leftInset: leftInset);
                    _paintPulse(context.canvas, origin, rows, metrics, accent);
                  },
                );
              },
            ),
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
