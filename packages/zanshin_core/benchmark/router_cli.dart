// SPDX-License-Identifier: MIT

// Story 4.15: line router B (docs/graph-layout.md §14) from the command line — the oracle's Dart
// side (spikes/graph-layout-ab/tools/router-oracle.mjs), a route check on a §2 input and a
// benchmark. Not part of the test gate; it imports nothing that reaches `dart:ffi`.
//
// ```text
// router_cli oracle <cases.json> <out.json>
// router_cli check --mode compact|free --order greedy|compact --width W --height H <input.json>
// router_cli bench --mode compact|free --order greedy|compact --width W --height H [--runs N] [--warmup W] <input.json>
// ```
//
// `oracle` routes GL's own grids (the cases the oracle tool writes) and writes per case the kinds,
// polylines, ports, bridges and reports. `check` lays the input out with the product engine
// (`computeGraphGrid`, no stacks), routes it and prints one JSON line of counts: kinds, reports,
// the segments inside a non-endpoint card (split into explained = on a reported edge and not, and
// into those on the engine's blocked merges). `bench` prints one JSON line with the class stage,
// the geometry stage and one 1200 × 800 bridge window (at the plane's left edge, vertically
// centred, where the trunk's lines run) medians; parsing and
// the layout are untimed. Exit code 2 on a usage error or an invalid input. Run from
// `packages/zanshin_core`:
//
// ```sh
// dart compile exe benchmark/router_cli.dart -o <dir>/router_cli
// ```

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';
import 'package:zanshin_core/src/graph_layout/router.dart';

import '../test/graph_layout/support/router_scan.dart';
import '../test/graph_layout/support/spec_json.dart';

const _usage = '''
usage:
  router_cli oracle <cases.json> <out.json>
  router_cli check --mode compact|free --order greedy|compact --width W --height H <input.json>
  router_cli bench --mode compact|free --order greedy|compact --width W --height H [--runs N] [--warmup W] <input.json>''';

/// A usage error or an invalid input: exit code 2.
final class _Exit2 implements Exception {
  _Exit2(this.message);

  final String message;
}

const _kindNames = <String>['straight', 'fork', 'merge-adjacent', 'merge-up', 'gutter'];

void main(List<String> args) {
  try {
    if (args.isEmpty) {
      throw _Exit2('missing command');
    }
    final void Function(List<String>) run = switch (args.first) {
      'oracle' => _oracle,
      'check' => _check,
      'bench' => _bench,
      _ => throw _Exit2('unknown command "${args.first}"'),
    };
    run(args.sublist(1));
  } on _Exit2 catch (e) {
    stderr
      ..writeln('router_cli: ${e.message}')
      ..writeln(_usage);
    exitCode = 2;
  } on SpecInputError catch (e) {
    stderr.writeln('router_cli: invalid input: ${e.message}');
    exitCode = 2;
  } on LayoutContractException catch (e) {
    stderr.writeln('router_cli: invalid input: ${e.rule}: ${e.message}');
    exitCode = 2;
  }
}

