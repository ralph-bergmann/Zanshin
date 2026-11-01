// SPDX-License-Identifier: MIT

// Story 10.12: the real graph's costs on the worker. On extracted copies of the medium-1k and large-10k fixtures —
// each as committed (loose objects) and `git gc`-packed, and packed with jj's changed-path index when a `jj` CLI is on
// PATH (`jj debug index-changed-paths`, run on the temp copy only) — it measures `graphLayout` for `free` and
// `compact` over the default `revsets.log` and `all()`, and `commitContents` pages of 20, 60, 150 and 300 ids at the
// layout's operation (the merges first, then jj log order), what 10.11's content paging asks per viewport.
//
// Prints numbers only (min / median ms of 5 runs after 1 warm-up run); asserts nothing. Real worker isolate + real
// cdylib. Run from `packages/zanshin_core` with the env of `Makefile.toml`'s `[tasks.test-core]` (plus
// `ZANSHIN_LOG=error`):
//
// ```sh
// dart run benchmark/graph_content_page.dart
// ```

import 'dart:io';

import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/ffi/log_defaults.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';

const _warmup = 1;
const _runs = 5;
const _pages = [20, 60, 150, 300];

Future<void> main() async {
  final String? jj = await _jjCli();
  if (jj == null) {
    print('no jj 0.46.0 on PATH: the changed-path index runs are skipped');
  }
  final Directory temp = Directory.systemTemp.createTempSync('zanshin_graph_content_page_');
  try {
    for (final fixture in const ['medium-1k-commits', 'large-10k-commits']) {
      for (final store in ['loose', 'packed', if (jj != null) 'packed+changed-paths']) {
        final dir = Directory('${temp.path}/$fixture-$store')..createSync();
        await _run('tar', ['-xf', '../../test-fixtures/repos/$fixture.tar.zst', '-C', dir.path]);
        if (store != 'loose') {
          await _run('git', [
            '--git-dir=${dir.path}/.jj/repo/store/git',
            '-c',
            'gc.pruneExpire=never',
            'gc',
            '--quiet',
          ]);
        }
        if (store == 'packed+changed-paths') {
          await _run(jj!, ['--no-pager', '-R', dir.path, 'debug', 'index-changed-paths']);
        }
        await _bench(dir.path, '$fixture $store');
      }
    }
  } finally {
    temp.deleteSync(recursive: true);
  }
}

/// `jj` when it is on PATH at the pinned version, else null.
Future<String?> _jjCli() async {
  try {
    final ProcessResult version = await Process.run('jj', ['--version']);
    return version.exitCode == 0 && '${version.stdout}'.trim() == 'jj 0.46.0' ? 'jj' : null;
  } on ProcessException {
    return null;
  }
}

Future<void> _run(String executable, List<String> arguments) async {
  final ProcessResult result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError('$executable ${arguments.join(' ')}: ${result.stderr}');
  }
}

Future<void> _bench(String path, String label) async {
  final ZanshinWorker worker = await ZanshinWorker.start();
  try {
    final RepoHandle handle = await worker.openRepo(path);
    final LogDefaults defaults = await handle.logDefaults();
    for (final (String name, String revset) in [('revsets.log', defaults.log), ('all()', 'all()')]) {
      for (final LayoutMode mode in LayoutMode.values) {
        _report(
          label,
          'graphLayout($name, ${mode.name})',
          await _measure(
            () => handle.graphLayout(
              revset: revset,
              anchors: defaultGraphAnchors,
              utcOffsetMin: 120,
              prioritize: defaults.logGraphPrioritize,
              shortPrefixes: defaults.shortPrefixes,
              mode: mode,
            ),
          ),
        );
      }
    }
    final GraphTopologyView topology = (await handle.graphLayout(
      revset: 'all()',
      anchors: defaultGraphAnchors,
      utcOffsetMin: 120,
    )).topology;
    // The merges first (the costly `empty`), then jj log order; the root carries no content.
    final order = <int>[
      for (var i = 0; i < topology.nodeCount; i++)
        if (topology.parentCount(i) >= 2) i,
      for (var i = 0; i < topology.nodeCount; i++)
        if (topology.parentCount(i) == 1) i,
    ];
    final int merges = order.where((i) => topology.parentCount(i) >= 2).length;
    for (final int size in _pages) {
      final List<String> ids = [for (final int i in order.take(size)) topology.commitId(i)];
      _report(
        label,
        'commitContents(${ids.length} ids, ${merges < ids.length ? merges : ids.length} merges)',
        await _measure(
          () => handle.commitContents(
            operationId: topology.operationId,
            commitIds: ids,
            extraOperationIds: topology.extraOperationIds,
          ),
        ),
      );
    }
    await handle.close();
  } finally {
    await worker.close();
  }
}

/// `(min, median)` ms of [measured], from issuing it to its reply.
Future<(double, double)> _measure(Future<Object?> Function() measured) async {
  final samples = <int>[];
  for (var r = 0; r < _warmup + _runs; r++) {
    final sw = Stopwatch()..start();
    await measured();
    if (r >= _warmup) {
      samples.add(sw.elapsedMicroseconds);
    }
  }
  samples.sort();
  return (samples.first / 1000, samples[samples.length ~/ 2] / 1000);
}

void _report(String label, String what, (double, double) t) {
  final (double min, double median) = t;
  print('[$label] $what: min ${min.toStringAsFixed(1)} ms / med ${median.toStringAsFixed(1)} ms');
}
