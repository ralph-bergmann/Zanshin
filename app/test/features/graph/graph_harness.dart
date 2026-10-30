// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';

import '../../../widgetbook/graph/graph_recordings.g.dart';

/// The witnesses' surface (Story 10.1): 800 × 600 at dpr 1.
const surface = Size(800, 600);

/// The recording [name] (`<input> <mode> <order>`).
RecordedGraphLayout recording(String name) {
  final (String input, String output) = graphRecordings[name]!;
  return RecordedGraphLayout.fromSpec(input, output);
}

/// A hand-built layout: one (key, row, col) per node, edges as (child, parent) node indices (in any order), day
/// [buckets] as (value, first row, last row), oldest first.
RecordedGraphLayout handLayout(
  List<(String, int, int)> nodes, {
  List<(int, int)> edges = const <(int, int)>[],
  int unit = 1,
  int? workingCopy,
  List<(int, int, int)> buckets = const <(int, int, int)>[],
  int? root,
  int utcOffsetMinutes = 0,
}) {
  final sorted = <(int, int)>[...edges]..sort((a, b) => a.$1.compareTo(b.$1));
  var rows = 0;
  var cols = 0;
  for (final (_, int row, int col) in nodes) {
    rows = row + unit > rows ? row + unit : rows;
    cols = col + 1 > cols ? col + 1 : cols;
  }
  return RecordedGraphLayout(
    mode: unit == 1 ? GraphMode.compact : GraphMode.free,
    unit: unit,
    rows: rows,
    colCount: cols,
    keys: <String>[for (final (String key, _, _) in nodes) key],
    cols: Int32List.fromList(<int>[for (final (_, _, int col) in nodes) col]),
    nodeRows: Int32List.fromList(<int>[for (final (_, int row, _) in nodes) row]),
    parentCounts: Int32List(nodes.length),
    elided: Uint8List(nodes.length),
    edgeChildren: Int32List.fromList(<int>[for (final (int child, _) in sorted) child]),
    edgeParents: Int32List.fromList(<int>[for (final (_, int parent) in sorted) parent]),
    edgeKinds: <GraphEdgeKind>[for (final _ in sorted) GraphEdgeKind.direct],
    edgeShapes: <GraphEdgeShape>[for (final _ in sorted) GraphEdgeShape.straight],
    bucketValues: <int>[for (final (int value, _, _) in buckets) value],
    bucketFirstRows: Int32List.fromList(<int>[for (final (_, int first, _) in buckets) first]),
    bucketLastRows: Int32List.fromList(<int>[for (final (_, _, int last) in buckets) last]),
    utcOffsetMinutes: utcOffsetMinutes,
    rootIndex: root,
    workingCopyIndex: workingCopy,
  );
}

/// A chain of [rows] commits `r0` (the oldest) … `r<rows−1>`, one per row, in column `row % cols` unless [colOf]
/// says otherwise; [head] adds a newest commit above them all (every card moves down one pitch).
RecordedGraphLayout chainLayout(int rows, {int cols = 6, String? head, Map<String, int> colOf = const {}}) {
  final nodes = <(String, int, int)>[
    if (head != null) (head, rows, colOf[head] ?? 0),
    for (int row = rows - 1; row >= 0; row--) ('r$row', row, colOf['r$row'] ?? row % cols),
  ];
  return handLayout(nodes, edges: <(int, int)>[for (var i = 0; i + 1 < nodes.length; i++) (i, i + 1)]);
}

/// What the test cards saw: builds and State inits per key, taps in order.
class CardLog {
  final builds = <String, int>{};
  final inits = <String, int>{};
  final taps = <String>[];

  int get buildCount => builds.values.fold(0, (a, b) => a + b);

  int get initCount => inits.values.fold(0, (a, b) => a + b);

  void clear() {
    builds.clear();
    inits.clear();
    taps.clear();
  }
}

/// A card that logs its builds and inits, paints a rect in the colour `0xFF000000 + node` and the key as text.
class TestCard extends StatefulWidget {
  const TestCard({required this.nodeKey, required this.node, required this.log, super.key});

  final String nodeKey;
  final int node;
  final CardLog log;

  @override
  State<TestCard> createState() => _TestCardState();
}

class _TestCardState extends State<TestCard> {
  @override
  void initState() {
    super.initState();
    widget.log.inits.update(widget.nodeKey, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) {
    widget.log.builds.update(widget.nodeKey, (n) => n + 1, ifAbsent: () => 1);
    return Semantics(
      container: true,
      child: GestureDetector(
        onTap: () => widget.log.taps.add(widget.nodeKey),
        child: ColoredBox(
          color: Color(0xFF000000 + widget.node),
          child: Text(widget.nodeKey, textDirection: TextDirection.ltr),
        ),
      ),
    );
  }
}

/// The node a test card's colour encodes.
int nodeOfColor(Color color) => color.toARGB32() & 0xFFFFFF;

/// One viewport under test: its controllers, the current widget inputs and the card log.
class GraphHarness {
  GraphHarness(this.layout, {GraphMetrics? metrics}) : metrics = metrics ?? GraphMetrics();

