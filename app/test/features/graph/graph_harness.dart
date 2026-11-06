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

import '../../../widgetbook/graph/fake_content.dart';
import '../../../widgetbook/graph/graph_recordings.g.dart';
import '../../../widgetbook/graph/graph_stack_recordings.g.dart';

/// The witnesses' surface (Story 10.1): 800 × 600 at dpr 1.
const surface = Size(800, 600);

/// The recording [name] (`<input> <mode> <order>`).
RecordedGraphLayout recording(String name) {
  final (String input, String output) = graphRecordings[name]!;
  return RecordedGraphLayout.fromSpec(input, output);
}

/// The stack recording [name] (`<input> <mode> <state>`, Story 10.17), with the catalogue's fake content inline unless
/// [inlineContent] is false.
RecordedGraphLayout stackRecording(String name, {bool inlineContent = true}) {
  final (String input, String output, _) = graphStackRecordings[name]!;
  return RecordedGraphLayout.fromSpec(input, output, content: inlineContent ? fakeContent : null);
}

/// A constructed grouped layout (Story 10.17's scale witness, never an engine output): `head` (row 2) over one
/// collapsed run of [members] changes `m0` (the oldest) … `m<members−1>`, folded into the stack node `stack:m0` (row
/// 1), over `base` (row 0); every member has a timestamp a minute apart and a subject.
RecordedGraphLayout hugeStackLayout(int members) {
  final keys = <String>['head', for (var i = 0; i < members; i++) 'm$i', 'base', graphStackKey('m0')];
  final int base = members + 1;
  final int stack = members + 2;
  final int n = keys.length;
  int rowOf(int i) => i == 0
      ? 2
      : i == stack
      ? 1
      : i == base
      ? 0
      : -1;
  return RecordedGraphLayout(
    mode: GraphMode.compact,
    unit: 1,
    rows: 3,
    colCount: 1,
    keys: keys,
    cols: Int32List.fromList(<int>[for (var i = 0; i < n; i++) math.min(rowOf(i), 0)]),
    nodeRows: Int32List.fromList(<int>[for (var i = 0; i < n; i++) rowOf(i)]),
    parentCounts: Int32List.fromList(<int>[
      for (var i = 0; i < n; i++)
        if (i == base) 0 else 1,
    ]),
    elided: Uint8List(n),
    timestamps: <int?>[for (var i = 0; i < n; i++) 1790000000000 + 60000 * (i == stack ? members : i)],
    contents: <GraphCommitContent?>[
      for (var i = 0; i < n; i++)
        if (i == stack) null else GraphCommitContent(subject: 'change ${keys[i]}'),
    ],
    edgeChildren: Int32List.fromList(<int>[0, stack]),
    edgeParents: Int32List.fromList(<int>[stack, base]),
    edgeKinds: const <GraphEdgeKind>[GraphEdgeKind.direct, GraphEdgeKind.direct],
    edgeShapes: const <GraphEdgeShape>[GraphEdgeShape.straight, GraphEdgeShape.straight],
    runMembers: <List<int>>[
      <int>[for (var i = 1; i <= members; i++) i],
    ],
    runStackNodes: <int?>[stack],
  );
}

/// [inner] with [breaks] (Story 10.31): a hand-made Free layout whose rows are already the shortened ones.
class BrokenLayout extends GraphLayout {
  /// [inner] carrying [breaks].
  BrokenLayout(this.inner, this.breaks);

  /// The layout read through.
  final GraphLayout inner;

  @override
  final List<GraphBreak> breaks;

