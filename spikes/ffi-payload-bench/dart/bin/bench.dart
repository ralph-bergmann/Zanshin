// SPDX-License-Identifier: Apache-2.0
//
// Dart consumer-side bench: JSON vs FlatBuffers parse/access on the artifacts
// produced by the Rust `gen_artifacts` binary. Mirrors the real FFI direction
// (Rust produces, Dart reads).
//
// The matrix, per payload + size:
//   json decode-only    — jsonDecode(utf8.decode(bytes)), nothing else
//   json consume-all    — decode + read EVERY field (ints + strings)
//   json consume-subset — decode + read ONE scalar field per element
//   fb   consume-all     — zero-copy root + read EVERY field (materializes strings)
//   fb   consume-subset  — zero-copy root + read ONE scalar field per element
//
// "consume-subset" is the honest test of zero-copy: JSON must still parse the
// whole buffer, FlatBuffers can skip straight to the fields it needs.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/payload_zanshin.bench_generated.dart';

// Keep results alive so nothing is optimized away.
int _sink = 0;

void main(List<String> args) {
  final artifactsDir = args.isNotEmpty
      ? Directory(args[0])
      : Directory.fromUri(Platform.script.resolve('../../artifacts'));

  final manifestFile = File('${artifactsDir.path}/manifest.json');
  if (!manifestFile.existsSync()) {
    stderr.writeln('manifest not found: ${manifestFile.path}');
    stderr.writeln('run the Rust gen_artifacts binary first.');
    exit(1);
  }

  final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final entries = (manifest['entries'] as List).cast<Map<String, dynamic>>();

  _printHeader();
  for (final e in entries) {
    final kind = e['kind'] as String;
    final param = e['param'] as int;
    final jsonBytes = File('${artifactsDir.path}/${e['json']}').readAsBytesSync();
    final fbBytes = File('${artifactsDir.path}/${e['fb']}').readAsBytesSync();

    final consumers = kind == 'graph' ? _graphConsumers : _diffConsumers;

    final jsonDecodeOnly = _measure(() => consumers.jsonDecodeOnly(jsonBytes));
    final jsonAll = _measure(() => consumers.jsonAll(jsonBytes));
    final jsonSubset = _measure(() => consumers.jsonSubset(jsonBytes));
    final fbAll = _measure(() => consumers.fbAll(fbBytes));
    final fbSubset = _measure(() => consumers.fbSubset(fbBytes));

    _printRow('$kind/$param consume-all', jsonAll, fbAll);
    _printRow('$kind/$param consume-subset', jsonSubset, fbSubset);
    _printRow('$kind/$param json-decode-only', jsonDecodeOnly, fbSubset);
    stdout.writeln('');
  }

  // Defeat dead-code elimination.
  if (_sink == 0x7fffffffffffff) stdout.writeln('unreachable $_sink');
}

// --------------------------------------------------------------- Consumers

class _Consumers {
  const _Consumers({
    required this.jsonDecodeOnly,
    required this.jsonAll,
    required this.jsonSubset,
    required this.fbAll,
    required this.fbSubset,
  });

  final int Function(Uint8List) jsonDecodeOnly;
  final int Function(Uint8List) jsonAll;
  final int Function(Uint8List) jsonSubset;
  final int Function(Uint8List) fbAll;
  final int Function(Uint8List) fbSubset;
}

final _graphConsumers = _Consumers(
  jsonDecodeOnly: (b) {
    final m = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
    return (m['nodes'] as List).length;
  },
  jsonAll: (b) {
    final m = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
    final nodes = m['nodes'] as List;
    var sum = 0;
    for (final raw in nodes) {
      final n = raw as Map<String, dynamic>;
      sum += (n['row'] as int) + (n['lane'] as int) + (n['color'] as int);
      sum += (n['change_id'] as String).length +
          (n['commit_id'] as String).length +
          (n['summary'] as String).length;
      sum += (n['parents'] as List).length;
      if (n['is_working_copy'] as bool) sum += 1;
      if (n['is_immutable'] as bool) sum += 1;
    }
    return sum;
  },
  jsonSubset: (b) {
    final m = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
    final nodes = m['nodes'] as List;
    var sum = 0;
    for (final raw in nodes) {
      sum += (raw as Map<String, dynamic>)['lane'] as int;
    }
    return sum;
  },
  fbAll: (b) {
    final nodes = GraphSlice(b).nodes!;
    var sum = 0;
    for (final n in nodes) {
      sum += n.row + n.lane + n.color;
      sum += n.changeId!.length + n.commitId!.length + n.summary!.length;
      sum += n.parents!.length;
      if (n.isWorkingCopy) sum += 1;
      if (n.isImmutable) sum += 1;
    }
    return sum;
  },
  fbSubset: (b) {
    final nodes = GraphSlice(b).nodes!;
    var sum = 0;
    for (final n in nodes) {
      sum += n.lane;
    }
    return sum;
  },
);

