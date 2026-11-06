// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show RouteGeometry;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../shell/shell_scope.dart';
import 'day_axis.dart';
import 'graph_card.dart' show graphLocalDay;
import 'graph_layout.dart';
import 'graph_metrics.dart';
import 'graph_view_model.dart';
import 'minimap_raster.dart';
import 'vertical_layout.dart';

// The design's constants (graph-view.jsx `minimapSize`, sync #22; DS ui_kits/desktop/kit.css:155-172), CSS px.

/// The strip's inset in the card (kit.css:157, `inset:12px 8px`).
const minimapStripInset = EdgeInsets.symmetric(vertical: 12, horizontal: 8);

/// The split between the day labels (left) and the graph's dots (right) (`MINI_SPLIT`).
const double minimapSplit = 58;

/// The largest x scale (`MINI_KX`): one column ≈ 12 px.
const _kxMax = 0.04;

/// The graph part's padding on either side (`MINI_PAD`).
const double _pad = 8;

/// The graph part's least and largest width (`MINI_GW_MIN`, `MINI_GW_MAX`).
const double _graphMin = 60;
const double _graphMax = 160;

/// The least height of one pitch on the strip (`MINI_MIN_PITCH`): a taller history scrolls the minimap.
const double minimapMinPitch = 2;

/// The minimap's size for a graph whose laid-out card centres span `span` px in x (Story 10.31, design graph-view.jsx
/// `minimapSize`): the graph part [graph] = clamp(span · 0.04 + 16, 60, 160), the [strip] = 58 + graph, the [card] =
/// strip + 16 and the x scale [kx] (0.04, less once the graph part is full).
@immutable
class MinimapSize {
  /// The size for [span].
  factory MinimapSize.of(double span) {
    final double graph = (span * _kxMax + 2 * _pad).clamp(_graphMin, _graphMax);
    final double strip = minimapSplit + graph;
    return MinimapSize._(graph, strip, span > 0 ? math.min(_kxMax, (graph - 2 * _pad) / span) : 0);
  }

  const MinimapSize._(this.graph, this.strip, this.kx);

  /// The graph part's width.
  final double graph;

  /// The strip's width.
  final double strip;

  /// The x scale.
  final double kx;

  /// The card's width.
  double get card => strip + 2 * _pad;
}

/// The card width without a graph: the token `--minimap-w` (134).
final double minimapDefaultCardWidth = MinimapSize.of(0).card;

/// What the canvas hands the minimap (Story 10.16): its layout, rows, metrics, route geometry (null while routing),
/// insets and scroll controllers.
@immutable
class GraphMinimapFrame {
  /// A frame of one canvas build.
  const GraphMinimapFrame({
    required this.layout,
    required this.rows,
    required this.metrics,
    required this.geometry,
    required this.insets,
    required this.vertical,
    required this.horizontal,
  });

  /// The layout shown.
  final GraphLayout layout;

  /// The canvas's rows.
  final VerticalLayout rows;

  /// The card size.
  final GraphMetrics metrics;

  /// Router B's geometry, null while it is being routed.
  final RouteGeometry? geometry;

  /// The plane's live margins.
  final EdgeInsets insets;

  /// The canvas's vertical scroll controller.
  final ScrollController vertical;

  /// The canvas's horizontal scroll controller.
  final ScrollController horizontal;

  @override
  bool operator ==(Object other) =>
      other is GraphMinimapFrame &&
      identical(other.layout, layout) &&
      identical(other.rows, rows) &&
      other.metrics == metrics &&
      identical(other.geometry, geometry) &&
      other.insets == insets &&
      identical(other.vertical, vertical) &&
      identical(other.horizontal, horizontal);

  @override
  int get hashCode => Object.hash(
    identityHashCode(layout),
    identityHashCode(rows),
    metrics,
    identityHashCode(geometry),
    insets,
    identityHashCode(vertical),
    identityHashCode(horizontal),
  );
}

/// The canvas's current [GraphMinimapFrame] for the minimap in the shell's sibling slot (Story 10.16): the canvas
/// [publish]es after each build that changed it, and [retract]s on dispose.
class GraphMinimapSource extends ChangeNotifier {
  GraphMinimapFrame? _frame;
  var _disposed = false;
  final _cardWidth = ValueNotifier<double>(minimapDefaultCardWidth);

  // The x extent of the laid-out nodes' centres, per layout and metrics.
  GraphLayout? _extentLayout;
  GraphMetrics? _extentMetrics;
  (double, double) _extent = (0, 0);

  /// The current frame, null without a canvas.
  GraphMinimapFrame? get frame => _frame;

  /// The min and max centre x of the current frame's laid-out nodes; (0, 0) without any.
  (double, double) get extent => _extent;

  /// The minimap card's width for the current frame (Story 10.31): it follows the columns; [minimapDefaultCardWidth]
  /// without a frame. Notifies only when it changes.
  ValueListenable<double> get cardWidth => _cardWidth;

  /// Makes [frame] current; notifies only when it changed.
  void publish(GraphMinimapFrame frame) {
    if (_disposed || frame == _frame) {
      return;
    }
    _frame = frame;
    if (!identical(_extentLayout, frame.layout) || _extentMetrics != frame.metrics) {
      _extentLayout = frame.layout;
      _extentMetrics = frame.metrics;
      _extent = _extentOf(frame.layout, frame.metrics);
    }
    final (double x0, double x1) = _extent;
    // Published after the canvas's build: the shell rebuilds on the next frame.
    _cardWidth.value = MinimapSize.of(x1 - x0).card;
    notifyListeners();
  }

