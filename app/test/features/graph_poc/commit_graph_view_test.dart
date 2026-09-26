// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph_poc/commit_card.dart';
import 'package:zanshin/src/features/graph_poc/commit_graph_view.dart';
import 'package:zanshin/src/features/graph_poc/graph_data.dart';
import 'package:zanshin/src/features/graph_poc/graph_geometry.dart';

const rowCount = 100000;
const surface = Size(800, 600);
final graph = CommitGraphData.fake(rowCount);

typedef Harness = ({ScrollController v, ScrollController h, List<int> taps});

Future<Harness> pumpGraph(WidgetTester tester) async {
  tester.view
    ..physicalSize = surface
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final v = ScrollController();
  final h = ScrollController();
  addTearDown(v.dispose);
  addTearDown(h.dispose);
  final taps = <int>[];
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: CommitGraphView(
        graph: graph,
        onTap: taps.add,
        verticalController: v,
        horizontalController: h,
      ),
    ),
  );
  return (v: v, h: h, taps: taps);
}

List<CommitCard> mountedCards(WidgetTester tester) =>
    tester.widgetList<CommitCard>(find.byType(CommitCard, skipOffstage: false)).toList();

Rect viewportRect(Harness g) => Offset(g.h.offset, g.v.offset) & surface;

String describe(List<CommitCard> cards, Harness g) {
  final List<int> rows = cards.map((c) => c.row).toList()..sort();
  final int visible = cards.where((c) => cardRect(c.row, graph.rows[c.row].lane).overlaps(viewportRect(g))).length;
  final Set<int> lanes = cards.map((c) => graph.rows[c.row].lane).toSet();
  return 'mounted=${cards.length} visible=$visible rows=${rows.first}..${rows.last} '
      'lanes=${lanes.toList()..sort()} scroll=(${g.h.offset}, ${g.v.offset})';
}

/// First row in [from, from+20) whose card is fully inside the viewport.
int fullyVisibleRow(Harness g, int from) {
  for (var row = from; row < from + 20; row++) {
    final Rect rect = cardRect(row, graph.rows[row].lane);
    if (viewportRect(g).intersect(rect) == rect) {
      return row;
    }
  }
  throw StateError('no fully visible card near $from');
}

void main() {
  testWidgets('(1) with 100000 rows only the cards around the viewport are built', (tester) async {
    final Harness g = await pumpGraph(tester);
    final List<CommitCard> cards = mountedCards(tester);
    debugPrint('(1) 800x600, $rowCount rows: ${describe(cards, g)}');
    expect(cards.length, lessThan(30));
    expect(cards.map((c) => c.row).reduce((a, b) => a > b ? a : b), lessThan(20));
    expect(find.byType(RawScrollbar), findsNWidgets(2));
  });

  testWidgets('(2) scroll extents are computed from the data alone', (tester) async {
    final Harness g = await pumpGraph(tester);
    final double vMax = g.v.position.maxScrollExtent;
    final double hMax = g.h.position.maxScrollExtent;
    debugPrint(
      '(2) vertical maxScrollExtent=$vMax (rows*rowHeight-h = ${rowCount * rowHeight - surface.height}), '
      'horizontal maxScrollExtent=$hMax (lanes*laneWidth-w = ${graph.laneCount * laneWidth - surface.width})',
    );
    expect(vMax, rowCount * rowHeight - surface.height);
    expect(hMax, graph.laneCount * laneWidth - surface.width);
  });

  testWidgets('(3) jumping to row 50000 mounts only rows near 50000', (tester) async {
    final Harness g = await pumpGraph(tester);
    g.v.jumpTo(50000 * rowHeight);
    await tester.pump();
    final List<CommitCard> cards = mountedCards(tester);
    debugPrint('(3) after jump to row 50000: ${describe(cards, g)}');
    expect(cards.length, lessThan(30));
    for (final card in cards) {
      expect(card.row, inInclusiveRange(50000 - 5, 50000 + 16));
    }
  });

  testWidgets('(4) tapping a card hit-tests through the custom viewport', (tester) async {
    final Harness g = await pumpGraph(tester);
    final int top = fullyVisibleRow(g, 0);
    await tester.tap(find.byWidgetPredicate((w) => w is CommitCard && w.row == top));
    g.v.jumpTo(50000 * rowHeight);
    await tester.pump();
    final int deep = fullyVisibleRow(g, 50000);
    await tester.tap(find.byWidgetPredicate((w) => w is CommitCard && w.row == deep));
    debugPrint('(4) tapped rows $top and $deep -> onTap received ${g.taps}');
    expect(g.taps, <int>[top, deep]);
  });

  testWidgets('(5) scrolling by one viewport renders without exceptions', (tester) async {
    final Harness g = await pumpGraph(tester);
    await tester.drag(find.byType(CommitGraphView), Offset(-surface.width / 2, -surface.height));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugPrint('(5a) after diagonal drag by one viewport: ${describe(mountedCards(tester), g)}');
    expect(g.v.offset, greaterThan(0));
    expect(g.h.offset, greaterThan(0));
    g.v.jumpTo(g.v.offset + surface.height);
    await tester.pump();
    expect(tester.takeException(), isNull);
    debugPrint('(5b) after jumpTo(+one viewport): ${describe(mountedCards(tester), g)}');
  });

  testWidgets('(6) lanes outside the horizontal cache extent are not built', (tester) async {
    final Harness g = await pumpGraph(tester);
    expect(mountedCards(tester).where((c) => graph.rows[c.row].lane == 5), isEmpty);
    g.h.jumpTo(g.h.position.maxScrollExtent);
    await tester.pump();
    final List<CommitCard> cards = mountedCards(tester);
    debugPrint('(6) scrolled fully right: ${describe(cards, g)}');
    expect(cards.where((c) => graph.rows[c.row].lane == 0), isEmpty);
  });

  testWidgets('(7) edges are clipped, batched per color and painted behind the cards', (tester) async {
    await pumpGraph(tester);
    final RenderCommitGraphViewport viewport = tester.allRenderObjects.whereType<RenderCommitGraphViewport>().single;
    final calls = <Symbol>[];
    expect(
      viewport,
      paints..everything((method, arguments) {
        calls.add(method);
        return true;
      }),
    );
    final int paths = calls.where((s) => s == #drawPath).length;
    debugPrint(
      '(7) paint calls: ${calls.length} total, clipRect at ${calls.indexOf(#clipRect)}, '
      '$paths drawPath (last at ${calls.lastIndexOf(#drawPath)}), first card text at ${calls.indexOf(#drawParagraph)}',
    );
    expect(calls.indexOf(#clipRect), lessThan(calls.indexOf(#drawPath)));
    expect(calls.lastIndexOf(#drawPath), lessThan(calls.indexOf(#drawParagraph)));
    expect(paths, inInclusiveRange(1, lanePalette.length));
  });
}