/// The oracle cases: `{"cases": [{"name", "width", "height", "free", "unit", "rows", "cols",
/// "parent_counts", "edges": [[from, to, kind], …]}]}` (kind 0 direct, 1 indirect).
void _oracle(List<String> args) {
  if (args.length != 2) {
    throw _Exit2('oracle takes <cases.json> <out.json>');
  }
  final Object? doc = jsonDecode(utf8.decode(_read(args[0])));
  if (doc is! Map<String, Object?> || doc['cases'] is! List<Object?>) {
    throw _Exit2('oracle: expected {"cases": [...]}');
  }
  final out = <Object?>[];
  for (final raw in doc['cases']! as List<Object?>) {
    final spec = raw! as Map<String, Object?>;
    Int32List ints(String key) => Int32List.fromList([for (final Object? v in spec[key]! as List<Object?>) v! as int]);
    final edges = spec['edges']! as List<Object?>;
    final froms = Int32List(edges.length);
    final tos = Int32List(edges.length);
    final kinds = Uint8List(edges.length);
    for (var k = 0; k < edges.length; k++) {
      final triple = edges[k]! as List<Object?>;
      froms[k] = triple[0]! as int;
      tos[k] = triple[1]! as int;
      kinds[k] = triple[2]! as int;
    }
    final classes = RouteClasses.compute(
      nodeRows: ints('rows'),
      nodeCols: ints('cols'),
      unit: spec['unit']! as int,
      free: spec['free']! as bool,
      edgeFroms: froms,
      edgeTos: tos,
      edgeKinds: kinds,
      parentCounts: ints('parent_counts'),
    );
    final g = RouteGeometry.compute(
      classes,
      RouteMetrics(width: (spec['width']! as num).toDouble(), height: (spec['height']! as num).toDouble()),
    );
    final RouteBridges all = g.bridges(
      double.negativeInfinity,
      double.negativeInfinity,
      double.infinity,
      double.infinity,
    );
    out.add({
      'name': spec['name'],
      'kinds': [for (var k = 0; k < classes.edgeCount; k++) _kindNames[classes.kinds[k]]],
      'gutters': [
        for (var k = 0; k < classes.edgeCount; k++)
          if (classes.kinds[k] == RouteClasses.kindGutter) classes.gutters[k] else null,
      ],
      'slots': classes.slots,
      'points': [
        for (var k = 0; k < classes.edgeCount; k++)
          [for (int q = 2 * g.pointStarts[k]; q < 2 * g.pointStarts[k + 1]; q++) g.points[q]],
      ],
      'ports': [
        for (var i = 0; i < classes.nodeRows.length; i++)
          [for (int q = g.portStarts[i]; q < g.portStarts[i + 1]; q++) g.portXs[q]],
      ],
      'bridges': [
        for (var q = 0; q < all.length; q++)
          [all.xs[q], all.ys[q], all.horizontalEdges[q], all.verticalEdges[q], all.verticalBreaks[q]],
      ],
      'direct_fallbacks': classes.directFallbacks,
      'overfull_gutters': classes.overfullGutters,
      'overfull_clusters': g.overfullClusters,
      'unavoidable_crossings': g.unavoidableCrossings,
    });
  }
  try {
    File(args[1]).writeAsStringSync('${jsonEncode({'cases': out})}\n');
  } on FileSystemException catch (e) {
    throw _Exit2('cannot write ${args[1]}: ${e.message}');
  }
}

/// A §2 input laid out by the product engine, ready to route.
typedef _Laid = ({GraphGridView grid, Int32List parentCounts, int n});

_Laid _layOut(_Cli cli, Uint8List bytes) {
  final LayoutInput input = parseSpecInput(bytes).input;
  final grid = GraphGridView.fromBytes(
    computeGraphGrid(input, mode: cli.mode, order: cli.order, budget: defaultLayoutBudget),
  );
  // shortcut: parentCount = the input's parent entries (Missing and repeated Indirect edges
  // included), not jj's real parent count, so a hidden merge reached through two Indirect entries
  // never shares an entry here; read the input's stack facts (`parent_count`) when a measured input
  // carries them.
  final counts = Int32List(input.n);
  for (var i = 0; i < input.n; i++) {
    counts[i] = input.parStart[i + 1] - input.parStart[i];
  }
  return (grid: grid, parentCounts: counts, n: input.n);
}

RouteClasses _classes(_Laid laid) => RouteClasses.compute(
  nodeRows: laid.grid.nodeRows,
  nodeCols: laid.grid.nodeCols,
  unit: laid.grid.unit,
  free: laid.grid.mode == LayoutMode.free,
  edgeFroms: laid.grid.edgeFroms,
  edgeTos: laid.grid.edgeTos,
  edgeKinds: laid.grid.edgeKinds,
  parentCounts: laid.parentCounts,
);

