// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show RouteGeometry;
import 'package:zanshin_ui/zanshin_ui.dart';

import 'day_axis.dart';
import 'graph_card.dart';
import 'graph_edges.dart';
import 'graph_layout.dart';
import 'graph_metrics.dart';
import 'graph_viewport.dart';
import 'vertical_layout.dart';

const _dayMs = 86400000;

/// A viewport over [layout] with commit cards (Story 10.3), router B's edges (Story 10.4) and Free's day axis (Story
/// 10.2): the composition the catalogue and `GraphView` share (Story 10.5). It owns its scroll controllers, its rows
/// (once per layout, remapped per metrics change), its day-axis painter (rebuilt when the rows, the theme or the local
/// day of [cards]' "now" change) and its edge painter; its [GraphRouteCache] runs the route's class stage once per
/// layout and its geometry once per card size (in `Isolate.run` above `routeSyncNodeLimit` nodes; edges appear when it
/// completes). The hovered card's edges are hovered, @'s lineage is on, the selection is the anchor while it is on
/// screen.
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
    this.onUserScroll,
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

  /// Receives user scrolling.
  final ValueChanged<double>? onUserScroll;

  @override
  State<GraphCanvas> createState() => _GraphCanvasState();
}

class _GraphCanvasState extends State<GraphCanvas> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  VerticalLayout? _rows;
  GraphDayAxisPainter? _axis;
  VerticalLayout? _axisRows;
  int? _axisDay;
  late final _routes = GraphRouteCache(onRouted: () => setState(() {}));
  GraphEdgePainter? _edges;

  // The axes whose drag has delivered an update since their last scroll end.
  final _dragged = <Axis>{};

  @override
  void initState() {
    super.initState();
    widget.cards.now.addListener(_nowChanged);
  }

  @override
  void didUpdateWidget(GraphCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cards, widget.cards)) {
      oldWidget.cards.now.removeListener(_nowChanged);
      widget.cards.now.addListener(_nowChanged);
    }
  }

  @override
  void dispose() {
    widget.cards.now.removeListener(_nowChanged);
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
      GraphCard(layout: widget.layout, node: node, controller: widget.cards);

  /// The rows, built once per layout and remapped once per metrics change.
  VerticalLayout _rowsFor(GraphMetrics metrics) {
    final VerticalLayout? rows = _rows;
    if (rows != null && rows.layout == widget.layout) {
      return rows.metrics == metrics ? rows : _rows = rows.withMetrics(metrics);
    }
    return _rows = UniformRows(widget.layout, metrics);
  }

  /// The day-axis painter, recreated (the old one disposed) when the rows, the theme or the local day change.
  GraphDayAxisPainter _axisFor(VerticalLayout rows, GraphTheme theme) {
    final int nowMs = widget.cards.now.value;
    final int day = _dayOf(nowMs);
    final GraphDayAxisPainter? axis = _axis;
    if (axis != null && identical(_axisRows, rows) && axis.theme == theme && _axisDay == day) {
      return axis;
    }
    axis?.dispose();
    _axisRows = rows;
    _axisDay = day;
    return _axis = GraphDayAxisPainter(
      axis: GraphDayAxis.of(widget.layout, rows),
      theme: theme,
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
    final GraphCardController cards = widget.cards;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      // The viewport's z-order follows the card controller; rebuilding it builds no card.
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[cards.selected, cards.hovered, cards.menuOpen]),
        builder: (context, _) {
          final String? menu = cards.menuOpen.value;
          final String? hoveredKey = cards.hovered.value;
          final highlight = GraphEdgeHighlight(
            hoveredNode: hoveredKey == null ? null : widget.layout.indexOfKey(hoveredKey),
          );
          return GraphViewport(
            layout: widget.layout,
            metrics: metrics,
            verticalLayout: rows,
            cardBuilder: _card,
            verticalController: _vertical,
            horizontalController: _horizontal,
            insets: widget.insets,
            selectedKey: cards.selected.value,
            hoveredKey: hoveredKey,
            pinnedKeys: menu == null ? const <String>{} : <String>{menu},
            anchorKey: cards.selected.value,
            reveal: widget.reveal,
            onUserPan: widget.onUserScroll,
            paintBackground: axis.paintGuides,
            paintEdges: edges == null
                ? null
                : (context, origin, visible) => edges.paint(context, origin, visible, highlight: highlight),
            paintOverlay: (context, origin, visible) =>
                axis.paintLabels(context, origin, visible, leftInset: leftInset),
          );
        },
      ),
    );
  }
}
