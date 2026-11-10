import 'dart:typed_data';

import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';
import 'package:zanshin_core/src/graph_layout/router.dart';

import 'data.dart';
import 'engine.dart';
import 'lines.dart';
import 'metrics.dart';

/// The lab's switches: id, label on the page, default.
const labRules = <(String, String, bool)>[
  ('short-first', 'Kurze Zweige zuerst, nah an Main', true),
  ('ends-first', 'Wer zuerst endet, sitzt näher an Main', true),
  ('fewest-skipped', 'Wer weniger Commits überspringt, sitzt näher an Main', false),
  ('dock-to-parent', 'Seitenzweig, der in seinen Zweig zurückmündet, sitzt neben ihm', true),
  ('reserve-to-merge', 'Spalte bis zum Merge belegt', true),
  ('same-columns', 'Gleiche Spalten in Free und Compact', false),
  ('dodge', 'Linien weichen Karten aus', true),
  ('free-level', 'Waagerechte suchen eine freie Höhe', true),
  ('spread', 'Waagerechte teilen den Platz gleichmäßig', true),
  ('ports', 'Anschlüsse im Fächer, Linien einzeln', true),
  ('bend-at-parent', 'Merge biegt an der Elternkarte ab, wenn ihr Zweig weiterläuft', true),
  ('no-overlap', 'Linien liegen nicht übereinander (lieber eine Kreuzung)', true),
  (
    'fewer-crossings',
    'Merge biegt an der Elternkarte ab und steigt neben der Zielspalte, wenn das Kreuzungen spart',
    true,
  ),
  ('column-order', 'Linien verlassen eine Karte immer in der Reihenfolge ihrer Spalten', true),
  ('tight-fan', 'Ein Fächer teilt sich eine enge Stelle, statt Linien übereinander zu legen', true),
  ('tie-break', 'Zwei Linien verschiedener Karten teilen sich keine Senkrechte', true),
];

/// The ids of the switches that are on when a request names none.
Set<String> defaultRules() => {
  for (final (String id, String _, bool on) in labRules)
    if (on) id,
};

/// One card on the page, in pixels. [node] is a grid node: an input node or a stack.
final class LabCard {
  LabCard({required this.node, required this.col, required this.x, required this.y});

  final int node;
  final int col;
  final double x;
  final double y;

  /// Whether a free cell lies nearer to the card's lines; set by [measure].
  bool nearer = false;
}

/// One line on the page: [pts] are x, y pairs from the parent's top edge to the child's bottom edge.
final class LabLine {
  LabLine({required this.edge, required this.from, required this.to, required this.pts, required this.dashed});

  final int edge;
  final int from;
  final int to;
  final List<double> pts;
  final bool dashed;

  /// Whether the line passes behind a card; set by [measure].
  bool behind = false;
}

