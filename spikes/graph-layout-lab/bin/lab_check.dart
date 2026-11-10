import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';
import 'package:zanshin_core/src/graph_layout/router.dart';

import '../../../packages/zanshin_core/test/graph_layout/support/spec_json.dart';
import '../lib/columns.dart';
import '../lib/data.dart';
import '../lib/engine.dart';
import '../lib/lines.dart';
import '../lib/metrics.dart';
import '../lib/scene.dart';

/// Checks the lab's rules on every data set under `<data dir>`, in both modes: what must hold
/// whatever the next rule changes, and that the product's columns equal the lab's. With the goldens
/// directory as a second argument it runs the product check on every golden input too, with and
/// without its stack requests. Sets exit code 1 if any check fails, and always runs them all.
///
/// usage: dart --packages=<repo>/.dart_tool/package_config.json run bin/lab_check.dart <data dir> [<goldens dir>]
void main(List<String> a) {
  final names = [
    for (final FileSystemEntity f in Directory(a[0]).listSync())
      if (f.path.endsWith('.json') && !f.path.endsWith('.meta.json')) f.uri.pathSegments.last.replaceAll('.json', ''),
  ]..sort();
  for (final String name in names) {
    final d = LabData.load(a[0], name);
    for (final LayoutMode mode in LayoutMode.values) {
      final List<String> fails = [
        ..._columnFails(d, mode),
        ..._productFails(d.input, d.stackInput(), mode),
        for (final String fail in _productFails(d.input, null, mode)) 'no stacks: $fail',
        ..._lineFails(d, mode, stacks: true),
        for (final String fail in _lineFails(d, mode, stacks: false)) 'no stacks: $fail',
      ];
      stdout.writeln('$name ${mode.name}: ${fails.isEmpty ? 'ok' : fails.take(5).join('; ')}');
      if (fails.isNotEmpty) {
        exitCode = 1;
      }
    }
  }
  if (a.length > 1) {
    _checkGoldens(a[1]);
  }
}

/// The failures of "the product's columns are the lab's" on [input] in [mode] with [stacks].
List<String> _productFails(LayoutInput input, StackInput? stacks, LayoutMode mode) {
  final product = GraphGridView.fromBytes(computeGraphGrid(input, mode: mode, stacks: stacks));
  final GraphGridView lab = labGridOf(
    input,
    stacks,
    mode,
    reserveToMerge: true,
    shortFirst: true,
    sameColumns: false,
    endsFirst: true,
    fewestSkipped: false,
    dockToParent: true,
  );
  if (product.lanes != lab.lanes) {
    return ['product ${product.lanes} columns, lab ${lab.lanes}'];
  }
  for (var i = 0; i < product.nodeCols.length; i++) {
    if (product.nodeCols[i] != lab.nodeCols[i] || product.nodeRows[i] != lab.nodeRows[i]) {
      return [
        'node $i: product row ${product.nodeRows[i]} col ${product.nodeCols[i]}, '
            'lab row ${lab.nodeRows[i]} col ${lab.nodeCols[i]}',
      ];
    }
  }
  return const [];
}

/// Runs [_productFails] on every golden input under [goldens], in both modes.
void _checkGoldens(String goldens) {
  var checked = 0;
  void check(Uint8List bytes, List<Uint8List> requests, String what) {
    final bool stacked = requests.isNotEmpty;
    final ({LayoutInput input, int nowMs, SpecStackFacts? facts}) parsed = parseSpecInput(bytes, stacks: stacked);
    for (final LayoutMode mode in LayoutMode.values) {
      final List<String> fails = [
        ..._productFails(parsed.input, null, mode),
        for (final Uint8List request in requests)
          ..._productFails(parsed.input, parseSpecStackRequest(request, parsed.facts!), mode),
      ];
      checked += 1 + requests.length;
      if (fails.isNotEmpty) {
        stdout.writeln('$what ${mode.name}: ${fails.take(5).join('; ')}');
        exitCode = 1;
      }
    }
  }

  Uint8List file(String path) => File('$goldens/$path').readAsBytesSync();
  for (final String path in const [
    'design/design-default.json',
    'design/design-all.json',
    'fixtures/tiny-all.input.json',
    'fixtures/medium-narrow.input.json',
  ]) {
    check(file(path), const [], path);
  }
  for (final String rev in const ['default', 'all']) {
    final requests = [
      for (final String state in const ['default', 'expanded', 'mixed']) file('stacks/request-$state.json'),
    ];
    check(file('stacks/design-$rev.json'), requests, 'stacks/design-$rev.json');
  }
  final List<String> cases = File('$goldens/fuzz/cases.jsonl').readAsLinesSync();
  for (var c = 0; c < cases.length; c++) {
    check(utf8.encode(cases[c]), const [], 'fuzz case $c');
  }
  final List<String> stackCases = File('$goldens/stacks/fuzz/cases.jsonl').readAsLinesSync();
  for (var c = 0; c < stackCases.length; c++) {
    final line = jsonDecode(stackCases[c]) as Map<String, Object?>;
    check(utf8.encode(jsonEncode(line['input'])), [utf8.encode(jsonEncode(line['request']))], 'stack fuzz case $c');
  }
  stdout.writeln('goldens: $checked layouts${exitCode == 0 ? ': ok' : ''}');
}