  @override
  GraphMode get mode => inner.mode;
  @override
  int get unit => inner.unit;
  @override
  int get rows => inner.rows;
  @override
  int get colCount => inner.colCount;
  @override
  int get nodeCount => inner.nodeCount;
  @override
  String keyOf(int node) => inner.keyOf(node);
  @override
  int? indexOfKey(String key) => inner.indexOfKey(key);
  @override
  int colOf(int node) => inner.colOf(node);
  @override
  int rowOf(int node) => inner.rowOf(node);
  @override
  int? timestampOf(int node) => inner.timestampOf(node);
  @override
  int parentCountOf(int node) => inner.parentCountOf(node);
  @override
  bool elidedOf(int node) => inner.elidedOf(node);
  @override
  int missingCountOf(int node) => inner.missingCountOf(node);
  @override
  int get edgeCount => inner.edgeCount;
  @override
  int childOf(int edge) => inner.childOf(edge);
  @override
  int parentOf(int edge) => inner.parentOf(edge);
  @override
  GraphEdgeKind kindOf(int edge) => inner.kindOf(edge);
  @override
  GraphEdgeShape shapeOf(int edge) => inner.shapeOf(edge);
  @override
  ({int start, int end}) parentEdges(int node) => inner.parentEdges(node);
  @override
  ({int start, int end}) childEdges(int node) => inner.childEdges(node);
  @override
  int childEdgeAt(int slot) => inner.childEdgeAt(slot);
  @override
  int get bucketCount => inner.bucketCount;
  @override
  GraphBucketKind bucketKindOf(int bucket) => inner.bucketKindOf(bucket);
  @override
  int bucketValueOf(int bucket) => inner.bucketValueOf(bucket);
  @override
  int bucketFirstRowOf(int bucket) => inner.bucketFirstRowOf(bucket);
  @override
  int bucketLastRowOf(int bucket) => inner.bucketLastRowOf(bucket);
  @override
  int get utcOffsetMinutes => inner.utcOffsetMinutes;
  @override
  int? get rootIndex => inner.rootIndex;
  @override
  int? get workingCopyIndex => inner.workingCopyIndex;
  @override
  int get shownCount => inner.shownCount;
  @override
  int? get totalCount => inner.totalCount;
  @override
  String? get operationId => inner.operationId;
  @override
  String changeIdOf(int node) => inner.changeIdOf(node);
  @override
  String commitIdOf(int node) => inner.commitIdOf(node);
  @override
  int changeIdPrefixLengthOf(int node) => inner.changeIdPrefixLengthOf(node);
  @override
  int? changeOffsetOf(int node) => inner.changeOffsetOf(node);
  @override
  bool isImmutable(int node) => inner.isImmutable(node);
  @override
  bool isHidden(int node) => inner.isHidden(node);
  @override
  bool isDivergent(int node) => inner.isDivergent(node);
  @override
  List<GraphRef> refsOf(int node) => inner.refsOf(node);
  @override
  List<String> workingCopiesOf(int node) => inner.workingCopiesOf(node);
  @override
  String? get workspaceName => inner.workspaceName;
  @override
  GraphCommitContent? contentOf(int node) => inner.contentOf(node);
  @override
  int get version => inner.version;
}

/// A hand-built layout: one (key, row, col) per node, edges as (child, parent) node indices (in any order; a child's
/// edges keep their list order, so its first listed parent is its first parent), [indirect] as positions in [edges],
/// day [buckets] as (value, first row, last row), oldest first. The card facts are optional, one entry per node.
RecordedGraphLayout handLayout(
  List<(String, int, int)> nodes, {
  List<(int, int)> edges = const <(int, int)>[],
  Set<int> indirect = const <int>{},
  int unit = 1,
  int? workingCopy,
  List<(int, int, int)> buckets = const <(int, int, int)>[],
  int? root,
  int utcOffsetMinutes = 0,
  List<int?>? timestamps,
  List<List<GraphRef>>? refs,
  List<GraphCommitContent?>? contents,
  List<int>? flags,
  List<int>? prefixLengths,
  List<int?>? offsets,
  List<List<String>>? workspaces,
  String? workspaceName,
  List<int>? parentCounts,
  List<String>? commitIds,
  List<String>? changeIds,
  String? operationId,
  int? totalCount,
}) {
  // Dart's sort is not stable: sort positions by child, then by position.
  final order = List<int>.generate(edges.length, (k) => k)
    ..sort((a, b) {
      final int byChild = edges[a].$1.compareTo(edges[b].$1);
      return byChild != 0 ? byChild : a.compareTo(b);
    });
  final sorted = <(int, int)>[for (final int k in order) edges[k]];
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
    parentCounts: parentCounts == null ? Int32List(nodes.length) : Int32List.fromList(parentCounts),
    elided: Uint8List(nodes.length),
    timestamps: timestamps,
    refs: refs,
    contents: contents,
    flags: flags == null ? null : Uint8List.fromList(flags),
    changeIdPrefixLengths: prefixLengths == null ? null : Int32List.fromList(prefixLengths),
    changeOffsets: offsets,
    workingCopies: workspaces,
    workspaceName: workspaceName,
    commitIds: commitIds,
    changeIds: changeIds,
    operationId: operationId,
    totalCount: totalCount,
    edgeChildren: Int32List.fromList(<int>[for (final (int child, _) in sorted) child]),
    edgeParents: Int32List.fromList(<int>[for (final (_, int parent) in sorted) parent]),
    edgeKinds: <GraphEdgeKind>[
      for (final int k in order)
        if (indirect.contains(k)) GraphEdgeKind.indirect else GraphEdgeKind.direct,
    ],
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

/// A card that logs its builds and inits, paints a rect in the colour `0xFF000000 + node` and the key as text, inside
/// the overhang the viewport lays every card child out with (so its rect is the card rect).
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
    // The semantics node first, so `getSemantics` of a TestCard finds its own node.
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.all(graphCardOverhang),
        child: GestureDetector(
          onTap: () => widget.log.taps.add(widget.nodeKey),
          child: ColoredBox(
            color: Color(0xFF000000 + widget.node),
            child: Text(widget.nodeKey, textDirection: TextDirection.ltr),
          ),
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
  GraphTransition? transition;
  Duration transitionElapsed = Duration.zero;

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
        transition: transition,
        transitionElapsed: transitionElapsed,
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
