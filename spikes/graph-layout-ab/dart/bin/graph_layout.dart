import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:graph_layout/graph_layout.dart';

const String _usage = '''
usage:
  graph_layout layout --mode compact|time|free --order greedy|optimized|compact [--budget B] [--stacks R] [--columns mode|joint] <input.json> <output.json>
  graph_layout bench  --mode compact|time|free --order greedy|optimized|compact [--budget B] [--stacks R] [--columns mode|joint] [--runs N] [--warmup W] <input.json>
(--order compact is Dart-only, SPEC §4.7; --budget is its search budget, default 2000000;
 --stacks R is Dart-only, SPEC §4.8: the stack request file R, modes compact and free only;
 --columns is Dart-only, SPEC §4.3 / §4.7: joint = one packing and column order for compact and
 free (modes compact and free, orders greedy and compact only), mode = per mode, the default)''';

/// Usage error or invalid input: exit code 2 (SPEC §6).
final class _Exit2 implements Exception {
  _Exit2(this.message);

  final String message;
}

void main(List<String> args) {
  try {
    if (args.isEmpty) throw _Exit2('missing command');
    final cli = _Cli.parse(args.sublist(1));
    switch (args.first) {
      case 'layout':
        _layout(cli);
      case 'bench':
        _bench(cli);
      default:
        throw _Exit2('unknown command "${args.first}"');
    }
  } on _Exit2 catch (e) {
    stderr
      ..writeln('graph_layout: ${e.message}')
      ..writeln(_usage);
    exitCode = 2;
  } on InputError catch (e) {
    stderr.writeln('graph_layout: invalid input: ${e.message}');
    exitCode = 2;
  }
}

void _layout(_Cli cli) {
  if (cli.runs != null || cli.warmup != null) throw _Exit2('--runs / --warmup are bench-only');
  if (cli.positional.length != 2) throw _Exit2('layout takes <input.json> <output.json>');
  final request = cli.stacks == null ? null : _read(cli.stacks!);
  final input = parseInput(_read(cli.positional[0]), stacks: request != null);
  final stacks = request == null ? null : parseStackRequest(request, input);
  final json = encodeOutput(
    computeLayout(input, cli.mode, cli.order, budget: cli.budget, stacks: stacks, joint: cli.joint),
  );
  try {
    File(cli.positional[1]).writeAsStringSync(json);
  } on FileSystemException catch (e) {
    throw _Exit2('cannot write ${cli.positional[1]}: ${e.message}');
  }
}

