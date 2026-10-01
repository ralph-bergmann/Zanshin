// SPDX-License-Identifier: MIT

// Story 4.11: the product layout engine behind docs/graph-layout.md §6's CLI, for the shipped
// scope only — a third implementation next to the spike's Rust and Dart references, which
// `node tools/compare.mjs --core <binary>` (spikes/graph-layout-ab) checks byte for byte.
//
// ```text
// graph_layout_cli layout --mode compact|free --order greedy|compact <input.json> <output.json>
// graph_layout_cli bench  --mode compact|free --order greedy|compact [--runs N] [--warmup W] <input.json>
// ```
//
// `bench` prints one §8.4 JSON line (`impl` `dart-core-aot` or `dart-core-jit`). The `parse`
// phase is the JSON parse plus V1–V4; the engine validates once more inside `layering`. Exit code
// 2 on a usage error or an invalid input (message on stderr, no output file). Not part of the
// test gate; it imports nothing that reaches `dart:ffi`. Run from `packages/zanshin_core`:
//
// ```sh
// dart run benchmark/graph_layout_cli.dart bench --mode free --order compact <input.json>
// dart compile exe benchmark/graph_layout_cli.dart -o <dir>/graph_layout_core
// ```

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import '../test/graph_layout/support/spec_json.dart';

const _usage = '''
usage:
  graph_layout_cli layout --mode compact|free --order greedy|compact <input.json> <output.json>
  graph_layout_cli bench  --mode compact|free --order greedy|compact [--runs N] [--warmup W] <input.json>''';

/// A usage error or an invalid input: exit code 2 (§6).
final class _Exit2 implements Exception {
  _Exit2(this.message);

  final String message;
}

void main(List<String> args) {
  try {
    if (args.isEmpty) {
      throw _Exit2('missing command');
    }
    // The command first: an unknown one is named as such, not as a flag error.
    final void Function(_Cli) run = switch (args.first) {
      'layout' => _layout,
      'bench' => _bench,
      _ => throw _Exit2('unknown command "${args.first}"'),
    };
    run(_Cli.parse(args.sublist(1)));
  } on _Exit2 catch (e) {
    stderr
      ..writeln('graph_layout_cli: ${e.message}')
      ..writeln(_usage);
    exitCode = 2;
  } on SpecInputError catch (e) {
    stderr.writeln('graph_layout_cli: invalid input: ${e.message}');
    exitCode = 2;
  } on LayoutContractException catch (e) {
    stderr.writeln('graph_layout_cli: invalid input: ${e.rule}: ${e.message}');
    exitCode = 2;
  }
}

void _layout(_Cli cli) {
  if (cli.runs != null || cli.warmup != null) {
    throw _Exit2('--runs / --warmup are bench-only');
  }
  if (cli.positional.length != 2) {
    throw _Exit2('layout takes <input.json> <output.json>');
  }
  final LayoutInput input = parseSpecInput(_read(cli.positional[0])).input;
  final grid = GraphGridView.fromBytes(
    computeGraphGrid(input, mode: cli.mode, order: cli.order, budget: defaultLayoutBudget),
  );
  try {
    File(cli.positional[1]).writeAsStringSync(canonicalOutput(grid));
  } on FileSystemException catch (e) {
    throw _Exit2('cannot write ${cli.positional[1]}: ${e.message}');
  }
}