  /// Drops the frame of the canvas scrolled by [vertical], if it is still the current one. Called from the canvas's
  /// dispose, so its listeners hear it after a microtask, never while the tree is locked.
  void retract(ScrollController vertical) {
    if (_disposed || !identical(_frame?.vertical, vertical)) {
      return;
    }
    _frame = null;
    scheduleMicrotask(() {
      if (!_disposed) {
        _cardWidth.value = minimapDefaultCardWidth;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _cardWidth.dispose();
    super.dispose();
  }
}

/// A year boundary on the minimap in plane coordinates (Story 10.31): at `y`, `year` above it and `below` under it
/// (null at the history's oldest day, which opens its first year).
typedef MinimapYear = ({double y, int year, int? below});

/// The minimap's day labels in plane coordinates, ascending y (Story 10.16), with the year boundaries (ascending y)
/// and the breaks' centre ys (Story 10.31).
@immutable
class MinimapLabels {
  /// Labels at [ys] reading [texts].
  const MinimapLabels(
    this.ys,
    this.texts, {
    required this.free,
    this.years = const <MinimapYear>[],
    this.breaks = const <double>[],
    this.nowYear,
    this.silent = const <int>{},
    this.yearTexts = const <int, String>{},
  });

  /// No labels.
  static const empty = MinimapLabels(<double>[], <String>[], free: false);

  /// The labels the day lookup reads but nothing draws (Story 10.31): a day whose divider lies in a break.
  final Set<int> silent;

  /// Each year of [years] as its label text.
  final Map<int, String> yearTexts;

  /// The year boundaries, ascending y: the topmost first.
  final List<MinimapYear> years;

  /// The breaks' centre ys, in plane coordinates.
  final List<double> breaks;

  /// The current year at the layout's offset; a history that lies in it alone gets no sticky header.
  final int? nowYear;

  /// Each label's centre y in plane coordinates, ascending.
  final List<double> ys;

  /// Each label's text.
  final List<String> texts;

  /// Whether these are Free's day buckets (a day's label sits at its bottom) rather than Compact's rows.
  final bool free;

  /// The number of labels.
  int get length => ys.length;
}

/// The minimap's day labels of [layout] mapped by [rows] (graph-view.jsx:445-459):
/// - **Free:** one label per shown [GraphDayAxis] day at its label y, reading [graphDayLabel] of the bucket; the
///   axis's year boundaries and breaks (Story 10.31);
/// - **Compact:** per row the newest timestamp of its laid-out nodes (the root and nodes without one left out); a row
///   gets a label at its card centre only when its day ([graphLocalDay]) is older than the last label's; a year
///   boundary midway between two labels of different years.
MinimapLabels minimapLabels(
  GraphLayout layout,
  VerticalLayout rows, {
  required AppLocalizations strings,
  required int nowMs,
}) {
  final int offset = layout.utcOffsetMinutes;
  final int nowYear = graphYearOf(nowMs, utcOffsetMinutes: offset);
  String label(int day) => graphDayLabel(strings, day, nowMs: nowMs, utcOffsetMinutes: offset);
  Map<int, String> yearTexts(List<MinimapYear> years) => <int, String>{
    for (final MinimapYear y in years) ...<int, String>{
      y.year: graphYearLabel(strings, y.year),
      if (y.below case final int below) below: graphYearLabel(strings, below),
    },
  };
  if (layout.mode == GraphMode.free) {
    final axis = GraphDayAxis.of(layout, rows);
    // The shown days and the days dropped in a break (looked up, never drawn), ascending y.
    final days = <(double, int, bool)>[
      for (var b = 0; b < axis.length; b++) (axis.labelYs[b], axis.values[b], false),
      for (var b = 0; b < axis.droppedValues.length; b++) (axis.droppedYs[b], axis.droppedValues[b], true),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final years = <MinimapYear>[
      for (final GraphAxisYear y in axis.years.reversed) (y: y.y, year: y.year, below: y.below),
    ];
    return MinimapLabels(
      <double>[for (final (double y, _, _) in days) y],
      <String>[for (final (_, int value, _) in days) label(value)],
      free: true,
      years: years,
      breaks: <double>[for (final GraphAxisBreak b in axis.breaks.reversed) b.centre],
      nowYear: nowYear,
      silent: <int>{
        for (var i = 0; i < days.length; i++)
          if (days[i].$3) i,
      },
      yearTexts: yearTexts(years),
    );
  }
  final int? root = layout.rootIndex;
  final newest = <int, int>{};
  for (var node = 0; node < layout.nodeCount; node++) {
    final int row = layout.rowOf(node);
    final int? ts = layout.timestampOf(node);
    if (row < 0 || layout.isFolded(node) || node == root || ts == null) {
      continue;
    }
    final int? seen = newest[row];
    if (seen == null || ts > seen) {
      newest[row] = ts;
    }
  }
  // A higher row lies higher up: descending rows are ascending y.
  final List<int> order = newest.keys.toList()..sort((a, b) => b.compareTo(a));
  final ys = <double>[];
  final texts = <String>[];
  final labelYears = <int>[];
  double last = double.infinity;
  final double half = rows.metrics.cardHeight / 2;
  for (final row in order) {
    final int day = graphLocalDay(newest[row]!, utcOffsetMinutes: offset);
    if (day < last) {
      last = day.toDouble();
      ys.add(rows.topOfRow(row) + half);
      texts.add(label(day));
      labelYears.add(graphYearOf(day, utcOffsetMinutes: offset));
    }
  }
  final years = <MinimapYear>[
    for (var i = 1; i < ys.length; i++)
      if (labelYears[i] != labelYears[i - 1])
        (y: (ys[i - 1] + ys[i]) / 2, year: labelYears[i - 1], below: labelYears[i]),
    if (ys.isNotEmpty) (y: ys.last, year: labelYears.last, below: null),
  ];
  return MinimapLabels(ys, texts, free: false, years: years, nowYear: nowYear, yearTexts: yearTexts(years));
}

/// The day the minimap names at plane y [planeY] (graph-view.jsx:495-499): Free, the first label at or below
/// `planeY − 1`, else the last; Compact, the last label at or above `planeY + 1`, else the first. Null without labels.
String? minimapDayAt(MinimapLabels labels, double planeY) {
  if (labels.length == 0) {
    return null;
  }
  if (labels.free) {
    for (var i = 0; i < labels.length; i++) {
      if (labels.ys[i] >= planeY - 1) {
        return labels.texts[i];
      }
    }
    return labels.texts.last;
  }
  String pick = labels.texts.first;
  for (var i = 0; i < labels.length && labels.ys[i] <= planeY + 1; i++) {
    pick = labels.texts[i];
  }
  return pick;
}

/// Runs [rasterMinimap] somewhere; the default is another isolate.
typedef MinimapRasterRunner = Future<Uint8List> Function(MinimapRasterInput input);

Future<Uint8List> _isolateRaster(MinimapRasterInput input) => Isolate.run(() => rasterMinimap(input));

/// The plane → strip map of one frame and strip height (graph-view.jsx `GraphMinimap`, sync #22): x through
/// [MinimapSize], y at `k = max(stripH / total, 2 / pitch)`; content [over] the strip's height scrolls by [msOf].
@immutable
class MinimapMapping {
  const MinimapMapping._(this.k, this.kx, this.x1, this.top, this.strip, this.stripHeight, this.over);

  /// [frame]'s map onto a strip [stripHeight] tall, with the laid-out nodes' centre x [extent] (min, max).
  factory MinimapMapping.of(GraphMinimapFrame frame, double stripHeight, (double, double) extent) {
    final (double x0, double x1) = extent;
    final size = MinimapSize.of(x1 - x0);
    final EdgeInsets insets = frame.insets;
    final double total = math.max(1, frame.rows.contentHeight + insets.top + insets.bottom);
    final double pitch = frame.metrics.cardHeight + frame.metrics.gapY;
    final double k = math.max(stripHeight / total, minimapMinPitch / pitch);
    final double over = math.max(0, total * k - stripHeight);
    return MinimapMapping._(k, size.kx, x1, insets.top, size.strip, stripHeight, over);
  }

  /// Strip px per plane px in y.
  final double k;

  /// Strip px per plane px in x.
  final double kx;

  /// The rightmost centre x.
  final double x1;

  /// The plane's top inset.
  final double top;

  /// The strip's width.
  final double strip;

  /// The strip's height.
  final double stripHeight;

  /// How far the content overflows the strip: the minimap's scroll range.
  final double over;

  /// The content's height on the strip.
  double get contentHeight => stripHeight + over;

  /// The strip x of plane x [x].
  double mx(double x) => strip - 4 - (x1 - x) * kx;

  /// The content y of plane y [y]; the strip y is this less [msOf].
  double my(double y) => (y + top) * k;

  /// The plane y of strip y [sy] at scroll offset [ms].
  double planeY(double sy, double ms) => (sy + ms) / math.max(k, 1e-6) - top;

  /// The minimap's scroll offset at the canvas's [position]: 0 at the top to [over] at the bottom, in proportion.
  double msOf(ScrollPosition position) {
    if (over == 0 || !position.hasPixels || !position.hasContentDimensions) {
      return 0;
    }
    return over * (position.pixels / math.max(1, position.maxScrollExtent)).clamp(0, 1);
  }

  @override
  bool operator ==(Object other) =>
      other is MinimapMapping &&
      other.k == k &&
      other.kx == kx &&
      other.x1 == x1 &&
      other.top == top &&
      other.strip == strip &&
      other.stripHeight == stripHeight &&
      other.over == over;

  @override
  int get hashCode => Object.hash(k, kx, x1, top, strip, stripHeight, over);
}

/// The minimap's scroll offset for [frame] under [mapping]: 0 while the canvas has no position.
double _msOf(GraphMinimapFrame frame, MinimapMapping mapping) =>
    frame.vertical.hasClients ? mapping.msOf(frame.vertical.position) : 0;

/// Whether [node] has a place on the plane (not a folded stack member).
bool _laidOut(GraphLayout layout, int node) => layout.rowOf(node) >= 0 && !layout.isFolded(node);

/// The min and max centre x of [layout]'s laid-out nodes; (0, 0) without any.
(double, double) _extentOf(GraphLayout layout, GraphMetrics metrics) {
  double x0 = double.infinity;
  double x1 = double.negativeInfinity;
  for (var node = 0; node < layout.nodeCount; node++) {
    if (_laidOut(layout, node)) {
      final double x = metrics.x(layout.colOf(node)) + metrics.cardWidth / 2;
      x0 = math.min(x0, x);
      x1 = math.max(x1, x);
    }
  }
  return x0.isFinite ? (x0, x1) : (0, 0);
}

/// The raster input of [frame] on a strip [stripHeight] CSS px tall at [dpr] (Story 10.16): the laid-out nodes' plane
/// centres (x the card's centre, y `rows.top + cardHeight / 2`), the route polylines (none while
/// [GraphMinimapFrame.geometry] is null), the plane → device map and the colours [faint] (the out layer), [text] (the
/// in layer's nodes) and [muted] (its edges), each 0xAARRGGBB. The raster is the strip's width and covers the content
/// window [windowTop] (content px) down [windowHeight] (default the strip's height) — Story 10.31: a history taller
/// than the strip rasters at most three strip heights around the visible part.
MinimapRasterInput minimapRasterInput(
  GraphMinimapFrame frame,
  double stripHeight,
  double dpr, {
  required int faint,
  required int text,
  required int muted,
  double windowTop = 0,
  double? windowHeight,
}) {
  final GraphLayout layout = frame.layout;
  final GraphMetrics metrics = frame.metrics;
  final VerticalLayout rows = frame.rows;
  final mapping = MinimapMapping.of(frame, stripHeight, _extentOf(layout, metrics));
  final nodes = <int>[
    for (var node = 0; node < layout.nodeCount; node++)
      if (_laidOut(layout, node)) node,
  ];
  final xs = Float64List(nodes.length);
  final ys = Float64List(nodes.length);
  final stacks = Uint8List(nodes.length);
  for (var i = 0; i < nodes.length; i++) {
    final int node = nodes[i];
    xs[i] = metrics.x(layout.colOf(node)) + metrics.cardWidth / 2;
    ys[i] = rows.top(node) + metrics.cardHeight / 2;
    stacks[i] = layout.isStackNode(node) ? 1 : 0;
  }
  final (Int32List edgeStarts, Float64List edgePoints) = _centredEdges(frame);
  return MinimapRasterInput(
    nodeXs: xs,
    nodeYs: ys,
    nodeStacks: stacks,
    edgeStarts: edgeStarts,
    edgePoints: edgePoints,
    ax: dpr * (mapping.strip - 4 - mapping.x1 * mapping.kx),
    bx: dpr * mapping.kx,
    ay: dpr * (mapping.top * mapping.k - windowTop),
    by: dpr * mapping.k,
    dpr: dpr,
    width: (mapping.strip * dpr).round(),
    height: ((windowHeight ?? stripHeight) * dpr).round(),
    outNode: faint,
    outEdge: faint,
    inNode: text,
    inEdge: muted,
  );
}

/// [frame]'s route polylines (CSR offsets, x/y pairs) with each end carried on to its card's centre. The router runs
/// a line from the parent's top edge to the child's bottom edge; the minimap draws a card as a dot at its centre, and a
/// stretched strip would open a gap of half a card on either side of every dot (design sync #22).
(Int32List, Float64List) _centredEdges(GraphMinimapFrame frame) {
  final RouteGeometry? geometry = frame.geometry;
  if (geometry == null) {
    return (Int32List(1), Float64List(0));
  }
  final GraphLayout layout = frame.layout;
  final GraphMetrics metrics = frame.metrics;
  final int edges = math.min(geometry.pointStarts.length - 1, layout.edgeCount);
  final starts = Int32List(edges + 1);
  final points = <double>[];
  void centre(int node) => points
    ..add(metrics.x(layout.colOf(node)) + metrics.cardWidth / 2)
    ..add(frame.rows.top(node) + metrics.cardHeight / 2);
  for (var e = 0; e < edges; e++) {
    final int from = geometry.pointStarts[e];
    final int to = geometry.pointStarts[e + 1];
    final int parent = layout.parentOf(e);
    final int child = layout.childOf(e);
    final bool ends = to > from && _laidOut(layout, parent) && _laidOut(layout, child);
    if (ends) {
      centre(parent);
    }
    points.addAll(geometry.points.sublist(2 * from, 2 * to));
    if (ends) {
      centre(child);
    }
    starts[e + 1] = points.length ~/ 2;
  }
  return (starts, Float64List.fromList(points));
}

/// The raster's key: a change re-rasters (Story 10.16); [windowTop] and [windowHeight] are the content window it
/// covers (Story 10.31), [width] × [height] its device pixels.
@immutable
class _RasterKey {
  const _RasterKey(
    this.frame,
    this.top,
    this.bottom,
    this.stripHeight,
    this.windowTop,
    this.windowHeight,
    this.width,
    this.height,
    this.dpr,
    this.colors,
  );

  final GraphMinimapFrame frame;
  final double top;
  final double bottom;
  final double stripHeight;
  final double windowTop;
  final double windowHeight;
  final int width;
  final int height;
  final double dpr;
  final (int, int, int) colors;

  @override
  bool operator ==(Object other) =>
      other is _RasterKey &&
      identical(other.frame.layout, frame.layout) &&
      identical(other.frame.rows, frame.rows) &&
      other.frame.metrics == frame.metrics &&
      identical(other.frame.geometry, frame.geometry) &&
      other.top == top &&
      other.bottom == bottom &&
      other.stripHeight == stripHeight &&
      other.windowTop == windowTop &&
      other.windowHeight == windowHeight &&
      other.width == width &&
      other.height == height &&
      other.dpr == dpr &&
      other.colors == colors;

  @override
  int get hashCode => Object.hash(
    identityHashCode(frame.layout),
    identityHashCode(frame.rows),
    frame.metrics,
    identityHashCode(frame.geometry),
    top,
    bottom,
    stripHeight,
    windowTop,
    windowHeight,
    width,
    height,
    dpr,
    colors,
  );
}

/// The minimap (Story 10.16; design graph-view.jsx:440-541, DS ui_kits/desktop/kit.css:155-172): the whole graph in
/// dots on a glass card, the day labels left of [minimapSplit], the viewport band, @ and the selection, and the
/// current-day pill at the band's centre.
///
/// The dots and dotted edges are rasterised once per layout, card size, strip size and theme by [rasterMinimap] through
/// [runRaster] (another isolate by default; one raster in flight, the latest key re-rastered once after it) and
/// painted inside their own `RepaintBoundary`; scrolling, hover and the selection repaint only the overlay. A press or
/// drag jumps the graph vertically (nothing is selected); the wheel and trackpad over it scroll both axes; all of it
/// feeds the shell's calm scrolling.
class GraphMinimap extends StatefulWidget {
  /// The minimap of [model]'s canvas.
  const GraphMinimap({required this.model, this.runRaster = _isolateRaster, super.key});

  /// The graph's view model: the canvas's [GraphViewModel.minimapSource], the selection and "now".
  final GraphViewModel model;

  /// Runs a raster; tests pass a synchronous one.
  final MinimapRasterRunner runRaster;

  @override
  State<GraphMinimap> createState() => _GraphMinimapState();
}

enum _Text { label, pill, hoverPill, year }

class _GraphMinimapState extends State<GraphMinimap> {
  final _hover = ValueNotifier<double?>(null);
  var _dragging = false;

  // The content window the raster covers (Story 10.31), per mapping; the canvas controller watched for leaving it.
  MinimapMapping? _windowMapping;
  double _windowTop = 0;
  double _windowHeight = 0;
  ScrollController? _watched;

  // The labels, per rows, "now" and strings.
  VerticalLayout? _labelRows;
  int? _labelNow;
  AppLocalizations? _labelStrings;
  MinimapLabels _labels = MinimapLabels.empty;

  // The raster: the wanted key and its input, the last one rastered, one in flight, the images shown.
  ({_RasterKey key, MinimapRasterInput Function() input})? _wanted;
  _RasterKey? _done;
  var _running = false;
  ui.Image? _out;
  ui.Image? _in;
  _RasterKey? _shown;

  // The text painters, per text and kind, kept while the colours stay.
  final _texts = <String, TextPainter>{};
  ZsColors? _textColors;

  @override
  void dispose() {
    _watched?.removeListener(_scrolled);
    _hover.dispose();
    _out?.dispose();
    _in?.dispose();
    _clearTexts();
    super.dispose();
  }

  void _clearTexts() {
    for (final TextPainter painter in _texts.values) {
      painter.dispose();
    }
    _texts.clear();
  }

  TextPainter _text(String text, _Text kind, ZsColors colors) {
    if (!identical(_textColors, colors)) {
      _clearTexts();
      _textColors = colors;
    }
    return _texts.putIfAbsent('${kind.index}:$text', () {
      final TextStyle style = switch (kind) {
        _Text.label => ZsType.id.copyWith(fontSize: ZsType.fsXs, color: colors.textDim),
        _Text.pill => ZsType.id.copyWith(
          fontWeight: FontWeight.w600,
          fontVariations: const <ui.FontVariation>[ui.FontVariation.weight(600)],
          color: colors.text,
        ),
        _Text.hoverPill => ZsType.id.copyWith(color: colors.textMuted),
        _Text.year => graphYearStyle(colors),
      };
      return TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
    });
  }

  MinimapMapping _mappingOf(GraphMinimapFrame frame, double stripHeight) =>
      MinimapMapping.of(frame, stripHeight, widget.model.minimapSource.extent);

  /// The content window to raster for [mapping] at scroll offset [ms]: the whole strip while nothing overflows, else
  /// at most three strip heights around the visible strip; re-centred once the visible strip comes within half a
  /// strip height of an edge that is not the content's, so a fast scroll finds the next raster ready.
  (double, double) _windowFor(MinimapMapping mapping, double ms) {
    final double h = mapping.stripHeight;
    final double height = mapping.over == 0 ? h : math.min(mapping.contentHeight, 3 * h);
    if (mapping == _windowMapping && _windowHeight == height && _comfortable(mapping, ms)) {
      return (_windowTop, _windowHeight);
    }
    _windowMapping = mapping;
    _windowHeight = height;
    _windowTop = mapping.over == 0 ? 0 : (ms - h).clamp(0, mapping.contentHeight - height);
    return (_windowTop, _windowHeight);
  }

  /// Whether the visible strip at [ms] keeps half a strip height from each window edge that is not the content's.
  bool _comfortable(MinimapMapping mapping, double ms) {
    final double margin = mapping.stripHeight / 2;
    final double bottom = _windowTop + _windowHeight;
    final bool top = _windowTop <= .5 || ms >= _windowTop + margin;
    final bool end = bottom >= mapping.contentHeight - .5 || ms + mapping.stripHeight <= bottom - margin;
    return top && end;
  }

  /// Watches [controller] for a scroll that leaves the raster window.
  void _watch(ScrollController controller) {
    if (identical(_watched, controller)) {
      return;
    }
    _watched?.removeListener(_scrolled);
    _watched = controller..addListener(_scrolled);
  }

  void _scrolled() {
    final MinimapMapping? mapping = _windowMapping;
    final GraphMinimapFrame? frame = widget.model.minimapSource.frame;
    if (mapping == null || frame == null || mapping.over == 0) {
      return;
    }
    if (!_comfortable(mapping, _msOf(frame, mapping))) {
      setState(() {});
    }
  }

  MinimapLabels _labelsOf(GraphMinimapFrame frame, AppLocalizations strings) {
    final int now = widget.model.now.value;
    if (!identical(_labelRows, frame.rows) || _labelNow != now || !identical(_labelStrings, strings)) {
      _labelRows = frame.rows;
      _labelNow = now;
      _labelStrings = strings;
      _labels = minimapLabels(frame.layout, frame.rows, strings: strings, nowMs: now);
    }
    return _labels;
  }

  // ---- raster ----

  void _request(GraphMinimapFrame frame, MinimapMapping mapping, double dpr, ZsColors colors) {
    final (double windowTop, double windowHeight) = _windowFor(mapping, _msOf(frame, mapping));
    final int width = (mapping.strip * dpr).round();
    final int height = (windowHeight * dpr).round();
    if (width <= 0 || height <= 0) {
      return;
    }
    final (int, int, int) ink = (colors.textFaint.toARGB32(), colors.text.toARGB32(), colors.textMuted.toARGB32());
    final key = _RasterKey(
      frame,
      frame.insets.top,
      frame.insets.bottom,
      mapping.stripHeight,
      windowTop,
      windowHeight,
      width,
      height,
      dpr,
      ink,
    );
    if (key == _wanted?.key) {
      return;
    }
    _wanted = (
      key: key,
      input: () => minimapRasterInput(
        frame,
        mapping.stripHeight,
        dpr,
        faint: ink.$1,
        text: ink.$2,
        muted: ink.$3,
        windowTop: windowTop,
        windowHeight: windowHeight,
      ),
    );
    _pump();
  }

  void _pump() {
    final ({_RasterKey key, MinimapRasterInput Function() input})? wanted = _wanted;
    if (_running || wanted == null || wanted.key == _done) {
      return;
    }
    _running = true;
    final _RasterKey key = wanted.key;
    unawaited(
      widget
          .runRaster(wanted.input())
          .then(
            (bytes) => _rastered(key, bytes),
            onError: (Object error, StackTrace stack) {
              _running = false;
              _done = key; // Not retried: the same input fails again.
              FlutterError.reportError(
                FlutterErrorDetails(exception: error, stack: stack, library: 'zanshin minimap'),
              );
              // A newer key requested meanwhile still rasters.
              if (mounted) {
                _pump();
              }
            },
          ),
    );
  }

  void _rastered(_RasterKey key, Uint8List bytes) {
    _running = false;
    if (!mounted) {
      return;
    }
    // A superseded result is dropped; the latest key rasters once now.
    if (key == _wanted?.key) {
      _done = key;
      unawaited(_decode(key, bytes));
    }
    _pump();
  }

  Future<void> _decode(_RasterKey key, Uint8List bytes) async {
    final int n = key.width * key.height * 4;
    final List<ui.Image> images = await Future.wait(<Future<ui.Image>>[
      _image(Uint8List.sublistView(bytes, 0, n), key.width, key.height),
      _image(Uint8List.sublistView(bytes, n, 2 * n), key.width, key.height),
    ]);
    if (!mounted || key != _done) {
      for (final image in images) {
        image.dispose();
      }
      return;
    }
    _out?.dispose();
    _in?.dispose();
    setState(() {
      _out = images[0];
      _in = images[1];
      _shown = key;
    });
  }

  static Future<ui.Image> _image(Uint8List pixels, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  // ---- interaction ----

  void _report(double amount) => ShellScope.maybeOf(context)?.reportUserScroll(amount);

  /// Jumps the graph so the band centres on strip y [sy] of a strip [stripHeight] tall, read against the frame current
  /// at the event (a scroll may have changed the insets since the last build).
  void _jump(double sy, double stripHeight) {
    final GraphMinimapFrame? frame = widget.model.minimapSource.frame;
    if (frame == null || !frame.vertical.hasClients) {
      return;
    }
    final ScrollPosition position = frame.vertical.position;
    frame.vertical.jumpTo(
      minimapJumpTarget(
        _mappingOf(frame, stripHeight),
        sy,
        viewport: position.viewportDimension,
        maxScrollExtent: position.maxScrollExtent,
        insets: frame.insets,
      ),
    );
  }

  static void _scrollBy(ScrollController controller, double delta) {
    if (delta == 0 || !controller.hasClients) {
      return;
    }
    final ScrollPosition position = controller.position;
    controller.jumpTo((position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent));
  }

  void _scroll(Offset delta) {
    final GraphMinimapFrame? frame = widget.model.minimapSource.frame;
    if (frame == null) {
      return;
    }
    _scrollBy(frame.horizontal, delta.dx);
    _scrollBy(frame.vertical, delta.dy);
    _report(delta.dx.abs() + delta.dy.abs());
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final GraphViewModel model = widget.model;
    return Semantics(
      container: true,
      label: context.l10n.graphMinimap,
      child: ZsGlass(
        fill: ZsGlassFill.strong,
        blur: ZsGlassBlur.strong,
        radius: ZsMetrics.of(context).radiusIsland,
        child: Padding(
          // The strip's inset counts from the card's outer edge; the glass lays its child out inside its border.
          padding: minimapStripInset - const EdgeInsets.all(ZsSurface.borderWidth),
          child: ListenableBuilder(
            listenable: Listenable.merge(<Listenable>[model, model.now, model.minimapSource]),
            builder: (context, _) =>
                LayoutBuilder(builder: (context, constraints) => _strip(context, constraints.biggest)),
          ),
        ),
      ),
    );
  }

  Widget _strip(BuildContext context, Size size) {
    final GraphMinimapFrame? frame = widget.model.minimapSource.frame;
    if (frame == null || size.isEmpty) {
      return const SizedBox.expand();
    }
    final ZsColors colors = ZsColors.of(context);
    final MinimapMapping mapping = _mappingOf(frame, size.height);
    _watch(frame.vertical);
    _request(frame, mapping, MediaQuery.devicePixelRatioOf(context), colors);
    final MinimapLabels labels = _labelsOf(frame, context.l10n);
    final GraphLayout layout = frame.layout;
    final String? selected = widget.model.selected;
    final int? at = layout.workingCopyIndex;
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onHover: (event) {
        if (!_dragging) {
          _hover.value = event.localPosition.dy;
        }
      },
      onExit: (_) => _hover.value = null,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (event.buttons & kPrimaryButton == 0) {
            return;
          }
          _dragging = true;
          _hover.value = null;
          _report(40);
          _jump(event.localPosition.dy, size.height);
        },
        onPointerMove: (event) {
          if (_dragging) {
            _report(40);
            _jump(event.localPosition.dy, size.height);
          }
        },
        onPointerUp: (_) => _dragging = false,
        onPointerCancel: (_) => _dragging = false,
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            GestureBinding.instance.pointerSignalResolver.register(
              event,
              (event) => _scroll((event as PointerScrollEvent).scrollDelta),
            );
          }
        },
        onPointerPanZoomUpdate: (event) => _scroll(-event.panDelta),
        child: CustomPaint(
          size: size,
          painter: _BandPainter(frame: frame, mapping: mapping, color: colors.flHover),
          foregroundPainter: _OverlayPainter(
            frame: frame,
            mapping: mapping,
            inLayer: _in,
            raster: _shown,
            labels: labels,
            selected: selected == null ? null : layout.placeOfKey(selected),
            workingCopy: at == null ? null : layout.placeOfKey(layout.keyOf(at)),
            hover: _hover,
            colors: colors,
            text: (text, kind) => _text(text, kind, colors),
          ),
          child: RepaintBoundary(
            child: CustomPaint(
              size: size,
              painter: _RasterPainter(_out, raster: _shown, frame: frame, mapping: mapping),
            ),
          ),
        ),
      ),
    );
  }
}

