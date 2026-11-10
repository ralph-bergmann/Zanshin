// SPDX-License-Identifier: MIT

// The line router (docs/graph-layout.md §14) from the command line: a route check on a §2 input and a
// benchmark. Not part of the test gate; it imports nothing that reaches `dart:ffi`.
//
// ```text
// router_cli check --mode compact|free --width W --height H <input.json>
// router_cli bench --mode compact|free --width W --height H [--runs N] [--warmup W] <input.json>
// ```
//
// `check` lays the input out with the product engine (`computeGraphGrid`, no stacks), routes it and
// prints one JSON line of counts: the lines per number of points, the reports and the segments inside
// a non-endpoint card (split into reported = on a line the router reports, and not). `bench` prints
// one JSON line with the per-layout stage (`class`), the geometry stage and one 1200 × 800 bridge
// window (at the plane's left edge, vertically centred, where the trunk's lines run) medians; parsing
// and the layout are untimed. Exit code 2 on a usage error or an invalid input. Run from
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
  router_cli check --mode compact|free --width W --height H <input.json>
  router_cli bench --mode compact|free --width W --height H [--runs N] [--warmup W] <input.json>''';

/// A usage error or an invalid input: exit code 2.
final class _Exit2 implements Exception {
  _Exit2(this.message);

  final String message;
}

void main(List<String> args) {
  try {
    if (args.isEmpty) {
      throw _Exit2('missing command');
    }
    final void Function(List<String>) run = switch (args.first) {
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

/// A §2 input laid out by the product engine, ready to route.
typedef _Laid = ({GraphGridView grid, Int32List parentCounts, int n});

_Laid _layOut(_Cli cli, Uint8List bytes) {
  final LayoutInput input = parseSpecInput(bytes).input;
  final grid = GraphGridView.fromBytes(computeGraphGrid(input, mode: cli.mode));
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
  final pointCounts = <String, int>{'2': 0, '4': 0, '6': 0, '8': 0};
  for (var k = 0; k < classes.edgeCount; k++) {
    pointCounts.update('${g.pointStarts[k + 1] - g.pointStarts[k]}', (count) => count + 1);
  }
  var vertical = 0;
  var horizontal = 0;
  var reported = 0;
  final List<CardHit> hits = cardHits(g);
  for (final hit in hits) {
    if (hit.vertical) {
      vertical++;
    } else {
      horizontal++;
    }
    if (g.behindEdges[hit.edge] != 0) {
      reported++;
    }
  }
  stdout.writeln(
    jsonEncode({
      'input': File(cli.input).uri.pathSegments.last,
      'mode': cli.mode.name,
      'width': cli.width,
      'height': cli.height,
      'nodes': laid.n,
      'edges': classes.edgeCount,
      'points': pointCounts,
      'behind_cards': g.behindCards,
      'shared_stretches': g.sharedStretches,
      'tight_fans': g.tightFans,
      'unavoidable_crossings': g.unavoidableCrossings,
      'unsettled_ports': g.unsettledPorts,
      'card_hits': {
        'total': hits.length,
        'vertical': vertical,
        'horizontal': horizontal,
        'reported': reported,
        'unreported': hits.length - reported,
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
  _Cli(this.mode, this.width, this.height, this.runs, this.warmup, this.input);

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
      final allowed = {'mode', 'width', 'height', if (bench) 'runs', if (bench) 'warmup'};
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

    return _Cli(mode, size('width'), size('height'), count('runs'), count('warmup'), positional.single);
  }

  final LayoutMode mode;
  final double width;
  final double height;
  final int? runs;
  final int? warmup;
  final String input;
}
