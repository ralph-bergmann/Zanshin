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

// The design's constants (graph-view.jsx:444, 480; DS ui_kits/desktop/kit.css:155-172), CSS px.

/// The strip's width: the 134 px card less 8 px on each side (`MINI_W`).
const double minimapStripWidth = 118;

/// The strip's inset in the card (kit.css:157, `inset:12px 8px`).
const minimapStripInset = EdgeInsets.symmetric(vertical: 12, horizontal: 8);

/// The split between the day labels (left) and the graph's dots (right) (`MINI_SPLIT`).
const double minimapSplit = 58;

/// The graph's right edge in the strip (`gr = MINI_W − 4`).
const double _graphRight = 114;

/// The graph's left limit: at most 48 px of graph width (`MINI_GL`).
const double _graphLeft = 66;

/// The largest x scale (`MINI_KX`).
const _kxMax = 0.04;

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

  /// The current frame, null without a canvas.
  GraphMinimapFrame? get frame => _frame;

  /// Makes [frame] current; notifies only when it changed.
  void publish(GraphMinimapFrame frame) {
    if (_disposed || frame == _frame) {
      return;
    }
    _frame = frame;
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
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The minimap's day labels in plane coordinates, ascending y (Story 10.16).
@immutable
class MinimapLabels {
  /// Labels at [ys] reading [texts].
  const MinimapLabels(this.ys, this.texts, {required this.free});

  /// No labels.
  static const empty = MinimapLabels(<double>[], <String>[], free: false);

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
/// - **Free:** one label per [GraphDayAxis] bucket at its label y, reading [graphDayLabel] of the bucket;
/// - **Compact:** per row the newest timestamp of its laid-out nodes (the root and nodes without one left out); a row
///   gets a label at its card centre only when its day ([graphLocalDay]) is older than the last label's.
MinimapLabels minimapLabels(
  GraphLayout layout,
  VerticalLayout rows, {
  required AppLocalizations strings,
  required int nowMs,
}) {
  final int offset = layout.utcOffsetMinutes;
  String label(int day) => graphDayLabel(strings, day, nowMs: nowMs, utcOffsetMinutes: offset);
  if (layout.mode == GraphMode.free) {
    final axis = GraphDayAxis.of(layout, rows);
    final int n = axis.length;
    // labelYs decrease with the bucket, so the newest day comes first.
    return MinimapLabels(
      <double>[for (int b = n - 1; b >= 0; b--) axis.labelYs[b]],
      <String>[for (int b = n - 1; b >= 0; b--) label(axis.values[b])],
      free: true,
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
  double last = double.infinity;
  final double half = rows.metrics.cardHeight / 2;
  for (final row in order) {
    final int day = graphLocalDay(newest[row]!, utcOffsetMinutes: offset);
    if (day < last) {
      last = day.toDouble();
      ys.add(rows.topOfRow(row) + half);
      texts.add(label(day));
    }
  }
  return MinimapLabels(ys, texts, free: false);
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

/// The plane → strip map of one frame and strip height (graph-view.jsx:476-482).
@immutable
class _Mapping {
  const _Mapping(this.k, this.kx, this.x1, this.top);

  /// [frame]'s map onto a strip [stripHeight] tall, with the laid-out nodes' centre x [extent] (min, max).
  factory _Mapping.of(GraphMinimapFrame frame, double stripHeight, (double, double) extent) {
    final (double x0, double x1) = extent;
    final EdgeInsets insets = frame.insets;
    final double k = stripHeight / math.max(1, frame.rows.contentHeight + insets.top + insets.bottom);
    final double kx = x1 > x0 ? math.min((_graphRight - _graphLeft) / (x1 - x0), _kxMax) : 0;
    return _Mapping(k, kx, x1, insets.top);
  }

  final double k;
  final double kx;
  final double x1;
  final double top;

  double mx(double x) => _graphRight - (x1 - x) * kx;

  double my(double y) => (y + top) * k;

  /// The plane y of strip y [sy].
  double planeY(double sy) => sy / math.max(k, 1e-6) - top;

  @override
  bool operator ==(Object other) =>
      other is _Mapping && other.k == k && other.kx == kx && other.x1 == x1 && other.top == top;

  @override
  int get hashCode => Object.hash(k, kx, x1, top);
}

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

/// The raster input of [frame] on a strip of [strip] CSS px at [dpr] (Story 10.16): the laid-out nodes' plane centres
/// (x the card's centre, y `rows.top + cardHeight / 2`), the route polylines with their indirect flags (none while
/// [GraphMinimapFrame.geometry] is null), the plane → device map and the colours [faint] (the out layer), [text] (the
/// in layer's nodes) and [muted] (its edges), each 0xAARRGGBB.
MinimapRasterInput minimapRasterInput(
  GraphMinimapFrame frame,
  Size strip,
  double dpr, {
  required int faint,
  required int text,
  required int muted,
}) {
  final GraphLayout layout = frame.layout;
  final GraphMetrics metrics = frame.metrics;
  final VerticalLayout rows = frame.rows;
  final mapping = _Mapping.of(frame, strip.height, _extentOf(layout, metrics));
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
  final RouteGeometry? geometry = frame.geometry;
  final int edges = geometry == null ? 0 : math.min(geometry.pointStarts.length - 1, layout.edgeCount);
  final indirect = Uint8List(edges);
  for (var e = 0; e < edges; e++) {
    indirect[e] = layout.kindOf(e) == GraphEdgeKind.indirect ? 1 : 0;
  }
  return MinimapRasterInput(
    nodeXs: xs,
    nodeYs: ys,
    nodeStacks: stacks,
    edgeStarts: geometry == null ? Int32List(1) : Int32List.fromList(geometry.pointStarts.sublist(0, edges + 1)),
    edgePoints: geometry?.points ?? Float64List(0),
    edgeIndirect: indirect,
    ax: dpr * (_graphRight - mapping.x1 * mapping.kx),
    bx: dpr * mapping.kx,
    ay: dpr * mapping.top * mapping.k,
    by: dpr * mapping.k,
    dpr: dpr,
    width: (strip.width * dpr).round(),
    height: (strip.height * dpr).round(),
    outNode: faint,
    outEdge: faint,
    inNode: text,
    inEdge: muted,
  );
}

/// The raster's key: a change re-rasters (Story 10.16).
@immutable
class _RasterKey {
  const _RasterKey(this.frame, this.top, this.bottom, this.width, this.height, this.dpr, this.colors);

  final GraphMinimapFrame frame;
  final double top;
  final double bottom;
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

enum _Text { label, pill, hoverPill }

class _GraphMinimapState extends State<GraphMinimap> {
  final _hover = ValueNotifier<double?>(null);
  var _dragging = false;

  // The x extent of the laid-out nodes' centres, per layout and metrics.
  GraphLayout? _extentLayout;
  GraphMetrics? _extentMetrics;
  (double, double) _extent = (0, 0);

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

  // The text painters, per text and kind, kept while the colours stay.
  final _texts = <String, TextPainter>{};
  ZsColors? _textColors;

  @override
  void dispose() {
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
      };
      return TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
    });
  }

  _Mapping _mappingOf(GraphMinimapFrame frame, double stripHeight) {
    if (!identical(_extentLayout, frame.layout) || _extentMetrics != frame.metrics) {
      _extentLayout = frame.layout;
      _extentMetrics = frame.metrics;
      _extent = _extentOf(frame.layout, frame.metrics);
    }
    return _Mapping.of(frame, stripHeight, _extent);
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

  void _request(GraphMinimapFrame frame, Size size, double dpr, ZsColors colors) {
    final int width = (size.width * dpr).round();
    final int height = (size.height * dpr).round();
    if (width <= 0 || height <= 0) {
      return;
    }
    final (int, int, int) ink = (colors.textFaint.toARGB32(), colors.text.toARGB32(), colors.textMuted.toARGB32());
    final key = _RasterKey(frame, frame.insets.top, frame.insets.bottom, width, height, dpr, ink);
    if (key == _wanted?.key) {
      return;
    }
    _wanted = (
      key: key,
      input: () => minimapRasterInput(frame, size, dpr, faint: ink.$1, text: ink.$2, muted: ink.$3),
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
    final double top = frame.insets.top;
    final double target =
        sy / math.max(_mappingOf(frame, stripHeight).k, 1e-6) -
        (top + (position.viewportDimension - top - frame.insets.bottom) / 2);
    frame.vertical.jumpTo(target.clamp(0, math.max(0, position.maxScrollExtent)));
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
    final _Mapping mapping = _mappingOf(frame, size.height);
    _request(frame, size, MediaQuery.devicePixelRatioOf(context), colors);
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
            labels: labels,
            selected: selected == null ? null : layout.placeOfKey(selected),
            workingCopy: at == null ? null : layout.placeOfKey(layout.keyOf(at)),
            hover: _hover,
            colors: colors,
            text: (text, kind) => _text(text, kind, colors),
          ),
          child: RepaintBoundary(
            child: CustomPaint(size: size, painter: _RasterPainter(_out)),
          ),
        ),
      ),
    );
  }
}

/// The band's top and bottom in strip px (graph-view.jsx:494), or null while the canvas has no scroll position.
(double, double)? _bandOf(GraphMinimapFrame frame, _Mapping mapping) {
  final ScrollController vertical = frame.vertical;
  if (!vertical.hasClients) {
    return null;
  }
  final ScrollPosition position = vertical.position;
  if (!position.hasPixels || !position.hasViewportDimension) {
    return null;
  }
  final double offset = position.pixels;
  return (
    (offset + frame.insets.top) * mapping.k,
    (offset + position.viewportDimension - frame.insets.bottom) * mapping.k,
  );
}

/// The viewport band (kit.css:166): `--fl-hover`, r 4, under the dots.
class _BandPainter extends CustomPainter {
  _BandPainter({required this.frame, required this.mapping, required this.color}) : super(repaint: frame.vertical);

  final GraphMinimapFrame frame;
  final _Mapping mapping;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final (double, double)? band = _bandOf(frame, mapping);
    if (band == null) {
      return;
    }
    final (double top, double bottom) = band;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(minimapSplit + 2, top, minimapStripWidth - minimapSplit + 2, math.max(4, bottom - top)),
        const Radius.circular(4),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_BandPainter old) => old.frame != frame || old.mapping != mapping || old.color != color;
}