/// The canvas scroll offset that centres the band on strip y [sy] (Story 10.31, graph-view.jsx `jump`): the band's
/// centre lies at `pixels · (k − over / range) + c0 · k` with `c0 = top + (viewport − top − bottom) / 2`, solved for
/// `pixels` and clamped to the scroll range.
double minimapJumpTarget(
  MinimapMapping mapping,
  double sy, {
  required double viewport,
  required double maxScrollExtent,
  required EdgeInsets insets,
}) {
  final double range = math.max(1, maxScrollExtent);
  final double c0 = insets.top + (viewport - insets.top - insets.bottom) / 2;
  final double target = (sy - c0 * mapping.k) / math.max(mapping.k - mapping.over / range, 1e-6);
  return target.clamp(0, math.max(0, maxScrollExtent));
}

/// The band's top and bottom in strip px with the minimap's scroll offset (graph-view.jsx `vTop`, `vBot`, `ms`), or
/// null while the canvas has no scroll position.
({double top, double bottom, double ms})? _bandOf(GraphMinimapFrame frame, MinimapMapping mapping) {
  final ScrollController vertical = frame.vertical;
  if (!vertical.hasClients) {
    return null;
  }
  final ScrollPosition position = vertical.position;
  if (!position.hasPixels || !position.hasViewportDimension) {
    return null;
  }
  final double offset = position.pixels;
  final double ms = mapping.msOf(position);
  return (
    top: (offset + frame.insets.top) * mapping.k - ms,
    bottom: (offset + position.viewportDimension - frame.insets.bottom) * mapping.k - ms,
    ms: ms,
  );
}

