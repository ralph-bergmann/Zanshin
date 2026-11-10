import 'dart:typed_data';

import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';
import 'package:zanshin_core/src/graph_layout/stacks.dart';

import 'columns.dart';
import 'data.dart';

/// The grid as the app computes it today: the product engine, lane order `compact`.
GraphGridView appGrid(LabData d, LayoutMode mode, {required bool stacks}) => GraphGridView.fromBytes(
  computeGraphGrid(
    d.input,
    mode: mode,
    order: LaneOrder.compact,
    budget: defaultLayoutBudget,
    stacks: stacks ? d.stackInput() : null,
  ),
);

/// The lab's grid: rows and stacks from the product engine, columns from [chooseColumns].
GraphGridView labGrid(
  LabData d,
  LayoutMode mode, {
  required bool stacks,
  required bool reserveToMerge,
  required bool shortFirst,
  required bool sameColumns,
  required bool endsFirst,
  required bool fewestSkipped,
  required bool dockToParent,
}) {
  // packLanes sets the visit order the later phases read; its lanes are replaced below.
  final engine = LayoutEngine(d.input, mode)
    ..layering()
    ..packLanes();
  final Int32List lane = chooseColumns(
    engine,
    reserveToMerge: reserveToMerge,
    shortFirst: shortFirst,
    sameColumns: sameColumns,
    endsFirst: endsFirst,
    fewestSkipped: fewestSkipped,
    dockToParent: dockToParent,
  ).column;
  var count = 0;
  for (final int l in lane) {
    if (l >= count) {
      count = l + 1;
    }
  }
  // Per lane its rows, ascending: `blocked` (and through it the stack pass) reads them.
  final laneYStart = Int32List(count + 1);
  for (final int l in lane) {
    laneYStart[l + 1]++;
  }
  for (var l = 0; l < count; l++) {
    laneYStart[l + 1] += laneYStart[l];
  }
  final cursor = Int32List.fromList(laneYStart);
  final laneYs = Int64List(engine.n);
  for (final int i in engine.visitOrder) {
    laneYs[cursor[lane[i]]++] = engine.y[i];
  }
  engine
    ..lane = lane
    ..laneCount = count
    ..laneYStart = laneYStart
    ..laneYs = laneYs
    ..markBlocked()
    ..route()
    ..col = Int32List.fromList(lane);
  if (!stacks) {
    return GraphGridView.fromBytes(engine.toGrid(LaneOrder.greedy));
  }
  final grouped = StackLayout(engine, d.stackInput())..run();
  return GraphGridView.fromBytes(grouped.toGrid(LaneOrder.greedy));
}