void _bench(_Cli cli) {
  if (cli.positional.length != 1) {
    throw _Exit2('bench takes <input.json>');
  }
  final int runs = cli.runs ?? 31;
  final int warmup = cli.warmup ?? 10;
  if (runs < 1) {
    throw _Exit2('--runs must be ≥ 1');
  }
  if (warmup < 0) {
    throw _Exit2('--warmup must be ≥ 0');
  }
  final String path = cli.positional[0];
  final Uint8List bytes = _read(path); // untimed (§8.2.1)

  const phases = ['parse', 'layering', 'lanes', 'blocked', 'routing', 'ordering', 'total'];
  final List<Int64List> samples = List.generate(phases.length, (_) => Int64List(runs));
  final t = Int64List(7);
  final sw = Stopwatch()..start();
  LayoutInput? input;
  Uint8List? grid;
  for (var iter = 0; iter < warmup + runs; iter++) {
    var k = 0;
    t[k++] = sw.elapsedTicks;
    input = parseSpecInput(bytes).input;
    t[k++] = sw.elapsedTicks;
    grid = computeGraphGrid(
      input,
      mode: cli.mode,
      order: cli.order,
      budget: defaultLayoutBudget,
      onPhaseEnd: () => t[k++] = sw.elapsedTicks,
    );
    if (iter < warmup) {
      continue;
    }
    final int r = iter - warmup;
    for (var ph = 0; ph < 6; ph++) {
      samples[ph][r] = _ns(t[ph + 1] - t[ph], sw.frequency);
    }
    samples[6][r] = _ns(t[6] - t[1], sw.frequency); // total: one span, parse excluded
  }
  final view = GraphGridView.fromBytes(grid!);

  final out = StringBuffer()
    ..write('{"impl":"')
    ..write(const bool.fromEnvironment('dart.vm.product') ? 'dart-core-aot' : 'dart-core-jit')
    ..write('","input":')
    ..write(jsonEncode(File(path).uri.pathSegments.last))
    ..write(',"mode":"')
    ..write(cli.mode.name)
    ..write('","order":"')
    ..write(cli.order.name)
    ..write('","nodes":')
    ..write(input!.n)
    ..write(',"edges":')
    ..write(view.edgeCount)
    ..write(',"rows":')
    ..write(view.rows)
    ..write(',"lanes":')
    ..write(view.lanes)
    ..write(',"digest":')
    ..write(specDigest(view))
    ..write(',"warmup":')
    ..write(warmup)
    ..write(',"runs":')
    ..write(runs)
    ..write(',"phases":{');
  for (var ph = 0; ph < phases.length; ph++) {
    final Int64List s = samples[ph]..sort();
    if (ph > 0) {
      out.write(',');
    }
    out
      ..write('"')
      ..write(phases[ph])
      ..write('":{"median_ns":')
      ..write(s[runs ~/ 2])
      ..write(',"min_ns":')
      ..write(s[0])
      ..write('}');
  }
  out.write('}}');
  stdout.writeln(out);
}

/// Stopwatch ticks × 10^9 div frequency (§8.2); skips the multiply when ticks are already ns.
int _ns(int ticks, int frequency) => frequency == 1000000000 ? ticks : ticks * 1000000000 ~/ frequency;

Uint8List _read(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException catch (e) {
    throw _Exit2('cannot read $path: ${e.message}');
  }
}

final class _Cli {
  _Cli(this.mode, this.order, this.runs, this.warmup, this.positional);

  factory _Cli.parse(List<String> args) {
    final flags = <String, String>{};
    final positional = <String>[];
    for (var k = 0; k < args.length; k++) {
      final String arg = args[k];
      if (!arg.startsWith('--')) {
        positional.add(arg);
        continue;
      }
      final int eq = arg.indexOf('=');
      final String name;
      final String value;
      if (eq >= 0) {
        name = arg.substring(2, eq);
        value = arg.substring(eq + 1);
      } else {
        if (k + 1 >= args.length) {
          throw _Exit2('$arg needs a value');
        }
        name = arg.substring(2);
        value = args[++k];
      }
      if (!const {'mode', 'order', 'runs', 'warmup'}.contains(name)) {
        throw _Exit2('unknown flag --$name');
      }
      if (flags.containsKey(name)) {
        throw _Exit2('--$name given twice');
      }
      flags[name] = value;
    }
    final LayoutMode mode =
        LayoutMode.values.where((m) => m.name == flags['mode']).firstOrNull ??
        (throw _Exit2('--mode must be compact or free'));
    final LaneOrder order =
        LaneOrder.values.where((o) => o.name == flags['order']).firstOrNull ??
        (throw _Exit2('--order must be greedy or compact'));
    return _Cli(mode, order, _intFlag(flags, 'runs'), _intFlag(flags, 'warmup'), positional);
  }

  static int? _intFlag(Map<String, String> flags, String name) {
    final String? value = flags[name];
    if (value == null) {
      return null;
    }
    return int.tryParse(value) ?? (throw _Exit2('--$name must be an integer'));
  }

  final LayoutMode mode;
  final LaneOrder order;
  final int? runs;
  final int? warmup;
  final List<String> positional;
}