/// The viewport band (kit.css:166): `--fl-hover`, r 4, under the dots.
class _BandPainter extends CustomPainter {
  _BandPainter({required this.frame, required this.mapping, required this.color}) : super(repaint: frame.vertical);

  final GraphMinimapFrame frame;
  final MinimapMapping mapping;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final ({double top, double bottom, double ms})? band = _bandOf(frame, mapping);
    if (band == null) {
      return;
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          minimapSplit + 2,
          band.top,
          mapping.strip - minimapSplit + 2,
          math.max(4, band.bottom - band.top),
        ),
        const Radius.circular(4),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_BandPainter old) => old.frame != frame || old.mapping != mapping || old.color != color;
}

/// Where a raster covering [raster]'s window lands on the strip at scroll offset [ms]; the whole strip without a key.
Rect _rasterRect(_RasterKey? raster, MinimapMapping mapping, double ms, Size size) => raster == null
    ? Offset.zero & size
    : Rect.fromLTWH(0, raster.windowTop - ms, raster.width / raster.dpr, raster.windowHeight);

/// The out layer (kit.css:163, `.zk-mini-g{opacity:.6}`): the raster at 60 %, moved with the minimap's scroll offset
/// (Story 10.31).
class _RasterPainter extends CustomPainter {
  _RasterPainter(this.image, {required this.raster, required this.frame, required this.mapping})
    : super(repaint: mapping.over == 0 ? null : frame.vertical);

