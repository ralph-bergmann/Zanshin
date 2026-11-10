import 'dart:typed_data';

import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';
import 'package:zanshin_core/src/graph_layout/stacks.dart';

import 'columns.dart';
import 'data.dart';

/// The grid as the app computes it today: the product engine.
GraphGridView appGrid(LabData d, LayoutMode mode, {required bool stacks}) =>
    GraphGridView.fromBytes(computeGraphGrid(d.input, mode: mode, stacks: stacks ? d.stackInput() : null));

/// [labGridOf] for the data set [d], with its default stack request when [stacks] is set.
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
}) => labGridOf(
  d.input,
  stacks ? d.stackInput() : null,
  mode,
  reserveToMerge: reserveToMerge,
  shortFirst: shortFirst,
  sameColumns: sameColumns,
  endsFirst: endsFirst,
  fewestSkipped: fewestSkipped,
  dockToParent: dockToParent,
);

/// The lab's grid of [input]: rows and stacks from the product engine, columns from [chooseColumns].
GraphGridView labGridOf(
  LayoutInput input,
  StackInput? stacks,
  LayoutMode mode, {
  required bool reserveToMerge,
  required bool shortFirst,
  required bool sameColumns,
  required bool endsFirst,
  required bool fewestSkipped,
  required bool dockToParent,
}) {
  // The product's chooseColumns sets the visit order the later phases read; its lanes are replaced below.
  final engine = LayoutEngine(input, mode)
    ..layering()
    ..chooseColumns();
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
  if (stacks == null) {
    return GraphGridView.fromBytes(engine.toGrid());
  }
  final grouped = StackLayout(engine, stacks)..run();
  return GraphGridView.fromBytes(grouped.toGrid());
}