/// The column rules, with every combination of the two column switches: the main branch alone in
/// column 0, one column per branch, no two branches of a column on the same rows. With "short
/// first": a branch whose rows lie inside another's sits nearer to the main branch.
List<String> _columnFails(LabData d, LayoutMode mode) {
  final fails = <String>[];
  final e = LayoutEngine(d.input, mode)..layering();
  final cont = e.continuations();
  // With "same columns" both modes get the same column for every card.
  final other = LayoutEngine(d.input, mode == LayoutMode.free ? LayoutMode.compact : LayoutMode.free)..layering();
  Int32List joint(LayoutEngine g) => chooseColumns(
    g,
    reserveToMerge: true,
    shortFirst: true,
    sameColumns: true,
    endsFirst: true,
    fewestSkipped: false,
    dockToParent: true,
  ).column;
  final Int32List here = joint(e);
  final Int32List there = joint(other);
  for (var i = 0; i < e.n; i++) {
    if (here[i] != there[i]) {
      fails.add('same columns: card $i is in column ${here[i]} here and ${there[i]} in the other mode');
      break;
    }
  }
  for (final (bool reserve, bool short, bool same, bool ends, bool skipped, bool dock) in [
    (false, false, false, false, false, false),
    (false, true, false, false, false, false),
    (true, false, false, false, false, false),
    (true, true, false, false, false, false),
    (true, true, false, true, false, false),
    (true, true, false, true, false, true),
    (true, true, true, true, false, false),
    (true, true, true, true, true, false),
    (true, true, true, true, false, true),
  ]) {
    {
      final what = 'reserve $reserve, short $short, same $same, ends $ends, skipped $skipped, dock $dock';
      final Placement p = chooseColumns(
        e,
        reserveToMerge: reserve,
        shortFirst: short,
        sameColumns: same,
        endsFirst: ends,
        fewestSkipped: skipped,
        dockToParent: dock,
      );
      for (var i = 0; i < e.n; i++) {
        if (d.input.priority[i] == 0 && p.column[i] != 0) {
          fails.add('$what: main card $i in column ${p.column[i]}');
        }
        final int f = e.fp[i];
        if (f >= 0 && cont[f] == i && p.column[f] != p.column[i]) {
          fails.add('$what: the branch breaks between $f and $i');
        }
      }
      final int chains = p.columnOf.length;
      for (var a = 0; a < chains; a++) {
        if (a != p.main && p.columnOf[a] == 0) {
          fails.add('$what: branch $a shares column 0 with the main branch');
        }
        for (var b = 0; b < chains; b++) {
          if (a == b || a == p.main || b == p.main) {
            continue;
          }
          final bool sameRows = p.lo[a] < p.hi[b] + e.unit && p.lo[b] < p.hi[a] + e.unit;
          if (a < b && sameRows && p.columnOf[a] == p.columnOf[b]) {
            fails.add('$what: branches $a and $b overlap in column ${p.columnOf[a]}');
          }
          final bool inside = p.lo[b] <= p.lo[a] && p.hi[a] <= p.hi[b] && p.hi[a] - p.lo[a] < p.hi[b] - p.lo[b];
          // With "same columns" the other mode's rows decide too, so this holds per mode only without it.
          // With "fewest skipped" it does not hold for two branches that fork from different branches,
          // with "dock to parent" not for a side branch and its branch.
          if (short && !same && !skipped && !dock && inside && p.columnOf[a] >= p.columnOf[b]) {
            fails.add('$what: branch $a lies inside $b but not nearer to the main branch');
          }
        }
      }
    }
  }
  return fails;
}

/// Whether a vertical run of [p] crosses a horizontal run of [q] (x, y pairs), not just touches it.
bool _crosses(List<double> p, List<double> q) {
  for (var i = 0; i + 3 < p.length; i += 2) {
    if (p[i] != p[i + 2]) {
      continue;
    }
    final double top = p[i + 1] < p[i + 3] ? p[i + 1] : p[i + 3];
    final double bottom = p[i + 1] < p[i + 3] ? p[i + 3] : p[i + 1];
    for (var j = 0; j + 3 < q.length; j += 2) {
      final double left = q[j] < q[j + 2] ? q[j] : q[j + 2];
      final double right = q[j] < q[j + 2] ? q[j + 2] : q[j];
      if (q[j + 1] == q[j + 3] && left < p[i] && p[i] < right && top < q[j + 1] && q[j + 1] < bottom) {
        return true;
      }
    }
  }
  return false;
}