void _check(List<String> args) {
  final cli = _Cli.parse(args, bench: false);
  final _Laid laid = _layOut(cli, _read(cli.input));
  final RouteClasses classes = _classes(laid);
  final g = RouteGeometry.compute(classes, RouteMetrics(width: cli.width, height: cli.height));
  final kinds = Int32List(5);
  for (var k = 0; k < classes.edgeCount; k++) {
    kinds[classes.kinds[k]]++;
  }
  // The engine's blocked merges (a non-first parent in another lane with `blocked`): defect 2.
  final GraphGridView grid = laid.grid;
  final blockedMerge = Uint8List(classes.edgeCount);
  var blockedMerges = 0;
  var blockedMergeGutters = 0;
  for (var k = 0; k < classes.edgeCount; k++) {
    if (grid.edgeBlocked[k] != 0 && classes.firstParents[k] == 0) {
      blockedMerge[k] = 1;
      blockedMerges++;
      if (classes.kinds[k] == RouteClasses.kindGutter) {
        blockedMergeGutters++;
      }
    }
  }
  final Uint8List overfullGutter = overfullGutterEdges(classes);
  var vertical = 0;
  var horizontal = 0;
  var explained = 0;
  var onBlockedMerges = 0;
  var onBlockedMergesVertical = 0;
  final List<CardHit> hits = cardHits(g);
  for (final hit in hits) {
    if (hit.vertical) {
      vertical++;
    } else {
      horizontal++;
    }
    final int k = hit.edge;
    if (classes.fallbackEdges[k] != 0 || g.overfullEdges[k] != 0 || overfullGutter[k] != 0) {
      explained++;
    }
    if (blockedMerge[k] != 0) {
      onBlockedMerges++;
      if (hit.vertical) {
        onBlockedMergesVertical++;
      }
    }
  }
  stdout.writeln(
    jsonEncode({
      'input': File(cli.input).uri.pathSegments.last,
      'mode': cli.mode.name,
      'order': cli.order.name,
      'width': cli.width,
      'height': cli.height,
      'nodes': laid.n,
      'edges': classes.edgeCount,
      'kinds': {for (var q = 0; q < 5; q++) _kindNames[q]: kinds[q]},
      'direct_fallbacks': classes.directFallbacks,
      'overfull_gutters': classes.overfullGutters,
      'overfull_clusters': g.overfullClusters,
      'unavoidable_crossings': g.unavoidableCrossings,
      'blocked_merges': blockedMerges,
      'blocked_merges_on_gutters': blockedMergeGutters,
      'card_hits': {
        'total': hits.length,
        'vertical': vertical,
        'horizontal': horizontal,
        'explained': explained,
        'unexplained': hits.length - explained,
        'blocked_merges': onBlockedMerges,
        'blocked_merges_vertical': onBlockedMergesVertical,
      },
    }),
  );
}