/// The out layer (kit.css:163, `.zk-mini-g{opacity:.6}`): the raster at 60 %, repainted only for a new raster.
class _RasterPainter extends CustomPainter {
  _RasterPainter(this.image);

  final ui.Image? image;

  @override
  void paint(Canvas canvas, Size size) {
    final ui.Image? image = this.image;
    if (image == null) {
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()
        ..color = const Color.fromRGBO(0, 0, 0, .6)
        ..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_RasterPainter old) => !identical(old.image, image);
}

/// Everything above the out layer (graph-view.jsx:494-537; kit.css:163-172): the in layer clipped to the band, the
/// selection and @ dots, the hover line, the connector, the day labels and the pills.
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.frame,
    required this.mapping,
    required this.inLayer,
    required this.labels,
    required this.selected,
    required this.workingCopy,
    required this.hover,
    required this.colors,
    required this.text,
  }) : super(repaint: Listenable.merge(<Listenable>[frame.vertical, hover]));

  final GraphMinimapFrame frame;
  final _Mapping mapping;
  final ui.Image? inLayer;
  final MinimapLabels labels;
  final int? selected;
  final int? workingCopy;
  final ValueListenable<double?> hover;
  final ZsColors colors;
  final TextPainter Function(String text, _Text kind) text;

  @override
  void paint(Canvas canvas, Size size) {
    final (double, double)? band = _bandOf(frame, mapping);
    if (band == null) {
      return;
    }
    final (double vTop, double vBot) = band;
    final double cy = (vTop + vBot) / 2;
    final ui.Image? image = inLayer;
    if (image != null && vBot > vTop) {
      canvas
        ..save()
        ..clipRect(Rect.fromLTRB(-8, vTop, size.width + 16, vBot))
        ..drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Offset.zero & size,
          Paint()..filterQuality = FilterQuality.low,
        )
        ..restore();
    }
    _mark(canvas, selected, colors.accentLine);
    _mark(canvas, workingCopy, colors.co);
    final double? hov = hover.value;
    if (hov != null) {
      final dash = Paint()
        ..color = colors.textDim
        ..strokeWidth = 1;
      for (double x = minimapSplit; x < minimapStripWidth; x += 4) {
        canvas.drawLine(Offset(x, hov), Offset(math.min(x + 2, minimapStripWidth), hov), dash);
      }
    }
    canvas.drawLine(
      Offset(minimapSplit, cy),
      Offset(minimapStripWidth, cy),
      Paint()
        ..color = colors.atChrome
        ..strokeWidth = 1,
    );
    var lastY = -99.0;
    for (var i = 0; i < labels.length; i++) {
      final double sy = mapping.my(labels.ys[i]);
      if (sy - lastY < 18 || (sy - cy).abs() < 15 || (hov != null && (sy - hov).abs() < 13)) {
        continue;
      }
      lastY = sy;
      final TextPainter painter = text(labels.texts[i], _Text.label);
      painter.paint(canvas, Offset(minimapSplit - 4 - painter.width, sy - painter.height / 2));
    }
    if (hov != null) {
      final String? day = minimapDayAt(labels, mapping.planeY(hov));
      if (day != null) {
        _pill(canvas, day, hov, hovered: true);
      }
    }
    final String? day = minimapDayAt(labels, mapping.planeY(cy));
    if (day != null) {
      _pill(canvas, day, cy, hovered: false);
    }
  }

  void _mark(Canvas canvas, int? node, Color color) {
    if (node == null) {
      return;
    }
    final GraphLayout layout = frame.layout;
    final GraphMetrics metrics = frame.metrics;
    if (layout.rowOf(node) < 0) {
      return;
    }
    final double x = mapping.mx(metrics.x(layout.colOf(node)) + metrics.cardWidth / 2);
    final double y = mapping.my(frame.rows.top(node) + metrics.cardHeight / 2);
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
      !identical(old.labels, labels) ||
      old.selected != selected ||
      old.workingCopy != workingCopy ||
      !identical(old.colors, colors);
}