  final ui.Image? image;
  final _RasterKey? raster;
  final GraphMinimapFrame frame;
  final MinimapMapping mapping;

  @override
  void paint(Canvas canvas, Size size) {
    final ui.Image? image = this.image;
    if (image == null) {
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      _rasterRect(raster, mapping, _msOf(frame, mapping), size),
      Paint()
        ..color = const Color.fromRGBO(0, 0, 0, .6)
        ..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_RasterPainter old) =>
      !identical(old.image, image) || old.raster != raster || old.mapping != mapping || old.frame != frame;
}

/// Everything above the out layer (graph-view.jsx:494-537; kit.css:163-172): the in layer clipped to the band, the
/// selection and @ dots, the hover line, the connector, the day labels and the pills.
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.frame,
    required this.mapping,
    required this.inLayer,
    required this.raster,
    required this.labels,
    required this.selected,
    required this.workingCopy,
    required this.hover,
    required this.colors,
    required this.text,
  }) : super(repaint: Listenable.merge(<Listenable>[frame.vertical, hover]));

  // The sticky header's height and the gap a year keeps from the day labels (graph-view.jsx, sync #22).
  static const double _stickyHeight = 22;
  static const double _yearClear = 16;

  final GraphMinimapFrame frame;
  final MinimapMapping mapping;
  final ui.Image? inLayer;
  final _RasterKey? raster;
  final MinimapLabels labels;
  final int? selected;
  final int? workingCopy;
  final ValueListenable<double?> hover;
  final ZsColors colors;
  final TextPainter Function(String text, _Text kind) text;

  @override
  void paint(Canvas canvas, Size size) {
    final ({double top, double bottom, double ms})? band = _bandOf(frame, mapping);
    if (band == null) {
      return;
    }
    final double vTop = band.top;
    final double vBot = band.bottom;
    final double ms = band.ms;
    final double strip = mapping.strip;
    final double cy = (vTop + vBot) / 2;
    final ui.Image? image = inLayer;
    if (image != null && vBot > vTop) {
      canvas
        ..save()
        ..clipRect(Rect.fromLTRB(-8, vTop, size.width + 16, vBot))
        ..drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          _rasterRect(raster, mapping, ms, size),
          Paint()..filterQuality = FilterQuality.low,
        )
        ..restore();
    }
    // The breaks (Story 10.31): a small zigzag across the graph part.
    final breakPaint = Paint()
      ..color = colors.textDim
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round;
    for (final double y in labels.breaks) {
      final double sy = mapping.my(y) - ms;
      if (sy < -4 || sy > size.height + 4) {
        continue;
      }
      const double x0 = minimapSplit + 4;
      final points = <Offset>[
        for (final Offset p in graphZigzag(0, strip - x0, sy, 0, amp: 2, step: 5))
          Offset(math.min(x0 + p.dx, strip), p.dy),
      ];
      canvas.drawPath(Path()..addPolygon(points, false), breakPaint);
    }
    _mark(canvas, selected, colors.accentLine, ms);
    _mark(canvas, workingCopy, colors.co, ms);
    final double? hov = hover.value;
    if (hov != null) {
      final dash = Paint()
        ..color = colors.textDim
        ..strokeWidth = 1;
      for (double x = minimapSplit; x < strip; x += 4) {
        canvas.drawLine(Offset(x, hov), Offset(math.min(x + 2, strip), hov), dash);
      }
    }
    canvas.drawLine(
      Offset(minimapSplit, cy),
      Offset(strip, cy),
      Paint()
        ..color = colors.atChrome
        ..strokeWidth = 1,
    );
    // The years (Story 10.31): each boundary heads the section below it with the older year; the top section's year
    // sticks as a header — none when the whole history lies in this year.
    final years = <({double sy, int year})>[
      for (final MinimapYear y in labels.years)
        if (y.below != null) (sy: mapping.my(y.y) - ms, year: y.below!),
    ];
    int? sticky;
    for (final y in years) {
      if (y.sy <= _stickyHeight) {
        sticky = y.year;
      }
    }
    if (sticky == null && labels.years.isNotEmpty && (years.isNotEmpty || labels.years.first.year != labels.nowYear)) {
      sticky = labels.years.first.year;
    }
    var lastY = -99.0;
    for (var i = 0; i < labels.length; i++) {
      final double sy = mapping.my(labels.ys[i]) - ms;
      if (labels.silent.contains(i) ||
          sy - lastY < 18 ||
          (sy - cy).abs() < 15 ||
          (hov != null && (sy - hov).abs() < 13) ||
          (sticky != null && sy < _stickyHeight) ||
          years.any((y) => (y.sy - sy).abs() < _yearClear)) {
        continue;
      }
      lastY = sy;
      final TextPainter painter = text(labels.texts[i], _Text.label);
      painter.paint(canvas, Offset(minimapSplit - 4 - painter.width, sy - painter.height / 2));
    }
    for (final y in years) {
      if (y.sy > _stickyHeight && y.sy < size.height - 4) {
        final TextPainter painter = text(labels.yearTexts[y.year]!, _Text.year);
        painter.paint(canvas, Offset(minimapSplit - 4 - painter.width, y.sy + 3));
      }
    }
    if (sticky != null) {
      final TextPainter painter = text(labels.yearTexts[sticky]!, _Text.year);
      const double right = minimapSplit - 4;
      final rect = Rect.fromLTRB(right - painter.width - 8, 0, right, painter.height + 6);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(rect.topLeft, rect.topLeft + const Offset(8, 0), <Color>[
            colors.flBgSolid.withValues(alpha: 0),
            colors.flBgSolid,
          ]),
      );
      painter.paint(canvas, Offset(right - painter.width, 3));
    }
    if (hov != null) {
      final String? day = minimapDayAt(labels, mapping.planeY(hov, ms));
      if (day != null) {
        _pill(canvas, day, hov, hovered: true);
      }
    }
    final String? day = minimapDayAt(labels, mapping.planeY(cy, ms));
    if (day != null) {
      _pill(canvas, day, cy, hovered: false);
    }
  }

  void _mark(Canvas canvas, int? node, Color color, double ms) {
    if (node == null) {
      return;
    }
    final GraphLayout layout = frame.layout;
    final GraphMetrics metrics = frame.metrics;
    if (layout.rowOf(node) < 0) {
      return;
    }
    final double x = mapping.mx(metrics.x(layout.colOf(node)) + metrics.cardWidth / 2);
    final double y = mapping.my(frame.rows.top(node) + metrics.cardHeight / 2) - ms;
    canvas.drawCircle(Offset(x, y), 3.2, Paint()..color = color);
  }

  /// A pill (kit.css:171-172): padding 3/9, a 1 px border, fully rounded, its right edge at [minimapSplit] and
  /// centred on [y]; the current-day pill with its shadow.
  void _pill(Canvas canvas, String day, double y, {required bool hovered}) {
    final TextPainter painter = text(day, hovered ? _Text.hoverPill : _Text.pill);
    final double width = painter.width + 2 * 9 + 2;
    final double height = painter.height + 2 * 3 + 2;
    final rect = Rect.fromLTWH(minimapSplit - width, y - height / 2, width, height);
    final pill = RRect.fromRectAndRadius(rect, Radius.circular(height / 2));
    if (!hovered) {
      const shadow = BoxShadow(color: Color(0x80000000), offset: Offset(0, 4), blurRadius: 14, spreadRadius: -4);
      canvas.drawRRect(pill.shift(shadow.offset).inflate(shadow.spreadRadius), shadow.toPaint());
    }
    canvas
      ..drawRRect(pill, Paint()..color = colors.flBgSolid)
      ..drawRRect(
        pill.deflate(.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = hovered ? colors.borderStrong : colors.atChrome,
      );
    painter.paint(canvas, Offset(rect.left + 1 + 9, rect.top + 1 + 3));
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.frame != frame ||
      old.mapping != mapping ||
      !identical(old.inLayer, inLayer) ||
      old.raster != raster ||
      !identical(old.labels, labels) ||
      old.selected != selected ||
      old.workingCopy != workingCopy ||
      !identical(old.colors, colors);
}