void _bench(List<String> args) {
  final cli = _Cli.parse(args, bench: true);
  final int runs = cli.runs ?? 15;
  final int warmup = cli.warmup ?? 5;
  if (runs < 1) {
    throw _Exit2('--runs must be ≥ 1');
  }
  if (warmup < 0) {
    throw _Exit2('--warmup must be ≥ 0');
  }
  final _Laid laid = _layOut(cli, _read(cli.input)); // untimed
  final metrics = RouteMetrics(width: cli.width, height: cli.height);
  final GraphGridView grid = laid.grid;
  var maxRow = 0;
  for (var i = 0; i < grid.nodeRows.length; i++) {
    if (grid.nodeRows[i] > maxRow) {
      maxRow = grid.nodeRows[i];
    }
  }
  final double planeH = 2 * metrics.pad + maxRow / grid.unit * (metrics.height + metrics.gapY) + metrics.height;
  const double x0 = 0;
  final double y0 = planeH / 2 - 400;
  final classSamples = Int64List(runs);
  final geometrySamples = Int64List(runs);
  final bridgeSamples = Int64List(runs);
  final sw = Stopwatch()..start();
  RouteClasses? classes;
  RouteGeometry? g;
  var bridges = 0;
  for (var iter = 0; iter < warmup + runs; iter++) {
    final int t0 = sw.elapsedTicks;
    classes = _classes(laid);
    final int t1 = sw.elapsedTicks;
    g = RouteGeometry.compute(classes, metrics);
    final int t2 = sw.elapsedTicks;
    bridges = g.bridges(x0, y0, x0 + 1200, y0 + 800).length;
    final int t3 = sw.elapsedTicks;
    if (iter < warmup) {
      continue;
    }
    final int r = iter - warmup;
    classSamples[r] = _ns(t1 - t0, sw.frequency);
    geometrySamples[r] = _ns(t2 - t1, sw.frequency);
    bridgeSamples[r] = _ns(t3 - t2, sw.frequency);
  }
  Map<String, int> stats(Int64List s) {
    final sorted = Int64List.fromList(s)..sort();
    return {'median_ns': sorted[runs ~/ 2], 'min_ns': sorted[0]};
  }

  stdout.writeln(
    jsonEncode({
      'impl': const bool.fromEnvironment('dart.vm.product') ? 'dart-core-aot' : 'dart-core-jit',
      'input': File(cli.input).uri.pathSegments.last,
      'mode': cli.mode.name,
      'order': cli.order.name,
      'width': cli.width,
      'height': cli.height,
      'nodes': laid.n,
      'edges': classes!.edgeCount,
      'runs_h': g!.horizontalYs.length,
      'runs_v': g.verticalXs.length,
      'window_bridges': bridges,
      'warmup': warmup,
      'runs': runs,
      'phases': {'class': stats(classSamples), 'geometry': stats(geometrySamples), 'bridges': stats(bridgeSamples)},
    }),
  );
}

/// Stopwatch ticks × 10^9 div frequency; skips the multiply when ticks are already ns.
int _ns(int ticks, int frequency) => frequency == 1000000000 ? ticks : ticks * 1000000000 ~/ frequency;

Uint8List _read(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException catch (e) {
    throw _Exit2('cannot read $path: ${e.message}');
  }
}

final class _Cli {
  _Cli(this.mode, this.order, this.width, this.height, this.runs, this.warmup, this.input);

  factory _Cli.parse(List<String> args, {required bool bench}) {
    final flags = <String, String>{};
    final positional = <String>[];
    for (var k = 0; k < args.length; k++) {
      final String arg = args[k];
      if (!arg.startsWith('--')) {
        positional.add(arg);
        continue;
      }
      if (k + 1 >= args.length) {
        throw _Exit2('$arg needs a value');
      }
      final String name = arg.substring(2);
      final allowed = {'mode', 'order', 'width', 'height', if (bench) 'runs', if (bench) 'warmup'};
      if (!allowed.contains(name)) {
        throw _Exit2('unknown flag --$name');
      }
      if (flags.containsKey(name)) {
        throw _Exit2('--$name given twice');
      }
      flags[name] = args[++k];
    }
    if (positional.length != 1) {
      throw _Exit2('expected one <input.json>');
    }
    final LayoutMode mode =
        LayoutMode.values.where((m) => m.name == flags['mode']).firstOrNull ??
        (throw _Exit2('--mode must be compact or free'));
    final LaneOrder order =
        LaneOrder.values.where((o) => o.name == flags['order']).firstOrNull ??
        (throw _Exit2('--order must be greedy or compact'));
    double size(String name) {
      final double? value = double.tryParse(flags[name] ?? '');
      if (value == null || value <= 0) {
        throw _Exit2('--$name must be a positive number');
      }
      return value;
    }

    int? count(String name) {
      final String? value = flags[name];
      return value == null ? null : (int.tryParse(value) ?? (throw _Exit2('--$name must be an integer')));
    }

    return _Cli(mode, order, size('width'), size('height'), count('runs'), count('warmup'), positional.single);
  }

  final LayoutMode mode;
  final LaneOrder order;
  final double width;
  final double height;
  final int? runs;
  final int? warmup;
  final String input;
}