/// Lays [d] out and returns what the page draws, as JSON-ready maps. [lab] picks the lab's columns
/// and lines; otherwise the product engine and its router run unchanged. [rules] are the ids of the
/// switches that are on ([labRules]).
Map<String, Object?> buildScene(
  LabData d, {
  required bool lab,
  required LayoutMode mode,
  required bool stacks,
  required Set<String> rules,
}) {
  final clock = Stopwatch()..start();
  const m = RouteMetrics(width: 240, height: 62);
  final GraphGridView grid = lab
      ? labGrid(
          d,
          mode,
          stacks: stacks,
          reserveToMerge: rules.contains('reserve-to-merge'),
          shortFirst: rules.contains('short-first'),
          sameColumns: rules.contains('same-columns'),
          endsFirst: rules.contains('ends-first'),
          fewestSkipped: rules.contains('fewest-skipped'),
          dockToParent: rules.contains('dock-to-parent'),
        )
      : appGrid(d, mode, stacks: stacks);

  final int n = grid.nodeCount;
  final int nodes = grid.nodeRows.length;
  var maxRow = 0;
  for (final int row in grid.nodeRows) {
    if (row > maxRow) {
      maxRow = row;
    }
  }
  final double pitch = m.height + m.gapY;
  final double colW = m.width + m.gapX;
  final cardOf = List<LabCard?>.filled(nodes, null);
  for (var i = 0; i < nodes; i++) {
    final int row = grid.nodeRows[i];
    if (row < 0) {
      continue; // a member of a collapsed stack
    }
    cardOf[i] = LabCard(
      node: i,
      col: grid.nodeCols[i],
      x: m.pad + grid.nodeCols[i] * colW,
      y: m.pad + (maxRow - row) / grid.unit * pitch,
    );
  }
  final List<LabCard> cards = cardOf.nonNulls.toList();

  final List<LabLine> lines = lab
      ? labLines(
          grid,
          cardOf,
          m,
          dodge: rules.contains('dodge'),
          freeLevels: rules.contains('free-level'),
          spread: rules.contains('spread'),
          ports: rules.contains('ports'),
          bendAtParent: rules.contains('bend-at-parent'),
          noOverlap: rules.contains('no-overlap'),
          fewerCrossings: rules.contains('fewer-crossings'),
          columnOrder: rules.contains('column-order'),
          tightFans: rules.contains('tight-fan'),
          tieBreak: rules.contains('tie-break'),
        )
      : _appLines(d, grid, m);
  final Map<String, int> metrics = measure(cards, lines, m);

  // The members of every stack node, oldest first.
  final members = <int, List<int>>{};
  if (grid.hasStacks) {
    for (var r = 0; r < grid.runCount; r++) {
      final int node = grid.runNodes![r];
      if (node >= 0) {
        members[node] = grid.runMembers!.sublist(grid.runStarts![r], grid.runStarts![r + 1]);
      }
    }
  }
  String short(int i) => (d.meta[i]['change_id']! as String).substring(0, 8);
  Map<String, Object?> cardJson(LabCard card) {
    final List<int> run = members[card.node] ?? const [];
    final int top = run.isEmpty ? card.node : run.last; // a stack shows its newest member
    final Map<String, Object?> meta = d.meta[top];
    final String description = meta['description']! as String;
    return {
      'n': card.node,
      'x': card.x,
      'y': card.y,
      'id': run.isEmpty ? short(top) : '${short(run.first)}…${short(top)}',
      'title': description.isEmpty ? '(no description)' : description,
      'sub': '${meta['author']} · ${_date(meta['committer_ts_ms']! as int, d.input.utcOffsetMin)}',
      'refs': [
        for (final Object? b in meta['bookmarks']! as List)
          if ((b! as Map)['remote'] == null) (b as Map)['name'],
      ],
      if (run.isNotEmpty) 'stack': run.length,
      if (d.input.priority[top] == 0) 'main': true,
      if (meta['working_copy'] == true) 'wc': true,
      if (card.nearer) 'nearer': true,
    };
  }

  return {
    'engine': lab ? 'lab' : 'app',
    'mode': mode.name,
    'cardWidth': m.width,
    'cardHeight': m.height,
    'width': m.pad * 2 + metrics['columns']! * colW,
    'height': m.pad * 2 + maxRow / grid.unit * pitch + m.height,
    'cards': [for (final LabCard card in cards) cardJson(card)],
    'lines': [
      for (final LabLine line in lines)
        {
          'e': line.edge,
          'from': line.from,
          'to': line.to,
          'pts': line.pts,
          if (line.dashed) 'dashed': true,
          if (line.behind) 'behind': true,
        },
    ],
    'days': mode == LayoutMode.free ? _days(d, grid, cards, m) : const <Object?>[],
    'metrics': metrics,
    'rules': [
      for (final (String id, String label, bool _) in labRules) {'id': id, 'label': label, 'on': rules.contains(id)},
    ],
    'nodes': n,
    'ms': clock.elapsedMilliseconds,
  };
}

/// The app's lines: the product router on [grid].
List<LabLine> _appLines(LabData d, GraphGridView grid, RouteMetrics m) {
  final int n = d.input.n;
  final classes = RouteClasses.compute(
    nodeRows: grid.nodeRows,
    nodeCols: grid.nodeCols,
    unit: grid.unit,
    free: grid.mode == LayoutMode.free,
    edgeFroms: grid.edgeFroms,
    edgeTos: grid.edgeTos,
    edgeKinds: grid.edgeKinds,
    parentCounts: Int32List.fromList([for (var i = 0; i < n; i++) d.input.parStart[i + 1] - d.input.parStart[i]]),
  );
  final geometry = RouteGeometry.compute(classes, m);
  return [
    for (var k = 0; k < grid.edgeCount; k++)
      LabLine(
        edge: k,
        from: grid.edgeFroms[k],
        to: grid.edgeTos[k],
        pts: geometry.points.sublist(2 * geometry.pointStarts[k], 2 * geometry.pointStarts[k + 1]),
        dashed: grid.edgeKinds[k] == GraphGridView.edgeKindIndirect,
      ),
  ];
}

/// One mark per change of day between vertically neighbouring cards: its y and the newer day.
List<Object?> _days(LabData d, GraphGridView grid, List<LabCard> cards, RouteMetrics m) {
  final List<LabCard> byY = [...cards]..sort((a, b) => b.y.compareTo(a.y)); // oldest first
  final marks = <Object?>[];
  int? day;
  for (final LabCard card in byY) {
    final int key = grid.nodeDays[card.node];
    if (key == GraphGridView.noDay) {
      continue;
    }
    if (day != null && key != day) {
      marks.add({'y': card.y + m.height + m.gapY / 2, 'label': _date(key, d.input.utcOffsetMin)});
    }
    day = key;
  }
  return marks;
}

/// The local calendar day of the epoch milliseconds [ms], as `2014-11-20`.
String _date(int ms, int utcOffsetMin) {
  final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(Duration(minutes: utcOffsetMin));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}