final _diffConsumers = _Consumers(
  jsonDecodeOnly: (b) {
    final m = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
    return (m['files'] as List).length;
  },
  jsonAll: (b) {
    final m = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
    final files = m['files'] as List;
    var sum = 0;
    for (final rawF in files) {
      final f = rawF as Map<String, dynamic>;
      sum += (f['path'] as String).length + (f['old_path'] as String).length;
      sum += f['status'] as int;
      for (final rawH in f['hunks'] as List) {
        final h = rawH as Map<String, dynamic>;
        sum += (h['old_start'] as int) + (h['new_start'] as int);
        sum += (h['header'] as String).length;
        for (final rawL in h['lines'] as List) {
          final l = rawL as Map<String, dynamic>;
          sum += l['origin'] as int;
          sum += (l['old_lineno'] as int) + (l['new_lineno'] as int);
          sum += (l['content'] as String).length;
        }
      }
    }
    return sum;
  },
  jsonSubset: (b) {
    final m = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
    final files = m['files'] as List;
    var sum = 0;
    for (final rawF in files) {
      sum += (rawF as Map<String, dynamic>)['status'] as int;
    }
    return sum;
  },
  fbAll: (b) {
    final files = Diff(b).files!;
    var sum = 0;
    for (final f in files) {
      sum += f.path!.length + f.oldPath!.length;
      sum += f.status.value;
      for (final h in f.hunks!) {
        sum += h.oldStart + h.newStart;
        sum += h.header!.length;
        for (final l in h.lines!) {
          sum += l.origin.value;
          sum += l.oldLineno + l.newLineno;
          sum += l.content!.length;
        }
      }
    }
    return sum;
  },
  fbSubset: (b) {
    final files = Diff(b).files!;
    var sum = 0;
    for (final f in files) {
      sum += f.status.value;
    }
    return sum;
  },
);

// ----------------------------------------------------------------- Harness

class _Stat {
  const _Stat(this.medianUs, this.samples);
  final double medianUs;
  final int samples;
}

_Stat _measure(int Function() fn) {
  for (var i = 0; i < 3; i++) {
    _sink ^= fn();
  }
  final samples = <int>[];
  final overall = Stopwatch()..start();
  while (samples.length < 300 && overall.elapsedMilliseconds < 1500) {
    final sw = Stopwatch()..start();
    final r = fn();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
    _sink ^= r;
  }
  samples.sort();
  return _Stat(samples[samples.length ~/ 2].toDouble(), samples.length);
}

// ------------------------------------------------------------------ Output

void _printHeader() {
  stdout.writeln(
      '${'case'.padRight(34)}${'json'.padLeft(12)}${'flatbuf'.padLeft(12)}${'speedup'.padLeft(10)}');
  stdout.writeln('-' * 68);
}

void _printRow(String label, _Stat json, _Stat fb) {
  final speedup = json.medianUs / fb.medianUs;
  stdout.writeln(
    label.padRight(34) +
        _fmtUs(json.medianUs).padLeft(12) +
        _fmtUs(fb.medianUs).padLeft(12) +
        '${speedup.toStringAsFixed(2)}x'.padLeft(10),
  );
}

String _fmtUs(double us) {
  if (us >= 1000) return '${(us / 1000).toStringAsFixed(2)} ms';
  return '${us.toStringAsFixed(1)} µs';
}