/// The line rules: every line is drawn with right angles, from its parent's top to its child's
/// bottom; no run passes behind a card; the lines of one card do not cross each other and turn in
/// the order of their columns.
List<String> _lineFails(LabData d, LayoutMode mode, {required bool stacks}) {
  final fails = <String>[];
  const m = RouteMetrics(width: 240, height: 62);
  final GraphGridView grid = labGrid(
    d,
    mode,
    stacks: stacks,
    reserveToMerge: true,
    shortFirst: true,
    sameColumns: false,
    endsFirst: true,
    fewestSkipped: false,
    dockToParent: true,
  );
  var maxRow = 0;
  for (final int row in grid.nodeRows) {
    maxRow = row > maxRow ? row : maxRow;
  }
  final cardOf = [
    for (var i = 0; i < grid.nodeRows.length; i++)
      grid.nodeRows[i] < 0
          ? null
          : LabCard(
              node: i,
              col: grid.nodeCols[i],
              x: m.pad + grid.nodeCols[i] * (m.width + m.gapX),
              y: m.pad + (maxRow - grid.nodeRows[i]) / grid.unit * (m.height + m.gapY),
            ),
  ];
  final List<LabLine> lines = labLines(
    grid,
    cardOf,
    m,
    dodge: true,
    freeLevels: true,
    spread: true,
    ports: true,
    bendAtParent: true,
    noOverlap: true,
    fewerCrossings: true,
    columnOrder: true,
    tightFans: true,
    tieBreak: true,
  );
  // No line passes behind a card, with a vertical or a horizontal run (the page's metric).
  if (measure(cardOf.nonNulls.toList(), lines, m)['behind']! > 0) {
    fails.add(
      'lines ${[for (final LabLine line in lines)
        if (line.behind) line.edge].join(', ')} pass behind a card',
    );
  }
  // Two lines that both turn right at one card edge (within a row gap of it) never cross each
  // other. A line that turns far away may cross them: cards lie in between.
  final byCard = <(int, bool), List<LabLine>>{};
  for (final LabLine line in lines) {
    final List<double> p = line.pts;
    if (p.length < 6) {
      continue;
    }
    if (p[1] - p[3] < m.gapY) {
      (byCard[(line.from, true)] ??= []).add(line);
    }
    if (p[p.length - 3] - p.last < m.gapY) {
      (byCard[(line.to, false)] ??= []).add(line);
    }
  }
  for (final List<LabLine> edge in byCard.values) {
    for (var a = 0; a < edge.length; a++) {
      for (var b = 0; b < edge.length; b++) {
        if (a != b && _crosses(edge[a].pts, edge[b].pts)) {
          fails.add('lines ${edge[a].edge} and ${edge[b].edge} of one card cross');
        }
      }
    }
  }
  // The lines that turn at one card edge leave and arrive in the order of the columns they connect
  // to. The line at the centre goes straight on and is no part of that order.
  final turning = <(int, bool), List<(double, int)>>{};
  for (final LabLine line in lines) {
    final List<double> p = line.pts;
    final LabCard from = cardOf[line.from]!;
    final LabCard to = cardOf[line.to]!;
    if (p[0] != from.x + m.width / 2) {
      (turning[(line.from, true)] ??= []).add((p[0], to.col));
    }
    if (p[p.length - 2] != to.x + m.width / 2) {
      (turning[(line.to, false)] ??= []).add((p[p.length - 2], from.col));
    }
  }
  for (final MapEntry<(int, bool), List<(double, int)>> edge in turning.entries) {
    final List<(double, int)> ports = edge.value..sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < ports.length; i++) {
      if (ports[i - 1].$2 > ports[i].$2) {
        fails.add('the lines of card ${edge.key.$1} are not in column order');
        break;
      }
    }
  }
  // Two lines of one card edge never share a port.
  final ports = <(int, bool, double)>{};
  for (final LabLine line in lines) {
    final List<double> p = line.pts;
    final LabCard from = cardOf[line.from]!;
    final LabCard to = cardOf[line.to]!;
    // A port lies on the card's edge, at least 18 px from its corners.
    bool on(LabCard card, double x) => card.x + 18 <= x && x <= card.x + m.width - 18;
    if (!on(from, p[0]) || p[1] != from.y || !on(to, p[p.length - 2]) || p.last != to.y + m.height) {
      fails.add('line ${line.edge} misses a card edge');
    }
    if (!ports.add((line.from, true, p[0])) || !ports.add((line.to, false, p[p.length - 2]))) {
      fails.add('line ${line.edge} shares a port');
    }
    for (var q = 0; q + 3 < p.length; q += 2) {
      if (p[q] != p[q + 2] && p[q + 1] != p[q + 3]) {
        fails.add('line ${line.edge} has a slanted run');
      }
      if (p[q] != p[q + 2]) {
        continue;
      }
      final double top = p[q + 1] < p[q + 3] ? p[q + 1] : p[q + 3];
      final double bottom = p[q + 1] < p[q + 3] ? p[q + 3] : p[q + 1];
      for (final LabCard? card in cardOf) {
        if (card != null &&
            card.node != line.from &&
            card.node != line.to &&
            card.x < p[q] &&
            p[q] < card.x + m.width &&
            card.y < bottom &&
            card.y + m.height > top) {
          fails.add('line ${line.edge} runs behind card ${card.node}');
        }
      }
    }
  }
  return fails;
}