  final v = ScrollController();
  final h = ScrollController();
  final controller = GraphViewportController();
  final log = CardLog();
  GraphLayout layout;
  GraphMetrics metrics;
  VerticalLayout? verticalLayout;
  EdgeInsets insets = EdgeInsets.zero;
  var pinned = const <String>{};
  String? selected;
  String? hovered;
  String? anchorKey;
  GraphReveal? reveal;
  GraphPaintHook? background;
  GraphPaintHook? edges;
  GraphPaintHook? overlay;
  var disableAnimations = false;
  GraphNodeOpacity? opacityOf;

  /// Called before each card is built.
  void Function()? onCardBuild;

  /// The card builder: a method, so its tear-off is equal across builds, as the viewport requires.
  Widget cardBuilder(BuildContext context, int node) {
    onCardBuild?.call();
    return TestCard(nodeKey: layout.keyOf(node), node: node, log: log);
  }

  /// [node]'s top in plane coordinates, by the item 4 formula (independent of [UniformRows]).
  double topOf(int node) =>
      verticalLayout?.top(node) ??
      metrics.pad +
          (layout.rows - layout.unit - layout.rowOf(node)) * (metrics.cardHeight + metrics.gapY) / layout.unit;

  /// [node]'s card in content coordinates, by the item 3 and 4 formulas.
  Rect cardRect(int node) => Rect.fromLTWH(
    insets.left + metrics.pad + layout.colOf(node) * (metrics.cardWidth + metrics.gapX),
    insets.top + topOf(node),
    metrics.cardWidth,
    metrics.cardHeight,
  );

  /// The keys whose card, inflated by the overhang, meets the viewport ± [cache] (at the scroll offset [at], by
  /// default the current one), plus the pinned keys present.
  Set<String> expectedMounted({double cache = 250, Offset? at}) {
    final Rect window = ((at ?? scroll) & surface).inflate(cache);
    return <String>{
      for (var i = 0; i < layout.nodeCount; i++)
        if (cardRect(i).inflate(graphCardOverhang).overlaps(window)) layout.keyOf(i),
      for (final String key in pinned)
        if (layout.indexOfKey(key) != null) key,
    };
  }

  /// Both maximum scroll extents by the item 3 and 4 formulas.
  Offset get expectedMax {
    final double width = layout.colCount == 0
        ? 2 * metrics.pad
        : 2 * metrics.pad + layout.colCount * (metrics.cardWidth + metrics.gapX) - metrics.gapX;
    final double height =
        verticalLayout?.contentHeight ??
        (layout.nodeCount == 0
            ? 2 * metrics.pad
            : 2 * metrics.pad + layout.rows / layout.unit * (metrics.cardHeight + metrics.gapY) - metrics.gapY);
    return Offset(
      math.max(0, insets.horizontal + width - surface.width),
      math.max(0, insets.vertical + height - surface.height),
    );
  }

  Widget build() => MediaQuery(
    data: MediaQueryData(size: surface, disableAnimations: disableAnimations),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: GraphViewport(
        layout: layout,
        metrics: metrics,
        verticalLayout: verticalLayout,
        cardBuilder: cardBuilder,
        verticalController: v,
        horizontalController: h,
        insets: insets,
        pinnedKeys: pinned,
        selectedKey: selected,
        hoveredKey: hovered,
        anchorKey: anchorKey,
        reveal: reveal,
        controller: controller,
        opacityOf: opacityOf,
        paintBackground: background,
        paintEdges: edges,
        paintOverlay: overlay,
      ),
    ),
  );

  Offset get scroll => Offset(h.offset, v.offset);

  /// The viewport in content coordinates.
  Rect get viewport => scroll & surface;

  RenderGraphViewport render(WidgetTester tester) => tester.allRenderObjects.whereType<RenderGraphViewport>().single;

  /// The keys of the mounted cards (on and off screen).
  Set<String> mounted(WidgetTester tester) =>
      tester.widgetList<TestCard>(find.byType(TestCard, skipOffstage: false)).map((c) => c.nodeKey).toSet();

  /// Where [key]'s card is on screen.
  Offset screenOf(WidgetTester tester, String key) =>
      tester.getTopLeft(find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == key, skipOffstage: false));
}

/// Pumps [harness] on the 800 × 600 surface.
Future<void> pumpGraph(WidgetTester tester, GraphHarness harness) async {
  tester.view
    ..physicalSize = surface
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(harness.v.dispose);
  addTearDown(harness.h.dispose);
  await tester.pumpWidget(harness.build());
}