void _bench(_Cli cli) {
  if (cli.positional.length != 1) throw _Exit2('bench takes <input.json>');
  final runs = cli.runs ?? 31;
  final warmup = cli.warmup ?? 10;
  if (runs < 1) throw _Exit2('--runs must be ≥ 1');
  if (warmup < 0) throw _Exit2('--warmup must be ≥ 0');
  final path = cli.positional[0];
  final bytes = _read(path); // untimed (SPEC §8.2.1)
  final request = cli.stacks == null ? null : _read(cli.stacks!);

  // With --stacks one more phase, `stacks`, after `ordering` (SPEC §6, amended 2026-10-01).
  final phases = [
    'parse',
    'layering',
    'lanes',
    'blocked',
    'routing',
    'ordering',
    if (request != null) 'stacks',
    'total',
  ];
  final timed = phases.length - 1;
  final samples = List.generate(phases.length, (_) => Int64List(runs));
  final t = Int64List(timed + 1);
  final sw = Stopwatch()..start();
  LayoutInput? input;
  LayoutResult? result;
  for (var iter = 0; iter < warmup + runs; iter++) {
    var k = 0;
    t[k++] = sw.elapsedTicks;
    input = parseInput(bytes, stacks: request != null);
    final stacks = request == null ? null : parseStackRequest(request, input);
    t[k++] = sw.elapsedTicks;
    result = computeLayout(
      input,
      cli.mode,
      cli.order,
      budget: cli.budget,
      stacks: stacks,
      joint: cli.joint,
      onPhaseEnd: () => t[k++] = sw.elapsedTicks,
    );
    if (iter < warmup) continue;
    final r = iter - warmup;
    for (var ph = 0; ph < timed; ph++) {
      samples[ph][r] = _ns(t[ph + 1] - t[ph], sw.frequency);
    }
    samples[timed][r] = _ns(t[timed] - t[1], sw.frequency); // total: one span, parse excluded
  }

  final out = StringBuffer()
    ..write('{"impl":"')
    ..write(const bool.fromEnvironment('dart.vm.product') ? 'dart-aot' : 'dart-jit')
    ..write('","input":')
    ..write(jsonEncode(File(path).uri.pathSegments.last))
    ..write(',"mode":"')
    ..write(cli.mode.name)
    ..write('","order":"')
    ..write(cli.order.name)
    ..write(cli.joint ? '","columns":"joint' : '')
    ..write('","nodes":')
    ..write(input!.n)
    ..write(',"edges":')
    ..write(result!.edgeFrom.length)
    ..write(',"rows":')
    ..write(result.rows)
    ..write(',"lanes":')
    ..write(result.lanes)
    ..write(',"digest":')
    ..write(digest(result))
    ..write(',"warmup":')
    ..write(warmup)
    ..write(',"runs":')
    ..write(runs)
    ..write(',"phases":{');
  for (var ph = 0; ph < phases.length; ph++) {
    final s = samples[ph]..sort();
    if (ph > 0) out.write(',');
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

/// Stopwatch ticks × 10^9 div frequency (SPEC §8.2); skips the multiply when ticks are already ns.
int _ns(int ticks, int frequency) => frequency == 1000000000 ? ticks : ticks * 1000000000 ~/ frequency;

Uint8List _read(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException catch (e) {
    throw _Exit2('cannot read $path: ${e.message}');
  }
}

final class _Cli {
  _Cli(this.mode, this.order, this.runs, this.warmup, this.budget, this.stacks, this.joint, this.positional);

  factory _Cli.parse(List<String> args) {
    final flags = <String, String>{};
    final positional = <String>[];
    for (var k = 0; k < args.length; k++) {
      final arg = args[k];
      if (!arg.startsWith('--')) {
        positional.add(arg);
        continue;
      }
      final eq = arg.indexOf('=');
      final String name, value;
      if (eq >= 0) {
        name = arg.substring(2, eq);
        value = arg.substring(eq + 1);
      } else {
        if (k + 1 >= args.length) throw _Exit2('$arg needs a value');
        name = arg.substring(2);
        value = args[++k];
      }
      if (!const {'mode', 'order', 'runs', 'warmup', 'budget', 'stacks', 'columns'}.contains(name)) {
        throw _Exit2('unknown flag --$name');
      }
      if (flags.containsKey(name)) throw _Exit2('--$name given twice');
      flags[name] = value;
    }
    final mode = Mode.values.where((m) => m.name == flags['mode']).firstOrNull;
    if (mode == null) throw _Exit2('--mode must be compact, time or free');
    final order = LaneOrder.values.where((o) => o.name == flags['order']).firstOrNull;
    if (order == null) throw _Exit2('--order must be greedy, optimized or compact');
    final budget = _intFlag(flags, 'budget') ?? compactBudget;
    if (budget < 0) throw _Exit2('--budget must be ≥ 0');
    final stacks = flags['stacks'];
    if (stacks != null && mode == Mode.time) throw _Exit2('--stacks takes --mode compact or free');
    final columns = flags['columns'] ?? 'mode';
    if (columns != 'mode' && columns != 'joint') throw _Exit2('--columns must be mode or joint');
    final joint = columns == 'joint';
    if (joint && (mode == Mode.time || order == LaneOrder.optimized)) {
      throw _Exit2('--columns joint takes --mode compact or free and --order greedy or compact');
    }
    return _Cli(mode, order, _intFlag(flags, 'runs'), _intFlag(flags, 'warmup'), budget, stacks, joint, positional);
  }

  static int? _intFlag(Map<String, String> flags, String name) {
    final value = flags[name];
    if (value == null) return null;
    return int.tryParse(value) ?? (throw _Exit2('--$name must be an integer'));
  }

  final Mode mode;
  final LaneOrder order;
  final int? runs;
  final int? warmup;

  /// The `compact` order's search budget (SPEC §4.7), `compactBudget` unless `--budget` is given.
  final int budget;

  /// The stack request file (SPEC §4.8, Story 4.13), or null without `--stacks`.
  final String? stacks;

  /// `--columns joint` (SPEC §4.3 / §4.7, amended 2026-10-27, Story 4.14); `mode` is the default.
  final bool joint;
  final List<String> positional;
}
